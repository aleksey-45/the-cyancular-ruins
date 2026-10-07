class_name TunnelMeta
extends RefCounted

# 远程联机隧道(EasyTier)的**全部常量**,单一来源。
#
# - 为什么单独一份而不是塞进 `Tunnel`:这些值**同时**被三处读 —— 隧道编排(`core/net/tunnel.gd`)、
#   客户端大厅页(房间码展示/错误文案)、以及 `tools/fetch_easytier.py`(下载分发,它读同一份
#   版本号拼 URL)。写第二份就一定会漂,而漂的后果是"下载的版本与命令行参数不匹配"这种
#   **不报错**的失效。
#
# - 许可:EasyTier 是 **LGPL-3.0**(不是 AGPL)。本仓只以**独立进程**方式调用它的官方 exe
#   (不静态链接、不改它的源码),故不触发 LGPL §4 的"组合作品"条款;分发时随包附上许可全文与
#   出处链接(`LICENSE_NAME` / `LICENSE_URL`),这条是 `ensure_downloaded` 的义务。

# ── 二进制 ──
# - 版本号 = **实际测过的那一版**(2026-09-29 用 2.6.4 在本机跑通端到端)。改它之前先用
#   `easytier-core.exe --help` 逐条对一遍下面那串命令行是否仍被接受:
#   --no-tun / -i / -l / -p / --network-name / --network-secret / --hostname /
#   --rpc-portal / --private-mode。(`--udp-whitelist` / `--tcp-whitelist` 原在列,2026-09-30
#   查源码确认对 UDP 数据面无效后连同调用点一起删除,见 `core/net/tunnel.gd` 文件头。)
# 二进制住在**游戏目录的 `easytier/` 子目录**里(路径由 AppPaths 给:发布版=exe 同级的
# `easytier/`,开发态=仓库根的 `easytier/`);`tools/fetch_easytier.py` 也下到那里。
const ET_VERSION := "2.6.4"
const CORE_EXE := "easytier-core.exe"
const CLI_EXE := "easytier-cli.exe"
# 注意： `Packet.dll` **不是可选项**:`easytier-core.exe` 静态导入它(同时导入 `wintun.dll`,
#   后者只在 TUN 模式下才真正被加载)。少了它的表现是**进程根本起不来** —— Windows 直接返回
#   `0xC0000135`(STATUS_DLL_NOT_FOUND),stdout/stderr **一个字节都没有**,`OS.create_process`
#   只拿到一个立刻退出的 pid。2026-09-29 实测踩到:只把两个 exe 复制过去,`easytier-core --version`
#   零输出。故 `available()` 要连它们一起查、`fetch_easytier.py` 要**整包解压**而不是只挑两个 exe。
const CORE_DLLS := ["Packet.dll", "wintun.dll"]
const LICENSE_NAME := "LGPL-3.0"
const LICENSE_URL := "https://github.com/EasyTier/EasyTier/blob/main/LICENSE"
# 官方 release 资产名(Windows x86_64)。%s 是版本号,出现两次(标签前缀 + 资产名)。
const RELEASE_URL := "https://github.com/EasyTier/EasyTier/releases/download/v%s/easytier-windows-x86_64-v%s.zip"

# ── 虚拟网络命名契约 ──
# 房间码 → 网络名/密钥 直接拼接(见 Tunnel.room_credentials);
# 主机名是**端口从房主传给客机的通道** —— 客机扫 peer 列表找 HOST_PREFIX 开头的那条,
# 从尾部切出端口。改这两条前缀 = 改协议,两端必须同一个 build。
const NET_PREFIX := "cyr-"
const HOST_PREFIX := "cyr-host-"
const GUEST_PREFIX := "cyr-guest-"

# ── 虚拟网段 ──
# 房主固定占用 .1(客机用 --dhcp 领号,从 .2 起)。
# - 选 10.126.126.0/24 的理由:它不在家用路由器常见网段(192.168.x/10.0.x/172.16-31.x)里,
#   玩家真网卡撞上这个网段的概率极低 —— 撞上时 no-tun 的用户态栈会把内网流量也吸进隧道。
const VIP_CIDR := "10.126.126.0/24"
const VIP_HOST := "10.126.126.1"

