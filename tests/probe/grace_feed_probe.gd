extends Node

# `grace` 字段进 `round_state` 的载荷面防御性校验(阶段 3,spec §4 的 3.1)。场景模式、headless。
#
# 运行方式：
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/grace_feed_probe.tscn
# 验收标准：末行 `GRACE FEED PROBE: ALL-OK`。
#
# ── 为什么不能用源码断言代替 ──
# "三个生产者调了 `_send_round_state`"是文本判定条件(写在 tests/probe/reconnect_status_probe 里),
# 它拦不住"并进去的时机/条件写错了"(比如空表也带键、或者读的是别的字段)。本探针实际创建一个
# `MatchHost`(role_peers 传空 —— 同 `match_host_hygiene_probe` 的手法:宿主不建玩家、不排
# peer、所有 rpc_id 静默提前返回;⑥ 那相自己往 `host.players` 里摆一具,见该处注释),用
# 子类覆写 `_rpc_all` 截获真正要发出去的那份载荷(同 `stats_delivery_probe` 的手法),
# 在调用时刻深拷贝。
#
# 注意事项：本探针的双向逻辑(2026-09-28 二次评审后补 ⑤/⑥),别把其中一半当成另一半的替代:
#   - ①②③ —— 载荷面:字段进不进载荷、空表带不带键。**(下面这段"为什么不能用源码断言
#     代替"说的就是它。)**
#   - ④⑤ —— 源码级:唯一出口 / 每一处广播都带自己那一份读数刷新。
#   - ⑥ —— 行为面:真驱动 `_on_reclaim` 的接受路径,读实际要发出去的那份载荷。
#    ->  ⑤ 与 ⑥ 互补,不是重复:⑤ 看不见控制流(`if cond:` 里的条件刷新它保持测试通过),⑥ 不在乎
#     文本(删掉那一行刷新则直接断言失败)。哪一半缺了,那一类改法就无人拦。
const MAP := "res://maps/newfactory.cyrm"
# - 计数法(逐条点实跑的 `_check`,不是数源码里的出现次数):① 1 + ② 1 + ③ 1 + ④ 1 + ⑤ 1
#   + ⑥ 4(仪器:`_enter_grace` 的载荷里这个人在宽限里 / 接受路径确实走到了 / reclaim 那一发
#     确实广播了 + 主断言:`after` 里不得有他)= 10。
const EXPECTED_CHECKS := 10

# 覆写 `_rpc_all` 的宿主:`_send_round_state` 内部调的就是它,故这里的截获是生产路径上的,
# 不是探针自己模仿出来的第二份。
class CaptureHost extends MatchHost:
	var last_round_state: Dictionary = {}
	var round_state_count := 0

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			round_state_count += 1
			last_round_state = (args[0] as Dictionary).duplicate(true)
		# 不调 super:本探针不排 peer,rpc 本来也发不出去(调了只是白扫一遍空表)。


