extends Node2D

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
	# 10 块源砖(顶行 32×32)→ 最近邻 2× 放大成 64×64
	var bricks: Array[Image] = []
	for i in range(10):
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.blit_rect(src_img, Rect2i(i * 32, 0, 32, 32), Vector2i.ZERO)
		img.resize(ts, ts, Image.INTERPOLATE_NEAREST)
		bricks.append(img)
	# atlas:16 列(形状 0-15)× 10 行(纹理 1-10),空气象限透明
	var atlas_img := Image.create(16 * ts, 10 * ts, false, Image.FORMAT_RGBA8)
	atlas_img.fill(Color(0, 0, 0, 0))
	for tex in range(10):
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
		for tex in range(10):
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
					# packed → atlas 坐标(形状列, 纹理行)
					layer.set_cell(Vector2i(x + offset_x, y + offset_y), source_id,
							Vector2i(MazeGenerator.shape_of(v), MazeGenerator.texture_of(v) - 1))


func _build_wall_collision(grid: Array[Array]) -> void:
	var half: int = GameParameters.TILE_SIZE / 2   # 32 子格
	var cols = grid[0].size()   # 125
	var rows = grid.size()      # 75
	# 形状掩码展开成 250×150 的 32px 子格(每 64px 格 → 2×2)
	var sub: Array[Array] = []
	for _r in range(rows * 2):
		var srow: Array[int] = []
		srow.resize(cols * 2)
		srow.fill(MazeGenerator.EMPTY)
		sub.append(srow)
	for y in range(rows):
		for x in range(cols):
			var shape: int = MazeGenerator.shape_of(grid[y][x])
			if shape == 0:
				continue
			for qy in range(2):
				for qx in range(2):
					if shape & (1 << (qy * 2 + qx)):
						sub[y * 2 + qy][x * 2 + qx] = MazeGenerator.SOLID
	_greedy_rects(sub, half)


func _greedy_rects(grid: Array[Array], ts: int) -> void:
	var walls = StaticBody2D.new()
	walls.name = "WallCollision"
	$WorldViewport.add_child(walls)

	var cols = grid[0].size()
	var rows = grid.size()

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
					if grid[y][x] == MazeGenerator.EMPTY or used[y][x]:
						continue
					# 横向扩展整行连续墙段
					var x2 := x
					while x2 + 1 < cols and grid[y][x2 + 1] != MazeGenerator.EMPTY and not used[y][x2 + 1]:
						x2 += 1
					# 纵向扩展:要求下行整段都是未访问的墙
					var y2 := y
					while y2 + 1 < rows:
						var can := true
						for cx in range(x, x2 + 1):
							if grid[y2 + 1][cx] == MazeGenerator.EMPTY or used[y2 + 1][cx]:
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
