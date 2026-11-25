# Monster Editor 로드맵

각 단계는 앞 단계의 완료 기준을 전제로 한다. 미구현 기능은 검증에서 `NOT_EVALUATED`로 남기고, 어느 단계에서도
기존 게임·기존 몬스터·Python Map Editor의 회귀를 허용하지 않는다.

| 단계 | 주제 | 게임 런타임 변경 | 프로토콜 변경 |
|---|---|---|---|
| STEP 1 | Architecture / Schema / Core Validation | 없음 | 없음 |
| STEP 2 | Editor GUI Foundation / Monster Catalog | 없음 | 없음 |
| STEP 3 | Animation / Collision Editor | 없음 (표현 리소스 생성만) | 없음 |
| STEP 4 | Attack Pattern Editor / Combat Runtime | `DataEnemyAgent` 전투부 추가 | 20 → 21 |
| STEP 5 | AI Graph Editor / Behavior Runtime | 행동 실행기·모듈 추가 | 없음 |
| STEP 6 | Godot Runtime Test / Map Editor Integration | 없음 | 없음 |
| STEP 7 | Stabilization / Windows EXE Distribution | 없음 | 없음 |

## MONSTER-STEP 1 — Architecture / Schema / Core Validation (이번 단계)

- **범위**: 기존 시스템 분석, `.rtcmonster` Schema V1, Python core(문서·직렬화·저장·검증), 예제 3개, Godot 계약 검사,
  설계 문서 5개.
- **완료 기준**: Python 테스트 통과, contract check 통과, `check_project.py`와 Map Editor 테스트 무회귀.
- **남긴 것**: 데이터 런타임, Bridge의 Import/Export/Publish, GUI — 전부 아래 단계.

## MONSTER-STEP 2 — Editor GUI Foundation / Monster Catalog

**선행 조건**

1. STEP 1 병합.
2. 공통 코드 추출 결정: `storage.py`(원자 저장·잠금), 경로 안전 규칙, `GodotSession`/`run_child`/`ProcessScope`를
   Map Editor와 공유할지. Map Editor는 flat module로 PyInstaller에 묶이므로, 추출한다면 Map Editor EXE 빌드·패키지
   검증(`verify_windows_package.py`)을 같은 변경에서 다시 통과시켜야 한다. 추출하지 않으면 중복을 유지하고 양쪽
   테스트로 동등성을 지킨다.
3. PySide6 버전은 Map Editor의 pin(`PySide6-Essentials==6.11.3`)을 그대로 쓴다.

**구현 범위**

- 창 골격: 프로젝트 설정(프로젝트 폴더, Godot 실행 파일, 작업 폴더 — Map Editor 설정 화면과 같은 규칙),
  카탈로그 패널, Inspector, 검증 패널.
- **Monster Catalog**: 게시된 몬스터(`project.published_monsters`)와 초안(`.rtcmonster` 폴더)을 구분해 표시.
  분류·태그·rank로 필터. 초안은 게임 콘텐츠처럼 보이지 않는다.
- 새로 만들기(`new_document`), 복제(새 `monster_id` 필수), 열기, 저장, 다른 이름으로 저장, 삭제(초안 파일만).
- **Inspector 자동 구성**: `schema.DOCUMENT`와 `modules.MODULES`의 `describe()`에서 폼을 만든다. 타입·범위·단위·
  기본값·지원 수준을 표시하고, `planned` 필드는 "게임에 적용되지 않음"으로 표시한다. 필드별 하드코딩 금지.
- 편집 대상: `metadata`, `stats`, `loot`, `movement`, `sensors`. (애니메이션·판정·공격·AI는 값 표시만)
- Undo/Redo: `MonsterDocument`가 불변이므로 문서 스냅샷 스택.
- 저장 안전: 외부 변경 감지(`DocumentConflict`) 시 덮어쓰기·다시 열기·다른 이름 저장 선택. 저장 실패 시 원본 유지.
- 검증 패널: 11개 영역 상태, finding 클릭 시 해당 필드로 이동. `NOT_EVALUATED`를 회색 "미검사"로 표시(통과 아님).
- **Bridge `inspect_monsters` / `import_monster`**: `tools/monster_bridge/`에 읽기 전용 명령 추가. Import는 legacy
  몬스터의 값과 `source_binding`(파일 해시, `editability`)을 채운다. STEP 1의 probe 출력이 그 원료다.
  두 예제를 Import 결과와 대조해 손으로 쓴 것과 같아지는지 확인한다.

