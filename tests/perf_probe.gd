extends SceneTree

# 性能诊断 + 可破坏碰撞回归(分块重建)。
#  1) 可破坏层:旧 9× 全图贪心基线 vs 分块构建(计数/覆盖率/单块重建/200 次摧毁)
#  2) N 只飞鸟:障碍收集 + A* + 死区逃逸耗时
#  3) 全场景每帧物理基准(真实 CollisionBuilder 建的永久墙 + 可破坏块 + N 只鸟)
# 用法:godot --headless --path . -s res://tests/perf_probe.gd

func _initialize() -> void:
	TileDefs.load_defs()
	var grid: Array[Array] = MazeGenerator.load_map_file()
	MazeGenerator.current_grid = grid
	if grid.is_empty():
		printerr("no map")
		quit(1)
		return

	var host := Node2D.new()
	host.name = "PerfHost"
	root.add_child(host)

	# ── 1) 可破坏层:基线 / 分块构建 / 覆盖率 / 单块重建 / 200 次摧毁 ──
	var sub: Array[Array] = CollisionBuilder.build_sub(grid, true)
	var baseline := _greedy_count(sub)
	print("[perf] 旧 9× 全图贪心: %d shapes(9 副本合计)" % baseline)
	var total := CollisionBuilder.build_destructible_chunks(sub, host)
	print("[perf] 分块构建: %d shapes(块内不跨块合并,%s)" % [total, "≥旧" if total >= baseline else "BUG"])
	var ok := _verify_coverage(host, sub)
	print("[perf] 覆盖率(中心副本并集 == 实心子格): %s" % ("通过" if ok else "失败!"))
	var wall_total := CollisionBuilder.build_permanent(
			CollisionBuilder.build_sub(grid, false), host, "WallCollision")

	# 单块重建计时(取一个含可破坏砖的块)
	var probe_chunk := Vector2i.ZERO
	var found := false
	for y in range(sub.size()):
		for x in range(sub[0].size()):
			if sub[y][x] != MazeGenerator.EMPTY:
				probe_chunk = CollisionBuilder.chunk_of(Vector2i(x / 2, y / 2))
				found = true
				break
		if found:
			break
	var n_rep := 50
	var t_r0 := Time.get_ticks_usec()
	var last_count := 0
	for i in range(n_rep):
		last_count = CollisionBuilder.rebuild_chunk(sub, probe_chunk, host)
	var t_r1 := Time.get_ticks_usec()
	print("[perf] 单块重建均值: %.3f ms(%d 次, %d shapes)" % [(t_r1 - t_r0) / 1000.0 / n_rep, n_rep, last_count])

	# 模拟连续摧毁 200 格:网格副本与子格同步清空,只重建所在块;每 50 格验覆盖率
	var grid2: Array[Array] = []
	for row in grid:
		grid2.append(row.duplicate())
	var cells: Array[Vector2i] = []
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			var tex: int = MazeGenerator.texture_of(grid[y][x])
			if tex != 0 and (TileDefs.bullet_destroyable(tex) or TileDefs.explosion_destroyable(tex)):
				cells.append(Vector2i(x, y))
	var t_d0 := Time.get_ticks_usec()
	var cover_fail := 0
	var destroy_total := 0
	for k in range(200):
		var cell := cells[(k * 37) % cells.size()]
		grid2[cell.y][cell.x] = 0
		for qy in range(2):
			for qx in range(2):
				sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		CollisionBuilder.rebuild_chunk(sub, CollisionBuilder.chunk_of(cell), host)
		if k % 50 == 0:
			if not _verify_coverage(host, sub):
				cover_fail += 1
		destroy_total += 1
	var t_d1 := Time.get_ticks_usec()
	print("[perf] 200 次摧毁重建总计: %.0f ms(均值 %.2f ms/次), 覆盖率失败 %d 次" % [
		(t_d1 - t_d0) / 1000.0, (t_d1 - t_d0) / 1000.0 / destroy_total, cover_fail])

	# ── 1b) 攀爬基座薄碰撞条(仅锁链顶/底;梯顶不加——会挡从下方爬升) ──
	var c_count := 0
	var e_count := 0
	for y in range(grid.size()):
		for x in range(grid[y].size()):
			var tex: int = MazeGenerator.texture_of(grid[y][x])
			if tex == 12:
				c_count += 1
			elif tex == 14:
				e_count += 1
	var expect_ledges: int = (c_count + e_count) * 9
	var ledges := CollisionBuilder.build_climb_ledges(grid, host)
	print("[perf] 攀爬基座: 链顶%d + 链底%d = %d(×9=%d), ClimbLedges %d shapes, %s" % [
		c_count, e_count, c_count + e_count,
		expect_ledges, ledges, "一致" if ledges == expect_ledges else "不一致!"])
	var ledge_node := host.get_node_or_null("ClimbLedges") as StaticBody2D
	var pos_ok := true
	if ledge_node != null:
		for s in ledge_node.get_children():
			if not (s is CollisionShape2D):
				continue
			var rem := posmod(int((s as CollisionShape2D).position.y), 64)
			if rem != 3 and rem != 61:
				pos_ok = false
				printerr("[perf] 薄条 y%%64=%d 位置异常" % rem)
	print("[perf] 薄条位置检查(y%%64∈{3顶,61底}): %s" % ("通过" if pos_ok else "失败"))

	# ── 2) 飞鸟寻路 ──
	var fly_scene: PackedScene = load("res://scenes/enemies/EnemyFlyBird.tscn")
	var player := Node2D.new()
	player.name = "StubPlayer"
	player.add_to_group("player")
	root.add_child(player)
	player.global_position = Vector2(56 * 64 + 32, 47 * 64 + 32)

	for count in [10, 20, 40]:
		for old in get_nodes_in_group("enemies"):
			old.queue_free()
		await physics_frame
		var birds: Array = []
		for i in range(count):
			var fb := fly_scene.instantiate()
			root.add_child(fb)
			var ang := float(i) / float(count) * TAU
			fb.global_position = player.global_position + Vector2(cos(ang), sin(ang) * 0.6) * 250.0
			birds.append(fb)
		var ct0 := Time.get_ticks_usec()
		var n_coll := 20
		for i in range(n_coll):
			for fb in birds:
				fb._collect_obstacles()
		var ct1 := Time.get_ticks_usec()
		var at0 := Time.get_ticks_usec()
		var n_astar := 20
		for i in range(n_astar):
			birds[0]._collect_obstacles()
			birds[0]._repath_to(MazeGenerator.cell_of(birds[0].global_position, 64, 125, 75) + Vector2i(3, -2))
		var at1 := Time.get_ticks_usec()
		var et0 := Time.get_ticks_usec()
		birds[0]._collect_obstacles()
		var esc: Vector2 = birds[0]._find_escape_column()
		var et1 := Time.get_ticks_usec()
		var raw0 := Time.get_ticks_usec()
		for i in range(n_astar):
			MazeGenerator.astar_path_nearest(Vector2i(10, 10), Vector2i(110, 60))
		var raw1 := Time.get_ticks_usec()
		var box_avg := 0
		for fb in birds:
			box_avg += fb._obstacle_boxes.size()
		print("[perf] %d 只鸟: 障碍收集 %.3f ms/只, A*(带障碍) %.3f ms/次, 死区逃逸 %.1f ms, 纯A*基准 %.3f ms/次, 平均障碍箱 %d" % [
			count, (ct1 - ct0) / 1000.0 / (n_coll * count),
			(at1 - at0) / 1000.0 / n_astar,
			(et1 - et0) / 1000.0,
			(raw1 - raw0) / 1000.0 / n_astar,
			box_avg / count])
	for old in get_nodes_in_group("enemies"):
		old.queue_free()
	await physics_frame

	# ── 3) 全场景每帧物理基准(真实 CollisionBuilder 碰撞)──
	var host2 := Node2D.new()
	host2.name = "PerfHost2"
	root.add_child(host2)
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), host2, "WallCollision")
	CollisionBuilder.build_destructible_chunks(CollisionBuilder.build_sub(grid, true), host2)

	for count in [0, 20, 40]:
		for old in get_nodes_in_group("enemies"):
			old.queue_free()
		await physics_frame
		var combat := _make_player_stub()
		combat.global_position = Vector2(56 * 64 + 32, 47 * 64 + 32)
		root.add_child(combat)
		var birds2: Array = []
		for i in range(count):
			var fb := fly_scene.instantiate()
			root.add_child(fb)
			var ang := float(i) / float(maxf(count, 1.0)) * TAU
			fb.global_position = combat.global_position + Vector2(cos(ang), sin(ang) * 0.6) * 300.0
			birds2.append(fb)
		for i in range(180):
			await physics_frame
		var f0 := Time.get_ticks_usec()
		var n_frames := 240
		for i in range(n_frames):
			await physics_frame
		var f1 := Time.get_ticks_usec()
		var awake := 0
		for fb in birds2:
			if fb.state != 0:
				awake += 1
		print("[perf] %d 只鸟: 平均帧 %.3f ms (%d 醒)" % [count, (f1 - f0) / 1000.0 / n_frames, awake])
		for fb in birds2:
			fb.queue_free()
		combat.queue_free()
		await physics_frame

	host2.free()
	player.free()
	host.free()
	print("[perf] DONE")
	quit(0)


