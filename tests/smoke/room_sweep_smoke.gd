extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke)。锁的结构横跨两个文件(2026-09-14 拆账本后):
#  **room_manager.gd**:1) SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;3) _process 每周期调
#   _sweep_stale_rooms;4) _sweep_stale_rooms 对超龄房走拆除统一集中处理;5) 大乱斗在局宽限谓词同时引用
#   ROYALE_MATCH_TIME_CEILING 与 rr.in_match,且 1v1 仍是裸 MAX_ROOM_AGE。
#  **lobby_rooms.gd**(账本/统一集中处理搬来这里):2) 建房时给 created_at 赋时间戳;统一集中处理体外不得出现
#   端口归还/注册表删除(见 _check_teardown_funnel);杀 worker 的实现另在 worker_launcher.gd。
#  **批次 3(3v3,2026-09-18)**:argv 契约扩到 --team/--teams(见 _check_argv_contract 的正/反向),
#   另在 _check_team_startup_contract 钉宽限分派/走光退出/不降级/满员才开(真链路归 B 册)。
#  **B 册 Task 4(2026-09-19)**:_check 里把清扫判据扩到**三张注册表**,并单独钉住
#   `_sweep_stale_rooms` 那条「全空则提前 return」的并列守卫 —— 它是**独立的第二条**退出路径,
#   漏掉一张表时列表那行照旧在、断言测试全部通过,而那张表的房永远不清扫(静默端口泄漏)。
#  **B 册 Task 5(2026-09-19)**:3v3 分支补齐与 royale 对称的两条 —— 收集块(`for tcode in
#   lobby.team_rooms`)+ 宽限谓词行(TEAM_MATCH_ESTIMATE / tr.in_match / SWEEP_INTERVAL);
#   此前 3v3 一条都没有,"掏空循环"或"摘掉门控"都能测试全部通过(同样是静默端口泄漏)。
#  **B 册 Task 7(2026-09-19)**:两条**收集块的循环体**断言(`stale_team.append(tr)` /
#   `stale_royale.append(rr)`)—— 只钉 `for …` 头行是**同粒度**的洞:留头行、掏空体时上面四条测试全部通过。
#  **阶段 2-B Task 4(2026-09-21,回局凭据的登记与清理)**:三处 ——
#   ① `_check_teardown_funnel` 的模式表加 `rejoin.drop_room(`(凭据表也是一张注册表,"整房作废"
#      同样是拆除动作;加它之前把该调用挪出统一集中处理**这条门完全看不见**,已实测);
#   ② `_check_reclaim_ladder` 加一条**反向**断言:room_manager 里不许出现 `rejoin.drop_room(`
#      (统一集中处理那条只扫 lobby_rooms.gd,扫不到写在编排层的绕道 —— 这正是该函数存在的理由);
#   ③ 新增 `_check_rejoin_spawn_wiring`:四个 spawn 点逐个明确提示必须在 spawn **之后**登记凭据,
#      且 GC 搭在 30s 回收梯上(漏一个的症状是静默的:那个模式永远回不去)。
#  **阶段 2-B Task 5(2026-09-21,同日)**:**改名跟随** —— `rejoin.drop_room(code)` →
#   `rejoin.drop_port(worker_port)`(三张注册表的房号空间重叠,按 code 作废会误伤同号的另一间房)。
#   上面①②两处的判据串跟着改;`_check_reclaim_ladder` 那条**两种写法都收**(旧名留给"有人把按
#   code 的版本加回来"这一档)。-  这是**跟着改名**,不是放宽白名单 —— 方向别搞反。
#  **2026-09-28 评审(大乱斗可证上界那批的收尾)** —— `_check` 里四处,都在函数体内,
#   `CHECK_NAMES` 不变:
#   ① 上界的链有**两环**,原实现只钉住环一(settings.gd 的钳位);补环二
#      (`scenes/mp_lobby.gd` 的秒换算);
#   ② 判决串改**片段匹配**(Finding 4:整行字面量对无害改写响亮虚假失败（测试用例误报）;但也不退到全文件
#      片段 —— `TEAM_MATCH_ESTIMATE` 同为 1800,那半会静默失明);
#   ③ 两个新读的文件各补一条"读不到就说读不到"的断言(Finding 5:否则诊断会误报成
#      "钳位/换算变了")。
#  **2026-09-28 终审(整支)→ 第三环(`_check` 内再加一条,`CHECK_NAMES` 仍不变)**:
#   ④ 前面两条钉的都是**上界**这一侧;而**真正产生下发值**的是滑块那一侧 ——
#      `scenes/mp_lobby.gd` 的 `tslider.max_value = 15.0` 与它的 `value_changed`
#      (`Settings.royale_match_min = v`,**不钳位**)。放宽它  ->  环一环二保持测试通过而上界失效。
#      - 判据比**数值**而非子串:`contains("15")` 挡不住 `15.0 → 150.0`(实测它含子串)。
#       ->  链是**三环**;把它写进 header 是为了让下一个读到"两环"的人知道还有一环。
#  **2026-10-03(T2「统一大厅整屏搬 `.tscn`」)→ 第三环的**家搬了**,判据跟着搬**:
#   ⑤ `scenes/mp_lobby.gd` 的 `_build_match_time_row()` 已随迁移删除,上限现在住在
#      **`scenes/mp_lobby.tscn` 的 `MatchTimeSlider.max_value`**(`_build_ui()` 只灌
#      `value = Settings.royale_match_min` 并接 `value_changed`,不再碰上限)。
#       ->  本条改读基础结构框架,并加三条:节点必须**恰一个**且是 `HSlider`、读不到基础结构框架要响亮报"读不到"、
#      `.gd` 里不许再出现 `_time_slider.max_value`(否则上限回到两个家、判据被架空)。
#      - 链的**环数与语义一个字没变**(环一 settings.gd 钳位 / 环二秒换算 / 环三写入端);
#        变的只是环三住在哪个文件 —— 改版式去编辑器里改那个节点,别回来加 `max_value`。
# 跑法:用户自跑(room_sweep_smoke.sh)。通过 = SMOKE_ROOM_SWEEP OK。

var _fail := ""
# 注意： 2026-09-21(「看得见进不去」批 Task 6 补):**本文件每个 `_check_*` 都必须跑到尾**。
#   为什么需要:本文件的 `_check_*` 全是"`_fail` 非空就提前返回"的写法,而 **GDScript 的脚本错误
#   (`Invalid call. Nonexistent function …` 这类)不给 `_fail` 赋值** —— 它只让**出错的那个
#   函数当场结束**,调用方 `_initialize` 照常往下走,`_finish()` 于是打出 OK。实测(本批
#   Task 1 首次发现、Task 6 原样复现):把 `WorkerLauncher.pid_of` 连名带 4 处调用一起改名
#   (只改定义的话 `room_manager.gd` 先编不过、会走另一条红路),输出多一段
#     `SCRIPT ERROR: Invalid call. Nonexistent function 'pid_of' in base 'RefCounted (WorkerLauncher)'`
#   而 verdict **仍是 `SMOKE_ROOM_SWEEP OK`** —— 那一组断言被静默跳过,读起来像"全过"。
#   (同源的完整表述在 `tests/lib/probe_base.gd` 文件头:`ALL-OK` 只证明"没有任何一条断言
#   失败",不证明"该跑的断言都跑过";两个新场景探针用 `_checks >= EXPECTED_CHECKS` 堵它。)
# - 判据为什么成立:`_fail` 为空时,任何"提前 return"都只可能来自函数开头那条
#   `if _fail != "": return` —— 而它只在 `_fail` 已非空时点火,与 `_fail` 为空矛盾。
#   故 `_fail` 为空 ⟺ 「没有正式断言失败」;此时名单不全就**只可能**是"有函数没跑到尾"。
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
	# - 先**编译**一次目标脚本再做文本断言。本冒烟是纯文本扫描(`-s` 下 grep 源码),它**不会**
	#   编译被扫的文件 —— 于是"文本全对但文件压根编译不过"这件事它能直接放过去。
	#   实测踩过:把 `_teardown_room` 的参数从 `kill: bool` 改成 `mode: int` 时漏改了体内一处
	#   `kill` 引用 → GDScript 编译失败,而本冒烟**照样报 OK**(另两条验证也没覆到:主菜单场景
	#   不加载 room_manager,`--worker` 分支也不碰 RoomManager)。`load()` 会真正编译它。
	#   注:`load()` 解析失败时**不返回 null**(给回的是那个坏掉的脚本对象),故判据用
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


# 取「**等于** line_text 的那一行 + 紧随其后、缩进更深的一块」(到下一个缩进 ≤ 它的非空行为止)。
# - 必须用**保留缩进**的视图(`ScanUtil.code_view`,它同样剥掉注释):`code_only` 会 strip_edges,
#   拿它切不出块 —— 而这里两条断言的价值恰恰在于"那个 if 后面**真的有**它声称做的事"。
# - 只返回**第一处**命中:本用途下每个 needle 都是唯一的(命中处不是唯一时,断言会红在
#   "块里没有 X"上,不会静默取错)。
func _block_of(code_view: String, line_text: String) -> String:
	var lines: PackedStringArray = code_view.split("\n")
	for i in range(lines.size()):
		# - 匹配用**整行相等**(strip 后),不用 `contains`:本仓的 `elif _team_mode:` 里就含
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
# 「端口泄漏」这**同一个**失败模式本层补过三次(on_peer_left 空房分支 / royale_leave 空房分支 /
# ai_duel 摘房前的手动释放)。统一集中处理后「新加一条拆除路径」不可能漏 —— 因为没有第二条路可走。
# 断言形态刻意选「**只能出现在这一处**」而不是「数调用点个数」:个数会随实现漂,而这是契约本身。
func _check_teardown_funnel() -> void:
	# - 2026-09-14:账本与拆除统一集中处理搬进了 server/lobby_rooms.gd(LobbyRooms,见 M4c)。
	#   统一集中处理的判据跟着搬 —— 「端口归还与注册表删除只能出现在统一集中处理体内」这条纪律与它住哪个文件无关。
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
			# - 模式列表必须包含**当前**的端口归还入口。2026-09-14 端口池搬进 WorkerLauncher 后,
			#   `_worker_ports.erase(port)` 改名成 `_launcher.release_now(port)` —— 若不把新名字
			#   加进来,这条门就对端口回收**彻底失明**(它只认旧字符串,而旧字符串已全仓不存在),
			#   表现是恒绿:新加一条绕过统一集中处理的拆除路径也照过。改名/搬家时相同机制改这里。
			# 注意： 三张注册表各留一条判据(1v1 那条就是裸 `rooms.erase(`),且 `*_rooms.erase(` 排在
			#   裸 `rooms.erase(` **之前**:裸那条是另两条的**子串**(`team_rooms.erase(` 里就含
			#   `rooms.erase(`)—— 所以其实三种写法都拦得住,但只留裸那条时判词会点错名字(报
			#   "rooms.erase(" 而实际写的是 team_rooms)。反过来,也**别**把这两条当冗余删掉:删了不会
			#   虚假通过（未有效测试）(仍被子串拦住),只是判词失去分辨力 —— 那是排查时最贵的那点信息。
			# 注意： 阶段 2-B(Task 4,2026-09-21)新增 `rejoin.drop_room(`:凭据表**也是一张注册表**,
			#   作废某房的凭据同样是"拆除动作"。加它之前,**把 `drop_room` 挪到调用方**(本仓对
			#   `teardown_room` 明令禁止的那件事)这条门**完全看不见** —— 实测:挪进
			#   `_reclaim_finished_matches`(另一个文件)后本冒烟仍报 OK,而"同一件事两处实现"
			#   这条纪律就只剩注释在守。判据只认**当前**的调用形状(`rejoin.drop_port(`),
			#   改名/搬家时相同机制改这里(与上面 `_launcher.release_now` 那条同一条纪律)。
			# 注意： 2026-09-21 同日**改名**:`drop_room(code)` → `drop_port(worker_port)`(三张注册表
			#   的房号空间重叠,按 code 作废会误伤同号的另一间房)。-  这里是**跟着改名**,不是
			#   "为了让某处的调用过关而放宽" —— 放宽的方向(把不在统一集中处理里的调用也收进白名单)
			#   恰恰是这条门存在要拦的事,别往那边改。
			for pat in ["_release_port_later(", "launcher.release_now(", "royale_rooms.erase(", "team_rooms.erase(", "rooms.erase(", "rejoin.drop_port("]:
				if t.contains(pat):
					if not allowed.has(f["name"]):
						_fail = "lobby_rooms.%s 里出现 %s —— 拆除必须走 teardown_room 单一收口" % [f["name"], pat]
						return
	_done.append("_check_teardown_funnel")


