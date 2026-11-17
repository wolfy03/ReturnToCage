"""Run bounded traversal verification in a separate Godot process and isolated user data."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from traversal_process import ProcessScope


def atomic_json(path, value):
    stage = path.with_suffix(".tmp")
    stage.write_text(json.dumps(value), encoding="utf-8")
    os.replace(stage, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--request", required=True)
    parser.add_argument("--owner-pid", type=int)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    request_path = Path(args.request)
    base = root / ".godot" / "rtc_traversal"
    if not re.fullmatch(r"[a-f0-9]{32}", request_path.parent.name) or request_path.name != "request.json":
        parser.error("invalid traversal job")
    if (request_path.resolve().parent.parent != base or not request_path.is_absolute()
            or any(p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()) for p in [root / ".godot", base, request_path.parent, request_path])):
        parser.error("request must be a project traversal job without links")
    if request_path.stat().st_size > 65536:
        parser.error("oversized request")
    try:
        request = json.loads(request_path.read_text(encoding="utf-8-sig"))
    except (ValueError, OSError) as error:
        parser.error(f"cannot read request: {error}")
    if not isinstance(request, dict) or type(request.get("fps")) is not int or not 1 <= request["fps"] <= 1000:
        parser.error("invalid request or physics tick rate")
    token = request_path.parent.name
    folder = "res://.godot/rtc_traversal/" + token
    if (request.get("token") != token or not isinstance(request.get("region"), str) or not isinstance(request.get("fingerprint"), str) or re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", request.get("region", "")) is None
            or request.get("scene") != folder + "/scene.tscn"
            or request.get("output") != folder + "/result.json"
            or re.fullmatch(r"[a-f0-9]{64}", request.get("fingerprint", "")) is None):
        parser.error("invalid request fields")
    directory = request_path.parent
    output = directory / "status.json"
    for name in ("scene.tscn", "result.json", "result.json.tmp", "status.json", "status.tmp", "godot.log", "cancel"):
        p = directory / name
        if p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()):
            parser.error("linked job files rejected")
    started = time.monotonic()
    if (directory / "cancel").exists():
        atomic_json(output, {"state": "cancelled", "return_code": None, "termination": "not_started",
                             "worker_pid": os.getpid(), "child_pid": None, "owner_pid": args.owner_pid,
                             "command": [], "engine_error": False, "wall_ms": 0})
        print("TRAVERSAL PROCESS state=cancelled exit=not_started")
        return 1
    with tempfile.TemporaryDirectory(prefix="rtc-traversal-user-") as isolated:
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "GODOT_USER_HOME"):
            path = Path(isolated) / name
            path.mkdir()
            env[name] = str(path)
        process = None
        scope = None
        reason = ""
        termination = "none"
        failure = ""
        command = []
        try:
            scope = ProcessScope(args.owner_pid, own_worker=True)
            log = (directory / "godot.log").open("w", encoding="utf-8")
            command = [args.godot, "--headless", "--path", str(root), "--fixed-fps", str(request["fps"]),
                       "res://tests/editor/traversal_physics.tscn", "--", folder + "/request.json"]
            with log:
                process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            scope.attach(process)
            stopping_at = None
            while process.poll() is None:
                if (directory / "cancel").exists():
                    reason = "cancelled"
                elif scope.owner_exited():
                    reason = "owner_exited"
                    (directory / "cancel").touch()
                elif "SCRIPT ERROR:" in (directory / "godot.log").read_text(encoding="utf-8", errors="replace"):
                    reason = "script_error"
                elif time.monotonic() - started > 60:
                    reason = "timeout"
                if reason:
                    if stopping_at is None:
                        stopping_at = time.monotonic()
                        (directory / "cancel").touch()
                    # Give the verifier its bounded cooperative cleanup first.
                    if time.monotonic() - stopping_at >= 2:
                        termination = "terminate"
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            termination = "kill"
                            process.kill()
                            process.wait()
                        break
                time.sleep(0.05)
        except (OSError, RuntimeError) as error:
            reason = "worker_error"
            failure = str(error)
        finally:
            if process is not None and process.poll() is None:
                termination = "kill"
                process.kill()
                process.wait(timeout=5)
            if scope is not None:
                scope.close()
        if not reason and (directory / "cancel").exists():
            reason = "cancelled"
        text = (directory / "godot.log").read_text(encoding="utf-8", errors="replace") if (directory / "godot.log").exists() else ""
        engine_error = any(marker in text for marker in ("ERROR:", "CowData", "ObjectDB instances leaked", "resources still in use"))
        state = "complete"
        if reason:
            state = reason
        elif process.returncode != 0 or "TRAVERSAL PHYSICS PASS" not in text or engine_error:
            state = "failed"
        code = process.returncode if process is not None else None
        atomic_json(output, {"state": state, "return_code": code, "termination": termination,
                            "worker_pid": os.getpid(), "child_pid": process.pid if process is not None else None,
                            "owner_pid": args.owner_pid, "command": command, "error": failure, "engine_error": engine_error,
                            "wall_ms": round((time.monotonic() - started) * 1000)})
        print(f"TRAVERSAL PROCESS state={state} exit={code}")
        return int(state != "complete")


if __name__ == "__main__":
    raise SystemExit(main())
