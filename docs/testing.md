# 테스트와 실행 검증

## 환경과 공통 명령

Godot 4.7.2를 사용한다. `.godot-version`과 project.godot의 4.7 feature가 일치하는지 실행 스크립트가 확인한다. Python 3.10 이상이 있으면 전체 검증을 한 번에 실행할 수 있다.

```sh
python tools/check_project.py --godot godot
```

Windows PowerShell 예시(설치 위치에 맞춰 변경):

```powershell
$godotExe = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe'
python tools/check_project.py --godot $godotExe
```

개별 명령:

```sh
godot --headless --path . --editor --quit
godot --headless --path . res://core/validation/validate_content.tscn
godot --headless --path . res://tests/test_runner.tscn
godot --headless --path . res://tests/test_runner.tscn -- --restart-write
godot --headless --path . res://tests/test_runner.tscn -- --restart-read
godot --headless --path . --quit-after 60
```

실제 localhost ENet 연결은 기본 CI에서 socket 대기로 인한 hang을 피하기 위해 별도 timeout helper로 검증한다. 상세 범위와 명령은 `docs/multiplayer.md`를 참고한다.

프로세스 재시작 회귀는 각 역할에 독립된 native `user://` root를 할당하고 phase 1과 phase 2에서 같은 역할의 root만 재사용한다. Host와 client는 서로 다른 Godot OS process이며 phase 1의 ENet 객체나 singleton을 공유하지 않는다. 정상 종료 시 임시 파일을 지우고, 실패/timeout/process crash 시 JSON status와 각 process log를 보존한다.

```powershell
python tools/test_multiplayer_restart.py --godot $godotExe --players 2 --scenario valid
python tools/test_multiplayer_restart.py --godot $godotExe --players 2 --scenario invalid
python tools/test_multiplayer_restart.py --godot $godotExe --players 3 --scenario valid
python tools/test_multiplayer_worlds.py --godot $godotExe --players 2
python tools/test_multiplayer_worlds.py --godot $godotExe --players 3
```

`valid`는 Save v4의 returning safe position과 owner-private/item/quest 상태를 재시작 전후 비교한다. `invalid`는 finite이지만 Settlement bounds 밖인 위치가 deterministic fallback으로 치유되고, 같은 세션의 다음 reconnect와 후속 Save에서 그 위치가 유지되는지 검사한다. 3-player mode는 B/C의 protected inventory, PERSONAL quest, effects, survival, spawn assignment가 서로 교차 노출되지 않는지 함께 확인한다. 고정 sleep 대신 atomic JSON sentinel을 사용하며, 기본 port는 실행마다 사용 가능한 UDP port를 선택한다. 성공 아티팩트가 필요하면 `--keep-artifacts`를 추가한다.

`test_multiplayer_worlds.py`는 역할별 profile 파일을 분리한 실제 ENet process로 individual
world routing을 검사한다. 2-player mode는 host A가 Settlement에 남는 동안 B만 Sewer로
이동하고 다시 혼자 돌아오는지 확인한다. 3-player mode는 C가 Settlement에 남는 split과
B/C가 함께 Sewer roster를 구성하는 경우를 모두 확인하며, 각 전환에서 old-world actor와
다른-world roster가 남지 않는지 검사한다.

러너는 실패 시 1을 반환한다. tools/check_project.py는 각 실행을 120초로 제한하고 종료 코드 외에도 SCRIPT ERROR, ERROR/WARNING, orphan/leak 경고와 성공 마커를 검사한다. GitHub Actions는 공식 Godot 4.7.2 Linux 바이너리로 같은 project check, 2-player valid/invalid 및 3-player valid process-restart E2E, 2/3-player individual-world E2E를 실행한다. CI 원격 실행 결과는 실제 push 이후 별도로 확인해야 한다.

## 테스트 구성

기존 test_runner.gd를 유지하고 StabilityTests를 추가했다. v2 fixture를 변경하지 않고 기존 저장 필드와 결과를 비교한다. 새 테스트는 사망/부활/중복 손실, 원정 persistence 차단, 난이도 스냅샷, 효과/장비/주기 tick, 사망 드롭 부분·전체 회수와 재사망, 저장 복원, 전리품 보존, 보상 거래, 선행 조건/제작, 손상 snapshot, Validator 타입/진입점, 실제 근접·투사체, HUD 난이도 동기화를 검증한다.

