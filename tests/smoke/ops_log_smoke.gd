extends SceneTree
# 审计通道冒烟:纯判据(should_audit / ops_file_name / ops_files_to_keep)。
# 用法:"$GODOT" --headless --path . -s res://tests/smoke/ops_log_smoke.gd(外层套 timeout)

const ND := preload("res://core/net/net_diag.gd")
const WL := preload("res://server/lobby/worker_launcher.gd")

# ★ 条数闸:断言数对不上就红。没有它,一次脚本中途报错只让后面的断言静默跳过,判词照打 OK。
const EXPECTED_CHECKS := 16

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

	# ── audit() 端到端:注入测试路径 → 写 → 读回校验 ──
	var tmp := "user://logs/_ops_smoke.jsonl"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://logs"))
	ND.begin_audit_for_test(tmp)
	ND.audit("unit_seeded", {"room": "4821", "n": 3})
	ND.audit("unit_seeded", {"room": "4821", "n": 3})
	var lines := FileAccess.get_file_as_string(tmp).strip_edges().split("\n")
	var ok_line := false
	if lines.size() >= 2:
		var obj = JSON.parse_string(lines[1])
		ok_line = typeof(obj) == TYPE_DICTIONARY and obj.has("t") and obj.has("pid") \
				and obj.has("role") and str(obj.get("event", "")) == "unit_seeded" \
				and int((obj.get("data", {}) as Dictionary).get("n", 0)) == 3
	fail += _check("audit 写出带 t/pid/role/event/data 的 JSON 行", ok_line)
	fail += _check("两次调用 + session_start = 三行", lines.size() == 3)
	fail += _check("audit_path 指向注入路径", ND.audit_path() == tmp)
	# ★ 冒烟进程的 role() 是 client(命令行里既没有 --worker 也没有 --server)⇒ end 之后必须不再写:
	#   这条同时钉住"不许把审计开到玩家客户端"。
	ND.end_audit_for_test()
	ND.audit("after_end", {})
	fail += _check("client 进程不再写",
			FileAccess.get_file_as_string(tmp).strip_edges().split("\n").size() == 3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	# ★ 显式定角色:导出标记从 dedicated_server 换成 serverui 之后,role() 的推断把大厅当成了
	#   client(dev/headless 也没参数)⇒ 服务端必须在启动时显式声明,审计才开得起来。
	ND.set_role("server")
	fail += _check("显式定角色后按 server 审计", ND.role() == "server" and ND.should_audit(ND.role()))
	ND.set_role("")

	# ── tail_lines:worker_lost 的崩溃现场(最后 n 个非空行,单行返回) ──
	fail += _check("文件不存在 → 空串", ND.tail_lines("user://logs/_no_such_file_zz.log", 3) == "")
	var tp := "user://logs/_tail_smoke.log"
	var tf := FileAccess.open(tp, FileAccess.WRITE)
	tf.store_line("alpha")
	tf.store_line("")
	tf.store_line("beta")
	tf.store_line("gamma  ")
	tf.close()
	fail += _check("取最后 2 个非空行并压成一行", ND.tail_lines(tp, 2) == "beta ↵ gamma")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tp))

	# ── worker 日志归档:端口复用不许覆盖上一局崩溃现场 ──
	fail += _check("归档名插在扩展名前",
			WL.archive_name("user://logs/worker_7800.log", "210433") == "user://logs/worker_7800_210433.log")
	var wn := PackedStringArray(["worker_7800.log", "worker_7800_210431.log",
			"worker_7800_210432.log", "worker_7801_210432.log"])
	var keptw := WL.prune_worker_logs(wn, 7800, 2)
	fail += _check("只留该端口最新 2 份归档",
			keptw.size() == 2 and keptw.has("worker_7800_210432.log") and keptw.has("worker_7800_210431.log"))
	fail += _check("不碰别的端口", not keptw.has("worker_7801_210432.log"))
	fail += _check("不含未归档的活文件", not keptw.has("worker_7800.log"))

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
