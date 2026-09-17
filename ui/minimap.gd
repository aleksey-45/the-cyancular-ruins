class_name Minimap
extends CanvasLayer

# 小地图(可选视觉,实验分支 KikuchiHeinr):**以玩家为中心**的圆形视野。
# 地形由 ui/minimap_circle.gdshader 画圆(圆外直接 discard),敌人点只在圆内
# (世界距离 ≤ RANGE_CELLS 格)才显示。由 pvp_client / royale_game 按设置挂载。
#
# ★ 环面:地形靠采样器 repeat_enable 免费回绕;敌人距离走 toroidal_delta_px 的
#   最短向量 —— 玩家在接缝附近时,地图另一头的敌人**其实就在身边**,直接相减会
#   把它判成"很远"而误藏。

const RADIUS_PX := 140.0    # 圆在屏幕上的半径(像素)
# 圆覆盖的世界半径(格)。★ 调"圆形范围"只改这一行,它**不改变圆在屏幕上的大小**,
# 只改圆里的缩放(每格像素 = RADIUS_PX / RANGE_CELLS,当前 140/50 = 2.8px/格)。
# 标定参照:屏幕能看到 46×36 格(世界视口 2208×1728 ÷ cam_zoom 0.75 ÷ TILE_SIZE 64),
# 1v1 两出生点环面最短距离 34 格。50 → 半径 3200 世界像素 ≈ 2.2 个屏宽,是"雷达"而非"缩略图"。
const RANGE_CELLS := 50.0
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0          # 圆的外接方框距屏幕**右**边缘
# 距屏幕**下**边缘的留白。★ 必须比 EDGE 大得多 —— 右下角是**延迟条**
# (PvpHud / RoyaleHud 的 PingWrap,锚在离下边 24px 处、向上生长),而小地图 layer 131
# 画在 PvpHud(130) **之上**。旧的整图缩略只有 200px 高、碰不到它;换成 280×280 的圆之后
# 会**盖住延迟数字**(2026-09-17 用户报"不要挡住下方的延迟")。
# 80 = 24(延迟条自身距下边) + ~40(延迟条高度) + ~16 间隙,留得比"刚好不压"宽一点。
const EDGE_BOTTOM := 80.0
const RING_PX := 4.0        # 圆内缘描边宽度(2026-09-17:2 → 4,用户要求"加粗")

const SHADER_PATH := "res://ui/minimap_circle.gdshader"
const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)

var _local_provider: Callable = Callable()   # () -> Vector2 本地玩家世界坐标
var _enemy_provider: Callable = Callable()   # () -> Vector2 对手世界坐标(INF=无)
# 多目标模式(大乱斗):others_provider () -> Array[Vector2],按需扩点位池
var _others_provider: Callable = Callable()
var _mat: ShaderMaterial = null
var _rect_pos := Vector2.ZERO
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _other_dots: Array[ColorRect] = []


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


# 大乱斗多目标版:others_provider 返回全部对手世界坐标数组
func setup_multi(local_provider: Callable, others_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider


func _ready() -> void:
	layer = 131   # 盖在 PvpHud(130) 之上、不影响输入
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	# 地形底图:墙=亮灰,水=蓝,空气=深色半透明(1 像素 = 1 格,着色器按 PX_PER_CELL 放大)
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
		# 玩家位置未知:藏掉全部点(地形仍按上一次的中心画)
		_dot_self.visible = false
		_dot_enemy.visible = false
		for d in _other_dots:
			d.visible = false
		return
	var canonical := MazeGenerator.wrap_to_range(p, w, h)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))

	# 自己:恒在圆心
	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5

	if _others_provider.is_valid():
		# 多目标(大乱斗):按需扩池,显隐随设置 + 范围
		var others: Array = _others_provider.call()
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		_place_enemy_dot(_dot_enemy, _enemy_provider.call(), p, w, h)


func _circle_center() -> Vector2:
	return _rect_pos + Vector2(RADIUS_PX, RADIUS_PX)


# 敌人点:环面最短向量 → 圆心偏移;超出半径(即世界距离 > RANGE_CELLS 格)不显示。
func _place_enemy_dot(dot: ColorRect, enemy: Vector2, player: Vector2, w: float, h: float) -> void:
	if not Settings.pvp_minimap_show_enemy or not enemy.is_finite():
		dot.visible = false
		return
	# ★ 参数顺序:toroidal_delta_px(a, b, …) 返回 **a→b**,故是 (玩家, 敌人)
	var d := GridPathfinder.toroidal_delta_px(player, enemy, w, h)   # 世界像素
	var s := d / float(GameParameters.TILE_SIZE) * PX_PER_CELL       # 圆心 → 该点的屏幕像素
	if s.length() > RADIUS_PX:
		dot.visible = false
		return
	dot.visible = true
	dot.position = _circle_center() + s - dot.size * 0.5
