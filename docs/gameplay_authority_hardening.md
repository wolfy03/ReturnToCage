# Multiplayer gameplay authority and lifecycle hardening

Audit baseline: `89c05f55c1444067464d875fb03a163f31b4e483`. At the start of this
work, fetched `origin/master` and local HEAD both matched this commit. Godot is
pinned to **4.7.2**. Existing user art, animation tests, and documentation changes
were preserved in the original checkout; implementation and checks used an
isolated worktree.

## Reproduced defects and retained guards

The new regression fixture was run against an isolated copy of the baseline.
It produced 14 failing assertions (17 passing), including state-preservation
assertions. It reproduced distant Settlement entry, distant normal escape,
return-item result forgery, missing remote return-item handler, host-facade
discovery failure, persistent-owner recovery rejection, and acceptance of an
out-of-bounds finite Settlement return position. The unchanged baseline full
project check passed before these tests were introduced.

Existing authoritative HURT/Dodge, alive, world-ready/revision, identity,
owner-private snapshot, transport generation, and world interest guards were
retained. Existing HURT/Dodge regression fixtures now arrange valid proximity
before their successful transition assertions. Rejection assertions remain.

Real death testing also reproduced self-collision during respawn clearance.
A separate regression reproduced a Settlement player's inventory being penalized
when the host's compatibility facade pointed at an Adventure. Both have focused
regressions: the retiring actor's RID is excluded from respawn queries, and
multiplayer death resolution never falls back to the host's Adventure session.
World-specific rule lookup also excludes the host facade; offline lookup retains
its matching-world rules snapshot.

## Intent boundary

The reliable client APIs are:

- `request_escape_at_point(point_id)`
- `request_use_return_item()`
- `request_recover_death_drop(drop_id)`
- `request_enter_region(exit_id, region_id)`

Their wire requests bind to the sender's current world and exact world revision.
The server derives persistent identity from its attachment registry. It validates
the living, ready player and authoritative actor, rejects HURT/Dodge and pending
transitions, and resolves interactions from that player's server runtime.

`InteractionTarget.is_in_range()` intersects the existing authored interaction
shapes using authoritative transforms. No client coordinates or duplicated
distance constants authorize entry, escape, or recovery. Escape points additionally
require the region's declared escape ID, `EscapePoint2D.can_interact()` and its
existing landing policy. Settlement entry retains `ExitService` connection,
unlock, and entry-marker checks. The old result-selecting RPC always rejects;
its public compatibility method resolves a nearby point in multiplayer and
retains the existing offline scene-router path.

## Return channel and transition commit

Only the authoritative actor mutates channel duration, origin, and movement lock.
Quick-item input on a presentation actor requests the server intent. The server
checks possession of `return_seed`, region permission, alive/ready Adventure
state, HURT/Dodge/climb, and an existing channel. Repeated starts cannot reset or
complete a running channel.

Movement, displacement, damage, HURT, committed dodge, death, world/revision
change, disconnect, despawn, and session reset cancel the channel. Cancellation
restores channel movement and consumes nothing. Owners receive reliable,
world/revision-filtered progress events in twentieths; presentation does not run
a completion clock or change its gameplay channel fields.

The multiplayer completion path validates the actor's completed channel again,
reserves the actual destination runtime, and obtains a `PlayerSpawnPolicy`
decision before registering a destination assignment. Settlement candidates must
be finite, within bounds, collision-clear, supported, and have a nonzero collision
mask. Invalid safe positions use deterministic configured markers and heal the
canonical safe position only on success. Adventure entries try configured slot
offsets deterministically, so an occupied slot does not reject another valid slot.

Preflight uses the runtime scene's actual collision shapes. Direct shape tests
also work before a new `World2D` broadphase tick; dynamic bodies count for
clearance, static bodies for walkable support. No arbitrary zero-position spawn
is substituted. Missing scenes, incompatible runtime roots, absent spawners,
invalid masks, and exhausted valid markers fail before canonical mutation.
Unoccupied preflight runtimes are released on failure; existing occupied worlds
are retained.

`finish_player_adventure()` stages the Settlement world candidate and validates
all loot instances before consuming an item or transferring loot. Inventory and
Settlement notifications are batched through the commit. Exactly one return item
is removed, participation is retired, the staged world is installed, and then
observers receive committed state. Storage overflow retains the existing pending
loot semantics. If staging or item removal fails, the previous spawn assignment
is restored and world, revision, participation, inventories, storage, and readiness
remain unchanged. There is no fallible `move_player_to_world()` call after securing
loot.

