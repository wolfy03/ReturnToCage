"""Bridge client and legacy import.

The client is exercised against a stand-in executable: a real child process that behaves the way Godot can
misbehave (no response, a response to another request, a crash, a hang ...). Nothing in the client is
patched; process start, timeout, cancellation and response checking all run for real.

What these tests cannot say is whether the *real* engine answers correctly. That is
``check_godot_import.py``, which runs Godot against the project and against an isolated copy.
The importer tests use ``fixtures/contract_probe.json``, recorded output of the real probe.
"""

import copy
import json
from pathlib import Path
import threading
import time

import pytest

from conftest import PROJECT, load
from bridge import client, importer
from bridge.client import BridgeError
from rtcmonster import FAIL, validate

FIXTURE = Path(__file__).parent / "fixtures/contract_probe.json"
@pytest.fixture
def probe():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def environment(probe):
    return {key: probe[key] for key in ("godot_version", "physics_ticks_per_second", "network_protocol_version",
                                        "gravity", "target_keep_range_scale", "snapshot_states")}


# ------------------------------------------------------------------------------------------------- client
def test_a_good_response_is_accepted_and_checked(fake):
    godot, project, set_mode = fake
    set_mode("ok", data=json.dumps({"monsters": [{"monster_id": "ant", "agent_script":
                                                  "res://gameplay/actors/enemies/enemy_agent.gd"},
                                                 {"monster_id": "wasp", "agent_script": "res://x/wasp_agent.gd"}]}))
    response = client.inspect_monsters(godot, project)
    assert response.operation == "inspect_monsters" and len(response.request_id) == 32
    assert response.environment["godot_version"].startswith("4.7.2") and response.seconds > 0
    assert [(row["monster_id"], row["import_support"]) for row in response.data["monsters"]] == [
        ("ant", "complete"), ("wasp", "unsupported")]
    assert client.check_version(godot, project).startswith("4.7.2.")


@pytest.mark.parametrize("mode, code", [
    ("no_result", client.INVALID_RESPONSE), ("bad_json", client.INVALID_RESPONSE),
    ("not_an_object", client.INVALID_RESPONSE), ("no_data", client.INVALID_RESPONSE),
    ("wrong_request", client.RESPONSE_MISMATCH), ("wrong_protocol", client.RESPONSE_MISMATCH),
    ("wrong_operation", client.RESPONSE_MISMATCH), ("wrong_project", client.RESPONSE_MISMATCH),
    ("crash", client.PROCESS_CRASH), ("script_error", client.ENGINE_ERROR), ("fail", client.UNKNOWN_MONSTER),
])
def test_every_way_godot_can_answer_wrongly_is_a_coded_failure(fake, mode, code):
    godot, project, set_mode = fake
    set_mode(mode)
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "import_monster", "ghost")
    assert caught.value.code == code, caught.value
    assert isinstance(caught.value.log, str)


def test_a_missing_executable_and_a_wrong_project_are_reported(fake, tmp_path):
    godot, project, set_mode = fake
    with pytest.raises(BridgeError) as caught:
        client.call(tmp_path / "no_such_godot.exe", project, "inspect_monsters")
    assert caught.value.code == client.GODOT_MISSING
    with pytest.raises(BridgeError) as caught:
        client.call(godot, tmp_path, "inspect_monsters")
    assert caught.value.code == client.PROJECT_INVALID
    with pytest.raises(ValueError):
        client.call(godot, project, "delete_everything")
    set_mode("not_godot")
    with pytest.raises(BridgeError) as caught:
        client.godot_version(godot)
    assert caught.value.code == client.GODOT_MISSING


def test_a_godot_of_another_version_is_refused_before_anything_runs(fake):
    godot, project, set_mode = fake
    set_mode("ok", version="4.8.0.stable.official.abcdef")
    with pytest.raises(BridgeError) as caught:
        client.check_version(godot, project)
    assert caught.value.code == client.GODOT_VERSION_MISMATCH and "4.7.2" in caught.value.detail
    (project / ".godot-version").unlink()
    with pytest.raises(BridgeError) as caught:
        client.check_version(godot, project)
    assert caught.value.code == client.PROJECT_INVALID


def test_a_hanging_godot_times_out_and_is_stopped(fake):
    godot, project, set_mode = fake
    set_mode("hang", seconds=20)
    started = time.monotonic()
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "inspect_monsters", timeout=1.0)
    assert caught.value.code == client.TIMEOUT and time.monotonic() - started < 15


