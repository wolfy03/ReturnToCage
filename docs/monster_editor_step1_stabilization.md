# MONSTER-STEP 1 안정화

MONSTER-STEP 1(`b2e32b3`)의 Python core와 Godot 계약 검증기를 검토해 결함을 고치고, STEP 2~7이 구조를 다시 쓰지
않고 확장할 수 있도록 경계를 정리한 기록이다. 게임 런타임 코드, 기존 몬스터 리소스, 네트워크 프로토콜,
`.rtcmonster` Schema V1의 필드와 의미는 바꾸지 않았다. 세 예제 문서는 한 바이트도 바뀌지 않았다.

- 기준: master `869e81b`(안정화 브랜치에 병합), MONSTER-STEP 1 `b2e32b3`
- 브랜치: `feature/monster-editor-step1-stabilization`
- 환경: Godot 4.7.2-stable, Python 3.14.5, physics 60 Hz

## 1. 발견한 문제와 수정

| FIX | 문제 | 원인 | 수정 | 회귀 테스트 |
|---|---|---|---|---|
| 01 | `document.data["stats"]["max_health"] = -100`이 통했다. 정규화·검증을 우회하고, Undo 스냅샷까지 함께 바뀐다 | `data`가 내부 dict를 그대로 반환 | 데이터를 `FrozenDict`/`FrozenList`(변경 메서드가 `TypeError`를 내는 dict/list 하위 클래스)로 보관. 모든 변경은 `replace`/`apply`를 거쳐 정규화된다 | `test_immutability.py`, `test_stabilization_regressions.py` |
| 02 | 단일 필드 교체(`replace`)뿐이라 "상태 ID 변경 + 참조 갱신" 같은 묶음 편집을 표현할 수 없었다. 참조 대상이 스키마에 없어 검증기가 필드마다 손으로 확인했다 | 편집 API·참조 메타데이터 부재 | `apply(*edits)` 원자적 편집(`set_value`, `insert_item`, `remove_item`, `move_item`, `rename_id`). 스키마의 `Id(ref=...)`가 참조 대상을 선언하고, 참조 검증과 ID 이름 변경이 그 선언에서 파생된다. 모든 필드가 `node.info()`로 UI 중립 메타데이터를 낸다 | `test_immutability.py`, `test_extensibility.py` |
| 03 | 검증이 673줄짜리 모듈의 클래스 하나였고, 오류 코드가 문자열로 흩어져 있었으며, 결과가 어떤 문서·파일을 본 것인지 알 수 없었다 | 구조 없음 | `validation/` 패키지: 규칙은 `@rule` 함수, 코드는 `define()`으로 한 번 선언(영역·상태·수정 위치 고정), `Report`는 문서 fingerprint와 읽은 파일 해시에 묶인다 | `test_extensibility.py` |
| 04 | 모듈·조건·이벤트가 전역 dict였고, 검증기가 `"Hop"`, `"ExecuteAttackPattern"`, `"RangeStrike"` 같은 이름을 직접 비교했다 | 의미가 레지스트리가 아니라 검증기에 있었다 | `Registry`(불변, `extend()`로 확장)와 `Schema(registry)`. 의미는 항목의 플래그·콜백(`completes_if`, `runs_pattern`, `hurt_reaction`, `clip_budgets`, `checks`, `damaging`, `arms`, `signal`, `immediate` …)에 있고, 범용 코드는 이름을 모른다 | `test_extensibility.py` |
| 05 | 같은 ID를 두 파일이 정의하면 첫 파일이 조용히 선택됐다. 파일 하나가 깨지면 카탈로그 전체가 `{}`가 됐다 | `setdefault()`와 폴더 단위 `except` | `catalog.scan_content`: 중복 ID는 모든 경로와 함께 보고되고 어느 쪽도 채택되지 않는다. 파일별 오류는 기록되고 나머지는 유지된다. "디스크에서 발견"과 "Godot 등록 확인"을 구분한다 | `test_catalog_assets.py` |
| 06 | IHDR만 온전하면 손상된 PNG도 통과했다 | 헤더만 읽음 | 4단계로 분리(경로 / 헤더 / 무결성 / Godot import). 무결성은 표준 라이브러리로 chunk 구조·CRC·zlib 스트림·scanline 수와 filter 타입을 확인한다. Godot import는 `NOT_EVALUATED`로 남긴다 | `test_catalog_assets.py` |
| 07 | 등록된 모든 몬스터에 예제 문서를 요구했고, 공통 비교가 `attack`·`dead`·`idle` 상태와 첫 번째 공격 패턴을 전제했다 | 범용 검사와 legacy 비교가 한 함수 | 5개 계약(environment / registry / legacy / data_driven / behavior)으로 분리. registry는 예제 없이 모든 몬스터를 검사하고, legacy는 명시적으로 등록한 기준 몬스터(`LEGACY_PROFILES`)만 비교한다. 구조화된 JSON 증거를 남긴다 | `test_godot_contract.py`, `check_contract_extensibility.py` |
| 08 | 저장 실패 경로 테스트가 `os.replace` 하나뿐이었고 동시 저장·잠금·임시 파일 정책이 문서화되지 않았다 | – | 장애 주입 7종, 스레드·프로세스 동시 저장, 잠금 충돌, 덮어쓰기 승인 revision, 남은 임시 파일 정책(`stale_temporaries`) | `test_storage_faults.py` |
| 09 | `tick_of(0.2, 0)`이 0을 반환하고, scale 0이 `ZeroDivisionError`였으며, shape 분기가 `if/else`였다 | 입력 검증 없음 | tick rate·시간·scale·좌표의 비정상 입력은 `ValueError`. shape는 `geometry.SHAPES` 레지스트리로 분기. 같은 tick 이벤트의 실행 순서(`schedule`)를 정의 | `test_geometry_timing_matrix.py` |
| 10 | 같은 tick에 떨어지는 이벤트의 순서 모순, 피해 배율 0을 검출하지 못했다 | 규칙 없음 | `event_order_differs_from_time`, `pattern_deals_no_damage` 경고 추가. 즉시 순환과 정상 반복의 구분을 문서화 | `test_geometry_timing_matrix.py`, `test_validation.py` |
| 11 | Frog 미지원 2건의 해결 방향이 미정 | – | 방향 확정(§6). Schema V1은 유지 | – (문서) |
| 12 | Map Editor와의 공통화 방침 미정 | – | 후보·조건 정리, 이번 단계는 추출하지 않음(§7) | – (문서) |
| 13 | 성능 기준값 없음 | – | `benchmark.py`로 3개 규모 측정(§8). 스냅샷 구조 공유 적용 | `test_immutability.py` |
| 14 | CI path filter가 일부 의존 파일을 빠뜨렸고, Godot 종료 코드 외 검증이 약했다 | – | path 확대, Godot 버전 확인, schema 문서 최신성 검사, 확장성 검증 job step, JUnit·계약 JSON·측정 결과 artifact | workflow |

