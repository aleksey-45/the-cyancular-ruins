class_name GroundWeaponField
extends RefCounted

# 地面掉落武器逻辑数据表。
# 单人模式由 Level0 持有，多人模式由服务端 MatchHost 权威维护、客户端维护镜像。
# 不直接操作场景节点，仅维护武器元数据条目（唯一实例 ID、武器类型、弹药、位置及速度）。
# 拾取时调用方优先获取最近的一把武器，连续按键可逐一拾取。

var map_size: Vector2 = Vector2.ZERO
var entries: Array[Dictionary] = []   # {inst, type_id, mag, pos, vel}


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


# 查询指定半径范围内距离 pos 最近的武器条目（按环面最短距离计算）。
# 若距离相同则按 inst 升序决出确定性结果。
func nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for e in entries:
		var inst := int(e["inst"])
		if exclude.has(inst):
			continue
		# 计算环面最短相对位移
		var d := GridPathfinder.toroidal_delta_px(
			e["pos"], pos, map_size.x, map_size.y).length()
		if d > radius:
			continue
		if best.is_empty() or d < best_d or (is_equal_approx(d, best_d) and inst < int(best["inst"])):
			best = e
			best_d = d
	return best
