shader_type canvas_item;
// PvP 区分双方:给 P2 角色本体 AnimatedSprite2D 挂本 shader,色相旋转 hue_shift 度。
// 只染本体,武器/预瞄线等其它节点不受影响。结果 × COLOR,保住受击白闪(modulate 放大)与
// 无敌帧半透明(modulate.a)的既有效果。

uniform float hue_shift : hint_range(-180.0, 180.0) = -65.0;  // 度:P2 色相旋转量(负=反向),白/灰不变

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
	vec4 tex = texture(TEXTURE, UV);
	vec3 hsv = rgb2hsv(tex.rgb);
	hsv.x = fract(hsv.x + hue_shift / 360.0);
	tex.rgb = hsv2rgb(hsv);
	COLOR = tex * COLOR;
}
