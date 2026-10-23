extends SceneTree
# 审计通道冒烟:纯判据(should_audit / ops_file_name / ops_files_to_keep)。
# 用法:"$GODOT" --headless --path . -s res://tests/smoke/ops_log_smoke.gd(外层套 timeout)

const ND := preload("res://core/net/net_diag.gd")

# ★ 条数闸:断言数对不上就红。没有它,一次脚本中途报错只让后面的断言静默跳过,判词照打 OK。
const EXPECTED_CHECKS := 5

var _checks := 0


func _initialize() -> void:
	var fail := 0

	fail += _check("client 不审计", ND.should_audit("client") == false)
	fail += _check("server 审计", ND.should_audit("server") == true)
	fail += _check("文件名带 role/pid/stamp",
			ND.ops_file_name("server", 4321, "20261021_210433") == "ops-server-4321-20261021_210433.jsonl")

	var names := PackedStringArray(["ops-server-1-a.jsonl", "ops-server-1-c.jsonl",
			"ops-server-1-b.jsonl", "diag-server-1-a.jsonl"])
	var kept := ND.ops_files_to_keep(names, 2)
	fail += _check("只留最新 2 份且不动非 ops 文件",
			kept.size() == 2 and kept.has("ops-server-1-c.jsonl") and kept.has("ops-server-1-b.jsonl")
			and not kept.has("diag-server-1-a.jsonl"))
	fail += _check("不足 keep 时全留",
			ND.ops_files_to_keep(PackedStringArray(["ops-server-1-a.jsonl"]), 60).size() == 1)

	if _checks != EXPECTED_CHECKS:
		fail += 1
		printerr("  FAIL- 条数闸:_checks=%d 期望 %d" % [_checks, EXPECTED_CHECKS])

	if fail == 0:
		print("OPS_LOG_OK(%d checks): 审计纯判据(client 不审计 / 文件名 / 保留名单)" % _checks)
		quit(0)
	else:
		printerr("OPS_LOG_FAIL: %d 项断言失败(共 %d)" % [fail, _checks])
		quit(1)


func _check(name: String, cond: bool) -> int:
	_checks += 1
	if cond:
		print("  ok  - " + name)
		return 0
	printerr("  FAIL- " + name)
	return 1
