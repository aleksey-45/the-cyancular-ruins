class_name StatusBanner
extends CanvasLayer

# 局内网络与连接状态横幅：
# 用于在屏幕顶部居中显示断线重连、网络波动等关键本地状态提示。
# 由客户端连接状态机驱动显示与更新。

const FONT_SIZE := 32
# 顶部垂直偏移量（避开记分栏与上方状态栏）
const TOP_OFFSET := 128.0

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	PixelFont.shared()
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)

	_label = Label.new()
	_label.name = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(_label, FONT_SIZE)
	_label.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_panel.add_child(_label)
	_center_panel()


# 依据标签文本尺寸动态居中对齐面板
func _center_panel() -> void:
	if not _panel.is_inside_tree():
		return
	_panel.update_minimum_size()
	var ms := _panel.get_combined_minimum_size()
	var half := ms * 0.5
	_panel.offset_left = -half.x
	_panel.offset_right = half.x
	_panel.offset_top = TOP_OFFSET
	_panel.offset_bottom = TOP_OFFSET + ms.y


# 设置横幅提示文字，传入空字符串时自动隐藏面板
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	_center_panel()

