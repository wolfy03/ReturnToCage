# 기반 시스템 아키텍처

`core/boot.tscn`은 유지되는 UI와 교체되는 WorldLayer를 소유한다. SceneRouter는 검증된 AdventureContext를 지역에 전달하고 이전 월드를 즉시 트리에서 분리한다. 새 autoload는 추가하지 않았다.

## 상태와 명령

GameSession은 다섯 State의 facade다. [소유권 표](session_architecture.md)를 따른다. Resource는 정적 콘텐츠이며 현재 수량, 효과 시간, 손실, 위치는 RefCounted 모델에만 기록한다. UI는 명령 결과와 시그널을 사용하며 저장 Dictionary를 수정하지 않는다.

- `PlayerState`: 능력치, 장비, 인벤토리, 생존, 체력, 안전 위치, `EffectRuntimeModel`.
- `SettlementState`: 창고, 시설, 주민, 넘친 전리품 `pending_loot`.
- `ProgressionState`: 퀘스트 진행, 해금, 발견 지점.
- `AdventureState`: 현재 원정과 지역별 `DeathDropRecord`.
- `DifficultyState`: 다음 원정의 프리셋·Override. 진행 중 원정은 `AdventureRulesSnapshot`의 복제된 유효 난이도를 사용한다.

`ExitService`, `ProgressionService`, `CraftingService`가 연결·선행 조건·거래 규칙을 검사한다. InventoryModel의 preview/exchange는 출력 공간까지 시뮬레이션한 뒤 한 번에 적용한다. 정상 탈출 시 한 종류라도 공간이 부족하면 전리품 전체를 pending에 유지한다. 퀘스트 보상도 지급 성공 후에만 수령 처리한다.

## 세션 흐름

`MENU → SETTLEMENT → ADVENTURE → SETTLEMENT`이며 사망은 `RESPAWNING`을 거친다. SaveManager는 SETTLEMENT에서만 저장, MENU/SETTLEMENT에서만 불러오기를 허용한다. 직접 함수 호출도 검사한다. 활성 원정 중 SceneRouter를 통한 정착지 이동도 거부한다.

원정 시작 시 난이도 프리셋과 Override를 합친 값을 복제한다. 적 체력·공격력, 생존 소모, 전리품, 인벤토리·장비 손실, 드롭, 탈출 지점 표시가 같은 스냅샷을 조회한다. 프로그래밍 API로 전역 설정을 바꿔도 다음 원정부터 적용된다.

## 사망과 회수

PlayerActor가 실제 위치와 함께 `handle_player_death()`를 한 번 호출한다. GameSession과 Actor 양쪽의 중복 방지 장치가 손실 재적용을 막는다. `DeathResolutionService`는 기존 `DeathLossPolicy`를 사용하고 `RespawnResult`에 유지/손실 아이템, 장비 손상/손실, 드롭, 부활 체력·생존·위치를 반환한다. 부활 비율은 `RespawnPolicy` Resource에서 읽는다. 정착지 사망은 원정 손실을 적용하지 않는다.

체력은 월드 교체 전에 복구한다. 효과 tick은 부활 대기 동안 정지하고 새 Actor 준비 후 재개한다. DROP_AT_DEATH만 영속 회수 기록을 만들며, 동일 지역 재진입 시 해당 위치에 오브젝트를 생성한다. 성공적으로 추가한 수량만 미확보 전리품으로 이동한다. 일부 회수한 기록은 유지하고, 전체 회수한 기록만 제거한다. 회수 뒤 다시 사망하면 미확보 전리품이 새 기록으로 이동한다.

## 효과와 전투

플레이어 EffectController는 세션 효과 모델의 어댑터다. Scene Node가 효과 시간을 소유하지 않는다. 효과는 GameSession에서 tick하며 장면 이동 시 유지된다. 적은 자기 수명에 맞는 로컬 효과 모델을 쓴다. source별 Modifier 교체는 중간 값을 노출하지 않아 최대 체력 갱신 시 손실이 없다.

STAT_MODIFIER, PERIODIC_HEAL, PERIODIC_DAMAGE를 실행한다. tick_interval_seconds마다 magnitude × stacks를 적용한다. 음식 슬롯 교체와 REPLACE/REFRESH/STACK을 지원한다. 장비 source는 `equipment:<slot>`, 효과 source는 `effect:<source>/<effect_id>` 형식이다. 장비 효과는 장착 중 지속하며 저장 시 제외하고 장비로 재구성한다. 내구도 0인 장비는 능력치·효과·공격을 제공하지 않는다.

CombatComponent는 근접/투사체 전략을 선택한다. 근접 범위는 Resource의 attack_range로 Hitbox를 구성한다. 투사체는 ProjectileAttack 씬을 생성해 범위만큼 이동한다. Hurtbox는 target_factions를 검사하고 성공한 피격에 hit_effects를 적용한다.

## 이동과 등반

PlayerInputComponent는 Input Map에서 수평·수직 축을 제공한다. MovementComponent는 GROUND/AIR/CLIMB을 구분한다. ClimbableArea2D와 겹치고 중심선 허용 거리 안에서 W/S를 눌러야 진입한다. CLIMB은 중력을 끄고 Resource 속도·정렬·이탈 정책을 사용한다. 공격과 귀환 채널링은 등반과 함께 실행할 수 없다. 피격은 drop_on_damage, 강제 넉백·사망은 강제 이탈이다. 영역 이탈·상하단·점프·장면 변경도 일반 이동으로 복구한다.

## 저장 경계와 시그널

각 State가 자신의 flat save 필드를 직렬화한다. SessionSnapshot에서 독립 복원·검증한 뒤 전체 State를 교체한다. 치명적 오류는 현재 세션을 유지한다. 교체 시 이전 inventory/storage relay를 끊고 새 모델에 연결한다. 기존 8개 시그널은 유지하며 phase_changed/player_respawned를 추가했다. [저장 형식](save_format.md)을 참고한다.

전역 EventBus, 주민 AI, 슬롯형 인벤토리, 장비 Instance 전면 재작성은 도입하지 않았다. 기존 Component와 Enemy 상태 노드는 유지한다.

## 안정화 경계

StackValidation은 모델의 입력 규칙과 저장 레코드 보정을 공유한다. Snapshot의 일회성
instance ID 검사 집합으로 전체 저장 상태의 중복을 제거하며 전역 ItemInstance 저장소는 없다.
InventoryModel의 restore/initialize/exchange는 최종 changed를 한 번만 발행한다.
정확한 instance 입력은 해당 ID만 제거한다. 모든 exchange 실패는 원본을 유지한다.

QuestState와 SettlementState의 작은 수령 잠금은 storage_changed 콜백의 재진입을 막는다.
reward_claimed는 지급 성공 후 확정한다. 후속 퀘스트 시작 실패는 이미 지급한 보상을
rollback하지 않는다. 해당 퀘스트의 선행 조건이 충족되면 기존 start_quest 경로로 시작한다.

사망은 설정과 좌표를 먼저 검증한다. 실패한 RespawnResult는 phase/pause/소지품을
변경하지 않는다. 씬 로드 실패 시 respawn은 재시도 가능하게 남고 stale paused 플래그는
해제한다. RESPAWNING에서는 tick을 유예해 새 월드가 준비될 때까지 추가 피해를 막는다.
