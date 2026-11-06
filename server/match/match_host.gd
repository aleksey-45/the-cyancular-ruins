class_name MatchHost
extends Node


# ── C 方案(S4b):上下文(共享状态)从继承链上摘下来,宿主改为 has-a。────────────────────────
var state: MatchState = null
var grace_snapshot: Dictionary = {}   # 宽限期读数(由 server_main 推入;round_state 广播时并入)


func _ensure_state() -> void:
	if state == null:
		state = MatchState.new()


# 外部 API 门面(server_main / 武器脚本按方法名探测):只转发到 state。
func destroyed_cells() -> Array[Vector2i]:
	return state.destroyed_cells()


func damaged_partial_subs() -> Array[Vector2i]:
	return state.damaged_partial_subs()


func note_disconnect_round(role: int) -> void:
	state.note_disconnect_round(role)


func is_friendly(a: Node, b: Node) -> bool:
	return state.is_friendly(a, b)
# 对局权威核心:生命周期、输入 FIFO 消费、每物理帧编排、出生点。快照在 snapshot_system.gd,裁决在
# combat_system / 回合在 round_system / 共享状态在 match_state;输入队列的入队/丢包/抖动包络/1Hz 诊断在 input_intake.gd。★ C2 四条不变量仍在
# _physics_process 与 _on_input 的编排里,原样未动。

const TIME_SYNC_INTERVAL := 0.1   # Beta:颗粒状态下发节律(10Hz;怀表数字平滑够了)

var _time_sync := 0.0

const RW_SNAP_DT := 1.0 / 20.0     # 自身状态采样间隔(20Hz,与单机 WorldRewind 同款)
var _rw_buf: Dictionary = {}       # role -> Array[帧快照](t 升序;只存**自己**的状态+自己的子弹)
var _rw_cursor: Dictionary = {}    # role -> float(已倒退秒数)
# ★ _rw_on / _rw_trail 声明在根基类 MatchState,本文件不重复声明 —— GDScript 禁止成员遮蔽(子类重复声明基类成员是硬 Parse Error)。
var _rw_snap_t: Dictionary = {}    # role -> float(采样节拍)
var _rw_t0: Dictionary = {}        # role -> float(环缓零点;回放按 t-t0 寻帧)

# C 方案(S0.5):系统 → 宿主/网络 的唯一通道;绑定见 _bind_ports()。
var _ports: MatchPorts = null
# C 方案(S1):快照系统。
var _snapshot: SnapshotSystem = null
# C 方案(S2):裁决系统。
var _combat: CombatSystem = null
# C 方案(S3):地面武器系统。
var _ground: GroundSystem = null
# C 方案(S4):回合系统。
var _round: RoundSystem = null

func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], teams: Dictionary = {}, spawns: Dictionary = {}) -> void:
	_ensure_state()
	state._team_of = teams.duplicate()
# 1v1 出生点:start_on 算好的那一份(与 match_start / match_sync 广播同源)。空 = 手工/测试路径(基类 _spawn_cell 自己随机)。
# ★ 子类(RoyaleHost / TeamHost)覆写了 _spawn_cell 与 role_spawns,本表对它们无效(它们各自持有自己的点表)。
	state._duel_spawns = spawns.duplicate()
	state._round_full_heal = bool(options.get("round_full_heal", false))
	var raw_disabled: Array = options.get("disabled_weapons", [])
	for v in raw_disabled:
		state._disabled_weapons.append(int(v))
	state._ai_roles = ai_roles
# Beta 时间玩法(B21):房主 options 带 time 规则才建服务器权威颗粒经济。★ 普通局 time_economy 恒 null,一切结算/广播短路,行为零变化。
	var time_dict: Dictionary = options.get("time", {})
	if not time_dict.is_empty():
		state.time_economy = TimeEconomy.new(TimeRules.from_dict(time_dict))
		for role in role_peers:
			state.time_economy.add_role(int(role))
		for r in ai_roles:
			state.time_economy.add_role(int(r))
	MazeGenerator.set_map_file(map_path)

	state.grid = WorldBuilder.load_grid()
	if state.grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	state._base_grid = MazeGenerator.copy_grid(state.grid)
	# C 方案:端口 + 系统先建好,再挂 TileDefs 回调(回调会落到 _combat)。
	_bind_ports()
	_snapshot = SnapshotSystem.new()
	_snapshot.bind(state, _ports)
	_combat = CombatSystem.new()
	_combat.bind(state, _ports)
	_ground = GroundSystem.new()
	_ground.bind(state, _ports)
	_round = RoundSystem.new()
	_round.bind(state, _ports, _ground)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
# cyrm v4(B18):破坏已下沉 16px 子格 —— worker 必须连子格回调(TileDefs.on_sub_destroyed),否则客户端永远收不到拆砖事件(幽灵墙:服务器碰撞已消、客户端还在渲染/预测碰撞)。
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(state.grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	state.destructible_sub = WorldBuilder.build_sim(self, state.grid)
# PvP 权威对局:取消命中无敌帧(每发结算一次);双方玩家(层 2)互相物理碰撞。
	CombatComponent.pvp_arena = true

	state.peer_by_role = role_peers.duplicate()
	for role in role_peers:
		_add_player(role, PacketInputSource.new(), null)
# AI 补位(实验性):同一 player.tscn,输入源换 AiInputSource、由 AiNavigator 驱动;入 players 即自动获得快照/裁决/计分/复活覆盖
# (不入 input_sources —— 它不走网络包)。★ 代码就位,但界面未接(客户端按钮已删)。
	for ai_role in state._ai_roles:
		_add_player(int(ai_role), AiInputSource.new(), AiNavigator.new())


# C 方案(S0.5):端口层。所有 Callable 都按**方法名**绑定 ⇒ 虚分派到 TeamHost/RoyaleHost 的覆写照旧生效。
func _bind_ports() -> void:
	_ports = MatchPorts.new()
	_ports.net_rpc_role = Callable(self, "_port_rpc_role")
	_ports.net_rpc_role_all = Callable(self, "_port_rpc_role_all")
	_ports.net_broadcast = Callable(self, "_port_broadcast")
	_ports.net_peers_sendable = Callable(self, "_port_net_peers_sendable")
	_ports.net_peer_count = Callable(self, "_port_net_peer_count")
	_ports.scene_bullets = Callable(self, "_port_scene_bullets")
	_ports.scene_add_child = Callable(self, "_port_scene_add_child")
	_ports.scene_rebuild_chunk = Callable(self, "_port_scene_rebuild_chunk")
	_ports.send_round_state = Callable(self, "_send_round_state")
	_ports.on_bullet_hit = Callable(self, "_on_bullet_hit")
	_ports.broadcast_round_state = Callable(self, "_broadcast_round_state")
	_ports.match_winner = Callable(self, "_match_winner")
	_ports.spawn_cell = Callable(self, "_spawn_cell")
	_ports.respawn_player = Callable(self, "_respawn_player")
	_ports.down_killer_of = Callable(self, "_down_killer_of")
	_ports.award_down = Callable(self, "_award_down")
	_ports.finish_match = Callable(self, "_finish_match")
	_ports.start_next_round = Callable(self, "_start_next_round")
	_ports.reset_time_rewind_state = Callable(self, "reset_time_rewind_state")
	assert(_ports.is_ready(), "MatchPorts 未绑全")


func ports() -> MatchPorts:
	return _ports


# 网络效果落地:系统不直接碰 NetBus/NetBusExt。
func _port_rpc_role(role: int, method: String, args: Array, via_ext: bool = false) -> void:
	var peer: int = int(state.peer_by_role.get(role, -1))
	if peer < 0 or not NetBus.is_peer_live(peer):
		return
	if via_ext:
		NetBusExt.callv("rpc_id", [peer, method] + args)
	else:
		NetBus.callv("rpc_id", [peer, method] + args)


func _port_rpc_role_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true, via_ext: bool = false) -> void:
	if via_ext:
		_rpc_all_ext(method, args, except_role, live_only)
	else:
		_rpc_all(method, args, except_role, live_only)


func _port_broadcast(method: String, args: Array = []) -> void:
	if not NetBus.all_peers_sendable():
		return
	NetBus.callv("rpc", [method] + args)


func _port_net_peers_sendable() -> bool:
	return NetBus.all_peers_sendable()


func _port_net_peer_count() -> int:
	return multiplayer.get_peers().size()


func _port_scene_bullets() -> Array:
	return get_tree().get_nodes_in_group("bullet")


func _port_scene_add_child(node: Node) -> void:
	add_child(node)


func _port_scene_rebuild_chunk(chunk: Vector2i) -> void:
	CollisionBuilder.rebuild_chunk(state.destructible_sub, chunk, self)


# ── 裁决域转发(S2):TileDefs 回调 / 玩家信号 / 外部 API 仍只认宿主,宿主转给 CombatSystem。
func _on_tile_destroyed(cell: Vector2i) -> void:
	_combat.on_tile_destroyed(cell)


func _on_sub_destroyed(sub: Vector2i, pre_hp: int, owner: Node) -> void:
	_combat.on_sub_destroyed(sub, pre_hp, owner)


func _on_player_hit(source_pos: Vector2, damage: int, cause: String, role: int) -> void:
	_combat.on_player_hit(source_pos, damage, cause, role)


func _adjudicate_bullets() -> void:
	_combat.adjudicate()


func _broadcast_pending_beams() -> void:
	_combat.broadcast_pending_beams()


func notify_direct_hit(shooter: Node, victim: Node) -> void:
	_combat.notify_direct_hit(shooter, victim)


# ── 地面武器域转发(S3):调用点仍只认宿主,宿主转给 GroundSystem。
func _sync_ground_positions() -> void:
	_ground.sync_positions()


func _debug_keep_weapon_within_reach() -> void:
	_ground.debug_keep_weapon_within_reach()


func _handle_ground_actions(role: int, src: PacketInputSource) -> void:
	_ground.handle_actions(role, src)


func _setup_ground_weapons() -> void:
	_ground.setup()


func ground_weapons_payload() -> Array:
	return _ground.payload()


# ── 回合域转发(S4):叶子覆写与外部调用仍走宿主,宿主转给 RoundSystem。
func _match_round_tick(delta: float) -> void:
	_round.tick(delta)


func _broadcast_round_state() -> void:
	_round.broadcast_round_state()


func _match_winner() -> int:
	return int(_round.match_winner())


func _down_killer_of(role: int) -> int:
	return int(_round.down_killer_of(role))


func _award_down(victim_role: int, killer_role: int) -> void:
	_round.award_down(victim_role, killer_role)


func _respawn_player(role: int) -> void:
	_round.respawn_player(role)


func _start_next_round() -> void:
	_round.start_next_round()


func _round_over(winner: int) -> void:
	_round.round_over(winner)


func _on_down_edge(role: int) -> void:
	_round.on_down_edge(role)


func _handle_respawns(delta: float) -> void:
	_round.handle_respawns(delta)


func _countdown_can_start(delta: float) -> bool:
	return bool(_round.countdown_can_start(delta))


func _countdown_resync_tick(delta: float) -> void:
	_round.countdown_resync_tick(delta)


func _reset_world_and_clear_dynamics() -> void:
	_round.reset_world_and_clear_dynamics()


func _round_state_base() -> Dictionary:
	return _round.round_state_base()


func _broadcast_kill(killer: int, victim: int) -> void:
	_round.broadcast_kill(killer, victim)


func is_match_over() -> bool:
	return bool(_round.is_match_over())


func mark_client_ready(role: int) -> void:
	_round.mark_client_ready(role)


# 子弹直击的基类实现(叶子覆写 + super;1v1 直接实例化 MatchHost ⇒ 这里是 1v1 的唯一归因写端)。
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	var pl := victim as Player
	if pl != null:
		pl.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	var shooter_role := state._role_of(bullet.shooter)
	_port_rpc_role(shooter_role, "hit_confirm", [shooter_role, _victim_role], true)
	bullet.queue_free()


# 出生:建一个玩家节点并摆到出生点。★ 原先这里是两个逐行同构的循环(网络玩家 / AI 补位),现在只有这一份。
func _add_player(role: int, src: PlayerInput, nav: AiNavigator) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(src)
	add_child(p)
	p.collision_mask |= 2   # 与对方玩家(层2)物理碰撞;自身节点互不作用由 Godot 排除
	state.players[role] = p
	if nav == null:
		state.input_sources[role] = src
	else:
		nav.host = self
		nav.role = role
		nav.src = src
		p.add_child(nav)

	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	var who := "AI " if nav != null else ""   # 日志前缀:拼出来与拆前那两条 print 逐字相同
	print("MatchHost: %s角色 %d 出生点 %s" % [who, role, spawn])
	return p


func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)


func _ready() -> void:

	state._round_state = MatchState.RoundState.COUNTDOWN
	state._round_timer = MatchState.COUNTDOWN_TIME
	# 开局 COUNTDOWN 广播此刻还没有订阅方(客户端在切场景)⇒ 先挂起,等 match_sync 报到后补发(见 RoundSystem 就绪闸)。
	state._countdown_hold = MatchState.COUNTDOWN_HOLD_MAX
	state._countdown_bcast_done = false
	state._countdown_resync = MatchState.COUNTDOWN_RESYNC
# 禁用武器槽位:玩家 @onready 在 _init 时未就绪(碰不得 weapons),进树后才应用。
	for role in state.players:
		(state.players[role] as Node).weapons.set_enabled_types(state._disabled_weapons)
# 地面武器:铺 12 把 + 每个玩家随机拿 1 把。★ 必须排在 set_enabled_types 之后 —— 先给再禁的话,手上一旦是禁用武器会被判成空手。
# ★ 这同时是服务器玩家有枪的唯一来源(player.tscn 自身的 _ready 给的是空背包,不发就开不了火,且不会有任何报错)。
	_setup_ground_weapons()

	_wire_hit_feedback()
	_broadcast_round_state()
	add_to_group("authority_explosion_sink")   # BulletBase._explode 用组回调上报权威爆炸位置(子弹不引 autoload)


# 权威爆炸表现同步:子弹通过组回调找到本节点(不靠 autoload —— `-s` 冒烟会 parse 失败)。
# 服务器在权威位置广播;客户端收掉自己那颗视觉榴弹、改画在权威位置(位置一致、无"双爆")。
func on_authority_explosion(pos: Vector2, shooter: Node, visual: PackedScene) -> void:
	var role := state._role_of(shooter)
	var path := ""
	if visual != null:
		path = visual.resource_path
	var canonical := MazeGenerator.wrap_to_range(pos, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_rpc_all_ext("explosion", [canonical, role, path])


# 把每个玩家的 combat.took_hit 接到本宿主的 _on_player_hit。★ 接线走裸方法名(Callable(self, "_on_player_hit"))⇒ 虚分派:
# 子类覆写的那份才是被调到的那个。★ 抽成具名函数是为了让「手工摆位」路径(探针)也调生产那一份接线,而不是再抄一遍(第二份真相)。
# ★ 幂等:同一对 (信号, Callable) 重复 connect 会被 Godot 拒绝。
func _wire_hit_feedback() -> void:
	for role in state.players:
		var combat = (state.players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))

# ★ 生效选项改由对局场景进场拉取下发(随 NetBus.match_sync 的应答):原先那次「推」与 match_start 落在同一次客户端 poll,而新场景的订阅方还不存在 ⇒ 静默丢失。


# 输入队列(入队 / 有界丢包 / 抖动包络 / 1Hz 诊断)整段已在 server/match/input_intake.gd;本文件只留「谁调、调在流程哪一步」。
# ★ 队列本体 _pending_input 仍住 MatchState(SnapshotSystem 要按 role 读深度),故每次调用传的是同一个字典引用。
var _intake := InputIntake.new()
# ★ S1:本人包(ack + c2)改到玩家步进之后发。本标志防"同一帧多次 physics 追赶"时重复调度。
var _own_flush_pending := false


func _netstat_tick(delta: float) -> void:
	_intake.tick(state._pending_input, delta, state._round_state, state._client_snap_tick, state._client_tick)


# ★ 清队列与复位抖动包络必须一起做:只清队列 ⇒ 旧包络把上限继续顶在高位,新纪元开局就白带一层陈旧延迟。
func reset_input_queue(role: int) -> void:
	_intake.reset(state._pending_input, role)


func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in state.peer_by_role:
		if state.peer_by_role[role] == caller:
			# 60Hz:一包 = 一条 tick 记录(入队即用,不再拆包)。
			# ★ st/ct:不是队列的一部分,后到的覆盖先到的 —— 它们只代表“最近一次”。st 是命中回放时间基准;ct 仍只落位。
			state._client_snap_tick[int(role)] = int(pkt.get("st", 0))
			state._client_tick[int(role)] = int(pkt.get("ct", 0))
			_intake.intake(state._pending_input, int(role), pkt)
			return


# ══ O0(bullet-perf 计划 §O0)· tick 分段计时 —— **只做诊断,默认关** ══
var _tick_timing := preload("res://server/match/tick_timing.gd").new()


func _physics_process(delta: float) -> void:
	var _t_all: int = _tick_timing.begin()   # O0:整 tick 计时起点(关闭 diag 时 = -1)
# ★★ 快照广播必须放在「消费本帧输入」之前:Player 是子节点(父先于子),本帧玩家要到本函数返回后才步进 —— 若在消费后广播,
# 状态还是「上一输入模拟完(S_{F-1})」而 ack 已指向刚消费的 C_F ⇒ ack 领先状态一拍,客户端移动中每次快照都误判分歧、画面被拉回
# (server-rendered 插值吸收,故旧路径不暴露;C2 rollback 一比整态就现形)。放消费前则 ack 与状态配对一致。

	# 服务器物理 tick 计数:与快照 tick、命中回放共用同一 60Hz 时间轴 ⇒ 必须在广播/裁决之前 +1。
	state._srv_tick += 1

	_sync_ground_positions()

	_debug_keep_weapon_within_reach()

	_debug_destroy_tile(delta)
	if state.time_economy != null:
		var _t_rewind: int = _tick_timing.begin()
		_tick_beta_rewind(delta)   # Beta 回溯机(环缓/倒放/免伤/轨迹)
		_tick_timing.end(&"rewind", _t_rewind)
# 加速态必须在快照之前定格(快照的 haste 位读的就是这个倍率);★ 裁决在服务器:按住 + 账户可耗才生效,只乘自己。
	if state.time_economy != null:
		for role in state.input_sources:
			var acc := state.time_economy.accounts.get(int(role)) as GrainAccount
			var p := state.players.get(int(role)) as Node2D
			if acc == null or p == null:
				continue
			var src: PacketInputSource = state.input_sources[role]
			var on: bool = src.haste_held() and acc.can_spend()
			if on:
				var burn: float = state.time_economy.rules.haste_burn * delta
				if acc.spend(delta, state.time_economy.rules.haste_burn) < burn * 0.999:
					on = false   # 账户当帧烧空(余额/锁定不足)→ 立即回落,与单机同款
			p.pvp_haste_mult = state.time_economy.rules.haste_mult if on else 1.0
	# 下行:每 SNAPSHOT_STRIDE 个物理 tick 广播一次世界包;输入消费与广播相位解耦(每 tick 消费一条记录)。
	# 本人包(ack+c2)在玩家步进之后帧末发(见 _flush_own_snapshots)。
	state._snapshot_tick_phase += 1
	var snapshot_tick := false
	if state._snapshot_tick_phase >= MatchState.SNAPSHOT_STRIDE:
		state._snapshot_tick_phase = 0
		snapshot_tick = true
		var _t_world: int = _tick_timing.begin()
		_snapshot.broadcast()
		_tick_timing.end(&"world_snap", _t_world)   # O0:含 encode_world + 单次广播 rpc

	if state.time_economy != null:
		state.time_economy.tick(delta)
		_time_sync -= delta
		if _time_sync <= 0.0:
			_time_sync = TIME_SYNC_INTERVAL
			_rpc_all_ext("time_state", [state.time_economy.state_payload()])
# 应用输入(父先于子 ⇒ 玩家 _physics_process 读到的已是最新注入)。★ U1:每物理 tick 消费一条 FIFO 记录(一条 = 1 tick),
# 队列空 = 缺包(沿用 held/轴)。★ ack = 刚消费记录的 seq(本帧末随本人包回带,rollback 锚点;见 _flush_own_snapshots)。
	for role in state.input_sources:
		var src: PacketInputSource = state.input_sources[role]
		src.clear_edges()
		if state._pending_input.has(role):
			var q: Array = state._pending_input[role]
# COUNTDOWN(开局/换局 3 秒):双方禁止移动/开火 —— 只清空缓冲不喂输入,玩家站在出生点不动。
			if state._round_state == MatchState.RoundState.COUNTDOWN:
				q.clear()
				src.reset_state()   # 连 held/axis 一起清,防上一包方向让服务器玩家在冻结期漂移(C2 分歧源)
				continue
			if not q.is_empty():
				var pkt: Dictionary = q.pop_front()
				src.apply_packet(pkt)
				state._ack_seq[role] = int(pkt.get("seq", state._ack_seq.get(role, 0)))
# 地面武器拾取/丢弃的边沿:★ 必须紧跟 apply_packet —— 本轮开头已 clear_edges(),边沿就是这一包刚写进去的,晚一拍就被下一轮清掉。
				_handle_ground_actions(role, src)

	# 本人包推迟到本帧末(玩家子节点步进完之后):那时 c2 才是"本 tick 输入已生效"的权威态,ack 也是本 tick 刚消费的 seq。
	# 依赖 Godot 的 call_deferred 在帧末(所有 _physics_process 之后)执行。
	# 受击事件锚点:帧末(子节点步进之后)记录"上一次完成步进时的已消费 seq",下一帧裁决用它(见 MatchState._stepped_seq)。
	if not state._stepped_seq_pending:
		state._stepped_seq_pending = true
		_record_stepped_seq.call_deferred()
	if snapshot_tick:
		_own_flush_pending = true
		_flush_own_snapshots.call_deferred()

	var _t_adj: int = _tick_timing.begin()   # O0:这一段含 _push_lag_frame(lag 历史写入)
	_adjudicate_bullets()
	_tick_timing.end(&"adjudicate", _t_adj)

	_broadcast_pending_beams()

	_match_round_tick(delta)

	_netstat_tick(delta)
# 分帧重建可破坏碰撞块(爆炸拆墙):每帧最多 2 块,剩下的留到下一帧。
	if not state._dirty_chunks.is_empty():
		var processed := 0
		var chunks := state._dirty_chunks.keys()
		state._dirty_chunks.clear()
		for ch in chunks:
			if processed >= 2:
				state._dirty_chunks[ch] = true
				continue
			CollisionBuilder.rebuild_chunk(state.destructible_sub, ch, self)
			processed += 1
	_tick_timing.end_tick(_t_all, state.players, self)   # O0:整 tick 收尾 + 子弹数/玩家数(窗口到点才吐一行)


# ★ S1:本人包发送点。由 `_physics_process` 在消费完本 tick 输入后 call_deferred 进来 ——
#   此刻所有 Player 子节点已经步进完,c2/ack 是同一 tick 的权威态(详见 snapshot_system.send_own 的头注)。
# ★ 别改成在 `_physics_process` 里直接发:那时子节点还没步进,c2 会退回落后一拍。
func _flush_own_snapshots() -> void:
	if not _own_flush_pending:
		return
	_own_flush_pending = false
	if not is_inside_tree():
		return
	# O0:本人包段 = capture_state + encode_own + 逐 peer rpc_id。★ 它在帧末 deferred 跑,不在 `_t_all` 的
	# 窗口里 ⇒ 读 `own_snap_*` 时要单独看,别拿它去和 tick_avg_us 相加对账。
	var _t_own: int = _tick_timing.begin()
	_snapshot.send_own()
	_tick_timing.end(&"own_snap", _t_own)


# 帧末记录每个 role "上一次完成步进时的已消费 seq"(受击事件锚点;call_deferred 保证跑在 Player 子节点步进之后)。
func _record_stepped_seq() -> void:
	state._stepped_seq_pending = false
	if not is_inside_tree():
		return
	for role in state.input_sources:
		state._stepped_seq[int(role)] = int(state._ack_seq.get(int(role), 0))


# ★ 仅测试用(--test-destroy-tile):对局开始 delay 秒后拆掉指定格、只拆一次;默认关,生产路径行为逐字一致。
# ★ 必须走 TileDefs.damage_tile 而不是直接改 grid —— 那样才经 on_destroyed → _on_tile_destroyed → 广播,与真爆炸同一条链。
# ★ 那句 print 是探针的「非空转」证据:worker 是独立 OS 进程(探针拿不到 _host),日志是唯一能读到它内部动作的通道。
func _debug_destroy_tile(delta: float) -> void:
	if MatchState.test_destroy_cell.x < 0:
		return
	MatchState.test_destroy_after -= delta
	if MatchState.test_destroy_after > 0.0:
		return
	var cell := MatchState.test_destroy_cell
	MatchState.test_destroy_cell = Vector2i(-1, -1)   # 只拆一次
	print("worker: [test] 拆格 %s(相⑦ 用)" % str(cell))
	TileDefs.damage_tile(cell, 999999, "explosion")

# ══ Beta 回溯机(每 role 自身,他人不受影响)══ 环缓只存该 role 自己的状态(位置/速度/HP/朝向/倒地/弹量)+ 它自己的子弹,
# 不重建已消亡的弹(已爆的榴弹不复活,已知边界)。★ 回溯期间:输入源 frozen、take_hit 免伤,自己的子弹随历史倒放且照常伤害他人(用户裁定)。

