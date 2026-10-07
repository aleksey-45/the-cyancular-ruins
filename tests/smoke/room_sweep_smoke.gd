extends SceneTree

# 房间生命周期与僵尸房间清理机制源码级检查：
# 校验 RoomManager 与 LobbyRooms 的超龄房间超时清扫逻辑、3v3/大乱斗启动参数约定以及资源释放路径。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/room_sweep_smoke.gd

var _fail := ""
# 注意事项：2026-09-21(「看得见进不去」批 Task 6 补):**本文件每个 `_check_*` 都必须跑到尾**。
#   为什么需要:本文件的 `_check_*` 全是"`_fail` 非空就提前返回"的写法,而 **GDScript 的脚本错误
#   (`Invalid call. Nonexistent function …` 这类)不给 `_fail` 赋值 —— 它只让出错的那个
#   函数当场结束**,调用方 `_initialize` 照常往下走,`_finish()` 于是输出 OK 判定。实测(本批
#   Task 1 首次发现、Task 6 原样复现):把 `WorkerLauncher.pid_of` 连名带 4 处调用一起改名
#   (只改定义的话 `room_manager.gd` 先编不过、会走另一条红路),输出多一段
#     `SCRIPT ERROR: Invalid call. Nonexistent function 'pid_of' in base 'RefCounted (WorkerLauncher)'`
#   而 verdict 仍是 `SMOKE_ROOM_SWEEP OK` —— 那一组断言被静默跳过,读起来像"全部断言通过"。
#   （参考 tests/lib/probe_base.gd 说明：ALL-OK 仅证明未发生断言失败，需配合执行计数确保所有预期断言均已执行完毕。）
# - 判定条件为什么成立:`_fail` 为空时,任何"提前 return"都只可能来自函数开头那条
#   `if _fail != "": return` —— 而它只在 `_fail` 已非空时点火,与 `_fail` 为空矛盾。
#   故 `_fail` 为空 ⟺ 「没有正式断言失败」;此时名单不全就只可能是"有函数没跑到尾"。
const CHECK_NAMES := [
	"_check", "_check_argv_contract", "_check_teardown_funnel",
	"_check_team_startup_contract", "_check_team_spawn_guard",
	"_check_worker_pid_tracking", "_check_join_refusal_guards", "_check_reclaim_ladder",
	"_check_rejoin_spawn_wiring",
]
var _done: Array[String] = []

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://server/lobby/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		_finish()
		return
	# - 先编译一次目标脚本再做文本断言。本冒烟是纯文本扫描(`-s` 下 grep 源码),它不会
	#   编译被扫的文件 —— 于是"文本全对但文件压根编译不过"这件事它能直接放过去。
	#   注意事项：把 `_teardown_room` 的参数从 `kill: bool` 改成 `mode: int` 时遗漏修改了体内一处
	#   `kill` 引用 -> GDScript 编译失败,而本冒烟照样报 OK(另两条验证也没覆到:主菜单场景
	#   不加载 room_manager,`--worker` 分支也不碰 RoomManager)。`load()` 会真正编译它。
	#   注:`load()` 解析失败时不返回 null(给回的是那个坏掉的脚本对象),故判定条件用
	#   `reload()` 的错误码 —— 它会真的重解析并如实返回 OK / ERR_PARSE_ERROR(实测过两种写法)。
	var scr: GDScript = load("res://server/lobby/room_manager.gd")
	if scr == null or scr.reload() != OK:
		_fail = "room_manager.gd 编译失败(源码文本可能全对,但 GDScript 编不过)"
		_finish()
		return
	_check(src)
	_check_argv_contract()
	_check_teardown_funnel()
	_check_team_startup_contract()
	_check_team_spawn_guard()
	_check_worker_pid_tracking()
	_check_join_refusal_guards()
	_check_reclaim_ladder()
	_check_rejoin_spawn_wiring()
	_finish()


# 取「等于 line_text 的那一行 + 紧随其后、缩进更深的一块」(到下一个缩进 ≤ 它的非空行为止)。
# - 必须用保留缩进的视图(`ScanUtil.code_view`,它同样剥掉注释):`code_only` 会 strip_edges,
#   拿它切不出块 —— 而这里两条断言的价值恰恰在于"那个 if 后面真的有它声称做的事"。
# - 只返回第一处命中:本用途下每个 needle 都是唯一的(命中处不是唯一时,断言会红在
#   "块里没有 X"上,不会静默取错)。
func _block_of(code_view: String, line_text: String) -> String:
	var lines: PackedStringArray = code_view.split("\n")
	for i in range(lines.size()):
		# - 匹配用整行相等(strip 后),不用 `contains`:本仓的 `elif _team_mode:` 里就含
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


# ── 批次 2 新增:房间拆除统一集中处理 ──
# 「端口泄漏」这同一个失败模式本层补过三次(on_peer_left 空房分支 / royale_leave 空房分支 /
# ai_duel 摘房前的手动释放)。统一集中处理后「新加一条拆除路径」不可能漏 —— 因为没有第二条路可走。
# 断言形态刻意选「只能出现在这一处」而不是「数调用点个数」:个数会随实现漂,而这是契约本身。
func _check_teardown_funnel() -> void:
	# - 2026-09-14:账本与拆除统一集中处理搬进了 server/lobby_rooms.gd(LobbyRooms,见 M4c)。
	#   统一集中处理的判定条件跟着搬 —— 「端口归还与注册表删除只能出现在统一集中处理体内」这条纪律与它住哪个文件无关。
	var src := FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd")
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
			# - 模式列表必须包含当前的端口归还入口。2026-09-14 端口池搬进 WorkerLauncher 后,
			#   `_worker_ports.erase(port)` 改名成 `_launcher.release_now(port)` —— 若不把新名字
			#   加进来,这条门就对端口回收彻底扫描失效（未读取到源文件）(它只认旧字符串,而旧字符串已全仓不存在),
			#   会导致测试产生假阳性：新增绕过统一管理的释放路径仍能错误通过。符号重命名或迁移时需同步维护此处。
			# 注意事项：三张注册表各自配置独立判定条件，且 `*_rooms.erase(` 需排在 `rooms.erase(` 之前：
			#   避免通用子串优先命中导致错误定位提示不够精准。同时保留各特定表断言可确保定位清晰。
			# 注意事项：阶段 2-B(Task 4,2026-09-21)新增 `rejoin.drop_room(`:凭据表也是一张注册表,
			#   作废某房的凭据同样是"拆除动作"。加它之前,把 `drop_room` 挪到调用方(本仓对
			#   `teardown_room` 明令禁止的那件事)这条门完全看不见 —— 实测:挪进
			#   `_reclaim_finished_matches`(另一个文件)后本冒烟仍报 OK,而"同一件事两处实现"
			#   这条纪律就只剩注释在守。判定条件只认当前的调用形状(`rejoin.drop_port(`),
			#   改名/搬家时相同处理逻辑改这里(与上面 `_launcher.release_now` 那条同一条纪律)。
			# 注意事项：2026-09-21 同日改名:`drop_room(code)` -> `drop_port(worker_port)`(三张注册表
			#   的房号空间重叠,按 code 作废会误伤同号的另一间房)。-  这里是跟着改名,不是
			#   "为了让某处的调用过关而放宽" —— 放宽的方向(把不在统一集中处理里的调用也收进白名单)
			#   恰恰是这条门存在要拦的事,别往那边改。
			for pat in ["_release_port_later(", "launcher.release_now(", "royale_rooms.erase(", "team_rooms.erase(", "rooms.erase(", "rejoin.drop_port("]:
				if t.contains(pat):
					if not allowed.has(f["name"]):
						_fail = "lobby_rooms.%s 里出现 %s —— 拆除必须走 teardown_room 单一收口" % [f["name"], pat]
						return
	_done.append("_check_teardown_funnel")


