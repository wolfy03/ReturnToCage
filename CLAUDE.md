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
  **Combat Action State**(`CombatActionController`, `%CombatAction`)가 관리한다. 두 축을
  한 enum 으로 합치면 `AIR + ATTACK`, `CLIMB + HURT`, `GROUND + DODGE` 같은 조합이
  상태 폭발로 이어진다. 현재 구현된 action state 는 `IDLE / ATTACK_STARTUP /
  ATTACK_ACTIVE / ATTACK_RECOVERY / HURT / DODGE` 이며 `DEAD` 는 후속 단계다.
  `ATTACK_RECOVERY` 만 취소 가능하다: 다음 combo step(`ATTACK_STARTUP`)이나 `DODGE` 로
  **직접** 전이한다(IDLE 경유 금지). `STARTUP`/`ACTIVE` 는 계속 commitment 구간이다.
- **공격 타이밍 상수를 코드에 두지 않는다.** 선딜·유효·후딜은 전부
  `WeaponDefinition.attack_combo`(`AttackComboDefinition`)의 각 step
  (`AttackDefinition`)에서 읽는다. 멜리 히트박스가 열려 있는 시간도 `active_seconds`
  하나가 결정한다. 별도 쿨다운을 부활시키지 않는다 — 새 combo 를 시작할 수 있는 유일한
  기준은 action state 가 `IDLE` 인지다.
- **무기는 combo 하나만 소유한다.** `AttackDefinition` 은 **한 타격 step** 이고,
  `WeaponDefinition.attack_combo` 가 그 순서를 소유한다. 한 번만 휘두르는 무기도
  1-step combo 로 authoring 한다 — `attack_definition` 같은 단일 필드를 되살려 source of
  truth 를 둘로 만들지 않는다. `AttackStrategy` 는 실행 중인 step 을 **인자로 받는다**
  (무기에서 다시 조회하지 않는다).
- **chain / dodge cancel 은 authored window 가 결정한다.** 각 step 의 `chain_window` /
  `dodge_cancel_window`(`CombatActionWindowDefinition`, half-open `[start, end)`)만이
  "지금 가능한가" 를 답한다. `CombatActionController` 는 시간을 모르므로 graph 상 허용은
  필요조건일 뿐이다. 8차의 모든 window 는 **recovery 안에만** 존재한다
  (`start >= startup + active`, `end <= total`) — validation 이 이를 강제한다.
- **combo step 마다 새 `DamageContext` 를 만든다.** knockback·hit effect·facing 이 step 별로
  다를 수 있으므로 1타 context 를 2·3타에 재사용하지 않는다. 스태미나도 step 마다
  `ATTACK_ACTIVE` 진입 시 1회씩 차감한다(combo 전체를 미리 예약하지 않는다).
- **combo index 는 다음에서 0 으로 초기화된다.** 정상 종료, HURT, dodge cancel, death,
  reset, world transition, commit/strategy 실패.
- **Input Buffer 는 client prediction 이 아니라 authoritative scheduler 다.**
  `CombatInputBufferComponent` 는 **검증이 끝난** intent 가 *언제* 실행될지만 정한다.
  slot 은 **하나**이고 **latest input wins**(queue 로 확장하지 않는다). transient combat
  action(`non-IDLE`) 때문에 못 하는 경우에만 buffer 하고, `IDLE` 에서 게임플레이 사유로
  거절된 요청은 buffer 하지 않는다 — buffer 는 무효한 행동을 나중에 유효하게 만들지 않는다.
  만료된 intent 는 window 가 열려도 실행되지 않으며, 실행 가능해진 시점에 실패하면 **한 번만**
  시도하고 버린다. 이 컴포넌트는 `NetworkManager`·RPC·peer 를 전혀 모른다.
- **buffer 된 intent 는 presentation event 를 만들지 않는다.** 수신 시점이 아니라 실제
  action 이 시작되는 순간에만 `attack_presented` / `dodge_presented` 가 나간다(정확히 1회).
  즉시 실행과 buffer 실행이 같은 signal 경로(`attack_executed`/`dodge_executed`)를 쓴다.
  교체되어 버려진 intent 는 영영 presentation 을 만들지 않는다(sequence 는 이미 소비됨).
- **공격 공간 정보와 플레이어 공격 넉백도 `AttackDefinition` step 이 소유한다.** 논리적
  reach는 `range`, 현재 rectangle 판정은 `hitbox_size`/`hitbox_offset`, 공격자 기준 impulse는
  `knockback` 에 둔다. `WeaponDefinition.attack_range` 나 Hitbox/Combat 코드 기본값을 다시
  만들지 않는다. facing 은 x와 offset x만 반전하고 y는 그대로 둔다.
- **공격은 `ATTACK_ACTIVE` 진입 순간에만 commit 된다.** 히트박스 활성화·투사체 생성·스태미나
  차감이 전부 거기서 한 번 일어난다. 요청 프레임에는 아무것도 발생하지 않는다.
- **phase 시간의 소유자는 `CombatComponent` 하나다.** `HitboxComponent` 는 자체 duration
  타이머를 갖지 않는다 — 지금 살아 있는지(`active`)와 이번 공격에서 이미 맞힌 대상만 안다.
  멜리 히트박스는 `ATTACK_ACTIVE` 동안에만 활성이며 `IDLE`/`STARTUP`/`RECOVERY` 에서는 꺼져
  있다. `abort_attack()` 은 히트박스까지 내린다(사망 포함).
- **긴 프레임에서 공격이 증발하면 안 된다.** 한 프레임이 ACTIVE 구간을 통째로 삼켜도
  판정 기회가 0 이 되지 않도록, 히트박스는 활성화되는 순간 direct space query 로 즉시
  한 번 훑는다(`monitoring` 은 다음 physics step 에야 켜지기 때문). 중복 타격은
  공격 단위 `_hit_targets` 가 막는다.
- **`DamageContext.knockback` 은 권위 물리 impulse 다.** 호스트의 damaged 경로에서 기존
  `CharacterBody2D.velocity` 에 더한다. Player는 `MovementComponent.apply_external_impulse()`,
  Enemy는 같은 finite 검증의 actor helper를 쓴다. 별도 RPC/저장 필드/locomotion mode를 만들지
  않는다. 넉백 자체는 HURT 여부를 결정하지 않는다.
- **Player HURT 는 scene-local Combat Action 이다.** `PlayerHurtComponent` 하나가 0.25초
  hit-stun timer와 `MovementComponent` 의 `CONTROL_LOCK_HURT` lock 을 소유한다. 직접 피해의
  `DamageContext.causes_hurt`가 true면 공격이나 dodge를 IDLE 중간 전이 없이 HURT로 interrupt한다.
  knockback은 별도로 먼저 적용되며 zero knockback도 HURT를 만들 수 있다. periodic/starvation은
  `causes_hurt = false`다. HURT는 기존 contact invulnerability도, 저장/복제 상태도 아니다.
- **Player DODGE 는 scene-local Combat Action 이고 i-frame 은 데이터가 소유한다.**
  `PlayerDodgeComponent` 하나가 dodge timeline 과 `CONTROL_LOCK_DODGE` lock 을 소유하고,
  duration·무적 구간·속도·비용은 전부 `DodgeDefinition`(`res://data/combat/player_dodge.tres`)
  에서 읽는다. 무적은 `HealthComponent.evasion_invulnerable`(타이머 없는 gate)로만 구현하며
  기존 post-hit `invulnerability_seconds` 나 `god_mode` 를 재사용하지 않는다. 이 gate 는
  `DamageContext.can_be_evaded` 가 true 인 피해만 막는다(periodic/starvation 은 false).
  스태미나는 시작 시 1회 지불되고 **절대 환불하지 않는다.** dodge 는 지상에서만 시작하고,
  진행 중 위치를 직접 쓰지 않으므로 벽은 `move_and_slide` 가 막고 낭떠러지는 평범한 `AIR`
  낙하가 된다. dodge 를 위해 locomotion mode 를 추가하지 않는다.
- **"지상" 은 enum 이 아니라 실제 접지다.** dodge 시작 조건은
  `movement.mode == GROUND` **그리고** `CharacterBody2D.is_on_floor()` 둘 다다. `mode` 는
  physics tick 당 한 번만 갱신돼 한 프레임 stale 할 수 있고, 그것만 믿으면 이미 공중인
  액터가 지상 dodge 를 시작한다. 시작 후 낭떠러지를 벗어나는 것은 여전히 정상이다.
