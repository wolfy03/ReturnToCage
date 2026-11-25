# Monster Editor 런타임 계약

`.rtcmonster` 문서를 실행할 데이터 기반 런타임(`DataEnemyAgent`)이 지켜야 할 규칙이다.

> **상태: 설계 계약. 구현되지 않았다.** MONSTER-STEP 1에는 이 계약을 실행하는 Godot 코드가 없다. 게임의 모든
> 몬스터는 기존 `EnemyAgent`/`FrogAgent`로 동작한다. 이 문서의 규칙 중 Python에서 실제로 검사되는 것은
> tick 양자화(`timing.py`), 좌표 변환(`geometry.py`), 타임라인·상태 그래프의 정적 규칙(`validation.py`)뿐이다.
> 구현 단계는 [roadmap](monster_editor_roadmap.md)의 STEP 4(전투)와 STEP 5(행동)다.

기존 동작을 그대로 옮긴 규칙에는 **[기존]**, 기존과 달라지는 규칙에는 **[변경]**을 붙였다.

## 1. tick 순서

권위 actor만 실행한다(`is_simulation_authority()`). 하나의 physics clock이 전부를 진행한다.

```text
1. 쿨다운 감소 (패턴별)                          [기존: FrogAgent.attack_cooldown_remaining]
2. 타깃 선택                                     [기존: EnemyAgent._select_target]
3. 중력, ground_brake                            [기존]
4. 전역 interrupt 처리 (death > hurt)             [기존: _on_died / _on_damaged, tick 경계로 정렬됨 → 변경]
5. 현재 상태의 module tick
   └ ExecuteAttackPattern이면 Attack Timeline tick: 이번 tick의 이벤트 실행, hitbox on/off
6. 전환 평가 → 최대 1회 전환                      [기존: tick당 change_state 1회]
7. move_and_slide
8. facing 갱신 (facing lock이 없을 때 velocity.x 부호) [기존]
9. hurtbox 집합 갱신 (override)
```

- render frame(`_process`)은 판정·상태·시간을 소유하지 않는다. **[변경]** 기존 `HealthComponent.invulnerable_remaining`은
  `_process`에서 줄어든다. 데이터 기반 몬스터의 `hit_invulnerability_seconds`는 physics tick으로 센다.
- 비권위 actor는 이 순서의 어느 단계도 실행하지 않는다. 받은 snapshot을 보간하고 presenter만 돈다. **[기존]**

## 2. 시간과 tick

- 저장 단위는 초, 실행 단위는 정수 tick. 변환은 하나다:

  ```text
  tick_of(t) = max(0, ceil(t × tick_rate − 1e-6))
  ```

- 순간 이벤트(시각 `t`)는 시작 후 `tick_of(t)`번째 tick에 **한 번** 실행된다. tick 0은 상태·패턴이 시작된 tick이고,
  `t ≤ 0`인 이벤트는 그 tick에 실행된다.
- 구간 `[start, end)`는 `tick_of(start) ≤ n < tick_of(end)`인 tick에서 유효하다(반열림 — 플레이어 전투 window와 같다).
  시작 tick은 포함하고 끝 tick은 포함하지 않는다. tick을 하나도 포함하지 않는 구간은 검증 실패다
  (`window_shorter_than_one_tick`).
- **같은 tick에 떨어진 이벤트는 문서에 나열된 순서로 실행된다**(`timing.schedule`). 저장된 초의 대소는 동률을 가르지
  않는다. 나열 순서가 초의 순서와 어긋나면 검증기가 `event_order_differs_from_time`으로 경고한다.
- 패턴은 `tick_of(duration)` tick에 끝난다. 그 tick의 이벤트는 완료 판정 전에 실행된다. `duration`을 넘는 시각의
  이벤트는 검증 실패다(`event_after_pattern_end`).
