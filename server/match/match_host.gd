class_name MatchHost
extends MatchRound

# 对局权威(核心):生命周期、输入 FIFO 消费、每物理帧编排、出生点。
#
# ★ 2026-09-15(阶段 5.6)按域拆成一条继承链,本文件只剩**核心**;四个域在
#   match_snapshot / match_combat / match_round / match_state 里,见基类注释。
#   **C2 四条不变量仍在 `_physics_process` 与 `_on_input` 里,原样未动。**

const TIME_SYNC_INTERVAL := 0.1   # Beta:颗粒状态下发节律(10Hz;怀表数字平滑够了)

var _time_sync := 0.0
# ── Beta 回溯(每 role 自身;他人不受影响)──
const RW_SNAP_DT := 1.0 / 20.0     # 自身状态采样间隔(20Hz,与单机 WorldRewind 同款)
var _rw_buf: Dictionary = {}       # role -> Array[帧快照](t 升序;只存**自己**的状态+自己的子弹)
var _rw_cursor: Dictionary = {}    # role -> float(已倒退秒数)
# _rw_on / _rw_trail 声明在根基类 MatchState(本文件不重复声明,GDScript 禁止成员遮蔽)
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
	# Beta 时间玩法(B21):房主 options 带 time 规则(建房页 9 项) ⇒ 建服务器权威颗粒经济。
	# 普通局 options["time"] 为空 → time_economy 恒 null,一切结算/广播短路,行为零变化。
	var time_dict: Dictionary = options.get("time", {})
	if not time_dict.is_empty():
		time_economy = TimeEconomy.new(TimeRules.from_dict(time_dict))
		for role in role_peers:
			time_economy.add_role(int(role))
		for r in ai_roles:
			time_economy.add_role(int(r))
	MazeGenerator.set_map_file(map_path)
	# 建世界:碰撞 + 瓦片属性(不渲染)。服务器进程走场景模式,autoload/静态类已就绪。
	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	_base_grid = MazeGenerator.copy_grid(grid)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	# cyrm v4(B18):破坏已下沉 16px 子格 —— worker 必须连**子格**回调,否则客户端永远收不到
	# 拆砖事件(幽灵墙:服务器碰撞已消、客户端还在渲染/预测碰撞)。格级 on_destroyed 保留,
	# 供 _debug_destroy_tile / 复位那条 damage_tile 老路径。
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	destructible_sub = WorldBuilder.build_sim(self, grid)
	# PvP 权威对局:取消命中无敌帧(每发结算一次);双方玩家(层2)互相物理碰撞
	CombatComponent.pvp_arena = true
	# 生成两个玩家(player.tscn 完整物理模拟,注入 PacketInputSource)
	peer_by_role = role_peers.duplicate()
	for role in role_peers:
		var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
		var src := PacketInputSource.new()
		p.set_input_source(src)
		add_child(p)
		p.collision_mask |= 2   # 与对方玩家(层2)物理碰撞;自身节点互不作用由 Godot 排除
		players[role] = p
		input_sources[role] = src
		# 首局直接摆位(_respawn_player 依赖 combat/weapons,需玩家 _ready 后才能调,放到 _ready/_start_next_round)
		var spawn := _spawn_cell(role)
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
		print("MatchHost: 角色 %d 出生点 %s" % [role, spawn])
	# AI 补位(实验性):同一 player.tscn,输入源换 AiInputSource,由 AiNavigator 驱动;
	# 快照/命中裁决/计分/复活全部按 players 迭代 → 客户端副本零改动。
	# ★ 不入 input_sources(不走网络包);入 players 即自动获得快照/裁决/计分/复活覆盖。
	# D13:代码就位,不接界面(客户端按钮已删)。
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
	# 开局回合:玩家已在 _init 摆位,进 COUNTDOWN
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	# 禁用武器槽位:_init 时玩家 @onready 未就绪(不能碰 weapons),进树后应用
	for role in players:
		(players[role] as Node).weapons.set_enabled_types(_disabled_weapons)
	# 地面武器:铺 12 把 + 每个玩家随机拿 1 把。
	# ★ 必须排在 set_enabled_types **之后** —— 与单机 `_give_starting_weapon` 同款理由:
	#   先给再禁的话,手上一旦是禁用武器会被判成空手。
	# ★ 这同时是**服务器玩家有枪的唯一来源**:player.tscn 自身的 _ready 给的是空背包,
	#   不发的话服务器上的玩家开不了火(PvP 直接哑火,且不会有任何报错)。
	_setup_ground_weapons()
	# 受击反馈:任意来源(子弹/鸟接触/鸟弹/爆炸)实际扣血 → combat.took_hit → 广播 hit_event
	_wire_hit_feedback()
	_broadcast_round_state()


