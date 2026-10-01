extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke)。锁的结构横跨三个文件,而它**已经
# 跟着架构换过一整套载体**(2026-09-14 拆账本 → 2026-09-21 阶段 2-B → 本次单进程化):
#  **room_manager.gd**:1) SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;3) `_process` 每周期调
#   `_sweep_stale_rooms`(另按 REJOIN_GC_INTERVAL 走凭据表 GC);4) 超龄房走拆除收口 —— 有会话的
#   房**先 `session.abort()`**(它会走 `finished` → 收口那一条),没会话的僵尸房直接 teardown;
#   5) 大乱斗在局宽限谓词同时引用 RoyaleHost.MATCH_TIME 与 rr.in_match,3v3 那条用
#   TEAM_MATCH_ESTIMATE 与 tr.in_match,1v1 那条的门控是本房的 room.started。
#   ★ 回收从"每 30s 按 pid 轮询 worker 还在不在"变成**信号驱动**:`MatchSession.finished` →
#   `_on_session_finished`(作废凭据 + 拆房 + 释放会话),2h 超龄清扫兜底 —— 见 _check_reclaim_ladder。
#  **lobby_rooms.gd**(账本/收口):2) 建房时给 created_at 赋时间戳;收口体外不得出现**注册表删除**
#   (见 _check_teardown_funnel)。★ 端口池 / 三档端口归还延迟 / 按端口杀 worker / pid 记账
#   那一整套随 `server/worker_launcher.gd` **一起消失** —— 反向断言见 _check_teardown_funnel。
#  **match_session.gd**(新,每局一个节点):宽限分派 / 走光才结束 / 满员才开 / 不降级 这些**语义**
#   全搬到了这里 —— 别再去 server_main.gd 找它们(见 _check_team_startup_contract)。
#  **argv 契约整体消失**:`--worker`/`--royale`/`--team`/`--roles`/`--teams` 不再存在(参战 role
#   集合与队伍表由房记录经 `MatchSession.new(...)` 直接传),故 _check_argv_contract 只剩反向断言。
#  ★ 删掉的一相:`_check_worker_pid_tracking` —— pid 记账随 `--worker` 子进程整体消失,
#   没有载体可断言(见 _initialize 里删除处的注释)。
#
#  **三张注册表的对称性**(B 册 Task 4/5/7 留下的纪律):3v3 与大乱斗两条分支必须与 1v1 对称 ——
#   收集块(`for … lobby.*_rooms`)+ 循环体里的 `stale.append(...)` + 在局宽限谓词,少一条就会出现
#   "守卫在、那张表的房永不被清"(**静默**资源泄漏)。★ 单进程化把三张表的收集**并进同一个
#   `stale` 列表**,于是旧形态那条「三条 `is_empty()` 并列」的守卫在源码里变成了**一条**
#   `if stale.is_empty(): return` —— 并列性挪到了**收集侧**(三张表各自 append 进同一个列表),
#   判据跟着挪(见 _check 与 _check_reclaim_ladder 各钉一半)。
# 跑法:用户自跑(room_sweep_smoke.sh)。通过 = SMOKE_ROOM_SWEEP OK。

var _fail := ""
# ★★ 2026-09-21(「看得见进不去」批 Task 6 补;**单进程化后同一条纪律照旧成立**):**本文件每个
#   `_check_*` 都必须跑到尾**。
#   为什么需要:本文件的 `_check_*` 全是"`_fail` 非空就早退"的写法,而 **GDScript 的脚本错误
#   (`Invalid call. Nonexistent function …` 这类)不给 `_fail` 赋值** —— 它只让**出错的那个
#   函数当场结束**,调用方 `_initialize` 照常往下走,`_finish()` 于是打出 OK。当年那次的现场是
#   "探针真去调一次生产类":把 `WorkerLauncher.pid_of` 连名带调用一起改名后,输出多一段
#     `SCRIPT ERROR: Invalid call. Nonexistent function 'pid_of' in base 'RefCounted (WorkerLauncher)'`
#   而 verdict **仍是 `SMOKE_ROOM_SWEEP OK`** —— 那一组断言被静默跳过,读起来像"全过"。
#   ★ 那一相已随子进程删除,但**这个洞没被封上**:本文件现在是纯源码扫描,一次越界/空串操作
#   (从空块里 `split`、往数组下标取不存在的元素)照样能让整段断言被静默跳过。故名单对账留着。
#   (同源的完整表述在 `tests/lib/probe_base.gd` 文件头:`ALL-OK` 只证明"没有任何一条断言
#   失败",不证明"该跑的断言都跑过";两个新场景探针用 `_checks >= EXPECTED_CHECKS` 堵它。)
# ★ 判据为什么成立:`_fail` 为空时,任何"提前 return"都只可能来自函数开头那条
#   `if _fail != "": return` —— 而它只在 `_fail` 已非空时点火,与 `_fail` 为空矛盾。
#   故 `_fail` 为空 ⟺ 「没有正式断言失败」;此时名单不全就**只可能**是"有函数没跑到尾"。
const CHECK_NAMES := [
	"_check", "_check_argv_contract", "_check_teardown_funnel",
	"_check_team_startup_contract", "_check_team_spawn_guard",
	"_check_join_refusal_guards", "_check_reclaim_ladder",
	"_check_rejoin_spawn_wiring",
]
var _done: Array[String] = []

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
	#   不加载 room_manager,而服务端那条路要真起进程才走得到 RoomManager)。`load()` 会真正编译它。
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
	# ★ 删除处:`_check_worker_pid_tracking` 这一相**整体删除**(2026 单进程化),不是漏了。
	#   为什么:它钉的是"端口 → pid 的登记、pid_alive 的判活、归还端口时清 pid"——那是
	#   `--worker` 子进程时代"这一局还在不在"的**唯一**判据。子进程没了之后这一整套(含
	#   `WorkerLauncher` 类本身)都不存在,没有载体可断言;而它守的**意图**("别把一个已经结束的
	#   对局判成还在")改由会话节点回答 —— 新判据钉在 _check_reclaim_ladder ③ 与清扫那一格。
	_check_join_refusal_guards()
	_check_reclaim_ladder()
	_check_rejoin_spawn_wiring()
	_finish()


