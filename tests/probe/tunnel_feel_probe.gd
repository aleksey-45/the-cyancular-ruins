extends Node

# P2P 隧道多实例网络性能基准测试探针。场景模式运行（依赖 Autoload 单例）。
#
# 用法（通常由 tests/probe/tunnel_feel_probe.sh 编排调度）：
#   "$GODOT" --path . --log-file host.log res://tests/probe/tunnel_feel_probe.tscn -- \
#       --side=host --seconds=90 --netstat
#   "$GODOT" --path . --log-file guest.log res://tests/probe/tunnel_feel_probe.tscn -- \
#       --side=guest --code=12345 --seconds=90 --netstat
#
# 测试目标与设计：
# 1. 核心指标：网络延迟、预测回滚频率与帧耗时波动（卡顿率统计）。
# 2. 数据采集：
#    - 帧耗时分位数（p50/p95/p99/max）与卡顿帧统计（>16.7ms / >33.3ms / >50ms）
#    - 房间加入与场景切换耗时
#    - EasyTier 动态端口转发链路有效性
#    - 网络指标（客户端未确认输入积压、ping、回滚累计，服务端输入队列深度）
# 3. 设计原则：
#    - 确定性输入序列：基于预设时间表驱动玩家行为，保证不同测试运行结果具备可比性。
#    - 完整大厅交互：客机通过真实大厅流程加入房间，完整触发 EasyTier 隧道动态端口映射。
#    - 真实渲染模式：使用非 headless 模式运行，纳入渲染与 UI 绘制开销。
#
# 前置条件：
# - 运行目录需包含 easytier 二进制组件及 relay.txt 配置文件。

const PREFIX := "tunnel_feel_"

# ── 固定操作序列（确定性时间表；双端执行同一份序列）──
#   - 每一项包含 `[起始时间, 结束时间, 动作名称]`（单位：秒）。在 _seq_tick 中映射为具体的输入动作。
#   - 采用确定性时间表而非随机走位：避免随机行为导致多次测试之间的帧耗时数据失去可比性。
#   - 覆盖四种典型回滚敏感场景：长距离水平移动、贴地跳跃、开火射击（含后坐力与弹丸生成）、急停反向。
const SEQ: Array = [
	[0.0, 2.5, "run_right"],
	[2.5, 3.5, "jump_right"],
	[3.5, 5.5, "run_right"],
	[5.5, 7.0, "jump_left"],
	[7.0, 9.0, "run_left"],
	[9.0, 9.2, "stop"],
	[9.2, 11.0, "run_right"],
	[11.0, 13.0, "jump_left"],
	[13.0, 15.0, "run_left"],
	[15.0, 15.2, "stop"],
]
const SEQ_PERIOD := 15.2      # 单轮序列循环周期（秒）
const FIRE_EVERY := 0.5       # 定时开火间隔（与走位解耦，确保采集到移动中射击的单帧耗时）

const ENTER_TIMEOUT := 120.0  # 进入对局超时上限（包含 P2P 隧道建立与房间码握手协商，冷启动预留充足冗余）
const LOBBY_TIMEOUT := 20.0   # 等大厅页挂上的上限
# - 3v3 选边:等一会儿再选,让 `team_pick` 落在大厅已经把本端登记进房之后
#   (`team_pick` 要按 peer 反查房,太早会被当"不在房里"丢掉)。
const TEAM_PICK_DELAY := 2.0
# - 房主点「开始」:必须等成员陆续进来。等太短会被"人数不足/未满员"拒掉,而那次拒绝
#   只出现在房主状态栏,客机侧完全看不到 -> 表象与"隧道没通"难以分辨。
const START_DELAY := 14.0

var _side := "host"
var _code := ""
var _seconds := 90.0
var _seconds_set := false
# 模式:duel(1v1)/ royale(大乱斗)/ team(3v3)。三者在同一个统一大厅页(`mp_lobby`)里,
# 差别只在:建房前的模式选择、加入时发的 RPC、以及 royale/team 要房主点开始、3v3 还要选边。
var _mode := "duel"
var _team := 1                # 仅 team:本端选哪一队(1 或 2)

