# 전투 개편 계획과 현황 (데드셀 방향)

## 상태

이 문서는 전투 개편 **착수 전 사전 분석**으로 시작했으나, 이후 기반 작업이 진행되어
현재는 완료 사항까지 함께 기록한다.

```
완료  1차  CombatRuntimeState 로 stamina ownership 이전
완료  2차  authoritative stamina replication (Protocol v13) + runtime-mirror HUD
완료  3차  Combat Action State Machine (IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY)
예정  4차  AttackDefinition + 실제 attack timeline
```

> **주의.** 이 문서의 일부는 구현 이전에 쓰인 분석이다. 문서와 코드가 충돌하면
> **코드와 `CLAUDE.md` 의 현재 아키텍처 규칙이 우선**한다. 이 문서를 그대로 구현
> 지시로 받아들이지 않는다. 아래 4절의 단계표가 현재 유효한 실행 계획이다.

멀티플레이는 계속 유지·확장한다는 전제이며, 새 전투 시스템은 처음부터 서버 권위 경계를
지켜서 설계한다. 1절의 수치·파일·함수는 현재 코드에서 확인한 값이다.

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
| 스태미나 소비처 | 공격만 | 소유·복제 구조는 완료(3-1). 회피·대시가 쓸 소비처만 남음 |
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
- `PlayerRuntimeState.combat`(`CombatRuntimeState`) — 전투 런타임 값을 추가로 얹을 자리.
  스태미나가 이미 여기에 있고 복제 경로도 갖춰져 있다.

## 3. 먼저 결정해야 하는 구조 문제

### 3-1. 스태미나 소유와 복제 — 완료됨 (1차·2차)

과거 구조에서는 `CombatComponent`(Scene Node)가 스태미나를 소유했고, 그래서 저장되지도
복제되지도 않았다(클라이언트 HUD 가 항상 최대치를 표시하는 문제가 있었다). 현재는 해소됐다.

```
PlayerRuntimeState
 └─ CombatRuntimeState        ← 스태미나의 유일한 canonical owner
      ├─ stamina
      └─ max_stamina

CombatComponent
 └─ combat_runtime 참조만 보유 (소비·재생 로직은 계속 컴포넌트에 있음)
```

- `CombatRuntimeState` 는 transient 이며 Save v4 에 포함되지 않는다. 네트워크를 전혀 모르는
  순수 런타임 모델이고, 외부 권위 값을 받을 때는 `apply_values(stamina, max_stamina)` 를 쓴다.
- 복제는 두 경로다. 이벤트 기반 reliable `PlayerRuntimeSnapshot`(stamina/max_stamina 포함)과,
  지속 변화를 담당하는 throttled `PlayerCombatRuntimeSnapshot`(`unreliable_ordered` 채널 3,
  `COMBAT_STATE_INTERVAL = 0.1`, 값이 변했을 때만 전송, sequence 로 stale 패킷 무시).
- 클라이언트는 스태미나를 스스로 재생하지 않는다(`combat.set_process(false)` 유지, 예측 없음).
  `GameSession.apply_player_combat_runtime_snapshot()` 이 기존 `CombatRuntimeState` **객체를
  교체하지 않고 값만** 갱신한다. 교체하면 각 `CombatComponent` 의 참조가 끊어지기 때문이다.
- HUD 는 `GameSession.get_player_stamina()` / `get_player_max_stamina()` 로 runtime mirror 를
  읽고 `player_combat_runtime_changed` 로 갱신된다.

자세한 복제 계약은 `docs/multiplayer.md` 의 "Authoritative stamina replication (Protocol v13)".

### 3-2. 회피를 어디에 둘 것인가 — 결정됨

**`MovementComponent.Mode` 에 `DODGE` 를 추가하지 않는다.** (과거 분석에서는 그 방향을
제안했으나 폐기했다.) locomotion 과 combat action 을 하나의 enum 으로 합치면

```
AIR + ATTACK
GROUND + ATTACK
AIR + HURT
CLIMB + HURT
GROUND + DODGE
```

같은 조합이 곧바로 상태 폭발로 이어진다. 따라서 두 축을 독립적으로 관리한다.

```
Movement / Locomotion State        Combat Action State
  GROUND                             IDLE
  AIR                                ATTACK_STARTUP
  CLIMB                              ATTACK_ACTIVE
                                     ATTACK_RECOVERY
                                     DODGE
                                     HURT
                                     DEAD
```

`MovementComponent.Mode` 는 현재의 `GROUND / AIR / CLIMB` 를 유지한다. `ATTACK`, `DODGE`,
`HURT`, `DEAD` 는 모두 Combat Action State 축에 속한다. 3차에서 그 축(`CombatActionController`)을
도입하면서 `IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY` 네 상태만 구현했고,
`DODGE` / `HURT` / `DEAD` 는 후속 단계다.

무적 프레임은 `HealthComponent.invulnerable_remaining` 을 그대로 재사용하지 않는 편이 안전하다.
현재 이 값은 "피격 후 무적"이라 의미가 다르다. `receive_periodic_damage()` 가 접촉 무적을
무시하도록 이미 분리돼 있듯이, 회피 무적도 별도 플래그로 둔다.

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

## 4. 단계 계획 (현재 유효한 실행 순서)

각 단계는 **그 단계만으로 `check_project.py` 와 멀티플레이 E2E 가 통과하는 상태**로 끝나야
한다. 한 단계에서 한 종류의 구조적 문제만 해결한다.

| 단계 | 내용 | 상태 |
|---|---|---|
| 1차 | Combat Runtime State — `CombatRuntimeState` 로 stamina ownership 이전 | 완료 |
| 2차 | Stamina authoritative replication (Protocol v13) + runtime-mirror HUD | 완료 |
| 3차 | **Combat Action State Machine** — `IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY` 만 | 완료 |
| 4차 | `AttackDefinition` + 실제 attack timeline (데이터로 뺀 선딜/유효/후딜) | 다음 |
| 5차 | Hitbox 데이터화 + Knockback 실제 적용 | 예정 |
| 6차 | HURT (플레이어 피격 경직) | 예정 |
| 7차 이후 | Dodge/i-frame, Combo·입력 버퍼·캔슬 윈도우, 적 패턴 개편, 히트스톱·카메라 표현 | 예정 |

### 완료된 1차·2차 요약

`CombatComponent` 가 소유하던 스태미나를 `PlayerRuntimeState.combat` 으로 옮기고(1차),
이벤트 기반 reliable 스냅샷과 throttled unreliable combat 스냅샷으로 복제한 뒤 HUD 가
runtime mirror 를 읽게 했다(2차). 상세는 3-1 과 `docs/multiplayer.md` 를 본다.

### 3차 — Combat Action State Machine (완료)

`gameplay/components/combat_action_controller.gd` 의 `CombatActionController` 가 combat action
축을 소유한다. PlayerActor 의 `%CombatAction` 노드이며 `CombatComponent.action` 이 참조한다.

```
IDLE            → ATTACK_STARTUP
ATTACK_STARTUP  → ATTACK_ACTIVE | IDLE      (취소)
ATTACK_ACTIVE   → ATTACK_RECOVERY | IDLE    (취소)
ATTACK_RECOVERY → IDLE
```

- 상태 저장·전이 검증·`state_changed` 시그널만 담당한다. 데미지·스태미나·무기·히트박스·
  애니메이션·네트워크를 모른다. 실제 상태가 바뀔 때만 시그널을 발생시킨다.
- **scene-local** 이다. 공격이 월드 전환을 넘어 유지될 이유가 없으므로 새 액터는 `IDLE` 로
  시작한다. 씬을 넘어 유지돼야 하는 값(스태미나)은 계속 `CombatRuntimeState` 에 있다.
- 권위 변경은 서버 시뮬레이션에서만 일어난다. 비권위 액터는 `combat.set_process(false)` 라
  action 이 스스로 진행하지 않는다. **네트워크로 복제하지 않으며 프로토콜은 v13 그대로다.**
- **타이밍 상수를 새로 만들지 않았다.** 아직 startup/active 길이의 authoritative source 가
  없기 때문이다. 현재 공격은 여전히 즉발이고 데미지 타이밍은 3차 이전과 동일하다.
  성공한 공격은 `enter_recovery_from_immediate_attack()` 이라는 명시적 임시 edge 로
  `ATTACK_RECOVERY` 에 들어가고, 기존 `WeaponDefinition.attack_cooldown` 이 그대로 recovery
  창 역할을 한다. 쿨다운이 끝나는 프레임에 `finish_attack()` 으로 `IDLE` 에 복귀한다.
  이 edge 는 일반 전이표에 없다 — `transition_to(ATTACK_RECOVERY)` 는 `IDLE` 에서 계속 실패하며,
  4차에서 실제 타임라인이 생기면 삭제한다.
- 공격 시작 조건에 `action.is_idle()` 이 추가됐다. 쿨다운과 역할이 일부 겹치지만 둘 다
  유지한다. 쿨다운은 무기 공격 속도 규칙이고, action state 는 앞으로 타임라인과 캔슬 규칙을
  담당할 축이다. 4차 이후 역할을 점진적으로 정리한다.
- 실패한 공격(쿨다운·스태미나 부족·무기 없음·내구도 0·등반 중·귀환 채널링·strategy 실패)은
  action state 를 **전혀 바꾸지 않는다**.

### 4차 이후 메모

무기마다 선딜/후딜/히트박스 모양/콤보 단계가 달라지므로, 지금처럼 `WeaponDefinition` 에
스칼라만 두는 구조로는 부족하다. `AttackDefinition`(windup / active / recovery /
hitbox 오프셋·크기 / 캔슬 가능 구간 / 다음 콤보 id) 같은 하위 Resource 배열이 필요하다.

`AttackDefinition` 이 `WeaponDefinition` 안에 들어가는 sub-resource 라면 먼저 평범한
`extends Resource` 를 검토한다. 반드시 `ContentDefinition` 일 필요는 없다 —
`ContentDefinition` 은 ContentRegistry 에 독립적으로 등록되는 ID 기반 콘텐츠용이다.
실제 데이터 ownership 은 4차에서 재검토한다.

4차의 연결 지점은 이미 준비돼 있다. `begin_attack()` → startup 타이머 →
`enter_attack_active()` → 히트박스 arm → active 타이머 → `enter_attack_recovery()` →
recovery 타이머 → `finish_attack()` 으로 자연스럽게 이어지며, 그 시점에 위의 임시 edge 를
삭제한다.

적 공격은 아직 `EnemyAgent.perform_attack()` 이 대상 `HealthComponent.receive_damage()` 를
직접 호출한다. 히트박스 파이프라인으로 옮기는 것은 적 패턴 개편 단계의 일이다.

## 5. 개편 중 깨지기 쉬운 것

- `NetworkProtocol.VERSION`(현재 13) — 페이로드 모양이 바뀌면 반드시 올린다. 핸드셰이크에서
  거절되며 `tests/unit/test_network_input_validation.gd` 가 정확한 숫자를 검증한다.
  Combat Action state 가 네트워크 payload 에 추가되는 시점에는 payload shape 변경 여부에
  따라 protocol version 을 검토한다.
- `NetworkProtocol.valid_snapshot()` 의 `movement_mode` 상한 — `MovementComponent.Mode` 는
  `GROUND/AIR/CLIMB` 를 유지할 예정이라 당장 손댈 일은 없다. 다만 언젠가 locomotion 이
  실제로 늘어난다면 이 상한도 같이 올려야 스냅샷이 조용히 버려지지 않는다.
  (전투 상태는 Movement Mode 에 넣지 않으므로 여기에 해당하지 않는다 — 3-2 참고.)
- `PlayerRuntimeSnapshot.from_payload()` / `PlayerCombatRuntimeSnapshot.from_payload()` —
  필드 누락·타입·범위 검증이 엄격하다. 필드를 추가하면 두 validator 와
  `tests/unit/test_combat_runtime_replication.gd`, `tests/unit/test_multiplayer_lifecycle.gd` 의
  인라인 payload 를 함께 고친다.
- 클라이언트 runtime mirror 는 `CombatRuntimeState` **객체를 교체하지 않는다.** 교체하면
  `CombatComponent.combat_runtime` 참조가 조용히 끊어진다.
- `tests/integration/multiplayer_world_runtime_probe.gd` 에서 `@rpc` 어노테이션과 그 대상
  함수 사이에 다른 함수를 끼워 넣지 않는다. RPC 설정이 끊겨 타임아웃으로만 드러난다.
- `tests/unit/test_multiplayer_combat_foundation.gd`, `tests/integration/test_multiplayer_combat_loot.gd`
  — 전투 경로를 직접 검증한다. 개편하면 여기부터 깨진다.
- 전역 시그널 연결 해제 누락 → `check_project.py` 가 orphan/leak 경고로 실패.
- `ServerWorldRuntime` 경로(`server_runtime_mode`)에서 표현 노드(애니메이션·파티클·카메라)를
  만들면 headless 서버가 텍스처를 로드하게 된다. 새 전투 표현은 전부 권위 경로 바깥에 둔다.
