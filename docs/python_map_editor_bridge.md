# Python Map Editor Godot Bridge

## 실행과 문서

ZIP을 풀고 `ReturnToCageMapEditor.exe`를 실행한다. **파일 → Godot 프로젝트 설정**에서 전체 ReturnToCage 체크아웃, 공식 Godot `4.7.2.stable.official.ed1daf0bf` 실행 파일 및 프로젝트 외부의 작업·로그 폴더를 지정한다. 설정 화면은 경로만 검사해 저장한다. 엔진 버전과 ContentRegistry는 사용자가 가져오기를 요청하면 확인한다. Windows 콘솔 런처를 선택하면 같은 폴더의 실제 엔진 바이너리를 사용한다.

**Godot 지역 가져오기**에서 등록된 RegionDefinition을 선택한다. 가져온 문서의 지역 ID와 이름은 읽기 전용이다. 플랫폼과 PNG 장식을 편집한 뒤 `.rtcmap`으로 저장할 수 있다. **Godot 내보내기 검증**은 스테이징과 런타임 검사까지 수행한다. **Godot로 내보내기**는 대상 Scene 경로를 표시하고 확인을 받은 뒤 기존 프로젝트에 게시한다. **새 프로젝트 폴더로 내보내기**는 새 폴더에 검증된 게임 프로젝트 사본을 만든다. 게시한 V3 문서에서 새 원본 지문을 사용하려면 `.rtcmap`을 다시 저장한다.

독립 문서는 기존 V1/V2를 읽고 V2로 저장한다. 가져온 지역은 V3이며 프로젝트 지문, 원본 Scene/RegionDefinition 경로·SHA-256·UID, 노드 ID, 상대 경로, 부모, 로컬·월드 Transform2D 및 충돌 레이어·마스크를 저장한다. 기존 노드 ID는 지역 ID, NodePath, 실제 클래스 또는 Script 경로의 조합에서 파생한다. 새 노드는 `rtc_map_object_id` 메타데이터로 ID를 유지한다. V4에서 추가한 마커, 연결, 환경 및 스폰 설계는 `.rtcmap`에 저장한다. V4 문서의 검증·게시·Export As를 요청하면 Bridge 실행 전에 `UNSUPPORTED_NODE`로 차단한다. Scene 변환을 지원하는 범위는 기존 V3 계약과 같다.

## 실행 계약

Python은 프로젝트의 적격 리소스 트리를 복제하고 복사본의 해시를 실제 원본과 확인한다. 캐시와 Git 메타데이터, 배포 프리셋, 문서 및 Python 에디터 소스는 게임 복사 범위에서 제외한다. 작업 디렉터리와 Godot 사용자 데이터, .godot 캐시를 원본과 분리한다. 리소스 파일을 초기 Import한 후 Godot Bridge를 아래와 같이 실행한다. 이 예에서 요청·결과 경로는 작업 디렉터리 안에 있으며 Bridge 파일은 사본의 `tools/map_bridge/`에 있다.

```text
Godot.exe --headless --path <project-copy> --log-file <log> --scene res://tools/map_bridge/bridge.tscn -- --request <request.json>
```

요청은 protocol 1, request_id, operation, 결과 경로와 입력 데이터를 가진다. 결과는 요청 ID·프로토콜, 명령, PASS/FAIL, Godot 버전, 오류 코드, 경고 및 명령별 요약을 반환한다.

| 명령 | 검증 및 출력 |
| --- | --- |
| `inspect_project` | ContentRegistry의 지역 ID, 이름, Definition 및 Scene 경로 |
| `inspect_region`, `import_region` | Scene 및 RegionDefinition UID/지문, 편집 대상·원본 transform 및 전체 노드 상태 |
| `validate_document` | 원본 바인딩을 대조하고 편집 명령을 메모리에서 적용하여 검사 |
| `export_region` | 복사본의 원본 기반 Scene 편집, PackedScene/ResourceSaver 스테이징, 예상 상태와 해시 |
| `validate_export` | 새 프로세스에서 재로드하여 계층·순서·Owner·스크립트·저장 속성·연결·리소스 공유와 UID를 대조하고 초기화된 플랫폼 충돌을 확인 |

Python은 요청 및 버전 일치, 종료 코드 0, 구조화된 PASS 결과와 산출물 해시를 요구한다. 게임 지역의 실제 로딩, 스폰 및 월드 흐름은 별도 기존 `field_runtime_probe.tscn`에서 확인한다. Godot 프로세스 로그와 종료 코드는 보존한다. `0xC0000005`와 같은 엔진 오류는 결과 파일이 있어도 실패이며 게시하지 않는다. 작업 취소·타임아웃에는 소유한 프로세스만 종료하며 Windows에서 Traversal의 Job Object를 사용한다. 선택한 엔진 또는 시간 한도를 자동으로 변경하지 않는다.

## 게시 및 복구

PY-STEP 3의 게시 단위는 Scene 한 파일이다. RegionDefinition, 외부 참조 및 UID를 검증하고 Definition 파일을 그대로 둔다. 내보낼 객체가 바뀌지 않았으면 원본 Scene 바이트를 보존하고 독립 프로세스에서 다시 읽어 의미 구조와 런타임을 검사한다.

