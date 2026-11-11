shader_type canvas_item;

// 逐精灵的形体光。渲染策略由 `light_model` 决定(TAG 驱动):
//   0 = flat / 1 = ellipsoid / 2 = cylinder / 3 = sdf / 4 = parts / 5 = guide(打光辅助图)
//
// ★★ 必须用 `vertex()` 的 VERTEX 经 varying 传到 fragment:fragment 里的 `VERTEX` 是世界坐标,
//   直接拿它除以半尺寸会被 clamp 到 ±1,法线恒定 ⇒ 明暗完全消失(实测过)。
// ★★ fragment() 不允许 `return`:写一个 return 会让整个材质编译失败,精灵静默降级成无光照。
// ★ 解析形状的法线是连续函数,不会像距离场那样留下宝石切面。

varying vec2 v_local;

uniform int light_model = 0;
uniform vec2 light_size = vec2(24.0, 24.0);
// 椭球中心(相对帧中心):由剪影质心拟合得到,不是帧中心。
uniform vec2 light_center = vec2(0.0);
uniform sampler2D normal_tex : filter_linear, repeat_disable;
// 分部模型(light_model=4):RG = 该像素在有"身体/手/腿"局部坐标里的归一化位置(0.5=部件中心)。
uniform sampler2D part_tex : filter_nearest, repeat_disable;
// 打光辅助图(light_model=5):RG = 同上,另加 B = 贴体 AO(A 通道是精灵不透明掩码)。
uniform sampler2D shade_tex : filter_nearest, repeat_disable;
// 朝向:flip_h 时 parts 分支的 UV 被镜像,法线 x 要跟着翻回屏幕空间,否则世界光方向跟着朝向镜像。
uniform float flip_x = 0.0;
// 分部光照的"立体度":<1 压平(更贴环境), >1 更鼓。只影响 parts / guide 模型。
uniform float part_flat : hint_range(0.0, 1.5) = 1.0;
// 贴体 AO 的压暗强度:guide 模型最后一次乘 (1 - ao * ao_strength)。
uniform float ao_strength : hint_range(0.0, 1.0) = 0.35;
uniform vec2 sun_dir = vec2(0.0, -1.0);
uniform float gain : hint_range(0.0, 1.0) = 0.45;
uniform float boost : hint_range(0.0, 0.5) = 0.15;
// 椭球圆度:0 = 按剪影拟合的椭圆;1 = 两轴取均值(正圆)。
uniform float shape_round : hint_range(0.0, 1.0) = 0.0;
// ndl 重映射窗口:下移 lo ⇒ 亮面更大;窗口越窄 ⇒ 明暗交界越硬。
uniform float edge_lo : hint_range(-0.5, 1.0) = 0.20;
uniform float edge_hi : hint_range(-0.5, 1.5) = 0.80;
// 明暗色阶数。★ 0/1 = 连续形体光:按美术像素块取整采样,块内同一亮度、块间连续渐变;
// ≥1.5 = 量化模式,配合 dither 做棋盘过渡。
uniform float steps : hint_range(0.0, 16.0) = 0.0;
// 有序抖动强度(0 = 硬色阶;1 = 满强度 Bayer)。只在 steps ≥ 1.5 时生效。
uniform float dither : hint_range(0.0, 1.0) = 1.0;
// 抖动格边长(精灵本地像素)。★ 锚精灵本地坐标:锚屏幕的话相机一动图案会在物体上"爬"。
uniform float dither_px = 1.0;
// 鼓起系数:>1 = 法线更早转向侧面 ⇒ 球面感更强(1.0 = 按包围盒的原始椭球)。
// ★ 为什么需要:light_size 用的是整帧包围盒,身体只占其中一部分,法线实际只走了球面中间一段。
uniform float bulge : hint_range(0.5, 3.0) = 1.0;   // 1 本地像素 = 屏幕 2px(玩家根 scale 2.0、cam_zoom 1.0),更细的棋盘
// 4×4 Bayer(N 阶递归):16 个阈值。
// ★ 为什么不用 2×2:2×2 只有 4 个阈值,在平滑渐变上做散点会成条纹状聚集
//   (用户实测:像"成条的斑点簇"而不是棋盘);4×4 的散点分布均匀得多。
float _bayer2(vec2 a) {
	a = floor(a);
	return fract(a.x * 0.5 + a.y * a.y * 0.75);
}
float _bayer4(vec2 a) {
	return _bayer2(a * 0.5) * 0.25 + _bayer2(a);
}