var _measure: Node = null
var _t := 0.0
var _phase := "boot"          # boot -> lobby -> entering -> playing -> done
var _phase_t := 0.0
var _t_click := -1.0          # 点下"建房/加入"的时刻
var _t_match := -1.0          # 真进对局的时刻
var _page: Node = null
var _code_seen := ""          # 房主自己建出来的房号
var _guest_port := 0          # 客机实际连的端口(= 隧道转发绑定口 Q)
var _guest_addr := ""
var _note: Array[String] = []
var _seq_t := 0.0
var _fire_t := 0.0
var _picked := false          # team:本端选边是否已发出
var _started := false         # host:开局请求是否已发出(royale/team 要房主点开始)
var _expect := 2              # 房主等房里凑够几人再点开始(duel 用不到)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--side="):
			_side = a.trim_prefix("--side=")
		elif a.begins_with("--code="):
			_code = a.trim_prefix("--code=")
		elif a.begins_with("--seconds="):
			_seconds = float(a.trim_prefix("--seconds="))
			_seconds_set = true
		elif a.begins_with("--mode="):
			_mode = a.trim_prefix("--mode=")
		elif a.begins_with("--team="):
			_team = int(a.trim_prefix("--team="))
		elif a.begins_with("--expect="):
			_expect = int(a.trim_prefix("--expect="))
	# - 测量器挂 `root`(不是本场景):主菜单 -> 大厅页 -> 对局 这一串换场都不该把它带走,
	#   而帧时间恰恰要跨这三段连续量(进场那一下的卡顿正是最该看到的)。
	var m: Node = load("res://tests/probe/tunnel_feel_measure.gd").new()
	m.set("side", _side)
	get_tree().root.add_child.call_deferred(m)
	_measure = m
	print("PROBE[%s]: 启动(side=%s mode=%s code=%s seconds=%s)" % [_side, _side, _mode, _code, str(_seconds)])
	# - 客机的前置门:没有 `easytier/`(四件套)或 `relay.txt` 里一个节点都没有时,
	#   `Tunnel.available()` / `has_initial_peers()` 会让 `_join_with_code` 直接走
	#   `missing_hint()` 返回 —— 客机一步都不会走,而下面等进对局那条梯会在 120s 后
	#   报 NO-MATCH。那种输出与"隧道建起来了但对局进不去"长得一样,读的人会去查错的地方。
	#   故在这里当场判掉,并把它自己的提示原样带出来。
	if _side != "host":
		if not Tunnel.available():
			_finish("NO-TUNNEL:%s" % _tunnel_missing_hint())
			return
		if not Tunnel.has_initial_peers():
			_finish("NO-TUNNEL:%s" % Tunnel.no_relay_hint())
			return
	# 先等一帧让 measure 挂进树,再开始换场(换场过程中 root 正忙,add_child 会静默失败)。
	await get_tree().process_frame


# `Tunnel.missing_hint()` 的文案(它自己的探针在 core/net/tunnel.gd;这里不重写第二份)。
func _tunnel_missing_hint() -> String:
	return Tunnel.missing_hint()


func _process(delta: float) -> void:
	_t += delta
	_phase_t += delta
	match _phase:
		"boot":
			_to_lobby()
		"lobby":
			_lobby_tick()
		"entering":
			_entering_tick()
		"playing":
			_playing_tick(delta)
		"done":
			pass


# ── 阶段 1:主菜单 -> 大厅页 ──

func _to_lobby() -> void:
	# 走生产入口:主菜单那颗「多人模式」按钮做的正是 `PvpSession.reset()` + 换场。
	# 手搓换场会漏掉 reset,而 reset 决定了地址/端口从零开始 —— 那正是双实例互不串的前提。
	if _side == "host":
		# 房主:自建房 -> 必须让 `_ensure_own_server` 起本机服务端并起隧道。
		# 本机服务端 exe 只在导出包里存在(开发树没有 `Cyancular Ruins Server.exe`),
		# 故本探针要求跑在导出目录(`.sh` 会负责铺好)。
		pass
	else:
		# 客机:预置地址(回环)—— 它要连的是自己那条隧道转发口,而转发口是隧道起来之后
		# 才知道的(`Tunnel.forward_port()`),由大厅页自己填。这里只把地址摆对。
		PvpSession.server_address = "127.0.0.1"
	PvpSession.player_name = "FEEL-%s" % _side
	print("PROBE[%s]: 切换至大厅界面" % _side)
	get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn")
	_advance("lobby")


