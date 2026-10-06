extends SceneTree

# 「1v1 worker 在**一个 claim 都没有**时会自己退出」—— 真拉起一个 worker,再读它自己的日志。
# 跑法: source tests/env.sh && timeout 150 "$GODOT" --headless --path . -s res://tests/smoke/duel_spawn_timeout_smoke.gd
# 通过 = `DUEL SPAWN TIMEOUT SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# `server_main._process` 的报到梯原先只有三支:`_team_mode`(30s 退出)、
# `_royale` 且 ≥2 人(20s 降级开局)、`_royale` 且 <2 人(10s 退出)。
# **纯 1v1 一支都没有** ⇒ 大厅配对完、worker 已拉起,而两个客户端都没 `claim_role`
# (转连失败 / 都在 go_match 后立刻消失)时,worker **永驻**、端口白占到 2h 超龄兜底。
#
# ═══ 三条纪律(与 team_spawn_smoke 同款)═══
# ① 端口必须落在**真大厅的 worker 端口池之外**(池 = 7800 + 500)⇒ 固定用 29015。
# ② **跑前先删日志**:`--log-file` 沿用旧文件会让上一次的"报到超时"行让本跑**假绿**。
# ③ 判成败只看最末那行文本,不数 ERROR、也不看退出码。
#
# ★ **两条断言缺一不可**:`就绪` 证明 worker 本身是健康的(把"开机即崩"与"按梯退出"分开),
#   `报到超时` 才是本项要的行为。少了前者,一个开机就 quit(1) 的 worker 会让后者也失败,
#   而失败原因完全指错方向。
# ★ 30s 的来历(改这里要一起看):客户端侧内建兜底是 **12s 转连 / 25s claim** ⇒ worker
#   必须**晚于**它们退;`RECONNECT` 那套的超时也在这个量级。三处同源,别单独调一个。
#
# ★★ **只在编辑器二进制下有效**(2026-09-28 登记):本冒烟末尾那段源码级门控读的是
#   `res://server/server_main.gd` 的**文本**。导出成 `.pck` 之后 GDScript 存的是**二进制 token**,
#   同一处**读不到源码**(要么空串、要么一坨 token 字节)⇒ 门控必然 FAIL,而那是**工具面**的
#   失败、与 `server_main` 对不对无关。要跑它请用编辑器/console 二进制(`$GODOT`),别在发布产物里跑。

const PORT := 29015                      # 池外(池 = 7800..8299)
const READY_MARK := "worker 就绪,等待两名玩家"
const TIMEOUT_MARK := "1v1 报到超时"
const READY_WAIT_MS := 40000             # 冷启动 headless worker + 建世界,给足
const LADDER_WAIT_MS := 60000            # 30s 梯 + 余量

# 结构封闭那两条判据的**位置锚/目标串**(见 `_check_lobby_process_off`):
# `set_process(false)` 必须落在 `_ready` 体内、**大厅分支挂上 RoomManager 之后**,且两者之间没有早退。
const LOBBY_ANCHOR := "add_child(RoomManager.new())"
const PROCESS_OFF := "set_process(false)"


