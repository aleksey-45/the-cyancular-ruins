extends Control
# 主菜单场景：包含标题、模式入口按钮、版本标识以及背景鱼眼镜头地图漫游视效。
# 单人模式支持弹出配置面板（选择地图与禁用武器）；多人入口进入统一联机大厅。
# 控件风格与尺寸规范统一遵循 UiFactory。

const PROBE_NODE_NAME := "MenuAutotestProbe"
const TUNNEL_FEEL_NODE_NAME := "TunnelFeelProbe"

var _sp_panel: PanelContainer = null

@onready var _ui_layer: CanvasLayer = %UILayer
@onready var _bg: ColorRect = %Bg
@onready var _title: Label = %Title
@onready var _ver: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox

# ── 背景镜头运动状态 ──
var _bg_mat: ShaderMaterial = null
var _bg_cells := Vector2(150.0, 100.0)
var _rng := RandomNumberGenerator.new()
var _seg_t := 0.0
var _seg_from := Vector2.ZERO
var _seg_to := Vector2.ZERO
var _seg_index := 0

const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")

# ── 背景漫游参数 ──
# 使用真实地形纹理与鱼眼着色器进行缓速漂移与微幅旋转，不生成任何动态实体
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
const BG_VIEW_CELLS := 26.6667
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"
const BG_BLUR_RADIUS_PX := 4.0

# ── 镜头运动轨迹参数 ──
const SEG_MIN_FRAC := 0.20
const SEG_MAX_FRAC := 0.80
const SEGMENT_SEC := 48.0
const SEG_TURN_DEG := 120.0
const SEG_TURN_EDGE_FRAC := 0.25
const SEG_MOVE_BIAS := 0.8
const SEG_PATH_SEED := 20261003

func _ready() -> void:
	# 发布构建自检：验证武器注册表配置有效加载
	if OS.get_cmdline_user_args().has("--registry-report"):
		var ids: Array[int] = WeaponRegistry.all_ids()
		print("[registry] weapons=%d ids=%s" % [ids.size(), str(ids)])

	# 重置对局相关全局状态
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	RunOptions.reset()
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()

	_build_ui()

	# 自动化测试探针挂载
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

	# P2P 隧道网络性能基准测试探针
	if _tunnel_feel_requested():
		if not get_tree().root.has_node(NodePath(TUNNEL_FEEL_NODE_NAME)) \
				and ResourceLoader.exists("res://tests/probe/tunnel_feel_probe.tscn"):
			var tf: Node = (load("res://tests/probe/tunnel_feel_probe.tscn") as PackedScene).instantiate()
			tf.name = TUNNEL_FEEL_NODE_NAME
			get_tree().root.add_child.call_deferred(tf)


# 检查命令行是否请求执行网络基准测试
func _tunnel_feel_requested() -> bool:
	var side := false
	var secs := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--side="):
			side = true
		elif arg.begins_with("--seconds="):
			secs = true
	return side and secs


# 启动单人模式并加载主关卡场景
func _enter_level0() -> void:
	MazeGenerator.set_map_file(Settings.sp_map_path if MapCatalog.is_valid_map(Settings.sp_map_path) else "")
	GameParameters.refresh_map_size()
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	get_tree().change_scene_to_file("res://scenes/level_0.tscn")


# ── 界面初始化 ──
func _build_ui() -> void:
	_build_background()
	_ver.text = AppInfo.version_string()
	_wire_menu()
	_title.modulate.a = 0.0
	_ver.modulate.a = 0.0
	_play_emerge(_title, _ver, _menu_sequence())


# 连接菜单各功能按钮事件
func _wire_menu() -> void:
	%StartBtn.pressed.connect(_on_single_pressed)
	%MultiBtn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()
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


# 获取菜单按钮的展示顺序
func _menu_sequence() -> Array:
	var seq: Array = []
	for c in _menu_box.get_children():
		if c is VBoxContainer:
			for g in c.get_children():
				seq.append(g)
		else:
			seq.append(c)
	return seq


