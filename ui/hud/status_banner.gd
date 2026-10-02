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
#   故宿主必须 `preload("res://ui/hud/status_banner.tscn").instantiate()`;
#   守卫:`tests/hud_declarative_probe.gd` 的 ⑧。
# ★ 层位取 140 的推导:必须**高于** HUD(130)与小地图(131)(否则被盖住);必须**低于**
#   暂停菜单(145)与结算页(150)—— 那两块是模态性质的画面,横幅不该压在它们上面。
#   (真掉线时若菜单正开着,`_begin_reconnect` 会推迟到关菜单才动,那一刻菜单已经消失。)
#
# ★ 文本与配色**全部走 `UiFactory`**:颜色不在本文件写 `Color(...)` 字面量(调色板的唯一
#   来源是 `ui/ui_factory.gd`);字号必须是 16 的倍数(`kh_l4`/`kh_l5` 扫 `res://ui`)。

const FONT_SIZE := 32
# 顶中锚的**纵向**落点:在记分条(offset_top 16)与「对手掉线中」那一条(offset_top 72)之下。
# ★ 这个数**不是**随手取的:1v1 的记分条**实测高 52px**(占 y ∈ [16, 68])、其下那条
#   GraceWrap **实测占 y ∈ [72, 124]**(高 52 = 标签 36 + 复用那个 Plate 的上下各 8),
#   128 让三者互不重叠(横幅高**实测 76px** = 标签 36 + 上下各 20 的内边距 ⇒ 占 y ∈ [128, 204])。
#   ★★ 那三个数是 2026-09-28 Task 5 落下 `GraceWrap` 那一条时**真量**的(headless 下
#   `get_global_rect()` 拿到的就是布局算出的矩形,与相③ 量横幅用的是同一个办法)。
#   本条此前写「记分条高约 48px、GraceWrap 到 120px 结束」—— **两个数都偏小 4**:
#   按 font_size 32 手推会得到"标签高 = 字号 = 32",而**含 CJK 的那两行**实测标签高 36,
#   再加 Plate 的上下内边距 8+8 ⇒ 52。
#   ★★ 36 **不是**"本项目字体在 32 下的行高"这个**字体属性** —— 别再照那个说法把它套到纯拉丁
#   面板上(2026-09-29 订正)。`Label` 的一行高度 = `max(字体在该字号的 get_height, 整形后的
#   ascent + descent)`,**两半都随内容变**:引擎侧见 `scene/gui/label.cpp` 的 `get_line_height()`
#   与 `_shape()` 里那句 `if (asc + dsc < font_h)`(不足则上下补平,超出则原样保留)。
#   实测:纯拉丁那一行 **33**(`font.get_height(32)` 就是 33),只有含 CJK 的行才被撑到 **36**
#   (Unifont 的 CJK 字形框更高)。同一份 Plate 就能看见这 3px —— `ui/pvp_hud.tscn` 的 `PingWrap`
#   (只有 "24ms")实测高 **49** = 33 + 上下各 8,而含 CJK 的 `ScoreWrap` 是 **52**。
#   **结论不变**(124 < 128,三者仍互不重叠),但那两个数字要照实写 ——
#   与 Task 4 那次"注释断言了代码不产生的几何"是同一类缺陷。
# ★★ 纵向只有这一个数,**横向则是按内容现算的**(`_center_panel()`,不是常量):面板宽 =
#   文字宽 + 面板左右各 28px 的内边距 ⇒ 居中时占 x ∈ [960 - w/2, 960 + w/2]。
#   ⚠ **登记(2026-09-28 实测,不修)**:大乱斗右上角排行榜的底板左缘在 x = 1920 - 736 = **1184**
#   (`ui/royale_hud.tscn` 的 BoardBg,`anchor_right = 1.0` + `offset_left = -736`;板上的文字自
#   x = **1204** 起,那是 BoardBox 的 `offset_left = -716`),而最长那条状态文字
#   (「与服务器断线,正在重连…(剩余 60s)」)的面板宽**实测 568px** ⇒ 右端 **1244**。
#   ⇒ 横幅右侧**侵入排行榜左缘 60px**(x ∈ [1184, 1244]);纵向横幅占 y ∈ [128, 204],而板自
#   y = 96 起**向下长**(8 行时实测板底到 y ≈ 499 —— `ui/royale_hud.gd` 的
#   `_board_bg.size.y = vbox 高 + 34`)⇒ 那一竖条盖住的是标题行下缘、计时行整条、以及第一行
#   玩家左侧的「名次」那几格。
#   ★ **568 这个数是两处独立算得的,互相印证**:①`tests/reconnect_status_probe.gd` 相③ 的
#   居中断言把整块矩形打在自己的消息里(实测 `rect=[P: (676.0, 128.0), S: (568.0, 76.0)]`);
#   ②按本项目那条度量规则手算标签宽 ——「汉字 32px、半角 16px」(与 `ui/royale_hud.gd` 的
#   `NAME_UNITS` 同一条口径):12 个汉字 + 8 个半角 = 384 + 128 = **512**,再加左右各 28 的
#   内边距 = **568**。
#   ⚠ **别照这句话的上一版写**:它曾写「面板宽 ≈ 632 ⇒ 右端 1276 ⇒ 盖住 92px」,
#   那三个数**一个都复现不出来**(实测就是上面那 568 / 1244 / 60)。
#   1v1/3v3 那一带是空的(那两个模式没有排行榜),故只有大乱斗看得见;改法不是把 TOP_OFFSET
#   往下挪(挪到板底 y ≈ 499 之下就落到屏幕中部、与中央播报抢位置),而是要另想办法
#   (缩短文案 / 换单行小字 / 给大乱斗单独一个落点),**属另行评估**。
#   更早那版注释写的「居中出现时占 680~1240,仍不压到它」是**两个错**:① 当时根本没居中(见
#   `_center_panel()` 上方那段);② 就算居中,1240 也已经越过 1184 —— 那句话自己就不自洽。
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
	# ★★ 锚点**必须在这一行之后**设(已入树)—— 未入树时 `set_anchor` 拿到的 `parent_range`
	#    是 0,四个偏移量会全塌成 0(详见 `_center_panel()` 上方那段踩坑记录)。
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)

	_label = Label.new()
	_label.name = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(_label, FONT_SIZE)
	_label.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_panel.add_child(_label)
	# ★★ 锚点 / 偏移量**都**在这里设 —— 而且必须在 `root.add_child(_panel)` **之后**
	#    (即入树之后),理由见 `_center_panel()`。
	_center_panel()


