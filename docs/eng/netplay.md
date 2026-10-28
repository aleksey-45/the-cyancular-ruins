# 联机网络系统

本项目使用 Godot 4.7.1，通过 GDExtension 接入 GameNetworkingSockets v1.6.1（GNS），采用专用的二进制序列化协议与消息级 Zstd 压缩。服务端单进程管理房间会话与权威世界模拟；对局结束后无缝返回同一房间。1v1、3v3 及大乱斗等模式共用统一的客户端预测、服务端物理模拟与表现层管线。

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
| 角色移动、跳跃、攀爬、游泳与武器物理步进 | [ActorStep](../../core/sim/actor_step.gd) | 双端共用的固定步进与碰撞查询 |
| 角色之间的阻挡 | [ActorCollider](../../core/sim/actor_collider.gd) | 站立、蹲伏矩形的轴向阻挡与环面映射 |

- **通信与规则**：[NetBus](../../core/net/net_bus.gd) 负责调用 [GnsEndpoint](../../native/gns/gns.cpp) 管理 IP/UDP 连接、三条 lane 与消息派发；[NetCodec](../../core/net/net_codec.gd) 负责二进制高效编解码与增量快照缓存；[MatchRules](../../server/match_rules.gd) 负责对战模式计分、出生点分配、复活与回合流转。房间直接分发客户端报文。连接事件由 NetBus 的信号通知大厅与对战场景。
- **基线与状态同步**：加入对局、断线重连与新回合均遵循标准握手流程：`服务端下发完整 BASELINE → 客户端初始化场景与碰撞体 → 客户端上报 READY → 恢复定频 STATE 快照同步`。基线包含地图数据、当前子格生命值、所有存活实体以及玩家自身状态。
- **击退状态更新**：常规 STATE 为 30 Hz。显式击退命中造成伤害或改变冲量时，服务端在当前 tick 的地形与碰撞提交后发送完整 STATE：偶数 tick 使用常规更新，奇数 tick 仅补发给受影响玩家。同 tick 多次命中合并为一份，使用现有差量协议。
- **本地受击预测**：[CombatPrediction](../../core/net/combat_prediction.gd) 推进已知弹丸、引信、光束与爆炸，保留本地 HP、击退、倒地和动作许可预测。远端角色只提供权威运动代理，不执行远端武器或修改其 HP；显示走独立插值缓冲。服务端仍完整裁决所有角色的交互。设计和取舍见[本地预测域](local_prediction_design.md)。
- **命中确认**：44 字节的 `HIT` 携带稳定攻击 ID、命中 tick、来源、权威击退向量、命中后的 HP 与朝向。确认结果按对应阶段重放，与视觉弹丸是否存在无关；STATE 已覆盖的命中不再施加。榴弹已结算直接触碰的标记与引信状态一起恢复。迟到且确有影响的战斗事件在物理帧开始合批修复本地历史；远端输入提示不触发重放，新 STATE 同批到达时共用一次恢复。未知的远端瞬发开火、飞行时间短于开火信息传递时间的近距离弹丸，需要权威结果补齐。
- **爆炸预测**：榴弹引信启动时，服务端在地形提交后发送可靠 `BULLET_FUSE`，包含当前 tick 和弹丸状态。客户端保存该 tick 的检查点，逻辑弹丸在正常预测/重放中逐 tick 推进引信，不在收包回调中预演整条剩余轨迹。本地移动完成后，在对应 tick 只对本地角色应用预测受击；预测和重放共用范围、遮挡、水体、伤害与冲量算法。确认的爆点和受击结果用于后续重放。
- **爆炸表现**：已知引信的爆炸在预测 tick 播放，并结束仍在飞行的视觉弹丸。服务端结算后向全部客户端发送可靠 `EXPLOSION`，确认位置与 tick；表现按弹丸 ID 合并。只有首次预测产生动画和碎屑，重放只推进运动；尚未收到引信信息时由权威事件触发表现。单人模式由本地结算触发。
- **地图与房间生命周期**：首次基线和新回合重置地形；同回合重连复用现有地图与碰撞，只补齐权威子格生命值。`ROOM.in_match` 为真时更新房间信息；为假时返回大厅。
- **连接状态流转**：客户端状态依次经历 `LOADING`（加载中）、`ONLINE`（在线对战）、`RECONNECTING`（断线重连中）、`OFFLINE`（离线）。场景加载期间的地形与弹丸事件由大厅缓存，客户端初始化完毕后按序应用。

---

## 二、 进程管理与生命周期

Windows 客户端通过 [NetSession](../../core/net/net_session.gd) 持有一个 Windows Job 作业对象句柄。本地服务端、EasyTier 核心进程、CLI 工具及其派生的全部子进程均在创建时加入该作业对象（通过 [OwnedProcessGroup](../../native/process_group/process_group.cpp) 中的 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 实现），并配置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 标志。

本地服务端与 EasyTier UDP 转发共用 `NetBus.pick_free_port()`：探测 socket 绑定 `127.0.0.1:0`，读取系统分配的端口后关闭，再由实际服务绑定。本地客户端通过 `--port` 将选定端口传给服务端；服务端收到 `--port 0` 时自行选择端口。

- **安全退出保障**：作业对象句柄由客户端独占持有且禁止子进程继承。离开联机会话时调用 `NetSession.close()`，依次断开 GNS、关闭 Job 句柄并清空网络状态。无论是窗口正常关闭、崩溃退出还是被任务管理器强杀，Windows 操作系统都会自动回收作业对象句柄并强制终止所属的全部后台子进程，从根本上杜绝孤儿进程和端口残留。
- **Windows 兼容性**：扩展面向 64 位 Windows 10 及以上系统，接口依据 [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) 实现。
- **macOS 生命周期**：[macOS 扩展](../../native/process_group/process_group_macos.cpp) 使用 `posix_spawn` 将会话子进程加入独立进程组。显式关闭会先终止所属进程组，再关闭管道并回收子进程；客户端异常结束时由守护子进程在寿命管道 EOF 后终止进程组。写端设置 `FD_CLOEXEC`，但仍可能被其他 `fork` 出的守护进程继承，所以显式关闭不能只靠 EOF。联机组件统一经 `NetSession.launch()` 启动，嵌套会话各自持有自己的管道与进程组。CLI 输出按帧非阻塞读取。

macOS 发布版以同一 `.app` 的 `--headless -- --server` 入口运行本地服务端；EasyTier 位于应用包的 `Contents/Helpers/`，日志和中继列表位于用户数据目录。具体构建见[开发工具](tools.md)，测试入口见[进程生命周期验证](process_lifecycle_validation.md)。

---

## 三、 网络通信通道 (Channels)

公共事件通过 `broadcast_event` 一次编码，并由原生 `send_many` 一次压缩后向多个接收者发送，保持逐连接可靠队列的顺序和错误记录。BASELINE 的 codec 状态仍逐连接更新；STATE 的序号、ACK 和 own 仍独立。输入提示按角色编码一次，为各接收者拼成排除自身的完整冗余包。详见[广播与日志优化](server_fanout_optimization.md)。

接口通过 `send_input`、`send_state`、`send_event` 暴露。NetCodec 使用 `StreamPeerBuffer` 进行小端二进制读写。NetBus 在编码载荷前增加两字节协议标识 `[199, 3]`，接收端先检查版本，再读取载荷类型；不同版本不进入快照解码。客户端与服务端必须一起更新。以下类型和长度均指 NetCodec 载荷，不含这两字节及 GNS 的压缩、分片、加密开销。类型字节为 INPUT 的 `0`、STATE 的 `1` 或 EVENT 的 `2 + kind`；lane 编号分别为 0、1、2：

| 数据流 | 载荷类型字节 | GNS lane | 传输方式 | 内容 |
|---|---:|---:|---|---|
| **INPUT** | 0 | 0 | UnreliableNoNagle | 上行：最新 4 帧持续输入、未确认动作与 STATE ACK；下行：全角色有界冗余、各记录首次可用 tick |
| **STATE** | 1 | 1 | UnreliableNoNagle；由快照序号拒绝旧帧 | 服务端广播：玩家、掉落物及逻辑弹丸增量快照、接收者预测状态、移动/动作确认序号、时钟到达余量反馈、地图版本号 |
| **EVENT** | 2 + kind | 2 | ReliableNoNagle，同一 lane 内按序接收 | 关键事件：房间信令、完整基线、READY、地形、回合、弹丸出生、结束与 Beta 回溯、开火/受击与激光特效，以及分阶段的颗粒收益 |

- **输入数据包结构**：INPUT 包含控制阶段标识 `control_epoch`，每条持续输入显式携带序号，允许冗余集合中的序号不连续。记录还包含目标 tick、观察到的服务端 tick、移动轴向、持续按键与瞄准方向。包内第一帧完整写入，后续帧用字段位图省略相对前一帧未变化的值；每个 INPUT 包可独立解码。单次触发动作（跳跃、换弹、拾取等）单独携带序号、目标 tick、按键边沿与武器上下文，并通过 `action_ack` 独立确认。
- **远端输入转发**：RoomSession 保留每个角色最近 4 条持续输入和动作时效内的记录。收到上行输入后，在物理 tick 合批发送包含所有角色的完整提示集合，适配 INPUT 待发整包覆盖；不会在发送后清空其他角色的提示。每条记录保存服务器首次确定的 `available_tick`，重复转发不改变它；通常等于 `target_tick`，只用一字节标记，迟到时再携带完整值。STATE 提供各角色 ACK 与原始持续输入游标；当前客户端只保留该协议的收包入口，不用远端提示驱动本地预测或积累远端回滚队列。该设计参考 [DDNet 预输入转发](https://github.com/ddnet/ddnet/blob/master/src/engine/server/server.cpp#L1833)。
- **本地后缀重放**：重建本地 ACK 后的有效命令，并复核实际轴向阻挡、起身重叠、弹丸点/线段接触及射手回溯状态，包含原先为空的查询。远端完整状态差异不直接否决本地历史；首个实际依赖变化才使后缀失效。历史不足、地形或弹丸锚点不一致时仍保守恢复，但不重演七名对手的完整玩法。
- **输入积压边界**：远端收包只向运行中的队列提交新增提示，持续提示最多保留 128 条，动作提示最多 48 条；恢复时重建队列，迟到差异判定只在临时调度器中重建命令后缀，不运行物理。淘汰时优先移除预测窗口以外的提示；窗口内输入溢出则记录缺失序号，冻结预测和迟到事件重放，等待权威 ACK 覆盖或新 epoch。`target_tick` 与 `available_tick` 都受未来 32 tick 窗口约束。NetBus 只合并同屏障内 STATE，保留最大序号；INPUT 全部解码后按记录去重，可靠消息保序派发。
- **战斗结果重放**：已预测区间的新攻击或命中确认同样在物理更新开始触发整组重放，`trigger=event`。三种触发源共用一次合批和完整恢复入口。已确认命中按阶段、攻击 ID 和 tick 应用，即使本地弹丸已结束也会重放；已确认爆点保持服务端的位置与 tick。
- **弹丸结束**：普通弹丸撞墙、命中或到达射程后，服务端在同 tick 合批发送可靠 `BULLET_END`。消息为 1 字节类型、4 字节 tick、2 字节数量与每项 8 字节 ID，共 `7 + 8N` 字节。预测保留结束 tick，在重放中终止对应弹丸，权威 STATE 覆盖该 tick 后释放记录。客户端收到消息时结束可见副本。
- **弹丸数量约束**：多人模式按角色及武器类型统计存活弹丸。服务端读取权威实体，预测读取当前模拟 tick 的逻辑弹丸；未来出生和已结束的弹丸不占用当前名额。开火、弹药和后坐力共用这一判定。
- **战斗状态预测**：已知攻击使用共享武器配置和命中函数推进击退、HP、倒地旋转与碰撞，随后 STATE 恢复并重新模拟。HIT 按攻击 ID、tick、命中阶段与受击者匹配，携带权威 HP、冲量与死亡朝向，覆盖该受击者的结果。爆炸与光束命中多人时，各目标独立确认，尚未确认的目标继续预测；计分、拾取、地形及最终伤害结果由服务端决定。
- **动作可用时间**：持续输入和单次动作最早从 `max(target_tick, receipt_tick + 1)` 开始使用；重复记录保留最早接收时间。动作过期与持续按键延续仍根据原始 `target_tick` 判断。
- **时钟反馈**：新反馈只更新到达余量的平滑值，通过 1.02/0.96 倍速连续调整后续推进。已发送输入、动作的目标 tick 保持不变。时钟越出预测窗口时根据最新权威状态重建；参考 [DDNet 平滑时钟](https://github.com/ddnet/ddnet/blob/master/src/engine/client/smooth_time.cpp)。
- **实体索引与命中判定**：动态实体使用自增整数 ID 标识。子弹投射物编号结合了玩家 ID、开火序号与弹丸序号，便于本地预测与权威快照精确对齐合并。伤害结算、弹药扣除、掉落物拾取与地形破坏均由服务端权威计算。

### NetBus 的事件屏障

`NetBus._coalesce_messages()` 在派发前压缩收到的消息批次：同一合并区间内，每个 peer 的 STATE 只保留快照序号最大的一条。收到 EVENT 或连接通知时，清空可替换 STATE 的索引，结束当前区间；无法识别的包也按屏障处理。屏障之前保留的消息仍留在原位置，后续 STATE 从新区间开始合并。INPUT 不结束区间，所有 INPUT 都保留到解码后按记录去重。

例如，下面的数字是快照序号：

```text
收到：STATE#10, STATE#11, TERRAIN, STATE#12, STATE#13
派发：STATE#11,           TERRAIN,           STATE#13
```

这样，TERRAIN 前后的 STATE 各自合并，事件回调仍在两段消息之间执行。它保留本地接收顺序，避免批次优化跨过可能改变地形、基线或生命周期的回调；屏障本身不等待其他消息。

GNS 不保证跨 lane 的接收顺序，因此这个屏障也不能恢复发送顺序。如果 STATE 先于它依赖的 TERRAIN 到达，仍由 `map_revision` 暂存等待；基线初始化由 BASELINE/READY 握手协调。详见 [GNS lane 顺序语义](https://github.com/ValveSoftware/GameNetworkingSockets/blob/v1.6.1/include/steam/isteamnetworkingsockets.h)。

---

## 四、 状态快照与增量同步 (Delta Compression)

STATE 报文头包含消息类型、当前快照序号、基准快照序号、服务端世界 tick 与地图版本号 `map_revision`，共计 17 字节。快照序号按连接独立递增；基准序号为 0 时表示不依赖历史的独立全量快照。

- **差量编码机制**：报文头后使用 1 字节位图标识角色、拾取物、本机预测状态、Beta 时间账户及逻辑弹丸五个区块是否变化；未变化区块从已确认基线恢复。只有 tick 推进的快照载荷仍为 18 字节。全量快照提供角色顺序表，角色区块通过位图记录存在与变化状态，每个变化角色再以字段位图省略未变化的值。掉落物使用 4 字节 ID，弹丸使用 8 字节 ID，各自编码创建、变化与移除。
- **预测状态与时间账户**：输入确认、调度反馈、最后采用的输入、角色物理状态、计时器、背包、手持武器以及 Beta 时间账户均按固定字段表编码变化位图。接收端先恢复完整权威状态，再交给预测与表现层。切换武器实例时完整写入新武器状态；空背包、移除的实体及时间账户显式编码。
- **双端基线确认机制**：双端各自维护最多 64 份解码快照历史缓存。客户端成功解码快照后更新 ACK 并上报，服务端始终以客户端最新确认的快照作为基准进行差量压缩。若服务端历史基线已过期，则自动下发全量快照；若客户端缺失指定基线，则丢弃该差量并在下次 INPUT 中发送 `ACK=0` 请求新的全量快照。
- **广播编码复用**：同一次广播按公共世界和各接收者基线复用角色、掉落物、账户与弹丸编码，接收者的 `own`、序列号和 ACK 仍独立生成。历史公共状态仅从调用方深拷贝一次后只读，后续修改源字典不影响已有快照。
- **地图版本同步**：每次权威子格 HP 变化递增 `map_revision`。服务端每 tick 通过一条可靠 TERRAIN 发送 tick、变更子格的最终 HP 和最终版本号。客户端在物理帧按块更新碰撞，随后应用版本一致的权威状态；未来版本 STATE 暂存，等待地形追上后用于本地预测和远端播放。
- **爆炸碰撞地形预测**：已知爆炸在相同模拟 tick 使用共享伤害公式临时更新子格 HP 与碰撞。客户端保存原 HP，重放和清理时恢复。权威 TERRAIN 覆盖临时结果，并按 tick 保留尚未被覆盖的未来爆炸；`map_revision` 始终表示权威地形版本。表现读取当前预测结果，最终地形由服务端确认。
- **远端回溯阻挡**：`rewind_path` 描述已开始回溯的角色在未来最多 32 tick 的历史位置与碰撞姿态，仅发送变化结点。客户端在角色阶段结束后更新阻挡体并扣除回溯消耗；中途停止由新 STATE/epoch 确认。该字段不进入表现插值缓冲，不替代服务端回溯战斗历史。
- **地形查询复用**：联机预测器按完整参数缓存相同静态地形运动查询，每角色最多 256 条。角色矩形阻挡仍逐次计算；地形碰撞节点重建后缓存全部失效。预测历史只读共享未变化的背包，普通状态捕获仍保留独立副本。

设计参考了 [Quake III 消息编码机制](https://github.com/id-Software/Quake-III-Arena/blob/master/code/qcommon/msg.c) 与 [Snapshot Compression 增量压缩协议](https://gafferongames.com/post/snapshot_compression/)。

---

## 五、 GNS 传输与 Zstd 压缩

[GnsEndpoint](../../native/gns/gns.cpp) 使用 `CreateListenSocketIP` / `ConnectByIPAddress` 建立普通 UDP 连接；官方 EasyTier 提供直连与中继路径。Windows 和 macOS 均使用同一游戏程序，建房时从当前程序启动 `--headless -- --server --port <端口>` 子进程。

服务端需要明确的非零监听端口。传入端口 0 时先用临时 UDP socket 获取空闲端口，关闭后交给 GNS；客户端的临时源端口由 GNS 内部选择。

每条连接配置三条同优先级、同权重 lane，发送速率固定为 64 KiB/s。GNS 内部线程负责 UDP 收发、加密、分片、确认和可靠重传。NetBus 以物理处理优先级 -1000 在每个 60 Hz tick 开始时派发回调与消息，随后执行权威模拟或本地预测。

INPUT 和 STATE 各保留一条待发消息，新消息替换尚未提交的旧消息。对应 lane 没有待发字节且预计排队不超过一个 60 Hz tick 时，才向 GNS 提交。压缩后的实时消息最多 16 KiB。EVENT 使用可靠 lane；消息按 128 KiB 分块，发送队列按 256 KiB 水位补充，接收端完整组装后派发。

原生接收每次最多处理 256 条、512 KiB 线上或解压字节，软时间预算为 2 ms；预取未处理的消息保持引用，关闭时释放。NetBus 派发另有 512 KiB/2 ms 软预算，保留完整消息和剩余顺序。每帧最多补取 `256 - 待派发数量` 条消息，先合并新旧 STATE，再继续派发；批次已满时仍运行连接回调和发送重试。预算在完整消息之间检查，不能限制单次大消息解压、解码或业务回调的耗时。

GNS 接收缓存每连接为 4 MiB/1024 条；脚本待派发批次每连接最多 64 MiB/1024 条。收到后排队超过 5 秒，或脚本批次越界时，记录 `receive_backlog_reset` 并关闭该连接；客户端随后通过现有重连流程重新获取控制 epoch 和基线。可靠分片检查总长度一致且不超过声明容量。

单次发送只检查并刷新目标连接，统一 `poll` 再重试所有待发连接；连接状态和 lane 状态通过同一次查询取得，避免向 N 名玩家广播时重复扫描整组连接。

每条应用消息在加密前通过 Godot 的 Zstd 压缩，压缩结果较小时采用压缩体。外层 4 字节小端长度记录解压大小，0 表示原始字节。可靠分块另带 4 字节消息总长。EasyTier 设置 `--compression none`。

接口语义见 [GNS 官方头文件](https://github.com/ValveSoftware/GameNetworkingSockets/blob/v1.6.1/include/steam/isteamnetworkingsockets.h)。固定版本的带宽估计状态见 [官方 issue 108](https://github.com/ValveSoftware/GameNetworkingSockets/issues/108)。

---

## 六、 输入调度与物理模拟

- **时序调度**：服务端以 60Hz 执行物理世界模拟，以 30Hz 向客户端发送 STATE 快照。`InputBuffer` 按 `target_tick` 组织未来输入；若收到迟到输入，则顺延至下一 tick 执行。未来调度窗口最大为 32 tick；服务端的持续移动轴和按键只延续至原始 `target_tick + 6`，随后归零并保持瞄准方向。权威恢复按 STATE tick 判断已知时效，远端提示按服务端首次 `available_tick` 判断；明确已过期的输入先清零，恢复游标和重复转发都不会重新激活按键。远端尚未获知的未来输入仍延续最后有效值，允许正常的预测猜测。
- **动作确认与时效性**：跳跃、切枪、换弹、拾取与丢弃等属于单次触发动作。未确认的动作会随后续 INPUT 报文持续冗余重发，超出目标时间 12 tick（200ms）后自动失效并由服务端清理。每个物理 tick 最多消费一条有效动作，实际生效仍受武器冷却、剩余弹药及角色状态限制。
- **输入时钟平滑同步**：客户端按 `STATE tick + min(ceil(RTT_ms × 60 / 1000) + 2, 32)` 初始化输入时钟，覆盖快照下行和输入上行时间。服务端通过 STATE 报文回报最新收包的到达余量 `lead = target_tick - server_tick`。客户端通过小幅度动态调速（1.02 倍、1.00 倍、0.96 倍）连续修正后续推进，输入与动作的目标 tick 保持不变。预测窗口为最新权威 tick 的未来 32 tick。
- **步进分离与表现更新**：服务端角色由 `AuthorityWorld` 每 tick 统一调用一次 `ActorStep`。服务端、本地预测与远端运动体调用 `Player.enable_manual_simulation`，关闭自动物理回调，使用即时位姿的原生静态查询体。每次共享步进开始时提交变换，再通过 `move_and_collide` 查询地形，角色间使用逻辑矩形轴向阻挡。首次预测执行动作产生射击反馈；重放仅推进游戏状态，完成后由 `Player.present_tick` 更新表现。

---

## 七、 客户端预测与平滑播放

- **预测回滚流程**：物理 tick 开始时应用暂存的最新 STATE。对应历史 tick 的整组角色玩法状态、弹丸、账户与地形必须严格一致，再从权威游标重建命令：整个后缀等价则保留结果；后部命令变化则保留此前已验证的前缀，从检查点重放变化部分。动画 Pose `state` 和姿态停留计时 `slock` 仍保存在完整快照和检查点中，但不参与玩法复用资格；复用时保留本地预测动画，远端显示继续使用独立的权威插值缓冲。碰撞姿态、朝向及武器字段仍严格比较。前缀不越过新的可靠事件或不同的远端回溯轨迹，且不得存在临时预测地形。ACK 或序号变化本身不触发物理重算；复用时同时更新命令历史和游标。锚点不同或检查点无法恢复时，恢复整组权威锚点并重放，随后采集新输入。角色、弹丸和账户保持同一时间线。逐 tick 玩法历史最多保留 64 条，单次最大重放 32 tick，历史缺失时走权威恢复。`reuse_counts` 与 `reuse_totals` 记录首个拒绝条件、复用量和部分复用后的重放量。
- **预测表现历史**：只有真实预测步调用 `begin_visual_step` 记录插值起点。权威重放完成后按此前真实预测帧的位移重新对齐插值区间；重放中的历史移动只更新模拟状态。
- **接地上下文**：`ActorStep` 保存并恢复 `_grounded`，通过本 tick 的 X/Y 运动查询更新地面接触；站在地面上时将贴地距离纳入向下查询。
- **角色生命周期**：倒地旋转碰撞体时清除接地状态。单人重新开始与服务端复活共用 `Player.reset_motion`，恢复站立形状，清除速度、击退、攀爬、游泳、跳跃、冲刺和姿态锁。
- **复活时刻**：对战规则用绝对 `respawn_tick` 安排死亡后 120 tick 的复活，在该 tick 所有角色移动结束后执行。STATE 同步此时刻；预测从下一 tick 起结束旧尸体的阻挡，新的权威状态恢复复活角色的实际位置和碰撞。回合冻结时对外报告的复活时刻为 0。
- **Beta 加速预测**：所有角色共用同一个 `TimeEconomy`，按角色阶段消费，完成全部角色后统一回复一次。已知伤害、击杀和子格破坏收益以可靠 `TIME_REWARD` 携带 tick、阶段、序号、角色及实际入账额；同 tick/阶段/角色合批。角色阶段收益在对应光束阶段后重放，弹丸收益在弹丸阶段后，规则收益在 tick 末尾应用。STATE 已覆盖的收益不再入账；未知收益等待权威事件，不额外猜测。
- **断流预测窗口**：本地模拟和输入目标 tick 均最多超前最新权威 STATE 32 tick；达到边界后冻结预测位置，输入继续上报。待发动作按输入序号保留有限窗口，本地模拟队列仅在步进时接收输入。新 STATE 到达后恢复预测，失去时基时重新对齐时钟。
- **武器状态恢复**：手持武器同时按背包实例 ID 和类型恢复，实际武器节点与权威背包保持一致。拾取替换和复活保留武器先保存旧弹药、卸下旧武器，再更新背包并装备；恢复快照时，旧武器弹药写回发生在装入权威背包之前。
- **视觉平滑校正**：角色物理节点始终位于实际预测位置。角色精灵与武器挂载于 `Visuals` 节点，网络校正产生的微小位置偏差在 50ms 内线性衰减平滑。开火起点 `shot_origin` 自动剔除该视觉偏移，保证弹道不受视觉平滑影响。
- **远端实体插值播放**：远端角色、掉落物与血条共用 100ms 播放缓冲，沿环形最短路径平滑插值。缓冲样本上限为 32 份；当网络严重落后超过 12 tick 时自动重定位追赶，断流超过 100ms 时自动冻结，防止实体在未知状态下无限外推。
- **角色碰撞**：单人、服务端和客户端预测共用站立、蹲伏矩形定义。走路和击退合为一次 X/Y 轴向运动，地形通过 Godot 查询，角色通过逻辑矩形阻挡。每 tick 按角色 ID 递增推进，ID 较小的对手已经移动，ID 较大的对手保持本 tick 起始状态。矩形映射到当前角色最近的环面副本，按阵营筛选。
- **远端运动预测**：STATE 包含运动状态、原始持续输入与 `driver`（背包、武器冷却/蓄力/换弹、射击序号、氧气计时及下一步控制锁）。隐藏运动体复用完整 `ActorStep.step`，保留影响移动的切枪、反冲和武器倍率；仅收集逻辑攻击，不执行远端音画动作。未知未来帧延续最后有效输入；已被权威锚点或首次可用 tick 明确判定过期的游标保持中立，直到收到新的有效输入。单次动作按 ACK 去重。历史记录保存实际消费命令及每 tick 的调度游标，包含过期归零和动作边沿；复用校验使用相同的权威恢复与提示调度规则。逻辑体保持权威规范坐标，最近环面阻挡副本由 `ActorCollider` 计算；视觉节点使用独立的 100ms 播放缓冲。每次恢复或推进前准备有序碰撞列表，整段重放复用。
- **弹丸本地模拟**：视觉弹丸仍由出生事件合并并独立播放。持续 STATE 新增逻辑弹丸的位置、速度、飞行距离、引信与直接命中标记，供对应 tick 直接恢复。`BULLET_SPAWN` 和 `BULLET_FUSE` 补充锚点之后的出生与检查点；同类型、同 ID 的节点可在重放窗口中复用，类型改变时重建。出生确认与仍有效的预测出生时刻及全部弹丸模拟字段一致时，只更新确认标记和检查点，不申请重放；不同时从较早的出生时刻失效，已被 STATE 覆盖的部分不再重算。出生身份和当前恢复锚点分别保留，结束或拒绝的节点不参与接触，超出窗口后释放。播放器只保存角色和掉落物表现数据，不复制这些弹丸锚点与驱动状态。
- **并发弹丸顺序**：服务端与预测均按攻击 ID 推进弹丸并立即应用该次爆炸；爆炸后的姿态和 LOS 影响后续弹丸。全部弹丸运动后再结算直接触碰，地形碰撞统一在 tick 末提交。榴弹移动前的点接触共用目标过滤，等距直接命中以角色 ID 决定顺序。
- **弹丸基线与 Beta**：加入、重连和换回合的基线包含存活弹丸的位置、速度、已飞行距离与引信进度。Beta 回溯期间，服务端以 20Hz 通过 `BULLET_REWIND` 同步该角色仍存活的弹丸；客户端暂停其本地物理，退出时按最后状态恢复模拟。STATE 在回溯期间及恢复飞行时同步显示弹丸，结束事件尚未到达时也能恢复飞行；普通飞行继续本地推进。
- **回溯事件与 STATE 的先后**：`BULLET_REWIND.tick` 是弹丸恢复锚点，等于服务端生成事件时的 tick 减 1。事件锚点严格早于已应用 STATE 时，客户端直接忽略它，不再删除、重建预测弹丸或改写显示。锚点与 STATE tick 相等的事件仍有效。显示层按角色记录实际服务器 tick（事件锚点加 1，或 STATE tick）；较旧 STATE 不覆盖更新事件。该机制保留历史复用，基线及场景重置时清空显示时间戳。

调用流程图与队列设计详见 [架构参考文档](architecture_references.md)。

---

## 八、 EasyTier P2P 网络隧道与重连流程

- **应用层免驱动网络栈**：集成官方 EasyTier v2.7.0 内核（`--no-tun` 模式），直接在应用层转发 UDP 数据包，无需安装系统虚拟网卡驱动，无需管理员权限。优先利用 STUN 进行 NAT 打洞实现 P2P 直连，直连受限网络环境下自动由公网节点中继转发。
- **动态端口分配**：系统运行时向操作系统申请空闲动态端口（通过临时绑定端口 0 并读取实际端口号实现），规避了固定端口冲突风险。
- **断线重连宽限期**：玩家发生网络闪断后，服务端保留其席位、角色物理实体及背包数据 60 秒。客户端断线后自动执行重连循环，重建网络隧道并连接本地转发端口后，凭房间号与重连 Token 向服务端请求完整基线并完成世界同步。
- **重连调度**：单次 GNS 连接尝试最多 5 秒；连接成功后在 60 秒总期限内等待完整基线。连接失败后间隔 1 秒重试，总期限结束时关闭 GNS 并进入离线状态。

---

## 九、 自动化测试验证

相关测试入口与规范请参阅 [测试体系说明](tests.md)。v2 的八人中继对照、公网失败及积压修复，以及 v3 的回溯阻挡和查询复用结果，见[联机改造实测记录](netcode_test_results.md)。网络压测与多进程对战实测数据记录另见 [GNS 验证记录](gns_validation.md)、[爆炸与预测验证](explosion_prediction_validation.md)、[角色校正与碰撞验证](correction_validation.md)、[前期爆炸击退验证](explosion_knockback_validation.md)和[爆炸推力预测验证](blast_prediction_validation.md)。

---

## 十、运行日志

日志默认开启。Windows 写入游戏目录下的 `log/`；macOS 写入 Godot 用户数据目录下的 `log/`。游戏目录不可写时回退到 `user://logs/`。每次运行生成 `client-<时间>-<PID>.log` 或 `server-<时间>-<PID>.log`，各文件独立保留。测试可通过 `-- --game-log-dir <绝对路径>` 指定目录。

游戏日志采用 JSON Lines，每行一条记录。`time` 是带毫秒的 UTC 时间，`uptime_ms` 是进程单调时钟，`pid`、`role` 标识进程，`event`、`data` 表示事件与字段。记录时生成 JSON 字符串并入队，由一个常驻后台线程批量写入和刷新文件。普通记录每秒唤醒写入线程，错误和警告立即唤醒；写盘期间释放队列锁。正常退出和切换日志文件时等待队列写完并关闭线程。`session_start` 包含构建、Godot、系统、架构、渲染后端与实际日志路径，正常退出记录 `session_end`。

`session_end` 表示该进程已执行退出回调。服务端或 EasyTier 被会话进程组终止时，结合宿主的 `session_close`、`process_stop` 记录判断退出流程。

文件写入通过 Mutex 串行化，引擎工作线程的输出可与主线程同时记录。发布版开启 GDScript 调用栈跟踪，错误记录保留可用的脚本堆栈。

| 记录 | 内容 |
|---|---|
| `performance` | 每秒实际帧间隔最大值、帧数、最近一帧处理与物理耗时、内存、场景、暂停、窗口焦点、低 CPU 模式、日志记录与刷新最大耗时 |
| `long_frame` | 逐次记录超过 50 ms 的实际帧间隔，以及处理、物理、焦点、暂停与场景信息 |
| `client_slow_tick`、`client_slow_present`、`world_slow_tick`、`transport_slow_dispatch` | 超过一个物理 tick 预算的处理，记录权威恢复、预测、表现、GNS 轮询与消息派发的耗时；`rollback` 分列角色恢复、弹丸准备和角色重放 |
| `window_focus` | 窗口获得或失去焦点的时间点 |
| `level_load`、`level_ready`、`terrain_painted`、`terrain_collision_ready` | 地图、铺图和碰撞初始化耗时 |
| `terrain_patch`、`terrain_prediction` | 权威更新的 tick、版本及子格最终 HP；预测爆炸 ID、tick、所依赖权威版本及修改子格数量 |
| `projectile_end` | 普通弹丸结束的绝对 tick 与合批 ID |
| `connect`、`listen`、`peer_*`、`server_*`、`transport_stop`、`send_error` | 连接生命周期、目标地址、端口和发送错误 |
| `transport_sample` | 每秒各数据流的消息数和序列化字节数、GNS 收发速率、RTT、lane 排队、实时消息替换、可靠待发量、STATE 收包与处理间隔、收包后派发等待、轮询间隔和解码统计 |
| `client_state`、`prediction_correction` | 输入序号、ACK、epoch、历史与动作数量、到达余量、预测时钟、校正幅度、地形版本和实体状态；`before_map_revision` 为校正前预测所用权威地形版本；≥32px 样本还包含上次权威状态、前后全体角色运动状态及未确认输入和动作 |
| `state_gap`、`playback_hold` | 超过 100ms 的 STATE 处理间隔，附 GNS 收包间隔、派发等待和轮询间隔；播放达到外推上限和恢复的时间点 |
| `baseline_*`、`player_ready`、`reconnect_*`、`seat_*` | 基线收发、初始化耗时、READY、席位宽限与重连 |
| `match_start`、`round_state`、`combat`、`respawn`、`pickup`、`drop`、`control_epoch` | 权威对局、回合、射击、伤害、击杀、拾取、丢弃与控制阶段变化 |
| `input_action`、`player_fire`、`player_damage`、`singleplayer_state` | 单次输入动作、本地预测射击、角色受伤及每秒单人状态 |
| `input_arrival` | 服务端收到输入状态切换时的 tick、目标 tick、余量和四帧冗余记录 |
| `beta_rewind_*`、`time_mode` | Beta 回溯起止、单人时间模式切换 |
| `explosive_spawn`、`explosive_removed`、`explosion` | 爆炸弹丸的 ID、位置、移除以及实际爆炸逻辑和特效是否执行 |
| `projectile_fuse`、`explosion_plan`、`explosion_prediction`、`explosion_confirmed` | 引信种子、预报爆点与耗时、首次预测推力、权威结果确认 |
| `impact_state` | 发生显式击退的 tick、角色、地图版本及是否补发状态 |
| `world_state` | 每秒权威 tick 数、最大 tick 耗时、各玩家输入队列峰值、缺输入与动作过期累计计数、背包及实体状态 |
| `engine`、`engine_error` | 引擎输出、错误类型、代码位置与脚本堆栈 |

武器状态同时记录背包条目、当前实例、声明类型、实际武器节点类型、场景路径和弹药。弹丸以稳定实体 ID 关联客户端、服务端与射击序号。JSON 中的 Godot 向量使用字符串表示。

`application` 是压缩前应用消息的计数和字节数，包含提交失败和被更新消息替换的发送尝试；`send_errors` 单列。接收侧 `rx_input/state` 仅统计实际派发包，省略的 STATE 计入 `rx_coalesced_state`；INPUT 不按整包省略。`transport_slow_dispatch.native_messages` 记录本次原生返回条数，`messages` 为实际派发条数，`pending_messages` 为延后批次大小。`transport_sample.receive_budget` 包含原生处理条数、线上/解压字节、预算触发次数、预取待处理条数、最长轮询与排队时间；`dispatch_budget_hits`、`pending_max` 记录脚本预算和批次峰值。`codec` 从连接建立开始累计：`full`、`delta` 为成功解码次数，`missing_base` 为缺少增量基线，`stale` 为旧序号，`serial_skips` 为序号跳跃；主动合并也会产生序号跳跃，不能据此推算物理丢包。

每个 peer 的 `tx_bytes_s`、`rx_bytes_s`、`tx_packets_s`、`rx_packets_s` 为 GNS 估计速率，不能累加当作精确累计流量。`quality_local/remote` 为 GNS 连接质量估计。lane 的 `pending_unreliable`、`pending_reliable`、`unacked_reliable` 使用字节，`queue_us` 使用微秒。`replaced_input/state` 是被新消息替换的待发数；`pending_event_bytes` 是扩展中尚未提交给 GNS 的可靠消息字节数。测试中的精确 UDP 长度和包数由转发器记录。

`correction_max_px` 是重放后与原预测位置之间的环面最短距离，`replay_max_ticks` 是采样区间内单次最大重放量。`counts.reconciles` 记录权威对账次数；`correction_checks` 及 `corrections_8px`、`corrections_32px`、`corrections_128px` 在每次对账时计数，每秒汇总，排除 epoch 变更和 Beta 回溯。≥32 px 的详细校正逐次记录，8–31 px 样本每秒最多一条。`counts` 同时记录各类重置原因，`input_totals` 是角色生命期内的迟到、延续输入、归零输入及动作过期累计数。`explosion.duration_ms` 记录单次爆炸处理耗时。

扩展把 GNS `m_usecTimeReceived` 转换到 Godot 单调时钟，随本机消息传给 `NetBus`。`state_receive_gap_max_ms` 记录 GNS 收包间隔，`state_gap_max_ms` 记录游戏线程处理间隔，`receive_queue_max_ms` 记录收包后等待派发，`poll_gap_max_ms` 记录主线程轮询间隔。BASELINE 派发前读取新连接 RTT，随后恢复预测时钟。收包间隔还受 GNS 工作线程和发送端调度影响；结合 `performance`、基线和服务端 tick 耗时判断，详见[校正与卡顿归因验证](replay_causality_validation.md)。

客户端的 `input_ack` 与 `action_ack` 分别记录权威移动输入确认与单次动作确认。`counts.state_callbacks` 包含基线以及地形追赶时重新提交的状态，实际 STATE 消息数读取 `application.rx_state.messages`。

EasyTier 启动参数固定包含 `--file-log-level info --file-log-dir <目录>`，目录为 `log/easytier/<游戏会话>-<host或guest>-<RPC端口>/`。文件由官方内核写入，采用官方默认轮转设置。游戏每 5 秒读取一次官方 CLI 的 peer 信息，写入 `tunnel_peers`，包含直连或中继路径、隧道协议、延迟、丢包估计和累计流量。隧道与 GNS 端到端统计分别记录。

`RUST_LOG` 按官方规则覆盖日志过滤级别，其值记录在 `tunnel_logging`。需要完整 info 记录时，启动游戏前清除该变量或设置为 `info`。配置语义见 [EasyTier 官方日志说明](https://easytier.cn/en/guide/network/configurations.html)与 [v2.7.0 日志选项](https://github.com/EasyTier/EasyTier/blob/v2.7.0/easytier/src/core.rs)。

复现联机问题后，保存双方客户端与实际房主服务端对应的日志文件，以及各自的 `easytier/` 子目录。`time` 用于跨设备初步对齐，精确关联使用 tick、epoch、输入序号和实体 ID。游戏结构化记录不写重连 token、邀请码或地图原始字节；EasyTier 原生日志包含网络地址和诊断信息，分享前检查内容。
