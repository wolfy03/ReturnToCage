import pytest

from conftest import EXAMPLE_IDS, PROJECT, edit, load
from rtcmonster import DOMAINS, FAIL, NOT_EVALUATED, PASS, WARNING, duplicate_monster_ids, new_document, validate
from rtcmonster.modules import CONDITIONS, EVENTS, MODULES, RESERVED_MODULES
from rtcmonster.validation import STATIC_DOMAINS, summarize


def states(data):
    return {row["id"]: row for row in data["behavior"]["states"]}


def go(to, condition, priority=0):
    return {"to": to, "priority": priority, "condition": condition}


ALWAYS = {"type": "Always"}
BOX = {"type": "rectangle", "center": [0, 0], "size": [10, 10]}


# ---------------------------------------------------------------------------------------------- report semantics
def test_status_order_and_empty_domains():
    assert summarize([PASS, WARNING, FAIL, NOT_EVALUATED]) == FAIL
    assert summarize([PASS, WARNING, NOT_EVALUATED]) == WARNING
    assert summarize([PASS, NOT_EVALUATED]) == NOT_EVALUATED
    assert summarize([PASS]) == PASS and summarize([]) == NOT_EVALUATED


@pytest.mark.parametrize("name", EXAMPLE_IDS)
def test_static_validation_never_claims_runtime_network_or_publish(name):
    for project in (None, PROJECT):
        summary = validate(load(name), project).summary()
        assert tuple(summary) == DOMAINS
        assert summary["runtime"] == NOT_EVALUATED and summary["network"] == NOT_EVALUATED
        assert summary["publish"] in (NOT_EVALUATED, FAIL)


def test_checks_that_need_the_project_are_not_evaluated_without_it(beetle):
    report = validate(beetle)
    assert report.status("assets") == NOT_EVALUATED and report.status("references") == NOT_EVALUATED
    assert report.status("compatibility") == NOT_EVALUATED
    assert {item.code for item in report.select(NOT_EVALUATED)} >= {
        "asset_files_unchecked", "monster_id_uniqueness_unchecked", "loot_reference_unchecked",
        "source_files_unchecked"}
    assert not report.select(FAIL)


def test_the_beetle_example_passes_every_static_domain_against_the_project(beetle):
    report = validate(beetle, PROJECT)
    assert {domain: report.status(domain) for domain in STATIC_DOMAINS} == dict.fromkeys(STATIC_DOMAINS, PASS)
    assert report.static_status == PASS and report.overall == NOT_EVALUATED


def test_the_frog_example_reports_its_two_unrepresentable_parts(frog):
    report = validate(frog, PROJECT)
    assert not [item for item in report.select(FAIL) if item.domain in STATIC_DOMAINS]
    blocked = report.select(FAIL, "publish", "export_blocked_unsupported")
    assert len(blocked) == 2 and report.status("publish") == FAIL
    assert {item.code for item in report.select(WARNING)} == {"value_not_applied_by_any_runtime", "planned_event"}


def test_the_rat_prototype_is_a_draft_that_uses_planned_features(rat):
    report = validate(rat, PROJECT)
    assert rat.data["source_binding"] is None and not report.select(FAIL)
    assert report.codes(WARNING) == {"no_animation", "value_not_applied_by_any_runtime", "planned_event"}
    assert rat.data["editor_metadata"]["estimated"] == ["stats", "collision", "attack_patterns", "behavior", "loot"]


# ------------------------------------------------------------------------------------------------ failure table
def _dup(section, *path):
    def change(data):
        rows = data[section]
        for key in path:
            rows = rows[key]
        rows.append(dict(rows[0]))
    return change


def _hitbox_events(*events):
    def change(data):
        data["attack_patterns"][0]["events"] = [
            {"type": kind, "time": time, "hitbox": "bite_box"} for kind, time in events]
    return change


