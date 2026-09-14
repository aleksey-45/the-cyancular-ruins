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
#   守卫:`tests/kh_l5_probe.gd` 第 3 条(判据取**去注释视图** —— 解释这个坏写法的注释本身
#   含该串,算进去会让断言永远红)。


# 杀掉持有该 UDP 端口的进程(若有)。找不到属主 / 无权限 / 非 Windows → 静默返回
# (`-ErrorAction SilentlyContinue` + 入口处的 OS 检查,与"杀不掉也别炸"的调用方预期一致)。
static func kill_udp_port(port: int) -> void:
	if OS.get_name() != "Windows":
		return   # PowerShell 串只在 Windows 有意义;别在其它平台白起一个进程
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)
