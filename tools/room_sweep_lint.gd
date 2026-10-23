extends SceneTree
# 房间生命周期约定的源码级检查器(按需跑,不进任何默认批):断言全是对产品源码文本的判形态,一条行为断言都没有。
# 跑法:"$GODOT" --headless --path . -s res://tools/room_sweep_lint.gd(不碰任何端口);通过 = 判词 SMOKE_ROOM_SWEEP OK。
# 检查的约定(名字见 CHECK_NAMES):拆除单一收口、worker argv 契约、3v3 启动契约与 spawn 守卫、worker PID 跟踪、
#   拒绝入房的三条文案、回局凭据的回收梯、四个 spawn 点登记凭据的顺序。约定文本在 docs/eng/room-lifecycle-conventions.md。

var _fail := ""
# ★ 每个 `_check_*` 都必须跑到尾,否则判词会假绿:脚本错误不给 `_fail` 赋值,只让出错那个函数当场结束、调用方照常往下走 ⇒ 判词仍是 OK。
#   故每个末尾把函数名记进 `_done`,`_finish()` 拿 CHECK_NAMES 对账。判据为什么成立:`_fail` 为空 ⟺ 没有正式断言失败 —— 提前 return 只可能来自那条 `if _fail != "": return`。
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
	# ★ 先 `load()` 一次目标脚本再作文本断言:纯文本扫描不会编译被扫的文件 ⇒「文本全对但文件压根编译不过」它能直接放过去(实测踩过)。
	#   `load()` 解析失败时不返回 null(给回的是那个坏掉的脚本对象),故判据用 `reload()` 的错误码;同源表述见 tests/lib/probe_base.gd 文件头。
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
# ★ 必须用保留缩进的视图(`ScanUtil.code_view`,它同样剥掉注释):`code_only` 会 strip_edges、切不出块 —— 而这两条断言的价值恰在于「那个 if 后面真的有它声称做的事」。
# ★ 只返回第一处命中:每个 needle 都是唯一的(不唯一时断言会红在「块里没有 X」上,不会静默取错)。
func _block_of(code_view: String, line_text: String) -> String:
	var lines: PackedStringArray = code_view.split("\n")
	for i in range(lines.size()):
		# ★ 匹配用整行相等(strip 后),不用 `contains`:仓库的 `elif _team_mode:` 里就含 `if _team_mode:` 这个子串,contains 会把块取错。
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


# 拆除动作(端口归还/注册表删除/杀 worker)只许出现在 server/lobby_rooms.gd 的 teardown_room / _release_port_later 内;断言形态取「只许出现在这一处」而不是数调用点个数(个数会随实现漂,这句是契约)。
func _check_teardown_funnel() -> void:
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
	var allowed := ["teardown_room", "_release_port_later"]
	for f in funcs:
		for line in (f["body"] as String).split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue
			# ★ 模式列表必须含当前的端口归还入口(`_launcher.release_now`)与三张注册表 + 凭据表作废(`rejoin.drop_port`):改名/搬家时同款改这里。
			#   三张表名互为子串(`team_rooms.erase(` 里含 `rooms.erase(`):只留裸那条判词会点错名字 —— 多留一条字符串是加宽判据面,不是放宽白名单。
			for pat in ["_release_port_later(", "launcher.release_now(", "royale_rooms.erase(", "team_rooms.erase(", "rooms.erase(", "rejoin.drop_port("]:
				if t.contains(pat):
					if not allowed.has(f["name"]):
						_fail = "lobby_rooms.%s 里出现 %s —— 拆除必须走 teardown_room 单一收口" % [f["name"], pat]
						return
	_done.append("_check_teardown_funnel")


