# Multiplayer foundation

This is an experimental 2-4 player cooperative host game foundation. It is intended for localhost and direct-IP LAN development tests, not internet play.

## Authority model

The host runs both the authoritative server and its local client. Remote clients send movement and attack/pickup intent only:

`local input -> move command -> server validation -> server MovementComponent -> authoritative transform snapshot -> client interpolation`

Attack requests contain only a monotonic sequence, and pickup requests contain only a server-issued loot entity ID. They never contain target, damage, item, or quantity results. Enemy AI, hit detection, health/death, loot RNG, and personal unsecured-loot mutation run only on the server. The server derives identity from `multiplayer.get_remote_sender_id()` and rejects unknown/spoofed senders, stale sequences, malformed values, invalid life phases, and out-of-range pickups.

`peer_id` remains the transient ENet/RPC routing identity. Each installation keeps a persistent logical `player_id` in `user://local_player_profile.json`, with a redundant copy at `user://local_player_profile.json.bak`; the client submits that identity during handshake and the host attaches it only after format and active-duplicate validation. Profile version `1` remains the load contract. A valid primary is canonical and repairs a missing, invalid, or stale backup. A valid backup recovers a missing or corrupt primary without changing the identity. If profile files existed but neither copy is valid, the profile reports `IDENTITY_RECOVERY_REQUIRED` instead of silently generating a replacement ID; the startup gate can inspect exact Save v4 identities and requires an explicit recovery choice. The validated mapping is replicated in the session snapshot. Personal progression and canonical in-session `PlayerState` ownership are keyed by `player_id`; actor ownership, movement routing, and sender validation remain keyed by active `peer_id`. This identity is not authenticated account ownership and can later be replaced by an external identity provider.

`GameSession` owns one canonical in-memory `PlayerState` per persistent `player_id`. `GameSession.players[peer_id]` is only the active attachment view and references that exact object; `GameSession.player` remains the local compatibility facade. A disconnect removes the peer runtime, actor, command caches, and active identity mapping, but the host retains the canonical state and personal progression until the multiplayer session ends. Reconnecting with the same inactive `player_id` attaches the existing state to the new peer and sends its current owner-only item and personal quest snapshots. Shared settlement, adventure, and difficulty models remain server-owned.

On clients, `PlayerState.health` is a read-only mirror of the latest validated server runtime snapshot. The snapshot does not rewrite stats, equipment, effects, inventory, or shared state. `PlayerActor` separately applies presentation: ALIVE displays mirrored health, while DEAD and RESPAWNING actors remain visually at zero health until the new life actor is spawned.

Godot's inherited `Object.is_connected(signal, callable)` reserves the requested `is_connected` name. `NetworkManager.is_session_connected()` is therefore the no-argument connection-state query on Godot 4.7.2.

## Start a host

1. Run the project normally.
2. In **Experimental Multiplayer**, select **Host** for a fresh session or **Host Save** for the primary saved session.
3. A fresh Host creates the authoritative session. Host Save first performs full detached Save staging, opens ENet with handshakes gated, applies the canonical snapshot, attaches only the local profile as peer `1`, and enables remote handshakes only after the restored session is ready.
4. The host listens on UDP port `7777` and enters the shared settlement test map.

## Join a host

1. Run another game instance.
2. Enter `127.0.0.1` for a same-machine host, or the host machine's LAN IPv4 address.
3. Select **Join**. The client validates protocol version `13`, verifies that its roster entry matches its local persistent profile, receives session metadata plus its owner-private state, then enters the settlement.
4. Select **Disconnect** to leave safely.

Ending an entered multiplayer session always performs transport cleanup, resets `GameSession` to one offline local player, removes the current world, and returns the AppRoot to **Main Menu**. This applies to manual host/client leave and server disconnect. A connection failure before session synchronization remains on the existing menu without a redundant world transition.

Allow inbound UDP `7777` in the host machine firewall for LAN testing. NAT traversal, UPnP, relay services, matchmaking, Steam networking, and host migration are not included.

