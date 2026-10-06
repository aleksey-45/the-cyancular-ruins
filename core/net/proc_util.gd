class_name ProcUtil
extends RefCounted

# 进程与端口管理工具（适用于 Windows 环境：基于 PowerShell 与 taskkill）。纯静态实现，不依赖 Autoload。
#
# 设计说明：
#   提供按 UDP 端口查找占用进程并安全终止的功能，主要供自动化测试脚本清理自身启动的服务端实例。
#   注意：获取拥有者进程 PID 需使用 `Select -ExpandProperty OwningProcess`，确保正确解析进程 ID。


# 终止占用指定 UDP 端口的进程（若存在）。未找到进程、无权限或非 Windows 平台时静默返回。
static func kill_udp_port(port: int) -> void:
	if OS.get_name() != "Windows":
		return   # PowerShell 串只在 Windows 有意义;别在其它平台白起一个进程
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)
