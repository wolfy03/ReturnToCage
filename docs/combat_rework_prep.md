# 전투 개편 계획과 현황 (데드셀 방향)

## 상태

이 문서는 전투 개편 **착수 전 사전 분석**으로 시작했으나, 이후 기반 작업이 진행되어
현재는 완료 사항까지 함께 기록한다.

```
완료  1차  CombatRuntimeState 로 stamina ownership 이전
완료  2차  authoritative stamina replication (Protocol v13) + runtime-mirror HUD
완료  3차  Combat Action State Machine (IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY)
완료  4차  AttackDefinition + 실제 attack timeline
완료  4차 안정화  ACTIVE window 단일 소유 + immediate sweep
완료  5차  AttackDefinition geometry/range + Knockback 실제 적용
완료  6차  Player HURT / Hit-Stun
다음  7차  Dodge + i-frame
```

> **주의.** 이 문서의 일부는 구현 이전에 쓰인 분석이다. 문서와 코드가 충돌하면
> **코드와 `CLAUDE.md` 의 현재 아키텍처 규칙이 우선**한다. 이 문서를 그대로 구현
> 지시로 받아들이지 않는다. 아래 4절의 단계표가 현재 유효한 실행 계획이다.

멀티플레이는 계속 유지·확장한다는 전제이며, 새 전투 시스템은 처음부터 서버 권위 경계를
지켜서 설계한다. 1절의 수치·파일·함수는 현재 코드에서 확인한 값이다.

## 1. 지금 전투가 실제로 도는 경로

```
[로컬] Input.primary_attack(J)
  → PlayerInputComponent.attack_requested
  → NetworkCombatComponent._on_attack_requested()
     ├ 싱글: 바로 _server_execute_attack()
     └ 멀티 클라이언트: NetworkManager.submit_player_attack(peer_id, seq)
  → [호스트] _request_player_attack (RPC, any_peer/reliable)
  → NetworkCombatComponent._server_execute_attack()
     sequence 중복/역행 거절 → life/phase 확인 → ServerCombatService.try_player_attack()
  → CombatComponent.attack(facing)              ← 여기서는 "요청 수락 + 선딜 시작"만
     action.is_idle() / CLIMB / 귀환 채널링 / 무기 / durability /
     attack_definition 유효성 / 스태미나 / 전략 존재 확인
     → damage·context·weapon 스냅샷 저장
     → action.begin_attack()  =  ATTACK_STARTUP, phase = startup_seconds
  → NetworkManager.broadcast_player_attack(...)  ← 클라이언트는 공격 "시작" 표현만

[호스트 tick] CombatComponent._process(delta) → _advance_attack()
  ATTACK_STARTUP 종료
     → 스태미나 재확인 → action.enter_attack_active()
     → strategy.execute()   ← geometry 구성 후 히트박스 activate 또는 투사체 생성
     → spend_stamina() → attacked            **공격은 여기서만 commit 된다**
  ATTACK_ACTIVE 종료  → action.enter_attack_recovery()
  ATTACK_RECOVERY 종료 → action.finish_attack() → IDLE, pending clear
```

phase 길이는 전부 `WeaponDefinition.attack_definition`(`AttackDefinition`)에서 읽는다.
코드에 하드코딩된 타이밍 상수는 없고, 별도의 무기 쿨다운도 없다. 한 프레임 delta 가
phase 보다 길면 잉여분을 다음 phase 로 넘겨 timeline 이 늘어지지 않게 한다.

적 공격은 아직 `EnemyAgent.perform_attack()` 이 대상 `HealthComponent.receive_damage()` 를
직접 호출한다(플레이어 timeline 과 통합되지 않음).

## 2. 데드셀식으로 가려면 없는 것

