# 联机系统

服务端以 60 Hz 运行权威模拟，基础 STATE 频率为 30 Hz。客户端预测本地角色，远端角色使用只读运动代理和独立的显示缓冲。伤害、拾取、地形、回合与胜负由服务端裁决。

## 模块与会话

| 模块 | 职责 |
|---|---|
| [RoomSession](../../server/room_session.gd) | 席位、连接、重连令牌、开局条件、60 秒断线宽限期 |
| [AuthorityWorld](../../server/authority_world.gd) | 权威角色、弹丸、掉落物、伤害与状态广播 |
| [InputBuffer](../../core/net/input_buffer.gd) | 输入去重、目标 tick 调度、动作确认与过期 |
| [NetBus](../../core/net/net_bus.gd) / [GnsEndpoint](../../native/gns/gns.cpp) | 连接、分 lane 传输、有限收包与派发 |
| [NetCodec](../../core/net/net_codec.gd) | 二进制协议、逐连接基线、公共编码复用 |
| [PredictionRollback](../../core/net/prediction_rollback.gd) | 本地输入时钟、历史比较、后缀重放 |
| [CombatPrediction](../../core/net/combat_prediction.gd) | 已知攻击的本地结果、确认与依赖检查 |
| [SnapshotBuffer](../../core/net/snapshot_buffer.gd) | 远端显示插值与有界外推 |

大厅与对局共用一个服务端进程和 GNS UDP 端口。加入、新回合和重连遵循 `BASELINE → 初始化场景及碰撞 → READY → STATE`。同回合重连保留地图节点并应用权威 HP。房间事件决定进入对局或返回大厅，START 不带载荷；人数及队伍条件见[对战模式](modes.md)。

## 通道、顺序与时效

NetBus 的协议前缀为 `[199, 4]`，NetCodec 使用小端字段。双方必须使用相同协议版本。

| 流 | lane | 传输 | 内容 |
|---|---:|---|---|
| INPUT | 0 | UnreliableNoNagle | 最新 4 帧持续输入、未确认动作、STATE ACK |
| STATE | 1 | UnreliableNoNagle | 世界快照、接收者 own、输入确认、时钟反馈、地形版本 |
| EVENT | 2 | ReliableNoNagle | 房间信令、基线、地形、回合、弹丸与战斗确认 |

同一可靠 lane 内保序，**不同 lane 没有接收顺序保证**。STATE 由快照序号拒绝旧帧。地形版本领先的 STATE 等待对应 TERRAIN；事件按 tick、身份和已应用权威覆盖范围判定是否仍有效。

NetBus 的事件屏障只控制本地待派发队列：连续 STATE 可以保留较新的消息；遇到 EVENT、连接边界或无效消息后，合并区间结束。它防止合并跨过已经收到的事件，不保证线上 EVENT 先于另一个 lane 的 STATE。可靠事件晚到时，消费者仍须检查权威覆盖和模拟影响。

原生接收每次最多处理 256 条、512 KiB 线上或解压字节，软时间预算为 2 ms。脚本派发另有 512 KiB / 2 ms 软预算，按完整消息保留剩余顺序；预算无法截断单条消息的解码或消费者。GNS 接收缓存每连接为 4 MiB / 1024 条，脚本批次每连接上限为 64 MiB / 1024 条；收到后排队超过 5 秒或批次越界时关闭连接，由重连恢复基线。

INPUT 与 STATE 各保留一条未提交消息，以新替旧；lane 空闲且预计排队不超过一个 60 Hz tick 时提交。压缩后的实时消息上限为 16 KiB。EVENT 按 128 KiB 分块，以 256 KiB 发送水位补充。应用消息采用有收益时才启用的 Zstd 压缩，EasyTier 使用 `--compression none`。公共事件一次编码、一次压缩，再经 `send_many` 发给接收者；BASELINE 和 STATE 的连接状态独立维护。

## 输入与时间

持续输入与单次动作分别携带 epoch、序号、目标 tick，并分别确认。持续输入只延续至原始目标 tick 后 6 tick；动作在 12 tick 后过期，每 tick 最多消费一条有效动作。迟到但仍有效的输入安排到下一 tick，年龄仍按原始目标判断。未来窗口上限为 32 tick。过期动作确认后丢弃，不能因重发而重新生效。

客户端以权威 tick、RTT 和 2 tick 余量初始化预测时钟，领先窗口上限为 32 tick；服务端回报带序号的到达余量。客户端通过 1.02、1.00、0.96 倍推进平滑调整，不改写已发送命令的目标 tick。移动、跳跃、攀爬、游泳和武器步进共用原生实现，角色顺序和阶段决定碰撞代理所处时间。

## STATE 编码与历史

每个连接独立维护快照序号、ACK 和最多 64 份历史。服务端相对接收者确认的快照发送差分；基线失效时发送全量。客户端缺少指定基线时丢弃差分，并以 ACK=0 请求全量。

STATE 分为角色、掉落物、own、时间账户和弹丸区块。变化记录按字段位图编码，实体创建和移除显式编码。一次广播捕获并隔离公共 world/time，各 peer 单独准备 own；公共差分按共同基线身份与角色表复用。不会为每个 peer 再完整比较 world/time，也不会先逐层比较整个对象再重复逐字段比较。

弹丸位置和行程作为持续变化字段直接写入；低频属性仍使用差分，增删和生命周期保留。解码器内部共享未变化的只读记录，修改时复制相应索引；返回给消费者的快照与 codec 历史隔离。调用方修改源数据或已返回快照不能污染历史。

TERRAIN 每 tick 合并子格最终 HP 和权威版本。客户端维护权威 HP 与未被覆盖的预测差分，提交脏碰撞后接纳版本一致的 STATE。地形所有权、恢复和缓存见[原生地形](native_terrain.md)。

## 预测、确认与表现

STATE 先与同 tick 历史及实际交互依赖比较，保留有效前缀，只重放失效后缀。网络触发的接纳在一个 process frame 内合并为一次；规则见[本地预测](local_prediction_design.md)和[历史复用](prediction_reuse.md)。

已知弹丸、光束、引信和爆炸预测本地受击；远端未知操作由权威信息补齐。HIT 使用攻击 ID、tick、目标及实际伤害/冲量确认结果，已被 STATE 覆盖的结果不重复施加。BULLET_REWIND 的恢复锚点严格早于已应用 STATE 时忽略；相等时仍按事件契约处理。显示也保留更新时间，较旧 STATE 不能覆盖较新的事件结果。

预测爆炸在模拟 tick 改变临时地形，后续查询前提交碰撞；表现按弹丸 ID 合并，一次性音画只在首次预测或首次权威到达时播放。重放仅恢复和推进模拟。远端角色与掉落物使用 100 ms（6 tick）播放缓冲，外推最多 6 tick；碰撞代理的 32 tick 恢复历史与显示外推是两个独立范围。本地 Visuals 偏移在约 50 ms 内衰减，不参与枪口或物理计算。

## EasyTier 与进程生命周期

官方 EasyTier nightly 通过 `--no-tun` 转发应用层 UDP。STUN 直连失败时经中继；禁用 P2P 是否走公网中继取决于实际路由和节点。`relay.txt` 配置 `txt://et2.lctn.cc.cd` 与 `udp://183.230.36.171:11010`。下载流程见[构建与工具](tools.md)。

本地服务与 UDP 转发以临时 socket 绑定端口 0 选择端口，再交给实际服务。Windows 的 [OwnedProcessGroup](../../native/process_group/process_group.cpp) 以 Job Object 持有会话子进程，关闭 Job 或客户端退出时回收。macOS 使用独立进程组和寿命管道，显式关闭也主动终止进程组。启动与关闭统一由 [NetSession](../../core/net/net_session.gd) 管理。

断线后保留席位、实体和背包 60 秒。单次 GNS 连接尝试最多 5 秒，失败后间隔 1 秒重试，总期限结束转为离线；成功后重新请求基线。

检查入口见[关键行为检查](tests.md)，统计口径见[性能观测](low_overhead_performance.md)，资料见[调研索引](architecture_references.md)。