# 取「**等于** line_text 的那一行 + 紧随其后、缩进更深的一块」(到下一个缩进 ≤ 它的非空行为止)。
# ★ 必须用**保留缩进**的视图(`ScanUtil.code_view`,它同样剥掉注释):`code_only` 会 strip_edges,
#   拿它切不出块 —— 而这里两条断言的价值恰恰在于"那个 if 后面**真的有**它声称做的事"。
# ★ 只返回**第一处**命中:本用途下每个 needle 都应当是唯一的;不唯一时(命中处是同一形状的另一处)
#   断言会红在"块里没有 X"上,判词只是失去分辨力 —— 故 _check_team_startup_contract ⑤ 特意把
#   取块的输入先裁到**函数体**上(全文里 `if mode == Mode.TEAM:` 有两处)。
func _block_of(code_view: String, line_text: String) -> String:
	var lines: PackedStringArray = code_view.split("\n")
	for i in range(lines.size()):
		# ★ 匹配用**整行相等**(strip 后),不用 `contains`:本仓的 `elif mode == Mode.ROYALE:` 里就含
		#   `if mode == Mode.ROYALE:` 这个子串 —— contains 会张冠李戴。
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


# ── 批次 2 新增:房间拆除收口 ──(2026-09-14 账本与收口搬进 lobby_rooms.gd;单进程化后又换过载体)
# 「幽灵房」这**同一个**失败模式本层补过三次(on_peer_left 空房分支 / royale_leave 空房分支 /
# ai_duel 摘房前的手动释放)。收口后「新加一条拆除路径」不可能漏 —— 因为没有第二条路可走。
# 断言形态刻意选「**只能出现在这一处**」而不是「数调用点个数」:个数会随实现漂,而这是契约本身。
func _check_teardown_funnel() -> void:
	# ★ 2026-09-14:账本与拆除收口搬进了 server/lobby_rooms.gd(LobbyRooms,见 M4c)。
	#   收口的判据跟着搬 —— 「注册表删除只能出现在收口体内」这条纪律与它住哪个文件无关。
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
	# ★★ 判据为什么是 `reg.erase(`:单进程化之后,三张注册表的删除**收敛成一句**
	#   (`teardown_room` 里先按房型选出 `reg`,再 `reg.erase(room.code)`)—— 旧的那条
	#   `_worker_ports.erase(port)` / `_launcher.release_now(port)`(端口归还入口)**随端口池
	#   一起不存在了**,故"端口归还"这一格的判据换成了"注册表删除"这一格。
	# ★ 只有这一个函数体内允许出现注册表的删除动作(它就是收口自己)。别把 `allowed` 放宽成
	#   "谁拆房谁算数"——那正是这条门存在要拦的事。
	var allowed := ["teardown_room"]
	# ★ 旧的三条 `*_rooms.erase(`(1v1/大乱斗/3v3)仍留在判据里是有意的:它们现在是"有人把某一张
	#   表单独 erase 回去"这一档的判据,而多留几个字符串是**加宽判据面**,与"放宽白名单"方向相反。
	for f in funcs:
		for line in (f["body"] as String).split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue
			for pat in ["reg.erase(", "rooms.erase(", "royale_rooms.erase(", "team_rooms.erase("]:
				if t.contains(pat):
					if not allowed.has(f["name"]):
						_fail = "lobby_rooms.%s 里出现 %s —— 拆除必须走 teardown_room 单一收口" % [f["name"], pat]
						return
	# ★★ 反向:端口池 / 端口归还 / 按 pid 记账那一整套**整体不存在**(随 `--worker` 子进程与
	#   `server/worker_launcher.gd` 一起删掉)。判据扫**生产目录**的**剥注释视图**,两个理由:
	#   · 剥注释:那些名字在注释里被提到是**有意的留档**(`core/net/proc_util.gd` /
	#     `core/net/grace_window.gd` 的文件头都在讲"当年那一套"),注释不是代码;
	#   · 只扫生产目录(server/core/scenes/ui/render):`tests/` 下的兄弟探针按**旧契约**写、
	#     由各自批次同步 —— 把它们收进来只会造出一条本文件修不了的红。
	var dead := ["release_now", "_release_port_later", "worker_port", "worker_pid", "WorkerLauncher"]
	var scanned := 0
	for path in ScanUtil.collect(["res://server", "res://core", "res://scenes", "res://ui", "res://render"]):
		if not path.ends_with(".gd"):
			continue
		scanned += 1
		var pcode := ScanUtil.code_only(ScanUtil.read(path))
		# ★ 读不到就是红:`ScanUtil.read` 读不出内容时给 ""(见它的注释),拿 "" 去 contains
		#   恒假 ⇒ 那个文件对这条反向断言**彻底失明**,而整体仍绿。
		if pcode.is_empty():
			_fail = "%s 读不出内容(读不到就是红 —— 否则这条反向断言对它失明)" % path
			return
		for tok in dead:
			if pcode.contains(tok):
				_fail = "%s 的代码里仍有 %s —— 端口池/端口归还/pid 记账随 worker_launcher.gd 整体删除,别让它们复活" % [path, tok]
				return
	# ★ 防失明:`collect` 走不到目录时(清单写错、路径不在包里)上面那个循环**一次都不跑**,
	#   这条反向断言会**恒绿**。故先要求它真扫到一批文件(生产目录当前约 110 个 .gd)。
	if scanned < 50:
		_fail = "反向扫描只走到 %d 个 .gd(生产目录应有一百来个)—— 目录清单写错?这条断言会因此恒绿" % scanned
		return
	_done.append("_check_teardown_funnel")


