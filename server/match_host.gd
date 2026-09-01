class_name MatchHost
extends Node

# 服务器权威对局模拟(每房间一个):建世界(只碰撞不渲染)+ 两个 Player(NetworkInputSource 注入)。
# 每物理帧消费双方输入包注入,玩家 _physics_process 自动跑(Player 是 CharacterBody2D,父先于子)。
# 协议只传 canonical 坐标;渲染归各端副本(客户端侧),服务器只存真值。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> NetworkInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> Array[输入包队列],按序消费不丢 just_pressed 边沿
var grid: Array = []
var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
var _snapshot_accum := 0.0
const SNAPSHOT_INTERVAL := 1.0 / 60.0   # 60Hz 快照(unreliable;服务器 60Hz 模拟,本地玩家靠快照渲染,30Hz 太卡)
const HIT_RADIUS := 40.0   # 子弹命中判定半径(px, 玩家缩放 2.5 的碰撞箱量级)
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次)
var _snap_tick := 0   # 快照序号(客户端靠它丢弃乱序的旧快照)

# ── 回合制(阶段4):回合状态机 / 记分 / 复活 / 换边 ──
enum RoundState { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER }
const KILLS_TO_WIN := 10     # 每局先到 10 击杀赢
const ROUNDS_TO_WIN := 2     # 三局两胜
const COUNTDOWN_TIME := 3.0
const ROUND_OVER_TIME := 4.0
const RESPAWN_DELAY := 2.0   # 局内死亡后复活延迟
var _round_state := RoundState.COUNTDOWN
var _round_num := 1
var _scores: Dictionary = {}     # role -> 本局击杀
var _rounds_won: Dictionary = {} # role -> 局胜数
var _round_timer := 0.0
var _side_swap := false          # true 时 P1 用 player2 出生点(每局换边)
var _respawn_pending: Dictionary = {}  # role -> 剩余复活秒
var _down_counted: Dictionary = {}     # role -> 本次倒地是否已计分/已入复活流程

func _init(map_path: String, role_peers: Dictionary) -> void:
	MazeGenerator.set_map_file(map_path)
	# 建世界:碰撞 + 瓦片属性(不渲染)。服务器进程走场景模式,autoload/静态类已就绪。
	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
	destructible_sub = WorldBuilder.build_sim(self, grid)
	# 生成两个玩家(Player.tscn 完整物理模拟,注入 NetworkInputSource)
	peer_by_role = role_peers.duplicate()
	for role in role_peers:
		var p: Node2D = preload("res://Scenes/Player/Player.tscn").instantiate()
		var src := NetworkInputSource.new()
		p.set_input_source(src)
		add_child(p)
		players[role] = p
		input_sources[role] = src
		# 首局直接摆位(_respawn_player 依赖 combat/weapons,需玩家 _ready 后才能调,放到 _ready/_start_next_round)
		var spawn := _spawn_cell(role)
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
		print("MatchHost: 角色 %d 出生点 %s" % [role, spawn])

func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)

func _ready() -> void:
	# 开局回合:玩家已在 _init 摆位,进 COUNTDOWN
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()

func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in peer_by_role:
		if peer_by_role[role] == caller:
			# 缓冲本帧到达的包,下一物理帧开头统一应用:
			#   held/axis 取最新(覆盖,服务器紧跟客户端不滞后);
			#   just_pressed 边沿累积(|=),不丢抓梯/跳跃/开火边沿(这是服务器模拟与客户端脱节的根因)。
			if not _pending_input.has(role):
				_pending_input[role] = []
			(_pending_input[role] as Array).append(pkt)
			return

func _physics_process(delta: float) -> void:
	# 应用输入(父先于子 → 玩家 _physics_process 读到的已是最新注入)。
	# 先清上一物理帧已读的边沿,再把本帧缓冲的包统一应用(held 最新、边沿累积)。
	for role in input_sources:
		var src: NetworkInputSource = input_sources[role]
		src.clear_edges()
		if _pending_input.has(role):
			var q: Array = _pending_input[role]
			for pkt in q:
				src.apply_packet(pkt)
			q.clear()
	# 玩家/子弹的 _physics_process 由树自动跑(子节点)
	# 子弹命中裁决 + 新子弹广播(玩家/子弹移动后)
	_adjudicate_bullets()
	# 回合制:击杀倒地转换检测 + 状态机推进(倒计时/复活/回合结束/换边)
	_match_round_tick(delta)
	# 快照广播(玩家移动后)
	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_broadcast_snapshot()
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

func _on_tile_destroyed(cell: Vector2i) -> void:
	# 服务器无瓦片渲染层,只需清持久子格 + 标记分块重建
	if not destructible_sub.is_empty():
		for qy in range(2):
			for qx in range(2):
				destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	# 广播拆墙给双方客户端:客户端子弹是视觉副本(apply_damage=false)不判伤害,
	# 服务器拆的墙必须由事件驱动客户端清瓦片渲染,否则建筑"看着没被炸坏"。
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "tile_destroyed", cell)

# 快照:canonical 坐标(玩家在服务器上始终 wrap_to_range 到 [0,MAP))。unreliable,30Hz。
# 带递增序号 tick:客户端靠它丢弃乱序到达的旧快照(unreliable 通道可能乱序)。
func _broadcast_snapshot() -> void:
	_snap_tick += 1
	var snap := {"tick": _snap_tick, "players": {}}
	for role in players:
		var p: Node2D = players[role]
		snap["players"][str(role)] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.get_facing(),
			"pose": p.state,
			"weapon": p.weapons.current_slot_int(),
			"hp": p.hp,
			"waterproof": p.waterproof,
			"downed": p.is_downed(),
		}
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "snapshot", snap)

# 子弹裁决:遍历 bullet 组。新子弹广播给非射手客户端;命中判定 = 与对手玩家的 toroidal 距离 < HIT_RADIUS。
func _adjudicate_bullets() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as CharacterBody2D
		# 新子弹:广播给非射手客户端(射手已本地生成视觉)
		var bid: int = bullet.get_instance_id()
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)
		# 命中裁决:对非射手玩家算 toroidal 距离
		for role in players:
			var p: Node2D = players[role]
			if p == bullet.shooter:
				continue
			var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < HIT_RADIUS:
				_on_bullet_hit(bullet, p, role)
				break

func _broadcast_bullet_spawn(bullet: CharacterBody2D) -> void:
	var scene_path := ""
	if bullet.scene_file_path != "":
		scene_path = bullet.scene_file_path
	elif bullet.has_meta("scene_path"):
		scene_path = bullet.get_meta("scene_path")
	# 协议只传 canonical [0,MAP):子弹锚到射手最近副本后可能是副本偏移坐标,归位。
	var canonical_pos := MazeGenerator.wrap_to_range(bullet.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var data := {
		"scene": scene_path,
		"pos": canonical_pos,
		"vel": bullet.velocity_vec,
		"speed": bullet.speed,
		"range": bullet.max_range,
		"size": bullet.size,
		"color": bullet.bullet_color,
		"gravity": bullet.gravity_factor,
		"hit_damage": bullet.hit_damage,
		"hit_impact": bullet.hit_impact,
		"explodes": bullet.explodes,
		"direct_damage": bullet.direct_hit_damage,
		"fuse": bullet.fuse_time,
		"hit_fuse": bullet.hit_fuse_time,
		"radius": bullet.explosion_radius,
		"expl_damage": bullet.explosion_damage,
		"expl_knock": bullet.explosion_knockback,
	}
	if bullet.explosion_visual != null:
		data["visual"] = bullet.explosion_visual.resource_path
	# 发给非射手客户端
	for role in peer_by_role:
		if players.has(role) and players[role] != bullet.shooter:
			NetBus.rpc_id(peer_by_role[role], "bullet_spawn", data)

func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	if victim.has_method("take_hit"):
		var was_down: bool = victim.has_method("is_downed") and victim.is_downed()
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
		# 击杀归因:本击致命(存活→倒地)→ 记射手,由 _match_round_tick 倒地转换检测计分
		# (溺水/自伤/无射手 = 不设 meta → 不计分)
		if not was_down and victim.has_method("is_downed") and victim.is_downed():
			victim.set_meta("pvp_killer", bullet.shooter)
		# 广播命中事件给双方客户端(受害者白闪/击退反馈)
		for role in peer_by_role:
			NetBus.rpc_id(peer_by_role[role], "hit_event", victim_role, bullet.hit_damage, bullet.global_position)
	bullet.queue_free()

# ── 回合制 ──

# 玩家节点 → role(0=无)。玩家是服务器权威模拟里的 Player 实例。
func _role_of(node: Node) -> int:
	if node == null:
		return 0
	for r in players:
		if players[r] == node:
			return int(r)
	return 0

# 本局角色出生点(换边感知):首局 _side_swap=false → P1=player/P2=player2;换边后交换。
func _spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))

# 每物理帧:倒地转换检测(击杀归因/计分/安排复活) + 回合状态机推进。
func _match_round_tick(delta: float) -> void:
	# 击杀:直击在 _on_bullet_hit 记 pvp_killer,爆炸在 apply_aoe 记,统一这里计分。
	for role in players:
		if _down_counted.get(role, false):
			continue
		var p: Node2D = players[role]
		if p.is_downed():
			_down_counted[role] = true
			var killer := _role_of(p.get_meta_or_null("pvp_killer"))
			p.remove_meta("pvp_killer")
			if killer != 0 and killer != role:
				_scores[killer] = int(_scores.get(killer, 0)) + 1
				_broadcast_kill(killer, role)
				_broadcast_round_state()
			if _round_state == RoundState.PLAYING:
				_respawn_pending[role] = RESPAWN_DELAY
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				_broadcast_round_state()
		RoundState.PLAYING:
			_handle_respawns(delta)
			for role in players:
				if int(_scores.get(role, 0)) >= KILLS_TO_WIN:
					_round_over(role)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass   # 对局结束,等玩家退出/服务器关房

# 局内死亡复活:倒计时后重生(重置血量/防水/位置/武器)。
func _handle_respawns(delta: float) -> void:
	for role in _respawn_pending.keys():
		_respawn_pending[role] = float(_respawn_pending[role]) - delta
		if _respawn_pending[role] <= 0.0:
			_respawn_player(role)

# 重生:摆到本局出生点,血量/防水/倒地复位,武器回 1。
func _respawn_player(role: int) -> void:
	var p: Node2D = players[role]
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	p.apply_authoritative_state(p.max_hp, p.max_waterproof, false)
	if p.has_method("cancel_jump_state"):
		p.cancel_jump_state()
	if p.weapons != null and p.weapons.has_method("equip"):
		p.weapons.equip("1")
	_respawn_pending.erase(role)
	_down_counted[role] = false
	p.remove_meta("pvp_killer")

func _round_over(winner: int) -> void:
	_rounds_won[winner] = int(_rounds_won.get(winner, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()

func _start_next_round() -> void:
	# 三局两胜:先赢 2 局 → MATCH_OVER
	for role in players:
		if int(_rounds_won.get(role, 0)) >= ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	# 换边 + 下一局
	_side_swap = not _side_swap
	_round_num += 1
	_scores = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()

func _broadcast_round_state() -> void:
	var data := {
		"state": _round_state,
		"round": _round_num,
		"scores": _scores,
		"rounds_won": _rounds_won,
		"timer": _round_timer,
	}
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "round_state", data)

func _broadcast_kill(killer: int, victim: int) -> void:
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "kill_event", killer, victim)
