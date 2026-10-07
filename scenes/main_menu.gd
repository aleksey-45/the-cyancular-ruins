extends Control
# 主菜单(像素 UI):粗体大标题 + 模式按钮浮现动画,场景是裸 Control,UI 全在代码里建。
# 左下角显示版本号(分支名 + git 提交序号);「信 息」按钮切到独立整页(提交历史/团队/致谢)。
# 「单人模式」弹出开局面板(勾选本局禁用武器),确认后进 Level0。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源);字号必须是 16 的倍数。

# 自动探针节明确提示:挂在树根上跨场景存活,靠这个名字做「已挂过就别再挂」的幂等判据
const PROBE_NODE_NAME := "MenuAutotestProbe"
const TUNNEL_FEEL_NODE_NAME := "TunnelFeelProbe"   # P2P 隧道网络性能基准测试探针节点名

var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)

# 注意： 静态 UI 结构定义在 `scenes/main_menu.tscn` 里(2026-10-03 从代码迁出,见 `tools/gen_menu_scene.gd`)。
#   判据是**外观不变** —— 与改前逐像素比对:**差异 0 / 2764800**。
#   - 那个 `.tscn` 里多一层**全屏 `UIRoot` Control**:`CanvasLayer` **切断** Control 的 theme
#     传播链(引擎 `ThemeOwner::_get_next_owner_node` 遇到既非 Control 也非 Window 的父节点
#     直接返回 null) ->  Theme 挂在 CanvasLayer 自己身上是**够不到**里面那些控件的。
#     全屏 Control 作壳是**惰性**的:子节点的锚点相对它的矩形,而它的矩形就是视口。
#   - 背景(`Bg`)的**材质仍由代码挂** —— 那张地形贴图是运行时烘的(`TerrainAtlas`),
#     进不了 `.tscn`;导出的基础结构时还特意清空了材质,免得整张 4800×3200 被内嵌进去。
@onready var _ui_layer: CanvasLayer = %UILayer
@onready var _bg: ColorRect = %Bg
@onready var _title: Label = %Title
@onready var _ver: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox

# ── 背景镜头运动的状态(见 _process)──
var _bg_mat: ShaderMaterial = null       # 背景 ColorRect 的材质(null = 没建出来)
var _bg_cells := Vector2(150.0, 100.0)   # 背景那张图的格数(从纹理尺寸反推;随机取点要用)
var _rng := RandomNumberGenerator.new()  # 路径随机源(种子固定  ->  可复现)
var _seg_t := 0.0                        # 当前段已走过的秒数
var _seg_from := Vector2.ZERO            # 当前段起点(格坐标)
var _seg_to := Vector2.ZERO              # 当前段终点(格坐标)
var _seg_index := 0                      # 段序号(奇偶决定角度是 0→120 还是 120→0)

# 弹出面板的**基础结构框架**在场景里(容器/滚动区/标签/锚点看得见);按钮与勾选框仍由
# UiFactory 建、数据由 _fill_* 填 —— 控件进场景就得在使用处补 style_control +
# style_button,等于把「控件工厂唯一来源」这条纪律散回各处。
const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")

