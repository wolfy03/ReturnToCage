"""Graphics adapters for immutable map objects."""

from pathlib import Path

from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import QColor, QImageReader, QPen, QPixmap
from PySide6.QtWidgets import QGraphicsItem, QGraphicsRectItem

from objects import MIN_SIZE, validate_texture
from terrain_atlas import BUILTIN_ROOT
from terrain_renderer import TerrainCache, draw_terrain


class TextureCache:
    def __init__(self):
        self.root = None
        self.images = {}
        self.terrain = TerrainCache()

    @property
    def terrain_root(self):
        return self.root or BUILTIN_ROOT

    def lookup(self, path):
        return self._load(path)[0]

    def natural_size(self, path):
        return self._load(path)[1]

    def _load(self, path):
        if not path or self.root is None:
            return QPixmap(), (64, 64)
        if path not in self.images:
            validate_texture(path)
            image, dimensions = QPixmap(), (64, 64)
            try:
                target = (self.root / Path(path)).resolve(strict=True)
                if target.is_relative_to(self.root) and target.is_file():
                    reader = QImageReader(str(target), b"PNG")
                    size = reader.size()
                    if size.isValid():
                        dimensions = (max(MIN_SIZE, size.width()), max(MIN_SIZE, size.height()))
                        if max(size.width(), size.height()) > 512:
                            reader.setScaledSize(size.scaled(QSize(512, 512), Qt.AspectRatioMode.KeepAspectRatio))
                        image = QPixmap.fromImage(reader.read())
            except (OSError, RuntimeError, ValueError):
                pass
            if len(self.images) >= 128:
                self.images.pop(next(iter(self.images)))
            self.images[path] = image, dimensions
        return self.images[path]


class ObjectItem(QGraphicsRectItem):
    def __init__(self, model, textures):
        super().__init__()
        self.textures = textures
        self.model = None
        self.setFlag(QGraphicsItem.GraphicsItemFlag.ItemUsesExtendedStyleOption)
        self.set_model(model)

    def set_model(self, model):
        if model == self.model:
            return
        self.model = model
        width, height = model.size
        self.setRect(-width / 2, -height / 2, width, height)
        self.setPos(*model.position)
        self.setRotation(model.rotation)
        self.update()

    def set_layer(self, layer, order):
        self.setVisible(layer.visible)
        self.setFlag(QGraphicsItem.GraphicsItemFlag.ItemIsSelectable, layer.visible and not layer.locked)
        self.setZValue(order)

    def handle_point(self, direction):
        return self.mapToScene(QPointF(direction[0] * self.rect().width() / 2,
                                      direction[1] * self.rect().height() / 2))

    def paint(self, painter, option, widget=None):
        rect = self.rect()
        model = self.model
        platform = model.type == "platform"
        image = self.textures.lookup(model.properties.texture_path)
        surface = model.properties.terrain
        if surface:
            tiles = self.textures.terrain.lookup(self.textures.terrain_root, surface)
            if tiles:
                draw_terrain(painter, rect, option.exposedRect, surface, tiles)
            else:
                painter.fillRect(rect, QColor("#552529"))
                painter.setPen(QPen(QColor("#ef9f9f"), 0))
                painter.drawLine(rect.topLeft(), rect.bottomRight())
                painter.drawLine(rect.topRight(), rect.bottomLeft())
        elif image.isNull():
            fill = "#41666b" if platform else "#564766"
            painter.fillRect(rect, QColor(fill))
            if not platform:
                painter.setPen(QPen(QColor("#b49ac7"), 0))
                painter.drawLine(rect.topLeft(), rect.bottomRight())
                painter.drawLine(rect.topRight(), rect.bottomLeft())
        else:
            painter.drawPixmap(rect, image, QRectF(image.rect()))
        painter.setPen(QPen(QColor("#d7fff4" if self.isSelected() else "#81baa9" if platform else "#ac8cbb"), 0))
        painter.drawRect(rect)
        if model.properties.one_way:
            painter.drawLine(rect.topLeft(), rect.topRight())

