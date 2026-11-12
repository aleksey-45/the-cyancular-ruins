extends Control

const PROBE_NODE_NAME := "MenuAutotestProbe"

# ── 编辑器入口(客户端专属)──
# ★ "editor" 由**导出预设**注入(export_presets.cfg 客户端预设写 custom_features="editor"),服务端/Web 不写
#   ⇒ 服务端与 Web 产物里这个入口根本不出现(计划 §5 不做编辑器 web 导出)。
# ★ 开发态(Godot 编辑器里跑 / 直接跑工程)也建入口(2026-11-12 仓主决定):编辑器二进制恒带 "editor";
#   产物版式仍由生成器骨架决定,开发态只是多追加一个按钮。
# ★ 纯函数、无副作用:产物检查(tools/build_release.py)直接调它来对账产物分支。
const EDITOR_SCENE := "res://scenes/editor/editor_root.tscn"


static func editor_entry_enabled() -> bool:
	# 只看 "editor":编辑器二进制恒真、客户端产物按 custom_features 真;服务端/Web 没有该 feature ⇒ false。
	return OS.has_feature("editor")


var _sp_panel: PanelContainer = null
# 开发态与客户端产物里被创建;产物自检靠它判断「按钮是否真的建出来了」。
var _editor_btn: Button = null

# ★★ 静态骨架在 scenes/main_menu.tscn 里,由 tools/gen_menu_scene.gd 的**构建模式**(`-- main_menu`)生成:
#   容器化(0 绝对 offset,详见生成器头注释)。改版式 = 改生成器重跑 + 前后截图对比;别手改 .tscn。
# ★ 背景已换成**实时光影场景**(ui/menu_backdrop.gd:场景 TileMapLayer + ParallaxBg + PostProcess,
#   昼夜 120s = 24h);%Bg 只剩兜底底色,地图读不到时才看得见。
@onready var _ui_layer: CanvasLayer = %UILayer
# %Title 现在是 160 号青色 Label(无背景);_play_emerge 只要求 CanvasItem。
@onready var _title: Control = %Title
@onready var _ver: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox

const SP_PANEL_SCENE := preload("res://ui/screens/sp_launch_panel.tscn")
const HEADER_STRIP_PANEL := preload("res://ui/components/header_strip_panel.tscn")
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
	# ★ 开发态与客户端产物都会追加这个按钮;服务端/Web 没有 editor feature ⇒ 与骨架完全一致。
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
