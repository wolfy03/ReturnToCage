# Monster Editor Godot Bridge (protocol 1)

> MONSTER-STEP 3에서 `stage_monster`가 추가됐다(아래 "stage_monster"). protocol은 1 그대로다: 이 명령을 모르는
> 이전 bridge는 `UNKNOWN_OPERATION`으로 답한다. `inspect_monsters`와 `import_monster`는 여전히 읽기만 한다.

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

## stage_monster / read_stage (STEP 3, 안정화에서 강화)

요청에 `"stage"`가 붙는다. `staging_session`은 편집기가 사본을 만들 때 표식에 적은 세션 ID다.

```json
{"images": {"<image id>": "<프로젝트 기준 PNG 경로>"},
 "clips": [{"id": "idle", "fps": 10, "loop": true,
            "frames": [{"image": "<image id>", "rect": [0, 0, 64, 48], "duration": 1}]}],
 "presentation": {"roles": {"idle": "idle"}, "visual_scale": [1, 1], "visual_offset": [0, -13],
                  "faces_right_by_default": true, "attack_hit_frame": 2, "airborne_speed": 30, "move_speed_threshold": 8},
 "carrier": "<등록된 Enemy ID, 비우면 registry의 첫 Enemy>", "texture_filter": 1,
 "staging_session": "<32자리 세션 ID>"}
```

`tools/monster_bridge/monster_stager.gd`가 처리한다. 다음 순서로 거절한다.

1. 프로젝트 루트에 `.rtc_monster_staging` 표식이 없거나 세션 ID를 읽을 수 없다 → `NOT_A_STAGING_PROJECT`.
2. 요청의 `staging_session`이 표식의 세션과 다르다 → `STAGING_NOT_OWNED`. 표식이 있다는 이유만으로 쓰지 않는다.
3. 요청 값이 틀렸다 → `INVALID_REQUEST`. ID 형식, 이미지 경로, 개수 한도, fps·duration 범위, rect가 **정수
   픽셀**이고 이미지 안인지, 역할이 staged Clip을 가리키는지, scale > 0, hit frame이 [0, 64]의 정수인지, texture
   filter가 enum 범위인지를 전부 본다. script error가 아니라 코드로 답한다.

통과하면 `res://monster_stage/<monster_id>/`의 이전 파일을 지우고 `sprite_frames.tres`와 `animation_profile.tres`를
`ResourceSaver`로 저장한 뒤 응답 `data`에 다음을 담는다.

| 키 | 내용 |
|---|---|
| `sprite_frames_path`, `profile_path` | 저장한 두 리소스 |
| `profile` | 저장한 profile을 디스크에서 다시 읽은 결과(`monster_inspector.gd`의 `profile()`과 같은 형식) |
| `attach` | carrier actor를 표현 actor와 서버 런타임 actor로 한 번씩 ready시킨 결과(`has_presenter`, sprite의 `SpriteFrames` 경로·첫 frame 텍스처·위치·scale·`texture_filter`) |
| `monster_id`, `staging_session` | 요청과 대조된다 |

**`read_stage`.** 요청 `"stage": {"staging_session": "…"}`. 같은 세션 검사를 거쳐 staged 두 파일을 **디스크에서**
읽어 `profile`(같은 형식)과 `resources`(`res://` 경로 → `FileAccess.get_sha256`)를 돌려준다. 편집기는 이것을
`stage_monster`가 끝난 뒤 **새 프로세스**로 실행하므로, 재읽기가 만든 프로세스의 메모리에 남은 객체일 수 없다.

추가 오류 코드: `NOT_A_STAGING_PROJECT`, `STAGING_NOT_OWNED`, `INVALID_REQUEST`(형식·범위),
`RESOURCE_MISSING`(Godot이 PNG를 텍스처로 못 읽음, 또는 staged 파일 없음), `EXPORT_FAILED`(저장 실패).

Python 쪽(`bridge/staging.py`)의 코드:

| 코드 | 뜻 |
|---|---|
| `NOTHING_TO_STAGE` | Clip이 없는 문서 |
| `STAGING_INSIDE_PROJECT` | 작업 폴더가 프로젝트이거나 그 안 |
| `STAGING_UNSAFE_SOURCE` | 프로젝트에 링크·junction·reparse point·특수 파일이 있다. 복사를 시작하지 않는다 |
| `STAGING_TOO_LARGE` | 파일 수·크기 한도 초과, 또는 여유 공간 부족 |
| `STAGE_FAILED` | 복사 실패, import 실패 |
| `STAGING_NOT_OWNED` | 삭제하려는 폴더가 이 세션이 만든 사본이 아니다(표식 없음·다른 세션·링크·잘못된 위치) |
| `STAGING_CLEANUP_FAILED` | 사본을 다 지우지 못했다. 경로와 원인을 담는다. 다시 시도할 수 있다 |
| `RESOURCE_PATH_INVALID` | 응답이 가리키는 경로가 사본 안의 허용된 파일이 아니다 |

