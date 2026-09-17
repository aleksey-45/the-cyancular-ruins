# 断线重连与回局设计（1v1 + 大乱斗）

**日期**：2026-09-17 ｜ **状态**：设计，待评审 ｜ **前置**：无（可在当前 main 上开分支）

用户原话（三段，构成需求）：

> 「重连不是玩家退出了不会立刻结算，而是可以重新加进去吗」
> 「此外为什么 B 不能重新进入房间」
> 「出这份 spec，1v1 也是」

## 0. 决策摘要（用户 2026-09-17 逐条裁定）

| # | 问题 | 裁定 |
|---|---|---|
| 1 | 重连做到哪一层 | **局内自动重连 + 回大厅后能回那局**（不做"worker 崩了也能恢复"） |
| 2 | 宽限期内掉线者的身体 | **留在场上不动**（可被打、可被杀） |
| 3 | 谁有资格 reclaim | **一次性 session token** |
| 4 | 1v1 宽限期内对手看到什么 | **不冻结、不等待**：对手可以随意走动、随意攻击掉线者的身体 |
| 3b | token **由谁生成**（第 3 条与第 1 条的冲突，§3.1） | **大厅生成**，随 `go_match` 一并下发（用户 2026-09-17 追加裁定） |
| 4b | 1v1 宽限期"送分"（§3.8） | **接受送分**：掉线者照常 2s 复活，在线方可反复击杀刷分（用户 2026-09-17 追加裁定） |

★ 第 3 与第 1 条的原始冲突见 §3.1；已按「大厅生成」解决，余下部分按此写。

---

## 1. 现状：为什么今天做不到（事实，全部带行号）

### 1.1 两条链路的根本差异

| 维度 | 大乱斗 | 1v1 |
|---|---|---|
| 一方掉线时 worker | **继续跑**（`server_main.gd:337-349`：`_claims.erase` + `_host.mark_disconnected(role)`；仅 `_claims.is_empty()` 才 `quit(0)`） | **`_host.queue_free()` + `quit(0)`，进程直接死**（`server_main.gd:351-354`） |
| 掉线者的对局状态 | `RoyaleHost.mark_disconnected`（`royale_host.gd:408-430`）：置 `_left`、**`players[role].queue_free()` + erase**、清 `input_sources`/`peer_by_role`；`players.size() < 2` → `_finish_match()` | 无 —— 进程随局一起死 |
| 房间记录 | 开局后仍在 `royale_rooms` 里（`royale_list` 不列 `lobby_rooms.gd:342`、`royale_join` 拒绝 `:297-299`），**全员断开大厅**后走 `on_peer_left` 空房分支拆掉（`:190`） | **第一个 `peer_left` 就拆**（`lobby_rooms.gd:171`：`players.is_empty() or room.started`） |
| 端口归还延迟 | `ROYALE_PORT_REUSE_DELAY = 360s`（`worker_launcher.gd:33`） | `WORKER_PORT_REUSE_DELAY = 30s`（`:26`） |
| 正常终局后 worker | **不退出**（`_finish_match` 只置状态 + 广播，`royale_host.gd:331-334`），继续 60Hz | 也不退出（`match_round.gd:52-53` MATCH_OVER 分支是 `pass`） |

**结论**：大乱斗的"对局还在 worker 内存里活着"这个地基**已经存在**；1v1 没有，得先造。

### 1.2 三处硬堵点（两道链路的共同障碍）

**① 开局后到达的 `claim_role` 被静默吞掉。** `_begin_match` 里主动断开了信号（`server_main.gd:304-305`）：

```gdscript
_match_started = true
NetBus.role_claimed.disconnect(_on_role_claimed)   # ← 此后 claim 无人监听
```

于是 `_on_role_claimed` 的防串线闸门（`server_main.gd:269-274`）**在信号路径上不可达**：既不解包、也不 `disconnect_peer`、也不回包。客户端只能等 `lobby_page.gd:335-339` 的 **25s claim 超时**回大厅。

**② 身份不可验证。** role 从不重排也从不显式释放；`_claims`（`server_main.gd:14`，role→peer）在 worker 进程内、无回写大厅的通道。守卫 `_claims.has(role) and _claims[role] != caller` 的语义是"先到先得 + 一律拒绝"，没有"原主可以回来"这一态。