# ── 批次 2 新增 / 单进程化跟随改写:role 集合与队伍表的**传递契约** ──
# 旧形态把参战 role 集合与队伍表拼在 worker 的命令行上(`--roles` / `--teams`),于是"生成端与
# 解析端只改一边 = 静默降级"是本相的老对手(CLAUDE.md 当年明文要求两边同步改)。单进程化把那条
# 命令行**整体删掉**:对局参数由房记录经 `MatchSession.new(...)` 直接传 —— 生成端与解析端塌缩成
# **同一次构造调用**,那条"只改一边"的故障模式失去了载体。故本相只剩两半:
#   ① 反向:旧 argv 协议标识符一个都不许复活,且 `server/worker_launcher.gd` 这个文件不存在;
#   ② 正向(载体换了):那次 7 参构造必须在位 —— 它是参战集合/队伍表**唯一**的传递口。
func _check_argv_contract() -> void:
	# ★ 反向的第一批:量纲型旧标识符(把"人数/上界"当参数、再从 role 号推集合与队号)。
	#   第二批:本次整体删除的模式/名单开关(`--worker`/`--royale`/`--team`/`--roles`/`--teams`/
	#   `--ai-roles`)—— 它们**必须一个都不剩**,否则说明有人把"每局一个子进程"那条路接了回来。
	# ★ 判据取**剥注释视图**:`server_main.gd` 的文件头**有意**留了一句"这里不再有 --worker/…"
	#   的留档,而注释不是代码(拿整文件原文 contains 会被那句留档自己判红)。
	var main_code := ScanUtil.code_only(ScanUtil.read("res://server/server_main.gd"))
	if main_code.is_empty():
		_fail = "无法读取(或读空)server_main.gd"
		return
	for bad in ["--worker", "--royale", "--team", "--roles", "--teams", "--ai-roles",
			"--players", "--max-role", "_role_bound", "_expected_players",
			"--team-size", "_team_bound"]:
		if main_code.contains(bad):
			_fail = "server_main.gd 的代码里仍有旧 argv 标识符 %s(对局参数已改由房记录给出)" % bad
			return
	# ★ 生成端那个文件**整个不存在**了(不是改名、也不是"留着不用"):端口池/三档延迟/spawn 族
	#   都在里面,只要它还在,就说明旧形态还活着。这里用 `FileAccess.file_exists` 而不是
	#   `ScanUtil.read` 判空 —— 后者把"文件不存在"与"文件读不出内容"混成同一个 ""。
	if FileAccess.file_exists("res://server/worker_launcher.gd"):
		_fail = "server/worker_launcher.gd 又出现了 —— 单进程化后不该再有 worker 启动器"
		return
	# ★ 正向:参战集合与队伍表的**新传递口**。判据取那次构造调用的**整行**(含实参顺序):
	#   漏传 roles/teams 中的任何一个都不会报错,只会让那一局按错的名单摆位
	#   (3v3 尤其静默:teams 空 = 全员同一队,而胜负从第一秒就是假的)。
	var rm := ScanUtil.read("res://server/room_manager.gd")
	if rm.is_empty():
		_fail = "无法读取(或读空)room_manager.gd"
		return
	if not ScanUtil.code_only(rm).contains(
			"MatchSession.new(mode, room.code, _next_match_id, roster, roles, ai_roles, teams)"):
		_fail = "room_manager 里没有 MatchSession.new(…, roster, roles, ai_roles, teams) 这一行 —— 参战集合/队伍表的新传递口不在位"
		return
	_done.append("_check_argv_contract")


