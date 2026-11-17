# STEP 7 최종 안정화 조사

기준 `d1cdedfcbb66176299c55fcabf719d969d814995`, 검증일 2026-11-17.
**구현 반영과 네이티브 안정화 완료를 구분한다. 네이티브 종료 문제는 미해결이다.**

## 환경과 보존

- Microsoft Windows 11 Pro, 10.0.26200 / build 26200. `Get-ComputerInfo`의
  WindowsProductName은 구형 레지스트리 이름인 Windows 10 Pro를 반환했으므로 CIM의
  실제 Caption/Version도 함께 확인했다.
- Godot `4.7.2.stable.official.ed1daf0bf`, Windows x86_64 GUI executable.
  SHA-256 `ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424`.
- 이 환경의 엔진: `C:/Users/maker/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe`.
  일반 실행 명령은 아래 `<godot>`를 설치 경로로 바꾼다.
- 프로젝트는 Forward Plus 설정이며 에디터 GUI 회귀는 기존과 동일한
  `--rendering-method gl_compatibility`로 실행한다. Headless는 표시 장치를 만들지 않는다.
- 시작 시 수정 파일은 `export_presets.cfg`, 미추적 사용자 파일은
  `world/adventure/test_region.tscn`, `data/content/regions/test_region.tres`였다.
  작업 전 SHA-256을 별도로 저장했고 파일을 수정하거나 커밋하지 않았다.
- 이전 보고서의 `rtc7-final-validation-d1rlj6gg`, `rtc7-native-comparison-hw4elram`
  로그 폴더가 실제로 존재함을 확인했다. 기존 stamina 실패 로그도 보존되어 있다.

## 확인된 결함과 수정

### 마지막 stamina 패킷 유실

`NetworkPlayerComponent.combat_snapshot_tick()`은 pair가 바뀔 때만 보내고
`NetworkManager._receive_player_combat_runtime`은 기존 unreliable_ordered channel 3을 쓴다.
마지막 최대값 패킷이 유실되면 이후 값이 변하지 않으므로 수정 전에는 재전송이 없었다.
`GameSession.apply_player_combat_runtime_snapshot()`과 클라이언트 시퀀스 검증은 정상이어도
수렴을 보장할 수 없는 구조다.

변경값의 0.1초 throttle과 기존 payload/sequence/world-revision 검증을 유지하면서
변경 없는 값도 0.5초 heartbeat로 재전송한다. 새 RPC나 client-side stamina 보정은 없다.
서버 최대 stamina·재생 속도·6초 assertion deadline은 바꾸지 않았다.
유휴 캐릭터마다 최대 약 2회/초의 추가 sample이 생긴다.

단위 테스트는 마지막 100/100 패킷을 버려 mirror를 99/100에 남긴 뒤, 서버 값의 추가
변경 없이 더 높은 sequence의 heartbeat로 복구되는지 검사한다. 기존 dirty-state 억제
테스트도 유지한다. 전체 기본 assertion은 6,389에서 **6,395 (+6)**로 증가했다.
과거 간헐 실패에는 패킷 송수신 trace가 부족했으므로 과거 모든 실패가 이 원인이었다고
단정하지 않는다. 새 ENet 로그에는 peer/world/server/mirror/max/time 정보를 추가했다.

### Traversal 초기화와 종료

- 작업 폴더 예약 뒤 pack/save/reload/request/launch 실패 시, 아직 실행하지 않은 해당
  token 폴더의 알려진 임시 파일만 정리한다. content 경로와 link는 정리 대상으로 거절한다.
  실행 중이거나 완료된 진단 작업의 로그는 삭제하지 않는다.
- Request 쓰기 오류와 snapshot 타입 오류를 명시적으로 처리한다.
- RegionDefinition `changed` 신호를 직접 감시하고 clear 시 disconnect한다.
- 손상된 status를 거절할 때도 취소 파일을 작성한다. 실행 중인 worker를 잊어버리지 않는다.
- controller가 tree에서 나갈 때 신호를 차단하여 함께 종료 중인 UI를 갱신하지 않는다.
- verifier는 cancel을 물리 루프 경계에서 확인한다. 입력 해제, climb 종료, Actor 해제,
  world 해제와 프레임 경계 처리 뒤 종료하며, 취소 작업은 result를 게시하지 않는다.
  결과 파일 생성 실패도 명시적 오류로 종료한다.
- Python은 취소 시 먼저 최대 2초의 협력적 정리를 기다리고, 필요하면 terminate 후
  최대 5초 안에 kill/wait한다. 분석 watchdog은 기존 60초 그대로다.
