# 전투 개편 사전 분석 (데드셀 방향)

다음 작업 대상은 "데드셀식 전투 개편"이고, 멀티플레이는 계속 유지·확장한다는 전제다.
이 문서는 **구현 계획이 아니라 착수 전 실측 자료**다. 수치·파일·함수는 현재 코드에서 확인한 값이다.

## 1. 지금 전투가 실제로 도는 경로

```
[로컬] Input.primary_attack(J)
  → PlayerInputComponent.attack_requested                       (player_input_component.gd:43)
  → NetworkCombatComponent._on_attack_requested()               (network_combat_component.gd:26)
     ├ 싱글: 바로 _server_execute_attack()
     └ 멀티 클라이언트: NetworkManager.submit_player_attack(peer_id, seq)
  → [호스트] _request_player_attack (RPC, any_peer/reliable)
  → NetworkManager → player_attack_command_received
  → NetworkCombatComponent._server_execute_attack()
     1. PlayerAttackCommand.is_valid_after(_last_server_sequence)  중복/역행 거절
     2. sequence 를 먼저 소비 (스팸 재생 방지)
     3. life_phase == ALIVE, phase ∈ {SETTLEMENT, ADVENTURE} 확인
     4. ServerCombatService.try_player_attack(actor)
        → CombatComponent.attack(facing)                        (combat_component.gd:27)
           - cooldown_remaining > 0 이면 거절
           - CLIMB 중이거나 귀환 채널링 중이면 거절
           - MAIN_HAND 장비 → WeaponDefinition, durability == 0 이면 거절
           - stamina < weapon.stamina_cost 이면 거절
           - damage = weapon.base_damage + stats.attack_power
           - DamageContext(knockback = (120*facing, -40)) 생성
           - strategies[attack_mode].execute(...)
             · MELEE: hitbox.configure_range(range, facing) + hitbox.arm(context, 0.12초)
             · PROJECTILE: attack_scene 인스턴스 생성 후 launch()
           - stamina -= cost, cooldown_remaining = weapon.attack_cooldown
     5. actor.cancel_return_channel_for_combat()
     6. NetworkManager.broadcast_player_attack(peer_id, seq, facing)  → 클라이언트는 표현만
  → HitboxComponent 가 0.12초 동안 겹친 Hurtbox 에 receive_hit()
  → HurtboxComponent: source_faction ≠ faction, target_factions 검사
  → HealthComponent.receive_damage(): max(1, amount - defense), 접촉 무적 0.35초
  → damaged/died 시그널 → EnemyAgent 는 hurt/dead 상태로 전이
```

적 공격은 `EnemyAgent.perform_attack()` 이 대상의 `HealthComponent.receive_damage()` 를
**직접** 호출한다(히트박스를 쓰지 않는다). 선딜은 `attack_state.gd` 의 `0.7 → 0.5` 하드코딩.

### 현재 고정 수치 (전부 하드코딩 또는 기본값)

| 값 | 위치 | 값 |
|---|---|---|
| 히트박스 지속 | `combat_component.gd` 호출 인자 | 0.12초 |
| 히트박스 높이 | `hitbox_component.configure_range()` | 30px 고정 |
| 접촉 무적 | `health_component.gd` | 0.35초 |
| 넉백 벡터 | `combat_component.gd` | `(120*facing, -40)` — **속도에 적용되지 않음** |
| 적 경직 | `hurt_state.gd` | 0.25초 + `-last_hit_direction * 90` |
| 적 공격 사이클 | `attack_state.gd` | 0.7초, 0.2초 뒤 판정 |
| 중력/점프/가속 | `movement_component.gd` | 1100 / -390 / 1300 / 1700 |
| 기본 스탯 | `stat_block.gd` | hp100, speed190, atk5, def0, stamina100, regen18 |
| 스냅샷 | `network_player_component.gd` | 20Hz, 보간 14.0, 텔레포트 500px |

## 2. 데드셀식으로 가려면 없는 것

| 요소 | 현재 | 비고 |
|---|---|---|
| 회피/구르기 | 없음 | 입력 액션도 없음. 무적 프레임 개념 없음 |
| 스태미나 소비처 | 공격만 | 회피·대시·차징에 쓰려면 소유 위치부터 옮겨야 함(3절) |
| 콤보 | 없음 | 공격은 단발. `sequence` 는 네트워크용 일련번호일 뿐 콤보 인덱스가 아님 |
| 공격 모션/선후딜 | 없음 | 히트박스가 즉시 켜짐. windup/active/recovery 구분 없음 |
| 넉백 적용 | 벡터만 존재 | `DamageContext.knockback` 이 velocity 에 반영되지 않음 |
| 피격 경직(플레이어) | 없음 | 적만 hurt 상태가 있음 |
| 방향 공격(위/아래) | 없음 | 히트박스가 항상 수평 |
| 무기별 패턴 | 2종(근접/투사체) | `AttackStrategy` 확장점은 이미 있음 |
| 방패/패링 | 없음 | |
| 적 예고 텔레그래프 | 없음 | 색/애니메이션 자산 자체가 없음 |
| 보스·엘리트 | 없음 | 적 1종 |
| 히트스톱·카메라 흔들림 | 없음 | 표현 계층 전무 |
| 애니메이션 | 없음 | `Polygon2D` 플레이스홀더. `attack_presented` 시그널만 이미 준비됨 |

