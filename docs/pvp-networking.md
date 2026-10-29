# The Cyancular Ruins — PvP 联机模块分析

**专用服务器权威 + 客户端本地预测自己(C2)。** 服务器跑全部权威模拟;客户端不裁决伤害。本地玩家跑完整 `player.gd` 物理,服务器 30Hz 广播快照,客户端用它校正自己、渲染远端对手。

- 环面世界:协议只传 canonical `[0, MAP)` 坐标;渲染各端归最近副本;距离与插值走最短路径增量。
- 两端共用 autoload `NetBus` 收口 RPC,跨场景常驻。

## 1. 进程拓扑

```
大厅进程(--headless,UDP 7777)
server_main.tscn
 ├─ RoomManager(清扫梯 / 拉起 worker / 注入 launcher)
 │   └─ LobbyRooms(房间门面)
 │        └─ RoomRegistry(mode -> {code: Room})
 └─ WorkerLauncher(端口池 [7800,8300) / OS.create_process)

每局一个 worker 进程(--worker --port P,--headless)
server_main.tscn(worker 分支)
 └─ MatchHost / RoyaleHost / TeamHost
      ├─ WorldBuilder 建世界(只碰撞不渲染)
      ├─ player.tscn × N(完整物理,注入 PacketInputSource)
      └─ 子弹模拟 + 命中裁决 + 30Hz 快照广播
```

客户端 P1 / P2 … 对称连到该局的 worker,没有房主优势。服务端进程带运维面板与审计通道;面板在 `DisplayServer.get_name() == "headless"` 下不实例化。

## 2. 场景流程

```
main_menu.tscn
 ├─ 单人 → Level0.pvp_mode=false → scenes/level_0.tscn
 └─ 多人 → PvpSession.reset() → scenes/mp_lobby.tscn
       ├─ 建房 / 输房间号加入
       └─ 开局 → 大厅发 session_token + go_match(role, port)
                → 客户端转连 worker、claim_role
                → worker 建局并回 match_start(role, spawn, map_path)
                → pvp_game.tscn / royale_game.tscn / team_game.tscn
```

## 3. 文件地图

| 文件 | 角色 |
|---|---|
| `core/net/wire.gd`(autoload `Wire`)+ `wire_kind.gd` | 唯一传输收口:ENetConnection 直连、帧派发、信号转发;消息种类登记表 |
| `core/net/pvp_session.gd` | 静态会话配置:role / spawn / map / 地址 / token / 回局凭据 |
| `core/net/net_codec.gd` / `prediction_rollback.gd` | 快照 `PackedByteArray` 编解码 / C2 权威锚定与未确认输入重放 |
| `core/net/grace_window.gd` | 掉线宽限期表与到点动作分派 |
| `core/net/local_input_source.gd` / `packet_input_source.gd` | 本地输入源 / 网络输入源(服务器唯一消费方) |
| `server/server_main.gd` | 入口:大厅分支 / worker 分支、认领、宽限、结算 |
| `server/lobby/room_manager.gd` / `lobby_rooms.gd` | 拉 worker、配对开局、清扫与回收 / 房间账本门面、RPC handler、`teardown_room` 收口 |
| `server/lobby/room_registry.gd` / `room_types.gd` | 单一注册表 `mode -> {code: Room}` 与列表载荷 / 单一房型 `Room` |
| `server/lobby/worker_launcher.gd` / `rejoin_registry.gd` | 端口池、拉起 / 杀 worker、port → pid / 回局凭据表 |
| `server/match/match_bootstrap.gd` / `match_host.gd` / `match_state.gd` | 建局引导 / 权威对局编排 / 回合状态机与记分 |
| `server/match/match_snapshot.gd` / `match_combat.gd` / `match_round.gd` | 30Hz 世界包与本人包 / 子弹爆炸光束裁决与拆墙 / 回合迁移与换局复位 |
| `scenes/pvp_game.gd` + `.tscn` / `royale_game.gd` / `team_game.gd` | 三个客户端对局场景 |
| `scenes/pvp_match_client.gd` | 三个对局客户端共用基类(输入上报、C2、重连) |
| `scenes/player/player_replica.gd` | 远端副本(视觉 + 幽灵碰撞体) |
| `scenes/mp_lobby.gd` / `scenes/mp_lobby.tscn` | 统一联机大厅 UI |

