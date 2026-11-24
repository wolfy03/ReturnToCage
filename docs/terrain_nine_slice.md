# Terrain nine-slice contract

`FieldPlatform` is a StaticBody2D scene instance with a centered RectangleShape2D in CollisionShape2D and a centered Polygon2D named Visual. Collision layers and masks belong to the body. The platform script builds the polygon and shape from local size and applies the authored one-way flag. The bridge uses a stable identity derived from the region, node path and script for objects without explicit editor IDs. It preserves instance ownership, transform and resource UID. When the semantic snapshot is unchanged the bridge skips ResourceSaver, preserving original bytes.

Terrain metadata lives in `assets/terrain/<theme_id>.json`. Format `rtc_terrain_9slice`, version 1, stores a project-relative PNG, its original dimensions, and positive integer left/right/top/bottom margins. Each pair of margins is strictly smaller than its image axis. The source bounds along X are 0, left, width minus right, width. Y uses top and bottom the same way. PNGs are sampled with nearest filtering. The center and edges repeat at native pixel size, beginning at each destination cell's top-left, clipping incomplete final tiles. At exactly the minimum size the respective middle row or column is empty.

The nine-slice occupies the same rectangle as the collision shape. The whole rectangle rotates with the node. The texture's alpha affects only rendering. Legacy platforms retain their original polygon. Applying a theme explicitly to a standard, inline, unscripted platform attaches the FieldPlatform script in place and records its prior editor ID. The original node, collision shape, visual child, tint, owner and transform are retained. Conversion of custom visuals or scaled platforms to nine-slice is blocked where exact preview parity cannot be guaranteed.

A draft containing a terrain surface writes Schema V5. The surface stores the theme ID, texture, source dimensions and effective margins. This captures overrides and allows geometry validation without a project or Godot. Legacy drafts continue writing their original V2, V3 or V4 shape. Unknown fields cause a read error before a document can be replaced. The bridge checks that the theme is registered and the PNG exists in the same project snapshot before publishing. Atlas files are project dependencies and remain outside the Scene/RegionDefinition transaction.

The two shipped diagnostic atlases exercise sewer and forest registrations. They are test patterns; production art should replace them only after repeat seams and metadata have been checked.

## Editing and verification

Use the library's platform brush theme for Paint, Rectangle and drag placement. With a platform selected, the Inspector switches between legacy and a registered atlas, and accepts an optional PNG or margin override. The margin order is left, top, right, bottom. Applying an appearance does not resize an existing platform; enlarge it first if its current size is below the border minimum. Drag resize clamps to the minimum. Brush creation fits the minimum before committing. Appearance edits and placement presets use the existing undo stack.

The Windows bundle includes the two diagnostic themes for use without Godot. Selecting a project folder loads that project's registrations. A missing or invalid atlas is shown as a crossed red platform and reported by Python validation. Godot conversion verifies the actual project assets and imported texture UID before staging the two-file transaction. The PNG must have its Godot-generated .png.import sidecar in the target project. The bridge rejects settings or UIDs that its isolated import had to rewrite.

From the repository root, run the paired pixel comparison and isolated Sewer publication with the official Windows Godot executable:

```powershell
python tools/python_map_editor/check_terrain.py --godot <godot-exe> --artifacts <output-directory>
```

The comparison records source-sized, resized, tall, wide and rotated platform captures from both renderers. It checks pixel coverage and color, and checks that applying appearance leaves the same collision resource, size, mask, layer and one-way flag in use. The bridge test runs in a disposable project and checks that only the intended node changes and that both V3 and region-design views reload the published asset.
