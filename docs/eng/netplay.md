# 联机系统

Godot 4.7.1 原生 ENet 使用固定二进制协议和 Zstd 包级压缩。每个房主进程管理一个房间和一个权威世界；对局结束回到同一房间。1v1、3v3、大乱斗共用客户端、模拟和表现代码。

## 状态所有权与生命周期

| 状态 | 持有者 |
|---|---|
| peer、席位、token、60 秒断线期限、READY | [RoomSession](../../server/room_session.gd) |
| 角色、弹丸、拾取物与权威战斗 | [AuthorityWorld](../../server/authority_world.gd) |
| 输入调度、epoch、移动与动作 ACK | [InputBuffer](../../core/net/input_buffer.gd) |
| 本地输入时钟、重发记录和预测历史 | [PredictionRollback](../../core/net/prediction_rollback.gd) |
| 远端实体共同播放时间 | [SnapshotBuffer](../../core/net/snapshot_buffer.gd) |
| 本地角色与武器的视觉校正 | Player.Visuals |
| 移动、跳跃、攀爬、水中移动和武器步进 | [ActorStep](../../core/sim/actor_step.gd) |

[NetBus](../../core/net/net_bus.gd) 创建 ENet、发送三条数据流并派发消息。[NetCodec](../../core/net/net_codec.gd) 负责二进制编解码和每连接的差量缓存。[MatchRules](../../server/match_rules.gd) 处理模式计分、出生点、复活和回合。SceneMultiplayer 的 server_relay 关闭，客户端消息由房间直接分发。

加入、重连和换回合共用 BASELINE → 初始化场景与碰撞 → READY → STATE 流程。基线包含地图字节、当前子格生命值、完整动态实体和自身状态。READY 携带回合号；换回合重建地图和拾取物，并重置各席位的 ready。

客户端连接阶段为 LOADING、ONLINE、RECONNECTING、OFFLINE。回合界面读取最近的权威 NetEvent.RoundState。场景加载期间的地形事件由大厅暂存，客户端初始化后接管。

## 进程所有权

[NetSession](../../core/net/net_session.gd) 持有一个 Windows Job。服务端、EasyTier 内核、CLI 及后代进程都属于该 Job。[OwnedProcessGroup](../../native/process_group/process_group.cpp) 通过 PROC_THREAD_ATTRIBUTE_JOB_LIST 在创建时加入 Job，并启用 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE。Job 句柄由客户端独占且不继承。

离开会话调用 NetSession.close()，依次断开 ENet、关闭 Job、清空 Tunnel 和 LocalServer 状态。窗口关闭与正常 quit 由 Autoload 的退出回调关闭句柄；客户端异常终止时 Windows 回收句柄，Job 随之终止子进程。大厅切换对局场景保留会话，重新进入联机创建新的 Job。组件重启可单独停止该组件。

CLI 管道按帧非阻塞读取，单次等待上限五秒；关闭会话取消等待，只处理当前会话的启动结果。Job 终止直接结束子进程，子进程退出回调不会运行。日志追加保存；EasyTier 配置写入系统临时目录，以本次 RPC 端口命名。

扩展面向 Windows 10 及以上 x64。接口依据 [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)，构建见 [开发工具](tools.md)，实测见 [进程生命周期验证](process_lifecycle_validation.md)。

## 三条数据流

接口为 send_input、send_state、send_event，内部使用 SceneMultiplayer.send_bytes 与 peer_packet。StreamPeerBuffer 按固定顺序写入小端字节；首字节是 flow，EVENT 随后写 kind。内部模拟与表现使用 Dictionary。

| 数据流 | flow | 通道 | 模式 | 内容 |
|---|---:|---:|---|---|
| INPUT | 0 | 1 | unreliable | 最新四条持续输入、未确认动作、快照 ACK |
| STATE | 1 | 2 | unreliable_ordered | 世界差量、自身预测状态、两个输入 ACK、到达余量、map_revision |
| EVENT | 2 | 0 | reliable | 房间操作、基线、READY、地形、回合、开火、命中和光束特效 |

INPUT 共享 control_epoch 和连续移动记录的起始序号；每条移动保留目标 tick、观察 tick、轴、持续按键和瞄准。动作单独携带序号、目标 tick、按下/释放位图、瞄准及武器上下文。快照 ACK 占四字节。

动态实体使用整数 ID。接收端先恢复同一 tick 的完整实体列表，再交给预测和播放。弹丸编号组合玩家、射击序号和弹丸序号，用于预测表现合并。弹药、伤害、拾取、地形和胜负由服务端结算；伤害统一经 world.damage 处理统计、颗粒收益及 HIT。

## 固定布局与差量基线

STATE 头为消息码、快照序号、基线序号、世界 tick 和 map_revision，共 17 字节。快照编号属于连接，换回合仍递增；基线编号零表示独立全量。全量快照提供角色顺序表，差量用该顺序的存在/变化位图描述角色。

弹丸变化记录使用八字节 ID、一字节位图和变化的位置/速度；武器类型、生成输入序号、epoch 在创建或变化时发送。常速弹丸仅位置变化时为 17 字节。拾取物与自身背包发送变化字段，删除实体使用显式 ID 列表。弹丸场景、射程、尺寸和颜色从本地 WeaponRegistry 缓存读取。权威位置与速度反映水中阻力、碰撞和 Beta 回溯；Vector2 为 float32，预测计时器为 float64。

双方各保存最多 64 份完整快照。客户端成功解码并缓存后更新 ACK，服务端相对仍保留的 ACK 基线编码。服务端基线过期发送全量；客户端缺少指定基线时忽略该差量，并在下次 INPUT 中发 ACK=0 请求全量。该缓存与 32 个播放样本独立。

BASELINE 清空差量历史并嵌入独立全量 STATE，服务端等待 READY 后继续发送。新连接建立新的编解码器；可靠基线编号高于该连接先前 STATE。

地形每次生命值变化递增 map_revision，通过 EVENT 同步。客户端暂存最新的未来版本远端世界，待地形追上后应用；本地状态、ACK、时钟反馈和最新碰撞代理在下一物理帧处理。

布局与差量参考 [Quake III 消息编码](https://github.com/id-Software/Quake-III-Arena/blob/master/code/qcommon/msg.c) 和 [Snapshot Compression 的 ACK 基线](https://gafferongames.com/post/snapshot_compression/)；类型配置本地解析参考 [Teeworlds 弹丸](https://github.com/teeworlds/teeworlds/blob/master/src/game/server/entities/projectile.cpp)。读写使用 [Godot StreamPeer](https://docs.godotengine.org/en/stable/classes/class_streampeer.html)。

## ENet 包级压缩

服务端、客户端和重连新 peer 在 create 成功后、交给 MultiplayerAPI 前执行：

~~~gdscript
peer.get_host().compress(ENetConnection.COMPRESS_ZSTD)
~~~

两端固定相同模式。[Godot 接口](https://docs.godotengine.org/en/stable/classes/class_enetconnection.html#class-enetconnection-method-compress) 要求双方设置一致。ENet 对实际 UDP 包体调用压缩器，结果更大时发送原包；协议头、分片与重组由 [原生实现](https://github.com/godotengine/godot/blob/master/thirdparty/enet/protocol.c) 处理。大基线和全量 STATE 可经 ENet 分片传输。

## 模拟与输入调度

服务端 60 Hz 模拟、30 Hz 发送 STATE。InputBuffer 按 target_tick 保存未来输入，当前 tick 使用最新已到期持续状态；迟到状态安排到下一 tick。未来窗口 32 tick，持续轴和按键按原始目标时间延续最多六 tick，之后归零并保留瞄准。

跳跃、点击、松开、换弹、切枪、拾取和丢弃属于独立动作。动作重复发送至 action_ack 确认，目标时间之后 12 tick 过期；每世界 tick 最多消费一条有效动作。移动 ack 与 action_ack 分别退休对应记录，动作效果仍受冷却、弹药、角色状态和武器实例约束。无反馈时客户端按输入时钟退休超过 44 tick 的动作，持续输入保留四条，预测历史保留 64 条。

输入时钟从 STATE tick + RTT 对应 tick + 两 tick 余量初始化。STATE 的 timing_seq 和 lead 提供到达反馈，lead 为目标 tick 减服务器收包 tick。客户端仅平滑新反馈，以 1.02、1.00、0.96 倍速度调整预测时钟；输入采样与发送保持 60 Hz，服务器每世界 tick 模拟一次。

ActorStep 使用相同碰撞实体为服务端、本地预测和单人执行角色步进，返回开火与音效等动作。首次步进执行动作，预测重放仅恢复玩法状态。Player.present_tick 更新动画、预瞄线、闪烁、HUD 和合并的库存通知。

## 预测与共同播放

STATE 到达时保存最新待应用权威状态。在下一物理 tick 恢复完整状态，按相同 InputBuffer 重放至输入时钟，再采样新输入。历史最多 64 条，单次重放上限 32 tick；历史缺失或超预算直接采用权威状态。复活、换回合、重连和退出回溯推进 control_epoch，重建输入与预测历史。

角色与武器共用 Visuals，校正偏移在 50 ms 内衰减。本地外观按最近一个实际模拟 tick 的位移和物理插值比例采样，视觉外推上限一个 tick。镜头与本地标签跟随 Visuals，在角色表现更新后更新镜头。物理位置、碰撞和弹道使用模拟状态。

远端角色、弹丸、拾取物、血条和小地图共用 100 ms 播放缓冲，环面插值沿最短位移。播放样本上限 32，采样保留左端和未来样本；普通缓冲偏差平滑调速，严重落后超过 12 tick 时重定位到最新 tick 减六。断流最多外推 100 ms，随后冻结。碰撞代理在物理帧使用最新权威位置。

激光读取最多 12 tick 的角色 AABB 历史，地形使用当前状态，一条光束对同一角色判定一次。实体弹丸在当前权威世界连续检测。Beta 以 20 Hz 记录自身状态和仍存活的自身弹丸，回溯期间客户端跟随权威状态，退出后重建预测。

参考调用图与队列规则见 [模拟、预测与网络波动](architecture_references.md)。

## 官方 EasyTier、端口与重连

[安装工具](../../tools/fetch_easytier.py) 从官方 Windows 2.7.0 包复制运行组件和许可，缺少 relay.txt 时生成默认公共节点列表：

~~~powershell
python tools/fetch_easytier.py --source D:/Codes/ChatGPT/cyr/easytier-windows-x86_64
~~~

网络设置写入可写 TOML，启动参数传配置文件与本地 RPC portal。使用 no-tun、UDP、延迟优先、房间凭据和主机名端口信息；bind_device=false，data_compress_algo="None"。官方 CLI 创建 UDP 转发。

房间码是保留前导零的八位十进制字符串。端口通过绑定零、读取端口、关闭探测 socket、启动实际服务分配。断线席位保留 60 秒；客户端一个重试循环，每次 ENet 尝试最多五秒，失败间隔一秒。转发重建后连接本地新端口，以房间码和 token 请求基线。

## 验证

[网络探针与多进程对局](tests.md) 覆盖输入调度、二进制往返、ACK 差量、权威战斗、播放、地形、Beta、AI、换回合与重连。[结果与计量边界](network_validation.md) 分别报告基线和对战的 ENet 字节、包数、CPU、帧耗时及断流后的外推/冻结。
