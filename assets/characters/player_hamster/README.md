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
| `run` | `hamster_walk.png` | 4x2 / 8 | 14 | yes |
| `jump` | `hamster_jump_jump.png` | 3x2 / 6 | 11 | no |
| `fall` | `hamster_fall.png` | 3x2 / 6 | 9 | yes |
| `land` | `hamster_land.png` | 3x2 / 6 | 20 | no |
| `climb` | `hamster_climb_ladder.png` | 4x2 / 8 | 10 | yes |
| `climb_idle` | `hamster_climb_ladder.png` | 4x2 / 8 | 6 | no |
| `dodge` | `hamster_dodge.png` | 4x2 / 8 | 12 | no |
| `hurt` | `hamster_hurt.png` | 4x2 / 8 | 12 | no |
| `death` | `hamster_death.png` | 4x2 / 8 | 10 | no |
| `attack_1` | `hamster_attack_one_handed.png` | 4x2 / 8 | 12 | no |
| `attack_2` | `hamster_attack_2.png` | 4x2 / 8 | 12 | no |
| `attack_3` | `hamster_attack_one_handed.png` | 4x2 / 8 | 12 | no |

The hand-aligned walk sheet drives the existing moving-ground clip. The optional
`land` clip plays after an air-to-ground transition and yields to combat and death
presentation. `climb_idle` shares the climb texture, and `attack_3` shares the
first attack texture through separate manifest entries.

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

The hand-aligned PNGs use the artwork layer from the Aseprite exports. Their
normalized cells preserve the authored relative frame offsets and align the
standing contact line with the shipped presentation profile.

Full contract, authoring rules and the readiness checklist:
[docs/character_animation_assets.md](../../../docs/character_animation_assets.md).
