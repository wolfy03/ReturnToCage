"""Reusable relative placements for the platform and decoration editor."""

from dataclasses import asdict, replace
import json

from objects import DocumentError, MapObject, validate_text

MAX_PRESET_OBJECTS = 128  # Matches the Godot Field Editor preset limit.
MAX_PRESET_BYTES = 256 * 1024


def capture_preset(name, objects):
    validate_text(name, 80)
    if not name or not 1 <= len(objects) <= MAX_PRESET_OBJECTS:
        raise DocumentError("프리셋은 이름과 1~128개 플랫폼 또는 장식이 필요합니다.")
    x, y = objects[0].position
    relative = [replace(obj, position=(obj.position[0] - x, obj.position[1] - y)) for obj in objects]
    return json.dumps({"version": 1, "name": name, "objects": [asdict(obj) for obj in relative]},
                      ensure_ascii=False, allow_nan=False)


def load_preset(payload):
    if not isinstance(payload, str) or len(payload.encode("utf-8")) > MAX_PRESET_BYTES:
        raise DocumentError("프리셋 형식 또는 크기가 올바르지 않습니다.")
    try:
        data = json.loads(payload)
        if (not isinstance(data, dict) or data.keys() != {"version", "name", "objects"}
                or type(data["version"]) is not int or data["version"] != 1
                or not isinstance(data["objects"], list) or not 1 <= len(data["objects"]) <= MAX_PRESET_OBJECTS):
            raise DocumentError("프리셋 형식이 올바르지 않습니다.")
        validate_text(data["name"], 80)
        return data["name"], tuple(MapObject.from_data(item) for item in data["objects"])
    except (TypeError, ValueError, RecursionError) as error:
        raise DocumentError(f"프리셋을 읽을 수 없습니다. {error}") from error