| 요소 | 현재 | 비고 |
|---|---|---|
| 회피/구르기 | 없음 | 입력 액션도 없음. 무적 프레임 개념 없음 |
| 스태미나 소비처 | 공격만 | 소유·복제·commit 시점 확정. 회피·대시가 쓸 소비처만 남음 |
| 콤보 | 없음 | 공격은 단발. `sequence` 는 네트워크용 일련번호일 뿐 콤보 인덱스가 아님 |
| 공격 모션/선후딜 | **완료(4차)** | `AttackDefinition` 의 startup/active/recovery. 판정은 ACTIVE 진입 시 |
| 넉백 적용 | **완료(5차)** | 권위 Player/Enemy가 `DamageContext.knockback`을 velocity에 additive 적용 |
| 피격 경직(플레이어) | **완료(6차)** | scene-local HURT action + 0.25초 input lock |
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
`HURT`, `DEAD` 는 모두 Combat Action State 축에 속한다. 현재
`IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY / HURT`를 구현했다.
`DODGE`와 `DEAD` action은 후속 단계다.

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

현재 단발 공격의 timing/range/rectangle geometry/knockback은 embedded plain Resource인
`AttackDefinition`에 모였다. 향후 실제 무기가 multiple hitbox, shape type, 콤보 단계나 cancel
window를 요구할 때 배열/하위 phase Resource를 별도 설계한다. 그때도 독립 콘텐츠 id가 필요하지
않다면 `ContentDefinition`으로 올리지 않고 weapon sub-resource 경계를 유지한다.

## 4. 단계 계획 (현재 유효한 실행 순서)

각 단계는 **그 단계만으로 `check_project.py` 와 멀티플레이 E2E 가 통과하는 상태**로 끝나야
한다. 한 단계에서 한 종류의 구조적 문제만 해결한다.

| 단계 | 내용 | 상태 |
|---|---|---|
| 1차 | Combat Runtime State — `CombatRuntimeState` 로 stamina ownership 이전 | 완료 |
| 2차 | Stamina authoritative replication (Protocol v13) + runtime-mirror HUD | 완료 |
| 3차 | **Combat Action State Machine** — `IDLE / ATTACK_STARTUP / ATTACK_ACTIVE / ATTACK_RECOVERY` 만 | 완료 |
| 4차 | `AttackDefinition` + 실제 attack timeline (데이터로 뺀 선딜/유효/후딜) | 완료 |
| 4차 안정화 | ACTIVE window 단일 소유 + immediate sweep | 완료 |
| 5차 | AttackDefinition rectangle geometry/range + Knockback 실제 적용 | 완료 |
| 6차 | HURT (플레이어 피격 경직·공격 interruption·control lock) | 완료 |
| 7차 | Dodge + i-frame | **다음** |
| 이후 | Combo·입력 버퍼·캔슬 윈도우, 적 패턴 개편, 히트스톱·카메라 표현 | 예정 |

### 완료된 1차·2차 요약

`CombatComponent` 가 소유하던 스태미나를 `PlayerRuntimeState.combat` 으로 옮기고(1차),
이벤트 기반 reliable 스냅샷과 throttled unreliable combat 스냅샷으로 복제한 뒤 HUD 가
runtime mirror 를 읽게 했다(2차). 상세는 3-1 과 `docs/multiplayer.md` 를 본다.

### 3차 — Combat Action State Machine (완료)

`gameplay/components/combat_action_controller.gd` 의 `CombatActionController` 가 combat action
축을 소유한다. PlayerActor 의 `%CombatAction` 노드이며 `CombatComponent.action` 이 참조한다.

```
IDLE            → ATTACK_STARTUP
IDLE            → HURT
ATTACK_STARTUP  → ATTACK_ACTIVE | IDLE | HURT
ATTACK_ACTIVE   → ATTACK_RECOVERY | IDLE | HURT
ATTACK_RECOVERY → IDLE | HURT
HURT            → IDLE
```

- 상태 저장·전이 검증·`state_changed` 시그널만 담당한다. 데미지·스태미나·무기·히트박스·
  애니메이션·네트워크를 모른다. 실제 상태가 바뀔 때만 시그널을 발생시킨다.
- **scene-local** 이다. 공격이 월드 전환을 넘어 유지될 이유가 없으므로 새 액터는 `IDLE` 로
  시작한다. 씬을 넘어 유지돼야 하는 값(스태미나)은 계속 `CombatRuntimeState` 에 있다.
