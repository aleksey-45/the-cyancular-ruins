extends SceneTree

# .cyrt 时空地图事件层探针(-s 数据级,不建世界):
#   解析(新 kind/标志/默认值)· rev/re 语义(不可逆/一次性) · 逆操作完备性
#   · v4 注释行兼容 · 玩家入史混合回拨顺序 · set_inverse 回填升级
# 用法:godot --headless --path . -s res://Tests/time_events_probe.gd

var _fails := 0


func _init() -> void:
	_test_parse_kinds()
	_test_flags()
	_test_compat_v4()
	_test_player_mix_rewind()
	_test_set_inverse_upgrade()
	if _fails == 0:
		print("TIME EVENTS PROBE: OK(解析/标志/rev-re/v4兼容/玩家混合回拨/逆操作回填)")
		quit(0)
	else:
		print("TIME EVENTS PROBE: FAILED(%d)" % _fails)
		quit(1)


func _chk(cond: bool, what: String) -> void:
	if cond:
		print("  ✓ ", what)
	else:
		_fails += 1
		print("  ✗ ", what)


const SAMPLE := """
# cyrt-v1
# player 10 10
# tl-w0: 25
# tl: 15 collapse 22 20 17 11 rev=1 桥梁坍塌
# tl: 12 explode 30 18 4 dmg=50 kb=300 燃气爆炸
# tl: 11 wipe 40 10 3 rev=0 强制塌方
# tl: 10 gen 40 30 6 3 tex=19 增生岩壁
# tl: 8 spawn_enemy 50 20 type=jump_bird count=2 空降鸟群
# tl: 6 open 46 20 1 10 密室炸开
000000000000000000
"""


func _test_parse_kinds() -> void:
	print("[1] 新事件种解析")
	var tl := TimeTimeline.parse_lines(SAMPLE.split("\n"))
	_chk(tl.w0 == 25.0, "tl-w0 起始钟解析")
	_chk(tl.size() == 6, "六条事件全部入账(实为 %d)" % tl.size())
	var by_kind := {}
	for e in tl.entries:
		by_kind[str(e["fwd"]["op"])] = e
	_chk(by_kind.has("collapse") and by_kind["collapse"]["fwd"]["rect"] == Rect2i(22, 20, 17, 11),
			"collapse 矩形参数")
	_chk(by_kind.has("explode") and by_kind["explode"]["fwd"]["center"] == Vector2i(30, 18)
			and int(by_kind["explode"]["fwd"]["radius"]) == 4
			and int(by_kind["explode"]["fwd"]["dmg"]) == 50
			and absf(float(by_kind["explode"]["fwd"]["kb"]) - 300.0) < 0.01,
			"explode 圆心/半径/dmg/kb 覆盖")
	_chk(by_kind.has("gen") and int(by_kind["gen"]["fwd"]["tex"]) == 19,
			"gen 纹理标志 tex=19")
	_chk(by_kind.has("spawn_enemy") and str(by_kind["spawn_enemy"]["fwd"]["etype"]) == "jump_bird"
			and int(by_kind["spawn_enemy"]["fwd"]["count"]) == 2,
			"spawn_enemy type/count 标志")
	_chk(str(by_kind["spawn_enemy"]["inv"]["op"]) == "despawn_spawn"
			and int(by_kind["spawn_enemy"]["inv"]["spawn_id"]) == int(by_kind["spawn_enemy"]["id"]),
			"spawn 逆操作 despawn_spawn 且 id 已回填")
	_chk(str(by_kind["explode"]["inv"]["op"]) == "restore_pristine",
			"explode 解析期预置 restore_pristine 兜底")
	# 默认值:无 dmg/kb 标志时取 TimeParams
	var tl2 := TimeTimeline.parse_lines("# tl-w0: 5\n# tl: 3 explode 1 1 2\n".split("\n"))
	_chk(int(tl2.entries[0]["fwd"]["dmg"]) == TimeParams.EVT_EXPLODE_DMG,
			"explode 默认伤害取 TimeParams.EVT_EXPLODE_DMG")


