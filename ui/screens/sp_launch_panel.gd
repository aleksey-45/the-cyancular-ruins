class_name SpLaunchPanel
extends PanelContainer

# 单人开局面板(设计系统 v2):结构从 main 的 sp_launch_panel 填充逻辑迁移,内容由本文件建 ——
# 皮 = UiDesign.skin_menu_panel(凿刻边 + 内亮线,Theme 2.0),控件 = UiDesign 的 header_strip /
# menu_button / label。★ 对外契约不变:initial_map / disabled / play_requested / show_error,以及
# 「返回 = 隐藏面板、开始探索 = 发信号」的旧行为。
#
# ── 结构(全部容器驱动,零绝对坐标 / 零手写 StyleBox / 零 Color 字面量)──────────────
#   skin_menu_panel(self, PANEL_PAD) = PanelCarved 外框 + 内衬 Body
#     └─ Page VBox(最小宽 560,块间距 SP_6)
#         ├─ HeaderStrip「—— 单人开局 ——」(T_H1,居中)
#         ├─ MapPicker(地图标题条/缩略图/滚动由 picker 自己带)
#         ├─ WeaponsSection VBox(SP_4):HeaderStrip「禁用武器…」(T_H2)+ WeaponPicker(1 列滚动)
#         ├─ Actions HBox(SP_6,居中):开始探索(Gold)/ 返回(Quiet),同为 420×88
#         └─ Status(T_H2,C_TEXT_DIM,初始隐藏;show_error 显示,自动折行)
#
# ★ MapPicker / WeaponPicker 的皮肤与内部实现归 UI-5a/5b;此处只把实例放进 v2 面板、沿用它们
#   的公开 API(setup / selected / disabled_weapons),不改它们的逻辑或皮肤。

signal play_requested(path: String, disabled_weapons: Array[int])

# 布局 token 组合(内容驱动的下限/间距,不是绝对坐标;数值与迁移前一致)。
const PANEL_PAD := Vector2(UiDesign.SP_9, UiDesign.SP_6)      # 64 × 32:内衬
const PAGE_MIN_W := UiDesign.SP_10 * 7                        # 560:内容最小宽(面板宽 = 560 + 两侧内衬)
const BLOCK_GAP := UiDesign.SP_6                              # 32:大块间距
const SECTION_GAP := UiDesign.SP_4                            # 16:分区标题条与其内容之间
const BUTTON_SIZE := Vector2(UiDesign.SP_10 * 5 + UiDesign.SP_5 - UiDesign.SP_1,
		UiDesign.SP_10 + UiDesign.SP_2)                      # 420 × 88(与 PvpHud 结算返回键同档)
const MAP_H := UiDesign.SP_10 * 3 + UiDesign.SP_9 - UiDesign.SP_1  # 300:地图网格滚动高度
const WEAPONS_H := UiDesign.SP_10 * 4                         # 320:武器开关滚动高度

# 地图标题条文案:与 MapPicker.setup 的默认值一致,这里显式传入以钉住面板标题来源。
const MAP_TITLE := "地图(点选;缩略图 = 开局地形简略图)"

var initial_map := ""
var disabled: Array[int] = []
var _map := MapPicker.new()
var _weapons: WeaponPicker
var _status: Label


func _ready() -> void:
	UiDesign.skin_menu_panel(self, PANEL_PAD)
	var body := get_node("Body") as Container
	var page := VBoxContainer.new()
	page.name = "Page"
	page.custom_minimum_size.x = PAGE_MIN_W
	page.add_theme_constant_override("separation", BLOCK_GAP)
	body.add_child(page)

	page.add_child(UiDesign.header_strip("—— 单人开局 ——", UiDesign.T_H1, true))

	_map.name = "MapPicker"
	page.add_child(_map)
	_map.setup(initial_map, 2, MAP_H, MAP_TITLE)

	var weapons_section := VBoxContainer.new()
	weapons_section.name = "WeaponsSection"
	weapons_section.add_theme_constant_override("separation", SECTION_GAP)
	page.add_child(weapons_section)
	weapons_section.add_child(UiDesign.header_strip("禁用武器(勾选 = 本局不可用)",
			UiDesign.T_H2))

	_weapons = WeaponPicker.new(disabled, 1, WEAPONS_H)
	_weapons.name = "WeaponPicker"
	weapons_section.add_child(_weapons)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", BLOCK_GAP)
	page.add_child(actions)
	var go := UiDesign.menu_button("开始探索", UiDesign.T_H2, BUTTON_SIZE, "gold")
	go.name = "StartBtn"
	go.pressed.connect(_on_play)
	actions.add_child(go)
	var back := UiDesign.menu_button("返回", UiDesign.T_H2, BUTTON_SIZE, "quiet")
	back.name = "BackBtn"
	back.pressed.connect(_on_back)
	actions.add_child(back)

	_status = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_status.name = "Status"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 错误文案可能带地图文件名:自动折行,避免把面板横向撑宽(短文案版面不变)。
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.hide()
	page.add_child(_status)


func show_error(message: String) -> void:
	_status.text = message
	_status.show()


# 开始探索:原样把当前选图与禁用武器交给调用方(main_menu 负责校验/存档/进图)。
func _on_play() -> void:
	Sfx.play("ui")
	play_requested.emit(_map.selected, _weapons.disabled_weapons())


# 返回 = 只隐藏面板(与旧 siri 行为一致,由 main_menu 的「单人模式」按钮再次显示)。
func _on_back() -> void:
	Sfx.play("ui")
	hide()
