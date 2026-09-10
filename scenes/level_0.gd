class_name Level0
extends Node2D

# 运行时破坏支持:瓦片被破坏(变空气)后,由 TileDefs.damage_tile 回调刷新瓦片层 + 重建碰撞。
static var wall_layer: TileMapLayer = null
static var water_layer: TileMapLayer = null
static var surface_texture: Texture2D = null
static var water_surface_layer: Node2D = null
static var _grid_ref: Array[Array] = []
# 建图时的原始(未破坏)网格深拷贝:每局复位用它重铺瓦片/碰撞(不被运行时 damage_tile 污染)。
static var _pristine_grid: Array[Array] = []
# 持久化可破坏层 32px 子格(250×150):摧毁时只清该格 2×2,下帧只重建所在分块。
static var _destructible_sub: Array[Array] = []
# 本帧被摧毁砖所在的分块(Vector2i → true);_process 里逐块重建后清空。
static var _dirty_chunks: Dictionary = {}

# PvP 模式:只建世界(地图/瓦片/碰撞/水),玩家/敌人/相机/后处理由 PvP 场景负责。
static var pvp_mode: bool = false

# ── 安全场景切换:游戏世界(全量碰撞)退役挂起,不再释放 ──
# change_scene_to_file 会在切换时同步 memdelete 当前场景;单机/PvP 游戏世界含数万碰撞体,
# 同步析构偶发原生段错误(实测死亡后回菜单/按 R 重载都会触发)。做法:新场景手动实例化
# 并接管 current_scene,旧世界摘树挂起、永不释放(即「挂起不释放」保活策略;每次退役先
# 释放上一具挂起世界,稳态最多挂一具)。
# 注意:摘树必须回到帧末进行,故本函数先 await 一帧(见函数内注释)。
static var _retired: Node = null   # 挂起的上一具游戏世界(最多一具,新的退役时释放旧的)

static func safe_change_scene(tree: SceneTree, path: String) -> void:
	# 先回到帧末再动树:调用方(按钮按下/R 重载的输入处理)可能正处于旧场景节点发出的
	# 信号调用栈里,立刻摘树会触发 CanvasItem EXIT_TREE 状态错误(headless 实测)。
	await tree.process_frame
	var old: Node = tree.current_scene
	var next: Node = load(path).instantiate()
	tree.root.add_child(next)      # 新场景 _ready 先跑(旧世界仍在树上,静态引用完好)
	tree.current_scene = next      # 接管 current_scene 指针,旧场景不再被 change 流程释放
	if old != null and old != next:
		tree.root.remove_child(old)
		old.visible = false
		if _retired != null and is_instance_valid(_retired):
			_retired.free()        # 释放更早的那一具(此鱼已在树上挂了整局时间,最稳)
		_retired = old

# 根 Window 的输入事件不会自动路由进 SubViewport（WorldViewport），
# 所以 SubViewport 内节点（玩家/枪）的 _unhandled_input 收不到。
# 在根级把未处理输入手动转发进 WorldViewport。
func _unhandled_input(event: InputEvent) -> void:
	$WorldViewport.push_input(event)

func _ready() -> void:
	RenderingServer.set_default_clear_color("b0e5f6")
	CombatFeedback.spawn(self)

	# 临时：从固定地图文件加载（随机生成已注释，两者之后一起删除）
	var grid := WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	_grid_ref = grid
	_pristine_grid = MazeGenerator.copy_grid(grid)
	Level0.wall_layer = $WorldViewport/WallLayer
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)

	var tile_set = _create_wall_tileset()
	var wl: TileMapLayer = $WorldViewport/WallLayer
	wl.tile_set = tile_set
	_paint_maze(wl, grid)
	Level0.water_layer = $WorldViewport/WaterLayer
	Level0.water_surface_layer = $WorldViewport/WaterSurfaceLayer
	Level0.water_layer.tile_set = tile_set
	_paint_water(grid)


	_build_wall_collision.call_deferred(grid)
	if pvp_mode:
		return  # 世界已建;敌人/单玩家放置/后处理交给 PvP 场景
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
	$WorldViewport/Player.weapons.set_enabled_slots(RunOptions.disabled_weapons)   # 开局选项:禁用武器槽生效
	$EnemySpawner.spawn_all.call_deferred(spawns)

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	call_deferred("add_child", pp)
	_build_esc_menu()


