shader_type canvas_item;

uniform sampler2D screen_tex : filter_nearest, repeat_disable;

uniform bool barrel_enabled = true;
uniform float barrel_strength : hint_range(0.0, 0.5) = 0.3;
// 窗口尺寸 / 世界视口尺寸，把窗口 uv 映射到世界纹理的中心裁剪区。
uniform vec2 crop_scale = vec2(1.0);
uniform float desat : hint_range(0.0, 1.0) = 0.0;
// 受击红闪:0=无,1=纯红罩。由 PostProcess.flash_hit() 置峰后每帧衰减。
uniform float hit_red : hint_range(0.0, 1.0) = 0.0;
// 残血红屏:0=无(血量高于阈值),1=最低血。只在**屏幕边缘**压暗+去饱和+暗红,中心保持干净(不挡索敌/准星)。
uniform float low_hp : hint_range(0.0, 1.0) = 0.0;
uniform float low_hp_pulse = 0.0;   // 心跳相位(弧度),PostProcess 里按血量加速
// ── 个人钟·第一阶段(时间玩法)三个全屏效果 ──
uniform float rewind_film : hint_range(0.0, 1.0) = 0.0;   // 回溯底片化覆盖度(0→1:由内而外铺满)
uniform float loan_depth : hint_range(0.0, 1.0) = 0.0;    // 贷款深度:变亮 + 红蓝色差
uniform float haste_dim : hint_range(0.0, 1.0) = 0.0;     // 加速压暗覆盖度(0→1:由内而外铺满)
uniform vec2 viewport_size = vec2(1920.0, 1440.0);        // ★ 仅供运行时覆盖的**兜底默认值**:它写的是**窗口**尺寸,不是世界视口(2208×1728)。真值由 `post_process.gd:84` 每帧 `set_shader_parameter("viewport_size", Vector2(world_viewport.size))` 写入;本默认值只在"没人设过"时生效。用途:`:64` 色差偏移的分母。
uniform float loan_aberration = 5.0;                      // 色差偏移上限(像素)

