shader_type canvas_item;

// siri 版形体光:不依赖 main 的逐资产几何 tag,用精灵 alpha 梯度近似 2D 法线。
// 视觉目标是"亮面提亮、暗面压暗、迎光边有方向感",不是 main 的精确椭球/圆柱模型。
// ★ 平面内部必须用 main 的 flat 法线 (0,0,1),否则纯色精灵会被整体压暗。

uniform vec2 sun_dir = vec2(0.45, -0.89); // 指向光源的屏幕空间单位向量
uniform float gain : hint_range(0.0, 1.0) = 0.5;
uniform float boost : hint_range(0.0, 0.5) = 0.05;
uniform float steps : hint_range(0.0, 6.0) = 4.0;
uniform float dither : hint_range(0.0, 1.0) = 0.3;
uniform float bulge : hint_range(0.5, 3.0) = 1.0;
uniform float edge_lo : hint_range(-0.5, 1.0) = 0.2;
uniform float edge_hi : hint_range(-0.5, 1.5) = 0.8;

float bayer4(vec2 p) {
	vec2 f = floor(mod(p, 4.0));
	float m[16] = {0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
			3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0};
	return m[int(f.x + f.y * 4.0)] / 16.0;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV) * COLOR;
	if (tex.a <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		vec2 px = TEXTURE_PIXEL_SIZE;
		float aL = texture(TEXTURE, UV - vec2(px.x, 0.0)).a;
		float aR = texture(TEXTURE, UV + vec2(px.x, 0.0)).a;
		float aU = texture(TEXTURE, UV - vec2(0.0, px.y)).a;
		float aD = texture(TEXTURE, UV + vec2(0.0, px.y)).a;
		vec2 grad = vec2(aL - aR, aU - aD);
		vec3 n = vec3(0.0, 0.0, 1.0);
		float len = length(grad);
		if (len > 0.0001) {
			vec2 p = normalize(grad) * bulge;
			n = normalize(vec3(p * 0.35, 0.35));
		}
		vec3 l = normalize(vec3(sun_dir.x, sun_dir.y, 1.0));
		float ndl = clamp(dot(n, l), 0.0, 1.0);
		ndl = smoothstep(edge_lo, edge_hi, ndl);
		if (steps >= 1.5) {
			float b = bayer4(FRAGCOORD.xy) - 0.5;
			ndl = ndl + b * dither / max(steps, 1.0);
			ndl = clamp(floor(ndl * steps + 0.5) / steps, 0.0, 1.0);
		}
		COLOR = vec4(tex.rgb * (1.0 + boost) * mix(1.0 - gain, 1.0, ndl), tex.a);
	}
}
