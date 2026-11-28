# MONSTER-STEP 3 안정화 — 참조 무결성, Staging 안전성, 렌더링 검증, STEP 4 준비

STEP 3([monster_editor_step3.md](monster_editor_step3.md))의 Animation / Collision 편집과 Staging을 안정화한 기록이다.
게임 런타임, `NetworkProtocol`(20), 세이브(v5), Schema(V1), Bridge protocol(1), Godot 버전(4.7.2)은 바꾸지 않았다.
추가된 Godot 파일은 staging 사본에서만 동작하는 검증 도구(`tools/monster_bridge/render_check.gd`, `.tscn`)뿐이다.

## 1. 기준과 통합

| 항목 | 값 |
|---|---|
| 브랜치 | `feature/monster-editor-step3-stabilization` |
| 출발점 | `feature/monster-editor-step3` = `94e0689` (STEP 2의 `95a0f7e`를 포함) |
| 통합한 master | `8a24f91` (merge base `6e35d51`, master 쪽 10개 커밋). 충돌 없이 병합 |
| 병합 직후 baseline | Monster Editor pytest 757 통과 / 5 건너뜀 (STEP 3 보고와 같은 수) |

master에서 온 Runtime 안정화(점프 패킷 재전송, CommandWatchdog, lifecycle idle 한도, map bridge 플랫폼 동기화,
functional / process 결과 분리)는 그대로 있다. 이 브랜치는 `tools/python_monster_editor/`, `tools/monster_bridge/`,
`.github/workflows/python-monster-editor.yml`, `docs/`만 고쳤다.

작업 중 같은 PC에서 다른 세션의 Godot 프로세스가 돌고 있었다. 건드리지 않았고, 이 브랜치의 검사는 자기가 시작한
프로세스만 종료한다.

## 2. 문제별 결과

| 항목 | 기존 문제 | 근본 원인 | 수정 | 결과 |
|---|---|---|---|---|
| FIX-01 | frame을 옮기면 그 frame의 Hurtbox 세트가 다른 frame에 붙는다 | GUI가 frame 배열만 `move_item` 했다. override와 `attack_hit_frame`은 **번호**로 frame을 가리킨다 | `application.animation.move_frame`: 이동 + 번호 재지정을 한 edit 목록으로. GUI는 성공을 확인한 뒤 선택을 옮긴다 | PASS |
| FIX-02 | frame 삭제는 override만 당기고 `attack_hit_frame`은 그대로였다. 마지막 frame도 지워졌다 | 번호 참조를 한 군데서 관리하지 않았다 | 이동·삭제·삽입·복제가 같은 mapping(`references.remap_frames`)을 쓴다. 타격 frame 삭제는 대체 frame을 **묻는다**. 마지막 frame 삭제는 거절 | PASS |
| FIX-03 | Clip 삭제가 역할·override만 정리하고 공격 패턴·AI의 참조를 끊었다 | 참조를 필드 경로로 하드코딩했다 | schema 순회로 참조를 찾는다(`references.incoming`). 게임플레이 참조가 있으면 거절하거나 대체 Clip으로 재연결. ID 변경 추가 | PASS |
| FIX-04 | 사용 중인 Hitbox 삭제 가능. 이미지 크기가 바뀌어도 갱신이 조용히 통과 | 위와 같음 | Hitbox는 이벤트 참조가 있으면 거절·대체. 이미지 갱신은 rect가 벗어나면 거절(rect를 줄이지 않는다). 이미지 삭제는 frame을 지우지 않는다 | PASS |
| FIX-05 | 좌표 변환이 화면 코드에 섞여 있었고 검증이 얕았다 | — | 변환 순서를 문서화하고 반전 상태의 양쪽 핸들 크기 조절, 왼쪽을 보는 아트, 확대·pan·visual_scale 분리, NaN·Infinity 입력을 테스트 | PASS |
| FIX-06 | 드래그 중 문서·Clip·frame이 바뀌면 다른 대상에 적용될 수 있었다 | 드래그가 "선택된 도형"만 기억했다 | 드래그는 세션(context, 도형, facing, 원래 값)이다. 하나라도 달라지면 취소. Esc·포커스 상실·workspace 전환·재생 시작도 취소 | PASS |
| FIX-07 | 일시정지 후 재생이 처음부터 다시 시작. 재생 중 판정 편집 가능 | 재생 상태가 "타이머가 도는가" 하나였다 | Qt 없는 `application.playback.Playback`: 정지 / 재생 / 일시정지. 재생 중 캔버스는 읽기 전용 | PASS |
| FIX-08 | frame cache가 개수(128)로만 제한 → 해상도에 따라 2 GiB까지 | — | 바이트 예산(96 MiB) + LRU. 큰 시트를 frame마다 통째로 다시 디코딩하던 것도 수정 | PASS |
| FIX-09 | `copytree(symlinks=False)`가 링크를 따라가 프로젝트 밖을 복사할 수 있었다 | — | 복사 전에 전체를 조사해 링크·junction·reparse point·특수 파일이 있으면 시작하지 않는다. 파일 수·크기·여유 공간 한도, 취소, 복사 중 원본 변경 감지 | PASS |
| FIX-10 | 표식 파일만 있으면 어떤 폴더든 지울 수 있었고 삭제 실패를 숨겼다 | 삭제 권한이 "표식 존재"였다 | `StagingSession`: 세션 ID가 표식과 일치하고 폴더가 만든 그대로일 때만 삭제. 실패는 `STAGING_CLEANUP_FAILED`로 보고하고 재시도 가능 | PASS |
| FIX-11 | 응답 검증·비교 중 예외가 나면 사본이 남았다 | 정리가 `BridgeError` 분기에만 있었다 | `stage_presentation`이 모든 경로에서 사본을 지운다(`keep=True`일 때만 호출자 소유) | PASS |
| FIX-12 | 응답 경로를 `res://`만 떼고 존재 여부만 봤다. Godot 쪽 입력 검증이 느슨했다 | — | 응답의 타입·세션·경로(사본 안, 허용 폴더, 확장자, 링크 경유 금지) 검사. stager가 모든 요청 값을 검사하고 다른 세션의 요청을 거절 | PASS |
| FIX-13 | 재읽기가 리소스를 만든 프로세스 안에서 이뤄졌다 | — | 두 번째 Godot 프로세스(`read_stage`)가 디스크에서 다시 읽는다. 생성 파일 해시를 엔진과 편집기가 각각 계산해 대조. 이미지 해시를 문서 기록과 대조 | PASS |
| FIX-14 | texture filter를 넘기기만 하고 비교하지 않았다 | — | profile과 실제 sprite 양쪽에서 비교. inherit(0)은 그 자체의 값으로 비교 | PASS |
| FIX-15 | 화면에 그려진 결과는 미검사였다 | staging이 headless였다 | `render_check.tscn` + `check_godot_render.py`: 실제 렌더러로 그려 미리보기와 비교 | PASS (§9) |
| FIX-16 | `gui/animation.py` 한 파일에 캔버스·cache·재생·workspace | — | `gui/preview_canvas.py`, `gui/frame_cache.py`, `application/playback.py`로 분리 | PASS |
| FIX-17 | 참조 편집 규칙이 편집 함수마다 따로 | — | `application/references.py` 하나 | PASS |
| FIX-18 | staging 결과가 언제까지 유효한지 표시가 없었다 | — | 결과에 문서·프로젝트 fingerprint. 편집·다른 문서·프로젝트 변경 시 "오래됨". 검사 영역을 나눠 표시 | PASS |
| FIX-19 | crash 재시도 기록이 횟수뿐이었다 | — | functional 결과와 process 결과를 분리(종료 코드, 첫 crash 로그). stage는 이전 시도의 출력을 지우고 다시 쓴다. 취소·제한 시간에 프로세스 트리를 끝낸다 | PASS |

엔진의 종료 crash(`0xC0000005`) 자체는 고치지 않았다([known_issues.md](known_issues.md)).

## 3. 참조 무결성 계약 (`application/references.py`)

Schema V1에는 두 종류의 참조가 있다.

**ID 참조.** `Id(ref=kind)`로 선언된 필드(또는 그런 key의 map)가 이미지·Clip·Hitbox·공격 패턴·상태를 이름으로
가리킨다. `references.incoming(document, kind, id)`가 schema 순회로 전부 찾는다 — 나중에 레지스트리에 모듈이나
이벤트가 추가돼도 이 코드는 바뀌지 않는다.

**frame 번호.** "Clip C의 N번째 frame"을 뜻하는 숫자. 정확히 둘이다.

| 필드 | 어느 Clip의 번호인가 |
|---|---|
| `collision.hurtbox_overrides[].frame` | 그 override의 `clip` |
| `presentation.attack_hit_frame` | `presentation.roles.attack`에 연결된 Clip (그 Clip에 그 번호의 frame이 실제로 있을 때만) |

공격 패턴의 이벤트는 **초 단위**다. frame 번호가 아니며 frame 순서를 바꿔도 건드리지 않는다.

| 편집 | 규칙 |
|---|---|
| frame 이동 | `move_mapping` (예: 4 frame에서 1→3이면 `{0:0, 1:3, 2:1, 3:2}`)으로 두 필드를 같이 옮긴다 |
| frame 삽입·복제 | 그 위치 이후 번호 +1. 복제본은 전용 Hurtbox 세트 없이 시작한다 |
| frame 삭제 | 뒤 번호 −1. 그 frame의 전용 세트는 확인 후 함께 삭제. **타격 frame이면** 어느 frame이 타격을 보여 줄지 사용자가 고른다(인접 frame으로 조용히 옮기지 않는다). Clip의 마지막 frame은 삭제하지 않는다 |
| Clip 삭제 | 역할 연결을 비우고 전용 세트를 지운다(확인 후). 공격 패턴·상태·이벤트가 참조하면 거절하거나 사용자가 고른 대체 Clip으로 재연결. 패턴이나 상태를 지우는 일은 없다 |
| Clip / Hitbox ID 변경 | core의 `rename_id`: 참조하는 필드가 전부 함께 바뀐다 |
| Hitbox 삭제 | 이벤트가 참조하면 거절하거나 대체 Hitbox로 재연결 |
| Hurtbox 삭제·ID 변경 | 참조하는 곳이 없다. override는 기본 세트의 "보기"가 아니라 세트 전체의 독립된 복사본이므로(`boxes`가 세트를 대체) 기본 Hurtbox를 고쳐도 override는 그대로다 |
| 이미지 삭제 | frame이 쓰고 있으면 거절하거나 크기가 맞는 다른 이미지로 재연결. frame을 지우지 않는다 |
| 이미지 갱신 | 새 크기에 rect가 들어가지 않는 frame이 있으면 거절. rect를 줄여 맞추지 않는다 |

모든 함수는 edit 목록을 돌려줄 뿐 적용하지 않는다. 한 동작의 edit을 `DocumentSession.apply`에 함께 넘기므로
원자적이고 Undo 한 단계다. 중간 상태의 문서는 존재하지 않는다.

frame의 동일성은 **위치**로 추적한다. 같은 이미지·같은 rect의 frame이 여러 개 있을 수 있으므로 그림으로 구별하지
않는다(테스트는 frame마다 다른 `duration`을 꼬리표로 쓴다).

**세션 규칙** (`DocumentSession.apply`). S2에서 "edit 하나하나의 경로"가 아니라 **적용한 결과**를 보도록 바꿨다(§15).

- 편집 가능하지 않은 구역은 edit 묶음을 적용한 뒤에도 그대로여야 한다. 예외는 하나다: 새 초안에서 편집기가
  아직 없을 뿐인 구역(`attack_patterns`, `behavior`)의, 편집 가능한 대상(Clip·이미지·Hitbox)을 가리키는
  `Id(ref=…)` 필드가 **존재하는 다른 대상**을 가리키게 되는 것. 비우거나 없는 ID를 넣는 것은 "따라가기"가 아니다.
- 가져온 문서가 `read_only`로 묶은 구역은 그 예외도 없다. binding이 언급하지 않은 구역도 `read_only`다
  (이전에는 `editable`로 취급했다).
- ID 변경(`rename_id`)은 경로가 없는 edit이고 그 이름을 쓰는 필드를 전부 고쳐 쓴다. 결과를 보므로, 읽기 전용
  구역의 필드를 하나라도 고치게 되는 rename은 통째로 거절된다.
- 어떤 edit도 편집할 수 없는 구역의 참조를 끊어 놓을 수 없다(가리키던 대상을 지우거나 다른 이름으로 바꿔서).
  사용자가 그 구역에서 고칠 방법이 없기 때문이다.

frame 고유 ID는 도입하지 않았다. V1의 번호 참조는 위 규칙으로 일관되게 유지된다. frame 단위 이벤트가 생기는
시점에는 번호 대신 ID가 필요해질 수 있다(§13).

## 4. Preview · 드래그 · 재생 계약

**좌표** (`gui/preview_canvas.py`, 식은 전부 `rtcmonster.geometry`).

```text
frame 픽셀 --sprite_to_actor(frame 크기, visual_offset, visual_scale, 기본 방향, facing)--> actor 좌표
actor 좌표 --(× zoom, + 위젯 중심, + pan)--> 화면 픽셀
```

- 도형은 actor 좌표, **오른쪽을 보는 상태로** 저장한다. 왼쪽 미리보기에서는 `mirror_shape`로 그리고 드래그한 점은
  `mirror_point`로 되돌린 뒤 쓴다. 저장되는 값은 미리보기 방향과 무관하다.
- zoom과 pan은 화면 상태일 뿐 도형에 닿지 않는다. `visual_scale`은 그림만 키우고 도형은 그대로다.
- Bottom-center 맞춤은 Clip의 **첫 frame** 크기 기준이다. V1에는 frame별 기준점이 없다. frame 크기가 섞인 Clip에
  적용하면 편집기가 그 사실을 알린다(검증의 `mixed_frame_sizes` 경고도 그대로 있다).
- 쓸 수 없는 값(NaN, Infinity, 0 이하의 크기, 빠진 필드)의 도형은 그리지도 집지도 않는다. 검증이 보고할 일이다.

**드래그.** 누를 때 `DragSession`(context = 문서 세션·Clip·frame, 도형, facing, 원래 값)이 만들어진다. 놓을 때까지
문서는 바뀌지 않고, 놓는 순간 편집 1회가 요청된다. 다음 중 하나라도 일어나면 드래그는 취소되고 아무것도 적용되지
않는다: Esc, 다른 문서·문서 닫기, 프로젝트 변경, Clip·frame 변경, 좌우 반전, 재생 시작, Undo/Redo로 그 도형이
바뀜, 도형 삭제, 목록에서 다른 도형 선택, 다른 마우스 버튼, 포커스 상실, 마우스 capture 상실, workspace 전환.
문서가 편집을 거절하면 도형은 원래 자리에 그려지고 선택은 유지된다.

**재생** (`application/playback.py`, Qt 없음).

| 상태 | 뜻 |
|---|---|
| 정지 | 시간 0 |
| 재생 | `advance(초)`가 시간을 진행 |
| 일시정지 | 시간 유지 |

재생 버튼은 일시정지 지점에서 이어서 재생한다. 끝난 one-shot Clip이나 정지 상태에서는 처음부터다. "처음으로"는
별도 버튼이다. one-shot Clip은 마지막 frame에서 스스로 일시정지한다. 초 = `duration / fps`
(`rtcmonster.timing`, 게임의 `EnemyAnimationProfile`과 같은 식). 한 번의 `advance`는 1초를 넘지 않는다.

재생 중에는 frame이 저절로 바뀌므로 판정을 편집할 수 없다(캔버스 읽기 전용, 숫자 입력 비활성). 일시정지하면 그
frame을 편집한다.

이것은 **미리보기 시계**다. 공격이 언제 맞는지는 physics tick(`timing.tick_of`)이 정하고 Clip과 무관하다.

## 5. Frame cache (`gui/frame_cache.py`)

| 제한 | 값 |
|---|---|
| **cache 전체** = frame + 보관 중인 시트 (`total_bytes`) | **160 MiB** (`DEFAULT_BUDGET`) |
| 그중 시트 한 장 | 64 MiB 이하일 때만 보관 (`SHEET_LIMIT`). 시트와 그 frame 하나가 예산에 함께 들어가지 않으면 보관하지 않는다 |
| frame | 시트를 뺀 나머지. 64 MiB 시트를 보관 중이면 96 MiB (`FRAME_BUDGET`), 시트가 없으면 160 MiB 전부 |
| 항목 수 | 512 |
| 한 frame | 예산의 절반 이하. 넘으면 그리되 보관하지 않는다 |

STEP 3 안정화 1차에서는 시트가 frame 예산(96 MiB) **밖에** 따로 있어서 "예산 96 MiB"라고 적어 놓고 실제로는
160 MiB까지 들고 있었다. S2에서 예산을 하나로 합쳤다: `max_bytes`가 곧 cache가 드는 전부이고
`bytes + sheet_bytes <= max_bytes`가 항상 성립한다. 넘치면 오래된 frame부터, 마지막에 시트를 버린다.

LRU다. key는 (프로젝트, 경로, 파일 내용 해시, rect)이므로 다른 프로젝트·바뀐 파일·다른 rect가 같은 frame을 돌려줄
수 없다. 실패한 디코딩은 기억하지 않는다. 프로젝트를 떠나면 그 프로젝트의 frame을, 이미지 갱신 시 그 파일의
frame을 버린다. 편집할 때마다 전체를 비우지 않는다.

파일 변경 감지는 크기와 수정 시각이다(빠르지만 둘 다 그대로인 채 내용만 바뀐 파일은 못 본다). "크기·해시 갱신"은
그 기억을 지우고 파일을 실제로 다시 읽는다.

**시트 재디코딩.** PNG는 중간부터 읽을 수 없어서 frame 하나를 잘라내려면 파일 전체를 디코딩한다. 측정해 보니
4096×4096 시트에서 frame당 157 ms였다. 마지막 시트 한 장을 보관하고 거기서 잘라내도록 바꿔 약 1 ms가 됐다(아래 표).

**실측** (`check_frame_cache.py`, Windows 11, 이 PC, 1회 실행. cache 추정치와 프로세스 working set은 다른 양이다):

| frame | 요청한 frame 수 (픽셀 합계) | cache 최대 | 보관된 frame | 밀려난 frame | 시트 디코딩 | working set: 시작 → 최대 → 비운 뒤 | 디코딩 / frame | cache hit / frame |
|---|---|---|---|---|---|---|---|---|
| 256px | 512 (128 MiB) | 96 MiB | 384 | 128 | 2회 | 46 → 207 → 46 MiB | 0.92 ms | 0.022 ms |
| 512px | 128 (128 MiB) | 96 MiB | 96 | 32 | 2회 | 46 → 207 → 46 MiB | 3.77 ms | 0.024 ms |
| 1024px | 32 (128 MiB) | 96 MiB | 24 | 8 | 2회 | 46 → 207 → 46 MiB | 14.64 ms | 0.033 ms |

32 frame Clip 400회 재생: frame당 0.0225 ms, 디코딩 32회, working set 증가 0 KiB.

cache 추정치(frame + 시트)는 예산 160 MiB를 넘지 않았다. working set의 증가분은 그와 같은 수준이다(약 161 MiB).
cache를 비우면 시작 수준으로 돌아왔다(누수 없음). 32 frame Clip을 400번 다시 재생해도 디코딩은 32번, working set
증가는 0 KiB였다.

## 6. Staging 계약 (`bridge/staging.py`)

```text
요청 검사 → StagingSession 생성(조사 → 복사 → 표식) → import → stage_monster
  → 응답 검사 → read_stage(새 프로세스) → 재읽기 검사 → 비교 → 결과 → 사본 삭제
```

**복사.** 복사 전에 대상 전체를 조사한다(`survey`). 심볼릭 링크, Windows junction, 그 밖의 reparse point, 일반 파일이
아닌 것이 하나라도 있으면 `STAGING_UNSAFE_SOURCE`로 시작하지 않는다 — 따라가면 프로젝트 밖을 복사할 수 있고, 조용히
빼면 게임에 필요한 리소스가 빠질 수 있기 때문이다. 복사하지 않는 최상위 폴더(`.git`, `.github`, `.claude`,
`.vscode`, `.idea`, `build`, `docs`, `devtools`, `artifacts`)와 `__pycache__`·`*.pyc`·`*.tmp`는 들여다보지 않는다.
`.godot`(import cache)은 복사한다. 파일 20만 개, 8 GiB, 여유 공간(필요량 + 256 MiB) 한도가 있고 넘으면
`STAGING_TOO_LARGE`다. 파일마다 취소를 확인하며 취소하면 부분 사본을 지운다.

복사는 파일 시스템 snapshot이 아니다. 복사 직후 원본의 크기·수정 시각이 조사 때와 다르면 `changed_during_copy`에
기록하고 결과의 `staging` 영역을 `WARNING`으로 표시한다.

**소유권.** 사본은 `StagingSession` 하나가 만들고 쓰고 지운다. 표식(`.rtc_monster_staging`)은 JSON이며 세션 ID,
원본 경로, 생성 시각, PID를 담는다. 삭제(`session.remove()`) 전에 확인하는 것:

- 폴더 이름이 `rtc-monster-stage-*`이고 그 안의 `project`가 세션이 만든 경로다.
- 폴더와 `project`가 링크·junction이 아니고, 만든 경로 그대로 resolve된다.
- 실제 프로젝트를 포함하지도, 그 안에 있지도 않다.
- 표식을 읽을 수 있고 세션 ID가 같다.

하나라도 아니면 `STAGING_NOT_OWNED`이고 아무것도 지우지 않는다. `remove_staging_copy(path)`는 이 프로세스가 만든
사본에만 동작한다 — 표식을 복사해 넣은 폴더는 지워지지 않는다.

S2에서 더한 것(§15): 폴더의 **identity**(device, inode)를 만들 때 기록해 두고 삭제 전에 대조한다 — 같은 이름의
다른 폴더는 표식이 있어도 지우지 않는다. 표식의 사본(`.rtc_monster_staging_owner`)을 사본 **옆**에 하나 더 둔다.
삭제는 사본의 내용 → 표식 → 사본 폴더 → 옆의 token → 작업 폴더 순서로 하므로, 어디서 멈추든 소유를 증명하는
파일이 마지막까지 남는다. 표식이 이미 없는 폴더는 **이 세션이 삭제를 시작했던 것**(`leftover`)일 때만, token이나
identity로 확인한 뒤 다시 지운다.

**삭제 실패.** Windows의 파일 잠금에 대비해 0.25초 간격으로 4번까지 시도한다. 그래도 남으면
`STAGING_CLEANUP_FAILED`(경로, 첫 실패 항목, 원인, "실제 프로젝트에는 영향 없음")이고 세션은 `leftovers()`에 남아
다시 `remove()`할 수 있다. 검증 자체는 성공했는데 삭제만 실패하면 결과를 돌려주고 `StageResult.cleanup_error`에
적는다. 편집기는 그 경로를 사용자에게 보여 준다.

**수명.** `stage_presentation`은 돌아가기 전에 사본을 지운다 — 성공, `BridgeError`, 잘못된 응답, 예상 못 한
예외(`KeyError`·`TypeError`·`ValueError`·`OSError`), 취소 전부. `keep=True`면 호출자가 `result.session`을 소유하고
직접 지운다. `keep_on_failure=True`는 실패한 사본을 조사용으로 남기고 경로를 오류에 적는다. 취소는 남기지 않는다.

**이전 실행이 남긴 폴더.** 프로그램이 죽어 남은 사본은 `find_stale_copies()`가 표식 내용과 함께 나열할 뿐이다.
자동으로 지우지 않는다 — 실행 중인 다른 편집기의 것일 수 있다. 표식의 세션·시각·PID를 보고 손으로 지운다.

**응답 검사.** `sprite_frames_path`·`profile_path`는 `res://monster_stage/<monster_id>/` 아래의 `.tres`여야 하고,
OS 경로, `..`, 다른 확장자, 다른 폴더, 링크를 거쳐 사본 밖으로 나가는 경로는 `RESOURCE_PATH_INVALID`다. profile
재읽기의 모든 필드 타입을 확인한 뒤에야 비교에 넘긴다. 응답의 몬스터 ID와 staging 세션이 요청과 달라도 거절한다.

**비교.** 기존 항목(Clip·fps·loop·frame 수·텍스처 경로·region·duration·역할·scale·offset·facing·hit frame·속도)에
더해:

- texture filter: profile과 carrier의 실제 sprite에서 각각.
- 디스크 재읽기: 두 번째 프로세스의 재읽기가 만든 프로세스의 보고와 같은가.
- 생성 파일 해시: 엔진(`FileAccess.get_sha256`)과 편집기(`hashlib`)가 같은 값을 내는가.
- 이미지: 사본의 PNG가 문서가 기록한 해시의 그 파일인가. rect가 여전히 맞더라도 내용이 다르면 차이다("편집기에서
  이미지를 갱신하라"). 해시가 기록되지 않은 이미지는 비교할 수 없다고 적는다.

**결과** (`StageResult`).

| 필드 | 내용 |
|---|---|
| `differences`, `passed` | 구조 비교. `passed`는 렌더링·전투·네트워크·게시에 대해 아무것도 말하지 않는다 |
| `areas` | `staging` `resources` `readback` `images` `attach` — 검사함. `rendering` `combat_runtime` `network` `publish` — 항상 `NOT_EVALUATED` |
| `document_fingerprint`, `project_fingerprint` | 결과가 어떤 문서와 어떤 프로젝트 파일에 대한 것인가. `is_current(document)` |
| `dependencies` | stage가 의존한 **모든** 프로젝트 파일의 manifest: 경로 → sha256·크기·수정 시각 (S2, §15) |
| `resources` | 생성된 두 파일의 SHA-256 |
| `process` | 호출별 시도 횟수와 crash한 시도의 종료 코드 |
| `notes`, `cleanup_error`, `godot_version`, `session` | |

편집기는 결과를 문서 fingerprint와 프로젝트 generation, 그리고 의존 파일 manifest에 묶어 둔다. 편집, 다른 문서,
프로젝트 설정 변경, **의존 파일의 변경** 뒤에는 "Staging: 오래됨"으로 표시하고, 통과한 결과도 "구조 일치 (실제
렌더링·전투는 미검사)"라고 적는다.

## 7. Godot 쪽 검증 (`monster_stager.gd`)

- 표식이 있고 **요청의 `staging_session`이 표식의 세션과 같을 때만** 동작한다(`NOT_A_STAGING_PROJECT`,
  `STAGING_NOT_OWNED`). `read_stage`와 render check도 같은 검사를 쓴다.
