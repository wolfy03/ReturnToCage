# 저장 형식 v3

최상위는 `format_version: 3`, `saved_at`, `game_state`다. 기본 경로는 `user://return_to_cage_save.json`. 기존 v2 flat 필드 이름은 유지하고 다음 배열만 추가했다.

| 필드 | 내용 |
|---|---|
| active_effects | effect_id, remaining, stacks, food_slot, source_id, applied_by, tick_elapsed |
| death_drops | id, region_id, position [x,y], items, session_id, recovered |
| pending_loot | 창고에 들어가지 못한 ItemStack 기록 배열 |

기존 player_stats는 기본 능력치만 저장한다. 임시 Modifier를 저장하지 않는다. 활성 효과와 장비를 복원한 뒤 source별로 한 번 재구성한다. 장비 지속 효과는 active_effects에 중복 저장하지 않는다. ItemStack은 item_id, quantity, durability, instance_id를 사용한다. 주민 JSON은 `{ "milo": { "unlocked": true, "state": "idle" } }`를 유지한다.

## 저장 가능한 상태

SETTLEMENT에서만 Save, MENU/SETTLEMENT에서만 Load를 허용한다. ADVENTURE/RESPAWNING에서는 파일을 읽거나 쓰기 전에 거부한다. 진행 중 원정과 난이도 스냅샷은 저장하지 않는다. v3 저장은 정착지에서 작성되므로 로드하면 정착지 상태가 된다.

## 복원과 오류

SaveManager가 JSON과 envelope를 확인하고 Migration을 수행한다. SessionSnapshot은 독립 모델에 먼저 복원한다. 최상위 상태나 필수 컨테이너 타입이 잘못되면 fatal_error를 반환해 기존 세션을 유지한다. 성공했을 때만 GameSession이 모델들을 교체하고 session_reset을 발행한다.

복구 가능한 문제는 warnings에 수집한다. 위치는 숫자 2개인지 검사한다. 미등록 난이도는 normal로 복구하며 Override 허용 목록·enum·배율 범위를 검사한다. 허기·갈증·체력, 시설 레벨과 장비 슬롯을 보정한다. 퀘스트 progress는 최신 objective 수에 맞춰 0을 채우거나 초과분을 제거한다. 음수/잘못된 스택은 제외하고 최대 중첩 초과는 분할한다. 용량을 넘는 유효 아이템은 pending_loot로 보존한다.

미등록 일반 아이템/퀘스트는 경고 후 제외하는 기존 정책이다. death_drops의 사라진 지역·아이템은 경고와 함께 기록을 보존해 콘텐츠 복구 후 회수할 수 있다. 중복 드롭 ID는 거부하고 이미 회수한 기록은 복원하지 않는다. load_game() bool과 load_finished의 메시지가 치명적 실패와 경고를 포함한 성공을 구분한다. SessionSnapshot은 fatal_error와 warnings를 별도로 제공한다.

## 쓰기와 Migration

`.tmp`에 쓰고 flush/close한 뒤 기존 파일을 `.bak`으로 이동하고 최종 rename한다. 실패하면 메시지를 반환하고 가능한 경우 이전 파일을 복구한다.

Migration은 원본을 깊게 복사한 뒤 단계별로 진행한다.

1. v1 → v2: difficulty_overrides와 protected_inventory가 없으면 추가.
2. v2 → v3: active_effects, death_drops, pending_loot가 없으면 빈 배열 추가.

v1/v2에 기록되지 않은 과거 임시 버프는 복원할 수 없다. 기본 능력치에 효과를 덧붙이지 않는다. 미래 버전은 거부한다. v3 증가는 내부 리팩터링 때문이 아니라 실제 영속 데이터 세 종류를 추가했기 때문이다. tests/fixtures의 기존 v2 JSON은 수정하지 않고 호환 검증에 계속 사용한다.

## 안정화 검증 정책 (v3 유지)

StackValidation과 SaveData.valid_stack이 모든 스택 복원 경계를 공유한다.
수량/내구도는 유한한 32비트 정수 범위이며 수량은 양수다. instance_id는 문자열이고,
비어 있지 않으면 수량이 반드시 1이다. 일반 아이템만 최대 중첩으로 분할한다.
잘못된 레코드는 구체적인 위치를 포함한 경고 한 개로 거부한다.

내구도 -1은 기존 미지정 sentinel로 유지한다. -1 미만은 0으로, 장비의 최대 내구도
초과는 해당 EquipmentDefinition.max_durability로 보정하고 경고한다. 런타임 add/equip은
범위를 벗어난 입력을 거부한다. pending_loot의 unknown/mistyped ItemDefinition은 제외한다.
기존 death_drops의 미등록 콘텐츠 보존 정책은 유지하되 수량·중복·내구도 규칙은 동일하다.

non-empty instance_id는 Snapshot 전체에서 다음 순서로 첫 항목만 유지한다.
player_inventory → equipment(슬롯 정렬) → protected_inventory → settlement_storage
(overflow 포함) → pending_loot → death_drops(배열 순서).
후속 중복은 제외하고 첫 위치/중복 위치를 경고한다. 일반 아이템의 동일 ID는 합법이다.
검증된 overflow는 take_restore_overflow로 버퍼를 비우면서 pending으로 한 번만 이전한다.

PlayerState.restore 자체는 체력을 0..max_health로 보정한다. SaveManager의 정착지 재개는
기존 v3 정책에 따라 0을 1로 회복하고 별도 경고한다. 허기/갈증은 SurvivalConfig의 최대값,
progression_reduction은 0..0.9로 제한한다. 위치는 Vector2 변환 후에도 유한한지 검사한다.
JSON의 유한한 큰 숫자가 float32 좌표에서 무한대가 되는 경우도 거부한다.

v1/v2/v3 Migration은 그대로다. 문자열 버전, 소수 버전, 음수/미래 버전과 비정상 숫자는
거부한다. 재진입 잠금, Actor 생명 세대와 restore의 instance 검사 집합은 저장하지 않는다.

### Reward notification and quest progress boundaries

Reward inventory notifications are held until pending loot has been cleared or
quest reward_claimed has been committed. A synchronous save from storage_changed
therefore contains a consistent reward state. Failed exchanges still leave both
owners unchanged. InventoryModel.begin_update/end_update batches notifications;
it does not replace exchange's staged transaction or provide rollback itself.

Quest progress accepts only finite, integral signed 32-bit values before integer
conversion (JSON 2.0 is valid). Invalid values retain the initialized 0 and report
one progress warning. Valid integers outside 0..required_amount are clamped with
a warning. Completion reconciliation remains a separate validation step.
