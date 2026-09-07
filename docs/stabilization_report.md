# 기반 시스템 안정화·등반 구현 보고

2026-09-07, master 기준. 작업 전 존재하던 project.godot의 입력 이벤트 직렬화와 main_scene 정렬 변경을 보존했다. 기존 v2 fixture와 테스트 러너 구조를 유지했다.

## 1. 변경한 파일

기존 파일 수정:

- `README.md`
- `autoload/game_session.gd`
- `autoload/save_manager.gd`
- `autoload/scene_router.gd`
- `core/boot.tscn`
- `core/models/active_effect.gd`
- `core/models/adventure_session.gd`
- `core/models/death_loss_policy.gd`
- `core/models/inventory_model.gd`
- `core/models/session/adventure_state.gd`
- `core/models/session/difficulty_state.gd`
- `core/models/session/player_state.gd`
- `core/models/session/progression_state.gd`
- `core/models/session/settlement_state.gd`
- `core/models/stat_block.gd`
- `core/serialization/save_data.gd`
- `data/content/exits/field_gate.tres`
- `data/content/game_start/default_game_start.tres`
- `data/definitions/effect_definition.gd`
- `data/definitions/equipment_definition.gd`
- `data/definitions/facility_definition.gd`
- `data/definitions/game_start_definition.gd`
- `data/definitions/loot_table_definition.gd`
- `data/definitions/quest_definition.gd`
- `data/definitions/recipe_definition.gd`
- `data/definitions/region_definition.gd`
- `data/definitions/settlement_exit_definition.gd`
- `data/definitions/weapon_definition.gd`
- `docs/architecture.md`
- `docs/content_authoring_guide.md`
- `docs/controls.md`
- `docs/save_format.md`
- `docs/session_architecture.md`
- `docs/testing.md`
- `gameplay/actors/enemies/chase_state.gd`
- `gameplay/actors/enemies/enemy_agent.gd`
- `gameplay/actors/enemies/patrol_state.gd`
- `gameplay/actors/player/player.gd`
- `gameplay/components/combat_component.gd`
- `gameplay/components/damage_context.gd`
- `gameplay/components/effect_controller.gd`
- `gameplay/components/health_component.gd`
- `gameplay/components/hitbox_component.gd`
- `gameplay/components/hurtbox_component.gd`
- `gameplay/components/interaction_component.gd`
- `gameplay/components/movement_component.gd`
- `gameplay/components/player_input_component.gd`
- `project.godot`
- `tests/test_runner.gd`
- `ui/game_hud.gd`
- `world/adventure/adventure_region.gd`
- `world/adventure/sewer_region.tscn`
- `world/settlement/settlement.gd`

추가 파일(스크립트 UID는 아래 별도 표기):

- `.github/workflows/godot.yml`
- `.godot-version`
- `core/models/adventure_rules_snapshot.gd`
- `core/models/command_result.gd`
- `core/models/death_drop_record.gd`
- `core/models/effect_runtime_model.gd`
- `core/models/respawn_result.gd`
- `core/serialization/session_snapshot.gd`
- `core/services/crafting_service.gd`
- `core/services/death_resolution_service.gd`
- `core/services/exit_service.gd`
- `core/services/progression_service.gd`
- `data/content/climbing/ladder.tres`
- `data/content/climbing/rope.tres`
- `data/content/respawn/default_respawn.tres`
- `data/definitions/climbable_definition.gd`
- `data/definitions/respawn_policy.gd`
- `docs/stabilization_report.md`
- `gameplay/components/attacks/attack_strategy.gd`
- `gameplay/components/attacks/melee_attack_strategy.gd`
- `gameplay/components/attacks/projectile_attack.gd`
- `gameplay/components/attacks/projectile_attack_strategy.gd`
- `gameplay/components/climbable_area_2d.gd`
- `tests/fixtures/projectile_attack.tscn`
- `tests/stability_tests.gd`
- `tests/visual_smoke.gd`
- `tests/visual_smoke.tscn`
- `tools/check_project.py`
- `world/adventure/escape_point_2d.gd`
- `world/region_point.gd`

