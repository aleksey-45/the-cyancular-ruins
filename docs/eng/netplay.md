# 联机与网络系统架构 (大厅 / 匹配 / 预测回滚 / 断线重连)

> 本文档规范 Cyber Ruins (CyR) 的网络与多人对战架构。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。

---

## 一、网络拓扑与架构模式

### 1. 服务端运行模式 (`server/server_main.gd`)
服务端以 headless 模式运行（入口 `server/server_main.tscn`），支持两种工作模式：
1. **大厅模式 (Lobby Mode)**：默认监听 UDP 端口 7777（可通过 `--port` 自定义），单进程内管理房间生命周期、队伍分配与对局匹配。在单进程架构下，局内会话以 `MatchSession` 子节点形式挂载在大厅树下运行。
2. **独立单局模式 (Worker Mode)**：使用 `--worker --port P` 参数启动，独占 UDP 端口 `P`，专用于自动化测试或独立进程部署。接收 `--royale`（大乱斗）或 `--team`（3v3）及 `--roles`、`--teams`、`--ai-roles` 等配置。

### 2. 核心服务端组件
- **房间簿记 (`server/lobby/lobby_rooms.gd`)**：`LobbyRooms extends Node`，维护内存中的房间状态机、玩家认领表与房间号字典。作为 Node 挂载以访问 `multiplayer` API 与 SceneTree。
- **房间调度与生命周期 (`server/lobby/room_manager.gd`)**：负责对局拉起、房间超时扫描（默认每 30 秒轮询清理已结束对局，2 小时保底清扫陈旧对局）、以及客户端向指定对局引导。
- **权威对局宿主 (`server/match/match_host.gd`)**：单局物理与规则权威。包含碰撞世界（通过 `WorldBuilder` 仅构建物理碰撞而不创建渲染对象）、双端角色对象注入 `NetworkInputSource`、输入包 FIFO 队列消费、60Hz 权威状态广播快照生成，以及投射物命中仲裁。

---

## 二、客户端预测与回滚机制 (Client-Side Prediction & Reconciliation)

客户端采用业界标准的客户端预测与回滚架构（C2，参考 `core/net/prediction_rollback.gd` 与 `scenes/pvp_match_client.gd`）：

1. **本地输入预测**：本地玩家读取本机真实 `Input` 并在本地物理帧即时步进，保证 0 延迟移动与瞄准手感。每个输入包打上自增 `seq` 序号，以 60Hz 可靠传输至服务端。
2. **服务端权威消费**：服务端每个物理 Tick 按 FIFO 顺序消费一个输入包，并在广播快照中回传当前已处理的 `ack_seq` 以及权威全量物理状态。
3. **分歧比对与回滚 (Reconciliation)**：
   - 客户端收到权威快照后，对比快照对应的历史本地记录。若位置或速度误差超出容差阈值，执行 `restore_state` 将本地状态重置为服务端权威值。
   - 客户端从被确认的 `ack_seq` 重新快进重放所有尚未被服务端确认的本地输入（Replay Pending Inputs），平滑纠正预测偏差。
4. **贴身对抗容差机制 (Contact Tolerance)**：
   - 自由移动阶段采用常规位置容差（`pos_tol = 2.0px`）。
   - 贴身肉搏阶段（通过 `Player.touching_player()` 检测滑动碰撞），切换至自适应贴身容差（`contact_pos_tol = 8.0px`），大幅减少近身接触时的非必要预测回滚。

### 远端角色副本 (`PlayerReplica`) 与阻挡体
1. **视觉呈现**：远端对手为客户端创建的 `PlayerReplica` 副本，武器姿态与准星通过 `apply_snapshot` 同步，不执行本地开火逻辑。
2. **预测阻挡体 (Ghost Body)**：
   - 远端副本挂载一个轻量 `StaticBody2D`（`collision_layer=2`，`mask=0`），姿态根据快照动态切换。
   - 客户端本地玩家设置 `collision_mask |= 2`，使得本地预测步进时能正确感知远端玩家的物理阻挡，杜绝因本地穿透而服务端阻挡导致的持续高频回滚循环。
3. **位置平滑算法**：
   - 渲染层使用指数收敛追赶算法（`1 - exp(-INTERP_RATE * delta)`，`INTERP_RATE = 12.0`），消除网络抖动。
   - 物理预测阻挡体紧随最新的原始权威位置，不经过平滑低通滤波，确保预测碰撞的绝对实时性。

---

## 三、网络通信协议与通信总线

通信依托 ENet RPC（通过 `core/net/net_bus.gd` 与扩展总线 `core/net/net_bus_ext.gd`）：

| 消息类型 | 传输模式 | 典型内容 |
|---|---|---|
| 输入包 (`send_input`) | Reliable 60Hz | 水平轴输入、按键位掩码（含跳跃、换弹 `BIT_RELOAD`、下蹲等）、切枪、准星角度 |
| 状态快照 (`snapshot`) | Unreliable 60Hz | 全体玩家权威坐标、速度、朝向、姿态、手持武器 ID、生命值、防水状态、倒地标记 |
| 事件广播 (`round_state`, `hit_event` 等) | Reliable | 回合切换倒计时、击中判定确认、瓦片物理破坏事件 `tile_destroyed`、击杀播报 |
| 光束射击 (`beam_fired`) | Reliable | 权威即时光束轨迹广播，供非射手端绘制视觉特效 |

### 通信纪律与连接保全
1. **定向发包活性检查**：发送定向 RPC 前统一调用 `NetBus.is_peer_live(id)`，校验底层 ENet 套接字状态与通道计数（`get_channels() > 0`），防御向处于断开析构窗口的客户端发包引发底层通道错误。
2. **全员广播活性检查**：执行全员状态广播前通过 `NetBus.all_peers_sendable()` 确认全体对端具备发包条件。
3. **环面最短路径坐标**：所有网络坐标均传输标准 Canonical 坐标；各端渲染时调用 `toroidal_delta_px` 计算最短向量，避免跨接缝击退方向颠倒。

---

## 四、断线重连与会话恢复

### 1. 宽限期机制 (`core/net/grace_window.gd`)
- 客户端掉线时，服务端不立即销毁角色节点或结算淘汰，统一进入 60 秒宽限期（`GraceWindow.DEFAULT_SECONDS`）。
- 掉线期间角色物理节点保留在场景中，服务端重置其输入缓冲并冻结输入源，角色分数、血量、背包、装备完好保留。

### 2. 局内直连恢复 (同端口/同会话恢复)
- 客户端检测到网络闪断后，保持本地场景与世界树不变，使用握手分配的 `session_token` 调用 `reclaim_role`。
- 服务端校验令牌有效性与宽限期剩余时间，核准后重新绑定 `peer_id`，换回网络输入源，并下发 `match_start`。
- 客户端重连成功后重置本地预测序号，并向服务端拉取 `match_sync` 补齐断线期间被破坏的地图瓦片（`destroyed_cells`）与地面武器拾取状态。

### 3. 返回大厅后重新加入 (`server/lobby/rejoin_registry.gd`)
- 若玩家意外退出到主界面或大厅，凭借本地保存的 `PvpSession.rejoin` 凭据，可在房间列表中看到标识为“进行中”的原房间。
- 客户端向大厅发送 `rejoin_request(room_code, token)`，大厅凭据表 `RejoinRegistry` 校验房间有效性后，返回对应对局的目标端口与角色。
- 客户端重新加载对局场景，进入该房间并完成角色重认领。

---

## 五、核心自动化测试用例
- `tests/smoke/pvp_room_smoke.sh`：房间创建、加入、开局握手链路。
- `tests/smoke/pvp_match_smoke.sh`：输入处理、快照广播、击杀状态转移。
- `tests/smoke/pvp_reconcile_smoke.sh`：客户端回滚预测核心算法单元测试。
- `tests/smoke/rejoin_registry_smoke.gd`：重连凭据表过期与作废逻辑测试。
- `tests/probe/reconnect_probe.tscn`：真实网络闪断与断线重连端到端验证。
- `tests/probe/replica_ghost_probe.tscn`：远端对手副本与阻挡体回滚抑制测试。