// ── 天空 + 光照(纯渲染层)──
// ★ 不同时段**不是同一套阴影换角度**,而是三套权重混合(由 PostProcess 按高度角算):
//   · 斜投影影 cast_*:只属于**有太阳**的时段。正午几乎为零(只剩台沿下一条接触影),
//     晨昏最长。夜里 cast_strength = 0 —— 没有太阳就没有方向影。
//   · 整体压暗 dim:夜里主要靠它(没有太阳 ⇒ 全场暗),
//   · 迎光边 rim:正午朝上(顶边)、晨昏朝太阳侧、夜里是月光(冷、弱)。
//   暗部颜色 cast_tint 也按时段给:正午中性冷灰、晨昏冷紫(与暖光互补)、夜里几乎不参与。
//
// ★★ 天空由本 shader 合成,不用清屏色:世界视口是 transparent_bg,空气的 alpha = 0。
uniform bool sun_on = false;
uniform vec2 sun_dir = vec2(0.45, -0.89);   // 指向太阳的单位向量(屏幕空间,y 向下)
// 环境光**颜色**(= 强度 × 色相):实体内容统一乘它,三通道恒 ≤ 1。
// ★ 用 vec3 而不是标量:环境光本来就该带颜色(黄昏偏暖、夜里偏蓝),见 PostProcess._push_sun。
uniform vec3 ambient_color = vec3(1.0);
// 环境光**色相**(归一化到最大通道 1,只含颜色不含强度)与"色相拉拢权重"。
// ★ 为什么需要:纯乘法只能压低通道 —— 蓝色砖在暖光下乘完还是蓝灰,而天空是暖橙,
//   于是"地形压暗和天色对不上"。按权重把颜色拉向 light_hue 并保持亮度,才能真的变暖。
uniform vec3 ambient_hue = vec3(1.0);
uniform float amb_hue_mix : hint_range(0.0, 1.0) = 0.4;
uniform vec3 sky_top = vec3(0.69, 0.90, 0.96);      // 天空(上):高处
uniform vec3 sky_bottom = vec3(0.69, 0.90, 0.96);   // 天空(下):地平线附近
// ★★ 垂直渐变:真实日落是"地平线橙、高处仍蓝"。整片天空染成一个色 = 整屏变色(实测"太夸张")。
uniform float sky_curve = 0.10;      // 横带弯曲量:0 = 纯横线,越大越弯(仍是横带,不是圆)
// 屏幕空间压暗幅度(大气深度):0 = 关闭。★ 别调大 —— 超过 0.08 就会读成滤镜而不是深度。
uniform float sky_band_pow = 1.7;   // 半径幂:>1 = 上疏下密
// ★ 像素风:把渐变**量化成有限条带**,不做连续插值(连续插值一缩小就是"糊")。
uniform float cast_strength : hint_range(0.0, 1.0) = 0.5;  // 斜投影影浓度(无太阳时段 = 0)
uniform float cast_steps = 4.0;            // 影长 = steps × cast_step_px
uniform float cast_step_px = 2.0;          // 单步长度(世界像素)
uniform vec3 cast_tint = vec3(0.74, 0.81, 0.93);   // 暗部色(相乘):按时段给,不是恒定蓝
uniform float sun_warm : hint_range(0.0, 1.0) = 0.0;       // 受光侧暖色(晨昏才有)
// ★ 暖色 tint 的三通道必须**都 ≤ 1**:任何 >1 的乘数都会把砖的某个通道推过原值 ⇒ 看起来在发光。
uniform vec3 sun_warm_tint = vec3(1.0, 0.93, 0.82);
uniform float sun_debug : hint_range(0.0, 1.0) = 0.0;      // 1 = 输出遮挡掩码,调试用
// 影子深浅:紧贴遮挡体的一侧 = 1(最深),最远一侧衰减到这个比例。别调到 0(那就没边了)。
uniform float shadow_far : hint_range(0.0, 1.0) = 0.32;   // 影子远端残留(数值在 lighting_params.tres)
// 环境地板:影子里最暗的那部分不低于它(夜里低、白天高)。
// ★ 纯乘性模型里最暗 = ambient × (1-cast) × …,夜里会压到接近 0(用户:一切都黑)。
//   地板把 [0,1] 的 lit 重映射到 [floor, 1] —— 仍然 ≤ 1,不破坏「只压不抬」。
uniform float amb_floor : hint_range(0.0, 0.9) = 0.3;
// ★ 实心判定阈值:必须**只在这里定义一次**。曾经着色判定用 0.90、挡光判定仍用 0.5,
//   结果半透明的东西(子弹曳尾 alpha 0.55、预瞄线 0.6)照样挡光投假影。
//   半透明不该是遮挡体:水、曳尾、预瞄线都在这条线以下。
const float SOLID_A = 0.90;
const int MAX_SUN_STEPS = 32;

// 遮挡采样用**线性过滤**的同一张世界纹理:点采样会让斜射线从两个实心texel之间"漏"过去,
// 影子里出现一片虚线状的破洞(实测)。线性过滤把边界摊成一个 texel 的过渡,配合 step() 仍是硬边。
uniform sampler2D occ_tex : filter_linear, repeat_disable;

// ── 发光通道 ── 独立 GlowViewport(同尺寸、透明底、相机同步)。
// ★ 必须在这里叠(**整个光照之后**):世界里的一切都被乘过 ambient,发光体若画在世界里
//   会被一起压暗 —— 那就不是"夜里更亮",而是"夜里跟着变暗",与需求正好相反。
// ★ 采样用**最近邻**:遮罩是标记图,插值会把相邻像素混出不存在的强度。
uniform sampler2D glow_tex : filter_nearest, repeat_disable;
uniform float glow_gain = 0.0;   // 0 = 没有发光通道(自动发现失败时),整段跳过

// ── UI 通道 ── 第三只 SubViewport(同尺寸、透明底、相机同步),里面只放"不该吃光照"的辅助层:
//   换弹读条、预瞄线。它们在世界里会被乘 ambient、被影子压暗,但又不是发光体(有暗色底环),
//   所以既不能留在世界、也不能塞进加色的发光通道 —— 必须单独一条**正常混合**的通道。
uniform sampler2D ui_tex : filter_nearest, repeat_disable;
uniform float ui_gain = 0.0;