- 실행 전 취소는 `not_started`, child PID/exit code는 null로 기록하고 Godot를 만들지 않는다.
  Godot가 이미 시작했다면 world 초기화 전에도 취소를 확인한다. 이 분기를 추가하기 전
  controller 퇴장 테스트가 초기화 중 강제 종료를 재현했으며 해당 실패도 로그에 남겼다.
- 취소된 작업도 `engine_error`를 별도로 기록한다. exit 0이어도 CowData/error가 있으면
  취소의 정상 종료 검사에서 거절하므로 취소 상태로 엔진 오류를 숨기지 않는다.
- Windows Job Object를 child 생성 **전에 worker 자신에 적용**하여 Popen과 attach 사이에
  worker가 죽더라도 child가 남지 않도록 한다. 정상 종료 시 child를 wait한 뒤 job을
  disarm한다. 비정상 worker 종료는 kernel의 kill-on-close로 owned child를 정리한다.
- 플러그인에서 시작한 worker는 실제 부모 PID를 확인하고 원래 에디터 process handle을
  유지해 종료를 감지한다. 다른 Godot를 PID 검색으로 강제 종료하지 않는다.

기존 Traversal assertion 78개에 초기화 정리·위험 경로 거절·Resource 신호 해제 5개,
손상 status의 취소/결과 거절 2개를 추가해 85개가 됐다. 마지막에는 실제 Actor의 입력
증거가 로그에 나타난 뒤 취소하는 검사(준비 3 + 결과 3)를 추가해 **91개**다.
이 검사는 child code 0, forced termination 없음, result 미게시를 확인했다.
10회 반복 초반 6회는 83개, 후반 4회는 85개였다. 최종 91개 suite의 별도 실행도 정상
종료했다. 서로 다른 테스트 버전의 숫자를 같은 결과로 합치지 않는다. 기존 78개는 유지했다.

## 네이티브 덤프 분석

