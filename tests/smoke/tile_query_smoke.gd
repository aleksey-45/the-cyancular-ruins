extends SceneTree

# 场景瓦片碰撞与障碍物探测逻辑冒烟测试：
# 验证 TileQuery 在 64px 网格与 16px 子格上的瓦片阻挡查询算法一致性。

const TS := 64   # = GameParameters.TILE_SIZE;-s 脚本自身不能引 autoload,故写字面量

var _fail := 0


func _initialize() -> void:
	TileDefs.load_defs()   # 需要真实属性表才能区分"墙"与"水"

	# 合成 6×6 图(边长 384px):第 0 列整列是墙,右下角一格水(纹理 21 -> (5,5))。
	# - 墙放第 0 列是刻意的:这样两条接缝断言(越过 x=W 落到第 6 格 / 越过 x=0 落到第 -1 格)
	#   绕回后正好都落在这一列墙上 —— 判定结果由"绕没绕"决定,而不是被别处的墙顺带满足。
	var g := _blank(6, 6)
	for y in range(6):
		g[y][0] = MazeGenerator.pack(1, 15)          # 实心砖(第 0 列)
	g[5][5] = MazeGenerator.pack(21, 15)             # 水
	TileDefs.load_terrain(g, [])

	var W := 6.0 * TS
	var H := 6.0 * TS

	# ① 纯空区域 -> 不压到东西
	_check(not TileQuery.rect_overlaps_solid(_rect(TS * 1.5, TS * 0.5, TS), TS),
			"空区域:rect_overlaps_solid 为 false")
	# ② 正面压到第 0 列的墙
	_check(TileQuery.rect_overlaps_solid(_rect(TS * 0.2, TS * 1.5, TS), TS),
			"压到第 0 列的墙 → true")
	# ③ -  跨右接缝:矩形横跨 x=W,覆盖第 5 格(空)与第 6 格 —— 绕回后是第 0 格(墙)。
	#    不绕的实现会去读 grid[y][6](6 列表,越界)或读错行。
	_check(TileQuery.rect_overlaps_solid(Rect2(W - 1.0, TS * 1.5, TS * 0.5, TS), TS),
			"★ 跨右接缝:第 6 格绕回第 0 格(墙)→ true(不绕会越界)")
	# ④ -  负坐标绕回:往左整整一幅图(x ≈ -W)。
	#    为什么非要"超过一整幅图"才够鉴别:GDScript 数组的负索引对 -1/-2 恰好与 posmod 同值,
	#    只有偏移 ≥ 一个地图边长时,-8 这类下标才会在"不绕"的实现里越界。这里落点绕回后是
	#    第 4/5 格(空) -> false,与 ③ 的"绕回撞墙 -> true"成对,排除"永远 true"。
	_check(not TileQuery.rect_overlaps_solid(
			Rect2(-W - TS * 1.5, TS * 1.5, TS * 0.8, TS), TS),
			"★ 往左一幅图(-8 格)绕回第 4/5 格(空)→ false(不绕则越界)")
	# ⑤ 水:矩形落在 (5,5) 那格水上 —— 水不算实心,但飞鸟版要算
	var seam_water := Rect2(TS * 5.2, TS * 4.5, TS * 0.6, TS)
	_check(not TileQuery.rect_overlaps_solid(seam_water, TS),
			"水不算实心瓦片，rect_overlaps_solid 为 false")
	_check(TileQuery.rect_overlaps_solid_or_liquid(seam_water, TS),
			"solid_or_liquid 将水体判定为有效阻挡，返回 true")

	# ⑥ 空网格：全部返回 false（无阻挡判定）
	TileDefs.load_terrain([], [])
	_check(not TileQuery.rect_overlaps_solid(_rect(0, 0, TS * 3), TS),
			"空网格 → false(调用方自备方向:飞鸟要的是不可走,故它必须保留自己的 is_empty 早退)")
	_check(not TileQuery.rect_overlaps_solid_or_liquid(_rect(0, 0, TS * 3), TS),
			"空网格 → solid_or_liquid 也 false")

	if _fail == 0:
		print("TILE_QUERY OK")
		quit(0)
	else:
		print("TILE_QUERY FAIL(%d 条)" % _fail)
		quit(1)


# 返回类型声明为 Array[Array]，与 MazeGenerator.current_grid 的强类型保持一致。
func _blank(cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for _y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	return g


func _rect(x: float, y: float, size: float) -> Rect2:
	return Rect2(Vector2(x, y), Vector2(size, size))


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)
