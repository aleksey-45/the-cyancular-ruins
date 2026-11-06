extends CanvasLayer


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

	var strip := UiFactory.header_strip("载 入 中", 48, true)
	strip.custom_minimum_size = Vector2(720, 0)
	vb.add_child(strip)

	_pct = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pct.custom_minimum_size = Vector2(720, 0)
	vb.add_child(_pct)
	_title = _pct


func show_loading(text: String = "正在构建世界…") -> void:
	if _pct != null and text != "":
		_pct.text = text
	visible = true


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
