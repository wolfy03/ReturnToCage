# 세션 상태의 소유권

`GameSession`은 기존 autoload와 시그널을 유지하는 facade다. 세션 ID, 플레이 시간,
안내 메시지와 아래 다섯 State를 소유하고, 새 게임·복원 및 여러 도메인에 걸친 명령을 조정한다.
새로운 autoload는 없다.

| 모델 | 추가할 데이터와 책임 |
| --- | --- |
| `PlayerState` (`GameSession.player`) | `stats`, `inventory`, `equipment`, `protected_inventory`, `survival`, `health`, `last_safe_position`. 초기화와 플레이어 저장 필드 복원 |
| `SettlementState` (`settlement`) | `storage`, `facility_levels`, `resident_states`. 주민 값은 `ResidentState`이며 정착지 저장을 담당 |
| `ProgressionState` (`progression`) | `quest_states`, 지역·출구·플래그 해금, 발견한 탈출 지점. `QuestDefinition`은 복제하지 않음 |
| `AdventureState` (`adventure`) | `active_session`. 원정 런타임 상태 소유와 복원 시 초기화 |
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

각 State의 `to_save_dict()`가 담당 필드만 반환하고 GameSession이 flat Dictionary로 합친다.
`restore()`는 `PackedStringArray` 경고를 반환한다. `core/serialization/save_data.gd`와
기존 InventoryModel·EquipmentModel·StatBlock의 복원 검증으로 잘못된 중첩 타입을 걸러낸다.
퀘스트 진행 배열은 정의의 objective 길이에 맞춰 복원해 이후 UI/이벤트의 인덱스 접근을 보호한다.

save format은 **2 그대로**이며 기존 key를 유지한다. SaveManager가 복제한 envelope를
단계별 migration에 전달한다. 현재 단계는 `_migrate_v1_to_v2()` 하나이며
`difficulty_overrides`, `protected_inventory`를 보충한다. 원본 envelope는 변경하지 않는다.
진행 중 원정은 기존처럼 저장하지 않으며 로드 후 정착지로 돌아온다.

누락된 inventory/진행/주민 데이터는 빈 상태로 복원한다. 생존 수치·위치·난이도와
능력치의 누락/오류는 검증된 시작 설정을 사용하며, 체력 누락 시 복원한 max_health를 사용한다.
이전 세션의 생존 수치나 임시 능력치 Modifier가 새 로드에 섞이지 않는다.
알 수 없는 item/quest/equipment/facility는 경고와 함께 제외한다. 지역·출구·플래그 문자열은
기존처럼 보존한다. 잘못된 envelope는 현재 세션을 건드리지 않고 로드 실패한다.

## 호환 API와 시그널

기존 `player_inventory`, `player_stats`, `equipment`, `settlement_storage`, `quest_states`,
`active_adventure` 등의 속성은 deprecated getter/setter다. State 외에 별도 객체를 저장하지 않는다.
production의 gameplay/world/UI/devtools는 새 도메인 접근을 사용한다. 테스트의 기존 접근은
호환 검증을 위해 의도적으로 유지한다.

두 가지 타입 전환에 유의한다. `resident_states`의 값은 이제 Dictionary 대신 `ResidentState`다.
`survival_state`의 Dictionary getter는 저장 어댑터용 **스냅샷**이며, 전체 Dictionary 대입은
지원한다. 중첩 Dictionary 변경 대신 `player.survival.hunger` 같은 typed 접근을 사용한다.
저장 JSON에는 이 타입 전환이 드러나지 않는다.

인벤토리·창고 객체는 reset/restore 때 유지하고 내용만 교체한다. `_create_models()`와
relay 연결은 반복 호출에 안전하다. 기존 호환 setter로 모델을 교체하면 이전 relay를 해제한다.
새 코드는 모델 객체를 교체하지 말고 InventoryModel API로 내용을 변경한다.
기존 여덟 GameSession 시그널은 유지한다.

## 다음 단계 경계

시설 업그레이드, 퀘스트 command 및 `finish_adventure()` 정산은 아직 GameSession에 있다.
AdventureResolutionService, quest event decoupling, data-driven item use는 후속 작업이다.
Inventory 슬롯/ItemInstance 구조, Enemy 상태 머신과 기존 컴포넌트의 플레이 책임은 유지했다.