// ── 地形掩码 ── 烘好的数据纹理(不是视图通道):r > 0.5 = 这个像素是地形。
// ★ 地形受光必须只作用在地形上,否则精灵会被地形那套"向上找顶面"的算法误伤(实测 10% 变暗)。
uniform sampler2D terrain_mask : filter_nearest, repeat_disable;   // 地形分类:最近邻
// 同一张掩码再绑一个**线性**采样器:水体深度/离岸要的是平滑场,不是逐格块。
uniform sampler2D water_tex : filter_linear, repeat_disable;   // ★ 最近邻:逐格数据不该被插值糊
uniform float mask_gain = 0.0;
uniform vec2 mask_grid = vec2(1.0);     // 掩码的格数(cols, rows)
// 世界坐标 → 格坐标要用相机的原点与缩放,由 PostProcess 每帧推。
uniform vec2 cam_origin = vec2(0.0);
uniform float cam_zoom = 1.0;
const float TILE_PX = 64.0;             // 世界格边长(像素)

// ── 地形受光参数 ── 数值来自 lighting_params.tres(不在 .gd 里写死)。
uniform float terrain_gain : hint_range(0.0, 0.8) = 0.25;
uniform float terrain_depth_px = 48.0;
// 地形受光的色阶数(像素化):0/1 = 关闭。★ 量化的是**深度比值**,不是乘完 gain 的结果 ——
// gain 只有 0.06,量化结果的话 3 档只差 4/255,肉眼看不出来。
uniform float terrain_steps : hint_range(0.0, 6.0) = 4.0;
// 地形受光抖动(0 = 硬色阶;1 = 满强度 Bayer)。锚世界纹理坐标,相机移动时图案跟着墙走。
uniform float terrain_dither : hint_range(0.0, 1.0) = 1.0;
uniform float dither_px = 2.0;
const float TERRAIN_STEP_PX = 6.0;   // 步长(世界像素):6×8 = 48px 覆盖深度
// 2×2 Bayer:值 {0, 0.5, 0.75, 0.25}(经典矩阵 /4)。
// ★ 顺序抖动会把平坦区打散成棋盘;而精灵只有 48px,不打散又会切出"等高线"。
//   所以默认 `form_steps = 1`(精灵不量化),这函数留给地形/以后想开的人。
float _bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}

// 该点是不是实体(alpha 判定)。越界一律当空气(不知道就当作挡不住)。
float _occ(vec2 suv) {
	if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
		return 0.0;
	}
	return texture(occ_tex, suv).a;
}

// ── 地形受光:**三向探测**求朝向,再按 NdotL 压暗 ──
// ★ 为什么不是"只向上找顶面":那只给出上/下,墙的左右脸完全没有区别,
//   太阳从左边还是右边来对建筑毫无影响 ⇒ 用户:建筑还是没有光影效果。
// ★ 做法:从当前实心像素向上/左/右各走一小段,哪一侧先撞到空气,就说明表面朝那一侧。
//   三个方向的距离合成一个近似外法线,再和太阳方向做点积。
//   成本:3 × 8 步 ≈ 24 次 alpha 采样(只在实心像素上做)。
float _march_steps(vec2 suv, vec2 dir, float step_uv) {
	for (int i = 0; i < 8; i++) {
		vec2 q = suv + dir * step_uv;
		if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0 || _occ(q) < SOLID_A) {
			return float(i);
		}
		suv = q;
	}
	return 8.0;
}

