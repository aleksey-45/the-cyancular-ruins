class_name MatchHost
extends MatchRound

# 对局权威核心:生命周期、输入 FIFO 消费、每物理帧编排、出生点。四个域在 match_snapshot / match_combat /
# match_round / match_state 里;输入队列的入队/丢包/抖动包络/1Hz 诊断在 input_intake.gd。★ C2 四条不变量仍在
# _physics_process 与 _on_input 的编排里,原样未动。

const TIME_SYNC_INTERVAL := 0.1   # Beta:颗粒状态下发节律(10Hz;怀表数字平滑够了)

var _time_sync := 0.0

const RW_SNAP_DT := 1.0 / 20.0     # 自身状态采样间隔(20Hz,与单机 WorldRewind 同款)
var _rw_buf: Dictionary = {}       # role -> Array[帧快照](t 升序;只存**自己**的状态+自己的子弹)
var _rw_cursor: Dictionary = {}    # role -> float(已倒退秒数)
# ★ _rw_on / _rw_trail 声明在根基类 MatchState,本文件不重复声明 —— GDScript 禁止成员遮蔽(子类重复声明基类成员是硬 Parse Error)。
var _rw_snap_t: Dictionary = {}    # role -> float(采样节拍)
var _rw_t0: Dictionary = {}        # role -> float(环缓零点;回放按 t-t0 寻帧)

func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], teams: Dictionary = {}) -> void:
	_options = options
	_team_of = teams.duplicate()
	_round_full_heal = bool(options.get("round_full_heal", false))
	var raw_disabled: Array = options.get("disabled_weapons", [])
	for v in raw_disabled:
		_disabled_weapons.append(int(v))
	_ai_roles = ai_roles
# Beta 时间玩法(B21):房主 options 带 time 规则才建服务器权威颗粒经济。★ 普通局 time_economy 恒 null,一切结算/广播短路,行为零变化。
	var time_dict: Dictionary = options.get("time", {})
	if not time_dict.is_empty():
		time_economy = TimeEconomy.new(TimeRules.from_dict(time_dict))
		for role in role_peers:
			time_economy.add_role(int(role))
		for r in ai_roles:
			time_economy.add_role(int(r))
	MazeGenerator.set_map_file(map_path)

	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	_base_grid = MazeGenerator.copy_grid(grid)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
# cyrm v4(B18):破坏已下沉 16px 子格 —— worker 必须连子格回调(TileDefs.on_sub_destroyed),否则客户端永远收不到拆砖事件(幽灵墙:服务器碰撞已消、客户端还在渲染/预测碰撞)。
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	destructible_sub = WorldBuilder.build_sim(self, grid)
# PvP 权威对局:取消命中无敌帧(每发结算一次);双方玩家(层 2)互相物理碰撞。
	CombatComponent.pvp_arena = true

	peer_by_role = role_peers.duplicate()
	for role in role_peers:
		var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
		var src := PacketInputSource.new()
		p.set_input_source(src)
		add_child(p)
		p.collision_mask |= 2   # 与对方玩家(层2)物理碰撞;自身节点互不作用由 Godot 排除
		players[role] = p
		input_sources[role] = src

		var spawn := _spawn_cell(role)
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
		print("MatchHost: 角色 %d 出生点 %s" % [role, spawn])
# AI 补位(实验性):同一 player.tscn,输入源换 AiInputSource、由 AiNavigator 驱动;入 players 即自动获得快照/裁决/计分/复活覆盖
# (不入 input_sources —— 它不走网络包)。★ 代码就位,但界面未接(客户端按钮已删)。
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

	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
# 禁用武器槽位:玩家 @onready 在 _init 时未就绪(碰不得 weapons),进树后才应用。
	for role in players:
		(players[role] as Node).weapons.set_enabled_types(_disabled_weapons)
