"""Image assets: path, header and integrity. Godot import is a different level and is not claimed here."""

from collections import Counter
import re

from .. import png
from .context import rule
from .report import ASSETS, FAIL, IN_PROJECT, NOT_EVALUATED, NOWHERE, RUNTIME, WARNING, define

define(None, FAIL, {"invalid_hash": "A recorded SHA-256 is not 64 lowercase hex digits."})
define(ASSETS, FAIL, {
    "asset_missing": "The image file does not exist in the project.",
    "asset_size_mismatch": "The image's real size differs from the size recorded in the document.",
})
define(ASSETS, FAIL, {
    "asset_invalid": "The path is unsafe or the file is not a PNG the editor accepts (header level).",
    "asset_corrupt": "The PNG header is valid but the image data is damaged (integrity level).",
}, remedy=IN_PROJECT)
define(ASSETS, WARNING, {
    "asset_changed": "The image's content changed since it was registered.",
}, remedy=IN_PROJECT)
define(ASSETS, WARNING, {"duplicate_image_path": "Two image entries point at the same file."})
define(ASSETS, NOT_EVALUATED, {
    "asset_files_unchecked": "No project folder was given, so no image file was opened.",
}, remedy=NOWHERE)
define(RUNTIME, NOT_EVALUATED, {
    "asset_godot_import_not_run": "Whether Godot imports the images as textures was not checked (needs Godot).",
}, remedy=NOWHERE)


@rule
def images(context):
    rows = context.data["assets"]["images"]
    paths = Counter(row["path"] for row in rows)
    for index, row in enumerate(rows):
        path = f"assets.images[{index}]"
        if row["sha256"] and not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            context.add("invalid_hash", f"{path}.sha256", domain=ASSETS, subject=row["id"])
        if paths[row["path"]] > 1:
            context.add("duplicate_image_path", f"{path}.path", row["path"], subject=row["id"])
    thumbnail = context.data["metadata"]["thumbnail"]
    targets = [(f"assets.images[{index}]", row) for index, row in enumerate(rows)]
    if thumbnail:
        targets.append(("metadata.thumbnail",
                        {"id": "", "path": thumbnail, "width": None, "height": None, "sha256": ""}))
    if not targets:
        return
    context.add("asset_godot_import_not_run")
    if context.project is None:
        context.add("asset_files_unchecked", detail="No project folder was given.")
        return
    for path, row in targets:
        state, result = context.project.image(row["path"])
        related = (row["path"],)
        if state == "missing":
            context.add("asset_missing", path, row["path"], related=related, subject=row["id"])
        elif state == png.INTEGRITY:
            context.add("asset_corrupt", path, f"{row['path']}: {result}", related=related, subject=row["id"])
        elif state != "ok":
            context.add("asset_invalid", path, f"{row['path']}: {result}", related=related, subject=row["id"])
        else:
            width, height, digest = result
            if row["width"] is not None and (width, height) != (row["width"], row["height"]):
                context.add("asset_size_mismatch", path,
                            f"declared {row['width']}x{row['height']}, file is {width}x{height}",
                            related=related, subject=row["id"])
            if row["sha256"] and row["sha256"] != digest:
                context.add("asset_changed", path, "The image changed since it was registered.",
                            related=related, subject=row["id"])
