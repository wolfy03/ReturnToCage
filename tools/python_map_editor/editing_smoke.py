"""Qt event regression and the 1,000-object viewport benchmark."""

import hashlib
from statistics import median
from time import perf_counter

from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QColor, QDragEnterEvent, QDragMoveEvent, QDropEvent, QImage
from PySide6.QtTest import QTest

from document import MapDocument, decode, encode, read_document, write_document
from objects import MapObject
from panels import ROLE

LEFT = Qt.MouseButton.LeftButton
MIDDLE = Qt.MouseButton.MiddleButton
CTRL = Qt.KeyboardModifier.ControlModifier


def edit_map(window, target, result, require):
    view = window.view
    viewport = view.viewport()
    window.library_dock.show()
    window.layers_dock.raise_()
    window.activateWindow()
    view.fit_map()
    view.setFocus()
    require(window.library_dock.isVisible() and window.layers_dock.isVisible(), "object and layer panels visible")

    def at(x, y):
        point = view.mapFromScene(QPointF(x, y))
        if not viewport.rect().contains(point):
            raise RuntimeError(f"Qt position outside viewport: {point}; {viewport.rect()}")
        return point

    def drag(start, end, button=LEFT, during=None):
        QTest.mousePress(viewport, button, pos=start)
        QTest.mouseMove(viewport, end)
        if during:
            during()
        QTest.mouseRelease(viewport, button, pos=end)

    def tool(key, name):
        QTest.keyClick(view, key)
        require(view.tool == name and window.tool_actions[name].isChecked(), f"{name} shortcut activates an exclusive tool")

    def action(key, modifiers=CTRL):
        view.setFocus()
        QTest.keyClick(view, key, modifiers)

    def click(x, y, modifiers=Qt.KeyboardModifier.NoModifier):
        QTest.mouseClick(viewport, LEFT, modifiers, at(x, y))

    def input_value(key, value):
        field = window.object_inspector.fields[key]
        field.setFocus()
        field.selectAll()
        QTest.keyClicks(field, value)
        QTest.keyClick(field, Qt.Key.Key_Return)

    tool(Qt.Key.Key_R, "rectangle")
    drag(at(832, 448), at(576, 384))
    platform, = window.draft.objects
    require(platform.position == (704, 416) and platform.size == (256, 64),
            "reverse rectangle drag produces centred positive snapped geometry")
    result["input_checks"] = "Qt test mouse, keyboard and drag/drop events"
    tool(Qt.Key.Key_V, "select")
    click(704, 416)
    require(view.selected_ids() == {platform.id}, "click selects the platform")

    def moved_preview():
        require(window.object_inspector.fields["x"].text() == "768",
                "inspector previews snapped coordinates during movement")
        require(window.draft.objects == (platform,), "drag preview leaves the saved model untouched")

    before = window.undo.index()
    drag(at(704, 416), at(768, 448), during=moved_preview)
    require(window.undo.index() == before + 1 and window.draft.objects[0].position == (768, 448),
            "move commits a single undo command")
    action(Qt.Key.Key_Z)
    require(window.draft.objects == (platform,) and view.selected_ids() == {platform.id}, "undo restores geometry and selection")
    action(Qt.Key.Key_Z, CTRL | Qt.KeyboardModifier.ShiftModifier)
    require(window.draft.objects[0].position == (768, 448), "redo reapplies snapped movement")

    input_value("rotation", "90")
    require(window.draft.objects[0].rotation == 90, "rotation field commits through Qt keyboard editing")
    item = view.objects[platform.id]
    previous_left = item.handle_point((-1, 0))
    previous_right = item.handle_point((1, 0))
    before = window.undo.index()
    drag(at(previous_right.x(), previous_right.y()), at(previous_right.x(), previous_right.y() + 64))
    item = view.objects[platform.id]
    require(window.undo.index() == before + 1 and item.model.size == (320, 64)
            and (previous_left - item.handle_point((-1, 0))).manhattanLength() < 0.001,
            "rotated resize keeps the opposite edge fixed and creates one undo command")
    current = item.model
    corner = item.handle_point((1, 1))
    start = at(corner.x(), corner.y())
    end = at(corner.x() + 32, corner.y() + 32)
    QTest.mousePress(viewport, LEFT, pos=start)
    QTest.mouseMove(viewport, end)
    QTest.keyClick(view, Qt.Key.Key_Escape)
    QTest.mouseRelease(viewport, LEFT, pos=end)
    require(item.model == current and item.pos().toTuple() == current.position
            and window.undo.index() == before + 1, "escape cancels resize without a command")

    selected = window.draft.objects
    before = window.undo.index()
    for field, invalid in (("x", "invalid"), ("x", "nan"), ("y", "inf"),
                           ("object_height", "-2"), ("rotation", "1000001")):
        input_value(field, invalid)
        require(window.draft.objects == selected and window.undo.index() == before
                and window.object_inspector.fields[field].text() != invalid,
                f"invalid inspector field restored without history ({field}: {invalid})")

    project = target.parent
    image_path = project / "장식.png"
    image = QImage(40, 48, QImage.Format.Format_ARGB32)
    image.fill(QColor("#d89ad9"))
    require(image.save(str(image_path)), "fixture PNG created")
    window._set_project_root(project / "cancelled-scan")
    generation = window.library_generation
    window._set_project_root(project)
    require(window.library_generation > generation, "switching projects invalidates the prior texture scan")
    for _ in range(100):
        if any(asset.path == "장식.png" for asset in window.library.assets):
            break
        QTest.qWait(10)
    group = window.library.groups["decoration"]
    item = next((group.child(index) for index in range(group.childCount())
                 if group.child(index).data(0, ROLE).path == "장식.png"), None)
    require(item is not None and not window.view.textures.lookup("장식.png").isNull(), "project PNG discovered and decoded")
    window.library.search.setText(".png")
    require(window.library.groups["platform"].isHidden() and not item.isHidden(), "library searches resource paths")
    window.library.search.clear()
    window.library.tree.setCurrentItem(item)

    mime = window.library.tree.mimeData([item])
    position = at(960, 448)
    enter = QDragEnterEvent(position, Qt.DropAction.CopyAction, mime, LEFT, Qt.KeyboardModifier.NoModifier)
    move = QDragMoveEvent(position, Qt.DropAction.CopyAction, mime, LEFT, Qt.KeyboardModifier.NoModifier)
    drop = QDropEvent(QPointF(position), Qt.DropAction.CopyAction, mime, LEFT, Qt.KeyboardModifier.NoModifier)
    from PySide6.QtWidgets import QApplication

    for event in (enter, move, drop):
        QApplication.sendEvent(viewport, event)
    require(drop.isAccepted() and len(window.draft.objects) == 2, "Qt drag/drop places the selected PNG")
    decoration = window.draft.objects[-1]
    require(decoration.layer_id == "decorations" and decoration.size == (40, 48)
            and decoration.properties.texture_path == "장식.png", "decoration restores PNG dimensions and reference")

    before = window.undo.index()
    input_value("texture", "../invalid.png")
    require(window.undo.index() == before and window.object_inspector.fields["texture"].text() == "장식.png",
            "invalid texture path restores the committed input")
    input_value("scale_x", "1.5")
    require(view.objects[decoration.id].model.size == (60, 48), "decoration scale updates its viewport geometry")
    window.object_inspector.fields["layer"].setFocus()
    QTest.keyClick(window.object_inspector.fields["layer"], Qt.Key.Key_Up)
    require(view.objects[decoration.id].model.layer_id == "terrain", "inspector assigns an object to another layer")
    QTest.keyClick(window.object_inspector.fields["layer"], Qt.Key.Key_Down)
    require(view.objects[decoration.id].model.layer_id == "decorations", "layer reassignment updates the document")
    click(768, 480)
    window.object_inspector.fields["one_way"].setFocus()
    QTest.keyClick(window.object_inspector.fields["one_way"], Qt.Key.Key_Down)
    require(view.objects[platform.id].model.properties.one_way, "platform collision metadata is editable")
    click(960, 448)
    click(768, 480, CTRL)
    require(view.selected_ids() == {platform.id, decoration.id}
            and window.object_inspector.fields["x"].text() == "", "Ctrl multi-selection displays mixed coordinates")
    before = window.undo.index()
    input_value("rotation", "45")
    require(window.undo.index() == before + 1 and {obj.rotation for obj in window.draft.objects} == {45},
            "mixed inspector applies shared property in one undo command")
    action(Qt.Key.Key_C)
    action(Qt.Key.Key_V)
    ids = {obj.id for obj in window.draft.objects}
    require(len(ids) == 4 and len(view.selected_ids()) == 2, "clipboard paste generates fresh IDs and selects copies")
    action(Qt.Key.Key_D)
    require(len(window.draft.objects) == 6, "duplicate supports mixed object types")
    action(Qt.Key.Key_Delete, Qt.KeyboardModifier.NoModifier)
    require(len(window.draft.objects) == 4, "delete removes multiple selected objects")
    action(Qt.Key.Key_Z)
    require(len(window.draft.objects) == 6 and len(view.selected_ids()) == 2,
            "undo delete restores original IDs and selection")
    action(Qt.Key.Key_Z)
    action(Qt.Key.Key_Z)
    require({obj.id for obj in window.draft.objects} == {platform.id, decoration.id},
            "undo duplicate and paste restores original object set")

    tool(Qt.Key.Key_B, "paint")
    before = window.undo.index()
    start, end = at(992, 576), at(1120, 576)
    drag(start, end)
    require(len(window.draft.objects) == 7 and window.undo.index() == before + 1, "paint fills five brush cells in one command")
    drag(start, end)
    require(len(window.draft.objects) == 7 and window.undo.index() == before + 1, "painting over occupied cells cannot duplicate them")
    tool(Qt.Key.Key_E, "erase")
    drag(start, end)
    require(len(window.draft.objects) == 2 and window.undo.index() == before + 2,
            "erase drag is one undo command "
            f"(remaining={[(obj.type, obj.position) for obj in window.draft.objects]}, "
            f"history={window.undo.index() - before}, zoom={view.zoom:.3f})")
    action(Qt.Key.Key_Z)
    require(len(window.draft.objects) == 7, "undo restores erased brush objects")
    action(Qt.Key.Key_Z)

    layer = window.layer_panel.topLevelItem(1)
    layer.setCheckState(2, Qt.CheckState.Checked)
    click(960, 448)
    require(window.draft.layers[1].locked and len(window.draft.objects) == 2
            and not view.objects[decoration.id].isSelected(), "locked layer prevents erase and selection")
    window.layer_panel.topLevelItem(1).setCheckState(1, Qt.CheckState.Unchecked)
    require(not view.objects[decoration.id].isVisible(), "hidden layer removes objects from the viewport")
    action(Qt.Key.Key_Z)
    require(view.objects[decoration.id].isVisible(), "undo restores layer visibility")
    tool(Qt.Key.Key_H, "pan")
    before = view.horizontalScrollBar().value()
    center = viewport.rect().center()
    drag(center, center + type(center)(35, 18))
    require(view.horizontalScrollBar().value() < before, "left-button Pan tool moves the camera")
    tool(Qt.Key.Key_V, "select")
    view.fit_map()

    expected = window.draft
    action(Qt.Key.Key_S)
    require(not window.dirty and read_document(target)[0] == expected, "keyboard save records objects, layers and metadata")
    action(Qt.Key.Key_Z)
    require(window.dirty, "undo away from saved index marks the document dirty")
    action(Qt.Key.Key_Z, CTRL | Qt.KeyboardModifier.ShiftModifier)
    require(not window.dirty, "redo to saved index returns to clean")
    window.layer_panel.topLevelItem(1).setCheckState(2, Qt.CheckState.Unchecked)
    require(window.dirty, "edit after save is dirty")
    action(Qt.Key.Key_Z)
    require(not window.dirty, "undo to saved index returns to clean")
    window.open_document(target)
    require(window.draft == expected and not window.undo.canUndo() and not window.dirty
            and len(view.objects) == 2 and view.objects[decoration.id].isVisible(),
            "reopen restores edited V2 draft and starts a new undo history")

    return target.read_bytes()


