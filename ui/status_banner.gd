class_name StatusBanner
extends CanvasLayer

# 对局内**本地状态**横幅(阶段 3,spec §4 的 3.2 + 3.4,2026-09-28)。
# 目前只有一个数据源:`scenes/pvp_match_client.gd` 的断线重连状态机(`_set_status`)。
#
# ═══ 为什么必须有它(而不是接着 `print`)═══
# 阶段 1 把「重连中」降级成了 `print`,理由记在当时的计划里:`pvp_game` / `royale_game` /
# `team_game` 都是 **Node2D**,而 `UiFactory.panel_box()` 返回的是 **StyleBoxFlat(不是节点)**
# —— 没有一个"能挂上去的东西"。本类就是补上那个东西:`ui/status_banner.tscn` 是一个
# CanvasLayer,面板与文字由 `_ready()` 用 `UiFactory` 建 —— 与 `ui/match_result.tscn` 同一种
# 取舍(裸骨架 tscn + 代码建面板;理由是"手写锚点是'改错了不报错'的那一类",故让它与逻辑
# 同处一室,而不是散进 .tscn 的 offset 数字里)。见 `tests/hud_declarative_probe.gd` 文件头
# 关于"裸骨架 tscn 的 @onready 数为 0 是**正确形状**"那一段。
#
# ★★ **层位只住在 `ui/status_banner.tscn` 里**(`layer = 140`),脚本**不设** layer。
#   理由与结算页逐字相同:`.new()` 建出来的 CanvasLayer 是**默认的 layer 1** —— 会画在三个
#   对局 HUD(130)与小地图(131)**底下**,横幅被 HUD 盖住且**不报错**。
#   故宿主必须 `preload("res://ui/status_banner.tscn").instantiate()`;
#   守卫:`tests/hud_declarative_probe.gd` 的 ⑧。
# ★ 层位取 140 的推导:必须**高于** HUD(130)与小地图(131)(否则被盖住);必须**低于**
#   暂停菜单(145)与结算页(150)—— 那两块是模态性质的画面,横幅不该压在它们上面。
#   (真掉线时若菜单正开着,`_begin_reconnect` 会推迟到关菜单才动,那一刻菜单已经消失。)
#
# ★ 文本与配色**全部走 `UiFactory`**:颜色不在本文件写 `Color(...)` 字面量(调色板的唯一
#   来源是 `ui/ui_factory.gd`);字号必须是 16 的倍数(`kh_l4`/`kh_l5` 扫 `res://ui`)。

const FONT_SIZE := 32
# 顶中锚,落在记分条(offset_top 16)与「对手掉线中」那一条(offset_top 72)之下。
# ★ 这个数**不是**随手取的:1v1 的记分条高约 48px、其下那条 GraceWrap 到 120px 结束,
#   128 让三者互不重叠;大乱斗右上角的排行榜从 x≈1184 起,而本横幅按内容宽(实测最长的
#   "与服务器断线,正在重连…(剩余 60s)" 约 560px ⇒ 居中出现时占 680~1240,仍不压到它)。
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
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.offset_top = TOP_OFFSET
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)

	_label = Label.new()
	_label.name = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(_label, FONT_SIZE)
	_label.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_panel.add_child(_label)


# 空串 = 收起。★ 唯一调用方 = `PvpMatchClient._set_status`(见那里的四个转折点)。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
