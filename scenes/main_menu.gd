extends Control
# 主菜单(像素 UI):粗体大标题 + 模式按钮浮现动画,场景是裸 Control,UI 骨架在 main_menu.tscn 里;左下角版本号,「信 息」切独立整页,「单人模式」弹开局面板。

const PROBE_NODE_NAME := "MenuAutotestProbe"

var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)

# ★★ 静态骨架在 scenes/main_menu.tscn 里(见 tools/gen_menu_scene.gd),迁移判据是外观逐像素不变。
# ★ 背景(Bg)的材质仍由代码挂 —— 那张地形贴图是运行时烘的(TerrainAtlas),进不了 .tscn;bg 自己已经在 UIRoot 下,不再 add_child。
@onready var _ui_layer: CanvasLayer = %UILayer
@onready var _bg: ColorRect = %Bg
@onready var _title: Label = %Title
@onready var _ver: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox

var _bg_mat: ShaderMaterial = null       # 背景 ColorRect 的材质(null = 没建出来)
var _bg_cells := Vector2(150.0, 100.0)   # 背景那张图的格数(从纹理尺寸反推;随机取点要用)
var _rng := RandomNumberGenerator.new()  # 路径随机源(种子固定 ⇒ 可复现)
var _seg_t := 0.0                        # 当前段已走过的秒数
var _seg_from := Vector2.ZERO            # 当前段起点(格坐标)
var _seg_to := Vector2.ZERO              # 当前段终点(格坐标)
var _seg_index := 0                      # 段序号(奇偶决定角度是 0→120 还是 120→0)

const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")
const HEADER_STRIP_PANEL := preload("res://ui/components/header_strip_panel.tscn")

# ── 背景:真实地形(与游戏同一份图集)+ 鱼眼漂移(没有任何实体)── 背景必须是真实地形:砖是 structure.png 的砖、水是水、树叶是树叶,像「透过一扇窗看进那个世界」。
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
# ★★ Web 例外:Web 上烘图分辨率降到 16(2400×1600 ≈ 15MB)—— wasm 里烘 61MB 图要好几秒,且 4800 超过部分设备
#    WebGL2 纹理上限(常见 4096);背景本来就被 shader 压暗+模糊,16px/格观感几乎无差。桌面/移动仍 32。
static func bg_cell_px() -> int:
	return 16 if OS.has_feature("web") else BG_CELL_PX

const BG_VIEW_CELLS := 26.6667
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"
const BG_BLUR_RADIUS_PX := 4.0

