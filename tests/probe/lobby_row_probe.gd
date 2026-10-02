extends Node

# 三个大厅页把「对局中」的房画成**看得见、点不动**的一行 —— 界面面探针。
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
#   `_request_list.call_deferred(...)` → 真的去连大厅(1v1 页默认云地址,另两页 127.0.0.1:7777)。
#   本探针只想验**画出来的行**,不想开任何 socket、更不想碰用户的 7777。
#   不入树 ⇒ `_ready` 不跑 ⇒ 没有 deferred、没有网络;只要把 `_on_*_rooms` 用到的两个成员
#   (`_list_box` / `_status`)手工摆好,就能直接调那三个渲染函数。
# ★ 判「点不动」用的是 `Button.pressed` 上的**连接数**:`disabled = true` 只是观感,真正的
#   "点了没有反应"是**没有连任何 handler**。两半都断言(disabled + 0 连接),否则"画成灰的但
#   仍然连着 handler"会全绿 —— 那种实现里键盘焦点按下去照样会加入。
#
# ═══ 断言计数 ═══
# ★ ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"**(见 tests/lib/probe_base.gd
#   文件头)。故这里比对期望条数:三页 × 8 条 = 24,少跑一条就红。改探针必须同步改这个数。

const EXPECTED_CHECKS := 24

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
	_check_page("res://scenes/matchmaking.tscn", "_on_room_list", ROWS_1V1, "1v1")
	_check_page("res://scenes/royale_lobby.tscn", "_on_royale_rooms", ROWS_N, "大乱斗")
	_check_page("res://scenes/team_lobby.tscn", "_on_team_rooms", ROWS_N, "3v3")
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


# 一页 8 条:对局中那一行(存在 / disabled / 无 handler / 不吃焦点 / 文案含「对局中」/ 名单来自载荷)
# + 普通那一行(不是 disabled / 恰有一个 handler)。
func _check_page(scene_path: String, fn: String, rows: Array, tag: String) -> void:
	var p: Node = (load(scene_path) as PackedScene).instantiate()
	# ★ 手工摆好渲染函数用到的两个成员(不入树 ⇒ `_ready` 不跑 ⇒ 它们都还是 null)
	p.set("_list_box", VBoxContainer.new())
	p.set("_status", Label.new())
	p.call(fn, rows)
	var box: Node = p.get("_list_box")
	var live := _find_button(box, "5678")     # 对局中的那一行
	var open_ := _find_button(box, "1234")    # 普通的那一行(正向对照)
	_check(live != null and open_ != null,
			"%s 两种行都在列表里(live=%s / 普通=%s)" % [tag, str(live), str(open_)])
	if live == null or open_ == null:
		p.free()
		return
	_check(live.disabled, "%s ★ 对局中的行 disabled = true" % tag)
	_check(live.pressed.get_connections().is_empty(),
			"%s ★ 对局中的行没接任何 handler(disabled 只是观感,不接 handler 才是真的点不动)" % tag)
	_check(live.focus_mode == Control.FOCUS_NONE,
			"%s ★ 对局中的行不吃键盘焦点(焦点环落到它上面 = 邀请一次注定失败的按下)" % tag)
	_check(live.text.contains("对局中"), "%s 对局中的行文案含「对局中」(实得「%s」)" % [tag, live.text])
	_check(live.text.contains("阿甲") and live.text.contains("bob"),
			"%s 对局中的行显示**载荷里**的名单(实得「%s」)" % [tag, live.text])
	_check(not open_.disabled, "%s 普通行不是 disabled(正向对照)" % tag)
	_check(open_.pressed.get_connections().size() == 1,
			"%s 普通行恰有一个 handler(还能加入;正向对照)" % tag)
	p.free()


func _find_button(box: Node, code: String) -> Button:
	for c in box.get_children():
		if c is Button and (c as Button).text.contains(code):
			return c
	return null
