extends Node

# 大乱斗 B1/B2 探针的**观察者**(客户端子进程用;见 royale_bound_probe.gd 文件头)。
# 挂在 get_tree().root 上(不是探针场景里):切场景不会把它带走 → 它能跨「实际大厅场景 →
# 真 royale_game 场景」那次换场继续待在树里,并在**换场之后**读真 royale_game 实例的状态。
# 这正是 B2 的要害:那三条开局载荷与 match_start 落在同一次 poll,而新场景那时还不存在。
#
# 它只做两件事,都**不消费**载荷(订阅只为记到达帧号当证据):
#   1. 驱动实际大厅场景(创建房间 / 加入房间)—— 见 royale_bound_probe.gd 的流程说明;
#   2. 换场后静置一小段,断言真 royale_game 上「昵称表 / 头顶 ID / 角色色相 / 禁武器」
#      四样都到位,然后写结果文件。

const RESULT_PREFIX := "royale_b12_probe_"
const GO_FILE := "user://royale_b12_probe_go.txt"
const LOBBY_ADDR := "127.0.0.1"   # 本探针大厅的地址(实际大厅页按 `PvpSession.server_address` 连)
# 与 royale_bound_probe.gd 的 HUE_C1/HUE_C2、DISABLED_SLOT 保持一致(两个客户端的本端选项)
const HUE_BY_ROLE := {1: 90.0, 3: 180.0}
const DISABLED_SLOT := 3
# 注意： 等待形状(2026-10-03 修):**等载荷落地 + 截止线**,不是"固定静置 N 秒后断言"。
#   旧写法是 `const SETTLE := 2.0` + `_stage_t < SETTLE  ->  return`,它把**两条不同的判据**
#   混成了一条:"载荷有没有到" 与 "到得够不够快"。后者**不是本探针的断言对象** ——
#   文件头的断言对象是「换场后那四样到底有没有进新场景」。
#
#   实测(2026-10-03,纯生产路径、无任何插桩,2/2 客户端):
#     换场 → 收到 `match_sync_data` 的**墙钟**间隔 = c1 **5906ms** / c2 **3900ms**。
#   成因(已定位,见 probe 文件头 §B2 结论):客户端换场那一刻要把整个
#   `royale_game`(Level0 世界 + 碰撞 + HUD)建起来,主循环**卡住 ~8 秒**
#   (探针环境里同时有大厅 + worker + 两个客户端共 4 个 Godot 抢 CPU,实测值被放大);
#   卡顿期内客户端不排空 UDP 收缓冲  ->  包被内核丢  ->  **可靠包靠 ENet 退避重传**,
#   在客户端恢复后才整批涌进来(同一瞬间 `round_state` 计数从 9 跳到 20,是同一现象)。
#    ->  固定 2.0s 会**在这条载荷到达之前**就断言  ->  红;而它红的原因是**探针的等待形状**,
#     不是产品丢包。故改成等载荷。
#
#   - 测试有效性没有降低:载荷**始终不到**(= 真丢包)时,`PAYLOAD_DEADLINE` 到点照样断言  ->  红。
#   - 也没有变成恒真:若 `_on_match_sync` 没把 `_names/_hues/...` 应用上去,断言照样红。
const SETTLE_AFTER_PAYLOAD := 0.5   # 应答落地后再等一拍:观察者的订阅可能排在游戏的订阅者**之前**
const PAYLOAD_DEADLINE := 25.0      # 等应答的上限(探针时间);到点仍没到  ->  照常断言(红)
const DEADLINE := 50.0

var who := "c1"
# drive = 驱动实际大厅走「建房/加入 → go_match → 转连 → 开局」全流程(自然时序,见 royale_bound_probe);
# wait  = 只等换场再断言:载荷由外部在**同一次 poll** 里注入(见 royale_bound_probe 的 --payload 模式)。
var mode := "drive"
var lobby: Node = null     # 真 mp_lobby.tscn 实例(本进程里被驱动的那份)

var _t := 0.0
var _stage := 0
var _stage_t := 0.0
var _match_start_frame := -1
var _game_added_frame := -1      # royale_game 节点加入场景树(=_ready 运行)的帧号
var _arrival_t := -1.0           # match_sync 应答落地的探针时刻(见 SETTLE_AFTER_PAYLOAD)
var _arrivals: Dictionary = {}   # 信号名 -> 到达帧号(证据:三条是否与 match_start 同一次 poll)


func _ready() -> void:
	if mode == "wait":
		_stage = 1   # 载荷由外部注入,无需驱动大厅
	_log("观察者就绪(mode=%s role=%s);真大厅实例=%s" % [mode, who, str(lobby != null)])
	# 只登记帧号,不消费(PvpSession 的交接仍由大厅/新场景自己走)
	NetBus.local_match_start.connect(func(_role: int, _spawn: Vector2i, _map: String) -> void:
		_match_start_frame = Engine.get_process_frames())
	# 诊断:_on_match_sync 的应答是**进场拉取**那条路的关键证据(旧的三条推送信号在拉模型下
	# 不再触发,故 `_arrivals` 里看不到它们 —— 这里把真正承载载荷的那条记下来)。
	NetBus.local_match_sync.connect(func(p: Dictionary) -> void:
		_arrivals["match_sync"] = Engine.get_process_frames()
		_log("match_sync 应答: names=%s hues=%s options=%s" % [str(p.get("names", {})),
				str(p.get("hues", {})), str(p.get("options", {}))]))


