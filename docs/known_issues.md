# Known Issues

현재 해결되지 않았고, 왜 그대로 두는지와 어떻게 다루는지를 적는 문서다. 문제를 숨기는 목록이 아니다 —
여기에 적혔다는 이유로 실패가 통과가 되지는 않는다. 검증 결과를 읽는 방법은
[testing.md](testing.md)의 "결과 상태"를, 2026-11 통합 안정화의 경위는
[runtime_stabilization.md](runtime_stabilization.md)를 본다.

## 결과 상태

모든 검증 실행은 서로 독립인 두 답을 갖는다.

| 답 | 값 | 뜻 |
|---|---|---|
| Functional Result | `PASS` / `FAIL` / `TIMEOUT` | 검사 자체가 통과했는가 |
| Process Exit Result | `PASS` / `FAIL` / `TIMEOUT` / `KNOWN_ENGINE_CRASH` / `UNKNOWN_NATIVE_CRASH` | 프로세스가 정상 종료했는가 |

- 실행 하나가 **PASS**인 것은 두 답이 모두 `PASS`일 때뿐이다. 성공 marker를 출력한 뒤 비정상 종료한 실행은
  `Functional PASS / Process KNOWN_ENGINE_CRASH`이지 PASS가 아니다.
- `PASS_WITH_WARNINGS`는 검사는 통과했지만 별도 경고가 있는 판정이다(아래 "Spawn 캡슐 겹침").
- `NOT_EVALUATED`는 실제로 실행하지 않은 검사다. 통과로 세지 않는다.
- `tools/repeat_stability.py`가 이 분류를 실행마다 `results.json`에 기록한다(`functional_result`,
  `process_result`, `exit_code`, `commit`). 종료 코드 판정(`pass`)은 그대로이며 crash를 통과로 바꾸지 않는다.

## Godot native crash (`0xC0000005`)

| 항목 | 내용 |
|---|---|
| 오류 | `0xC0000005` / `3221225477` / `STATUS_ACCESS_VIOLATION` |
| 원인 | Godot 엔진 종료 과정의 use-after-free. GDScript 인스턴스·리소스 해제 순서의 엔진 내부 문제 |
| 영향 버전 | 공식 Godot 4.7.2-stable (Windows). Linux CI에서는 재현되지 않았다 |
| 나타나는 곳 | 성공 marker를 출력한 **뒤** 프로세스가 끝나는 순간. headless·rendered·export EXE·bridge editor 모두 |
| 근거 | full dump와 스택: [step7_stability_round2.md](step7_stability_round2.md), [step7_stability.md](step7_stability.md), bridge 프로세스: [python_map_editor_native_stability.md](python_map_editor_native_stability.md), release: [windows_demo.md](windows_demo.md) |
| 기능 영향 | 없음(검사는 끝난 뒤다). 프로세스 종료 코드만 실패가 된다 |

**왜 고치지 않는가.** 엔진 내부 문제이고 프로젝트 코드로 근본 수정할 수 없다. 엔진 소스를 고치거나, 종료
코드를 무시하거나, 이 crash 하나를 피하려고 게임 구조를 바꾸지 않는다. Godot 버전을 올리는 별도 작업에서
해결한다.

**분류 기준.** `KNOWN_ENGINE_CRASH`는 다음을 모두 만족할 때만 쓴다.

1. 종료 코드가 `0xC0000005`다.
2. 그 실행의 성공 marker가 이미 출력됐다.
3. 기능 실패 표시(`ERROR:`, `PROBE FAIL`, timeout, assertion, leak)가 로그에 없다.

하나라도 아니면 `UNKNOWN_NATIVE_CRASH`다. 같은 종료 코드라는 이유만으로 기존 버그로 분류하지 않는다. 특히
**작업 도중**(import, 게시, probe 실행 중)에 난 access violation은 성공 marker가 없으므로 항상 unknown이다.

**운영 정책.**

- 제한적으로 재실행할 수 있다. 최초 실패 로그·재실행 횟수·crash 횟수·최종 결과·commit·Godot 버전을 모두
  남긴다. 재실행이 통과했다고 앞의 crash 기록을 지우지 않는다.
- CI job은 이 crash로 끝나면 그대로 실패다. 자동으로 성공 처리하지 않는다. 필수 gate에서 예외로 승인할지는
  사람이 실행별로 판단하며, 그 예외는 이 분류에만 적용된다.
