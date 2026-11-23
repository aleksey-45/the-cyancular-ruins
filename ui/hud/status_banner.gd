class_name StatusBanner
extends CanvasLayer

# 对局内本地状态横幅(屏幕上方居中,半透明深底 + 危险色文案)。唯一数据源 = 宿主调 `set_text()`;
# 断线重连状态机等由接入方驱动(UI-3 集成),本组件不自己找数据 —— 对外接口与 main 的 status_banner.gd 一致。
# 视觉全走 v2 设计系统:底板 = `UiDesign.panel_box()`(全项目唯一 StyleBox 构造点),字号/间距/颜色一律 token,
# 本文件不写 StyleBox / Color 字面量 / 绝对坐标。

const FONT_SIZE := UiDesign.T_H2
# 纵向位置:记分条(上沿 16)与其下 GraceWrap 之后 = 128px = SP_9 × 2;横向/高度由内容撑开(_center_panel),
# 面板锚点固定在顶部居中,所以这里只有纵向 token 偏移。
const TOP_OFFSET := float(UiDesign.SP_9 * 2)

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	# CanvasLayer 本身不能布局:根 Control 铺满视口,面板挂在它下面才吃 anchors。
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	# 不描边面板(与 main 同视觉);底色/内边距都在 UiDesign 里,不在本文件手写 StyleBox。
	_panel.add_theme_stylebox_override("panel", UiDesign.panel_box(false))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)

	# 文字颜色 = C_DANGER(状态/断线提示的既有语义);字号走 UiDesign.style_control 的字体与断言。
	_label = UiDesign.label("", FONT_SIZE, UiDesign.C_DANGER)
	_label.name = "StatusLabel"
	_panel.add_child(_label)
	_center_panel()


# ★ 必须在改完文字之后重算居中:面板宽随文字变,否则居中会停在上一句的宽度上;
#   未入树时 get_combined_minimum_size() 不可信(会全塌成 0),故先挡掉。
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


# 空串 = 隐藏横幅(状态恢复/重连成功后的清空路径)。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	_center_panel()
