# ReturnToCage Field Editor

Godot 4.7.2에서 프로젝트를 열고 **Project → Project Settings → Plugins**에서
**ReturnToCage Field Editor**를 활성화한다. 저장소 기본 설정은 활성화 상태다.
`world/adventure/sewer_region.tscn`을 열고 **2D** 화면과 왼쪽 **Field Editor** Dock을 선택한다.
새 필드는 기존 모험 씬을 복제하고 `AdventureRegion` 스크립트와 필수 매니저를 유지하면 편집할 수 있다.

1. 검색창에서 표시 이름, 콘텐츠 ID, 경로 또는 카테고리를 검색한다.
2. 팔레트 행을 2D 뷰포트로 끌고 위치 표시가 원하는 곳에 오면 놓는다. Esc로 취소한다.
3. 선택된 노드의 Position을 Inspector에서 정확히 입력하거나 Godot 이동 도구를 사용한다.
4. Ctrl+S로 일반 `.tscn`을 저장한다. 기존 씬을 다시 열어 같은 방식으로 편집한다.

**Placement enabled**는 배치 입력을 켜고 끈다. **Grid snap**은 새 배치에만 적용되며
기본 간격은 32px이다. Alt를 누르면 이번 배치의 스냅을 건너뛴다. 이동 도구에는
Godot의 스냅 설정이 적용된다. **Use selected Node2D group**을 켜면 현재 씬이 소유한
일반 Node2D 그룹을 선택해 그 아래에 배치할 수 있다. 플레이어 스폰 슬롯은 루트에 추가된다.

| 팔레트 | 저장되는 데이터 |
| --- | --- |
| Terrain | 크기, 색, one-way를 설정할 수 있는 플랫폼 또는 장애물 인스턴스. Size가 충돌 사각형과 폴리곤을 함께 갱신한다. |
| Enemy | `FieldEnemySpawnPoint`와 등록된 EnemyDefinition ID |
| Gather | `FieldGatherPoint`와 등록된 ItemDefinition ID. Inspector에서 수량을 바꿀 수 있다. |
| Region Points | ENTRY와 ESCAPE `RegionPoint`. ESCAPE에 requires_landing을 설정할 수 있다. |
| Spawns | 사용 중인 0–3 슬롯을 피해서 추가하는 PlayerSpawnPoint |
| Climbables | 사다리 또는 밧줄 정의, Area2D 충돌 사각형, Top/Bottom 마커 |
| Decorations | Texture2D 또는 `world/decorations/` 아래의 시각 전용 PackedScene 경로 |

장식 PackedScene은 Node2D, Sprite2D, Polygon2D, Line2D로 구성하고 스크립트와 중첩
씬 인스턴스를 붙이지 않는다. Inspector의 장식 경로는 표시 월드에서만 읽힌다.
장식은 충돌을 생성하지 않는다. 기존 플랫폼의 편집은 CollisionShape2D와 Polygon2D에
각각 적용한다. 새 플랫폼은 루트의 Size 속성에서 편집한다.

노드 선택, 다중 선택, 이동, 삭제, 복제와 속성 편집은 Godot 기본 도구를 사용한다.
배치도 같은 Undo/Redo 기록을 사용한다. Godot의 복제는 ID 속성을 함께 복사하므로
복제한 마커의 ID를 변경한 뒤 **Validate field**를 실행한다. RegionPoint가 추가되면
`RegionDefinition`의 선언을 직접 확인하고 갱신한다. 등록되지 않은 필드는 먼저
`scene_path`를 지정한다.

## 검증

```sh
python tools/test_field_editor.py --godot <Godot 4.7.2 실행파일>
python tools/test_field_editor.py --godot <Godot 4.7.2 실행파일> --rendered
```

