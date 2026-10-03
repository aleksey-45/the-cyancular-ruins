extends ProbeBase

# KH 合并 L5 验收探针(场景模式:autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 600 res://tests/probe/kh_l5_probe.tscn
# 期望:每条 [L5] ... 通过,末行 "KH L5 PROBE: ALL-OK",退出码 0。
#
# 存在理由:L5(大乱斗 = royale)把 MatchHost 开成了 RoyaleHost 的基类,并在 main 上追加
# 了一批新接口。这些交付里有一大半是**"某段既有代码必须一个字都没动"**或**"某样东西
# 全仓只剩一处"**——没有运行时入口,只能在源码层机械扫描。本探针就是那台扫描仪:
#   1) ★ C2 rollback 四条在位 + 生产侧 _on_input 入队(server/match_host.gd)。L5 给 MatchHost
#      加了 RoyaleHost 扩展点,硬约束是「**只追加**,不碰 C2 四条」;本探针是这条约束的长期守卫:
#      · 每物理 tick 每 role 恰好消费 1 个 FIFO 输入包(q.pop_front + _ack_seq 更新)
#      · 60Hz 快照**先于**输入消费(否则 ack 领先权威状态一拍 → 移动中每次快照误判分歧)
#      · 快照载荷同时带 ack_seq 与权威整态 c2
#      · COUNTDOWN 分支清队列 **且** src.reset_state()
#      · _on_input 只把到达的包**入队**(不得就地 apply / 丢队列)——前四条只管消费侧,
#        单独改坏生产侧能全绿(见该断言的注释)
#   2) main 既有成果在位(server/room_manager.gd 的 sweep 族 —— 1v1 / 大乱斗 / 3v3 三张
#      注册表都要被扫到 + _kill_worker)
#   3) server_main 的 _kill_port_holder 取属主进程用修正版(不是取不到属性的 % 写法)
#   4) ★ 零演示残留(生产目录)
#   5) ★ CombatFeedback.spawn 全仓生产路径恰好 1 处,且在 scenes/level_0.gd
#   6) 大乱斗非射手端激光走 NetBus(不是 NetBusExt —— 收错节点会静默 no-op)
#   7) AI 输入源 is_network_driven() 覆写存在且返回 true
#   8) ★ 字号规范:全仓所有字号载体都是 16 的倍数(**含经 helper 实参传递的字号**)
#      ★ 2026-10-03 扩扫描面:**.tscn 与 .tres 也扫** —— 字号正在搬进 `.tscn`(控件的
#        `theme_override_font_sizes/font_size = N`)与 `.tres`(Theme 的
#        `Body/font_sizes/font_size = N`)。`ScanUtil.walk` 只收 .gd/.tscn ⇒ `.tres` 必须
#        **显式补进扫描面**,否则「16 的倍数」这条规则会**看起来还在守、其实空了**。
#        配套加了两条防空转的闸:① 载体**总数下限**(见 MIN_FONT_CARRIERS);
#        ② `.tscn` 里 `theme_type_variation` 引用的变体名必须在某个 Theme 里有定义。
#   9) 新接口在位且归属正确(+ 反向断言:基类不得含子类方法)
#  10) ★ MatchHost 的 round_full_heal 选项真的把双方回满血(端到端 + 对照组)
#
# --quit-after 是安全网:本脚本引用 MatchHost 等标识符;若某处解析失败,场景根节点没有
# 脚本 → 一行都不打印、命令挂死。有它最坏只是超时退出。
#
# ⚠ CI 判据必须是 **grep 文本 `KH L5 PROBE: ALL-OK`**,不能只看退出码:
#    探针中途脚本报错时 --quit-after 仍以 exit 0 退出,退出码与"跑通了"不可分。
#    ★★ 2026-09-28 订正(取代旧版"这时**不会**打印 ALL-OK",实测已推翻):运行期脚本错误
#    **只让出错的那个函数当场结束、调用方继续** ⇒ verdict **照打 `ALL-OK`**、被跳过的组静默变绿;
#    故该行只证明"**没有任何断言失败**",**不证明"该跑的断言都跑过"**(权威:`tests/lib/probe_base.gd`)。
#
# ⚠⚠ 自伤防护(本文件被自己扫描,务必守住):凡是本探针**要找的字面量**,一律用
#    `"前" + "后"` 碎片拼出来,绝不整段写在源码里 —— 第 4/5 条扫的是**目录树**、
#    第 8 条扫的是**全仓(含 tests/)**,整段写在源码里会被自己命中(假绿或假红)。
#    第 8 条更狠:它还会把本文件里的示例当数据扫,连合成样例的数字都走 str(4*5) 生成。

# 生产目录(第 4/5 条只扫这些;排除 tests/ 以免探针自身的负断言文本自伤)
const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui"]
# 全仓扫描根(第 2/8 条:字号与私有残留要看整仓,含 tests/)
const ALL_DIRS := ["res://core", "res://scenes", "res://server", "res://ui",
		"res://tests"]

# 扫描到的源文件数下限:防止"扫描根本坏了 → 一个文件都没扫到 → 零命中 = 假绿"
const MIN_PROD_FILES := 40
const MIN_ALL_FILES := 60

# ── 第 8 条(字号规范)新增的两道防空转闸 ──
# ① **载体总数下限**。文件数下限(MIN_ALL_FILES)管的是"根扫不扫得到",管不到"载体一类
#    都匹配不上":路径/后缀/剥注释视图任一环坏掉 ⇒ 命中 0、`bad` 恒空 ⇒ verdict 照打
#    ALL-OK —— 正是本仓登记过十次的「守卫比它读起来弱」。故把**总量**打出来并设下限。
#    今日实测(2026-10-03,把 .tres 补进扫描面后)总量 = **97**(.gd/.tscn 90 + .tres 7),
#    取 70 留健康余量(只拦"整体坏掉",不拦正常增删)。
const MIN_FONT_CARRIERS := 70
# ② Theme 资源的字号落点。第 8 条要求它**确实被扫到**(载体数 ≥1)—— 否则 `.tres` 那一支
#    其实没生效,而"读不到 .tres"与"扫坏了"在 verdict 上长得一样(都会静默通过)。
const THEME_FONT_FILE := "res://ui/theme/menu_theme.tres"

# L5 新增的、带字号的 UI 文件:第 8 条要把它们的字号覆盖情况打出来(人眼可核覆盖面)
const L5_FONT_FILES := ["res://ui/hud/royale_hud.gd", "res://scenes/mp_lobby.gd"]

# ── 扫描针(碎片拼接:见文件头「自伤防护」)──
# 常量名**不得**含连写的 FONT_SIZE:第 8 条的 D 类扫描会把 "以 const 开头且含 FONT_SIZE"
# 的本探针常量当成字号声明,读不出数值 → 本探针自伤(假红)。
const N_STYLE_CONTROL := "style" + "_control("
const N_STYLE_CONTROL_RE := "style" + "_control\\("
const N_FONT_OVERRIDE := "add_theme" + "_font_size_override("
const N_FONT_OVERRIDE_RE := "add_theme" + "_font_size_override\\("
const N_FACTORY := "Ui" + "Factory."
const N_WEAPON_CHECK := "make_weapon" + "_check("
const N_FONT_SZ_ASSIGN := "font" + "_size\\s*=\\s*([0-9]+)"
const N_FONT_SZ_CONST := "FONT" + "_SIZE"
const N_CONST_DECL := "^const\\s+\\w*FONT" + "_SIZE\\w*\\s*:?=\\s*([0-9]+)"

# ── MatchHost 的源码**并集** ──
# ★ 2026-09-15(阶段 5.6):权威按域拆成一条继承链 ——
#   RoyaleHost → MatchHost(核心) → MatchRound(回合) → MatchCombat(裁决)
#   → MatchSnapshot(快照) → MatchState(共享状态+RPC 助手) → Node
# 本探针的判据是**按职责**写的,所以取源也要跟着改成并集:只读 match_host.gd 的话,
# 那些 needle 在新家找不到 → **门恒绿、静默失明**(仓内已登记过的失败模式)。
# 这不是放水 —— 被守的东西一个字没变,只是它现在住在链上的哪一层而已;
# 反向断言(基类不得含 RoyaleHost 的子类方法)反而更严了:五份都查。
const HOST_SRC := ["res://server/match/match_host.gd", "res://server/match/match_round.gd",
		"res://server/match/match_combat.gd", "res://server/match/match_snapshot.gd",
		"res://server/match/match_state.gd"]


func _host_code() -> String:
	var parts: Array[String] = []
	for f in HOST_SRC:
		parts.append(_code_only(_read(f)))
	return "\n".join(parts)


# 探针短名:拼 ALL-OK / FAIL / 汇总行的方括号前缀用(ProbeBase 的必需覆写项)。
func probe_id() -> String:
	return "L5"


func _ready() -> void:
	_check_c2_contract()
	_check_room_manager()
	_check_kill_port_holder()
	_check_no_demo_residue()
	_check_feedback_mount_point()
	_check_royale_laser_routing()
	_check_ai_input_gate()
	_check_font_size_law()
	_check_new_interfaces()
	await _check_round_full_heal()
	_finish()


