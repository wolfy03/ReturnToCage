# Enemy 애니메이션

Enemy 표현은 player pipeline(manifest → builder)을 쓰지 않는 별도의 가벼운 구조다.
AI·판정·물리는 그대로이고, 표현은 이미 있는 상태를 읽기만 한다.

```
EnemyAgent.animation_profile_path (문자열 경로)
  └─ EnemyAnimationProfile (.tres, presentation/enemy/profiles/)
       └─ SpriteFrames (assets/characters/enemies/<id>/sprite_frames.tres)
            └─ EnemyAnimationPresenter → AnimatedSprite2D
```

- **경로는 문자열이다.** actor scene은 `EnemyDefinition.actor_scene`으로 `ContentRegistry`가
  미리 로드하므로, scene이 profile을 직접 참조하면 headless 서버까지 텍스처가 따라 들어간다.
- **서버 런타임 actor는 visual을 만들지 않는다.** `EnemySpawnManager`가
  `setup_enemy(..., presentation_enabled = not authoritative_runtime)`로 넘긴다.
- **presenter는 읽기만 한다.** `current_state_id`, `velocity`, `facing`, `health`만 본다.
  권위 actor와 복제된 actor가 같은 규칙을 쓰므로 표현을 위한 추가 네트워크 데이터가 없다.
- **clip 우선순위:** `death > hurt > attack > 공중(jump/fall) > land > prepare(jump_start) > move/idle`.
  같은 clip은 다시 `play()`하지 않는다. death는 한 번만 재생되고 이후 교체되지 않는다.
  같은 hurt 상태에서 다시 맞으면 체력 감소를 계기로 hurt만 다시 시작한다.
- **공중 판정은 수직 속도다.** 복제 actor는 물리를 돌리지 않으므로 `is_on_floor()`를 쓰지 않는다.
  정점에서 속도가 0을 지나는 순간은 짧은 확인 시간으로 가린다.
- **좌우 반전은 presenter child의 scale 부호뿐이다.** actor root·충돌체·hurtbox는 건드리지 않는다.
- **타이밍의 소유자는 상태 노드다.** `States/Attack`의 `duration_seconds`/`recovery_seconds`,
  `States/Dead`의 `removal_seconds`가 gameplay 값이고, profile의 `attack_hit_frame`은 그에 맞춘
  표현 값이다. `tests/unit/test_enemy_animation.gd`가 둘이 어긋나면 실패한다. 아트가 안 맞으면
  clip을 고친다 — 상태 시간을 고치지 않는다.

## 현재 에셋 상태

| Enemy | clip | 상태 |
|---|---|---|
| `sewer_beetle` | idle 4f / move 6f / attack 7f / hurt 3f / death 5f, 64×48 | **임시 프로그래머 아트** |
| `frog` | idle 4f / jump_start 2f / jump 2f / fall 2f / land 2f / attack 6f / hurt 3f / death 5f, 64×64 | **임시 프로그래머 아트** |

저장소에 있는 딱정벌레·개구리 sheet는 **전부 임시**다. 저장소 밖 스크립트로 그린 저해상도 도형이고,
프레임마다 실제로 다른 그림이긴 하지만 정식 아트가 아니다. 정식 아트는 아직 한 장도 없다.
임시 sheet는 정식 아트가 들어올 때까지 그대로 두며, 아래 "정식 아트 제작 명세"는 교체할 그림의 규격이다
— 지금 파일의 규격이 아니다.

## 개구리 (`frog`) AI

`FrogAgent`(`EnemyAgent` 상속)와 `gameplay/actors/enemies/frog/`의 상태 노드로 구성한다.
개구리는 **hop으로만 이동한다.**

```
idle ─▶ patrol ─▶ (prepare ─▶ hop ─▶ patrol …) ─▶ idle
  └────────── 탐지 ──▶ alert ─▶ chase ─▶ (prepare ─▶ hop ─▶ chase …)
                                  ├─ 사거리 + 쿨다운 ──▶ attack ─▶ chase
                                  └─ 대상 상실/leash/막힘 ──▶ return ─▶ idle
피격 ─▶ hurt ─▶ chase        체력 0 ─▶ dead
```

- **공중 점프가 구조적으로 없다.** 발사는 `prepare`가 접지 상태에서 한 번만 한다. `hop`은
  착지를 기다릴 뿐 속도를 다시 주지 않는다. 웅크린 동안 공중에 뜨면 발사를 취소한다.