func _initialize() -> void:
	# ★ 空载守卫:load 失败立刻 quit(1),否则后面抛错走不到 quit() → 进程**永久挂起**。
	var L: GDScript = load("res://server/lobby/worker_launcher.gd")
	if L == null:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(读不到 worker_launcher.gd)")
		quit(1)
		return
	var launcher = L.new()
	var fails: Array[String] = []
	var log_path: String = launcher.log_path(PORT)

	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)          # 纪律 ②
		# ★ 删不掉就**别往下走**:残留的旧日志里两个标记都在,会让本冒烟在 1 秒内打出 ALL-OK
		#   而**什么都没观测**(僵尸 worker 占着日志文件的 Windows 共享冲突正是这种情形 ——
		#   被 timeout 掐掉的上一跑从不执行 kill_worker)。
		# ★★ **最可能的成因就是僵尸 worker**(占着日志文件,可能还占着端口 29015):被 `timeout`
		#   掐掉的上一跑走不到 `kill_worker`,那个 worker 子进程活到今天。**先清进程再跑**。
		#   ⚠ 反过来的情形同样要认得:Windows 的删除是**延迟生效**(delete-pending)的 —— 路径仍被
		#   持有而 `file_exists` 已经返回 **false** ⇒ **这条守卫不会点火**,于是旧的"两个标记都在"的
		#   日志会被就地改写、读混。该情形在下面会表现成「等不到就绪标记」,而那条失败信息
		#   **指向 worker 本身**、与真正的成因(残留进程)**方向相反**。见到它就回来查进程,
		#   别急着怀疑 `server_main`。
		if FileAccess.file_exists(log_path):
			print("DUEL SPAWN TIMEOUT SMOKE: FAIL(删不掉旧日志 %s —— 最可能是僵尸 worker 占着它(可能还占着端口 29015);先清进程再跑)" % log_path)
			quit(1)
			return
	if not launcher.spawn_worker(PORT):              # 1v1:无 --royale / --team / --ai-roles
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(1v1 worker 拉起失败)")
		quit(1)
		return

	var ready_text := _wait_for(log_path, READY_MARK, READY_WAIT_MS)
	if not ready_text.contains(READY_MARK):
		fails.append("worker 日志里没有「%s」(等了 %.1fs)—— worker 本身没起来,后面的梯无从谈起。日志尾部:%s"
				% [READY_MARK, READY_WAIT_MS / 1000.0, ready_text.right(400)])
	else:
		var t0 := Time.get_ticks_msec()
		var text := _wait_for(log_path, TIMEOUT_MARK, LADDER_WAIT_MS)
		if not text.contains(TIMEOUT_MARK):
			fails.append("★ 无人 claim 时 worker 没在报到梯上退出(等了 %.1fs;缺「%s」)。"
					% [LADDER_WAIT_MS / 1000.0, TIMEOUT_MARK]
					+ "日志尾部:%s" % text.right(400))
		else:
			var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
			print("  [info] 报到梯在就绪后 %.1fs 点火" % elapsed)
			# ★ 这是**判据**不是读数:它同时拦两种假绿 ——
			#   ① 旧日志残留(那种情况下观测到的耗时 ~0.3s);② 将来有人把 30.0 调小到
			#   客户端兜底(12s 转连 / 25s claim)之下,那会把"转连慢"变成"连不上"。
			#   ★ 取 25.0 而不是 30.0:观测粒度是 250ms 轮询,而门槛是严格的 `> 30.0`
			#   (就绪后实测 29.8s 属正常)。
			#   ★ **判据是 `<= 25.0` 而不是 `< 25.0`**:它编码的不变量是「必须**严格晚于**客户端
			#   25s 的 claim 兜底」,取等(恰好 25.0s)就已经不晚于、正是要拦的那一格。
			if elapsed <= 25.0:
				fails.append("★ 报到梯点火太早(就绪后仅 %.1fs,应 >30s;≤25s 已不晚于客户端的 25s claim 兜底)" % elapsed)

	# ── 源码级门控检查(见下方长注释:本冒烟结构上照不到大厅那一面)──
	# ★ 本冒烟起的是 **worker**,结构上永远进不了大厅模式 ⇒ 它**看不见**下面这条回归:
	#   把那一支的条件写成 **worker-only 标志的否定**(`not _royale and not _team_mode`)时,
	#   大厅进程里那些合取项**全成立** ⇒ `start_server.bat` 起的大厅会在 30 秒后 quit(0) 自杀
	#   (实测发生过)。⇒ 唯一能自动拦住它的是**源码级**检查。
	#
	# ★★ 判的是**语义不变量**,不是字面行。判据(全部落在**剥注释**视图上):
	#   ① 1v1 报到梯的**整条**门控里至少有一个**正的实例 worker 标志**:门控里出现的标识符
	#      **逐个**试(不钉第一个、也不钉名字),要求它被声明成 `var X := false`(或
	#      `var X: bool = false`)**且**被 `X = is_worker` 赋过值 —— 后者防它退化成 `_ready`
	#      里的局部量(`is_worker` 正是出不了函数的那个);
	#   ② 门控**不得否定** worker-only 标志(`_royale` / `_team_mode` / `_worker`):大厅里
	#      它们恒 false,取反恒真。★ **只禁否定式,不禁"以 `not` 开头"** —— `not _match_started`
	#      是正常写法,必须放行(那一支还要求 `_worker` 为真,结构上进不去);
	#   ③ `set_process(false)` 必须在 **`_ready` 体内、紧跟 `add_child(RoomManager.new())` 之后、
	#      且两者之间没有早退**;`_run_worker` 体内**不得**有它(两边的函数体任一取不到 ⇒
	#      **报红**,不静默跳过 —— 见 `_check_lobby_process_off` 里那条 `_run_worker` 空体守卫)。
	#
	# ★★ **哪一条是承重的:③,不是 ①②**(2026-09-28 终审订正;与其照"`var _worker := false`
	#   在位"那句读,不如读这一条):`_worker == false` 与 `_worker or …` **两种写法都能过 ①②**
	#   —— `_worker` 确实被声明成 `var _worker := false`、也确实被 `= is_worker` 赋过值,而
	#   ①② 都不问"这个标志在门里是**正的**吗"。真正拦住"大厅进程进梯"的是 **③**:大厅分支
	#   自己 `set_process(false)` ⇒ `_process` 在**结构上**不再跑,门控写得多歪都无所谓。
	#   故 ③ 才是那条底线,①② 是 belt(它们挡的是"门写成否定式"这一**类**里最直白的那几种)。
	#
	# ★★ **上一版在注释里撒过谎,别照那句读**(2026-09-28 重审订正):它写着"对改名 / 重排合取项 /
	#   抽 helper 免疫",实际只做到了**改名**(而且连 `var X: bool = false` 这种写法都不认)。
	#   它取门控的办法是**切到第一个合取项**(`gate.split(" and ")[0]`)再判那一个是不是实例标志 ⇒
	#     · `elif not _match_started and _worker and _host == null:`(**语义等价且安全**)取到
	#       `not _match_started` ⇒ 假红「门控是否定式」;
	#     · 把条件抽成 helper(`elif _should_timeout_1v1():`)⇒ 假红「不是实例标志」。
	#   假红会招来错误的补救(「把守卫放松点」)—— 与探针纪律相悖。现在判**整条**条件,
	#   且门控若只是一句裸的**零参 helper 调用**,就顺着它的那一条 `return` 再判一层(只一层)。
	#
	# ★ **今天真正覆盖到的 / 仍看不见的**(照实,别夸大):
	#   覆盖 = 标志改名、合取项重排、`not _match_started` 这类**对非 worker-only 标志**的否定、
	#          `var X: bool = false` 写法、条件抽成**一层** helper(其函数体是**唯一**一条
	#          `return <整条条件>`)、`set_process(false)` 的挪位。
	#   看不见 = worker-only 标志**换名之后再取反**(文本判不出"谁是 worker-only",只认那三个名字)、
	#          两层以上的 helper 间接、helper 里有别的早退(那种 helper 体有不止一条 `return`,
	#          本守卫报红 —— 是**保守**方向)、`set_process(false)` **之前且锚点之上**的早退
	#          (如 `NetBus.start_server()` 失败那一支 —— 它同帧 `quit(1)`,梯子来不及点火,
	#          见 `server_main.gd` 那处的登记注释)。
	#   ★★ 判据**不覆盖**"门控那个标志真的被 `= is_worker` 赋过值"的**可达性**:`X = is_worker`
	#      只按文本判在位(写进一段永远走不到的分支里、或后面又被别处改掉,文本看不见)。
	#      这一条由本冒烟的**运行半场**兜底 —— 它等的就是那条梯在一个真 1v1 worker 上点火。
	#   最后一层仍是**真大厅存活**(手动 A/B,未进常驻测试)。
	var SU: GDScript = load("res://tests/lib/scan_util.gd")
	if SU == null:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(读不到 tests/lib/scan_util.gd —— 源码级门控检查无法进行)")
		quit(1)
		return
	var src: String = SU.read("res://server/server_main.gd")
	if src.is_empty():
		fails.append("读不到 server/server_main.gd —— 源码级门控检查无法进行(导出包里是二进制 token,本冒烟只在编辑器二进制下有效)")
	else:
		var code: String = SU.code_only(src)
		var view: String = SU.code_view(src)
		var body: String = SU.func_body(view, "_process")
		if body.is_empty():
			fails.append("★ 取不到 `server_main._process` 的函数体 —— 源码级门控检查无法进行")
		else:
			var gate := _ladder_gate(body, TIMEOUT_MARK)
			if gate.is_empty():
				fails.append("★ `_process` 里找不到 1v1 报到梯(判据是它打的那句 `%s`)" % TIMEOUT_MARK)
			else:
				_check_gate(gate, code, view, SU, fails)
		# 结构封闭:大厅那半边的**最后一道动作**必须关掉自己的 `_process`(与梯子极性无关的保险)。
		_check_lobby_process_off(SU.func_body(view, "_ready"), SU.func_body(view, "_run_worker"), fails)

	launcher.kill_worker(PORT)
	_finish(fails)