# ── 批次 3(3v3)新增 / 单进程化跟随改写:启动契约里"本册能做到的那一半" ──
# ★ 边界照实写明:**真链路**(6 个真客户端 → 满员开局 → 有人掉线 → 宽限到期 → **其余人继续打**)
#   归 **B 册的真链路探针**。本函数钉的是**分派与开局判据本身**,而它们的载体已整体从
#   `server_main.gd`(进程级 argv 开关 / `_process` 里的超时梯)搬进 `server/match_session.gd`
#   (每局一个节点:`_process` 的三条超时梯 / `_expire_graces` / `_begin_match` 的帧末复核):
#   ① 宽限到点走那条**已被 grace_window_smoke ⑦ 逐个模式钉住答案**的纯函数,而不是又抄一遍 if/else;
#   ② `_expire_graces` 末尾那条"全员走光才结束"也含 3v3(漏了 = 3v3 走光后会话永驻);
#   ③ `_begin_match` 必须真建 TeamHost,且**帧末再核一次满员**;
#   ④ 3v3 的超时梯**不降级**(与 royale 那条"按已到人数开局"方向相反)、收齐判据是"满员才开";
#   ⑤ 越界/名册守卫**模式无关**;模式是**单值枚举**(旧的双布尔开关不得复活)。
func _check_team_startup_contract() -> void:
	if _fail != "":
		return
	var src := ScanUtil.read("res://server/match_session.gd")
	if src.is_empty():
		_fail = "无法读取 match_session.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 到点的分派必须走纯函数(答案在 grace_window_smoke ⑦ 里按模式逐个钉死)。
	var expire := ScanUtil.func_body(code, "_expire_graces")
	if expire.is_empty():
		_fail = "找不到 _expire_graces 的函数体"
		return
	# ★★ 判据必须落到"**比较了**"上,不能只查函数名出现:旧写法是 `contains("GraceWindow.expire_action(")`
	#   —— 而把分派退回不可测写法、同时把那行当**死代码**留下的变异
	#   (`var _a := GraceWindow.expire_action(...)` + 原样的手写 if/else)两条都满足 ⇒ 全绿,
	#   而 3v3 已经坏了(宽限到期的那个人会让整局提前收场)。
	if not expire.contains("GraceWindow.expire_action(mode == Mode.ROYALE, mode == Mode.TEAM) == GraceWindow.ACTION_REMOVE"):
		_fail = "_expire_graces 未把 GraceWindow.expire_action 的返回值**比较**给 ACTION_REMOVE(分派退回不可测的 if/else?)"
		return
	# ★ 反向:分派里不许再出现**以 `if mode ==` 开头**的手写分支 —— 那种行只可能是"按模式再写
	#   一遍"的分派。下面那条"全员走光"判据是多条件式(以 `if (mode ==` 开头),不在射程内。
	for eline in expire.split("\n"):
		if eline.begins_with("if mode =="):
			_fail = "_expire_graces 里有手写的按模式分派(%s)—— 三个模式的答案必须来自 GraceWindow.expire_action" % eline
			return
	if not expire.contains("mark_disconnected(role)"):
		_fail = "_expire_graces 的移出分支未调 mark_disconnected(3v3 少人应继续打)"
		return
	# ② 末尾那条"全员走光才结束"必须把 3v3 一并收进去,且**不能省 `started` 前置**。
	# ★ 与上面那条分派是**两条**判据(一条管"某个人到点怎么办"、一条管"人全走光了这一局结不结束"),
	#   只改一条就是"3v3 少人继续打"能成立、但 6 个人走光后会话永驻。
	# ★ 判据取"比较行 + 紧邻它上面那一行"(同一条多行条件式):`mode == Mode.ROYALE or
	#   mode == Mode.TEAM` 与 `started` 都写在续行那一支上,只看含 `_grace.size() == 0` 的
	#   那一行会把 3v3 那一半漏判成"不在"。
	var gone := ""
	var glines: PackedStringArray = expire.split("\n")
	for i in range(glines.size()):
		if glines[i].contains("claims.is_empty() and _grace.size() == 0"):
			gone = glines[i]
			if i > 0:
				gone = glines[i - 1] + "\n" + gone
			break
	if gone.is_empty():
		_fail = "找不到 _expire_graces 末尾的「全员走光才结束」判据(被删了?)"
		return
	if not gone.contains("Mode.TEAM"):
		_fail = "「全员走光才结束」判据没含 3v3(Mode.TEAM)—— 3v3 全员走光后会话永驻"
		return
	# ★ `started` 是旧 `_match_started` 前置的直系对应物:本函数每秒无条件跑,少了它"开机等玩家"
	#   期间(claims 空 + 宽限期空)同样满足 ⇒ 一建局就判"全员离开"自杀。那是**静默**的。
	if not gone.contains("started"):
		_fail = "「全员走光才结束」判据没含 started 前置(开机等玩家期间会被判成全员离开)"
		return
	# ③ `_begin_match` 必须真的建 TeamHost(而不是落进 1v1 分支静默开成 2 人局),且**帧末再核一次**。
	var begin := ScanUtil.func_body(code, "_begin_match")
	if begin.is_empty():
		_fail = "找不到 _begin_match 的函数体"
		return
	if not begin.contains("TeamHost.start_on("):
		_fail = "_begin_match 未按 3v3 建 TeamHost(3v3 会静默开成 1v1)"
		return
	# ★ 帧末复核:收齐判据由**最后一个** claim 满足 → 开局延到帧末,而这一帧里 claim 集可能
	#   **缩小**(有人刚 claim 完就掉线)。不核的话 5 个人也能开 —— 而本模式的纪律是"满员才开、
	#   不降级"(3v3 少一个人 = 一边 3 打 2,整局胜负从第一秒就是假的)。
	if not begin.contains("if mode == Mode.TEAM and claims.size() < team_of_role.size():"):
		_fail = "_begin_match 缺 3v3 的帧末满员复核(5 个人也能开局 → 一边 3 打 2)"
		return
	# ④ 3v3 报到超时梯:**结束这一局**(不降级开局)。方向与 royale 那条("按已到人数开局")相反。
	#   判据只取那一支的块(到下一个 `elif` 为止)—— 看整段 `_process` 会被别处的 `_finish()`
	#   与大乱斗那条自己的 `_begin_match()` 喂饱(两种写法都实测过:放宽到固定行数会把正确实现
	#   判红,收紧到写死 5 行则漏掉块尾的收场)。
	var ladder := ""
	var lines: PackedStringArray = code.split("\n")
	for i in range(lines.size()):
		if lines[i].contains("if mode == Mode.TEAM and not started"):
			var j := i + 1
			while j < lines.size() and not lines[j].begins_with("elif "):
				j += 1
			ladder = "\n".join(lines.slice(i, j))
			break
	if ladder.is_empty():
		_fail = "找不到 3v3 的报到超时梯(未满员时会话一直挂着)"
		return
	if not ladder.contains("_finish()"):
		_fail = "3v3 报到超时梯没有结束这一局(_finish())—— 收不齐就该收场"
		return
	if ladder.contains("_begin_match("):
		_fail = "★ 3v3 超时梯调了 _begin_match(降级开局)—— 与用户裁定「满 6 人才开」相反"
		return
	# ⑤ 收齐判据 = 满员,且**分母是驱动摆位的那个集合**(Task 9 评审 M5)。
	# ★ 判据落在 3v3 那一支的**整块**上(用保留缩进的视图切块),而不是"文件里某处出现过某串":
	#   后者既能被别处的同形代码喂饱,也照不出"分母用错集合"这一档。
	# ★ 为什么分母必须是 `team_of_role.size()`:`team_of_role` 按 role **去重**,而 `role_set`
	#   是逐 token 列表、**可以带重复**(旧 argv 时代 `--roles 1,1,2,2,3,3 --teams 1,1,1,2,2,2`
	#   那种输入长度校验能过)⇒ 拿 `role_set.size()` 当满员界可能**永远到不了**,干等 30s 超时
	#   收场(静默,零报错)。
	# ★ 取块前先裁到 `_on_role_claimed` 的函数体:`_begin_match` 里另有一处**逐字相同**的
	#   `if mode == Mode.TEAM:` 行(那里按 team 建宿主),全文取块会先命中它、判词从此失去分辨力。
	var claimed := ScanUtil.func_body(ScanUtil.code_view(src), "_on_role_claimed")
	if claimed.is_empty():
		_fail = "找不到 _on_role_claimed 的函数体"
		return
	var fill := _block_of(claimed, "if mode == Mode.TEAM:")
	if fill.is_empty():
		_fail = "找不到 3v3 的收齐分支(_on_role_claimed 里的 `if mode == Mode.TEAM:`)"
		return
	if not fill.contains("if claims.size() >= team_of_role.size():"):
		_fail = "3v3 收齐判据不是「满员才开」(_claims.size() >= team_of_role.size())"
		return
	if fill.contains("role_set.size()"):
		_fail = "3v3 收齐判据用的是 role_set.size()(role 会重复/留空洞 —— 分母必须取去重后的队伍表)"
		return
	# ⑥ 越界/名册守卫必须**模式无关**(单端口下 role 集合对三个模式一视同仁)。
	#    集合外的 role 混进来会让 `claims.size()` 提前够数开局,而宿主那侧没有它的摆位;
	#    名册外的 caller 是**架构层面新增**的那一档 —— 没有端口/进程隔离之后,别的房里的玩家
	#    也连在同一个服务端上,不判就会把他的 role 写进这一局的表。
	# ★ 旧判据是"越界守卫必须同时管 3v3"(`((_royale or _team_mode) and not _role_set.has(role))`);
	#   新实现里这两条守卫**不再有模式条件**,故判据换成"守卫在场 + 名册那条也在 + 没带 mode 条件"
	#   —— 带条件的那天就是"某个模式静默漏判"的那天。
	var guard := ""
	var rlines: PackedStringArray = claimed.split("\n")
	for i in range(rlines.size()):
		if rlines[i].contains("not role_set.has(role)"):
			guard = rlines[i]
			if i > 0:
				guard = rlines[i - 1] + "\n" + guard
			break
	if guard.is_empty():
		_fail = "_on_role_claimed 的越界守卫被删(集合外的 role 能混进局里开局)"
		return
	if not guard.contains("not roster.has(caller)"):
		_fail = "_on_role_claimed 缺名册守卫(单端口下别的房的玩家能串进这一局)"
		return
	if guard.contains("mode =="):
		_fail = "★ 越界/名册守卫带了模式条件(三个模式必须一视同仁,否则必有一档静默漏判)"
		return
	# ⑦ 模式开关**互斥**(Task 9 评审 M4 的老问题):旧形态是三处手写优先级不一致,故当年要求
	#    "两个开关同时为真时当场拒绝启动"。新架构把它变成了**结构问题**:模式是 `MatchSession`
	#    上的一个 `enum Mode` 单值,互斥由类型保证 —— 于是判据换成反向:那两只布尔开关不得复活。
	if not code.contains("enum Mode { DUEL, ROYALE, TEAM }"):
		_fail = "match_session 缺 enum Mode { DUEL, ROYALE, TEAM }(模式互斥的载体)"
		return
	for tok in ["_team_mode", "_royale"]:
		if code.contains(tok):
			_fail = "match_session 里出现旧的双布尔模式开关 %s —— 模式是单值枚举,别把「两开关互斥」那套加回来" % tok
			return
	_done.append("_check_team_startup_contract")


