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
var _bg_mat: ShaderMaterial = null      # 背景 ColorRect 的材质(null = 没建出来)
var _motion_noise: FastNoiseLite = null # 漂移与转速调制共用一张噪声(不同行 = 去相关)
var _motion_t := 0.0                    # 噪声时间轴(秒,随真实时间推进)
var _bg_angle := 0.0                    # 旋转角(逐帧积分 ⇒ 角速度连续 ⇒ 永不跳)

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
# 一句话:**一格 = 96 屏幕像素 = 玩家视角(48px/格)的 200%**;按"源分辨率烘 + 整数 3× 放大"走。
#   · `BG_VIEW_CELLS = 20.0` —— 屏幕**横向**铺 20 格 ⇒ 1920 / 20 = **96 屏幕像素/格**。
#     ★ 参照:对局的玩家镜头 = 64px × `PlayerParams.cam_zoom`(0.75)= **48px/格、约 40 格宽**
#     ⇒ 这里是它的 **2.0 倍**(用户 2026-10-03 的口径:先要 500%,后改成 **200%**)。
#     ★ 与 `BG_CELL_PX` 是**配套的一对**:96 / 32 = **3×** 整数倍(见下)。
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
#     若改成从**图集层 16px 子格**直接烘 96px/格 = 每子格 24px = **1.5×**(非整数)⇒ 砖缝会
#     一格粗一格细。**当前实现走的是源分辨率那条**(烘图缩放比 = 32/16 的整数路径)。
#   · 想"再放大一点":只改 `BG_VIEW_CELLS`,并让它与 32 的比仍是**整数** ——
#     例 `BG_VIEW_CELLS = 10.0`(192px/格 = 6×,= 玩家视角 400%)、`15.0`(128px/格 = 4×)
#     都行;`13.33`(144px/格 = 4.5×)就会粗细不均。★ 改大了**不会糊**(最近邻),
#     只是"源像素→屏幕像素"不再是整数倍时,砖缝会有粗有细。
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
const BG_VIEW_CELLS := 20.0
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"

# ── 镜头运动:漂移 + 旋转(都喂给 shader;运动学住在脚本里,见 _process)──
# ★ 为什么不用 shader 里那串 `sin(TIME·a), cos(TIME·b)` 的李萨如:它是**周期性的** ——
#   看久一点就会发现镜头在绕同一个圈(用户 2026-10-03:"要随意一点")。改成
#   `FastNoiseLite` 采样(固定种子)⇒ 轨迹连续、永不重复、每次进菜单还是同一段(可复现)。
# ★ `drift_amp = 0.06`(半屏宽)与旧值同 —— 在 1920 上 ≈ 115px 的游走范围,
#   是"一直在慢慢晃"而不是"在跑"。★ 它是**屏幕空间**量,与 `BG_VIEW_CELLS` 无关。
const DRIFT_AMP := 0.06
# 噪声时间轴推进速率(1/s):越大晃得越快。噪声 frequency=1 ⇒ 特征时长 ≈ 1/0.15 ≈ 7s。
# 峰值速度 ≈ DRIFT_AMP × RATE × 960px ≈ 0.06×0.15×1.5×960 ≈ 13px/s(背景该有的量级)。
const DRIFT_RATE := 0.15
# 旋转:**基准**(不受噪声调制时)转一整圈的秒数。用户要"几十秒转一整圈" ⇒ 60s(=6°/s)。
# ★ 太慢就"看不出在转",太快就成了内容而不是背景;60 是这两端之间取的。
const ROT_PERIOD_SEC := 60.0
# 角速度的噪声调制深度:1.0 = 速率在 0~2× 基准之间游走(时快时慢),`0.85` ⇒ 0.15~1.85×。
# ★ 刻意**不让它穿过 0**:反向会让旋转"顿一下"(用户点名不要),而 0.85 已经足够"随意"。
const ROT_WOBBLE := 0.85
# 调制噪声的时间轴速率(1/s):越大,快慢切换越频繁。0.05 ⇒ 特征时长 ≈ 20s
# (与一整圈同量级 ⇒ 一圈里速率只缓慢地变一两次,不会抖)。
const ROT_WOBBLE_RATE := 0.05
# 噪声种子固定 ⇒ "随意"但不"每次都不一样"(每次进菜单同一段轨迹,便于对图)。
const MOTION_SEED := 20261003
# 副信息(标题与按钮之间那层空档里的一行小字)。内容刻意是**静态标语**:不是版本号
# (那会随构建漂,而左下角已有一行确定性的版本号给 `--nover` 自动探针读),也不是当前
# 模式提示(那一行在别处)。
const TAGLINE := "环面世界 · 像素射击"


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
	var tag := _build_tagline()
	var buttons := _build_menu_buttons()
	_play_emerge(title, ver, tag, buttons)


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
		_bg_mat = mat
		bg.material = mat
		# 运动噪声:漂移的两个轴取**不同行**、转速调制取第三行 ⇒ 三者互不相关。
		_motion_noise = FastNoiseLite.new()
		_motion_noise.seed = MOTION_SEED
		_motion_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_motion_noise.frequency = 1.0
	_ui_layer.add_child(bg)


# 背景镜头运动:每帧把 `drift_offset` 与 `rot_angle` 喂给 shader。
# ★ 三条硬约束(用户 2026-10-03):
#   ① 平滑 —— 任何一帧都不许跳:漂移是**噪声函数取值**(本身连续),角度是**逐帧积分**
#      (角速度连续 ⇒ 角度 C¹)。绝不用 randf() 逐帧扰动。
#   ② 慢 —— 见上面几个常量;它是背景,不是内容。
#   ③ 非周期 —— 噪声不是正弦,不会绕回同一个圈(这就是"随意"的来源)。
# ★ 不在 shader 里算的原因:GDShader 没有噪声函数,而叠正弦终究会周期。
func _process(delta: float) -> void:
	if _bg_mat == null:
		return
	_motion_t += delta
	# 漂移:两个轴取噪声的**不同行**(0 / 137),互不相关 ⇒ 二维游走不像沿某条直线来回。
	_bg_mat.set_shader_parameter("drift_offset", Vector2(
			_motion_noise.get_noise_2d(_motion_t * DRIFT_RATE, 0.0),
			_motion_noise.get_noise_2d(_motion_t * DRIFT_RATE, 137.0)) * DRIFT_AMP)
	# 旋转:角速度 = 基准 × 噪声调制(0.15~1.85×),积分成角度。`maxf` 兜底保证不反向。
	var wobble := 1.0 + ROT_WOBBLE * _motion_noise.get_noise_2d(_motion_t * ROT_WOBBLE_RATE, 271.0)
	_bg_angle += (TAU / ROT_PERIOD_SEC) * maxf(0.1, wobble) * delta
	_bg_mat.set_shader_parameter("rot_angle", _bg_angle)


# 大标题:中央浮现(描边同色加粗)
func _build_title() -> Label:
	var title := UiFactory.label("The Cyancular Ruins", 96, UiFactory.C_ACCENT)
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_outline_color", UiFactory.C_ACCENT)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	title.offset_top = 200.0
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


# 副信息行:填标题与按钮列之间那层空档。小字(`C_TEXT_DIM`)、字号 16、居中。
# ★ 位置在**标题与按钮之间**(y 356~392),不是标题正下方的"副标题" —— 旧的版本号
#   当年就因为挂在标题正下方而被读成副标题、与模式按钮抢视线(2026-09-13 评析),别重蹈。
func _build_tagline() -> Label:
	var tag := UiFactory.label(TAGLINE, 16, UiFactory.C_TEXT_DIM)
	# 深色细描边:副信息压在**会漂移的地图**上,总有几帧底下是浅色的墙/箱子 ——
	# 描边用 `C_BG`(页面底色,不是新色值),让它在任何背景上都能读出来。
	# ★ 描边宽度 4(≈两侧各 2px)是相对 16px 字号的克制值:再厚会把 1~2px 的笔画糊在一起。
	tag.add_theme_constant_override("outline_size", 4)
	tag.add_theme_color_override("font_outline_color", UiFactory.C_BG)
	tag.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	tag.anchor_left = 0.5
	tag.anchor_right = 0.5
	tag.grow_horizontal = Control.GROW_DIRECTION_BOTH
	tag.offset_top = 356.0
	tag.offset_bottom = 392.0
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.modulate.a = 0.0
	_ui_layer.add_child(tag)
	return tag


