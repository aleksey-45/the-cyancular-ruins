class_name TunnelMeta
extends RefCounted

# 大厅与对局使用相同的 EasyTier 设置。虚拟网络负责转发对局的 UDP 数据。
# EasyTier 由游戏作为子进程启动。随附的版权、许可证和源码出处记录在 THIRD_PARTY_NOTICES.txt 中。

static var files: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/easytier.json"))[
	"macos" if OS.has_feature("macos") else "windows"]

# 房间号加上前缀构成虚拟网络名称。房间号也充当网络密钥，房主则把游戏端口写到自己的节点名中。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# 虚拟网络为房主保留固定地址。加入方通过 DHCP 获得自己的地址。
const VIP_HOST := "10.126.126.1"

# 初始节点地址按行保存在 relay.txt 中，支持 txt://、udp://、tcp:// 和 host:port。
# 客户端经初始节点交换地址。能建立点对点连接时直接通信，否则通过中继传输数据。
const RELAY_FILE_NAME := "relay.txt"

const DEFAULT_RELAYS: Array[String] = [
	"txt://et2.lctn.cc.cd",
	"udp://183.230.36.171:11010",
]

static func required_files() -> PackedStringArray:
	return PackedStringArray([files.core, files.cli] + files.libraries)
