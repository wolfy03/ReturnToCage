"""Core of the ReturnToCage Monster Editor: the `.rtcmonster` document, its files and its static validation.

Pure Python standard library. It imports neither Qt nor Godot, so the same
code serves the future GUI, command-line checks and CI.
"""

from .document import MonsterDocument, decode, encode, new_document
from .schema import DOCUMENT_TYPE, SCHEMA_VERSION, SUFFIX
from .spec import DocumentError
from .storage import DocumentConflict, document_revision, read_document, write_document
from .validation import (DOMAINS, FAIL, NOT_EVALUATED, PASS, WARNING, Finding, Report, duplicate_monster_ids,
                         validate, validate_payload)

__all__ = [
    "DOCUMENT_TYPE", "DOMAINS", "FAIL", "NOT_EVALUATED", "PASS", "SCHEMA_VERSION", "SUFFIX", "WARNING",
    "DocumentConflict", "DocumentError", "Finding", "MonsterDocument", "Report", "decode", "document_revision",
    "duplicate_monster_ids", "encode", "new_document", "read_document", "validate", "validate_payload",
    "write_document",
]
