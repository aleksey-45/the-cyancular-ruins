# 联机捡枪 / 切枪 / 副本持枪 三处失灵 —— 根因与修复(2026-09-17)

**一句话**:用户报的三条(1v1 捡不起地上的枪、大乱斗捡起后切不动枪、对手丢枪后我方视角里他还举着)
各有一个**可证的**根因,全部落地修复并加了红→绿守卫;附带修掉同域的换局幽灵枪,
以及"往正在断开的 peer 发定向包"这条 channel 0 噪音的来源类。

分支 `cleanup/stage1-bugs-and-hygiene`。判据一律 grep `ALL-OK`。

---

## 1. 修了什么(逐条:现象 → 根因 → 守卫)

### 1.1 1v1 捡不起地上的枪(只能捡起"原先丢弃的")

**根因:同一个 `entries[].pos`,两条投递路径送出去的不是同一个东西。**

- `MatchGround._sync_ground_positions()`(每帧、`_physics_process` 第一行)把每条 `pos` 刷成
  `WeaponPickup.visual_center()` = `canonical + visual_offset`(手枪 ≈ (60,14));**拾取判定读的就是它**
  (设计:"以看得见的那把枪为圆心")。
- `_broadcast_weapon_spawned()`(掉落/换下/复活散枪)是**紧跟** `_spawn_ground_weapon` 调的,
  那时本帧的 `_sync_ground_positions` 早跑过、节点是之后才建的 → 发出去的是**原始 canonical** ✅
- `ground_weapons_payload()`(开局那批,走 `match_sync`)读的是**已被刷新的表** → 发的是
  **判定圆心**(多一个 offset)❌
