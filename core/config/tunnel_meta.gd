class_name TunnelMeta
extends RefCounted

# EasyTier 免驱动应用层虚拟网隧道全局常量定义。
# 为 Tunnel 隧道管理、联机大厅与下载工具提供统一数据源。
#
# 许可说明：EasyTier 采用 LGPL-3.0 协议。本项目仅以独立子进程方式调用其预编译可执行文件，
# 许可正文、版权声明和官方源码链接收录于发布包根部的 THIRD_PARTY_NOTICES.txt。

# ── 核心可执行文件与动态库 ──
# Windows 组件包含 EXE 和依赖库，macOS 组件使用无后缀通用可执行文件。
const ET_VERSION := "2.7.0"
const CORE_EXE := "easytier-core.exe"
const CLI_EXE := "easytier-cli.exe"
const CORE_DLLS := ["Packet.dll", "wintun.dll"]
const LICENSE_NAME := "LGPL-3.0"
const LICENSE_URL := "https://github.com/EasyTier/EasyTier/blob/main/LICENSE"
const OFFICIAL_DIR := "easytier-windows-x86_64"

# ── 虚拟网络命名规范 ──
# 房间码直接映射为网络名与接入密钥；主机名携带端口信息供加入方解析。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# ── 虚拟网络网段 ──
# 房主固定分配 10.126.126.1，加入方通过 DHCP 动态分配。
const VIP_CIDR := "10.126.126.0/24"
const VIP_HOST := "10.126.126.1"

# ── 初始中继与 NAT 穿透辅助节点 ──
# relay.txt 每行一个节点，支持 host:port 或 tcp:// / udp:// 格式。
# 双方连接相同的中继节点以交换端点并尝试 P2P 直连，直连受限时由中继节点转发。
const RELAY_FILE_NAME := "relay.txt"

const DEFAULT_RELAYS := [
	"udp://et.basd1.de:11010",
	"udp://183.230.36.171:11010",
	"udp://et.sumnight.online:11012",
	"udp://net.vpspersonxu.xyz:11010",
	"udp://et1.fuis.top:11010",
	"udp://boi.de5.net:11010",
	"udp://47.92.208.217:11010",
	"udp://et.dnjjs.com:11010",
	"udp://us01.225284.xyz:11010",
	"udp://dreamlife.indevs.in:11010",
]

static func core_name() -> String:
	return "easytier-core" if OS.has_feature("macos") else CORE_EXE

static func cli_name() -> String:
	return "easytier-cli" if OS.has_feature("macos") else CLI_EXE

static func required_files() -> PackedStringArray:
	var files := PackedStringArray([core_name(), cli_name()])
	if OS.has_feature("windows"):
		files.append_array(CORE_DLLS)
	return files
