ReturnToCage Map Editor — PY-STEP 6 (Windows x64)

ZIP 전체를 풀고 ReturnToCageMapEditor.exe를 실행하세요.
_internal 폴더를 실행 파일과 같은 위치에 두세요.

V / R / B / E / H: 선택 / 사각형 / 연속 배치 / 지우기 / 화면 이동
휠: 커서 기준 줌 | 가운데 버튼 드래그: 화면 이동 | F: 맵에 맞추기
Ctrl/Shift+클릭: 다중 선택 | Delete: 삭제 | Ctrl+D: 복제
Ctrl+C / Ctrl+V: 복사 / 붙여넣기 | Ctrl+Z / Ctrl+Shift+Z: 실행 취소 / 다시 실행
Ctrl+N / Ctrl+O / Ctrl+S: 새 맵 / 열기 / 저장

라이브러리 항목을 뷰포트로 끌어 배치하세요. 편집 메뉴의 리소스 프로젝트
폴더에서 PNG가 포함된 폴더를 지정할 수 있습니다. 회전과 정확한 좌표는
속성에서 입력하고, 선택한 플랫폼의 모서리나 가장자리 핸들을 끌어
크기를 조절하세요. 레이어에서 객체 수, 표시 및 잠금을 확인할 수 있습니다.

플랫폼 속성의 지형 표시 / 테마 또는 라이브러리의 플랫폼 브러시에서
9-Slice 테마를 선택할 수 있습니다. 여백은 좌, 상, 우, 하 순서입니다.
테마를 적용한 문서는 Schema V5로, Enemy 스폰 목록을 가진 문서는 Schema V6로 저장됩니다. 동봉된 하수구와 숲 PNG는
렌더링 검증용이며, 프로젝트에 게시할 때는 대상 프로젝트에 해당 메타데이터와
Godot에서 가져온 PNG가 있어야 합니다.

.rtcmap은 지역 정보, 플랫폼·장식, 레이어 상태를 담는 JSON 초안입니다.
기존 V1 문서는 열 수 있으며 다음 저장 때 V2로 기록됩니다. PNG는 프로젝트
상대 경로로 기록되므로 다른 PC에서 열 때 같은 리소스 폴더를 지정하세요.
다른 이름으로 저장에서 기존 파일을 선택하면 덮어쓰기 확인이 열립니다.
다른 편집기에서 저장 중이거나 확인 후 대상이 바뀌면 다시 열거나 다른 경로를 선택하세요.

독립 초안 편집에는 외부 Python이나 Godot가 필요하지 않습니다.
기존 Godot 지역을 열거나 내보낼 때 파일 메뉴에서 ReturnToCage 프로젝트와
공식 Godot 4.7.2를 설정하세요. 내보내기 검증과 새 프로젝트 폴더로 내보내기를
사용하면 원본 Scene에 쓰기 전에 실제 런타임에서 검사할 수 있습니다.
지역 메뉴의 마법사로 빈 지역, 평지, 플랫폼 템플릿을 만들 수 있습니다.
ENTRY / ESCAPE와 스폰을 배치하고, 지역 설계 패널에서 연결과 환경을
편집하세요. 보기 메뉴의 Python 문서 검증은 Godot 없이 실행됩니다.
Godot 지역 설계 가져오기(V4)는 마커, 스폰과 환경을 가져옵니다.
공식 Godot 4.7.2를 설정한 뒤 Godot 내보내기를 선택하면 Scene과
RegionDefinition을 격리 사본에서 검증한 뒤 게시 승인을 묻습니다.
신규 지역의 정착지 출구와 해금은 기존 게임 도구로 별도 구성하세요.
ESCAPE에서 다른 지역으로 연결하는 초안은 .rtcmap에 남으며 게시가 차단됩니다.
기존 V3 플랫폼·장식 게시는 유지됩니다.

공식 소스와 빌드 워크플로: https://github.com/wolfy03/ReturnToCage
소스 위치: tools/python_map_editor/ (feature/python-map-editor)

동봉 구성요소의 라이선스는 licenses 폴더를 참조하세요.
Qt 6.11.3 및 Qt for Python 6.11.3 소스와 구성요소 안내:
https://download.qt.io/archive/qt/
https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.11.3-src/
https://doc.qt.io/qtforpython-6.11/licenses.html
