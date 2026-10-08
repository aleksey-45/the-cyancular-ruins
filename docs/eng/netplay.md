# 网络系统架构与通信协议规范 (Network Architecture & Protocol Specification)

本文档系统性说明项目的网络底层架构、客户端预测与服务端校正管线（Client-Side Prediction & Server Reconciliation）、全量网络数据契约（Data Contracts & Packet Specs）、会话状态机、断线容错机制，并对现行协议的技术债务提供深度的诊断与下一代协议重构蓝图。

---

## 一、 架构全景与网络拓扑 (Network Topology & Architecture Overview)

```
                       ┌──────────────────────────────────────────────┐
                       │     EasyTier 用户态 P2P 虚拟网 / 局域网      │
                       └──────────────────────┬───────────────────────┘
                                              │ UDP / ENet
                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                       服务端权威宿主 (Server-Authoritative Dedicated Host)                   │
│                                                                                             │
│  ┌─────────────────────────┐               ┌─────────────────────────────────────────────┐  │
│  │ 房间管理器 (RoomManager) │  动态挂载     │ 权威对局会话 (MatchSession / MatchHost)      │  │
│  │  • 匹配大厅 / 选边编排  ├──────────────►│  • 60Hz 物理模拟与规则判定 (Deterministic Sim)│  │
│  │  • 端口管理与超时清理   │ (单进程单端口)│  • FIFO 输入队列消费与确认 (Input Queue)    │  │
│  │  • 重连凭据 (Rejoin)    │               │  • 双轨快照广播 (World Snapshot / Own State)│  │
│  └─────────────────────────┘               └─────────────────────────────────────────────┘  │
└───────────────────────────────────────┬─────────────────────────────────────────────────────┘
                                        │
                 ┌──────────────────────┴──────────────────────┐
                 ▼ (60Hz Unreliable 快照 + Reliable 事件)      ▼
┌─────────────────────────────────────────────┐ ┌─────────────────────────────────────────────┐
│             客户端 A (Client A)             │ │             客户端 B (Client B)             │
│  • 本地预测管线 (CSP Pipeline)              │ │  • 本地预测管线 (CSP Pipeline)              │
│  • 输入环形缓冲区 (Input Ring Buffer)       │ │  • 输入环形缓冲区 (Input Ring Buffer)       │
│  • 环面分歧比对与回滚 (Reconciliation)      │ │  • 环面分歧比对与回滚 (Reconciliation)      │
│  • 远端副本指数平滑 (PlayerReplica)         │ │  • 远端副本指数平滑 (PlayerReplica)         │
│  • 幽灵阻挡体感知 (Ghost Collider)          │ │  • 幽灵阻挡体感知 (Ghost Collider)          │
└─────────────────────────────────────────────┘ └─────────────────────────────────────────────┘
```

### 1. 传输层与免驱动 P2P 隧道
- **底层传输协议**：基于 Godot 原生 `ENetMultiplayerPeer`（底层为 UDP）。
- **EasyTier 用户态虚拟网（User-Space Overlay Network）**：
  - 核心进程运行于 `--no-tun` 模式，直接在应用层接管 UDP 数据包路由与转发。
  - **零驱动依赖**：无需安装系统级虚拟网卡驱动（如 TAP/TUN），无需 Windows UAC 管理员提权。
  - **NAT 穿透**：优先通过 STUN 服务器实现对等节点直连（P2P Direct Connect）；在对称型 NAT 等受限网络下，自动由 EasyTier 中继节点接力转发。

### 2. 单进程单端口会话架构 (Single-Process Session Architecture)
- **避免端口切换断流**：传统联机常采用“大厅主进程分配端口 -> 派生子进程对局 -> 客户端断开并重连新端口”模型，在 NAT 穿透环境下极易产生打洞失效与握手断点。
- **动态会话挂载**：
  - 服务端默认监听 UDP 7777（`DEFAULT_PORT`，可通过命令行 `--port P` 覆盖）。
  - 大厅匹配与实际对局运行在**同一进程、同一 UDP 套接字**内。
  - 房间满员开局时，`RoomManager` 直接将 `MatchSession` 节点挂载至服务端场景树。客户端在原 ENet 连接与 Peer ID 下直接切入对局，实现零延迟平滑入场。

