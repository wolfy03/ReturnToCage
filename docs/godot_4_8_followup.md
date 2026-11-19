# Godot 4.8 beta 4 후속 조사

**BLOCKED — 주 개발 버전은 4.7.2.** 이 문서는 `3c029cd`의 [검증 보고서](godot_4_8_migration_validation.md)를 보완한다. 기존 실행과 실패 기록은 해당 커밋과 원래 로그 위치에 보존했다.

## Rendered Editor

- **테스트 입력** `native_hover_id=-1`이 찍힌 실행에서는 창 ID와 실제 마우스 좌표를 얻었지만 해당 좌표를 소유한 Godot 창을 Windows가 반환하지 않았다. beta 4의 `Viewport::_update_mouse_over()`는 native window에서 DisplayServer가 전달한 `windowmanager_window_over`를 사용한다. 포커스 또는 맞는 좌표만으로 Control의 hover를 입증할 수 없다. 기존 4.7.2 비교에서도 입력 미도달이 관찰됐다. `TEST_HARNESS_FAILURE`로 기록하며 popup 좌표나 창 상태의 정확한 재현 원인은 남아 있다. [공식 뷰포트 코드](https://github.com/godotengine/godot/blob/b070e63b161aa816afac71dcfc9d60859d38f220/scene/main/viewport.cpp#L3282-L3308)
- **네이티브 접근 위반** beta 4 렌더링 에디터 PID 8664, 스레드 6088은 GUI 성공 마커 전에 `0xC0000005`로 종료했다. 예외 주소는 모듈 RVA `0x195b962`, 읽기 대상은 `0x7000000140`이다. 공식 Windows x64 디버그 자산은 PDB 대신 PE/COFF·DWARF 별도 심볼을 제공한다. EXE와 심볼의 CodeView GUID `443f8dab-0dbf-8a43-8707-a19913c0fd92` 및 age 1이 일치했고 EXE의 `gnu_debuglink` CRC `0xa2467c0a`도 검증했다. [공식 beta 4 릴리스 자산](https://github.com/godotengine/godot-builds/releases/tag/4.8-beta4)

```text
0x195b962  EditorFileSystemDirectory::get_subdir_count() const
0x17f2048  EditorHelp::_reload_scripts_documentation(EditorFileSystemDirectory*)
0x17f2061  EditorHelp::_reload_scripts_documentation(EditorFileSystemDirectory*)
0x17f2af7  EditorHelp::_regen_script_doc_thread(void*)
0x3776acd  Thread::callback(...)
```

이 스택은 스크립트 문서 재생성 스레드의 파일시스템 디렉터리 순회에서 발생한 `ENGINE_NATIVE_FAILURE`다. 소스상 로더 스레드는 현재 파일시스템 트리 포인터를 받아 재귀 순회하며, EditorFileSystem은 재스캔이나 종료에서 트리를 해제하는 경로를 가진다. 유사 스택의 업스트림 보고가 있지만 이 덤프만으로 어느 경로가 포인터를 무효화했는지 확정할 수 없다. 기존 `GDScriptLanguage::finish()` 종료 크래시와 별도로 추적한다. [EditorHelp 소스](https://github.com/godotengine/godot/blob/b070e63b161aa816afac71dcfc9d60859d38f220/editor/doc/editor_help.cpp#L3245-L3297) · [유사 업스트림 이슈](https://github.com/godotengine/godot/issues/122158)

## Headless Editor

이전 두 실패는 import 성공 후 fixture 에디터 실행에서 발생했다. 공식 `ResourceFormatLoaderText::get_dependencies()`의 해당 오류 분기는 `FileAccess::open(p_path, READ)`가 실패했을 때 실행된다. 로그에는 읽지 못한 경로와 OS 오류가 없다. fixture의 저장과 재열기, 파일시스템 스캔 시점, UID나 캐시 모드 중 무엇이 관련됐는지는 `UNKNOWN`이다. 새 브랜치의 부분 검증에서 전체 스크립트 파싱과 Headless 3회가 모두 종료 코드 0으로 통과했다. 이전 실패를 포함한 판정은 보류 상태다. [공식 ResourceLoader 소스](https://github.com/godotengine/godot/blob/b070e63b161aa816afac71dcfc9d60859d38f220/scene/resources/resource_format_text.cpp#L1550-L1560)

## 3인 ENet

기존 beta 4 5회차에서는 세 peer 연결과 스폰까지 도달했다. host가 B의 위치 150, C의 위치 198에서 방향 -1의 명령을 보내고, B 클라이언트는 시작과 최종 위치 150을 보고했다. 같은 배치와 방향으로 성공한 실행도 있다. 현 코드에서 이동 입력은 양쪽의 World Ready 확인을 통과해야 서버에 도달하며, Transform Snapshot은 서버의 복제 준비 확인과 클라이언트의 world/revision 확인을 거친다. 기존 run에는 입력 sequence 수락과 authoritative transform 송신 및 적용을 함께 추적한 로그가 없으므로 어느 경계에서 정지했는지는 `UNKNOWN`이다. Stamina 단계 전에 실패했고 heartbeat는 유지했다.

## 증거

- 분리 검증 로그는 상위 `validation/branch-separation-20261119-172757`의 `engine-upgrade-e9wuodt2`와 `beta4-coff-stack-recheck.log`에 있다.
- 원본 WER 덤프는 같은 상위 `validation/dumps/Godot_v4.8-beta4_win64.exe.8664.dmp`에 있다. 디버그 바이너리와 덤프는 Git 외부에 보관한다.
- 새 beta 4 프로필의 전체 게이트는 `upgrade/godot-4.8` CI에서 실행한다. 로컬 parse/headless 확인은 `NOT VERIFIED`로 기록했다.