FAILURES = [
    # (example, mutation, domain, code)
    ("frog", _dup("assets", "images"), "references", "duplicate_image_id"),
    ("frog", _dup("animations", "clips"), "references", "duplicate_animation_id"),
    ("frog", _dup("collision", "hurtboxes"), "references", "duplicate_hurtbox_id"),
    ("frog", _dup("collision", "hitboxes"), "references", "duplicate_hitbox_id"),
    ("frog", lambda d: d["attack_patterns"].append(dict(d["attack_patterns"][0])), "references",
     "duplicate_pattern_id"),
    ("frog", _dup("behavior", "states"), "references", "duplicate_state_id"),
    ("frog", lambda d: d["animations"]["clips"][0]["frames"][0].update(image="ghost"), "references", "unknown_image"),
    ("frog", lambda d: d["presentation"]["roles"].update(idle="ghost"), "references", "unknown_animation"),
    ("frog", lambda d: d["attack_patterns"][0].update(clip="ghost"), "references", "unknown_animation"),
    ("frog", lambda d: d["attack_patterns"][0]["events"][1].update(hitbox="ghost"), "references", "unknown_hitbox"),
    ("frog", lambda d: states(d)["idle"]["transitions"][0].update(to="ghost"), "references", "unknown_state"),
    ("frog", lambda d: d["behavior"]["interrupts"]["death"].update(state="ghost"), "references", "unknown_state"),
    ("frog", lambda d: states(d)["attack"]["params"].update(pattern="ghost"), "references", "unknown_pattern"),
    ("frog", lambda d: states(d)["chase"]["transitions"][1]["condition"].update(pattern="ghost"), "references",
     "unknown_pattern"),
    ("frog", lambda d: states(d)["idle"]["animation"].update(mode="clip", clip="ghost"), "references",
     "unknown_animation"),
    ("frog", lambda d: d["collision"]["hurtbox_overrides"].append({"clip": "attack", "frame": 6, "boxes": []}),
     "references", "frame_out_of_range"),
    ("frog", lambda d: d["collision"]["hurtbox_overrides"].extend(
        [{"clip": "attack", "frame": 1, "boxes": []}] * 2), "references", "duplicate_hurtbox_override"),
    ("sewer_beetle", lambda d: d["stats"].update(max_health=-5), "schema", "out_of_range"),
    ("sewer_beetle", lambda d: d["stats"].update(max_health=0), "schema", "out_of_range"),
    ("sewer_beetle", lambda d: d["stats"].update(move_speed=1001), "schema", "out_of_range"),
    ("sewer_beetle", lambda d: d["loot"]["entries"][0].update(min_amount=3, max_amount=2), "schema",
     "loot_amount_order"),
    ("sewer_beetle", lambda d: d["loot"].update(loot_table_id=""), "schema", "loot_table_id_missing"),
    ("sewer_beetle", lambda d: d["assets"]["images"][0].update(sha256="xyz"), "assets", "invalid_hash"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0].update(fps=0), "animation", "out_of_range"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0]["frames"][0].update(duration=0), "animation",
     "out_of_range"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0]["frames"][0].update(duration=-1), "animation",
     "out_of_range"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0].update(frames=[]), "animation", "clip_without_frames"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0]["frames"][3].update(rect=[224, 0, 64, 48]), "animation",
     "source_rect_outside_image"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0]["frames"][0].update(rect=[0, 0, 0, 48]), "animation",
     "source_rect_empty"),
    ("sewer_beetle", lambda d: d["presentation"]["roles"].update(hurt=""), "animation", "required_role_missing"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0].update(loop=False), "animation", "held_role_must_loop"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][2].update(loop=True), "animation",
     "one_shot_role_must_not_loop"),
    ("sewer_beetle", lambda d: d["presentation"].update(attack_hit_frame=7), "animation",
     "attack_hit_frame_out_of_range"),
    ("sewer_beetle", lambda d: d["presentation"].update(visual_scale=[0, 1]), "animation", "out_of_range"),
    ("sewer_beetle", lambda d: d["collision"]["body"]["shape"].update(size=[0, 22]), "collision", "out_of_range"),
    ("sewer_beetle", lambda d: d["collision"]["hurtboxes"][0]["shape"].update(size=[40, -1]), "collision",
     "out_of_range"),
    ("sewer_rat_prototype", lambda d: d["collision"]["hurtboxes"][1]["shape"].update(radius=0), "collision",
     "out_of_range"),
    ("sewer_rat_prototype", lambda d: d["collision"]["hitboxes"][0]["shape"].update(center=[99999, 0]), "collision",
     "out_of_range"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0]["events"][1].update(time=0.6), "attack",
     "event_after_pattern_end"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0]["phases"][1].update(start=0.25, end=0.15), "attack",
     "phase_ends_before_it_starts"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0]["phases"][1].update(start=0.2), "attack",
     "phases_not_contiguous"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0].update(duration=0.6), "attack",
     "phases_do_not_fill_duration"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0].update(phases=[]), "attack", "phases_missing"),
    ("sewer_rat_prototype", _hitbox_events(("DisableHitbox", 0.15), ("EnableHitbox", 0.2), ("DisableHitbox", 0.25)),
     "attack", "hitbox_disabled_before_enabled"),
    ("sewer_rat_prototype", _hitbox_events(("EnableHitbox", 0.15), ("EnableHitbox", 0.2)), "attack",
     "hitbox_already_enabled"),
    ("sewer_rat_prototype", _hitbox_events(("EnableHitbox", 0.05), ("DisableHitbox", 0.25)), "attack",
     "hitbox_outside_active_phase"),
    ("sewer_rat_prototype", _hitbox_events(("EnableHitbox", 0.2),), "attack", "hitbox_outside_active_phase"),
    ("sewer_rat_prototype", _hitbox_events(("EnableHitbox", 0.201), ("DisableHitbox", 0.209)), "attack",
     "window_shorter_than_one_tick"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0]["phases"].__setitem__(slice(0, 2), [
        {"kind": "windup", "start": 0, "end": 0.241}, {"kind": "active", "start": 0.241, "end": 0.25}]), "attack",
     "window_shorter_than_one_tick"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][1]["range"].update(min=200), "attack", "range_order"),
    ("sewer_rat_prototype", lambda d: d["attack_patterns"][0]["damage"].update(
        hit_policy="multi_hit", multi_hit_interval=0.05) or d["attack_patterns"][0].update(cooldown=-1), "attack",
     "out_of_range"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0]["events"][0].update(time=0.1), "attack",
     "strike_outside_active_phase"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0]["events"][0].update(time=0.9), "attack",
     "event_after_pattern_end"),
    ("sewer_beetle", lambda d: d["behavior"].update(initial_state="ghost"), "ai", "initial_state_missing"),
    ("sewer_beetle", lambda d: d["behavior"].update(states=[]), "ai", "no_states"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(module="Teleport", params={}), "ai", "unknown_module"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(module="Dash", params={}), "ai", "module_not_available"),
    ("sewer_beetle", lambda d: states(d)["idle"]["params"].update(seconds=-1), "ai", "out_of_range"),
    ("sewer_beetle", lambda d: states(d)["patrol"].update(transitions=[]), "ai", "state_never_exits"),
    ("sewer_beetle", lambda d: states(d)["patrol"].update(transitions=[go("idle", {"type": "ActionCompleted"})]),
     "ai", "state_never_exits"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(transitions=[go("patrol", ALWAYS)])
     or states(d)["patrol"].update(transitions=[go("idle", {"all": [ALWAYS, ALWAYS]})]), "ai",
     "immediate_transition_cycle"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(transitions=[go("idle", ALWAYS)]), "ai",
     "immediate_transition_cycle"),
    ("sewer_beetle", lambda d: d["behavior"]["interrupts"]["death"].update(state="hurt"), "ai",
     "death_state_not_terminal"),
    ("sewer_beetle", lambda d: d["behavior"]["interrupts"]["hurt"].update(state=""), "ai", "hurt_state_missing"),
    ("sewer_beetle", lambda d: d.update(attack_patterns=[]) or states(d)["attack"]["params"].update(pattern=""),
     "ai", "no_attack_patterns"),
]


