"""Findings, their stable codes, and the report a validation run returns.

A **code** is the machine-readable identity of a finding. Tools branch on
``finding.code`` (and ``status``, ``domain``, ``path``), never on the text in
``detail``, which is written for people and may be reworded or translated.
Every code is declared once with ``define``; emitting an undeclared code is a
programming error, and the table in docs/monster_editor_schema_v1.md is
generated from these declarations.
"""

from dataclasses import dataclass

PASS = "PASS"
WARNING = "WARNING"
FAIL = "FAIL"
NOT_EVALUATED = "NOT_EVALUATED"
STATUSES = (PASS, WARNING, FAIL, NOT_EVALUATED)

SCHEMA, REFERENCES, ASSETS, ANIMATION, COLLISION, ATTACK, AI = (
    "schema", "references", "assets", "animation", "collision", "attack", "ai")
COMPATIBILITY, RUNTIME, NETWORK, PUBLISH = "compatibility", "runtime", "network", "publish"
DOMAINS = (SCHEMA, REFERENCES, ASSETS, ANIMATION, COLLISION, ATTACK, AI, COMPATIBILITY, RUNTIME, NETWORK, PUBLISH)
# The domains a static check can decide. The other three need Godot or a publish step.
STATIC_DOMAINS = DOMAINS[:8]

# Where the cause of a finding can be fixed.
IN_DOCUMENT, IN_PROJECT, NOWHERE = "document", "project", "none"


@dataclass(frozen=True)
class CodeInfo:
    code: str
    domain: str | None       # None = decided by the field the finding points at
    status: str
    summary: str
    remedy: str


CODES = {}


def define(domain, status, codes, remedy=IN_DOCUMENT):
    """Declare finding codes. ``codes`` maps code -> one-line meaning."""
    for code, summary in codes.items():
        if code in CODES:
            raise ValueError(f"finding code defined twice: {code}")
        CODES[code] = CodeInfo(code, domain, status, summary, remedy)


def summarize(states):
    """Worst state wins: FAIL, then WARNING, then NOT_EVALUATED, then PASS. Nothing examined = NOT_EVALUATED."""
    states = set(states)
    return next((state for state in (FAIL, WARNING, NOT_EVALUATED) if state in states),
                PASS if states else NOT_EVALUATED)


@dataclass(frozen=True, slots=True)
class Finding:
    status: str
    domain: str
    code: str
    path: str = ""            # dotted field path inside the document ("" = the document as a whole)
    detail: str = ""          # human-readable; never parse it
    related: tuple = ()       # other document paths or project files involved
    subject: str = ""         # ID of the object concerned (state, clip, pattern, monster ...)

    @property
    def remedy(self):
        """``document`` (edit the field at ``path``), ``project`` (a project file must change) or ``none``."""
        return CODES[self.code].remedy

    @property
    def summary(self):
        return CODES[self.code].summary


@dataclass(frozen=True)
class Report:
    """The result of one run, tied to exactly what was examined.

    ``fingerprint`` is the document's fingerprint and ``inputs`` are the
    project files that were read with their hashes. A report describes those
    and nothing else: once the document or one of the files changes it is
    stale, and ``is_current`` says so.
    """
    findings: tuple
    fingerprint: str = ""
    tick_rate: int = 60
    project: str = ""                 # "" = validated without a project folder
    inputs: tuple = ()                # ((project-relative path, sha256 or ""), ...)
    scans: tuple = ()                 # ((content folder, scan fingerprint), ...)

    def status(self, domain):
        return summarize(item.status for item in self.findings if item.domain == domain)

    def summary(self):
        return {domain: self.status(domain) for domain in DOMAINS}

    @property
    def static_status(self):
        """Worst state among the domains this module can actually decide."""
        return summarize(self.status(domain) for domain in STATIC_DOMAINS)

    @property
    def overall(self):
        return summarize(self.status(domain) for domain in DOMAINS)

    @property
    def blocking(self):
        """Findings that forbid publishing: every FAIL. Warnings and NOT_EVALUATED never appear here."""
        return [item for item in self.findings if item.status == FAIL]

    @property
    def unverified(self):
        """Domains nobody has examined yet. Not a failure, and not a pass."""
        return [domain for domain in DOMAINS if self.status(domain) == NOT_EVALUATED]

    def select(self, status=None, domain=None, code=None):
        return [item for item in self.findings
                if (status is None or item.status == status) and (domain is None or item.domain == domain)
                and (code is None or item.code == code)]

    def codes(self, status=FAIL):
        return {item.code for item in self.findings if item.status == status}

    def matches(self, document):
        """True when this report was made for exactly this document content."""
        return bool(self.fingerprint) and document.fingerprint == self.fingerprint

    def stale_inputs(self):
        """Project files and content folders that changed since the run. Empty without a project."""
        if not self.project:
            return []
        from pathlib import Path
        from ..catalog import scan_content
        from ..project import file_sha256

        changed = []
        root = Path(self.project)
        for relative, digest in self.inputs:
            try:
                current = file_sha256(root / relative)
            except OSError:
                current = ""
            if current != digest:
                changed.append(relative)
        changed.extend(f"data/content/{folder}" for folder, fingerprint in self.scans
                       if scan_content(root, folder).fingerprint != fingerprint)
        return changed

    def is_current(self, document):
        """False as soon as the document or anything read from the project has changed."""
        return self.matches(document) and not self.stale_inputs()