**테스트**

- core 테스트 유지 + Qt source smoke(100/150/200% 배율, 네이티브 플랫폼 — offscreen에서는 단축키 검사가 실패한다).
- Import 왕복: `import_monster(sewer_beetle)` → 문서 → contract check 통과.
- 무변경 열기→저장의 바이트 동일성, 외부 변경 충돌 UI, Undo/Redo 후 문서 동일성.

**완료 기준**: 비개발자가 카탈로그에서 기존 몬스터를 열어 값을 보고, 새 초안을 만들어 스탯·전리품을 편집·저장·
재열기할 수 있다. 게임 파일은 하나도 바뀌지 않는다.

**하지 않는 것**: 게시, sprite 편집, 판정 편집, 타임라인, AI 그래프, EXE.

## MONSTER-STEP 3 — Animation / Collision Editor

- **선행**: STEP 2. 데이터 런타임은 아직 필요 없다.
- **범위**: 이미지 등록(sheet 격자 분할 `slice_grid`, 개별 PNG, 크기·해시 기록), clip 편집(frame 순서·지속 시간·FPS·
  loop), 역할 연결, 재생 미리보기, `visual_offset`/`visual_scale`과 bottom-center 프리셋, body·hurtbox·hitbox 시각
  편집(사각형·원), 좌우 반전 미리보기, frame별 hurtbox override 편집.
  Bridge `stage_monster`의 표현부: Godot 안에서 `SpriteFrames`와 `EnemyAnimationProfile`을 `ResourceSaver`로 생성.
- **테스트**: 생성한 `SpriteFrames`를 probe로 다시 읽어 문서와 대조(딱정벌레·개구리의 기존 리소스와 의미상 동일),
  `EnemyAnimationProfile.validation_errors()` 빈 목록, sprite↔actor 변환의 화면 좌표 검증, headless 서버가 텍스처를
  로드하지 않는지.
- **완료 기준**: 새 아트로 clip과 판정을 만들고, staging 프로젝트에서 legacy actor에 profile을 붙여 그려진다.

## MONSTER-STEP 4 — Attack Pattern Editor / Combat Runtime

- **선행**: STEP 3. **이 단계부터 게임 런타임과 프로토콜이 바뀐다.**
- **범위(Godot)**: `DataEnemyDefinition`(EnemyDefinition 상속), 공용 `data_enemy.tscn` + `DataEnemyAgent`,
  Attack Timeline Executor(정수 tick), 몬스터 hitbox(기존 `HitboxComponent` 재사용 + 인스턴스 단위 공유 hit 목록),
  hurtbox 집합 구성, `RangeStrike`·`EnableHitbox`·`DisableHitbox`·`ApplyImpulse`·`ApplyMovement`·facing lock,
  패턴 선택기와 쿨다운. `EnemyRuntimeSnapshot`에 `attack_pattern`·`attack_seq`·`attack_elapsed` 추가,
  `NetworkProtocol.VERSION` 21.
- **범위(Editor)**: 패턴 목록, phase·이벤트 타임라인(초 + tick + 실제 실행 초 표시), hitbox 구간 편집,
  clip과 나란히 보기(clip은 참고 표시, 시간을 결정하지 않음).
- **테스트**: 단위(타임라인 tick, 대상당 1회, 다단 히트 간격, 중단 시 정리, 긴 프레임), Sewer Rat Prototype을 테스트
  fixture로 스폰해 두 패턴이 계약대로 맞는지, ENet 2·3인(공격·피해 복제, 중간 접속 시 `attack_elapsed`, 사망·전리품
  중복 없음, 월드 격리), 기존 몬스터 무회귀, protocol 불일치 handshake.