# ── 批次 2 新增:role 协议必须是**显式 role 集合**(--roles)──
# 旧协议传「人数 + role 上界」两个整数:两者量纲不同、且都得从人数**推导**;而 role 由
# royale_join 的「最小空闲号」分配、有人退出后不重排 → 编号会留空洞(房里 {1,3} 而成员 2 人),
# 推导必然出错 → 持 3 号的真客户端被当串线剔除断开(历史 B1)。故做**反向**断言:旧标识符一个都不许复活。
# 它防的是这套 argv 契约的**历史故障模式** —— 大厅与 worker 两边只改一边(CLAUDE.md 明文要求同步改)。
func _check_argv_contract() -> void:
	# 两边的文件清单:**生成端 + 解析端**。2026-09-14 生成端从 room_manager.gd 搬到
	# worker_launcher.gd(spawn 族随迁)——故两处清单都要含 worker_launcher.gd。
	# - 别只改正向那条:反向(旧标识符禁令)若还扫着 room_manager.gd,新生成端就没人管了,
	#   旧协议名可以在那儿悄悄复活 —— 那正是「只改一半」的另一种形态。
	for f in ["res://server/server_main.gd", "res://server/lobby/worker_launcher.gd"]:
		var txt := FileAccess.get_file_as_string(f)
		if txt.is_empty():
			_fail = "无法读取 %s" % f
			return
		for line in txt.split("\n"):
			var t: String = line.strip_edges()
			if t.is_empty() or t.begins_with("#"):
				continue   # 注释里提旧协议名是**有意的**(留档为什么换掉),不算违规
			# - 批次 3(3v3)新增 `--team-size` / `_team_bound`:同一类故障模式(把"队数/人数"
			#   当参数量纲,再从 role 号推队号)。队号与 role 集合**同序等长**传过去才是精确的那条。
			for bad in ["--players", "--max-role", "_role_bound", "_expected_players",
					"--team-size", "_team_bound"]:
				if t.contains(bad):
					_fail = "%s 的代码里仍有旧 argv 协议标识符 %s(应已换成 --roles 集合)" % [f, bad]
					return
	# 正向:集合协议必须在两边都在位(只改一边 = 启动的 worker 收不到 role 集合,静默降级)
	# - 批次 3(3v3):`--team` / `--teams` 同样**两边都要在** —— 生成端(worker_launcher)拼了
	#   而解析端(server_main)没接 = worker 收到一个它不认识的开关,静默按 1v1 形态跑;
	#   反过来只改解析端 = 大厅启动的 worker 永远不带队号。**文件清单只有这两个**,别漏。
	# 注意： 判据取**剥注释视图**(`ScanUtil.code_only`),与上面那条反向检查**同口径**:反向那条
	#   刻意用 `begins_with("#")` 跳过注释行(注释里提旧协议名是**有意的**留档),正向这条
	#   早先却是**整文件 `contains`** —— 于是"把那一行真代码删掉、只在注释里留一句 `"--roles"`
	#   的说明"就能把正向断言喂绿,而那正是本条要防的"只接了一半"。注释不是代码。
	for f in ["res://server/server_main.gd", "res://server/lobby/worker_launcher.gd"]:
		var code2 := ScanUtil.code_only(ScanUtil.read(f))
		if not code2.contains('"--roles"'):
			_fail = "%s 未接 --roles(集合协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % f
			return
		for tok in ['"--team"', '"--teams"']:
			if not code2.contains(tok):
				_fail = "%s 未接 %s(3v3 启动协议只接了一半?注:判据剥掉注释 —— 光在注释里提到不算)" % [f, tok]
				return
	_done.append("_check_argv_contract")

