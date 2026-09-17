shader_type canvas_item;

// 圆形小地图的地形:以玩家所在格为中心采样地图贴图,圆外直接 discard。
// ★ 采样器开 repeat_enable:地图贴图正好是 cols×rows、四周无留白,于是 uv 越过 1.0
//   就是"绕到地图另一头" —— 环面回绕不需要铺 3×3 副本。
uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size    = vec2(1.0, 1.0);   // 格数 (cols, rows)
uniform vec2  center_cell = vec2(0.0, 0.0);   // 玩家所在格(canonical)
uniform float px_per_cell = 7.0;              // 每格多少屏幕像素
uniform float radius      = 140.0;            // 屏幕半径(像素)
uniform float ring        = 2.0;              // 圆内缘描边宽度

void fragment() {
	// 以圆心为原点的屏幕像素(V 轴向下,与 Godot 一致)
	vec2 p = UV * (2.0 * radius) - vec2(radius);
	float d = length(p);
	if (d > radius) {
		discard;
	}
	// +0.5:uv 按像素归一化,取格中心要半格偏移;越界由 repeat_enable 绕回
	vec2 uv = (center_cell + p / px_per_cell + 0.5) / map_size;
	COLOR = texture(map_tex, uv);
	if (d > radius - ring) {
		// 暗环:地图开阔区是浅灰蓝,不描边时圆形轮廓读不出来
		COLOR.rgb = mix(COLOR.rgb, vec3(0.05, 0.09, 0.13), 0.75);
	}
}
