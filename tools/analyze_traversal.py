"""Run bounded traversal verification in a separate Godot process and isolated user data."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def atomic_json(path, value):
    stage = path.with_suffix(".tmp")
    stage.write_text(json.dumps(value), encoding="utf-8")
    os.replace(stage, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--request", required=True)
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
    with tempfile.TemporaryDirectory(prefix="rtc-traversal-user-") as isolated:
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "GODOT_USER_HOME"):
            path = Path(isolated) / name
            path.mkdir()
            env[name] = str(path)
        with (directory / "godot.log").open("w", encoding="utf-8") as log:
            command = [args.godot, "--headless", "--path", str(root), "--fixed-fps", str(request["fps"]),
                       "res://tests/editor/traversal_physics.tscn", "--", folder + "/request.json"]
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            reason = ""
            termination = "none"
            while process.poll() is None:
                if (directory / "cancel").exists():
                    reason = "cancelled"
                elif "SCRIPT ERROR:" in (directory / "godot.log").read_text(encoding="utf-8", errors="replace"):
                    reason = "script_error"
                elif time.monotonic() - started > 60:
                    reason = "timeout"
                if reason:
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
        text = (directory / "godot.log").read_text(encoding="utf-8", errors="replace")
        state = "complete"
        if reason:
            state = reason
        elif process.returncode != 0 or "TRAVERSAL PHYSICS PASS" not in text or "ERROR:" in text:
            state = "failed"
        atomic_json(output, {"state": state, "return_code": process.returncode, "termination": termination, "wall_ms": round((time.monotonic() - started) * 1000)})
        print(f"TRAVERSAL PROCESS state={state} exit={process.returncode}")
        return int(state != "complete")


if __name__ == "__main__":
    raise SystemExit(main())
