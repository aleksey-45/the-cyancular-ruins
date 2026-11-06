extends Node


const DT := 1.0 / 60.0
const MARKER := "ROLLBACK FIDELITY PROBE: ALL-OK"
const EXPECTED_CHECKS := 34

var _failures: Array[String] = []
var _checks := 0

# ★ 假绿防线(Godot 的运行时错误只中断当前函数,调用它的 _ready() 会照常往下走):「测试函数中途报错 → 一条 _check 都没跑到 → _failures 仍空 → 照样打印 ALL-OK 并 exit 0」。
#   实测:把 map_px 从 _close_enough 里删掉(必报错),红跑却印了 ALL-OK。故每个测试函数在最后一行给自己盖完成戳;缺戳 = 没跑完 = 红。
var _ran: Dictionary = {}

func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[fid]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[fid]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[fid]   ✗ %s" % msg)


func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _ready() -> void:
	CombatComponent.pvp_arena = true
	_test_torus_compare()
	_require_ran("torus")
	_test_predicted_fields()
	_require_ran("predicted_fields")
	_test_contact_tolerance()
	_require_ran("contact_tol")
	await _test_event_alignment()
	_require_ran("event_align")
	_test_feedback_only()
	_require_ran("feedback_only")
	_check_source_guard()
	if _checks != EXPECTED_CHECKS:
		_fail("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	print("[fid] checks = %d (EXPECTED_CHECKS=%d)" % [_checks, EXPECTED_CHECKS])
	if _failures.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("ROLLBACK FIDELITY PROBE: FAIL")
		for f in _failures:
			print("[fid]   ✗ %s" % f)
		get_tree().quit(1)


func _test_torus_compare() -> void:
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(w * 0.5, h * 0.5)

	var c := PredictionRollback.new()
	c.bind(p)
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"winst": 0, "aim": Vector2(1.0, 0.0)})

	var s14: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s14["pos"] = (s14["pos"] as Vector2) + Vector2(float(w), 0.0)
	var s15: Dictionary = (c._captures[15] as Dictionary).duplicate()
	s15["pos"] = (s15["pos"] as Vector2) + Vector2(float(w), 0.0)

	c.map_px = Vector2(float(w), float(h))
	var rb0 := c.rollback_count()
	c.on_authoritative(14, s14)
	c.reconcile()
	_check(c.rollback_count() == rb0,
			"① 环面同一物理点(差一整幅地图宽)不判分歧(回滚 ×%d→×%d)" % [rb0, c.rollback_count()])

	# ② 反证:map_px 归零 → 同一份形状的载荷必须判成分歧(证明 ① 不是空转断言)
	c.map_px = Vector2.ZERO
	var rb1 := c.rollback_count()
	c.on_authoritative(15, s15)
	c.reconcile()
	_check(c.rollback_count() == rb1 + 1,
			"② 去掉环面处理后同一份载荷判为分歧(回滚 ×%d→×%d)" % [rb1, c.rollback_count()])

	p.queue_free()
	_ran["torus"] = true


func _test_predicted_fields() -> void:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	var cap: Dictionary = p.capture_state()
	var missing: Array = []
	for f in PredictionRollback.PREDICTED_FIELDS:
		if not cap.has(String(f)):
			missing.append(String(f))
	_check(missing.is_empty(),
			"㉑ PREDICTED_FIELDS 每个键都在真 capture_state() 里(缺 %s)" % str(missing))
	p.queue_free()
	_ran["predicted_fields"] = true


func _make_contact_fixture() -> Dictionary:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_HEIGHT * 0.5)
	var c := PredictionRollback.new()
	c.bind(p)
	c.pos_tol = 2.0
	c.contact_pos_tol = 24.0
	c.map_px = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"winst": 0, "aim": Vector2(1.0, 0.0)})
	var s: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s["pos"] = (s["pos"] as Vector2) + Vector2(10.0, 0.0)
	return {"ctrl": c, "player": p, "state": s}