func _create_wall_tileset() -> TileSet:
	var ts: int = GameParameters.TILE_SIZE          # 64
	var half: int = ts / 2                          # 32 子格
	var texture: Texture2D = load("res://assets/textures/structure.png")
	var src_img: Image = texture.get_image()
	# 22 块源砖(两行 32×32 + 第3行两块水)→ 最近邻 2× 放大成 64×64
	var bricks: Array[Image] = []
	for i in range(22):
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.blit_rect(src_img, Rect2i((i % 10) * 32, (i / 10) * 32, 32, 32), Vector2i.ZERO)
		img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
		bricks.append(img)
	Level0.surface_texture = ImageTexture.create_from_image(bricks[21])  # 水面单格贴图(供 Sprite)
	# atlas:16 列(形状 0-15)× 22 行(纹理 1-22),空气象限透明
	var atlas_img := Image.create(16 * ts, 22 * ts, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color(0, 0, 0, 0))
	for tex in range(22):
		for shape in range(16):
			var tile := bricks[tex].duplicate()
			for sy in range(2):
				for sx in range(2):
					if (shape & (1 << (sy * 2 + sx))) == 0:
						tile.fill_rect(Rect2i(sx * half, sy * half, half, half), Color(0, 0, 0, 0))
			atlas_img.blit_rect(tile, Rect2i(0, 0, ts, ts), Vector2i(shape * ts, tex * ts))
	var atlas_tex := ImageTexture.create_from_image(atlas_img)
	var tile_set = TileSet.new()
	tile_set.tile_size = Vector2i(ts, ts)
	var atlas = TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(ts, ts)
	atlas.texture = atlas_tex
	tile_set.add_source(atlas)
	# 瓦片坐标 = (形状列, 纹理行);空气(shape 0)含全透明瓦片,铺图时跳过即可
	for shape in range(16):
		for tex in range(22):
			atlas.create_tile(Vector2i(shape, tex))

	return tile_set


func _paint_maze(layer: TileMapLayer, grid: Array[Array]) -> void:
	var source_id = 0
	var cols = grid[0].size()
	var rows = grid.size()

	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var offset_x = tx * cols
			var offset_y = ty * rows
			for y in range(rows):
				var row: Array = grid[y]
				for x in range(cols):
					var v: int = row[x]
					if v == MazeGenerator.EMPTY:
						continue
					if Water.is_liquid(MazeGenerator.texture_of(v)):
						continue  # 水由 _paint_water 分层铺
					# packed → atlas 坐标(形状列, 纹理行)
					layer.set_cell(Vector2i(x + offset_x, y + offset_y), source_id,
							Vector2i(MazeGenerator.shape_of(v), MazeGenerator.texture_of(v) - 1))


# 水格铺图:水体格铺水体瓦片(T理纡 21,atlas 行 20);水面格(上方非 liquid)只放 Sprite 亮线,不铺瓦片(避免双层半透明叠加变深)。
func _paint_water(grid: Array[Array]) -> void:
	const BODY_ROW := 20   # 纹理 21(水体)的 atlas 行
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
					if v == MazeGenerator.EMPTY:
						continue
					if not Water.is_liquid(MazeGenerator.texture_of(v)):
						continue
					var above: int = grid[posmod(y - 1, rows)][x]
					var is_surface := above == 0 or not Water.is_liquid(MazeGenerator.texture_of(above))
					if is_surface:
						# 收集水面格,合批成一个 canvas item(替代 N 个 Sprite,省 draw call,画面不变)
						surface_cells.append({
							"pos": Vector2((x + ox) * ts + ts * 0.5, (y + oy) * ts + ts),
							"phase": (x + ox) * 1.7 + (y + oy) * 2.3,
						})
					else:
						wl.set_cell(Vector2i(x + ox, y + oy), 0,
							Vector2i(MazeGenerator.shape_of(v), BODY_ROW))


	# 合批:一个 canvas item 画所有水面格(替代 N 个 Sprite,省 draw call,画面不变)
	if not surface_cells.is_empty():
		var batch := WaterSurfaceBatch.new()
		batch.setup(surface_cells, Level0.surface_texture, ts)
		surf.call_deferred("add_child", batch)


func _process(_delta: float) -> void:
	if not _dirty_chunks.is_empty():
		# 分帧重建:每帧最多重建 2 块,爆炸同时毁多块时摊到多帧,避免 CPU 尖峰
		const MAX_REBUILD_PER_FRAME := 2
		var processed := 0
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			if processed >= MAX_REBUILD_PER_FRAME:
				_dirty_chunks[ch] = true  # 放回下帧继续
				continue
			CollisionBuilder.rebuild_chunk(_destructible_sub, ch, $WorldViewport)
			processed += 1


# 瓦片被破坏(变空气):清掉 3×3 环面副本对应格 + 持久子格该格 2×2,标记所在块下帧重建。
func _on_tile_destroyed(cell: Vector2i) -> void:
	if wall_layer != null and not _grid_ref.is_empty():
		var cols: int = _grid_ref[0].size()
		var rows: int = _grid_ref.size()
		for ty in range(-1, 2):
			for tx in range(-1, 2):
				wall_layer.set_cell(Vector2i(cell.x + tx * cols, cell.y + ty * rows), -1)
	# 9 环面副本由同一子格生成,只清中心格 2×2 即可;块间互不合并 → 只重建所在块
	if not _destructible_sub.is_empty():
		for qy in range(2):
			for qx in range(2):
				_destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true


# PvP 换局复位:把可破坏砖/碰撞/瓦片全量还原成建图时的原始状态(当前网格重置为基线深拷贝)。
# 服务器每局开赛也做同样复位,双方从同一基线出发 → 不存在"客户端多拆/少拆"的幽灵墙。
# CollisionBuilder 的 build 幂等(同名节点先 free 再建),可安全整体重建。
func reset_destructibles() -> void:
	if _pristine_grid.is_empty():
		return
	var g := MazeGenerator.copy_grid(_pristine_grid)
	MazeGenerator.current_grid = g
	_grid_ref = g
	TileDefs.init_hp(g)
	# 瓦片层整层重铺(清掉 -1 残留,恢复被拆砖的贴图)
	var wl := Level0.wall_layer
	if wl != null:
		_paint_maze(wl, g)
	# 碰撞:可破坏分块 + 永久墙 + 攀爬条整体重建为基线
	_destructible_sub = WorldBuilder.build_sim($WorldViewport, g)


func _build_wall_collision(grid: Array[Array]) -> void:
	# 永久墙 + 可破坏分块 + 攀爬基座条,逻辑迁到 WorldBuilder.build_sim(服务器复用)
	_destructible_sub = WorldBuilder.build_sim($WorldViewport, grid)


# 单人「倒地按 R 重启」:原地复位,不重建世界。
# 旧实现走场景重载(第二份完整世界 + 退役拆旧世界),重启过程在引擎原生层偶发段错误
# (实测表象:重启后蓝屏/地图未加载)。改为在当前 Level0 内复位:可破坏砖/瓦片/碰撞回
# 基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点,从机制上绕开「新建/拆毁大世界」。
# PvP 不走这里(服务器权威管复活)。由 player.gd 倒地 R 调用。
func restart_single() -> void:
	if _pristine_grid.is_empty() or _grid_ref.is_empty():
		return
	var player: CharacterBody2D = $WorldViewport/Player
	# 瓦片/碰撞整层还原为建图基线;顺手清掉本帧的拆砖重建队列(基线已是最新)
	_dirty_chunks.clear()
	reset_destructibles()
	# 清场上动态物:子弹 + 敌人(尸体/坠落物一起清,避免与重刷的敌人并排残留)
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			(e as Node).queue_free()
	# 玩家满血满氧回出生点,姿态/武器复位
	var spawns := MazeGenerator.load_spawns()
	var spawn_cell: Vector2i = spawns.get("player", Vector2i(-1, -1))
	if spawn_cell.x < 0:
		spawn_cell = Vector2i(_grid_ref[0].size() / 2, _grid_ref.size() / 2)
	player.restart_at(spawn_cell)
	# 敌人重刷(与 _ready 同款;deferred 等旧敌 queue_free 先生效,避免同名冲突)
	EnemySpawner.load_types()
	$EnemySpawner.spawn_all.call_deferred(spawns)


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

# 单机 ESC 菜单:呼出=暂停整份模拟,退出=解暂停后回主菜单。
# PauseMenu 自己管暂停与切场景(open() 里 paused=true、go_menu() 首行先解暂停再走
# Level0.safe_change_scene),故本处不需要任何信号接线。
# (PvP 菜单由 pvp_client 自建——PvP 下本方法不会被调,见 _ready 的 pvp_mode 早 return。)
func _build_esc_menu() -> void:
	add_child(PauseMenu.new(false))   # 隐藏待命,自行处理 ui_cancel
