"""Deploy a pinned Mesa software OpenGL renderer beside CI executables only.

No system driver changes; these DLLs are excluded from the distributed artifact.
Upstream: https://github.com/pal1000/mesa-dist-win/releases/tag/25.1.6
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

VERSION = "25.1.6"
SHA256 = "7b4dea5f4fdd362acaffd13f4dd01de3b1e3f67a24c89ab92957eeb8a404e23d"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, action="append", required=True)
    parser.add_argument("--7zip", dest="seven_zip", default="7z")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rtc_ci_mesa_") as temporary:
        root = Path(temporary)
        archive = root / "mesa.7z"
        urllib.request.urlretrieve(
            f"https://github.com/pal1000/mesa-dist-win/releases/download/{VERSION}/mesa3d-{VERSION}-release-msvc.7z", archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
            raise RuntimeError("CI Mesa download SHA-256 mismatch")
        subprocess.run([args.seven_zip, "x", str(archive), f"-o{root / 'unpacked'}", "-y"],
                       check=True, stdout=subprocess.DEVNULL, timeout=120)
        candidates = list((root / "unpacked").rglob("x64/opengl32.dll"))
        if len(candidates) != 1:
            raise RuntimeError("CI Mesa archive has no unique x64 OpenGL deployment")
        drivers = list(candidates[0].parent.glob("*.dll"))
        if not any(driver.name == "libgallium_wgl.dll" for driver in drivers):
            raise RuntimeError("CI Mesa Gallium dependency is missing")
        for destination in args.destination:
            destination.mkdir(parents=True, exist_ok=True)
            for driver in drivers:
                shutil.copy2(driver, destination / driver.name)
    print(f"Installed per-application CI Mesa {VERSION}, sha256={SHA256}")


if __name__ == "__main__":
    main()
