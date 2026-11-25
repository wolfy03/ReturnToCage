"""GATE E: the contract evaluation, exercised on a recorded probe.

``fixtures/contract_probe.json`` is real output of tools/monster_bridge/contract_probe.tscn
(Godot 4.7.2), recorded when the examples were last verified. These tests do
not run Godot; they prove how the evaluation reacts to what a probe reports -
in particular to an enemy nobody wrote an example for. The run against the
live engine is check_godot_contract.py, and check_contract_extensibility.py
repeats the new-enemy scenario with a real Godot on an isolated project copy.
"""

import copy
import json
import sys
from pathlib import Path

import pytest

from conftest import EXAMPLES, PROJECT, edit, load

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import godot_contract as contract  # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures/contract_probe.json"
STATIC_IDS = ("frog", "sewer_beetle")


@pytest.fixture
def probe():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


@pytest.fixture
def documents():
    return {name: load(name) for name in ("sewer_beetle", "frog", "sewer_rat_prototype")}


def run(probe, documents, clean=True, static_ids=None, profiles=None):
    ids = sorted(probe["enemies"]) if static_ids is None else static_ids
    report, _stale = contract.evaluate(probe, documents, PROJECT, "4.7.2", clean, ids, profiles)
    return report


def failures(report, section=None):
    return {(row.monster, row.name) for row in report.failed if section in (None, row.section)}


def new_enemy(probe, monster_id="cave_gnat", source="sewer_beetle"):
    """Register one more enemy in the probe, as the game would report a newly added one."""
    entry = copy.deepcopy(probe["enemies"][source])
    entry["definition_path"] = f"res://data/content/enemies/{monster_id}.tres"
    entry["display_name"] = "Cave Gnat"
    entry["max_health"] = 9.0
    probe["enemies"][monster_id] = entry
    return entry


# -------------------------------------------------------------------------------------------------- baseline
def test_the_recorded_probe_and_the_examples_agree(probe, documents):
    report = run(probe, documents)
    assert report.ok, sorted(failures(report))
    assert report.summary() == {"environment": "PASS", "registry": "PASS", "legacy": "PASS",
                                "data_driven": "NOT_EVALUATED", "behavior": "NOT_EVALUATED"}
    assert len(report.passed) > 190
    assert {row.monster for row in report.results if row.section == "legacy"} == {"sewer_beetle", "frog"}
    assert {row.monster for row in report.results if row.section == "registry"} == {
        "sewer_beetle", "frog", "sewer_rat_prototype"}


def test_the_data_driven_contract_is_never_passed_by_anything(probe, documents):
    report = run(probe, documents)
    rows = [row for row in report.results if row.section == "data_driven"]
    assert rows and all(row.status == "NOT_EVALUATED" for row in rows)
    assert any(row.status == "NOT_EVALUATED" for row in report.results if row.section == "behavior")


# ------------------------------------------------------------------------------------- a new enemy appears
def test_a_new_enemy_is_checked_by_the_registry_contract_and_needs_no_example(probe, documents):
    new_enemy(probe)
    report = run(probe, documents)
    assert report.ok, sorted(failures(report))
    checked = [row for row in report.results if row.monster == "cave_gnat"]
    assert len(checked) >= 14 and {row.section for row in checked} == {"registry"}
    assert all(row.status == "PASS" for row in checked)
    assert "cave_gnat" not in {row.monster for row in report.results if row.section == "legacy"}


@pytest.mark.parametrize("damage, expected", [
    (lambda e: e.update(definition_errors=["cave_gnat: missing loot table x"]), "EnemyDefinition validates"),
    (lambda e: e["components"].update(hurtbox=False), "actor has the hurtbox component"),
    (lambda e: e["components"].update(health=False), "actor has the health component"),
    (lambda e: e.update(max_health=0.0), "stats are positive and finite"),
    (lambda e: e.update(move_speed=float("nan")), "stats are positive and finite"),
    (lambda e: e.update(body=[]), "has a body collision shape"),
    (lambda e: e["hurtbox"].update(shapes=[]), "hurtbox has a shape"),
    (lambda e: e["hurtbox"].update(collision_layer=1), "hurtbox layer/mask follows the project convention"),
    (lambda e: e.pop("loot"), "loot table exists"),
    (lambda e: e["loot"].update(item_ids=["gold_bar"]), "loot items exist"),
    (lambda e: e["profile"].update(errors=["missing required animation: hurt"]),
     "animation profile loads and validates"),
    (lambda e: e["run"].update(instantiated=False), "actor scene instantiates and runs"),
    (lambda e: e["run"].update(states_seen=[]), "actor enters a state"),
    (lambda e: e["run"].update(presenter_in_server_mode=True), "server-mode actor creates no presenter"),
    (lambda e: e["run"].update(presenter_in_presentation_mode=False),
     "presentation-mode actor creates its presenter"),
    (lambda e: e.update(agent_script=""), "has an actor scene whose root is an EnemyAgent"),
    (lambda e: e.update(definition_path="res://tests/fixtures/gnat.tres"),
     "definition path is under data/content/enemies"),
])
def test_a_broken_new_enemy_fails_the_registry_contract_and_only_that(probe, documents, damage, expected):
    damage(new_enemy(probe))
    report = run(probe, documents)
    assert ("cave_gnat", expected) in failures(report, "registry")
    assert failures(report, "legacy") == set() and report.section("legacy") == "PASS"
    assert report.section("registry") == "FAIL" and not report.ok


