shader_type canvas_item;

// 主菜单背景:把一张地图(新版 factory,`maps/newfactory.cyrm`)的简略图铺满全屏,
// 叠一层 **鱼眼镜头** 透视 + 缓慢漂移 + 边缘径向色差。
//
// ★ 为什么是 shader 而不是"缩略图缩放":
//   鱼眼是**逐像素的径向重映射**,不是整体缩放;漂移必须逐帧跟时间走。两者都要求
//   在采样阶段改 uv,纹理本身不动。
// ★ 环面自洽:本作的世界本来就是环面(左右/上下无缝回绕),所以采样越界时用
//   `repeat_enable` **绕到地图另一头**正好与世界观一致 —— 也不会在边缘拉出条纹。
// ★ 本 shader **只服务主菜单背景**,与对局内的 `post_process.gdshader` 无关:
//   改这里不会碰任何一局游戏的一个像素。
//
// 各量的取值与理由(都是**看实图调的**,记录在这里免得下次再猜):
//   · `fisheye = 0.85` —— r' = r·(1+k·r²)。屏幕边缘(半屏宽 0.5 处)采样到的源半径约
//     放大到 1.11 倍,内容被压得更密 ⇒ 中心的方块相对"鼓"出来;横贯画面的长条地板在
//     上下两侧会**明显弯**(实图里就是靠它读出来的)。实测 0.40/0.55 在块状地形上读不太出来
//     (方块大小本就不一,没有参照就看不出来),0.85 才有"一眼是鱼眼"的效果;再大
//     (≥1.2)四角绕到地图另一头太多、方块开始糊,而且会让人眼晕。
//   · `view_w_cells = 150` —— 横向铺满整张图(150 格)。再放大(如 90)会只看到地图一角,
//     版式上"这是一张地图"这条线索就弱了。★ 整张图铺满一个 4:3 屏 ⇒ 上下必然略微越界,
//     靠 `repeat_enable` 绕回(见上,世界观上是自洽的)。
//   · `drift_amp = 0.06` —— 李萨如 `(sin(t·0.07), cos(t·0.05))·0.06`(半屏宽为单位)。
//     两个频率互质 ⇒ 看不出循环;0.06 在半屏宽上 ≈ 9 格 ≈ 115px,是"一直在慢慢晃"而不是"在跑"。
//   · `aberration = 0.02` —— 红/蓝通道各取 ±2% 的鱼眼强度 ⇒ 越靠边分色越明显(边缘约 5px)。
//     这是"奇怪的镜头"那一点非常规;选它是因为它**不引入任何新色值**(纯通道偏移)。
//   · `dim / desat / vignette` —— 让背景**在文字后面退下去**:整体压到 0.5、去饱和三成、
//     再按半径往边缘继续压 0.45(起点 0.28 ⇒ 中央大片区域基本不压,标题与按钮底下的
//     背景是均匀的)。标题/副信息/按钮文字的可读性因此不低于旧的纯色压暗罩。
//   · `breathe_amp = 0.012` —— 整幅轻微胀缩,让静止时也有"活着"的感觉(≈1.2%)。

uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size   = vec2(150.0, 100.0);  // 地图格数 (cols, rows)
uniform float view_w_cells = 150.0;             // 屏幕**横向**覆盖多少格(整张图宽 150)
uniform float fisheye    = 0.85;                // 径向重映射强度 r' = r·(1 + k·r²)
uniform float drift_amp  = 0.06;                // 漂移幅度(半屏宽为单位)
uniform float breathe_amp = 0.012;              // 呼吸缩放幅度(整幅轻微胀缩)
uniform float aberration = 0.020;               // 边缘径向色差(纯粹是"怪镜头"感)
uniform float dim        = 0.50;                // 整体压暗
uniform float vignette   = 0.45;                // 边缘再压暗
uniform float desat      = 0.30;                // 去饱和(往亮度混):背景不该比 UI 抢眼


// cc:相对屏幕中心的坐标(以**半屏宽**归一 —— x∈[-0.5,0.5],y 已按宽高比折算,
//     故 cc 上的圆在屏幕上也是圆);drift:漂移偏移(同单位);strength:鱼眼强度。
// 返回该像素应采样的纹理 uv(越界由 repeat_enable 绕回)。
vec2 menu_sample_uv(vec2 cc, vec2 drift, float strength) {
	float r = length(cc);
	float rs = r * (1.0 + strength * r * r);
	vec2 dir = cc / max(r, 0.00001);
	vec2 c2 = dir * rs + drift;                       // 鱼眼 + 漂移
	vec2 cell = map_size * 0.5 + c2 * view_w_cells;   // 半屏宽单位 → 格坐标
	return cell / map_size;
}


void fragment() {
	// 宽/高(>1)。窗口 1920×1440 时 ≈ 1.333。
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);      // 呼吸:整幅轻微胀缩

	float r = length(cc);
	vec2 drift = vec2(sin(TIME * 0.07), cos(TIME * 0.05)) * drift_amp;
	float edge = smoothstep(0.22, 0.60, r);

	// 三个颜色通道各取略微不同的鱼眼强度 ⇒ 边缘出现径向色差(越靠边越明显)。
	float ab = aberration * edge;
	vec3 col;
	col.r = texture(map_tex, menu_sample_uv(cc, drift, fisheye * (1.0 + ab))).r;
	col.g = texture(map_tex, menu_sample_uv(cc, drift, fisheye)).g;
	col.b = texture(map_tex, menu_sample_uv(cc, drift, fisheye * (1.0 - ab))).b;

	col *= dim;                                        // 全局压暗
	// 去饱和:简略图里有亮青的水、绿的树叶、棕的箱子 —— 原色直接铺在标题后面会抢视线,
	// 往亮度混三成,保留"这是哪张图"的色相线索,同时让它安静下来。
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.28, 0.66, r));   // 边缘再压暗
	COLOR = vec4(col, 1.0);
}
