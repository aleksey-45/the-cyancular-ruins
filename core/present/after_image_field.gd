class_name AfterImageField
extends RefCounted

# 记录残影的贴图、世界变换、颜色和绘制通道。残影随存续时间线性淡出，过期后回收。
# 通过 WorldCanvas.sprite() 绘制，普通残影位于角色下方，前景残影位于世界画面上方。
# 复用回收的记录。达到数量上限时，优先回收最早的残影。
# 默认显示 0.26 秒。跨地图边缘时，以相机锚点为参考选择最近的地图副本。

const MAX_ENTRIES := 48
const DEFAULT_LIFE := 0.26

var _rows: Array[Array] = []
var _free: Array[Array] = []
var _cap := MAX_ENTRIES
var _life := DEFAULT_LIFE


## 设置最大残影数和默认显示时长。
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


## 绘制淡出中的残影，回收过期记录。根据相机锚点和地图尺寸计算跨边界的绘制位置。
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
