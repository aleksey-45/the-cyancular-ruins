extends SceneTree

# M1 验收探针(策划案 §8 M1:时间账本 + 单针表盘 + 子弹时间时停,纯数字层无世界联动)。
# 纯函数 + 临时地图,不引 autoload,-s 可直接跑:
#   Godot_console --headless --path . -s res://Tests/time_ledger_probe.gd
#
# 断言清单:
#   ① 参数换算(分钟→秒/阶段/表盘文本)
#   ② 10ms 粒度量化 + 阶段衰减倍率
#   ③ 子弹时间(scale=0 时停 / 0.05 慢放)
#   ④ 账本收支(回拨 / 消费 / 统计 / 流速场)
#   ⑤ 阶段切换 / 终末 / 灾前三类信号
#   ⑥ .cyrm v4 时间层解析(小数秒、标签、降序、下一个待触发)
#   ⑦ 只正向跨越触发 + 回拨不触发 + 回拨后重新武装
#   ⑧ LIFO 回拨顺序与逆操作正确性 + 逆操作完备性
#   ⑨ 玩家操作入史(不重放、参与回拨、逆操作严格互逆)
#   ⑩ 门面 TimeWorld 兼容载荷 + v4 地图端到端(网格/spawn/事件/回拨)

const EPS := 0.001


func _initialize() -> void:
	var fails: Array[String] = []

	_test_params(fails)
	_test_clock(fails)
	_test_ledger(fails)
	_test_timeline(fails)
	_test_legacy_demo_map(fails)
	_test_facade_and_map(fails)

	if fails.is_empty():
		print("TIME LEDGER PROBE: OK(参数/粒度/时停/账本/信号/解析/跨越/回拨/入史/门面/v0.1兼容)")
		quit(0)
	else:
		for f in fails:
			push_error("TIME LEDGER PROBE FAIL: " + f)
		print("TIME LEDGER PROBE: FAIL(%d)" % fails.size())
		quit(1)


# ── ① 参数换算 ──────────────────────────────────────────────
func _test_params(fails: Array[String]) -> void:
	if not is_equal_approx(TimeParams.FINAL_SECONDS, 7200.0):
		fails.append("FINAL_SECONDS 应为 7200(120min)")
	if not is_equal_approx(TimeParams.W0_DEFAULT, 3600.0):
		fails.append("W0_DEFAULT 应为 3600(60min,T_ruin)")
	if not is_equal_approx(TimeParams.PRE_RUIN_TARGET, TimeParams.FINAL_SECONDS):
		fails.append("灾前目标应等于轴长(FINAL_SECONDS)")
	_near(fails, "kill_seconds(JumpBird)", TimeParams.kill_seconds("JumpBird"), 21.0)
	_near(fails, "kill_seconds(BlackBird)", TimeParams.kill_seconds("BlackBird"), 60.0)
	_near(fails, "kill_seconds(FinalBoss)", TimeParams.kill_seconds("FinalBoss"), 3600.0)
	_near(fails, "kill_seconds(未知)", TimeParams.kill_seconds("Nope"), 0.0)
	if TimeParams.phase_of(0.0) != 0 or TimeParams.phase_of(0.24) != 0:
		fails.append("毁灭度 <25% 应为阶段 0")
	if TimeParams.phase_of(0.25) != 1 or TimeParams.phase_of(0.49) != 1:
		fails.append("毁灭度 25~50% 应为阶段 1")
	if TimeParams.phase_of(0.50) != 2 or TimeParams.phase_of(0.74) != 2:
		fails.append("毁灭度 50~75% 应为阶段 2")
	if TimeParams.phase_of(0.75) != 3 or TimeParams.phase_of(1.0) != 3:
		fails.append("毁灭度 ≥75% 应为阶段 3")
	_near(fails, "decay_multiplier(阶段2)", TimeParams.decay_multiplier_of(0.5), 1.30)
	_near(fails, "decay_multiplier(阶段3)", TimeParams.decay_multiplier_of(0.9), 1.50)
	if TimeParams.format_clock(14.3) != "T-14.30":
		fails.append("表盘文本应为百分秒 T-14.30,实为 " + TimeParams.format_clock(14.3))
	if TimeParams.format_clock(-5.0) != "T-00.00":
		fails.append("负值应夹到 T-00.00")


