# 联机:RPC 通道划分表（★ 单一来源）

> **本文件从 [`netplay.md`](netplay.md) 拆出**（2026-10-13,理由同上）。**它是通道号的唯一来源** ——
> 代码里的 `@rpc("any_peer", "call_remote", "reliable", N)` 与 `rpc_channel_contract_smoke` 都以此为准。
> ★ 任何冲突**以源码为准**（`server/match/match_snapshot.gd` 与相关脚本）。

### RPC 通道划分表(★ 单一来源)

> **为什么**:全仓 `@rpc` 原先**无一例指定通道** ⇒ 可靠流量全挤在一条道上:一次 `bullet_spawn` 的
> **重传**会顶住它后面**所有**可靠事件(含 10Hz 状态镜像)。按**流量类别**分流后,"一次性可靠载荷"的重传
> **不再堵住**"高频输入 / 状态镜像 / 会话序列"。

> ★★ **通道号怎么映到 ENet(读引擎源码得的,不是猜的)** —— `modules/enet/enet_multiplayer_peer.cpp::put_packet`:
> ```cpp
> int channel = SYSCH_RELIABLE;              // 0
> switch (get_transfer_mode()) {
>     case TRANSFER_MODE_UNRELIABLE: channel = SYSCH_UNRELIABLE; break;  // 1
>     case TRANSFER_MODE_RELIABLE:   channel = SYSCH_RELIABLE;   break;  // 0
> }
> if (tr_channel > 0) { channel = SYSCH_MAX + tr_channel - 1; }        // = tr_channel + 1
> ```
> ⇒ **`transfer_channel = 0` 不是"第 0 条用户道",而是"系统默认"**:引擎自己就按可靠性分流
> (**reliable → ENet 0 / unreliable → ENet 1**)。★ 所以 **unreliable 的快照本来就已经与可靠载荷隔离**,
> **不要**给它 `transfer_channel = 1` —— 那会把它从系统 unreliable 道挪到用户道 ENet 2,是一次
> **没有理由的行为改变**(本批差点这么写,已订正)。真正需要分流的是**可靠流量内部**。

> ★★ **分道的判据(比"按类别分"更硬的一条)**:**凡是与「会话 / 回局生命周期」成序列的消息,一律留控制道。**
> 因为跨通道**不保序** —— 例:`round_state` 必须排在 `match_start`/`go_match`(切场景)**之后**,而它是
> **变更时发送**(非周期)⇒ 一旦被切场景那条超越,客户端在还没进对局场景时收到它 ⇒ 处理节点不存在 ⇒
> **那次宣告永久丢失**(下一次要等下一次变更)。同理 `*_options`/`peer_hues`/`room_map` 是**大厅期**的会话消息。
> ⇒ 只有**比赛期内的高频 FX / 生成事件**(子弹、光束、拆墙、命中、击杀、武器增删)才进 ENet 4。

> **`@rpc` 的写法(2026-10-08 实测 + 官方文档)**:签名 `@rpc(mode, sync, transfer_mode, transfer_channel)`,
> 四参**全写**:`@rpc("authority", "call_remote", "reliable", 3)`。实测两条:① 只写三参并把 int 放第 3 位
> 会被引擎拒 —— `Parse Error: Invalid argument for annotation "@rpc": argument 3 should be "String" but is "int"`;
> ② 四参形态解析通过。官方文档补充:**`mode`/`sync`/`transfer_mode` 三个字符串的顺序无关**(按集合匹配),
> 而 **`transfer_channel` 必须是最末那个 int** ⇒ 中间项不能省。`sync` 写 `"call_remote"` 是**默认值**,
> 语义不变(本表**只加通道**,不动 mode/transfer_mode)。

> **★ 可观测性上限(照实)**:通道号**无法在运行期回读** —— `GDScript.get_script_method_list()` 的元素键只有
> `["name","args","default_args","flags","id","return"]`,**没有** `rpc_config`。⇒ 唯一能自动化的判据是
> **本表 ↔ 声明的文本对账**(代理判据,见 [`tests/smoke/rpc_channel_contract_smoke.gd`](../../tests/smoke/rpc_channel_contract_smoke.gd));
> 要**行为级**证明"分流真的生效",需要两个 peer 分别占不同通道对打(今天**没有**这条路径,登记为覆盖上限)。