# ── 批次 3(3v3)新增:启动契约里"本册能做到的那一半" ──
# - 边界照实写明:**真链路**(6 个真客户端连上 `--team` worker → 满员开局 → 有人掉线 →
#   宽限到期 → **其余人继续打**)归 **B 册的真链路探针** —— 它需要大厅侧的 team 房间入口,
#   而那个入口本册不做。本函数钉的是**分派本身**:
#   ① `--team` / `--teams` 两边逐字对应(在 `_check_argv_contract` 里);
#   ② 宽限到点走那条**已被 grace_window_smoke ⑦ 逐个模式钉住答案**的纯函数,而不是又抄一遍
#      if/else —— 原先那个 `else` 把 1v1 与 3v3 一起吞成"收场退进程",3v3 第一个宽限到期的人
#      会带着整局退进程(与设计约定"该队少人继续打"相反;当时不可达,只因大厅还没有入口);
#   ③ `_expire_graces` 末尾那条"全员走光才退出"也含 3v3(漏了 = 走光后 worker 永驻占端口);
#   ④ 3v3 的超时梯不降级(与 --royale 方向相反)、收齐判据是"满员才开"。
func _check_team_startup_contract() -> void:
	var src := ScanUtil.read("res://server/server_main.gd")
	if src.is_empty():
		_fail = "无法读取 server_main.gd"
		return
	var code := ScanUtil.code_only(src)
	# ① 到点的分派必须走纯函数(答案在 grace_window_smoke ⑦ 里按模式逐个严格约束)。
	var expire := ScanUtil.func_body(code, "_expire_graces")
	if expire.is_empty():
		_fail = "找不到 _expire_graces 的函数体"
		return
	# 注意： 判据必须落到"**比较了**"上,不能只查函数名出现(Task 9 评审 M1):
	#   旧写法是 `contains("GraceWindow.expire_action(")` —— 而把分派退回不可测写法、同时把那行
	#   当**死代码**留下的变异(`var _a := GraceWindow.expire_action(...)` + 原样的 `if _royale: … else: quit`)
	#   两条都满足  ->  测试全部通过,而 3v3 已经坏了(宽限到期的那个人会带着整局退进程)。
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
	# - 与上面那条分派是**两条**判据(一条管"某个人到点怎么办"、一条管"人全走光了 worker 退不退"),
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
	# - 判据落在 3v3 那一支的**整块**上(用保留缩进的视图切块),而不是"文件里某处出现过某串":
	#   后者既能被别处的同形代码喂饱,也照不出"分母用错集合"这一档。
	# - 为什么分母必须是 `_team_of_role.size()`:`_team_of_role` 按 role **去重**,`_role_set` 是
	#   `--roles` 的逐 token 列表 —— `--roles 1,1,2,2,3,3 --teams 1,1,1,2,2,2` 长度校验能过,
	#   而队伍表只有 3 键  ->  拿 6 当满员界**永远到不了**  ->  干等 30s 超时退出(静默,零报错)。
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
	#    但它与"绝不静默"的纪律不一致。-  判据取那只守卫的**整块**(到下一个同缩进行为止):
	#    只查 `if _royale and _team_mode:` 这行文本的话,一个被 `pass` 掉的空块照样测试全部通过 ——
	#    那正是 M1 那类"看着像守卫、其实守不住"的形状。
	var excl := _block_of(ScanUtil.code_view(src), "if _royale and _team_mode:")
	if excl.is_empty():
		_fail = "server_main 未拒绝 --royale 与 --team 同时为真(模式开关互斥的守卫被删?)"
		return
	if not excl.contains("quit(1)"):
		_fail = "--royale/--team 互斥守卫里没有 quit(1)(空块 = 守卫守不住,静默开成错的那一半)"
		return
	_done.append("_check_team_startup_contract")