### 수정 전 실패 확인

`tests/test_stabilization_regressions.py`는 **기존 API만** 사용한다. 수정 전(`b2e32b3` + master 병합) 코드에서
19개 중 16개가 실패했고(불변성 2, 카탈로그 2, 손상 PNG 5, tick rate 3, 비유한 시간 1, scale 3), 수정 후 19개 모두
통과한다. 수정 전에도 통과한 3개는 정상 이미지 대조군 1개와 Python이 우연히 거절하던 입력 2개
(`tick_of(x, nan)`, `tick_of(nan)`)다. 새 API(편집, 레지스트리 확장, 카탈로그 모델, 계약 분리)의 테스트는 대상
API가 수정 전에 없었으므로 "수정 전 실패"를 확인할 수 없다.

## 2. 구조 변화

```text
수정 전                                   수정 후
rtcmonster/                               rtcmonster/
  spec.py      필드 node                    spec.py        + ref / hint / deprecated / info(), capabilities
  schema.py    전역 DOCUMENT 트리           schema.py      Schema(registry): fields() 순회, 참조 선언
  modules.py   전역 dict 3개                modules.py     Registry + 플래그·검증 콜백을 가진 항목
  document.py  data가 내부 dict 노출        document.py    FrozenDict/FrozenList, apply(), fingerprint, clone
                                            editing.py     Edit 5종, 원자 적용, rename_id
  validation.py  클래스 하나 (673줄)        validation/    report · context · structure · assets · animation
                                                           · combat · behavior · compatibility
  project.py   카탈로그 + PNG 헤더          catalog.py     ContentScan / MonsterCatalog
                                            png.py         헤더 + 무결성
                                            project.py     경로 안전, 이미지 검사, 원본 파일 상태
  geometry.py  if/else shape                geometry.py    SHAPES 레지스트리, 입력 검증
  timing.py                                 timing.py      입력 검증, schedule()
check_godot_contract.py  비교 로직 포함     godot_contract.py            계약 평가 (순수 함수)
                                            check_godot_contract.py      probe 실행 + 보고
                                            check_contract_extensibility.py  격리 사본에서 신규 몬스터 시나리오
                                            benchmark.py                 측정
```

의존 방향은 한쪽이다: `spec` ← `modules` ← `schema` ← `document`/`editing` ← `validation` ← 도구. 순환은 없다
(`catalog`가 초안을 읽을 때만 `storage`를 함수 안에서 import한다).

## 3. 공개 API와 호환성

`rtcmonster/__init__.py`의 `__all__`이 공개 범위다. 밑줄로 시작하는 이름과 여기서 다시 내보내지 않는 모듈은 내부
구현이다. 패키지 밖에서 `MonsterDocument._data`에 접근하지 않는다.