## 4. 传输层:NetBus

服务器与客户端共用 `/root/NetBus`(autoload)。`ENetMultiplayerPeer` + Godot 高层 MultiplayerAPI;大厅端口 `7777`(`DEFAULT_PORT`),`create_server(port, 16, ENet_CHANNELS)`,`ENet_CHANNELS = 4`。

- 方法按调用方区分两端;服务端侧 `emit` 信号转交 `RoomManager` / `MatchHost`,不硬依赖类型。
- `NetBus.is_peer_live(id)`:ENet peer 状态 `CONNECTED` 且通道数 > 0。定向发送前必须判。
- `NetBus.all_peers_sendable()`:peer 表里每一个都能收包;空表 = false。广播前判。
- `NetBus.reply(id, method, …)`:答复 caller 的唯一收口,内部先判活。

RPC 主干:

| RPC | 方向 | 模式 |
|---|---|---|
| `create_room()` / `join_room(code)` / `list_rooms()` | 客户端 → 大厅 | reliable |
| `go_match(role, port)` / `session_token(token)` | 大厅 → 客户端 | reliable |
| `claim_role(role, name)` / `report_token(token)` / `reclaim_role(role, token)` | 客户端 → worker | reliable |
| `send_input(pkt)` | 客户端 → worker | reliable |
| `snapshot_world(payload)` | worker → 客户端 | unreliable |
| `snapshot_own(payload)` | worker → 客户端(逐 peer) | unreliable |
| `bullet_spawn` / `hit_event` / `beam_fired` / `tile_destroyed` / `kill_event` / `round_state` | worker → 客户端 | reliable |

信号分区:

- 客户端侧:`local_room_created` / `local_room_joined` / `local_room_list` / `local_match_start` / `local_server_message` / `local_snapshot_world` / `local_snapshot_own` / `local_bullet_spawn` / `local_hit_event` / `local_tile_destroyed` / `local_round_state` / `local_kill_event` / `local_opponent_left`。
- 服务器 → `RoomManager`:`room_create_requested` / `room_join_requested` / `room_list_requested` / `peer_left`。
- 服务器 → `MatchHost`:`input_received`。

RPC 里用 `multiplayer.get_remote_sender_id()` 取真实调用方。通道号见 [`eng/netplay-rpc-channels.md`](eng/netplay-rpc-channels.md)。

## 5. 房间与匹配

- 房型 `RoomTypes.Room`:字段并集,`mode` 是模式唯一真相。注册表 `RoomRegistry`:`mode -> {code: Room}`;`LobbyRooms` 是门面,`rooms` / `royale_rooms` / `team_rooms` 是三个只读视图。
- 房号 4 位,只在本 mode 内唯一(`RoomRegistry.next_code(mode)`)。
- 建房:生成房号,房主 role = 1;1v1 回 `room_created(code)`,大乱斗 / 3v3 走等待室状态广播。
- 加入:房间不存在 / 对局中 / 已满 / 邀请码错 → `server_message`;成功则分配 role 并 `room_joined`。
- 1v1 满两人自动开局(经 `pairing_ready`);大乱斗房主 `royale_start`;3v3 两队各 3 人后房主 `team_start`。
- 开局:冻结名单(`freeze_roster`)→ `pick_port()` → `OS.create_process` 拉起 worker → 发 `session_token` 与 `go_match(role, port)`;客户端转连 worker 并 `claim_role`,worker 侧 `MatchBootstrap.start_on` / `TeamHost.start_on` / `RoyaleHost.start_on` 建局。
- 地图:默认 `MatchBootstrap.PVP_MAP = res://maps/newfactory.cyrm`;房主上报的 `player_options.map` 经 `MapCatalog.resolve_pvp_map()` 校验(只认 `res://maps/*.cyrm`、拒 `..`、须有双出生点),不合规回落默认图。
- 掉线:`server_main._on_peer_left` 把 role 放进宽限期,玩家节点不销毁;到点按 `GraceWindow.expire_action` 移出或收场。
- 拆除唯一收口 `LobbyRooms.teardown_room`;端口归还延迟三档由 `ModeRoomRules.port_return_seconds(mode)` 给(120 / 360 / 360 秒),`tools/room_sweep_lint.gd` 钉住。

