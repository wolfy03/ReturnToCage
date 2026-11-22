# PY-STEP 3 Windows 네이티브 종료 조사

## 성공·실패 CI 비교

| 항목 | 성공 실행 44999918220 | 실패 실행 45000079400 |
| --- | --- | --- |
| Git SHA | `cac521ef8dd5cdec7db477c995f1c640281b910b` | `a3c49de5ae4a8e3b1c53244b0a0ee650b456bc0a` |
| Windows / Runner | Server 2025 Datacenter 10.0.26100, windows-2025-vs2026 20261116.315.1 | 동일 |
| 엔진 다운로드 | 공식 4.7.2 Windows x64, 양쪽 ZIP SHA-256 `731980f9608d61333e5baf54a2ef17210acc7a538446c0cb9969f002aca1e953` 검증 | 동일 |
| 실행 파일 및 버전 | 로컬 공식 EXE SHA-256 `ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424`, 버전 `4.7.2.stable.official.ed1daf0bf`. 당시 각 Runner의 별도 EXE 해시 출력은 UNKNOWN | 동일 ZIP 체크섬으로 확인. 당시 별도 EXE 해시 출력은 UNKNOWN |
| Python·Qt·빌드 도구 | Python 3.14.5 x64, PySide6-Essentials 6.11.3, PyInstaller 6.22.3 | 동일 |
| 프로세스 환경 | 사본을 `--path`와 CWD로 사용. `APPDATA`, `LOCALAPPDATA`, `HOME`, XDG 디렉터리를 작업별로 분리. EXE 검증은 시스템 전용 PATH | 동일 규칙. 임시 경로와 PID는 다름. 전체 환경 변수와 CPU 모델은 UNKNOWN |
| Godot 캐시와 인수 | 원본 `.godot` 제외, 사본에서 `--headless --editor --recovery-mode --import` 후 `--scene res://tools/map_bridge/bridge.tscn -- --request …` | 동일. 실제 캐시 바이트는 UNKNOWN |
| 결과 | 통합·EXE 성공 | 통합 PID 1144와 EXE PID 6644 모두 `validate_export` 결과 JSON PASS 후 코드 3221225477로 종료 |

