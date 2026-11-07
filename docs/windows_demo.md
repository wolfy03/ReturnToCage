# Windows demo export and verification

Godot **4.7.2**, Windows Desktop **x86_64 release**. The current build uses
NetworkProtocol **17**, Save **5**, and Local Profile **1**. Build from the latest `master`;
existing uncommitted art and other user files are not part of a reproducible
repository build and must be preserved separately.

## Export failures reproduced

The original registry walked physical `DirAccess` entries and accepted only
`.tres` names. An actual release EXE built from baseline
`de7853aa2178ea4a49bd498362cd20df8d37c9dc` registered **zero** content definitions.
Its physical listing contained `default_game_start.tres.remap`, while
`ResourceLoader.list_directory()` returned `default_game_start.tres`. The
resource was packed, but the registry silently skipped it. Consequently
GameSession initialization and the client's session snapshot failed.

The registry now recursively enumerates logical resource paths using
`ResourceLoader.list_directory()` and loads through `ResourceLoader.load()`.
It accepts `.tres` and `.res`, orders traversal deterministically, rejects wrong
types, empty IDs and duplicate IDs, and reports paths for both duplicate sources.
An empty/missing directory and absent mandatory start/default difficulty are
explicit validation failures rather than a misleading successful empty registry.
No content resource filenames were changed.

A second release-only failure appeared after the registry fix: threaded
environment loading supplied `EnvironmentDefinition` as a loader type hint.
The binary `.res` loader did not recognize this GDScript custom class hint.
It now receives the native `Resource` hint; `EnvironmentPresenter` retains its
existing custom-resource type validation and fallback behavior. The EXE checks
exercise a cold threaded Settlement load, not just a cached resource lookup.

Snapshot application checks start content, selected difficulty, global content
validation, phase and identity mappings before retiring existing models. Its
precise failure reason is copied into NetworkManager's UI error before transport
cleanup, for example:

```text
[NET] Session snapshot rejected: Missing GameStartDefinition: default_game_start
[NET] Session snapshot rejected: Unknown difficulty: normal
```

## Build a verified release

Python 3.10+ and the official Godot 4.7.2 Windows editor/export templates are
required. Existing installations can be used. The optional installer downloads
only official pinned release assets and installs x86_64 templates without
removing other versions:

```powershell
python tools/install_windows_godot.py --editor-dir C:\Tools\Godot --templates-dir "$env:APPDATA\Godot\export_templates"
python tools/build_windows_demo.py --godot C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe --rendered
```

The preset is `Windows Desktop` in `export_presets.cfg`. It exports all resources,
including dynamically discovered content and dynamically loaded world/background/
player presentation resources. Root test suites, tools, docs, build output and
GitHub files are excluded. Debug UI remains part of Boot's dependency graph but
is disabled by its existing release guard. A small opt-in release verification
driver is retained so the shipped EXE itself can be checked; it uses the normal
Boot, GameSession, SceneRouter and network paths, not alternate gameplay RPCs.

The build script imports and exports to a pending EXE, inspects its PE x86_64
header and embedded PCK footer, and executes it outside the source project.
Only a successful executable replaces `build/windows/ReturnToCage_Demo.exe`.
The EXE is a single runtime file; no loose PCK or console wrapper is needed.
`build_manifest.json` and `SHA256SUMS.txt` are optional provenance metadata.
Generated output is ignored by Git. Code signing is not configured.

## What the executable checks prove

```powershell
python tools/test_windows_export.py --godot <Godot-console.exe>
python tools/test_windows_export.py --godot <Godot-console.exe> --rendered
```

The checker runs the actual release EXE without a project `--path` and uses a
fresh native `user://` root for every process, isolating test profiles from the
production identity. It verifies:

- Identical Editor/EXE content ID rosters, start definition, all difficulty IDs,
  complete content validation, dynamically loaded resources, local profile and
  GameSession initialization.
