extends Control
# 主菜单(实验分支):像素粗体大标题 + 模式按钮浮现动画,
# 背景 = 实机演示(MenuDemoAi 驱动真实玩家追打演示鸟,镜头正常跟随)。
# 标题下方显示版本号(分支名 + git 提交序号);「版本信息」列出本分支提交历史。
# Settings.old_ui=true 时保留旧版简洁布局。

const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"

static var _version_cache := ""
static var _log_cache: Array = []

var _ui_layer: CanvasLayer = null
var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)
var _ver_panel: PanelContainer = null   # 版本信息面板(弹出式)
var _demo_level0: Node = null           # 背景演示世界(切场景前要先拆它的碰撞体,见 _leave_menu)


# 切换场景前把演示世界从场景树摘下挂起(而非释放):实测场景切换时释放含大量
# 碰撞体的物理世界会偶发原生段错误;脱离场景树的节点完全停止处理且不被 change_scene 释放。
# (回主菜单方向的游戏世界退役走 Level0.safe_change_scene,见其注释)
func _leave_menu(path: String) -> void:
	if _demo_level0 != null and is_instance_valid(_demo_level0):
		Level0.menu_demo_instance = _demo_level0
		var parent := _demo_level0.get_parent()
		if parent != null:
			parent.remove_child(_demo_level0)
		_demo_level0.visible = false
	await get_tree().process_frame
	get_tree().change_scene_to_file(path)


# 单机进关卡(Level0 = 全量物理世界)。不能直接 change_scene:旧场景销毁若与新世界的
# 「建图 deferred flush(WorldBuilder.build_sim,数万静态体)」同帧发生,会偶发原生段错误
# (蓝屏;headless autotest 实测 ~1/4~1/2,而直接启动 Level0 从不崩——崩点不在建图本身,
# 而在「销毁旧场景 × 构建新大世界」的并发)。做法:先把演示世界摘树(同上),再实例化
# Level0 让它跑完 _ready + deferred 建图/刷怪/首批物理注册并稳定数帧,之后才把菜单场景
# (纯 UI,无大物理)摘树释放——两件事在时间上彻底错开。
func _enter_level0() -> void:
	# 复位对局全局:menu_demo 可能被上一轮主菜单残留为 true(复用演示世界路径不改它),
	# 不清会误走 Level0 的演示分支(HUD 隐藏/AI 驱动,单机开局异常)。
	Level0.pvp_mode = false
	Level0.menu_demo = false
	CombatComponent.pvp_arena = false
	if _demo_level0 != null and is_instance_valid(_demo_level0):
		Level0.menu_demo_instance = _demo_level0
		var parent := _demo_level0.get_parent()
		if parent != null:
			parent.remove_child(_demo_level0)
		_demo_level0.visible = false
	await get_tree().process_frame
	await Level0.enter_game_staged(get_tree())


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

	# 自动流转探针( Tests/menu_autotest.gd ):命令行 -- --autotest-sp / --autotest-mp / --autotest-set
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--autotest-"):
			var probe := Node.new()
			probe.set_script(load("res://Tests/menu_autotest.gd"))
			probe.set("mode", arg.trim_prefix("--autotest-"))
			get_tree().root.add_child.call_deferred(probe)
			break


# ── 版本号 / 提交历史(git,结果缓存)──

# 读 git 输出为 UTF-8 文本。OS.execute 在中文 Windows 上按系统码页解码 → 中文乱码;
# execute_with_pipe 拿原始流,FileAccess.get_as_text 显式按 UTF-8 解。
static func _git_text(args: Array) -> String:
	var res: Variant = OS.execute_with_pipe("git", args, true)
	if res is Dictionary and res.has("stdio"):
		var f: FileAccess = res["stdio"]
		if f != null:
			# 分块读到 EOF,攒原始字节后显式按 UTF-8 解码
			# (get_as_text/get_buffer 单次在中文 Windows 会因系统码页/时机导致乱码或截断)
			var bytes := PackedByteArray()
			var guard := 0
			while not f.eof_reached() and guard < 1000:
				guard += 1
				var chunk := f.get_buffer(4096)
				if chunk.size() == 0:
					break
				bytes.append_array(chunk)
			if bytes.size() > 0:
				return bytes.get_string_from_utf8()
	var out: Array = []
	OS.execute("git", args, out, true)
	return str(out[0]) if out.size() > 0 else ""