# 把每个玩家的 `combat.took_hit` 接到本宿主的 `_on_player_hit`。
# ★ 接线走**裸方法名**(`Callable(self, "_on_player_hit")`)⇒ **虚分派**:子类覆写的那份才是
#   被调到的那个(逐人伤害累计就挂在这条上 —— 2026-09-25 起它住在 `MatchCombat._on_player_hit`
#   本体,`TeamHost` 那份覆写已随统计面上提一起删除)。
# ★ 为什么抽成具名函数而不是留几行在 `_ready` 里:**手工摆位路径**(探针:role_peers 传空、
#   玩家在 `_ready` 之后才 `_place` 进来)也要调**生产那一份**接线 —— 让探针自己再抄一遍
#   `connect(...)` 的话,验的是抄件:哪天生产的接线断了/换了信号,探针照样绿(本仓明令禁止的
#   "第二份真相";同 `TeamHost._apply_team_layers` 的抽法)。
# ★ 幂等性:同一对 (信号, Callable) 重复 connect 会被 Godot 拒绝(不重复触发)。
#   探针那条路径下 `_ready` 时 `players` 还是空的,故这里**恰好**接一次。
func _wire_hit_feedback() -> void:
	for role in players:
		var combat = (players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))

# (原 `_broadcast_match_options` 已删 —— 生效选项改由对局场景**进场拉取**下发:
#  那次"推"与 match_start 落在同一次客户端 poll,而那一刻新场景的订阅方还不存在 → 静默丢失
#  (自检 B2:禁武器闸门没上)。现在 options 随 `NetBus.match_sync` 的应答一起给。
#  消费者 `tests/probe/royale_probe` 的"未收到 match_options = FAIL"断言不变 —— 它现在验的是拉取路径。)

# ── 网络统计读数(2026-09-22 诊断用,★ 默认关;`-- --netstat`)────────────────
# 每 role 的**待消费输入队列长度**。
# ★ 为什么必须有这一格:客户端侧量到的 `gap`(已发未确认)在两种成因下**读数一样** ——
#   ① 服务端消费不过来,包真堆在 `_pending_input` 里;② 服务端消费得动,但包在路上
#   (ENet 可靠通道在高 RTT 下的节流/窗口)。只有这一格能把它们分开:队列小 ⇒ 是②。
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_trace := false     # 逐帧队列追踪(`--netstat-trace`,前 600 tick)
var _netstat_trace_f := 0


func _netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		var ua := OS.get_cmdline_user_args()
		_netstat = ua.has("--netstat")
		# `--netstat-trace`:逐帧打(只在前 600 tick ≈ 10 秒),用于定位"那个固定偏置是哪一刻
		# 被顶上去的"。★ 每秒一行的采样看不见 0.13 秒的爬升 —— 实测队列在开局 1 秒内从 0
		# 跳到 8 然后就永远停在那儿(ρ=1,没有回复力),那一下只能逐帧看。
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
			# 缓冲本帧到达的包,按 seq 序 FIFO,每物理 tick 消费一个(见 _physics_process):
			# 1 包/ tick → 服务器权威模拟与客户端"重放未确认输入"1:1 同序(C2 rollback 需要,
			# 见 docs/pvp-c2-retrospective.md P1)。held/axis 由被消费的那包决定,边沿不丢。
			if not _pending_input.has(role):
				_pending_input[role] = []
			(_pending_input[role] as Array).append(pkt)
			return