두 SHA 사이에는 `docs/python_map_editor_bridge.md`만 변경됐다. 실패한 통합은 무편집 하수구, EXE 실패는 편집된 프로젝트 사본이었다. 두 실행 모두 게시가 차단됐다. [성공 실행](https://github.com/wolfy03/ReturnToCage/actions/runs/44999918220) · [실패 실행 및 증거](https://github.com/wolfy03/ReturnToCage/actions/runs/45000079400)

## 재현과 콜스택

Windows 11 x64 빌드 26200.9974에서 공식 EXE로 조사했다. 일반 실행에서 초기 Import가 한 번 결과를 쓴 뒤 크래시했다. 같은 사본에서 별도로 반복한 기존 무편집 `validate_export`는 50/50 정상 종료했다. 이 반복은 초기 실패와 다른 시도이며, 변경 전 코드에서도 단일 조건의 50회 통과가 가능함을 보여 준다.

ProcDump가 관리한 공식 EXE에서 `validate_export`와 `import_region`의 읽기 예외 `0xC0000005`를 각각 캡처했다. 로컬 증거의 위치는 상위 `validation/python-map-editor-stability/native-dumps/`다. 대표 `validate_export` 덤프 `Godot_v4.7.2-stable_win64.exe_261122_201211.dmp`의 스레드는 28312다. 실패 모듈은 공식 Godot EXE, 예외 RVA는 `0x3e2d181`이었다. 두 덤프 모두 정리 중 레지스터가 `0xfeeefeeefeeefeee`를 가리켰다. 공식 배포 자산에서 일치하는 PDB를 찾지 못했다. 동일 EXE의 x64 unwind 정보로 확보한 프레임은 다음과 같다.

```text
godot+0x3e2d181  reference counter read
godot+0x3e2d29d  reference initialization
godot+0x547f41   script iteration (matched to source by disassembly)
godot+0x3e3baf8
godot+0x60539
```

`0x547ee0` 함수의 종료 재진입 플래그, 캐시 정리 호출, SelfList 첫 링크와 `self()` 읽기, Ref 초기화 순서가 공식 소스의 `GDScriptLanguage::finish()`와 일치한다. 기존 별도 심볼 빌드의 스택에서는 같은 접근이 `GDScriptLanguage::finish → ScriptServer::finish_languages → Main::cleanup`으로 확인됐다. 공식 빌드 덤프로 정확히 어느 GDScript 파일이 먼저 해제됐는지는 확인하지 못했다. [기존 심볼 진단](step7_stability_round2.md) · [4.7.2 GDScript 소스](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/modules/gdscript/gdscript.cpp)

같은 공식 실행 파일·프로젝트 사본을 ProcDump로 실행한 A/B에서 기존 코드는 Import 3/3, Validation 3/3이 비정상 종료했다. 캐시된 Script와 base refs를 보존하는 변경만 적용한 실험은 각각 3/3 정상 종료했다. 디버거 실행과 일반 실행은 힙 동작이 다를 수 있으므로 두 재현율을 합산하지 않는다.

## 변경과 안전성

Bridge 전용 프로세스는 캐시에 이미 있는 등록 Script와 그 base에 강한 참조를 유지한다. 공식 Windows 4.7.2에서만 빈 native `ImageFormatLoaderExtension` 객체가 참조를 소유한다. 이 객체는 이미지 형식이나 로드 콜백을 등록하지 않는다. `ImageLoader::cleanup()`은 `ScriptServer::finish_languages()` 뒤, GDScript 모듈 해제 전에 실행된다. 엔진은 그 지점에서 해당 참조를 정상 해제한다. 이 방식은 참조 수명만 바꾸며 공식 바이너리, Scene 파일, 게임 Autoload 및 검증 규칙을 바꾸지 않는다. [4.7.2 정리 순서](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/main/main.cpp)

Bridge는 충돌 검증 Scene이 실제 해제됐는지 확인하고 PackedScene과 RegionDefinition 참조를 해제한다. 두 번의 세션 초기화가 원인이라는 근거는 없었다. 세션과 Collision을 별도로 측정하며 기존 Runtime·Traversal fixture는 그대로 실행하되 사본 안의 Bridge 전용 진입 Scene에만 종료 가드를 추가한다. 결과 기록과 종료 요청은 Godot가 로깅하며 부모가 실제 종료 코드와 Job Object의 잔류 수를 기록한다.

종료 코드가 0이고 로그에 엔진 오류가 없을 때만 결과를 승인한다. 네이티브 종료와 함께 생성된 PASS JSON으로는 게시할 수 없다. 게시 직전 취소, 외부 변경, 실제 자식 프로세스의 저널 작성·Scene 교체 직후 종료, 다음 실행 복구를 테스트한다. 별도의 프로세스 캡처는 원래 실행의 판정이나 로그를 변경하지 않는다.

## 순차 검증

```powershell
python tools/python_map_editor/bridge_stability.py --godot "<official exe>" --artifacts "<workspace outside project>" --commands --round-trips 10
python tools/python_map_editor/verify_windows_package.py "<ZIP>" --artifacts "<logs>" --bridge-project . --godot "<official exe>" --bridge-repeats 10
```

기본 Push CI를 유지했다. 별도의 workflow-dispatch 안정성 작업에서 단계별 30회, 전체 `validate_export` 50회, 무편집·편집 왕복 각 10회, 새 프로젝트 사본에서 배포 EXE 게시 10회를 순차 검증한다. 실패 증거를 보존하며 결과 JSON·종료 코드와 별도로 로그를 수집한다. Microsoft 서명 ProcDump가 제공되면 최초 접근 위반 뒤 프로젝트 사본에서 별도의 덤프 캡처를 시도한다. 이 캡처에 쓰는 Child 환경은 시스템·격리 경로 변수만 전달한다.

### Cold import 분리

첫 가드 적용 후 정상 실행에서 `validate_export` 50회가 연속 통과했지만 CI 배포 검증에서는 검증 직전 **리소스 가져오기용 별도 editor**가 `0xC0000005`로 종료했다. 이 프로세스는 기존 `--editor --recovery-mode --import`로 실행되어 Bridge 가드가 없었다. 임시 사본에서 가져오기 전용 빈 Scene과 전용 EditorPlugin을 사용해 같은 가드를 editor 종료에서도 적용한다. 해당 작업은 원래 프로젝트에서 EditorPlugin을 실행하지 않는다. 임시로 바꾼 사본의 `project.godot`와 기존 `override.cfg`는 정상·실패·취소 모두에서 원래 바이트를 복원한다. 임시 EditorPlugin의 실제 종료 호출을 확인하지 못하면 작업이 실패한다.