# ── 批次 2 新增:role 协议必须是显式 role 集合(--roles)──
# 旧协议传「人数 + role 上界」两个整数:两者量纲不同、且都得从人数推导;而 role 由
# royale_join 的「最小空闲号」分配、有人退出后不重排 -> 编号会留空洞(房里 {1,3} 而成员 2 人),
# 推导必然出错 -> 持 3 号的真实客户端实例被当串线剔除断开(历史 B1)。故做反向断言:旧标识符一个都不许复活。
# 它防的是这套 命令行参数约定的历史故障模式 —— 大厅与 worker 两边只改一边(CLAUDE.md 明文要求同步改)。
func _check_argv_contract() -> void:
	# 参数解析端检查：单进程单端口下对局角色与队伍配置直接通过房间记录传递，
	# 独立单局启动时仍需支持 --roles 与 --team 命令行参数解析。
	var files := ["res://server/server_main.gd"]
	for f in files:
		var txt := FileAccess.get_file_as_string(f)
		if txt.is_empty():
			_fail = "无法读取 %s" % f
			return
		for line in txt.split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue   # 注释里提旧协议名是有意的(留档为什么换掉),不算违规
			# - 批次 3(3v3)新增 `--team-size` / `_team_bound`:同一类故障模式(把"队数/人数"
			#   当参数量纲,再从 role 号推队号)。队号与 role 集合同序等长传过去才是精确的那条。
			for bad in ["--players", "--max-role", "_role_bound", "_expected_players",
					"--team-size", "_team_bound"]:
				if t.contains(bad):
					_fail = "%s 的代码里仍有旧 argv 协议标识符 %s(应已换成 --roles 集合)" % [f, bad]
					return
	# 正向断言：代码实现中必须包含 --roles 参数处理逻辑（基于去除注释后的代码视图判定）。
	for f in files:
		var code2 := ScanUtil.code_only(ScanUtil.read(f))
		if not code2.contains('"--roles"'):
			_fail = "%s 未接 --roles(集合协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % f
			return
		for tok in ['"--team"', '"--teams"']:
			if not code2.contains(tok):
				_fail = "%s 未接 %s(3v3 启动协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % [f, tok]
				return
	_done.append("_check_argv_contract")

