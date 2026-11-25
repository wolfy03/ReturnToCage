"""Static validation of a monster document.

Every finding belongs to one domain and has one of four states. A domain that
was not examined stays NOT_EVALUATED: this module never runs Godot, so
``runtime`` and ``network`` can never be PASS here, and ``publish`` can only
fail or stay unevaluated.
"""

from collections import Counter
from dataclasses import dataclass
import re

from . import project as project_files
from .document import decode
from .modules import CONDITIONS, EVENTS, GAMEPLAY, IMMEDIATE_CONDITIONS, MODULES, RESERVED_MODULES
from .schema import DOCUMENT, LOOPING_ROLES, ONE_SHOT_ROLES, REQUIRED_ROLES, StateNode, condition_leaves, resolve
from .spec import PLANNED, Arr, DocumentError, Map, Obj, Opt
from .timing import DEFAULT_TICK_RATE, clip_seconds, frame_start_seconds, tick_of, window_ticks

PASS = "PASS"
WARNING = "WARNING"
FAIL = "FAIL"
NOT_EVALUATED = "NOT_EVALUATED"

SCHEMA, REFERENCES, ASSETS, ANIMATION, COLLISION, ATTACK, AI = (
    "schema", "references", "assets", "animation", "collision", "attack", "ai")
COMPATIBILITY, RUNTIME, NETWORK, PUBLISH = "compatibility", "runtime", "network", "publish"
DOMAINS = (SCHEMA, REFERENCES, ASSETS, ANIMATION, COLLISION, ATTACK, AI, COMPATIBILITY, RUNTIME, NETWORK, PUBLISH)
STATIC_DOMAINS = DOMAINS[:8]
TIME_TOLERANCE = 1e-6
DAMAGING_EVENTS = ("RangeStrike", "EnableHitbox", "SpawnProjectile")
_RANGE_DOMAINS = (("collision", COLLISION), ("attack_patterns", ATTACK), ("behavior", AI),
                  ("animations", ANIMATION), ("presentation", ANIMATION), ("assets", ASSETS))


def summarize(states):
    states = set(states)
    return next((state for state in (FAIL, WARNING, NOT_EVALUATED) if state in states),
                PASS if states else NOT_EVALUATED)


@dataclass(frozen=True, slots=True)
class Finding:
    status: str
    domain: str
    code: str
    path: str = ""
    detail: str = ""


@dataclass(frozen=True)
class Report:
    findings: tuple

    def status(self, domain):
        return summarize(item.status for item in self.findings if item.domain == domain)

    def summary(self):
        return {domain: self.status(domain) for domain in DOMAINS}

    @property
    def static_status(self):
        """Worst state among the domains this module can actually decide."""
        return summarize(self.status(domain) for domain in STATIC_DOMAINS)

    @property
    def overall(self):
        return summarize(self.status(domain) for domain in DOMAINS)

    def select(self, status=None, domain=None, code=None):
        return [item for item in self.findings
                if (status is None or item.status == status) and (domain is None or item.domain == domain)
                and (code is None or item.code == code)]

    def codes(self, status=FAIL):
        return {item.code for item in self.findings if item.status == status}


def validate_payload(payload, **options):
    """Validate raw bytes. An unreadable file is a schema failure, not an exception."""
    try:
        document = decode(payload)
    except DocumentError as error:
        return Report((Finding(FAIL, SCHEMA, "unreadable_document", "", str(error)),)
                      + tuple(Finding(NOT_EVALUATED, domain, "document_unreadable") for domain in DOMAINS[1:]))
    return validate(document, **options)


def duplicate_monster_ids(documents):
    """Findings for monster IDs shared by several ``(label, document)`` pairs of one catalog."""
    counts = Counter(document.monster_id for _, document in documents)
    return [Finding(FAIL, REFERENCES, "duplicate_monster_id", label, document.monster_id)
            for label, document in documents if counts[document.monster_id] > 1]


def _always_true(condition):
    if "all" in condition:
        return all(_always_true(part) for part in condition["all"])
    if "any" in condition:
        return any(_always_true(part) for part in condition["any"])
    return "not" not in condition and condition["type"] in IMMEDIATE_CONDITIONS


def _can_fire(condition, never):
    if "all" in condition:
        return all(_can_fire(part, never) for part in condition["all"])
    if "any" in condition:
        return any(_can_fire(part, never) for part in condition["any"])
    return "not" in condition or condition["type"] not in never


