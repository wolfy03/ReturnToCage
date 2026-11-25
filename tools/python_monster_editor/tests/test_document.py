import json

import pytest

from conftest import EXAMPLE_IDS, EXAMPLES, edit, load
from rtcmonster import (DOCUMENT_TYPE, FAIL, SCHEMA_VERSION, DocumentError, MonsterDocument, decode, encode,
                        new_document, validate, validate_payload)
from rtcmonster.schema import TOP_LEVEL_ORDER


def raw(document, **changes):
    data = json.loads(encode(document))
    data.update(changes)
    return json.dumps(data).encode()


def test_a_new_document_is_valid_and_fills_every_default():
    document = new_document("moss_slug", "Moss Slug")
    data = document.data
    assert document.monster_id == "moss_slug" and data["metadata"]["display_name"] == "Moss Slug"
    assert data["stats"] == {"max_health": 20, "attack_damage": 4, "move_speed": 55, "chase_range": 230,
                             "attack_range": 42, "faction": "hostile", "hit_invulnerability_seconds": 0.35,
                             "planned": {"defense": 0, "attack_speed": 1, "knockback_resistance": 0,
                                         "stagger_resistance": 0, "damage_resistances": {},
                                         "status_resistances": {}}}
    assert data["movement"]["gravity"] == 1100 and data["source_binding"] is None
    assert [state["id"] for state in data["behavior"]["states"]] == ["idle", "hurt", "dead"]
    assert data["behavior"]["states"][0]["params"] == {"seconds": 1}  # module defaults are filled in
    assert not validate(document).select(FAIL)


def test_encoding_is_canonical_json_with_the_documented_layout():
    payload = encode(new_document("moss_slug", "이끼 민달팽이"))
    text = payload.decode("utf-8")
    assert text.endswith("}\n") and "\r" not in text and "이끼 민달팽이" in text
    data = json.loads(text)
    assert tuple(data) == TOP_LEVEL_ORDER
    assert data["schema_version"] == SCHEMA_VERSION and data["document_type"] == DOCUMENT_TYPE
    assert '"size": [32, 22]' in text  # vectors stay on one line for readable diffs


@pytest.mark.parametrize("name", EXAMPLE_IDS)
def test_examples_reopen_without_any_byte_changing(name):
    payload = (EXAMPLES / f"{name}.rtcmonster").read_bytes()
    document = decode(payload)
    assert encode(document) == payload
    assert decode(encode(document)) == document


def test_equivalent_data_always_serializes_to_the_same_bytes(beetle):
    data = json.loads(encode(beetle))
    shuffled = {key: data[key] for key in reversed(list(data))}
    shuffled["stats"] = {key: data["stats"][key] for key in reversed(list(data["stats"]))}
    shuffled["stats"]["max_health"] = 24.0          # same value, different spelling
    del shuffled["movement"]["ground_brake"]        # a default left out
    payload = json.dumps(shuffled, indent=7).encode()
    assert payload != encode(beetle)
    assert decode(payload) == beetle and encode(decode(payload)) == encode(beetle)


def test_documents_are_immutable_and_edits_return_new_documents(beetle):
    with pytest.raises(AttributeError):
        beetle.data = {}
    changed = beetle.replace(("stats", "max_health"), 30)
    assert changed.data["stats"]["max_health"] == 30 and beetle.data["stats"]["max_health"] == 24
    assert changed != beetle and beetle.to_dict() is not beetle.data
    with pytest.raises(DocumentError, match="no such field"):
        beetle.replace(("stats", "mana"), 1)
    with pytest.raises(DocumentError, match="expected a number"):
        beetle.replace(("stats", "max_health"), "many")


@pytest.mark.parametrize("version, message", [(0, "unsupported"), (2, "newer editor"), (99, "newer editor"),
                                              ("1", "schema_version"), (1.0, "schema_version"),
                                              (True, "schema_version"), (None, "schema_version")])
def test_unsupported_schema_versions_are_rejected(beetle, version, message):
    with pytest.raises(DocumentError, match=message):
        decode(raw(beetle, schema_version=version))


