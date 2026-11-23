class_name Broadcast
extends Control

# 中央广播(对局开始 / 倒计时 / 本局结果 / 等待提示)。UI-3b 迁移到设计系统 v2。
#
# ── 与 main 参考版的关系 ────────────────────────────────────────────────────
# 结构照 main 的 ui/hud/broadcast:全屏压暗层 Mask → 居中 CenterContainer →
# PanelCarved 面板(Body 内衬) → HeaderStrip 巨字 + 副文案;
# 视觉全部来自 Theme 2.0 / UiDesign token,本文件零 StyleBox、零 Color 字面量、
# 零绝对坐标(唯一的手写布局是"铺满宿主"的锚点,属 HUD 例外)。
#
# ── siri 契约(与迁移前逐项一致)──────────────────────────────────────────────
#   · set_broadcast(visible_on, title, subtitle) / start_countdown(seconds, subtitle);
#   · 走秒逻辑收进 v2 CountdownClock(纯逻辑,重复 start 只采纳更短剩余、数字单调不增),
#     但仍由本组件的 _process 驱动,不新增 countdown_finished 等外部信号;
#   · 巨字缩放入场(punch)的幅度/衰减与迁移前相同。

# 巨字/副文案字号:像素字体硬约束 = 16 的倍数;用 T_* token 组合出原来的 144 / 64,
# 不把 144 / 64 写成裸数字(契约见 docs/construction/2026-11-23-ui-full-replacement-plan.md §5.4)。
const BIG_SIZE := UiDesign.T_H1 * 3   # 144
const SUB_SIZE := UiDesign.T_H2 * 2   # 64

# 压暗层不透明度:版式参数(颜色取 UiDesign.C_BG),沿用 main 的 0.3。
const MASK_ALPHA := 0.3

# 巨字最小宽度:让数字与文案的 HeaderStrip 底板宽度稳定,不随字数跳动。
const STRIP_MIN_W := 640.0

const PUNCH_SCALE := 0.06
const PUNCH_DECAY := 4.0

var mask: ColorRect
var big: Label
var sub: Label

var _center: CenterContainer
var _panel: PanelContainer
var _clock := CountdownClock.new()
var _punch := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 铺满宿主:本组件不是独立 CanvasLayer,层位随宿主 HUD(main 同款约定)。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Mask:广播出现时压暗战局,保证巨字可读;颜色只有 C_BG 一个来源。
	mask = ColorRect.new()
	mask.name = "Mask"
	mask.color = UiDesign.C_BG
	mask.modulate.a = MASK_ALPHA
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.visible = false
	add_child(mask)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.visible = false
	add_child(_center)

	# 面板 = Theme 2.0 的 PanelCarved(外框)+ PanelCarvedBody(内衬),padding 72/44 与 main 的
	# UiFactory.menu_panel(Vector2(72, 44)) 同档(Theme 里有现成的 PanelCarvedBodyInset72 变体)。
	_panel = UiDesign.menu_panel(Vector2(72, 44))
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.add_child(_panel)

	var body := VBoxContainer.new()
	body.name = "Box"
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", UiDesign.SP_5)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(_panel.get_node("Body") as Container).add_child(body)

	# 巨字:HeaderStrip variation + HeaderTitle 配色(金色);字号走 token 组合。
	var strip := UiDesign.header_strip("", BIG_SIZE, true)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big = strip.get_child(0) as Label
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.custom_minimum_size.x = STRIP_MIN_W
	body.add_child(strip)

	sub = UiDesign.label("", SUB_SIZE, UiDesign.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(sub)
	hide()


func set_broadcast(visible_on: bool, title: String, subtitle: String) -> void:
	# ★ 参数不能叫 show:CanvasItem 有同名方法(触发 SHADOWED_VARIABLE_BASE_CLASS)。
	_clock.stop()
	visible = visible_on
	mask.visible = visible_on
	_center.visible = visible_on
	big.text = title
	sub.text = subtitle
	_punch = 1.0 if visible_on else 0.0
	_apply_punch()


func start_countdown(seconds: float, subtitle: String) -> void:
	# 重复进入倒计时(服务器 0.5s 重播当前剩余)只采纳更短剩余,数字绝不回拨。
	_clock.start(seconds)
	show()
	mask.visible = true
	_center.visible = true
	sub.text = subtitle
	_count(int(_clock.text()))


func _process(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * PUNCH_DECAY)
		_apply_punch()
	# 显示 ceil(剩余) 且至少 1:3→2→1 一个不落;停表后保留最后一格数字(与迁移前一致)。
	if _clock.tick(delta) == CountdownClock.TICK_RUNNING:
		_count(int(_clock.text()))


func _count(number: int) -> void:
	var text := str(number)
	if big.text != text:
		big.text = text
		_punch = 1.0
		_apply_punch()


func _apply_punch() -> void:
	if _panel.size.x > 0.0:
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)