- **완료 기준**: 고정 행동(제자리)의 데이터 몬스터가 패턴을 실행해 플레이어에게 피해를 준다. legacy 몬스터는
  그대로다.

## MONSTER-STEP 5 — AI Graph Editor / Behavior Runtime

- **선행**: STEP 4.
- **범위(Godot)**: Behavior Executor(전환 평가, interrupt, 원자 구간), 모듈 `Wait`·`GroundPatrol`·`ChaseTarget`·
  `FaceTarget`·`Hop`·`ExecuteAttackPattern`·`HurtReaction`·`Death`, 조건 전부(`contract` 수준), 정수 tick 타이머.
  개구리 미지원 2건 해결(Schema V2 후보: 원점 기준 접촉 판정, `Hop`의 근거리 속도).
- **범위(Editor)**: 노드 그래프(상태 = 노드, 전환 = 간선, 우선순위 표시), 조건 편집기, 모듈 Inspector,
  도달 불가·무한 대기·즉시 순환의 실시간 표시.
- **테스트**: 같은 시나리오에서 legacy 딱정벌레와 데이터 딱정벌레의 상태 기록·위치 비교, 개구리 동일 비교
  (`test_frog_enemy.gd`의 시나리오 재사용), ENet(타깃 변경, 연결 해제, leash 복귀), Sewer Rat Prototype 전체 행동.
- **완료 기준**: 딱정벌레와 동등한 데이터 몬스터가 숲·하수도에서 legacy와 구분되지 않게 동작한다.

## MONSTER-STEP 6 — Godot Runtime Test / Map Editor Integration

- **선행**: STEP 5.
- **범위**: Bridge `validate_export`·`runtime_test`·`publish`·`recover`(다중 파일 저널), 편집기의 "Godot에서 테스트"
  (격리된 프로젝트 사본에서 권위 실행 기록 수집), 게시 승인 UI, 삭제 시 맵 참조 검사,
  Map Editor 카탈로그에 새 몬스터가 나오는지 확인(코드 변경 없이 되는 것이 목표).
  검증의 `runtime`·`network`·`publish` 영역이 이 단계에서 처음 PASS가 될 수 있다.
- **테스트**: 게시 중단·실패 주입 후 복구, 외부 변경 충돌, 게시한 몬스터를 Map Editor V6 문서에 배치해 게임에서
  스폰, 기존 V6 문서 무회귀, 반복 안정성(Map Editor stability gate와 같은 방식).
- **완료 기준**: 비개발자가 몬스터를 만들어 게시하고 맵에 배치해 게임에서 싸울 수 있다.

## MONSTER-STEP 7 — Stabilization / Windows EXE Distribution

- **선행**: STEP 6.
- **범위**: Windows x64 OneDir EXE(PyInstaller, Map Editor spec 재사용), 패키지 검증 스크립트, 장시간·반복 안정성,
  한글 경로, 고DPI, 오류 메시지 정리, 사용자 문서.
- **완료 기준**: 깨끗한 Windows에서 ZIP을 풀어 실행하고 STEP 6의 전체 흐름이 통과한다.

## 결정이 필요한 사항

| 사항 | 언제까지 | 선택지 |
|---|---|---|
| 공통 Python 패키지 추출 | STEP 2 시작 | 추출(Map Editor EXE 재검증 필요) / 중복 유지 |
| 개구리 접촉 판정 | STEP 5 | `ContactStrike` 이벤트 추가(V2) / hitbox 근사 수용 |
| `causes_hurt` 존중 여부 | STEP 5 | 데이터 몬스터만 존중 / legacy도 수정 / 현행 유지 |
| 정수 tick 타이머를 legacy에도 적용할지 | STEP 5 | 적용(경계 tick이 바뀔 수 있음) / 데이터 몬스터만 |
| 기존 두 몬스터의 전환 시점 | STEP 6 이후 | 전환 / legacy 유지 |
