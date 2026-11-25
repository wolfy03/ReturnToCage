"""GATE A: a document never changes, and every change goes through the edit API."""

import copy
import json
import pickle

import pytest

from conftest import load
from rtcmonster import (DocumentError, MonsterDocument, clone_document, decode, encode, format_path, insert_item,
                        move_item, new_document, parse_path, remove_item, rename_id, set_value, validate)
from rtcmonster.document import FrozenDict, FrozenList


def snapshot(document):
    return encode(document), document.fingerprint


# ----------------------------------------------------------------------------------------------- no way in
def test_the_constructor_copies_its_input():
    raw = json.loads(encode(new_document("moss_slug", "Moss Slug")))
    del raw["schema_version"], raw["document_type"]
    document = MonsterDocument(raw)
    before = snapshot(document)
    raw["stats"]["max_health"] = 999
    raw["behavior"]["states"].clear()
    raw["collision"]["body"]["shape"]["size"][0] = 1
    assert snapshot(document) == before


def test_every_container_reachable_from_data_is_frozen(frog):
    def walk(value, path="data"):
        if isinstance(value, dict):
            assert type(value) is FrozenDict, path
            for key, item in value.items():
                walk(item, f"{path}.{key}")
        elif isinstance(value, list):
            assert type(value) is FrozenList, path
            for index, item in enumerate(value):
                walk(item, f"{path}[{index}]")
        else:
            assert value is None or isinstance(value, (str, int, float, bool)), path
    walk(frog.data)


@pytest.mark.parametrize("mutate", [
    lambda d: d.__setitem__("monster_id", "x"), lambda d: d.__delitem__("stats"), lambda d: d.clear(),
    lambda d: d.pop("stats"), lambda d: d.popitem(), lambda d: d.setdefault("x", 1), lambda d: d.update(x=1),
    lambda d: d.__ior__({"x": 1}),
    lambda d: d["metadata"]["tags"].append("a"), lambda d: d["metadata"]["tags"].extend(["a"]),
    lambda d: d["metadata"]["tags"].insert(0, "a"), lambda d: d["metadata"]["tags"].__iadd__(["a"]),
    lambda d: d["behavior"]["states"].pop(), lambda d: d["behavior"]["states"].remove(d["behavior"]["states"][0]),
    lambda d: d["behavior"]["states"].clear(), lambda d: d["behavior"]["states"].reverse(),
    lambda d: d["behavior"]["states"].sort(key=str), lambda d: d["behavior"]["states"].__setitem__(0, {}),
    lambda d: d["behavior"]["states"].__delitem__(0), lambda d: d["behavior"]["states"].__imul__(2),
    lambda d: d["behavior"]["states"][0]["params"].__setitem__("seconds", 9),
    lambda d: d["collision"]["body"]["shape"]["size"].__setitem__(0, 0),
])
def test_every_mutating_method_is_refused(mutate):
    document = new_document("moss_slug", "Moss Slug")
    before = snapshot(document)
    with pytest.raises(TypeError, match="read-only"):
        mutate(document.data)
    assert snapshot(document) == before


def test_copies_handed_out_are_independent_and_plain(beetle):
    before = snapshot(beetle)
    whole = beetle.to_dict()
    part = beetle.get("behavior", "states")
    assert type(whole) is dict and type(whole["behavior"]["states"]) is list and type(part) is list
    whole["stats"]["max_health"] = -1
    whole["animations"]["clips"].clear()
    part[0]["transitions"].clear()
    part.append("junk")
    assert snapshot(beetle) == before
    for clone in (copy.deepcopy(beetle.data), copy.copy(beetle.data), pickle.loads(pickle.dumps(beetle.data))):
        assert type(clone) is dict and clone == beetle.data
        clone["monster_id"] = "changed"
    assert beetle.monster_id == "sewer_beetle"
    with pytest.raises(DocumentError, match="no such field"):
        beetle.get("stats", "mana")


def test_a_value_given_to_an_edit_can_be_changed_afterwards_without_effect():
    document = new_document("moss_slug", "Moss Slug")
    tags = ["cave"]
    state = {"id": "rest", "module": "Wait", "transitions": [
        {"to": "idle", "condition": {"type": "ActionCompleted"}}]}
    edited = document.apply(set_value(("metadata", "tags"), tags), insert_item(("behavior", "states"), state))
    before = snapshot(edited)
    tags.append("later")
    state["module"] = "Nonsense"
    state["transitions"].clear()
    assert snapshot(edited) == before and edited.data["metadata"]["tags"] == ["cave"]


