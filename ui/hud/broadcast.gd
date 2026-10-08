class_name Broadcast
extends Control

# 中央广播界面组件：
# 提供全屏半透明压暗遮罩、居中提示面板以及大标题与副标题显示。
# 支持开场倒计时、局间结算与比赛终局等状态通知。

# 主标题字号
const BIG_FONT := 144
# 副标题字号
const SUB_FONT := 64

# 全屏背景半透明遮罩色
const MASK_COLOR := Color(0, 0, 0, 0.3)

# 标题面板最小宽度
const STRIP_MIN_W := 640.0

# 倒计时数字跳动脉冲缩放幅度与衰减率
const PUNCH_SCALE := 0.06
const PUNCH_DECAY := 4.0

# 倒计时结束信号
signal countdown_finished

# 广播节点组件引用
var mask: ColorRect = null
var big: Label = null
var sub: Label = null

# 是否启用数字跳动微缩放动效
var punch_enabled := true

var _center: CenterContainer = null
var _panel: PanelContainer = null
var _counting := false
var _countdown := 0.0
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


# 设置广播显示状态与文案
func set_broadcast(show: bool, big_text: String, sub_text: String) -> void:
	_counting = false
	mask.visible = show
	_center.visible = show
	big.text = big_text
	sub.text = sub_text
	_punch = 1.0 if show else 0.0
	_apply_punch()


# 启动倒计时广播
func start_countdown(seconds: float, sub_text: String) -> void:
	_countdown = seconds
	_counting = true
	mask.visible = true
	_center.visible = true
	sub.text = sub_text
	_set_big_text(str(maxi(ceili(_countdown), 1)))


func stop_countdown() -> void:
	_counting = false


func is_counting() -> bool:
	return _counting


# 驱动倒计时进度与动效衰减
func tick(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * PUNCH_DECAY)
		_apply_punch()
	if not _counting:
		return
	_countdown -= delta
	if _countdown > 0.0:
		_set_big_text(str(maxi(ceili(_countdown), 1)))
	else:
		_counting = false
		countdown_finished.emit()


# 更新主文本并在内容发生变动时触发脉冲
func _set_big_text(t: String) -> void:
	if big.text == t:
		return
	big.text = t
	_punch = 1.0
	_apply_punch()


# 以面板中心为原点应用缩放动效
func _apply_punch() -> void:
	if not punch_enabled or _panel == null:
		return
	if _panel.size.x <= 0.0:
		return
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)

