extends SceneTree
# 下行接收逻辑守卫(S-03:把 net_bus.gd 里"解码 → tick 去重 → 坏包只警告一次 → 丢包/诊断计数"抽成 SnapshotRx 之后,

const EXPECTED_CHECKS := 7

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/snapshot_rx.gd") == null:
		print("SNAPSHOT RX FAILED: load(snapshot_rx.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var world := _fixture_world()
	var own := _fixture_own()
	var inp := _fixture_input()
	var wb := NetCodec.encode_world(world)
	var ob := NetCodec.encode_own(own)
	var ib := NetCodec.encode_input(inp)

	# ① 同 tick 幂等:同一世界包连收两次只 emit 一次(去掉什么才红:删 `tick <= _last_world_tick` 去重)
	var rx := SnapshotRx.new()
	var d1 := rx.accept_world(wb, 1000)
	var d2 := rx.accept_world(wb, 2000)
	_chk(not d1.is_empty() and d2.is_empty() and int(rx.stats().get("world_rx", 0)) == 1,
			"同 tick 世界包只接受一次(实得 d1 空=%s d2 空=%s rx=%d)" % [
				str(d1.is_empty()), str(d2.is_empty()), int(rx.stats().get("world_rx", 0))])

	# ② 乱序旧包丢弃、新 tick 接受(去掉什么才红:去重判据改成 `tick != _last_world_tick` ⇒ 旧包也会被收)
	var old_wb := NetCodec.encode_world(_with_tick(world, int(world["tick"]) - 1))
	var new_wb := NetCodec.encode_world(_with_tick(world, int(world["tick"]) + 1))
	_chk(rx.accept_world(old_wb, 3000).is_empty() and not rx.accept_world(new_wb, 4000).is_empty(),
			"乱序/迟到旧包丢弃、更新的 tick 接受")

	# ③ 坏包只警告一次(world/own 共用一面旗;输入包另一面):删旗或每包都报 ⇒ 红
	var bad := wb.duplicate()
	bad[0] = (int(bad[0]) + 1) & 0xFF   # 版本字节改坏 ⇒ 解码必空
	var bad_rx := SnapshotRx.new()
	var b1 := bad_rx.accept_world(bad, 1000)
	var b2 := bad_rx.accept_world(bad, 2000)
	var b3 := bad_rx.accept_own(bad)
	var b4 := bad_rx.accept_input(bad)
	_chk(b1.is_empty() and b2.is_empty() and b3.is_empty() and b4.is_empty()
			and bad_rx.warn_snapshot_once() and not bad_rx.warn_snapshot_once()
			and bad_rx.warn_input_once() and not bad_rx.warn_input_once()
			and int(bad_rx.stats().get("world_rx", -1)) == 0,
			"坏包一律丢弃、计数不动,且快照/输入各只警告一次(世界与本人共用快照旗)")

	# ④ reset 后旧 tick 重新被接受(去掉什么才红:reset() 漏清 _last_world_tick)
	var again := rx.accept_world(wb, 5000)
	rx.reset()
	var after := rx.accept_world(wb, 6000)
	_chk(again.is_empty() and not after.is_empty() and rx.world_tick() == int(world["tick"]),
			"reset() 后同 tick 重新接受(重连/换局靠它,否则新纪元包全被当旧包丢)")

	# ⑤ tick 缺口丢包估计 + 步长学习(去掉什么才红:把 lost 计算挪到基线更新之后 ⇒ 永远 0;删步长学习 ⇒ 步长停在 1)
	var gap_rx := SnapshotRx.new()
	for t in [10, 11, 12, 15]:
		gap_rx.accept_world(NetCodec.encode_world(_with_tick(world, t)), 1000000 + t)
	var gs := gap_rx.stats()
	_chk(int(gs.get("world_lost", -1)) == 2 and int(gs.get("step", -1)) == 1,
			"tick 缺口估计:10,11,12,15 中间丢 2 包、步长学到 1(实得 lost=%d step=%d)" % [
				int(gs.get("world_lost", -1)), int(gs.get("step", -1))])

	# ⑥ 本人包:同 tick 幂等 + 返回形状与下游 emit 契约一致({ack_seq, q, c2})
	var own_rx := SnapshotRx.new()
	var o1 := own_rx.accept_own(ob)
	var o2 := own_rx.accept_own(ob)
	_chk(not o1.is_empty() and o2.is_empty()
			and int(o1.get("ack_seq", -1)) == int(own["ack_seq"])
			and int(o1.get("q", -1)) == int(own["q"])
			and (o1.get("c2", {}) as Dictionary).has("pos")
			and (o1.get("c2", {}) as Dictionary).has("inv"),
			"本人包同 tick 幂等且返回 {ack_seq,q,c2} 形状(下游 rollback 锚点零改动的契约)")

	# ⑦ 1Hz 诊断读数键集(--diag 的 snap_rx 载荷;口径要和服务器 snapshot_tx 的 world_msgs 对得上)
	var diag := _diag_after_accept(wb)
	_chk(diag.size() == 8 and diag.has("interval_ms") and diag.has("world_msgs")
			and diag.has("world_lost") and diag.has("world_loss_pct") and diag.has("own_msgs")
			and diag.has("own_lost") and diag.has("own_loss_pct") and diag.has("step"),
			"take_diag() 的键集 = 旧 NetBus snap_rx 的 8 个键(实得 %s)" % str(diag.keys()))

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("SNAPSHOT RX OK(%d 条断言):同 tick 幂等 · 旧包丢弃 · 坏包只警告一次 · reset 重新接受 · 丢包估计 · 本人包形状 · 诊断键集" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("SNAPSHOT RX FAILED: %d 处" % _fails.size())
		quit(1)


func _diag_after_accept(wb: PackedByteArray) -> Dictionary:
	var rx := SnapshotRx.new()
	rx.accept_world(wb, 1000000)
	return rx.take_diag(1000000 + 1000000)


func _with_tick(world: Dictionary, tick: int) -> Dictionary:
	var w: Dictionary = world.duplicate(true)
	w["tick"] = tick
	return w


# ── 夹具(与 net_wire_smoke 同源的最小集:世界/本人载荷的键集与 schema 对齐)──

func _fixture_world() -> Dictionary:
	var e1 := {
		"pos": Vector2(1234.567, -678.901), "vel": Vector2(300.25, -42.125),
		"facing": -1, "pose": 4, "type_id": 7, "hp": 49, "waterproof": 10,
		"downed": true, "aim": Vector2(0.6, -0.8),
		"previewing": true, "haste": false, "rewind": true,
		"trail": [[100.0, 200.0], [101.5, 201.5]],
	}
	return {"tick": 123456, "players": {"1": e1}}


func _fixture_own() -> Dictionary:
	var c2 := {
		"pos": Vector2(1234.567, -678.901), "vel": Vector2(-120.37, 0.4321),
		"facing": -1, "state": 4,
		"slock": 0.125, "coyote": 0.0625, "jbuf": 0.09375,
		"jcut": true, "squat": true, "charge": true,
		"ct": 0.5, "lmv_d": 1, "lmv_t": 0.3125,
		"wp": 10, "wp_t": 0.25, "wp_s": true, "wp_d": 0.1875,
		"clatch": true, "swim": true, "hp": 49,
		"ifr": 0.03125, "down": true,
		"knock": Vector2(-123.456, 78.9), "wslot": 3, "winst": 77,
		"fire_cd": 0.25, "aiming": true, "fire_buf": true,
		"aim_f": 1, "aim_cf": -1, "mag": 7, "rld": true, "rld_t": 0.125,
		"chg": 0.625, "trg": 0.1875,
		"inv": [{"type": 1, "inst": 77, "mag": 30}],
	}
	return {"ack_seq": 123456, "q": 5, "c2": c2}


func _fixture_input() -> Dictionary:
	var src := PacketInputSource.new()
	return PacketInputSource.pack_record(src, 123456, Vector2(0.6, -0.8), 987654321, 12345678)