def test_cancelling_stops_the_call_promptly(fake):
    godot, project, set_mode = fake
    set_mode("hang", seconds=20)
    cancel = threading.Event()
    thread, box = client.threaded(client.call, godot, project, "inspect_monsters", cancel=cancel)
    time.sleep(0.6)
    started = time.monotonic()
    cancel.set()
    thread.join(15)
    assert not thread.is_alive() and time.monotonic() - started < 10
    assert isinstance(box.get("error"), BridgeError) and box["error"].code == client.CANCELLED
    already = threading.Event()
    already.set()
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "inspect_monsters", cancel=already)
    assert caught.value.code == client.CANCELLED


def test_a_response_about_another_monster_is_not_imported(fake):
    godot, project, set_mode = fake
    set_mode("ok", data=json.dumps({"monster_id": "frog", "monster": {}}))
    with pytest.raises(BridgeError) as caught:
        client.import_monster(godot, project, "sewer_beetle")
    assert caught.value.code == client.RESPONSE_MISMATCH


def test_the_request_and_response_files_never_land_in_the_project(fake):
    godot, project, _set_mode = fake
    before = sorted(path.relative_to(project).as_posix() for path in project.rglob("*"))
    client.call(godot, project, "inspect_monsters")
    assert sorted(path.relative_to(project).as_posix() for path in project.rglob("*")) == before


# ----------------------------------------------------------------------------------------------- importer
GAMEPLAY_SECTIONS = ("stats", "movement", "sensors", "presentation", "collision", "attack_patterns", "behavior",
                     "loot")


def clips_by_path(document):
    images = {row["id"]: row for row in document.data["assets"]["images"]}
    return {clip["id"]: (clip["fps"], clip["loop"],
                         [(images[frame["image"]]["path"], tuple(frame["rect"]), frame["duration"],
                           images[frame["image"]]["sha256"]) for frame in clip["frames"]])
            for clip in document.data["animations"]["clips"]}


@pytest.mark.parametrize("monster_id, status, profile, unsupported", [
    ("sewer_beetle", importer.COMPLETE, "ground_melee", 0), ("frog", importer.PARTIAL, "hopper", 2)])
def test_an_import_reproduces_the_verified_example(probe, monster_id, status, profile, unsupported):
    result = importer.build_document(monster_id, probe["enemies"][monster_id], environment(probe), PROJECT)
    example = load(monster_id)
    assert (result.status, result.profile, len(result.notes)) == (status, profile, unsupported)
    for section in GAMEPLAY_SECTIONS:
        assert result.document.data[section] == example.data[section], section
    assert clips_by_path(result.document) == clips_by_path(example)
    mine, theirs = result.document.data["source_binding"], example.data["source_binding"]
    for key in ("runtime", "definition_path", "actor_scene_path", "animation_profile_path", "sprite_frames_path",
                "loot_table_path", "files", "editability", "unsupported"):
        assert mine[key] == theirs[key], key
    assert mine["passthrough"].get("folded_states") == theirs["passthrough"].get("folded_states")
    assert mine["passthrough"]["profile_texture_filter"] == 1          # kept, though Schema V1 has no field for it
    assert result.document.data["metadata"]["display_name"] == example.data["metadata"]["display_name"]
    report = validate(result.document, PROJECT)
    assert not [item for item in report.select(FAIL) if item.domain != "publish"]
    assert (report.status("publish") == FAIL) == bool(unsupported)


def test_a_second_monster_on_a_known_actor_needs_no_new_code(probe):
    monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    monster.update(display_name="Cave Gnat", max_health=9.0, definition_path="res://data/content/enemies/sewer_beetle.tres")
    result = importer.build_document("cave_gnat", monster, environment(probe), PROJECT)
    assert result.status == importer.COMPLETE and result.profile == "ground_melee"
    assert result.document.monster_id == "cave_gnat" and result.document.data["stats"]["max_health"] == 9
    assert [state["id"] for state in result.document.data["behavior"]["states"]] == [
        "idle", "patrol", "chase", "attack", "hurt", "dead"]


def test_an_unknown_actor_is_imported_partially_and_says_so(probe):
    monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    monster["agent_script"] = "res://gameplay/actors/enemies/spider/spider_agent.gd"
    assert importer.import_support(monster["agent_script"]) == importer.UNSUPPORTED
    result = importer.build_document("cave_spider", monster, environment(probe), PROJECT)
    assert result.status == importer.UNSUPPORTED and result.profile == ""
    data = result.document.data
    # What every enemy has was read ...
    assert data["stats"]["max_health"] == 24 and data["collision"]["body"]["shape"]["size"] == [34, 22]
    assert len(data["animations"]["clips"]) == 5 and data["loot"]["loot_table_id"] == "sewer_beetle_loot"
    # ... the behaviour was not, and nothing pretends otherwise.
    assert data["attack_patterns"] == []
    assert data["source_binding"]["editability"]["behavior"] == "unsupported"
    paths = [row["path"] for row in data["source_binding"]["unsupported"]]
    assert paths == ["behavior", "attack_patterns"] and "placeholder" in data["source_binding"]["unsupported"][0]["reason"]
    assert validate(result.document, PROJECT).status("publish") == FAIL


def test_an_actor_with_states_the_profile_does_not_know_is_not_forced_into_it(probe):
    monster = copy.deepcopy(probe["enemies"]["frog"])
    monster["states"].append({"id": "burrow", "script": "res://gameplay/actors/enemies/frog/frog_burrow_state.gd",
                              "snapshot_state": 0, "properties": {}, "constants": {}})
    result = importer.build_document("frog", monster, environment(probe), PROJECT)
    assert result.status == importer.UNSUPPORTED
    assert any("burrow" in note for note in result.notes)
    renamed = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    renamed["states"][0]["script"] = "res://gameplay/actors/enemies/custom_idle_state.gd"
    assert importer.build_document("sewer_beetle", renamed, environment(probe), PROJECT).status == importer.UNSUPPORTED


@pytest.mark.parametrize("damage, code", [
    (lambda m: m.update(body=[]), "unsupported_body"),
    (lambda m: m["body"].append(dict(m["body"][0])), "unsupported_body"),
    (lambda m: m["body"][0].update({"class": "CapsuleShape2D"}), "unsupported_body"),
    (lambda m: m.update(agent_script=""), "no_actor"),
])
def test_a_monster_that_cannot_be_represented_fails_instead_of_being_guessed(probe, damage, code):
    monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    damage(monster)
    with pytest.raises(importer.ImportError_) as caught:
        importer.build_document("sewer_beetle", monster, environment(probe), PROJECT)
    assert caught.value.code == code


def test_unsupported_hurtboxes_and_missing_profiles_are_listed_not_dropped_silently(probe):
    monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    monster["hurtbox"]["shapes"].append({"class": "ConvexPolygonShape2D", "position": [0, 0], "disabled": False})
    monster["profile"] = {"error": "cannot load res://x.tres"}
    result = importer.build_document("sewer_beetle", monster, environment(probe), PROJECT)
    assert result.status == importer.PARTIAL
    paths = [row["path"] for row in result.document.data["source_binding"]["unsupported"]]
    assert paths == ["collision.hurtboxes[1]", "presentation"]
    assert len(result.document.data["collision"]["hurtboxes"]) == 1 and result.document.data["animations"]["clips"] == []


def test_a_response_the_schema_cannot_hold_never_becomes_a_document(probe):
    from rtcmonster import DocumentError
    monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
    monster["max_health"] = "a lot"
    with pytest.raises(DocumentError):
        importer.build_document("sewer_beetle", monster, environment(probe), PROJECT)
    with pytest.raises(DocumentError):
        importer.build_document("Not An ID", copy.deepcopy(probe["enemies"]["sewer_beetle"]), environment(probe),
                                PROJECT)


def test_profiles_are_registered_per_actor_script_never_per_monster(probe):
    assert set(importer.IMPORT_PROFILES) == {"res://gameplay/actors/enemies/enemy_agent.gd",
                                             "res://gameplay/actors/enemies/frog/frog_agent.gd"}
    source = (Path(importer.__file__)).read_text(encoding="utf-8")
    assert '"sewer_beetle"' not in source and '"frog"' not in source
    with pytest.raises(ValueError, match="already exists"):
        importer.register_import_profile("res://gameplay/actors/enemies/enemy_agent.gd", None)
    script = "res://gameplay/actors/enemies/spider/spider_agent.gd"
    profile = importer.LegacyImportProfile(
        "spider", importer.IMPORT_PROFILES["res://gameplay/actors/enemies/enemy_agent.gd"].states,
        importer.IMPORT_PROFILES["res://gameplay/actors/enemies/enemy_agent.gd"].build)
    try:
        importer.register_import_profile(script, profile)
        monster = copy.deepcopy(probe["enemies"]["sewer_beetle"])
        monster["agent_script"] = script
        result = importer.build_document("cave_spider", monster, environment(probe), PROJECT)
        assert result.status == importer.COMPLETE and result.profile == "spider"
    finally:
        del importer.IMPORT_PROFILES[script]


def test_importing_reads_the_project_and_writes_nothing(probe):
    document = importer.build_document("frog", probe["enemies"]["frog"], environment(probe), PROJECT).document
    before = importer.project_fingerprint(PROJECT, document)
    importer.build_document("frog", probe["enemies"]["frog"], environment(probe), PROJECT)
    assert importer.project_fingerprint(PROJECT, document) == before and len(before) >= 20
