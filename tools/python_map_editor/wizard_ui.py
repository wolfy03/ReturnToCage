"""Region creation UI. It only builds a MapDocument."""

from PySide6.QtGui import QUndoCommand
from PySide6.QtWidgets import QComboBox, QDialog, QDialogButtonBox, QFormLayout, QLabel, QLineEdit, QSpinBox

from document import MAX_EXTENT, MIN_EXTENT, MapDocument
from objects import DocumentError
from region_design import SPAWN_SLOTS, RegionEnvironment
from region_wizard import TEMPLATES, create_region
from strings import tr


class RegionWizard(QDialog):
    def __init__(self, parent, known_ids):
        super().__init__(parent)
        self.known_ids = known_ids
        self.document = None
        self.setWindowTitle(tr("region_wizard"))
        form = QFormLayout(self)
        self.region_id = QLineEdit("new_region")
        self.region_id.setMaxLength(64)
        self.name = QLineEdit(tr("default_name"))
        self.name.setMaxLength(120)
        self.width = QSpinBox()
        self.height = QSpinBox()
        for spin, value in ((self.width, 1200), (self.height, 600)):
            spin.setRange(MIN_EXTENT, MAX_EXTENT)
            spin.setValue(value)
        self.template = QComboBox()
        for key in TEMPLATES:
            self.template.addItem(tr(f"template_{key}"), key)
        self.environment = QLineEdit()
        self.slots = QSpinBox()
        self.slots.setRange(1, SPAWN_SLOTS)
        self.slots.setValue(SPAWN_SLOTS)
        for key, widget in (("region_id", self.region_id), ("display_name", self.name), ("width", self.width),
                            ("height", self.height), ("template", self.template),
                            ("environment_path", self.environment), ("spawn_count", self.slots)):
            form.addRow(tr(key), widget)
        self.error = QLabel()
        self.error.setWordWrap(True)
        form.addRow(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

    def accept(self):
        try:
            self.document = create_region(self.region_id.text(), self.name.text(), self.width.value(),
                                          self.height.value(), self.template.currentData(), self.slots.value(),
                                          RegionEnvironment(self.environment.text().strip()), self.known_ids)
        except DocumentError as error:
            self.error.setText(str(error))
            return
        super().accept()


class WizardEdit(QUndoCommand):
    def __init__(self, window, document):
        super().__init__(tr("region_wizard"))
        self.window = window
        self.before = MapDocument(display_name=tr("default_name"))
        self.after = document

    def apply(self, document):
        self.window.draft = document
        self.window._apply_metadata((document.region_id, document.display_name, document.width, document.height))
        self.window._sync_objects()
        self.window._sync_region_design()
        self.window._refresh_godot_actions()
        self.window.view.fit_map()

    def redo(self):
        self.apply(self.after)

    def undo(self):
        self.apply(self.before)
