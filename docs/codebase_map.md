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

`PlayerState`(영속, Save v4 대상)와 `PlayerRuntimeState`(transient, 저장하지 않음)는
서로 다른 것이다. 런타임 쪽은 다음을 소유한다.

```
PlayerRuntimeState            (peer 단위, transient)
├─ life_id
├─ life_phase
├─ death_result
└─ combat: CombatRuntimeState
     ├─ stamina               ← 스태미나의 유일한 canonical owner
     └─ max_stamina
```

`CombatComponent` 는 이 객체를 참조만 한다. 클라이언트에서는 이 runtime state 가 서버
값을 담는 **runtime mirror** 이며 클라이언트가 스스로 값을 굴리지 않는다. 스태미나는
Save v4 에 포함되지 않는다.

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
`player_registered`, `player_unregistered`, `player_world_changed`,
`player_combat_runtime_changed`.

Phase: `MENU → SETTLEMENT → ADVENTURE → SETTLEMENT`, 사망 시 `RESPAWNING` 경유.
멀티플레이에서 phase 와 `adventure.active_session` 은 **오프라인/구 UI 호환 facade**일 뿐,
플레이어 위치의 source of truth 는 `PlayerWorldState` 다.

## 4. 멀티플레이 축

`NetworkManager` (ENet, 기본 포트 7777, 최대 4인, `NetworkProtocol.VERSION = 13`).

프로토콜 이력: v11 이 월드 배정, v12 가 월드/revision 에 묶인 게임플레이 복제(이동·적·전리품·
전투 표현·필드 상호작용)를 도입했고, **v13 이 authoritative 스태미나 복제**를 추가했다.
v13 의 내용은 `PlayerRuntimeSnapshot` 에 `stamina`/`max_stamina` 포함, 지속 스태미나용
`PlayerCombatRuntimeSnapshot` 신설, `unreliable_ordered` 채널 3 이다.

RPC 는 전부 `NetworkManager` 안에만 있고, 다른 노드는 시그널로 받는다. 이 구조를 깨지 말 것.

`InteractionTarget.activated`는 로컬 presentation 흐름이며 authority boundary가 아니다. 특히
remote actor에는 HURT도 DODGE도 복제되지 않는다(dodge는 facing mirror + 표현만 받는다). `_begin_player_world_transition()`과
`_return_player_to_settlement()`은 공통 `_validate_authoritative_world_interaction()`으로
현재 peer/world의 authoritative actor, ALIVE/death/HURT/DODGE 상태를 spawn/world mutation
전에 재검증한다. attack/item/loot/gather도 각각의 기존 서버 경계에서 HURT와 DODGE를 거절한다.

- 클라이언트 → 호스트 (`any_peer`): `_request_player_move_input`(unreliable_ordered ch0),
  `_request_player_attack`, `_request_world_loot_pickup`, `_request_world_gather`,
  `_request_enter_region`, `_request_return_to_settlement`, `_request_world_roster`,
  `_confirm_world_ready`, `_request_handshake`.
- 호스트 → 클라이언트 (`authority`): `_receive_player_transform`(unreliable_ordered ch1),
  `_receive_player_runtime`, `_receive_player_attack`, `_receive_player_respawn`,
  `_receive_enemy_spawn/_transform(ch2)/_runtime/_despawn`,
  `_receive_loot_spawn/_despawn/_pickup_result`, `_receive_gather_consumed`,
  `_receive_player_combat_runtime`(unreliable_ordered ch3),
  `_receive_world_roster_player/_remove/_complete`, `_receive_world_transition_failure`,
  `_receive_session_snapshot`, `_receive_private_player_state`,
  `_receive_spawn_assignment`, `_receive_world_assignment`, `_client_add_peer/_remove_peer`,
  `_reject_handshake`.

복제 경로별 성격:

| 경로 | 빈도 | 신뢰성 | 계기 |
|---|---|---|---|
| Player Transform | 20 Hz | `unreliable_ordered` ch1 | 권위 tick |
| Combat Runtime (`PlayerCombatRuntimeSnapshot`) | 최대 10 Hz, 값이 변했을 때만 | `unreliable_ordered` ch3 | 권위 tick |
| Player Runtime Full (`PlayerRuntimeSnapshot`) | 이벤트 | `reliable` | world-ready / life / respawn / health |
| Enemy Transform | 권위 tick | `unreliable_ordered` ch2 | 권위 tick |

지속적으로 변하는 combat state 를 reliable RPC 로 매 tick 보내지 않는다는 것이 이 표의 요점이다.

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
`%Input` `%Movement` `%Network` `%NetworkCombat` `%NetworkDodge` `%Health` `%Survival`
`%Effects` `%CombatAction` `%Hurt` `%Dodge` `%Combat` `Hitbox` `Hurtbox` `%Interaction`
`Camera2D`.

