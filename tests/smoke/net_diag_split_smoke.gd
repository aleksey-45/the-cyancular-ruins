extends SceneTree
# 诊断日志**分流**守卫(2026-10-31,用户报「日志 700KB 混在一起,找都不好找」):

const EXPECTED_CHECKS := 5
const TMP_DIAG := "user://net_diag_split_test/diag.jsonl"
const TMP_METRICS := "user://net_diag_split_test/metrics.jsonl"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/net_diag.gd") == null:
		print("NET DIAG SPLIT FAILED: load(net_diag.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("user://net_diag_split_test")

	# ① 纯函数节流判据(默认 10s;verbose 1s 由 --diag-verbose 打开,这里只钉非 verbose 的常量)
	_chk(NetDiag.metric_due(-1, 0, 10000)
			and not NetDiag.metric_due(0, 9999, 10000)
			and NetDiag.metric_due(0, 10000, 10000)
			and NetDiag.metric_due(0, 5, 1)
			and NetDiag.metric_interval_ms() >= 1000,
			"metric_due 边界:首条必写 / 未满间隔不写 / 满间隔写(实得 interval=%d)" % NetDiag.metric_interval_ms())

	# ② 事件与心跳**分两个文件**:log_event 进 diag,log_metric 进 metrics(不再混一处)
	NetDiag.begin_for_test(TMP_DIAG)
	NetDiag.begin_metrics_for_test(TMP_METRICS)
	NetDiag.log_event("rollback", {"ack": 1})
	NetDiag.log_metric("queue", {"role": 1, "depth": 0})
	NetDiag.flush()   # ★ 必须刷:FileAccess 有缓冲,不刷读到的是旧内容(客户端 role 不逐行 flush)
	var diag_text := FileAccess.get_file_as_string(TMP_DIAG)
	var metrics_text := FileAccess.get_file_as_string(TMP_METRICS)
	_chk(diag_text.contains("\"rollback\"") and not diag_text.contains("\"queue\"")
			and metrics_text.contains("\"queue\"") and not metrics_text.contains("\"rollback\""),
			"事件/心跳分文件(diag 只有 rollback;metrics 只有 queue)")

	# ③ 心跳节流:同一 event 立刻再写一次必须被丢掉(默认 10s 间隔)
	NetDiag.log_metric("queue", {"role": 1, "depth": 99})
	NetDiag.flush()
	var queue_lines := 0
	for ln in FileAccess.get_file_as_string(TMP_METRICS).split("\n"):
		if str(ln).contains("\"queue\""):
			queue_lines += 1
	_chk(queue_lines == 1 and NetDiag.metrics_count() == 1,
			"同一心跳事件未满间隔被节流(metrics 里 queue 行数 %d,计数 %d;期望 1/1)"
			% [queue_lines, NetDiag.metrics_count()])

	# ④ 两条路径互不相同(文件名口径:diag-* / metrics-*)
	_chk(NetDiag.file_path() == TMP_DIAG and NetDiag.metrics_path() == TMP_METRICS
			and NetDiag.file_path() != NetDiag.metrics_path(),
			"diag / metrics 是两份独立文件(实得 %s / %s)" % [NetDiag.file_path(), NetDiag.metrics_path()])

	# ⑤ CYR_LOG_DIR 环境变量整体覆盖落盘目录(真链路按支分目录;不设时行为不变 —— 由 net_metrics_smoke 钉 server_log_dir)
	var had := OS.get_environment("CYR_LOG_DIR")
	OS.set_environment("CYR_LOG_DIR", "user://net_diag_split_test/override")
	var overridden := NetDiag.log_dir()
	if had.is_empty():
		OS.unset_environment("CYR_LOG_DIR")
	else:
		OS.set_environment("CYR_LOG_DIR", had)
	_chk(overridden == "user://net_diag_split_test/override",
			"CYR_LOG_DIR 覆盖 log_dir(实得 %s)" % overridden)

	NetDiag.end_metrics_for_test()
	NetDiag.end_for_test()
	DirAccess.remove_absolute(TMP_DIAG)
	DirAccess.remove_absolute(TMP_METRICS)

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET DIAG SPLIT OK(%d 条断言):节流边界 · 事件/心跳分文件 · 心跳节流 · 两路径独立 · CYR_LOG_DIR 覆盖" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("NET DIAG SPLIT FAILED: %d 处" % _fails.size())
		quit(1)