**③ 对局状态只在 worker 进程内存**：`_scores` / `_deaths` / `_left` / `_match_time` / `grid` 破坏态 / `TileDefs.hp_grid`（进程级 static）/ `ground_weapons` 全表 / `_next_ground_inst` / `_ack_seq`。**无落盘、无序列化、无回大厅通道**（`MatchHost` 没有任何 `save`/`restore` 方法）。

### 1.3 顺手挖出的两个既有缺陷（与本设计相邻，建议一并修）

- **`pvp_game.gd:228-242` 的「对手已离开 → 2.5s 回主菜单」不可达**：`NetBus.opponent_left` 这个 RPC（`net_bus.gd:322-324`）在**服务端全仓没有任何调用点**。CLAUDE.md 把它列为"三条离开对局世界的路径"之一，实际不是。
- **对局中服务器断线，客户端无任何提示**：`local_server_message("服务器断开")`（`net_bus.gd:65`）的订阅者只有 `scenes/lobby_page.gd:66`；对局场景没人接。表现是快照停更、输入自停（`pvp_match_client.gd:118` 的 `can_send_to_server()` 转 false），玩家卡在一个静止的世界里，只能按 ESC 自己退。

---

## 2. 目标与非目标

**目标**

1. 客户端与 worker 的连接**闪断**（丢包超时、临时网络故障）后，能在宽限期内**自动回原局**，不丢对局进度。
2. 玩家**退回主菜单/进程重启**后，仍能从大厅**回到原局**。
3. 两条链路（1v1 / 大乱斗）都支持，且**语义一致**：掉线期间对局继续，掉线者的身体留在场上。

**非目标（明确不做）**

- worker 进程崩溃后的恢复（需要状态落盘，属另一量级）。
- 观战、语音。
- 掉线者**离开后**（宽限期超时）的回归 —— 超时即按现有语义"移出对局"。
- 反作弊级别身份验证（token 是"防误顶替"，不是"防恶意"）。

---

## 3. 设计

### 3.1 会话令牌：**由大厅生成**（用户 2026-09-17 裁定）

原始需求里两条互相冲突：**worker 生成 token** 与 **回大厅后能回那局**。冲突点在于 —— worker 的 token **大厅不知道**，客户端拿着它回大厅时，大厅无法把它对回任何一局。

**裁定：改由大厅生成。** 与原始措辞只差"谁生成"，语义完全不变（仍是一次性、仍只有原客户端拿得到），但三方天然一致：大厅知道、客户端知道、worker 在 claim 时被同步告知。

**流程**

1. **生成**：大厅在拉起 worker 的那两处（`room_manager.gd:45-75` 的 `royale_start` / `:129-158` 的 `royale_start_ai` / `:161-182` 的 `_start_match`）为每个参战 role 生成一份 token，存进房间记录（新增字段 `tokens: {peer → token}`）。
2. **下发**：客户端转连 worker **之前**，经 `NetBusExt` 发给该 peer；客户端存进 `PvpSession.token`。
3. **带过去**：客户端转连 worker 后，随 claim 一起把 token 报给 worker；worker 存 `_tokens[role] = token`，供日后 `reclaim_role` 核验。

★ **不得改 `NetBus` 的方法表。** CLAUDE.md 的硬纪律：原 `NetBus` 保持与原版服务端逐字节一致，改它的方法表会让与之的 RPC 全部失联。所以：

- `go_match(role, port)`、`claim_role(role, name)` **签名一律不动**；
- token 走 `NetBusExt` 的两条新 RPC（`session_token(token)` 大厅→客户端、`report_token(token)` 客户端→worker），与现有的 `player_options` 同款路径（`lobby_page.gd:279-284` 就是 `NetBus` + `NetBusExt` 两条包一起发的先例）。
- 好处：对原版 worker（没有 `NetBusExt` 节点）token 静默丢弃 → 优雅降级成今天的"不能重连"，不会把原版链路打坏。

