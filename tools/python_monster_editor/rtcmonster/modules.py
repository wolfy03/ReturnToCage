"""Registries of behaviour modules, transition conditions and timeline events.

Everything a document may *execute* is listed here. A document names an entry
and supplies parameters; it can never carry code. One registry entry drives

    document normalization  (parameter types and defaults)
    static validation       (ranges, references, the flags below, entry-specific checks)
    inspector generation    (``describe`` / ``info`` of every parameter)
    reference documentation (rtcmonster.reference)
    capability lookup       (``support`` -> spec.capabilities)

so adding an entry never means editing the validator or the schema. The generic
code reads the flags on an entry (``completes``, ``damaging``, ``signal`` ...);
it never compares an entry's ID.

``support`` says whether an entry mirrors behaviour that already exists in the
legacy GDScript runtime (``CONTRACT``) or is only reserved (``PLANNED``).
Nothing here is executed from data yet: there is no data-driven runtime.
"""

from dataclasses import dataclass, field
from types import MappingProxyType

from .spec import CONTRACT, PLANNED, Bool, Choice, DocumentError, Id, Num, Vec, capabilities

SNAPSHOT_STATES = ("IDLE", "MOVING", "ATTACKING", "HURT", "DEAD")
COMPARISONS = ("<", "<=", ">", ">=")
STAT_NAMES = ("max_health", "attack_damage", "move_speed", "chase_range", "attack_range")

GAMEPLAY = "gameplay"          # server authority only
PRESENTATION = "presentation"  # never changes damage, physics or state

# Signals a state can wait for. A condition names the one it listens to.
COMPLETED, FAILED, PATTERN_COMPLETED = "completed", "failed", "pattern_completed"


@dataclass(frozen=True)
class Module:
    id: str
    category: str
    summary: str
    params: dict
    completes: bool          # raises the "completed" signal
    can_fail: bool           # raises the "failed" signal
    terminal: bool = False   # the state is never left
    snapshot: str = "IDLE"   # EnemyRuntimeSnapshot.State replicated while active; "dynamic" = decided per tick
    required_roles: tuple = ()
    optional_roles: tuple = ()
    legacy: str = ""         # existing GDScript that behaves this way
    cleanup: str = ""        # what an interruption must undo
    atomic: str = ""         # part of the module during which ordinary transitions wait (interrupts still apply)
    support: str = CONTRACT
    label: str = ""          # display name; defaults to the ID
    since: int = 1           # schema version that introduced the entry
    interruptible: bool = True      # the hurt interrupt may cut it short
    runs_pattern: bool = False      # executes an attack pattern and raises "pattern_completed"
    hurt_reaction: bool = False     # suitable as the target of the hurt interrupt
    clip_budgets: tuple = ()        # (clip role, seconds parameter): the clip should fit inside that time
    completes_if: object = None     # optional callable(params) -> bool narrowing ``completes``
    checks: tuple = ()              # callables(context, state, path): entry-specific validation

    def raises(self, params, has_time_limit=False):
        """Signals a state running this module can actually raise with these parameters."""
        signals = set()
        if self.completes and (self.completes_if is None or self.completes_if(params)):
            signals.add(COMPLETED)
        if self.can_fail or has_time_limit:
            signals.add(FAILED)
        if self.runs_pattern:
            signals.add(PATTERN_COMPLETED)
        return signals

    @property
    def capabilities(self):
        return capabilities(self.support)


@dataclass(frozen=True)
class Condition:
    type: str
    summary: str
    params: dict
    legacy: str = ""
    support: str = CONTRACT
    signal: str = ""         # the module signal this condition waits for, if any
    immediate: bool = False  # true without anything having to happen; a cycle of these never waits
    since: int = 1

    @property
    def capabilities(self):
        return capabilities(self.support)


@dataclass(frozen=True)
class Event:
    type: str
    side: str
    summary: str
    params: dict
    legacy: str = ""
    support: str = CONTRACT
    damaging: bool = False       # can hurt a target
    instant_strike: bool = False  # hits in the tick it runs, without a hitbox window
    arms: str = ""               # parameter naming the hitbox this event arms
    disarms: str = ""            # parameter naming the hitbox this event disarms
    leaves_ground: bool = False  # can lift the actor off the floor
    since: int = 1

    @property
    def capabilities(self):
        return capabilities(self.support)


