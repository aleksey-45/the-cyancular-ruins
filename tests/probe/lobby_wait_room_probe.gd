extends Node

# 统一大厅 `mp_lobby` 的**等待室**探针(Task 5)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_wait_room_probe.tscn
# 判据: 文本 `LOBBY WAIT ROOM PROBE: ALL-OK(N 条断言)`(不看退出码 —— 探针挂住时 --quit-after
#       到期仍 exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ═══ 为什么需要它 ═══
# ★★ 等待室的实现形状**天生静默**:三个模式共用**一个**面板,按 `mode` 分支清空重填。
#    · "少清一次" ⇒ 上一个模式的名单**叠在新名单上**(3+1 行,没人报错);
#    · "少登记一次 meta" ⇒ 探针数不出名单行,只能遍历所有 Label 猜(极易假绿);
#    · "少连一颗按钮" / "少接一条 handler" ⇒ 那颗按钮画在屏上、按下去毫无反应。
#    三类都没有任何运行时信号 —— 只有断言看得见。
# ★ (a)(b) 两张接线表(四条 `_show_wait_room` 调用点、`_hide_wait_room` 的唯一调用点
#    `_on_return_to_lobby`、三个模式下各按钮连什么)是本任务的硬要求:本探针**行为级**地
#    走四条调用点里的三条半(1v1 建房 / 1v1 加入 / 大乱斗状态 / 3v3 状态),以及
#    `_on_return_to_lobby` 的隐藏行为(经**真按钮**按下去触发)。
#
# ⚠ 预期噪音(不是失败):本探针**不入树、不开任何 socket**,但凡走**房主路径**
#    (`room_map`)或 **leave RPC** 的相,在"没有大厅对端"时各打**一条**引擎 ERROR
#    (`RPC 'x' on yourself is not allowed` / `Trying to call an RPC while no multiplayer
#    peer is active`)。实测 GDScript 在那一行之后**继续执行**,不会中断函数。
#    ⇒ 本探针共 **5 条**这种 ERROR 属**预期**,来自:③(1v1 建房)/ ⑩ 的房主载荷(喂 ⑪)/
#      ⑯ / ⑯c(3v3 房主)/ ⑱(leave)。判词只认 `LOBBY WAIT ROOM PROBE: ALL-OK`。
#    ★ 零 RPC 的相:`_on_room_joined`(无 room_map)与**非房主**的 `room_state`(⑤/⑥/⑦/⑫ 等)。
#    ★ 这条清单是"改本探针要一起看"的:加一个房主相就多一条噪音,别把它读成新故障。
# ⚠ 另一处预期噪音:按 1v1 的「退出房间」会走 `_return_to_lobby` → `NetBus.start_client`
#    (本仓 create-form 探针同款)。同一同步调用栈内紧跟 `NetBus.stop()`,ENet 只在 poll 里
#    flush ⇒ 本帧就 quit,**一个包都不出网**。
#
# ★ 覆盖边界(照实登记,别读成"已覆盖"):居中的锚点必须在**入树之后**设(两页旧稿都踩过),
#   本探针**不入树** ⇒ 那一条**没有断言**(与 `lobby_create_form_probe` 同款缺口)。
#   版式本身不在这里验;这里验的是"哪个模式画出哪些东西 + 哪些按钮连着谁"。
#
# ★ EXPECTED_CHECKS 是"ALL-OK 不等于全都跑过"那条纪律的落点 —— 出错只会让**当前函数**
#   当场结束、调用方继续,判词照打。少跑一条即红。
const EXPECTED_CHECKS := 21

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
	var packed: PackedScene = load("res://scenes/mp_lobby.tscn")
	# 空载守卫:解析失败时 `load()` 仍返回非 null 但 `instantiate()` 会炸;两者都挡住,
	# 免得走不到 `_finish()` 而让进程挂在 --quit-after 上(一行裁决都不打)。
	if packed == null or not packed.can_instantiate():
		print("LOBBY WAIT ROOM PROBE: 无法加载 mp_lobby.tscn")
		get_tree().quit(1)
		return

	_phase_pvp(packed)       # ①-⑤ 1v1:加入/建房两条调用点 + 退出的隐藏行为
	_phase_royale(packed)    # ⑥-⑪ 大乱斗:名单/颜色行/房主闸门/清空重填
	_phase_team(packed)      # ⑫-⑯ 3v3:两队+未选边/编号印行序/颜色行/选边/开始
	_phase_wiring(packed)    # ⑰-⑲ 收起创建弹层 / 大乱斗退出 / 四颗按钮各恰 1 个 handler
	_finish()


# ── ①-⑤:1v1 ────────────────────────────────────────────────────────
# ★ 1v1 **新增**的一座等待室(旧 1v1 页建房后什么都没有,状态只落状态栏)。
func _phase_pvp(packed: PackedScene) -> void:
	var p = _page(packed)

	# ① (brief 1/2) 1v1 **加入**那条调用点:`_on_room_joined(role)` 必须把等待室亮起来。
	#    房号只能从 `_join_pending` 取(`room_joined` 载荷只有 role)。
	p.set("_join_pending", "4321")
	p.call("_on_room_joined", 2)
	_check(p._wait_panel != null and p._wait_panel.visible
			and p._wait_title.text.contains("4321")
			and p._wait_count.text == "等待对手… 1 / 2",
			"① 1v1 加入后:等待室可见 + 标题含房间号 + 人数行是「等待对手… 1 / 2」(实得标题「%s」/人数行「%s」)"
					% [_title_text(p), _count_text(p)])

	# ② (brief 1) 1v1:有「退出房间」;选边与开始**都不可见**(1v1 两人凑齐自动开局,没有开始按钮)。
	var leave := _find_button(p._wait_panel, "退出房间")
	_check(leave != null and leave.visible
			and not _find_button(p._wait_panel, "加入 A 队").visible
			and not _find_button(p._wait_panel, "加入 B 队").visible
			and not _find_button(p._wait_panel, "开 始 游 戏").visible,
			"② 1v1:退出房间在;选边/开始三颗都不可见")

	# ④ (brief 7) 1v1 有角色颜色行。
	_check(p._wait_hue.visible, "④ 1v1:角色颜色行可见")

	# ③ (接线 a) 1v1 **建房**那条调用点:`_on_room_created(code)`。
	p.call("_on_room_created", "8765")
	_check(p._wait_panel.visible and p._wait_title.text.contains("8765"),
			"③ 1v1 建房后:等待室可见 + 标题含新房号(实得「%s」)" % _title_text(p))

	# ⑤ (接线 a / 唯一调用点) 按**真按钮**「退出房间」⇒ 走 `_return_to_lobby` → `_on_return_to_lobby`
	#    → `_hide_wait_room`。★ 判词只说"隐藏":它守的是"这条链上有人在改 `_wait_panel.visible`"。
	#    把 `_on_return_to_lobby` 里那句删掉 ⇒ ⑤ 与 ⑱ **一起红**(两条都走那条共用清理),
	#    其余相照绿 —— 读数这么辨是因为 `_hide_wait_room()` 的调用点**只有**那一处。
	leave.pressed.emit()
	_check(not p._wait_panel.visible, "⑤ 按 1v1 退出房间:等待室隐藏(唯一调用点 `_on_return_to_lobby`)")
	NetBus.stop()   # 拆掉 `_return_to_lobby` 刚建的 client:本帧就 quit,不发一个包出去
	p.free()