# role 协议必须是显式 role 集合(--roles):旧协议传「人数 + role 上界」两个整数,而 role 号由「最小空闲号」分配、退出后不重排 ⇒ 编号留空洞、推导必然出错。
# 判据是反向的:旧标识符一个都不许复活(大厅与 worker 两边只改一边,是这套 argv 契约的历史故障模式)。
func _check_argv_contract() -> void:
	# 生成端(worker_launcher.gd)与解析端(2026-10-22 起搬到 core/mp/mode_context.gd)两边清单都要在:只改一半 = 静默降级。
	# ★ 解析端不再住在 server_main.gd:那里只剩"取 ctx 字段 + 落实例标志",argv 字符串都搬进了纯函数模块。
	for f in ["res://server/server_main.gd", "res://server/lobby/worker_launcher.gd",
			"res://core/mp/mode_context.gd"]:
		var txt := FileAccess.get_file_as_string(f)
		if txt.is_empty():
			_fail = "无法读取 %s" % f
			return
		for line in txt.split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue   # 注释里提旧协议名是**有意的**(留档为什么换掉),不算违规
			for bad in ["--players", "--max-role", "_role_bound", "_expected_players",
					"--team-size", "_team_bound"]:
				if t.contains(bad):
					_fail = "%s 的代码里仍有旧 argv 协议标识符 %s(应已换成 --roles 集合)" % [f, bad]
					return
	# 正向:集合协议必须在两边都在位(只改一边 = 拉起的 worker 收不到 role 集合,静默降级)。
	# ★ 判据取剥注释视图(`ScanUtil.code_only`):注释里提旧协议名是有意的留档 —— 把真代码删掉、只在注释里留一句说明,不该喂绿这条。
	for f in ["res://server/lobby/worker_launcher.gd", "res://core/mp/mode_context.gd"]:
		var code2 := ScanUtil.code_only(ScanUtil.read(f))
		if not code2.contains('"--roles"'):
			_fail = "%s 未接 --roles(集合协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % f
			return
		for tok in ['"--team"', '"--teams"']:
			if not code2.contains(tok):
				_fail = "%s 未接 %s(3v3 启动协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % [f, tok]
				return
	_done.append("_check_argv_contract")

