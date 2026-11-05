# Player hamster sprite assets

Production character art is active. The shipped animation profile references the
generated `player_hamster_sprite_frames.tres`, disables placeholder mode, and
applies the visual-only scale/offset needed by the 256x256 frame canvas.

```
source/                              build-tool output PNGs, one sheet per clip
player_hamster_sprite_manifest.tres  PlayerSpriteManifest — what each sheet means
player_hamster_sprite_frames.tres    generated SpriteFrames — what the game loads
```

`source/` holds output from the **Python Sprite Asset Build Tool** — raw
generative output that has already been frame-extracted, background-cleaned,
normalised, composed and aligned. The Godot builder downstream only slices an
already-normalised sheet; it never resizes an image, removes a background or
repositions a character. A raw sheet is therefore not made to fit by resizing or
stretching it: that hides frame distortion and anchor drift rather than fixing
them.

The canonical sheet is **1024x512, cut 4x2 into 256x256 frames**, read row-major.
Other grids are allowed as long as the sheet divides evenly; the build tool warns
when a frame canvas is not 256x256.

## Active semantic mapping

| Semantic | Source sheet | Grid / frames | FPS | Loop |
|---|---|---:|---:|---|
| `idle` | `hamster_idle.png` | 4x2 / 8 | 9 | yes |
| `run` | `hamster_run_run.png` | 4x2 / 8 | 14 | yes |
| `jump` | `hamster_jump_jump.png` | 3x2 / 6 | 11 | no |
| `fall` | `hamster_fall.png` | 3x2 / 6 | 9 | yes |
| `climb` | `hamster_climb_ladder.png` | 4x2 / 8 | 10 | yes |
| `climb_idle` | `hamster_climb_ladder.png` | 4x2 / 8 | 6 | no |
| `dodge` | `hamster_dodge.png` | 4x2 / 8 | 12 | no |
| `hurt` | `hamster_hurt.png` | 4x2 / 8 | 12 | no |
| `death` | `hamster_death.png` | 4x2 / 8 | 10 | no |
| `attack_1` | `hamster_attack_one_handed.png` | 4x2 / 8 | 12 | no |
| `attack_2` | `hamster_attack_one_handed.png` | 4x2 / 8 | 12 | no |
| `attack_3` | `hamster_attack_one_handed.png` | 4x2 / 8 | 12 | no |

`climb_idle`, `attack_2`, and `attack_3` are explicit temporary semantic aliases.
They remain separate manifest entries so dedicated sheets can replace only their
texture references later. `hamster_walk.png` is retained but is not mapped while
gameplay has no separate walk semantic.

The active profile uses `visual_scale = (0.35, 0.35)` and
`visual_offset = (0, -72)`. These transform only the presentation child; actor,
collision, hitbox, hurtbox and interaction geometry are unchanged.

File names are an import convenience. The manifest's `semantic_name` is what the
game binds to, so a sheet may be called anything.

Regenerate the SpriteFrames after changing sheets or the manifest:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn
```

That is a production build and it refuses an incomplete manifest, because this
directory's `player_hamster_sprite_frames.tres` is what the game ships. To
preview art that is still arriving, say so and send it somewhere else:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
    --allow-incomplete --output=user://player_hamster_preview_frames.tres
```

The shipped resource belongs to the manifest in this directory and to no other. A build run with
`--manifest` pointed somewhere else is refused the production output path whether or not it is
complete, because CI regenerates that file from this manifest and would find anything else stale.

The manifest decides how sheets are cut and played. How large the character
appears and which way it faces belong to
`presentation/player/player_animation_profile.tres`, not here.

Art QA note: the normalized run sheet and two grounded fall poses touch their
256x256 alpha boundary. They are used without runtime resize/reposition as required;
a future source re-export may add transparent breathing room if visual review finds
edge clipping in motion.

Full contract, authoring rules and the readiness checklist:
[docs/character_animation_assets.md](../../../docs/character_animation_assets.md).
