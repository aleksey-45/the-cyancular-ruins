shader_type canvas_item;

uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size    = vec2(1.0, 1.0);
uniform vec2  center_cell = vec2(0.0, 0.0);
uniform float px_per_cell = 7.0;
uniform float radius      = 140.0;
uniform float ring        = 4.0;
uniform vec3  ring_color  = vec3(0.45, 0.46, 0.48);
uniform float ring_mix    = 0.85;

void fragment() {
	// 以圆心为原点的屏幕像素(V 轴向下,与 Godot 一致)
	vec2 p = UV * (2.0 * radius) - vec2(radius);
	float d = length(p);
	if (d > radius) {
		discard;
	}
	vec2 uv = (center_cell + p / px_per_cell + 0.5) / map_size;
	COLOR = texture(map_tex, uv);
	if (d > radius - ring) {
		COLOR.rgb = mix(COLOR.rgb, ring_color, ring_mix);
	}
}
