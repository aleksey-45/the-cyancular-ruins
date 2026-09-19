extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke)。锁的结构横跨两个文件(2026-09-14 拆账本后):
#  **room_manager.gd**:1) SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;3) _process 每周期调
#   _sweep_stale_rooms;4) _sweep_stale_rooms 对超龄房走拆除收口;5) 大乱斗在局宽限谓词同时引用
#   RoyaleHost.MATCH_TIME 与 rr.in_match,且 1v1 仍是裸 MAX_ROOM_AGE。
#  **lobby_rooms.gd**(账本/收口搬来这里):2) 建房时给 created_at 赋时间戳;收口体外不得出现
#   端口归还/注册表删除(见 _check_teardown_funnel);杀 worker 的实现另在 worker_launcher.gd。
#  **批次 3(3v3,2026-09-18)**:argv 契约扩到 --team/--teams(见 _check_argv_contract 的正/反向),
#   另在 _check_team_startup_contract 钉宽限分派/走光退出/不降级/满员才开(真链路归 B 册)。
#  **B 册 Task 4(2026-09-19)**:_check 里把清扫判据扩到**三张注册表**,并单独钉住
#   `_sweep_stale_rooms` 那条「全空则提前 return」的并列守卫 —— 它是**独立的第二条**退出路径,
#   漏掉一张表时列表那行照旧在、断言全绿,而那张表的房永远不清扫(静默端口泄漏)。
#  **B 册 Task 5(2026-09-19)**:3v3 分支补齐与 royale 对称的两条 —— 收集块(`for tcode in
#   lobby.team_rooms`)+ 宽限谓词行(TEAM_MATCH_ESTIMATE / tr.in_match / SWEEP_INTERVAL);
#   此前 3v3 一条都没有,"掏空循环"或"摘掉门控"都能全绿(同样是静默端口泄漏)。
#  **B 册 Task 7(2026-09-19)**:两条**收集块的循环体**断言(`stale_team.append(tr)` /
#   `stale_royale.append(rr)`)—— 只钉 `for …` 头行是**同粒度**的洞:留头行、掏空体时上面四条全绿。
# 跑法:用户自跑(room_sweep_smoke.sh)。通过 = SMOKE_ROOM_SWEEP OK。

var _fail := ""

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://server/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		_finish()
		return
	# ★ 先**编译**一次目标脚本再做文本断言。本冒烟是纯文本扫描(`-s` 下 grep 源码),它**不会**
	#   编译被扫的文件 —— 于是"文本全对但文件压根编译不过"这件事它能直接放过去。
	#   实测踩过:把 `_teardown_room` 的参数从 `kill: bool` 改成 `mode: int` 时漏改了体内一处
	#   `kill` 引用 → GDScript 编译失败,而本冒烟**照样报 OK**(另两条验证也没覆到:主菜单场景
	#   不加载 room_manager,`--worker` 分支也不碰 RoomManager)。`load()` 会真正编译它。
	#   注:`load()` 解析失败时**不返回 null**(给回的是那个坏掉的脚本对象),故判据用
	#   `reload()` 的错误码 —— 它会真的重解析并如实返回 OK / ERR_PARSE_ERROR(实测过两种写法)。
	var scr: GDScript = load("res://server/room_manager.gd")
	if scr == null or scr.reload() != OK:
		_fail = "room_manager.gd 编译失败(源码文本可能全对,但 GDScript 编不过)"
		_finish()
		return
	_check(src)
	_check_argv_contract()
	_check_teardown_funnel()
	_check_team_startup_contract()
	_check_team_spawn_guard()
	_finish()


