class_name Level0
extends Node2D

# 地形由 Terrain 统一维护；场景负责装载、时间轴和表现提交。
@onready var wall_layer: TileMapLayer = $WorldViewport/TerrainLayers/WallLayer
@onready var water_layer: TileMapLayer = $WorldViewport/TerrainLayers/WaterLayer
@onready var water_surface_layer: Node2D = $WorldViewport/TerrainLayers/WaterSurfaceLayer
var map_info: Dictionary
var terrain: Terrain
var spawn_cell: Vector2i
var enabled_weapons: Array[int]
var _weapon_floors: Array[Vector2i]
var _wall_rows: Dictionary = {}
var _view_margin := Vector2.ZERO
@onready var _terrain_layers: Node2D = $WorldViewport/TerrainLayers

# PvP 模式:只建世界(地图/瓦片/碰撞/水),玩家/敌人/相机/后处理由 PvP 场景负责。
var pvp_mode := false

# 避免一次性同步销毁大量物理与渲染节点引发卡顿或崩溃。
# 场景切换过渡中标志：防止同帧或相近帧重复进入切换逻辑。
static var _switching: bool = false

## 怀表时间系统账户与时间场(单机;PvP 不建 → 时间系统整体旁路)
var time_field: TimeField
var _rewind: WorldRewind = null   # 世界快照/回放(单机;PvP 不建)
var _post_process: PostProcess = null
var _film_t: float = 0.0          # 回溯底片化强度(get 平滑 ramp,≤200ms)
var _haste_t: float = 0.0         # 加速视效强度(ramp 100ms)
# 时间状态高亮使用实体的 TimeGlow 加色副本。
var _glows: Dictionary = {}

static func safe_change_scene(tree: SceneTree, path: String) -> void:
	if _switching:
		return
	_switching = true
	# 信号回调尚未退出时，旧场景必须留在树中。
	await tree.process_frame
	var old: Node = tree.current_scene
	var next: Node = load(path).instantiate()
	tree.root.add_child(next)
	tree.current_scene = next
	if old != null and old != next:
		tree.root.remove_child(old)
		old.visible = false
		start_reap(tree, old)
	_switching = false

# 将大场景节点的同步销毁平摊到多个帧中，并在显示菜单期间后台逐步回收。
# 销毁顺序采用逆前序遍历，确保子节点优先于父节点被释放。
# 每物理帧执行受时间预算限制，避免瞬时卡顿。
const REAP_BUDGET_US := 3000      # 每帧销毁耗时预算（微秒）
static var _reap_queue: Array[Node] = []
static var _reaper_driver: Node = null

class _Reaper extends Node:
	func _ready() -> void:
		# 切换场景可能在暂停中发生，销毁驱动节点不受暂停影响
		process_mode = Node.PROCESS_MODE_ALWAYS
		set_process(true)

	func _process(_delta: float) -> void:
		if Level0.reap_step():
			queue_free()

	func _exit_tree() -> void:
		if Level0._reaper_driver == self:
			Level0._reaper_driver = null

# 将旧场景追加到分帧释放队列，复用仍存活的回收驱动。
static func start_reap(tree: SceneTree, world: Node) -> void:
	if world == null or not is_instance_valid(world):
		return
	# 队列追加未完成的拆除任务
	_collect_preorder(world, _reap_queue)
	# 驱动者还活着就复用(它与拆除队列都是全局的,不需要第二个);已排队待删的另起一个 ——
	# 不能只判 != null:它可能刚判空、正等帧末销毁,复用会让新队列没人拆。
	if _reaper_driver == null or not is_instance_valid(_reaper_driver) \
			or _reaper_driver.is_queued_for_deletion():
		_reaper_driver = _Reaper.new()
		_reaper_driver.name = "WorldReaper"
		tree.root.add_child(_reaper_driver)

# 推进一步。返回 true = 队列已空(驱动者据此自毁)。
static func reap_step() -> bool:
	var deadline := Time.get_ticks_usec() + REAP_BUDGET_US
	while not _reap_queue.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _reap_queue.pop_back()
		if is_instance_valid(n):
			n.free()
	return _reap_queue.is_empty()

static func _collect_preorder(n: Node, out: Array[Node]) -> void:
	out.append(n)
	for c in n.get_children():
		_collect_preorder(c, out)

# 根 Window 的输入事件不会自动路由进 SubViewport（WorldViewport），
# 所以 SubViewport 内节点（玩家/枪）的 _unhandled_input 收不到。
# 在根级把未处理输入手动转发进 WorldViewport。
func _unhandled_input(event: InputEvent) -> void:
	$WorldViewport.push_input(event)

var combat_rules: CombatSimulator

func _enter_tree() -> void:
	terrain = Terrain.new(map_info["grid"], map_info["descriptors"])
	$WorldViewport.world_2d = World2D.new()
	if not pvp_mode:
		time_field = TimeField.new(GrainAccount.new())

func _ready() -> void:
	# 清屏背景色与地形图集统一保持一致
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	add_child(preload("res://ui/hud/combat_feedback.tscn").instantiate())

	var grid: Array[Array] = map_info["grid"]
	var viewport: SubViewport = $WorldViewport
	var camera = $WorldViewport/Camera2D
	_view_margin = Vector2(viewport.size) / (2.0 * camera.zoom)
	camera.view_moved.connect(_align_terrain_layers)

	var water_rows := {}
	for desc in TerrainAtlas.descriptor_rows(terrain.descriptors()):
		if TileDefs.is_liquid(MapFormatV4.descriptor_texture(desc)):
			water_rows.get_or_add(desc & MapFormatV4.TINT_MASK, water_rows.size())
		else:
			_wall_rows[desc] = _wall_rows.size()
	wall_layer.tile_set = TerrainAtlas.make_wall_tileset(_wall_rows)
	_paint_maze()
	water_layer.tile_set = TerrainAtlas.make_water_tileset(
			GameParameters.TILE_SIZE, TerrainAtlas.WATER_BODY_BRICK, water_rows)
	_paint_water(grid, water_rows)
	terrain.attach(viewport)

	if pvp_mode:
		set_physics_process(false)
		set_process(false)
		return
	process_physics_priority = -100 # 提交上一个 tick 的地形和历史，确定本 tick 的时间模式。
	var player: Player = $WorldViewport/Player
	var damage_numbers := DamageNumbers.new(player)
	viewport.add_child(damage_numbers)
	combat_rules = CombatSimulator.new(terrain, viewport)
	combat_rules.time_field = time_field
	var watch: WatchHud = $HUD.watch
	combat_rules.grain_dropped.connect(func(at: Vector2, amount: int) -> void:
		GrainCrystalFx.spawn(viewport, at, amount, time_field.account, watch))
	player.combat_rules = combat_rules
	player.ground_actions = _handle_ground_actions
	player.projectile_count = combat_rules.count_projectiles.bind(player)
	combat_rules.projectile_spawned.connect(_present_projectile)
	combat_rules.detonated.connect(func(_id: int, pos: Vector2, type_id: int) -> void:
		ProjectileVisual.explosion(viewport, pos, player, WeaponRegistry.blast_definition(type_id)["radius"], terrain))
	combat_rules.beam_fired.connect(func(_id: int, _shot: Dictionary, points: PackedVector2Array) -> void:
		preload("res://core/present/laser_visual.gd").play(viewport, points, player.global_position, terrain.map_size))
	combat_rules.tile_hit.connect(_present_tile_hit)
	combat_rules.player_hit.connect(func(_source: int, victim: Player, damage: int,
			_knock_changed: bool, _force: float) -> void:
		if damage > 0:
			victim.play_hit_feedback(damage)
			damage_numbers.add_hit(victim, damage))
	combat_rules.npc_hit.connect(func(source: Node, victim: EnemyBase, damage: int) -> void:
		if source is Player:
			CombatFeedback.hit_marker()
			damage_numbers.add_hit(victim, damage))
	combat_rules.projectile_hit_npc.connect(func(type_id: int) -> void:
		var sound: String = WeaponRegistry.projectile_definition(type_id)["npc_hit_sound"]
		if not sound.is_empty():
			Sfx.play(sound))
	EnemySpawner.load_types()
	_weapon_floors = SpawnPicker.floor_cells(grid, map_info["size"])
	player.weapons.enabled_types = enabled_weapons
	_rewind = WorldRewind.new(combat_rules)
	terrain.rewind_enabled = true
	_start_single()

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	_post_process = pp
	player.post_process = pp
	add_child(pp)
	add_child(PauseMenu.new(false))

func _exit_tree() -> void:
	if time_field != null:
		Sfx.pitch_mult = 1.0


func _align_terrain_layers(center: Vector2) -> void:
	# 相机平滑或震动越界时，整层移动一个地图周期，让相机仍落在铺图的主区间。
	var origin := (center / terrain.map_size).floor() * terrain.map_size
	if _terrain_layers.position != origin:
		_terrain_layers.position = origin


