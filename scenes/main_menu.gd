extends Control
# 主菜单(像素 UI):粗体大标题 + 模式按钮浮现动画,场景是裸 Control,UI 全在代码里建。
# 左下角显示版本号(分支名 + git 提交序号);「信 息」按钮切到独立整页(提交历史/团队/致谢)。
# 「单人模式」弹出开局面板(勾选本局禁用武器),确认后进 Level0。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源);字号必须是 16 的倍数。

# 自动探针节点名:挂在树根上跨场景存活,靠这个名字做「已挂过就别再挂」的幂等判据
const PROBE_NODE_NAME := "MenuAutotestProbe"

var _ui_layer: CanvasLayer = null
var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)

# ── 背景镜头运动的状态(见 _process)──
var _bg_mat: ShaderMaterial = null       # 背景 ColorRect 的材质(null = 没建出来)
var _bg_cells := Vector2(150.0, 100.0)   # 背景那张图的格数(从纹理尺寸反推;随机取点要用)
var _rng := RandomNumberGenerator.new()  # 路径随机源(种子固定 ⇒ 可复现)
var _seg_t := 0.0                        # 当前段已走过的秒数
var _seg_from := Vector2.ZERO            # 当前段起点(格坐标)
var _seg_to := Vector2.ZERO              # 当前段终点(格坐标)
var _seg_index := 0                      # 段序号(奇偶决定角度是 0→120 还是 120→0)

# 弹出面板的**骨架**在场景里(容器/滚动区/标签/锚点看得见);按钮与勾选框仍由
# UiFactory 建、数据由 _fill_* 填 —— 控件进场景就得在使用处补 style_control +
# style_button,等于把「控件工厂唯一来源」这条纪律散回各处。
const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")

# ── 背景:**真实地形**(与游戏同一份图集)+ 鱼眼漂移(没有任何实体)──
# 用户要求:背景是"世界"本身在以一种奇怪的鱼眼镜头缓慢漂移/移动,**不放任何实体**
# (没有玩家/敌人/子弹)。
# ★ 2026-10-03 改判:背景必须是**真实地形** —— 砖是 `structure.png` 的砖、水是水、
#   树叶是树叶,像"透过一扇窗看进那个世界"。旧实现走 `MapCatalog.build_image()`,
#   而那套的语义是**选图面板的示意缩略图**(每格一个平色块)⇒ 放大多少都是色块,
#   不是那个世界。现在改走 `TerrainAtlas.bake_map_image()`:**同一个** `TerrainAtlas`
#   给 `Level0` 生成 TileSet、也在这里把地图烘成 Image ⇒ 背景与游戏是同一套像素。
#
# ── 取景/缩放(具名常量,方便"再放大一点")──
# 一句话:**一格 = 72 屏幕像素 = 玩家视角(48px/格)的 150%**;屏幕约 27 格宽。
#   · `BG_VIEW_CELLS = 26.6667` —— 屏幕**横向**铺 26.67 格 ⇒ 1920 / 26.67 = **72 屏幕像素/格**。
#     ★ 参照:对局的玩家镜头 = 64px × `PlayerParams.cam_zoom`(0.75)= **48px/格、约 40 格宽**
#     ⇒ 这里是它的 **1.5 倍**(用户 2026-10-03 的口径:500% → 200% → **150%**)。
#   · ★★ **像素完美这一档有个取舍(照实登记)**:72 / `BG_CELL_PX`(32)= **2.25×**(非整数)
#     ⇒ 源砖的一个像素会时而占 2 个、时而占 3 个屏幕像素,砖缝**粗细略有不均**
#     (2.25 是"2 或 3",不是随机 —— 但每隔一个砖缝宽一点是看得出来的)。
#     ★ 整数倍的邻近档只有 **`BG_VIEW_CELLS = 30.0`(64px/格 ≈ 133%)** 与
#       **`BG_VIEW_CELLS = 20.0`(96px/格 = 200%)**。**要不要为了像素完美牺牲"150%"这个数,
#       留给用户定** —— 改 `BG_VIEW_CELLS` 一个常量即可。
#   · `BG_CELL_PX = 32` —— **烘图**分辨率:游戏里 64px 的一格烘成 32 图像像素
#     (= **源砖的分辨率**:`structure.png` 一块砖就是 32×32,游戏里按 2× 画成一格)。
#     整张 newfactory(150×100 格)= 4800×3200 ≈ 61MB。
#     ★★ 为什么烘图分辨率**不**直接等于屏幕的 96(最直觉的做法):那会得到
#     150×96 × 100×96 = 14400×9600 ≈ 553MB,主菜单背不动(Image + 上传 GPU 各一份)。
#     ★ 而"像素完美"(砖缝粗细均匀)要求的**不是**烘图分辨率等于屏幕分辨率,只要求
#     **屏幕像素/格 ÷ 烘图像素/格 是整数**:
#       – 图集的子格是 16 图像像素,但那是**源 8×8 象限最近邻放大 2×** 来的
#         ⇒ 真正的源分辨率是 **8px/子格 = 32px/格**;
#       – 烘到 32px/格 时每个子格 = 8px,**正好等于那个 8×8 源象限本身**(放大 2× 再缩回去无损);
#       – 屏幕再放大 **整数 3×** ⇒ 每 1 个源像素落到 3×3 个屏幕像素上。
#     (烘图本身走的是**源分辨率**那条:32px/格 时每个子格 = 8px = 源砖那个 8×8 象限,
#      不是从 16px 图集层再缩。)
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
const BG_VIEW_CELLS := 26.6667
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"
# 背景**虚焦**半径(屏幕像素)。★ 与取景是两个独立量:模糊是"镜头虚焦",取景是"看多远"。
# 4 是"看得出是虚的、又不至于把砖整块抹平"的值(150% 下一格 72px,砖面本身是平色,
# 4px 的高斯主要糊的是砖缝/梯子横档这些高频边)。
const BG_BLUR_RADIUS_PX := 4.0

