class_name Minimap
extends CanvasLayer

# 玩家位于小地图中央。可见范围跨过地图边缘时，背景接着显示另一侧的瓦片。
# 玩家标记取跨地图边缘的最短偏移。只绘制落在圆内的标记。

const RADIUS_PX := 140.0    # 小地图在 HUD 上的半径，单位为像素。
const RANGE_CELLS := 200.0   # 从玩家位置向外显示的子格数。
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0
const EDGE_BOTTOM := 72.0   # 延迟读数显示在小地图下方，此处预留高度。
const RING_PX := 4.0
const RING_SELF_PX := 4.0

const CENTER := Vector2(1920.0 - EDGE - RADIUS_PX, 1440.0 - EDGE_BOTTOM - RADIUS_PX)

var _map_size: Vector2
var _map: Dictionary
var _mat: ShaderMaterial
var _dots := Node2D.new()
var _markers: Array[Array] = []

func _init(map: Dictionary) -> void:
	_map = map
	_map_size = Vector2(map.size * CyrmMap.CELL_SIZE)

func _ready() -> void:
	layer = 131
	var cells: PackedInt32Array = _map.layers[CyrmMap.SCENE]
	var cols: int = _map.size.x
	var rows: int = _map.size.y

	# 背景纹理用一个像素表示一个子格，空地、水和其他地形分别着色。
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v := CyrmMap.tile_material(cells[y * cols + x])
			if v == 0:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif TileDefs.is_liquid(v):
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
	_mat.set_shader_parameter("center_cell", canonical / float(CyrmMap.CELL_SIZE))
	_markers = [[CENTER, frame.actors[0].name_color(frame.mode)]]
	if frame.radar_players:
		for i in range(1, frame.actors.size()):
			var pose := frame.actors[i]
			var offset := GridPathfinder.toroidal_delta_px(pos, pose.anchor, _map_size) * (PX_PER_CELL / CyrmMap.CELL_SIZE)
			if offset.length_squared() <= RADIUS_PX * RADIUS_PX:
				_markers.append([CENTER + offset, pose.name_color(frame.mode)])
	_dots.queue_redraw()

func _draw_markers() -> void:
	_dots.draw_rect(Rect2(CENTER - Vector2.ONE * (4 + RING_SELF_PX), Vector2.ONE * (8 + 2 * RING_SELF_PX)), Color.WHITE)
	for marker in _markers:
		_dots.draw_rect(Rect2(marker[0] - Vector2(4, 4), Vector2(8, 8)), marker[1])