# ── 镜头运动:「随机路径段」循环 ── ① 取一个随机目标点(地图中央 60% 那块矩形,两轴都是);② 平滑移动过去(缓入缓出,到点速度 → 0);③ 同一段时间里视角旋转 SEG_TURN_DEG;④ 到点后重新生成下一段。
# ★ 角度口径(以本版为准):角度在 0° 与 120° 之间来回摆,不是每段累加 +120° —— 段 1:0→120、段 2:120→0、段 3:0→120…… 这样三条同时成立:角度始终落在 [0,120]、段间连续不跳、且与「每段重新取路径」同拍(若每段都从 0 重新开始,段间会从 120 跳回 0)。★ 「旋转比移动缓慢很多」落在段时长与缓动曲线形状上:位移走缓入缓出(smoothstep,峰值 1.5 倍),旋转走梯形速度剖面(峰值 1.33 倍)⇒ 比位移更接近线性,观感是「移动先到位、转动还在慢慢走」。
const SEG_MIN_FRAC := 0.20     # 目标点的取值范围:地图的 20%~80%(两轴 ⇒ 中央 60% 的矩形)
const SEG_MAX_FRAC := 0.80
# 每段时长(秒)—— 它就是「移动速度」的单一旋钮:位移与旋转同段,改它两者一起变。
const SEGMENT_SEC := 48.0
const SEG_TURN_DEG := 120.0
# 旋转曲线的变速段占整段的比例(梯形速度剖面,见 _trapezoid):0.25 ⇒ 两端各 25% 用来加减速、中间 50% 匀速,峰值速度只有平均的 1/(1-0.25) ≈ 1.33 倍。
const SEG_TURN_EDGE_FRAC := 0.25
# 位移缓动曲线的偏置(见 _process):s = smoothstep(u) 的 SEG_MOVE_BIAS 次幂。
const SEG_MOVE_BIAS := 0.8
# 路径随机数种子固定 ⇒ 「随机」但每次进菜单是同一串路径(可复现、可对图)。
const SEG_PATH_SEED := 20261003
func _ready() -> void:
	# ── 发布产物自检:武器注册表到底从包里读到了几条 ── ★ 为什么必须在产物侧量:data/weapons.json 进不进 .pck 只由一次真导出回答 —— 真没进包时 WeaponRegistry._ensure_loaded() 只打一条 push_error、只在 stderr、不影响退出码 ⇒ 光看「游戏起得来」是看不出来的。
	# ★ 开关写在 -- 之后(与 --netstat / --pickup-diag 同款;写在前面会被 Godot 当自己的参数丢掉、静默失效),且默认关 ⇒ 生产行为一字不变。★ 消费者是 tools/build_release.py 的产物冒烟(check_weapon_registry):它拿仓库里那份 json 当期望值对账,判据是文本 grep,不看退出码。
	if OS.get_cmdline_user_args().has("--registry-report"):
		var ids: Array[int] = WeaponRegistry.all_ids()
		print("[registry] weapons=%d ids=%s" % [ids.size(), str(ids)])

	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	RunOptions.reset()
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()

	_build_ui()

	# 菜单流转自动探针:命令行 -- --autotest-sp|mp|set|level 时,把探针挂到树根(而非本场景)—— 它要穿越 change_scene 存活;平时零开销。
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--autotest-"):
			continue
		if get_tree().root.has_node(NodePath(PROBE_NODE_NAME)):
			break
		if not ResourceLoader.exists("res://tests/harness/menu_autotest.gd"):
			break
		var probe_script := load("res://tests/harness/menu_autotest.gd")
		if probe_script == null:
			break
		var probe := Node.new()
		probe.name = PROBE_NODE_NAME
		probe.set_script(probe_script)
		probe.set("mode", arg.trim_prefix("--autotest-"))
		get_tree().root.add_child.call_deferred(probe)
		break


# 单机进关卡(Level0 = 全量物理世界)。
func _enter_level0() -> void:
	# 选图(菜单里定的,空 = 随机):★ 必须在 change_scene 之前钉进 MazeGenerator 的会话缓存 —— 它是静态的、活过场景切换;文件被删 / 改名时回落随机,不让玩家卡在旧路径上。
	MazeGenerator.set_map_file(Settings.sp_map_path if MapCatalog.is_valid_map(Settings.sp_map_path) else "")
	# ★ 必须跟着重算世界尺寸:启动时算的是「当时随机挑的图」(如 demo 125×75 → 8000 宽),选了别的图(如 newfactory 150×100 → 9600 宽)不重算的话环面回绕 / 最短路径按错边界。
	GameParameters.refresh_map_size()
	Level0.pvp_mode = false            # 复位 PvP 标志,避免上次 PvP 残留
	CombatComponent.pvp_arena = false  # 回单机恢复命中无敌帧
	# ★ Web:Level0 的建图被拆成多帧(见 level_0._web_build_world),先亮遮罩并让出一帧让它真画出来;
	#   桌面建图在一帧内完成、遮罩只会闪一下 ⇒ 只在 Web 上走这条路。
	if OS.has_feature("web"):
		LoadingScreen.show_loading("正在构建世界…")
		await get_tree().process_frame
		await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/level_0.tscn")


func _build_ui() -> void:
	_build_background()
	_ver.text = AppInfo.version_string()
	_wire_menu()
	# ★ 浮现动画的起点:modulate.a = 0。
	_title.modulate.a = 0.0
	_ver.modulate.a = 0.0
	_play_emerge(_title, _ver, _menu_sequence())


