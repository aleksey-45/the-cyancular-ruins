extends Node

# 建筑(可破坏砖)碰撞守卫:碰撞必须**逐 16px 子格**与"游戏自己的规则"一致。
# 存在理由:破坏/回溯这条链上**碰撞那一维此前完全没有守卫** —— `tile_rewind_probe` 只验
# 「网格 + 渲染层 atlas」,照不到"砖没了碰撞还在"(看不见的墙 = 虚空碰撞箱)与"砖画着却撞不着"。
#
# 判据取**游戏自己的两条规则**(不是另写一套):
#   渲染  = `_paint_maze` 的规则:tex != 0 且 非液体 且 子格存活
#   碰撞  = `CollisionBuilder.build_sub` 的规则:tex 是 wall 且 子格存活
#   ★ 例外:锁链顶/底有 **64px 全宽 6px 薄碰撞条**(`build_climb_ledges`),它不来自子格 →
#     凡 3×3 子格邻域里出现链纹理(12/13/14)的采样点**整点跳过**(保守,宁可少验)。
#
# 相① 选中一个"可破坏且存活"的子格:它必须同时有渲染与碰撞
# 相② 只拆它 → 两侧同时消失,同格其它子格**不受牵连**
# 相③ 拆光该 64px 格里所有存活的可破坏子格 → 全无;并验 **9 环面副本**(±MAP 偏移)
# 相③b 走**格级**那条链(激光真调的 `damage_tile`):打光整格后渲染/碰撞/`sub_hp` 必须一起没。
#      ★ 与相②/③ 的区别:那两相走 `damage_sub`(逐子格),照不到"格级回调无人接"这条链 ——
#      单机侧此前只有服务器接了 `TileDefs.on_destroyed` ⇒ 整格已碎、16 子格仍 `sub_alive`
#      (幽灵砖),而本文件与另外三条探针**全绿**。
# 相④ 回溯复原 → 逐子格回到基线(渲染与碰撞都对上),环面副本一并回来
# 相④b 相③b 那一格在回溯后**连格级 `hp_grid` 一起**回满血(否则复原后下一发激光一发即碎);
#      判据是**拆前快照**(不是 `_expect`:后者按活的 `sub_hp` 判,"没被复原"与"本来就没有"同假 ⇒ 半复原会假过)
# 相⑤ 节流窗口:一帧内拆跨 **多块**(> MAX_REBUILD_PER_FRAME=2)的砖 → 数出碰撞追上渲染要几帧;断言有界
# 相⓪/相⑥ 全场抽样(每 8 个子格一点):**渲染与碰撞各自与规则逐点相等** —— 这一相就是
#      「建筑有没有虚空碰撞箱」的直接回答,破坏+回溯之后再扫一遍
#
# 用法:godot --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn

const STRIDE := 8   # 全场抽样步长(子格);8 子格 = 128px = 2 格

var _fails: Array[String] = []
var _skipped := 0
var _sampled := 0
# ★ 跑完闩(`destroyed_cells_probe.gd:18-22` 的先例):`_run()` 里任何**运行期**脚本错误会让
#   GDScript 当场从 `_run()` 返回,而 `_fails` 还是空的 ⇒ 若无此闩,裁决会把"没跑完"打成
#   `ALL-OK`。判据是 grep 文本 `TILE COLLISION PROBE: ALL-OK`,所以 `ALL-OK` 必须真的意味着
#   "跑完了且全过"。由 `_run()` 最后一行置真;早退(前置不成立)也置真 —— 那是**明确结论**,
#   不是"没跑完"。
var _ran_to_end := false


func _ready() -> void:
	_go.call_deferred()


# `_run()` 有 `await`,裁决不能跟它同一层(见 `_ran_to_end` 的注释):跑完(或被错误中断)后
# 回到这里,才判跑完闩。
func _go() -> void:
	await _run()
	_finish()


func _finish() -> void:
	if not _ran_to_end:
		print("TILE COLLISION PROBE: FAIL(_run() 没跑完(中途脚本错误?)—— 无失败项的 ALL-OK 在这情况下是假绿)")
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("TILE COLLISION PROBE: ALL-OK(子格粒度/部分破坏不牵连/格级销毁无幽灵砖/环面副本/回溯复原(含格级 HP)/重建有界/全场渲染与碰撞各符其规则)")
	else:
		print("TILE COLLISION PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
	get_tree().quit(0 if _fails.is_empty() else 1)


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


## 找一个"可破坏、存活"的子格(优先整格都活的,便于相③)。
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
		# ★ 早退也要置跑完闩:这是**明确结论**(前置不成立),不是"中途出错没跑完"。
		#   绝不在这里自带 `quit()` —— 那会让 `_finish()` 随后照常打一条 `ALL-OK`(假绿)。
		_fail("世界未就绪(玩家/瓦片层/时间场缺一)")
		_ran_to_end = true
		return
	var world := player.get_world_2d()
	var mx := float(GameParameters.MAP_WIDTH)

	# 相⓪ 全场抽样
	_scan(world, _all_subs(), "相⓪·初始全场")

	# 相① 目标子格
	var target := _find_target()
	if target.x < 0:
		_fail("图上没有可破坏的子格,用例前置不成立")
		_ran_to_end = true
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

	# 相② 只拆它
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

	# 相③ 拆光该格所有存活的可破坏子格
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

	# ── 相③b 格级路径:激光真调的 API(`damage_tile`)打光整格 ⇒ 渲染/碰撞/hp 必须一起没 ──
	# 存在理由:该探针此前的破坏全走 `damage_sub`(相②/③/⑤),而**格级**这条链单机根本没接回调
	# ⇒ "整格已碎、16 子格仍 sub_alive"的幽灵砖在本探针与另外三条探针下**全绿**。
	# ★ 选点要求三条:① 该格 16 子格全 `sub_alive` 且纹理非 0;② 纹理 `explosion_destroyable`
	#   (激光传的 source 就是 "explosion";不满足则 `damage_tile` 第一行 return = 断言恒真);
	#   ③ 与相① 选中的格不同(别把相③ 的后果混进来)。
	var cell3b := Vector2i(-1, -1)
	var subs3b: Array = []
	# ★ `base3b` 必须在**函数作用域**声明(相④b 要用它):声明在下面的 `else:` 块里的话
	#   GDScript 的块作用域会让相④b 看不见它。
	var base3b: Array = []
	for y in MazeGenerator.current_subgrid.size():
		for x in (MazeGenerator.current_subgrid[0] as Array).size():
			var cc := Vector2i(x / 4, y / 4)
			if cc == cell:
				continue
			var all_alive := true
			var tex3b := 0
			for s in _cell_subs(cc):
				if not TileDefs.sub_alive(s) or _tex(s) == 0:
					all_alive = false
					break
				tex3b = _tex(s)
			if all_alive and TileDefs.explosion_destroyable(tex3b) \
					and TileDefs.type_id_of(tex3b) == TileDefs.TYPE_WALL:
				cell3b = cc
				subs3b = _cell_subs(cc)
				break
		if cell3b.x >= 0:
			break
	if cell3b.x < 0:
		_fail("相③b 找不到一整格全活的可爆砖(用例前置不成立)")
	else:
		for s in subs3b:
			base3b.append([_painted(s), _terrain_at(world, _sub_center(s))])
		# ★ 前置:格级那条 API 真收下了这一格。上面选点验的是**子格**纹理,而 `damage_tile`
		#   验的是**格级**纹理(`flatten_scene` 取 16 子格里出现最多的非零者)—— 两者一旦分家
		#   (如将来给液体开可爆),`damage_tile` 首行就 return ⇒ 下面几条**全恒真**。
		if not TileDefs.damage_tile(cell3b, 999999, "explosion"):
			_fail("相③b 格级 damage_tile 拒收格 %s(选点前置不成立 ⇒ 下面几条恒真)" % str(cell3b))
		await _wait_ms(300)                       # 脏块分帧重建(与相② 同款等待)
		var ghost := 0
		for s in subs3b:
			if _painted(s):
				ghost += 1
		if ghost != 0:
			_fail("相③b 格级销毁后仍有 %d/16 子格在画(幽灵砖)" % ghost)
		# ★ 子格碰撞与"墙会不会长回来"的**真相源**是 `sub_hp`(`CollisionBuilder.build_sub`
		#   按 `sub_alive` 判定,`WorldBuilder.build_sim` 在复位时按基线重算它)—— 不是渲染层、
		#   也不是 `_destructible_sub`。只清后两者时:`ghost`/格心碰撞/相④/相⑥ **全绿**
		#   (相④ 回溯会把渲染与碰撞用 `pre_hp` 原样还原,相⑥ 又拿 `sub_alive` 当规则),
		#   只有这一条照得出来。去掉 `destroy_cell` 里那句 `restore_sub(sub, 0)` ⇒ 必红。
		var still_alive := 0
		for s in subs3b:
			if TileDefs.sub_alive(s):
				still_alive += 1
		if still_alive != 0:
			_fail("相③b 格级销毁后仍有 %d/16 子格 sub_alive(sub_hp 未清 ⇒ 复位时墙会长回来)"
					% still_alive)
		# ★ 逐子格与"游戏自己的两条规则"对账(同相⓪/⑥ 的口径):**清了一维、漏了另一维**
		#   (只清 `_destructible_sub` / 只清渲染,不写 `sub_hp`)必被这里的计数抓住。
		_scan(world, subs3b, "相③b·格级销毁后")
		var c3b := Vector2(cell3b.x * 64 + 32, cell3b.y * 64 + 32)
		if _terrain_at(world, c3b) or _terrain_at(world, c3b + Vector2(mx, 0.0)) \
				or _terrain_at(world, c3b - Vector2(mx, 0.0)):
			_fail("相③b 格级销毁后格心(含 ±MAP_WIDTH 副本)仍有碰撞(看不见的墙)")
		if TileDefs.hp_grid[cell3b.y][cell3b.x] != 0:
			_fail("相③b 格级销毁后 hp_grid[%s] 应为 0(实得 %d)"
					% [str(cell3b), TileDefs.hp_grid[cell3b.y][cell3b.x]])
		print("[相③b] 格级销毁目标格 %s(基线已记 %d 项)残留画=%d 仍活=%d"
				% [str(cell3b), base3b.size(), ghost, still_alive])

	# 相④ 回溯复原
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

	# ── 相④b 相③b 那一格在回溯后必须连 hp_grid 一起回来 ──
	# ★ 复用 Task 2 留下的 cell3b / subs3b / base3b,并复用相④ 的**那一次**回溯(不自己再按 rewind:
	#   冷却与历史长度不由本探针控制)。
	# ★ 这里**必须拿拆前快照**(`base3b`)比对,**不能**改用 `_expect` 与规则对账:`_expect` 读的是
	#   **活的 `sub_hp`**,而"没被复原的子格"在它眼里正是"本来就不该有" ⇒ 两边**同时为假** ⇒
	#   半复原(账本只回放 k<16 条)会判过。快照才是独立基准(它记的是"拆**前**长这样")。
	var back_wrong := 0
	for i in subs3b.size():
		var s: Vector2i = subs3b[i]
		if _painted(s) != bool(base3b[i][0]) or _terrain_at(world, _sub_center(s)) != bool(base3b[i][1]):
			back_wrong += 1
	if cell3b.x >= 0:
		# 纹理表 `current_subgrid` 从不被破坏改动 ⇒ 回溯后读它与破坏前同值,可当满血基准
		# ★ 前提:该格 16 子格**同纹理**(格级基线取的是多数纹理)—— 两张在库图实测无混纹理格
		#   (该实测是离线做的、**未随探针固化**,边界登记见 docs/eng/registered-debt.md §六)
		var want3b := TileDefs.hp_of(_tex(subs3b[0]))
		print("[相④b] 相③b 那格回溯后与拆前基线不符 %d/16,hp_grid=%d(应 %d)"
				% [back_wrong, TileDefs.hp_grid_at(cell3b), want3b])
		if back_wrong != 0:
			_fail("相④b 回溯后相③b 那格有 %d/16 个子格与拆前基线不符(渲染/碰撞有一样没回来)" % back_wrong)
		if TileDefs.hp_grid_at(cell3b) != want3b:
			_fail("相④b 回溯后 hp_grid[%s] 应回到 %d(实得 %d)⇒ 下一发激光会一发即碎"
					% [str(cell3b), want3b, TileDefs.hp_grid_at(cell3b)])

	# 相⑤ 节流窗口:跨多块一帧拆光
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

	# 相⑥ 再扫一遍全场
	_scan(world, _all_subs(), "相⑥·破坏+回溯后全场")

	_ran_to_end = true   # ← 只有走到这里才算"跑完"(裁决在 _finish,见文件头的跑完闩)
