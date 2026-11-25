# MONSTER-STEP 2 — Editor GUI Foundation, Monster Catalog, Legacy Import

STEP 1의 core 위에 PySide6 편집기 골격, 몬스터 카탈로그, 읽기 전용 Godot Bridge와 기존 몬스터 Import를 올린 기록이다.
사용법은 [monster_editor_user_guide.md](monster_editor_user_guide.md), Bridge 규약은
[monster_editor_bridge.md](monster_editor_bridge.md)에 있다.

## 1. 이번 단계에서 있는 것과 없는 것

| 구분 | 상태 |
|---|---|
| 편집기 창(메뉴·툴바·도킹 패널·단축키·설정 복원), 프로젝트 없이도 초안 편집 | **구현됨** |
| Monster Catalog: 게임 콘텐츠 / 초안 / 문제, 검색·필터, 등록 상태 | **구현됨** |
| 새 몬스터, 열기, 저장, 다른 이름으로 저장, 닫기, 복제, 초안 삭제, Undo/Redo | **구현됨** |
| Inspector: `metadata`·`stats`·`movement`·`sensors` 편집, 전리품 편집기 | **구현됨** (스키마에서 생성) |
| `assets`·`animations`·`collision`·`attack_patterns`·`behavior` | **읽기 전용 요약만** — 편집기는 STEP 3~5 |
| Godot Bridge `inspect_monsters` / `import_monster` | **구현됨** (읽기 전용) |
| Legacy Import: Sewer Beetle(완전), Frog(부분 — 표현하지 못한 2건을 표시) | **구현됨** |
| 검증 패널: 11개 영역, finding 이동, 오래된 결과 표시 | **구현됨** |
| 게임에 게시(Publish), Godot 런타임 테스트, 데이터 기반 몬스터 실행 | **없음** — `NOT_EVALUATED`. STEP 4~6 |
| Windows EXE | **없음** — `python main.py`로 실행. STEP 7 |

게임 런타임, 네트워크 프로토콜(20), 세이브 포맷(v5), Godot 버전(4.7.2), Map Editor는 바꾸지 않았다. 추가된 Godot
파일은 읽기 전용 Bridge(`tools/monster_bridge/bridge.gd`, `bridge.tscn`, `monster_inspector.gd`)뿐이고, 기존
`contract_probe.gd`는 같은 추출 코드를 쓰도록 정리했다(출력은 같다).

## 2. 시작 시점의 CI 실패 분류

`origin/master` = `6e35d51`에서 브랜치 `feature/monster-editor-step2`를 만들었다. 그 커밋의 GitHub Actions:

| 워크플로 | 결과 | 분류 |
|---|---|---|
| Python Monster Editor | 성공 | — |
| Python Map Editor | 성공 | 이전 커밋(`869e81b`)의 실패는 이후 master 커밋에서 해소됨 |
| Godot validation / `headless` | 성공 | — |
| Godot validation / `windows-demo` | **실패** | 기존 실패. 릴리스 EXE의 session lifecycle E2E에서 역할 D의 `host` 명령이 `command timeout`. `a032ff9`부터 `6e35d51`까지 master의 모든 커밋에서 같은 job이 실패한다 |

`windows-demo` 실패는 Monster Editor와 무관한 경로(내보낸 게임 EXE의 ENet 세션 수명주기)이고 STEP 2는 그 코드를
건드리지 않는다. 이번 단계에서 고치지 않았고, 이 브랜치에서도 같은 job이 실패할 수 있다. 로컬에서는 같은 커밋에서
`check_project.py`가 통과한다(§8).

## 3. 계층

```text
gui/            PySide6. 위젯과 입력만. 문서를 직접 고치지 않는다
  │  사용자 의도(편집, 저장, 가져오기)
  ▼
application/    Qt 없음. DocumentSession·History, ProjectSession, Settings, ValidationController, JobBoard
  │  Edit / read / write / validate
  ▼
rtcmonster/     STEP 1 core (불변 문서, 원자 편집, 저장, 검증, 카탈로그)

bridge/         Qt 없음. Godot 프로세스 실행(client)과 probe 결과 → 문서 변환(importer)
```