def test_documents_never_share_mutable_state(beetle):
    second = beetle.replace(("stats", "max_health"), 30)
    third = second.replace(("metadata", "display_name"), "Renamed")
    plain = third.to_dict()
    plain["animations"]["clips"][0]["frames"].clear()
    assert len(beetle.data["animations"]["clips"][0]["frames"]) == 4
    assert len(second.data["animations"]["clips"][0]["frames"]) == 4
    assert beetle.data["stats"]["max_health"] == 24 and second.data["metadata"]["display_name"] == "Sewer Beetle"


def test_the_object_itself_cannot_be_rebound(beetle):
    for action in (lambda: setattr(beetle, "data", {}), lambda: setattr(beetle, "_data", {}),
                   lambda: delattr(beetle, "_data"), lambda: setattr(beetle, "anything", 1)):
        with pytest.raises(AttributeError):
            action()


def test_validation_and_saving_do_not_change_a_document(tmp_path, frog):
    from rtcmonster import write_document
    before = snapshot(frog)
    validate(frog)
    write_document(tmp_path / "frog.rtcmonster", frog)
    assert snapshot(frog) == before


# ----------------------------------------------------------------- structural boundary versus semantic drafts
def test_a_structurally_invalid_value_never_becomes_a_document(beetle):
    before = snapshot(beetle)
    for edit in (set_value(("stats", "max_health"), "many"), set_value(("stats", "max_health"), float("nan")),
                 set_value(("stats", "mana"), 1), set_value(("monster_id",), "Bad ID"),
                 insert_item(("behavior", "states"), {"module": "Wait"}),
                 insert_item(("animations", "clips"), {"id": "x", "frames": [{"rect": None}]}),
                 set_value(("collision", "body", "shape"), {"type": "polygon"}),
                 insert_item(("stats",), 1), remove_item(("behavior", "states", 99)),
                 move_item(("behavior", "states", 0), 99), set_value((), 1), "not an edit"):
        with pytest.raises(DocumentError):
            beetle.apply(edit)
    assert snapshot(beetle) == before


def test_a_semantically_wrong_draft_can_still_be_stored_and_is_reported(beetle):
    draft = beetle.apply(set_value(("stats", "max_health"), -5),
                         set_value(("behavior", "initial_state"), "ghost"))
    assert decode(encode(draft)) == draft
    assert {"out_of_range", "initial_state_missing", "unknown_state"} <= validate(draft).codes()


# ------------------------------------------------------------------------------------------------- edit API
def test_edits_are_atomic(beetle):
    before = snapshot(beetle)
    with pytest.raises(DocumentError, match="edit 1"):
        beetle.apply(set_value(("stats", "max_health"), 99), set_value(("stats", "mana"), 1))
    assert snapshot(beetle) == before and beetle.data["stats"]["max_health"] == 24


def test_list_edits_insert_remove_and_reorder(beetle):
    ids = [state["id"] for state in beetle.data["behavior"]["states"]]
    rest = {"id": "rest", "module": "Wait", "transitions": [{"to": "idle", "condition": {"type": "ActionCompleted"}}]}
    appended = beetle.apply(insert_item(("behavior", "states"), rest))
    assert [s["id"] for s in appended.data["behavior"]["states"]] == ids + ["rest"]
    assert appended.data["behavior"]["states"][-1]["params"] == {"seconds": 1}      # defaults were filled in
    first = beetle.apply(insert_item(("behavior", "states"), rest, 0))
    assert first.data["behavior"]["states"][0]["id"] == "rest"
    moved = first.apply(move_item(("behavior", "states", 0), 2))
    assert [s["id"] for s in moved.data["behavior"]["states"]][:3] == ["idle", "patrol", "rest"]
    removed = moved.apply(remove_item(("behavior", "states", 2)))
    assert removed == beetle


def test_intermediate_states_of_one_transaction_need_not_be_valid(beetle):
    # Removing the only pattern while a state still names it is invalid on its own;
    # together with re-pointing the state it is one consistent edit.
    result = beetle.apply(
        remove_item(("attack_patterns", 0)),
        insert_item(("attack_patterns",), {**beetle.get("attack_patterns", 0), "id": "snap"}),
        set_value(("behavior", "states", 3, "params", "pattern"), "snap"))
    assert not validate(result).select("FAIL")


