# 조작

| Input Map 액션 | 기본 키 | 역할 |
|---|---:|---|
| `move_left` | A | 왼쪽 이동 |
| `move_right` | D | 오른쪽 이동 |
| `jump` | Space | 점프 |
| `interact` | E | 현재 선택 상호작용 |
| `primary_attack` | J | 주 무기 공격 |
| `use_quick_item` | Q | 정착지에서는 Berry, 원정에서는 귀환 씨앗 채널링 |
| `open_inventory` | I | HUD 상세 패널 열기/닫기 |
| `pause` | Esc | 향후 일시정지 메뉴 확장 지점 |
| `debug_panel` | F10 | Debug 빌드 개발 패널 |

키 값은 스크립트에 직접 쓰지 않고 `project.godot` Input Map에서 관리한다. 게임패드 지원 시 동일 액션에 Left Stick/D-pad, South 버튼 점프, West 버튼 공격, North 버튼 상호작용을 추가하고 deadzone과 UI 포커스 이동을 함께 검증한다.