# 取「**等于** line_text 的那一行 + 紧随其后、缩进更深的一块」(到下一个缩进 ≤ 它的非空行为止)。
# ★ 必须用**保留缩进**的视图(`ScanUtil.code_view`,它同样剥掉注释):`code_only` 会 strip_edges,
#   拿它切不出块 —— 而这里两条断言的价值恰恰在于"那个 if 后面**真的有**它声称做的事"。
# ★ 只返回**第一处**命中:本用途下每个 needle 都是唯一的(命中处不是唯一时,断言会红在
#   "块里没有 X"上,不会静默取错)。
func _block_of(code_view: String, line_text: String) -> String:
	var lines: PackedStringArray = code_view.split("\n")
	for i in range(lines.size()):
		# ★ 匹配用**整行相等**(strip 后),不用 `contains`:本仓的 `elif _team_mode:` 里就含
		#   `if _team_mode:` 这个子串 —— contains 会把 `_run_worker` 那句提示串当成 3v3 收齐分支。
		if lines[i].strip_edges() != line_text:
			continue
		var base := _indent_of(lines[i])
		var out: String = lines[i]
		var j := i + 1
		while j < lines.size():
			if not lines[j].strip_edges().is_empty() and _indent_of(lines[j]) <= base:
				break
			out += "\n" + lines[j]
			j += 1
		return out
	return ""


func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# ── 批次 2 新增:房间拆除收口 ──
# 「端口泄漏」这**同一个**失败模式本层补过三次(on_peer_left 空房分支 / royale_leave 空房分支 /
# ai_duel 摘房前的手动释放)。收口后「新加一条拆除路径」不可能漏 —— 因为没有第二条路可走。
# 断言形态刻意选「**只能出现在这一处**」而不是「数调用点个数」:个数会随实现漂,而这是契约本身。
func _check_teardown_funnel() -> void:
	# ★ 2026-09-14:账本与拆除收口搬进了 server/lobby_rooms.gd(LobbyRooms,见 M4c)。
	#   收口的判据跟着搬 —— 「端口归还与注册表删除只能出现在收口体内」这条纪律与它住哪个文件无关。
	var src := FileAccess.get_file_as_string("res://server/lobby_rooms.gd")
	if src.is_empty():
		_fail = "无法读取 lobby_rooms.gd"
		return
	var funcs: Array = []   # [{name, body}] —— 按 "func " 切块(缩进的内部类方法也算块)
	var cur_name := ""
	var cur_body := ""
	for line in src.split("\n"):
		var st: String = line.strip_edges()
		if st.begins_with("func "):
			if not cur_name.is_empty():
				funcs.append({"name": cur_name, "body": cur_body})
			cur_name = st.substr(5, st.find("(") - 5)
			cur_body = ""
		else:
			cur_body += line + "\n"
	if not cur_name.is_empty():
		funcs.append({"name": cur_name, "body": cur_body})
	# 只有这两个函数体内允许出现端口/注册表的拆除动作(后者是它自己的定义与实现)
	var allowed := ["teardown_room", "_release_port_later"]
	for f in funcs:
		for line in (f["body"] as String).split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue
			# ★ 模式列表必须包含**当前**的端口归还入口。2026-09-14 端口池搬进 WorkerLauncher 后,
			#   `_worker_ports.erase(port)` 改名成 `_launcher.release_now(port)` —— 若不把新名字
			#   加进来,这条门就对端口回收**彻底失明**(它只认旧字符串,而旧字符串已全仓不存在),
			#   表现是恒绿:新加一条绕过收口的拆除路径也照过。改名/搬家时同款改这里。
			# ★★ 三张注册表各留一条判据(1v1 那条就是裸 `rooms.erase(`),且 `*_rooms.erase(` 排在
			#   裸 `rooms.erase(` **之前**:裸那条是另两条的**子串**(`team_rooms.erase(` 里就含
			#   `rooms.erase(`)—— 所以其实三种写法都拦得住,但只留裸那条时判词会点错名字(报
			#   "rooms.erase(" 而实际写的是 team_rooms)。反过来,也**别**把这两条当冗余删掉:删了不会
			#   假绿(仍被子串拦住),只是判词失去分辨力 —— 那是排查时最贵的那点信息。
			for pat in ["_release_port_later(", "launcher.release_now(", "royale_rooms.erase(", "team_rooms.erase(", "rooms.erase("]:
				if t.contains(pat):
					if not allowed.has(f["name"]):
						_fail = "lobby_rooms.%s 里出现 %s —— 拆除必须走 teardown_room 单一收口" % [f["name"], pat]
						return


