# 세션 상태의 소유권

`GameSession`은 기존 autoload와 시그널을 유지하는 facade다. 세션 ID, 플레이 시간,
안내 메시지와 아래 다섯 State를 소유하고, 새 게임·복원 및 여러 도메인에 걸친 명령을 조정한다.
새로운 autoload는 없다.

| 모델 | 추가할 데이터와 책임 |
| --- | --- |
| `PlayerState` (`GameSession.player`) | `stats`, `inventory`, `equipment`, `protected_inventory`, `survival`, `health`, `last_safe_position`, `effects`. 초기화와 플레이어 저장 필드 복원 |
| `SettlementState` (`settlement`) | `storage`, `facility_levels`, `resident_states`, `pending_loot`. 주민 값은 `ResidentState`이며 정착지 저장을 담당 |
| `ProgressionState` (`progression`) | `shared_quest_states`, `PersonalProgressionState[player_id]`, 지역·출구·플래그 해금, 발견한 탈출 지점. `QuestDefinition` 자체는 복제하지 않음 |
| `AdventureState` (`adventure`) | `active_session`, `death_drops`. 활성 원정은 runtime-only이며 death drop은 stable owner player ID와 함께 복원 |
| `DifficultyState` (`difficulty`) | `id`, `overrides`, 프리셋 복제 후 effective difficulty 생성. 허용 속성 목록은 `OVERRIDABLE_PROPERTIES` 한 곳에 정의 |

`ResidentState`는 주민 ID, `unlocked`, `current_state: StringName`을 가진다.
ID는 기존 JSON의 바깥 키이며 값은 계속 `{"unlocked": true, "state": "idle"}`이다.
주민 정의 Registry와 새 주민 AI는 도입하지 않았다.

`SurvivalState`는 허기·갈증·진행도 감소율을 소유한다. `SurvivalComponent.configure()`에
`GameSession.player.survival`을 전달하면 동일 객체를 공유한다. 컴포넌트는 기존 계산과
시그널을 담당하고, PlayerActor는 이동·전투·피해 처리를 계속 담당한다.
씬에서 생존 Dictionary를 만들어 세션에 복사하는 경로는 제거했다.

## 새 게임 콘텐츠

`data/content/game_start/default_game_start.tres`가 현재 시작 설정이다.
`GameStartDefinition`은 `ContentDefinition`이므로 기존 ContentRegistry의 재귀 검색과
`validate_all()`에 자동 참여한다. Registry 코드는 바꿀 필요가 없다.

초기 아이템은 `StartingItemDefinition` 배열이며 ID·수량·내구도를 가진다.
초기 주민은 `StartingResidentDefinition` 배열이다. 시설 레벨과 능력치는 typed Dictionary,
해금 목록은 typed Array다. 설정은 실제 상태로 복사하며 런타임에서 Resource를 변경하지 않는다.
시작 수량·장비·시설·주민·난이도·생존 수치·체력·위치를 바꿀 때 GameSession 수정은 필요 없다.

시작 설정 타입, 콘텐츠 참조, 수량, 용량, 장비 슬롯·내구도, 주민 ID 중복, 능력치와
위치를 검증한다. 잘못된 설정이면 GameSession은 `push_error`를 기록하고
`start_new_game()`이 `false`를 반환한다. 메뉴는 씬에 진입하지 않고 오류를 표시한다.

## 저장 경계

production 저장은 `GameSession.export_persistent_state()`가 Save v4의 `shared`와
`players[player_id]`를 만들고, 로드는 migration 뒤 `prepare_persistent_restore()`와
`apply_persistent_snapshot()`을 거친다. 각 State의 `to_save_dict()`와 `restore()`는 자기
도메인만 직렬화·검증한다. v1–v3 flat snapshot builder는 migration regression test 전용으로
유지하며 live load 경로에서 직접 적용하지 않는다.

save format은 **4**이다. `peer_id`와 network/runtime revision은 저장하지 않으며, Host의
attached/detached canonical PlayerState와 personal progression은 persistent `player_id`로
저장한다. v1 → v2 → v3 → v4 migration을 거치며 진행 중 원정은 재개하지 않는다.
[저장 형식](save_format.md)을 따른다.

