"""Run the Godot bridge and return a checked response. No Qt; callers decide on which thread.

``inspect_monsters`` and ``import_monster`` only read. ``stage_monster`` writes presentation resources, and
only into a staging copy of the project (see ``bridge.staging``); the bridge itself refuses any other project.

Contract of one call:

* the request carries a fresh ``request_id``; a response is accepted only when it repeats that ID, the
  protocol version and the operation, and names the project that was asked about;
* exit code 0 alone proves nothing: the response file must exist, parse and say ``PASS``;
* an engine log with script errors, or a negative / huge exit code (a native crash), is a failure even
  when a response file exists;
* only the process this module started is ever terminated - on cancel, on timeout and on error.

Every failure raises ``BridgeError`` with a stable ``code``.
"""

from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import uuid

PROTOCOL = 1
OPERATIONS = ("inspect_monsters", "import_monster", "stage_monster", "read_stage")
STAGE_OPERATIONS = ("stage_monster", "read_stage")      # carry a ``stage`` payload; only run in a staging copy
DEFAULT_TIMEOUT = 180
CRASH_ATTEMPTS = 3
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
ENGINE_ERRORS = re.compile(r"SCRIPT ERROR:|Parse Error|ObjectDB instances leaked|resources still in use", re.I)
BRIDGE_SCENE = "res://tools/monster_bridge/bridge.tscn"

# Stable failure codes.
GODOT_MISSING, GODOT_VERSION_MISMATCH, PROJECT_INVALID, TIMEOUT, CANCELLED, PROCESS_CRASH, ENGINE_ERROR = (
    "GODOT_MISSING", "GODOT_VERSION_MISMATCH", "PROJECT_INVALID", "TIMEOUT", "CANCELLED", "PROCESS_CRASH",
    "ENGINE_ERROR")
INVALID_RESPONSE, RESPONSE_MISMATCH, UNKNOWN_MONSTER = "INVALID_RESPONSE", "RESPONSE_MISMATCH", "UNKNOWN_MONSTER"


class BridgeError(RuntimeError):
    def __init__(self, code, message, log="", exit_code=None):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.detail = message
        self.log = log
        self.exit_code = exit_code      # the process's exit code, when the failure is about the process


@dataclass(frozen=True)
class BridgeResponse:
    operation: str
    request_id: str
    data: dict
    environment: dict        # godot_version, physics_ticks_per_second, gravity, ...
    log: str
    seconds: float
    attempts: int = 1        # more than 1 when the engine crashed on exit and the read was repeated
    # What the *process* did, kept apart from what the bridge answered: the exit codes of the attempts that
    # crashed (their answers were thrown away) and the engine log of the first of them.
    crashes: tuple = ()
    crash_log: str = ""

    @property
    def process_result(self):
        """``CLEAN`` or ``CRASHED_THEN_RETRIED``. A crash is never folded into a plain success."""
        return "CRASHED_THEN_RETRIED" if self.crashes else "CLEAN"


def engine_binary(godot):
    """The executable to start. Windows' ``*_console.exe`` is a launcher that starts the engine as a second
    process; killing the launcher on cancel or timeout would leave that engine running against the project.
    The engine binary next to it is used instead when it exists."""
    godot = Path(godot)
    if os.name == "nt" and godot.name.lower().endswith("_console.exe"):
        companion = godot.with_name(godot.name[:-len("_console.exe")] + ".exe")
        if companion.is_file():
            return companion
    return godot


def _stop(process):
    """End the process this module started, and anything it started in turn. Nothing else is touched.

    A child left running keeps its working directory open, and on Windows that makes the staging copy it
    ran in impossible to delete. The tree is found from this process's own PID, never by name.
    """
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15,
                           creationflags=subprocess.CREATE_NO_WINDOW)
        except (OSError, subprocess.SubprocessError):
            pass
    else:
        try:
            os.killpg(process.pid, 9)          # the child was started in its own session
        except (OSError, AttributeError):
            pass
    if process.poll() is None:
        process.kill()


