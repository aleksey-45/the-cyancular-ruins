shader_type canvas_item;
// 水面逐格上下起伏:每格瓦片以「底部」为锚(UV.y=1 → offset=0,恒不动),顶部拉伸 ±amp(px),
// 正弦周期、相位逐格变化 → 波浪感。锚底用 UV.y(瓦片局部坐标,origin 无关)保证与下方水体无缝。
// 水体层(WaterLayer)不挂此 shader,不拉伸。参数沿用 GameParameters.water_sway_amp / water_sway_speed。

uniform float amp = 3.0;
uniform float speed = 0.8;

void vertex() {
	vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	vec2 cell = floor(world / 64.0);
	// 相位逐格错开(1.7/2.3 非整数频率),相邻格起伏不同步 → 波浪
	float phase = sin(TIME * speed + cell.x * 1.7 + cell.y * 2.3);
	// 锚底:UV.y=1(格底)offset=0,UV.y=0(格顶)±amp
	float offset = amp * phase * (1.0 - UV.y);
	VERTEX.y += offset;
}