# 模式按钮:标题之后从中央依次浮现。返回按钮数组(浮现动画按这个次序排)。
# 三组分开 ——「开始游戏」/「选项」/「退出」,且**三组之间有分隔线**(见下)。
# ★★ 2026-10-03(按钮层级,用户已批准):六颗不再同权重 ——
#   主行动「单 人 模 式」720×104 + `accent` 档(C_ACCENT 描边,比 primary 更前);
#   「多 人 模 式」640×88;Beta/退出走 quiet 档;设置/信息再小一档 560×76。
#   ★ 文案一个字都没动(四条自检 + kh_l4_visual_probe 全按文案找按钮)。
func _build_menu_buttons() -> Array:
	# ★★ 2026-10-03:**撤掉那个「框住所有按钮的大框」**(用户看完成品图后的裁定 ——
	#   按钮直接落在页面底上,不要外框)。同一批把整列尺度放大(设计稿 1920×1440 上原度量偏小):
	#   按钮 640×88(工厂默认)、组内 20、组间 48、整列 `offset_top` 170。
	#   ★ 定位/生长方向/次序/文案一个字都没动(探针按文案找按钮)。
	#   ★ 别再加回 `menu_panel()`:撤框是**用户明确要求**,不是审美取舍。
	# ★ 2026-10-03(第二批):三组之间插入 `menu_separator()`;外层 separation 也用它来
	#   表达"组分隔"(36)而不是组内(20)—— 组的边界因此**看得见**。
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_top = 170.0
	box.add_theme_constant_override("separation", 36)   # 组与组之间的空档(分隔线上下各一份)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_ui_layer.add_child(box)

	var play_group := _btn_group()
	var opt_group := _btn_group()
	box.add_child(play_group)
	box.add_child(UiFactory.menu_separator())
	box.add_child(opt_group)
	box.add_child(UiFactory.menu_separator())

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
	return [start_btn, multi_btn, beta_btn, settings_btn, ver_btn, quit_btn]


# 浮现动画:标题与副信息先出(淡入),按钮依次淡入
func _play_emerge(title: Label, ver: Label, tag: Label, buttons: Array) -> void:
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(tag, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	var delay := 0.9
	for b in buttons:
		_emerge(b, delay, 0.5)
		delay += 0.16


# 一组按钮:组内紧凑(20),组与组之间靠外层 VBox 的 separation(36)+ 分隔线拉开。
# ★ 2026-10-03:14/34 → 20/48 → 现 20/36(第二批加了分隔线,组间空档改由线来表达)。
func _btn_group() -> VBoxContainer:
	var g := VBoxContainer.new()
	g.add_theme_constant_override("separation", 20)
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


# ── 单人开局面板:禁用武器(勾选 = 本局不可用)──
# 单人开局面板:场景(ui/sp_launch_panel.tscn)给骨架(标题/副标题/勾选列/按钮行),
# 武器勾选与按钮仍走工厂。★ CheckList 容器只为给勾选一个**插在 ButtonRow 之前**的位置
# —— 直接 vb.add_child(cb) 会把勾选追加到按钮行后面。
func _fill_sp_panel(panel: PanelContainer) -> PanelContainer:
	# 选图:每张卡带一版**开局地形简略图**(由 MapCatalog 从 .cyrm 现画,不是美术资源)
	var picker := MapPicker.new()
	panel.get_node("VBox/MapSection").add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	var checks: Array[CheckButton] = []
	var check_list: VBoxContainer = panel.get_node("VBox/CheckList")
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

	var row: HBoxContainer = panel.get_node("VBox/ButtonRow")
	# 单机开局面板(本屏的另一处按钮)同样走菜单按钮工厂 —— 它与主菜单同屏出现,
	# 不换的话两套描边会在同一屏里并排。
	# ★ 尺寸**必须显式传**:这两颗与主菜单那六颗不是同一处版式 —— 它们在弹层里**并排**
	#   (HBox),而 `menu_button` 的默认值已涨到 640 ⇒ 不写就是 640+640+24 = 1304 宽,
	#   把这块弹层从 ~900 撑到 ~1340。420 是这两个并排按钮原本的宽度(保持弹层宽度不变),
	#   高度随新内边距抬到 72。
	var go := UiFactory.menu_button("开 始 探 索", 32, Vector2(420, 72))
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
	var back := UiFactory.menu_button("返回", 32, Vector2(420, 72))   # 尺寸理由同上
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel
