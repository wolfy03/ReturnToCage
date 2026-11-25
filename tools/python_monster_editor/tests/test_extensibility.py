"""GATE B: new modules, conditions, events and rules plug in without editing generic code.

Everything defined in this file is a test fixture. No game feature is added:
the "Burrow" module below exists only to prove the extension path.
"""

import ast
from pathlib import Path

import pytest

from conftest import EXAMPLE_IDS, PROJECT, edit, load
from rtcmonster import (CODES, DEFAULT_REGISTRY, DEFAULT_SCHEMA, DOMAINS, FAIL, MonsterDocument, Schema, capabilities,
                        decode, encode, new_document, parse_path, reference, validate)
from rtcmonster.modules import COMPLETED, FAILED, GAMEPLAY, PRESENTATION, Condition, Event, Module
from rtcmonster.spec import APPLIED, CAPABILITY_STAGES, CONTRACT, EDITOR, PLANNED, Bool, Choice, DocumentError, Id, Num
from rtcmonster.validation import STATUSES
from rtcmonster.validation.report import IN_DOCUMENT, IN_PROJECT, NOWHERE, define

PACKAGE = Path(__file__).resolve().parents[1] / "rtcmonster"


@pytest.fixture(scope="module", autouse=True)
def fixture_code():
    """The fixture module's own finding code exists only while this file's tests run."""
    define("ai", FAIL, {"burrow_needs_depth": "Test fixture: a Burrow that stays must go below the surface."})
    yield
    del CODES["burrow_needs_depth"]


def _burrow_check(context, state, path):
    if state["params"]["stay"] and state["params"]["depth"] < 8:
        context.add("burrow_needs_depth", f"{path}.params.depth", state["params"]["depth"], subject=state["id"])


BURROW = Module(
    "Burrow", "movement", "Dig in and wait under the surface.",
    {"depth": Num(16, 0, 200, "px", doc="How far below the floor."), "stay": Bool(False),
     "exit": Choice(("timer", "target_near"), "timer"), "seconds": Num(2, 0.1, 60, "s"),
     "ambush": Id("", empty=True, ref="pattern")},
    completes=True, can_fail=False, snapshot="IDLE", required_roles=("idle",), support=PLANNED,
    label="Burrow", since=2, clip_budgets=(("land", "seconds"),), checks=(_burrow_check,),
    completes_if=lambda params: params["exit"] == "timer")
SCENT = Condition("TargetScent", "Fixture: the target was smelled.", {"strength": Num(1, 0, 10)}, support=PLANNED)
TREMOR = Event("GroundTremor", GAMEPLAY, "Fixture: shake the ground.", {"radius": Num(40, 1, 500, "px")},
               support=PLANNED, damaging=True, instant_strike=True)
DUST = Event("DustPuff", PRESENTATION, "Fixture: dust.", {"size": Num(1, 0, 4)}, support=PLANNED)


@pytest.fixture(scope="module")
def schema():
    return Schema(DEFAULT_REGISTRY.extend(modules=[BURROW], conditions=[SCENT], events=[TREMOR, DUST]))


def burrower(schema, **params):
    data = new_document("mole", "Mole").to_dict()
    data["behavior"]["states"].insert(1, {
        "id": "burrow", "module": "Burrow", "params": params,
        "transitions": [{"to": "idle", "condition": {"type": "ActionCompleted"}},
                        {"to": "idle", "priority": 5, "condition": {"type": "TargetScent", "strength": 3}}]})
    data["behavior"]["states"][0]["transitions"] = [{"to": "burrow", "condition": {"type": "ActionCompleted"}}]
    data["attack_patterns"] = [{
        "id": "quake", "duration": 0.5,
        "phases": [{"kind": "windup", "start": 0, "end": 0.2}, {"kind": "recovery", "start": 0.2, "end": 0.5}],
        "events": [{"type": "GroundTremor", "time": 0.2}, {"type": "DustPuff", "time": 0.2}]}]
    return MonsterDocument(data, schema)


# ---------------------------------------------------------------------------- a new module, end to end
def test_a_registry_extension_does_not_touch_the_default_registry(schema):
    assert "Burrow" in schema.registry.modules and "Burrow" not in DEFAULT_REGISTRY.modules
    assert "TargetScent" not in DEFAULT_REGISTRY.conditions and "GroundTremor" not in DEFAULT_REGISTRY.events
    with pytest.raises(DocumentError, match="already registered"):
        DEFAULT_REGISTRY.extend(modules=[BURROW, BURROW])
    with pytest.raises(DocumentError, match="already registered"):
        DEFAULT_REGISTRY.extend(conditions=[DEFAULT_REGISTRY.conditions["Always"]])
    with pytest.raises(TypeError):
        DEFAULT_REGISTRY.modules["Burrow"] = BURROW