# ── 批次 3(3v3)新增:生成端的 fail-fast(队号**取值**)──
# - 为什么这条必须**真调一次**、而不是再写一条源码文本断言:文本只能证明"那几行字在"。
#   而这里的失败后果是**静默**的:解析端对越界队号静默丢弃 → 子进程因长度不等开机即 quit(1),
#   而生成端返回 `pid > 0`  ->  大厅判定"启动成功"、**对局永不开始、大厅侧零报错**
#   (Task 9 评审 M2;B 册大厅要从房间数据拼 teams,最容易踩的就是这一脚)。
# - 只喂**非法**输入:合法输入会真的启动一个子进程(本冒烟不该做那件事)。
#   控制组的判别点 = **长度相等**而队号越界 —— 只校验长度的旧实现在这一档会放行。
func _check_team_spawn_guard() -> void:
	print("[info] 下面那条 ERROR 是**预期**的:正在验证生成端拒绝越界队号(不真调一次,这条守卫就只是空话)")
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段。
	# (正确的实现**不会**启动任何进程 —— 校验在 `OS.create_process` 之前。)
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
	# created_at 的赋值点随 create_room/royale_create 搬进了 lobby_rooms.gd
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains(
			"created_at = Time.get_unix_time_from_system()"):
		_fail = "create_room/royale_create 未记录 created_at(超龄判据的输入)"; return
	if not src.contains("func _process"):
		_fail = "缺定时 _process"; return
	if not src.contains("func _sweep_stale_rooms"):
		_fail = "缺 _sweep_stale_rooms"; return
	# 杀 worker 的实现已随端口池搬进 WorkerLauncher(2026-09-14),这里改认新入口 ——
	# 但**两条都要**:实现存在 + room_manager 里有人调它。只查实现会放任"实现在、统一集中处理不再杀"
	# (清扫路径不杀 → 僵尸 worker 继续占着端口,正是本层补过三次的那个泄漏)。
	if not FileAccess.get_file_as_string("res://server/lobby/worker_launcher.gd").contains("func kill_worker"):
		_fail = "缺 WorkerLauncher.kill_worker(杀 worker 的实现)"; return
	if not FileAccess.get_file_as_string("res://server/lobby/lobby_rooms.gd").contains("launcher.kill_worker("):
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
	# - 2026-09-28 改认上界常量:原先这里认 `RoyaleHost.MATCH_TIME`,而它只是**默认值** ——
	#   房主可在建房页把一局配到 15 分钟(装载钳位到 30),于是"等了近 2h 才开局 + 配了长时长"
	#   的房会在**对局中途**被判超龄、连 worker 一起终止(缺口最大约 1500s)。
	if not pred.contains("ROYALE_MATCH_TIME_CEILING"):
		_fail = "大乱斗在局宽限缺 ROYALE_MATCH_TIME_CEILING(宽限被删/被改回默认时长?)"; return
	if pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限又用回了 RoyaleHost.MATCH_TIME(它只是默认值,不是上界)"; return
	# ── 2026-09-28:上界常量本身 + **它的前提**。四条缺一不可 ──
	# - 判据取**片段**而不是整行字面量(2026-09-28 评审 Finding 4):原先要求整行
	#   `const ROYALE_MATCH_TIME_CEILING := 1800.0`,对无害改写**响亮地虚假失败（测试用例误报）**。
	#   - 但也不取"文件里出现过 1800"那种全文件片段 —— 那是**空话**:同一个
	#   `room_manager.gd` 里 `TEAM_MATCH_ESTIMATE` 也是 1800.0,拿它当判据时把本常量改成
	#   900 照样绿(**静默失明**,而这正是本条判词声称要拦的那一档)。
	#   故取中间档:**声明那一行**必须含 `1800`。容忍空白 / `1800` vs `1800.0` / 注释缩进,
	#   不容忍把值改小。方向:宁可响亮虚假失败（测试用例误报）,不可静默失明。
	var ceil_line := ""
	for line in src.split("\n"):
		if line.contains("const ROYALE_MATCH_TIME_CEILING"):
			ceil_line = line
			break
	if ceil_line.is_empty() or not ceil_line.contains("1800"):
		_fail = "缺 ROYALE_MATCH_TIME_CEILING=1800(或值被改小了 —— 它必须盖得住装载钳位的上界)"; return
	# 注意： 前提钉在**它住的地方**:上界 1800 = 30 分钟 × 60,而 30 来自 `Settings.royale_match_min`
	#   的**装载钳位**。钳位一放宽(比如到 60 分钟),上面两条**保持测试通过**,而缺口**复现** ——
	#   只有这一条会红。改钳位时回来一起改。
	var settings_src := FileAccess.get_file_as_string("res://core/config/settings.gd")
	# - Finding 5(2026-09-28):读不到时必须报"读不到" —— 否则下面那条会宣称**钳位变了**,
	#   把诊断引向完全错误的方向(本文件对 room_manager.gd 早有相同机制判据,这里当时漏了)。
	if settings_src.is_empty():
		_fail = "无法读取 settings.gd(读不到源码 ≠ 钳位变了)"; return
	if not settings_src.contains("royale_match_min = clampf(") or not settings_src.contains("1.0, 30.0"):
		_fail = ("★ Settings.royale_match_min 的装载钳位变了 —— ROYALE_MATCH_TIME_CEILING "
				+ "(=30min×60=1800)不再盖得住它,大乱斗在局宽限的缺口复现。改钳位要一起改上界常量。"); return
	# ── 注意： 2026-09-28 评审 Finding 1:上界的链有**两环**,上面刚钉的是**环一**,下面是**环二** ──
	#   链的形状:`settings.gd` 把 `royale_match_min` 钳进 [1,30] 分钟(环一) → `mp_lobby.gd`
	#   把它**换算成秒**下发(环二,`* 60.0`)。只钉环一时,把 `* 60.0` 改成 `* 120.0`(或干脆
	#   传分钟) ->  实际下发的 `match_time` 翻倍/变形,而**上面所有断言照样测试全部通过** —— 上界静默失效,
	#   正是"前提断言"要防的那个形状,只是**下移了一环**。
	# - 判据相同机制取片段(Finding 4):定位**含 `"match_time"` 且带换算**的那一行,要求它同时含
	#   `Settings.royale_match_min` 与 `* 60.0` —— 不钉整行(容忍空白/换行/取值写法)。
	#   - 2026-10-03(统一大厅):mp_lobby 里 `"match_time"` 出现**两次** —— 一次是建房弹层的
	#     行键(`_form_rows["match_time"]`,不含换算),一次才是载荷里那一行。旧实现取**第一处**
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
	# ── 注意： 2026-09-28 终审(整支)→ 链其实是**三环**,这里钉的是**第三环(写入端)** ──
	#   环一 = `settings.gd` 的**装载**钳位 [1,30](上面钉着);环二 = 秒换算(上面钉着);
	#   **环三 = `scenes/mp_lobby.gd` 那根滑块的 `max_value`(`tslider.max_value = 15.0`)**
	#   —— -  它才是**真正产生下发值**的那一环:`value_changed` 把滑块值**不钳位地**写进
	#   `Settings.royale_match_min`(下面的 `Settings.royale_match_min = v`),而下发的
	#   `match_time` 读的是**内存里那个值** —— 装载钳位 [1,30] 只在下一次**装载**时才生效。
	#    ->  把 `max_value` 放宽(比如到 60)之后,上面所有断言(含环一环二)**照样测试全部通过**,
	#   而实际下发的 `match_time` 已经能到 3600  ->  1800s 的上界**静默失效**。
	#   - 另一条同源的口子(更远一环、本文件不钉):server/royale_host.gd 的 `_cfg_match_time`
	#   把客户端给的 `match_time` **原样收下**,worker 侧也不钳位  ->  上界**依赖客户端行为**,
	#   不是无条件成立的(登记见 CLAUDE.md)。
	#   - 判据取**数值比较而不是子串**(与上面那两条片段判据略有不同,理由在下面):
	#   `contains("15")` 挡不住 `15.0 → 150.0`(它含子串 "15"),而那正是本条要抓的"放宽"。
	#   故把 `max_value = <数字>` 抽出来比数值;容忍空白/整数写法(与同族的"宁可响亮虚假失败（测试用例误报）"同向)。
	# ── 注意： 2026-10-03(T2 整屏搬 `.tscn`):这一环的**家搬了**,读法跟着搬 ──
	#   搬之前:`scenes/mp_lobby.gd` 的 `_build_match_time_row()` 里那句 `max_value = 15.0`。
	#   搬之后:整个「创建弹层」是 `scenes/mp_lobby.tscn` 的**静态基础结构框架**,而
	#   `_build_ui()` 只灌 `value = Settings.royale_match_min` 并接 `value_changed`,
	#   **不再碰上限**  ->  上限的唯一来源就是基础结构框架里 `MatchTimeSlider` 节点的 `max_value`。
	#   - 为什么不能就此把这一环删掉:`_set_create_visible`/`value_changed` 那条路没变 ——
	#     放宽上限之后环一环二保持测试通过,而下发的 `match_time` 仍能到 3600(静默失效)。
	#   - 所以本条**改读 `.tscn`**,并且:
	#     ① 读不到基础结构框架  ->  响亮报"读不到"(不伪装成"第三环变了");
	#     ② `MatchTimeSlider` 必须**恰一个**且仍是 `HSlider`(读错一个同名节点会得到别的上限,
	#        而数值断言看起来保持测试通过 —— 与 `_unique()` 同一条纪律);
	#     ③ 仍比**数值**;
	#     ④ 另加一条**反向**断言:`.gd` 里不许再出现 `_time_slider.max_value`
	#        (否则上限回到两个家:基础结构框架那份被读、代码那份生效 —— 判据会被架空)。
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
	# ── B 册 Task 5(2026-09-19):3v3 的**收集块 + 宽限谓词**也要各有一针 ──
	# - 此前这里与 royale 分支**不对称**:royale 那条三截谓词断言在,3v3 一条都没有。缺它时
	#   「保留 `var stale_team` 声明、掏空 `for tcode in lobby.team_rooms:` 循环」或「把
	#   tr.in_match / TEAM_MATCH_ESTIMATE 从宽限里摘掉」都能编译通过、上面四条(三张表名、
	#   提前 return 的并列判据、拆除列表)测试全部通过 —— 而那正是「守卫在、3v3 永不被清」那一档
	#   (-worker 端口永久泄漏)。收集块与谓词行**各钉一次**:只钉删除列表那行不够,它由
	#   stale_team 变量喂饱,变量恒空也照过。
	if not body.contains("for tcode in lobby.team_rooms"):
		_fail = "_sweep_stale_rooms 没有收集 3v3 超龄房的循环(team_rooms 永不被扫 → 端口永久泄漏)"; return
	# 注意： B 册 Task 7(评审留的**同粒度**洞):上面那条只认 `for …` 的**头行** —— 保留头行、
	#   只把循环体掏空(删掉 `stale_team.append(tr)`)时,上面那条 + 既有的 `contains("stale_team")`
	#   + 三表并列判据 + 拆除列表**四条测试全部通过**,而 `stale_team` 恒空  ->  3v3 房**永不被清**(端口泄漏)。
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
	# 批次 2 改法:_sweep 不再**直接**杀 worker / 删房,改走拆除统一集中处理(带 KILL 形态)。
	# 「杀 worker + 删房 + 回收端口」这件事本身仍被 _check_teardown_funnel 钉住(那些动作只允许
	# 出现在 _teardown_room 体内);这里只认新入口。
	# - 别改回「直接调 _kill_worker」:那样端口回收会绕过统一集中处理,正是本层补过三次的那个泄漏。
	if not body.contains("teardown_room(") or not body.contains("TEARDOWN_KILL"):
		_fail = "_sweep_stale_rooms 未走拆除收口(应调 _lobby.teardown_room(..., LobbyRooms.TEARDOWN_KILL, ...))"; return
	# 三张注册表都要被拆:rooms(1v1) / royale_rooms / team_rooms 并存,漏一张 = 那张的端口永久泄漏
	if not body.contains("stale + stale_royale"):
		_fail = "_sweep_stale_rooms 未把多张注册表的超龄房一并拆除"; return
	# 注意： 批次 3(Task 4):3v3 那一支的**两条**判据 —— 只查「拆除列表」是不够的,因为
	#   末尾那条「全空则提前 return」的并列判据是**独立的第二条**退出路径:
	#     `if stale.is_empty() and stale_royale.is_empty(): return`
	#   漏掉 stale_team 时,**只有 3v3 房超龄**的那次 tick 会当场 return、永远不清扫 →
	#   端口永久泄漏;而拆除列表那行照旧在、房间收集块照旧在  ->  只查列表的断言**测试全部通过**。
	#   这正是本层反复补的同一个失败模式(见 lobby_rooms.teardown_room 的注释)的第四种形态,
	#   且症状是**静默**的。故这里逐个明确提示三张表、并单独钉住那条提前返回。
	if not body.contains("stale_team"):
		_fail = "_sweep_stale_rooms 完全没扫 3v3 房(team_rooms 的超龄房 → worker 端口永久泄漏)"; return
	if not body.contains("stale.is_empty() and stale_royale.is_empty() and stale_team.is_empty()"):
		_fail = "_sweep_stale_rooms 的「无超龄房则提前 return」守卫漏了某张注册表(只有那张表的房超龄时永不清扫 → 静默端口泄漏)"; return
	if not body.contains("stale + stale_royale + stale_team"):
		_fail = "_sweep_stale_rooms 的拆除列表未含全部三张注册表(未被扫到的那张 → 端口永久泄漏)"; return
	# 汇总 print 必须把 3v3 那一档的**数据**报出来(照实登记的估值界;漏了只是日志失真,
	# 但它是上面那些界的**唯一**读数)。
	# - 2026-10-02 降精度:判据钉**数据**(实参 `stale_team.size()`),不钉文案里的字面量 "3v3"
	#   —— 那句 print 里的 "3v3" 只是标签,把标签留着、把那个实参换成别的变量的变异它拦不住;
	#   反之换个写法的文案不该红。要拦的变异:**不再把 3v3 超龄数报进汇总行**(界变了而日志读不出)。
	#   - 那条 print 是**跨行**的(格式串一行、实参表在后续几行),故连同实参一起收集到 `]` 收束。
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
	# - 本函数**跑到尾**的凭证(判据在 _finish;理由见文件头那段)。下面的每个 _check_* 相同机制。
	_done.append("_check")

# ── 2026-09-21(「看得见进不去」批)新增:worker pid 的登记与归还 ──
# - 为什么钉它:「对局中的房什么时候消失」这条判据是**这一局的 worker 进程还在不在**
#   (三种模式的 worker 都在对局结束时自己退)。pid 的来源就是这里:端口 → pid 的映射。
# - 归还端口时**不清 pid** 的后果是**静默**的:大厅会认为一个已经结束(甚至端口已被复用给
#   别的局)的对局还活着 —— 房永远不出现在回收名单里,而端口与列表位一直占着。
func _check_worker_pid_tracking() -> void:
	if _fail != "":
		return
	var L := WorkerLauncher.new()
	# 直接摆内部表(与 _check_team_spawn_guard 只喂非法输入同一个取向:本冒烟不该真启动子进程)。
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段。
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


# ── 2026-09-21(「看得见进不去」批)新增:三条 join 的**拒绝守卫与文案** ──
# - 为什么是源码级:文案是**发给玩家看的字符串**,而探针里没有对端 ——
#   `NetBus.reply` 在 `is_peer_live(caller)` 为假时**静默跳过**(见 NetBus.reply 的注释),
#   所以那句话在探针里根本观测不到。行为面(调用方没被 append 进 players)由
#   `tests/probe/lobby_visibility_probe.tscn` 阶段 1/②/③ 断言,这里断言的是**那句话本身**。
# - 为什么文案值得一条断言:1v1 原先对"对局进行中"说的是「房间已满」—— 那是假话,而且会命中
#   大厅页 `_on_server_message` 的**自动刷新**分支(那条只认旧文案)。改文案 = 静默改行为。
# - 另钉一条反向:三条守卫必须**用"这一局在进行中"判**(started / in_match),不许退化成
#   "房满 / 人数"之类的替代判据 —— 后者在"房里只剩 1 人"时放行,正是本批要堵的那档。
# 注意： 2026-09-21(回局入口批)补一条**前提**(下方判据与文案一个字节都没改):
#   `tests/probe/lobby_visibility_probe` 阶段 1②③ 断的是「对局中的房**对无凭据者**一律拒绝」——
#   "回局"那条路**刻意不经过这三条守卫**:它走 `rejoin_request`(大厅侧 `on_rejoin_request`,
#   按凭据表放行),客户端侧则在列表里把持凭据的那一行画成**可点**(阶段 8)。
#   故**不许**在这三个 handler 里插"有凭据就放行"的分支 —— 那等于把"回局"混进"入房"语义,
#   而本函数这条守卫**当场变成一句空话且红不起来**(它判的是那条 `if` 还在,前面加一条
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


# ── 2026-09-21 新增:对局中房间的**回收梯接线** ──
# - 为什么"接线"要单独钉:行为探针(`tests/probe/lobby_visibility_probe.tscn` 阶段 4)是**手工调**
#   `_reclaim_finished_matches()` 的 —— 把 `_process` 里那次调用删掉,行为探针**照样测试全部通过**,
#   而生产里房永远不会被回收(端口与列表位白占)。本仓对这类"两半"的既有先例:
#   `team_room_smoke` ⑨①(接线面)对 `hud_declarative_probe` ③(行为面)—— 缺一不可。
# - 另一条:回收不能绕道直接删注册表。既有的 `_check_teardown_funnel` 只扫
#   `server/lobby_rooms.gd`,**扫不到写在 room_manager 里的绕道** —— 那正是本函数存在的理由。
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
	var mo := ScanUtil.func_body(code, "_match_over")
	if mo.is_empty():
		_fail = "找不到 _match_over"
		return
	if not mo.contains("pid <= 0") or not mo.contains("port <= 0"):
		_fail = "★ _match_over 没把 port/pid <= 0 判成「没结束」(开局那一瞬会被自己的回收梯拆掉)"
		return
	# 注意： 阶段 2-B(Task 4,2026-09-21)新增的**反向**断言:凭据表作废(`rejoin.drop_port`)必须
	#   留在 `teardown_room` 体内(上面那条"绕道直接删注册表"的同一件事 —— 凭据表也是一张注册表)。
	#   - 为什么必须在这里另加一条:上面那条正向断言(`_check_teardown_funnel`)只扫
	#   `server/lobby_rooms.gd`,**扫不到写在 room_manager 里的绕道** —— 这正是本函数存在的理由。
	#   - 实测(未加本条时):把 `lobby.rejoin.drop_room(room.code)` 挪进 `_reclaim_finished_matches`
	#   的拆除循环,**本冒烟照旧报 OK** —— 那份"别把这段挪到调用方"的纪律当时只剩注释在守。
	#   - 这是一条**否定式**判据(不许出现),不是"必须出现":凭据登记(`rejoin.grant`)在
	#   `_grant_rejoin` 里、是正常路径,别把两者混为一谈。
	#   - 判据**只收 `drop_port(`/`drop_room(` 两种写法**:那是"整房作废"(拆除动作)。`drop_token(`
	#   是"消费掉某一份凭据",不是拆除动作、将来可能合法地出现在别处,收进来只会造出虚假失败（测试用例误报）。
	#   - 两种写法都收:本函数落地当天 `drop_room` 改名成了 `drop_port`(见 `_check_teardown_funnel`
	#   那条注释)—— 只留旧名的门对**当前**的绕道彻底失明,只留新名的门认不出有人把按 code 的
	#   版本加回来。多留一个字符串在这里是**加宽判据面**,与"放宽白名单"是相反的方向。
	for stale in ["rejoin.drop_port(", "rejoin.drop_room("]:
		if code.contains(stale):
			_fail = "★ room_manager 里出现 %s —— 凭据作废必须留在 teardown_room 体内(挪到调用方 = 同一件事两处实现)" % stale
			return
	_done.append("_check_reclaim_ladder")


