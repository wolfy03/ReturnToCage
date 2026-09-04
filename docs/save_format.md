# 저장 형식

## 현재 버전

JSON 최상위 `format_version`은 `2`다. `saved_at`과 `game_state`를 함께 기록한다. 기본 경로는 `user://return_to_cage_save.json`이다.

`game_state`에는 세션 ID, 플레이 시간, 기본 능력치, 현재 체력, 플레이어 인벤토리, 장비, 정착지 창고, 보호 인벤토리, 시설 레벨, 주민 상태, 지역/출입구 해금, 발견 탈출 지점, 퀘스트 진행, 난이도 프리셋/Override, 생존 상태와 마지막 안전 위치가 있다. 진행 중 원정은 저장하지 않고 마지막 안전한 정착지 상태로 복구한다.

아이템/시설/퀘스트/지역은 `.tres` 경로가 아니라 안정적인 콘텐츠 ID로 저장한다. Node와 Resource 객체는 저장하지 않는다.

## 쓰기와 오류 정책

SaveManager는 동일한 직렬화 함수로 저장 내용을 만든 뒤 `.tmp`에 쓰고 flush/close한다. 기존 저장은 `.bak`으로 옮긴 다음 임시 파일을 최종 파일명으로 rename한다. 임시 파일 생성 또는 rename이 실패하면 Signal로 명시적인 실패를 반환한다. JSON 파싱 실패, 지원하지 않는 버전, 파일 부재는 기존 상태를 덮어쓰지 않고 실패한다. 등록되지 않은 콘텐츠 ID는 복원에서 제외하고 경고로 반환한다.

## Migration 추가

`SaveManager.migrate()`에 `version == N` 단계 하나를 추가하고, 복제한 Dictionary에 새 필드의 안전한 기본값을 넣은 뒤 버전을 `N + 1`로 올린다. 한 단계씩 순서대로 적용해야 하며 원본 Dictionary를 직접 변경하지 않는다. 현재 v1 → v2는 `difficulty_overrides`, `protected_inventory`를 추가한다.
