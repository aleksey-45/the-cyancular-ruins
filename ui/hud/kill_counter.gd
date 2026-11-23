class_name KillCounter
extends PanelContainer

# 右上角击杀计数(三位零填充)。main 的 kill_counter.tscn 只有骨架、样式由 hud.gd 集成时给;
# siri 这里把骨架 + 样式 + 计数格式收进一个**独立可加载**的组件,免得 Lead 在 Hud 里再抄一份 token:
#   · .tscn = 面板 + 名为 "KillLabel" 的 Label(初始 "000",编辑器里也能看);
#   · 本脚本 = HUD 底板(不画底色,设计系统例外二)+ 字号/颜色 + `set_kills()`。
# 锚点/层位留给集成方(main:锚 right、SP_6 距边、SP_4 距顶,生长方向 BEGIN)—— 组件不写绝对坐标。

const FONT_SIZE := UiDesign.T_H1    # 48:16 的倍数,像素字体锐利
const KILL_COLOR := UiDesign.C_ACCENT

var _label: Label = null
var _kills := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# draw_center = false:只留 content margin 撑出留白,不垫底色(与 main / 设计系统「例外二」一致)。
	UiDesign.hud_plate(self, UiDesign.SP_4, UiDesign.SP_2, false)

	_label = get_node_or_null("KillLabel") as Label
	if _label == null:
		_label = UiDesign.label("", FONT_SIZE, KILL_COLOR)
		_label.name = "KillLabel"
		add_child(_label)
	else:
		_label.add_theme_color_override("font_color", KILL_COLOR)
		UiDesign.style_control(_label, FONT_SIZE)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply()


# 每死一个敌人调一次,或直接灌当前总数(两种集成方式都安全,重复调用幂等)。
func set_kills(n: int) -> void:
	_kills = maxi(n, 0)
	_apply()


func kills() -> int:
	return _kills


func _apply() -> void:
	if _label != null:
		_label.text = "%03d" % _kills