- `rtcmonster`, `application`, `bridge`는 PySide6를 import하지 않는다. `tests/test_application.py`가 새 프로세스에서
  이 세 패키지를 import한 뒤 `PySide6`/`shiboken6` 모듈이 하나도 로드되지 않았는지 검사한다.
- GUI가 문서를 바꾸는 길은 `MainWindow.apply_edits()` → `DocumentSession.apply()` 하나다. 위젯은 값을 들고 있을 뿐
  문서의 소유자가 아니다.
- 모달 대화상자는 `gui.dialogs.Prompts` 뒤에 있다. 테스트는 `gui.testing.ScriptedPrompts`로 답을 정해 두므로 창이
  멈추지 않는다. 대화상자 클래스 자체(`NewMonsterDialog`, `CloneDialog`)는 실제 위젯으로 따로 검사한다.

| 파일 | 책임 |
|---|---|
| `application/session.py` | `History`(스냅샷 목록과 커서, 500단계), `DocumentSession`(문서·경로·디스크 revision·dirty·편집 가능 범위) |
| `application/project.py` | 프로젝트 폴더·Godot 실행 파일 검사, 카탈로그, ID 상태, registry 결과 보관, 초안 삭제 |
| `application/settings.py` | JSON 설정. 손상되면 기본값으로 복구하고 그 사실을 알린다 |
| `application/work.py` | 검증 결과의 current/stale/none, 비동기 작업 ticket과 늦게 온 결과 폐기 |
| `bridge/client.py` | Bridge 호출, 취소·제한 시간, 응답 대조, 오류 코드 |
| `bridge/importer.py` | `LegacyImportProfile` 등록형 변환 |
| `gui/inspector.py` | 스키마 node → 위젯 등록표, Inspector 패널 |
| `gui/panels.py` | Overview, 썸네일, 전리품 편집기, 읽기 전용 요약 |
| `gui/lists.py` | 카탈로그 패널, 검증 패널 |
| `gui/main_window.py` | 창, 메뉴, 작업 흐름 |

## 4. Core에서 고친 것

| 문제 | 수정 |
|---|---|
| ID가 "비어 있다"와 "확인 못 했다"가 구분되지 않았다 | `MonsterCatalog.id_status()` → `AVAILABLE` / `CONFLICT` / `UNKNOWN`. `IdCheck`는 `bool()`로 쓸 수 없다(`TypeError`). 프로젝트가 없거나 콘텐츠 폴더를 못 읽으면 `UNKNOWN` |
| 초안끼리의 ID 충돌을 못 봤다 | `monster_catalog(project, drafts=…)`가 초안 폴더를 함께 읽고 `draft_duplicate_id`를 보고한다. 게임 몬스터에 묶인 초안(`source_binding`)은 그 몬스터의 작업본이므로 충돌이 아니다 |
| 콘텐츠 폴더가 링크로 프로젝트 밖을 가리킬 수 있었다 | `scan_content`가 링크·프로젝트 밖 경로를 읽지 않고 문제로 보고 |
| `stale_inputs`가 경로 검사를 거치지 않았다 | `resolve_project_file` 사용 |
| "수정됨"이 편집 횟수 기준이었다 | `DocumentSession.dirty` = 현재 fingerprint ≠ 저장된 fingerprint. Undo로 돌아오면 깨끗해진다 |
| 이미지 검사가 PNG 구조까지만 봤다 | 편집기는 Qt로 실제 디코딩한다. 구조 통과 / 디코딩 통과 / Godot import(미검사)를 따로 표시 |

`registry_verified`는 Godot이 실제로 답한 경우에만 붙는다. 파일로만 찾은 몬스터는 `discovered`("파일로 발견")이고
"등록됨"으로 표시하지 않는다. registry 결과는 프로젝트 설정이 바뀌면 버린다.

## 5. 편집기 동작의 근거

- **문서 세션.** 열기는 편집이 아니다: 손으로 정렬한 파일을 열어도 dirty가 아니고, 저장하지 않으면 다시 쓰지 않는다.
  저장은 `write_document(path, document, 마지막으로 본 revision)`이라 그 사이 파일이 바뀌었으면 `DocumentConflict`가
  난다. 이때 다시 불러오기 / 덮어쓰기(한 번 더 확인) / 다른 이름으로 저장 / 취소 중에서 고른다. 다른 이름으로 저장할
  때 기존 파일을 덮는 경우, 물어보는 동안 그 파일이 또 바뀌면 저장하지 않는다.
