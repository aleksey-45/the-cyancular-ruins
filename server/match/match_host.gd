class_name MatchHost
extends MatchRound

# 权威对局核心宿主 MatchHost：
# 负责对局生命周期管理、客户端输入 FIFO 消费、物理帧模拟编排、出生点分配及时间机制控制。
# 继承链分层：MatchState -> MatchGround -> MatchSnapshot -> MatchCombat -> MatchRound -> MatchHost。

const TIME_SYNC_INTERVAL := 0.1   # 时间机制状态同步周期（10Hz）

var _time_sync := 0.0
# ── 时间回溯管理（针对单角色独立生效）──
const RW_SNAP_DT := 1.0 / 20.0     # 状态采样时间间隔（20Hz）
var _rw_buf: Dictionary = {}       # 角色编号 -> 历史帧快照数组（按时间升序）
var _rw_cursor: Dictionary = {}    # 角色编号 -> 当前回溯倒退秒数
var _rw_snap_t: Dictionary = {}    # 角色编号 -> 下次采样时间戳
var _rw_t0: Dictionary = {}        # 角色编号 -> 环形缓冲区基准时间点

func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], teams: Dictionary = {}) -> void:
	_options = options
	_team_of = teams.duplicate()
	_round_full_heal = bool(options.get("round_full_heal", false))
	var raw_disabled: Array = options.get("disabled_weapons", [])
	for v in raw_disabled:
		_disabled_weapons.append(int(v))
	_ai_roles = ai_roles
	# 时间玩法配置：若房主开启时间规则，则实例化权威颗粒经济系统
	var time_dict: Dictionary = options.get("time", {})
	if not time_dict.is_empty():
		time_economy = TimeEconomy.new(TimeRules.from_dict(time_dict))
		for role in role_peers:
			time_economy.add_role(int(role))
		for r in ai_roles:
			time_economy.add_role(int(r))
	MazeGenerator.set_map_file(map_path)
	# 构建权威物理世界：碰撞网格与瓦片属性初始化
	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	_base_grid = MazeGenerator.copy_grid(grid)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	# 注册 16 像素子格破坏回调，确保子格破碎后及时向各客户端同步
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	destructible_sub = WorldBuilder.build_sim(self, grid)
	# 权威对局配置：双方角色开启互相碰撞检测
	CombatComponent.pvp_arena = true
	# 实例化真人玩家节点（使用完整的 player.tscn 物理模拟，注入 PacketInputSource）
	peer_by_role = role_peers.duplicate()
	for role in role_peers:
		var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
		var src := PacketInputSource.new()
		p.set_input_source(src)
		add_child(p)
		p.collision_mask |= 2   # 开启与其他角色的物理碰撞
		players[role] = p
		input_sources[role] = src
		# 首局摆位初始化
		var spawn := _spawn_cell(role)
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
		print("MatchHost: 角色 %d 出生点 %s" % [role, spawn])
	# AI 补位初始化：复用 player.tscn，注入 AiInputSource 并挂载 AiNavigator 驱动
	for ai_role in _ai_roles:
		var role := int(ai_role)
		var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
		var src := AiInputSource.new()
		p.set_input_source(src)
		add_child(p)
		p.collision_mask |= 2
		players[role] = p
		var nav := AiNavigator.new()
		nav.host = self
		nav.role = role
		nav.src = src
		p.add_child(nav)
		var spawn := _spawn_cell(role)
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
		print("MatchHost: AI 角色 %d 出生点 %s" % [role, spawn])


func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)


func _ready() -> void:
	# 初始回合进入开局倒计时阶段
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	# 应用禁用武器配置
	for role in players:
		(players[role] as Node).weapons.set_enabled_types(_disabled_weapons)
	# 生成地面武器并为每位玩家随机分配一把初始武器
	_setup_ground_weapons()
	# 监听玩家受击信号，统一分发受击反馈广播
	_wire_hit_feedback()
	_broadcast_round_state()


# 连接玩家受击事件至本宿主的 _on_player_hit 回调方法
func _wire_hit_feedback() -> void:
	for role in players:
		var combat = (players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))


