extends SceneTree
# 僵尸房间清理——源码级结构检查(仿 player_contract_smoke)。锁的结构横跨两个文件(2026-09-14 拆账本后):
#  **room_manager.gd**:1) SWEEP_INTERVAL(10min)/MAX_ROOM_AGE(2h)常量;3) _process 每周期调
#   _sweep_stale_rooms;4) _sweep_stale_rooms 对超龄房走拆除收口;5) 大乱斗在局宽限谓词同时引用
#   RoyaleHost.MATCH_TIME 与 rr.in_match,且 1v1 仍是裸 MAX_ROOM_AGE。
#  **lobby_rooms.gd**(账本/收口搬来这里):2) 建房时给 created_at 赋时间戳;收口体外不得出现
#   端口归还/注册表删除(见 _check_teardown_funnel);杀 worker 的实现另在 worker_launcher.gd。
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
	_finish()


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
			for pat in ["_release_port_later(", "launcher.release_now(", "royale_rooms.erase(", "rooms.erase("]:
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
			for bad in ["--players", "--max-role", "_role_bound", "_expected_players"]:
				if t.contains(bad):
					_fail = "%s 的代码里仍有旧 argv 协议标识符 %s(应已换成 --roles 集合)" % [f, bad]
					return
	# 正向:集合协议必须在两边都在位(只改一边 = 拉起的 worker 收不到 role 集合,静默降级)
	for f in ["res://server/server_main.gd", "res://server/worker_launcher.gd"]:
		if not FileAccess.get_file_as_string(f).contains('"--roles"'):
			_fail = "%s 未接 --roles(集合协议只接了一半?)" % f
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
	# 批次 2 改法:_sweep 不再**直接**杀 worker / 删房,改走拆除收口(带 KILL 形态)。
	# 「杀 worker + 删房 + 回收端口」这件事本身仍被 _check_teardown_funnel 钉住(那些动作只允许
	# 出现在 _teardown_room 体内);这里只认新入口。
	# ★ 别改回「直接调 _kill_worker」:那样端口回收会绕过收口,正是本层补过三次的那个泄漏。
	if not body.contains("teardown_room(") or not body.contains("TEARDOWN_KILL"):
		_fail = "_sweep_stale_rooms 未走拆除收口(应调 _lobby.teardown_room(..., LobbyRooms.TEARDOWN_KILL, ...))"; return
	# 两张注册表都要被拆:rooms(1v1) 与 royale_rooms 并存,漏一张 = 那张的端口永久泄漏
	if not body.contains("stale + stale_royale"):
		_fail = "_sweep_stale_rooms 未把两张注册表的超龄房一并拆除"; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_ROOM_SWEEP FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_ROOM_SWEEP OK: 10min 扫 2h 超龄房间,杀 worker+删房 结构齐备(含大乱斗在局宽限界钉死)")
	quit(0)