# 子进程的 stdout 不会被父进程继承(Windows CreateProcess 不继承句柄)→ 落盘一份,
# 父进程在失败/超时时把它打印输出,否则客户端子进程里发生了什么完全看不见。
func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://%s%s.log" % [RESULT_PREFIX, who]
	# READ_WRITE 不会创建文件(文件不存在时 open 直接返回 null)→ 首次落盘用 WRITE 建出来
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, mode)
	if f != null:
		f.seek_end()
		# 墙钟戳(2026-10-03 加):`_t` 是 delta 累加,而 Godot 会把超长帧的 delta 钳掉  -> 
		# 卡顿期它**严重低报**(实测同一事件 `_t`=12.2s 而 `get_ticks_msec()`=22.1s)。
		# 本探针的整个诊断都建立在"晚了多久"上  ->  量延迟必须用墙钟,不能只用 `_t`。
		f.store_line("%5.1fs w=%dms %s" % [_t, Time.get_ticks_msec(), msg])
		f.close()
	NetBus.local_peer_info.connect(func(_names: Dictionary) -> void:
		_arrivals["peer_info"] = Engine.get_process_frames())
	NetBusExt.local_peer_hues.connect(func(_hues: Dictionary) -> void:
		_arrivals["peer_hues"] = Engine.get_process_frames())
	NetBusExt.local_match_options.connect(func(_opts: Dictionary) -> void:
		_arrivals["match_options"] = Engine.get_process_frames())
	# 消费者何时才存在:_ready 紧跟 node_added 同帧跑 → 这帧之前它的订阅还没装上
	get_tree().node_added.connect(func(n: Node) -> void:
		if _is_royale_game(n):
			_game_added_frame = Engine.get_process_frames())


func _process(delta: float) -> void:
	_t += delta
	if _t > DEADLINE:
		_finish(false, "超时(阶段 %d;match_start 帧=%d,到达 %s)" % [_stage, _match_start_frame,
				str(_arrivals)])
		return
	match _stage:
		0:
			_stage_wait_lobby()
		1:
			_stage_wait_game(delta)


# ── 阶段 0:等实际大厅连上大厅服 → c1 建房 / c2 等 GO 文件后加入 ──
func _stage_wait_lobby() -> void:
	if lobby == null or not is_instance_valid(lobby):
		_log_once("等真大厅实例挂上(add_child 被推迟到帧末)")
		return
	if not bool(lobby.get("_connected")):
		_log_once("等大厅连接(_connected=false)")
		return   # 实际大厅面板自己会连(`_ready` 的 `_request_list` 按 `PvpSession.server_address`)
	# 注意： 守卫:连上的必须是**本探针的大厅**,不能是云服(与 royale_c2_watcher / team_match_watcher
	#   相同机制)。生产默认地址是云(`PvpSession.server_address` 初值 120.53.107.140),而本探针是
	#   **实例化真 mp_lobby 让它自己连** —— `royale_bound_probe._run_client` 漏了那句地址预置时,
	#   两个客户端会**静默连云**(还会在云上那台真服务器上真的建房):日志里满是本端自己的
	#   「已连接服务器」,而编排器一条 `玩家连入` 都没有  ->  只剩 75s 超时。当场明确提示,
	#   别让下一个人再从超时逆推(规避历史已知问题)。
	if String(lobby.get("_connected_addr")) != LOBBY_ADDR:
		_finish(false, "本端连的是 %s,不是本探针大厅 %s —— 检查 royale_bound_probe._run_client 的地址预置"
				% [lobby.get("_connected_addr"), LOBBY_ADDR])
		return
	if who == "c1":
		_log("大厅已连,建房")
		# 统一大厅:先设筛选再开弹层(弹层按 `_mode` 选默认模式),最后走真按钮回调建房。
		lobby.call("_set_filter", PvpSession.MODE_ROYALE)
		lobby.call("_open_create_dialog")
		lobby.call("_on_create_pressed")   # 等价于点「创建房间」(公开房,人数上限默认 4)
		_stage = 1
		return
	if not FileAccess.file_exists(GO_FILE):
		return
	var f := FileAccess.open(GO_FILE, FileAccess.READ)
	var code: String = f.get_as_text().strip_edges() if f != null else ""
	if f != null:
		f.close()
	if code.is_empty():
		return
	_log("用房间号 %s 加入" % code)
	lobby.call("_join_code", code, PvpSession.MODE_ROYALE)   # 等价于点房间列表里的房间
	_stage = 1


var _logged_once: Dictionary = {}

func _log_once(msg: String) -> void:
	if _logged_once.has(msg):
		return
	_logged_once[msg] = true
	_log(msg)


