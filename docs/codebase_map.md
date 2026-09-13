# 코드베이스 지도

실제 코드를 읽고 정리한 구조 지도다. 설계 의도는 `architecture.md` /
`session_architecture.md` / `multiplayer.md` 를, 작업 규칙은 루트 `CLAUDE.md` 를 본다.

## 1. 큰 그림

```
core/boot.tscn (main scene)
├─ AppRoot(core/app_root.gd)        메뉴·신원 게이트·호스팅/조인 진입점
├─ ServerWorldRoot                  호스트 전용. 점유된 월드마다 ServerWorldRuntime 1개
├─ NetworkServices/                 Quest/Settlement/PlayerItem 복제 서비스(월드 무관)
├─ WorldLayer                       SceneRouter 가 교체하는 "보이는" 월드 1개
├─ UILayer/GameHUD                  코드로 생성되는 HUD
├─ MultiplayerPanel, DebugPanel, IdentityRecoveryDialog
└─ MainMenu
```

autoload 5개 (`project.godot`):
`ContentRegistry` → `NetworkManager` → `GameSession` → `SaveManager` → `SceneRouter`.

로컬 클라이언트가 **보는** 월드(WorldLayer)와 호스트가 **시뮬레이션하는** 월드
(ServerWorldRoot 아래의 SubViewport)는 별개다. 호스트 본인의 화면도 권위 시뮬레이션의
소유자가 아니다.

## 2. 디렉터리별 책임

| 경로 | 책임 |
|---|---|
| `autoload/` | 5개 전역. `game_session.gd`(60KB)와 `network_manager.gd`(68KB)가 사실상 두 축 |
| `core/models/` | 런타임 RefCounted 모델(인벤토리·장비·효과·스탯) |
| `core/models/session/` | 5개 State (Player/Settlement/Progression/Adventure/Difficulty) + `PlayerWorldState`, `WorldRuntime` |
| `core/models/network/` | 네트워크 명령·스냅샷 DTO. 전부 `to_payload()`/`from_payload()` + 검증 |
| `core/services/` | 규칙 판정 순수 로직(사망/출구/선행조건/제작/전투/스폰/아이템 명령) |
| `core/serialization/` | Save v4 봉투, `SessionSnapshot` 독립 검증·복원 |
| `core/profile/` | `user://` 로컬 신원 프로필(player_id, 표시 이름, 복구) |
| `core/validation/` | 콘텐츠 검증 진입 씬 |
| `data/definitions/` | `ContentDefinition` 상속 Resource 스크립트 |
| `data/content/` | 실제 `.tres` 콘텐츠. **여기 있는 것만** ContentRegistry 가 로드 |
| `gameplay/actors/` | Player, Enemy(+상태 노드), Loot 액터 씬·스크립트 |
| `gameplay/components/` | 액터에 붙는 컴포넌트(이동·전투·체력·생존·상호작용·효과·네트워크) |
| `world/` | 월드 씬(정착지/모험지), 스폰·복제 매니저, 서버 런타임, 배경 표현 |
| `ui/`, `devtools/` | HUD·멀티플레이 패널·신원 복구 창·디버그 패널 (전부 코드 생성 UI) |
| `tests/`, `tools/` | 인프로세스 테스트 러너 + 실제 프로세스 분리 E2E 파이썬 하네스 |

## 3. 세션 상태

`GameSession` 은 5개 State 의 facade다. 자체 소유: `session_id`, `play_time_seconds`,
`last_message`, `phase`, 그리고 플레이어 레지스트리.

| State | 소유 |
|---|---|
| `PlayerState` | `stats`(StatBlock), `inventory`, `protected_inventory`, `equipment`, `survival`, `health`, `last_safe_position`, `effects` |
| `SettlementState` | `storage`, `facility_levels`, `resident_states`, `pending_loot` |
| `ProgressionState` | 공유 퀘스트 + 플레이어별 `PersonalProgressionState`, 해금, 발견한 탈출 지점 |
| `AdventureState` | `active_session`, `death_drops` |
| `DifficultyState` | 프리셋 id + override, 원정 시작 시 `AdventureRulesSnapshot` 으로 확정 |

플레이어 레지스트리는 3층이다. 이걸 헷갈리면 멀티플레이가 조용히 깨진다.

- `_player_states_by_id[player_id]` — **영속 canonical** PlayerState. 접속 여부와 무관.
- `players[peer_id]` / `_attached_player_ids[peer_id]` — 현재 연결된 peer 의 **부착**.
- `_player_world_states[player_id]` — 현재 어느 월드에 있는지(`settlement` 또는
  `adventure:<region_id>`) + `revision`.

