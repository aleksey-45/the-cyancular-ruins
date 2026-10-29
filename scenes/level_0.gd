class_name Level0
extends Node2D

# 地形由 NativeTerrain 统一维护；场景负责装载、时间轴和表现提交。
static var wall_layer: TileMapLayer = null
static var water_layer: TileMapLayer = null
static var surface_texture: Texture2D = null
static var water_surface_layer: Node2D = null
var terrain: NativeTerrain
var _grid_ref: Array[Array]:
	get: return terrain.get_grid_snapshot() if terrain != null else []

# PvP 模式:只建世界(地图/瓦片/碰撞/水),玩家/敌人/相机/后处理由 PvP 场景负责。
static var pvp_mode: bool = false

# 避免一次性同步销毁大量物理与渲染节点引发卡顿或崩溃。
# 场景切换过渡中标志：防止同帧或相近帧重复进入切换逻辑。
static var _switching: bool = false

## 怀表时间系统账户与时间场(单机;PvP 不建 → 时间系统整体旁路)
static var grain_account: GrainAccount = null
static var time_field: TimeField = null
var _rewind: WorldRewind = null   # 世界快照/回放(单机;PvP 不建)
var _prev_time_mode: int = 0      # 上一帧时间场模式(判回溯进入/退出)
var _post_process: PostProcess = null
var _tile_cursor: float = -1.0
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

func _ready() -> void:
	# 清屏背景色与地形图集统一保持一致
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	CombatFeedback.spawn(self)

	var grid := WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	terrain = TileDefs.terrain
	Level0.wall_layer = $WorldViewport/WallLayer

	var tile_set = _create_wall_tileset()
	var wl: TileMapLayer = $WorldViewport/WallLayer
	wl.tile_set = tile_set
	if not pvp_mode:
		_paint_maze(wl)
	Level0.water_layer = $WorldViewport/WaterLayer
	Level0.water_surface_layer = $WorldViewport/WaterSurfaceLayer
	Level0.water_layer.tile_set = _create_water_tileset()
	_paint_water(grid)


	if pvp_mode:
		return  # PvP 基线完成墙体铺图和物理初始化。
	_build_wall_collision.call_deferred(grid)
	EnemySpawner.load_types()
	var spawns := MazeGenerator.current_spawns
	_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
	$WorldViewport/Player.weapons.set_enabled_types(RunOptions.disabled_weapons)   # 开局选项:禁用武器槽生效
	# 单人模式创建颗粒账户和时间场；PvP 的 TimeField.current 为 null，环境倍率为 1。
	grain_account = GrainAccount.new()
	time_field = TimeField.new(grain_account)
	TimeField.current = time_field
	_rewind = WorldRewind.new($WorldViewport)
	terrain.set_rewind_enabled(true)
	# 透支锁定:怀表红闪提示(表针锁定期间两键都取不出颗粒)
	grain_account.loan_locked.connect(func() -> void:
		var w = get_tree().get_first_node_in_group("watch_hud")
		if w != null:
			w.flash_locked())
	_give_starting_weapon($WorldViewport/Player)
	$EnemySpawner.spawn_all.call_deferred(spawns)
	# 单人模式初始武器随机散落于全图，玩家初始空手
	scatter_weapons.call_deferred(_default_weapon_types())

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	_post_process = pp
	call_deferred("add_child", pp)
	_build_pause_menu()

func _exit_tree() -> void:
	if terrain != null: terrain.set_rewind_enabled(false)


# 瓦片图集由 TerrainAtlas 统一构建
func _create_wall_tileset() -> TileSet:
	return TerrainAtlas.make_wall_tileset()

func _create_water_tileset() -> TileSet:
	var ts := GameParameters.TILE_SIZE
	# 水面合批 shader 的采样源(= 水体纹理放大到 ts×ts)
	Level0.surface_texture = ImageTexture.create_from_image(TerrainAtlas.water_brick_image(ts))
	return TerrainAtlas.make_water_tileset(ts)

func _paint_maze(layer: TileMapLayer) -> void:
	# cyrm v4：绘制 16px 子格图层（跳过空气与液体瓦片）
	var source_id = 0
	var subgrid := terrain.get_subgrid_snapshot()
	if subgrid.is_empty(): return
	var sc: int = subgrid[0].size()
	var sr := subgrid.size()
	for y in range(sr):
		var row: Array = subgrid[y]
		for x in range(sc):
			var tex: int = row[x]
			if tex == MapFormat.EMPTY or Water.is_liquid(tex):
				continue
			var atlas := Vector2i((y % 4) * 4 + (x % 4), tex - 1)
			for ty in range(-1, 2):
				for tx in range(-1, 2):
					layer.set_cell(Vector2i(x + tx * sc, y + ty * sr), source_id, atlas)