- 권위 변경은 서버 시뮬레이션에서만 일어난다. 비권위 액터는 `combat.set_process(false)` 라
  action 이 스스로 진행하지 않는다. **네트워크로 복제하지 않으며 프로토콜은 v13 그대로다.**
- 3차 당시에는 타이밍의 authoritative source 가 없어 공격이 여전히 즉발이었고, 성공한 공격이
  임시 edge 로 곧장 `ATTACK_RECOVERY` 에 들어가 기존 무기 쿨다운을 recovery 창으로 썼다.
  **4차에서 그 임시 edge 와 쿨다운은 모두 제거됐다**(아래 4차 절 참고). 과거 구조이며 현재
  코드에는 남아 있지 않다.
- 공격 시작 조건에 `action.is_idle()` 이 추가됐고, 4차 이후로는 이것이 재공격 가능 여부의
  **유일한** 기준이다.
- 실패한 공격(스태미나 부족·무기 없음·내구도 0·등반 중·귀환 채널링·strategy 실패)은
  action state 를 **전혀 바꾸지 않는다**.

### 4차 — AttackDefinition + attack timeline (완료)

`data/definitions/attack_definition.gd` 의 `AttackDefinition` 은 **평범한 `Resource`** 이며
`ContentDefinition` 이 아니다. 독립 id 로 ContentRegistry 에 등록되는 콘텐츠가 아니라
`WeaponDefinition.attack_definition` 에 박히는 sub-resource 다.

- timing은 `startup_seconds` / `active_seconds` / `recovery_seconds`이며 전부 유한 양수다.
  5차부터 `range`(양수 finite), `hitbox_size`(각 성분 양수 finite), `hitbox_offset`(각 성분
  finite), `knockback`(각 성분 finite)도 같은 Resource가 소유한다. knockback은 zero와 음수
  x/y를 허용한다. `validation_errors(owner_id)` 결과는 `WeaponDefinition.validate_definition()`에
  합쳐지며 `attack_definition`이 null인 무기도 실패한다.
- `twig_sword` 는 `0.10 / 0.12 / 0.33` 으로 이관했다. 합 0.55초로 **기존 공격 cadence 를
  유지**하되 판정은 입력 직후가 아니라 0.10초 뒤에 발생한다. `active_seconds = 0.12` 는
  기존 히트박스 활성 시간을 그대로 옮긴 값이며, 이제 이 값이 유일한 source 다
  (`HitboxComponent` 의 `arm()` 과 기본값 인자, 자체 카운트다운은 모두 제거했다).
- **phase 시간의 소유자는 `CombatComponent` 하나다.** `HitboxComponent` 는 자체 duration
  타이머를 갖지 않고 `activate()` / `deactivate()` 만 노출한다. 멜리 히트박스는 ACTIVE 동안만
  활성이며 ACTIVE 를 벗어나는 즉시 꺼진다. 활성화 순간 direct space query 로 이미 겹쳐 있는
  대상을 한 번 훑기 때문에, 한 프레임이 ACTIVE 구간을 통째로 삼켜도 commit 된 공격이 판정
  없이 증발하지 않는다(`monitoring` 은 다음 physics step 에야 켜진다). 중복 타격은 공격 단위
  `_hit_targets` 가 막는다. `abort_attack()` 은 히트박스까지 내리며 반복 호출해도 안전하다 —
  ACTIVE 도중 사망해도 잔존 히트박스가 남지 않는다(이미 commit 된 스태미나는 환불하지 않는다).
- `CombatComponent` 가 pending attack(weapon/context/facing)과 phase timer 를 소유한다.
  scene-local 이고 Save 대상이 아니므로 `CombatRuntimeState` 로 올리지 않는다. 공격 도중
  장비나 스탯이 바뀌어도 이미 시작된 공격의 의미는 스냅샷으로 고정된다.
- 스태미나는 선딜에서 **검증만** 하고 ACTIVE commit 때 한 번 차감한다. commit 직전에 다시
  확인하며, 부족하거나 전략 실행이 실패하면 데미지·차감 없이 `IDLE` 로 되돌린다.