**Token 规格**：`String`，16 个 hex 字符（`%016x` 拼两次 `randi()`），**每局每 role 一份**，随房间记录一起生灭。

### 3.2 worker 侧：宽限期状态机

新增（`server/server_main.gd`，worker 进程内）：

```gdscript
const GRACE_SECONDS := 30.0      # 宽限期。★ 唯一入口,调它改时长
var _tokens: Dictionary = {}     # role(int) -> token(String),claim 时从客户端带来
var _grace_until: Dictionary = {}# role(int) -> 到期时刻 ms(不在表里 = 在线)
```

**掉线时（`_on_peer_left`）**：

- 大乱斗分支（现 `:337-349`）**不再**直接 `mark_disconnected`，改为：
  1. `_grace_until[role] = Time.get_ticks_msec() + int(GRACE_SECONDS * 1000.0)`
  2. **把该 role 的输入源置空**（关键，见下）
  3. `peer_by_role.erase(role)`（老 peer 已死，留着会让 `_rpc_all` 往死连接发包）
  4. `_broadcast_round_state()`（HUD 需要一个"某人掉线中"的可见态，见 §3.6）
  5. **不调 `mark_disconnected`、不动 `players`** —— 身体留在场上（你的裁定 2）
- 1v1 分支（现 `:351-354`）**删掉 `quit(0)`**，同样进宽限。

★ **输入源必须显式置空**：`PacketInputSource` 在队列空时**沿用上一包（held）**（`net_bus`/`match_host.gd:131-148` 的"缺包沿用 held"纪律）。不置空的话，掉线者的身体会**保持他断开前最后一帧的输入**——一直朝那个方向跑或一直开枪。做法：`input_sources[role].reset_state()`（`NetworkInputSource.reset_state()` 连 held/axis 一起清，已有）+ 清空 `_pending_input[role]`。

**宽限期内每秒轮询（`_process`）**：

```gdscript
for role in _grace_until.keys():
    if Time.get_ticks_msec() >= _grace_until[role]:
        _grace_until.erase(role)
        # 到点仍未回来 → 走现有语义
        if _royale:
            _host.mark_disconnected(role)      # 移出对局、排行榜标「离开」、<2 人终局
        else:
            # 1v1:对手若还在,判其胜;再拆局退进程
            _host.queue_free(); get_tree().quit(0)
```

**宽限期内该 role 回来了** → 见 §3.3；清 `_grace_until[role]`。

### 3.3 worker 侧：`reclaim_role` 入口

**新增一条 RPC，走 `NetBusExt`**（旁路扩展协议）：`reclaim_role(role: int, token: String)`。

★ **不要改 `NetBus` 的方法表** —— CLAUDE.md 明确：原 NetBus 保持与原版服务端逐字节一致，改它的方法表会让与之的 RPC 全部失联。扩展能力一律进 `NetBusExt`（对原版 worker 不存在 → 静默丢弃、优雅降级）。

worker 侧处理（`server_main.gd`，与 `_on_role_claimed` 并列）：

```
if not _match_started: 拒绝(没开局,走正常 claim)
if not _grace_until.has(role): 拒绝(该 role 没在宽限期里 = 没掉线,或已超时移出)
if _tokens.get(role, "") != token: 拒绝(令牌不对)
→ 接受:
    _claims[role] = caller
    peer_by_role[role] = caller           # 重新绑定
    input_sources[role] = 新建 PacketInputSource(role, caller)   # 换掉死连接
    _pending_input[role] = []             # 清残留
    _ack_seq[role] = 0                    # C2 锚点重协商(客户端 rollback ring 已失)
    _grace_until.erase(role)
    回一条 match_resumed(role, spawn?, map_path) 给该 peer
    _broadcast_round_state()              # HUD 摘掉「掉线中」标记
```

★ **玩家节点不重建**：因为身体从未销毁（裁定 2），服务端的对局状态（分数/阵亡/位置/血量/背包/世界破坏/地面武器）**全都不用恢复** —— 这是本设计最省的一处，比"销毁后重建"便宜一个数量级。

### 3.4 客户端侧：两条回局路径

**路径甲 —— 局内自动重连（不离开场景）**

