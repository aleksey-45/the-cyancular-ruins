vec3 rewind_film_color(vec3 rgb, vec2 screen_uv, float coverage) {
	float radius = distance(screen_uv, vec2(0.5)) / 0.75;
	float amount = smoothstep(0.0, 0.28, coverage - radius);
	vec3 negative = vec3(1.0) - rgb;
	float gray = dot(negative, vec3(0.299, 0.587, 0.114));
	return mix(rgb, mix(negative, vec3(gray), 0.25), amount);
}