# ── ⑥-⑪:大乱斗 ─────────────────────────────────────────────────────
func _phase_royale(packed: PackedScene) -> void:
	var p = _page(packed)

	# 非房主(host_role 1 ≠ your_role 2)⇒ 顺带绕开 `room_map` 那条 RPC(只有房主才发)。
	var st := _royale_state("2468", [["甲", 1], ["乙", 2], ["丙", 3]], 2, 1)
	p.call("_on_room_state_royale", st)
	_check(p._wait_panel.visible and p._wait_title.text.contains("2468"),
			"⑥ 大乱斗房间状态 ⇒ 等待室可见 + 标题含房号(实得「%s」)" % _title_text(p))

	# ⑦ (brief 3) 名单行数 == 载荷 players 条数。★ 判据是每行上的 `roster_row` meta
	#    (brief (c))—— 靠"遍历所有 Label"会把标题/人数行一起数进来,极易假绿。
	_check(_roster_rows(p._wait_panel).size() == 3,
			"⑦ 大乱斗:名单行数 == players 条数(期望 3,实得 %d)" % _roster_rows(p._wait_panel).size())

	# ⑧ (brief 7) 大乱斗有角色颜色行。
	_check(p._wait_hue.visible, "⑧ 大乱斗:角色颜色行可见")

	# ⑨ (brief 6) 非房主 ⇒ 开始游戏不可见;顺带:大乱斗**不该有**选边按钮(那是 3v3 的)。
	_check(not _find_button(p._wait_panel, "开 始 游 戏").visible
			and not _find_button(p._wait_panel, "加入 A 队").visible
			and not _find_button(p._wait_panel, "加入 B 队").visible,
			"⑨ 大乱斗非房主:开始游戏不可见 + 两颗选边按钮都不可见")

	# ⑪ 清空重填:再喂一份**更短的**载荷 ⇒ 行数跟着变(3 → 1),而不是叠成 4。
	var st2 := _royale_state("2468", [["甲", 1]], 1, 1)
	p.call("_on_room_state_royale", st2)
	_check(_roster_rows(p._wait_panel).size() == 1,
			"⑪ 重入清空:名单行数跟着新载荷走(期望 1,实得 %d)—— 少了清空会叠成 4"
					% _roster_rows(p._wait_panel).size())

	# ⑩ (brief 5 的正向对照,大乱斗那一半) 房主(host_role == your_role)⇒ 开始游戏可见。
	#    ★ 缺了这一条,⑨ 可以被一个"永远不可见"的实现通过 —— 两条一起才钉住"按 host_role 判"。
	_check(_find_button(p._wait_panel, "开 始 游 戏").visible, "⑩ 大乱斗房主:开始游戏可见")
	p.free()


