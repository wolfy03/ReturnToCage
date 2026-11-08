shader_type canvas_item;

uniform float amplitude = 5.0;
uniform float angular_speed = 1.8;
instance uniform float phase = 0.0;
instance uniform float inverse_display_scale = 1.0;
instance uniform float float_weight = 1.0;

void vertex() {
	// The sprite transform applies its display scale after this displacement.
	VERTEX.y += amplitude * inverse_display_scale * float_weight * sin(TIME * angular_speed + phase);
}
