extends Node

const GROUPS := {"net": "net_case", "transport": "transport_case", "terrain": "terrain_case", "simulation": "simulation_case", "monitor": "monitor_case", "prediction": "prediction_case"}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# 物理查询需要空间已经推进过至少一个物理帧；否则首帧的直接空间状态还没有宽相。
	await get_tree().physics_frame
	var selected: Array = GROUPS.keys()
	var args := OS.get_cmdline_user_args()
	var at := args.find("--groups")
	if at >= 0 and at + 1 < args.size(): selected = Array(args[at + 1].split(",", false))
	var failures := 0
	for group in selected:
		if not GROUPS.has(group):
			printerr("Unknown check group: ", group)
			get_tree().quit(1)
			return
		var suite = load("res://tests/%s.gd" % GROUPS[group]).new()
		suite.run(get_tree())
		suite.cleanup()
		for failure in suite.failures: printerr("FAIL %s: %s" % [group, failure])
		failures += suite.failures.size()
		print("CHECK %s %s (%d)" % [group, "PASS" if suite.failures.is_empty() else "FAIL", suite.checks])
	await get_tree().process_frame
	for child in get_tree().root.get_children():
		if is_instance_valid(child) and child is AudioStreamPlayer:
			if child.playing: await child.finished
			if is_instance_valid(child): child.queue_free()
	await get_tree().process_frame
	Sfx._cache.clear()
	print("CHECKS COMPLETE failures=%d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
