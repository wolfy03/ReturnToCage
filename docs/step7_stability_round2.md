# STEP 7 안정화 2차 — 2026-11-17~18

기준은 `26f103e3494312bf4d0b5fad8c8591e5e776d029`이다. 공식 엔진 버전은
변경하지 않았다. 이 문서는 이전 [1차 보고서](step7_stability.md)를 대체하지 않으며,
이전 실패 로그와 이번 실패 로그를 모두 보존한다. **프로젝트 수정 완료와 공식 엔진의
반복 안정성 확보는 별개의 판정이다.**

## 실행 환경과 증거

- Windows 11 Pro 10.0.26200 x64, Python 3.14.5.
- 공식 실행 파일: `C:/Users/maker/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe`.
- 버전: `4.7.2.stable.official.ed1daf0bf`.
- SHA-256: `ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424`.
- 프로젝트 기본 Forward Plus, 렌더링 에디터 fixture는 GL Compatibility.
  NVIDIA RTX 3070 Laptop, 드라이버 596.49.
- 이번 조사 자료: `%TEMP%/rtc7-round2-62f581e170fe4d949e2cca288987cc1c`.
  TEMP는 개발 환경의 증거 위치이며 저장소에서 다운로드할 수 있는 자료는 아니다.
  덤프/PDB/실행 파일은 Git에 포함하지 않는다.
- 사용자 `export_presets.cfg`, `world/adventure/test_region.tscn`,
  `data/content/regions/test_region.tres`는 시작/종료 해시로 보호한다.
  Field Editor 임시 프로젝트에도 사용자 테스트 지역 두 파일을 복사하지 않는다.

## 확인된 GDScript 종료 수명 결함

공식 Windows 릴리스 자산에는 일치하는 Windows PDB가 없었다. 별도 TEMP 디렉터리에
정확한 소스 `ed1daf0bf001b61586d9930840f2f1394092c079`를 clone하고 MSVC 14.51.36231,
SCons로 심볼 포함 `template_debug`를 만들었다. 공식 실행 파일은 교체하지 않았다.

```text
platform=windows target=template_debug dev_build=yes debug_symbols=yes
optimize=none disable_3d=yes vulkan=no d3d12=no opengl3=no
disable_path_overrides=no -j4
```

이 빌드는 headless 종료 조사용이며 렌더링/에디터 회귀용 빌드가 아니다. 최초 빌드의
path override 미지원 오류는 호환되지 않는 실행 조건으로 기록하고 안정성 PASS에 넣지 않았다.

### 잘못되는 순서

정확한 소스의 `modules/gdscript/gdscript.cpp:2228`에 있는
`GDScriptLanguage::finish()`는 현재 스크립트만 임시 `Ref<GDScript>`로 보호한다.

1. 현재 스크립트의 함수/타입 참조를 끊고 `clear()`한다.
2. `s = s->next()`로 다음 SelfList 요소를 저장한다.
3. 루프 몸체 종료 시 현재 임시 Ref가 해제된다.
4. 현재 스크립트의 소멸은 그 스크립트의 `base` Ref도 해제한다.
5. 그 base가 2번의 다음 요소이면 다음 반복의 `s->self()`가 이미 해제된 주소다.

ObjectDB ID를 해제 전후로 비교하는 별도 계측에서 실제로 다음 스크립트가 사라졌다.
축소 프로젝트의 Actor 조건 10회 모두 검출됐다. 예:

```text
RTC_FINISH_DANGLING_NEXT
 current=res://data/definitions/facility_definition.gd
 released_next=res://data/definitions/content_definition.gd
```

이는 사용자 Facility 데이터의 오류나 Traversal의 PlayerActor 해제 오류라는 뜻이 아니다.
실제로 다음 요소의 수명을 보호하지 않는 엔진 종료 루프의 문제다. 단순 두 클래스만 있는
별도 최소 프로젝트에서는 재현하지 않았으므로, 모든 상속 프로젝트가 실패한다고 일반화하지 않는다.

### 덤프와 심볼 스택