static func version_string() -> String:
	if _version_cache != "":
		return _version_cache
	var branch := _git_text(["rev-parse", "--abbrev-ref", "HEAD"]).strip_edges()
	var n := _git_text(["rev-list", "--count", "HEAD"]).strip_edges()
	_version_cache = ("%s #%s" % [branch, n]) if branch != "" else "dev"
	return _version_cache


# 提交历史(新→旧,最多 20 条):[{hash,time,subject}]
static func commit_log() -> Array:
	if not _log_cache.is_empty():
		return _log_cache
	for line in _git_text(["-c", "i18n.logOutputEncoding=UTF-8",
			"log", "--pretty=%h|%cI|%s", "-20"]).split("\n"):
		var parts := line.strip_edges().split("|", true, 2)
		if parts.size() == 3:
			_log_cache.append({
				"hash": parts[0],
				"time": parts[1].replace("T", " ").substr(0, 16),
				"subject": parts[2],
			})
	return _log_cache


# ── 新版 UI ──
func _build_new_ui() -> void:
	# 背景:实机演示。优先复用保活的演示世界(避免反复构建/释放物理世界 → 原生段错误)
	if Level0.menu_demo_instance != null and is_instance_valid(Level0.menu_demo_instance):
		var reused: Node = Level0.menu_demo_instance
		add_child(reused)
		reused.revive_demo()
		_demo_level0 = reused
	else:
		Level0.menu_demo = true
		var level0: Node = load("res://Scenes/Level0.tscn").instantiate()
		add_child(level0)
		Level0.menu_demo = false   # 只影响本次实例化
		_demo_level0 = level0
	# 后处理(与游戏内一致的画面),再叠一层暗化让 UI 突出
	if _demo_level0 != null:
		var pp := PostProcess.new()
		pp.world_viewport = _demo_level0.get_node("WorldViewport")
		add_child(pp)

	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 140   # 盖过 PostProcess(128)/HUD(129)
	add_child(_ui_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.05, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(dim)

	# 大标题:中央浮现(描边同色加粗);下面一行版本号
	var title := _pixel_label("The Cyancular Ruins", 104, Color(0.55, 0.95, 1.0))
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_outline_color", Color(0.55, 0.95, 1.0))
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.anchor_left = 0.5
	title.anchor_right = 0.5
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	title.offset_top = 200.0
	title.offset_bottom = 340.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.modulate.a = 0.0
	_ui_layer.add_child(title)

	var ver := _pixel_label("dev" if "--nover" in OS.get_cmdline_user_args() else version_string(),
			30, Color(0.75, 0.85, 0.9, 0.9))
	ver.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	ver.anchor_left = 0.5
	ver.anchor_right = 0.5
	ver.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ver.offset_top = 352.0
	ver.offset_bottom = 392.0
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.modulate.a = 0.0
	_ui_layer.add_child(ver)

	# 模式按钮:标题之后从中央依次浮现
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_top = 130.0
	box.add_theme_constant_override("separation", 18)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	_ui_layer.add_child(box)

	var start_btn := _pixel_button("单 人 模 式", 38)
	start_btn.pressed.connect(_on_single_pressed)
	var multi_btn := _pixel_button("多 人 对 战", 38)
	multi_btn.pressed.connect(func() -> void:
		PvpSession.reset()
		_leave_menu("res://Scenes/matchmaking.tscn"))
	var royale_btn := _pixel_button("大 乱 斗", 38)
	royale_btn.pressed.connect(func() -> void:
		PvpSession.reset()
		PvpSession.royale = true
		_leave_menu("res://Scenes/royale_lobby.tscn"))
	var settings_btn := _pixel_button("设      置", 38)
	settings_btn.pressed.connect(func() -> void:
		_leave_menu("res://Scenes/settings_menu.tscn"))
	var ver_btn := _pixel_button("版 本 信 息", 38)
	ver_btn.pressed.connect(_on_version_pressed)
	var quit_btn := _pixel_button("退      出", 38)
	quit_btn.pressed.connect(func() -> void: get_tree().quit())
	for b in [start_btn, multi_btn, royale_btn, settings_btn, ver_btn, quit_btn]:
		box.add_child(b)

	# 浮现动画:标题先出(淡入),按钮依次淡入
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	var delay := 0.9
	for b in [start_btn, multi_btn, royale_btn, settings_btn, ver_btn, quit_btn]:
		_emerge(b, delay, 0.5)
		delay += 0.16


# 元素浮现:延迟后淡入。按钮由容器管理布局,只做透明度。
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


func _on_version_pressed() -> void:
	Sfx.play("ui")
	if _ver_panel != null:
		_ver_panel.visible = not _ver_panel.visible
		return
	_ver_panel = _build_ver_panel()
	_ui_layer.add_child(_ver_panel)


# ── 版本信息面板:当前版本 + 提交历史 ──
func _build_ver_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.custom_minimum_size = Vector2(1180, 0)
	panel.add_child(vb)

	vb.add_child(_pixel_label("—— 版本信息 ——", 44, Color(0.6, 0.95, 1.0)))
	vb.add_child(_pixel_label("当前版本: %s(分支名 + 提交序号)" % version_string(), 26))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(1160, 620)
	vb.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.custom_minimum_size = Vector2(1120, 0)
	scroll.add_child(list)

	var log := commit_log()
	if log.is_empty():
		list.add_child(_pixel_label("(读不到 git 历史:仓库不可用或未安装 git)", 24, Color(0.9, 0.6, 0.5)))
	var total := log.size()
	for i in range(log.size()):
		var e: Dictionary = log[i]
		var row := _pixel_label("%s  %s  %s" % [str(e["hash"]), str(e["time"]), str(e["subject"])],
				22, Color(0.92, 0.95, 1.0))
		list.add_child(row)

	var back := _pixel_button("返 回", 30)
	back.pressed.connect(func() -> void: panel.visible = false)
	vb.add_child(back)
	return panel


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
	for slot in [1, 2, 3, 4, 5, 6]:
		var cb := CheckButton.new()
		cb.text = "%d. %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]]
		cb.icon = WeaponComponent.silhouette(slot)   # 纯白像素剪影,便于辨认
		cb.expand_icon = false
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
		_enter_level0())
	var back := _pixel_button("返回", 34)
	back.pressed.connect(func() -> void: panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel


# ── 旧版 UI(Settings.old_ui=true):保留原布局,追加设置/版本信息入口 ──
func _build_old_ui() -> void:
	# 深色底(与原版默认灰底观感一致;全局清屏色被 Level0 改浅蓝后白字看不清)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.13, 0.15)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var title := Label.new()
	title.text = "The Cyancular Ruins"
	title.position = Vector2(60, 60)
	title.add_theme_font_size_override("font_size", 40)
	add_child(title)

	var ver := Label.new()
	ver.text = version_string()
	ver.position = Vector2(60, 112)
	ver.add_theme_font_size_override("font_size", 20)
	ver.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	add_child(ver)

	var single := Button.new()
	single.text = "单人"
	single.position = Vector2(60, 180)
	single.size = Vector2(200, 48)
	single.pressed.connect(func() -> void:
		_enter_level0())
	add_child(single)

	var multi := Button.new()
	multi.text = "多人"
	multi.position = Vector2(60, 240)
	multi.size = Vector2(200, 48)
	multi.pressed.connect(func() -> void:
		PvpSession.reset()
		_leave_menu("res://Scenes/matchmaking.tscn"))
	add_child(multi)

	var royale := Button.new()
	royale.text = "大乱斗"
	royale.position = Vector2(60, 300)
	royale.size = Vector2(200, 48)
	royale.pressed.connect(func() -> void:
		PvpSession.reset()
		PvpSession.royale = true
		_leave_menu("res://Scenes/royale_lobby.tscn"))
	add_child(royale)

	var settings := Button.new()
	settings.text = "设置"
	settings.position = Vector2(60, 360)
	settings.size = Vector2(200, 48)
	settings.pressed.connect(func() -> void:
		_leave_menu("res://Scenes/settings_menu.tscn"))
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
	b.custom_minimum_size = Vector2(360, 60)
	b.pressed.connect(func() -> void: Sfx.play("ui"))
	return b