- 외부 프로세스가 죽어도 데이터는 안전해야 한다. Map Editor는 Godot을 격리된 staging 프로젝트에서만
  실행하고, 종료 코드 0과 구조화된 PASS 결과가 모두 있어야 게시한다. 게시는 저널이 있는 두 파일
  트랜잭션이다. crash로 끝난 실행은 게시를 차단하고 원본 Scene·RegionDefinition은 바뀌지 않는다
  ([python_map_editor_bridge.md](python_map_editor_bridge.md)).
- 엔진 버전별 예외는 검증·프로세스 관리 계층(`tools/repeat_stability.py`, CI)에만 둔다. 게임 런타임에
  이 crash를 위한 조건문을 넣지 않는다.
- Monster Editor Bridge는 crash로 끝난 호출의 결과를 버리고 다시 실행한다. 위 분류 기준의 2·3번(성공 marker,
  실패 표시 없음)을 로그로 확인해 `exit_after_success`면 전체 3회까지, 아니면(`during_work`) 한 번만 더 한다. 대상은 읽기 명령과,
  버려도 되는 staging 사본 안의 자기 출력만 다시 쓰는 `stage_monster`뿐이다. 응답에 시도 횟수, 버린 시도의 종료
  코드, 첫 crash의 로그가 남고(`BridgeResponse.crashes` / `.crash_log` / `.process_result`) 재시도가 통과해도
  지워지지 않는다. Bridge는 종료 코드만 보고 "알려진 엔진 crash"라고 분류하지 않는다 — 위 분류 기준의 판단은 로그를
  보는 사람의 몫이다([monster_editor_bridge.md](monster_editor_bridge.md)).

**엔진을 올린 뒤 재검증.**

```sh
python tools/repeat_stability.py --godot <new godot> --repeat 30 --case physics --case player --case project --case local3 --case lifecycle --output <dir>
```

`known_engine_crash=0`이 30회 이어지면 이 항목과 CI의 예외 판단을 지운다.

## Windows 릴리스 probe (`windows-demo`)의 간헐 실패

`Godot validation / windows-demo`가 실행마다 다른 자리에서 실패한다. 2026-11-28에 실패한 실행의 산출물(`steps.json`,
`failure.json`, 역할별 `engine.log`)을 하나씩 읽어 다시 분류했다. 근거와 재현은
[runtime_stabilization.md](runtime_stabilization.md) §6에 있다. 서로 같은 원인이라고 가정하지 않았다.