- 3차의 임시 edge `enter_recovery_from_immediate_attack()` 과 `WeaponDefinition.attack_cooldown`,
  `CombatComponent.cooldown_remaining` 은 모두 제거했다. 재공격 가능 여부의 유일한 기준은
  action state 가 `IDLE` 인지다.
- 네트워크는 그대로다. action state 를 복제하지 않으며 `NetworkProtocol.VERSION` 은 **13**
  이다. `attack_presented` 는 이제 "공격 시작" 표현 이벤트로 읽으면 된다.
- 4차에서 건드리지 않았던 히트박스 geometry/range와 넉백 적용은 5차에 완료했고 Player
  피격 경직은 6차에 완료했다. 적 공격 파이프라인은 여전히 후속 범위다.

### 5차 — Hitbox data + Knockback (완료)

`AttackDefinition`은 다음 정적 공격 데이터를 함께 소유한다.

```
AttackDefinition
├─ timing: startup_seconds / active_seconds / recovery_seconds
├─ range: 논리적 reach, projectile 이동 거리
├─ rectangle geometry: hitbox_size / hitbox_offset
└─ knockback: 공격자 forward-local impulse
```

- `WeaponDefinition.attack_range`는 제거됐고 공격별 range의 source는
  `weapon.attack_definition.range` 하나다. melee collision 크기와 offset은 range와 독립이다.
- `MeleeAttackStrategy`가 ACTIVE commit 시 `configure_geometry(size, offset, facing)` 후
  `activate(context)`를 호출한다. RectangleShape2D 크기는 항상 양수이고 offset x만 facing으로
  mirror하며 y는 유지한다. HitboxComponent에는 공격 geometry 기본값, 30px 높이, `range * 0.5`
  계산이 없다. immediate sweep은 방금 CollisionShape2D에 넣은 동일 shape/global transform을
  사용한다. query의 256 결과 상한은 defensive technical limit이지 gameplay max_targets가 아니다.
- `twig_sword`는 `range=52`, `hitbox_size=(52,30)`, `hitbox_offset=(26,0)`,
  `knockback=(120,-40)`으로 기존 체감을 그대로 이관했다.
- `CombatComponent.attack()`이 STARTUP 시작 시 authored knockback의 x만 facing으로 반전해
  `DamageContext`에 snapshot한다. melee와 projectile은 이 context를 그대로 공유한다.
- `WeaponDefinition`/`AttackDefinition` 자체는 매 공격 deep-copy하지 않는다. static authored
  Resource를 immutable reference로 유지하며 damage, resolved knockback, target factions,
  hit effects처럼 runtime에 필요한 mutable 의미만 시작 시 context/pending field에 고정한다.
- 성공한 damage는 기존 `HealthComponent.damaged(context)` 신호를 거쳐 권위 Player/Enemy의
  `CharacterBody2D.velocity += context.knockback`으로 이어진다. finite가 아닌 impulse는 runtime
  boundary에서도 거절한다. zero는 유효한 no-op이다.
- Player는 non-zero impulse를 받을 때 기존 climb damage 정책에 관계없이 CLIMB을 먼저 이탈한
  뒤 impulse를 받는다. Enemy `HurtState`는 0.25초 duration만 소유하고 고정 90px 넉백은 없다.
- Player HURT, hit stun, input lock, attack cancel은 추가하지 않았다. 공격 도중 넉백을 받아도
  combat action timeline은 독립적으로 끝까지 진행한다. Movement Mode도 GROUND/AIR/CLIMB뿐이다.
- 모든 계산/적용은 권위 시뮬레이션에만 있고 RPC/payload/save 변경은 없다. Protocol v13과
  Save v4를 유지하며 기존 transform/runtime replication이 결과 위치와 velocity를 전달한다.

적 공격은 아직 `EnemyAgent.perform_attack()` 이 대상 `HealthComponent.receive_damage()` 를
직접 호출하고 `(100,-30)`을 작성한다. Player가 이를 실제 impulse로 받지만, 적 공격을
Hitbox/정적 데이터 파이프라인으로 옮기는 일은 후속 enemy pattern 단계다.

