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
- **clip 우선순위:** `death > hurt > attack > prepare(jump_start) > 공중(jump/fall) > land > move/idle`.
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

임시 아트는 저장소 밖 스크립트로 그린 도형이다. 프레임마다 실제로 다른 그림이지만 완성
아트가 아니며, 정식 스프라이트로 교체해야 한다.
