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
python tools/test_multiplayer_world_runtime.py --godot $godotExe --players 2
python tools/test_multiplayer_world_runtime.py --godot $godotExe --players 3
python tools/test_multiplayer_forest.py --godot $godotExe --players 2
python tools/test_multiplayer_forest.py --godot $godotExe --players 3
```

`valid`는 Save v4의 returning safe position과 owner-private/item/quest 상태를 재시작 전후 비교한다. `invalid`는 finite이지만 Settlement bounds 밖인 위치가 deterministic fallback으로 치유되고, 같은 세션의 다음 reconnect와 후속 Save에서 그 위치가 유지되는지 검사한다. 3-player mode는 B/C의 protected inventory, PERSONAL quest, effects, survival, spawn assignment가 서로 교차 노출되지 않는지 함께 확인한다. 고정 sleep 대신 atomic JSON sentinel을 사용하며, 기본 port는 실행마다 사용 가능한 UDP port를 선택한다. 성공 아티팩트가 필요하면 `--keep-artifacts`를 추가한다.

`test_multiplayer_worlds.py`는 역할별 profile 파일을 분리한 실제 ENet process로 individual
world routing을 검사한다. 2-player mode는 host A가 Settlement에 남는 동안 B만 Sewer로
이동하고 다시 혼자 돌아오는지 확인한다. 3-player mode는 C가 Settlement에 남는 split과
B/C가 함께 Sewer roster를 구성하는 경우를 모두 확인하며, 각 전환에서 old-world actor와
다른-world roster가 남지 않는지 검사한다.

`test_multiplayer_world_runtime.py`는 동일한 독립 process 경계에서 Host presentation이
Settlement인 동안 별도 Sewer server runtime을 실행하고, 2-player에서는 반대로 Host만
Sewer에 들어가도 Settlement client가 유지되는 경우까지 검사한다. 실제 movement command와
20 Hz snapshot, enemy AI/health/combat, 실제 enemy attack knockback의 서버 위치 변화와 원격
presentation 방향 동기화, loot claim/despawn, shared gather consumption, world clock,
same-world roster를 검증한다. Sewer player의 Settlement command와 Host의 cross-world
attack/pickup은 실패해야 한다. remote presentation actor가 HURT를 모르는 상태에서도 escape
요청은 서버 authoritative HURT로 거절되고, HURT 종료 후 같은 return은 성공해야 한다. B의
실제 combat presentation event도 함께 검증한다: enemy direct hit의 HURT event와 duration,
buffered `attack_1 → attack_2`의 sequence/combo step/key/timing, Dodge direction/duration이
원격 actor에 도착하지만 그 actor의 CombatAction/health/stamina/position을 직접 변경하지 않는다.
이 이벤트는 기존 reliable world/revision routing을 사용한다. B의
개별 복귀 동안 C runtime은 유지되고, 마지막 참가자 퇴장
뒤 runtime 정리와 fresh 재생성을 확인한다.

### Autoload signal 생명주기 (unit)

재생성 가능한 UI(`AppRoot`, `GameHUD`, `MultiplayerPanel`, `DebugPanel`)는 autoload signal 연결을 `SignalBindings`에 기록해 `_exit_tree`에서 정확히 그 연결만 끊고, tree에 다시 들어오면(`_enter_tree` + `is_node_ready()`) 복원한다. Godot는 target이 free될 때 연결(bound method와 lambda 모두)을 자동 정리하므로 free 이후 누수는 없지만, tree에서 빠졌으나 아직 free되지 않은 구간에는 autoload 이벤트가 그대로 전달된다(예: `AppRoot._return_to_menu`의 `get_tree() == null`). `tests/unit/test_signal_lifecycle.gd`는 AppRoot 생성→detach→재부착→free를 3회, 단독 HUD/MultiplayerPanel 생성·삭제를 3회 반복하며 모든 autoload signal의 연결 수가 기준값으로 돌아오는지, 같은 callback 중복 연결이 없는지, detach된 subtree가 어떤 autoload signal도 받지 않는지, Host/leave 반복이 연결을 늘리지 않는지 확인한다. ObjectDB/orphan 경고는 `check_project.py`의 출력 검사가 실패로 처리한다.

### 플레이어별 알림 격리

`tests/unit/test_gameplay_notifications.gd`는 offline/host local routing, host 자신의 gather 알림, 원격 private 알림이 host HUD에 나타나지 않는지, shared upgrade 중복 방지, 수신 RPC guard와 `valid_notification`, session 종료 시 정리, Load 결과 표시를 검사한다. 실제 ENet에서는 `test_multiplayer_world_runtime.py`가 host status를 sentinel로 고정한 채 gather(2인 B / 3인 C), B return, B death 알림이 소유자에게 정확히 1회 가고 host와 다른 client에는 가지 않는지(`NOTIFICATION ... ISOLATION OK`), client B의 workbench upgrade가 B에게 1회(command result), host와 C에게 shared로 1회 가는지(`NOTIFICATION SHARED UPGRADE OK`) 확인한다. `test_multiplayer_local.py`는 disconnect 전 personal notice가 자기 client에만 도착하는지, session 종료 후 메시지가 비는지, reconnect 후 새 peer mapping으로 자기 identity의 notice만 받는지 확인한다.

### Save primary/backup 복구 (unit)

`tests/unit/test_save_backup_recovery.gd`는 실제 `SaveManager.save_game()`으로 만든 고유 `user://` 파일만 사용한다(production Save·profile 미사용). Primary/backup 조합표(둘 다 유효, backup 손상, primary 없음/JSON 손상/구조 손상/full staging 실패 + 유효 backup, backup 없음, 둘 다 손상, 둘 다 없음, legacy v2 primary + 유효 backup, 다른 identity의 유효 primary + 다른 backup)를 검사하고 load가 파일을 쓰지 않는지 확인한다. `SaveManager.set_failure_hook_for_tests()`로 temporary open/write/validate, backup preserve/create, primary install, rollback 실패를 주입해 이전 primary/backup bytes와 load 결과가 보존되는지, 무효 primary가 `.bak`을 덮지 않는지, rollback까지 실패해도 backup으로 복구되는지 확인한다. `test_host_saved_game.gd`는 primary 없이 유효 backup만 있을 때 Saved Host가 backup을 호스팅하고 primary를 쓰지 않는지 확인한다.

### 전리품 지급 위치 (PICKUP E2E)

전리품 지급 위치는 **world kind가 결정한다**: Settlement는 main inventory, Adventure의 일반
field loot는 `unsecured_loot`, Adventure에서 기존 가방에서 드롭한 아이템의 재습득은 main
inventory(instance_id·수량 보존)다. E2E는 각 경로를 실제 world 설정에 맞춰 검증한다.

- `tools/test_multiplayer_local.py`(`multiplayer_probe.gd`)는 Sewer 씬을 **Settlement world로**
  묶는 legacy fixture다. 따라서 PICKUP은 main inventory 증가를 기대한다. 서버 승인 후 정확한
  수량, `unsecured_loot`·다른 player의 inventory/unsecured 불변, 서버·client 각각 LootActor
  retire 정확히 1회, collector client의 개인 inventory snapshot 갱신, PERSONAL collect quest
  credit 1회를 확인한다. 이어서 서버 직접 재claim, 같은 entity의 client 재요청, 위조 entity
  ID 요청이 모두 거절되고 상태가 그대로인지 `PICKUP_REPLAY`에서 다시 검사한다.
