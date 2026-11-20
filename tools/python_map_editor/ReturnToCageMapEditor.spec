from pathlib import Path

source = Path(SPECPATH)
analysis = Analysis(
    [str(source / "main.py")],
    pathex=[str(source)],
)
# Qt6Core uses Windows' unsuffixed ICU exports. A vendor ICU DLL collected
# from the build machine can shadow the OS DLL with incompatible exports.
analysis.binaries = [
    entry for entry in analysis.binaries
    if not Path(entry[0]).name.lower().startswith(("icuuc", "icuin", "icudt", "icu.dll"))
]
archive = PYZ(analysis.pure)
executable = EXE(
    archive,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="ReturnToCageMapEditor",
    console=False,
    upx=False,
)
distribution = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    name="ReturnToCageMapEditor",
    upx=False,
)
