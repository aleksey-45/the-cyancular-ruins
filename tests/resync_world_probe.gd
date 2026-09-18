extends Node

# 「重连补态:先还原基线、再应用 destroyed」的**真行为**守卫。
# 跑法: timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/resync_world_probe.tscn
# 通过 = 文本 `RESYNC WORLD PROBE: ALL-OK` 退出 0(判据是**文本**,不是退出码 —— 场景探针在脚本
#   报错时 `--quit-after` 到点照样 exit 0,只看退出码会把"根本没跑完"读成"通过")。
#
# ═══ 守的是什么 ═══
# `match_sync` 的 `destroyed` 表达的是「与**建局基线**不同的格」。客户端在宽限期内**错过一次换局**时,
# 服务器那次 `_reset_world_and_clear_dynamics()` 已经把可破坏砖还原成基线 ⇒ 那些格等于基线、
# **永不进载荷** ⇒ 客户端本地留着上一局拆出来的破洞 = **幻影空洞**(服务器上那里是实心墙)。
# 客户端唯一的还原路径是新回合 COUNTDOWN 里的 `Level0.reset_destructibles()`(见
# `pvp_game._on_round_state`),而重连回来时那一局可能**已经打到 PLAYING** → 那条分支不触发。
# 修法 = 补态那一路**先** `reset_destructibles()` **再**应用 `destroyed`(因为 destroyed 相对基线,
# 两者合起来恰好等于服务器的 grid,不上线任何新字节)。
#
# ═══ 为什么不是真链路断言,也不是源码级断言 ═══
# · 真链路要造出「换局正好落在宽限期内」:1v1 一局得先到 5 杀才结束,现成探针里没有便宜手段,
#   而"不许为测试新造产品开关"是硬约束 → 真链路不可得(见报告)。
# · 源码级(如 tests/reconnect_smoke.gd 那种 grep)只能判"那行字在不在",判不了**行为**:
#   顺序写反(先应用、后还原)、或闸门写错(读了两遍 `_resync_pull_pending`,第二遍必 false)
#   这三种坏法里,后两种照样能通过任何"字符串在位"式的断言。
# · 所以退到**真对象 + 真函数**:真 `Level0`(pvp_mode、真地图、真碰撞、真 `_pristine_grid`)
#   + 真 `PvpMatchClient._on_match_sync`(直接调那**一个**函数 —— 它只读 `_level0`/`_world`/
#   `PvpSession`,与"是否真的连在网上"无关)。同款手法见 `ground_action_probe`(真 MatchHost、
#   role_peers 传空)与 `destroyed_cells_probe`。

const MAP := "res://maps/factory1v1.cyrm"

var _fails: Array[String] = []
var _client: PvpMatchClient = null
var _level0: Node = null
var _ran_to_end := false          # 防"脚本中途报错 → 无失败项的 ALL-OK"(假绿守卫)

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
	# 真客户端实例:两个子类都 extends PvpMatchClient 且**都没覆写 `_on_match_sync`**,
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
	# ★ 非空转前置:B 的基线必须是**实心** —— 否则"应用 destroyed"那一步的判据(下面 ④)
	#   会与"什么都没做"长得一样(空气改空气 = 零差异),顺序写反也照样绿。
	_check(_a_pristine != 0 and _b_pristine != 0,
			"两格在基线里都是实心(A=%d,B=%d)—— 前置:证明下面几条判的是真的差异" % [_a_pristine, _b_pristine])

	# ── ② 造出"客户端与基线不一致"的现场:A、B 都在本地被拆掉 ──
	# 走**真客户端的真路径**(`_on_remote_tile_destroyed` = 服务器拆墙事件/换局补态共用的那一个),
	# 不是直接改网格。
	_client._on_remote_tile_destroyed(_a, true)
	_client._on_remote_tile_destroyed(_b, true)
	_check(_grid_at(_a) == 0 and _grid_at(_b) == 0,
			"前置:本地这两格都已拆掉(A=%d,B=%d)" % [_grid_at(_a), _grid_at(_b)])

	# ── ③ 补态那一路:先还原基线、再应用载荷(A **不在**载荷里 = 上一局拆的、服务器已还原)──
	_client._resync_pull_pending = true
	_client._on_match_sync({"destroyed": [_b]})
	_check(_grid_at(_a) == _a_pristine,
			"★ 幻影空洞被填回:不在载荷里的 A (%s) 回到基线(%d,实得 %d)—— 去掉「先还原」那一行即红" %
			[str(_a), _a_pristine, _grid_at(_a)])
	_check(_grid_at(_b) == 0,
			"★ 载荷里的 B (%s) 仍是被拆的(实得 %d)—— 顺序写反(先应用、后还原)会把它一并填回去" %
			[str(_b), _grid_at(_b)])

	# ── ④ 进场那一路**不许**还原(闸门必须是那个读一次即清的 `resync`)──
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
