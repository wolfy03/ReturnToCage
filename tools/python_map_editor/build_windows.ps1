param(
    [Parameter(Mandatory)][string]$Python,
    [string]$OutputRoot = (Join-Path $PSScriptRoot "../../build/python-map-editor")
)

$ErrorActionPreference = "Stop"
$pythonExe = (Resolve-Path -LiteralPath $Python).Path
$version = & $pythonExe -c "import platform, struct; print(platform.python_version(), struct.calcsize('P') * 8, platform.machine())"
if ($LASTEXITCODE -ne 0 -or $version -ne "3.14.5 64 AMD64") {
    throw "The Windows build requires Python 3.14.5 x64. Found: $version"
}
New-Item -ItemType Directory -Force $OutputRoot | Out-Null
$root = Join-Path (Resolve-Path -LiteralPath $OutputRoot).Path ([guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory $root | Out-Null
$originalPath = $env:PATH
try {
    # Exclude unrelated native DLLs installed by other development tools.
    $env:PATH = Join-Path $env:SystemRoot "System32"
    & $pythonExe -m PyInstaller --noconfirm --clean --workpath "$root/work" --distpath "$root/dist" "$PSScriptRoot/ReturnToCageMapEditor.spec"
    if ($LASTEXITCODE -ne 0) {
        throw "PyInstaller failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:PATH = $originalPath
}
$distribution = Join-Path $root "dist/ReturnToCageMapEditor"
Copy-Item -LiteralPath "$PSScriptRoot/README.txt" -Destination $distribution
$notices = Join-Path $distribution "licenses"
New-Item -ItemType Directory $notices | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot/upstream_licenses/LGPL-3.0-only.txt","$PSScriptRoot/upstream_licenses/GPL-3.0-only.txt" -Destination $notices
& $pythonExe -c @'
import importlib.metadata as metadata
from pathlib import Path
import shutil
import sys

output = Path(sys.argv[1])
shutil.copyfile(Path(sys.base_prefix) / "LICENSE.txt", output / "Python-LICENSE.txt")
for name in ("PySide6-Essentials", "shiboken6", "PyInstaller"):
    dist = metadata.distribution(name)
    target = output / name
    target.mkdir()
    for entry in dist.files or ():
        if entry.name.lower().startswith(("license", "copying", "notice")) or "licenses" in entry.parts:
            if dist.locate_file(entry).is_file():
                destination = target.joinpath(*entry.parts[-2:])
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(dist.locate_file(entry), destination)
'@ $notices
if ($LASTEXITCODE -ne 0) {
    throw "Failed to copy third-party license notices"
}
Compress-Archive -LiteralPath $distribution -DestinationPath "$root/ReturnToCageMapEditor-PY-STEP3-win-x64.zip"
Write-Output "EXE $distribution/ReturnToCageMapEditor.exe"
Write-Output "ZIP $root/ReturnToCageMapEditor-PY-STEP3-win-x64.zip"
