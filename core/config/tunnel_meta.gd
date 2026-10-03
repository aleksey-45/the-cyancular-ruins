class_name TunnelMeta
extends RefCounted

# 远程联机隧道(EasyTier)的**全部常量**,单一来源。
#
# ★ 为什么单独一份而不是塞进 `Tunnel`:这些值**同时**被三处读 —— 隧道编排(`core/net/tunnel.gd`)、
#   客户端大厅页(房间码展示/错误文案)、以及 `tools/fetch_easytier.py`(下载分发,它读同一份
#   版本号拼 URL)。写第二份就一定会漂,而漂的后果是"下载的版本与命令行参数不匹配"这种
#   **不报错**的失效。
#
# ★ 许可:EasyTier 是 **LGPL-3.0**(不是 AGPL)。本仓只以**独立进程**方式调用它的官方 exe
#   (不静态链接、不改它的源码),故不触发 LGPL §4 的"组合作品"条款;分发时随包附上许可全文与
#   出处链接(`LICENSE_NAME` / `LICENSE_URL`),这条是 `ensure_downloaded` 的义务。

# ── 二进制 ──
# ★ 版本号 = **实际测过的那一版**(2026-09-29 用 2.6.4 在本机跑通端到端)。改它之前先用
#   `easytier-core.exe --help` 逐条对一遍下面那串命令行是否仍被接受:
#   --no-tun / -i / -l / -p / --network-name / --network-secret / --hostname /
#   --rpc-portal / --private-mode。(`--udp-whitelist` / `--tcp-whitelist` 原在列,2026-09-30
#   查源码确认对 UDP 数据面无效后连同调用点一起删除,见 `core/net/tunnel.gd` 文件头。)
const ET_VERSION := "2.6.4"
const CORE_EXE := "easytier-core.exe"
const CLI_EXE := "easytier-cli.exe"
# ★★ `Packet.dll` **不是可选项**:`easytier-core.exe` 静态导入它(同时导入 `wintun.dll`,
#   后者只在 TUN 模式下才真正被加载)。少了它的表现是**进程根本起不来** —— Windows 直接返回
#   `0xC0000135`(STATUS_DLL_NOT_FOUND),stdout/stderr **一个字节都没有**,`OS.create_process`
#   只拿到一个立刻退出的 pid。2026-09-29 实测踩到:只把两个 exe 复制过去,`easytier-core --version`
#   零输出。故 `available()` 要连它们一起查、`fetch_easytier.py` 要**整包解压**而不是只挑两个 exe。
const CORE_DLLS := ["Packet.dll", "wintun.dll"]
const LICENSE_NAME := "LGPL-3.0"
const LICENSE_URL := "https://github.com/EasyTier/EasyTier/blob/main/LICENSE"
# 官方 release 资产名(Windows x86_64)。%s 是版本号,出现两次(标签前缀 + 资产名)。
const RELEASE_URL := "https://github.com/EasyTier/EasyTier/releases/download/v%s/easytier-windows-x86_64-v%s.zip"
# 解包后二进制落在 `user://easytier/`;与游戏 exe 同目录也认(优先)。
const USER_DIR := "user://easytier"

# ── 虚拟网络命名契约 ──
# 房间码 → 网络名/密钥 直接拼接(见 Tunnel.room_credentials);
# 主机名是**端口从房主传给客机的通道** —— 客机扫 peer 列表找 HOST_PREFIX 开头的那条,
# 从尾部切出端口。改这两条前缀 = 改协议,两端必须同一个 build。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# ── 虚拟网段 ──
# 房主固定占用 .1(客机用 --dhcp 领号,从 .2 起)。
# ★ 选 10.126.126.0/24 的理由:它不在家用路由器常见网段(192.168.x/10.0.x/172.16-31.x)里,
#   玩家真网卡撞上这个网段的概率极低 —— 撞上时 no-tun 的用户态栈会把内网流量也吸进隧道。
const VIP_CIDR := "10.126.126.0/24"
const VIP_HOST := "10.126.126.1"

# ── 会合节点(中继 / 共享节点)──
# ★★ 2026-09-29 **实测订正**:EasyTier **没有**默认对等节点、**也没有**局域网自动发现
#   (`--help` 里只有 `--enable-udp-broadcast-relay`,那是"把游戏自己的 UDP 广播喂进隧道"、
#   而且要管理员权限,不是节点发现)。不带 `-p`/`-e` 时,`easytier-cli peer` 里**永远只有本机
#   一条** —— 两台机器各起一个 EasyTier、只填同一个房间码的话,**它们永远见不到对方**。
#   故"中继"不是兜底,**是必需的会合点**:两端都填同一个共享节点,由它交换端点,
#   之后数据面**尽量走 P2P 直连**(实测 `peer` 里 `cost: p2p` + `tunnel_proto: udp`,
#   共享节点那条则是 `PublicServer_<hostname>`),打洞失败才退化成经它转发。
#
# 覆盖方式:每行一个端点写进 `user://easytier-relay.txt`(见 RELAY_FILE,**优先级高于下面的内置表**)。
#   接受 `host:port` 或完整 URL(`tcp://host:port`);`#` 开头是注释。
#   ★ 房主与客机**必须用同一份** —— 会合点不同就等于没填。
#   ★ `127.0.0.1` **不能**当对端地址(发出去的 socket 会绑到虚拟网地址,Windows 报
#     `0x2711 WSAEADDRNOTAVAIL`)—— 要填**对端能从物理网络访问到的**地址。
const RELAY_FILE := "user://easytier-relay.txt"

# 内置会合节点(2026-09-29 用户指定)。★ 它**就是** `docs/netplay.md` §6 说的那个初始节点 ——
# 没有它,发布出去的游戏**谁也连不上谁**。
# ★ 为什么两条都给(tcp + udp):同一个节点的两种接入方式,谁先连上算谁。实测两条都能建立
#   连接(udp 那条日志里是 `tunnel_type: "udp"`)。★ 早先"`-p` 只认 tcp"的结论是**错的** ——
#   它来自一次本机对打(对端是同机的另一个实例)的失败,不该推广到公网节点。
# ★ 它**不转发就不花你的钱**这件事不成立:打洞失败时数据要经它转发,那时它的带宽=延迟上限。
const RELAYS: Array[String] = [
	"tcp://dreamlife.indevs.in:11010",
	"udp://dreamlife.indevs.in:11010",
	# 备用会合点(2026-10-01 加):单一第三方社区节点是隐藏的单点依赖;EasyTier 对
	# 多条 -p 全部尝试,谁可达用谁。us01.225284.xyz 实测 tcp/udp 双可达。
	"tcp://us01.225284.xyz:11010",
	"udp://us01.225284.xyz:11010",
]

# ── 本地 RPC 门户端口区间(easytier-core 的管理口,仅 127.0.0.1)──
# 每端随机取一个:同机同时跑房主隧道与客机隧道时(联调)不会撞。
const RPC_PORT_LO := 15888
const RPC_PORT_HI := 15999


static func release_url() -> String:
	return RELEASE_URL % [ET_VERSION, ET_VERSION]