# 旧 9× 全图贪心计数(基线;每副本一块,返回中心副本 rect 数,×9 = 总 shape 数)。
func _greedy_count(sub: Array[Array]) -> int:
	var scols = sub[0].size()
	var srows = sub.size()
	var total := 0
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var used: Array[Array] = []
			for _r in range(srows):
				var urow: Array[bool] = []
				urow.resize(scols)
				urow.fill(false)
				used.append(urow)
			for y in range(srows):
				for x in range(scols):
					if sub[y][x] == MazeGenerator.EMPTY or used[y][x]:
						continue
					var x2 := x
					while x2 + 1 < scols and sub[y][x2 + 1] != MazeGenerator.EMPTY and not used[y][x2 + 1]:
						x2 += 1
					var y2 := y
					while y2 + 1 < srows:
						var can := true
						for cx in range(x, x2 + 1):
							if sub[y2 + 1][cx] == MazeGenerator.EMPTY or used[y2 + 1][cx]:
								can = false
								break
						if not can:
							break
						y2 += 1
					for ry in range(y, y2 + 1):
						for rx in range(x, x2 + 1):
							used[ry][rx] = true
					total += 1
	return total


# 验证中心副本碰撞形状的覆盖并集 == 子格实心集合(实心必须被覆盖,非实心不能被覆盖)。
func _verify_coverage(parent: Node, sub: Array[Array]) -> bool:
	var scols = sub[0].size()
	var srows = sub.size()
	var ts: int = CollisionBuilder.SUB_TS
	var map_w: int = scols * ts
	var map_h: int = srows * ts
	var covered: Array[Array] = []
	for _r in range(srows):
		var c: Array[bool] = []
		c.resize(scols)
		c.fill(false)
		covered.append(c)
	for child in parent.get_children():
		if not (child is StaticBody2D):
			continue
		if not String(child.name).begins_with("DestructibleChunk_"):
			continue
		for s in child.get_children():
			if not (s is CollisionShape2D):
				continue
			var cs := s as CollisionShape2D
			var shp := cs.shape
			if not (shp is RectangleShape2D):
				continue
			var pos := cs.position
			if pos.x < -0.5 or pos.x >= map_w or pos.y < -0.5 or pos.y >= map_h:
				continue  # 只算中心副本(跳过 9 副本里的偏移副本)
			var size := (shp as RectangleShape2D).size
			var r := Rect2(pos - size * 0.5, size)
			var x0 := maxi(floori(r.position.x / ts), 0)
			var y0 := maxi(floori(r.position.y / ts), 0)
			var x1 := mini(ceili((r.position.x + r.size.x) / ts), scols)
			var y1 := mini(ceili((r.position.y + r.size.y) / ts), srows)
			for y in range(y0, y1):
				for x in range(x0, x1):
					covered[y][x] = true
	for y in range(srows):
		for x in range(scols):
			var solid: bool = sub[y][x] != MazeGenerator.EMPTY
			if solid != covered[y][x]:
				return false
	return true


# 带碰撞体的玩家桩(站层2,入 player 组)。
class StubPlayer2:
	extends CharacterBody2D
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(40, 40)
		shape.shape = rect
		add_child(shape)
	func take_hit(_source_pos: Vector2, _damage: int, _ignore_iframes: bool = false) -> void:
		pass
	func is_downed() -> bool:
		return false

func _make_player_stub() -> CharacterBody2D:
	return StubPlayer2.new()
