# Monster Editor 아키텍처 (MONSTER-STEP 1)

몬스터마다 GDScript를 새로 쓰는 대신, 등록된 행동 모듈과 데이터의 조합으로 몬스터를 만들기 위한
기반 설계다. 이 문서는 구조와 결정 이유를 다룬다. 필드 정의는
[monster_editor_schema_v1.md](monster_editor_schema_v1.md), 실행 규칙은
[monster_editor_runtime_contract.md](monster_editor_runtime_contract.md), 기존 몬스터와의 관계는
[monster_editor_compatibility.md](monster_editor_compatibility.md), 이후 단계는
[monster_editor_roadmap.md](monster_editor_roadmap.md), 안정화에서 내린 결정·공개 API·확장 가이드는
[monster_editor_step1_stabilization.md](monster_editor_step1_stabilization.md)에 있다.

## 1. 이번 단계에서 실제로 있는 것과 없는 것

| 구분 | 상태 |
|---|---|
| `.rtcmonster` Schema V1, Python 문서 모델, 정규 직렬화, 안전한 파일 저장 | **구현됨** (`tools/python_monster_editor/rtcmonster/`) |
| 정적 검증기 (11개 영역, 4개 상태, 선언된 finding 코드) | **구현됨** (`rtcmonster/validation/`) |
| 불변 문서, 원자적 편집 API, 모듈 레지스트리 확장, 콘텐츠 카탈로그, PNG 무결성 검사 | **구현됨** (안정화) |
| 예제 문서 3개 (Sewer Beetle, Frog, Sewer Rat Prototype) | **작성됨** (`tools/python_monster_editor/examples/`) |
| Godot 계약 검사: 환경 / 등록된 모든 몬스터(registry) / 기준 몬스터(legacy) | **구현됨** (`tools/monster_bridge/contract_probe.gd`, `godot_contract.py`, `check_godot_contract.py`) |
| 데이터 기반 AI·전투 런타임 (`DataEnemyAgent` 등) | **없음** — 계약만 확정. MONSTER-STEP 4~5 |
| Godot Bridge의 Import / Export / Publish | **없음** — 인터페이스만 확정. MONSTER-STEP 2~6 |
| Monster Editor GUI, EXE | **없음** — MONSTER-STEP 2~7 |

게임은 지금도 기존 GDScript로 몬스터를 실행한다. 이번 단계는 게임 런타임 코드를 한 줄도 바꾸지 않았다.
추가된 Godot 파일은 읽기 전용 probe 하나뿐이다. 배포 preset `Windows Desktop`은 `tools/*`를 제외한다
(`Windows Desktop 2` preset은 기존 `tools/map_bridge`와 마찬가지로 제외하지 않는다 — 이번 단계에서 preset은 바꾸지 않았다).

## 2. 기존 몬스터 시스템 분석

기준: master `57ac9b0`, Godot 4.7.2, physics 60 Hz(`project.godot`에 설정이 없어 엔진 기본값. probe가 실측).

### 2.1 구성요소와 책임