Godot가 생성한 새 `.gd.uid` 21개도 각 스크립트 옆에 포함한다.

## 2. 주요 클래스와 책임

| 클래스 | 책임 |
|---|---|
| DeathResolutionService / RespawnResult / RespawnPolicy | 사망 손실과 정책 기반 부활, 구조화된 결과 |
| AdventureRulesSnapshot | 원정의 유효 난이도 복제·고정 |
| DeathDropRecord | 지역·위치·수량·고유 ID를 가진 회수 기록 |
| EffectRuntimeModel / ActiveEffect | 세션 효과 시간·슬롯·중첩·출처·Modifier 및 주기 tick |
| SessionSnapshot | 독립 복원과 치명적 오류/경고 분리, 성공 시 전체 적용 |
| CommandResult | 성공 여부, 실패 이유, 미지급 아이템 목록 |
| ExitService | 출입구 연결·해금·플래그·시설·진입점 검사 |
| ProgressionService / CraftingService | 선행 조건, 반복/후속 퀘스트, 시설·제작 거래 |
| AttackStrategy, MeleeAttackStrategy, ProjectileAttackStrategy, ProjectileAttack | 실제 근접 범위와 투사체 실행 |
| ClimbableDefinition / ClimbableArea2D | 사다리·밧줄 정책 Resource와 감지·중심선·끝점 |
| RegionPoint / EscapePoint2D | 실제 진입 Marker 및 탈출 상호작용·표시 정책 |

## 3. 사망·원정·효과·저장·등반 흐름

- 사망: 실제 Actor 위치 전달 → 중복 검사 → 원정 손실/정착지 무손실 구분 → 드롭 및 양수 체력·생존 복구 → 정착지 새 Actor. 손실 결과에 보호 인벤토리도 유지 목록으로 포함한다.
- 원정: 출입구 도메인 검증 → 유효 난이도 스냅샷 → 모든 원정 규칙 공통 조회 → 정상 탈출 시 거래 또는 pending 보존. 진행 중 Save/Load와 직접 facade restore, 무단 SceneRouter 정착지 복귀를 거부한다.
- 효과: 세션 PlayerState 소유 → 장면과 독립 tick → 만료 시 source 제거. 장비 재연결과 최대 체력 버프 refresh가 중간 무버프 값을 노출하지 않는다. 주기 피해는 접촉 무적 시간과 독립적으로 정확한 양을 적용한다.
- 저장: JSON/Migration → 임시 모델 검증 → 성공한 Snapshot만 적용. 치명적 오류는 기존 세션을 유지한다. 유효한 초과 아이템은 pending에 보존한다.
- 등반: 실제 Area 겹침 + 중심 거리 + W/S → 부드러운 정렬 → 중력 없는 CLIMB → 상하단/점프/정책 피격/강제 넉백/사망/장면 이탈. 하수구 사다리 상단 플랫폼에 도달해 E로 탈출한다. 공격·귀환과 등반의 동시 실행은 차단한다.

## 4. 저장 버전과 Migration

v3. v2 flat key는 유지하고 active_effects, death_drops, pending_loot를 추가했다. v1 → v2는 기존 두 필드를 보충하고, v2 → v3는 새 배열을 추가한다. 임시 Modifier 자체는 저장하지 않는다. 기존 v2 fixture 파일은 수정하지 않았다. 상세 구조는 [save_format.md](save_format.md)에 기록했다.

## 5. 실제 실행 명령

프로젝트 루트에서 다음 PowerShell 명령을 실행했다.

```powershell
$godotExe = 'C:/Users/maker/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe'
python tools/check_project.py --godot $godotExe
& $godotExe --path . --rendering-method gl_compatibility res://tests/visual_smoke.tscn
git diff --check
```

일반적인 설치 경로와 개별 명령은 [testing.md](testing.md)에 별도로 안내한다. check_project.py는 import/parse, Validator, 기존+신규 러너, restart-write/restart-read, 메인 씬을 각각 별도 프로세스로 실행한다. 종료 코드뿐 아니라 ERROR/WARNING/orphan/leak와 성공 마커를 검사한다.

