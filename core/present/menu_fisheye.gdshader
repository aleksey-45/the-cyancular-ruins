shader_type canvas_item;

// 主菜单将 newfactory.cyrm 的场景图层绘制成一张背景纹理。
// 脚本移动并旋转视野。纹理采用重复采样，视野越过地图边缘时会显示地图另一侧。


uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size   = vec2(150.0, 100.0);  // 地图宽高均以瓦片数表示。
uniform float view_w_cells = 26.6667;              // 应用畸变前，窗口宽度对应的瓦片数。
uniform float fisheye    = 0.85;
uniform vec2  view_center = vec2(75.0, 50.0);   // 视野中心在地图中的位置，以瓦片为单位。
uniform float rot_angle  = 0.0;                 // 以视野中心为原点的旋转角，单位为弧度。
uniform float breathe_amp = 0.012;              // 坐标缩放系数在 1 的两侧变化，最大偏差由该参数决定。
uniform float aberration = 0.020;
uniform float dim        = 0.60;                // 整幅画面的压暗程度。1 表示全黑。
uniform float vignette   = 0.30;
uniform float desat      = 0.20;                // 0 保留原色，1 显示灰度画面。
uniform float blur_radius = 6.0;               // 相邻模糊采样点的间距，单位为屏幕像素。


vec2 rot2(vec2 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}


// 先旋转采样点并调整它到中心的距离，再将其映射到地图纹理。
vec2 menu_sample_uv(vec2 cc, float strength) {
	vec2 c = rot2(cc, rot_angle);
	float r = length(c);
	float rs = r * (1.0 + strength * r * r);
	vec2 dir = c / max(r, 0.00001);
	vec2 c2 = dir * rs;
	vec2 cell = view_center + c2 * view_w_cells;
	return cell / map_size;
}


vec3 bg_sample(vec2 cc) {
	return texture(map_tex, menu_sample_uv(cc, fisheye)).rgb;
}


// 画面边缘的红色和蓝色通道使用不同的采样坐标，模拟镜头色差。
vec3 bg_sample_ab(vec2 cc) {
	float ab = aberration * smoothstep(0.22, 0.60, length(cc));
	vec3 col;
	col.r = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 + ab))).r;
	col.g = texture(map_tex, menu_sample_uv(cc, fisheye)).g;
	col.b = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 - ab))).b;
	return col;
}


void fragment() {
	// 横纵坐标都以屏幕宽度为单位，使同一半径在画面上对应一个圆。
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);

	float r = length(cc);

	// 模糊使用 3×3 高斯卷积核。只有中央采样点计算各颜色通道的偏移，减小纹理采样开销。
	vec3 col;
	if (blur_radius < 0.5) {
		col = bg_sample_ab(cc);
	} else {
		vec2 sp = vec2(SCREEN_PIXEL_SIZE.x, SCREEN_PIXEL_SIZE.y / aspect) * blur_radius;
		col = bg_sample_ab(cc) * 4.0;
		col += bg_sample(cc + vec2(sp.x, 0.0)) * 2.0;
		col += bg_sample(cc + vec2(-sp.x, 0.0)) * 2.0;
		col += bg_sample(cc + vec2(0.0, sp.y)) * 2.0;
		col += bg_sample(cc + vec2(0.0, -sp.y)) * 2.0;
		col += bg_sample(cc + vec2(sp.x, sp.y));
		col += bg_sample(cc + vec2(-sp.x, sp.y));
		col += bg_sample(cc + vec2(sp.x, -sp.y));
		col += bg_sample(cc + vec2(-sp.x, -sp.y));
		col /= 16.0;
	}

	col = mix(col, vec3(0.0), dim);
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.28, 0.66, r));
	COLOR = vec4(col, 1.0);
}
