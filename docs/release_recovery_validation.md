# Integrated recovery and release validation (Stage 3)

Baseline master: `96e1c0f1b20db661148331f15b97da73ddbafaca` (Stages 1 and 2).
Godot 4.7.2 / Protocol 16 / Save 4 / Profile 1 remain unchanged. This stage
extends validation and release provenance, without new gameplay or artwork.

## Covered bugs

Stage 1 fixed the full-screen HUD intercepting menu clicks after Disconnect,
retained Adventure state blocking Load, stale SceneRouter assignment revisions,
old actor signals and reentrant menu transitions. The HUD now follows the active
phase/session, old references and assignment caches are retired, and menu actions
wait for scene cleanup. Existing persistent identity and disk Saves are retained.

Stage 2 fixed omitted Host-local arrival notifications and hidden/stopped actors
being treated as already present after world re-entry. Host and Client share
roster validation/application, departing actors are removed and idempotent arrival
restores visibility without duplicate simulation. Transient input/transform
ordering survives actor replacement so respawn/re-entry cannot freeze movement.
Details: [disconnect recovery](multiplayer.md#disconnect-recovery-stage-1) and
[player roster recovery](player_roster_recovery.md).

## Same-process integrated sequence

`tools/test_session_recovery.py` controls three persistent OS processes through
the normal Boot scene. Each role has its own native user-data directory and
new test identity. It launches each role exactly once and checks its reported
process ID and player ID after every action. Editor and exported EXE use
`core/validation/session_recovery_probe.gd`; the existing Stage 2 probe is a thin
wrapper over the same assertions. Existing assertions remain in that shared probe.

1. A clicks New Game, moves with normal input, and clicks Save to create an
   isolated Save v4 fixture containing a known inventory marker.
2. A clicks Host directly from single-player; B clicks Join. Both screens check
   the complete same-world roster and each other's moving/run-animated actor.
3. D joins as a third Client. B enters Sewer, then A enters Sewer. All screens
   check same-world actor sets and cross-world absence. B returns/re-enters.
4. A clicks Disconnect; A/B/D must reach a clean menu. A clicks New Game and
   moves offline, returns to menu, clicks Load and verifies the original Save.
5. A clicks Host Save; B rejoins, manually disconnects, starts/moves in an offline
   New Game, returns to menu and rejoins A again in the same process.
6. A disconnects. D becomes a new Host without restarting. B joins D at `::1`
   after previously using A at `127.0.0.1`; B/D see each other move. Both leave.

New/Load/Save/Host/Host Save/Join/Disconnect use `Viewport.push_input` mouse
motion/down/up and must actually emit the button signal through GUI hit testing.
Only the isolated port is supplied to the production Host/Join handlers. Offline
fixture return-to-menu invokes the existing production cleanup path directly;
this does not add an offline menu button or claim that such a button was tested.
World-distance fixtures position the server actor at the actual authored gate or
escape point before the normal intent request. Simulation remains authoritative.

Menu checks cover the complete Stage 1 cache/reset invariants, empty runtimes,
one persistent local identity, no session, hidden/unbound HUD, no presented world
and enabled actions. Offline movement verifies restored simulation authority.
Roster checks validate exact identity sets, visible/process-enabled actors,
world ownership, separate authoritative actors and disabled presentation damage.
The original Profile and Save hashes must remain unchanged through recovery.

Every command report and failure log contains `NetworkManager`, `GameSession`,
`SceneRouter` and `PlayerSpawnManager` state, including ready/pending/spawn keys,
world/revision, actor identity/visibility/process/simulation and runtime rosters.
The driver preserves `steps.json`, `failure.json`, bootstrap reports and engine
logs. A nonzero exit or engine error/warning is fatal even after assertions pass.

## Commands and release gate

Run process tests sequentially, with official pinned editor/templates:

```powershell
python tools/check_project.py --godot <Godot-console.exe>
python -m unittest discover -s tools/tests -p test_windows_release_validation.py
python tools/test_session_recovery.py --godot <Godot-console.exe>
python tools/build_windows_demo.py --godot <Godot-console.exe> --rendered --rendering-method gl_compatibility
```

The build keeps all existing content parity and EXE/EXE, Editor/EXE, EXE/Editor
checks. Both headless and rendered passes now also run the entire integrated
sequence against the actual pending release EXE, outside the project directory
and without a project `--path`. Rendered results require the Windows display
server; headless execution alone cannot pass a requested GUI check.

`--rendered` without `--rendering-method` retains the default renderer check.
Compatibility GUI CI uses pinned per-application Mesa; this tests a
software renderer, not a physical graphics card or performance. The Mesa DLLs are
excluded from `ReturnToCage-Windows-Demo-x86_64`, which contains only the embedded
PCK EXE, `build_manifest.json`, and `SHA256SUMS.txt`.

The previous published EXE/manifest remain intact if validation fails. Source
changes during validation or a changed EXE hash also block publication. Four
Python boundary tests cover dirty-source rejection, failed GUI/roster validation,
source mutation and exact commit/binary manifest binding. The legacy normal ENet
probe now retires scene/resources before successful engine shutdown; its abrupt
Host-exit scenario still retains transport until process exit, and its gameplay,
privacy, reconnect and exit-code success conditions are unchanged.

Release builds require a clean source checkout. `--allow-dirty` is available only
for local preflight and explicitly records `source_dirty=true`; CI does not use
it. `build_manifest.json` schema 1 includes the full `git_commit`, branch,
`source_dirty`, UTC build time, engine/protocol/save/profile versions, actual EXE
SHA-256, embedded-PCK status and headless/GUI lifecycle results with stable process
IDs. GitHub builds verify the checkout SHA equals `GITHUB_SHA`.

Verify provenance with the downloaded manifest, not the EXE filename:

```powershell
$manifest = Get-Content build/windows/build_manifest.json | ConvertFrom-Json
$manifest.git_commit
(Get-FileHash build/windows/ReturnToCage_Demo.exe -Algorithm SHA256).Hash -eq $manifest.sha256
```

CI uploads the demo only after all Windows validation steps succeed; diagnostics
are uploaded even on failure. The full Linux job additionally runs normal ENet
2/3-player, Host disconnect, the original world/restart/authority/protocol tests,
Stages 1/2 and the integrated sequence. No existing test or assertion is removed.

## Limits

The automated tests use independent local processes and isolated identities.
They do not certify two physical PCs, a LAN/firewall/NAT setup, every graphics
driver or performance. Every manifest records `manual_two_pc_test=false`.
Unsigned Windows executables may require the usual local trust decision. Active
Adventure persistence and Host migration remain outside this work.