# ── ②③ 粒度 / 衰减 / 时停 ────────────────────────────────────
func _test_clock(fails: Array[String]) -> void:
	# w=3600 → D=0.5 → 阶段 2(倍率 1.3)
	var c := TimeClock.new(3600.0)
	if c.phase() != 2:
		fails.append("w=3600 应为阶段 2,实为 %d" % c.phase())
	_near(fails, "D(w=3600)", c.destruction(), 0.5)
	var applied := c.elapse(1.0)
	_near(fails, "衰减作用量", applied, 1.30)
	_near(fails, "衰减后 w", c.w, 3598.70)

	# 10ms 粒度:不足一步不推进,攒够一步才走
	var g := TimeClock.new(3600.0)
	_near(fails, "粒度以下不推进", g.elapse(0.004), 0.0, 0.0)
	_near(fails, "粒度以下 w 不变", g.w, 3600.0, 0.0)
	_near(fails, "攒够一步推进 10ms", g.elapse(0.006), 0.01, 0.0001)
	_near(fails, "一步后 w", g.w, 3599.99, 0.0001)

	# 子弹时间:0 = 决策时停(思考不烧钟);0.05 = 慢放
	var b := TimeClock.new(3600.0)
	b.set_scale(TimeParams.SCALE_PAUSE)
	_near(fails, "时停不烧钟", b.elapse(5.0), 0.0, 0.0)
	_near(fails, "时停 w 不变", b.w, 3600.0, 0.0)
	b.set_scale(TimeParams.SCALE_SLOW)
	# 1.0s × 0.05 × 1.3 = 0.065 → 量化 6 步 = 0.06(余 0.005 留待下帧)
	_near(fails, "慢放推进", b.elapse(1.0), 0.06, 0.0101)
	b.set_scale(TimeParams.SCALE_NORMAL)

	# 阶段切换信号:w=1810(D=0.7486,阶段2)推进 60s×1.3=78 → 阶段 3
	var p := TimeClock.new(1810.0)
	if p.phase() != 2:
		fails.append("w=1810 应为阶段 2,实为 %d" % p.phase())
	var seen: Array = []
	p.phase_changed.connect(func(ph: int, prev: int) -> void: seen.append([ph, prev]))
	p.elapse(60.0)
	if seen.size() != 1:
		fails.append("阶段切换信号应恰好 1 次,实为 %d" % seen.size())
	elif int(seen[0][0]) != 3 or int(seen[0][1]) != 2:
		fails.append("阶段切换应为 2→3,实为 %s→%s" % [str(seen[0][1]), str(seen[0][0])])

	# 灾前信号:回拨到轴顶
	var pre := TimeClock.new(TimeParams.FINAL_SECONDS - 1.0)
	var pre_hit := [false]
	pre.pre_ruin_reached.connect(func() -> void: pre_hit[0] = true)
	pre.recover(1.0, "blessing")
	if not pre_hit[0] or not pre.is_pre_ruin():
		fails.append("回拨到灾前应触发 pre_ruin_reached")

	# 终末信号:一次打穿到 0(流速场 3.0 × 阶段加成 1.5)
	var fin := TimeClock.new(1.0)
	var fin_hit := [false]
	fin.final_reached.connect(func() -> void: fin_hit[0] = true)
	fin.set_flow(TimeParams.FLOW_STORM)
	fin.elapse(10.0)
	if not fin_hit[0] or not fin.is_final():
		fails.append("W 归零应触发 final_reached 并夹到 0")
	_near(fails, "终末后 w", fin.w, 0.0, 0.0)


# ── ④ 账本收支 ──────────────────────────────────────────────
func _test_ledger(fails: Array[String]) -> void:
	var c := TimeClock.new(3600.0)
	_near(fails, "击杀回拨", c.recover(60.0, "kill:BlackBird"), 60.0)
	_near(fails, "回收统计", c.recovered_total, 60.0)
	_near(fails, "消费推进", c.spend(120.0, "trade"), 120.0)
	_near(fails, "消费统计", c.spent_total, 120.0)
	_near(fails, "收支净额 w", c.w, 3540.0)
	_near(fails, "击杀回收量(基准流速)", c.kill_reward("BlackBird"), 60.0)

	var rush := TimeClock.new(3600.0)
	rush.set_flow(TimeParams.FLOW_RUSH)
	_near(fails, "涨潮区击杀双倍回收", rush.kill_reward("BlackBird"), 120.0)

	var lag := TimeClock.new(3600.0)
	lag.set_flow(TimeParams.FLOW_LAG)
	_near(fails, "时滞区衰减减半", lag.elapse(1.0), 0.65)

	# 灾前上限:回拨不得越过轴顶
	var cap := TimeClock.new(TimeParams.FINAL_SECONDS - 10.0)
	_near(fails, "回拨被灾前上限截断", cap.recover(600.0), 10.0)
	_near(fails, "灾前上限", cap.w, TimeParams.FINAL_SECONDS)


