extends SceneTree

const EXPECTED_CHECKS := 9

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	_chk(NetMetrics.snapshot_loss(-1, 100, 1) == 0, "首包(prev_tick=-1)不计丢")
	_chk(NetMetrics.snapshot_loss(100, 101, 1) == 0, "步长 1 的连续包不计丢")
	_chk(NetMetrics.snapshot_loss(100, 103, 1) == 2, "步长 1、跳 3 记丢 2")
	_chk(NetMetrics.snapshot_loss(100, 104, 2) == 1, "步长 2、跳 4 记丢 1")
	_chk(NetMetrics.snapshot_loss(100, 90, 1) == 0 and NetMetrics.snapshot_loss(100, 100, 1) == 0,
			"tick 回退或相等不计丢")
	_chk(NetMetrics.loss_pct(0, 0) == 0, "零样本丢包率为 0")
	_chk(NetMetrics.loss_pct(99, 1) == 1 and NetMetrics.loss_pct(0, 5) == 100,
			"丢包率分母 = rx+lost(99/1 ⇒ 1%,0/5 ⇒ 100%)")
	_chk(NetMetrics.server_log_dir(true, true, "C:/game", "C:/user") == "C:/game/log",
			"导出构建的服务端日志目录 = <exe 目录>/log")
	_chk(NetMetrics.server_log_dir(false, true, "C:/game", "C:/user") == "C:/user"
			and NetMetrics.server_log_dir(true, false, "C:/game", "C:/user") == "C:/user"
			and NetMetrics.server_log_dir(false, false, "C:/game", "C:/user") == "C:/user",
			"客户端 / 开发态一律落 user://logs")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET METRICS OK(%d 条断言):tick 缺口丢包估计 · 丢包率 · 服务端日志目录选择" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("NET METRICS FAILED: %d 处" % _fails.size())
		quit(1)