def test_a_new_enemy_is_not_exempt_from_the_catalog_comparison(probe, documents):
    new_enemy(probe)
    report = run(probe, documents, static_ids=STATIC_IDS)       # the game has it, the files on disk do not
    assert ("", "static catalog scan agrees with ContentRegistry") in failures(report, "environment")


# ------------------------------------------------------------------------------- baselines stay pinned
def test_a_missing_baseline_example_is_an_error(probe, documents):
    del documents["frog"]
    report = run(probe, documents)
    assert failures(report, "legacy") == {("frog", "baseline monster has an example document")}


def test_a_baseline_removed_from_the_game_is_an_error(probe, documents):
    del probe["enemies"]["frog"]
    assert ("frog", "baseline monster is registered in the game") in failures(run(probe, documents), "legacy")


@pytest.mark.parametrize("monster, change, name", [
    ("sewer_beetle", lambda d: d["stats"].update(max_health=25), "stats.max_health"),
    ("sewer_beetle", lambda d: d["collision"]["body"]["shape"].update(size=[36, 22]), "body shape"),
    ("sewer_beetle", lambda d: d["attack_patterns"][0]["events"][0].update(time=0.25), "attack commit time"),
    ("sewer_beetle", lambda d: d["animations"]["clips"][2].update(fps=12), "clip attack fps/loop"),
    ("sewer_beetle", lambda d: d["behavior"]["states"][5]["params"].update(removal_seconds=0.5),
     "death removal time"),
    ("sewer_beetle", lambda d: d["loot"]["entries"][0].update(weight=4), "loot entries"),
    ("frog", lambda d: d["behavior"]["states"][3]["params"].update(lift=341), "chase hop lift"),
    ("frog", lambda d: d["attack_patterns"][0].update(cooldown=1.3), "attack cooldown"),
    ("frog", lambda d: d["sensors"].update(leash_distance=500), "sensors.leash_distance"),
    ("frog", lambda d: d["presentation"].update(visual_offset=[0, -19]), "presentation.visual_offset"),
    ("frog", lambda d: d["collision"]["hitboxes"][0]["shape"].update(size=[90, 80]), "contact box"),
])
def test_every_pinned_value_of_a_baseline_is_still_compared(probe, documents, monster, change, name):
    documents[monster] = edit(documents[monster], change)
    assert (monster, name) in failures(run(probe, documents), "legacy")


def test_a_change_in_the_game_is_caught_from_the_other_side(probe, documents):
    probe["enemies"]["frog"]["agent_properties"]["patrol_radius"] = 200.0
    probe["enemies"]["sewer_beetle"]["attack_range"] = 50.0
    assert failures(run(probe, documents), "legacy") == {("frog", "patrol radius"),
                                                         ("sewer_beetle", "stats.attack_range")}


def test_a_profile_that_does_not_fit_is_reported_not_raised(probe, documents):
    profiles = {"sewer_beetle": contract.LegacyProfile("lunge", "bite", "dead")}
    report = run(probe, documents, profiles=profiles)
    assert ("sewer_beetle", "example and game have the structure the profile expects") in failures(report, "legacy")


def test_baselines_are_an_explicit_list(probe, documents):
    assert set(contract.LEGACY_PROFILES) == {"sewer_beetle", "frog"}
    new_enemy(probe, "frog_elder", "frog")
    report = run(probe, documents)
    assert report.ok and "frog_elder" not in {row.monster for row in report.results if row.section == "legacy"}


# ------------------------------------------------------------------------------------ environment and drafts
def test_an_unclean_engine_log_fails_even_when_every_value_matches(probe, documents):
    report = run(probe, documents, clean=False)
    assert failures(report) == {("", "Godot ran without errors, warnings or leaks")}


@pytest.mark.parametrize("change, name", [
    (lambda p: p.update(godot_version="4.8.0-stable (official)"), "Godot is the pinned version"),
    (lambda p: p.update(physics_ticks_per_second=120), "physics tick rate is the validator's default"),
    (lambda p: p.update(network_protocol_version=21), "network protocol version is unchanged"),
    (lambda p: p.update(snapshot_states=["IDLE", "MOVING"]), "EnemyRuntimeSnapshot.State names"),
    (lambda p: p.update(content_errors=["boom"]), "ContentRegistry validates"),
])
def test_environment_drift_is_reported(probe, documents, change, name):
    change(probe)
    assert ("", name) in failures(run(probe, documents), "environment")


def test_a_draft_that_became_game_content_is_reported(probe, documents):
    new_enemy(probe, "sewer_rat_prototype")
    assert ("sewer_rat_prototype", "draft is not registered game content") in failures(run(probe, documents))


def test_the_fixture_is_a_real_probe_of_the_pinned_engine(probe):
    assert probe["protocol"] == 1 and probe["godot_version"].startswith("4.7.2-")
    assert set(probe["enemies"]) == set(STATIC_IDS) and (EXAMPLES / "frog.rtcmonster").is_file()
    for entry in probe["enemies"].values():
        assert entry["components"] == {"health": True, "hurtbox": True, "network_enemy": True, "states": True}