# ── 批次 3(3v3)新增:启动参数约定里"本册能做到的那一半" ──
# - 边界照实写明:真实网络链路(6 个真实客户端实例连上 `--team` worker -> 满员开局 -> 有人掉线 -> 
#   宽限到期 -> 其余人继续打)归 B 册的真实网络链路探针 —— 它需要大厅侧的 team 房间入口,
#   而那个入口本册不做。本函数约束的是分派本身:
#   ① `--team` / `--teams` 两边逐字对应(在 `_check_argv_contract` 里);
#   ② 宽限期超时严格按模式区分处置策略，避免将 3v3 误判为 1v1 的终止对局逻辑；
#   ③ `_expire_graces` 末尾那条"全员走光才退出"也含 3v3(漏了 = 走光后 worker 永驻占端口);
#   ④ 3v3 的分级超时机制不降级(与 --royale 方向相反)、全员就绪判定条件是"满员才开"。
func _check_team_startup_contract() -> void:
	# 单进程架构下对局逻辑由 server/match_session.gd 承载。
	var src := ScanUtil.read("res://server/match_session.gd")
	if src.is_empty():
		_fail = "无法读取 match_session.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 到点的分派必须走纯函数(答案在 grace_window_smoke ⑦ 里按模式逐个严格约束)。
	var expire := ScanUtil.func_body(code, "_expire_graces")
	if expire.is_empty():
		_fail = "找不到 _expire_graces 的函数体"
		return
	# 注意事项：判定条件必须落到"比较了"上,不能只查函数名出现(Task 9 评审 M1):
	#   旧写法是 `contains("GraceWindow.expire_action(")` —— 而把分派退回不可测写法、同时把那行
	#   当无引用冗余代码留下的变异(`var _a := GraceWindow.expire_action(...)` + 原样的 `if _royale: … else: quit`)
	#   两条都满足  ->  全部断言通过,而 3v3 已经坏了(宽限到期的那个人会带着整局退进程)。
	#   故要求整条比较式接口已声明且生效;另加一条反向:分派里不许再出现手写的 `if _royale:` 优先级分支。
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
	# - 与上面那条分派是两条判定条件(一条管"某个人到点怎么办"、一条管"人全走光了 worker 退不退"),
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
	# ④ 分级超时机制：不降级（策略方向与 --royale 相反）。
	#   判定条件仅截取该特定分支代码块（直到下一个 `elif` 出现）—— 扫描整段 `_process` 会受到其他分支
	#   退出逻辑与大乱斗模式的干扰（实测验证：固定行数范围会导致正确实现误判失败，
	#   过窄则无法覆盖块末尾的 quit 退出调用）。
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
	# - 判定条件从 `quit(0)` 改成 `_finish()`(2026-10-07,单进程单端口):对局收场现在唯一的
	#   出口是 `MatchSession._finish()`(它发 `finished` 让 RoomManager 作废凭据并拆房)。
	#   原先钉 `quit(0)` 是因为旧形态下 worker 必须退进程才能释放它独占的端口;
	#   单进程之后退进程会把房主自己的大厅连同隧道一起带走 —— "退出"这件事整个换了形状。
	if not ladder.contains("_finish()"):
		_fail = "3v3 报到超时梯没有 _finish()(收不齐就该收场;退进程会把大厅一起带走)"
		return
	if ladder.contains("_begin_match("):
		_fail = "★ 3v3 超时梯调了 _begin_match(降级开局)—— 与用户裁定「满 6 人才开」相反"
		return
	# ⑤ 全员就绪判定条件 = 满员,且分母是驱动摆位的那个集合(Task 9 评审 M5)。
	# - 判定条件落在 3v3 那一支的整块上(用保留缩进的视图切块),而不是"文件里某处出现过某串":
	#   后者既能被别处的同形代码喂饱,也照不出"分母用错集合"这一档。
	# - 为什么分母必须是 `_team_of_role.size()`:`_team_of_role` 按 role 去重,`_role_set` 是
	#   `--roles` 的逐 token 列表 —— `--roles 1,1,2,2,3,3 --teams 1,1,1,2,2,2` 长度校验能过,
	#   而队伍表只有 3 键  ->  拿 6 当满员界永远到不了  ->  阻塞等待 30s 超时退出(静默,零报错)。
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
	# ⑥ role 越界防御性校验必须同时管 3v3:`_team_of_role` 只覆盖 --roles 里的 role,集合外的 role
	#    混进来会让 `_claims.size()` 提前够数开局,而 TeamHost 那侧 `spawns[role]` 缺键。
	if not code.contains("((_royale or _team_mode) and not _role_set.has(role))"):
		_fail = "_on_role_claimed 的越界守卫只认 _royale(集合外的 role 能混进 3v3 局里开局)"
		return
	# ⑦ 模式开关互斥(Task 9 评审 M4):`--royale` 与 `--team` 同时为真时必须当场拒绝启动。
	#    此前三处判定条件的优先级并不一致(`_ready` 里 royale 先、`_on_role_claimed`/`_begin_match`
	#    里 team 先):手敲两个开关时 `_team_of_role` 永不填充,而 `_begin_match` 却按 team 分支
	#    去建 TeamHost -> 空 teams -> `spawns[role]` 全员缺键。生产不可达(生成端是两个独立函数),
	#    但它与"绝不静默"的纪律不一致。-  判定条件取那只防御性校验的整块(到下一个同缩进行为止):
	#    只查 `if _royale and _team_mode:` 这行文本的话,一个被 `pass` 掉的空块照样全部断言通过 ——
	#    那正是 M1 那类"看着像防御性校验、其实守不住"的形状。
	# - 2026-10-07:这条只钉命令行那半边(手工起单局独立服务端)。大厅那条路(房记录)
	#   结构上不可能混模式:`MatchSession.validate` 收的是单个 `p_mode` 枚举,
	#   不存在"两个都真"这种输入 —— 那比文本防御性校验强,不需要再钉一次。
	var sm := ScanUtil.read("res://server/server_main.gd")
	if sm.is_empty():
		_fail = "无法读取 server_main.gd"
		return
	var excl := _block_of(ScanUtil.code_view(sm), "if want_royale and want_team:")
	if excl.is_empty():
		_fail = "server_main 未拒绝 --royale 与 --team 同时为真(模式开关互斥的守卫被删?)"
		return
	if not excl.contains("quit(1)"):
		_fail = "--royale/--team 互斥守卫里没有 quit(1)(空块 = 守卫守不住,静默开成错的那一半)"
		return
	# ⑧ 单端口下的名册闸(2026-10-07):大厅与对局共用同一个 peer,任何一个连上来的 peer
	#    都能发 `claim_role` —— 原先靠"端口独占 + 进程独占"隐式隔离,现在没有了。
	#    故 `_on_role_claimed` 必须把"不在本局名册里的 caller"拒掉(与 role 越界同款)。
	#    - 少了它:隔壁房的玩家、或端口复用期迟到的旧客户端,能直接顶掉本局的 role。
	var claimed := ScanUtil.func_body(code, "_on_role_claimed")
	if claimed.is_empty():
		_fail = "找不到 _on_role_claimed 的函数体"
		return
	if not claimed.contains("roster"):
		_fail = "★ _on_role_claimed 没有名册闸(单端口下任何 peer 都能 claim —— 串线顶掉本局 role)"
		return
	_done.append("_check_team_startup_contract")


# ── 批次 3(3v3)新增:生成端的 fail-fast(队号取值)──
# - 为什么这条必须真调一次、而不是再写一条源码文本断言:文本只能证明"那几行字在"。
#   而这里的失败后果是静默的:解析端对越界队号静默丢弃 -> 子进程因长度不等开机即 quit(1),
#   而生成端返回 `pid > 0`  ->  大厅判定"启动成功"、对局永不开始、大厅侧零报错
#   (Task 9 评审 M2;B 册大厅要从房间数据拼 teams,最容易踩的就是这一脚)。
# - 只喂非法输入:合法输入会真的启动一个子进程(本冒烟不该做那件事)。
#   控制组的判别点 = 长度相等而队号越界 —— 只校验长度的旧实现在这一档会放行。
func _check_team_spawn_guard() -> void:
	# - 2026-10-07:判定条件从"生成端 `spawn_team_worker` 拒绝越界队号"改成"共用判定条件
	#   `MatchSession.validate` 拒绝它"。两项关键逻辑守的是同一个失败模式(队号越界会让子进程/
	#   会话带着错的队表开局),而判定条件现在只有一份 —— 命令行那条路与房记录那条路共用它。
	# - 真的调一次(不是文本断言):本仓的纪律是"文本只能证明那几行字在"。`MatchSession`
	#   在 `-s` 下可以 load 并调静态方法(实测),故这条保住了行为面。
	# - 只喂非法输入:合法输入会去建会话(本冒烟不该做那件事)。
	var S: GDScript = load("res://server/match_session.gd")
	if S == null:
		_fail = "无法加载 match_session.gd(共用判据的宿主)"
		return
	# 控制组:长度相等、队号越界 —— 只校验长度的旧实现在这一档会放行。
	var why_bad: String = S.validate(S.Mode.TEAM, [1, 2, 3], {1: 1, 2: 1, 3: 3})
	if why_bad.is_empty():
		_fail = "validate 放行了越界队号(长度相等、队号 3 越界 → 会话带着错的队表开局、零报错)"
		return
	# 长度不等也必须拒(roles 与 teams 同序配对的前提)
	if str(S.validate(S.Mode.TEAM, [1, 2, 3], {1: 1, 2: 1})).is_empty():
		_fail = "validate 放行了 roles/teams 长度不等"
		return
	# 大乱斗缺参战集合也必须拒(不能从人数推导 —— 历史 B1)
	if str(S.validate(S.Mode.ROYALE, [], {})).is_empty():
		_fail = "validate 放行了大乱斗的空 role 集合(从人数推导必然出错,历史 B1)"
		return
	# 反向:合法输入必须放行(否则每个模式都开不了局 —— 恒拒绝的防御性校验和没有防御性校验一样坏)
	if not str(S.validate(S.Mode.TEAM, [1, 2], {1: 1, 2: 2})).is_empty():
		_fail = "validate 拒绝了合法输入(3v3:roles [1,2] / teams {1:1,2:2})"
		return
	if not str(S.validate(S.Mode.DUEL, [1, 2], {})).is_empty():
		_fail = "validate 拒绝了合法输入(1v1)"
		return
	_done.append("_check_team_spawn_guard")


