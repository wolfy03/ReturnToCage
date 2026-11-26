import os
from pathlib import Path
import sys
import textwrap

import pytest

from rtcmonster import MonsterDocument, read_document

TOOL = Path(__file__).resolve().parents[1]
PROJECT = TOOL.parents[1]
EXAMPLES = TOOL / "examples"
EXAMPLE_IDS = ("sewer_beetle", "frog", "sewer_rat_prototype")


def load(name):
    return read_document(EXAMPLES / f"{name}.rtcmonster")[0]


def edit(document, change):
    """Return a copy of the document after ``change(data)`` mutated its plain data."""
    data = document.to_dict()
    change(data)
    return MonsterDocument(data)


@pytest.fixture
def beetle():
    return load("sewer_beetle")


@pytest.fixture
def frog():
    return load("frog")


@pytest.fixture
def rat():
    return load("sewer_rat_prototype")


# A stand-in for the Godot executable: a real child process that can misbehave on request.
FAKE = textwrap.dedent('''
    import json, os, signal, sys, time
    mode = os.environ.get("RTC_FAKE_MODE", "ok")
    args = sys.argv[1:]
    if args == ["--version"]:
        if mode == "not_godot":
            sys.exit(7)
        print(os.environ.get("RTC_FAKE_VERSION", "4.7.2.stable.official.ed1daf0bf"))
        sys.exit(0)
    if "--import" in args:                # the editor's asset import of a staging copy
        sys.exit(int(os.environ.get("RTC_FAKE_IMPORT_EXIT", "0")))
    request = json.load(open(args[args.index("--request") + 1], encoding="utf-8"))
    project = args[args.index("--path") + 1]
    if os.environ.get("RTC_FAKE_ECHO"):   # lets a test read the request the client really sent
        json.dump({"request": request, "project": project}, open(os.environ["RTC_FAKE_ECHO"], "w", encoding="utf-8"))
    for relative in json.loads(os.environ.get("RTC_FAKE_TOUCH", "[]")):
        os.makedirs(os.path.dirname(os.path.join(project, relative)), exist_ok=True)
        open(os.path.join(project, relative), "w").close()
    result = {"protocol": 1, "request_id": request["request_id"], "operation": request["operation"],
              "project_path": project, "status": "PASS", "error_code": "", "message": "",
              "godot_version": "4.7.2-stable (official)", "physics_ticks_per_second": 60,
              "network_protocol_version": 20, "gravity": 1100.0, "target_keep_range_scale": 1.35,
              "snapshot_states": ["IDLE", "MOVING", "ATTACKING", "HURT", "DEAD"],
              "data": json.loads(os.environ.get("RTC_FAKE_DATA", '{"monsters": []}'))}
    if mode == "hang":
        time.sleep(float(os.environ.get("RTC_FAKE_SECONDS", "20")))
    if mode == "crash":
        if os.name == "nt":
            os._exit(-1073741819)          # 0xC0000005, an access violation
        os.kill(os.getpid(), signal.SIGSEGV)
    if mode == "wrong_request":
        result["request_id"] = "someone-elses-request"
    if mode == "wrong_protocol":
        result["protocol"] = 2
    if mode == "wrong_operation":
        result["operation"] = "import_monster" if request["operation"] == "inspect_monsters" else "inspect_monsters"
    if mode == "wrong_project":
        result["project_path"] = os.path.dirname(project.rstrip("/\\\\")) or "/"
    if mode == "fail":
        result.update(status="FAIL", error_code="UNKNOWN_MONSTER", message=request.get("monster_id", ""))
    if mode == "script_error":
        print("SCRIPT ERROR: Invalid call. Nonexistent function 'boom' in base 'Nil'.")
    if mode == "no_data":
        del result["data"]
    if mode != "no_result":
        with open(request["result_path"], "w", encoding="utf-8") as stream:
            stream.write("{ this is not json" if mode == "bad_json" else
                         "[1, 2, 3]" if mode == "not_an_object" else json.dumps(result))
    print("MONSTER BRIDGE", request["operation"], result["status"])
    sys.exit(3 if mode == "fail" else 0)
''')


@pytest.fixture
def fake(tmp_path, monkeypatch):
    """``(godot, project, set_mode)``: a stand-in executable and a folder that looks like the project."""
    script = tmp_path / "fake_godot.py"
    script.write_text(FAKE, encoding="utf-8")
    if os.name == "nt":
        godot = tmp_path / "fake_godot.cmd"
        # exit /b hands the child's exit code on unchanged, including crash codes above 255.
        godot.write_text(f'@"{sys.executable}" "{script}" %*\r\n@exit /b %ERRORLEVEL%\r\n', encoding="utf-8")
    else:
        godot = tmp_path / "fake_godot"
        godot.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        godot.chmod(0o755)
    project = tmp_path / "프로젝트"
    (project / "tools/monster_bridge").mkdir(parents=True)
    (project / "project.godot").write_text("", encoding="utf-8")
    (project / "tools/monster_bridge/bridge.tscn").write_text("", encoding="utf-8")
    (project / ".godot-version").write_text("4.7.2\n", encoding="utf-8")

    def set_mode(mode, **extra):
        monkeypatch.setenv("RTC_FAKE_MODE", mode)
        for key, value in extra.items():
            monkeypatch.setenv(f"RTC_FAKE_{key.upper()}", str(value))
    set_mode("ok")
    return godot, project, set_mode


# ------------------------------------------------------------------------------------------------ Qt (GUI tests)
@pytest.fixture(scope="session")
def app():
    """The one QApplication of the test session, shared by every GUI test module.

    PySide6 is imported here and not at the top: the core and application tests must keep working, and
    keep proving they need no Qt, on a machine that has none.
    """
    widgets = pytest.importorskip("PySide6.QtWidgets")
    yield widgets.QApplication.instance() or widgets.QApplication([])


@pytest.fixture
def native(app):
    if app.platformName() == "offscreen":
        pytest.skip("window shortcuts need a real windowing system; run on Windows")