## 6. 服务器权威对局:MatchHost

`MatchHost` 每房间一个,建整张地图与全部玩家。

### 构造

- `MazeGenerator.set_map_file` → `WorldBuilder.load_grid()` + `TileDefs.init_hp` / `init_sub_hp` + `WorldBuilder.build_sim`(永久墙 + 可破坏分块 + 攀爬条)。服务器只建碰撞不渲染。
- 实例化 `scenes/player/player.tscn`,每个 role 一份 `PacketInputSource`,按出生点摆位;玩家完整跑 `_physics_process`。

### 每物理帧时序

1. 同步地面武器位置、Beta 时间玩法(`time_economy`)与加速态。
2. 快照相位:每 `SNAPSHOT_STRIDE = 2` 个 tick 广播一次 `snapshot_world` + 逐 peer `snapshot_own`(30Hz)。
3. 消费输入:每 2 个 tick 从 FIFO 取一条记录;`clear_edges()`,`apply_packet()`,更新 `_ack_seq[role]`。COUNTDOWN 期间清空队列并 `reset_state()`。
4. 玩家与子弹的 `_physics_process` 由场景树步进(父先于子,读到的是本帧注入)。
5. `_adjudicate_bullets()`、`_broadcast_pending_beams()`、`_match_round_tick()`、队列诊断。
6. 可破坏碰撞块重建:每帧最多 2 块(`CollisionBuilder.rebuild_chunk`)。

### 输入

- 队列在 `InputIntake`(`server/match/input_intake.gd`),`held` / `axis` / `aim` 覆盖取最新,`pressed` / `released` 边沿按位累积。
- 缺包时沿用上一包 `held`;边沿只活一帧。
- 一条输入记录覆盖 `PacketInputSource.TICKS_PER_RECORD = 2` 个物理 tick。

### 快照

- 世界包:`{tick, players: {role: {pos, vel, facing, pose, type_id, hp, waterproof, downed, aim, previewing, …}}}`;`tick` 在 60Hz 物理 tick 域,每包 +2。
- 本人包:`{ack_seq, q, c2}`;`q` = 已到达未消费的输入记录数,`c2 = player.capture_state()`。
- 载荷由 `NetCodec` 打包成 `PackedByteArray`;RPC 入口解码回同形状 `Dictionary`。

### 裁决与拆墙

- `_adjudicate_bullets`:遍历 `bullet` 组,`_seen_bullets` 防重;新子弹广播 `bullet_spawn` 给非射手端。
- 命中 = 与非射手玩家的 `toroidal_delta_px` 距离 < `HIT_RADIUS`(`BulletBase.PLAYER_HIT_RADIUS = 40.0`);命中后 `take_hit` + 广播 `hit_event` + `queue_free()`。
- 榴弹在 `_adjudicate_grenade`:只结算一次直接命中,不销毁子弹,引信照常爆炸。
- 即时光束:`_broadcast_pending_beams()` 轮询 `collect_pending_beam_report()`,经 `beam_fired` 广播给非射手端。
- 拆墙:`_on_tile_destroyed` 清 `sub_hp` 与 `destructible_sub` 子格、标 `_dirty_chunks`、广播 `tile_destroyed`;16px 子格拆毁走 `_on_sub_destroyed` + `sub_destroyed`。

## 7. 客户端对局

`scenes/pvp_game.gd`(基类 `scenes/pvp_match_client.gd`)加载 Level0(`pvp_mode = true`)。

### `_ready`

1. `MazeGenerator.set_map_file(PvpSession.map_path)` + `GameParameters.refresh_map_size()` + `Level0.pvp_mode = true`;实例化 `scenes/level_0.tscn`,本地玩家摆到 `PvpSession.spawn`,`collision_mask |= 2`。
2. 建 `PredictionRollback`,`bind(_local)`、设 `map_px`;补 `PostProcess`(pvp_mode 下 Level0 不建)。
3. 实例化 `PlayerReplica` 进 `WorldViewport`。
4. 连快照 / 子弹 / 光束 / 命中 / 拆砖 / 回合 / 击杀 / 对手离开 / `match_sync` 信号。
5. 末尾 `NetBus.rpc_id(1, "match_sync")` 拉进场载荷。

### 输入上报

- **每物理 tick**：`note_post_step()`(上一 tick 的预测整态) + `reconcile()` + `PacketInputSource.pack_record()`(一条 = 1 tick) + C2 `note_input`；**每 2 个 tick** 把 `[上一 tick, 本 tick]` 两条记录 `pack_pair()` 后 `NetBus.rpc_id(1, "send_input", pkt)`（流水线,30Hz 发包）。
- 包字段:`seq`(包级=高 tick,低 tick=seq-1)、`held0/1`、`ax0/1`、`pressed0/1`、`released0/1`、`winst0/1`、`aim`、`st`、`ct`。
- 位常量 `PacketInputSource.BIT_*`:up=1 / down=2 / charge=4 / attack=8 / reload=16 / pickup=32 / drop=64 / haste=128 / rewind=256。
- 本地预测**不锁存**(60Hz 真输入),C2 重放 1 步/记录;客户端与服务器逐 tick 同序。

### 快照消费

- `snapshot_world`:丢弃 `tick` 回退的旧包;自己那份刻意不消费;对手部分交 `PlayerReplica.apply_snapshot()`。
- `snapshot_own`:丢弃 `ack_seq > _input_seq` 的跨纪元残留;其余喂 `PredictionRollback`。★ 本人包由服务端在"消费并步进完本 tick"之后帧末发(S1),`ack/c2` 是最新同拍态;世界包里自己那份因此比本人包旧 1 tick(客户端不消费它)。
- 容差:`pos_tol = 2.0`;接触期 `contact_pos_tol = 8.0`。`in_contact` 由 `Player.touching_player()` 在 `note_post_step()` / `reconcile()` 之前写入,不进 `capture_state()`、不上行。
- 分歧处理:预测被证实不动;真性分歧才 `restore(权威态)` 并按序重放 `(ack, last_applied]` 的本地输入。

### 事件消费

- `bullet_spawn`:生成视觉子弹副本,`apply_damage = false`,摆到 canonical 位置;`hit_event`:本地玩家被命中 → `take_hit` 即时白闪 / 击退,血量以快照为权威。
- `tile_destroyed` / `sub_destroyed`:同步拆砖渲染与碰撞;`round_state`:四态编排在基类,1v1 新一局清子弹 + 复位砖,`MATCH_OVER` 刷新结算页。
- `opponent_left`:置 `_match_ended`、停重连、2.5s 后回主菜单。

## 8. 远端副本:PlayerReplica

`Node2D` + `AnimatedSprite2D`,不做物理。