# ── 网络性能诊断统计（通过命令行参数 --netstat 开启，默认关闭）──
# 统计各角色待消费输入队列长度。
# 用于区分客户端测量的未确认输入滞后来源于网络传输延迟还是服务端处理积压。
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_trace := false     # 逐帧输入队列追踪（--netstat-trace，记录前 600 tick）
var _netstat_trace_f := 0


func _netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		var ua := OS.get_cmdline_user_args()
		_netstat = ua.has("--netstat")
		# 逐物理帧记录队列深度，用于定位网络突发投递或初始积压的发生时刻
		_netstat_trace = ua.has("--netstat-trace")
	if not _netstat and not _netstat_trace:
		return
	if _netstat_trace:
		_netstat_trace_f += 1
		if _netstat_trace_f <= 600:
			var tparts: Array[String] = []
			for role in _pending_input:
				tparts.append("%d=%d" % [role, (_pending_input[role] as Array).size()])
			print("[trc] f=%d state=%d q={%s}" % [_netstat_trace_f, _round_state, ", ".join(tparts)])
		if not _netstat:
			return
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var parts: Array[String] = []
	for role in _pending_input:
		parts.append("%d=%d" % [role, (_pending_input[role] as Array).size()])
	print("[netstat-srv] 待消费队列(包) %s" % ", ".join(parts))


func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in peer_by_role:
		if peer_by_role[role] == caller:
			# 缓冲接收到的输入包，按序列号进入先进先出队列，服务端每个物理帧消费并推进模拟
			if not _pending_input.has(role):
				_pending_input[role] = []
			(_pending_input[role] as Array).append(pkt)
			return


func _physics_process(delta: float) -> void:
	# 快照广播必须在消费本帧输入之前执行：
	# 保证广播的权威状态与 ACK 序列号严格匹配，避免客户端误判预测分歧导致不必要的视觉拉回。
	# 同步地面武器物理位置
	_sync_ground_positions()
	_debug_keep_weapon_within_reach()
	_debug_destroy_tile(delta)
	if time_economy != null:
		_tick_beta_rewind(delta)   # 处理各角色的时间回溯逻辑
	# 处理时间加速状态
	if time_economy != null:
		for role in input_sources:
			var acc := time_economy.accounts.get(int(role)) as GrainAccount
			var p := players.get(int(role)) as Node2D
			if acc == null or p == null:
				continue
			var src: PacketInputSource = input_sources[role]
			var on: bool = src.haste_held() and acc.can_spend()
			if on:
				var burn: float = time_economy.rules.haste_burn * delta
				if acc.spend(delta, time_economy.rules.haste_burn) < burn * 0.999:
					on = false   # 颗粒耗尽时自动退出加速状态
			p.pvp_haste_mult = time_economy.rules.haste_mult if on else 1.0
	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_broadcast_snapshot()
	# 时间玩法：颗粒账户自然回复与定频状态同步
	if time_economy != null:
		time_economy.tick(delta)
		_time_sync -= delta
		if _time_sync <= 0.0:
			_time_sync = TIME_SYNC_INTERVAL
			_rpc_all_ext("time_state", [time_economy.state_payload()])
	# 消费各角色的输入包：每物理帧从 FIFO 队列消费一个输入包推进模拟
	for role in input_sources:
		var src: PacketInputSource = input_sources[role]
		src.clear_edges()
		if _pending_input.has(role):
			var q: Array = _pending_input[role]
			# 倒计时阶段（开局或回合切换）：禁止移动与开火，清空输入缓冲并重置输入源状态
			if _round_state == RoundState.COUNTDOWN:
				q.clear()
				src.reset_state()
				continue
			if not q.is_empty():
				var pkt: Dictionary = q.pop_front()
				src.apply_packet(pkt)
				_ack_seq[role] = int(pkt.get("seq", _ack_seq.get(role, 0)))
				# 地面武器交互：紧随 apply_packet 处理拾取与丢弃边沿触发
				_handle_ground_actions(role, src)
	# 子弹命中判定与新子弹广播
	_adjudicate_bullets()
	# 激光等即时光束武器开火同步广播
	_broadcast_pending_beams()
	# 回合状态机推进：倒计时、击杀判定、回合结算与胜负统计
	_match_round_tick(delta)
	_netstat_tick(delta)
	# 瓦片被破坏后分帧重建碰撞体
	if not _dirty_chunks.is_empty():
		var processed := 0
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			if processed >= 2:
				_dirty_chunks[ch] = true
				continue
			CollisionBuilder.rebuild_chunk(destructible_sub, ch, self)
			processed += 1