# ── 背景:**真实地形**(与游戏同一份图集)+ 鱼眼漂移(没有任何实体)──
# 用户要求:背景是"世界"本身在以一种奇怪的鱼眼镜头缓慢漂移/移动,**不放任何实体**
# (没有玩家/敌人/子弹)。
# - 2026-10-03 改判:背景必须是**真实地形** —— 砖是 `structure.png` 的砖、水是水、
#   树叶是树叶,像"透过一扇窗看进那个世界"。旧实现走 `MapCatalog.build_image()`,
#   而那套的语义是**选图面板的示意缩略图**(每格一个平色块) ->  放大多少都是色块,
#   不是那个世界。现在改走 `TerrainAtlas.bake_map_image()`:**同一个** `TerrainAtlas`
#   给 `Level0` 生成 TileSet、也在这里把地图烘成 Image  ->  背景与游戏是同一套像素。
#
# ── 取景/缩放(具名常量,方便"再放大一点")──
# 一句话:**一格 = 72 屏幕像素 = 玩家视角(48px/格)的 150%**;屏幕约 27 格宽。
#   - `BG_VIEW_CELLS = 26.6667` —— 屏幕**横向**铺 26.67 格  ->  1920 / 26.67 = **72 屏幕像素/格**。
#     - 参照:对局的玩家镜头 = 64px × `PlayerParams.cam_zoom`(0.75)= **48px/格、约 40 格宽**
#      ->  这里是它的 **1.5 倍**(用户 2026-10-03 的口径:500% → 200% → **150%**)。
#   - 注意： **像素完美这一档有个取舍(照实登记)**:72 / `BG_CELL_PX`(32)= **2.25×**(非整数)
#      ->  源砖的一个像素会时而占 2 个、时而占 3 个屏幕像素,砖缝**粗细略有不均**
#     (2.25 是"2 或 3",不是随机 —— 但每隔一个砖缝宽一点是看得出来的)。
#     - 整数倍的邻近档只有 **`BG_VIEW_CELLS = 30.0`(64px/格 ≈ 133%)** 与
#       **`BG_VIEW_CELLS = 20.0`(96px/格 = 200%)**。**要不要为了像素完美牺牲"150%"这个数,
#       留给用户定** —— 改 `BG_VIEW_CELLS` 一个常量即可。
#   - `BG_CELL_PX = 32` —— **烘图**分辨率:游戏里 64px 的一格烘成 32 图像像素
#     (= **源砖的分辨率**:`structure.png` 一块砖就是 32×32,游戏里按 2× 画成一格)。
#     整张 newfactory(150×100 格)= 4800×3200 ≈ 61MB。
#     注意： 为什么烘图分辨率**不**直接等于屏幕的 96(最直觉的做法):那会得到
#     150×96 × 100×96 = 14400×9600 ≈ 553MB,主菜单背不动(Image + 上传 GPU 各一份)。
#     - 而"像素完美"(砖缝粗细均匀)要求的**不是**烘图分辨率等于屏幕分辨率,只要求
#     **屏幕像素/格 ÷ 烘图像素/格 是整数**:
#       – 图集的子格是 16 图像像素,但那是**源 8×8 象限最近邻放大 2×** 来的
#          ->  真正的源分辨率是 **8px/子格 = 32px/格**;
#       – 烘到 32px/格 时每个子格 = 8px,**正好等于那个 8×8 源象限本身**(放大 2× 再缩回去无损);
#       – 屏幕再放大 **整数 3×**  ->  每 1 个源像素落到 3×3 个屏幕像素上。
#     (烘图本身走的是**源分辨率**那条:32px/格 时每个子格 = 8px = 源砖那个 8×8 象限,
#      不是从 16px 图集层再缩。)
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
const BG_VIEW_CELLS := 26.6667
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"
# 背景**虚焦**半径(屏幕像素)。-  与取景是两个独立量:模糊是"镜头虚焦",取景是"看多远"。
# 4 是"看得出是虚的、又不至于把砖整块消除差异"的值(150% 下一格 72px,砖面本身是平色,
# 4px 的高斯主要糊的是砖缝/梯子横档这些高频边)。
const BG_BLUR_RADIUS_PX := 4.0