def test_normalization_applies_the_new_modules_defaults_and_types(schema):
    document = burrower(schema)
    state = document.data["behavior"]["states"][1]
    assert state["params"] == {"depth": 16, "stay": False, "exit": "timer", "seconds": 2, "ambush": ""}
    assert document.data["behavior"]["states"][1]["transitions"][1]["condition"] == {
        "type": "TargetScent", "strength": 3}
    assert document.data["attack_patterns"][0]["events"][0] == {"type": "GroundTremor", "time": 0.2, "radius": 40}
    for params, message in (({"depth": "deep"}, "number"), ({"tunnel": 1}, "unknown field"),
                            ({"exit": "never"}, "expected one of"), ({"stay": 1}, "true or false")):
        with pytest.raises(DocumentError, match=message):
            burrower(schema, **params)
    assert decode(encode(document), schema) == document
    with pytest.raises(DocumentError, match="unknown type"):          # the default schema does not know it
        decode(encode(document))


def test_generic_validation_covers_the_new_entries_without_knowing_them(schema):
    report = validate(burrower(schema))
    assert not report.select(FAIL)
    assert {(item.code, item.detail) for item in report.select("WARNING", "compatibility")} >= {
        ("planned_module", "Burrow"), ("planned_condition", "TargetScent"), ("planned_event", "GroundTremor"),
        ("planned_event", "DustPuff")}
    # ranges come from the parameter schema
    assert validate(burrower(schema, depth=500)).select(FAIL, "ai", "out_of_range")
    # references come from Id(ref=...)
    assert validate(burrower(schema, ambush="ghost")).select(FAIL, "references", "unknown_pattern")
    assert not validate(burrower(schema, ambush="quake")).select(FAIL)
    # event flags: an instant strike needs no active phase and counts as a hit
    assert not report.select(code="no_active_phase") and not report.select(code="pattern_without_hit")
    # completes_if: with exit=target_near the module never raises "completed"
    waiting = validate(burrower(schema, exit="target_near"))
    assert waiting.select("WARNING", "ai", "transition_never_fires") and not waiting.select(FAIL)
    assert BURROW.raises({"exit": "timer"}) == {COMPLETED} and BURROW.raises({"exit": "target_near"}) == set()
    assert BURROW.raises({"exit": "target_near"}, has_time_limit=True) == {FAILED}


def test_a_module_brings_its_own_rule(schema):
    report = validate(burrower(schema, stay=True, depth=2))
    finding, = report.select(FAIL, "ai", "burrow_needs_depth")
    assert finding.path == "behavior.states[1].params.depth" and finding.subject == "burrow"
    assert not validate(burrower(schema, stay=True, depth=20)).select(code="burrow_needs_depth")


def test_renaming_follows_references_declared_by_the_new_module(schema):
    from rtcmonster import rename_id
    renamed = burrower(schema, ambush="quake").apply(rename_id("pattern", "quake", "rumble"))
    assert renamed.data["behavior"]["states"][1]["params"]["ambush"] == "rumble"


def test_metadata_reference_and_capabilities_include_the_new_entries(schema):
    info = schema.module_params("Burrow")["depth"].info()
    assert (info["type"], info["default"], info["minimum"], info["maximum"], info["unit"]) == (
        "number", 16, 0, 200, "px")
    assert schema.module_params("Burrow")["ambush"].info()["reference"] == "pattern"
    assert schema.module_params("Burrow")["exit"].info()["choices"] == ("timer", "target_near")
    assert "| `Burrow` | movement |" in reference.modules(schema) and "`Burrow`" not in reference.modules()
    assert "| `TargetScent` |" in reference.conditions(schema) and "| `GroundTremor` | gameplay |" in reference.events(
        schema)
    assert BURROW.capabilities == capabilities(PLANNED) and BURROW.since == 2 and BURROW.label == "Burrow"
    assert not BURROW.capabilities["data_runtime"] and not BURROW.capabilities["legacy_equivalent"]


