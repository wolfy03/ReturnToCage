# `.rtcmonster` Schema V1

몬스터 한 종의 편집 원본이다. 정의의 단일 출처는 `tools/python_monster_editor/rtcmonster/schema.py`와
`modules.py`이고, 이 문서의 표(`generated:` 주석 사이)는 `python -m rtcmonster.reference` 출력이다.
`tests/test_contracts.py`가 표와 코드가 어긋나면 실패한다.

## 1. 파일 형식

- 확장자 `.rtcmonster`, UTF-8(BOM 없음) JSON, 줄바꿈 LF, 마지막에 개행 1개, 최대 8 MiB.
- **정규 직렬화.** 키는 스키마 순서, 들여쓰기 2칸, 숫자 리스트(벡터·사각형)는 한 줄. `map` 타입은 키 정렬.
  값이 같은 문서는 항상 같은 바이트가 된다 — 키 순서나 `24.0`/`24` 표기 차이, 생략한 기본값은 저장하면 사라진다.
  정규 형식으로 저장된 파일은 열었다 저장해도 한 바이트도 바뀌지 않는다.
- **숫자.** 유한한 값만. `NaN`·`Infinity`·`1e999`는 읽기 단계에서 거절한다. 정수 값의 실수는 정수로 저장한다.
- **모르는 필드는 거절한다.** 예외는 `editor_metadata.ui`와 `source_binding.passthrough`(불투명 JSON) 둘뿐이다.
- **중복 키는 거절한다.**
- 문서는 코드를 담지 않는다. 실행되는 것은 전부 레지스트리 ID(모듈·조건·이벤트)다.

### 버전 정책

| 상황 | 동작 |
|---|---|
| `schema_version` 없음, 정수가 아님 | 거절 |
| `document_type`이 `"rtcmonster"`가 아님 | 거절 |
| 지원하는 이전 버전 | `document.py`의 migration 함수로 현재 구조로 올린 뒤 연다. 저장하면 현재 버전 |
| 더 높은 버전 | 거절 ("newer editor"). 모르는 필드를 버리고 여는 일은 없다 |

V1 안에서는 필드를 추가하지 않는다. 필드·모듈 파라미터·이벤트 타입이 늘면 V2가 되고 V1→V2 migration을 함께 넣는다.
모듈·조건·이벤트를 **추가**하는 것도 이전 편집기가 열 수 없게 만들므로 버전을 올린다.

## 2. 단위와 좌표

| 항목 | 규약 |
|---|---|
| 길이 | Godot 월드 픽셀 |
| 시간 | 초. 권위 실행은 tick으로 양자화 ([runtime contract §2](monster_editor_runtime_contract.md)) |
| 축 | +X 오른쪽, +Y 아래 |
| 원점 | actor(`CharacterBody2D`) local origin. 기존 scene의 원점을 옮기지 않는다 |
| 기준 방향 | 모든 shape·벡터는 **오른쪽을 본 상태**로 저장 |
| 좌우 반전 | facing이 왼쪽이면 중심 x와 벡터 x의 부호만 바꾼다. 크기·y는 그대로 |
| 사각형 | `center` + `size`(전체 너비·높이) = `CollisionShape2D.position` + `RectangleShape2D.size` |
| 원 | `center` + `radius` = `CollisionShape2D.position` + `CircleShape2D.radius` |
| 화면 zoom | 저장하지 않는다 |
| `visual_scale` | 표현 child에만 적용. collision에는 절대 적용하지 않는다 |

### sprite 좌표 ↔ actor 좌표

`EnemyAnimationPresenter`의 실제 구조를 그대로 식으로 옮긴 것이다. frame은 `AnimatedSprite2D`에 **중앙 정렬**되고,
sprite는 `visual_offset`만큼 이동하며, presenter node 전체가 `visual_scale`로 확대되고 facing에 따라 x가 반전된다.
따라서 `visual_offset`도 함께 반전된다.

```text
dir     = facing(±1) × (faces_right_by_default ? 1 : -1)
actor.x = (p.x − frame_w/2 + visual_offset.x + frame.offset.x) × visual_scale.x × dir
actor.y = (p.y − frame_h/2 + visual_offset.y + frame.offset.y) × visual_scale.y
```

`geometry.sprite_to_actor` / `actor_to_sprite`가 이 식과 역변환이다. Bottom-center anchor는 강제 규격이 아니라 제작
편의 기능이다: `geometry.bottom_center_offset(frame_size, visual_scale, body_shape, foot_margin)`가 "frame 아래
가운데 = body 바닥"이 되는 `visual_offset`을 제안할 뿐, 원점과 body shape는 바꾸지 않는다. 딱정벌레의 실제 값
`[0, -13]`이 이 식의 결과와 같다(64×48 frame, body 높이 22). 이미지 해상도와 frame 크기는 몬스터마다 달라도 된다.
256×256·여백 50 px 같은 규격은 `geometry.slice_grid(..., origin, spacing)`으로 자를 수 있는 프리셋일 뿐이다.

## 3. 지원 수준 (Support 열)

저장할 수 있다는 것과 게임에 적용된다는 것은 다르다.