# ────────────────────────── 源码级判据 ──────────────────────────

# 判据 ①②的就地判 + **一层 helper 追索**。
# ★ 抽 helper 是**等价重写**、安全 —— 不能因为"门控里没有标志"就假红(那正是上一版的病)。
#   门控若只是一句裸的零参调用,就取 helper 体内**唯一**那条 `return <条件>` 再判一次。
func _check_gate(gate: String, code: String, view: String, SU, fails: Array[String]) -> void:
	var verdict := _gate_verdict(gate, code)
	if verdict == "":
		return
	var helper := _bare_call_name(gate)
	if helper == "":
		fails.append("★ 1v1 报到梯的门控 `%s` 不合格:%s" % [gate, verdict])
		return
	var hcond := _sole_return_condition(SU.func_body(view, helper))
	if hcond.is_empty():
		fails.append("★ 1v1 报到梯的门控是一句 helper 调用 `%s()`,但取不到它**唯一**的那条 `return <条件>` —— 本守卫追不下去(抽 helper 可以,但请写成 `return <整条条件>` 这一种形态)" % helper)
		return
	var v2 := _gate_verdict(hcond, code)
	if v2 == "":
		return
	fails.append("★ 1v1 报到梯的门控 `%s()` 不合格(其 `return` 条件 = `%s`):%s" % [helper, hcond, v2])


