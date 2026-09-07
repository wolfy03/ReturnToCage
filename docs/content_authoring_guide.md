# 콘텐츠 제작 가이드

## 공통 규칙

정적 데이터는 data/content 아래 `.tres`로 추가하고 안정적인 snake_case id를 부여한다. 현재 수량·내구도·효과 시간·회수 여부는 런타임 모델에만 기록한다. 새 콘텐츠를 추가한 뒤 `godot --headless --path . res://core/validation/validate_content.tscn`을 실행한다.

## 아이템, 음식, 장비와 효과

ItemDefinition의 중첩·무게·보호·허기/갈증 회복과 effects를 지정한다. EffectDefinition의 kind는 능력치 변경, 주기 회복, 주기 피해다. 주기 효과는 tick_interval_seconds마다 magnitude × stacks를 적용한다. duration_seconds 0은 시간 만료가 없는 효과다. REPLACE는 중첩과 tick 타이머를 초기화하고 REFRESH는 지속시간을 갱신한다. STACK은 max_stacks까지 중첩한다. 음식은 food_slot이 같은 기존 효과를 교체한다.

EquipmentDefinition.stat_modifiers는 가산 능력치, equip_effects는 장착 중 지속 효과다. 내구도 0이면 둘 다 적용하지 않고 무기 공격도 거부한다. WeaponDefinition은 attack_range, target_factions, hit_effects를 실제 공격에 사용한다. PROJECTILE은 ProjectileAttack을 루트로 하는 attack_scene이 필수다. CollisionShape2D와 Hurtbox를 감지하는 collision_mask(현재 Hurtbox 레이어 값 2)를 설정한다. tests/fixtures/projectile_attack.tscn은 최소 구성 예다. 전략 확장은 CombatComponent.strategies에 AttackStrategy 구현을 등록한다.

## 지역, 출입구, 탈출 지점

1. RegionDefinition에 PackedScene 경로, entry_point_ids, escape_point_ids, ItemDefinition 자원 ID와 EnemyDefinition 적 ID를 지정한다.
2. 해당 씬에 RegionPoint Marker2D를 배치하고 kind와 point_id를 정의 목록과 일치시킨다. 플레이어는 선택한 ENTRY Marker에 생성된다. ESCAPE Marker에는 실제 상호작용 오브젝트가 생성된다. 상단 플랫폼 탈출은 requires_landing을 켠다.
3. SettlementExitDefinition에 connected_region_ids와 모든 연결 지역에 존재하는 entry_point_id를 지정한다. required_flags와 required_facility_levels로 요구 조건을 선언한다. 해당 출구와 지역은 모두 해금되어야 한다.
4. 상호작용은 `request_adventure_from_exit(exit_id, selected_region_id)`에 선택 지역을 명시한다. 여러 연결이 있으면 호출 UI에서 지역을 선택한다. 연결 배열의 첫 요소를 임의 사용하지 않는다.

미구현 출구는 development_locked를 켜고 거짓 연결을 넣지 않는다. 현재 field_gate는 이 상태다. Validator는 Resource 타입, 연결 지역, 진입점, 선언·실제 Marker 불일치, 중복 ID를 검사한다.

## 사다리와 밧줄

ClimbableDefinition을 작성하고 LADDER/ROPE, speed_multiplier, alignment_tolerance, alignment_speed, 상하단·점프 이탈 허용, requires_interaction, drop_on_damage를 지정한다. 현재는 Polygon/선 그래픽을 사용한다. 아트 애니메이션은 MovementComponent의 mode_changed와 CLIMB 상태에 연결할 수 있다.

씬 배치:

1. Area2D에 ClimbableArea2D 스크립트와 definition을 지정한다. collision_layer는 0, collision_mask는 플레이어 Body 레이어(현재 1), monitoring을 켠다.
2. CollisionShape2D로 등반 가능 구간을 감싼다. Area 원점의 X가 정렬 중심선이다. 지나치게 넓은 영역 대신 alignment_tolerance에 맞는 폭을 사용한다.
3. 상단·하단 Marker2D를 배치하고 top_marker/bottom_marker에 직접 연결한다. 노드 이름은 자유다. 위쪽 y가 아래쪽보다 작아야 한다.
4. 상단 Marker는 플레이어 중심이 플랫폼 위에 놓이는 높이에 둔다. 아래에서 올라올 플랫폼은 one_way_collision을 사용한다. 상단 탈출 RegionPoint는 같은 착지 높이에 둔다.
5. W로 진입, 입력 해제 시 정지, S로 하강, Space 이탈, 피격·귀환 차단을 실제 씬에서 검증한다.

샘플은 climbing/ladder.tres와 rope.tres, sewer_region.tscn의 EmergencyLadder/TestRope다. 공격은 등반 중 차단한다. drop_on_damage=false면 일반 피격 시 유지하지만 강제 넉백·사망은 항상 이탈한다.

## 사망, 시설, 퀘스트와 제작

GameStartDefinition은 초기 데이터와 respawn_policy/survival_config를 참조한다. RespawnPolicy는 체력·허기·갈증 부활 비율을 지정한다. 사망 드롭 생성 여부는 원정 난이도의 recovery_policy를 따른다.

FacilityDefinition은 선행 시설/퀘스트, 각 레벨 비용과 해금 플래그를 선언한다. 선행 시설은 최소 레벨 1, 선행 퀘스트는 완료 상태가 필요하다. QuestDefinition은 objectives와 선행/후속 목록, repeatable을 지정한다. 후속 퀘스트는 보상 수령 후 시작하며 반복 퀘스트는 완료·수령 후 재시작할 수 있다.

RecipeDefinition은 입력/출력 Item ID와 수량, 시설 ID/레벨, unlock_flags를 선언한다. 정착지 HUD 또는 GameSession.craft()로 실행한다. 출력 공간까지 검사한 뒤 입력 제거와 출력을 한 번에 적용한다. 현재 최소 제작은 즉시 거래이며 craft_seconds를 사용하는 제작 대기열은 후속 확장 대상이다.

비용/보상/전리품 배열 길이와 음수 수량, 선행 조건·목표의 Resource 타입을 검증한다. 주민은 아직 ResidentDefinition Registry가 없으므로 TALK_TO_NPC 대상은 시작 설정의 주민 ID로 검증한다. 발견 목표는 지역의 탈출 지점 ID로 검증한다.