## Death drops and discovery

Recovery resolves peer → canonical player ID → current `PlayerWorldState` →
world's `AdventureSession`. Persistent ownership uses **only `owner_player_id`**.
`owner_peer_id` is legacy diagnostic data and is never saved or used to authorize
recovery. Ownerless legacy Save v4 records retain their shared recovery behavior.

`DeathDropManager` creates a world entity when authoritative death resolution
emits a new record, and recreates retained records when a runtime is created.
It uses the existing world-scoped `NetworkEntityRegistry`. The public roster
contains drop ID, transient entity ID, availability, and position; it contains
neither inventory contents nor owner-private state. Only ready peers in that
world receive spawn/update/despawn events, including a late-entry roster.

Recovery validates the authoritative interaction range and persistent owner.
The domain model batches inventory notifications and locks the record while
updating its remainder. Duplicate or synchronous reentrant claims cannot mint
items. Partial inventory acceptance leaves the remaining stacks at the death
site. Reconnection creates a new peer attachment but retains drop ownership;
the existing disconnect policy for unsecured expedition loot is unchanged.

`discover_escape_for_peer()` verifies the declared point against the requesting
player's runtime and records it in that world's session. Existing once-per-session
discovery and quest event scope policy is preserved. The host-local facade is
used only by the offline compatibility API.

## Versions and validation

**NetworkProtocol 16**, **Save v4**, **Local Player Profile v1**. The new RPCs and
wire signatures require the protocol bump. A real ENet probe sends a v15
handshake and verifies rejection before any canonical attachment. Save schema
and migration requirements are unchanged. Channel timers, peer IDs, runtime IDs,
pending transitions, world-ready state, and sequence caches are not added to Save.

Run the existing full check and sequential process suites from `docs/testing.md`
and `CLAUDE.md`, plus:

```sh
godot --headless --path . res://tests/test_runner.tscn -- --authority-only
python tools/test_multiplayer_authority.py --godot godot --players 2
python tools/test_multiplayer_authority.py --godot godot --players 3
python tools/test_multiplayer_protocol.py --godot godot --players 2
```

The authority unit/integration fixture checks denied-state invariants, landing,
proximity, pending transitions, completed-channel authorization, movement/damage/
HURT/dodge/displacement/disconnect cancellation, missing or forbidden items,
exact consumption, item-removal failure, invalid loot staging, spawn fallback,
runtime creation failure, persistent ownership, reentrant recovery, remainder,
discovery, cross-world death isolation, and respawn self-collision.

The new process probe uses actual client RPCs for forged normal/return-item
results, distant entry/escape, invalid IDs, wrong-world and wrong-owner recovery,
duplicate return starts/recovery, and stale entry replay. It checks successful
normal escape, owner progress, server channel completion, production death,
same-world spawn/despawn, late-entry roster, changed-peer reconnect, persistent
owner recovery, stable identities, and C's surviving runtime while Host remains
in Settlement. Host-side position changes only arrange test geometry; they do
not replace the production intent or authorization path. All processes are
headless automation, not a claim of manual visual playtesting.

GitHub Actions adds both authority process sizes and protocol mismatch without
removing existing project, restart, individual-world, or world-runtime checks.
Host migration, dedicated server, NAT/relay, matchmaking, active Adventure/empty
world persistence, equipment appearance, and character art remain outside scope.

### Local results (Godot 4.7.2)

Baseline full suite: 4,270 assertions. Final full suite: **4,369 assertions**,
with restart writer (1 assertion), restart reader (25 assertions), content and
sprite pipeline validation, import, and main-scene smoke all passing. The first
implementation commit was independently exported and passed the complete project
check before it was committed.

| Separate-process check | Result |
| --- | --- |
| Normal ENet 2 / 3 players, including same-session reconnect | PASS / PASS |
| Host disconnect | PASS |
| Process restart: 2-player valid / invalid safe position | PASS / PASS |
| Process restart: 3-player owner privacy | PASS |
| Individual world: 2 / 3 players | PASS / PASS |
| World runtime: 2 / 3 players | PASS / PASS |
| Gameplay authority: 2 / 3 players | PASS / PASS |
| Actual v15 handshake against v16 server | PASS (rejected) |

The legacy normal 2-player probe timed out once at its jump input stage during
consolidated validation. Earlier standalone checks and the final rerun passed;
its assertions and timeout were retained. The new probe's own typed-array and
freed-capture fixture mistakes were corrected before the final process results.
