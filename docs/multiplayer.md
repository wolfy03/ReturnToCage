# Multiplayer foundation

This is an experimental 2-4 player cooperative host game foundation. It is intended for localhost and direct-IP LAN development tests, not internet play.

## Authority model

The host runs both the authoritative server and its local client. Remote clients send movement and attack/pickup intent only:

`local input -> move command -> server validation -> server MovementComponent -> authoritative transform snapshot -> client interpolation`

Attack requests contain only a monotonic sequence, and pickup requests contain only a server-issued loot entity ID. They never contain target, damage, item, or quantity results. Enemy AI, hit detection, health/death, loot RNG, and personal unsecured-loot mutation run only on the server. The server derives identity from `multiplayer.get_remote_sender_id()` and rejects unknown/spoofed senders, stale sequences, malformed values, invalid life phases, and out-of-range pickups.

`GameSession.players` is the canonical peer-to-`PlayerState` collection. `GameSession.player` remains a compatibility view of the local peer's exact same object. Shared settlement, progression, adventure, and difficulty models remain server-owned conceptually; this phase only transmits session metadata, protocol version, and the player list rather than reusing save dictionaries.

On clients, `PlayerState.health` is a read-only mirror of the latest validated server runtime snapshot. The snapshot does not rewrite stats, equipment, effects, inventory, or shared state. `PlayerActor` separately applies presentation: ALIVE displays mirrored health, while DEAD and RESPAWNING actors remain visually at zero health until the new life actor is spawned.

Godot's inherited `Object.is_connected(signal, callable)` reserves the requested `is_connected` name. `NetworkManager.is_session_connected()` is therefore the no-argument connection-state query on Godot 4.7.2.

## Start a host

1. Run the project normally.
2. In **Experimental Multiplayer**, select **Host**.
3. The host listens on UDP port `7777`, creates the authoritative session, and enters the shared settlement test map.

## Join a host

1. Run another game instance.
2. Enter `127.0.0.1` for a same-machine host, or the host machine's LAN IPv4 address.
3. Select **Join**. The client validates protocol version `3`, receives session metadata/player roster, then enters the settlement.
4. Select **Disconnect** to leave safely.

Ending an entered multiplayer session always performs transport cleanup, resets `GameSession` to one offline local player, removes the current world, and returns the AppRoot to **Main Menu**. This applies to manual host/client leave and server disconnect. A connection failure before session synchronization remains on the existing menu without a redundant world transition.

Allow inbound UDP `7777` in the host machine firewall for LAN testing. NAT traversal, UPnP, relay services, matchmaking, Steam networking, and host migration are not included.

## Local automated probe

The optional helper launches isolated headless Godot processes and enforces a timeout. It checks actual ENet host/join, two or three peer registries and actors, the late-join enemy roster, A/D movement, jump, W/S climbing, authoritative transform and health presentation snapshots on clients, client disconnect cleanup, a fresh reconnect, and host disconnect notification. Unit/in-process integration coverage separately exercises attack validation, server hit detection, enemy damage/death, loot spawn, exact-once pickup, and personal loot ownership.

```powershell
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 3
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2 --host-disconnect
```

For a visual manual test, start two to four normal instances. Verify that each instance reads input only for its own hamster, all actors occupy distinct spawn points, remote transforms interpolate, closing a client removes its actor on the host and remaining clients, and closing the host returns clients to the menu with a disconnect message.

## Supported now

- Host creation with `ENetMultiplayerPeer`
- Direct-IP client join and leave
- Protocol-version handshake
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
- Stable world-local network entity IDs for enemies and loot
- Enemy spawn/despawn plus 20 Hz interpolated transform snapshots and reliable health/state events
- Server-only Resource-driven loot rolls and replicated loot actors
- Distance/life/entity validated pickup requests with atomic double-claim protection
- Peer-specific expedition unsecured loot and isolated death loss
- Offline single-player compatibility
- Multiplayer save and load disabled for both host and clients

`inventory_changed` remains a local-player UI compatibility signal. `storage_changed`, `facility_changed`, and `quest_changed` describe shared server-owned session state. Peer-specific presentation uses `player_health_changed` and `player_life_changed`.

Enemy kills currently retain the existing party-shared quest-event behavior. This is an explicit temporary compatibility policy; multiplayer quest ownership is not defined in this phase.

## Not synchronized yet

- Inventory and equipment replication
- Quest state
- Settlement storage, facilities, residents, and progression
- Crafting
- Party scene transitions and coordinated expedition start/return
- Persistent multiplayer saves
- Reconnect and host migration
- Dedicated server builds
- Internet matchmaking, relay, NAT traversal, and Steam integration
