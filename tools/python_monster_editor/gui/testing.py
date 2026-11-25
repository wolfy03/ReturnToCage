"""Scripted answers for the questions the window asks. Used by tests and by the source smoke run.

Not a mock of the editor: the window, the widgets, the files and Godot are all real. Only the modal
dialogs, which would block an unattended run, are answered from a script. An unexpected question fails
loudly instead of being answered with a default.
"""

from collections import deque


class ScriptedPrompts:
    METHODS = ("unsaved_changes", "conflict", "confirm", "open_path", "save_path", "new_monster", "clone",
               "project_settings", "error", "info")

    def __init__(self):
        self.answers = {name: deque() for name in self.METHODS}
        self.calls = []

    def expect(self, method, answer=None):
        self.answers[method].append(answer)
        return self

    def _answer(self, method, *args):
        self.calls.append((method, args))
        if method in ("error", "info"):
            if self.answers[method]:
                self.answers[method].popleft()
            return None
        if not self.answers[method]:
            raise AssertionError(f"unexpected prompt: {method}{args}")
        answer = self.answers[method].popleft()
        return answer(*args) if callable(answer) else answer

    def asked(self, method):
        return [args for name, args in self.calls if name == method]

    def last_error(self):
        errors = self.asked("error")
        return errors[-1] if errors else None

    def __getattr__(self, name):
        if name in ScriptedPrompts.METHODS:
            return lambda *args: self._answer(name, *args)
        raise AttributeError(name)
