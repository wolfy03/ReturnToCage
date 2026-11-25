# Monster Editor 호환성: 기존 몬스터와 Map Editor

기존 두 몬스터를 `.rtcmonster`로 어디까지 표현할 수 있는지, 기존 런타임을 어떻게 보존하는지, Map Editor와 어떻게
이어지는지를 정리한다. 수치는 master `57ac9b0`의 코드와 `tools/monster_bridge/contract_probe.tscn`이 Godot 4.7.2에서
실측한 값이다.

## 1. Sewer Beetle (일반 지상 근접)

구성: `EnemyAgent` + 상태 노드 6개(`Idle`, `Patrol`, `Chase`, `Attack`, `Hurt`, `Dead`). 전용 스크립트 없음.

```text
idle ──1.0초──▶ patrol ──탐지──▶ chase ──사거리──▶ attack ──0.7초──▶ chase
  └──────탐지──────────────────────▲   └─ 대상이 chase_range×1.35 밖 ─▶ patrol
피격 ─▶ hurt ──0.25초──▶ chase          체력 0 ─▶ dead ──0.45초──▶ 전리품 + 제거
```

| 항목 | 기존 동작 | 출처 | 문서 표현 |
|---|---|---|---|
| Idle | 정지 1.0초. 대상이 `chase_range`(240) 안이면 즉시 chase | `idle_state.gd` (literal) | `Wait {seconds: 1}` + 전환 2개 |
| Patrol | 스폰 지점 ±90 px 왕복, `move_speed × 0.55` | `patrol_state.gd` (literal) | `GroundPatrol {radius: 90, speed_scale: 0.55}` |
| 감지 | 원점 간 직선 거리 ≤ 240. 시야·높이 제한 없음 | `distance_to_player()` | `TargetDistance <= {stat: chase_range}` |
| Chase | 대상 쪽으로 `move_speed`(58). 거리 > 324면 patrol, ≤ 46이면 attack | `chase_state.gd` | `ChaseTarget` + 전환(우선순위 20, 10) |
| 공격 시작 | 거리 ≤ `attack_range`(46). 쿨다운 없음 | `chase_state.gd` | `TargetDistance <= {stat: attack_range}` |
| 공격 | 전체 0.7초. 0.2초 준비 → **한 순간** 판정 → 0.5초 후딜 | `attack_state.gd` (export) | 패턴 `bite`: windup 0~0.2, recovery 0.2~0.7 |
| 피해 시점·범위 | 0.2초에 대상과의 거리 ≤ 46 + 12면 명중. hitbox 없음 | `perform_attack()` | `RangeStrike {time: 0.2, reach: {stat: attack_range}, slack: 12}` |
| 피해 | `attack_damage`(7) × 난이도 배율, physical, 넉백 (±100, −30) | `perform_attack()` | `damage {multiplier: 1, knockback: [100, -30]}` |
| Body | 사각형 34×22, 원점 중심, layer/mask 1/1 | `sewer_beetle.tscn` | `collision.body` |
| Hurtbox | 사각형 40×28, 원점 중심, layer 2 / mask 4, 고정 | `sewer_beetle.tscn` | `collision.hurtboxes[body]` |
| 피격 | 넉백 impulse + hurt 0.25초 → chase. 피격 후 0.35초 무적 | `_on_damaged`, `hurt_state.gd`, `HealthComponent` | `HurtReaction {seconds: 0.25}`, `stats.hit_invulnerability_seconds` |
| 사망 | 속도 0, 충돌 레이어 제거, 0.45초 뒤 제거 | `dead_state.gd` (export) | `Death {removal_seconds: 0.45}` |
| 전리품 | `sewer_beetle_loot`: moss_fiber(가중 3, 1~2), clean_pebble(가중 1, 1). 난이도 배율 적용 | `.tres` | `loot.entries` |
| 애니메이션 | idle 4f@5 / move 6f@12 / attack 7f@10 / hurt 3f@12 / death 5f@12, 64×48. offset (0, −13). hit frame 2 | profile, `sprite_frames.tres` | `animations`, `presentation` |
| 복제 상태 | idle → IDLE, patrol·chase → MOVING, attack → ATTACKING, hurt → HURT, dead → DEAD | `NetworkEnemyComponent._state_value` | 모듈의 replicated state와 일치 |

