class_name TunnelMeta
extends RefCounted

# EasyTier 免驱动应用层虚拟网隧道全局常量定义。
# 为 Tunnel 隧道管理、联机大厅与下载工具提供统一数据源。
#
# 许可说明：EasyTier 采用 LGPL-3.0 协议。本项目仅以独立子进程方式调用其预编译可执行文件，
# 许可正文、版权声明和官方源码链接收录于发布包根部的 THIRD_PARTY_NOTICES.txt。

# ── 核心可执行文件与动态库 ──
# 必须包含 easytier-core.exe、easytier-cli.exe 以及运行时依赖库 Packet.dll 与 wintun.dll。
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

# ── 初始中继与打洞辅助节点 ──
# 节点地址从游戏目录下的 relay.txt 文件读取，每行一个节点（支持 host:port 或 tcp:// / udp:// 格式）。
# 双方连接相同的中继节点以交换端点并发起 P2P 直连打洞，打洞受限时由中继节点转发。
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
