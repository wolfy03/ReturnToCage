"""Static validation of a monster document.

Structure
---------
``report``         statuses, domains, stable finding codes, Finding, Report
``context``        the Context every rule receives, the recording ProjectView, the rule registry
``structure``      schema ranges and reference integrity (derived from the schema)
``assets``         image path, header and integrity levels
``animation``      clips, roles, clip time against gameplay time
``combat``         collision shapes and attack timelines
``behavior``       the state graph
``compatibility``  planned features and source files

A rule is a function taking the Context, registered with ``@rule``. Adding a
domain check means adding a function; ``validate`` does not change. Module- and
event-specific knowledge is not in the rules at all: it is declared on the
registry entries the rules read.

Every finding belongs to one domain and has one of four states. A domain that
was not examined stays NOT_EVALUATED: this package never runs Godot, so
``runtime`` and ``network`` can never be PASS here, and ``publish`` can only
fail or stay unevaluated.
"""

from collections import Counter

from ..document import decode
from ..spec import DocumentError
from ..timing import DEFAULT_TICK_RATE, check_tick_rate
from . import animation, assets, behavior, combat, compatibility, structure
from .context import RULES, Context, rule
from .report import (AI, ANIMATION, ASSETS, ATTACK, CODES, COLLISION, COMPATIBILITY, DOMAINS, FAIL, NETWORK,
                     NOT_EVALUATED, NOWHERE, PASS, PUBLISH, REFERENCES, RUNTIME, SCHEMA, STATIC_DOMAINS, STATUSES,
                     WARNING, CodeInfo, Finding, Report, define, summarize)

define(SCHEMA, PASS, {"structure_valid": "Every value is inside its range."}, remedy=NOWHERE)
define(REFERENCES, PASS, {"references_resolved": "Every reference points at something that exists."},
       remedy=NOWHERE)
define(ASSETS, PASS, {"assets_verified": "Every image passed the path, header and integrity checks."},
       remedy=NOWHERE)
define(ANIMATION, PASS, {"animation_consistent": "Clips and roles are consistent."}, remedy=NOWHERE)
define(COLLISION, PASS, {"collision_valid": "Collision shapes are valid."}, remedy=NOWHERE)
define(ATTACK, PASS, {"attack_timelines_valid": "Attack timelines are consistent."}, remedy=NOWHERE)
define(AI, PASS, {"behavior_graph_valid": "The state graph is consistent."}, remedy=NOWHERE)
define(COMPATIBILITY, PASS, {"no_static_incompatibility": "Nothing planned-only is used and sources are unchanged."},
       remedy=NOWHERE)
define(RUNTIME, NOT_EVALUATED, {"godot_runtime_not_run": "No Godot process ran this document."}, remedy=NOWHERE)
define(NETWORK, NOT_EVALUATED, {"network_replication_not_run": "Replication was not exercised."}, remedy=NOWHERE)
define(PUBLISH, NOT_EVALUATED, {"publish_not_implemented": "Publishing to game content does not exist yet."},
       remedy=NOWHERE)
define(PUBLISH, FAIL, {
    "export_blocked_unsupported": "The source binding lists behaviour this schema cannot express.",
    "publish_blocked_by_failures": "A static domain has a failure.",
})
define(None, NOT_EVALUATED, {"document_unreadable": "Not examined because the document could not be read."},
       remedy=NOWHERE)

# Importing a rule module registers its rules; the tuple fixes the order they run in.
RULE_MODULES = (structure, assets, animation, combat, behavior, compatibility)

_PASS_CODES = ((SCHEMA, "structure_valid"), (REFERENCES, "references_resolved"), (ASSETS, "assets_verified"),
               (ANIMATION, "animation_consistent"), (COLLISION, "collision_valid"),
               (ATTACK, "attack_timelines_valid"), (AI, "behavior_graph_valid"),
               (COMPATIBILITY, "no_static_incompatibility"))


def validate(document, project=None, tick_rate=DEFAULT_TICK_RATE):
    """Run every static rule. ``project`` enables the checks that read project files.

    The returned report is bound to ``document.fingerprint`` and to the files
    that were read; see ``Report.is_current``.
    """
    check_tick_rate(tick_rate)
    context = Context(document, project, tick_rate)
    for check in RULES:
        check(context)
    for domain, code in _PASS_CODES:
        if not any(item.domain == domain for item in context.findings):
            context.add(code)
    context.add("godot_runtime_not_run",
                detail="No Godot process ran. A data-driven runtime does not exist in MONSTER-STEP 1.")
    context.add("network_replication_not_run")
    binding = context.data["source_binding"]
    for index, row in enumerate((binding or {}).get("unsupported", ())):
        context.add("export_blocked_unsupported", f"source_binding.unsupported[{index}]",
                    f"{row['path']}: {row['reason']}")
    if context.has_failures(STATIC_DOMAINS):
        context.add("publish_blocked_by_failures")
    context.add("publish_not_implemented", detail="Publishing to Godot content is outside MONSTER-STEP 1.")
    view = context.project
    return Report(tuple(context.findings), document.fingerprint, tick_rate,
                  "" if view is None else str(view.root),
                  () if view is None else tuple(sorted(view.inputs.items())),
                  () if view is None else view.scans)


def validate_payload(payload, **options):
    """Validate raw bytes. An unreadable file is a schema failure, not an exception."""
    try:
        document = decode(payload)
    except DocumentError as error:
        return Report((Finding(FAIL, SCHEMA, "unreadable_document", "", str(error)),)
                      + tuple(Finding(NOT_EVALUATED, domain, "document_unreadable") for domain in DOMAINS[1:]))
    return validate(document, **options)


def duplicate_monster_ids(documents):
    """Findings for monster IDs shared by several ``(label, document)`` pairs of one catalog."""
    counts = Counter(document.monster_id for _, document in documents)
    return [Finding(FAIL, REFERENCES, "duplicate_monster_id", label, document.monster_id,
                    subject=document.monster_id)
            for label, document in documents if counts[document.monster_id] > 1]


__all__ = ["CODES", "DOMAINS", "FAIL", "NOT_EVALUATED", "PASS", "STATIC_DOMAINS", "STATUSES", "WARNING",
           "CodeInfo", "Context", "Finding", "Report", "define", "duplicate_monster_ids", "rule", "summarize",
           "validate", "validate_payload"]
