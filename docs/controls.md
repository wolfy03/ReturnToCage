# 조작

| 액션 | 기본 입력 | 동작 |
|---|---|---|
| move_left / move_right | A / D, ← / →, 왼쪽 스틱 X | 좌우 이동 |
| move_up / move_down | W / S, ↑ / ↓, 왼쪽 스틱 Y | 겹친 사다리·밧줄에서 등반·하강 |
| jump | Space | 지상 점프, 등반 중 뛰어내리기 |
| interact | E | 우선순위가 가장 높은 상호작용 |
| primary_attack | J | 장착 무기 공격; 등반/귀환 중 불가 |
| use_quick_item | Q | 정착지 Berry, 원정 귀환 씨앗 채널링 |
| open_inventory | I | HUD 상세 패널 토글 |
| pause | Esc | 일시정지/재개 |
| debug_panel | F10 | Debug 빌드 개발 패널 |

등반 영역 밖에서 W/S는 공중 이동을 만들지 않는다. 등반 중 입력을 놓으면 높이를 유지한다. HUD는 상호작용 대상이 없을 때 `[W/S] Climb`과 `[Space] Jump off`를 표시한다. 상호작용 필요 Resource는 E로 잡은 뒤 W/S로 이동한다.

하수구 시작 입구는 기존처럼 E로 탈출한다. 오른쪽 비상 사다리는 직접 올라가 상단 플랫폼에 선 뒤 E로 탈출한다. 사다리 아래 E로 즉시 탈출할 수 없다. 원정 중 Q는 이동·피격 시 취소되며 등반과 동시에 실행할 수 없다.

Save/Load/난이도 UI는 원정·부활 중 잠기며 툴팁에 이유를 표시한다. 정착지에서 pending loot 수령과 제작 버튼을 사용할 수 있다. 입력 키는 project.godot에만 정의한다.