# 水格铺图:水体格铺水体瓦片(纹理 21,水体专用 64px 图集的 atlas 行 0);水面格(上方非 liquid)只放 Sprite 亮线,不铺瓦片(避免双层半透明叠加变深)。
func _paint_water(grid: Array[Array]) -> void:
	const BODY_ROW := 0   # 水体专用图集只有一行(纹理 21)
	var ts := GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	var wl: TileMapLayer = Level0.water_layer
	var surf: Node2D = Level0.water_surface_layer
	var surface_cells: Array = []
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var ox := tx * cols
			var oy := ty * rows
			for y in range(rows):
				var row: Array = grid[y]
				for x in range(cols):
					var v: int = row[x]
					if v == MapFormat.EMPTY:
						continue
					if not Water.is_liquid(MapFormat.texture_of(v)):
						continue
					var above: int = grid[posmod(y - 1, rows)][x]
					var is_surface := above == 0 or not Water.is_liquid(MapFormat.texture_of(above))
					if is_surface:
						# 收集水面格,合批成一个 canvas item(替代 N 个 Sprite,省 draw call,画面不变)
						surface_cells.append({
							"pos": Vector2((x + ox) * ts + ts * 0.5, (y + oy) * ts + ts),
							"phase": (x + ox) * 1.7 + (y + oy) * 2.3,
						})
					else:
						wl.set_cell(Vector2i(x + ox, y + oy), 0,
							Vector2i(MapFormat.shape_of(v), BODY_ROW))


	# 合批:一个 canvas item 画所有水面格(替代 N 个 Sprite,省 draw call,画面不变)
	if not surface_cells.is_empty():
		var batch := WaterSurfaceBatch.new()
		batch.setup(surface_cells, Level0.surface_texture, ts)
		surf.call_deferred("add_child", batch)

func _process(_delta: float) -> void:
	flush_terrain_visuals()
	# 时间场驱动(单机;先于实体各自的物理帧让模式生效——实体在 _physics_process 里查询)
	if time_field != null and not pvp_mode:
		_drive_time(_delta, Input.is_action_pressed("rewind"), Input.is_action_pressed("haste"))
		_tick_rewind(_delta)
		_tick_time_visuals(_delta)
	_update_pickup_prompt()
	if not pvp_mode: flush_terrain_collision()