### 6차 — Player HURT / Hit-Stun (완료)

`CombatActionController`에 scene-local `HURT`를 추가했다. 모든 공격 phase와 IDLE에서 HURT로
직접 진입할 수 있고 HURT는 IDLE로만 끝난다. HURT→ATTACK 직접 전이와 HURT→HURT transition은
거절한다. 재피격은 state signal 없이 timer만 refresh한다.

```
PlayerActor
├─ MovementComponent       GROUND / AIR / CLIMB + additive impulse
├─ CombatActionController  state/transition only
├─ CombatComponent         attack timeline owner
└─ PlayerHurtComponent     0.25초 HURT timer + attack interruption + control lock
```

- 직접 damage가 accept되면 return channel을 취소하고 knockback을 먼저 적용한다. 살아 있고
  `DamageContext.causes_hurt`가 true일 때만 HURT를 시작한다. zero knockback도 HURT를 만들며,
  non-zero knockback + `causes_hurt=false`도 가능하다.
- 공격 중 피격은 `interrupt_attack_for_hurt()`로 pending/context/phase/hitbox만 정리한 뒤
  현재 attack phase→HURT로 한 번에 전환한다. STARTUP은 stamina를 쓰지 않았으므로 그대로이고,
  ACTIVE/RECOVERY는 이미 쓴 stamina를 환불하지 않는다. 이미 spawn된 projectile은 유지된다.
- HURT 동안 독립적인 `controls_locked`가 수평 가속, jump, climb 입력/새 진입을 차단한다.
  gravity, collision, move_and_slide와 기존 knockback velocity는 계속 작동한다. interaction,
  quick item, loot pickup, gather도 권위 actor의 HURT를 확인해 거절한다.
- periodic effect와 starvation은 semantic `causes_hurt=false`를 명시해 HP는 감소하지만 HURT나
  attack interruption을 만들지 않는다. damage type 문자열은 reaction 정책에 사용하지 않는다.
- lethal damaged signal에서는 HURT를 시작하지 않는다. death는 hurt reset 후 attack/lifecycle을
  정리하며 respawn/world transition으로 만들어진 새 actor는 IDLE/unlocked다.
- HURT는 무적이 아니다. 기존 contact invulnerability를 변경하지 않았고 Dodge i-frame도 아직
  없다. scene-local timer/state/controls/velocity는 Save v4에 저장하거나 network payload로
  복제하지 않는다. Protocol v13과 기존 transform/runtime replication을 유지한다.

### 7차 NEXT

다음 단계는 Dodge + i-frame이다. 로컬 presentation latency 정책을 함께 검토하되 HURT와 기존
contact invulnerability를 Dodge 무적과 합치지 않는다. Combo/input buffer/cancel window와 적
pattern 재구성은 계속 후속 범위다.

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
- `tests/unit/test_multiplayer_combat_foundation.gd`, `tests/integration/test_multiplayer_combat_loot.gd`,
  `tests/stability_tests.gd` — 전투 경로를 직접 검증한다. 개편하면 여기부터 깨진다. 특히
  "공격 요청 직후 히트박스/데미지" 를 가정한 픽스처는 이제 선딜을 지나야 한다.
- `CombatComponent._process` 는 timeline 진행과 스태미나 재생을 같은 호출에서 한다.
  테스트에서 차감량을 정확히 비교하려면 `stamina_regen_multiplier = 0.0` 으로 얼린다.
- phase 경계의 부동소수점 잔차는 `PHASE_EPSILON` 이 흡수한다. 이 값을 없애면 phase 를
  프레임으로 쪼갤 때 timeline 이 멈출 수 있다.
- 전역 시그널 연결 해제 누락 → `check_project.py` 가 orphan/leak 경고로 실패.
- `ServerWorldRuntime` 경로(`server_runtime_mode`)에서 표현 노드(애니메이션·파티클·카메라)를
  만들면 headless 서버가 텍스처를 로드하게 된다. 새 전투 표현은 전부 권위 경로 바깥에 둔다.
