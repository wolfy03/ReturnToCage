"""Release publication/provenance boundaries; actual EXE checks remain separate."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_windows_demo as build


def pe_fixture() -> bytes:
    data = bytearray(256)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<H", data, 68, 0x8664)
    data += struct.pack("<Q4s", 32, b"GDPC")
    return bytes(data)


class ReleaseBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rtc_release_boundary_")
        self.root = Path(self.temporary.name).resolve()
        self.root_patch = patch.object(build, "ROOT", self.root)
        self.root_patch.start()
        self.env_patch = patch.dict(os.environ, {"GITHUB_ACTIONS": "false"})
        self.env_patch.start()
        (self.root / ".godot-version").write_text("4.7.2\n")
        (self.root / ".gitignore").write_text("/build/\n")
        (self.root / "tracked.txt").write_text("committed source\n")
        for arguments in [("init",), ("config", "user.name", "Release validation"),
                          ("config", "user.email", "validation@example.invalid"),
                          ("add", "."), ("commit", "-m", "fixture")]:
            subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True)
        self.output = self.root / "build/windows/ReturnToCage_Demo.exe"
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous verified release")
        self.manifest = self.output.parent / "build_manifest.json"
        self.manifest.write_text("previous manifest")

    def tearDown(self):
        self.env_patch.stop()
        self.root_patch.stop()
        self.temporary.cleanup()

    def run_build(self, outcome="pass"):
        real_output = subprocess.check_output

        def version(command, **kwargs):
            if command[0] == "fixture-godot":
                return "4.7.2.stable.fixture"
            return real_output(command, **kwargs)

        def fake_export(command, log):
            log.write_text("fixture subprocess\n")
            if "--export-release" in command:
                Path(command[-1]).write_bytes(pe_fixture())

        owner = self

        class Checks:
            def __init__(self, *args):
                self.results = {"export-content": {"display_server": "headless", "rendering_method": "dummy",
                                                   "content_ids": ["default_game_start"]},
                                "lifecycle": {"status": "pass"}}

            def run(self):
                if outcome == "validation_failure":
                    raise RuntimeError("fixture GUI/roster validation rejected")
                if outcome == "source_changed":
                    (owner.root / "tracked.txt").write_text("changed during validation\n")

            def close(self):
                pass

        with patch.object(sys, "platform", "win32"), \
                patch.object(sys, "argv", ["build_windows_demo.py", "--godot", "fixture-godot", "--output", str(self.output)]), \
                patch.object(build.subprocess, "check_output", side_effect=version), \
                patch.object(build, "run", side_effect=fake_export), patch.object(build, "ExportChecks", Checks), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return build.main()

    def test_dirty_source_requires_explicit_local_preflight(self):
        (self.root / "tracked.txt").write_text("local edits\n")
        with self.assertRaisesRegex(RuntimeError, "dirty"):
            build.source_identity()
        self.assertTrue(build.source_identity(True)["source_dirty"])

    def test_validation_failure_preserves_previous_release_and_manifest(self):
        self.assertEqual(self.run_build("validation_failure"), 1)
        self.assertEqual(self.output.read_bytes(), b"previous verified release")
        self.assertEqual(self.manifest.read_text(), "previous manifest")

    def test_source_mutation_during_validation_blocks_publication(self):
        self.assertEqual(self.run_build("source_changed"), 1)
        self.assertEqual(self.output.read_bytes(), b"previous verified release")
        self.assertEqual(self.manifest.read_text(), "previous manifest")

    def test_manifest_binds_binary_to_exact_clean_commit(self):
        commit = build.source_identity()["git_commit"]
        self.assertEqual(self.run_build(), 0)
        manifest = json.loads(self.manifest.read_text())
        self.assertEqual(manifest["git_commit"], commit)
        self.assertEqual(manifest["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertFalse(manifest["source_dirty"])
        self.assertFalse(manifest["manual_two_pc_test"])
        self.assertEqual((manifest["protocol"], manifest["save"], manifest["profile"]), (19, 5, 1))


if __name__ == "__main__":
    unittest.main()