# ── 镜头运动:「随机路径段」循环(用户 2026-10-03 的最新口径,其余描述以本条为准)──
#   1. 取一个随机目标点(在地图的**中央 60%** 那块矩形里,两轴都是);
#   2. **平滑移动**过去(缓入缓出,到点速度 → 0);
#   3. **同一段时间里**视角旋转 `SEG_TURN_DEG`;
#   4. 到点后重新生成下一段。
# ★ 为什么不住在 shader 里:GDShader 没有随机数、也没有"段"的概念;运动学住脚本,
#   每帧把 `view_center`(视野中心,格坐标)与 `rot_angle` 两个 uniform 喂进去。
# ★ 角度口径(用户 2026-10-03 订正过一次,以本版为准):
#   ① **角度在 0° 与 120° 之间**(不是每段累加 +120°)。用户原话:"是零到 120,不是 120"。
#      ⇒ 段 1:0°→120°、段 2:120°→0°、段 3:0°→120° …… **来回摆**。
#      这样三条同时成立:角度**始终落在 [0,120]**、段间**连续不跳**、且与"每段重新取路径"同拍。
#      (若让每段都从 0° 重新开始,段间会从 120° 跳回 0° —— 那正是"不许跳"禁止的。)
#   ② **"旋转比移动缓慢很多"落在段时长与缓动曲线形状上**(两者同长,没法靠时长差表达):
#      位移走缓入缓出(smoothstep,峰值速度 1.5 倍);旋转走**梯形速度剖面**
#      (两端速度 0、中间匀速段最长,峰值只有 1.33 倍)⇒ **比位移更接近线性**,
#      观感上是"移动先到位、转动还在慢慢走",而不是"两者一起加速又一起停"。
const SEG_MIN_FRAC := 0.20     # 目标点的取值范围:地图的 20%~80%(两轴 ⇒ 中央 60% 的矩形)
const SEG_MAX_FRAC := 0.80
# 每段时长(秒)—— **它就是"移动速度"的单一旋钮**:位移与旋转同段,改它两者一起变。
# ★ 2026-10-03 用户连提三次降速:15.0 → 21.4(70%)→ 32.0 → **48.0s**(再降 2/3)。
#   最后一次刻意走**大档位**而不是再乘一次小数 —— 用户是靠"看着太快"逐步逼近的,
#   一步一个台阶比连续微调好收敛。
#   ★ 连带效果(照实说):旋转也同比例变慢(120°/段 ⇒ **3.75°/s**,原 5.6°/s);
#     "旋转比移动慢很多"这个**比例**没变,只是两者绝对值一起降。**刻意只动这一个常量** ——
#     一次一个变量,用户才好接着调。★ 要再慢就继续加这个数。
# 当前量级(换算到 150% 取景 = 一格 72 屏幕像素):平均位移 ≈36 格 / 48s ≈ **54px/s**
# (峰值 ≈81px/s);转角 120°/段 = **2.5°/s**;一整圈 = 3 段 ≈ **144s**。
# ★ 中间那 36 格/段是怎么来的:目标点两轴各均匀落在 20%~80% 的矩形(newfactory 150×100 格
#   ⇒ 列 30~120、行 20~80),两点间平均距离 ≈36 格。**最坏情况 ≈108 格/段**(≈243px/s 峰值)。
const SEGMENT_SEC := 48.0
# 每段**端点**的角度(度):在 0° 与 120° 之间来回摆。★ 用户点名"零到 120" ⇒ 原样实现。
# 若嫌转太快,**先降这个**(降到 60 ⇒ 2.8°/s),不要去改段时长 —— 那会连位移一起拖慢。
const SEG_TURN_DEG := 120.0
# 旋转曲线的"变速段"占整段的比例(梯形速度剖面,见 _trapezoid):
# 0.25 ⇒ 两端各 25% 用来加减速、中间 50% 匀速,峰值速度只有平均的 1/(1-0.25) ≈ **1.33 倍**。
# ★ 它比位移的 smoothstep(峰值 1.5 倍、且峰值被 SEG_MOVE_BIAS 前移)**更接近线性** ——
#   这正是"旋转比移动缓慢/更稳"那半句的落实处。★ 两端速度**严格为 0**:0↔120 每次反向
#   都发生在速度为 0 的时刻,所以反向处**不会出现折角**(这是"不许跳"在角度上的落实)。
const SEG_TURN_EDGE_FRAC := 0.25
# 位移缓动曲线的偏置(见 _process):`s = smoothstep(u) ** SEG_MOVE_BIAS`。
# 1.0 = 对称的缓入缓出;取 **0.8** ⇒ 速度峰值略微前移、"到得更早一点、然后慢慢蹭到点上" ——
# 这正是"移动先到位、转动还在慢慢走"里那半句。★ 两端速度仍严格为 0(0^0.8 = 0),故不跳。
const SEG_MOVE_BIAS := 0.8
# 路径随机数种子固定 ⇒ "随机"但**每次进菜单是同一串路径**(可复现、可对图)。
const SEG_PATH_SEED := 20261003
func _ready() -> void:
	# ── 发布产物自检:武器注册表到底从包里读到了几条 ──
	# ★ 为什么必须在**产物侧**量:`data/weapons.json` 进不进 `.pck` **只由一次真导出回答**
	#   —— 静态只能论证到"导出过滤器只跳 `TextFile`,而 `.json` 是 `JSON` 类型"
	#   (`include_filter` 里的 `data/*.json` 是**保险不是机制**)。真没进包时
	#   `WeaponRegistry._ensure_loaded()` 只打**一条** `push_error`、**只在 stderr**、
	#   **不影响退出码** ⇒ 光看"游戏起得来"是看不出来的。
	# ★ 开关写在 `--` 之后(与 `--netstat` / `--pickup-diag` 同款 —— 写在前面会被 Godot
	#   当自己的参数丢掉、**静默失效**),且**默认关** ⇒ 生产行为一字不变。
	# ★ 消费者是 `tools/build_release.py` 的产物冒烟(`check_weapon_registry`):它拿仓库里
	#   那份 json 当期望值,与这一行对账。判据是**文本 grep**,不看退出码。
	if OS.get_cmdline_user_args().has("--registry-report"):
		var ids: Array[int] = WeaponRegistry.all_ids()
		print("[registry] weapons=%d ids=%s" % [ids.size(), str(ids)])

	# 复位对局相关全局(进过 PvP 回来不残留)
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	# 上次单人开局选择(存档在 Settings)
	RunOptions.reset()
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()

	_build_new_ui()

	# 菜单流转自动探针(规格 §6 的 L4 验收项):命令行 `-- --autotest-sp|mp|set|level` 时,
	# 把探针挂到树根(而非本场景)——它要穿越 change_scene 存活。平时零开销。
	# 缺文件守卫:探针文件可能缺失(开发分支尚未落该文件、或有人手删)时静默跳过,不让主菜单崩。
	# 注:「发布版会裁掉 tests/」**不是**这条守卫的理由——export_presets.cfg 是
	# export_filter="all_resources",tests/ 会一起打进发布包,真实理由是文件可能不存在。
	# 幂等:sp 流程经 Level0.safe_change_scene 会**重进本场景**,不判重就会挂上第二个探针
	# (第二个探针又会点一次「单人模式」,把干净主菜单盖成单人面板)。
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--autotest-"):
			continue
		if get_tree().root.has_node(NodePath(PROBE_NODE_NAME)):
			break
		if not ResourceLoader.exists("res://tests/smoke/menu_autotest.gd"):
			break
		var probe_script := load("res://tests/smoke/menu_autotest.gd")
		if probe_script == null:
			break
		var probe := Node.new()
		probe.name = PROBE_NODE_NAME
		probe.set_script(probe_script)
		probe.set("mode", arg.trim_prefix("--autotest-"))
		get_tree().root.add_child.call_deferred(probe)
		break