@pytest.mark.parametrize("kind, old, new", [("state", "chase", "pursue"), ("animation", "attack", "bite_clip"),
                                            ("pattern", "bite", "snap"), ("image", "attack_strip", "atk")])
def test_renaming_an_id_updates_every_reference(beetle, kind, old, new):
    renamed = beetle.apply(rename_id(kind, old, new))
    from rtcmonster.schema import REFERENCE_SOURCES
    ids = [row["id"] for row in renamed.get(*REFERENCE_SOURCES[kind])]
    assert new in ids and old not in ids
    report, baseline = validate(renamed), validate(beetle)
    assert report.codes() == baseline.codes() == set()
    assert renamed.apply(rename_id(kind, new, old)) == beetle


def test_renaming_follows_roles_events_conditions_interrupts_and_map_keys(frog):
    edited = frog.apply(set_value(("behavior", "phases"), [
        {"id": "enraged", "health_ratio_below": 0.5, "enter_state": "alert", "pattern_weights": {"leap_bite": 2}}]))
    renamed = edited.apply(rename_id("pattern", "leap_bite", "pounce"), rename_id("hitbox", "leap_contact", "body_slam"),
                           rename_id("state", "alert", "notice"), rename_id("state", "hurt", "stagger"),
                           rename_id("animation", "idle", "rest"))
    data = renamed.data
    assert data["behavior"]["phases"][0]["pattern_weights"] == {"pounce": 2}
    assert data["behavior"]["phases"][0]["enter_state"] == "notice"
    assert data["behavior"]["interrupts"]["hurt"]["state"] == "stagger"
    assert data["attack_patterns"][0]["events"][1]["hitbox"] == "body_slam"
    assert data["presentation"]["roles"]["idle"] == "rest" and data["presentation"]["roles"]["move"] == "rest"
    chase = next(state for state in data["behavior"]["states"] if state["id"] == "chase")
    assert chase["transitions"][1]["condition"] == {"type": "AttackAvailable", "pattern": "pounce"}
    attack = next(state for state in data["behavior"]["states"] if state["id"] == "attack")
    assert attack["params"]["pattern"] == "pounce"
    assert not {code for code in validate(renamed).codes() if code.startswith("unknown_")}


def test_a_rename_that_would_collide_or_miss_is_refused(beetle):
    for edit in (rename_id("state", "chase", "idle"), rename_id("state", "ghost", "x"),
                 rename_id("state", "chase", "Bad Name"), rename_id("monster", "a", "b")):
        with pytest.raises(DocumentError):
            beetle.apply(edit)


def test_finding_paths_can_be_turned_into_edit_paths(frog):
    for text in ("stats.max_health", "behavior.states[3].transitions[0].condition.any[1].not",
                 "attack_patterns[0].events[1].hitbox", "collision.body.shape.size[0]", "monster_id"):
        assert format_path(parse_path(text)) == text
    path = parse_path("behavior.states[3].params.lift")
    assert frog.get(*path) == 340 and frog.replace(path, 300).get(*path) == 300
    node, value = frog.schema.field(frog.data, path)
    assert value == 340 and node.info()["unit"] == "px/s" and node.info()["maximum"] == 2000


# --------------------------------------------------------------------------------------------------- cloning
def test_a_clone_gets_its_own_id_and_is_never_bound_to_the_original_resources(beetle):
    copy_ = clone_document(beetle, "cave_beetle", "Cave Beetle")
    assert copy_.monster_id == "cave_beetle" and copy_.data["metadata"]["display_name"] == "Cave Beetle"
    assert copy_.data["source_binding"] is None and beetle.data["source_binding"] is not None
    assert copy_.data["loot"]["loot_table_id"] == "cave_beetle_loot"
    assert copy_.data["stats"] == beetle.data["stats"] and copy_.fingerprint != beetle.fingerprint
    with pytest.raises(DocumentError, match="of its own"):
        clone_document(beetle, "sewer_beetle")
    with pytest.raises(DocumentError):
        clone_document(beetle, "Bad Id")


# ------------------------------------------------------------------------------------------------ undo / redo
class History:
    """What an editor's undo stack is at core level: document snapshots and a cursor."""

    def __init__(self, document):
        self.items, self.cursor = [document], 0

    @property
    def current(self):
        return self.items[self.cursor]

    def edit(self, *edits):
        self.items[self.cursor + 1:] = [self.current.apply(*edits)]   # a new edit discards the redo branch
        self.cursor += 1

    def undo(self):
        self.cursor -= 1

    def redo(self):
        self.cursor += 1


def test_undo_and_redo_return_exactly_the_earlier_documents():
    history = History(new_document("moss_slug", "Moss Slug"))
    a = snapshot(history.current)
    history.edit(set_value(("stats", "max_health"), 30))
    b = snapshot(history.current)
    history.edit(set_value(("metadata", "tags"), ["cave"]))
    c = snapshot(history.current)
    history.undo()
    assert snapshot(history.current) == b
    history.undo()
    assert snapshot(history.current) == a
    history.redo()
    assert snapshot(history.current) == b
    history.edit(set_value(("stats", "move_speed"), 70))       # edit after undo: C is gone from the history
    assert len(history.items) == 3 and snapshot(history.items[1]) == b
    assert c not in [snapshot(item) for item in history.items]
    history.undo()
    history.undo()
    assert snapshot(history.current) == a


def test_two_branches_from_one_document_are_independent(beetle):
    left = beetle.replace(("stats", "max_health"), 10)
    right = beetle.replace(("stats", "max_health"), 90)
    left_again = left.replace(("metadata", "tags"), ["a"])
    assert (beetle.data["stats"]["max_health"], left.data["stats"]["max_health"],
            right.data["stats"]["max_health"]) == (24, 10, 90)
    assert right.data["metadata"]["tags"] == ["ground", "melee"] and left_again.data["metadata"]["tags"] == ["a"]


def test_hundreds_of_edits_leave_every_snapshot_intact(frog):
    history = History(frog)
    expected = [snapshot(frog)]
    for step in range(300):
        history.edit(set_value(("stats", "max_health"), 1 + step % 500),
                     set_value(("animations", "clips", step % 8, "fps"), 1 + step % 30))
        expected.append(snapshot(history.current))
    assert [snapshot(item) for item in history.items] == expected
    for _ in range(300):
        history.undo()
    assert history.current == frog and snapshot(history.current) == expected[0]


def test_a_report_belongs_to_one_revision_of_the_document(beetle):
    report = validate(beetle)
    assert report.fingerprint == beetle.fingerprint and report.matches(beetle)
    edited = beetle.replace(("stats", "max_health"), 25)
    assert not report.matches(edited) and validate(edited).matches(edited)
    assert report.matches(edited.replace(("stats", "max_health"), 24))      # same content, same fingerprint
    assert load("sewer_beetle").fingerprint == beetle.fingerprint


def test_snapshots_share_unchanged_parts_without_sharing_anything_mutable(frog):
    edited = frog.replace(("stats", "max_health"), 30)
    # Untouched sections are the very same frozen objects; the edited path is not.
    assert edited.data["animations"] is frog.data["animations"]
    assert edited.data["behavior"]["states"] is frog.data["behavior"]["states"]
    assert edited.data["stats"] is not frog.data["stats"] and edited.data is not frog.data
    assert edited.data["stats"]["planned"] is frog.data["stats"]["planned"]
    with pytest.raises(TypeError):
        edited.data["animations"]["clips"].append({})          # shared, and still impossible to change
    # Sharing never crosses a real difference, including 1 versus 1.0 versus True.
    same = frog.replace(("stats", "max_health"), 18)
    assert same == frog and same.data is frog.data
    deep = frog.replace(("behavior", "states", 3, "params", "lift"), 300)
    assert deep.data["behavior"]["states"][2] is frog.data["behavior"]["states"][2]
    assert deep.data["behavior"]["states"][3] is not frog.data["behavior"]["states"][3]
    assert frog.data["behavior"]["states"][3]["params"]["lift"] == 340


def test_the_schema_limit_rejects_what_it_cannot_hold():
    from rtcmonster import new_document as make
    data = make("big_one", "Big").to_dict()
    done = [{"to": "idle", "condition": {"type": "ActionCompleted"}}]
    data["behavior"]["states"] += [{"id": f"s{index}", "module": "Wait", "transitions": done}
                                   for index in range(61)]
    assert len(MonsterDocument(data).data["behavior"]["states"]) == 64      # the limit itself is accepted
    data["behavior"]["states"].append({"id": "one_too_many", "module": "Wait", "transitions": done})
    with pytest.raises(DocumentError, match="at most 64"):                  # the plan's 100 states are refused
        MonsterDocument(data)
    with pytest.raises(DocumentError, match="at most 64"):
        make("big_one", "Big").apply(*[insert_item(("behavior", "states"), {
            "id": f"s{index}", "module": "Wait", "transitions": done}) for index in range(62)])
