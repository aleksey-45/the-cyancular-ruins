class_name Broadcast
extends Control

# 中央广播(三个对局 HUD 共用):全屏压暗遮罩 + 屏幕正中的大字 / 副文案。
#
# ★ **从哪来**:`ui/hud/{pvp,royale,team}_hud` 里各抄了一份、逐字相同的那三样 ——
#   `_set_broadcast(show, big, sub)` / `show_notice(...)` / `_process` 里那段倒计时走秒。
#   三个模式**真正不同的只有"要显示什么文案、在哪个状态显示"**,那部分**留在各自的 HUD 里**;
#   本组件只负责「怎么显示」与「数字怎么走」,不认识任何模式规则。
#
# ★ **它是对局 HUD 的一部分**,不是独立 CanvasLayer:以子节点形式挂进 HUD(三个 HUD 都在
#   layer 130),层位随宿主 —— **不另起一层**去和 status_banner(140)/结算页(150)抢位置。
#
# ★ **声明式契约**:按 `preload("res://ui/hud/broadcast.tscn").instantiate()` 建
#   (三个 HUD 的 .tscn 里以 `instance=` 引用)。**不要 `Broadcast.new()`** —— 那会得到一具
#   没有子节点的空 Control。本组件是"**裸骨架 tscn + 代码建子节点**"(与
#   `ui/hud/status_banner.gd` 同一种取舍:手写锚点是"改错了不报错"的那一类),故脚本里
#   **没有** `@onready $路径` —— `tests/probe/hud_declarative_probe.gd` 的文件头把这种形状
#   判为**正确**。
#
# ★ 颜色一律从 `UiFactory` 调色板取;唯一的字面量例外是**全屏压暗罩**(它是"压暗游戏画面"
#   这个职责本身,不属于调色板语义)。

# 巨大数字 / 主文案。字号必须是 16 的倍数(本项目像素字体硬约定,见 ui/factory/ui_factory.gd 文件头)。
const BIG_FONT := 144
# 副文案(第 N 局 / 对战开始 / 局胜 x - y …)。
const SUB_FONT := 64

# 全屏压暗罩:保留对局画面可辨(0.3 = 压暗但不挡死)。
const MASK_COLOR := Color(0, 0, 0, 0.3)

# 倒计时数字走完时发一次 —— 大乱斗的 PLAYING 态要据此收起广播(1v1/3v3 不接)。
signal countdown_finished

# 探针与兼容读点直接读这三个(见各 HUD 里 `_big` / `_mask` 那几行转发)。
var mask: ColorRect = null
var big: Label = null
var sub: Label = null

var _center: CenterContainer = null
var _counting := false
var _countdown := 0.0


func _ready() -> void:
	# 汉字回退链 + 关抗锯齿/微调/子像素(共享 FontFile 实例,同三个 HUD 的口径)。
	PixelFont.shared()

	mask = ColorRect.new()
	mask.name = "Mask"
	mask.color = MASK_COLOR
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# IGNORE:广播只给人看,绝不能吃掉点击(菜单/按钮得照常可点)。
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.visible = false
	add_child(mask)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.visible = false
	add_child(_center)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.add_child(vb)

	big = UiFactory.label("", BIG_FONT, UiFactory.C_TEXT)
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(big)

	sub = UiFactory.label("", SUB_FONT, UiFactory.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)


# 显示 / 收起广播。`show == false` 时同时停掉倒计时 —— 三个 HUD 原先每一个 "收起" 调用点
# 都顺手把 `_in_countdown` 置了 false,这里把那条口径收进组件(少一处漏改的机会)。
func set_broadcast(show: bool, big_text: String, sub_text: String) -> void:
	_counting = false
	mask.visible = show
	_center.visible = show
	big.text = big_text
	sub.text = sub_text


# 开始一段倒计时:主文案 = 巨大数字(由 `tick` 续写),副文案 = 调用方给的那一行。
func start_countdown(seconds: float, sub_text: String) -> void:
	_countdown = seconds
	_counting = true
	mask.visible = true
	_center.visible = true
	sub.text = sub_text
	big.text = str(maxi(ceili(_countdown), 1))


func stop_countdown() -> void:
	_counting = false


func is_counting() -> bool:
	return _counting


# 倒计时本地走秒(服务器只在状态切换时广播一次 round_state,两次之间由本端自己走)。
# ★ 与 1v1 的「对手掉线中」那一条**共用同一口径**(`GraceWindow.tick_display`),但那一条
#   住在 PvpHud 里 —— 掉线可能发生在倒计时中,两者各自走各自的。
func tick(delta: float) -> void:
	if not _counting:
		return
	_countdown -= delta
	if _countdown > 0.0:
		big.text = str(maxi(ceili(_countdown), 1))
	else:
		_counting = false
		countdown_finished.emit()