# ── 镜头运动:「随机路径段」循环(用户 2026-10-03 的最新口径,其余描述以本条为准)──
#   1. 取一个随机目标点(在地图的**中央 60%** 那块矩形里,两轴都是);
#   2. **平滑移动**过去(缓入缓出,到点速度 → 0);
#   3. **同一段时间里**视角旋转 `SEG_TURN_DEG`;
#   4. 到点后重新生成下一段。
# - 为什么不住在 shader 里:GDShader 没有随机数、也没有"段"的概念;运动学住脚本,
#   每帧把 `view_center`(视野中心,格坐标)与 `rot_angle` 两个 uniform 传入去。
# - 角度口径(用户 2026-10-03 订正过一次,以本版为准):
#   ① **角度在 0° 与 120° 之间**(不是每段累加 +120°)。用户原话:"是零到 120,不是 120"。
#       ->  段 1:0°→120°、段 2:120°→0°、段 3:0°→120° …… **来回摆**。
#      这样三条同时成立:角度**始终落在 [0,120]**、段间**连续不跳**、且与"每段重新取路径"同拍。
#      (若让每段都从 0° 重新开始,段间会从 120° 跳回 0° —— 那正是"不许跳"禁止的。)
#   ② **"旋转比移动缓慢很多"落在段时长与缓动曲线形状上**(两者同长,没法靠时长差表达):
#      位移走缓入缓出(smoothstep,峰值速度 1.5 倍);旋转走**梯形速度剖面**
#      (两端速度 0、中间匀速段最长,峰值只有 1.33 倍) ->  **比位移更接近线性**,
#      观感上是"移动先到位、转动还在慢慢走",而不是"两者一起加速又一起停"。
const SEG_MIN_FRAC := 0.20     # 目标点的取值范围:地图的 20%~80%(两轴  ->  中央 60% 的矩形)
const SEG_MAX_FRAC := 0.80
# 每段时长(秒)—— **它就是"移动速度"的单一旋钮**:位移与旋转同段,改它两者一起变。
# - 2026-10-03 用户连提三次降速:15.0 → 21.4(70%)→ 32.0 → **48.0s**(再降 2/3)。
#   最后一次刻意走**大档位**而不是再乘一次小数 —— 用户是靠"看着太快"逐步逼近的,
#   一步一个台阶比连续微调好收敛。
#   - 连带效果(照实说):旋转也同比例变慢(120°/段  ->  **3.75°/s**,原 5.6°/s);
#     "旋转比移动慢很多"这个**比例**没变,只是两者绝对值一起降。**刻意只动这一个常量** ——
#     一次一个变量,用户才好接着调。-  要再慢就继续加这个数。
# 当前量级(换算到 150% 取景 = 一格 72 屏幕像素):平均位移 ≈36 格 / 48s ≈ **54px/s**
# (峰值 ≈81px/s);转角 120°/段 = **2.5°/s**;一整圈 = 3 段 ≈ **144s**。
# - 中间那 36 格/段是怎么来的:目标点两轴各均匀落在 20%~80% 的矩形(newfactory 150×100 格
#    ->  列 30~120、行 20~80),两点间平均距离 ≈36 格。**最坏情况 ≈108 格/段**(≈243px/s 峰值)。
const SEGMENT_SEC := 48.0
# 每段**端点**的角度(度):在 0° 与 120° 之间来回摆。-  用户明确提示"零到 120"  ->  原样实现。
# 若嫌转太快,**先降这个**(降到 60  ->  2.8°/s),不要去改段时长 —— 那会连位移一起拖慢。
const SEG_TURN_DEG := 120.0
# 旋转曲线的"变速段"占整段的比例(梯形速度剖面,见 _trapezoid):
# 0.25  ->  两端各 25% 用来加减速、中间 50% 匀速,峰值速度只有平均的 1/(1-0.25) ≈ **1.33 倍**。
# - 它比位移的 smoothstep(峰值 1.5 倍、且峰值被 SEG_MOVE_BIAS 前移)**更接近线性** ——
#   这正是"旋转比移动缓慢/更稳"那半句的落实处。-  两端速度**严格为 0**:0↔120 每次反向
#   都发生在速度为 0 的时刻,所以反向处**不会出现折角**(这是"不许跳"在角度上的落实)。
const SEG_TURN_EDGE_FRAC := 0.25
# 位移缓动曲线的偏置(见 _process):`s = smoothstep(u) ** SEG_MOVE_BIAS`。
# 1.0 = 对称的缓入缓出;取 **0.8**  ->  速度峰值略微前移、"到得更早一点、然后慢慢蹭到点上" ——
# 这正是"移动先到位、转动还在慢慢走"里那半句。-  两端速度仍严格为 0(0^0.8 = 0),故不跳。
const SEG_MOVE_BIAS := 0.8
# 路径随机数种子固定  ->  "随机"但**每次进菜单是同一串路径**(可复现、可对图)。
const SEG_PATH_SEED := 20261003
func _ready() -> void:
	# ── 发布产物自检:武器注册表到底从包里读到了几条 ──
	# - 为什么必须在**产物侧**量:`data/weapons.json` 进不进 `.pck` **只由一次真导出回答**
	#   —— 静态只能论证到"导出过滤器只跳 `TextFile`,而 `.json` 是 `JSON` 类型"
	#   (`include_filter` 里的 `data/*.json` 是**保险不是机制**)。真没进包时
	#   `WeaponRegistry._ensure_loaded()` 只打**一条** `push_error`、**只在 stderr**、
	#   **不影响退出码**  ->  光看"游戏起得来"是看不出来的。
	# - 开关写在 `--` 之后(与 `--netstat` / `--pickup-diag` 相同机制 —— 写在前面会被 Godot
	#   当自己的参数丢掉、**静默失效**),且**默认关**  ->  生产行为一字不变。
	# - 消费者是 `tools/build_release.py` 的产物冒烟(`check_weapon_registry`):它拿仓库里
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

	_build_ui()

	# 菜单流转自动探针(规格 §6 的 L4 验收项):命令行 `--autotest-sp|mp|set|level` 时,
	# 把探针挂到树根(而非本场景)——它要穿越 change_scene 存活。平时零开销。
	# 缺文件守卫:探针文件可能缺失(开发分支尚未落该文件、或有人手删)时静默跳过,不让主菜单崩。
	# 注:「发布版会裁掉 tests/」**不是**这条守卫的理由——export_presets.cfg 是
	# export_filter="all_resources",tests/ 会一起打包进发布包,真实理由是文件可能不存在。
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

	# P2P 隧道多实例网络性能基准测试探针（tests/probe/tunnel_feel_probe.tscn，由 tunnel_feel_probe.sh 编排调度）。
	# 在二进制导出包中，命令行无法动态覆盖启动场景路径，因此由主菜单检查命令行参数后挂载测试探针。
	# 仅在显式指定测试参数时生效，常规游戏启动不受影响。
	if _tunnel_feel_requested():
		if not get_tree().root.has_node(NodePath(TUNNEL_FEEL_NODE_NAME)) \
				and ResourceLoader.exists("res://tests/probe/tunnel_feel_probe.tscn"):
			var tf: Node = (load("res://tests/probe/tunnel_feel_probe.tscn") as PackedScene).instantiate()
			tf.name = TUNNEL_FEEL_NODE_NAME
			get_tree().root.add_child.call_deferred(tf)


# 检查命令行是否显式请求运行网络性能基准测试（要求同时包含 --side 与 --seconds 参数）
func _tunnel_feel_requested() -> bool:
	var side := false
	var secs := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--side="):
			side = true
		elif arg.begins_with("--seconds="):
			secs = true
	return side and secs


# 单机进关卡(Level0 = 全量物理世界)。菜单是纯 UI(无世界、无大物理),普通切场景即可:
# change_scene 在这里只会销毁一棵 Control 树,不存在「销毁大世界 × 构建大世界」的同帧对撞。
# 反方向(游戏世界退役回菜单)才需要挂起式切换,见 Level0.safe_change_scene 的注释。
func _enter_level0() -> void:
	# 选图(菜单里定的,空 = 随机):-  必须在 change_scene **之前**钉进 MazeGenerator 的会话缓存
	# —— 它是静态的,活过场景切换;文件被删/改名时回落随机,不让玩家卡在旧路径上。
	MazeGenerator.set_map_file(Settings.sp_map_path if MapCatalog.is_valid_map(Settings.sp_map_path) else "")
	# - 必须跟着重算世界尺寸:启动时算的是"当时随机挑的图"(如 demo 125×75 → 8000 宽),
	#   选了别的图(如 newfactory 150×100 → 9600 宽)不重算的话环面回绕/最短路径按错边界。
	GameParameters.refresh_map_size()
	Level0.pvp_mode = false            # 复位 PvP 标志,避免上次 PvP 残留
	CombatComponent.pvp_arena = false  # 回单机恢复命中无敌帧
	get_tree().change_scene_to_file("res://scenes/level_0.tscn")


# ── 菜单 UI ──
func _build_ui() -> void:
	_build_background()
	_ver.text = AppInfo.version_string()
	_wire_menu()
	# - 浮现动画的起点:`modulate.a = 0`。**必须在 `_ready` 里设**,不能靠 `.tscn` 存
	#   —— 那两个值在导出时是"动画跑到一半"的瞬时值(a≈0.004),而 `_ready` 先于第一帧,
	#   在这里归零等价于旧代码"建出来就归零"。
	_title.modulate.a = 0.0
	_ver.modulate.a = 0.0
	_play_emerge(_title, _ver, _menu_sequence())