# 瓦片被破坏(变空气):清掉 3×3 环面副本对应格 + 持久子格该格 2×2,标记所在块下帧重建。
## 单格写回(瓦片回溯用):网格 + 9 环面副本渲染 + 持久子格 2×2 + 脏块重建标记。
## 回溯期子弹对精英的二次伤害(策划案:「回退造成二次伤害」)——
## 回溯中普通实体冻结/由快照摆位,唯有精英照常存在;倒飞的子弹再次穿过它就再吃一次伤害。
func _rewind_elite_hits() -> void:
	if _rewind == null:
		return
	var elites: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e.has_meta("elite") and not bool(e.get("is_dead")):
			elites.append(e)
	if elites.is_empty():
		return
	for b in _rewind.replay_bullets():
		if not is_instance_valid(b):
			continue
		var dmg := int(b.get("hit_damage"))
		if dmg <= 0:
			continue
		var bp: Vector2 = (b as Node2D).global_position
		for e in elites:
			var ep: Vector2 = (e as Node2D).global_position
			var d := GridPathfinder.toroidal_delta_px(bp, ep,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			if d.length() > 42.0:
				continue
			var hit_ids: Array = b.get_meta("rw_hit_ids", [])
			if hit_ids.has(e.get_instance_id()):
				continue
			hit_ids.append(e.get_instance_id())
			b.set_meta("rw_hit_ids", hit_ids)
			var dir := d.normalized() if not d.is_zero_approx() else Vector2.RIGHT
			e.call("hurt", dmg, dir, float(b.get("hit_impact")))

func _flush_terrain_history() -> void:
	if terrain != null and _rewind != null:
		terrain.seal_rewind(_rewind.recorded_seconds())

func flush_terrain_visuals() -> void:
	if terrain != null: terrain.flush_visuals(Level0.wall_layer)

func reset_destructibles() -> void:
	if terrain == null or terrain.empty(): return
	terrain.reset()
	if Level0.wall_layer != null: _paint_maze(Level0.wall_layer)
	terrain.attach($WorldViewport)

func _build_wall_collision(_grid: Array[Array]) -> void:
	terrain.attach($WorldViewport)

func restart_single() -> void:
	if terrain == null or terrain.empty():
		return
	var player: CharacterBody2D = $WorldViewport/Player
	# 瓦片/碰撞整层还原为建图基线;顺手清掉本帧的破坏瓦片重建队列(基线已是最新)
	reset_destructibles()
	# 重开是新时间线，旧地图的 HP 和实体历史不能带入新开局。
	_rewind = WorldRewind.new($WorldViewport)
	_tile_cursor = -1.0
	# 清场上动态物:子弹 + 敌人(尸体/坠落物一起清,避免与重刷的敌人并排残留)
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			(e as Node).queue_free()
	# 玩家满血满氧回出生点,姿态/武器复位
	var spawns := MazeGenerator.current_spawns
	var spawn_cell: Vector2i = spawns.get("player", Vector2i(-1, -1))
	if spawn_cell.x < 0:
		spawn_cell = Vector2i(_grid_ref[0].size() / 2, _grid_ref.size() / 2)
	player.restart_at(spawn_cell)
	# 敌人重刷(与 _ready 相同机制;deferred 等旧敌 queue_free 先生效,避免同名冲突)
	EnemySpawner.load_types()
	$EnemySpawner.spawn_all.call_deferred(spawns)
	# 单人模式重置：清空背包与地面武器，全量重新散落
	clear_pickups()
	_give_starting_weapon(player)
	scatter_weapons.call_deferred(_default_weapon_types())

func _place_player(_grid: Array[Array], spawn_cell: Vector2i) -> void:
	var player: CharacterBody2D = $WorldViewport/Player
	var ts: int = GameParameters.TILE_SIZE
	var pos := Vector2i(-1, -1)
	if spawn_cell.x >= 0 and spawn_cell.y >= 0:
		pos = spawn_cell
	else:
		# 地图无 # player:固定用左上第一个空格(地图唯一来源)
		for y in range(_grid.size()):
			for x in range(_grid[y].size()):
				if _grid[y][x] == MapFormat.EMPTY:
					pos = Vector2i(x, y)
					break
			if pos.x >= 0:
				break
		if pos.x < 0:
			push_error("No empty cells to place player!")
			return
	player.position = Vector2(pos.x * ts + ts / 2.0, pos.y * ts + ts / 2.0)

# 单机 ESC 菜单:呼出=暂停整份模拟,退出=解暂停后回主菜单。
# PauseMenu 自己管暂停与切场景(open() 里 paused=true、go_menu() 首行先解暂停再走
# Level0.safe_change_scene),故本处不需要任何信号接线。
# (PvP 菜单由 pvp_client 自建——PvP 下本方法不会被调,见 _ready 的 pvp_mode 早 return。)
func _build_pause_menu() -> void:
	add_child(PauseMenu.new(false))   # 隐藏待命,自行处理 ui_cancel


var ground_weapons := GroundWeaponField.new()
var _next_pickup_inst: int = 1
var _pickup_nodes: Dictionary = {}      # inst -> WeaponPickup
var _self_drop_until: Dictionary = {}   # inst -> 允许重新拾取的时间戳（毫秒），防止丢弃后立即误拾取的抖动

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


# 单人模式开局默认装备第一把可用武器
func _give_starting_weapon(p: Node) -> void:
	if p == null or p.weapons == null:
		return
	p.weapons.set_initial_inventory([int(p.weapons.default_type())])


# 单机初始武器清单:每种 2 把,跳过本局被禁的类型。
# (禁用武器不该出现在地图上 —— 与 set_enabled_types 同源:RunOptions.disabled_weapons)
# - 清单来自注册表(json 顺序 = 散落顺序)。加第 7 把枪只改 json,这里一个字不动。
func _default_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not RunOptions.disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out


# 生成地面武器实体，self_drop=true 表示刚被玩家丢弃
func spawn_pickup(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_drop: bool = false) -> WeaponPickup:
	if inst <= 0:
		inst = _next_pickup_inst
		_next_pickup_inst += 1
	else:
		_next_pickup_inst = maxi(_next_pickup_inst, inst + 1)
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	# 先配置属性再加入场景树
	node.configure(type_id, inst, mag, vel)
	# 挂载至 WorldViewport 保证正确进入世界视口渲染
	$WorldViewport.add_child(node)
	node.global_position = pos
	node.canonical_pos = pos   # 权威位置(渲染位置由锚点推出,见 WeaponPickup)
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_pickup_nodes[inst] = node
	if self_drop:
		_self_drop_until[inst] = Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return node

func remove_pickup(inst: int) -> void:
	ground_weapons.remove(inst)
	_self_drop_until.erase(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)

func clear_pickups() -> void:
	for n in _pickup_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()


# 把 types 里每种武器铺到全图开阔地板格上(尽量互相远离)。
func scatter_weapons(types: Array) -> void:
	clear_pickups()
	if terrain.empty():
		return
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var cols := int(ground_weapons.map_size.x / float(GameParameters.TILE_SIZE))
	var rows := int(ground_weapons.map_size.y / float(GameParameters.TILE_SIZE))
	var cells: Array = $EnemySpawner.open_floor_cells(TileDefs.terrain.get_grid_snapshot())
	var want := types.size()
	var picked: Array = GridPathfinder.spread_cells(cells, want, 10, cols, rows)
	# 与 EnemySpawner 的 "spawned N enemies from map" 相同机制:布点数量要能一眼核对
	# (不足时也走这行 —— 小图/密封图有多少铺多少,不报错也不能卡住开局)。
	print("[Level0] 地面武器 %d/%d 件(开阔地板格 %d)" % [picked.size(), want, cells.size()])
	var half := float(GameParameters.TILE_SIZE) * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * float(GameParameters.TILE_SIZE) + Vector2(half, half)
		spawn_pickup(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)


# 拾取判定：优先拾取距离角色最近的地面武器
func try_pickup_for(p: Node2D) -> void:
	if p == null or p.weapons == null:
		return
	var e: Dictionary = ground_weapons.nearest_within(
		p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops())
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped_type: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped_type < 0:
		return   # 被门控前置校验拒绝(禁用武器),地面那件留着
	remove_pickup(inst)
	if dropped_type > 0:
		# 放不下 → 被换下的那把掉在玩家脚下(残弹跟着枪走)
		var d: Dictionary = p.weapons.take_last_dropped()
		spawn_pickup(dropped_type, int(d.get("mag", WeaponInventory.MAG_FULL)),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up))


