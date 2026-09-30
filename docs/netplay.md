# 远程联机(no-tun 隧道)

## 1. 总览

```
房主                                          客户端
──────────────────────────────────────────    ──────────────────────────────────
Cyancular Ruins.exe                           Cyancular Ruins.exe
  ├ 随机选一个端口 P                             ├ 输入房间号(5 位)
  ├ 启动 Server.exe -- --port P                  ├ 启动 EasyTier(--no-tun --dhcp)
  ├ 检测 127.0.0.1:P 能否连接                     ├ 读 peer 列表,取出房主的端口 P
  ├ 建房,得到房间号                              ├ 端口转发 127.0.0.1:Q → 房主IP:P
  ├ 启动 EasyTier --no-tun -i 10.126.126.1       └ 连接 127.0.0.1:Q,加入房间
  │   --hostname cyr-host-P                      ↓
  └ 连接 127.0.0.1:P                        EasyTier 用户态 NAT 代理(房主侧,无需参数)
                                              房主IP:P → 房主 127.0.0.1:P
Server.exe -- --port P                        每个来源一条 NAT 记录,每条记录一个本机 socket
  ├ start_server(P)
  └ RoomManager(大厅)+ MatchSession(对局,同进程)
```

一个进程、一个端口、一个 5 位房间号。客户端从进入大厅到对局结束,全程连接同一台服务端。

### 1.1 目录布局

发布目录如下(开发态同一个布局,只是根换成仓库根):

```
The Cyancular Ruins.exe         客户端
Cyancular Ruins Server.exe      服务端;客户端点「建房」时拉起同目录的它
easytier/                       EasyTier,见 §4
  easytier-core.exe             隧道本体
  easytier-cli.exe              查询 peer、下发转发规则
  Packet.dll                    core 静态依赖,缺了它进程根本起不来
  wintun.dll
  relay.txt                     公共节点列表,见 §6(随发布包分发;玩家可自行编辑)
log/                            运行期才有
  client.log                    客户端
  server.log                    服务端
  client.old.log                上一轮的客户端日志(单份超过 2 MB 时轮转一份)
  server.old.log
  easytier-host-<pid>/easytier.log    房主侧内核(pid = 拉起它的游戏进程)
  easytier-guest-<pid>/easytier.log   客机侧内核
```

两份游戏日志由 `core/config/game_log.gd`(autoload `GameLog`)写。它用 `OS.add_logger()` 接住
引擎的全部输出(print、警告、报错、脚本错误),按角色写进 `log/`。引擎自带的文件日志在
`project.godot` 里被关掉(`debug/file_logging/enable_file_logging` 与它的 `.pc` 覆盖都是 false):
那个落点只认 `%APPDATA%` 下的 `user://`,而且客户端与服务端会同名互相覆盖。游戏目录写不进去时
(例如装在 Program Files 下)`GameLog` 退回 `user://logs/<角色>.log`,并把落点打进日志。

内核日志按角色分目录,因为内核的日志文件名固定是 `easytier.log`、`--file-log-dir` 只能给目录 ——
同一台机器上同时跑房主与客机两条隧道时,两个进程会去写同一个文件、互相截断。目录名尾部再带
拉起者的游戏进程 pid:同机多局各写各的,孤儿清扫也据此认领所有权(见 §4.4)。内核是攒一批才落盘
(实测约 8 秒一次),刚开始就退出的会话可能只留下一个空文件。

---

## 2. 进程与端口

### 2.1 服务端

单进程。大厅(`RoomManager` + `LobbyRooms`)与对局(`MatchSession`)在同一个进程里,配对完成后
`add_child(MatchSession)`,端口不变。

命令行参数(**必须写在 `--` 之后**,`server_main.gd` 读 `OS.get_cmdline_user_args()`):

| 参数 | 作用 |
|---|---|
| `--port <端口号>` | 监听端口,省略时用 `NetBus.DEFAULT_PORT`(7777) |
| `--tunnel --room <5 位房间号>` | 自检:启动一条房主隧道,打印「隧道就绪」后退出(打包冒烟用) |
| `--test-ground-teleport` | 仅测试用 |
| `--test-destroy-tile <列,行[,秒]>` | 仅测试用 |

