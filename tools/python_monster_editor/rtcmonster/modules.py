"""Registries of behaviour modules, transition conditions and timeline events.

Everything a document may *execute* is listed here. A document names an entry
and supplies parameters; it can never carry code. The same metadata is what an
inspector needs to build its form, so the GUI does not hard-code any module.

``support`` says whether an entry mirrors behaviour that already exists in the
legacy GDScript runtime (``CONTRACT``) or is only reserved for later steps
(``PLANNED``). Nothing here is executed from data yet: MONSTER-STEP 1 has no
data-driven runtime.
"""

from dataclasses import dataclass

from .spec import CONTRACT, PLANNED, Bool, Choice, Id, Num, Vec

SNAPSHOT_STATES = ("IDLE", "MOVING", "ATTACKING", "HURT", "DEAD")
COMPARISONS = ("<", "<=", ">", ">=")
STAT_NAMES = ("max_health", "attack_damage", "move_speed", "chase_range", "attack_range")

GAMEPLAY = "gameplay"          # server authority only
PRESENTATION = "presentation"  # never changes damage, physics or state


@dataclass(frozen=True)
class Module:
    id: str
    category: str
    summary: str
    params: dict
    completes: bool          # raises ActionCompleted
    can_fail: bool           # raises ActionFailed
    terminal: bool = False   # the state is never left
    snapshot: str = "IDLE"   # EnemyRuntimeSnapshot.State replicated while active; "dynamic" = decided per tick
    required_roles: tuple = ()
    optional_roles: tuple = ()
    legacy: str = ""         # existing GDScript that behaves this way
    cleanup: str = ""        # what an interruption must undo
    atomic: str = ""         # part of the module during which ordinary transitions wait (interrupts still apply)
    support: str = CONTRACT


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

MODULES = {module.id: module for module in (
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
           atomic="crouch and flight: transitions are evaluated only while grounded and waiting"),
    Module("ReturnToOrigin", "movement", "Walk back to the spawn origin.",
           {"speed_scale": Num(1, 0.05, 10, "x move_speed"), "arrive_distance": Num(16, 1, 1000, "px")},
           completes=True, can_fail=False, snapshot="MOVING", required_roles=("move",),
           legacy="", cleanup="none", support=PLANNED),
    Module("ExecuteAttackPattern", "combat", "Run one attack pattern to its end.",
           {"pattern": Id("", empty=True, doc='Pattern to run. "" = choose with the attack selector.')},
           completes=True, can_fail=True, snapshot="ATTACKING",
           legacy="AttackState, FrogAttackState",
           cleanup="every live hitbox and facing lock is released; the cooldown already started stays",
           atomic="the whole pattern: only AttackPatternCompleted, ActionFailed and interrupts leave it"),
    Module("HurtReaction", "combat", "Hit-stun after a direct hit.",
           {"seconds": Num(0.25, 0, 10, "s")},
           completes=True, can_fail=False, snapshot="HURT", required_roles=("hurt",),
           legacy="HurtState (0.25 s)", cleanup="none"),
    Module("Death", "combat", "Stop, drop collision, then drop loot and remove the actor.",
           {"removal_seconds": Num(0.45, 0.05, 60, "s")},
           completes=False, can_fail=False, terminal=True, snapshot="DEAD", required_roles=("death",),
           legacy="DeadState.removal_seconds", cleanup="not interruptible"),
)}

# Named in the product plan but without a contract yet. A document that uses
# one is reported as failing instead of being accepted as if it could run.
RESERVED_MODULES = ("Walk", "Run", "Dash", "Jump", "Flee", "Fly", "SelectAttack", "Guard", "Dodge", "Recover",
                    "Alert", "Summon", "ApplyBuff", "Enrage", "TemporaryInvulnerability")


@dataclass(frozen=True)
class Condition:
    type: str
    summary: str
    params: dict
    legacy: str = ""
    support: str = CONTRACT


def _compare(unit, low=0, high=1_000_000):
    # ``value`` is a Quantity; schema.py swaps this placeholder for the Quantity node.
    return {"op": Choice(COMPARISONS, "<=", required=True), "value": ("quantity", unit, low, high)}