float _terrain_lit(vec2 suv) {
	if (_occ(suv) < SOLID_A) {
		return 1.0;   // 空气:不参与(天空走另一条分支)
	}
	// 地形掩码:只有"真的是地形"才做受光,否则精灵会被误伤(它有自己的形体光)。
	float mat_gain_mul = 1.0;
	if (mask_gain > 0.5) {
		vec2 wp = cam_origin + (suv * viewport_size - viewport_size * 0.5) / max(cam_zoom, 0.0001);
		vec2 g = floor(wp / TILE_PX);
		vec2 muv = (mod(g, mask_grid) + 0.5) / mask_grid;
		vec4 m = texture(terrain_mask, muv);
		if (m.r < 0.5) {
			return 1.0;
		}
		// 水格(m.g=5):不参与地形受光,走 _water_shade 的深度/岸边处理。
		if (m.g * 255.0 > 4.5) {
			return 1.0;
		}
		// G 通道 = 材质类:不同材质对同一束光的响应不同。
		// 金属对比更强(硬、反光),树叶最软(透光、不该有硬阴影),木头居中。
		float mid = m.g * 255.0;
		if (mid > 0.5 && mid < 1.5) {
			mat_gain_mul = 1.6;      // metal
		} else if (mid > 1.5 && mid < 2.5) {
			mat_gain_mul = 0.45;     // foliage
		} else if (mid > 2.5 && mid < 3.5) {
			mat_gain_mul = 0.75;     // wood
		}
	}
	float su = TERRAIN_STEP_PX / max(viewport_size.y, 1.0);
	float sv = TERRAIN_STEP_PX / max(viewport_size.x, 1.0);
	float du = _march_steps(suv, vec2(0.0, -1.0), su);   // 向上(uv.y 向下,所以 -1)
	float dl = _march_steps(suv, vec2(-1.0, 0.0), sv);
	float dr = _march_steps(suv, vec2( 1.0, 0.0), sv);
	// 哪个方向离空气越近,法线越偏向那边(1 - d/8)。
	vec2 n = vec2(0.0, -1.0) * max(0.0, 1.0 - du / 8.0)
			+ vec2(-1.0, 0.0) * max(0.0, 1.0 - dl / 8.0)
			+ vec2( 1.0, 0.0) * max(0.0, 1.0 - dr / 8.0);
	if (length(n) < 0.001) {
		n = vec2(0.0, -1.0);
	}
	n = normalize(n);
	// 太阳方向在 uv 空间(y 向下)与 sun_dir 同向。
	float ndl = clamp(dot(n, normalize(sun_dir)), 0.0, 1.0);
	float t = 1.0 - ndl;
	if (terrain_steps >= 1.5) {
		if (terrain_dither > 0.001) {
			float b = _bayer2(suv * viewport_size / max(dither_px, 1.0)) - 0.5;
			t = clamp(t + b * terrain_dither / terrain_steps, 0.0, 1.0);
		}
		t = floor(t * terrain_steps + 0.5) / terrain_steps;
	}
	return 1.0 - terrain_gain * mat_gain_mul * t;
}


// ── 水体着色:深度色阶 + 岸边泡沫 ──
// ★ 数据来自地形掩码的 B/A 通道(水深 / 离岸),由 PostProcess 烘图时算好。
// ★ 深水做**乘性**压暗偏蓝(不破「世界层乘性链」);岸边泡沫是**加算高光**,
//   属于已登记的例外(见 docs/eng/render.md「准确的不变量」)。
vec3 _water_shade(vec2 suv, vec3 col) {
	if (mask_gain < 0.5) {
		return col;
	}
	vec2 wp = cam_origin + (suv * viewport_size - viewport_size * 0.5) / max(cam_zoom, 0.0001);
	vec2 g = floor(wp / TILE_PX);
	vec2 muv = (mod(g, mask_grid) + 0.5) / mask_grid;
	vec4 m = texture(terrain_mask, muv);
	vec4 wdat = texture(water_tex, muv);   // 线性采样 ⇒ 深度是连续场
	if (m.r < 0.5 || m.g * 255.0 < 4.5) {
		return col;
	}
	// ★ 只在"水面上方是空气"的格子,画一条 0.1 格宽的上端亮线。
	//   内部水格、被墙压住的水面都不出现 —— 不是沿岸一圈发亮。
	if (m.b > 0.5) {
		float fy = fract(wp.y / TILE_PX);   // 0 = 格子顶边
		// ★ 水线**上下起伏**:逐格相位 + 正弦,复刻原来 WaterSurfaceBatch 的顶点位移
		//   (lift = sin(TIME*speed + phase) * amp,底边锚定、顶边浮动)。
		//   1 世界px = 1/64 格;amp 取 2 世界px ⇒ 0.031。
		float phase = floor(wp.x / TILE_PX) * 1.7 + floor(wp.y / TILE_PX) * 2.3;
		float lift = sin(TIME * 1.6 + phase) * 0.031;
		if (fy < 0.15 + lift) {
			col += vec3(0.28, 0.40, 0.45) * 0.35;
		}
	}
	return col;
}