参战角色集合与队伍表由房间记录直接交给 `MatchSession`。

`core/net/local_server.gd` 的 `launch_and_connect()`:

```gdscript
const PORT_LO := 20000
const PORT_HI := 59999
const PICK_TRIES := 8
const PROBE_TIMEOUT := 10.0

for i in range(PICK_TRIES):
    var port := randi_range(PORT_LO, PORT_HI)
    var pid := OS.create_process(exe, PackedStringArray(["--", "--port", str(port)]))
    if pid <= 0:
        continue
    # 通过 NetBus.start_client("127.0.0.1", port) 与 can_send_to_server() 轮询检测连接
    # 连接成功就返回这个端口;服务端进程立即退出则换一个端口重试
return -1
```

- **端口范围 `20000–59999`**。选到已被占用的端口时由重试处理:服务端绑定失败会立即退出,
  检测在 1 秒内发现,换一个端口重来即可。
- 检测成功时**连接保持建立**,调用方直接当作"已连接大厅"。
- 服务端端口冲突会明确报错(`ERROR: Couldn't create an ENet host.` + `服务器: 监听失败 20`)。

### 2.2 进对局

`go_match` 只表示"切换到对局场景";客户端在同一条连接上发送 `claim_role`,端口写入
`PvpSession.server_port`,供局内断线重连使用。

连接参数只有 `PvpSession` 一个来源。写入它的有两处:`LocalServer.launch_and_connect()`(本机启动服务端)
与 `Tunnel.start_client()`(隧道)。

---

## 3. 房间号

5 位数字,`%05d`,范围 `00000–99999`;用 `randi_range(0, 99999)` 取随机数。派生方式是直接拼接:

```
network-name   = "cyr-" + 房间号      例:cyr-48213
network-secret = 房间号               例:48213
```

`Tunnel.is_valid_room()` 要求"恰好 5 位十进制数字",`00000` 合法。
大厅的房间号由 `LobbyRooms._generate_code()` 生成,它调用 `Tunnel.generate_room()`。

### 3.1 房间号即隧道网络名

网络名由房间号算出,所以一个房间号对应一张隧道网络、一台机器。三层的对应关系:

| 层 | 关系 | 依据 |
|---|---|---|
| 隧道网络 | 1 个房间号 : 1 张网络 | `network-name = "cyr-<房间号>"` |
| 服务器 | 1 台 : 1 个端口 : N 个房间 | `rooms` / `royale_rooms` / `team_rooms` 都是字典 |
| 客户端连接 | 1 条 : 1 台服务器 | `NetBus.start_client(addr, port)` |

以此判断的两处:

- **建网条件** `not Tunnel.on_network(code)`:本端不在这个房间号的网络上时重新建隧道;房主更换
  房间号后,隧道随之更换网络名(`Tunnel._code` 记录本端所在的网络)。
- **加入条件** `Tunnel.on_network(code) and NetBus.can_send_to_server()`:房间号是本端所在的网络,
  直接使用当前连接;否则先清理旧连接、旧隧道与本机服务端,再按新房间号建隧道并连接。

同一张网络内不重连:服务端的房间记录里存的是 peer id(`room.players`)。

### 3.2 建房 = 全新的服务端 + 全新的隧道 + 全新的房间

`LobbyPage._ensure_own_server()` 无条件依次执行:停止当前连接 → 停止隧道 → 停止本机服务端 →
选择端口、启动服务端、连接(`LocalServer.launch_and_connect()`)。三页的建房都走这一个前置。

---

## 4. EasyTier 隧道

### 4.1 文件从哪来

四个文件放在**游戏目录的 `easytier/` 子目录**里(见 §1.1):`easytier-core.exe` / `easytier-cli.exe` /
`Packet.dll` / `wintun.dll`。`tools/fetch_easytier.py` 在构建阶段下载并完整解压到那里。