# ── ⑫-⑯:3v3 ────────────────────────────────────────────────────────
func _phase_team(packed: PackedScene) -> void:
	var p = _page(packed)

	# 这份载荷正是 brief 断言 8 要的:roles = [1, 3]、都在未选边档 ⇒ 印 role 会出 1、3。
	# ★ host_role 给 99(非房主)只为**绕开 `room_map` 那条 RPC**(只有房主才发)——
	#   本相不验房主,少一条引擎噪音。
	var st := _team_state_pick("1357", [["甲", 1, 0], ["乙", 3, 0]], 1, 99, 3)
	p.call("_on_room_state_team", st)

	# ⑫ (brief 2) 两队标题 + 未选边档 + 两颗选边按钮都在。
	_check(_has_label_text(p._wait_panel, "A 队") and _has_label_text(p._wait_panel, "B 队")
			and _has_label_text(p._wait_panel, "未选边")
			and _find_button(p._wait_panel, "加入 A 队").visible
			and _find_button(p._wait_panel, "加入 B 队").visible,
			"⑫ 3v3:A 队 / B 队 / 未选边三档都在 + 两颗选边按钮都可见")

	# ⑬ (brief 8) 第 2 行名单的编号是**行序** 2 而不是 role 3。
	#    ★ 判据落在**文案前缀**上:印 role 的实现会给出「3. 乙」⇒ 这一条必红。
	var rows := _roster_rows(p._wait_panel)
	_check(rows.size() == 2 and rows[1].text.begins_with("2."),
			"⑬ 名单行编号印行序:第 2 行以「2.」开头(实得「%s」)" % ("" if rows.size() < 2 else rows[1].text))

	# ⑭ (brief 7) 3v3 用队色 ⇒ 角色颜色行整行收起。
	_check(not p._wait_hue.visible, "⑭ 3v3:角色颜色行不可见(用队色)")

	# ⑮ (brief 4) 我在 A 队 ⇒ 「加入 A 队」不可见;「加入 B 队」**仍可见**(正向对照:
	#    缺了它,一个"两颗都藏起来"的实现也能过这一条)。
	var st2 := _team_state_pick("1357", [["甲", 1, 1], ["乙", 3, 1]], 1, 99, 3)
	p.call("_on_room_state_team", st2)
	_check(not _find_button(p._wait_panel, "加入 A 队").visible
			and _find_button(p._wait_panel, "加入 B 队").visible,
			"⑮ 3v3 已在 A 队:加入 A 队不可见,加入 B 队仍可见")

	# ⑯ (brief 5) 房主 + 两队各满 ⇒ 开始游戏可见。
	var full := _team_state_pick("1357", [
			["甲", 1, 1], ["丙", 5, 1], ["戊", 6, 1],
			["乙", 3, 2], ["丁", 4, 2], ["己", 7, 2]], 1, 1, 3)
	p.call("_on_room_state_team", full)
	_check(_find_button(p._wait_panel, "开 始 游 戏").visible, "⑯ 3v3 房主 + 两队各满:开始游戏可见")

	# ⑯b 反向:两队各满但**不是房主** ⇒ 不可见(把上一条的"房主"那一半也钉住)。
	var full2 := _team_state_pick("1357", [
			["甲", 1, 1], ["丙", 5, 1], ["戊", 6, 1],
			["乙", 3, 2], ["丁", 4, 2], ["己", 7, 2]], 3, 1, 3)
	p.call("_on_room_state_team", full2)
	_check(not _find_button(p._wait_panel, "开 始 游 戏").visible,
			"⑯b 3v3 两队各满但非房主:开始游戏仍不可见")

	# ⑯c 反向:房主但**两队没满** ⇒ 不可见(把"两队各满"那一半也钉住)。
	#     ★ 缺了它,一个"房主恒见开始"的实现能过 ⑯ —— 那颗按钮把人送进服务端 `team_start`
	#       的满员守卫(点了没反应),而屏上看着"可以开了";本探针也会**全绿**。
	var mid := _team_state_pick("1357", [["甲", 1, 1], ["乙", 3, 2]], 1, 1, 3)
	p.call("_on_room_state_team", mid)
	_check(not _find_button(p._wait_panel, "开 始 游 戏").visible,
			"⑯c 3v3 房主但两队没满:开始游戏不可见")
	p.free()


# ── ⑰-⑲:接线面 ─────────────────────────────────────────────────────
func _phase_wiring(packed: PackedScene) -> void:
	var p = _page(packed)

	# ⑰ 进等待室**同时**收起创建弹层(否则弹层留在屏上、把等待室压在下面)。
	#    ★ 先真开一次弹层 —— 只调 `_show_wait_room` 的话 `_create_panel` 是 null,
	#      "有没有收起"根本无从谈起(那条断言会恒绿)。
	p.call("_open_create_dialog")
	var opened: bool = p._create_panel.visible
	p.call("_show_wait_room", _royale_state("2468", [["甲", 1]], 1, 1), PvpSession.MODE_ROYALE)
	_check(opened and p._wait_panel.visible and not p._create_panel.visible,
			"⑰ 进等待室:创建弹层被收起(先真开一次再收)")

	# ⑱ (接线 b) 按大乱斗的「退出房间」⇒ 等待室隐藏。★ 大乱斗那条**不断大厅 peer**,
	#    所以它不走 `_return_to_lobby`(那条会 `NetBus.stop()`);隐藏由 `_on_return_to_lobby`
	#    那条共用清理完成 —— 本断言钉的正是"那条清理真的挂在这条按钮的链上"。
	#    ⚠ 这里会打一条 `RPC 'royale_leave' on yourself is not allowed` 的引擎 ERROR(无对端),预期噪音。
	_find_button(p._wait_panel, "退出房间").pressed.emit()
	_check(not p._wait_panel.visible, "⑱ 按大乱斗退出房间:等待室隐藏(走共用清理,不断大厅 peer)")
	NetBus.stop()
	p.free()

	# ⑲ 四颗按钮各恰 1 个 handler。★ 判词只说"恰一个 handler":它守的是"忘了 connect"
	#    (按钮画着、按下去毫无反应)与"重复 connect"(一次点击发两遍)。
	#    **不守**"连错了函数" —— 那是 ⑤ / ⑱ 行为断言的事(它们按真按钮跑完整条链)。
	var p2 = _page(packed)
	p2.call("_show_wait_room", _royale_state("2468", [["甲", 1]], 1, 1), PvpSession.MODE_ROYALE)
	var counts_ok := true
	var counts_msg := ""
	for text: String in ["退出房间", "开 始 游 戏", "加入 A 队", "加入 B 队"]:
		var b: Button = _find_button(p2._wait_panel, text)
		var n := -1 if b == null else b.pressed.get_connections().size()
		if b == null or n != 1:
			counts_ok = false
			counts_msg += " %s=%s" % [text, "缺" if b == null else str(n)]
	_check(counts_ok, "⑲ 四颗按钮各恰 1 个 handler%s" % counts_msg)
	p2.free()


