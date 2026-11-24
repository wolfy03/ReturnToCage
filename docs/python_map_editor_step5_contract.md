# PY-STEP 5 Godot 데이터 계약

기준은 공식 Windows Godot `4.7.2.stable.official.ed1daf0bf`와 ReturnToCage의 `0dfcf10`이다. 아래 표는 Scene과 Resource를 실제로 읽고 쓰는 계약이다. Python 문서 편집과 저장은 JSON만 사용한다.

| Python V4 | Godot 저장 대상 | 보존 및 검증 |
| --- | --- | --- |
| `region_id`, `display_name` | `RegionDefinition.id`, `display_name` | 기존 지역의 ID와 표시 이름은 잠근다. 신규 ID는 ContentRegistry와 대상 경로에서 중복을 거부한다. |
| `width`, `height`, 레이어 표시·잠금 | Python 문서 | Godot RegionDefinition에는 캔버스 크기나 편집기 레이어 상태가 없다. 물리 경계를 추가하지 않는다. |
| 플랫폼, 장식 | `FieldPlatform`, 기존 지원 정적 사각형, `FieldDecoration` | 기존 Scene 계약의 위치·크기·회전·Collider·PNG·owner 규칙을 재사용한다. |
| `RegionPoint.id`, `kind`, `point_id`, `position`, `requires_landing` | `RegionPoint` Marker2D, enum ENTRY=0 / ESCAPE=1, `StringName` ID | 원본의 경로, 부모, owner, basis는 유지하고 월드 위치 변경을 부모 로컬 좌표로 변환한다. 새 표식은 `RegionPoints` 아래 배치한다. |
| ENTRY / ESCAPE ID | `RegionDefinition.entry_point_ids`, `escape_point_ids` | 각 종류별 중복 금지. 하수구처럼 두 종류 사이에 문자열을 공유할 수 있다. 기존 목록의 순서를 보존한다. 첫 ENTRY는 서버 기본 앵커다. |
| `SpawnPoint.id`, `spawn_index`, `position` | 지역 루트 바로 아래의 `PlayerSpawnPoint` Marker2D | 저장 인덱스 0~3. `NetworkManager.MAX_PLAYERS`와 동일하다. 런타임은 직접 자식만 읽는다. |
| `environment.path`, `uid`, `loading_color` | `RegionDefinition.environment_path`, `environment_loading_color` | 경로는 문자열이다. UID가 있으면 리소스 경로·실제 UID·등록 경로가 일치해야 한다. 타입은 EnvironmentDefinition이어야 한다. |
| `template_ladder` | 공식 Platform 템플릿의 `ladder_default` 배치 의도 | 기존 지역의 임의 Climbable은 원본에 보존한다. |
| `connections` | 대응되는 런타임 필드 없음 | V4의 ESCAPE→지역/ENTRY는 디자인 데이터다. 이 연결이 있는 문서의 게시는 차단한다. |

신규 지역은 `addons/rtc_field_editor/region_scaffold.tscn`을 인스턴스화한다. AdventureRegion 루트는 NetworkEntityRegistry, LootSpawnManager, EnemySpawnManager, PlayerSpawnManager와 공식 Terrain/Decorations/SpawnPoints/GatherPoints/RegionPoints/Climbables 그룹을 그대로 사용한다. 신규 RegionDefinition은 GDScript의 초기값을 유지한다. 공식 Wizard의 기본 위험도는 1이며 설명의 기본값은 빈 문자열이다. 추천 장비·적·자원·잠금·귀환 아이템 정책은 편집기의 별도 설정이 없다면 리소스 선언값을 사용한다. 기존 리소스를 다시 저장할 때에는 편집 범위 외 모든 저장 속성, 장면과 리소스 UID, Scene 의존 관계를 보존한다.

## 이동과 게시

- **Settlement → Adventure**는 `SettlementExitDefinition.id`와 `connected_region_ids` 및 공유 `entry_point_id`를 사용한다. `GameSession`의 해금·출구 정책이 적용되고 `SceneRouter`가 월드를 교체한다. 신규 지역 파일을 게시해도 정착지 출구와 해금 정책은 별도로 구성해야 한다.
- **Adventure → Settlement**에서는 `AdventureRegion`이 ESCAPE 마커에서 `EscapePoint2D`를 만든다. `point_id`는 `interaction_id`가 되며 NetworkManager는 RegionDefinition의 ESCAPE 목록, 액터 거리 및 상호작용 가능 여부를 검사한다.
- **Adventure → Adventure**는 이 연결 경로에서 지원되지 않는다. 기존 정착지 출구를 암묵적으로 만들거나 수정하지 않는다.
- 마커의 ID 변경·삭제는 저장 노드 참조, 지속 연결, 정착지 출구의 ENTRY 참조, 시작 데이터와 퀘스트의 ESCAPE 참조를 검사한다. 근거가 부족한 변경은 실패 처리한다.
- 텅 빈 Empty 템플릿에는 바닥이 없다. Scene 구조 검증과 실제 Spawn Safety의 결과를 구분한다. 지지면이 없는 지도는 런타임 검증과 게시에서 별도로 판정한다.
