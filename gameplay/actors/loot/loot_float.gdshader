shader_type canvas_item;

uniform float amplitude = 5.0;
uniform float angular_speed = 1.8;
instance uniform float phase = 0.0;

void vertex() {
	VERTEX.y += amplitude * sin(TIME * angular_speed + phase);
}
