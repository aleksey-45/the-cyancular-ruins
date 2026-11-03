class_name StatusBanner
extends CanvasLayer

# 对局内本地状态横幅。唯一数据源:宿主 `_set_status`(S-17 后由 `scenes/mp_client/reconnect_driver.gd` 的断线重连状态机驱动)。

const FONT_SIZE := 32
# 顶中锚的纵向落点。128 是唯一的纵向常量;它必须让三带互不重叠 ——
const TOP_OFFSET := 128.0

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	# 汉字回退链 + 关抗锯齿/微调/子像素(本项目像素字体硬约定,同三个 HUD)。
	PixelFont.shared()
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ IGNORE:横幅只给人看,绝不能吃掉点击(棋盘下面的暂停菜单/按钮得照常可点)。
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	# 不透明面板(`panel_box(false)` 不描边):它可能压在浅灰蓝的地图开阔区上,半透明会读不清。
	_panel.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)
	# ★★ 锚点必须在这一行之后设(已入树)—— 未入树时 `set_anchor` 拿到的 `parent_range`
	#    是 0,四个偏移量会全塌成 0(详见 `_center_panel()` 上方那段踩坑记录)。
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)

	_label = Label.new()
	_label.name = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(_label, FONT_SIZE)
	_label.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_panel.add_child(_label)
	# ★★ 锚点 / 偏移量都在这里设 —— 而且必须在 `root.add_child(_panel)` 之后
	#    (即入树之后),理由见 `_center_panel()`。
	_center_panel()


# 顶中居中:四个偏移量必须自己算,而且必须在入树之后算。
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


# 空串 = 收起。★ 唯一调用方 = `PvpMatchClient._set_status`(见那里的五个转折点)。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	# ★ 必须在改完文字之后重算居中:面板宽随文字变,否则居中会停在上一句的宽度上。
	_center_panel()
