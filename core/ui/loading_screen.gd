extends CanvasLayer

# 跨场景「载入中」遮罩(2026-10-24)。用途 = Web 上 Level0 的建图被拆成多帧(9 份环面瓦片/水面/整层碰撞),
# 期间用一个挡画面的遮罩 + 进度文字替代"点完开始黑屏几秒"。
# ★ 桌面建图很快 ⇒ 只有调用方显式 show_loading() 才亮(目前只有 main_menu 在 Web 上进关前会调),不改变桌面观感。
# ★ 必须在「树暂停」时也刷新:Web 建图期间 get_tree().paused = true(冻结玩家/敌人物理),遮罩要能画出来 ⇒ PROCESS_MODE_ALWAYS。
# ★ 层位 200:高于 PauseMenu(145) / 结算(150),任何一屏都能盖住。

var _dim: ColorRect = null
var _title: Label = null
var _pct: Label = null


func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false


func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 吃鼠标/键盘:载入期间别让玩家点到底下的按钮(桌面虽然一闪而过,Web 上要几秒)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(root)

	_dim = ColorRect.new()
	_dim.color = UiFactory.C_BG
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 24)
	center.add_child(vb)

	# 标题带用工厂的 header_strip(与暂停/结算同一个味道);居中档保证窄面板里不贴边。
	var strip := UiFactory.header_strip("载 入 中", 48, true)
	strip.custom_minimum_size = Vector2(720, 0)
	vb.add_child(strip)

	_pct = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pct.custom_minimum_size = Vector2(720, 0)
	vb.add_child(_pct)
	_title = _pct   # 同一行兼作"当前阶段"文字(进度百分比由 set_progress 一起写)


# 亮起遮罩;text 是阶段说明(空 = 保持原样)。
func show_loading(text: String = "正在构建世界…") -> void:
	if _pct != null and text != "":
		_pct.text = text
	visible = true


# 更新进度。p 只在有实际进度时给(0..1);text 覆盖当前阶段文字。
func set_progress(p: float, text: String = "") -> void:
	if not visible:
		visible = true
	if _pct == null:
		return
	var body := text
	if body == "":
		body = "正在构建世界…"
	if p >= 0.0:
		body += "  %d%%" % int(round(clampf(p, 0.0, 1.0) * 100.0))
	_pct.text = body


func hide_loading() -> void:
	visible = false
	_pct.text = ""