# 单机进关卡(Level0 = 全量物理世界)。菜单是纯 UI(无世界、无大物理),普通切场景即可:
# change_scene 在这里只会销毁一棵 Control 树,不存在「销毁大世界 × 构建大世界」的同帧对撞。
# 反方向(游戏世界退役回菜单)才需要挂起式切换,见 Level0.safe_change_scene 的注释。
func _enter_level0() -> void:
	# 选图(菜单里定的,空 = 随机):★ 必须在 change_scene **之前**钉进 MazeGenerator 的会话缓存
	# —— 它是静态的,活过场景切换;文件被删/改名时回落随机,不让玩家卡在旧路径上。
	MazeGenerator.set_map_file(Settings.sp_map_path if MapCatalog.is_valid_map(Settings.sp_map_path) else "")
	# ★ 必须跟着重算世界尺寸:启动时算的是"当时随机挑的图"(如 demo 125×75 → 8000 宽),
	#   选了别的图(如 newfactory 150×100 → 9600 宽)不重算的话环面回绕/最短路径按错边界。
	GameParameters.refresh_map_size()
	Level0.pvp_mode = false            # 复位 PvP 标志,避免上次 PvP 残留
	CombatComponent.pvp_arena = false  # 回单机恢复命中无敌帧
	get_tree().change_scene_to_file("res://scenes/level_0.tscn")


# ── 菜单 UI ──
func _build_new_ui() -> void:
	_build_ui_layer()
	var title := _build_title()
	var ver := _build_version_label()
	var buttons := _build_menu_buttons()
	_play_emerge(title, ver, buttons)


func _build_ui_layer() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 140   # 盖过 PostProcess(128)/HUD(129)
	add_child(_ui_layer)
	_build_background()


# 背景:真实地形图铺满全屏,由 shader 做鱼眼 + 漂移 + 压暗/暗角(见 menu_fisheye.gdshader)。
# ★ 底 ColorRect 的原色是 `UiFactory.C_BG`(**调色板 token,不是新字面量**):shader 正常时
#   fragment 覆写整块 COLOR,这层底不可见;万一 shader 载入失败,留下的是一块与页面底同色
#   的深底(而不是 ColorRect 默认的**白色** —— 那会是一屏白得读不出字的菜单)。
# ★ 空气的底色用 `MapCatalog.BG`(与选图缩略图同底色):它比 `C_BG` 略亮一点,烘出来的
#   地形才有"背景"可依(纯黑会把砖缝读成噪点);而 shader 的 dim/vignette 会把它压到
#   和原来那层底差不多的亮度 ⇒ 文字可读性不依赖这一处取色。
func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = UiFactory.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh: Shader = load(BG_SHADER)
	if sh != null:
		# 真实地形图:地图子格纹理 × TerrainAtlas 的图集(= Level0 生成 TileSet 的同一份)。
		# ★ 底色 = 对局那个清屏色(`TerrainAtlas.SKY_COLOR`),不是选图缩略图那层近黑 ——
		#   用户 2026-10-03:"背景颜色不对(要和局内一致)"。可读性靠 shader 的 dim 换。
		# ★ 这里**没有**出生点标记要抹 —— 烘的是地形本身,不画任何实体/标记。
		var tex := TerrainAtlas.terrain_texture(BG_MAP, BG_CELL_PX, TerrainAtlas.SKY_COLOR)
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("map_tex", tex)
		# 格数由纹理尺寸 ÷ 每格像素反推(4800/32 = 150 列 × 3200/32 = 100 行),免得再解析一次地图头。
		mat.set_shader_parameter("map_size",
				Vector2(tex.get_width(), tex.get_height()) / float(BG_CELL_PX))
		# 取景(屏幕横向多少格)由常量显式给,不从纹理尺寸反推 —— 见 BG_VIEW_CELLS 的头注:
		# 它与 BG_CELL_PX 是配套的一对,反推会让"再放大一点"变成只改一半。
		mat.set_shader_parameter("view_w_cells", BG_VIEW_CELLS)
		mat.set_shader_parameter("blur_radius", BG_BLUR_RADIUS_PX)
		_bg_cells = Vector2(tex.get_width(), tex.get_height()) / float(BG_CELL_PX)
		_bg_mat = mat
		bg.material = mat
		_init_motion()
	_ui_layer.add_child(bg)


# ── 路径段循环 ──
# 首段:起点也取一个随机点(而不是地图正中)—— 免得每次进菜单都从同一个位置出发,
# 而且那一点必然落在 20%~80% 的矩形里(与后面每一段同一个分布)。
func _init_motion() -> void:
	_rng.seed = SEG_PATH_SEED
	_seg_t = 0.0
	_seg_index = 0
	_seg_from = _random_target()
	_seg_to = _random_target()
	_bg_mat.set_shader_parameter("view_center", _seg_from)
	_bg_mat.set_shader_parameter("rot_angle", 0.0)   # 段 0 从 0° 出发


func _random_target() -> Vector2:
	return Vector2(
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.x,
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.y)