# 六颗按钮的接线。
func _wire_menu() -> void:
	%StartBtn.pressed.connect(_on_single_pressed)
	# ★★ 联机入口只剩这一颗(三合一,统一大厅 mp_lobby):1v1 / 3v3 / 大乱斗都在那一个页面里按筛选区分。
	%MultiBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()   # 不碰回局凭据(见 pvp_session.gd 的 reset 注释)
		get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn"))
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
	# ★ Web 版只发客户端且浏览器没有 UDP/ENet ⇒ 联机(多人)与依赖它的 Beta 入口在这版是死路:
	#   直接隐藏,别让玩家点进去卡在"大厅连不上"。单机 / 设置 / 信息 / 退出保持原样。
	if OS.has_feature("web"):
		%MultiBtn.visible = false
		%BetaBtn.visible = false


# ★★ 浮现序列 = MenuBox 子树里屏幕上从上到下的次序,由树的形状推出来(组展开成组员,分隔线 / 退出键按它们在列里的位置插进去)。
func _menu_sequence() -> Array:
	var seq: Array = []
	for c in _menu_box.get_children():
		if c is VBoxContainer:
			for g in c.get_children():
				seq.append(g)
		else:
			seq.append(c)
	return seq


# ★ 底 ColorRect 的原色是 UiFactory.C_BG(调色板 token,不是新字面量):shader 正常时 fragment 覆写整块 COLOR,这层底不可见;万一 shader 载入失败,留下的是一块与页面底同色的深底(而不是 ColorRect 默认的白色 —— 那会是一屏白得读不出字的菜单)。
func _build_background() -> void:
	var bg := _bg
	var sh: Shader = load(BG_SHADER)
	if sh != null:
		# 真实地形图:地图子格纹理 × TerrainAtlas 的图集(= Level0 生成 TileSet 的同一份)。
		var cell_px := bg_cell_px()
		var tex := TerrainAtlas.terrain_texture(BG_MAP, cell_px, TerrainAtlas.SKY_COLOR)
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("map_tex", tex)
		mat.set_shader_parameter("map_size",
				Vector2(tex.get_width(), tex.get_height()) / float(cell_px))
		# 取景(屏幕横向多少格)由常量显式给,不从纹理尺寸反推 —— 它与烘图分辨率是配套的一对,反推会让「再放大一点」变成只改一半。
		mat.set_shader_parameter("view_w_cells", BG_VIEW_CELLS)
		mat.set_shader_parameter("blur_radius", BG_BLUR_RADIUS_PX)
		_bg_cells = Vector2(tex.get_width(), tex.get_height()) / float(cell_px)
		_bg_mat = mat
		bg.material = mat
		_init_motion()


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


# ★ 「不许跳」这条硬约束在两处都成立:位置 —— 段末 u→1 时 s→1(恰好落在 _seg_to),下一段从 _seg_from = 上一段的 _seg_to、s→0 出发 ⇒ 位置连续,且 smoothstep 两端导数为 0 ⇒ 速度也连续(不会一顿);角度 —— 0→120 与 120→0 交替,端点角度。
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
	var turn: float = e if (_seg_index % 2) == 0 else 1.0 - e
	_bg_mat.set_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	_bg_mat.set_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))


static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)               # 匀速段的速度(面积归一)
	if u < a:
		return v * u * u / (2.0 * a)             # 加速
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)   # 减速
	return v * (a * 0.5 + (u - a))               # 匀速


