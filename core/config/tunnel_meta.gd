class_name TunnelMeta
extends RefCounted

# EasyTier 免驱动应用层虚拟网隧道全局常量定义。
# 为 Tunnel 隧道管理、联机大厅与下载工具提供统一数据源。
#
# 许可说明：EasyTier 采用 LGPL-3.0 协议。本项目仅以独立子进程方式调用其预编译可执行文件，
# 许可正文、版权声明和官方源码链接收录于发布包根部的 THIRD_PARTY_NOTICES.txt。

# Windows 组件包含 EXE 和依赖库，macOS 组件使用无后缀通用可执行文件。
const ET_RELEASE := "nightly"
const CORE_EXE := "easytier-core.exe"
const CLI_EXE := "easytier-cli.exe"
const CORE_DLLS := ["Packet.dll", "wintun.dll"]
const LICENSE_NAME := "LGPL-3.0"
const LICENSE_URL := "https://github.com/EasyTier/EasyTier/blob/main/LICENSE"

# 房间码直接映射为网络名与接入密钥；主机名携带端口信息供加入方解析。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# 房主固定分配 10.126.126.1，加入方通过 DHCP 动态分配。
const VIP_CIDR := "10.126.126.0/24"
const VIP_HOST := "10.126.126.1"

# relay.txt 每行一个节点，支持 txt://、udp://、tcp:// 或无协议的 host:port。
# 双方连接相同的中继节点以交换端点并尝试 P2P 直连，直连受限时由中继节点转发。
const RELAY_FILE_NAME := "relay.txt"

const DEFAULT_RELAYS := [
	"txt://et2.lctn.cc.cd",
	"udp://183.230.36.171:11010",
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