# ── 1) ★ C2 rollback 四条在位(server/match_host.gd)─────────────────────
# L5 的 RoyaleHost 扩展点全部是**只追加**的;这条断言就是"只追加"的长期守卫。四条任一
# 被动过,客户端 rollback 就失去锚点(见 docs/pvp-c2-retrospective.md P1/P2)。
# 判据取**去注释视图**:注释里提到这些名字不算"在位"(T4 清扫探针实测撞见过)。
func _check_c2_contract() -> void:
	var fails_before := _failures.size()
	var p := "MatchHost 继承链(见 HOST_SRC)"
	var code := _host_code()
	_check(not code.is_empty(), "读不到 %s" % p)
	if code.is_empty():
		return
	var needles := [
		# ★ 2026-10-02 降精度:原先钉的是**局部别名** `q` / `src` / `pkt` —— 把局部变量改个名
		#   (合法重构)就会红。意图是"这几个**动作**在不在"(消费一个 / 写 ack / 清冻结态 / 清队列)
		#   ⇒ 锚到方法名。位置序断言那边的 `find` 仍落在正确那一处(其它 `pop_front` 在别的函数里)。
		["pop" + "_front()", "每物理 tick 每 role 恰好消费一个 FIFO 输入包"],
		["_ack_seq[", "ack = 刚消费包的 seq(客户端 rollback 锚点)"],
		["reset" + "_state()", "COUNTDOWN 期连 held/axis 一起清(冻结期不漂移)"],
		[".clear()", "COUNTDOWN 分支清空缓冲(不喂输入)"],
		["_snapshot" + "_accum", "60Hz 快照累加器(消费前广播)"],
	]
	for spec in needles:
		var s: String = spec[0]
		_check(code.count(s) >= 1,
				"C2 契约缺失:%s 在 %s 里 %d 处(%s)" % [s, p, code.count(s), spec[1]])
	# 顺序:快照广播必须**先于**消费本帧输入,否则 ack 指向刚消费的包、状态却还是上一步进完的
	# → ack 领先状态一拍 → 客户端移动中每次快照都误判分歧、画面被拉回。
	var i_accum := code.find("_snapshot" + "_accum += delta")
	var i_cast := code.find("_broadcast" + "_snapshot()")
	var i_pop := code.find("pop" + "_front()")
	_check(i_accum >= 0 and i_cast >= 0 and i_pop >= 0,
			"C2 顺序断言前置不足:accum=%d broadcast=%d pop=%d(源码里找不到?)" % [i_accum, i_cast, i_pop])
	if i_accum >= 0 and i_cast >= 0 and i_pop >= 0:
		_check(i_accum < i_cast and i_cast < i_pop,
				"快照广播不在消费输入之前(accum=%d broadcast=%d pop=%d)" % [i_accum, i_cast, i_pop])
	# 快照载荷:ack_seq + 权威整态 c2 必须都在 _broadcast_snapshot 体内
	var snap := _func_body(code, "_broadcast" + "_snapshot")
	_check(snap.contains("\"ack" + "_seq\""), "快照载荷缺 ack_seq(客户端无从锚定已确认输入)")
	_check(snap.contains("\"c2\""), "快照载荷缺权威整态 c2(rollback 无从整态恢复)")
	# COUNTDOWN 分支:清空缓冲 **且** src.reset_state(),且**都发生在 pop 之前** —— 这才等于
	# "确实在 COUNTDOWN 的 early-continue 分支里"。只查全局存在是不够的:把它挪到别处
	# (比如循环外)照样绿,而冻结期又会漏喂上一包方向 → C2 分歧源。
	var phys := _func_body(code, "_physics_process")
	var i_cd := phys.find("RoundState." + "COUNTDOWN")
	var i_clear := phys.find(".clear()")
	var i_reset := phys.find("reset" + "_state()")
	var i_pop_phys := phys.find("pop" + "_front()")
	_check(i_cd >= 0 and i_clear >= 0 and i_reset >= 0 and i_pop_phys >= 0,
			"C2 COUNTDOWN 断言前置不足:countdown=%d clear=%d reset=%d pop=%d" % [i_cd, i_clear, i_reset, i_pop_phys])
	if i_cd >= 0 and i_clear >= 0 and i_reset >= 0 and i_pop_phys >= 0:
		_check(i_cd < i_clear and i_cd < i_reset and i_clear < i_pop_phys and i_reset < i_pop_phys,
				"COUNTDOWN 的清零/重置不在消费之前(不在 early-continue 分支里?): countdown=%d clear=%d reset=%d pop=%d"
				% [i_cd, i_clear, i_reset, i_pop_phys])
	# ★ 第 5 条(生产侧:`_on_input`):包到达时只**入队**,不得就地应用/丢弃。
	# 上面四条(每 tick 消费一个 / ack / 快照顺序 / COUNTDOWN 清零)全都建立在「包先入队、
	# 由 _physics_process 每 tick 取一个」之上。若有人把 `_on_input` 改成到达即
	# `apply_packet`(或把队列丢掉改成直接赋值),上面四条照样全绿 —— 因为它们只读
	# 消费侧 —— 而 C2 rollback 的「1 包/tick、1:1 同序」锚点已经没了:客户端按 ack 重放
	# 未确认输入时,服务器实际模拟的输入序列与重放序列不再同序,分歧会变成常态。
	# 故正向钉住「按 role 建 FIFO 队列 + 到达即 append」,反向钉住「体内不得就地应用、不得清队列」。
	var on_in := _func_body(code, "_on" + "_input")
	_check(not on_in.is_empty(), "取不到 %s 的函数体(函数改名/挪进别的文件了?)" % ("_on" + "_input"))
	if not on_in.is_empty():
		# ★ 降精度:原把 `role` 这个形参名也钉进去了 ⇒ 只留队列本身的名字。
		var queue_init := "_pending" + "_input["
		_check(on_in.contains(queue_init),
				"%s 里没有按 role 建 FIFO 队列(%s)→ 到达的包进不了缓冲" % ["_on" + "_input", queue_init])
		# ★ 降精度:原钉 `.append(pkt)` 的形参名(`pkt`);`_on_input` 体里 `.append(` 唯一 ⇒ 只留方法名。
		_check(on_in.contains(".append("),
				"%s 里没有把到达的包 append 进队列(每 tick 消费一个的前提没了)" % ("_on" + "_input"))
		_check(not on_in.contains("apply_" + "packet"),
				"%s 里出现就地 apply_packet:包不再由 _physics_process 每 tick 消费一个 → C2 1:1 同序锚点失效"
				% ("_on" + "_input"))
		_check(not on_in.contains(".clear()") and not on_in.contains("pop_" + "front"),
				"%s 里出现清队列/pop:生产侧不得消费(消费的唯一位置是 _physics_process)"
				% ("_on" + "_input"))
	_summary(fails_before, "C2 契约:四条在位(含快照先于消费、COUNTDOWN 早退清零、载荷带 ack_seq+c2)+ 生产侧 _on_input 入队不落地")


# ── 2) main 既有成果在位(server/room_manager.gd + server/worker_launcher.gd)──
# L5 把大乱斗大厅并进了同一份 room_manager。main 的「超龄房清扫」族(防 worker 进程 +
# 端口永久泄漏)必须原样保留:少了 sweep 就泄漏,少了 kill_worker 就杀不掉 worker。
# ★ 2026-09-14:杀 worker 的实现与那段 PowerShell 随端口池搬进了 WorkerLauncher
#   (server/worker_launcher.gd)。判据按**职责**拆到两个文件,不是删掉 ——
#   「杀不掉 worker」这个失败模式与文件放哪无关,必须仍然有人守。
func _check_room_manager() -> void:
	var fails_before := _failures.size()
	var p := "res://server/lobby/room_manager.gd"
	var pw := "res://server/lobby/worker_launcher.gd"
	var pp := "res://core/net/proc_util.gd"
	var code := _code_only(_read(p))
	var code_w := _code_only(_read(pw))
	var code_p := _code_only(_read(pp))
	_check(not code.is_empty(), "读不到 %s" % p)
	_check(not code_w.is_empty(), "读不到 %s" % pw)
	_check(not code_p.is_empty(), "读不到 %s" % pp)
	if code.is_empty() or code_w.is_empty() or code_p.is_empty():
		return
	var needles := [
		["func _sweep_stale_rooms(", "超龄房清扫入口(1v1 / 大乱斗 / 3v3 三族都要被扫到)", p, code],
		["created_at", "房间创建时间戳(超龄判据)", p, code],
		["func kill_worker(", "按端口杀 worker 进程(跨进程需查端口,不能只靠 create_process 的 pid)",
				pw, code_w],
		# ★ 2026-09-14:那段 PowerShell 与 server_main 的一份**逐字相同**,已收进 core/proc_util.gd
		#   (ProcUtil.kill_udp_port)。判据按职责跟着搬 —— 「取不到属主进程就一个都杀不掉」这个
		#   失败模式与它住哪个文件无关,必须仍然有人守。
		["Select -Expand" + "Property OwningProcess -Unique", "取 UDP 端口属主进程的修正写法",
				pp, code_p],
	]
	for spec in needles:
		var s: String = spec[0]
		_check((spec[3] as String).count(s) >= 1,
				"%s 缺失:%s(%s)" % [(spec[2] as String).get_file(), s, spec[1]])
	# ★ 私有调试残留:KH 的 _spawn_worker 曾硬编码 `--log-file` 指向**开发机本机绝对路径**
	# (含其用户名数字段),异机运行时写不存在目录(与 main 无关的私机路径)。全仓必须零命中。
	# ⚠ 连本文件的注释也不能出现那个数字:本扫描包含 tests/,写进注释就是自己命中自己。
	var leak: Array[String] = []
	for f in _collect(ALL_DIRS):
		if _read(f).contains("215" + "59"):
			leak.append(f)
	_check(leak.is_empty(), "KH 私机路径残留 %d 处: %s" % [leak.size(), ", ".join(leak)])
	_summary(fails_before, "room_manager:sweep 族 %d 针在位,私机路径残留 %d 处" % [needles.size(), leak.size()])


