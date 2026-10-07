extends Node

# 「重连状态补充同步:先还原基线、再应用 destroyed」的**真行为**守卫。
# 跑法: timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/resync_world_probe.tscn
# 通过 = 文本 `RESYNC WORLD PROBE: ALL-OK` 退出 0(判据是**文本**,不是退出码 —— 场景探针在脚本
#   报错时 `--quit-after` 到点照样 exit 0,只看退出码会把"根本没跑完"读成"通过")。
#
# ═══ 守的是什么 ═══
# `match_sync` 的 `destroyed` 表达的是「与**建局基线**不同的格」。客户端在宽限期内**错过一次换局**时,
# 服务器那次 `_reset_world_and_clear_dynamics()` 已经把可破坏砖还原成基线  ->  那些格等于基线、
# **永不进载荷**  ->  客户端本地留着上一局拆出来的破洞 = **幻影空洞**(服务器上那里是实心墙)。
# 客户端唯一的还原路径是新回合 COUNTDOWN 里的 `Level0.reset_destructibles()`(见
# `pvp_game._on_round_state`),而重连回来时那一局可能**已经打到 PLAYING** → 那条分支不触发。
# 修法 = 状态补充同步那一路**先** `reset_destructibles()` **再**应用 `destroyed`(因为 destroyed 相对基线,
# 两者合起来恰好等于服务器的 grid,不上线任何新字节)。
#
# - 判据覆盖**三维**,缺一维就有一种退化实现能测试全部通过:
#   - `MazeGenerator.current_grid`(逻辑)
#   - 墙体瓦片层(用户**看得见**的那一维)
#   - `Level0._destructible_sub` 子格(物理摸得着的那一维)
#   只断 grid → `reset_destructibles()` 哪天退化成"只改 grid、不重铺瓦片也不重建碰撞"照样测试全部通过,
#   而画面上仍是个洞、物理上仍能穿过去(客户端以为修好了、用户看见的没修)。
#
# ═══ 为什么不是真实网络链路断言,也不是源码级断言 ═══
# - 真实网络链路要造出「换局正好落在宽限期内」:1v1 一局得先到 5 杀才结束,现成探针里没有便宜手段,
#   而"不许为测试新造产品开关"是硬约束 → 真实网络链路不可得(见报告)。
# - 源码级(如 tests/smoke/reconnect_smoke.gd 那种 grep)只能判"那行字在不在",判不了**行为**:
#   顺序写反(先应用、后还原)、或门控前置校验写错(读了两遍 `_resync_pull_pending`,第二遍必 false)
#   这三种坏法里,后两种照样能通过任何"字符串在位"式的断言。
# - 所以退到**真对象 + 真函数**:真 `Level0`(pvp_mode、真地图、真碰撞、真 `_pristine_grid`)
#   + 真 `PvpMatchClient._on_match_sync`(直接调那**一个**函数 —— 它只读 `_level0`/`_world`/
#   `PvpSession`,与"是否真的连在网上"无关)。相同机制手法见 `ground_action_probe`(真 MatchHost、
#   role_peers 传空)与 `destroyed_cells_probe`。

const MAP := "res://maps/newfactory.cyrm"

var _fails: Array[String] = []
var _client: PvpMatchClient = null
var _level0: Node = null
var _ran_to_end := false          # 防"脚本中途报错 → 无失败项的 ALL-OK"(测试漏检守卫)

var _a := Vector2i(-1, -1)        # 客户端上一局拆过、而服务器换局已还原的格(**不在**载荷里)
var _b := Vector2i(-1, -1)        # 掉线窗口内被服务器拆的格(**在**载荷里)
var _a_pristine := 0
var _b_pristine := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	# 与客户端 `_ready` 同一套建世界的姿势(见 pvp_game.gd:31-40)
	MazeGenerator.set_map_file(MAP)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	_level0 = load("res://scenes/level_0.tscn").instantiate()
	add_child(_level0)
	await _run()
	_finish()


