# Field Editor STEP 7 — Traversal & Reachability

## 실행과 결과 읽기

1. Godot 4.7.2에서 등록된 모험 지역 씬을 연다. Field Editor의 **Region Design**에서
   **Traversal & Reachability** 페이지를 선택한다.
2. **Analyze Traversal**을 누른다. 연결된 RegionDefinition은 디스크와 일치해야 한다.
   저장하지 않은 Scene 편집은 현재 편집 트리의 별도 `.godot` 스냅샷으로 분석한다.
   원본 Scene이나 Resource를 자동 저장하지 않는다.
3. 첫 결과는 Candidate이다. Python이 별도 Godot 프로세스에서 실제 PlayerActor를
   검증한다. 에디터에서 GameSession이나 네트워크 서버를 실행하지 않는다.
4. 표면, 방향별 연결, 스폰별 ESCAPE 결과를 읽는다. 행을 선택하면 관련 Scene 노드를
   선택한다. 관측된 충돌 원인도 별도 행에서 선택할 수 있다.
5. Dock의 Visualize에서 Walkable Surfaces, Verified/Candidate Jumps, Drop/Climb
   Connections, Unreachable Areas, Escape Reachability를 개별적으로 켠다.
   실선은 실제 물리 샘플이며 후보/실패는 점선이다. 선택된 연결은 굵게 표시한다.
6. 분석 중 같은 버튼은 **Cancel Analysis**가 된다. **Clear Analysis**는 결과를 지운다.
   Scene 전환, Undo/Redo, Inspector 편집, 파일 변경은 결과를 무효화한다.
   직접 스크립트로 바꾼 Transform/주요 물리 속성은 캐시를 0.2초마다 비교한다.
   Scene을 닫고 다시 열면 이전 증거를 재사용하지 않고 다시 분석한다.

Region Design 본문에는 스크롤이 적용된다. 긴 진단 목록이 네이티브 팝업을 화면보다
크게 늘리지 않는다. STEP 6의 연결·환경·스폰 진단 페이지도 그대로 사용할 수 있다.

| 표시 | 의미 |
| --- | --- |
| Candidate | 기하/운동학 후보. 실제 통과를 보장하지 않는다. |
| Verified surface / edge | 실제 CharacterBody2D 바닥 판정과 입력을 사용하여 이동했다. |
| Verified Reachable | 한 스폰에서 목표까지 위치를 재설정하지 않고 입력을 이어 재생했다. 실제 EscapePoint2D의 범위와 can_interact도 통과했다. |
| Candidate Reachable | 개별 연결 또는 그래프 후보가 있어도 전체 연속 재생은 성공하지 않았다. |
| Unreachable Within Tested Inputs | 해당 연결의 제한된 시작점/제어 전략이 실패했다. 모든 입력이 불가능하다는 증명은 아니다. |
| Not Evaluated | 미지원 지형, 후보 범위 밖, 분석 예산 소진 또는 검증된 접근 경로가 없다. |
| Invalid Spawn / Destination | 스폰 정책/슬롯 또는 목표 선언이 유효하지 않다. |

표면의 `access=Candidate Reachable`은 검증된 간선 그래프의 연결성만 나타낸다.
그 표면까지 모든 연결을 이어 재생했다는 뜻은 아니다. ESCAPE의 Verified Reachable만
전체 경로 재생 증거를 가진다. 빨간 `No verified approach`도 미검증 접근을 뜻한다.
낙하 후 검증된 귀환 간선이 없으면 경고하지만, 절대 복귀 불가능이라고 판정하지 않는다.
ESCAPE의 초록 링은 모든 분석 시작점의 연속 재생이 성공하고 partial이 아닌 경우에만 표시한다.

## 실제 이동 모델

분석 상수는 별도로 복제하지 않는다. `traversal_analysis.gd:model()`이 실제
`gameplay/actors/player/player.tscn`의 Movement/CollisionShape2D와
`data/content/game_start/default_game_start.tres`를 읽는다. 검증기는 새 게임의 실제
PlayerState로 PlayerActor를 구성하고 실제 적용된 속도도 기록한다.

현재 기본 프로필:

| 항목 | 런타임 규칙/위치 |
| --- | --- |
| 수평 속도 | 기본 190. StatBlock의 move_speed로 갱신. |
| 가속/감속 | MovementComponent의 1300 / 1700. 공중에서도 같은 수평 제어. |
| 점프 | 초기 Y 속도 -390. 실제 바닥 또는 허용된 등반 이탈에서만 request_jump 가능. |
| 중력 | MovementComponent의 1100. 실제 physics_tick/move_and_slide를 그대로 실행. |
| 낙하 제한 | 별도 최대 낙하 속도/낙하 피해 없음. |
| 입력 유지 | 점프 버튼 유지에 따른 높이 변화, coyote time, jump buffer 없음. 전투 입력 버퍼와 구분한다. |
| 플레이어 충돌체 | CapsuleShape2D, 반경 14, 전체 높이 34. safe_margin와 floor_max_angle도 Scene에서 읽음. |
| 등반 | 실제 Area overlap, alignment_tolerance, W/S, requires_interaction일 때 E. 속도는 move_speed × 해당 ClimbableDefinition.speed_multiplier. |
| 등반 종료 | 실제 Top/Bottom 이탈 플래그, 영역 이탈, 허용된 점프 이탈. 피격/제어 잠금은 런타임에 존재하지만 이 분석의 무전투 프로필에서 재현하지 않음. |
| 착지 | 실제 is_on_floor + 대상 CollisionShape 경로/착지 높이. 같은 StaticBody의 다른 shape를 혼동하지 않음. 바닥 스냅은 slide collision이 없을 수 있어 같은 물리 공간의 지지 ray도 확인. |

