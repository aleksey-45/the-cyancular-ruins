# 联机基础(大厅 / 匹配 / 房间 / 重连)

入口 `server/server_main.tscn`(headless),同一份代码两种角色:

| 角色 | 启动 | 端口 |
|---|---|---|
| 大厅 | 无参 | UDP `7777`(`NetBus.DEFAULT_PORT`) |
| 对局 worker | `--worker --port P` | UDP `P`,一局一个进程 |

命令行开关写在 `--` 之后;解析与校验在 `core/mp/mode_context.gd`(`ModeContext.from_args`)。

模式 id:`ModeDefs.MODE_PVP` / `MODE_ROYALE` / `MODE_TEAM`(`core/mp/mode_defs.gd`)。worker 开关 `--royale` / `--team`;参数 `--roles`、`--ai-roles`、`--teams`。role 上界 `ModeDefs.ROLE_MAX`(16);3v3 每队 `TEAM_SIZE`(3)、`TEAM_COUNT`(2)。

## 房间模型

- 一种房型 `RoomTypes.Room`;字段并集,`mode` 是模式唯一真相(`is_duel()` / `is_royale()` / `is_team()`)。
- 单一注册表 `RoomRegistry`:`mode -> {code: Room}`;增删只走 `add` / `erase`,`of(mode)` 是只读视图。房号 4 位(`0000`~`9999`),只在本 mode 内唯一(`next_code(mode)`)。
- `LobbyRooms` 是门面(`Node`),保留 `rooms` / `royale_rooms` / `team_rooms` 三个只读视图;1v1 两人就绪经 `pairing_ready` 信号交给 `RoomManager`(两人凑齐**不触发开局**,须房主 `pvp_start`)。

## 端口池与拆除

- 端口池单一来源 `server/lobby/worker_launcher.gd`:`WORKER_PORT_BASE = 7800`、`WORKER_PORT_SPAN = 500` ⇒ `[7800, 8300)`;分配用递增游标 + 占用集合(`pick_port()`)。
- 拆除唯一收口 `LobbyRooms.teardown_room`;形态 `TEARDOWN_DELAYED`(默认)/ `TEARDOWN_ABORT` / `TEARDOWN_KILL`。端口归还延迟由 `ModeRoomRules.port_return_seconds(mode)` 给三档:`WORKER_PORT_REUSE_DELAY` = 120s,`ROYALE_PORT_REUSE_DELAY` / `TEAM_PORT_REUSE_DELAY` = 360s。
- `tools/room_sweep_lint.gd` 钉住:端口归还、注册表删除、凭据作废只出现在 `teardown_room` / `_release_port_later` 内。

## 开局链路

1. 大厅建房 / 加入并写房间记录;1v1 两人、大乱斗房主开始、对抗(2~10 人,两队各 ≥1 即可开)。
2. `RoomManager` 冻结名单(`freeze_roster`)、`pick_port()`、`OS.create_process` 拉起 `--headless --worker --port P`;worker 引擎日志写 `<日志目录>/worker_<port>.log`(日志目录:导出服务端 = exe 同目录 `log/`,开发态 = `user://logs`),按端口归档保留 20 份。
3. 大厅先发 `session_token`,再发 `go_match(role, port)`。
4. 客户端断开大厅、连 worker 端口、`claim_role(role, name, proto)`(v7 起带版本号,服务端不符即拒绝+踢连接);收齐 role 后 `MatchBootstrap.start_on` 建局。对局场景 `_ready` 末尾 `NetBus.rpc_id(1, "match_sync")` 拉 `match_sync_data`(昵称 / 色相 / 选项 / role 集合 / 出生点 / 地面武器 / 已拆格)。

## 一局之内