# ── 阶段 2-B(Task 4,2026-09-21)新增:四个 spawn 点**都**登记回局凭据 ──
# - 为什么是源码级:登记跑在"spawn 成功之后",要真启动 worker 才走得到 —— 本文件里没有可用的
#   行为探针(真链路归 **Task 8 的 `tests/probe/rejoin_probe.sh`**,本步不重复造)。而**漏掉任何一个**
#   spawn 点的症状是**静默**的:那个模式的玩家点「回到对局」永远得到"凭据已失效",大厅侧
#   一行报错都没有 —— 正是本仓反复登记的"守卫在、东西不在"那一档。
# - 四个点**逐个明确提示**,不数 `_grant_rejoin(` 的个数:个数会随实现漂,而且数不出"漏的是哪一个"
#   (口径同 `_check_teardown_funnel` 的注释)。`royale_start_ai` 最容易漏 —— 它是 AI 补位那条
#   冷门分支,而且它的 `granted` 只许收真人 role(范围必须与 token 循环一致)。
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
		# ② 登记必须排在 **spawn 调用之后**:凭据里的 worker_pid 是"这一局还在不在"的唯一判据,
		#    登记早了 pid 还是 0 → `RejoinRegistry.decision` 把还在打的局判成"已结束"。
		#    - 判据落在**同一函数体内的先后**(不是"文件里某个位置")—— 顺序错了不报错,只静默失真。
		var at_spawn := body.find("spawn_")
		if at_spawn < 0 or body.find("_grant_rejoin(") < at_spawn:
			_fail = "★ %s 的 _grant_rejoin( 未排在 spawn 调用之后(凭据里的 worker_pid 会是 0)" % f
			return
	# ③ 凭据表的 GC 必须搭在 30s 回收梯上:TTL 只是表的上界,不为它另立定时器(同一件事不留两处)
	var rec := ScanUtil.func_body(code, "_reclaim_finished_matches")
	if rec.is_empty():
		_fail = "找不到 _reclaim_finished_matches"
		return
	if not rec.contains("lobby.rejoin.prune("):
		_fail = "★ 回收梯未清过期凭据(lobby.rejoin.prune)—— 凭据表只增不减,表会无限长大"
		return
	_done.append("_check_rejoin_spawn_wiring")


func _finish() -> void:
	# 注意： 名单对账(见文件头那段)。**只在 `_fail` 为空时**做:`_fail` 非空说明已有正式断言失败,
	#   那时早就打 FAIL 了,再叠一条"没跑到尾"只会把真原因淹掉。
	# - 判据为什么成立:`_fail` 为空时,任何 `_check_*` 的提前 return 都只可能来自函数开头那条
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
			# 反向:名单比实跑少  ->  加了新检查却没把它登记进 CHECK_NAMES(新检查会**不受本对账保护**)。
			# 让它红,而不是静默放行 —— 那正是本条要堵的方向。
			_fail = ("★★ 跑过的检查数(%d)与 CHECK_NAMES(%d)不符 —— 加/删了 _check_* 却没同步名单"
					% [_done.size(), CHECK_NAMES.size()])
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备(三张注册表的在局宽限界逐个钉死:1v1 裸界 / 大乱斗 ROYALE_MATCH_TIME_CEILING(可证上界) / 3v3 TEAM_MATCH_ESTIMATE;%d 项检查全部跑到尾)" % _done.size())
	quit(0)
