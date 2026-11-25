# ReturnToCage Monster Editor (MONSTER-STEP 2)

`.rtcmonster` 문서의 Python core와 그 위의 편집기다. 편집기는 초안을 만들고 게임 몬스터의 값을 읽어 올 뿐,
게임을 바꾸지 않는다(게시는 이후 단계).

```sh
python -m pip install -r tools/python_monster_editor/requirements.txt    # Python 3.14.5, PySide6-Essentials 6.11.3
python tools/python_monster_editor/main.py [문서.rtcmonster]
```

| 폴더 | 내용 | 의존성 |
|---|---|---|
| `rtcmonster/` | core: 문서, 편집, 저장, 검증, 카탈로그 | 표준 라이브러리 |
| `application/` | 문서 세션·Undo/Redo, 프로젝트, 설정, 작업 관리 | 표준 라이브러리 |
| `bridge/` | Godot 실행(`client`)과 legacy 몬스터 변환(`importer`) | 표준 라이브러리 |
| `gui/`, `main.py` | 편집기 | PySide6 |

- 사용법: [`docs/monster_editor_user_guide.md`](../../docs/monster_editor_user_guide.md)
- STEP 2 기록: [`docs/monster_editor_step2.md`](../../docs/monster_editor_step2.md)
- Bridge 규약: [`docs/monster_editor_bridge.md`](../../docs/monster_editor_bridge.md)

- 설계: [`docs/monster_editor_architecture.md`](../../docs/monster_editor_architecture.md)
- 필드 정의: [`docs/monster_editor_schema_v1.md`](../../docs/monster_editor_schema_v1.md)
- 실행 계약(미구현): [`docs/monster_editor_runtime_contract.md`](../../docs/monster_editor_runtime_contract.md)
- 기존 몬스터·Map Editor: [`docs/monster_editor_compatibility.md`](../../docs/monster_editor_compatibility.md)
- 이후 단계: [`docs/monster_editor_roadmap.md`](../../docs/monster_editor_roadmap.md)

## core API

```python
from rtcmonster import (clone_document, insert_item, monster_catalog, new_document, parse_path, read_document,
                        rename_id, set_value, validate, write_document)

document = new_document("moss_slug", "Moss Slug")
document = document.replace(("stats", "max_health"), 30)     # 문서는 불변, 편집은 새 문서를 돌려준다
document.data["stats"]["max_health"] = 1                     # TypeError: data는 읽기 전용 뷰다

# 여러 변경을 한 번에. 하나라도 실패하면 아무것도 바뀌지 않는다 (Undo 한 단계)
document = document.apply(
    insert_item(("behavior", "states"), {"id": "rest", "module": "Wait", "transitions": [
        {"to": "idle", "condition": {"type": "ActionCompleted"}}]}),
    set_value(("metadata", "tags"), ["cave"]),
    rename_id("state", "rest", "nap"))                       # ID를 바꾸면 참조도 함께 바뀐다

revision = write_document("moss_slug.rtcmonster", document)  # 새 파일은 기존 파일을 덮지 않는다
document, revision = read_document("moss_slug.rtcmonster")
dirty = document.fingerprint != revision                     # "수정됨"은 비교다
write_document("moss_slug.rtcmonster", document, revision)   # 그 사이 파일이 바뀌었으면 DocumentConflict

report = validate(document, project="../..")                 # project를 주면 이미지·ID·loot·원본 해시도 검사
for finding in report.blocking:                              # FAIL만. 분기는 finding.code로 한다
    print(finding.code, finding.path, document.get(*parse_path(finding.path)) if finding.path else "")
report.is_current(document)                                  # 문서나 읽은 파일이 바뀌면 False

for path, node, value in document.schema.fields(document.data):   # Inspector가 쓸 메타데이터
    info = node.info()                                       # type, default, minimum, maximum, unit, choices, …

catalog = monster_catalog("../..")                           # 게임 몬스터(discovered)와 문제 목록
copy = clone_document(document, "moss_slug_elder")           # 새 ID 필수, source_binding은 지워진다
```

공개 API는 `rtcmonster/__init__.py`의 `__all__`이다. 표와 주의사항은
[`docs/monster_editor_step1_stabilization.md`](../../docs/monster_editor_step1_stabilization.md) §3, §10에 있다.

## 명령

```sh
# 테스트: core, application, bridge, GUI (Linux는 QT_QPA_PLATFORM=offscreen)
python -m pytest tools/python_monster_editor/tests -q -rs -p no:cacheprovider

# 문서 정적 검증
python tools/python_monster_editor/validate.py tools/python_monster_editor/examples/*.rtcmonster --project .

# Godot 계약 검사 (Godot 4.7.2 필요): 환경 / 등록된 모든 몬스터 / 기준 몬스터 예제
python tools/python_monster_editor/check_godot_contract.py --godot <godot> --artifacts <dir>

# 격리된 프로젝트 사본에서: 예제 없는 신규 몬스터는 통과, 잘못된 신규 몬스터는 실패
python tools/python_monster_editor/check_contract_extensibility.py --godot <godot>

# 스키마 문서의 표 갱신 (schema.py / modules.py / 검증 코드 선언을 고친 뒤)
cd tools/python_monster_editor && python -m rtcmonster.reference --update ../../docs/monster_editor_schema_v1.md

# GUI 스모크: 네이티브 창에서 실제 입력으로 전체 흐름, 화면과 시간 기록 (--project/--godot은 선택)
python tools/python_monster_editor/main.py --smoke-report <report.json> --smoke-shots <dir> --project . --godot <godot>

# 실제 Godot으로 Bridge와 Import 검사 (격리된 프로젝트 사본의 신규 몬스터, 실패 경로 포함)
python tools/python_monster_editor/check_godot_import.py --godot <godot> --artifacts <dir>

# 규모별 측정
python tools/python_monster_editor/benchmark.py --output <result.json>
```

두 Godot 검사는 게임 파일을 바꾸지 않는다. 게임에 몬스터를 새로 추가해도 예제 문서를 쓸 필요는 없다 —
새 몬스터는 registry 계약이 검사한다. 예제와 비교되는 것은 `godot_contract.LEGACY_PROFILES`에 등록한 기준 몬스터뿐이다.
기준 몬스터의 스크립트·scene·리소스를 고쳐서 "source files" 항목으로 실패하면, **예제가 여전히 게임과 같은지 먼저
확인한 뒤** `--refresh-bindings`로 해시를 갱신한다(값이 다르면 갱신되지 않는다). 그때 `--artifacts`의 `probe.json`을
`tests/fixtures/contract_probe.json`에도 복사한다.

## 검증 결과 읽기

`PASS` / `WARNING` / `FAIL` / `NOT_EVALUATED`. `runtime`과 `network`는 이 도구에서 항상 `NOT_EVALUATED`다 —
Godot을 실행하지 않고, 데이터 기반 런타임이 아직 없기 때문이다. `NOT_EVALUATED`는 통과가 아니다.

## 예제

| 파일 | 내용 |
|---|---|
| `examples/sewer_beetle.rtcmonster` | 게임의 실제 딱정벌레. 값은 contract check가 Godot과 대조한다 |
| `examples/frog.rtcmonster` | 게임의 실제 개구리. V1로 정확히 표현되지 않는 2건이 `source_binding.unsupported`에 있다 |
| `examples/sewer_rat_prototype.rtcmonster` | **추정값 fixture.** 게임 콘텐츠가 아니며 게시하지 않는다 |

예제는 문서일 뿐이다. 게임은 여전히 기존 GDScript로 딱정벌레와 개구리를 실행한다.
