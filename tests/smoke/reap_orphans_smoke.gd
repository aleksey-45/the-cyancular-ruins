extends SceneTree

# 孤儿进程与残留日志清理端到端冒烟测试：
# 模拟游戏异常退出后后台残留内核进程的场景，验证 Tunnel._reap_orphans() 的进程精准回收与日志轮转策略。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/reap_orphans_smoke.gd

const Tunnel := preload("res://core/net/tunnel.gd")

var _checks := 0
var _failed := 0
var _made: Array[String] = []      # 本探针在 log/ 下造过的目录名,收尾逐个删


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("ok - %s" % what)
	else:
		_failed += 1
		print("FAILED - %s" % what)


func _initialize() -> void:
	print("== 孤儿清理实弹冒烟 ==")
	if not Tunnel.available():
		print("SKIP: easytier 未安装(先跑 tools/fetch_easytier.py)")
		quit(1)
		return
	var log_root := AppPaths.log_dir()
	DirAccess.make_dir_recursive_absolute(log_root)
	# ── ① 构造测试临时目录 ──
	var fake_pids: Array[int] = []
	var p := 3900000
	while fake_pids.size() < 31:
		p += 1
		if OS.is_process_running(p):
			continue
		fake_pids.append(p)
	for i in range(fake_pids.size()):
		_touch_fake_dir(log_root, "easytier-guest-%d" % fake_pids[i])
	_touch_fake_dir(log_root, "easytier-guest-%d" % OS.get_process_id())   # 当前活跃进程:不许被清
	var old_fmt := "easytier-host"
	var old_fmt_mine := not DirAccess.dir_exists_absolute(log_root.path_join(old_fmt))
	if old_fmt_mine:
		_touch_fake_dir(log_root, old_fmt)
	OS.delay_msec(1200)
	for i in range(7, 31):                 # 后 24 份重写 -> mtime 变新;前 7 份保持最老
		_touch_fake_dir(log_root, "easytier-guest-%d" % fake_pids[i])
	# ── ② 孤儿进程残留:实际核心服务进程 + 指向已失效 PID 的日志目录 ──
	var orphan_owner := _dead_pid(3910000)
	var orphan_name := "easytier-host-%d" % orphan_owner
	var orphan_dir := log_root.path_join(orphan_name)
	var rpc_port := 0
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") == OK:
		rpc_port = probe.get_local_port()
		probe.stop()
	var args := PackedStringArray([
		"--no-tun", "-i", "10.126.126.250",
		"--network-name", "cyr-reap-smoke", "--network-secret", "reap-smoke",
		"--hostname", "reap-smoke", "--private-mode", "true",
		"--rpc-portal", "127.0.0.1:%d" % rpc_port,
		"-l", "udp://0.0.0.0:0",
		"--file-log-level", "info", "--file-log-dir", orphan_dir,
		"--file-log-size", "5", "--file-log-count", "3",
	])
	var pid := OS.create_process(Tunnel.core_exe(), args)
	_check(pid > 0, "假孤儿内核拉起(pid=%d)" % pid)
	var alive := false
	for i in range(30):
		if pid > 0 and OS.is_process_running(pid):
			alive = true
			break
		OS.delay_msec(100)
	_made.append(orphan_name)
	_check(alive, "假孤儿活着(等它过了启动期)")
	if alive:
		OS.delay_msec(800)
		# ── ③ 清扫 + 断言 ──
		Tunnel._reap_orphans()
		for i in range(50):
			if not OS.is_process_running(pid):
				break
			OS.delay_msec(100)
		_check(not OS.is_process_running(pid), "假孤儿被清扫终结")
		var gone := true
		for i in range(7):
			if DirAccess.dir_exists_absolute(log_root.path_join("easytier-guest-%d" % fake_pids[i])):
				gone = false
		_check(gone, "7 份最老的死主目录被截断")
		var kept := 0
		for i in range(7, 31):
			if DirAccess.dir_exists_absolute(log_root.path_join("easytier-guest-%d" % fake_pids[i])):
				kept += 1
		_check(kept == 24, "24 份较新的死主目录全在(实际 %d)" % kept)
		_check(DirAccess.dir_exists_absolute(log_root.path_join(
				"easytier-guest-%d" % OS.get_process_id())), "活主目录(本进程)没被碰")
		_check(DirAccess.dir_exists_absolute(log_root.path_join(old_fmt)), "旧格式目录没被碰")
	# ── 收尾 ──
	for n in _made:
		Tunnel._remove_dir_recursive(log_root.path_join(n))
	if _failed == 0:
		print("REAP SMOKE OK(%d 项)" % _checks)
		quit(0)
	else:
		print("REAP SMOKE FAILED(%d/%d)" % [_failed, _checks])
		quit(1)


## 造(或重写)一份假目录,里面放一个 easytier.log —— 重写就是刷新 mtime 的手段。
func _touch_fake_dir(log_root: String, dir_name: String) -> void:
	var d := log_root.path_join(dir_name)
	DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(d.path_join("easytier.log"), FileAccess.WRITE)
	if f != null:
		f.store_line("reap-smoke fake log")
		f.close()
	if not _made.has(dir_name):
		_made.append(dir_name)


## 从 start 起找一个当前不存在的进程 pid(假已退出进程的目录名用)。
func _dead_pid(start: int) -> int:
	var p := start
	while OS.is_process_running(p):
		p += 1
	return p
