class_name AfterImageField
extends RefCounted

# 通用残影场:把「某一帧的角色贴图 + 当时的世界变换 + 颜色 + 绘制通道」排进池子,
# 每帧按年龄线性淡出、过期回收,超过上限丢最老的一条。
#
# 只做数据 + 绘制,不创建 Node:全部经 WorldCanvas.sprite() 提交到
# Pass.NORMAL / Pass.FOREGROUND(角色残影压在角色下,前景残影盖在世界之上)。
# 行数组从 _free 池复用,池满时循环覆盖,避免每帧为残影分配新对象。
#
# 旧 WorldView._trails 的语义原样保留:寿命 0.26s、按镜头锚点做世界环绕折叠;
# 红/蓝交替只是颜色由调用方(WorldView)决定,本层不关心触发规则。

const MAX_ENTRIES := 48
const DEFAULT_LIFE := 0.26

var _rows: Array[Array] = []
var _free: Array[Array] = []
var _cap := MAX_ENTRIES
var _life := DEFAULT_LIFE


## 上限/默认寿命可调(探针与 QA 用;运行时用默认值)。
func configure(cap: int, life := DEFAULT_LIFE) -> void:
	_cap = maxi(cap, 1)
	_life = maxf(life, 0.0)
	while _rows.size() > _cap:
		_free.append(_rows.pop_front())


func capacity() -> int:
	return _cap


func size() -> int:
	return _rows.size()


## 记录一条残影。life < 0 时用 configure() 的默认寿命。
func spawn(now: float, image: Texture2D, pose: Transform2D, color: Color,
		flip := false, pass_kind := WorldCanvas.Pass.NORMAL, life := -1.0) -> void:
	if image == null or color.a <= 0.0:
		return
	var lifetime := _life if life < 0.0 else life
	if lifetime <= 0.0:
		return
	while _rows.size() >= _cap:
		_free.append(_rows.pop_front())
	var row: Array = _free.pop_back() if not _free.is_empty() \
			else [0.0, null, Transform2D.IDENTITY, Color.WHITE, false, WorldCanvas.Pass.NORMAL, 0.0]
	row[0] = now
	row[1] = image
	row[2] = pose
	row[3] = color
	row[4] = flip
	row[5] = pass_kind
	row[6] = lifetime
	_rows.append(row)


## 淡出并绘制;过期的行回收进池。anchor/size 用于世界环绕折叠(与旧 _draw_trails 一致)。
func present(now: float, anchor: Vector2, canvas: WorldCanvas, size: Vector2) -> void:
	for i in range(_rows.size() - 1, -1, -1):
		var row: Array = _rows[i]
		var lifetime := float(row[6])
		var age := now - float(row[0])
		if age >= lifetime:
			_rows.remove_at(i)
			_free.append(row)
			continue
		var color: Color = row[3]
		color.a *= clampf(1.0 - age / lifetime, 0.0, 1.0)
		var pose: Transform2D = row[2]
		pose.origin = GridPathfinder.anchor_to_nearest(pose.origin, anchor, size)
		_sprite(canvas, row[1], pose, color, row[4], row[5])


func clear() -> void:
	_free.append_array(_rows)
	_rows.clear()


# 残影贴图与角色一样来自帧图集,Region 绘制方式与 WorldView._texture 一致。
static func _sprite(canvas: WorldCanvas, texture: Texture2D, pose: Transform2D,
		color: Color, flip: bool, pass_kind: int) -> void:
	var atlas := texture as AtlasTexture
	canvas.sprite(atlas.atlas, atlas.region, pose, color, flip, pass_kind)
