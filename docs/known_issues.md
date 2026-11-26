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
- Monster Editor Bridge는 crash로 끝난 호출의 결과를 버리고 다시 실행한다(최대 3회). 대상은 읽기 명령과,
  버려도 되는 staging 사본 안의 자기 출력만 다시 쓰는 `stage_monster`뿐이다. 응답에 시도 횟수, 버린 시도의 종료
  코드, 첫 crash의 로그가 남고(`BridgeResponse.crashes` / `.crash_log` / `.process_result`) 재시도가 통과해도
  지워지지 않는다. Bridge는 종료 코드만 보고 "알려진 엔진 crash"라고 분류하지 않는다 — 위 분류 기준의 판단은 로그를
  보는 사람의 몫이다([monster_editor_bridge.md](monster_editor_bridge.md)).

**엔진을 올린 뒤 재검증.**

```sh
python tools/repeat_stability.py --godot <new godot> --repeat 30 --case physics --case player --case project --case local3 --case lifecycle --output <dir>
```

`known_engine_crash=0`이 30회 이어지면 이 항목과 CI의 예외 판단을 지운다.

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
