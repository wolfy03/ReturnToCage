# Integration & Runtime Stabilization (2026-11)

master `6e35d51`(Forest, Map Editor Schema V6, Monster Editor STEP 1, 새 햄스터 sprite·착지 clip, 하수구
`FieldPlatform` 지형이 합쳐진 시점)에서 드러난 문제를 원인별로 정리한 기록이다. 브랜치는
`fix/integration-runtime-stabilization`. 결과 상태의 정의는 [known_issues.md](known_issues.md)를 본다.

환경: Windows 11, Godot 4.7.2-stable(official), Python 3.14.5, PySide6 6.11.3, Forward+ / headless,
NetworkProtocol 20, Save v5. 엔진 버전과 프로토콜은 바꾸지 않았다.

## 1. 문제별 원인과 수정

| 문제 | 근본 원인 | 수정 | 상태 |
|---|---|---|---|
| 3인 probe 점프 단계 timeout | 점프가 unreliable 이동 packet **하나**에만 실렸고 그 packet이 전송 중 유실됐다 | 클라이언트가 0.15초 동안 플래그 유지, 호스트는 상승 에지에서 1회 실행 | 해결 |
| 릴리스 lifecycle Role D `host`의 `command timeout` | probe watchdog의 idle 제한이 "busy를 관측한 프레임"에서만 갱신됐다 | `CommandWatchdog`: 명령 수락 시 두 제한 모두 재시작 | 해결 |
| 브리지가 저장한 플랫폼의 Visual 불일치 | Visual 갱신이 "충돌체 크기가 다를 때" 분기 안에 있었다 | 충돌체·Visual·one-way 독립 검사 | 해결 |
| 원격 플레이어의 가짜 착지 | 첫 snapshot 전 기본 AIR를 낙하로 봤다 (`1e0adab`에서 수정) | 회귀 테스트 보강만 | 해결(기존 수정 유지) |
| 릴리스 lifecycle의 "run animation missing" | **미확정.** 클라이언트가 자기 actor의 transform snapshot을 이동 구간 내내 적용하지 못했다 | 진단 추가만 | **미해결** |
| 릴리스 lifecycle의 `input_authority` (dodge 뒤 `ready_action`) | **미확정** | 진단 추가만 | **미해결** |
| 종료 시 `0xC0000005` | Godot 엔진 종료 use-after-free | 대상 아님. 분류·기록 체계만 | Known issue |

### 1.1 점프 유실

추적(임시 로그, 커밋하지 않음)으로 확인한 사실:

- 실패한 실행에서 클라이언트는 점프가 실린 이동 명령을 **보냈다**(`send jump seq=124`).
- 호스트의 RPC 핸들러 `_request_player_move_input`은 그 sequence로 **호출되지 않았다.**
- 점프가 도착한 실행에서는 호스트가 바닥 위에서 수락했고 actor는 6 tick 동안 34 px 올라갔다. 즉 서버의 점프
  처리·접지 판정·snapshot은 정상이고, probe의 관측 조건(`y < start − 10`)도 정상이다.

따라서 게임 입력 유실이며 테스트 관측 실패가 아니다. 이동 명령은 매 프레임 `unreliable_ordered`로 나가고 점프는
한 번의 키 입력이라, packet 하나가 사라지면 입력이 사라진다. ENet packet throttle은 계측 결과 32(drop 없음)에
머물렀으므로 throttle이 원인이라는 근거는 없다 — 유실이 전송 계층의 어디서 나는지는 확정하지 못했고, 수정은
"packet 하나의 유실을 견딘다"는 계약에 맞췄다.

수정은 [multiplayer.md](multiplayer.md)의 "Jump delivery"에 있다. wire 형식과 프로토콜 버전은 그대로다.
같은 유실이 릴리스 lifecycle의 `input_authority`(jump 횟수 비교) 실패 중 하나의 원인이었다.

**프로토콜을 바꾸지 않은 이유.** 전달 보장에는 dodge처럼 별도 reliable 명령이 필요하고, 그것은 새 RPC이므로
v21이다. 영향 범위는 handshake(구버전 peer 거절), release EXE와 editor의 혼합 실행, `NetworkProtocol.VERSION`을
고정값으로 확인하는 테스트 5곳·`build_windows_demo.py` manifest·Monster Editor 계약(`EXPECTED_NETWORK_PROTOCOL`)
이다. 이번 문제는 기존 payload 안에서 해결되므로 올리지 않았다. 남는 한계(0.15초 동안의 연속 유실)는
multiplayer.md에 적었다.

### 1.2 Role D host timeout

CI 실패 로그([run 45662356879](https://github.com/wolfy03/ReturnToCage/actions/runs/45662356879))의 D `engine.log`:

```text
SESSION STEP 36 check_menu ...
SESSION FAILURE STATE ...
ERROR: PLAYER ROSTER PROBE FAIL D: command timeout
```

`SESSION STEP 37 host`는 없다. D는 host 명령을 **받기 전에** 스스로 실패했고, 컨트롤러는 host 명령을 보낸 직후
그 실패 결과를 읽었다(실패 보고의 `sequence`가 36). 제품의 host 시작·세션 정리·ENet·포트와는 무관하다.

원인은 probe의 watchdog이다. idle 제한(300초)은 `_process`가 `_busy == true`를 본 프레임에서만 갱신됐는데, D의
명령(`check_menu`, `inspect`)은 수락한 프레임 안에서 끝나 busy로 관측되지 않는다. 그래서 D의 idle 제한은 시작
시각 + 300초에 고정됐고, rendered release lifecycle처럼 5분을 넘는 실행에서 D가 대기 중에 끝났다. 로컬 실행은
더 짧아서 재현되지 않았다. (이 idle 제한은 `3cc7416`에서 60초 단일 제한을 나누면서 들어간 결함이다.)

수정: 제한을 `core/validation/command_watchdog.gd`로 옮기고 명령을 수락할 때 두 제한을 모두 다시 시작한다.
실패 메시지는 어느 제한이 지났는지와 마지막 sequence를 말한다. `tests/unit/test_command_watchdog.gd`가
"한 프레임 안에 끝나는 명령만 받는 역할"을 재현한다.

제품 쪽 세션 lifecycle은 고치지 않았다 — 고칠 결함을 찾지 못했다(§3).

### 1.3 Scene Bridge 플랫폼 동기화

[python_map_editor_bridge.md](python_map_editor_bridge.md)의 "Scene에 직접 저장된 FieldPlatform의 자식" 참조.
외곽선 계산은 `FieldPlatform.rectangle_polygon()` 하나로 모았다(런타임과 브리지가 같은 식을 따로 갖고 있었다).

### 1.4 미해결: "run animation missing" (릴리스 2/10, 소스 rendered 1/22)

`B move` 뒤 **B가 자기 actor를 볼 때** 실패한다(같은 순간 호스트 A는 B의 달리기를 본다). 추가한 관찰 기록:

```text
observed=["fall/AIR/facing=1", "idle/GROUND/facing=1"]  motion=true run=false
```

watch를 시작할 때 B의 자기 actor는 snapshot을 한 번도 적용하지 않은 기본 자세(AIR)였고, 이동이 끝난 뒤에야
위치가 한 번에 바뀌었다. 20 Hz snapshot이 0.6~1.1초 동안 하나도 적용되지 않은 것이다. 가설(오래된 sequence로
거절, world revision 불일치, 렌더 프레임 정지)은 코드 검토로 뒷받침하지 못했고 14회 추가 반복에서 재현되지 않았다.
다음 발생 때 원인이 드러나도록 실패 메시지에 관찰 기록과 snapshot 카운터(`applied`/`stale`/`has`)를 넣었다.
플레이어에게는 "월드에 들어온 직후 잠깐 자기 캐릭터가 멈춰 보인다"로 나타날 수 있다.

### 1.5 미해결: `input_authority` (릴리스 1/10)

dodge 실행 뒤 `ready_action`(action IDLE + 접지)을 10초 안에 만족하지 못했다. 보고된 값(dodge 1회 실행, 속도 0,
축 0)은 전부 조건을 만족해 어느 부분이 빠졌는지 알 수 없었다. 표본에 `action_idle`/`on_floor`/`movement_mode`를
추가했다.

## 2. 반복 검증

같은 장비, 순차 실행, 실행마다 새 프로세스. "기능"은 성공 marker가 있고 기능 실패 표시가 없다는 뜻이다.

| 검사 | commit | 실행 | 기능 PASS | 기능 FAIL | Timeout | Known engine crash | Unknown native crash | 완전 PASS |
|---|---|---|---|---|---|---|---|---|
| 3인 local probe, 수정 전 | `3cc7416` | 12 | 8 | 0 | 4 (JUMPING 3, CLEANUP 1) | 미분류 | 미분류 | 8 |
| 3인 local probe, 수정 전 | `6e35d51` 계열 | 13 | 9 | 0 | 4 (JUMPING 3, WAITING 1) | 미분류 | 미분류 | 9 |
| 3인 local probe, 수정 후 | `6e35d51` + 점프 수정(미커밋) | 30 | 30 | 0 | 0 | 4 | 0 | 26 |
| Headless lifecycle | `495fafb` | 10 | 10 | 0 | 0 | 0 | 0 | 10 |
| Windows release lifecycle (`--rendered`) | `495fafb` | 10 | 6 | 3 | 0 | 0 | 1 | 6 |
| Rendered lifecycle (소스) | `495fafb` + 진단 | 22 | 21 | 1 | 0 | 0 | 0 | 21 |

- 점프 관련 기능 실패·관측 timeout은 수정 후 30회 중 0이다. 30회 통과가 간헐 문제의 완전한 제거를 증명하지는 않는다.
- 수정 전 표의 timeout에는 종료 crash가 섞여 있을 수 있다(그때는 두 답을 나눠 기록하지 않았다).
- 릴리스 10회의 기능 FAIL 3건은 §1.4가 2건, §1.5가 1건이다. Unknown 1건은 export 전 `--editor --quit` import
  프로세스의 `0xC0000005`(성공 marker 이전)다. Role D timeout은 0건이다.
- 첫 lifecycle·release 반복은 도구 결함(산출물 폴더 재사용, marker 지정 오류)과 실행 중 문서 수정으로 인한
  "source dirty" 때문에 전부 무효였다. 그 결과는 통과·실패 어느 쪽으로도 세지 않았고 도구를 고친 뒤 다시 돌렸다.

로그와 `results.json`: `build/validation/runtime-stabilization/{jump-after-fix,lifecycle,release}/`(로컬).

## 3. 세션 lifecycle 계약

`NetworkManager`의 상태는 `OFFLINE → HOSTING` / `OFFLINE → CONNECTING → CONNECTED` /
`OFFLINE → HOSTING_RESTORING → HOSTING`이고, 모든 종료는 `OFFLINE`으로 돌아온다.

| 동작 | 경로 | 보장 |
|---|---|---|
| Host 시작 | `host_game()` → `_reset_transport()` → `_open_host_transport()` → `_finalize_host_session()` | 이전 transport를 먼저 닫는다. 실패하면 다시 reset하고 오류를 반환한다 |
| Client 연결 | `join_game()` → `_reset_transport()` → `create_client` → `CONNECTING` | handshake·session snapshot·spawn/world 배정을 받기 전에는 `_session_entered`가 false다 |
| 연결 해제 | `leave_game()` / `_on_server_disconnected()` / `_on_connection_failed()` → `_finish_network_session(reason)` | 세션에 들어온 적이 있을 때만 `multiplayer_session_ended`를 한 번 낸다 |
| 세션 정리 | `_reset_transport_only()` | peer close, `OfflineMultiplayerPeer` 교체, `_local_peer_id = 1`, 수신 플래그·pending 초기화 |
| 상태 정리 | `GameSession.reset_to_offline_local_player()` | 참가자 registry·runtime(sequence 포함)·알림·원정을 버리고 로컬 `PlayerState`·Save·Profile은 유지 |
| 재시작 / Client→Host | 위 정리 뒤 `host_game()` | 같은 프로세스에서 가능. lifecycle E2E의 D가 join → 서버 종료 → menu → host를 실제로 수행한다 |
| 이전 callback 무효화 | `_transport_generation` | transport를 닫을 때마다 증가. 지연 callback은 캡처한 generation이 다르면 버린다 |
| 오류 | `last_error` + `Error` 반환 | 잘못된 port·player 수·미활성 identity는 transport를 건드리기 전에 거절한다 |

`leave_game()`은 `OFFLINE`에서 호출해도 안전하다(이미 닫힌 transport를 다시 reset할 뿐 `multiplayer_session_ended`를 내지 않는다).
`begin_host_restore()`만 `OFFLINE`이 아니면 `ERR_ALREADY_IN_USE`로 거절한다. Role D 실패를 조사하면서 이 경로에서
이전 세션 상태가 새 세션으로 넘어가는 사례는 찾지 못했고, headless lifecycle 10/10이 이를 뒷받침한다.

## 4. CI

`e043314`(중간 커밋): Python Map Editor 성공, Python Monster Editor 성공, Godot validation — `headless` 성공,
`windows-demo` 실패([run 45730419503](https://github.com/wolfy03/ReturnToCage/actions/runs/45730419503)).
`windows-demo`의 실패 지점은 release 빌드 전 단계인 "Disconnect menu input and session recovery E2E"이고,
`DISCONNECT RECOVERY PROBE PASS` 뒤 `process exit=3221225477`이다 — Functional PASS / Process
KNOWN_ENGINE_CRASH. 이 job은 여러 프로세스를 띄우는 단계를 연속으로 실행하므로 엔진 종료 crash가 있는 한
안정적으로 녹색이 될 수 없다. job의 실패 판정은 바꾸지 않았다.

### 통합 후보 `88251c5` 전체 검증 (로컬, 한 SHA)

36개 단계 중 35개 PASS, 1개 `Functional PASS / Process KNOWN_ENGINE_CRASH`.

| 묶음 | 결과 |
|---|---|
| `check_project.py` (7,020 assertions), release-boundary unittest | PASS |
| ENet E2E 20종 (local 2·3·host-disconnect, restart 3, worlds 2, world_runtime 2, forest 2, authority 2, protocol, disconnect, roster 2) | PASS |
| `test_session_recovery.py` (headless lifecycle) | 전 역할 `PROBE PASS` 뒤 A가 `0xC0000005`로 종료 — Known engine crash. 같은 검사의 10회 반복은 10/10 |
| Forest playtest | PASS_WITH_WARNINGS (스폰 캡슐 겹침, [known_issues.md](known_issues.md)) |
| Forest rendered probe | PASS |
| Map Editor pytest (184 passed, 3 skipped), V6 집중 테스트, Qt smoke | PASS |
| Scene / V4 / Forest V6 / Terrain 브리지, V6 Enemy 스폰 데이터 안전 + 10회 왕복 | PASS |
| Monster Editor pytest (569 passed, 3 skipped), Godot 계약 (205 checks, 3 not evaluated) | PASS |
| Map Editor OneDir EXE 빌드, 패키징 EXE 검증 | PASS |
| Windows release 빌드 + EXE 검증 (`--rendered`, 1회) | PASS |

이 문서 표를 추가한 커밋은 문서만 바꾼다. 위 결과는 `88251c5`의 것이며 그 뒤 코드·리소스 변경은 없다.
최종 커밋의 CI 결과는 이 브랜치의 보고에 적는다.

## 5. 다른 작업에 주는 영향

- **NetworkProtocol·Save:** 변경 없음(20 / v5).
- **Monster Editor:** `texture_filter` 호환성 메모만 추가했다([monster_editor_compatibility.md](monster_editor_compatibility.md)).
  예제·schema·코드는 건드리지 않았다. `network_player_component.gd`와 `field_platform.gd`는 예제의
  `source_binding` 대상이 아니다.
- **Map Editor:** `tools/map_bridge/scene_contract.gd`가 바뀌었으므로 EXE를 다시 빌드해야 배포본에 반영된다.
  브리지는 이제 프로젝트의 `FieldPlatform.rectangle_polygon()`을 호출하므로, 이 커밋 이전의 프로젝트 사본에는
  새 EXE를 쓸 수 없다.
- **사용자 제작 아트·지형:** 변경 없음. 스폰 위치·지형 데이터를 옮기지 않았다.

## 6. `windows-demo` 실패의 재분류 (2026-11-28, `feature/runtime-stability-input-snapshot`)

master `98fd8b3` 기준. 게임 런타임과 프로토콜은 바꾸지 않았다 — 고칠 런타임 결함을 확인하지 못했다. 바뀐 것은 검증
도구(`core/validation/session_recovery_probe.gd`, `tools/test_session_recovery.py`)와 단위 테스트뿐이다.

### 6.1 `input_authority` — 버프가 멈춘 것이 아니라 끝난 것

마지막 `A input_authority PASS` 뒤에 실패한 것은 probe가 아니라 제어기의 비교였다(`verify_input_isolation(third=True)`).
실패한 실행의 `steps.json`에서 두 표본(B의 권위 actor, B의 UI가 입력을 막고 있는 동안):

| | sequence | snapshot | hunger | thirst | quick_paws 남은 시간 |
|---|---|---|---|---|---|
| 이전 (104번째 단계) | 1329 | 1658 | 91.319 | 84.998 | 20.57 |
| 이후 (129번째 단계) | 1538 | 2186 | 88.152 | 80.246 | −1 (효과 없음) |

snapshot·허기·갈증은 전부 진행했다. 허기가 준 양(3.168)을 같은 실행의 다른 구간에서 잰 속도(0.12/s)로 나누면 두 표본
사이는 약 26.4초이고, 버프는 20.57초 남아 있었다. 즉 **버프는 약 6초 전에 정상 만료**됐다. 조건식
`0 < 이후 < 이전`은 "만료"를 "정지"로 읽었다. 로컬에서는 같은 구간이 2.7초라 드러나지 않는다.

수정(`ce0ea5f`):

- `blocked_tick_problem(before, after)`가 snapshot, 생존 수치, 버프를 따로 판정한다. 버프가 없어진 경우는 Host의
  **게임 시간**(physics tick 수 ÷ tick rate)으로 잰 경과가 남은 시간보다 길 때만 통과한다(정상 만료). 일찍 사라지거나,
  줄지 않거나, 다른 속도로 줄면 실패다(허용 오차 0.5초) — 이전보다 엄격하다. 생존 수치가 이미 최소값이면 "멈춤"이
  아니라 "이 구간으로는 알 수 없음"으로 보고한다.
- **시계는 벽시계가 아니다.** 처음에는 Host의 벽시계(`ticks_msec`)와 비교했고, 그 판정이 `536d950`의 CI에서 실패했다
  ([run 46112525461](https://github.com/wolfy03/ReturnToCage/actions/runs/46112525461)): "버프가 22.19초 동안 16.70초
  줄었다". 같은 표본의 physics tick은 1002개(60Hz에서 16.70초)였다 — 버프는 게임 시간과 **정확히** 같이 갔다. 엔진은
  긴 프레임 하나가 진행시킬 수 있는 시간을 제한하므로(`max_physics_steps_per_frame`), 굶는 장비에서는 게임 시간이
  벽시계보다 느리다(이 실행에서 75%). 버프·생존·물리가 모두 같은 시간으로 가므로 게임 안에서는 일관된다. 이것은
  판정의 오류였고, 동시에 그 runner가 얼마나 느린지를 처음으로 잰 수치다: 0.6초짜리 이동이나 1초 안의 관측을 벽시계로
  기다리는 검사는 이 장비에서 게임 시간 기준으로 그만큼 짧아진다.
- 버프 fixture를 비교할 표본 바로 앞에서 건다(`input_effect`). 그 사이 단계가 얼마나 걸리는지에 기대지 않는다.
- 표본에 peer, player id, actor instance id, world id·revision, physics tick, Host 시계, 차단 상태
  (`host_ui_blocked`, `controls_locked`), 효과의 존재·지속 시간, 생존 수치의 최소값 여부를 더했다. 두 표본이 같은
  actor·같은 world의 것이 아니면 비교하지 않는다. 결과는 `tick_checks.json`에 남는다.
- `tools/tests/test_lifecycle_tick_check.py`: 위 두 CI 표본(옛 조건의 실패, 벽시계와 게임 시간의 차이)을 그대로
  쓰고(13개 경우), 정지·조기 소멸·속도 이상·physics 정지는 여전히 실패임을 확인한다.

### 6.2 제어된 재현 (`--inject`)

| 주입 | 무엇을 흉내 내는가 | 결과 |
|---|---|---|
| `buff-delay=62` | 차단 구간이 버프(60초)보다 길다 | 경과 64.6초, 버프 59.79 → 없음, 판정 통과. 359단계 전부 PASS (그 실행은 끝에서 D가 `PROBE PASS` 뒤 `0xC0000005` — 엔진 종료 crash) |
| `stall-observer=1500` (rendered) | 관찰 프로세스가 1.5초 동안 프레임을 못 돈다 | `d30baab`와 같은 실패: `observed=["idle/GROUND/facing=1", "idle/GROUND/facing=-1"]`, `motion=true run=false`, `max_frame_gap_msec=1515` |
| `hold-result=4` | 결과 파일이 4초 동안 열려 있다 | `publication failed after 290 attempts in 3000 ms` — `43ea113`과 같은 메시지 |

둘째와 셋째는 "그런 일이 있으면 그 모양이 된다"를 보일 뿐, CI에서 실제로 그랬다는 증거가 아니다. 그래서 판정은
바꾸지 않았다: 달리기 관측 조건도, 게시 제한 3초도 그대로다. 달라진 것은 기록(관찰자의 프레임 수와 최대 간격, 게시
시도 횟수)과, 게시 재시도가 프레임 수가 아니라 시계에 맞춰진다는 점이다(한 프레임이 몇 초인 장면 전환 중에도 3초를
다 쓴다).

### 6.3 `slot_ui`

12개 조건이 한 메시지였으므로 단계마다 이름을 붙였다. 로컬 rendered 27회 중 2회 재발했고 둘 다 같은 자리다:

```text
stage=bag window open (visible=true) and its consumable tab clickable
click=before: dragging=false hovered=.../GameHUD/.../@HBoxContainer@21 ... disabled=false visible=true
      after:  dragging=false hovered=.../InventoryWindow/Content/Tabs/@Button@67 ... received=false
```

probe가 만든 mouse motion·press·release가 탭 버튼의 `pressed`가 되지 않았다. 슬롯 요청을 보내기 **전**이므로 owner
snapshot과 result의 순서, 복제와는 무관하다(Host는 같은 reliable 채널로 snapshot을 result보다 먼저 보낸다 —
`PlayerItemReplicationService._execute_slot`). 합성 입력 쪽 문제로 분류하되 기전은 확인하지 못했고, 재시도로 덮지 않았다.
`0513b42`의 실패가 같은 것이었는지는 그 실행의 기록으로는 알 수 없다.

### 6.4 UI 입력 차단 범위 — 기존 lifecycle이 보는 것

`verify_input_isolation`(2인·3인 각각)이 실제 키 입력으로 본다. 새 검사를 더하지는 않았다.

| 항목 | 어디서 |
|---|---|
| 차단: 이동 | Host: 장비창을 연 채 왼쪽 키 → 권위 축 0·정지. Client: 가방을 열면 누르고 있던 오른쪽 키가 0이 됨 |
| 차단: 점프·공격·회피 | `input_blocked_edges` + 권위 쪽 jump/attack/dodge 횟수 불변 |
| 키를 누른 채 UI를 열고 닫기 | 누른 채 열기(위), ESC로 닫은 뒤 입력 재개, 세션을 나갔다 들어온 뒤 누르고 있던 키(`held_right`) |
| 유지: 다른 플레이어 조작 | A가 막힌 동안 B·D 이동 |
| 유지: 권위 물리, snapshot | 막힌 플레이어의 snapshot sequence 증가 |
| 유지: 생존 수치, 버프 시간 | `blocked_tick_problem` (§6.1) |
| 유지: Enemy AI | `input_world_tick`: Host UI가 막힌 동안 Sewer 적의 이동과 복제 |
| 유지: 네트워크 메시지 | 막힌 owner의 장착(`item_ui`), 창고 왕복(`input_storage`) |

Host UI와 Client UI는 따로 본다(A의 장비창·ESC, B의 가방·장비창·ESC). 보지 않는 것: 메뉴(ESC) 상태에서의 버프 시간,
막힌 Client에서의 Enemy AI.

### 6.5 Snapshot·Slot UI 경계 — 이번에 한 것과 하지 않은 것

메시지 순서를 제어하는 새 테스트는 만들지 않았다. 지연 주입(§6.2)이 전부다. 오래된 snapshot의 거절
(`snapshots_stale`), world revision 불일치, sequence 초기화는 기존 unit test와 lifecycle의 `slot_rpc reject=...` /
`slot_check`(중도 참가·지역 이동·재접속 뒤)가 본다. 이번 분석에서 그 경로의 결함은 찾지 못했다.

### 6.6 반복 검증

Windows 11, Godot 4.7.2-stable, 같은 PC, 순차 실행, 실행마다 새 프로세스. 성공할 때까지 돌린 것이 아니라 정한 횟수를
전부 적는다.

| 검사 | commit | 실행 | 완전 PASS | 기능 FAIL | Known engine crash | Unknown native crash |
|---|---|---|---|---|---|---|
| Headless lifecycle (`repeat_stability --case lifecycle`) | `ce0ea5f` | 10 | 10 | 0 | 0 | 0 |
| Rendered lifecycle (소스) | `ce0ea5f` | 10 | 9 | 1 (`slot_ui`, §6.3) | 0 | 0 |
| Rendered lifecycle (소스) | `508f529` | 15 | 14 | 0 | 1 (전 역할 `PROBE PASS` 뒤 B 종료) | 0 |
| Rendered lifecycle (소스), 진단 추가 뒤 확인 | 작업 트리 | 1 | 0 | 1 (`slot_ui`, §6.3) | 0 | 0 |
| Headless lifecycle, 진단 추가 뒤 확인 | 작업 트리 | 1 | 1 | 0 | 0 | 0 |
| ENet world runtime 2인 / 3인 | `ce0ea5f` | 3 / 3 | 3 / 3 | 0 | 0 | 0 |
| Local multiplayer probe 2인 / 3인 | `ce0ea5f` | 3 / 3 | 3 / 3 | 0 | 0 | 0 |
| Disconnect recovery | `ce0ea5f` | 3 | 3 | 0 | 0 | 0 |
| Windows release 빌드 + EXE 검증 (`--rendered`) | `508f529` | 3 | 1 | 1 (D의 입력, 아래) | 0 | 1 (`editor-exe-client`) |

- 수정한 판정(버프)에 의한 실패는 수정 뒤 39회의 lifecycle 실행에서 0이다. 수정 전의 실패는 로컬에서 자연 발생하지
  않으므로(구간이 2.7초) CI의 실제 표본과 `buff-delay` 주입으로 재현했다.
- 릴리스 3회 중 기능 실패 1건은 새 증상이다: D가 오른쪽 키를 눌렀는데 Host의 D actor가 10초 동안 움직이지 않았다
  (`axes=(0,0)`, 명령은 도착). **원인 미확정**이고 실제 기능 실패일 수 있다 — [known_issues.md](known_issues.md).
- 릴리스 EXE 반복은 3회뿐이다. 10회를 채우지 않았다.

로그: 로컬 scratch 폴더(커밋하지 않음). CI 결과는 이 브랜치의 보고에 적는다.
