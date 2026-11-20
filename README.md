# ReturnToCage Map Editor

ReturnToCage의 독립형 Windows 맵 에디터입니다. 현재 PY-STEP 1에서는 한국어 PySide6 화면에서 맵 경계와 격자를 보고, 확대·축소와 이동을 사용하며, 지역 ID·이름·크기를 `.rtcmap` 초안으로 저장하고 다시 열 수 있습니다.

객체 배치와 Undo/Redo는 PY-STEP 2, Godot Scene 및 RegionDefinition 변환은 PY-STEP 3의 범위입니다. 실제 게임 및 물리 검증 계획은 [설계 문서](docs/python_map_editor.md)에 있습니다.

## 소스 실행 및 Windows 빌드

Windows x64에서 Python 3.14.5를 사용합니다. 저장소 루트에서 실행합니다.

```powershell
python -m venv .venv
$editorPython = ".\.venv\Scripts\python.exe"
& $editorPython -m pip install -r tools/python_map_editor/requirements.txt
& $editorPython -m pytest tools/python_map_editor/tests -q
& $editorPython tools/python_map_editor/main.py
& ./tools/python_map_editor/build_windows.ps1 -Python $editorPython
```

빌드는 `build/python-map-editor`에 OneDir 패키지와 ZIP을 생성합니다. ZIP 전체를 풀고 `ReturnToCageMapEditor.exe`를 실행합니다. Windows에서 묶음 자체의 동작을 확인하려면 [배포 검증 명령](docs/python_map_editor.md#소스와-onedir-빌드)을 사용하세요.

이 저장소의 초기 소스는 [ReturnToCage의 PY-STEP 1 커밋](https://github.com/wolfy03/ReturnToCage/commit/fd59f9fa107f6bb80a8ed802ec711426fab2b59a)에서 가져왔습니다. 설계 문서의 Godot 파일 경로는 [게임 저장소](https://github.com/wolfy03/ReturnToCage)를 기준으로 합니다. 제3자 라이선스 안내는 [배포 README](tools/python_map_editor/README.txt)에 있습니다.
