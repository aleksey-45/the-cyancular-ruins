shader_type canvas_item;

// 逐精灵的**形体光**。渲染策略由 `light_model` 决定(TAG 驱动):
//   0 = flat / 1 = ellipsoid / 2 = cylinder / 3 = sdf
//
// ★★ 必须用 `vertex()` 的 VERTEX 经 varying 传到 fragment:fragment 里的 `VERTEX` 是世界坐标,
//   直接拿它除以半尺寸会被 clamp 到 ±1,法线恒定 ⇒ 明暗完全消失(实测过)。
// ★★ fragment() **不允许 `return`**:写一个 return 会让整个材质编译失败,精灵静默降级成无光照。
// ★ 解析形状的法线是连续函数,不会像距离场那样留下宝石切面。

varying vec2 v_local;

uniform int light_model = 0;
uniform vec2 light_size = vec2(24.0, 24.0);
// 椭球中心(相对帧中心):由剪影质心拟合得到,不是帧中心。
uniform vec2 light_center = vec2(0.0);
uniform sampler2D normal_tex : filter_linear, repeat_disable;
uniform vec2 sun_dir = vec2(0.0, -1.0);
uniform float gain : hint_range(0.0, 1.0) = 0.45;
uniform float boost : hint_range(0.0, 0.5) = 0.15;
// 明暗色阶数(像素化):0/1 = 关闭(连续渐变),4 = 四档。
uniform float steps : hint_range(0.0, 6.0) = 4.0;
// 有序抖动强度(0 = 硬色阶;1 = 满强度 Bayer)。
uniform float dither : hint_range(0.0, 1.0) = 1.0;
// 抖动格边长(精灵本地像素)。★ 锚精灵本地坐标:锚屏幕的话相机一动图案会在物体上"爬"。
uniform float dither_px = 1.0;
// 鼓起系数:>1 = 法线更早转向侧面 ⇒ 球面感更强(1.0 = 按包围盒的原始椭球)。
// ★ 为什么需要:light_size 用的是整帧包围盒,身体只占其中一部分,法线实际只走了球面中间一段。
uniform float bulge : hint_range(0.5, 3.0) = 1.0;   // 1 本地像素 = 屏幕 2.5px(玩家 scale 2.5),更细的棋盘
// 4×4 Bayer(N 阶递归):16 个阈值。
// ★ 为什么不用 2×2:2×2 只有 4 个阈值,在平滑渐变上做散点会**成条纹状聚集**
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
	vec3 n;
	if (light_model == 1) {
		// ★ 按**半径**归一化,不是逐分量 clamp:
		//   逐分量 clamp 会让边缘/四角的 |p| > 1 ⇒ z 归零 ⇒ 法线全是纯侧面,背光侧整条变黑。
		//   归一化到球面上则法线始终连续,边缘只是"转向侧面"而不是"一拍到底"。
		vec2 p = (v_local - light_center) / max(light_size, vec2(1.0)) * bulge;
		float r = length(p);
		if (r > 1.0) {
			p /= r;
		}
		float z = sqrt(max(0.0, 1.0 - dot(p, p)));
		// ★ 边缘 z 下限 0.35(不是 0.02):完全侧向的法线会让背光边缘掉到最暗档,
		//   形成一圈生硬的黑边(用户:头顶变黑)。留住"朝向观察者"的分量,边缘才是渐变。
		n = normalize(vec3(p, max(z, 0.35)));
	} else if (light_model == 2) {
		vec2 p = clamp((v_local - light_center) / max(light_size, vec2(1.0)), -1.0, 1.0);
		float z = sqrt(max(0.0, 1.0 - p.y * p.y));
		n = normalize(vec3(p * 0.35, max(z, 0.02)));
	} else if (light_model == 3) {
		vec3 s = texture(normal_tex, UV).rgb * 2.0 - 1.0;
		n = normalize(vec3(s.xy, max(s.z, 0.05)));
	} else {
		n = vec3(0.0, 0.0, 1.0);
	}
	vec3 l = normalize(vec3(sun_dir.x, sun_dir.y, 1.0));
	float ndl = clamp(dot(n, l), 0.0, 1.0);
	// 明暗交界:纯 Lambert 在 48px 的小块上会被读成"整体均匀"。
	ndl = smoothstep(0.20, 0.80, ndl);
	if (steps >= 1.5) {
		// 整片抖动:Bayer 阈值在整个精灵上均匀散开 ⇒ 才是可见的棋盘格。
		if (dither > 0.001) {
			float b = _bayer4(v_local / max(dither_px, 1.0)) - 0.5;
			ndl = ndl + b * dither / steps;
		}
		// ★ 上钳 1.0:量化后仍 ≤1,不越过"只压不抬"的结构约束。
		ndl = clamp(floor(ndl * steps + 0.5) / steps, 0.0, 1.0);
	}
	// 先提亮(boost 给亮面留头部空间)、再只压背光面。
	COLOR.rgb *= (1.0 + boost) * mix(1.0 - gain, 1.0, ndl);
}