func _check(src: String) -> void:
	if not src.contains("const SWEEP_INTERVAL := 600.0"):
		_fail = "缺 SWEEP_INTERVAL=600(10min)常量"; return
	if not src.contains("const MAX_ROOM_AGE := 7200.0"):
		_fail = "缺 MAX_ROOM_AGE=7200(2h)常量"; return
	# created_at 的赋值点随 create_room/royale_create 搬进了 lobby_rooms.gd
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains(
			"created_at = Time.get_unix_time_from_system()"):
		_fail = "create_room/royale_create 未记录 created_at(超龄判据的输入)"; return
	if not src.contains("func _process"):
		_fail = "缺定时 _process"; return
	if not src.contains("func _sweep_stale_rooms"):
		_fail = "缺 _sweep_stale_rooms"; return
	# - 2026-10-07(单进程单端口):这组断言原先约束的是"杀 worker 的实现 + 有人调它" ——
	# - 单进程单端口架构：超龄清理必须能真实回收正在运行的对局会话节点，
	#   而非仅仅抹除房间注册表记录（防止对局后台空转占用内存与连接）。
	#   因此校验信号的完整触发与接收链路（inproc_room_teardown）。
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains("inproc_room_teardown.emit("):
		_fail = "lobby_rooms.teardown_room 未通知托管方结束对局(超龄清扫只抹记录 -> 会话空转)"; return
	if not FileAccess.get_file_as_string("res://server/lobby/room_manager.gd").contains("inproc_room_teardown.connect("):
		_fail = "RoomManager 未接 inproc_room_teardown(通知没人收 -> 那一局不会被收掉)"; return
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
	# 断言只在谓词那两行(宽限声明 + 比较)上做,不查整个 body:body 里别的代码行(清理日志)
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
	# - 2026-09-28 改认上界常量:原先这里认 `RoyaleHost.MATCH_TIME`,而它只是默认值 ——
	#   房主可在建房页把一局配到 15 分钟(装载钳位到 30),于是"等了近 2h 才开局 + 配了长时长"
	#   的房会在对局中途被判超龄、连 worker 一起终止(缺口最大约 1500s)。
	if not pred.contains("ROYALE_MATCH_TIME_CEILING"):
		_fail = "大乱斗在局宽限缺 ROYALE_MATCH_TIME_CEILING(宽限被删/被改回默认时长?)"; return
	if pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限又用回了 RoyaleHost.MATCH_TIME(它只是默认值,不是上界)"; return
	# ── 2026-09-28:上界常量本身 + 它的前提。四条缺一不可 ──
	# - 判定条件取片段而不是整行字面量(2026-09-28 评审 Finding 4):原先要求整行
	#   `const ROYALE_MATCH_TIME_CEILING := 1800.0`,对正常格式调整响亮地测试误报。
	#   - 判定条件精确限定在常量声明行，避免全文件匹配可能被其他相同数值变量（如 TEAM_MATCH_ESTIMATE）满足而失去校验有效性。
	#   声明行必须包含数值 1800，防止该上限被异常改小。
	var ceil_line := ""
	for line in src.split("\n"):
		if line.contains("const ROYALE_MATCH_TIME_CEILING"):
			ceil_line = line
			break
	if ceil_line.is_empty() or not ceil_line.contains("1800"):
		_fail = "缺 ROYALE_MATCH_TIME_CEILING=1800(或值被改小了 —— 它必须盖得住装载钳位的上界)"; return
	# 注意事项：前提钉在它住的地方:上界 1800 = 30 分钟 × 60,而 30 来自 `Settings.royale_match_min`
	#   的装载钳位。钳位一放宽(比如到 60 分钟),上面两条保持测试通过,而缺口复现 ——
	#   只有这一条会红。改钳位时回来一起改。
	var settings_src := FileAccess.get_file_as_string("res://core/config/settings.gd")
	# - Finding 5(2026-09-28):读不到时必须报"读不到" —— 否则下面那条会宣称钳位变了,
	#   把诊断引向完全错误的方向(本文件对 room_manager.gd 早有相同处理逻辑判定条件,这里当时漏了)。
	if settings_src.is_empty():
		_fail = "无法读取 settings.gd(读不到源码 ≠ 钳位变了)"; return
	if not settings_src.contains("royale_match_min = clampf(") or not settings_src.contains("1.0, 30.0"):
		_fail = ("★ Settings.royale_match_min 的装载钳位变了 —— ROYALE_MATCH_TIME_CEILING "
				+ "(=30min×60=1800)不再盖得住它,大乱斗在局宽限的缺口复现。改钳位要一起改上界常量。"); return
	# ── 注意： 2026-09-28 评审 Finding 1:上界的链有两环,上面刚约束的是环一,下面是环二 ──
	#   链的形状:`settings.gd` 把 `royale_match_min` 钳进 [1,30] 分钟(环一) -> `mp_lobby.gd`
	#   把它换算成秒下发(环二,`* 60.0`)。只钉环一时,把 `* 60.0` 改成 `* 120.0`(或干脆
	#   传分钟) ->  实际下发的 `match_time` 翻倍/变形,而上面所有断言照样全部断言通过 —— 上界静默失效,
	#   正是"前提断言"要防的那个形状,只是下移了一环。
	# - 判定条件相同处理逻辑取片段(Finding 4):定位含 `"match_time"` 且带换算的那一行,要求它同时含
	#   `Settings.royale_match_min` 与 `* 60.0` —— 不钉整行(容忍空白/换行/取值写法)。
	#   - 2026-10-03(统一大厅):mp_lobby 里 `"match_time"` 出现两次 —— 一次是建房弹层的
	#     行键(`_form_rows["match_time"]`,不含换算),一次才是载荷里那一行。旧实现取第一处
	#      ->  会挑中行键、把这一环判成断裂(实测)。故这里改取**同时含 `Settings.royale_match_min`
	#     的那一行**;一处都取不到才算这一环真的没了。
	var lobby_src := FileAccess.get_file_as_string("res://scenes/mp_lobby.gd")
	if lobby_src.is_empty():
		_fail = "无法读取 scenes/mp_lobby.gd(读不到源码 ≠ 上界链第二环变了)"; return
	var has_key := false
	var conv := ""
	for line in lobby_src.split("\n"):
		if not line.contains("\"match_time\""):
			continue
		has_key = true
		if line.contains("Settings.royale_match_min"):
			conv = line
			break
	if not has_key:
		_fail = "scenes/mp_lobby.gd 里找不到 \"match_time\" 那一行(上界链第二环消失/改名?)"; return
	if conv.is_empty():
		_fail = ("★ 秒换算这一环断了 —— ROYALE_MATCH_TIME_CEILING 的链有**三环**,这是第二环:"
				+ "mp_lobby.gd 的 \"match_time\" 必须仍由 Settings.royale_match_min × 60.0 得来,"
				+ "否则上界静默失效(改换算要一起改上界常量)"); return
	if not conv.contains("* 60.0"):
		_fail = ("★ 秒换算这一环断了 —— ROYALE_MATCH_TIME_CEILING 的链有**三环**,这是第二环:"
				+ "mp_lobby.gd 的 \"match_time\" 必须仍由 Settings.royale_match_min × 60.0 得来,"
				+ "否则上界静默失效(改换算要一起改上界常量)"); return
	# ── 注意： 2026-09-28 终审(整支) -> 链其实是三环,这里约束的是第三环(写入端) ──
	#   环一 = `settings.gd` 的装载钳位 [1,30](上面负责校验);环二 = 秒换算(上面负责校验);
	#   环三 = `scenes/mp_lobby.gd` 那根滑块的 `max_value`(`tslider.max_value = 15.0`)
	#   —— -  它才是真正产生下发值的那一环:`value_changed` 把滑块值不钳位地写进
	#   `Settings.royale_match_min`(下面的 `Settings.royale_match_min = v`),而下发的
	#   `match_time` 读的是内存里那个值 —— 装载钳位 [1,30] 只在下一次装载时才生效。
	#    ->  把 `max_value` 放宽(比如到 60)之后,上面所有断言(含环一环二)照样全部断言通过,
	#   而实际下发的 `match_time` 已经能到 3600  ->  1800s 的上界静默失效。
	#   - 另一条同源的口子(更远一环、本文件不钉):server/royale_host.gd 的 `_cfg_match_time`
	#   把客户端给的 `match_time` 原样收下,worker 侧也不钳位  ->  上界依赖客户端行为,
	#   不是无条件成立的(登记见 CLAUDE.md)。
	#   - 判定条件取数值比较而不是子串(与上面那两条片段判定条件略有不同,理由在下面):
	#   `contains("15")` 挡不住 `15.0 -> 150.0`(它含子串 "15"),而那正是本条要抓的"放宽"。
	#   故把 `max_value = <数字>` 抽出来比数值;容忍空白/整数写法(与同族的"宁可响亮测试误报"同向)。
	# ── 注意： 2026-10-03(T2 整屏搬 `.tscn`):这一环的家搬了,读法跟着搬 ──
	#   搬之前:`scenes/mp_lobby.gd` 的 `_build_match_time_row()` 里那句 `max_value = 15.0`。
	#   搬之后:整个「创建弹层」是 `scenes/mp_lobby.tscn` 的静态基础结构框架,而
	#   `_build_ui()` 只灌 `value = Settings.royale_match_min` 并接 `value_changed`,
	#   不再碰上限  ->  上限的唯一来源就是基础结构框架里 `MatchTimeSlider` 节点的 `max_value`。
	#   - 为什么不能就此把这一环删掉:`_set_create_visible`/`value_changed` 那条路没变 ——
	#     放宽上限之后环一环二保持测试通过,而下发的 `match_time` 仍能到 3600(静默失效)。
	#   - 所以本条改读 `.tscn`,并且:
	#     ① 读不到基础结构框架  ->  响亮报"读不到"(不伪装成"第三环变了");
	#     ② `MatchTimeSlider` 必须恰一个且仍是 `HSlider`(读错一个同名节点会得到别的上限,
	#        而数值断言看起来保持测试通过 —— 与 `_unique()` 同一条纪律);
	#     ③ 仍比数值;
	#     ④ 另加一条反向断言:`.gd` 里不许再出现 `_time_slider.max_value`
	#        (否则上限回到两个家:基础结构框架那份被读、代码那份生效 —— 判定条件会被架空)。
	var tscn_src := FileAccess.get_file_as_string("res://scenes/mp_lobby.tscn")
	if tscn_src.is_empty():
		_fail = "无法读取 scenes/mp_lobby.tscn(读不到骨架 ≠ 上界链第三环变了)"; return
	var mt_body := ""
	var mt_nodes := 0
	var tscn_lines := tscn_src.split("\n")
	for i in range(tscn_lines.size()):
		if not tscn_lines[i].begins_with("[node name=\"MatchTimeSlider\""):
			continue
		mt_nodes += 1
		if not tscn_lines[i].contains("type=\"HSlider\""):
			_fail = "scenes/mp_lobby.tscn 的 MatchTimeSlider 不再是 HSlider(类型变了 ⇒ 上限读法失效)"; return
		for j in range(i + 1, tscn_lines.size()):
			if tscn_lines[j].begins_with("["):
				break
			mt_body += tscn_lines[j] + "\n"
	if mt_nodes != 1:
		_fail = ("scenes/mp_lobby.tscn 里 `MatchTimeSlider` 节点有 %d 个(期望恰 1 个)"
				% mt_nodes + " —— 上界链第三环的读取点不唯一"); return
	if mt_body.is_empty():
		_fail = "scenes/mp_lobby.tscn 的 MatchTimeSlider 节点体是空的(上限读不到 ≠ 第三环变了)"; return
	var cap_re := RegEx.new()
	if cap_re.compile("max_value\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)") != OK:
		_fail = "正则编译失败(本函数自身的 bug,不是被扫文件的问题)"; return
	var cap_m := cap_re.search(mt_body)
	if cap_m == null:
		_fail = "「一局限时」滑块(MatchTimeSlider)里找不到 `max_value = <数字>`(上界链第三环消失?)"; return
	if not is_equal_approx(float(cap_m.get_string(1)), 15.0):
		_fail = ("★ 「一局限时」滑块的上限被改成了 %s —— ROYALE_MATCH_TIME_CEILING 的链有**三环**,"
				% cap_m.get_string(1)
				+ "这是第三环、也是**真正产生下发值**的那一环(`value_changed` 不钳位地把它写进 "
				+ "Settings.royale_match_min,而下发的 match_time 读的是内存里那个值;装载钳位 "
				+ "[1,30] 只在下一次装载才生效)⇒ 1800s 的上界静默失效。放宽上限要一起改上界常量。"
				+ "★ 值现在住在 scenes/mp_lobby.tscn 的 MatchTimeSlider.max_value(见本文件头);"
				+ "改版式请去编辑器里改那个节点。"); return
	if ScanUtil.code_only(lobby_src).contains("_time_slider.max_value"):
		_fail = ("scenes/mp_lobby.gd 里又出现了 `_time_slider.max_value` —— 上限回到**两个家**:"
				+ "本条读的是骨架那份,而真正生效的是代码这份 ⇒ 判据被架空(第三环必须以 .tscn 为唯一来源)"); return
	if not pred.contains("rr.in_match"):
		_fail = "大乱斗在局宽限缺 rr.in_match 门控"; return
	if not pred.contains("SWEEP_INTERVAL"):
		_fail = "大乱斗在局宽限未含 SWEEP_INTERVAL(界被改回只加一局,挡不住下一次 tick?)"; return
	# 反过来:1v1 的超龄判断必须保持裸 MAX_ROOM_AGE,宽限不得泄漏进 1v1 分支
	if not code.contains("room.created_at > MAX_ROOM_AGE:"):
		_fail = "1v1 超龄判断不再是裸 MAX_ROOM_AGE(宽限泄漏?)"; return
	# ── B 册 Task 5(2026-09-19):3v3 的收集块 + 宽限谓词也要各有一针 ──
	# - 此前这里与 royale 分支不对称:royale 那条三截谓词断言在,3v3 一条都没有。缺它时
	#   「保留 `var stale_team` 声明、掏空 `for tcode in lobby.team_rooms:` 循环」或「把
	#   tr.in_match / TEAM_MATCH_ESTIMATE 从宽限里摘掉」都能编译通过、上面四条(三张表名、
	#   提前 return 的并列判定条件、拆除列表)全部断言通过 —— 而那正是「防御性校验在、3v3 永不被清」那一档
	#   (-worker 端口永久泄漏)。收集块与谓词行各钉一次:只钉删除列表那行不够,它由
	#   stale_team 变量喂饱,变量恒空也照过。
	if not body.contains("for tcode in lobby.team_rooms"):
		_fail = "_sweep_stale_rooms 没有收集 3v3 超龄房的循环(team_rooms 永不被扫 → 端口永久泄漏)"; return
	# 注意事项：B 册 Task 7(评审留的同粒度洞):上面那条只认 `for …` 的头行 —— 保留头行、
	#   只把循环体掏空(删掉 `stale_team.append(tr)`)时,上面那条 + 既有的 `contains("stale_team")`
	#   + 三表并列判定条件 + 拆除列表四条全部断言通过,而 `stale_team` 恒空  ->  3v3 房永不被清(端口泄漏)。
	#   royale 那一侧此前同样没钉 append(同一个洞,不是本任务引入的退化)—— 一并补上:
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
	# 批次 2 改法:_sweep 不再直接终止 worker 进程 / 删房,改走拆除统一集中处理(带 KILL 形态)。
	# 「终止 worker 进程 + 删房 + 回收端口」这件事本身仍被 _check_teardown_funnel 严格校验(那些动作只允许
	# 出现在 _teardown_room 体内);这里只认新入口。
	# - 别改回「直接调 _kill_worker」:那样端口回收会绕过统一集中处理,正是本层补过三次的那个泄漏。
	if not body.contains("teardown_room(") or not body.contains("TEARDOWN_KILL"):
		_fail = "_sweep_stale_rooms 未走拆除收口(应调 _lobby.teardown_room(..., LobbyRooms.TEARDOWN_KILL, ...))"; return
	# 三张注册表都要被拆:rooms(1v1) / royale_rooms / team_rooms 并存,漏一张 = 那张的端口永久泄漏
	if not body.contains("stale + stale_royale"):
		_fail = "_sweep_stale_rooms 未把多张注册表的超龄房一并拆除"; return
	# 注意事项：批次 3(Task 4):3v3 那一支的两条判定条件 —— 只查「拆除列表」是不够的,因为
	#   末尾那条「全空则提前 return」的并列判定依据为独立的第二条退出路径:
	#     `if stale.is_empty() and stale_royale.is_empty(): return`
	#   漏掉 stale_team 时,只有 3v3 房超龄的那次 tick 会当场 return、永远不清扫 -> 
	#   端口永久泄漏;而拆除列表那行照旧在、房间收集块照旧在  ->  只查列表的断言全部断言通过。
	#   这正是本层反复补的同一个失败模式(见 lobby_rooms.teardown_room 的注释)的第四种形态,
	#   且症状是静默的。故这里逐个明确提示三张表、并单独断言校验那条提前返回。
	if not body.contains("stale_team"):
		_fail = "_sweep_stale_rooms 完全没扫 3v3 房(team_rooms 的超龄房 → worker 端口永久泄漏)"; return
	if not body.contains("stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty()"):
		_fail = "_sweep_stale_rooms 的「无超龄房则提前 return」守卫漏了某张注册表(只有那张表的房超龄时永不清扫 → 静默端口泄漏)"; return
	if not body.contains("stale + stale_royale + stale_team"):
		_fail = "_sweep_stale_rooms 的拆除列表未含全部三张注册表(未被扫到的那张 → 端口永久泄漏)"; return
	# 汇总 print 必须把 3v3 那一档的数据报出来(照实登记的估值界;漏了只是日志失真,
	# 但它是上面那些界的唯一读数)。
	# - 2026-10-02 降精度:判定条件钉数据(实参 `stale_team.size()`),不钉文案里的字面量 "3v3"
	#   —— 那句 print 里的 "3v3" 只是标签,把标签留着、把那个实参换成别的变量的变异它拦不住;
	#   反之换个写法的文案不该红。要拦的变异:不再把 3v3 超龄数报进汇总行(界变了而日志读不出)。
	#   - 那条 print 是跨行的(格式串一行、实参表在后续几行),故连同实参一起收集到 `]` 收束。
	var summary := ""
	for i in range(code_lines.size()):
		if code_lines[i].begins_with('print("[lobby] 清理'):
			var parts: Array[String] = []
			for j in range(i, code_lines.size()):
				parts.append(code_lines[j])
				if code_lines[j].strip_edges().ends_with("]"):
					break
			summary = "\n".join(parts)
			break
	if summary.is_empty() or not summary.contains("stale_team.size()"):
		_fail = "_sweep_stale_rooms 的汇总 print 未报 3v3 那一档的数据(stale_team.size())—— 界有变化而日志读不出来"; return
	# - 本函数跑到尾的凭证(判定条件在 _finish;理由见文件头那段)。下面的每个 _check_* 相同处理逻辑。
	_done.append("_check")