| 구성요소 | 위치 | 책임 |
|---|---|---|
| `EnemyDefinition` | `data/definitions/enemy_definition.gd` | 정적 콘텐츠: 이름, actor scene, 체력·공격력·이동속도·추격거리·공격거리, 진영, 전리품 테이블 ID. 검증 시 scene을 instantiate해 root가 `EnemyAgent`인지 확인 |
| `ContentRegistry` | `autoload/content_registry.gd` | `res://data/content`를 재귀 로드해 ID로 등록. 중복 ID·타입 오류를 보고. `actor_scene`이 여기서 preload되므로 scene이 텍스처를 직접 참조하면 headless 서버까지 따라 들어간다 |
| `EnemyAgent` | `gameplay/actors/enemies/enemy_agent.gd` | `CharacterBody2D`. 중력(1100), 타깃 선택, 상태 전환, 피해 반응, 넉백, 효과(`EffectController`), 사망. `%States` 자식 노드를 이름(snake_case)으로 등록 |
| `EnemyState`와 6개 상태 | `gameplay/actors/enemies/*_state.gd` | `enter()`와 `physics_tick(delta) -> 다음 상태 ID`. 시간·거리 상수는 대부분 코드 literal |
| `FrogAgent`와 8개 상태 | `gameplay/actors/enemies/frog/` | hop 전용 이동, 가장자리·벽 감지, leash, 공격 쿨다운. export 변수 17개 |
| `HurtboxComponent` / `HealthComponent` | `gameplay/components/` | 진영 필터 → `receive_damage` → `max(1, amount - defense)`. 피격 후 0.35초 무적 |
| `DamageContext` | `gameplay/components/damage_context.gd` | 피해량, 종류, source, 진영, knockback, `causes_hurt`, `can_be_evaded` |
| `EnemyAnimationProfile` / `EnemyAnimationPresenter` | `presentation/` | 문자열 경로로 지연 로드되는 표현 전용 구조. 상태 ID·속도·방향·체력만 읽는다 |
| `EnemySpawnManager` | `world/multiplayer/enemy_spawn_manager.gd` | 권위 스폰, entity ID 등록, 사망 시 kill 기록·전리품 roll·despawn, 접속 peer에게 roster 전송 |
| `NetworkEnemyComponent` / `EnemyRuntimeSnapshot` | `gameplay/components/`, `core/models/network/` | 20 Hz 비신뢰 transform + 체력·상태 변경 시 신뢰 snapshot. 클라이언트는 보간만 한다 |
| Python Map Editor V6 | `tools/python_map_editor/` | Enemy 스폰이 `enemy_id` 문자열을 참조. 카탈로그는 `data/content/enemies/*.tres`의 `id` 줄을 읽는다(`discover_enemies`) |

### 2.2 권위 tick 한 번 (`EnemyAgent._physics_process`)

```
타깃 선택 → 중력 → 현재 상태 physics_tick → (반환값이 있으면) 상태 전환 1회 → move_and_slide → velocity.x로 facing 갱신
```

- 상태 전환은 tick당 최대 한 번이다. 한 tick 안에서 연쇄 전환이 일어나지 않는다.
- 타깃은 "살아 있고, 같은 월드·같은 부모이며, `chase_range × 1.35` 안"이면 유지하고, 아니면 가장 가까운 유효
  플레이어로 바꾼다.
- 공격은 hitbox가 아니다. `perform_attack()`이 `attack_range + 12` 거리 검사 후 대상의 `HealthComponent`에
  `DamageContext(attack_power, physical, knockback = (±100, -30))`를 직접 넘긴다.
- 피해를 받으면 종류와 무관하게 `hurt`로 전환한다(`causes_hurt`를 보지 않는다 — 주기 피해도 hurt를 다시 시작한다).
- 체력이 0이 되면 `dead`: 충돌 레이어를 끄고 0.45초 뒤 `finished` → 전리품 → despawn.

### 2.3 재사용 가능한 것

`EnemyDefinition`, `ContentRegistry`, `HurtboxComponent`, `HealthComponent`, `DamageContext`, `EffectController`,
`EnemySpawnManager`, `NetworkEnemyComponent`, `EnemyRuntimeSnapshot`, `EnemyAnimationProfile`/`Presenter`,
`LootTableDefinition`은 데이터 기반 몬스터도 그대로 쓴다. 플레이어용 `HitboxComponent`(활성화 순간 즉시 sweep,
활성 구간 단위 중복 타격 방지, 자체 타이머 없음)는 몬스터 hitbox의 요구와 정확히 같다.
Python 쪽은 Map Editor의 원자적 저장·해시 충돌 감지 알고리즘, 스냅샷 기반 `GodotSession`, Job Object 프로세스
관리, 게시 저널을 계승한다.