# ★ 边界:6 个真客户端的真链路归真链路探针;本函数钉的是分派本身 —— ① `--team`/`--teams` 两边逐字对应;② 宽限到点走 `GraceWindow.expire_action` 纯函数;
#   ③ `_expire_graces` 末尾「全员走光才退出」含 3v3(漏了 = worker 永驻占端口);④ 3v3 超时梯不降级(与 --royale 相反)、收齐判据 = 满员才开。
func _check_team_startup_contract() -> void:
	var src := ScanUtil.read("res://server/server_main.gd")
	if src.is_empty():
		_fail = "无法读取 server_main.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 到点的分派必须走纯函数 `GraceWindow.expire_action`(答案按模式逐个钉在 grace_window_smoke 里)。
	var expire := ScanUtil.func_body(code, "_expire_graces")
	if expire.is_empty():
		_fail = "找不到 _expire_graces 的函数体"
		return
	# ★★ 判据必须落到「比较了」上,不能只查函数名出现:旧写法只认函数名子串,把分派退回手写 if/else 的变异曾全绿。
	#   另加反向:分派里不许再出现手写的 `if _royale:` 优先级分支。
	if not expire.contains("GraceWindow.expire_action(_royale, _team_mode) == GraceWindow.ACTION_REMOVE"):
		_fail = "_expire_graces 未把 GraceWindow.expire_action 的返回值**比较**给 ACTION_REMOVE(分派退回不可测的 if/else?)"
		return
	if expire.contains("if _royale:"):
		_fail = "_expire_graces 里出现了手写的 `if _royale:` 分派(三个模式的答案必须来自 GraceWindow.expire_action)"
		return
	if not expire.contains("mark_disconnected(role)"):
		_fail = "_expire_graces 的移出分支未调 mark_disconnected(3v3 少人应继续打)"
		return
	# ② `_expire_graces` 末尾那条「全员走光才退出」必须把 `_team_mode` 一并收进去,否则 6 个人走光后 worker 永驻占端口。
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
	# ③ `_begin_match` 必须真的建 TeamHost(落进 1v1 分支 = 静默开成 2 人局)。
	var begin := ScanUtil.func_body(code, "_begin_match")
	if not begin.contains("TeamHost.start_on("):
		_fail = "_begin_match 未按 _team_mode 建 TeamHost(3v3 会静默开成 1v1)"
		return
	# ④ 3v3 超时梯不降级(方向与 --royale 相反);判据只取那一支的块(到下一个 `elif` 为止)—— 看整段 `_process` 会被别处的 quit 喂饱。
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
	# ⑤ 收齐判据 = 满员,且分母是 `_team_of_role.size()`:`--roles 1,1,2,2,3,3` 之类能过长度校验,而 `_team_of_role` 按 role 去重 ⇒ 拿 `_role_set` 长度当满员界永远到不了(干等 30s 静默超时)。
	#   判据落在 3v3 那一支的整块上(保留缩进的视图切块),不是「文件里某处出现过某串」—— 后者既会被别处的同形代码喂饱,也照不出「分母用错集合」这一档。
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
	# ⑥ role 越界守卫必须同时管 3v3:集合外的 role 混进来会让 `_claims.size()` 提前够数开局,而 TeamHost 那侧 `spawns[role]` 缺键。
	if not code.contains("((_royale or _team_mode) and not _role_set.has(role))"):
		_fail = "_on_role_claimed 的越界守卫只认 _royale(集合外的 role 能混进 3v3 局里开局)"
		return
	# ⑦ `--royale` 与 `--team` 同时为真必须当场拒绝启动。2026-10-22:守卫搬进 `ModeContext`(纯函数,
	#    置 ok=false),真正的 `quit(1)` 在 server_main 的通用分支里 —— 两半都要在:
	#    只留 ModeContext 不接退出 = 静默继续;只留退出没有守卫 = 永远不触发。
	var ctx_src := ScanUtil.read("res://core/mp/mode_context.gd")
	if ctx_src.is_empty():
		_fail = "无法读取 mode_context.gd"
		return
	var excl := _block_of(ScanUtil.code_view(ctx_src), 'if bool(ctx["royale"]) and bool(ctx["team"]):')
	if excl.is_empty():
		_fail = "ModeContext 未拒绝 --royale 与 --team 同时为真(模式开关互斥的守卫被删?)"
		return
	if not excl.contains("_fail("):
		_fail = "ModeContext 的互斥守卫里没有 _fail(...)(空块 = 守卫守不住,静默开成错的那一半)"
		return
	if not code.contains('if not bool(ctx["ok"]):'):
		_fail = "server_main 未对 ModeContext.ok=false 做 quit(1)(互斥/越界都会被静默放行)"
		return
	_done.append("_check_team_startup_contract")


# ★ 这条必须真调一次,不能只作文本断言:文本只能证明「那几行字在」,而失败后果是静默的 —— 解析端对越界队号静默丢弃 ⇒ 子进程开机即 quit(1),
#   而生成端返回 `pid > 0` ⇒ 大厅判定「拉起成功」、对局永不开始、大厅侧零报错。★ 只喂非法输入(合法输入会真拉起子进程);控制组 = 长度相等而队号越界。
func _check_team_spawn_guard() -> void:
	print("[info] 下面那条 ERROR 是**预期**的:正在验证生成端拒绝越界队号(不真调一次,这条守卫就只是空话)")
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段(正确的实现不会拉起任何进程:校验在 `OS.create_process` 之前)。
	var bad_val := WorkerLauncher.new().spawn_team_worker(7770, [1, 2, 3], [1, 1, 3])
	if bad_val:
		_fail = "spawn_team_worker 放行了越界队号(长度相等、队号 3 越界 → 子进程开机即 quit、大厅判定成功、零报错)"
		return
	_done.append("_check_team_spawn_guard")


