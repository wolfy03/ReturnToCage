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


# ------------------------------------------------------------------------------- animation workspace (STEP 3)
ROLE_LABELS = {"idle": "대기 (idle)", "move": "이동 (move)", "attack": "공격 (attack)", "hurt": "피격 (hurt)",
               "death": "사망 (death)", "jump_start": "도약 준비 (jump_start)", "jump": "상승 (jump)",
               "fall": "하강 (fall)", "land": "착지 (land)"}
SHAPE_LABELS = {"rectangle": "사각형", "circle": "원"}
SHAPE_KIND_LABELS = {"body": "Body", "hurtbox": "Hurtbox", "override": "Hurtbox (override)", "hitbox": "Hitbox"}
ANIMATION = {
    "title": "Animation / Collision",
    "tab_sources": "이미지 · Clip", "tab_clip": "Clip · 역할 · 배치", "tab_shapes": "판정",
    "images": "Images", "clips": "Animation Clips", "clip_settings": "Clip", "roles": "역할 연결",
    "visual": "화면 배치", "shapes": "판정 도형",
    "image_path_hint": "프로젝트 기준 PNG 경로 (예: assets/characters/enemies/ant/idle.png)",
    "browse": "찾아보기…", "register": "등록", "refresh_image": "크기·해시 갱신", "remove": "삭제",
    "clip_id": "새 Clip ID", "clip_id_hint": "비우면 자동 (clip, clip_2 …)",
    "columns": "열", "rows": "행", "count": "frame 수", "all_frames": "전체",
    "clip_from_grid": "격자로 Clip 만들기", "clip_from_images": "선택 이미지로 Clip 만들기",
    "play": "재생", "pause": "일시정지", "stop": "처음으로", "flip": "좌우 반전 미리보기", "zoom": "배율",
    "play_tip": "재생하거나 일시정지한 곳에서 이어서 재생합니다. 끝난 one-shot Clip은 처음부터 재생합니다.",
    "stop_tip": "재생을 멈추고 첫 frame으로 돌아갑니다.",
    "playback_state": {"stopped": "정지", "playing": "재생 중", "paused": "일시정지"},
    "playing_read_only": "재생 중에는 판정을 편집할 수 없습니다. 일시정지한 뒤 편집하세요.",
    "drag_cancelled": "드래그를 취소했습니다. 문서는 바뀌지 않았습니다.",
    "rename": "ID 변경…", "rename_clip": "Clip '{clip}'의 새 ID (참조하는 곳도 함께 바뀝니다)",
    "rename_box": "판정 '{box}'의 새 ID",
    "duplicate_frame": "복제", "duplicate_frame_tip": "이 frame을 바로 뒤에 한 번 더 넣습니다. 전용 Hurtbox는 복사하지 않습니다.",
    "hit_frame": "타격 frame", "hit_frame_tip": "공격 역할 Clip에서 타격이 보이는 첫 frame 번호입니다. 표현 전용이며 "
                                              "실제 피해 시각을 정하지 않습니다.",
    "last_frame": "Clip의 마지막 frame은 삭제할 수 없습니다. Clip을 삭제하세요.",
    "frame_option": "frame {frame}",
    "hit_frame_removed": "frame {frame}은 공격의 타격 frame입니다.\n삭제하면 어느 frame이 타격을 보여 줄지 선택하세요. "
                         "(번호는 삭제 전 기준)",
    "hit_frame_blocked": "적용하지 않았습니다: frame {frame}은 타격 frame입니다. 타격 frame을 먼저 다른 frame으로 정하세요.",
    "frame_override_removed": "frame {frame}에는 전용 Hurtbox 세트가 있습니다.\nframe을 삭제하면 그 세트도 함께 삭제됩니다. 계속할까요?",
    "clip_removal": "Clip '{clip}'을 삭제하면 다음도 함께 정리됩니다.\n{usages}\n\n역할 연결은 비워지고 전용 Hurtbox 세트는 삭제됩니다. 계속할까요?",
    "clip_in_use": "Clip '{clip}'을 공격 패턴·AI가 사용하고 있습니다.\n{usages}\n\n이 참조들이 대신 사용할 Clip을 선택하세요. "
                   "공격 패턴이나 상태는 삭제되지 않습니다.",
    "clip_blocked": "적용하지 않았습니다: Clip '{clip}'을 {usages}가 사용 중입니다. 먼저 그쪽을 고치거나 대체 Clip을 선택하세요.",
    "image_in_use": "이미지 '{image}'를 Clip {clips}의 frame {count}개가 사용 중입니다.\nframe은 삭제하지 않습니다. "
                    "대신 사용할 이미지를 선택하세요. (크기가 맞아야 합니다)",
    "hitbox_in_use": "Hitbox '{hitbox}'를 공격 이벤트가 사용하고 있습니다.\n{usages}\n\n대신 사용할 Hitbox를 선택하세요.",
    "anchor_mixed": "이 Clip은 frame 크기가 서로 다릅니다. 첫 frame 기준으로 맞췄습니다. Schema V1에는 frame별 기준점이 없어 "
                    "다른 frame은 발 위치가 어긋날 수 있습니다.",
    "runtime_note": "Hitbox와 전용 Hurtbox 세트는 문서에 저장만 됩니다. 현재 게임 런타임은 이 값을 사용하지 않습니다.",
    "duration": "지속", "frame_earlier": "◀", "frame_later": "▶", "remove_frame": "삭제",
    "duration_tip": "frame 지속 시간의 배수입니다. 초 = 지속 ÷ FPS.", "frame_earlier_tip": "이 frame을 앞으로 옮깁니다.",
    "frame_later_tip": "이 frame을 뒤로 옮깁니다.", "remove_frame_tip": "이 frame을 Clip에서 뺍니다.",
    "fps": "FPS", "loop": "반복 재생 (loop)",
    "visual_scale": "visual_scale (x, y)", "visual_offset": "visual_offset (x, y)",
    "foot_margin": "발 아래 여백(px)", "bottom_center": "Bottom-center 맞춤",
    "shape_type": "모양", "center": "중심 (x, y)", "size": "크기 (w, h)", "radius": "반지름",
    "enabled": "사용", "add_hurtbox": "Hurtbox 추가", "add_hitbox": "Hitbox 추가",
    "override_frame": "이 frame 전용 Hurtbox", "override_clip": "이 Clip 전용 Hurtbox", "override_clear": "전용 Hurtbox 해제",
    "override_none": "기본 Hurtbox 세트를 쓰는 frame입니다.",
    "override_clip_state": "이 Clip 전체에 전용 Hurtbox 세트가 적용됩니다.",
    "override_frame_state": "frame {frame} 전용 Hurtbox 세트가 적용됩니다.",
    "disabled_suffix": "  (꺼짐)", "no_clip": "(없음)",
    "role_required": "필수 역할입니다. Clip을 연결해야 합니다.", "role_loops": "이 역할의 Clip은 loop여야 합니다.",
    "no_document": "문서가 열려 있지 않습니다.", "no_clip_selected": "Clip을 만들거나 선택하세요.",
    "select_one_image": "격자로 나눌 이미지를 하나만 선택하세요.", "select_images": "Clip에 넣을 이미지를 선택하세요.",
    "read_only": "기존 게임 리소스에서 가져온 문서입니다. 이미지·Clip·판정은 읽기 전용이며 미리보기만 할 수 있습니다.",
    "refused": "적용하지 않았습니다: {error}",
    "time": "frame {frame} / {count} · {position:.3f} / {seconds:.3f} s · {state}",
    "labels": {"register": "이미지 등록", "refresh": "이미지 정보 갱신", "remove_image": "이미지 삭제", "clip": "Clip 추가",
               "remove_clip": "Clip 삭제", "fps": "FPS 변경", "loop": "loop 변경", "duration": "frame 지속 변경",
               "move_frame": "frame 순서 변경", "remove_frame": "frame 삭제", "role": "역할 연결", "visual": "화면 배치 변경",
               "anchor": "Bottom-center 맞춤", "shape": "판정 도형 수정", "add_box": "판정 추가", "remove_box": "판정 삭제",
               "override": "전용 Hurtbox 변경", "duplicate_frame": "frame 복제", "rename": "ID 변경",
               "hit_frame": "타격 frame 변경"},
}


