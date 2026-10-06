# PvP 武器网络同步缺陷排查与修复报告 (2026-09-17)

本文档记录针对 PvP 联机模式中武器拾取、武器切换、远端玩家持枪状态同步以及换局状态重置缺陷的排查过程、根本原因分析、修复方案与回归测试结果。

---

## 一、 问题概述

在多人生存与对决模式联机测试中，暴露了以下五项直接影响核心战斗体验的同步缺陷及衍生问题：
1. **地面武器拾取判定失效**：在 1v1 等模式中，地图初始生成的地面武器靠近后无法按键拾取（仅后续丢弃的武器可正常拾取）。
2. **拾取武器后无法切换槽位**：大乱斗等模式拾取第二把武器后，使用鼠标滚轮无法在武器间正常切换。
3. **远端玩家丢弃武器视觉状态残留**：对手丢弃手中最后一把武器（进入空手状态）后，其他玩家视角仍显示其保持举枪姿态。
4. **1v1 换局地面武器状态脱节**：第 2 回合开始后，客户端残留上一回合的武器实体并与新生成的武器实例 ID 冲突，导致新回合武器不可见或无法拾取。
5. **ENet Channel 0 数据包发送告警**：连接断开或切局时，控制台偶发 `Unable to send packet on channel 0, max channels: 0` 引擎底层错误。

所有上述问题均已完成根本原因定位、代码修复及回归测试验证。

---

## 二、 根本原因与修复方案

### 1. 地面武器拾取判定失效

#### 根本原因
服务端向客户端下发地面武器位置数据时，不同生命周期路径发送的数据语义不一致，导致客户端渲染实体位置与服务端判定区域产生偏移：
1. **服务端判定逻辑**：`MatchGround._sync_ground_positions()` 在每物理帧首行将条目位置更新为视觉中心坐标 `visual_center = canonical_pos + visual_offset`（例如手枪偏移约 `(60, 14)`），服务端的拾取半径检测（64px）以此坐标为圆心。
2. **动态生成路径**：玩家丢弃或换下武器触发 `_broadcast_weapon_spawned()` 时，节点刚刚创建，广播下发的是原始世界基准坐标 `canonical_pos`。客户端以此坐标生成节点，两端位置一致。
3. **开局同步路径**：开局全量同步 `ground_weapons_payload()`（通过 `match_sync` 下发）读取的是已经被物理帧更新过的条目列表，下发的是包含偏移的 `visual_center`。
4. **客户端叠加偏移**：客户端 `_spawn_pickup_node` 默认传入坐标为 `canonical_pos`，在渲染时再次累加 `visual_offset`，导致初始武器渲染在 `canonical_pos + 2 * visual_offset` 处。

此时，客户端渲染的视觉模型与服务端的实际判定圆心相距刚好一个 `visual_offset`（手枪约 61.6px）。由于拾取有效半径仅为 64px，有效判定余量不足 2px；玩家站在看到的武器东侧时，实际距离服务端判定圆心超过 64px，导致界面出现交互提示但服务端校验失败无法拾取。

#### 修复方案
- 统一服务端坐标序列化口径：在 `MatchGround` 中新增 `_canonical_of(inst)` 方法，显式读取节点的原始基准坐标；无论是全量开局载荷还是动态生成事件，均统一序列化 `canonical_pos`。
- 服务端内部维护的 `entries[].pos` 保持为判定圆心不变，客户端每帧根据基准坐标与视觉偏移计算显示，彻底消除两端位置偏差。

---

### 2. 滚轮武器切换异常

#### 根本原因
客户端滚轮切枪事件发送的数据与服务端接收期望的数据语义不一致（武器配置类型 ID vs 背包槽位索引）：
1. **事件生产端**：`WeaponComponent.request_net_cycle` 在滚轮切枪时，通过 `push_net_slot(int(inventory.held[next]["type"]))` 发送了目标武器的**配置类型 ID**（数值范围 1~6）。
2. **事件消费端**：`player.gd` 接收到网络槽位请求后，调用 `weapons.equip_index(wslot - 1)`，该接口要求传入**背包槽位索引**（0 开始）。
3. **数字键输入**：通过键盘数字键（1~4）切枪时，输入层返回的是槽位索引（1~4），语义自洽。

