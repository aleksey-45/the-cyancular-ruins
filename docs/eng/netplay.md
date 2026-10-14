# 联机网络系统

本项目基于 Godot 4.7.1 原生 ENet 实现多人网络对战，采用专用的二进制序列化协议配合 Zstd 包级压缩。服务端单进程管理房间会话与权威世界模拟；对局结束后无缝返回同一房间。1v1、3v3 及大乱斗等模式共用统一的客户端预测、服务端物理模拟与表现层管线。

---

## 一、 状态归属与模块生命周期

| 模块 / 状态 | 职责持有者 | 说明 |
|---|---|---|
| 对等连接（Peer）、席位分配、重连令牌（Token）、60秒断线宽限期 | [RoomSession](../../server/room_session.gd) | 管理网络会话生命周期与断线保护 |
| 玩家实体、子弹投射物、地面掉落物与伤害结算 | [AuthorityWorld](../../server/authority_world.gd) | 服务端权威物理世界与战斗裁决 |
| 输入调度队列、控制阶段（epoch）、移动与动作确认（ACK） | [InputBuffer](../../core/net/input_buffer.gd) | 输入时序整理、去重与过期清理 |
| 本地输入时钟、重发记录与预测重放历史 | [PredictionRollback](../../core/net/prediction_rollback.gd) | 客户端预测与服务端状态对齐回滚 |
| 远端实体播放时钟与状态插值缓冲 | [SnapshotBuffer](../../core/net/snapshot_buffer.gd) | 平滑远端实体的移动与表现 |
| 本地角色与武器的视觉平滑偏移 | Player.Visuals | 衰减网络预测修正产生的视觉抖动 |
| 角色移动、跳跃、攀爬、游泳与武器物理步进 | [ActorStep](../../core/sim/actor_step.gd) | 纯逻辑共享步进器，双端共用 |

- **通信与规则**：[NetBus](../../core/net/net_bus.gd) 负责底层 ENet 连接管理、通道数据收发与消息派发；[NetCodec](../../core/net/net_codec.gd) 负责二进制高效编解码与增量快照缓存；[MatchRules](../../server/match_rules.gd) 负责对战模式计分、出生点分配、复活与回合流转。禁用 `SceneMultiplayer` 的默认 `server_relay`，由房间直接分发客户端报文。
- **基线与状态同步**：加入对局、断线重连与新回合均遵循标准握手流程：`服务端下发完整 BASELINE → 客户端初始化场景与碰撞体 → 客户端上报 READY → 恢复定频 STATE 快照同步`。基线包含地图数据、当前子格生命值、所有存活实体以及玩家自身状态。
- **连接状态流转**：客户端状态依次经历 `LOADING`（加载中）、`ONLINE`（在线对战）、`RECONNECTING`（断线重连中）、`OFFLINE`（离线）。场景加载期间的地形破坏事件由大厅缓存，客户端初始化完毕后按序应用。

---

## 二、 进程管理与生命周期

Windows 客户端通过 [NetSession](../../core/net/net_session.gd) 持有一个 Windows Job 作业对象句柄。本地服务端、EasyTier 核心进程、CLI 工具及其派生的全部子进程均在创建时加入该作业对象（通过 [OwnedProcessGroup](../../native/process_group/process_group.cpp) 中的 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 实现），并配置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 标志。

- **安全退出保障**：作业对象句柄由客户端独占持有且禁止子进程继承。离开联机会话时调用 `NetSession.close()`，依次断开 ENet、关闭 Job 句柄并清空网络状态。无论是窗口正常关闭、崩溃退出还是被任务管理器强杀，Windows 操作系统都会自动回收作业对象句柄并强制终止所属的全部后台子进程，从根本上杜绝孤儿进程和端口残留。
- **Windows 兼容性**：扩展面向 64 位 Windows 10 及以上系统，接口依据 [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) 实现。
- **macOS 生命周期**：[macOS 扩展](../../native/process_group/process_group_macos.cpp) 使用 `posix_spawn` 将会话子进程加入独立进程组。守护子进程等待生命期管道 EOF，随后终止该进程组；客户端独占管道写端，写端禁止跨 exec 继承。关闭会话与客户端被强制结束都会关闭写端，触发同一退出流程。联机组件统一经 `NetSession.launch()` 启动，嵌套会话各自持有自己的管道与进程组。CLI 输出按帧非阻塞读取。

