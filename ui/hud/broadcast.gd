class_name Broadcast
extends Control

# 对局中央提示，显示开局倒计时、对局结果和等待信息。
const BIG_SIZE := UiDesign.T_H1 * 3   # 144
const SUB_SIZE := UiDesign.T_H2 * 2   # 64

const MASK_ALPHA := 0.3

# 标题设置最小宽度，以免面板随倒计时数字变化而抖动。
const STRIP_MIN_W := 640.0

const PUNCH_SCALE := 0.06
const PUNCH_DECAY := 4.0

var mask: ColorRect
var big: Label
var sub: Label

var _center: CenterContainer
var _panel: PanelContainer
var _clock := CountdownClock.new()
var _punch := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 提示显示时压暗对局画面，便于阅读。
	mask = ColorRect.new()
	mask.name = "Mask"
	mask.color = UiDesign.C_BG
	mask.modulate.a = MASK_ALPHA
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.visible = false
	add_child(mask)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.visible = false
	add_child(_center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.add_child(_panel)

	var body := VBoxContainer.new()
	body.name = "Box"
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiDesign.skin_menu_panel(_panel, Vector2(72, 44)).add_child(body)

	var strip := UiDesign.header_strip("", BIG_SIZE, true)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big = strip.title
	big.custom_minimum_size.x = STRIP_MIN_W
	body.add_child(strip)

	sub = UiDesign.label("", SUB_SIZE, UiDesign.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(sub)
	hide()


func set_broadcast(visible_on: bool, title: String, subtitle: String) -> void:
	_clock.stop()
	visible = visible_on
	mask.visible = visible_on
	_center.visible = visible_on
	big.text = title
	sub.text = subtitle
	_punch = 1.0 if visible_on else 0.0
	_apply_punch()


func start_countdown(seconds: float, subtitle: String) -> void:
	show()
	mask.visible = true
	_center.visible = true
	sub.text = subtitle
	_count(_clock.start(seconds))


func _process(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * PUNCH_DECAY)
		_apply_punch()
	# 倒计时停止后保留最后显示的数字。
	var number := _clock.tick(delta)
	if number > 0:
		_count(number)


func _count(number: int) -> void:
	var text := str(number)
	if big.text != text:
		big.text = text
		_punch = 1.0
		_apply_punch()


func _apply_punch() -> void:
	if _panel.size.x > 0.0:
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)
