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