# ── 3) server_main 的 _kill_port_holder 是修正版 ────────────────────────
# `% OwningProcess` 这种写法取不到属性(ForEach-Object 后接裸名字不展开 $_),实测拿空
# → 端口属主杀不掉 → 7777 被旧进程占着、新实例 bind 失败瞬间退出(双击 exe 闪退)。
# 判据取**去注释视图**:server_main 里那条解释这个坏写法的注释本身就含该串,算进去
# 会让这条断言永远红(注释不是代码)。
func _check_kill_port_holder() -> void:
	var fails_before := _failures.size()
	# ★ 2026-09-14:实现从 server_main 搬进 core/proc_util.gd(ProcUtil.kill_udp_port)——
	#   原先它与 worker_launcher 那份**逐字相同**。判据跟着搬,但**坏写法的禁令两个文件都查**:
	#   只查新家的话,谁要是在 server_main 里再手抄一份坏写法就没人管了。
	var pp := "res://core/net/proc_util.gd"
	var ps := "res://server/server_main.gd"
	var cp := _code_only(_read(pp))
	var cs := _code_only(_read(ps))
	_check(not cp.is_empty() and not cs.is_empty(), "读不到 %s / %s" % [pp, ps])
	if cp.is_empty() or cs.is_empty():
		return
	var good := "Select -Expand" + "Property OwningProcess -Unique"
	var evil := "%" + " OwningProcess"
	_check(cp.count(good) >= 1, "%s 缺修正写法(%s)" % [pp, good])
	var evil_hits := cp.count(evil) + cs.count(evil)
	_check(evil_hits == 0,
			"代码里出现取不到属性的 %s 写法 %d 处(注释不算;查了 proc_util 与 server_main)"
			% [evil, evil_hits])
	_summary(fails_before, "kill_udp_port:修正写法 %d 处(proc_util),坏写法 %d 处(proc_util+server_main)"
			% [cp.count(good), evil_hits])


# ── 4) ★ 零演示残留(只扫生产目录)─────────────────────────────────────
# L4 把"主菜单背后挂一个真 Level0 演示世界"整条链退役了。留下来就是成本与风险:演示世界
# 要建全量碰撞、要在进出菜单时反复建/拆大世界(实测偶发原生段错误)。这条保证它不会被
# "为了好看"再搬回来。
func _check_no_demo_residue() -> void:
	var fails_before := _failures.size()
	var files := _collect(PROD_DIRS)
	_check(files.size() >= MIN_PROD_FILES,
			"演示残留扫描:只收到 %d 个生产源文件(扫描根坏了?期望 ≥%d)" % [files.size(), MIN_PROD_FILES])
	var hits: Array[String] = []
	for f in files:
		var low := _read(f).to_lower()
		for needle in _demo_needles():
			if low.contains(needle):
				hits.append("%s ← %s" % [f, needle])
	_check(hits.is_empty(), "演示世界残留 %d 处: %s" % [hits.size(), ", ".join(hits)])
	_summary(fails_before, "零演示残留:扫 %d 个生产源文件,命中 %d" % [files.size(), hits.size()])


# ── 5) ★ 打击反馈层唯一挂载点(生产路径恰好 1 处)───────────────────────
# 多一处(比如菜单又建一个)→ 两份反馈层抢 current;少一处 → 击杀播报/命中标记全哑。
# 必须由**对局世界**创建一次,且调用点留在 _ready 顶部、建图之前。
# 判据取**去注释视图**:计数必须数的是真调用。数裸文本的话,删掉调用、留一句"提到"它的
# 注释就能把计数维持成 1 → 反馈层根本没挂上而断言照样绿(正是本探针要防的"字面量出现过"式假绿);
# 反过来,一句介绍挂载点的文档注释也会被当成第二处 → 假红。
func _check_feedback_mount_point() -> void:
	var fails_before := _failures.size()
	var files := _collect(PROD_DIRS)
	var needle := "Combat" + "Feedback.spawn("
	var hits: Array[String] = []
	for f in files:
		var n := _code_only(_read(f)).count(needle)
		for _i in range(n):
			hits.append(f)
	_check(hits.size() == 1,
			"打击反馈层挂载点在生产路径应恰好 1 处(实际 %d): %s" % [hits.size(), ", ".join(hits)])
	if hits.size() == 1:
		_check(hits[0] == "res://scenes/level_0.gd",
				"唯一挂载点应是 res://scenes/level_0.gd(实际 %s)" % hits[0])
	_summary(fails_before, "打击反馈挂载点:命中 %d 处" % hits.size())