# 判据 ①②。返回 "" = 合格;否则返回**失败理由**(文中已含"该怎么改")。
func _gate_verdict(gate: String, code: String) -> String:
	var flag := _negated_worker_flag(gate)
	if flag != "":
		return ("它**否定**了 worker-only 标志 `%s` —— 大厅进程里该标志恒 false、取反恒真,"
				+ "大厅会开机 30 秒后打印报到超时并 quit(0) 自杀。门控要用**正的** worker 标志"
				+ "(见 `server_main.gd` 的 `_worker` 声明处注释)") % flag
	if not _has_instance_worker_flag(gate, code):
		return ("门控里找不到**正的实例 worker 标志**。要求:门控里至少有一个标识符 X,文件里有 "
				+ "`var X := false`(或 `var X: bool = false`)声明,**且**有 `X = is_worker` 赋值 "
				+ "(`_ready` 的局部量 `is_worker` 出不了函数,不能当门)")
	return ""


# 判据②:门控是否**否定**了某个 worker-only 标志。返回被否定的标志名,没有则 ""。
# ★ 只禁否定式、**不禁"以 `not` 开头"**:`not _match_started` 是正常写法,必须放行。
# ★ 正则容忍空白与一层括号 ⇒ `not (_royale or _team_mode)` 这个**同一语义换个拼写**的洞也咬得住
#   (旧版是靠"门控里有 `not `"抓它的,那与"否定的是 worker-only 标志"并不是一回事)。
# ★ 剩余边界照实:只认这三个**名字**,因此"给 worker-only 标志改名之后再取反"看不见
#   ("哪个标志是 worker-only"是语义,文本判不出来)。
func _negated_worker_flag(gate: String) -> String:
	for raw in ["_royale", "_team_mode", "_worker"]:
		var flag := str(raw)
		var re := RegEx.new()
		if re.compile("\\bnot\\s*\\(*\\s*%s\\b" % flag) != OK:
			continue
		if re.search(gate) != null:
			return flag
	return ""


