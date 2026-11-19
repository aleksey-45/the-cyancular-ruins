extends RefCounted

# 录屏音频采集（Master 总线 AudioEffectCapture）与 REC 指示器。
# host = 宿主的 Recorder 节点：只用来挂指示器；WAV 落盘对象由 host 在调用时传入。

const AUDIO_BUFFER := 1.5

# ── REC 指示器：对齐 HUD 的 24/32 系（ui/hud/hud.gd）──
# REC：右上角，右边缘与击杀计数器同一条 -32 线，纵向排在击杀计数器下方。
const REC_FONT := 32             # 与 HUD 时钟同号
# 击杀计数器的 PanelContainer 右边缘是 -32，但它的文字还有 16px 右 content margin；
# REC 没有底板，要对齐的是文字右缘，所以取 32+16=48。
const REC_RIGHT := 48.0
const REC_TOP := 16.0 + 48.0 + 12.0 + 8.0   # 击杀计数器 top16 + 48 字 + 上下 margin 12 + 间距 8

var _host: Node = null
var _cap: AudioEffectCapture = null
var _bus := -1
var _fx := -1
var _indicator: CanvasLayer = null
var _indicator_label: Label = null


func _init(host: Node) -> void:
	_host = host


func attach_audio() -> void:
	if _cap != null:
		return
	_bus = AudioServer.get_bus_index("Master")
	_cap = AudioEffectCapture.new()
	_cap.buffer_length = AUDIO_BUFFER
	_fx = AudioServer.get_bus_effect_count(_bus)
	AudioServer.add_bus_effect(_bus, _cap)
	_cap.clear_buffer()


func detach_audio() -> void:
	if _cap == null:
		return
	if _bus >= 0 and _fx >= 0:
		AudioServer.remove_bus_effect(_bus, _fx)
	_cap = null
	_bus = -1
	_fx = -1


func has_capture() -> bool:
	return _cap != null


func clear_capture() -> void:
	if _cap != null:
		_cap.clear_buffer()


func drain_audio(wav) -> void:
	if _cap == null:
		return
	var n := _cap.get_frames_available()
	if n <= 0:
		return
	var buf: PackedVector2Array = _cap.get_buffer(n)
	if wav != null:
		wav.add_frames(buf)


func stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]


func show_indicator(on: bool) -> void:
	if _indicator == null:
		_indicator = CanvasLayer.new()
		_indicator.name = "RecordIndicator"
		_indicator.layer = 200
		_indicator.process_mode = Node.PROCESS_MODE_ALWAYS
		var label := Label.new()
		label.text = "● REC"
		UiFactory.style_control(label, REC_FONT)
		label.add_theme_color_override("font_color", UiFactory.C_DANGER)
		label.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
		label.add_theme_constant_override("outline_size", 4)
		# 文字在定宽框内右对齐。
		label.anchor_left = 1.0
		label.anchor_right = 1.0
		label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.offset_left = -REC_RIGHT - 160.0
		label.offset_right = -REC_RIGHT
		label.offset_top = REC_TOP
		label.offset_bottom = REC_TOP
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_indicator.add_child(label)
		_indicator_label = label
		_host.add_child(_indicator)
	if _indicator_label != null:
		_indicator.visible = on
