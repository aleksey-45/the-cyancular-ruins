class_name Level0
extends Node2D

const LevelPickupsScript := preload("res://scenes/level/level_pickups.gd")

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
	var key := MazeGenerator.map_file_path()
	var built: Dictionary = _wall_ts_cache.get(key, {})
	if built.is_empty():
		built = TerrainAtlas.make_wall_tileset_for(_collect_wall_descs())
		_wall_ts_cache[key] = built
	_desc_row = built["row_of"]
	return built


func _collect_wall_descs() -> Array:
	var uniq := {}
	var sd := MazeGenerator.current_subdesc
	if sd.is_empty():
		for row in MazeGenerator.current_subgrid:
			for t in row:
				if int(t) != 0:
					uniq[MapFormatV4.neutral_descriptor(int(t))] = true
	else:
		for row in sd:
			for d in row:
				if int(d) != 0:
					uniq[int(d)] = true
	var out: Array = uniq.keys()
	out.sort()
	return out


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


func _ring_copies() -> Array:
	var out: Array = []
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			out.append(Vector2i(tx, ty))
	return out


static var _paint_cache: Dictionary = {}

func _paint_cache_for_current_map() -> Dictionary:
	var key := MazeGenerator.map_file_path()
	var hit: Dictionary = _paint_cache.get(key, {})
	if not hit.is_empty():
		return hit
	var sg := MazeGenerator.current_subgrid
	var sd := MazeGenerator.current_subdesc
	var sc: int = sg[0].size()
	var sr: int = sg.size()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	xs.resize(sc * sr)
	ys.resize(sc * sr)
	var rows := PackedByteArray()
	rows.resize(sr)
	for y in sr:
		var row: Array = sg[y]
		var base := y * sc
		var any := false
		for x in sc:
			var tex: int = row[x]
			if tex == MazeGenerator.EMPTY or Water.is_liquid(tex):
				xs[base + x] = -1
				continue
			any = true
			xs[base + x] = (y % 4) * 4 + (x % 4)
			ys[base + x] = _wall_row(_desc_or_neutral(sd, y, x, tex))
		rows[y] = 1 if any else 0
	var out := {"x": xs, "y": ys, "rows": rows, "sc": sc, "sr": sr}
	_paint_cache[key] = out
	return out


# 只画真正可能出现在视口里的环带:视口 2208x1728 远小于地图,整圈 9 份全画是 5~6 倍浪费
# (贴图 24 万格 -> 4 万级;碰撞环带不在此列,见 CollisionBuilder)。中心份全画,其余按"该副本在源图里的可见条带"画。
const RING_VIEW_MARGIN_SUB := 8

func _ring_visible_sub_rects() -> Array:
	var sc: int = MazeGenerator.current_subgrid[0].size()
	var sr: int = MazeGenerator.current_subgrid.size()
	var zoom := maxf(0.01, PlayerParams.cam_zoom)
	var wsub := mini(sc, ceili(float(($WorldViewport as SubViewport).size.x) / (16.0 * zoom)) + RING_VIEW_MARGIN_SUB * 2)
	var hsub := mini(sr, ceili(float(($WorldViewport as SubViewport).size.y) / (16.0 * zoom)) + RING_VIEW_MARGIN_SUB * 2)
	var out: Array = []
	for c: Vector2i in _ring_copies():
		var x0 := 0
		var y0 := 0
		var x1 := sc
		var y1 := sr
		if c.x < 0:
			x0 = maxi(0, sc - wsub)
		elif c.x > 0:
			x1 = mini(sc, wsub)
		if c.y < 0:
			y0 = maxi(0, sr - hsub)
		elif c.y > 0:
			y1 = mini(sr, hsub)
		out.append([c, x0, y0, x1, y1])
	return out


# ★ 墙层与地形剪影层的唯一写点:漏镜像不会报错,只会让实体重新被地形受光/斜影误伤。
static func _set_wall_cell(cell: Vector2i, atlas: Vector2i) -> void:
	if wall_layer != null:
		wall_layer.set_cell(cell, 0, atlas)
	if terrain_layer != null:
		terrain_layer.set_cell(cell, 0, atlas)


static func _erase_wall_cell(cell: Vector2i) -> void:
	if wall_layer != null:
		wall_layer.set_cell(cell, -1)
	if terrain_layer != null:
		terrain_layer.set_cell(cell, -1)


func _paint_maze_copies() -> void:
	var cache := _paint_cache_for_current_map()
	var xs: PackedInt32Array = cache["x"]
	var ys: PackedInt32Array = cache["y"]
	var row_any: PackedByteArray = cache["rows"]
	var sc: int = cache["sc"]
	var sr: int = cache["sr"]
	for entry in _ring_visible_sub_rects():
		var c: Vector2i = entry[0]
		var x0: int = entry[1]
		var y0: int = entry[2]
		var x1: int = entry[3]
		var y1: int = entry[4]
		var offset_x = c.x * sc
		var offset_y = c.y * sr
		for y in range(y0, y1):
			if row_any[y] == 0:
				continue
			var base := y * sc
			var oy: int = y + offset_y
			for x in range(x0, x1):
				var tx := xs[base + x]
				if tx < 0:
					continue
				_set_wall_cell(Vector2i(x + offset_x, oy), Vector2i(tx, ys[base + x]))


func _paint_water_copies(grid: Array[Array]) -> void:
	var ts := GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	var surf: Node2D = Level0.water_surface_layer
	var surface_by_desc: Dictionary = {}   # 描述符 → 该描述符下的所有液体格
	var wzoom := maxf(0.01, PlayerParams.cam_zoom)
	var x_limit := mini(cols, ceili(float(($WorldViewport as SubViewport).size.x) / (float(ts) * wzoom)) + RING_VIEW_MARGIN_SUB / 4 + 1)
	var y_limit := mini(rows, ceili(float(($WorldViewport as SubViewport).size.y) / (float(ts) * wzoom)) + RING_VIEW_MARGIN_SUB / 4 + 1)
	for entry in _ring_visible_sub_rects():
		var c: Vector2i = entry[0]
		var x0: int = entry[1] / 4
		var y0: int = entry[2] / 4
		var x1: int = mini(cols, ceili(float(entry[3]) / 4.0))
		var y1: int = mini(rows, ceili(float(entry[4]) / 4.0))
		if c.x < 0:
			x0 = maxi(x0, cols - x_limit)
		elif c.x > 0:
			x1 = mini(x1, x_limit)
		if c.y < 0:
			y0 = maxi(y0, rows - y_limit)
		elif c.y > 0:
			y1 = mini(y1, y_limit)
		var ox := c.x * cols
		var oy := c.y * rows
		for y in range(y0, y1):
			var row: Array = grid[y]
			for x in range(x0, x1):
				var v: int = row[x]
				if v == MazeGenerator.EMPTY:
					continue
				if not Water.is_liquid(MazeGenerator.texture_of(v)):
					continue
				# ★ 所有液体格都进**同一条管线**(合批):水面砖 / 水体砖只是图集里不同的 UV 行,
				#   同色、同 alpha、同条纹、同起伏 —— 不存在"两层对不齐"的接缝。
				var above: int = grid[posmod(y - 1, rows)][x]
				var is_surface := above == 0 or not Water.is_liquid(MazeGenerator.texture_of(above))
				var d: int = _water_desc_of(v, x, y)
				if not surface_by_desc.has(d):
					surface_by_desc[d] = []
				(surface_by_desc[d] as Array).append({
					"pos": Vector2((x + ox) * ts + ts * 0.5, (y + oy) * ts + ts),
					"phase": (x + ox) * 1.7 + (y + oy) * 2.3,
					"surface": is_surface,
					"weight": 1.0 if is_surface else 0.0,   # ★ 只有水面格起伏
				})

	# ★ 按**描述符分桶**:每桶用自己的 tint 砖。水面若恒用中性砖,而水体按辅码 tint 过,
	#   两层就会有色差(registered-debt 里那条"水面合批不消费辅码")。
	for d in surface_by_desc:
		var cells: Array = surface_by_desc[d]
		if cells.is_empty():
			continue
		var tex := ImageTexture.create_from_image(_make_water_atlas(ts, int(d)))
		var batch := WaterSurfaceBatch.new()
		batch.setup(cells, tex, ts)
		surf.add_child.call_deferred(batch)



