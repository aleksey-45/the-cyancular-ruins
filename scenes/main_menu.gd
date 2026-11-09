extends Control

const PROBE_NODE_NAME := "MenuAutotestProbe"

# ── 编辑器入口(客户端专属)──
# ★ feature 由**导出预设**注入,不是运行期判断文件在不在:`export_presets.cfg` 里客户端预设
#   (preset0 Windows Desktop / preset2 macOS)写 `custom_features="editor"`,服务端/Web 不写
#   ⇒ 服务端与 Web 产物里这个入口根本不出现(计划 §5 不做编辑器 web 导出)。
# ★ 纯函数、无副作用:产物检查(tools/build_release.py)直接调它来对账产物分支。
const EDITOR_SCENE := "res://scenes/editor/editor_root.tscn"


static func editor_entry_enabled() -> bool:
	# ★ 为什么不是裸 `OS.has_feature("editor")`:Godot 源码 `core/os/os.cpp` 的 `TOOLS_ENABLED`
	#   分支对 "editor" **直接返回 true** ⇒ 编辑器二进制(开发态直接跑工程 / 编辑器里 play)也恒真,
	#   单靠它会让开发态主菜单长出按钮、破坏 P2「菜单版式逐像素不变」的验收。
	#   "template" 只在**导出模板**里为真 ⇒ 两者相与 = **只有导出的客户端产物**才为真:
	#   客户端预设带 `custom_features="editor"` ⇒ true;服务端/Web 预设不带 ⇒ false。
	return OS.has_feature("editor") and OS.has_feature("template")


var _sp_panel: PanelContainer = null
# 只在带 editor feature 的客户端产物里被创建;产物自检靠它判断「按钮是否真的建出来了」。
var _editor_btn: Button = null

# ★★ 静态骨架在 scenes/main_menu.tscn 里,由 tools/gen_menu_scene.gd 的**构建模式**(`-- main_menu`)生成:
#   容器化(0 绝对 offset,详见生成器头注释)。改版式 = 改生成器重跑 + 前后截图对比;别手改 .tscn。
# ★ 背景(Bg)的材质仍由代码挂 —— 那张地形贴图是运行时烘的(TerrainAtlas),进不了 .tscn;bg 是骨架里的全屏 ColorRect。
@onready var _ui_layer: CanvasLayer = %UILayer
@onready var _bg: ColorRect = %Bg
# %Title 是 HeaderStrip 面板(整条标题带一起淡入);_play_emerge 只要求 CanvasItem。
@onready var _title: Control = %Title
@onready var _ver: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox

var _bg_mat: ShaderMaterial = null
var _bg_cells := Vector2(150.0, 100.0)
var _rng := RandomNumberGenerator.new()
var _seg_t := 0.0
var _seg_from := Vector2.ZERO
var _seg_to := Vector2.ZERO
var _seg_index := 0

const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")
const HEADER_STRIP_PANEL := preload("res://ui/components/header_strip_panel.tscn")

# ── 背景:真实地形(与游戏同一份图集)+ 鱼眼漂移(没有任何实体)── 背景必须是真实地形:砖是 structure.png 的砖、水是水、树叶是树叶,像「透过一扇窗看进那个世界」。
const BG_MAP := "res://maps/newfactory.cyrm"
const BG_CELL_PX := 32
static func bg_cell_px() -> int:
	return 16 if OS.has_feature("web") else BG_CELL_PX

const BG_VIEW_CELLS := 26.6667
const BG_SHADER := "res://core/present/menu_fisheye.gdshader"
const BG_BLUR_RADIUS_PX := 4.0

