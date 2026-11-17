# STEP 7 구현 및 검증 기록

검증일: 2026-11-17. 기준: `efbfe43aa0e47aca0360dce19ed18a57d57d55d6`, Godot 4.7.2.
사용 방법, 이동 수치, 분석 한계는 [Traversal 가이드](traversal_analysis.md)에 기록했다.

## 구현 범위

표면·점프·낙하 후보와 실제 입력 기반 물리 검증을 분리했다. WALK/JUMP/DROP/
CLIMB_UP/CLIMB_DOWN은 방향 간선이며, ESCAPE의 Verified Reachable은 스폰 설정 후
목표까지 위치를 재설정하지 않은 연속 입력 재생을 요구한다. 검사하지 않은 연결은 성공으로
표시하지 않는다. 새 RPC, SaveData 변경, 이동·전투·스폰 정책 변경은 없다.

실제 검증 중 확인하고 보완한 경계:

- 바닥 스냅은 `is_on_floor()`가 true여도 slide collision이 없을 수 있다. 같은 실제
  물리 공간의 지지 ray로 보완한다.
- 같은 StaticBody의 다른 CollisionShape 착지를 목표 착지로 오인하지 않도록 shape 경로와
  높이를 함께 확인한다. 단일 body의 상부 선반/하부 바닥 회귀 테스트를 추가했다.
- 채집/탈출이 E 입력을 먼저 받는 경우를 기존 Area 생성·거리·우선순위 규칙으로 검사한다.
  선행 소비를 재현하지 않았으면 등반을 Not Evaluated로 남긴다.
- 겹친 등반 영역에서는 실제 MovementComponent가 사용한 영역 경로를 증거로 기록한다.
  다른 영역의 이동을 요청한 사다리의 성공으로 기록하지 않는다.
- 검증 프로필에 없는 동작 스크립트를 지운 뒤 남은 지형만 성공 처리하지 않는다.
  해당 프로필을 partial/Not Evaluated로 제한한다.
- live Scene과 직렬화 후 스냅샷의 상태 정규화를 구분해 fingerprint를 검증한다.
- 씬 전환 시 RegionDefinition이 null인 표시 경로의 typed Array 오류를 수정했다.
- 네이티브 팝업 GUI 입력에는 실제 Window ID가 필요했다. 버튼과 결과 행을 마우스 이벤트로 검사한다.
- 외부 프로세스 대기를 렌더 프레임 수로 제한하던 테스트 실행기의 조기 종료를 제거했다.
  기존 90초 wall-clock 제한, 성공 마커, 모든 assertion, 엔진 오류 거절은 유지했다.
- 누락 Resource 실패 주입은 인덱싱된 콘텐츠 파일을 잠시 이동하는 대신 `.godot`의
  존재하지 않는 경로를 가진 복사본으로 수행한다. Scene 저장 호출이 없고 원본 파일과
  Undo 이력이 보존되는 assertion을 유지·강화했다. 자동 저장이 복사본을 저장하더라도
  콘텐츠 검색 경로에 중복 ID가 생기지 않는다.

## 수정 파일

| 경로 | 책임/변경 |
| --- | --- |
| `addons/rtc_field_editor/traversal_analysis.gd` | 실제 프로필 읽기, 표면/후보/방향 그래프, fingerprint |
| `addons/rtc_field_editor/traversal_controller.gd` | 비동기 실행, 취소, 캐시, 변경 감지, 보고서 검증 |
| `addons/rtc_field_editor/plugin.gd` | 기존 플러그인 생명주기·Inspector·UndoRedo와 연결 |
| `addons/rtc_field_editor/level_design_dialog.gd` | Traversal 페이지, 행 선택, 제한/프로필 안내, 스크롤 |
| `addons/rtc_field_editor/field_visualization.gd` | 표면/실제 궤적/방향/후보/미검증 접근/슬롯별 탈출 표시 |
| `tests/editor/traversal_physics.gd`, `.tscn` | 격리된 실제 PlayerActor 입력 검증 |
| `tests/editor/traversal_tests.gd`, `.tscn` | 78개 경계·물리·보고서 assertion |
| `tests/editor/traversal_editor_checks.gd` | 실제 에디터 버튼/결과 행 입력, 취소, 무효화, 저장/재열기 |
| `tests/editor/traversal_unmodelled.gd` | 미지원 동작이 실행되거나 검증 성공으로 바뀌지 않는지 검사 |
| `tests/editor/field_editor_probe.gd` | STEP 7 dispatch, 누락 파일 실패 주입을 콘텐츠 인덱서와 격리 |
| `tools/analyze_traversal.py` | 안전한 요청 경로, 격리 사용자 데이터, watchdog, 종료 코드/종료 방식 기록 |
| `tools/test_field_editor.py` | 기존 전체 회귀에 새 검증 포함, child status/로그 보존 |
| `docs/traversal_analysis.md` | 사용 방법·실제 이동 모델·분석 범위 |
| `docs/field_editor.md`, `docs/testing.md`, `docs/codebase_map.md` | 기능 및 검증 진입점 연결 |