func _tick_beta_rewind(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in state.players:
		var r := int(role)
		var p := state.players[role] as Node2D
		var src: PacketInputSource = state.input_sources.get(role)
		var acc := state.time_economy.accounts.get(r) as GrainAccount
		if p == null or src == null or acc == null:
			continue

		var want: bool = src.rewind_held() and acc.can_spend() and not p.is_downed()
		var on := bool(state._rw_on.get(r, false))
		if want and not on:
			src.frozen = true
			p.set_meta("time_rewinding", true)
			state._rw_on[r] = true
			_rw_cursor[r] = 0.0
			state._rw_trail[r] = []
			if not _rw_buf.has(r) or (_rw_buf[r] as Array).is_empty():
				_rw_t0[r] = now
			on = true
		elif not want and on:
			_finish_rw(r, p, src)
			continue
		if not on:
			_record_rw_frame(r, p, now)
			continue

		acc.spend(delta, state.time_economy.rules.rewind_burn)
		if acc.balance <= 0.0:
			_finish_rw(r, p, src)
			continue
		var cur := float(_rw_cursor.get(r, 0.0))
		var mult := lerpf(TimeParams.REWIND_START_MULT, 1.0,
				clampf(cur / maxf(TimeParams.REWIND_RAMP_TIME, 0.001), 0.0, 1.0))
		cur += delta * mult
		_rw_cursor[r] = cur
		_apply_rw_frame(r, p, cur)

		if Engine.get_physics_frames() % 3 == 0:
			var trail: Array = state._rw_trail.get(r, [])
			trail.append([p.global_position.x, p.global_position.y])
			if trail.size() > 10:
				trail.pop_front()
			state._rw_trail[r] = trail


# 退出回溯(两条退出路径共用:主动松开 / 颗粒耗尽)。★★ 录像带模型:把「被复写的未来」从环缓上裁掉 —— 只做 frozen=false /
# 摘 meta / 清 trail 而不碰 _rw_buf 的话,那些帧还留在环缓里,而寻帧是从当前末尾往回数(target = buf.back().t - cursor),
# 于是下一次回溯会先把那段被抹掉的未来倒放一遍(玩家看到「回溯过的时间又出现了」)。★ 保留语义与单机一致:裁完若一帧不剩至少留 1 帧。
func _finish_rw(r: int, p: Node2D, src: PacketInputSource) -> void:
	src.frozen = false
	p.remove_meta("time_rewinding")
	state._rw_on[r] = false
	state._rw_trail[r] = []
	var buf: Array = _rw_buf.get(r, [])
	if buf.is_empty():
		_rw_cursor[r] = 0.0
		return

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
# ★★ 类型化:原来隔着 wc / inv / slot 三个句柄做字符串反射(成员名一改名,get 就静默返回 null ⇒ 快照值静默退化,而没有任何断言会红)。
# ★ 逐字行为差共三处、逐条列全:① slot.get("mag", 0) → slot["mag"](条目缺键不是正常态 ⇒ 无实际行为差);② 去掉恒真的
# if held != null(held 是 Array[Dictionary]);③ 去掉 has_method 探测(wc 已收窄成 WeaponComponent)。⚠ 零守卫:rewind_weapon_probe S9 已删(2026-10-09)。
	var wc := p.get("weapons") as WeaponComponent
	if wc != null:
		d["widx"] = wc._current_index
		var inv: WeaponInventory = wc.inventory
		var mags: Array = []
		if inv != null:
			for slot in inv.held:
				mags.append(int(slot["mag"]))
		d["wmags"] = mags
		var live: WeaponBase = wc.current_weapon()
		if live != null and is_instance_valid(live):
			d["wlive"] = live.mag_ammo
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
	var depth: float = state.time_economy.rules.rewind_buffer_seconds()
	while buf.size() > 2 and float(buf[0]["t"]) < float(buf[buf.size() - 1]["t"]) - depth:
		buf.pop_front()



# 换局复位回溯环(BUG-04,2026-10-30):环深的唯一裁剪是 12s,而换局间隙 = ROUND_OVER 4s + COUNTDOWN 3s = 7s < 12s
func reset_time_rewind_state() -> void:
	for r in state._rw_on.keys():
		var src: PacketInputSource = state.input_sources.get(int(r), null)
		if src != null:
			src.frozen = false
		var p: Node2D = state.players.get(int(r), null)
		if p != null and is_instance_valid(p):
			p.remove_meta("time_rewinding")
	state._rw_on.clear()
	state._rw_trail.clear()
	_rw_buf.clear()
	_rw_cursor.clear()
	_rw_snap_t.clear()
	_rw_t0.clear()


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
	# ★ 2026-11-01(R3):逐字段恢复**只有一份实现** = `Player.rewind_restore`(单机回溯走的是同一个函数)。
	if p.has_method("rewind_restore"):
		p.rewind_restore(f)


# ══ 队制模式(TeamHost / RoyaleHost)共用段 ══ 原先这两个文件里逐字重复的几段收在这里,子类只留「差异覆写」。


# 掉线宽限期到点后把 role 从对局里摘掉(两个子类 mark_disconnected 里逐字相同的 11 行:节点释放 +
func _detach_role(role: int) -> bool:
	role = int(role)
	if state._left.has(role):
		return false
	state._left[role] = true
	state._respawn_pending.erase(role)
	state._down_counted[role] = true
	if state.players.has(role):
		var p: Node = state.players[role]
		if is_instance_valid(p):
			p.queue_free()
		state.players.erase(role)
	if state.input_sources.has(role):
		state.input_sources.erase(role)
	state.peer_by_role.erase(role)
	return true


# 终局收场:置 MATCH_OVER + 广播(两个子类逐字相同的两条)。★ 收场日志是模式差异(队号 / role),留在子类覆写里,
# 且必须排在 super 之后 —— 它读的 _match_winner() 已经先被广播载荷读过一次(顺序与拆前逐字一致)。
func _finish_match() -> void:
	state._round_state = MatchState.RoundState.MATCH_OVER
	_broadcast_round_state()


# 「这次倒地算谁的击杀」的归因读端(3v3 与大乱斗共用):上一个打 victim 的人;归因年龄 > ATTRIB_WINDOW(3s)、
# 无归因、自伤 ⇒ 0。★ 唯一实现是 MatchState._attributed_role_within;大乱斗原先把它那 14 行函数体整段抄了一份。
# ★ 1v1 不用它(RoundSystem.down_killer_of 走 _opponent_of),故上提不改变 1v1 行为。
func _attributed_killer(victim: Node2D) -> int:
	return state._attributed_role_within(victim, MatchState.ATTRIB_WINDOW)


# ── start_on 的地图前奏(两个子类逐字相同)── 换图 → 重算世界尺寸 → 网格未载则载入。
# ★ 顺序不可倒:散点与可抵达判据(SpawnPicker.reachable_spawn_cells)都读 MazeGenerator.current_grid,
#   网格为空时所有 `# respawn` 点都会被判"不可抵达" ⇒ 永远掉进几何回退(与 MatchBootstrap.start_on 同一条理由)。
static func prepare_map(map_path: String) -> void:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()


# 手工 / 测试路径建局前的地图兜底(两个子类 _init 里逐字同款的 3 行):网格已在 MazeGenerator 里就**不再换图** ——
# 散点要读的正是那份网格,而调用方(探针等)可能已经为同一局预载过它。
static func ensure_spawn_grid(map_path: String) -> void:
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()


# ── 从 MatchState 移出的宿主侧实现(S4b):网络效果 / 出生点向量 / round_state 发送 ──
func _rpc_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in state.peer_by_role:
		if role == except_role or not state.players.has(role):
			continue
		var peer: int = state.peer_by_role[role]
# ★ 判活走 NetBus.is_peer_live(读 ENet peer 自己的 state),不是 get_peers():后者晚于真实状态,挡不住「往已拆掉的 peer 发定向包」→ 那句 channel 0 错误。
		if live_only and not NetBus.is_peer_live(peer):
			continue

		NetBus.callv("rpc_id", [peer, method] + args)

# Beta 时间玩法的广播走 NetBusExt(NetBus 纪律:原方法表不动)。


func _rpc_all_ext(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in state.peer_by_role:
		if role == except_role or not state.players.has(role):
			continue
		var peer: int = state.peer_by_role[role]

		if live_only and not NetBus.is_peer_live(peer):
			continue

		NetBusExt.callv("rpc_id", [peer, method] + args)


# round_state 的唯一出口:三个生产者拼完 data 后都必须调它,宽限期读数只在这里并进去一次。


func _send_round_state(data: Dictionary) -> void:
	GraceWindow.merge_into(data, grace_snapshot)
	_rpc_all("round_state", [data])




# 「节点 → role」的**唯一判据**(全仓只此一份;原先 _role_of_node 与两段内联循环另抄了三份,哨兵还不一致)。


func _spawn_cell(role: int) -> Vector2i:
	var r := int(role)
	var points := state.map_respawn_points(state._duel_side(r))
	if points.is_empty():
		state._warn_legacy_spawn()
		return state._legacy_spawn_cell(r)
	if not state._duel_placed.has(r) and state._duel_spawns.has(r):
		state._duel_placed[r] = true
		return state._duel_spawns[r]
	state._duel_placed[r] = true
	var anchors: Array = []
	for other in state._duel_spawns:
		if int(other) != r:
			anchors.append(state._duel_spawns[other])
	var exclude: Array = []
	if state._duel_spawns.has(r):
		exclude.append(state._duel_spawns[r])
	var cell := SpawnChooser.pick(points, exclude, null, SpawnPicker.FAR_CELLS, anchors,
			SpawnPicker.grid_dims())
	if cell.x < 0:
		state._warn_legacy_spawn()
		cell = state._legacy_spawn_cell(r)
	state._duel_spawns[r] = cell
	return cell


# 老地图回退(逐字等同改造前的 _spawn_cell):地图两固定点 + 每局换边。网格/地图没加载时同样回 (-1,-1)。


func role_spawns() -> Dictionary:
	if state.map_respawn_points(1).is_empty() and state.map_respawn_points(2).is_empty():
		var out := {}
		for role in state.players:
			out[int(role)] = state._legacy_spawn_cell(int(role))
		return out
	return state._duel_spawns.duplicate()
