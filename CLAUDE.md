# CLAUDE.md — ReturnToCage 작업 규칙

Godot **4.7.2** 2D 횡스크롤 생존 RPG. 싱글 + 호스트 권위 멀티플레이(최대 4인).
이 파일은 이 저장소에서 작업할 때 **먼저 읽고 지켜야 할 규칙**이다. 구조 설명은
[docs/codebase_map.md](docs/codebase_map.md), 설계 의도는 `docs/` 의 기존 문서를 따른다.

## 0. 시작 전 확인

1. `.godot-version` = `4.7.2`, `project.godot` 의 `config/features` 에 `"4.7"`. 둘이
   어긋나면 `tools/check_project.py` 가 즉시 실패한다. 엔진 버전은 임의로 올리지 않는다.
2. 변경 전후로 아래를 돌린다. 실패한 상태로 커밋하지 않는다.

```sh
python tools/check_project.py --godot <godot 4.7.2 실행 파일>
```

3. 멀티플레이에 영향을 주는 변경이면 프로세스 분리 E2E까지 돌린다(순차 실행. 동시에
   돌리면 재시작 프로브가 불안정해진다).

```sh
python tools/test_multiplayer_restart.py      --godot <godot> --players 2 --scenario valid
python tools/test_multiplayer_restart.py      --godot <godot> --players 2 --scenario invalid
python tools/test_multiplayer_restart.py      --godot <godot> --players 3 --scenario valid
python tools/test_multiplayer_worlds.py       --godot <godot> --players 2
python tools/test_multiplayer_worlds.py       --godot <godot> --players 3
python tools/test_multiplayer_world_runtime.py --godot <godot> --players 2
python tools/test_multiplayer_world_runtime.py --godot <godot> --players 3
```

## 1. 절대 규칙 (기존 아키텍처가 강제하는 것)

- **새 autoload 를 추가하지 않는다.** 현재 5개(`ContentRegistry`, `NetworkManager`,
  `GameSession`, `SaveManager`, `SceneRouter`)가 전부다. 전역이 필요하면 `GameSession`
  facade 뒤의 State/Service 로, 월드 단위면 world scene 자식 노드로 넣는다.
- **Resource 는 정적 콘텐츠, RefCounted 모델은 런타임 상태.** 현재 수량·내구도·효과
  잔여시간·회수 여부·위치를 Resource 에 쓰지 않는다. 테스트에서 Resource 를 바꿔야 하면
  `duplicate()` 하거나 임시 등록 후 정리한다.
- **Scene Node 가 지속 상태의 소유자가 되지 않는다.** 효과 시간은
  `PlayerState.effects`(`EffectRuntimeModel`)가 소유하고 `GameSession` 이 tick 한다.
  스태미나는 `PlayerRuntimeState.combat`(`CombatRuntimeState`)이 소유하고
  `CombatComponent` 는 **참조만** 한다. 씬을 이동해도 유지돼야 하는 값은 전부 모델에 둔다.
- **`MovementComponent.Mode` 는 locomotion 전용이다.** `GROUND`, `AIR`, `CLIMB` 뿐이며
  `ATTACK`, `DODGE`, `HURT`, `DEAD` 를 여기에 추가하지 않는다. 이런 상태는 별도의
  **Combat Action State** 가 관리한다(3차 작업 대상). 두 축을 한 enum 으로 합치면
  `AIR + ATTACK`, `CLIMB + HURT`, `GROUND + DODGE` 같은 조합이 상태 폭발로 이어진다.
- **클라이언트는 데미지를 적용하지 않는다.** 클라이언트가 보내는 것은 항상 *의도*이고,
  호스트가 검증 후 실행하고 결과를 복제한다(2절).
- **입력 액션은 `project.godot` 에만 정의한다.** 코드에서 InputMap 을 만들지 않는다.
- **`res://data/content` 아래에는 `ContentDefinition` 만 둔다.** `ContentRegistry` 가
  시작 시 이 폴더를 재귀 로드하므로, 여기에 텍스처를 참조하는 표현용 Resource 를 두면
  headless 서버 런타임까지 텍스처를 끌고 들어간다. 배경 preset 이
  `world/environment/presets/` 에 있는 이유가 이것이다.
- **`check_project.py` 는 경고도 실패로 본다.** `SCRIPT ERROR`, `ERROR:`, `WARNING:`,
  `orphan`, `ObjectDB instances leaked`, `resources still in use` 중 하나라도 출력되면
  실패다. 따라서:
  - `_ready()` 에서 연결한 전역 시그널(`GameSession`, `NetworkManager`)은 `_exit_tree()`
    에서 `is_connected()` 확인 후 반드시 끊는다.
  - 임시로 만든 Node 는 `queue_free()`/`free()` 한다. `ResourceLoader.load_threaded_*`
    는 노드가 사라질 때 결과를 동기 회수해 토큰을 정리한다.