★ **必须四个文件一起放**:`easytier-core.exe` 静态依赖 `Packet.dll`,缺少它的表现是进程无法启动
(Windows 返回 `0xC0000135`,stdout/stderr 没有任何输出,`OS.create_process` 只得到一个立即退出的
pid)。`available()` 因此把这两个 dll 也算进"文件是否齐全"。路径由 `AppPaths.easytier_dir()` 给出
(发布态 = exe 目录下的 `easytier/`,开发态 = 仓库根下的 `easytier/`)。

### 4.2 房主

```
easytier-core.exe --no-tun
  -i 10.126.126.1
  --network-name cyr-<房间号>
  --network-secret <房间号>
  --hostname cyr-host-<端口号>
  --rpc-portal 127.0.0.1:<rpc>
  --private-mode true
  -l udp://0.0.0.0:0
  -l tcp://0.0.0.0:0
  -p tcp://<初始节点>
  -p udp://<初始节点>
```

### 4.3 客户端

```
easytier-core.exe --no-tun --dhcp
  --network-name cyr-<房间号>
  --network-secret <房间号>
  --hostname cyr-guest-<8 位随机值>
  --rpc-portal 127.0.0.1:<rpc>
  --private-mode true
  -l udp://0.0.0.0:0
  -l tcp://0.0.0.0:0
  -p tcp://<初始节点>
  -p udp://<初始节点>
```

启动顺序:

1. 启动 EasyTier,轮询 `easytier-cli --rpc-portal 127.0.0.1:<rpc> -o json peer`,直到出现主机名以
   `cyr-host-` 开头的那一条(约 3~10 秒,上限 60 秒),从中取出房主的虚拟 IP 与端口 P。
2. 下发转发规则:`easytier-cli ... port-forward add udp 127.0.0.1:Q <房主IP>:P`
   (`Q` 是本机挑的空闲端口,与房主的 `P` 无关)。
3. 连接 `127.0.0.1:Q`,发送加入请求。

### 4.4 孤儿清理(异常退出)

`easytier-core` 是独立进程:游戏崩溃或被强杀时 `stop()` 没机会执行,内核残留成孤儿 —— 继续占着
RPC 门户与虚拟网地址,房主侧还会把一间死房间挂在共享节点上(旧码进得去网、连不上服)。Windows
不回收孤儿,游戏也不上 Job Object,兜底是**下次起隧道时的认领清理**(`Tunnel._reap_orphans`,
建房/加入前各跑一次、每游戏进程一次):

- **认领判据**:内核命令行里带本游戏的日志根路径(`--file-log-dir`),且其日志目录名尾部的
  游戏 pid 已死 → 是本游戏拉起的孤儿 → 终结。owner 还活着的不碰(同机双开互连是另一局);
  玩家手动跑的内核、easytier-gui 的子进程不含这条路径,永不误伤。
- **旧日志截断**:owner 已死的日志目录按 mtime 留新删旧,保底最近 25 份
  (`TunnelMeta.ET_LOG_KEEP`)= 崩溃现场永远留着最近这些,又不无限堆积。
- 枚举内核用 PowerShell `Get-CimInstance Win32_Process`(要命令行,tasklist 只有名字)。

---

## 5. hostname 约定

房间号只决定网络名与密钥,不含端口。端口通过 **hostname** 传递:房主把自己的端口号拼进主机名
(`cyr-host-<端口号>`,见 `TunnelMeta.HOST_PREFIX`),客户端在 peer 列表里找到这一条,从末尾取出
端口号。

修改前缀等于修改协议,两端必须是同一个 build。`Tunnel.host_port_of()` / `pick_host_peer()` /
`parse_peers_json()` 是纯函数,由 `tests/netplay_probe.gd` 逐个覆盖。

---

## 6. 初始节点

两端都要配置初始节点:由 `-p` 指定,peer 列表里才能看到对方。
两端都必须配置初始节点,且**填同一份**。

节点**只**来自 `easytier/relay.txt`(游戏目录下,见 §1.1)—— 2026-10-02 起**代码里没有内置
节点表**(原 `TunnelMeta.RELAYS` 已删:初始节点是部署事实,不进代码)。发布包随包分发这份文件
(`tools/archive_build.py` 复制);文件缺失时游戏只生成一份**纯注释模板**(`Tunnel.ensure_relay_file`),
往里填地址即可。每行一个地址,`#` 开头是注释,`host:port` 或完整 URL 都可以
(`Tunnel.relay_list()` 只认这一个文件),改完重进房间生效。

