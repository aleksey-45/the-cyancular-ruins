class_name Level0
extends Node2D

# 运行时破坏支持:瓦片被破坏(变空气)后,由 TileDefs.damage_tile 回调刷新瓦片层 + 重建碰撞。
static var wall_layer: TileMapLayer = null
static var water_layer: TileMapLayer = null
static var water_surface_layer: TileMapLayer = null
static var _grid_ref: Array[Array] = []
# 持久化可破坏层 32px 子格(250×150):摧毁时只清该格 2×2,下帧只重建所在分块。
static var _destructible_sub: Array[Array] = []
# 本帧被摧毁砖所在的分块(Vector2i → true);_process 里逐块重建后清空。
static var _dirty_chunks: Dictionary = {}

# 根 Window 的输入事件不会自动路由进 SubViewport（WorldViewport），
# 所以 SubViewport 内节点（玩家/枪）的 _unhandled_input 收不到。
# 在根级把未处理输入手动转发进 WorldViewport。
func _unhandled_input(event: InputEvent) -> void:
	$WorldViewport.push_input(event)

func _ready() -> void:
	RenderingServer.set_default_clear_color("bbeeff")

	# 临时：从固定地图文件加载（随机生成已注释，两者之后一起删除）
	var grid = MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	_grid_ref = grid
	Level0.wall_layer = $WorldViewport/WallLayer
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)

	# 地图文件尺寸固定，据此回写环形回绕的像素尺寸
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE

	var tile_set = _create_wall_tileset()
	var wl: TileMapLayer = $WorldViewport/WallLayer
	wl.tile_set = tile_set
	_paint_maze(wl, grid)
	Level0.water_layer = $WorldViewport/WaterLayer
	Level0.water_surface_layer = $WorldViewport/WaterSurfaceLayer
	Level0.water_layer.tile_set = tile_set
	Level0.water_surface_layer.tile_set = tile_set
	_paint_water(grid)
	# 水面起伏 shader:每格正弦上下拉伸(锚底无缝),相位逐格错开;水体层不挂
	var wsm := ShaderMaterial.new()
	wsm.shader = load("res://Scenes/Effects/water_surface.gdshader")
	wsm.set_shader_parameter("amp", GameParameters.water_sway_amp)
	wsm.set_shader_parameter("speed", GameParameters.water_sway_speed)
	Level0.water_surface_layer.material = wsm

	_build_wall_collision(grid)
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
	$EnemySpawner.spawn_all(spawns)

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	add_child(pp)


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


# 水格铺图:所有液体格铺水体蓝底(T理纡 21,atlas 行 20);上方非 liquid 的格额外铺水面亮线(22,行 21)——水面拉伸露出的顶部缝隙被蓝底盖住。
func _paint_water(grid: Array[Array]) -> void:
	const BODY_ROW := 20   # 纹理 21(水体)的 atlas 行
	const SURF_ROW := 21   # 纹理 22(水面)的 atlas 行
	var cols := grid[0].size()
	var rows := grid.size()
	var wl: TileMapLayer = Level0.water_layer
	var sl: TileMapLayer = Level0.water_surface_layer
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
					var target := sl if is_surface else wl
					target.set_cell(Vector2i(x + ox, y + oy), 0,
							Vector2i(MazeGenerator.shape_of(v), SURF_ROW if is_surface else BODY_ROW))


func _process(_delta: float) -> void:
	if not _dirty_chunks.is_empty():
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			# 只重建被摧毁砖所在分块(块内一次贪心 + 9 环面副本),永久墙建一次不动
			CollisionBuilder.rebuild_chunk(_destructible_sub, ch, $WorldViewport)


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


func _build_wall_collision(grid: Array[Array]) -> void:
	# 永久墙(1-14)建一次整图节点;可破坏(15-20)按分块存节点,摧毁时只重建所在块
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false),
			$WorldViewport, "WallCollision")
	_destructible_sub = CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(_destructible_sub, $WorldViewport)
	# 攀爬结构基座薄碰撞条(梯子顶/锁链顶底),供玩家停留/落脚
	CollisionBuilder.build_climb_ledges(grid, $WorldViewport)


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
