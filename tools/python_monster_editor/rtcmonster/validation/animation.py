"""Clips, roles, and how clip time relates to gameplay time. Clips are drawn, never obeyed."""

from ..modules import GAMEPLAY
from ..schema import LOOPING_ROLES, ONE_SHOT_ROLES, REQUIRED_ROLES
from ..timing import clip_seconds, frame_start_seconds
from .context import rule
from .report import ANIMATION, FAIL, WARNING, define

TIME_TOLERANCE = 1e-6

define(ANIMATION, FAIL, {
    "clip_without_frames": "A clip has no frames.",
    "source_rect_empty": "A frame's source rectangle has no area.",
    "source_rect_outside_image": "A frame's source rectangle does not fit inside its image.",
    "required_role_missing": "Clips exist but a role every enemy needs (idle, move, attack, hurt, death) is empty.",
    "held_role_must_loop": "A clip used for a held role (idle, move, jump, fall) does not loop.",
    "one_shot_role_must_not_loop": "A clip used only for one-shot roles loops.",
    "attack_hit_frame_out_of_range": "attack_hit_frame is beyond the attack clip's last frame.",
})
define(ANIMATION, WARNING, {
    "no_animation": "No clips: the actor is drawn with its placeholder polygon.",
    "mixed_frame_sizes": "Frames differ in size, but one visual_offset serves every clip.",
    "clip_longer_than_gameplay": "A one-shot clip lasts longer than the gameplay time it illustrates.",
    "hit_frame_mismatch": "The frame that shows the strike and the tick that deals it are more than half a tick apart.",
})


def _frame_size(context, frame):
    if frame["rect"] is not None:
        return tuple(frame["rect"][2:])
    image = context.index["image"].get(frame["image"])
    return (image["width"], image["height"]) if image else None


@rule
def clips(context):
    sizes = set()
    for index, clip in enumerate(context.data["animations"]["clips"]):
        path = f"animations.clips[{index}]"
        if not clip["frames"]:
            context.add("clip_without_frames", path, clip["id"], subject=clip["id"])
        for frame_index, frame in enumerate(clip["frames"]):
            frame_path = f"{path}.frames[{frame_index}]"
            image, rect = context.index["image"].get(frame["image"]), frame["rect"]
            if rect is not None:
                x, y, width, height = rect
                if width <= 0 or height <= 0:
                    context.add("source_rect_empty", f"{frame_path}.rect", rect, subject=clip["id"])
                elif image and (x + width > image["width"] or y + height > image["height"]):
                    context.add("source_rect_outside_image", f"{frame_path}.rect",
                                f"{list(rect)} does not fit {image['width']}x{image['height']}", subject=clip["id"])
            size = _frame_size(context, frame)
            if size:
                sizes.add(size)
    if len(sizes) > 1:
        context.add("mixed_frame_sizes", "animations.clips",
                    "One visual_offset serves every clip, so frames of different sizes will not line up: "
                    + ", ".join(f"{w}x{h}" for w, h in sorted(sizes)))


@rule
def roles(context):
    all_clips = context.index["animation"]
    roles_ = context.data["presentation"]["roles"]
    if not all_clips:
        context.add("no_animation", "animations.clips", "The actor will be drawn with its placeholder polygon.")
    else:
        for role in REQUIRED_ROLES:
            if not roles_[role]:
                context.add("required_role_missing", f"presentation.roles.{role}",
                            "EnemyAnimationProfile needs idle, move, attack, hurt and death.")
    for role, clip_id in roles_.items():
        clip = all_clips.get(clip_id)
        if clip is None:
            continue
        if role in LOOPING_ROLES and not clip["loop"]:
            context.add("held_role_must_loop", f"presentation.roles.{role}", clip_id, subject=clip_id)
        # A clip may serve a looping role and a one-shot role only if it loops for the former.
        elif role in ONE_SHOT_ROLES and clip["loop"] and not any(roles_[other] == clip_id for other in LOOPING_ROLES):
            context.add("one_shot_role_must_not_loop", f"presentation.roles.{role}", clip_id, subject=clip_id)
    attack = all_clips.get(roles_["attack"])
    hit_frame = context.data["presentation"]["attack_hit_frame"]
    if attack is not None and attack["frames"] and hit_frame >= len(attack["frames"]):
        context.add("attack_hit_frame_out_of_range", "presentation.attack_hit_frame",
                    f"{roles_['attack']} has {len(attack['frames'])} frames", subject=roles_["attack"])


def _longer(context, clip_id, limit, path, what):
    clip = context.index["animation"].get(clip_id)
    if clip is not None and clip["frames"] and clip["fps"] > 0 and not clip["loop"]             and clip_seconds(clip) > limit + TIME_TOLERANCE:
        context.add("clip_longer_than_gameplay", path,
                    f"{clip_id} lasts {clip_seconds(clip):.3f} s but {what} lasts {limit:.3f} s", subject=clip_id)


@rule
def clips_fit_gameplay(context):
    """A clip that disagrees with gameplay time is only a warning: gameplay never follows the clip."""
    roles_ = context.data["presentation"]["roles"]
    for index, state in enumerate(context.data["behavior"]["states"]):
        module = context.module(state)
        for role, parameter in (module.clip_budgets if module else ()):
            _longer(context, roles_[role], state["params"][parameter], f"behavior.states[{index}]",
                    f"{state['id']} ({module.id}.{parameter})")
    attack = context.index["animation"].get(roles_["attack"])
    hit_frame = context.data["presentation"]["attack_hit_frame"]
    half_tick = 0.5 / context.tick_rate
    for index, pattern in enumerate(context.data["attack_patterns"]):
        _longer(context, pattern["clip"], pattern["duration"], f"attack_patterns[{index}]", "the pattern")
        commits = sorted(event["time"] for event in pattern["events"]
                         if context.registry.events[event["type"]].side == GAMEPLAY)
        clip = context.index["animation"].get(pattern["clip"])
        if commits and clip is not None and clip is attack and clip["fps"] > 0                 and hit_frame < len(clip["frames"]):
            shown = frame_start_seconds(clip, hit_frame)
            if abs(shown - commits[0]) > half_tick + TIME_TOLERANCE:
                context.add("hit_frame_mismatch", "presentation.attack_hit_frame",
                            f"frame {hit_frame} starts at {shown:.3f} s but {pattern['id']} commits at "
                            f"{commits[0]:.3f} s", related=(f"attack_patterns[{index}]",), subject=pattern["id"])