두 명령은 임시 프로젝트에 씬을 복제하고 배치, Undo/Redo, 저장과 런타임 재생을 검사한다.
렌더링 옵션은 Godot 에디터에 마우스 이벤트를 주입해 팔레트에서 뷰포트로 드래그한 뒤
씬 탭을 닫고 다시 연다. 실제 OS 입력 장치로 수행한 수동 테스트와는 구분한다.
프로젝트 전체와 ENet 검증은 [테스트 문서](testing.md)를 따른다.


**Validate field**는 충돌한 ID나 스폰 인덱스와 두 노드의 씬 상대 경로를 표시한다.
경로를 기준으로 Scene 트리에서 해당 노드를 찾을 수 있다. 복제된 ID와 RegionDefinition은
검증 중 자동으로 수정하지 않는다. 새 씬도 등록 전에 구조를 검사할 수 있다.

플레이어 스폰 슬롯은 루트 바로 아래에 두고 0–3 인덱스를 한 번씩 사용한다. 그룹 아래의
ENTRY는 지원하지만 그룹 아래의 플레이어 슬롯은 현재 스폰 매니저가 무시한다. 슬롯이
부족하면 경고를 표시하며, 착지 여유 공간과 지지 지형은 런타임 물리 검증에서 판정한다.
장식은 Dock에서 리소스 타입과 PackedScene 구성까지 검사한다. 권위 월드 시작 시에는
경로 존재만 검사해 장식 텍스처나 씬을 로드하지 않는다.

## 지형 도구와 레이어

**Tool** 메뉴에서 모드를 선택한다. 기존 팔레트 드래그 앤 드롭은 모든 모드에서
사용할 수 있다.

- **Select**는 Godot의 기본 선택·이동 도구를 사용한다.
- **Rectangle**은 왼쪽 버튼을 누른 점과 놓은 점 사이에 플랫폼을 만든다. 팔레트에서
  Obstacle을 선택하면 장애물로 이름을 붙인다. 각 끝점을 에디터 화면에서 월드 좌표로
  변환한 뒤 스냅한다. Alt는 해당 끝점의 스냅을 생략한다. 폭과 높이가 각각 4 월드
  단위 이상이어야 한다. 생성 후 Inspector의 **Size**에서 크기를 바꿀 수 있다.
- **Paint**는 Grid 간격과 같은 크기의 셀을 연속 배치한다. 이 모드의 셀 간격은
  Rectangle의 스냅 체크 상태와 독립적이다. 빠른 이동의 중간점을 샘플링하고,
  동일 스트로크와 기존 FieldPlatform의 변환된 외곽과 겹치는 셀을 건너뛴다. 스트로크당
  최대 2,048셀을 생성한다.
- **Erase**는 반경 10 월드 단위 브러시로 현재 씬이 소유한 FieldPlatform만
  지운다. 하수구의 기존 플랫폼과 매니저는 계속 Godot 기본 도구에서 관리한다.

누르는 동안에는 사각형·셀·지우기 대상만 미리 표시한다. 버튼을 놓으면 스트로크가
한 번의 Undo/Redo 작업이 된다. Esc, 씬 전환, 도구 변경 또는 뷰포트 밖에서 버튼을
놓으면 진행 중인 스트로크를 취소한다. 중첩 부모에 생성할 때는 부모 변환의 역변환을
적용해 월드 축 기준의 사각형을 보존한다.

**Layer: Auto**는 리소스 타입에 맞는 레이어를 사용한다. 레이어를 직접 선택하면
호환되는 종류만 배치할 수 있다. 플레이어 스폰은 SpawnPoints로 분류되며 실제 노드는
루트에 둔다. **Visible**은 에디터 캔버스 미리보기만 바꾼다. Godot의 선택 가이드나
씬 트리 항목은 표시될 수 있다. **Tool lock**은 Field Editor의 제작 및 배치를
막으며 Godot 기본 Select·Inspector에는 적용되지 않는다. 레이어 설정은 씬을
전환하면 초기화되며, 씬의 Visibility·충돌·렌더 순서에는 저장되지 않는다.