- Actual EXE/EXE ENet Host/Join, Editor Host/EXE Client, and EXE Host/Editor Client.
- Protocol 16 acceptance, session and owner-private snapshots, spawn/world
  assignments, world-ready state, Settlement and its asynchronously loaded
  environment. Both roles must agree on session ID and have different persistent
  player IDs/native user directories.
- Nonzero exit, missing stages, engine errors/warnings, content roster mismatch,
  unexpected debug/editor exports, or changed Save/Profile/Protocol versions fail
  the check. Logs and JSON reports remain in the printed artifact directory.

`--rendered` runs without `--headless` and checks that a real Windows display
server was used. Local verification also initialized the default D3D12 Forward+
renderer on an NVIDIA GeForce RTX 3070 Laptop GPU. Headless validation does not
claim to test a graphics device. The checker refuses to report Windows EXE
execution success on a non-Windows OS.

## Distribution and two-PC play

Copy `ReturnToCage_Demo.exe` to each Windows x86_64 PC. Start Host on one PC and
Join using that PC's LAN IPv4 address on the other (UDP 7777). Each PC creates its
own normal profile under its own Windows user data directory. For same-PC tests,
use the checker above: launching two ordinary copies under the same Windows user
shares the production profile and correctly triggers duplicate identity rejection.

The automated results cover independent local Windows processes over ENet.
Two physical PCs on a LAN, other graphics devices, and firewall configurations
still require testing in that environment; no such result is reported as PASS.

GitHub Actions keeps all existing Linux regressions and adds a Windows job that
builds a release and actually runs EXE content and all three Host/Join pairings.
Only a successful build uploads `ReturnToCage-Windows-Demo-x86_64`; diagnostic
logs are uploaded separately, including on failure. CI keeps headless verification
and additionally requests the default Windows renderer without `--headless`.
The actual display server/rendering method are recorded in the manifest and logs.
This does not certify a physical graphics device or two-PC LAN operation.

Reference: [Godot ResourceLoader logical directory listing](https://docs.godotengine.org/en/stable/classes/class_resourceloader.html#class-resourceloader-method-list-directory).

## Local verification results

- Editor/Export: identical 29 content IDs; `default_game_start` and
  `normal`/`story`/`survival` found; content validation PASS.
- Actual release EXE initialization and EXE/EXE, Editor/EXE, EXE/Editor ENet
  sessions: PASS in both headless and default-renderer modes.
- Full Godot project check: 4,384 assertions PASS, restart writer/reader PASS,
  import, content and sprite pipeline validation, main-scene smoke PASS.
- Existing normal ENet 2/3-player, host disconnect, process restart
  2-player valid/invalid and 3-player privacy, individual-world 2/3-player,
  WorldRuntime 2/3-player, authority 2/3-player and protocol rejection: PASS.
- One initial Editor process-restart probe exited with native Windows code
  `0xC0000005` after its seed-complete marker. A focused rerun and the subsequent
  complete remaining process matrix passed. No assertion or timeout was removed;
  this observation is not presented as a diagnosed/fixed engine issue.

The release binary is approximately 114 MiB with an embedded PCK. Build and
validation results are generated artifacts rather than committed binaries.

## Inventory and equipment release gate (6-C)

The same-process probe starts offline and uses the normal GUI to move an
inventory stack, equip gear, craft at the workbench, and save. It checks slot
indices, quantities, equipment IDs, final stats, and storage after Load, then
continues through two- and three-player ENet, world travel, reconnect, and
offline New Game followed by rehosting. The old item presenter connection and
the pending state are checked during teardown. The Windows artifact is published
after the Linux regression job and all Windows checks have passed.

The valid process-restart fixture uses Settlement locations outside Milo's
patrol corridor so transient collision occupancy cannot invalidate its
expected exact restore. The invalid-position case still checks fallback and
healing. The controller preserves per-process output on failure. A result
publication error, timeout, or nonzero exit remains a failed run, including
native Windows `0xC0000005` after a Godot PASS marker. Rendered and headless
results are reported separately.
