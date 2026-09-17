extends Node

# 局内「捡枪 / 丢枪」探针的**观察者**(客户端子进程用;见 ground_net_probe.gd 文件头)。
# 挂在 `get_tree().root` 上:真 royale_lobby → 真 royale_game 的那次换场不会把它带走 →
# 它能在换场之后直接读**真 royale_game 实例的运行时状态**(地面武器表 / 本地玩家背包)。
#
# 流程(每个客户端都跑;c1 建房、c2 用房间号加入):
#   0   驱动真大厅(建房 / 加入房间),等换场到真 royale_game
#   1   等对局进 PLAYING
#   2   接管本地玩家的输入源为 `ground_bot_input`,开始「丢-捡」循环:
#         · DROP 相:长按 Q(玩家自己的计时满 0.6s → 上行一次丢弃边沿)
#                   → 观察 **weapon_spawned** 事件到达(客户端建出节点)= 丢成功
#         · SEEK 相:朝**刚丢出的那一把**走(丢出时带 400px/s 初速,落点离玩家约 150px,
#                   超出拾取半径 64px,所以必须走过去)→ 进半径后按 F
#                   → 观察 **weapon_removed** 事件到达 = 捡成功 → 轮数 +1
#       每相都有超时;超时就换"全场最近的一把"重试,不让一把够不着的枪卡死整轮。
#   3   跑够 TARGET_CYCLES 轮 → 静置 → _assert()
#
# ★ 这条探针为什么必须存在:服务器权威侧(`MatchGround._try_server_pickup/_try_server_drop`)
#   与客户端侧(`_remove_pickup_node` / 权威背包变化后的 restore)各自的**单元级**探针
#   (tests/ground_action_probe、tests/ground_client_probe)都是绿的,而用户报的崩溃在
#   **真链路**上 —— 只有真大厅 + 真 worker + 真 royale_game 才跑得到
#   「上行边沿 → 服务器裁决 → 事件回传 → 客户端删节点 → 快照 c2 改背包 → reconcile」这一整条。
#
# ★ 断言在"确实踩到了"上,不在"没报错"上:崩溃的表现是**结果文件根本不出现**,
#   所以 `_spawned` / `_removed` / `_cycles` 三条计数必须都到线,否则判 FAIL ——
#   没有它们,"走了 40 秒什么也没发生"会被读成通过。

const BotInput := preload("res://tests/ground_bot_input.gd")

const RESULT_PREFIX := "ground_net_probe_"
const GO_FILE := "user://ground_net_probe_go.txt"
const DEADLINE := 90.0
const TARGET_CYCLES := 4         # 至少跑完几轮「丢→走过去→捡」才算真踩到这条路
const DROP_TIMEOUT := 4.0        # 长按 Q 到 weapon_spawned 到达的上限(0.6s 计时 + 1 RTT)
const STAND_TRY := 2.5           # SEEK 相开头"站着按 F"的窗口(开 --test-ground-teleport 时够用)
const SEEK_TIMEOUT := 10.0       # 走位的上限(超了就**拉黑这一把**换目标,见 _step_seek)
const SETTLE := 1.5
const STUCK_TIME := 0.5          # 卡住多久算卡住(触发跳跃)
const STUCK_EPS := 6.0           # 半秒内水平位移小于它 = 卡住

# ── 两种对局模式的差异(只有 4 处;其余全共用:两个大厅页同 extends LobbyPage,
#    两个对局场景同 extends PvpMatchClient)──
# ★ 这张表是**唯一**的模式差异来源:ground_net_probe 建房时也来这儿取大厅场景路径,
#   别在那边再抄一份。
const MODES := {
	"royale": {
		"lobby_scene": "res://scenes/royale_lobby.tscn",
		"game_script": "royale_game.gd",
		"needs_start": true,       # 房主得自按「开始游戏」
		"has_suicide_key": true,   # K → NetBusExt.suicide_request → RoyaleHost.request_suicide_role
	},
	"duel": {
		"lobby_scene": "res://scenes/matchmaking.tscn",
		"game_script": "pvp_game.gd",
		"needs_start": false,      # 配对即开局(go_match),没有开始按钮
		"has_suicide_key": false,  # ★ pvp_game 连 _unhandled_input 都没有 —— K 在这边**没有接收端**
	},
}

var who := "c1"
var mode := "royale"             # "royale" / "duel"(见 MODES)
var scene := "L1"                # 剧本名(见 tests/ground_scenarios.gd 的分派表)
var lobby: Node = null           # 真大厅场景实例(本进程里被驱动的那份;由 ground_net_probe 建)

var _t := 0.0
var _stage := 0
var _stage_t := 0.0
var _game: Node = null           # 换场后的真 royale_game 实例
var _local: Node2D = null
var _bot = null
var _round_state := -1
var _quitting := false
var _logged_once: Dictionary = {}

# ── 事件计数(判据的地面真值;客户端**只能**从这两条事件知道服务器裁决了什么)──
var _spawned := 0
var _removed := 0
var _my_spawned := 0             # by_role == 我的 role(即"我丢下的"):排除了对手的丢弃
var _my_removed := 0             # by_role == 我的 role(即"我捡走的"):排除了对手的拾取
var _my_inst := 0                # 最近一次"我自己丢下的那把"
var _hb_t := 0.0

# ── 循环状态机 ──
enum { PH_DROP, PH_SEEK }
var _phase: int = PH_DROP
var _cycles := 0
var _phase_t := 0.0
var _pickup_cd := 0.0
var _tail_t := 0.0               # 跑够轮数后的收尾计时(见 _debug_step 的收尾分支)
var _list_refresh_ms := 0        # 上次催大厅刷房间列表的时刻(见 _join_first_public_room)
var _start_ms := 0               # 上次按「开始游戏」的时刻(见 _stage_wait_game;房主自按)
var _last_x := 0.0
var _stuck_t := 0.0
var _target_inst := 0            # 本相当前追的那把(超时后据此拉黑)
var _blocked: Dictionary = {}    # 试过够不着的 inst(再挑目标时跳过,免得每轮都挑中同一把)
var _k_sent := false             # 已按过 K(只按一次,制造一次服务器外部事件)
var _drop_dir := 1               # 最近一次丢出的方向(SEEK 相在"目标几乎正上/正下"时沿它继续走)
var _drop_spawned0 := 0          # 进入 DROP 相时的 _my_spawned 基线
var _seek_removed0 := 0          # 进入 SEEK 相时的 _my_removed 基线


func _ready() -> void:
	_log("观察者就绪(role=%s);真大厅实例=%s" % [who, str(lobby != null)])
	NetBus.local_round_state.connect(func(data: Dictionary) -> void:
		_round_state = int(data.get("state", -1)))
	NetBus.local_weapon_spawned.connect(func(data: Dictionary) -> void:
		_spawned += 1
		if int(data.get("by_role", -1)) == int(PvpSession.role):
			_my_inst = int(data.get("inst", 0))
			_my_spawned += 1)
	NetBus.local_weapon_removed.connect(func(data: Dictionary) -> void:
		_removed += 1
		if int(data.get("by_role", -1)) == int(PvpSession.role):
			_my_removed += 1)


func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://%s%s.log" % [RESULT_PREFIX, who]
	var fmode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, fmode)
	if f != null:
		f.seek_end()
		f.store_line("%5.1fs %s" % [_t, msg])
		f.close()


func _log_once(msg: String) -> void:
	if _logged_once.has(msg):
		return
	_logged_once[msg] = true
	_log(msg)


func _process(delta: float) -> void:
	if _quitting:
		return
	_t += delta
	if _t > DEADLINE:
		var cs := get_tree().current_scene
		_finish(false, "超时(阶段 %d;当前场景=%s;捡 %d 丢 %d 轮 %d)" % [_stage,
				"(空)" if cs == null else str(cs.name), _removed, _spawned, _cycles])
		return
	_stage_t += delta
	match _stage:
		0:
			_stage_lobby()
		1:
			_stage_wait_game()
		2:
			_stage_playing()
		3:
			# ★ 等**收尾**跑完再断言(不是等阶段计时):轮次完成点可能在丢枪相位,
			#   收尾那几秒要用来把枪捡回手上,末态才与轮次无关(见 _debug_step 的收尾分支)。
			if _cycles >= TARGET_CYCLES and _tail_t >= SETTLE:
				_assert()
			elif _cycles >= TARGET_CYCLES:
				_log_once("%d 轮已跑完,收尾中" % TARGET_CYCLES)


# ── 阶段 0:等真大厅连上 → c1 建房 / c2 等 GO 文件后加入 ──
func _stage_lobby() -> void:
	# 大厅是**游戏自己切进来的 current_scene**(见 ground_net_probe._run_client)——
	# 观察者挂在 root 上,所以换场不会把它带走;这里每帧认一次,直到认出来为止。
	if lobby == null or not is_instance_valid(lobby):
		var cs := get_tree().current_scene
		if cs != null and _is_lobby_scene(cs):
			lobby = cs
			_log("认出大厅场景 %s" % str(cs.name))
		else:
			_log_once("等大厅场景切进来(当前=%s)" % ("(空)" if cs == null else str(cs.name)))
			return
	if not bool(lobby.get("_connected")):
		_log_once("等大厅连接(_connected=false)")
		return
	if who == "c1":
		_log("大厅已连,建房")
		lobby.call("_on_create_pressed")
		_stage = 1
		_stage_t = 0.0
		return
	if not FileAccess.file_exists(GO_FILE):
		# ★ 导出 exe 形态下**没有裁判进程**来写这个交接文件(那条路上两个客户端是各自
		#   独立拉起来的,见 ground_net_probe.gd 的 `--test-ground-teleport` 段)。
		#   退化成"从大厅**自己拉到的**房间列表里挑第一个公开房加入" —— 复用 lobby 已有的
		#   那条投递路径,不新增第二条。
		if _join_first_public_room():
			_stage = 1
			_stage_t = 0.0
		return
	var f := FileAccess.open(GO_FILE, FileAccess.READ)
	var code: String = f.get_as_text().strip_edges() if f != null else ""
	if f != null:
		f.close()
	if code.is_empty():
		return
	_log("用房间号 %s 加入" % code)
	_join_room_code(code)
	_stage = 1
	_stage_t = 0.0


# 用房间号加入 —— 两页的入口不同,走各自**游戏自己的**那条路(不直接发 RPC,与"用 K 键验自杀"同款纪律)。
#   大乱斗:royale_lobby._join_room(code, invite)
#   1v1  :matchmaking 的入口是「加入」按钮,读的是 `_code_edit` 里的文本 → 填进去再按
func _join_room_code(code: String) -> void:
	if mode == "duel":
		var edit: LineEdit = lobby.get("_code_edit")
		if edit == null or not is_instance_valid(edit):
			_log("拿不到 matchmaking._code_edit,无法加入")
			return
		edit.text = code
		lobby.call("_on_join_pressed")
		return
	lobby.call("_join_room", code, "")


# 从大厅渲染出来的房间按钮里取第一个房号并加入。
# ★ 读按钮**文本**而不是去 lobby 里翻内部字段:那份房间列表 lobby 只渲染不保存
#   (`_on_royale_rooms` 里没有留存),而按钮文本是它自己的公开产物。
func _join_first_public_room() -> bool:
	# ★ 必须**主动催刷新**:大厅只在 `_ready` 与玩家点刷新时拉列表,而 c1 建房是在那之后
	#   —— 不催的话 c2 守着开局那份空列表等到超时(实测:导出形态下就是这么卡死的)。
	var now := Time.get_ticks_msec()
	if now - _list_refresh_ms >= 1500:
		_list_refresh_ms = now
		lobby.call("_on_refresh_pressed")
	var box: Node = lobby.get("_list_box")
	if box == null or not is_instance_valid(box):
		return false
	for c in box.get_children():
		var t := ""
		if c is Button:
			t = (c as Button).text
		elif c.get("text") != null:
			t = str(c.get("text"))
		for p in t.split(" "):
			var s: String = p.strip_edges()
			if s.length() >= 3 and s.is_valid_int():
				_log("用大厅房间列表加入 %s" % s)
				_join_room_code(s)
				return true
	return false


func _stage_wait_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game_scene(cs):
		# ★ 只有大乱斗需要有人按「开始游戏」(1v1 是配对即开局,没有那个按钮 ——
		#   去 `lobby.get("_start_btn")` 只会拿到 null,按不动)。
		#   导出形态下**没有裁判进程**替我们按 → 房主(c1)自己按,且走游戏自己的路径
		#   (emit 那个按钮的 pressed),不直接发 RPC:与用 K 键验自杀同款纪律。
		if bool(MODES[mode]["needs_start"]) and who == "c1" \
				and lobby != null and is_instance_valid(lobby):
			var btn: Button = lobby.get("_start_btn")
			var now := Time.get_ticks_msec()
			if btn != null and is_instance_valid(btn) and now - _start_ms >= 2000:
				_start_ms = now
				_log("房主按下「开始游戏」")
				btn.pressed.emit()
		_log_once("等换场(当前场景=%s)" % ("(空)" if cs == null else str(cs.name)))
		return
	_game = cs
	_log("已换场到 %s(帧 %d)" % [MODES[mode]["game_script"], Engine.get_process_frames()])
	_stage = 2
	_stage_t = 0.0


func _stage_playing() -> void:
	if _game == null or not is_instance_valid(_game):
		_finish(false, "royale_game 实例失效")
		return
	if _round_state != 1:
		_log_once("等 PLAYING(当前 round_state=%d)" % _round_state)
		return
	_local = _game.get("_local")
	if _local == null or not is_instance_valid(_local):
		_finish(false, "拿不到本地玩家")
		return
	_bot = BotInput.new()
	_local.set_input_source(_bot)
	_last_x = _local.global_position.x
	_log("PLAYING:已接管输入源为脚本手柄,开始「丢-捡」循环(开局持枪 %d 把)" % \
			_local.weapons.inventory.held.size())
	_stage = 3
	_stage_t = 0.0
	_phase = PH_DROP
	_phase_t = 0.0


# ── 阶段 3:循环的**驱动**(每物理帧一次,在 royale_game 自己的 _physics_process 之前)──
# ★ 顺序要紧:观察者挂在 root 上、比当前场景先一步,所以这里写的 axis/aim/边沿,
#   会被本帧 `pvp_match_client._physics_process` 的 `pack_record` 读到并上行。
func _physics_process(delta: float) -> void:
	if _stage != 3 or _game == null or _bot == null or _local == null:
		return
	if not is_instance_valid(_local):
		return
	_debug_step(delta)


func _debug_step(delta: float) -> void:
	_phase_t += delta
	# 心跳(诊断用):把**权威与本地两边的背包**摆在一起看 —— 这轮实测正是靠它发现
	# 客户端那份全程是空的(而服务器发了枪),也就是"捡枪在客户端没生效"那条。
	_hb_t += delta
	if _hb_t >= 5.0:
		_hb_t = 0.0
		var rb = _game.get("_rollback")
		_log("♥ t=%.0f 相=%d 本地背包=%d 槽=%d 我丢=%d 我捡=%d 全场丢=%d 捡=%d 地面=%d rb=%s" % [
				_t, _phase, _local.weapons.inventory.held.size(), _local.weapons.current_slot_int(),
				_my_spawned, _my_removed, _spawned, _removed, _game.ground_weapons.size(),
				"无" if rb == null else "last=%d ack=%d caps=%d seqs=%d pend=%d rollback=%d" % [
						int(rb.last_applied()), int(rb._acked),
						(rb._captures as Dictionary).size(), (rb._seqs as Array).size(),
						(rb._pending as Array).size(), int(rb.rollback_count())]])
	if _cycles >= TARGET_CYCLES:
		_bot.axis = 0.0
		_bot.hold_q = false
		_bot.jump = false
		# ★ 收尾:确保手上**拿着**一把再断言。轮次的完成点落在"刚捡到"那一刻,但驱动器一到
		#   TARGET_CYCLES 就把输入清零 —— 若此刻正停在 DROP 相,手上是空的,而"客户端背包
		#   为空"那条断言会把它读成产品 bug(实测 c2 就是这么红的:丢 8 捡 7,净 -1)。
		#   在这里补一次"站着按 F",末态才与轮次无关。
		_tail_t += delta
		if _tail_t < 4.0 and _local.weapons.inventory.held.is_empty():
			_pickup_cd -= delta
			if _pickup_cd <= 0.0:
				_bot.press_f()
				_pickup_cd = 0.35
		return
	# 每帧清一次一次性标记(它们只该持续一帧)
	_bot.jump = false
	_bot.aim = Vector2.RIGHT
	# ★ 第 2 轮之后按一次 K:制造一次**服务器外部事件**(倒地 → 2s 后复活 + 瞬移回出生点,
	#   复活时 `_drop_all_but_one` 又把背包清成一把)。它有两个作用:
	#   ① 让 C2 真的走一次 `restore_state` —— 本轮实测 `rollback_count()` 全程是 0,
	#      也就是说"预测与权威逐位一致"时客户端**从不**应用权威整态(背包正是靠它同步的);
	#   ② 复活那次"背包从 N 把变 1 把"是**最大幅度的一次背包突变**,是压这条路的靶子。
	if _cycles >= 2 and not _k_sent:
		_k_sent = true
		_suicide()
	match _phase:
		PH_DROP:
			_step_drop(delta)
		PH_SEEK:
			_step_seek(delta)


# 走**游戏自己的** K 键路径(顺带把 `_unhandled_input` 的 K 分支还在也验了)。
# ★ 1v1 **没有这条路**:K 的接收端(`royale_game._unhandled_input` → `NetBusExt.suicide_request`
#   → `RoyaleHost.request_suicide_role`)整条只存在于大乱斗侧,pvp_game 连 `_unhandled_input`
#   都没有。硬 `call` 它只会得到 "Invalid call" 且**静默什么都不做** —— 所以这里显式分流,
#   1v1 靠服务器侧的 `--test-down-role` 制造同一件事(见 server/match_debug.gd)。
func _suicide() -> void:
	if not bool(MODES[mode]["has_suicide_key"]):
		_log("本模式没有 K 自杀键(1v1);改由服务器 --test-down-role 制造倒地")
		return
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_K
	_game.call("_unhandled_input", ev)
	_log("已按 K(自杀脱困)→ 等服务器 2s 复活 + 背包清成随机一把")


# DROP 相:长按 Q。★ **不看客户端自己的背包** —— 客户端那份是快照喂的,可能落后于权威
# (本轮实测:全程 `held` 为 0,而服务器那边早就把枪发下来了)。丢弃该不该成功由**服务器**
# 裁决(`_try_server_drop` 自己有空手早退),这里只管把边沿送上去、等 `weapon_spawned` 回执。
# 按"客户端以为空手"就跳过丢弃,恰好会把要测的那条路整条绕过去。
func _step_drop(_delta: float) -> void:
	# ★ 先朝**选好的方向**走一小段再丢:① 走位会把 `facing_direction` 摆到那一侧
	#   (空手时 `weapon._auto_aim` 不会替我们设朝向);② 丢出去之后人已经在追的路上了。
	_bot.axis = float(_drop_dir)
	_bot.aim = Vector2(float(_drop_dir), 0.0)
	if _phase_t < 0.35:
		return          # 先走起来(定朝向),再长按
	_bot.hold_q = true
	if _my_spawned > _drop_spawned0:
		_bot.hold_q = false
		# 记下它朝哪边飞出去了(SEEK 相在"目标几乎正上/正下"时要沿这个方向继续走)
		_drop_dir = 1 if _local.facing_direction >= 0 else -1
		_log_once("丢弃成功(weapon_spawned 已到,inst=%d,朝 %+d)" % [_my_inst, _drop_dir])
		_restart_phase(PH_SEEK)
	elif _phase_t >= DROP_TIMEOUT:
		_bot.hold_q = false
		_log("丢弃超时(长按 %.1fs 没等到 weapon_spawned;先去捡一把再来)" % _phase_t)
		_restart_phase(PH_SEEK)


# SEEK 相:先站着按 F,再退化成走向目标;捡到就进下一轮。
func _step_seek(_delta: float) -> void:
	# 完成判定放最前:捡到的信号可能在任一步到达,别被下面的分支吃掉。
	# 判据只认 `by_role == 我` 那一份 —— 全场计数会把对手的拾取算进来(两人同跑会假绿)。
	# ★ 基线取**本相开始时**的计数,不是本帧开始时的:事件在 multiplayer.poll() 里到达
	#   (早于 _physics_process),同一帧内读两次不会变 —— 按帧比会永远不成立。
	if _my_removed > _seek_removed0:
		_cycles += 1
		_log("第 %d 轮完成(捡走;地面还有 %d 件;客户端背包 %d 把/槽 %d)" % [
				_cycles, _game.ground_weapons.size(),
				_local.weapons.inventory.held.size(), _local.weapons.current_slot_int()])
		_restart_phase(PH_DROP)
		return
	# ★ 前 STAND_TRY 秒**先站着按 F**:开了 `--test-ground-teleport` 的服务器会把枪喂到脚下
	#   (见 MatchGround.test_ground_teleport),于是这一步必定成功 → 整轮不依赖任何走位。
	#   没开那个开关时只是白按两秒(服务器 `nearest_within` 返回空 → 静默 no-op),不伤。
	if _phase_t < STAND_TRY:
		_bot.axis = 0.0
		_pickup_cd -= _delta
		if _pickup_cd <= 0.0:
			_bot.press_f()
			_pickup_cd = 0.35
		return
	var e := _seek_target()
	if e.is_empty():
		if _phase_t > STAND_TRY + 3.0:
			_log("没有可捡的目标(地面表空?/全被拉黑)")
			_restart_phase(PH_DROP)
		return
	var target: Vector2 = e["pos"]
	_target_inst = int(e["inst"])
	var dp: Vector2 = MazeGenerator.toroidal_delta_px(_local.global_position, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var dist := dp.length()
	if dist <= PlayerParams.weapon_pickup_radius * 0.7:
		_bot.axis = 0.0
		_pickup_cd -= _delta
		if _pickup_cd <= 0.0:
			_bot.press_f()
			_pickup_cd = 0.35
	else:
		# ★ 目标几乎在**正上/正下方**时(|dp.x| 很小)**不能站着不动** —— 那正是
		#   "走到目标超时(44px)"的成因:枪就在脚下那一层、水平只差几十像素,而机器人轴恒 0,
		#   于是它蹲在原地等超时。改成沿**丢出方向**继续走:枪就是朝那边飞出去的,
		#   走同一个方向迟早进半径;真掉到下一层了也一起掉下去,仍在同层找得到。
		var ax := dp.x
		if absf(ax) <= 4.0:
			ax = float(_drop_dir) * 32.0
		_bot.axis = signf(ax)
		_bot.aim = dp.normalized() if absf(dp.x) > 4.0 else Vector2(float(_drop_dir), 0.0)
		# 卡住就跳(台阶/矮墙):半秒内水平位移不足 STUCK_EPS 视为卡住
		if absf(_local.global_position.x - _last_x) < STUCK_EPS:
			_stuck_t += _delta
			if _stuck_t >= STUCK_TIME:
				_bot.jump = true
				_stuck_t = 0.0
		else:
			_stuck_t = 0.0
		_last_x = _local.global_position.x
	if _phase_t > SEEK_TIMEOUT:
		# ★ 把这一把**拉黑**再换目标:只"重试最近的一把"会原地打转 —— 够不着的那把
		#   永远还是最近的,于是每一轮都挑它、每一轮都超时(实测:卡在同一个 1112px
		#   目标上耗掉整局)。拉黑之后扫描会跳过它,去找下一把。
		_log("走到目标超时(%.0fpx;拉黑 inst=%d 换目标)" % [dist, _target_inst])
		_blocked[_target_inst] = true
		_restart_phase(PH_SEEK)


# 本相的目标:同层最近的、且没被拉黑的一把(返回表里的条目;没有则空字典)。
func _seek_target() -> Dictionary:
	var field = _game.ground_weapons
	if field == null:
		return {}
	# ★ 优先挑**同一层**的:跨层的枪多半走不过去(本探针没有导航,只会水平走 + 卡住跳),
	#   挑了也是白等一个 SEEK_TIMEOUT(实测:反复"走到目标超时(385px)"—— 就是别层的枪)。
	# ★ 跳过**已拉黑**的:够不着的那把如果还是最近的,每轮都会重新挑中它、每轮超时。
	var ts := float(GameParameters.TILE_SIZE)
	var my_row := int(floor(_local.global_position.y / ts))
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for want_same_row in [true, false]:
		var best: Dictionary = {}
		var best_d := INF
		for e in field.entries:
			if _blocked.has(int(e["inst"])):
				continue
			var p: Vector2 = e["pos"]
			if (int(floor(p.y / ts)) == my_row) != want_same_row:
				continue
			var d: float = GridPathfinder.toroidal_delta_px(
					p, _local.global_position, w, h).length()
			if d < best_d:
				best_d = d
				best = e
		if not best.is_empty():
			return best
	return {}


func _restart_phase(p: int) -> void:
	_phase = p
	_phase_t = 0.0
	_pickup_cd = 0.0
	_bot.hold_q = false
	_bot.axis = 0.0
	# 每个相的**事件计数基线**(见 _step_seek 里那段"按帧比永远不成立")
	_drop_spawned0 = _my_spawned
	_seek_removed0 = _my_removed
	if p == PH_DROP:
		_drop_dir = _pick_drop_dir()
	# ★ 拉黑表(`_blocked`)**刻意不在这里清**:本局里够不着的那些,下一轮多半还是够不着 ——
	#   清了就等于把"每轮都挑中同一把、每轮超时"重新装回去。


# 选一个"丢出去还捡得回来"的方向。落体在身前约 2~3 格处停下(见 PlayerParams 的
# weapon_drop_offset/speed 与落体摩擦),所以先扫一眼那一带是不是**同层的开阔地面** ——
# 枪要落到够不着的层,整轮就只能等超时(实测:探针最初跑不满轮数就是这么来的:
# 人在一处窄台/悬崖边,枪飞出去掉到下一层,水平差几十像素却再也走不过去)。
func _pick_drop_dir() -> int:
	var grid: Array = MazeGenerator.current_grid
	if grid.is_empty() or _local == null:
		return 1
	var ts := float(GameParameters.TILE_SIZE)
	var pos: Vector2 = _local.global_position
	var row := int(floor(pos.y / ts))
	var col0 := int(floor(pos.x / ts))
	var cols: int = (grid[0] as Array).size()
	for d in [1, -1]:
		var ok := true
		for i in range(1, 5):   # 身前 1~4 格都要是同层开阔地面
			var c := int(posmod(col0 + d * i, cols))
			if not MazeGenerator.is_floor_cell_with_headroom(grid, Vector2i(c, row)):
				ok = false
				break
		if ok:
			return d
	return 1


func _is_game_scene(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with(str(MODES[mode]["game_script"]))


# 本模式的大厅场景是不是这一个?按脚本路径认(两个大厅页都 extends LobbyPage,
# 用脚本名区分 royale_lobby / matchmaking)。
func _is_lobby_scene(n: Node) -> bool:
	var s = n.get_script()
	if s == null:
		return false
	var p := str(s.resource_path)
	return p.ends_with("royale_lobby.gd") or p.ends_with("matchmaking.gd")


# ── 断言:判据一律是"这条路真的被走到了",不是"没报错" ──
func _assert() -> void:
	var problems: Array = []
	if _my_spawned < TARGET_CYCLES:
		problems.append("我丢下的只有 %d 条 weapon_spawned(< %d):丢弃没真的走通" % [_my_spawned, TARGET_CYCLES])
	if _my_removed < TARGET_CYCLES:
		problems.append("我捡走的只有 %d 条 weapon_removed(< %d):拾取没真的走通" % [_my_removed, TARGET_CYCLES])
	if _cycles < TARGET_CYCLES:
		problems.append("只跑完 %d 轮(< %d)" % [_cycles, TARGET_CYCLES])
	if _local == null or not is_instance_valid(_local):
		problems.append("本地玩家在循环中被释放")
	else:
		if _local.is_downed():
			problems.append("循环结束时本地玩家倒地")
		# ★ 这条是**语义**断言,不是冗余:服务器已经把我捡走的那把算进背包了(事件可证),
		#   而客户端这份要是还空着,就说明"拾取"在客户端**从未生效** —— 枪在手却开不了火,
		#   且不报任何错。它与上面几条计数互为反证(计数只证明事件到了)。
		if _local.weapons.inventory.held.is_empty():
			problems.append("客户端背包在整轮循环后仍是空的(权威早已发枪/捡枪 → 快照的 inv 没被应用)")
	var field = _game.get("ground_weapons")
	var nodes = _game.get("_pickup_nodes")
	if field == null or nodes == null:
		problems.append("拿不到客户端地面武器表")
	elif int(field.size()) != int((nodes as Dictionary).size()):
		problems.append("客户端地面表与节点数不一致(%d 条 / %d 个节点)" % [
				int(field.size()), (nodes as Dictionary).size()])
	var detail := "role=%d 丢=%d 捡=%d 轮=%d 地面=%s 背包=%s%s" % [
			PvpSession.role, _spawned, _removed, _cycles,
			str(int(field.size())) if field != null else "?",
			str(_local.weapons.inventory.held.size()) if _local != null else "?",
			"" if problems.is_empty() else " | " + "; ".join(problems)]
	_finish(problems.is_empty(), detail)


func _finish(ok: bool, detail: String) -> void:
	if _quitting:
		return
	_quitting = true
	print("PROBE[%s]: %s" % [who, ("OK " if ok else "FAIL ") + detail])
	_log(("OK " if ok else "FAIL ") + detail)
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, who], FileAccess.WRITE)
	if f != null:
		f.store_string(("OK " if ok else "FAIL ") + detail)
		f.close()
	# 等对端也写完再退(两边是并发子进程,先退的会把另一边带进"剩余 <2 人即终局")
	_wait_peer_then_quit(ok, detail)


func _wait_peer_then_quit(ok: bool, _detail: String) -> void:
	var waited := 0.0
	while waited < 20.0:
		var other := "c2" if who == "c1" else "c1"
		if FileAccess.file_exists("user://%s%s.result" % [RESULT_PREFIX, other]):
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	get_tree().quit(0 if ok else 1)