누락된 inventory/진행/주민 데이터는 빈 상태로 복원한다. 생존 수치·위치·난이도와
능력치의 누락/오류는 검증된 시작 설정을 사용하며, 체력 누락 시 복원한 max_health를 사용한다.
이전 세션의 생존 수치나 임시 능력치 Modifier가 새 로드에 섞이지 않는다.
알 수 없는 item/quest/equipment/facility는 경고와 함께 제외한다. 지역·출구·플래그 문자열은
기존처럼 보존한다. 잘못된 envelope는 현재 세션을 건드리지 않고 로드 실패한다.

## 호환 API와 시그널

과거 `player_inventory`, `player_stats`, `settlement_storage`, `quest_states` 등의 state-property
facade는 production과 tests가 typed owner API로 이동한 뒤 제거했다. `GameSession.player`만
local-player 호환 view로 유지하며 active peer와 persistent registry가 참조하는 동일한
canonical PlayerState를 반환한다. 새 코드는 `GameSession.player`, `settlement`, `progression`,
`adventure`, `difficulty`의 typed API를 사용한다.

새 게임은 모델 내용을 초기화한다. restore는 독립 SessionSnapshot을 검증한 뒤 모델을 교체한다. `_create_models()`와
relay 연결은 반복 호출에 안전하다. 외부 객체 교체용 compatibility setter는 제거했다.
새 코드는 모델 객체를 교체하지 말고 InventoryModel API로 내용을 변경한다.
기존 여덟 GameSession 시그널은 유지한다.

## 명령의 확장 지점

사망 손실·부활은 DeathResolutionService, 출입구는 ExitService, 선행 조건은
ProgressionService, 제작 거래는 CraftingService에 둔다. GameSession은 결과를 적용하고
시그널을 발행한다. PlayerState.effects는 장면에 독립적인 EffectRuntimeModel이다.
AdventureSession.rules는 원정 시작 때 확정한 AdventureRulesSnapshot이다.
더 자세한 흐름은 [아키텍처](architecture.md)를 참고한다.

Quest event decoupling, 귀환 아이템 효과 데이터화, 제작 대기열은 후속 확장 대상이다.
Inventory 슬롯/ItemInstance 구조와 기존 컴포넌트의 플레이 책임은 유지했다.

## 안정화 기준점

Persistent registry는 `_player_states_by_id[player_id]`, active attachment는
`players[peer_id]`와 `_attached_player_ids[peer_id]`가 담당한다. `attach_player`는 같은
canonical 객체를 연결하고, `detach_player`는 연결만 해제하며, `remove_player_state`만
persistent state를 삭제한다. Client의 remote placeholder는 disconnect 때 제거한다.

프로세스 재시작 뒤에도 Save v4는 canonical registry를 `player_id`로 복원하고 runtime
`peer_id`는 복원하지 않는다. Host Saved Game 직후 local profile만 peer 1에 attach되며
remote records는 detached canonical state다. 새 ENet peer의 handshake가 같은 inactive
`player_id`를 제출하면 그 객체를 재사용한다. NetworkManager의 peer/player mapping,
world-ready, private/session receive flags, spawn assignment는 현재 transport/session 전용
cache이며 disconnect와 transport reset에서 제거된다. `validate_runtime_invariants()`는 active
mapping의 양방향 대칭과 GameSession attachment, owner/session-bound spawn cache를 점검하되
detached canonical player 자체는 오류로 취급하지 않는다.

PlayerState는 reset/restore 시 이전 EffectRuntimeModel의 periodic과 이전 StatBlock의
stat_changed 연결을 명시적으로 해제한다. 외부에서 이전 RefCounted를 보관해도 현재
PlayerState에 콜백하지 않는다. 이전 효과 모델은 paused 상태로 폐기된다.

Actor마다 생명 세대 번호를 부여한다. 사망·체력 콜백은 현재 세대인지 검사한다.
새 게임과 로드도 세대를 무효화한다. complete_respawn은 효과 pause를 해제하고,
새 Actor의 arm_player_life가 사망 결과 캐시를 지운다. 잘못된 전이는 false를 반환한다.
신규 세션 생성은 기존 플레이 전이와 구분하여 상태를 재설정한다.

자세한 복원 순서와 한계는 [안정화 보고](stability_baseline.md)를 참고한다.
