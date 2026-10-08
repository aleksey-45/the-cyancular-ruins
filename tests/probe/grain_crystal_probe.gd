extends Node

# 乌鸫精英结晶探针(场景级):
#   ① 乌鸫实例带 elite 标(免疫回溯/加速与玩家同步的依据)
#   ② 击杀 -> 结晶 FX 生成(grain_crystal 组)
#   ③ 吸收 -> 账户 +300 + 怀表颤抖
# 用法:godot --headless --path . res://tests/probe/grain_crystal_probe.tscn

var _fails: Array[String] = []


func _fail(m: String) -> void:
	_fails.append(m)


func _wait_ms(ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		await get_tree().process_frame


func _run() -> void:
	var tree := get_tree()
	await tree.process_frame
	var lvl: Node = load("res://scenes/level_0.tscn").instantiate()
	tree.root.add_child(lvl)
	await _wait_ms(400)
	var acc: GrainAccount = Level0.grain_account
	var vp: Node = lvl.get_node_or_null("WorldViewport")
	var player: Node2D = lvl.get_node_or_null("WorldViewport/Player")
	if acc == null or vp == null or player == null:
		print("GRAIN CRYSTAL PROBE: FAIL(世界未就绪)")
		tree.quit(1)
		return

	# ① 手动放一只乌鸫在玩家旁边
	var bird: Node2D = (load("res://scenes/enemies/enemy_black_bird.tscn") as PackedScene).instantiate()
	vp.add_child(bird)
	bird.global_position = player.global_position + Vector2(120, -40)
	await _wait_ms(200)
	if not bird.has_meta("elite"):
		_fail("乌鸫实例缺 elite 标")

	# ② 击杀 -> 结晶 FX 应在数帧内出现
	var bal0: int = int(acc.balance)
	bird.call("hurt", 9999, Vector2.RIGHT, 0.0)
	await _wait_ms(120)
	if tree.get_nodes_in_group("grain_crystal").is_empty():
		_fail("击杀后未生成结晶 FX")

	# ③ 轮询等待吸收:余额 +300,且吸收当刻怀表在颤抖
	var watch: Node = null
	var found: Array = lvl.find_children("*", "WatchHud", true, false)
	if not found.is_empty():
		watch = found[0]
	var got := false
	var tremble_seen := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3500:
		await tree.process_frame
		if int(acc.balance) > bal0:
			got = true
			if watch != null and float(watch.get("_tremble_t")) > 0.0:
				tremble_seen = true
			break
	if not got:
		_fail("结晶未被吸收(余额未 +300;%.0fms)" % float(Time.get_ticks_msec() - t0))
	else:
		var delta_bal: int = int(acc.balance) - bal0
		if delta_bal != TimeParams.ELITE_GRAIN_DROP:
			_fail("入账数额不符(得 %d 期望 %d)" % [delta_bal, TimeParams.ELITE_GRAIN_DROP])
		if watch != null and not tremble_seen:
			_fail("吸收时怀表未颤抖")

	if _fails.is_empty():
		print("GRAIN CRYSTAL PROBE: OK(elite标/结晶生成/吸收+300/怀表颤抖)")
		tree.quit(0)
	else:
		print("GRAIN CRYSTAL PROBE: FAIL(%d): %s" % [_fails.size(), "; ".join(_fails)])
		tree.quit(1)


func _ready() -> void:
	_run.call_deferred()