func _test_contact_tolerance() -> void:
	var f1: Dictionary = _make_contact_fixture()
	var c1: PredictionRollback = f1["ctrl"]
	c1.in_contact = false
	var rb0 := c1.rollback_count()
	c1.on_authoritative(14, f1["state"])
	c1.reconcile()
	_check(c1.rollback_count() == rb0 + 1,
			"③ 非接触期 10px 偏差判为分歧(回滚 ×%d→×%d)" % [rb0, c1.rollback_count()])
	(f1["player"] as Node).queue_free()

	# ② 接触期:同一份形状的载荷、只把 in_contact 翻成 true ⇒ 必须不回滚。★ 两份夹具各自独立(不复用控制器):①的回滚会重放并改写 capture,复用会让 ② 比到别的东西。
	var f2: Dictionary = _make_contact_fixture()
	var c2: PredictionRollback = f2["ctrl"]
	c2.in_contact = true
	var rb1 := c2.rollback_count()
	c2.on_authoritative(14, f2["state"])
	c2.reconcile()
	_check(c2.rollback_count() == rb1,
			"④ 贴身时同一份载荷不再判分歧(回滚 ×%d→%d,容差 2→24px)" % [rb1, c2.rollback_count()])
	(f2["player"] as Node).queue_free()

	_ran["contact_tol"] = true


