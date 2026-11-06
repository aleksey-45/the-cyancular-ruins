extends ProbeBase

# 联机拆砖粒子探针(2026-10-26 修"服务器事件 → 粒子"表现层)。

const EXPECTED_CHECKS := 11

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

const COLS := 8
const ROWS := 6
const TILE := 64
const MAP_W := COLS * TILE
const MAP_H := ROWS * TILE
const LEAF_TEX := 15

# 格级事件目标:贴着右接缝那格(canonical 中心 x=480,锚到本地玩家后应变成 -32)。
const CELL_EVENT := Vector2i(7, 2)
# 独立子格事件目标格(0,4)、取它的子格 (1,18)。
const SUB_CELL := Vector2i(0, 4)
const SUB_EVENT := Vector2i(1, 18)
# 已死/重复事件用格(2,1)的左上子格。
const REPEAT_SUB := Vector2i(8, 4)
# 去重用格(3,1)的左上子格。
const DEDUP_SUB := Vector2i(12, 4)
# silent 形态用格(0,0)。
const SILENT_CELL := Vector2i(0, 0)
# R2(注入)用格:⑩ 有预测环 ⇒ 走注入;⑪ 注入被拒 ⇒ 兜底立即应用。
const INJECT_CELL := Vector2i(5, 2)
const REJECT_CELL := Vector2i(1, 2)

# 本地玩家位置:贴左接缝(所以 canonical 右侧的粒子必须被搬过来)。
const LOCAL_POS := Vector2(10.0, 192.0)


class StubClient extends Node:
	var _world: Node2D = null
	var _local: Node2D = null
	var _rollback = null      # ⑩⑪ 用:R2 注入路径的替身(见 StubRollback)


# 预测环替身:只实现 TileSync 用到的那一个方法。`reject=true` = 模拟"环外/已 ack"的拒绝路径。
class StubRollback extends RefCounted:
	var seqs: Array[int] = []
	var calls := 0
	var reject := false

	func apply_external_event(seq: int, cb: Callable) -> int:
		if reject:
			return 1
		seqs.append(seq)
		calls += 1
		cb.call()
		return 0


var _client: StubClient = null
var _world: Node2D = null
var _sync: TileSync = null
var _checks := 0