- **Undo/Redo.** 불변 문서 스냅샷의 목록이다. 한 번의 `apply_edits`가 한 단계이고(여러 필드 동시 변경도 한 단계),
  값이 바뀌지 않으면 단계가 생기지 않는다. 텍스트 입력 중의 Ctrl+Z는 그 입력란의 것이고, 확정된 뒤에는 문서 Undo로
  넘어간다.
- **잘못된 입력.** 구조적으로 불가능한 값(ID 형식 위반 등)은 적용하지 않고 원래 값으로 되돌리며 다른 필드는 그대로
  둔다. 범위를 벗어난 숫자는 초안에 남길 수 있고 검증이 `out_of_range`로 보고한다 — 편집기가 값을 몰래 고치지 않는다.
- **Inspector.** `document.schema.fields()`와 `node.info()`에서 만든다. 필드 이름이나 몬스터 ID로 분기하는 코드는
  없다. 새 위젯 종류는 `register_editor(matches, factory)` 한 번이다. 툴팁에 경로·범위·단위·기본값·지원 수준·
  "데이터 런타임: 미지원"을 적는다. `planned` 그룹 안의 필드는 "예정 · 게임에 적용되지 않음"으로 표시한다.
- **편집 가능 범위.** 새 초안과 복제본은 다섯 영역이 전부 편집 가능하다. Import한 문서는 `source_binding.editability`를
  따른다: `metadata`·`stats`·`loot`는 편집 가능, `movement`·`sensors`는 기존 스크립트가 값을 갖고 있어 읽기 전용,
  표현하지 못한 부분은 미지원. 읽기 전용 영역에 대한 편집은 세션이 거절한다(위젯 비활성화에만 의존하지 않는다).
- **복제.** 새 ID가 필수다. `source_binding`을 지우고, 전리품 테이블 ID를 새 ID 기준의 빈 이름으로 바꾼다. 원본 파일은
  건드리지 않는다.
- **삭제.** 초안 파일만 지운다. 경로·ID를 보여 주고 확인받으며, 목록에 표시된 뒤 파일이 바뀌었으면 지우지 않는다.
  게임 콘텐츠를 지우는 기능은 없다.
- **검증.** 편집하면 결과가 "오래됨"이 되고 잠시 뒤 한 번 다시 돈다(연속 편집은 한 번으로 합쳐진다). 프로젝트가
  바뀌어도 오래됨이다. 오래된 결과는 색을 빼고 경고문을 붙인다. `NOT_EVALUATED`는 "미검사"이며 통과 색을 쓰지 않는다.
- **Godot 작업.** 별도 스레드에서 돌고 창은 멈추지 않는다. 결과가 돌아왔을 때 프로젝트 상태(generation)나 열려 있는
  문서가 요청 시점과 다르면 결과를 버리고 그렇게 알린다. 창을 닫으면 편집기가 시작한 프로세스만 종료하고 기다린다.

## 6. Legacy Import

`import_monster`는 Godot이 읽은 실제 값을 받아 `bridge/importer.py`가 문서로 바꾼다. 행동과 공격은 **actor 스크립트
단위로 등록된 `LegacyImportProfile`**이 변환한다. 몬스터 ID로 분기하지 않는다.

| actor 스크립트 | profile | 결과 |
|---|---|---|
| `gameplay/actors/enemies/enemy_agent.gd` | `ground_melee` | 완전 |
| `gameplay/actors/enemies/frog/frog_agent.gd` | `hopper` | 부분 — Schema V1로 정확히 표현되지 않는 2건을 `source_binding.unsupported`에 기록 |
| 그 밖의 스크립트 | 없음 | 미지원 — 스탯·표현·판정처럼 읽을 수 있는 값만 가져오고 행동·공격은 "가져오지 않음"으로 표시. 게시 검사는 실패 |