- `tools/test_multiplayer_world_runtime.py`는 실제 `adventure:sewer_region` runtime에서 enemy
  loot가 B의 `unsecured_loot`에만 정확히 추가되고 main inventory와 C의 inventory/unsecured는
  변하지 않는지, 범위 밖 C의 claim·중복·위조 요청이 거절되는지 확인한다
  (`ADVENTURE UNSECURED LOOT PICKUP OK`). Host의 cross-world pickup 거절도 같은 probe가 본다.
- `tools/test_multiplayer_authority.py`는 Adventure에서 드롭한 carried item을 다시 주웠을 때
  `unsecured_loot`가 아니라 owner-private main bag으로 돌아오는지 확인한다. 단위 수준의
  instance_id·수량 보존은 `tests/integration/test_inventory_drop.gd`가 검사한다.

`test_multiplayer_disconnect.py`와 `test_session_recovery.py`의 loopback 정책은
`tools/loopback_policy.py`가 정한다. 기본 Host/Join 주소는 IPv4 `127.0.0.1`(`--address`로 변경 가능,
loopback IP literal만 허용)이고, 두 번째 Host에 다른 주소 형식으로 접속하는 단계만 IPv6 `::1`을
쓴다. `--ipv6 auto`(기본)는 `::1`을 bind할 수 있을 때만 그 단계를 IPv6로 실행하고, 아니면 IPv4로
실행한 뒤 `IPv6 SKIPPED (사유)`를 출력한다. `--ipv6 require`는 IPv6를 쓸 수 없으면 실패하고,
`--ipv6 skip`은 IPv4로 고정한다. 결과는 PASS 줄과 lifecycle `summary.json`의 `loopback`에
IPv4/IPv6로 구분해 기록된다. CI(Linux/Windows)는 `--ipv6 require`로 실행하고, Windows release
EXE lifecycle도 `ipv6_mode="require"`를 쓰므로 기존 IPv6 검증은 약화되지 않는다. 정책 자체는
`tools/tests/test_loopback_policy.py`가 검사한다. lifecycle 입력 검사에서 dodge 이후 정지 판정은 attack과 같이
`ready_action`(CombatAction IDLE + 접지)을 기다린다. dodge 실행 tick에는 속도가 아직 적용되지
않아, 그 전에 정지를 판정하면 이어지는 dodge 이동을 위반으로 오판한다.

lifecycle probe(`core/validation/session_recovery_probe.gd`)의 watchdog은 둘이다. 실행 중인 명령은
60초(`COMMAND_TIMEOUT_MSEC`) 안에 끝나야 하고, 다음 명령을 기다리기만 하는 역할은 300초
(`IDLE_TIMEOUT_MSEC`)까지 허용한다. controller가 다른 역할을 구동하는 동안 한 역할이 쉬는 시간은 느린
rendered runner에서 1분을 넘는다 — 하나의 60초 watchdog이 이 대기까지 재던 것이 `windows-demo`의
간헐적 `command timeout`(D `field_gear_ready`) 원인이었다. 명령 자체의 제한은 그대로다.

release build(`tools/build_windows_demo.py`)는 검증 전후로 `git status`가 깨끗해야 한다. Godot import가
만드는 `.gd.uid`가 커밋돼 있지 않으면 import 뒤에 untracked 파일이 생겨 "Release source is dirty"로
실패하므로, 새 GDScript의 `.uid`는 반드시 같이 커밋한다(`tools/map_bridge/` 포함).

러너는 실패 시 1을 반환한다. tools/check_project.py는 각 실행을 120초로 제한하고 종료 코드 외에도 SCRIPT ERROR, ERROR/WARNING, orphan/leak 경고와 성공 마커를 검사한다. GitHub Actions는 공식 Godot 4.7.2 Linux 바이너리로 같은 project check, 2-player valid/invalid 및 3-player valid process-restart E2E, 2/3-player individual-world E2E, 2/3-player world-runtime E2E를 실행한다. CI 원격 실행 결과는 실제 push 이후 별도로 확인해야 한다.

## 테스트 구성

기존 test_runner.gd를 유지하고 StabilityTests를 추가했다. v2 fixture를 변경하지 않고 기존 저장 필드와 결과를 비교한다. 새 테스트는 사망/부활/중복 손실, 원정 persistence 차단, 난이도 스냅샷, 효과/장비/주기 tick, 사망 드롭 부분·전체 회수와 재사망, 저장 복원, 전리품 보존, 보상 거래, 선행 조건/제작, 손상 snapshot, Validator 타입/진입점, 실제 근접·투사체, HUD 난이도 동기화를 검증한다.

등반 통합 테스트는 실제 플레이어·하수구 씬과 Input Action을 사용한다. 영역 밖 입력, 진입·정렬·정지·하강·점프·피격·귀환 차단, 사다리 상단 플랫폼 착지와 E 탈출, 밧줄 속도와 하단 이탈을 확인한다. 테스트용 변경 Resource는 복제하거나 임시 등록하고 종료 시 제거한다.

단일-process 저장 writer/reader 검증은 첫 프로세스에서 테스트 전용 `user://return_to_cage_restart_test.json`을 기록하고 다음 프로세스에서 읽는다. 위 multiplayer restart probe는 이 테스트와 별도로 production local profile, production Save v4, Host Saved Game, Join 경로를 실제 child process에서 사용한다.

## 렌더링 자동 점검

GPU/디스플레이가 있는 환경에서 실행한다. headless 물리 테스트와 별개다.

```sh
godot --path . --rendering-method gl_compatibility res://tests/visual_smoke.tscn
```

Visual smoke는 Settlement의 비동기 EnvironmentPresenter 로드 완료를 기다린 뒤 이미지를
캡처하므로 단색 loading fallback이 아니라 실제 sky/cloud 레이어를 검증한다.

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

기존 runner가 dispatch하는 파일 중 안정화·전투 관련 항목은 다음과 같다. 외부 프레임워크를 추가하지 않는다.

- unit/test_inventory_stability.gd: 인스턴스 수량·중복, 내구도, signal 횟수, 정확한 instance 입력과 거래 rollback.
- unit/test_player_state_restore.gd: reset/restore 3회, 보관한 이전 객체의 콜백 차단, 체력·생존·좌표 보정, getter 및 시작 콘텐츠 검증.
- unit/test_settlement_state_restore.gd: unknown pending, storage overflow 합병, 세션 전체 중복, 보상·pending 재진입/원자성.
- unit/test_save_migration.gd: 실제 v1/v2/v3 파일 로드, 잘못된 버전과 필드, 사용자 경고, fatal rollback.
- integration/test_session_stability.gd: null 사망 설정, 전이 거부, duplicate death, 늦은 Actor 시그널, 씬 실패 후 respawn 재시도.
- unit/test_world_runtime.gd: world runtime lifecycle/물리 격리와 함께 authoritative HURT 중
  enter-region/return-to-Settlement가 world/revision, Adventure participation, pending transition,
  spawn assignment를 보존하며 거절되고 HURT 종료 직후 정상 성공하는지 검증한다.