# ── 批次 2 新增:role 协议必须是**显式 role 集合**(--roles)──
# 旧协议传「人数 + role 上界」两个整数:两者量纲不同、且都得从人数**推导**;而 role 由
# royale_join 的「最小空闲号」分配、有人退出后不重排 → 编号会留空洞(房里 {1,3} 而成员 2 人),
# 推导必然出错 → 持 3 号的真客户端被当串线踢掉(历史 B1)。故做**反向**断言:旧标识符一个都不许复活。
# 它防的是这套 argv 契约的**历史故障模式** —— 大厅与 worker 两边只改一边(CLAUDE.md 明文要求同步改)。
func _check_argv_contract() -> void:
	# 两边的文件清单:**生成端 + 解析端**。2026-09-14 生成端从 room_manager.gd 搬到
	# worker_launcher.gd(spawn 族随迁)——故两处清单都要含 worker_launcher.gd。
	# ★ 别只改正向那条:反向(旧标识符禁令)若还扫着 room_manager.gd,新生成端就没人管了,
	#   旧协议名可以在那儿悄悄复活 —— 那正是「只改一半」的另一种形态。
	for f in ["res://server/server_main.gd", "res://server/worker_launcher.gd"]:
		var txt := FileAccess.get_file_as_string(f)
		if txt.is_empty():
			_fail = "无法读取 %s" % f
			return
		for line in txt.split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue   # 注释里提旧协议名是**有意的**(留档为什么换掉),不算违规
			# ★ 批次 3(3v3)新增 `--team-size` / `_team_bound`:同一类故障模式(把"队数/人数"
			#   当参数量纲,再从 role 号推队号)。队号与 role 集合**同序等长**传过去才是精确的那条。
			for bad in ["--players", "--max-role", "_role_bound", "_expected_players",
					"--team-size", "_team_bound"]:
				if t.contains(bad):
					_fail = "%s 的代码里仍有旧 argv 协议标识符 %s(应已换成 --roles 集合)" % [f, bad]
					return
	# 正向:集合协议必须在两边都在位(只改一边 = 拉起的 worker 收不到 role 集合,静默降级)
	# ★ 批次 3(3v3):`--team` / `--teams` 同样**两边都要在** —— 生成端(worker_launcher)拼了
	#   而解析端(server_main)没接 = worker 收到一个它不认识的开关,静默按 1v1 形态跑;
	#   反过来只改解析端 = 大厅拉起的 worker 永远不带队号。**文件清单只有这两个**,别漏。
	for f in ["res://server/server_main.gd", "res://server/worker_launcher.gd"]:
		var txt2 := FileAccess.get_file_as_string(f)
		if not txt2.contains('"--roles"'):
			_fail = "%s 未接 --roles(集合协议只接了一半?)" % f
			return
		for tok in ['"--team"', '"--teams"']:
			if not txt2.contains(tok):
				_fail = "%s 未接 %s(3v3 启动协议只接了一半?)" % [f, tok]
				return

# ── 批次 3(3v3)新增:启动契约里"本册能做到的那一半" ──
# ★ 边界照实写明:**真链路**(6 个真客户端连上 `--team` worker → 满员开局 → 有人掉线 →
#   宽限到期 → **其余人继续打**)归 **B 册的真链路探针** —— 它需要大厅侧的 team 房间入口,
#   而那个入口本册不做。本函数钉的是**分派本身**:
#   ① `--team` / `--teams` 两边逐字对应(在 `_check_argv_contract` 里);
#   ② 宽限到点走那条**已被 grace_window_smoke ⑦ 逐个模式钉住答案**的纯函数,而不是又抄一遍
#      if/else —— 原先那个 `else` 把 1v1 与 3v3 一起吞成"收场退进程",3v3 第一个宽限到期的人
#      会带着整局退进程(与用户裁定"该队少人继续打"相反;当时不可达,只因大厅还没有入口);
#   ③ `_expire_graces` 末尾那条"全员走光才退出"也含 3v3(漏了 = 走光后 worker 永驻占端口);
#   ④ 3v3 的超时梯不降级(与 --royale 方向相反)、收齐判据是"满员才开"。
func _check_team_startup_contract() -> void:
	var src := ScanUtil.read("res://server/server_main.gd")
	if src.is_empty():
		_fail = "无法读取 server_main.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 到点的分派必须走纯函数(答案在 grace_window_smoke ⑦ 里按模式逐个钉死)。
	var expire := ScanUtil.func_body(code, "_expire_graces")
	if expire.is_empty():
		_fail = "找不到 _expire_graces 的函数体"
		return
	# ★★ 判据必须落到"**比较了**"上,不能只查函数名出现(Task 9 评审 M1):
	#   旧写法是 `contains("GraceWindow.expire_action(")` —— 而把分派退回不可测写法、同时把那行
	#   当**死代码**留下的变异(`var _a := GraceWindow.expire_action(...)` + 原样的 `if _royale: … else: quit`)
	#   两条都满足 ⇒ 全绿,而 3v3 已经坏了(宽限到期的那个人会带着整局退进程)。
	#   故要求整条比较式在位;另加一条反向:分派里不许再出现手写的 `if _royale:` 优先级分支。
	if not expire.contains("GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE"):
		_fail = "_expire_graces 未把 GraceWindow.expire_action 的返回值**比较**给 ACTION_REMOVE(分派退回不可测的 if/else?)"
		return
	if expire.contains("if _royale:"):
		_fail = "_expire_graces 里出现了手写的 `if _royale:` 分派(三个模式的答案必须来自 GraceWindow.expire_action)"
		return
	if not expire.contains("mark_disconnected(role)"):
		_fail = "_expire_graces 的移出分支未调 mark_disconnected(3v3 少人应继续打)"
		return
	# ② 末尾那条"全员走光才退出"必须把 _team_mode 一并收进去。
	# ★ 与上面那条分派是**两条**判据(一条管"某个人到点怎么办"、一条管"人全走光了 worker 退不退"),
	#   只改一条就是"3v3 少人继续打"能成立、但一局打完 6 个人走光后 worker 永驻占端口。
	var gone := ""
	for line in expire.split("\n"):
		if line.contains("_match_started and _claims.is_empty() and _grace.size() == 0"):
			gone = line
			break
	if gone.is_empty():
		_fail = "找不到 _expire_graces 末尾的「全员走光才退出」判据(被删了?)"
		return
	if not gone.contains("_team_mode"):
		_fail = "「全员走光才退出」判据没含 _team_mode(3v3 全员走光后 worker 永驻占端口)"
		return
	# ③ `_begin_match` 必须真的建 TeamHost(而不是落进 1v1 分支静默开成 2 人局)。
	var begin := ScanUtil.func_body(code, "_begin_match")
	if not begin.contains("TeamHost.start_on("):
		_fail = "_begin_match 未按 _team_mode 建 TeamHost(3v3 会静默开成 1v1)"
		return
	# ④ 超时梯:**不降级**(方向与 --royale 相反)。
	#   判据只取那一支的块(到下一个 `elif` 为止)—— 看整段 `_process` 会被别处的 quit
	#   **和大乱斗那条自己的 `_begin_match()`** 喂饱(两种写法都实测过:放宽到固定行数会把
	#   正确实现判红,收紧到写死 5 行则漏掉块尾的 quit)。
	var ladder := ""
	var lines: PackedStringArray = code.split("\n")
	for i in range(lines.size()):
		if lines[i].contains("_team_mode and not _match_started"):
			var j := i + 1
			while j < lines.size() and not lines[j].begins_with("elif "):
				j += 1
			ladder = "\n".join(lines.slice(i, j))
			break
	if ladder.is_empty():
		_fail = "找不到 3v3 的报到超时梯(未满员时 worker 会一直占着端口)"
		return
	if not ladder.contains("quit(0)"):
		_fail = "3v3 报到超时梯没有 quit(0)(收不齐就该退出释放端口)"
		return
	if ladder.contains("_begin_match("):
		_fail = "★ 3v3 超时梯调了 _begin_match(降级开局)—— 与用户裁定「满 6 人才开」相反"
		return
	# ⑤ 收齐判据 = 满员,且**分母是驱动摆位的那个集合**(Task 9 评审 M5)。
	# ★ 判据落在 3v3 那一支的**整块**上(用保留缩进的视图切块),而不是"文件里某处出现过某串":
	#   后者既能被别处的同形代码喂饱,也照不出"分母用错集合"这一档。
	# ★ 为什么分母必须是 `_team_of_role.size()`:`_team_of_role` 按 role **去重**,`_role_set` 是
	#   `--roles` 的逐 token 列表 —— `--roles 1,1,2,2,3,3 --teams 1,1,1,2,2,2` 长度校验能过,
	#   而队伍表只有 3 键 ⇒ 拿 6 当满员界**永远到不了** ⇒ 干等 30s 超时退出(静默,零报错)。
	var fill := _block_of(ScanUtil.code_view(src), "if _team_mode:")
	if fill.is_empty():
		_fail = "找不到 3v3 的收齐分支(_on_role_claimed 里的 `if _team_mode:`)"
		return
	if not fill.contains("if _claims.size() >= _team_of_role.size():"):
		_fail = "3v3 收齐判据不是「满员才开」(_claims.size() >= _team_of_role.size())"
		return
	if fill.contains("_role_set.size()"):
		_fail = "3v3 收齐判据用的是 _role_set.size()(role 会重复/留空洞 —— 分母必须取去重后的队伍表)"
		return
	# ⑥ role 越界守卫必须同时管 3v3:`_team_of_role` 只覆盖 --roles 里的 role,集合外的 role
	#    混进来会让 `_claims.size()` 提前够数开局,而 TeamHost 那侧 `spawns[role]` 缺键。
	if not code.contains("((_royale or _team_mode) and not _role_set.has(role))"):
		_fail = "_on_role_claimed 的越界守卫只认 _royale(集合外的 role 能混进 3v3 局里开局)"
		return
	# ⑦ 模式开关**互斥**(Task 9 评审 M4):`--royale` 与 `--team` 同时为真时必须当场拒绝启动。
	#    此前三处判据的优先级并不一致(`_ready` 里 royale 先、`_on_role_claimed`/`_begin_match`
	#    里 team 先):手敲两个开关时 `_team_of_role` 永不填充,而 `_begin_match` 却按 team 分支
	#    去建 TeamHost → 空 teams → `spawns[role]` 全员缺键。生产不可达(生成端是两个独立函数),
	#    但它与"绝不静默"的纪律不一致。★ 判据取那只守卫的**整块**(到下一个同缩进行为止):
	#    只查 `if _royale and _team_mode:` 这行文本的话,一个被 `pass` 掉的空块照样全绿 ——
	#    那正是 M1 那类"看着像守卫、其实守不住"的形状。
	var excl := _block_of(ScanUtil.code_view(src), "if _royale and _team_mode:")
	if excl.is_empty():
		_fail = "server_main 未拒绝 --royale 与 --team 同时为真(模式开关互斥的守卫被删?)"
		return
	if not excl.contains("quit(1)"):
		_fail = "--royale/--team 互斥守卫里没有 quit(1)(空块 = 守卫守不住,静默开成错的那一半)"
		return