# 六颗按钮的接线。-  文案/尺寸/档位一个都没动(四条自检 + `kh_l4_visual_probe` 按文案找按钮),
#   它们现在住在 `.tscn` 里(`theme_type_variation` 就是原来 `menu_button` 的第 4 个实参)。
func _wire_menu() -> void:
	%StartBtn.pressed.connect(_on_single_pressed)
	# 注意： 联机入口只剩这一颗(2026-10-03 三合一,统一大厅 `mp_lobby`):1v1 / 3v3 / 大乱斗
	#   都在那一个页面里按筛选区分,菜单不再按模式分列三颗按钮。
	#   它一律走 `PvpSession.reset()`(每次进页复位 role/spawn/map_path),
	#   **不要**在这里写任何清凭据的东西:回局凭据要活过"回主菜单"这一步(那正是路径乙的意义),
	#   而模式归属改由各大厅页记房号那一拍(`note_room(code, mode)`)确定。往 `reset()` 里加回
	#   清凭据那四行、或在这里直接清凭据 = 玩家从对局回主菜单、再按这个入口进来时凭据被抹掉
	#   → 自己那间"对局中"的房恒为灰、回不去(**而一行报错都没有**) —— 这就是 C1。
	#   `reconnect_smoke` 有源码级断言钉着它。
	%MultiBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()   # 不碰回局凭据(见 pvp_session.gd 的 reset 注释)
		get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn"))
	# Beta(2026-09-28,用户指定放在联机入口下面):以后所有实验性玩法都从这个入口进。
	%BetaBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/beta_menu.tscn"))
	%SettingsBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/settings_menu.tscn"))
	%VerBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/info_menu.tscn"))
	%QuitBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().quit())


# 注意： 浮现序列 = `MenuBox` 子树里**屏幕上从上到下**的次序,由树的形状**推**出来
#   (组展开成组员,分隔线/退出键按它们在列里的位置插进去)。
#   旧实现是手写一张清单 `[start, multi, beta, sep_a, settings, ver, sep_b, quit]`,并在注释里
#   要求"日后往列里插静态元素必须同步补进来" —— 现在**这条要求消失了**:插进 `.tscn` 就自动
#   按位置参与动画。漏掉分隔线的老症状(一进菜单两条线全亮,而按钮还在一个个淡入)不会再出现。
func _menu_sequence() -> Array:
	var seq: Array = []
	for c in _menu_box.get_children():
		if c is VBoxContainer:
			for g in c.get_children():
				seq.append(g)
		else:
			seq.append(c)
	return seq


# 背景:真实地形图铺满全屏,由 shader 做鱼眼 + 漂移 + 压暗/暗角(见 menu_fisheye.gdshader)。
# - 底 ColorRect 的原色是 `UiFactory.C_BG`(**调色板 token,不是新字面量**):shader 正常时
#   fragment 覆写整块 COLOR,这层底不可见;万一 shader 载入失败,留下的是一块与页面底同色
#   的深底(而不是 ColorRect 默认的**白色** —— 那会是一屏白得读不出字的菜单)。
# - 空气的底色用 `MapCatalog.BG`(与选图缩略图同底色):它比 `C_BG` 略亮一点,烘出来的
#   地形才有"背景"可依(纯黑会把砖缝读成噪点);而 shader 的 dim/vignette 会把它压到
#   和原来那层底差不多的亮度  ->  文字可读性不依赖这一处取色。
func _build_background() -> void:
	var bg := _bg
	var sh: Shader = load(BG_SHADER)
	if sh != null:
		# 真实地形图:地图子格纹理 × TerrainAtlas 的图集(= Level0 生成 TileSet 的同一份)。
		# - 底色 = 对局那个清屏色(`TerrainAtlas.SKY_COLOR`),不是选图缩略图那层近黑 ——
		#   用户 2026-10-03:"背景颜色不对(要和局内一致)"。可读性靠 shader 的 dim 换。
		# - 这里**没有**出生点标记要抹 —— 烘的是地形本身,不画任何实体/标记。
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
	# - `bg` 就是 `.tscn` 里那个 `Bg` —— 它自己已经在 `UIRoot` 下,**不再 add_child**。
	#   材质由这里挂(那张地形贴图是运行时烘的,进不了 `.tscn`;导出的基础结构时也特意清空了材质)。


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


# 背景镜头运动:每帧把 `view_center`(视野中心,格坐标)与 `rot_angle` 传入 shader。
# - "不许跳"这条硬约束在两处都成立:
#   - **位置**:段末 u→1 时位移 s→1(恰好落在 `_seg_to`),而下一段从 `_seg_from = 上一段的
#     `_seg_to`、s→0 出发  ->  位置连续;且 smoothstep 在两端导数为 0  ->  速度也连续(不会"一顿")。
#   - **角度**:0→120 与 120→0 交替,**端点角度重合**(上一段结束在 120°,下一段也从 120° 出发)
#      ->  角度连续;且梯形剖面在两端速度同样为 0  ->  反向处是"停稳了再往回走",没有折角。
# - 曲线形状(见常量区 ②):位移 = `smoothstep(u) ** SEG_MOVE_BIAS`(缓入缓出、峰值略前移),
#   旋转 = **梯形速度剖面**(两端变速、中段匀速) ->  观感上是"移动先到位、转动还在慢慢走"。
func _process(delta: float) -> void:
	if _bg_mat == null:
		return
	_seg_t += delta
	while _seg_t >= SEGMENT_SEC:
		_seg_t -= SEGMENT_SEC        # 保留余数,不累积误差
		_seg_index += 1
		_seg_from = _seg_to          # 下一段从上一段的终点出发  ->  位置不跳
		_seg_to = _random_target()
	var u := clampf(_seg_t / SEGMENT_SEC, 0.0, 1.0)
	var s: float = pow(smoothstep(0.0, 1.0, u), SEG_MOVE_BIAS)
	var e := _trapezoid(u)
	# 偶数段 0→120,奇数段 120→0(见常量区 ①:角度只在 [0,120] 之间来回)
	var turn: float = e if (_seg_index % 2) == 0 else 1.0 - e
	_bg_mat.set_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	_bg_mat.set_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))


# 梯形速度剖面的**位移**曲线:0 → 1,两端速度 0、中间匀速(占 1-2*edge)。
# 面积恒为 1  ->  s(0)=0、s(1)=1;峰值速度 = 1/(1-edge)(edge=0.25  ->  1.33 倍)。
# - 用它而不是再一个 smoothstep,是因为它**更接近线性**(峰值 1.33 < 1.5),
#   且两端速度同样为 0 —— 见常量区 ②。
static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)               # 匀速段的速度(面积归一)
	if u < a:
		return v * u * u / (2.0 * a)             # 加速
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)   # 减速
	return v * (a * 0.5 + (u - a))               # 匀速


