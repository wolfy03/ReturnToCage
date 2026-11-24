import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_project import failure_category, profile_commands, run_case


class DevelopmentProfileTests(unittest.TestCase):
    def plan(self, profile, players=()):
        return profile_commands(profile, "explicit-engine", players, "candidate", None, (), Path("results"))

    def test_editor_profile_excludes_network_and_keeps_rendered_probe(self):
        tests = self.plan("editor")
        self.assertEqual([spec[0] for spec in tests], [
            "test_traversal_process", "test_traversal_jobs", "headless-editor", "rendered-editor",
        ])
        self.assertIn("--rendered", tests[-1][1])

    def test_runtime_selects_only_requested_peer_counts(self):
        self.assertEqual([spec[0] for spec in self.plan("runtime")], ["project"])
        self.assertEqual([spec[0] for spec in self.plan("runtime", (3, 2, 3))], ["project", "enet2", "enet3"])

    def test_upgrade_delegates_unfiltered_to_the_complete_gate(self):
        [test] = self.plan("engine-upgrade")
        self.assertIn("tools/validate_godot_upgrade.py", test[1])
        self.assertNotIn("--case", test[1])

    def test_failure_classification_uses_evidence(self):
        gui = "ERROR: Traversal GUI input did not reach the target Control"
        self.assertEqual(failure_category(gui, {"return_code": 1}), "TEST_HARNESS_FAILURE")
        self.assertEqual(failure_category(gui + "\nFIELD EDITOR PROCESS exit=3221225477", {}), "ENGINE_NATIVE_FAILURE")
        self.assertEqual(failure_category("ERROR: WORLD RUNTIME PROBE FAIL: local presentation did not receive movement", {}),
                         "UNKNOWN")
        self.assertEqual(failure_category("ERROR: TRAVERSAL TEST cancelled results persisted", {}), "TRAVERSAL_FAILURE")

    @unittest.skipUnless(sys.platform == "win32", "Windows owned-process tracking")
    def test_marker_with_nonzero_exit_fails_and_evidence_survives_another_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            first, second = parent / "first", parent / "second"
            first.mkdir()
            second.mkdir()
            command = [sys.executable, "-c", "print('success-marker'); raise SystemExit(7)"]
            failed = run_case(("probe", command, ("success-marker",), 10), first, os.environ.copy())
            command = [sys.executable, "-c", "print('success-marker')"]
            passed = run_case(("probe", command, ("success-marker",), 10), second, os.environ.copy())
            self.assertEqual((failed["status"], failed["return_code"]), ("FAIL", 7))
            self.assertEqual((passed["status"], passed["return_code"]), ("PASS", 0))
            self.assertIn("success-marker", Path(failed["stdout"]).read_text())
            self.assertNotEqual(failed["stdout"], passed["stdout"])

    @unittest.skipUnless(sys.platform == "win32", "Windows owned-process tracking")
    def test_upgrade_requires_the_final_report_and_expected_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            for index, (decision, code, marker, expected) in enumerate((
                (None, 0, None, "FAIL"),
                ("APPROVED", 0, "APPROVED", "PASS"),
                ("APPROVED", 0, None, "FAIL"),
                ("NOT VERIFIED", 1, "NOT VERIFIED", "NOT VERIFIED"),
                ("NOT VERIFIED", 7, "NOT VERIFIED", "FAIL"),
                ("BLOCKED", 1, "BLOCKED", "BLOCKED"),
            )):
                with self.subTest(decision=decision, code=code, marker=marker):
                    output = Path(temporary) / str(index)
                    output.mkdir()
                    if decision is not None:
                        gate = output / "rtc-upgrade-fixture"
                        gate.mkdir()
                        (gate / "results.json").write_text(json.dumps({"decision": decision, "runs": []}))
                    command = [sys.executable, "-c", f"print({f'Decision: {marker}'!r}); raise SystemExit({code})"]
                    result = run_case(("engine-upgrade", command, (), 10), output, os.environ.copy())
                    self.assertEqual(result["status"], expected)


if __name__ == "__main__":
    unittest.main()
