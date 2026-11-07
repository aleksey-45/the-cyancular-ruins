shader_type canvas_item;
render_mode unshaded;

// 死亡倒带叠加层：输入是已解码的 640×480 采集帧（含 HUD/后处理）。
// 效果：CRT 桶形 + 垂直滚动 + 逐行抖动 + tracking 带 + 色差/chroma bleed
//       + 扫描线/噪点/dropout + 底片化/去饱和/冷青 tint + 暗角 + 白闪。

uniform sampler2D tape_tex : filter_linear, repeat_disable;
uniform vec2 tape_px = vec2(640.0, 480.0);
uniform float frame_seed = 0.0;
uniform float tape_time = 0.0;
uniform float speed = 1.0;
uniform float speed_norm : hint_range(0.0, 1.0) = 0.0;

uniform float film : hint_range(0.0, 1.0) = 0.85;
uniform float desat : hint_range(0.0, 1.0) = 0.15;
uniform vec3 tape_tint : source_color = vec3(0.88, 0.95, 1.02);
uniform float contrast_lift : hint_range(0.0, 0.5) = 0.06;
uniform float flash : hint_range(0.0, 1.0) = 0.0;

uniform float barrel : hint_range(0.0, 0.5) = 0.28;
uniform float roll = 0.0;
uniform float wobble_px : hint_range(0.0, 6.0) = 1.2;
uniform float tracking : hint_range(0.0, 1.0) = 0.40;
uniform float tracking_height : hint_range(0.01, 0.4) = 0.10;
uniform float head_switch_h : hint_range(0.0, 0.15) = 0.03;
uniform float chroma_px = 2.0;
uniform float chroma_bleed : hint_range(0.0, 1.0) = 0.35;
uniform float scan_alpha : hint_range(0.0, 1.0) = 0.18;
uniform float noise_amt : hint_range(0.0, 1.0) = 0.06;
uniform float dropout : hint_range(0.0, 1.0) = 0.15;
uniform float vignette : hint_range(0.0, 1.0) = 0.45;
uniform float glow_boost : hint_range(0.0, 0.5) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec2 barrel_uv(vec2 uv, float k) {
	vec2 c = uv - 0.5;
	float r = length(c);
	return c * ((r * (1.0 + k * r * r)) / max(r, 1e-4)) + 0.5;
}

void fragment() {
	vec2 uv = barrel_uv(UV, barrel);
	uv = vec2(uv.x, fract(uv.y + roll));
	float line = floor(uv.y * tape_px.y);

	float wob = (hash21(vec2(line * 0.07, frame_seed)) - 0.5) * wobble_px / tape_px.x;
	float band_y = fract(tape_time * 0.09 + 0.31);
	float band = tracking * smoothstep(tracking_height, 0.0,
			abs(fract(uv.y - band_y + 0.5) - 0.5));
	wob += band * (hash21(vec2(line, frame_seed + 3.0)) - 0.35) * 40.0 / tape_px.x;
	float head = smoothstep(1.0 - head_switch_h, 1.0, uv.y) * step(0.0001, head_switch_h);
	wob += head * (0.5 + hash21(vec2(line, frame_seed))) * 30.0 / tape_px.x;

	vec2 suv = clamp(uv + vec2(wob, 0.0), vec2(0.0), vec2(1.0));
	float px = 1.0 / tape_px.x;
	vec3 cen = texture(tape_tex, suv).rgb;
	float cx = chroma_px * px;
	float cr = texture(tape_tex, clamp(suv + vec2(cx, 0.0), vec2(0.0), vec2(1.0))).r;
	float cb = texture(tape_tex, clamp(suv - vec2(cx, 0.0), vec2(0.0), vec2(1.0))).b;
	vec3 acc = vec3(0.0);
	for (int i = -2; i <= 2; i++) {
		acc += texture(tape_tex, clamp(suv + vec2(float(i) * chroma_bleed * 2.0 * px, 0.0),
				vec2(0.0), vec2(1.0))).rgb;
	}
	acc /= 5.0;
	vec3 col = vec3(luma(cen)) + (acc - vec3(luma(acc))) * (1.0 - 0.3 * chroma_bleed);
	col.r = mix(col.r, cr, 0.5);
	col.b = mix(col.b, cb, 0.5);

	if (mod(line, 3.0) < 1.0) {
		col *= 1.0 - scan_alpha;
	}
	float n = hash21(floor(uv * tape_px) + vec2(frame_seed * 7.13, frame_seed * 3.7));
	col += (n - 0.5) * noise_amt;
	float drop = step(1.0 - dropout * 0.02, hash21(vec2(line * 0.13, frame_seed)));
	col = mix(col, vec3(0.92, 0.97, 1.0), drop * 0.85);
	col += band * (hash21(vec2(uv.x * 300.0, line + frame_seed)) - 0.4) * 0.5;
	col += head * (hash21(vec2(uv.x * 220.0, line)) - 0.4) * 0.35;

	vec3 inv = vec3(1.0) - col;
	col = mix(col, mix(inv, vec3(luma(inv)), 0.25), film);
	col = mix(col, vec3(luma(col)), desat);
	col *= tape_tint;
	col = col * (1.0 - contrast_lift) + contrast_lift;
	col += vec3(0.05, 0.075, 0.10) * glow_boost;

	float vr = clamp(distance(UV, vec2(0.5)) / 0.75, 0.0, 1.0);
	col *= mix(1.0, 1.0 - vignette, vr * vr);
	col = mix(col, vec3(0.97, 0.99, 1.0), flash);
	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
