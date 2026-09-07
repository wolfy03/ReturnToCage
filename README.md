# Return to Cage

Godot **4.7.2** 기반 2D 횡스크롤 생존 RPG다. 정착지 준비 → 하수구 원정 → 전투·채집·등반 → 탈출 또는 사망 → 정착지 복귀 흐름을 플레이할 수 있다.

`project.godot`을 열고 F5로 실행한다. A/D는 좌우, W/S는 사다리·밧줄 등반, Space는 점프, E는 상호작용, J는 공격, Q는 귀환 아이템이다. 비상 사다리는 꼭대기까지 올라간 뒤 E로 탈출한다.

원정 중 저장·불러오기와 난이도 UI는 잠긴다. 원정 규칙은 시작할 때 고정되며, 음식 효과와 사망 드롭은 세션에 유지된다. 창고 초과 전리품은 pending 보관함에서 다시 수령할 수 있다. 세이브 v3는 v1/v2를 단계별로 이관한다.

```sh
python tools/check_project.py --godot godot
```

엔진 버전은 `.godot-version`에 고정되어 있다. 실행 파일 지정, CI 및 수동 점검 절차는 [테스트](docs/testing.md)를 참고한다.

- [아키텍처](docs/architecture.md) · [상태 소유권](docs/session_architecture.md)
- [콘텐츠 제작](docs/content_authoring_guide.md) · [저장 형식](docs/save_format.md)
- [조작](docs/controls.md)
