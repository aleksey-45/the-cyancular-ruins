class_name Minimap
extends CanvasLayer

# 圆形小地图以本地玩家为中心。跨过地图边缘时连续显示另一侧地形，玩家标记也取跨边界的最短偏移。

const RADIUS_PX := 140.0     # 小地图在 HUD 上的半径，单位为像素。
const RANGE_CELLS := 200.0   # 从玩家位置向外显示的子格数。
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := float(UiDesign.MARGIN)                             # 屏幕右边距。
const EDGE_BOTTOM := float(UiDesign.MARGIN + UiDesign.SP_8)      # 底部再让出延迟读数的高度。
const RING_PX := 4.0

const TILE_EMPTY_ALPHA := 0.55
const TILE_LIQUID_ALPHA := 0.85
const TILE_SOLID_ALPHA := 0.95

var _map_size: Vector2
var _map: Dictionary
var _mat: ShaderMaterial
var _view: ColorRect
var _dots: Dots

func _init(map: Dictionary) -> void:
	_map = map
	_map_size = Vector2(map.size * CyrmMap.CELL_SIZE)

func _ready() -> void:
	layer = 131
	# 小地图可能先于世界画布创建，先加载材质表供地形着色使用。
	TileDefs.load_defs()
	var cells: PackedInt32Array = _map.layers[CyrmMap.SCENE]
	var cols: int = _map.size.x
	var rows: int = _map.size.y

	# 背景纹理用一个像素表示一个子格，空地、水和其他地形分别着色。
	var empty_color := Color(UiDesign.C_BG, TILE_EMPTY_ALPHA)
	var liquid_color := Color(UiDesign.C_SLOT_FILLED, TILE_LIQUID_ALPHA)
	var solid_color := Color(UiDesign.C_TEXT_DIM, TILE_SOLID_ALPHA)
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v := CyrmMap.tile_material(cells[y * cols + x])
			if v == 0:
				img.set_pixel(x, y, empty_color)
			elif TileDefs.is_liquid(v):
				img.set_pixel(x, y, liquid_color)
			else:
				img.set_pixel(x, y, solid_color)

	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://ui/hud/minimap_circle.gdshader")
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	_view = ColorRect.new()
	_view.name = "Circle"
	_view.material = _mat
	_view.anchor_left = 1.0
	_view.anchor_right = 1.0
	_view.anchor_top = 1.0
	_view.anchor_bottom = 1.0
	_view.offset_left = -EDGE - RADIUS_PX * 2.0
	_view.offset_right = -EDGE
	_view.offset_top = -EDGE_BOTTOM - RADIUS_PX * 2.0
	_view.offset_bottom = -EDGE_BOTTOM
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_view)

	# 玩家标记的偏移以小地图圆心为参考。
	_dots = Dots.new()
	_dots.name = "Markers"
	add_child(_dots)

func present(frame: MatchFrame) -> void:
	var pos := frame.focus
	var canonical := GridPathfinder.wrap_to_range(pos, _map_size)
	_mat.set_shader_parameter("center_cell", canonical / float(CyrmMap.CELL_SIZE))
	_dots.markers.clear()
	if frame.actors.is_empty():
		_dots.queue_redraw()
		return
	_dots.markers.append([Vector2.ZERO, frame.actors[0].name_color(frame.mode)])
	if frame.radar_players:
		for i in range(1, frame.actors.size()):
			var pose := frame.actors[i]
			var offset := GridPathfinder.toroidal_delta_px(pos, pose.anchor, _map_size) \
					* (PX_PER_CELL / CyrmMap.CELL_SIZE)
			if offset.length_squared() <= RADIUS_PX * RADIUS_PX:
				_dots.markers.append([offset, pose.name_color(frame.mode)])
	_dots.queue_redraw()


class Dots extends Control:
	const DOT_PX := 8.0
	const RING_SELF_PX := 4.0
	var markers: Array = []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		anchor_left = 0.0
		anchor_top = 0.0
		anchor_right = 1.0
		anchor_bottom = 1.0
		offset_left = 0.0
		offset_top = 0.0
		offset_right = 0.0
		offset_bottom = 0.0

	func _draw() -> void:
		var center := size * 0.5
		# 白色外圈用于识别本地玩家。
		draw_rect(Rect2(center - Vector2.ONE * (DOT_PX * 0.5 + RING_SELF_PX),
				Vector2.ONE * (DOT_PX + 2.0 * RING_SELF_PX)), Color.WHITE)
		for marker in markers:
			draw_rect(Rect2(center + marker[0] - Vector2.ONE * (DOT_PX * 0.5),
					Vector2.ONE * DOT_PX), marker[1])
