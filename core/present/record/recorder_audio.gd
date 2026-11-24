extends RefCounted

# 录屏音频采集（Master 总线 AudioEffectCapture）与 REC 指示器。
# host = 宿主的 Recorder 节点：只用来挂指示器；WAV 落盘对象由 host 在调用时传入。
# 相对 main 的适配：指示器不用旧 UiFactory，改走 UI 设计系统 v2（UiDesign token + 像素字体）。

const AUDIO_BUFFER := 1.5

# ── REC 指示器：对齐 siri HUD 的 24/32 系（ui/hud/hud.gd + ui/hud/kill_counter.gd）──
# 击杀计数器：锚 right、距边 SP_6(32)，底板 content margin SP_4(16) ⇒ 文字右缘在 48。
# 纵向：距顶 SP_4(16) + 字高 T_H1(48) + 上下 content margin SP_2(8)×2 = 80，再空 SP_2(8) 起 REC。
const REC_FONT := UiDesign.T_H2           # 与 HUD 次级字号同档（32）
const REC_RIGHT := float(UiDesign.SP_6 + UiDesign.SP_4)   # 48：对齐击杀计数器文字右缘
const REC_TOP := float(UiDesign.SP_4 + UiDesign.T_H1 + UiDesign.SP_2 * 2 + UiDesign.SP_2)
const REC_HALF_W := 160.0                 # 定宽框，文字框内右对齐

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
		var label := UiDesign.label("● REC", REC_FONT, UiDesign.C_DANGER)
		label.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
		label.add_theme_constant_override("outline_size", 4)
		# 文字在定宽框内右对齐；锚在右上角，右缘与击杀计数器文字右缘同一条线。
		label.anchor_left = 1.0
		label.anchor_right = 1.0
		label.anchor_top = 0.0
		label.anchor_bottom = 0.0
		label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.offset_left = -REC_RIGHT - REC_HALF_W
		label.offset_right = -REC_RIGHT
		label.offset_top = REC_TOP
		label.offset_bottom = REC_TOP
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_indicator.add_child(label)
		_indicator_label = label
		_host.add_child(_indicator)
	if _indicator_label != null:
		_indicator.visible = on
