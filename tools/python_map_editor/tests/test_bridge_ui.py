import pytest

pytest.importorskip("PySide6", reason="Qt is installed by the Windows GUI job")

from PySide6.QtCore import QEventLoop, QSettings, QThread, QTimer
from PySide6.QtWidgets import QApplication

import godot_ui
from window import MainWindow


def test_bridge_completion_can_start_next_worker_after_join(monkeypatch, tmp_path):
    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    loop = QEventLoop()
    completed = []
    threads = []

    def operation(_settings, _cancel, name, _payload, _progress):
        threads.append(QThread.currentThread())
        return {"name": name, "evidence": tmp_path}

    def completion(result):
        completed.append((result["name"], QThread.currentThread() == app.thread(),
                          threads[-1].wait(0), window._bridge_thread))
        if result["name"] == "first":
            window._start_godot("second", None, completion, settings=object())
        else:
            loop.quit()

    monkeypatch.setattr(godot_ui, "run_operation", operation)
    try:
        window._start_godot("first", None, completion, settings=object())
        QTimer.singleShot(5000, loop, loop.quit)
        loop.exec()
        assert completed == [("first", True, True, None), ("second", True, True, None)]
    finally:
        if window._bridge_thread is not None:
            window._bridge_thread.wait(5000)
            app.processEvents()
        window.close()
