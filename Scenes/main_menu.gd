extends Control
# 主菜单(实验分支 KikuchiHeinr):像素粗体大标题 + 模式按钮从屏幕中央依次浮现,
# 背景 = 单人地图奔跑演示(Level0.menu_demo:镜头向左匀速运镜,主角向左奔跑)。
# Settings.old_ui=true 时保留旧版简洁布局(可在设置里切回)。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"
const PAN_SPEED := 240.0            # 背景镜头向左匀速运镜(px/s)
const RUNNER_SCREEN_X := 260.0      # 主角在镜头前方的水平偏移(px)
const WEAPON_NAMES := {1: "手枪", 2: "步枪", 3: "重狙 M82A1", 4: "霰弹 S686", 5: "榴弹发射器"}

var _cam: Camera2D = null
var _runner: AnimatedSprite2D = null
var _runner_y := 0.0
var _ui_layer: CanvasLayer = null
var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)


func _ready() -> void:
	# 复位对局相关全局(进过 PvP/开过 demo 回来不残留)
	Level0.pvp_mode = false
	Level0.menu_demo = true
	CombatComponent.pvp_arena = false
	# 上次单人开局选择(存档在 Settings)
	RunOptions.reset()
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
	RunOptions.difficulty = Settings.sp_difficulty

	if Settings.old_ui:
		_build_old_ui()
	else:
		_build_new_ui()


func _process(delta: float) -> void:
	if _cam == null:
		return
	# 镜头向左匀速运镜;取模回中央副本范围内(3×3 铺贴保证跨接缝画面连续)
	_cam.global_position.x = wrapf(_cam.global_position.x - PAN_SPEED * delta, 0.0,
			GameParameters.MAP_WIDTH)
	_cam.global_position.y = _runner_y
	# 主角跟镜头同步向左跑,保持固定屏幕位置(世界在向后流动)
	if _runner != null:
		_runner.global_position = Vector2(_cam.global_position.x - RUNNER_SCREEN_X, _runner_y)