| 값 | 의미 |
|---|---|
| `applied` | 기존 Godot 런타임이 같은 의미의 값을 실제로 읽는다 (`EnemyDefinition`, actor scene, `EnemyAnimationProfile`, `LootTableDefinition`). 문서에서 리소스로 내보내는 Bridge는 아직 없다 |
| `contract` | 데이터 기반 런타임이 따를 계약이고 기존 동작을 그대로 기술한다. 데이터에서 실행하는 런타임은 아직 없다 |
| `planned` | 저장·검증만 된다. 어떤 런타임도 읽지 않는다. 기본값이 아니면 `compatibility` 경고가 난다 |
| `editor` | 편집기 전용. 게임과 무관하다 |

## 4. 필드

경로의 `[]`는 리스트 항목, `.*`는 map 값이다. "required"는 생략할 수 없는 필드다. 컨테이너의 지원 수준은 따로
표시하지 않은 하위 필드에 그대로 적용된다.

<!-- generated:fields -->
| Field | Type | Default | Range | Unit | Support | Meaning |
|---|---|---|---|---|---|---|
| `monster_id` | id | required |  |  | applied | EnemyDefinition.id. Map spawns reference it, so it never follows the display name. |
| `metadata.display_name` | text | required | <= 120 characters |  | applied | EnemyDefinition.display_name. |
| `metadata.description` | text | "" | <= 2000 characters |  | editor |  |
| `metadata.category` | id or "" | "" |  |  | editor | Catalog grouping, for example beetle or amphibian. |
| `metadata.rank` | choice | normal | normal \| elite \| boss |  | planned |  |
| `metadata.habitats` | list of id | [] | <= 16 items |  | editor | Region IDs or biome names the monster is meant for. |
| `metadata.tags` | list of id | [] | <= 32 items |  | editor |  |
| `metadata.thumbnail` | project path | "" | .png |  | editor |  |
| `stats.max_health` | number | 20 | [1, 99999] | HP | applied |  |
| `stats.attack_damage` | number | 4 | [0, 9999] | HP | applied |  |
| `stats.move_speed` | number | 55 | [0, 1000] | px/s | applied |  |
| `stats.chase_range` | number | 230 | [0, 2000] | px | applied |  |
| `stats.attack_range` | number | 42 | [0, 1000] | px | applied |  |
| `stats.faction` | id | hostile |  |  | applied |  |
| `stats.hit_invulnerability_seconds` | number | 0.35 | [0, 10] | s | contract | HealthComponent.invulnerability_seconds on the actor scene: direct hits are ignored this long after one lands. |
| `stats.planned.defense` | number | 0 | [0, 9999] | HP | planned |  |
| `stats.planned.attack_speed` | number | 1 | [0.1, 10] | x | planned |  |
| `stats.planned.knockback_resistance` | number | 0 | [0, 1] | ratio | planned |  |
| `stats.planned.stagger_resistance` | number | 0 | [0, 1] | ratio | planned |  |
| `stats.planned.damage_resistances` | map of id to number | {} |  |  | planned |  |
| `stats.planned.status_resistances` | map of id to number | {} |  |  | planned |  |
| `movement.locomotion` | choice | ground | ground \| hop |  | contract | fly is reserved. |
| `movement.gravity` | number | 1100 | [0, 5000] | px/s^2 | contract | EnemyAgent.GRAVITY. A constant in the legacy runtime. |
| `movement.ground_brake` | number | 0 | [0, 10000] | px/s^2 | contract | Deceleration of leftover ground speed. 0 = none. |
| `movement.ground_grace_seconds` | number | 0 | [0, 1] | s | contract | Floor contact is remembered this long. |
| `sensors.target_policy` | choice | nearest_player | nearest_player |  | contract |  |
| `sensors.target_keep_scale` | number | 1.35 | [1, 10] | x chase_range | contract | The current target is kept inside chase_range times this. |
| `sensors.leash_distance` | number or null | null | [32, 4000] | px | contract | Farthest chase from the spawn origin. null = none. |
| `assets.images` | list of object | [] | <= 256 items |  | applied |  |
| `assets.images[].id` | id | required |  |  | applied |  |
| `assets.images[].path` | project path | required | .png |  | applied |  |
| `assets.images[].width` | integer | required | [1, 8192] | px | applied |  |
| `assets.images[].height` | integer | required | [1, 8192] | px | applied |  |
| `assets.images[].sha256` | text | "" | <= 64 characters |  | applied | Content hash when the image was registered. "" = not recorded. |
| `animations.clips` | list of object | [] | <= 128 items |  | applied |  |
| `animations.clips[].id` | id | required |  |  | applied |  |
| `animations.clips[].display_name` | text | "" | <= 120 characters |  | editor |  |
| `animations.clips[].fps` | number | 10 | [0.1, 120] | frames/s | applied | SpriteFrames animation speed. |
| `animations.clips[].loop` | boolean | false |  |  | applied |  |
| `animations.clips[].on_finish` | choice | hold_last_frame | hold_last_frame \| return_to_locomotion |  | planned |  |
| `animations.clips[].priority` | integer | 0 | [0, 100] |  | planned |  |
| `animations.clips[].frames` | list of object | [] | <= 256 items |  | applied |  |
| `animations.clips[].frames[].image` | id | required |  |  | applied |  |
| `animations.clips[].frames[].rect` | [integer, integer, integer, integer] or null | null | each [0, 8192] | px | applied | [x, y, w, h] inside the image. null = the whole image. |
| `animations.clips[].frames[].duration` | number | 1 | [0.01, 100] | x | applied | SpriteFrames relative duration. Seconds = duration / fps. |
| `animations.clips[].frames[].offset` | [number, number] | [0, 0] | each [-4096, 4096] | px | planned |  |
| `presentation.faces_right_by_default` | boolean | true |  |  | applied |  |
| `presentation.visual_scale` | [number, number] | [1, 1] | each (0, 64] | x | applied |  |
| `presentation.visual_offset` | [number, number] | [0, 0] | each [-4096, 4096] | px | applied | Position of the frame centre, in the unscaled visual space. |
| `presentation.airborne_speed` | number | 30 | [1, 400] | px/s | applied |  |
| `presentation.move_speed_threshold` | number | 8 | [0, 400] | px/s | applied |  |
| `presentation.attack_hit_frame` | integer | 0 | [0, 64] | frame | applied | First attack frame that shows the strike. Presentation only. |
| `presentation.roles.idle` | id or "" | "" |  |  | applied |  |
| `presentation.roles.move` | id or "" | "" |  |  | applied |  |
| `presentation.roles.attack` | id or "" | "" |  |  | applied |  |
| `presentation.roles.hurt` | id or "" | "" |  |  | applied |  |
| `presentation.roles.death` | id or "" | "" |  |  | applied |  |
| `presentation.roles.jump_start` | id or "" | "" |  |  | applied |  |
| `presentation.roles.jump` | id or "" | "" |  |  | applied |  |
| `presentation.roles.fall` | id or "" | "" |  |  | applied |  |
| `presentation.roles.land` | id or "" | "" |  |  | applied |  |
| `collision.body.shape` | object by 'type' | required | rectangle \| circle |  | contract | Collision shape. capsule, polygon and composite are reserved and rejected in V1. |
| `collision.body.layer` | integer | 1 | [0, 4294967295] |  | contract |  |
| `collision.body.mask` | integer | 1 | [0, 4294967295] |  | contract |  |
| `collision.hurtboxes` | list of object | [] | <= 16 items |  | contract | Default hurtbox set (layer 2 / mask 4). |
| `collision.hurtboxes[].id` | id | required |  |  | contract |  |
| `collision.hurtboxes[].shape` | object by 'type' | required | rectangle \| circle |  | contract | Collision shape. capsule, polygon and composite are reserved and rejected in V1. |
| `collision.hurtboxes[].enabled` | boolean | true |  |  | contract |  |
| `collision.hurtbox_overrides` | list of object | [] | <= 512 items |  | planned |  |
| `collision.hurtbox_overrides[].clip` | id | required |  |  | planned |  |
| `collision.hurtbox_overrides[].frame` | integer or null | null | [0, 255] |  | planned | null = every frame of the clip. |
| `collision.hurtbox_overrides[].boxes` | list of object | required | <= 16 items |  | planned | Replaces the whole set. [] = no hurtbox at all. |
| `collision.hurtbox_overrides[].boxes[].id` | id | required |  |  | planned |  |
| `collision.hurtbox_overrides[].boxes[].shape` | object by 'type' | required | rectangle \| circle |  | planned | Collision shape. capsule, polygon and composite are reserved and rejected in V1. |
| `collision.hurtbox_overrides[].boxes[].enabled` | boolean | true |  |  | planned |  |
| `collision.hitboxes` | list of object | [] | <= 64 items |  | planned | Hitbox shapes (layer 4 / mask 2) armed by EnableHitbox events. |
| `collision.hitboxes[].id` | id | required |  |  | planned |  |
| `collision.hitboxes[].shape` | object by 'type' | required | rectangle \| circle |  | planned | Collision shape. capsule, polygon and composite are reserved and rejected in V1. |
| `attack_patterns` | list of object | [] | <= 64 items |  | contract |  |
| `attack_patterns[].id` | id | required |  |  | contract |  |
| `attack_patterns[].display_name` | text | "" | <= 120 characters |  | editor |  |
| `attack_patterns[].kind` | choice | melee | melee \| leap |  | contract | projectile is reserved. |
| `attack_patterns[].clip` | id or "" | "" |  |  | contract | Clip shown while the pattern runs. |
| `attack_patterns[].duration` | number | 0.7 | [0.05, 30] | s | contract |  |
| `attack_patterns[].completion.mode` | choice | duration | duration \| duration_and_landed |  | contract |  |
| `attack_patterns[].completion.min_air_seconds` | number | 0.08 | [0, 5] | s | contract |  |
| `attack_patterns[].completion.max_air_seconds` | number | 2.5 | [0.1, 30] | s | contract |  |
| `attack_patterns[].range.min` | number or stat reference | 0 | [0, 4000] | px | contract |  |
| `attack_patterns[].range.max` | number or stat reference | {'stat': 'attack_range', 'scale': 1, 'offset': 0} | [0, 4000] | px | contract |  |
| `attack_patterns[].range.vertical` | number or null | null | [0, 4000] | px | contract | Largest height difference. null = unlimited. |
| `attack_patterns[].cooldown` | number | 0 | [0, 600] | s | contract |  |
| `attack_patterns[].priority` | integer | 0 | [-1000, 1000] |  | contract |  |
| `attack_patterns[].weight` | number | 1 | (0, 1000] |  | contract |  |
| `attack_patterns[].condition` | condition or null | null | leaf \| all \| any \| not |  | planned |  |
| `attack_patterns[].movement_locked` | boolean | true |  |  | contract |  |
| `attack_patterns[].facing_locked` | boolean | true |  |  | contract |  |
| `attack_patterns[].interrupt.on_hurt` | choice | cancel | cancel \| ignore |  | contract |  |
| `attack_patterns[].damage.multiplier` | number | 1 | [0, 100] | x attack_power | contract |  |
| `attack_patterns[].damage.type` | id | physical |  |  | contract |  |
| `attack_patterns[].damage.knockback` | [number, number] | [100, -30] | each [-10000, 10000] | px/s | contract |  |
| `attack_patterns[].damage.hit_policy` | choice | once_per_target | once_per_target \| multi_hit |  | contract |  |
| `attack_patterns[].damage.multi_hit_interval` | number | 0.25 | [0.05, 10] | s | contract |  |
| `attack_patterns[].damage.status_effects` | list of id | [] | <= 8 items |  | planned |  |
| `attack_patterns[].phases` | list of object | [] | <= 32 items |  | contract |  |
| `attack_patterns[].phases[].kind` | choice | required | windup \| active \| recovery |  | contract |  |
| `attack_patterns[].phases[].start` | number | required | [0, 30] | s | contract |  |
| `attack_patterns[].phases[].end` | number | required | [0, 30] | s | contract |  |
| `attack_patterns[].events` | list of object by 'type' | [] | <= 128 items |  | contract |  |
| `behavior.initial_state` | id | idle |  |  | contract |  |
| `behavior.interrupts.hurt.state` | id or "" | hurt |  |  | contract |  |
| `behavior.interrupts.hurt.policy` | choice | always | always \| never |  | contract |  |
| `behavior.interrupts.death.state` | id | dead |  |  | contract |  |
| `behavior.states` | list of state | [] | <= 64 items |  | contract |  |
| `behavior.states[].id` | id | required |  |  | contract |  |
| `behavior.states[].display_name` | text | "" | <= 120 characters |  | editor |  |
| `behavior.states[].module` | text | required | <= 64 characters |  | contract | Registered module ID. Unknown IDs are a validation failure. |
| `behavior.states[].params` | opaque object | {} |  |  | contract | Module parameters. Missing ones take the module default. |
| `behavior.states[].animation.mode` | choice | auto | auto \| clip \| pattern |  | contract | auto = presenter role rules; clip = fixed clip; pattern = the running pattern's clip. |
| `behavior.states[].animation.clip` | id or "" | "" |  |  | contract |  |
| `behavior.states[].snapshot_state` | choice | auto | auto \| IDLE \| MOVING \| ATTACKING \| HURT \| DEAD |  | contract | EnemyRuntimeSnapshot.State replicated in this state. auto = the module's own. |
| `behavior.states[].max_seconds` | number or null | null | [0.05, 3600] | s | contract | Raises ActionFailed when exceeded. null = no limit. |
| `behavior.states[].interruptible` | boolean | true |  |  | planned | false = the hurt interrupt is ignored in this state. |
| `behavior.states[].transitions` | list of object | [] | <= 32 items |  | contract |  |
| `behavior.states[].transitions[].to` | id | required |  |  | contract |  |
| `behavior.states[].transitions[].priority` | integer | 0 | [-1000, 1000] |  | contract | Higher is evaluated first; ties keep document order. |
| `behavior.states[].transitions[].condition` | condition | required | leaf \| all \| any \| not |  | contract | Transition condition. |
| `behavior.phases` | list of object | [] | <= 16 items |  | planned |  |
| `behavior.phases[].id` | id | required |  |  | planned |  |
| `behavior.phases[].health_ratio_below` | number | required | [0, 1] | ratio | planned |  |
| `behavior.phases[].enter_state` | id or "" | "" |  |  | planned |  |
| `behavior.phases[].pattern_weights` | map of id to number | {} |  |  | planned |  |
| `loot.loot_table_id` | id or "" | "" |  |  | applied |  |
| `loot.entries` | list of object or null | null | <= 64 items |  | applied | LootTableDefinition rows. null = the table is not managed by this document. |
| `loot.entries[].item_id` | id | required |  |  | applied |  |
| `loot.entries[].weight` | number | required | (0, 1000000] |  | applied |  |
| `loot.entries[].min_amount` | integer | 1 | [1, 9999] |  | applied |  |
| `loot.entries[].max_amount` | integer | 1 | [1, 9999] |  | applied |  |
| `loot.apply_difficulty_multiplier` | boolean | true |  |  | applied |  |
| `source_binding` | object or null | null |  |  | editor | null = draft that was never published. Otherwise the Godot resources it mirrors. |
| `editor_metadata.notes` | text | "" | <= 4000 characters |  | editor |  |
| `editor_metadata.estimated` | list of text | [] | <= 512 items |  | editor | Paths whose values are guesses, not measured game values. |
| `editor_metadata.ui` | opaque object | {} |  |  | editor |  |
<!-- /generated:fields -->

보충:

- **`monster_id`와 표시 이름은 분리된다.** 맵의 스폰은 `monster_id`만 참조하므로 이름을 바꿔도 맵이 깨지지 않는다.
- **`stats`의 여섯 값은 `EnemyDefinition`과 1:1이다.** 난이도 배율(`enemy_health_multiplier`,
  `enemy_damage_multiplier`)은 런타임이 항상 곱한다. 이동 유형별 속도는 stat이 아니라 모듈의 `speed_scale`이다.
- **Quantity.** "number or stat reference" 타입은 숫자이거나 `{"stat": "chase_range", "scale": 1.35, "offset": 0}`
  (= stat × scale + offset)이다. 기존 코드의 `chase_range * 1.35` 같은 식을 숫자로 굳히지 않기 위한 것이다.
- **애니메이션 frame은 항상 명시적이다.** sprite sheet든 개별 PNG든 문서에는 frame마다 `image`와 `rect`가 저장된다
  (`rect: null`은 이미지 전체). 격자 정보는 저장하지 않는다 — `slice_grid`가 frame 목록을 만든다.
  frame 시간은 Godot `SpriteFrames`와 같다: `duration / fps` 초.
- **AI 상태와 clip은 분리된다.** `presentation.roles`가 역할(idle, move, attack…)에 clip을 연결하고, 상태의
  `animation.mode`가 `auto`(presenter의 역할 규칙), `clip`(고정 clip), `pattern`(실행 중인 공격 패턴의 clip) 중
  하나를 고른다. 한 상태가 여러 clip을 쓸 수 있고(Hop 모듈: jump_start → jump → fall → land), 필요 없는 clip을
  강제하지 않는다. 모듈별 필수·선택 역할은 §6 표에 있다.
- **`source_binding: null`은 초안이다.** 게시된 적이 없다는 뜻이고, 그런 문서의 `monster_id`가 이미 게임에 있으면
  실패다.

## 5. Collision

<!-- generated:shapes -->
| Shape | Fields |
|---|---|
| `rectangle` | `center` [number, number] = [0, 0] each [-4096, 4096] px<br>`size` [number, number] each (0, 4096] px |
| `circle` | `center` [number, number] = [0, 0] each [-4096, 4096] px<br>`radius` number (0, 2048] px |
<!-- /generated:shapes -->

`capsule`, `polygon`, `composite`는 예약어이며 V1은 읽기 단계에서 거절한다.

| 판정 | 필드 | 규칙 |
|---|---|---|
| Body | `collision.body` | 지형 충돌. 고정. 애니메이션 frame에 따라 바뀌지 않는다. layer/mask 1/1 |
| Hurtbox | `collision.hurtboxes` + `hurtbox_overrides` | 맞는 영역. layer 2 / mask 4. 여러 개 가능 |
| Hitbox | `collision.hitboxes` | 때리는 영역. layer 4 / mask 2. 공격 패턴의 `EnableHitbox`로만 켜진다 |

**적용 우선순위** (아래가 위를 덮는다):

```text
collision.hurtboxes (기본)
  → hurtbox_overrides[clip, frame = null]   clip 전체
  → hurtbox_overrides[clip, frame = n]      특정 frame
  → 공격 패턴 / 런타임 (EnableInvulnerability 등)
```

override는 병합이 아니라 **전체 교체**다. 해당 항목이 없으면 상속이고, `boxes: []`는 "판정 없음"을 명시한 것이다.
둘은 다른 문서로 저장되고 비교된다. override가 가리키는 "현재 frame"은 서버가 렌더링 없이 계산한다 — clip의
frame 지속 시간과 상태 경과 시간만 쓴다([runtime contract §5](monster_editor_runtime_contract.md)).

## 6. Action Module

<!-- generated:modules -->
| Module | Category | Parameters | Completes | Can fail | Replicated state | Clip roles | Legacy equivalent | Support |
|---|---|---|---|---|---|---|---|---|
| `Wait` | movement | `seconds` number = 1 [0, 600] s | yes | no | IDLE | idle | IdleState (1.0 s), FrogIdleState.wait_seconds | contract |
| `GroundPatrol` | movement | `radius` number = 90 [8, 4000] px<br>`speed_scale` number = 0.55 [0.05, 10] x move_speed | no | no | MOVING | move | PatrolState | contract |
| `ChaseTarget` | movement | `speed_scale` number = 1 [0.05, 10] x move_speed | no | no | MOVING | move | ChaseState | contract |
| `FaceTarget` | movement | `seconds` number = 0.35 [0, 60] s | yes | no | IDLE | idle | FrogAlertState | contract |
| `Hop` | movement | `toward` choice = patrol patrol \| target \| origin<br>`count` integer = 0 [0, 100] hops<br>`interval_seconds` number = 0.8 [0, 60] s<br>`prepare_seconds` number = 0.18 [0.05, 5] s<br>`speed_scale` number = 1 [0.05, 10] x move_speed<br>`lift` number = 230 [50, 2000] px/s<br>`patrol_radius` number = 130 [16, 4000] px<br>`max_drop` number = 56 [4, 2000] px<br>`max_air_seconds` number = 2.5 [0.5, 30] s<br>`stuck_seconds` number = 2.5 [0, 60] s<br>`min_progress` number = 6 [0, 1000] px<br>`arrive_distance` number = 28 [1, 1000] px<br>`rehome_on_stuck` boolean = false<br>`hold_in_attack_range` boolean = false | yes | yes | dynamic | idle (optional: jump_start, jump, fall, land) | FrogPatrolState / FrogChaseState / FrogReturnState with FrogPrepareState and FrogHopState | contract |
| `ReturnToOrigin` | movement | `speed_scale` number = 1 [0.05, 10] x move_speed<br>`arrive_distance` number = 16 [1, 1000] px | yes | no | MOVING | move | – | planned |
| `ExecuteAttackPattern` | combat | `pattern` id or "" = "" | yes | yes | ATTACKING | – | AttackState, FrogAttackState | contract |
| `HurtReaction` | combat | `seconds` number = 0.25 [0, 10] s | yes | no | HURT | hurt | HurtState (0.25 s) | contract |
| `Death` | combat | `removal_seconds` number = 0.45 [0.05, 60] s | no | no | DEAD | death | DeadState.removal_seconds | contract |

Reserved module IDs (rejected by validation until they get a contract): `Walk`, `Run`, `Dash`, `Jump`, `Flee`, `Fly`, `SelectAttack`, `Guard`, `Dodge`, `Recover`, `Alert`, `Summon`, `ApplyBuff`, `Enrage`, `TemporaryInvulnerability`.
<!-- /generated:modules -->

- **Completes**: 모듈이 끝나면 `ActionCompleted`가 한 번 참이 된다. `Hop`은 `count = 0`이고 `toward`가 `origin`이
  아니면 끝나지 않는다.
- **Can fail**: `ActionFailed`를 낼 수 있다. 상태에 `max_seconds`가 있으면 어떤 모듈이든 초과 시 `ActionFailed`.
- **Replicated state**: 그 상태에서 `EnemyRuntimeSnapshot.State`로 복제되는 값. `dynamic`은 모듈이 tick마다 정한다
  (`Hop`: 대기 중 `IDLE`, 웅크림·비행 중 `MOVING`). 상태의 `snapshot_state`로 덮어쓸 수 있다.
- 모든 모듈은 서버 권위로만 실행된다. 클라이언트는 모듈을 실행하지 않는다.

## 7. Transition Condition

조건은 leaf(`{"type": ...}`)이거나 `{"all": [...]}`, `{"any": [...]}`, `{"not": {...}}` 조합이다(1~16개, 깊이 8).

<!-- generated:conditions -->
| Condition | Parameters | Meaning | Legacy equivalent | Support |
|---|---|---|---|---|
| `Always` | – | Unconditional. | timer-less fallthrough | contract |
| `HasTarget` | – | A valid living player in the same world is selected. | EnemyAgent._valid_target | contract |
| `LostTarget` | – | No valid target is selected. | EnemyAgent._valid_target | contract |
| `TargetDistance` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 1000000] px | Distance between actor and target origins. Infinite without a target. | EnemyAgent.distance_to_player | contract |
| `TargetVerticalDistance` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 1000000] px | Absolute height difference to the target. | FrogAgent.attack_vertical_reach | contract |
| `TargetOriginDistance` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 1000000] px | Horizontal distance between the target and the spawn origin. | FrogAgent.target_inside_leash | contract |
| `DistanceFromOrigin` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 1000000] px | Horizontal distance between the actor and the spawn origin. | FrogAgent.distance_from_origin | contract |
| `StateElapsedTime` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 3600] s | Time since the state was entered. | state timers | contract |
| `ActionCompleted` | – | The state's module finished. | timer expiry / landing | contract |
| `ActionFailed` | – | The state's module gave up. | stuck clock | contract |
| `AttackPatternCompleted` | – | The running attack pattern finished. | AttackState end | contract |
| `AttackCooldownReady` | `pattern` id or "" = "" | The pattern's cooldown is over. "" = any pattern. | FrogAgent.attack_cooldown_remaining | contract |
| `AttackAvailable` | `pattern` id or "" = "" | A pattern is in range, off cooldown and allowed. "" = any pattern. | ChaseState / FrogChaseState attack test | contract |
| `IsGrounded` | – | Touched the floor within the grounded grace time. | FrogAgent.is_grounded | contract |
| `IsAirborne` | – | Not grounded. | FrogAgent.is_grounded | contract |
| `HealthRatio` | `op` choice < \| <= \| > \| >=<br>`value` number or stat reference [0, 1] ratio | Current health divided by maximum health. | – | planned |
| `ObstacleAhead` | `distance` number = 24 [1, 2000] px | A wall blocks the facing direction within the distance. | – | planned |
| `EdgeAhead` | `distance` number = 24 [1, 2000] px<br>`max_drop` number = 56 [4, 2000] px | The ground ahead drops further than max_drop. | – | planned |
| `ReceivedDamage` | – | Damage was taken during this tick. | – | planned |
| `IsDead` | – | Health reached zero. | – | planned |
| `RandomChance` | `per_second` number = 0.5 [0, 60] 1/s | True with this probability per second, drawn from the server RNG. | – | planned |
<!-- /generated:conditions -->

평가 규칙은 [runtime contract §3](monster_editor_runtime_contract.md)에 있다: `priority` 내림차순, 같으면 문서
순서, 처음 참인 전환 하나만, tick당 전환 한 번.

## 8. 공격 패턴과 타임라인 이벤트

패턴은 AI 상태와 독립적이다. `ExecuteAttackPattern` 상태가 패턴을 지정하거나(`pattern: "id"`), 비워 두면 선택기가
고른다.

- `phases`는 0에서 시작해 `duration`까지 빈틈없이 이어져야 한다. `windup` → `active` → `recovery`가 기본이고
  `active`가 여러 번 나올 수 있다(다단 공격).
- 이벤트의 `time`은 패턴 시작부터의 **초**다. frame 번호가 아니다. clip의 FPS를 바꿔도 이벤트 시간은 바뀌지 않는다.
- `EnableHitbox`~`DisableHitbox` 구간은 하나의 `active` phase 안에 있어야 한다. `DisableHitbox`가 없으면 패턴이
  끝날 때(중단 포함) 꺼진다.
- `RangeStrike`는 기존 몬스터의 "거리 1회 판정"이다. `active` phase 안이거나 `windup`이 끝나는 바로 그 시각에만 둘
  수 있다.
- `completion.mode = duration_and_landed`는 `duration`이 지나고 **착지까지** 한 뒤 끝난다(개구리 도약).

<!-- generated:events -->
| Event | Side | Parameters | Meaning | Legacy equivalent | Support |
|---|---|---|---|---|---|
| `RangeStrike` | gameplay | `reach` number or stat reference [0, 4000] px<br>`slack` number = 12 [0, 1000] px | Instant hit on the current target if it is within reach + slack. No hitbox. Allowed inside an active phase or exactly where a windup ends. | EnemyAgent.perform_attack | contract |
| `EnableHitbox` | gameplay | `hitbox` id | Arm a hitbox from collision.hitboxes until DisableHitbox or the pattern ends. | – | planned |
| `DisableHitbox` | gameplay | `hitbox` id | Disarm a hitbox. | – | planned |
| `ApplyImpulse` | gameplay | `velocity` [number, number] = [0, 0] each [-10000, 10000] px/s<br>`x_scales_move_speed` boolean = false<br>`mode` choice = set set \| add<br>`requires_grounded` boolean = true | Change the velocity once. x points forward and is mirrored by facing. | FrogAttackState leap | contract |
| `ApplyMovement` | gameplay | `speed_scale` number = 1 [-10, 10] x move_speed<br>`seconds` number = 0.2 [0, 30] s | Hold a forward speed for a time. | – | planned |
| `LockFacing` | gameplay | – | Stop turning toward the target. | – | planned |
| `UnlockFacing` | gameplay | – | Resume turning toward the target. | – | planned |
| `SpawnProjectile` | gameplay | `projectile_id` id | Spawn a registered projectile. | – | planned |
| `ApplyStatusEffect` | gameplay | `effect_id` id<br>`target` choice = target target \| self | Apply a registered EffectDefinition. | – | planned |
| `EnableInvulnerability` | gameplay | – | Ignore evadable damage. | – | planned |
| `DisableInvulnerability` | gameplay | – | Take damage again. | – | planned |
| `CompleteAttack` | gameplay | – | End the pattern early. | – | planned |
| `PlayAnimation` | presentation | `clip` id | Switch the clip shown for this pattern. | – | planned |
| `SpawnEffect` | presentation | `effect_id` id | Show a registered visual effect. | – | planned |
| `PlaySound` | presentation | `sound_id` id | Play a registered sound. | – | planned |
<!-- /generated:events -->

`gameplay` 이벤트는 권위 런타임만 실행한다. `presentation` 이벤트는 피해·물리·상태를 바꿀 수 없다.

## 9. 검증 규칙

`validate(document, project=None, tick_rate=60)`가 내는 finding 코드다. 읽기 단계에서 거절되는 모양 오류는 모두
`schema` 영역의 `unreadable_document` 하나로 보고된다(`validate_payload`).