# ── 批次 3(3v3)新增 / 单进程化跟随改写:队号**取值**的 fail-fast ──
# ★ 旧判据是**真调一次** `WorkerLauncher.spawn_team_worker(7770, [1,2,3], [1,1,3])` 验"长度相等而
#   队号越界 → 拒绝"(文本只能证明"那几行字在",而越界队号的后果是**静默**的:解析端丢弃 →
#   子进程开机即 quit、大厅判定"拉起成功"、对局永不开始且零报错)。
# ★ 子进程与那条命令行整体消失,那条取值校验换成了**开局闸 + 分母**这一对:
#   ① 越界/未选边的队号**根本进不了局** —— 开局闸是 `LobbyRooms.team_room_ready`(`_by_team` 只
#      统计队号 1/2 且两队各 3 人),而"从 `tr.team_of` 组 teams"的代码在 `RoomManager.team_start`
#      里,且**必须排在组表之前**(排反了就会把 `get(role, 0)` 的 0 号队静默带进那一局);
#   ② 满员分母是 `MatchSession.team_of_role.size()`(去重后的队伍表),不是逐 token 的 `role_set`
#      —— 拿后者当界会让"同 role 重复的输入"永远到不了满员(与 _check_team_startup_contract ⑤
#      是同一条源码事实的两面:那边钉"满员才开"的语义,这边钉"分母与取值面")。
func _check_team_spawn_guard() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/room_manager.gd"))
	var body := ScanUtil.func_body(code, "team_start")
	if body.is_empty():
		_fail = "找不到 RoomManager.team_start 的函数体"
		return
	# ① 组 teams 的那几行必须还在 room_manager 里(它是"role → 队号"唯一的落点)。
	if not body.contains("teams[int(r)] = int(tr.team_of.get(int(r), 0))"):
		_fail = "★ team_start 里没有从 tr.team_of 组 teams 的那几行(队伍归属的唯一来源丢了)"
		return
	# ★ 取值校验 = 开局闸;它**必须在组表之前**:`get(int(r), 0)` 的 0 是"未选边"的哨兵,
	#   先组表再校验的话,那个 0 会静默进局(3v3 少一个人 = 一边 3 打 2,而日志零报错)。
	if not body.contains("lobby.team_room_ready(tr)"):
		_fail = "★ team_start 缺开局闸 lobby.team_room_ready(未选边/越界的队号会被带进局里)"
		return
	if body.find("lobby.team_room_ready(tr)") > body.find("teams[int(r)]"):
		_fail = "★ team_start 的队号取值校验排在了组表之后(0 号队会静默进局)"
		return
	# ② 分母(与 _check_team_startup_contract ⑤ 同源;这里再点名一次,因为它是"取值面"的另一半)。
	var session := ScanUtil.code_only(ScanUtil.read("res://server/match_session.gd"))
	if session.is_empty():
		_fail = "无法读取(或读空)match_session.gd"
		return
	if not session.contains("if claims.size() >= team_of_role.size():"):
		_fail = "MatchSession 的满员判据没用 team_of_role.size()(去重后的队伍表)"
		return
	if session.contains("if claims.size() >= role_set.size():"):
		_fail = "★ MatchSession 的满员判据用了 role_set.size()(逐 token 列表会重复 —— 满员界永远到不了)"
		return
	_done.append("_check_team_spawn_guard")


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
	# ★ 下面全部走**剥注释视图**(`code_view` 保缩进切块 / `code_only` 去缩进比对):这个函数的
	#   注释**正好**在逐条讲那些界与那条守卫,拿整文件原文 `contains` 会被注释喂饱 —— 注释不是代码。
	var cv := ScanUtil.code_view(src)
	var code := ScanUtil.code_only(src)
	var sweep := ScanUtil.func_body(cv, "_sweep_stale_rooms")
	if sweep.is_empty():
		_fail = "取不到 _sweep_stale_rooms 的函数体"; return
	# 超龄判断本身(基准界);在局宽限是紧邻它上面那一行,逐档钉在下面。
	if not sweep.contains("created_at > MAX_ROOM_AGE"):
		_fail = "_sweep_stale_rooms 缺超龄判断"; return
	# ── 三条在局宽限谓词,逐档点名(判据 = 谓词行 + 紧邻它上面那行宽限声明)──
	# ★ 断言只在**那两行**上做,不查整个 body:body 里别的行(清理日志、别处的常量名)也能满足
	#   `contains`,查全 body 会被它喂饱 —— 实测把宽限改回「只加一局时长」仍能通过。
	# ★★ 1v1 那一档的**方向变了**(照实改写,不是放宽):旧实现的 1v1 是**裸 MAX_ROOM_AGE**
	#   (那时 1v1 房没有"已开局"可读的标志,回收靠 worker 进程),故当年有一条反向断言
	#   "宽限不得泄漏进 1v1 分支"。新架构里 1v1 房有 `started`,清扫与另两张表**对称地**给它
	#   在局宽限 —— 于是判据换成"门控必须读本房类型的 started",而"界必须含 SWEEP_INTERVAL
	#   (挡得住下一次 tick)"那一半逐字保留。
	var specs := [
		["room.created_at > MAX_ROOM_AGE", "room.started", "RoyaleHost.MATCH_TIME", "1v1"],
		["rr.created_at > MAX_ROOM_AGE", "rr.in_match", "RoyaleHost.MATCH_TIME", "大乱斗"],
		["tr.created_at > MAX_ROOM_AGE", "tr.in_match", "TEAM_MATCH_ESTIMATE", "3v3"],
	]
	for spec in specs:
		var pred := ""
		var clines: PackedStringArray = code.split("\n")
		for i in range(clines.size()):
			if clines[i].contains(str(spec[0])):
				pred = clines[i]
				if i > 0:
					pred = clines[i - 1] + "\n" + pred
				break
		if pred.is_empty():
			_fail = "找不到%s超龄判定(谓词行 %s)" % [spec[3], spec[0]]; return
		if not pred.contains(str(spec[1])):
			_fail = "%s 的在局宽限门控不是 %s(在局房会被当成僵尸房拆掉?)" % [spec[3], spec[1]]; return
		if not pred.contains(str(spec[2])):
			_fail = "%s 的在局宽限缺 %s(宽限被删/被写死?)" % [spec[3], spec[2]]; return
		if not pred.contains("SWEEP_INTERVAL"):
			_fail = "%s 的在局宽限未含 SWEEP_INTERVAL(界被改回只加一局,挡不住下一次 tick?)" % spec[3]; return
	# ── 三张注册表的**收集块**(头行 + 循环体)逐张点名 ──
	# ★ 单进程化把三张表的收集**并进同一个 `stale` 列表**(不再有 `stale_royale`/`stale_team`):
	#   于是"漏掉一张表"的形态变成了"那个循环不在"或"它没往 `stale` 里 append" —— 两种都会让
	#   那张表的超龄房**永远进不了拆除列表**(静默资源泄漏)。故逐张取**块**(头行 + 更深的循环体)
	#   而不是全文 `contains`:保留头行、只把循环体掏空时,后者照样绿(B 册 Task 7 评审留的同粒度洞)。
	var loops := [
		["for code in lobby.rooms:", "stale.append(room)", "1v1"],
		["for rcode in lobby.royale_rooms:", "stale.append(rr)", "大乱斗"],
		["for tcode in lobby.team_rooms:", "stale.append(tr)", "3v3"],
	]
	for lp in loops:
		var blk := _block_of(sweep, str(lp[0]))
		if blk.is_empty():
			_fail = "_sweep_stale_rooms 没有收集%s超龄房的循环(%s)—— 那张表的房永不被清" % [lp[2], lp[0]]; return
		if not blk.contains(str(lp[1])):
			_fail = "_sweep_stale_rooms 的%s收集块循环体是空的(留了 for 头行却没 %s → 那张表的房永不被清)" % [lp[2], lp[1]]; return
	# ── 那条唯一的提前 return 守卫 ──
	# ★★ 旧形态(`stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty()`)的**三条
	#   并列**在新实现里已不存在:三张表并进一个 `stale`,并列性挪到了**收集侧**(上面那三条
	#   逐张表的 append 就是它的等价判据)。守卫本体仍要钉:它缺席时"这次没有超龄房"的每次 tick
	#   都会白跑一遍拆除循环。
	var guard := _block_of(sweep, "if stale.is_empty():")
	if guard.is_empty() or not guard.contains("return"):
		_fail = "_sweep_stale_rooms 缺「无超龄房则提前 return」的守卫(或被掏空)"; return
	# ── 拆除:有活会话的房**先结束会话**,没会话的僵尸房直接走收口 ──
	# ★ 旧判据这一格是"杀 worker 的实现存在 + 收口调它"。子进程没了之后,同一格的失败模式
	#   (那一局没被真正结束 / 房不消失)改由这两条路守 —— **两条都要**:只查一条会放任
	#   "房被拆了而那一局还在跑"(客户端还在打一局没人认领的对局),或反过来"会话结束了而房
	#   永远留在列表里"。
	var live := _block_of(sweep, "if s != null and is_instance_valid(s):")
	if live.is_empty() or not live.contains("s.abort()"):
		_fail = "_sweep_stale_rooms 的有会话分支没走 s.abort()(直接 teardown = 还在跑的那一局失去收口)"; return
	var dead := _block_of(sweep, "else:")
	if dead.is_empty() or not dead.contains("lobby.teardown_room("):
		_fail = "_sweep_stale_rooms 的没会话分支没走拆除单口(lobby.teardown_room)—— 没开局的僵尸房拆不掉"; return
	# ★ 不在本地再抄一遍收口那三件事(作废凭据 / 拆房 / 释放会话):`abort()` → `finished` →
	#   `_on_session_finished` 那一条才是它们唯一的落点。
	if sweep.contains("lobby.rejoin.end_match("):
		_fail = "_sweep_stale_rooms 自己作废了凭据(应交给会话的 finished 收口,别抄第二遍)"; return
	# 汇总 print 也必须报界(照实登记的界;漏了只是日志失真,但它是那些界的**唯一**读数)。
	# ★ 旧判据要求它逐个报三档(含 `3v3`);新实现的汇总行报**一条合并界**(基准 + "在局中另加宽限"),
	#   分档的估值在源码的三条 grace 行里、不在日志里 —— 故判据改成:汇总行必须同时报出基准界
	#   与「在局宽限」这一档,否则运维读到"N 个超龄房"时看不出在局中的房为什么活得比 2h 久。
	var summary := ""
	for line in code.split("\n"):
		if line.begins_with('print("[lobby] 清理'):
			summary = line
			break
	if summary.is_empty() or not summary.contains("MAX_ROOM_AGE") or not summary.contains("宽限"):
		_fail = "_sweep_stale_rooms 的汇总 print 未报出基准界与在局宽限(界有变化而日志读不出来)"; return
	# ★ 本函数**跑到尾**的凭证(判据在 _finish;理由见文件头那段)。下面的每个 _check_* 同款。
	_done.append("_check")