수정 전 동일 소스 빌드를 ProcDump로 실행해 실제 `0xC0000005` full dump를 확보했다:
`godot.windows.template_debug.dev.x86_64.exe_261117_235555.dmp`.
그 빌드와 정확히 일치하는 PDB를 DbgHelp로 읽어 다음 스택을 확인했다.

```text
std::_Atomic_storage<unsigned int,4>::load          atomic:916
SafeNumeric<unsigned int>::conditional_increment   safe_refcount.h:138
SafeRefCount::refval                               safe_refcount.h:208
RefCounted::reference / init_ref                   ref_counted.cpp:75 / 37
Ref<GDScript>::ref_pointer / operator= / constructor
GDScriptLanguage::finish                          gdscript.cpp:2246
ScriptServer::finish_languages                    script_language.cpp:339
Main::cleanup                                     main.cpp:5273
```

Read AV, fault RVA `0x4d9814`인 **이 별도 빌드**에서 RCX는
`0xfeeefeeefeef001e`였다. 공식 바이너리의 RVA와 혼동하지 않는다.

추가 계측은 현재 Ref 해제 중 `ContentDefinition` 소멸자 진입에서 멈춘다.
첫 chance breakpoint dump `free-dump/*235951.dmp`의 일치 PDB 스택은
`GDScriptLanguage::finish → Ref<GDScript>::unref → 파생 GDScript 소멸자 →
Ref<GDScript> 소멸자 → base GDScript 소멸자`를 확인했다. 이 덤프의 `0x80000003`은
진단을 위해 의도적으로 넣은 breakpoint이며 실제 AV와 구분한다.
`symbol-stack.log`, `free-stack.log`, `finish-iterator-instrument.patch`,
`free-instrument.patch`를 TEMP에 보존했다. 전체 할당 스택은 수집하지 않았다.

### 엔진 패치와 적용 범위

[별도 엔진 패치](../tools/diagnostics/godot_4_7_2_script_finish.patch)는 종료 참조 해제
패스 동안 전체 스크립트의 강한 참조를 유지하고, 두 SelfList를 비운 뒤 참조를 해제한다.
게임 이동/물리/네트워크 규칙을 변경하지 않는다. 이 패치는 프로젝트에서 자동 적용되지
않고 공식 Godot 버전을 교체하지도 않는다. 엔진용 변경으로 별도 관리한다.

같은 private tracked-only 프로젝트·Actor 입력·Windows debug-process heap 조건에서
수정 전 빌드는 10/10회 성공 마커 이후 AV로 종료했고, iterator 검사를 유지한 패치 빌드는
10/10회 코드 0으로 종료했다. timeout과 ERROR/CowData는 없었다. 디버거 최초의 정상
`0x80000003` startup event는 AV와 구분했다. 원본 소스의 일반 실행은 10/10 정상 종료해
debug heap의 영향을 확인했다. 공식 빌드와 debug 빌드의 실패율을 직접 비교하지 않는다.

수정 전 소스에 적용하는 [iterator 진단 패치](../tools/diagnostics/godot_4_7_2_finish_iterator_probe.patch)도
별도 제공한다. ObjectDB ID가 사라졌음을 확인하면 의도적으로 중단하므로 생산용 패치가 아니다.
두 패치 모두 정확한 소스의 index에 `git apply --check --cached`가 통과했다.

공식 PDB가 아닌 커스텀 PDB를 공식 실행 파일에 적용하지 않았다. 실행 파일에 대한
전역 Page Heap/AppVerifier/시스템 디버거 설정도 변경하지 않았다. 이전 다른 RVA와
CowData 메시지가 모두 이 한 결함이라는 증거는 아직 없다.

## GUI 입력 원인과 수정

제품의 Analyze 버튼은 Windows 네이티브 입력 자동화로 실제 pressed 콜백이 실행됐다.
물리 마우스 수동 검사는 수행하지 않았다. 자동화 입력과 사람이 손으로 누른 검사는 구분한다.

