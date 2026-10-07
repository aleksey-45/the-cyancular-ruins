class_name Broadcast
extends Control

# 中央广播(三个对局 HUD 共用):全屏压暗遮罩 + 屏幕正中的凿刻面板 + 大字 / 副文案。
#
# - **从哪来**:`ui/hud/{pvp,royale,team}_hud` 里各抄了一份、逐字相同的那三样 ——
#   `_set_broadcast(show, big, sub)` / `show_notice(...)` / `_process` 里那段倒计时倒计时更新。
#   三个模式**真正不同的只有"要显示什么文案、在哪个状态显示"**,那部分**留在各自的 HUD 里**;
#   本组件只负责「怎么显示」与「数字怎么走」,不认识任何模式规则。
#
# - **它是对局 HUD 的一部分**,不是独立 CanvasLayer:以子节点形式挂进 HUD(三个 HUD 都在
#   layer 130),层位随宿主 —— **不另起一层**去和 status_banner(140)/结算页(150)抢位置。
#
# - **声明式契约**:按 `preload("res://ui/hud/broadcast.tscn").instantiate()` 建
#   (三个 HUD 的 .tscn 里以 `instance=` 引用)。**不要 `Broadcast.new()`** —— 那会得到一具
#   没有子节点、也没铺满宿主的空 Control。本组件是"**裸基础结构框架 tscn + 代码建子节点**"(与
#   `ui/hud/status_banner.gd` 同一种取舍:手写锚点是"改错了不报错"的那一类),故脚本里
#   **没有** `@onready $路径` —— `tests/probe/hud_declarative_probe.gd` 的文件头把这种形状
#   判为**正确**。
#
# ── 视觉(方向 B 的凿刻语汇)─────────────────────────────────────────────
# 面板 = `UiFactory.menu_panel()`(外深线 + 内亮线两条 1px 线);大字落在一条
# `UiFactory.header_strip()` 标题带里(C_HEADER 底 + 只有下边一条线 + **琥珀 C_GOLD** 字);
# 副文案在带下单独一行、C_TEXT_DIM、小一号。
# - 颜色一律从 `UiFactory` 调色板取;唯一的字面量例外是**全屏压暗罩**(它是"压暗游戏画面"
#   这个职责本身,不属于调色板语义)。
# 注意： **边界登记**:"菜单系 token"(`C_HEADER` / `C_INNER` / `C_GOLD` / `C_EDGE` /
#   `C_TEXT_MUTE`)在 `ui/factory/ui_factory.gd` 的注释里被划定为"**只给菜单系用**,
#   对局内 HUD 一律不用"。广播层是**刻意的例外**(用户 2026-10-03 要求把它做得和菜单同一套
#   器物感)。代价如实记:从此**改这几个菜单 token 会连带改到对局内广播的外观** ——
#   它们今天被 `tests/probe/menu_style_probe.gd` 按值钉着,所以改它们会**响亮地红**,不是静默。
#   `C_ACCENT` / `C_TEXT` / `C_TEXT_DIM` / `C_DANGER` / `C_PLATE` 那些"被 HUD 读"的 token
#   一个都没动,值行为保持一致。

# 巨大数字 / 主文案。字号必须是 16 的倍数(本项目像素字体硬约定,见 ui/factory/ui_factory.gd 文件头)。
const BIG_FONT := 144
# 副文案(第 N 局 / 对战开始 / 局胜 x - y …)。
const SUB_FONT := 64

# 全屏压暗罩:保留对局画面可辨(0.3 = 压暗但不挡死)。
const MASK_COLOR := Color(0, 0, 0, 0.3)

# 标题带的最小宽度:单个数字("3")也让面板是一块**稳定的牌匾**,而不是随字宽缩成一粒。
# (它只是**下限** —— 长文案如「P1 获胜!」会把带子自然撑宽。)
const STRIP_MIN_W := 640.0

# ── 数字的"存在感":每跳一个数字放一次缩放脉冲 ──
# - 纯表现、可整体关掉(`punch_enabled = false`);计费是每帧一次 `Vector2` 标量乘 —— 无堆分配
#   (字符串只在**数字真的变了**那一帧才重建,见 `_set_big_text`)。
const PUNCH_SCALE := 0.06    # 峰值放大 6%(与 squash_stretch 的幅度同量级)
const PUNCH_DECAY := 4.0     # 每秒衰减  ->  约 0.25s 回到平静