| 기존 API | 상태 |
|---|---|
| `MonsterDocument(data)`, `.data`, `.to_dict()`, `.get()`, `.replace()`, `.monster_id` | 유지. `.data`는 이제 읽기 전용 뷰(변경 시 `TypeError`). `.get()`은 없는 경로에 `DocumentError` |
| `new_document`, `encode`, `decode` | 유지. 선택 인자 `schema` 추가 |
| `read_document`, `write_document`, `document_revision`, `DocumentConflict` | 유지 |
| `validate`, `validate_payload`, `duplicate_monster_ids`, `Finding`, `Report` | 유지. `Finding`에 `related`·`subject`·`remedy`·`summary`, `Report`에 `fingerprint`·`inputs`·`blocking`·`unverified`·`is_current()` 추가 |
| `rtcmonster.validation.summarize`, `STATIC_DOMAINS` | 유지 (패키지가 다시 내보냄) |
| `project.content_ids`, `published_monsters` | 유지. 중복 ID와 읽을 수 없는 파일을 **제외**한다(이전엔 첫 파일 채택 / 전체 손실) |
| `project.png_size` | 유지 (헤더만. 무결성은 `inspect_image`) |
| `project.inspect_image` | 유지. 이제 무결성까지 확인하고 `png.PngError`를 낼 수 있다 |
| `modules.MODULES` / `CONDITIONS` / `EVENTS` / `RESERVED_MODULES` | 유지 (기본 레지스트리의 읽기 전용 뷰) |
| `schema.DOCUMENT`, `TOP_LEVEL_ORDER`, `normalize` | 유지 (기본 스키마의 뷰) |
| `modules.IMMEDIATE_CONDITIONS` | 제거. `Condition.immediate`로 대체 (패키지 내부에서만 쓰였다) |

새 공개 API: `clone_document`, `Edit`·`set_value`·`insert_item`·`remove_item`·`move_item`·`rename_id`,
`Schema`·`DEFAULT_SCHEMA`, `Registry`·`DEFAULT_REGISTRY`, `capabilities`, `monster_catalog`·`scan_content`,
`CODES`, `parse_path`·`format_path`.

기존 216개 테스트 중 수정한 것은 1개다: "이미지가 바뀌면 `asset_changed`" 테스트가 파일 끝에 바이트를 덧붙이는
방식이었는데, 그것은 이제 올바르게 `asset_corrupt`(IEND 뒤의 데이터)다. 같은 크기로 다시 그린 PNG를 쓰도록 고쳤다.
완화하거나 삭제한 테스트는 없다.

## 4. 설계 결정 기록