CONDITIONS = {condition.type: condition for condition in (
    Condition("Always", "Unconditional.", {}, legacy="timer-less fallthrough"),
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
    Condition("ActionCompleted", "The state's module finished.", {}, "timer expiry / landing"),
    Condition("ActionFailed", "The state's module gave up.", {}, "stuck clock"),
    Condition("AttackPatternCompleted", "The running attack pattern finished.", {}, "AttackState end"),
    Condition("AttackCooldownReady", 'The pattern\'s cooldown is over. "" = any pattern.',
              {"pattern": Id("", empty=True)}, "FrogAgent.attack_cooldown_remaining"),
    Condition("AttackAvailable", 'A pattern is in range, off cooldown and allowed. "" = any pattern.',
              {"pattern": Id("", empty=True)}, "ChaseState / FrogChaseState attack test"),
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
)}

# A cycle made only of these never waits for anything and would spin forever.
IMMEDIATE_CONDITIONS = ("Always",)


@dataclass(frozen=True)
class Event:
    type: str
    side: str
    summary: str
    params: dict
    legacy: str = ""
    support: str = CONTRACT


EVENTS = {event.type: event for event in (
    Event("RangeStrike", GAMEPLAY, "Instant hit on the current target if it is within reach + slack. No hitbox. "
                                    "Allowed inside an active phase or exactly where a windup ends.",
          {"reach": ("quantity", "px", 0, 4000), "slack": Num(12, 0, 1000, "px")},
          legacy="EnemyAgent.perform_attack"),
    Event("EnableHitbox", GAMEPLAY, "Arm a hitbox from collision.hitboxes until DisableHitbox or the pattern ends.",
          {"hitbox": Id(required=True)},
          support=PLANNED),
    Event("DisableHitbox", GAMEPLAY, "Disarm a hitbox.", {"hitbox": Id(required=True)}, support=PLANNED),
    Event("ApplyImpulse", GAMEPLAY, "Change the velocity once. x points forward and is mirrored by facing.",
          {"velocity": Vec((0, 0), unit="px/s", low=-10000, high=10000),
           "x_scales_move_speed": Bool(False, doc="x is a multiple of move_speed instead of px/s."),
           "mode": Choice(("set", "add"), "set"),
           "requires_grounded": Bool(True, doc="Skipped when the actor is not grounded.")},
          legacy="FrogAttackState leap"),
    Event("ApplyMovement", GAMEPLAY, "Hold a forward speed for a time.",
          {"speed_scale": Num(1, -10, 10, "x move_speed"), "seconds": Num(0.2, 0, 30, "s")}, support=PLANNED),
    Event("LockFacing", GAMEPLAY, "Stop turning toward the target.", {}, support=PLANNED),
    Event("UnlockFacing", GAMEPLAY, "Resume turning toward the target.", {}, support=PLANNED),
    Event("SpawnProjectile", GAMEPLAY, "Spawn a registered projectile.", {"projectile_id": Id(required=True)},
          support=PLANNED),
    Event("ApplyStatusEffect", GAMEPLAY, "Apply a registered EffectDefinition.",
          {"effect_id": Id(required=True), "target": Choice(("target", "self"), "target")}, support=PLANNED),
    Event("EnableInvulnerability", GAMEPLAY, "Ignore evadable damage.", {}, support=PLANNED),
    Event("DisableInvulnerability", GAMEPLAY, "Take damage again.", {}, support=PLANNED),
    Event("CompleteAttack", GAMEPLAY, "End the pattern early.", {}, support=PLANNED),
    Event("PlayAnimation", PRESENTATION, "Switch the clip shown for this pattern.", {"clip": Id(required=True)},
          support=PLANNED),
    Event("SpawnEffect", PRESENTATION, "Show a registered visual effect.", {"effect_id": Id(required=True)},
          support=PLANNED),
    Event("PlaySound", PRESENTATION, "Play a registered sound.", {"sound_id": Id(required=True)}, support=PLANNED),
)}
