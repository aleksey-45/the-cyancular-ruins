class_name GroundWeaponField
extends RefCounted

# 场上地面武器的**纯逻辑表**(单机由 Level0 持有;联机由服务器 MatchHost 权威持有、
# 客户端另存一份只读的)。**不碰节点** —— 建/删 WeaponPickup 由持有方负责。
#
# ★ 「多把武器距离太近、捡不起来某些枪」的解法在 nearest_within 的**调用约定**上:
#   调用方一次只捡**最近的一把**,不做"范围里能捡的全捡"。
#   因为拾取规则保证任何武器都捡得起来(容量够就放入、不够就替换手上那把),
#   不存在"最近那把捡不动、把后面能捡的挡住了"的情形 —— 连着按 F 就能逐把捡走。

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


# 距离 pos 最近的、在 radius 内的条目(环面最短距离)。无则返回空字典。
# ★ 距离与半径判定都走**环面最短**:武器可能在接缝另一侧,用绝对坐标差会得出
#   "隔了整幅地图"→ 贴脸也捡不到。
# ★ 并列(两把完全重合)按 inst 升序 —— 必须确定性,否则两台客户端各自挑中不同的一把,
#   服务器裁决的和玩家看到的不是同一把。
func nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for e in entries:
		var inst := int(e["inst"])
		if exclude.has(inst):
			continue
		# 注意 toroidal_delta_px 的签名是 (a, b, w, h) —— 宽高是**两个 float 参数**。
		# 传成 Vector2 不会报错,只会静默按 0 宽高算距离。
		var d := GridPathfinder.toroidal_delta_px(
			e["pos"], pos, map_size.x, map_size.y).length()
		if d > radius:
			continue
		if best.is_empty() or d < best_d or (is_equal_approx(d, best_d) and inst < int(best["inst"])):
			best = e
			best_d = d
	return best