# ── 标题 / 版本号 / 按钮列的**版式**都在 `.tscn` 里(2026-10-03 迁移)──
# 这里只留下几条**改之前先想清楚**的既有裁定:
# - 大标题(128 号、`C_ACCENT`、**无描边**、锚 `PRESET_CENTER_TOP` + `offset_top = 160`):
#   2026-10-03 用户删掉副信息行、标题从 96 放大到 **128**、并**去掉描边** —— 于是那里
#   **一个描边/阴影 override 都没有**。-  用户是知情取舍(更亮更干净的背景必然压不住浅色字),
#   **别**再"为了可读性"把描边/外环/底板加回来。
# - 版本号(16 号、`C_TEXT_DIM`、锚 `PRESET_BOTTOM_LEFT`):原先居中挂在标题正下方,
#   位置与字号都让它读成标题的「副标题」、和真正的模式按钮抢视线(2026-09-13 视觉评析)。
#   文本由 `_build_ui()` 灌(`AppInfo.version_string()`,`--nover` 的处理在它里面,统一集中处理入口)。
# - 按钮列(`MenuBox`,锚 `PRESET_CENTER` + `offset_top = 170`):三组
#   「开始游戏(单人/多人/Beta)」/「选项(设置/信息)」/「退出」,组间两条分隔线。
#   注意： **别再加回 `menu_panel()` 把整列框起来** —— 撤框是用户明确要求,不是审美取舍。
#   - 尺寸/档位:单人 720×104 `accent`(全页唯一"最前")、多人 640×88(默认)、
#     Beta/退出 640×88 `quiet`、设置/信息 560×76。
# 浮现动画:标题与版本号先出(淡入),其余元素(按钮 **与分隔线**)按序列依次淡入。
# - 参数名是 `sequence` 而不是 `buttons`:它按**屏幕次序**混装按钮与静态元素
#   (由 `_menu_sequence()` 从树序推出)。`_emerge` 只写 `modulate.a` —— 任何 Control 都支持。
func _play_emerge(title: Label, ver: Label, sequence: Array) -> void:
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	# - 2026-10-04 加速(用户「主页面淡入动画速度加快」):原 0.1/1.1 / 首延迟 0.9 / 步进 0.16 / 单个 0.5
	#    ->  整屏约 2.5s 才出齐;现 0.6 / 0.45 / 0.09 / 0.28  ->  约 1.35s。**次序与形状一字未动**。
	var delay := 0.45
	for c in sequence:
		_emerge(c, delay, 0.28)
		delay += 0.09


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
# 场景(`ui/screens/sp_launch_panel.tscn`)**只给基础结构框架**(根节点的锚点/名字/居中定位),
# 内容与皮全在这里建:
#   - 皮 = `UiFactory.skin_menu_panel()`(外深线 + 内亮线,方向 B 的凿刻感)。**必须先套皮
#     再取 `Body`** —— 内容只有加进 `Body` 才吃得到面板内边距(加在外层等于 padding 失效、
#     内容直接顶到外线上,而画面上只表现为"挤",**不报错**)。
#   - 层级与其余两屏(创建房间弹层 / 设置页)同一套:标题 = 相同标题栏、主行动 = 琥珀(gold)、
#     次要动作 = quiet、面板 = 相同边框样式。

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

	# 面板标题 = 相同标题栏(与「创 建 房 间」/「加入房间」保持统一视觉风格)。
	vb.add_child(UiFactory.header_strip("—— 单人开局 ——", 48))

	# 选图:每张卡带一版**开局地形简略图**(由 MapCatalog 从 .cyrm 现画,不是美术资源)
	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	# 区块标题 = 相同标题栏(小一号:它是面板**内**的分区,不与面板标题抢视线)。
	vb.add_child(UiFactory.header_strip("禁用武器(勾选 = 本局不可用)", 32))

	var checks: Array[CheckButton] = []
	var check_list := VBoxContainer.new()
	# - 名字是**公开契约**:`menu_weapon_grid_probe` 按这个名字在面板子树里找勾选列
	#   (它不写死路径 —— 版式再挪一层也不会瞎)。改名前先看那个探针。
	check_list.name = "CheckList"
	check_list.add_theme_constant_override("separation", SP_CHECK_GAP)
	vb.add_child(check_list)
	var ids: Array[int] = WeaponRegistry.all_ids()
	for type_id: int in ids:
		var cb := CheckButton.new()
		# - 不带编号:那个数字**看起来**是键位,而 type_id 与键位毫无关系(用户 2026-09-25 定)。
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
	# - 尺寸**必须显式传**:这两颗与主菜单那六颗不是同一处版式 —— 它们在弹层里**并排**
	#   (HBox),而 `menu_button` 的默认值已涨到 640  ->  不写就是 640+640+28 = 1308 宽,
	#   把这块弹层从 ~990 撑到 ~1400。420 是这两个并排按钮原本的宽度,高度随新内边距抬到 88
	#   (`_btn_box` 的上下内边距现在是 20  ->  32 号字按钮的最低高度 = 32 + 40 = 72;这里给 88
	#   是**主行动那两颗**的版式取值,比最低高度再高一档)。
	# 主行动走 gold(与「创 建 房 间」同色)、返回走 quiet。
	var go := UiFactory.menu_button("开 始 探 索", 32, Vector2(420, 88), "gold")
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				# - 必须是 `ids[i]`:**不能**写成 `i + 1`。序号只在"json 恰好是 1..N 的
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