새 GDScript의 `.gd.uid`도 함께 관리한다. `autoload`, `core`, `gameplay`, `world`의 기존
런타임 파일과 멀티플레이 프로토콜은 변경하지 않았다.

## 측정 결과

이동한 Root `(70, 32)`에서도 하수구를 실제 입력으로 검사했다.

| 대상 | 표면 | 후보 간선 | 검증 간선 | 시간 |
| --- | ---: | ---: | ---: | ---: |
| 하수구 | 5 | 25 | 11 | 약 1.6~1.8초 |
| 혼합 테스트 맵 | 4 | 20 | 15 | 약 0.8~0.9초 |
| E를 가로막는 채집물 | 4 | 20 | 14 | 약 0.7초 |
| 동일 body의 다중 shape | 5 | 25 | 14 | 약 1.1초 |
| 미지원 제어 스크립트 | 4 | 20 | 0 | partial, 물리 입력 검증 생략 |

하수구의 검증 간선은 WALK 4, JUMP 3, DROP 3, CLIMB_UP 1이다.
CLIMB_DOWN을 임의로 성공 처리하지 않았다. 별도 밧줄 하강 fixture에서 검증했다.
Fresh 4슬롯과 ENTRY anchor의 4슬롯에서 2개 ESCAPE로 가는 16개 조합을
모두 연속 입력으로 통과했다. 원본 지역 배치 파일은 변경하지 않았다.

## 실제 실행한 검증

실행 파일은 Godot 4.7.2 Windows x86_64이다. 일반 명령은 가이드에 있으며,
아래 결과는 성공 마커와 프로세스 종료를 구분한다.

| 명령/검사 | 결과 |
| --- | --- |
| `python tools/check_project.py --godot <4.7.2>` | PASS, 기존 6,389 assertions + restart 1/25, 정상 종료 |
| `<godot> --headless --path . res://tests/editor/traversal_tests.tscn` | 78 assertions 정상 종료 PASS 실행 확보. 별도 반복에서 성공 데이터 생성 후 0xC0000005가 발생한 실행은 FAIL로 유지 |
| `python tools/test_field_editor.py --godot <4.7.2>` | 전체 성공 실행 확보. 다른 실행에서는 검증기/기존 runtime 프로세스의 네이티브 종료 또는 EditorFileSystem 오류 때문에 runner가 FAIL |
| 같은 명령 `--rendered` | 마우스 이벤트 기반 에디터 기능·저장/재열기 PASS. 전체 성공 실행도 확보. 별도 실행의 기존 runtime/fixture 네이티브 종료는 FAIL로 유지 |
| `python tools/test_multiplayer_world_runtime.py --godot <4.7.2> --players 2` | 정상 종료 PASS 실행 및 최종 비교 2회 PASS. 별도 실행에 native 종료와 stamina mirror 미수렴 실패가 있어 무조건적인 안정 PASS로 판정하지 않음 |
| 같은 명령 `--players 3` | 기능 3/3 및 프로세스 정상 종료 PASS |
| Windows `--export-release "Windows Desktop"` | PASS |
| 생성 EXE `--headless --quit-after 120` | PASS, export 콘텐츠 34개, 정상 종료 |
| `git diff --check`, Python `py_compile` | PASS |