# ── 校验局号 match_id 的严格单调递增性 ──
# 单进程单端口架构下，局号 match_id 作为对局生命周期与重连凭据的唯一标识符。
# 局号必须从 1 开始单调递增，且不得重置或复用。
func _check_worker_pid_tracking() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby/room_manager.gd"))
	if not code.contains("var _next_match_id := 1"):
		_fail = "缺 _next_match_id 初值 1(局号分配器)"
		return
	var om := ScanUtil.func_body(code, "_open_match")
	if om.is_empty():
		_fail = "找不到 _open_match 的函数体"
		return
	var at_use := om.find("_next_match_id")
	var at_inc := om.find("_next_match_id += 1")
	if at_use < 0 or at_inc < 0:
		_fail = "★ _open_match 没有用 _next_match_id 当会话局号并把它 +1(局号会撞车)"
		return
	# 先分配当前局号再自增，确保局号从 1 开始且每局独立。
	if at_inc < at_use:
		_fail = "★ _open_match 先自增后取号(局号顺序错位;两局可能撞同一个号)"
		return
	# 校验局号计数器不得被重置为 0 或 1。
	for line in code.split("\n"):
		if line.contains("_next_match_id = 0") or line.contains("_next_match_id = 1"):
			_fail = "★ room_manager 把 _next_match_id 拨回去了(%s)—— 局号复用会让旧凭据被判成「还在」" % line.strip_edges()
			return
	_done.append("_check_worker_pid_tracking")