# ── 阶段 1:等换场(实际大厅 → 真 royale_game),静置后断言 ──
func _stage_wait_game(delta: float) -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_royale_game(cs):
		# 诊断:换场没发生时,把实际大厅的 `_current_mode` 一起打印输出 —— 空串就是
		# `_enter_match_scene` 那支 push_error(不切场景,刻意加固),那才是"等不到换场"的真因。
		var cm := "(lobby 已 free)"
		if lobby != null and is_instance_valid(lobby):
			cm = str(lobby.get("_current_mode"))
		_log_once("等换场(当前场景=%s, _current_mode=「%s」)" % [
				("(空)" if cs == null else str(cs.name)), cm])
		return
	if _stage_t == 0.0:
		_log("已换场到 royale_game(帧 %d;match_start 帧 %d)" % [Engine.get_process_frames(),
				_match_start_frame])
		if mode == "wait":
			# - 批次 3:本模式由"载荷在切场景的**同一次 poll** 里被推过去"改成"**拉**"。
			#   应答必须由**换场后仍活着**的节点发 —— 探针节点自己是 current scene,换场会 free 它
			#   (实测:那条协程一条应答都没发出去)。本观察者挂在 root 上,正是为此。
			NetBus.local_match_sync.emit({
				"names": {1: "P1", 3: "P3"},
				"hues": HUE_BY_ROLE.duplicate(),
				"options": {"disabled_weapons": [DISABLED_SLOT], "round_full_heal": false},
				"roles": [1, 3],
				"spawns": {1: PvpSession.spawn, 3: PvpSession.spawn},
			})
			_log("已投 match_sync 应答(新场景应按 role 应用到 _names/_hues/disabled_weapons)")
	_stage_t += delta
	# 等载荷(带截止线),不再用固定静置 —— 理由见文件头 `SETTLE_AFTER_PAYLOAD` 上方那段。
	if _arrivals.has("match_sync"):
		if _arrival_t < 0.0:
			_arrival_t = _stage_t
		if _stage_t < _arrival_t + SETTLE_AFTER_PAYLOAD:
			return
	elif _stage_t < PAYLOAD_DEADLINE:
		return
	_assert_on_game(cs)


func _is_royale_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("royale_game.gd")


func _assert_on_game(game: Node) -> void:
	var problems: Array = []
	var role := PvpSession.role
	if role != 1 and role != 3:
		problems.append("角色号异常 %d(房内编号带空洞 {1,3},B1 修复后仍应原样发给客户端)" % role)
	# 1) 昵称表 + 自己的头顶 ID(peer_info)
	var names: Dictionary = _dict_of(game, "_names")
	var labels: Dictionary = _dict_of(game, "_id_labels")
	if names.size() < 2:
		problems.append("昵称表 %s 不足 2 项 → peer_info 没进新场景" % str(names))
	if not labels.has(role):
		problems.append("本地头顶 ID 未建(role %d 不在 %s)→ peer_info 没进新场景" % [role,
				str(labels.keys())])
	# 2) 角色色相(peer_hues):两端各自的 hue 都要对得上,才说明按 role 下发且没串
	var hues: Dictionary = _dict_of(game, "_hues")
	for r in HUE_BY_ROLE:
		var want: float = float(HUE_BY_ROLE[r])
		if not hues.has(r) or not is_equal_approx(float(hues[r]), want):
			problems.append("role %d 色相 %s ≠ %s → peer_hues 没进新场景" % [r, str(hues.get(r)),
					str(want)])
	# 3) 禁武器门控前置校验(match_options):判据是**真玩家的武器槽位**(下面那段 local.weapons.enabled_types)。
	#    2026-09-14:PvpSession.disabled_weapons 已作为"只写不读"删除;原先对它的那条断言是
	#    冗余见证(同一条链路上已经有下面那条权威断言),按仓内惯例改探针认新入口,
	#    不为探针保留死字段。
	var local: Node = game.get("_local")
	if local == null or not is_instance_valid(local):
		problems.append("拿不到本地玩家(场景没建好?)")
	else:
		var weapons: Node = local.get("weapons")
		var slots: Array = weapons.enabled_types if weapons != null else []
		if slots.has(DISABLED_SLOT):
			problems.append("本地玩家武器槽位 %s 没被闸(槽 %d 仍启用)→ 禁武器没生效" % [str(slots),
					DISABLED_SLOT])
	var detail := "role=%d match_start 帧=%d 消费者入树帧=%d 三载荷到达帧=%s" % [role, _match_start_frame,
			_game_added_frame, str(_arrivals)]
	_finish(problems.is_empty(), detail + ("" if problems.is_empty() else " | " + "; ".join(problems)))


func _dict_of(n: Node, prop: String) -> Dictionary:
	var v = n.get(prop)
	return v if typeof(v) == TYPE_DICTIONARY else {}


func _finish(ok: bool, msg: String) -> void:
	if mode == "wait":
		print("PROBE: %s\n  %s" % ["ALL-OK" if ok else "FAIL", msg])
	_log(("OK " if ok else "FAIL ") + msg)
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, who], FileAccess.WRITE)
	if f != null:
		f.store_string(("OK " if ok else "FAIL ") + msg)
		f.close()
	get_tree().quit(0 if ok else 1)
