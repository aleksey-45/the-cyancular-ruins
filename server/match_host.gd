class_name MatchHost
extends MatchRound

# 对局权威(核心):生命周期、输入 FIFO 消费、每物理帧编排、出生点。
#
# ★ 2026-09-15(阶段 5.6)按域拆成一条继承链,本文件只剩**核心**;四个域在
#   match_snapshot / match_combat / match_round / match_state 里,见基类注释。
#   **C2 四条不变量仍在 `_physics_process` 与 `_on_input` 里,原样未动。**

func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = []) -> void:
	_options = options
	_round_full_heal = bool(options.get("round_full_heal", false))
	var raw_disabled: Array = options.get("disabled_weapons", [])
	for v in raw_disabled:
		_disabled_weapons.append(int(v))
	_ai_roles = ai_roles
	MazeGenerator.set_map_file(map_path)
	# 建世界:碰撞 + 瓦片属性(不渲染)。服务器进程走场景模式,autoload/静态类已就绪。
	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	_base_grid = MazeGenerator.copy_grid(grid)
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
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
	for role in players:
		var combat = (players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))
	_broadcast_round_state()

# (原 `_broadcast_match_options` 已删 —— 生效选项改由对局场景**进场拉取**下发:
#  那次"推"与 match_start 落在同一次客户端 poll,而那一刻新场景的订阅方还不存在 → 静默丢失
#  (自检 B2:禁武器闸门没上)。现在 options 随 `NetBus.match_sync` 的应答一起给。
#  消费者 `tests/royale_probe` 的"未收到 match_options = FAIL"断言不变 —— 它现在验的是拉取路径。)

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
	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_broadcast_snapshot()
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