# 背景镜头运动:每帧把 `view_center`(视野中心,格坐标)与 `rot_angle` 喂给 shader。
# ★ "不许跳"这条硬约束在两处都成立:
#   · **位置**:段末 u→1 时位移 s→1(恰好落在 `_seg_to`),而下一段从 `_seg_from = 上一段的
#     `_seg_to`、s→0 出发 ⇒ 位置连续;且 smoothstep 在两端导数为 0 ⇒ 速度也连续(不会"一顿")。
#   · **角度**:0→120 与 120→0 交替,**端点角度重合**(上一段结束在 120°,下一段也从 120° 出发)
#     ⇒ 角度连续;且梯形剖面在两端速度同样为 0 ⇒ 反向处是"停稳了再往回走",没有折角。
# ★ 曲线形状(见常量区 ②):位移 = `smoothstep(u) ** SEG_MOVE_BIAS`(缓入缓出、峰值略前移),
#   旋转 = **梯形速度剖面**(两端变速、中段匀速)⇒ 观感上是"移动先到位、转动还在慢慢走"。
func _process(delta: float) -> void:
	if _bg_mat == null:
		return
	_seg_t += delta
	while _seg_t >= SEGMENT_SEC:
		_seg_t -= SEGMENT_SEC        # 保留余数,不累积误差
		_seg_index += 1
		_seg_from = _seg_to          # 下一段从上一段的终点出发 ⇒ 位置不跳
		_seg_to = _random_target()
	var u := clampf(_seg_t / SEGMENT_SEC, 0.0, 1.0)
	var s: float = pow(smoothstep(0.0, 1.0, u), SEG_MOVE_BIAS)
	var e := _trapezoid(u)
	# 偶数段 0→120,奇数段 120→0(见常量区 ①:角度只在 [0,120] 之间来回)
	var turn: float = e if (_seg_index % 2) == 0 else 1.0 - e
	_bg_mat.set_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	_bg_mat.set_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))


# 梯形速度剖面的**位移**曲线:0 → 1,两端速度 0、中间匀速(占 1-2*edge)。
# 面积恒为 1 ⇒ s(0)=0、s(1)=1;峰值速度 = 1/(1-edge)(edge=0.25 ⇒ 1.33 倍)。
# ★ 用它而不是再一个 smoothstep,是因为它**更接近线性**(峰值 1.33 < 1.5),
#   且两端速度同样为 0 —— 见常量区 ②。
static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)               # 匀速段的速度(面积归一)
	if u < a:
		return v * u * u / (2.0 * a)             # 加速
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)   # 减速
	return v * (a * 0.5 + (u - a))               # 匀速


# 大标题:中央浮现(描边同色加粗)
# 大标题:中央浮现。
# ★ 2026-10-03 用户:删掉副信息行(原「环面世界 · 像素射击」)、**标题放大** 96 → **128**
#   (16 的倍数,与全项目字号纪律一致)、并**去掉描边** —— 于是这里**一个描边/阴影 override
#   都没有**了,标题就是纯 `C_ACCENT` 字身。★ 用户是知情取舍(更亮更干净的背景必然压不住
#   浅色字),**别**再"为了可读性"把描边/外环/底板加回来 —— 要兜只在文字这侧、且由用户点了头才做。
func _build_title() -> Label:
	var title := UiFactory.label("The Cyancular Ruins", 128, UiFactory.C_ACCENT)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	title.offset_top = 160.0
	title.offset_bottom = 340.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate.a = 0.0
	_ui_layer.add_child(title)
	return title


# --nover 的处理收在 AppInfo.version_string() 里(单一收口),这里不再分叉。
# 版本号放左下角、小一号、压暗:原先居中挂在标题正下方 —— 位置与字号都让它读成
# 标题的「副标题」,和真正的模式按钮抢视线(2026-09-13 视觉评析)。
func _build_version_label() -> Label:
	var ver := UiFactory.label(AppInfo.version_string(), 16, UiFactory.C_TEXT_DIM)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	ver.offset_left = 24.0
	ver.offset_right = 900.0
	ver.offset_top = -40.0
	ver.offset_bottom = -16.0
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	ver.modulate.a = 0.0
	_ui_layer.add_child(ver)
	return ver


# 模式按钮:标题之后从中央依次浮现。返回按钮数组(浮现动画按这个次序排)。
# 三组分开 ——「开始游戏」/「选项」/「退出」,且**三组之间有分隔线**(见下)。
# ★★ 2026-10-03(按钮层级,用户已批准):六颗不再同权重 ——
#   主行动「单 人 模 式」720×104 + `accent` 档(C_ACCENT 描边,比 primary 更前);
#   「多 人 模 式」640×88;Beta/退出走 quiet 档;设置/信息再小一档 560×76。
#   ★ 文案一个字都没动(四条自检 + kh_l4_visual_probe 全按文案找按钮)。
# ── 模式按钮列的版式常量(第三批尺度,2026-10-03)──
# 组与组之间的空档(分隔线**上下各一份**)。
const MENU_GROUP_GAP := 48
# 组内按钮之间的空档。
const MENU_ITEM_GAP := 28
# 整列顶部偏移(锚在屏幕中心 + 这个偏移,列自该处向下长)。
const MENU_COLUMN_TOP := 170.0


