# MONSTER-STEP 3 — Animation / Collision Editor

STEP 2([monster_editor_step2.md](monster_editor_step2.md)) 위에 이미지·Clip·화면 배치·판정 도형 편집과,
Godot이 표현 리소스를 직접 만들어 보는 staging 검증을 더했다. 게임 런타임·`NetworkProtocol`(20)·Schema(V1)·
Bridge protocol(1)은 바뀌지 않았다. 게임 프로젝트의 파일은 이 단계의 어떤 기능으로도 쓰이지 않는다.

## 1. 있는 것과 없는 것

| 항목 | 상태 |
|---|---|
| 이미지 등록(크기·SHA-256 측정), 갱신, 삭제 | 구현 |
| 격자 분할 Clip(`slice_grid`), 이미지별 Clip | 구현 |
| frame 순서·지속 시간, FPS, loop | 구현 |
| 역할 연결(9개 역할) | 구현 |
| 재생 미리보기(문서의 시간 규칙 `timing.frame_at` 그대로) | 구현 |
| `visual_scale` / `visual_offset`, bottom-center 맞춤 | 구현 |
| body·hurtbox·hitbox 편집(사각형·원): 드래그와 숫자 입력 | 구현 |
| 좌우 반전 미리보기 | 구현 |
| frame별·Clip별 hurtbox override | 구현 (편집). 게임이 읽지는 않는다 — schema의 `planned` |
| Bridge `stage_monster`: Godot이 `SpriteFrames`·`EnemyAnimationProfile` 생성 | 구현 (staging 사본 안에서만) |
| 실제 프로젝트에 게시 | **없음** (STEP 6) |
| `texture_filter` 편집 | **없음** — Schema V1에 필드가 없다(§6) |
| frame `offset`, Clip `on_finish`·`priority` 편집 | **없음** (`planned`, 값 표시도 요약에만) |
| 렌더링된 화면으로 staging 결과 확인 | **NOT_EVALUATED** — staging은 headless다(§5) |

## 2. 계층

```text
gui/animation.py            AnimationWorkspace, PreviewCanvas, load_frame      (Qt)
application/animation.py    한 동작 -> Edit 목록. 이미지/Clip/역할/도형/override   (Qt 없음)
bridge/staging.py           프로젝트 사본, stage 요청, 재읽기 대조                 (Qt 없음)
tools/monster_bridge/monster_stager.gd   Godot 안에서 리소스 생성·저장·재읽기·attach
```

- workspace는 문서를 바꾸지 않는다. 모든 동작은 `edits_requested(edits, label)`로 나가고 창의
  `apply_edits` → `DocumentSession.apply` 한 곳에서 적용된다. 동작 하나가 Undo 한 단계다.
- 기하와 시간 식은 새로 만들지 않았다. 캔버스는 `geometry.sprite_to_actor` / `mirror_shape` /
  `shape_bounds`를, 재생은 `timing.frame_at` / `clip_seconds`를 그대로 쓴다.
- 필드·몬스터별 분기는 없다. `application/animation.py`와 stager는 어떤 몬스터 이름도 모른다.
- `rtcmonster.spec.EDITOR_EDITABLE_SECTIONS`에 `assets`, `animations`, `presentation`, `collision`이 추가됐다.
  게임에서 가져온 문서는 이 구역이 `read_only`로 묶여 있으므로(`importer.LEGACY_EDITABILITY`) 미리보기만 된다.

## 3. 편집 동작의 근거

