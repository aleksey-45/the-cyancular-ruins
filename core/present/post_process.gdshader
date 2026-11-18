shader_type canvas_item;

#include "res://core/present/time_film.gdshaderinc"

uniform sampler2D screen_tex : filter_nearest, repeat_disable;

uniform bool barrel_enabled = true;
uniform float barrel_strength : hint_range(0.0, 0.5) = 0.3;
// 用窗口与视口的尺寸比确定采样区域，中心始终对齐。
uniform vec2 crop_scale = vec2(1.0);
uniform float desat : hint_range(0.0, 1.0) = 0.0;
// 脚本在受击时提高此值，再逐帧降低，使红色闪光消退。
uniform float hit_red : hint_range(0.0, 1.0) = 0.0;
// 当前的低生命值暗角强度。
uniform float low_hp : hint_range(0.0, 1.0) = 0.0;
uniform float rewind_film : hint_range(0.0, 1.0) = 0.0;   // 回溯时逐渐扩大滤镜的作用范围。
uniform float loan_depth : hint_range(0.0, 1.0) = 0.0;    // 将透支量换算到 0 至 1，供增亮和色差效果使用。
uniform float haste_dim : hint_range(0.0, 1.0) = 0.0;     // 加速时使暗色滤镜逐渐覆盖画面。
uniform vec2 viewport_size = vec2(1920.0, 1440.0);        // 世界视口的宽度用于把像素偏移换算成 UV 偏移。
uniform float loan_aberration = 5.0;                      // 透支达到上限时，红色和蓝色通道各自偏移的像素数。

void fragment() {
	vec2 uv = SCREEN_UV;

	if (barrel_enabled) {
		vec2 centered = uv - 0.5;
		float r = length(centered);
		float r_new = r * (1.0 + barrel_strength * r * r);
		uv = centered * (r_new / max(r, 0.0001)) + 0.5;
	}

	// 镜头畸变会用到窗口外的颜色，因此从较大的世界视口纹理取样。
	uv = (uv - 0.5) * crop_scale + 0.5;

	COLOR = texture(screen_tex, uv);
	if (hit_red > 0.0) {
		COLOR.rgb = mix(COLOR.rgb, vec3(0.85, 0.05, 0.05), hit_red * 0.6);
	}
	if (desat > 0.0) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(COLOR.rgb, vec3(g), desat);
	}
	// 加速效果使用相对屏幕中心的距离，平滑过渡到未处理的画面。
	float rt = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.75, 0.0, 1.0);

	// 回溯效果从画面中央扩展，应用反色并降低饱和度。
	if (rewind_film > 0.0) {
		COLOR.rgb = rewind_film_color(COLOR.rgb, SCREEN_UV, rewind_film);
	}
	if (haste_dim > 0.0) {
		float amt = smoothstep(0.0, 0.28, haste_dim - rt);
		vec3 target = COLOR.rgb * 0.55 + vec3(0.02, 0.035, 0.07);
		COLOR.rgb = mix(COLOR.rgb, target, amt);
	}
	if (low_hp > 0.0) {
		// 暗角随像素离中心的距离加深，中心区域保留原色。
		float edge = smoothstep(0.30, 0.78, distance(SCREEN_UV, vec2(0.5)) / 0.75);
		vec3 shade = COLOR.rgb * vec3(0.32, 0.22, 0.24);
		COLOR.rgb = mix(COLOR.rgb, shade, edge * low_hp * 0.85);
	}
	// 模拟透支效果时，沿水平方向错开红色与蓝色通道，再增加整体亮度。
	if (loan_depth > 0.0) {
		float off = loan_depth * loan_aberration / max(viewport_size.x, 1.0);
		vec3 base = texture(screen_tex, uv).rgb;
		float cr = texture(screen_tex, uv + vec2(off, 0.0)).r;
		float cb = texture(screen_tex, uv - vec2(off, 0.0)).b;
		COLOR.rgb = mix(COLOR.rgb, vec3(cr, base.g, cb), 0.9);
		COLOR.rgb += vec3(0.10, 0.095, 0.12) * loan_depth;
	}
}
