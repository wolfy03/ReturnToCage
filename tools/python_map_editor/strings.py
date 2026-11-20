"""Korean UI text. Stable keys allow additional translations."""

KO = {
    "file": "파일", "edit": "편집", "view": "보기", "region": "지역", "help": "도움말",
    "new": "새 맵", "open": "열기", "save": "저장", "save_as": "다른 이름으로 저장",
    "exit": "종료", "zoom_in": "확대", "zoom_out": "축소", "fit": "화면에 맞춤",
    "actual": "100% 보기", "grid": "격자", "about": "조작 방법",
    "structure": "맵 구성", "bounds": "영역 경계", "inspector": "속성",
    "document": "맵 문서", "region_id": "지역 ID", "display_name": "표시 이름",
    "width": "너비", "height": "높이", "output": "출력", "position": "좌표",
    "default_name": "새 지역", "unit": " px", "dirty": "저장하지 않은 변경",
    "saved": "저장됨", "draft": "새 문서", "document_filter": "ReturnToCage 맵 문서 (*.rtcmap)",
    "opened": "맵을 열었습니다 · {path}", "written": "맵을 저장했습니다 · {path}",
    "invalid": "문서를 처리할 수 없습니다", "conflict": "파일 충돌",
    "conflict_detail": "다른 편집기에서 저장 중이거나 대상 파일이 바뀌었습니다. 파일을 다시 열거나 다른 이름으로 저장하세요.",
    "overwrite_title": "기존 파일 덮어쓰기",
    "overwrite_body": "이 파일을 덮어쓰시겠습니까?\n{path}",
    "confirm_title": "변경 내용 저장",
    "confirm_body": "현재 맵의 변경 내용을 저장하시겠습니까?",
    "discard": "변경 버리기", "cancel": "취소",
    "pan": "화면 이동", "pan_tip": "이동 모드 또는 마우스 가운데 버튼을 누르고 드래그",
    "quick_help": "휠로 확대·축소 · 가운데 버튼으로 이동",
    "about_body": "마우스 휠로 커서 위치를 확대·축소합니다.\n가운데 버튼 또는 이동 모드에서 드래그하여 화면을 이동합니다.\nF 키를 누르면 영역 경계가 화면에 맞춰집니다.\n맵 문서는 .rtcmap JSON 파일로 저장됩니다.",
}


def tr(key):
    return KO[key]
