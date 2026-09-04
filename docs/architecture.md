# Return to Cage 기반 아키텍처

## 실행 구조

`core/boot.tscn`이 메인 씬이다. `AppRoot` 아래에는 교체되는 `WorldLayer`, 유지되는 `UILayer`, 전환용 `TransitionLayer`, 디버그 전용 `DebugLayer`가 있다. 메인 메뉴에서 새 게임 또는 불러오기를 선택하면 `SceneRouter`가 `WorldLayer`의 월드만 교체한다.

월드 흐름은 `Boot → MainMenu → GameSession → Settlement ↔ AdventureRegion`이다. 모험 진입 시 `AdventureContext` 객체에 지역 ID, 정착지 출입구 ID, 진입 지점 ID, 난이도 ID, 준비 인벤토리 스냅샷, 세션 ID를 담아 새 지역의 `configure()`에 직접 전달한다. 임시 전역 필드를 통한 장면 간 전달은 사용하지 않는다.

## Autoload

- `ContentRegistry`: 전체 게임 수명 동안 불변 콘텐츠 Resource를 안정적인 ID로 조회하고 검증한다.
- `GameSession`: 새 게임부터 저장/종료까지 유지되는 런타임 상태만 소유한다.
- `SaveManager`: GameSession 직렬화, 원자적 파일 교체, 버전 Migration을 담당한다.
- `SceneRouter`: 지속 AppRoot의 WorldLayer 교체와 Context 전달을 한 경로로 통제한다.

의존 방향은 `ContentRegistry → GameSession → World/UI`이며, 저장은 `SaveManager → GameSession`, 전환은 `SceneRouter → ContentRegistry/WorldLayer`이다. 월드나 UI가 Save JSON 구조를 알지 못한다.

## 정의와 상태 분리

`data/definitions`의 Resource 클래스와 `data/content`의 `.tres`는 변경되지 않는 콘텐츠 정의다. 수량, 내구도, 현재 체력, 허기, 퀘스트 진행, 시설 레벨은 `core/models`, 컴포넌트 또는 `GameSession`에만 존재한다. 저장 파일은 Resource 경로 대신 안정적인 `id`와 런타임 값만 기록한다.

주요 런타임 모델은 `InventoryModel`, `EquipmentModel`, `StatBlock`, `QuestState`, `AdventureSession`, `DeathLossResult`다. 인벤토리는 스냅샷을 반환하고, 모든 변경은 API와 `changed` Signal을 거친다.

## 플레이 책임

- `PlayerInputComponent`: Input Map을 행동 의도로 변환한다.
- `MovementComponent`: 중력, 지상 이동, 점프를 수행한다.
- `HealthComponent`, `DamageContext`, `HitboxComponent`, `HurtboxComponent`: 피해 원인/진영/무적 시간/사망을 처리한다.
- `CombatComponent`: 무기 Resource 수치, 쿨다운, 스태미나를 사용해 공격한다.
- `SurvivalComponent`: SurvivalConfig와 난이도에 따른 허기·갈증을 계산한다.
- `EffectController`: 데이터 기반 효과의 슬롯, 갱신, 중첩, 만료와 능력치 Modifier를 관리한다.
- `InteractionComponent`: 우선순위가 높은 대상, 동률이면 가까운 대상을 고르고 HUD에는 하나의 안내만 보낸다.
- `EnemyAgent`: 상태 노드(`Idle/Patrol/Chase/Attack/Hurt/Dead`)에 물리 결정을 위임한다.

## Signal 흐름

근거리 이벤트는 컴포넌트 Signal로 연결한다. 예를 들어 Hurtbox → Health → Player/Enemy, InteractionTarget → World command, Player → HUD 순서다. 씬을 넘는 상태 변경은 GameSession의 `adventure_started`, `adventure_finished`, `facility_changed`, `quest_changed`를 사용한다. 전역 EventBus는 없다.

## 원정 결과

`AdventureSession`은 시작 인벤토리, 미확보 전리품, 발견 탈출구, 적 처치와 결과를 분리한다. 정상/귀환 아이템 탈출에서만 미확보 전리품을 창고에 확정한다. 사망은 `DeathLossPolicy`가 난이도 Resource와 사용자 Override를 읽어 결정적 결과 객체를 만들며, 중요 아이템 보호와 장비 보호/내구도 감소/분실을 분리한다.
