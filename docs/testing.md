# 테스트와 실행 검증

## 자동 테스트

```powershell
& 'C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' --headless --path . res://tests/test_runner.tscn
```

러너는 실패 시 종료 코드 1을 반환한다. ItemStack/중첩/overflow/제거/무게, 장비 장착, 음식 사용, 생존 임계값, Modifier와 버프 갱신·만료, seed 고정 LootTable, 세 가지 사망 손실과 장비 정책, 보호 아이템, Registry 중복/누락 참조, 퀘스트, 시설 비용, v1 Migration, 저장 round-trip, 미등록 저장 ID, 손상 JSON, 전체 원정 성공/사망 흐름과 두 월드 실제 로드를 검증한다.

## 콘텐츠 검증

```powershell
& 'C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' --headless --path . res://core/validation/validate_content.tscn
```

## 에디터/메인 씬 검사

```powershell
& 'C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' --headless --path . --editor --quit
& 'C:\Users\maker\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe' --headless --path . --quit-after 60
```

## 수동 플레이 절차

1. 에디터에서 F6이 아니라 프로젝트 실행(F5) 후 `New Game`을 누른다.
2. A/D, Space로 Milo에게 이동하고 E로 샘플 퀘스트를 받는다.
3. 오른쪽 하수구 문에서 E를 눌러 원정 Context와 함께 진입한다.
4. 두 Scrap 지점에서 E로 총 4개를 채집하고 J로 딱정벌레를 공격한다.
5. HUD의 Eat/Drink 버튼으로 회복과 데이터 기반 버프를 확인한다.
6. 시작 입구 또는 우측 사다리에서 E로 탈출한다. Q 귀환 씨앗은 3초 정지해야 성공하며 이동/피격 시 소모 없이 취소된다.
7. 정착지 작업대에서 E를 눌러 Scrap 3개를 쓰고 레벨/색/기능 상태 변화를 확인한다.
8. Milo에게 돌아가 보상을 받고 Archive post 또는 HUD Save로 저장한다.
9. 새 게임으로 상태를 바꾼 뒤 Load하여 창고, 시설, 퀘스트, 생존/체력과 난이도를 비교한다.
10. F10 개발 패널에서 무적, 생존 정지, 수치 변경, 아이템/자원 지급, 강제 사망, 시설 업그레이드, 검증과 상태 출력을 확인한다.