# ── ⑥⑦⑧⑨ 时间线(事件溯源)────────────────────────────────────
func _test_timeline(fails: Array[String]) -> void:
	var source := PackedStringArray([
		"# cyrm-v4",
		"# tl-w0: 25",
		"# tl: 15 collapse 22 20 17 11 桥梁坍塌",
		"# tl: 5 open 46 20 1 10 密室炸开",
		"# tl: 14.300 open 1 2 3 4 小数秒事件",
	])
	var tl := TimeTimeline.parse_lines(source)
	_near(fails, "tl-w0 解析", tl.w0, 25.0)
	if tl.size() != 3:
		fails.append("事件数应为 3,实为 %d" % tl.size())

	var evs := tl.legacy_events()
	if evs.size() != 3:
		fails.append("兼容 events 数应为 3,实为 %d" % evs.size())
	else:
		_near(fails, "events 降序首项 t", float(evs[0]["w"]), 15.0)
		_near(fails, "小数秒解析", float(evs[1]["w"]), 14.3)
		_near(fails, "events 末项 t", float(evs[2]["w"]), 5.0)
		if str(evs[0]["action"]) != "collapse":
			fails.append("首项动作应为 collapse,实为 " + str(evs[0]["action"]))
		if (evs[0]["rect"] as Rect2i) != Rect2i(22, 20, 17, 11):
			fails.append("区域矩形解析错误:" + str(evs[0]["rect"]))
		if str(evs[0]["label"]) != "桥梁坍塌":
			fails.append("中文标签解析错误:" + str(evs[0]["label"]))

	_near(fails, "下一个待触发(w=25)", tl.next_pending_t(25.0), 15.0)
	_near(fails, "下一个待触发(w=14)", tl.next_pending_t(14.0), 5.0)
	_near(fails, "无待触发(w=4)", tl.next_pending_t(4.0), -1.0)

	# ⑦ 只正向跨越;回拨(上升)不触发
	var down := tl.crossings(25.0, 13.0)
	if down.size() != 2:
		fails.append("25→13 应跨越 2 个事件,实为 %d" % down.size())
	elif not is_equal_approx(float(down[0]["t"]), 15.0):
		fails.append("跨越顺序应为 t 降序(先 15)")
	var down2 := tl.crossings(13.0, 5.0)
	if down2.size() != 1 or not is_equal_approx(float(down2[0]["t"]), 5.0):
		fails.append("13→5 应只跨越 t=5")
	if tl.crossings(5.0, 25.0).size() != 0:
		fails.append("回拨方向不得触发定时事件")
	if tl.crossings(24.0, 23.0).size() != 0:
		fails.append("未跨阈值不得触发")
	# 边界语义:t 必须严格小于跨越前的世界针才会被触发(写在 w0 上的事件永不触发)
	if tl.crossings(15.0, 14.0).size() != 1:
		fails.append("从 t 恰好起步时该 t 不触发,只触发更低的阈值")

	# ⑧ 回拨顺序与逆操作。钟**上升**时先越过最小阈值 → 撤销顺序 = t 升序(不是 t 降序!)
	var ops := tl.rewind_ops(25.0, 5.0)
	if ops.size() != 2:
		fails.append("回拨到 25 应撤销 2 个事件,实为 %d" % ops.size())
	else:
		_near(fails, "撤销首项 t(最小阈值先撤)", float(ops[0]["t"]), 14.3)
		if str((ops[0]["op"] as Dictionary).get("op")) != "collapse":
			fails.append("open 的逆操作应为 collapse")
		_near(fails, "撤销次项 t", float(ops[1]["t"]), 15.0)
		if str((ops[1]["op"] as Dictionary).get("op")) != "open":
			fails.append("collapse 的逆操作应为 open")
	if tl.rewind_ops(10.0, 5.0).size() != 0:
		fails.append("回拨到未跨越的阈值不应产生逆操作")
	if tl.incomplete_inverses().size() != 0:
		fails.append("区域原型 collapse/open 的逆操作应完备")

	# 重新武装 = 无状态推导(跨越过的再次跨越仍会产出)
	if tl.crossings(25.0, 13.0).size() != 2:
		fails.append("回拨后应重新武装(再次跨越可再触发)")

	# ⑨ 玩家操作入史:不重放、参与回拨、逆操作严格互逆
	var tl2 := TimeTimeline.parse_lines(source)
	var cell := Vector2i(3, 4)
	var prev_value: int = MazeGenerator.SOLID
	# 玩家在钟值 20 拆墙(chronologically 最早)→ 回拨时最后复原
	tl2.record_player_op(20.0,
			{"op": "destroy_tiles", "cells": [cell], "values": [prev_value]},
			{"op": "restore_tiles", "cells": [cell], "values": [prev_value]},
			"玩家拆墙")
	# 玩家在钟值 12 拾取(chronologically 最晚)→ 回拨时最先撤销
	tl2.record_player_op(12.0,
			{"op": "take_item", "item": "medkit"},
			{"op": "give_item", "item": "medkit"},
			"玩家拾取")
	if tl2.size() != 5:
		fails.append("两条玩家操作应入史(共 5 条),实为 %d" % tl2.size())
	if tl2.crossings(25.0, 10.0).size() != 2:
		fails.append("玩家操作不得作为定时事件重放")
	var ops2 := tl2.rewind_ops(25.0, 10.0)
	if ops2.size() != 4:
		fails.append("回拨应同时撤销玩家操作与定时事件,实为 %d" % ops2.size())
	else:
		if str(ops2[0]["origin"]) != TimeTimeline.ORIGIN_PLAYER or str(ops2[0]["label"]) != "玩家拾取":
			fails.append("最先撤销的应是 chronologically 最晚的玩家操作(t=12 拾取)")
		if str((ops2[0]["op"] as Dictionary).get("op")) != "give_item":
			fails.append("拾取的逆操作应为 give_item")
		_near(fails, "随后撤销 t=14.3", float(ops2[1]["t"]), 14.3)
		if str(ops2[3]["label"]) != "玩家拆墙":
			fails.append("最后撤销的应是 chronologically 最早的玩家操作(t=20 拆墙)")
		if str((ops2[3]["op"] as Dictionary).get("op")) != "restore_tiles":
			fails.append("拆墙的逆操作应为 restore_tiles")
	if tl2.incomplete_inverses().size() != 0:
		fails.append("玩家操作逆操作应完备")


# ── ⑪ v0.1 兼容:真实 demo 图的时间线(不含世界改写)──────────────
# 守住 TimeWorld 门面改造:v0.1 垂直切片(旧 v3 标记 + `# tl:` 注释)必须仍然
# "w0=25 / 2 个事件 / 两次快进各触发一个 / 回拨可逆"——与 Tests/time_map_probe.gd 的
# 纯逻辑部分等价,但不实例化 Level0(那一步依赖完整世界,由 time_map_probe 在 GUI/编辑器里跑)。
func _test_legacy_demo_map(fails: Array[String]) -> void:
	var path := "res://map/timetest.cyrm"
	if not FileAccess.file_exists(path):
		fails.append("演示图缺失:" + path)
		return
	var tw := TimeWorld.parse_for(path)
	_near(fails, "demo w0", tw.w0, 25.0)
	if tw.events.size() != 2:
		fails.append("demo 事件数应为 2,实为 %d" % tw.events.size())
	_near(fails, "demo next_trigger", tw.next_trigger(), 15.0)

	# 第一次快进:12s(阶段 3 → ×1.5)只跨越 t=15
	var first := tw.tick(12.0)
	if first.size() != 1 or str(first[0]["action"]) != "collapse":
		fails.append("demo 第一次快进应只触发 collapse(t=15)")
	# 第二次快进:跨越 t=5 → open
	var second := tw.tick(12.0)
	if second.size() != 1 or str(second[0]["action"]) != "open":
		fails.append("demo 第二次快进应只触发 open(t=5)")
	if not tw.clock.is_final():
		fails.append("demo 两次快进后世界针应到 0")

	# 回拨到 25:钟上升,先越过 t=5(open),再越过 t=15(collapse) → 逆操作按 t 升序
	var ops := tw.rewind_to(25.0)
	if ops.size() != 2:
		fails.append("demo 回拨到 25 应撤销 2 个事件,实为 %d" % ops.size())
	else:
		_near(fails, "demo 撤销首项 t", float(ops[0]["t"]), 5.0)
		if str((ops[0]["op"] as Dictionary).get("op")) != "collapse":
			fails.append("demo t=5(open)的逆操作应为 collapse")
		_near(fails, "demo 撤销次项 t", float(ops[1]["t"]), 15.0)
		if str((ops[1]["op"] as Dictionary).get("op")) != "open":
			fails.append("demo t=15(collapse)的逆操作应为 open")
	_near(fails, "demo 回拨后 w", tw.w, 25.0, 0.05)
	_near(fails, "demo 回拨后重新武装", tw.next_trigger(), 15.0)
	MazeGenerator.set_map_file("")