# ------------------------------------------------------------------------- generic code names no entry
@pytest.mark.parametrize("name", ["schema.py", "document.py", "editing.py", "reference.py", "validation/__init__.py",
                                  "validation/context.py", "validation/structure.py", "validation/assets.py",
                                  "validation/animation.py", "validation/combat.py", "validation/behavior.py",
                                  "validation/compatibility.py"])
def test_generic_code_never_names_a_module_event_condition_or_monster(name):
    registered = (set(DEFAULT_REGISTRY.modules) | set(DEFAULT_REGISTRY.events) | set(DEFAULT_REGISTRY.conditions)
                  | set(EXAMPLE_IDS) | {"frog", "beetle"})
    allowed = {"Always"}        # ConditionNode.default(): the neutral condition
    tree = ast.parse((PACKAGE / name).read_text(encoding="utf-8"))
    docstrings = {id(node.body[0].value) for node in ast.walk(tree)
                  if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef)) and node.body
                  and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant)}
    used = {node.value for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings}
    if name == "document.py":
        allowed |= {"Wait", "HurtReaction", "Death", "ActionCompleted"}   # new_document()'s minimal skeleton
    assert not (used & registered) - allowed, sorted((used & registered) - allowed)


# ---------------------------------------------------------------------------------- metadata contract
def test_every_field_exposes_the_metadata_an_inspector_needs():
    keys = {"type", "default", "required", "minimum", "maximum", "exclusive_minimum", "range", "unit", "choices",
            "reference", "description", "support", "deprecated", "hint", "editable"}
    seen = 0
    for name in EXAMPLE_IDS:
        document = load(name)
        for path, node, _value in document.schema.fields(document.data):
            info = node.info()
            assert set(info) == keys, path
            assert info["support"] in (APPLIED, CONTRACT, PLANNED, EDITOR) and isinstance(info["editable"], bool)
            seen += 1
    assert seen > 1500
    hints = {node.info()["hint"] for _path, node, _value in DEFAULT_SCHEMA.fields(load("frog").data)}
    assert hints == {"", "multiline", "image"}                        # UI-neutral words, never widget classes


def test_reference_metadata_drives_checks_and_is_complete(frog):
    from rtcmonster.schema import REFERENCE_SOURCES
    referenced = {node.ref for _path, node, _value in frog.schema.fields(frog.data) if getattr(node, "ref", "")}
    assert referenced == set(REFERENCE_SOURCES) == {"image", "animation", "hitbox", "pattern", "state"}
    for kind in REFERENCE_SOURCES:
        assert f"unknown_{kind}" in CODES


def test_support_levels_map_to_explicit_capability_stages():
    for support in (APPLIED, CONTRACT, PLANNED, EDITOR):
        stages = capabilities(support)
        assert tuple(stages) == CAPABILITY_STAGES and stages["contract_defined"] and stages["static_validation"]
        # Nothing is editable in a GUI, exportable or runnable from data yet, and nothing claims otherwise.
        assert not stages["editor_editable"] and not stages["godot_resource_export"]
        assert not stages["data_runtime"] and not stages["multiplayer_verified"]
    assert capabilities(APPLIED)["legacy_equivalent"] and not capabilities(PLANNED)["legacy_equivalent"]
    stages = capabilities(PLANNED)
    stages["data_runtime"] = True
    assert not capabilities(PLANNED)["data_runtime"]                   # callers get a copy