등반 통합 테스트는 실제 플레이어·하수구 씬과 Input Action을 사용한다. 영역 밖 입력, 진입·정렬·정지·하강·점프·피격·귀환 차단, 사다리 상단 플랫폼 착지와 E 탈출, 밧줄 속도와 하단 이탈을 확인한다. 테스트용 변경 Resource는 복제하거나 임시 등록하고 종료 시 제거한다.

단일-process 저장 writer/reader 검증은 첫 프로세스에서 테스트 전용 `user://return_to_cage_restart_test.json`을 기록하고 다음 프로세스에서 읽는다. 위 multiplayer restart probe는 이 테스트와 별도로 production local profile, production Save v4, Host Saved Game, Join 경로를 실제 child process에서 사용한다.

## 렌더링 자동 점검

GPU/디스플레이가 있는 환경에서 실행한다. headless 물리 테스트와 별개다.

```sh
godot --path . --rendering-method gl_compatibility res://tests/visual_smoke.tscn
```

메인 씬의 New Game, 정착지, 실제 등반 후 상단 화면, HUD 경계를 확인하며 스크린샷은 user://validation에 저장한다. 자동 입력 테스트이며 사람의 수동 플레이를 대체했다고 표시하지 않는다.

## 수동 플레이 절차

1. F5 → New Game. A/D와 Space 이동, Milo E로 퀘스트 시작.
2. 하수구 문 E로 진입. HUD Save/Load/난이도가 잠기고 이유가 나오는지 확인.
3. 자원 채집, J 전투, 음식 효과 적용 후 입구 탈출. 버프와 시간이 이어지는지 확인.
4. 다시 진입해 오른쪽 사다리에서 W로 올라가기, 멈추기, S 하강, Space 이탈. 바닥 E 탈출 불가, 상단 착지 후 E 탈출 가능 확인.
5. Survival 사망 후 정착지에서 양수 HP와 손실 메시지 확인. 재진입해 같은 위치 드롭을 회수.
6. 창고를 채운 뒤 탈출하고 pending 표시 및 공간 확보 후 수령 확인. 퀘스트 보상도 공간 부족 뒤 재시도.
7. 정착지에서 Save → 프로그램 종료 → Load. 난이도/Override, 효과, 드롭, 보관함 복원 확인.
8. F10 개발 패널은 Debug 빌드 전용 우회 기능이며 일반 플레이 경로와 구분한다.

## 안정화 경계 테스트

기존 runner는 다음 다섯 파일을 dispatch한다. 외부 프레임워크를 추가하지 않는다.

- unit/test_inventory_stability.gd: 인스턴스 수량·중복, 내구도, signal 횟수, 정확한 instance 입력과 거래 rollback.
- unit/test_player_state_restore.gd: reset/restore 3회, 보관한 이전 객체의 콜백 차단, 체력·생존·좌표 보정, getter 및 시작 콘텐츠 검증.
- unit/test_settlement_state_restore.gd: unknown pending, storage overflow 합병, 세션 전체 중복, 보상·pending 재진입/원자성.
- unit/test_save_migration.gd: 실제 v1/v2/v3 파일 로드, 잘못된 버전과 필드, 사용자 경고, fatal rollback.
- integration/test_session_stability.gd: null 사망 설정, 전이 거부, duplicate death, 늦은 Actor 시그널, 씬 실패 후 respawn 재시도.

Resource.duplicate(true) 이후에도 외부 Resource는 공유될 수 있다. 테스트가 변경할
SurvivalConfig 같은 외부 Resource는 명시적으로 복제해 원본 콘텐츠를 오염시키지 않는다.

`tests/unit/test_reward_save_boundary.gd` saves synchronously from the storage
notification during pending/quest reward claims, then loads and retries the claim
to check quantity conservation. It also exercises fractional, oversized,
non-finite, negative and mistyped quest progress. These regressions failed on the
previous implementation. The updated full run passes 759 main assertions plus
1 restart-write and 25 restart-read assertions (785 total).