### 2.4 구조적 문제 (데이터 기반 제작을 막는 것)

1. **수치가 코드에 있다.** idle 1.0초, patrol 반경 90·속도 0.55배, hurt 0.25초, 공격 여유 12 px, 넉백 (100, -30)은
   literal이다. 편집기가 읽을 수도 바꿀 수도 없다.
2. **몬스터 하나가 스크립트 묶음이다.** 개구리는 agent 1개 + 상태 8개. 새 이동 방식마다 같은 양이 필요하다.
3. **공격 판정에 모양이 없다.** 원점 간 거리 한 번이 전부라 공격 범위를 그릴 수 없고 다중 타격·광역이 불가능하다.
4. **피격 반응을 조절할 수 없다.** 모든 피해가 hurt를 다시 시작한다. 슈퍼아머·경직 저항을 표현할 자리가 없다.
5. **시간이 float 누적이다.** `remaining -= delta` 뒤 비교라 경계 tick이 반올림에 좌우된다.
   `HealthComponent`의 무적 시간은 render `_process`에서 줄어든다.
6. **복제 상태가 5개뿐이다.** 클라이언트는 `MOVING인데 서 있음 = 웅크림`처럼 추론한다. 공격이 여러 개면 어느
   공격인지 알 수 없다.
7. **상태 이름이 계약이다.** presenter가 `&"prepare"`, `&"attack"` 문자열을 직접 비교한다.

## 3. 전체 아키텍처

```text
Monster Editor (Python / PySide6)            ← MONSTER-STEP 2~5
    │  편집 · 미리보기 · 정적 검증
    ▼
Monster Document (.rtcmonster, JSON)         ← 이번 단계: 모델 · 직렬화 · 저장 · 검증
    │
    ▼
Godot Monster Bridge (tools/monster_bridge)  ← 이번 단계: 읽기 전용 contract probe만
    │  Import · Export · Validation · Runtime Test · Publish/Recovery
    ▼
Godot Content Resources
    ├─ EnemyDefinition (기존) / DataEnemyDefinition (신규, EnemyDefinition 상속)
    ├─ EnemyAnimationProfile + SpriteFrames (기존, 문자열 경로로만 참조)
    └─ LootTableDefinition (기존)
    ▼
Godot Monster Runtime
    ├─ Legacy: EnemyAgent / FrogAgent + 상태 노드          (그대로 유지)
    └─ Data-driven: DataEnemyAgent (EnemyAgent 상속)        ← MONSTER-STEP 4~5
         Behavior Executor · Action Modules · Attack Timeline Executor · Collision Resolver
    ▼
EnemySpawnManager · NetworkEnemyComponent · EnemyAnimationPresenter (공용)
    ▼
ContentRegistry → Python Map Editor 카탈로그 → Enemy Spawn 배치
```

| 계층 | 책임 | 하지 않는 것 |
|---|---|---|
| Editor | 입력, 문서 편집, 저장, 시각 미리보기, 정적 검증 | 피해 계산, AI 실행. 미리보기는 표시일 뿐이다 |
| Document | 몬스터 한 종의 편집 원본. 코드를 담지 않는다 | 런타임 상태(현재 체력, 쿨다운 잔여) |
| Bridge | 문서 ↔ Godot 리소스 변환, 엔진에서의 검증, 원자적 게시와 복구 | Python에서 `.tres`/`.tscn` 문자열 조립 |
| Runtime | AI, 이동, 충돌, 피해, 상태 전환, 복제. 편집기 없이 동작 | 텍스처·사운드 로드 (headless) |
| Presentation | sprite, 사운드, VFX | 판정·상태·물리 변경 |

### 3.1 데이터 기반 몬스터가 Godot에 놓이는 방식 (확정된 설계, 미구현)

