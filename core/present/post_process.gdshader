shader_type canvas_item;

uniform sampler2D screen_tex : filter_nearest, repeat_disable;

uniform bool barrel_enabled = true;
uniform float barrel_strength : hint_range(0.0, 0.5) = 0.3;
// 窗口尺寸 / 世界视口尺寸，把窗口 uv 映射到世界纹理的中心裁剪区。
uniform vec2 crop_scale = vec2(1.0);
uniform float desat : hint_range(0.0, 1.0) = 0.0;
// 受击红闪:0=无,1=纯红罩。由 PostProcess.flash_hit() 置峰后每帧衰减。
uniform float hit_red : hint_range(0.0, 1.0) = 0.0;
// ── 怀表时间系统·第一阶段(时间玩法)三个全屏效果 ──
uniform float rewind_film : hint_range(0.0, 1.0) = 0.0;   // 回溯底片化覆盖度(0→1:由内而外铺满)
uniform float loan_depth : hint_range(0.0, 1.0) = 0.0;    // 透支深度:变亮 + 红蓝色差
uniform float haste_dim : hint_range(0.0, 1.0) = 0.0;     // 加速压暗覆盖度(0→1:由内而外铺满)
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
	// ── 时间玩法视效:覆盖度模型 ──
	// cov=覆盖度(0→1)。逐像素半径 t(中心0→边缘1)与 cov 比较:cov 超过 t 的区域先被覆盖,
	// 过渡由内而外推进;cov=1 时全图覆盖 —— **最终效果是全图统一的**(底特律变人导航模式那种切换感)。
	float rt = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.75, 0.0, 1.0);

	// 回溯:全图统一底片色调(反色 + 轻去饱和)
	if (rewind_film > 0.0) {
		float amt = smoothstep(0.0, 0.28, rewind_film - rt);
		vec3 inv = vec3(1.0) - COLOR.rgb;
		float g = dot(inv, vec3(0.299, 0.587, 0.114));
		vec3 film = mix(inv, vec3(g), 0.25);
		COLOR.rgb = mix(COLOR.rgb, film, amt);
	}
	// 加速:全图统一压暗 + 冷色偏移(角色靠加色高亮"跳"出来 —— 见 TimeGlow)
	// -  0.42 → 0.55:压得太黑时用户会读成"一切都被调暗了、谁都没被高亮",留一点环境可读性。
	if (haste_dim > 0.0) {
		float amt = smoothstep(0.0, 0.28, haste_dim - rt);
		vec3 target = COLOR.rgb * 0.55 + vec3(0.02, 0.035, 0.07);
		COLOR.rgb = mix(COLOR.rgb, target, amt);
	}
	// 透支:整体变亮 + 红蓝色影分离(深度越深越明显)
	if (loan_depth > 0.0) {
		float off = loan_depth * loan_aberration / max(viewport_size.x, 1.0);
		vec3 base = texture(screen_tex, uv).rgb;
		float cr = texture(screen_tex, uv + vec2(off, 0.0)).r;
		float cb = texture(screen_tex, uv - vec2(off, 0.0)).b;
		COLOR.rgb = mix(COLOR.rgb, vec3(cr, base.g, cb), 0.9);
		COLOR.rgb += vec3(0.10, 0.095, 0.12) * loan_depth;
	}
}