### 3. 逻辑信道划分 (Logical Channel Allocation)
ENet 连接统一显式分配 4 个逻辑信道（`ENet_CHANNELS = 4`），避免因通道未初始化引发 `Unable to send packet on channel 0, max channels: 0` 错误：
- **Channel 0 (Reliable Ordered)**：可靠保序信道。承载房间匹配、开局指令、全量对齐快照、战斗判定事件、环境瓦片破坏及断线重连协议。
- **Channel 1 (Unreliable Sequenced)**：不可靠有序信道。承载 60Hz 高频物理快照广播（`snapshot_world`）与客户端本人校正快照（`snapshot_own`）。

---

## 二、 客户端预测与服务端校正 (Client-Side Prediction & Server Reconciliation)

为了在 2D 横版高频对抗中提供零延迟的平台跳跃与射击手感，系统实现了严密的 CSP（Client-Side Prediction）与服务端权威校正管线（参见 [`PredictionRollback`](../../core/net/prediction_rollback.gd) 与 [`PvpMatchClient`](../../scenes/pvp_match_client.gd)）。

### 1. 本地输入预测与环形缓冲区
1. **即时推演**：本地玩家每物理帧采集输入设备（键盘、鼠标），生成带自增序号 `seq` 的输入包，并在本地即时执行物理积分（位移、跳跃、冲刺、抓墙）。
2. **输入环形缓冲区 (Input Ring Buffer)**：
   - 客户端维护容量为 128 帧的环形缓冲区，记录每帧的 `(seq, input_packet, predicted_state)`。
   - 输入包以 60Hz 频率通过 `send_input` Reliable 发往服务端。

### 2. 服务端权威处理与确认 (Authoritative Processing)
1. **FIFO 输入消费**：服务端为每位玩家维护独立的输入包队列，每个物理 Tick 从队列头部消费一个输入包，注入权威物理世界模拟。
2. **确认序号回传**：服务端生成快照时，在专属包（`snapshot_own`）中携带当前已完成物理积分的最新输入序号 `ack_seq`。

### 3. 分歧比对与回滚重演 (Rollback & Resimulation)
客户端收到 `snapshot_own` 后执行服务端校正：
1. **历史锚点查找**：在本地环形缓冲区中定位 `seq == ack_seq` 的历史记录。丢弃所有 `seq < ack_seq` 的已确认过期记录。
2. **分歧判定**：比对历史预测位置与服务端权威位置 `c2.pos`。
3. **回滚重放**：若偏差超出容差阈值，执行重置并重放：
   - 调用 `Player.restore_state(c2)` 将本地角色瞬时复原至权威状态。
   - 提取从 `ack_seq + 1` 至当前本地最新帧的所有未确认输入包。
   - 在单个物理帧内连续快进模拟（Fast-forward Resimulation）这些输入帧，平滑回到当前时刻。

### 4. 环面流形坐标解算 (Toroidal Coordinate Resolution)
游戏世界为环面几何（水平与垂直双向无缝连通，坐标区间 $[0, W)$ 与 $[0, H)$）：
- **严禁直接向量相减**：若角色从坐标 $W - 1$ 跨过边界移动到 $0$，直接欧氏减法会得出幅度为 $-W$ 的巨大位移，引发灾难性误回滚。
- **最短位移计算**：分歧比对与相对位移计算必须统一调用 `GridPathfinder.toroidal_delta_px()`：
  $$\Delta x = \operatorname{wrap}(x_{\text{pred}} - x_{\text{auth}} + W/2, W) - W/2$$
- 实体跨越世界接缝时，坐标通过 `GridPathfinder.wrap_to_range()` 规范化，确保预测与校正的几何拓扑连续。

### 5. 动态贴身接触容差 (Contact-Adaptive Tolerance)
在 2D 平台动作游戏中，两名玩家贴身缠斗时，角色控制器的滑动挤压运算极易产生亚像素级微小发散：
- **常规状态容差**：`pos_tol = 2.0px`。
- **贴身接触容差**：当检测到两名玩家发生物理碰撞接触时（`Player.touching_player() == true`），容差动态放宽至 `contact_pos_tol = 8.0px`。
- **平滑消抖**：接触解除后容差立即恢复 2.0px。该自适应机制有效消除了近身推挤与肉搏过程中高频触发回滚导致的画面剧烈抖动。