- unit/test_combat_runtime_state.gd: `CombatRuntimeState` reset/spend/regenerate/max 클램프, 실제 Settlement actor의 `CombatComponent`가 `PlayerRuntimeState.combat`을 참조하는지, 공격 성공 시 stamina_cost 차감·부족 시 거절과 값 유지·cooldown 미시작, `_process` 재생과 survival multiplier, stat modifier에 따른 max 변화, unbound component의 null 안전성, 월드 전환 시 유지와 respawn 시 max로 refill.
- unit/test_attack_timeline.gd: `AttackDefinition` timing/spatial 검증(양수 finite range/size,
  finite offset/knockback, zero·음수 knockback 허용, owner id 접두사, ContentDefinition 아님),
  `WeaponDefinition`의 null·중첩 검증, `attack_range` 제거와 shipped `twig_sword`의 0.55초 cadence,
  STARTUP 동안 히트박스 비활성·commit 없음, ACTIVE 진입 시 1회 commit과
  `active_seconds` 만큼의 히트박스 window·스태미나 1회 차감, RECOVERY 중 재공격 거절,
  전체 사이클 후 IDLE과 재공격 허용, 전체 timeline보다 큰 delta에서도 4회 전이·1회 commit,
  phase 경계를 걸친 delta의 잉여 이월. 히트박스 lifecycle(IDLE/STARTUP/RECOVERY에서 비활성,
  ACTIVE에서만 활성, 자체 타이머 없음)과 STARTUP/ACTIVE/RECOVERY 각각에서의 `abort_attack()`
  정리(ACTIVE 이후 abort는 스태미나를 환불하지 않음, 반복 호출 안전). 실제 적을 사거리에 두고
  전체 timeline을 삼키는 큰 delta에서도 melee 판정이 정확히 1회 발생하는지, ACTIVE 도중 사망 시
  즉시 히트박스가 꺼지고 추가 피해가 없는지. projectile은 strategy 직접 호출이 아니라 실제
  `CombatComponent` timeline을 통해 ACTIVE 진입에서 정확히 1개만 spawn되고
  `AttackDefinition.range` 및 동일한 context knockback snapshot을 쓰는지 검증한다.
- unit/test_combat_hit_geometry.gd: twig/custom rectangle size와 right/left offset x mirror(y 유지),
  runtime non-finite geometry 거절, Player/Enemy additive impulse와 zero/non-finite 안전성. 실제
  right/left melee가 Enemy HURT를 유지하면서 authored velocity와 위치 이동을 만드는지,
  Player damage가 velocity/위치에 반영되는지, zero knockback no-op, CLIMB 이탈 후 impulse,
  `causes_hurt=false` impulse가 공격 timeline과 독립인지, presentation actor no-op.
- unit/test_combat_action_controller.gd: combat action 상태 머신의 초기 IDLE, 정상 전이
  (`IDLE → STARTUP → ACTIVE → RECOVERY → IDLE`)와 취소, 불법 전이 거절 및 거절 후 상태 유지,
  IDLE/각 attack phase→HURT와 HURT→IDLE, HURT에서 attack phase/HURT 직접 전이 거절,
  `is_hurt=true`/`is_attacking=false`, 실제 변경 시에만 발생하는 signal과 reset 정책. 실제 PlayerActor 통합으로 wiring,
  `IDLE → STARTUP → ACTIVE → RECOVERY → IDLE` 전체 phase 진행, 각 공격 phase에서 재공격 거절,
  별도 cooldown 없이 IDLE에서만 재공격 허용, 모든 실패 경로에서 IDLE 유지,
  월드 전환·사망·부활 후 IDLE을 검증한다.
- unit/test_attack_combo.gd: `CombatActionWindowDefinition`(half-open `[start, end)`,
  disabled 기본값, 비유한/역전/길이 0 거절, startup·active 안의 window 거절, action 길이를
  넘는 window 거절), `AttackComboDefinition`(빈 combo·null step 거절, step 오류 전파와 step
  번호가 붙은 메시지, 1-step/3-step), `WeaponDefinition` 마이그레이션(`attack_definition`
  부재, `attack_combo` 가 단일 source), 배포된 twig_sword 3-step 의 타이밍·geometry·knockback·
  window 값 고정, `CombatInputBufferDefinition` 검증과 배포 리소스, combo 진행(1→2→3 직접
  전이·transient IDLE 부재·step 별 elapsed·step 별 `DamageContext`·step 당 1회 stamina commit·
  마지막 step 은 chain 불가·종료 시 index 0), buffer 타이밍(startup/active/창 이전에는 대기,
  창이 열리는 순간 실행, 만료된 intent 는 실행하지 않음, 창이 닫힌 뒤의 입력은 이전 combo 를
  잇지 않고 새 combo 를 염, 마지막 step 뒤에도 새 combo, 입력 시점 facing snapshot),
  dodge cancel(startup/active 직접 취소 불가, recovery 창에서 `ATTACK_RECOVERY → DODGE` 직접
  전이, pending/phase/hitbox/combo 정리, attack stamina 환불 없음, 창 밖 거절), buffer 수명
  (latest input wins 양방향, IDLE 거절은 buffer 하지 않음, HURT 진입이 기존 intent 제거,
  HURT 중 새 입력은 살아남아 종료 후 실행, DODGE 는 direct cancel 없이 종료 후 실행,
  실행 가능 시점의 실패는 1회 시도 후 폐기, death 가 buffer 를 비움), presentation timing
  (수신 시 0회, 실행 시 정확히 1회, 교체된 intent 는 영영 0회, buffer 된 sequence 재전송 거절),
  그리고 실제 적을 상대로 한 3타 전부 명중·step 당 1회 타격을 검증한다.
- presentation/tools/validate_player_sprite_pipeline.tscn: `check_project.py`가 content
  validation 직후 실행하는 저장소 상태 검사(`SPRITE PIPELINE VALIDATION PASS`). manifest·생성
  `SpriteFrames`·shipped profile 셋이 서로 맞는지 본다. **art 없음 + placeholder는 PASS**,
  **partial manifest 작업 중도 PASS**, 그러나 preview 산출물이 production 경로에 올라왔거나
  manifest 없이 frames만 있거나 완성 manifest인데 굽지 않았거나 활성화가 반쯤 된 상태는 FAIL이다.
  production state에서는 manifest를 메모리에서 다시 구워 `production_signature`(clip·speed·loop·
  region·**source texture resource_path**·atlas 크기·**frame별 duration**)로 committed resource와
  비교하므로 stale generated resource가 조용히 통과하지 않는다.