func _build_menu_buttons() -> Array:
	# ★★ 2026-10-03:**撤掉那个「框住所有按钮的大框」**(用户看完成品图后的裁定 ——
	#   按钮直接落在页面底上,不要外框)。同一批把整列尺度放大(设计稿 1920×1440 上原度量偏小):
	#   按钮 640×88(工厂默认)、组内间距、组间间距、整列 `offset_top` 都收进下面三个具名常量。
	#   ★ 定位/生长方向/次序/文案一个字都没动(探针按文案找按钮)。
	#   ★ 别再加回 `menu_panel()`:撤框是**用户明确要求**,不是审美取舍。
	# ★ 2026-10-03(第二批):三组之间插入 `menu_separator()`;外层 separation 也用它来
	#   表达"组分隔"而不是组内 —— 组的边界因此**看得见**。
	#   ★ 第三批(用户:「还是不够」)把两档各抬约 +35%:20/36 → 28/48。
	#     ⚠ 简报里写的 "48 / 20 → 64 / 28" 是按**加分隔线之前**那版读的(那时组间 = 48);
	#       分隔线进来后组间实际是 36,故这里按"当前值 × 1.35"落成 **48**。
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_top = MENU_COLUMN_TOP
	box.add_theme_constant_override("separation", MENU_GROUP_GAP)   # 组与组之间的空档(分隔线上下各一份)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_ui_layer.add_child(box)

	var play_group := _btn_group()
	var opt_group := _btn_group()
	# ★★ 两条分隔线**各留一个引用**:它们要按**屏幕上的上下次序**一起参与浮现(见下方返回的序列)。
	#    原先它们不在那个序列里 ⇒ 一进菜单就是全亮的两条线,而按钮还在一个个淡入。
	var sep_a := UiFactory.menu_separator()
	var sep_b := UiFactory.menu_separator()
	box.add_child(play_group)
	box.add_child(sep_a)
	box.add_child(opt_group)
	box.add_child(sep_b)

	# 主行动:尺寸最大 + accent 档(C_ACCENT 描边)。这是整页唯一的"最前"按钮。
	var start_btn := UiFactory.menu_button("单 人 模 式", 32, Vector2(720, 104), "accent")
	start_btn.pressed.connect(_on_single_pressed)
	# ★★ 联机入口只剩这一颗(2026-10-03 三合一,统一大厅 `mp_lobby`):1v1 / 3v3 / 大乱斗
	#   都在那一个页面里按筛选区分,菜单不再按模式分列三颗按钮。
	#   它一律走 `PvpSession.reset()`(每次进页复位 role/spawn/map_path),
	#   **不要**在这里写任何清凭据的东西:回局凭据要活过"回主菜单"这一步(那正是路径乙的意义),
	#   而模式归属改由各大厅页记房号那一拍(`note_room(code, mode)`)确定(见 pvp_session.gd 的
	#   `room_mode` 那段:三张注册表的房号空间是共用的,不判模式就会串)。往 `reset()` 里加回清凭据
	#   那四行、或在这里直接清凭据 = 玩家从对局回主菜单、再按这个入口进来时凭据被抹掉
	#   → 自己那间"对局中"的房恒为灰、回不去(**而一行报错都没有**) —— 这就是 C1。
	#   `reconnect_smoke` 有源码级断言钉着它。
	var multi_btn := UiFactory.menu_button("多 人 模 式", 32, Vector2(640, 88))
	multi_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()   # 不碰回局凭据(见 pvp_session.gd 的 reset 注释)
		get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn"))
	# Beta(2026-09-28,用户指定放在联机入口下面):以后所有实验性玩法都从这个入口进
	# (现在是 PvP 时间玩法的两个变体)。弱化变体:实验功能不与正式模式抢注意力。
	# ★ 尺寸仍**显式**传:variant 是第 4 个位置实参、GDScript 没有具名实参 —— 这里必须写出
	#   与 `menu_button` 默认值同值的尺寸(640×88),别再写回旧的 420×64(那会让 Beta / 退出
	#   两颗比同列按钮瘦一圈)。
	var beta_btn := UiFactory.menu_button("Beta", 32, Vector2(640, 88), "quiet")
	beta_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/beta_menu.tscn"))
	# 字间距一律单空格。原先 2 字标签(设/置、退/出)用 6 个全角空格撑到与 4 字标签等宽,
	# 结果是两座孤岛,而再短些的标签又比它们窄 —— 按钮列的文本块宽度既不等宽
	# 也不成体系(2026-09-13 视觉评析)。按钮本身够宽,标签不必再自己凑宽度。
	# ★ 设置/信息属「选项」组,比开始游戏组再小一档(560×76)。
	var settings_btn := UiFactory.menu_button("设 置", 32, Vector2(560, 76))
	settings_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/settings_menu.tscn"))
	var ver_btn := UiFactory.menu_button("信 息", 32, Vector2(560, 76))
	ver_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/info_menu.tscn"))
	# 退出用弱化变体:常态描边与文字都压暗一档,不与「单人模式」抢注意力。
	# 尺寸与 Beta 同(640×88),弱化只在颜色上表达。
	var quit_btn := UiFactory.menu_button("退 出", 32, Vector2(640, 88), "quiet")
	quit_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().quit())
	# 联机入口收成一颗后,「开始游戏」组按 单人 → 多人 → Beta 排列。★ 显示次序由
	# add_child 的次序决定;下面返回的数组同时是**浮现动画**的次序,两处必须一起改 ——
	# 且**次序要一致**(数组里 Beta 排在设置/信息**之前**,与屏幕上的上下位置同序),
	# 否则淡入会从下往上跳。
	for b in [start_btn, multi_btn, beta_btn]:
		play_group.add_child(b)
	for b in [settings_btn, ver_btn]:
		opt_group.add_child(b)
	box.add_child(quit_btn)
	# ★★ 返回的是**整列的浮现序列**,不是"按钮清单" —— 判据是**屏幕上的从上到下次序**,
	#    分隔线**按它在列里的位置插进去**,与按钮同款(同样的 0.16 节奏)。漏掉分隔线 ⇒
	#    一进菜单它们就全亮着,而按钮还在一个个淡入(用户 2026-10-03 报的现象)。
	#    屏幕上从上到下:单人 → 多人 → Beta →[分隔线]→ 设置 → 信息 →[分隔线]→ 退出。
	#    ⚠ 日后在 `box` 里插任何**静态**元素(副信息行之类),也必须按它在列里的位置补进这里。
	return [start_btn, multi_btn, beta_btn, sep_a, settings_btn, ver_btn, sep_b, quit_btn]


