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
var _base_grid: Array = []   # 建局原始(未破坏)网格深拷贝:每局复位重铺,防客户端/服务器砖状态漂移
var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
var _snapshot_accum := 0.0
const SNAPSHOT_INTERVAL := 1.0 / 60.0   # 60Hz 快照(unreliable;服务器 60Hz 模拟,本地玩家靠快照渲染,30Hz 太卡)
const HIT_RADIUS := 40.0   # 子弹命中判定半径(px, 玩家缩放 2.5 的碰撞箱量级)
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次)
var _snap_tick := 0   # 快照序号(客户端靠它丢弃乱序的旧快照)

# ── PvPvE 中立鸟:服务器权威模拟,位置 canonical,快照+spawn/died 事件同步 ──
# 发布开关:true=对局生成中立鸟;false=暂时不上鸟(PvP 纯净 1v1)。鸟代码保留,需要时翻回 true。
const ENABLE_BIRDS := false
var birds: Dictionary = {}   # bird_id(int) -> EnemyBase
var _next_bird_id := 1

# ── 回合制(阶段4):回合状态机 / 记分 / 复活 / 换边 ──
enum RoundState { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER }
const KILLS_TO_WIN := 5      # 每局先到 5 击杀赢
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
var _last_round_winner := 0            # 最近一局的胜者 role(客户端播报"本局胜利/落败"用)

func _init(map_path: String, role_peers: Dictionary) -> void:
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
	# 生成两个玩家(Player.tscn 完整物理模拟,注入 NetworkInputSource)
	peer_by_role = role_peers.duplicate()
	for role in role_peers:
		var p: Node2D = preload("res://scenes/player/Player.tscn").instantiate()
		var src := NetworkInputSource.new()
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

func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)

func _ready() -> void:
	# 开局回合:玩家已在 _init 摆位,进 COUNTDOWN
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	# 受击反馈:任意来源(子弹/鸟接触/鸟弹/爆炸)实际扣血 → combat.took_hit → 广播 hit_event
	for role in players:
		var combat = (players[role] as Node).get("combat")
		if combat != null and combat.has_signal("took_hit"):
			combat.took_hit.connect(_on_player_hit.bind(role))
	_spawn_round_birds()  # 内部按 ENABLE_BIRDS 守卫,关闭时开局/换局都不刷
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
			# COUNTDOWN(开局/换局 3 秒):双方禁止移动/开火——只清空缓冲不喂输入,
			# 玩家站在出生点不动(权威冻结;客户端是服务器渲染,自然跟随)。
			if _round_state == RoundState.COUNTDOWN:
				q.clear()
				continue
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

# ── PvPvE 中立鸟:读地图 # enemy meta,每局固定一批,死不补,换局/开局重置 ──
func _spawn_round_birds() -> void:
	if not ENABLE_BIRDS:
		return  # 发布开关关闭:任何时机(开局/换局)都不刷鸟
	_clear_birds()
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	var meta: Array = spawns.get("enemies", [])
	var ts := GameParameters.TILE_SIZE
	var roster: Array = []
	for entry in meta:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var type_name: String = str(entry.get("type", ""))
		var cell: Variant = entry.get("cell")
		if type_name.is_empty() or typeof(cell) != TYPE_VECTOR2I or not EnemySpawner.TYPES.has(type_name):
			continue
		var scene: PackedScene = load(EnemySpawner.TYPES[type_name])
		if scene == null:
			continue
		var spawn_cell := _nearest_floor_cell(cell)
		var e: CharacterBody2D = scene.instantiate()
		e.set("network_canonical", true)   # 服务器权威:位置存 canonical
		add_child(e)
		e.global_position = Vector2(spawn_cell.x * ts + ts * 0.5, spawn_cell.y * ts + ts * 0.5)
		var id := _next_bird_id
		_next_bird_id += 1
		birds[id] = e
		if e.has_signal("died"):
			e.died.connect(_on_bird_died.bind(id))
		roster.append({"id": id, "scene": EnemySpawner.TYPES[type_name], "pos": e.global_position})
	# 本局鸟清单发给两端客户端(建副本用;之后每帧快照带位置/动画)
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "enemy_spawn", roster)
	print("MatchHost: 刷鸟 %d 只" % roster.size())

