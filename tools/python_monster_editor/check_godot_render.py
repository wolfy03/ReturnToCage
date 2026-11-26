"""Draw staged monsters with Godot's real renderer and compare with the editor's preview (MONSTER-STEP 3 stabilization).

    python tools/python_monster_editor/check_godot_render.py --godot <godot> --artifacts <dir>
        [--rendering-method forward_plus|mobile|gl_compatibility] [--allow-no-renderer]

For the Sewer Beetle, the Frog (each carried by its own actor) and a new draft built here with the editor's
own helpers (scaled 1.5x, bottom-centre aligned, carried by the beetle's actor):

1. stage the document in a project copy (``stage_presentation``), as the editor does;
2. run ``render_check.tscn`` there **with a window and a renderer**: the real ``EnemyAnimationPresenter``
   sprite is drawn for the first and a middle frame of every clip, facing right and left, into a
   320x240 viewport at 3 pixels per unit, and saved as PNG;
3. draw the same frames with the editor's ``PreviewCanvas`` at the same size and zoom;
4. compare: where the scene tree says the frame is against ``rtcmonster.geometry``; the bounding box
   and the pixels of the two images; the sprite's texture filter; which clip the presenter picks per
   state; and which frame ``AnimatedSprite2D`` shows after how long while really playing.

Evidence kept in ``--artifacts``: for every shot the preview, the Godot screenshot, a side-by-side sheet,
and both with the document's collision shapes drawn over them; ``render_report.json`` with every number.

The collision overlay is drawn from the *document* by this check. The game does not use the document's
hitboxes or per-frame hurtbox sets in MONSTER-STEP 3; the overlay shows where they would be, nothing more.

Without a renderer (a headless machine) the run fails, or with ``--allow-no-renderer`` reports
NOT_EVALUATED and exits 0. It never substitutes a headless check.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time

TOOL = Path(__file__).resolve().parent
PROJECT = TOOL.parents[1]
sys.path.insert(0, str(TOOL))

from bridge import client, rendering, staging  # noqa: E402
from bridge.client import BridgeError  # noqa: E402
from check_godot_stage import draft_from_art, manifest, manifest_difference  # noqa: E402
from rtcmonster import read_document  # noqa: E402

EXAMPLES = TOOL / "examples"
SIZE, ZOOM = (320, 240), 3
# Nearest sampling at a whole-number zoom must reproduce the preview exactly. With another filter or a
# fractional scale, edge pixels are blended by the renderer; then only position and coverage are held to
# a limit and the colour figures are recorded without a verdict.
EXACT_FILTERS = (1,)
BOX_TOLERANCE = 1               # pixels, for filtered or fractionally scaled sprites
COVERAGE_TOLERANCE = 0.06       # share of drawn pixels that may be present in only one image


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--godot", required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--rendering-method", default="", help="pass --rendering-method to Godot (default: the project's)")
    parser.add_argument("--allow-no-renderer", action="store_true",
                        help="report NOT_EVALUATED and exit 0 when the engine cannot render here")
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True)

    from PySide6.QtGui import QImage
    from PySide6.QtWidgets import QApplication
    from gui import render_compare
    app = QApplication.instance() or QApplication([])

    started = time.monotonic()
    before = manifest(PROJECT)
    work = Path(tempfile.mkdtemp(prefix="rtc-render-check-"))
    beetle = read_document(EXAMPLES / "sewer_beetle.rtcmonster")[0]
    frog = read_document(EXAMPLES / "frog.rtcmonster")[0]
    subjects = [("sewer_beetle", beetle, "sewer_beetle"), ("frog", frog, "frog"),
                ("new_draft", draft_from_art(beetle), "sewer_beetle")]
    report = {"size": list(SIZE), "zoom": ZOOM, "requested_rendering_method": args.rendering_method or "(project default)",
              "monsters": {}, "renderer": None}
    failures, unavailable = [], ""

    def check(name, passed, detail=""):
        print(f"{'PASS' if passed else 'FAIL':5} {name}" + (f" :: {detail}" if detail and not passed else ""), flush=True)
        if not passed:
            failures.append(name)
        return passed

    for name, document, carrier in subjects:
        folder = args.artifacts / name
        folder.mkdir(parents=True, exist_ok=True)
        result = None
        try:
            result = staging.stage_presentation(args.godot, PROJECT, document, work, carrier, keep=True)
            check(f"{name}: staged and read back equal to the document", result.passed, "; ".join(result.differences))
            shots = rendering.default_shots(
                document, lambda clip_id, frame, document=document: render_compare.slots_as_shapes(document, clip_id, frame))
            drawn = rendering.render_staged(args.godot, result.session, document, folder, shots, carrier=carrier,
                                            size=SIZE, zoom=ZOOM, rendering_method=args.rendering_method)
        except BridgeError as error:
            if error.code in (rendering.NO_RENDERER, client.PROCESS_CRASH, client.ENGINE_ERROR, client.INVALID_RESPONSE) \
                    and not report["monsters"] and args.allow_no_renderer:
                unavailable = f"{error.code}: {error.detail}"
                (folder / "engine.log").write_text(error.log or "", encoding="utf-8")
                break
            check(f"{name}: rendered", False, f"{error.code}: {error.detail}")
            (folder / "engine.log").write_text(error.log or "", encoding="utf-8")
            continue
        finally:
            if result is not None:
                result.session.remove()
        report["renderer"] = drawn.renderer
        check(f"{name}: drawn by a real renderer ({drawn.renderer.get('rendering_method')}, "
              f"{drawn.renderer.get('rendering_driver')})", drawn.renderer.get("display_server") != "headless")
        check(f"{name}: carried by the {carrier} actor", drawn.data.get("carrier") == carrier, str(drawn.data.get("carrier")))
        check(f"{name}: frame placement, texture filter, presenter roles and playback timing match the document",
              drawn.passed, "; ".join(drawn.differences[:6]))
        expected_filter = staging.texture_filter_of(document)[0]
        scale = document.data["presentation"]["visual_scale"]
        exact = expected_filter in EXACT_FILTERS and all(float(value * ZOOM).is_integer() for value in scale)
        rows, worst = [], {"box": 0, "coverage": 0.0, "colour": 0}
        for shot, wanted in zip(drawn.data["shots"], shots):
            preview, state = render_compare.preview_image(PROJECT, document, shot["clip"], shot["frame"], shot["facing"],
                                                          SIZE, ZOOM)
            godot_image = QImage(str(folder / shot["image"]))
            numbers = render_compare.compare_images(preview, godot_image)
            preview.save(str(folder / f"{shot['name']}_preview.png"))
            with_shapes, _state = render_compare.preview_image(PROJECT, document, shot["clip"], shot["frame"],
                                                               shot["facing"], SIZE, ZOOM, shapes=True)
            with_shapes.save(str(folder / f"{shot['name']}_preview_overlay.png"))
            overlay = QImage(str(folder / shot["overlay_image"])) if shot.get("overlay_image") else None
            render_compare.side_by_side(
                [preview, godot_image, with_shapes, overlay],
                ["editor preview", "Godot renderer", "preview + document shapes", "Godot + document shapes"]).save(
                str(folder / f"{shot['name']}_compare.png"))
            drawn_pixels = max(1, numbers.get("opaque_in_both", 0) + numbers.get("only_in_preview", 0)
                               + numbers.get("only_in_rendered", 0) + numbers.get("partly_transparent", 0))
            box_a, box_b = numbers.get("preview_box"), numbers.get("rendered_box")
            box_delta = max((abs(a - b) for a, b in zip(box_a, box_b)), default=999) if box_a and box_b else 999
            coverage = (numbers.get("only_in_preview", 0) + numbers.get("only_in_rendered", 0)) / drawn_pixels
            worst = {"box": max(worst["box"], box_delta), "coverage": max(worst["coverage"], coverage),
                     "colour": max(worst["colour"], numbers.get("colour_differs", 0))}
            rows.append({"name": shot["name"], "clip": shot["clip"], "frame": shot["frame"], "facing": shot["facing"],
                         "preview_state": state, "corners": shot["corners"],
                         "expected_corners": rendering.expected_corners(document, shot["clip"], shot["frame"],
                                                                        shot["facing"], SIZE, ZOOM),
                         "flip": shot.get("presenter_scale"), "pixels": numbers, "shapes": len(wanted.get("shapes", []))})
        identical = sum(1 for row in rows if row["pixels"].get("identical"))
        if exact:
            check(f"{name}: all {len(rows)} screenshots equal the editor preview pixel for pixel",
                  identical == len(rows), f"{identical} of {len(rows)} identical; worst {worst}")
        else:
            check(f"{name}: all {len(rows)} screenshots have the preview's position and coverage "
                  f"(filtered or fractionally scaled: colours are recorded, not judged)",
                  worst["box"] <= BOX_TOLERANCE and worst["coverage"] <= COVERAGE_TOLERANCE, str(worst))
        facings = {row["facing"] for row in rows}
        mirrored = all((row["flip"][0] < 0) == ((row["facing"] < 0) != (not document.data["presentation"]["faces_right_by_default"]))
                       for row in rows)
        check(f"{name}: both facings were drawn and the sprite is mirrored exactly when it should be",
              facings == {1, -1} and mirrored)
        report["monsters"][name] = {
            "carrier": carrier, "texture_filter": drawn.data.get("texture_filter"), "expected_texture_filter": expected_filter,
            "visual_scale": list(scale), "visual_offset": list(document.data["presentation"]["visual_offset"]),
            "pixel_exact_expected": exact, "identical_screenshots": identical, "screenshots": len(rows), "worst": worst,
            "role_selection": drawn.data.get("role_selection"), "roles_not_forced": list(drawn.notes),
            "timings": [{"clip": row["clip"], "samples": len(row.get("samples", [])), "loop": row.get("loop"),
                         "largest_delta": row.get("largest_delta")} for row in drawn.data.get("timings", [])],
            "differences": list(drawn.differences), "shots": rows, "seconds": round(drawn.seconds, 2),
            "process": {"stage": result.process, "render_crash_exit_codes": list(drawn.crashes)}}

    left = [path.name for path in work.iterdir() if path.name.startswith(staging.STAGING_PREFIX)]
    check("no staging copy is left behind", not left and not staging.leftovers(), str(left))
    changed = manifest_difference(before, manifest(PROJECT))
    check("the real project is byte-for-byte unchanged", not changed, str(changed[:10]))
    shutil.rmtree(work, ignore_errors=True)
    app.processEvents()

    status = "NOT_EVALUATED" if unavailable else ("FAIL" if failures else "PASS")
    report.update(status=status, failures=failures, unavailable=unavailable, seconds=round(time.monotonic() - started, 1),
                  platform=sys.platform, qt_platform=app.platformName(), ci=bool(os.environ.get("CI")),
                  not_checked=["the document's hitboxes and per-frame hurtbox sets are drawn as an overlay only; no "
                               "runtime uses them in MONSTER-STEP 3", "jump_start and land clips (presenter timers)",
                               "combat, network and publishing"])
    (args.artifacts / "render_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                       encoding="utf-8")
    if unavailable:
        print(f"MONSTER RENDER CHECK NOT_EVALUATED: no renderer here ({unavailable})")
        return 0
    print(f"MONSTER RENDER CHECK {status} ({len(report['monsters'])} monsters; {len(failures)} failed checks; "
          f"{report['seconds']} s)")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
