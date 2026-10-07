extends Node

# 回溯「虚空碰撞箱」探针(场景级,单机实际关卡场景)。
#
# 背景(2026-10-03 用户报「时间回溯还是会导致有些时候有虚空碰撞箱」):录制期为回溯保留的
# 尸体(`hold_corpses` → 死亡白闪结束后 `visible=false` + 停物理)**只藏了画、没摘碰撞** ——
# 玩家 `collision_mask = 5` 里含敌人层(值 4) ->  一具看不见却仍在层 4 的实体就是"虚空碰撞箱"。
#
# 阶段 1:隐藏尸体仍在玩家 mask 上可被命中吗(物理空间查询,用**玩家自己的 mask**)。
# 阶段 2:可破坏砖 —— 破坏后不得留碰撞(幽灵墙),回溯复原后碰撞必须回来
#      (现有 tile_rewind_probe 只验网格+渲染,**碰撞那一维此前无守卫**)。
# 阶段 3:反向 —— 回溯复活后尸体必须**看得见且碰撞层还原**(不能变成"看不见地穿人")。
# 阶段 4:全场扫描:任何"不可见却仍带碰撞层"的节点(= 虚空碰撞箱的完整定义)一律点出来。
#
# 用法:godot --headless --path . res://tests/probe/rewind_phantom_probe.tscn

var _fails: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


## 在 pos 处放一个 8×8 的查询框,返回命中的 body 列表(mask 由调用方给)。
func _bodies_at(world: World2D, pos: Vector2, mask: int) -> Array:
	var ss := world.direct_space_state
	var ps := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(8, 8)
	ps.shape = rect
	ps.transform = Transform2D(0.0, pos)
	ps.collision_mask = mask
	ps.collide_with_bodies = true
	ps.collide_with_areas = false
	var out: Array = []
	for h in ss.intersect_shape(ps, 16):
		out.append(h.get("collider"))
	return out


## 全场扫描「不可见却仍带碰撞层」的 CollisionObject2D(= 虚空碰撞箱的完整定义)。
## 返回 [[节明确提示, 类名, layer], …]。
func _invisible_collidables(root: Node) -> Array:
	var out: Array = []
	if root is CollisionObject2D:
		var co := root as CollisionObject2D
		if co.collision_layer != 0 and not co.is_visible_in_tree():
			out.append([str(co.get_path()), co.get_class(), co.collision_layer])
	for ch in root.get_children():
		out.append_array(_invisible_collidables(ch))
	return out


## 抽样扫描:既无墙体网格、又无瓦片渲染的格子上,是否仍留着地形碰撞(= 幽灵墙)。
## 返回 [抽样格数, 命中数]。
func _ghost_terrain(world: World2D, grid: Array, wall: TileMapLayer) -> Array:
	var sample := 0
	var ghosts := 0
	for y in range(0, grid.size(), 3):
		for x in range(0, grid[0].size(), 3):
			var v: int = int(grid[y][x])
			if v != 0 and TileDefs.is_blocked(v):
				continue
			var painted := false
			for sy in 4:
				if painted:
					break
				for sx in 4:
					if wall.get_cell_atlas_coords(Vector2i(x * 4 + sx, y * 4 + sy)).x >= 0:
						painted = true
						break
			if painted:
				continue
			sample += 1
			if not _bodies_at(world, Vector2(x * 64 + 32, y * 64 + 32), 1).is_empty():
				ghosts += 1
	return [sample, ghosts]