func _run() -> void:
	# 等 Level0 `_ready` 的 `_build_wall_collision.call_deferred(grid)` 落地 ——
	# 不等的话它会在本探针之后又整层重铺一次碰撞。
	for i in 4:
		await get_tree().process_frame
	var grid := MazeGenerator.current_grid
	_check(not grid.is_empty(), "世界已建(网格非空)")
	if grid.is_empty():
		return
	# 真实客户端实例实例:两个子类都 extends PvpMatchClient 且**都没覆写 `_on_match_sync`**,
	# 故直接实例化基类跑的就是生产那一份实现(空载荷不会碰到两个"必须覆写"的虚函数)。
	_client = PvpMatchClient.new()
	add_child(_client)
	_client._level0 = _level0
	_client._world = _level0.get_node("WorldViewport")
	_client._local = _client._world.get_node("Player")

	# ── ① 挑两格**可被爆炸破坏**的砖:载荷里放 B、不放 A ──
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var picked: Array[Vector2i] = []
	for y in rows:
		for x in cols:
			var v: int = grid[y][x]
			if v == 0:
				continue
			if TileDefs.explosion_destroyable(MazeGenerator.texture_of(v)):
				# - 额外要求该格在**基线**里就有碰撞子格(形状非 0 的实体砖):③ 里要断言
				#   "还原之后子格回来了",而形状 0 的格在基线里本来就是 0 → 那条断言会**恒假**
				#   (与"还原没生效"长得一样)。要的是"能被清掉、也该被还原"的格。
				if _sub_at(Vector2i(x, y)) == 0:
					continue
				picked.append(Vector2i(x, y))
				if picked.size() >= 2:
					break
		if picked.size() >= 2:
			break
	_check(picked.size() == 2, "地图里找到两格可破坏砖(%s)" % str(picked))
	if picked.size() < 2:
		return
	_a = picked[0]
	_b = picked[1]
	_a_pristine = int(grid[_a.y][_a.x])
	_b_pristine = int(grid[_b.y][_b.x])
	# - 非无效操作前置:B 的基线必须是**实心** —— 否则"应用 destroyed"那一步的判据(下面 ④)
	#   会与"什么都没做"长得一样(空气改空气 = 零差异),顺序写反也照样绿。
	_check(_a_pristine != 0 and _b_pristine != 0,
			"两格在基线里都是实心(A=%d,B=%d)—— 前置:证明下面几条判的是真的差异" % [_a_pristine, _b_pristine])

	# ── ② 造出"客户端与基线不一致"的现场:A、B 都在本地被拆掉 ──
	# 走**真实客户端实例的真路径**(`_on_remote_tile_destroyed` = 服务器拆墙事件/换局状态补充同步共用的那一个),
	# 不是直接改网格。
	_client._on_remote_tile_destroyed(_a, true)
	_client._on_remote_tile_destroyed(_b, true)
	_check(_grid_at(_a) == 0 and _grid_at(_b) == 0,
			"前置:本地这两格都已拆掉(A=%d,B=%d)" % [_grid_at(_a), _grid_at(_b)])
	# - 非无效操作前置(瓦片层/碰撞维度):A 的**瓦片**与**碰撞子格**也真的被清掉了 —— 否则 ③ 里
	#   那条"还原之后确实重铺回来了"与"这一格从来没被动过"长得一模一样,退化实现照样能绿。
	_check(_tile_source_at(_a) == -1 and _sub_at(_a) == 0,
			"前置:A 的瓦片(cell_source_id=%d)与碰撞子格(%d)都已清掉" %
			[_tile_source_at(_a), _sub_at(_a)])

	# ── ③ 状态补充同步那一路:先还原基线、再应用载荷(A **不在**载荷里 = 上一局拆的、服务器已还原)──
	_client._resync_pull_pending = true
	_client._on_match_sync({"destroyed": [_b]})
	_check(_grid_at(_a) == _a_pristine,
			"★ 幻影空洞被填回:不在载荷里的 A (%s) 回到基线(%d,实得 %d)—— 去掉「先还原」那一行即红" %
			[str(_a), _a_pristine, _grid_at(_a)])
	_check(_grid_at(_b) == 0,
			"★ 载荷里的 B (%s) 仍是被拆的(实得 %d)—— 顺序写反(先应用、后还原)会把它一并填回去" %
			[str(_b), _grid_at(_b)])
	# 注意： 同一条"还原真的发生了"的判据,**换到用户看得见/物理摸得着的那两维**上再过一遍:
	#   上面两条只读 `MazeGenerator.current_grid` —— 若 `reset_destructibles()` 哪天退化成
	#   "只改 grid、不重铺瓦片也不重建碰撞",grid 那两条**照样测试全部通过**,而客户端画面上仍是个洞
	#   (瓦片层)、物理上仍能穿过去(碰撞层)。也就是"客户端以为修好了、用户看见的没修"。
	#   这里同时钉两维:`_on_tile_destroyed` 清的是 9 份环面副本的瓦片 + 该格 2×2 子格,
	#   而 `reset_destructibles()` 重铺瓦片(`_paint_maze`)+ 整层重建碰撞(`build_sim`)。
	_check(_tile_source_at(_a) != -1 and _sub_at(_a) != 0,
			"★ A 的瓦片(cell_source_id=%d)与碰撞子格(%d)真的重铺回来了(前置已证还原前这两样是空的)" %
			[_tile_source_at(_a), _sub_at(_a)])

	# ── ④ 进场那一路**不许**还原(门控前置校验必须是那个读一次即清的 `resync`)──
	# 反过来:若有人把还原写成无条件的,这里红。
	_client._on_remote_tile_destroyed(_a, true)
	_client._resync_pull_pending = false
	_client._on_match_sync({})
	_check(_grid_at(_a) == 0,
			"进场那一路不还原(闸门没被写成无条件):A 仍是拆掉的(实得 %d)" % _grid_at(_a))

	_ran_to_end = true