# ── 批次 3(3v3)新增:生成端的 fail-fast(队号**取值**)──
# ★ 为什么这条必须**真调一次**、而不是再写一条源码文本断言:文本只能证明"那几行字在"。
#   而这里的失败后果是**静默**的:解析端对越界队号静默丢弃 → 子进程因长度不等开机即 quit(1),
#   而生成端返回 `pid > 0` ⇒ 大厅判定"拉起成功"、**对局永不开始、大厅侧零报错**
#   (Task 9 评审 M2;B 册大厅要从房间数据拼 teams,最容易踩的就是这一脚)。
# ★ 只喂**非法**输入:合法输入会真的拉起一个子进程(本冒烟不该做那件事)。
#   控制组的判别点 = **长度相等**而队号越界 —— 只校验长度的旧实现在这一档会放行。
func _check_team_spawn_guard() -> void:
	print("[info] 下面那条 ERROR 是**预期**的:正在验证生成端拒绝越界队号(不真调一次,这条守卫就只是空话)")
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段。
	# (正确的实现**不会**拉起任何进程 —— 校验在 `OS.create_process` 之前。)
	var bad_val := WorkerLauncher.new().spawn_team_worker(7770, [1, 2, 3], [1, 1, 3])
	if bad_val:
		_fail = "spawn_team_worker 放行了越界队号(长度相等、队号 3 越界 → 子进程开机即 quit、大厅判定成功、零报错)"
		return