`attach_player` 는 같은 객체를 연결만, `detach_player` 는 해제만, 실제 삭제는
`remove_player_state` 만 한다.

`GameSession` 시그널 (UI/시스템이 구독하는 지점):
`session_reset`, `inventory_changed`, `storage_changed`, `facility_changed`,
`resident_changed`, `settlement_state_changed`, `shared_progression_changed`,
`quest_changed`, `quest_state_changed`, `player_item_state_changed`,
`adventure_started`, `adventure_finished`, `difficulty_changed`, `phase_changed`,
`player_died`, `player_respawned`, `player_health_changed`, `player_life_changed`,
`player_registered`, `player_unregistered`, `player_world_changed`.

Phase: `MENU → SETTLEMENT → ADVENTURE → SETTLEMENT`, 사망 시 `RESPAWNING` 경유.
멀티플레이에서 phase 와 `adventure.active_session` 은 **오프라인/구 UI 호환 facade**일 뿐,
플레이어 위치의 source of truth 는 `PlayerWorldState` 다.

## 4. 멀티플레이 축

`NetworkManager` (ENet, 기본 포트 7777, 최대 4인, `NetworkProtocol.VERSION = 12`).

RPC 는 전부 `NetworkManager` 안에만 있고, 다른 노드는 시그널로 받는다. 이 구조를 깨지 말 것.

- 클라이언트 → 호스트 (`any_peer`): `_request_player_move_input`(unreliable_ordered ch0),
  `_request_player_attack`, `_request_world_loot_pickup`, `_request_world_gather`,
  `_request_enter_region`, `_request_return_to_settlement`, `_request_world_roster`,
  `_confirm_world_ready`, `_request_handshake`.
- 호스트 → 클라이언트 (`authority`): `_receive_player_transform`(unreliable_ordered ch1),
  `_receive_player_runtime`, `_receive_player_attack`, `_receive_player_respawn`,
  `_receive_enemy_spawn/_transform(ch2)/_runtime/_despawn`,
  `_receive_loot_spawn/_despawn/_pickup_result`, `_receive_gather_consumed`,
  `_receive_world_roster_player/_remove/_complete`, `_receive_world_transition_failure`,
  `_receive_session_snapshot`, `_receive_private_player_state`,
  `_receive_spawn_assignment`, `_receive_world_assignment`, `_client_add_peer/_remove_peer`,
  `_reject_handshake`.

월드 스코핑: `ServerWorldRoot.reconcile()` 이 `GameSession.get_peer_world()` 집합에서
필요한 월드를 뽑아 `ServerWorldRuntime` 을 만들고 없어지면 지운다. 각 런타임은
`SubViewport`(`world_2d = World2D.new()`, `render_target_update_mode = DISABLED`)에
월드 씬을 넣고 `configure_server_runtime(world_id, region_id)` 를 호출한다.

이동 복제: 클라이언트가 매 `_process` 에 `PlayerMoveCommand` 를 보내고, 호스트는
`input.apply_move_command()` 로 서버 측 입력에 주입한다. 호스트는 **20 Hz**
(`NetworkPlayerComponent.SNAPSHOT_INTERVAL`)로 위치·속도·facing·movement mode 를
브로드캐스트한다. 클라이언트는 `INTERPOLATION_SPEED = 14.0` 지수 보간,
`TELEPORT_DISTANCE = 500` 초과 시 순간이동. **클라이언트 예측·재조정(reconciliation)은 없다.**

## 5. 액터와 컴포넌트

`PlayerActor`(CharacterBody2D) 자식:
`%Input` `%Movement` `%Network` `%NetworkCombat` `%Health` `%Survival` `%Effects`
`%Combat` `Hitbox` `Hurtbox` `%Interaction` `Camera2D`.

권위가 아닌(= 원격 표현용) 액터는 `_ready()` 에서 Health/Survival/Combat/Effects 의
`_process` 를 끄고 Hurtbox 의 monitoring/monitorable 을 내린다. Camera2D 는 로컬
플레이어만 켜진다.

`EnemyAgent`(CharacterBody2D)는 `%States` 아래 Idle/Patrol/Chase/Attack/Hurt/Dead 노드를
`EnemyState` 로 모아 `change_state(&"...")` 로 돌린다. 각 state 는
`physics_tick(delta) -> StringName` 으로 다음 상태 id 를 반환한다(빈 문자열이면 유지).

컴포넌트 요약:

- `PlayerInputComponent` — `_process` 로 축, `_unhandled_input` 으로 액션 시그널.
  `local_input_enabled`(로컬 플레이어만), `gameplay_actions_enabled`(권위일 때만 직접 실행),
  `network_intents_enabled`(클라이언트가 의도만 보낼 때).
- `MovementComponent` — `GROUND/AIR/CLIMB`. 중력·가감속·점프·등반 정렬을 전부 소유.
  `speed` 는 `move_speed` 스탯을 따라간다.
- `HealthComponent` — `receive_damage(DamageContext)`, 접촉 무적 `invulnerability_seconds`
  (기본 0.35), `receive_periodic_damage()` 는 무적을 무시한다.
- `CombatComponent` — 쿨다운, **스태미나**, 무기별 전략 dispatch.
- `HitboxComponent`(Area2D) / `HurtboxComponent`(Area2D) — 팩션·target_factions 검사 후
  `hit_effects` 적용.
- `EffectController` — `PlayerState.effects` 모델의 어댑터. 시간은 모델이 소유.
- `SurvivalComponent` — 허기/갈증. `GameSession.player.survival` 과 같은 객체를 공유.

## 6. 콘텐츠

`ContentRegistry` 가 `res://data/content` 를 재귀 스캔해 `.tres` 를 로드하고 id 중복·
타입·빈 id 를 검사한 뒤 모든 정의의 `validate_definition(registry)` 를 돌린다.
현재 **29개** 리소스가 통과한다.

정의 종류: item / equipment / weapon / effect / enemy / loot_table / recipe / facility(+level) /
quest(+objective) / region / settlement_exit / climbable / difficulty / respawn_policy /
survival_config / game_start(+starting_item, starting_resident).

현재 콘텐츠 규모(= 사실상 프로토타입):
아이템 9, 적 1(`sewer_beetle`), 지역 1(`sewer_region`), 출구 2(하나는 잠김),
시설 1(`workbench`), 퀘스트 1, 레시피 2, 효과 3, 난이도 3.

## 7. 저장

Save v4. `shared` + `players[player_id]` 구조. `peer_id` 와 네트워크/런타임 revision 은
저장하지 않는다. 로드는 마이그레이션(v1→v2→v3→v4) → `prepare_persistent_restore()` →
`SessionSnapshot` 독립 검증 → `apply_persistent_snapshot()` 으로 State 를 통째 교체한다.
치명적 오류면 현재 세션을 건드리지 않는다. 진행 중 원정은 재개하지 않는다.

## 8. 검증 인프라

- `tests/test_runner.tscn` → `test_runner.gd` 가 자체 테스트 + `tests/unit/*`,
  `tests/integration/*` 를 `preload().new().run(self)` 로 순차 dispatch. 성공 시
  `TEST PASS: <n> assertions` 출력. 현재 기준선 **785 assertions**.
- `tools/check_project.py` — 엔진 버전 핀 확인 → editor import → 콘텐츠 검증 →
  테스트 러너 → restart-write/read → 60프레임 부팅. 각 단계 120초 제한, 경고도 실패.
- `tools/test_multiplayer_*.py` — 실제 ENet + 분리된 OS 프로세스. restart(재접속/세이브),
  worlds(개별 월드 라우팅), world_runtime(서버 런타임·전투·전리품·채집).
- `.github/workflows/godot.yml` — push 시 같은 검사를 리눅스 Godot 4.7.2 로 실행.

## 9. 현재 비어 있는 영역 (다음 작업 후보)

| 영역 | 현황 |
|---|---|
| 아트 | 배경 텍스처만 존재. 캐릭터·적·시설·아이템 전부 Polygon2D 플레이스홀더. 애니메이션 0 |
| 레벨 | TileMap 없음. 지형을 `WorldHelpers` 로 코드 생성. 지역 1개 |
| 전투 | 회피/구르기·스태미나 UI·콤보·경직·넉백 적용·방향 공격·보스 없음 (자세히는 `combat_rework_prep.md`) |
| 주민 | `ResidentAgent` 는 랜덤 왕복 3상태. `ResidentDefinition` 레지스트리 없음, 직업·대사·생활 행동 없음 |
| 정착지 발전 | 시설 레벨 데이터는 있으나 외형/기능 변화는 색·크기뿐. 장식·배치 시스템 없음 |
| 성장 | 레벨/경험치/스킬 트리 없음. 성장은 장비·시설 해금뿐 |
| 낮/밤 | `EnvironmentPresenter.set_time_normalized()` 훅만 있고 no-op. 달 레이어 비활성 |
| 오디오 | 없음 |
| 제작 | 즉시 거래만. `craft_seconds` 대기열 미구현 |