**서버와 클라이언트.** 서버(권위)는 위 전부를 실행하고 presenter를 만들지 않는다. 클라이언트는 physics를 끄고
snapshot 위치를 보간하며, `state` enum을 `idle`/`chase`/`attack`/`hurt`/`dead`로 되돌려 presenter에 준다(MOVING은
항상 `chase`로 보인다 — patrol과 chase를 구분하지 않는다).

**결과: 딱정벌레는 Schema V1로 빠짐없이 표현된다.** `examples/sewer_beetle.rtcmonster`는 프로젝트 포함 정적 검증의
8개 영역이 모두 PASS이고 미지원 항목이 없다.

## 2. Frog (도약형)

구성: `FrogAgent`(`EnemyAgent` 상속, export 17개) + 상태 노드 10개(전용 8, 공용 `Hurt`·`Dead`).

```text
idle ─▶ patrol ─▶ (prepare ─▶ hop ─▶ patrol …) ─▶ idle
  └── 탐지 ──▶ alert ─▶ chase ─▶ (prepare ─▶ hop ─▶ chase …)
                          ├─ 사거리 + 쿨다운 ──▶ attack ─▶ chase
                          └─ 대상 상실 / leash / 막힘 ──▶ return ─▶ idle
```

| 항목 | 기존 동작 | 문서 표현 |
|---|---|---|
| 도약 준비 | 접지 상태에서 0.18초 웅크림. 웅크린 동안 뜨면 발사 취소 | `Hop.prepare_seconds` |
| 순찰 도약 | 0.8초 간격, 3번 뛰고 idle. 속도 0.6배, lift 230. 반경 130을 **넘기 전에** 방향 전환 | `Hop {toward: patrol, count: 3, interval_seconds: 0.8, speed_scale: 0.6, lift: 230, patrol_radius: 130}` |
| 추격 도약 | 0.3초 간격, 속도 1배, lift 340 | `Hop {toward: target, count: 0, interval_seconds: 0.3, lift: 340}` |
| 점프·착지 | 발사는 한 번. 공중에서 속도를 다시 주지 않음. 최소 0.08초 뒤 착지 판정, 2.5초 안전 한도 | `Hop` 모듈 계약, `max_air_seconds` |
| 지형 끝 감지 | 착지 예상 지점 아래로 ray. `max_drop`(56)보다 깊으면 hop 안 함 | `Hop.max_drop` |
| 장애물 | 몸 높이의 ray가 벽에 막히고 정점 높이의 ray도 막히면 hop 안 함 | `Hop` 모듈 계약 |
| 막힘 | 진행(6 px 미만) 없이 2.5초면 포기 | `Hop {stuck_seconds: 2.5, min_progress: 6}` → `ActionFailed` |
| 감지 | 대상이 leash(520) 안이고 거리 ≤ `chase_range`(260) → alert 0.35초 → chase | `all[TargetOriginDistance <= 520, TargetDistance <= chase_range]`, `FaceTarget` |
| 도약 공격 | 0.2초 웅크림 → `(1.5 × move_speed, −250)` 도약 → 도약 중 접촉 시 1회 명중 → 착지 후 종료 | 패턴 `leap_bite`: `ApplyImpulse` + `duration_and_landed` |
| 공격 조건 | 거리 ≤ 72 **그리고** 높이 차 ≤ 40, 쿨다운 완료. 사거리 안인데 쿨다운 중이면 제자리 대기 | `AttackAvailable`, `range.vertical: 40`, `Hop.hold_in_attack_range` |
| 공격 쿨다운 | 1.2초. 도약하는 순간 시작, 공격이 끝날 때 다시 시작 | `cooldown: 1.2` + 런타임 계약 §4 |
| 복귀 | origin 28 px 안이면 idle. 막히면 현재 위치를 새 origin으로 | `Hop {toward: origin, arrive_distance: 28, rehome_on_stuck: true}` |
| 추격 제한 | 대상 상실, 대상이 leash 밖, 자신이 leash 밖, 거리 > 351 중 하나면 return | `any[LostTarget, not TargetOriginDistance<=520, DistanceFromOrigin>520, TargetDistance>chase_range×1.35]` |
| 복귀 중 재감지 | leash 안, 거리 ≤ 208(0.8배), origin에서 390(0.75배) 미만 | `all[...]` 조건 |
| 공중 공격·피격 | 공중에서도 맞는다(hurtbox 고정). 피격되면 hurt로 끊기고 쿨다운은 남는다 | interrupt + 쿨다운 계약 |
| 지상 미끄러짐 | hop·공격 외 지상 속도는 1400 px/s²로 감속. 접지는 0.06초 유예 | `movement.ground_brake`, `ground_grace_seconds` |
| 복제 상태 | idle·patrol·alert·chase·return → IDLE, prepare·hop → MOVING | `Hop`의 dynamic 상태: 대기 IDLE, 웅크림·비행 MOVING |
| 애니메이션 | idle 4f@5, jump_start 2f@12, jump/fall 2f@8, land 2f@12, attack 6f@10, hurt 3f@12, death 5f@12, 64×64. offset (4, −19). move 역할 = idle clip | `animations`, `presentation.roles` |

legacy의 `prepare`와 `hop` 상태는 `Hop` 모듈 안으로 접었다(`source_binding.passthrough.folded_states`). 그래서 문서의
상태는 8개다.

### V1로 정확히 표현되지 않는 것 (2건)

`examples/frog.rtcmonster`의 `source_binding.unsupported`에 기록되어 있고, 그래서 이 문서의 `publish`는 **FAIL**이다.

| # | 기존 동작 | V1 표현 | 차이 |
|---|---|---|---|
| 1 | `FrogAttackState`는 도약 중 매 tick **대상의 원점**이 `|dx| ≤ 44, |dy| ≤ 40` 안인지 본다 | 88×80 hitbox `leap_contact` | hitbox는 대상의 **hurtbox**와 겹침을 본다. 대상 hurtbox 크기만큼 더 멀리서 맞는다 |
| 2 | `FrogReturnState`는 origin이 chase hop 한 번 거리보다 가까우면 짧은 순찰 hop(0.6배, lift 230)으로 바꾼다 | `Hop`은 상태당 속도·lift가 하나 | 마지막 hop이 origin을 지나칠 수 있다 |

**확정된 방향** (안정화에서 결정, 근거와 대안 비교는 [stabilization §6](monster_editor_step1_stabilization.md)):
(1) hitbox마다 판정 방식을 고르는 `hitboxes[].target_test`(`hurtbox_overlap` 기본 / `origin_inside`)를 V2에 추가한다
— 88×80 상자가 대상 원점을 포함하는지가 기존 식과 정확히 같다. (2) `Hop`에 `near_goal_speed_scale`·
`near_goal_lift`를 V2에 추가한다. 둘 다 Frog 전용이 아니라 모든 도약·돌진형이 쓸 수 있는 형태다. Schema V1에는
넣지 않았고, 실행할 런타임이 생기는 STEP 5에서 V1→V2 migration과 함께 넣는다.

### 기존 런타임의 알려진 특성 (문서가 그대로 기술하는 것)

- 모든 피해가 hurt를 다시 시작한다. 주기 피해도 그렇다(§ 런타임 계약 3.3).
- hurt는 항상 chase로 돌아간다. 대상이 없으면 chase가 다음 tick에 patrol/return으로 보낸다.
- 공중에서 죽으면 제거될 때까지 그 자리에 멈춘다(`Death`가 속도를 0으로 한다).
- 도약 공격이 플레이어 머리 위에 착지할 수 있다.

## 3. 공통 기능과 특화 기능

| 공통 (모듈로 추출) | 딱정벌레 전용 | 개구리 전용 |
|---|---|---|
| 타깃 선택과 유지, 중력, 넉백, 효과·스탯, hurt, death, 전리품, 복제, presenter | 지상 보행(`GroundPatrol`, `ChaseTarget`), 즉발 거리 판정(`RangeStrike`) | hop 이동(`Hop`), leash, 가장자리·벽 감지, 도약 공격(`ApplyImpulse` + 착지 완료), 공격 쿨다운·수직 사거리, 지상 감속 |

`Wait`, `HurtReaction`, `Death`, `ExecuteAttackPattern`은 두 몬스터가 같은 모듈을 파라미터만 달리해 쓴다.

## 4. Legacy 런타임 보존