# 浮现动画:标题与版本号先出(淡入),其余元素(按钮 **与分隔线**)按序列依次淡入。
# ★ 参数名是 `sequence` 而不是 `buttons`:它按**屏幕次序**混装按钮与静态元素(见
#   `_build_menu_buttons` 末尾那条)。`_emerge` 只写 `modulate.a` —— 任何 Control 都支持。
func _play_emerge(title: Label, ver: Label, sequence: Array) -> void:
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	var delay := 0.9
	for c in sequence:
		_emerge(c, delay, 0.5)
		delay += 0.16


# 一组按钮:组内紧凑(20 → **28**),组与组之间靠外层 VBox 的 separation(**48**)+ 分隔线拉开。
# ★ 2026-10-03:14/34 → 20/48 → 20/36(第二批加了分隔线,组间空档改由线来表达)
#   → **28/48**(第三批,用户:「margin 和 padding 还是不够」,两档各约 +35%)。
#   ★ 组间那 48 是**分隔线上下各一份**(视觉空档 ≈ 48+2+48);组内 28 只在按钮之间。
func _btn_group() -> VBoxContainer:
	var g := VBoxContainer.new()
	g.add_theme_constant_override("separation", MENU_ITEM_GAP)
	return g


# 元素浮现:延迟后淡入。按钮由容器管理布局,只做透明度。
func _emerge(c: Control, delay: float, dur: float) -> void:
	c.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(c, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_SINE)


func _on_single_pressed() -> void:
	Sfx.play("ui")
	if _sp_panel != null:
		_sp_panel.visible = not _sp_panel.visible
		return
	_sp_panel = _fill_sp_panel(SP_PANEL_SCENE.instantiate() as PanelContainer)
	_ui_layer.add_child(_sp_panel)


# ── 单人开局面板(禁用武器:勾选 = 本局不可用)────────────────────────────
# 场景(`ui/screens/sp_launch_panel.tscn`)**只给骨架**(根节点的锚点/名字/居中定位),
# 内容与皮全在这里建:
#   · 皮 = `UiFactory.skin_menu_panel()`(外深线 + 内亮线,方向 B 的凿刻感)。**必须先套皮
#     再取 `Body`** —— 内容只有加进 `Body` 才吃得到面板内边距(加在外层等于 padding 失效、
#     内容直接顶到外线上,而画面上只表现为"挤",**不报错**)。
#   · 层级与其余两屏(创建房间弹层 / 设置页)同一套:标题 = 同款标题带、主行动 = 琥珀(gold)、
#     次要动作 = quiet、面板 = 同款凿刻边。