- **가장자리·벽 감지:** `FrogAgent.can_hop_toward()`가 착지 예상 지점 아래로 ray를 쏴
  `max_drop`보다 깊으면 hop하지 않는다. patrol은 방향을 바꾸고, chase/return은 `stuck_seconds`
  뒤에 포기한다. return이 막히면 현재 위치를 새 patrol 원점으로 삼아 무한 대기를 막는다.
- **추적 한계:** 대상이 사라지거나 `chase_range × 1.35` 밖이거나 `leash_distance`를 넘으면 return.
- **공격:** 0.2초 웅크린 뒤 짧게 도약한다. 도약 한 번에 `perform_attack()`은 최대 1회이고
  기존 권위·사거리 검사를 그대로 쓴다. `attack_cooldown_seconds`가 다음 공격을 막는다.
  쿨다운은 도약하는 순간 시작하고 공격이 끝날 때 다시 시작한다 — 피격으로 끊긴 도약도 쿨다운을 남긴다.
  대상이 `attack_vertical_reach`보다 위나 아래에 있으면 공격하지 않고 hop으로 접근한다.
- **타깃 결정은 서버다.** 기존 `EnemyAgent._select_target()`(가장 가까운 유효 플레이어)을 쓴다.
- **복제는 기존 snapshot 그대로다.** `EnemyState.snapshot_state()`로 상태별 매핑만 지정한다:
  대기 상태(idle/patrol/alert/chase/return)는 `IDLE`, `prepare`/`hop`은 `MOVING`. payload와
  `NetworkProtocol.VERSION`은 바뀌지 않는다. 복제 actor는 "`MOVING`인데 지상에 멈춰 있음"을
  웅크림(`jump_start`)으로 그린다.
- **알려진 한계:** 공중에서 죽으면 제거될 때까지(0.45초) 그 자리에 멈춘다. 도약이 플레이어
  머리 위에 착지할 수 있다. 복잡한 경로 탐색은 없다.

## 정식 아트 제작 명세

ReturnToCage의 정식 아트는 픽셀 아트가 아니라 **손그림 기반 2D 횡스크롤 RPG**(메이플스토리풍: 굵고 정리된
외곽선, 단순한 면 채색, 과장된 실루엣과 큰 눈) 스타일이다. Enemy도 주인공 햄스터와 같은 해상도·같은
선 굵기·같은 채색 밀도로 그려 한 화면에서 스타일이 섞이지 않게 한다.

### 캔버스

| 항목 | 규격 |
|---|---|
| 형식 | PNG RGBA32, 투명 배경(premultiply 하지 않은 straight alpha), clip당 가로 strip 1장 (`<clip>.png`) |
| frame 크기 | **256×256**. 한 Enemy의 모든 clip이 같은 크기를 쓴다 |
| 안전 여백 | **사방 50px**. 몸·더듬이·혀·이펙트가 가운데 156×156 안에 들어온다 |
| 예외 | 도약·혀 공격처럼 156px에 안 들어가는 Enemy는 그 Enemy의 **모든 clip**을 384×256으로 넓힌다(여백 50px 유지). clip마다 크기를 바꾸지 않는다 |
| 방향 | 오른쪽을 본다 (`faces_right_by_default = true`). 왼쪽은 presenter가 visual child만 뒤집는다 |
| 앵커 | **바닥 중앙.** 발이 닿는 선은 frame 아래에서 50px, 좌우 중심은 frame 가운데다. 모든 frame이 같은 선·같은 중심을 쓴다 |
| 일관성 | frame 사이에 몸 크기·비율·외곽선 굵기·색이 변하지 않는다. 눌림·늘어남은 의도한 자세에서만 쓴다 |
| 위치 | `assets/characters/enemies/<enemy_id>/`, `sprite_frames.tres`가 strip을 `AtlasTexture`로 자른다 |

공중 clip(`jump`/`fall`)도 발 기준선을 유지한 채 그린다. 높이는 물리가 이미 옮기므로 그림에서 몸을
위로 띄우면 두 번 뜬다.

### 화면 크기는 profile이 맞춘다

충돌체와 hurtbox는 아트와 무관하게 고정이다. 그림 크기는 `EnemyAnimationProfile`의 `visual_scale`과
`visual_offset`으로만 맞춘다(visual child에만 적용, actor root·충돌체 금지).

| Enemy | 충돌체 | hurtbox | 화면 목표 크기 | frame 안 그림 크기 (`visual_scale` 0.35 기준) |
|---|---|---|---|---|
| `sewer_beetle` | 34×22 | 40×28 | 약 48×30 | 약 137×86 |
| `frog` | 30×22 | 36×28 | 약 44×36 | 약 126×103 |

- `visual_scale`은 주인공과 같은 **0.35**를 기준으로 한다(같은 화면 픽셀 밀도). 양수여야 한다.
- `visual_offset.y = 충돌체 높이/2 − (frame 높이/2 − 발 여백) × visual_scale`.
  256 frame·50px 여백·scale 0.35·충돌체 높이 22이면 `11 − 78 × 0.35 ≈ −16.3`.
- `visual_offset.x`는 0. 그림의 좌우 중심이 frame 중심에 있어야 좌우 반전에서 몸이 튀지 않는다.
- **Texture filter:** 손그림을 0.35로 줄여 그리므로 profile의 `texture_filter`를
  `TEXTURE_FILTER_LINEAR`(주인공과 동일)로 둔다. 축소에서 선이 깨지면 import의 mipmap을 켜고
  `LINEAR_WITH_MIPMAPS`를 쓴다. `NEAREST`는 지금의 저해상도 임시 sheet 전용이며 profile 기본값이다.

### clip과 타이밍

애니메이션은 gameplay를 표현할 뿐이다. 아래 시간은 **상태 노드가 소유한 gameplay 값**이고, 아트는
여기에 맞춘다. 아트가 안 맞으면 frame 수·fps·`attack_hit_frame`을 고친다 — 상태 시간, AI, 판정은 고치지 않는다.

| clip | loop | 권장 frame × fps | 지켜야 할 것 |
|---|---|---|---|
| idle | O | 6~8 × 8 | 호흡 정도의 작은 움직임 |
| move (딱정벌레) | O | 8 × 12 | 순환이 끊기지 않는 걸음 |
| jump_start (개구리) | X | 3 × 16 | 웅크림. `prepare_seconds` **0.18초** 안에 끝난다 |
| jump / fall (개구리) | O | 2~3 × 8 | 상승 자세 / 하강 자세 |
| land (개구리) | X | 3 × 18 | 착지 반응. 약 **0.16초** |
| attack | X | 딱정벌레 7~8 × 10~12, 개구리 6~8 × 10~14 | 아래 "공격" 참조 |
| hurt | X | 3~4 × 12~16 | hurt 상태 **0.25초** 안에 끝난다 |
| death | X | 5~6 × 12~14 | **0.45초**(제거 시점) 안에 끝나고 마지막 frame이 최종 자세 |

**공격.** 피해 판정 시각은 상태 노드가 정한다: 딱정벌레는 공격 시작 **0.20초**에 타격(전체 0.7초),
개구리는 **0.20초**에 도약을 시작하고 도약 중 접촉한 순간 한 번 타격한다(지상 기준 전체 0.6초).
profile의 `attack_hit_frame`은 "타격이 보이는 첫 frame"이고, 그 frame의 시작 시각
(`attack_hit_frame ÷ fps`)이 0.20초여야 한다. 예: 10fps면 frame 2, 15fps면 frame 3.
`tests/unit/test_enemy_animation.gd`가 이 정합이 어긋나면 실패한다. 준비 동작이 0.20초보다 길어 보여야
한다면 준비 frame의 그림을 과장할 뿐, 0.20초를 늘리지 않는다.

### 교체 절차

1. strip을 `assets/characters/enemies/<enemy_id>/`에 넣고 `sprite_frames.tres`의 region·frame 수·fps·loop를 고친다.
2. profile(`presentation/enemy/profiles/`)의 `visual_scale`/`visual_offset`/`texture_filter`/`attack_hit_frame`을 맞춘다.
3. `sewer_beetle.tscn`·`frog.tscn`의 충돌체, hurtbox, 상태 노드 시간은 건드리지 않는다.
4. `python tools/check_project.py`와 `python tools/test_forest_visual.py`(렌더링, screenshot)를 돌려 확인한다.
5. 이 문서의 "현재 에셋 상태" 표를 정식 아트로 바꾼다. 일부 clip만 정식이면 그 Enemy는 여전히 임시로 적는다.
