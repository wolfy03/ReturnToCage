"""Failure injection for worker launch, cancellation and Windows child ownership."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from traversal_process import ProcessScope

ROOT = Path(__file__).resolve().parents[1]


class WorkerLifecycle(unittest.TestCase):
    def test_bad_owner(self):
        with self.assertRaises(RuntimeError):
            ProcessScope(os.getppid() + 999999)

    def test_normal_child(self):
        scope = ProcessScope()
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        try:
            scope.attach(child)
            self.assertEqual(child.wait(timeout=5), 0)
            self.assertIn(scope.active_processes(), (0, None))
        finally:
            scope.close()

    def test_launch_error_writes_status(self):
        base = ROOT / ".godot" / "rtc_traversal"
        base.mkdir(parents=True, exist_ok=True)
        token = uuid.uuid4().hex
        folder = base / token
        folder.mkdir()
        prefix = "res://.godot/rtc_traversal/" + token
        request = dict(region="sewer_region", token=token, fingerprint="0" * 64,
                       scene=prefix + "/scene.tscn", output=prefix + "/result.json", fps=60)
        try:
            (folder / "request.json").write_text(json.dumps(request), encoding="utf-8")
            result = subprocess.run([sys.executable, str(ROOT / "tools/analyze_traversal.py"),
                                     "--godot", str(folder / "missing-engine.exe"),
                                     "--request", str(folder / "request.json")], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            status = json.loads((folder / "status.json").read_text())
            self.assertEqual(status["state"], "worker_error")
            self.assertIsNone(status["child_pid"])
            self.assertTrue(status["error"])
            self.assertFalse((folder / "result.json").exists())
            # Cancellation before launch must not start even an invalid engine.
            (folder / "cancel").touch()
            cancelled = subprocess.run([sys.executable, str(ROOT / "tools/analyze_traversal.py"),
                                        "--godot", str(folder / "missing-engine.exe"),
                                        "--request", str(folder / "request.json")], capture_output=True, timeout=10)
            self.assertNotEqual(cancelled.returncode, 0)
            status = json.loads((folder / "status.json").read_text())
            self.assertEqual(status["state"], "cancelled")
            self.assertEqual(status["termination"], "not_started")
            self.assertIsNone(status["child_pid"])
        finally:
            for child in folder.iterdir():
                child.unlink()
            folder.rmdir()

    @unittest.skipUnless(os.name == "nt", "Windows Job Object ownership")
    def test_worker_crash_reaps_only_owned_child(self):
        with tempfile.TemporaryDirectory(prefix="rtc-job-test-") as directory:
            pid_file = Path(directory) / "pid"
            # os._exit bypasses finally/atexit and models a worker crash. The
            # kernel closes its non-inheritable job handle and reaps its child.
            script = ("import sys,subprocess,os,time; from pathlib import Path; "
                      "from traversal_process import ProcessScope; s=ProcessScope(own_worker=True); "
                      "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']); "
                      "s.attach(p); Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(.5); os._exit(7)")
            independent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            try:
                worker = subprocess.Popen([sys.executable, "-c", script, str(pid_file)], cwd=ROOT / "tools")
                deadline = time.monotonic() + 5
                while (not pid_file.exists() or not pid_file.read_text()) and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(pid_file.exists())
                pid = int(pid_file.read_text())
                observer = ProcessScope()
                # Open a real process handle before exit, so PID reuse cannot
                # turn this assertion into a check of some unrelated process.
                handle = observer.api.OpenProcess(0x100000, False, pid)
                self.assertTrue(handle)
                try:
                    self.assertEqual(worker.wait(timeout=5), 7)
                    self.assertEqual(observer.api.WaitForSingleObject(handle, 5000), 0)
                    self.assertIsNone(independent.poll())
                finally:
                    observer.api.CloseHandle(handle)
                    observer.close()
            finally:
                if worker.poll() is None:
                    worker.kill()
                worker.wait(timeout=5)
                independent.kill()
                independent.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