```text
Legacy Enemy        EnemyDefinition.actor_scene = sewer_beetle.tscn / frog.tscn → EnemyAgent / FrogAgent + 상태 노드
Data-Driven Enemy   DataEnemyDefinition.actor_scene = data_enemy.tscn → DataEnemyAgent  (MONSTER-STEP 4~5, 미구현)
```

- 두 경로는 `EnemyDefinition`, `EnemySpawnManager`, `NetworkEnemyComponent`, presenter를 공유한다.
- 이번 단계는 기존 몬스터의 scene·script·resource를 하나도 바꾸지 않았다.
- 기존 몬스터를 데이터 런타임으로 옮기는 것은 **선택**이고, 옮기기 전에 같은 시나리오에서 두 런타임의 상태 기록을
  비교한다.

## 5. Import 정책과 편집 가능 범위

기존 몬스터를 가져온 문서는 `source_binding.runtime = "legacy"`이고, `editability`가 섹션마다 다음 중 하나를 가진다.

| 값 | 의미 | legacy 몬스터에서 |
|---|---|---|
| `editable` | 값을 바꿔 Godot 리소스에 다시 쓸 수 있다 | `metadata`(표시 이름), `stats`(EnemyDefinition 5개 수치와 진영), `loot` |
| `read_only` | 값은 보이지만 scene이나 GDScript에 있어 Bridge가 쓰지 않는다 | `movement`, `sensors`, `assets`, `animations`, `presentation`, `collision`, `attack_patterns`, `behavior` |
| `unsupported` | 현재 계약으로 표현할 수 없다 | `source_binding.unsupported[]`에 경로와 이유 |
| `passthrough` | 편집하지 않지만 원본 그대로 보존한다 | `source_binding.passthrough` (예: `folded_states`) |

규칙:

- 알 수 없는 상태 노드나 스크립트를 만나면 지우거나 기본 상태로 바꾸지 않는다. `unsupported`에 기록하고 원본은
  그대로 둔다.
- `unsupported`가 비어 있지 않으면 데이터 런타임용 Export는 차단된다(`publish` = FAIL, `export_blocked_unsupported`).
- 파생에 쓰인 모든 파일의 SHA-256이 `source_binding.files`에 있다. 프로젝트 파일이 바뀌면 검증기가
  `source_changed`를 내고, contract check는 실패한다 — 예제를 다시 확인한 뒤
  `check_godot_contract.py --refresh-bindings`로 해시를 갱신한다. 코드 literal(1.0초, 90 px 등)은 probe로 읽을 수
  없으므로 이 해시가 유일한 감시 수단이다.
- Step 1에는 Import 명령이 없다. 두 예제는 손으로 작성하고 contract check로 검증했다. `editability`는 STEP 2의
  Import가 채울 값의 계약이다.

## 6. Migration 순서

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 기존 몬스터의 동작·파라미터 분석 | 완료 (이 문서) |
| 2 | 데이터 표현 가능 여부 검토 | 완료 (딱정벌레 전부, 개구리 2건 제외) |
| 3 | `.rtcmonster` 예제 작성과 실제 값 대조 | 완료 (contract check 205항목: environment 7, registry 39, legacy 158, behavior 1) |
| 4 | 데이터 런타임에서 지상형 fixture 검증 (Sewer Rat Prototype) | STEP 4~5 |
| 5 | 딱정벌레: 같은 시나리오에서 legacy와 상태 기록 비교 | STEP 5 |
| 6 | `Hop` 구현, 개구리 미지원 2건 해결, 상태 기록 비교 | STEP 5 |
| 7 | 선택적 전환 (definition의 `actor_scene` 교체) | STEP 6 이후, 승인 필요 |

## 7. 지원 요약

| 기능 | Schema V1 | 정적 검증 | 기존 런타임 | 데이터 런타임 |
|---|---|---|---|---|
| 기본 스탯, 진영, 전리품 | O | O | O | 미구현 |
| 사각형 body / hurtbox 1개 | O | O | O | 미구현 |
| 원형 shape, hurtbox 여러 개 | O | O | 엔진은 지원, 기존 scene엔 없음 | 미구현 |
| frame별 hurtbox override | O (`planned`) | O | X | 미구현 |
| hitbox 기반 공격, 다단 히트 | O (`planned`) | O | X (플레이어만) | 미구현 |
| 거리 즉발 공격 | O | O | O | 미구현 |
| sprite sheet / 개별 PNG clip | O | O | O (SpriteFrames) | 표현 계층 공용 |
| FSM + 모듈 + 조건 | O | O | GDScript로 고정 | 미구현 |
| hop 이동 | O | O | O (FrogAgent) | 미구현 |
| 방어력·저항 등 확장 스탯 | O (`planned`) | 경고 | X | 미정 |
| 보스 Phase | O (`planned`) | 경고 | X | 미정 |
| 투사체, 상태이상, 소환 | 이벤트 예약 (`planned`) | 경고 | X | 미정 |
| capsule / polygon / composite shape | X (거절) | – | – | 후속 |

