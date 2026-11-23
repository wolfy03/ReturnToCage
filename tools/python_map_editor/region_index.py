"""Revision-bound offline ENTRY indexes for external map drafts."""

from dataclasses import dataclass, replace
from pathlib import Path

from document import read_document_snapshot
from objects import DocumentError

INDEXED = "indexed"
MODIFIED = "modified"
MISSING = "missing"
INVALID = "invalid"
NOT_INDEXED = "not_indexed"


@dataclass(frozen=True, slots=True)
class IndexedRegion:
    region_id: str
    path: Path
    sha256: str
    schema_version: int
    entries: tuple[str, ...] | None
    state: str = INDEXED

    @classmethod
    def read(cls, path):
        path = path.absolute()
        draft, revision, version = read_document_snapshot(path)
        entries = None if draft.design is None else tuple(
            point.point_id for point in draft.design.region_points if point.kind == "ENTRY")
        return cls(draft.region_id, path, revision, version, entries)

    def recheck(self):
        try:
            current = self.read(self.path)
        except FileNotFoundError:
            state = MISSING
        except (DocumentError, OSError, RuntimeError):
            state = INVALID
        else:
            state = INDEXED if (current.sha256, current.schema_version, current.region_id) == (
                self.sha256, self.schema_version, self.region_id) else MODIFIED
        return self if state == self.state else replace(self, state=state)

    @property
    def current_entries(self):
        return self.entries if self.state == INDEXED else None
