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

四个文件放在客户端同目录:`easytier-core.exe` / `easytier-cli.exe` / `Packet.dll` / `wintun.dll`。
`tools/fetch_easytier.py` 在构建阶段下载并完整解压。

★ **必须四个文件一起放**:`easytier-core.exe` 静态依赖 `Packet.dll`,缺少它的表现是进程无法启动
(Windows 返回 `0xC0000135`,stdout/stderr 没有任何输出,`OS.create_process` 只得到一个立即退出的
pid)。`available()` 因此把这两个 dll 也算进"文件是否齐全"。

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

内置在 `TunnelMeta.RELAYS`(当前是 `dreamlife.indevs.in` 的 tcp 与 udp 两条);要更换就在
`user://easytier-relay.txt` 里每行写一个地址(`Tunnel.relay_list()` 读到文件就只用文件内容;
`host:port` 或完整 URL 都可以,`#` 开头是注释)。

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
| `core/net/tunnel.gd` | 房间号生成/校验/解析;EasyTier 进程与命令行参数;就绪检测;下发转发规则;解析 CLI 输出 |
| `core/config/tunnel_meta.gd` | 版本号 / 可执行文件名 / 必需的两个 dll / 下载地址 / 许可证 / 主机名前缀 / 虚拟网段 / 初始节点(与配置文件路径)/ RPC 端口区间 |
| `core/net/local_server.gd` | `launch_and_connect()`(选择端口 → 启动服务端 → 检测连接)/ `stop_owned()` |
| `core/net/pvp_session.gd` | 连接参数(`server_address` / `server_port` / `room_code`)与回局凭据 |
| `core/net/net_bus.gd` | `@rpc` 统一入口;`_exit_tree` 关闭本机服务端与隧道 |
| `server/match_session.gd` | 一局的编排(名册 / claims / 宽限期 / 开局 / `match_sync`) |
| `server/lobby_rooms.gd` | 三种模式的房间表与建房、加入、退出 |
| `scenes/lobby_page.gd` | 三个页面共用的建房与加入流程(`_ensure_own_server()` / `_join_with_code()`)、房间号显示 |
| `tools/fetch_easytier.py` | 构建阶段下载并完整解压 EasyTier |
| `tests/netplay_probe.gd` | 房间号 / peer 解析 / 源码级契约 |
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
```

`netplay_probe` 的判断项(10 万次抽样):`generate_room()` 恒为 5 位数字、每个结果都能通过
`is_valid_room`(往返一致)、首位数字分布均匀、不同房间号的网络名互不相同;以及 `host_port_of` /
`pick_host_peer` / `parse_peers_json` 的边界与异常输入。

### 8.2 手工验证隧道

一个共享节点 + 一个房主 + 一个客户端,三个 easytier-core 进程都在 127.0.0.1 上,用真实网卡 IP
作为对端地址。真实两机部署时把 `<本机对外 IP>` 换成各自那台的地址。

```powershell
# ① 共享节点(用自己的网络名;两端都指向它,用于互相发现)
easytier-core.exe --no-tun --network-name relay-net --network-secret relay-secret `
  --hostname cyr-relay -l tcp://0.0.0.0:11010 -l udp://0.0.0.0:11010

# ② 房主(另开一个窗口);再另开一个窗口运行:Cyancular Ruins Server.exe -- --port 7777
easytier-core.exe --no-tun -i 10.126.126.1 `
  --network-name cyr-48213 --network-secret 48213 `
  --hostname cyr-host-7777 `
  --rpc-portal 127.0.0.1:15888 -p tcp://<本机对外 IP>:11010

# ③ 客户端
easytier-core.exe --no-tun --dhcp `
  --network-name cyr-48213 --network-secret 48213 `
  --hostname cyr-guest-test `
  --rpc-portal 127.0.0.1:15889 -p tcp://<共享节点 IP>:11010

# ④ 检查客户端是否找到房主(应当出现一条 cyr-host-7777)
easytier-cli.exe --rpc-portal 127.0.0.1:15889 -o json peer

# ⑤ 下发转发规则(绑定口挑一个空闲端口)
easytier-cli.exe --rpc-portal 127.0.0.1:15889 port-forward add udp 127.0.0.1:24000 10.126.126.1:7777

# ⑥ 客户端游戏:在大厅页的「房间号」输入框填 48213
```

在游戏中的对应做法:两端各自在 `user://easytier-relay.txt` 里写一行共享节点地址,然后房主建房、
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
- [ ] 建房 → 加入 → 对局 → 双方能看到对方移动、互相命中
- [ ] 局内断开网络 → 宽限期内重连成功
- [ ] 退出游戏后 `easytier-core.exe` 与本机服务端都不残留
- [ ] `tests/netplay_probe.gd` 全部通过
