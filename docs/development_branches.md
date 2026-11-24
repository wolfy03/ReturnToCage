# ReturnToCage 개발 브랜치

| 브랜치 | 프로젝트 디렉터리 | Godot | 작업 범위 |
| --- | --- | --- | --- |
| `master` | `return-to-cage` | 4.7.2 stable | 검증된 게임 및 Field Editor 변경 통합 |
| `feature/field-editor` | `return-to-cage-editor` | 4.7.2 stable | Field Editor STEP 7 개선과 이후 편집 기능 개발 |
| `feature/python-map-editor` | `return-to-cage-python-editor` | GUI·EXE는 독립 실행 · 향후 연동은 4.7.2 | ReturnToCage 내부 Python Map Editor |
| `upgrade/godot-4.8` | `return-to-cage-godot48` | 4.8 beta 4 | 엔진 호환성 및 전체 회귀 검증 |
| `test/godot-4.8-beta4` | `return-to-cage-4.8` | 4.8 beta 4 | 최초 beta 4 검증과 커밋 `3c029cd`의 보존 |

표의 디렉터리는 같은 상위 폴더에 둔다. Field Editor는 `origin/master`의 `55f93646a0298d724728f7700f3ce194ed7ebfa8`에서 분기했다. 업그레이드 브랜치는 `3c029cd27c6380a158eb8b788282ac0ec3819093`을 계승했다. `godot-4.7.2-rollback`은 동일한 master 기준 커밋을 가리킨다.

각 worktree에는 별도 `.godot`, 임포트 파일, Shader Cache, Editor Metadata, Traversal 작업 공간과 `build` 경로가 있다. 실행기는 Git이 각 worktree에 할당한 관리 경로 아래 `rtc-development`에 엔진 위치와 전용 Godot 사용자 데이터를 저장한다. 검증은 실행마다 새 사용자 데이터 디렉터리를 만든다. 다른 worktree에서 `.godot`를 복사하면 이 경계가 깨진다.

## 엔진 설정 및 실행

Python 3.10 이상과 공식 Windows x64 콘솔 실행 파일 및 같은 디렉터리의 Godot 본체를 준비한다. PowerShell에서 대상 worktree로 이동한다.

```powershell
python tools/launch_editor.py --configure --godot "<해당 버전의 Godot_console.exe>"
python tools/launch_editor.py
```

업그레이드 worktree에서 일치하는 공식 Export Template의 추출 폴더도 저장할 수 있다.

```powershell
python tools/launch_editor.py --configure --godot "<beta 4 실행 파일>" --templates "<version.txt 및 Windows x64 EXE가 있는 폴더>"
```

master에서는 Field Editor worktree의 런처에 명시적으로 대상을 지정한다. master에 런처 파일을 추가할 필요가 없다.

```powershell
# return-to-cage-editor에서 실행
python tools/launch_editor.py --configure --worktree ../return-to-cage --godot "<4.7.2 실행 파일>"
python tools/launch_editor.py --worktree ../return-to-cage
```

런처와 러너는 절대 실행 경로, `--version`, 공식 빌드 식별자, SHA-256을 출력하며 PATH에서 Godot를 검색하지 않는다. master와 Field Editor는 `.godot-version`의 안정 버전을 사용한다. 업그레이드는 별도 `.godot-upgrade-version`의 후보 빌드를 확인한다. 이 파일은 검증 입력으로 쓰이며 프로젝트의 공용 엔진 pin은 승인 후에 바꾼다.

## 검증 프로필과 CI

독립 Python Map Editor의 소스는 이 저장소의 `tools/python_map_editor/`에 있다. Python 테스트, Qt GUI, Windows EXE 빌드와 실행은 경로 기반 [PY 전용 CI](../.github/workflows/python-map-editor.yml)에서 검사한다. 기능 브랜치 푸시는 이 CI를 사용한다. 향후 Godot 통합 코드가 함께 변경된 경우 master 대상 PR의 게임 검증과 관련 4.7.2 통합 검사를 실행한다. 설치·빌드·기존 별도 저장소의 이전 사항은 [Python Map Editor 가이드](python_map_editor.md)를 참조한다.

| 프로필 | 명령 | 검사 범위 |
| --- | --- | --- |
| Editor | `python tools/validate_project.py --profile editor` | Headless와 실제 GUI 입력, Dock·배치 도구·Region 흐름, 저장·재열기, Traversal, 취소·프로세스·결과 파일 관리 |
| Runtime | `python tools/validate_project.py --profile runtime` | 전체 프로젝트와 실제 부팅, 콘텐츠, 게임 및 재시작 검증 |
| Runtime ENet | `python tools/validate_project.py --profile runtime --players 2 --players 3` | Runtime 검증에 선택한 peer 수별 Spawn, World 전환, 이동·상태 복제 검증을 1회씩 추가 |
| Engine Upgrade | `python tools/validate_project.py --profile engine-upgrade` | 공식 Windows 템플릿을 사용한 전체 승인 게이트 |

프로필은 `--godot`로 로컬 설정을 명시적으로 덮어쓸 수 있다. `--plan`은 실행 범위를 출력하고 결과를 `NOT VERIFIED`로 표시한다. `--upgrade-case parse` 같은 부분 진단은 전환 승인으로 계산되지 않는다. 업그레이드 전체 게이트는 Physics, PlayerActor, Traversal 각 10회, Headless 및 Rendered Editor 각 3회, 2인 및 3인 ENet 각 10회, 전체 프로젝트, Scene/Resource 저장·재열기, Windows Release Export와 실제 EXE 부팅을 요구한다.

GitHub Actions에서 Field Editor 브랜치의 push와 이 브랜치를 대상으로 하는 PR은 Editor 프로필을 실행한다. Spawn·World·런타임·콘텐츠·관련 fixture의 경로가 바뀌면 Runtime과 2·3인 ENet을 추가한다. 분류가 불가능한 diff는 Runtime을 포함한다. 업그레이드 브랜치의 push는 독립 worktree에서 전체 엔진 게이트를 실행한다. master push와 master 대상 PR은 통합 CI를 사용한다.

호스팅 Windows CI의 렌더링 검사는 오디오 출력 장치가 없어 Godot의 `Dummy` 드라이버를 명시한다. GUI 렌더링, 실제 마우스 입력, 오류 로그 및 종료 코드 검사는 그대로 적용한다. 로컬에서는 기본 오디오 드라이버를 사용하며, 같은 CI 조건을 재현할 때만 `RTC_VALIDATION_AUDIO_DRIVER=Dummy`를 지정한다.

프로필은 필수 마커와 종료 코드 0을 함께 검사한다. 알려진 오류, 타임아웃 및 남은 소유 프로세스도 판정에 반영한다. 각 실행의 `results.json`에 `PASS`, `FAIL`, `BLOCKED`, `NOT VERIFIED`를 기록하고 증거가 있는 실패를 `EDITOR_FAILURE`, `TRAVERSAL_FAILURE`, `ENGINE_NATIVE_FAILURE`, `RUNTIME_FAILURE`, `NETWORK_FAILURE`, `TEST_HARNESS_FAILURE`로 분류한다. 원인이 불명확하면 `UNKNOWN`을 사용한다. 에디터 기능 마커 이후 child가 접근 위반으로 종료하면 `ENGINE_NATIVE_FAILURE`다.

## 병합 및 복구

- Field Editor 변경은 4.7.2 Editor 검증을 거친다. Spawn Policy, PlayerSpawnManager, RegionDefinition Runtime, SceneRouter, Entry/Exit, 서버 권위 객체·동기화를 건드리면 해당 Runtime 및 ENet 검증을 추가한다. beta 4의 승인 상태는 Field Editor의 병합 조건에 포함되지 않는다.
- 엔진 업그레이드는 전체 게이트의 승인과 master에서의 smoke test를 요구한다. beta 4는 현재 `BLOCKED`다. RC나 Stable은 `upgrade/godot-4.8-rc…` 같은 단기 검증 브랜치와 독립 worktree에서 공식 바이너리·템플릿·pin을 갱신하고 이전 로그를 보존한다.
- Field Editor 변경이 master에 병합된 후에는 업그레이드 worktree에서 `git fetch origin`과 `git merge origin/master`로 동기화한다. 최신 게임 동작과 필요한 호환 코드 양쪽을 검토하고 Scene/Resource 충돌을 개별 확인한다. 충돌 해결 뒤 관련 회귀를 다시 실행한다.
- 복구 조사는 작업 중인 디렉터리를 건드리지 않고 별도 worktree에서 `git worktree add --detach ../return-to-cage-rollback godot-4.7.2-rollback`으로 연다. 이전 공식 4.7.2 실행 파일을 지정한다. 복구 태그와 공유 브랜치 이력은 그대로 둔다.
- `export_presets.cfg`, `world/adventure/test_region.tscn`, `data/content/regions/test_region.tres`의 원본 로컬 버전을 보호한다. 파일을 정리나 커밋 경로에 포함하지 않고 작업 전후 SHA-256을 비교한다. 새 worktree에는 Git에 기록된 기준 파일만 들어간다.

## 로그와 알려진 실패

프로필 결과의 기본 위치는 각 worktree의 Git 관리 디렉터리 아래 `rtc-development/validation`이다. `--artifacts`로 Git 작업 트리 밖에 별도 상위 디렉터리를 지정할 수 있다. 각 실행의 로그는 `PROFILE LOGS` 및 `results.json`에서 찾을 수 있다. 프로필은 하위 Godot 프로세스, Traversal 작업, ENet 피어 로그를 고유 실행 폴더의 `children` 아래 보존한다. Windows CI는 이 로그들을 프로필 결과와 함께 업로드한다.

이번 분리 작업의 로컬 증거는 상위 `validation/branch-separation-20261119-172757`에 있다. 공식 4.7.2의 첫 Editor 프로필에서 Traversal Python Process 4개와 Jobs 12개가 통과했다. Headless는 액세스 위반 때문에, 렌더링은 입력 주입이 대상 Control에 도달하지 않아 실패했다. 종료·입력 실패를 원본 4.7.2 환경에서 재현했으며 프로필은 이를 구분해 기록했다.

첫 호스팅 Field Editor CI에서 렌더링 GUI 입력은 통과했지만 WASAPI 초기화 오류가 전체 렌더링 검사를 중단시켰다. Headless의 Traversal child 접근 위반은 별도의 실패다. 두 프로필의 기존 CI 증거를 `validation/branch-audit-a90245c8`에도 보존했다. [Field Editor CI 로그](https://github.com/wolfy03/ReturnToCage/actions/runs/44489202168) · [Engine Upgrade CI 로그](https://github.com/wolfy03/ReturnToCage/actions/runs/44490052474)

이전 beta 4 로그, WER 미니덤프 및 분석 결과는 상위 `validation/godot-4.8-beta4`와 `validation/dumps`에 있다. [기존 검증 보고서](https://github.com/wolfy03/ReturnToCage/blob/3c029cd27c6380a158eb8b788282ac0ec3819093/docs/godot_4_8_migration_validation.md)