# ── ⑩ 门面 + v4 地图端到端 ───────────────────────────────────
func _test_facade_and_map(fails: Array[String]) -> void:
	# 临时 v4 地图:优先写 user://(正常编辑器/导出环境);user:// 不可写时回退到 res://
	# (受限沙箱/只读用户目录)。两条候选路径都失败才判失败。
	var map_path := ""
	for candidate in ["user://time_ledger_probe_v4.cyrm", "res://.time_ledger_probe_v4.cyrm"]:
		var f := FileAccess.open(candidate, FileAccess.WRITE)
		if f == null:
			continue
		f.store_string("\n".join(PackedStringArray([
			"# cyrm-v4",
			"# player 1 1",
			"# tl-w0: 12.5",
			"# tl: 9.75 collapse 0 0 2 2 桥",
			"001f001f001f001f",
			"001f00000000001f",
		])))
		f.close()
		map_path = candidate
		break
	if map_path.is_empty():
		fails.append("无法写入临时 v4 地图(user:// 与 res:// 均不可写)")
		return

	MazeGenerator.set_map_file(map_path)
	if MazeGenerator.map_size() != Vector2i(4, 2):
		fails.append("v4 map_size 应为 (4,2),实为 " + str(MazeGenerator.map_size()))
	var grid := MazeGenerator.load_map_file()
	if grid.size() != 2 or (grid[0] as Array).size() != 4:
		fails.append("v4 空间层未按 v3 解析")
	var spawns := MazeGenerator.load_spawns()
	if spawns.get("player", Vector2i(-1, -1)) != Vector2i(1, 1):
		fails.append("v4 spawn 元数据解析错误:" + str(spawns.get("player", "无")))

	var tw := TimeWorld.parse_for(map_path)
	_near(fails, "门面 w0", tw.w0, 12.5)
	if not tw.has_events() or tw.events.size() != 1:
		fails.append("门面事件数应为 1")
	# 12.5 → 阶段 3(倍率 1.5):4s 真实 ≈ 6s 世界 → w=6.5,跨越 9.75
	var due := tw.tick(4.0)
	if due.size() != 1:
		fails.append("门面 tick 应产出 1 个到点事件,实为 %d" % due.size())
	else:
		if str(due[0]["action"]) != "collapse":
			fails.append("到点事件动作应为 collapse")
		if (due[0]["rect"] as Rect2i) != Rect2i(0, 0, 2, 2):
			fails.append("到点事件区域错误:" + str(due[0]["rect"]))
	_near(fails, "门面 w(tick 后)", tw.w, 6.5)

	var inv_ops := tw.rewind_to(12.5)
	if inv_ops.size() != 1:
		fails.append("回拨应返回 1 条逆操作,实为 %d" % inv_ops.size())
	elif str((inv_ops[0]["op"] as Dictionary).get("op")) != "open":
		fails.append("回拨逆操作应为 open")
	_near(fails, "回拨后 w", tw.w, 12.5)
	_near(fails, "回拨后重新武装", tw.next_trigger(), 9.75)
	if tw.tick(4.0).size() != 1:
		fails.append("重新武装后再次跨越应再次触发")

	# 收尾:把会话钉住的地图缓存放回随机(否则 -s 之后实例化的 autoload 会去读已删除的临时图),再删临时图。
	MazeGenerator.set_map_file("")
	if FileAccess.file_exists(map_path):
		DirAccess.remove_absolute(map_path)


# ── 断言助手 ────────────────────────────────────────────────
func _near(fails: Array[String], tag: String, got: float, want: float, eps: float = EPS) -> void:
	if absf(got - want) > eps:
		fails.append("%s: 实为 %s,期望 %s" % [tag, str(got), str(want)])
