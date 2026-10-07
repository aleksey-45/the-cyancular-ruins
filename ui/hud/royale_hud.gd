class_name RoyaleHud
extends CanvasLayer

# 大乱斗 HUD(CanvasLayer layer=130):
#  - 右上角击杀排行榜(实时):名次/昵称/击杀数/存活状态,自己高亮;下方显示剩余时间
#  - 广播层:全屏遮罩 + 居中巨字(开局倒计时/终局胜败)—— **三个对局 HUD 共用**
#    `ui/hud/broadcast.tscn`(见 broadcast.gd),本类只喂文案与时机
#  - 延迟(右下角)
# 数据全部来自 round_state 载荷:{state, scores(总击杀), timer, names, alive, left, match_winner}
#
# 字体来源:统一走 UiFactory.style_control(内部转调 core/pixel_font.gd 的 PixelFont.shared()),
# 不再自建 load(ttf) + theme override 抄本。字号必须是 16 的倍数(本项目像素字体硬约定,
# 见 ui/ui_factory.gd 文件头)—— 本文件全部字号已按 16 归一。

const LAYER := 130
# 颜色一律取 UiFactory 的调色板(单一来源,见 ui/ui_factory.gd 的 token 段)。
const COLOR_BOARD := UiFactory.C_TEXT
const COLOR_ME := UiFactory.C_ACCENT
const COLOR_DEAD := UiFactory.C_TEXT_DIM
const COLOR_LEFT := UiFactory.C_DANGER
# 「掉线中」= 还在宽限期内、**可能回来**(阶段 3,spec §4 的 3.1)。
# - 与上三档是并列的第四种语义,故用调色板里新加的那一档(理由与实测对比度见
#   `UiFactory.C_GRACE` 那段)。别为了省一个常量把它并进任何一档。
const COLOR_GRACE := UiFactory.C_GRACE
# (原先还有 BIG_COLOR / SUB_COLOR —— 中央广播的大字/副文案颜色。两者随广播层一起搬进了
#  共享组件 `ui/hud/broadcast.gd`,这里不再有引用,故连同常量一并删除,不留死声明。)

# 排行榜面板宽(原 480):一行要塞「名次 + 昵称 + 击杀 + 阵亡 + 状态」五段,
# 480 时只要昵称稍长,末段的「存活/复活中/离开」就被顶出面板(2026-09-13 实测:
# 9 字昵称那行约 690px vs 面板 480)。
const BOARD_W := 720.0
# 昵称列的显示宽度上限(半角单位;汉字算 2)。超出按 … 截断 —— 状态段必须留在面板内。
const NAME_UNITS := 14

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

# 节点句柄一律从 royale_hud.tscn 取(声明式契约:见 tests/probe/hud_declarative_probe.tscn)。
# - 排行榜的**行**不在这里 —— 行数随人数变,由 _refresh_board 建/复用,见那里的说明。
# - 宿主必须用 preload("res://ui/hud/royale_hud.tscn").instantiate() 建,不能 RoyaleHud.new()
#   —— .new() 建出来的 CanvasLayer 没有子节点,下面这些 @onready 全是 null,_ready 解引用必崩。
@onready var _board_bg: ColorRect = $BoardBg
@onready var _board_vbox: VBoxContainer = $BoardBox
@onready var _timer_label: Label = $BoardBox/TimerLabel
@onready var _broadcast: Broadcast = $Broadcast
@onready var _ping_wrap: PanelContainer = $PingWrap
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _hint_wrap: PanelContainer = $HintWrap

# 探针兼容访问口:广播节点已搬进 Broadcast 组件,本转发保住既有读点
# (`combat_hud_visual_probe` 读 `royale._big`)。
var _big: Label:
	get:
		return _broadcast.big if _broadcast != null else null

# 排行榜行 Label(不含标题/计时):**复用**而不是每次重建 —— 见 _on_round_state 里的说明
var _rows: Array[Label] = []
var _last_row_count := -1
var _state := ST_COUNTDOWN
# role(int) -> 剩余秒(**只由服务器下发**)。-  大乱斗的 `RoyaleHost` 本来就 **1Hz 广播**
# `round_state`(HUD_SYNC_INTERVAL),而 `server_main` 也是每秒刷一次读数  ->  这里的值恒新,
# **不需要** 1v1 那样的本地倒计时更新(`GraceWindow.tick_display`)。两侧必要性的差异是**实测**的:
# 1v1/3v3 只在状态转折时广播,故它们那边必须本地走 —— 别为了"统一"给大乱斗也加一遍。
var _grace: Dictionary = {}
var _my_name := "Anon"

