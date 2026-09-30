extends SceneTree

# 孤儿清理的**实弹**冒烟(手动跑;拉真内核、动真 log/,但造出来的东西收尾全清):
#
#   1. 在 log/ 下造 31 份"死主"目录(easytier-guest-<假死pid>):7 份保持最老的 mtime、
#      24 份重写成较新 mtime;另造 1 份活主目录(本进程 pid)与 1 份旧格式目录(无 pid)。
#   2. 拉起一个真 easytier-core,但日志目录名指向一个**已死的 pid** —— 复现"游戏崩溃后内核
#      残留":拉起者已死,内核就是孤儿。
#   3. `Tunnel._reap_orphans()` 一遍,断言:
#      · 假孤儿被终结;
#      · 恰好删掉 7 份最老的死主目录(死主共 7+24+1(孤儿的)=32 份,保底 25 ⇒ 删最老 7 份),
#        24 份较新的全在;
#      · 活主目录与旧格式目录原样(前者是双开互连的另一局,后者不是本游戏命名的)。
#
#   跑法:`"$GODOT" --headless --path . -s res://tests/reap_orphans_smoke.gd`
#
# ★ 与 netplay_probe 的分工:那个纯静态、不起进程;这个动真格 —— 清扫的两半(杀进程、删目录)
#   都依赖 OS 行为(命令行枚举、mtime、文件锁),只有实弹测得了。
# ★ 中途崩了也不怕:没清掉的假目录 owner 都是死 pid,会被下一次真清扫当过期日志收走。

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
	# ── ① 造假目录 ──
	var fake_pids: Array[int] = []
	var p := 3900000
	while fake_pids.size() < 31:
		p += 1
		if OS.is_process_running(p):
			continue
		fake_pids.append(p)
	for i in range(fake_pids.size()):
		_touch_fake_dir(log_root, "easytier-guest-%d" % fake_pids[i])
	_touch_fake_dir(log_root, "easytier-guest-%d" % OS.get_process_id())   # 活主:不许被清
	var old_fmt := "easytier-host"
	var old_fmt_mine := not DirAccess.dir_exists_absolute(log_root.path_join(old_fmt))
	if old_fmt_mine:
		_touch_fake_dir(log_root, old_fmt)
	OS.delay_msec(1200)
	for i in range(7, 31):                 # 后 24 份重写 → mtime 变新;前 7 份保持最老
		_touch_fake_dir(log_root, "easytier-guest-%d" % fake_pids[i])
	# ── ② 假孤儿:真内核 + 指向死 pid 的日志目录 ──
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


## 从 start 起找一个当前不存在的进程 pid(假死主的目录名用)。
func _dead_pid(start: int) -> int:
	var p := start
	while OS.is_process_running(p):
		p += 1
	return p