실제 구현은 `gameplay/components/movement_component.gd`, `player_input_component.gd`,
`climbable_area_2d.gd`, `gameplay/actors/player/player.gd`에 있다.
One-way 발판 아래로 통과하는 하강 입력을 새로 만들지 않는다.

## 검증 구조와 한계

- `traversal_analysis.gd`: 직사각형 표면을 플레이어 폭만큼 줄이고 몸체 여유 공간을
  샘플링한다. 축에 정렬된 음수/비균일 Scale은 후보로 지원한다. 회전/스큐 지형,
  CollisionPolygon2D, TileMapLayer 표면 추출은 Not Evaluated이다.
- `traversal_controller.gd`: 스냅샷, 비동기 실행, 취소, 캐시 무효화 및 보고서 검증.
  에디터의 @tool 하위 리소스와 직렬화된 상태가 달라질 수 있어 live fingerprint와
  cache-free snapshot fingerprint를 분리해서 확인한다.
- `tests/editor/traversal_physics.gd`: 별도 테스트 월드에서 실제 PlayerActor,
  PlayerSpawnPolicy, MovementComponent, ClimbableArea2D, EscapePoint2D를 사용한다.
  GameSession의 새 기본 프로필을 구성하지만 이 프로세스의 사용자 데이터는 격리한다.
  AdventureRegion의 실제 탈출·채집 Area 생성 계약을 재사용하고 gameplay _ready는 실행하지 않는다. 보상·장면 전환 콜백은 원본 스크립트를 떼기 전에 해제한다.
- `tools/analyze_traversal.py`: 승인된 프로젝트 내부 작업 폴더와 고정된 테스트 씬만
  실행한다. 셸 명령 문자열을 만들지 않는다. 종료 코드, 오류 로그, 성공 마커와 terminate/kill 여부를 모두 확인한
  뒤에만 결과를 완료 처리한다. timeout, cancel, script_error, 비정상 종료를 구분한다.
- 기존 FieldVisualization이 결과를 그린다. Actor, Overlay 또는 분석 결과를 콘텐츠 Scene에 저장하지 않는다.

검증용 위치 설정은 **독립 연결의 시작/초기 스폰 설정에서만** 사용한다. 전체 ESCAPE
재생 중에는 reset/teleport하지 않는다. 방향 입력, 점프/상호작용 이벤트 및 실제 위치 샘플을
보관한다. 점프/낙하는 최대 세 시작점에서 목표 방향 피드백/제동 전략을 시험한다.
착지 후 입력을 놓고 10 physics frame 동안 안정적 바닥을 확인한다.
상행과 하행은 별도 간선이다. requires_interaction의 E 입력이 채집/탈출 상호작용에 가로막히면 선행 소비를 가정하지 않고 Not Evaluated로 남긴다. 실제 MovementComponent가 다른 겹친 등반 영역을 선택했다면 의도한 사다리의 증거로 사용하지 않는다.

ENTRY는 실제 전환 스폰의 anchor이며 슬롯 오프셋과 함께 분석한다. Fresh Slot과 구분한다.
각 authored 슬롯을 독립적으로 검사한다. 런타임의 다른 슬롯 fallback이 있다고 해서
안전하지 않은 authored 슬롯을 안전하다고 표시하지 않는다. 동시 플레이어의 예약/충돌,
적, 피격, 전투, 생존, 일시 효과와 장비로 달라진 프로필은 이 분석의 범위 밖이다.
실제 2·3인 동시 스폰/권위 검증은 별도 ENet 회귀로 확인한다.

ESCAPE 검증은 물리적 접근과 기존 상호작용 조건 검사이다. 분석은 탈출 활성화로
정착지 전환을 일으키지 않는다. GameSession/SceneRouter의 실제 귀환, 채집, 전투 및
콘텐츠 해금은 기존 runtime/interactive/ENet 테스트의 책임이다.

Source Root의 비단위 basis는 실제 런타임 Actor 상속 Transform과 격리 Actor의 차이가
있어 물리 검증을 거절한다. Root 위치 이동과 지형의 중첩 Transform은 따로 처리한다.
지원하지 않는 객체를 제거해 놓고 검증 성공으로 바꾸지 않는다. 동적/사용자 스크립트
물리 객체가 있으면 해당 격리 프로필을 Not Evaluated/partial로 제한한다.

## 성능 예산과 취소