# ── 2026-09-21(「看得见进不去」批)新增:三条 join 的拒绝防御性校验与文案 ──
# - 为什么是源码级:文案是发给玩家看的字符串,而探针里没有对端 ——
#   `NetBus.reply` 在 `is_peer_live(caller)` 为假时静默跳过(见 NetBus.reply 的注释),
#   所以那句话在探针里根本观测不到。行为面(调用方没被 append 进 players)由
#   `tests/probe/lobby_visibility_probe.tscn` 阶段 1/②/③ 断言,这里断言的是那句话本身。
# - 为什么文案值得一条断言:1v1 原先对"对局进行中"说的是「房间已满」—— 那是假话,而且会命中
#   大厅页 `_on_server_message` 的自动刷新分支(那条只认旧文案)。改文案 = 静默改行为。
# - 另钉一条反向:三条防御性校验必须用"这一局在进行中"判(started / in_match),不许退化成
#   "房满 / 人数"之类的替代判定条件 —— 后者在"房里只剩 1 人"时放行,正是本批要堵的那档。
# 注意事项：2026-09-21(重连返回对局入口批)补一条前提(下方判定条件与文案一个字节都没改):
#   `tests/probe/lobby_visibility_probe` 阶段 1②③ 断的是「对局中的房对无凭据者一律拒绝」——
#   "重连返回对局"那条路刻意不经过这三条防御性校验:它走 `rejoin_request`(大厅侧 `on_rejoin_request`,
#   按凭据表放行),客户端侧则在列表里把持凭据的那一行画成可点(阶段 8)。
#   故不许在这三个 handler 里插"有凭据就放行"的分支 —— 那等于把"重连返回对局"混进"入房"语义,
#   而本函数这条防御性校验当场变成一句空话且红不起来(它判的是那条 `if` 还在,前面加一条
#   前置分支它照样绿)。
func _check_join_refusal_guards() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby/lobby_rooms.gd"))
	var cases := [
		["join_room", "if room.started:"],
		["royale_join", "if rr.in_match:"],
		["team_join", "if tr.in_match:"],
	]
	for c in cases:
		var body := ScanUtil.func_body(code, str(c[0]))
		if body.is_empty():
			_fail = "找不到 %s 的函数体" % c[0]
			return
		if not body.contains(c[1]):
			_fail = "★ %s 缺少「对局中即拒绝」的守卫(%s)—— 对局中的房会被第三人加入" % [c[0], c[1]]
			return
		if not body.contains('"该房间的对局已进行中,无法加入"'):
			_fail = "%s 的拒绝文案不是三模式统一的那一句" % c[0]
			return
	_done.append("_check_join_refusal_guards")


# ── 2026-09-21 新增:对局中房间的资源回收阶梯机制接线 ──
# - 为什么"接线"要单独钉:行为探针(`tests/probe/lobby_visibility_probe.tscn` 阶段 4)是手工调
#   `_reclaim_finished_matches()` 的 —— 把 `_process` 里那次调用删掉,行为探针照样全部断言通过,
#   而生产里房永远不会被回收(端口与列表位白占)。本仓对这类"双向逻辑"的既有先例:
#   `team_room_smoke` ⑨①(接线面)对 `hud_declarative_probe` ③(行为面)—— 缺一不可。
# - 另一条:回收不能绕道直接删注册表。既有的 `_check_teardown_funnel` 只扫
#   `server/lobby_rooms.gd`,扫不到写在 room_manager 里的绕道 —— 那正是本函数存在的理由。
func _check_reclaim_ladder() -> void:
	if _fail != "":
		return
	var src := ScanUtil.read("res://server/lobby/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		return
	var code := ScanUtil.code_only(src)
	if not code.contains("const MATCH_SWEEP_INTERVAL := 30.0"):
		_fail = "缺 MATCH_SWEEP_INTERVAL=30 常量(回收梯的周期)"
		return
	var proc := ScanUtil.func_body(code, "_process")
	if proc.is_empty():
		_fail = "找不到 RoomManager._process"
		return
	if not proc.contains("_reclaim_finished_matches()"):
		_fail = "★ _process 没调 _reclaim_finished_matches —— 对局结束后房与端口永不被回收"
		return
	var fn := ScanUtil.func_body(code, "_reclaim_finished_matches")
	if fn.is_empty():
		_fail = "找不到 _reclaim_finished_matches"
		return
	if not fn.contains("teardown_room("):
		_fail = "★ 回收梯没走拆除单一收口(端口归还/注册表删除只许出现在 teardown_room)"
		return
	# 三张注册表都要被扫:漏一张 = 那张的房永不被回收(静默端口泄漏,本层补过五次的那个模式)
	for pat in ["for code in lobby.rooms", "for rcode in lobby.royale_rooms", "for tcode in lobby.team_rooms"]:
		if not fn.contains(pat):
			_fail = "★ 回收梯漏扫了一张注册表(%s)→ 那张的房与端口永不被回收" % pat
			return
	# - 判定条件从 `_match_over(port, pid)` 改成"会话节点还在不在"(2026-10-07,单进程单端口):
	#   对局现在是大厅进程里的一个 `MatchSession` 节点,没有"另一个进程"可查了。
	#   这条钉的仍是同一件事 —— "这一局结束了吗"必须由精确的那一件事回答,而不是按
	# 单进程单端口架构下，对局结束判定直接依据 MatchSession 会话节点的存活状态（_session 与 is_instance_valid）。
	if not fn.contains("_session"):
		_fail = "★ 回收梯没有读**会话节点**(对局结束的判据)—— 单进程之后没有 worker 进程可查"
		return
	if not fn.contains("is_instance_valid(_session)"):
		_fail = "★ 回收梯未判会话节点是否还有效(开局那一瞬会被自己的回收梯拆掉)"
		return
	# 对局结束由 RoomManager._on_session_finished 调用 rejoin.end_match(match_id) 处理，不依赖 teardown_room。
	for stale in ["rejoin.drop_port(", "rejoin.drop_room("]:
		if code.contains(stale):
			_fail = "★ room_manager 里出现 %s —— 凭据作废必须留在 teardown_room 体内(挪到调用方 = 同一件事两处实现)" % stale
			return
	_done.append("_check_reclaim_ladder")


# ── 检查各模式开局入口与重连凭证签发 ──
func _check_rejoin_spawn_wiring() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby/room_manager.gd"))
	# 单进程单端口架构下，各模式开局入口统一经由 _open_match 初始化会话并签发重连凭证。
	var entries := ["_start_match", "royale_start", "royale_start_ai", "team_start", "ai_duel"]
	for f in entries:
		var body := ScanUtil.func_body(code, f)
		if body.is_empty():
			_fail = "找不到 %s 的函数体" % f
			return
		if not body.contains("_open_match("):
			_fail = "★ %s 没走 _open_match(该模式开不了局,或开了局却不登记回局凭据 —— 零报错)" % f
			return
	# 凭证登记必须在创建 MatchSession 之后执行，确保登记时已持有有效局号 match_id。
	var om := ScanUtil.func_body(code, "_open_match")
	if om.is_empty():
		_fail = "找不到 _open_match 的函数体"
		return
	var at_session := om.find("MatchSession.new(")
	var at_grant := om.find("lobby.rejoin.grant(")
	if at_session < 0:
		_fail = "★ _open_match 没有建 MatchSession(单进程之后对局就是这个节点)"
		return
	if at_grant < 0:
		_fail = "★ _open_match 没有登记回局凭据(该模式点「回到对局」永远得到「凭据已失效」,且零报错)"
		return
	if at_grant < at_session:
		_fail = "★ _open_match 的凭据登记排在**建会话之前**(局号还没分配 -> 凭据里的 match_id 是 0 -> 回局必被拒)"
		return
	# 凭据清理集成于 30s 周期回收阶梯中。
	var rec := ScanUtil.func_body(code, "_reclaim_finished_matches")
	if rec.is_empty():
		_fail = "找不到 _reclaim_finished_matches"
		return
	if not rec.contains("lobby.rejoin.prune("):
		_fail = "★ 回收梯未清过期凭据(lobby.rejoin.prune)—— 凭据表只增不减,表会无限长大"
		return
	_done.append("_check_rejoin_spawn_wiring")


func _finish() -> void:
	# 注意事项：名单对账(见文件头那段)。只在 `_fail` 为空时做:`_fail` 非空说明已有正式断言失败,
	#   那时早就打 FAIL 了,再叠一条"没跑到尾"只会把真原因淹掉。
	# - 判定条件为什么成立:`_fail` 为空时,任何 `_check_*` 的提前 return 都只可能来自函数开头那条
	#   `if _fail != "": return` —— 而它只在 `_fail` 已非空时点火,与前提矛盾。故 `_fail` 为空 ⟺
	#   「没有正式断言失败」;此时名单不全就只可能是"那个函数没跑到尾"(脚本错误)。
	if _fail.is_empty():
		var missing: Array[String] = []
		for n in CHECK_NAMES:
			if not _done.has(n):
				missing.append(n)
		if not missing.is_empty():
			_fail = ("★★ 这些检查**没跑到尾**(多半是脚本错误让那个函数当场结束,而它不给 _fail 赋值):%s"
					% str(missing))
		elif _done.size() != CHECK_NAMES.size():
			# 反向:名单比实跑少  ->  加了新检查却没把它登记进 CHECK_NAMES(新检查会不受本对账保护)。
			# 让它红,而不是静默放行 —— 那正是本条要堵的方向。
			_fail = ("★★ 跑过的检查数(%d)与 CHECK_NAMES(%d)不符 —— 加/删了 _check_* 却没同步名单"
					% [_done.size(), CHECK_NAMES.size()])
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,收局(会话)+删房 结构齐备(三张注册表的在局宽限界逐个钉死:1v1 裸界 / 大乱斗 ROYALE_MATCH_TIME_CEILING(可证上界) / 3v3 TEAM_MATCH_ESTIMATE;%d 项检查全部跑到尾)" % _done.size())
	quit(0)