func _check(src: String) -> void:
	if not src.contains("const SWEEP_INTERVAL := 600.0"):
		_fail = "缺 SWEEP_INTERVAL=600(10min)常量"; return
	if not src.contains("const MAX_ROOM_AGE := 7200.0"):
		_fail = "缺 MAX_ROOM_AGE=7200(2h)常量"; return
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains(
			"created_at = Time.get_unix_time_from_system()"):
		_fail = "create_room/royale_create 未记录 created_at(超龄判据的输入)"; return
	if not src.contains("func _process"):
		_fail = "缺定时 _process"; return
	if not src.contains("func _sweep_stale_rooms"):
		_fail = "缺 _sweep_stale_rooms"; return
	# 杀 worker 的实现住在 WorkerLauncher:实现存在与「收口里有人调它」两条都要 —— 只查实现会放任「实现在、收口不再杀」(僵尸 worker 继续占端口)。
	if not FileAccess.get_file_as_string("res://server/lobby/worker_launcher.gd").contains("func kill_worker"):
		_fail = "缺 WorkerLauncher.kill_worker(杀 worker 的实现)"; return
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains("launcher.kill_worker("):
		_fail = "lobby_rooms 未调 launcher.kill_worker(收口不再杀 worker → 僵尸占端口)"; return
	var fn := src.find("func _sweep_stale_rooms")
	var body_end := src.find("\nfunc ", fn + 10)
	if body_end < 0:
		body_end = src.length()
	var body := src.substr(fn, body_end - fn)
	if not body.contains("created_at > MAX_ROOM_AGE"):
		_fail = "_sweep_stale_rooms 缺超龄判断"; return
	var src_lines: Array = []
	for line in body.split("\n"):
		var t: String = line.strip_edges()
		if not t.is_empty() and not t.begins_with("#"):
			src_lines.append(t)
	# 宽限断言只在谓词那两行(声明 + 比较)上做,不查整个 body:body 里别的代码行也含同样的常量名,查全 body 会被它喂饱。
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
	# ★ 上界认的是 `ROYALE_MATCH_TIME_CEILING` 而不是 `RoyaleHost.MATCH_TIME`:后者只是默认值,房主可在建房页把一局配到 15 分钟,长时长房会在对局中途被判超龄、连 worker 一起杀掉。
	if not pred.contains("ROYALE_MATCH_TIME_CEILING"):
		_fail = "大乱斗在局宽限缺 ROYALE_MATCH_TIME_CEILING(宽限被删/被改回默认时长?)"; return
	if pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限又用回了 RoyaleHost.MATCH_TIME(它只是默认值,不是上界)"; return
	# ★ 判据取「声明那一行含 1800」这一中间档:整行字面量对无害改写假红;而全文件找 `1800` 是空话(同一个文件里 `TEAM_MATCH_ESTIMATE` 也是 1800.0)。
	#   方向:宁可响亮假红,不可静默失明。
	var ceil_line := ""
	for line in src.split("\n"):
		if line.contains("const ROYALE_MATCH_TIME_CEILING"):
			ceil_line = line
			break
	if ceil_line.is_empty() or not ceil_line.contains("1800"):
		_fail = "缺 ROYALE_MATCH_TIME_CEILING=1800(或值被改小了 —— 它必须盖得住装载钳位的上界)"; return
	# ★★ 前提的另一环:上界 1800 = 30 分钟 × 60,而 30 来自 `Settings.royale_match_min` 的装载钳位 —— 钳位一放宽,上面两条照绿而缺口复现,只有这条会红。
	var settings_src := FileAccess.get_file_as_string("res://core/config/settings.gd")
	# ★ 读不到时必须报「读不到」,否则下一条会宣称钳位变了,把诊断引向完全错误的方向。
	if settings_src.is_empty():
		_fail = "无法读取 settings.gd(读不到源码 ≠ 钳位变了)"; return
	if not settings_src.contains("royale_match_min = clampf(") or not settings_src.contains("1.0, 30.0"):
		_fail = ("★ Settings.royale_match_min 的装载钳位变了 —— ROYALE_MATCH_TIME_CEILING "
				+ "(=30min×60=1800)不再盖得住它,大乱斗在局宽限的缺口复现。改钳位要一起改上界常量。"); return
	# ★ 上界链有三环,这里钉环二:`mp_lobby.gd` 把 `royale_match_min` 换算成秒(`* 60.0`)下发 —— 改成 `* 120.0` 而上面照绿 ⇒ 上界静默失效。
	#   判据同款取片段:定位含 `"match_time"` 且带换算的那一行,要求它同时含 `Settings.royale_match_min` 与 `* 60.0`(该文件里 `"match_time"` 出现两次,取第一处会挑中行键)。
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
	# ★ 环三(写入端)= scenes/mp_lobby.tscn 里 `MatchTimeSlider` 节点的 `max_value`:它才是真正产生下发值的那一环 —— `value_changed` 把滑块值不钳位地写进
	#   `Settings.royale_match_min`,而装载钳位 [1,30] 只在下一次装载时生效 ⇒ 放宽 `max_value` 后前两环照绿、下发值已能到 3600(静默失效)。
	# ★ 判据读 .tscn 且比数值而不是子串(`contains("15")` 挡不住 `15.0 → 150.0`);`MatchTimeSlider` 必须恰一个且仍是 HSlider(读错同名节点会得到别的上限)。
	#   读不到骨架 ⇒ 响亮报「读不到」;另加反向:`.gd` 里不许再出现 `_time_slider.max_value`(否则上限回到两个家,判据被架空)。
	# ⚠ server/royale_host.gd 原样收下客户端给的 `match_time`、worker 侧也不钳位 ⇒ 上界依赖客户端行为,不是无条件成立(登记见 docs/eng/registered-debt.md)。
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
	# 反过来:1v1 的超龄判断必须保持裸 `MAX_ROOM_AGE`,宽限不得泄漏进 1v1 分支。
	if not code.contains("room.created_at > MAX_ROOM_AGE:"):
		_fail = "1v1 超龄判断不再是裸 MAX_ROOM_AGE(宽限泄漏?)"; return
	# ★ 3v3 的收集块与宽限谓词要各有一针:只钉删除列表那行不够 —— 它由 `stale_team` 变量喂饱,变量恒空也照过(症状是 3v3 房永不被清、worker 端口永久泄漏)。
	#   两边各钉一次,才拦得住「保留 `var stale_team` 声明、掏空 `for tcode in lobby.team_rooms:` 循环」或「把 `tr.in_match` / `TEAM_MATCH_ESTIMATE` 从宽限里摘掉」。
	if not body.contains("for tcode in lobby.team_rooms"):
		_fail = "_sweep_stale_rooms 没有收集 3v3 超龄房的循环(team_rooms 永不被扫 → 端口永久泄漏)"; return
	# ★★ 循环头行与循环体的 `append` 要分别钉:只钉头行时,掏空 `stale_team.append(tr)` 仍全绿而 `stale_team` 恒空 ⇒ 3v3 房永不被清。
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
	# ★ `_sweep` 走拆除收口:别改回「直接调 `_kill_worker`」—— 那样端口回收会绕过收口,正是本层补过三次的那个泄漏。
	if not body.contains("teardown_room(") or not body.contains("TEARDOWN_KILL"):
		_fail = "_sweep_stale_rooms 未走拆除收口(应调 _lobby.teardown_room(..., LobbyRooms.TEARDOWN_KILL, ...))"; return
	if not body.contains("stale + stale_royale"):
		_fail = "_sweep_stale_rooms 未把多张注册表的超龄房一并拆除"; return
	# ★★ 3v3 那一支要两条判据:只查「拆除列表」不够 —— 末尾「全空则提前 return」的并列判据是第二条退出路径,漏掉 `stale_team` 时 3v3 超龄那次 tick 当场 return ⇒ 端口永久泄漏。
	if not body.contains("stale_team"):
		_fail = "_sweep_stale_rooms 完全没扫 3v3 房(team_rooms 的超龄房 → worker 端口永久泄漏)"; return
	if not body.contains("stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty()"):
		_fail = "_sweep_stale_rooms 的「无超龄房则提前 return」守卫漏了某张注册表(只有那张表的房超龄时永不清扫 → 静默端口泄漏)"; return
	if not body.contains("stale + stale_royale + stale_team"):
		_fail = "_sweep_stale_rooms 的拆除列表未含全部三张注册表(未被扫到的那张 → 端口永久泄漏)"; return
	# ★ 汇总 print 必须把 3v3 超龄数(实参 `stale_team.size()`)报出来:判据钉数据而不钉文案里的 "3v3" 标签 —— 标签留着、实参换掉才是要拦的变异。
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
	# ★ 本函数跑到尾的凭证(判据在 `_finish`;理由见文件头)。下面的每个 `_check_*` 同款。
	_done.append("_check")

