# 联机:断线重连(阶段 2-A / 2-B / 3)

两条路径:路径甲 = 局内闪断后连回同一 worker 端口、重新认领 role,不切场景、不重建世界;路径乙 = 回大厅后凭据回原局,见 [`netplay-rooms.md`](netplay-rooms.md)。

## 令牌与宽限

- token 由大厅生成(`LobbyRooms.new_token()`),经 `session_token` 在 `go_match` 之前发给客户端;客户端 claim 后经 `report_token` 报给 worker,worker 只归档,校验发生在 `reclaim_role`。三条 RPC 都在 `NetBusExt`。
- 宽限期唯一入口 `GraceWindow.DEFAULT_SECONDS`(60s,`core/net/grace_window.gd`,时间由调用方传入)。到点动作由 `GraceWindow.expire_action` 分派:大乱斗 / 3v3 移出对局(`ACTION_REMOVE`),1v1 收场(`ACTION_TEARDOWN`);`server_main._expire_graces` 每秒轮询。
- `server_main._on_peer_left` 只 `_claims.erase(role)` + `_enter_grace(role)`,不销毁玩家节点:分数 / 阵亡 / 血量 / 背包 / 位置 / 世界破坏 / 地面武器都留在进程内存里。
- `_enter_grace` 必须同时 `input_sources[role].reset_state()` 与清空 `_pending_input[role]`;`_on_reclaim` 的接受路径同样处理。

`server_main._on_reclaim` 三条拒绝条件:未开局 / 该 role 不在宽限期 / token 不匹配;任一不满足即 `disconnect_peer`。接受后:重绑 `peer_by_role`、把新 `PacketInputSource` 挂回该玩家节点、清输入队列、`_ack_seq[role] = 0`、`_grace.leave(role)`、`NetBus.reply(caller, "match_start", role, spawn, map)`。

## 客户端

- 触发点只有服务器断开(`NetBus.local_server_message`)。菜单开着时记 `_pending_disconnect`,关菜单由 `_recheck_disconnect()` 补发。
- 两条时间尺度:`RECONNECT_RETRY_MS = 2000`(定时器节拍),`RECONNECT_ATTEMPT_TIMEOUT_MS = 5000`(一次握手寿命);预算 = `GraceWindow.DEFAULT_SECONDS`。同一条连接只发一次 `reclaim_role`;收到 worker 回的 `match_start` 才算成功。
- 成功(`_on_resumed`):`_input_seq` / `_have_prev_seq` / `_prev_sent_seq` / `_input_pair_phase` 归零,重建 `PredictionRollback` 并重新 `bind`、设 `map_px` 与 `ticks_per_record`,再置 `_resync_pull_pending` 并 `NetBus.rpc_id(1, "match_sync")`。
- `_on_snapshot_own` 丢弃 `ack > _input_seq` 的快照(跨纪元残留 ack);`_cancel_reconnect()` 停掉在飞的重连循环,`_abort_reconnect(reason)` 收横幅、`NetBus.stop()`、回主菜单。

## 补态(match_sync)

- `destroyed` = `MatchHost.destroyed_cells()`:当前 `grid` 与建局基线 `_base_grid` 不同的格,顺序确定;空数组不带键。
- 客户端补态路径先 `Level0.reset_destructibles()`,再逐格 `_on_remote_tile_destroyed(cell, true)`;顺序不可换,且只在补态路径做。
- 地面武器「先清后灌」:`_clear_ground_weapons()` 后按 `ground_weapons` 建节点;进场那次本地为空,同一段代码无分支。`_resync_pull_pending` 读一次即清;补态应答不做出生点校正、不发告警。测试:`resync_world_probe.tscn`(还原墙体瓦片层 + `_destructible_sub` 子格两维)、`rollback_fidelity_probe.tscn`(C2 容差与接触提示接线)。

## 状态与横幅

- 服务器把宽限读数经 `_sync_grace_snapshot()` 推进宿主 `grace_snapshot`;`round_state` 的 `grace` 字段(`{role: 剩余秒}`)只在 `MatchState._send_round_state` 并入一次,空表不带键;客户端本地走秒(`GraceWindow.tick_display`)。1v1 / 3v3 不每秒广播 `round_state`;3v3 刻意不消费 `grace`。
- 本地横幅 `ui/hud/status_banner.tscn`(layer 140)由 `PvpMatchClient._subscribe_reconnect()` 实例化;五个转折点:`_begin_reconnect` / `_on_reconnect_retry_tick` / `_on_resumed` / `_cancel_reconnect` / `_abort_reconnect`。
- `opponent_left` 在 1v1 收场分支、`quit(0)` 之前发,只发给 `_claims` 里还在的人,走 `NetBus.reply`。通知先到由 `_match_ended` 挡住重连;断开先到由 `_cancel_reconnect()` 叫停。
