"""Per-user settings: recent files, paths and window layout. Never stored in a document or in the game.

A plain JSON file, so the application layer stays free of Qt and the file can be tested and repaired by
hand. A missing or damaged file falls back to defaults; the damaged file is kept next to it for inspection.
"""

import json
import os
from pathlib import Path
import tempfile

RECENT_LIMIT = 10
DEFAULTS = {
    "project_root": "",
    "godot_path": "",
    "drafts_folder": "",
    "logs_folder": "",
    "recent_projects": [],
    "recent_documents": [],
    "window_geometry": "",       # base64 of QMainWindow.saveGeometry()
    "window_state": "",          # base64 of QMainWindow.saveState()
    "catalog_filter": "all",
    "catalog_search": "",
}


def default_path():
    base = os.environ.get("APPDATA") or os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "ReturnToCage" / "MonsterEditor" / "settings.json"


class Settings:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else default_path()
        self.values = dict(DEFAULTS)
        self.recovered = False       # True when a damaged file was replaced by defaults
        self.load()

    def load(self):
        self.values = {key: (list(value) if isinstance(value, list) else value) for key, value in DEFAULTS.items()}
        try:
            payload = self.path.read_bytes()
        except OSError:
            return
        try:
            data = json.loads(payload.decode("utf-8"))
            if not isinstance(data, dict):
                raise ValueError("settings are not an object")
        except (UnicodeError, ValueError, RecursionError):
            self.recovered = True
            try:
                self.path.replace(self.path.with_suffix(".damaged.json"))
            except OSError:
                pass
            return
        for key, default in DEFAULTS.items():
            value = data.get(key, default)
            # A value of the wrong type is ignored, not trusted.
            if isinstance(default, list):
                if isinstance(value, list) and all(isinstance(item, str) for item in value):
                    self.values[key] = value[:RECENT_LIMIT]
            elif isinstance(value, str):
                self.values[key] = value

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(self.values, ensure_ascii=False, indent=2).encode("utf-8")
        with tempfile.NamedTemporaryFile(dir=self.path.parent, prefix=".settings-", delete=False) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(payload)
                stream.flush()
                stream.close()
                os.replace(temporary, self.path)
            finally:
                stream.close()
                temporary.unlink(missing_ok=True)

    def get(self, key):
        return self.values[key]

    def set(self, key, value):
        if key not in DEFAULTS or type(value) is not type(DEFAULTS[key]):
            raise KeyError(key)
        self.values[key] = value

    def remember(self, key, entry):
        """Put ``entry`` at the front of a recent list, without duplicates, capped at RECENT_LIMIT."""
        entry = str(entry)
        items = [item for item in self.values[key] if item != entry]
        self.values[key] = [entry] + items[:RECENT_LIMIT - 1]

    def forget(self, key, entry):
        self.values[key] = [item for item in self.values[key] if item != str(entry)]