- `pvp_match_client` / `pvp_game` 监听 `NetBus` 的服务器断开（今天无人接，见 §1.3）。
- 断开后：显示一个"重连中…"的轻提示（复用 `PvpSession`/HUD 一块小底板），**不切场景**，本地世界原样保留。
- 自动重试：`NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)`，重试间隔 2s、总时长 = 服务器宽限期（30s）内尽力。
- 连上后立刻 `NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)`。
- 成功 → 摘提示，继续；失败/超时 → 回主菜单（今天的行为）。

★ 这条路径下**客户端的世界没有被重建**（场景没切），所以破坏态、地面武器、副本位置全都还在原地，只需等快照续上。

★ **重连成功后客户端必须重置自己的 C2 状态**：`PredictionRollback` 的输入环与 `_input_seq` 要清空并与服务器新协商的 `_ack_seq` 重新对齐。不清的话，头几帧会把环里**断线前**那些记录当成"未确认输入"重放，与服务器已重置的锚点错位 → 表现为一连串无谓的回滚（可能持续增长）。这条要在 `reconnect_probe` 里量（断言重连后回滚次数**不持续增长**）。

**路径乙 —— 回大厅后回局（重建场景）**

- 客户端记住 `(server_address, worker_port, role, token, room_code)`（`PvpSession` 新增字段；`room_code` 曾被删除，需重新加入）。
- 从主菜单进"多人对战/大乱斗"时，若 `PvpSession` 里有一条**未过期**的回局记录 → 大厅页给出一个入口：「你有一局在进行中，返回对局」。
- 点它 → 向大厅发 `rejoin_request(room_code, token)` → 大厅校验（房间还在 + token 匹配 + worker 端口有效）→ 回 `go_match(role, port, token)`（复用现有载荷形状）→ 客户端照常转连 + `claim_role`。
- ★ **重建场景需要世界破坏态**：客户端重进 `pvp_game.tscn` 会从 `map_path` 重建初始地图，而服务器上是破坏后的 `grid` → 两端发散。**必须让 `match_sync` 带上破坏态**（见 §3.5）。

### 3.5 `match_sync` 增加「世界破坏态」

`MatchHost` 有 `grid`（当前）与 `_base_grid`（建局基线深拷贝）。二者差异 = 被摧毁的格。

- 新增 `MatchHost.destroyed_cells() -> Array[Vector2i]`：遍历 `grid`，凡是与 `_base_grid` 不同（或值为 `MapFormat.EMPTY` 而基线非空）的格即为已摧毁。
- `server_main._on_match_sync` 的应答里加一个 `destroyed` 字段（`Array[Vector2i]`）。
- 客户端进场时（`pvp_match_client` 处理 `match_sync`）逐格调 `TileDefs.damage_tile(cell, 9999, "explosion")` —— **复用现有的 `tile_destroyed` 处理路径**（那条路径已经能把瓦片渲染 + 碰撞层清干净），不另写一套。

★ 上限：一局最多 125×75 = 9375 格，全被拆也是 9k 条 `Vector2i`。unreliable/reliable 都能扛，但应**只在有破坏时才带该字段**（空数组不带），避免每局固定多几 KB。

### 3.6 HUD：掉线中 / 重连中

- **服务端**：`round_state` 载荷加一个 `grace` 字段（`{role: 剩余秒}`，仅在有宽限角色时带）。大乱斗排行榜的行状态增加一档「掉线中」；1v1 的记分条旁显示对手状态。
- **客户端本身**：路径甲期间本地显示「重连中…」（自己知道，不需要服务器广播）。

### 3.7 大厅侧：房间记录在局内保留

现在两条链路都会在客户端转连 worker 时**立刻拆房**，这是有意的（防 1/2 幽灵房与连环僵尸 worker，`lobby_rooms.gd:167-170` 注释）。要支持回局，改成"**在局内保留到宽限期结束**"，同时补上替代的回收机制。

