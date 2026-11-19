class_name Level0
extends Node2D

const LevelPickupsScript := preload("res://scenes/level/level_pickups.gd")
const LevelWorldPainterScript := preload("res://scenes/level/level_world_painter.gd")
const LevelTimeFxScript := preload("res://scenes/level/level_time_fx.gd")
const LevelPlaytestScript := preload("res://scenes/level/level_playtest.gd")

static var wall_layer: TileMapLayer = null
# 地形剪影层(TerrainViewport 内):与墙层同一份 cells,供后处理的地形受光/斜影当遮挡源。
static var terrain_layer: TileMapLayer = null
static var water_surface_layer: Node2D = null
static var _grid_ref: Array[Array] = []
static var _pristine_grid: Array[Array] = []
static var _pristine_subgrid: Array[Array] = []
static var _pristine_subdesc: Array[Array] = []
static var _desc_row: Dictionary = {}
static var _row_warned := false
static var _destructible_sub: Array[Array] = []
static var _dirty_chunks: Dictionary = {}
# 本局被摧毁过的 16px 子格(Vector2i → true):换局增量复位只还这些格子(全量重铺实测 ~1.4s ⇒ 每局大卡)。
# ★ 只增不减、复位时清空;回溯复原也留在集合里(复位到基线是无害的重复还原)。
static var _damaged_subs: Dictionary = {}

static var pvp_mode: bool = false

# 试玩(编辑器 → 游戏)由编辑器置位;普通单人开局恒 false:玩家空手、敌人静止、Esc 回编辑器。
static var playtest_mode: bool = false
static var playtest_spawn: Vector2i = Vector2i(-1, -1)   # 编辑器点的那一个出生点(格)
static var playtest_restore_map: String = ""            # 进试玩前钉住的地图路径(退出时还回去)

# 图集只随地图变:同一进程里重开/换模式时直接复用,重建一次 ~87ms。
static var _wall_ts_cache: Dictionary = {}


static var _switching: bool = false

static var grain_account: GrainAccount = null
static var time_field: TimeField = null
var _rewind: WorldRewind = null
var _prev_time_mode: int = 0
var _post_process: PostProcess = null
# 背景四层景深的独立视口(纯视觉;不进 WorldViewport ⇒ 不污染遮挡/受光)
var _bg_viewport: SubViewport = null
var _tile_ledger: TileLedger = null
var _tile_pending: Array = []
var _tile_cursor: float = -1.0
var _film_t: float = 0.0
var _haste_t: float = 0.0
# 时间状态高亮(B13):加色副本(见 scenes/effects/time_glow.gd),实体 → TimeGlow
var _glows: Dictionary = {}

# 世界绘制 / 时间视觉 / 试玩三个域模块:host = 本节点,世界状态留在 static 字段与上面的实例账本里。
var _painter := LevelWorldPainterScript.new()
var _time_fx := LevelTimeFxScript.new()
var _playtest := LevelPlaytestScript.new()


static func safe_change_scene(tree: SceneTree, path: String) -> void:
	if _switching:
		return
	_switching = true
	# 先回到帧末再动树:调用方(按钮按下 / R 重载的输入处理)可能正处于旧场景节点发出的信号调用栈里,立刻摘树会触发 CanvasItem EXIT_TREE 状态错误(headless 实测)。
	await tree.process_frame
	var t0 := Time.get_ticks_usec()
	var t := t0
	var old: Node = tree.current_scene
	var next: Node = load(path).instantiate()
	t = _perf_log("load+instantiate", t)
	tree.root.add_child(next)
	t = _perf_log("add_child(next)", t)
	tree.current_scene = next
	if old != null and old != next:
		if OS.get_cmdline_user_args().has("--perf-teardown-detail"):
			_teardown_detail(tree, old)
			_perf_log("总计", t0)
			_switching = false
			return
		tree.root.remove_child(old)
		t = _perf_log("remove_child(old)", t)
		old.visible = false
		if OS.get_cmdline_user_args().has("--perf-reap-sync"):
			old.free()
			t = _perf_log("free() 同步(对照)", t)
		else:
			start_reap(tree, old)
			t = _perf_log("start_reap(旧世界)", t)
	_perf_log("总计", t0)
	_switching = false

const REAP_BUDGET_US := 3000
static var _reap_queue: Array[Node] = []
static var _reaper_driver: Node = null
static var _reap_nodes := 0
static var _reap_frames := 0
static var _reap_us := 0

