# Player hamster sprite assets

Drop-in point for the production character art. Nothing here is required for the
game to run: while these files are absent the shipped animation profile keeps
`allow_placeholder = true` and the polygon hamster is used instead.

```
source/                              build-tool output PNGs, one sheet per clip
player_hamster_sprite_manifest.tres  PlayerSpriteManifest — what each sheet means
player_hamster_sprite_frames.tres    generated SpriteFrames — what the game loads
```

`source/` holds normalised output from the sprite build tool, not raw generative
output. A raw sheet is not made to fit by resizing or stretching it: that hides
frame distortion and anchor drift rather than fixing them.

The canonical sheet is **1024x512, cut 4x2 into 256x256 frames**, read row-major.
Other grids are allowed as long as the sheet divides evenly; the build tool warns
when a frame canvas is not 256x256.

File names are an import convenience. The manifest's `semantic_name` is what the
game binds to, so a sheet may be called anything.

Regenerate the SpriteFrames after changing sheets or the manifest:

```sh
godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn
```

Full contract, authoring rules and the readiness checklist:
[docs/character_animation_assets.md](../../../docs/character_animation_assets.md).