# 把地图 meta 给的鸟出生格吸附到最近合法地板格(EMPTY、正下方 SOLID、头上留空)。
# 原因:PvP 的 # enemy 格未必是地板格(单机 EnemySpawner 只挑地板格,meta 常直接给半空/卡墙格),
# 直接照格出生会让鸟开局带睡姿自由落体或卡在几何里重力越积越大(空中睡姿的另一个来源)。
func _nearest_floor_cell(from: Vector2i) -> Vector2i:
	if _is_floor_cell(from):
		return from
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return from
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	for radius in range(1, 32):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var c := Vector2i(posmod(from.x + dx, cols), posmod(from.y + dy, rows))
				if _is_floor_cell(c):
					return c
	return from  # 找不到就保持原格(宁可原样,不丢鸟)

func _is_floor_cell(c: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	if c.y < 0 or c.x < 0 or c.y >= rows or c.x >= cols:
		return false
	if grid[c.y][c.x] != MazeGenerator.EMPTY:
		return false
	if not TileDefs.is_blocked(grid[posmod(c.y + 1, rows)][posmod(c.x, cols)]):
		return false
	# 头上留一格空,避免贴着天花板/嵌进头顶实心
	return grid[posmod(c.y - 1, rows)][posmod(c.x, cols)] == MazeGenerator.EMPTY

func _clear_birds() -> void:
	for id in birds:
		var e: Node = birds[id]
		if is_instance_valid(e):
			e.queue_free()
	birds.clear()
	_next_bird_id = 1

func _on_bird_died(id: int) -> void:
	birds.erase(id)
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "enemy_died", id)

# 快照:canonical 坐标(玩家在服务器上始终 wrap_to_range 到 [0,MAP))。unreliable,30Hz。
# 带递增序号 tick:客户端靠它丢弃乱序到达的旧快照(unreliable 通道可能乱序)。
func _broadcast_snapshot() -> void:
	_snap_tick += 1
	var snap := {"tick": _snap_tick, "players": {}}
	for role in players:
		var p: Node2D = players[role]
		# 是否正在预瞄(heavy_aim 蓄力):给对手副本画预瞄红线/弧(所有有预瞄的武器)。
		var previewing := false
		if p.weapons != null and p.weapons.current_weapon() != null:
			previewing = p.weapons.current_weapon().is_previewing()
		snap["players"][str(role)] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.get_facing(),
			"pose": p.state,
			"weapon": p.weapons.current_slot_int(),
			"hp": p.hp,
			"waterproof": p.waterproof,
			"downed": p.is_downed(),
			"aim": p.get_current_aim_dir(),
			"previewing": previewing,
		}
	# 中立鸟:canonical 位置 + 当前动画名 + 朝向(副本照播;死亡由 enemy_died 事件移除)
	var birds_snap := {}
	for id in birds:
		var e: Node2D = birds[id]
		if not is_instance_valid(e):
			continue
		var anim = e.get("_anim")
		var flip := false
		var anim_name := ""
		if anim != null:
			flip = bool(anim.flip_h)
			anim_name = str(anim.animation)
		birds_snap[str(id)] = {"pos": e.global_position, "flip": flip, "anim": anim_name}
	snap["enemies"] = birds_snap
	# 只发给仍在线的 peer(对方中途退出后 room teardown 前残留的帧不再刷错)
	var live_peers := multiplayer.get_peers()
	for role in peer_by_role:
		if live_peers.has(peer_by_role[role]):
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
		# 敌方子弹(无射手):服务器物理已裁决(撞玩家→take_hit),只广播视觉、不做半径补刀。
		if bullet.shooter == null:
			continue
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

func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	if victim.has_method("take_hit"):
		# 受击反馈广播统一走 combat.took_hit → _on_player_hit(子弹/鸟/爆炸同源,避免重复)
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	bullet.queue_free()

