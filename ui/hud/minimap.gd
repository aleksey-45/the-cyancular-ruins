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

const SHADER_PATH := "res://ui/hud/minimap_circle.gdshader"
const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)

var _local_provider: Callable = Callable()   # 返回本地玩家世界坐标的回调
var _enemy_provider: Callable = Callable()   # 返回对手世界坐标的回调
var _others_provider: Callable = Callable()  # 多人模式下返回其他玩家世界坐标数组的回调
var _color_provider: Callable = Callable()   # 返回与目标数组对应颜色的回调
var _self_color_provider: Callable = Callable() # 返回本地玩家队色的回调
var _ring_self: ColorRect
var _mat: ShaderMaterial = null
var _rect_pos := Vector2.ZERO
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _other_dots: Array[ColorRect] = []


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


# 初始化多目标雷达显示（团队对抗与多人大乱斗模式）
func setup_multi(local_provider: Callable, others_provider: Callable,
		color_provider: Callable, self_color_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider
	_color_provider = color_provider
	_self_color_provider = self_color_provider


func _ready() -> void:
	layer = 131
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	# 生成缩略地形底图：墙体、水体与空地使用不同颜色区分
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			if v == MazeGenerator.EMPTY:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif Water.is_liquid(MazeGenerator.texture_of(v)):
				img.set_pixel(x, y, Color(0.15, 0.38, 0.85, 0.85))
			else:
				img.set_pixel(x, y, Color(0.62, 0.68, 0.75, 0.95))

	_rect_pos = Vector2(1920.0 - EDGE - RADIUS_PX * 2.0, 1440.0 - EDGE_BOTTOM - RADIUS_PX * 2.0)

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	var view := ColorRect.new()
	view.name = "Circle"
	view.material = _mat
	view.position = _rect_pos
	view.size = Vector2(RADIUS_PX, RADIUS_PX) * 2.0
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)

	# 优先添加外框描边节点，确保自身标记覆盖在描边之上
	_ring_self = _make_dot(Color(1.0, 1.0, 1.0, 1.0))
	_ring_self.size = Vector2(8, 8) + Vector2(RING_SELF_PX, RING_SELF_PX) * 2.0
	_dot_self = _make_dot(SELF_COLOR)
	_dot_enemy = _make_dot(ENEMY_COLOR)


func _make_dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.size = Vector2(8, 8)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.visible = false
	add_child(d)
	return d


func _process(_delta: float) -> void:
	if _dot_self == null:
		return
	var p := Vector2.INF
	if _local_provider.is_valid():
		p = _local_provider.call()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if not p.is_finite() or w <= 0.0 or h <= 0.0:
		_dot_self.visible = false
		_ring_self.visible = false
		_dot_enemy.visible = false
		for d in _other_dots:
			d.visible = false
		return
	var canonical := MazeGenerator.wrap_to_range(p, w, h)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))

	# 本地角色标记固定居中显示
	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5
	var use_team_self := _self_color_provider.is_valid()
	if use_team_self:
		_dot_self.color = _self_color_provider.call()
		_ring_self.visible = true
		_ring_self.position = _circle_center() - _ring_self.size * 0.5
	else:
		_ring_self.visible = false

	if _others_provider.is_valid():
		var others: Array = _others_provider.call()
		var cols: Array = _color_provider.call() if _color_provider.is_valid() else []
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			if i < cols.size():
				(_other_dots[i] as ColorRect).color = cols[i]
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		_place_enemy_dot(_dot_enemy, _enemy_provider.call(), p, w, h)


func _circle_center() -> Vector2:
	return _rect_pos + Vector2(RADIUS_PX, RADIUS_PX)


# 根据环面最短位移计算并摆放目标点位，超出雷达视野时隐藏
func _place_enemy_dot(dot: ColorRect, enemy: Vector2, player: Vector2, w: float, h: float) -> void:
	if not Settings.pvp_minimap_show_enemy or not enemy.is_finite():
		dot.visible = false
		return
	var d := GridPathfinder.toroidal_delta_px(player, enemy, w, h)
	var s := d / float(GameParameters.TILE_SIZE) * PX_PER_CELL
	if s.length() > RADIUS_PX:
		dot.visible = false
		return
	dot.visible = true
	dot.position = _circle_center() + s - dot.size * 0.5