# ── 6) 大乱斗非射手端激光:走 NetBus,不走 NetBusExt ────────────────────
# 发送端 server/match_host.gd 用的是 NetBus.rpc_id(..., "beam_fired")。收在 NetBusExt
# 上会**静默 no-op**(同名 RPC 收不到,不报错)→ 大乱斗里对手的激光整条看不见。
func _check_royale_laser_routing() -> void:
	var fails_before := _failures.size()
	var p := "res://scenes/royale_game.gd"
	var code := _code_only(_read(p))
	_check(not code.is_empty(), "读不到 %s" % p)
	if code.is_empty():
		return
	var beam := "beam" + "_fired"
	_check(code.contains("Net" + "Bus.local_" + beam + ".connect("),
			"%s 没有订阅 NetBus.local_%s(非射手端看不到激光)" % [p, beam])
	var mixed: Array[String] = []
	for raw_line in code.split("\n"):
		var l: String = raw_line
		if l.contains(beam) and l.contains("Net" + "BusExt"):
			mixed.append(l.strip_edges())
	_check(mixed.is_empty(),
			"%s 里有 %d 行同时出现 NetBusExt 与 %s(发送端走 NetBus,收错节点会静默 no-op): %s"
			% [p, mixed.size(), beam, " | ".join(mixed)])
	_summary(fails_before, "大乱斗激光路由:NetBus 订阅在位,NetBusExt 混用 %d 处" % mixed.size())


# ── 7) AI 手感闸:AiInputSource.is_network_driven() 返回 true ───────────
# 不覆写(基类返回 false)→ 服务器侧 AI 被判成"本地单机" → 打空弹夹后进换弹、静默停火
# reload_time 秒(霰弹 2.2s / 榴弹 2.8s),AI 手感莫名变差且无任何报错。
func _check_ai_input_gate() -> void:
	var fails_before := _failures.size()
	var p := "res://core/net/ai_input_source.gd"
	var code := _code_only(_read(p))
	_check(not code.is_empty(), "读不到 %s" % p)
	if code.is_empty():
		return
	var sig := "func is_" + "network_driven("
	var i := code.find(sig)
	_check(i >= 0, "%s 缺 %s(基类返回 false → AI 被判本地单机)" % [p, sig])
	if i >= 0:
		var body := _func_body(code, "is_" + "network_driven")
		_check(body.contains("return true"),
				"%s 的 is_network_driven() 没返回 true(体=%s)" % [p, body.strip_edges()])
	_summary(fails_before, "AI 输入闸:is_network_driven() 覆写回报 true")


# ── 8) ★ 字号规范:全仓所有字号载体都是 16 的倍数(含 helper 实参)──────
# 本项目的像素字体(less_perfect_dos_vga)只在 16 的整数倍下与渲染缩放整数对齐,非 16
# 倍数会糊 —— 这是 ui/ui_factory.gd 文件头写下的硬约定,必须**机械可查**。
# 载体清单(A/B/C/D 照 L4 探针;B 是本探针补的那一类):
#   A) add_theme_font_size_override(…, N) 的实参(含 "font_size"/normal_/bold_font_size 键)
#   B) ★ 字号 helper 的调用实参 —— helper 由**函数体机械推导**:函数体内出现
#      `style_control(<形参>)` 或 `add_theme_font_size_override(…, <形参>)`,即认定该形参
#      是字号;该 helper 的调用点同一位置的整数字面量必须 16 的倍数。
#      (L4 只扫载体、不认 helper → royale_hud 的 `_make_label(20, …)` 全绿;T6 实测过。)
#   C) 字面赋值 `…font_size = N`(.tscn 的 theme_override_font_sizes/font_size = N 走这条)
#   D) const …FONT_SIZE… := N
#   E) UiFactory.label/button 与 style_control 的字号实参 + make_weapon_check 的字号实参
#      (字号直接写在函数体内的 style_control 调用同样是载体,正是这条被单列的理由)
func _check_font_size_law() -> void:
	var fails_before := _failures.size()
	var gd_tscn := _collect(ALL_DIRS)          # .gd + .tscn(ScanUtil.walk 只收这两种)
	var tres := _collect_tres(ALL_DIRS)        # ★ 显式补 .tres(见文件头第 8 条)
	_check(gd_tscn.size() >= MIN_ALL_FILES,
			"字号扫描:只收到 %d 个源文件(期望 ≥%d)" % [gd_tscn.size(), MIN_ALL_FILES])
	var files := gd_tscn.duplicate()
	files.append_array(tres)
	var bad: Array[String] = []
	var census := {}
	for f in files:
		_font_scan_file(f, _read(f), bad, census)
	_check(bad.is_empty(), "字号规范违例 %d 处(必须 16 的倍数): %s" % [bad.size(), "; ".join(bad)])
	# 扫描量下限:把**载体总数**打出来。扫描面坏掉时它掉到 0 附近而 bad 恒空(假绿)。
	var total := 0
	for p in census.keys():
		for k in (census[p] as Dictionary).keys():
			total += int(census[p][k])
	print("[L5] 字号载体总数:%d(下限 %d;扫 %d 个 .gd/.tscn + %d 个 .tres)"
			% [total, MIN_FONT_CARRIERS, gd_tscn.size(), tres.size()])
	_check(total >= MIN_FONT_CARRIERS,
			"字号载体只扫到 %d 个(下限 %d)—— 扫描面(路径/后缀/剥注释视图)坏了时零命中是假绿"
			% [total, MIN_FONT_CARRIERS])
	# Theme 资源必须真的被扫到(≥1 载体)。读不到 .tres 与扫坏了在 verdict 上一样静默。
	if not tres.is_empty():
		_check(census.has(THEME_FONT_FILE),
				"字号扫描没碰到 Theme %s(.tres 那一支路没生效 → Theme 里的字号没进过断言)"
				% THEME_FONT_FILE)
	# 扫描器自检:证明它**能红**(否则本探针就是又一台"永不失败的验收门")
	_self_test_font_scanners()
	# ★ 变体引用对账:.tscn 里那串「theme_type_variation 指向的变体名」必须在某个被扫到的
	#   Theme(.tres)里**有定义**(`Name/base_type` 或 `Name/font_sizes/…`)—— 否则控件静默
	#   回落 Godot 默认字号(不报错),而 .tscn 那一侧看不到任何字号值可查。
	_check_variation_refs(files, tres)
	# 覆盖面对账:L5 新文件的每个字号载体各命中几处,逐条打出来供人眼核对
	for p in L5_FONT_FILES:
		_check(census.has(p),
				"字号扫描没碰到 L5 新文件 %s(载体清单漏了这一类 → 该文件的字号没进过断言)" % p)
		if census.has(p):
			var parts: Array[String] = []
			for k in (census[p] as Dictionary).keys():
				parts.append("%s×%d" % [str(k), int(census[p][k])])
			parts.sort()
			print("[L5] 字号覆盖 %s: %s" % [p, ", ".join(parts)])
	_summary(fails_before, "字号规范:扫 %d 个 .gd/.tscn + %d 个 .tres,载体 %d 个,违例 %d 处(含经 helper 实参传递的字号)"
			% [gd_tscn.size(), tres.size(), total, bad.size()])


