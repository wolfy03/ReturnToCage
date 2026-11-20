# ReturnToCage Map Editor

Python Map Editor는 [wolfy03/ReturnToCage](https://github.com/wolfy03/ReturnToCage)의 내부 프로젝트다. 소스 위치는 `tools/python_map_editor/`, 작업 브랜치는 `feature/python-map-editor`다. 설치·빌드·배포와 개발 이력을 이 저장소에서 관리한다.

PY-STEP 1은 독립 2D 문서 편집 기반이다. 한국어 다크 테마, 맵 구조와 속성 도크, 영역 경계와 32px 격자, Godot과 같은 X 오른쪽·Y 아래쪽 좌표, 커서 기준 줌, 가운데 버튼 드래그 및 이동 모드, 화면 맞춤을 제공한다. 문서의 지역 ID, 표시 이름, 너비와 높이를 바꾸고 `.rtcmap` JSON으로 저장하거나 다시 열 수 있다. 창 배치, 도크, 격자 표시, 마지막 파일 폴더를 사용자 설정에 저장한다. Godot 실행이나 프로젝트 선택 없이 사용할 수 있다.

## 기존 STEP 1~7과 이전 계획

| Godot 단계 | 구현과 데이터 의존성 | Python 후속 구현 |
| --- | --- | --- |
| STEP 1 · Region 구조 | `data/definitions/region_definition.gd`의 `scene_path`, ID, ENTRY/ESCAPE 목록, 환경 참조와 `world/adventure/sewer_region.tscn`. Scene root는 서버 런타임 설정을 지원하며 Player·Enemy·Loot spawn manager와 NetworkEntityRegistry를 포함한다. `RegionDefinition.validate_field_nodes`는 authored point, enemy/gather ID, 정의 참조 및 충돌 구조를 검증한다. | PY-STEP 3에서 Godot importer가 기존 Scene과 RegionDefinition을 함께 읽는다. 런타임 소유권, 스폰 및 네트워크 생성은 기존 Scene 구조와 서버에 맡긴다. |
| STEP 2 · Dock과 배치 | `plugin.gd`, `palette_tree.gd`, `catalog.gd`, `placement.gd`. Catalog는 EditorFileSystem에서 실제 ContentDefinition, 텍스처, 장식 Scene, 프리셋을 읽고 이름·ID·경로·분류로 검색한다. Placement는 종류별 부모와 노드를 생성하고 Canvas transform을 역변환해 배치한다. | PY-STEP 2에서 알려진 플랫폼·장식과 같은 제한된 객체부터 Qt 드래그 앤 드롭과 QUndoStack을 제공한다. 전체 카탈로그는 이후 Godot 변환기가 제공한 데이터를 이용한다. Qt에서 PNG를 캐시하고 Godot 전용 형식은 변환기가 미리보기를 내보낸다. |
| STEP 3 · 지형 도구 | `terrain_stroke.gd`, `terrain_commands.gd`, `field_layers.gd`의 사각형·격자 페인트·지우개, 2,048 셀 제한, 충돌을 고려한 지우기와 Terrain/Decorations/SpawnPoints/GatherPoints/RegionPoints/Climbables/Background 레이어. | PY-STEP 2에서 Select·Rectangle·Paint·Erase와 선택/잠금/표시를 구현한다. 스트로크 및 멀티 편집은 한 Undo 명령으로 묶고 변경된 Qt 아이템만 갱신한다. |
| STEP 4 · 크기·텍스처와 저장 | `platform_resize.gd`는 핸들 위치를 Platform 로컬 transform으로 계산한다. `FieldPlatform`은 크기와 실제 Collider를 함께 관리한다. `decoration_stroke.gd`는 간격·seed·각도·scale을 기록한다. `field_maintenance.gd`는 staging, 외부 변경 감지, UID 및 Undo 충돌을 처리한다. | PY-STEP 2의 핸들·스냅은 같은 좌표 변환을 사용한다. PY-STEP 3에서 Godot staging·재검증 및 기존 파일 보호를 추가한다. |
| STEP 5 · Wizard와 Preset | `region_wizard.gd`, `region_scaffold.tscn`, `region_recovery.gd`, `placement_preset.gd`, `preset_tools.gd`, `field_visualization.gd`. 현재 템플릿은 Empty, Flat, Platform이고 Platform은 ladder 정의에 의존한다. ID 중복, ENTRY/ESCAPE, 1~4 슬롯, 환경 및 양쪽 파일 경로를 검사하고 저널로 Scene/Resource 쌍을 복구한다. | PY-STEP 4 Wizard는 문서만 만든다. 공식 템플릿을 먼저 이전하고 Climbable과 Exploration은 동일한 런타임 형식과 검증을 충족하는 별도 초안 템플릿으로 추가한다. 프리셋 참조와 배치 좌표는 기존 의미를 유지한다. |
| STEP 6 · Region Design | `level_design_dialog.gd`, `level_design.gd`, `field_maintenance.gd`. SettlementExitDefinition의 목적지 지역·ENTRY, RegionPoint의 종류·ID, PlayerSpawnPoint 인덱스, EnvironmentDefinition 경로가 서로 연결된다. `tools/playtest_region.py`와 `tests/editor/field_runtime_probe.tscn`은 실제 게임 및 물리 검증을 수행한다. | PY-STEP 4에서 Inspector/Viewport 양쪽으로 표식을 편집하고 연결 참조를 확인한다. 실제 Spawn Safety, Runtime Load와 Gameplay Playtest는 격리된 Godot 프로세스에서 실행한다. |
| STEP 7 · Traversal | `traversal_analysis.gd`가 합성된 world transform과 Collider를 읽어 후보 그래프를 만든다. `traversal_controller.gd`가 스냅샷, SHA fingerprint, 요청·취소 및 stale result를 관리한다. `tools/analyze_traversal.py`가 Job Object로 `tests/editor/traversal_physics.tscn`을 실행하며 실제 PlayerActor 입력으로 간선·슬롯·ESCAPE 경로를 검증한다. | PY-STEP 5에서 Qt worker가 Godot 변환기로 동일한 요청을 준비하고 검증기 결과를 렌더링한다. Candidate, Verified 및 Not Evaluated를 구분한다. |

## 데이터와 Godot 연동 경계

1. **순수 Python 문서.** `document.py`의 schema 1은 `schema_version`, `region_id`, `display_name`, `width`, `height`만 담는다. 알 수 없는 버전과 필드를 거부한다. Qt는 이 모델을 편집하고 파일 확장자는 `.rtcmap`으로 제한한다. 화면 픽셀과 월드 위치는 Qt Graphics View가 변환한다.
2. **후속 schema.** 객체 ID, 부모 관계, 2×3 affine transform, 종류별 속성, 레이어, 자원 참조, 지역 연결 및 환경이 필요하다. 새 버전은 기존 schema 1의 기본 정보를 명시적으로 마이그레이션한다. 회전·비균등 스케일·중첩 transform은 Godot 로드 시 저장한 local transform과 부모 계층을 이용하며 합성 world transform은 계산값으로 취급한다.
3. **Godot 변환기.** Godot 4.7.2 headless 도구가 `ResourceLoader`와 `PackedScene.instantiate()`로 허용된 프로젝트의 Scene·정의를 정규화한다. 가져온 원본과 의존 파일의 hash, UID, 노드 경로를 기록한다. 기존 맵을 편집할 때 원본 스냅샷을 기반으로 지원 필드만 Godot에서 수정한다. 알 수 없는 노드와 속성의 보존을 보장할 수 없거나 원본이 바뀌면 Export를 차단한다.
4. **게시와 검증.** 원본과 분리된 검증 사본에서 `PackedScene.pack()`과 `ResourceSaver`로 Scene·정의 쌍을 만들고 다시 읽어 `RegionDefinition`, `ContentRegistry`, 실제 Spawn 및 Runtime Load를 검증한다. 세션·SceneRouter·NetworkManager 및 서버 권위는 기존 구조를 유지한다. 최종 게시에는 대상 경로·UID·해시 검사와 기존 저널 복구 흐름을 활용한다.
5. **Traversal 연동.** `res://.godot/rtc_traversal/<32hex>/request.json`의 token, fingerprint, FPS, Scene 및 결과 경로 계약을 유지한다. 분석 아이템은 컨트롤러의 결과 검증에서 UI 의존 부분을 분리해 요청에 대응하는 JSON만 적용한다. 취소 파일과 작업 소유권으로만 프로세스를 종료하고, 편집 또는 취소 후 도착한 결과를 폐기한다. EXE 배포에서는 사용자 Python을 호출하는 대신 동결 실행 파일의 전용 worker 진입점을 사용하도록 설계한다. 이 진입점과 Godot 버전 설정 화면은 후속 구현이다.

## PY-STEP 2~6 완료 기준

- **2 · 기본 편집** 플랫폼과 장식을 Qt Viewport에서 추가·선택·복제·이동·크기 변경·삭제하고, 레이어와 Undo/Redo가 입력 한 번 단위로 동작한다.
- **3 · 왕복 변환** 복제한 Sewer의 노드 transform, 충돌 및 UID/참조를 비교하고 변환된 Scene·Resource를 기존 런타임에서 연다. 이때 백업, 외부 변경 비교, 자동 복구를 추가한다.
- **4 · 지역과 Playtest** 새 지역 Wizard, 호환 프리셋, 연결·ENTRY/ESCAPE·스폰·환경을 편집하고 실제 런타임 로드와 Spawn Safety를 검사한다.
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

빌드 스크립트가 고유 폴더에 EXE, `_internal`, README, 라이선스 안내 및 ZIP을 생성한다. 배포 ZIP 전체를 풀고 `ReturnToCageMapEditor.exe`를 시작한다. 외부 Python 및 Godot은 PY-STEP 1 실행 조건에 포함되지 않는다.

`--smoke-report <path.json>`는 실제 Qt 창을 열어 Qt 기반 입력 자동화로 줌·이동·속성 편집·저장·재열기·설정 복원을 검사하고 스크린샷을 기록한다. EXE 검증은 별도 위치에서 배포본을 풀고 Python·Qt 환경 변수와 외부 실행 경로를 제거한 환경에서 수행한다.

```powershell
& $editorPython tools/python_map_editor/verify_windows_package.py "<빌드 ZIP>" --artifacts build/python-map-editor/qa
```

`.rtcmap` 초안은 같은 폴더에 임시 파일을 쓰고 flush 후 원자적으로 게시한다. 작성자는 대상 옆의 `.<filename>.lock` 파일에 OS 잠금을 잡고 저장 직전에 문서 revision을 다시 확인한다. 빈 잠금 파일은 다음 작성자와 같은 파일을 사용하기 위해 남기며 OS 잠금은 프로세스 종료 시 해제된다. 이 규약을 사용하는 작성자 간에 협력적으로 보호한다. 외부 프로그램이 잠금을 사용하지 않으면 마지막 해시 확인과 교체 사이의 좁은 구간에 파일을 바꿀 수 있다. 정상 예외 경로는 임시 파일을 정리하며, 프로세스를 강제로 종료하면 임시 파일이 남을 수 있다. 백업 저널은 PY-STEP 3의 범위다.

다른 이름으로 저장은 선택한 기존 파일의 revision을 기록하고 덮어쓰기 확인을 표시한다. 사용자가 승인한 후 대상이 이동·삭제·수정되면 저장을 차단한다. 실패와 취소 시 열린 문서 경로와 최근 폴더가 유지된다. 읽기 전용 파일 및 심볼릭 링크·정션 경로를 보호한다.

GitHub Actions의 **Python Map Editor** 워크플로는 경로 변경을 감지해 문서 테스트, 150% Qt 스모크, OneDir 빌드와 압축을 푼 EXE 실행을 수행한다. 통과한 ZIP과 검증 로그는 Actions Artifacts에서 받을 수 있다. 게임 배포와 Python 에디터 배포는 별도 자산이다.

## 별도 저장소 이전

이전 공개 저장소는 [wolfy03/ReturnToCageMapEditor](https://github.com/wolfy03/ReturnToCageMapEditor)다. 사용을 중단하고 이 저장소의 기능 브랜치에서 계속 개발한다. 해당 저장소의 `main` 끝 `6b7ad1bda7be312641f69e8b8b7ee7be804b96c8`에는 단일 초기 커밋이 있다. 에디터 소스, 테스트, 문서, 빌드와 라이선스 파일은 원본 `fd59f9f`와 동일했다. 별도 저장소 전용 README의 실행 절차를 이 문서에 반영했고, 그 초기 커밋은 기능 브랜치 이력에 보존한다. 별도 저장소에서 태그, Releases, Actions 워크플로·아티팩트, Issues, Pull Requests, LFS 항목은 발견되지 않았다. 전체 Git 번들, 메타데이터, 기존 로컬 배포 ZIP과 SHA-256 기록은 상위 `validation/python-map-editor-consolidation`에 있다. 별도 저장소 삭제는 승인 대기 상태다.

## PY-STEP 1 검증 기록

- Windows 11 Pro x64 빌드 26200에서 pytest 16개와 소스의 Windows Qt 스모크 7개를 통과했다.
- 초기 OneDir 실행은 호스트의 다른 도구에서 유입된 ICU DLL이 QtCore의 unsuffixed import를 제공하지 못해 실패했다. 빌드 경로를 제한하고 spec에서 OS ICU와 충돌하는 번들 파일을 제외했다. 기존 실패 자료는 상위 `validation/python-map-editor-step1/package-qa`에 별도로 보존했다.
- 수정한 EXE의 Windows Qt 스모크는 배포 ZIP을 저장소 밖에 풀고 별도 작업 디렉터리·사용자 데이터 및 시스템 전용 PATH로 실행했다. 번들 Python과 windowed PE 서브시스템을 확인했다. 실제 Windows 입력 검사에서는 일반 실행의 격자 켜기·끄기, 100% 줌과 창 닫기를 확인했다. 물리적으로 Python이 설치되지 않은 별도 PC 검증은 수행하지 않았다.
- Qt 라이선스 본문은 [Qt 6.11.3 소스의 LICENSES](https://github.com/qt/qtbase/tree/v6.11.3/LICENSES)에서 가져왔다.