`Viewport::_update_mouse_over(InputEventMouse)`는 네이티브 창에서
`root.gui.windowmanager_window_over`를 사용한다. 새 popup에서 `window_id`, focus,
좌표가 모두 맞아도 이 OS mouse-enter 대상이 없으면 hover 갱신을 하지 않는다.
`Input.parse_input_event()`는 Windows의 mouse-enter 이벤트를 만들지 않는다.
`notify_mouse_entered()`도 같은 내부 window-manager 포인터를 초기화하는 API가 아니다.

`traversal_editor_checks.gd`는 공식 `Window.warp_mouse()`로 클라이언트 경계를 통과한
뒤 `DisplayServer.process_events()`로 네이티브 이벤트를 처리하고 기존 mouse motion /
press / release를 주입한다. 실제 hovered Control이 대상인지도 확인한다. callback 직접
호출, 클릭 실패 시 signal fallback, assertion 완화는 없다. 생산용 UI는 변경하지 않았다.

첫 렌더링 진단에서 Analyze/결과 선택/Cancel/씬 재열기 후 Analyze와 모든 GUI assertion이
통과했다. 다만 같은 전체 실행의 후속 Traversal child가 AV로 종료되어 **전체 실행은 FAIL**이다.

## Traversal 작업 보관

- 새 Editor Controller 요청은 출처를 표시한다. Worker는 정상 child 종료와 status 저장 후에만
  `retention.json`을 작성한다. snapshot/request/status/result/log 해시와 원래 owner/worker의
  PID·생성 시각·실행 파일을 기록한다.
- 현재 표시 중인 결과는 살아 있는 원래 에디터의 lease로 보호한다. Controller의 clear는
  `released` 토큰만 기록하고 파일을 삭제하지 않는다. 실행 중 clear/cancel은 기존 협력적
  취소를 유지한다.
- Worker가 정상 완료를 기록한 뒤 완료 작업 중 최근 5개를 남긴다. 현재 열려 있는
  결과는 최근 5개 밖이어도 추가로 보호한다. 매 프레임 정리하거나 UI 스레드에서 파일 해시를 읽지 않는다.
- Running/Cancelling/Failed/Crashed/Unknown/Corrupted/기존 manifest 없는 작업은 자동 삭제하지 않는다.
  PID 재사용을 원래 프로세스로 취급하지 않는다. 접근 권한 부족 등 살아 있는지 불확실하면 보존한다.
- 32자리 hex 토큰, `.godot/rtc_traversal` 범위, 모든 상위 경로의 symlink/junction,
  정확한 파일 집합, 해시, 상태, process identity를 검사하고 잠금 아래 삭제 직전 재검사한다.
  알려진 파일만 직접 unlink하며 재귀 삭제하지 않는다. 낯선 파일/하위 폴더/덤프가 있으면 보존한다.
- 기존 Windows Job Object, cooperative cancel, orphan 방지와 실패 로그는 유지한다.

검증 명령:

```powershell
python tools/test_traversal_jobs.py
python tools/test_traversal_process.py
python tools/repeat_stability.py --godot <official-exe> --repeat 10 --case physics --case player --case traversal
python tools/repeat_stability.py --godot <official-exe> --repeat 3 --case headless --case rendered
python tools/repeat_stability.py --godot <official-exe> --repeat 10 --case enet2 --case enet3
```

## 최종 회귀 결과

성공 마커, 정상 종료, 오류 로그, 자식 프로세스 유무를 모두 확인했다.
실패 후 재실행 성공으로 이전 실패를 덮어쓰지 않았다. 아래 표는 공식 실행 파일 결과다.

| 항목 | 성공 | 실패 | 종료 코드와 판정 |
|---|---:|---:|---|
| Physics Fixture | 10 | 0 | 모두 0, 이 반복 집합 PASS |
| PlayerActor Fixture | 9 | 1 | 0 / 3221225477, FAIL |
| Traversal suite | 4 | 6 | 0 / 1 / 3221225477, child AV 포함 FAIL |
| Headless Field Editor | 0 | 3 | 모두 1, child AV 포함 FAIL |
| Rendered Field Editor 전체 | 1 | 2 | 0 / 1, 후속 child AV 포함 FAIL |
| Rendered GUI 입력·에디터 probe 단계 | 3 | 0 | hover/Analyze/선택/Cancel/재열기 PASS, 전체와 구분 |
| 2인 ENet | 10 | 0 | 모두 0, PASS |
| 3인 ENet | 8 | 2 | 0 / 1, 아래 role별 native exit로 FAIL |
| 전체 프로젝트 검사 | 1 | 0 | 0, PASS |
| Windows Release Export | 1 | 0 | 0, PASS |
| 생성 EXE headless boot | 1 | 0 | 0, 격리 user data, PASS |