profile이 기대한 상태 구성과 실제 actor가 다르면 그 profile을 쓰지 않고 미지원으로 내린다. Import 결과는 저장되지
않은 새 초안이며, 게임 파일을 쓰는 경로가 없다. 문서의 `source_binding.files`에 원본 파일들의 SHA-256이 들어가고,
Overview가 "원본 변경 없음 / 원본이 바뀜"을 표시한다.

검증(`check_godot_import.py`, 실제 Godot 4.7.2):

- 이 프로젝트: 두 몬스터의 Import가 검증된 예제 문서와 게임플레이 영역·애니메이션·source binding에서 같다. 저장 후
  재열기 동일. 프로젝트 파일 전체 해시가 실행 전후 같다.
- 격리된 프로젝트 사본에 몬스터 둘을 추가: 기존 actor를 쓰는 새 몬스터(`cave_beetle`)는 코드 변경 없이 자기 ID와
  자기 값으로 완전 Import된다. 모르는 actor 스크립트의 몬스터(`odd_bug`)는 미지원으로 보고되고 게시 검사가 실패한다.
- 실패: 실행 파일 없음, 다른 엔진 버전, 없는 몬스터, 제한 시간, 취소 — 각각 고유한 오류 코드, 남는 파일 없음.

## 7. 측정

Windows 11, Python 3.14.5, PySide6 6.11.3, 네이티브 플랫폼, 한 번 실행한 값(통계 아님). 원본은
[monster_editor_step2_screens/](monster_editor_step2_screens/)의 `smoke_report_*.json`.

| 동작 | 시간 |
|---|---|
| 창 시작 | 약 280 ms |
| 새 문서 생성(파일 저장 포함) | 약 33 ms |
| 필드 한 개 편집 / Undo / Redo (작은 초안) | 4 / 3 / 3 ms |
| 검증 | 5 ms |
| 저장 / 열기 | 17 / 23 ms |
| Inspector 생성 | 9 ms |
| Godot registry 확인, 몬스터 Import | 각 약 1.8 초 (Godot 프로세스 시작이 대부분) |

| 문서 규모 | 표시 | 편집 1회 | Undo | 검증+목록 |
|---|---|---|---|---|
| Small (clip 5, state 10) | 65 ms | 23–32 ms | 15–19 ms | 16 ms |
| Medium (clip 20, state 30) | 66 ms | 46 ms | 19 ms | 29 ms |
| Large (clip 50, state 64) | 130 ms | 91–97 ms | 24–28 ms | 58–61 ms |

Large 문서의 편집 1회가 100 ms에 가깝다. core의 편집 자체는 약 29 ms(STEP 1 측정)이고 나머지는 요약 패널을 통째로
다시 그리는 비용이다. STEP 2의 편집 대상(숫자·문자열 확정 입력)에서는 문제가 되지 않지만, STEP 3의 드래그 조작에는
요약 갱신을 미루는 처리가 필요하다. 스모크는 250 ms를 넘으면 실패한다.

## 8. 검증 결과

| 검사 | 결과 |
|---|---|
| `pytest tools/python_monster_editor/tests` (Windows, 네이티브) | 686 통과, 5 건너뜀 |
| GUI 스모크(실제 키·마우스 입력 + 실제 Godot), 100% / 150% / 200% | 각 38개 통과 |
| `check_godot_import.py` | 45개 통과 |
| `check_godot_contract.py`, `check_contract_extensibility.py` | 통과 (205 / PASS) |
| `check_project.py`, Map Editor pytest, ENet E2E 9종 | 통과 (§9) |

배율 검사는 `QT_ENABLE_HIGHDPI_SCALING=0`과 `QT_SCALE_FACTOR=1 / 1.5 / 2`로 device pixel ratio를 정확히
1.0 / 1.5 / 2.0으로 맞춰 돌렸다(개발 PC의 시스템 배율이 150%이기 때문). 초안 폴더는 한글과 공백이 든 경로를 썼다.
화면은 [monster_editor_step2_screens/](monster_editor_step2_screens/)에 있다.

**확인하지 않은 것**