하수구(표면 5, 사다리·밧줄 2, 후보 간선 25)와 작은 혼합 테스트 맵(표면 4,
후보 간선 20)을 측정했다. Windows 4.7.2 headless에서 각각 약 1.8초 / 0.9초였으며,
최종 검증 간선은 각각 11 / 15개였다. 하수구의 Fresh/ENTRY × 4슬롯 × 2탈출구
16개 경로를 실제 입력으로 이어 재생했다. 결과는 테스트 프로필/전략 범위의 증거다.

기본 지역보다 약 12배 이상의 표면을 다룰 수 있도록 표면 64, 후보 shape 128,
간선 256, 시작 anchor 32, ESCAPE 4, climbable 64, 독립 시도 768로 제한한다.
검증 프로세스의 물리 분석 wall budget은 20초, 프로세스 전체 watchdog은 60초다.
예산을 넘으면 partial이며 남은 슬롯/목표는 Not Evaluated로 남긴다.
Geometry 샘플은 표면당 최대 64개다. 거대한 Scene의 초기 직렬화 비용은 여전히 Scene 크기에 비례한다.

Godot `--fixed-fps`는 물리 timestep을 바꾸지 않고 headless 대기를 줄이는 데 사용한다.
별도 이동 적분기를 만들거나 Engine.time_scale을 바꾸지 않는다. 작업은 외부 프로세스에서
실행하고 취소 파일을 50ms마다 확인한다. 분석 중 에디터는 입력을 계속 처리한다.

작업 자료는 `.godot/rtc_traversal/<32자리 nonce>/`에 남는다. `request.json`, `scene.tscn`,
`result.json`, `status.json`, `godot.log`를 확인할 수 있다. 완료되지 않은 자료를 재사용하지 않는다.
nonce, 프로젝트 경로/링크, Region ID, fingerprint, JSON 크기/타입, 간선 인덱스,
유한 좌표, 샘플 개수와 노드 경로를 확인한다. `..`로 Scene 밖 노드를 선택할 수 없다.
오류 종료 후 성공 마커가 남아 있어도 controller는 Verified 보고서를 가져오지 않는다.

## 테스트

일반 명령:

```sh
python tools/check_project.py --godot godot
python tools/test_field_editor.py --godot godot
python tools/test_field_editor.py --godot godot --rendered
python tools/test_multiplayer_world_runtime.py --godot godot --players 2
python tools/test_multiplayer_world_runtime.py --godot godot --players 3
godot --headless --path . --export-release "Windows Desktop" /path/to/output/ReturnToCage.exe --quit
```

Windows PowerShell 예시(엔진 설치 위치는 로컬 환경에 맞춘다):

```powershell
$godotExe = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64.exe'
python tools/test_field_editor.py --godot $godotExe --rendered
& $godotExe --headless --path . res://tests/editor/traversal_tests.tscn
```

`test_field_editor.py`는 기존 STEP 1~6 검증에 Traversal suite를 추가한다. 실제 Actor의
점프·공중 반전·착지, 방향별 점프/낙하/등반, E+W 사다리, 밧줄 하강, 전체 슬롯 경로,
잘못된 보고서, 동일 StaticBody의 서로 다른 착지 shape, 표면/간선 한도를 검사한다. 렌더링 에디터에서는 네이티브 Window ID를
지정한 InputEventMouseMotion/MouseButton을 주입한다. 분석, 취소, 행 선택, 변형 후
무효화, 재분석, 저장, 탭 닫기/재열기를 검사한다. 물리 마우스로 사람이 수행한 테스트와 구분한다.

입력 주입은 [Godot Viewport 입력 API](https://docs.godotengine.org/en/stable/classes/class_viewport.html)와
프로젝트의 기존 에디터 테스트 방식을 따른다. Headless의 버튼 신호 테스트만으로 GUI 성공을 판정하지 않는다.

## Windows 네이티브 오류 추적

4.7.2에서 성공 마커 이후 `3221225477 (0xC0000005)` 또는
`CowData was modified during destruction`가 발생하는 기존 문제가 남아 있다.
기준 efbfe43의 격리된 전체 렌더링 Field Editor 테스트 2회에서도 에디터 기능 PASS 뒤
runtime 프로세스가 0xC0000005로 종료했다(2/2). STEP 7 작업 중에도 별도 프로세스의
비정상 종료가 관측되었다. Windows Application 이벤트에는 Godot 모듈의
`0x547f2c`, `0x191eaee`, `0x191eae2` 오프셋이 기록됐다.
이는 작은 관측 표본이며 발생 확률이나 동일 근본 원인을 확정하지 않는다.
기능 assertion과 정상 종료를 분리하고, 마지막 성공 실행이 이전 실패 기록을 지우지 않는다.
기존 테스트 러너의 non-zero/error 거절 정책을 유지한다. 근본 원인을 해결했다고 주장하지 않는다.

후속 [STEP 7 안정화 조사](step7_stability.md)에는 실제 크래시 덤프, 반복 검증 및
worker Job Object 소유권/협력적 취소/초기화 정리 결과를 기록했다.