func _lobby_tick() -> void:
	if _page == null:
		var p := get_tree().current_scene
		if p != null and p.has_method("_on_create_pressed"):
			_page = p
	if _page == null:
		if _phase_t > LOBBY_TIMEOUT:
			_finish("NO-LOBBY:%.0fs 内大厅页面未完成挂载（场景切换超时）" % LOBBY_TIMEOUT)
		return
	if _side == "host":
		# 建房:先把模式切对(统一大厅页三种模式共用,`_create_payload` 按 `_create_mode` 出载荷),
		# 再点创建。必须是公开房 —— 客机是按房号从列表加入的,私密房不进列表。
		_page.call("_apply_create_form", _mode_const())
		var pub = _page.get("_public_check")
		if pub != null:
			pub.set("button_pressed", true)
		print("PROBE[host]: 点击「创建房间」（模式 %s）" % _mode)
		_page.call("_on_create_pressed")
	else:
		if _code == "":
			_finish("NO-CODE:客机未指定 --code=<房间号>")
			return
		# 加入:模式显式指定，仅查询目标模式对应的房间列表
		print("PROBE[guest]: 按房间号加入 %s（模式 %s）" % [_code, _mode])
		_page.call("_join_code", _code, _mode_const())
	_t_click = _t
	_advance("entering")


func _mode_const() -> String:
	match _mode:
		"royale":
			return PvpSession.MODE_ROYALE
		"team":
			return PvpSession.MODE_TEAM
		_:
			return PvpSession.MODE_PVP


# 房里现在有几个人。房主靠它判"够不够开局"。
# - 取 `_wait_count` 那一行渲染出来的文案再解出第一个整数。那是本页当下唯一的权威陈述:
#   它由服务端广播(`team_room_state` / `room_state`)驱动 —— 大乱斗写
#   `"N / M 人(至少 2 人可开局)"`、3v3 由 `_team_count_text` 拼,两种都以 `"N /"` 开头。
# - 不去数名单行的子节点:3v3 的名单里混着队头行与空位行,数出来不是人数。
# - 不用 `RegEx`:导出模板把该模块裁掉了(`export_presets.cfg` 的自定义模板),
#   在导出包里 `RegEx` 是未声明标识符 —— 本探针是跑在导出包上的,故只能手解。
func _room_player_count() -> int:
	if _page == null:
		return 0
	var lbl = _page.get("_wait_count")
	if lbl == null:
		return 0
	var txt := str(lbl.get("text")).strip_edges()
	var head := txt.split(" ", false)[0] if not txt.is_empty() else ""
	return int(head) if head.is_valid_int() else 0


# ── 阶段 2:等进对局 ──

func _entering_tick() -> void:
	# 主机端：获取并输出当前房间号（供测试编排脚本传递给客机实例）
	if _side == "host" and _code_seen == "":
		_code_seen = _read_host_code()
		if _code_seen != "":
			print("PROBE[host]: 房间号 = %s" % _code_seen)
	# 客机端：记录实际连接的本地转发端口，用于验证是否正确走 EasyTier 隧道端口转发链路
	if _side == "guest" and _guest_port == 0:
		var fp := int(Tunnel.forward_port())
		if fp > 0:
			_guest_port = fp
			_guest_addr = PvpSession.server_address
			_note.append("客机经隧道转发端口 Q=%d 连接(隧道连接生效)" % fp)

	# 模式特定流程处理：
	# 1. 3v3 模式自动选边
	if _mode == "team" and not _picked and _phase_t > TEAM_PICK_DELAY:
		_picked = true
		print("PROBE[%s]: 队伍选择 → %d 队" % [_side, _team])
		_page.call("_on_wait_pick", _team)
	# 2. 大乱斗与 3v3 模式由房主在满足最小人数要求后触发开始
	if _side == "host" and _mode != "duel" and not _started:
		var n := _room_player_count()
		if n >= _expect and _phase_t > START_DELAY:
			_started = true
			print("PROBE[host]: 房间内玩家数 %d (满足阈值 ≥%d)，点击「开始游戏」（模式 %s）" % [n, _expect, _mode])
			_page.call("_on_wait_start_pressed")

	if _in_match():
		_t_match = _t
		var took := _t_match - _t_click if _t_click >= 0.0 else -1.0
		print("PROBE[%s]: 成功进入对局（耗时 %.1fs）" % [_side, took])
		_advance("playing")
		return
	if _phase_t > ENTER_TIMEOUT:
		_finish("NO-MATCH:%.0fs 内未能进入对局（隧道连接/房间码/角色认领超时）" % ENTER_TIMEOUT)