- 地图:默认 `MatchBootstrap.PVP_MAP = res://maps/newfactory.cyrm`;房主上报的 `player_options.map` 经 `MapCatalog.resolve_pvp_map()` 校验(只认 `res://maps/*.cyrm`、拒 `..`、须有双出生点),不合规回落默认图。
- `MatchHost` 建世界(只碰撞不渲染)+ 每 role 一份 `player.tscn`,注入 `PacketInputSource`。
- 回合:`MatchState.RoundState` COUNTDOWN → PLAYING → ROUND_OVER → MATCH_OVER;`KILLS_TO_WIN = 5`、`ROUNDS_TO_WIN = 2`、`COUNTDOWN_TIME = 3.0`、`ROUND_OVER_TIME = 4.0`、`RESPAWN_DELAY = 2.0`。击杀记给对方(倒地边沿,不分死因);换局整队换到另一侧(地图 `# teamspawn` 的另一队列表、重随机;旧图的几何回退仍用 `_side_swap` 翻点集)。COUNTDOWN 双端禁移动 / 开火:服务器清输入队列并 `reset_state()`,客户端 `InputSource.frozen`。
- ★★ 开局倒计时(三模式同一条):服务器等客户端场景就绪(`mark_client_ready`,上限 `COUNTDOWN_HOLD_MAX=2.0s`)才开始走时钟,并在 COUNTDOWN 期间**每 0.5s 重播一次当前剩余**(`MatchRound._countdown_resync_tick`;大乱斗原就有,1v1/3v3 2026-11-01 补上)。客户端走秒器 = 纯逻辑 `CountdownClock`(`ui/hud/countdown_clock.gd`):重复 `start` **只采纳更短的剩余、绝不回拨**,显示 `ceil(剩余)` 且钳到 ≥1 ⇒ 数字单调不增、`3→2→1` 一个不落。守卫 = `tests/smoke/countdown_clock_smoke.gd`(9 条)。
- 换局:服务器 `_reset_world_and_clear_dynamics()` 还原可破坏砖与子格 HP 基线、清子弹、重置地面武器;客户端同刻 `Level0.reset_destructibles()`。

## 频率与载荷

| 项 | 值 |
|---|---|
| 物理 tick | 60Hz |
| `snapshot_world` | 60Hz,unreliable;`SNAPSHOT_HZ = 60`、`SNAPSHOT_STRIDE = 1`(所有人数)。**每包全量**(v7 起 DELTA 已删);世界条目 trail 2 点 = **25 B**、空 trail = 17 B ⇒ N=16 世界包 408 B(多人回溯时)/ 280 B(常态),上行 ≈0.49 MB/s(回溯)/≈0.36 MB/s(常态) |
| `snapshot_own` | 每 tick 一包,unreliable,逐 peer;`{ack_seq, q, c2}`,**每包全量** 99 B(v7 起无差分) |
| `send_input` | 30Hz,reliable,**手打包 42 B/包**(P1 定点化前 46 B);包内两条连续 tick 记录(`PacketInputSource.INPUT_BATCH_TICKS=2`,一条记录 = 1 tick);`st` = 最近成功解码的快照 tick(命中回放时间基准),`ct` = 客户端物理帧号(仍只落位);`held` 的 `BIT_NEED_FULL=512` 为保留位(v7 起恒不置位) |
| 编解码 | `core/net/net_codec.gd` 打包成 `PackedByteArray`(快照 + 输入同模块),RPC 入口解回同形状 `Dictionary` |

## 客户端

- 流程 `main_menu` → `mp_lobby` → `pvp_game`(`pvp_mode = true`)。本地玩家 = C2:`PredictionRollback`(`core/net/prediction_rollback.gd`);预测被证实不动,真性分歧才 `restore(权威态)` 并按序重放未确认输入。容差:位置 `pos_tol = 2.0`、接触期 `contact_pos_tol` 动态 8→48;速度 `VEL_TOL = 20`、接触期 `contact_vel_tol = 400`(2026-10-31:接触期速度分歧是幽灵体 vs 真实身体的碰撞几何噪声)。`contact_pos_tol`/迟滞由 `PredictionContact.contact_tol(rel_speed, anchor_speed, horizon)` 算(drift 取相对/锚点速度大者 ×2 模型系数,离开贴身区后 150ms 内仍按贴身容差)。
- 远端对手 = `PlayerReplica`:位置走 **playout 缓冲插值**(`PLAYOUT_TICKS = 2` ≈ 33ms 缓冲,取样后再 `anchor_to_nearest` 锚回本地玩家最近副本);幽灵碰撞体**不跟插值**,按权威速度外推(≤2 tick / 60px);快照 `type_id = 0` = 空手。副本幽灵碰撞体 `StaticBody2D`(layer 2 / mask 0,3v3 按队配),本地玩家补 `collision_mask |= 2`;渲染层带排在世界的墙体/梯子/建筑层之前(与本体同带)。对手预瞄线不可见(快照 `previewing` 客户端不消费)。
- 离开对局的路径(ESC / MATCH_OVER / 对手离开)都走 `Level0.safe_change_scene`;世界由 `WorldReaper` 分帧拆除。