- 客户端 `_spawn_pickup_node` 把载荷 `pos` 直接当 `node.canonical_pos`(其注释写明"事件里的 pos 是
  canonical")→ 开局那批被画在 `canonical + 2×offset`、落体也从错的地方开始;玩家站到**画出来的**枪上时,
  与服务器判定圆心相距**恰好一个 offset** —— 手枪 61.6px vs 半径 64px,**只剩 2px 余量**,
  从东侧走过去必然超半径 → "看着有 F 提示,按 F 什么也不发生"。掉落那批因为发的是 canonical、两边对齐,
  所以**捡得起来** —— 正是用户观察到的差别。

**实测证据**(把 `ground_weapons_payload` 临时改回旧行为跑 ⓪ 相):**12/12 件**都不符 ✓ 根因坐实。

**修法**:两条路径都走 `MatchGround._canonical_of(inst)`(显式读节点,不再靠时序巧合)。
`entries[].pos` = 判定圆心**不动**;客户端每帧的 `_tick_ground_weapons` 刷新也不动 ——
修好后两边圆心逐字对齐(顺带治好 F 提示圈平移 60px)。

### 1.2 大乱斗"捡起武器后无法切换武器"(滚轮)

**根因:滚轮上行的是武器**类型 id**,消费端按**背包位置**读**(`2643cfb` 改数字键语义时漏的半个)。

- 生产:`request_net_cycle` 里 `push_net_slot(int(inventory.held[next]["type"]))`(类型 id 1-6)
- 消费:`player.gd` 的 `weapons.equip_index(wslot - 1)`(背包位置)
- 数字键那条自洽(`LocalInputSource._weapon_slot_raw` 返回 1-4 = 位置)

背包 `[步枪2, 手枪1]` 从步枪滚一下 → 上行 `1` → 服务器 `equip_index(0)` 切回**步枪**(等于没切);
`[手枪1, 重狙3]` → 上行 `3` → `equip_index(2)` **越界早退**(服务器压根没切)→ 权威 `wslot` 经
`sync_soft_state` 把客户端拉回原枪。**只在背包 ≥2 把时现形** —— 即"捡起武器之后"。

**修法**:`push_net_slot(next + 1)`(背包位置,与数字键同量纲)。

> ⚠ **数字键那半没定位到缺陷**:InputMap(`1`-`4` = physical_keycode 49-52)齐、不在
> `Settings.REMAPPABLE_ACTIONS` 里;真链路探针量的**客户端自己那份背包**(`ground_net_watcher.gd`
> 读 `_local.weapons.inventory.held.size()`)是 `背包=2`,说明拾取后客户端确实拿到了第二把。
> 用户答"两种都切不动 / 没细看",本轮**不猜着改**数字键,交实机复验。
> 若仍切不动,下一个测量点:今天只量了"背包件数",没量"切枪请求是否被权威采纳" —— 给
> `ground_net_watcher` 加「按一次数字键 → 断言权威 `wslot` 跟着变、且下一帧没被 `sync_soft_state` 拉回」。

### 1.3 对手丢枪后我方视角里"还举着"

**根因**:`PlayerReplica.apply_snapshot` 的 `if slot > 0 and slot != _weapon_slot_int` —— 快照的
`weapon` 为 **0(空手)** 那一档被整个忽略。服务器只有一种情况会让它变 0:把**最后一把**丢出去
(`drop_current()` 里 `_first_enabled_index() < 0`)。开局人手一把 → "对手把枪丢了"几乎必然命中。
握两把以上时丢一把会自动换另一把(slot 变了、照常重建),所以一直没被发现。

**修法**:守卫改成 `if slot != _weapon_slot_int`(`_swap_weapon(0)` 本来就是写好的空手路径:
先记 slot 再释放实例,`WEAPONS.get("0","")` 查不到 → return)。

### 1.4 附带:1v1 换局后地面武器与客户端脱节(用户没报,同域必踩)

**根因**:`_reset_ground_weapons` 清空重铺**不发任何事件**,且把 `_next_ground_inst` 重置回 1 →
新一轮那批与客户端残留节点**撞号**,而 `_spawn_pickup_node` 对已有 inst 是**静默 return**;
客户端侧也从不在换局时清理 → 第 2 局起客户端画的是上一局的幽灵枪、真枪一件都看不见,
只能捡后来的丢弃物(1v1 独有:只有它有换局)。

**修法**:清空广播 `weapon_removed`×旧、重铺后广播 `weapon_spawned`×留在场上的(可靠通道保序),
`_next_ground_inst` 不再重置。
★ **客户端不加"自愈清空"**:真写过一版,结果服务器是「先重铺广播、**再** `_broadcast_round_state`」,
后到的清空把刚建好的新一轮那批一起抹掉 → 第 2 局起客户端地面**恒空**。守卫已加反向断言防止复活。

### 1.5 `Unable to send packet on channel 0, max channels: 0`

**机制**(读引擎源码钉死):该消息只出自 `enet_packet_peer.cpp:64` 的
`p_channel >= peer->channelCount`(即**目标 peer 的通道数为 0**)。ENet 在
`enet_peer_reset_queues()`(断开/超时/被 reset)里把它置 0。`ENet_CHANNELS=4` 解决不了它 ——
真身是「**往一个 ENet 已拆掉、但 MultiplayerAPI 还没忘掉的 peer 发定向包**」,而 `get_peers()`
比 ENet 真实状态**晚**(本仓 `lobby_rooms.gd` 早就实测记过"滞后超过一帧")。
★ 报文里的通道号是证据:`SYSCH_RELIABLE=0 / SYSCH_UNRELIABLE=1`,所以 "channel **0**" 只可能来自
**reliable** 定向包;**广播打不出这条**(`enet_host_broadcast` 自己跳过非 CONNECTED 的 peer)。

**修法(两层)**:

1. 新增 `NetBus.is_peer_live(id)`(判据 = ENet 自己的 `state == CONNECTED` **且**
   `get_channels() > 0` —— 后者正是 `send()` 会检查的那个量),`_rpc_all` 的 `live_only` **默认改成 true**
   (原先 8 个调用点里 7 个不判在线:`tile_destroyed`/`bullet_spawn`/`beam_fired`/`weapon_*`/`round_state`/`kill_event`),
   并给 `hit_event`/`hit_confirm`(交火时最密)、`match_start`+`server_message`(两种 `start_on`)、
   `match_sync_data`、`ping→pong`、`snapshot_own`、大厅的 `is_peer_online` 都接上同一判据。
2. 新增 `NetBus.reply(id, method, …)` 作为**大厅侧全部"答复 caller"发送的单一收口**
   (`server/lobby_rooms.gd` + `server/room_manager.gd` 的 33 处已全部改走它;实参形状与 `rpc_id`
   一致,故只是换名)。**为什么这一类必须收口**:请求与"对端断开"常挤在**同一次 poll** 里 ——
   ENet 按到达顺序处理命令,**处理 DISCONNECT 时当场把该 peer 的通道数清零**,而同批里排在它前面的
   RECEIVE 事件要等 dispatch 阶段才派发 → 于是"客户端发完请求就 `stop()`"这一拍,服务端是在
   **通道已清零**的状态下处理该请求并发它的应答 → 应答必然打这条错误。
   (用户实机 1v1 日志的顺序正是如此:ERROR → `玩家断开 peer=…`。)

**实测与残留**:大厅/worker 的**定向发送已全部过判据**,但 `royale_probe` 跑多轮**仍有约 2/3 轮出现 1 条**,
且逐轮归属不同(某轮在 `worker_7800.log`、某轮只在编排进程的 stdout、某轮完全不出现 ⇒ **是竞态**)。
用"把 `is_peer_live` 恒返回 false"的实验曾观察到 0 条,但该现象在未改动的对照轮里也会时有时无
(**这个对照本身就说明它不是稳定判据**,不能作为因果证据)。
⇒ **结论:每局最多 1 条、对象是正在离场的 peer、包本来就该丢** —— 非致命、不影响任何对局行为;
要彻底消掉需要一次引擎级定位(带 GDScript 栈的插桩,或给 `ENetPacketPeer::send` 那条 `ERR_FAIL` 打断点),
本轮不做。**注意别把它当成"功能坏了"**:它的出现与拾取/切枪/副本三处修复无关。

---

## 2. 改了哪些文件

| 文件 | 改动 |
|---|---|
| `server/match_ground.gd` | `_canonical_of()` 新增;载荷与 `weapon_spawned` 都发 canonical;换局广播增删 + 不再重置 inst |
| `scenes/player/weapon_component.gd` | 滚轮上行背包位置(`next + 1`) |
| `scenes/player/player_replica.gd` | 认 `weapon == 0`(空手) |
| `scenes/pvp_game.gd` | 换局**不**自清地面武器(带解释注释) |
| `core/net/net_bus.gd` | `is_peer_live()` / `can_send_to_server()`;`ping→pong` 判活;订正 `ENet_CHANNELS` 注释 |
| `server/match_state.gd` | `_rpc_all` 的 `live_only` 默认 true |
| `server/match_snapshot.gd` / `match_combat.gd` / `match_bootstrap.gd` / `royale_host.gd` / `server_main.gd` / `lobby_rooms.gd` | 定向发送前判活 |
| `scenes/pvp_match_client.gd` | `send_input`/`send_ping` 加 `can_send_to_server()` 守卫(离场那几帧不再打另一条 RPC 错误) |

## 3. 测试(都归到已有探针,不新开文件)

| 探针 | 新增 |
|---|---|
| `ground_action_probe` | ⓪ 载荷位置契约(`pos + visual_offset` == 判定圆心;反证过:**旧代码 12/12 不符**);⑦ 换局 inst 单调 + 重铺后仍捡得动 |
| `ground_client_probe` | ⑥ 切枪字段 = 背包位置(含"按消费端口径还原同一位置")、⑦ 副本认空手(还能重建) |
| `net_ground_probe` | ④b 换局必须广播 removed+spawned、inst 不得重置、**客户端不得自己清空**(反向) |
| | ④c 切枪字段两端同量纲(反向:不得再出现 `push_net_slot(...["type"])`) |

跑法(判据 grep `ALL-OK`):

```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$G" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
"$G" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
"$G" --headless --path . --quit-after 3600 res://tests/net_ground_probe.tscn      # 源码级
"$G" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport   # 真链路;先确认 7777 空闲
bash tests/pvp_room_smoke.sh ; bash tests/pvp_match_smoke.sh
"$G" --headless --path . --quit-after 10800 res://tests/royale_probe.tscn          # 全链路;先确认 7777 空闲
```

本轮实测(2026-09-17,全绿):`ground_action_probe` / `ground_client_probe` / `net_ground_probe` /
`ground_net_probe`(c1/c2 `丢=8 捡=9 轮=4`) / `royale_probe` / `pvp_room_smoke` / `pvp_match_smoke` /
`kh_l4|l5|l6_probe` / `match_host_hygiene_probe` / `royale_disconnect_count_probe` / `grenade_player_hit_probe`。

## 4. 实机验收(探针答不了的部分)

1. **1v1**:走到散落的枪上按 F 应**必捡**(不再需要从某一侧绕)。
2. **1v1 第二局**:换局后地上那批应**当场换成新一轮的位置**且捡得起来。
3. **大乱斗**:捡第二把 → 滚轮来回切,枪跟着变且不被拉回;数字键 1/2 切背包第 N 把
   (**若数字键仍切不动**,请回报"按下去有没有一点动静/有没有响切枪音效",见 §1.2 的 ⚠)。
4. **两模式**:让对手丢光他最后一把枪 → 我方视角他手上应**立刻空了**。

## 5. 未做 / 未决

- 数字键切枪那半(见 §1.2 ⚠):读不出缺陷,不猜着改。
- channel 0 每局残留 1 条(见 §1.5):影响面已界定(非致命),成因是竞态、未钉死。
- 大厅"答复 caller"的定向发送**已**统一走 `NetBus.reply()`(33 处);客户端→服务端那几条
  (`match_sync`/`claim_role`/`list_rooms`/`royale_*`,在页面的超时/刷新梯上)仍**未**判活 ——
  它们打出来的是另一条错误(`no multiplayer peer` / `not connected`),不在本次报告的症状里。
- 上一轮未复现的**硬崩溃**本轮未追(无堆栈、无复现步骤)。
- `docs/2026-09-17-duel-probe-lobby-rpc-blocker.md` 那条 duel 探针卡点属另一条线,本轮未碰。