@pytest.mark.parametrize("payload", [
    b"", b"{", b"[]", b"null", b"\xff\xfe", b'{"schema_version": 1}',
    b'{"schema_version": 1, "document_type": "rtcmap"}',
    b'{"schema_version": 1, "schema_version": 1, "document_type": "rtcmonster"}',
])
def test_damaged_or_foreign_files_are_rejected(payload):
    with pytest.raises(DocumentError):
        decode(payload)
    report = validate_payload(payload)
    assert report.status("schema") == FAIL and report.codes() == {"unreadable_document"}
    assert report.status("ai") == "NOT_EVALUATED"


@pytest.mark.parametrize("literal", ["NaN", "Infinity", "-Infinity", "1e999"])
def test_non_finite_numbers_are_rejected(beetle, literal):
    payload = encode(beetle).replace(b'"max_health": 24', f'"max_health": {literal}'.encode())
    assert payload != encode(beetle)
    with pytest.raises(DocumentError):
        decode(payload)
    with pytest.raises(DocumentError, match="finite"):
        beetle.replace(("stats", "max_health"), float("nan"))


@pytest.mark.parametrize("change, message", [
    (lambda data: data.update(extra=1), "unknown field"),
    (lambda data: data["stats"].update(mana=3), "unknown field"),
    (lambda data: data.pop("monster_id"), "required"),
    (lambda data: data.pop("collision"), "required"),
    (lambda data: data.update(monster_id="Sewer Beetle"), "snake_case"),
    (lambda data: data.update(monster_id="../frog"), "snake_case"),
    (lambda data: data["stats"].update(max_health="24"), "number"),
    (lambda data: data["stats"].update(max_health=True), "number"),
    (lambda data: data["animations"]["clips"][0].update(loop=1), "true or false"),
    (lambda data: data["metadata"].update(rank="legendary"), "expected one of"),
    (lambda data: data["metadata"].update(display_name="a\nb"), "control characters"),
    (lambda data: data["collision"]["body"].update(shape={"type": "polygon", "points": []}), "unknown type"),
    (lambda data: data["collision"]["body"]["shape"].update(size=[1, 2, 3]), "list of 2"),
    (lambda data: data["attack_patterns"][0]["events"].append({"type": "RunScript", "time": 0}), "unknown type"),
    (lambda data: data["attack_patterns"][0]["events"][0].update(code="OS.execute()"), "unknown field"),
    (lambda data: data["behavior"]["states"][0]["transitions"][0].update(condition={"type": "Eval"}), "unknown type"),
    (lambda data: data["behavior"]["states"][0]["params"].update(script="res://x.gd"), "unknown field"),
    (lambda data: data["assets"]["images"][0].update(path="C:/art/idle.png"), "unsafe"),
    (lambda data: data["assets"]["images"][0].update(path="../outside/idle.png"), "unsafe"),
    (lambda data: data["assets"]["images"][0].update(path="/etc/idle.png"), "unsafe"),
    (lambda data: data["assets"]["images"][0].update(path="assets\\idle.png"), "unsafe"),
    (lambda data: data["assets"]["images"][0].update(path="assets/idle.gd"), "must end with"),
])
def test_unreadable_shapes_cannot_be_opened(beetle, change, message):
    with pytest.raises(DocumentError, match=message):
        edit(beetle, change)


def test_conditions_cannot_nest_without_bound(beetle):
    condition = {"type": "Always"}
    for _ in range(12):
        condition = {"not": condition}
    with pytest.raises(DocumentError, match="nest deeper"):
        edit(beetle, lambda data: data["behavior"]["states"][0]["transitions"][0].update(condition=condition))


def test_a_document_cannot_carry_code_or_arbitrary_scenes(rat):
    text = encode(rat).decode()
    assert ".gd" not in text and ".tscn" not in text and "res://" not in text
    # A module is named, never defined: an unknown name opens but is reported.
    unknown = edit(rat, lambda data: data["behavior"]["states"][0].update(module="RunGdscript", params={"x": 1}))
    assert "unknown_module" in validate(unknown).codes()


def test_documents_are_bounded_in_size():
    document = new_document("big_one", "Big")
    with pytest.raises(DocumentError, match="at most"):
        edit(document, lambda data: data["metadata"].update(description="x" * 2001))
    with pytest.raises(DocumentError, match="size limit"):
        decode(b" " * (8 * 1024 * 1024 + 1))
    assert isinstance(load("frog"), MonsterDocument)