- `Room` / `RoyaleRoom` 新增：`in_match`（1v1 也要，今天只有大乱斗有）、`tokens: {peer → token}`、`grace_until: int`。
- `on_peer_left`：房间 `in_match` 时**不再拆房**，只 `grace_until = now + GRACE + 余量`；`started` 那条关房规则收窄为"未 `in_match` 的 `started` 房"（配对瞬间掉线仍要关，防幽灵房）。
   ★ 大乱斗的 `in_match` 在 `room_manager.gd:62` 置位；1v1 目前只置 `Room.started`（`room_manager.gd:164`），要补一个等价标记。
- **回收**：由 sweep 承担 —— `in_match` 且 `now > grace_until` → `teardown_room(KILL)`（杀 worker + 归还端口）。今天 sweep 对 1v1 与等待中的大乱斗房**没有在局宽限**（`room_manager.gd:236-239` 已登记为未修），本设计顺带把它补上。
- **端口归还延迟**：1v1 的 `WORKER_PORT_REUSE_DELAY = 30s` **短于**宽限期 → 必须提到 ≥ `GRACE + 余量`（建议与 royale 一致用 360s，或至少 120s）。否则宽限期内端口被发给新 worker → 串线（`server_main.gd:269-274` 那条守卫正是为此）。
- **回局入口**：新增 `NetBusExt.rejoin_request(room_code, token)` → 校验通过则回 `go_match(role, port, token)`。

### 3.8 1v1 的特殊语义（对应你的裁定 4）

裁定 4 = 「对手可以随意走动，随意攻击对手的身体」。落到 1v1 的三局两胜制上有一个**必须知道的后果**：

- 掉线者的身体留在场上（裁定 2）→ **如果它照常 2s 复活**（`MatchRound._handle_respawns` 遍历 `players`，掉线者仍在 `players` 里），那么在线的一方可以**反复击杀它拿分** → 5 杀赢一局 → 三局两胜赢下整场。也就是说**宽限期实际上是在线方的"送分窗口"**。
- 另一种做法：掉线者倒地后**不复活**（在 `_handle_respawns` 里跳过 `_grace_until` 里的 role）→ 在线方只能拿 1 分，这一局无法推进，宽限期到点再判。

**两条都符合"可被打可被杀"，差别在宽限期的意义。**

★ **裁定（用户 2026-09-17）：取「照常复活」，送分就送分。** 所以：

- `_handle_respawns`（`match_round.gd:57-61`）**不加**任何宽限期特判 —— 掉线者倒地后照常 2s 复活；
- 在线方可以在 30s 宽限期内反复击杀刷够 5 分、拿下这一局，乃至三局两胜赢下整场。**这是已知且被接受的行为**，不是缺陷；
- 因此宽限期默认值 `GRACE_SECONDS = 30` 不宜再放大（它现在同时是"对手的送分时长"）。

---

## 4. 状态恢复清单

因为**身体不销毁**（裁定 2），服务端几乎不用恢复任何东西。真正的清单：

| 状态 | 谁持有 | 掉线时 | 重连时 |
|---|---|---|---|
| 玩家节点（位置/血量/背包/倒地） | worker `players[role]` | **不动** | **不动** ✓ |
| `_scores` / `_deaths` / `_left` | worker 内存 | **不动** | **不动** ✓ |
| `_match_time` / `_round_state` | worker 内存 | **不停**（对局继续） | **不动** ✓ |
| 世界破坏态 / `TileDefs.hp_grid` | worker 内存 | **不动** | **不动** ✓（路径甲）；路径乙靠 `match_sync` 的 `destroyed` 下发 |
| 地面武器表 | worker 内存 | **不动** | **不动** ✓（路径甲）；路径乙靠现有 `ground_weapons` 载荷 |
| `peer_by_role[role]` | worker | erase | **重绑新 peer** |
| `input_sources[role]` | worker | `reset_state()` 置空 | **换新 PacketInputSource** |
| `_pending_input[role]` | worker | 清空 | 清空 |
| `_ack_seq[role]` | worker | 保留 | **重置 0**（客户端 rollback ring 已失，锚点重协商） |
| 客户端本地世界 | 客户端 | 路径甲：不动 / 路径乙：重建 | 路径乙需 `destroyed` |

---

## 5. 超时与边界

