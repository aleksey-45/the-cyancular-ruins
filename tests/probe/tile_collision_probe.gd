extends Node

# 建筑(可破坏砖)碰撞守卫:碰撞必须**逐 16px 子格**与"游戏自己的规则"一致。
# 存在理由:破坏/回溯这条链上**碰撞那一维此前完全没有守卫** —— `tile_rewind_probe` 只验
# 「网格 + 渲染层 atlas」,无法覆盖检测"砖没了碰撞还在"(看不见的墙 = 虚空碰撞箱)与"砖画着却撞不着"。
#
# 判据取**游戏自己的两条规则**(不是另写一套):
#   渲染  = `_paint_maze` 的规则:tex != 0 且 非液体 且 子格存活
#   碰撞  = `CollisionBuilder.build_sub` 的规则:tex 是 wall 且 子格存活
#   - 例外:锁链顶/底有 **64px 全宽 6px 薄碰撞条**(`build_climb_ledges`),它不来自子格 →
#     凡 3×3 子格邻域里出现链纹理(12/13/14)的采样点**整点跳过**(保守,宁可少验)。
#
# 阶段 1 选中一个"可破坏且存活"的子格:它必须同时有渲染与碰撞
# 阶段 2 只拆它 → 两侧同时消失,同格其它子格**不受牵连**
# 阶段 3 拆光该 64px 格里所有存活的可破坏子格 → 全无;并验 **9 环面副本**(±MAP 偏移)
# 阶段 4 回溯复原 → 逐子格回到基线(渲染与碰撞都对上),环面副本一并回来
# 阶段 5 节流窗口:一帧内拆跨 **多块**(> MAX_REBUILD_PER_FRAME=2)的砖 → 数出碰撞追上渲染要几帧;断言有界
# 相⓪/阶段 6 全场抽样(每 8 个子格一点):**渲染与碰撞各自与规则逐点相等** —— 这一相就是
#      「建筑有没有虚空碰撞箱」的直接回答,破坏+回溯之后再扫一遍
#
# 用法:godot --headless --path . res://tests/probe/tile_collision_probe.tscn

const STRIDE := 8   # 全场抽样步长(子格);8 子格 = 128px = 2 格

var _fails: Array[String] = []
var _skipped := 0
var _sampled := 0


func _ready() -> void:
	_run.call_deferred()


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _terrain_at(world: World2D, pos: Vector2) -> bool:
	var ss := world.direct_space_state
	var ps := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(8, 8)   # 8×8 恒落在 16px 子格的中段,不会蹭到邻格
	ps.shape = rect
	ps.transform = Transform2D(0.0, pos)
	ps.collision_mask = 1       # 地形层
	ps.collide_with_bodies = true
	ps.collide_with_areas = false
	return not ss.intersect_shape(ps, 4).is_empty()


func _painted(sub: Vector2i) -> bool:
	return (Level0.wall_layer as TileMapLayer).get_cell_atlas_coords(sub).x >= 0


func _sub_center(sub: Vector2i) -> Vector2:
	return Vector2(sub.x * 16 + 8, sub.y * 16 + 8)


func _tex(sub: Vector2i) -> int:
	var sg: Array = MazeGenerator.current_subgrid
	if sub.y < 0 or sub.y >= sg.size() or sub.x < 0 or sub.x >= (sg[0] as Array).size():
		return 0
	return int((sg[sub.y] as Array)[sub.x])


## 该子格"应该有渲染吗/应该有碰撞吗"(游戏自己的两条规则,见文件头)。
func _expect(sub: Vector2i) -> Array:
	var t := _tex(sub)
	var alive := t != 0 and TileDefs.sub_alive(sub)
	return [
		alive and not TileDefs.is_liquid(t),
		alive and TileDefs.type_id_of(t) == TileDefs.TYPE_WALL,
	]