### 6. 远端玩家副本与幽灵阻挡体 (PlayerReplica & Ghost Body)
1. **指数平滑插值**：远端玩家通过 `PlayerReplica` 渲染，从 `snapshot_world` 获取权威位置，采用指数滤波平滑渲染抖动：
   $$\vec{P}_{\text{render}} = \vec{P}_{\text{render}} + (\vec{P}_{\text{target}} - \vec{P}_{\text{render}}) \times (1 - e^{-12 \cdot \Delta t})$$
2. **幽灵碰撞体 (Ghost Body)**：
   - 远端副本挂载一个轻量 `StaticBody2D`（Layer 2，Mask 0），其坐标直接与最新收到的服务端原始坐标硬对齐（不经过视觉平滑插值）。
   - 本地玩家的碰撞检测掩码包含 Layer 2。因此本地预测步进时即可感知远端玩家的物理阻挡，杜绝了本地穿透而服务端阻挡导致的频繁回滚。

---

## 三、 网络协议数据契约与报文规范 (Data Contracts & Packet Specs)

### 1. 通信路由总览 (RPC Routing Matrix)

| 节点 | 方法名 | 方向 | 传输模式 | 信道 | 触发频次 | 用途 |
|---|---|---|---|---|---|---|
| `NetBus` | `create_room` | C $\to$ S | Reliable | 0 | 偶发 | 请求创建 1v1 房间 |
| `NetBus` | `join_room` | C $\to$ S | Reliable | 0 | 偶发 | 加入指定 1v1 房间 |
| `NetBus` | `send_input` | C $\to$ S | Reliable | 0 | 60Hz | 上报客户端输入包 |
| `NetBus` | `claim_role` | C $\to$ S | Reliable | 0 | 进场一次 | 认领角色席位与上报昵称 |
| `NetBus` | `match_sync` | C $\to$ S | Reliable | 0 | 进场/重连 | 主动拉取全量静态与增量状态 |
| `NetBus` | `snapshot_world` | S $\to$ C | Unreliable | 1 | 60Hz | 广播全场实体渲染态快照 |
| `NetBus` | `snapshot_own` | S $\to$ C | Unreliable | 1 | 60Hz | 定向发送客户端物理校正状态 |
| `NetBus` | `bullet_spawn` | S $\to$ C | Reliable | 0 | 事件触发 | 广播物理子弹生成 |
| `NetBus` | `beam_fired` | S $\to$ C | Reliable | 0 | 事件触发 | 广播即时光束（激光）轨迹 |
| `NetBus` | `match_sync_data` | S $\to$ C | Reliable | 0 | 响应拉取 | 下发全量静态与环境状态 |
| `NetBus` | `hit_event` | S $\to$ C | Reliable | 0 | 事件触发 | 广播受击伤害与击退 |
| `NetBus` | `tile_destroyed` | S $\to$ C | Reliable | 0 | 事件触发 | 广播宏观瓦片（64px）破坏 |
| `NetBus` | `round_state` | S $\to$ C | Reliable | 0 | 状态跳变 | 广播回合阶段与倒计时 |
| `NetBus` | `weapon_spawned` | S $\to$ C | Reliable | 0 | 事件触发 | 广播场上新增地面武器 |
| `NetBus` | `weapon_removed` | S $\to$ C | Reliable | 0 | 事件触发 | 广播场上移除地面武器 |
| `NetBus` | `kill_event` | S $\to$ C | Reliable | 0 | 事件触发 | 广播击杀归因事件 |
| `NetBus` | `go_match` | S $\to$ C | Reliable | 0 | 开局一次 | 通知客户端切入对局场景 |
| `NetBusExt` | `sub_destroyed` | S $\to$ C | Reliable | 0 | 事件触发 | 广播 16px 子格破坏 |
| `NetBusExt` | `hit_confirm` | S $\to$ C | Reliable | 0 | 事件触发 | 定向向射手发送 FPS 命中反馈 |
| `NetBusExt` | `reclaim_role` | C $\to$ S | Reliable | 0 | 重连触发 | 断线重连认领角色席位 |
| `NetBusExt` | `rejoin_request` | C $\to$ S | Reliable | 0 | 大厅触发 | 跨场景重返对局申请 |

---

### 2. 客户端输入报文契约 (`send_input`)

输入包通过 `PacketInputSource.pack_record()` 统一构造，为动态字典结构：