# ── 初始节点(relay / shared node)──
# 注意： 2026-09-29 **实测订正**:EasyTier **没有**默认对等节点、**也没有**局域网自动发现
#   (`--help` 里只有 `--enable-udp-broadcast-relay`,那是"把游戏自己的 UDP 广播传入隧道"、
#   而且要管理员权限,不是节点发现)。不带 `-p`/`-e` 时,`easytier-cli peer` 里**永远只有本机
#   一条** —— 两台机器各起一个 EasyTier、只填同一个房间码的话,**它们永远见不到对方**。
#   故"中继"不是保底处理,**是必需的初始节点**:两端都填同一个共享节点,由它交换端点,
#   之后数据面**尽量走 P2P 直连**(实测 `peer` 里 `cost: p2p` + `tunnel_proto: udp`,
#   共享节点那条则是 `PublicServer_<hostname>`),打洞失败才退化成经它转发。
#
# 覆盖方式:`easytier/relay.txt`(游戏目录下,绝对路径见 `Tunnel.relay_file()`),每行一个
#   端点,`#` 开头是注释。接受 `host:port` 或完整 URL(`tcp://host:port`)。
#   注意： **节点只来自这个文件,代码里没有内置表**(2026-10-02 设计约定删除原 `RELAYS` 常量:
#     初始节点是部署事实,不进代码)。文件缺失时游戏只生成一份**纯注释模板**
#     (`Tunnel.ensure_relay_file`,里面一个节点都没有) ->  `has_initial_peers()` 为假,
#     大厅页会把"别人进不来/找不到房主"说明白。
#   - 发布包**随包分发**这份文件(`tools/archive_build.py` 复制)—— 删内置表之后它是玩家
#     开箱即联机的唯一节点来源,打包时缺了要明确提示,不静默。
#   - 同一个节点的 tcp/udp 两种地址都可以各写一行(优先采用最先建立成功的连接；实测两种协议均可正常握手,
#     udp 那条日志里是 `tunnel_type: "udp"`)。-  早先"`-p` 只认 tcp"的结论是**错的** ——
#     它来自一次同机双开联机测试(对端是同机的另一个实例)的失败,不该推广到公网节点。
#   - 房主与客机**必须用同一份** —— 初始节点不同就等于没填。
#   - `127.0.0.1` **不能**当对端地址(发出去的 socket 会绑到虚拟网地址,Windows 报
#     `0x2711 WSAEADDRNOTAVAIL`)—— 要填**对端能从物理网络访问到的**地址。
#   - 节点**不转发就不花钱**这件事不成立:打洞失败时数据要经它转发,那时它的带宽=延迟上限。
const RELAY_FILE_NAME := "relay.txt"

# ── 本地 RPC 门户端口(easytier-core 的管理口,仅 127.0.0.1)──
# - 不再是常量区间(2026-10-04 架构优化):端口由 `Tunnel._pick_rpc_port` 使用 TCP socket 向操作系统
#   动态分配(bind 127.0.0.1:0 → 读回分配端口 → 释放),以具体端口号传给内核。旧的 15888~15999 随机选取会与
#   EasyTier 默认门户的自动取号池(15888..15900)重叠,端口冲突会导致内核立即异常退出(2026-10-04 经
#   源码验证)——保留此注释避免未来重新引入硬编码区间。

# ── 内核自身日志 ──
# 保存在**游戏目录的 `log/`** 下,目录名 = 前缀 + 本端角色 + **启动它的游戏进程 pid**
# (`easytier-host-48152`)。pid 后缀具有双重作用:
#   - 进程所有权标记 —— 游戏异常崩溃或强制终止时 `Tunnel.stop()` 无法执行,后台内核可能残留;
#     残留清理机制(`Tunnel._reap_orphans`)在下次启动隧道时,通过内核命令行中的日志目录识别来源,
#     若目录名尾部的父进程 pid 已退出则终止该残留内核。同机多实例运行时由于父进程存活不会误终止。
#   - 同机多实例互不干扰 —— 每个会话独立子目录,避免 `easytier.log` 产生写冲突。
# - 为什么按角色分目录而不是都倒进 `log/`:内核的日志文件名是固定的 `easytier.log`,而
#   `--file-log-dir` 只能指定目录 —— 同一台机器上跑着房主与客机两条隧道时(开发与测试环境常见),
#   两个进程会去写同一个文件、互相截断(2026-10-02 实测:两条内核同时写一个目录,文件恒为 0 字节)。
const ET_LOG_DIR_PREFIX := "easytier-"
const ROLE_HOST := "host"
const ROLE_GUEST := "guest"

## 残留清理机制对历史日志目录的**保留份数上限**(仅 owner 进程已退出的目录参与清理,按修改时间保留最新文件)。
## 保留日志便于排查崩溃现场问题(2026-10-04 确定保留 25 份)。
const ET_LOG_KEEP := 25


## 某角色的内核日志目录名(尾部带本游戏 pid,见上)。
static func et_log_dir_name(role: String) -> String:
	return "%s%s-%d" % [ET_LOG_DIR_PREFIX, role, OS.get_process_id()]


## 目录名 → 启动它的游戏进程 pid;0 = 不是本游戏建的目录(玩家手动的、旧格式的都算,不碰)。
## - 与 `et_log_dir_name` 是一对:改命名必须两边同改。
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