没有节点的后果(两端不同):房主建房能开,但**没人进得来**(建房反馈会点名,见
`Tunnel.no_relay_hint()`);客机点加入会被 `LobbyPage._join_with_code` 的
`has_initial_peers` 闸拦下,提示先写节点。

两条约束:`127.0.0.1` 不能作为对端地址(发出的 socket 会绑定到虚拟网络地址,Windows 报
`0x2711 WSAEADDRNOTAVAIL`);`tcp://` 与 `udp://` 两种地址都可以用。

自建共享节点(任意一台有公网地址的服务器):

```
easytier-core.exe --no-tun --network-name relay-net --network-secret relay-secret ^
  --hostname cyr-relay -l tcp://0.0.0.0:11010 -l udp://0.0.0.0:11010
```

---

## 7. 文件职责

| 文件 | 内容 |
|---|---|
| `core/config/app_paths.gd` | 游戏目录与 `easytier/`、`log/` 两个子目录(路径的唯一来源) |
| `core/config/game_log.gd` | 日志落盘(autoload `GameLog`):客户端 `client.log`、服务端 `server.log`,含轮转与退路 |
| `core/net/tunnel.gd` | 房间号生成/校验/解析;EasyTier 进程与命令行参数;就绪检测;下发转发规则;解析 CLI 输出;公共节点列表;孤儿清理(异常退出兜底,§4.4) |
| `core/config/tunnel_meta.gd` | 版本号 / 可执行文件名 / 必需的两个 dll / 下载地址 / 许可证 / 主机名前缀 / 虚拟网段 / 公共节点列表文件名 / 内核日志目录命名(前缀+角色+游戏 pid)与保留份数 |
| `core/net/local_server.gd` | `launch_and_connect()`(选择端口 → 启动服务端 → 检测连接)/ `stop_owned()` |
| `core/net/pvp_session.gd` | 连接参数(`server_address` / `server_port` / `room_code`)与回局凭据 |
| `core/net/net_bus.gd` | `@rpc` 统一入口;`_exit_tree` 关闭本机服务端与隧道 |
| `server/match_session.gd` | 一局的编排(名册 / claims / 宽限期 / 开局 / `match_sync`) |
| `server/lobby_rooms.gd` | 三种模式的房间表与建房、加入、退出 |
| `scenes/lobby_page.gd` | 三个页面共用的建房与加入流程(`_ensure_own_server()` / `_join_with_code()`)、房间号显示 |
| `tools/fetch_easytier.py` | 构建阶段下载并完整解压到 `easytier/` |
| `tests/netplay_probe.gd` | 房间号 / peer 解析 / 目录布局 / 源码级契约 |
| `tests/reap_orphans_smoke.gd` | 孤儿清理实弹:真内核假孤儿被终结、目录按份数截断(手动,自清) |
| `tests/kh_migration_e2e_probe.tscn` | 真实进程端到端:启动服务端 → 建房 → 启动真实隧道 → 清理 |
| `tests/script_load_probe.tscn` | 用场景模式逐个加载全部 .gd 文件 |

---

## 8. 验证

### 8.1 自动化

```bash
"$GODOT" --headless --path . -s res://tests/netplay_probe.gd            # 房间号 / peer 解析 / 源码级契约
"$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd        # 房间生命周期与拆除
"$GODOT" --headless --path . -s res://tests/rejoin_registry_smoke.gd
"$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd
"$GODOT" --headless --path . -s res://tests/reap_orphans_smoke.gd      # 孤儿清理实弹(拉真进程,手动)
```

`netplay_probe` 的判断项(10 万次抽样):`generate_room()` 恒为 5 位数字、每个结果都能通过
`is_valid_room`(往返一致)、首位数字分布均匀、不同房间号的网络名互不相同;以及 `host_port_of` /
`pick_host_peer` / `parse_peers_json` 的边界与异常输入。

