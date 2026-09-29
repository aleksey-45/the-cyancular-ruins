class_name MatchHost
extends MatchRound

# 对局权威(核心):生命周期、输入 FIFO 消费、每物理帧编排、出生点。
#
# ★ 2026-09-15(阶段 5.6)按域拆成一条继承链,本文件只剩**核心**;四个域在
#   match_snapshot / match_combat / match_round / match_state 里,见基类注释。
#   **C2 四条不变量仍在 `_physics_process` 与 `_on_input` 里,原样未动。**

const TIME_SYNC_INTERVAL := 0.1   # Beta:颗粒状态下发节律(10Hz;怀表数字平滑够了)

var _time_sync := 0.0

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
		(players[role] as Node).weapons.set_enabled_slots(_disabled_weapons)
	# 地面武器:铺 12 把 + 每个玩家随机拿 1 把。
	# ★ 必须排在 set_enabled_slots **之后** —— 与单机 `_give_starting_weapon` 同款理由:
	#   先给再禁的话,手上一旦是禁用武器会被判成空手。
	# ★ 这同时是**服务器玩家有枪的唯一来源**:player.tscn 自身的 _ready 给的是空背包,
	#   不发的话服务器上的玩家开不了火(PvP 直接哑火,且不会有任何报错)。
	_setup_ground_weapons()
	# 受击反馈:任意来源(子弹/鸟接触/鸟弹/爆炸)实际扣血 → combat.took_hit → 广播 hit_event
	_wire_hit_feedback()
	_broadcast_round_state()


# 把每个玩家的 `combat.took_hit` 接到本宿主的 `_on_player_hit`。
# ★ 接线走**裸方法名**(`Callable(self, "_on_player_hit")`)⇒ **虚分派**:子类覆写的那份才是
#   被调到的那个(`TeamHost._on_player_hit` 的逐人伤害累计就挂在这条上)。
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
#  消费者 `tests/royale_probe` 的"未收到 match_options = FAIL"断言不变 —— 它现在验的是拉取路径。)

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
	# Beta 时间玩法:加速态(在快照**前**定格 —— 快照的 haste 位读的就是这个倍率)。
	# 裁决在服务器:按住 + 账户可耗才生效;只乘自己(别的角色/子弹/世界一概不动)。
	if time_economy != null:
		for role in input_sources:
			var acc := time_economy.accounts.get(int(role)) as GrainAccount
			var p := players.get(int(role)) as Node2D
			if acc == null or p == null:
				continue
			var src: PacketInputSource = input_sources[role]
			var on := src.haste_held() and acc.can_spend()
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