# 仅用于自动化测试：开局指定延迟后触发瓦片破坏，用于验证断线重连场景下的状态补齐同步
func _debug_destroy_tile(delta: float) -> void:
	if MatchState.test_destroy_cell.x < 0:
		return
	MatchState.test_destroy_after -= delta
	if MatchState.test_destroy_after > 0.0:
		return
	var cell := MatchState.test_destroy_cell
	MatchState.test_destroy_cell = Vector2i(-1, -1)
	print("worker: [test] 拆格 %s" % str(cell))
	TileDefs.damage_tile(cell, 999999, "explosion")

# ── 时间回溯系统：各角色独立记录与回溯 ──
func _tick_beta_rewind(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in players:
		var r := int(role)
		var p := players[role] as Node2D
		var src: PacketInputSource = input_sources.get(role)
		var acc := time_economy.accounts.get(r) as GrainAccount
		if p == null or src == null or acc == null:
			continue
		var want: bool = src.rewind_held() and acc.can_spend() and not p.is_downed()
		var on := bool(_rw_on.get(r, false))
		if want and not on:
			src.frozen = true
			p.set_meta("time_rewinding", true)
			_rw_on[r] = true
			_rw_cursor[r] = 0.0
			_rw_trail[r] = []
			if not _rw_buf.has(r) or (_rw_buf[r] as Array).is_empty():
				_rw_t0[r] = now
			on = true
		elif not want and on:
			_finish_rw(r, p, src)
			continue
		if not on:
			_record_rw_frame(r, p, now)
			continue
		# 回溯进行中：持续消耗颗粒并按加速曲线递增游标倒退模拟
		acc.spend(delta, time_economy.rules.rewind_burn)
		if acc.balance <= 0.0:
			_finish_rw(r, p, src)
			continue
		var cur := float(_rw_cursor.get(r, 0.0))
		var mult := lerpf(TimeParams.REWIND_START_MULT, 1.0,
				clampf(cur / maxf(TimeParams.REWIND_RAMP_TIME, 0.001), 0.0, 1.0))
		cur += delta * mult
		_rw_cursor[r] = cur
		_apply_rw_frame(r, p, cur)
		# 记录残影轨迹点（每 3 个物理帧记录一个坐标，最多保留 10 个）
		if Engine.get_physics_frames() % 3 == 0:
			var trail: Array = _rw_trail.get(r, [])
			trail.append([p.global_position.x, p.global_position.y])
			if trail.size() > 10:
				trail.pop_front()
			_rw_trail[r] = trail


## 退出回溯状态：恢复输入控制、移除回溯元数据，并裁剪掉已被回溯覆盖的未来历史帧。
func _finish_rw(r: int, p: Node2D, src: PacketInputSource) -> void:
	src.frozen = false
	p.remove_meta("time_rewinding")
	_rw_on[r] = false
	_rw_trail[r] = []
	var buf: Array = _rw_buf.get(r, [])
	if buf.is_empty():
		_rw_cursor[r] = 0.0
		return
	# 裁剪晚于退出时刻的历史帧
	var exit_t := float(buf[buf.size() - 1]["t"]) - float(_rw_cursor.get(r, 0.0))
	var kept := 0
	for i in range(buf.size()):
		if float(buf[i]["t"]) <= exit_t:
			kept = i + 1
	if kept == 0:
		kept = 1
	if kept < buf.size():
		buf.resize(kept)
		_rw_buf[r] = buf
	_rw_cursor[r] = 0.0


# 常规阶段：以 20Hz 频率采样并记录角色自身的位置、速度、生命值、朝向及子弹数据
func _record_rw_frame(r: int, p: Node2D, now: float) -> void:
	if now < float(_rw_snap_t.get(r, 0.0)):
		return
	_rw_snap_t[r] = now + RW_SNAP_DT
	if not _rw_t0.has(r):
		_rw_t0[r] = now
	var d := {
		"t": now - float(_rw_t0[r]),
		"p": p.global_position,
		"v": p.get("velocity"),
		"hp": int(p.get("hp")),
		"facing": int(p.get("facing_direction")),
		"downed": p.is_downed(),
	}
	var wc = p.get("weapons")
	if wc != null:
		d["widx"] = int(wc.get("_current_index"))
		var inv = wc.get("inventory")
		var mags: Array = []
		if inv != null:
			var held = inv.get("held")
			if held != null:
				for slot in held:
					mags.append(int(slot.get("mag", 0)))
		d["wmags"] = mags
		var live = wc.call("current_weapon") if wc.has_method("current_weapon") else null
		if live != null and is_instance_valid(live):
			d["wlive"] = int(live.get("mag_ammo"))
	var bl: Array = []
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b) or not (b is Node2D):
			continue
		if b.get("shooter") != p:
			continue
		bl.append({"p": (b as Node2D).global_position, "v": b.get("velocity_vec"),
				"fs": b.call("rewind_state") if b.has_method("rewind_state") else {}})
	d["bullets"] = bl
	if not _rw_buf.has(r):
		_rw_buf[r] = []
	var buf: Array = _rw_buf[r]
	buf.append(d)
	var depth: float = time_economy.rules.rewind_buffer_seconds()
	while buf.size() > 2 and float(buf[0]["t"]) < float(buf[buf.size() - 1]["t"]) - depth:
		buf.pop_front()


