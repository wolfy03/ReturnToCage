# ReturnToCage Monster Editor — core (MONSTER-STEP 1)

`.rtcmonster` 문서의 Python core다. GUI는 아직 없다. 표준 라이브러리만 쓰고 Qt·Godot를 import하지 않는다.

- 설계: [`docs/monster_editor_architecture.md`](../../docs/monster_editor_architecture.md)
- 필드 정의: [`docs/monster_editor_schema_v1.md`](../../docs/monster_editor_schema_v1.md)
- 실행 계약(미구현): [`docs/monster_editor_runtime_contract.md`](../../docs/monster_editor_runtime_contract.md)
- 기존 몬스터·Map Editor: [`docs/monster_editor_compatibility.md`](../../docs/monster_editor_compatibility.md)
- 이후 단계: [`docs/monster_editor_roadmap.md`](../../docs/monster_editor_roadmap.md)

## 지금 되는 것

```python
from rtcmonster import new_document, read_document, write_document, validate

document = new_document("moss_slug", "Moss Slug")
document = document.replace(("stats", "max_health"), 30)   # 문서는 불변, 편집은 새 문서를 돌려준다
revision = write_document("moss_slug.rtcmonster", document)  # 새 파일은 기존 파일을 덮지 않는다

document, revision = read_document("moss_slug.rtcmonster")
write_document("moss_slug.rtcmonster", document, revision)   # 그 사이 파일이 바뀌었으면 DocumentConflict

report = validate(document, project="../..")                 # project를 주면 이미지·ID·loot·원본 해시도 검사
print(report.summary())
```

## 명령

```sh
# 테스트 (pytest만 필요)
python -m pytest tools/python_monster_editor/tests -q -rs -p no:cacheprovider

# 문서 정적 검증
python tools/python_monster_editor/validate.py tools/python_monster_editor/examples/*.rtcmonster --project .

# 실제 Godot 리소스와 예제 대조 (Godot 4.7.2 필요)
python tools/python_monster_editor/check_godot_contract.py --godot <godot>

# 스키마 문서의 표 다시 만들기 (schema.py / modules.py를 고친 뒤)
cd tools/python_monster_editor && python -m rtcmonster.reference
```

`check_godot_contract.py`는 게임 파일을 바꾸지 않는다. 기존 몬스터의 스크립트·scene·리소스를 고쳐서 이 검사가
"source files" 항목으로 실패하면, 예제가 여전히 게임과 같은지 확인한 뒤 `--refresh-bindings`로 해시를 갱신한다.

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
