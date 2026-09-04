# 콘텐츠 제작 가이드

## 공통 규칙

모든 콘텐츠 파일은 `data/content` 아래의 적절한 폴더에 `.tres`로 추가한다. 각 Resource의 `id`는 저장 데이터와 다른 Resource의 참조에 사용되므로 출시 후 변경하지 않는다. 소문자 `snake_case`를 권장한다. 새 파일을 추가한 뒤 반드시 전체 콘텐츠 검증을 실행한다.

## 아이템, 음식과 효과

일반 아이템은 `ItemDefinition` 스크립트를 사용하는 `.tres`를 만들고 표시 이름, 분류, 최대 중첩, 무게, 가치, 보호 여부와 태그를 지정한다. 수량은 Resource에 넣지 않는다.

음식/음료는 같은 정의에 `hunger_restore`, `thirst_restore`, `food_slot`, `effects`를 설정한다. 새 버프는 먼저 `EffectDefinition` `.tres`를 만들고 대상 능력치, ADD/MULTIPLY, 값, 지속시간, REPLACE/REFRESH/STACK 정책을 지정한 뒤 음식의 외부 Resource 참조로 연결한다. 아이템 ID별 분기 코드는 필요 없다.

## 장비와 무기

방어 장비는 `EquipmentDefinition`, 무기는 `WeaponDefinition`을 사용한다. 슬롯, 내구도, 능력치 변경을 지정하고 무기는 공격 방식, 피해, 쿨다운, 범위, 스태미나 비용과 대상 진영을 추가한다. 현재 샘플은 근접 `twig_sword`다.

## 적과 전리품

`LootTableDefinition`에 후보 ID, 가중치, 최소/최대 수량을 같은 인덱스로 작성한다. `EnemyDefinition`에서 이 LootTable을 참조한다. 난수는 `roll(rng, multiplier)`에 외부 `RandomNumberGenerator`를 전달하므로 테스트에서 seed를 고정할 수 있다. 새 적 씬은 `EnemyAgent`와 여섯 상태 노드를 조합한다.

## 지역과 출입구

`RegionDefinition`에 씬 경로와 논리적인 진입/탈출 지점 ID, 주요 자원, 적 ID를 작성한다. `SettlementExitDefinition.connected_region_ids`에서 지역 ID를 참조한다. 정착지 상호작용 코드는 지역 씬 경로를 직접 알지 않고 Registry와 SceneRouter를 사용한다.

## 시설과 제작법

시설은 `FacilityDefinition.levels`에 `FacilityLevelDefinition` SubResource를 추가한다. 레벨마다 비용 ID/수량, 해금 플래그, 외형 색, 주민 관심 지점을 선언한다. `RecipeDefinition`은 입력/출력 배열과 요구 시설 ID/레벨을 가진다. 레벨 전용 `if` 분기 대신 레벨 데이터를 조회한다.

## 퀘스트

`QuestDefinition.objectives`에 `QuestObjectiveDefinition`을 추가한다. 지원 목표는 아이템 확보, 적 처치, 지점 발견, 시설 업그레이드, NPC 대화다. 진행 상태는 `QuestState`에만 저장된다. 보상과 선행/후속 퀘스트도 ID로 연결한다.

## 검증

PowerShell에서 프로젝트 루트를 기준으로 다음을 실행한다.

```powershell
& 'C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' --headless --path . res://core/validation/validate_content.tscn
```

빈 ID, 중복 ID, 잘못된 Resource 타입, 누락된 아이템/적/지역/시설/퀘스트 참조, 배열 길이 불일치, 잘못된 수치 범위가 있으면 종료 코드 1을 반환한다.
