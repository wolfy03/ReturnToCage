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

## Asset pipeline

```
build-tool PNG sheets              assets/characters/player_hamster/source/
        -> PlayerSpriteManifest    player_hamster_sprite_manifest.tres
        -> SpriteFrames            player_hamster_sprite_frames.tres   (generated)
        -> CharacterAnimationProfile
        -> PlayerAnimationPresenter -> AnimatedSprite2D
```

The manifest is the source of truth for what each sheet means. PNG file names are an import
convenience; `PlayerSpriteAnimationEntry.semantic_name` is what the game binds to, so sheets may be
named anything.

Regenerate the SpriteFrames after changing sheets or the manifest:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
    --manifest=res://assets/characters/player_hamster/player_hamster_sprite_manifest.tres \
    --output=res://assets/characters/player_hamster/player_hamster_sprite_frames.tres
```

With no manifest present the tool reports `SPRITE BUILD SKIPPED` and succeeds: the pipeline exists
before the art does. A partial manifest still builds — it reports which clips are missing — because
previewing the art in hand is useful. Activating it in the shipped profile is the step that requires
every clip.

The build is deterministic: the same manifest always yields the same animation order, frame order,
regions, speeds and loop flags, so regenerating and diffing is a meaningful check after a re-export.

### Sheet layout

The canonical sheet is **1024x512, cut 4x2 into 256x256 frames**. Other grids are allowed as long as
the sheet divides evenly by its columns and rows; the build tool warns when a frame canvas is not
256x256, because mixing canvases between clips is how a character starts changing size mid-combo.

Frames are read **row-major** and this is never inferred:

```text
0 1 2 3
4 5 6 7
```

`frame_count` may be smaller than `columns * rows` — a six-frame clip on a 4x2 sheet simply leaves
its last two cells unused.

Raw generative output (1774x887, 1254x1254, or any other unstructured canvas) is never used as a
SpriteFrames source and never resized or stretched to fit. Resizing hides frame distortion and anchor
drift instead of fixing them; use the build tool's frame extraction and recomposition output.
Incomplete background removal is likewise not patched over with a threshold.

### Per-clip playback

`fps` and `loop` are authored per clip. FPS is the real playback speed for locomotion clips only:

```text
idle        8-10 fps    loop
run         12-16 fps   loop
jump        10-12 fps   one-shot
fall        8-10 fps
climb       8-12 fps    loop
climb_idle  6-8 fps     loop
dodge / hurt / death / attack_1..3       one-shot
```

Attack, dodge and hit-stun clips are seeked explicitly from authoritative gameplay progress, so their
FPS is not a timing source. `loop = false` on them records what the asset is, not how it is driven.

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

## Visual transform

`CharacterAnimationProfile.visual_scale` and `visual_offset` are applied to the presentation child
only — scale on the presenter, offset on the sprite. Production sprite pixels and the placeholder
polygon are very different sizes, and that difference must never reach collision, hitbox, hurtbox or
interaction geometry. Facing composes with the authored scale: the presenter flips the sign of x
around its magnitude rather than replacing it, which is why `visual_scale` must be positive.

## Placeholder policy

The shipped `player_animation_profile.tres` intentionally has no production SpriteFrames and permits
the Polygon hamster placeholder. A missing final sprite asset therefore does not block gameplay,
headless CI, or dedicated server simulation. `presentation_enabled=false` actors do not load or
instantiate the visual scene at all.

The placeholder is all-or-nothing. Mixing a production `idle` with a polygon `run` would look worse
than either, so partial art keeps the placeholder for everything. `PlaceholderVisual` stays in the
scene after activation as a runtime fallback.

### Production activation

Only once every required clip exists and validates:

1. Generate `player_hamster_sprite_frames.tres` from the manifest.
2. Point `player_animation_profile.tres`'s `sprite_frames` at it.
3. Set `allow_placeholder = false`, so a clip that goes missing later fails CI instead of silently
   falling back.
4. Re-check each `AttackAnimationBinding`'s frame partitions against the real pose count.

Never substitute one clip for another to reach completeness — duplicating `attack_2` into `attack_3`,
or reusing `jump` as `fall`, is an art decision disguised as a build step.

### Asset readiness checklist

```text
[ ] all 12 required clips exist
[ ] transparent background, no baked floor or ground shadow
[ ] no baked weapon, slash, impact, afterimage, dust, blood or scene props
[ ] climb sheets show the back view without a baked rope or ladder
[ ] frame canvas consistent within and across clips
[ ] anchor stable: feet on ground clips, body centre in air and climb
[ ] character scale consistent between clips
[ ] canonical facing consistent with faces_right_by_default
[ ] no clipped ears, feet or tail at the canvas edge
[ ] no white, black or dirty semi-transparent halo at alpha edges
[ ] attack contact poses located, partitions authored from them
[ ] profile validates with allow_placeholder = false
```

Automation cannot catch identity drift. A person still has to look for a face that changes shape
between frames, ears or feet that change count, fur markings that wander, a tail that appears and
disappears, malformed limbs, and body proportions that drift across a clip.

## Remote event ordering

Remote transient presentation follows authoritative presentation event arrival order. Attack, Dodge,
and HURT events announce actions that already started on the server, so a cosmetic local timer must
never reject a later valid event. Same-type stale or duplicate sequences remain rejected, but sequence
numbers from different action types are never compared. Death is the only absolute visual override.
