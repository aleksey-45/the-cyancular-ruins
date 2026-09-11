extends Node

# 大乱斗 B1/B2 探针的**观察者**(客户端子进程用;见 royale_bound_probe.gd 文件头)。
# 挂在 get_tree().root 上(不是探针场景里):切场景不会把它带走 → 它能跨「真大厅场景 →
# 真 royale_game 场景」那次换场继续待在树里,并在**换场之后**读真 royale_game 实例的状态。
# 这正是 B2 的要害:那三条开局载荷与 match_start 落在同一次 poll,而新场景那时还不存在。
#
# 它只做两件事,都**不消费**载荷(订阅只为记到达帧号当证据):
#   1. 驱动真大厅场景(创建房间 / 加入房间)—— 见 royale_bound_probe.gd 的流程说明;
#   2. 换场后静置一小段,断言真 royale_game 上「昵称表 / 头顶 ID / 角色色相 / 禁武器」
#      四样都到位,然后写结果文件。

const RESULT_PREFIX := "royale_b12_probe_"
const GO_FILE := "user://royale_b12_probe_go.txt"
# 与 royale_bound_probe.gd 的 HUE_C1/HUE_C2、DISABLED_SLOT 保持一致(两个客户端的本端选项)
const HUE_BY_ROLE := {1: 90.0, 3: 180.0}
const DISABLED_SLOT := 3
const SETTLE := 2.0        # 换场后等载荷落地的静置秒数(快照/HUD 都在建,给足余量)
const DEADLINE := 50.0

var who := "c1"
# drive = 驱动真大厅走「建房/加入 → go_match → 转连 → 开局」全流程(自然时序,见 royale_bound_probe);
# wait  = 只等换场再断言:载荷由外部在**同一次 poll** 里注入(见 royale_bound_probe 的 --payload 模式)。
var mode := "drive"
var lobby: Node = null     # 真 royale_lobby.tscn 实例(本进程里被驱动的那份)

var _t := 0.0
var _stage := 0
var _stage_t := 0.0
var _match_start_frame := -1
var _game_added_frame := -1      # royale_game 节点入树(=_ready 运行)的帧号
var _arrivals: Dictionary = {}   # 信号名 -> 到达帧号(证据:三条是否与 match_start 同一次 poll)


func _ready() -> void:
	if mode == "wait":
		_stage = 1   # 载荷由外部注入,无需驱动大厅
	_log("观察者就绪(mode=%s role=%s);真大厅实例=%s" % [mode, who, str(lobby != null)])
	# 只登记帧号,不消费(PvpSession 的交接仍由大厅/新场景自己走)
	NetBus.local_match_start.connect(func(_role: int, _spawn: Vector2i, _map: String) -> void:
		_match_start_frame = Engine.get_process_frames())


# 子进程的 stdout 不会被父进程继承(Windows CreateProcess 不继承句柄)→ 落盘一份,
# 父进程在失败/超时时把它打出来,否则客户端子进程里发生了什么完全看不见。
func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://%s%s.log" % [RESULT_PREFIX, who]
	# READ_WRITE 不会创建文件(文件不存在时 open 直接返回 null)→ 首次落盘用 WRITE 建出来
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, mode)
	if f != null:
		f.seek_end()
		f.store_line("%5.1fs %s" % [_t, msg])
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


# ── 阶段 0:等真大厅连上大厅服 → c1 建房 / c2 等 GO 文件后加入 ──
func _stage_wait_lobby() -> void:
	if lobby == null or not is_instance_valid(lobby):
		_log_once("等真大厅实例挂上(add_child 被推迟到帧末)")
		return
	if not bool(lobby.get("_connected")):
		_log_once("等大厅连接(_connected=false)")
		return   # 真大厅面板自己会连 127.0.0.1(_ready 里的 _request_list)
	if who == "c1":
		_log("大厅已连,建房")
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
	lobby.call("_join_room", code, "")   # 等价于点房间列表里的房间
	_stage = 1


var _logged_once: Dictionary = {}

func _log_once(msg: String) -> void:
	if _logged_once.has(msg):
		return
	_logged_once[msg] = true
	_log(msg)


# ── 阶段 1:等换场(真大厅 → 真 royale_game),静置后断言 ──
func _stage_wait_game(delta: float) -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_royale_game(cs):
		_log_once("等换场(当前场景=%s)" % ("(空)" if cs == null else str(cs.name)))
		return
	if _stage_t == 0.0:
		_log("已换场到 royale_game(帧 %d;match_start 帧 %d)" % [Engine.get_process_frames(),
				_match_start_frame])
	_stage_t += delta
	if _stage_t < SETTLE:
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
	# 3) 禁武器闸门(match_options):PvpSession 与真玩家武器槽位都要被闸住
	if PvpSession.disabled_weapons != [DISABLED_SLOT]:
		problems.append("PvpSession.disabled_weapons=%s ≠ [%d] → match_options 没进新场景" % [
				str(PvpSession.disabled_weapons), DISABLED_SLOT])
	var local: Node = game.get("_local")
	if local == null or not is_instance_valid(local):
		problems.append("拿不到本地玩家(场景没建好?)")
	else:
		var weapons: Node = local.get("weapons")
		var slots: Array = weapons.enabled_slots if weapons != null else []
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
