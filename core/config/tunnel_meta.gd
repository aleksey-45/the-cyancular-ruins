class_name TunnelMeta
extends RefCounted

# EasyTier 免驱动应用层虚拟网隧道全局常量定义。
# 为 Tunnel 隧道管理、联机大厅与下载工具提供统一数据源。
#
# 许可说明：EasyTier 采用 LGPL-3.0 协议。本项目仅以独立子进程方式调用其预编译可执行文件，
# 随发布包附带许可文件与官方源码链接。

# ── 核心可执行文件与动态库 ──
# 必须包含 easytier-core.exe、easytier-cli.exe 以及运行时依赖库 Packet.dll 与 wintun.dll。
const ET_VERSION := "2.6.4"
const CORE_EXE := "easytier-core.exe"
const CLI_EXE := "easytier-cli.exe"
const CORE_DLLS := ["Packet.dll", "wintun.dll"]
const LICENSE_NAME := "LGPL-3.0"
const LICENSE_URL := "https://github.com/EasyTier/EasyTier/blob/main/LICENSE"
const RELEASE_URL := "https://github.com/EasyTier/EasyTier/releases/download/v%s/easytier-windows-x86_64-v%s.zip"

# ── 虚拟网络命名规范 ──
# 房间码直接映射为网络名与接入密钥；主机名携带端口信息供加入方解析。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# ── 虚拟网络网段 ──
# 房主固定分配 10.126.126.1，加入方通过 DHCP 动态分配。
const VIP_CIDR := "10.126.126.0/24"
const VIP_HOST := "10.126.126.1"

# ── 初始中继与打洞辅助节点 ──
# 节点地址从游戏目录下的 relay.txt 文件读取，每行一个节点（支持 host:port 或 tcp:// / udp:// 格式）。
# 双方连接相同的中继节点以交换端点并发起 P2P 直连打洞，打洞受限时由中继节点转发。
const RELAY_FILE_NAME := "relay.txt"

# ── 本地 RPC 管理端口 ──
# 管理端口由操作系统在运行时动态分配空闲端口，避免与系统其他进程发生端口冲突。

# ── 内核日志配置 ──
# 日志存储于游戏目录下的 log/ 目录，目录名为 "easytier-<role>-<pid>"。
# 附加 PID 后缀可区分同机多开实例，并在下次启动时清理意外残留的历史孤儿进程。
const ET_LOG_DIR_PREFIX := "easytier-"
const ROLE_HOST := "host"
const ROLE_GUEST := "guest"

## 孤儿日志清理保留的历史目录上限（仅清理对应进程已退出的目录，按修改时间保留最新目录）。
const ET_LOG_KEEP := 25


## 生成指定角色的内核日志目录名（包含当前游戏进程 PID）。
static func et_log_dir_name(role: String) -> String:
	return "%s%s-%d" % [ET_LOG_DIR_PREFIX, role, OS.get_process_id()]


## 从日志目录名解析其归属的游戏进程 PID；返回 0 表示非标准目录（跳过清理）。
static func et_log_dir_owner(dir_name: String) -> int:
	if not dir_name.begins_with(ET_LOG_DIR_PREFIX):
		return 0
	var rest := dir_name.substr(ET_LOG_DIR_PREFIX.length())
	for role in [ROLE_HOST, ROLE_GUEST]:
		if rest.begins_with(role + "-"):
			var tail := rest.substr(role.length() + 1)
			return int(tail) if tail.is_valid_int() and int(tail) > 0 else 0
	return 0


static func release_url() -> String:
	return RELEASE_URL % [ET_VERSION, ET_VERSION]
