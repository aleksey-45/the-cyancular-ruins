extends Node

# frame_perf_probe 的执行体(挂 root,穿越 change_scene 存活),常量与流程见 frame_perf_probe.gd。

const BASE_FRAMES := 600
const SMOKE_FRAMES := 300


func _ready() -> void:
	_run()


func _run() -> void:
	var tree := get_tree()
	await tree.create_timer(0.5).timeout
	# 钉死变量:地图与难度不钉,两次运行会因随机选图/持久化难度不可比
	RunOptions.map_file = "demo.cyrm"
	RunOptions.difficulty = 1
	Settings.sp_difficulty = 1
	tree.change_scene_to_file("res://Scenes/Level0.tscn")
	await tree.create_timer(2.0).timeout   # 等世界构建/敌人苏醒
	await _sample("baseline", BASE_FRAMES)
	await _smoke_phase()
	_report_scene()
	tree.quit(0)


func _sample(tag: String, frames: int) -> void:
	var dts: Array[float] = []
	var prev := Time.get_ticks_usec()
	for i in range(frames):
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		dts.append(float(now - prev) / 1000.0)
		prev = now
	dts.sort()
	var sum := 0.0
	for v in dts:
		sum += v
	print("PERF[%s]: n=%d avg=%.3fms p50=%.3fms p95=%.3fms max=%.3fms" % [
		tag, dts.size(), sum / dts.size(),
		dts[dts.size() / 2], dts[int(dts.size() * 0.95)], dts[dts.size() - 1]])


func _smoke_phase() -> void:
	# 道具同款烟区:量两件事——①生成瞬间烘焙耗时(使用道具时的卡顿);②烟区存活期的每帧开销
	var cur := get_tree().current_scene
	if cur == null:
		print("PERF[smoke]: 无场景,跳过")
		return
	var pl := get_tree().get_first_node_in_group("player") as Node2D
	var pos := pl.global_position if pl != null else Vector2.ZERO
	var t0 := Time.get_ticks_usec()
	Smoke.spawn_zone(cur, pos, 220.0, 6.0)
	print("PERF[smoke]: spawn 调用返回=%.1fms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	await get_tree().process_frame   # 烘焙在 zone._ready,等一帧
	var zones := get_tree().get_nodes_in_group("smoke_zone")
	if not zones.is_empty():
		var z: Node = zones[0]
		var rng := RandomNumberGenerator.new()
		var t1 := Time.get_ticks_usec()
		var tex: Texture2D = z.call("_bake_frame", rng)
		print("PERF[smoke]: 单帧烘焙=%.1fms (纹理 %s)" % [
			float(Time.get_ticks_usec() - t1) / 1000.0,
			str(tex.get_size()) if tex != null else "<null>"])
	else:
		print("PERF[smoke]: 烟区未生成(SmokeZone 脚本缺失?)")
	await _sample("smoke_active", SMOKE_FRAMES)


func _report_scene() -> void:
	var tree := get_tree()
	var cur := tree.current_scene
	var enemies := tree.get_nodes_in_group("enemies").size()
	var bullets := tree.get_nodes_in_group("bullet").size()
	print("PERF[scene]: %s enemies=%d bullets=%d" % [
		cur.scene_file_path if cur != null else "<null>", enemies, bullets])