void vertex() {
	v_local = VERTEX;   // 本地坐标(以精灵中心为原点)
}

void fragment() {
	// ★ 像素契约:形体光先在美术像素栅格上取整,再算形状/明暗/抖动。sprite 本地 1 单位 = 1 美术像素,
	//   取整后一个美术像素内的屏幕像素共享同一亮度,亮度本身连续。
	vec2 lp = floor(v_local);
	vec3 n;
	float ao = 0.0;
	if (light_model == 1) {
		// ★ 按半径归一化,不是逐分量 clamp:
		//   逐分量 clamp 会让边缘/四角的 |p| > 1 ⇒ z 归零 ⇒ 法线全是纯侧面,背光侧整条变黑。
		//   归一化到球面上则法线始终连续,边缘只是"转向侧面"而不是"一拍到底"。
		vec2 size = mix(light_size, vec2((light_size.x + light_size.y) * 0.5), shape_round);
		vec2 p = (lp - light_center) / max(size, vec2(1.0)) * bulge;
		float r = length(p);
		if (r > 1.0) {
			p /= r;
		}
		float z = sqrt(max(0.0, 1.0 - dot(p, p)));
		// ★ 边缘 z 下限 0.35(不是 0.02):完全侧向的法线会让背光边缘掉到最暗档,
		//   形成一圈生硬的黑边(用户:头顶变黑)。留住"朝向观察者"的分量,边缘才是渐变。
		n = normalize(vec3(p, max(z, 0.35)));
	} else if (light_model == 2) {
		vec2 p = clamp((lp - light_center) / max(light_size, vec2(1.0)), -1.0, 1.0);
		float z = sqrt(max(0.0, 1.0 - p.y * p.y));
		n = normalize(vec3(p * 0.35, max(z, 0.02)));
	} else if (light_model == 3) {
		vec3 s = texture(normal_tex, UV).rgb * 2.0 - 1.0;
		n = normalize(vec3(s.xy, max(s.z, 0.05)));
	} else if (light_model == 4) {
		// 每一块(身体/左右手/左右腿)用它自己的局部坐标当球面,块与块之间互不干扰。
		vec2 pn = texture(part_tex, UV).rg * 2.0 - 1.0;
		pn.x *= 1.0 - 2.0 * flip_x;
		vec2 p4 = pn * part_flat;
		float r4 = length(p4);
		if (r4 > 1.0) {
			p4 /= r4;
		}
		float z4 = sqrt(max(0.0, 1.0 - dot(p4, p4)));
		n = normalize(vec3(p4, max(z4, 0.35)));
	} else if (light_model == 5) {
		vec4 sh = texture(shade_tex, UV);
		ao = sh.b;
		vec2 p5 = sh.rg * 2.0 - 1.0;
		p5.x *= 1.0 - 2.0 * flip_x;
		vec2 pn5 = p5 * part_flat;
		float r5 = length(pn5);
		if (r5 > 1.0) {
			pn5 /= r5;
		}
		float z5 = sqrt(max(0.0, 1.0 - dot(pn5, pn5)));
		n = normalize(vec3(pn5, max(z5, 0.35)));
	} else {
		n = vec3(0.0, 0.0, 1.0);
	}
	vec3 l = normalize(vec3(sun_dir.x, sun_dir.y, 1.0));
	float ndl = clamp(dot(n, l), 0.0, 1.0);
	// 明暗交界:纯 Lambert 在 48px 的小块上会被读成"整体均匀"。
	ndl = smoothstep(edge_lo, edge_hi, ndl);
	if (steps >= 1.5) {
		// 整片抖动:Bayer 阈值在整个精灵上均匀散开 ⇒ 才是可见的棋盘格。
		if (dither > 0.001) {
			float b = _bayer4(lp / max(dither_px, 1.0)) - 0.5;
			ndl = ndl + b * dither / steps;
		}
		// ★ 上钳 1.0:量化后仍 ≤1,不越过"只压不抬"的结构约束。
		ndl = clamp(floor(ndl * steps + 0.5) / steps, 0.0, 1.0);
	}
	// 先提亮(boost 给亮面留头部空间)、再只压背光面。
	COLOR.rgb *= (1.0 + boost) * mix(1.0 - gain, 1.0, ndl);
	COLOR.rgb *= 1.0 - ao * ao_strength;
}
