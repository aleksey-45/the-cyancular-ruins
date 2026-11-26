class_name AfterImageField
extends RefCounted

# 残影按存续时间淡出，过期后回收。达到数量上限时，优先回收最早的残影。
# 普通残影先于角色绘制，前景残影在角色之后绘制。

const MAX_ENTRIES := 48

var _rows: Array[Array] = []
var _free: Array[Array] = []


func spawn(now: float, image: AtlasTexture, pose: Transform2D, color: Color,
		pass_kind: WorldCanvas.Pass, life: float) -> void:
	if _rows.size() == MAX_ENTRIES:
		_free.append(_rows.pop_front())
	var row: Array = _free.pop_back() if not _free.is_empty() \
			else [0.0, null, Transform2D.IDENTITY, Color.WHITE, WorldCanvas.Pass.NORMAL, 0.0]
	row[0] = now
	row[1] = image
	row[2] = pose
	row[3] = color
	row[4] = pass_kind
	row[5] = life
	_rows.append(row)


## 跨过地图边界时，残影绘制在离相机最近的一侧。
func present(now: float, anchor: Vector2, canvas: WorldCanvas, size: Vector2) -> void:
	for i in range(_rows.size() - 1, -1, -1):
		var row: Array = _rows[i]
		var lifetime := float(row[5])
		var age := now - float(row[0])
		if age >= lifetime:
			_rows.remove_at(i)
			_free.append(row)
			continue
		var color: Color = row[3]
		color.a *= clampf(1.0 - age / lifetime, 0.0, 1.0)
		var pose: Transform2D = row[2]
		pose.origin = GridPathfinder.anchor_to_nearest(pose.origin, anchor, size)
		var image: AtlasTexture = row[1]
		canvas.sprite(image.atlas, image.region, pose, color, row[4])


func clear() -> void:
	_free.append_array(_rows)
	_rows.clear()