# 自己刚丢下的枪在冷却期内不参与自己的拾取判定(否则丢完原地按 F 就捡回来)
func _live_self_drops() -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for inst in _self_drop_until.keys():
		if int(_self_drop_until[inst]) > now:
			out.append(inst)
		else:
			_self_drop_until.erase(inst)
	return out


# 凡满足拾取条件的武器均显示按键交互提示
## 时间玩法视效驱动:底片化 ramp ≤200ms、加速压暗 ramp 100ms、透支深度直传
func _tick_time_visuals(delta: float) -> void:
	if _post_process == null or time_field == null:
		return
	var rewinding: bool = time_field.is_rewinding()
	_film_t = move_toward(_film_t, 1.0 if rewinding else 0.0, delta / 0.2)
	_haste_t = move_toward(_haste_t, 1.0 if time_field.is_hasting() else 0.0, delta / 0.1)
	_post_process.set_time_effects(_film_t, time_field.loan_depth(), _haste_t)

	# 透支/加速/回溯的音调变形(全局系数;透支越深越尖)
	var depth := time_field.loan_depth()
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

func _sync_time_glows() -> void:
	if time_field == null:
		return
	var want: Dictionary = {}
	if time_field.is_hasting():
		var pl := get_node_or_null("WorldViewport/Player") as Node2D
		if pl != null:
			want[pl] = [GLOW_PLAYER, 1]
		for e in get_tree().get_nodes_in_group("enemies"):
			if not (e is Node2D) or not is_instance_valid(e) or bool(e.get("is_dead")):
				continue
			if e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]      # 精英不分远近(它是时间场的"例外",要一眼看到)
			elif _near_player(e as Node2D):
				want[e] = [GLOW_ENEMY, 1]
	elif time_field.is_rewinding():
		for e in get_tree().get_nodes_in_group("enemies"):
			if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]
	for k in _glows.keys():
		if not is_instance_valid(k) or not want.has(k):
			var old: TimeGlow = _glows[k]
			if is_instance_valid(old):
				old.queue_free()
			_glows.erase(k)
	for k in want.keys():
		var spec: Array = want[k]
		var g: TimeGlow = _glows.get(k)
		if g == null or not is_instance_valid(g):
			g = TimeGlow.attach(k, spec[0], int(spec[1]))
			if g != null:
				_glows[k] = g
		else:
			g.set_color(spec[0])

func _near_player(n: Node2D) -> bool:
	var pl := get_node_or_null("WorldViewport/Player") as Node2D
	if pl == null:
		return false
	var d := GridPathfinder.toroidal_delta_px(n.global_position, pl.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return d.length() <= GLOW_RADIUS


## 时间场按键驱动接口。
var _prev_want_rewind := false
var _prev_want_haste := false

func _drive_time(delta: float, want_rewind: bool, want_haste: bool) -> void:
	# 锁定或余额耗尽时按下技能按键给出拒绝音效反馈
	if grain_account != null and want_rewind and not _prev_want_rewind and not grain_account.can_spend():
		Sfx.play("deny")
	if grain_account != null and want_haste and not _prev_want_haste and not grain_account.can_spend():
		Sfx.play("deny")
	_prev_want_rewind = want_rewind
	_prev_want_haste = want_haste
	time_field.update(delta, want_rewind, want_haste)
## 世界回溯步进：录制与回放状态机，以及击败实体的暂时隐藏与恢复
func _tick_rewind(delta: float) -> void:
	if _rewind == null:
		return
	var pl := get_node_or_null("WorldViewport/Player")
	var rewinding: bool = time_field != null and time_field.is_rewinding()
	if rewinding and not _rewind.was_rewinding:
		# 最后一个物理帧可能刚扣过 HP，先入账再进入回放。
		_flush_terrain_history()
		_rewind.begin()
		_tile_cursor = _rewind.recorded_seconds()   # 瓦片还原高水位=进入回溯时刻
	elif not rewinding and _rewind.was_rewinding:
		var exit_t: float = _rewind.finish()
		terrain.truncate_rewind(exit_t)
	_rewind.was_rewinding = rewinding
	_prev_time_mode = time_field.mode if time_field != null else 0
	if rewinding:
		WorldRewind.hold_corpses = false
		_rewind.step(delta, pl)
		# 倒飞子弹穿过不受回溯影响的精英敌人时正常结算二次伤害
		_rewind_elite_hits()
		# 瓦片还原:跨过 target 的破坏按 t 降序写回(最新破坏先还,最早的值最后落地)
		if _tile_cursor >= 0.0:
			var target := _rewind.current_target()
			terrain.rewind_between(target, _tile_cursor)
			_tile_cursor = target
	else:
		WorldRewind.hold_corpses = true
		_rewind.record(delta, pl, get_tree().get_nodes_in_group("enemies"),
				get_tree().get_nodes_in_group("bullet"))
		WorldRewind.expire_corpses(get_tree())
		# 瓦片账本:帧末入账本帧拆掉的格;并裁剪超出回溯窗口的旧条目
		_flush_terrain_history()
		terrain.prune_rewind(_rewind.recorded_seconds() - TimeParams.SNAP_SECONDS)

func _update_pickup_prompt() -> void:
	var pl := $WorldViewport.get_node_or_null("Player") as Node2D
	# 地面武器拾取判定与渲染坐标映射到距离本地玩家最近的可视副本
	var anchor: Vector2 = pl.global_position if pl != null else Vector2.ZERO
	for inst in _pickup_nodes:
		var n0 = _pickup_nodes.get(inst, null)
		if n0 != null and is_instance_valid(n0):
			var pk0 := n0 as WeaponPickup
			pk0.set_anchor(anchor)
			pk0.sync_render_from_canonical()
			var e0: Dictionary = ground_weapons.get_entry(int(inst))
			if not e0.is_empty():
				e0["pos"] = pk0.canonical_pos
	var self_drops := _live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in _pickup_nodes:
		var n = _pickup_nodes.get(inst, null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		var can := false
		if pl != null and not self_drops.has(int(inst)):
			if pl.weapons.is_type_enabled(int(pk.type_id)):
				var d := GridPathfinder.toroidal_delta_px(
						pk.canonical_pos, pl.global_position, w, h).length()
				can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
# 网络物理步进前按块完成本批地形碰撞更新。
func flush_terrain_collision() -> void:
	if terrain == null: return
	terrain.flush_collisions()