# ------------------------------------------------------------------------------ finding and code contract
def test_every_emitted_code_is_declared_once_with_a_fixed_meaning():
    emitted = set()
    for name in ("validation/__init__.py", "validation/structure.py", "validation/assets.py",
                 "validation/animation.py", "validation/combat.py", "validation/behavior.py",
                 "validation/compatibility.py", "modules.py"):
        tree = ast.parse((PACKAGE / name).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "add" and node.args \
                    and isinstance(node.args[0], ast.Constant):
                emitted.add(node.args[0].value)
    assert emitted and emitted <= set(CODES), sorted(emitted - set(CODES))
    for code, info in CODES.items():
        assert code == info.code and info.status in STATUSES and info.summary.endswith(".")
        assert info.domain in DOMAINS or info.domain is None
        assert info.remedy in (IN_DOCUMENT, IN_PROJECT, NOWHERE)
    with pytest.raises(ValueError, match="defined twice"):
        define("ai", FAIL, {"unknown_module": "again"})
    with pytest.raises(KeyError):
        validate(new_document("a", "A")).findings[0].__class__("FAIL", "ai", "not_a_code").remedy


def test_findings_carry_machine_readable_fields(frog, beetle):
    broken = edit(beetle, lambda d: d["behavior"]["states"][2]["transitions"][0].update(to="ghost"))
    finding, = validate(broken).select(FAIL, "references", "unknown_state")
    assert (finding.path, finding.subject, finding.remedy) == (
        "behavior.states[2].transitions[0].to", "ghost", IN_DOCUMENT)
    assert broken.get(*parse_path(finding.path)) == "ghost"
    cycle = edit(beetle, lambda d: (d["behavior"]["states"][0].update(transitions=[
        {"to": "patrol", "condition": {"type": "Always"}}]), d["behavior"]["states"][1].update(transitions=[
            {"to": "idle", "condition": {"type": "Always"}}])))
    finding, = validate(cycle).select(FAIL, "ai", "immediate_transition_cycle")
    assert set(finding.related) == {"idle", "patrol"}
    for item in validate(frog, PROJECT).findings:
        assert item.code in CODES and item.status == CODES[item.code].status
        assert item.domain == (CODES[item.code].domain or item.domain) and item.summary
        if item.path and item.remedy == IN_DOCUMENT and not item.path.startswith("source_binding"):
            frog.get(*parse_path(item.path))                           # the path resolves inside the document


def test_blocking_and_unverified_are_distinct_from_warnings(beetle, frog):
    clean = validate(beetle, PROJECT)
    assert clean.blocking == [] and clean.unverified == ["runtime", "network", "publish"]
    warned = validate(edit(beetle, lambda d: d["stats"]["planned"].update(defense=3)), PROJECT)
    assert warned.status("compatibility") == "WARNING" and warned.blocking == []
    failed = validate(edit(beetle, lambda d: d["stats"].update(max_health=-1)), PROJECT)
    assert {item.code for item in failed.blocking} == {"out_of_range", "publish_blocked_by_failures"}
    assert {item.code for item in validate(frog, PROJECT).blocking} == {"export_blocked_unsupported"}


def test_a_report_goes_stale_when_the_document_or_a_project_file_changes(tmp_path, beetle):
    import shutil
    project = tmp_path / "copy"
    for folder in ("data/content", "assets/characters/enemies", "gameplay/actors/enemies",
                   "gameplay/components", "presentation", "core/models/network", "data/definitions"):
        shutil.copytree(PROJECT / folder, project / folder)
    report = validate(beetle, project)
    assert report.is_current(beetle) and report.stale_inputs() == [] and report.project == str(project)
    assert dict(report.scans).keys() == {"enemies", "items"}
    assert "assets/characters/enemies/sewer_beetle/idle.png" in dict(report.inputs)
    assert not report.is_current(beetle.replace(("stats", "max_health"), 25))
    (project / "data/content/enemies/new_one.tres").write_text('[resource]\nid = &"new_one"\n', encoding="utf-8")
    assert report.stale_inputs() == ["data/content/enemies"] and not report.is_current(beetle)
    (project / "data/content/enemies/new_one.tres").unlink()
    assert report.is_current(beetle)
    scene = project / "gameplay/actors/enemies/sewer_beetle.tscn"
    scene.write_bytes(scene.read_bytes() + b"\n")
    assert report.stale_inputs() == ["gameplay/actors/enemies/sewer_beetle.tscn"]
    (project / "assets/characters/enemies/sewer_beetle/idle.png").unlink()
    assert "assets/characters/enemies/sewer_beetle/idle.png" in report.stale_inputs()
    assert validate(beetle).stale_inputs() == [] and validate(beetle).project == ""


def test_project_files_are_read_once_per_run(monkeypatch, frog):
    from rtcmonster.validation import context
    calls = {"scan": [], "image": []}
    real_scan, real_image = context.scan_content, context.inspect_image
    monkeypatch.setattr(context, "scan_content", lambda root, folder: (calls["scan"].append(folder),
                                                                     real_scan(root, folder))[1])
    monkeypatch.setattr(context, "inspect_image", lambda root, path: (calls["image"].append(path),
                                                                     real_image(root, path))[1])
    validate(frog, PROJECT)
    assert sorted(calls["scan"]) == ["enemies", "items"] and len(calls["image"]) == len(set(calls["image"])) == 8


def test_an_invalid_tick_rate_is_rejected_before_any_rule_runs(beetle):
    for rate in (0, -1, float("nan"), "60"):
        with pytest.raises(ValueError, match="tick rate"):
            validate(beetle, tick_rate=rate)