> **作用域**:产品**声明 59 条**(`net_bus.gd` 28 + `net_bus_ext.gd` 31)。`reconnect_smoke.gd`（已删·2026-10-09） 的
> **13** 条是测试桩自己的 RPC ⇒ **不在作用域内**。★ 裸 `grep -rn "@rpc("` 还会多出 `server/match/match_state.gd:219`
> 那条**注释**与 `.superpowers/` 备份目录 ⇒ **别拿裸 grep 的行数当作用域**。

> **通道容量**:`core/net/net_bus.gd` 的 `const ENet_CHANNELS := 4` 传给 `create_server/create_client`,而引擎会
> 自己 `+ SYSCH_MAX(2)` ⇒ ENet 实际有 6 条道(0~5),`transfer_channel` 可用 1~4。本表最大用 3 ⇒ 落在 ENet 4 ✓。

| `transfer_channel` | 实际 ENet 道 | 语义 | 为什么这样分 | 该通道上的 RPC(逐条点名) |
|---|---|---|---|---|
| **0**（默认） | reliable→**0** / unreliable→**1** | 关键握手 / 会话序列 / 生命周期宣告 **+ 全部快照** | ★ 走**系统默认**(reliable 0 / unreliable 1):快照**已经**与可靠载荷隔离,不需要用户通道;**且成序列的消息必须同一条道**(跨通道不保序) | `ai_duel` / `claim_role` / `create_room` / `go_match` / `join_room` / `list_rooms` / `lobby_name` / `match_options` / `match_start` / `match_sync` / `match_sync_data` / `opponent_left` / `peer_hues` / `peer_info` / `ping` / `player_options` / `pong` / `reclaim_role` / `rejoin_denied` / `rejoin_request` / `report_token` / `room_created` / `room_joined` / `room_list` / `room_map` / `round_state` / `royale_create` / `royale_join` / `royale_leave` / `royale_list` / `royale_rooms` / `royale_start` / `royale_start_ai` / `server_message` / `session_token` / `snapshot_own` / `snapshot_world` / `suicide_request` / `team_create` / `team_join` / `team_leave` / `team_list` / `team_pick` / `team_rooms` / `team_start` |
| **1** | **2** | 60Hz 输入 | 60Hz 且单向高频;与一次性载荷分开后,一次重传不再顶住输入 | `send_input` |
| **2** | **3** | 10Hz 状态镜像 | 10Hz 状态镜像;它们**后面的东西等不起**,而载荷相对小,单开一条道 | `royale_room_state` / `team_room_state` / `time_state` |
| **3** | **4** | 比赛期内的一次性 FX / 生成事件 | 允许重传,但**别堵住别人** —— 这就是本表存在的理由;只放**比赛期内**的高频事件 | `beam_fired` / `beam_fired` / `bullet_spawn` / `hit_confirm` / `hit_event` / `kill_event` / `sub_destroyed` / `tile_destroyed` / `weapon_removed` / `weapon_spawned` |

**合计 59 条**:`transfer_channel` 0 = 45 / 1 = 1 / 2 = 3 / 3 = 10。

★ **表里 58 个方法名、声明 59 条** —— 差的那一条是**刻意的重名**:`beam_fired` 在 `net_bus.gd`(248)
与 `net_bus_ext.gd`(41) **各声明一次**(`net_bus_ext.gd` 那份自己的注释写着"原版 NetBus 逐字节不动,
新 RPC 进 NetBusExt" ⇒ ext 那份是**遗留**)。这件事**本仓栽过**:重名 = 接收端挂错节点 = **静默 no-op**,
裁定见 [`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd)(**必须走 NetBus**,不是 NetBusExt)、
[`scenes/pvp_game.gd`](../../scenes/pvp_game.gd)(发送端走 NetBus)、判据见
`kh_l6_probe.gd`（已删·2026-10-09）(**同行**必须含 `NetBus.rpc_id(`)。
⇒ **两份必须给同一通道**(今天都是 3),`rpc_channel_contract_smoke` 把"重名集合恰好 = {beam_fired}"
**钉成一条断言** —— 新出现一个重名、或 beam_fired 被删掉一份,都会红。