## 6. 테스트 결과

| 검사 | 결과 |
|---|---|
| 기존 + 안정화 회귀 테스트 | PASS, 461 assertions |
| 새 프로세스 저장 | PASS, 1 assertion |
| 별도 프로세스 재시작·로드 | PASS, 25 assertions |
| 콘텐츠 검증 | PASS, 29 Resources |
| Headless editor import/parse 및 메인 씬 | PASS |
| OpenGL 렌더링 자동 실행 | PASS, 0 failures |
| git diff --check | PASS |

회귀와 재시작 검증 합계 **487 assertions**. 최종 headless 실행에서 parser/runtime 오류, invalid access, orphan/leak 경고가 없었다. 테스트 성공을 위해 기존 검증을 제거하지 않았다. 비교 함수는 v3의 새 기본 배열을 보충하고 모든 기존 필드를 계속 비교한다.

## 7. 수동 플레이 검증

사람처럼 창에 직접 키보드·마우스를 입력하는 수동 플레이는 실행하지 않았다. 이 세션에 해당 자동화 도구가 없어 미검증으로 구분한다.

대신 실제 OpenGL 렌더러에서 메인 씬을 열고 New Game, 실제 물리 등반, 상단 착지, E 탈출, HUD 잠금 상태를 자동 실행했다. 생성한 settlement.png와 ladder_top.png를 열어 화면 경계와 버튼 배치를 확인했다. 파일은 user://validation에 있다. 이는 엔진 자동 통합 검증이며 수동 플레이 결과로 주장하지 않는다.

## 8. 아직 구현·검증하지 않은 부분

- GitHub 원격 CI 실행 결과는 아직 없다. 워크플로와 공식 엔진 다운로드 URL을 확인했으며 동일 검증 스크립트는 로컬에서 통과했다.
- 실제 손 조작, 다양한 게임패드 하드웨어·OS, 장시간 플레이는 미검증이다. A/D/W/S 물리 키 이벤트 매핑과 등반 물리는 자동 테스트했다.
- 벌판 지역은 구현하지 않았다. field_gate는 development_locked이며 하수구에 허위 연결하지 않는다.
- 제작은 요청한 최소 원자적 거래로 구현했다. 기존 craft_seconds를 사용하는 시간 경과 제작 대기열, 아트 등반 애니메이션, 신규 주민 AI는 추가하지 않았다.

## 9. 향후 콘텐츠 확장 지점과 남은 하드코딩

RespawnPolicy, EffectDefinition, ClimbableDefinition, Region/Exit Marker, AttackStrategy, RecipeDefinition을 통해 확장한다. 전역 EventBus, Quest event decoupling, 귀환 아이템 효과 데이터화, ContentRegistry typed indexing은 후속 작업이다.

요청된 초기 콘텐츠 ID 직접 참조를 production에서 다시 검색했다. GameSession의 새 게임 초기화에는 남아 있지 않다. 다음은 기존 샘플 플레이/UI 연결이며 초기값 중복 소유가 아니다.

| 파일 | 남은 직접 참조 |
|---|---|
| gameplay/actors/player/player.gd | berry 빠른 사용, return_seed 채널링 |
| world/settlement/settlement.gd | milo, workbench, sewer_gate, sewer_region 및 샘플 퀘스트/배치 |
| world/adventure/adventure_region.gd | berry, rusty_scrap 샘플 채집 배치 |
| ui/game_hud.gd | berry/water_drop 버튼, workbench 표시, 난이도 프리셋 목록 |
| devtools/debug_panel.gd | berry/water_drop 개발 지급, workbench 개발 명령 |

production에서 구 GameSession.player_inventory/player_stats/equipment/settlement_storage/quest_states/active_adventure/facility_levels/resident_states/difficulty_id/survival_state call site는 검색되지 않았다. GameSession의 deprecated getter/setter와 테스트의 호환성 접근은 의도적으로 유지했다. State 외에 중복 상태 객체를 추가하지 않았다.