| 결정 | 선택 | 대안과 버린 이유 |
|---|---|---|
| 불변 문서 | dict/list 하위 클래스로 변경 메서드를 막는다 | **Defensive deep copy**: `data`를 읽을 때마다 전체 복사(Large에서 약 3 ms, 검증기는 수백 번 읽는다). **`MappingProxyType` + tuple**: `isinstance(x, dict/list)`가 거짓이 되어 JSON 인코딩과 모든 reader를 바꿔야 한다. **Persistent 자료구조**: 측정 없이 도입할 복잡도가 아니다. 한계: `dict.__setitem__(d, k, v)`처럼 기반 클래스를 직접 부르면 우회된다 — 사고 방지이지 공격 방어가 아니다 |
| 스냅샷 메모리 | `freeze(value, previous)`가 바뀌지 않은 하위 트리를 이전 문서와 공유 | 전체 복사: Large에서 스냅샷당 619 KiB(실측). 공유 후 1.2 KiB. 불변이므로 공유가 안전하다. 편집 1회 시간은 약 35% 늘었다(§8) |
| 편집 | 값 객체 `Edit` 5종 + `apply` | 명령 클래스 계층(do/undo): Undo는 스냅샷 교체로 충분하다. 문서가 불변이라 역연산이 필요 없다 |
| ID 이름 변경 | 스키마의 `Id(ref=kind)` 선언을 순회해 일괄 치환 | 종류별 수동 함수: 필드가 늘 때마다 빠뜨린다. 이름 변경과 참조 검증이 같은 선언을 쓰므로 둘이 어긋날 수 없다 |
| 구조 검증과 의미 검증 | 모양(타입·모르는 필드·ID 형식·유한성)은 문서가 될 수 없다. 범위·참조·의미는 저장되고 finding이 된다 | 기존 정책 유지. 이제 `apply`도 같은 경계를 지난다 |
| Validation 분리 | 영역별 모듈 + `@rule` 등록 + 공용 `Context` | 클래스 계층·플러그인 로더: 규칙은 함수면 충분하고, 외부 코드를 동적으로 읽을 이유가 없다 |
| 오류 코드 | `define()`으로 한 번 선언. 영역·상태·수정 위치가 코드에 고정 | 호출부마다 상태 지정: 같은 코드가 두 상태로 나갈 수 있다. 선언에서 문서 표를 생성한다 |
| 결과 무효화 | `Report.fingerprint`(문서) + `inputs`(읽은 파일 해시) + `scans`(폴더 fingerprint) | 타임스탬프: 내용이 같아도 무효가 되고, 같은 초의 변경을 놓친다 |
| 모듈 의미 | 레지스트리 항목의 플래그와 `checks` 콜백 | 검증기 안의 이름 비교: 모듈이 늘 때마다 검증기를 고친다. `test_extensibility.py`가 범용 코드에 이름이 없음을 AST로 검사한다 |
| PNG 무결성 | 표준 라이브러리(`zlib`)로 컨테이너·스트림·scanline 구조 확인 | **Pillow**: core가 표준 라이브러리만 쓴다는 성질을 잃고 EXE 패키징·라이선스·보안 갱신 부담이 생긴다. **헤더만**: 손상 파일이 통과한다. 픽셀 재구성은 하지 않는다 — 디코더를 새로 쓰는 것이 아니다. STEP 3에서 미리보기를 위해 Qt로 실제 디코딩하게 되면 그 결과를 같은 단계에 더한다 |
| 카탈로그 | 발견(`discovered`) / Godot 확인(`registry_verified`·`not_in_registry`) / 초안(`draft`) | 파일이 있으면 등록된 것으로 간주: `ContentRegistry`가 거절한 파일도 "게시됨"으로 보인다 |
| 저장 동시성 | 협력적 sidecar 잠금 + revision 재확인 | OS 강제 잠금: 플랫폼마다 다르고 외부 편집기를 막을 수 없다는 사실은 그대로다 (§5) |
| Schema 버전 | V1 유지 | Frog 해결 필드를 지금 추가: 버전 정책상 V2가 되어야 하고, 실행할 런타임이 없어 검증할 수 없다 |
| 계약 검증 | 범용 registry 계약 + 명시적 legacy 기준 목록 | 모든 몬스터에 예제 요구: 몬스터가 늘 때마다 손으로 문서를 써야 한다. 신규 몬스터를 검사에서 제외: 잘못된 리소스를 놓친다 |

## 5. 저장 계약

| 상황 | 동작 |
|---|---|
| 최초 저장 (`expected_revision=None`) | 새 파일만 만든다. 대상이 있으면 `DocumentConflict` — 기존 파일을 덮지 않는다 |
| 기존 파일 갱신 (`expected_revision=<읽은 값>`) | 디스크의 해시가 그 값일 때만 교체 |
| 다른 이름으로 저장, 대상 없음 | 최초 저장과 같다 |
| 다른 이름으로 저장, 대상 있음 | 거절된다. 사용자가 덮어쓰기를 승인하면 **승인 시점**의 `document_revision(target)`을 넘긴다. 승인과 저장 사이에 대상이 바뀌면 `DocumentConflict` |
| 외부 변경·삭제 | `DocumentConflict`. 아무것도 쓰지 않는다 |
| 저장 도중 실패 (임시 파일 생성·쓰기·flush·fsync·교체) | 원본 그대로, 임시 파일 제거, 잠금 해제. 같은 저장을 다시 하면 성공한다 |
| 두 프로세스가 같은 revision에서 저장 | 정확히 하나만 성공, 나머지는 `DocumentConflict` |
| 읽기 전용 대상 | `PermissionError` |

무조건 덮어쓰는 API는 없다. 반환값(revision)은 `document.fingerprint`와 같은 값이므로 "수정됨" 여부는 플래그가
아니라 `document.fingerprint != revision` 비교다.

**제약.**

- 잠금은 협력적이다. 같은 규약(`.<이름>.lock` sidecar)을 쓰는 프로세스끼리만 서로를 막는다. 규약을 모르는 외부
  프로그램은 revision 확인과 교체 사이의 짧은 구간에 파일을 바꿀 수 있고, 그 변경은 덮인다. 이 구간을 없애지 못했다.
- 원자성은 같은 볼륨 안의 `os.replace`(Windows `MoveFileEx`, POSIX `rename`)에 의존한다. 임시 파일을 대상과 같은
  디렉터리에 만드는 이유다. 네트워크 파일 시스템에서의 원자성과 잠금 동작은 검증하지 않았다.
- 프로세스가 임시 파일 생성과 교체 사이에 강제 종료되면 `.rtcmonster-*` 파일이 남는다. 문서로 읽히지 않으며,
  `storage.stale_temporaries(folder)`가 1시간 넘은 것을 찾고 `remove_stale_temporaries`가 지운다(자동 실행은 없다).
