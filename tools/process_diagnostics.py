"""Captured subprocesses with durable logs and scoped descendant cleanup."""
import json
import subprocess
import tempfile
import time
from pathlib import Path
from traversal_process import ProcessScope

LOGS = Path(tempfile.mkdtemp(prefix="rtc-process-logs-"))
_counter = 0


def run_logged(command, *, artifact_prefix=None, **kwargs):
    global _counter
    _counter += 1
    prefix = artifact_prefix or LOGS / f"{_counter:03}"
    for option in ("capture_output", "text", "encoding", "errors"):
        kwargs.pop(option, None)
    timeout = kwargs.pop("timeout", None)
    record = {"command": command, "started": time.time(), "timeout": False}
    process = None
    stdout = stderr = b""
    scope = ProcessScope()
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
        record["pid"] = process.pid
        scope.attach(process)
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        record["timeout"] = True
        scope.close()
        process.kill()
        stdout, stderr = process.communicate(timeout=5)
        raise
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        # The owner may have exited immediately after signalling cooperative
        # cancellation. Observe the actual job rather than guessing from PIDs.
        cleanup_deadline = time.monotonic() + 7
        while scope.active_processes() not in (0, None) and time.monotonic() < cleanup_deadline:
            time.sleep(.05)
        record.update(return_code=process.returncode if process else None,
                      wall_seconds=round(time.time() - record["started"], 3),
                      remaining_children=scope.active_processes())
        scope.close()
        prefix.with_suffix(".stdout.log").write_bytes(stdout)
        prefix.with_suffix(".stderr.log").write_bytes(stderr)
        prefix.with_suffix(".json").write_text(json.dumps(record, indent=2), encoding="utf-8")
        print(f"PROCESS LOG {prefix} pid={record.get('pid')} exit={record['return_code']} timeout={record['timeout']} children={record['remaining_children']}", flush=True)
    if record["remaining_children"] not in (None, 0):
        raise RuntimeError("Subprocess left owned descendants; reaped and logs preserved")
    return subprocess.CompletedProcess(command, process.returncode,
                                       stdout.decode("utf-8", "replace"), stderr.decode("utf-8", "replace"))


def engine_error(output):
    return any(marker in output for marker in ("ERROR:", "SCRIPT ERROR:", "CowData", "ObjectDB instances leaked", "resources still in use"))