- 모든 요청 값을 검사한다: ID 형식, 이미지 경로(`..`, `:`, `\`, `//`, 절대 경로, PNG 아님), 이미지·Clip·frame 수,
  fps (0, 120], duration (0, 100], loop가 bool, rect가 **정수 픽셀**이고 이미지 안, 역할이 staged Clip을 가리킴,
  scale > 0, hit frame이 [0, 64]의 정수, 속도가 0 이상, texture filter가 enum 범위. 틀리면 `INVALID_REQUEST`이고
  script error가 나지 않는다. 실제 엔진으로 13가지 잘못된 요청을 보내 확인한다(`check_godot_stage.py`).
- profile에 관한 검사를 **첫 파일을 쓰기 전에** 끝낸다.
- 출력 폴더의 이전 파일을 지우고 다시 쓴다. crash한 시도가 남긴 반쪽 파일이 다음 시도의 결과로 읽히지 않는다.

## 8. 프로세스 결과와 crash 정책

- `BridgeResponse.attempts`, `.crashes`(버린 시도의 종료 코드), `.crash_log`(첫 crash의 엔진 로그),
  `.process_result`(`CLEAN` / `CRASHED_THEN_RETRIED`). crash는 성공에 섞이지 않는다.
- 종료 코드만으로 "알려진 엔진 crash"라고 단정하지 않는다. 로그를 남겨 확인할 수 있게 한다.
- 재시도는 읽기 명령과, 버려도 되는 사본 안의 자기 출력만 다시 쓰는 `stage_monster`·import·렌더 검사에만 한다.
  실제 프로젝트에 쓰는 작업은 재시도하지 않는다(그런 작업은 아직 없다).
- S2: crash를 둘로 나눈다. **성공 줄을 출력한 뒤** 죽었고 로그에 실패 표시가 없으면 `exit_after_success`
  (알려진 엔진 종료 crash의 모양) — 전체 3회까지 다시 한다. 그 밖은 `during_work`(작업 도중, 원인 불명) — **한 번만**
  더 한다. crash한 실행에 쓴 시간이 600초를 넘거나 취소되면 새로 시작하지 않는다. 시도마다 단계·횟수·종료 코드·
  분류·소요 시간·로그 끝부분이 기록되고, 성공한 결과에도 실패한 오류에도 붙어 있다(§15).
- 취소·제한 시간에는 시작한 프로세스의 **트리**를 끝낸다(Windows `taskkill /T`, POSIX 프로세스 그룹). 자식이 남아
  작업 폴더를 잡고 있으면 사본을 지울 수 없기 때문이다. 대상은 편집기가 시작한 PID에서 찾으며 이름으로 찾지 않는다.

## 9. 실제 렌더링 검증 (`check_godot_render.py`)

staging 사본에서 `render_check.tscn`을 **창과 렌더러가 있는 상태로** 실행한다. 등록된 Enemy actor(carrier)에 staged
profile을 붙여, 실제 `EnemyAnimationPresenter`가 만든 sprite를 320×240 viewport(단위당 3 픽셀)에 그리고 PNG로
저장한다. 같은 frame을 편집기의 `PreviewCanvas`로 같은 크기·배율에 그려 비교한다.

| 비교 | 방법 |
|---|---|
| 위치·크기·반전 | scene tree가 말하는 frame 네 모서리 vs `geometry.sprite_to_actor` (허용 오차 0.01 px) |
| 픽셀 | 두 이미지의 bounding box, 한쪽에만 그려진 픽셀 수, 양쪽 모두 불투명한 픽셀의 색 차이 |
| frame region | sprite가 실제로 쓴 텍스처·region vs 문서의 이미지·rect |
| texture filter | profile과 sprite |
| 역할 | 상태를 강제했을 때 실제 presenter가 고른 Clip (idle, move, attack, hurt, death, jump, fall) |
| frame duration·loop | `AnimatedSprite2D`를 실제로 재생하며 매 frame 기록한 (경과 시간, frame) vs `timing.frame_at`. 검사의 시계와 sprite의 시계는 같은 간격으로 가지만 한 frame 안에서 갱신 순서가 다를 수 있어, 표본마다 앞뒤 한 frame 간격을 허용한다 |

이 PC에서 두 렌더러로 실행했다: **forward_plus / d3d12** 와 **gl_compatibility / opengl3** (NVIDIA GeForce RTX 3070 Laptop GPU). 결과는 두 렌더러에서 같았다.

| 몬스터 | carrier | scale · offset | filter | 스크린샷 | 미리보기와 픽셀 동일 | 위치 오차 | 한쪽에만 그려진 면적 | 위치·역할·필터·재생 시간 |
|---|---|---|---|---|---|---|---|---|
| Sewer Beetle | `sewer_beetle` | [1, 1] · [0, -13] | 1 | 20 | 20 | 0 px | 0.0% | 일치 |
| Frog | `frog` | [1, 1] · [4, -19] | 1 | 32 | 32 | 0 px | 0.0% | 일치 |
| 새 초안 | `sewer_beetle` | [1.5, 1.5] · [0, -16.67] | 1 | 20 | 6 | 1 px | 2.8% | 일치 |

개구리에서 실제 presenter가 고른 Clip: attack → `attack`, death → `death`, fall → `fall`, hurt → `hurt`, idle → `idle`, jump → `jump`, move → `idle`. 재생 시간은 Clip마다 한 번 실제로 재생해 매 frame 기록했다(딱정벌레 idle 84표본).

nearest 필터와 정수 배율에서는 미리보기와 **픽셀까지 같다**. 새 초안은 일부러 `visual_scale` 1.5(× 3 = 4.5, 정수가
아님)로 만들었다: 가장자리 픽셀이 렌더러마다 다르게 반올림되므로 위치(±1 px)와 덮인 면적(6% 이내)만 판정하고 색
차이는 기록만 한다.

증거: [monster_editor_step3_screens/](monster_editor_step3_screens/) — 각 장은 왼쪽부터 편집기 미리보기, Godot
렌더러, 미리보기 + 문서의 도형, Godot + 문서의 도형이다.

![개구리 attack frame 3, 왼쪽](monster_editor_step3_screens/frog_attack_f3_left_compare.png)

**한계.**

- 도형 overlay는 이 검사가 **문서에서** 그린 것이다. 게임은 문서의 Hitbox와 frame별 Hurtbox 세트를 쓰지 않는다
  (STEP 4). overlay가 보인다고 판정이 구현된 것이 아니다.
- `jump_start`·`land`는 presenter 내부 타이머로만 나타나므로 강제하지 않았다(개구리에서 "강제하지 않음"으로 기록).
- 렌더러가 없는 환경은 `NOT_EVALUATED`다. headless 검사로 대체하지 않는다.
- carrier는 몬스터마다 자기 actor를 썼다(딱정벌레·개구리). 새 초안은 딱정벌레 actor가 carrier다 — 데이터 기반
  actor는 아직 없다.

## 10. GUI 책임 분리

| 파일 | 책임 | Qt |
|---|---|---|
| `application/references.py` | 참조 조회, 영향, 재연결, ID 변경, frame 번호 재지정 | 없음 |
| `application/animation.py` | 동작 하나 → edit 목록 | 없음 |
| `application/playback.py` | 재생 상태와 시간 조회 | 없음 |
| `gui/frame_cache.py` | 디코딩과 메모리 | 있음 |
| `gui/preview_canvas.py` | 그리기, 좌표, 도형 선택·드래그. 문서·세션·파일을 모른다 | 있음 |
| `gui/animation.py` | workspace: 목록, 버튼, 확인 대화, 선택 | 있음 |
| `gui/render_compare.py` | 미리보기 이미지와 스크린샷 비교 | 있음 |
| `bridge/staging.py`, `bridge/rendering.py` | staging 세션, 렌더 검사 실행과 기대값 | 없음 |

Animation과 Collision은 한 캔버스에서 같은 선택(Clip, frame, 도형)을 쓰므로 workspace를 둘로 나누지 않았다.

## 11. 성능

같은 PC, 네이티브 Windows, 1회 실행(`main.py --smoke-report`).

| 동작 | 100% | 150% | 200% |
|---|---|---|---|
| workspace로 전환 | 36.42 ms | 39.56 ms | 43.08 ms |
| frame 선택 | 8.5 ms | 8.42 ms | 8.66 ms |
| frame 이동 (세트·타격 frame 포함, 편집 1회) | 21.0 ms | 37.19 ms | 38.8 ms |
| 그 이동의 Undo | 10.41 ms | 12.68 ms | 12.99 ms |
| 드래그 중 마우스 이동 20회 (문서 변경 없음) | 7.64 ms | 7.99 ms | 8.12 ms |
| 드래그 확정 (편집 1회) | 13.52 ms | 14.64 ms | 15.32 ms |

| 문서 규모 | 표시 | 편집 1회 | Undo | 검증 + 목록 |
|---|---|---|---|---|
| Small | 47.64 ms | 23.71 ms | 14.84 ms | 15.92 ms |
| Medium | 81.37 ms | 47.03 ms | 15.49 ms | 32.3 ms |
| Large | 142.34 ms | 95.76 ms | 20.0 ms | 69.54 ms |

Large 문서의 편집 1회는 STEP 2에서 91~97 ms, STEP 3에서 89.9 ms였고 이번 측정은 95.76 ms다(같은 PC, 다른 날, 다른 세션의 Godot이 함께 돌고 있었다). 참조 재지정이 붙은 frame 이동도 작은 문서에서 편집 1회와 같은 수준이다.

드래그 중에는 문서를 건드리지 않는다(이동 20회에 약 8 ms). 편집 비용의 대부분은 여전히 core의 정규화와
fingerprint이고(STEP 3에서 분석한 그대로) 이번에 바꾸지 않았다.

## 12. 검증 기록

Windows 11, Python 3.14.5, PySide6-Essentials 6.11.3, Godot 4.7.2-stable. 코드 커밋 `9e83ad0`에서 실행했다(그 뒤의
커밋은 문서와 증거 파일뿐이다). Godot을 쓰는 검사는 순차로 돌렸다.

| 검사 | 실제 Godot | 실제 GUI | 실제 렌더러 | 결과 |
|---|---|---|---|---|
| `pytest tools/python_monster_editor/tests` (네이티브) | — | Qt 위젯 + `QTest` 입력 | — | 911 통과, 8 건너뜀 |
| 같은 명령, `QT_QPA_PLATFORM=offscreen` | — | offscreen | — | 909 통과, 10 건너뜀 |
| `pytest tools/python_map_editor/tests` | — | — | — | 184 통과, 3 건너뜀 |
| `tools/check_project.py` | 예 | — | — | `ALL PROJECT CHECKS PASS` |
| `check_godot_contract.py` | 예 | — | — | 205 통과, 3 미검사 (environment·registry·legacy PASS) |
| `check_contract_extensibility.py` | 예 | — | — | PASS |
| `check_godot_import.py` | 예 | — | — | 45 통과 |
| `check_godot_stage.py` | 예 | — | — | PASS, 실패 0 (2회 연속). 프로젝트 파일 1094개의 해시가 전후 같음 |
| `check_godot_render.py` (forward_plus / d3d12) | 예 | 미리보기 캔버스 | **예** | PASS (2회 연속) |
| `check_godot_render.py --rendering-method gl_compatibility` | 예 | 미리보기 캔버스 | **예** (opengl3) | PASS |
| `check_frame_cache.py` | — | Qt 디코딩 | — | PASS |
| GUI 스모크 100% / 150% / 200% (`main.py --smoke-report`, 실제 Godot) | 예 | **네이티브 창, 실제 입력** | — | 각 49 통과 |
| `test_multiplayer_restart.py` 2인 valid·invalid, 3인 valid | 예 | — | — | 통과 |
| `test_multiplayer_worlds.py` / `world_runtime.py` / `forest.py` 2·3인 | 예 | — | — | 통과 |
| Map Editor `check_scene_bridge.py`, `check_enemy_spawn_bridge.py` | 예 | — | — | 통과 (V6 round trip 2/2, data safety PASS) |

건너뛴 8건: 심볼릭 링크를 만들 권한이 없는 Windows 계정에서의 링크 테스트(Linux CI에서 실행된다). Windows junction은
권한이 필요 없어 실제로 만들어 검사했다. offscreen에서는 창 단위 단축키 2건이 더 빠진다.

**회귀 중 드러난 것.**

- 첫 전체 실행에서 Godot의 종료 crash(`0xC0000005`)가 세 군데서 났다: staging 사본의 `--import`, 거절을 기대한 Bridge
  호출 하나(3회 연속), 렌더 검사 한 번. 앞의 둘은 재시도가 없는 경로였고 세 번째는 재시도 3회를 다 썼다. 같은 PC에서
  다른 세션의 Godot이 계속 돌고 있었다. import와 렌더 실행을 crash 재시도 대상에 넣고(둘 다 버려도 되는 사본에서
  처음부터 다시 하는 작업이다), 검사 스크립트는 "거절되는가"라는 질문을 crash로 답을 못 얻었을 때 다시 묻도록 했다.
  그 뒤 staging 2회·렌더 3회가 모두 통과했고 기록된 crash는 0건이었다. crash 원인 자체는 여전히 엔진 쪽이다.
- 렌더 씬이 viewport를 트리에 넣기 전에 `canvas_transform`을 지정해 엔진이 `ERROR:` 한 줄을 냈다(결과는 맞았다).
  순서를 고쳤고, 렌더 검사는 이제 자기 씬의 로그에 `ERROR:`가 있으면 실패한다.
- 취소된 staging의 사본이 지워지지 않는 경우를 테스트가 찾았다: 종료시킨 프로세스의 자식이 작업 폴더를 잡고 있었다.
  프로세스 트리를 끝내도록 고쳤다.
- frame cache 실측이 시트 재디코딩(frame당 157 ms)을 찾았다(§5).
- 참조 재연결이 세션에서 거절됐다: 편집기가 없는 `attack_patterns` 구역의 필드였기 때문이다. 참조 필드만 통과시키는
  세션 규칙을 넣었다(§3). 같은 검토에서 `rename_id`가 편집 가능 검사를 건너뛰던 것도 막았다.

**CI** (GitHub Actions, 코드가 마지막으로 바뀐 커밋 `d30baab`).

| 워크플로 / job | 결과 |
|---|---|
| Python Monster Editor / `core` (Ubuntu, Windows) | 성공 |
| Python Monster Editor / `godot-contract` (Linux: 계약·확장성·Import·Staging) | 성공 |
| Python Monster Editor / `gui-windows` (스모크 3배율, Import, Staging, **렌더링**, 작업 트리 미변경) | 1차 실패 → 재실행 성공 |
| Python Map Editor (`43ea113`에서 실행; 이후 커밋은 그 경로를 건드리지 않아 다시 돌지 않았다) | 성공 |
| Godot validation / `headless` | 성공 |
| Godot validation / `windows-demo` | **실패** (아래) |

- `gui-windows` 1차 실패는 `check_godot_import.py`(STEP 2의 검사, 이 브랜치에서 고치지 않음)의 격리 프로젝트 단계에서
  Bridge 호출이 `0xC0000005`로 3회 연속 끝난 것이다. 같은 커밋을 다시 실행해 통과했다. 재시도 3회를 다 쓰는 경우가
  개발 PC에서 한 번, CI에서 한 번 있었다 — crash가 서로 독립이라는 가정(약 5% → 3연속 0.01%)은 맞지 않는다.
  원인은 밝히지 못했고 엔진 버전을 올릴 때 다시 본다([known_issues.md](known_issues.md)).
- **CI runner에서도 실제 렌더러가 돌았다**: forward_plus / d3d12 / Microsoft Basic Render Driver(소프트웨어). 딱정벌레
  20장·개구리 32장이 미리보기와 픽셀까지 같았다. 새 초안(scale 1.5)은 위치 오차 1 px, 한쪽에만 그려진 면적 5.1%로
  한도(6%) 안이었다 — 개발 PC의 GPU(2.8%)와 가장자리 반올림이 다르다.
- 그 과정에서 CI만의 문제 셋을 고쳤다: runner에 오디오 장치가 없어 엔진이 낸 `ERROR:` 줄(렌더 검사를
  `--audio-driver Dummy`로 실행), `docs/`에 넣은 증거 PNG를 Godot이 import해 생긴 `.png.import` 파일(폴더에
  `.gdignore`), 재생 시간 표본 하나가 frame 경계에서 한 frame 앞선 것(검사의 시계와 sprite의 시계의 위상 차이를
  양쪽으로 허용).
- `windows-demo`는 릴리스 EXE의 session lifecycle probe에서 역할 B의 `assert_motion`이 실패했다(`43ea113`, `d30baab`
  두 번 모두). master `8a24f91`에서는 같은 job이 성공했고 그 전 master 커밋들에서는 실패했다. 이 브랜치는 게임
  코드를 바꾸지 않았다(`tools/python_monster_editor/`, `tools/monster_bridge/`, 워크플로, 문서뿐). Runtime 안정화에서
  미해결로 남긴 "client 자신의 actor snapshot / run animation 관측" 문제와 같은 자리이며
  ([runtime_stabilization.md](runtime_stabilization.md)), 여기서 고치지 않았다.

**확인하지 않은 것.** 사람이 직접 조작한 검사(입력은 `QTest` 이벤트). OS 파일 대화상자. macOS. Linux에서의 창 단위
단축키. 실제 전투·네트워크·게시(해당 기능 없음). Windows 릴리스 빌드와 lifecycle probe는 이 브랜치에서 다시 돌리지
않았다 — 게임 코드를 바꾸지 않았고, 그 결과는 [runtime_stabilization.md](runtime_stabilization.md)의 것이다.

## 13. STEP 4 확장 가이드

공격 패턴 편집기가 그대로 쓰는 것:

| 필요 | 쓰는 것 |
|---|---|
| 같은 문서·같은 Undo | `MainWindow.apply_edits` → `DocumentSession.apply`. workspace는 `edits_requested(edits, label)`만 낸다 |
| "지워도 되나, 무엇이 깨지나" | `references.incoming` / `blocking` / `describe`, `animation.hitbox_usages`, `animation.clip_usages` |
| 재연결·ID 변경 | `references.retarget`, `references.rename`, `animation.remove_box(document, slot, replace_with=…)` |
| Hitbox 목록과 강조 | `animation.shape_slots(data, clip, frame)`, `AnimationWorkspace.highlight_box("hitbox", id)` |
| 미리보기 | `PreviewCanvas` (문서를 모른다: pixmap·frame 크기·presentation·도형을 넘긴다), `frame_cache.load_frame` |
| 타임라인 시간 → 미리보기 | `AnimationWorkspace.seek(초)` / `select_frame(n)`, `playback.time` / `frame` / `frame_window` / `duration` / `loop_count` |
| 선택 따라가기 | `AnimationWorkspace.selection_changed(clip, frame, slot)` |
| 현재 frame의 Hurtbox 세트 | `animation.effective_hurtboxes(data, clip, frame)` (frame 전용 → Clip 전용 → 기본) |
| staging·검증 | `StagingSession`, `stage_presentation(keep=True)`, `rendering.render_staged` |

두 시간축은 계속 따로다.

```text
Animation 시간     = 표현. playback.time, 초 = duration / fps
Attack Timeline 시간 = 서버 권위. timing.tick_of(초, tick_rate)
```

타임라인 화면은 둘을 나란히 보여 줄 수 있지만 Clip의 frame이 이벤트 시각을 정하지 않는다.

**Schema V2 후보** (이번에 도입하지 않았다. 호환성이 실제로 깨지는 시점에 migration과 함께):

| 후보 | 이유 |
|---|---|
| `presentation.texture_filter` | 지금은 가져온 문서의 passthrough에만 있다. 새 초안·복제본은 profile 기본값(nearest)이 된다 |
| frame 고유 ID | frame 단위 이벤트가 생기면 번호 재지정 대상이 늘어난다 |
| frame별 anchor | 크기가 다른 frame의 발 위치 |
| `hitboxes[].target_test`, `Hop.near_goal_*` | 개구리의 미지원 2건 (기존 결정) |

## 14. 하지 않은 것

공격 패턴 편집기, 타임라인 실행기, `DataEnemyDefinition` / `DataEnemyAgent`, 실제 피해 판정, frame별 Hurtbox의
런타임 적용, 프로토콜 변경, AI 그래프, 게시, EXE, Godot 엔진 수정·버전 변경, 게임 네트워크 코드 수정.

## 15. STEP 3-S2 — 1차 안정화 뒤에 남은 결함

1차 안정화(`cbf68ce`까지)의 코드를 다시 읽어 찾은 결함 여덟 가지를 고쳤다. 기능을 새로 만들지 않았고 Schema(V1),
Godot(4.7.2), 프로토콜(20), 세이브(v5), 게임 런타임은 그대로다. 각 결함은 **먼저 테스트로 재현하고**
(`tests/test_step3_s2.py`를 `cbf68ce`의 코드에 대해 실행: 16 실패, 10 오류, 4 통과 — 통과한 4개는 "이미 안전했던
것이 계속 안전한지" 보는 가드다) 그 다음에 고쳤다(30 통과).

| 항목 | 결함 | 수정 전 재현 | 수정 | 바뀐 파일 |
|---|---|---|---|---|
| FIX-20 | Clip·Hitbox의 ID 변경이, 가져온 문서가 `read_only`로 묶은 구역의 참조까지 고쳐 썼다. binding이 언급하지 않은 구역은 `editable`로 취급됐다. 참조 필드에는 아무 값이나(빈 값, 없는 ID) 넣을 수 있었다 | `DID NOT RAISE DocumentError` 5건 | 세션이 edit의 경로가 아니라 **적용 결과**를 원본과 비교한다(§3). 선언되지 않은 구역은 `read_only` | `application/session.py` |
| FIX-21 | stage 뒤에 이미지나 스크립트가 바뀌어도 "Staging: 구조 일치"가 유지됐다. 유효성은 문서와 프로젝트 설정 변경만 봤다 | `stage_state()`가 디스크를 보지 않음 | 결과의 의존 파일 manifest와 디스크를 비교한다: 편집마다 크기·시각, 새로고침(F5)에서 전체 내용 | `gui/main_window.py`, `bridge/staging.py` |
| FIX-22 | 삭제가 중간에 실패하면 표식이 먼저 지워져 있을 수 있었고, 그러면 재시도가 `STAGING_NOT_OWNED`로 영원히 거절됐다 | 잠긴 파일 하나로 실제 재현 | 삭제 순서를 정하고(소유 증명을 마지막에) 사본 옆에 token을 하나 더 둔다. 폴더 identity 대조 | `bridge/staging.py` |
| FIX-23 | `Path.resolve()`가 링크를 실제 경로로 바꾼 **뒤에** 링크인지 검사해서, 프로젝트 root가 junction이어도 통과했다 | `DID NOT RAISE BridgeError` | 받은 경로 그대로(`abspath`) 먼저 검사한다. 작업 폴더도 같다 | `bridge/staging.py` |
| FIX-24 | 조사와 복사 사이에 상위 폴더가 링크로 바뀌면 그 링크를 따라 프로젝트 밖의 파일을 복사했다(파일 자신만 검사했다) | 밖의 파일이 복사됨 | 파일마다 읽기 직전에 root부터 그 파일까지의 모든 폴더와 파일 자신을 다시 검사하고, 연 handle이 방금 본 그 파일인지 확인한 뒤 그 handle의 바이트를 복사한다 | `bridge/staging.py` |
| FIX-25 | fingerprint가 문서의 이미지와 `.godot-version`뿐이었다. stager·presenter·profile 스크립트나 carrier의 파일이 바뀌어도 같았다 | fingerprint 불변 | manifest: 이미지, `.godot-version`, `project.godot`, Bridge 4개 파일, profile·presenter 스크립트, 그리고 엔진이 알려 주는 carrier의 정의·scene·script | `bridge/staging.py`, `tools/monster_bridge/monster_stager.gd` |
| FIX-26 | crash 재시도가 "3회까지"뿐이었다. 작업 도중의 crash와 종료 crash를 구분하지 않았고 기록은 종료 코드 목록이 전부였다 | 분류·기록 API 없음 | 분류, 분류별 한도, 전체 시간 한도, 시도별 기록(§8) | `bridge/client.py`, `bridge/staging.py`, `bridge/rendering.py` |
| FIX-27 | frame cache "예산 96 MiB" 밖에 시트 64 MiB가 따로 있었다. STEP 2의 증거 이미지 폴더에는 Godot이 만든 `.import` 13개가 커밋돼 있었다 | 예산 98,404 B에 147,456 B 보유 | 예산을 하나로 합쳤다(§5). 증거 폴더에 `.gdignore`, `.import` 제거, 관리 규칙을 `docs/testing.md`에 | `gui/frame_cache.py`, `check_frame_cache.py`, `docs/monster_editor_step2_screens/` |

### FIX-20: 결과로 판정한다

edit 하나하나의 경로를 보는 검사로는 두 가지를 놓친다. rename은 경로가 없고 그 이름을 쓰는 필드를 전부 고친다.
여러 edit을 묶으면 하나씩은 허용돼도 합쳐서는 허용되지 않는 변화가 될 수 있다. 그래서 `document.apply(*edits)`로
새 문서를 만든 다음, history에 넣기 **전에** 원본과 비교한다(`_protected_change`).

- 편집 가능하지 않은 구역의 값 집합(경로까지)이 같아야 한다. 구조가 달라졌으면 거절.
- 값이 달라진 곳은 전부 "따라갈 수 있는 참조"여야 하고, 새 값은 새 문서에 **존재하는** 대상이어야 한다.
- Clip·이미지·Hitbox의 ID 집합이 달라졌으면, 편집 불가 구역의 참조 중 이전에는 유효했는데 이제 끊긴 것이 없어야 한다.

비교는 보호 구역이 실제로 달라졌거나 대상 ID 집합이 달라졌을 때만 문서를 순회한다(평소 편집에는 비용이 없다).
기존 흐름(대체 Clip을 고르는 삭제, 새 초안의 ID 변경)은 그대로 통과한다.

### FIX-21 · FIX-25: 의존 파일 manifest

`StageResult.dependencies` = `{경로: {sha256, size, mtime_ns}}`. sha256은 staging 사본에서, 크기·시각은 복사할 때 본
원본의 것이다. `project_fingerprint`는 이 manifest의 경로와 sha256을 묶은 해시다.

| 비교 | 언제 | 무엇을 | 한계 |
|---|---|---|---|
| 빠른 비교 `changed_dependencies(project, result)` | 편집할 때마다(`stage_state`) | 크기와 수정 시각 | 둘 다 그대로인 채 내용만 바뀐 파일은 못 본다. 내용은 같고 시각만 바뀐 파일은 "바뀜"으로 본다 |
| 전체 비교 `changed_dependencies(…, deep=True)` | 카탈로그 새로고침(F5) → `verify_stage()` | 모든 파일의 sha256 | 파일 수만큼 읽는다(보통 20개 안팎) |

전체 비교에서 내용이 같은 것으로 확인된 파일의 크기·시각이 빠른 비교의 새 기준이 된다. manifest에 없는 파일
(다른 몬스터의 리소스, 게임 코드 전반)의 변경은 결과를 오래된 것으로 만들지 않는다 — 그것까지 넣으면 어떤 편집에도
결과가 무효가 된다. presenter가 간접적으로 부르는 코드까지 추적하지는 않는다.

### FIX-22 ~ FIX-24: 그 사이에 일어나는 일

- **조사 → 복사.** 조사가 본 것을 믿지 않는다. 조사 뒤 새로 생긴 파일은 복사되지 않는다(문서화된 한계). 사라진 파일은
  `STAGE_FAILED`, 폴더나 파일이 다른 종류(링크, 폴더↔파일)로 바뀌었으면 `STAGING_UNSAFE_SOURCE`, 내용이 바뀐 파일은
  읽은 그대로 복사하고 `changed_during_copy`에 적는다. 읽는 도중 쓰인 파일도 거기 들어간다.
- **`O_NOFOLLOW`.** POSIX에서는 마지막 구성요소가 링크면 열기 자체가 실패한다. Windows에는 그 flag가 없어서, 열기
  직전의 `lstat`과 연 뒤의 `fstat`이 같은 파일(device, inode)인지로 확인한다. 상위 폴더가 검사와 열기 사이의 아주 짧은
  순간에 바뀌는 경우까지 막지는 못한다 — 그 창을 파일 하나의 검사 직후로 줄였을 뿐이다.
- **삭제.** §6 참조. 표식이 없는 폴더를 지우는 길은 "이 세션이 이미 삭제를 시작한 폴더"에만 열려 있고, 그때도 token
  이나 identity가 맞아야 한다. 표식이 없는데 삭제를 시작한 적도 없는 폴더, 같은 이름의 다른 폴더는 거절된다(테스트).

### FIX-26: 기록의 모양

```json
{"attempts": {"import": 1, "stage_monster": 2, "read_stage": 1},
 "result": "CRASHED_THEN_RETRIED",
 "crash_exit_codes": [3221225477],
 "crashes": [{"step": "stage_monster", "attempt": 1, "exit_code": 3221225477,
              "classification": "exit_after_success", "seconds": 1.74, "log_tail": "…"}]}
```

`StageResult.process`와 검사 스크립트의 보고서(`stage_report.json`, `render_report.json`)에 들어간다. 편집기는 로그
폴더가 설정돼 있으면 crash한 시도의 로그 끝부분을 파일로 남긴다. 엔진의 crash 자체는 고치지 않았다.

### 검증 (S2)

Windows 11, Python 3.14.5, PySide6-Essentials 6.11.3, Godot 4.7.2-stable. 코드 커밋 `468b75c`에서 실행했다(그 뒤는
문서뿐이다). Godot을 쓰는 검사는 순차로 돌렸다.

| 검사 | 결과 |
|---|---|
| `tests/test_step3_s2.py` — 수정 전(`cbf68ce`의 코드) | 16 실패, 10 오류, 4 통과 |
| `tests/test_step3_s2.py` — 수정 후 | 30 통과 |
| `pytest tools/python_monster_editor/tests` (네이티브 / offscreen) | 941 통과·8 건너뜀 / 939 통과·10 건너뜀 (1차 안정화: 911) |
| `pytest tools/python_map_editor/tests` | 184 통과, 3 건너뜀 |
| `check_godot_contract.py` / `check_contract_extensibility.py` | 205 통과·3 미검사 / PASS |
| `check_godot_stage.py` | PASS, 검사 72개. manifest가 이미지·도구 파일·carrier 파일 3개를 포함하고 실제 프로젝트와 빠른·전체 비교 모두 차이 없음 |
| `check_godot_render.py` (forward_plus / gl_compatibility) | PASS / PASS. 딱정벌레 20·개구리 32장 픽셀 동일 |
| `check_frame_cache.py` | PASS. frame + 시트 최대 160 MiB = 예산 |
| GUI 스모크 100% / 200% (실제 입력, 실제 Godot) | 각 49 통과 |
| ENet E2E 9종, Map Editor `check_scene_bridge.py` | 통과 |
| `tools/check_project.py` | 1차 **실패**, 재실행 2회 통과 (아래) |
| `check_godot_import.py` | 1차 **실패**, 재실행 2회 통과 (아래) |

**이번 회귀에서 본 엔진 crash.** 전부 `0xC0000005`이고 게임·편집기 코드의 실패 표시는 없었다.

| 어디서 | 모양 | 처리 |
|---|---|---|
| `check_godot_stage.py`의 `stage_monster` 1회, 렌더 검사 중 `stage_monster` 2회 | Bridge 호출 | 재시도 1회로 통과. 결과에 `CRASHED_THEN_RETRIED`와 시도 기록이 남았다 — 새 기록이 실제 crash를 잡은 첫 사례다 |
| `check_project.py`의 `tests/test_runner.tscn -- --restart-write` | `TEST PASS` 출력 **뒤** 종료 중 crash | 이 스크립트는 재시도가 없다(게임 쪽 도구, 이번에 고치지 않음). 다시 실행해 통과 |
| `check_godot_import.py`의 격리 사본 `--import` | import 도중 종료 | 이 스크립트의 그 단계는 재시도가 없다(STEP 2의 검사). 다시 실행해 통과 |

뒤의 둘은 이 브랜치가 바꾼 코드가 아니다. [known_issues.md](known_issues.md)의 기준으로 `check_project`의 것은 성공
marker 뒤의 crash이고, import 도중의 것은 marker가 없어 "unknown"으로 남는다. 같은 PC에서 다른 세션의 Godot이 계속
돌고 있었다.

CI 결과는 이 절 아래 "CI (S2)"에 푸시 뒤 적는다.


**CI (S2)** — GitHub Actions, 커밋 `1b19bb1`(코드는 `468b75c`와 같다).

| 워크플로 / job | 결과 |
|---|---|
| Python Monster Editor / `core` (Ubuntu) | 성공 — 945 통과, 4 건너뜀 |
| Python Monster Editor / `core` (Windows) | 성공 — 949 통과, 건너뜀 없음 (심볼릭 링크 테스트 포함) |
| Python Monster Editor / `godot-contract` (Linux: 계약·확장성·Import·Staging) | 성공 |
| Python Monster Editor / `gui-windows` (스모크 3배율, Import, Staging, 실제 렌더링, 작업 트리 미변경) | 성공, 첫 실행 |
| Godot validation / `headless` | 성공 |
| Godot validation / `windows-demo` | **실패** — `Disconnect menu input and session recovery E2E` 단계에서 릴리스 EXE 프로세스가 `3221225477`(`0xC0000005`)로 종료 |

`windows-demo`의 실패 지점은 실행마다 달랐다: `43ea113`·`d30baab`에서는 `Build release EXE and execute content and ENet
validation` 단계의 lifecycle probe(`assert_motion`), `1b19bb1`에서는 그 단계는 통과하고 다음 단계의 프로세스 crash다.
`cbf68ce`의 실행은 취소됐다. 어느 쪽도 Monster Editor의 코드를 실행하지 않으며, 이 브랜치는 게임 런타임·네트워크
코드를 바꾸지 않았다. master `8a24f91`에서는 같은 job이 한 번 성공했다. Runtime 안정화의 미해결 항목과 엔진 crash로
분류하고 여기서 고치지 않았다 — master 병합 판단에서는 "이 브랜치가 만든 실패가 아니지만, 통과한 적도 없다"로 읽어야 한다.

## 16. Final patch — 병합 전 마지막 세 가지

`0513b42`의 코드 검토에서 남은 세 항목만 고쳤다. 새 안정화 단계가 아니다. 각 항목은 먼저 테스트로 재현했다
(`tests/test_step3_final.py`를 `0513b42`의 코드에 대해 실행: 24 실패, 1 통과 — 통과한 하나는 가드) → 수정 후 25 통과.

| 항목 | 결함 | 수정 | 바뀐 파일 |
|---|---|---|---|
| 1. 필수 의존성 | `dependency_manifest()`가 없는 파일·읽을 수 없는 파일을 조용히 뺐다. stager 스크립트가 없어도 stage가 "통과"했고, 그 파일이 계속 없는 한 fingerprint도 같았다 | 필수 파일의 누락·읽기 실패·일반 파일 아님·잘못된 경로·링크 경유는 `STAGING_DEPENDENCY_INVALID`. manifest를 만들지 않으므로 결과도 없다. 선택 의존 파일(이미지의 `.png.import`)은 있으면 포함, 없으면 생략 — 경로 규칙은 똑같이 적용 | `bridge/staging.py` |
| 2. 결과 판정 | 복사 도중 원본이 바뀌면 `areas["staging"]`만 WARNING이 되고 `passed`와 편집기 표시는 그대로 "통과"였다 | `passed`의 뜻은 그대로(구조 일치). `verdicts`가 구조 / 복사 일관성 / 의존성 완전성 / 현재 파일과의 일치 / 프로세스 / cleanup을 따로 말하고, `confirmed`는 앞의 넷이 모두 PASS일 때만 참. 편집기는 `passed`이지만 `confirmed`가 아닌 결과를 "구조는 일치, 확정 아님"으로 표시 | `bridge/staging.py`, `gui/main_window.py`, `gui/strings.py` |
| 3. 생성 실패의 cleanup | 복사나 표식 쓰기가 실패하면 `shutil.rmtree(..., ignore_errors=True)`로 지웠다. 그 삭제가 실패해도 아무 말이 없었고 폴더를 기억하는 세션도 없었다 | 부분 사본도 소유 확인을 거쳐 순서대로 지운다. 실패하면 처음 실패의 원인, 삭제 실패의 원인, 폴더 경로, 세션 ID, 조치 방법을 오류에 담고 세션을 `leftovers()`에 남긴다. 소유를 확인할 수 없는 폴더는 지우지 않는다 | `bridge/staging.py` |

**기존 호출과의 호환.** `StageResult.passed`, `differences`, `areas`, `is_current`, `process`, `cleanup_error`는 그대로다.
`verdicts`·`confirmed`·`changed_since_copy`가 더해졌다. 편집기의 `stage_state()`는 기존 값(`none`·`passed`·`differs`·
`stale`)에 `unconfirmed`가 하나 늘었다. `dependency_manifest(root, paths, surveyed=None)` 호출은 그대로 동작하되 이제
누락을 숨기지 않는다 — 누락을 허용하려면 `optional=`로 넘긴다.

**"현재 파일과의 일치"를 어디서 보는가.** 두 곳이다. stage가 끝나는 순간 의존 파일의 내용을 실제 프로젝트와 한 번
대조해 결과에 적는다(`changed_since_copy`, `verdicts["current"]`) — Godot이 도는 수십 초 사이의 변경. 그 뒤의 변경은
결과가 아니라 편집기가 본다(§15의 "오래됨").

**한계.** 선택 의존 파일은 이미지의 import 설정뿐이다. `.png.import`가 없는 프로젝트(아직 import하지 않은)에서의
stage는 사본 안에서 Godot이 만든 설정으로 돌았을 것이고, 그 설정은 manifest에 없다. 복사가 한 시점의 상태가 아니었을
때(`copy` WARNING)는 무엇이 바뀌었는지(`changed_during_copy`)를 알려 줄 뿐 다시 복사하지 않는다 — 다시 실행하는 것이
사용자의 다음 행동이다.

### 검증 (Final patch)

Windows 11, Python 3.14.5, PySide6-Essentials 6.11.3, Godot 4.7.2-stable. 코드 커밋 `0a6c337`에서 실행했다(그 뒤는
문서뿐이다).

| 검사 | 결과 |
|---|---|
| `tests/test_step3_final.py` — 수정 전(`0513b42`의 코드) / 수정 후 | 24 실패·1 통과 / 25 통과 |
| `pytest tools/python_monster_editor/tests` (네이티브 / offscreen) | 966 통과·8 건너뜀 / 964 통과·10 건너뜀 |
| 실제 Godot Staging (`check_godot_stage.py`) | PASS, 검사 78개. 세 문서 모두 `confirmed`, manifest에 이미지의 `.png.import` 포함 |
| 실제 Godot Rendering (`check_godot_render.py`, forward_plus) | PASS. 딱정벌레 20·개구리 32장 픽셀 동일 |
| Native GUI 스모크 100% / 150% / 200% | 각 49 통과 |
| `check_godot_import.py` / `check_godot_contract.py` / `check_contract_extensibility.py` | 45 통과 / 205 통과·3 미검사 / PASS |
| Map Editor: `pytest tools/python_map_editor/tests`, `check_scene_bridge.py` | 184 통과·3 건너뜀 / 통과 |
| `tools/check_project.py` | 3회 실행: **실패, 실패, 통과** (아래) |

`check_project.py`의 두 실패는 서로 다른 씬에서 같은 모양이다: 검사가 자기 PASS 줄을 출력한 **뒤** Godot 프로세스가
`0xC0000005`로 종료했다(`validate_player_sprite_pipeline.tscn`에서 `SPRITE PIPELINE VALIDATION PASS` 뒤, 그리고
`test_runner.tscn -- --restart-write`에서). 기능 실패 표시는 없었다. [known_issues.md](known_issues.md)의 분류로
알려진 엔진 종료 crash이며, 이 스크립트는 재시도하지 않으므로 그대로 실패로 끝난다. 이 브랜치는 그 씬들도
`check_project.py`도 바꾸지 않았다. 이 PC에서의 빈도가 이전 회귀들보다 높았다(같은 시간에 다른 세션의 Godot이 돌고
있었다) — 엔진 버전을 올릴 때 다시 볼 항목이다.

CI 결과는 아래 "CI (Final patch)"에 푸시 뒤 적는다.


**CI (Final patch)** — GitHub Actions, 커밋 `e18ad03`(코드는 `0a6c337`과 같다).

| 워크플로 / job | 결과 |
|---|---|
| Python Monster Editor / `core` (Ubuntu) | 성공 — 970 통과, 4 건너뜀 |
| Python Monster Editor / `core` (Windows) | 성공 — 974 통과, 건너뜀 없음 |
| Python Monster Editor / `godot-contract` (Linux: 계약·확장성·Import·Staging) | 성공 |
| Python Monster Editor / `gui-windows` (스모크 3배율, Import, Staging, 실제 렌더링, 작업 트리 미변경) | 성공, 첫 실행 |
| Godot validation / `headless` | 성공 |
| Godot validation / `windows-demo` | **성공** (`e18ad03`). 이 job이 이 브랜치에서 통과한 첫 실행이다 |

`windows-demo`는 같은 게임 코드로 `43ea113`·`d30baab`·`1b19bb1`·`0513b42`에서 서로 다른 자리에서 실패했고 `e18ad03`에서
통과했다. 통과 한 번이 그 실패들이 해결됐다는 뜻은 아니다 — 간헐적이라는 뜻이다
([known_issues.md](known_issues.md)의 "Windows 릴리스 probe의 미해결 기능 실패"). 이 줄보다 뒤의 커밋은 문서만 고친다.

이것으로 MONSTER-STEP 3 안정화를 닫는다. 남은 것은 이 브랜치 밖의 일이다: 엔진의 종료 crash(엔진 버전을 올릴 때),
Windows 릴리스 probe의 기능 실패(MONSTER-STEP 4-B 전에 별도 검증).

## 17. Closure patch — 남은 경계 조건 세 가지

master `98fd8b3` 위의 `feature/monster-editor-step3-closure`. 기존 구현은 그대로 두고 `bridge/staging.py`의 세 자리만
고쳤다. 각 항목은 먼저 테스트로 재현했다(`tests/test_step3_closure.py`를 `98fd8b3`의 코드에 대해 실행: 20 실패, 6 통과 —
통과한 6개는 가드이거나 그 코드에서도 옳았던 경우) → 수정 후 26 통과.

| 항목 | 결함 | 수정 |
|---|---|---|
| FIX-29 재검증의 경로 | `changed_dependencies()`와 `dependency_stats()`는 경로의 마지막 파일만 봤다. 상위 폴더가 프로젝트 밖을 가리키는 링크·junction으로 바뀌고 그 안에 같은 바이트의 파일이 있으면 "바뀌지 않음"이었다. 기록된 경로가 `../x` 같은 모양이어도 그대로 따라갔다 | 둘 다 manifest를 만들 때와 같은 `_dependency_file()`을 쓴다. 어느 단계든 링크를 거치는 경로, 일반 파일이 아닌 것, 프로젝트 기준의 평범한 경로가 아닌 것은 내용과 무관하게 **바뀐 것**이다. quick과 deep 모두 같다. `dependency_stats()`는 그런 경로의 baseline을 만들지 않는다 |
| FIX-30 선택 의존 파일의 존재 | manifest를 Godot이 돈 **뒤의 사본**에서 읽었다. Godot이 사본에 만든 `.png.import`가 프로젝트의 파일로 기록됐고(그 뒤 "프로젝트에 없음"으로 판정), 원본에 없던 파일은 manifest에 없으므로 나중에 생겨도 다시 보지 않았다 | 선택 파일의 존재는 **복사할 때의 원본**(survey)에서 정하고, 있던 파일의 해시는 Godot이 돌기 전에 사본에서 읽는다. `StageResult.optional_dependencies`가 경로마다 `present`/`absent`를 기록한다. `absent`였던 경로에 무엇이든 생기면 `changed_dependencies()`가 그 경로를 보고한다 |
| FIX-31 재시도 사이의 소유 | 삭제가 실패하면 소유 확인 없이 같은 경로를 다시 지웠다(최대 4회). 첫 시도와 재시도 사이에 같은 이름의 다른 폴더가 생기면 그 폴더가 지워졌다 | `remove()`와 `_abandon()`이 `_delete_owned()` 하나를 쓰고, **매 시도 전에** `check_deletable()`을 다시 한다. 재시도에서 거절되면 더 지우지 않고, 오류와 `cleanup_error`에 거절 이유와 앞선 삭제 실패의 이유를 함께 남긴다. 세션은 `leftovers()`에 남는다 |

**선택 의존 파일의 여섯 상태.**

| 상태 | 결과 |
|---|---|
| 원본에 처음부터 없음 | `optional_dependencies[path] == "absent"`, `dependencies`에 없음, `confirmed` 가능 |
| 원본에 처음부터 있음 | `"present"`, `dependencies`에 있음 |
| Staging 도중 원본에 새로 생김 | `changed_since_copy`에 그 경로, `verdicts["current"] == FAIL`, `confirmed` 아님 |
| Staging 도중 원본에서 삭제됨 | 위와 같음 |
| 사본에서만 Godot이 생성(또는 다시 씀) | 프로젝트의 변경이 아니다. 결과에 영향 없음 |
| 원본의 내용 변경 | `changed_since_copy`에 그 경로 (크기가 같아도 — deep 비교) |

stage가 끝난 뒤의 생성·삭제·변경은 편집기의 "오래됨" 판정이 같은 함수로 본다(§15).

**기존 호출과의 호환.** `StageResult`에 기본값이 있는 필드 `optional_dependencies` 하나가 끝에 더해졌다. `passed`,
`differences`, `areas`, `verdicts`의 키, `confirmed`, `is_current`, `project_fingerprint`의 계산은 그대로다.
`changed_dependencies(project, result, deep=False, baseline=None)`와 `dependency_stats(project, result)`의 모양도 같고,
`optional_dependencies`가 없는 결과 객체도 받는다. 소유 확인의 규칙(표식, owner token, 폴더 identity)은 바꾸지 않았다.

**정상적인 재시도는 그대로다.** 한 번의 시도가 표식까지 지운 뒤 다른 파일에서 막힌 경우, 세션은 그 시점에 `leftover`
상태이므로 다음 확인은 owner token이나 폴더의 identity로 통과한다. 첫 확인에서 거절된 `remove()`는 전처럼 세션의 상태를
바꾸지 않는다.

**한계.**

- 이것은 **시도와 시도 사이**의 보호다. 한 번의 확인과 그 뒤의 삭제 사이에 폴더가 바뀌는 경쟁은 막지 못한다 — 폴더를
  열어 둔 채 그 핸들 기준으로 지우는 구현이 아니다.
- 폴더의 identity는 `(device, inode)`다. 파일 시스템이 값을 주지 않으면 표식과 token만이 근거이고, 지워진 폴더의 inode를
  새 폴더가 다시 받는 경우는 구분하지 못한다.
- 세션의 폴더가 다른 이름으로 옮겨져 그 경로에 아무것도 없으면 `remove()`는 "이미 없음"으로 끝난다. 옮겨진 폴더는
  찾지 않는다.
- 재검증의 경로 규칙은 프로젝트 루트 **아래**에 적용된다. 루트 자체가 링크인지는 stage를 시작할 때만 본다.
- 선택 의존 파일은 여전히 이미지의 `.png.import`뿐이다.

### 검증 (Closure patch)

Windows 11, Python 3.14.5, PySide6-Essentials 6.11.3, Godot 4.7.2-stable.

| 검사 | 결과 |
|---|---|
| `tests/test_step3_closure.py` — 수정 전(`98fd8b3`의 코드) / 수정 후 | 20 실패·6 통과 / 26 통과 |
| `pytest tools/python_monster_editor/tests` (네이티브 / offscreen) | 992 통과·8 건너뜀 / 990 통과·10 건너뜀 |
| 실제 Godot Staging (`check_godot_stage.py`) | PASS, 검사 78개. 세 문서 모두 `confirmed`, 이미지의 import 설정이 manifest에 있음 |
| 실제 Godot Rendering (`check_godot_render.py`) | PASS, 검사 20개 |
| Native GUI 스모크 100% / 150% / 200% (`--godot` 없이) | 각 27 통과 |

전체 pytest의 첫 실행에서 기존 테스트 하나(`test_step3_final.py`의 `project.godot` 경우)가 실패했다. 그 테스트는
`dependency_manifest`의 호출을 가로채는데, 선택 파일을 미리 읽는 새 호출이 같은 함수를 지났기 때문이다. 테스트는
고치지 않았고, 미리 읽는 쪽이 내부 함수(`_manifest`)를 쓰게 했다.