- 잠금 sidecar 파일은 남는다(`.gitignore`에 등록).
- Godot 다중 파일 게시 저널은 STEP 6 범위다.

## 6. Frog 특화 행동의 확장 방향

### 접촉 판정 (ContactStrike)

기존: 도약 중 매 tick **대상의 원점**이 `|dx| ≤ 44, |dy| ≤ 40` 안이면 명중.

| 대안 | 재현 정확도 | 재사용성 | GUI | 호환성 | 네트워크 | 비용 |
|---|---|---|---|---|---|---|
| A. 일반 hitbox로 근사 | 낮음 — 대상 hurtbox 크기만큼 더 멀리서 맞는다 | 이미 있음 | 변화 없음 | V1 그대로 | 없음 | 0 |
| B. `ContactStrike` 이벤트 추가 | 정확 | 낮음 — hitbox와 별개의 크기·구간 표현이 하나 더 생긴다 | 이벤트 전용 편집기 필요 | V2 | 없음 | 중간 |
| **C. hitbox마다 판정 방식 선택** | 정확 — 88×80 상자가 대상 원점을 포함하는지 = 기존 식 | 높음 — 모든 도약·돌진형이 같은 hitbox 편집 화면으로 쓴다 | hitbox Inspector에 선택 항목 하나 | V2 (필드 추가) | 없음 (서버 판정) | 낮음 |

**결정: C.** V2에서 `collision.hitboxes[].target_test`를 추가한다: `"hurtbox_overlap"`(기본, V1의 유일한 의미) 또는
`"origin_inside"`. 구간·중복 방지·좌우 반전은 hitbox의 것을 그대로 쓴다. V1 문서는 migration에서
`"hurtbox_overlap"`으로 채워지므로 의미가 바뀌지 않는다.

### 근거리 도약 속도

기존: 복귀 중 origin이 추격 hop 한 번 거리보다 가까우면 짧은 순찰 hop(0.6배, lift 230)으로 바꾼다.

**결정:** V2에서 `Hop` 모듈에 `near_goal_speed_scale`·`near_goal_lift`(null = 사용 안 함)를 추가한다. 목표(target 또는
origin)까지의 수평 거리가 기본 속도·lift의 hop 도달 거리보다 짧을 때 적용된다. 목표 초과 방지를 "거리 기반 속도
계산"이 아니라 "두 번째 hop 설정"으로 표현하는 이유는 기존 동작이 그렇고, 발사 속도가 항상 authoring한 두 값 중
하나라 예측하기 쉽기 때문이다. 착지 조건·최대 체공·지형 안전 검사는 `Hop`에 이미 있다(`max_air_seconds`,
`max_drop`).

### Schema 버전

| 변경 | 버전 |
|---|---|
| 기존 필드로 표현 가능 | V1 그대로 |
| 필드·모듈 파라미터·이벤트·조건·shape 추가 (의미 변경 없음) | V2 + V1→V2 migration(기본값 채움). 이전 편집기는 V2를 거절한다 |
| 기존 필드의 의미·단위 변경, 필드 제거 | 금지. 새 이름의 필드를 추가하고 이전 것은 `deprecated`로 표시 |
| 지원 수준만 변경 (`planned` → `contract`) | 버전 불변. 문서 내용이 아니라 편집기·런타임의 상태다 |

두 Frog 항목은 V2 후보로만 기록했고, 스키마에 미리 넣지 않았다. 실행할 런타임이 생기는 STEP 5에서 넣는다.
Frog 런타임은 건드리지 않았다.

### 보스·특수 몬스터가 V1에 들어가는지

| 사례 | V1 | 비고 |
|---|---|---|
| 한 패턴에서 여러 hitbox | 가능 | `EnableHitbox` 여러 개 |
| 다단 타격 | 가능 | `hit_policy: multi_hit` + `multi_hit_interval` |
| 연속 공격 | 가능 | `ExecuteAttackPattern` 상태를 `AttackPatternCompleted`로 연결 |
| 공격 중 방향 고정 / 피격 무시 | 가능 | `facing_locked`, `interrupt.on_hurt: ignore` |
| 한 패턴에서 여러 clip | 가능 (`planned`) | `PlayAnimation` 이벤트 |
| 체력 비율로 공격 가중치 변경 | 가능 (`planned`) | `behavior.phases[].pattern_weights` |
| 조건에 따른 공격 취소 | **불가** | 패턴 실행 중에는 interrupt만 통과한다. V2 후보: 패턴의 `cancel_condition` |
| 페이즈별 상태 그래프 | **부분** | `phases[].enter_state`로 다른 상태 묶음에 들어갈 수 있지만, 그래프 자체를 페이즈가 소유하지 않는다 |
| 페이즈별 hurtbox | **불가** | override의 키가 clip·frame뿐이다. V2 후보: 페이즈를 override 키에 추가 |
| 이동 형태 전환 | **부분** | 상태마다 다른 이동 모듈을 쓸 수 있지만 `movement.locomotion`은 문서에 하나다 |
| 이벤트 ID, Damage Group | 없음 | 이벤트는 위치로 식별한다. hit 목록은 공격 인스턴스 단위 하나다. hitbox별 그룹이 필요해지면 V2 |

## 7. Python Map Editor와의 공통화

이번 단계는 Map Editor의 패키지 구조와 EXE 빌드를 건드리지 않았고, 공통 패키지도 추출하지 않았다.

| 영역 | Map Editor | Monster Editor | 지금 상태 | 추출 판단 |
|---|---|---|---|---|
| 원자 저장·sidecar 잠금·revision | `document.py` | `storage.py` | 같은 알고리즘의 중복 구현 | **후보 1순위.** 책임이 동일하고 데이터 모델과 무관하다 |
| 경로 안전 규칙 | `source_region.relative_path`, `objects.validate_texture` | `spec.safe_relative_path`, `project.resolve_project_file` | 규칙이 거의 같다 | 후보. 확장자 정책만 인자로 |
| Godot 프로세스 실행·취소·Job Object | `godot_bridge.run_child`, `traversal_process.ProcessScope` | 없음 (`subprocess.run` 한 번) | STEP 2에서 필요해진다 | **STEP 2의 Import가 필요로 할 때 추출.** 그 전엔 재구현하지 않는다 |
| Bridge 요청·응답 규약 | protocol 1, request_id | probe의 단일 JSON | 다름 | 규약(봉투)은 공통, 명령은 각자 |
| Validation 상태·finding | `region_validation.Finding` | `validation.report.Finding` | 4개 상태는 같고 필드는 다르다 | 보류. 영역 체계가 서로 다르다 |
| Content 카탈로그 | `discover_enemies` (ID만) | `catalog.scan_content` | Monster 쪽이 상위 집합 | Map Editor가 중복 ID 표시가 필요해질 때 |
| 문서 모델 | `MapDocument` dataclass | `MonsterDocument` + Schema | 다름 | **추출하지 않는다** |
| PySide6 위젯, EXE 빌드 | 있음 | 없음 | – | STEP 7에서 spec 재사용 검토 |

추출 조건: 두 편집기가 실제로 같은 책임을 수행하고, 공개 인터페이스가 안정적이며, 각 편집기의 테스트가 독립적으로
돌고, 순환 의존이 없고, **Map Editor EXE를 다시 빌드해 `verify_windows_package.py`를 통과**해야 한다(Map Editor는
flat module로 PyInstaller에 묶인다). 코드가 비슷하다는 것만으로는 추출하지 않는다. 후보 구조는
`tools/rtc_editor_common/{filesystem,process,bridge}`이며 확정이 아니다.

## 8. 성능 측정

`python tools/python_monster_editor/benchmark.py`. Windows 11, AMD64(Family 25 Model 80), CPython 3.14.5,
`time.perf_counter`, 표본마다 GC 후 측정, 중앙값. 반복 횟수는 Small 30, Medium 15, Large 7. 메모리는 `tracemalloc`.
"수정 전"은 `b2e32b3`의 패키지를 같은 스크립트로 잰 값이다. 전부 **이 기계에서의 실측**이고 목표값이 아니다.
GUI가 없으므로 UI 반응 속도에 대해서는 아무것도 말하지 않는다.

| 규모 | clip | frame | 패턴 | 상태 | 정규 JSON |
|---|---|---|---|---|---|
| Small | 5 | 50 | 2 | 10 | 23 KB |
| Medium | 20 | 300 | 10 | 30 | 99 KB |
| Large | 50 | 1,000 | 30 | 64 | 282 KB |

Large의 상태 수는 계획의 100이 아니라 64다. 스키마 한도(`behavior.states` ≤ 64)이고, 65번째는 거절된다
(`test_the_schema_limit_rejects_what_it_cannot_hold`).

| 항목 (ms, 수정 전 → 후) | Small | Medium | Large |
|---|---|---|---|
| 문서 생성 | 1.0 → 1.4 | 4.7 → 11.7 | 12.0 → 17.3 |
| 전체 복사 (`to_dict`) | 0.39 → 0.23 | 1.6 → 1.0 | 5.1 → 3.1 |
| 단일 필드 수정 | 1.8 → 2.4 | 7.4 → 10.0 | 21.5 → 29.3 |
| 5개 필드 수정 | 8.8 → 2.3 | 37.3 → 10.0 | 107.7 → 29.1 |
| JSON encode | 2.7 → 2.5 | 11.3 → 11.9 | 34.5 → 34.9 |
| JSON decode | 1.6 → 2.0 | 9.6 → 16.8 | 19.8 → 23.8 |
| 전체 정적 검증 | 1.1 → 3.4 | 5.3 → 7.6 | 13.3 → 20.8 |
| 저장 + 재열기 | 17.8 → 27.2 | 35.7 → 34.0 | 68.7 → 72.9 |
| 연속 100회 수정 | 166 → 255 | 805 → 1,044 | 2,380 → 3,032 |
| fingerprint 최초 계산 | – → 4.0 | – → 17.8 | – → 52.1 |
| 참조 인덱스 생성 | – → 0.007 | – → 0.015 | – → 0.029 |
| **Undo 스냅샷 1개 (KiB)** | 51.1 → 1.2 | 215.9 → 1.2 | 619.0 → 1.2 |

