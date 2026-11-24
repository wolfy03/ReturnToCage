from dataclasses import replace
import json
from pathlib import Path

import pytest

from document import MapDocument, decode, encode, read_document, write_document
from godot_bridge import BridgeError, _verify_design
from objects import DocumentError
from region_design import EnemySpawn, RegionDesign, RegionPoint, SpawnPoint, discover_enemies
from region_validation import FAIL, NOT_EVALUATED, validate_region
from region_wizard import create_region

PROJECT = Path(__file__).resolve().parents[3]
BASE = RegionDesign((RegionPoint("entry_marker", "ENTRY", "entry", [32, 64]),), (), (SpawnPoint("slot", 0, [80, 64]),))
FROG = EnemySpawn("enemy_a", "frog_spawn_1", "frog", [300, 200])


def test_v6_round_trip_keeps_enemy_spawns(tmp_path):
    original = MapDocument(design=replace(BASE, enemy_spawns=(FROG, replace(FROG, id="enemy_b", spawn_id="b", enabled=False))))
    path = tmp_path / "숲.rtcmap"
    revision = write_document(path, original)
    data = json.loads(path.read_bytes())
    assert data["schema_version"] == 6
    assert data["design"]["enemy_spawns"][0] == {"id": "enemy_a", "spawn_id": "frog_spawn_1", "enemy_id": "frog",
                                                 "position": [300, 200], "enabled": True}
    assert read_document(path) == (original, revision)


def test_an_empty_enemy_list_is_still_v6_and_differs_from_unmanaged():
    managed = MapDocument(design=replace(BASE, enemy_spawns=()))
    payload = encode(managed)
    assert json.loads(payload)["schema_version"] == 6 and decode(payload) == managed
    assert decode(payload).design.enemy_spawns == () and managed != MapDocument(design=BASE)


def test_drafts_without_enemy_spawns_keep_their_earlier_schema_bytes():
    payload = encode(MapDocument(design=BASE))
    data = json.loads(payload)
    assert data["schema_version"] == 4 and list(data["design"]) == [
        "region_points", "connections", "spawn_points", "environment", "template_ladder"]
    document = decode(payload)
    assert document.design.enemy_spawns is None and encode(document) == payload
    wizard = create_region("offline_region", "Offline", 1200, 600, "flat", 4, BASE.environment)
    assert wizard.design.enemy_spawns is None and json.loads(encode(wizard))["schema_version"] == 4


@pytest.mark.parametrize("version", [4, 5])
def test_enemy_spawns_are_rejected_below_v6(version):
    data = json.loads(encode(MapDocument(design=replace(BASE, enemy_spawns=(FROG,)))))
    data["schema_version"] = version
    with pytest.raises(DocumentError, match="Schema V6"):
        decode(json.dumps(data).encode())


@pytest.mark.parametrize("change", ["missing", "null", "no_design"])
def test_v6_requires_an_enemy_list(change):
    data = json.loads(encode(MapDocument(design=replace(BASE, enemy_spawns=(FROG,)))))
    if change == "missing":
        del data["design"]["enemy_spawns"]
    elif change == "null":
        data["design"]["enemy_spawns"] = None
    else:
        data["design"] = None
    with pytest.raises(DocumentError, match="Schema V6"):
        decode(json.dumps(data).encode())


@pytest.mark.parametrize("fields", [
    {"spawn_id": "Bad ID"}, {"enemy_id": ""}, {"enabled": 1}, {"position": [float("nan"), 0]}, {"id": "9x"},
])
def test_enemy_spawn_fields_are_validated(fields):
    with pytest.raises(DocumentError):
        replace(FROG, **fields)


def test_enemy_marker_identity_is_shared_with_other_markers():
    with pytest.raises(DocumentError, match="duplicate stable marker ID"):
        replace(BASE, enemy_spawns=(replace(FROG, id="slot"),))
    with pytest.raises(DocumentError, match="invalid enemy spawn"):
        replace(BASE, enemy_spawns=[FROG])


def test_unknown_design_fields_stay_rejected():
    data = json.loads(encode(MapDocument(design=replace(BASE, enemy_spawns=(FROG,)))))
    data["design"]["enemy_spawns"][0]["level"] = 3
    with pytest.raises(DocumentError):
        decode(json.dumps(data).encode())
    data = json.loads(encode(MapDocument(design=replace(BASE, enemy_spawns=()))))
    data["design"]["gather_points"] = []
    with pytest.raises(DocumentError):
        decode(json.dumps(data).encode())


