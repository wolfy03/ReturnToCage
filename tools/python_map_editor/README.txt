ReturnToCage Map Editor — PY-STEP 2 (Windows x64)

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

.rtcmap은 지역 정보, 플랫폼·장식, 레이어 상태를 담는 JSON 초안입니다.
기존 V1 문서는 열 수 있으며 다음 저장 때 V2로 기록됩니다. PNG는 프로젝트
상대 경로로 기록되므로 다른 PC에서 열 때 같은 리소스 폴더를 지정하세요.
다른 이름으로 저장에서 기존 파일을 선택하면 덮어쓰기 확인이 열립니다.
다른 편집기에서 저장 중이거나 확인 후 대상이 바뀌면 다시 열거나 다른 경로를 선택하세요.

독립 초안 편집에는 외부 Python이나 Godot가 필요하지 않습니다.
Godot Scene 변환, 런타임 플레이테스트 및 물리 검증은 후속 단계입니다.

공식 소스와 빌드 워크플로: https://github.com/wolfy03/ReturnToCage
소스 위치: tools/python_map_editor/ (feature/python-map-editor)

동봉 구성요소의 라이선스는 licenses 폴더를 참조하세요.
Qt 6.11.3 및 Qt for Python 6.11.3 소스와 구성요소 안내:
https://download.qt.io/archive/qt/
https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.11.3-src/
https://doc.qt.io/qtforpython-6.11/licenses.html