# ── worker pid 的登记与归还 ──
# ★ 钉它:「对局中的房什么时候消失」的判据是本局 worker 进程还在不在,而 pid 的来源就是这里(端口 → pid);归还端口时不清 pid 的后果是静默的 ——
#   大厅会认为一个已经结束(甚至端口已被复用给别的局)的对局还活着,房永不出现在回收名单里,而端口与列表位一直占着。
func _check_worker_pid_tracking() -> void:
	if _fail != "":
		return
	var L := WorkerLauncher.new()
	# 直接摆内部表(与 spawn 守卫只喂非法输入同取向:本冒烟不该真拉起子进程)。
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段(正确的实现不会拉起任何进程:校验在 `OS.create_process` 之前)。
	L.set("_worker_pids", {7770: 4242})
	if L.pid_of(7770) != 4242:
		_fail = "WorkerLauncher.pid_of 没读到登记过的 pid"
		return
	if L.pid_alive(0) or L.pid_alive(-1):
		_fail = "★ pid_alive(<=0) 必须是 false(登记发生在 spawn 成功之后,那之前的窗口别判成活着)"
		return
	L.release_now(7770)
	if L.pid_of(7770) != 0:
		_fail = "★ 端口归还后未清 pid(房会被判成「还在」→ 永久占着列表位与端口)"
		return
	_done.append("_check_worker_pid_tracking")


