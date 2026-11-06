class_name GroundWeaponField
extends RefCounted


var map_size: Vector2 = Vector2.ZERO
var entries: Array[Dictionary] = []


func size() -> int:
	return entries.size()


func clear() -> void:
	entries.clear()


func add(entry: Dictionary) -> void:
	entries.append(entry)


func remove(inst: int) -> Dictionary:
	for i in entries.size():
		if int(entries[i]["inst"]) == inst:
			return entries.pop_at(i)
	return {}


func get_entry(inst: int) -> Dictionary:
	for e in entries:
		if int(e["inst"]) == inst:
			return e
	return {}


func reanchor(inst: int, pos: Vector2, vel: Vector2) -> bool:
	var e := get_entry(inst)
	if e.is_empty():
		return false
	e["pos"] = pos
	e["vel"] = vel
	return true


func nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for e in entries:
		var inst := int(e["inst"])
		if exclude.has(inst):
			continue
		# 注意 toroidal_delta_px 的签名是 (a, b, w, h) —— 宽高是两个 float 参数。
		# 传成 Vector2 不会报错,只会静默按 0 宽高算距离。
		var d := GridPathfinder.toroidal_delta_px(
			e["pos"], pos, map_size.x, map_size.y).length()
		if d > radius:
			continue
		if best.is_empty() or d < best_d or (is_equal_approx(d, best_d) and inst < int(best["inst"])):
			best = e
			best_d = d
	return best
