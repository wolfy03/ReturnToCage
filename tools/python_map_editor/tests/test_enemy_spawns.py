from dataclasses import replace
import json
from pathlib import Path

import pytest

from document import MapDocument, decode, encode, read_document, write_document
from godot_bridge import BridgeError, _verify_design
from objects import DocumentError
from region_design import (
    MAX_MARKERS, EnemySpawn, RegionDesign, RegionPoint, SpawnPoint, discover_enemies, unique_spawn_id,
)
from region_validation import FAIL, NOT_EVALUATED, validate_region
from region_wizard import create_region
from strings import tr

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


LONG = "e" * 64
ENEMY_TRES = '[gd_resource type="Resource" script_class="EnemyDefinition" load_steps=2 format=3]\n[resource]\nid = &"{id}"\n'


def test_spawn_ids_keep_their_number_inside_the_length_limit():
    taken = set()
    for index in range(1, 301):
        spawn_id = unique_spawn_id(LONG, taken)
        assert len(spawn_id) <= 64 and spawn_id.endswith(f"_spawn_{index}") and spawn_id not in taken
        EnemySpawn("marker", spawn_id, LONG, [0, 0])  # a valid document ID
        taken.add(spawn_id)
    assert unique_spawn_id("frog", ()) == "frog_spawn_1"
    assert unique_spawn_id("frog", {"frog_spawn_1", "frog_spawn_3"}) == "frog_spawn_2"


def test_spawn_id_is_reused_after_deletion_and_never_duplicated():
    taken = {unique_spawn_id(LONG, ())}
    taken.add(unique_spawn_id(LONG, taken))
    third = unique_spawn_id(LONG, taken)
    taken.add(third)
    first = sorted(taken)[0]
    taken.remove(first)
    assert unique_spawn_id(LONG, taken) == first  # the freed ID, not a clash with the remaining ones
    taken.add(first)
    assert unique_spawn_id(LONG, taken) not in taken


def test_long_enemy_ids_with_a_shared_prefix_do_not_collide():
    left, right = "a" * 60 + "left", "a" * 60 + "rght"
    taken = set()
    for enemy in (left, right, left, right, right):
        spawn_id = unique_spawn_id(enemy, taken)
        assert len(spawn_id) <= 64 and spawn_id not in taken
        taken.add(spawn_id)
    assert len(taken) == 5


def test_spawn_id_generation_fails_as_a_document_error():
    for bad in ("", "Bad", "9x", "a" * 65, None):
        with pytest.raises(DocumentError):
            unique_spawn_id(bad, ())
    # Even a full marker budget of taken IDs leaves a free candidate.
    full = {f"frog_spawn_{index}" for index in range(1, MAX_MARKERS + 1)}
    assert unique_spawn_id("frog", full) == f"frog_spawn_{MAX_MARKERS + 1}"


def test_one_bad_resource_does_not_hide_the_enemy_catalog(tmp_path):
    content = tmp_path / "data/content"
    (content / "enemies").mkdir(parents=True)
    (content / "bosses/deep").mkdir(parents=True)
    (content / "enemies/frog.tres").write_text(ENEMY_TRES.format(id="frog"), encoding="utf-8")
    (content / "bosses/deep/toad_king.tres").write_text(ENEMY_TRES.format(id="toad_king"), encoding="utf-8")
    (content / "enemies/broken.tres").write_bytes(b"\xff\xfe\x00 not utf-8 \xff")
    (content / "enemies/empty.tres").write_bytes(b"")
    (content / "enemies/no_id.tres").write_text(ENEMY_TRES.format(id="Not Valid"), encoding="utf-8")
    (content / "enemies/huge.tres").write_bytes(b"x" * (1024 * 1024 + 1))
    (content / "enemies/a_directory.tres").mkdir()
    # Another definition type living beside the enemies must not be offered as an enemy.
    (content / "enemies/loot.tres").write_text(
        '[gd_resource type="Resource" script_class="LootTableDefinition" format=3]\n[resource]\nid = &"frog_loot"\n', encoding="utf-8")
    assert discover_enemies(tmp_path) == ("frog", "toad_king")
    assert discover_enemies(tmp_path / "absent") == ()


def test_project_catalog_matches_the_authored_enemy_definitions():
    authored = set()
    for path in (PROJECT / "data/content").rglob("*.tres"):
        text = path.read_text(encoding="utf-8")
        if 'script_class="EnemyDefinition"' in text.splitlines()[0]:
            authored.add(path.stem)
    assert authored and set(discover_enemies(PROJECT)) == authored


