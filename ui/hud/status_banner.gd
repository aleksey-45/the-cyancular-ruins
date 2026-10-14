class_name StatusBanner
extends CanvasLayer

# 对局内本地状态横幅。唯一数据源:`scenes/pvp_match_client.gd` 的断线重连状态机(`_set_status`)。
#
# 为什么需要一个类:`pvp_game` / `royale_game` / `team_game` 都是 Node2D,而
# `UiFactory.panel_box()` 返回的是 StyleBoxFlat(不是节点) —— 没有"能挂上去的东西"。
# 取舍与 `ui/screens/match_result.tscn` 同款:裸骨架 `.tscn` + 代码建面板(手写锚点是
# "改错了不报错"的那一类,故让它与逻辑同处一室)。
#
# 层位(layer 140)只住在 `ui/hud/status_banner.tscn` 里,脚本不设 layer:`.new()` 出来的
# CanvasLayer 是默认 layer 1,会画在三个对局 HUD(130)与小地图(131)底下且不报错。
# ⇒ 宿主必须 `preload("res://ui/hud/status_banner.tscn").instantiate()`。
# 层位取 140 的推导(高于 HUD / 低于暂停菜单与结算页)见 `docs/eng/ui.md`。
#
# 文本与配色全部走 `UiFactory`:本文件不写 `Color(...)` 字面量;字号必须是 16 的倍数。
# ⚠ 扫字号的两支源码级守卫 `kh_l4` / `kh_l5` 已删·2026-10-09 ⇒ 这一条今天零守卫。

const FONT_SIZE := 32
# 顶中锚的纵向落点。128 是唯一的纵向常量;它必须让三带互不重叠 ——
# 记分条 y∈[16,68] / GraceWrap y∈[72,124] / 本横幅 y∈[128,204](都是 2026-09-28 headless 实测)。
# ⚠ 已知边界(登记,不修):大乱斗排行榜左缘 x=1184,而最长文案的面板宽实测 568 ⇒ 右端 1244,
#   横幅右侧侵入 60px;只有大乱斗看得见,不能靠下挪这个常量解决。
# 推导、Label 行高(纯拉丁 33 / 含 CJK 36)与修法候选都在 `docs/eng/ui.md`「状态横幅的几何与层位」。
# 那一段今天零自动化守卫(相关探针已删·2026-10-09)⇒ 改几何要人眼看一局大乱斗。
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
# 未入树时 `set_anchor` 拿到的 `parent_range` 是 `Rect2()`(引擎 `Control::get_parent_anchorable_rect`
# 首行就 `return Rect2()`),于是四个偏移量全塌成 0 ⇒ 面板按最小尺寸向右长出去、左缘钉在视口中心
# (与 `ui/screens/match_result.gd` 的 `show_result()` 末端同一个先例)。
# 横向没有常量:宽度 = 文字宽 + 左右各 28px 内边距,每次 `set_text` 都要重算。
# `update_minimum_size()` 不是多余的:标签缓存本来就失效时,面板那份陈旧缓存不会被作废,
# 直接读会拿到上一句文字的宽度。推导见 `docs/eng/ui.md`「状态横幅的几何与层位」。
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