두 상태 축은 분리돼 있다.

```
PlayerActor
├─ MovementComponent      locomotion : GROUND / AIR / CLIMB
├─ CombatActionController combat action : IDLE / ATTACK_STARTUP /
│                                         ATTACK_ACTIVE / ATTACK_RECOVERY /
│                                         HURT / DODGE
├─ CombatComponent        pending attack · phase timer · 전략 실행 · 스태미나 commit
│    └─ CombatRuntimeState 참조 (stamina / max_stamina)
├─ PlayerHurtComponent    HURT timer · 공격/dodge interruption · control lock(hurt)
└─ PlayerDodgeComponent   DODGE timer · i-frame gate · control lock(dodge)
     └─ DodgeDefinition (res://data/combat/player_dodge.tres, ContentDefinition 아님)
          ├─ duration_seconds
          ├─ iframe_start_seconds / iframe_end_seconds  ← half-open 무적 구간
          ├─ speed                                      ← 롤 수평 속도
          └─ stamina_cost                               ← 시작 시 1회 commit, 환불 없음

WeaponDefinition
└─ AttackDefinition (embedded sub-resource, ContentDefinition 아님)
     ├─ startup_seconds
     ├─ active_seconds     ← 멜리 히트박스가 열려 있는 시간
     ├─ recovery_seconds
     ├─ range              ← 논리적 reach / projectile 이동 거리
     ├─ hitbox_size        ← 현재 rectangle 크기
     ├─ hitbox_offset      ← 공격자 local offset
     └─ knockback          ← 공격자 forward-local impulse
```

공격 한 번의 흐름:

```
attack(facing)  →  검증 + context/weapon 스냅샷  →  ATTACK_STARTUP (startup_seconds)
  →  ATTACK_ACTIVE 진입 = commit (전략 실행 · 히트박스 활성 · 스태미나 차감 · attacked)
  →  active_seconds  →  히트박스 비활성 + ATTACK_RECOVERY (recovery_seconds)  →  IDLE
```

phase 시간은 `CombatComponent` 만 소유한다. 히트박스 상태는 다음과 같다.

| action state | 멜리 히트박스 |
|---|---|
| IDLE | inactive |
| ATTACK_STARTUP | inactive |
| ATTACK_ACTIVE | **active** |
| ATTACK_RECOVERY | inactive |
| HURT | inactive |
| DODGE | inactive |
| `abort_attack()` / 사망 | inactive (즉시) |

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
  `speed` 는 `move_speed` 스탯을 따라간다. input gate 는 **소유자별**이다:
  `set_control_lock(source, locked)` 와 `CONTROL_LOCK_HURT` / `CONTROL_LOCK_DODGE` 를 쓰고
  `controls_locked` 는 "lock 이 하나라도 있는가" 를 읽는 계산 속성이다. 각 소유자는 자기
  lock 만 해제한다.
- `HealthComponent` — `receive_damage(DamageContext)`, 접촉 무적 `invulnerability_seconds`
  (기본 0.35), `receive_periodic_damage()` 는 무적을 무시한다. 여기에 더해 타이머 없는
  `evasion_invulnerable` gate 가 있고 `PlayerDodgeComponent` 만 열고 닫는다. 이 gate 는
  `DamageContext.can_be_evaded` 가 true 인 피해만 막으며 접촉 무적/god mode 와 별개다.
- `CombatActionController` — combat action 축(`IDLE / ATTACK_STARTUP / ATTACK_ACTIVE /
  ATTACK_RECOVERY / HURT / DODGE`). `DODGE` 는 `IDLE` 에서만 들어가고 `IDLE`/`HURT` 로만
  나간다(공격을 롤로 캔슬하거나 hit-stun 을 롤로 탈출할 수 없다). 상태 저장·전이 검증·시그널만 담당하며 timing·데미지·스태미나·무기·히트박스·
  네트워크를 모른다. scene-local 이라 월드 전환 시 새 액터는 `IDLE` 로 시작한다.
  locomotion(`MovementComponent.Mode`)과 **독립된 축**이다.
- `CombatComponent` — 공격 요청 검증, **attack timeline 진행**(pending attack + phase timer),
  `ATTACK_ACTIVE` 진입 시 전략 실행과 스태미나 commit, 스태미나 재생 로직.
  스태미나 값 자체는 소유하지 않고 `combat_runtime`(`CombatRuntimeState`) 참조를 통해 읽고
  쓴다. 공격 시작 시 `AttackDefinition.knockback`의 x만 facing으로 해석해 `DamageContext`에
  snapshot한다. 비권위 액터에서는 `_process` 가 꺼져 있어 재생을 돌리지 않는다.
- `HitboxComponent`(Area2D) / `HurtboxComponent`(Area2D) — 팩션·target_factions 검사 후
  `hit_effects` 적용. Hitbox 는 **duration 을 모른다**: `activate()`/`deactivate()` 로만
  켜지고 꺼지고 공격 geometry 기본값도 갖지 않는다. Melee strategy가 ACTIVE commit 전에
  `AttackDefinition.hitbox_size/hitbox_offset`으로 rectangle을 구성한다. 활성화 순간 실제
  CollisionShape2D와 같은 shape/transform으로 direct space query를 실행하며, 256 결과 상한은
  방어적 기술 한계일 뿐 gameplay target 수가 아니다. 중복 타격은 `_hit_targets`가 막는다.
- `PlayerHurtComponent` — scene-local HURT timing owner. 유효한 직접 피해가 들어오면 공격의
  pending data/hitbox를 정리한 뒤 현재 attack phase에서 HURT로 직접 전환한다. 0.25초 동안
  `CONTROL_LOCK_HURT` lock을 유지하고 재피격은 signal 없이 timer만 refresh한다. 종료는 반드시
  `HURT → IDLE`이며 death/reset과 새 world actor에는 상태가 남지 않는다. 진행 중인 dodge가
  있으면 `DODGE → HURT` 전이 직전에 `interrupt_for_hurt()`로 i-frame과 dodge lock만 내리고
  velocity는 건드리지 않는다(넉백 impulse는 이미 적용돼 있다).
- `PlayerDodgeComponent` — scene-local DODGE timing owner. `DodgeDefinition` 없이는 모든
  dodge를 거절한다. `IDLE`이면서 `movement.mode == GROUND` **그리고** `is_on_floor()`일 때만
  시작하고(stale mode만으로는 부족하다), 시작 시 스태미나를 **정확히 한 번** 지불한 뒤 절대
  환불하지 않는다. 매 tick 수평 velocity만 쓰고 위치는 쓰지 않으므로 벽은 `move_and_slide`가
  막고 낭떠러지는 평범한 `AIR` 낙하가 된다(새 locomotion mode 없음). i-frame 구간은
  definition의 half-open 창이 유일한 소유자이며 `HealthComponent`의 `evasion_invulnerable`을
  열고 닫는다. 방향은 `dodge_requested(horizontal_direction)`가 실어 보낸 입력 시점 의도가
  우선이고, 없을 때만 `facing`으로 fallback한다. 정상 종료(`_finish()`)만 자기가 쓴
  `velocity.x`를 0으로 되돌리며, 공용 cleanup은 velocity를 건드리지 않는다. 진행 중인 return
  channel은 dodge를 막지 않고, 커밋이 확정된 뒤 이 컴포넌트가 한 번만 취소한다.
- 피해 성공 후 `HealthComponent.damaged(context)`를 받은 권위 Player/Enemy가
  `context.knockback`을 기존 velocity에 더한다. Player는 non-zero impulse일 때 CLIMB을 먼저
  이탈한다. 이 물리 impulse와 `DamageContext.causes_hurt`의 hit reaction은 독립이다. HURT 중
  입력 가속·점프·climb 조작·공격·상호작용·quick item은 막되 gravity/collision/기존 velocity는
  계속 처리한다. periodic/starvation은 HP만 줄이고 HURT를 만들지 않는다.
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
  `TEST PASS: <n> assertions` 출력. assertion 총계는 테스트가 늘 때마다 바뀌므로 문서에
  고정 숫자를 적지 않는다. 판단 기준은 전체 suite 와 멀티플레이 E2E 의 통과 여부다.
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
| 전투 | 스태미나(소유·복제·HUD), 공격 타임라인/geometry, 권위 넉백, Player HURT·hit-stun·attack interruption, 서버 권위 Dodge + i-frame 까지 완료. 콤보·입력 버퍼·보스는 없다 (단계별 계획은 `combat_rework_prep.md`) |
| 주민 | `ResidentAgent` 는 랜덤 왕복 3상태. `ResidentDefinition` 레지스트리 없음, 직업·대사·생활 행동 없음 |
| 정착지 발전 | 시설 레벨 데이터는 있으나 외형/기능 변화는 색·크기뿐. 장식·배치 시스템 없음 |
| 성장 | 레벨/경험치/스킬 트리 없음. 성장은 장비·시설 해금뿐 |
| 낮/밤 | `EnvironmentPresenter.set_time_normalized()` 훅만 있고 no-op. 달 레이어 비활성 |
| 오디오 | 없음 |
| 제작 | 즉시 거래만. `craft_seconds` 대기열 미구현 |