@dataclass(frozen=True)
class Registry:
    """An immutable set of modules, conditions and events. ``extend`` returns a larger one."""
    modules: MappingProxyType = field(default_factory=lambda: MappingProxyType({}))
    conditions: MappingProxyType = field(default_factory=lambda: MappingProxyType({}))
    events: MappingProxyType = field(default_factory=lambda: MappingProxyType({}))
    reserved_modules: tuple = ()

    @staticmethod
    def of(modules=(), conditions=(), events=(), reserved_modules=()):
        return Registry().extend(modules, conditions, events, reserved_modules)

    def extend(self, modules=(), conditions=(), events=(), reserved_modules=()):
        def merged(current, entries, key, kind):
            result = dict(current)
            for entry in entries:
                name = getattr(entry, key)
                if name in result:
                    raise DocumentError(f"{kind} '{name}' is already registered")
                result[name] = entry
            return MappingProxyType(result)

        reserved = tuple(name for name in self.reserved_modules + tuple(reserved_modules)
                         if name not in {module.id for module in modules})
        return Registry(merged(self.modules, modules, "id", "module"),
                        merged(self.conditions, conditions, "type", "condition"),
                        merged(self.events, events, "type", "event"), reserved)


def _hop_completes(params):
    # An endless hop toward a target has no natural end; only patrol budgets and arrivals finish.
    return params["count"] > 0 or params["toward"] == "origin"


def _needs_a_pattern(context, state, path):
    if not context.index["pattern"]:
        context.add("no_attack_patterns", path, state["id"], subject=state["id"])


_HOP_PARAMS = {
    "toward": Choice(("patrol", "target", "origin"), "patrol", doc="Hop direction source."),
    "count": Num(0, 0, 100, "hops", integer=True, doc="Hops before ActionCompleted. 0 = keep hopping."),
    "interval_seconds": Num(0.8, 0, 60, "s", doc="Grounded wait before each hop."),
    "prepare_seconds": Num(0.18, 0.05, 5, "s", doc="Crouch on the ground before launch."),
    "speed_scale": Num(1, 0.05, 10, "x move_speed", doc="Horizontal launch speed as a share of move_speed."),
    "lift": Num(230, 50, 2000, "px/s", doc="Upward launch speed."),
    "patrol_radius": Num(130, 16, 4000, "px", doc="Used when toward = patrol."),
    "max_drop": Num(56, 4, 2000, "px", doc="Deepest landing accepted. Lower ground counts as an edge."),
    "max_air_seconds": Num(2.5, 0.5, 30, "s", doc="Safety net for a hop that never lands."),
    "stuck_seconds": Num(2.5, 0, 60, "s", doc="No progress for this long raises ActionFailed. 0 = never."),
    "min_progress": Num(6, 0, 1000, "px", doc="A hop shorter than this made no progress."),
    "arrive_distance": Num(28, 1, 1000, "px", doc="Used when toward = origin: ActionCompleted inside it."),
    "rehome_on_stuck": Bool(False, doc="toward = origin only: adopt the current position as the new origin."),
    "hold_in_attack_range": Bool(False, doc="toward = target only: do not hop while an attack pattern is in range, "
                                            "even one that is still cooling down."),
}

