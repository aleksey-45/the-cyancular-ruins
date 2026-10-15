class_name Broadcast
extends Control

# 中央广播(三个对局 HUD 共用):压暗遮罩 + 凿刻面板 + 大字/副文案;三个模式真正不同的只有"显示什么文案",那部分留在各自 HUD。
# ★ 它是对局 HUD 的一部分、不是独立 CanvasLayer:以子节点形式挂进 HUD(三个 HUD 都在 layer 130),不另起一层去和 status_banner(140)/结算页(150)抢位置。
# ★ 声明式契约:用 broadcast.tscn 的 instantiate() 建,不要 Broadcast.new()(那样得到的是没有子节点、也没铺满宿主的空 Control);
#   本组件是"裸骨架 tscn + 代码建子节点",故脚本里没有 @onready $路径 —— 零守卫(hud_declarative_probe 已删·2026-10-09)。
# ── 视觉:面板 = UiFactory.menu_panel();大字落在 UiFactory.header_strip() 标题带里(琥珀 C_GOLD);★ 颜色一律从 UiFactory 调色板取,唯一字面量例外是全屏压暗罩。
# ★★ 边界登记:菜单系 token(C_HEADER/C_INNER/C_GOLD/C_EDGE/C_TEXT_MUTE)在 UiFactory 里划定"只给菜单系用",广播层是刻意的例外(用户要求与菜单同一套器物感)
#   ⇒ 改这几个 token 会连带改到对局内广播的外观,今天没有守卫拦着(menu_style_probe 已删·2026-10-09);被 HUD 读的那批 token 一个都没动。

# 巨大数字 / 主文案。字号必须是 16 的倍数(本项目像素字体硬约定,见 ui/factory/ui_factory.gd 文件头)。
const BIG_FONT := 144
const SUB_FONT := 64

const MASK_COLOR := Color(0, 0, 0, 0.3)

const STRIP_MIN_W := 640.0

const PUNCH_SCALE := 0.06    # 峰值放大 6%(与 squash_stretch 的幅度同量级)
const PUNCH_DECAY := 4.0     # 每秒衰减 ⇒ 约 0.25s 回到平静

# 倒计时数字走完时发一次 —— 大乱斗的 PLAYING 态要据此收起广播(1v1/3v3 不接)。
signal countdown_finished

var mask: ColorRect = null
var big: Label = null
var sub: Label = null

var punch_enabled := true

var _center: CenterContainer = null
var _panel: PanelContainer = null
var _counting := false
var _countdown := 0.0
var _punch := 0.0


func _ready() -> void:
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

	_panel = UiFactory.menu_panel(Vector2(72, 44))
	_center.add_child(_panel)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 24)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(_panel.get_node("Body") as Container).add_child(box)

# 大字 = 一条标题带里的琥珀字(C_HEADER 底 + 只有下边一条线)。★ 复用 header_strip 而不是手搓 StyleBox:配色与形状由工厂单点定义(改它 = 同时改菜单,见文件头的边界登记)。
	var strip := UiFactory.header_strip("", BIG_FONT)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big = strip.get_child(0) as Label
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.custom_minimum_size = Vector2(STRIP_MIN_W, 0)
	box.add_child(strip)

	sub = UiFactory.label("", SUB_FONT, UiFactory.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)


# 显示 / 收起广播:show == false 时同时停掉倒计时 —— 三个 HUD 原先每一个"收起"调用点都顺手置了标志,这里把那条口径收进组件(少一处漏改的机会)。
func set_broadcast(show: bool, big_text: String, sub_text: String) -> void:
	_counting = false
	mask.visible = show
	_center.visible = show
	big.text = big_text
	sub.text = sub_text
	_punch = 1.0 if show else 0.0
	_apply_punch()


func start_countdown(seconds: float, sub_text: String) -> void:
	_countdown = seconds
	_counting = true
	mask.visible = true
	_center.visible = true
	sub.text = sub_text
	_set_big_text(str(maxi(ceili(_countdown), 1)))


func stop_countdown() -> void:
	_counting = false


func is_counting() -> bool:
	return _counting


# 倒计时本地走秒(服务器只在状态切换时广播一次 round_state,两次之间由本端自己走)。★ 与 1v1 的"对手掉线中"共用同一口径(GraceWindow.tick_display),
# 但那条住在 PvpHud 里 —— 掉线可能发生在倒计时中,两者各自走各自的。★ 脉冲衰减不受 _counting 早退影响(否则数字走完后画面会卡在放大态)。
func tick(delta: float) -> void:
	if _punch > 0.0:
		_punch = maxf(0.0, _punch - delta * PUNCH_DECAY)
		_apply_punch()
	if not _counting:
		return
	_countdown -= delta
	if _countdown > 0.0:
		_set_big_text(str(maxi(ceili(_countdown), 1)))
	else:
		_counting = false
		countdown_finished.emit()


# 改大字文本,变了才重建字符串并发一次脉冲(倒计时期间每帧都会调到 —— 这层判重同时避免了每帧的字符串分配与每帧的脉冲触发)。
func _set_big_text(t: String) -> void:
	if big.text == t:
		return
	big.text = t
	_punch = 1.0
	_apply_punch()


# 缩放脉冲:围绕面板中心放大(不是绕左上角)。★ 布局未定时(size == 0)直接跳过 —— 那时 pivot 还是原点,缩放会把面板从左上角甩出去。
func _apply_punch() -> void:
	if not punch_enabled or _panel == null:
		return
	if _panel.size.x <= 0.0:
		return
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)