func _ready() -> void:
	layer = LAYER
	# - 一次:共享字体关抗锯齿/微调/子像素并挂 CJK 回退链。场景里那些 Label 引用的就是
	#   同一个共享 FontFile 实例 —— 不调这句,它们会带抗锯齿、且**汉字没有回退字形**
	#   (本 HUD 的字几乎全是中文:排行榜标题/存活/复活中/离开)。同 pvp_hud.gd:26。
	PixelFont.shared()
	_my_name = PvpSession.player_name
	# 两块底板样式**仍由代码给**:颜色 token(C_*)的唯一来源是 UiFactory,
	# 抄进 .tscn 就是第二处真值(见 ui_factory.gd 文件头第 1 条纪律)。
	_ping_wrap.add_theme_stylebox_override("panel", _plate_box(14.0, 6.0))
	_hint_wrap.add_theme_stylebox_override("panel", _plate_box(10.0, 4.0))
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	# - 倒计时数字走完那一拍:PLAYING 态要收起广播(1v1/3v3 不接这条 —— 它们的 PLAYING
	#   广播由服务器下发的状态切换收起)。
	_broadcast.countdown_finished.connect(_on_countdown_finished)
	_broadcast.set_broadcast(true, "大乱斗", "等待开局…")


# 倒计时走完  ->  若此刻已是 PLAYING,把广播收起(原来是 `_process` 里那两行的统一集中处理)。
func _on_countdown_finished() -> void:
	if _state == ST_PLAYING:
		_broadcast.set_broadcast(false, "", "")


# ── 布局说明(节点树已迁进 ui/royale_hud.tscn)────────────────────────────
# 四个静态区块原先由 _build_board/_build_broadcast/_build_ping/_build_hint 现建
# (阶段 5.5 前 _ready 有 90 净行)。现在场景里声明、上面 @onready 取回:
#   BoardBg + BoardBox(排行榜底与内容,右锚) / Broadcast(共享的广播层,含 Mask)
#   / PingWrap(右下角延迟) / HintWrap(左下角按键提示,下锚)
# - 子节点顺序 = 绘制顺序,必须与当年的 add_child 顺序一致:BoardBg → BoardBox →
#   Broadcast → PingWrap → HintWrap(**Broadcast 的 Mask 盖在排行榜之上是现状**,切勿随意改进)。
# - 硬编码的 1920 屏幕坐标已换成右锚/下锚(1920×1440 视口下位置逐一等价)。

# HUD 元素底板(与单机 HUD 同一套做法)。-  唯一源是 `UiFactory.C_PLATE` —— 本处直接引用,
# 不再有内联字面量(本文件其它地方早就引 `UiFactory`,这里是漏网的那一处)。
# - 本文件的 `_board_bg`(排行榜)**不在其中** —— 那张玩家栏被用户明确提示排除,单独是 0.25。
static func _plate_box(pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_PLATE
	sb.set_corner_radius_all(0)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# 昵称**定宽**成一列(实现在 UiFactory.fit_name,结算页共用同一份口径)。
static func _fit_name(s: String, max_units: int) -> String:
	return UiFactory.fit_name(s, max_units)


func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 字体 + 字号统一由工厂套用(唯一字体来源;size 必须是 16 的倍数,工厂内有 assert 守卫)
	UiFactory.style_control(l, size)
	return l

# 外部(如断线通知)直接弹广播;倒计时由 Broadcast 自己续写(这里一并把它停掉)。
func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)

# 倒计时数字倒计时更新已收进 Broadcast(PLAYING 且走完时由 `_on_countdown_finished` 收起)。
func _process(delta: float) -> void:
	_broadcast.tick(delta)
	# 剩余时间本地倒计时更新微调(每秒有服务器广播校正)
	if _state == ST_PLAYING and not _broadcast.is_counting() and _timer_label.has_meta("remain"):
		var remain := float(_timer_label.get_meta("remain")) - delta
		_timer_label.set_meta("remain", remain)
		_timer_label.text = "剩余时间  %d:%02d" % [int(maxf(remain, 0.0)) / 60, int(maxf(remain, 0.0)) % 60]

func _on_ping(ms: int) -> void:
	# - 不带「延迟」二字,直接 "24ms"(2026-09-17 用户要求);与 PvpHud 相同机制。
	_ping_label.text = "%dms" % ms
	# - 阈值配色(2026-09-17 补):本条**以前只吃 tscn 里那个静态灰蓝、从不上色**,而 1v1 那条
	#   一直按阈值上色 —— 同一个数字在两种模式里长得不一样(用户要求"有颜色")。共用单一来源。
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", ST_PLAYING))
	_state = state
	var names: Dictionary = data.get("names", {})
	var alive: Dictionary = data.get("alive", {})
	var left: Array = data.get("left", [])
	var deaths: Dictionary = data.get("deaths", {})
	var scores: Dictionary = data.get("scores", {})
	# - **缺键 = 此刻没人掉线**(服务端空表不带上该键,见 `GraceWindow.merge_into`)。
	_grace = data.get("grace", {})
	var rows := _refresh_board(names, scores, deaths, alive, left, _grace, state)
	_refresh_broadcast(state, data, names, rows, alive)