| 커밋 (run) | 실패한 자리 | 실제로 실패한 조건 | 분류 | 상태 |
|---|---|---|---|---|
| `98fd8b3` master ([46099981595](https://github.com/wolfy03/ReturnToCage/actions/runs/46099981595/job/140841090742)), `07bf5f0` ([46108080023](https://github.com/wolfy03/ReturnToCage/actions/runs/46108080023)) | Role A `input_authority` (`axis=0`, `after=1329`), 종료 코드 1, `B's blocked UI stopped authority, survival, or buff ticks` | probe가 아니라 **제어기**의 비교(`0 < 버프 남은 시간 < 이전 값`). 버프가 20.6초 남았을 때 첫 표본을 뜨고 약 26초 뒤 둘째 표본을 떴다 — 버프는 정상 만료됐고 허기·갈증·snapshot은 모두 진행했다 | 테스트 판정 오류 (느린 runner에서 드러남) | **수정** (`ce0ea5f`) |
| `43ea113` | Role D `check_menu` | 게임은 정상적으로 메뉴에 있었다. probe가 결과 파일을 3초 동안 게시하지 못했다(`PLAYER ROSTER RESULT publication failed`). 이전 기록의 "`assert_motion`"은 틀렸다 | 테스트 fixture (파일 게시). 무엇이 파일을 잡고 있었는지는 미확인 | 재시도를 프레임이 아니라 시계에 맞춤, 시도 횟수 기록 |
| `d30baab` | Role B `assert_motion` (B가 Host A를 관찰) | 관찰 기록이 `idle/facing=1 → idle/facing=-1`뿐이고 위치는 한 번에 바뀌었다 | CI 타이밍 **의심**: 관찰 프로세스가 프레임을 돌리지 못한 경우와 같은 모양(제어된 재현으로 확인). 그 실행에서 실제로 그랬다는 기록은 없다 | 미확정. 다음 발생 때 프레임 간격이 기록된다 |
| `0513b42` | Role B `slot_ui` | 그 실행의 기록으로는 알 수 없다(12개 조건이 한 메시지였다) | 미확정 | 조건마다 이름을 붙임. 로컬 rendered에서 2/27 재발: 요청을 보내기 **전**, probe의 합성 클릭이 가방 탭 버튼에 전달되지 않았다 — 테스트 fixture (합성 입력), 기전 미확인 |
| `1b19bb1` | Disconnect menu input and session recovery E2E | `DISCONNECT RECOVERY PROBE PASS D` 뒤 `process exit=3221225477`. 이 단계는 릴리스 EXE가 아니라 에디터 바이너리로 돈다 | 알려진 엔진 종료 crash 유형 (Functional PASS / Process KNOWN_ENGINE_CRASH) | 대상 아님 |

`last_reports`의 상태 덤프는 각 역할이 **마지막으로 답한 때**의 상태다. 실패 순간의 상태가 아니다.

**새로 드러난, 해결하지 못한 항목** (로컬 릴리스 EXE 3회 중):

| 증상 | 기록 | 분류 |
|---|---|---|
| Role A `input_authority` (`axis=1`, D를 관찰): D가 오른쪽 키를 누른 뒤 10초 동안 Host의 D actor가 5px 이상 움직이지 않았다 | Host 표본: `axes=(0,0)`, `x=180.36`(시작 180.0), `sequence=660`(명령은 계속 도착), `controls_locked=false`, `world_revision=1` | **미확정 — 실제 기능 실패일 수 있다.** D의 클라이언트가 0축을 보낸 것(키 입력이 풀렸거나 로컬 차단)인지 Host가 버린 것인지 가를 기록이 없었다. 이후 결과에 각 프로세스의 `local_input`(차단 여부, 키 상태, 창 focus)을 넣었다 |
| `editor-exe-client exit=3221225477` (에디터·EXE 혼합 ENet 단계) | 성공 marker 이전 | Unknown native crash |

**순서.** MONSTER-STEP 4-A(Attack Pattern Editor / Timeline GUI)는 게임 런타임을 바꾸지 않으므로 이 문제와 독립이다.
MONSTER-STEP 4-B(실제 Combat Runtime, 프로토콜 변경)는 위의 "D의 입력이 Host에서 움직임이 되지 않음"이 실제 결함인지
가려질 때까지 시작하지 않는다.

## Unknown native crash

성공 marker 없이 난 `0xC0000005`. 2026-11 안정화 중 관찰된 것:

| 어디서 | 관찰 | 상태 |
|---|---|---|
| Map Editor bridge의 `prepare`(격리 import editor) | V6 10회 왕복 중 1회. 게시 전 단계라 원본은 그대로였고 재실행은 10/10 통과 | 미해결. 덤프를 확보하지 못해 기존 버그와 같은지 확인하지 못했다 |

새로 관찰하면 여기에 단계·빈도·commit·로그 위치를 적는다. 근거가 생기기 전에는 known으로 옮기지 않는다.

## Spawn 캡슐 겹침 경고 (`Player Body Clearance`)

`tools/playtest_region.py`와 bridge의 런타임 검사가 Forest·Sewer의 플레이어 스폰 4곳에서 내는 `WARN`이다.
이 경고 때문에 해당 판정이 `PASS_WITH_WARNINGS`가 된다.

| 항목 | 내용 |
|---|---|
| 검사 | 스폰 marker 위치에 플레이어 캡슐(반지름 14, 높이 34)을 **그대로** 놓고 지형과 겹치는지 본다 |
| 값 | 스폰 y = 520, 바닥 윗면 y = 535, 캡슐 아랫면 y = 537 → 바닥과 **2 px** 겹친다 |
| 실제 동작 | 스폰 직후 물리가 2 px 밀어 올려 y ≈ 517.96에 선다. 갇힘·낙하·반복 충돌·즉시 피해 없음 |
| 근거 | 같은 검사의 `ENTRY Physical Anchor`, `Player Spawn Slot n`, 실제 스폰 배정 항목은 PASS. Forest·Sewer ENet E2E에서 스폰 직후 이동·점프가 통과한다 |

이 겹침은 Sewer부터 써 온 "marker를 발 근처에 둔다"는 배치 관례이며 의도된 값이다. 경고를 없애려고
사용자가 만든 지형이나 스폰 위치를 옮기지 않는다. 검사는 그대로 두어, 2 px보다 큰 겹침이나 다른 지형과의
겹침이 생기면 같은 항목에서 드러나게 한다.

## 3인 probe의 간헐 실패 중 남은 것

점프 단계 timeout은 원인을 고쳤다([runtime_stabilization.md](runtime_stabilization.md)). 남은 실패는 위의
엔진 종료 crash뿐이며, 실행별 횟수는 그 문서의 반복 검증 표에 있다.