# ── 源码守卫 ── map_px 不接线的话,环面修复在真机上是惰性的、而且静默:不报错、探针全绿、生产行为与修复前逐帧一致(实测过)。所以把「接线了」这件事本身变成断言。
func _check_source_guard() -> void:
	var lines0 := FileAccess.get_file_as_string("res://scenes/pvp_match_client.gd").split("\n")
	var boot := _func_block(lines0, "func _boot_world(")
	var found := false
	for i in range(boot[0] + 1, boot[1]):
		if lines0[i].strip_edges().begins_with("#"):
			continue
		if lines0[i].contains("map_px"):
			found = true
			break
	_check(boot[0] >= 0 and found,
			"PvpMatchClient._boot_world() 给控制器设了 map_px(不设 = 环面修复惰性且静默;块没找到 = 引导段入口名改了,守卫也要跟着改)")

	# ② 接触提示的接线(in_contact 必须在 note_post_step 之前写 —— 它是那一步的消费方)。漏了这一行 = 静默退回 2px 容差:不报错、探针全绿、真机行为与改动前逐帧一致。
	var txt2 := FileAccess.get_file_as_string("res://scenes/pvp_match_client.gd")
	var lines := txt2.split("\n")
	var hint_line := -1
	var hint_count := 0
	for i in range(lines.size()):
		var line := lines[i]
		if line.strip_edges().begins_with("#"):
			continue
		if line.contains("_rollback.in_contact = _update_contact_state()"):
			hint_count += 1
			hint_line = i
	_check(hint_count == 1,
			"接触提示只许有**一处**赋值(实得 %d 处 —— 0 = 漏接线,>1 = 有两处在抢)" % hint_count)
	var note_line := -1
	if hint_line >= 0:
		var blk_end := lines.size()
		for i in range(hint_line + 1, lines.size()):
			if lines[i].begins_with("func "):
				blk_end = i
				break
		for i in range(hint_line + 1, blk_end):
			if lines[i].strip_edges().begins_with("#"):
				continue
			if lines[i].contains(".note_post_step("):
				note_line = i
				break
	_check(note_line >= 0,
			"接触提示的赋值排在**同一帧块内**的 note_post_step 之前(hint@%d, note@%d;顺序反了 = 静默退回 2px 容差)"
			% [hint_line, note_line])

	# ③ 受击事件时刻对齐的接线(2026-10-28):网络回调只入队,由物理帧开头的 _drain_hit_events 注入
	var lines3 := FileAccess.get_file_as_string("res://scenes/pvp_match_client.gd").split("\n")
	var ev_block := _func_block(lines3, "func _on_hit_event(")
	var drain_block := _func_block(lines3, "func _drain_hit_events(")
	var apply_block := _func_block(lines3, "func _apply_local_hit_event(")
	var queued := 0
	var direct_hit := 0
	for i in range(ev_block[0] + 1, ev_block[1]):
		if lines3[i].strip_edges().begins_with("#"):
			continue
		if lines3[i].contains("_pending_hit_events.append("):
			queued += 1
		if lines3[i].contains("_apply_local_hit_event("):
			direct_hit += 1
	_check(ev_block[0] >= 0 and queued == 1 and direct_hit == 0,
			"受击回调只许入队一次(pending=%d,直接注入=%d;直接注入 = 在 idle 帧重放,move_and_slide 按渲染帧 delta 缩放)" % [queued, direct_hit])

	var drained := 0
	for i in range(drain_block[0] + 1, drain_block[1]):
		if lines3[i].strip_edges().begins_with("#"):
			continue
		if lines3[i].contains("_apply_local_hit_event("):
			drained += 1
	_check(drain_block[0] >= 0 and drained == 1,
			"物理帧开头只许有一处 _drain_hit_events → _apply_local_hit_event(实得 %d 处;0 = 队列没人消费)" % drained)

	var phys_block := _func_block(lines3, "func _physics_process(")
	var drain_calls := 0
	for i in range(phys_block[0] + 1, phys_block[1]):
		if lines3[i].strip_edges().begins_with("#"):
			continue
		if lines3[i].contains("_drain_hit_events()"):
			drain_calls += 1
	_check(phys_block[0] >= 0 and drain_calls == 1,
			"_physics_process 必须消费一次 _drain_hit_events()(实得 %d 处;0 = 受击事件永远不生效)" % drain_calls)

	var inject_calls := 0
	var fallback := 0
	for i in range(apply_block[0] + 1, apply_block[1]):
		var line3 := lines3[i]
		if line3.strip_edges().begins_with("#"):
			continue
		if line3.contains("apply_external_event("):
			inject_calls += 1
		if line3.contains("_local.take_hit(") and line3.contains(", true)"):
			fallback += 1
	_check(apply_block[0] >= 0 and inject_calls == 1,
			"事件对齐只许有**一处** apply_external_event(实得 %d 处;0 = 注入没接上)" % inject_calls)
	_check(fallback == 1,
			"兜底路径必须存在且只播反馈(take_hit 第 5 参 = true;实得 %d 处)" % fallback)

	var lines4 := FileAccess.get_file_as_string("res://server/match/combat_system.gd").split("\n")
	var anchor_block := _func_block(lines4, "func event_seq_for(")
	var stepped_uses := 0
	var ack_uses := 0
	var srv_tick_uses := 0
	for i in range(anchor_block[0] + 1, anchor_block[1]):
		if lines4[i].strip_edges().begins_with("#"):
			continue
		if lines4[i].contains("_stepped_seq"):
			stepped_uses += 1
		if lines4[i].contains("_ack_seq.get("):
			ack_uses += 1
		if lines4[i].contains("_srv_tick"):
			srv_tick_uses += 1
	_check(anchor_block[0] >= 0 and stepped_uses == 1 and ack_uses == 1 and srv_tick_uses == 0,
			"事件锚点用 _stepped_seq(实得 %d 处;ack 仅作首帧兜底 %d 处;srv_tick %d 处 —— 1/1/0 才对)" % [stepped_uses, ack_uses, srv_tick_uses])

	var lines5 := FileAccess.get_file_as_string("res://server/match/match_host.gd").split("\n")
	var host_block := _func_block(lines5, "func _physics_process(")
	var sched := 0
	for i in range(host_block[0] + 1, host_block[1]):
		if lines5[i].strip_edges().begins_with("#"):
			continue
		if lines5[i].contains("_record_stepped_seq") and lines5[i].contains("call_deferred"):
			sched += 1
	_check(host_block[0] >= 0 and sched == 1,
			"MatchHost 每 tick 排一次帧末 _record_stepped_seq(实得 %d 处;0 = 锚点永远不前进)" % sched)
	var rec_block := _func_block(lines5, "func _record_stepped_seq(")
	var rec_writes := 0
	for i in range(rec_block[0] + 1, rec_block[1]):
		if lines5[i].strip_edges().begins_with("#"):
			continue
		if lines5[i].contains("_stepped_seq["):
			rec_writes += 1
	_check(rec_block[0] >= 0 and rec_writes == 1,
			"_record_stepped_seq 必须写一次 _stepped_seq(实得 %d 处)" % rec_writes)

	# ⑤ 落水窒息不回显(2026-10-29):服务端必须跳过 cause=="water" 的 hit_event,客户端溺水调用必须带 cause ——
	#    漏任一处 = 客户端二次扣血(每次窒息多一次回滚)。删掉不报错,只能靠源码守卫。
	var lines6 := FileAccess.get_file_as_string("res://server/match/combat_system.gd").split("\n")
	var hit_fn := _func_block(lines6, "func on_player_hit(")
	var water_skip := 0
	for i in range(hit_fn[0] + 1, hit_fn[1]):
		if lines6[i].strip_edges().begins_with("#"):
			continue
		if lines6[i].contains("cause == \"water\""):
			water_skip += 1
	_check(hit_fn[0] >= 0 and water_skip == 1,
			"服务端必须跳过 cause=water 的 hit_event(实得 %d 处;0 = 溺水伤害双计)" % water_skip)

	var water_calls := 0
	for line7 in FileAccess.get_file_as_string("res://scenes/player/player.gd").split("\n"):
		if line7.strip_edges().begins_with("#"):
			continue
		if line7.contains("take_hit(global_position, PlayerParams.player_waterproof_damage") and line7.contains("\"water\""):
			water_calls += 1
	_check(water_calls == 1,
			"溺水 take_hit 必须带 cause=\"water\"(实得 %d 处;0 = 服务端不会跳过回声)" % water_calls)


