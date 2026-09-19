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
raw generative output
  -> Python Sprite Asset Build Tool       outside Godot
  -> normalized PNG sheets                assets/characters/player_hamster/source/
  -> PlayerSpriteManifest                 player_hamster_sprite_manifest.tres
  -> Godot PlayerSpriteFramesBuilder
  -> SpriteFrames                         player_hamster_sprite_frames.tres   (generated)
  -> CharacterAnimationProfile
  -> PlayerAnimationPresenter -> AnimatedSprite2D
```

### Two tools, two jobs

The word "build tool" covers two separate stages and they must not be confused.

The **Python Sprite Asset Build Tool** turns raw generative output into a production sheet: frame
extraction, background cleanup and transparent alpha, frame normalisation, canvas composition,
alignment, and the 1024x512 output. It is the only place raw art is reshaped.

The **Godot `PlayerSpriteFramesBuilder`** takes an already-normalised sheet and slices it: grid to
`AtlasTexture`, semantic clip, fps, loop, `SpriteFrames`. It never resizes an image, removes a
background, repositions a character or corrects identity drift. If a sheet needs any of that, it is
not ready to be in `source/`.

### What the manifest owns

The manifest is the source of truth for **sprite sheet semantic identity and slicing/playback
metadata** — and only that. PNG file names are an import convenience;
`PlayerSpriteAnimationEntry.semantic_name` is what the game binds to, so sheets may be named
anything.

It is deliberately not the source of truth for presentation. How large the character appears, which
way it faces and where it sits are runtime concerns owned solely by `CharacterAnimationProfile`
(`visual_scale`, `visual_offset`, `faces_right_by_default`). The presenter reads only the profile, so
a copy of those values in the manifest would be a setting that never reaches the screen.

### Building

Production build — the default. It refuses an incomplete manifest, because the default output is the
resource the game ships and a partial one would make the repository claim art it does not have:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn
```

Preview build, for art that is still arriving. It needs the explicit flag *and* its own output path;
the shipped resource is off limits to a preview whether the manifest is complete or not:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
    --allow-incomplete --output=user://player_hamster_preview_frames.tres
```

The shipped resource also belongs to one manifest. `--manifest` pointed anywhere other than
`player_hamster_sprite_manifest.tres` is refused the production output path, complete or not, flag or
no flag — it has to name its own:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
    --manifest=res://sandbox/experiment_manifest.tres \
    --output=user://experiment_frames.tres
```

The reason is the check below: it regenerates the shipped resource from the shipped manifest and
diffs. A build from some other manifest can be entirely valid and still not be that file, so writing
it to the shipped path produces a resource that is stale the moment it lands.

Both paths are compared canonically, so the rule cannot be stepped around by spelling the same file
differently — `tmp/../player_hamster_sprite_frames.tres`, `./player_hamster_sprite_frames.tres` and
a doubled slash all name the shipped resource and are treated as it. Only `res://` and `user://` are
accepted; an empty path, a bare filesystem path and anything climbing above its own root are refused
rather than guessed at.

With no manifest present the tool reports `SPRITE BUILD SKIPPED` and succeeds: the pipeline exists
before the art does.

The build is deterministic: the same manifest always yields the same animation order, frame order,
regions, speeds and loop flags, so regenerating and diffing is a meaningful check after a re-export.

### Repository state check

`tools/check_project.py` runs `validate_player_sprite_pipeline.tscn`, which checks that the manifest,
the generated `SpriteFrames` and the shipped profile agree. Any one of them can be committed without
the others, and most of those combinations are mistakes that an ordinary test run would not notice:

Everything it can report, it reports in one run — an author fixing sheets should not have to
rebuild five times to discover five faults. A duplicate semantic, a missing texture and an invalid
fps come back together, as do every missing required clip and every bad attack partition. The one
thing it stops after is a structurally broken manifest: completeness, the rebuild comparison and the
generated clips all mean nothing until the manifest parses, so reporting them would be noise.

```text
no manifest, no frames, placeholder profile            PASS   (where the project is now)
partial manifest, no frames, placeholder profile       PASS   (art arriving)
partial manifest with frames on the production path    FAIL   (preview artefact committed)
frames with no manifest                                FAIL   (nobody can regenerate it)
complete manifest, no frames                           FAIL   (source finished, never baked)
complete manifest and frames, placeholder profile      FAIL   (activation left half done)
profile using frames with no sources behind it         FAIL
complete, regenerated, activated                       PASS
```

For the last case it rebuilds from the manifest in memory and compares a production signature — clip
names, speeds, loop flags, regions, **which texture resource each frame came from**, and **each
frame's duration** — against the committed resource. Both of those last parts matter. Swapping
`old_run.png` for a same-sized `new_run.png` leaves regions identical, so region metadata alone would
call a stale resource current. And Godot stores a playback multiplier on every individual frame that
the editor will let someone retime by hand; nothing in the manifest produces that value, so a rebuild
would not reproduce it and the edit would survive unnoticed. Pixel content is not hashed; repainting
a PNG in place does not change how it is sliced.

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

## Stage status

```text
10A  pipeline ready, placeholder active     <- the repository is here
10B  hardening done; activation waiting on production art
```

10B tightened the pipeline before any art lands. The production signature covers per-frame duration;
the shipped output path accepts only the shipped manifest, compared canonically so a different
spelling is not a different file; the check reports every authoring fault in one run; and the
ownership scope is stated the same way in every document. The activation steps below are unchanged
and still waiting on `source/`, which is empty.

## Placeholder policy

The shipped `player_animation_profile.tres` intentionally has no production SpriteFrames and permits
the Polygon hamster placeholder. A missing final sprite asset therefore does not block gameplay,
headless CI, or dedicated server simulation. `presentation_enabled=false` actors do not load or
instantiate the visual scene at all.

The placeholder is all-or-nothing. Mixing a production `idle` with a polygon `run` would look worse
than either, so partial art keeps the placeholder for everything. `PlaceholderVisual` stays in the
scene after activation as a runtime fallback.

### Production activation

Land it as one commit — normalised PNGs, manifest, generated `SpriteFrames`, the profile's
`sprite_frames`, `allow_placeholder = false` and the real attack partitions together. Any partial
combination is one of the FAIL states above, so a half-finished activation cannot sit on master.

Only once every required clip exists and validates:

1. Generate `player_hamster_sprite_frames.tres` from the manifest.
2. Point `player_animation_profile.tres`'s `sprite_frames` at it.
3. Set `allow_placeholder = false`, so a clip that goes missing later fails CI instead of silently
   falling back.
4. Re-check each `AttackAnimationBinding`'s frame partitions against the real pose count.

Facing and visual transform are tuned in `player_animation_profile.tres` at this point, never added
back to the manifest.

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