## 2. 서버 권위 경계 (멀티플레이는 계속 유지·확장한다)

새 게임플레이 시스템은 **처음부터** 이 경계를 지켜서 설계한다. 나중에 붙이는 비용이 훨씬 크다.

```
클라이언트 입력 → (intent RPC, any_peer) → NetworkManager 검증 → 호스트 시뮬레이션
        → 상태 변경(GameSession/State) → (authority RPC) → 같은 월드의 ready peer 에게 복제
```

- 권위 판정은 항상 `NetworkManager.is_authoritative_simulation()` 과 액터의
  `simulation_enabled` 를 함께 본다(`PlayerActor.is_simulation_authority()`).
  싱글플레이도 "호스트"로 취급되므로 같은 코드 경로를 탄다.
- 전송자 위조 방지는 `NetworkProtocol.valid_command_sender(sender_id, actor_peer_id, known_peer)`.
- 명령은 **sequence 로 중복·역행을 막는다**(`PlayerMoveCommand`, `PlayerAttackCommand`
  의 `is_valid_after()`). 새 명령을 만들면 같은 패턴을 따른다. 유효한 sequence 는
  게임플레이 검증보다 **먼저** 소비해서, 거절된 스팸이 쿨다운 후 재생되지 않게 한다.
- 모든 월드 페이로드는 `(world_id, revision)` 과 묶인다. 전환 직전에 날아온 패킷은
  revision 불일치로 버린다. 복제 대상은 `ready_remote_peer_ids(world_id)` /
  `replication_ready_remote_peer_ids(world_id)` 로 **같은 월드의 ready peer 만**.
- 호스트는 점유된 월드마다 `ServerWorldRuntime` 을 하나씩 띄우고, 각각 자기
  `SubViewport.World2D` 에서 물리를 돌린다. 좌표가 겹쳐도 월드 간 물리 질의가 섞이지 않는다.
  이 런타임이 인스턴스화하는 씬은 `configure_server_runtime()` 을 받아
  `server_runtime_mode = true` 가 되며, **배경/표현 노드를 만들면 안 된다.**
- `peer_id` 는 런타임 값이고 저장하지 않는다. 영속 신원은 `player_id`(StringName)다.
  저장·복원·소유 판정은 전부 `player_id` 기준.
- **지속적으로 변하는 값을 reliable RPC 로 매 tick 보내지 않는다.** 이벤트 기반 교정은
  reliable 로, 계속 변하는 값은 throttle + "변했을 때만" + `unreliable_ordered` + sequence 로
  보낸다. 현재 모범 사례는 스태미나 복제다: 이벤트용 reliable `PlayerRuntimeSnapshot` 과,
  10 Hz 상한에 값이 변했을 때만 나가는 `PlayerCombatRuntimeSnapshot`(채널 3)로 분리돼 있다.
  클라이언트는 받은 값을 mirror 만 하고 스스로 굴리지 않는다(예측 없음).
- 클라이언트 runtime mirror 를 적용할 때 **모델 객체를 교체하지 말고 값만 갱신한다.**
  Scene 컴포넌트가 그 객체를 참조하고 있어서 교체하면 조용히 끊어진다.

### payload 를 바꿀 때 함께 볼 것

`NetworkProtocol.VERSION`(현재 **13**) 상향 → 해당 DTO 의 `to_payload()`/`from_payload()`
validator → 관련 unit test(인라인 payload 를 쓰는 테스트 포함) → handshake mismatch 테스트.
같은 버전 안에서 구/신 payload 를 섞어 허용하지 않는다.

## 3. 코드 컨벤션

- GDScript, 탭 들여쓰기(`.editorconfig`), 정적 타입 표기를 항상 쓴다(`func f(x: int) -> bool`).
- ID·팩션·스탯 키는 `StringName` 리터럴(`&"max_health"`)을 쓴다. `String` 과 섞지 않는다.
- `class_name` 은 파일명 PascalCase 와 일치시킨다. 새 스크립트는 `.uid` 파일이 함께
  생성되므로 같이 커밋한다.
- 명령 결과는 `CommandResult` / `InventoryResult` / `CombatResult` 로 반환하고, UI 는
  Dictionary 를 직접 만지지 않는다.
- 검증 실패는 예외가 아니라 `push_error()` + 실패 반환. 세션 상태는 건드리지 않는다.

### 스탯 키 (전부)

`max_health`, `move_speed`, `attack_power`, `defense`, `max_stamina`, `stamina_regen`
— `StatBlock.base_values` 에 정의. 새 스탯을 추가하면 여기 base 값과 저장/복원 경로를 함께 본다.
Modifier 는 source 단위로 교체한다(`replace_source`). 장비 source 는 `equipment:<slot>`,
효과 source 는 `effect:<source>/<effect_id>`.

### 충돌 레이어 (고정 규약)

| 레이어 | 용도 |
|---|---|
| 1 | 캐릭터 Body, 지형(StaticBody2D) |
| 2 | Hurtbox (피격 판정) |
| 4 | Hitbox (공격 판정) |
| 8 | InteractionTarget / EscapePoint |

- Hitbox: `layer 4 / mask 2`, Hurtbox: `layer 2 / mask 4`,
  Interaction 감지 Area: `layer 0 / mask 8`, ClimbableArea2D: `layer 0 / mask 1`.
- 새 판정 영역을 만들 때 이 표를 벗어나지 않는다. 벗어나야 하면 표를 먼저 갱신한다.

## 4. 콘텐츠 추가 절차

1. `data/content/<종류>/<id>.tres` 로 추가. id 는 안정적인 snake_case, 전역 유일.
2. 정의 스크립트는 `data/definitions/` 의 `ContentDefinition` 상속 + `validate_definition(registry)`
   구현. 등록 코드는 고칠 필요 없다(재귀 스캔).
3. 검증:
   `godot --headless --path . res://core/validation/validate_content.tscn` →
   `CONTENT VALIDATION PASS` 문자열이 나와야 한다.
4. 자세한 규칙(지역/출입구/사다리/퀘스트/제작)은 `docs/content_authoring_guide.md`.

## 5. 테스트 추가 절차

- 새 테스트 파일은 `tests/unit/` 또는 `tests/integration/` 에 두고 형태는 고정이다:

```gdscript
extends RefCounted

func run(t: Node) -> void:            # 비동기가 필요하면 -> void 유지하고 await 사용
    t.assert_true(<조건>, "설명")
    t.assert_equal(<실제>, <기대>, "설명")
```

- `tests/test_runner.gd` 의 `run_all()` 에 `preload("res://tests/unit/<파일>.gd").new().run(self)`
  를 추가한다(비동기면 `await` 를 붙인다). 외부 테스트 프레임워크는 도입하지 않는다.
- 테스트가 만든 노드는 반드시 정리한다(누수 경고 = 실패).
- 실제 ENet 이 필요한 회귀는 `tools/test_multiplayer_*.py` 쪽에 붙인다. 고정 sleep 대신
  원자적 JSON sentinel 을 쓰고, 역할별로 독립된 `user://` root 를 준다.

## 6. 월드 씬에 대해 알아둘 것

- 현재 월드 씬(`settlement.tscn`, `sewer_region.tscn`)은 **지오메트리를 코드에서**
  `WorldHelpers.add_platform/add_label/add_interaction` 으로 생성한다. `.tscn` 에는
  스폰 포인트, RegionPoint, 등반 Area, 매니저 노드만 있다. TileMap 기반 레벨로 갈 거라면
  이건 교체 대상이며, 교체 시 `server_runtime_mode` 경로에서 표현 노드가 생기지 않도록
  주의한다.
- 아트는 사실상 없다. 플레이어·적·시설은 전부 `Polygon2D` 플레이스홀더다.
  배경만 `assets/backgrounds/` 에 실제 텍스처가 있다
  (단, `stars_overlay_3840x2160.png` 는 잘린 파일이라 임포트 실패 상태 — 재출력 필요).
- z-index 규약: Backdrop `-1100`, 배경 `-1000..-100`, 게임플레이 `0`, 전경(미구현) `100..900`.

## 7. 손대기 전에 한 번 더 생각할 것

- `GameSession` 의 State 객체를 **교체하지 말고** 모델 API 로 내용을 바꾼다. 교체용
  compatibility setter 는 이미 제거됐다.
- 인벤토리 교환은 출력 공간까지 시뮬레이션한 뒤 한 번에 적용한다. 실패는 원본을 유지한다.
- 사망/부활은 `DeathResolutionService` → `RespawnResult` 경로만 사용한다. 액터에는
  생명 세대(`life_id`)가 있어서 `GameSession.is_current_life()` 로 늦은 시그널을 막는다.
- 원정 중에는 저장/불러오기/난이도 변경이 잠긴다. 진행 중 원정은 저장·재개하지 않는다.
- Save 포맷은 **v4**. 필드를 추가하면 해당 State 의 `to_save_dict()`/`restore()` 와
  `SessionSnapshot` 검증, 그리고 `docs/save_format.md` 를 같이 고친다. 마이그레이션
  회귀 테스트(v1→v4)를 깨뜨리지 않는다.

## 8. 문서 갱신 의무

동작을 바꿨으면 해당 문서도 같은 커밋에서 고친다:
`docs/architecture.md`(기반 구조), `docs/session_architecture.md`(상태 소유권),
`docs/multiplayer.md`(복제·권위), `docs/save_format.md`(저장), `docs/testing.md`(검증),
`docs/content_authoring_guide.md`(콘텐츠), `docs/controls.md`(조작).