func _paint_maze() -> void:
	var descriptors := terrain.descriptors()
	for i in descriptors.size():
		_paint_wall(i, descriptors[i], true)


func _paint_wall(index: int, desc: int, alive: bool) -> void:
	var row: int = _wall_rows.get(desc, -1)
	if row < 0:
		return
	var sub := terrain.sub_position(index)
	var p := Terrain.SUB_PER_CELL
	var quad := (sub.y % p) * p + sub.x % p
	var atlas := TerrainAtlas.atlas_coords(row, quad)
	var span := Vector2i(terrain.sub_columns, terrain.sub_rows)
	var copies := GridPathfinder.seam_copy_range(Rect2(Vector2(sub), Vector2.ONE),
			Vector2(span), _view_margin / Terrain.SUB_SIZE)
	for y in range(copies.position.y, copies.end.y):
		for x in range(copies.position.x, copies.end.x):
			var cell := sub + Vector2i(x, y) * span
			if alive:
				wall_layer.set_cell(cell, 0, atlas)
			else:
				wall_layer.erase_cell(cell)

# 64px 水格取同材质子格中出现最多的辅码，平票取较小值。
func _water_tint(descriptors: PackedInt32Array, cell: Vector2i, texture: int) -> int:
	var counts := {}
	var best := MapFormatV4.NEUTRAL_TINT
	var best_count := 0
	var p := Terrain.SUB_PER_CELL
	var start := cell.y * p * terrain.sub_columns + cell.x * p
	for y in p:
		for x in p:
			var desc := descriptors[start + y * terrain.sub_columns + x]
			if MapFormatV4.descriptor_texture(desc) != texture:
				continue
			var tint := desc & MapFormatV4.TINT_MASK
			var count := int(counts.get(tint, 0)) + 1
			counts[tint] = count
			if count > best_count or (count == best_count and tint < best):
				best = tint
				best_count = count
	return best

func _paint_water(grid: Array[Array], water_rows: Dictionary) -> void:
	var ts := GameParameters.TILE_SIZE
	var span := Vector2i(terrain.columns, terrain.rows)
	var reach := _view_margin / ts
	var descriptors := terrain.descriptors()
	var surface_groups := {}
	for y in terrain.rows:
		var above: Array = grid[posmod(y - 1, terrain.rows)]
		for x in terrain.columns:
			var value: int = grid[y][x]
			var texture := MapFormat.texture_of(value)
			if not TileDefs.is_liquid(texture):
				continue
			var cell := Vector2i(x, y)
			var tint := _water_tint(descriptors, cell, texture)
			var is_surface := not TileDefs.is_liquid(MapFormat.texture_of(above[x]))
			var atlas := TerrainAtlas.atlas_coords(water_rows[tint], MapFormat.shape_of(value))
			var bounds := Rect2(Vector2(cell), Vector2.ONE)
			if is_surface:
				bounds = bounds.grow_individual(0.0, GameParameters.water_sway_amp / ts, 0.0, 0.0)
			var copies := GridPathfinder.seam_copy_range(bounds, Vector2(span), reach)
			for ty in range(copies.position.y, copies.end.y):
				for tx in range(copies.position.x, copies.end.x):
					var at := cell + Vector2i(tx, ty) * span
					if is_surface:
						surface_groups.get_or_add(tint, []).append({
							"pos": (Vector2(at) + Vector2(0.5, 1.0)) * ts,
							"phase": x * 1.7 + y * 2.3,
						})
					else:
						water_layer.set_cell(at, 0, atlas)
	for tint in surface_groups:
		var batch := WaterSurfaceBatch.new()
		var image := TerrainAtlas.water_brick_image(ts, TerrainAtlas.WATER_SURFACE_BRICK, tint)
		batch.setup(surface_groups[tint], ImageTexture.create_from_image(image), ts)
		water_surface_layer.add_child(batch)

func _physics_process(delta: float) -> void:
	terrain.flush_collisions()
	var was_rewinding := time_field.is_rewinding()
	_drive_time(delta)
	_tick_rewind(delta, was_rewinding)

func _process(delta: float) -> void:
	flush_terrain_visuals()
	_tick_time_visuals(delta)
	_update_pickup_prompt()


func _present_projectile(bullet: BulletBody) -> void:
	var view := ProjectileVisual.new()
	view.configure(terrain, bullet.type_id, bullet.size)
	view.follow(bullet, $WorldViewport/Player)
	$WorldViewport.add_child(view)
	bullet.tree_exiting.connect(view.queue_free)