- 사람이 직접 창을 조작한 검사는 하지 않았다. 입력은 전부 `QTest`가 실제 위젯에 보낸 키·마우스 이벤트다.
- 파일 선택 대화상자 등 OS 네이티브 대화상자는 `ScriptedPrompts`로 대체했으므로 자동 검사 범위 밖이다.
- Linux의 GUI 테스트는 offscreen 플랫폼이고 창 단위 단축키 테스트 2개는 건너뛴다(Windows에서 실행).
- macOS는 실행해 보지 않았다.
- Import의 "예제와 같음"은 게임플레이 영역 기준이다. 사람이 쓴 설명·태그, 이미지 ID 이름, clip 순서는 비교 대상이 아니다.

## 9. 최종 회귀 실행 기록

이 절은 커밋 직전에 실제로 실행한 명령과 결과다.

Windows 11, Python 3.14.5, PySide6 6.11.3, Godot 4.7.2. Godot을 쓰는 검사는 순차로 실행했다.

| 명령 | 결과 |
|---|---|
| `pytest tools/python_monster_editor/tests` (네이티브) | 686 통과, 5 건너뜀 (전부 "symbolic links are not available" — Windows 권한. Linux CI에서 실행된다) |
| 같은 명령, `QT_QPA_PLATFORM=offscreen` | 684 통과, 7 건너뜀 (위 5 + 창 단위 단축키 2) |
| `pyflakes` (rtcmonster, application, bridge, gui, main, 새 테스트) | 경고 없음 |
| `pytest tools/python_map_editor/tests` | 184 통과, 3 건너뜀 |
| `tools/check_project.py` | `ALL PROJECT CHECKS PASS` |
| `check_godot_contract.py` | 205 통과, 3 미검사 (environment·registry·legacy PASS) |
| `check_contract_extensibility.py` | PASS |
| `check_godot_import.py` | 45 통과 (연속 4회) |
| GUI 스모크 100% / 150% / 200%, 실제 Godot | 각 38 통과 |
| `test_multiplayer_restart.py` 2인 valid·invalid, 3인 valid | 통과 |
| `test_multiplayer_worlds.py` 2·3인 | 통과 |
| `test_multiplayer_world_runtime.py` 2·3인 | 통과 |
| `test_multiplayer_forest.py` 2·3인 | 통과 |

실행 중 드러난 두 가지:

- **추적되지 않은 파일과 격리 사본.** `check_contract_extensibility.py`는 git이 추적하는 파일만 복사한다. 새
  `monster_inspector.gd`를 `git add` 하기 전에는 사본에 그 파일이 없어 probe가 멈췄다(180초 제한 시간으로 실패).
  스테이징 후 통과한다. 코드 결함이 아니라 실행 순서 문제지만, 새 Godot 파일을 추가한 뒤에는 스테이징하고 이 검사를
  돌려야 한다.
- **Godot 종료 시 crash.** Bridge 호출이 결과를 쓴 뒤 엔진이 종료 도중 `0xC0000005`로 죽는 일이 있었다(150회 중 7회).
  STEP 1의 `contract_probe`에서도 80회 중 2회 재현되고, 게임 기본 씬 실행은 120회 중 0회였다. 원인은 밝히지 못했다.
  crash한 실행의 결과는 쓰지 않고, 읽기 전용 호출이므로 최대 3회까지 다시 실행한다. 재시도를 넣은 뒤 90회 연속
  호출에서 실패 0회. 자세한 내용은 [monster_editor_bridge.md](monster_editor_bridge.md)의 "엔진 종료 시 crash".
  콘솔 런처(`*_console.exe`)로 실행하면 취소·제한 시간 때 런처만 죽고 엔진이 남아 다음 실행과 겹치는 문제도 있어,
  Bridge client가 항상 엔진 실행 파일을 직접 띄우도록 했다.

## 10. 다음 단계로 넘기는 것

- 요약 패널의 부분 갱신(Large 문서, 연속 조작) — STEP 3 시작 시.
- `PySide6` 의존으로 CI의 core job이 Qt를 설치한다. core만 따로 검사하는 job이 필요해지면 분리한다.
- 공통 Python 패키지 추출은 하지 않았다. Bridge 프로세스 실행 코드는 Map Editor와 중복이다(Map Editor EXE 재검증
  비용 때문에 유지).
- 개구리의 미지원 2건은 Schema V2에서 해결한다(로드맵 STEP 5).
