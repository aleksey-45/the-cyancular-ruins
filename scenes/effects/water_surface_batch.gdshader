shader_type canvas_item;

// 水体合批:**所有**液体格都走这一条管线(水面砖 / 水体砖只是图集里不同的 UV 行)。
// 同色、同 alpha、同条纹、同起伏 ⇒ 不存在"两层对不齐"的接缝。
varying vec2 v_world;

uniform sampler2D surf : filter_nearest;
uniform float sway_speed = 1.6;
uniform float sway_amp = 2.0;

void vertex() {
	// 顶点色:r=相位(0..1→0..TAU),g=本顶点的位移权重(底边 0 / 顶边随深度衰减)。
	float w = COLOR.g;
	float lift = sin(TIME * sway_speed + COLOR.r * 6.2831853) * (sway_amp * w);
	VERTEX.y += lift;
	v_world = VERTEX;
}

void fragment() {
	vec4 t = texture(surf, UV);
	// 横向流动条纹:亮度随 y 变化(水平条带),锚世界坐标 —— 锚屏幕会随相机在画面上"爬"。
	// 只做乘性压暗(0.95~1.0),不破「世界层乘性链」。
	float band = floor(v_world.y / 16.0);
	float s1 = sin(v_world.x * 0.020 + TIME * 1.10 + band * 0.7);
	float s2 = sin(v_world.x * 0.035 - TIME * 1.70 + band * 1.3);
	float st = clamp(0.5 + 0.25 * s1 + 0.25 * s2, 0.0, 1.0);
	st = floor(st * 3.0 + 0.5) / 3.0;
	t.rgb *= mix(0.95, 1.0, st);
	COLOR = t;
}