# 回溯阶段：根据游标寻找目标时刻对应的历史快照并写回角色与子弹状态
func _apply_rw_frame(r: int, p: Node2D, cursor: float) -> void:
	var buf: Array = _rw_buf.get(r, [])
	if buf.size() < 2:
		return
	var target := float(buf[buf.size() - 1]["t"]) - cursor
	var f: Dictionary = buf[0]
	for e in buf:
		if float(e["t"]) <= target:
			f = e
		else:
			break
	p.global_position = f["p"]
	p.set("velocity", f["v"])
	var combat = p.get("combat")
	if combat != null:
		var hp1 := clampi(int(f["hp"]), 0, int(combat.get("max_hp")))
		if hp1 != int(combat.get("hp")):
			combat.set("hp", hp1)
			combat.call("emit_signal", "hp_changed", hp1, int(combat.get("max_hp")))
	p.set("facing_direction", int(f["facing"]))
	var wc = p.get("weapons")
	if wc != null and f.has("wmags"):
		var inv = wc.get("inventory")
		if inv != null:
			var held = inv.get("held")
			var mags: Array = f["wmags"]
			for i in mini(held.size(), mags.size()):
				held[i]["mag"] = int(mags[i])
		if int(f.get("widx", -1)) >= 0 and int(f.get("widx", -1)) != int(wc.get("_current_index")):
			wc.call("equip_index", int(f["widx"]))
		var live = wc.call("current_weapon") if wc.has_method("current_weapon") else null
		if live != null and is_instance_valid(live) and int(f.get("wlive", -1)) >= 0:
			live.set("mag_ammo", int(f["wlive"]))
	# 自身发射的子弹写回历史位置与速度
	var hist: Array = f.get("bullets", [])
	if hist.is_empty():
		return
	var live_own: Array = []
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b) and b is Node2D and b.get("shooter") == p:
			live_own.append(b)
	for i in mini(hist.size(), live_own.size()):
		var b: Node2D = live_own[i]
		var h: Dictionary = hist[i]
		b.global_position = h["p"]
		b.set("velocity_vec", h["v"])
		if b.has_method("apply_rewind_state") and not (h["fs"] as Dictionary).is_empty():
			b.call("apply_rewind_state", h["fs"])
