extends Node

# 1v1 真实客户端 Bot 观察者:挂 get_tree().root(跨换场存活)。

const BotHandle := preload("res://tests/harness/bot/bot_input.gd")
const Obs := preload("res://tests/harness/bot/bot_observation.gd")
const Brain := preload("res://tests/harness/bot/bot_brain.gd")

const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 90.0
const ROUND_STATE_TIMEOUT := 30.0
const RUN_SECONDS := 40.0
const HARD_LIMIT := 150.0
const LOG_INTERVAL := 0.5
const FIRE_RANGE := 620.0
const PREFERRED_RANGE := 300.0
const BACKOFF_RANGE := 140.0
const MEMORY_TTL := 3.0
const MOVED_PX := 64.0
const PULSE := 0.55
const PULSE_ON := 0.30

var who := "c1"
var idx := 1
var lobby_port := 29400

var lobby: Node = null
var _lobby_attached := false
var _created := false
var _joined := false
var _started := false
var _refresh_t := 1.2

var _game: Node = null
var _local: Node2D = null
var _bot = null
var _entered := false
var _role := 0
var _t := 0.0
var _enter_t := 0.0
var _round_state := -1
var _round_t := -1.0
var _play_t := 0.0
var _snap_world: Dictionary = {}
var _got_snap := false
var _spawn_pos := Vector2.ZERO
var _moved := false
var _fired := 0
var _fire_t := 0.0
var _prev_fire := false
var _prev_attack := false
var _mem: Dictionary = {}
var _state: Dictionary = {}
var _log_t := 0.0
var _view_n := 0
var _radar_n := 0
var _mem_n := 0
var _min_dist := INF
var _saw_enemy := false
var _reason := ""
var _lines: Array[String] = []
var _fails: Array[String] = []
var _done := false


func _ready() -> void:
	NetBus.local_snapshot_world.connect(_on_snap_world)
	NetBus.local_round_state.connect(_on_round_state)
	multiplayer.connected_to_server.connect(_on_lobby_connected)
	multiplayer.connection_failed.connect(_on_lobby_failed)
	var e := NetBus.start_client(LOBBY_ADDR, lobby_port)
	if e != OK:
		_fail("start_client(大厅 %s:%d)失败 err=%d" % [LOBBY_ADDR, lobby_port, e])
		_finish("大厅连接失败")
		return
	_log("观察者就绪,连大厅 %s:%d" % [LOBBY_ADDR, lobby_port])


func _on_lobby_failed() -> void:
	_fail("连大厅失败")
	_finish("大厅连接失败")


func _on_lobby_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", "BOT%d" % idx)
	_attach_lobby.call_deferred()


# 页挂在探针场景下(换场即随场景 free),与生产形状一致。
func _attach_lobby() -> void:
	if _lobby_attached:
		return
	var cs := get_tree().current_scene
	if cs == null:
		return
	lobby = load("res://scenes/mp_lobby.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	lobby.set("_connected", true)
	lobby.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(lobby)
	lobby.call("_set_filter", PvpSession.MODE_PVP)
	_lobby_attached = true
	_log("真大厅页已挂载")


func _physics_process(delta: float) -> void:
	if _done:
		return
	_t += delta
	if _t > HARD_LIMIT:
		_finish("硬上限 %.0fs" % HARD_LIMIT)
		return
	if not _entered:
		if _t > ENTER_TIMEOUT:
			_fail("进局超时")
			_finish("进局超时")
			return
		_tick_lobby()
		_tick_start()
		_try_enter_game()
		return
	_enter_t += delta
	if _round_state != 1:
		if _round_t >= 0.0 and _enter_t - _round_t > ROUND_STATE_TIMEOUT:
			_fail("进局后 %.0fs 没等到 round_state=PLAYING" % ROUND_STATE_TIMEOUT)
			_finish("开局广播没来")
		return
	_play_t += delta
	_tick_bot(delta)
	if _play_t >= RUN_SECONDS:
		_finish("观察 %.0fs" % RUN_SECONDS)


func _tick_lobby() -> void:
	if not _lobby_attached:
		return
	if lobby == null or not is_instance_valid(lobby):
		return
	if idx == 1:
		if not _created and _t > 0.8:
			_created = true
			lobby.call("_open_create_dialog")
			lobby.call("_on_create_pressed")
			_log("建房(真按钮回调)")
	else:
		_tick_join()


func _tick_join() -> void:
	if _joined or lobby == null or not is_instance_valid(lobby):
		return
	_refresh_t -= 1.0 / 60.0
	if _refresh_t <= 0.0 and _t > 1.0:
		_refresh_t = 1.5
		lobby.call("_on_refresh_pressed")
		return
	var grid = lobby.get("_grid")
	if grid == null:
		return
	for c in grid.get_children():
		if c is Button and str(c.get_meta("code", "")) != "" and not (c as Button).disabled:
			_joined = true
			(c as Button).pressed.emit()
			_log("点房卡 %s" % str(c.get_meta("code", "")))
			return


# 1v1:房主在等待室「开始游戏」可见(2/2 就绪)时点它。
func _tick_start() -> void:
	if idx != 1 or _started or not _lobby_attached:
		return
	if lobby == null or not is_instance_valid(lobby):
		return
	var b = lobby.get("_wait_start")
	if b == null or not (b as Button).is_visible_in_tree():
		return
	_started = true
	(b as Button).pressed.emit()
	_log("点「开始游戏」")


func _try_enter_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		return
	var local = cs.get("_local")
	if local == null:
		return
	_game = cs
	_local = local
	_spawn_pos = _local.global_position
	_role = PvpSession.role
	if cs.get_index() < get_index():
		_fail("观察者树序在游戏场景之后,输入边沿会丢")
		_finish("树序错误")
		return
	_bot = BotHandle.new()
	_local.set_input_source(_bot)
	_entered = true
	_enter_t = 0.0
	_log("已进入 pvp_game role=%d spawn=%s" % [_role, str(PvpSession.spawn)])


func _is_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("pvp_game.gd")


func _on_snap_world(world: Dictionary) -> void:
	_snap_world = world
	_got_snap = true


func _on_round_state(data: Dictionary) -> void:
	_round_state = int(data.get("state", -1))
	_round_t = _enter_t


func _tick_bot(delta: float) -> void:
	var my_pos := _local.global_position
	if not _moved and my_pos.distance_to(_spawn_pos) > MOVED_PX:
		_moved = true
	var cands := _candidates(my_pos)
	var cam := _local.get_viewport().get_camera_2d()
	var cam_center := my_pos
	var view_size := Vector2(2208, 1728)
	if cam != null:
		if cam.has_method("get_base_global_position"):
			cam_center = cam.get_base_global_position()
		else:
			cam_center = cam.global_position
		view_size = Vector2(_local.get_viewport().size) / cam.zoom
	var radar_px := 0.0
	var radar_unc := 0.0
	if Settings.pvp_show_minimap and Settings.pvp_minimap_show_enemy:
		radar_px = Minimap.RANGE_CELLS * float(GameParameters.TILE_SIZE)
		radar_unc = float(GameParameters.TILE_SIZE) / Minimap.PX_PER_CELL
	var map_size := Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var obs: Array = Obs.build(cands, {
		"my_role": _role, "mode": "pvp", "teams": {},
		"self_pos": my_pos, "cam_center": cam_center, "view_size": view_size,
		"map_size": map_size, "radar_radius_px": radar_px,
		"radar_uncertainty_px": radar_unc, "now": _t, "memory_ttl": MEMORY_TTL,
	}, _mem)
	Obs.prune(_mem, _t, MEMORY_TTL)
	_count_sources(obs)
	for o in obs:
		if str(o.get("relation", "")) == Obs.REL_ENEMY:
			_saw_enemy = true
			var d := GridPathfinder.toroidal_delta_px(my_pos, o.get("pos", my_pos),
					map_size.x, map_size.y).length()
			_min_dist = minf(_min_dist, d)
	var can_act := _round_state == 1
	if can_act and _local.has_method("is_downed") and bool(_local.call("is_downed")):
		can_act = false
	var intent: Dictionary = Brain.decide(obs, {
		"can_act": can_act, "self_pos": my_pos,
		"self_vx": (_local as CharacterBody2D).velocity.x,
		"now": _t, "delta": delta, "fire_range_px": FIRE_RANGE,
		"preferred_range_px": PREFERRED_RANGE, "backoff_px": BACKOFF_RANGE,
		"map_size": map_size,
	}, _state)
	_apply_intent(intent, delta, can_act)
	_log_tick(delta)


func _candidates(my_pos: Vector2) -> Array:
	var out: Array = []
	var players: Dictionary = _snap_world.get("players", {})
	var rep = _game.get("_remote_replica")
	for key in players:
		var r := int(key)
		if r == _role:
			continue
		var pos: Vector2 = my_pos
		if rep != null and is_instance_valid(rep):
			pos = (rep as Node2D).global_position
		else:
			pos = (players[key] as Dictionary).get("pos", my_pos)
		out.append({"role": r, "pos": pos})
	return out


func _apply_intent(intent: Dictionary, delta: float, can_act: bool) -> void:
	if _bot == null:
		return
	var fire := can_act and bool(intent.get("fire", false))
	var on := false
	if fire:
		_fire_t += delta
		on = fmod(_fire_t, PULSE) < PULSE_ON
	else:
		_fire_t = 0.0
	_bot.set("axis", float(intent.get("axis", 0.0)))
	_state["_last_axis"] = float(intent.get("axis", 0.0))
	var aim: Vector2 = intent.get("aim", Vector2.RIGHT)
	_bot.set("aim", aim if aim.length_squared() > 0.0001 else Vector2.RIGHT)
	_bot.set("attack", on)
	if bool(intent.get("jump", false)):
		_bot.call("press_jump")
	if on and not _prev_attack:
		_bot.call("press_attack_edge")
		_fired += 1
	elif not on and _prev_attack:
		_bot.call("release_attack_edge")
	_prev_attack = on
	_prev_fire = fire
	_reason = str(intent.get("reason", ""))


func _count_sources(obs: Array) -> void:
	_view_n = 0
	_radar_n = 0
	_mem_n = 0
	for o in obs:
		match str(o.get("source", "")):
			"view": _view_n += 1
			"radar": _radar_n += 1
			"memory": _mem_n += 1


func _log_tick(delta: float) -> void:
	_log_t -= delta
	if _log_t > 0.0:
		return
	_log_t = LOG_INTERVAL
	var p := _local.global_position
	var body := _local as CharacterBody2D
	var downed := _local.has_method("is_downed") and bool(_local.call("is_downed"))
	_log("t=%.1f obs=%d view=%d radar=%d mem=%d reason=%s pos=(%.0f,%.0f) fired=%d ax=%.2f vx=%.0f floor=%d downed=%d"
			% [_t, _view_n + _radar_n + _mem_n, _view_n, _radar_n, _mem_n,
			_reason, p.x, p.y, _fired, float(_state.get("_last_axis", 0.0)),
			body.velocity.x if body != null else 0.0,
			int(body.is_on_floor()) if body != null else -1, int(downed)])


func _finish(reason: String) -> void:
	if _done:
		return
	_done = true
	if _bot != null:
		_bot.set("attack", false)
		_bot.set("axis", 0.0)
	# 接线级判据:真局 + 快照 + 开局 + 移动。交战(看到对手 / 进入射程后开火)只记录不门禁 ——
	# ★ 为什么:没有导航时能否碰面取决于随机出生点,拿它当判据会变成"时红时绿"的假守卫;导航落地后再升级判据。
	var ok := _entered and _got_snap and _moved and _play_t >= 5.0
	_lines.append("BOT_1V1 who=%s role=%d entered=%d moved=%d fired=%d snap=%d play_t=%.1f"
			% [who, _role, int(_entered), int(_moved), _fired, int(_got_snap), _play_t])
	_lines.append("BOT_1V1 CONTACT saw_enemy=%d view=%d radar=%d mem=%d min_dist=%.0f"
			% [int(_saw_enemy), _view_n, _radar_n, _mem_n, _min_dist])
	_lines.append("BOT_1V1 %s reason=%s" % ["OK" if ok else "FAIL", reason])
	_write_result()
	_log("收工 %s" % _lines.back())
	get_tree().quit(0 if ok else 1)


func _write_result() -> void:
	var path := "user://bot_1v1_%s.txt" % who
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	for l in _lines:
		f.store_line(l)
	f.close()


func _log(msg: String) -> void:
	_lines.append(msg)
	print("BOT[%s] %s" % [who, msg])


func _fail(msg: String) -> void:
	_fails.append(msg)
	_lines.append("FAIL: " + msg)
	printerr("BOT[%s] FAIL: %s" % [who, msg])
