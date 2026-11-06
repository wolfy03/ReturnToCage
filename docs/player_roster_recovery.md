# Player presentation roster recovery (Stage 2)

Audited master: `1b129d60cd2a487aef30b1bb617db20e23553d92`, including Stage 1
Disconnect recovery. Protocol 16, Save 4 and Profile 1 are unchanged.

## Reproduction and causes

Real ENet 2-player and 3-player probes reproduced B disappearing from the Host
presentation after Sewer → Settlement. The authoritative runtime still contained
B. Fresh initial joins worked in these reproductions; the failure was world
leave/re-entry, not a universal failure to attach a new Client.

`_broadcast_world_arrival()` notified remote peers but omitted the local Host.
`_on_player_world_changed()` hid/stopped departing presentation actors; later
ready reconciliation could remove them, but no local arrival recreated them.
If the hidden actor remained, roster handling ignored it as already present.
The same roster signal also reached authoritative spawners without an explicit
role guard. The focused baseline had seven failing assertions.

A separate 3-player respawn movement check exposed actor-local sequence reset:
the replacement server actor accepted an in-flight old input (sequence 1597),
then rejected the replacement presentation actor's inputs starting at 1.
Transform sequence reset can likewise freeze a new presentation after a late old
snapshot. Two deterministic replacement tests reproduced these ordering failures.

## Behavior

- Host local roster delivery and Client RPC receipt use shared validation and
  application helpers. Persistent identity, attachment, session, world and exact
  accepted revision must agree. The server also checks its authoritative spawn
  assignment's identity/session/error/finite position before publishing.
- The Host uses local signals, without sending an ENet RPC to itself. Late scene
  initialization still requests the full current-world roster. Registration,
  committed arrival and world-ready completion can safely deliver duplicates.
- Presentation departure removes the old node immediately. Repeated valid roster
  delivery restores a suspended actor without duplicates and leaves an already
  active actor's position unchanged. Stale departure/arrival payloads cannot
  regress the client world mirror or remove a returned player.
- Authoritative spawners ignore presentation roster events. Existing
  `ServerWorldRoot` / isolated `World2D` runtime simulation remains the owner of
  movement, damage and combat. Presentation actors keep simulation disabled and
  hurtbox monitoring disabled; only the local presentation reads input intents.
- `PlayerRuntimeState.move_input_sequence` and `transform_sequence` retain
  ordering across actor replacement. They belong to the current peer attachment
  and are discarded with its runtime registry on detach/reset. They are never
  serialized or added to a wire payload. World assignment revisions and the
  existing transport-generation guards remain in effect.

No character art, equipment appearance, enemy/loot rules, or gameplay balance is
changed. Stage 1 menu recovery is covered by the existing regression harness.

## Verification

`tests/integration/test_player_presentation_roster.gd` covers departure/re-entry,
assignment validation, runtime/presentation separation, idempotent visibility,
stale RPC mirror handling and actor replacement ordering. It is included in the
full suite and can run alone with `--roster-only`.

```sh
godot --headless --path . res://tests/test_runner.tscn -- --roster-only
python tools/test_multiplayer_roster.py --godot <godot-4.7.2> --players 2
python tools/test_multiplayer_roster.py --godot <godot-4.7.2> --players 3
python tools/test_multiplayer_roster.py --godot <godot-4.7.2> --players 2 --rendered
python tools/test_multiplayer_roster.py --godot <godot-4.7.2> --players 3 --rendered
```

The ENet harness runs real Boot scenes in separate, persistent OS processes with
isolated user data/profiles. It checks visible/process-enabled presentation actor
identity sets on every screen and separately checks authoritative runtime actor
sets. Scenarios cover initial join and two-way movement, B Sewer round trip,
Host-first Sewer entry followed by B, the A/B Settlement–C Sewer split and C
return/re-entry, same-world and Adventure death/respawn, persistent-identity
reconnect, duplicate delivery and invalid roster data. Movement assertions sample
both transform displacement and the run animation/facing while production input
intents execute on the server.

The existing world-runtime E2E also explicitly checks the Host presentation before
departure and after independent returns, in addition to its runtime checks.
Run process tests sequentially. Rendered checks use Compatibility by default and
reject a headless display server. This verifies local Windows rendering, not
two-physical-PC network conditions. CI runs the 2/3-player harness on Linux and
Windows and uploads logs/step results. Any nonzero process exit, engine error or
leak warning fails the harness, even after scenario assertions pass.

The test mailbox retries atomic command/result file replacement for up to three
seconds when a Windows reader holds a sharing lock. It never repeats gameplay
commands. The Windows probe exercises result publication with a temporarily held
reader before reporting ready. Publication failures remain fatal and pending
result files are included in CI diagnostics.
Final tree shutdown is deferred until the command coroutine releases its captures;
scene removal and pending background resource loads must finish first.