@pytest.mark.parametrize("name, change, domain, code", FAILURES, ids=[f"{row[3]}-{index}" for index, row in
                                                                      enumerate(FAILURES)])
def test_each_authoring_error_is_reported_in_its_domain(name, change, domain, code):
    baseline = validate(load(name))
    assert code not in baseline.codes()
    report = validate(edit(load(name), change))
    assert report.select(FAIL, domain, code), sorted(report.codes())
    assert report.status(domain) == FAIL and report.status("publish") == FAIL
    assert report.select(FAIL, "publish", "publish_blocked_by_failures")


WARNINGS = [
    ("sewer_beetle", lambda d: states(d)["patrol"]["transitions"].append(go("idle", ALWAYS, -5))
     or states(d)["patrol"]["transitions"].append(go("chase", ALWAYS, -9)), "ai", "transition_shadowed"),
    ("sewer_beetle", lambda d: d["behavior"]["states"].append(
        {"id": "lonely", "module": "Wait", "transitions": [go("idle", {"type": "ActionCompleted"})]}), "ai",
     "unreachable_state"),
    ("sewer_beetle", lambda d: states(d)["patrol"]["transitions"].append(go("idle", {"type": "ActionFailed"})), "ai",
     "transition_never_fires"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(
        transitions=[go("chase", {"type": "HasTarget"})]), "ai", "completion_unhandled"),
    ("sewer_beetle", lambda d: d["behavior"]["interrupts"]["hurt"].update(state="idle"), "ai",
     "hurt_state_without_hurt_reaction"),
    ("sewer_beetle", lambda d: d["stats"]["planned"].update(defense=3), "compatibility",
     "value_not_applied_by_any_runtime"),
    ("sewer_beetle", lambda d: d["metadata"].update(rank="boss"), "compatibility",
     "value_not_applied_by_any_runtime"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(interruptible=False), "compatibility",
     "value_not_applied_by_any_runtime"),
    ("sewer_beetle", lambda d: d["collision"]["hurtbox_overrides"].append(
        {"clip": "attack", "frame": None, "boxes": []}), "compatibility", "value_not_applied_by_any_runtime"),
    ("sewer_beetle", lambda d: states(d)["patrol"]["transitions"].append(
        go("idle", {"type": "HealthRatio", "op": "<", "value": 0.3})), "compatibility", "planned_condition"),
    ("sewer_beetle", lambda d: states(d)["idle"].update(module="ReturnToOrigin", params={}), "compatibility",
     "planned_module"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][3].update(fps=6), "animation", "clip_longer_than_gameplay"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][2].update(fps=5), "animation", "hit_frame_mismatch"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][0]["frames"][0].update(rect=[0, 0, 32, 48]), "animation",
     "mixed_frame_sizes"),
    ("sewer_beetle", lambda d: d["collision"]["hurtboxes"][0].update(enabled=False), "collision",
     "no_enabled_hurtbox"),
    ("sewer_beetle", lambda d: d["collision"]["body"].update(layer=3), "collision", "nonstandard_body_layer"),
    ("sewer_beetle", lambda d: d["collision"]["hitboxes"].append({"id": "spare", "shape": BOX}), "collision",
     "unused_hitbox"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0].update(events=[]), "attack", "pattern_without_hit"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0].update(events=[]), "attack", "no_active_phase"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0]["completion"].update(mode="duration_and_landed"), "attack",
     "landing_without_impulse"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0]["damage"].update(hit_policy="multi_hit"), "attack",
     "multi_hit_without_hitbox"),
]