- `GRACE_SECONDS = 30`（唯一入口）。与 `WorkerLauncher` 的端口延迟必须满足 `端口延迟 ≥ GRACE`（见 §3.7）。
- **宽限期不计入 `_match_time`**：大乱斗的限时继续走（对局不停）。
- **宽限期与 sweep 的宽限要区分**：sweep 的是"房龄"，这里是"角色掉线"。
- **同一个 role 被两个人同时 reclaim**：`_tokens` 比对本就唯一，后者被拒（并 `disconnect_peer`，防串线）。
- **worker 在宽限期内退出**（例如大乱斗剩最后一人且他也掉线）：客户端重连会连不上 → 走"重连失败 → 回主菜单"。
- **客户端重连成功但服务器已把它移出**（宽限期到点）：`reclaim_role` 返回失败 → 客户端回主菜单并提示"对局已结束"。

---

## 6. 探针与文档

- **`tests/reconnect_probe.tscn`（新）**：真大厅 + 真 worker + 真客户端。脚本化地掐掉一个客户端的连接（或直接 `NetBus.stop()` 再重连），断言：① 宽限期内该 role 的身体**留在场上**且**输入被冻结**（位置不再变化）；② `reclaim_role` 带对 token 成功、带错 token 被拒；③ 重连后 `_scores`/`_deaths` 未变；④ 宽限期到点仍不回来 → 移出对局。
  ★ 必须有**反向断言**：错 token 必须被拒（否则"谁都能顶替"这条会假绿）。
- **`tests/rejoin_probe.tscn`（新，路径乙）**：客户端回主菜单后再经 `rejoin_request` 回局，断言重进场景后**世界破坏态与服务器一致**（拆两堵墙再回局，比对两端）。
- **扩展 `tests/unstick`… 无关**。扩展 `tests/royale_disconnect_count_probe`：宽限期内的 role 不应触发终局（现在掉线即 `mark_disconnected`，改后 30s 内不终局）。
- **CLAUDE.md**：§网络与 PvP 新增「断线重连与回局」一节；把 §1.3 那两个既有缺陷一并记上（或在本批修掉后记为已修）。

---

## 7. 分阶段实施建议

| 阶段 | 内容 | 独立可验收 |
|---|---|---|
| **1** | token（大厅生成，随 `go_match` 下发，`claim_role` 带上）+ worker 宽限期状态机 + `reclaim_role` + 客户端路径甲（局内自动重连）+ 1v1 不再 `quit(0)` | 是：闪断后自动回局 |
| **2** | 大厅房间在局内保留 + `rejoin_request` + `match_sync` 带 `destroyed` + 客户端路径乙 | 是：回主菜单后能回那局 |
| **3** | HUD「掉线中／重连中」+ §1.3 两个既有缺陷（`opponent_left` 不可达 / 断线无提示） | 是：可见性与兜底 |

★ **1v1 必须先做阶段 1 里"删掉 `quit(0)`"那一步**，否则 1v1 连地基都没有。

---

## 8. 明确不做

- worker 崩溃后的恢复（要落盘/回传，另一量级）。
- 观战、语音。
- 宽限期超时后的回归。
- 反作弊级身份验证。
- 改 `NetBus` 的方法表（扩展一律走 `NetBusExt`）。

## 9. 已知风险

1. **端口复用竞态**：宽限期 ≥ 端口延迟这条不成立时，新 worker 会拿到旧端口 → 重连的客户端连到**别的局**。`_on_role_claimed`/`reclaim_role` 的 token 校验能挡住（token 不匹配即拒），但表现为"莫名其妙连不上"。
2. **1v1 宽限期送分**（§3.8）：**已由用户裁定接受**（取"照常复活"），在线方可在宽限期内刷分赢下整场。此处只作为"设计上有意为之"记录，不是待修项 —— 但**宽限期时长因此不宜放大**。
3. **路径乙的世界一致性**：`destroyed` 只覆盖瓦片破坏；**子弹、爆炸中的榴弹、正在下落的武器**不恢复（瞬态，可接受，但重进瞬间会看到"墙已破而子弹没了"）。
4. **`_ack_seq` 重置**会让客户端在重连后的头几帧做一次全量 rollback（C2 的既有行为，应能收敛；需在探针里确认回滚次数不持续增长）。