- `apply_snapshot(data, local_anchor, tick)`:存 canonical 目标,更新朝向 / 姿态 / 倒地 / 武器槽 / 受击闪烁。`type_id = 0` = 空手,与换枪同等重建。
- 位置走 playout 缓冲插值:固定 `PLAYOUT_TICKS = 4`(60Hz tick 域、下行 30Hz ⇒ 2 个发包间隔 ≈ 67ms 缓冲)之后的那一刻,对两条相邻快照夹逼插值;取样点再 `anchor_to_nearest` 回本地玩家最近副本。两端冻结(不外插、不倒退);相邻样本环面距离 > `SNAP_DIST = 128 px` ⇒ 清历史一帧落位(回溯 / 重生 / 换边)。
- 渲染层带:副本在 `_ready` 里把自己挪到世界结构层(`Level0.wall_layer`:墙体 / 梯子 / 建筑)之前 —— 本体在 `level_0.tscn` 里就排在那层之前,副本运行时 `add_child` 到世界末尾会盖住那些结构(现象:只有别人的角色压在地形上)。
- 幽灵碰撞体:`StaticBody2D`,`collision_layer = 2` / `collision_mask = 0`;五份 `CollisionPolygon2D` 按 `pose` 切换,`downed` 时不切;节点进 `player_replica` 组。★ 幽灵体**不跟插值**:跟未经平滑的最新快照锚点(预测面要最小陈旧)。
- 姿态映射 `POSE_ANIM`:`0 idle / 1 move / 2 fly / 3 charge / 4 squat`;倒地停动画并转体,幽灵体世界旋转压回 0。
- 武器视觉由 `weapon_base.drive_remote_visual(aim, aim_facing)` 驱动,不开火、不读鼠标;对手预瞄线不画(快照 `previewing` 客户端不消费)。

## 9. 输入抽象

| 方法 | `LocalInputSource` | `PacketInputSource` |
|---|---|---|
| `get_axis` | 读真实 `Input` | `ax`(水平) + `held` 位推导垂直 |
| `is_action_pressed` | 读真实 `Input` | `_held` 位掩码 |
| `is_action_just_pressed/released` | 读真实 `Input` | `_pressed` / `_released` 累积边沿 |
| `is_attack_*` | 委托 `"attack"` | `BIT_ATTACK` |
| `get_switch_index_pressed` | 轮询按键 1-4 | `_switch_index` |
| `consume_switch_inst` | 默认 0 | 包内 `winst` |
| `get_aim_dir_override` | `Vector2.ZERO`(落回鼠标) | 注入的瞄准方向 |

- 基类 `PlayerInput` 的 `frozen` 在所有公开读口短路:PvP COUNTDOWN / 局间冻结时一切读口返回中性值,子类 `_*_raw()` 不被调用。`player.gd` 字段 `input_source`(默认 `LocalInputSource.new()`)+ `set_input_source()`;攻击查询转发给武器,`has_method` 守卫回退真实 Input。

## 10. 协议汇总

| 包 | 方向 | 频率 / 模式 | 字段 |
|---|---|---|---|
| 输入包 | 客户端 → worker | 30Hz / reliable | 手打包 **46 B**：两条 tick 记录 `seq` `held0/1` `ax0/1` `pressed0/1` `released0/1` `winst0/1` + `aim` `st` `ct`（`NetCodec.KIND_INPUT`） |
| `snapshot_world` / `snapshot_own` | worker → 客户端 | 30Hz / unreliable | 世界包 `tick` + `players{…}`;本人包(逐 peer)`{ack_seq, q, c2}` |
| `bullet_spawn` | worker → 客户端 | reliable | `scene shooter_role pos vel speed range size color gravity hit_damage …` |
| `hit_event` | worker → 客户端 | reliable | `victim_role damage source_pos` |
| `beam_fired` | worker → 客户端 | reliable | 光束报告 + `shooter_role` |
| 房间 / 对局 | 双向 | reliable | `create_room` `join_room` `go_match` `session_token` `claim_role` `match_start` `match_sync` `match_sync_data` `round_state` … |