func _func_block(lines: Array, header_prefix: String) -> Array:
	for i in range(lines.size()):
		if String(lines[i]).begins_with(header_prefix):
			var end := lines.size()
			for j in range(i + 1, lines.size()):
				if String(lines[j]).begins_with("func "):
					end = j
					break
			return [i, end]
	return [-1, -1]


func _make_event_fixture(x_off: float) -> Dictionary:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	# ★ 必须在物理帧里手动步进才能拿到与服务器同口径的 move_and_slide(帧外按渲染帧 delta 缩放),故关引擎自动步进、只手动步。
	p.set_physics_process(false)
	var start := Vector2(GameParameters.MAP_WIDTH * 0.5 + x_off, GameParameters.MAP_HEIGHT * 0.5)
	p.global_position = start
	var c := PredictionRollback.new()
	c.bind(p)
	c.map_px = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var recs: Array = []
	for i in range(30):
		recs.append({"seq": i + 1, "ax": 1.0, "held": 0, "pressed": 0, "released": 0,
				"winst": 0, "aim": Vector2(1.0, 0.0)})
	return {"ctrl": c, "player": p, "start": start, "recs": recs,
			"hp": int((p.capture_state() as Dictionary).get("hp", 0))}


func _hit_once(p: Node2D) -> void:
	p.call("take_hit", p.global_position, 10, true)


# ★ 轨迹类断言必须在物理帧里步进:Godot 4 的 move_and_slide() 在物理帧外按渲染帧 delta 缩放(实测:同一速度在
#   idle 帧的位移随帧间隔在 0.01~2px 之间变;首帧前才是 0)⇒ 帧外重放的轨迹随帧率变、不可作为黄金对照。等 physics_frame 再手动步。
func _phys_advance(c: PredictionRollback, rec: Dictionary) -> void:
	await get_tree().physics_frame
	c.advance(rec)


