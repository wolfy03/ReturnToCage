"""Validation results and background jobs, with the rule that decides whether a result may still be shown.

Both problems are the same: something was computed for one state of the world, and by the time it is
shown the document or the project may have moved on.
"""

from dataclasses import dataclass, field
import itertools
import threading

from rtcmonster import validate
from rtcmonster.timing import DEFAULT_TICK_RATE

CURRENT, STALE, NONE = "current", "stale", "none"


class ValidationController:
    """Holds the latest report and says whether it still describes what the user is looking at."""

    def __init__(self):
        self.report = None
        self._project = None
        self._tick_rate = DEFAULT_TICK_RATE
        self._session_id = None

    def run(self, session, project_root=None, tick_rate=DEFAULT_TICK_RATE):
        """Validate the session's current document now and remember what it was validated against."""
        self.report = validate(session.document, None if project_root is None else str(project_root), tick_rate)
        self._project = None if project_root is None else str(project_root)
        self._tick_rate = tick_rate
        self._session_id = session.session_id
        return self.report

    def clear(self):
        self.report = None
        self._session_id = None

    def state(self, session, project_root=None, tick_rate=DEFAULT_TICK_RATE, check_files=False):
        """``current``, ``stale`` or ``none``.

        Cheap by default: document fingerprint, session, project and tick rate. ``check_files`` also
        re-hashes the project files the report read, which touches the disk.
        """
        report = self.report
        if report is None or session is None:
            return NONE
        project = None if project_root is None else str(project_root)
        if self._session_id != session.session_id or not report.matches(session.document) \
                or project != self._project or tick_rate != self._tick_rate:
            return STALE
        if check_files and report.stale_inputs():
            return STALE
        return CURRENT


@dataclass(frozen=True)
class Ticket:
    """What a background job was started for."""
    job_id: int
    kind: str
    project_generation: int
    session_id: int | None = None
    fingerprint: str = ""
    cancel: threading.Event = field(default_factory=threading.Event, compare=False)


class JobBoard:
    """Issues tickets and decides whether a finished job's result may still be applied."""

    def __init__(self):
        self._ids = itertools.count(1)
        self._active = {}

    def issue(self, kind, project_generation, session=None):
        ticket = Ticket(next(self._ids), kind, project_generation,
                        None if session is None else session.session_id,
                        "" if session is None else session.document.fingerprint)
        self._active[ticket.job_id] = ticket
        return ticket

    def cancel(self, ticket):
        ticket.cancel.set()

    def cancel_all(self):
        for ticket in self._active.values():
            ticket.cancel.set()

    @property
    def active(self):
        return list(self._active.values())

    def finish(self, ticket, project_generation, session=None, same_document=False):
        """Close the job and return True when its result is still valid.

        A result is discarded when the job was cancelled, when the project changed since it started, or -
        if ``same_document`` - when the document it was started for is no longer the open one or was edited.
        """
        known = self._active.pop(ticket.job_id, None) is not None
        if not known or ticket.cancel.is_set() or ticket.project_generation != project_generation:
            return False
        if same_document:
            # "No document open" is a state too: a job started with nothing open stays valid only while
            # nothing is open.
            current_id = None if session is None else session.session_id
            current_fingerprint = "" if session is None else session.document.fingerprint
            if current_id != ticket.session_id or current_fingerprint != ticket.fingerprint:
                return False
        return True
