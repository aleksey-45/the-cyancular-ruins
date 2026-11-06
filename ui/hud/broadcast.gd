class_name Broadcast
extends Control


# 巨大数字 / 主文案。字号必须是 16 的倍数(本项目像素字体硬约定,见 ui/factory/ui_factory.gd 文件头)。
const BIG_FONT := 144
const SUB_FONT := 64

const MASK_COLOR := Color(0, 0, 0, 0.3)

const STRIP_MIN_W := 640.0

const PUNCH_SCALE := 0.06
const PUNCH_DECAY := 4.0

signal countdown_finished

var mask: ColorRect = null
var big: Label = null
var sub: Label = null

var punch_enabled := true

var _center: CenterContainer = null
var _panel: PanelContainer = null
var _clock := CountdownClock.new()
var _punch := 0.0


func _ready() -> void:
	PixelFont.shared()

	mask = ColorRect.new()
	mask.name = "Mask"
	mask.color = MASK_COLOR
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.visible = false
	add_child(mask)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.visible = false
	add_child(_center)

	_panel = UiFactory.menu_panel(Vector2(72, 44))
	_center.add_child(_panel)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 24)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(_panel.get_node("Body") as Container).add_child(box)

	var strip := UiFactory.header_strip("", BIG_FONT)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big = strip.get_child(0) as Label
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.custom_minimum_size = Vector2(STRIP_MIN_W, 0)
	box.add_child(strip)

	sub = UiFactory.label("", SUB_FONT, UiFactory.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)


func set_broadcast(show: bool, big_text: String, sub_text: String) -> void:
	_clock.stop()
	mask.visible = show
	_center.visible = show
	big.text = big_text
	sub.text = sub_text
	_punch = 1.0 if show else 0.0
	_apply_punch()


func start_countdown(seconds: float, sub_text: String) -> void:
	_clock.start(seconds)
	mask.visible = true
	_center.visible = true
	sub.text = sub_text
	_set_big_text(_clock.text())


func is_counting() -> bool:
	return _clock.running()


func tick(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * PUNCH_DECAY)
		_apply_punch()
	var r := _clock.tick(delta)
	if r == CountdownClock.TICK_RUNNING:
		_set_big_text(_clock.text())
	elif r == CountdownClock.TICK_FINISHED:
		countdown_finished.emit()


func _set_big_text(t: String) -> void:
	if big.text == t:
		return
	big.text = t
	_punch = 1.0
	_apply_punch()


func _apply_punch() -> void:
	if not punch_enabled or _panel == null:
		return
	if _panel.size.x <= 0.0:
		return
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)