世界包与本人包由 [`core/net/net_codec.gd`](../core/net/net_codec.gd) 打包;输入包同样走这份编解码器(`KIND_INPUT`,46 B/包 = 两条 tick 记录;改前是 34 B 单条锁存记录 / 更早是 7 键 `Dictionary`)。完整通道归属见 [`eng/netplay-rpc-channels.md`](eng/netplay-rpc-channels.md)。

## 11. 环面纪律

1. 模拟用 canonical 真值:服务器玩家与客户端本地玩家都 `wrap_to_range` 到 `[0, MAP)`。
2. 协议只传 canonical:快照 `pos`、子弹 `pos` 都是 canonical。
3. 渲染各端归最近副本:自己 = 中间副本;对手 / 子弹 = `anchor_to_nearest(canonical, 自己)`。
4. 距离、击退、校正走 `toroidal_delta_px`,不做 naive lerp。
5. 物理副本无关(9 副本地形逐像素相同);锚定是渲染层变换,在 `move_and_slide` 之后,不回喂物理。

## 12. 端到端数据流

```
客户端                          worker                          对手客户端
每物理帧(60Hz 采样，30Hz 发包 —— 一包两条 tick 记录):
  本地模拟自己(C2) + 打包输入 ── reliable ──→  InputIntake FIFO
                            ↓ 每 tick 取一条
                            全体 Player._physics_process 权威模拟;子弹 / 光束裁决,拆墙
                            30Hz snapshot_world ── unreliable ──→ 对手副本直出最新包
                            30Hz snapshot_own   ── unreliable ──→ PredictionRollback(分歧才 restore+重放)
                            新子弹 / 命中 / 拆砖 ── reliable ──→ 视觉反馈
```

## 13. 测试

| 脚本 | 覆盖 |
|---|---|
| `tests/smoke/pvp_room_smoke.sh` | 建房 → 配对 → `go_match`(占 7777) |
| `tests/smoke/pvp_match_smoke.sh` | 输入 → 模拟 → 快照 → 子弹广播 |
| `tests/smoke/net_wire_smoke.gd` | 线格式(三 kind 头/往返/坏包 + schema 对齐) |
| `tests/smoke/input_queue_smoke.gd` | 输入队列(轴收口/有界/回复力/上限) |
| `tests/probe/rejoin_probe.sh` | 回大厅后回局三端 |
| `tests/probe/rollback_fidelity_probe.tscn` | C2 容差与接触提示接线 |

★ 原 `rpc_channel_contract_smoke` / `room_registry_smoke` / `mode_*_smoke` / `resync_world_probe` 已随 2026-10-24 默认批激进削减删除（缺口见 [`eng/registered-debt.md`](eng/registered-debt.md) §九）。

## 14. 已知边界

- 子弹散射:客户端视觉子弹的散射角本地掷定,与服务器权威子弹不同;命中由服务器裁决。本地玩家子弹是视觉副本:`weapon_base.fire()` 里 `b.apply_damage = not Level0.pvp_mode`。
- 并发上限由端口池决定:每局一个 worker,端口池 500 个;端口耗尽时 `pick_port()` 返回 -1。
- 回局只在宽限期内真正成功;宽限到期后 worker 会移出或收场,客户端被 `_on_reclaim` 踢连接。pid 复用:`pid_alive` 即 `OS.is_process_running`,误判方向是「多留」,降级成超龄清扫兜底。
- 引擎自身偶发 `max channels: 0` 报错:连接被踢的同拍定向发送。★ 2026-10-24 客户端侧已缓解 —— 收到 `go_match` 后在帧末**再等一帧**才 `NetBus.stop()`(`lobby_page._do_go_match`),让大厅最后两条定向包先落地。引擎侧的「判活通过→同帧被拆→send」窗口在 GDScript 里没有原子性,关不掉 ⇒ 剩下的偶发仍按「已登记、不追」处理,它只丢一条「注定要被断的连接上的最后一条包」,不影响对局。3v3 队友不在本地 `collision_mask` 里 ⇒ 队友永不判接触,与「队友不互挡」一致。
