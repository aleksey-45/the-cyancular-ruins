shader_type canvas_item;
// 水面逐格上下起伏:每格瓦片以「底部」为锚(格内 y=64 → offset=0),顶部拉伸 ±amp(px),
// 正弦周期、相位逐格变化 → 波浪感。格内 y 用 fract(world.y/64) 算(真实位移;UV 是 atlas 坐标不能用)。
// 水面格在 WaterLayer 也铺了水体蓝底,拉伸露出的顶部缝隙被蓝底盖住 → 无缝。
// 水体层(WaterLayer)不挂此 shader,不拉伸。参数沿用 GameParameters.water_sway_amp / water_sway_speed。

uniform float amp = 3.0;
uniform float speed = 0.8;

void vertex() {
	vec2 world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	vec2 cell = floor(world / 64.0);
	// 相位逐格错开(1.7/2.3 非整数频率),相邻格起伏不同步 → 波浪
	float phase = sin(TIME * speed + cell.x * 1.7 + cell.y * 2.3);
	float local_y = fract(world.y / 64.0) * 64.0;   // 瓦片内 y:0=顶,64=底
	float offset = amp * phase * (1.0 - local_y / 64.0);  // 底部 offset=0(锚),顶部 ±amp
	VERTEX.y += offset;
}