# ── 三条 join 的拒绝守卫与文案 ──
# ★ 为什么是源码级:文案是发给玩家看的字符串,而探针里没有对端 —— `NetBus.reply` 在 `is_peer_live(caller)` 为假时静默跳过,那句话在探针里观测不到(行为面零守卫:`lobby_visibility_probe.tscn` 已删·2026-10-09)。
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


# ── 对局中房间的回收梯接线 ──
# ★ 「接线」要单独钉:行为探针(零守卫:`lobby_visibility_probe.tscn` 已删·2026-10-09)是手工调 `_reclaim_finished_matches()` 的,把 `_process` 里那次调用删掉它照样全绿;回收也不许绕道直接删注册表 —— `_check_teardown_funnel` 只扫 server/lobby_rooms.gd。
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
	# 三张注册表都要被扫:漏一张 = 那张的房永不被回收(静默端口泄漏,本层补过五次的那个模式)。
	for pat in ["for code in lobby.rooms", "for rcode in lobby.royale_rooms", "for tcode in lobby.team_rooms"]:
		if not fn.contains(pat):
			_fail = "★ 回收梯漏扫了一张注册表(%s)→ 那张的房与端口永不被回收" % pat
			return
	var mo := ScanUtil.func_body(code, "_match_over")
	if mo.is_empty():
		_fail = "找不到 _match_over"
		return
	if not mo.contains("pid <= 0") or not mo.contains("port <= 0"):
		_fail = "★ _match_over 没把 port/pid <= 0 判成「没结束」(开局那一瞬会被自己的回收梯拆掉)"
		return
	# ★★ 凭据表作废(`rejoin.drop_port`,旧名 `drop_room`)必须留在 `teardown_room` 体内:凭据表也是一张注册表,挪到调用方就是绕道 —— 挪走时本冒烟曾照旧报 OK。
	#   两种写法都收:只留旧名的门对当前绕道失明,只留新名认不出按 code 的版本被加回来(加宽判据面 ≠ 放宽白名单);`drop_token(` 是消费某一份凭据,不收。
	for stale in ["rejoin.drop_port(", "rejoin.drop_room("]:
		if code.contains(stale):
			_fail = "★ room_manager 里出现 %s —— 凭据作废必须留在 teardown_room 体内(挪到调用方 = 同一件事两处实现)" % stale
			return
	_done.append("_check_reclaim_ladder")


