extends ProbeBase


const EXPECTED_CHECKS := 11

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

const COLS := 8
const ROWS := 6
const TILE := 64
const MAP_W := COLS * TILE
const MAP_H := ROWS * TILE
const LEAF_TEX := 15

const CELL_EVENT := Vector2i(7, 2)
const SUB_CELL := Vector2i(0, 4)
const SUB_EVENT := Vector2i(1, 18)
const REPEAT_SUB := Vector2i(8, 4)
const DEDUP_SUB := Vector2i(12, 4)
const SILENT_CELL := Vector2i(0, 0)
const INJECT_CELL := Vector2i(5, 2)
const REJECT_CELL := Vector2i(1, 2)

const LOCAL_POS := Vector2(10.0, 192.0)


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


var _cstate: ClientState = null
var _cports: ClientPorts = null
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

	_check(_particle_count() == 0, "起始世界应无粒子(实得 %d)" % _particle_count())
	_checks += 1

	var fails_before := _failures.size()
	_sync.on_cell(CELL_EVENT, false)
	_check(_particle_count() == 1, "格级事件应只新增 1 簇粒子,实得 %d(旧实现 17 簇)" % _particle_count())
	_summary(fails_before, "格级事件只播 1 簇粒子")
	_checks += 1

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

	_sync.on_sub(SUB_EVENT, false)
	_check(_particle_count() == 2, "子格事件应新增 1 簇,实得 %d" % _particle_count())
	_checks += 1
	var expect_sub := _anchored(Vector2(SUB_EVENT.x * 16 + 8, SUB_EVENT.y * 16 + 8))
	var got_sub := _last_particle_pos()
	_check(got_sub.distance_to(expect_sub) <= 1.0,
			"子格粒子坐标应为 %s(锚定后),实得 %s" % [str(expect_sub), str(got_sub)])
	_checks += 1

	_sync.on_sub(SUB_EVENT, false)
	_check(_particle_count() == 2, "已死子格的重复事件不应再播粒子,实得 %d" % _particle_count())
	_checks += 1

	_sync.on_cell(SILENT_CELL, true)
	_check(_particle_count() == 2, "silent 事件不应播粒子,实得 %d" % _particle_count())
	_checks += 1

	var dedup_pos := _anchored(Vector2(DEDUP_SUB.x * 16 + 8, DEDUP_SUB.y * 16 + 8))
	TileHitFx.clear_recent_hits()
	TileHitFx.mark_hit(dedup_pos)
	_sync.on_sub(DEDUP_SUB, false)
	_check(_particle_count() == 2, "刚播过命中碎片的砖,破坏事件应被去重,实得 %d" % _particle_count())
	_checks += 1

	var rb := StubRollback.new()
	_cstate._rollback = rb
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



func _build_world() -> void:
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
	_cstate = ClientState.new()
	_cports = ClientPorts.new()
	var local := Node2D.new()
	local.name = "Local"
	local.position = LOCAL_POS
	add_child(local)
	_cstate._world = _world
	_cstate._local = local


func _build_sync() -> void:
	_sync = TileSync.new()
	_sync.bind(_cstate, _cports)


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
