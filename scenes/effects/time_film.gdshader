shader_type canvas_item;

// Beta 时间玩法(P2):**底片色**着色器 —— 挂到"世界图层(砖/水)+ 自己"或"他人副本"上。
// 单机的底片是全屏后处理(会把所有人都变底片);用户裁定 PvP 里**敌方单位颜色不变化**,
// 所以这里改成"挂谁谁变":世界层 + 自己(PvP 客户端自己挂)、回溯者本人(他人视角)。
//
// coverage:0→1 的由内而外推进感(与单机 post_process 同款公式:SCREEN_UV 半径 vs 覆盖度)。
uniform float coverage : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float rt = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.75, 0.0, 1.0);
	float amt = smoothstep(0.0, 0.28, coverage - rt);
	vec3 inv = vec3(1.0) - COLOR.rgb;
	float g = dot(inv, vec3(0.299, 0.587, 0.114));
	vec3 film = mix(inv, vec3(g), 0.25);
	COLOR.rgb = mix(COLOR.rgb, film, amt);
}
