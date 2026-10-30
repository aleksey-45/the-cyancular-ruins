class_name ProcUtil
extends RefCounted

# 进程 / 端口相关的平台工具(**仅 Windows 有效**:taskkill 与 PowerShell)。纯静态、不引 autoload。
#
# ★ 为什么收这里:同一段「按 UDP 端口找属主进程并强杀」的 PowerShell 串原先在
#   `server/worker_launcher.gd`(按端口杀 worker)与 `server/server_main.gd`(大厅启动前清残留)
#   各写一遍,**逐字相同** —— 而其中一条写法是踩过坑才修对的(见下),抄第二份时没有任何提示。
#   同一个坑在本仓补过不止一次,故把「正确写法」收成一处,别再给第二次抄的机会。
#
# ⚠ 取属主进程必须用 `Select -ExpandProperty OwningProcess`:`% OwningProcess` 这种写法
#   (ForEach-Object 后接裸名字)**取不到属性**、实测拿空 → 一个进程都杀不掉,且**不报错**。
#   后果:旧进程继续占着 7777 → 新实例 bind 失败瞬间退出(双击服务端 exe 闪退)。
#   守卫:kh_l5_probe.gd(已删·2026-10-09) 第 3 条(判据取**去注释视图** —— 解释这个坏写法的注释本身
#   含该串,算进去会让断言永远红)。
#
# ★ 2026-10-04 加**保守护栏**(审计 §2.1「无差别强杀端口属主」):取到属主 PID 后先查进程名,
#   只有**我们这一族**才 Stop-Process,否则**只打印一行、不杀**。取向 = **证不出是"我们这一族"
#   的,就不杀**;名字读不出来(权限/竞态)同样不杀 —— 原先这里是**不管属主是谁一律强杀**。
#   名族名单(前缀):`Godot*`(引擎/编辑器/console 版)、`Cyancular*`(服务端 exe)、
#   `The Cyancular*`(客户端/大厅 exe 与它的归档改名版);**外加"本进程自己的 exe 名"** ——
#   发布版 exe 被改过名(如 `RoF_server.exe`)时旧实例的进程名就是它,光靠前缀认不出来
#   (Review Focus 5 点名的失败模式:清不掉 ⇒ 又 bind 失败闪退)。
#   ⚠ 同一份名单在 `start_server.bat` 的 `:reap_port_holder` 里**另有一份**(bat 没法 import
#   GDScript)⇒ 改一处必须同时改另一处。
#   ★ 动机没修坏(本文件 :5-9 那条「双击服务端别闪退」):旧实例、旧 worker **都是我们这一族**
#     ⇒ 照样被杀;三个测试探针的调用方(reconnect / rejoin / team_match)杀的也是 Godot worker。
#   ⚠ 覆盖上限(照实登记):
#     · 三条名族是**前缀**匹配 ⇒ 一个恰好以 `Godot` 起头的**别的**程序也会被认成自己人
#       (实测合成名 `Godotless` 命中);判定只在"它真的占着该端口"之上做**收窄**,不是白名单兜底。
#     · 把发布版 exe **改名**成不在这三族里的字串后:**同名**的旧实例仍认得出(第 4 条是精确相等),
#       **不同名**时(例:本进程已改名、占着 7777 的旧实例还是老名字,或反过来)清不掉 ——
#       那时双击服务端会打印警告而不是静默杀 ⇒ 有意的取舍,登记在 docs/eng/registered-debt.md §六。


const SYS32 := "C:/Windows/System32"


# 杀掉持有该 UDP 端口的进程(**仅当属主是"我们这一族"**)。
# 找不到属主 / 非 Windows → 静默返回;属主是别人 / 名字读不出来 → 打印一行、**不杀**。
# ★ BUG-10(2026-10-30):本函数是**阻塞**形态(PowerShell 启动 + 查询要几百 ms),只留给「启动前清残留」
#   (那一刻没人等大厅循环);大厅侧关房 / 清扫走 kill_udp_port_async,否则每次关房都冻一次主线程。
static func kill_udp_port(port: int) -> void:
	_kill_udp_port_blocking(port)


# 异步形态:放上后台线程跑同一段 PowerShell(输出照打)。★ 线程由 reap_kill_threads() 在主线程收尸;
#   房间侧的端口归还**不能**依赖"杀完立刻恢复" —— 杀是异步的,归还口径见 lobby_rooms.TEARDOWN_KILL 的延迟。
static var _kill_threads: Array[Thread] = []


static func kill_udp_port_async(port: int) -> void:
	if OS.get_name() != "Windows":
		return
	var t := Thread.new()
	t.start(func() -> void: _kill_udp_port_blocking(port))
	_kill_threads.append(t)


# 主线程收尸(由大厅 tick 调):已结束的线程 join 掉,没结束的留到下一轮。★ 不 join 会泄漏线程句柄。
static func reap_kill_threads() -> void:
	if _kill_threads.is_empty():
		return
	var keep: Array[Thread] = []
	for t in _kill_threads:
		if t.is_alive():
			keep.append(t)
		else:
			t.wait_to_finish()
	_kill_threads = keep