func _in_match() -> bool:
	var s := get_tree().current_scene
	if s == null:
		return false
	var p := str(s.scene_file_path)
	return p.ends_with("pvp_game.tscn") or p.ends_with("royale_game.tscn") or p.ends_with("team_game.tscn")


# ── 阶段 3:固定操作序列 + 采样 ──

func _playing_tick(delta: float) -> void:
	if not _seconds_set:
		_seconds = 90.0
	_seq_tick(delta)
	if _t - _t_match >= _seconds:
		_advance("done")
		_finish("")


# 基于确定性时间序列驱动角色移动：仅根据时间步进触发预设动作，确保双端执行完全一致的操作序列。
func _seq_tick(delta: float) -> void:
	_seq_t += delta
	if _seq_t >= SEQ_PERIOD:
		_seq_t -= SEQ_PERIOD
	var act := "stop"
	for row in SEQ:
		if _seq_t >= float(row[0]) and _seq_t < float(row[1]):
			act = str(row[2])
			break
	Input.action_release("left")
	Input.action_release("right")
	Input.action_release("up")
	Input.action_release("down")
	match act:
		"run_right":
			Input.action_press("right")
		"run_left":
			Input.action_press("left")
		"jump_right":
			Input.action_press("right")
			Input.action_press("up")
		"jump_left":
			Input.action_press("left")
			Input.action_press("up")
		"stop":
			pass
	# 定时开火:按住不放只会算一次 just_pressed,故"按下 -> 松开"。
	# - 动作名是 `attack`(见 `project.godot` 的 `[input]` 段与 `player.gd` 的读法);
	#   本夹具第一版写成 `fire` —— 那个动作不存在,`Input.action_press("fire")` 会静默
	#   什么都不做(不报错),于是"开火帧"整段没被采到,而读数上看不出任何异常。
	_fire_t += delta
	if _fire_t >= FIRE_EVERY:
		_fire_t = 0.0
		Input.action_press("attack")
		await get_tree().process_frame
		Input.action_release("attack")


func _read_host_code() -> String:
	# 房号来自 `PvpSession.room_code` —— 大厅页在 `_on_room_created` 里经 `note_room(code, …)`
	# 落的正是它(见 `mp_lobby.gd` 那段),它是这条信息的单一来源。
	# - 早先这里想去翻大厅页的 `_grid` 房卡元数据,那是错的:`_grid` 是收到 `room_list`
	#   之后才填的,而房主建房后列表不会自动回来(本页没有轮询) -> 恒读到空串。
	#   而且那种写法还把一个本该直接读的值绕成了"从 UI 反推"。
	return PvpSession.room_code


func _advance(p: String) -> void:
	_phase = p
	_phase_t = 0.0


# ── 收尾:写这一侧的读数 ──

func _finish(fail: String) -> void:
	var lines: Array[String] = []
	lines.append("side=%s" % _side)
	lines.append("mode=%s" % _mode)
	lines.append("team=%d" % _team)
	lines.append("verdict=%s" % ("OK" if fail == "" else fail))
	lines.append("seconds_played=%.1f" % (0.0 if _t_match < 0.0 else _t - _t_match))
	lines.append("enter_seconds=%.2f" % (-1.0 if _t_match < 0.0 or _t_click < 0.0 else _t_match - _t_click))
	lines.append("room_code=%s" % (_code if _side == "guest" else _code_seen))
	lines.append("tunnel_forward_port=%d" % int(Tunnel.forward_port()))
	lines.append("tunnel_available=%s" % str(Tunnel.available()))
	lines.append("connected_port=%d" % _guest_port)
	lines.append("connected_addr=%s" % _guest_addr)
	lines.append("server_port=%d" % PvpSession.server_port)
	lines.append("worker_port=%d" % PvpSession.worker_port)
	if _measure != null and is_instance_valid(_measure):
		for l in _measure.call("report_lines"):
			lines.append(str(l))
	for n in _note:
		lines.append("note=%s" % n)

	var path := ProjectSettings.globalize_path("user://%s%s.txt" % [PREFIX, _side])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("═══ 本端指标统计(%s) ═══" % _side)
	for l in lines:
		print("  " + l)
	print("TUNNEL FEEL [%s]: %s -> %s" % [_side, "OK" if fail == "" else fail, path])
	# 顺序要紧:`quit()` 会让 `_measure` 的退出钩子跑不到,故读数必须先落盘(上面已落)。
	await get_tree().process_frame
	get_tree().quit(0 if fail == "" else 1)