func _present_tile_hit(point: Vector2, texture_id: int) -> void:
	var anchor: Vector2 = $WorldViewport/Player.global_position
	var pos := GridPathfinder.anchor_to_nearest(point, anchor, terrain.map_size)
	preload("res://scenes/effects/tile_hit_fx.gd").spawn($WorldViewport, pos, texture_id)

# 回溯中的弹丸可再次命中不受时间回溯影响的精英。
func _rewind_elite_hits() -> void:
	var world := CollisionWorld.acquire($WorldViewport)
	for bullet: BulletBody in combat_rules.projectiles.values():
		if not bullet.shooter is Player:
			continue
		for entry: Dictionary in world.shape_overlaps(bullet.shape, bullet.global_transform, CollisionWorld.LAYER_ENEMY):
			var elite := entry["collider"] as EnemyBase
			if elite == null or not elite.has_meta("elite") or elite.is_dead:
				continue
			var id := elite.get_instance_id()
			if bullet.rewind_hits.has(id):
				continue
			bullet.rewind_hits[id] = true
			combat_rules.resolve_hit(bullet.shooter, elite, CombatProfiles.DIRECT, bullet.global_position,
					bullet.hit_damage, bullet.hit_impact, combat_rules.hit_direction(bullet.global_position, elite.global_position))

func flush_terrain_visuals() -> void:
	terrain.flush_visual_changes(_paint_wall)

func restart_single() -> void:
	terrain.reset()
	flush_terrain_visuals()
	# 重开是新时间线，旧地图的 HP 和实体历史不能带入新开局。
	_rewind = WorldRewind.new(combat_rules)
	time_field.mode = TimeField.Mode.NONE
	combat_rules.clear()
	for enemy: EnemyBase in _world_enemies():
		enemy.queue_free()
	clear_pickups()
	_start_single()

func _start_single() -> void:
	var player: Player = $WorldViewport/Player
	player.restart_at(spawn_cell)
	player.weapons.set_initial_inventory([enabled_weapons[0]])
	$EnemySpawner.spawn_all(map_info["spawns"]["enemies"])
	_scatter_weapons()


var _next_pickup_inst: int = 1
var _pickup_nodes: Dictionary = {}      # inst -> WeaponPickup

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


func _handle_ground_actions(player: Player, record: Array) -> void:
	var pressed: int = record[ActorInput.PRESSED]
	if pressed & ActorInput.BIT_DROP:
		GroundWeaponField.drop(player, player.weapons.drop_current(), spawn_pickup.bind(true))
	if pressed & ActorInput.BIT_PICKUP:
		var now := Time.get_ticks_msec()
		GroundWeaponField.pick_up(_pickup_nodes, player, terrain.map_size,
				func(item: WeaponPickup) -> bool: return item.solo_unlock_ms <= now, spawn_pickup)

func spawn_pickup(type_id: int, carried: int, pos: Vector2, vel: Vector2, self_drop := false) -> WeaponPickup:
	var inst := _next_pickup_inst
	_next_pickup_inst += 1
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	# 入树时同步碰撞体，因此位置和武器类型都先设置。
	node.configure(type_id, inst, carried, vel)
	node.time_field = time_field
	node.position = pos
	node.canonical_pos = pos
	# 挂载至 WorldViewport 保证正确进入世界视口渲染
	$WorldViewport.add_child(node)
	_pickup_nodes[inst] = node
	if self_drop:
		node.solo_unlock_ms = Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return node

func clear_pickups() -> void:
	for pickup: WeaponPickup in _pickup_nodes.values():
		pickup.queue_free()
	_pickup_nodes.clear()


func _scatter_weapons() -> void:
	GroundWeaponField.scatter(terrain, _weapon_floors, enabled_weapons, spawn_pickup)


## 时间玩法视效驱动:底片化 ramp ≤200ms、加速压暗 ramp 100ms、透支深度直传
func _tick_time_visuals(delta: float) -> void:
	var rewinding: bool = time_field.is_rewinding()
	_film_t = move_toward(_film_t, 1.0 if rewinding else 0.0, delta / 0.2)
	_haste_t = move_toward(_haste_t, 1.0 if time_field.is_hasting() else 0.0, delta / 0.1)

	# 透支/加速/回溯的音调变形(全局系数;透支越深越尖)
	var depth := time_field.account.loan_depth()
	_post_process.set_time_effects(_film_t, depth, _haste_t)
	var mult := 1.0 + TimeParams.LOAN_PITCH_RANGE * depth
	if time_field.is_hasting():
		mult += 0.12
	elif rewinding:
		mult -= 0.15
	Sfx.pitch_mult = clampf(mult, 0.7, 1.8)
	_sync_time_glows()