검증은 편집 중인 FieldPlatform의 Size를 충돌 사각형과 시각 폴리곤 외곽과 비교한다.
트리 밖에서 검사하는 PackedScene은 프리팹 지오메트리를 포함하므로, 실제 Size 반영은
FieldPlatform이 준비된 후 확인한다.


## 플랫폼 핸들, 장식 브러시와 데이터 정리

**Select**에서 FieldPlatform 하나를 선택하면 모서리와 변에 핸들 8개가 나타난다.
핸들을 끌면 반대편이 고정되고, 버튼을 놓으면 Position과 Size가 함께 바뀐다.
Grid Snap은 드래그하는 점의 월드 좌표에 적용된다. Alt는 스냅을 해제하고 Esc는
미리보기를 취소한다. Terrain이 숨겨져 있거나 잠겨 있으면 핸들을 사용할 수 없다.
기존 일반 StaticBody2D 플랫폼은 Godot 기본 도구로 편집한다.

**Decoration Brush**에서는 팔레트의 텍스처나 시각 전용 씬을 선택하고 드래그한다.
Spacing은 월드 좌표 간격이다. 회전 범위, 최소·최대 크기, 시드, 좌우 반전 및 중복
방지 옵션을 조절할 수 있다. 동일한 설정·경로·기존 배치에 동일한 시드를 사용하면
같은 변환을 얻는다. 한 번의 Undo는 스트로크 전체를 되돌린다. 브러시 장식은
기존 장식 노드와 동일하게 리소스 경로와 Transform을 씬에 저장한다.

**Duplicate IDs**에서 충돌 경로를 보고 행을 선택해 해당 노드를 찾을 수 있다.
**Reissue duplicates**는 현재 씬이 소유한 적·채집 중복만 바꾸고, 씬 순서의
첫 ID를 보존한다. RegionPoint는 직접 수정한다. ID를 바꾼 씬은 저장하고 멀티플레이
참가자에게 같은 씬을 배포한다.

**Sync Region Points**에서 ENTRY·ESCAPE 추가와 제거를 검토하고 **Save and sync**를
선택한다. 먼저 씬을 저장한 다음 연결된 RegionDefinition 파일을 갱신한다.
연결이 없거나 여러 개이면 중단한다. 잘못된 필드 구성과 정착지 출구, 퀘스트, 새 게임
설정이 참조하는 지점 제거도 차단한다. 제거된 탈출 ID는 기존 플레이어 저장에 남을 수 있다.
동기화는 선언만 수정하며 Undo/Redo도 이전·새 선언을 파일에 저장한다.

동기화는 변경된 RegionDefinition을 먼저 임시 파일에 준비하고 기존 씬 파일을
백업한다. 씬 저장에 실패하거나 준비한 리소스로 교체하지 못하면 이전 씬 파일을
복원하고, 편집 중인 노드는 다시 저장할 수 있게 남겨 둔다. 읽기 전용 리소스는
씬을 저장하기 전에 거절한다. Undo/Redo에서 파일 쓰기가 실패하면 마지막으로
저장된 선언을 유지하고, 해당 이력 위치를 복구한 뒤 다시 시도하도록 안내한다.
다른 작업이 이미 이력을 이동시킨 경우에는 파일을 추가로 변경하지 않고 다시
검토하라는 메시지를 표시한다. 씬 탭을 전환해도 열린 탭의 이력을 사용할 수 있다.

정착지 출구의 ENTRY, 새 게임의 발견된 탈출 지점, 퀘스트의 지점 발견 목표가
콘텐츠의 직접 참조다. 플레이어 저장에 기록된 탈출 지점과 네트워크에 전달되는
지점 ID는 동기화에서 자동 변경하지 않는다. 배포 후 탈출 ID를 제거하면 이전
발견 기록이 남을 수 있으므로 같은 버전의 씬·리소스를 참가자에게 배포한다.