- **`DataEnemyDefinition extends EnemyDefinition`** — 기존 7개 필드에 behavior·attack pattern·collision 데이터와
  `animation_profile_path`(문자열)를 더한다. `registry.get_definition(id) is EnemyDefinition`이 그대로 참이라
  `EnemySpawnManager`, `EnemyRuntimeSnapshot.from_payload`, Map Editor 카탈로그, 기존 스폰 마커가 전부 수정 없이
  동작한다. 텍스처를 참조하지 않으므로 `data/content`에 둘 수 있다.
- **공용 actor scene 하나** (`data_enemy.tscn`, root `DataEnemyAgent extends EnemyAgent`). 몬스터마다 scene을 만들지
  않는다. Body·Hurtbox·Hitbox shape는 `_ready`에서 definition의 collision 데이터로 구성한다.
- **`DataEnemyAgent`는 `%States` 노드를 쓰지 않는다.** 상태 실행기가 데이터의 state 목록을 돌리고,
  `current_state_id`와 `state_changed`는 기존과 같은 의미로 유지한다. 그래서 `NetworkEnemyComponent`와 presenter가
  바뀌지 않는다.
- 모듈과 조건, 타임라인 이벤트는 GDScript로 **한 번** 구현되고 ID로 등록된다. 문서는 ID와 파라미터만 가진다.

## 4. 주요 결정과 대안

| 결정 | 선택 | 버린 대안과 이유 |
|---|---|---|
| 스키마 정의 방식 | 선언적 spec 트리 하나(`schema.py`)에서 decode·범위 검증·기본값·문서 표를 모두 파생 | dataclass 수십 개: 필드마다 검증·기본값·문서를 따로 써야 해 어긋난다. `jsonschema` 라이브러리: 의존성 추가, 참조 무결성·시간 규칙은 어차피 직접 써야 한다 |
| 읽기 실패와 검증 실패의 구분 | **모양**(타입, 모르는 필드, ID 형식, 유한한 숫자)이 틀리면 열 수 없다. **범위·참조·의미**가 틀리면 열리고 finding으로 표시된다 | 전부 예외: 음수 체력 하나 때문에 문서를 못 열면 고칠 수도 없다. 전부 finding: 타입이 틀린 값을 들고 있는 모델은 모든 코드가 방어해야 한다 |
| 모르는 필드 | 거절 (`editor_metadata.ui`, `source_binding.passthrough`만 불투명 JSON 허용) | 무시 후 보존: 오타가 조용히 저장된다. Map Editor와 같은 정책 |
| AI 표현 | FSM + 등록된 Action Module + 조건 조합 + 공격 패턴 선택기 | Behavior Tree / Utility AI: 기존 두 몬스터가 FSM이고 비개발자가 그래프로 읽기 쉽다. 확장 경계는 module·condition 레지스트리. 스크립트 삽입: 임의 코드 실행이라 금지 |
| 시간 단위 | 초(실수)로 저장, 권위 실행은 정수 tick으로 한 규칙에 따라 양자화 | 프레임 번호: 애니메이션 FPS를 바꾸면 판정이 움직인다. tick 수 저장: tick rate가 바뀌면 문서가 전부 틀린다 |
| 공격 판정 | 패턴이 시간 구간으로 hitbox를 켜고 끈다. 기존 "거리 1회" 판정은 `RangeStrike` 이벤트로 그대로 표현 | hitbox만 허용: 기존 몬스터를 정확히 표현할 수 없게 된다 |
| 좌표 | actor-local 픽셀, 오른쪽을 본 기준. 좌우 반전은 중심 x만 | sprite 기준 좌표: 아트 크기를 바꾸면 판정이 움직인다 |
| 데이터 기반 definition | `EnemyDefinition` 상속 | 별도 ContentDefinition: 스폰·snapshot·Map Editor가 전부 두 타입을 알아야 한다 |
| 리소스 생성 | Godot 프로세스 안에서 `ResourceSaver`/`PackedScene` | Python 문자열 조립: UID·ext_resource·타입 직렬화를 흉내 내야 한다. Map Editor가 이미 같은 결론 |
| 저장 코드 | Map Editor 알고리즘을 monster 패키지 안에 다시 구현 | import 공유: Map Editor는 flat module로 frozen EXE에 묶여 있어 지금 구조를 바꾸면 안정화된 배포물을 건드린다. 공통 패키지 추출은 STEP 2 과제 |
| 기존 몬스터 | 그대로 두고 문서로 **기술**만 한다 | 지금 전환: 런타임이 없고, 개구리는 V1로 완전히 표현되지 않는다 |

