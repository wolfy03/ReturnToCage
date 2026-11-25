"""Every text the editor shows, in one place. Korean first; identifiers stay as they are in the data.

Logic never compares these strings. Lookups go from a stable key (a field path, a finding code, a status)
to a label; a missing entry falls back to the key itself, so a new schema field shows up without a
translation instead of disappearing. Adding an English table later means adding a second dictionary.
"""

APP_NAME = "ReturnToCage Monster Editor"

SECTIONS = {"metadata": "기본 정보", "stats": "능력치", "movement": "이동", "sensors": "감지", "loot": "전리품",
            "summary": "요약"}

FIELDS = {
    "monster_id": "Monster ID",
    "metadata.display_name": "표시 이름", "metadata.description": "설명", "metadata.category": "분류",
    "metadata.rank": "등급 (Rank)", "metadata.habitats": "등장 지역", "metadata.tags": "태그",
    "metadata.thumbnail": "썸네일",
    "stats.max_health": "최대 체력", "stats.attack_damage": "기본 공격력", "stats.move_speed": "이동 속도",
    "stats.chase_range": "추격 거리", "stats.attack_range": "공격 거리", "stats.faction": "진영",
    "stats.hit_invulnerability_seconds": "피격 후 무적 시간",
    "stats.planned.defense": "방어력", "stats.planned.attack_speed": "공격 속도",
    "stats.planned.knockback_resistance": "넉백 저항", "stats.planned.stagger_resistance": "경직 저항",
    "stats.planned.damage_resistances": "속성 저항", "stats.planned.status_resistances": "상태이상 저항",
    "movement.locomotion": "이동 유형", "movement.gravity": "중력", "movement.ground_brake": "지상 감속",
    "movement.ground_grace_seconds": "접지 유예 시간",
    "sensors.target_policy": "타깃 선택", "sensors.target_keep_scale": "타깃 유지 배율",
    "sensors.leash_distance": "추격 제한 거리",
    "loot.loot_table_id": "Loot Table ID", "loot.apply_difficulty_multiplier": "난이도 배율 적용",
}

CHOICES = {
    "normal": "일반", "elite": "엘리트", "boss": "보스", "ground": "지상 보행", "hop": "도약",
    "nearest_player": "가장 가까운 플레이어",
}

SUPPORT = {
    "applied": "기존 게임이 같은 값을 사용",
    "contract": "계약 정의됨 · 기존 동작을 기술",
    "planned": "예정 · 게임에 적용되지 않음",
    "editor": "편집기 전용",
}

EDITABILITY = {"editable": "편집 가능", "read_only": "읽기 전용", "unsupported": "미지원", "passthrough": "원본 보존"}

STATUS = {"PASS": "통과", "WARNING": "경고", "FAIL": "실패", "NOT_EVALUATED": "미검사"}
STATUS_COLORS = {"PASS": "#4f9d69", "WARNING": "#c9a227", "FAIL": "#c8553d", "NOT_EVALUATED": "#7d8597"}
DOMAINS = {"schema": "Schema", "references": "References", "assets": "Assets", "animation": "Animation",
           "collision": "Collision", "attack": "Attack", "ai": "AI", "compatibility": "Compatibility",
           "runtime": "Runtime", "network": "Network", "publish": "Publish"}
REMEDY = {"document": "문서의 필드", "project": "프로젝트 파일", "none": "–"}

REGISTRATION = {
    "draft": "초안", "discovered": "파일로 발견 (등록 미확인)", "registry_verified": "Godot Registry 확인",
    "not_in_registry": "Registry에 없음",
}
PROBLEMS = {
    "duplicate_id": "ID 중복", "unreadable": "읽을 수 없음", "invalid_encoding": "인코딩 오류",
    "missing_id": "ID 없음", "invalid_id": "잘못된 ID", "not_a_regular_file": "링크 또는 일반 파일 아님",
    "too_large": "파일이 너무 큼", "folder_unavailable": "폴더를 읽을 수 없음", "draft_unreadable": "손상된 초안",
    "draft_shadows_published": "게임 몬스터와 ID 충돌", "draft_duplicate_id": "초안끼리 ID 충돌",
}
ID_STATUS = {"available": "사용 가능", "conflict": "이미 사용 중", "unknown": "확인 불가 (프로젝트 미연결)"}
IMPORT_STATUS = {"complete": "완전 Import", "partial": "부분 Import", "unsupported": "미지원 (공통 정보만)",
                 "failed": "가져오기 실패"}
IMAGE_STATE = {"ok": "디코딩 통과", "missing": "파일 없음", "structure_failed": "PNG 구조 검사 실패",
               "decode_failed": "이미지 디코딩 실패", "too_large": "크기 한도 초과", "unchecked": "검사하지 않음",
               "none": "이미지 없음"}
BINDING = {"none": "초안 (게임 리소스에 묶이지 않음)", "unchanged": "원본 변경 없음", "modified": "원본 변경됨",
           "missing": "원본 삭제됨", "unknown": "검증 불가 (프로젝트 미연결)"}


def field_label(path):
    return FIELDS.get(path, path.rsplit(".", 1)[-1])


def choice_label(value):
    return CHOICES.get(value, value)