사본의 소유권, 수명, 응답 검사, 비교 항목은 [monster_editor_step3_stabilization.md](monster_editor_step3_stabilization.md) §6~7.

## render_check (안정화)

`tools/monster_bridge/render_check.tscn`. Bridge의 명령이 아니라 별도 씬이며 **`--headless` 없이** 실행한다.

```sh
godot --path <staging 사본> res://tools/monster_bridge/render_check.tscn -- --request <request.json>
```

```json
{"protocol": 1, "request_id": "…", "result_path": "…", "staging_session": "…", "monster_id": "…",
 "carrier": "sewer_beetle", "output_dir": "<편집기가 만든 폴더>", "size": [320, 240], "zoom": 3,
 "shots": [{"name": "idle_f0_right", "clip": "idle", "frame": 0, "facing": 1, "shapes": [{"kind": "body", "shape": {…}}]}],
 "timings": [{"clip": "idle", "seconds": 0.7}]}
```

같은 세션 검사를 거친다. carrier actor를 staged profile로 ready시키고(simulation 꺼짐) 각 shot의 Clip·frame·facing을
실제 presenter의 sprite에 지정해 off-screen viewport에 그린 뒤 `output_dir`에 PNG로 저장한다. 응답에는 shot마다
scene tree에서 읽은 frame 네 모서리의 화면 좌표, 쓰인 텍스처와 region, presenter scale이, 그리고 sprite의 texture
filter, 상태별로 presenter가 고른 Clip, 실제 재생 중 기록한 (경과 시간, frame) 표본, 렌더러 정보(display server,
rendering method·driver, 그래픽 어댑터)가 들어 있다. headless로 실행하면 `NO_RENDERER`로 답한다.

쓰는 파일은 결과 파일과 `output_dir`의 PNG뿐이다. 도형 overlay는 요청에 담긴 **문서의** 도형을 그린 것이고 게임의
판정이 아니다.

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

crash한 실행의 결과는 내용이 멀쩡해 보여도 쓰지 않는다. 읽기 명령은 같은 호출을 다시 실행한다(최대 3회).
`stage_monster`도 다시 실행한다 — 버려도 되는 사본 안의 자기 출력 폴더만 쓰고, 시작할 때 이전 시도의 파일을 지우기
때문이다. 실제 프로젝트에 쓰는 명령은 재시도하지 않는다(그런 명령은 아직 없다). 세 번 모두 crash하면
`PROCESS_CRASH`다. `check_godot_contract.py`(STEP 1)는 재시도하지 않으므로 같은 이유로 드물게 실패할 수 있다.

기능 결과와 프로세스 결과는 따로 남는다.

| `BridgeResponse` | 뜻 |
|---|---|
| `attempts` | 몇 번째 시도에서 답을 얻었나 |
| `crashes` | 버린 시도들의 종료 코드 |
| `crash_log` | 첫 crash의 엔진 로그 |
| `process_result` | `CLEAN` / `CRASHED_THEN_RETRIED` |

종료 코드만으로 "알려진 엔진 crash"라고 단정하지 않는다([known_issues.md](known_issues.md)의 분류 기준). 로그를
남기는 것은 그 판단을 사람이 할 수 있게 하기 위해서다.

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
| `NO_RENDERER` | render check를 렌더러 없이 실행했다. NOT_EVALUATED로 보고한다 |

편집기는 코드를 그대로 보여 주고 엔진 로그를 보관한다. 실패한 작업은 열려 있는 문서를 바꾸지 않는다.

## 프로세스 관리

- 편집기가 시작한 자식 프로세스만 종료한다. 이미 떠 있는 Godot 에디터나 게임은 찾지도 건드리지도 않는다.
- 취소·제한 시간에는 그 프로세스의 **트리**를 끝낸다(Windows `taskkill /F /T /PID`, POSIX는 프로세스 그룹). 자식이
  남으면 작업 폴더를 잡고 있어 staging 사본을 지울 수 없다. 대상은 시작한 PID에서 찾는다. 이름으로 찾지 않는다.
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