# 时间状态高亮：时间加速时高亮玩家与附近敌人，时空回溯时仅高亮不受回溯影响的精英敌人
const GLOW_PLAYER := Color(0.30, 0.62, 1.0)      # 主角:冷白蓝
const GLOW_ENEMY := Color(1.0, 0.94, 0.86)       # 普通敌:暖白
const GLOW_ELITE := Color(1.0, 0.82, 0.06)       # 精英:亮黄(两层叠加 → "极为亮眼")
const GLOW_RADIUS := 1500.0                      # 只给近处敌人上副本(远处的看不见,白花销)

func _world_enemies() -> Array[Node]:
	var viewport: SubViewport = $WorldViewport
	return get_tree().get_nodes_in_group("enemies").filter(func(enemy: Node) -> bool:
		return enemy.get_viewport() == viewport)

func _sync_time_glows() -> void:
	var want := {}
	var haste := time_field.is_hasting()
	var player: Player = $WorldViewport/Player
	if haste:
		want[player] = [GLOW_PLAYER, 1]
	if haste or time_field.is_rewinding():
		for enemy: EnemyBase in _world_enemies():
			if enemy.is_dead:
				continue
			if enemy.has_meta("elite"):
				want[enemy] = [GLOW_ELITE, 2]
			elif haste and GridPathfinder.toroidal_delta_px(player.global_position,
					enemy.global_position, terrain.map_size).length_squared() <= GLOW_RADIUS * GLOW_RADIUS:
				want[enemy] = [GLOW_ENEMY, 1]
	for node in _glows.keys():
		if not is_instance_valid(node) or not want.has(node):
			var glow: TimeGlow = _glows[node]
			if is_instance_valid(glow):
				glow.queue_free()
			_glows.erase(node)
	for node in want:
		if not is_instance_valid(_glows.get(node)):
			var glow := TimeGlow.attach(node, want[node][0], want[node][1])
			if glow != null:
				_glows[node] = glow


## 时间场按键驱动接口。
var _prev_want_rewind := false
var _prev_want_haste := false

func _drive_time(delta: float) -> void:
	var want_rewind := Input.is_action_pressed("rewind")
	var want_haste := Input.is_action_pressed("haste")
	if not time_field.account.can_spend() and ((want_rewind and not _prev_want_rewind) \
			or (want_haste and not _prev_want_haste)):
		Sfx.play("deny")
	_prev_want_rewind = want_rewind
	_prev_want_haste = want_haste
	time_field.update(delta, want_rewind and _rewind.can_rewind(), want_haste)
## 世界回溯步进：录制与回放状态机，以及击败实体的暂时隐藏与恢复
func _tick_rewind(delta: float, was_rewinding: bool) -> void:
	var player: Player = $WorldViewport/Player
	if time_field.is_rewinding():
		if not was_rewinding:
			# 上一个物理帧的地形修改先入账，再进入回放。
			terrain.seal_rewind(_rewind.recorded_seconds())
			_rewind.begin()
		var cursor := _rewind.current_target()
		_rewind.step(delta, player)
		# 倒飞子弹仍可命中不受回溯影响的精英。
		_rewind_elite_hits()
		terrain.rewind_between(_rewind.current_target(), cursor)
	else:
		if was_rewinding:
			terrain.truncate_rewind(_rewind.finish())
		_rewind.record(delta, player, _world_enemies())
		terrain.seal_rewind(_rewind.recorded_seconds())
		terrain.prune_rewind(_rewind.recorded_seconds() - TimeParams.SNAP_SECONDS)

func _update_pickup_prompt() -> void:
	var player := $WorldViewport.get_node_or_null("Player") as Player
	var anchor := player.global_position if player != null else Vector2.ZERO
	var now := Time.get_ticks_msec()
	var size := terrain.map_size
	for pickup: WeaponPickup in _pickup_nodes.values():
		pickup.set_anchor(anchor)
		pickup.sync_render_from_canonical()
		var can := player != null and pickup.solo_unlock_ms <= now \
				and player.weapons.is_type_enabled(pickup.type_id) \
				and GridPathfinder.toroidal_delta_px(anchor, pickup.canonical_pos, size).length() \
						<= PlayerParams.weapon_pickup_radius
		PickupPrompt.show_over(pickup, can)