반복 러너에서 timeout/남은 자식 프로세스/CowData 메시지는 각각 0건이었다.
이는 과거 CowData 문제가 해결됐다는 뜻이 아니다. 현재 공식 바이너리는 변경하지 않았고
별도 축소 조건에서도 AV가 발생하므로 Physics 10/10만으로 수명 안전성을 보장하지 않는다.

- 기본 33개 콘텐츠를 삭제/수정하지 않았다. 실제 작업 트리는 보존한 사용자 지역 1개를 포함해
  34개 검증 PASS다. tracked-only 축소 프로젝트는 33개, Wizard fixture가 추가된 임시
  Field Editor 프로젝트는 38개였다. 사용자 지역을 runtime fixture로 진입시키지 않았다.
- 프로젝트 검사: `6395` assertions, 재시작 write `1`, read `25` 모두 PASS.
- Traversal 반복 첫 집합은 기존 `91` assertions다. 보관 lease의 정상 토큰/잘못된 토큰 검사
  2개를 추가한 최종 에디터 fixture는 `93` assertions를 실행했다. 기존 검사를 삭제하지 않았다.
  최종 렌더링 3회차는 전체 93개와 interactive smoke, 모든 child의 정상 종료까지 PASS다.
- 최종 보관 정책 Python 테스트 **12/12**, Windows Job Object/worker lifecycle 테스트
  **4/4** PASS. 유효한 최근 완료 작업 5개 유지, 오래된 열린 결과 추가 보호, 살아 있는
  worker/child, PID 재사용, 불완전 identity, 해시 변경, 깨진 기록, 알려지지 않은 파일/폴더,
  symlink/junction guard, 원래 결과 보존을 검사한다. 링크 guard 테스트는 생성 권한과
  무관한 단위 주입 검사이며 모든 reparse 유형을 실제 OS에서 생성한 통합 검사는 아니다.
- 마지막 전체 headless 확인 1회는 import process의 AV 때문에 추가 FAIL이다
  (`rtc-process-logs-7vdflcoq/001.json`, child exit 3221225477). 기존 0/3 집합을 지우지 않았다.
- 패치 template 엔진으로 전체 93개 suite도 시도했다. 마커와 exit 0은 나왔지만
  `EditorUndoRedoManager`가 없는 template에서 editor 전용 의존성이 컴파일 오류를 출력했다.
  **그 실행은 FAIL**이며 패치 엔진의 전체 Field Editor 회귀 PASS로 사용하지 않는다.
  신뢰할 수 있는 엔진 A/B는 앞의 좁은 Actor/종료 조건 10회씩이다.

### ENet 상세

2인 10회와 3인 10회 모두 host/client 기능 마커를 출력했다. Stamina Mirror 수렴 assertion
실패와 권위 피격/넉백 assertion 실패는 이번 반복에서 없었다. 예시 trace의 서버 및 mirror는
각각 100/100, max 100이었다. 기존 unreliable snapshot + heartbeat 경로와 값을 바꾸지 않았다.
같은 trace에서 처음 관측한 `mirrored_low=92.3`이 이후 mirror 100으로 수렴했다.

3인 1회차는 client-2 PID 22696, 10회차는 host PID 21152가 성공 마커 뒤
`3221225477`로 종료했다. 각각 다른 역할의 프로세스이고 2회 모두 전체 FAIL이다.
단순 재시도로 PASS로 바꾸거나 timeout을 늘리지 않았다. Application 이벤트도 보존했다.
공식 바이너리에서 관측한 다른 fault RVA 전부를 하나의 근본 원인으로 확정하지 않는다.

### 추가 축소 실험