func _grid_at(cell: Vector2i) -> int:
	var g := MazeGenerator.current_grid
	if g.is_empty() or cell.y < 0 or cell.y >= g.size():
		return -1
	var row: Array = g[cell.y]
	if cell.x < 0 or cell.x >= row.size():
		return -1
	return int(row[cell.x])


# 墙体瓦片层里该格的纹理源 id(-1 = 该格没有瓦片)。铺的是 9 份环面副本,中心那份就是原坐标。
# - 读的是**渲染**那一维:`grid` 说"这格是墙"不等于**画出来了** —— `_paint_maze` 才是。
func _tile_source_at(cell: Vector2i) -> int:
	var wl: TileMapLayer = Level0.wall_layer
	if wl == null:
		return -1
	# 注意： 2026-10-02 合并修订说明:`_paint_maze` 在 cyrm v4(B18)里改成铺 **16px 子格**了
	#    ->  该层的坐标是**子格**坐标,不是 64px 格坐标。原实现直接拿格坐标去查  ->  恒 -1
	#   (② 的前置那条 `== -1` 因此**恒真**、③ 那条恒假)。这里按同样推导出来的比例展开,
	#   任一子格有砖就返回它的 source id。
	var per: int = CollisionBuilder.TILE_TS / CollisionBuilder.SUB_TS
	var sx := cell.x * per
	var sy := cell.y * per
	for dy in per:
		for dx in per:
			var sid := wl.get_cell_source_id(Vector2i(sx + dx, sy + dy))
			if sid != -1:
				return sid
	return -1


# 持久可破坏层里该 64px 格覆盖的那一块子格:**任一**非零就返回它,全零返回 0
# (-1 = 越界 / 该层还没建)。
# - 读的是**物理**那一维:`_on_tile_destroyed` 把这些子格清零,`reset_destructibles` 靠
#   `WorldBuilder.build_sim` 整层重建 —— 只改 grid 的退化实现不会让这里恢复。
# 注意： 2026-10-02 合并修订说明:子格边长**从 `CollisionBuilder` 推导**,不写死乘数。
#   原实现写的是 `cell * 2`(32px 子格 / 每格 2×2),而 cyrm v4(B18)已把破坏下沉到
#   **16px(每格 4×4)**  ->  它**一直在取错格**;换 PvP 地图后 ② 的前置断言才把它暴露异常
#   (它读到的是别的子格,而 `_on_remote_tile_destroyed` 清的是本格那 16 个)。
#   - 顺带把"只看左上那一个子格"改成"整格任一非零":4×4 下左上子格只代表 1/16,
#   不足以支撑"这一格有碰撞"这个判据。
func _sub_at(cell: Vector2i) -> int:
	var sub: Array[Array] = Level0._destructible_sub
	if sub.is_empty():
		return -1
	var per: int = CollisionBuilder.TILE_TS / CollisionBuilder.SUB_TS
	var sy := cell.y * per
	var sx := cell.x * per
	if sy < 0 or sy >= sub.size():
		return -1
	if sx < 0 or sx >= (sub[sy] as Array).size():
		return -1
	for dy in per:
		var y := sy + dy
		if y >= sub.size():
			break
		var row: Array = sub[y]
		for dx in per:
			var x := sx + dx
			if x >= row.size():
				break
			if int(row[x]) != 0:
				return int(row[x])
	return 0


func _finish() -> void:
	if not _ran_to_end:
		print("RESYNC WORLD PROBE: FAIL")
		print("  - _run() 没跑完(中途脚本错误?)—— 无失败项的 `ALL-OK` 在这情况下是假绿")
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("RESYNC WORLD PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("RESYNC WORLD PROBE: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)