# 倒计时数字走完时发一次 —— 大乱斗的 PLAYING 态要据此收起广播(1v1/3v3 不接)。
signal countdown_finished

# 探针与兼容读点直接读这三个(见各 HUD 里 `_big` / `_mask` 那几行转发)。
var mask: ColorRect = null
var big: Label = null
var sub: Label = null

# 缩放脉冲总开关(关掉 = 纯静态大字,行为与抽组件之前一致)。
var punch_enabled := true

var _center: CenterContainer = null
var _panel: PanelContainer = null
var _counting := false
var _countdown := 0.0
var _punch := 0.0


func _ready() -> void:
	# 汉字回退链 + 关抗锯齿/微调/子像素(共享 FontFile 实例,同三个 HUD 的口径)。
	PixelFont.shared()

	mask = ColorRect.new()
	mask.name = "Mask"
	mask.color = MASK_COLOR
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# IGNORE:广播只给人看,绝不能拦截屏蔽点击事件(菜单/按钮得照常可点)。
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.visible = false
	add_child(mask)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.visible = false
	add_child(_center)

	# 凿刻面板(外深线 + 内亮线)。-  内容加到它那个名为 `Body` 的 PanelContainer 里。
	_panel = UiFactory.menu_panel(Vector2(72, 44))
	_center.add_child(_panel)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 24)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(_panel.get_node("Body") as Container).add_child(box)

	# 大字 = 一条标题带里的琥珀字(C_HEADER 底 + 只有下边一条线)。
	# - 复用 `header_strip` 而不是手搓一个 StyleBox:配色与"只有下边一条线"那条形状
	#   由工厂单点定义(改它=同时改菜单,这是接受的,见文件头上方那条边界登记)。
	var strip := UiFactory.header_strip("", BIG_FONT)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big = strip.get_child(0) as Label
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.custom_minimum_size = Vector2(STRIP_MIN_W, 0)
	box.add_child(strip)

	sub = UiFactory.label("", SUB_FONT, UiFactory.C_TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)


# 显示 / 收起广播。`show == false` 时同时停掉倒计时 —— 三个 HUD 原先每一个 "收起" 调用点
# 都随意将 `_in_countdown` 置了 false,这里把那条口径收进组件(少一处漏改的机会)。
func set_broadcast(show: bool, big_text: String, sub_text: String) -> void:
	_counting = false
	mask.visible = show
	_center.visible = show
	big.text = big_text
	sub.text = sub_text
	# 结果出现时也弹一下(与数字同一种存在感)。收起来的时候把脉冲归零、缩放复位。
	_punch = 1.0 if show else 0.0
	_apply_punch()


# 开始一段倒计时:主文案 = 巨大数字(由 `tick` 续写),副文案 = 调用方给的那一行。
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


# 倒计时本地倒计时更新(服务器只在状态切换时广播一次 round_state,两次之间由本端自己走)。
# - 与 1v1 的「对手掉线中」那一条**共用同一口径**(`GraceWindow.tick_display`),但那一条
#   住在 PvpHud 里 —— 掉线可能发生在倒计时中,两者各自走各自的。
# - 脉冲的衰减**不受 `_counting` 提前返回影响**(否则数字走完后画面会卡在放大态)。
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


# 改大字文本,**变了才**重建字符串并发一次脉冲(倒计时期间每帧都会调到,故这层判重不是
# 多余的:它同时避免了每帧的字符串分配与每帧的脉冲触发)。
func _set_big_text(t: String) -> void:
	if big.text == t:
		return
	big.text = t
	_punch = 1.0
	_apply_punch()


# 缩放脉冲:围绕**面板中心**放大(不是绕左上角)。
# - 布局未定时(`size == 0`)直接跳过 —— 那时 pivot 还是原点,缩放会把面板从左上角甩出去。
#   下一帧 `tick` 会再补一次(脉冲还没衰减完),画面不会缺这一下。
func _apply_punch() -> void:
	if not punch_enabled or _panel == null:
		return
	if _panel.size.x <= 0.0:
		return
	_panel.pivot_offset = _panel.size * 0.5
	_panel.scale = Vector2.ONE * (1.0 + PUNCH_SCALE * _punch)
