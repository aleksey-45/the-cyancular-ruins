class_name StatusBanner
extends CanvasLayer

# 在屏幕上方居中显示对局状态，例如掉线或重连。

const FONT_SIZE := UiDesign.T_H2
# 顶部偏移为比分和重连宽限计时预留空间。
const TOP_OFFSET := float(UiDesign.SP_9 * 2)

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	# 面板的锚点以铺满视口的根控件为参考。
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.add_theme_stylebox_override("panel", UiDesign.panel_box(false))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)

	_label = UiDesign.label("", FONT_SIZE, UiDesign.C_DANGER)
	_label.name = "StatusLabel"
	_panel.add_child(_label)
	_center_panel()


# 提示文字改变面板的最小宽度，入树后按新宽度重新居中。
func _center_panel() -> void:
	if _panel == null or not _panel.is_inside_tree():
		return
	_panel.update_minimum_size()
	var ms: Vector2 = _panel.get_combined_minimum_size()
	var half := ms * 0.5
	_panel.offset_left = -half.x
	_panel.offset_right = half.x
	_panel.offset_top = TOP_OFFSET
	_panel.offset_bottom = TOP_OFFSET + ms.y


# 空字符串用于隐藏横幅。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	_center_panel()