## 5. Python 패키지 구성

```text
tools/python_monster_editor/
├─ rtcmonster/
│  ├─ spec.py          필드 node와 UI 중립 메타데이터(info), 경로 안전 규칙, 지원 수준별 capability
│  ├─ modules.py       Registry: Action Module / Condition / Event 항목과 그 의미 플래그·검증 콜백
│  ├─ schema.py        Schema(registry): 문서 트리, 참조 선언(Id.ref), 범용 순회 fields()
│  ├─ document.py      MonsterDocument(불변 FrozenDict/FrozenList), 정규 encode/decode, fingerprint, clone
│  ├─ editing.py       Edit 5종과 원자 적용(apply), ID 이름 변경
│  ├─ storage.py       원자적 저장, 잠금, 해시 기반 외부 변경 감지, 남은 임시 파일 정리
│  ├─ timing.py        초 ↔ tick, clip 시간, 같은 tick 이벤트 순서(schedule), 타임라인 표
│  ├─ geometry.py      SHAPES 레지스트리, 좌우 반전, sprite ↔ actor 변환, sheet 격자 분할
│  ├─ catalog.py       콘텐츠 폴더 scan(중복·오류 보고), 몬스터 카탈로그(발견 / Godot 확인 / 초안)
│  ├─ png.py           PNG 헤더와 무결성 검사
│  ├─ project.py       프로젝트 파일 접근(경로 안전, 이미지 검사, 원본 파일 상태)
│  ├─ validation/      report(코드·Finding·Report) · context(Context, ProjectView, @rule)
│  │                   · structure · assets · animation · combat · behavior · compatibility
│  └─ reference.py     schema·registry·코드 선언에서 문서 표를 생성
├─ examples/           sewer_beetle · frog · sewer_rat_prototype
├─ tests/              pytest (표준 라이브러리 외 의존성 없음)
├─ validate.py         명령행 검증
├─ godot_contract.py   probe 결과 평가(순수 함수): environment / registry / legacy / data_driven / behavior
├─ check_godot_contract.py          probe 실행과 보고, contract_report.json
├─ check_contract_extensibility.py  격리된 프로젝트 사본에서 신규 몬스터 시나리오
└─ benchmark.py        규모별 측정
tools/monster_bridge/
└─ contract_probe.gd / .tscn   읽기 전용 probe
```

의존 방향은 `spec ← modules ← schema ← document / editing ← validation ← 도구` 한쪽이다. 범용 코드(schema,
document, editing, validation, reference)는 모듈·조건·이벤트·몬스터의 **이름을 모른다** — 의미는 레지스트리 항목의
플래그에 있고, `tests/test_extensibility.py`가 범용 코드에 그런 문자열이 없음을 검사한다. 새 몬스터 종류나 모듈이
늘어도 이 코드들은 바뀌지 않는다.

core는 Qt와 Godot를 import하지 않는다. GUI가 붙어도 이 경계는 유지한다. 빈 디렉터리나 stub 클래스는 만들지 않았다.

## 6. Godot Bridge 계약

Map Editor Bridge(`tools/python_map_editor/godot_bridge.py`, `tools/map_bridge/`)의 실행 규약을 그대로 따른다:
프로젝트 스냅샷 복사본에서 실행, 분리된 사용자 데이터, protocol·request_id·operation이 일치하는 JSON 결과,
종료 코드 0, 엔진 오류 로그가 있으면 결과 파일이 있어도 실패.