이미 **깔려 있는** 확장점:
- `CombatComponent.strategies: Dictionary[int, AttackStrategy]` — 공격 방식 추가 지점.
- `PlayerActor.attack_presented(sequence, facing)` — 클라이언트 표현 훅(이미 복제됨).
- `EffectRuntimeModel` / `EffectDefinition` — 상태이상·버프를 데이터로 넣을 수 있음.
- `EnemyState` 상태 노드 — 적 패턴 추가는 노드 추가 + `change_state` 만으로 가능.
- `MovementComponent.Mode` — 회피 상태를 여기에 추가하는 게 자연스러움.

## 3. 먼저 결정해야 하는 구조 문제

### 3-1. 스태미나의 소유자를 옮겨야 한다 (선행 작업)

현재 스태미나는 `CombatComponent.stamina`(Scene Node)가 소유한다. 이건 `CLAUDE.md` 의
"Scene Node 가 지속 상태를 소유하지 않는다" 규칙과 어긋나고, 실제로 깨져 있다:

- **저장되지 않는다.** 씬을 이동하면 100으로 리셋된다.
- **복제되지 않는다.** 클라이언트는 권위 액터가 아니라 `CombatComponent._process` 가
  꺼져 있어, HUD 가 읽는 `bound_player.combat.stamina`(`ui/game_hud.gd:143`)는 항상 100이다.
  즉 클라이언트 화면의 스태미나 표시는 지금도 거짓이다.
- 회피·대시가 스태미나를 쓰게 되는 순간 이 불일치가 곧바로 조작감 문제가 된다.

→ `PlayerState`(또는 `SurvivalState` 옆의 전용 런타임 모델)로 옮기고,
`PlayerRuntimeSnapshot` 에 실어 복제하는 것이 선행 작업이다. `player_runtime_snapshot.gd`
의 `to_payload`/`from_payload` 는 필드 검증이 엄격하므로 양쪽을 같이 고쳐야 한다.

### 3-2. 회피를 어디에 둘 것인가

- 상태는 `MovementComponent.Mode` 에 `DODGE` 추가가 가장 자연스럽다(중력·입력 처리를
  이미 소유하고 있고, `mode` 는 이미 스냅샷으로 복제된다 — `NetworkProtocol.valid_snapshot()`
  의 상한이 `Mode.CLIMB` 이라 **enum 확장 시 이 검증도 같이 고쳐야 한다**).
- 무적 프레임은 `HealthComponent.invulnerable_remaining` 을 재사용할 수 있으나, 현재
  이건 "피격 후 무적"이라 의미가 다르다. `receive_periodic_damage()` 가 무적을 무시하도록
  이미 분리돼 있듯이, 회피 무적도 별도 플래그로 두는 편이 안전하다.

### 3-3. 네트워크 모델: 지금은 예측이 없다

클라이언트는 입력을 보내고 20Hz 스냅샷을 보간만 한다. 예측/재조정이 없으므로 현재도
**클라이언트 입력에는 RTT 만큼의 지연**이 있다. 데드셀식 회피는 이 지연에 민감하다.
선택지는 셋이고, 착수 전에 골라야 한다.

| 방향 | 내용 | 비용 |
|---|---|---|
| A. 표현만 선행 | 입력 즉시 회피 **애니메이션/이펙트**만 로컬 재생, 실제 이동·무적은 호스트 결과로 확정 | 낮음. 기존 `attack_presented` 와 같은 패턴 |
| B. 로컬 예측 + 재조정 | 클라이언트가 이동을 예측하고 스냅샷과 어긋나면 보정 | 큼. 입력 버퍼·재시뮬레이션 필요, 현재 구조에 없음 |
| C. 호스트 지연 보상 | 히트 판정 시 공격자 시점의 과거 위치로 되감기 | 큼. 위치 히스토리 필요 |

권장 순서는 A 로 개편을 먼저 완성하고, 체감이 부족하면 그때 B 를 별도 작업으로 분리하는 것.
어느 쪽이든 **적 AI 와 히트 판정은 호스트에만 남긴다**는 원칙은 바뀌지 않는다.

