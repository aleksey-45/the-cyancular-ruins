shader_type canvas_item;
render_mode blend_premul_alpha;

// 每个子格保存对应的瓦片图层，地图边缘循环采样。
uniform sampler2D tile_index : filter_nearest, repeat_enable;
uniform sampler2DArray tiles : filter_nearest, repeat_disable;
uniform vec2  map_size   = vec2(150.0, 100.0);  // 地图宽高均以瓦片数表示。
uniform float view_w_cells = 26.6667;              // 应用畸变前，窗口宽度对应的瓦片数。
uniform float fisheye    = 0.85;
instance uniform vec2 view_center = vec2(0.5);          // 视野中心在整张地图中的相对位置。
instance uniform float rot_angle = 0.0;                // 以视野中心为原点的旋转角，单位为弧度。
uniform float breathe_amp = 0.012;              // 坐标缩放系数在 1 的两侧变化，最大偏差由该参数决定。
uniform float aberration = 0.020;
uniform float dim        = 0.60;                // 整幅画面的压暗程度。1 表示全黑。
uniform float vignette   = 0.30;
uniform float desat      = 0.20;                // 0 保留原色，1 显示灰度画面。
uniform float blur_radius = 4.0;               // 相邻模糊采样点的间距，单位为屏幕像素。


vec2 rot2(vec2 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}


vec4 bg_sample(vec2 cc, float strength) {
	vec2 c = rot2(cc, rot_angle);
	vec2 uv = view_center + c * (1.0 + strength * dot(c, c)) * view_w_cells / map_size;
	float layer = texture(tile_index, uv).r;
	vec2 tile_uv = fract(fract(uv) * map_size);
	vec4 texel = texture(tiles, vec3(tile_uv, layer));
	return vec4(texel.rgb * texel.a, texel.a);
}

// 画面边缘的红色和蓝色通道使用不同的采样坐标，模拟镜头色差。
vec4 bg_sample_ab(vec2 cc) {
	float ab = aberration * smoothstep(0.22, 0.60, length(cc));
	vec4 col = bg_sample(cc, fisheye);
	col.r = bg_sample(cc, fisheye * (1.0 + ab)).r;
	col.b = bg_sample(cc, fisheye * (1.0 - ab)).b;
	return col;
}


void fragment() {
	// 横纵坐标都以屏幕宽度为单位，使同一半径在画面上对应一个圆。
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);

	float r = length(cc);

	// 模糊使用 3×3 高斯卷积核。只有中央采样点计算各颜色通道的偏移，减小纹理采样开销。
	vec4 scene = bg_sample_ab(cc);
	if (blur_radius >= 0.5) {
		float step_uv = SCREEN_PIXEL_SIZE.x * blur_radius;
		scene *= 4.0;
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				if (x == 0 && y == 0) { continue; }
				float weight = float((2 - abs(x)) * (2 - abs(y)));
				scene += bg_sample(cc + vec2(float(x), float(y)) * step_uv, fisheye) * weight;
			}
		}
		scene /= 16.0;
	}

	vec3 col = scene.rgb * COLOR.rgb;
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	// 地图的透明部分透出背景，暗角与压暗作用于整幅画面。
	float shade = (1.0 - dim) * (1.0 - vignette * smoothstep(0.28, 0.66, r));
	COLOR = vec4(col * shade, 1.0 - (1.0 - scene.a) * shade);
}
