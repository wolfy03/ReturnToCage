"""Retention must preserve active, unknown, failed and externally changed jobs."""
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import traversal_jobs as jobs


class Retention(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rtc-retention-test-")
        self.base = Path(self.temporary.name) / ".godot" / "rtc_traversal"
        self.base.mkdir(parents=True)
        self.processes = patch.object(jobs, "identity", return_value=None)
        self.processes.start()
        self.addCleanup(self.processes.stop)
        self.addCleanup(self.temporary.cleanup)

    def job(self, order=0):
        directory = self.base / uuid.uuid4().hex
        directory.mkdir()
        request = {"origin": "rtc_field_editor", "token": directory.name}
        status = {"state": "complete", "return_code": 0, "engine_error": False, "child_pid": 999,
                  "owner_pid": 100, "worker_pid": 200}
        for name in jobs.FILES:
            value = json.dumps(request if name == "request.json" else status) if name.endswith("json") else "fixture"
            (directory / name).write_text(value)
        manifest = {"schema": 1, "token": directory.name, "completed": time.time() - 100 + order,
                    "owner": {"pid": 100, "created": 1, "image": "editor"},
                    "worker": {"pid": 200, "created": 2, "image": "python"},
                    "files": {name: jobs.digest(directory / name) for name in jobs.FILES}}
        (directory / "retention.json").write_text(json.dumps(manifest))
        return directory

    def test_keep_five_and_protected_current_result(self):
        entries = [self.job(i) for i in range(8)]
        removed = jobs.prune(self.base, protected={entries[0].name})
        self.assertEqual(set(removed), {entries[1].name, entries[2].name})
        self.assertTrue(entries[0].exists())
        self.assertTrue(all(p.exists() for p in entries[3:]))

    def test_failed_corrupted_and_unknown_are_preserved(self):
        failed, corrupt, legacy, unexpected = [self.job() for _ in range(4)]
        (failed / "status.json").write_text('{"state":"failed"}')
        (corrupt / "retention.json").write_text("{")
        (legacy / "retention.json").unlink()
        (unexpected / "dump.dmp").write_text("diagnostics")
        self.assertEqual(jobs.prune(self.base, keep=0), [])
        self.assertTrue(all(p.exists() for p in [failed, corrupt, legacy, unexpected]))

    def test_current_completed_job_counts_towards_recent_five(self):
        entries = [self.job(i) for i in range(8)]
        removed = jobs.prune(self.base, protected={entries[-1].name})
        self.assertEqual(set(removed), {p.name for p in entries[:3]})
        self.assertEqual(len(list(self.base.iterdir())), 5)

    def test_hash_mismatch_and_missing_files_preserved(self):
        changed, missing = self.job(), self.job()
        (changed / "scene.tscn").write_text("author changes")
        (missing / "result.json").unlink()
        self.assertEqual(jobs.prune(self.base, keep=0), [])

    def test_incomplete_process_identity_is_not_a_dead_owner(self):
        directory = self.job()
        manifest = jobs.read_json(directory / "retention.json")
        manifest["owner"] = {"pid": 100}
        (directory / "retention.json").write_text(json.dumps(manifest))
        self.assertEqual(jobs.prune(self.base, keep=0), [])
        self.assertTrue(directory.exists())

    def test_live_owner_requires_explicit_release(self):
        directory = self.job()
        owner = jobs.read_json(directory / "retention.json")["owner"]
        with patch.object(jobs, "identity", side_effect=lambda pid: owner if pid == 100 else None):
            self.assertEqual(jobs.prune(self.base, keep=0), [])
            (directory / "released").write_text(directory.name)
            self.assertEqual(jobs.prune(self.base, keep=0), [directory.name])

    def test_live_worker_and_child_protected_even_when_released(self):
        directory = self.job()
        worker = jobs.read_json(directory / "retention.json")["worker"]
        (directory / "released").write_text(directory.name)
        for live in [200, 999]:
            with patch.object(jobs, "identity", side_effect=lambda pid: worker if pid == live else None):
                self.assertEqual(jobs.prune(self.base, keep=0), [])

    def test_inaccessible_process_and_existing_lock_protect(self):
        directory = self.job()
        with patch.object(jobs, "identity", side_effect=PermissionError):
            self.assertEqual(jobs.prune(self.base, keep=0), [])
        (self.base / ".retention_lock").mkdir()
        self.assertEqual(jobs.prune(self.base, keep=0), [])
        self.assertTrue(directory.exists())

    def test_no_recursive_deletion_or_arbitrary_directory(self):
        directory = self.job()
        (directory / "nested").mkdir()
        self.assertEqual(jobs.prune(self.base, keep=0), [])
        self.assertEqual(jobs.prune(self.base.parent, keep=0), [])

    def test_reused_owner_pid_is_not_old_owner(self):
        directory = self.job()
        replacement = {"pid": 100, "created": 20, "image": "unrelated"}
        with patch.object(jobs, "identity", side_effect=lambda pid: replacement if pid == 100 else None):
            self.assertEqual(jobs.prune(self.base, keep=0), [directory.name])

    def test_link_and_junction_guard(self):
        directory = self.job()
        original = jobs.linked
        # The same rejection is used for symlinks and Windows junctions, without
        # requiring elevated symlink creation rights on a developer machine.
        with patch.object(jobs, "linked", side_effect=lambda p: p == directory or original(p)):
            self.assertEqual(jobs.prune(self.base, keep=0), [])

    def test_only_successful_editor_jobs_receive_attestation(self):
        directory = self.job()
        (directory / "retention.json").unlink()
        request = jobs.read_json(directory / "request.json")
        owner = {"pid": 100, "created": 1, "image": "editor"}
        jobs.attest(directory, request, None)
        self.assertFalse((directory / "retention.json").exists())
        jobs.attest(directory, {"token": directory.name}, owner)
        self.assertFalse((directory / "retention.json").exists())
        with patch.object(jobs, "identity", return_value={"pid": 200, "created": 2, "image": "python"}):
            jobs.attest(directory, request, owner)
        self.assertEqual(jobs.read_json(directory / "retention.json")["owner"], owner)
        self.assertEqual(jobs.prune(self.base, keep=0), [directory.name])


if __name__ == "__main__":
    unittest.main()