# ── 2026-09-21(「看得见进不去」批)新增:三条 join 的**拒绝守卫与文案** ──
# ★ 为什么是源码级:文案是**发给玩家看的字符串**,而探针里没有对端 ——
#   `NetBus.reply` 在 `is_peer_live(caller)` 为假时**静默跳过**(见 NetBus.reply 的注释),
#   所以那句话在探针里根本观测不到。行为面(调用方没被 append 进 players)由
#   `tests/lobby_visibility_probe.tscn` 相①/②/③ 断言,这里断言的是**那句话本身**。
# ★ 为什么文案值得一条断言:1v1 原先对"对局进行中"说的是「房间已满」—— 那是假话,而且会命中
#   大厅页 `_on_server_message` 的**自动刷新**分支(那条只认旧文案)。改文案 = 静默改行为。
# ★ 另钉一条反向:三条守卫必须**用"这一局在进行中"判**(started / in_match),不许退化成
#   "房满 / 人数"之类的替代判据 —— 后者在"房里只剩 1 人"时放行,正是本批要堵的那档。
# ★★ 2026-09-21(回局入口批)补一条**前提**(下方判据与文案一个字节都没改):
#   `tests/lobby_visibility_probe` 相①②③ 断的是「对局中的房**对无凭据者**一律拒绝」——
#   "回局"那条路**刻意不经过这三条守卫**:它走 `rejoin_request`(大厅侧 `on_rejoin_request`,
#   按凭据表放行),客户端侧则在列表里把持凭据的那一行画成**可点**(相⑧)。
#   故**不许**在这三个 handler 里插"有凭据就放行"的分支 —— 那等于把"回局"混进"入房"语义,
#   而本函数这条守卫**当场变成一句空话且红不起来**(它判的是那条 `if` 还在,前面加一条
#   前置分支它照样绿)。
func _check_join_refusal_guards() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby_rooms.gd"))
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


