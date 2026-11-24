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

임시 아트는 저장소 밖 스크립트로 그린 도형이다. 프레임마다 실제로 다른 그림이지만 완성
아트가 아니며, 정식 스프라이트로 교체해야 한다. 교체 규격은 아래 명세를 따른다.

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
  대상이 `attack_vertical_reach`보다 위나 아래에 있으면 공격하지 않고 hop으로 접근한다.
- **타깃 결정은 서버다.** 기존 `EnemyAgent._select_target()`(가장 가까운 유효 플레이어)을 쓴다.
- **복제는 기존 snapshot 그대로다.** `EnemyState.snapshot_state()`로 상태별 매핑만 지정한다:
  대기 상태(idle/patrol/alert/chase/return)는 `IDLE`, `prepare`/`hop`은 `MOVING`. payload와
  `NetworkProtocol.VERSION`은 바뀌지 않는다. 복제 actor는 "`MOVING`인데 지상에 멈춰 있음"을
  웅크림(`jump_start`)으로 그린다.
- **알려진 한계:** 공중에서 죽으면 제거될 때까지(0.45초) 그 자리에 멈춘다. 도약이 플레이어
  머리 위에 착지할 수 있다. 복잡한 경로 탐색은 없다.

## 스프라이트 제작 명세 (정식 아트 교체용)

| 항목 | 규격 |
|---|---|
| 형식 | PNG RGBA32, 투명 배경, clip당 가로 strip 1장 (`<clip>.png`) |
| frame 크기 | 딱정벌레 64×48, 개구리 64×64. 한 Enemy 안에서는 모든 clip이 같은 크기 |
| 방향 | 오른쪽을 본다 (`faces_right_by_default = true`) |
| 앵커 | 바닥 중앙. 발이 frame 아래쪽 1~2px 위 같은 줄에 닿는다 |
| 여백 | 도약·혀·더듬이가 잘리지 않도록 사방 4px 이상 |
| 필터 | nearest (픽셀 아트 기준) |
| 위치 | `assets/characters/enemies/<enemy_id>/`, `sprite_frames.tres`가 strip을 `AtlasTexture`로 자른다 |

| clip | loop | 현재 fps × frame | 지켜야 할 타이밍 |
|---|---|---|---|
| idle | O | 5 × 4 | 없음 |
| move (딱정벌레) | O | 12 × 6 | 없음 |
| jump_start (개구리) | X | 12 × 2 | `prepare_seconds` 0.18초 안에 끝난다 |
| jump / fall (개구리) | O | 8 × 2 | 없음 (상승/하강 자세) |
| land (개구리) | X | 12 × 2 | 약 0.16초 |
| attack | X | 10 × 7(딱정벌레) / 10 × 6(개구리) | `attack_hit_frame`(현재 2)이 0.2초에 시작해야 한다. 전체는 공격 상태 길이(0.7 / 0.6초) 이하 |
| hurt | X | 12 × 3 | hurt 상태 0.25초 |
| death | X | 12 × 5 | 0.45초(제거 시점) 안에 끝나고 마지막 frame이 최종 자세 |

frame 수나 fps를 바꾸면 `sprite_frames.tres`와 profile의 `attack_hit_frame`을 함께 고친다.
크기가 달라지면 profile의 `visual_offset`/`visual_scale`로 맞춘다 — 충돌체는 고치지 않는다.