```gdscript
{
    "seq": int,        # 单调递增输入序号（自 1 起算）
    "ax": float,       # 水平移动轴 [-1.0, 1.0]
    "held": int,       # 持续按住状态位掩码
    "pressed": int,    # 边沿触发按下状态位掩码 (Just Pressed)
    "released": int,   # 边沿触发释放状态位掩码 (Just Released)
    "winst": int,      # 目标武器实例 ID（0 表示本帧无切枪请求）
    "aim": Vector2     # 归一化鼠标瞄准方向向量
}
```

#### 按键位掩码定义 (Key Bitmask Definitions)
| 常量名 | 掩码值 | 语义 | 生效信道 |
|---|---|---|---|
| `BIT_UP` | `1` ($2^0$) | 向上 / 跳跃 | held, pressed, released |
| `BIT_DOWN` | `2` ($2^1$) | 向下 / 下蹲 / 穿透平台 | held, pressed, released |
| `BIT_CHARGE` | `4` ($2^2$) | 冲刺 (Dash) | held, pressed, released |
| `BIT_ATTACK` | `8` ($2^3$) | 主武器开火 | held, pressed, released |
| `BIT_RELOAD` | `16` ($2^4$) | 手动装填 (Reload) | held, pressed, released |
| `BIT_PICKUP` | `32` ($2^5$) | 拾取地面武器 (F 键，纯边沿) | pressed |
| `BIT_DROP` | `64` ($2^6$) | 丢弃当前武器 (长按 Q 满 2s 触发，纯边沿) | pressed |
| `BIT_HASTE` | `128` ($2^7$) | 时间加速激活 (单人/Beta 规则) | held |
| `BIT_REWIND` | `256` ($2^8$) | 时空回溯激活 (单人/Beta 规则) | held |

---

### 3. 服务端双轨快照系统 (Dual-Track Snapshot System)

为避免 $O(N^2)$ 序列化开销，服务端快照分为两组不同受众的报文：

#### A. 全场渲染态快照 (`snapshot_world`)
单次序列化后广播给所有客户端（开销 $O(N)$），用于驱动远端玩家副本渲染：
```gdscript
{
    "tick": int,                         # 服务端权威物理 Tick
    "players": {
        "<role_id>": {                   # 字符串键角色编号 ("1", "2" 等)
            "pos": Vector2,              # 角色世界绝对坐标
            "vel": Vector2,              # 角色当前速度向量
            "facing": int,               # 面朝方向 (1=右, -1=左)
            "pose": int,                 # 动画姿态状态枚举
            "type_id": int,              # 手持武器配置类型 ID (WeaponRegistry)
            "hp": int,                   # 当前生命值
            "waterproof": bool,          # 防水服装备状态
            "downed": bool,              # 是否处于倒地硬直状态
            "aim": Vector2,              # 瞄准方向向量
            "previewing": bool,          # 是否处于重武器蓄力预瞄状态
            "haste": bool,               # 是否处于加速状态
            "rewind": bool,              # 是否处于回溯状态
            "trail": Array[Vector2]      # 最近 3 帧回溯残影轨迹点
        }
    }
}
```

#### B. 本地专属校正快照 (`snapshot_own`)
定向发送给角色本人，携带完整的物理内部状态，供客户端执行预测比对与回滚重演：
```gdscript
{
    "ack_seq": int,                      # 服务端已确认消费的最新输入包序号
    "c2": {                              # 角色全量物理状态字典 (Player.capture_state)
        "pos": Vector2,                  # 权威全局坐标
        "vel": Vector2,                  # 权威线速度
        "facing": int,                   # 朝向
        "state": int,                    # 内部移动状态机状态
        "slock": float,                  # 状态锁定计时器
        "coyote": float,                 # 土狼时间计时器
        "jbuf": float,                   # 跳跃输入缓冲计时器
        "jcut": bool,                    # 跳跃可变高度截断标志
        "squat": bool,                   # 下蹲标志
        "charge": bool,                  # 冲刺标志
        "ct": float,                     # 冲刺剩余时长计时器
        "lmv_d": int,                    # 上次移动方向
        "lmv_t": float,                  # 上次移动窗口计时器
        "wp": bool,                      # 防水服持有标志
        "wp_t": float,                   # 防水服防护计时器
        "wp_s": bool,                    # 是否曾浸水标志
        "wp_d": float,                   # 溺水伤害计时器
        "clatch": bool,                  # 梯子抓取附着标志
        "swim": bool,                    # 游泳涉水标志
        "hp": int,                       # 生命值
        "ifr": float,                    # 受击无敌帧计时器
        "down": bool,                    # 倒地状态
        "knock": Vector2,                # 受击击退速度向量
        "wslot": int,                    # 当前手持武器槽位
        "winst": int,                    # 当前手持武器唯一实例 ID
        "wmag": int,                     # 当前武器弹匣弹药量
        "wres": int,                     # 当前武器备弹量
        "wrld": float                    # 换弹冷却计时器
    }
}
```

