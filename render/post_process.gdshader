shader_type canvas_item;

uniform sampler2D screen_tex : filter_nearest, repeat_disable;

uniform bool barrel_enabled = true;
uniform float barrel_strength : hint_range(0.0, 0.5) = 0.3;
// 窗口尺寸 / 世界视口尺寸，把窗口 uv 映射到世界纹理的中心裁剪区。
uniform vec2 crop_scale = vec2(1.0);
uniform float desat : hint_range(0.0, 1.0) = 0.0;
// 受击红闪:0=无,1=纯红罩。由 PostProcess.flash_hit() 置峰后每帧衰减。
uniform float hit_red : hint_range(0.0, 1.0) = 0.0;
// ── 个人钟·第一阶段(时间玩法)三个全屏效果 ──
uniform float rewind_film : hint_range(0.0, 1.0) = 0.0;   // 回溯底片化(中心先变,向外辐射)
uniform float loan_depth : hint_range(0.0, 1.0) = 0.0;    // 贷款深度:变亮 + 红蓝色差
uniform float haste_dim : hint_range(0.0, 1.0) = 0.0;     // 加速:背景压暗 + 玩家处保持高亮
uniform vec2 player_uv = vec2(0.5, 0.5);                  // 玩家在屏幕上的归一化位置
uniform vec2 viewport_size = vec2(1920.0, 1440.0);        // 世界视口尺寸(色差换算像素偏移)
uniform float loan_aberration = 5.0;                      // 色差偏移上限(像素)

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
	if (hit_red > 0.0) {
		// 画面微红一瞬间:向红色偏移(保留暗部细节,不做纯色覆盖);0.6 = 可感知但不糊画面
		COLOR.rgb = mix(COLOR.rgb, vec3(0.85, 0.05, 0.05), hit_red * 0.6);
	}
	if (desat > 0.0) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(COLOR.rgb, vec3(g), desat);
	}
	// 回溯:底片色调由屏幕中心向外辐射渐变(中心最先/最深,边缘保留本色)
	if (rewind_film > 0.0) {
		float rr = distance(SCREEN_UV, vec2(0.5));
		float m = smoothstep(0.04, 0.55, rr);
		vec3 inv = vec3(1.0) - COLOR.rgb;
		vec3 film = mix(inv, COLOR.rgb, m * 0.85);
		COLOR.rgb = mix(COLOR.rgb, film, rewind_film);
	}
	// 贷款:整体变亮 + 红蓝色影分离(深度越深越明显)
	if (loan_depth > 0.0) {
		float off = loan_depth * loan_aberration / max(viewport_size.x, 1.0);
		vec3 base = texture(screen_tex, uv).rgb;
		float cr = texture(screen_tex, uv + vec2(off, 0.0)).r;
		float cb = texture(screen_tex, uv - vec2(off, 0.0)).b;
		COLOR.rgb = mix(COLOR.rgb, vec3(cr, base.g, cb), 0.9);
		COLOR.rgb += vec3(0.10, 0.095, 0.12) * loan_depth;
	}
	// 加速:背景大幅压暗,玩家所在小范围内保持原亮度(并轻微提亮 = 主角高亮)
	if (haste_dim > 0.0) {
		float pd = distance(SCREEN_UV, player_uv);
		float keep = 1.0 - smoothstep(0.03, 0.16, pd);
		float dim = mix(1.0 - 0.55 * haste_dim, 1.0, keep);
		COLOR.rgb *= dim;
		COLOR.rgb += vec3(0.05, 0.07, 0.10) * keep * haste_dim;
	}
}