# 地面武器:铺 12 把 + 每个玩家随机拿 1 把。★ 必须排在 set_enabled_types 之后 —— 先给再禁的话,手上一旦是禁用武器会被判成空手。
# ★ 这同时是服务器玩家有枪的唯一来源(player.tscn 自身的 _ready 给的是空背包,不发就开不了火,且不会有任何报错)。
	_setup_ground_weapons()

	_wire_hit_feedback()
	_broadcast_round_state()


# 把每个玩家的 combat.took_hit 接到本宿主的 _on_player_hit。★ 接线走裸方法名(Callable(self, "_on_player_hit"))⇒ 虚分派:
# 子类覆写的那份才是被调到的那个。★ 抽成具名函数是为了让「手工摆位」路径(探针)也调生产那一份接线,而不是再抄一遍(第二份真相)。
# ★ 幂等:同一对 (信号, Callable) 重复 connect 会被 Godot 拒绝。
func _wire_hit_feedback() -> void:
	for role in players:
		var combat = (players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))

# ★ 生效选项改由对局场景进场拉取下发(随 NetBus.match_sync 的应答):原先那次「推」与 match_start 落在同一次客户端 poll,而新场景的订阅方还不存在 ⇒ 静默丢失。


# 输入队列(入队 / 有界丢包 / 抖动包络 / 1Hz 诊断)整段已在 server/match/input_intake.gd;本文件只留「谁调、调在流程哪一步」。
# ★ 队列本体 _pending_input 仍住 MatchState(match_snapshot 要按 role 读深度),故每次调用传的是同一个字典引用。
var _intake := InputIntake.new()
# ★ S1:本人包(ack + c2)改到玩家步进之后发。本标志防"同一帧多次 physics 追赶"时重复调度。
var _own_flush_pending := false


func _netstat_tick(delta: float) -> void:
	_intake.tick(_pending_input, delta, _round_state, _client_snap_tick, _client_tick)


# ★ 清队列与复位抖动包络必须一起做:只清队列 ⇒ 旧包络把上限继续顶在高位,新纪元开局就白带一层陈旧延迟。
func reset_input_queue(role: int) -> void:
	_intake.reset(_pending_input, role)


func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in peer_by_role:
		if peer_by_role[role] == caller:
# U1:一包两条 tick 记录(30Hz 包)⇒ 拆成连续两条入队(低 tick seq = 高 tick - 1)。
# ★ st/ct 只落位不消费(增量批才用):它们不是队列的一部分,后到的覆盖先到的 —— 丢记录不影响它们,因为它们本来就只代表"最近一次"。
			_client_snap_tick[int(role)] = int(pkt.get("st", 0))
			_client_tick[int(role)] = int(pkt.get("ct", 0))
			for rec in PacketInputSource.unpack_pair(pkt):
				_intake.intake(_pending_input, int(role), rec)
			return


func _physics_process(delta: float) -> void:
# ★★ 快照广播必须放在「消费本帧输入」之前:Player 是子节点(父先于子),本帧玩家要到本函数返回后才步进 —— 若在消费后广播,
# 状态还是「上一输入模拟完(S_{F-1})」而 ack 已指向刚消费的 C_F ⇒ ack 领先状态一拍,客户端移动中每次快照都误判分歧、画面被拉回
# (server-rendered 插值吸收,故旧路径不暴露;C2 rollback 一比整态就现形)。放消费前则 ack 与状态配对一致。

	_sync_ground_positions()

	_debug_keep_weapon_within_reach()

	_debug_destroy_tile(delta)
	if time_economy != null:
		_tick_beta_rewind(delta)   # Beta 回溯机(环缓/倒放/免伤/轨迹)
# 加速态必须在快照之前定格(快照的 haste 位读的就是这个倍率);★ 裁决在服务器:按住 + 账户可耗才生效,只乘自己。
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
					on = false   # 账户当帧烧空(余额/锁定不足)→ 立即回落,与单机同款
			p.pvp_haste_mult = time_economy.rules.haste_mult if on else 1.0
	# 下行 30Hz:每 SNAPSHOT_STRIDE 个物理 tick 广播一次(整数相位,见 MatchState._snapshot_tick_phase)。
	# ★ U1 后消费节奏与广播相位**解耦**:服务器每物理 tick 消费一条记录(一条 = 1 tick);广播仍 30Hz。
	# ★ S1(2026-10-24):本 tick 只广播**世界包**;本人包(ack+c2)在玩家步进之后帧末发(见下方 _flush_own_snapshots)。
	_snapshot_tick_phase += 1
	var snapshot_tick := false
	if _snapshot_tick_phase >= SNAPSHOT_STRIDE:
		_snapshot_tick_phase = 0
		snapshot_tick = true
		_broadcast_snapshot()

	if time_economy != null:
		time_economy.tick(delta)
		_time_sync -= delta
		if _time_sync <= 0.0:
			_time_sync = TIME_SYNC_INTERVAL
			_rpc_all_ext("time_state", [time_economy.state_payload()])
# 应用输入(父先于子 ⇒ 玩家 _physics_process 读到的已是最新注入)。★ U1:每物理 tick 消费一条 FIFO 记录(一条 = 1 tick),
# 队列空 = 缺包(沿用 held/轴)。★ ack = 刚消费记录的 seq(本帧末随本人包回带,rollback 锚点;见 _flush_own_snapshots)。
	for role in input_sources:
		var src: PacketInputSource = input_sources[role]
		src.clear_edges()
		if _pending_input.has(role):
			var q: Array = _pending_input[role]
# COUNTDOWN(开局/换局 3 秒):双方禁止移动/开火 —— 只清空缓冲不喂输入,玩家站在出生点不动。
			if _round_state == RoundState.COUNTDOWN:
				q.clear()
				src.reset_state()   # 连 held/axis 一起清,防上一包方向让服务器玩家在冻结期漂移(C2 分歧源)
				continue
			if not q.is_empty():
				var pkt: Dictionary = q.pop_front()
				src.apply_packet(pkt)
				_ack_seq[role] = int(pkt.get("seq", _ack_seq.get(role, 0)))
# 地面武器拾取/丢弃的边沿:★ 必须紧跟 apply_packet —— 本轮开头已 clear_edges(),边沿就是这一包刚写进去的,晚一拍就被下一轮清掉。
				_handle_ground_actions(role, src)

	# ★ S1:本人包推迟到本帧末(玩家子节点步进完之后)再发 —— 那时 c2 才是"本 tick 输入已生效"的权威态,
	#   ack 也是本 tick 刚消费的 seq;比"等下一次 30Hz 广播"少一拍(均值 ~16.7ms)。
	#   ★ 依赖 Godot 的 call_deferred 在帧末(所有 _physics_process 之后)执行。
	if snapshot_tick:
		_own_flush_pending = true
		call_deferred("_flush_own_snapshots")

	_adjudicate_bullets()

	_broadcast_pending_beams()

	_match_round_tick(delta)

	_netstat_tick(delta)
# 分帧重建可破坏碰撞块(爆炸拆墙):每帧最多 2 块,剩下的留到下一帧。
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


# ★ S1:本人包发送点。由 `_physics_process` 在消费完本 tick 输入后 call_deferred 进来 ——
#   此刻所有 Player 子节点已经步进完,c2/ack 是同一 tick 的权威态(详见 match_snapshot.send_own_snapshots 的头注)。
# ★ 别改成在 `_physics_process` 里直接发:那时子节点还没步进,c2 会退回落后一拍。
func _flush_own_snapshots() -> void:
	if not _own_flush_pending:
		return
	_own_flush_pending = false
	if not is_inside_tree():
		return
	send_own_snapshots()


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

		if Engine.get_physics_frames() % 3 == 0:
			var trail: Array = _rw_trail.get(r, [])
			trail.append([p.global_position.x, p.global_position.y])
			if trail.size() > 10:
				trail.pop_front()
			_rw_trail[r] = trail