| 동작 | 규칙 | 이유 |
|---|---|---|
| 이미지 등록 | core의 경로·헤더·무결성 검사를 통과한 PNG만. 크기와 해시는 파일에서 읽는다 | 손으로 적은 크기는 `asset_size_mismatch`의 원인이다 |
| 격자 Clip | 이미지 크기가 격자로 나누어떨어져야 한다 | 나머지가 있는 분할은 조용히 잘린 frame을 만든다 |
| Clip 삭제 | 그 Clip을 가리키는 역할과 override를 같은 Undo 단계에서 함께 지운다 | 남으면 `unknown_animation` FAIL이 된다 |
| frame 삭제 | 그 frame의 override는 지우고 뒤 frame의 override 번호를 하나씩 당긴다 | override는 번호로 frame을 가리킨다 |
| 사용 중인 이미지 삭제 | 거절 | Clip을 깨뜨리는 삭제를 한 번의 클릭으로 허용하지 않는다 |
| 도형 드래그 | 드래그 중에는 캔버스의 미리보기만 바뀌고, **버튼을 뗄 때 편집 1회** | 편집 1회는 문서 전체를 정규화한다(§4) |
| 겹친 도형 선택 | 이미 선택된 도형이 우선(핸들 → 영역), 아니면 위에 그려진 도형 | 목록에서 고른 body를 hurtbox 밑에서도 끌 수 있어야 한다 |
| 사각형 크기 조절 | 끈 변만 움직이고 반대 변은 고정. 최소 1 px | 중심 고정 방식은 반대쪽이 함께 움직여 맞추기 어렵다 |
| 반전 미리보기에서의 드래그 | 화면 좌표를 authored(오른쪽 보기) 공간으로 되돌려 저장 | 문서의 도형은 항상 오른쪽 보기 기준이다 |
| 저장 값 | 소수 둘째 자리로 반올림 | 드래그가 sub-pixel 잡음을 문서에 남기지 않게 |
| hurtbox override | frame 전용 → Clip 전용 → 기본 세트 순으로 적용. 만들 때 현재 적용 중인 세트를 복사 | schema의 정의 그대로(`boxes`가 세트 전체를 대체) |

거절된 동작은 문서를 바꾸지 않고 workspace 위쪽에 이유를 보여 준다.

## 4. 편집 1회의 비용

STEP 2는 Large 문서(50 clip, 64 state)에서 편집 1회 91~97 ms를 재고 "대부분이 요약 재생성"이라고 적었다.
이 단계에서 다음을 바꿨다.

- 요약 패널: 보일 때만, 그리고 보여 주는 구역이 실제로 바뀐 경우에만 다시 그린다(snapshot이 바뀌지 않은 구역을
  공유하므로 identity 비교가 정확하다). 숨겨진 상태에서 `toHtml()`로 읽으면 그때 갱신한다.
- 전리품 표: `loot` 구역이 바뀐 경우에만 셀 위젯을 다시 만든다.
- 대표 이미지: PNG 구조 검사(파일 전체 읽기 + 해시)를 파일의 크기·수정 시각별로 한 번만 한다.

같은 장비에서 다시 잰 값(Large, 최솟값):

| 구간 | ms |
|---|---|
| 편집 1회 전체(`apply_edits`) | 70.1 |
| core `document.apply` | 28.5 |
| Inspector / 전리품 / 요약 / Animation workspace 갱신 | 0.1 / 0.0 / 0.0 / 0.3 |
| 검증 결과 표시 | 4.7 |
| 나머지(문서 fingerprint 계산, history) | 약 36 |

GUI 갱신은 더 이상 비용의 주된 부분이 아니다. 남은 비용은 문서 정규화와 fingerprint(변경 없는 편집 판별과
dirty 표시에 쓰인다)이며 둘 다 core의 일이다. smoke의 Large 편집 1회는 89.9 ms로 한도(250 ms) 안이다.
**결정:** 연속 조작은 gesture가 끝날 때 한 번만 편집으로 확정한다. 변경된 subtree만 정규화하는 방식은 core의
불변식 전체를 다시 검증해야 해서 이번에 하지 않았다.

## 5. Staging (`stage_monster`)

`Godot → 표현 리소스 Staging 검증`, 또는 `bridge.staging.stage_presentation()`.

1. 프로젝트를 새 폴더로 복사하고(`.git`, `.github`, `.claude`, `build`, `docs`, `devtools` 제외, import cache인
   `.godot`은 포함) 사본에 `.rtc_monster_staging` 표식을 둔다. 사본은 프로젝트 **밖**에만 만든다.
2. 사본에서 `--import`를 돌린다(새 PNG가 텍스처가 된다).
3. 사본에서 bridge의 `stage_monster`를 실행한다. Godot이 `SpriteFrames`(frame마다 `AtlasTexture`)와
   `EnemyAnimationProfile`을 만들어 `ResourceSaver`로 `res://monster_stage/<monster_id>/`에 저장하고, 저장한
   파일을 다시 읽어(`monster_inspector.gd`의 `profile()` — 기존 몬스터를 읽는 것과 같은 코드) 돌려준다.
4. 등록된 Enemy actor 하나(carrier)에 그 profile 경로를 붙여 ready시킨다: 한 번은 표현 actor로, 한 번은 서버
   런타임이 만드는 방식(`presentation_enabled = false`)으로.