def _planned_paths(node, value, path="", inherited=False):
    """Paths of values that differ from their default but that no runtime reads."""
    if isinstance(node, StateNode):
        node = node._base
    planned = inherited or node.support == PLANNED
    if isinstance(node, Opt):
        if value is not None:
            if planned:
                yield path
            else:
                yield from _planned_paths(node.node, value, path, planned)
    elif isinstance(node, Obj):
        for key, child in node.fields.items():
            yield from _planned_paths(child, value[key], f"{path}.{key}" if path else key, planned)
    elif isinstance(node, Arr):
        if planned:
            if value:
                yield path
        else:
            for index, item in enumerate(value):
                yield from _planned_paths(node.item, item, f"{path}[{index}]", False)
    elif isinstance(node, Map):
        if planned and value:
            yield path
    elif planned and hasattr(node, "default"):
        try:
            if value != node.default():
                yield path
        except (NotImplementedError, DocumentError):
            return


class _Validator:
    def __init__(self, document, project, tick_rate):
        self.doc = document
        self.data = document.data
        self.project = project
        self.tick_rate = tick_rate
        self.findings = []
        data = self.data
        self.images = {row["id"]: row for row in data["assets"]["images"]}
        self.clips = {row["id"]: row for row in data["animations"]["clips"]}
        self.hitboxes = {row["id"] for row in data["collision"]["hitboxes"]}
        self.patterns = {row["id"]: row for row in data["attack_patterns"]}
        self.states = {row["id"]: row for row in data["behavior"]["states"]}

    def add(self, status, domain, code, path="", detail=""):
        self.findings.append(Finding(status, domain, code, path, str(detail)))

    def run(self):
        for check in (self.schema, self.references, self.assets, self.animation, self.collision, self.attack,
                      self.ai, self.compatibility):
            check()
        for domain, code in ((SCHEMA, "structure_valid"), (REFERENCES, "references_resolved"),
                             (ASSETS, "assets_verified"), (ANIMATION, "animation_consistent"),
                             (COLLISION, "collision_valid"), (ATTACK, "attack_timelines_valid"),
                             (AI, "behavior_graph_valid"), (COMPATIBILITY, "no_static_incompatibility")):
            if not any(item.domain == domain for item in self.findings):
                self.add(PASS, domain, code)
        self.add(NOT_EVALUATED, RUNTIME, "godot_runtime_not_run",
                 detail="No Godot process ran. A data-driven runtime does not exist in MONSTER-STEP 1.")
        self.add(NOT_EVALUATED, NETWORK, "network_replication_not_run")
        binding = self.data["source_binding"]
        for index, row in enumerate((binding or {}).get("unsupported", ())):
            self.add(FAIL, PUBLISH, "export_blocked_unsupported", f"source_binding.unsupported[{index}]",
                     f"{row['path']}: {row['reason']}")
        if any(item.status == FAIL and item.domain in STATIC_DOMAINS for item in self.findings):
            self.add(FAIL, PUBLISH, "publish_blocked_by_failures")
        self.add(NOT_EVALUATED, PUBLISH, "publish_not_implemented",
                 detail="Publishing to Godot content is outside MONSTER-STEP 1.")
        return Report(tuple(self.findings))

    # -- schema -----------------------------------------------------------------------------------------------
    def schema(self):
        def report(path, code, detail):
            domain = next((domain for prefix, domain in _RANGE_DOMAINS if path.startswith(prefix)), SCHEMA)
            self.add(FAIL, domain, code, path, detail)
        DOCUMENT.check(self.data, "", report)
        loot = self.data["loot"]
        for index, row in enumerate(loot["entries"] or ()):
            if row["min_amount"] > row["max_amount"]:
                self.add(FAIL, SCHEMA, "loot_amount_order", f"loot.entries[{index}]",
                         f"min {row['min_amount']} > max {row['max_amount']}")
        if loot["entries"] is not None and not loot["loot_table_id"]:
            self.add(FAIL, SCHEMA, "loot_table_id_missing", "loot.loot_table_id")

    # -- references -------------------------------------------------------------------------------------------
    def _duplicates(self, rows, label, path):
        counts = Counter(row["id"] for row in rows)
        for index, row in enumerate(rows):
            if counts[row["id"]] > 1:
                self.add(FAIL, REFERENCES, f"duplicate_{label}_id", f"{path}[{index}].id", row["id"])

    def _need(self, known, value, code, path, allow_empty=True):
        if value == "" and allow_empty:
            return
        if value not in known:
            self.add(FAIL, REFERENCES, code, path, value)

    def references(self):
        data = self.data
        collision = data["collision"]
        for rows, label, path in (
                (data["assets"]["images"], "image", "assets.images"),
                (data["animations"]["clips"], "animation", "animations.clips"),
                (collision["hurtboxes"], "hurtbox", "collision.hurtboxes"),
                (collision["hitboxes"], "hitbox", "collision.hitboxes"),
                (data["attack_patterns"], "pattern", "attack_patterns"),
                (data["behavior"]["states"], "state", "behavior.states"),
                (data["behavior"]["phases"], "phase", "behavior.phases")):
            self._duplicates(rows, label, path)
        for index, clip in enumerate(data["animations"]["clips"]):
            for frame_index, frame in enumerate(clip["frames"]):
                self._need(self.images, frame["image"], "unknown_image",
                           f"animations.clips[{index}].frames[{frame_index}].image", False)
        for role, clip in data["presentation"]["roles"].items():
            self._need(self.clips, clip, "unknown_animation", f"presentation.roles.{role}")
        seen = Counter((row["clip"], row["frame"]) for row in collision["hurtbox_overrides"])
        for index, row in enumerate(collision["hurtbox_overrides"]):
            path = f"collision.hurtbox_overrides[{index}]"
            self._need(self.clips, row["clip"], "unknown_animation", f"{path}.clip", False)
            self._duplicates(row["boxes"], "hurtbox", f"{path}.boxes")
            clip = self.clips.get(row["clip"])
            if clip is not None and row["frame"] is not None and row["frame"] >= len(clip["frames"]):
                self.add(FAIL, REFERENCES, "frame_out_of_range", f"{path}.frame",
                         f"{row['clip']} has {len(clip['frames'])} frames")
            if seen[row["clip"], row["frame"]] > 1:
                self.add(FAIL, REFERENCES, "duplicate_hurtbox_override", path, f"{row['clip']} / {row['frame']}")
        for index, pattern in enumerate(data["attack_patterns"]):
            path = f"attack_patterns[{index}]"
            self._need(self.clips, pattern["clip"], "unknown_animation", f"{path}.clip")
            for event_index, event in enumerate(pattern["events"]):
                event_path = f"{path}.events[{event_index}]"
                if event["type"] == "PlayAnimation":
                    self._need(self.clips, event["clip"], "unknown_animation", f"{event_path}.clip", False)
                elif event["type"] in ("EnableHitbox", "DisableHitbox"):
                    self._need(self.hitboxes, event["hitbox"], "unknown_hitbox", f"{event_path}.hitbox", False)
            if pattern["condition"] is not None:
                self._condition_references(pattern["condition"], f"{path}.condition")
        behavior = data["behavior"]
        self._need(self.states, behavior["interrupts"]["hurt"]["state"], "unknown_state",
                   "behavior.interrupts.hurt.state")
        self._need(self.states, behavior["interrupts"]["death"]["state"], "unknown_state",
                   "behavior.interrupts.death.state", False)
        for index, state in enumerate(behavior["states"]):
            path = f"behavior.states[{index}]"
            if state["animation"]["mode"] == "clip":
                self._need(self.clips, state["animation"]["clip"], "unknown_animation", f"{path}.animation.clip", False)
            if state["module"] == "ExecuteAttackPattern":
                self._need(self.patterns, state["params"]["pattern"], "unknown_pattern", f"{path}.params.pattern")
            for transition_index, transition in enumerate(state["transitions"]):
                transition_path = f"{path}.transitions[{transition_index}]"
                self._need(self.states, transition["to"], "unknown_state", f"{transition_path}.to", False)
                self._condition_references(transition["condition"], f"{transition_path}.condition")
        for index, phase in enumerate(behavior["phases"]):
            self._need(self.states, phase["enter_state"], "unknown_state", f"behavior.phases[{index}].enter_state")
            for pattern_id in phase["pattern_weights"]:
                self._need(self.patterns, pattern_id, "unknown_pattern",
                           f"behavior.phases[{index}].pattern_weights.{pattern_id}", False)
        self._project_references()

    def _condition_references(self, condition, path):
        for leaf_path, leaf in condition_leaves(condition, path):
            if "pattern" in leaf:
                self._need(self.patterns, leaf["pattern"], "unknown_pattern", f"{leaf_path}.pattern")

    def _project_references(self):
        data = self.data
        binding, loot = data["source_binding"], data["loot"]
        if self.project is None:
            self.add(NOT_EVALUATED, REFERENCES, "monster_id_uniqueness_unchecked", "monster_id",
                     "No project folder was given.")
            if loot["loot_table_id"] or loot["entries"]:
                self.add(NOT_EVALUATED, REFERENCES, "loot_reference_unchecked", "loot")
            return
        published = project_files.published_monsters(self.project)
        if binding is None:
            if data["monster_id"] in published:
                self.add(FAIL, REFERENCES, "duplicate_monster_id", "monster_id",
                         f"already published by {published[data['monster_id']]['path']}")
        else:
            bound = project_files.bound_definition_id(self.project, binding["definition_path"])
            if bound is not None and bound != data["monster_id"]:
                self.add(FAIL, REFERENCES, "binding_id_mismatch", "monster_id",
                         f"{binding['definition_path']} defines {bound}")
        if loot["entries"] is None:
            if loot["loot_table_id"] and loot["loot_table_id"] not in project_files.content_ids(self.project, "loot"):
                self.add(FAIL, REFERENCES, "unknown_loot_table", "loot.loot_table_id", loot["loot_table_id"])
        else:
            items = project_files.content_ids(self.project, "items")
            for index, row in enumerate(loot["entries"]):
                if row["item_id"] not in items:
                    self.add(FAIL, REFERENCES, "unknown_item", f"loot.entries[{index}].item_id", row["item_id"])

    # -- assets -----------------------------------------------------------------------------------------------
    def assets(self):
        images = self.data["assets"]["images"]
        paths = Counter(row["path"] for row in images)
        for index, row in enumerate(images):
            path = f"assets.images[{index}]"
            if row["sha256"] and not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
                self.add(FAIL, ASSETS, "invalid_hash", f"{path}.sha256")
            if paths[row["path"]] > 1:
                self.add(WARNING, ASSETS, "duplicate_image_path", f"{path}.path", row["path"])
        thumbnail = self.data["metadata"]["thumbnail"]
        targets = [(f"assets.images[{index}]", row) for index, row in enumerate(images)]
        if thumbnail:
            targets.append(("metadata.thumbnail", {"path": thumbnail, "width": None, "height": None, "sha256": ""}))
        if not targets:
            return
        if self.project is None:
            self.add(NOT_EVALUATED, ASSETS, "asset_files_unchecked", detail="No project folder was given.")
            return
        for path, row in targets:
            try:
                width, height, digest = project_files.inspect_image(self.project, row["path"])
            except FileNotFoundError:
                self.add(FAIL, ASSETS, "asset_missing", path, row["path"])
                continue
            except (OSError, DocumentError) as error:
                self.add(FAIL, ASSETS, "asset_invalid", path, f"{row['path']}: {error}")
                continue
            if row["width"] is not None and (width, height) != (row["width"], row["height"]):
                self.add(FAIL, ASSETS, "asset_size_mismatch", path,
                         f"declared {row['width']}x{row['height']}, file is {width}x{height}")
            if row["sha256"] and row["sha256"] != digest:
                self.add(WARNING, ASSETS, "asset_changed", path, "The image changed since it was registered.")

    # -- animation --------------------------------------------------------------------------------------------
    def _frame_size(self, frame):
        if frame["rect"] is not None:
            return tuple(frame["rect"][2:])
        image = self.images.get(frame["image"])
        return (image["width"], image["height"]) if image else None

    def animation(self):
        data = self.data
        sizes = set()
        for index, clip in enumerate(data["animations"]["clips"]):
            path = f"animations.clips[{index}]"
            if not clip["frames"]:
                self.add(FAIL, ANIMATION, "clip_without_frames", path, clip["id"])
            for frame_index, frame in enumerate(clip["frames"]):
                frame_path = f"{path}.frames[{frame_index}]"
                image, rect = self.images.get(frame["image"]), frame["rect"]
                if rect is not None:
                    x, y, width, height = rect
                    if width <= 0 or height <= 0:
                        self.add(FAIL, ANIMATION, "source_rect_empty", f"{frame_path}.rect", rect)
                    elif image and (x + width > image["width"] or y + height > image["height"]):
                        self.add(FAIL, ANIMATION, "source_rect_outside_image", f"{frame_path}.rect",
                                 f"{rect} does not fit {image['width']}x{image['height']}")
                size = self._frame_size(frame)
                if size:
                    sizes.add(size)
        if len(sizes) > 1:
            self.add(WARNING, ANIMATION, "mixed_frame_sizes", "animations.clips",
                     "One visual_offset serves every clip, so frames of different sizes will not line up: "
                     + ", ".join(f"{w}x{h}" for w, h in sorted(sizes)))
        roles = data["presentation"]["roles"]
        if not self.clips:
            self.add(WARNING, ANIMATION, "no_animation", "animations.clips",
                     "The actor will be drawn with its placeholder polygon.")
        else:
            for role in REQUIRED_ROLES:
                if not roles[role]:
                    self.add(FAIL, ANIMATION, "required_role_missing", f"presentation.roles.{role}",
                             "EnemyAnimationProfile needs idle, move, attack, hurt and death.")
        for role, clip_id in roles.items():
            clip = self.clips.get(clip_id)
            if clip is None:
                continue
            if role in LOOPING_ROLES and not clip["loop"]:
                self.add(FAIL, ANIMATION, "held_role_must_loop", f"presentation.roles.{role}", clip_id)
            # A clip may serve a looping role and a one-shot role only if it loops for the former.
            elif role in ONE_SHOT_ROLES and clip["loop"] and not any(
                    roles[other] == clip_id for other in LOOPING_ROLES):
                self.add(FAIL, ANIMATION, "one_shot_role_must_not_loop", f"presentation.roles.{role}", clip_id)
        attack = self.clips.get(roles["attack"])
        hit_frame = data["presentation"]["attack_hit_frame"]
        if attack is not None and attack["frames"] and hit_frame >= len(attack["frames"]):
            self.add(FAIL, ANIMATION, "attack_hit_frame_out_of_range", "presentation.attack_hit_frame",
                     f"{roles['attack']} has {len(attack['frames'])} frames")
        self._clip_fits_gameplay(attack, hit_frame)

    def _clip_fits_gameplay(self, attack, hit_frame):
        """Clips are drawn, never obeyed. A clip that disagrees with gameplay time is only a warning."""
        roles = self.data["presentation"]["roles"]

        def longer(clip_id, limit, path, what):
            clip = self.clips.get(clip_id)
            if clip is not None and clip["frames"] and not clip["loop"] \
                    and clip_seconds(clip) > limit + TIME_TOLERANCE:
                self.add(WARNING, ANIMATION, "clip_longer_than_gameplay", path,
                         f"{clip_id} lasts {clip_seconds(clip):.3f} s but {what} lasts {limit:.3f} s")

        for index, state in enumerate(self.data["behavior"]["states"]):
            path, params = f"behavior.states[{index}]", state["params"]
            if state["module"] == "HurtReaction":
                longer(roles["hurt"], params["seconds"], path, "the hurt state")
            elif state["module"] == "Death":
                longer(roles["death"], params["removal_seconds"], path, "the body before removal")
            elif state["module"] == "Hop":
                longer(roles["jump_start"], params["prepare_seconds"], path, "the crouch")
        half_tick = 0.5 / self.tick_rate
        for index, pattern in enumerate(self.data["attack_patterns"]):
            path = f"attack_patterns[{index}]"
            longer(pattern["clip"], pattern["duration"], path, "the pattern")
            commits = sorted(event["time"] for event in pattern["events"] if EVENTS[event["type"]].side == GAMEPLAY)
            clip = self.clips.get(pattern["clip"])
            if commits and clip is not None and clip is attack and hit_frame < len(clip["frames"]):
                shown = frame_start_seconds(clip, hit_frame)
                if abs(shown - commits[0]) > half_tick + TIME_TOLERANCE:
                    self.add(WARNING, ANIMATION, "hit_frame_mismatch", "presentation.attack_hit_frame",
                             f"frame {hit_frame} starts at {shown:.3f} s but {pattern['id']} commits at "
                             f"{commits[0]:.3f} s")

    # -- collision --------------------------------------------------------------------------------------------
    def collision(self):
        collision = self.data["collision"]
        body = collision["body"]
        if (body["layer"], body["mask"]) != (1, 1):
            self.add(WARNING, COLLISION, "nonstandard_body_layer", "collision.body",
                     f"layer {body['layer']} / mask {body['mask']}; the project convention is 1 / 1")
        if not any(row["enabled"] for row in collision["hurtboxes"]):
            self.add(WARNING, COLLISION, "no_enabled_hurtbox", "collision.hurtboxes",
                     "Nothing can hit this monster by default.")
        used = {event["hitbox"] for pattern in self.data["attack_patterns"] for event in pattern["events"]
                if event["type"] == "EnableHitbox"}
        for index, row in enumerate(collision["hitboxes"]):
            if row["id"] not in used:
                self.add(WARNING, COLLISION, "unused_hitbox", f"collision.hitboxes[{index}]", row["id"])

    # -- attack -----------------------------------------------------------------------------------------------
    def attack(self):
        stats = self.data["stats"]
        for index, pattern in enumerate(self.data["attack_patterns"]):
            path = f"attack_patterns[{index}]"
            duration = pattern["duration"]
            instant = any(event["type"] == "RangeStrike" for event in pattern["events"])
            actives = self._phases(pattern, path, instant)
            # A legacy strike is an instant between wind-up and recovery, so it needs no active window.
            windup_ends = [(phase["end"], phase["end"]) for phase in pattern["phases"] if phase["kind"] == "windup"]
            events = sorted(enumerate(pattern["events"]), key=lambda row: row[1]["time"])
            live, damaging = {}, False
            for event_index, event in events:
                event_path = f"{path}.events[{event_index}]"
                kind, time = event["type"], event["time"]
                damaging = damaging or kind in DAMAGING_EVENTS
                if time > duration + TIME_TOLERANCE:
                    self.add(FAIL, ATTACK, "event_after_pattern_end", f"{event_path}.time",
                             f"{time} s is after the pattern's {duration} s")
                    continue
                if kind == "RangeStrike" and not any(start - TIME_TOLERANCE <= time <= end + TIME_TOLERANCE
                                                    for start, end in actives + windup_ends):
                    self.add(FAIL, ATTACK, "strike_outside_active_phase", f"{event_path}.time", time)
                elif kind == "EnableHitbox":
                    if event["hitbox"] in live:
                        self.add(FAIL, ATTACK, "hitbox_already_enabled", event_path, event["hitbox"])
                    else:
                        live[event["hitbox"]] = (time, event_path)
                elif kind == "DisableHitbox":
                    if event["hitbox"] not in live:
                        self.add(FAIL, ATTACK, "hitbox_disabled_before_enabled", event_path, event["hitbox"])
                    else:
                        self._hitbox_window(*live.pop(event["hitbox"]), time, actives)
            for start, event_path in live.values():
                # No DisableHitbox: the hitbox is released when the pattern ends.
                self._hitbox_window(start, event_path, duration, actives)
            if not damaging:
                self.add(WARNING, ATTACK, "pattern_without_hit", path, pattern["id"])
            damage = pattern["damage"]
            if damage["hit_policy"] == "multi_hit":
                if tick_of(damage["multi_hit_interval"], self.tick_rate) < 1:
                    self.add(FAIL, ATTACK, "multi_hit_interval_below_one_tick", f"{path}.damage.multi_hit_interval")
                if not any(event["type"] == "EnableHitbox" for event in pattern["events"]):
                    self.add(WARNING, ATTACK, "multi_hit_without_hitbox", f"{path}.damage.hit_policy",
                             "Only a hitbox that stays armed can hit repeatedly.")
            low, high = resolve(pattern["range"]["min"], stats), resolve(pattern["range"]["max"], stats)
            if low > high:
                self.add(FAIL, ATTACK, "range_order", f"{path}.range", f"min {low} > max {high}")
            if pattern["completion"]["mode"] == "duration_and_landed" and not any(
                    event["type"] == "ApplyImpulse" for event in pattern["events"]):
                self.add(WARNING, ATTACK, "landing_without_impulse", f"{path}.completion",
                         "The pattern waits for a landing but never leaves the ground.")

    def _phases(self, pattern, path, instant):
        phases = pattern["phases"]
        if not phases:
            self.add(FAIL, ATTACK, "phases_missing", f"{path}.phases")
            return []
        ordered = True
        for index, phase in enumerate(phases):
            if phase["end"] <= phase["start"]:
                ordered = False
                self.add(FAIL, ATTACK, "phase_ends_before_it_starts", f"{path}.phases[{index}]",
                         f"start {phase['start']}, end {phase['end']}")
        expected = 0
        for index, phase in enumerate(phases):
            if ordered and abs(phase["start"] - expected) > TIME_TOLERANCE:
                self.add(FAIL, ATTACK, "phases_not_contiguous", f"{path}.phases[{index}].start",
                         f"expected {expected}, found {phase['start']}")
            expected = phase["end"]
        if ordered and abs(expected - pattern["duration"]) > TIME_TOLERANCE:
            self.add(FAIL, ATTACK, "phases_do_not_fill_duration", f"{path}.phases",
                     f"phases end at {expected} s, the pattern lasts {pattern['duration']} s")
        actives = [(phase["start"], phase["end"]) for phase in phases if phase["kind"] == "active"]
        if not actives and not instant:
            self.add(WARNING, ATTACK, "no_active_phase", f"{path}.phases")
        for index, phase in enumerate(phases):
            if phase["end"] > phase["start"] and window_ticks(phase["start"], phase["end"], self.tick_rate) == 0:
                self.add(FAIL, ATTACK, "window_shorter_than_one_tick", f"{path}.phases[{index}]",
                         f"{phase['kind']} {phase['start']}..{phase['end']} s has no physics tick at "
                         f"{self.tick_rate} Hz")
        return actives

    def _hitbox_window(self, start, event_path, end, actives):
        if not any(low - TIME_TOLERANCE <= start and end <= high + TIME_TOLERANCE for low, high in actives):
            self.add(FAIL, ATTACK, "hitbox_outside_active_phase", event_path, f"armed {start}..{end} s")
        elif window_ticks(start, end, self.tick_rate) == 0:
            self.add(FAIL, ATTACK, "window_shorter_than_one_tick", event_path, f"armed {start}..{end} s")

    # -- AI ---------------------------------------------------------------------------------------------------
    def ai(self):
        behavior = self.data["behavior"]
        states = behavior["states"]
        if not states:
            self.add(FAIL, AI, "no_states", "behavior.states")
            return
        if behavior["initial_state"] not in self.states:
            self.add(FAIL, AI, "initial_state_missing", "behavior.initial_state", behavior["initial_state"])
        hurt, death = behavior["interrupts"]["hurt"], behavior["interrupts"]["death"]
        if hurt["policy"] == "always" and not hurt["state"]:
            self.add(FAIL, AI, "hurt_state_missing", "behavior.interrupts.hurt.state")
        hurt_state, death_state = self.states.get(hurt["state"]), self.states.get(death["state"])
        if hurt_state is not None and hurt_state["module"] != "HurtReaction":
            self.add(WARNING, AI, "hurt_state_without_hurt_reaction", "behavior.interrupts.hurt.state", hurt["state"])
        if death_state is not None and not getattr(MODULES.get(death_state["module"]), "terminal", False):
            self.add(FAIL, AI, "death_state_not_terminal", "behavior.interrupts.death.state", death["state"])
        immediate = {}
        for index, state in enumerate(states):
            path = f"behavior.states[{index}]"
            module = MODULES.get(state["module"])
            if module is None:
                reserved = state["module"] in RESERVED_MODULES
                self.add(FAIL, AI, "module_not_available" if reserved else "unknown_module", f"{path}.module",
                         state["module"] + (" is reserved for a later step" if reserved else ""))
                continue
            if state["module"] == "ExecuteAttackPattern" and not self.patterns:
                self.add(FAIL, AI, "no_attack_patterns", path, state["id"])
            if module.terminal:
                if state["transitions"]:
                    self.add(WARNING, AI, "transition_never_fires", f"{path}.transitions",
                             f"{state['module']} never leaves its state")
                continue
            never = set()
            # An endless hop toward a target has no natural end; only patrol budgets and arrivals finish.
            completes = module.completes and not (
                state["module"] == "Hop" and state["params"]["count"] == 0 and state["params"]["toward"] != "origin")
            if not completes:
                never.add("ActionCompleted")
            if not module.can_fail and state["max_seconds"] is None:
                never.add("ActionFailed")
            if state["module"] != "ExecuteAttackPattern":
                never.add("AttackPatternCompleted")
            ordered = sorted(enumerate(state["transitions"]), key=lambda row: (-row[1]["priority"], row[0]))
            usable, shadow = 0, None
            for transition_index, transition in ordered:
                transition_path = f"{path}.transitions[{transition_index}]"
                if shadow is not None:
                    self.add(WARNING, AI, "transition_shadowed", transition_path,
                             f"an unconditional transition to {shadow} is evaluated first")
                    continue
                if not _can_fire(transition["condition"], never):
                    self.add(WARNING, AI, "transition_never_fires", transition_path,
                             f"{state['module']} never raises that event")
                    continue
                usable += 1
                if _always_true(transition["condition"]):
                    shadow = transition["to"]
                    immediate[state["id"]] = transition["to"]
            if usable == 0:
                self.add(FAIL, AI, "state_never_exits", path,
                         f"{state['id']} has no transition that can fire, so the monster stays there forever")
            elif completes and not any(
                    leaf["type"] in ("ActionCompleted", "AttackPatternCompleted")
                    for transition in state["transitions"] for _, leaf in condition_leaves(transition["condition"])):
                self.add(WARNING, AI, "completion_unhandled", path,
                         f"{state['module']} finishes but no transition reacts to it")
        self._reachability(behavior, hurt, death)
        self._immediate_cycles(immediate)

    def _reachability(self, behavior, hurt, death):
        frontier = [behavior["initial_state"], death["state"]] + ([hurt["state"]] if hurt["policy"] == "always" else [])
        frontier += [phase["enter_state"] for phase in behavior["phases"]]
        reached = set()
        while frontier:
            state = self.states.get(frontier.pop())
            if state is None or state["id"] in reached:
                continue
            reached.add(state["id"])
            frontier.extend(transition["to"] for transition in state["transitions"])
        for index, state in enumerate(behavior["states"]):
            if state["id"] not in reached:
                self.add(WARNING, AI, "unreachable_state", f"behavior.states[{index}]", state["id"])

    def _immediate_cycles(self, immediate):
        reported = set()
        for start in immediate:
            trail, current = [], start
            while current in immediate and current not in trail:
                trail.append(current)
                current = immediate[current]
            if current in trail:
                cycle = trail[trail.index(current):]
                key = frozenset(cycle)
                if key not in reported:
                    reported.add(key)
                    self.add(FAIL, AI, "immediate_transition_cycle", "behavior.states",
                             " -> ".join(cycle + [current]) + " never waits for anything")

    # -- compatibility ----------------------------------------------------------------------------------------
    def compatibility(self):
        data = self.data
        for path in _planned_paths(DOCUMENT, data):
            self.add(WARNING, COMPATIBILITY, "value_not_applied_by_any_runtime", path)
        for index, state in enumerate(data["behavior"]["states"]):
            path = f"behavior.states[{index}]"
            module = MODULES.get(state["module"])
            if module is not None and module.support == PLANNED:
                self.add(WARNING, COMPATIBILITY, "planned_module", f"{path}.module", state["module"])
            for transition_index, transition in enumerate(state["transitions"]):
                for leaf_path, leaf in condition_leaves(
                        transition["condition"], f"{path}.transitions[{transition_index}].condition"):
                    if CONDITIONS[leaf["type"]].support == PLANNED:
                        self.add(WARNING, COMPATIBILITY, "planned_condition", leaf_path, leaf["type"])
        for index, pattern in enumerate(data["attack_patterns"]):
            for event_index, event in enumerate(pattern["events"]):
                if EVENTS[event["type"]].support == PLANNED:
                    self.add(WARNING, COMPATIBILITY, "planned_event",
                             f"attack_patterns[{index}].events[{event_index}]", event["type"])
        binding = data["source_binding"]
        if binding is None:
            return
        for index, row in enumerate(binding["files"]):
            if not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
                self.add(FAIL, COMPATIBILITY, "invalid_hash", f"source_binding.files[{index}].sha256")
        if self.project is None:
            self.add(NOT_EVALUATED, COMPATIBILITY, "source_files_unchecked", "source_binding.files",
                     "No project folder was given.")
            return
        for path, state in project_files.source_states(self.doc, self.project):
            if state == project_files.MISSING:
                self.add(FAIL, COMPATIBILITY, "source_missing", "source_binding.files", path)
            elif state == project_files.MODIFIED:
                self.add(WARNING, COMPATIBILITY, "source_changed", "source_binding.files",
                         f"{path} changed in the project since this document was derived from it")


def validate(document, project=None, tick_rate=DEFAULT_TICK_RATE):
    """Run every static check. ``project`` enables the checks that read project files."""
    return _Validator(document, project, tick_rate).run()