- 긴 프레임은 tick을 건너뛰지 않는다. 엔진이 밀린 physics tick을 차례로 실행하므로 모든 tick 번호를 순서대로 지난다.
- 비정상 입력(0 이하·비유한 tick rate, 비유한 시간)은 `ValueError`다. 조용히 0으로 처리하지 않는다.
- 타이머는 tick 수를 센다. **[변경]** 기존 상태는 `remaining -= delta` 후 비교라, `0.7 − 12 × (1/60)`이 `0.5`와
  정확히 같지 않아 경계 tick이 반올림에 좌우된다. 정수 tick은 이 흔들림이 없다. 60 Hz에서 기존 수치는 모두 같은
  tick에 대응한다: 0.2초 = 12, 0.25초 = 15, 0.45초 = 27, 0.7초 = 42. 0.18초(개구리 웅크림)는 11 tick = 0.1833초다.
- tick rate는 가정하지 않는다. 런타임은 `Engine.physics_ticks_per_second`를 읽고, 검증기는 `tick_rate` 인자를
  받는다(기본 60, contract probe가 프로젝트 실제 값과 같은지 확인).
- **clip은 시간을 결정하지 않는다.** clip의 FPS·frame 수를 바꿔도 `tick_of`의 입력은 그대로다. 그림과 판정이
  어긋나면 검증기가 `hit_frame_mismatch` / `clip_longer_than_gameplay` 경고로 알려 준다. 판정은 움직이지 않는다.
- 편집기는 `timing.timeline(pattern, tick_rate)`로 "저장된 초 → tick → 실제 실행 초"를 나란히 보여 준다.

## 3. 상태 기계

### 3.1 전환 평가

한 tick에 한 번, module tick 뒤에:

1. 현재 상태의 전환을 `priority` 내림차순, 같으면 문서 순서로 정렬한다.
2. 순서대로 조건을 평가해 **처음 참인 전환 하나**를 실행한다. 나머지는 평가하지 않는다.
3. 전환했으면 이번 tick은 끝이다. 새 상태의 module은 `enter`만 실행되고 첫 tick은 다음 physics tick이다.

tick당 전환이 한 번이므로 한 tick 안의 무한 전환은 구조적으로 없다. **[기존]** 조건은 부작용이 없다
(`RandomChance`만 서버 RNG를 소비한다).

### 3.2 조건 조합

`all`은 왼쪽부터 평가해 거짓에서 멈추고, `any`는 참에서 멈춘다. `not`은 한 조건을 뒤집는다. 타깃이 없을 때
거리 조건의 거리는 무한대다 — `TargetDistance <= x`는 거짓, `TargetDistance > x`는 참. **[기존]**
`ActionCompleted`/`ActionFailed`/`AttackPatternCompleted`는 사건이 일어난 tick의 전환 평가에서만 참이다.

### 3.3 전역 interrupt

| interrupt | 조건 | 동작 | 우선순위 |
|---|---|---|---|
| death | 체력 0 | 현재 module·패턴을 정리하고 `interrupts.death.state`로. 이후 어떤 전환도 없다 | 최상 |
| hurt | 직접 피해를 받음, `interrupts.hurt.policy = always`, 실행 중 패턴이 `interrupt.on_hurt = ignore`가 아님 | 현재 module·패턴을 정리하고 `interrupts.hurt.state`로. 이미 hurt면 다시 진입(타이머 재시작) | death 다음 |

- 같은 tick에 둘 다 일어나면 death만 처리한다. interrupt는 일반 전환보다 먼저다.
- **[기존]** 지금의 `EnemyAgent._on_damaged`는 주기 피해(`causes_hurt = false`)에도 hurt를 다시 시작한다. V1의
  `always`는 이 동작이다. `causes_hurt`를 존중하는 정책은 V2에서 값을 추가한다.
- `policy = never`는 hurt 상태로 가지 않는다(피해와 넉백은 받는다). `on_hurt = ignore`는 그 패턴 동안만 같은 효과다(슈퍼아머).
- 상태의 `interruptible = false`는 `planned`다 — V1 런타임은 읽지 않는다.