# ── 新版 UI ──
func _build_new_ui() -> void:
	# 背景:地图奔跑演示。menu_demo 已置位,Level0 只铺图不建玩家/敌人。
	Level0.menu_demo = true
	var level0: Node = load("res://Scenes/Level0.tscn").instantiate()
	add_child(level0)
	Level0.menu_demo = false   # 只影响本次实例化
	_cam = level0.get_node("WorldViewport/Camera2D")
	var spawns := MazeGenerator.load_spawns()
	var spawn: Vector2i = spawns.get("player", Vector2i(int(MazeGenerator.map_size().x / 2.0), 0))
	_runner_y = spawn.y * GameParameters.TILE_SIZE + GameParameters.TILE_SIZE * 0.5
	_cam.global_position = Vector2(spawn.x * GameParameters.TILE_SIZE, _runner_y)
	# 主角(纯视觉):借 Player.tscn 的 SpriteFrames 播奔跑,朝左跑
	var tmp: Node = preload("res://Scenes/Player/Player.tscn").instantiate()
	var frames: SpriteFrames = tmp.get_node("AnimatedSprite2D").sprite_frames
	var body_scale: Vector2 = tmp.scale
	tmp.free()
	_runner = AnimatedSprite2D.new()
	_runner.sprite_frames = frames
	_runner.scale = body_scale
	_runner.flip_h = true
	_runner.play("move")
	level0.get_node("WorldViewport").add_child(_runner)
	# 后处理(与游戏内一致的画面),再叠一层暗化让 UI 突出
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	add_child(pp)

	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 140   # 盖过 PostProcess(128)/HUD(129)
	add_child(_ui_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.05, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(dim)

	# 大标题:中央浮现(淡入 + 轻微上移)
	var title := _pixel_label("The Cyancular Ruins", 104, Color(0.55, 0.95, 1.0))
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	title.offset_top = 220.0
	title.offset_bottom = 360.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate.a = 0.0
	title.position.y += 40.0
	_ui_layer.add_child(title)

	# 模式按钮:标题之后从中央依次浮现
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_top = 120.0
	box.add_theme_constant_override("separation", 22)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_ui_layer.add_child(box)

	var start_btn := _pixel_button("单 人 模 式", 40)
	start_btn.pressed.connect(_on_single_pressed)
	var multi_btn := _pixel_button("多 人 对 战", 40)
	multi_btn.pressed.connect(func() -> void:
		PvpSession.reset()
		get_tree().change_scene_to_file("res://Scenes/matchmaking.tscn"))
	var settings_btn := _pixel_button("设      置", 40)
	settings_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://Scenes/settings_menu.tscn"))
	var quit_btn := _pixel_button("退      出", 40)
	quit_btn.pressed.connect(func() -> void: get_tree().quit())
	for b in [start_btn, multi_btn, settings_btn, quit_btn]:
		box.add_child(b)

	# 浮现动画:标题先出(淡入+上浮),按钮依次淡入
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	var delay := 0.9
	for b in [start_btn, multi_btn, settings_btn, quit_btn]:
		_emerge(b, delay, 0.5)
		delay += 0.18


# 元素浮现:延迟后淡入。按钮由容器管理布局,只做透明度;标题的位移在其外部单独处理。
func _emerge(c: Control, delay: float, dur: float) -> void:
	c.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(c, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_SINE)


func _on_single_pressed() -> void:
	if _sp_panel != null:
		_sp_panel.visible = not _sp_panel.visible
		return
	_sp_panel = _build_sp_panel()
	_ui_layer.add_child(_sp_panel)


# ── 单人开局面板:禁用武器 + 难度(鸟密度)──
func _build_sp_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(560, 0)
	panel.add_child(vb)

	vb.add_child(_pixel_label("—— 单人开局 ——", 44, Color(0.6, 0.95, 1.0)))
	vb.add_child(_pixel_label("禁用武器(勾选 = 本局不可用)", 26))

	var checks: Array[CheckButton] = []
	for slot in [1, 2, 3, 4, 5]:
		var cb := CheckButton.new()
		cb.text = "%d. %s" % [slot, WEAPON_NAMES[slot]]
		_style_control(cb, 26)
		cb.button_pressed = Settings.sp_disabled_weapons.has(slot)
		checks.append(cb)
		vb.add_child(cb)

	vb.add_child(_pixel_label("难度(影响敌人密度)", 26))
	var diff_row := HBoxContainer.new()
	diff_row.add_theme_constant_override("separation", 12)
	vb.add_child(diff_row)
	var diff_btns: Array[Button] = []
	for d in 3:
		var b := Button.new()
		_style_control(b, 26)
		b.toggle_mode = true
		b.text = RunOptions.DIFFICULTY_NAMES[d]
		b.button_pressed = Settings.sp_difficulty == d
		b.pressed.connect(func() -> void:
			Settings.sp_difficulty = d
			Settings.save()
			for other in diff_btns:
				other.set_pressed_no_signal(other == b))
		diff_btns.append(b)
		diff_row.add_child(b)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	vb.add_child(row)
	var go := _pixel_button("开 始 探 索", 34)
	go.pressed.connect(func() -> void:
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				Settings.sp_disabled_weapons.append(i + 1)
		Settings.save()
		RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
		RunOptions.difficulty = Settings.sp_difficulty
		get_tree().change_scene_to_file("res://Scenes/Level0.tscn"))
	var back := _pixel_button("返回", 34)
	back.pressed.connect(func() -> void:
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel


# ── 旧版 UI(Settings.old_ui=true):保留原布局,追加设置入口 ──
func _build_old_ui() -> void:
	var title := Label.new()
	title.text = "The Cyancular Ruins"
	title.position = Vector2(60, 60)
	title.add_theme_font_size_override("font_size", 40)
	add_child(title)

	var single := Button.new()
	single.text = "单人"
	single.position = Vector2(60, 180)
	single.size = Vector2(200, 48)
	single.pressed.connect(func() -> void:
		Level0.pvp_mode = false
		CombatComponent.pvp_arena = false
		get_tree().change_scene_to_file("res://Scenes/Level0.tscn"))
	add_child(single)

	var multi := Button.new()
	multi.text = "多人"
	multi.position = Vector2(60, 240)
	multi.size = Vector2(200, 48)
	multi.pressed.connect(func() -> void:
		PvpSession.reset()
		get_tree().change_scene_to_file("res://Scenes/matchmaking.tscn"))
	add_child(multi)

	var settings := Button.new()
	settings.text = "设置"
	settings.position = Vector2(60, 300)
	settings.size = Vector2(200, 48)
	settings.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://Scenes/settings_menu.tscn"))
	add_child(settings)


# ── UI 小工具 ──
func _pixel_label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pf: FontFile = load(PIXEL_FONT)
	if pf != null:
		pf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		pf.hinting = TextServer.HINTING_NONE
		pf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		l.add_theme_font_override("font", pf)
	return l


func _style_control(c: Control, font_size: int) -> void:
	c.add_theme_font_size_override("font_size", font_size)
	var pf: FontFile = load(PIXEL_FONT)
	if pf != null:
		c.add_theme_font_override("font", pf)


func _pixel_button(text: String, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	_style_control(b, font_size)
	b.custom_minimum_size = Vector2(360, 64)
	b.pressed.connect(func() -> void: Sfx.play("ui"))
	return b
