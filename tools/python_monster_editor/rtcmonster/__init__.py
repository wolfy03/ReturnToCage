"""Core of the ReturnToCage Monster Editor: the `.rtcmonster` document, its files and its static validation.

Pure Python standard library. It imports neither Qt nor Godot, so the same
code serves the future GUI, command-line checks and CI.

Public API
----------
Everything listed in ``__all__`` is the supported surface for the GUI, the
command-line tools and tests. Names that start with an underscore, and modules
not re-exported here, are implementation detail and may change. In particular
nothing outside this package may touch ``MonsterDocument._data``.

    create      new_document, clone_document
    open/save   read_document, write_document, document_revision, DocumentConflict
    edit        MonsterDocument.replace / .apply with set_value, insert_item, remove_item, move_item, rename_id
    validate    validate, validate_payload, Report, Finding, CODES
    metadata    DEFAULT_SCHEMA (Schema.fields / .field / node.info()), DEFAULT_REGISTRY, capabilities
    catalog     monster_catalog, scan_content, published_monsters
    assets      inspect_image
    paths       parse_path, format_path
"""

from .catalog import IdCheck, find_drafts, monster_catalog, scan_content
from .document import MonsterDocument, clone_document, decode, encode, new_document
from .editing import Edit, insert_item, move_item, remove_item, rename_id, set_value
from .modules import DEFAULT_REGISTRY, Registry
from .project import inspect_image, published_monsters
from .schema import DEFAULT_SCHEMA, DOCUMENT_TYPE, SCHEMA_VERSION, SUFFIX, Schema, format_path, parse_path
from .spec import EDITOR_EDITABLE_SECTIONS, DocumentError, capabilities, field_capabilities
from .storage import DocumentConflict, document_revision, read_document, write_document
from .validation import (CODES, DOMAINS, FAIL, NOT_EVALUATED, PASS, STATIC_DOMAINS, WARNING, Finding, Report,
                         duplicate_monster_ids, validate, validate_payload)

__all__ = [
    "CODES", "DEFAULT_REGISTRY", "DEFAULT_SCHEMA", "DOCUMENT_TYPE", "DOMAINS", "EDITOR_EDITABLE_SECTIONS", "FAIL",
    "IdCheck", "NOT_EVALUATED", "PASS",
    "SCHEMA_VERSION", "STATIC_DOMAINS", "SUFFIX", "WARNING",
    "DocumentConflict", "DocumentError", "Edit", "Finding", "MonsterDocument", "Registry", "Report", "Schema",
    "capabilities", "clone_document", "decode", "document_revision", "duplicate_monster_ids", "encode",
    "field_capabilities", "find_drafts", "format_path", "insert_item", "inspect_image", "monster_catalog",
    "move_item", "new_document", "parse_path",
    "published_monsters", "read_document", "remove_item", "rename_id", "scan_content", "set_value", "validate",
    "validate_payload", "write_document",
]