# ── 夹具与小工具 ────────────────────────────────────────────────────

# 一个不入树的页面实例,并把不入树时**为 null** 的几个基类成员垫上。
# ★ 它们是 handler 的必经之路(`_status.text = …` / `_redraw_cards` 读 `_grid`):
#   不垫的话 `_on_room_*` 会在写 `_status` 那一行**当场报错并中断**,
#   后面的 `_show_wait_room` 根本跑不到 —— 整个探针会变成"测一个没跑的东西"。
#   (`lobby_row_probe` 同款垫法。)
func _page(packed: PackedScene):
	var p = packed.instantiate()
	p.set("_status", Label.new())
	p.set("_grid", GridContainer.new())
	return p


# 大乱斗房态载荷。`plist` = [[昵称, role], …];`your_role` / `host_role` 按需给。
func _royale_state(code: String, plist: Array, your_role: int, host_role: int) -> Dictionary:
	var players: Array = []
	for e in plist:
		players.append({"role": int(e[1]), "name": str(e[0]), "team": 0})
	return {"code": code, "is_public": true, "players": players,
			"your_role": your_role, "host_role": host_role, "max_players": 4}


# 3v3 房态载荷。`plist` = [[昵称, role, team], …]。
func _team_state_pick(code: String, plist: Array, your_role: int, host_role: int,
		team_size: int) -> Dictionary:
	var players: Array = []
	for e in plist:
		players.append({"role": int(e[1]), "name": str(e[0]), "team": int(e[2])})
	return {"code": code, "is_public": true, "players": players,
			"your_role": your_role, "host_role": host_role,
			"team_size": team_size, "max_players": 6}


# 名单行 = 带 `roster_row` meta 的 Label(brief (c))。按**行序**返回(深度优先,与添加顺序一致)。
func _roster_rows(n: Node) -> Array[Label]:
	var out: Array[Label] = []
	if n is Label and (n as Label).has_meta("roster_row"):
		out.append(n)
	for c in n.get_children():
		out.append_array(_roster_rows(c))
	return out


# 子树里有没有**任意深度**的 Label 含这段文案?(版式挪层不该让断言失效。)
func _has_label_text(n: Node, needle: String) -> bool:
	if n is Label and (n as Label).text.contains(needle):
		return true
	for c in n.get_children():
		if _has_label_text(c, needle):
			return true
	return false


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func _title_text(p) -> String:
	return "" if p._wait_title == null else p._wait_title.text


func _count_text(p) -> String:
	return "" if p._wait_count == null else p._wait_count.text


# ★ 收尾两道:① 断言条数不足 EXPECTED_CHECKS 即红(有断言没跑到);② 有失败即红。
func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY WAIT ROOM PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY WAIT ROOM PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
