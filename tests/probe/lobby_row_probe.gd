extends Node

# 统一大厅(mp_lobby)的房卡巡检 —— 界面面探针。
# 运行方式： "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
# 验收标准： 文本 `LOBBY ROW PROBE: ALL-OK`
#
# - 超时帧数配置 `--quit-after 3600`：所有断言均在 `_ready` 中同步执行完成，
#   正常执行完毕后主动调用 `quit()`；该上限仅用于防止异常挂起。
#
# ── 为什么页面不加入场景树 ──
# - 加入场景树就会跑 `_ready`,而 `_finish_lobby_ready` 里有一句
#   `_request_list.call_deferred(...)` -> 真的去连大厅(默认云地址)。本探针只想验画出来的卡,
#   不想开任何 socket、更不想碰用户的 7777。
#   不加入场景树  ->  `_ready` 不跑  ->  没有 deferred、没有网络;只要把 `_ingest_rooms` 用到的两个成员
#   (`_grid` / `_status`)手工摆好,就能直接喂三份载荷。
# - 判「点不动」用的是 `Button.pressed` 上的连接数:`disabled = true` 只是观感,真正的
#   "点了没有反应"是没有连任何 handler。双向逻辑都断言(disabled + 0 连接),否则"画成灰的但
#   仍然连着 handler"会全部断言通过 —— 那种实现里键盘焦点按下去照样会加入。
#
# ── 断言计数 ──
# - 断言完整性校验：验证实际执行断言数量与 EXPECTED_CHECKS 一致（共 14 条），
#   防止因异常提前退出导致测试假阳性。少跑一条即判定失败。

const EXPECTED_CHECKS := 14

