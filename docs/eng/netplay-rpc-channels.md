# 联机:RPC 通道划分表（★ 单一来源）

通道号以本表为准;代码里的 `@rpc("any_peer", "call_remote", "reliable", N)` 按本表对账。★ **单一真相源 / 对账入口 = `tools/gen_rpc_channel_table.py --check`**:扫两个 autoload 的行首 `@rpc(...)` + 紧随的 `func 名(`,与本表逐项比对;漂移逐项打印差异 + exit 1,一致打印 `OK` + exit 0;`--write` 按代码幂等重写表的 RPC 列与合计数字。原 `-s` 文本对账守卫(`rpc_channel_contract_smoke`)随 2026-10-24 默认批削减删除,由本工具接管(历史削减记录见 [`registered-debt.md`](registered-debt.md));它只核文本形态,不证明运行期派发(保证边界见「声明与对账」)。

## 映射
`modules/enet/enet_multiplayer_peer.cpp::put_packet`:

```cpp
int channel = SYSCH_RELIABLE;              // 0
switch (get_transfer_mode()) {
    case TRANSFER_MODE_UNRELIABLE: channel = SYSCH_UNRELIABLE; break;  // 1
    case TRANSFER_MODE_RELIABLE:   channel = SYSCH_RELIABLE;   break;  // 0
}
if (tr_channel > 0) { channel = SYSCH_MAX + tr_channel - 1; }        // = tr_channel + 1
```

⇒ `transfer_channel = 0` = 系统默认:reliable 走 ENet 0、unreliable 走 ENet 1;`transfer_channel = N > 0` 走 ENet `N + 1`。

`core/net/net_bus.gd` 的 `const ENet_CHANNELS := 4` 传给 `create_server/create_client`,引擎再加 `SYSCH_MAX`(2) ⇒ ENet 实际 6 条道(0~5),`transfer_channel` 可用 1~4。最大用到 3(ENet 4)。

## 分道规则
- 与「会话 / 回局生命周期」成序列的消息一律留控制道(`transfer_channel = 0`);跨通道不保序。
- `round_state` 必须排在 `match_start` / `go_match`(切场景)之后;`*_options` / `room_map` 属大厅期会话消息。
- 比赛期内的高频 FX / 生成事件(子弹、光束、拆墙、命中、击杀、武器增删)进 `transfer_channel = 3`。

## 通道表
| `transfer_channel` | 实际 ENet 道 | 语义 | 该通道上的 RPC |
|---|---|---|---|
| **0**(默认) | reliable→**0** / unreliable→**1** | 关键握手 / 会话序列 / 生命周期宣告 + 全部快照 | `ai_duel` / `claim_role` / `create_room` / `go_match` / `join_room` / `list_rooms` / `lobby_name` / `match_options` / `match_start` / `match_sync` / `match_sync_data` / `opponent_left` / `peer_info` / `ping` / `player_options` / `pong` / `pvp_room_state` / `pvp_start` / `reclaim_role` / `rejoin_denied` / `rejoin_request` / `report_token` / `room_created` / `room_joined` / `room_list` / `room_map` / `round_state` / `royale_create` / `royale_join` / `royale_leave` / `royale_list` / `royale_rooms` / `royale_start` / `royale_start_ai` / `server_message` / `session_token` / `snapshot_own` / `snapshot_world` / `suicide_request` / `team_create` / `team_join` / `team_leave` / `team_list` / `team_pick` / `team_rooms` / `team_start` |
| **1** | **2** | 60Hz 输入 | `send_input`(60Hz 一包一条记录,每条 = 1 个物理 tick) |
| **2** | **3** | 10Hz 状态镜像 | `royale_room_state` / `team_room_state` / `time_state` |
| **3** | **4** | 比赛期内的一次性 FX / 生成事件 | `beam_fired` / `bullet_spawn` / `explosion` / `hit_confirm` / `hit_event` / `kill_event` / `sub_destroyed` / `tile_destroyed` / `weapon_removed` / `weapon_spawned` |

**合计 60 条**:`transfer_channel` 0 = 46 / 1 = 1 / 2 = 3 / 3 = 10。

## 声明与对账

- `@rpc` 四参全写:`@rpc(mode, sync, transfer_mode, transfer_channel)`。三参并把 int 放第 3 位会被引擎拒(`argument 3 should be "String" but is "int"`);`mode` / `sync` / `transfer_mode` 三个字符串顺序无关,`transfer_channel` 必须是最末那个 int;`sync` 写 `"call_remote"` 是默认值。
- ★ **单一真相源 / 对账入口 = `tools/gen_rpc_channel_table.py --check`**:只校验不写盘(漂移 exit 1);`--write` 幂等重写表的 RPC 列与合计数字。扫描口径 = 只认**行首** `@rpc(`(注释里的不算)、`@rpc` 行与 `func` 行之间允许空行、四参必须全写。**改通道号 = 改代码声明 + 跑 `--write`(或手改表再 `--check`)**,两处只改一处必红。
- 作用域:产品声明 **60** 条(`net_bus.gd` 28 + `net_bus_ext.gd` 32);`transfer_channel` 0/1/2/3 = 46/1/3/10。
- 唯一性:表里 **60** 个方法名 = **60** 条声明,无重名 —— 同一 RPC 名不得同时出现在两个 autoload(挂错节点 = 静默 no-op);`beam_fired` 的 `net_bus_ext.gd` 死副本已随 S-04 删除(`net_bus.gd` 里 `beam_fired` 的注释记着这件事),工具把重名集合钉成空集。
- 通道号无法在运行期回读:`GDScript.get_script_method_list()` 不含 `rpc_config` ⇒ 唯一自动化判据是上面的文本对账(原 `rpc_channel_contract_smoke` 已删)。
- **接收端纪律**:`beam_fired` 必须走 `NetBus`(不是 `NetBusExt`);挂错节点 = 静默 no-op。