@pytest.mark.parametrize("name, change, domain, code", WARNINGS, ids=[f"{row[3]}-{index}" for index, row in
                                                                      enumerate(WARNINGS)])
def test_suspicious_but_openable_documents_get_warnings(name, change, domain, code):
    assert not validate(load(name)).select(WARNING, domain, code)
    report = validate(edit(load(name), change))
    assert report.select(WARNING, domain, code), sorted(report.codes(WARNING))
    assert not report.select(FAIL, domain)


# ------------------------------------------------------------------------------------------ behaviour of the rules
def test_changing_a_clip_fps_never_changes_the_attack_timeline(beetle):
    from rtcmonster.timing import timeline
    faster = edit(beetle, lambda d: d["animations"]["clips"][2].update(fps=30))
    assert timeline(faster.data["attack_patterns"][0]) == timeline(beetle.data["attack_patterns"][0])
    report = validate(faster)
    assert not report.select(FAIL) and report.select(WARNING, "animation", "hit_frame_mismatch")


def test_a_validation_at_another_tick_rate_uses_that_rate(rat):
    narrow = edit(rat, lambda d: d["attack_patterns"][0]["phases"].__setitem__(slice(0, 3), [
        {"kind": "windup", "start": 0, "end": 0.15}, {"kind": "active", "start": 0.15, "end": 0.16},
        {"kind": "recovery", "start": 0.16, "end": 0.5}]) or d["attack_patterns"][0]["events"][1].update(time=0.16))
    assert "window_shorter_than_one_tick" in validate(narrow, tick_rate=30).codes()
    assert "window_shorter_than_one_tick" not in validate(narrow, tick_rate=120).codes()