읽는 법:

- **나아진 것.** 여러 필드 편집이 `apply` 한 번이라 편집 수에 비례하지 않는다(Large 108 → 29 ms). 스냅샷 메모리는
  문서 크기와 무관해졌다(Large 619 → 1.2 KiB). `data` 읽기는 복사가 없다.
- **느려진 것.** 편집 1회는 약 35%(freeze와 공유 판정), 검증은 약 55%(스키마를 순회하는 범용 참조 검사) 느려졌다.
  문서 생성·decode의 Medium 값(11.7, 16.8 ms)은 실행마다 5~12 ms 사이로 흔들렸다.
- **남은 비용.** 편집 1회가 여전히 문서 전체를 복사·정규화한다(Large 29 ms). 프레임을 드래그하며 초당 수십 번
  편집하는 STEP 3 화면에서는 문제가 될 수 있다. 그때의 선택지는 (1) 드래그 중에는 미리보기 값만 바꾸고 놓을 때
  한 번 편집, (2) 바뀐 하위 트리만 정규화. 지금은 어느 것도 구현하지 않았다 — 측정할 GUI가 없다.
- 프로젝트 파일은 검증 1회당 폴더·이미지마다 한 번만 읽는다(`test_project_files_are_read_once_per_run`).

## 9. 신규 기능 추가 가이드

공통 절차: 코드를 고친 뒤 `cd tools/python_monster_editor && python -m rtcmonster.reference --update
../../docs/monster_editor_schema_v1.md`로 문서 표를 갱신하고(`test_contracts.py`와 CI가 최신인지 검사), pytest를
돌린다. 문서에 새로 저장되는 것이 생기면 Schema 버전을 올리고 `document._MIGRATIONS`에 migration을 넣는다(§6).

| 추가할 것 | 고칠 곳 | 고치지 않는 곳 | 테스트 | 런타임 지원 표시 |
|---|---|---|---|---|
| Schema 필드 | `schema._document()`에 node 하나 (타입·기본값·범위·단위·`doc`·`support`·`ref`·`hint`) | decode, encode, 범위 검증, 참조 검증, 이름 변경, 문서 표, Inspector 메타데이터 — 전부 node에서 파생 | 예제 왕복 테스트가 기본값 채움을 확인. 의미 규칙이 있으면 규칙 테스트 | node의 `support` |
| Action Module | `modules._MODULES`에 `Module(...)` 하나. 특수 규칙은 `checks=(함수,)`, 완료 조건은 `completes_if` | `validation/*`, `schema.py`, `reference.py` | `test_extensibility.py`의 Burrow fixture가 절차 그대로다 | `support`, `since` |
| Transition Condition | `modules._CONDITIONS`에 `Condition(...)`. 신호를 기다리면 `signal`, 무조건 참이면 `immediate` | 위와 같음 | 같은 파일의 TargetScent fixture | `support` |
| Attack Event | `modules._EVENTS`에 `Event(...)`. `side`와 플래그(`damaging`, `instant_strike`, `arms`, `disarms`, `leaves_ground`) | 위와 같음 | GroundTremor / DustPuff fixture | `support` |
| Collision Shape | `schema.SHAPE.variants`에 필드, `geometry.SHAPES`에 `ShapeKind`, `RESERVED_SHAPES`에서 제거 | `geometry`의 함수들, 검증 | `test_a_new_shape_is_one_registry_entry`, `test_the_shape_registry_matches_the_schema` | Godot 쪽 shape 생성은 Bridge에서 |
| Validation Rule | 해당 영역 모듈에 `@rule` 함수, 맨 위에 `define(영역, 상태, {코드: 뜻})` | `validate()`, 다른 규칙 | 실패·경고 표(`test_validation.py`의 `FAILURES` / `WARNINGS`)에 한 줄 | – |
| Legacy 계약 fixture | `godot_contract.LEGACY_PROFILES`에 `LegacyProfile(공격 상태, 패턴 ID, 사망 상태, 전용 비교 함수)`와 예제 문서 | registry 계약, 다른 기준 몬스터 | `test_godot_contract.py` | – |
| 데이터 기반 몬스터 유형 | 아직 없다. 런타임(STEP 4~5)이 생기면 `godot_contract`의 `data_driven` 계약에 검사를 추가 | – | – | – |

같은 정보를 두 곳에 써야 하는 지점은 하나 남아 있다: 새 shape는 `schema.SHAPE`(필드)와 `geometry.SHAPES`(계산)에
각각 등록한다. 한쪽은 데이터 모양, 다른 쪽은 수식이라 합치지 않았고, 테스트가 두 집합이 같은지 확인한다.

## 10. STEP 2 진입 인터페이스

| GUI 동작 | API | 반환 / 예외 |
|---|---|---|
| 새 문서 | `new_document(monster_id, display_name)` | `MonsterDocument` / `DocumentError`(ID 형식) |
| 열기 | `read_document(path)` | `(document, revision)` / `DocumentError`, `OSError` |
| 저장 | `write_document(path, document, expected_revision)` | 새 revision / `DocumentConflict`, `PermissionError`, `OSError` |
| 복제 | `clone_document(document, new_id, display_name=None)` | 초안. `source_binding`은 지워진다 / `DocumentError`(같은 ID) |
| 편집 | `document.apply(set_value(...), insert_item(...), …)` | 새 문서. 실패 시 `DocumentError`, 원본 불변 |
| ID 변경 | `document.apply(rename_id("state", old, new))` | 참조까지 갱신된 새 문서 |
| Undo/Redo | 문서 객체 목록과 커서 | 스냅샷은 불변이며 서로 독립 (`test_immutability.py`의 `History`가 최소 구현) |
| 수정 여부 | `document.fingerprint != revision` | – |
| 검증 | `validate(document, project=..., tick_rate=...)` | `Report`. `report.is_current(document)`가 거짓이면 다시 검증 |
| finding → 필드 | `parse_path(finding.path)` → `document.get(*path)` / `document.schema.field(document.data, path)` | `(node, value)` |
| Inspector 구성 | `document.schema.fields(document.data)`의 `(path, node, value)`, `node.info()` | type·default·range·unit·choices·reference·support·hint |
| 모듈 목록 | `document.schema.registry.modules` / `.conditions` / `.events`, `schema.module_params(id)` | 항목과 파라미터 node |
| 지원 여부 | `capabilities(node.support)`, `module.capabilities` | 단계별 bool |
| 카탈로그 | `monster_catalog(project, drafts=[...], registry_ids=None)` | 항목·문제·`is_id_free(id)` |
| 이미지 검사 | `inspect_image(project, relative)` | `(w, h, sha256)` / `FileNotFoundError`, `DocumentError`, `png.PngError` |

GUI가 지켜야 할 것:

- `document.data`를 바꾸려 하지 않는다. 바꿀 값은 `to_dict()`/`get()`으로 복사해 고친 뒤 `apply`에 넘긴다.
- 표시 문자열을 해석하지 않는다. 분기는 `finding.code`·`status`·`domain`·`remedy`로 한다.
- `NOT_EVALUATED`를 통과로 그리지 않는다. `report.unverified`가 그 목록이다.
- 초안과 게임 콘텐츠를 `MonsterEntry.source`·`registration`으로 구분한다. `registry_ids` 없이 얻은 카탈로그를
  "게임에 등록됨"으로 표시하지 않는다.
- 복제는 항상 새 ID를 요구한다. 복제본은 원본의 Godot 리소스에 묶이지 않는다.
- Legacy Import는 STEP 2 범위다. 이번 단계에는 없다.

바꾸면 안 되는 계약: Schema V1의 필드와 의미, 정규 직렬화(같은 내용 = 같은 바이트), finding 코드의 이름과 뜻,
`expected_revision=None`은 생성 전용이라는 의미, tick 변환식, 좌표 변환식.

## 11. 남은 제약

- 데이터 기반 런타임, Import/Export/Publish, GUI는 없다. `runtime`·`network`는 항상 `NOT_EVALUATED`다.
- `capabilities()`의 `editor_editable`·`godot_resource_export`·`data_runtime`·`multiplayer_verified`는 모든 지원 수준에서
  `False`다. 해당 기능이 생기는 단계에서 올린다.
- PNG 무결성 검사는 픽셀을 재구성하지 않는다. Godot이 실제로 import하는지는 Godot만 답한다.
- 편집 1회는 문서 전체를 정규화한다(§8).
- 저장 잠금은 협력적이다(§5).
- `tests/fixtures/contract_probe.json`은 기록된 probe다. 게임의 몬스터 값이 바뀌어 예제를 갱신하면
  `check_godot_contract.py --artifacts <dir>`의 `probe.json`으로 함께 갱신한다. 갱신하지 않으면
  `test_godot_contract.py`의 기준 테스트가 실패해 알려 준다.
- 코드 literal(idle 1.0초 등)은 probe로 읽을 수 없어 원본 파일 해시로만 감시한다.