# ── 四个 spawn 点都登记回局凭据 ──
# ★ 为什么是源码级:登记跑在「spawn 成功之后」,要真拉起 worker 才走得到,本文件没有可用的行为探针;漏掉任何一个 spawn 点的症状是静默的 ——
#   那个模式的玩家点「回到对局」永远得到「凭据已失效」,大厅侧零报错。★ 四个点逐个点名而不数调用次数(个数会漂,也数不出漏的是哪个);`royale_start_ai` 最易漏。
func _check_rejoin_spawn_wiring() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby/room_manager.gd"))
	var spawns := ["_start_match", "royale_start", "royale_start_ai", "team_start"]
	for f in spawns:
		var body := ScanUtil.func_body(code, f)
		if body.is_empty():
			_fail = "找不到 %s 的函数体" % f
			return
		# ① 该 spawn 点必须登记凭据(否则那个模式永远回不去,且零报错)
		if not body.contains("_grant_rejoin("):
			_fail = "★ %s 未登记回局凭据(该模式点「回到对局」永远得到「凭据已失效」,且零报错)" % f
			return
		# ② 登记必须排在 spawn 调用之后:登记早了 `worker_pid` 还是 0 ⇒ `RejoinRegistry.decision` 把还在打的局判成「已结束」(顺序错了不报错,只静默失真)。
		var at_spawn := body.find("spawn_")
		if at_spawn < 0 or body.find("_grant_rejoin(") < at_spawn:
			_fail = "★ %s 的 _grant_rejoin( 未排在 spawn 调用之后(凭据里的 worker_pid 会是 0)" % f
			return
	# ③ 凭据表的 GC 搭在 30s 回收梯上:TTL 只是表的上界,不为它另立定时器(同一件事不留两处)。
	var rec := ScanUtil.func_body(code, "_reclaim_finished_matches")
	if rec.is_empty():
		_fail = "找不到 _reclaim_finished_matches"
		return
	if not rec.contains("lobby.rejoin.prune("):
		_fail = "★ 回收梯未清过期凭据(lobby.rejoin.prune)—— 凭据表只增不减,表会无限长大"
		return
	_done.append("_check_rejoin_spawn_wiring")


func _finish() -> void:
	# ★★ 名单对账(理由见文件头):只在 `_fail` 为空时做 —— 已打 FAIL 时再叠一条「没跑到尾」只会淹掉真原因。
	#   判据为什么成立:`_fail` 为空时任何 `_check_*` 的提前 return 都只可能来自开头那条 `if _fail != "": return`,与前提矛盾 ⇒ `_fail` 为空 ⟺ 没有正式断言失败,此时名单不齐全就只能是脚本错误。
	if _fail.is_empty():
		var missing: Array[String] = []
		for n in CHECK_NAMES:
			if not _done.has(n):
				missing.append(n)
		if not missing.is_empty():
			_fail = ("★★ 这些检查**没跑到尾**(多半是脚本错误让那个函数当场结束,而它不给 _fail 赋值):%s"
					% str(missing))
		elif _done.size() != CHECK_NAMES.size():
			# 反向:名单比实跑少 ⇒ 加了新检查却没登记进 CHECK_NAMES(新检查会不受对账保护)—— 让它红,而不是静默放行。
			_fail = ("★★ 跑过的检查数(%d)与 CHECK_NAMES(%d)不符 —— 加/删了 _check_* 却没同步名单"
					% [_done.size(), CHECK_NAMES.size()])
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备(三张注册表的在局宽限界逐个钉死:1v1 裸界 / 大乱斗 ROYALE_MATCH_TIME_CEILING(可证上界) / 3v3 TEAM_MATCH_ESTIMATE;%d 项检查全部跑到尾)" % _done.size())
	quit(0)
