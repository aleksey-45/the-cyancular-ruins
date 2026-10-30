# 联机:RPC 通道划分表（★ 单一来源）

通道号以本表为准;代码里的 `@rpc("any_peer", "call_remote", "reliable", N)` 按本表对账。★ **原「通道表 ↔ 声明文本」对账守卫已随 2026-10-24 默认批激进削减删除** ⇒ 这张表今天**没有自动化守卫**,改通道号必须人眼对表(缺口登记在 [`registered-debt.md`](registered-debt.md) §九)。

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

v5 起 [`core/net/wire.gd`](../../core/net/wire.gd) 直连 ENetConnection,通道由 `WireKind.CHANNELS := 4` 指定,四条道全归应用(0 会话 / 1 输入 / 2 快照 / 3 事件);v4 的「引擎自留 SYSCH 两条」不再适用。

## 分道规则
- 与「会话 / 回局生命周期」成序列的消息一律留控制道(`transfer_channel = 0`);跨通道不保序。
- `round_state` 必须排在 `match_start` / `go_match`(切场景)之后;`*_options` / `peer_hues` / `room_map` 属大厅期会话消息。
- 比赛期内的高频 FX / 生成事件(子弹、光束、拆墙、命中、击杀、武器增删)进 `transfer_channel = 3`。

## 通道表
| `transfer_channel` | 实际 ENet 道 | 语义 | 该通道上的 RPC |
|---|---|---|---|
| **0**(默认) | reliable→**0** / unreliable→**1** | 关键握手 / 会话序列 / 生命周期宣告 + 全部快照 | `ai_duel` / `claim_role` / `create_room` / `go_match` / `join_room` / `list_rooms` / `lobby_name` / `match_options` / `match_start` / `match_sync` / `match_sync_data` / `opponent_left` / `peer_hues` / `peer_info` / `ping` / `player_options` / `pong` / `pvp_room_state` / `pvp_start` / `reclaim_role` / `rejoin_denied` / `rejoin_request` / `report_token` / `room_created` / `room_joined` / `room_list` / `room_map` / `round_state` / `royale_create` / `royale_join` / `royale_leave` / `royale_list` / `royale_rooms` / `royale_start` / `royale_start_ai` / `server_message` / `session_token` / `snapshot_own` / `snapshot_world` / `suicide_request` / `team_create` / `team_join` / `team_leave` / `team_list` / `team_pick` / `team_rooms` / `team_start` |
| **1** | **2** | 30Hz 输入 | `send_input`(采样 30Hz;一条记录管 2 个物理 tick) |
| **2** | **3** | 10Hz 状态镜像 | `royale_room_state` / `team_room_state` / `time_state` |
| **3** | **4** | 比赛期内的一次性 FX / 生成事件 | `beam_fired` / `beam_fired` / `bullet_spawn` / `hit_confirm` / `hit_event` / `kill_event` / `sub_destroyed` / `tile_destroyed` / `weapon_removed` / `weapon_spawned` |

**合计 61 条**:`transfer_channel` 0 = 47 / 1 = 1 / 2 = 3 / 3 = 10。

## 声明与对账

- `@rpc` 四参全写:`@rpc(mode, sync, transfer_mode, transfer_channel)`。三参并把 int 放第 3 位会被引擎拒(`argument 3 should be "String" but is "int"`);`mode` / `sync` / `transfer_mode` 三个字符串顺序无关,`transfer_channel` 必须是最末那个 int;`sync` 写 `"call_remote"` 是默认值。
- 作用域(v5,登记表 [`core/net/wire_kind.gd`](../../core/net/wire_kind.gd)):产品声明 57 条,通道 0/1/2/3 = 45/1/2/9(程序化清点 2026-10-30);v4 的 61 条里有 3 条死协议(peer_info/match_options/peer_hues)与 1 条重名(beam_fired 双份)未迁;`transfer_channel` 0/1/2/3 = 47/1/3/10。表里 60 个方法名,差的一条是 `beam_fired` 在 `net_bus.gd` 与 `net_bus_ext.gd` 各声明一次(两份都给通道 3)。通道号无法在运行期回读:`GDScript.get_script_method_list()` 不含 `rpc_config` ⇒ 过去的唯一自动化判据是文本对账(`rpc_channel_contract_smoke`,已删)⇒ **今天只能人工对表**;「重名集合恰好 = {beam_fired}」也没人钉了。
- **接收端纪律**:`beam_fired` 必须走 `Wire`(不是 `Wire`);挂错节点 = 静默 no-op。
