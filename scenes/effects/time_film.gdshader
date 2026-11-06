shader_type canvas_item;

uniform float coverage : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float rt = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.75, 0.0, 1.0);
	float amt = smoothstep(0.0, 0.28, coverage - rt);
	vec3 inv = vec3(1.0) - COLOR.rgb;
	float g = dot(inv, vec3(0.299, 0.587, 0.114));
	vec3 film = mix(inv, vec3(g), 0.25);
	COLOR.rgb = mix(COLOR.rgb, film, amt);
}