## 协议与发送纪律

- RPC 通道号唯一来源:[`netplay-rpc-channels.md`](netplay-rpc-channels.md)。定向发送前判活 `NetBus.is_peer_live(id)`;广播前判 `NetBus.all_peers_sendable()`;答复 caller 走 `NetBus.reply`。
- 协议只传 canonical `[0, MAP)` 坐标;跨接缝距离与插值走 `toroidal_delta_px`。
- `beam_fired` 走 `NetBus`(不是 `NetBusExt`);接收端挂错节点 = 静默 no-op。
- 榴弹的权威判定在 `_adjudicate_grenade`:只结算一次直接命中、不销毁子弹。

## 服务端运维面

- 面板:`server/gui/server_panel.tscn` 由 `server_main.gd` 在"大厅分支 + 非 headless"时**代码实例化**(不挂在 `server_main.tscn` 上)。只读大厅状态(房间 / 端口 / worker 存活 / 名单),唯一写操作是关房,走 `teardown_room`。审计:`NetDiag.audit()` 常开(仅非 client 进程),一行一 JSON 写 `<日志目录>/ops-<role>-<pid>-<时间戳>.jsonl`;关窗优雅拆房并写 `lobby_stop`;每局 worker 日志按端口归档。审计事件与字段的权威在 [`tests.md`](tests.md) 的「运维审计通道」一节。
- **日志落盘目录(2026-10-30)**:选择逻辑收在 [`core/net/net_metrics.gd`](../../core/net/net_metrics.gd) 的 `server_log_dir`(纯函数,`-s` 可测)。**导出构建的服务端** = exe 同目录 `log/`(默认开,无需 `--diag`);开发态 / 编辑器 / 客户端 = `user://logs`。同目录里同时落:结构化 `diag-<role>-<pid>-<时间戳>.jsonl`、运维 `ops-*.jsonl`、worker 引擎日志 `worker_<port>.log`(归档保留 20 份)。打包侧由 `build_release.py` 的产物冒烟断言「exe 同目录跑完出现非空 `log/`」。`--netstat` 每秒一行含**下行丢包估计**(world/own 两本账,tick 缺口推算,口径见 `NetMetrics.snapshot_loss`),`--diag` 每秒一条 `snap_rx` 带 `world_lost/own_lost/loss_pct`。

## 测试

`pvp_match_smoke.sh`（建房 → 房主开始 → 输入 → 模拟 → 快照 → 子弹广播，占 7777）= 真链路；默认批里与联机相关的有 `net_wire_smoke`（线格式）/ `input_queue_smoke`（输入队列，`-s`）/ `net_tile_fx_probe`（客户端拆砖粒子表现层，2026-10-26 增）。原 `rpc_channel_contract_smoke` / `room_registry_smoke` / `mode_*_smoke` 已随 2026-10-24 默认批激进削减删除（缺口见 [`registered-debt.md`](registered-debt.md) §九）；原 `pvp_room_smoke.sh` 已删（结构性恒红、毒化真链路批，见 [`registered-debt.md`](registered-debt.md) §二十七）。房间寿命与回局见 [`netplay-rooms.md`](netplay-rooms.md)，断线重连见 [`netplay-reconnect.md`](netplay-reconnect.md)，快照管线见 [`netcode-snapshots.md`](netcode-snapshots.md)。