const SEG_MIN_FRAC := 0.20
const SEG_MAX_FRAC := 0.80
const SEGMENT_SEC := 48.0
const SEG_TURN_DEG := 120.0
const SEG_TURN_EDGE_FRAC := 0.25
const SEG_MOVE_BIAS := 0.8
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

	# ── 产物自检:编辑器入口到底在不在 ──
	# 客户端产物必须 `feature=true entry=true`;服务端产物(强制跑 main_menu 场景)必须 `false false`。
	# ★ entry = 按钮**是否真的建出来了**(不是"该不该建");判据由 tools/build_release.py 的产物冒烟 grep。
	# ★ 开关同样写在 `--` 之后(与 --registry-report / --netstat 同款),默认关 ⇒ 生产行为一字不变。
	if OS.get_cmdline_user_args().has("--editor-entry-report"):
		print("[editor] feature=%s entry=%s" % [str(editor_entry_enabled()), str(_editor_btn != null)])

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


func _enter_level0() -> void:
	MazeGenerator.set_map_file(Settings.sp_map_path if MapCatalog.is_valid_map(Settings.sp_map_path) else "")
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	LoadingScreen.show_loading("正在构建世界…")
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/level_0.tscn")


func _build_ui() -> void:
	_build_background()
	_ver.text = AppInfo.version_string()
	_wire_menu()
	_title.modulate.a = 0.0
	_ver.modulate.a = 0.0
	_play_emerge(_title, _ver, _menu_sequence())


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
	if OS.has_feature("web"):
		%MultiBtn.visible = false
		%BetaBtn.visible = false
	# ★ 只在客户端产物(`custom_features="editor"`)里加这个按钮 ⇒ 开发构建/服务端/Web 的主菜单
	#   与骨架**完全一致**(不追加任何节点;版式由 scenes/main_menu.tscn 的容器树决定)。
	if editor_entry_enabled():
		# 复制 %BetaBtn 的样式(Quiet variation + 列宽/行高 flags),不新建第二套皮肤。
		# ★ duplicate(0):默认 flags 会把 %BetaBtn 刚接好的 pressed 连接也复制过来 ⇒ 点编辑器会同时进 Beta。
		var editor_btn := (%BetaBtn as Button).duplicate(0) as Button
		editor_btn.name = "EditorBtn"
		editor_btn.unique_name_in_owner = false
		editor_btn.text = "地 图 编 辑 器"
		editor_btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			get_tree().change_scene_to_file(EDITOR_SCENE))
		%PlayGroup.add_child(editor_btn)
		%PlayGroup.move_child(editor_btn, %BetaBtn.get_index() + 1)
		_editor_btn = editor_btn


func _menu_sequence() -> Array:
	var seq: Array = []
	for c in _menu_box.get_children():
		if c is VBoxContainer:
			for g in c.get_children():
				seq.append(g)
		else:
			seq.append(c)
	return seq


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
	_bg_mat.set_shader_parameter("rot_angle", 0.0)


func _random_target() -> Vector2:
	return Vector2(
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.x,
			_rng.randf_range(SEG_MIN_FRAC, SEG_MAX_FRAC) * _bg_cells.y)


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


static func _trapezoid(u: float) -> float:
	var a := SEG_TURN_EDGE_FRAC
	var v: float = 1.0 / (1.0 - a)
	if u < a:
		return v * u * u / (2.0 * a)
	if u > 1.0 - a:
		return 1.0 - v * (1.0 - u) * (1.0 - u) / (2.0 * a)
	return v * (a * 0.5 + (u - a))


func _play_emerge(title: Control, ver: Label, sequence: Array) -> void:
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
	get_node("%UIRoot").add_child(_sp_panel)



const SP_PANEL_PADDING := Vector2(64, 46)
const SP_BLOCK_GAP := 28
const SP_CHECK_GAP := 20
const SP_BUTTON_GAP := 28
const SP_PANEL_MIN_W := 560.0

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

	vb.add_child(_header("—— 单人开局 ——", 48, true))

	var picker := MapPicker.new()
	vb.add_child(picker)
	picker.setup(Settings.sp_map_path, 2, 300.0)

	vb.add_child(_header("禁用武器(勾选 = 本局不可用)", 32, false))

	var checks: Array[CheckButton] = []
	var check_list := VBoxContainer.new()
	check_list.name = "CheckList"
	check_list.add_theme_constant_override("separation", SP_CHECK_GAP)
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