- **정상 종료만 dodge 속도를 정리한다.** duration 을 다 채운 dodge 는 `_finish()` 에서
  `actor.velocity.x = 0.0` 만 한다(`velocity = Vector2.ZERO` 금지 — 낭떠러지 낙하 속도를
  지운다). 공용 cleanup(`interrupt_for_hurt` / `reset` / death)은 velocity 를 **절대**
  건드리지 않는다. HURT 로 끊긴 dodge 가 자기를 끊은 넉백을 삼키면 안 된다.
- **dodge 방향은 버튼을 누른 순간의 이동 의도가 먼저다.** `PlayerInputComponent` 가
  `dodge_requested(horizontal_direction)` 로 그 시점의 `Input.get_axis` 를 함께 넘긴다
  (cached `move_axis` 는 `_process` 에서만 갱신돼 같은 프레임 방향 전환을 놓친다). 입력이
  없을 때만 `actor.facing` 으로 fallback 한다.
- **Return Channel 은 dodge 거절 사유가 아니다.** 유효한 dodge 는 채널을 취소하고 시작한다.
  취소는 **모든 검증 + action 전이 + 스태미나 지불이 끝난 뒤** `PlayerDodgeComponent` 가
  한 번만 호출한다. 거절된 dodge 는 `return_channel` 도 `movement.enabled` 도 바꾸지 않는다.
  cancel ownership 을 network 계층에 중복으로 두지 않는다.
- **`MovementComponent` 의 input gate 는 소유자별이다.** `set_control_lock(source, locked)` 와
  `CONTROL_LOCK_HURT` / `CONTROL_LOCK_DODGE` 를 쓰고, `controls_locked` 는 읽기 전용 계산
  속성이다. 각 소유자는 자기 lock 만 해제한다 — HURT 로 끊긴 dodge 가 hit-stun 도중에
  조작을 돌려주면 안 된다.
- **Dodge 입력은 edge-trigger intent 다.** 매 tick 나가는 unreliable movement packet 에 태우지
  않고 별도 reliable `PlayerDodgeCommand` 로 보낸다. 호스트는 sequence 를 게임플레이 검증보다
  먼저 소비하고, `direction` 은 정확히 `±1` 만 허용하며 그 외 값은 정규화하지 않고 거절한다.
  이 검사는 `is_equal_approx` 가 아니라 **exact 비교**다 — 호스트가 이 값에 dodge 속도를
  곱하므로 `0.999999` 같은 근사값을 받아주면 계약이 무너진다. local signal 층도 같은 계약을
  쓴다: `±1` 은 그대로, `0` 만 facing fallback, 그 외 finite 값은 **거절**한다(반올림하지
  않는다). facing 자체가 `0`/`NaN`/`INF` 면 `+1` 을 지어내지 않고 아무것도 보내지 않는다.
  malformed direction 도 sequence 는 소비하므로 같은 번호로 정상 값을 다시 보낼 수 없다.
  remote client 는 HP 무적·스태미나 소비·DODGE state·combo index·input buffer·위치를 스스로
  결정하지 않는다.
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
- 명령은 **sequence 로 중복·역행을 막는다**(`PlayerMoveCommand`, `PlayerAttackCommand`,
  `PlayerDodgeCommand` 의 `is_valid_after()`). 새 명령을 만들면 같은 패턴을 따른다. 유효한 sequence 는
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
- **`InteractionTarget.activated` 는 권위 경계가 아니다.** remote presentation actor는 HURT를
  복제받지 않으므로 local interaction 차단은 UX 보조일 뿐이다. world transition, attack,
  quick item, loot, gather처럼 gameplay를 변경하는 명령은 최종 서버 경계에서 해당 peer/world의
  authoritative `PlayerActor`와 life/death/HURT/DODGE 상태를 다시 검증한다.

### payload 를 바꿀 때 함께 볼 것

`NetworkProtocol.VERSION`(현재 **14**) 상향 → 해당 DTO 의 `to_payload()`/`from_payload()`
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