def test_disabled_spawns_still_need_a_valid_enemy_and_a_bridge_catalog_counts():
    design = replace(BASE, enemy_spawns=(replace(FROG, enemy_id="dragon", enabled=False),))
    codes = {(item.status, item.code) for item in validate_region(MapDocument(design=design), project=PROJECT)}
    assert (FAIL, "enemy_reference") in codes
    # Without a project folder the registry list reported by the bridge decides.
    offline = {(item.status, item.code) for item in validate_region(MapDocument(design=design), enemies=("frog",))}
    assert (FAIL, "enemy_reference") in offline and (NOT_EVALUATED, "enemy_reference_unchecked") not in offline
    known = {item.code for item in validate_region(MapDocument(design=design), enemies=("dragon",))}
    assert "enemy_reference" not in known and "enemy_reference_unchecked" not in known


def _window(tmp_path):
    pytest.importorskip("PySide6", reason="Qt is installed by the Windows GUI job")
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QApplication

    from window import MainWindow

    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    window.show()
    app.processEvents()
    return app, window


def _choose_enemy_with_keyboard(window, enemy):
    """Pick the placement kind the way a user does: click the field, replace its text, confirm."""
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest

    palette = window.enemy_palette
    assert palette.isVisibleTo(window) and palette.isEnabled()
    QTest.mouseClick(palette.lineEdit(), Qt.MouseButton.LeftButton)
    assert palette.lineEdit().hasFocus()
    QTest.keyClick(palette.lineEdit(), Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(palette.lineEdit(), enemy)
    QTest.keyClick(palette.lineEdit(), Qt.Key.Key_Return)
    assert palette.currentText() == enemy


def test_enemy_kind_is_chosen_and_placed_with_real_input(tmp_path):
    app, window = _window(tmp_path)
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QPushButton

    try:
        window._install_draft(create_region("offline_region", "Offline", 1200, 600, "flat", 4, BASE.environment))
        assert window.draft.design.enemy_spawns is None
        window.view.fit_map()
        screen = window.view.viewport()
        action = window.tool_actions["place_enemy"]
        assert action.isEnabled() and action in window.menuBar().findChildren(type(action)) or action.isEnabled()

        # A map without enemies and without a selected marker: the editing form is
        # disabled, yet the placement choice is shown, enabled and already filled in.
        assert not window.marker_form.isEnabled()
        action.trigger()
        app.processEvents()
        assert window.view.tool == "place_enemy" and window.region_dock.isVisible()
        assert window.region_tabs.currentIndex() == 0 and window.enemy_palette.isVisibleTo(window)
        offered = {window.enemy_palette.itemText(i) for i in range(window.enemy_palette.count())}
        assert {"frog", "sewer_beetle"} <= offered and window.enemy_palette.currentText() in offered

        def click(x, y=200):
            QTest.mouseClick(screen, Qt.MouseButton.LeftButton, pos=window.view.mapFromScene(QPointF(x, y)))

        _choose_enemy_with_keyboard(window, "frog")
        click(300)
        click(380)  # the choice persists while placing
        _choose_enemy_with_keyboard(window, "sewer_beetle")
        click(460)
        # Arrow keys in the field step through the offered kinds as well.
        window.enemy_palette.setFocus()
        index = window.enemy_palette.currentIndex()
        QTest.keyClick(window.enemy_palette, Qt.Key.Key_Up if index else Qt.Key.Key_Down)
        stepped = window.enemy_palette.currentText()
        assert stepped != "sewer_beetle" and stepped in offered
        _choose_enemy_with_keyboard(window, "frog")
        click(540)
        spawns = window.draft.design.enemy_spawns
        assert [(row.enemy_id, row.spawn_id) for row in spawns] == [
            ("frog", "frog_spawn_1"), ("frog", "frog_spawn_2"), ("sewer_beetle", "sewer_beetle_spawn_1"), ("frog", "frog_spawn_3")]
        assert json.loads(encode(window.draft))["schema_version"] == 6
        assert len(window.view.markers) == len(window.draft.design.markers)

        # With an ENTRY or a player spawn selected the choice is still usable.
        window.tool_actions["select"].trigger()
        for other in (window.draft.design.region_points[0], window.draft.design.spawn_points[0]):
            window.view.select_marker(other.id)
            assert window.marker_form.isEnabled() and not window.enemy_id.isVisibleTo(window)
            action.trigger()
            _choose_enemy_with_keyboard(window, "sewer_beetle")
            click(700 + 60 * len(window.draft.design.enemy_spawns))
            assert window.draft.design.enemy_spawns[-1].enemy_id == "sewer_beetle"
            window.tool_actions["select"].trigger()
        assert len(window.draft.design.enemy_spawns) == 6

        # Editing an existing enemy does not change what the tool places next, and vice versa.
        target = window.draft.design.enemy_spawns[0]
        marker = window.view.mapFromScene(QPointF(*target.position))
        marker.setY(marker.y() - 10)
        QTest.mouseClick(screen, Qt.MouseButton.LeftButton, pos=marker)
        assert window.view.marker_id == target.id and window.enemy_id.isVisibleTo(window)
        assert window.enemy_id.currentText() == "frog" and window.enemy_palette.currentText() == "sewer_beetle"
        QTest.mouseClick(window.enemy_id.lineEdit(), Qt.MouseButton.LeftButton)
        QTest.keyClick(window.enemy_id.lineEdit(), Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
        QTest.keyClicks(window.enemy_id.lineEdit(), "sewer_beetle")
        QTest.mouseClick(window.enemy_spawn_id, Qt.MouseButton.LeftButton)
        QTest.keyClick(window.enemy_spawn_id, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
        QTest.keyClicks(window.enemy_spawn_id, "trail_beetle")
        assert window.enemy_enabled.isChecked()
        QTest.keyClick(window.enemy_spawn_id, Qt.Key.Key_Tab)  # x
        window.enemy_enabled.setFocus()
        QTest.keyClick(window.enemy_enabled, Qt.Key.Key_Space)
        assert not window.enemy_enabled.isChecked()
        apply = next(button for button in window.marker_form.findChildren(QPushButton) if button.text() == tr("apply_region"))
        QTest.mouseClick(apply, Qt.MouseButton.LeftButton)
        edited = window.draft.design.enemy_spawns[0]
        assert (edited.enemy_id, edited.spawn_id, edited.enabled, edited.position) == (
            "sewer_beetle", "trail_beetle", False, target.position)
        _choose_enemy_with_keyboard(window, "frog")
        assert window.draft.design.enemy_spawns[0] == edited and window.enemy_id.currentText() == "sewer_beetle"
        window.undo.undo()
        assert window.draft.design.enemy_spawns[0] == target
        window.undo.redo()

        # Deleting one and placing again reuses the freed spawn ID without a clash.
        window.view.select_marker(window.draft.design.enemy_spawns[1].id)
        delete = next(button for button in window.marker_form.findChildren(QPushButton) if button.text() == tr("delete"))
        QTest.mouseClick(delete, Qt.MouseButton.LeftButton)
        assert "frog_spawn_2" not in {row.spawn_id for row in window.draft.design.enemy_spawns}
        action.trigger()
        click(1000)
        ids = [row.spawn_id for row in window.draft.design.enemy_spawns]
        # frog_spawn_1 was renamed above and frog_spawn_2 was just deleted: the lowest free one is taken.
        assert ids[-1] == "frog_spawn_1" and len(ids) == len(set(ids))
        click(1060)
        ids = [row.spawn_id for row in window.draft.design.enemy_spawns]
        assert ids[-1] == "frog_spawn_2" and len(ids) == len(set(ids))

        # Removing every enemy leaves a managed, empty list; undo returns to the unmanaged draft.
        window.tool_actions["select"].trigger()
        while window.draft.design.enemy_spawns:
            window.view.select_marker(window.draft.design.enemy_spawns[0].id)
            window._delete_marker()
        assert window.draft.design.enemy_spawns == ()
        while window.undo.canUndo():
            window.undo.undo()
        assert window.draft.design.enemy_spawns is None
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()


def test_long_enemy_ids_place_repeatedly_through_the_tool(tmp_path):
    app, window = _window(tmp_path)
    try:
        window._install_draft(create_region("offline_region", "Offline", 1200, 600, "flat", 4, BASE.environment))
        window.enemy_palette.setCurrentText(LONG)
        for index in range(40):
            window._place_marker("place_enemy", (40 + index * 20, 200))
        ids = [row.spawn_id for row in window.draft.design.enemy_spawns]
        assert len(ids) == 40 == len(set(ids)) and all(len(item) <= 64 for item in ids)
        assert ids[9].endswith("_spawn_10") and ids[39].endswith("_spawn_40")
        # An ID the document cannot hold is reported, not raised through the event loop.
        errors = []
        window._edit_error = errors.append
        for bad in ("Bad Enemy", "9lives", ""):
            window.enemy_palette.setCurrentText(bad)
            window._place_marker("place_enemy", (900, 200))
        assert len(errors) == 3 and len(window.draft.design.enemy_spawns) == 40
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()


def test_legacy_linked_draft_keeps_unsaved_edits_when_asked_to_reimport(tmp_path, monkeypatch):
    app, window = _window(tmp_path)
    from PySide6.QtWidgets import QInputDialog, QMessageBox

    from source_region import GodotSource

    try:
        source = GodotSource("0" * 64, "1" * 64, "world/adventure/offline_region.tscn",
                             "data/content/regions/offline_region.tres", "2" * 64, "3" * 64, "uid://scene", "", ())
        legacy = replace(create_region("offline_region", "Offline", 1200, 600, "flat", 4, BASE.environment), source=source)
        window._install_draft(legacy)
        window._add_marker("place_escape", (300, 200))  # an unsaved edit
        edited = window.draft
        assert window.dirty and edited != legacy

        errors = []
        window._edit_error = errors.append
        window.enemy_palette.setCurrentText("frog")
        window._place_marker("place_enemy", (100, 100))
        assert len(errors) == 1 and str(errors[0]) == tr("enemy_reimport_required")
        assert window.draft == edited and window.dirty and window.draft.design.enemy_spawns is None

        # Following the advice goes through the unsaved-changes prompt; cancelling keeps everything.
        launches = []
        monkeypatch.setattr(window, "_start_godot", lambda *args, **kwargs: launches.append(args))
        monkeypatch.setattr(QInputDialog, "getItem", lambda *args, **kwargs: (args[3][0], True))
        prompts = []

        def cancel(box):
            prompts.append(box.text())
            box.done(0)
            return 0

        monkeypatch.setattr(QMessageBox, "exec", cancel)
        monkeypatch.setattr(QMessageBox, "clickedButton", lambda box: box.escapeButton())
        window._select_import({"regions": [{"id": "offline_region", "name": "Offline",
                                            "definition": "data/content/regions/offline_region.tres"}],
                               "recovered": [], "enemies": ["frog", "toad_king"]}, True)
        assert prompts == [tr("confirm_body")] and launches == []
        assert window.draft == edited and window.dirty
        # The registry list reported by Godot is offered for placement from then on.
        assert "toad_king" in {window.enemy_palette.itemText(i) for i in range(window.enemy_palette.count())}
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()


def test_every_earlier_schema_still_reads_and_resaves_without_change():
    from objects import MapObject, ObjectProperties
    from source_region import GodotSource
    from terrain_atlas import discover_themes

    v1 = b'{"schema_version":1,"region_id":"legacy","display_name":"Old","width":640,"height":480}\n'
    migrated = decode(v1)
    assert migrated.design is None and json.loads(encode(migrated))["schema_version"] == 2

    surface = discover_themes(PROJECT)[0]["sewer_concrete"]
    plain = MapObject("platform_a", "platform", "terrain", (31, 45), surface.minimum_size, properties=ObjectProperties(True))
    textured = replace(plain, properties=ObjectProperties(True, terrain=surface))
    source = GodotSource("0" * 64, "1" * 64, "world/adventure/offline_region.tscn",
                         "data/content/regions/offline_region.tres", "2" * 64, "3" * 64, "uid://scene", "", ())
    expected = {
        2: MapDocument(objects=(plain,)),
        3: MapDocument(objects=(plain,), source=source),
        4: MapDocument(objects=(plain,), source=source, design=BASE),
        5: MapDocument(objects=(textured,), source=source, design=BASE),
        6: MapDocument(objects=(textured,), source=source, design=replace(BASE, enemy_spawns=(FROG,))),
    }
    for version, document in expected.items():
        payload = encode(document)
        assert json.loads(payload)["schema_version"] == version
        assert b"enemy_spawns" in payload if version == 6 else b"enemy_spawns" not in payload
        reopened = decode(payload)
        assert reopened == document and encode(reopened) == payload  # a no-op save is byte-identical
        if version < 6 and document.design is not None:
            assert reopened.design.enemy_spawns is None  # still unmanaged after a round trip