# 玩家受击反馈:实际扣血(子弹/鸟接触/鸟弹/爆炸) → 广播 hit_event 给两端客户端。
# 客户端按 victim_role:是自己 → 白闪/击退;是对手 → 对手副本受击闪烁。
# bind(role) 在 Godot 里把绑定参数追加在信号参数之后 → 实际入参顺序为 (source_pos, damage, role)。
func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	for r in peer_by_role:
		NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)

# ── 回合制 ──

# 某角色的对手 role(1v1,players 恰两个角色;找不到返回 0)。
func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0

# 本局角色出生点(换边感知):首局 _side_swap=false → P1=player/P2=player2;换边后交换。
func _spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))

# 每物理帧:倒地转换检测(击杀计分/安排复活) + 回合状态机推进。
func _match_round_tick(delta: float) -> void:
	for role in players:
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁:PLAYING 内倒地、未安排复活即安排。
		# (旧实现把调度塞在计分闩锁内,且读击杀用 get_meta_or_null —— 该方法 Godot 4.7 不存在,
		#  倒地判定在赋值 killer 时抛错中断 → 复活永不安排、击杀不计分、局永远推不完。)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 击杀定义:对方死亡都算 —— 不分死因(枪杀/爆炸/溺水/自伤/无射手)一律记给对方 +1。
		# (旧实现靠 pvp_killer 射手归因、无射手不计分,已废弃。)
		var scorer := _opponent_of(role)
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			_broadcast_kill(scorer, role)
			_broadcast_round_state()
			# 击杀后双方复位:死者照常走 _respawn_player(2s 后满血复活);
			# 活着的「我方」立刻回本方出生点但保留当前血量(不回血,防复活点连杀)。
			_reset_survivor(scorer)
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

# 击杀后活方「复位」:回到本方出生点但保留血量/防水,不治疗。死者(另一 role)照常满血复活。
func _reset_survivor(role: int) -> void:
	if not players.has(role):
		return
	var p: Node2D = players[role]
	if p.is_downed():   # 同归于尽:双方都是死者、无活方,各走自己的复活流程
		return
	var spawn := _spawn_cell(role)
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	p.velocity = Vector2.ZERO
	if p.has_method("cancel_jump_state"):
		p.cancel_jump_state()

func _round_over(winner: int) -> void:
	_last_round_winner = winner
	_rounds_won[winner] = int(_rounds_won.get(winner, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()

# 换局复位(服务器权威):清掉场上所有子弹 + 把可破坏砖/碰撞整层还原为建局基线。
# 客户端在同一时刻收到新一轮 COUNTDOWN 也做同款复位(Level0.reset_destructibles),
# 双方从同一基线出发 → 消除"客户端多拆/少拆砖"造成的幽灵碰撞,旧子弹不跨局残留。
func _reset_world_and_clear_dynamics() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	_seen_bullets.clear()
	if _base_grid.is_empty():
		return
	var g := MazeGenerator.copy_grid(_base_grid)
	grid = g
	MazeGenerator.current_grid = g
	TileDefs.init_hp(g)
	destructible_sub = WorldBuilder.build_sim(self, g)

func _start_next_round() -> void:
	# 三局两胜:先赢 2 局 → MATCH_OVER
	for role in players:
		if int(_rounds_won.get(role, 0)) >= ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	# 换边 + 下一局
	_reset_world_and_clear_dynamics()
	_side_swap = not _side_swap
	_round_num += 1
	_scores = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_spawn_round_birds()   # 换局:清上一局鸟 + 按地图 meta 重刷
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
	# 客户端按自己 role 播报"本局胜利/落败"(ROUND_OVER)与"胜利/失败"(MATCH_OVER)
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "round_state", data)

func _match_winner() -> int:
	var best_role := 0
	var best_n := -1
	for role in players:
		var n: int = int(_rounds_won.get(role, 0))
		if n > best_n:
			best_n = n
			best_role = int(role)
	return best_role

func _broadcast_kill(killer: int, victim: int) -> void:
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "kill_event", killer, victim)
