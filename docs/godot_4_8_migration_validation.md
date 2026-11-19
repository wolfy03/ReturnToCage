# Godot 4.8 beta 4 전환 검증

**BLOCKED — 4.7.2 유지.** beta 4 렌더링 에디터가 접근 위반으로 한 차례 종료했고, 다른 실행에서는 입력 검증과 헤드리스 리소스 검사도 실패했다. 3인 ENet 5회차에서는 이동 표시 검증이 실패했다. 모든 시도와 실패를 보존했다.

## 환경과 복구 기준

- Windows 11 Pro x64, 빌드 26200. 원본 `master`의 시작 HEAD와 원격 master는 모두 `55f93646a0298d724728f7700f3ce194ed7ebfa8`.
- 복구 태그 `godot-4.7.2-rollback`를 위 커밋에 생성하고 원격에 푸시했다. 원본 `return-to-cage`, 4.7.2 비교용 detached `return-to-cage-4.7-baseline`, beta 검증 브랜치 `test/godot-4.8-beta4`의 `return-to-cage-4.8`는 각각 독립 캐시를 사용했다.
- 아래 경로에서 `validation`은 `D:\Godot_Project\ReturnToCage\validation`이다. Field Editor 렌더링 검사는 GL Compatibility를 사용했다. 프로젝트 설정은 4.7 및 Forward Plus다.

| 엔진 | 공식 버전 및 빌드 | 실행 파일 위치 | SHA-256 |
| --- | --- | --- | --- |
| 4.7.2 콘솔 | `4.7.2.stable.official.ed1daf0bf` | `C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe` | `c8f0a6bc45a19b33541501e57f6f7cd972ab18453743266339d495cbbe846643` |
| 4.7.2 본체 | 같은 빌드 | 같은 폴더의 `Godot_v4.7.2-stable_win64.exe` | `ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424` |
| beta 4 콘솔 | `4.8.beta4.official.b070e63b1` | `validation\godot-4.8-beta4\engine\Godot_v4.8-beta4_win64_console.exe` | `332afc4bc00fe6f136f993822c8420c6f7479475ab167da15a63dad9f582fe02` |
| beta 4 본체 | 같은 빌드 | 같은 폴더의 `Godot_v4.8-beta4_win64.exe` | `a6d14a82e133c2635f896ea94988b6fa373eecf84893ff1deb4644e2175b0c7c` |
| beta 4 Release 템플릿 | `4.8.beta4` (`version.txt`) | `validation\godot-4.8-beta4\export-baseline\user\Godot\export_templates\4.8.beta4\windows_release_x86_64.exe` | `1c5f33d1f5217c1b265bda90bfe544b83e6380f62d099b6d482f29f12fadc1d1` |

에디터와 템플릿은 공식 Windows x64 배포본을 사용했다. 기존 엔진이나 전역 템플릿을 교체하지 않았고, 4.7.2 진단 패치는 적용하지 않았다. [Godot 4.8 beta 4 공식 아카이브](https://godotengine.org/download/archive/4.8-beta4/)

## 네이티브 종료

beta 4 공식 빌드의 `GDScriptLanguage::finish()`는 static 데이터와 dangling instance 정리 전에 각각 스크립트 목록을 `LocalVector<Ref<GDScript>>`로 보관한다. 마지막 단계는 목록의 head를 다시 가져온다. 4.7.2 덤프에 기록된 다음 iterator 요소의 참조 수명 문제를 방지하는 구조다. [공식 beta 4 소스](https://github.com/godotengine/godot/blob/b070e63b161aa816afac71dcfc9d60859d38f220/modules/gdscript/gdscript.cpp#L2236-L2305) · [4.7.2 심볼 및 덤프 조사](step7_stability_round2.md)

| 독립 프로세스 테스트 | 4.7.2 정상 / 실패 | beta 4 정상 / 실패 | beta 4 종료 코드 |
| --- | --- | --- | --- |
| Physics | 10 / 0 | 10 / 0 | 모두 0 |
| PlayerActor | 5 / 5 | 10 / 0 | 모두 0 |
| Traversal | 3 / 7 | 10 / 0 | 모두 0 |

4.7.2 PlayerActor 실패 5회는 모두 `3221225477` (`0xC0000005`). Traversal은 상위 종료 코드 `1` 6회와 `3221225477` 1회가 기록됐다. 실패 7회 모두 Traversal 물리 child 또는 suite의 접근 위반을 포함했다. Windows Application 이벤트 1000에서 4.7.2 본체의 `0x547f2c` 14건과 `0x3e2d181` 3건을 확인했다. beta 4의 세 네이티브 fixture에서는 접근 위반이 0건이었으나 렌더링 재검증에서 별도 접근 위반이 1건 있었다. beta 4에서 CowData 또는 ObjectDB leak 메시지는 관찰되지 않았다.

렌더링 재검증 1회차에서 beta 4 본체 PID 8664 (콘솔 래퍼 PID 19596), 스레드 6088이 GL Compatibility 초기화 출력 뒤 GUI 마커 전에 `3221225477`로 종료했다. Application 이벤트 1000/1001은 본체 모듈의 `0xC0000005`, fault RVA `0x195b962`를 기록했다. WER 미니덤프의 예외 컨텍스트에서 `0x7000000140` 읽기 중 실패했으며, 공식 EXE의 unwind 정보로 얻은 Godot 프레임 RVA는 아래와 같다.

```text
0x195b962 → 0x17f2048 → 0x17f2061 → 0x17f2af7 → 0x3776acd → 0x4ae727a
```

정확히 일치하는 PDB를 확보하지 못해 함수명은 확인하지 못했다. 초기화 이후 어느 에디터 작업에서 접근했는지와 4.7.2 iterator 결함과의 관련성은 미확정이다.

## 기능 검증과 실패 기록

| beta 4 검사 | 결과 | 관찰 |
| --- | --- | --- |
| 초기 Headless Import와 GDScript 파싱 | PASS | 둘 다 종료 0. 추적된 GDScript 274개 로드 오류 0 |
| 전체 프로젝트 | PASS | 종료 0, 6,395 assertions 및 별도 재시작 1 / 25 assertions |
| Traversal | 10/10 | 93 assertions 유지. 실입력 물리 검증, 여러 이동 후보, 슬롯별 도달, 취소 및 결과 무효화 |
| Traversal Python | PASS | Process 4개, 보관 및 정리 12개 |
| Headless Field Editor 원본 | 0/3 | 에디터 종료 0, 러너 종료 1. 복구 대화상자 `popup_centered()`에서 `Window 0 spawned at invalid position` |
| Headless Field Editor 호환 수정 | 1/3 | 위치 오류는 사라짐. 2·3회차 에디터 종료 0, 러너 종료 1. `ResourceFormatLoaderText::get_dependencies()`의 `FileAccess::open` 실패 |
| Rendered Field Editor 원본 | 0/3 | Windows 창 좌표와 포커스를 얻었으나 목표 Control에 hover 및 입력 미도달 |
| Rendered Field Editor 추가 두 반복 집합 | 0/3, 0/3 | viewport 입력 시도에서도 hover 미도달. 원래 입력 경로를 사용한 추가 3회 중 1회 에디터 접근 위반, 2회 native hover ID `-1`과 버튼 미도달 |
| 2인 ENet | 10/10 | host, client 모두 정상 종료 |
| 3인 ENet | 9/10 | 5회차 client-2 이동 검증 실패 및 종료 1. 러너가 대기 중인 host와 client-1을 정리 |
| Windows Release Export | PASS | 공식 x64 템플릿, 종료 0 |
| Windows EXE 부팅과 콘텐츠 | PASS | 실제 Release EXE 종료 0, 에디터와 콘텐츠 ID 33개 일치. Export/Export 및 양방향 Editor/Export ENet과 세 프로세스의 세션 복구 포함 |

검사 로그와 Job Object 관측에서 잔여 소유 프로세스는 0이었다. 종료 0이어도 오류 로그가 있으면 실패 처리했다. 정상 종료한 Headless Field Editor 실행에서 별도 Scene 및 RegionDefinition 저장과 재열기, ENTRY/ESCAPE, Traversal 검증 재실행 및 에디터 probe teardown을 확인했다.

3인 실패 시 host에 `bx=150.00 cx=198.00 direction=-1`, client-2에 `local presentation did not receive movement start=150.00 current=150.00`이 기록됐다. 같은 슬롯 배치 및 이동 방향으로 성공한 실행도 있어, 이 조건만으로 원인을 확정할 수 없다. 실패는 Stamina 검사 전에 발생했다. Stamina 단계에 도달한 실행에서는 server/mirror/max가 모두 100으로 수렴했다. 기존 unreliable-ordered 이동 입력, 서버 권위 스태미나와 snapshot/heartbeat, 모든 검증 조건을 유지했다.

## 성능과 파일 변경

- 같은 sewer 분석에서 두 엔진 모두 표면 5개, 후보 25개, Verified 11개, 물리 12,621 ticks를 기록했다. 각 간선 상태와 16개 spawn/ESCAPE 조합의 `Verified Reachable` 판정이 일치했다. 같은 로그의 14개 Verified 측정은 후보 수가 우연히 같은 별도 fixture다.
- 본 비교의 sewer 검증 시간 중앙값은 4.7.2 **2.435초**, beta 4 **2.415초**였다. 로컬의 기존 1.6~1.8초 기준보다 오래 걸렸고 여러 검증 그룹이 함께 실행된 환경이어서 이 차이를 엔진 속도 차이로 해석하기 어렵다.
- 동일한 기준 커밋의 새 사본에서 콜드 import를 한 번씩 실행했다. 4.7.2는 9.96초, beta 4는 9.51초였고 둘 다 오류 없이 종료했다. 결과는 `validation\cold-import\results.json`에 있다.
- 캐시가 이미 있는 Headless Editor 시작·종료 각 3회의 중앙값은 7.36초와 6.48초, 관측된 peak working set 중앙값은 약 718 MiB와 777 MiB였다. 샘플 간격은 50 ms였고 메모리와 부팅 값은 이 환경에서의 관측치다. GUI 반응성은 입력 실패로 정상 비교를 완료하지 못했다.
- 프로젝트 Scene, Resource, UID, 이동 수치, 네트워크 프로토콜 및 저장 형식은 수정하지 않았다. 4.8 import가 생성한 20개 텍스처 `.import`의 차이는 기본 압축 품질 모드와 alpha-test mipmap 옵션이다. 에셋 경로 및 UID 변경은 없었다. 메타데이터 diff는 `validation\godot-4.8-beta4\auto-import-metadata.patch`에 따로 보존했다.
- `addons/rtc_field_editor/plugin.gd`에서 복구 창 wrapping Label에 최소 폭을 지정해 너무 높은 팝업의 위치 오류를 수정했다. `get_dependencies()`가 열지 못한 구체적 리소스 경로와 실패 원인은 로그에서 확인되지 않았다.
- `tests/editor/traversal_editor_checks.gd`의 렌더링 입력 진단에 native hover window ID를 추가했다. 기존 마우스 진입 및 입력 주입 경로와 assertion을 유지했다. 4.7.2 원본 렌더링 비교 1회에서도 같은 hover 실패와 별도의 종료 접근 위반이 발생했다. 입력 문제가 beta 4에만 발생한다는 근거는 없다.
- `tools/validate_godot_upgrade.py`를 추가하고 `tools/check_project.py` 및 `tools/process_diagnostics.py`에 후보 버전 지정과 로그 위치 연결을 추가했다.

## 자동 검증과 재실행

별도 worktree에서 공식 RC 또는 Stable 실행 파일과 동일 릴리스의 추출된 Windows export template을 지정한다. 기존 pin은 `check_project.py`의 기본 동작에 계속 적용된다. 명시적 업그레이드 검증만 후보 버전을 확인한다.

```powershell
python tools/validate_godot_upgrade.py `
    --godot "C:\Tools\Godot\Godot_v4.8-beta4_win64_console.exe" `
    --expected-version 4.8.beta4 `
    --templates "C:\Tools\Godot\4.8.beta4\templates" `
    --artifacts "D:\Godot_Project\ReturnToCage\validation\godot-4.8-beta4"
```

`--expected-version`에는 `4.8.rc1`, `4.8.stable` 또는 빌드 해시를 포함한 정확한 공식 버전 문자열을 사용할 수 있다. 템플릿은 `version.txt`와 Windows x64 EXE가 있는 폴더다. 러너는 링크된 worktree에서 실행하며 원본 worktree의 보호 파일 해시를 시작과 끝에 비교한다. 실행마다 새 결과 폴더와 사용자 데이터 경로를 만들고, 명령·버전·SHA-256·PID·wall time·표준 출력/오류·종료 코드·자식 프로세스 수·하위 로그 위치를 기록한다. 부분 실행(`--case`)이나 템플릿을 생략한 실행은 전체 전환을 승인하지 않는다. 새 RC 또는 Stable에서 모든 검사를 마친 뒤, 그 전에 사용하던 버전의 태그를 보존하고 master 반영 및 smoke test를 별도로 한다.

## 로그와 Git

- 4.7.2 반복 원본 `%TEMP%\rtc-stability-p8vf11ed`. beta 4 반복 원본의 절대 경로는 `validation\godot-4.8-beta4\native-baseline\runner.log`, `enet-baseline\runner.log`, `editor-baseline\runner.log` 첫 줄에 있다. 3인 실패는 `enet3-05.stdout.log` 및 `%TEMP%\return_to_cage_world_runtime_j56haqsi\processes.json`을 참조한다.
- 공식 소스와 초기 import, 전체 검사, Export 로그는 `validation\godot-4.8-beta4`. 상세 전후 비교는 `validation\traversal-comparison.json`, `performance.json`, `application-events.json`에 보존했다.
- 호환 수정 후 에디터 결과는 `rtc-upgrade-4.8.beta4-woypwzkb\results.json`, 렌더링 재검증은 `rtc-upgrade-4.8.beta4-ri_5oq1n\results.json`과 하위 로그에 있다. WER 덤프와 스택은 `validation\godot-4.8-beta4\rendered-8664-exception-stack.log`, `validation\dumps`를 참조한다. 각 러너의 기존 임시 로그 경로도 기록했다.
- Export 자동화 최초 실행에서 색상 제어 문자가 성공 마커 문자열에 포함되어 러너만 실패했다. 원본은 `rtc-upgrade-4.8.beta4-wplzs4sb\results.json`에 보존했다. 판정에 사용할 텍스트에서 ANSI 색상을 제거한 후 `rtc-upgrade-4.8.beta4-04wdjhj3\results.json`에서 Export 및 EXE 검증 모두 정상 종료를 확인했다.
- 검증 브랜치에만 코드와 이 보고서를 커밋한다. 원격 master와 복구 태그는 모두 `55f93646a0298d724728f7700f3ce194ed7ebfa8`. 검증 브랜치의 최종 SHA는 이 보고서를 포함하는 커밋이다.

| 원본 사용자 파일 | 시작 및 종료 SHA-256 |
| --- | --- |
| `export_presets.cfg` | `bf3a40ade099434fa95918ce1952bfb4b41fd171fef1347cd0576c442ab2f069` |
| `world/adventure/test_region.tscn` | `76c21fc820d4ca30b25ee4ce02f4f6e577b01a6e973b0e7ebcf9edeaf42b6b2a` |
| `data/content/regions/test_region.tres` | `0c015f96b54b28a6a3ac20aad5756c34f33b3586d239307bc0be6b83f1945473` |