def _run(command, cwd, cancel, timeout):
    """Run one child to completion. Returns ``(exit_code, output)``; kills only this child."""
    command = [str(engine_binary(command[0])), *command[1:]]
    kwargs = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {"start_new_session": True}
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=subprocess.STDOUT, **kwargs)
        except OSError as error:
            raise BridgeError(GODOT_MISSING, str(error)) from error
        deadline = time.monotonic() + timeout
        stopped = None
        try:
            while process.poll() is None:
                if cancel is not None and cancel.wait(0.05):
                    stopped = CANCELLED
                    break
                if cancel is None:
                    time.sleep(0.05)
                if time.monotonic() >= deadline:
                    stopped = TIMEOUT
                    break
        finally:
            if process.poll() is None:
                _stop(process)
            process.wait(timeout=15)
        output.seek(0)
        log = output.read().decode("utf-8", errors="replace")
    if stopped == CANCELLED:
        raise BridgeError(CANCELLED, "the operation was cancelled", log)
    if stopped == TIMEOUT:
        raise BridgeError(TIMEOUT, f"Godot did not finish within {timeout} s", log)
    return process.returncode, log


def godot_version(godot, cancel=None, timeout=30):
    """The engine's ``--version`` line, e.g. ``4.7.2.stable.official.ed1daf0bf``."""
    code, log = _run([str(godot), "--version"], None, cancel, timeout)
    lines = [line.strip() for line in log.splitlines() if line.strip()]
    if code != 0 or not lines:
        raise BridgeError(GODOT_MISSING, f"not a working Godot executable (exit {code})", log)
    return lines[-1]


def check_version(godot, project, cancel=None):
    """Raise unless the executable is the engine version the project pins in ``.godot-version``."""
    try:
        pinned = (Path(project) / ".godot-version").read_text(encoding="utf-8").strip()
    except OSError as error:
        raise BridgeError(PROJECT_INVALID, f"cannot read .godot-version: {error}") from error
    actual = godot_version(godot, cancel)
    if not actual.startswith(pinned + "."):
        raise BridgeError(GODOT_VERSION_MISMATCH, f"the project needs Godot {pinned}; this executable is {actual}")
    return actual


def call(godot, project, operation, monster_id="", cancel=None, timeout=DEFAULT_TIMEOUT, work_folder=None,
         stage=None):
    """Run one bridge operation against ``project`` and return a checked BridgeResponse.

    Godot 4.7.2 on Windows sometimes dies with an access violation while shutting down, after the bridge
    has finished (measured: a few runs in a hundred, also with the STEP 1 probe; never with the game's main
    scene). A crashed run is never trusted, whatever it wrote. The read operations change nothing, and
    ``stage_monster`` first deletes, then rewrites, its own output folder inside a disposable staging copy
    (so a half-written file of a crashed attempt cannot pass for a result), so the call is simply made
    again, at most ``CRASH_ATTEMPTS`` times. Nothing that writes to the real project is ever retried here.

    The functional answer and the process outcome are reported separately: ``BridgeResponse.attempts``,
    ``.crashes`` (exit codes of the discarded attempts), ``.crash_log`` and ``.process_result``. An exit
    code alone does not prove *which* crash it was; the log of the first crashed attempt is kept so that
    can be looked at. Cancelling stops the retries, and each attempt has its own ``timeout``.

    ``stage`` is the payload of the stage operations and is sent only with those.
    """
    if operation not in OPERATIONS:
        raise ValueError(f"unknown bridge operation: {operation}")
    crashes, crash_log = [], ""
    for attempt in range(1, CRASH_ATTEMPTS + 1):
        try:
            response = _call_once(godot, project, operation, monster_id, cancel, timeout, work_folder, stage)
        except BridgeError as error:
            if error.code != PROCESS_CRASH or attempt == CRASH_ATTEMPTS:
                raise
            crashes.append(error.exit_code)
            crash_log = crash_log or error.log
            continue
        return replace(response, attempts=attempt, crashes=tuple(crashes), crash_log=crash_log)