### 3.4 Action Module 계약

모든 module은 세 진입점을 가진다: `enter(state, params)`, `tick(delta) -> RUNNING | COMPLETED | FAILED`,
`exit(reason)`. `exit`는 정상 전환, interrupt, despawn 어느 경우에도 정확히 한 번 호출된다.

| module | 완료 | 실패 | 중단 시 정리 | 권위 |
|---|---|---|---|---|
| `Wait` | `seconds` 경과 | – | 없음 | 서버 |
| `GroundPatrol` | – | – | 수평 속도는 다음 상태가 정한다 | 서버 |
| `ChaseTarget` | – | – | 위와 같음 | 서버 |
| `FaceTarget` | `seconds` 경과 | – | 없음 | 서버 |
| `Hop` | `count`번 hop / origin 도착 | 진행 없이 `stuck_seconds`, 양방향 모두 hop 불가 | 공중의 hop은 취소하지 않는다. 다음 상태가 속도를 물려받는다 | 서버 |
| `ExecuteAttackPattern` | 패턴 완료 | 선택 가능한 패턴 없음 | 모든 hitbox 해제, facing lock 해제, 무적 해제. 이미 시작된 쿨다운은 유지 | 서버 |
| `HurtReaction` | `seconds` 경과 | – | 없음 | 서버 |
| `Death` | (종료 상태) | – | 중단 불가 | 서버 |
| `ReturnToOrigin` (`planned`) | origin 도착 | – | 없음 | 서버 |

상태에 `max_seconds`가 있으면 초과 tick에 module 결과와 무관하게 `ActionFailed`가 된다.

**원자 구간.** `Hop`의 웅크림·비행과 `ExecuteAttackPattern`의 패턴 전체는 원자 구간이다: 그동안 일반 전환은
평가를 미루고 interrupt만 통과한다. **[기존]** 개구리는 prepare/hop 상태에서 탐지를 하지 않고, 공격 상태는 끝나야
chase로 돌아간다.

**`Hop` 한 번** (개구리의 prepare + hop 상태를 접은 것): 접지 상태에서 `interval_seconds` 대기 → 방향 결정 →
착지 예상 지점이 `max_drop`보다 깊거나 벽에 막히면 hop하지 않음 → `prepare_seconds` 웅크림(속도 0) → 여전히
접지면 `velocity = (dir × move_speed × speed_scale, −lift)`를 **한 번** 설정 → 최소 0.08초 뒤 착지하거나
`max_air_seconds`가 지나면 끝. 웅크린 동안 공중에 뜨면 발사를 취소한다. 공중 재점프는 없다.

### 3.5 공격 패턴 선택 (`pattern: ""`일 때)

1. 후보 = 쿨다운이 끝났고, 대상까지 거리가 `range.min..max` 안이고, `range.vertical`이 있으면 높이 차가 그 안이며,
   `condition`(있으면)이 참인 패턴.
2. `priority`가 가장 높은 것만 남긴다.
3. 여럿이면 `weight` 비례로 **서버 RNG**에서 하나를 뽑는다. Phase가 `pattern_weights`를 주면 그 값을 쓴다(`planned`).
4. 후보가 없으면 `ActionFailed`.

`AttackAvailable` 조건은 1단계 후보가 비어 있지 않은지와 같다.

## 4. Attack Timeline

패턴 하나의 실행(= **공격 인스턴스**)마다 서버가 `attack_seq`(actor 안에서 1씩 증가)를 부여한다.

```text
tick n (패턴 시작 후 n번째):
  1. tick_of(event.time) == n 인 이벤트를 문서 순서대로 실행
  2. 켜져 있는 hitbox로 판정
  3. 완료 판정: duration 모드 → n == tick_of(duration)
                duration_and_landed → n ≥ tick_of(duration) 이고 착지 (공중 시간 ≥ min_air_seconds),
                                      또는 공중 시간 ≥ max_air_seconds
```

- **쿨다운**은 첫 gameplay 이벤트가 실행되는 tick에 시작하고, 패턴이 끝나는 tick에 다시 시작한다. 그래서 피격으로
  끊긴 공격도 쿨다운을 남긴다. **[기존: FrogAttackState]**
- **`facing_locked`**: 패턴 시작 시 대상 쪽을 본 뒤 끝날 때까지 방향을 바꾸지 않는다. `LockFacing`/`UnlockFacing`은
  패턴 중간에 이를 바꾸는 `planned` 이벤트다.
- **`movement_locked`**: 패턴 시작 시 수평 속도를 0으로 하고, `ApplyImpulse`/`ApplyMovement`만 속도를 준다.
- **`ApplyImpulse`**: `velocity.x`는 전방 기준이라 facing으로 부호가 정해진다. `x_scales_move_speed`면 x는
  `move_speed`의 배수다. `mode = set`은 속도를 대입, `add`는 더한다. `requires_grounded`인데 공중이면 건너뛴다.
  **[기존: 개구리 도약 = set, (1.5 × move_speed, −250), 접지 필요]**
- **gameplay 이벤트는 권위 런타임만 실행한다.** presentation 이벤트(`PlayAnimation`, `SpawnEffect`, `PlaySound`)는
  표현 계층에서만 소비되고, 서버 런타임(headless)은 읽지도 않는다.

### 4.1 피해 적용

| 규칙 | 계약 |
|---|---|
| 피해량 | `attack_power(= attack_damage × 난이도 배율, 효과 반영) × damage.multiplier`. 대상 쪽에서 `max(1, amount − defense)` **[기존]** |
| 넉백 | `damage.knockback`, x는 공격자→대상 방향으로 부호 결정 **[기존: (±100, −30)]** |
| 대상당 횟수 | `once_per_target`: 공격 인스턴스 하나에서 같은 대상은 한 번. 패턴의 **모든 hitbox가 hit 목록을 공유**하므로 hitbox가 여러 개여도, 여러 tick 켜져 있어도 중복 피해가 없다 |
| 다단 히트 | `multi_hit`: 같은 대상을 `multi_hit_interval`(tick으로 양자화, 최소 1 tick)마다 다시 맞힐 수 있다 |
| 늦게 들어온 대상 | hitbox가 켜진 뒤 범위에 들어와도 맞는다(켜져 있는 매 tick 판정) |
| 긴 프레임 | hitbox는 켜지는 tick에 direct space query로 즉시 한 번 훑는다. `monitoring`은 다음 step에야 켜지기 때문이다 **[기존: HitboxComponent]** |
| 빠른 이동 | tick 사이를 건너뛰는 터널링은 V1에서 막지 않는다. 필요한 속도는 hitbox 크기로 보정한다 (알려진 한계) |
| 진영 | `source_faction`이 같은 대상은 맞지 않는다 **[기존: HurtboxComponent]** |
| 월드 | 같은 `SubViewport.World2D` 안에서만 물리 질의가 일어난다 **[기존: ServerWorldRuntime]** |
| 죽은 대상 | `current_health <= 0`이면 `receive_damage`가 거절한다 **[기존]** |
| 대상의 무적 | 대상의 post-hit 무적·회피 무적은 대상이 판단한다. 거절된 hit는 hit 목록에 넣지 않는다 **[기존]** |
| `RangeStrike` | 현재 타깃 하나에만, `거리 ≤ reach + slack`일 때 한 번. hitbox를 쓰지 않는다 **[기존: perform_attack]** |

### 4.2 중단과 정리

패턴은 hurt interrupt(`on_hurt = cancel`), death, despawn, 월드 전환으로 끊길 수 있다. 어떤 경우든 같은 tick에:
모든 hitbox를 끄고 hit 목록을 비우고, facing lock과 패턴이 건 무적을 풀고, 남은 이벤트를 버린다. 이미 준 피해와
이미 적용한 impulse는 되돌리지 않는다. 끊긴 패턴은 `AttackPatternCompleted`를 내지 않는다.

## 5. Collision 해석

- **Body**는 actor 생성 시 한 번 만들고 바꾸지 않는다.
- **Hurtbox 집합**은 매 tick 다음 순서로 정한다: 기본 → 현재 clip의 override → 현재 frame의 override.
  "현재 clip·frame"은 presenter가 아니라 **논리 clip 시계**에서 나온다: 상태(또는 패턴)가 쓰는 clip ID와 그 상태의
  경과 tick, 그리고 문서의 frame 지속 시간(`timing.frame_at`)만으로 계산한다. 텍스처도 `AnimatedSprite2D`도
  필요 없다. 클라이언트의 실제 재생 위치와 다를 수 있고, 다르면 서버 값이 맞는 값이다.
- **Hitbox**는 패턴 이벤트로만 켜진다. 켤 때 shape와 위치를 facing에 맞춰 구성한다(중심 x만 반전).
- 좌우 반전은 body·hurtbox·hitbox 모두 같은 규칙이다. actor root는 뒤집지 않는다. **[기존]**
- `hurtbox_overrides`와 `hitboxes`는 V1에서 `planned`다(기존 런타임에 없다).
- V1의 hitbox는 대상의 **hurtbox와의 겹침**만 판정한다. 대상 원점 기준 판정(개구리의 접촉 판정)은 V2에서
  `hitboxes[].target_test`로 추가하기로 결정했다
  ([stabilization §6](monster_editor_step1_stabilization.md)).
- shape 종류는 `geometry.SHAPES` 레지스트리가 정한다. 런타임의 shape 생성도 같은 표를 기준으로 한다.

## 6. 서버 권위

| 서버가 결정 | 클라이언트가 표현 |
|---|---|
| 위치·속도, AI 상태, 타깃, 패턴 선택, RNG, 공격 시작·종료, hitbox·hurtbox, 피해, 넉백, 체력, 상태이상, 사망, 전리품 | sprite 애니메이션, 방향, 공격·피격·사망 연출, 사운드, VFX, 체력 UI |

클라이언트는 몬스터에 대해 어떤 intent도 보내지 않는다. 클라이언트가 계산한 frame이나 충돌은 판정에 쓰이지
않는다. 몬스터 문서는 클라이언트에 전송되지 않는다 — 양쪽이 같은 `ContentRegistry` 콘텐츠를 갖고, 프로토콜
handshake가 버전 불일치를 막는다. **[기존]**

## 7. 네트워크

### 7.1 지금 복제되는 것 (`EnemyRuntimeSnapshot`, 프로토콜 20)

`entity_id`, `enemy_id`, `position`, `velocity`, `facing`, `health`, `max_health`, `state`(IDLE·MOVING·ATTACKING·
HURT·DEAD), `sequence`. 20 Hz 비신뢰 + 체력·상태 변경 시 신뢰. 스폰·despawn·roster는 별도 신뢰 메시지.

### 7.2 검토한 항목

| 항목 | 판단 | 근거 |
|---|---|---|
| Monster ID | 이미 있음 (`enemy_id`) | |
| Runtime Entity ID | 이미 있음 (`entity_id`) | |
| Facing | 이미 있음 | |
| Behavior State ID | **추가하지 않음** | 표현에 필요한 것은 5개 enum과 속도로 충분하다. 상태마다 `snapshot_state`가 매핑을 정한다 |
| Animation Clip ID / Start Tick | **추가하지 않음** | presenter가 state·velocity·health에서 고른다. clip을 복제하면 표현이 gameplay 데이터가 된다 |
| Action ID | **추가하지 않음** | 위와 같음. `Hop`의 웅크림은 "MOVING + 정지"로 추론한다 **[기존]** |
| Attack Pattern ID | **추가 필요 (STEP 4)** | 패턴이 둘 이상이면 ATTACKING만으로 어느 clip인지 알 수 없다 |
| Attack Instance ID (`attack_seq`) | **추가 필요 (STEP 4)** | 같은 패턴을 연달아 쓰면 state가 바뀌지 않아 재생을 다시 시작할 계기가 없다 |
| Attack Elapsed | **추가 필요 (STEP 4)** | 중간 접속·재접속 시 공격 연출을 중간부터 맞추려면 필요. tick 수가 아니라 초 단위 실수 |
| Attack Start Tick | 추가하지 않음 | peer 간 공유 tick 시계가 없다. elapsed로 충분하다 |
| Phase ID | 보류 (보스 단계) | Phase 런타임이 생길 때 결정 |
| Event Sequence | 이미 있음 (`sequence`) | stale·중복 snapshot 거절 |

### 7.3 확장 방식 (STEP 4에서 실행)

- `EnemyRuntimeSnapshot`에 `attack_pattern`(StringName, 빈 값 = 없음), `attack_seq`(int), `attack_elapsed`(float)를
  더한다. payload가 바뀌므로 `NetworkProtocol.VERSION`을 21로 올리고, DTO validator·단위 테스트·handshake
  불일치 테스트를 함께 고친다. 같은 버전 안에서 신·구 payload를 섞어 받지 않는다.
- legacy 몬스터는 `attack_pattern = &""`, `attack_seq`만 증가시켜 같은 경로를 탄다.
- 클라이언트 presenter: `attack_seq`가 바뀌면 공격 clip을 처음부터, 같으면 유지. 처음 받는 snapshot이면
  `attack_elapsed` 위치에서 시작한다.
- 지연·역전: `sequence`가 낮은 snapshot은 버린다 **[기존]**. 공격 중 hurt/dead 전환은 신뢰 snapshot으로 가므로
  유실되지 않고, presenter 우선순위(death > hurt > attack)가 늦게 온 공격 표현을 덮는다 **[기존]**.
- **이번 단계는 프로토콜을 바꾸지 않았다.** VERSION은 20이고 contract probe가 이를 확인한다.

## 8. Headless 분리

서버 런타임이 읽는 데이터 — stats, 상태·모듈·조건, 패턴·이벤트(gameplay), body·hurtbox·hitbox, 피해 정의, 선택
규칙, clip의 frame **지속 시간** — 는 전부 숫자와 ID다. 텍스처는 없다.

- `DataEnemyDefinition`은 clip의 시간 표(clip ID → frame 지속 시간 배열)만 갖고 `SpriteFrames`는 참조하지 않는다.
- `animation_profile_path`는 문자열이고, `presentation_enabled = true`인 actor만 `ResourceLoader.load`한다.
  **[기존: EnemyAgent._create_presentation]** 서버 런타임 actor는 presenter를 만들지 않는다 — contract probe가 두
  기존 몬스터에 대해 이를 실측한다.
- presentation 이벤트와 `presentation` 섹션은 서버용 리소스에 넣지 않는다.

## 9. 보스·Phase 확장 (계약만, `planned`)

`behavior.phases[]`가 자리다: `health_ratio_below`에 도달하면 한 번 `enter_state`로 가고, 이후 패턴 선택 가중치를
`pattern_weights`로 바꾼다. 연속 공격은 `ExecuteAttackPattern` 상태를 `AttackPatternCompleted`로 잇는 것으로 이미
표현된다. 반복 제한, 소환, 버프, 이동 방식 변경은 예약된 모듈(`Summon`, `ApplyBuff`, `Enrage`…)과 조건으로
추가한다. 이번 단계는 이 중 어느 것도 실행 규칙을 확정하지 않았고, 검증기는 사용 시 `planned` 경고를 낸다.