func _check(src: String) -> void:
	if not src.contains("const SWEEP_INTERVAL := 600.0"):
		_fail = "缺 SWEEP_INTERVAL=600(10min)常量"; return
	if not src.contains("const MAX_ROOM_AGE := 7200.0"):
		_fail = "缺 MAX_ROOM_AGE=7200(2h)常量"; return
	# created_at 的赋值点随 create_room/royale_create 搬进了 lobby_rooms.gd
	if not FileAccess.get_file_as_string("res://server/lobby_rooms.gd").contains(
			"created_at = Time.get_unix_time_from_system()"):
		_fail = "create_room/royale_create 未记录 created_at(超龄判据的输入)"; return
	if not src.contains("func _process"):
		_fail = "缺定时 _process"; return
	if not src.contains("func _sweep_stale_rooms"):
		_fail = "缺 _sweep_stale_rooms"; return
	# 杀 worker 的实现已随端口池搬进 WorkerLauncher(2026-09-14),这里改认新入口 ——
	# 但**两条都要**:实现存在 + room_manager 里有人调它。只查实现会放任"实现在、收口不再杀"
	# (清扫路径不杀 → 僵尸 worker 继续占着端口,正是本层补过三次的那个泄漏)。
	if not FileAccess.get_file_as_string("res://server/worker_launcher.gd").contains("func kill_worker"):
		_fail = "缺 WorkerLauncher.kill_worker(杀 worker 的实现)"; return
	if not FileAccess.get_file_as_string("res://server/lobby_rooms.gd").contains("launcher.kill_worker("):
		_fail = "lobby_rooms 未调 launcher.kill_worker(收口不再杀 worker → 僵尸占端口)"; return
	# _sweep_stale_rooms 体内必须出现:超龄判断、杀 worker、erase 房间
	var fn := src.find("func _sweep_stale_rooms")
	var body_end := src.find("\nfunc ", fn + 10)
	if body_end < 0:
		body_end = src.length()
	var body := src.substr(fn, body_end - fn)
	if not body.contains("created_at > MAX_ROOM_AGE"):
		_fail = "_sweep_stale_rooms 缺超龄判断"; return
	# 去掉注释行后的代码视图(注释里出现同名字符串不算数)
	var src_lines: Array = []
	for line in body.split("\n"):
		var t: String = line.strip_edges()
		if not t.is_empty() and not t.begins_with("#"):
			src_lines.append(t)
	# 上面那条 created_at > MAX_ROOM_AGE 只被 1v1 裸行满足,宽限被删掉它照样通过,故另立断言。
	# 断言只在**谓词那两行**(宽限声明 + 比较)上做,不查整个 body:body 里别的代码行(清理日志)
	# 也含同样的常量名,查全 body 会被它喂饱 —— 实测把宽限改回「只加一局时长」仍能通过。
	var code_lines := PackedStringArray(src_lines)
	var code := "\n".join(code_lines)
	var pred := ""
	for i in range(code_lines.size()):
		if code_lines[i].contains("rr.created_at > MAX_ROOM_AGE"):
			pred = code_lines[i]
			if i > 0:
				pred = code_lines[i - 1] + "\n" + pred
			break
	if pred.is_empty():
		_fail = "找不到大乱斗超龄判定(谓词行)"; return
	if not pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限缺 RoyaleHost.MATCH_TIME(宽限被删/被写死?)"; return
	if not pred.contains("rr.in_match"):
		_fail = "大乱斗在局宽限缺 rr.in_match 门控"; return
	if not pred.contains("SWEEP_INTERVAL"):
		_fail = "大乱斗在局宽限未含 SWEEP_INTERVAL(界被改回只加一局,挡不住下一次 tick?)"; return
	# 反过来:1v1 的超龄判断必须保持裸 MAX_ROOM_AGE,宽限不得泄漏进 1v1 分支
	if not code.contains("room.created_at > MAX_ROOM_AGE:"):
		_fail = "1v1 超龄判断不再是裸 MAX_ROOM_AGE(宽限泄漏?)"; return
	# ── B 册 Task 5(2026-09-19):3v3 的**收集块 + 宽限谓词**也要各有一针 ──
	# ★ 此前这里与 royale 分支**不对称**:royale 那条三截谓词断言在,3v3 一条都没有。缺它时
	#   「保留 `var stale_team` 声明、掏空 `for tcode in lobby.team_rooms:` 循环」或「把
	#   tr.in_match / TEAM_MATCH_ESTIMATE 从宽限里摘掉」都能编译通过、上面四条(三张表名、
	#   提前 return 的并列判据、拆除列表)全绿 —— 而那正是「守卫在、3v3 永不被清」那一档
	#   (-worker 端口永久泄漏)。收集块与谓词行**各钉一次**:只钉删除列表那行不够,它由
	#   stale_team 变量喂饱,变量恒空也照过。
	if not body.contains("for tcode in lobby.team_rooms"):
		_fail = "_sweep_stale_rooms 没有收集 3v3 超龄房的循环(team_rooms 永不被扫 → 端口永久泄漏)"; return
	# ★★ B 册 Task 7(评审留的**同粒度**洞):上面那条只认 `for …` 的**头行** —— 保留头行、
	#   只把循环体掏空(删掉 `stale_team.append(tr)`)时,上面那条 + 既有的 `contains("stale_team")`
	#   + 三表并列判据 + 拆除列表**四条全绿**,而 `stale_team` 恒空 ⇒ 3v3 房**永不被清**(端口泄漏)。
	#   royale 那一侧此前**同样**没钉 append(同一个洞,不是本任务引入的退化)—— 一并补上:
	#   两边各钉一次,守的是"循环头在、循环体是空的"这个形状。
	if not body.contains("stale_team.append(tr)"):
		_fail = "_sweep_stale_rooms 的 3v3 收集块循环体是空的(留了 for 头行却没 append → stale_team 恒空,3v3 房永不被清)"; return
	if not body.contains("stale_royale.append(rr)"):
		_fail = "_sweep_stale_rooms 的 royale 收集块循环体是空的(留了 for 头行却没 append → stale_royale 恒空,大乱斗房永不被清)"; return
	var tpred := ""
	for i in range(code_lines.size()):
		if code_lines[i].contains("tr.created_at > MAX_ROOM_AGE"):
			tpred = code_lines[i]
			if i > 0:
				tpred = code_lines[i - 1] + "\n" + tpred
			break
	if tpred.is_empty():
		_fail = "找不到 3v3 超龄判定(谓词行)"; return
	if not tpred.contains("TEAM_MATCH_ESTIMATE"):
		_fail = "3v3 在局宽限缺 TEAM_MATCH_ESTIMATE(宽限被删/被写死?)"; return
	if not tpred.contains("tr.in_match"):
		_fail = "3v3 在局宽限缺 tr.in_match 门控"; return
	if not tpred.contains("SWEEP_INTERVAL"):
		_fail = "3v3 在局宽限未含 SWEEP_INTERVAL(界被改回只加一局,挡不住下一次 tick?)"; return
	# 批次 2 改法:_sweep 不再**直接**杀 worker / 删房,改走拆除收口(带 KILL 形态)。
	# 「杀 worker + 删房 + 回收端口」这件事本身仍被 _check_teardown_funnel 钉住(那些动作只允许
	# 出现在 _teardown_room 体内);这里只认新入口。
	# ★ 别改回「直接调 _kill_worker」:那样端口回收会绕过收口,正是本层补过三次的那个泄漏。
	if not body.contains("teardown_room(") or not body.contains("TEARDOWN_KILL"):
		_fail = "_sweep_stale_rooms 未走拆除收口(应调 _lobby.teardown_room(..., LobbyRooms.TEARDOWN_KILL, ...))"; return
	# 三张注册表都要被拆:rooms(1v1) / royale_rooms / team_rooms 并存,漏一张 = 那张的端口永久泄漏
	if not body.contains("stale + stale_royale"):
		_fail = "_sweep_stale_rooms 未把多张注册表的超龄房一并拆除"; return
	# ★★ 批次 3(Task 4):3v3 那一支的**两条**判据 —— 只查「拆除列表」是不够的,因为
	#   末尾那条「全空则提前 return」的并列判据是**独立的第二条**退出路径:
	#     `if stale.is_empty() and stale_royale.is_empty(): return`
	#   漏掉 stale_team 时,**只有 3v3 房超龄**的那次 tick 会当场 return、永远不清扫 →
	#   端口永久泄漏;而拆除列表那行照旧在、房间收集块照旧在 ⇒ 只查列表的断言**全绿**。
	#   这正是本层反复补的同一个失败模式(见 lobby_rooms.teardown_room 的注释)的第四种形态,
	#   且症状是**静默**的。故这里逐个点名三张表、并单独钉住那条提前返回。
	if not body.contains("stale_team"):
		_fail = "_sweep_stale_rooms 完全没扫 3v3 房(team_rooms 的超龄房 → worker 端口永久泄漏)"; return
	if not body.contains("stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty()"):
		_fail = "_sweep_stale_rooms 的「无超龄房则提前 return」守卫漏了某张注册表(只有那张表的房超龄时永不清扫 → 静默端口泄漏)"; return
	if not body.contains("stale + stale_royale + stale_team"):
		_fail = "_sweep_stale_rooms 的拆除列表未含全部三张注册表(未被扫到的那张 → 端口永久泄漏)"; return
	# 汇总 print 也必须报第三条界(照实登记的估值界;漏了只是日志失真,但它是上面那些界的**唯一**读数)
	var summary := ""
	for line in code_lines:
		if line.begins_with('print("[lobby] 清理'):
			summary = line
			break
	if summary.is_empty() or not summary.contains("3v3"):
		_fail = "_sweep_stale_rooms 的汇总 print 未报 3v3 那一档(界有变化而日志读不出来)"; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备(三张注册表的在局宽限界逐个钉死:1v1 裸界 / 大乱斗 RoyaleHost.MATCH_TIME / 3v3 TEAM_MATCH_ESTIMATE)")
	quit(0)
