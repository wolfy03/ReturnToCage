"""Install official pinned Windows Godot and only its matching x86_64 templates.

Used by the Windows CI job. Existing user installations are never removed.
"""
import argparse
from pathlib import Path
import shutil
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--editor-dir", type=Path, required=True)
    parser.add_argument("--templates-dir", type=Path, required=True)
    args = parser.parse_args()
    version = (ROOT / ".godot-version").read_text().strip()
    base = f"https://github.com/godotengine/godot-builds/releases/download/{version}-stable"
    args.editor_dir.mkdir(parents=True, exist_ok=True)
    target = args.templates_dir / f"{version}.stable"
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rtc_godot_install_") as temporary:
        directory = Path(temporary)
        editor = directory / "editor.zip"
        urllib.request.urlretrieve(f"{base}/Godot_v{version}-stable_win64.exe.zip", editor)
        with zipfile.ZipFile(editor) as archive:
            for name in archive.namelist():
                if Path(name).name in (f"Godot_v{version}-stable_win64.exe", f"Godot_v{version}-stable_win64_console.exe"):
                    with archive.open(name) as source, (args.editor_dir / Path(name).name).open("wb") as dest:
                        shutil.copyfileobj(source, dest)
        required = [f"windows_{kind}_x86_64{suffix}.exe" for kind in ("debug", "release") for suffix in ("", "_console")]
        if any(not (target / name).exists() for name in required):
            templates = directory / "templates.tpz"
            urllib.request.urlretrieve(f"{base}/Godot_v{version}-stable_export_templates.tpz", templates)
            with zipfile.ZipFile(templates) as archive:
                for name in required:
                    with archive.open(f"templates/{name}") as source, (target / name).open("wb") as dest:
                        shutil.copyfileobj(source, dest)
        if any(not (target / name).exists() for name in required):
            raise RuntimeError("Official export template installation is incomplete")
    print(f"Installed official Godot {version} Windows editor and x86_64 templates")


if __name__ == "__main__":
    main()
