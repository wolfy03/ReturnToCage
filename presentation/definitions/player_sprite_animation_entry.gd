class_name PlayerSpriteAnimationEntry
extends Resource
## One authored animation sheet: which texture it is, how it is cut, and how it
## plays back.
##
## Presentation-only, and deliberately outside `data/content` — it holds a
## [Texture2D] reference, and a headless server must never discover art through
## [ContentRegistry]. Gameplay Resources never reference textures.
##
## This describes a sheet, not gameplay. `fps` is the authored playback speed for
## locomotion clips; it is never the source of attack, dodge or hit-stun timing,
## which the presenter seeks explicitly from authoritative gameplay progress.

## The clip this sheet provides, as [CharacterAnimationProfile] names it. The
## PNG's file name is an import convenience and means nothing at runtime.
@export var semantic_name: StringName
@export var texture: Texture2D

## Sheet layout. The production pipeline targets a 1024x512 sheet cut 4x2 into
## 256x256 frames, but the grid is authored rather than assumed so a clip can be
## six frames or ten without touching code.
@export_range(1, 32, 1) var columns: int = 4
@export_range(1, 32, 1) var rows: int = 2
## How many cells of the grid are real frames, read row-major from the top left.
## A 4x2 sheet with six frames simply leaves its last two cells unused.
@export_range(1, 256, 1) var frame_count: int = 8
@export_range(1.0, 120.0, 0.1) var fps: float = 12.0
@export var loop: bool = true

## The frame canvas the build tool produces. A different size is not an error —
## the grid only has to divide evenly — but it is worth flagging, because mixing
## canvases between clips is how a character starts changing size mid-combo.
const PREFERRED_FRAME_SIZE := Vector2i(256, 256)
## The canonical eight-frame sheet: 1024x512, 4x2, 256x256 frames.
const PREFERRED_SHEET_SIZE := Vector2i(1024, 512)

func texture_size() -> Vector2i:
	if texture == null:
		return Vector2i.ZERO
	return Vector2i(texture.get_width(), texture.get_height())

## Size of one cell. Zero when the sheet cannot be cut evenly.
func frame_size() -> Vector2i:
	var size := texture_size()
	if size.x <= 0 or size.y <= 0 or columns <= 0 or rows <= 0:
		return Vector2i.ZERO
	if size.x % columns != 0 or size.y % rows != 0:
		return Vector2i.ZERO
	return Vector2i(size.x / columns, size.y / rows)

## Row-major, always: frame 3 of a 4-wide sheet is the top-right cell and frame
## 4 is the start of the second row. Snake ordering and right-to-left rows are
## not inferred from anything — the contract is explicit so a re-export cannot
## silently reverse an animation.
func region_for(index: int) -> Rect2:
	var cell := frame_size()
	if cell == Vector2i.ZERO or index < 0 or index >= frame_count:
		return Rect2()
	var column := index % columns
	var row := index / columns
	return Rect2(column * cell.x, row * cell.y, cell.x, cell.y)

func validation_errors(owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if semantic_name.is_empty():
		errors.append("%ssprite entry semantic_name must not be empty" % prefix)
	if columns <= 0 or rows <= 0:
		errors.append("%ssprite entry grid must have positive columns and rows" % prefix)
	if frame_count <= 0:
		errors.append("%ssprite entry frame_count must be positive" % prefix)
	if columns > 0 and rows > 0 and frame_count > columns * rows:
		errors.append("%ssprite entry frame_count %d exceeds its %dx%d grid" % [prefix, frame_count, columns, rows])
	if not is_finite(fps) or fps <= 0.0:
		errors.append("%ssprite entry fps must be a positive finite rate" % prefix)
	if texture == null:
		errors.append("%ssprite entry texture is missing" % prefix)
		return errors
	var size := texture_size()
	if size.x <= 0 or size.y <= 0:
		errors.append("%ssprite entry texture has no pixels" % prefix)
		return errors
	if columns > 0 and size.x % columns != 0:
		errors.append("%ssprite entry texture width %d is not divisible by %d columns" % [prefix, size.x, columns])
	if rows > 0 and size.y % rows != 0:
		errors.append("%ssprite entry texture height %d is not divisible by %d rows" % [prefix, size.y, rows])
	return errors

## Advisory only. A sheet that cuts evenly but not into the production canvas is
## usable; it just deserves a second look before it ships.
func preferred_layout_warnings(owner_id: StringName = &"") -> PackedStringArray:
	var warnings := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	var cell := frame_size()
	if cell == Vector2i.ZERO:
		return warnings
	if cell != PREFERRED_FRAME_SIZE:
		warnings.append("%sframe canvas is %dx%d, not the production %dx%d" % [
			prefix, cell.x, cell.y, PREFERRED_FRAME_SIZE.x, PREFERRED_FRAME_SIZE.y
		])
	return warnings
