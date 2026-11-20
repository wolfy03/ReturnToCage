"""Source and frozen entry point for the Windows map editor."""

import argparse
import logging
from pathlib import Path
import sys

from PySide6.QtCore import QRectF, QSettings, QStandardPaths, QTimer
from PySide6.QtGui import QColor, QIcon, QPainter, QPalette, QPixmap
from PySide6.QtWidgets import QApplication

from document import DocumentError
from window import APP_NAME, MainWindow


def configure_appearance(app):
    app.setStyle("Fusion")
    palette = QPalette()
    roles = QPalette.ColorRole
    for role, value in (
        (roles.Window, "#252c38"), (roles.Base, "#1b202a"), (roles.AlternateBase, "#292f3b"),
        (roles.WindowText, "#e7edf5"), (roles.Text, "#e7edf5"), (roles.Button, "#303a49"),
        (roles.ButtonText, "#e7edf5"), (roles.Highlight, "#457969"),
        (roles.HighlightedText, "#ffffff"), (roles.PlaceholderText, "#b2bed0"),
        (roles.ToolTipBase, "#303a49"), (roles.ToolTipText, "#e7edf5"),
    ):
        palette.setColor(role, QColor(value))
    app.setPalette(palette)
    icon = QPixmap(64, 64)
    icon.fill(QColor("#212834"))
    with QPainter(icon) as painter:
        painter.fillRect(QRectF(12, 34, 40, 14), QColor("#74cdb8"))
        painter.fillRect(QRectF(28, 16, 24, 11), QColor("#aacad9"))
        painter.fillRect(QRectF(12, 16, 9, 11), QColor("#5f7490"))
    app.setWindowIcon(QIcon(icon))


def main():
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("document", nargs="?", type=Path)
    parser.add_argument("--smoke-report", type=Path, help="Run the windowed deployment smoke check.")
    args = parser.parse_args()
    app = QApplication([sys.argv[0]])
    app.setOrganizationName("ReturnToCage")
    app.setApplicationName(APP_NAME)
    configure_appearance(app)
    if args.smoke_report:
        from smoke import schedule_smoke

        return schedule_smoke(app, args.smoke_report.resolve())
    log_directory = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppLocalDataLocation))
    log_directory.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=log_directory / "editor.log", encoding="utf-8",
                        format="%(asctime)s %(levelname)s %(message)s", level=logging.WARNING)
    window = MainWindow(QSettings())
    window.show()
    if args.document:
        def open_initial_document():
            try:
                window.open_document(args.document.resolve())
            except (OSError, DocumentError) as error:
                logging.warning("Could not open draft: %s", error)
                window._report_error(error)

        QTimer.singleShot(0, open_initial_document)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
