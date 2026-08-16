extends Node2D

const WALL_COLOR: Color = Color("54778d")

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

	# 地图文件尺寸固定，据此回写环形回绕的像素尺寸
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE

	var tile_set = _create_wall_tileset()
	var wall_layer: TileMapLayer = $WorldViewport/WallLayer
	wall_layer.tile_set = tile_set
	_paint_maze(wall_layer, grid)

	_build_wall_collision(grid)
	_place_player(grid)
	$EnemySpawner.spawn_all(grid, $WorldViewport/Player.global_position)

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	add_child(pp)


func _create_wall_tileset() -> TileSet:
	var ts: int = GameParameters.TILE_SIZE
	var image = Image.create(ts * 2, ts, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(ts, 0, ts, ts), WALL_COLOR)

	var texture = ImageTexture.create_from_image(image)

	var tile_set = TileSet.new()
	tile_set.tile_size = Vector2i(ts, ts)

	var atlas = TileSetAtlasSource.new()
	atlas.texture_region_size = Vector2i(ts, ts)
	atlas.texture = texture
	tile_set.add_source(atlas)
	atlas.create_tile(Vector2i(0, 0))
	atlas.create_tile(Vector2i(1, 0))

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
					if row[x] != MazeGenerator.SOLID:
						continue
					layer.set_cell(Vector2i(x + offset_x, y + offset_y), source_id, Vector2i(1, 0))


func _build_wall_collision(grid: Array[Array]) -> void:
	var walls = StaticBody2D.new()
	walls.name = "WallCollision"
	$WorldViewport.add_child(walls)

	var cols = grid[0].size()
	var rows = grid.size()
	var ts: int = GameParameters.TILE_SIZE

	# 把连续墙格合并成少数几个大矩形碰撞体（每行扫一遍,把相邻墙段并成一个矩形）。
	# 需覆盖环面 3×3 展开区域,玩家/子弹/敌人才能跨接缝;否则节点数是格子数×9。
	var total_shapes := 0
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var offset_x = tx * cols * ts
			var offset_y = ty * rows * ts
			for y in range(rows):
				var row: Array = grid[y]
				var x := 0
				while x < cols:
					if row[x] != MazeGenerator.SOLID:
						x += 1
						continue
					# 找到从 x 起连续墙段的右端
					var seg_end := x + 1
					while seg_end < cols and row[seg_end] == MazeGenerator.SOLID:
						seg_end += 1
					var shape := RectangleShape2D.new()
					shape.size = Vector2((seg_end - x) * ts, ts)
					var col := CollisionShape2D.new()
					col.shape = shape
					col.position = Vector2(offset_x + (x + seg_end) * 0.5 * ts,
							offset_y + y * ts + ts / 2.0)
					walls.add_child(col)
					total_shapes += 1
					x = seg_end
	print("[Level0] wall collision shapes: %d" % total_shapes)


func _place_player(_grid: Array[Array]) -> void:
	var player: CharacterBody2D = $WorldViewport/Player
	var ts: int = GameParameters.TILE_SIZE
	var empty_cells: Array[Vector2i] = []
	for y in range(_grid.size()):
		for x in range(_grid[y].size()):
			if _grid[y][x] == MazeGenerator.EMPTY:
				empty_cells.append(Vector2i(x, y))
	if empty_cells.is_empty():
		push_error("No empty cells to place player!")
		return
	var pos = empty_cells[randi() % empty_cells.size()]
	player.position = Vector2(pos.x * ts + ts / 2.0, pos.y * ts + ts / 2.0)
