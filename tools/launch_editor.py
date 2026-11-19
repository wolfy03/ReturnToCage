"""Configure or open a worktree using its pinned Godot editor."""

import argparse
import json
from pathlib import Path
import subprocess

from development_environment import ROOT, identify, local_settings, user_environment, worktree


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worktree", type=Path, default=ROOT)
    parser.add_argument("--godot", type=Path, help="Explicit executable. Required with --configure.")
    parser.add_argument("--templates", type=Path, help="Save an extracted template folder for upgrade validation.")
    parser.add_argument("--configure", action="store_true")
    args = parser.parse_args()
    if args.configure and not args.godot:
        parser.error("--configure requires --godot")
    if args.templates and not args.configure:
        parser.error("--templates requires --configure")
    try:
        branch, _, expected, state = worktree(args.worktree)
        path = args.godot or local_settings(state).get("godot")
        if not path:
            parser.error("configure this worktree's Godot path or supply --godot")
        engine = identify(path, expected)
        print(json.dumps({"branch": branch, **engine}), flush=True)
        if args.configure:
            config = {"godot": engine["path"]}
            if args.templates:
                config["templates"] = str(args.templates.resolve(strict=True))
            state.mkdir(parents=True, exist_ok=True)
            (state / "engine.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
            return 0
        env = user_environment(state / "editor-user")
        return subprocess.call([engine["path"], "--path", str(args.worktree.resolve()), "--editor"], env=env)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
