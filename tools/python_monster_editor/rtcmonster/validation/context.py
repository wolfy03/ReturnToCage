"""What every rule receives: the document, shared indexes and a recording view of the project.

Rules never read files themselves. They ask the ``ProjectView``, which reads
each file or folder once per run and remembers what it read, so the report can
later tell whether its inputs are still the ones on disk.
"""

from functools import cached_property

from .. import png
from ..catalog import scan_content
from ..project import MISSING, MODIFIED, UNCHANGED, SOURCE_SUFFIXES, file_sha256, inspect_image, \
    resolve_project_file
from ..schema import MAX_IMAGE_BYTES, REFERENCE_SOURCES
from ..spec import DocumentError
from .report import CODES, Finding

RULES = []


def rule(function):
    """Register a validation rule: a callable taking the Context. Rules run in registration order."""
    RULES.append(function)
    return function


class ProjectView:
    def __init__(self, root):
        self.root = root
        self.inputs = {}       # relative path -> sha256 ("" = missing or unreadable)
        self._scans = {}
        self._images = {}

    def content(self, folder):
        if folder not in self._scans:
            self._scans[folder] = scan_content(self.root, folder)
        return self._scans[folder]

    @property
    def scans(self):
        return tuple((folder, scan.fingerprint) for folder, scan in sorted(self._scans.items()))

    def image(self, relative):
        """``("ok", (width, height, sha256))`` or ``(problem, message)`` with problem in
        missing / unsafe / header / integrity."""
        if relative not in self._images:
            try:
                result = ("ok", inspect_image(self.root, relative))
                self.inputs[relative] = result[1][2]
            except FileNotFoundError:
                result = ("missing", relative)
                self.inputs[relative] = ""
            except png.PngError as error:
                result = (error.level, str(error))
                self._record(relative)
            except (OSError, DocumentError) as error:
                result = ("unsafe", str(error))
            self._images[relative] = result
        return self._images[relative]

    def _record(self, relative):
        try:
            self.inputs[relative] = file_sha256(
                resolve_project_file(self.root, relative, SOURCE_SUFFIXES, MAX_IMAGE_BYTES))
        except (OSError, DocumentError):
            self.inputs[relative] = ""

    def source_state(self, relative, expected):
        self._record(relative)
        current = self.inputs[relative]
        return MISSING if not current else (UNCHANGED if current == expected else MODIFIED)


class Context:
    def __init__(self, document, project, tick_rate):
        self.document = document
        self.data = document.data
        self.schema = document.schema
        self.registry = document.schema.registry
        self.project = None if project is None else ProjectView(project)
        self.tick_rate = tick_rate
        self.findings = []

    @cached_property
    def index(self):
        """``{reference kind: {id: row}}`` for everything identifiers can point at. Built once per run."""
        result = {}
        for kind, path in REFERENCE_SOURCES.items():
            rows = self.data
            for key in path:
                rows = rows[key]
            table = {}
            for row in rows:
                table.setdefault(row["id"], row)
            result[kind] = table
        return result

    @cached_property
    def states(self):
        return self.index["state"]

    def module(self, state):
        return self.registry.modules.get(state["module"])

    def add(self, code, path="", detail="", *, domain=None, status=None, related=(), subject=""):
        info = CODES[code]
        if (info.domain is None) == (domain is None):
            raise ValueError(f"{code}: the domain is "
                             + ("decided per finding and must be given" if info.domain is None else "fixed"))
        self.findings.append(Finding(status or info.status, domain or info.domain, code, path, str(detail),
                                     tuple(related), subject))

    def has_failures(self, domains):
        return any(item.status == "FAIL" and item.domain in domains for item in self.findings)