# ── 对局结束的**回收梯接线**(2026-09-21 新增;单进程化跟随改写) ──
# ★ 为什么"接线"要单独钉:行为探针(`tests/lobby_visibility_probe.tscn` 相④)是**手工调**
#   回收的 —— 把那条线删掉,行为探针**照样全绿**,而生产里房永远不会被回收(列表位与凭据白占)。
#   本仓对这类"两半"的既有先例:`team_room_smoke` ⑨①(接线面)对 `hud_declarative_probe` ③(行为面)。
# ★ 回收的**形态换了**:旧架构是"每 30s 轮询 worker 进程还在不在"(`_reclaim_finished_matches`),
#   新架构是**信号驱动** —— `MatchSession.finished` → `_on_session_finished`(精确:会话自己说
#   "我结束了"的那一刻)+ 2h 超龄清扫兜底(死掉的会话 / 没开局的僵尸房)。
# ★ 另一条:回收不能绕道直接删注册表。既有的 `_check_teardown_funnel` 只扫
#   `server/lobby_rooms.gd`,**扫不到写在 room_manager 里的绕道** —— 那正是本函数存在的理由。
func _check_reclaim_ladder() -> void:
	if _fail != "":
		return
	var src := ScanUtil.read("res://server/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 接线本身:信号必须先接上,否则收局那一整套一次都不会跑。
	if not code.contains("session.finished.connect(_on_session_finished)"):
		_fail = "★ 会话的 finished 信号没接到 _on_session_finished —— 对局结束后房与凭据永不被回收"
		return
	var fin := ScanUtil.func_body(code, "_on_session_finished")
	if fin.is_empty():
		_fail = "找不到 _on_session_finished"
		return
	# ★ 三件事一条都不能少(与旧的"回收要拆房 + 释放"是同一个意图,载体从 worker 进程换成会话节点):
	#   作废凭据(否则那一局的玩家点「回到对局」会被放回一局已经结束的对局)、
	#   拆房(必须走收口)、释放会话节点(不释放就是每打完一局泄漏一个 MatchSession)。
	if not fin.contains("lobby.rejoin.end_match("):
		_fail = "★ 收局未作废凭据(lobby.rejoin.end_match)—— 「这一局没了」只有这一处能说"
		return
	if not fin.contains("lobby.teardown_room("):
		_fail = "★ 收局未走拆除单一收口(房永远留在列表里)"
		return
	if not fin.contains("queue_free()"):
		_fail = "★ 收局未释放会话节点(queue_free)—— 每打完一局泄漏一个 MatchSession"
		return
	# ★ 凭据作废的**唯一**时点就是这里(`RejoinRegistry.end_match` 的类头这么写着)。挪到别处
	#   (比如清扫里再抄一遍)不会报错,只会让"同一件事两处实现"。
	var n_end := code.count("lobby.rejoin.end_match(")
	if n_end != 1:
		_fail = "★ room_manager 里 lobby.rejoin.end_match( 出现 %d 次 —— 凭据作废只许有 _on_session_finished 这一处" % n_end
		return
	# ② 2h 兜底清扫:三张注册表的**收集块**在 `_check` 里逐张钉着(那是"清扫结构"面),这里钉
	#   **守卫 + 消费**这两半 —— 旧形态那条"三条 is_empty 并列"的守卫,在新形态里等于
	#   「三张表 append 进同一个 `stale`」(收集侧)+「一条 `if stale.is_empty(): return`」+
	#   「`for room in stale:` 拆同一批」。三半合起来才是旧那条判据的等价物,故两处各钉一半,
	#   不把同一份判据抄两遍。
	var sweep_view := ScanUtil.code_view(src)
	var sweep := ScanUtil.func_body(sweep_view, "_sweep_stale_rooms")
	if sweep.is_empty():
		_fail = "找不到 _sweep_stale_rooms"
		return
	var guard := _block_of(sweep, "if stale.is_empty():")
	if guard.is_empty() or not guard.contains("return"):
		_fail = "★ _sweep_stale_rooms 的「无超龄房则提前 return」守卫不在(或被掏空)"
		return
	if not sweep.contains("for room in stale:"):
		_fail = "★ 拆除循环没有消费那个被守卫过的 `stale` 列表(收集与拆除分了家 → 那张表的房永不被清)"
		return
	# ③ 反向:不得再有**按 pid 判「这一局还在不在」**的代码 —— 那个问题现在由"会话节点还在不在"
	#   回答(`room.get("session")` + `is_instance_valid`)。判据收的是当年那套 API 名与它唯一的
	#   谓词函数名:只要有人把它们接回来,这里当场红。
	for pat in ["pid_of(", "pid_alive(", "worker_pid", "_match_over"]:
		if code.contains(pat):
			_fail = "★ room_manager 里出现 %s —— 「这一局还在不在」必须问会话节点,别再按 pid 轮询" % pat
			return
	if not sweep.contains('room.get("session")') or not sweep.contains("is_instance_valid("):
		_fail = "★ 清扫没按「会话节点还在不在」判这一局(在局房与僵尸房会被一视同仁地拆)"
		return
	# ★ 另一条反向(与上面同一件事的"绕道"面,口径同 `_check_reclaim_ladder` 的老那条):
	#   注册表删除只许出现在 `teardown_room` 体内 —— `_check_teardown_funnel` 只扫
	#   `server/lobby_rooms.gd`,写在编排层的绕道它看不见。
	for pat in ["rooms.erase(", "royale_rooms.erase(", "team_rooms.erase(", "reg.erase("]:
		if code.contains(pat):
			_fail = "★ room_manager 里出现 %s —— 注册表删除必须留在 teardown_room 体内(绕道 = 同一件事两处实现)" % pat
			return
	_done.append("_check_reclaim_ladder")


# ── 阶段 2-B(Task 4,2026-09-21)新增 / 单进程化跟随改写:开局入口**都**登记回局凭据 ──
# ★ 为什么是源码级:登记发生在"开局那一刻",要真跑起一局才走得到 —— 本文件里没有可用的行为探针
#   (真链路归 `tests/rejoin_probe.sh`)。而**漏掉任何一个**开局入口的症状是**静默**的:那个模式的
#   玩家点「回到对局」永远得到"凭据已失效",大厅侧一行报错都没有 —— 正是本仓反复登记的
#   "守卫在、东西不在"那一档。
# ★ 载体换了:旧架构是"四个 spawn 点各自在 `spawn_*` 之后调 `_grant_rejoin(`",新架构把四个
#   RPC 入口 + 配对信号那条**统一汇到 `_open_match`**,凭据登记就在那一处。故判据变成两半:
#   ① 五个入口逐个点名,每一个都必须汇到 `_open_match`(漏一个 = 那个模式回不去);
#   ② `_open_match` 体内:登记必须在位、且**排在 `_send_go_match` 之前**、键必须是 `match_id`。
#   ★ 五个而不是旧清单的四个:`ai_duel` 在新架构里也是一条**独立入口**(旧实现里它经
#   `_start_match` 绕一圈),漏了它 AI 对战那一局的凭据就没人发。
func _check_rejoin_spawn_wiring() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/room_manager.gd"))
	var entries := ["_start_match", "royale_start", "royale_start_ai", "team_start", "ai_duel"]
	for f in entries:
		var body := ScanUtil.func_body(code, f)
		if body.is_empty():
			_fail = "找不到 %s 的函数体" % f
			return
		# ① 该入口必须汇到 `_open_match`(否则那一局既没会话、也没凭据,且零报错)
		if not body.contains("_open_match("):
			_fail = "★ %s 未汇到 _open_match(该模式点「回到对局」永远得到「凭据已失效」,且零报错)" % f
			return
	var open := ScanUtil.func_body(code, "_open_match")
	if open.is_empty():
		_fail = "找不到 _open_match 的函数体"
		return
	# ② 登记在 `_open_match` 体内(凭据登记的唯一落点)
	if not open.contains("lobby.rejoin.grant("):
		_fail = "★ _open_match 未登记回局凭据 —— 四个入口唯一落点,这里漏了就是三种模式全漏"
		return
	# ★ 顺序有意义:token 必须在 **go_match 之前**发到客户端(客户端收到 go_match 当场认领 role,
	#   而 `report_token` 紧跟着 claim 走;晚发会与 claim 抢同一次 poll)。凭据登记与它是同一批事,
	#   故判据落在**同一函数体内的先后**(不是"文件里某个位置")—— 顺序错了不报错,只静默失真。
	var at_go := open.find("_send_go_match")
	if at_go < 0 or open.find("lobby.rejoin.grant(") > at_go:
		_fail = "★ _open_match 的 lobby.rejoin.grant( 未排在 _send_go_match 之前(客户端会先认领 role 并报 token)"
		return
	# ★ 凭据的键必须是**局号**:三张注册表的房号空间重叠,按房号作废会误伤同号的另一间房
	#   (端口更不行 —— 单进程之后端口不再标识任何一局,见 RejoinRegistry 类头)。
	var grant_line := ""
	for line in open.split("\n"):
		if line.contains("lobby.rejoin.grant("):
			grant_line = line
			break
	if not grant_line.contains("match_id"):
		_fail = "★ _open_match 的凭据登记没带 match_id(凭据表的键:按房号/端口作废会误伤同号的另一间房)"
		return
	# ③ 凭据表的 GC 必须搭在 `_process` 的定时梯上(`REJOIN_GC_INTERVAL`):TTL 只是表的上界,
	#   不为它另立定时器(同一件事不留两处)。★ 旧判据是"搭在 30s 回收梯上"—— 那条梯随 pid
	#   轮询一起没了,GC 现在有自己的周期常量。
	if not code.contains("const REJOIN_GC_INTERVAL := 30.0"):
		_fail = "缺 REJOIN_GC_INTERVAL=30 常量(凭据表 GC 的周期)"
		return
	var proc := ScanUtil.func_body(code, "_process")
	if proc.is_empty():
		_fail = "找不到 RoomManager._process"
		return
	if not proc.contains("lobby.rejoin.prune("):
		_fail = "★ _process 未清过期凭据(lobby.rejoin.prune)—— 凭据表只增不减,表会无限长大"
		return
	_done.append("_check_rejoin_spawn_wiring")


func _finish() -> void:
	# ★★ 名单对账(见文件头那段)。**只在 `_fail` 为空时**做:`_fail` 非空说明已有正式断言失败,
	#   那时早就打 FAIL 了,再叠一条"没跑到尾"只会把真原因淹掉。
	# ★ 判据为什么成立:`_fail` 为空时,任何 `_check_*` 的提前 return 都只可能来自函数开头那条
	#   `if _fail != "": return` —— 而它只在 `_fail` 已非空时点火,与前提矛盾。故 `_fail` 为空 ⟺
	#   「没有正式断言失败」;此时名单不全就**只可能**是"那个函数没跑到尾"(脚本错误)。
	if _fail.is_empty():
		var missing: Array[String] = []
		for n in CHECK_NAMES:
			if not _done.has(n):
				missing.append(n)
		if not missing.is_empty():
			_fail = ("★★ 这些检查**没跑到尾**(多半是脚本错误让那个函数当场结束,而它不给 _fail 赋值):%s"
					% str(missing))
		elif _done.size() != CHECK_NAMES.size():
			# 反向:名单比实跑少 ⇒ 加了新检查却没把它登记进 CHECK_NAMES(新检查会**不受本对账保护**)。
			# 让它红,而不是静默放行 —— 那正是本条要堵的方向。
			_fail = ("★★ 跑过的检查数(%d)与 CHECK_NAMES(%d)不符 —— 加/删了 _check_* 却没同步名单"
					% [_done.size(), CHECK_NAMES.size()])
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,结束会话+拆房 结构齐备(三张注册表的在局宽限界逐个钉死:1v1 room.started / 大乱斗 RoyaleHost.MATCH_TIME / 3v3 TEAM_MATCH_ESTIMATE;对局回收走信号驱动 _on_session_finished;%d 项检查全部跑到尾)" % _done.size())
	quit(0)
