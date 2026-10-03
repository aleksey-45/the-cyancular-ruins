shader_type canvas_item;

// 主菜单背景:把一张地图(新版 factory,`maps/newfactory.cyrm`)的**真实地形图**
// (由 `TerrainAtlas.bake_map_image` 用与 Level0 同一份图集烘出来 —— 砖是 structure.png
// 的砖、水是水、树叶是树叶)铺满全屏,叠一层 **鱼眼镜头** 透视 + 缓慢漂移 + 慢速旋转
// + 边缘径向色差。
//
// ★ 为什么是 shader 而不是"缩略图缩放":
//   鱼眼是**逐像素的径向重映射**,不是整体缩放;漂移/旋转必须逐帧跟时间走。两者都要求
//   在采样阶段改 uv,纹理本身不动。
// ★ 环面自洽:本作的世界本来就是环面(左右/上下无缝回绕),所以采样越界时用
//   `repeat_enable` **绕到地图另一头**正好与世界观一致 —— 旋转/漂移把镜头推出图外时,
//   露出的也是这个世界本身,不会是空白边或拉伸条纹。
// ★ 本 shader **只服务主菜单背景**,与对局内的 `post_process.gdshader` 无关:
//   改这里不会碰任何一局游戏的一个像素。
//
// ── 镜头运动:两个量由**脚本每帧喂**(main_menu.gd)──────
//   `drift_offset` / `rot_angle` 不是在 shader 里用 TIME 算的,理由有两条:
//     · "随意"(非周期)要的是**噪声**轨迹,而 GDShader 里没有噪声函数;用几层正弦叠加
//       再怎么做也终究会绕回同一个圈 —— 那是用户点名的"机械感"。
//     · 脚本侧用 `FastNoiseLite` 采样,种子固定 ⇒ 每次进菜单是**同一段**轨迹(可复现),
//       又**永不重复**。旋转角是逐帧**积分**出来的(角速度 = 基准 + 噪声调制),
//       所以角速度连续 ⇒ 角度 C¹ 连续,**不会跳**。
//   ⇒ shader 只管"把坐标怎么映射",运动学住在脚本里(见 main_menu.gd 的 _process)。
//
// ── 各量的取值与理由(都是**看实图调的**,记录在这里免得下次再猜)──
//   · `view_w_cells = 20` —— 屏幕**横向**铺 20 格 ⇒ 1920/20 = **96 屏幕像素/格**
//     (= 玩家镜头 48px/格 的 **200%**,用户 2026-10-03 最终口径)。
//     ★ 这是**由材质每个菜单实例显式设的**(`main_menu.gd` 的 `BG_VIEW_CELLS`),
//       这里的默认值只保证"没人设时也是个合理的值"。
//     ★ 它必须与烘图分辨率**配套**:当前 96 / 32 = **3×** 整数倍 ⇒ 每个**源像素**
//       (源砖是 32×32,一格即一块砖)落到 3×3 个屏幕像素上,砖缝粗细均匀(像素完美)。
//       改成非整数倍(比如 240/32 = 7.5,或旧写法 96/64 = 1.5)会让某些砖缝粗一格、某些细一格。
//   · `fisheye = 0.85` —— r' = r·(1+k·r²)。屏幕边缘(半屏宽 0.5 处)采样到的源半径约
//     放大到 1.11 倍 ⇒ 中心的方块相对"鼓"出来;横贯画面的长条地板会**明显弯**(实图里
//     就是靠它读出来的)。实测 0.40/0.55 在块状地形上读不太出来(方块大小本就不一,
//     没有参照就看不出来),0.85 才有"一眼是鱼眼"的效果;再大(≥1.2)四角绕到地图另一头
//     太多、方块开始糊,而且会让人眼晕。
//   · `breathe_amp = 0.012` —— 整幅轻微胀缩,让静止时也有"活着"的感觉(≈1.2%)。
//   · `aberration = 0.02` —— 红/蓝通道各取 ±2% 的鱼眼强度 ⇒ 越靠边分色越明显(边缘约 5px)。
//     这是"奇怪的镜头"那一点非常规;选它是因为它**不引入任何新色值**(纯通道偏移)。
//   · `dim / desat / vignette` —— 让背景**在文字后面退下去**。★ 2026-10-03 重调:
//     底色从"近黑深蓝"换成**对局那个清屏色 `TerrainAtlas.SKY_COLOR`**(#B0E5F6,用户点名
//     "背景颜色要和局内一致")之后,原来的 0.50/0.30/0.45 太亮 —— 标题的强调青
//     (`UiFactory.C_ACCENT` #59D9E5)与天空是**同一个色相**,天空一旦亮起来就压不住字了。
//     现在整幅压到 **0.36**、去饱和 **0.25**、边缘再压 **0.55**。
//     ★★ 这是**取舍,不是"照搬了 #B0E5F6"**:天空 #B0E5F6 的相对亮度是 0.86,乘 0.36 之后
//     落到 ≈0.30(相对亮度),**压暗到原色的三成半** —— 换来标题在它上面仍有对比
//     (画面正中天空处 ≈ (0.248,0.323,0.347));去饱和刻意只留 0.25,是**为了保住那点青色**
//     (压暗已经让它变灰,再去饱和就真成"另一个世界"了)。
//     ★ 实测取图(WIDTH 1920):天空落点亮度约 0.25,标题(C_ACCENT,亮度 0.75)对比度
//     ≈2.6:1 —— 低于 WCAG 大字的 3:1,但标题是 96px 粗体 + 12px 同色描边(笔画本身极粗),
//     实图上清楚可读(见 `.superpowers/sdd/_l4_1_mainmenu.png`)。★ 再往上调 `dim` 会
//     先牺牲标题、再牺牲副信息(`C_TEXT_DIM`);再往下调则天空越来越不像"白天"。
//     ★ 按钮不受影响 —— 它们有自己的**不透明**面板(见 §UI 的底板纪律)。

uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size   = vec2(150.0, 100.0);  // 地图格数 (cols, rows)
uniform float view_w_cells = 20.0;              // 屏幕**横向**覆盖多少格(材质侧显式设,见上)
uniform float fisheye    = 0.85;                // 径向重映射强度 r' = r·(1 + k·r²)
uniform vec2  drift_offset = vec2(0.0);         // 平移(半屏宽为单位)—— 脚本每帧喂
uniform float rot_angle  = 0.0;                 // 采样坐标旋转(弧度)—— 脚本每帧喂
uniform float breathe_amp = 0.012;              // 呼吸缩放幅度(整幅轻微胀缩)
uniform float aberration = 0.020;               // 边缘径向色差(纯粹是"怪镜头"感)
uniform float dim        = 0.36;                // 整体压暗(见上:与 SKY_COLOR 的取舍)
uniform float vignette   = 0.55;                // 边缘再压暗
uniform float desat      = 0.25;                // 去饱和(往亮度混):背景不该比 UI 抢眼


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
	vec2 c2 = dir * rs + drift_offset;
	vec2 cell = map_size * 0.5 + c2 * view_w_cells;   // 半屏宽单位 → 格坐标
	return cell / map_size;
}


void fragment() {
	// 宽/高(>1)。窗口 1920×1440 时 ≈ 1.333。
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);      // 呼吸:整幅轻微胀缩

	float r = length(cc);
	float edge = smoothstep(0.22, 0.60, r);

	// 三个颜色通道各取略微不同的鱼眼强度 ⇒ 边缘出现径向色差(越靠边越明显)。
	float ab = aberration * edge;
	vec3 col;
	col.r = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 + ab))).r;
	col.g = texture(map_tex, menu_sample_uv(cc, fisheye)).g;
	col.b = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 - ab))).b;

	col *= dim;                                        // 全局压暗
	// 去饱和:真实地形里有亮青的水、绿的树叶、灰蓝的砖 —— 原色直接铺在标题后面会抢视线,
	// 往亮度混三成半,保留"这是哪张图"的色相线索,同时让它安静下来。
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.28, 0.66, r));   // 边缘再压暗
	COLOR = vec4(col, 1.0);
}
