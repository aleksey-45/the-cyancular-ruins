shader_type canvas_item;
// 仅旋转角色本体色相。COLOR 已包含纹理采样和 modulate，不再重复乘纹理。
uniform float hue_shift : hint_range(-180.0, 180.0) = 0.0;

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	// 只改色相:读**入参** COLOR(已含纹理),写回 rgb;alpha 原样透传。
	vec3 hsv = rgb2hsv(COLOR.rgb);
	hsv.x = fract(hsv.x + hue_shift / 360.0);
	COLOR.rgb = hsv2rgb(hsv);
}
