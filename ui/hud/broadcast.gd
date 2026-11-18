class_name Broadcast
extends Control

var _title: Label
var _subtitle: Label
var _panel: PanelContainer
var _countdown := 0.0
var _punch := 0.0

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	var body := VBoxContainer.new()
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", 24)
	body.mouse_filter = MOUSE_FILTER_IGNORE
	_panel = UiFactory.centered(self, body, 0.30, false)
	var strip := UiFactory.header_strip("", 144, true)
	strip.mouse_filter = MOUSE_FILTER_IGNORE
	_title = strip.get_child(0)
	_title.custom_minimum_size.x = 640
	body.add_child(strip)
	_subtitle = UiFactory.label("", 64, UiFactory.C_TEXT_DIM)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_subtitle)
	hide()

func set_broadcast(show: bool, title: String, subtitle: String) -> void:
	_countdown = 0.0
	visible = show
	_title.text = title
	_subtitle.text = subtitle
	_punch = 1.0 if show else 0.0
	_apply_punch()

func start_countdown(seconds: float, subtitle: String) -> void:
	_countdown = seconds
	show()
	_subtitle.text = subtitle
	_count(maxi(ceili(_countdown), 1))

func present(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * 4.0)
		_apply_punch()
	if _countdown > 0.0:
		_countdown -= delta
		if _countdown > 0.0:
			_count(ceili(_countdown))

func _count(number: int) -> void:
	var text := str(number)
	if _title.text != text:
		_title.text = text
		_punch = 1.0
		_apply_punch()

func _apply_punch() -> void:
	if _panel.size.x > 0.0:
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2.ONE * (1.0 + 0.06 * _punch)
