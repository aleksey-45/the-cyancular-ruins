shader_type canvas_item;

// siri 版形体光:不依赖 main 的逐资产几何 tag,用精灵 alpha 梯度近似 2D 法线。
// 视觉目标是"亮面提亮、暗面压暗、迎光边有方向感",不是 main 的精确椭球/圆柱模型。

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
		vec2 normal = vec2(aL - aR, aU - aD) * bulge;
		float len = length(normal);
		vec2 n2 = len > 0.0001 ? normal / len : vec2(0.0);
		float ndl = 0.5 + 0.5 * dot(n2, -normalize(sun_dir));
		ndl = smoothstep(edge_lo, edge_hi, ndl);
		if (steps >= 1.5) {
			float levels = max(steps, 1.0);
			ndl = floor(ndl * levels + bayer4(FRAGCOORD.xy) * dither) / levels;
			ndl = clamp(ndl, 0.0, 1.0);
		}
		float shade = mix(1.0 - gain * 0.5, 1.0 + boost, ndl);
		COLOR = vec4(tex.rgb * shade, tex.a);
	}
}
