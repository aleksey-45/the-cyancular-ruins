shader_type canvas_item;

// 主菜单背景:把一张地图(新版 factory,`maps/newfactory.cyrm`)的**真实地形图**
// (由 `TerrainAtlas.bake_map_image` 用与 Level0 同一份图集烘出来 —— 砖是 structure.png
// 的砖、水是水、树叶是树叶)铺满全屏,叠一层 **鱼眼镜头** 透视 + 随机路径段的平移 +
// 同一段时间里的慢速旋转 + 边缘径向色差。
//
// ★ 为什么是 shader 而不是"缩略图缩放":
//   鱼眼是**逐像素的径向重映射**,不是整体缩放;平移/旋转必须逐帧跟着镜头走。两者都要求
//   在采样阶段改 uv,纹理本身不动。
// ★ 环面自洽:本作的世界本来就是环面(左右/上下无缝回绕),所以采样越界时用
//   `repeat_enable` **绕到地图另一头**正好与世界观一致 —— 镜头被推出图外时,
//   露出的也是这个世界本身,不会是空白边或拉伸条纹。
// ★ 本 shader **只服务主菜单背景**,与对局内的 `post_process.gdshader` 无关:
//   改这里不会碰任何一局游戏的一个像素。
//
// ── 镜头运动:两个量由**脚本每帧喂**(main_menu.gd)──────
//   `view_center`(视野中心,格坐标)/ `rot_angle` 不是在 shader 里用 TIME 算的,理由有两条:
//     · 运动是"**随机路径段**":随机取一个目标点(地图中央 60% 那块矩形里)⇒ 缓入缓出
//       地移过去(到点速度 → 0),同一段时间里再转 120°,到点后生成下一段。段与段的
//       位置/角度都**连续**(段末速度也是 0,段间的角度是**累加**),不许跳。
//     · 这类"随机 + 段 + 缓动"在 GDShader 里没有对应的东西(没有随机数、也没有"段"的概念),
//       所以运动学住在脚本里,每帧把两个 uniform 喂进来。
//   ⇒ shader 只管"把坐标怎么映射",运动学住在脚本里(见 main_menu.gd 的 _process)。
//
// ── 各量的取值与理由(都是**看实图调的**,记录在这里免得下次再猜)──
//   · `view_w_cells = 26.6667` —— 屏幕**横向**铺 26.67 格 ⇒ 1920/26.67 = **72 屏幕像素/格**
//     (= 玩家镜头 48px/格 的 **150%**;用户 2026-10-03 的口径链:500% → 200% → 150%)。
//     ★ 这是**由材质每个菜单实例显式设的**(`main_menu.gd` 的 `BG_VIEW_CELLS`),
//       这里的默认值只保证"没人设时也是个合理的值"。
//     ★ 它与烘图分辨率**不配套了**:72 / 32 = **2.25×**(非整数)⇒ 源砖的一个像素时而
//       占 2 个、时而占 3 个屏幕像素,砖缝**粗细略有不均**。★ 整数倍的邻近档只有
//       64px/格(≈133%)与 96px/格(200%)—— **要不要为像素完美牺牲"150%"这个数由用户定**,
//       改 `main_menu.gd` 的 `BG_VIEW_CELLS` 一个常量即可,shader 这边不用动。
//   · `fisheye = 0.85` —— r' = r·(1+k·r²)。屏幕边缘(半屏宽 0.5 处)采样到的源半径约
//     放大到 1.11 倍 ⇒ 中心的方块相对"鼓"出来;横贯画面的长条地板会**明显弯**(实图里
//     就是靠它读出来的)。实测 0.40/0.55 在块状地形上读不太出来(方块大小本就不一,
//     没有参照就看不出来),0.85 才有"一眼是鱼眼"的效果;再大(≥1.2)四角绕到地图另一头
//     太多、方块开始糊,而且会让人眼晕。
//   · `breathe_amp = 0.012` —— 整幅轻微胀缩,让静止时也有"活着"的感觉(≈1.2%)。
//   · `aberration = 0.02` —— 红/蓝通道各取 ±2% 的鱼眼强度 ⇒ 越靠边分色越明显(边缘约 5px)。
//     这是"奇怪的镜头"那一点非常规;选它是因为它**不引入任何新色值**(纯通道偏移)。
//   · `dim` —— ★★ **黑色遮罩的"不透明度"**(`col = mix(col, black, dim)`),**不是乘数**。
//     `0` = 完全不压、`1` = 全黑。**改语义这件事本身就是一次修复**:早先写成 `col *= dim`
//     (即 dim = "保留多少亮度"),而**用户的心智模型一直是"黑色滤镜的浓度"** ——
//     于是他每次说"太黑,调小一点"(0.36 → 0.25 → 0.20 → 0.15)实际都让画面**更暗**,
//     这正是"为什么还是好黑"的答案。现在按他的模型写,数字才同向可控。
//     当前 **0.50**(用户 2026-10-03 点名"又不够黑了,改成 0.5")⇒ 压 50%。
//     ★ 只动 dim、**没动 vignette**(留 0.30):用户说的是"不够黑"这一个量;
//       历史上这两个数**有时成对动**(57e3985)、**有时只动 dim**(f704b77)—— 别假设它们绑定。
//   · `vignette` —— 同一件事的**径向**版:边缘再叠一层黑色遮罩(中心 0、外圈到 `vignette`)。
//     ★ 它是"整体看着黑"的**第二**个贡献者(四角被压得最狠),故随 dim 一起从 0.45 收到 **0.30**。
//   · `desat` —— 去饱和(往亮度混)。它只改"彩度",对亮度影响可忽略,故保持 **0.20**。
//   · `blur_radius` —— 背景虚焦半径(**屏幕像素**)。0 = 关。★ 与取景(`view_w_cells`)
//     是**两个独立量**:模糊是"镜头虚焦",取景是"看多远",别耦合。
//   · 按钮不受影响 —— 它们有自己的**不透明**面板(见 §UI 的底板纪律)。


uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size   = vec2(150.0, 100.0);  // 地图格数 (cols, rows)
uniform float view_w_cells = 26.6667;              // 屏幕**横向**覆盖多少格(材质侧显式设,见上)
uniform float fisheye    = 0.85;                // 径向重映射强度 r' = r·(1 + k·r²)
uniform vec2  view_center = vec2(75.0, 50.0);   // 视野中心(格坐标)—— 脚本每帧喂
uniform float rot_angle  = 0.0;                 // 采样坐标旋转(弧度)—— 脚本每帧喂
uniform float breathe_amp = 0.012;              // 呼吸缩放幅度(整幅轻微胀缩)
uniform float aberration = 0.020;               // 边缘径向色差(纯粹是"怪镜头"感)
uniform float dim        = 0.50;                // **黑色遮罩的不透明度**(0=不压、1=全黑)
uniform float vignette   = 0.30;                // 边缘再压暗(同样是"黑色遮罩",按半径)
uniform float desat      = 0.20;                // 去饱和(往亮度混):背景不该比 UI 抢眼
uniform float blur_radius = 4.0;               // 背景虚焦半径(**屏幕像素**;见文件头)


vec2 rot2(vec2 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}


// cc:相对屏幕中心的坐标(以**半屏宽**归一 —— x∈[-0.5,0.5],y 已按宽高比折算,
//     故 cc 上的圆在屏幕上也是圆);strength:鱼眼强度。
// 顺序:**先旋转、再鱼眼、最后平移**(越界由 repeat_enable 绕回)。
// ★ 旋转与鱼眼可交换(鱼眼是径向对称的),所以这个顺序不是关键;但**平移必须最后** ——
//   它是"世界在屏幕上挪",不该跟着镜头一起转(否则"旋转"会退化成原地打圈)。
vec2 menu_sample_uv(vec2 cc, float strength) {
	vec2 c = rot2(cc, rot_angle);
	float r = length(c);
	float rs = r * (1.0 + strength * r * r);
	vec2 dir = c / max(r, 0.00001);
	vec2 c2 = dir * rs;
	vec2 cell = view_center + c2 * view_w_cells;      // 半屏宽单位 → 格坐标(绕视野中心)
	return cell / map_size;
}


// 邻居 tap 用:只做鱼眼 + 平移,**不算色差** —— 一次纹理采样。
// ★ 色差只在**中心那一份**上算(见 fragment):否则 9 个 tap 每个都要 3 次采样、
//   每像素 27 次;而色差本来就只影响边缘那几个像素,模糊之后差别看不出来。
vec3 bg_sample(vec2 cc) {
	return texture(map_tex, menu_sample_uv(cc, fisheye)).rgb;
}


// 中心那一份:三个颜色通道各取略微不同的鱼眼强度 ⇒ 边缘出现径向色差。
vec3 bg_sample_ab(vec2 cc) {
	float ab = aberration * smoothstep(0.22, 0.60, length(cc));
	vec3 col;
	col.r = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 + ab))).r;
	col.g = texture(map_tex, menu_sample_uv(cc, fisheye)).g;
	col.b = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 - ab))).b;
	return col;
}


void fragment() {
	// 宽/高(>1)。窗口 1920×1440 时 ≈ 1.333。
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);      // 呼吸:整幅轻微胀缩

	float r = length(cc);

	// ── 背景虚焦(屏幕空间 3×3 高斯近似,权重 [1,2,1;2,4,2;1,2,1]/16)──
	// ★ 放在**鱼眼之后、对最终颜色取邻近 tap** ⇒ 观感是"背景虚焦",不是"纹理糊了"
	//   (对纹理本身模糊会被鱼眼二次拉伸:中心与边缘的糊法不一样)。
	// ★ 步长是**屏幕像素**:cc 的一步 = SCREEN_PIXEL_SIZE(x)/PE(y)/aspect。
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

	// 黑色遮罩(见文件头"dim 的语义")。
	col = mix(col, vec3(0.0), dim);
	// 去饱和:真实地形里有亮青的水、绿的树叶、灰蓝的砖 —— 原色直接铺在标题后面会抢视线,
	// 往亮度混一点,保留"这是哪张图"的色相线索,同时让它安静下来。
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.28, 0.66, r));   // 边缘再压暗
	COLOR = vec4(col, 1.0);
}
