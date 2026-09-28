extends SceneTree

# 「1v1 worker 在**一个 claim 都没有**时会自己退出」—— 真拉起一个 worker,再读它自己的日志。
# 跑法: source tests/env.sh && timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd
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


func _initialize() -> void:
	# ★ 空载守卫:load 失败立刻 quit(1),否则后面抛错走不到 quit() → 进程**永久挂起**。
	var L: GDScript = load("res://server/worker_launcher.gd")
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
	#   大厅进程里四个合取项**全成立** ⇒ `start_server.bat` 起的大厅会在 30 秒后 quit(0) 自杀
	#   (实测发生过)。⇒ 唯一能自动拦住它的是**源码级**检查。
	#
	# ★★ 判的是**语义不变量**,不是字面行(2026-09-28 重审后改写)。旧版钉死了
	#   `elif _worker and not _match_started and _host == null:` **整行**、并禁掉 `elif not _royale and not _team_mode`
	#   这一个字面写法 —— 那是**过拟合**,不是"看不见":任何等价重写(抽出 helper / 给标志改名 /
	#   调换合取项顺序)都会**假红**,连注释里逐字引用旧 bug 的形状也会红(旧版读的是**含注释**的全文)。
	#   假红会招来错误的补救(「把守卫放松点」)—— 与探针纪律相悖。现在的三条判据:
	#     ① `_process` 体内**不得**出现 `not _royale`(梯子不得以 worker-only 标志的否定为门);
	#     ② 1v1 报到梯的门控必须是**正的实例标志** —— 标识符是从梯子那行**就地取**的(不钉名字,
	#        改名照绿),且文件里确有 `var <名> := false` 声明(防它退化成 `_ready` 里的局部量:
	#        `is_worker` 正是出不了 `_ready` 的那个);
	#     ③ 文件里有 `set_process(false)`(大厅那半边的结构封闭,与极性无关)。
	#   ★ **不覆盖**:把判据整个搬进别的函数、或换个变量名再取反 —— 那一类由真大厅存活兜
	#     (A/B 手动跑,`EXIT=124`;未进常驻测试)。
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
		var body: String = SU.func_body(SU.code_view(src), "_process")
		if body.is_empty():
			fails.append("★ 取不到 `server_main._process` 的函数体 —— 源码级门控检查无法进行")
		elif body.contains("not _royale"):
			fails.append("★ 报到梯又用回了 worker-only 标志的**否定** —— 大厅进程里它恒真,会在 30 秒后 quit(0)")
		else:
			var gate := _ladder_gate(body)
			if gate.is_empty():
				fails.append("★ `_process` 里找不到 1v1 报到梯(判据是它打的那句 `1v1 报到超时`)")
			elif gate.begins_with("not") or gate.contains("not "):
				fails.append("★ 1v1 报到梯的门控是**否定式**(`%s`)—— 大厅进程里它恒真,会在 30 秒后 quit(0)" % gate)
			elif not code.contains("var %s := false" % gate):
				fails.append("★ 1v1 报到梯的门控 `%s` 不是实例标志(文件里没有 `var %s := false`)" % [gate, gate])
		# 结构封闭:大厅分支必须关掉自己的 `_process`(与梯子极性无关的那一层保险)。
		if not code.contains("set_process(false)"):
			fails.append("★ 大厅分支缺 `set_process(false)` —— 非 worker 进程又会 tick `_process`,把「非 worker 进程进梯」这个口子重新打开")

	launcher.kill_worker(PORT)
	_finish(fails)


# 从 `_process` 的函数体(必须是 `ScanUtil.code_view` 的**保缩进**视图)里,取「1v1 报到梯」
# 那支的**门控标识符**(如 `_worker`)—— 不钉名字、不钉整行,等价重写照绿。
# 做法:定位该支体内那句 `1v1 报到超时` 的 print,再**向上找最外层的包围分支**
# (`if `/`elif `,且缩进比当前见过的都浅),取它条件的第一个合取项。
# 返回 "" = 没找到(调用方报红);返回以 `not` 开头 = 门控是否定式(调用方报红)。
func _ladder_gate(body: String) -> String:
	var lines := body.split("\n")
	var at := -1
	for i in range(lines.size()):
		if lines[i].contains("1v1 报到超时"):
			at = i
			break
	if at < 0:
		return ""
	var gate := ""
	var floor_indent := _indent_of(lines[at])
	for i in range(at - 1, -1, -1):
		var s: String = lines[i]
		if s.strip_edges().begins_with("func "):
			break                                  # 到函数签名 = 再往上不是本函数了
		var ci := _indent_of(s)
		if ci >= floor_indent:
			continue                               # 同级/更深 = 本支的内部,继续往上
		var stripped := s.strip_edges()
		if stripped.begins_with("if "):
			gate = stripped.substr(3)
		elif stripped.begins_with("elif "):
			gate = stripped.substr(5)
		else:
			continue                               # 更浅但不是分支(不该有):继续往上找
		floor_indent = ci
	return gate.split(" and ")[0].strip_edges()


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