func _physics_process(delta: float) -> void:
	# 快照广播必须放在「消费本帧输入」之前——Player 是子节点,父先于子,本帧玩家要到
	# MatchHost._physics_process 返回后才步进。若在消费后广播,状态还是"上一输入模拟完(S_{F-1})",
	# 却已把 ack 指向刚消费的 C_F → ack 领先状态一拍 → 客户端拿自己的 ring[C_F](=S_C_F)
	# 比 S_{F-1},移动中每次快照都误判分歧、画面被拉回(server-rendered 插值吸收故旧路径不暴露;
	# C2 rollback 一比整态就现形)。放消费前:ack 仍指上 tick 消费的 C_{F-1},状态已是上一步进完的
	# S_{F-1},配对一致(客户端期望 ack=C 配 S_C,见 pvp_reconcile_smoke 的建模)。
	# 地面武器:先把落体的实际位置同步回表,后面的拾取判定(nearest_within)才用得上最新落点
	_sync_ground_positions()
	# 仅测试用(`--test-ground-teleport`,见 MatchGround.test_ground_teleport):默认关。
	_debug_keep_weapon_within_reach()
	# 仅测试用(`--test-destroy-tile`,见 MatchState.test_destroy_cell):默认关。
	_debug_destroy_tile(delta)
	if time_economy != null:
		_tick_beta_rewind(delta)   # Beta 回溯机(环缓/倒放/免伤/轨迹)
	# Beta 时间玩法:加速态(在快照**前**定格 —— 快照的 haste 位读的就是这个倍率)。
	# 裁决在服务器:按住 + 账户可耗才生效;只乘自己(别的角色/子弹/世界一概不动)。
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
	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_broadcast_snapshot()
	# Beta 时间玩法:账户回复 + 10Hz 显示镜像(怀表 HUD)。可靠通道:数值承诺,丢包会自愈。
	if time_economy != null:
		time_economy.tick(delta)
		_time_sync -= delta
		if _time_sync <= 0.0:
			_time_sync = TIME_SYNC_INTERVAL
			_rpc_all_ext("time_state", [time_economy.state_payload()])
	# 应用输入(父先于子 → 玩家 _physics_process 读到的已是最新注入)。
	# 每 tick 每 role 恰好消费一个 FIFO 包(最早的)→ 权威模拟与客户端重放 1:1 同序;
	# 队列空 = 缺包,沿用上一包 held/轴(PacketInputSource.clear_edges 不清 held)。
	# ack = 刚消费包的 seq(下一 tick 快照回带,客户端 rollback 锚点)。
	for role in input_sources:
		var src: PacketInputSource = input_sources[role]
		src.clear_edges()
		if _pending_input.has(role):
			var q: Array = _pending_input[role]
			# COUNTDOWN(开局/换局 3 秒):双方禁止移动/开火——只清空缓冲不喂输入,
			# 玩家站在出生点不动(权威冻结;客户端是服务器渲染,自然跟随)。
			if _round_state == RoundState.COUNTDOWN:
				q.clear()
				src.reset_state()   # 连 held/axis 一起清,防上一包方向让服务器玩家在冻结期漂移(C2 分歧源)
				continue
			if not q.is_empty():
				var pkt: Dictionary = q.pop_front()
				src.apply_packet(pkt)
				_ack_seq[role] = int(pkt.get("seq", _ack_seq.get(role, 0)))
				# 地面武器:拾取/丢弃的**边沿**。★ 必须紧跟 apply_packet —— 本轮开头
				# 已经 clear_edges(),边沿就是这一包刚写进去的;晚一拍就被下一轮清掉了。
				_handle_ground_actions(role, src)
	# 玩家/子弹的 _physics_process 由树自动跑(子节点)
	# 子弹命中裁决 + 新子弹广播(玩家/子弹移动后)
	_adjudicate_bullets()
	# 即时光束武器(激光)权威开火上报:读各角色武器里待广播的光束,发给非射手端
	_broadcast_pending_beams()
	# 回合制:击杀倒地转换检测 + 状态机推进(倒计时/复活/回合结束/换边)
	_match_round_tick(delta)
	# 网络统计读数(诊断,默认关)
	_netstat_tick(delta)
	# 分帧重建可破坏碰撞块(爆炸拆墙)
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

# 仅测试用(`--test-destroy-tile`,见 MatchState.test_destroy_cell):对局开始 delay 秒后拆掉
# 指定格,**只拆一次**。默认关(`test_destroy_cell == (-1,-1)` → 首行就 return),生产路径
# 不带这个开关,行为与今天逐字一致。
#
# ★ 为什么走 `TileDefs.damage_tile` 而不是直接改 grid:那样才会经 `TileDefs.on_destroyed`
#   → `MatchCombat._on_tile_destroyed` → `_rpc_all("tile_destroyed", …)`,也就是
#   **与真爆炸完全同一条广播链**(重连探针的相⑦ 要验的正是这条链 + 客户端的补态)。
# ★ 那条 print 是探针的"非空转"证据:worker 是**独立 OS 进程**(探针拿不到它的 `_host`),
#   日志是唯一能读到它内部动作的通道;没有它,"客户端那格是空气"可以靠"那格本来就是空气"骗过。
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

# ══ Beta 回溯机(每 role 自身;他人不受影响)════════════════════════
# 环缓只存**该 role 自己**的状态(位置/速度/HP/朝向/倒地/弹量)+ **它自己的子弹**
# (pos/vel + rewind_state;不重建已消亡的弹 —— 已爆的榴弹不复活,已知边界)。
# 回溯期间:输入源 frozen(状态由历史驱动)、take_hit 免伤(meta 闸)、
# 自己的子弹随历史倒放且照常伤害他人(用户裁定)。

func _tick_beta_rewind(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for role in players:
		var r := int(role)
		var p := players[role] as Node2D
		var src: PacketInputSource = input_sources.get(role)
		var acc := time_economy.accounts.get(r) as GrainAccount
		if p == null or src == null or acc == null:
			continue
		# 显式类型:time_economy 无类型字段链式取值推不出;且 p 的 is_downed() 返回 Variant
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
		# 回溯中:烧颗粒(rewind_burn/s);游标 3×→1× ramp;驱动自身与自己的子弹
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
		# 轨迹:每 3 个物理帧一个点(他人残像;快照带下去,超过 10 个丢最旧)
		if Engine.get_physics_frames() % 3 == 0:
			var trail: Array = _rw_trail.get(r, [])
			trail.append([p.global_position.x, p.global_position.y])
			if trail.size() > 10:
				trail.pop_front()
			_rw_trail[r] = trail


## 退出回溯(**两条退出路径共用**:主动松开 / 颗粒耗尽)。
##
## ★★ 2026-10-03 修 —— **录像带模型**:把"被复写的未来"从环缓上**裁掉**。
##   原实现只做 `frozen=false` / 摘 meta / 清 trail,**不碰 `_rw_buf`** ⇒ 那些"已经被回溯抹掉"
##   的帧还留在环缓里,而寻帧是 `target = buf.back().t - cursor`(从**当前末尾**往回数)——
##   于是**下一次回溯会先把那段被抹掉的未来倒放一遍**(玩家看到的就是"回溯过的时间又出现了")。
##   单机那条线早就修过(`world_rewind.gd` 的 `finish()`,KH 的 D3「两次回溯串带」),
##   PvP 这份是后来写的、漏了这一步。两边的语义现在对齐。
##
## 保留语义与单机一致:裁完若一帧不剩,至少留 1 帧(倒到了磁带最老处 ⇒ 世界停在那帧上,
## 磁带从它重新起算)。裁完把游标归零(下次从新末尾重新起算)。
func _finish_rw(r: int, p: Node2D, src: PacketInputSource) -> void:
	src.frozen = false
	p.remove_meta("time_rewinding")
	_rw_on[r] = false
	_rw_trail[r] = []
	var buf: Array = _rw_buf.get(r, [])
	if buf.is_empty():
		_rw_cursor[r] = 0.0
		return
	# 出口时刻 = 当前末尾往回走了 cursor 秒。晚于它的一律是被复写的未来。
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


# 非回溯期:20Hz 采样自己的状态(超 rewind_buffer_seconds 裁剪)
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


# 回溯中:按游标找 ≤ 目标时刻的最近帧,写回自身 + 自己的子弹
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
	# 自己的子弹:活弹按序写回(位置/速度/引信)—— 照常伤害他人
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