### 8.2 手工验证隧道

一个共享节点 + 一个房主 + 一个客户端,三个 easytier-core 进程都在 127.0.0.1 上,用真实网卡 IP
作为对端地址。真实两机部署时把 `<本机对外 IP>` 换成各自那台的地址。
★ 下面示例里的 `--rpc-portal` 端口**只属于手工排查**,刻意避开 15888~15900(EasyTier 自家
  默认门户的自动取号池);游戏自己起内核时根本不传固定口——用 TCP socket 向 OS 要号
  (`Tunnel._pick_rpc_port`,2026-10-04 起),这里给固定口只是为了本窗口能对得上 `easytier-cli`。

```powershell
# ① 共享节点(用自己的网络名;两端都指向它,用于互相发现)
easytier-core.exe --no-tun --network-name relay-net --network-secret relay-secret `
  --hostname cyr-relay -l tcp://0.0.0.0:11010 -l udp://0.0.0.0:11010

# ② 房主(另开一个窗口);再另开一个窗口运行:Cyancular Ruins Server.exe -- --port 7777
easytier-core.exe --no-tun -i 10.126.126.1 `
  --network-name cyr-48213 --network-secret 48213 `
  --hostname cyr-host-7777 `
  --rpc-portal 127.0.0.1:16001 -p tcp://<本机对外 IP>:11010

# ③ 客户端
easytier-core.exe --no-tun --dhcp `
  --network-name cyr-48213 --network-secret 48213 `
  --hostname cyr-guest-test `
  --rpc-portal 127.0.0.1:16002 -p tcp://<共享节点 IP>:11010

# ④ 检查客户端是否找到房主(应当出现一条 cyr-host-7777)
easytier-cli.exe --rpc-portal 127.0.0.1:16002 -o json peer

# ⑤ 下发转发规则(绑定口挑一个空闲端口)
easytier-cli.exe --rpc-portal 127.0.0.1:15889 port-forward add udp 127.0.0.1:24000 10.126.126.1:7777

# ⑥ 客户端游戏:在大厅页的「房间号」输入框填 48213
```

在游戏中的对应做法:两端各自在 `easytier/relay.txt` 里写一行共享节点地址,然后房主建房、
客户端填房间号 —— 隧道与转发规则全部自动完成。

| # | 验证项 | 结果 |
|---|---|---|
| W0-1 | no-tun 下 ENet(UDP)端到端 | ✅ 客户端连接 `127.0.0.1:<转发端口>` → 加入房间 → `match_start` |
| W0-2 | hostname 传递端口 | ✅ peer 列表里读到 `cyr-host-23117`,`host_port_of()` 取出 `23117` |
| W0-3 | 房间号派生 | ✅ 两端网络名相同即可见(客户端 DHCP 得到 `10.126.126.2`,看到房主 `10.126.126.1`) |
| W0-4 | 链路形态 | ✅ `cost: p2p`、`tunnel_proto: udp,udp6` |
| W0-5 | 共享节点只负责发现对端 | ✅ 共享节点自身不承载数据 |
| W0-6 | 无需管理员权限 | ✅ 全程 no-tun,不弹 UAC、不安装驱动 |
| W0-7 | 网段无冲突 | ✅ 本机真实网卡不在 `10.126.126.0/24` 内 |

### 8.3 验收清单

- [ ] `Server.exe -- --port P` 启动后占用的是客户端指定的那个端口
- [ ] 同一台机器同时开两个实例互不干扰
- [ ] 房主点「建房」→ 启动服务端与隧道 → 界面显示房间号;全程无 UAC
- [ ] 客户端输入房间号 → 启动隧道 → 读出端口 → 下发转发 → 连接 → 进入对局
- [ ] 建房后 `easytier/` 下有四件套与 `relay.txt`,`log/` 下有会话日志
- [ ] 建房 → 加入 → 对局 → 双方能看到对方移动、互相命中
- [ ] 局内断开网络 → 宽限期内重连成功
- [ ] 退出游戏后 `easytier-core.exe` 与本机服务端都不残留
- [ ] `tests/netplay_probe.gd` 全部通过