## 一次完整扫描(不可见碰撞体 + 幽灵墙地形),把问题 append 进 _fails。tag 用于打印。
func _scan(tag: String, lvl: Node, world: World2D, grid: Array, wall: TileMapLayer) -> void:
	var invis := _invisible_collidables(lvl)
	print("[%s] 不可见却带碰撞层的节点 %d 个" % [tag, invis.size()])
	for g in invis:
		print("        %s (%s, layer=%d)" % [g[0], g[1], g[2]])
	if not invis.is_empty():
		_fail("%s:存在不可见却有碰撞层的节点 %d 个(虚空碰撞箱)" % [tag, invis.size()])
	if wall != null and not grid.is_empty():
		var gt: Array = _ghost_terrain(world, grid, wall)
		print("[%s] 幽灵墙抽样:空气格 %d 个,其中仍有地形碰撞 %d 个" % [tag, gt[0], gt[1]])
		if int(gt[1]) > 0:
			_fail("%s:空气中残留地形碰撞 %d 处(虚空碰撞箱)" % [tag, gt[1]])


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	await _wait_ms(500)
	var player: Node2D = lvl.get_node_or_null("WorldViewport/Player") as Node2D
	if player == null or Level0.time_field == null:
		print("REWIND PHANTOM PROBE: FAIL(世界/时间系统未就绪)")
		tree.quit(1)
		return
	var world := player.get_world_2d()
	var player_mask := int((player as CollisionObject2D).collision_mask)
	await _wait_ms(1500)   # 先录一段"死前历史",后面那次回溯才跨得过死亡时刻

	# ── 阶段 1 隐藏尸体是否仍在玩家 mask 上可被命中 ──────────────────
	var target: Node = null
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D) or bool(e.get("is_dead")) or e.has_meta("elite"):
			continue
		target = e
		break
	var corpse_layer := -1
	var corpse_pos := Vector2.ZERO
	if target == null:
		_fail("图上无普通怪(用例前置)")
	else:
		var tref := target
		corpse_layer = int((tref as CollisionObject2D).collision_layer)
		tref.call("hurt", 9999, Vector2.RIGHT, 0.0)
		await _wait_ms(900)   # 死亡白闪 0.5s + 余量 → 应已进入"保留尸体"态
		if not is_instance_valid(tref):
			_fail("目标怪被释放了(未进入尸体保留;用例前置不成立)")
		else:
			corpse_pos = (tref as Node2D).global_position
			var vis: bool = (tref as Node2D).visible
			var layer := int((tref as CollisionObject2D).collision_layer)
			var hits := _bodies_at(world, corpse_pos, player_mask)
			var self_hit := hits.has(tref)
			print("[相①] 尸体 visible=%s is_dead=%s layer=%d 玩家mask=%d 查询命中自身=%s"
					% [str(vis), str(tref.get("is_dead")), layer, player_mask, str(self_hit)])
			if vis:
				_fail("尸体未被隐藏(用例前置不成立)")
			if layer != 0:
				_fail("隐藏尸体仍在层 %d(应为 0):玩家 mask=%d 含它 ⇒ 看不见的墙"
						% [layer, player_mask])
			if self_hit:
				_fail("物理空间查询证实:隐藏尸体仍挡在玩家 mask 上")

	# ── 阶段 4 全场扫描(尸体处于隐藏态时)──────────────────────────
	_scan("相④·尸体隐藏期", lvl, world, MazeGenerator.current_grid, Level0.wall_layer)

	# ── 阶段 2 可破坏砖:破坏 → 回溯复原后的**碰撞**状态 ────────────
	var grid: Array = MazeGenerator.current_grid
	var cell := Vector2i(-1, -1)
	for y in grid.size():
		if cell.x >= 0:
			break
		for x in grid[0].size():
			var v: int = grid[y][x]
			if v != 0 and TileDefs.explosion_destroyable(MazeGenerator.texture_of(v)):
				cell = Vector2i(x, y)
				break
	if cell.x < 0:
		_fail("图上没有可破坏砖(用例前置)")
	else:
		var center := Vector2(cell.x * 64 + 32, cell.y * 64 + 32)
		var before := _bodies_at(world, center, 1)   # 地形层
		await _wait_ms(1000)
		for sy in 4:
			for sx in 4:
				TileDefs.damage_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 9999, "explosion")
		await _wait_ms(300)   # 等脏块重建(每帧最多 2 块)
		var after_destroy := _bodies_at(world, center, 1)
		print("[相②] 格 %s 地形碰撞:破坏前 %d 个 / 破坏后 %d 个"
				% [str(cell), before.size(), after_destroy.size()])
		if before.size() > 0 and after_destroy.size() >= before.size():
			_fail("砖块已炸掉但地形碰撞仍在(%d→%d):幽灵墙"
					% [before.size(), after_destroy.size()])

		# 回溯跨过破坏时刻(2.5s 也跨过尸体死亡时刻)→ 砖块与尸体都应复原
		Input.action_press("rewind")
		await _wait_ms(1200)
		# 阶段 5:回溯**进行中**再扫一遍 —— 回溯期位置由回放器每帧摆,是"虚空碰撞箱"最可能的窗口
		_scan("相⑤·回溯进行中", lvl, world, MazeGenerator.current_grid, Level0.wall_layer)
		await _wait_ms(1300)
		Input.action_release("rewind")
		await _wait_ms(300)
		var painted := 0
		var wall: TileMapLayer = Level0.wall_layer
		if wall != null:
			for sy in 4:
				for sx in 4:
					if wall.get_cell_atlas_coords(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)).x >= 0:
						painted += 1
		var after_rewind := _bodies_at(world, center, 1)
		print("[相②] 回溯后:网格=%d 渲染子格=%d 地形碰撞=%d 个"
				% [int(grid[cell.y][cell.x]), painted, after_rewind.size()])
		if painted > 0 and after_rewind.is_empty():
			_fail("砖块渲染已复原但**碰撞缺失**:能穿进画出来的墙里")
		if painted == 0 and not after_rewind.is_empty():
			_fail("砖块渲染为空但**碰撞还在**:看不见的墙(虚空碰撞箱)")

	# ── 阶段 3 复活方向:尸体必须看得见 + 碰撞层还原 ─────────────────
	if is_instance_valid(target):
		var t2 := target as CollisionObject2D
		var vis2 := (target as Node2D).visible
		var layer2 := int(t2.collision_layer)
		print("[相③] 回溯复活后:visible=%s layer=%d(原层 %d) is_dead=%s"
				% [str(vis2), layer2, corpse_layer, str(target.get("is_dead"))])
		if not bool(target.get("is_dead")):
			if not vis2:
				_fail("复活的怪仍不可见")
			if corpse_layer >= 0 and layer2 != corpse_layer:
				_fail("复活的怪碰撞层未还原(%d ≠ %d):会看不见地穿人" % [layer2, corpse_layer])

	if _fails.is_empty():
		print("REWIND PHANTOM PROBE: ALL-OK(尸体隐藏时已摘碰撞 / 砖块碰撞随破坏与回溯一致 / 复活后层还原 / 无不可见碰撞体)")
	else:
		print("REWIND PHANTOM PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
	tree.quit(0 if _fails.is_empty() else 1)