# ★★ 顶中居中:四个偏移量**必须自己算**,而且必须**在树里**算。
#
# 踩过的坑(2026-09-28,修复前):`_ready` 里只 `set_anchors_preset(PRESET_CENTER_TOP)` +
# `offset_top = TOP_OFFSET`,而那次调用发生在 `root.add_child(_panel)` **之前**。`set_anchor`
# 是按 `offset = previous_pos - anchor * parent_range` 推偏移量的,而 `parent_range` 来自
# `get_parent_anchorable_rect()` —— 那个函数在**未入树**时直接返回 `Rect2()`(引擎源码
# `scene/gui/control.cpp` 的 `Control::get_parent_anchorable_rect` 首行 `if (!is_inside_tree())
# return Rect2();`)⇒ `parent_range = 0` ⇒ **四个偏移量全塌成 0**(锚点本身是对的 (0.5,0,0.5,0))。
# 之后标签一给面板最小尺寸,`Control::_size_changed` 就把尺寸钳到最小尺寸而**不动位置**
# (grow 方向默认 END)⇒ 1920 宽下实测面板占 x ∈ [960, 960+w],**左缘钉在视口中心**,
# 整块往右长出去 —— 一块**不透明**面板压在大乱斗排行榜(x ≥ 1184)上。
#
# ⇒ 唯一可靠的量是入树之后现算的 `get_combined_minimum_size()`(与 `ui/match_result.gd` 的
#   `show_result()` 末端那四行**同一个先例、同一条理由**,连踩的坑都一样;那边是"面板的左上角
#   钉在视口中心,内容往右下长出去",也是靠"装好内容再按最小尺寸算 ±half"修的)。
#   锚点 (0.5, 0) ⇒ `offset_left = -half.x` / `offset_right = +half.x` 即为水平居中;纵向按
#   `TOP_OFFSET` 起算、高度取最小尺寸。
# ★ 每次 `set_text` 都要重算:宽度随文字变(倒计时那条 `(剩余 60s)` → `(剩余 9s)` 就差一个字),
#   不重算的话居中会停在**上一句**文字的宽度上。
# ★ `update_minimum_size()` 那一行**不是**多余的:标签改文字时只在**自己的**缓存有效时才向上
#   逐层作废(`Control::update_minimum_size` 的 `while (… && invalidate->data.minimum_size_valid)`)
#   —— 标签缓存本来就失效时,面板那份陈旧缓存**不会**被作废 ⇒ 直接读会拿到上一句文字的宽度。
#   在面板上先调一次是无条件作废(面板缓存有效时才需要,失效时是 no-op),读到的就一定是现值。
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


# 空串 = 收起。★ 唯一调用方 = `PvpMatchClient._set_status`(见那里的**五个**转折点)。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
	# ★ 必须在**改完文字之后**重算居中:面板宽随文字变,否则居中会停在上一句的宽度上。
	_center_panel()