def test_project_enemy_catalog_and_validation():
    assert {"frog", "sewer_beetle"} <= set(discover_enemies(PROJECT))
    assert discover_enemies(None) == () and discover_enemies(PROJECT / "missing") == ()
    design = replace(BASE, enemy_spawns=(FROG, replace(FROG, id="enemy_b", position=[5000, 10]),
                                         replace(FROG, id="enemy_c", spawn_id="other", enemy_id="dragon")))
    codes = {(item.status, item.code, item.target) for item in validate_region(MapDocument(design=design), project=PROJECT)}
    assert (FAIL, "duplicate_enemy_spawn_id", "marker:enemy_a") in codes
    assert (FAIL, "duplicate_enemy_spawn_id", "marker:enemy_b") in codes
    assert (FAIL, "outside_bounds", "marker:enemy_b") in codes
    assert (FAIL, "enemy_reference", "marker:enemy_c") in codes
    assert not any(code == "enemy_reference" and target == "marker:enemy_a" for _, code, target in codes)
    offline = {(item.status, item.code) for item in validate_region(MapDocument(design=replace(BASE, enemy_spawns=(FROG,))))}
    assert (NOT_EVALUATED, "enemy_reference_unchecked") in offline
    assert not any("enemy" in item.code for item in validate_region(MapDocument(design=BASE), project=PROJECT))


def test_bridge_verification_compares_enemy_spawns():
    def reloaded(design):  # Godot reports the loading colour with its alpha channel
        return replace(design, environment=replace(design.environment, loading_color=design.environment.loading_color + "ff"))

    design = replace(BASE, enemy_spawns=(FROG,))
    _verify_design(design, reloaded(design))
    _verify_design(BASE, reloaded(BASE))
    for other in (replace(design, enemy_spawns=(replace(FROG, enemy_id="sewer_beetle"),)),
                  replace(design, enemy_spawns=(replace(FROG, enabled=False),)),
                  replace(design, enemy_spawns=(replace(FROG, position=[301, 200]),)),
                  replace(design, enemy_spawns=()), BASE):
        with pytest.raises(BridgeError, match="marker|enemy spawn"):
            _verify_design(design, reloaded(other))
    with pytest.raises(BridgeError, match="enemy spawn"):
        _verify_design(BASE, reloaded(design))


def test_enemy_spawns_are_placed_edited_and_removed_with_qt_events(tmp_path):
    pytest.importorskip("PySide6", reason="Qt is installed by the Windows GUI job")
    from PySide6.QtCore import QPointF, QSettings, Qt
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication

    from source_region import GodotSource
    from window import MainWindow

    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    window.show()
    app.processEvents()
    try:
        window._install_draft(create_region("offline_region", "Offline", 1200, 600, "flat", 4, BASE.environment))
        assert window.draft.design.enemy_spawns is None
        assert {"frog", "sewer_beetle"} <= {window.enemy_id.itemText(i) for i in range(window.enemy_id.count())}
        window.view.fit_map()
        screen = window.view.viewport()
        window.enemy_id.setCurrentText("frog")
        window.tool_actions["place_enemy"].trigger()
        for x in (300, 500):
            QTest.mouseClick(screen, Qt.MouseButton.LeftButton, pos=window.view.mapFromScene(QPointF(x, 200)))
        spawns = window.draft.design.enemy_spawns
        assert [row.enemy_id for row in spawns] == ["frog", "frog"]
        assert [row.spawn_id for row in spawns] == ["frog_spawn_1", "frog_spawn_2"]
        assert len(window.view.markers) == len(window.draft.design.markers)
        assert json.loads(encode(window.draft))["schema_version"] == 6

        window.tool_actions["select"].trigger()
        window.view.select_marker(spawns[1].id)
        window.enemy_id.setCurrentText("sewer_beetle")
        window.enemy_spawn_id.setText("trail_beetle")
        window.enemy_enabled.setChecked(False)
        window._save_marker()
        edited = window.draft.design.enemy_spawns[1]
        assert (edited.enemy_id, edited.spawn_id, edited.enabled, edited.position) == ("sewer_beetle", "trail_beetle", False, spawns[1].position)
        window.undo.undo()
        assert window.draft.design.enemy_spawns == spawns
        window.undo.redo()
        window.view.select_marker(spawns[0].id)
        window._delete_marker()
        assert window.draft.design.enemy_spawns == (edited,)
        window.view.select_marker(edited.id)
        window._delete_marker()
        assert window.draft.design.enemy_spawns == ()  # still a managed, empty list
        for _ in range(5):
            window.undo.undo()
        assert window.draft.design.enemy_spawns is None

        # A linked draft that never read the Scene's enemies must not start managing them.
        source = GodotSource("0" * 64, "1" * 64, "world/adventure/offline_region.tscn",
                             "data/content/regions/offline_region.tres", "2" * 64, "3" * 64, "uid://scene", "", ())
        window._install_draft(replace(window.draft, source=source))
        with pytest.raises(DocumentError):
            window._add_marker("place_enemy", (100, 100))
        assert window.draft.design.enemy_spawns is None
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()
