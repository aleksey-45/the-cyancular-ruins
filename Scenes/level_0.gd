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
	MazeGenerator.current_grid = grid

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

	# 贪心合并连续墙格为尽可能大的矩形（先横向扩展、再纵向扩展，并标记已访问），
	# 把形状数从「每行每段一个」压到「每块矩形一个」。需覆盖环面 3×3 展开区域，
	# 玩家/子弹/敌人才能跨接缝。
	var total_shapes := 0
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var offset_x = tx * cols * ts
			var offset_y = ty * rows * ts
			var used: Array[Array] = []
			for _r in range(rows):
				var urow: Array[bool] = []
				urow.resize(cols)
				urow.fill(false)
				used.append(urow)
			for y in range(rows):
				for x in range(cols):
					if grid[y][x] != MazeGenerator.SOLID or used[y][x]:
						continue
					# 横向扩展整行连续墙段
					var x2 := x
					while x2 + 1 < cols and grid[y][x2 + 1] == MazeGenerator.SOLID and not used[y][x2 + 1]:
						x2 += 1
					# 纵向扩展:要求下行整段都是未访问的墙
					var y2 := y
					while y2 + 1 < rows:
						var can := true
						for cx in range(x, x2 + 1):
							if grid[y2 + 1][cx] != MazeGenerator.SOLID or used[y2 + 1][cx]:
								can = false
								break
						if not can:
							break
						y2 += 1
					# 标记该矩形覆盖的格子已访问
					for ry in range(y, y2 + 1):
						for rx in range(x, x2 + 1):
							used[ry][rx] = true
					var shape := RectangleShape2D.new()
					shape.size = Vector2((x2 - x + 1) * ts, (y2 - y + 1) * ts)
					var col := CollisionShape2D.new()
					col.shape = shape
					col.position = Vector2(offset_x + (x + x2 + 1) * 0.5 * ts,
							offset_y + (y + y2 + 1) * 0.5 * ts)
					walls.add_child(col)
					total_shapes += 1
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
