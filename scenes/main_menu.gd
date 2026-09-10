extends Control
# 主菜单(像素 UI):粗体大标题 + 模式按钮浮现动画,场景是裸 Control,UI 全在代码里建。
# 标题下方显示版本号(分支名 + git 提交序号);「版本信息」列出本分支提交历史。
# 「单人模式」弹出开局面板(勾选本局禁用武器),确认后进 Level0。
# 控件一律走 UiFactory(像素字体与字号规范的单一来源);字号必须是 16 的倍数。

static var _version_cache := ""
static var _log_cache: Array = []

var _ui_layer: CanvasLayer = null
var _sp_panel: PanelContainer = null    # 单人开局面板(弹出式)
var _ver_panel: PanelContainer = null   # 版本信息面板(弹出式)


func _ready() -> void:
	# 复位对局相关全局(进过 PvP 回来不残留)
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	# 上次单人开局选择(存档在 Settings)
	RunOptions.reset()
	RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()

	_build_new_ui()


# 单机进关卡(Level0 = 全量物理世界)。菜单是纯 UI(无世界、无大物理),普通切场景即可:
# change_scene 在这里只会销毁一棵 Control 树,不存在「销毁大世界 × 构建大世界」的同帧对撞。
# 反方向(游戏世界退役回菜单)才需要挂起式切换,见 Level0.safe_change_scene 的注释。
func _enter_level0() -> void:
	Level0.pvp_mode = false            # 复位 PvP 标志,避免上次 PvP 残留
	CombatComponent.pvp_arena = false  # 回单机恢复命中无敌帧
	get_tree().change_scene_to_file("res://scenes/Level0.tscn")


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


# ── 菜单 UI ──
func _build_new_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 140   # 盖过 PostProcess(128)/HUD(129)
	add_child(_ui_layer)
	# 暗化底:菜单背景是空的,垫一层深色让像素字突出、按钮层次清楚
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.05, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(dim)

	# 大标题:中央浮现(描边同色加粗);下面一行版本号
	var title := UiFactory.label("The Cyancular Ruins", 96, Color(0.55, 0.95, 1.0))
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

	var ver := UiFactory.label("dev" if "--nover" in OS.get_cmdline_user_args() else version_string(),
			32, Color(0.75, 0.85, 0.9, 0.9))
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

	var start_btn := UiFactory.button("单 人 模 式", 32)
	start_btn.pressed.connect(_on_single_pressed)
	var multi_btn := UiFactory.button("多 人 对 战", 32)
	multi_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()
		get_tree().change_scene_to_file("res://scenes/matchmaking.tscn"))
	var settings_btn := UiFactory.button("设      置", 32)
	settings_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/settings_menu.tscn"))
	var ver_btn := UiFactory.button("版 本 信 息", 32)
	ver_btn.pressed.connect(_on_version_pressed)
	var quit_btn := UiFactory.button("退      出", 32)
	quit_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().quit())
	for b in [start_btn, multi_btn, settings_btn, ver_btn, quit_btn]:
		box.add_child(b)

	# 浮现动画:标题先出(淡入),按钮依次淡入
	var tw := create_tween()
	tw.tween_interval(0.1)
	tw.tween_property(title, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(ver, "modulate:a", 1.0, 1.1).set_trans(Tween.TRANS_SINE)
	var delay := 0.9
	for b in [start_btn, multi_btn, settings_btn, ver_btn, quit_btn]:
		_emerge(b, delay, 0.5)
		delay += 0.16


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

	vb.add_child(UiFactory.label("—— 版本信息 ——", 48, Color(0.6, 0.95, 1.0)))
	vb.add_child(UiFactory.label("当前版本: %s(分支名 + 提交序号)" % version_string(), 32))

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(1160, 620)
	vb.add_child(scroll)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.custom_minimum_size = Vector2(1120, 0)
	scroll.add_child(list)

	var log := commit_log()
	if log.is_empty():
		list.add_child(UiFactory.label("(读不到 git 历史:仓库不可用或未安装 git)", 32, Color(0.9, 0.6, 0.5)))
	for i in range(log.size()):
		var e: Dictionary = log[i]
		var row := UiFactory.label("%s  %s  %s" % [str(e["hash"]), str(e["time"]), str(e["subject"])],
				16, Color(0.92, 0.95, 1.0))
		list.add_child(row)

	var back := UiFactory.button("返 回", 32)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	vb.add_child(back)
	return panel


# ── 单人开局面板:禁用武器(勾选 = 本局不可用)──
func _build_sp_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(560, 0)
	panel.add_child(vb)

	vb.add_child(UiFactory.label("—— 单人开局 ——", 48, Color(0.6, 0.95, 1.0)))
	vb.add_child(UiFactory.label("禁用武器(勾选 = 本局不可用)", 32))

	var checks: Array[CheckButton] = []
	for slot in [1, 2, 3, 4, 5, 6]:
		var cb := CheckButton.new()
		cb.text = "%d. %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]]
		cb.icon = WeaponComponent.silhouette(slot)   # 纯白像素剪影,便于辨认
		cb.expand_icon = false
		UiFactory.style_control(cb, 32)
		cb.button_pressed = Settings.sp_disabled_weapons.has(slot)
		checks.append(cb)
		vb.add_child(cb)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	vb.add_child(row)
	var go := UiFactory.button("开 始 探 索", 32)
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				Settings.sp_disabled_weapons.append(i + 1)
		Settings.save()
		RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
		_enter_level0())
	var back := UiFactory.button("返回", 32)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel
