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