当背包中持有 `[步枪(类型2), 手枪(类型1)]` 时，当前手持步枪，向后滚动滚轮期望切到手枪：
- 上行请求发送手枪类型 ID `1`；
- 服务端执行 `equip_index(1 - 1 = 0)`，重新切回背包第 0 槽位的步枪，状态未发生变化。
若目标武器类型 ID 超过当前背包容量（例如狙击枪类型 ID 3），服务端执行 `equip_index(2)` 触发数组越界提前退出，随后在服务端状态同步（`sync_soft_state`）时将客户端回拉至原武器。

#### 修复方案
- 修改 `WeaponComponent` 中滚轮切枪的参数传递，改为 `push_net_slot(next + 1)`，统一上报背包槽位序号（1 开始），与数字键逻辑严格保持一致。

---

### 3. 远端玩家丢弃武器后视觉状态残留

#### 根本原因
远端玩家实体副本（`PlayerReplica`）的状态更新守卫排除了空手状态：
- `PlayerReplica.apply_snapshot` 中的武器同步条件为 `if slot > 0 and slot != _weapon_slot_int:`。
- 当玩家丢弃最后一把武器进入空手状态时，服务端同步快照中的武器槽位为 `0`。
- 由于判断条件要求 `slot > 0`，快照中的 `0` 槽位被直接忽略，远端副本未执行武器卸载逻辑，导致视觉模型依然保持上一把武器的持枪状态。

#### 修复方案
- 将更新条件修正为 `if slot != _weapon_slot_int:`。
- 在 `_swap_weapon(0)` 的原有逻辑中，已支持传入 `0` 时清空并释放当前武器节点，条件放开后可正确同步空手状态。

---

### 4. 1v1 回合切换地面武器脱节

#### 根本原因
1. 服务端在 `_reset_ground_weapons` 重置场地武器时，仅在本地清空列表并重新生成，未向客户端广播移除与生成事件。
2. 服务端在每回合将武器实例 ID 计数器 `_next_ground_inst` 重置为 1，导致新一回合生成的武器 ID 与客户端上一回合遗留的未释放节点 ID 发生碰撞。
3. 客户端 `_spawn_pickup_node` 在收到已存在的武器实例 ID 时会静默返回，导致客户端视觉上残留上一局武器、新武器无法正确渲染。

#### 修复方案
- 换局时服务端在清空场地前广播旧武器的 `weapon_removed` 事件，重新生成后广播新武器的 `weapon_spawned` 事件（通过可靠通道保证时序）。
- 服务端 `_next_ground_inst` 计数器在整个比赛生命周期内保持严格单调递增，不再在换局时重置，杜绝实例 ID 碰撞。
- 客户端严格依据服务端广播进行武器增删，避免本地异步清理逻辑与服务端生成广播产生时序竞争。

---

### 5. ENet Channel 0 数据包发送底层错误

#### 根本原因
控制台报错 `Unable to send packet on channel 0, max channels: 0` 源自 Godot 引擎底层 `enet_packet_peer.cpp` 中的安全校验：
- 当 ENet 处理断开连接事件（`enet_peer_reset_queues`）时，会将对应 Peer 的通道数重置为 0。
- 上层 `MultiplayerAPI` 的连接状态与 Peer 列表更新存在一定延迟（通常滞后 1 物理帧）。
- 若在 Peer 处于断开过程中，服务端仍尝试向该 Peer 发送 Reliable 定向 RPC（通道 0），引擎会因通道数为 0 抛出告警。
- 特别是在客户端主动退出时，其发送的请求与断开事件可能处于同一个底层 poll 批次中，服务端在处理请求时对端已处于断开状态。

#### 修复方案
1. **统一在线与通道校验**：
   - 在 `NetBus` 中新增 `is_peer_live(id)` 方法，校验 Peer 是否处于 `CONNECTED` 状态且通道数大于 0（`get_channels() > 0`）。
   - 在 `NetBus.can_send_to_server()` 中增加客户端到服务端的有效性防护。
   - `MatchState._rpc_all` 的 `live_only` 过滤默认置为 `true`，下发广播时跳过已失效 Peer。
   - 对战斗事件、命中确认、快照下发等高频定向 RPC 增加 `is_peer_live` 守卫。