공식 바이너리로 private tracked-only 프로젝트에서 실행한 별도 실험:

| 조건 | 정상 종료 | AV |
|---|---:|---:|
| Autoload 없는 기본 Node | 10 | 0 |
| Autoload 없는 StaticBody + Rectangle | 10 | 0 |
| Autoload 없는 단순 Resource Script | 10 | 0 |
| 전체 Autoload + Node | 10 | 0 |
| 전체 Autoload + Physics | 8 | 2 |
| 전체 Autoload + Actor PackedScene load만 | 9 | 1 |
| 전체 Autoload + Actor 생성/해제 | 8 | 2 |

일부 Autoload만 추가한 registry/network/session 조건은 의존성 script 오류가 있었으므로
안정성 PASS로 사용하지 않는다. 이 결과는 Actor 삭제 없이도 오류가 발생함을 보여주지만,
특정 Autoload 자체가 잘못됐다는 증거로 사용하지 않는다.

### 증거 위치

- `rtc-stability-exuoounz`: 공식 Physics/Player/Traversal 각 10회, 실패 포함.
- `rtc-stability-z4o4_p1k`: 공식 headless/rendered 각 3회, 실패 포함.
- `rtc-stability-ghx53wf3`: 공식 ENet 2/3인 각 10회, 실패 포함.
- `rtc-stability-96_54c_4`: 전체 검사/Windows export, 생성 EXE.
- `rtc-process-logs-wh3s1knl`: 최종 Python 검사/커스텀 template 시도/추가 headless/EXE 부팅.
- 조사 root의 `debugger-results.json`: 디버거 조건 engine A/B 각 10회.
- 조사 root의 `reduction-results.json`, `post-results.json`, `protected-final.json`,
  `round2-final-application-events.json`, `build-identities.json`: 조건/실패/해시/이벤트/빌드 식별.

## 변경 파일과 영향

- `traversal_controller.gd`: editor 요청 출처와 완료 결과 lease 해제. 토큰/경로/링크를 검사하고
  결과 파일을 직접 삭제하지 않는다.
- `tools/analyze_traversal.py`, `tools/traversal_jobs.py`: 성공한 editor 작업만 attest하고
  안전한 보관 정책을 적용한다. 원래 Windows Job Object와 취소 절차는 유지한다.
- `tools/test_traversal_jobs.py`: 보관 정책 12개 회귀.
- `tests/editor/traversal_editor_checks.gd`: native mouse-enter 후 실제 입력 주입과 hover 검사.
- `tests/editor/traversal_tests.gd`: lease 경로 보호 assertion 2개 추가.
- `tools/test_field_editor.py`: 사용자 지역 파일을 임시 fixture에서 제외.
- `tools/diagnostics/`: 별도 Godot source 진단/제안 패치와 적용 범위 설명.
- 본 문서와 `docs/testing.md`: 결과와 한계, 실행 방법 기록.

GameSession/SceneRouter/NetworkManager/MovementComponent/PlayerActor/콘텐츠/저장 형식은
변경하지 않았다. 스태미나 heartbeat와 모든 권위 assertion도 유지했다.

## 남은 제한과 Git 처리

**공식 Godot 4.7.2의 STEP 7 반복 안정화는 완료되지 않았다.** 확인된 GDScript iterator
수명 결함은 별도 엔진 패치로 제시했지만 공식 EXE에 적용하지 않았다. 전체 기능을 지원하는
심볼 포함 editor build의 광범위한 회귀, 다른 fault RVA/CowData와의 관련성, 완전한 할당
스택은 후속 조사 대상이다. Python retention은 Windows process identity를 확인할 수 없으면
삭제하지 않는다. 오래된 manifest 없는 폴더와 실패 자료는 수동 검토 없이 정리하지 않는다.

사용자 파일 세 개는 종료 해시가 모두 시작 해시와 일치한다. 해당 로컬 변경과 미추적 파일은
커밋 대상에서 제외한다. 이 작업 관련 파일만 master에 커밋·푸시하며, 필수 안정화 조건의
미충족을 구현/조사 결과 반영과 분리한다. STEP 8은 시작하지 않았다.