| 영역 | FAIL | WARNING | NOT_EVALUATED |
|---|---|---|---|
| schema | `unreadable_document`, `out_of_range`(collision·attack·ai·animation 경로는 해당 영역으로 보고), `loot_amount_order`, `loot_table_id_missing` | | |
| references | `duplicate_image_id`, `duplicate_animation_id`, `duplicate_hurtbox_id`, `duplicate_hitbox_id`, `duplicate_pattern_id`, `duplicate_state_id`, `duplicate_phase_id`, `duplicate_hurtbox_override`, `unknown_image`, `unknown_animation`, `unknown_hitbox`, `unknown_pattern`, `unknown_state`, `frame_out_of_range`, `duplicate_monster_id`, `binding_id_mismatch`, `unknown_loot_table`, `unknown_item` | | `monster_id_uniqueness_unchecked`, `loot_reference_unchecked` |
| assets | `asset_missing`, `asset_invalid`, `asset_size_mismatch`, `invalid_hash` | `asset_changed`, `duplicate_image_path` | `asset_files_unchecked` |
| animation | `clip_without_frames`, `source_rect_empty`, `source_rect_outside_image`, `required_role_missing`, `held_role_must_loop`, `one_shot_role_must_not_loop`, `attack_hit_frame_out_of_range` | `no_animation`, `mixed_frame_sizes`, `clip_longer_than_gameplay`, `hit_frame_mismatch` | |
| collision | (shape의 `out_of_range`) | `no_enabled_hurtbox`, `nonstandard_body_layer`, `unused_hitbox` | |
| attack | `phases_missing`, `phase_ends_before_it_starts`, `phases_not_contiguous`, `phases_do_not_fill_duration`, `event_after_pattern_end`, `strike_outside_active_phase`, `hitbox_already_enabled`, `hitbox_disabled_before_enabled`, `hitbox_outside_active_phase`, `window_shorter_than_one_tick`, `multi_hit_interval_below_one_tick`, `range_order` | `no_active_phase`, `pattern_without_hit`, `multi_hit_without_hitbox`, `landing_without_impulse` | |
| ai | `no_states`, `initial_state_missing`, `unknown_module`, `module_not_available`, `state_never_exits`, `immediate_transition_cycle`, `death_state_not_terminal`, `hurt_state_missing`, `no_attack_patterns` | `transition_shadowed`, `transition_never_fires`, `completion_unhandled`, `unreachable_state`, `hurt_state_without_hurt_reaction` | |
| compatibility | `source_missing`, `invalid_hash` | `value_not_applied_by_any_runtime`, `planned_module`, `planned_condition`, `planned_event`, `source_changed` | `source_files_unchecked` |
| runtime | | | `godot_runtime_not_run` (항상) |
| network | | | `network_replication_not_run` (항상) |
| publish | `export_blocked_unsupported`, `publish_blocked_by_failures` | | `publish_not_implemented` (항상) |

몇 가지 규칙의 정확한 뜻:

- **`state_never_exits`** — terminal이 아닌 상태에 발동 가능한 전환이 하나도 없다. 모듈이 끝나지 않는데
  `ActionCompleted`만 기다리는 경우도 포함한다.
- **`immediate_transition_cycle`** — `Always`(와 그 조합)만으로 이루어진 전환 고리. tick당 전환이 한 번이라 무한
  루프는 아니지만 몬스터가 아무것도 하지 못한다.
- **`transition_shadowed`** — 더 먼저 평가되는 무조건 전환 때문에 절대 선택되지 않는 전환.
- **`window_shorter_than_one_tick`** — phase나 hitbox 구간이 주어진 tick rate에서 physics tick을 하나도 포함하지
  않는다. 60 Hz에서 `0.201~0.209초`가 그렇다.
- **`hit_frame_mismatch`** — `attack_hit_frame`이 보이는 시각과 패턴의 첫 gameplay 이벤트 시각이 반 tick 넘게
  다르다. 판정은 바뀌지 않는다. 그림이 안 맞을 뿐이다.
- **`duplicate_monster_id`** — 초안의 ID가 게임에 이미 있는 `EnemyDefinition`과 같다. 여러 문서 사이의 중복은
  `duplicate_monster_ids([...])`가 검사한다.
- **정적으로 확정할 수 없는 것은 단정하지 않는다.** 프로젝트 폴더가 없으면 파일 관련 검사는 `NOT_EVALUATED`다.

## 10. 예제

`tools/python_monster_editor/examples/`:

| 문서 | 성격 | 정적 검증 (프로젝트 포함) |
|---|---|---|
| `sewer_beetle.rtcmonster` | 실제 게임 값. legacy 런타임에 binding | 8개 정적 영역 전부 PASS |
| `frog.rtcmonster` | 실제 게임 값. V1로 정확히 표현되지 않는 두 항목이 `source_binding.unsupported`에 있다 | 정적 FAIL 없음, compatibility WARNING(hitbox는 `planned`), publish FAIL(미지원 2건) |
| `sewer_rat_prototype.rtcmonster` | **추정값으로 만든 fixture.** 게임 콘텐츠가 아니다. `editor_metadata.estimated`에 추정 구간 표시 | 정적 FAIL 없음, animation WARNING(아트 없음), compatibility WARNING(`planned` 이벤트) |

가장 작은 유효 문서는 `new_document(monster_id, display_name)`가 만든다: 서 있고, 맞을 수 있고, 죽을 수 있다.

```json
{
  "schema_version": 1,
  "document_type": "rtcmonster",
  "monster_id": "moss_slug",
  "metadata": {"display_name": "Moss Slug"},
  "collision": {
    "body": {"shape": {"type": "rectangle", "center": [0, 0], "size": [32, 22]}},
    "hurtboxes": [{"id": "body", "shape": {"type": "rectangle", "center": [0, 0], "size": [38, 28]}}]
  },
  "behavior": {
    "initial_state": "idle",
    "states": [
      {"id": "idle", "module": "Wait",
       "transitions": [{"to": "idle", "condition": {"type": "ActionCompleted"}}]},
      {"id": "hurt", "module": "HurtReaction",
       "transitions": [{"to": "idle", "condition": {"type": "ActionCompleted"}}]},
      {"id": "dead", "module": "Death"}
    ]
  }
}
```

생략한 필드는 기본값으로 채워지고, 저장하면 모든 필드가 정규 순서로 기록된다.
