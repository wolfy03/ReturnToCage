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
개별 복귀 동안 C runtime은 유지되고, 마지막 참가자 퇴장
뒤 runtime 정리와 fresh 재생성을 확인한다.

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
