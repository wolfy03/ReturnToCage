# ReturnToCage Map Editor

Python Map Editor는 [wolfy03/ReturnToCage](https://github.com/wolfy03/ReturnToCage)의 내부 프로젝트다. 소스 위치는 `tools/python_map_editor/`, 작업 브랜치는 `feature/python-map-editor`다. 설치·빌드·배포와 개발 이력을 이 저장소에서 관리한다.

PY-STEP 5는 Python의 독립 편집을 유지하며 V4 지역 설계를 공식 Godot 4.7.2의 Scene과 RegionDefinition으로 변환한다. V1/V2 초안, V3 원본 바인딩 및 V4 지역 설계를 열 수 있다.

## 맵 편집

- 라이브러리에서 플랫폼이나 장식을 선택하고 맵으로 드래그한다. 더블클릭하면 화면 중심에 놓인다. 편집 메뉴의 **리소스 프로젝트 폴더**를 지정하면 플랫폼과 장식 기본 항목에 프로젝트 PNG가 추가된다. 이름·유형·경로로 검색할 수 있다.
- **선택(V)** 상태에서 클릭 또는 빈 곳에서 영역 드래그로 선택한다. Ctrl/Shift를 누르고 클릭해 선택을 추가하거나 제외한다. 선택을 드래그하면 함께 움직인다. 플랫폼 하나를 선택하면 모서리와 가장자리 핸들로 크기를 조절할 수 있다. Esc는 진행 중인 편집을 취소한다.
- **사각형(R)** 으로 플랫폼을 만들고, **배치(B)** 로 선택한 라이브러리 항목을 32px 간격으로 놓는다. **지우기(E)** 는 클릭 또는 드래그로 지운다. **화면 이동(H)** 또는 마우스 가운데 버튼으로 뷰포트를 움직인다. 툴바에서 격자 맞춤을 켜거나 끈다.
- 속성 패널에서 위치, 크기, 회전과 레이어를 입력한다. 플랫폼은 단방향 충돌 메타데이터를 지원한다. 장식은 PNG 경로와 배율을 지원한다. 다중 선택에서 값이 다르면 혼합 상태로 표시되고, 입력한 값은 전체 선택에 적용된다.
- 레이어 패널에서 활성 레이어, 객체 수, 표시와 잠금을 관리한다. 잠긴 레이어는 배치·수정·삭제를 허용하지 않는다. 스키마에서 레이어 ID는 참조 키다. 이 단계의 패널에서 ID를 바꾸거나 레이어를 삭제하는 기능은 제공하지 않는다.
- Ctrl+C/V로 복사·붙여넣기, Ctrl+D로 복제, Delete로 삭제한다. Ctrl+Z와 Ctrl+Shift+Z로 실행 취소·다시 실행한다. 레이어나 객체 속성 변경과 마우스 제스처는 각각 한 번의 실행 취소로 되돌린다. 저장한 이력 위치로 돌아오면 문서는 Clean이 된다.

## 지역 설계

- **지역 → 새 지역 마법사**에서 ID, 표시 이름, 너비·높이, Empty·Flat·Platform 템플릿, 환경 경로, 스폰 슬롯 1~4개를 설정한다. 플랫폼 템플릿에는 기존 `ladder_default` 위치가 설계 데이터로 표시된다. 템플릿은 Godot 원본의 1200×600 배치 좌표를 선택한 크기에 맞춰 변환한다.
- **지역 → ENTRY 배치 / ESCAPE 배치 / 스폰 배치**를 고른 뒤 Viewport를 클릭한다. 선택 도구로 마커를 끌어 옮기고 마커 탭에서 ID, 좌표, 착지 조건 또는 슬롯을 편집한다. 슬롯 표시는 1~4이며 저장된 `spawn_index`는 Godot와 같은 0~3이다. 같은 `point_id`를 ENTRY와 ESCAPE 사이에서 공유할 수 있다. 같은 종류 안의 중복은 오류다.
- **지역 연결**에서 현재 문서의 출발 ESCAPE, 목적 지역과 목적 ENTRY를 지정한다. 출발 ID는 같은 지역의 `RegionPoint.point_id` 중 ESCAPE 한 개를 참조해야 한다. 같은 문자열을 ENTRY와 ESCAPE에서 사용할 수 있다. 기존 정착지 출구의 공통 ENTRY 제약을 따라, 같은 출발 ID에 여러 목적 지역을 연결할 때는 동일한 ENTRY ID를 사용한다. 이 초안 연결은 Godot 런타임의 직접 지역 전환을 생성하지 않는다.
- 이전 V4 문서는 기존 `exit_id` 값을 그대로 읽는다. 이 필드에 `SettlementExitDefinition.id`를 사용한 연결은 실제 ESCAPE와 일치하지 않으면 오류로 표시한다. 패널에서 이전 연결을 삭제하고 출발 ESCAPE를 골라 추가할 수 있다. Godot의 정착지 출입구 정의와 게임 파일은 이 작업으로 변경되지 않는다.
- 외부 목적 지역은 **지역 문서 인덱스**에서 `.rtcmap` 파일을 선택해 확인한다. Python 검증 시 경로, SHA-256, 스키마와 지역 ID를 대조한다. 변경된 파일은 다시 인덱싱하기 전까지 `NOT EVALUATED`이며, 삭제되거나 잘못된 문서는 오류로 표시한다. 오래된 ENTRY 목록은 선택과 검증에 사용하지 않는다. 현재 열린 문서와 인덱스의 지역 ID는 Wizard 중복 검사에 반영된다.
- **환경**에서는 RegionDefinition의 `environment_path`와 `environment_loading_color`에 대응하는 값과 선택적인 Resource UID를 편집한다. `.tres`는 프로젝트 기준 `res://` 경로로 저장한다. 환경 리소스의 타입과 UID 검증은 Godot에 맡긴다.
- **배치 프리셋**에서 선택한 플랫폼·장식의 상대 좌표, 기하, 레이어와 속성을 사용자 설정에 저장하고 화면 중앙에 다시 배치한다. 배치 한 번은 한 Undo 명령이다. 기존 Godot `.tres` 프리셋은 원래 Godot 플러그인에서 사용한다.
- **보기 → Python 문서 검증**은 구조, 참조, 좌표, 슬롯 및 플랫폼 내부의 스폰 기준점 등 정적 문제를 보고한다. 결과를 클릭하면 관련 마커·객체·연결을 표시한다. 문서나 인덱스 변경으로 기존 결과는 무효화된다. Python Static, 외부 지역, Godot 런타임, 물리 및 내보내기 판정을 각각 표시한다. 전체 PASS에는 모든 영역의 검증이 필요하다. 기존 V3 Bridge Runtime 검증은 맵 전체의 물리·접근 가능성 검증을 완료하지 않으므로 물리 판정은 `NOT EVALUATED`로 유지한다.

V4의 `design`은 마커, 지역 연결 초안, 스폰, 환경 및 선택적인 사다리 앵커를 담는다. 기존 지역에서는 **Godot 지역 설계 가져오기 (V4)**로 원본의 마커·스폰·환경과 바인딩을 함께 가져온다. 기존 V3 문서에서 마커를 편집하려면 원본을 V4로 다시 가져온다. 불완전한 마커 목록으로 원본을 대체하지 않도록 V3 바인딩에 설계만 추가한 문서는 Godot가 거부한다.

새 V4 문서의 **Godot로 내보내기**는 공식 Scaffold를 기반으로 `world/adventure/<region_id>.tscn`과 `data/content/regions/<region_id>.tres`를 생성한다. Scene 재로드, 실제 스폰과 런타임 검증 결과를 확인한 뒤 두 파일의 게시 승인을 요청한다. 빈 템플릿은 물리 바닥을 배치해야 게시할 수 있다. ESCAPE 지역 연결이 포함된 문서는 연결 외 필드를 미리 검증할 수 있으며, 게임 게시 전에는 미지원 연결을 제거해야 한다. 신규 지역에 실제 정착지 진입 경로를 연결하고 지역을 해금하는 작업은 기존 게임 도구에서 수행한다.

## Godot 지역 작업

파일 메뉴에서 ReturnToCage 프로젝트 폴더, 공식 Godot 4.7.2 및 외부 작업 폴더를 설정한다. 경로 설정에는 엔진 실행이 필요 없다. **Godot 지역 가져오기**에서 등록된 지역을 선택하고 플랫폼 또는 PNG 장식을 편집한다. **Godot 내보내기 검증**으로 독립 스냅샷의 Scene 재로드 및 실제 런타임을 검사할 수 있다. **새 프로젝트 폴더로 내보내기**는 다른 위치에서 결과를 열 수 있는 프로젝트 사본을 만든다. 기존 Scene에 게시하려면 대상 경로를 확인한 뒤 **Godot로 내보내기**를 선택한다.

지원 노드와 원본 보존 정책은 [PY-STEP 5 Godot 계약](python_map_editor_step5_contract.md), [Scene 호환성](python_map_editor_scene_compatibility.md), [Godot Bridge, 게시 및 복구](python_map_editor_bridge.md)에 정리했다.

## 기존 STEP 1~7과 이전 계획

| Godot 단계 | 구현과 데이터 의존성 | Python 후속 구현 |
| --- | --- | --- |
| STEP 1 · Region 구조 | `data/definitions/region_definition.gd`의 `scene_path`, ID, ENTRY/ESCAPE 목록, 환경 참조와 `world/adventure/sewer_region.tscn`. Scene root는 서버 런타임 설정을 지원하며 Player·Enemy·Loot spawn manager와 NetworkEntityRegistry를 포함한다. `RegionDefinition.validate_field_nodes`는 authored point, enemy/gather ID, 정의 참조 및 충돌 구조를 검증한다. | Godot importer가 기존 Scene과 RegionDefinition을 함께 읽는다. 런타임 소유권, 스폰 및 네트워크 생성은 기존 Scene 구조와 서버에 맡긴다. |
| STEP 2 · Dock과 배치 | `plugin.gd`, `palette_tree.gd`, `catalog.gd`, `placement.gd`. Catalog는 EditorFileSystem에서 실제 ContentDefinition, 텍스처, 장식 Scene, 프리셋을 읽고 이름·ID·경로·분류로 검색한다. Placement는 종류별 부모와 노드를 생성하고 Canvas transform을 역변환해 배치한다. | 플랫폼과 장식을 Qt 드래그 앤 드롭으로 배치하고 QUndoStack으로 편집 이력을 관리한다. 전체 카탈로그는 이후 Godot 변환기가 제공한 데이터를 이용한다. Qt에서 PNG를 캐시하고 Godot 전용 형식은 변환기가 미리보기를 내보낸다. |
| STEP 3 · 지형 도구 | `terrain_stroke.gd`, `terrain_commands.gd`, `field_layers.gd`의 사각형·격자 페인트·지우개, 2,048 셀 제한, 충돌을 고려한 지우기와 Terrain/Decorations/SpawnPoints/GatherPoints/RegionPoints/Climbables/Background 레이어. | Select·Rectangle·Paint·Erase와 레이어 선택·잠금·표시를 제공한다. 스트로크 및 멀티 편집은 한 Undo 명령으로 묶고 기존 Qt 아이템을 재사용하고 변경된 위치와 도형을 갱신한다. |
| STEP 4 · 크기·텍스처와 저장 | `platform_resize.gd`는 핸들 위치를 Platform 로컬 transform으로 계산한다. `FieldPlatform`은 크기와 실제 Collider를 함께 관리한다. `decoration_stroke.gd`는 간격·seed·각도·scale을 기록한다. `field_maintenance.gd`는 staging, 외부 변경 감지, UID 및 Undo 충돌을 처리한다. | PY-STEP 2의 핸들·스냅은 같은 좌표 변환을 사용한다. Godot Bridge가 스테이징·재검증 및 기존 파일 보호를 담당한다. |
| STEP 5 · Wizard와 Preset | `region_wizard.gd`, `region_scaffold.tscn`, `region_recovery.gd`, `placement_preset.gd`, `preset_tools.gd`, `field_visualization.gd`. 현재 템플릿은 Empty, Flat, Platform이고 Platform은 ladder 정의에 의존한다. | 세 템플릿의 `.rtcmap` 초안과 플랫폼·장식 상대 배치 프리셋을 지원한다. |
| STEP 6 · Region Design | `level_design_dialog.gd`, `level_design.gd`, `field_maintenance.gd`, `RegionDefinition`, `SettlementExitDefinition`, `RegionPoint`, `PlayerSpawnPoint`. | Viewport와 패널에서 표식·연결·환경을 편집하고 Python에서 정적 참조를 검사한다. 실제 런타임 검증은 지원되는 V3 문서에서 실행할 수 있다. |
| STEP 7 · Traversal | `traversal_analysis.gd`와 `tools/analyze_traversal.py`가 Collider 및 실제 PlayerActor를 사용해 이동을 검증한다. | 기존 하수구 Traversal 회귀 수치를 검증한다. Python 편집기 내 Traversal Overlay는 후속 범위다. |

## 데이터와 Godot 연동 경계

1. **V2 문서.** `region_id`, `display_name`, `width`, `height`, `layers`, `objects`를 담는다. 객체에는 고유 ID, 유형, 레이어 ID, 중심 좌표, 크기, 회전(도), 종류별 메타데이터가 있다. +X는 오른쪽, +Y는 아래쪽이고 양의 각도는 화면에서 시계 방향이다. 플랫폼 크기는 Godot `FieldPlatform`처럼 중심 기준 사각형이며 핸들 크기 계산은 객체 로컬 축을 사용한다. 장식 크기는 뷰포트 치수이며 배율은 원본 PNG 크기 또는 기본 장식 크기에 대한 비율이다. 최대 32 MiB, 객체 50,000개, 레이어 128개를 허용한다. 중복 ID, 끊긴 레이어 참조, 4px 미만의 크기, 비유한 수 및 지원하지 않는 형식은 거부한다.
2. **이전과 리소스.** 명시적으로 저장할 때 V1은 V2로 기록한다. V2·V3는 지역 설계를 추가하면 V4로 저장된다. PNG는 선택한 폴더 기준 상대 경로로 저장한다. 절대 경로와 상위 폴더 탐색은 거부하며, 링크가 루트 외부를 가리키는 PNG도 표시하지 않는다. 파일이 없거나 디코딩할 수 없으면 자리표시자를 표시한다. 프로젝트 폴더 선택은 사용자 설정이며 파일에는 기록하지 않는다.
3. **Godot 변환기.** Godot 4.7.2 headless 도구가 `ResourceLoader`와 `PackedScene.instantiate()`로 허용된 프로젝트의 Scene·정의를 정규화한다. 가져온 원본과 의존 파일의 hash, UID, 노드 경로를 기록한다. 기존 맵을 편집할 때 원본 스냅샷을 기반으로 지원 필드만 Godot에서 수정한다. 알 수 없는 노드와 속성의 보존을 보장할 수 없거나 원본이 바뀌면 Export를 차단한다.
4. **게시와 검증.** 원본과 분리된 검증 사본에서 `PackedScene.pack()`과 `ResourceSaver`로 Scene·정의 쌍을 만들고 다시 읽어 `RegionDefinition`, `ContentRegistry`, 실제 Spawn 및 Runtime Load를 검증한다. 세션·SceneRouter·NetworkManager 및 서버 권위는 기존 구조를 유지한다. 최종 게시에는 대상 경로·UID·해시 검사와 기존 저널 복구 흐름을 활용한다.
5. **Traversal 연동.** `res://.godot/rtc_traversal/<32hex>/request.json`의 token, fingerprint, FPS, Scene 및 결과 경로 계약을 유지한다. 분석 아이템은 컨트롤러의 결과 검증에서 UI 의존 부분을 분리해 요청에 대응하는 JSON만 적용한다. 취소 파일과 작업 소유권으로만 프로세스를 종료하고, 편집 또는 취소 후 도착한 결과를 폐기한다. EXE 배포에서는 사용자 Python을 호출하는 대신 동결 실행 파일의 전용 worker 진입점을 사용하도록 설계한다. 이 진입점과 Godot 버전 설정 화면은 후속 구현이다.

## 후속 검증 범위

- **5 · Traversal** 실제 검증기의 Sewer 기준 표면 5개, 후보 간선 25개, Verified 간선 11개와 슬롯별 Reachability를 비교한다. Overlay 선택과 편집 중 stale 처리, 취소 및 Child 종료도 검사한다.
- **6 · 배포 검증** 객체 편집과 게임 연동을 소스 및 배포된 OneDir 양쪽에서 검증한다. 가능하면 Python 미설치 Windows에서 전체 검사를 반복하고 EXE·ZIP·가이드를 제공한다.

## 소스와 OneDir 빌드

고정 빌드 환경은 Windows x64와 Python 3.14.5다. 설치된 호환 버전을 사용했다. Qt Widgets, Graphics View 및 Qt Test는 `PySide6-Essentials`에 포함된다. PowerShell에서 프로젝트 루트로 이동해 다음을 실행한다.

```powershell
python -m venv build/python-map-editor/venv
$editorPython = "./build/python-map-editor/venv/Scripts/python.exe"
& $editorPython -m pip install -r tools/python_map_editor/requirements.txt
& $editorPython -m pytest tools/python_map_editor/tests -q -p no:cacheprovider
& $editorPython tools/python_map_editor/main.py
& ./tools/python_map_editor/build_windows.ps1 -Python $editorPython
```

빌드 스크립트가 고유 폴더에 EXE, `_internal`, README, 라이선스 안내 및 ZIP을 생성한다. 배포 ZIP 전체를 풀고 `ReturnToCageMapEditor.exe`를 시작한다. 일반 편집에는 외부 Python이나 Godot이 필요하지 않다.

`--smoke-report <path.json>`는 실제 Qt 창을 열어 Qt 마우스·키보드·드롭 이벤트를 보내 편집 도구, 저장·재열기 및 설정 복원을 검사하고 1,000개 객체 측정값과 스크린샷을 기록한다. 레이어와 일부 설정 검사는 위젯 상태를 직접 변경한다. EXE 검증은 배포본을 별도 폴더에 풀고 Python·Qt 환경 변수를 제거한 뒤 시스템 전용 PATH로 실행한다. Qt 배율 100%, 150%, 200%에서 편집 후 EXE를 종료한 다음, 별도 EXE 프로세스로 V2 문서·PNG와 V4 지역 설계 문서를 각각 다시 읽는다. V4 생성 테스트는 Godot 경로 없이 실행하며 Bridge 자식 프로세스 생성이 0회였는지 확인한다.

```powershell
& $editorPython tools/python_map_editor/verify_windows_package.py "<빌드 ZIP>" --artifacts build/python-map-editor/qa
```

`.rtcmap` 초안은 같은 폴더에 임시 파일을 쓰고 flush 후 원자적으로 게시한다. 작성자는 대상 옆의 `.<filename>.lock` 파일에 OS 잠금을 잡고 저장 직전에 문서 revision을 다시 확인한다. 빈 잠금 파일은 다음 작성자와 같은 파일을 사용하기 위해 남기며 OS 잠금은 프로세스 종료 시 해제된다. 이 규약을 사용하는 작성자 간에 협력적으로 보호한다. 외부 프로그램이 잠금을 사용하지 않으면 마지막 해시 확인과 교체 사이의 좁은 구간에 파일을 바꿀 수 있다. 정상 예외 경로는 임시 파일을 정리하며, 프로세스를 강제로 종료하면 임시 파일이 남을 수 있다. Godot Scene 게시용 백업과 복구 저널은 Godot Bridge가 별도로 관리한다.

다른 이름으로 저장은 선택한 기존 파일의 revision을 기록하고 덮어쓰기 확인을 표시한다. 사용자가 승인한 후 대상이 이동·삭제·수정되면 저장을 차단한다. 실패와 취소 시 열린 문서 경로와 최근 폴더가 유지된다. 읽기 전용 파일 및 심볼릭 링크·정션 경로를 보호한다.

GitHub Actions의 **Python Map Editor** 워크플로는 경로 변경을 감지해 문서 테스트, 100%·150%·200% Qt 스모크, Godot 4.7.2 왕복 검사, OneDir 빌드 및 압축을 푼 EXE 검증을 수행한다. 통과한 ZIP과 검증 로그는 Actions Artifacts에서 받을 수 있다. 게임 배포와 Python 에디터 배포는 별도 자산이다.

## 별도 저장소 이전

이전 공개 저장소는 [wolfy03/ReturnToCageMapEditor](https://github.com/wolfy03/ReturnToCageMapEditor)다. 사용을 중단하고 이 저장소의 기능 브랜치에서 계속 개발한다. 해당 저장소의 `main` 끝 `6b7ad1bda7be312641f69e8b8b7ee7be804b96c8`에는 단일 초기 커밋이 있다. 에디터 소스, 테스트, 문서, 빌드와 라이선스 파일은 원본 `fd59f9f`와 동일했다. 별도 저장소 전용 README의 실행 절차를 이 문서에 반영했고, 그 초기 커밋은 기능 브랜치 이력에 보존한다. 별도 저장소에서 태그, Releases, Actions 워크플로·아티팩트, Issues, Pull Requests, LFS 항목은 발견되지 않았다. 전체 Git 번들, 메타데이터, 기존 로컬 배포 ZIP과 SHA-256 기록은 상위 `validation/python-map-editor-consolidation`에 있다. 별도 저장소 삭제는 승인 대기 상태다.

## PY-STEP 1 검증 기록

- Windows 11 Pro x64 빌드 26200에서 pytest 16개와 소스의 Windows Qt 스모크 7개를 통과했다.
- 초기 OneDir 실행은 호스트의 다른 도구에서 유입된 ICU DLL이 QtCore의 unsuffixed import를 제공하지 못해 실패했다. 빌드 경로를 제한하고 spec에서 OS ICU와 충돌하는 번들 파일을 제외했다. 기존 실패 자료는 상위 `validation/python-map-editor-step1/package-qa`에 별도로 보존했다.
- 수정한 EXE의 Windows Qt 스모크는 배포 ZIP을 저장소 밖에 풀고 별도 작업 디렉터리·사용자 데이터 및 시스템 전용 PATH로 실행했다. 번들 Python과 windowed PE 서브시스템을 확인했다. 실제 Windows 입력 검사에서는 일반 실행의 격자 켜기·끄기, 100% 줌과 창 닫기를 확인했다. 물리적으로 Python이 설치되지 않은 별도 PC 검증은 수행하지 않았다.
- Qt 라이선스 본문은 [Qt 6.11.3 소스의 LICENSES](https://github.com/qt/qtbase/tree/v6.11.3/LICENSES)에서 가져왔다.

## PY-STEP 2 검증 기록

Windows 11 x64에서 pytest 52개 중 51개가 통과했다. Windows 심볼릭 링크 생성 권한이 필요한 기존 검사 한 건은 로컬에서 건너뛰며 Ubuntu CI에서 실행된다. Qt 100%·150%·200% 각 환경에서 소스와 배포 EXE가 각각 63개 검사를 통과했다. 배포 EXE는 각 배율에서 편집·저장 후 종료 코드 0으로 닫혔고, 새 프로세스가 한글 경로의 문서와 PNG를 읽은 후 종료 코드 0을 반환했다. Windows PE의 GUI 서브시스템과 포함된 Python 런타임도 확인했다. Python 미설치 별도 PC 검증은 수행하지 않았다.

1,000개 플랫폼을 담은 테스트 문서의 Windows 배포본 측정값이다. 각 수치는 작업을 한 번 실행하고 Qt 이벤트를 처리한 결과이며 단위는 ms다.

| Qt 배율 | 로드 | 선택 | 줌 | 화면 이동 | 저장 | 재열기 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100% | 54.19 | 15.84 | 15.09 | 14.69 | 24.04 | 58.85 |
| 150% | 57.49 | 18.50 | 17.60 | 16.33 | 23.85 | 59.21 |
| 200% | 57.49 | 18.45 | 18.60 | 15.00 | 29.67 | 56.35 |