# 递归收 roots 下的 `.tres`(字号搬进 Theme 后的新落点)。与 `ScanUtil.walk` 同法,
# 只是后缀不同 —— 不改 `ScanUtil.walk` 是为了**零blast radius**:它的调用方(kh_l4 /
# ui_palette_smoke / enemy_logic_smoke …)对"文件表里多出 .tres"各有各的假设,别顺手扩。
func _collect_tres(roots: Array) -> Array[String]:
	var out: Array[String] = []
	for r in roots:
		_walk_tres(r, out)
	out.sort()
	return out


func _walk_tres(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var p := dir_path.path_join(name)
			if d.current_is_dir():
				_walk_tres(p, out)
			elif name.ends_with(".tres"):
				out.append(p)
		name = d.get_next()
	d.list_dir_end()


# `.tscn` 的 Theme 变体引用对账(见调用处注释)。
# ⚠ 覆盖上限(照实登记):
#    · 判据是**名字对名字** —— 它保证"引用的变体在有定义的 Theme 里存在",但不保证该变体
#      **带字号**(一个只有 font_color 的变体照样算"有定义")。真正钉字号值的是第 8 条的
#      分支扫描;本条只堵"引了个不存在的变体 → 静默回落默认字号"这一档。
#    · **只扫 `.tscn`**(引用形式);运行期 `.gd` 里 `xxx.theme_type_variation = &"…"` 那种
#      写法**不认**(迁移把变体引用放场景里,这是本设计的前提)。
#    · 只认 ALL_DIRS 下能找到的 `.tres`;若将来 Theme 放进 `addons/` 等未扫根,本条会假红。
func _check_variation_refs(files: Array[String], tres: Array[String]) -> void:
	var fails_before := _failures.size()
	# Theme 里**定义**的变体名:`Name/base_type` 或 `Name/font_sizes|styles|colors|constants/…`
	var defined := {}
	var re_def := RegEx.create_from_string(
			"^([A-Za-z_]\\w*)/(?:base_type|font_sizes|styles|colors|icons|constants)\\b")
	for f in tres:
		for line in _read(f).split("\n"):
			var m := re_def.search(line)
			if m != null:
				defined[m.get_string(1)] = true
	# `.tscn` 里**引用**的变体名。★ 只扫 `.tscn` —— 一是语义(变体引用在场景里),二是**防自伤**:
	#   本探针是 `.gd`,若把 `.gd` 也扫进来,上面那句示例注释里的 shape 会命中正则
	#   (本文件头「自伤防护」记过同一类坑)。
	var used := {}
	var re_use := RegEx.create_from_string("theme_type_variation\\s*=\\s*&?\"([^\"]+)\"")
	for f in files:
		if not f.ends_with(".tscn"):
			continue
		for m in re_use.search_all(_read(f)):
			used[m.get_string(1)] = true
	var missing: Array[String] = []
	for raw_name in used.keys():
		if not defined.has(raw_name):
			missing.append(str(raw_name))
	_check(missing.is_empty(),
			"%d 个 theme_type_variation 引用的变体名在任何 Theme 里都没有定义(控件会静默回落默认字号): %s"
			% [missing.size(), ", ".join(missing)])
	_summary(fails_before, "变体引用对账:.tscn 引用 %d 个名字,Theme 定义 %d 个,缺 %d 个"
			% [used.size(), defined.size(), missing.size()])


# 扫单个源里的全部字号载体(合成源也能喂,供自检用)
func _font_scan_file(path: String, src: String, bad: Array[String], census: Dictionary) -> void:
	# 去注释视图:注释/日志行不得喂饱断言(T4 清扫探针实测撞见过)
	var code := _code_only(src)
	_scan_call_args(path, code, N_FONT_OVERRIDE, -1, bad, census)      # A
	for h in _derive_font_helpers(code):                                # B
		_scan_call_args(path, code, str(h[0]) + "(", int(h[1]), bad, census)
	_scan_call_args(path, code, N_STYLE_CONTROL, 1, bad, census)        # E
	_scan_call_args(path, code, N_FACTORY + "label(", 1, bad, census)   # E
	_scan_call_args(path, code, N_FACTORY + "button(", 1, bad, census)  # E
	_scan_call_args(path, code, N_WEAPON_CHECK, 2, bad, census)         # E
	var re_assign := RegEx.new()                                        # C
	re_assign.compile(N_FONT_SZ_ASSIGN)
	for m in re_assign.search_all(code):
		_census(census, path, "font_size 赋值")
		var v := int(m.get_string(1))
		if v % 16 != 0:
			bad.append("%s: 字号 %d(「%s」)" % [path, v, m.get_string(0).strip_edges()])
	var re_const := RegEx.new()                                         # D
	re_const.compile(N_CONST_DECL)
	for raw_line in code.split("\n"):
		var l: String = (raw_line as String).strip_edges()
		if not l.begins_with("const") or not l.contains(N_FONT_SZ_CONST):
			continue
		_census(census, path, "const 字号常量")
		var m := re_const.search(l)
		if m == null:
			bad.append("%s: const 字号声明读不出数值「%s」" % [path, l])
			continue
		var v := int(m.get_string(1))
		if v % 16 != 0:
			bad.append("%s: const 字号 %d(「%s」)" % [path, v, l])


# 由函数体推导「形参即字号」的 helper:返回 [[helper 名, 字号实参下标], …]
# 只认 `style_control(<控件>, <形参>)` 与 `add_theme_font_size_override(…, <形参>)` 两种体,
# 形参名必须真是该函数的形参 —— 这样推导不会把普通函数误认成字号 helper(误认=假红)。
# ⚠ 已知边界(评审记录,**看不见**的三类,别把它当全覆盖):
#   · 函数签名/形参表**换行**(参数跨行)的 helper:hdr 逐行匹配,匹配不上 → 该 helper
#     整个推导不出来,它的字号实参不进断言;
#   · 推导只有**一层**:helper A 把形参转手给 helper B(A 体内只有 `B(size)`)时不追;
#   · 实参不是整数字面量(走常量名/表达式)一律跳过(_scan_call_args 只查 is_valid_int),
#     除非那个常量的名字含 FONT_SIZE —— 只有常量声明扫描(D 类)认这个名字。
func _derive_font_helpers(code: String) -> Array:
	var out: Array = []
	var cur_name := ""
	var params: Array[String] = []
	var hdr := RegEx.new()
	hdr.compile("^(?:static\\s+)?func\\s+([A-Za-z_]\\w*)\\s*\\(([^)]*)\\)")
	var re_sc := RegEx.new()
	re_sc.compile(N_STYLE_CONTROL_RE + "([A-Za-z_]\\w*)\\s*,\\s*([A-Za-z_]\\w*)\\s*\\)")
	var re_ov := RegEx.new()
	re_ov.compile(N_FONT_OVERRIDE_RE + "[^,]*,\\s*([A-Za-z_]\\w*)\\s*\\)")
	for raw_line in code.split("\n"):
		var l: String = (raw_line as String).strip_edges()
		if l.begins_with("func ") or l.begins_with("static func "):
			cur_name = ""
			params = []
			var hm := hdr.search(l)
			if hm != null:
				cur_name = hm.get_string(1)
				for raw_p in (hm.get_string(2) as String).split(","):
					params.append((raw_p as String).split(":")[0].strip_edges())
			continue
		if cur_name.is_empty():
			continue
		var idx := -1
		var m := re_sc.search(l)
		if m != null:
			idx = params.find(m.get_string(2))
		else:
			m = re_ov.search(l)
			if m != null:
				idx = params.find(m.get_string(1))
		if idx >= 0:
			out.append([cur_name, idx])
	return out


# 扫描器自检:喂合成源,证明「坏值必红 + 好值不红」。合成源全用碎片/str() 现拼,
# 免得本探针自己的源码被第 8 条扫到(见文件头「自伤防护」)。
func _self_test_font_scanners() -> void:
	var fails_before := _failures.size()
	var bad_size := str(4 * 5)     # 20:非 16 倍数
	var ok_size := str(16 * 2)     # 32
	var synthetic_path := "res://__l5_synthetic__.gd"
	# 反例 1:UiFactory.label 的字号实参
	var bad: Array[String] = []
	_font_scan_file(synthetic_path,
			"var l := " + N_FACTORY + "label(\"x\", " + bad_size + ")", bad, {})
	_check(not bad.is_empty(), "字号自检①失败:UiFactory.label 的 %s 没被扫出来(扫描器形同虚设)" % bad_size)
	# 反例 2:经 helper 实参传递 —— L4 探针漏掉、T6 实测把 20 写进去仍全绿的那一类
	var helper_name := "_l5_" + "synth"
	var synth := "func " + helper_name + "(size: int, c: Color) -> void:\n\t" + \
			N_FACTORY + N_STYLE_CONTROL + "null, size)\n" + \
			"func _l5_use() -> void:\n\t" + helper_name + "(" + bad_size + ", Color.WHITE)\n"
	bad = []
	_font_scan_file(synthetic_path, synth, bad, {})
	_check(not bad.is_empty(),
			"字号自检②失败:helper 实参里的 %s 没被扫出来(＝ T6 实测的那个洞:照抄 L4 扫描模式)" % bad_size)
	# 正例:16 的倍数必须**不**报,否则扫描器是"恒红",一样不能用
	bad = []
	_font_scan_file(synthetic_path, synth.replace(bad_size, ok_size), bad, {})
	_check(bad.is_empty(), "字号自检③失败:16 的倍数被误报 %s" % str(bad))
	_summary(fails_before, "字号扫描器自检:helper 实参类坏值必红、好值不红")


# 扫 needle 调用,取第 arg_index 个实参(0 基;arg_index < 0 = 全部实参)。
# 纯整数字面量才查 16 的倍数;变量实参(如 style_control(x, WEAPON_FONT_SIZE))跳过 ——
# 它们的值由 D) 那条常量表兜住。
func _scan_call_args(path: String, src: String, needle: String, arg_index: int,
		bad: Array[String], census: Dictionary) -> void:
	var from := 0
	while true:
		var i := src.find(needle, from)
		if i < 0:
			return
		var open := i + needle.length() - 1
		from = i + needle.length()
		var close := _match_paren(src, open)
		if close < 0:
			return
		var args := _split_args(src.substr(open + 1, close - open - 1))
		var idxs: Array = range(args.size()) if arg_index < 0 else [arg_index]
		for k in idxs:
			if int(k) >= args.size():
				continue
			var a: String = args[int(k)].strip_edges()
			if not a.is_valid_int():
				continue
			_census(census, path, needle)
			var v := int(a)
			if v % 16 != 0:
				bad.append("%s: %s 第 %d 个实参 = %d" % [path, needle, int(k), v])


func _census(census: Dictionary, path: String, carrier: String) -> void:
	if not census.has(path):
		census[path] = {}
	var d: Dictionary = census[path]
	d[carrier] = int(d.get(carrier, 0)) + 1


# ── 9) 新接口在位,且归属正确 ──────────────────────────────────────────
# T2 评审发现的计划自相矛盾已修正:这些口**按归属**断言。反向断言尤其重要——
# mark_disconnected 读写 `_left` 并调 _finish_match(),整段搬进基类就是未定义符号。
# 判据一律用 `func 名(`(定义本身)而不是裸名字:裸名字会被**调用点**或注释满足,
# 函数被删而调用点残留时断言照样绿(那正是"未定义符号"要防的)。
func _check_new_interfaces() -> void:
	var fails_before := _failures.size()
	var base := "MatchHost 继承链(见 HOST_SRC)"
	var sub := "res://server/hosts/royale_host.gd"
	var base_code := _host_code()
	var sub_code := _code_only(_read(sub))
	_check(not base_code.is_empty() and not sub_code.is_empty(), "读不到 %s / %s" % [base, sub])
	if base_code.is_empty() or sub_code.is_empty():
		return
	# ★ 批次 3 改法:`_broadcast_match_options` 已删 —— 生效选项改由对局场景**进场拉取**
	#   (NetBus.match_sync)下发,那次"服务器推"是同一次 poll 里推给正在切场景的客户端,会静默丢
	#   (自检 B2)。按"改探针认新入口、别回退重构"的纪律改这里:**别把它加回来**。
	for m in ["notify" + "_direct_hit"]:
		_check(base_code.contains("func " + m + "("), "%s 缺基类方法 %s" % [base, m])
	for m in ["start_on", "set_display_names", "mark_disconnected", "request_suicide_role"]:
		_check(sub_code.contains("func " + m + "("), "%s 缺子类方法 %s" % [sub, m])
	# ★ 反向断言:子类方法不得出现在基类里
	var leaked: Array[String] = []
	for m in ["set_display_names", "mark_disconnected", "request_suicide_role",
			"_finish_match", "_attributed_killer"]:
		if base_code.contains(m):
			leaked.append(m)
	_check(leaked.is_empty(),
			"%s 含 RoyaleHost 的子类方法 %s(搬进基类即未定义符号)" % [base, ", ".join(leaked)])
	_check(_code_only(_read("res://ui/hud/royale_hud.gd")).contains("class_name RoyaleHud"),
			"ui/royale_hud.gd 缺 class_name RoyaleHud")
	# ★ 2026-09-14:大乱斗房间 handler 随账本搬进 server/lobby_rooms.gd(LobbyRooms,见 M4c)。
	#   判据跟着搬,但**两处都查**:老家若被人再抄一份同名 handler,那正是"两份真相"的开端。
	var rl := _code_only(_read("res://server/lobby/lobby_rooms.gd"))
	_check(rl.contains("func royale_create("), "server/lobby/lobby_rooms.gd 缺 func royale_create(")
	_check(not _code_only(_read("res://server/lobby/room_manager.gd")).contains("func royale_create("),
			"server/lobby/room_manager.gd 又出现 func royale_create(——房间 handler 应只在 lobby_rooms 一处)")
	_summary(fails_before, "新接口:基类 1 个 + 子类 4 个在位,基类零子类方法泄漏,RoyaleHud 在位,royale_create 在 lobby_rooms")


# ── 10) ★ round_full_heal 真的把双方回满血(端到端 + 对照组)────────────
# T2 评审:该分支在 T2 的 diff 里零覆盖(只被一次性探针验过)。这里起一局真 MatchHost,
# 把双方打残→把倒计时推完→断 hp == max_hp。**并跑一次 round_full_heal=false 的对照**
# —— 否则"回满了"可能来自别的路径,断言照样绿(对照组把这种假通过堵死)。
func _check_round_full_heal() -> void:
	var fails_before := _failures.size()
	var healed: Dictionary = await _run_heal_case(true)
	var control: Dictionary = await _run_heal_case(false)
	_check(healed.ok, "round_full_heal=true 没把双方回满血:%s" % healed.detail)
	_check(control.ok, "对照组(round_full_heal=false)也被回满了 → 主断言是假通过:%s" % control.detail)
	_summary(fails_before, "round_full_heal:开=%s 关=%s" % [healed.detail, control.detail])


# 起一局 MatchHost,打残双方,让倒计时走到 0 再断。返回 {ok, detail}
func _run_heal_case(enabled: bool) -> Dictionary:
	var host = MatchHost.new("res://maps/newfactory.cyrm", {1: 1, 2: 2},
			{"round_full_heal": enabled})
	host.name = "L5HealHost" + ("On" if enabled else "Off")
	add_child(host)
	var before := {}
	for role in host.players:
		var p = host.players[role]
		p.apply_authoritative_state(1, p.max_waterproof, false)
		before[role] = int(p.hp)
	var state_before := int(host._round_state)
	host._round_timer = 0.05
	# 让状态机自己走过 COUNTDOWN(_physics_process → _match_round_tick),上限 60 物理帧
	var frames := 0
	while frames < 60 and int(host._round_state) == state_before:
		await get_tree().physics_frame
		frames += 1
	var detail := ""
	var ok := true
	var reached := int(host._round_state) == int(MatchHost.RoundState.PLAYING)
	if not reached:
		ok = false
		detail = "倒计时没走完(state=%d,等了 %d 帧)" % [int(host._round_state), frames]
	else:
		for role in host.players:
			var p = host.players[role]
			detail += "%srole%d hp %d→%d/%d" % [" " if detail != "" else "", int(role),
					int(before[role]), int(p.hp), int(p.max_hp)]
			var want: int = int(p.max_hp) if enabled else 1
			if int(p.hp) != want:
				ok = false
	remove_child(host)
	host.queue_free()
	await get_tree().process_frame
	return {"ok": ok, "detail": detail}


# ── 工具 ────────────────────────────────────────────────────────────
func _demo_needles() -> Array[String]:
	# 碎片拼接:见文件头「自伤防护」
	return [
		"menu" + "_demo",
		"_demo" + "_level0",
		"enter_game" + "_staged",
		"build_permanent" + "_region",
	]

