"""Enumerate preview candidates in a process that the GUI can cancel."""

import json
import os
from pathlib import Path

from objects import DocumentError, validate_texture

MAX_LIBRARY_IMAGES = 5000


def scan_textures(directory, output):
    paths = []
    try:
        root = directory.resolve(strict=True)
        for folder, dirs, names in os.walk(root):
            base = Path(folder)
            dirs[:] = sorted(name for name in dirs if not name.startswith(".")
                             and name not in ("build", "venv", "node_modules")
                             and not (base / name).is_symlink() and not (base / name).is_junction())
            for name in sorted(names):
                if not name.lower().endswith(".png"):
                    continue
                try:
                    texture = (base / name).relative_to(root).as_posix()
                    validate_texture(texture)
                except DocumentError:
                    continue
                paths.append(texture)
                if len(paths) == MAX_LIBRARY_IMAGES:
                    break
            if len(paths) == MAX_LIBRARY_IMAGES:
                break
    except (OSError, RuntimeError):
        return 1
    output.write_text(json.dumps(paths, ensure_ascii=False), encoding="utf-8")
    return 0