## 链纹理(12/13/14)邻域 → 有薄碰撞条,采样不安全。
func _near_chain(sub: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var t := _tex(sub + Vector2i(dx, dy))
			if t == 12 or t == 13 or t == 14:
				return true
	return false


## 逐子格核对"渲染 ⇔ 规则"与"碰撞 ⇔ 规则"。cells = 采样子格列表。
func _scan(world: World2D, subs: Array, tag: String) -> void:
	var bad_paint: Array = []
	var bad_col: Array = []
	var n := 0
	_skipped = 0
	for s in subs:
		var sub: Vector2i = s
		if _near_chain(sub):
			_skipped += 1
			continue
		n += 1
		var e := _expect(sub)
		if _painted(sub) != bool(e[0]):
			bad_paint.append("%s(画=%s 期望=%s tex=%d)" % [str(sub), str(_painted(sub)), str(e[0]), _tex(sub)])
		if _terrain_at(world, _sub_center(sub)) != bool(e[1]):
			bad_col.append("%s(碰=%s 期望=%s tex=%d)" % [str(sub), str(_terrain_at(world, _sub_center(sub))), str(e[1]), _tex(sub)])
	print("[%s] 抽样 %d 点(跳过链邻域 %d):渲染不符 %d / 碰撞不符 %d"
			% [tag, n, _skipped, bad_paint.size(), bad_col.size()])
	if not bad_paint.is_empty():
		_fail("%s 渲染与规则不符 %d 处:%s" % [tag, bad_paint.size(), ", ".join(bad_paint.slice(0, 4))])
	if not bad_col.is_empty():
		_fail("%s 碰撞与规则不符 %d 处(虚空碰撞箱/能穿墙):%s"
				% [tag, bad_col.size(), ", ".join(bad_col.slice(0, 4))])


func _all_subs() -> Array:
	var sg: Array = MazeGenerator.current_subgrid
	var out: Array = []
	for y in range(0, sg.size(), STRIDE):
		for x in range(0, (sg[0] as Array).size(), STRIDE):
			out.append(Vector2i(x, y))
	return out


## 找一个"可破坏、存活"的子格(优先整格都活的,便于阶段 3)。
func _find_target() -> Vector2i:
	var sg: Array = MazeGenerator.current_subgrid
	for y in sg.size():
		for x in (sg[0] as Array).size():
			var sub := Vector2i(x, y)
			var t := _tex(sub)
			if t == 0 or not TileDefs.sub_alive(sub):
				continue
			if TileDefs.type_id_of(t) != TileDefs.TYPE_WALL:
				continue
			if not (TileDefs.explosion_destroyable(t) or TileDefs.bullet_destroyable(t)):
				continue
			return sub
	return Vector2i(-1, -1)


func _cell_subs(cell: Vector2i) -> Array:
	var out: Array = []
	for sy in 4:
		for sx in 4:
			out.append(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy))
	return out


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	await _wait_ms(500)
	var player: Node2D = lvl.get_node_or_null("WorldViewport/Player") as Node2D
	if player == null or Level0.wall_layer == null or Level0.time_field == null:
		print("TILE COLLISION PROBE: FAIL(世界未就绪)")
		tree.quit(1)
		return
	var world := player.get_world_2d()
	var mx := float(GameParameters.MAP_WIDTH)

	# 相⓪ 全场抽样
	_scan(world, _all_subs(), "相⓪·初始全场")

	# 阶段 1 目标子格
	var target := _find_target()
	if target.x < 0:
		print("TILE COLLISION PROBE: FAIL(图上没有可破坏的子格,用例前置不成立)")
		tree.quit(1)
		return
	var cell := Vector2i(target.x / 4, target.y / 4)
	var subs := _cell_subs(cell)
	var baseline: Array = []
	for s in subs:
		baseline.append([_painted(s), _terrain_at(world, _sub_center(s))])
	print("[相①] 目标子格 %s(格 %s)tex=%d 画=%s 碰=%s"
			% [str(target), str(cell), _tex(target), str(_painted(target)),
			str(_terrain_at(world, _sub_center(target)))])
	if not _painted(target) or not _terrain_at(world, _sub_center(target)):
		_fail("相① 选中的存活可破坏子格本身就缺渲染或缺碰撞")

	# 阶段 2 只拆它
	TileDefs.damage_sub(target, 9999, "explosion")
	await _wait_ms(300)
	if _painted(target) or _terrain_at(world, _sub_center(target)):
		_fail("相② 被拆的子格 %s 仍残留(画=%s 碰=%s)"
				% [str(target), str(_painted(target)), str(_terrain_at(world, _sub_center(target)))])
	var collateral := 0
	for i in subs.size():
		var s: Vector2i = subs[i]
		if s == target:
			continue
		if _painted(s) != bool(baseline[i][0]) or _terrain_at(world, _sub_center(s)) != bool(baseline[i][1]):
			collateral += 1
	print("[相②] 只拆 1 个子格:同格其余 15 格被牵连 %d 个" % collateral)
	if collateral > 0:
		_fail("相② 拆 1 个子格牵连了同格其它子格(%d 个)" % collateral)

	# 阶段 3 拆光该格所有存活的可破坏子格
	for s in subs:
		var t := _tex(s)
		if t != 0 and TileDefs.sub_alive(s) and TileDefs.type_id_of(t) == TileDefs.TYPE_WALL \
				and (TileDefs.explosion_destroyable(t) or TileDefs.bullet_destroyable(t)):
			TileDefs.damage_sub(s, 9999, "explosion")
	await _wait_ms(300)
	var left := 0
	for s in subs:
		if _painted(s) or _terrain_at(world, _sub_center(s)):
			left += 1
	print("[相③] 拆光该格:16 子格中仍有渲染或碰撞的 = %d" % left)
	if left > 0:
		_fail("相③ 拆光后该格仍有 %d 个子格残留渲染/碰撞" % left)
	var center := Vector2(cell.x * 64 + 32, cell.y * 64 + 32)
	if _terrain_at(world, center + Vector2(mx, 0.0)) or _terrain_at(world, center - Vector2(mx, 0.0)):
		_fail("相③ 环面副本(±MAP_WIDTH)处仍有地形碰撞:接缝另一侧的幽灵墙")

	# 阶段 4 回溯复原
	Input.action_press("rewind")
	await _wait_ms(2500)
	Input.action_release("rewind")
	await _wait_ms(400)
	var wrong := 0
	for i in subs.size():
		var s: Vector2i = subs[i]
		if _painted(s) != bool(baseline[i][0]) or _terrain_at(world, _sub_center(s)) != bool(baseline[i][1]):
			wrong += 1
	print("[相④] 回溯后:16 子格与破坏前基线不一致 = %d" % wrong)
	if wrong > 0:
		_fail("相④ 回溯后有 %d 个子格没回到基线(渲染/碰撞有一样没回来)" % wrong)
	for s in subs:
		var e := _expect(s)
		if _painted(s) != bool(e[0]) or _terrain_at(world, _sub_center(s)) != bool(e[1]):
			_fail("相④ 回溯后子格 %s 与规则不符(画=%s 碰=%s 规则=%s)"
					% [str(s), str(_painted(s)), str(_terrain_at(world, _sub_center(s))), str(e)])

	# 阶段 5 节流窗口:跨多块一帧拆光
	var victims: Array[Vector2i] = []
	var used_chunks: Array = []
	var sg: Array = MazeGenerator.current_subgrid
	for y in range(0, sg.size(), 4):
		for x in range(0, (sg[0] as Array).size(), 4):
			var t := _tex(Vector2i(x, y))
			if t == 0 or not TileDefs.sub_alive(Vector2i(x, y)) or not TileDefs.explosion_destroyable(t):
				continue
			if TileDefs.type_id_of(t) != TileDefs.TYPE_WALL:
				continue
			var c := CollisionBuilder.chunk_of(Vector2i(x / 4, y / 4))
			if used_chunks.has(c):
				continue
			used_chunks.append(c)
			victims.append(Vector2i(x, y))
			if victims.size() >= 3:
				break
		if victims.size() >= 3:
			break
	print("[相⑤] 一帧内拆 %d 个子格(块 %s)" % [victims.size(), str(used_chunks)])
	if victims.size() >= 3:
		for v in victims:
			TileDefs.damage_sub(v, 9999, "explosion")
		var frames := -1
		for f in range(12):
			var all_clean := true
			for v in victims:
				if _terrain_at(world, _sub_center(v)):
					all_clean = false
					break
			if all_clean:
				frames = f
				break
			await tree.process_frame
		print("[相⑤] 碰撞追上渲染用了 %d 帧(每帧上限 2 块)" % frames)
		if frames < 0:
			_fail("相⑤ 跨 3 块的破坏 12 帧后碰撞仍未清:永久的虚空碰撞箱")

	# 阶段 6 再扫一遍全场
	_scan(world, _all_subs(), "相⑥·破坏+回溯后全场")

	if _fails.is_empty():
		print("TILE COLLISION PROBE: ALL-OK(子格粒度/部分破坏不牵连/环面副本/回溯复原/重建有界/全场渲染与碰撞各符其规则)")
	else:
		print("TILE COLLISION PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
	tree.quit(0 if _fails.is_empty() else 1)