# ── 排行榜:按击杀降序 ──
# - **复用行、只改文字**，不要每次 queue_free 后重建 N 个 Label。
#   本函数每秒被调一次(round_state 的 HUD 同步),每次阵亡再加一次;重建 N 个 Label 的
#   同步成本实测 2.6 / 3.8 / 4.7 ms(4 / 6 / 8 行),是纯粹的每秒浪费 ——
#   见 tests/probe/royale_hud_cost_probe.tscn 与 docs/royale-soak-2026-09-12.md §3.1。
#   行数**只在人数变化时**才对不齐(进/退场),那时才增删。
# 返回排好序的行数据 —— 中央广播还要用它判"我是否还在场"。
func _refresh_board(names: Dictionary, scores: Dictionary, deaths: Dictionary,
		alive: Dictionary, left: Array, grace: Dictionary, state: int) -> Array:
	var rows: Array = []
	for role_s in names:
		rows.append({"role": int(role_s), "name": str(names[role_s]),
				"kills": int(scores.get(int(role_s), 0)),
				"deaths": int(deaths.get(int(role_s), 0))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["kills"] != b["kills"]:
			return a["kills"] > b["kills"]
		return a["role"] < b["role"])
	while _rows.size() > rows.size():
		(_rows.pop_back() as Label).queue_free()
	while _rows.size() < rows.size():
		var nl := _make_label(32, COLOR_BOARD)
		# 严格约束行宽 + 保底处理裁剪:文本宽度不再由内容决定(昵称长短不一把整行撑出面板)。
		nl.custom_minimum_size = Vector2(BOARD_W - 8.0, 0)
		nl.size_flags_horizontal = Control.SIZE_FILL
		nl.clip_text = true
		_board_vbox.add_child(nl)
		_rows.append(nl)
	if _rows.size() != _last_row_count:
		_last_row_count = _rows.size()
		# 底板高度随行数自适应(标题 + 计时 + N 行 + 内边距)。
		# - 末尾那个 34 = 原来的 14 + 用户 2026-09-15 要求的"底部再多留 20px"(底板向下多伸一截,
		#   末行文字与板底之间不再贴着)。改行数自适应时**别把它随意修改回 14**。
		# 只在行数变了才取 combined_minimum_size —— 它内部强制一次 layout,不该每秒付。
		_board_bg.size.y = _board_vbox.get_combined_minimum_size().y + 34
	for i in range(rows.size()):
		var e: Dictionary = rows[i]
		var is_me: bool = e["name"] == _my_name
		var tag := "存活"
		var col := COLOR_BOARD if not is_me else COLOR_ME
		if left.has(e["role"]):
			tag = "离开"
			col = COLOR_LEFT
		elif grace.has(e["role"]):
			# 「掉线」= 还在宽限期内、可能会回来(阶段 3,spec §4 的 3.1)。
			# - 排在「离开」**之后**:离开是终态(`mark_disconnected` 已把它移出对局),
			#   而两者在**同一帧**都可能成立(服务器刚 `_grace.leave` 完就 `mark_disconnected`,
			#   载荷里的 `grace` 已不含他 —— 但万一快照旧了一拍,「离开」才是该显示的那个)。
			# 注意： 标签**刻意取短**:这一行本来就贴着面板宽(9 字昵称实测 ≈690px / 面板 720),
			#   「掉线 42s」(8 半角单位)比既有的「复活中」(6 单位)只多 2 单位。
			#   **不要**改成「掉线中,等待重连…」那种长句 —— 会把末段顶出面板(`clip_text`
			#   静默裁掉,不是崩)。
			tag = "掉线 %ds" % int(ceilf(float(grace[e["role"]])))
			col = COLOR_GRACE
		elif not bool(alive.get(e["role"], true)) and state == ST_PLAYING:
			tag = "复活中"
			col = COLOR_DEAD if not is_me else COLOR_ME
		var row: Label = _rows[i]
		row.add_theme_color_override("font_color", col)
		row.text = "%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, _fit_name(str(e["name"]), NAME_UNITS), e["kills"], e["deaths"], tag]
	return rows


# ── 中央广播 ──
func _refresh_broadcast(state: int, data: Dictionary, names: Dictionary, rows: Array,
		alive: Dictionary) -> void:
	match state:
		ST_COUNTDOWN:
			_timer_label.text = "准备…"
			_broadcast.start_countdown(float(data.get("timer", 3.0)), "大乱斗开始")
		ST_PLAYING:
			_broadcast.set_broadcast(false, "", "")
			var remain := float(data.get("timer", 300.0))
			_timer_label.set_meta("remain", remain)
			_timer_label.text = "剩余时间  %d:%02d" % [int(remain) / 60, int(remain) % 60]
		ST_MATCH_OVER:
			_timer_label.text = "对局结束"
			var mw := int(data.get("match_winner", 0))
			if mw == 0:
				_broadcast.set_broadcast(true, "平 局", "杀敌数不相上下")
			elif rows.size() > 0 and mw != 0:
				# winner 名字:names 里 role==mw
				var wname := str(names.get(str(mw), names.get(mw, "P%d" % mw)))
				if wname == _my_name:
					_broadcast.set_broadcast(true, "胜 利 !", "你是大乱斗之王")
				else:
					_broadcast.set_broadcast(true, "失 败", "%s 赢得了大乱斗" % wname)
		_:
			pass