- unit/test_player_sprite_pipeline.gd: sprite asset pipeline 회귀. `PlayerSpriteAnimationEntry`
  검증(grid가 texture를 나누지 못하면 거절, frame_count가 grid 초과 시 거절, texture/semantic 누락,
  비유한·0·음수 fps 거절, frame_count < cell 수는 정상), 1024×512/4×2/256×256 규격은 통과하고
  다른 canvas는 error가 아니라 warning이라는 것, `PlayerSpriteManifest`의 중복 semantic·null
  entry 검증과 **구조적 유효성 vs 출시 준비 상태 분리**(일부 clip만 있는
  manifest는 빌드되지만 production ready가 아니고 누락 clip을 이름으로 보고), builder의 row-major
  slicing을 cell마다 다른 색으로 칠한 synthetic sheet로 frame별 region과 실제 픽셀까지 확인,
  fps/loop/clip 이름/frame 수 전파, 같은 manifest 두 번 빌드 시 완전 동일(그리고 manifest가 바뀌면
  달라짐), 생성 resource의 저장·재로드 round trip, frame region이 양수이고 atlas 안에 있으며 한
  canvas를 공유하는지, shipped production manifest/profile 상태 검증(정확한 12 semantic mapping,
  grid/frame count/fps/loop, generated frames 연결, `allow_placeholder=false`, attack partition이 실제
  frame 수 안), 그리고
  presentation transform(art 유무에 따른 sprite↔placeholder 전환, visual scale은 presenter에
  offset은 sprite에만 적용되고 actor root·collision·hitbox·hurtbox는 불변, facing이 authored
  scale의 부호만 뒤집고 reconfigure해도 현재 facing을 유지)을 검증한다. 10A 안정화로 다음이
  추가됐다: manifest가 `faces_right_by_default`/`visual_scale`/`visual_position`을 더 이상 갖지
  않고 `CharacterAnimationProfile`이 단독 소유라는 source-of-truth 고정, build policy 행렬
  (manifest 없음 → skip, 기본 manifest + production 경로 → 허용, 불완전 manifest + production →
  거절, 불완전 + preview + 비production 출력 → 허용, preview flag + production 경로 → 완성
  여부와 무관하게 거절, 구조적으로 깨진 manifest → 항상 거절), `production_signature`가
  `describe()`와 달리 같은 크기의 다른 source sheet 교체를 잡아낸다는 것, 그리고 pipeline
  state A~G 전부를 synthetic resource로 재현한 검증(profile이 다른 SpriteFrames를 가리키는 경우와
  manifest가 앞서 나가 committed resource가 stale해진 경우 포함, 실제 저장소 상태도 PASS 확인).
  10B 최종 hardening 으로 두 가지가 더 붙었다: canonical path 비교
  (`./`·`foo/../`·중복 `/` 로 쓴 production 경로를 전부 같은 파일로 인식하고, custom manifest 가
  그 철자로 shipped 경로에 쓰려는 시도를 거절하며, `res://`/`user://` 밖의 경로와 빈 경로는
  아예 거절 — 이 판단은 manifest 존재 여부보다 **먼저** 하므로 art 가 없는 상태에서도 오타
  argument 가 skip 으로 새지 않고, 반대로 equivalent 철자의 유효한 기본 경로는 계속 SKIP 이다),
  그리고 error aggregation(duplicate semantic·null texture·invalid fps 를 한 번에
  보고, 누락 clip 전부 나열, profile 의 여러 binding 오류도 함께 보고). 앞선 사전 안정화에서는
  두 가지가 붙었다: `production_signature`가 frame별 duration까지 담아
  editor에서 한 frame만 손으로 retime한 generated resource를 stale로 잡아내고(`describe()`는
  같은 편집을 보지 못한다), build policy가 manifest 출처까지 본다는 것 — 기본이 아닌 manifest는
  완성돼 있어도 production 경로에 쓰지 못하고(preview flag 유무와 무관), 자기 출력 경로에는
  완성/불완전 모두 정상적으로 쓴다.
- unit/test_player_animation_presentation.gd: presentation-disabled actor의 visual 미생성,
  presentation-enabled actor의 단일 lazy production visual/placeholder fallback, shipped profile 및 synthetic
  SpriteFrames profile 검증, idle/run/jump/fall/climb/climb_idle resolver, 권위 actor의
  Death/HURT/Dodge/Attack 우선순위와 remote latest-valid-event ordering, root transform과
  분리된 facing flip, committed attack/dodge facing, combo clip 직접 전환, authoritative
  `attack_elapsed()` seek와 8-frame phase partition, HURT refresh frame-0 restart, malformed/stale
  payload 무시, HURT→Attack/Dodge 및 Dodge↔Attack 전환, death absolute override,
  left-canonical climb facing과 remote gameplay isolation, Protocol 15/Save v4를 검증한다.
- 8차 안정화 회귀는 위 두 파일에 들어 있다. `test_attack_combo.gd` 는 `CombatComponent` 가
  `_process` 를 선언하지 않고 `physics_tick` 만 가진다는 것(단일 clock 고정), 실제 권위 tick
  순서(`hurt → dodge → combat → input_buffer`)를 모사한 helper 로 chain window 가 열리는
  프레임에 같은 프레임 chain 이 성립하는지, 같은 조건에서 buffer 를 combat 보다 먼저 tick 하면
  한 프레임 늦는지(순서가 계약인 이유), dodge cancel window 도 같은 프레임에 열리고 쓰이는지,
  만료 경계 두 경우(잔여 0.020 은 살아 chain, 0.010 은 만료되어 window 가 열려도 chain 없음),
  그리고 손으로 tick 하지 않고 실제 physics frame 만으로 buffered intent 가 chain 되는지를
  검증한다. `test_player_hurt.gd` 는 재피격 refresh 시 timer 갱신·`HURT → HURT` signal 부재·
  기존 buffer 폐기·폐기 후 새 입력의 재buffer 와 HURT 종료 후 실행, 그리고
  `causes_hurt = false` 피해와 회피된 공격이 buffer 를 건드리지 않음을 검증한다.
- unit/test_player_dodge.gd: `DodgeDefinition` 검증(양수 유한 duration/speed/cost, half-open
  i-frame 창의 시작<끝과 duration 내부 포함, 비-ContentDefinition, 배포 리소스 유효성),
  `DODGE` 전이표(IDLE→DODGE만 허용, attack/HURT에서 DODGE 진입 거절, DODGE→IDLE/HURT),
  소유자별 control lock(누적·소유자별 해제·빈 source 거절), `PlayerDodgeCommand`의
  sequence/±1 direction 분리 검증과 `dodge` 입력 액션 존재, dodge 타임라인(시작 시 스태미나
  1회 commit·환불 없음·중간 입력으로 방향 변경 불가·oversized delta·스태미나 부족 거절),
  i-frame(창 안 evadable 피해 무효화·periodic/starvation/`can_be_evaded=false`는 관통·창 종료
  후 정상 피격·god mode 미사용), HURT interrupt(직접 DODGE→HURT·넉백 velocity 보존·환불 없음·
  dodge lock만 해제·dodge로 hit-stun 탈출 불가·dodge로 attack 캔슬 불가), locomotion 경계
  (지상 시작 전용·위치 직접 조작 없음·낭떠러지 AIR 낙하 유지·벽 통과 불가·입력/점프 잠금),
  권위 guard(interaction/quick item/consumable/world transition 거절과 종료 후 재허용),
  network intent(sequence 소비 순서·중복/역행 거절·malformed direction 거절·presentation 경로가
  시뮬레이션하지 않음), death/world transition 정리를 검증한다. 7차 안정화로 다음이 추가됐다:
  dodge 입력 edge 가 그 시점 `Input.get_axis` 를 스냅샷해 `dodge_requested(±1/0)` 를 emit하고
  stale cached axis 를 무시하는지, 정상 종료가 `velocity.x` 만 0 으로 되돌리고 낭떠러지에서
  끝난 dodge 의 수직 속도는 보존하는지, HURT interrupt 는 넉백 velocity 를 그대로 두는지,
  현재 입력 방향이 facing 보다 우선하고 입력이 없을 때만 facing 으로 fallback 하는지, 비정규
  direction(0.5 / 0.999999 / NaN / INF)을 반올림하지 않고 거절하는지, `mode == GROUND` 라도
  실제 `is_on_floor()` 가 false 면 dodge 를 거절하고 스태미나·lock 을 건드리지 않는지, 그리고
  Return Channel 정책 A(유효한 dodge 는 채널을 정확히 한 번 취소하고 `movement.enabled` 를
  복구, 거절된 dodge 는 stamina/AIR/HURT/malformed 어느 경우에도 채널과 `movement.enabled` 를
  그대로 둔다)를 검증한다. dodge fixture 는 `movement.mode` 를 강제로 쓰지 않고 실제 physics
  frame 을 돌려 접지시킨다.