---

### 4. 全量状态拉取与对齐报文 (`match_sync` & `match_sync_data`)

用于客户端场景初始化完成后的首发对齐，或断线重连后的环境状态补回：

```gdscript
# match_sync_data 载荷规范
{
    "roles": Array[int],                 # 参战角色 ID 清单 [1, 2, ...]
    "names": { 1: "Alice", 2: "Bob" },   # 角色名映射表
    "hues": { 1: 0.0, 2: 180.0 },        # 角色色相度数表
    "spawns": { 1: Vector2i, ... },      # 各角色出生网格坐标
    "options": Dictionary,               # 生效对局选项（禁用武器、生命值规则等）
    "destroyed": Array[Vector2i],        # 全量已被摧毁的瓦片网格坐标列表 (回补幻影墙)
    "ground_weapons": [                  # 全场地面散落武器列表 (回补幽灵武器)
        {
            "inst": int,                 # 武器唯一实例 ID
            "type_id": int,              # 武器配置类型 ID
            "mag": int,                  # 弹匣弹药量
            "reserve": int,              # 备用弹药量
            "pos": Vector2,              # 地面世界坐标
            "vel": Vector2               # 抛投滑动速度
        }
    ]
}
```

---

## 四、 会话生命周期与状态机流转 (Session Lifecycle & Handshake FSM)

```
[客户端]                                              [服务端]
   │                                                     │
   │ 1. 房间匹配阶段                                      │
   ├─────── create_room / royale_create / team_create ──►│ 记录房间账本
   ├─────── join_room / royale_join / team_join ────────►│ 分配唯一 Role ID
   │◄────── royale_room_state / team_room_state ─────────┤ 广播等待室状态
   │                                                     │
   │ 2. 开局编排与会话初始化                              │
   │        (房主触发 start / 满员自启)                  │
   │◄────── session_token(token) ────────────────────────┤ 生成 16 位会话凭据
   │◄────── go_match(role, server_port) ─────────────────┤ 挂载 MatchSession 节点
   │                                                     │
   │ 3. 场景异步加载与席位认领 (Handshake)                │
   │ (客户端切入 pvp_game 场景树并初始化)                 │
   ├─────── claim_role(role, player_name) ──────────────►│ 绑定 PeerID <-> RoleID
   ├─────── report_token(token) ────────────────────────►│ 注册宽限期重连凭据
   │◄────── peer_info(names) ────────────────────────────┤ 广播全员昵称
   │                                                     │
   │ 4. 拉取驱动的全量基准状态对齐                        │
   ├─────── match_sync() ───────────────────────────────►│ 收集当前世界基准态
   │◄────── match_sync_data(payload) ────────────────────┤ 下发出生点/选项/墙体/武器
   │                                                     │
   │ 5. 权威物理对局阶段 (PLAYING)                        │
   │◄────── round_state("PLAYING") ──────────────────────┤ 解除操作冻结
   ├─────── send_input(pkt) [60Hz Reliable] ────────────►│ FIFO 队列消费模拟
   │◄────── snapshot_world(world) [60Hz Unreliable] ─────┤ 驱动远端副本
   │◄────── snapshot_own(own) [60Hz Unreliable] ─────────┤ 触发 CSP 本地校正
```

### 1. 场景加载竞态防范：拉取驱动机制 (Pull-based Initial Resync)
- **历史缺陷**：早期实现中，服务端在开局瞬间向客户端推送配置，而客户端当时正在进行 Godot 场景切换（`safe_change_scene`）。新场景尚未入树，信号未挂载，导致开局载荷被静默丢弃。
- **拉取解决**：改由客户端在完成场景 `_ready()` 并就绪后，主动向服务端上报 `match_sync()`。服务端收到后定向回发 `match_sync_data`，彻底解决异步加载竞态。

---

## 五、 断线容错与双阶段重连机制 (Fault Tolerance & Reconnection)

系统针对弱网闪断与意外退房设计了双阶段宽限期恢复模型：

