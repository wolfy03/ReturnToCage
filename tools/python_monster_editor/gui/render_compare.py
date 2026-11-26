"""The editor's preview and a Godot screenshot of the same frame, side by side and pixel by pixel.

``preview_image`` draws one frame with the very ``PreviewCanvas`` the animation workspace shows, at a
given size and zoom, with a transparent background and no guides - the same framing
``tools/monster_bridge/render_check.gd`` uses (actor origin in the middle, ``zoom`` pixels per unit).

``compare_images`` then reports, without judging:

* the bounding box of what each image drew (anything with alpha), so position and size can be compared;
* how many pixels are drawn in one image and not in the other;
* among the pixels both drew opaquely, how many differ by more than a small step per channel.

With a nearest filter and a whole-number zoom the two should agree exactly. A linear filter, a
fractional scale or anti-aliasing legitimately moves edge pixels; the thresholds for calling that a
failure belong to the caller, which knows the filter.
"""

from PySide6.QtCore import QPointF, QRect, QSize, Qt
from PySide6.QtGui import QColor, QImage, QPainter

from application import animation as logic

from .frame_cache import load_frame
from .preview_canvas import PreviewCanvas

CHANNEL_STEP = 8          # a channel may differ by this much before a pixel counts as different
BACKGROUND = "#1b202a"


def slots_as_shapes(document, clip_id, frame):
    """The shapes the workspace shows for a clip frame, as plain rows for the render check's overlay."""
    data = document.data
    return [{"kind": slot.kind, "id": slot.label, "shape": logic.shape_at(data, slot)}
            for slot in logic.shape_slots(data, clip_id, frame)]


def preview_image(project_root, document, clip_id, frame, facing, size, zoom, shapes=False):
    """``(QImage, state)``: the canvas's picture of one frame. ``state`` is ``load_frame``'s."""
    data = document.data
    clip = data["animations"]["clips"][logic.clip_index(data, clip_id)]
    path, rect = logic.frame_source(data, clip, frame)
    pixmap, state = load_frame(project_root, path, rect)
    canvas = PreviewCanvas()
    canvas.resize(QSize(*size))
    canvas.background = QColor(0, 0, 0, 0)
    canvas.guides = bool(shapes)
    canvas.set_zoom(zoom)
    canvas.set_facing(facing)
    rows = [(slot, logic.shape_at(data, slot)) for slot in logic.shape_slots(data, clip_id, frame)] if shapes else []
    canvas.show_frame(pixmap, logic.frame_size(data, clip, frame), data["presentation"], rows, False)
    image = canvas.render_image()
    canvas.deleteLater()
    return image, state


def _rgba(image):
    image = image.convertToFormat(QImage.Format.Format_RGBA8888)
    return image.width(), image.height(), bytes(image.constBits())[:image.width() * image.height() * 4]


def bounding_box(image):
    """``[left, top, right, bottom]`` (exclusive) of the pixels with any alpha, or None for an empty image."""
    width, height, data = _rgba(image)
    alpha = data[3::4]
    rows = [y for y in range(height) if any(alpha[y * width:(y + 1) * width])]
    if not rows:
        return None
    top, bottom = rows[0], rows[-1] + 1
    columns = [x for x in range(width) if any(alpha[top * width + x:bottom * width:width])]
    return [columns[0], top, columns[-1] + 1, bottom]


def compare_images(preview, rendered):
    """Numbers describing how two images of the same frame differ. No verdict."""
    if preview.size() != rendered.size():
        return {"same_size": False, "preview_size": [preview.width(), preview.height()],
                "rendered_size": [rendered.width(), rendered.height()]}
    width, height, first = _rgba(preview)
    _width, _height, second = _rgba(rendered)
    drawn_both = only_preview = only_rendered = differing = partial = 0
    largest = 0
    if first != second:
        for offset in range(0, len(first), 4):
            a, b = first[offset + 3], second[offset + 3]
            if not a and not b:
                continue
            if bool(a) != bool(b):
                only_preview += bool(a)
                only_rendered += bool(b)
                continue
            if a < 255 or b < 255:
                partial += 1                          # an edge pixel: coverage, not colour, is being compared
                continue
            drawn_both += 1
            delta = max(abs(first[offset + channel] - second[offset + channel]) for channel in range(3))
            largest = max(largest, delta)
            differing += delta > CHANNEL_STEP
    else:
        alpha = first[3::4]
        drawn_both = sum(1 for value in alpha if value == 255)
        partial = sum(1 for value in alpha if 0 < value < 255)
    return {"same_size": True, "identical": first == second,
            "preview_box": bounding_box(preview), "rendered_box": bounding_box(rendered),
            "opaque_in_both": drawn_both, "only_in_preview": only_preview, "only_in_rendered": only_rendered,
            "partly_transparent": partial, "colour_differs": differing, "largest_channel_delta": largest}


def side_by_side(images, labels, background=BACKGROUND, gap=8):
    """One evidence image: the given images in a row over the editor's background, each with a caption."""
    images = [image for image in images if image is not None]
    width = sum(image.width() for image in images) + gap * (len(images) + 1)
    height = max(image.height() for image in images) + gap * 2 + 18
    sheet = QImage(width, height, QImage.Format.Format_ARGB32)
    sheet.fill(QColor("#10131a"))
    painter = QPainter(sheet)
    x = gap
    for image, label in zip(images, labels):
        painter.fillRect(QRect(x, gap + 18, image.width(), image.height()), QColor(background))
        painter.drawImage(QPointF(x, gap + 18), image)
        painter.setPen(QColor("#d0d6e0"))
        painter.drawText(QRect(x, gap, image.width(), 16), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, label)
        x += image.width() + gap
    painter.end()
    return sheet