static func _kill_udp_port_blocking(port: int) -> void:
	if OS.get_name() != "Windows":
		return   # PowerShell 串只在 Windows 有意义;别在其它平台白起一个进程
	# ★ 保守护栏(见文件头):`Select -ExpandProperty` 那条修正写法照旧在,只是**不再无条件
	#   Stop-Process**。`$n` 为空(进程已退出/权限不足)时所有比较全为假 ⇒ 走 else ⇒ 不杀。
	# 第 4 条 =「本进程自己的 exe 名」。★ 与 `.bat` 那侧**同口径:精确相等**(不是前缀)——
	# 取向是"证不出是自己人就不杀",所以这条要**最紧**;exe 名里含单引号会**破掉整条 PowerShell
	# 串**(那时连前缀那三条一起失效)⇒ 这种名字直接不加这一条,前缀三条仍在。
	var self_pat := ""
	var self_name: String = OS.get_executable_path().get_file().get_basename()
	if self_name != "" and not self_name.contains("'"):
		self_pat = " -or $n -eq '" + self_name + "'"
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"foreach($id in $p){$n=(Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName; " + \
			"if($n -like 'Godot*' -or $n -like 'Cyancular*' -or $n -like 'The Cyancular*'" + \
			self_pat + "){" + \
			"Stop-Process -Id $id -Force -ErrorAction SilentlyContinue}" + \
			"else{Write-Output ('[ProcUtil] UDP " + str(port) + " held by ' + $n + " + \
			"' -- not ours, not killing it')}}"
	# ★ 必须**捕获输出**:这条 `-not ours` 警告是「证不出是自己人就不杀」取向的唯一可见反馈(见文件头)。
	#   旧写法是 `OS.execute(..., [], false, true)`(不捕获 + 自开控制台)⇒ 警告一闪即逝/根本进不了日志。
	var out: Array = []
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], out, false, false)
	for line in out:
		var s := str(line).strip_edges()
		if not s.is_empty():
			print(s)


# ── 按 UDP 端口查属主 PID(netstat 版;静默、只要 pid)────────────────────────────
# 用途:大厅「本机服务器」按钮的**残留清理**与**就绪轮询**(local_server),以及任何想"先问是谁占着"的调用方。
# ★★ 坑(旧的 local_server._pids_on_port 就是踩的这个):**UDP 行只有 4 列** ——
#   `  UDP    0.0.0.0:7777         *:*      1234`,没有 State 列;TCP 行才是 5 列。
#   按 `cols.size() >= 5` 判 ⇒ 对 UDP 恒假 ⇒ 一个属主都找不到(而 TCP 行又会命中**对端**地址,反向误报)。
#   判据必须是「第 1 列 == `UDP` 且第 2 列(本地地址)端口命中」。
# ★ 返回值可能含**本进程自己**;调用方自己判 `OS.get_process_id()`。
# ★ 只查 UDP:大厅/worker 都是 UDP(ENet),这能同时避开"本机某客户端连着远端 7777"的 TCP 对端假阳性。
static func pids_on_udp_port(port: int) -> Array[int]:
	var pids: Array[int] = []
	if OS.get_name() != "Windows":
		return pids
	var out: Array = []
	OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-ano"]), out, false, false)
	for chunk in out:
		for line in str(chunk).split("\n"):
			var pid := _pid_of_udp_line(line, port)
			if pid > 0 and not pids.has(pid):
				pids.append(pid)
	return pids


# netstat -ano 的一行 → 该行的属主 pid(UDP 且本地端口命中);否则 -1。纯函数(不碰 OS),`-s` 可测。
static func _pid_of_udp_line(line: String, port: int) -> int:
	var cols := line.strip_edges().split(" ", false)
	if cols.size() < 4 or cols[0] != "UDP":
		return -1
	# cols[1] = 本地地址,形如 `0.0.0.0:7777` / `[::]:7777` / `127.0.0.1:7777`
	if not _addr_has_port(cols[1], port):
		return -1
	# UDP 行的最后一列就是 pid(没有 State 列)。TCP 行即使列数够也不进这里(上面已经挡掉)。
	var pid := int(cols[cols.size() - 1])
	return pid if pid > 0 else -1


# 地址串的**端口**是否等于 port。★ 必须按冒号后整段解析,不能 `contains(":7777")`:
# 后者会被 `:17777` / `:77770` 这类前缀串命中;也不能 `contains(":7777 ")`(行尾无空格时会漏)。
static func _addr_has_port(addr: String, port: int) -> bool:
	var at := addr.rfind(":")
	if at < 0 or at + 1 >= addr.length():
		return false
	var tail := addr.substr(at + 1)
	return tail.is_valid_int() and int(tail) == port
