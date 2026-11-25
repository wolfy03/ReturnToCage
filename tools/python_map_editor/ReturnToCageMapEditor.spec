from pathlib import Path

source = Path(SPECPATH)
bridge = source.parent / "map_bridge"
# Ship the bridge scripts without Godot's .uid sidecars. The staged project
# gets fresh ones, and a build folder inside the project would otherwise
# duplicate the committed UIDs and make the editor scan warn.
bridge_files = [(str(path), str(Path("map_bridge") / path.relative_to(bridge).parent))
                for path in sorted(bridge.rglob("*"))
                if path.is_file() and path.suffix != ".uid" and "__pycache__" not in path.parts]
analysis = Analysis(
    [str(source / "main.py")],
    pathex=[str(source), str(source.parent)],
    datas=[*bridge_files,
           (str(source.parent.parent / "assets" / "terrain"), "assets/terrain")],
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
