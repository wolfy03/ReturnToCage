# Multiplayer foundation

This is an experimental 2-4 player cooperative host game foundation. It is intended for localhost and direct-IP LAN development tests, not internet play.

## Authority model

The host runs both the authoritative server and its local client. Remote clients send movement and attack/pickup intent only:

`local input -> move command -> server validation -> server MovementComponent -> authoritative transform snapshot -> client interpolation`

Attack requests contain only a monotonic sequence, and pickup requests contain only a server-issued loot entity ID. They never contain target, damage, item, or quantity results. Enemy AI, hit detection, health/death, loot RNG, and personal unsecured-loot mutation run only on the server. The server derives identity from `multiplayer.get_remote_sender_id()` and rejects unknown/spoofed senders, stale sequences, malformed values, invalid life phases, and out-of-range pickups.

`peer_id` remains the transient ENet/RPC routing identity. Each installation keeps a persistent logical `player_id` in `user://local_player_profile.json`, with a redundant copy at `user://local_player_profile.json.bak`; the client submits that identity during handshake and the host attaches it only after format and active-duplicate validation. Profile version `1` remains the load contract. A valid primary is canonical and repairs a missing, invalid, or stale backup. A valid backup recovers a missing or corrupt primary without changing the identity. If profile files existed but neither copy is valid, the profile reports `IDENTITY_RECOVERY_REQUIRED` instead of silently generating a replacement ID; Save-based candidate selection is deferred to the next recovery phase. The validated mapping is replicated in the session snapshot. Personal progression and canonical in-session `PlayerState` ownership are keyed by `player_id`; actor ownership, movement routing, and sender validation remain keyed by active `peer_id`. This identity is not authenticated account ownership and can later be replaced by an external identity provider.

`GameSession` owns one canonical in-memory `PlayerState` per persistent `player_id`. `GameSession.players[peer_id]` is only the active attachment view and references that exact object; `GameSession.player` remains the local compatibility facade. A disconnect removes the peer runtime, actor, command caches, and active identity mapping, but the host retains the canonical state and personal progression until the multiplayer session ends. Reconnecting with the same inactive `player_id` attaches the existing state to the new peer and sends its current owner-only item and personal quest snapshots. Shared settlement, adventure, and difficulty models remain server-owned.

On clients, `PlayerState.health` is a read-only mirror of the latest validated server runtime snapshot. The snapshot does not rewrite stats, equipment, effects, inventory, or shared state. `PlayerActor` separately applies presentation: ALIVE displays mirrored health, while DEAD and RESPAWNING actors remain visually at zero health until the new life actor is spawned.

Godot's inherited `Object.is_connected(signal, callable)` reserves the requested `is_connected` name. `NetworkManager.is_session_connected()` is therefore the no-argument connection-state query on Godot 4.7.2.

## Start a host

1. Run the project normally.
2. In **Experimental Multiplayer**, select **Host**.
3. The host listens on UDP port `7777`, creates the authoritative session, and enters the shared settlement test map.

## Join a host

1. Run another game instance.
2. Enter `127.0.0.1` for a same-machine host, or the host machine's LAN IPv4 address.
3. Select **Join**. The client validates protocol version `9`, verifies that its roster entry matches its local persistent profile, receives session metadata, then enters the settlement.
4. Select **Disconnect** to leave safely.

Ending an entered multiplayer session always performs transport cleanup, resets `GameSession` to one offline local player, removes the current world, and returns the AppRoot to **Main Menu**. This applies to manual host/client leave and server disconnect. A connection failure before session synchronization remains on the existing menu without a redundant world transition.

Allow inbound UDP `7777` in the host machine firewall for LAN testing. NAT traversal, UPnP, relay services, matchmaking, Steam networking, and host migration are not included.

## Local automated probe