| 명령 | 입력 | 출력 / 검증 | 구현 단계 |
|---|---|---|---|
| `contract_probe` | 없음 | 모든 EnemyDefinition의 실제 값·scene 구조·필수 컴포넌트·profile·loot, 실행 결과. 특정 몬스터의 scene 구조를 전제하지 않는다 | **STEP 1 (구현됨)** |
| `inspect_monsters` | 없음 | 게시된 몬스터 ID·이름·runtime 종류·원본 파일 해시 | STEP 2 |
| `import_monster` | monster_id | legacy 몬스터의 편집 가능 범위와 값 (`source_binding` 포함) | STEP 2 |
| `validate_document` | 문서 | 리소스 참조, 타입, 모듈 ID를 엔진에서 확인 | STEP 3~5 |
| `stage_monster` | 문서 | 복사본에 `DataEnemyDefinition`, profile, SpriteFrames, loot 생성 | STEP 3~5 |
| `validate_export` | staging | 새 프로세스에서 재로드, ContentRegistry 검증, 스폰, 상태 진행 | STEP 6 |
| `runtime_test` | 문서, 시나리오 | 실제 actor를 권위로 실행한 기록 | STEP 6 |
| `publish` / `recover` | 승인된 staging | 저널 기반 다중 파일 원자 게시, 실패 시 rollback | STEP 6 |

**원본 보호.** 문서는 파생에 쓰인 모든 프로젝트 파일의 SHA-256을 `source_binding.files`에 갖는다. 게시 직전 다시
비교해 하나라도 다르면 중단한다. 여러 파일을 한 번에 게시할 때는 Map Editor의 `pair-*` 저널 방식을 N개 파일로
일반화한다: 모든 파일의 이전·이후 해시를 기록 → 임시 파일로 준비 → 교체 → 사후 해시 확인 → 완료 기록. 파일
하나의 저장 성공은 게시 성공이 아니다. 완료 기록 전 중단은 다음 실행에서 이전 상태로 되돌린다.

**경로 보안.** 문서의 모든 경로는 프로젝트 상대 POSIX 경로다. 절대 경로, 드라이브 문자, `\`, `..`, `.`, 빈 구간,
끝이 공백·점인 구간은 decode에서 거절한다(`safe_relative_path`). 파일을 읽을 때는 심볼릭 링크·junction을 거치지
않는지, resolve한 경로가 프로젝트 안인지, 일반 파일인지, 크기 한도(이미지 16 MB, 8192 px) 안인지 확인한다
(`resolve_project_file`). 문서는 scene·script 경로를 **실행 대상으로** 가질 수 없다: 모듈·조건·이벤트는 레지스트리
ID이고, `source_binding`의 경로는 해시 비교에만 쓴다. Godot 프로세스가 실행하는 scene은 Bridge에 고정된 것뿐이다.

## 7. 검증 결과의 의미

| 상태 | 의미 |
|---|---|
| `PASS` | 그 영역을 검사했고 문제가 없다 |
| `WARNING` | 열리고 저장되지만 의도와 다를 가능성이 높다 |
| `FAIL` | 게시할 수 없다 |
| `NOT_EVALUATED` | 검사하지 않았다. 성공이 아니다 |

`schema` · `references` · `assets` · `animation` · `collision` · `attack` · `ai` · `compatibility`는 Python이 정적으로
판정한다. `runtime`과 `network`는 Godot을 실행해야만 판정할 수 있어 Python 검증에서는 항상 `NOT_EVALUATED`다.
`publish`는 정적 실패나 미지원 항목이 있으면 `FAIL`, 아니면 게시 기능이 생길 때까지 `NOT_EVALUATED`다.
프로젝트 폴더 없이 검증하면 파일을 읽어야 하는 검사(이미지, 몬스터 ID 중복, loot, 원본 해시)도 `NOT_EVALUATED`다.
