extends Node

const GROUPS := {
	"editor": ["editor_case"], "lan": ["lan_case"], "net": ["net_case"], "transport": ["transport_case"],
	"terrain": ["terrain_case"], "monitor": ["monitor_case"], "prediction": ["prediction_case"],
	"simulation": ["simulation_case", "time_case", "movement_case", "match_rules_case", "presentation_case"],
}

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# 等到场景树发出 physics_frame，在各节点处理本次物理更新之前执行测试。
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
		var issues := 0
		var checks := 0
		for name: String in GROUPS[group]:
			var suite = load("res://tests/%s.gd" % name).new()
			await suite.run(get_tree())
			suite.cleanup()
			for failure in suite.failures: printerr("FAIL %s: %s" % [group, failure])
			issues += suite.failures.size()
			checks += suite.checks
		failures += issues
		print("CHECK %s %s (%d)" % [group, "PASS" if issues == 0 else "FAIL", checks])
	await get_tree().process_frame
	for child in get_tree().root.get_children():
		if is_instance_valid(child) and child is AudioStreamPlayer:
			if child.playing: await child.finished
			if is_instance_valid(child): child.queue_free()
	await get_tree().process_frame
	Sfx._cache.clear()
	print("CHECKS COMPLETE failures=%d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
