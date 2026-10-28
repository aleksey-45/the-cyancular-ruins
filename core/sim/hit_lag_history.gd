extends RefCounted

# 命中回放用的受击面历史环:服务器每物理 tick 记一条 role -> {p: canonical 位置, r: 相对 p 的受击面 Rect2}。
# ★ 纯逻辑、无 autoload、不碰 SceneTree:-s 冒烟可直接 new() 驱动。
# ★ 只存受击面的几何(位置 + 相对偏移/尺寸),不存姿态/朝向:回放取的是"射手当时看到的那个矩形"。

const CAPACITY := 24   # 24 tick @60Hz = 400ms,远大于命中回放上限(8 tick),再多只是浪费内存

var _ticks: Array[int] = []
var _frames: Dictionary = {}   # tick(int) -> {role(int): {"p": Vector2, "r": Rect2}}


# 记录一个 tick 的全员受击面。同 tick 重复 push = 覆盖(物理追赶/重入时以最后一次为准)。
func push(tick: int, entries: Dictionary) -> void:
	var frame: Dictionary = {}
	for role in entries:
		var e: Dictionary = entries[role]
		frame[int(role)] = {"p": e["p"], "r": e["r"]}
	if _frames.has(tick):
		_frames[tick] = frame
		return
	_frames[tick] = frame
	if _ticks.is_empty() or tick > _ticks[_ticks.size() - 1]:
		_ticks.append(tick)
	else:
		var i := _ticks.size() - 1
		while i >= 0 and _ticks[i] > tick:
			i -= 1
		_ticks.insert(i + 1, tick)
	while _ticks.size() > CAPACITY:
		_frames.erase(_ticks[0])
		_ticks.remove_at(0)


func latest_tick() -> int:
	return _ticks[_ticks.size() - 1] if not _ticks.is_empty() else 0


# 目标 tick 向下取整到历史里已有的最近一条;低于最老夹到最老、高于最新夹到最新。空历史返回 -1。
func nearest_tick(t: int) -> int:
	if _ticks.is_empty():
		return -1
	if t <= _ticks[0]:
		return _ticks[0]
	if t >= _ticks[_ticks.size() - 1]:
		return _ticks[_ticks.size() - 1]
	var lo := 0
	var hi := _ticks.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if _ticks[mid] <= t:
			lo = mid
		else:
			hi = mid - 1
	return _ticks[lo]


func pos_for(role: int, t: int) -> Vector2:
	var frame := _frame_at(t)
	if frame.is_empty() or not frame.has(int(role)):
		return Vector2.ZERO
	var e: Dictionary = frame[int(role)]
	var p: Vector2 = e["p"]
	return p


# 世界系受击面 = 历史位置 p + 相对偏移 r;无该 role / 无历史时返回空 Rect2(调用方回退现时受击面)。
func rect_for(role: int, t: int) -> Rect2:
	var frame := _frame_at(t)
	if frame.is_empty() or not frame.has(int(role)):
		return Rect2()
	var e: Dictionary = frame[int(role)]
	var p: Vector2 = e["p"]
	var r: Rect2 = e["r"]
	return Rect2(p + r.position, r.size)


func clear() -> void:
	_ticks.clear()
	_frames.clear()


func size() -> int:
	return _ticks.size()


func _frame_at(t: int) -> Dictionary:
	var tick := nearest_tick(t)
	if tick < 0:
		return {}
	var frame: Dictionary = _frames.get(tick, {})
	return frame