# 判据①:门控里**至少有一个**标识符是"正的实例 worker 标志" —— 既要被声明成 false 初值的
# **实例字段**(排除 `_ready` 里的局部量 `is_worker`:那个出不了函数,门控里根本写不到它),
# 又要被 `= is_worker` 赋过值(光有个同名却没赋过值的死字段不算)。
# ★ 扫**门控里出现的每一个**标识符,不只第一个 —— 上一版栽的就是"只看首合取项"。
func _has_instance_worker_flag(gate: String, code: String) -> bool:
	for raw in _identifiers(gate):
		var name := str(raw)
		if not (code.contains("var %s := false" % name) \
				or code.contains("var %s: bool = false" % name)):
			continue
		if _has_assignment(code, name):
			return true
	return false


# 在**标识符边界上**找 `X = is_worker`。裸 `code.find` 会踩兄弟名(`_not_worker = is_worker`
# 里含 `_worker = is_worker` 这一子串 ⇒ 假绿;源码文本守卫最常见的失明方式之一)。
func _has_assignment(code: String, name: String) -> bool:
	var needle := "%s = is_worker" % name
	var i := code.find(needle)
	while i >= 0:
		if i == 0 or not _is_ident_char(code[i - 1]):
			return true
		i = code.find(needle, i + 1)
	return false


# 判据③:大厅那半边必须**在自己的尾部**关掉 `_process`。
# ★ 只判"文件里有 `set_process(false)`"是**位置不敏感**的(旧版就是这样):把那一行挪进
#   `_run_worker`(worker 也被关掉 tick ⇒ 报到梯永不点火),或在它上面插一条早退
#   (`return` 先于它生效 ⇒ 口子原样重开),两种改法都不会让"contains"变红。
func _check_lobby_process_off(ready_body: String, worker_body: String, fails: Array[String]) -> void:
	if ready_body.is_empty():
		fails.append("★ 取不到 `server_main._ready` 的函数体 —— 无法钉 `%s` 的位置" % PROCESS_OFF)
		return
	# ★★ `_run_worker` 取不到时**必须报红**,不能静默跳过下面那条否定断言:函数一改名/被内联,
	#   `worker_body` 就是空串,而 `"".contains(x)` 恒假 ⇒ 最后那条"不得出现在 `_run_worker` 里"
	#   会**静默放行**(把 `%s` 挪进 worker 那一支也照绿)。`_ready` 那半边一直有这条守卫,
	#   这里原先漏了 —— 同一件事一半严一半松,松的那半读起来完全一样。
	if worker_body.is_empty():
		fails.append("★ 取不到 `server_main._run_worker` 的函数体 —— 无法判 `%s` 有没有被挪进 worker 那一支(改名/内联?下面那条否定断言会因此**静默放行**)" % PROCESS_OFF)
		return
	var at := ready_body.find(PROCESS_OFF)
	if at < 0:
		fails.append("★ `%s` 不在 `_ready` 体内 —— 大厅那半边又敞开了(非 worker 进程会重新 tick `_process`,把「非 worker 进程进梯」这个口子打开)" % PROCESS_OFF)
		return
	var anchor := ready_body.find(LOBBY_ANCHOR)
	if anchor < 0:
		fails.append("★ `_ready` 体内找不到 `%s` —— 无法判 `%s` 是不是落在**大厅分支**里(顺序断言会因此退化成恒真)" % [LOBBY_ANCHOR, PROCESS_OFF])
		return
	if at < anchor:
		fails.append("★ `%s` 排在 `%s` **之前** —— 它不在大厅分支的尾部" % [PROCESS_OFF, LOBBY_ANCHOR])
		return
	if ready_body.substr(anchor, at - anchor).contains("return"):
		fails.append("★ `%s` 与 `%s` 之间有一条 `return` —— 那条早退会**跳过** `%s`,口子原样重开(位置钉的就是这一件事)" % [LOBBY_ANCHOR, PROCESS_OFF, PROCESS_OFF])
		return
	if worker_body.contains(PROCESS_OFF):
		fails.append("★ `%s` 出现在 `_run_worker` 体内 —— worker 也被关掉了 tick,报到梯永远不会点火" % PROCESS_OFF)


# 门控若只是"一句裸的零参调用"(`_should_timeout_1v1()`),返回函数名;否则返回 ""。
func _bare_call_name(gate: String) -> String:
	var re := RegEx.new()
	if re.compile("^([A-Za-z_][A-Za-z0-9_]*)\\(\\)$") != OK:
		return ""
	var m := re.search(gate)
	return m.get_string(1) if m != null else ""


