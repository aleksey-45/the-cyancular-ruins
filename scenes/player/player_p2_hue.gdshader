shader_type canvas_item;
// 共用画布通过每条贴图指令的红色通道传入归一化的色相偏移。
varying float hue_shift;

void vertex() {
	hue_shift = COLOR.r;
	COLOR.r = 1.0;
}

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
	hsv.x = fract(hsv.x + hue_shift);
	COLOR.rgb = hsv2rgb(hsv);
}