var _checks := 0
var _fails: Array[String] = []
var _host: CaptureHost = null


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _ready() -> void:
	_host = CaptureHost.new(MAP, {})
	add_child(_host)
	# - 关掉服务器每帧编排:本探针手工驱动,不关的话 `_physics_process` 会自己去广播快照 /
	#   推进回合计时(同 `match_host_hygiene_probe`、`team_disconnect_probe` 的手法)。
	_host.set_physics_process(false)

	# ── ① `_ready` 那条广播:没人掉线  ->  不带 `grace` 键 ──
	_check(_host.round_state_count >= 1, "`_ready` 广播了 round_state(计数 %d)" % _host.round_state_count)
	_check(not _host.last_round_state.has("grace"),
			"★ 空读数**不得**带 `grace` 键(spec 的同款纪律:destroyed/teams/stats 都是非空才带;实得 %s)"
			% str(_host.last_round_state.keys()))
	# ── ② 推入读数  ->  载荷里出现 `grace`,值与推入的逐字相同 ──
	_host.grace_snapshot = {1: 42.5}
	_host._broadcast_round_state()
	_check(_host.last_round_state.get("grace", {}) == {1: 42.5},
			"★ 非空读数必须进载荷(实得 %s)" % str(_host.last_round_state.get("grace", {})))
	# ── ③ 清空读数  ->  键又消失(不是"带着一个空字典")──
	_host.grace_snapshot = {}
	_host._broadcast_round_state()
	_check(not _host.last_round_state.has("grace"),
			"读数清空后键必须消失(实得 %s)" % str(_host.last_round_state.keys()))
	# ── ④ 源码级:三个生产者都走唯一出口,且生产目录里再没有第二处 round_state 发送 ──
	_check(_funnel_is_the_only_emitter(),
			"★ `round_state` 的唯一出口被绕过:tests 的日志里有逐条读数")
	# ── ⑤ 源码级:每一处 `_broadcast_round_state()` 之前都先刷过宽限读数 ──
	_check(_every_broadcast_precedes_with_grace_sync(),
			"★ 有 `_broadcast_round_state()` 的调用点没带**自己那一份** `_sync_grace_snapshot()`"
			+ "(载荷里的掉线态是旧值)")
	# ── ⑥ 行为面:`_on_reclaim` 接受路径的载荷里不得把刚回来的人继续列成「掉线中」──
	# - ⑤ 是文本判定条件,看不见控制流(见它上方的"看不见"清单);真正关掉那个洞的是本阶段。
	_phase_reclaim_payload()

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上 —— 要么有断言被静默跳过、"
				% [_checks, EXPECTED_CHECKS]
				+ "要么有新断言没登记进 EXPECTED_CHECKS(helper 里的脚本错误只让那个函数当场结束、"
				+ "调用方照常往下走,`_fails` 不会非空)")
	if _fails.is_empty():
		print("GRACE FEED PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("GRACE FEED PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 生产目录里 `_rpc_all("round_state"` 必须除出口自身外零命中(三处生产者都改走了
# `_send_round_state`),而三个生产者都必须含 `_send_round_state(`。
# 注意事项：那唯一一处命中就是出口自己的函数体(`server/match_state.gd` 的 `_send_round_state`),
#   故下面的第二个循环对 `match_state.gd` 显式放行 —— 它是出口的实现,不是漏网的旁路。
#   权威措辞与理由写在该函数上方那段注释里(`server/match_state.gd`,「除出口自身外零命中」;
#   - 只写符号名不写行号 —— 行号在这类文件里是负资产)。别把"零命中"当真去删掉那一行
#   (删了 `round_state` 一个字节都发不出去,而三个生产者各自的文本断言照样全部断言通过)。
#
# 注意事项：这条断言能看见什么、看不见什么(与 ⑤ 那份清单相同处理逻辑,别把它读成"生产目录全扫过"):
#   能看见:
#     - 下面那份硬编码复制的四文件名单里,三个生产者各自走了唯一出口、且没绕过它。
#     - 名单里任一文件读不到(空串) ->  红(不是静默跳过)。
#   看不见(名单是硬编码的,扫描面 = 名单本身):
#     - 一个新增的生产者文件(比如将来给第四种模式加一个 `*_host.gd` 去拼 `round_state`):
#       它根本不在名单里,这条断言一行都不会红 —— 新文件里直接
#       `_rpc_all("round_state", …)` 绕过出口,而这里照旧 `ALL-OK`。
#     - 名单里某个文件改名/搬家:旧路径读不到会红(那一半是安全的),但"改到新名字后
#       没登记进来"就又回到上一条。
#     - `grace` 并进去的时机/条件:本函数是纯文本判定条件,控制流一概看不见(那正是 ⑥ 的存在理由)。
#    ->  它是"今天这四个文件"的防御性校验,不是"生产目录"的防御性校验。 加新生产者时必须回来把路径补进
#     下面那两个数组 —— 补漏了不会有任何东西提醒。-  `tests/probe/reconnect_status_probe` 的阶段 2b
#     约束的是同一份「三个生产者」集合(它那份名单同样要补;本函数多一个 `match_state.gd`,
#     那是出口自身所在的文件,两边不是同一张表,别把这句话读成"共用一份常量")。
func _funnel_is_the_only_emitter() -> bool:
	var ok := true
	for p in ["res://server/match/match_state.gd", "res://server/match/match_round.gd",
			"res://server/hosts/royale_host.gd", "res://server/hosts/team_host.gd"]:
		var c := _code(p)
		if c.is_empty():
			print("    ✗ 读不到 %s" % p)
			ok = false
			continue
		if p != "res://server/match/match_state.gd" and not c.contains("_send_round_state("):
			print("    ✗ %s 没走 `_send_round_state(`" % p)
			ok = false
	for p in ["res://server/match/match_round.gd", "res://server/hosts/royale_host.gd",
			"res://server/hosts/team_host.gd", "res://server/match/match_state.gd"]:
		var c := _code(p)
		# match_state.gd 里那一处就是出口自身的实现,故放行
		if p == "res://server/match/match_state.gd":
			continue
		if c.contains("_rpc_all(\"round_state\""):
			print("    ✗ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)
			ok = false
	return ok


# ── ⑤ 的不变量 ────────────────────────────────────────────────────────────────
# 同一个函数体内,每一处 `_broadcast_round_state()` 之前都必须先调过
# `_sync_grace_snapshot()`。载荷里那个 `grace` 字典是 `MatchState.grace_snapshot` 的当前值,
# 而读数只在三处写:`_enter_grace`、`_expire_graces`、以及 `_process` 里每秒一次的保鲜。
# 广播点漏刷的后果(两处都是"删掉不报错"):
#   - `_on_reclaim`:上面刚 `_grace.leave(role)`,不刷  ->  载荷把这个刚回来的人继续列成
#     「掉线中(还剩 N 秒)」;而 1v1 / 3v3 的 `round_state` 只在状态跃迁时发、此后**没有任何
#     东西会重发**  ->  那个错值会一直挂到下一次击杀 / 换局(2026-09-28 修的正是这一处)。
#   - `_enter_grace`:进入重连宽限期后不刷  ->  载荷里不出现这个人的掉线态,客户端那行「掉线中」不亮。
# - 走 `code_only` 视图:注释里提到这两个名字不算数 —— 这条断言的形状恰恰是"读起来像
#   覆盖、实际被一句注释喂饱"的那一类。
#
# 注意事项：判定依据为「每一处广播都带自己那一份刷新」,不是"函数里存在过一次刷新"。
#   - 为什么不能只写"整个函数里 `sync` 在 `at` 之前":那样第二处广播会被第一处那次刷新
#     喂饱(实测:`find` 出来的第一处广播恒是最靠左的那个  ->  "只钉第一处"与"逐处都钉、但
#     判定条件仍是'函数里存在一次刷新'"判定结果逐字等价,迭代全部调用点一格都多抓不到)。
#     故本函数的判定依据为:第 i 处的刷新必须落在 `(第 i-1 处的位置, 第 i 处的位置)` 这个开区间
#     里(第一处则落在 `[0, 第一处)`)。 ->  在同一个函数里新增第二处广播而没配刷新 = 红。
#   - 代价照实说:紧接着第一处广播再写一处广播、中间没有任何刷新也会红 —— 那是**有意的
#     保守**(今天两处调用点各自只带一处广播,不存在这种写法;真出现了,补一行刷新就不红)。
#
# 注意事项：这条断言能看见什么、看不见什么(2026-09-28 二次评审后逐条写清 —— 上一版把它吹成
#    「扫所有调用点 …将来新增第三处也会被咬住」,而实现只 `find` 了第一处、计数器还
#    按函数加一,且判定条件本身对第二处始终为 true  ->  那句话是过度承诺,已订正):
#   能看见:
#     - 每个函数里的每一处 `_broadcast_round_state()`,且逐处要求它自己那一份刷新。
#     - 调用点被整体删光 / 接收者被改名(`sites == 0` 反向断言)。
#   看不见(纯文本序,没有任何控制流/数据流分析):
#     - 条件刷新:`if cond: _sync_grace_snapshot()` 之后紧跟广播 —— 文本上"刷新在广播之前"
#       成立,而 `cond` 为假的那些路径上载荷仍是旧值(这正是上一版"函数级不是块级"那句背后
#       真正的洞,而『函数级/块级』这个说法把它说小了 —— 它不是"块",是控制流本身)。
# 注意事项：这一格只有行为面拦得住,见 ⑥;⑤ 与 ⑥ 是互补的双向逻辑,不是重复。
#     - 无引用冗余代码也算数:`if false: _sync_grace_snapshot()` / 永不进入的分支里的刷新同样能让
#       本断言绿 —— 它只看见"这一行在广播之前",看不见那一行会不会被执行。
#     - 刷新与广播不在同一个函数里(广播搬进 helper / 经另一个方法间接调):本断言只看
#       函数体文本,跨函数看不到。
#     - 函数边界本身:`_func_blocks` 按"列 0 的 `func `"切块,嵌套类/lambda 里的方法会被
#       切出来当独立块(对本断言无害 —— 多扫到不含广播点的块而已);但函数体跨多行的续行、
#       或把广播写在 `class` 声明块里(本文件没有这种写法)不在它的射程内。
#     - `code_only` 保留字符串字面量:字面量里若写着带括号的 `"_broadcast_round_state()"`,
#       它会被当成一个调用点  ->  测试误报。今天 `server_main.gd` 里那两处是
#       `has_method("_broadcast_round_state")`(不带括号),匹配不上,故无此风险;给这条
#       断言写"带括号的自引用字面量"时要知道它会自己咬自己(或改成只在 `has_method(` 之后
#       的那种字面量上放行)。
func _every_broadcast_precedes_with_grace_sync() -> bool:
	var c := _code("res://server/server_main.gd")
	if c.is_empty():
		print("    ✗ 读不到 res://server/server_main.gd")
		return false
	var ok := true
	var sites := 0
	for f in _func_blocks(c):
		var body: String = f["body"]
		var n := 0
		var prev := -1      # 上一处广播的位置(-1 = 还没有);本处的刷新必须晚于它
		var at := body.find("_broadcast_round_state()")
		# - 逐调用点扫(不是逐函数),且逐处要求自己那一份刷新(见上方长注释)。
		while at >= 0:
			n += 1
			sites += 1
			var sync := body.find("_sync_grace_snapshot()", prev + 1)
			if sync < 0 or sync > at:
				print("    ✗ %s() 里第 %d 处 `_broadcast_round_state()` 没有**自己那一份** "
						% [f["name"], n] + "`_sync_grace_snapshot()`(载荷里的掉线态是旧值)")
				ok = false
			prev = at
			at = body.find("_broadcast_round_state()", at + 1)
	# - 反向校验：若未匹配到任何调用点，表明静态扫描目标可能已变更（如函数重命名），会导致循环未执行而产生假阳性通过。
	if sites == 0:
		print("    ✗ 一处 `_broadcast_round_state()` 都没扫到 —— 这条断言在空转")
		ok = false
	return ok


# ── ⑥ 行为面:`_on_reclaim` 接受路径的载荷(2026-09-28 二次评审后补)────────────
# ⑤ 是文本判定条件,它看不见控制流:`if cond: _sync_grace_snapshot()` 紧跟广播在文本上完全满足
# "刷新在广播之前",而 `cond` 为假的路径上载荷仍是旧值。把那个洞真关掉的是本阶段 ——
# 行为不在乎文本:它真驱动 `_on_reclaim` 的接受路径,读实际要发出去的那一份载荷。
# 注意事项：本阶段的核心价值在于反向对照验证：若将 `_on_reclaim` 中的 `_sync_grace_snapshot()` 移除，
#    主断言必须能够精确触发失败（检测到目标玩家仍残留且剩余秒数为正，精确复现缺陷场景）；
#    恢复代码后断言应重新通过。若缺少该反向对照，测试将退化为无法检出缺陷的无效断言。
#
# 手法:真宿主(`CaptureHost`,覆写 `_rpc_all` 截获)+ 真 `_on_reclaim`。
#   - `server_main.gd` 的实例不加入场景树:它的 `_ready` 会 `ProcUtil.kill_udp_port(7777)` 并把
#     大厅起起来 —— 那是用户自己的服务端,探针不许碰(与"探针不占 7777"同一条纪律)。
#     本阶段只调 `_on_reclaim` 这一个函数,而它的接受路径逐项核对过不碰树:
#     `_host.players[role]` / `_host.input_sources` / `_pending_input` / `_ack_seq` / `_grace` /
#     `MazeGenerator.map_file_path()`(静态)/ `NetBus.reply`(本进程 `multiplayer_peer` 为 null
#      ->  `is_peer_live` 恒 false  ->  静默返回 false,不发包)。
#   - 拒绝路径够不到 —— 它是唯一碰 `multiplayer`(`disconnect_peer`)的地方,而本阶段三条
#     前置(已开局 / 在宽限里 / token 相符)都满足;真走岔了,那条调用会当场报错而不是静默。
#   - 三条前置由 `_match_started` / `_enter_grace(role)` / `_tokens[role]` 造出来 —— 全是**生产
#     路径上的写法**,不是给探针开的旁路。
func _phase_reclaim_payload() -> void:
	var sm: Node = (load("res://server/server_main.gd") as GDScript).new()
	var host := CaptureHost.new(MAP, {})
	add_child(host)
	host.set_physics_process(false)
	var role := 1
	var p = (preload("res://scenes/player/player.tscn") as PackedScene).instantiate()
	host.add_child(p)
	var src := PacketInputSource.new()
	p.set_input_source(src)
	p.set_physics_process(false)
	host.players[role] = p
	host.input_sources[role] = src
	sm._host = host
	sm._match_started = true      # 判定条件①
	sm._tokens[role] = "tok-1"    # 判定条件③
	# 造出 bug 的现场:按生产路径进入重连宽限期(`_enter_grace` 末尾自己刷读数 + 广播) -> 
	# 此刻载荷里这个人在「掉线中」,而下面 `_on_reclaim` 的接受路径要把他放出来。
	sm._enter_grace(role)
	var before := _grace_of(host.last_round_state)
	_check(before.has(role),
			"★ [仪器] `_enter_grace` 那一发载荷里这个人在「掉线中」(实得 grace=%s;若为空,"
			% str(before) + "下面那条主断言就是恒绿的摆设)")
	host.round_state_count = 0
	sm._on_reclaim(1, role, "tok-1")
	_check(not sm._grace.has(role),
			"★ [仪器] 走的是**接受**路径(接受后宽限表里必须没这个人;实得 has=%s)"
			% str(sm._grace.has(role)))
	_check(host.round_state_count == 1,
			"★ [仪器] reclaim 那一发确实广播了一次 round_state(实得 %d;若为 0,主断言读到的就还是"
			% host.round_state_count + " `_enter_grace` 那份旧载荷 ⇒ 会**假红**)")
	var after := _grace_of(host.last_round_state)
	_check(not after.has(role),
			"★★ 主断言:`_on_reclaim` 接受路径的载荷**不得**把刚回来的人列成「掉线中」(实得 grace=%s)"
			% str(after))
	sm.free()


# 载荷里的 `grace` 字典(缺席  ->  空字典,与 `GraceWindow.merge_into` 的"非空才带键"同口径)。
func _grace_of(payload: Dictionary) -> Dictionary:
	var g: Dictionary = payload.get("grace", {})
	return g.duplicate()


# 把剥注释后的源码切成 `[{name, body}]`。`code_only` 已 strip_edges,故"列 0 的 `func `"
# 就是函数起点(嵌套类/lambda 的方法也会被切出来,对本断言无害 —— 多扫到不含广播点的块而已)。
func _func_blocks(code: String) -> Array:
	var out := []
	var name := ""
	var buf: Array[String] = []
	for line in code.split("\n"):
		if line.begins_with("func "):
			if name != "":
				out.append({"name": name, "body": "\n".join(buf)})
			name = line.substr(5, line.find("(") - 5)
			buf = []
		elif name != "":
			buf.append(line)
	if name != "":
		out.append({"name": name, "body": "\n".join(buf)})
	return out
