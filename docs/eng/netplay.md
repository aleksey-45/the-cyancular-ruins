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
- `LobbyRooms` 是门面(`Node`),保留 `rooms` / `royale_rooms` / `team_rooms` 三个只读视图;1v1 两人就绪经 `pairing_ready` 信号交给 `RoomManager`。

## 端口池与拆除

- 端口池单一来源 `server/lobby/worker_launcher.gd`:`WORKER_PORT_BASE = 7800`、`WORKER_PORT_SPAN = 500` ⇒ `[7800, 8300)`;分配用递增游标 + 占用集合(`pick_port()`)。
- 拆除唯一收口 `LobbyRooms.teardown_room`;形态 `TEARDOWN_DELAYED`(默认)/ `TEARDOWN_ABORT` / `TEARDOWN_KILL`。端口归还延迟由 `ModeRoomRules.port_return_seconds(mode)` 给三档:`WORKER_PORT_REUSE_DELAY` = 120s,`ROYALE_PORT_REUSE_DELAY` / `TEAM_PORT_REUSE_DELAY` = 360s。
- `tools/room_sweep_lint.gd` 钉住:端口归还、注册表删除、凭据作废只出现在 `teardown_room` / `_release_port_later` 内。

## 开局链路

1. 大厅建房 / 加入并写房间记录;1v1 两人、大乱斗房主开始、3v3 两队各 3 人。
2. `RoomManager` 冻结名单(`freeze_roster`)、`pick_port()`、`OS.create_process` 拉起 `--headless --worker --port P`;worker 引擎日志写 `user://logs/worker_<port>.log`,按端口归档保留 20 份。
3. 大厅先发 `session_token`,再发 `go_match(role, port)`。
4. 客户端断开大厅、连 worker 端口、`claim_role(role, name)`;收齐 role 后 `MatchBootstrap.start_on` 建局。对局场景 `_ready` 末尾 `NetBus.rpc_id(1, "match_sync")` 拉 `match_sync_data`(昵称 / 色相 / 选项 / role 集合 / 出生点 / 地面武器 / 已拆格)。

## 一局之内

- 地图:默认 `MatchBootstrap.PVP_MAP = res://maps/newfactory.cyrm`;房主上报的 `player_options.map` 经 `MapCatalog.resolve_pvp_map()` 校验(只认 `res://maps/*.cyrm`、拒 `..`、须有双出生点),不合规回落默认图。
- `MatchHost` 建世界(只碰撞不渲染)+ 每 role 一份 `player.tscn`,注入 `PacketInputSource`。
- 回合:`MatchState.RoundState` COUNTDOWN → PLAYING → ROUND_OVER → MATCH_OVER;`KILLS_TO_WIN = 5`、`ROUNDS_TO_WIN = 2`、`COUNTDOWN_TIME = 3.0`、`ROUND_OVER_TIME = 4.0`、`RESPAWN_DELAY = 2.0`。击杀记给对方(倒地边沿,不分死因);换局 `_side_swap`。COUNTDOWN 双端禁移动 / 开火:服务器清输入队列并 `reset_state()`,客户端 `InputSource.frozen`。
- 换局:服务器 `_reset_world_and_clear_dynamics()` 还原可破坏砖与子格 HP 基线、清子弹、重置地面武器;客户端同刻 `Level0.reset_destructibles()`。

## 频率与载荷

| 项 | 值 |
|---|---|
| 物理 tick | 60Hz |
| `snapshot_world` | 30Hz,unreliable;`SNAPSHOT_HZ = 30`、`SNAPSHOT_STRIDE = 2` |
| `snapshot_own` | 30Hz,unreliable,逐 peer;`{ack_seq, q, c2}` |
| `send_input` | 30Hz,reliable;一条记录覆盖 2 个物理 tick(`PacketInputSource.TICKS_PER_RECORD`) |
| 编解码 | `core/net/snapshot_codec.gd` 打包成 `PackedByteArray`,RPC 入口解回同形状 `Dictionary` |

## 客户端

- 流程 `main_menu` → `mp_lobby` → `pvp_game`(`pvp_mode = true`)。本地玩家 = C2:`PredictionRollback`(`core/net/prediction_rollback.gd`);预测被证实不动,真性分歧才 `restore(权威态)` 并按序重放未确认输入。容差 `pos_tol = 2.0`,接触期 `contact_pos_tol = 8.0`。
- 远端对手 = `PlayerReplica`:直接渲染最新快照(无 playout / 插值缓冲);目标与幽灵体都经 `anchor_to_nearest` 锚到本地玩家最近副本;快照 `type_id = 0` = 空手。副本幽灵碰撞体 `StaticBody2D`(layer 2 / mask 0),本地玩家补 `collision_mask |= 2`;对手预瞄线不可见(快照 `previewing` 客户端不消费)。
- 离开对局的路径(ESC / MATCH_OVER / 对手离开)都走 `Level0.safe_change_scene`;世界由 `WorldReaper` 分帧拆除。

## 协议与发送纪律

- RPC 通道号唯一来源:[`netplay-rpc-channels.md`](netplay-rpc-channels.md)。定向发送前判活 `NetBus.is_peer_live(id)`;广播前判 `NetBus.all_peers_sendable()`;答复 caller 走 `NetBus.reply`。
- 协议只传 canonical `[0, MAP)` 坐标;跨接缝距离与插值走 `toroidal_delta_px`。
- `beam_fired` 走 `NetBus`(不是 `NetBusExt`);接收端挂错节点 = 静默 no-op。
- 榴弹的权威判定在 `_adjudicate_grenade`:只结算一次直接命中、不销毁子弹。

## 服务端运维面

- 面板:`server/gui/server_panel.tscn` 挂在 `server_main.tscn` 上;`DisplayServer.get_name() == "headless"` 时不实例化。只读大厅状态(房间 / 端口 / worker 存活 / 名单),唯一写操作是关房,走 `teardown_room`。审计:`NetDiag.audit()` 常开(仅非 client 进程),一行一 JSON 写 `user://logs/ops-<role>-<pid>-<时间戳>.jsonl`;关窗优雅拆房并写 `lobby_stop`;每局 worker 日志按端口归档。审计事件与字段的权威在 [`tests.md`](tests.md) 的「运维审计通道」一节。

## 测试

`pvp_room_smoke.sh`(建房 / 加入 / `go_match`,占 7777)、`pvp_match_smoke.sh`(输入 → 模拟 → 快照 → 子弹广播)、`rpc_channel_contract_smoke.gd`(通道文本对账)、`room_registry_smoke.gd` / `mode_*_smoke.gd`。房间寿命与回局见 [`netplay-rooms.md`](netplay-rooms.md),断线重连见 [`netplay-reconnect.md`](netplay-reconnect.md),快照管线见 [`netcode-snapshots.md`](netcode-snapshots.md)。
