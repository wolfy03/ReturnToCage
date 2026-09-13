class_name EnvironmentDefinition
extends Resource
## Visual environment preset for one world presentation (Settlement or an
## Adventure region): a fallback color plus ordered background layers.
##
## This is deliberately NOT a ContentDefinition and must not live under
## res://data/content: ContentRegistry loads everything there at startup,
## including on the dedicated server / headless runtime, and this resource
## references large textures. Presets live in res://world/environment/presets
## and are loaded lazily by EnvironmentPresenter only for visible worlds.
##
## Future additions belong here as plain data (day/night tint curve, star
## visibility, sun/moon path, fog, weather, foreground layers); the presenter
## decides how to draw them. Keep gameplay/authoritative state out of it.

## Solid color drawn behind every layer. Also what the player sees when the
## textures cannot be loaded.
@export var fallback_color: Color = Color("162133")
## Coordinate space the layer/sprite positions are authored in. The presenter
## scales positions uniformly (by height) when the actual viewport differs.
@export var reference_size: Vector2 = Vector2(1280, 720)
@export var layers: Array[BackgroundLayerDefinition] = []

## Layers that are enabled and have something to draw, in authored order.
func active_layers() -> Array[BackgroundLayerDefinition]:
	var result: Array[BackgroundLayerDefinition] = []
	for layer in layers:
		if layer != null and layer.enabled and layer.has_content():
			result.append(layer)
	return result

func find_layer(layer_name: StringName) -> BackgroundLayerDefinition:
	for layer in layers:
		if layer != null and layer.layer_name == layer_name:
			return layer
	return null