class _Reaper extends Node:
	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		# ★ 显式开 _process:别指望「脚本定义了 _process 就自动启用」—— 本节点是内部类实例,自动启用走的是脚本方法探测那条路,不显式开就可能一帧都不进(实测:不开时拆除器全程零调用)。
		set_process(true)

	func _process(_delta: float) -> void:
		if Level0.reap_step():
			queue_free()

	func _exit_tree() -> void:
		if Level0._reaper_driver == self:
			Level0._reaper_driver = null

static func start_reap(tree: SceneTree, world: Node) -> void:
	if world == null or not is_instance_valid(world):
		return
	var t0 := Time.get_ticks_usec()
	_collect_preorder(world, _reap_queue)
	_reap_nodes = _reap_queue.size()
	_reap_frames = 0
	_reap_us = Time.get_ticks_usec() - t0
	if _reaper_driver == null or not is_instance_valid(_reaper_driver) \
			or _reaper_driver.is_queued_for_deletion():
		_reaper_driver = _Reaper.new()
		_reaper_driver.name = "WorldReaper"
		tree.root.add_child(_reaper_driver)

static func reap_step() -> bool:
	var deadline := Time.get_ticks_usec() + REAP_BUDGET_US
	while not _reap_queue.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _reap_queue.pop_back()
		if is_instance_valid(n):
			n.free()
	_reap_frames += 1
	if _reap_queue.is_empty():
		if OS.get_cmdline_user_args().has("--perf-switch"):
			print("[perf-switch] reap 完成              %d 节点 / %d 帧 / 收集 %.2f ms" % [
					_reap_nodes, _reap_frames, float(_reap_us) / 1000.0])
		return true
	return false

static func _teardown_detail(tree: SceneTree, old: Node) -> void:
	var total := Time.get_ticks_usec()
	var kids := old.get_children()
	print("[perf-switch] 旧世界 %d 个顶层子节点(逐个 free 计时):" % kids.size())
	for c in kids:
		# ★ 名字/类名必须在 free 之前取:c.free() 之后 c 已失效,再读 c.name 是 use-after-free(实测:整行 print 直接不出现,只留下表头)。
		var nm := str(c.name)
		var cls := c.get_class()
		var s := Time.get_ticks_usec()
		c.free()
		var e := Time.get_ticks_usec()
		print("[perf-switch]   %-22s %-14s %8.2f ms" % [nm, cls, float(e - s) / 1000.0])
	var s2 := Time.get_ticks_usec()
	if old.is_inside_tree():
		tree.root.remove_child(old)
	old.free()
	var husk := float(Time.get_ticks_usec() - s2) / 1000.0
	print("[perf-switch]   空壳 remove+free               %8.2f ms;整具合计 %.2f ms" % [
			husk, float(Time.get_ticks_usec() - total) / 1000.0])


static func _collect_preorder(n: Node, out: Array[Node]) -> void:
	out.append(n)
	for c in n.get_children():
		_collect_preorder(c, out)

# ── 换场耗时打点(诊断用,默认静默)── 打开方式:-- --perf-switch(与 --worker 同规,开关必须落在 -- 之后,见 OS.get_cmdline_user_args()),打一次换场就在 stdout 打四行;配套 tests/harness/menu_autotest.gd 的 -- --autotest-switch(两趟往返,把第 2 次退出也走到)。
static func _perf_log(label: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	if OS.get_cmdline_user_args().has("--perf-switch"):
		print("[perf-switch] %-20s %8.2f ms" % [label, float(now - t0) / 1000.0])
	return now

# 根 Window 的输入事件不会自动路由进 SubViewport(WorldViewport),SubViewport 内节点(玩家/枪)的 _unhandled_input 收不到;在根级把未处理输入手动转发进 WorldViewport。
func _unhandled_input(event: InputEvent) -> void:
	# 试玩:Esc 直接回编辑器(没有暂停菜单 —— 试玩是编辑器的一次性验证,不该弹出「继续/回大厅」)。
	if playtest_mode and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_leave_playtest()
		return
	$WorldViewport.push_input(event)

func _ready() -> void:
	_painter.setup(self, $WorldViewport as SubViewport)
	_time_fx.setup(self)
	_playtest.setup(self)
	LoadingScreen.show_loading("正在构建世界…")
	LoadingScreen.set_progress(0.02, "读取地图…")
	# 清屏色 = 世界的「空气」色。★ 单一来源放在 TerrainAtlas:主菜单背景的底色也读同一个常量,两处不许各写一份。
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	CombatFeedback.spawn(self)

	var grid := WorldBuilder.load_grid()
	LoadingScreen.set_progress(0.10, "初始化砖块…")
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		LoadingScreen.hide_loading()
		return
	_grid_ref = grid
	_pristine_grid = MazeGenerator.copy_grid(grid)
	_pristine_subgrid = []
	_pristine_subdesc = []
	Level0.wall_layer = $WorldViewport/WallLayer
	Level0.terrain_layer = $TerrainViewport/TerrainLayer
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	_pristine_subgrid = MazeGenerator.copy_grid(MazeGenerator.current_subgrid)
	_pristine_subdesc = MazeGenerator.copy_grid(MazeGenerator.current_subdesc)
	_damaged_subs.clear()
	LoadingScreen.set_progress(0.18, "烘焙墙体图集…")

	# 背景四层景深(层 3-6 = 100%/75%/50%/25%,契约见 ParallaxBg):纯视觉、**有相机才建**,
	# 服务器/headless 不建;不进快照/回滚(两端都从同一张地图文件现算)。
	if DisplayServer.get_name() != "headless":
		# ★★ 背景层放**独立 SubViewport**:它的像素不进世界视口的 alpha ⇒ 光照的遮挡/受光看不到背景,
		#   所以**不透明剪影是安全的**(世界视口只剩地形/实体/水)。相机由 ParallaxBg 每帧跟随世界相机。
		var bg_vp := SubViewport.new()
		bg_vp.name = "BgViewport"
		bg_vp.transparent_bg = true
		bg_vp.size = ($WorldViewport as SubViewport).size
		bg_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var bg := ParallaxBg.new()
		bg.name = "ParallaxBg"
		if bg.setup(MapFormat.load_bg_layers(MazeGenerator.map_file_path()), MazeGenerator.map_size(),
				$WorldViewport/Camera2D as Camera2D) > 0:
			bg_vp.add_child(bg)
			add_child(bg_vp)
			_bg_viewport = bg_vp
		else:
			bg_vp.free()

	var built := _create_wall_tileset()
	var wl: TileMapLayer = $WorldViewport/WallLayer
	wl.tile_set = built["tileset"]
	terrain_layer.tile_set = wl.tile_set
	LoadingScreen.set_progress(0.30, "铺设墙体…")
	_paint_maze_copies()
	LoadingScreen.set_progress(0.45, "准备水体…")
	Level0.water_surface_layer = $WorldViewport/WaterSurfaceLayer
	LoadingScreen.set_progress(0.55, "铺设水体…")
	_paint_water_copies(grid)

	LoadingScreen.set_progress(0.65, "构建碰撞…")
	get_tree().paused = true
	_build_world_progressive.call_deferred(grid)
	if pvp_mode:
		return
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	if playtest_mode:
		# 试玩:敌人照常按图生成,但每个生成后立刻冻结(贴图/位置保留,不动、不结算)。
		$EnemySpawner.enemy_spawned.connect(_on_playtest_enemy_spawned)
	var start_cell: Vector2i = spawns.get("player", Vector2i(-1, -1))
	if playtest_mode and playtest_spawn.x >= 0 and playtest_spawn.y >= 0:
		start_cell = playtest_spawn
	_place_player(grid, start_cell)
	# 拾取/丢弃端口:Player 不再向上找 Level0(旧 host_level());未绑定 = 本端不执行,联机只上行走服务器。
	($WorldViewport/Player as Player).bind_pickup_host(self)
	pickups.setup($WorldViewport, $EnemySpawner)
	$WorldViewport/Player.weapons.set_enabled_types(RunOptions.disabled_weapons)
	grain_account = GrainAccount.new()
	time_field = TimeField.new(grain_account)
	TimeField.current = time_field
	_rewind = WorldRewind.new($WorldViewport)
	_tile_ledger = TileLedger.new()
	grain_account.loan_locked.connect(func() -> void:
		var w = get_tree().get_first_node_in_group("watch_hud")
		if w != null and w.has_method("flash_locked"):
			w.flash_locked())
	if not playtest_mode:
		_give_starting_weapon($WorldViewport/Player)
	$EnemySpawner.spawn_all.call_deferred(spawns)
	if not playtest_mode:
		# 单机初始武器:每种 2 把、共 12 把,随机散落全图;玩家开局空手(见 player.gd)。★ deferred:scatter_weapons 要读 MazeGenerator.current_grid,延迟到帧末避半初始化状态。
		scatter_weapons.call_deferred(_default_weapon_types())

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	pp.bg_viewport = _bg_viewport
	_post_process = pp
	add_child.call_deferred(pp)
	if playtest_mode:
		_build_playtest_banner()
	else:
		_build_pause_menu()


# 墙体/所有非空气砖的图集(16px 象限制,按描述符行烘:行 = 本图去重描述符,辅码颜色烘进像素)。
# 构造在 TerrainAtlas —— 主菜单背景要「真实的那个世界」,必须与这里用同一份映射(见 terrain_atlas.gd 文件头)。
func _create_wall_tileset() -> Dictionary:
	return _painter.create_wall_tileset()


static func _desc_or_neutral(sd: Array, y: int, x: int, tex: int) -> int:
	if y < sd.size():
		var drow: Array = sd[y]
		if x < drow.size() and int(drow[x]) != 0:
			return int(drow[x])
	return MapFormatV4.neutral_descriptor(tex)


static func _wall_row(desc: int) -> int:
	if not _desc_row.has(desc) and not _row_warned:
		_row_warned = true
		push_warning("Level0: 描述符 0x%X 不在墙体图集行表,回落中性行" % desc)
	return TerrainAtlas.fallback_row(_desc_row, desc)


static func _water_desc_of(v: int, x: int, y: int) -> int:
	var fallback := MapFormatV4.neutral_descriptor(MazeGenerator.texture_of(v))
	var sd := MazeGenerator.current_subdesc
	if sd.is_empty():
		return fallback
	var counts := {}
	for sy in 4:
		var yy := y * 4 + sy
		if yy >= sd.size():
			continue
		var drow: Array = sd[yy]
		for sx in 4:
			var xx := x * 4 + sx
			if xx >= drow.size():
				continue
			var d := int(drow[xx])
			if d != 0:
				counts[d] = int(counts.get(d, 0)) + 1
	var best := 0
	var best_n := 0
	for d in counts:
		var nn := int(counts[d])
		if nn > best_n or (nn == best_n and d < best):
			best = d
			best_n = nn
	return best if best != 0 else fallback


static var _paint_cache: Dictionary = {}


func _paint_maze_copies() -> void:
	_painter.paint_maze_copies()


func _paint_water_copies(grid: Array[Array]) -> void:
	_painter.paint_water_copies(grid)



func _build_world_progressive(grid: Array[Array]) -> void:
	await _painter.build_world_progressive(grid)


func _process(_delta: float) -> void:
	# 时间场驱动(单机;先于实体各自的物理帧让模式生效——实体在 _physics_process 里查询)
	if time_field != null and not pvp_mode:
		_drive_time(_delta, Input.is_action_pressed("rewind"), Input.is_action_pressed("haste"))
		_tick_rewind(_delta)
		_tick_time_visuals(_delta)
	_update_pickup_prompt()
	if not _dirty_chunks.is_empty():
		const MAX_REBUILD_PER_FRAME := 2
		var processed := 0
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			if processed >= MAX_REBUILD_PER_FRAME:
				_dirty_chunks[ch] = true
				continue
			CollisionBuilder.rebuild_chunk(_destructible_sub, ch, $WorldViewport)
			processed += 1


func _rewind_elite_hits() -> void:
	_painter.rewind_elite_hits()


func _restore_sub(e: Dictionary) -> void:
	_painter.restore_sub(e)


func _on_tile_destroyed(cell: Vector2i) -> void:
	_painter.on_tile_destroyed(cell)


func _on_sub_destroyed(sub: Vector2i, pre_hp: int, _owner: Node = null) -> void:
	_painter.on_sub_destroyed(sub, pre_hp, _owner)


# PvP 换局复位(增量,2026-10-24):只还原「被拆过的 16px 子格」—— 全量重铺 9 环面副本实测 ~0.86s、整层碰撞重建 ~0.48s
func reset_destructibles() -> void:
	_painter.reset_destructibles()


# 单人「倒地按 R 重启」:原地复位,不重建世界。
# 旧实现走场景重载(第二份完整世界 + 退役拆旧世界),重启过程在引擎原生层偶发段错误;改为在当前 Level0 内复位:可破坏砖/瓦片/碰撞回基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点,从机制上绕开「新建/拆毁大世界」。PvP 不走这里(服务器权威管复活);由 player.gd 倒地 R 调用。
func restart_single() -> void:
	if _pristine_grid.is_empty() or _grid_ref.is_empty():
		return
	var player: CharacterBody2D = $WorldViewport/Player
	_dirty_chunks.clear()
	reset_destructibles()
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			(e as Node).queue_free()
	var spawns := MazeGenerator.load_spawns()
	var spawn_cell: Vector2i = spawns.get("player", Vector2i(-1, -1))
	if playtest_mode and playtest_spawn.x >= 0 and playtest_spawn.y >= 0:
		spawn_cell = playtest_spawn
	if spawn_cell.x < 0:
		spawn_cell = Vector2i(_grid_ref[0].size() / 2, _grid_ref.size() / 2)
	player.restart_at(spawn_cell)
	EnemySpawner.load_types()
	$EnemySpawner.spawn_all.call_deferred(spawns)
	clear_pickups()
	if not playtest_mode:
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
				if _grid[y][x] == MazeGenerator.EMPTY:
					pos = Vector2i(x, y)
					break
			if pos.x >= 0:
				break
		if pos.x < 0:
			push_error("No empty cells to place player!")
			return
	player.position = Vector2(pos.x * ts + ts / 2.0, pos.y * ts + ts / 2.0)

func _build_pause_menu() -> void:
	var pm := preload("res://ui/screens/pause_menu.tscn").instantiate() as PauseMenu
	pm.is_pvp = false
	add_child(pm)


# ── 试玩(编辑器 → 游戏)────────────────────────────────────────────────
# 只由 scenes/editor 置 playtest_mode。三条差异:敌人静止、玩家空手、Esc 回编辑器。

# 敌人一生成就定格:停物理帧 + 停动画首帧(位置/碰撞箱原样保留,「鸟会不会挡路/贴图多大」仍看得见)。
func _on_playtest_enemy_spawned(enemy: Node) -> void:
	_playtest.on_enemy_spawned(enemy)


func _build_playtest_banner() -> void:
	_playtest.build_playtest_banner()


func _leave_playtest() -> void:
	_playtest.leave_playtest()


var pickups := LevelPickupsScript.new()


func _give_starting_weapon(p: Node) -> void:
	if p == null or p.weapons == null:
		return
	p.weapons.set_initial_inventory([int(p.weapons.default_type())])


# 单机初始武器清单:每种 2 把,跳过本局被禁的类型(禁用武器不该出现在地图上 —— 与 set_enabled_types 同源:RunOptions.disabled_weapons)。
func _default_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not RunOptions.disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out


func spawn_pickup(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_drop: bool = false) -> WeaponPickup:
	return pickups.spawn(type_id, mag, pos, vel, inst, self_drop)


func remove_pickup(inst: int) -> void:
	pickups.remove(inst)


func clear_pickups() -> void:
	pickups.clear()


func scatter_weapons(types: Array) -> void:
	pickups.scatter(types)


func try_pickup_for(p: Node2D) -> void:
	pickups.try_pickup_for(p)


func _tick_time_visuals(delta: float) -> void:
	_time_fx.tick_time_visuals(delta)


var _prev_want_rewind := false
var _prev_want_haste := false


func _drive_time(delta: float, want_rewind: bool, want_haste: bool) -> void:
	_time_fx.drive_time(delta, want_rewind, want_haste)


func _tick_rewind(delta: float) -> void:
	_time_fx.tick_rewind(delta)


func _update_pickup_prompt() -> void:
	var pl := $WorldViewport.get_node_or_null("Player") as Node2D
	var anchor: Vector2 = pl.global_position if pl != null else Vector2.ZERO
	var nodes := pickups.nodes()
	for inst in nodes:
		var n0 = nodes.get(inst, null)
		if n0 != null and is_instance_valid(n0):
			var pk0 := n0 as WeaponPickup
			pk0.set_anchor(anchor)
			pk0.sync_render_from_canonical()
			var e0: Dictionary = pickups.entry(int(inst))
			if not e0.is_empty():
				e0["pos"] = pk0.canonical_pos
	var self_drops := pickups.live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in nodes:
		var n = nodes.get(inst, null)
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