# 构建背景全屏鱼眼漫游渲染材质
func _build_background() -> void:
	var bg := _bg
	var sh: Shader = load(BG_SHADER)
	if sh != null:
		var tex := TerrainAtlas.terrain_texture(BG_MAP, BG_CELL_PX, TerrainAtlas.SKY_COLOR)
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("map_tex", tex)
		mat.set_shader_parameter("map_size",
				Vector2(tex.get_width(), tex.get_height()) / float(BG_CELL_PX))
		mat.set_shader_parameter("view_w_cells", BG_VIEW_CELLS)
		mat.set_shader_parameter("blur_radius", BG_BLUR_RADIUS_PX)
		_bg_cells = Vector2(tex.get_width(), tex.get_height()) / float(BG_CELL_PX)
		_bg_mat = mat
		bg.material = mat
		_init_motion()


# 初始化背景运动参数
func _init_motion() -> void:
	_rng.seed = SEG_PATH_SEED
	_seg_t = 0.0
	_seg_index = 0
	_seg_from = _random_target()
	_seg_to = _random_target()
	_bg_mat.set_shader_parameter("view_center", _seg_from)
	_bg_mat.set_shader_parameter("rot_angle", 0.0)


func _random_target() -> Vector2:
	return Vector2(
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.x,
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.y)


# 更新背景漫游的中心位置与旋转角
func _process(delta: float) -> void:
	if _bg_mat == null:
		return
	_seg_t += delta
	while _seg_t >= SEGMENT_SEC:
		_seg_t -= SEGMENT_SEC
		_seg_index += 1
		_seg_from = _seg_to
		_seg_to = _random_target()
	var u := clampf(_seg_t / SEGMENT_SEC, 0.0, 1.0)
	var s: float = pow(smoothstep(0.0, 1.0, u), SEG_MOVE_BIAS)
	var e := _trapezoid(u)
	var turn: float = e if (_seg_index % 2) == 0 else 1.0 - e
	_bg_mat.set_shader_parameter("view_center", _seg_from.lerp(_seg_to, s))
	_bg_mat.set_shader_parameter("rot_angle", deg_to_rad(SEG_TURN_DEG * turn))


# 梯形速度剖面位移计算
static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)
	if u < a:
		return v * u * u / (2.0 * a)
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)
	return v * (a * 0.5 + (u - a))


# 执行标题与按钮淡入动画
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
	_ui_layer.add_child(_sp_panel)


# ── 单人开局设置面板 ──
const SP_PANEL_PADDING := Vector2(64, 46)
const SP_BLOCK_GAP := 28
const SP_CHECK_GAP := 20
const SP_BUTTON_GAP := 28
const SP_PANEL_MIN_W := 560.0

func _fill_sp_panel(panel: PanelContainer) -> PanelContainer:
	UiFactory.skin_menu_panel(panel, SP_PANEL_PADDING)
	var body := panel.get_node("Body") as Container
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(SP_PANEL_MIN_W, 0)
	vb.add_theme_constant_override("separation", SP_BLOCK_GAP)
	body.add_child(vb)

	vb.add_child(UiFactory.header_strip("—— 单人开局 ——", 48))

	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	vb.add_child(UiFactory.header_strip("禁用武器(勾选 = 本局不可用)", 32))

	var checks: Array[CheckButton] = []
	var check_list := VBoxContainer.new()
	check_list.name = "CheckList"
	check_list.add_theme_constant_override("separation", SP_CHECK_GAP)
	vb.add_child(check_list)
	var ids: Array[int] = WeaponRegistry.all_ids()
	for type_id: int in ids:
		var cb := CheckButton.new()
		cb.text = WeaponRegistry.name_of(type_id)
		cb.icon = WeaponIcons.silhouette(type_id)
		cb.expand_icon = false
		UiFactory.style_check(cb, 32)
		cb.button_pressed = Settings.sp_disabled_weapons.has(type_id)
		checks.append(cb)
		check_list.add_child(cb)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", SP_BUTTON_GAP)
	vb.add_child(row)

	var go := UiFactory.menu_button("开 始 探 索", 32, Vector2(420, 88), "gold")
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				Settings.sp_disabled_weapons.append(int(ids[i]))
		Settings.sp_map_path = picker.selected
		Settings.save()
		RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
		_enter_level0())
	var back := UiFactory.menu_button("返回", 32, Vector2(420, 88), "quiet")
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel
