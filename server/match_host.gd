class_name MatchHost
extends Node

# 服务器权威对局模拟(每房间一个):建世界(只碰撞不渲染)+ 两个 Player(NetworkInputSource 注入)。
# 每物理帧消费双方输入包注入,玩家 _physics_process 自动跑(Player 是 CharacterBody2D,父先于子)。
# 协议只传 canonical 坐标;渲染归各端副本(客户端侧),服务器只存真值。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> NetworkInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> 最新输入包
var grid: Array = []
var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
var _snapshot_accum := 0.0
const SNAPSHOT_INTERVAL := 1.0 / 30.0   # 30Hz 快照(unreliable)
const HIT_RADIUS := 40.0   # 子弹命中判定半径(px, 玩家缩放 2.5 的碰撞箱量级)
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次)

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
	var spawns := MazeGenerator.load_spawns()
	for role in role_peers:
		var p: Node2D = preload("res://Scenes/Player/Player.tscn").instantiate()
		var src := NetworkInputSource.new()
		p.set_input_source(src)
		add_child(p)
		var spawn: Vector2i = spawns.get("player" if role == 1 else "player2", Vector2i(-1, -1))
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts / 2.0, spawn.y * ts + ts / 2.0)
		players[role] = p
		input_sources[role] = src
		print("MatchHost: 角色 %d 出生点 %s" % [role, spawn])

func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)

func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in peer_by_role:
		if peer_by_role[role] == caller:
			_pending_input[role] = pkt
			return

func _physics_process(delta: float) -> void:
	# 消费输入(父先于子 → 玩家 _physics_process 读到的已是最新注入)
	for role in input_sources:
		var src: NetworkInputSource = input_sources[role]
		src.begin_tick()
		if _pending_input.has(role):
			src.apply_packet(_pending_input[role])
	# 玩家/子弹的 _physics_process 由树自动跑(子节点)
	# 子弹命中裁决 + 新子弹广播(玩家/子弹移动后)
	_adjudicate_bullets()
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

# 快照:canonical 坐标(玩家在服务器上始终 wrap_to_range 到 [0,MAP))。unreliable,30Hz。
func _broadcast_snapshot() -> void:
	var snap := {"players": {}}
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
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
		# 广播命中事件给双方客户端(受害者白闪/击退反馈)
		for role in peer_by_role:
			NetBus.rpc_id(peer_by_role[role], "hit_event", victim_role, bullet.hit_damage, bullet.global_position)
	bullet.queue_free()