# - 载荷里满房那间(5678)喂在前 —— 排序断言(第 9 条)靠它才有意义:
#   若输入顺序本来就对,把满房排后面也能全部断言通过(排序等于没验)。
const ROWS_1V1 := [
	{"code": "5678", "players": 2, "names": ["阿甲", "bob"], "in_match": true},
	{"code": "1234", "players": 1, "names": ["阿甲"], "in_match": false},
]
const ROWS_N := [
	{"code": "5678", "players": 2, "max_players": 4, "names": ["阿甲", "bob"], "in_match": true},
	{"code": "1234", "players": 1, "max_players": 4, "names": ["阿甲"], "in_match": false},
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
	_check_page([ROWS_1V1, ROWS_N, ROWS_N], [PvpSession.MODE_PVP,
			PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM])
	_check_multi_join_dead_end()
	_finish()


func _finish() -> void:
	# - 条数闸用 `!=`:少了 = 有断言没跑到,多了 = 多跑了一条没登记的断言(2026-10-03 最终
	#   整体评审 Minor① 把这一族从 `<` 统一过来)。两种都是账目对不上,都不算 ALL-OK。
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望恰好 %d 条,多了少了都算账目对不上)—— 这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY ROW PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY ROW PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 三份载荷(1v1 / 大乱斗 / 3v3)分别传入页面,断言合并后那张网格里
# 「对局中的卡点不动 / 普通卡可点」双向逻辑都在。
# - 断言用卡上那颗 Button(卡本体就是 Button):`disabled` 只是观感,
#   真正的"点了没有反应"是没连任何 handler —— 双向逻辑都断,否则"画成灰的但仍然连着
#   handler"会全部断言通过(那种实现里键盘焦点按下去照样会加入)。
func _check_page(rows_per_mode: Array, modes: Array) -> void:
	var p: Node = (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	# - 不加入场景树:加入场景树会跑 `_ready` -> `_finish_lobby_ready` 里那句 `_request_list.call_deferred`
	#   会真的去连大厅。本探针只想验画出来的卡,不开任何 socket。
	p.set("_grid", GridContainer.new())
	p.set("_status", Label.new())
	# - 三次 `_ingest_rooms`:第三次(三份都到齐)自己会触发一次 `_redraw_cards`。
	#   这里不再补调一次 —— 同帧调两遍会考出"网格里两批卡叠着"(见 `_redraw_cards` 里
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
	# - 排序:载荷里满房(1v1 的 5678 = 2/2)喂在数组前面,排完后网格里第一张卡必须是
	#   未满那间。-  `sort_custom` 的比较函数返回 true = a 排在 b 前面 —— 写反了满房会跑到
	#   最前;而上面那些断言全按 meta 找卡、对顺序完全不敏感  ->  只有这一条能红。
	#   (网格按 pvp -> royale -> team 画,故第一张必是 pvp 的两张之一。)
	var first: Node = grid.get_child(0)
	var first_code := ""
	if first is Button:
		first_code = str((first as Button).get_meta("code", ""))
	_check(first_code == "1234",
			"排序:未满的卡排在满房之前(网格第一张 = 「%s」,期望 1234)" % first_code)
	p.free()


# ── 多表加入「三张表全拒」的收尾(2026-10-03 ①)──────────────────────────────
# - 为什么必须常驻:加入弹层传的 `_mode` 默认是 ""(全部),而手敲房号正是走
#   `_join_code(code, "", invite)`  ->  三张表都问一次。三条应答全是 absent 时,
#   `_on_server_message` 在吞掉检查之前就 `_ack = true; _sent_ms = 0`(解除 8s 兜底保护),
#   而 `_swallow_absent` 又同时吞「房间不存在」与「房间已满」 ->  房号写错 / 房间已满时
#   一条文案都不显示、也不刷新,状态栏永远停在「加入房间 X,等待配对…」。
#   卡片点击那条路总是传已知模式,所以只有手敲房号这一档会撞上(统一大厅之后才出现的洞)。
# - 夹具直接摆状态、调 `_on_server_message`,不建 socket(与 `_check_page` 相同处理逻辑,页面不加入场景树
#    ->  `_ready` 不跑  ->  没有 deferred 网络;同帧 free 掉那句 `_request_list.call_deferred`)。
func _check_multi_join_dead_end() -> void:
	var p: Node = (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	p.set("_status", Label.new())
	var st: Label = p.get("_status")
	var busy := "加入房间 4321,等待配对…"
	var absent := ["房间不存在", "房间已满", "房间不存在"]

	# 相 A:第一次「三张表全拒」 ->  必须走一次自动刷新(门控前置校验 `_auto_refreshed` 被翻起)+ 清脏凭据。
	p.set("_probe_multi_join", true)
	p.set("_multi_left", 3)
	p.set("_join_pending", "4321")
	st.text = busy
	for m: String in absent:
		p.call("_on_server_message", m)
	_check(int(p.get("_multi_left")) == 0 and bool(p.get("_probe_multi_join")) == false,
			"①A 三张表全拒后多表闸门关闭(_multi_left=0 / _probe_multi_join=false)")
	_check(bool(p.get("_auto_refreshed")) == true,
			"①A 三张表全拒后走了一次自动刷新(_auto_refreshed=true)")
	_check(str(p.get("_join_pending")) == "",
			"①A 三张表全拒后 _join_pending 被清(失败不留脏凭据)")

	# 相 B:刷新额度已花光(`_auto_refreshed=true`)时再全拒一次  ->  状态栏显示最后一条文案。
	p.set("_probe_multi_join", true)
	p.set("_multi_left", 3)
	p.set("_join_pending", "4321")
	st.text = busy
	for m: String in ["房间不存在", "房间不存在", "房间已满"]:
		p.call("_on_server_message", m)
	_check(st.text == "房间已满",
			"①B 刷新额度用光时,状态栏显示**最后一条**服务端文案(实得「%s」)" % st.text)

	# 相 C(正向对照):同样的三条 absent,但 `_join_pending` 已被清(= 有一张表接受了)
	#    ->  不得误判失败、不得多刷一次。-  没有该测试阶段,把收尾写成"门控前置校验一关就报错"会全部断言通过,
	#   而那会让成功的多表加入(1v1 成功 + 另两张表 absent)每次都被误报一次失败。
	p.set("_probe_multi_join", true)
	p.set("_multi_left", 3)
	p.set("_join_pending", "")
	p.set("_auto_refreshed", false)
	st.text = "已加入,等待开战……"
	for m: String in absent:
		p.call("_on_server_message", m)
	_check(bool(p.get("_auto_refreshed")) == false and st.text == "已加入,等待开战……",
			"①C 有一张表接受时不误触发刷新/文案(正向对照;实得 auto_refreshed=%s text=「%s」)"
			% [str(p.get("_auto_refreshed")), st.text])
	p.free()


# 卡是 Button,内容全在子节点里 —— 按 meta 找卡、递归找文案。
# - 不能按 `Button.text` 找:卡的 `text` 是空串(内容自绘),那是有意的。
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