func probe_id() -> String:
	return "net_tile_fx"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_build_world()
	_build_sync()

	# ① 起始 0 簇
	_check(_particle_count() == 0, "起始世界应无粒子(实得 %d)" % _particle_count())
	_checks += 1

	# ② 格级事件只播 1 簇,不再展开成 16+1
	var fails_before := _failures.size()
	_sync.on_cell(CELL_EVENT, false)
	_check(_particle_count() == 1, "格级事件应只新增 1 簇粒子,实得 %d(旧实现 17 簇)" % _particle_count())
	_summary(fails_before, "格级事件只播 1 簇粒子")
	_checks += 1

	# ③ 粒子坐标锚到本地玩家附近的环面副本
	var expect_cell := _anchored(Vector2(CELL_EVENT.x * TILE + TILE * 0.5, CELL_EVENT.y * TILE + TILE * 0.5))
	var got_cell := _last_particle_pos()
	_check(got_cell.distance_to(expect_cell) <= 1.0,
			"格级粒子坐标应为 %s(锚定后),实得 %s" % [str(expect_cell), str(got_cell)])
	_checks += 1

	# ④ 16 个子格状态确实被清(静默只是不播粒子,不是不清)
	var subs_cleared := true
	for sy in 4:
		for sx in 4:
			if TileDefs.sub_alive(Vector2i(CELL_EVENT.x * 4 + sx, CELL_EVENT.y * 4 + sy)):
				subs_cleared = false
	_check(subs_cleared, "格级事件后该格 16 个子格应全部为死(否则客户端留幽灵墙)")
	_checks += 1

	# ⑤ 独立子格事件新增 1 簇,坐标同样锚定
	_sync.on_sub(SUB_EVENT, false)
	_check(_particle_count() == 2, "子格事件应新增 1 簇,实得 %d" % _particle_count())
	_checks += 1
	var expect_sub := _anchored(Vector2(SUB_EVENT.x * 16 + 8, SUB_EVENT.y * 16 + 8))
	var got_sub := _last_particle_pos()
	_check(got_sub.distance_to(expect_sub) <= 1.0,
			"子格粒子坐标应为 %s(锚定后),实得 %s" % [str(expect_sub), str(got_sub)])
	_checks += 1

	# ⑥ 重复/已死子格事件不播(否则 17 簇里会混进"早就没了"的子格)
	_sync.on_sub(SUB_EVENT, false)
	_check(_particle_count() == 2, "已死子格的重复事件不应再播粒子,实得 %d" % _particle_count())
	_checks += 1

	# ⑦ silent(重连补态):清状态但不播
	_sync.on_cell(SILENT_CELL, true)
	_check(_particle_count() == 2, "silent 事件不应播粒子,实得 %d" % _particle_count())
	_checks += 1

	# ⑧ 去重:本端刚在这块砖播过命中碎片 ⇒ 破坏事件不再叠一簇
	var dedup_pos := _anchored(Vector2(DEDUP_SUB.x * 16 + 8, DEDUP_SUB.y * 16 + 8))
	TileHitFx.clear_recent_hits()
	TileHitFx.mark_hit(dedup_pos)
	_sync.on_sub(DEDUP_SUB, false)
	_check(_particle_count() == 2, "刚播过命中碎片的砖,破坏事件应被去重,实得 %d" % _particle_count())
	_checks += 1

	# ⑩ R2:有预测环 ⇒ 变更必须走 `apply_external_event(seq, cb)` 注入(seq 透传、地形照拆、粒子仍只 1 簇)。
	#    ★ 这里走 RPC 入口 `_rpc_on_cell`(带锚点),而 `on_cell` 是"无锚点 ⇒ 立即应用"的老入口。
	var rb := StubRollback.new()
	_client._rollback = rb
	var particles_before := _particle_count()
	_sync._rpc_on_cell(INJECT_CELL, 42)
	var cleared_inject := true
	for sy in 4:
		for sx in 4:
			if TileDefs.sub_alive(Vector2i(INJECT_CELL.x * 4 + sx, INJECT_CELL.y * 4 + sy)):
				cleared_inject = false
	_check(rb.seqs == [42] and cleared_inject and _particle_count() == particles_before + 1,
			"有预测环时应走注入:注入的 seq=%s、子格已清=%s、粒子 +%d" % [
				str(rb.seqs), str(cleared_inject), _particle_count() - particles_before])
	_checks += 1

	# ⑪ 注入被拒(环外 / 已 ack)⇒ 兜底立即应用:地形照拆,不报错、不告警。
	rb.reject = true
	_sync._rpc_on_cell(REJECT_CELL, 43)
	var cleared_reject := true
	for sy in 4:
		for sx in 4:
			if TileDefs.sub_alive(Vector2i(REJECT_CELL.x * 4 + sx, REJECT_CELL.y * 4 + sy)):
				cleared_reject = false
	_check(cleared_reject, "注入被拒时应兜底立即应用(该格 16 个子格必须被拆),否则客户端留幽灵墙")
	_checks += 1

	# ⑨ 条数闸(防"断言被静默跳过、verdict 仍 ALL-OK")
	if _checks != EXPECTED_CHECKS:
		_check(false, "实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])

	_finish()


# ── 夹具 ─────────────────────────────────────────────────────────────

func _build_world() -> void:
	# 5 块可破坏树叶格(其余空气):每格 16 个子格都是纹理 15。
	var alive_cells := [CELL_EVENT, SUB_CELL, REPEAT_SUB / 4, DEDUP_SUB / 4, SILENT_CELL, INJECT_CELL, REJECT_CELL]
	var grid: Array[Array] = []
	for y in ROWS:
		var row: Array = []
		for x in COLS:
			row.append(MazeGenerator.pack(LEAF_TEX, 15) if Vector2i(x, y) in alive_cells else MazeGenerator.EMPTY)
		grid.append(row)
	var sgrid: Array[Array] = []
	for sy in ROWS * 4:
		var srow: Array = []
		for sx in COLS * 4:
			srow.append(LEAF_TEX if Vector2i(sx / 4, sy / 4) in alive_cells else 0)
		sgrid.append(srow)

	TileDefs.load_defs()
	MazeGenerator.current_grid = grid
	MazeGenerator.current_subgrid = sgrid
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(sgrid)
	# 锚定用的地图尺寸:探针里不读地图文件,直接按合成网格写 autoload 实例字段(与世界同源)。
	GameParameters.MAP_WIDTH = MAP_W
	GameParameters.MAP_HEIGHT = MAP_H

	_world = Node2D.new()
	_world.name = "StubWorld"
	add_child(_world)
	_client = StubClient.new()
	_client.name = "StubClient"
	add_child(_client)
	var local := Node2D.new()
	local.name = "Local"
	local.position = LOCAL_POS
	_client.add_child(local)
	_client._world = _world
	_client._local = local


func _build_sync() -> void:
	_sync = TileSync.new()
	_sync.bind(_client)


func _anchored(at: Vector2) -> Vector2:
	return MazeGenerator.anchor_to_nearest(at, LOCAL_POS, MAP_W, MAP_H)


func _particles() -> Array[Node]:
	var out: Array[Node] = []
	for c in _world.get_children():
		if c is CPUParticles2D:
			out.append(c)
	return out


func _particle_count() -> int:
	return _particles().size()


func _last_particle_pos() -> Vector2:
	var ps := _particles()
	if ps.is_empty():
		return Vector2(INF, INF)
	return (ps[ps.size() - 1] as Node2D).position