The optional helper launches isolated headless Godot processes with separate temporary local-profile files and enforces a timeout. It checks actual ENet host/join, two or three peer registries and actors, persistent identity continuity across a fresh reconnect, private local-personal plus shared quest snapshots, owner-only inventory/equipment snapshots, remote equip/item-use/deposit/withdraw commands, concurrent withdrawal, client-requested facility upgrade and crafting, shared storage/unlock mirrors, storage-overflow pending loot and claim, late-join settlement state, the enemy roster, movement/climbing, combat/loot, health presentation, disconnect cleanup, and host disconnect notification.

```powershell
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 3
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2 --host-disconnect
```

For a visual same-machine test, each process needs its own installation-profile identity. Launch each development instance with a different `--local-profile-path=<absolute-json-path>` user argument (after Godot's `--` separator); the automated helper configures this automatically. An override `X` derives `X.bak` and `X.tmp` without a special-case path policy. Two ordinary instances sharing the default `user://` profile are intentionally rejected as a duplicate active identity. Verify that each accepted instance reads input only for its own hamster, all actors occupy distinct spawn points, remote transforms interpolate, closing a client removes its actor on the host and remaining clients, and closing the host returns clients to the menu with a disconnect message.

## Supported now

- Host creation with `ENetMultiplayerPeer`
- Direct-IP client join and leave
- Protocol-version handshake
- Persistent local profiles with `player_` plus 128-bit lowercase hex identities, atomic temporary writes, and same-identity `.bak` redundancy
- Client-submitted, host-validated active `peer_id <-> player_id` mapping in the session snapshot
- Duplicate active persistent-identity rejection and same-profile fresh reconnect identity continuity
- Two to four peer registry and `PlayerState` creation from `GameStartDefinition`
- Server-owned player spawn/despawn in settlement and adventure scenes
- Horizontal movement, vertical climbing, and jump commands
- Server-authoritative movement simulation and transform snapshots
- Basic client interpolation
- Peer-specific life IDs, death results, and life phases
- Individual same-world respawn without ending the party adventure
- Validated health/life runtime presentation snapshots (separate from save data)
- Intent-only player attack requests with sequence replay protection
- Server-only enemy AI, combat, knockback, health, and death resolution
- Definition-driven enemy actors (`enemy_id -> EnemyDefinition.actor_scene -> EnemyAgent`) on server and clients
- Stable world-local network entity IDs for enemies and loot
- Enemy spawn/despawn plus 20 Hz interpolated transform snapshots and reliable health/state events
- Server-only Resource-driven loot rolls and replicated loot actors
- Distance/life/entity validated pickup requests with atomic double-claim protection
- Peer-specific expedition unsecured loot and isolated death loss
- `PERSONAL`, `PARTY`, and `WORLD` quest scopes (`WORLD` currently uses shared canonical storage)
- Server-only typed gameplay-event routing with killer/collector logical identity
- Private personal quest snapshots plus shared quest snapshots with stale-revision rejection
- PERSONAL rewards to the owning server `PlayerState`; PARTY/WORLD rewards to settlement storage
- Intent-only craft and facility-upgrade requests with server sender/life/phase validation and monotonic anti-replay sequences
- Atomic shared-storage craft transactions and atomic facility cost/level/unlock commits
- Reliable, revisioned settlement snapshots for storage, pending overflow loot, facility levels, and resident domain state
- Separate revisioned shared-progression snapshots for regions, exits, flags, and discovered escape points
- Read-only client settlement mirrors with malformed/stale snapshot rejection
- World-ready and fresh-join synchronization of current settlement and shared progression state
- Server-authoritative equip, unequip, consumable use, and personal inventory/shared-storage transfer commands
- One batched player item revision for inventory/protected-inventory/equipment transactions and owner-only reliable snapshots
- Stable equipment-instance command identity, monotonic anti-replay validation, and private inventory isolation
- Cross-inventory/equipment instance validation and atomic two-container transfer previews
- Offline single-player compatibility
- Save v4 with shared state plus canonical attached/detached players keyed only by persistent `player_id`
- Host-authoritative multiplayer save; clients cannot write saves and host load requires no active remote peers

`inventory_changed` remains a local-player UI compatibility signal. `quest_changed` is a compatibility notification; `quest_state_changed` carries scope and logical owner for replication. Peer-specific health/life presentation remains separate.

`SettlementState.pending_loot` is shared server-authoritative state. Its public getter always returns deep-copied ItemStacks, including on the host. A storage-full secure operation and a successful pending claim each produce exactly one settlement revision. Clients receive the mirror on late join and fresh reconnect; pending records share instance-ID validation with primary settlement storage.

Each connected player's server `PlayerState.inventory`, `protected_inventory`, and `equipment` are canonical. Clients receive only their own revisioned `PlayerItemStateSnapshot`; another peer's full private item state is never broadcast. Equip and unequip use stable instance IDs, consumable requests contain only an item ID, and storage transfers contain only direction, item identity, and amount. A same-session reconnect reuses the retained PlayerState, including health, survival, effects, all private item containers, and item revision.

Enemy kill credit requires a player-attributed server damage source. A single kill or pickup event can advance the contributing player's PERSONAL quests and the shared PARTY/WORLD quests. Ownerless environment kills grant no quest progress.

Disconnecting during an expedition explicitly forfeits that peer's current `PlayerAdventureState` and unsecured loot. Other peers' expedition loot and settlement storage are left unchanged. Joining again creates a new empty player-adventure state; same-session PlayerState reattachment does not restore the forfeited expedition participation.

Personal quest progression is not erased by a transient peer disconnect inside the host session, because it is owned by logical `player_id`, not by the connection. A reconnecting peer presenting that inactive identity receives the retained personal quest state. Save v4 persists attached and detached canonical PlayerStates and personal progression under that same identity. On clients, a disconnected remote peer's private placeholder state is discarded rather than retained as reconnect authority.

`finish_adventure()` is currently a party-wide operation: it gathers every registered player's unsecured loot into settlement storage and ends the expedition for the party. Individual escape and separate `finish_player_adventure(peer_id)` semantics are deferred rather than introducing an unused abstraction now.

Save v4 stores PARTY/WORLD quests in shared progression and PERSONAL quests under their owning `player_id`. It never stores peer IDs or runtime replication state. Offline and host saves use the same schema; clients remain read-only.

Persistent death drops store an optional stable `owner_player_id`; the runtime `owner_peer_id` is never serialized. This preserves per-player recovery ownership across a Save v4 host restart. Migrated legacy drops without an owner retain their historical shared-recovery behavior.

## 4-C.5 stable baseline

The verified baseline has no known P0 or P1 defects. Save production uses only `export_persistent_state() -> Save v4` and `migrate() -> prepare_persistent_restore() -> apply_persistent_snapshot()`. Legacy flat builders remain test/migration fixtures only. Automated Godot checks, process-restart save/load, two- and three-player ENet probes, repeated same-identity reconnect, and forced host-disconnect cleanup pass on Godot 4.7.2.

The read-only identity recovery backend can inspect deterministic candidate IDs from the primary Save v4 and can validate an explicitly selected candidate through the complete detached staging path before committing the profile. It does not auto-select or apply the staged game session, and it does not use legacy saves or the game-save `.bak` as identity sources.

Known P2/deferred work is limited to the next persistence UX phase: startup does not yet gate on recovery status or present candidate selection, saves with multiple player candidates require explicit selection UX, and process-restart client reattachment is not yet orchestrated end to end. These are not described as implemented features.

## Not synchronized yet

- Other-player equipment appearance summaries (full item state remains owner-private)
- Unsecured-loot item use
- Resident runtime movement and animation (resident persistent/domain state is mirrored)
- Party scene transitions and coordinated expedition start/return
- End-to-end process-restart reconnect UX (Save v4 restores detached records, but lobby/load orchestration is deferred)
- Host migration
- Dedicated server builds
- Internet matchmaking, relay, NAT traversal, and Steam integration