void fragment() {
	vec2 uv = SCREEN_UV;

	if (barrel_enabled) {
		vec2 centered = uv - 0.5;
		float r = length(centered);
		float r_new = r * (1.0 + barrel_strength * r * r);
		uv = centered * (r_new / max(r, 0.0001)) + 0.5;
	}

	// 世界视口比窗口大，采样范围超出 [0,1] 时取到的是窗口外真实渲染的内容，
	// 因此去掉 clamp，鱼眼边缘不再有黑边。
	uv = (uv - 0.5) * crop_scale + 0.5;

	vec4 world = texture(screen_tex, uv);
	// ★★ 合成口径:世界视口是 transparent_bg,而 Godot 画到透明目标的混合是
	//   dst.rgb = src.rgb*src.a + dst.rgb*(1-src.a) ⇒ world.rgb **已是预乘**(rgb 里带了 alpha)。
	//   所以正确合成 = sky*(1-a) + world.rgb,不是 mix(sky, world.rgb, a)。
	//   ★ 用错口径会把所有**半透明**的东西算暗:预瞄线(alpha 0.6)、水、发光都会被压掉一大截。
	// ★★ 天空色带:**略微弯曲的横带**,不是同心圆。
	//   用半径算会读成"一个圆"(用户:不能是圆)。这里只给纵坐标加一点随 x 的抛物线偏移,
	//   带子像地平线那样轻轻弯一下,整体仍是横条。
	//   量化前对纵坐标做幂压缩(pow>1)⇒ 上方带厚、下方带薄 = 上疏下密。
	float curve = sky_curve * (SCREEN_UV.x - 0.5) * (SCREEN_UV.x - 0.5) * 4.0;
	float rn = clamp(SCREEN_UV.y + curve, 0.0, 1.0);
	float gy = pow(rn, sky_band_pow);   // 只保留非线性坡度,不做量化 ⇒ 平滑渐变
	vec3 sky = mix(sky_top, sky_bottom, gy);
	// ── 地形受光 ── 墙的竖向体积感来自"离顶面多远",不是"在屏幕多低"。
	// ★ 已删除旧的屏幕空间压暗(atmo_depth):它按屏幕高度压暗,同一面墙在屏幕上方就亮、
	//   移到下方就暗 —— 那是滤镜不是光照,和"一切都很黑"是同一类问题。
	vec3 lit_world = world.rgb * ambient_color * _terrain_lit(uv);
	lit_world = _water_shade(uv, lit_world);
	// 色相拉拢:保持亮度不变,只把色调拉向当前光源色(黄昏暖、夜里蓝)。
	// ★ 权重必须随"光源偏离白色多远"缩放:正午光源是白的,hue_w 就是同亮度的灰,
	//   无条件混 50% 等于把饱和度砍半 —— 整屏发灰(用户:现在好灰啊)。
	float tint_dev = clamp(length(ambient_hue - vec3(1.0)) * 2.0, 0.0, 1.0);
	float lum_w = dot(lit_world, vec3(0.299, 0.587, 0.114));
	vec3 hue_w = ambient_hue * lum_w;
	lit_world = mix(lit_world, hue_w, amb_hue_mix * tint_dev);
	COLOR = vec4(sky * (1.0 - world.a) + lit_world, 1.0);
	// ── 光照:环境光(全局) + 斜投影影(按时段) 两项;方向性的体积感交给逐精灵的 form_light ──
	// ★ 薄 z 的斜投影影:先沿光的方向**穿出自己的实体**(那段是自己,不算遮挡),出体之后
	//   再撞到的实体才是"挡在我和太阳之间的东西" ⇒ 我在它影子里。
	//   少了"穿出自己"这一步,每面墙都会撞到自己 ⇒ 整面墙均匀变暗(实测)。
	if (sun_on) {
		vec2 vp = max(viewport_size, vec2(1.0));
		vec2 base = floor(uv * vp) + vec2(0.5);
		float solid = step(SOLID_A, _occ(uv));

		// ① 斜投影影:正午 cast_strength≈0 ⇒ 这一项自动消失(不画斜影),夜里同样为 0。
		// ★ 影子有**深浅**:紧贴遮挡体那一侧最深,越往外越淡(线性衰减到 shadow_far)。
		//   一刀切的等深色带看着像贴图描边,不像光被挡住。
		float shadow = 0.0;
		if (cast_strength > 0.001) {
			vec2 p = base;
			float hit_step = -1.0;   // 第几步撞到遮挡体(-1 = 没撞到 ⇒ 受光)
			bool exited = solid < 0.5;
			// 穿出自己最多走 cast_steps 步:深埋内部、一时穿不出去的像素按"受光"处理。
			// ★ 不设这个上限,内部像素穿出的距离各不相同 ⇒ 墙面上出现斜向条纹(实测)。
			float exit_budget = min(cast_steps, 6.0);
			if (solid > 0.5) {
				for (int i = 1; i <= MAX_SUN_STEPS; i++) {
					if (float(i) > exit_budget) {
						break;
					}
					p += sun_dir * cast_step_px;
					if (_occ(p / vp) < SOLID_A) {
						exited = true;
						break;
					}
				}
			}
			if (exited) {
				for (int j = 1; j <= MAX_SUN_STEPS; j++) {
					if (float(j) > cast_steps) {
						break;
					}
					p += sun_dir * cast_step_px;
					if (hit_step < 0.0 && _occ(p / vp) >= SOLID_A) {
						hit_step = float(j);   // 只记**最近**那一次,用来定深浅
					}
				}
			}
			if (hit_step > 0.0) {
				float t = clamp((hit_step - 1.0) / max(cast_steps - 1.0, 1.0), 0.0, 1.0);
				shadow = cast_strength * mix(1.0, shadow_far, t);
			}
		}
		// ★ 影子同时落在**实体和空气**上:侧视里台沿下方的暗带是玩家读"光从上面来"的主要线索,
		//   只画在实体上会导致**几乎看不见影子**(实测)。真正让它显假的是影子太长、
		//   边缘和后头平行 —— 靠"短"和"贴着遮挡体"解决,而不是靠砍掉它。

		// ── 亮度不变量:下面每一步都只在 [0,1] 之间做**乘法**,没有加法 ──
		// 于是最终 COLOR.rgb ≤ ambient × 贴图原值(逐通道),结构上不可能"比环境光更亮" ⇒ 永不发光。
		vec3 lit = vec3(1.0);
		lit *= mix(cast_tint, vec3(1.0), 1.0 - shadow);         // ≤ 1
		lit *= mix(vec3(1.0), sun_warm_tint, sun_warm * (1.0 - shadow) * solid);   // tint ≤ 1
		// ★ 去掉"整面背光压暗":它把墙压成一片均匀灰块(用户:灰蒙蒙)。
		//   光的来向交给**影子**表达就够了,不靠给整面刷灰。
		lit = min(lit, vec3(1.0));
		// 环境地板:最暗处抬到 amb_floor,最亮处仍是 1.0。
	lit = vec3(amb_floor) + (1.0 - amb_floor) * lit;
	COLOR.rgb *= lit;
		// 调试:白 = 在影子里。
		if (sun_debug > 0.5) {
			COLOR.rgb = vec3(shadow > 0.5 ? 1.0 : 0.0);
		}
	}
	// ── 发光叠加:在 ambient / 影子之后加,所以发光体既不被压暗也不吃影 ──
	// glow 通道是 transparent_bg,画进去的颜色按 Godot 的混合已是**预乘**(rgb 带了 alpha),
	// 直接加即可;强度(遮罩的 A)已经乘在 rgb 里。
	if (glow_gain > 0.5) {
		vec4 gl = texture(glow_tex, uv);
		COLOR.rgb += gl.rgb;
	}
	// ── UI 叠加:正常混合(不是加色)。★ 放在最后:UI 既不进 ambient、也不吃影子。
	//   用 mix 而不是 += :读条环有暗色底,加色会让它变亮。
	if (ui_gain > 0.5) {
		vec4 ui = texture(ui_tex, uv);
		COLOR.rgb = mix(COLOR.rgb, ui.rgb, ui.a);
	}
	if (hit_red > 0.0) {
		// 画面微红一瞬间:向红色偏移(保留暗部细节,不做纯色覆盖);0.6 = 可感知但不糊画面
		COLOR.rgb = mix(COLOR.rgb, vec3(0.85, 0.05, 0.05), hit_red * 0.6);
	}
	if (desat > 0.0) {
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		COLOR.rgb = mix(COLOR.rgb, vec3(g), desat);
	}
	// ── 时间玩法视效:覆盖度模型 ──
	// cov=覆盖度(0→1)。逐像素半径 t(中心0→边缘1)与 cov 比较:cov 超过 t 的区域先被覆盖,
	// 过渡由内而外推进;cov=1 时全图覆盖 —— **最终效果是全图统一的**(底特律变人导航模式那种切换感)。
	float rt = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.75, 0.0, 1.0);

	// 回溯:全图统一底片色调(反色 + 轻去饱和)
	if (rewind_film > 0.0) {
		float amt = smoothstep(0.0, 0.28, rewind_film - rt);
		vec3 inv = vec3(1.0) - COLOR.rgb;
		float g = dot(inv, vec3(0.299, 0.587, 0.114));
		vec3 film = mix(inv, vec3(g), 0.25);
		COLOR.rgb = mix(COLOR.rgb, film, amt);
	}
	// 加速:全图统一压暗 + 冷色偏移(角色靠加色高亮"跳"出来 —— 见 TimeGlow)
	// ★ 0.42 → 0.55:压得太黑时用户会读成"一切都被调暗了、谁都没被高亮",留一点环境可读性。
	if (haste_dim > 0.0) {
		float amt = smoothstep(0.0, 0.28, haste_dim - rt);
		vec3 target = COLOR.rgb * 0.55 + vec3(0.02, 0.035, 0.07);
		COLOR.rgb = mix(COLOR.rgb, target, amt);
	}
	// 贷款:整体变亮 + 红蓝色影分离(深度越深越明显)
	if (loan_depth > 0.0) {
		float off = loan_depth * loan_aberration / max(viewport_size.x, 1.0);
		vec3 base = texture(screen_tex, uv).rgb;
		float cr = texture(screen_tex, uv + vec2(off, 0.0)).r;
		float cb = texture(screen_tex, uv - vec2(off, 0.0)).b;
		COLOR.rgb = mix(COLOR.rgb, vec3(cr, base.g, cb), 0.9);
		COLOR.rgb += vec3(0.10, 0.095, 0.12) * loan_depth;
	}
	// ── 残血红屏:边缘压暗 + 去饱和 + 暗红,中心(edge=0)完全不动 ──
	// 不是纯红罩:保留边缘明暗关系(纯色覆盖会把地形细节糊成一片),强度封顶 0.55,心跳只做 ±20% 呼吸。
	if (low_hp > 0.0) {
		float edge_r = clamp(distance(SCREEN_UV, vec2(0.5)) / 0.78, 0.0, 1.0);
		float edge = smoothstep(0.42, 0.95, edge_r);
		float pulse = 0.80 + 0.20 * sin(low_hp_pulse);
		float amt = low_hp * edge * pulse;
		float g = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
		vec3 danger = vec3(g * 0.55 + 0.10, g * 0.06, g * 0.06);
		COLOR.rgb = mix(COLOR.rgb, danger, amt * 0.55);
	}
}