기본 콘텐츠 33개에 사용자의 로컬 `test_region` 1개가 추가되어 작업 트리 검증에서는
34개가 등록된다. 격리 에디터 테스트에서는 기존 fixture가 추가로 생성된다.
렌더링 GUI 검증은 엔진에 주입한 마우스 이벤트이며, 사람이 물리 마우스로 수행한 검증은 아니다.
외부 desktop automation은 창 바인딩 오류로 사용하지 못했다.

## 실패 관측과 해석

반복의 마지막 PASS로 앞선 실패를 덮어쓰지 않았다.

1. 기준 efbfe43의 격리 렌더링 회귀 2회 모두 기능 성공 뒤 기존 runtime 프로세스의
   `3221225477`이 발생했다. STEP 7에서는 전체 렌더링 회귀 정상 종료 2회와 네이티브
   종료 실행이 모두 관측됐다. 버전마다 실행한 child 수가 다르고 표본이 작아 확률 비교나
   동일 근본 원인을 확정할 수 없다.
2. 2인 ENet 비교에서는 기준 2회 중 1회 native 종료, STEP 7 비교 2회는 정상 종료였다.
   별도의 STEP 7 실행에서 client stamina mirror가 server max에 6초 내 수렴하지 못했다.
   관련 런타임·테스트 파일은 기준과 동일하며 이후 비교에서는 재현되지 않았다.
   원인은 미확정이다. timeout을 늘리거나 assertion을 완화하지 않았다.
3. Windows Application 이벤트의 예외는 `0xC0000005`, Godot 모듈 오프셋에는
   `0x547f2c`, `0x191eaee`, `0x191eae2`가 있었다. 작업 중 `CowData was modified
   during destruction`도 관측했다. 엔진 문제를 해결했다고 보고하지 않는다.
4. 실패 주입을 포함하는 에디터 회귀에서 `resource_format_text.cpp:1587 get_dependencies`
   오류가 간헐적으로 출력됐다. 인덱싱된 파일을 이동하던 실패 주입을 격리한 후의
   실행에서는 관측되지 않았지만 모든 발생의 근본 원인이 같다고 확정하지 않는다.
5. 최종 격리 실패 주입을 적용한 렌더링 실행에서 에디터 GUI 자체와 기존 runtime/
   보고서 fixture는 정상 종료했다. 이후 Traversal suite의 한 물리 child가
   `3221225477`로 종료하여 전체 runner는 FAIL이었다. 다음 headless 실행도 에디터
   기능 PASS 뒤 기존 runtime이 같은 코드로 종료했다. 성공 마커만으로 PASS 처리하지 않았다.

최종 실패 주입 격리 후 재실행에서도 실패를 기록했다. `rendered-isolated-final.log`는
에디터 기능과 종료가 정상이고 기존 runtime fixture들도 정상 종료했으나, 새 물리 suite의
한 child가 `3221225477`로 종료해 전체 FAIL이었다. `headless-isolated-final.log`는
기존 runtime 성공 마커 뒤 native 종료로 FAIL, `rendered-confirmation-final.log`는
모든 GUI assertion/물리 보고서 검사가 성공했으나 에디터 종료 코드가 `3221225477`여서
FAIL이다. 이 마지막 세 실행을 이전의 정상 종료 PASS로 대체하지 않는다.

로그는 이 개발 환경의 임시 폴더 `rtc7-final-validation-d1rlj6gg`와
`rtc7-native-comparison-hw4elram`, 각 `rtc-traversal-editor-logs-*`에 보존했다.
프로젝트 내부 개별 물리 작업의 request/result/status/godot.log도 `.godot/rtc_traversal`에 남는다.
네이티브 오류 및 ENet 간헐 실패가 남아 있어 전체 완료 조건을 **항상 안정적으로 통과한 것으로
인증하지 않는다**. 관련 런타임의 광범위한 수정은 이번 에디터 작업에 섞지 않았다.

## 보존 및 후속 범위

`export_presets.cfg`, `world/adventure/test_region.tscn`, `data/content/regions/test_region.tres`의
작업 전후 SHA-256 동일성을 확인했다. 해당 파일은 커밋에 포함하지 않는다.
복잡한 polygon/tile 표면 추출, 다른 장비·효과 프로필, 완전한 입력 탐색, 동적 플랫폼과
동시 다인 이동 시뮬레이션은 구현하지 않았다. STEP 8은 시작하지 않았다.