## 지역 생성과 배치 프리셋

**New Region**에서 ID, 표시 이름, 설명, 위험도, 환경 리소스 경로, ENTRY/ESCAPE
ID, 스폰 슬롯 수를 입력한다. 경로는 기존 프로젝트 폴더 안에서 지정한다.
Scene은 `res://world/adventure/`, RegionDefinition은 `res://data/content/regions/`
아래에 둔다. **Review files**로 대상과 설정을 확인한 뒤 생성한다.

- **Empty Region**은 매니저와 직접 자식 스폰 슬롯, 입구와 탈출만 생성한다.
  플레이하기 전에 바닥과 안전한 진입 공간을 배치해야 한다.
- **Flat Ground**는 기본 바닥과 진입·탈출 공간을 제공한다.
- **Platform Region**은 바닥, 높이가 다른 발판과 사다리를 제공한다.

생성 후 파일 시스템이 갱신되면 새 씬과 검증 결과가 열린다. 게임 시작 시
ContentRegistry가 새 RegionDefinition을 자동 검색한다. 플레이하려면 정착지 출구의
연결 지역·ENTRY를 설정하고 실제 진행 규칙에 맞춰 출구와 지역을 해금한다.
**Validate field**는 연결 여부를 안내하며 플레이를 실행하지 않는다.

생성 파일과 복구 기록은 먼저 `.godot/rtc_field_sync/`에 준비된다. 중단 후
**Recover Region Creation**을 열면 최종 경로, 임시 경로, 적용할 작업을 볼 수 있다.
확인 전에는 파일을 변경하지 않는다. 게시 전에는 해시가 확인된 임시 파일과
기록을 정리한다. 씬만 게시됐으면 검증된 RegionDefinition의 게시를 재개한다.
두 파일 모두 게시됐으면 최종 파일을 그대로 두고 기록만 정리한다.

해시가 다르거나 손상된 기록, 해시 기록 전에 중단된 임시 파일, 이전 버전의
복구 기록은 수동 검토가 필요하다. 실행 중인 프로세스의 게시 잠금과 소유자를
확인할 수 없는 잠금은 그대로 보존한다. 기록된 프로세스가 종료된 잠금은
다른 에디터가 지역을 게시 중이지 않은지 확인한 뒤 복구 화면에서 해제한다.

**Save Preset**으로 FieldPlatform, FieldDecoration, 적·채집 마커 또는 사다리·밧줄
하나 이상을 저장한다. Presets 카테고리에서 검색해 다른 씬으로 끌어 놓는다.
첫 선택 위치를 기준으로 상대 변환 행렬을 보존하고 적·채집 ID를 새로 발급한다.
잘못된 콘텐츠 참조, 비가역 변환, 등반 마커와 충돌 영역의 불일치는 전체 배치를 차단한다.
혼합 프리셋은 **Layer: Auto**에서 사용하며 구성 레이어 중 하나라도 잠기거나
숨겨져 있으면 전체 배치가 거절된다. 배치된 노드는 씬에 저장되고 프리셋 파일은
편집 전용이다.

**Visualize**에서 종류별 오버레이와 ID를 켠다. 채집 사각형은 InteractionTarget의
42×42 영역이고, 원은 서버가 추가로 확인하는 90 월드 단위 거리 제한이다.
적 오버레이는 위치와 설정만 표시한다. 레이어를 숨기면 해당 오버레이도 숨겨진다.

Sync Region Points의 Undo/Redo는 마지막 저장 해시와 메모리의 지점 선언을 확인한다.
외부 수정이나 Inspector의 미저장 값이 감지되면 파일을 보존하고 이력을 복구한다.
외부 수정은 에디터에서 리소스를 다시 읽고, 미저장 값은 검토해 저장하거나 취소한 뒤
Sync Region Points를 다시 연다.