### 3-4. 데이터로 뺄 것과 코드에 남길 것

무기마다 선딜/후딜/히트박스 모양/콤보 단계가 달라지므로, 지금처럼 `WeaponDefinition` 에
스칼라만 두는 구조로는 부족하다. `AttackPhaseDefinition`(windup / active / recovery /
hitbox 오프셋·크기 / 캔슬 가능 구간 / 다음 콤보 id) 같은 하위 Resource 배열이 필요하다.
새 Resource 는 `data/definitions/` 에 `ContentDefinition` 으로 넣고
`validate_definition()` 을 반드시 구현한다(`CLAUDE.md` 4절).

## 4. 단계별 착수안

각 단계는 **그 단계만으로 `check_project.py` 가 통과하는 상태**로 끝나야 한다.

**0단계 — 기준선 고정 (선행)**
현재 상태는 green 이다: `ALL PROJECT CHECKS PASS`, 테스트 785 assertions,
2인 world-runtime E2E 통과. 개편 전에 이 숫자를 기록해 두고, 매 단계 비교한다.

**1단계 — 스태미나 상태 이전**
`CombatComponent.stamina` → 세션 상태로. 스냅샷 복제 + HUD 수정 + 저장 필드 추가.
touch: `core/models/session/player_state.gd`, `core/models/network/player_runtime_snapshot.gd`,
`gameplay/components/combat_component.gd`, `gameplay/actors/player/player.gd`,
`ui/game_hud.gd`, `core/serialization/session_snapshot.gd`, `docs/save_format.md`.
test: `tests/unit/` 에 스태미나 소비·회복·복원·스냅샷 왕복 테스트 추가.

**2단계 — 공격 페이즈화**
`AttackPhaseDefinition` 도입, `CombatComponent.attack()` 을 즉발에서 windup/active/recovery
타임라인으로 교체. 히트박스 지속·크기·오프셋을 데이터에서 읽는다. 넉백을 실제 velocity 에
적용하고 플레이어 피격 경직을 추가한다.
touch: `data/definitions/weapon_definition.gd`(+새 정의), `gameplay/components/combat_component.gd`,
`hitbox_component.gd`, `health_component.gd`, `movement_component.gd`, 기존 무기 `.tres` 2종.

**3단계 — 회피/구르기**
`project.godot` 에 `dodge` 입력 액션 추가, `MovementComponent.Mode.DODGE`,
`NetworkProtocol.valid_snapshot()` 상한 갱신, 회피 전용 무적, 스태미나 소비,
클라이언트는 3-3 의 A 방식으로 표현 선행.
touch: `project.godot`, `movement_component.gd`, `player_input_component.gd`,
`network_combat_component.gd`(또는 새 intent RPC), `core/network/network_protocol.gd`,
`docs/controls.md`, `docs/multiplayer.md`.

**4단계 — 콤보**
콤보 인덱스와 캔슬 윈도우. 호스트가 콤보 상태를 소유하고, 클라이언트에는
`attack_presented` 에 콤보 단계를 실어 보낸다(payload 확장 → 프로토콜 버전 상향).

**5단계 — 적 패턴**
`EnemyState` 에 텔레그래프/돌진/원거리 상태 추가, `EnemyDefinition` 에 패턴 데이터.
적 공격을 `perform_attack()` 직접 호출에서 히트박스 기반으로 전환(플레이어와 같은 파이프라인).

**6단계 — 표현**
히트스톱, 카메라 흔들림, 피격 플래시. 아트가 없으므로 여기서 스프라이트/애니메이션
파이프라인 작업과 만난다(별도 작업으로 분리 권장).

## 5. 개편 중 깨지기 쉬운 것

- `NetworkProtocol.valid_snapshot()` 의 `movement_mode` 상한 — Mode enum 을 늘리면 여기도.
- `NetworkProtocol.VERSION` — 페이로드 모양이 바뀌면 반드시 올린다. 핸드셰이크에서 거절된다.
- `PlayerRuntimeSnapshot.from_payload()` — 필드 누락·범위 검증이 엄격하다. 필드 추가 시
  구버전 payload 를 받는 테스트가 있는지 확인.
- `tests/unit/test_multiplayer_combat_foundation.gd`, `tests/integration/test_multiplayer_combat_loot.gd`
  — 전투 경로를 직접 검증한다. 개편하면 여기부터 깨진다.
- 전역 시그널 연결 해제 누락 → `check_project.py` 가 orphan/leak 경고로 실패.
- `ServerWorldRuntime` 경로(`server_runtime_mode`)에서 표현 노드(애니메이션·파티클·카메라)를
  만들면 headless 서버가 텍스처를 로드하게 된다. 새 전투 표현은 전부 권위 경로 바깥에 둔다.
