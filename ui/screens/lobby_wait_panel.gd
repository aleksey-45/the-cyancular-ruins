class_name LobbyWaitPanel
extends PanelContainer

# 大厅等待室(UI 设计系统 v2):容器化布局,零绝对坐标、零手写 StyleBox/Color 字面量。
#
# ── 结构 ─────────────────────────────────────────────────────────────────────
#   UiDesign.skin_menu_panel(self, SP_9×SP_6) = 凿刻外框 + 内衬 Body
#     └─ VBox(SP_5, 最小宽 800 token):房间标题按钮(Gold,点击复制房号)
#         → 名单 VBox(每行 = 投影给的一行文字 + 状态色)
#         → 人数/规则行(居中)
#         → 换队按钮行(A/B,Primary)
#         → 自己角色颜色行(滑块 + 色相预览块)
#         → 开始游戏(Gold) / 退出房间(Quiet)
#
# ── 契约(与迁移前逐项等价;lobby_view / mp_lobby 只依赖这些)────────────────────
#   · LobbyWaitPanel.new(initial_hue: float)。
#   · present(room):room = LobbyProjection.waiting(...) 的字典,字段 title / count / roster /
#     team / my_team / can_start 原样使用(roster 行 = [文字, 颜色];重连/掉线等状态由投影给色,
#     本面板逐行照渲,不新增判断)。
#   · signal copy_requested / team_requested(side) / start_requested / exit_requested /
#     hue_changed(value);标题按钮 = 复制房间号,tooltip 保留。
#   · 换队按钮只在团队房且不是自己队时显示;颜色滑块只在非团队房显示;开始按钮按 can_start 显示。
#   · 不自带固定 rect:尺寸由内容驱动,调用方放进居中容器即可。
# ★ 重连状态本身仍由 lobby_view 的状态条显示(本面板没有状态行,与迁移前一致)。

signal copy_requested
signal team_requested(side: int)
signal start_requested
signal exit_requested
signal hue_changed(value: float)

# 布局 token 组合(内容驱动的下限/间距,不是绝对坐标)。
const PANEL_PAD := Vector2(UiDesign.SP_9, UiDesign.SP_6)
const PANEL_MIN_W := UiDesign.SP_10 * 10                # 800:等待室最小宽
const TITLE_MIN_H := UiDesign.SP_9                      # 64
const ROSTER_GAP := UiDesign.SP_3
const TEAM_MIN := Vector2(UiDesign.SP_10 * 3, UiDesign.SP_9 - UiDesign.SP_2)
const START_MIN := Vector2(UiDesign.SP_10 * 5 + UiDesign.SP_7, UiDesign.SP_9)
const EXIT_MIN := Vector2(START_MIN.x, UiDesign.SP_9 - UiDesign.SP_2)
const HUE_SLIDER_MIN_W := UiDesign.SP_10 * 4            # 320
const HUE_CHIP := Vector2(UiDesign.SP_8, UiDesign.SP_5 + UiDesign.SP_1)
# 色相预览的饱和度/亮度是**数据计算**的固定参数(与迁移前同一组值),不是调色板字面量;
# 预览色只随玩家色相变化,所以不能取调色板 token。
const HUE_PREVIEW_SAT := 0.75
const HUE_PREVIEW_VAL := 1.0

var _initial_hue: float
var _title: Button
var _roster: VBoxContainer
var _count: Label
var _hue: HBoxContainer
var _start: Button
var _teams: Array[Button] = []


func _init(initial_hue: float) -> void:
	_initial_hue = initial_hue


func _ready() -> void:
	UiDesign.skin_menu_panel(self, PANEL_PAD)
	var body := get_node("Body") as Container
	var page := VBoxContainer.new()
	page.name = "Page"
	page.custom_minimum_size.x = PANEL_MIN_W
	page.add_theme_constant_override("separation", UiDesign.SP_5)
	body.add_child(page)

	_build_title(page)
	_build_roster(page)
	_build_team_buttons(page)
	_build_hue_row(page)
	_build_actions(page)


func _build_title(parent: Control) -> void:
	_title = UiDesign.menu_button("", UiDesign.T_H2, Vector2(0, TITLE_MIN_H), "gold")
	_title.name = "RoomCode"
	_title.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_title.tooltip_text = "点击复制房间号"
	_title.pressed.connect(copy_requested.emit)
	parent.add_child(_title)


func _build_roster(parent: Control) -> void:
	_roster = VBoxContainer.new()
	_roster.name = "Roster"
	_roster.add_theme_constant_override("separation", ROSTER_GAP)
	parent.add_child(_roster)
	_count = UiDesign.ui_label("", "body")
	_count.name = "Count"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(_count)


func _build_team_buttons(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.name = "TeamButtons"
	row.add_theme_constant_override("separation", UiDesign.SP_5)
	parent.add_child(row)
	for side in [1, 2]:
		var text := "加入 A 队" if side == 1 else "加入 B 队"
		var button := UiDesign.menu_button(text, UiDesign.T_H2, TEAM_MIN, "primary")
		button.name = "TeamButton%d" % side
		button.pressed.connect(team_requested.emit.bind(side))
		row.add_child(button)
		_teams.append(button)


func _build_hue_row(parent: Control) -> void:
	_hue = HBoxContainer.new()
	_hue.name = "HueRow"
	_hue.add_theme_constant_override("separation", ROSTER_GAP)
	parent.add_child(_hue)
	var label := UiDesign.ui_label("自己角色颜色:", "body")
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hue.add_child(label)
	var slider := HSlider.new()
	slider.name = "HueSlider"
	slider.max_value = 360.0
	slider.step = 5.0
	slider.set_value_no_signal(_initial_hue)
	slider.custom_minimum_size = Vector2(HUE_SLIDER_MIN_W, 0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hue.add_child(slider)
	var chip := ColorRect.new()
	chip.name = "HueChip"
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	chip.custom_minimum_size = HUE_CHIP
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.color = _preview_color(slider.value)
	_hue.add_child(chip)
	slider.value_changed.connect(hue_changed.emit)
	slider.value_changed.connect(func(v: float) -> void: chip.color = _preview_color(v))


func _build_actions(parent: Control) -> void:
	_start = UiDesign.menu_button("开始游戏", UiDesign.T_H2, START_MIN, "gold")
	_start.name = "StartBtn"
	_start.pressed.connect(start_requested.emit)
	parent.add_child(_start)
	var exit := UiDesign.menu_button("退出房间", UiDesign.T_H2, EXIT_MIN, "quiet")
	exit.name = "ExitBtn"
	exit.pressed.connect(exit_requested.emit)
	parent.add_child(exit)


func present(room: Dictionary) -> void:
	_title.text = room["title"]
	_count.text = room["count"]
	for child in _roster.get_children():
		_roster.remove_child(child)
		child.queue_free()
	for row: Array in room["roster"]:
		# 逐行照渲投影给的文字与状态色(我/房主/队伍标题/重连标记都由投影决定)。
		_roster.add_child(UiDesign.label(str(row[0]), UiDesign.T_H2, row[1]))
	_hue.visible = not room["team"]
	for i in _teams.size():
		_teams[i].visible = room["team"] and room["my_team"] != i + 1
	_start.visible = room["can_start"]


# 色相 → 预览色(只做颜色计算,不写 Color(...) 字面量)。
static func _preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, HUE_PREVIEW_SAT, HUE_PREVIEW_VAL)