- unit/test_player_hurt.gd: 0.25초 HURT lifecycle/control lock과 re-hit timer refresh(signal 없음),
  STARTUP/ACTIVE/RECOVERY 직접 interruption, phase별 stamina 소비·비환불, melee hitbox cleanup,
  projectile commit 전 spawn 차단과 commit 후 projectile 생존, HURT 중 attack/network command·수평
  입력·jump·climb·interaction·quick item 거절, gravity/knockback displacement 유지, zero-knockback
  HURT와 non-reaction impulse의 독립성, periodic/starvation no-HURT, lethal/death/respawn reset,
  IDLE lethal hit의 transient HURT 부재, HURT 종료 후 interaction/item 재허용, world transition의
  scene-local reset과 locomotion enum 비오염, 실제 server item command의 HURT 거절을 검증한다.
- world-runtime process E2E 는 8차 경계도 확인한다: 호스트가 remote B 를 hit-stun 으로 묶은
  상태에서 B 의 attack intent 를 받아 buffer 하고(실행되지 않고 sequence 는 유지), 그 동안
  클라이언트에 presentation 이 가지 않으며, hit-stun 해제 후 intent 가 실행되고 그때 정확히
  한 번 presentation 이 도착하는지 본다. 정확한 chain/cancel 타이밍은 왕복 지연에 민감하므로
  unit/integration 이 맡고 E2E 에 넣지 않는다.
- world-runtime process E2E(`tools/test_multiplayer_world_runtime.py`)는 remote client의 dodge
  intent가 호스트에서만 실행되는지도 확인한다: 클라이언트 intent → 권위 dodge 시작과 i-frame/
  스태미나/control lock, 창 안 evadable 피해 무효화, presentation actor가 DODGE도 i-frame도
  갖지 않음, dodge 중 return/escape 거절(world/revision·spawn assignment·adventure 참여 보존),
  dodge 종료 후 lock/i-frame 해제, ±1이 아닌 direction의 거절을 검증한다.
- integration/test_multiplayer_combat_loot.gd: 기존 전투/사망/loot claim 외에 권위 HURT actor의
  gather와 loot pickup이 mutation 없이 거절되는지 검증한다.
- unit/test_combat_runtime_replication.gd: `CombatRuntimeState.apply_values` 검증,
  `PlayerRuntimeSnapshot`/`PlayerCombatRuntimeSnapshot`의 payload 왕복과 누락·타입·음수·
  초과·NaN/INF 거절, sequence 최신/중복/역행 처리, 값이 변하지 않을 때의 패킷 억제,
  스냅샷 적용 후 `CombatRuntimeState` 객체 identity 유지, 플레이어 간 격리(B 갱신이 C를
  건드리지 않음), HUD가 scene component가 아니라 runtime mirror를 읽는지.
- unit/test_environment_presentation.gd: EnvironmentDefinition/BackgroundLayerDefinition 저장·필터, presenter의 cover fit·parallax·autoscroll·repeat·z 클램프, 4:3·16:10·21:9 viewport coverage, 빈/누락/잘못된 타입 경로의 안전한 fallback, 로딩 중 즉시 fallback 색, 비동기 Preset 로드와 scene 제거 후 non-blocking token 회수, Settlement/Adventure visible presentation에는 EnvironmentPresenter가 생성되고 `server_runtime_mode` 및 ServerWorldRuntime scene에는 생성되지 않는 경계.

Resource.duplicate(true) 이후에도 외부 Resource는 공유될 수 있다. 테스트가 변경할
SurvivalConfig 같은 외부 Resource는 명시적으로 복제해 원본 콘텐츠를 오염시키지 않는다.

`tests/unit/test_reward_save_boundary.gd` saves synchronously from the storage
notification during pending/quest reward claims, then loads and retries the claim
to check quantity conservation. It also exercises fractional, oversized,
non-finite, negative and mistyped quest progress. These regressions failed on the
previous implementation.

전체 실행은 `TEST PASS: <n> assertions` 를 출력하고 러너가 실패 시 1을 반환한다.
assertion 총계는 테스트가 늘 때마다 바뀌므로 이 문서에 고정 숫자를 적지 않는다.
판단 기준은 `tools/check_project.py` 의 `ALL PROJECT CHECKS PASS` 와 각 멀티플레이
하네스의 종료 코드다.

## Disconnect menu recovery

Audited baseline: `14c3eac23a4cbfb4a2746dcb141daa1457e876e6` (master).
`integration/test_disconnect_recovery.gd` reproduced ten failing assertions before
the fix. In particular, a baseline New Game mouse click worked, but the same
enabled button received no click after Disconnect: the still-visible full-screen
HUD intercepted GUI input. Additional failures identified the retained Adventure
facade (blocking `SaveManager.can_load()`), stale SceneRouter assignment cache,
reentrant menu starts, retired transport callbacks and old actor HUD signals.
Identity activation and basic transport cache clearing already worked.

The focused test now checks 38 assertions. It injects mouse motion/down/up through
`Viewport.push_input`, including normal GUI hit testing; checking `disabled` alone
does not count as input verification. Run it alone or with the full suite:

```sh
godot --headless --path . res://tests/test_runner.tscn -- --disconnect-only
python tools/check_project.py --godot <godot-4.7.2>
python tools/test_multiplayer_disconnect.py --godot <godot-4.7.2>
python tools/test_multiplayer_disconnect.py --godot <godot-4.7.2> --rendered
```

The process harness keeps A, B and a replacement Host D alive throughout their
scenarios. Production Boot buttons receive real Godot GUI mouse events. Only the
port is supplied to the same production Host/Join handlers. Isolated user-data
directories and newly created test profiles keep production identities/Saves out
of the test. It covers Host Disconnect → New/Load/Host/Host Save, explicit Client
Disconnect → New Game, automatic server loss → New Game/rejoin, and joining the
replacement Host at `::1` (the IPv6 step; IPv4 fallback only under `--ipv6 auto` without IPv6)
after the first Host at `127.0.0.1`. Host Save is repeated
with the same saved session ID after an Adventure increased the old revision.

Every menu checkpoint verifies offline transport, empty attachment/ready/roster
caches, no pending transition/spawn, one unchanged local identity, empty session
ID, no Adventure sessions/runtimes/presentation actors, hidden/unbound HUD and
enabled menu actions. Profile and Save hashes must remain unchanged, offline
simulation authority must recover, and retired transport/timer events must not
close a new game. A process must exit zero with no engine errors or leak warnings;
the harness waits for scene cleanup and background resource loads before quitting.

`--rendered` defaults to `gl_compatibility` and rejects a headless display server;
`--rendering-method forward_plus` is available for machines that can run multiple
Forward+ contexts. The local rendered regression used Compatibility, not Forward+.
These are local ENet tests, not a two-physical-PC/LAN certification. CI runs the
headless process harness on Linux and Windows and uploads its logs/step results.
No player-roster display synchronization is added by this stage.

## Player presentation roster recovery (Stage 2)

See [player_roster_recovery.md](player_roster_recovery.md) for the reproduced
failure paths, actor replacement ordering, and headless/rendered 2/3-player ENet
commands. These tests inspect the actual Host presentation roster separately
from the authoritative runtime roster. Full checks include
`integration/test_player_presentation_roster.gd`; the focused runner flag is
`--roster-only`. Existing world-runtime E2E now also verifies that every returned
same-world player is visible and processing in the Host presentation.

## Integrated recovery / Windows release (Stage 3)

