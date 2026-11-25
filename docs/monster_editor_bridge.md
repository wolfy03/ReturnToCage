# Monster Editor Godot Bridge (protocol 1)

편집기가 게임의 실제 값을 읽기 위해 Godot을 실행하는 통로다. STEP 2의 두 명령은 **읽기 전용**이다: 결과 JSON 한
개 외에는 어떤 파일도 쓰지 않고, 리소스를 저장하지 않는다.

- Godot 쪽: `tools/monster_bridge/bridge.gd` + `bridge.tscn`, 공용 추출 코드 `monster_inspector.gd`
  (`contract_probe.gd`도 같은 코드를 쓴다).
- Python 쪽: `tools/python_monster_editor/bridge/client.py`(실행·검사), `bridge/importer.py`(문서 변환).

## 실행

```sh
godot --headless --path <project 절대 경로> res://tools/monster_bridge/bridge.tscn -- --request <request.json>
```

`--path`는 항상 절대 경로로 넘긴다. Godot은 프로젝트를 작업 폴더로 실행되므로 상대 경로는 다른 곳을 가리키고,
엔진이 프로젝트 관리자에서 제한 시간까지 멈춘다.

요청:

```json
{"protocol": 1, "request_id": "<요청마다 새 UUID>", "operation": "inspect_monsters" | "import_monster",
 "monster_id": "<import_monster일 때>", "result_path": "<임시 폴더의 절대 경로>.json"}
```

응답(결과 파일):

```json
{"protocol": 1, "request_id": "…", "operation": "…", "project_path": "<Godot이 본 res://의 실제 경로>",
 "status": "PASS" | "FAIL", "error_code": "", "message": "", "data": {…},
 "godot_version": "4.7.2-stable (official)", "physics_ticks_per_second": 60, …}
```

요청·결과 파일은 호출마다 새 임시 폴더에 만들고 호출이 끝나면 지운다(취소·제한 시간 포함).

## 명령

| 명령 | `data` |
|---|---|
| `inspect_monsters` | `monsters[]`: `monster_id`, `display_name`, `definition_path`, `actor_scene_path`, `agent_script`, `has_animation_profile`, `loot_table_id`, `definition_errors`. `content_errors`: `ContentRegistry.validate_all()`. Python이 각 행에 `import_support`(complete / partial / unsupported)를 붙인다 |
| `import_monster` | `monster_id`, `monster`(정의 값, scene 구조, 컴포넌트, shape, 상태 스크립트와 export 값, animation profile, loot — `contract_probe`와 같은 형식), `items`(아이템 ID 목록) |

몬스터 목록은 `ContentRegistry`가 실제로 등록한 `EnemyDefinition`이다. 편집기가 "Registry 확인됨"이라고 표시하는
근거는 이 응답뿐이다.

## 성공 판정

종료 코드 0은 성공이 아니다. 다음이 모두 참이어야 한다.

1. 프로세스가 정상 종료했다(음수·255 초과 코드는 crash).
2. 엔진 로그에 `SCRIPT ERROR:`, `Parse Error`, `ObjectDB instances leaked`, `resources still in use`가 없다.
3. 결과 파일이 있고 16 MiB 이하의 JSON object다.
4. `protocol`, `request_id`, `operation`이 요청과 같다.
5. `project_path`가 요청한 프로젝트와 같은 폴더다.
6. `status`가 `PASS`이고 `data`와 `godot_version`이 있다.
7. `import_monster`면 `data.monster_id`가 요청한 ID다.

### 엔진 종료 시 crash

Windows의 Godot 4.7.2는 Bridge가 일을 끝내고 결과를 쓴 **뒤**, 종료하는 도중에 access violation(`0xC0000005`)으로
죽는 경우가 있다. 개발 PC 측정: Bridge 150회 중 7회, 60회 중 1회, STEP 1의 `contract_probe` 80회 중 2회, 게임 기본
씬 120회 중 0회. 종료를 몇 프레임 미뤄도 달라지지 않았고 원인은 밝히지 못했다.

crash한 실행의 결과는 내용이 멀쩡해 보여도 쓰지 않는다. 두 명령은 읽기만 하므로 같은 호출을 다시 실행한다(최대 3회).
`BridgeResponse.attempts`에 횟수가 남는다. 세 번 모두 crash하면 `PROCESS_CRASH`다. 파일을 쓰는 명령이 생기면 이
재시도를 그대로 쓸 수 없다 — 그 단계에서 다시 정한다. `check_godot_contract.py`(STEP 1)는 재시도하지 않으므로 같은
이유로 드물게 실패할 수 있다.

## 오류 코드

| 코드 | 뜻 |
|---|---|
| `GODOT_MISSING` | 실행 파일이 없거나 실행되지 않는다 |
| `GODOT_VERSION_MISMATCH` | `--version`이 프로젝트의 `.godot-version`과 다르다 |
| `PROJECT_INVALID` | `project.godot`이나 Bridge scene이 없는 폴더 |
| `TIMEOUT` | 제한 시간(기본 180초) 초과. 프로세스는 종료된다 |
| `CANCELLED` | 사용자가 취소. 프로세스는 종료된다 |
| `PROCESS_CRASH` | 네이티브 crash 종료 코드 |
| `ENGINE_ERROR` | 엔진 로그에 스크립트 오류·누수 |
| `INVALID_RESPONSE` | 결과 파일이 없거나 JSON이 아니거나 형식이 다르다 |
| `RESPONSE_MISMATCH` | 다른 요청·명령·프로젝트·몬스터에 대한 응답 |
| `UNKNOWN_MONSTER` | 등록되지 않은 `monster_id` (Godot이 답한 코드) |
| `PROTOCOL_MISMATCH`, `UNKNOWN_OPERATION` | Bridge가 요청을 거절 |

편집기는 코드를 그대로 보여 주고 엔진 로그를 보관한다. 실패한 작업은 열려 있는 문서를 바꾸지 않는다.

## 프로세스 관리

- 편집기가 시작한 자식 프로세스만 종료한다. 이미 떠 있는 Godot 에디터나 게임은 찾지도 건드리지도 않는다.
- Windows에서는 콘솔 창 없이(`CREATE_NO_WINDOW`), POSIX에서는 새 세션으로 실행한다.
- 편집기는 콘솔 런처(`*_console.exe`)를 받으면 같은 폴더의 엔진 실행 파일로 바꿔 쓴다. 런처는 엔진을 손자 프로세스로
  띄우므로 취소 시 엔진이 남을 수 있기 때문이다.
- 호출 전에 `--version`으로 엔진 버전을 확인한다.

## Map Editor Bridge와 다른 점

Map Editor Bridge는 프로젝트 스냅샷 복사본에서 실행한다 — 씬을 저장하기 때문이다. Monster Bridge의 STEP 2 명령은
아무것도 저장하지 않으므로 실제 프로젝트에서 바로 실행한다(복사 비용 없이 약 1.8초). 파일을 쓰는 명령
(`stage_monster`, `publish`)이 생기는 단계에서는 Map Editor와 같은 복사본 실행과 저널을 쓴다
([아키텍처 §6](monster_editor_architecture.md)).

Godot은 실행 중 `.godot/` 캐시를 갱신할 수 있다. 이것은 엔진의 캐시이고 추적 파일이 아니다. `check_godot_import.py`는
`.godot/`를 제외한 프로젝트의 모든 파일 해시가 실행 전후 같은지 검사한다.

## Legacy Import Profile 추가

새 종류의 legacy actor를 가져오려면 `bridge/importer.py`에 그 actor 스크립트에 대한 profile을 등록한다.

```python
register_import_profile(
    "res://gameplay/actors/enemies/bat/bat_agent.gd",
    LegacyImportProfile("flyer", {"idle": "res://…/bat_idle_state.gd", …}, build_flyer,
                        unsupported=({"path": "…", "reason": "…"},)))
```

- 키는 actor 스크립트 경로다. 몬스터 ID로 분기하지 않는다 — 같은 스크립트를 쓰는 몬스터는 전부 같은 profile로 온다.
- `states`는 profile이 전제하는 상태 ID → 스크립트 경로다. 실제 actor와 다르면 profile을 쓰지 않고 미지원으로 내린다.
- `build(monster)`는 `movement`·`sensors`·`hitboxes`·`attack_patterns`·`behavior`를 돌려준다.
- V1로 정확히 표현할 수 없는 동작은 `unsupported`에 적는다. 적힌 항목이 있으면 결과는 "부분"이고 게시 검사가 실패한다.
- 검증: 격리된 프로젝트 사본에서 그 actor의 몬스터를 Import하는 검사를 `check_godot_import.py`에 추가한다.