# 面板四周的内边距(与 `UiFactory.menu_panel()` 的默认档一致 —— 三屏同一个呼吸量)。
const SP_PANEL_PADDING := Vector2(64, 46)
# 面板内**大块之间**(标题带 / 选图 / 禁用武器 / 按钮行)的间距。
const SP_BLOCK_GAP := 28
# 禁用武器一栏里**勾选行之间**的间距(行挤在一起与贴边是两件事,两个都要治)。
const SP_CHECK_GAP := 20
# 按钮行里两颗并排按钮的间距。
const SP_BUTTON_GAP := 28
# 内容侧最小宽度(两侧内边距另计)。
const SP_PANEL_MIN_W := 560.0

func _fill_sp_panel(panel: PanelContainer) -> PanelContainer:
	UiFactory.skin_menu_panel(panel, SP_PANEL_PADDING)
	var body := panel.get_node("Body") as Container
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(SP_PANEL_MIN_W, 0)
	vb.add_theme_constant_override("separation", SP_BLOCK_GAP)
	body.add_child(vb)

	# 面板标题 = 同款标题带(与「创 建 房 间」/「加入房间」同一个味道)。
	vb.add_child(UiFactory.header_strip("—— 单人开局 ——", 48))

	# 选图:每张卡带一版**开局地形简略图**(由 MapCatalog 从 .cyrm 现画,不是美术资源)
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	# 区块标题 = 同款标题带(小一号:它是面板**内**的分区,不与面板标题抢视线)。
	vb.add_child(UiFactory.header_strip("禁用武器(勾选 = 本局不可用)", 32))

	var checks: Array[CheckButton] = []
	var check_list := VBoxContainer.new()
	# ★ 名字是**公开契约**:`menu_weapon_grid_probe` 按这个名字在面板子树里找勾选列
	#   (它不写死路径 —— 版式再挪一层也不会瞎)。改名前先看那个探针。
	check_list.name = "CheckList"
	check_list.add_theme_constant_override("separation", SP_CHECK_GAP)
	vb.add_child(check_list)
	var ids: Array[int] = WeaponRegistry.all_ids()
	for type_id: int in ids:
		var cb := CheckButton.new()
		# ★ 不带编号:那个数字**看起来**是键位,而 type_id 与键位毫无关系(用户 2026-09-25 定)。
		cb.text = WeaponRegistry.name_of(type_id)
		cb.icon = WeaponIcons.silhouette(type_id)   # 纯白像素剪影,便于辨认
		cb.expand_icon = false
		UiFactory.style_check(cb, 32)
		cb.button_pressed = Settings.sp_disabled_weapons.has(type_id)
		checks.append(cb)
		check_list.add_child(cb)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", SP_BUTTON_GAP)
	vb.add_child(row)
	# 单机开局面板(本屏的另一处按钮)同样走菜单按钮工厂 —— 它与主菜单同屏出现,
	# 不换的话两套描边会在同一屏里并排。
	# ★ 尺寸**必须显式传**:这两颗与主菜单那六颗不是同一处版式 —— 它们在弹层里**并排**
	#   (HBox),而 `menu_button` 的默认值已涨到 640 ⇒ 不写就是 640+640+28 = 1308 宽,
	#   把这块弹层从 ~990 撑到 ~1400。420 是这两个并排按钮原本的宽度,高度随新内边距抬到 88
	#   (`_btn_box` 的上下内边距现在是 20 ⇒ 32 号字按钮的最低高度 = 32 + 40 = 72;这里给 88
	#   是**主行动那两颗**的版式取值,比最低高度再高一档)。
	# 主行动走 gold(与「创 建 房 间」同色)、返回走 quiet。
	var go := UiFactory.menu_button("开 始 探 索", 32, Vector2(420, 88), "gold")
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				# ★ 必须是 `ids[i]`:**不能**写成 `i + 1`。序号只在"json 恰好是 1..N 的
				#   稠密连续段"时才等于 type_id —— 一旦重排 json 或留下空洞,`i + 1` 会
				#   **静默禁用错的那把枪**(而今天 ids == [1..6],两种写法同结果,正是
				#   "改了不报错"的那一类)。
				Settings.sp_disabled_weapons.append(int(ids[i]))
		Settings.sp_map_path = picker.selected   # "" = 随机
		Settings.save()
		RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
		_enter_level0())
	var back := UiFactory.menu_button("返回", 32, Vector2(420, 88), "quiet")   # 尺寸理由同上
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel
