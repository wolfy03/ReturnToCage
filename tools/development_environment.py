"""Resolve the engine and private state for a ReturnToCage worktree."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
UPGRADE_BRANCH = "upgrade/godot-4.8"
VERSION = re.compile(r"(?P<release>\d+\.\d+(?:\.\d+)?\.(?:stable|beta\d+|rc\d+))\.official\.(?P<build>[0-9a-f]{7,40})")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], encoding="utf-8").strip()


def worktree(root):
    root = root.resolve(strict=True)
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        raise ValueError(f"Expected the worktree root: {root}")
    branch = git(root, "branch", "--show-current")
    upgrade = branch == UPGRADE_BRANCH or branch.startswith(UPGRADE_BRANCH + "-")
    pin_file = ".godot-upgrade-version" if upgrade else ".godot-version"
    pin = (root / pin_file).read_text(encoding="utf-8").strip()
    expected = pin if upgrade else pin + ".stable"
    state = Path(git(root, "rev-parse", "--absolute-git-dir")) / "rtc-development"
    return branch, upgrade, expected, state


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def identify(path, expected):
    executable = Path(path).resolve(strict=True)
    if not executable.is_file():
        raise ValueError(f"Godot is not a file: {executable}")
    actual = subprocess.check_output([str(executable), "--version"], encoding="utf-8", timeout=15).strip()
    match = VERSION.fullmatch(actual)
    if not match or expected not in (actual, match["release"]):
        raise ValueError(f"Expected official Godot {expected}; found {actual}")
    identity = {"path": str(executable), "version": actual, "build": match["build"], "sha256": sha256(executable)}
    if executable.stem.endswith("_console"):
        native = executable.with_name(executable.stem.removesuffix("_console") + executable.suffix)
        identity.update(native_path=str(native), native_sha256=sha256(native))
    return identity


def local_settings(state):
    config = state / "engine.json"
    return json.loads(config.read_text(encoding="utf-8")) if config.exists() else {}


def user_environment(directory):
    env = os.environ.copy()
    for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        path = directory / name.lower()
        path.mkdir(parents=True, exist_ok=True)
        env[name] = str(path)
    env["PYTHONUTF8"] = "1"
    return env
