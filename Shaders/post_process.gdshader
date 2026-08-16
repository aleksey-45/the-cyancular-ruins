shader_type canvas_item;

uniform sampler2D screen_tex : filter_nearest, repeat_disable;

uniform bool barrel_enabled = true;
uniform float barrel_strength : hint_range(0.0, 0.5) = 0.3;
// 窗口尺寸 / 世界视口尺寸，把窗口 uv 映射到世界纹理的中心裁剪区。
uniform vec2 crop_scale = vec2(1.0);
uniform float desat : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;

	if (barrel_enabled) {
		vec2 centered = uv - 0.5;
		float r = length(centered);
		float r_new = r * (1.0 + barrel_strength * r * r);
		uv = centered * (r_new / max(r, 0.0001)) + 0.5;
	}

	// 世界视口比窗口大，采样范围超出 [0,1] 时取到的是窗口外真实渲染的内容，
	// 因此去掉 clamp，鱼眼边缘不再有黑边。
	uv = (uv - 0.5) * crop_scale + 0.5;

	COLOR = texture(screen_tex, uv);
	if (desat > 0.0) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(COLOR.rgb, vec3(g), desat);
	}
}