2. **大厅应答统一收口**：
   - 新增 `NetBus.reply(id, method, ...)` 作为服务端大厅向客户端回复消息的统一收口，在发送前严格校验 Peer 存活状态。
   - 客户端在主动离开房间断开前，停止发送后续输入或 Ping 包，避免触发无效 RPC。

---

## 三、 涉及文件与代码变更

| 文件路径 | 变更说明 |
|---|---|
| `server/match_ground.gd` | 新增 `_canonical_of()`；全量载荷与增量事件统一序列化基准坐标；换局广播武器销毁与生成事件；实例 ID 保持单调递增 |
| `scenes/player/weapon_component.gd` | 滚轮切枪事件改为上报背包槽位序号（`next + 1`），统一输入量纲 |
| `scenes/player/player_replica.gd` | 修复快照武器槽位判定条件，支持同步空手状态（`slot == 0`） |
| `scenes/pvp_game.gd` | 移除客户端换局本地自主清空地面武器逻辑，完全交由服务端权威事件驱动 |
| `core/net/net_bus.gd` | 新增 `is_peer_live()` 与 `can_send_to_server()` 存活检测；补充 `NetBus.reply()` 收口方法 |
| `server/match_state.gd` | `_rpc_all` 广播的 `live_only` 选项默认启用 |
| `server/match_snapshot.gd`<br>`server/match_combat.gd`<br>`server/match_bootstrap.gd`<br>`server/royale_host.gd`<br>`server/lobby_rooms.gd`<br>`server/room_manager.gd` | 在定向 RPC 下发前增加 `is_peer_live()` 存活校验 |
| `scenes/pvp_match_client.gd` | `send_input` 与 `send_ping` 增加客户端存活防护，防止断开时抛出 RPC 告警 |

---

## 四、 自动化回归测试

相关测试逻辑已集成至现有探针与冒烟测试套件中：

| 测试用例 / 探针 | 覆盖验证内容 |
|---|---|
| `tests/ground_action_probe.tscn` | 验证武器数据载荷坐标一致性（`pos + visual_offset == 判定圆心`）；验证换局实例 ID 单调性与重新生成后的拾取有效性 |
| `tests/ground_client_probe.tscn` | 验证切枪网络字段与背包槽位一一对应；验证远端实体副本正确同步空手状态与重新装配 |
| `tests/net_ground_probe.tscn` | 源码级静态与逻辑断言：换局必须广播删除与生成事件、实例 ID 不得重置、切枪字段量纲一致 |
| `tests/ground_net_probe.tscn` | 完整网络链路拾取与丢弃回环测试（验证高频丢弃与拾取无状态丢失） |
| `tests/royale_probe.tscn` | 大乱斗全流程生命周期测试与数据包监控 |

### 执行命令

```bash
# 执行自动化探针（预期输出均包含 ALL-OK）
godot --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
godot --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
godot --headless --path . --quit-after 3600 res://tests/net_ground_probe.tscn

# 网络链路集成测试（需确保默认端口未被占用）
godot --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport
godot --headless --path . --quit-after 10800 res://tests/royale_probe.tscn
```

---

## 五、 实机人工验证清单

1. **地面武器拾取**：在 1v1 或大乱斗中，从任意方向走向初始地面武器，接近后均应正常弹出交互提示，按下交互键（默认 F）可立即拾取。
2. **回合交替**：在 1v1 模式完成第 1 回合进入第 2 回合后，场地上的地面武器应正确刷新并位于新位置，无上一回合残留，交互拾取功能正常。
3. **多武器切换**：拾取第二把武器后，使用鼠标滚轮上下滚动，主手武器应在槽位间流畅切换，不会发生被服务端强制拉回原武器的情况。
4. **空手状态同步**：让对手玩家丢弃其持有的全部武器，观察其角色外观应立刻切换为空手姿态，无模型残留。