## Local automated probe

The optional helper launches isolated headless Godot processes with separate temporary local-profile files and enforces a timeout. It checks actual ENet host/join, two or three peer registries and actors, persistent identity continuity across a fresh reconnect, owner-private base-stat/survival/effect/safe-position synchronization, private local-personal plus shared quest snapshots, owner-only inventory/equipment snapshots, remote equip/item-use/deposit/withdraw commands, concurrent withdrawal, client-requested facility upgrade and crafting, shared storage/unlock mirrors, storage-overflow pending loot and claim, late-join settlement state, the enemy roster, movement/climbing, combat/loot, health presentation, disconnect cleanup, and host disconnect notification.

```powershell
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 3
python tools/test_multiplayer_local.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2 --host-disconnect
```

The process-restart probe uses separate native `user://` roots for A, B, and C and reuses only the same player's directory after terminating every phase-one Godot process. It seeds a production Save v4, launches a new Host Saved Game process, reconnects newly launched client processes by persistent `player_id`, and compares canonical/private/shared state plus authoritative actor placement. It also performs a same-session reconnect after the process restart, duplicate-active-identity rejection, and final host-loss cleanup. Failure artifacts retain bounded logs and JSON phase/status diagnostics.

```powershell
python tools/test_multiplayer_restart.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2 --scenario valid
python tools/test_multiplayer_restart.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 2 --scenario invalid
python tools/test_multiplayer_restart.py --godot C:\Godot\Godot_v4.7.2-stable_win64_console.exe --players 3 --scenario valid
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
- Server-only enemy AI, hit resolution, additive `DamageContext.knockback`, health, and death resolution; movement snapshots carry the resulting transform/velocity with no knockback RPC
- Server-only Player HURT/hit-stun and attack interruption. HURT is not replicated; authoritative movement snapshots expose only its resulting motion, and server command endpoints reject attacks, quick-item use, loot pickup, gather, region entry, and Settlement return/escape while HURT
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
- Host Saved Game orchestration with pre-transport Save staging and a restoring-state handshake gate
- Protocol v13 synchronization: v12 world/revision-bound gameplay replication plus authoritative stamina

`inventory_changed` remains a local-player UI compatibility signal. `quest_changed` is a compatibility notification; `quest_state_changed` carries scope and logical owner for replication. Peer-specific health/life presentation remains separate.

`SettlementState.pending_loot` is shared server-authoritative state. Its public getter always returns deep-copied ItemStacks, including on the host. A storage-full secure operation and a successful pending claim each produce exactly one settlement revision. Clients receive the mirror on late join and fresh reconnect; pending records share instance-ID validation with primary settlement storage.

Each connected player's server `PlayerState.inventory`, `protected_inventory`, and `equipment` are canonical. Clients receive only their own revisioned `PlayerItemStateSnapshot`; another peer's full private item state is never broadcast. Equip and unequip use stable instance IDs, consumable requests contain only an item ID, and storage transfers contain only direction, item identity, and amount. A same-session reconnect reuses the retained PlayerState, including health, survival, effects, all private item containers, and item revision.

Protocol v10 introduced the separate owner-only `PlayerPrivateStateSnapshot` containing `player_id`, base stats, survival state, non-equipment active effects, and last-safe position. Protocol v11 retains that contract and additionally requires the session snapshot, private state, session/owner-bound spawn assignment, and owner world assignment to apply before `session_synchronized` opens the world. The server derives each private target from the accepted sender mapping and sends the payload only with `rpc_id(owner_peer_id)`; clients cannot request an arbitrary identity. The client validates the complete payload against its profile and attached local `player_id`, stages all replacement models, then atomically replaces those private domains. The destination scene consumes the cached spawn assignment while it is created, before the local actor acknowledges revision-bound world readiness. Inventory/equipment and PERSONAL quests retain their existing owner-only revisioned services, health/life retains its runtime snapshot, and shared domains remain outside this DTO. Reapplying a snapshot replaces effects and derived modifiers instead of accumulating them.

Spawn ownership is server-side. The accepted persistent `player_id`, not a current or historical `peer_id`, determines whether an attachment is returning. A returning player in Settlement first offers its server-maintained `last_safe_position`; the active Settlement scene checks finiteness, configured bounds, collision clearance, and walkable support. World-invalid coordinates fall back deterministically through configured `PlayerSpawnPoint` markers and the successful fallback heals `last_safe_position`. A genuinely new player ignores that field and receives the first available validated marker; configured marker slots are runtime-only and are never saved. Adventure scenes retain entry-slot spawning and never overwrite the Settlement-safe position.

The attach transaction records whether the canonical PlayerState existed before mutation. If private/spawn preparation fails, returning state is detached and retained, while a just-created fresh state is detached and removed. In both cases active identity maps, world-ready state, and spawn caches are cleared. Disconnect is idempotent and retains only server canonical state; transport reset clears session/private/spawn receive gates plus all runtime spawn decisions. A client-supplied position is never accepted.

Handshake rejection sends its reliable reason before a short delayed disconnect. The quarantine cache is scoped to the current transport generation, and the delayed callback captures both `peer_id` and that generation. Resetting or replacing the transport advances the generation and clears quarantine, so an old timer cannot disconnect or mutate a later connection even if ENet reuses the same numeric peer ID. A peer that disconnects before its timer fires is removed from quarantine and makes the callback a no-op.

Enemy kill credit requires a player-attributed server damage source. A single kill or pickup event can advance the contributing player's PERSONAL quests and the shared PARTY/WORLD quests. Ownerless environment kills grant no quest progress.

Disconnecting during an expedition explicitly forfeits that peer's current `PlayerAdventureState` and unsecured loot. Other peers' expedition loot and settlement storage are left unchanged. Joining again creates a new empty player-adventure state; same-session PlayerState reattachment does not restore the forfeited expedition participation.

Personal quest progression is not erased by a transient peer disconnect inside the host session, because it is owned by logical `player_id`, not by the connection. A reconnecting peer presenting that inactive identity receives the retained personal quest state. Save v4 persists attached and detached canonical PlayerStates and personal progression under that same identity. On clients, a disconnected remote peer's private placeholder state is discarded rather than retained as reconnect authority.

`finish_adventure()` remains the offline compatibility operation. Multiplayer exits use `finish_player_adventure(peer_id)`: only that participant's unsecured loot is secured and only that `PlayerWorldState` returns to Settlement. Other players sharing the Adventure world keep their participation and loot.

Save v4 stores PARTY/WORLD quests in shared progression and PERSONAL quests under their owning `player_id`. It never stores peer IDs or runtime replication state. Offline and host saves use the same schema; clients remain read-only.

Persistent death drops store an optional stable `owner_player_id`; the runtime `owner_peer_id` is never serialized. This preserves per-player recovery ownership across a Save v4 host restart. Migrated legacy drops without an owner retain their historical shared-recovery behavior.

## 4-C.5 stable baseline

The verified baseline has no known P0 or P1 defects. Save production uses only `export_persistent_state() -> Save v4` and `migrate() -> prepare_persistent_restore() -> apply_persistent_snapshot()`. Legacy flat builders remain test/migration fixtures only. Automated Godot checks, process-restart save/load, two- and three-player ENet probes, repeated same-identity reconnect, and forced host-disconnect cleanup pass on Godot 4.7.2.

The startup `AppRoot` identity gate treats valid, newly created, and backup-recovered profiles as ready. An unrecoverable profile opens a modal identity dialog backed by deterministic candidates from the primary Save v4. A single candidate is preselected but never auto-committed; multiple candidates require an explicit selection and confirmation. Cancel keeps New Game, Load, Host, and Join disabled and exposes a menu action that reopens recovery. The explicit Create New Player path has a separate warning confirmation because it does not attach existing Save player records.

The backend validates the selected candidate through the complete detached staging path before requesting identity commit through `NetworkManager`. `LocalPlayerProfile` remains the profile-file persistence implementation but is not exposed as a mutable general service. Recovery does not apply the staged Save session or use legacy saves or the game-save `.bak` as identity sources. After profile persistence succeeds, `AppRoot` explicitly activates one fresh offline `GameSession` local identity and verifies that it matches the profile before enabling session actions. Activation failure can be retried without recommitting the profile.

Host Saved Game is distinct from offline Load followed by Host. `SaveManager.prepare_load()` migrates and fully stages without live mutation, `NetworkManager.begin_host_restore()` opens only gated transport, `GameSession.apply_persistent_snapshot()` restores all canonical records with only the host attached, and `NetworkManager.finalize_host_restore()` builds the peer-1 roster, opens the handshake gate, then emits the session-ready `hosting_started` signal. A peer that submits its handshake before readiness is explicitly disconnected with `Server is restoring session` and may reconnect after the host is ready; it never receives a partial attachment. Saved remote players remain detached under persistent `player_id` until their identity reconnects; no old peer ID or fake attachment is restored. Invalid staging opens no server, bind failure applies no snapshot, and post-open failure closes transport before restoring one offline local identity.

`HOSTING_RESTORING` distinguishes transport ownership from gameplay authority. In that state ENet is open and `is_server()` is true for server-side transport/RPC validation, while `is_session_connected()`, `is_host_session_ready()`, and `is_authoritative_simulation()` are false. Consequently New Game, gameplay commands, play-time/effect ticks, and other authoritative simulation remain blocked even after the detached snapshot has been installed. Only successful `finalize_host_restore()` enters `HOSTING`, marks the session entered, opens handshakes, and enables gameplay authority. Offline single-player remains locally authoritative.

The 4-D process-restart lifecycle is covered by independent 2-player and 3-player OS-process probes. They verify profile primary/backup reuse, production Host Saved Game staging, detached canonical restoration, same-object reattachment, owner-private and revisioned item/quest synchronization, returning/fallback actor placement before readiness, B/C privacy isolation, symmetric runtime mappings, duplicate-active-identity rejection, repeated reconnect, and host-loss cache cleanup. Save v4 and Profile v1 remain unchanged. Deferred work is product infrastructure such as authenticated account identity, cloud saves, NAT traversal, dedicated servers, host migration, and active-Adventure persistence.

## Independent world participation and runtime (introduced in Protocol v12)

`GameSession.phase` remains an offline and compatibility facade, but multiplayer location authority is `player_id -> PlayerWorldState`. A stable state identifies `settlement` or `adventure:<region_id>` and carries an incrementing revision. `peer_id` is used only to attach the active transport peer to that canonical state. Fresh joins and reconnects begin in Settlement; disconnecting from Adventure forfeits unsecured loot and resets the detached world state to Settlement without deleting the canonical `PlayerState`.

Clients request a region or Settlement return; the host derives the sender identity, validates life/current world/content entry/pending state, commits one player's world state, and sends only that owner a `PlayerWorldAssignment`. The assignment contains no scene path. `SceneRouter` resolves the authoritative region through `ContentRegistry`, rejects wrong session/player/stale revisions, and changes only the local process presentation. After the destination `PlayerSpawnManager` consumes its authoritative spawn and world-filtered roster, the client acknowledges `(world_id, revision)`. Commands remain blocked while that acknowledgement is pending.

Each `PlayerSpawnManager` declares its world identity and creates actors only for peers whose canonical assignment matches it. Destination roster delivery is hosted by the stable `NetworkManager` autoload rather than scene-relative RPC paths, so Settlement and Sewer clients can have different scene trees. A leaving actor is removed from the old roster, while same-world peers are added deterministically.

Protocol v12 completes the independent runtime boundary. `ServerWorldRoot` is persistent beside the host's presentation `WorldLayer`; each occupied world owns one `ServerWorldRuntime` under a rendering-disabled `SubViewport` with its own `World2D`. The host can therefore present Settlement while `adventure:sewer_region` continues authoritative player physics, enemy AI, combat, loot, gather state, and its world-local clock; conversely, the host may present Sewer while a remote client continues independently in Settlement. The first participant creates the runtime, additional participants reuse it, and the last participant leaving removes it. Re-entry creates one fresh runtime; empty-field persistence remains intentionally unsupported.

Authoritative actors and presentation mirrors are distinct roles of the existing actor scenes. Runtime actors simulate and presentation actors consume snapshots. Stable `NetworkManager` RPC brokers carry `world_id` and the receiving peer's current world revision for player transform/runtime/attack presentation, enemy spawn/state/despawn, loot spawn/despawn, respawn, and gather consumption. Recipients are selected from ready peers in the same world, and a client rejects packets whose world or revision no longer matches its local assignment. Owner-private item, equipment, quest, and v10 private-state snapshots remain owner-only and are not world filtered; shared settlement/progression mirrors retain their prior global contract.

Enemy and loot managers own an explicit world ID. Entity registration is scoped by `(world_id, entity_id)`, so equal numeric IDs in different worlds do not alias. Combat uses actors in the isolated physics world; enemy targeting additionally requires an authoritative player actor in the same world root. Loot and gather requests derive the sender's current world on the server, validate the world, living runtime, authoritative Player HURT, distance, and availability, and broadcast results only to ready peers in that world. Settlement craft, facility, and storage-transfer commands retain server-side Settlement readiness checks.

Adventure sessions are indexed by Adventure world and tick independently of the host camera. An individual return removes only that player's authoritative and presentation actor; the shared runtime and the other participants' adventure/loot state remain. Adventure disconnect retains canonical `PlayerState`, forfeits unsecured participation, removes runtime mappings, and resets the reconnect assignment to Settlement.

Run the independent process checks with:

```text
python tools/test_multiplayer_worlds.py --godot <godot> --players 2
python tools/test_multiplayer_worlds.py --godot <godot> --players 3
python tools/test_multiplayer_world_runtime.py --godot <godot> --players 2
python tools/test_multiplayer_world_runtime.py --godot <godot> --players 3
```

## Authoritative stamina replication (introduced in Protocol v13, current)

`CombatRuntimeState`(`PlayerRuntimeState.combat`)가 스태미나의 유일한 권위 소유자다. 이
모델은 네트워크를 전혀 모르며, 복제는 두 경로로 나뉜다.

- **신뢰 경로 (이벤트 기반).** 기존 `PlayerRuntimeSnapshot` 에 `stamina` 와 `max_stamina`
  를 추가했다. world-ready, life 변경, 부활, 체력 변경처럼 이미 존재하던 이벤트에서만
  전송되며, 스태미나 때문에 이 reliable RPC 의 빈도를 올리지 않는다. payload 검증은
  `0 <= stamina <= max_stamina`, `max_stamina >= 0`, 유한값을 요구하고 위반 시 스냅샷
  전체를 거절한다.
- **지속 경로 (throttled).** 재생으로 계속 변하는 값은 `PlayerCombatRuntimeSnapshot`
  (`peer_id`, `stamina`, `max_stamina`, `sequence`)이 전담한다.
  `NetworkPlayerComponent.combat_snapshot_tick()` 이
  `COMBAT_STATE_INTERVAL = 0.1`(10 Hz) 주기로만 확인하고, 마지막으로 보낸 값과
  `is_equal_approx` 로 같으면 아예 전송하지 않는다. 따라서 최대치에서 대기 중인
  플레이어는 패킷을 만들지 않는다. 전송은 `unreliable_ordered` 채널 3
  (`_receive_player_combat_runtime`)이며, 다른 월드 페이로드와 같이
  `(world_id, revision)` 과 `replication_ready_remote_peer_ids(world_id)` 를 따른다.

클라이언트는 `GameSession.apply_player_combat_runtime_snapshot()` 으로 기존
`CombatRuntimeState` 객체의 값만 갱신한다. 객체를 교체하면 각 `CombatComponent` 가 들고
있는 참조가 끊어지기 때문이다. 수신 측은 `sequence` 가 마지막으로 적용한 값보다 클 때만
적용하므로 늦게 도착한 패킷이 최신 값을 덮어쓰지 않는다. 신뢰 스냅샷이 스태미나를 교정하면
서버는 다음 throttle tick 을 강제로 한 번 보내, 다른 채널에 떠 있던 오래된 값이 부활/최대치
교정을 되돌리지 못하게 한다.

호스트는 왕복이 필요 없다. 로컬 플레이어는 권위 `CombatRuntimeState` 를 직접 읽으므로
combat 스냅샷을 자기 자신에게 emit 하지 않는다. 클라이언트의 `CombatComponent` 는 계속
`set_process(false)` 이며 스태미나를 스스로 재생하지 않는다(예측 없음). HUD 는
`GameSession.get_player_stamina()` / `get_player_max_stamina()` 로 런타임 미러를 읽고,
`player_combat_runtime_changed` 시그널로 갱신된다. 스태미나는 여전히 transient 이며
Save v4 에 포함되지 않는다.

## Authoritative Player HURT (Stage 6, Protocol remains v13)

Player HURT는 권위 `PlayerActor` 안의 scene-local combat action이다. 서버의 accepted damage가
`DamageContext.causes_hurt=true`이고 non-lethal일 때만 `PlayerHurtComponent`가 attack pending
state/hitbox를 정리하고 0.25초 timer/control lock을 시작한다. knockback은 이 판단과 독립적으로
권위 velocity에 먼저 더해진다. periodic/starvation은 `causes_hurt=false`라 attack이나 입력을
중단하지 않는다.

HURT state와 remaining time은 복제하지 않는다. 새 RPC, snapshot field, payload 변경이 없어서
`NetworkProtocol.VERSION = 13`을 유지한다. 원격 presentation actor는 기존 20 Hz transform/
velocity snapshot만 받아 서버 knockback 이동을 보간한다. world-runtime process E2E는 실제
`EnemyAgent.perform_attack()`으로 서버 플레이어를 피격시키고, 서버와 원격 client presentation
모두 같은 +x 방향으로 이동하는지 tolerance를 두고 확인한다.

클라이언트는 HURT를 모르므로 공격 intent를 계속 보낼 수 있지만 서버 `CombatComponent.attack()`이
HURT action에서 거절하고 sequence는 기존 정책대로 소비한다. 같은 우회를 막기 위해 consumable
use, loot pickup, gather의 서버 명령 종착점도 송신자가 아닌 권위 PlayerActor의 HURT를 검사한다.
HURT animation/event, client prediction, CombatAction replication은 후속 범위다.

`InteractionTarget.activated`는 client presentation에서 실행될 수 있으므로 authority boundary가
아니다. enter-region과 return/escape는 최종 `NetworkManager` mutation 함수에서 공통
`_validate_authoritative_world_interaction()`을 호출한다. 이 helper는 peer/player/runtime/world-ready,
ALIVE 상태와 현재 world의 authoritative PlayerActor identity, death, HURT를 검사한다. 따라서
remote client가 HURT를 전혀 몰라도 서버가 transition 전에 요청을 거절하고 world/revision,
Adventure participation, pending transition, spawn assignment를 바꾸지 않는다. HURT 종료 뒤에는
같은 요청이 정상 처리된다. quest dialog/crafting/facility 제한은 필요할 때 명령별 정책으로
추가하며 이번 보강은 interaction system 전체를 재설계하지 않는다.

## Not synchronized yet

- Other-player equipment appearance summaries (full item state remains owner-private)
- Unsecured-loot item use
- Resident runtime movement and animation (resident persistent/domain state is mirrored)
- Party scene transitions and coordinated expedition start/return
- Host migration
- Dedicated server builds
- Internet matchmaking, relay, NAT traversal, and Steam integration
