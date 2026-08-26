shader_type canvas_item;
// 水面逐格上下伸缩:以「格底」为锚做垂直 scale,整格高度 ×(1 + phase·amp/64),
// 顶部按 -phase*amp 伸缩、底端固定,正弦周期、相位逐格错开 → 波浪感。
// 水体层(WaterLayer)不挂此 shader,不伸缩。参数沿用 GameParameters.water_sway_amp / water_sway_speed。

uniform float amp = 3.0;
uniform float speed = 0.8;

void vertex() {
	vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	vec2 cell = floor(world / 64.0);
	// 相位逐格错开(1.7/2.3 非整数频率),相邻格起伏不同步 → 波浪
	float phase = sin(TIME * speed + cell.x * 1.7 + cell.y * 2.3);
	// 整格垂直伸缩(以格底为锚):底部不动,顶部移动 -phase*amp
	float bottom = (cell.y + 1.0) * 64.0;
	float s = 1.0 + phase * (amp / 64.0);
	float new_y = (world.y - bottom) * s + bottom;
	VERTEX.y += new_y - world.y;
}