# helper 体里**唯一**那条 `return <条件>` 的条件文本(0 条或多条都返回 "" ⇒ 调用方报红)。
func _sole_return_condition(body: String) -> String:
	if body.is_empty():
		return ""
	var found := ""
	var n := 0
	for raw in body.split("\n"):
		var s: String = raw.strip_edges()
		if s.begins_with("return "):
			n += 1
			found = _squeeze_ws(s.substr(7))
	return found if n == 1 else ""


# 从 `_process` 的函数体(必须是 `ScanUtil.code_view` 的**保缩进**视图)里,取「1v1 报到梯」
# 那支的**整条门控表达式** —— 不是第一个合取项(旧版切 `split(" and ")[0]`,那是过拟合)。
# 两步:
#   ① 从打印 `mark` 的那行**向上**找**最外层**的包围分支(缩进比已经见过的都浅)—— 打印外面还套着
#      一层 `if _understaffed_wait > 30.0:`,那层要跨过去,否则取到的是**计时阈值**而不是门控;
#   ② 从那一行起把**整条条件**拼出来(拼到第一个以 `:` 结尾的行为止)—— 多行条件(续行)一并收进来;
#      末尾的 `:` 是语句终止符、不属于条件。
# 返回 "" = 没找到(调用方报红)。返回文本已做**空白归一**:拼接残留的换行/制表符会让
# 下面那些按子串判"否定了哪个标志"的断言漏判 —— 那是源码文本守卫最常见的失明方式。
func _ladder_gate(body: String, mark: String) -> String:
	var lines := body.split("\n")
	var at := -1
	for i in range(lines.size()):
		if lines[i].contains(mark):
			at = i
			break
	if at < 0:
		return ""
	var gate_at := -1
	var floor_indent := _indent_of(lines[at])
	for i in range(at - 1, -1, -1):
		var s: String = lines[i]
		if s.strip_edges().begins_with("func "):
			break                                  # 到函数签名 = 再往上不是本函数了
		var ci := _indent_of(s)
		if ci >= floor_indent:
			continue                               # 同级/更深 = 本支(或更深分支)的内部,继续往上
		var stripped := s.strip_edges()
		if stripped.begins_with("if ") or stripped.begins_with("elif "):
			gate_at = i
		else:
			continue                               # 更浅但不是分支(不该有):继续往上找
		floor_indent = ci
	if gate_at < 0:
		return ""
	var first: String = lines[gate_at].strip_edges()
	var cond := first.substr(3 if first.begins_with("if ") else 5)
	var k := gate_at
	while not cond.strip_edges().ends_with(":"):
		k += 1
		if k >= lines.size():
			break
		cond += " " + lines[k].strip_edges()
	cond = cond.strip_edges()
	if cond.ends_with(":"):
		cond = cond.substr(0, cond.length() - 1)
	cond = cond.strip_edges()
	if cond.ends_with("\\"):                       # 多行条件的续行符(行尾 `\`)
		cond = cond.substr(0, cond.length() - 1)
	return _squeeze_ws(cond)


# 空白归一(换行/制表符/多空格 → 单个空格)。子串判据必须在归一后的文本上做。
func _squeeze_ws(s: String) -> String:
	var re := RegEx.new()
	if re.compile("\\s+") != OK:
		return s.strip_edges()
	return re.sub(s, " ", true).strip_edges()


# 门控文本里出现的标识符(逐字符切,不引正则:`_`/数字/字母 算标识符字符)。
func _identifiers(s: String) -> Array[String]:
	var out: Array[String] = []
	var cur := ""
	for i in range(s.length()):
		var ch := s[i]
		if _is_ident_char(ch):
			cur += ch
		else:
			if cur != "":
				out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


func _is_ident_char(ch: String) -> bool:
	return ch == "_" or (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")


func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# 轮询日志直到出现 `mark` 或超时;返回**最终**读到的全文(调用方自己判 contains)。
func _wait_for(path: String, mark: String, max_ms: int) -> String:
	var text := ""
	var waited := 0
	while waited < max_ms:
		OS.delay_msec(250)
		waited += 250
		text = _read(path)
		if text.contains(mark):
			break
	return text


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _finish(fails: Array[String]) -> void:
	if fails.is_empty():
		print("DUEL SPAWN TIMEOUT SMOKE: ALL-OK")
		quit(0)
	else:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
