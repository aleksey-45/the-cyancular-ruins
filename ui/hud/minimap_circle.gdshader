shader_type canvas_item;

// 圆形区域中央对应本地玩家的位置，圆外不输出像素。
// 地形纹理在两个方向上重复，越过地图边缘时可以看见对侧。
uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size    = vec2(1.0, 1.0);   // 地图横向和纵向的子格数。
uniform vec2  center_cell = vec2(0.0, 0.0);   // 以地图左上角为原点的玩家坐标，单位为子格。
uniform float px_per_cell = 7.0;              // 小地图上每个子格对应的像素宽度。
uniform float radius      = 140.0;            // 圆形小地图在画布上的半径，单位为像素。
uniform float ring        = 4.0;              // 描边从圆周向内覆盖的像素数。
// 中性灰描边在空地、水面和实心地形上都清晰可见。
uniform vec3  ring_color  = vec3(0.45, 0.46, 0.48);
uniform float ring_mix    = 0.85;             // 1 完全使用描边色，0 保留地图原色。

void fragment() {
	vec2 p = UV * (2.0 * radius) - vec2(radius);
	float d = length(p);
	if (d > radius) {
		discard;
	}
	// 偏移半个子格，使子格坐标与纹素中心对齐。
	vec2 uv = (center_cell + p / px_per_cell + 0.5) / map_size;
	COLOR = texture(map_tex, uv);
	if (d > radius - ring) {
		COLOR.rgb = mix(COLOR.rgb, ring_color, ring_mix);
	}
}