func _test_event_alignment() -> void:
	var f1: Dictionary = _make_event_fixture(0.0)
	var c1: PredictionRollback = f1["ctrl"]
	var p1: Node2D = f1["player"]
	for r in f1["recs"]:
		await _phys_advance(c1, r)
	var hp1: int = int(f1["hp"])
	var applied := [0]
	var ok = c1.apply_external_event(19, func() -> void:
		applied[0] += 1
		_hit_once(p1))
	_check(ok == PredictionRollback.EventApply.APPLIED and applied[0] == 1,
			"⑤ 环内事件按历史 seq 注入成功(ok=%s,事件调用 %d 次)" % [str(ok), applied[0]])
	_check(c1.rollback_count() == 0, "⑥ 事件对齐不计入回滚计数(回滚 ×%d)" % c1.rollback_count())
	_check(int((p1.capture_state() as Dictionary).get("hp", 0)) == hp1 - 10,
			"⑦ 注入后 hp 恰扣一次(期望 %d,实得 %d)" % [hp1 - 10, int((p1.capture_state() as Dictionary).get("hp", 0))])

	var f2: Dictionary = _make_event_fixture(400.0)
	var c2: PredictionRollback = f2["ctrl"]
	var p2: Node2D = f2["player"]
	for i in range(19):
		await _phys_advance(c2, (f2["recs"] as Array)[i])
	_hit_once(p2)
	for i in range(19, 30):
		await _phys_advance(c2, (f2["recs"] as Array)[i])
	var cap1: Dictionary = c1._captures[30]
	var cap2: Dictionary = c2._captures[30]
	var d1: Vector2 = (cap1["pos"] as Vector2) - (f1["start"] as Vector2)
	var d2: Vector2 = (cap2["pos"] as Vector2) - (f2["start"] as Vector2)
	var dv: float = (cap1["vel"] as Vector2).distance_to(cap2["vel"])
	_check(d1.distance_to(d2) < 0.01 and dv < 0.01,
			"⑧ 注入轨迹 == 黄金轨迹(位移差 %.4f px / 速度差 %.4f)" % [d1.distance_to(d2), dv])
	_check(int(cap1.get("hp", 0)) == int(cap2.get("hp", 0)),
			"⑨ 黄金对照 hp 一致(%d vs %d)" % [int(cap1.get("hp", 0)), int(cap2.get("hp", 0))])

	var calls := [0]
	var ok_future = c1.apply_external_event(31, func() -> void: calls[0] += 1)
	c1.on_authoritative(25, (c1._captures[25] as Dictionary).duplicate(true))
	c1.reconcile()
	var hp_before := int((p1.capture_state() as Dictionary).get("hp", 0))
	var ok_acked = c1.apply_external_event(25, func() -> void: calls[0] += 1)
	_check(typeof(ok_future) == TYPE_INT and ok_future == PredictionRollback.EventApply.REJECTED
			and typeof(ok_acked) == TYPE_INT and ok_acked == PredictionRollback.EventApply.REJECTED
			and calls[0] == 0
			and int((p1.capture_state() as Dictionary).get("hp", 0)) == hp_before,
			"⑪ 环外/已 ack 事件拒绝注入且不改整态(future=%s acked=%s 调用 %d 次)" % [str(ok_future), str(ok_acked), calls[0]])

	var authority: Dictionary = (cap2 as Dictionary).duplicate(true)
	authority["pos"] = (authority["pos"] as Vector2) + ((f1["start"] as Vector2) - (f2["start"] as Vector2))
	var rb0 := c1.rollback_count()
	c1.on_authoritative(30, authority)
	c1.reconcile()
	_check(c1.rollback_count() == rb0 and int((p1.capture_state() as Dictionary).get("hp", 0)) == hp1 - 10,
			"⑩ 注入后 reconcile 对上黄金权威不回滚(回滚 ×%d→×%d)" % [rb0, c1.rollback_count()])

	var f3: Dictionary = _make_event_fixture(800.0)
	var c3: PredictionRollback = f3["ctrl"]
	var p3: Node2D = f3["player"]
	for r in f3["recs"]:
		await _phys_advance(c3, r)
	var hp3: int = int(f3["hp"])
	c3.apply_external_event(19, func() -> void: _hit_once(p3))
	c3.apply_external_event(19, func() -> void: _hit_once(p3))
	_check(int((p3.capture_state() as Dictionary).get("hp", 0)) == hp3 - 20,
			"⑫ 同 seq 两次受击各扣一次(期望 %d,实得 %d)" % [hp3 - 20, int((p3.capture_state() as Dictionary).get("hp", 0))])

	var f4: Dictionary = _make_event_fixture(1200.0)
	var c4: PredictionRollback = f4["ctrl"]
	var p4: Node2D = f4["player"]
	for r in f4["recs"]:
		await _phys_advance(c4, r)
	c4.apply_external_event(19, func() -> void: _hit_once(p4))
	var applied4 := [0]
	var ok_late = c4.apply_external_event(18, func() -> void: applied4[0] += 1)
	_check(ok_late == PredictionRollback.EventApply.REJECTED and applied4[0] == 0,
			"⑬ 乱序(seq 回退)事件拒绝注入(返回 %s)" % str(ok_late))

	var f5: Dictionary = _make_event_fixture(1600.0)
	var c5: PredictionRollback = f5["ctrl"]
	var p5: Node2D = f5["player"]
	for r in f5["recs"]:
		await _phys_advance(c5, r)
	var hp5: int = int(f5["hp"])
	c5.apply_external_event(25, func() -> void: _hit_once(p5))
	var auth20: Dictionary = (c5._captures[20] as Dictionary).duplicate(true)
	auth20["pos"] = (auth20["pos"] as Vector2) + Vector2(20.0, 0.0)
	c5.on_authoritative(20, auth20)
	c5.reconcile()
	_check(c5.rollback_count() == 1 and int((p5.capture_state() as Dictionary).get("hp", 0)) == hp5 - 10,
			"⑰ 迟到旧 ack 的回滚重放会重新应用注入事件(hp 期望 %d,实得 %d)" % [hp5 - 10, int((p5.capture_state() as Dictionary).get("hp", 0))])
	_check(int((c5._captures[30] as Dictionary).get("hp", 0)) == hp5 - 10,
			"⑱ 重放后的捕获链也带回事件(hp 期望 %d,实得 %d)" % [hp5 - 10, int((c5._captures[30] as Dictionary).get("hp", 0))])

	_check(c1.event_aligns() == 1 and c1.event_rejects() == 2
			and c1.event_reject_breakdown() == "ack=1 future=1 missing=0 order=0",
			"⑯ 事件计数 applied=%d rejected=%d [%s](期望 1/2 且 ack=1 future=1)" % [
			c1.event_aligns(), c1.event_rejects(), c1.event_reject_breakdown()])

	_ran["event_align"] = true