func _test_flags() -> void:
	print("[2] rev/re 语义")
	var tl := TimeTimeline.parse_lines(SAMPLE.split("\n"))
	var by_t := {}
	for e in tl.entries:
		by_t[float(e["t"])] = e
	_chk(bool(by_t[15.0]["rev"]) and bool(by_t[15.0]["re"]), "缺省 rev=1/re=1")
	_chk(not bool(by_t[11.0]["rev"]) and str(by_t[11.0]["inv"]["op"]) == "noop",
			"rev=0 → 逆操作 noop(作者标注不可逆)")
	# re=0 一次性:构造一个,触发一次后 crossings 不再给出
	var tl3 := TimeTimeline.parse_lines(
			"# tl-w0: 10\n# tl: 5 wipe 1 1 1 re=0\n# tl: 4 open 2 2 1 1\n".split("\n"))
	var due1 := tl3.crossings(10.0, 5.0)
	_chk(due1.size() == 1 and str(due1[0]["fwd"]["op"]) == "wipe", "re=0 事件首次正常触发")
	tl3.mark_consumed(int(due1[0]["id"]))
	var due2 := tl3.crossings(6.0, 0.0)
	var has_wipe := false
	for e in due2:
		if str(e["fwd"]["op"]) == "wipe":
			has_wipe = true
	_chk(not has_wipe and due2.size() == 1 and str(due2[0]["fwd"]["op"]) == "open",
			"已消耗(re=0)事件不再重播,其余照常")
	# rev=0 事件不进完备性缺口
	_chk(tl.incomplete_inverses().is_empty(), "rev=0 的 noop 不算逆操作缺口")


func _test_compat_v4() -> void:
	print("[3] v4 注释行兼容")
	var tl := TimeTimeline.parse_lines(
			"# cyrm-v4\n# tl-w0: 25\n# tl: 15 collapse 22 20 17 11 桥梁坍塌\n# tl: 5 open 46 20 1 10 密室炸开\n".split("\n"))
	_chk(tl.size() == 2 and tl.w0 == 25.0, "旧 v4 六段式行照常解析")
	_chk(str(tl.entries[0]["label"]) == "桥梁坍塌", "标签保留")
	_chk(bool(tl.entries[0]["rev"]) and bool(tl.entries[0]["re"]), "旧行隐含 rev=1/re=1")
	# 非法 kind/残行整行忽略不炸
	var tl2 := TimeTimeline.parse_lines("# tl-w0: 5\n# tl: 3 storm 1 1 4 4\n# tl: 2 collapse\n".split("\n"))
	_chk(tl2.size() == 0, "未登记 kind 与参数不足的行被忽略")


func _test_player_mix_rewind() -> void:
	print("[4] 玩家入史与 scheduled 混合的 LIFO 回拨")
	var tw := TimeWorld.from_timeline(TimeTimeline.parse_lines(
			"# tl-w0: 20\n# tl: 10 open 5 5 2 2\n# tl: 5 collapse 8 8 2 2\n".split("\n")))
	tw.tick(10.1)   # 钟降到 9.9,触发 t=10
	tw.tick(5.1)    # 钟降到 4.8,触发 t=5
	tw.timeline.record_player_op(6.0, {"op": "destroy_cells"}, {"op": "restore_cells"}, "玩家拆墙")
	var ops := tw.rewind_to(20.0)
	var seq := []
	for op in ops:
		seq.append(str((op["op"] as Dictionary).get("op", "")))
	# 撤销顺序 = t 升序(LIFO):5(collapse) → 6(玩家) → 10(open 的逆)
	_chk(seq == ["open", "restore_cells", "collapse"],
			"LIFO 撤销顺序 t 升序:5→6→10(实为 %s)" % str(seq))
	_chk(absf(tw.w - 20.0) < 0.001, "回拨后世界针=20")
	# scheduled 重新武装:再扫一次,t=10 与 t=5 都会再次触发(t 降序,open 先)
	var due := tw.tick(10.1)
	_chk(due.size() == 2 and str(due[0]["action"]) == "open" and str(due[1]["action"]) == "collapse",
			"scheduled 回拨后重新武装(两个事件都重播,open 先)")


func _test_set_inverse_upgrade() -> void:
	print("[5] 执行层回填精确逆操作")
	var tl := TimeTimeline.parse_lines("# tl-w0: 10\n# tl: 5 gen 3 3 4 4 tex=15\n".split("\n"))
	var id := int(tl.entries[0]["id"])
	_chk(str(tl.entries[0]["inv"]["op"]) == "restore_pristine", "解析期预置兜底")
	var cells := [{"cell": Vector2i(4, 4), "v": 0}, {"cell": Vector2i(5, 4), "v": 31}]
	tl.set_inverse(id, {"op": "restore_cells", "cells": cells})
	var ops := tl.rewind_ops(10.0, 4.9)   # w_now 取已越过阈值后的钟值(4.9 < t=5)
	_chk(ops.size() == 1 and str((ops[0]["op"] as Dictionary).get("op", "")) == "restore_cells"
			and (ops[0]["op"]["cells"] as Array).size() == 2,
			"set_inverse 后回拨取到捕获的精确逆(restore_cells×2)")
	# w0 边界告警路径不炸(阈值=w0)
	var tl2 := TimeTimeline.parse_lines("# tl-w0: 5\n# tl: 5 open 1 1 1 1\n".split("\n"))
	_chk(tl2.crossings(5.0, 0.0).is_empty(), "阈值==w0 严格小于才触发(边界语义不变)")
