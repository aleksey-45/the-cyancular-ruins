extends Node

# 统一大厅(mp_lobby)的房卡巡检 —— 界面面探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
# 判据: 文本 `LOBBY ROW PROBE: ALL-OK`
#
# ★ `--quit-after 3600`(=60s @60fps)的取值依据:本探针**全部断言都在 `_ready` 里同步跑完**,
#   跑完自己 `quit()`;安全网只在挂住时才用得上。本仓的教训是"安全网给薄了会把跑得慢读成
#   功能坏了"(`tests/probe/brawl_rollback_probe.tscn` 用 3600 就跑不完,实测要 30000),而这里没有
#   任何等待。3600 是"绝不可能耗尽"的量级。
#
# ═══ 为什么页面**不入树** ═══
# ★ 入树就会跑 `_ready`,而 `_finish_lobby_ready` 里有一句
#   `_request_list.call_deferred(...)` → 真的去连大厅(默认云地址)。本探针只想验**画出来的卡**,
#   不想开任何 socket、更不想碰用户的 7777。
#   不入树 ⇒ `_ready` 不跑 ⇒ 没有 deferred、没有网络;只要把 `_ingest_rooms` 用到的两个成员
#   (`_grid` / `_status`)手工摆好,就能直接喂三份载荷。
# ★ 判「点不动」用的是 `Button.pressed` 上的**连接数**:`disabled = true` 只是观感,真正的
#   "点了没有反应"是**没有连任何 handler**。两半都断言(disabled + 0 连接),否则"画成灰的但
#   仍然连着 handler"会全绿 —— 那种实现里键盘焦点按下去照样会加入。
#
# ═══ 断言计数 ═══
# ★ ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"**(见 tests/lib/probe_base.gd
#   文件头)。故这里比对期望条数:单页 8 条,少跑一条就红。改探针必须同步改这个数。

const EXPECTED_CHECKS := 8

const ROWS_1V1 := [
	{"code": "1234", "players": 1, "names": ["阿甲"], "in_match": false},
	{"code": "5678", "players": 2, "names": ["阿甲", "bob"], "in_match": true},
]
const ROWS_N := [
	{"code": "1234", "players": 1, "max_players": 4, "names": ["阿甲"], "in_match": false},
	{"code": "5678", "players": 2, "max_players": 4, "names": ["阿甲", "bob"], "in_match": true},
]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_check_page([ROWS_1V1, ROWS_N, ROWS_N], ["pvp", "royale", "team"])
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY ROW PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY ROW PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 三份载荷(1v1 / 大乱斗 / 3v3)分别喂进页面,断言**合并后那张网格**里
# 「对局中的卡点不动 / 普通卡可点」两半都在。
# ★ 断言用**卡上那颗 Button**(卡本体就是 Button):`disabled` 只是观感,
#   真正的"点了没有反应"是**没连任何 handler** —— 两半都断,否则"画成灰的但仍然连着
#   handler"会全绿(那种实现里键盘焦点按下去照样会加入)。
func _check_page(rows_per_mode: Array, modes: Array) -> void:
	var p: Node = (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	# ★ 不入树:入树会跑 `_ready` → `_finish_lobby_ready` 里那句 `_request_list.call_deferred`
	#   会真的去连大厅。本探针只想验**画出来的卡**,不开任何 socket。
	p.set("_grid", GridContainer.new())
	p.set("_status", Label.new())
	# ★ 三次 `_ingest_rooms`:第三次(三份都到齐)自己会触发一次 `_redraw_cards`。
	#   这里**不再**补调一次 —— 同帧调两遍会考出"网格里两批卡叠着"(见 `_redraw_cards` 里
	#   那句 remove_child 的注释);生产里三条 RPC 应答确实可能落在同一帧。
	for i in modes.size():
		p.call("_ingest_rooms", modes[i], rows_per_mode[i])
	var grid: Node = p.get("_grid")
	var live := _find_card(grid, "5678")     # 对局中的那张
	var open_ := _find_card(grid, "1234")    # 普通的那张(正向对照)
	_check(live != null and open_ != null,
			"合并后两种卡都在网格里(live=%s / 普通=%s)" % [str(live), str(open_)])
	if live == null or open_ == null:
		p.free()
		return
	_check(live.disabled, "★ 对局中的卡 disabled = true")
	_check(live.pressed.get_connections().is_empty(),
			"★ 对局中的卡没接任何 handler(disabled 只是观感,不接 handler 才是真的点不动)")
	_check(live.focus_mode == Control.FOCUS_NONE,
			"★ 对局中的卡不吃键盘焦点(焦点环落到它上面 = 邀请一次注定失败的按下)")
	_check(live.modulate.a < 1.0, "对局中的卡整体压暗(modulate.a=%.2f)" % live.modulate.a)
	_check(_has_label_text(live, "对局中"), "对局中的卡上有「对局中」角标")
	_check(not open_.disabled, "普通卡不是 disabled(正向对照)")
	_check(open_.pressed.get_connections().size() == 1,
			"普通卡恰有一个 handler(还能加入;正向对照)")
	p.free()


# 卡是 Button,内容全在子节点里 —— 按 meta 找卡、递归找文案。
# ★ 不能按 `Button.text` 找:卡的 `text` 是空串(内容自绘),那是**有意**的。
func _find_card(grid: Node, code: String) -> Button:
	for c in grid.get_children():
		if c is Button and str((c as Button).get_meta("code", "")) == code:
			return c
	return null


func _has_label_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for c in node.get_children():
		if _has_label_text(c, needle):
			return true
	return false