_MODULES = (
    Module("Wait", "movement", "Stand still for a fixed time.",
           {"seconds": Num(1, 0, 600, "s")},
           completes=True, can_fail=False, required_roles=("idle",),
           legacy="IdleState (1.0 s), FrogIdleState.wait_seconds", cleanup="none"),
    Module("GroundPatrol", "movement", "Walk back and forth around the spawn origin.",
           {"radius": Num(90, 8, 4000, "px"), "speed_scale": Num(0.55, 0.05, 10, "x move_speed")},
           completes=False, can_fail=False, snapshot="MOVING", required_roles=("move",),
           legacy="PatrolState", cleanup="horizontal velocity is left to the next state"),
    Module("ChaseTarget", "movement", "Walk toward the current target.",
           {"speed_scale": Num(1, 0.05, 10, "x move_speed")},
           completes=False, can_fail=False, snapshot="MOVING", required_roles=("move",),
           legacy="ChaseState", cleanup="horizontal velocity is left to the next state"),
    Module("FaceTarget", "movement", "Stop, turn toward the target and hold for a fixed time.",
           {"seconds": Num(0.35, 0, 60, "s")},
           completes=True, can_fail=False, required_roles=("idle",),
           legacy="FrogAlertState", cleanup="none"),
    Module("Hop", "movement", "Move only by grounded hops: wait, crouch, launch once, land.",
           _HOP_PARAMS, completes=True, can_fail=True, snapshot="dynamic",
           required_roles=("idle",), optional_roles=("jump_start", "jump", "fall", "land"),
           legacy="FrogPatrolState / FrogChaseState / FrogReturnState with FrogPrepareState and FrogHopState",
           cleanup="a hop already in the air is not cancelled; the next state inherits the velocity",
           atomic="crouch and flight: transitions are evaluated only while grounded and waiting",
           clip_budgets=(("jump_start", "prepare_seconds"),), completes_if=_hop_completes),
    Module("ReturnToOrigin", "movement", "Walk back to the spawn origin.",
           {"speed_scale": Num(1, 0.05, 10, "x move_speed"), "arrive_distance": Num(16, 1, 1000, "px")},
           completes=True, can_fail=False, snapshot="MOVING", required_roles=("move",),
           legacy="", cleanup="none", support=PLANNED),
    Module("ExecuteAttackPattern", "combat", "Run one attack pattern to its end.",
           {"pattern": Id("", empty=True, ref="pattern", doc='Pattern to run. "" = choose with the attack selector.')},
           completes=True, can_fail=True, snapshot="ATTACKING",
           legacy="AttackState, FrogAttackState",
           cleanup="every live hitbox and facing lock is released; the cooldown already started stays",
           atomic="the whole pattern: only AttackPatternCompleted, ActionFailed and interrupts leave it",
           runs_pattern=True, checks=(_needs_a_pattern,)),
    Module("HurtReaction", "combat", "Hit-stun after a direct hit.",
           {"seconds": Num(0.25, 0, 10, "s")},
           completes=True, can_fail=False, snapshot="HURT", required_roles=("hurt",),
           legacy="HurtState (0.25 s)", cleanup="none", hurt_reaction=True,
           clip_budgets=(("hurt", "seconds"),)),
    Module("Death", "combat", "Stop, drop collision, then drop loot and remove the actor.",
           {"removal_seconds": Num(0.45, 0.05, 60, "s")},
           completes=False, can_fail=False, terminal=True, snapshot="DEAD", required_roles=("death",),
           legacy="DeadState.removal_seconds", cleanup="not interruptible", interruptible=False,
           clip_budgets=(("death", "removal_seconds"),)),
)

# Named in the product plan but without a contract yet. A document that uses
# one is reported as failing instead of being accepted as if it could run.
_RESERVED_MODULES = ("Walk", "Run", "Dash", "Jump", "Flee", "Fly", "SelectAttack", "Guard", "Dodge", "Recover",
                     "Alert", "Summon", "ApplyBuff", "Enrage", "TemporaryInvulnerability")


def _compare(unit, low=0, high=1_000_000):
    # ``value`` is a Quantity; schema.py swaps this placeholder for the Quantity node.
    return {"op": Choice(COMPARISONS, "<=", required=True), "value": ("quantity", unit, low, high)}


_PATTERN_REF = {"pattern": Id("", empty=True, ref="pattern")}

_CONDITIONS = (
    Condition("Always", "Unconditional.", {}, legacy="timer-less fallthrough", immediate=True),
    Condition("HasTarget", "A valid living player in the same world is selected.", {}, "EnemyAgent._valid_target"),
    Condition("LostTarget", "No valid target is selected.", {}, "EnemyAgent._valid_target"),
    Condition("TargetDistance", "Distance between actor and target origins. Infinite without a target.",
              _compare("px"), "EnemyAgent.distance_to_player"),
    Condition("TargetVerticalDistance", "Absolute height difference to the target.",
              _compare("px"), "FrogAgent.attack_vertical_reach"),
    Condition("TargetOriginDistance", "Horizontal distance between the target and the spawn origin.",
              _compare("px"), "FrogAgent.target_inside_leash"),
    Condition("DistanceFromOrigin", "Horizontal distance between the actor and the spawn origin.",
              _compare("px"), "FrogAgent.distance_from_origin"),
    Condition("StateElapsedTime", "Time since the state was entered.", _compare("s", 0, 3600), "state timers"),
    Condition("ActionCompleted", "The state's module finished.", {}, "timer expiry / landing", signal=COMPLETED),
    Condition("ActionFailed", "The state's module gave up.", {}, "stuck clock", signal=FAILED),
    Condition("AttackPatternCompleted", "The running attack pattern finished.", {}, "AttackState end",
              signal=PATTERN_COMPLETED),
    Condition("AttackCooldownReady", 'The pattern\'s cooldown is over. "" = any pattern.',
              _PATTERN_REF, "FrogAgent.attack_cooldown_remaining"),
    Condition("AttackAvailable", 'A pattern is in range, off cooldown and allowed. "" = any pattern.',
              _PATTERN_REF, "ChaseState / FrogChaseState attack test"),
    Condition("IsGrounded", "Touched the floor within the grounded grace time.", {}, "FrogAgent.is_grounded"),
    Condition("IsAirborne", "Not grounded.", {}, "FrogAgent.is_grounded"),
    Condition("HealthRatio", "Current health divided by maximum health.", _compare("ratio", 0, 1), support=PLANNED),
    Condition("ObstacleAhead", "A wall blocks the facing direction within the distance.",
              {"distance": Num(24, 1, 2000, "px")}, support=PLANNED),
    Condition("EdgeAhead", "The ground ahead drops further than max_drop.",
              {"distance": Num(24, 1, 2000, "px"), "max_drop": Num(56, 4, 2000, "px")}, support=PLANNED),
    Condition("ReceivedDamage", "Damage was taken during this tick.", {}, support=PLANNED),
    Condition("IsDead", "Health reached zero.", {}, support=PLANNED),
    Condition("RandomChance", "True with this probability per second, drawn from the server RNG.",
              {"per_second": Num(0.5, 0, 60, "1/s")}, support=PLANNED),
)

