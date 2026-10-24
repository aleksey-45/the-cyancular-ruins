# 联机:房间寿命 / 回收判据 / 回大厅后回局

## 对局中的房

- 房活到 worker 进程退出。回收梯 `RoomManager._reclaim_finished_matches` 每 `MATCH_SWEEP_INTERVAL`(30s)一轮,判据 `_match_over(port, pid)` + `WorkerLauncher.pid_alive(pid)`。
- `worker_port <= 0` 或 `worker_pid <= 0` 一律判「没结束」(拉起中窗口);pid 在 `OS.create_process` 成功之后登记。
- 兜底 `_sweep_stale_rooms`:每 `SWEEP_INTERVAL`(600s)扫一次,房龄 > `MAX_ROOM_AGE`(7200s)连 worker 一起杀。1v1 无在局宽限;大乱斗 / 3v3 的在局宽限为 `SWEEP_INTERVAL` + 一局上界(`ROYALE_MATCH_TIME_CEILING` / `TEAM_MATCH_ESTIMATE`,各 1800s)。
- 房记录 `RoomTypes.Room` 字段:`mode / code / host_peer / players / player_role / in_match / worker_port / worker_pid / roster / created_at / is_public / invite_code / team_of / max_players / beta / time_rules / options / map / match_time`;`started` 是 `in_match` 的属性别名。
- `roster` 在开局那一刻由 `freeze_roster(room)` 冻结(`[{role, name}]`);列表行的人数和名字在 `in_match` 时取它。开局后成员转连 worker,`players` 会空。

## 列表与拒绝入房

- 房记录与列表载荷各带 `in_match`;载荷由纯函数 `LobbyRooms.room_list_payload()` / `royale_list_payload()` / `team_list_payload()` 构造。
- 三模式对局中统一拒绝文案「该房间的对局已进行中,无法加入」;`tools/room_sweep_lint.gd` 用源码级断言钉住三条文案。
- 私密房只对持凭据的本人列出(判据 `RejoinRegistry.owns(token, code, now_ms)`);`royale_list` / `team_list` 的 `token` 形参有默认值。

## 端口到 pid

`WorkerLauncher` 维护 port → pid 表:`pid_of(port)`(未登记 / 已归还 = 0)、`static pid_alive(pid)`(`pid <= 0` = false)。`release_now` 同时清端口与 pid。

## 回大厅后回局

- 入口是统一大厅房间列表里「自己那间房」那一行;行渲染与按下共用 `PvpSession.can_rejoin_to(code, mode)`(房号与模式都要对上)。
- 判据顺序:先「是不是我的房 + 凭据还在」,再「`in_match` ⇒ disabled」。本人那一行在对局中也可见、可点。
- 客户端 `LobbyPage.try_rejoin_row(code, in_match, mode)` → `rejoin_request(room_code, token)` → 大厅 `LobbyRooms.on_rejoin_request` 查凭据 → `NetBus.reply(caller, "go_match", role, port)`。
- 客户端认领分叉:有 `PvpSession.rejoin` 时发 `reclaim_role`,否则 `claim_role`。`_do_go_match` 只在真收到新 token 时覆盖 `session_token`。
- 服务端 join 守卫保持「对局中即拒绝」,不含凭据分支;回局查询只走 `on_rejoin_request`。
- 客户端兜底:`_request_rejoin` 发前判活、大厅 15s 无应答、大厅回「回不去了」(`_on_rejoin_denied` 清凭据并重拉列表)。

## 凭据

- `PvpSession`:`token` / `worker_port` / `room_code` / `rejoin` / `room_mode`(凭据属于哪个模式)/ `entry_mode`(进大厅时的初始筛选)。
- `can_rejoin()` / `can_rejoin_to(code, mode)` / `clear_rejoin()` / `note_room(code, mode)`;`reset()` 不清凭据,也不改 `server_address`。
- 凭据死处只有 `clear_rejoin()` 的调用点:换房号或换模式、大厅答「回不去了」、回局 15s 无应答、玩家进了另一间房。
- 表 `server/lobby/rejoin_registry.gd`(`RejoinRegistry`):`token -> {code, role, worker_port, worker_pid, expires_at}`;`TOKEN_TTL_SECONDS = 3600` 只是 GC 上界,「这一局还在不在」由 `worker_pid` 活性回答。
- `RejoinRegistry.decision(entry, code, worker_alive)` 返回 `""` = 放行,否则是拒绝理由;拒绝顺序:凭据不存在 → 房间号不符 → worker 不在。
- 作废该房凭据走 `drop_port(worker_port)`,键是 worker 端口不是房号;`port <= 0` 不清。GC 搭 30s 回收梯(`_reclaim_finished_matches` 首行 `lobby.rejoin.prune`)。

## 已知边界(登记,不修)

- 回局只在宽限期内真正成功:宽限到期后 worker 会 `mark_disconnected` 或收场退进程,大厅仍可能放行,客户端被 `_on_reclaim` 的判据②踢连接。
- pid 复用:`pid_alive` 即 `OS.is_process_running`,误判方向是「多留」而非「错杀」,降级成超龄清扫兜底。
- `_request_rejoin` 的判活假分支只在点行那一刻大厅连接已断时进入,而那一刻会真开一次大厅连接 ⇒ 探针不碰,登记为环境缺口。
- 引擎自身的 `max channels: 0` 报错:回局路径同样会踢连接,已登记、不修。
- `ai_duel` 不发 `session_token`、不调 `_grant_rejoin`,开局即摘房 ⇒ AI 对战局没有回局入口。

## 测试

`tests/probe/rejoin_probe.sh`:真链路三端(c1 离场再回局、c2 见证端、c3 第三人看得见进不去),自当大厅与裁判,端口 29300 / worker 29350,不占 7777。判词 `REJOIN PROBE: ALL-OK`。
