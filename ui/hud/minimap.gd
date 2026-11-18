class_name Minimap
extends CanvasLayer

# 环面小地图组件：以本地玩家为中心的圆形雷达视野。
# 地形纹理经着色器渲染为圆形视口，环面距离由 GridPathfinder 统一计算。
# 超出探测半径的目标点自动裁剪隐藏。

const RADIUS_PX := 140.0    # 屏幕渲染半径（像素）
const RANGE_CELLS := 50.0   # 雷达探测覆盖的世界网格半径（瓦片格）
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0          # 距屏幕右边缘间距
const EDGE_BOTTOM := 72.0   # 距屏幕下边缘间距，避开右下角网络延迟显示区域
const RING_PX := 4.0        # 圆形雷达外边缘描边宽度
const RING_SELF_PX := 4.0   # 本地玩家标记外侧描边宽度

const CENTER := Vector2(1920.0 - EDGE - RADIUS_PX, 1440.0 - EDGE_BOTTOM - RADIUS_PX)

var _map_size: Vector2
var _grid: Array[Array]
var _mat: ShaderMaterial
var _dots := Node2D.new()
var _markers: Array[Array] = []

func _init(grid: Array[Array], map_size: Vector2) -> void:
	_grid = grid
	_map_size = map_size

func _ready() -> void:
	layer = 131
	var grid := _grid
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	# 生成缩略地形底图：墙体、水体与空地使用不同颜色区分
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			if v == MapFormat.EMPTY:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif TileDefs.is_liquid(MapFormat.texture_of(v)):
				img.set_pixel(x, y, Color(0.15, 0.38, 0.85, 0.85))
			else:
				img.set_pixel(x, y, Color(0.62, 0.68, 0.75, 0.95))

	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://ui/hud/minimap_circle.gdshader")
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	var view := ColorRect.new()
	view.name = "Circle"
	view.material = _mat
	view.position = CENTER - Vector2.ONE * RADIUS_PX
	view.size = Vector2(RADIUS_PX, RADIUS_PX) * 2.0
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)

	add_child(_dots)
	_dots.draw.connect(_draw_markers)

func present(frame: MatchFrame) -> void:
	var pos := frame.focus
	var canonical := GridPathfinder.wrap_to_range(pos, _map_size)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))
	_markers = [[CENTER, frame.actors[0].name_color(frame.mode)]]
	if frame.radar_players:
		for i in range(1, frame.actors.size()):
			var pose := frame.actors[i]
			var offset := GridPathfinder.toroidal_delta_px(pos, pose.anchor, _map_size) * (PX_PER_CELL / GameParameters.TILE_SIZE)
			if offset.length_squared() <= RADIUS_PX * RADIUS_PX:
				_markers.append([CENTER + offset, pose.name_color(frame.mode)])
	_dots.queue_redraw()

func _draw_markers() -> void:
	_dots.draw_rect(Rect2(CENTER - Vector2.ONE * (4 + RING_SELF_PX), Vector2.ONE * (8 + 2 * RING_SELF_PX)), Color.WHITE)
	for marker in _markers:
		_dots.draw_rect(Rect2(marker[0] - Vector2(4, 4), Vector2(8, 8)), marker[1])
