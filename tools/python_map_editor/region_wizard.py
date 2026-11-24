"""Build the native editor's three adventure layouts in a Python draft."""

from document import MapDocument
from objects import MIN_SIZE, DocumentError, MapObject, ObjectProperties
from region_design import SPAWN_SLOTS, RegionDesign, RegionEnvironment, RegionPoint, SpawnPoint

TEMPLATES = ("empty", "flat", "platform")


def create_region(region_id, name, width, height, template, slots, environment, known_ids=()):
    draft = MapDocument(region_id, name, width, height)
    if not name.strip():
        raise DocumentError("지역 표시 이름을 입력하세요.")
    if region_id in known_ids:
        raise DocumentError(f"이미 인덱스에 있는 지역 ID입니다. {region_id}")
    if template not in TEMPLATES or type(slots) is not int or not 1 <= slots <= SPAWN_SLOTS:
        raise DocumentError("템플릿 또는 스폰 슬롯 수가 올바르지 않습니다.")
    if not isinstance(environment, RegionEnvironment):
        raise DocumentError("환경 설정이 올바르지 않습니다.")

    def point(x, y):
        return round(x * width / 1200, 3), round(y * height / 600, 3)

    def platform(key, x, y, w, h, one_way=False):
        return MapObject(key, "platform", "terrain", point(x, y),
                         tuple(max(MIN_SIZE, value) for value in point(w, h)),
                         properties=ObjectProperties(one_way=one_way))

    base = region_id[:58].rstrip("_")
    design = RegionDesign(
        (RegionPoint("initial_entry", "ENTRY", base + "_entry", point(150, 520)),
         RegionPoint("initial_escape", "ESCAPE", base + "_exit", point(1050, 520))),
        spawn_points=tuple(SpawnPoint(f"slot_{i}", i, point(150 + i * 48, 520)) for i in range(slots)),
        environment=environment, template_ladder=point(490, 454) if template == "platform" else None,
    )
    objects = ()
    if template != "empty":
        objects = (platform("flat_ground", 600, 565, 1200, 60),)
    if template == "platform":
        objects += (platform("low_platform", 490, 444, 200, 20, True),
                    platform("high_platform", 800, 365, 220, 20, True))
    return MapDocument(draft.region_id, draft.display_name, draft.width, draft.height, objects=objects, design=design)
