"""Preview playback of one clip: which frame is on screen at which time. No Qt, no clock of its own.

The owner feeds elapsed real time with ``advance``; everything else is a query. Time arithmetic is
``rtcmonster.timing`` (seconds per frame = relative duration / fps, one-shot clips hold their last frame),
which is the rule the game's ``EnemyAnimationProfile`` uses.

States and what the buttons mean:

    STOPPED   time is 0, nothing advances
    PLAYING   ``advance`` moves the time
    PAUSED    time is kept, nothing advances

    play()    PAUSED -> continues where it was; STOPPED, or a one-shot clip that reached its end -> from 0
    pause()   PLAYING -> PAUSED
    stop()    -> STOPPED at 0
    seek(), seek_frame()   move the time without changing the state (a playing clip keeps playing)

A one-shot clip that reaches its end pauses itself on the last frame (``finished`` is True).

This is a *preview* clock. It never decides when an attack hits: attack timelines run on physics ticks
(``rtcmonster.timing.tick_of``) and are independent of any clip. An attack-timeline view can show both
by reading ``time`` / ``frame`` / ``frame_window`` here next to its own tick times.
"""

from rtcmonster.timing import clip_seconds, frame_at, frame_seconds, frame_start_seconds

STOPPED, PLAYING, PAUSED = "stopped", "playing", "paused"
# One advance never moves further than this: a debugger stop or a suspended laptop is not ten minutes of
# animation to catch up with.
MAX_STEP_SECONDS = 1.0


class Playback:
    def __init__(self, clip=None):
        self.state = STOPPED
        self.time = 0.0                 # seconds since the clip started; keeps growing over loops
        self._clip = None
        self.set_clip(clip)

    # ---- the clip
    def set_clip(self, clip, keep_time=False):
        """Show another clip (or the same clip after an edit). Stops at 0 unless ``keep_time``."""
        self._clip = clip if clip is not None and clip["frames"] and clip["fps"] > 0 else None
        if self._clip is None or not keep_time:
            self.state, self.time = STOPPED, 0.0
        elif not self.loop:
            self.time = min(self.time, self.duration)

    @property
    def clip(self):
        return self._clip

    @property
    def available(self):
        return self._clip is not None

    @property
    def duration(self):
        """Seconds of one pass through the clip."""
        return clip_seconds(self._clip) if self._clip is not None else 0.0

    @property
    def loop(self):
        return bool(self._clip is not None and self._clip["loop"])

    # ---- queries
    @property
    def position(self):
        """Seconds into the current pass (``time`` folded into one loop)."""
        duration = self.duration
        if duration <= 0:
            return 0.0
        return self.time % duration if self.loop else min(self.time, duration)

    @property
    def loop_count(self):
        """Completed passes of a looping clip."""
        duration = self.duration
        return int(self.time // duration) if self.loop and duration > 0 else 0

    @property
    def frame(self):
        return frame_at(self._clip, self.time) if self._clip is not None else 0

    @property
    def frame_window(self):
        """``(start, end)`` seconds of the current frame within one pass."""
        if self._clip is None:
            return (0.0, 0.0)
        index = self.frame
        start = frame_start_seconds(self._clip, index)
        return (start, start + frame_seconds(self._clip)[index])

    @property
    def finished(self):
        return self._clip is not None and not self.loop and self.time >= self.duration

    @property
    def playing(self):
        return self.state == PLAYING

    # ---- control
    def play(self):
        if self._clip is None:
            return False
        if self.state == STOPPED or self.finished:
            self.time = 0.0
        self.state = PLAYING
        return True

    def pause(self):
        if self.state == PLAYING:
            self.state = PAUSED

    def stop(self):
        self.state, self.time = STOPPED, 0.0

    def seek(self, seconds):
        if self._clip is None:
            return
        seconds = max(0.0, float(seconds))
        self.time = seconds if self.loop else min(seconds, self.duration)

    def seek_frame(self, index):
        """Jump to the start of a frame."""
        if self._clip is None:
            return
        index = max(0, min(int(index), len(self._clip["frames"]) - 1))
        self.time = frame_start_seconds(self._clip, index)

    def advance(self, seconds):
        """Let ``seconds`` of real time pass. Returns True when the frame on screen changed."""
        if self.state != PLAYING or self._clip is None or not seconds > 0:
            return False
        before = self.frame
        self.time += min(float(seconds), MAX_STEP_SECONDS)
        if not self.loop and self.time >= self.duration:
            self.time = self.duration
            self.state = PAUSED
        return self.frame != before