### 1. 局内闪断快速重连 (Stage 1: In-Match Fast Reconnect)
适用于网络丢包、网络切换或瞬时断连（玩家仍停留在对局界面）：
1. **60 秒断线宽限期 (`GraceWindow`)**：
   - 客户端意外断开时，服务端**不销毁**其局内物理实体与背包，将其输入队列暂停，并启动 60 秒倒计时。
   - 对局状态广播附带 `grace` 读数，其余在线玩家 HUD 显示对手掉线倒计时。
2. **快速重连与席位认领**：
   - 客户端检测到 `server_disconnected` 后，在局内启动指数退避重连，复用本地记录的 `server_port` 与 `token`。
   - 重新建连后向服务端发送 `reclaim_role(role, token)`。服务端校验 Token 一致且该角色处于宽限期内，予以通过。
3. **序列号重协商与状态回补**：
   - 服务端重置该角色的 `_ack_seq` 为 0，重协商确认锚点。
   - 客户端重置本地 `_rollback` 实例与 `_input_seq = 0`，防止旧历史帧错位。
   - 客户端立即触发 `match_sync()`，服务端下发断线期间被破坏的瓦片（`destroyed`）与地面武器变动（`ground_weapons`），无缝消除幽灵物体。

### 2. 大厅跨场景重连 (Stage 2: Lobby-Mediated Rejoin)
适用于玩家崩溃重启游戏、或误按 ESC 返回大厅：
1. **凭据持久化 (`RejoinRegistry`)**：
   - 开局时为玩家签发唯一的会话凭据（包含 `token`, `match_id`, `role`, `room_code`），有效期为 1 小时。
2. **大厅对局可见性与重入**：
   - 正在对局中的房间在大厅列表中对第三方显示为“对局中，不可加入”；但对持有合法重连凭据的本人开放重连入口。
   - 客户端发送 `rejoin_request(room_code, token)`，服务端通过 `RejoinRegistry.decision()` 校验凭据有效性及对局是否存活。
   - 校验通过后，服务端直接回传 `go_match(role, server_port)`，客户端载入对局场景并沿用 Stage 1 协议认领席位。

---

## 六、 套接字健壮性与信道安全机制 (Socket Robustness & Defenses)

在 ENet 通信中，处理节点断开与重连时极易踩中引擎底层通道清零的边缘异常。项目建立了严格的防护收口：

### 1. 对等节点存活实时校验 (`is_peer_live`)
- **引擎底层成因**：Godot 源码中，`enet_peer_disconnect()` 在调用的瞬间就会触发 `peer->channelCount = 0`，但引擎上层的 `multiplayer.get_peers()` 信号派发滞后至少 1 帧。此时若向该节点发送定向 Reliable RPC，引擎直接报错：`Unable to send packet on channel 0, max channels: 0`。
- **解决方案**：统一封装 `NetBus.is_peer_live(id)`：
  ```gdscript
  func is_peer_live(id: int) -> bool:
      if not (multiplayer.multiplayer_peer is ENetMultiplayerPeer):
          return multiplayer.get_peers().has(id)
      var p := (multiplayer.multiplayer_peer as ENetMultiplayerPeer).get_peer(id)
      return p != null and p.get_state() == ENetPacketPeer.STATE_CONNECTED and p.get_channels() > 0
  ```
  直接绕过滞后的引擎上层列表，精确读取 ENet 原生状态位与通道计数。

### 2. 全员广播前置校验 (`all_peers_sendable`)
在执行 `rpc("snapshot_world", ...)` 广播前，必须调用 `all_peers_sendable()` 确认表内**每一个** Peer 的信道计数均大于 0。若有任意节点处于正在断开握手的过渡期，当帧主动短路不可靠快照广播，彻底杜绝广播引发的底层信道崩溃。

### 3. 定向响应安全收口 (`NetBus.reply`)
所有服务端响应客户端请求的发送点，统一收口至 `NetBus.reply(id, method, args...)`。发送前自动执行 `is_peer_live(id)` 校验，对端已断开时静默丢弃，杜绝请求处理与客户端主动断连并发碰撞时的异常报错。

---

## 七、 现行协议技术债诊断与下一代重构蓝图 (Technical Debt & Refactoring Blueprint)

### 1. 现行协议核心缺陷诊断 (Current Protocol Deficiencies)

现行协议属于典型的“基于动态字典原型拼接的临时实现（AI Slop / Prototype-style Protocol）”，存在以下系统性架构隐患：

1. **动态 Dictionary 序列化导致的严重 CPU/内存开销**：
   - 所有的输入包、快照、同步数据均使用 GDScript `Dictionary` 传递。
   - 每秒 60 次发送包含数十个字符串键名（如 `"pos"`, `"vel"`, `"facing"`, `"winst"`, `"lmv_d"`）的字典，导致高昂的字符串哈希寻址开销、二进制序列化元数据膨胀，以及严重的 GDScript 内存分配颠簸（GC Churn）。
2. **缺乏形式化物理 Tick 与严格时间基准**：
   - 客户端使用自增的 `input_seq`，服务端使用 `_snap_tick`。序列号是无物理时间量纲的标量，未绑定绝对物理时间步进（Tick 序号）。
   - 网络发生抖动或丢包重传时，两端缺乏统一的固定 Tick 步进对齐，容易引发输入队列积压或饥饿。
3. **输入流缺乏前向冗余编码（Sliding Window Redundancy）**：
   - 当前输入包完全依赖 ENet Channel 0 的 Reliable 机制传输。
   - 在高延迟或偶发丢包环境下，TCP 式的 Reliable 重传机制会导致后续输入包阻塞，服务端物理模拟队列瞬间饥饿，恢复后引发剧烈的批量追帧回滚。
4. **状态机转换依赖脆弱的延时避让**：
   - 大厅与对局切换多处依赖 `await get_tree().process_frame` 等待一帧来规避信道清零竞态，时序逻辑脆弱，缺乏严格的 ACK/NACK 状态机校验。

---

### 2. 下一代协议重构设计规范 (Next-Gen Protocol Blueprint)

未来协议重构应遵循以下工业化网络同步设计标准：

```
┌────────────────────────────────────────────────────────────────────────┐
│               下一代紧凑输入报文 (Compact Binary Input Packet)          │
├───────────────┬───────────────┬───────────────────┬────────────────────┤
│ Client Tick   │ Ack ServerTick│ Input History x3  │ Compact Aim & Act  │
│ (uint32, 4B)  │ (uint32, 4B)  │ (Bitmask, 3x2B=6B)│ (Half-Float, 4B)   │
└───────────────┴───────────────┴───────────────────┴────────────────────┘
 总长度: ~18 字节 (相比现行 Dictionary 的 ~200+ 字节，带宽开销降低 90% 以上)
```

#### A. 紧凑二进制封包 (Packed Binary Structs)
- **丢弃动态字典**：使用 `PackedByteArray` 与 Godot `StreamPeerBuffer` 进行二进制序列化。
- **定长数据布局**：
  - 输入位掩码压缩为定长 `uint16`；
  - 角色坐标与速度量化为定长 `int16`（定点数，精度 0.1px）或 `float32`；
  - 瞄准角使用 `uint8` 编码（256 度量化）。

#### B. 统一确定性物理 Tick 时钟体系 (Global Fixed Tick Clock)
- 服务端与客户端建立统一的 60Hz 物理 Tick 标尺（`server_tick` / `client_tick`）。
- 客户端输入与服务端快照均以明确的 `tick` 寻址，取代无量纲的序列计数器。
- 客户端预测重放严格按照 Tick 步进差分执行，确保物理模拟确定性。

#### C. 滑动窗口输入前向冗余 (Sliding Window Input Redundancy)
- 输入包迁移至 **Unreliable 传输通道**。
- 每个输入包携带当前 Tick 的输入，并**冗余附带过去 2~3 个历史 Tick 的紧凑输入掩码**：
  $$\text{Packet}(T) = \{ T, \text{Input}(T), \text{Input}(T-1), \text{Input}(T-2) \}$$
- 即使遭遇单包丢失，服务端也能无缝从后续包中解包出丢失帧的输入，无需等待重传，彻底消灭因网络抖动引起的输入队列卡顿与重演雪崩。

#### D. 形式化连接与会话状态机 (Formal Connection FSM)
- 废弃一切基于 `await process_frame` 的延时竞态避让。
- 大厅匹配、对局移交、断线重连全流程严格基于显式状态机（`DISCONNECTED` $\to$ `CONNECTING` $\to$ `LOBBY` $\to$ `HANDSHAKE` $\to$ `IN_MATCH` $\to$ `RECONNECTING`）与超时重试策略运转。