[release_recovery_validation.md](release_recovery_validation.md) documents the
same-process GUI sequence, the shared Editor/EXE assertions, state diagnostics,
full regression commands and clean-commit/SHA-256 publication boundary. The
original Editor/content/Host-Join checks remain and are extended by real release
EXE New/Load/rehost/rejoin/map roster tests, in both headless and GUI modes.


## Inventory / equipment GUI

See [inventory_ui.md](inventory_ui.md) for the UI/model boundary and controls.
The full runner includes `test_inventory_windows.gd`; use `--inventory-ui-only`
for focused checks. `tools/test_inventory_ui.py --rendered` uses isolated profiles
and real Godot GUI input, validates read-only snapshots, and captures a viewport
PNG. Windows release lifecycle checks also exercise these windows in the actual
EXE; existing content/ENet/roster/recovery assertions remain in place.

Stage 4-A adds hit-tested drags, split confirmation/cancel, hidden slot and bag
guards, second-page indices, whole-bag sort and Shift/dodge routing. The shared
Editor/EXE lifecycle checks real client drag approval, pending immutability,
duplicate input, old results, server rejection, world travel and reconnect.

Stage 4-B exercises double-click equip, replacement, unequip and consumption,
both drag directions, wrong equipment slot, legacy IDs, full-bag rollback,
derived stats and effects, and Save v5 load. The Editor/EXE lifecycle also uses
real Host and Client GUI commands, checks transition rejection, attempts to equip
the Host's instance from a Client, and verifies equipped state across rejoin.

Stage 5 covers the new slots, crafted output rollback, Save v5 reload, owner-only
mirrors and wrong-slot rejection. Projection tests compare live results under
temporary and gear multipliers, including broken equipment, and check that
previewing never changes health, signals or effect timers. The GUI and ENet
probes check slot layout, live stats, comparison and private remote crafting.

## Fixed inventory slot model (Stage 2)

The full runner includes tests/unit/test_inventory_slots.gd; --inventory-slots-only selects it. Tests cover sparse moves/swaps/merges/splits/sort/resize, failed-command layout rollback, instance conservation, real crafting/storage/equip/death paths, Save v4/v16 dense-format limitations and seeded mixed-operation invariants. Read-only GUI regressions check holes at actual model indices. See [inventory_slots.md](inventory_slots.md).

## Slot persistence and server intents (Stage 3)

The full runner includes `test_inventory_persistence.gd`; `--inventory-persistence-only` runs its Save v5/v17 boundaries. The source/release lifecycle adds real positive and forged slot RPCs, reconnect/world/privacy checks. Restart probes validate expanded sparse bags/storage, and mismatch uses the previous protocol (v19) against v20. See [inventory_persistence.md](inventory_persistence.md).

## Item data stability (Stage 6-A)

Run the focused suite with `--item-boundaries-only`. It covers legacy and
identified equipment in one sparse storage layout, duplicate transfer
rollback, authority-issued IDs, timed and stacked effects, death-drop
identity, broken or lost gear at respawn, invalid Save v5 and sparse crafting.
The shared lifecycle probe sends two ENet crafting requests against the same
materials, checks duplicate and stale sequences while materials are available,
then saves and rehosts with the exact crafted owner layout and identities.

## Scene 기반 필드 검증

표준 `tools/check_project.py`의 `test_field_scene.gd`가 하수구 지형과 마커의
이관 값, 잘못된 마커 ID, 필수 매니저, PackedScene 저장 및 캐시 없는 재로드를
검사한다. `tools/test_multiplayer_world_runtime.py --godot <godot> --players 2`
및 `--players 3`은 실제 ENet 스폰, 전투와 전리품, 지역 전환, 채집 지급과 중복
방지를 검증한다. 3인 테스트에서는 한 참가자가 기존 지역에 남은 상태에서
다른 참가자가 재진입해 이미 소모된 채집 상태를 받는지 검사한다.