def test_unconditional_transition_through_a_waiting_state_is_not_a_cycle(beetle):
    report = validate(edit(beetle, lambda d: states(d)["hurt"].update(transitions=[go("idle", ALWAYS)])))
    assert "immediate_transition_cycle" not in report.codes()


def test_a_never_policy_makes_the_hurt_state_optional(beetle):
    def change(data):
        data["behavior"]["interrupts"]["hurt"].update(state="", policy="never")
        data["behavior"]["states"] = [row for row in data["behavior"]["states"] if row["id"] != "hurt"]
    assert not validate(edit(beetle, change)).select(FAIL)


def test_an_explicitly_empty_hurtbox_override_differs_from_no_override(beetle):
    assert beetle.data["collision"]["hurtbox_overrides"] == []
    emptied = edit(beetle, lambda d: d["collision"]["hurtbox_overrides"].append(
        {"clip": "death", "frame": None, "boxes": []}))
    assert emptied != beetle and emptied.data["collision"]["hurtbox_overrides"][0]["boxes"] == []
    assert not validate(emptied).select(FAIL)


def test_catalog_duplicates_are_reported_for_every_copy():
    one, two, other = (new_document("moss_slug", "A"), new_document("moss_slug", "B"), new_document("ant", "C"))
    findings = duplicate_monster_ids([("a.rtcmonster", one), ("b.rtcmonster", two), ("c.rtcmonster", other)])
    assert [(item.status, item.code, item.path) for item in findings] == [
        (FAIL, "duplicate_monster_id", "a.rtcmonster"), (FAIL, "duplicate_monster_id", "b.rtcmonster")]


def test_registries_expose_what_an_inspector_needs():
    for module in MODULES.values():
        assert module.summary and module.category in ("movement", "combat")
        assert module.snapshot in ("IDLE", "MOVING", "ATTACKING", "HURT", "DEAD", "dynamic")
        for node in module.params.values():
            assert set(node.describe()) >= {"type", "default"}
    assert not set(RESERVED_MODULES) & set(MODULES)
    assert {entry.side for entry in EVENTS.values()} == {"gameplay", "presentation"}
    assert all(EVENTS[name].side == "presentation" for name in ("PlayAnimation", "SpawnEffect", "PlaySound"))
    assert "Always" in CONDITIONS and len(CONDITIONS) >= 18