def role_label(role):
    return ROLE_LABELS.get(role, role)


def shape_label(kind):
    return SHAPE_LABELS.get(kind, kind)


def shape_kind_label(kind):
    return SHAPE_KIND_LABELS.get(kind, kind)


STAGE = {
    "passed": "Staging 통과: Godot이 Clip {clips}개의 SpriteFrames와 EnemyAnimationProfile을 만들었고 문서와 일치합니다 "
              "(확인용 actor: {carrier}). 프로젝트 파일은 바뀌지 않았습니다.",
    "differs": "Godot이 만든 리소스가 문서와 다릅니다. 프로젝트 파일은 바뀌지 않았습니다.",
    "unconfirmed": "Staging 구조는 일치하지만 확정된 결과가 아닙니다: 검증하는 동안 프로젝트 파일이 바뀌었습니다 "
                   "(Clip {clips}개, 확인용 actor: {carrier}). 다른 프로그램의 저장이 끝난 뒤 다시 실행하세요.",
    "crashed": "(Godot이 {count}회 비정상 종료해 다시 실행했습니다. 그 실행의 결과는 쓰지 않았습니다.)",
    "notes": "(참고 {count}건)",
    "leftover": "Staging 작업 폴더를 지우지 못했습니다. 실제 프로젝트에는 영향이 없습니다.\n\n{detail}",
    "state": {"none": "Staging: 미실행", "passed": "Staging: 구조 일치 (실제 렌더링·전투는 미검사)",
              "differs": "Staging: 문서와 다름", "stale": "Staging: 오래됨 (문서나 프로젝트가 바뀜)",
              "unconfirmed": "Staging: 구조는 일치, 확정 아님 (검증 중 프로젝트가 바뀜 — 다시 실행)"},
}