5. Python이 재읽기 결과를 문서와 필드별로 대조한다(`staging.compare`).

**안전.** 실제 프로젝트는 쓰이지 않는다. 사본을 먼저 만들고, stager는 표식이 없는 프로젝트를
`NOT_A_STAGING_PROJECT`로 거절하며, Python은 프로젝트 안쪽을 staging 폴더로 받지 않고, 표식 없는 폴더를 지우지
않는다. Python은 `.tres` 텍스트를 조립하지 않는다.

**실패와 차이는 다르다.** Godot이 만든 것이 문서와 다르면 예외가 아니라 `StageResult.differences`다. 결과를 못
얻은 실행만 `BridgeError`다. 실패한 실행의 사본은 조사할 수 있게 남기고 경로를 오류에 적는다.

**crash 재시도.** 엔진 종료 crash([monster_editor_bridge.md](monster_editor_bridge.md)의 "엔진 종료 시 crash")로 끝난 실행은 믿지 않고 최대 3회까지
다시 한다. `stage_monster`는 버려도 되는 사본 안의 자기 출력만 덮어쓰므로 재시도가 안전하다.

**headless의 한계.** 4번은 presenter가 만들어졌고 sprite가 staged `SpriteFrames`의 텍스처를 갖고 있으며
위치·scale이 문서와 같은지를 확인한다. 화면에 실제로 그려진 픽셀은 확인하지 않는다 — NOT_EVALUATED다.

## 6. Schema에 없는 것: `texture_filter`

`EnemyAnimationProfile.texture_filter`는 Schema V1에 필드가 없다. 가져온 문서는 값을
`source_binding.passthrough.profile_texture_filter`에 갖고 있고 staging은 그 값을 profile에 넘긴다. 새 초안은
profile 기본값(`NEAREST`)으로 staging된다. 손그림 정식 아트에 필요한 `LINEAR`를 초안에서 고르려면 Schema V2의
필드와 migration이 필요하다([monster_editor_compatibility.md](monster_editor_compatibility.md)).

## 7. 검증

| 검사 | 명령 | 결과 |
|---|---|---|
| 전체 pytest | `python -m pytest tools/python_monster_editor/tests` | 757 passed, 5 skipped |
| 편집 로직 | `tests/test_animation_editing.py` | 21 |
| workspace (실제 클릭·드래그 포함) | `tests/test_gui_animation.py` | 13 |
| staging (가짜 엔진 프로세스) | `tests/test_staging.py` | 37 |
| **실제 Godot staging** | `python tools/python_monster_editor/check_godot_stage.py --godot <godot>` | PASS (26 checks, 3 staged) |
| GUI smoke (native, 100%) | `python tools/python_monster_editor/main.py --smoke-report … --smoke-shots …` | PASS (27) |

`check_godot_stage.py`가 실제 엔진으로 확인하는 것: 딱정벌레·개구리 예제와, 편집기의 helper로 기존 아트에서
조립한 새 초안을 각각 staging — 재읽기가 문서와 같음, `validation_errors()`가 빈 목록, carrier actor가 staged
리소스로 그림, 서버 런타임 actor는 visual을 만들지 않음, 저장된 `SpriteFrames`가 엔진이 쓴 리소스임. 그리고
실제 프로젝트가 `stage_monster`를 거절함, 없는 이미지가 stage를 멈춤(`RESOURCE_MISSING`), clip 없는 문서는 사본을
만들기 전에 거절됨, 전체 실행 뒤 실제 프로젝트가 바이트 단위로 그대로임.

skip 5건은 기존과 같다(offscreen에서의 창 단축키, 심볼릭 링크 권한).

## 8. 다음 단계로 넘기는 것

- Schema V2: `texture_filter`, staging 출력 경로. 개구리의 unsupported 2건과 함께.
- 게시(STEP 6): staging에서 검증된 두 리소스를 실제 프로젝트로 옮기는 트랜잭션. 지금의 `stage_monster`는
  사본 밖으로 아무것도 내보내지 않는다.
- hurtbox override와 hitbox를 읽는 데이터 런타임(STEP 4). 지금은 편집·검증만 된다.
- 렌더링 확인: staging 사본에서 rendered probe로 screenshot을 찍는 검사.
- carrier 선택 UI: 지금 메뉴는 registry가 처음 주는 Enemy를 쓴다. `stage_presentation(carrier=…)`는 이미 받는다.
