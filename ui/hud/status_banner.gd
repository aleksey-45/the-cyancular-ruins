class_name StatusBanner
extends CanvasLayer

# 对局内本地状态横幅。唯一数据源:宿主 `_set_status`(S-17 后由 `scenes/mp_client/reconnect_driver.gd` 的断线重连状态机驱动)。

const FONT_SIZE := UiFactory.T_H2
# 纵向位置 = 记分条(16..68)+ GraceWrap(72..124)之下;128 = SP_9 × 2(几何推导见 docs/systems/presentation/ui.md
# 「对局内状态横幅」)。横向/高度由内容撑开(_center_panel),不写绝对坐标。
const TOP_OFFSET := float(UiFactory.SP_9 * 2)

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


func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	# ★ 必须在改完文字之后重算居中:面板宽随文字变,否则居中会停在上一句的宽度上。
	_center_panel()