에디터 배치와 저장·재열기 검증은 [Field Editor 테스트](field_editor.md#검증)를 참고한다.

STEP 3 Field Editor 프로브는 반대 방향 사각형, 음수·비균일 부모 변환,
줌·팬 좌표 변환과 Alt 우회, 잠긴 레이어, 스트로크 단위 Undo/Redo를 검사한다.
렌더링 모드는 실제 에디터 입력 경로로 Rectangle·Paint·Erase를 실행하고,
레이어 숨김 중 저장한 씬의 충돌 및 가시성을 재로드해 비교한다.

STEP 4 에디터 프로브는 Erase 복원의 순서와 owner, 큰 플랫폼과 Paint의 교차,
레이어가 다른 중첩 부모 거절을 검사한다. 크기 핸들의 고정점, 브러시 시드·간격·Undo,
중복 ID 재발급, 참조된 ENTRY 제거 거절과 RegionDefinition 저장·Undo·Redo를
검사한다. 렌더링 프로브는 핸들과 브러시에 실제 에디터 마우스 이벤트를 주입한다.

STEP 4 안정화 프로브는 격리된 씬의 부분 저장 실패, 읽기 전용·누락 리소스, 씬
저장 후 리소스 교체 실패를 재현한다. 파일 해시, 메모리의 선언, Undo/Redo 커서를
비교하고 씬 탭을 전환한 뒤에도 이력이 실제 파일에 반영되는지 검사한다. 장식
브러시는 중복 3,000개를 지나는 단일 이동에서 배치 상한 2,048개를 검사하고,
최소 간격에서 입력 이벤트를 여러 번 나눠도 같은 시드의 결과가 유지되는지 확인한다.

STEP 5 에디터 프로브는 템플릿 3종, 게시 실패 복구, 프리셋 배치와 외부 파일
충돌을 검사한다. 이어 별도 게임 프로세스에서 생성된 콘텐츠를 자동 등록하고,
테스트 전용 출구를 연결한 후 신규 필드의 플레이어 스폰, 적, 채집, 충돌과
표시 전용 장식을 검증한다.

STEP 6 extends the Field Editor probe with shared ENTRY validation, resource
save/reload and undo conflicts, region marker selection, authored spawn
diagnostics and environment selection. The same harness runs the saved new
region through the isolated playtest probe. To run that probe for a saved region:

```sh
python tools/playtest_region.py --godot godot --region sewer_region
```


STEP 6 stabilization adds a sewer clearance regression that identifies an
attached player's capsule as the post-spawn blocker and checks RID exclusion,
disabled/layer filters, support, singular transforms and detached prefab Size.
Editor probes check Collision Source selection. Runtime report fixtures require
PASS_WITH_WARNINGS for limited capacity, FAIL for a blocked ENTRY and FAIL for
duplicate slots. The rendered harness also opens an interactive game and
injects move, jump, climb and escape input. Climb/escape fixture positioning is
synthetic. This is separate from a physical mouse/keyboard manual playthrough.


During STEP 6 stabilization on Windows, Godot 4.7.2 sometimes terminated after
a success marker with native exception 0xC0000005 (3221225477). The same shutdown
failure reproduced in an isolated checkout of the unmodified 4c39e64 baseline
after FIELD EDITOR PROBE PASS. Windows Application events named the Godot module
at offset 0x547f2c. A sprite-pipeline process also printed PASS before a failed
shutdown. Functional success and process success must be recorded separately.
The editor runner now prints each child return code and continues to fail on
abnormal exits. An editor shutdown also reported CowData modified during destruction with exit 0, which the runner correctly rejects because of the engine error. The native root cause remains unconfirmed.

## Field Editor traversal verification

STEP 7의 단위/격리 물리/렌더링 입력 검증은 기존 `tools/test_field_editor.py`에 포함된다.
실제 PlayerActor 입력, 연속 경로 재생, 제한된 분석 범위와 네이티브 종료 코드 판정은
[traversal_analysis.md](traversal_analysis.md)의 테스트·제한사항을 참고한다.

STEP 7 안정화의 반복 실행, Windows dump 조사와 프로세스 소유권/취소 검사는
[step7_stability.md](step7_stability.md)를 참고한다. `tools/repeat_stability.py`는 성공 마커와
정상 종료를 따로 기록하고 실패 로그도 보존한다. 네이티브 종료 문제는 미해결이다.

2차 조사에서 확인한 엔진 종료 iterator 수명 결함, 일치 소스/PDB 덤프,
GUI native mouse-enter 입력 수정 및 공식 바이너리의 최종 반복 결과는
[step7_stability_round2.md](step7_stability_round2.md)에 기록한다.
작업 보관 안전성은 `python tools/test_traversal_jobs.py`, worker 생명주기는
`python tools/test_traversal_process.py`로 별도 검사한다. 커스텀 엔진 패치의
검증과 공식 엔진의 반복 안정성은 동일한 결과로 취급하지 않는다.

## Forest Trail · Enemy 애니메이션 · 개구리

| 검사 | 위치 | 확인하는 것 |
|---|---|---|
| 숲 씬·콘텐츠 | `tests/unit/test_forest_region.gd` | 정의·씬 검증, scaffold 그룹, 9-Slice 테마 4종, 스폰 슬롯, `forest_gate`, 새 게임 해금, 배경 3레이어 순서 |
| Enemy 애니메이션 | `tests/unit/test_enemy_animation.gd` | 딱정벌레·개구리 profile 검증, clip 존재, frame이 서로 다른 sheet cell인지, 타격 frame과 공격 상태 시간의 정합, 상태→clip, 매 frame 재시작 방지, 좌우 반전이 visual child에만 적용되는지, death 1회 재생, 복제 actor의 표현, 서버 런타임 actor에 visual이 없는지 |
| 개구리 AI | `tests/unit/test_frog_enemy.gd` | 실제 숲에서 실제 PlayerActor로: hop 순찰과 반경·지형 유지, 접지 상태에서만 발사, 탐지→alert→chase→attack, 도약당 최대 1회 피해, 쿨다운, 대상 상실 후 복귀, 가장자리 감지, hurt, death와 제거 |
| 지역 런타임 | `python tools/playtest_region.py --godot <godot> --region forest_region` | 스폰·ENTRY·ESCAPE·채집·Enemy 4/4·정착지 복귀 |
| ENet | `python tools/test_multiplayer_forest.py --godot <godot> --players 2`(3) | 서버 전용 스폰, client roster, 서버 개구리의 타깃·도약 피해(도약당 1회), replica의 jump_start/공중/attack clip, replica가 물리·hurtbox를 갖지 않는지, leash 복귀, 늦게 들어온 client(3인)와 host의 roster 복원, 가까운 플레이어로 재타깃, 딱정벌레·개구리의 death 표현과 제거 복제 |
| 렌더링(GUI) | `python tools/test_forest_visual.py --godot <godot> --artifacts <dir>` | **창을 띄워** 숲에 들어가 실제 입력 action으로 걷고 공격한다. 네 Enemy의 presenter가 켜지고 placeholder polygon이 숨는지, 딱정벌레 5개·개구리 8개 clip이 실제로 재생됐는지, 네 마리가 실제 공격 입력으로 제거되는지 확인하고 screenshot을 남긴다. headless에서는 실패한다. Enemy 옆 배치만 합성이며, 아트 품질은 사람이 screenshot으로 본다. CI에는 넣지 않았다(로컬 검증용) |
| Python Map Editor | `python tools/python_map_editor/check_forest_region_bridge.py --godot <godot> --artifacts <dir>` | 숲 import, Schema V6 왕복, 무변경 저장의 바이트 동일성, V6 이전 문서의 Enemy marker 보존, 편집 후 재로드, Enemy 스폰 이동·종류 변경·끄기·삭제·추가, 잘못된 Enemy 목록 거절 |
| Python Map Editor 문서·UI | `python -m pytest tools/python_map_editor/tests/test_enemy_spawns.py` | V6 왕복, Enemy 없는 문서가 이전 버전 그대로 쓰이는지, V4/V5의 Enemy 필드와 목록 없는 V6 거절, 필드 검증, 64자 Enemy ID의 스폰 ID 생성(번호 보존·삭제 후 재사용·같은 prefix), 깨진 리소스가 섞인 Enemy 카탈로그, 꺼진 스폰의 잘못된 참조, 브리지 재로드 비교, **실제 마우스·키보드 입력**으로 배치 종류 선택·연속 배치·수정·삭제·Undo, V6 이전 연결 문서의 재가져오기 안내와 미저장 편집 보존 |
| V6 데이터 안전 | `python tools/python_map_editor/check_enemy_spawn_bridge.py --godot <godot> --artifacts <dir> --round-trips 10` | 일회용 프로젝트 사본에 실제 게시 후 재로드: V5 연결 문서의 Enemy 보존, 빈 목록의 전체 삭제와 `enemy_ids`, 재추가, 꺼진 스폰, Enemy가 있는 새 지역, 잘못된 목록 거절, 바뀐 원본 거절, 게시 취소, UID 보존, 반복 왕복 |
| 패키징 EXE | `python tools/python_map_editor/verify_windows_package.py <zip> --artifacts <dir> --bridge-project . --godot <godot> --include-design` | OneDir EXE에서 실제 입력으로 개구리 배치 → Sewer 쌍 게시 → 재가져오기 → `.rtcmap` 재열기, 모든 Godot 자식 프로세스의 종료 코드·native crash·누수 감사 |

숲 지형을 고치면 실제 입력으로 입구→전망대 경로와 움푹한 구간 탈출을 다시 확인한다. 자동화된
경로 검증은 Field Editor의 Traversal 분석을 쓴다.

## Monster Editor GUI · Bridge · Import (MONSTER-STEP 2)

편집기와 읽기 전용 Bridge의 검사다. 기록은 [monster_editor_step2.md](monster_editor_step2.md).
의존성: `python -m pip install -r tools/python_monster_editor/requirements.txt` (PySide6-Essentials 6.11.3).

| 검사 | 명령 | 범위 |
|---|---|---|
| Application (`tests/test_application.py`) | core와 같은 pytest 명령 | 문서 세션(dirty = fingerprint 비교, Undo/Redo, 저장·충돌·다시 열기), 프로젝트 설정의 전부-또는-전무 적용, ID 상태 3종, 초안끼리 ID 충돌, 링크로 프로젝트 밖을 가리키는 폴더, 설정 손상 복구, 검증 결과의 오래됨, 늦게 온 작업 결과 폐기, **하위 계층이 Qt를 import하지 않는지** |
| Bridge (`tests/test_bridge.py`) | 〃 | 대역 실행 파일로 응답 대조(다른 요청·protocol·명령·프로젝트), crash·제한 시간·취소·손상 JSON·스크립트 오류의 오류 코드, 임시 파일 정리, 기록된 probe에서 Import한 문서가 예제와 같은지, profile 등록 |
| GUI (`tests/test_gui.py`) | 〃 (Linux는 `QT_QPA_PLATFORM=offscreen`) | 실제 `QApplication`과 위젯. `test_input_…`은 `QTest` 키·마우스 입력이고 나머지는 창의 공개 메서드다. 창·메뉴·단축키, 새 몬스터 대화상자의 ID 상태, 열기 실패 5종, 필드 확정과 Undo 단계, 잘못된 입력, 저장·다른 이름 저장·충돌 4갈래·저장 실패, 닫기 보호, 복제, 초안 삭제, 스키마에서 생성된 Inspector, 읽기 전용 영역, 전리품, 검증 칩·오래됨·finding 이동, 카탈로그 검색·필터·선택 유지, 레이아웃·설정 복원, 썸네일(구조/디코딩 실패), 대역 Godot으로 Import·실패·늦은 결과 폐기·취소. 창 단위 단축키 테스트 2개는 offscreen에서 건너뛴다 |
| GUI 스모크 | `python tools/python_monster_editor/main.py --smoke-report <json> --smoke-shots <dir> [--project . --godot <godot>]` | 네이티브 창에서 실제 입력으로 한 흐름 전체: 새 몬스터 → 편집 → 단축키 Undo/Redo → 전리품 → 검증과 finding 이동 → Ctrl+S → (Godot이 있으면) registry 확인과 두 몬스터 Import → 복제 → 닫기 보호 → 새 창에서 설정 복원과 재열기 → Small·Medium·Large 문서 응답 시간. 화면 9장과 시간을 남긴다. `--project/--godot`이 없으면 Import는 `NOT_EVALUATED`로 기록된다. 배율은 `QT_SCALE_FACTOR=1 / 1.5 / 2` |
| Godot Import | `python tools/python_monster_editor/check_godot_import.py --godot <godot> --artifacts <dir>` | 실제 Godot. **game**: 두 기준 몬스터의 Import가 예제와 같고, 저장·재열기가 같고, 프로젝트 파일 해시가 전후 같다. **isolated**: 프로젝트 사본에 몬스터 둘을 추가 — 기존 actor의 새 몬스터는 자기 ID·값으로 완전 Import, 모르는 actor는 미지원으로 보고. **failures**: 실행 파일 없음·다른 버전·없는 몬스터·제한 시간·취소 |

새 Godot 파일을 추가했으면 `git add` 한 뒤 `check_contract_extensibility.py`를 돌린다 — 이 검사는 추적되는 파일만
복사하므로 스테이징 전에는 probe가 멈춘다. Windows의 Godot은 Bridge·probe 실행 뒤 종료 도중 드물게 crash한다
(`0xC0000005`, 수 % 수준). Bridge client는 읽기 전용 호출을 최대 3회 다시 실행한다
([monster_editor_bridge.md](monster_editor_bridge.md)).

확인하지 않는 것: OS 네이티브 파일 대화상자(테스트는 `ScriptedPrompts`로 대체), 사람이 직접 조작하는 검사, macOS.
GUI 테스트에서 `QTest.keyClicks`는 ASCII만 보낼 수 있다(그 밖의 문자는 프로세스가 중단된다). 한글 입력은
`QInputMethodEvent`의 commit string으로 보낸다.

## Monster Editor core (MONSTER-STEP 1)

`.rtcmonster` 문서 core와 실제 Godot 리소스의 계약 검사다. 설계는 [monster_editor_architecture.md](monster_editor_architecture.md).

| 검사 | 명령 | 확인하는 것 |
|---|---|---|
| Python core | `python -m pytest tools/python_monster_editor/tests -q -rs -p no:cacheprovider` | 문서 생성·기본값, 정규 직렬화와 무변경 왕복, 손상 JSON·미지원 버전·NaN·모르는 필드 거절, **문서 불변성과 Undo/Redo 스냅샷 독립성, 원자적 편집과 ID 이름 변경**, 원자 저장과 외부 변경 감지, **저장 장애 주입 7종과 스레드·프로세스 동시 저장**, 영역별 검증 규칙, **레지스트리 확장(테스트 전용 모듈·조건·이벤트)과 범용 코드에 이름이 없는지, finding 코드 선언, 결과 무효화**, **카탈로그 중복·부분 실패, PNG 손상 19종**, tick 양자화(30/60/120 Hz)와 좌표 변환 조합, **기록된 probe에 대한 계약 평가(신규 몬스터 추가 포함)**, 스키마 문서의 표가 코드와 같은지 |
| 예제 정적 검증 | `python tools/python_monster_editor/validate.py tools/python_monster_editor/examples/*.rtcmonster --project .` | 세 예제의 영역별 상태. `runtime`·`network`는 항상 `NOT_EVALUATED` |
| Godot 계약 | `python tools/python_monster_editor/check_godot_contract.py --godot <godot> --artifacts <dir>` | `tools/monster_bridge/contract_probe.tscn`을 실제 엔진에서 실행하고 다섯 계약으로 나눠 판정한다. **environment**: 엔진 버전, physics tick(60), 프로토콜(20), 깨끗한 엔진 로그. **registry**: 등록된 **모든** 몬스터의 정의 유효성, actor scene, 필수 컴포넌트, shape, loot, profile, headless 실행, 서버 모드 presenter 없음 — 예제 문서 없이. **legacy**: 기준 몬스터(딱정벌레·개구리)의 예제를 실제 값과 대조. **data_driven**·**behavior**: 런타임이 없어 `NOT_EVALUATED`. Godot 종료 코드 0만으로는 통과가 아니다(완료 표시와 유효한 결과 필요). `contract_report.json`에 commit·버전·영역별 상태·개별 결과를 남긴다 |
| 계약 확장성 | `python tools/python_monster_editor/check_contract_extensibility.py --godot <godot>` | 추적 파일만 복사한 격리 프로젝트에 새 `EnemyDefinition`을 추가해 실제 Godot으로 확인한다: 예제 없이도 통과하고 registry가 새 몬스터를 검사한다 / 정의를 깨뜨리면 registry에서 실패하고 legacy는 영향받지 않는다 |
| 측정 | `python tools/python_monster_editor/benchmark.py --output <json>` | Small·Medium·Large 문서의 생성·편집·직렬화·검증·저장 시간과 Undo 스냅샷 메모리. 통과/실패 기준이 아니라 기록이다 |

이 검사들이 **확인하지 않는 것**: 데이터 기반 몬스터의 실행. 그런 런타임은 아직 없고, 해당 항목은
`NOT_EVALUATED`로 출력된다. 게임에 몬스터를 추가해도 예제 문서는 필요 없다(registry 계약이 검사한다). 기준 몬스터의
스크립트·scene·리소스를 고치면 legacy 계약의 "source files" 항목이 실패한다 — 예제가 여전히 게임과 같은지 확인한 뒤
`--refresh-bindings`로 해시를 갱신하고, `probe.json`을 `tests/fixtures/contract_probe.json`에 복사한다.
CI는 `.github/workflows/python-monster-editor.yml`이다: Ubuntu·Windows의 pytest(core·application·bridge·GUI)·예제
검증·스키마 문서 최신성·측정, Ubuntu의 Godot 계약 검사·확장성 검사·Import 검사, Windows의 GUI 스모크(3개 배율,
실제 Godot)와 Import 검사. JUnit XML, 계약 JSON, Godot 로그, 측정 결과, 스모크 화면과 보고서를 artifact로 남긴다.
Godot을 실행하는 검사는 순차로 돌린다. 실행 중에는 `.godot` 캐시나 `.uid` 파일을 지우지 않는다 — 지우면 다음 실행이
"Missing .uid" 경고로 실패한다(코드 문제가 아니며 한 번 더 실행하면 사라진다).