macOS 发布版以同一 `.app` 的 `--headless -- --server` 入口运行本地服务端；EasyTier 位于应用包的 `Contents/Helpers/`，日志和中继列表位于用户数据目录。具体构建见[开发工具](tools.md)，测试入口见[进程生命周期验证](process_lifecycle_validation.md)。

---

## 三、 网络通信通道 (Channels)

接口通过 `send_input`、`send_state`、`send_event` 暴露，内部使用 `SceneMultiplayer.send_bytes` 配合 `StreamPeerBuffer` 进行紧凑的小端二进制读写。首字节标识数据通道（`flow`），EVENT 报文随后写入事件类型（`kind`）：

| 通道名称 | flow | ENet 通道 | 传输可靠性 | 报文内容说明 |
|---|---:|---:|---|---|
| **INPUT** | 0 | 1 | Unreliable | 客户端上报：最新 4 帧持续输入、未确认动作列表、已收到的最新快照序号 ACK |
| **STATE** | 1 | 2 | Unreliable Ordered | 服务端广播：增量世界快照、接收者预测状态、移动/动作确认序号、时钟到达余量反馈、地图版本号 |
| **EVENT** | 2 | 0 | Reliable Ordered | 关键事件：房间信令、完整基线数据、READY 就绪确认、地形破坏、回合转换、开火/受击事件与激光特效 |

- **输入数据包结构**：INPUT 包含控制阶段标识 `control_epoch` 与连续移动帧的起始序号。每帧移动数据记录目标 tick、观察到的服务端 tick、移动轴向、持续按键与瞄准方向。单次触发动作（跳跃、换弹、拾取等）单独携带序号、目标 tick、按键边沿与武器上下文，并通过 `action_ack` 独立确认。
- **实体索引与命中判定**：动态实体使用自增整数 ID 标识。子弹投射物编号结合了玩家 ID、开火序号与弹丸序号，便于本地预测与权威快照精确对齐合并。伤害结算、弹药扣除、掉落物拾取与地形破坏均由服务端权威计算。

---

## 四、 状态快照与增量同步 (Delta Compression)

STATE 报文头包含消息类型、当前快照序号、基准快照序号、服务端世界 tick 与地图版本号 `map_revision`，共计 17 字节。快照序号按连接独立递增；基准序号为 0 时表示不依赖历史的独立全量快照。

- **差量编码机制**：全量快照提供角色顺序表，增量快照通过位图记录角色的存活与变化状态。子弹投射物通过 8 字节 ID、变化位图及更新的位置/速度进行差量编码。若匀速子弹仅发生位置位移，更新包仅占用 17 字节。
- **双端基线确认机制**：双端各自维护最多 64 份解码快照历史缓存。客户端成功解码快照后更新 ACK 并上报，服务端始终以客户端最新确认的快照作为基准进行差量压缩。若服务端历史基线已过期，则自动下发全量快照；若客户端缺失指定基线，则丢弃该差量并在下次 INPUT 中发送 `ACK=0` 请求新的全量快照。
- **地图版本同步**：每次地形瓦片发生破坏时，地图版本号 `map_revision` 递增并通过 EVENT 可靠同步。客户端若收到未来版本的世界快照，会先暂存远端数据，待地形更新报文追上后再应用生效，避免因碰撞体未更新造成角色悬空或穿墙。

设计参考了 [Quake III 消息编码机制](https://github.com/id-Software/Quake-III-Arena/blob/master/code/qcommon/msg.c) 与 [Snapshot Compression 增量压缩协议](https://gafferongames.com/post/snapshot_compression/)。

---

## 五、 ENet 包级 Zstd 压缩

服务端与客户端在创建 ENet 连接成功后、挂载至 MultiplayerAPI 之前统一启用压缩：

```gdscript
peer.get_host().compress(ENetConnection.COMPRESS_ZSTD)
```

双端必须配置相同算法。ENet 底层在发送前对 UDP 包体调用 Zstd 压缩器，若压缩后体积反而变大则自动回退发送原包。协议头分片与重组由 ENet 原生处理，大体积基线与全量快照均可安全分片传输。

---

## 六、 输入调度与物理模拟

- **时序调度**：服务端以 60Hz 执行物理世界模拟，以 30Hz 向客户端发送 STATE 快照。`InputBuffer` 按 `target_tick` 组织未来输入；若收到迟到输入，则顺延至下一 tick 执行。未来调度窗口最大为 32 tick；网络丢包时持续移动轴最多向后延续 6 tick，随后归零并保持瞄准方向。
- **动作确认与时效性**：跳跃、切枪、换弹、拾取与丢弃等属于单次触发动作。未确认的动作会随后续 INPUT 报文持续冗余重发，超出目标时间 12 tick（200ms）后自动失效并由服务端清理。每个物理 tick 最多消费一条有效动作，实际生效仍受武器冷却、剩余弹药及角色状态限制。
- **输入时钟平滑同步**：客户端根据 `STATE tick + RTT/2 + 2 tick 余量` 初始化输入时钟。服务端通过 STATE 报文回报最新收包的到达余量 `lead = target_tick - server_tick`。客户端通过小幅度动态调速（1.02 倍、1.00 倍、0.96 倍）平滑修正本地输入时钟，避免输入过快产生积压或过慢导致服务端饥饿。
- **步进分离与表现更新**：`ActorStep` 使用统一碰撞体为双端执行物理推进。首次预测步进执行动作产生射击反馈；预测重放期间仅推进游戏状态，不重复触发音效、动画与开火。重放完成后由 `Player.present_tick` 统一更新表现。

---

## 七、 客户端预测与平滑播放

- **预测回滚流程**：收到新的权威 STATE 时，暂存待应用的最新状态。在下一物理帧重置至权威状态，利用 `InputBuffer` 中未确认的输入快速重放至当前本地输入时钟，随后采集新输入。历史输入最多保留 64 条，单次最大重放 32 tick；历史缺失或超预算时直接采用权威状态。
- **视觉平滑校正**：角色物理节点始终位于实际预测位置。角色精灵与武器挂载于 `Visuals` 节点，网络校正产生的微小位置偏差在 50ms 内指数衰减平滑，消除网络抖动带来的画面跳跃感。开火起点 `shot_origin` 自动剔除该视觉偏移，保证弹道不受视觉平滑影响。
- **远端实体插值播放**：远端角色、子弹、掉落物与血条共用 100ms 播放缓冲，沿环形最短路径平滑插值。缓冲样本上限为 32 份；当网络严重落后超过 12 tick 时自动重定位追赶，断流超过 100ms 时自动冻结，防止实体在未知状态下无限外推。

调用流程图与队列设计详见 [架构参考文档](architecture_references.md)。

---

## 八、 EasyTier P2P 网络隧道与重连流程

- **应用层免驱动网络栈**：集成官方 EasyTier v2.7.0 内核（`--no-tun` 模式），直接在应用层转发 UDP 数据包，无需安装系统虚拟网卡驱动，无需管理员权限。优先利用 STUN 进行 NAT 打洞实现 P2P 直连，直连受限网络环境下自动由公网节点中继转发。
- **动态端口分配**：系统运行时向操作系统申请空闲动态端口（通过临时绑定端口 0 并读取实际端口号实现），规避了固定端口冲突风险。
- **断线重连宽限期**：玩家发生网络闪断后，服务端保留其席位、角色物理实体及背包数据 60 秒。客户端断线后自动执行重连循环，重建网络隧道并连接本地转发端口后，凭房间号与重连 Token 向服务端请求完整基线并完成世界同步。

---

## 九、 自动化测试验证

相关测试入口与规范请参阅 [测试体系说明](tests.md)。网络压测与多进程对战实测数据记录请参阅 [网络验证记录](network_validation.md)。