def _call_once(godot, project, operation, monster_id, cancel, timeout, work_folder, stage=None):
    # Always absolute: Godot runs with the project as its working directory, so a relative --path would
    # point somewhere else and the engine would sit in the project manager until the timeout.
    project = Path(project).resolve()
    if not (project / "project.godot").is_file() or not (project / "tools/monster_bridge/bridge.tscn").is_file():
        raise BridgeError(PROJECT_INVALID, f"not a ReturnToCage project with the monster bridge: {project}")
    started = time.monotonic()
    request_id = uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="rtc-monster-bridge-", dir=work_folder) as folder:
        request_path, result_path = Path(folder) / "request.json", Path(folder) / "result.json"
        request = {"protocol": PROTOCOL, "request_id": request_id, "operation": operation, "monster_id": monster_id,
                   "result_path": str(result_path)}
        if operation in STAGE_OPERATIONS:
            request["stage"] = stage
        request_path.write_text(json.dumps(request), encoding="utf-8")
        code, log = _run([str(godot), "--headless", "--path", str(project), BRIDGE_SCENE, "--",
                          "--request", str(request_path)], project, cancel, timeout)
        if cancel is not None and cancel.is_set():
            raise BridgeError(CANCELLED, "the operation was cancelled", log)
        if code < 0 or code > 255:
            raise BridgeError(PROCESS_CRASH, f"Godot crashed (exit {code}, 0x{code & 0xffffffff:08X})", log, code)
        if ENGINE_ERRORS.search(log):
            raise BridgeError(ENGINE_ERROR, "Godot reported script errors or leaks", log)
        result = _read_result(result_path, code, log)
    for key, expected in (("protocol", PROTOCOL), ("request_id", request_id), ("operation", operation)):
        if result.get(key) != expected:
            raise BridgeError(RESPONSE_MISMATCH, f"response {key} is {result.get(key)!r}, expected {expected!r}", log)
    answered = result.get("project_path")
    if not isinstance(answered, str) or Path(answered).resolve() != project.resolve():
        raise BridgeError(RESPONSE_MISMATCH, f"response describes another project: {answered!r}", log)
    if result.get("status") != "PASS" or code != 0:
        code_name = result.get("error_code") or ENGINE_ERROR
        raise BridgeError(code_name if isinstance(code_name, str) else ENGINE_ERROR,
                          str(result.get("message") or f"exit {code}"), log)
    if not isinstance(result.get("data"), dict) or not isinstance(result.get("godot_version"), str):
        raise BridgeError(INVALID_RESPONSE, "response has no data or engine version", log)
    environment = {key: result.get(key) for key in (
        "godot_version", "physics_ticks_per_second", "network_protocol_version", "gravity",
        "target_keep_range_scale", "snapshot_states")}
    return BridgeResponse(operation, request_id, result["data"], environment, log, time.monotonic() - started)


def _read_result(path, code, log):
    try:
        if path.stat().st_size > MAX_RESPONSE_BYTES:
            raise BridgeError(INVALID_RESPONSE, "response exceeds the size limit", log)
        payload = path.read_bytes()
    except OSError as error:
        raise BridgeError(INVALID_RESPONSE, f"Godot wrote no response (exit {code})", log) from error
    try:
        result = json.loads(payload.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise BridgeError(INVALID_RESPONSE, f"response is not JSON: {error}", log) from error
    if not isinstance(result, dict):
        raise BridgeError(INVALID_RESPONSE, "response is not an object", log)
    return result


def inspect_monsters(godot, project, cancel=None, timeout=DEFAULT_TIMEOUT):
    """Monsters registered in the game's ContentRegistry, with whether each can be imported."""
    from .importer import import_support

    response = call(godot, project, "inspect_monsters", cancel=cancel, timeout=timeout)
    rows = response.data.get("monsters")
    if not isinstance(rows, list) or not all(isinstance(row, dict) and isinstance(row.get("monster_id"), str)
                                             for row in rows):
        raise BridgeError(INVALID_RESPONSE, "monster list is malformed", response.log)
    for row in rows:
        row["import_support"] = import_support(row.get("agent_script", ""))
    return response


def import_monster(godot, project, monster_id, cancel=None, timeout=DEFAULT_TIMEOUT):
    """Read one registered monster and convert it. Returns ``(ImportResult, BridgeResponse)``."""
    from .importer import build_document

    response = call(godot, project, "import_monster", monster_id, cancel, timeout)
    monster = response.data.get("monster")
    if response.data.get("monster_id") != monster_id or not isinstance(monster, dict):
        raise BridgeError(RESPONSE_MISMATCH, "response is about another monster", response.log)
    if cancel is not None and cancel.is_set():
        raise BridgeError(CANCELLED, "the operation was cancelled", response.log)
    return build_document(monster_id, monster, response.environment, project), response


def threaded(function, *args, **kwargs):
    """Run a bridge call on a plain thread and return ``(thread, box)``; ``box`` gets ``result`` or ``error``."""
    box = {}

    def work():
        try:
            box["result"] = function(*args, **kwargs)
        except BaseException as error:  # noqa: BLE001 - handed to the caller
            box["error"] = error

    thread = threading.Thread(target=work, daemon=True)
    thread.start()
    return thread, box