## 8. Python Map Editor 연동

Map Editor Schema V6의 Enemy 스폰은 `enemy_id` 문자열만 저장하고, 카탈로그는 `data/content/enemies/*.tres`의 `id`를
읽는다. Monster Editor는 **이 경로를 바꾸지 않는다**: 게시가 `data/content/enemies/<monster_id>.tres`를 만들면
Map Editor는 수정 없이 그 몬스터를 본다. `.rtcmap` 스키마는 그대로다.

```text
Monster Editor → 정적 검증 → Godot 검증 → 게시 (data/content/enemies/<id>.tres)
     → ContentRegistry → Map Editor 카탈로그 (discover_enemies) → Enemy Spawn 배치
```

| 상황 | 정책 |
|---|---|
| 몬스터 추가 | 게시 후 Map Editor가 프로젝트를 다시 읽으면 목록에 나온다. Map Editor 변경 없음 |
| 표시 이름 변경 | `monster_id`가 같으므로 맵은 영향 없다 |
| 이미지 변경 | 맵은 ID만 참조하므로 영향 없다 |
| ID 변경 | 지원하지 않는다. "새 ID로 복제 + 이전 것 삭제"로만 가능하고, 삭제 규칙을 따른다 |
| 삭제 | 게시 전에 프로젝트의 모든 region scene에서 그 `enemy_id`를 쓰는 스폰을 찾아 목록으로 보여 주고, 남아 있으면 삭제를 거절한다. 강제 삭제는 없다 |
| 존재하지 않는 몬스터 참조 | Map Editor가 이미 `enemy_reference` FAIL로 막고, Bridge는 `RESOURCE_MISSING`으로 거절한다 **(기존 동작)** |
| 게시되지 않은 몬스터 | Map Editor 카탈로그에 나오지 않는다. 초안은 `.rtcmonster` 파일일 뿐 게임 콘텐츠가 아니다 |
| 카탈로그 갱신 | Map Editor는 지역을 검증할 때마다 프로젝트 폴더의 Enemy 목록을 다시 읽는다(`discover_enemies`). 파일 감시는 하지 않는다 |

초안과 게시본의 구분은 문서의 `source_binding`(null = 초안)과 `rtcmonster.monster_catalog()`로 한다. 카탈로그의 각
항목은 다음 중 하나다.

| 상태 | 뜻 | 근거 |
|---|---|---|
| `draft` | `.rtcmonster` 파일일 뿐 게임 콘텐츠가 아니다 | 문서를 읽음 |
| `discovered` | `data/content/enemies`에 파일이 있다. 게임이 등록했는지는 모른다 | 파일 scan (Python) |
| `registry_verified` | `ContentRegistry`가 그 ID를 보고했다 | Godot probe |
| `not_in_registry` | 파일은 있는데 `ContentRegistry`에 없다 | Godot probe |

파일이 있다는 것만으로 "등록됨"이라고 하지 않는다. 같은 ID를 여러 파일이 정의하면 **어느 것도 채택하지 않고** 모든
경로를 문제로 보고하며, 그 ID는 Import와 신규 등록이 막힌다(`MonsterCatalog.is_id_free`). 파일 하나가 깨져도
(인코딩 오류, ID 없음, 링크, 크기 초과) 나머지 목록은 유지된다. `published_monsters()`는 Map Editor와 같은 범위의
호환 뷰로 남아 있으며 중복·오류 파일을 제외한다.

초안의 ID가 게임에 있는 ID와 같으면 `duplicate_monster_id` FAIL이다. `sewer_rat_prototype`은 초안이고, contract
check가 ContentRegistry에 없음을 확인한다.
