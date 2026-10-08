class_name ProcUtil
extends RefCounted

# 进程与端口底层系统工具（适用于 Windows 环境）。
# 纯静态实现，不依赖全局单例。


# 终止占用指定 UDP 端口的进程。
# 若未找到对应属主、缺乏权限或非 Windows 平台，则静默忽略。
static func kill_udp_port(port: int) -> void:
	if OS.get_name() != "Windows":
		return
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)