# ★ 大标题(128 号、C_ACCENT、无描边、锚 PRESET_CENTER_TOP + offset_top = 160):用户删掉副信息行、标题从 96 放大到 128、并去掉描边 —— 那里一个描边 / 阴影 override 都没有。
# ★ 按钮列(MenuBox,锚 PRESET_CENTER + offset_top = 170):三组「开始游戏(单人 / 多人 / Beta)」/「选项(设置 / 信息)」/「退出」,组间两条分隔线。★★ 别再加回 menu_panel() 把整列框起来 —— 撤框是用户明确要求。尺寸 / 档位:单人 720×104 accent(全页唯一「最前」)、多人 640×88(默认)、Beta / 退出 640×88 quiet、设置 / 信息 560×76。浮现动画:标题与版本号先出,其余元素(按钮与分隔线)按序列依次淡入;★ 参数名是 sequence 而不是 buttons(它按屏幕次序混装按钮与静态元素,由 _menu_sequence() 从树序推出),_emerge 只写 modulate.a。
func _play_emerge(title: Label, ver: Label, sequence: Array) -> void:
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	var delay := 0.45
	for c in sequence:
		_emerge(c, delay, 0.28)
		delay += 0.09


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
	# ★ 必须挂 UIRoot(UIRoot 才是主题宿主;CanvasLayer 会切断 Theme 传播链 —— 见文件头第 8 行)。
	get_node("%UIRoot").add_child(_sp_panel)


# ★ 皮 = UiFactory.skin_menu_panel()(外深线 + 内亮线,方向 B 的凿刻感)。

const SP_PANEL_PADDING := Vector2(64, 46)
const SP_BLOCK_GAP := 28
const SP_CHECK_GAP := 20
const SP_BUTTON_GAP := 28
const SP_PANEL_MIN_W := 560.0

# 列表固定可见高度,地图选择器和底部按钮不随武器数量往屏外挤。
const SP_CHECK_LIST_MAX_H := 320.0

func _header(title_text: String, size: int, centered: bool) -> HeaderStripPanel:
	var h := HEADER_STRIP_PANEL.instantiate() as HeaderStripPanel
	h.apply(title_text, size, centered)
	return h


func _fill_sp_panel(panel: PanelContainer) -> PanelContainer:
	UiFactory.skin_menu_panel(panel, SP_PANEL_PADDING)
	var body := panel.get_node("Body") as Container
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(SP_PANEL_MIN_W, 0)
	vb.add_theme_constant_override("separation", SP_BLOCK_GAP)
	body.add_child(vb)

	# 页首/弹层标题居中(2026-10-27 规则);下面那条「禁用武器」是表单内分区标题,保持左对齐。
	vb.add_child(_header("—— 单人开局 ——", 48, true))

	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	vb.add_child(_header("禁用武器(勾选 = 本局不可用)", 32, false))

	var checks: Array[CheckButton] = []
	var check_list := VBoxContainer.new()
	# ★ 名字是公开契约:menu_weapon_grid_probe 按这个名字在面板子树里找勾选列(它不写死路径 —— 版式再挪一层也不会瞎)。零守卫:该探针已删·2026-10-09。
	check_list.name = "CheckList"
	check_list.add_theme_constant_override("separation", SP_CHECK_GAP)
	# ★ ScrollContainer 里的内容不会被父容器拉伸成等宽 ⇒ 显式 EXPAND,勾选框才不被横向压窄。
	check_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ★ 高度上限设在 ScrollContainer 上、不在里面的 VBox 上:ScrollContainer 的 min_size.y 恒为 0,把上限写在内层会被吃掉(见 server/gui/server_panel.gd 的 _log_scroll 注释)。
	var check_scroll := ScrollContainer.new()
	check_scroll.custom_minimum_size = Vector2(0, SP_CHECK_LIST_MAX_H)
	check_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	check_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	check_scroll.add_child(check_list)
	vb.add_child(check_scroll)
	var ids: Array[int] = WeaponRegistry.all_ids()
	for type_id: int in ids:
		var cb := CheckButton.new()
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
	# 单机开局面板这两颗按钮同样走菜单按钮工厂(与主菜单同屏出现,不换的话两套描边会在同一屏里并排)。
	var go := UiFactory.menu_button("开 始 探 索", 32, Vector2(420, 88), "gold")
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				# ★ 必须是 ids[i]:不能写成 i + 1。
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