# 退出回溯(两条退出路径共用:主动松开 / 颗粒耗尽)。★★ 录像带模型:把「被复写的未来」从环缓上裁掉 —— 只做 frozen=false /
# 摘 meta / 清 trail 而不碰 _rw_buf 的话,那些帧还留在环缓里,而寻帧是从当前末尾往回数(target = buf.back().t - cursor),
# 于是下一次回溯会先把那段被抹掉的未来倒放一遍(玩家看到「回溯过的时间又出现了」)。★ 保留语义与单机一致:裁完若一帧不剩至少留 1 帧。
func _finish_rw(r: int, p: Node2D, src: PacketInputSource) -> void:
	src.frozen = false
	p.remove_meta("time_rewinding")
	_rw_on[r] = false
	_rw_trail[r] = []
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
	var depth: float = time_economy.rules.rewind_buffer_seconds()
	while buf.size() > 2 and float(buf[0]["t"]) < float(buf[buf.size() - 1]["t"]) - depth:
		buf.pop_front()



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
# ★ 战斗段同样改成句柄点访问:原三处 combat.get/set/call 反射里最阴的是 call("emit_signal", …) —— 名字对不上时 call 当场
# 报错并中止整段(连后面的武器段一起跳过)。hp_changed 是 CombatComponent 自己声明的信号,直接 emit 是同一件事的类型化写法。
	var combat := p.get("combat") as CombatComponent
	if combat != null:
		var hp1 := clampi(int(f["hp"]), 0, combat.max_hp)
		if hp1 != combat.hp:
			combat.hp = hp1
			combat.hp_changed.emit(hp1, combat.max_hp)
	p.set("facing_direction", int(f["facing"]))
	var wc := p.get("weapons") as WeaponComponent
	if wc != null and f.has("wmags"):
		var inv: WeaponInventory = wc.inventory
# ★★ 与单机 Player.rewind_restore 同一处修法、逐字对齐:① 切枪必须排在「条目写回」之前 —— _equip_index 会把走掉那把的出膛
# 实弹写回条目,排在写回之后就会冲掉刚恢复的快照值;② 手持实弹走 WeaponComponent.apply_mag()(未入树窗口写 pending_mag,由
# WeaponBase._ready 消费)而不是直接写 mag_ammo —— 后者会被 _ready 用条目旧值覆盖;③ wlive < 0 且确实切了枪 ⇒ 取快照条目值。
# ★ 语义口径:wlive 与 wmags 各自照抄快照,不许「以条目为准」把 wlive 丢掉。⚠ 行为侧零守卫(写法/语句序有探针 S9,已删 2026-10-09)。
		var want_idx := int(f.get("widx", -1))
		var switched := want_idx >= 0 and want_idx != wc._current_index
		if switched:
			wc.equip_index(want_idx)
		if inv != null:
			var held: Array = inv.held
			var mags: Array = f["wmags"]
			for i in mini(held.size(), mags.size()):
				held[i]["mag"] = int(mags[i])
		var live: WeaponBase = wc.current_weapon()
		if live != null and is_instance_valid(live):
			var want := int(f.get("wlive", -1))
			if want < 0 and switched and inv != null and wc._current_index >= 0 \
					and wc._current_index < inv.held.size():
				want = int(inv.held[wc._current_index]["mag"])
# ★ wlive 的 -1 是哨兵(没记),条目的 MAG_FULL(-1) 是满弹 —— 两个 -1 语义不同,不折算会让新枪停在 _equip_index 从恢复前条目取的有限旧值。
				if want == WeaponInventory.MAG_FULL:
					want = live.mag_size
			if want >= 0:
				WeaponComponent.apply_mag(live, want)

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
