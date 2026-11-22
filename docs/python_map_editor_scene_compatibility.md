# Godot 지역 편집 호환성

대상 엔진은 ReturnToCage의 공식 Godot 4.7.2다. 가져오기는 PackedScene을 인스턴스화한 뒤 편집 가능한 노드를 찾는다. 기존 Godot Field Editor는 계속 사용할 수 있다.

| 실제 게임 데이터 | 읽기 및 편집 | 보존 방식 |
| --- | --- | --- |
| `data/content/regions/sewer_region.tres` | 지역 ID·이름 및 Scene 경로를 읽는다. | `RegionDefinition` 파일 자체를 이전과 동일하게 유지한다. ENTRY/ESCAPE, 환경, 적과 자원 ID 및 다른 지역에서 들어오는 연결은 기존 ContentRegistry 경로를 사용한다. |
| 하수구의 `Terrain/Floor`, `WestPlatform`, `MidPlatform`, `EastPlatform`과 루트 `Landing` | 스크립트 없는 StaticBody2D와 중심이 같은 RectangleShape2D·Polygon2D의 조합이다. 위치·회전·크기·단방향 충돌을 편집한다. | Owner와 부모를 유지한다. 크기를 바꿀 때 RectangleShape2D를 복제하여 공유 원본을 건드리지 않고 Polygon2D 꼭짓점도 함께 바꾼다. 레이어·마스크·단방향 여유값은 유지한다. |
| `world/adventure/field_platform.tscn` | FieldPlatform은 StaticBody2D이며 `size`, `tint`, `one_way`를 저장한다. | 새 플랫폼은 기존 PackedScene 인스턴스에 Owner를 지정한다. 기존 플랫폼은 `size`와 `one_way`를 설정하고 런타임의 Collider·Visual 갱신을 검증한다. |
| FieldDecoration | Marker2D, `asset_path`, Node2D transform. PNG를 사용하는 장식의 위치·회전·크기·텍스처를 편집한다. | Z, Owner, 부모와 다른 노드 속성을 유지한다. PackedScene 장식, 직접 Sprite2D 및 안전하게 변환할 수 없는 장식은 기존 노드로 보존한다. |
| 하수구 ENTRY/ESCAPE, Climbable, GatherPoints, SpawnPoints, Signs | 원본의 읽기 전용 데이터다. | 스크립트, NodePath, 리소스, 부모와 Owner를 포함한 노드 상태를 저장 후 재로드하여 비교한다. |
| NetworkEntityRegistry, PlayerSpawnManager, EnemySpawnManager, LootSpawnManager | 기존 지역의 런타임 서비스다. | 새로 생성하지 않는다. RegionDefinition 검증과 실제 지역 런타임 테스트에서 확인한다. |

`FieldPlatform`의 시각적 치수와 콜라이더는 같은 중심 사각형을 사용한다. `FieldDecoration`의 PNG는 중심 Sprite2D로 표시된다. Bridge는 지역 노드의 실제 월드 Transform2D와 부모 로컬 Transform2D를 읽는다. 편집 대상은 객체의 월드 사각형을 모델에 투영하고, 쓰기 시 부모 transform을 역변환한다. 반전, 특이 행렬, 전단 및 플랫폼의 비균등 충돌 스케일을 가진 노드는 편집 대상에서 제외하고 원래 변환을 검증한다.

기존 EditorPlugin의 `field_layers.gd`는 Terrain과 Decorations의 배치 위치를 정의한다. `field_maintenance.gd` 및 `region_recovery.gd`는 스테이징, 파일 해시, UID와 다중 파일 복구를 관리하며 EditorUndoRedoManager·캐시 경로를 사용한다. Python Bridge는 런타임에서도 실행되는 `RegionDefinition.validate_definition`, `FieldSceneChecks` 및 기존 지역 런타임 probe를 직접 재사용한다. 이 단계에서는 RegionDefinition을 바꾸지 않으므로 원본 프로젝트로의 게시 대상은 Scene 한 파일이다.

[Godot PackedScene API](https://docs.godotengine.org/en/stable/classes/class_packedscene.html) · [Godot ResourceSaver API](https://docs.godotengine.org/en/stable/classes/class_resourcesaver.html)