const BOOT_BUDGET_US := 8000

func _build_world_progressive(grid: Array[Array]) -> void:
	var t := Time.get_ticks_usec()
	LoadingScreen.set_progress(0.68, "碰撞:永久墙")
	var perm := CollisionBuilder.build_sub(grid, false)
	CollisionBuilder.build_permanent(perm, $WorldViewport, "WallCollision")
	await get_tree().process_frame
	t = Time.get_ticks_usec()
	LoadingScreen.set_progress(0.72, "碰撞:可破坏层")
	var sub := CollisionBuilder.build_sub(grid, true)
	var cw := ceili(sub[0].size() / float(CollisionBuilder.CHUNK_CELLS * 4))
	var ch := ceili(sub.size() / float(CollisionBuilder.CHUNK_CELLS * 4))
	var total := cw * ch
	var n := 0
	for chy in ch:
		for chx in cw:
			CollisionBuilder.rebuild_chunk(sub, Vector2i(chx, chy), $WorldViewport)
			n += 1
			LoadingScreen.set_progress(0.72 + 0.26 * float(n) / float(maxi(total, 1)),
					"碰撞块 %d/%d" % [n, total])
			if Time.get_ticks_usec() - t >= BOOT_BUDGET_US:
				await get_tree().process_frame
				t = Time.get_ticks_usec()
	CollisionBuilder.build_climb_ledges(grid, $WorldViewport)
	_destructible_sub = sub
	LoadingScreen.set_progress(1.0, "完成")
	await get_tree().process_frame
	get_tree().paused = false
	await get_tree().process_frame
	LoadingScreen.hide_loading()


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
			var d := MazeGenerator.toroidal_delta_px(bp, ep,
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


func _restore_sub(e: Dictionary) -> void:
	if _grid_ref.is_empty() or wall_layer == null or MazeGenerator.current_subgrid.is_empty():
		return
	var sub: Vector2i = e["sub"]
	var hp := int(e["hp"])
	var sc: int = MazeGenerator.current_subgrid[0].size()
	var sr: int = MazeGenerator.current_subgrid.size()
	if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
		return
	TileDefs.restore_sub(sub, hp)
	var tex := int(MazeGenerator.current_subgrid[sub.y][sub.x])
	var cell := Vector2i(sub.x / 4, sub.y / 4)
	if tex == 0:
		return
	var atlas_row := _wall_row(_desc_or_neutral(MazeGenerator.current_subdesc, sub.y, sub.x, tex))
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			_set_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr),
					Vector2i((sub.y % 4) * 4 + (sub.x % 4), atlas_row))
	if not _destructible_sub.is_empty():
		_destructible_sub[sub.y][sub.x] = MazeGenerator.SOLID
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	if _grid_ref[cell.y][cell.x] == 0 and not _pristine_grid.is_empty():
		_grid_ref[cell.y][cell.x] = _pristine_grid[cell.y][cell.x]
		if TileDefs.hp_grid_at(cell) <= 0:
			TileDefs.set_hp_grid(cell, TileDefs.hp_of(tex))


func _on_tile_destroyed(cell: Vector2i) -> void:
	TileDefs.destroy_cell(cell)


func _on_sub_destroyed(sub: Vector2i, pre_hp: int, _owner: Node = null) -> void:
	_damaged_subs[sub] = true
	if _tile_ledger != null and TimeField.current != null and not TimeField.current.is_rewinding() and wall_layer != null:
		_tile_pending.append({"sub": sub, "hp": pre_hp})
	if wall_layer != null:
		var sc: int = MazeGenerator.current_subgrid[0].size()
		var sr: int = MazeGenerator.current_subgrid.size()
		for ty in range(-1, 2):
			for tx in range(-1, 2):
				_erase_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr))
	if not _destructible_sub.is_empty():
		_destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true


# PvP 换局复位(增量,2026-10-24):只还原「被拆过的 16px 子格」—— 全量重铺 9 环面副本实测 ~0.86s、整层碰撞重建 ~0.48s
func reset_destructibles() -> void:
	if _pristine_grid.is_empty() or _pristine_subgrid.is_empty():
		return
	var sc: int = (_pristine_subgrid[0] as Array).size()
	var sr: int = _pristine_subgrid.size()
	var subs: Dictionary = _damaged_subs.duplicate()
	var grid := MazeGenerator.current_grid
	for cy in grid.size():
		var row: Array = grid[cy]
		var prow: Array = _pristine_grid[cy]
		for cx in row.size():
			if row[cx] == prow[cx]:
				continue
			row[cx] = prow[cx]
			for sy in 4:
				for sx in 4:
					subs[Vector2i(cx * 4 + sx, cy * 4 + sy)] = true
	var chunks: Dictionary = {}
	var cells: Dictionary = {}
	for key in subs:
		var sub: Vector2i = key
		if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
			continue
		var tex: int = int(_pristine_subgrid[sub.y][sub.x])
		TileDefs.restore_sub(sub, TileDefs.hp_of(tex) if tex != 0 else 0)
		if not _destructible_sub.is_empty():
			_destructible_sub[sub.y][sub.x] = CollisionBuilder.destructible_value(tex)
		if tex != 0:
			var atlas := Vector2i((sub.y % 4) * 4 + (sub.x % 4),
					_wall_row(_desc_or_neutral(_pristine_subdesc, sub.y, sub.x, tex)))
			for ty in range(-1, 2):
				for tx in range(-1, 2):
					_set_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr), atlas)
		var cell := Vector2i(sub.x / 4, sub.y / 4)
		chunks[CollisionBuilder.chunk_of(cell)] = true
		cells[cell] = true
	for cell in cells:
		TileDefs.set_hp_grid(cell, TileDefs.hp_of(MazeGenerator.texture_of(int(_pristine_grid[cell.y][cell.x]))))
	for ch in chunks:
		CollisionBuilder.rebuild_chunk(_destructible_sub, ch, $WorldViewport)
	_dirty_chunks.clear()
	_damaged_subs.clear()


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
	if not is_instance_valid(enemy):
		return
	enemy.set_physics_process(false)
	var spr := enemy.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
	if spr != null:
		spr.stop()
		spr.frame = 0


func _build_playtest_banner() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlaytestBanner"
	layer.layer = 150
	add_child(layer)
	var panel := PanelContainer.new()
	panel.name = "Banner"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# 让开顶部居中的 HUD 时钟:横幅下移一行,两段文字不叠。
	panel.offset_top = float(UiFactory.MARGIN + UiFactory.SP_7)
	UiFactory.hud_plate(panel, UiFactory.SP_4, UiFactory.SP_2, true, UiFactory.C_PLATE_DEEP)
	layer.add_child(panel)
	var label := Label.new()
	label.text = "试玩 · 敌人静止 / 空手 · Esc 返回编辑器"
	UiFactory.style_control(label, UiFactory.T_BODY)
	label.add_theme_color_override("font_color", UiFactory.C_TEXT)
	panel.add_child(label)


func _leave_playtest() -> void:
	if not playtest_mode:
		return
	playtest_mode = false
	MazeGenerator.set_map_file(playtest_restore_map)   # 不让临时图泄漏到之后的开局
	safe_change_scene(get_tree(), "res://scenes/editor/editor_root.tscn")


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
	if _post_process == null or time_field == null:
		return
	var rewinding: bool = time_field.is_rewinding()
	_film_t = move_toward(_film_t, 1.0 if rewinding else 0.0, delta / 0.2)
	_haste_t = move_toward(_haste_t, 1.0 if time_field.is_hasting() else 0.0, delta / 0.1)
	_post_process.set_time_effects(_film_t, time_field.loan_depth(), _haste_t)

	var depth := time_field.loan_depth()
	var mult := 1.0 + TimeParams.LOAN_PITCH_RANGE * depth
	if time_field.is_hasting():
		mult += 0.12
	elif rewinding:
		mult -= 0.15
	Sfx.pitch_mult = clampf(mult, 0.7, 1.8)
	_sync_time_glows()


const GLOW_PLAYER := Color(0.30, 0.62, 1.0)
const GLOW_ENEMY := Color(1.0, 0.94, 0.86)
const GLOW_ELITE := Color(1.0, 0.82, 0.06)
const GLOW_RADIUS := 1500.0

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
				want[e] = [GLOW_ELITE, 2]
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
	var d := MazeGenerator.toroidal_delta_px(n.global_position, pl.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return d.length() <= GLOW_RADIUS


var _prev_want_rewind := false
var _prev_want_haste := false


func _drive_time(delta: float, want_rewind: bool, want_haste: bool) -> void:
	if grain_account != null and want_rewind and not _prev_want_rewind and not grain_account.can_spend():
		Sfx.play("deny")
	if grain_account != null and want_haste and not _prev_want_haste and not grain_account.can_spend():
		Sfx.play("deny")
	_prev_want_rewind = want_rewind
	_prev_want_haste = want_haste
	time_field.update(delta, want_rewind, want_haste)


func _tick_rewind(delta: float) -> void:
	if _rewind == null:
		return
	var pl := get_node_or_null("WorldViewport/Player")
	var rewinding: bool = time_field != null and time_field.is_rewinding()
	if rewinding and not _rewind.was_rewinding:
		_rewind.begin()
		_tile_cursor = _rewind.recorded_seconds()
	elif not rewinding and _rewind.was_rewinding:
		var exit_t: float = _rewind.finish()
		if _tile_ledger != null:
			_tile_ledger.prune_after(exit_t)
	_rewind.was_rewinding = rewinding
	_prev_time_mode = time_field.mode if time_field != null else 0
	if rewinding:
		WorldRewind.hold_corpses = false
		_rewind.step(delta, pl)
		_rewind_elite_hits()
		if _tile_ledger != null and _tile_cursor >= 0.0:
			var target := _rewind.current_target()
			for e in _tile_ledger.take_range(target, _tile_cursor):
				for c in e["cells"]:
					_restore_sub(c)
			_tile_cursor = target
	else:
		WorldRewind.hold_corpses = true
		_rewind.record(delta, pl, get_tree().get_nodes_in_group("enemies"),
				get_tree().get_nodes_in_group("bullet"))
		WorldRewind.expire_corpses(get_tree())
		if _tile_ledger != null:
			if not _tile_pending.is_empty():
				_tile_ledger.record(_rewind.recorded_seconds(), _tile_pending)
				_tile_pending = []
			_tile_ledger.prune(_rewind.recorded_seconds() - TimeParams.SNAP_SECONDS)


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

## 被合批用的两行图集:上半 = 水体砖,下半 = 水面砖,都按描述符 tint。
func _make_water_atlas(ts: int, desc: int) -> Image:
	var img := Image.create(ts, ts * 2, false, Image.FORMAT_RGBA8)
	img.blit_rect(TerrainAtlas._tinted_water_brick(ts, desc), Rect2i(0, 0, ts, ts), Vector2i(0, 0))
	# 下半行 = **水面砖**(自带顶边水线),按同一描述符 tint:
	#   水面格用它,水线本来就画在贴图里,不需要后处理再画。
	var surf := TerrainAtlas.water_brick_image(ts, TerrainAtlas.WATER_SURFACE_BRICK).duplicate()
	for yy in ts:
		for xx in ts:
			surf.set_pixel(xx, yy, TerrainAtlas.tint_color(surf.get_pixel(xx, yy), desc))
	img.blit_rect(surf, Rect2i(0, 0, ts, ts), Vector2i(0, ts))
	return img