실제 게시 시 프로젝트의 숨김 폴더 `.rtc-map-publish`에 파일별 원본 백업과 준비 상태 저널을 기록한다. 파일과 전체 프로젝트 해시를 확인하고 같은 볼륨의 임시 파일로 원자적으로 교체한다. 사후 확인 실패 시 승인된 출력 해시일 때만 백업을 복원한다. 다음 실행에서 준비 저널이 남아 있으면 현재 파일이 검증된 출력인지 원본인지 판단해 기록을 마무리한다. 두 해시 모두 다르면 외부 변경을 보호하고 진행을 중단한다. 다른 편집기가 프로젝트 잠금 규약을 사용하지 않으면 마지막 확인 직후 수정할 가능성이 있으므로, Godot의 동일 Scene을 닫은 상태에서 게시하는 편이 안전하다.

Export As는 새 경로에 완성된 검증 복사본을 게시하며 기존 대상 폴더가 있으면 거부한다. 사용자 프로필과 테스트 캐시는 사본에서 제외한다.

## 오류

| 코드 | 의미 |
| --- | --- |
| `INVALID_DOCUMENT` | 문서 스키마, 입력 또는 V3 원본 바인딩 오류 |
| `INVALID_PROJECT`, `INVALID_GODOT_PATH`, `GODOT_VERSION_MISMATCH` | 프로젝트 구성이나 공식 실행 파일 확인 실패 |
| `RESOURCE_MISSING` | RegionDefinition, Scene, PNG 또는 의존 리소스 누락 |
| `UNSUPPORTED_NODE`, `UNSUPPORTED_TRANSFORM` | 지원 대상 범위를 벗어난 노드 또는 transform. 원본 보존 여부와 함께 경고하거나 게시를 차단한다. |
| `SOURCE_MODIFIED`, `UID_CONFLICT` | 원본·리소스 변경, 복구 시 외부 변경, UID 불일치 |
| `EXPORT_FAILED`, `RUNTIME_LOAD_FAILED` | 스테이징·재로드·게시 또는 실제 게임 초기화 실패 |
| `PROCESS_CRASH`, `INVALID_RESPONSE`, `TIMEOUT`, `CANCELLED` | 종료 코드, 엔진 로그, JSON 계약 또는 작업 종료 상태 오류 |

## 검증 명령

```powershell
python -m pytest tools/python_map_editor/tests -q -rs
python tools/python_map_editor/check_scene_bridge.py --godot "<4.7.2 실행 파일>" --artifacts "<프로젝트 외부 로그 폴더>"
python tools/python_map_editor/verify_windows_package.py "<배포 ZIP>" --artifacts "<검증 로그>" --bridge-project . --godot "<4.7.2 실행 파일>"
```

통합 fixture는 별도 복사본에서 하수구를 가져오고 무편집·편집 왕복, UID가 있는 중첩 장식, 반전 장식 보존, 새 플랫폼, PNG 누락 차단과 게시·복구를 검사한다. Traversal 회귀는 기존 실제 PlayerActor 검증기를 사용한다. 기존 EditorPlugin과 달리 이 단계의 Python GUI는 지역 생성, 연결, ENTRY/ESCAPE, 스폰 편집 및 Traversal/Playtest UI를 제공하지 않는다.

[Scene 호환성](python_map_editor_scene_compatibility.md) · [설치 및 편집](python_map_editor.md)

### Windows 검증 기록

- 공식 Godot 4.7.2에서 하수구 원본과 무편집 결과 모두 46개 노드였고, 기존 Traversal 결과는 표면 5개·후보 간선 25개·검증 간선 11개였다. WestPlatform을 옮기고 넓힌 별도 실행에서는 46개 노드를 유지했고 변경은 해당 플랫폼·CollisionShape2D·Visual에 한정됐다. 편집 후 실제 Traversal 결과는 5·26·14였다.
- UID를 붙인 추가 fixture에서 50개 노드를 유지했다. 중첩 PNG 장식, 반전 장식 보존, 기존 플랫폼 삭제 및 새 FieldPlatform 추가, 두 UID와 RegionDefinition 해시 유지, 누락 PNG 게시 차단을 검증했다.
- 로컬 Windows pytest는 69개 통과, 심볼릭 링크 생성 권한이 필요한 기존 1개 검사는 건너뛰었다. 소스와 OneDir 배포본에서 Qt 100%·150%·200%의 독립 편집 검사 71개를 각각 통과했다. 시스템 전용 PATH에서 실행한 배포 EXE는 별도 한글 경로 프로젝트의 Godot 연동 검사 13개와 종료 코드 0을 기록했다. Python 미설치 별도 PC는 사용하지 않았다.
- 1,000개 객체를 대상으로 각 측정을 3회 수행했다. 배포본 150%의 중앙값/최대값(ms)은 fixture 생성 5.16/6.84, 읽기 12.23/13.07, 디코딩 10.68/20.07, Qt Scene 구성 61.64/72.65, 선택 29.15/41.89, 줌 21.72/24.89, Pan 18.28/21.73, 저장 18.84/19.19, 재열기 97.73/112.38이었다.
- 공식 Godot에서 별도 검증 실행의 Bridge 종료와 Traversal fixture 준비 종료에 `0xC0000005`가 발생했다. 해당 실행은 실패로 기록했고 게시를 차단했다. 정상 실행과 비정상 실행의 요청, 결과, Godot 로그 및 종료 코드는 상위 `validation/python-map-editor-step3`에 각각 보존했다. 성공 시나리오를 확인했으며 반복 네이티브 안정성은 BLOCKED다.