[Microsoft ProcDump](https://learn.microsoft.com/en-us/sysinternals/downloads/procdump)의
`-e -mm -x`로 단독 Traversal physics process의 unhandled exception dump를 수집했다.
전역 WER 레지스트리나 디버거 등록은 변경하지 않았다. 덤프는 Git에 포함하지 않는다.

- PID 20332, fault thread 20924 (`0x51bc`, 프로세스의 첫 thread).
- exception `0xC0000005`, read access, exception address `0x7ff6689dd181`.
- module base `0x7ff664bb0000`, fault RVA **`0x3e2d181`**.
- RCX/RBX/R12는 `0xfeeefeeefeeefeee`, instruction은 `[rcx + 0x120]`의 reference-count
  값을 읽고 atomic increment하는 경로였다. Windows debug heap의 해제 메모리 패턴과
  일치한다. 어떤 프로젝트 객체가 최초 해제했는지는 이 값만으로 식별할 수 없다.

PE `.pdata/.xdata` unwind metadata와 dump의 stack/context로 복원한 프레임:

```text
Godot + 0x3e2d181  (reference-count read; freed-memory pattern)
Godot + 0x3e2d29d
Godot + 0x547f41   (function range 0x547ee0..0x54832d)
Godot + 0x3e3baf8
Godot + 0x60539
Godot + 0x52adf
Godot + 0x52b7e
Godot + 0x10c9
Godot + 0x13f6
kernel32
```

공식 4.7.2의 [Main cleanup](https://github.com/godotengine/godot/blob/4.7.2-stable/main/main.cpp),
[ScriptServer](https://github.com/godotengine/godot/blob/4.7.2-stable/core/object/script_language.cpp),
[GDScriptLanguage::finish](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/gdscript/gdscript.cpp)를
disassembly의 호출 순서·인접 문자열과 비교했다. `0x60534`의 호출은 script language
finish 단계와 일치하고 `0x547ee0`의 스크립트 목록 순회/타입 참조 정리는
GDScriptLanguage::finish와 일치한다. 이전 `0x547f2c`도 같은 함수 범위에 있다.
**PDB/함수 심볼은 바이너리에 없으므로 함수명 연결은 source/disassembly 대조이며
정식 심볼 기반 source-line call stack은 아니다.** WinDbg/cdb는 설치되어 있지 않았다.

이 덤프는 SceneTree 정리 뒤 스크립트 종료 단계의 해제 후 접근을 뒷받침한다. 물리
쿼리 중 Actor 삭제가 직접 원인이라고 보여주지는 않는다. 이전 `0x191eaee/0x191eae2`
크래시를 동일한 원인으로 확정하지 않았다. CowData의 발생 객체/스레드도 이전 로그만으로
확정하지 못했다. 엔진 바이너리나 pinned 버전을 임의로 교체하지 않았다.

## 실행 방법과 결과 보존

```sh
python tools/test_traversal_process.py
python tools/repeat_stability.py --godot <godot> --repeat 10 --case traversal --case enet2 --case enet3
python tools/repeat_stability.py --godot <godot> --repeat 3 --case headless --case rendered
python tools/check_project.py --godot <godot>
```

PowerShell 예시:

```powershell
$godotExe = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64.exe'
python tools/repeat_stability.py --godot $godotExe --repeat 10 --case physics --case player
```

각 repetition은 새 프로세스이며 동시에 실행하지 않는다. `results.json`에 command,
PID, code, wall time, timeout, native/CowData, 남은 owned child 수를 기록한다.
stdout/stderr와 내부 개별 process log는 별도 임시 디렉터리에 보존한다.
앞선 실패를 다음 PASS로 덮어쓰지 않는다. 10회 중 하나라도 실패하면 그 반복 집합은 FAIL이다.
단일 성공 마커만으로 PASS 처리하지 않는다. runner도 자식 종료 후 제한된 cleanup
구간을 관찰하며, 남은 owned child는 정리하고 실패로 기록한다.

## 검증 집계

전체 에디터 회귀는 수십 개의 Godot
child를 실행하므로 10회 대신 headless/rendered 각각 3회 실행했다. 단독 물리/Actor/
Traversal 및 ENet은 각각 10회를 목표로 실행했다. 반복 횟수를 충족하지 않은 항목을
10회 안정 PASS로 보고하지 않는다.

| 검사/프로필 | 정상 성공 | 실패 | 종료 코드/판정 |
| --- | ---: | ---: | --- |
| 빈 최소 프로젝트, 새 process | 10 | 0 | 0, 해당 시작/종료 검사 PASS |
| 현재 프로젝트 메뉴 부팅/종료 | 10 | 0 | 0, 해당 경로 PASS |
| 프로젝트 내 physics 생성/해제 | 6 | 4 | 0 / 3221225477, 반복 FAIL |
| 실제 Actor 생성/해제 | 7 | 3 | 0 / 3221225477, 반복 FAIL |
| 기본 전체 프로젝트 검사 | 4 | 0 | 0, 6,395 + restart 1/25 assertions PASS |
| Traversal 10회 (83/85개) | 7 | 3 | 0 / 1 / 3221225477, 반복 FAIL |
| 최종 Traversal (91개) | 2 | 0 | 0, live cancel child 0 / termination none / engine_error false |
| Headless 전체 Editor, 취소 수정 후 | 3 | 0 | 0, 각 suite 85개, 해당 3회 PASS |
| Rendered 전체 Editor, 같은 프로필 | 0 | 3 | 1, GUI 분석 click 미전달로 FAIL |
| 2인 ENet | 9 | 1 | runner 1은 기능 PASS 후 child 3221225477, 반복 FAIL |
| 3인 ENet | 8 | 2 | runner 1은 기능 PASS 후 child 3221225477, 반복 FAIL |
| Windows Release Export | 2 | 0 | 0, PASS |
| 생성 EXE headless 120 frames | 1 | 0 | 0, 콘텐츠 34개, PASS |
| Python lifecycle 테스트 | 4 cases | 0 | 0, Windows worker-crash/타 process 보존 포함 |

기본 콘텐츠 33개와 사용자 `test_region` 1개 때문에 로컬에서는 34개가 등록된다.
위 반복에서 timeout/잔여 owned child는 0이었다. CowData는 새 반복에서 관측되지 않았지만
이를 해결됐다는 근거로 쓰지 않는다. ENet의 stamina 기능 검사 자체는 2·3인 각각 10/10
통과했으며, server/mirror가 100/100으로 수렴했다. 예시 trace의 mirror 저점은 92.3/100이다.
네이티브 종료가 있는 집합을 안정 PASS로 표현하지 않는다.

최소 physics fixture의 physics 모드는 Actor를 **생성하지 않지만**, 같은 script의 타입
선언과 프로젝트 autoload 의존성은 남아 있다. 이를 Actor script loading까지 배제한
독립 최소 프로젝트라고 표현하지 않는다. 별도 autoload 없는 NativeA/NativeB 상호 타입
참조 프로젝트도 import 및 종료 10회 모두 정상이라, 단순 순환 타입만으로 원인을
재현하지는 못했다. 어떤 프로젝트 script dependency가 최초 손상을 일으키는지는 미확정이다.

이전 실패도 보존했다. 개발 중 첫 에디터 집합은 강제 종료되는 cancel 경계와 테스트의
Variant bool 추론 오류(수정됨) 때문에 headless/rendered 각 3회 FAIL이었다. 한 headless
실행은 기존 STEP 5 fixture 저장 실패 뒤 script가 중단되어 RID/resource leak도 출력했다.
그 저장 실패는 후속 실행에서 재현되지 않았고 원인은 확정하지 않았다. 저장 오류 코드와
대상 경로를 출력하도록 계측했으며, 임의로 성공 처리하거나 assertion을 제거하지 않았다.
추론 오류가 난 rendered 실행은 90초 timeout이었다. job 강제 정리 뒤 반환 코드가
0으로 보였어도 timeout=true이므로 실패로 보존했다.

렌더링 입력 실패는 별도로 반복 재현했다. native Window는 visible/focused이고 button
좌표는 viewport 안에 있으나 hover가 null이고 Analyze callback이 실행되지 않았다.
전역 Input 주입, viewport 주입/enter 통지, relative motion 변경을 비교했지만 해결되지
않았으므로 이 실험적 변경은 되돌렸다. 기존 InputEvent 주입 방식과 모든 assertion을
유지하고 hover/window 진단 로그만 추가했다. 생산용 UI 코드는 바꾸지 않았다.
물리 마우스 수동 검사는 수행하지 않았다. 렌더링 회귀를 PASS로 보고하지 않는다.

재실행 로그 디렉터리(이 개발 환경의 TEMP 아래):

- `rtc7-stability-2d0315a975af40da9fa0013bc290f06a`: 기준선, dump/stack, Application events,
  개별 GUI 진단 실패, 최종 프로젝트/부팅/단순 타입 순환 검사.
- `rtc-stability-udldpf8o`: 초기 전체 매트릭스, 실패/성공 모두 보존.
- `rtc-stability-zg9lz0c7`: physics/player/traversal/ENet 각각 10회.
- `rtc-stability-6owqu064`: 수정 도중의 에디터 실패 집합.
- `rtc-stability-bfcdumtp`: 취소 수정 후 headless 3회 PASS, rendered 3회 FAIL.
- `rtc-stability-146zhcfs`: viewport/enter 입력 실험 3회 FAIL(원복).
- `rtc-stability-6yupltvr`: 프로젝트/Export 정상 종료, 생성 EXE.
- `rtc-stability-h4evgqk8`: 최종 91 assertions / live cancellation 정상 종료.
- `rtc-stability-z626m43d`: 마지막 프로젝트 검사 및 engine_error 검사까지 포함한 91개 suite 정상 종료.

## 남은 필수 조건

네이티브 종료 및 렌더링 입력 회귀가 남아 있어 **STEP 7 최종 안정화 완료가 아니다.**
최초 해제 지점을 식별하려면 동일 4.7.2 소스의 심볼 포함 build/heap diagnostics로 현재
덤프 경로를 더 축소해야 한다. 다른 종료 경로의 덤프도 따로 확보해야 하며, 이 작업의
수명 정리 변경이 GDScript engine 종료 결함을 고쳤다고 주장하지 않는다.

## 변경 파일과 영향

- `gameplay/components/network_player_component.gd`: 기존 stamina snapshot의 heartbeat만 추가.
- `addons/rtc_field_editor/traversal_controller.gd`: 초기화 정리, Resource 무효화, 종료 신호 차단.
- `tests/editor/traversal_physics.gd`: 협력적 취소와 정리 후 종료, result 쓰기 실패 처리.
- `tools/analyze_traversal.py`, `tools/traversal_process.py`: owner/child process 소유권, 종료·오류 기록.
- `tools/process_diagnostics.py`, `tools/check_project.py`, `tools/test_field_editor.py`:
  개별 process 로그와 엄격한 오류·종료 검사, owned descendant 정리.
- `tools/test_multiplayer_world_runtime.py`: 성공/실패 로그와 PID/종료 상태를 모두 보존.
- `tools/repeat_stability.py`: 순차 반복과 개별 결과 보존.
- `tools/test_traversal_process.py`: launch 실패·worker 강제 중단·무관한 child 보존 검사.
- `tests/editor/traversal_tests.gd`, `traversal_editor_checks.gd`: 실패 정리·신호·취소·controller 퇴장 회귀.
- `tests/editor/field_editor_probe.gd`: 간헐적인 fixture 저장 실패의 오류 코드/대상 경로 계측.
- `tests/integration/native_lifecycle_probe.gd`, `.tscn`: Actor 없는 physics / 실제 Actor 생성·삭제 최소 검사.
- `tests/integration/multiplayer_world_runtime_probe.gd`: 기존 assertion 유지, stamina 진단 로그 추가.
- `tests/unit/test_combat_runtime_replication.gd`: 마지막 패킷 유실 복구 검사.

GameSession/SceneRouter/NetworkManager/SaveData/이동 수치/콘텐츠는 변경하지 않았다.
스태미나 heartbeat가 추가하는 네트워크 비용 이외의 새 gameplay 기능은 없다. STEP 8은 시작하지 않았다.
