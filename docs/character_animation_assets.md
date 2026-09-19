# Character animation asset contract

Gameplay simulation and presentation are separate. `CharacterAnimationProfile` maps semantic names
to a `SpriteFrames` resource; gameplay code never references textures, files, frame callbacks, or
animation lengths. Replacing the placeholder with production art should require changes only to the
profile and visual assets.

## Required semantic clips

Player profiles with SpriteFrames provide:

```text
idle
run
jump
fall
climb
climb_idle
dodge
hurt
death
attack_1
attack_2
attack_3
```

Actual animation names may differ when the profile maps them. `AttackDefinition.presentation_key`
selects an `AttackAnimationBinding`; it is not a file or texture reference.

## Art production rules

- Transparent background; do not bake a ground shadow into frames.
- Use one stable canvas/frame size within a sheet.
- Keep the pivot and feet position stable so animation does not visibly jitter.
- Keep character scale consistent between clips. Visual scaling belongs to the presentation scene,
  never collision, hitbox, hurtbox, or interaction geometry.
- Record the profile's canonical art direction with `faces_right_by_default`. Right- and left-facing
  source art are both supported; when climb ignores live facing it uses that canonical direction.
  Only the visual child is horizontally flipped; never flip or negatively scale the `PlayerActor` root.
- Keep source rectangles and `AnimatedSprite2D` position stable. Per-frame offset correction is not
  part of the current pipeline.

## Attack phase partitions

Each `AttackAnimationBinding` splits one clip into half-open ranges:

```text
[0, startup_end_frame)                   STARTUP
[startup_end_frame, active_end_frame)    ACTIVE
[active_end_frame, frame_count)          RECOVERY
```

Every range must contain at least one frame. `PlayerAnimationPresenter` maps authoritative gameplay
phase progress into these ranges. Animation FPS and `animation_finished` never commit damage, open a
hitbox, spend stamina, or finish an action.

## Placeholder policy

The shipped `player_animation_profile.tres` intentionally has no production SpriteFrames and permits
the Polygon hamster placeholder. A missing final sprite asset therefore does not block gameplay,
headless CI, or dedicated server simulation. `presentation_enabled=false` actors do not load or
instantiate the visual scene at all.

## Remote event ordering

Remote transient presentation follows authoritative presentation event arrival order. Attack, Dodge,
and HURT events announce actions that already started on the server, so a cosmetic local timer must
never reject a later valid event. Same-type stale or duplicate sequences remain rejected, but sequence
numbers from different action types are never compared. Death is the only absolute visual override.
