"""Bounded Qt atlas cache and one draw operation per visible slice."""

from PySide6.QtCore import QPointF, QRectF
from PySide6.QtGui import QImageReader, QPainter, QPixmap

from objects import DocumentError
from terrain_atlas import atlas_error, project_file, slice_boxes


class TerrainCache:
    def __init__(self):
        self.slices = {}

    def lookup(self, root, surface):
        if surface not in self.slices:
            tiles = ()
            if not atlas_error(root, surface):
                try:
                    reader = QImageReader(str(project_file(root, surface.texture_path)), b"PNG")
                    image = reader.read()
                    if not image.isNull() and (image.width(), image.height()) == surface.source_size:
                        tiles = tuple(QPixmap.fromImage(image.copy(*source))
                                      for source, _ in slice_boxes(surface, *surface.border_size))
                except (OSError, DocumentError):
                    pass
            if len(self.slices) >= 16:
                self.slices.pop(next(iter(self.slices)))
            self.slices[surface] = tiles
        return self.slices[surface]


def draw_terrain(painter, rect, exposed, surface, tiles):
    painter.save()
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
    for tile, (_, bounds) in zip(tiles, slice_boxes(surface, rect.width(), rect.height())):
        cell = QRectF(*bounds).translated(rect.topLeft())
        visible = cell.intersected(exposed)
        if not visible.isEmpty():
            origin = QPointF((visible.left() - cell.left()) % tile.width(),
                             (visible.top() - cell.top()) % tile.height())
            painter.drawTiledPixmap(visible, tile, origin)
    painter.restore()