def benchmark(window, folder):
    samples = {}

    def elapsed(key, callback, repaint=False):
        start = perf_counter()
        result = callback()
        if repaint:
            QTest.qWait(1)
        samples.setdefault(key, []).append((perf_counter() - start) * 1000)
        return result

    for index in range(3):
        path = folder / f"benchmark-{index}.rtcmap"

        def make_fixture():
            models = tuple(MapObject(f"platform_{number}", "platform", "terrain",
                                     (40 + (number % 40) * 38, 30 + (number // 40) * 32), (26, 14))
                           for number in range(1000))
            return MapDocument("benchmark", "Benchmark", objects=models)

        document = elapsed("fixture_ms", make_fixture)
        write_document(path, document)
        raw = elapsed("read_ms", path.read_bytes)
        decoded = elapsed("decode_ms", lambda: decode(raw))
        window._install_draft(MapDocument())
        elapsed("scene_ms", lambda: window._install_draft(decoded), repaint=True)
        window.open_document(path)
        view = window.view
        viewport = view.viewport()
        obj = document.objects[500]
        target = view.mapFromScene(QPointF(*obj.position))
        elapsed("select_ms", lambda: QTest.mouseClick(viewport, LEFT, pos=target), repaint=True)
        assert view.selected_ids() == {obj.id}
        zoom = view.zoom
        elapsed("zoom_ms", lambda: view.set_zoom(zoom * 1.15), repaint=True)
        assert view.zoom > zoom
        center = viewport.rect().center()
        before = view.horizontalScrollBar().value()

        def pan():
            QTest.mousePress(viewport, MIDDLE, pos=center)
            QTest.mouseMove(viewport, center + type(center)(48, 25))
            QTest.mouseRelease(viewport, MIDDLE, pos=center + type(center)(48, 25))

        elapsed("pan_ms", pan, repaint=True)
        assert view.horizontalScrollBar().value() < before
        elapsed("save_ms", lambda: window.save_document(path, window.disk_hash))
        window._install_draft(MapDocument())
        elapsed("reopen_ms", lambda: window.open_document(path), repaint=True)
        assert window.draft == document and len(view.objects) == 1000
    return {name: {"median": round(median(values), 2), "max": round(max(values), 2)}
            for name, values in samples.items()}


def restart_checks(window, path):
    expected = hashlib.sha256(path.read_bytes()).hexdigest()
    window._set_project_root(path.parent)
    window.open_document(path)
    assert hashlib.sha256(encode(window.draft)).hexdigest() == expected
    assert len(window.draft.objects) == 2 and len(window.view.objects) == 2
    assert window.draft.region_id == "fixture01" and window.draft.width == 1800 and window.draft.height == 940
    assert window.draft.layers[1].visible and window.draft.layers[1].locked
    assert {obj.type for obj in window.draft.objects} == {"platform", "decoration"}
    assert any(obj.properties.one_way for obj in window.draft.objects)
    assert any(obj.properties.texture_path == "장식.png" for obj in window.draft.objects)
    assert not window.view.textures.lookup("장식.png").isNull()
    assert not window.dirty and not window.undo.canUndo()
    assert window.close()
    return expected
