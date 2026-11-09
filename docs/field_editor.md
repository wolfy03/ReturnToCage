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
  동일 스트로크와 기존 FieldPlatform 중심 셀의 중복을 건너뛴다. 스트로크당
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
FieldPlatform이 준비된 후 확인한다. 뷰포트 크기 조절 핸들은 후속 작업이며,
현재 크기 편집은 Inspector를 사용한다.