func _test_feedback_only() -> void:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_HEIGHT * 0.5)
	var n := [0]
	var cause := [""]
	p.combat.took_hit.connect(func(_sp: Vector2, _d: int, c: String) -> void:
		n[0] += 1
		cause[0] = c)
	var st0: Dictionary = p.capture_state()
	var hp0: int = int(st0["hp"])
	var vel0: Vector2 = st0["vel"]
	var ifr0: float = float(st0["ifr"])

	p.call("take_hit", p.global_position, 10, false, -1.0, true)
	var st1: Dictionary = p.capture_state()
	_check(int(st1["hp"]) == hp0 and (st1["vel"] as Vector2).is_equal_approx(vel0)
			and is_equal_approx(float(st1["ifr"]), ifr0) and n[0] == 0,
			"⑭ 反馈-only 不动 hp/速度/无敌帧,也不 emit took_hit")

	p.call("take_hit", p.global_position, 10)
	var st2: Dictionary = p.capture_state()
	_check(int(st2["hp"]) == hp0 - 10 and n[0] == 1,
			"⑮ 正常受击仍扣血并 emit took_hit(证明 ⑭ 不是恒真断言)")

	p.call("take_hit", p.global_position, 10, false, -1.0, false, "water")
	_check(cause[0] == "water", "⑲ 溺水伤害的 took_hit 带 cause=water(实得 %s)" % cause[0])
	p.call("take_hit", p.global_position, 10)
	_check(cause[0] == "", "⑳ 普通伤害 cause 为空(实得 %s;证明 ⑲ 不是恒真)" % cause[0])

	_ran["feedback_only"] = true