_EVENTS = (
    Event("RangeStrike", GAMEPLAY, "Instant hit on the current target if it is within reach + slack. No hitbox. "
                                    "Allowed inside an active phase or exactly where a windup ends.",
          {"reach": ("quantity", "px", 0, 4000), "slack": Num(12, 0, 1000, "px")},
          legacy="EnemyAgent.perform_attack", damaging=True, instant_strike=True),
    Event("EnableHitbox", GAMEPLAY, "Arm a hitbox from collision.hitboxes until DisableHitbox or the pattern ends.",
          {"hitbox": Id(required=True, ref="hitbox")}, support=PLANNED, damaging=True, arms="hitbox"),
    Event("DisableHitbox", GAMEPLAY, "Disarm a hitbox.", {"hitbox": Id(required=True, ref="hitbox")},
          support=PLANNED, disarms="hitbox"),
    Event("ApplyImpulse", GAMEPLAY, "Change the velocity once. x points forward and is mirrored by facing.",
          {"velocity": Vec((0, 0), unit="px/s", low=-10000, high=10000),
           "x_scales_move_speed": Bool(False, doc="x is a multiple of move_speed instead of px/s."),
           "mode": Choice(("set", "add"), "set"),
           "requires_grounded": Bool(True, doc="Skipped when the actor is not grounded.")},
          legacy="FrogAttackState leap", leaves_ground=True),
    Event("ApplyMovement", GAMEPLAY, "Hold a forward speed for a time.",
          {"speed_scale": Num(1, -10, 10, "x move_speed"), "seconds": Num(0.2, 0, 30, "s")}, support=PLANNED),
    Event("LockFacing", GAMEPLAY, "Stop turning toward the target.", {}, support=PLANNED),
    Event("UnlockFacing", GAMEPLAY, "Resume turning toward the target.", {}, support=PLANNED),
    Event("SpawnProjectile", GAMEPLAY, "Spawn a registered projectile.", {"projectile_id": Id(required=True)},
          support=PLANNED, damaging=True),
    Event("ApplyStatusEffect", GAMEPLAY, "Apply a registered EffectDefinition.",
          {"effect_id": Id(required=True), "target": Choice(("target", "self"), "target")}, support=PLANNED),
    Event("EnableInvulnerability", GAMEPLAY, "Ignore evadable damage.", {}, support=PLANNED),
    Event("DisableInvulnerability", GAMEPLAY, "Take damage again.", {}, support=PLANNED),
    Event("CompleteAttack", GAMEPLAY, "End the pattern early.", {}, support=PLANNED),
    Event("PlayAnimation", PRESENTATION, "Switch the clip shown for this pattern.",
          {"clip": Id(required=True, ref="animation")}, support=PLANNED),
    Event("SpawnEffect", PRESENTATION, "Show a registered visual effect.", {"effect_id": Id(required=True)},
          support=PLANNED),
    Event("PlaySound", PRESENTATION, "Play a registered sound.", {"sound_id": Id(required=True)}, support=PLANNED),
)

DEFAULT_REGISTRY = Registry.of(_MODULES, _CONDITIONS, _EVENTS, _RESERVED_MODULES)

# Convenience views of the default registry.
MODULES = DEFAULT_REGISTRY.modules
CONDITIONS = DEFAULT_REGISTRY.conditions
EVENTS = DEFAULT_REGISTRY.events
RESERVED_MODULES = DEFAULT_REGISTRY.reserved_modules
