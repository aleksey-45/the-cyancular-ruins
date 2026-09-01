# The Cyancular Ruins — PvP 联机模块分析

> 基于当前 `main` 分支代码（B2「对局互通」已完成，阶段 3 回合制未做）对联机部分的完整梳理。
> 设计源头见 `docs/superpowers/specs/2026-08-27-pvp-mode-design.md` 与
> `docs/superpowers/plans/2026-08-31-pvp-phase2-match-play.md`；本文是**现状代码**的落地对照。

---

## 1. 总览：权威模型与一句话架构

**专用服务器权威（authoritative dedicated server）+ 客户端本地预测自己（C2，client-side prediction）。**

- 一台 headless 服务器进程跑全部权威模拟（世界、两个玩家、子弹、命中裁决）；客户端**不裁决任何伤害**。
- 客户端本地玩家照常跑完整 `player.gd` 物理（C2），保证零延迟手感；服务器每 30Hz 广播快照，客户端用它**插值远端对手** + **校正自己**。
- 环面世界纪律：**协议只传 canonical `[0,MAP)` 坐标**；渲染各端归最近副本；插值走最短路径增量（绝不 naive lerp canonical）。
- 服务器/客户端共用同一个 autoload `NetBus` 收口 RPC，跨场景常驻。

### 进程拓扑

```
┌───────────────────────── 服务器进程（--headless，场景模式）─────────────────────────┐
│  server_main.tscn ── RoomManager（房间注册表）                                        │
│                         └─ MatchHost × N（每房间一个权威对局模拟）                     │
│                              ├─ WorldBuilder 建世界（只碰撞不渲染）                     │
│                              ├─ Player.tscn ×2（完整物理，注入 NetworkInputSource）    │
│                              └─ 子弹模拟 + 命中裁决 + 30Hz 快照广播                     │
└────────────────────────────────────────────────────────────────────────────────────┘
        ▲ reliable 输入包 60Hz          ▼ unreliable 快照 30Hz / reliable 事件
┌───────────────┐          ┌───────────────┐
│  客户端 P1      │   对称    │  客户端 P2     │    ← 完全对称，无房主优势
│  pvp_game.tscn │          │  pvp_game.tscn │
│  ├ Level0 世界   │          │               │
│  ├ 本地玩家 C2   │          │               │
│  └ RemoteReplica│          │               │
└───────────────┘          └───────────────┘
```

### 场景流程

```
main_menu.tscn（默认场景）
 ├─ 单人 → 复位 Level0.pvp_mode=false → Level0.tscn（单机路径逐字节不变）
 └─ 多人 → PvpSession.reset() → matchmaking.tscn
       ├─ 建房：连服务器 → rpc create_room → 拿房间号展示 → 等对手
       └─ 加入：连服务器 → 输房间号 → rpc join_room
       └─ 2 人就绪 → 服务器发 match_start(role, spawn, map) → 客户端切到 pvp_game.tscn
```

---

## 2. 文件地图

| 文件 | 角色 | 关键职责 |
|---|---|---|
| `Globals/net_bus.gd` | **autoload，唯一网络收口** | ENet 建连/断开；全部 RPC 定义；信号转发 |
| `Globals/pvp_session.gd` | 静态会话配置 | 菜单→匹配→对局间传参（role/spawn/map/地址） |
| `server/server_main.gd` | 服务器入口 | `NetBus.start_server()` + 挂 RoomManager |
| `server/room_manager.gd` | 房间注册表 | 建房/加入/断线清理/2 人就绪开局 |
| `server/match_host.gd` | **服务器权威对局** | 建世界 + 双玩家权威模拟 + 快照/事件广播 + 命中裁决 |
| `Scenes/pvp_game.tscn` + `Scenes/pvp_client.gd` | 客户端对局场景 | C2 本地玩家 + 输入上报 + 快照消费 + 自校正 + 视觉子弹 |
| `Scenes/Player/player_replica.gd` | 远端副本 | 纯视觉，最短路径插值，不做物理 |
| `Scenes/matchmaking.gd` | 匹配 UI | 建房/输房间号/状态提示 |
| `Scenes/main_menu.gd` | 主菜单 | 单人/多人入口 |
| `Globals/input_source.gd` | 输入抽象基类 | 默认委托真实 Input（本地现状） |
| `Globals/network_input_source.gd` | 网络输入源 | 服务器权威模拟唯一消费方 |
| `Tests/pvp_smoke_client.gd` / `.tscn` | B1 冒烟客户端 | 建房/加入/match_start 流程 |
| `Tests/pvp_room_smoke.sh` | B1 冒烟脚本 | 断言房间流程 |
| `Tests/pvp_match_smoke.gd` / `.tscn` | B2 冒烟客户端 | 输入→模拟→快照→子弹广播链路 |
| `Tests/pvp_match_smoke.sh` | B2 冒烟脚本 | loopback 双客户端 |

---

## 3. 传输层：NetBus（autoload）

服务器与客户端共用同一节点路径 `/root/NetBus`（autoload 常驻，RPC 才能跨场景路由）。用 `ENetMultiplayerPeer` + Godot 高层 MultiplayerAPI。端口默认 `7777`，服务器 `create_server(port, 16)` 上限 16 连接。

**方法按调用方区分两端**，服务端侧自己不实现业务逻辑，而是 `emit` 信号转交（RoomManager / MatchHost 连接信号），不硬依赖类型、可独立编译。

### RPC 清单

| RPC | 调用方 → 接收方 | 模式 | 动作 |
|---|---|---|---|
| `create_room()` | 客户端 → 服务器 | reliable | `room_create_requested` 转发给 RoomManager |
| `join_room(code)` | 客户端 → 服务器 | reliable | `room_join_requested` 转发 |
| `send_input(pkt)` | 客户端 → 服务器 | **reliable** | `input_received(caller, pkt)` 转发给 MatchHost |
| `snapshot(snap)` | 服务器 → 客户端 | **unreliable** | `local_snapshot` 信号 |
| `bullet_spawn(data)` | 服务器 → 客户端 | reliable | `local_bullet_spawn` 信号 |
| `hit_event(victim_role, damage, source_pos)` | 服务器 → 客户端 | reliable | `local_hit_event` 信号 |
| `room_created(code)` / `room_joined(role)` | 服务器 → 客户端 | reliable | 匹配流程反馈 |
| `match_start(role, spawn, map_path)` | 服务器 → 客户端 | reliable | 开局通知 |
| `server_message(text)` | 服务器 → 客户端 | reliable | 状态/错误提示 |

信号分区（净区分：哪些是给客户端的、哪些是服务器内部转交的）：

- **客户端侧**：`local_room_created` / `local_room_joined` / `local_match_start` / `local_server_message` / `local_snapshot` / `local_bullet_spawn` / `local_hit_event`
- **服务器 → RoomManager**：`room_create_requested` / `room_join_requested` / `peer_left`
- **服务器 → MatchHost**：`input_received`

RPC 里用 `multiplayer.get_remote_sender_id()` 确定真实调用方（防伪造）。

---

## 4. 匹配与房间：RoomManager

`RoomManager`（server）是服务器端房间注册表，`rooms: Dictionary(code → Room)`。

```gdscript
class Room:
    var code: String
    var players: Array[int]      # peer ids
    var player_role: Dictionary  # peer_id → 1/2
    var match_host: Node         # 该房间的 MatchHost
```

流程：

1. **建房** `create_room(caller)`：生成 4 位随机房间号（防重复），房主 role=1，`rpc_id(caller, "room_created", code)`。
2. **加入** `join_room(caller, code)`：房间不存在/已满 → `server_message` 拒绝；否则 role=2，`rpc room_joined`，**立刻 `_start_match`**（加入即开局，无需房主确认）。
3. **开局** `_start_match(room)`：
   - 服务器 **pin 固定地图** `res://factory_1V1(260827).cyrm`（含 `# player 17 65` 与 `# player2 133 64` 出生点）；
   - `MazeGenerator.load_spawns()` 取两个出生点，分别 `rpc_id(peer, "match_start", role, spawn, map_path)`；
   - 构造 `MatchHost.new(map_path, role_peers)` 挂树。
4. **断线** `on_peer_left(peer_id)`：从房间移除；房间空了 → free MatchHost + 删房间。（当前**不通知另一端**，见 §11 遗留。）

---

## 5. 服务器权威对局：MatchHost

每房间一个 `MatchHost`（`extends Node`），是整张地图 + 两个玩家的完整物理模拟。

### 构造 `_init(map_path, role_peers)`

- `MazeGenerator.set_map_file` → `WorldBuilder.load_grid()`（碰撞网格）+ `TileDefs.init_hp` + `WorldBuilder.build_sim`（碰撞：永久墙 + 可破坏分块 + 攀爬条）。**服务器只建碰撞不渲染**。
- 实例化两个 `Player.tscn`，各自 `set_input_source(NetworkInputSource.new())`，按出生点摆位。玩家是 `CharacterBody2D`，服务器上完整跑 `_physics_process`（重力/攀爬/游泳/武器全都有）。

### 每物理帧时序（`_physics_process`，顺序关键）

```
1. 输入注入：对每个 role →
     src.clear_edges()                      # 清上一帧已读边沿（pressed/released/weapon）
     for pkt in _pending_input[role]:       # 缓冲整帧的包队列
         src.apply_packet(pkt)              #   held/axis/aim 覆盖取最新；边沿 |累积
     q.clear()
2. 玩家/子弹的 _physics_process 由树自动跑（父先于子 → 读到的已是最新注入）
3. _adjudicate_bullets()                    # 命中裁决 + 新子弹广播
4. 30Hz 快照广播                            # _snapshot_accum 计时
5. 分帧重建可破坏碰撞块                     # 每帧最多重建 2 块（爆炸拆墙）
```

### 输入消费：队列 + 覆盖/累积双策略（近期的关键修复）

`_on_input(caller, pkt)` 把包**追加进 `_pending_input[role]` 队列**（不是覆盖单包），下帧开头统一应用：

- `held / axis / aim / weapon`：**覆盖取最新** → 服务器紧跟客户端，几乎不滞后；
- `just_pressed / just_released` 边沿：**`|=` 累积不覆盖** → 两包批量到达也不丢边沿。

> 边沿对抓梯/跳跃/开火至关重要。早期实现"每帧覆盖单包"，批量到达时 just_pressed 边沿被后包覆盖丢失，服务器模拟与客户端脱节 → 抓梯失败/跳不起来/开火丢失，表现为"被回拉"。改队列按序消费后修复。
> 缺包时：`held` 保持上一包（沿用），边沿被 `clear_edges()` 清空。

### 快照（30Hz unreliable，canonical 坐标）

```jsonc
{
  "tick": 123,          // 递增序号，客户端靠它丢乱序旧快照
  "players": {
    "1": { "pos": Vector2, "vel": Vector2, "facing": int,
           "pose": int, "weapon": int, "hp": int,
           "waterproof": int, "downed": bool },
    "2": { ... }
  }
}
```

- `pos` 是 canonical（服务器玩家每帧 `wrap_to_range` 到 `[0,MAP)`），**协议绝不传副本偏移坐标**。
- 用 `rpc_id` 逐 peer 发送（unreliable，30Hz）。

### 子弹裁决（`_adjudicate_bullets`）

- 遍历 `bullet` 组：`_seen_bullets[instance_id]` 防重，**新子弹首次出现时广播 `bullet_spawn` 给非射手客户端**（射手本地已生成视觉子弹，不重复收）。
- 命中判定 = 与**非射手玩家**的 `toroidal_delta_px` 距离 `< HIT_RADIUS(40px)`（环面最短距离，跨接缝也能命中）。
- 命中 → `victim.take_hit(pos, dmg, false, impact)` + 广播 `hit_event` 给双方 + `bullet.queue_free()`。

### 拆墙（`_on_tile_destroyed`）

服务器无瓦片渲染层：只清 `destructible_sub` 对应子格 + 标记 `_dirty_chunks`，由 `_physics_process` 每帧重建 ≤2 块（`CollisionBuilder.rebuild_chunk`）。

---

## 6. 客户端对局：pvp_client

`pvp_game.tscn` 根脚本，加载 Level0（`pvp_mode=true`）作为世界。

### `_ready`

1. `MazeGenerator.set_map_file(PvpSession.map_path)` + `Level0.pvp_mode = true`（在实例化 Level0 前设，其 `_ready` 里会跳过刷敌人/单玩家放置）。
2. 实例化 `Level0.tscn`，把世界里的 `Player` 设为本地玩家并摆到 `PvpSession.spawn`。
3. pvp_mode 下 Level0 不建后处理，这里手动补 `PostProcess`。
4. 创建 `RemoteReplica`（角色 = `3 - PvpSession.role`）进 WorldViewport。
5. 连 `local_snapshot` / `local_bullet_spawn` / `local_hit_event` 信号。

### 每物理帧：输入打包上报

```jsonc
{ "ax": 1.0, "held": 0b0111, "pressed": 0b0001, "released": 0,
  "weapon": 0, "aim": Vector2 }   // → rpc_id(1, "send_input", pkt)
```

位常量复用 `NetworkInputSource.BIT_*`（up=1/down=2/charge=4/attack=8），`held` 与 `pressed`/`released` 用不同位——`pressed` 只含**本帧刚按下**的边沿。瞄准方向 = `_local.get_current_aim_dir()`（本地武器实际瞄准，来自鼠标）。

### 快照消费与自校正（`_on_snapshot`）

- **丢弃乱序**：`tick` 比 `_last_snap_tick` 小 → 直接 return（unreliable 通道可能乱序，应用旧快照会把玩家拉回过去）。
- 自己的 role → `_self_correct(data)`；对手 role → `_remote_replica.apply_snapshot(data, local_pos)`。

`_self_correct` 分档处理（**近期把"一视同仁硬拉"改成分档**，消除"移动后卡一下又回去"）：

```
SELF_CORRECT_IGNORE = 64px    分歧 ≤ 64px：忽略   → 预测领先的正常区间，手感不打断
SELF_CORRECT_RATE   = 0.35    中等分歧：+= d*0.35  → 每帧按比例平滑靠拢，不硬跳
SELF_CORRECT_SNAP   = 128px   分歧 > 2 格：直接回位 → 真性大分歧（传送/卡墙），避免越积越歪
```

- **血量/防水/倒地状态**：服务器权威，直接 `apply_authoritative_state(hp, waterproof, downed)` 采纳（不做插值）。
- **位置**：一律走 `toroidal_delta_px` 最短路径增量，绝不 set 绝对位置（跨接缝不滑屏）。

### 事件消费

- `_on_bullet_spawn(data)`：反序列化服务器广播 → `load(scene)` 生成**视觉子弹副本**，`apply_damage=false`（不裁决伤害），摆到 canonical 位置进 WorldViewport。
- `_on_hit_event(victim_role, damage, source_pos)`：命中对象是本地玩家 → `take_hit` 即时白闪/击退反馈；**血量以快照为权威**（事件只做视觉反馈）。

---

## 7. 远端副本：PlayerReplica

纯视觉节点（`Node2D` + `AnimatedSprite2D`），**不做物理**（避免 set position 与物理引擎打架）。

- 复用 `Player.tscn` 的内联 SpriteFrames 与动画。
- `apply_snapshot(data, local_anchor)`：canonical 目标 → `anchor_to_nearest(canonical, local_anchor)` 锚到本地玩家最近副本 → 存 `_target`；同时更新 `flip_h`（facing）、pose→动画名（`0:idle 1:move 2:fly 3:charge 4:squat`）、downed 时停动画。
- `_process`：每帧 `global_position += toroidal_delta_px(cur, _target) * (1 - exp(-INTERP_RATE*delta))`，`INTERP_RATE=12` 指数插值 → 平滑且最短路径，跨接缝连续。

---

## 8. 输入抽象：InputSource / NetworkInputSource

目标：`player.gd` 不直接读全局 `Input`，输入来源可注入。

| 方法 | InputSource（基类=本地） | NetworkInputSource（服务器） |
|---|---|---|
| `get_axis` / `is_action_pressed` | 委托真实 Input | 注入包字段（`_axis` / `_held` 位掩码） |
| `is_action_just_pressed/released` | 委托真实 Input | `_pressed` / `_released` 累积边沿 |
| `is_attack_pressed/just_pressed/just_released` | 委托 `"attack"` 动作 | `BIT_ATTACK` 位 |
| `get_weapon_slot_pressed` | 轮询按键 1-5 | `_weapon`（包内切枪槽位） |
| `get_aim_dir_override` | 返回 `Vector2.ZERO`（武器落回鼠标） | 返回注入的瞄准方向 |

**接线点**：

- `player.gd`：字段 `input_source`（默认 `InputSource.new()`）+ `set_input_source()`；切枪轮询 `input_source.get_weapon_slot_pressed()`；攻击查询转发 `is_attack_*()`；`get_aim_dir_override()` 转发给武器。
- `weapon_base.gd`：`_aim_world_dir()` 里若 player 有 `get_aim_dir_override` 且非 ZERO → 用网络瞄准方向；攻击输入走 `player.is_attack_*()`（`has_method` 守卫回退真实 Input，兼容冒烟 StubPlayer）。
- 客户端本地玩家 = `InputSource.new()`（C2 照常读真实输入）；服务器两个玩家 = `NetworkInputSource` 注入包。

**边沿生命周期**：客户端每 tick 打包 pressed/released → 服务器 `apply_packet` 累积 → `clear_edges()` 在下一帧开头清空。边沿只活一帧，但**不因包批量到达而丢**（这正是抓梯/跳跃/开火在服务器上能复现的关键）。

---

## 9. 协议汇总（三套包）

| 包 | 方向 | 频率/模式 | 字段 |
|---|---|---|---|
| **输入包** | 客户端→服务器 | 每物理帧 / **reliable** | `ax`(float) `held`(int) `pressed`(int) `released`(int) `weapon`(int) `aim`(Vector2) |
| **快照包** | 服务器→客户端 | 30Hz / **unreliable** | `tick` + `players{role:{pos vel facing pose weapon hp waterproof downed}}` |
| **事件包** `bullet_spawn` | 服务器→客户端 | reliable | `scene pos vel speed range size color gravity hit_damage hit_impact explodes direct_damage fuse hit_fuse radius expl_damage expl_knock visual` |
| **事件包** `hit_event` | 服务器→客户端 | reliable | `victim_role damage source_pos` |
| **房间/对局** | — | reliable | `create_room join_room room_created room_joined match_start server_message` |

- 输入包 reliable：60Hz × ~20B ≈ 1.2KB/s/玩家，LAN/服务器模型下开销可忽略，**保边沿不丢**。
- 快照包 unreliable + `tick` 序号：客户端丢乱序旧快照。

---

## 10. 环面纪律（核心原则，代码处处贯彻）

1. **模拟用 canonical 真值**：服务器玩家、客户端本地玩家都 `wrap_to_range` 到 `[0,MAP)`。
2. **协议只传 canonical**：快照 `pos`、子弹 spawn `pos` 都是 canonical；服务器广播前 `wrap_to_range` 归位（子弹可能锚在射手副本偏移上）。
3. **渲染各端归最近副本**：自己 = 中间副本；对手/子弹 = `anchor_to_nearest(canonical, 自己)`。
4. **插值/校正走最短路径增量** `toroidal_delta_px(上一位, 目标)`，绝不 naive lerp canonical（否则跨接缝整屏滑动）。
5. 物理计算副本无关（9 副本地形逐像素相同），锚定是渲染层变换、在 `move_and_slide` 之后，不回喂物理。

---

## 11. 端到端数据流（典型时序）

```
客户端                      服务器                         对手客户端
每物理帧：
 本地模拟自己（C2）
 打包输入 ──── reliable ──→  MatchHost 队列缓冲
                            ↓ 下帧开头注入两个 NetworkInputSource
                            双方 Player._physics_process 权威模拟
                            子弹命中裁决 / 拆墙 / 新子弹登记
                            30Hz ── unreliable 快照(tick) ──→ 收快照
                                                              ├ 自己→自校正(分档)
                                                              └ 对手→Replica 最短路径插值
                            新子弹 ── reliable bullet_spawn ─→ 生成视觉子弹副本(apply_damage=false)
                            命中 ── reliable hit_event ──────→ 受害者即时白闪/击退
```

---

## 12. 测试

| 脚本 | 断言 | 跑法（用户自跑） |
|---|---|---|
| `Tests/pvp_room_smoke.sh` | 起服务器 + A 建房拿号 + B 加入 → 双方收到 `match_start` | `bash Tests/pvp_room_smoke.sh` |
| `Tests/pvp_match_smoke.sh` | A 建房后右移+开火，B 加入不动 → A 断言"收到快照且自己位置变了"，B 断言"收到快照 + 收到对手子弹 spawn 广播" | `bash Tests/pvp_match_smoke.sh` |

冒烟客户端脚本：`pvp_smoke_client.gd`（B1）/ `pvp_match_smoke.gd`（B2），经 `--role create|join --code XXXX` 驱动。命中/掉血不在 B2 覆盖（出生点相距远，无法确定性命中），留手动端到端。

---

## 13. 已知遗留与未实现（下一阶段入口）

**阶段 3 未做（设计文档有、代码没有）：**
- 回合制状态机（LOBBY→COUNTDOWN→PLAYING→ROUND_OVER→MATCH_OVER）、记分、复活、局间换边、击杀归因。现状**死亡即倒地、不复活**；PvP 下倒地按 R 不重载场景（`_unhandled_input` 有 `Level0.pvp_mode` 守卫）。

**已知边界 / 遗留问题：**
- **断线**：服务器清房间 + free MatchHost，但**不通知存活客户端**（无 `peer_left` 转给对端、无"对方退出→回菜单"）。
- **`tile_destroyed` 事件未同步**：服务器权威拆墙只重建自己的碰撞；客户端视觉子弹撞到"服务器已拆、客户端还没拆"的墙时会短暂分歧轨迹（可接受，快照/重建自愈）。
- **子弹散射随机量两端不同**：客户端视觉子弹散射角本地掷定，与服务器权威子弹不同 → 轨迹微差；命中由服务器裁决，可接受。
- **本地玩家子弹也是视觉副本**：`weapon_base.fire()` 里 `b.apply_damage = not Level0.pvp_mode`，PvP 下本地生成的子弹不裁决（避免自伤），伤害全由服务器裁决。
- **并发上限**：每房间一个完整世界模拟，进程内 2~4 局封顶（设计预留，未实测压力）。

### 近期修复史（从 git log 反推的稳定性演进）

| 提交 | 问题 → 修法 |
|---|---|
| `5558ad1` | 移动卡顿回拉 → 快照加 `tick` 丢弃乱序 + 自校正分档平滑（小忽略/中平滑/大硬回） |
| `e901254` | 服务器玩家溺水/回拉 → swim/climb 组件改走注入的 input_source（服务器读不到全局 Input）+ 回拉 SNAP 收窄到 2 格 |
| `2046143` | 服务器输入覆盖式丢 just_pressed 边沿（抓梯/跳跃失效）→ 改按序队列消费 |
| `c57fa1b` | 输入管线重设计：held/axis 每帧取最新（不滞后）+ 边沿累积不丢 + 队列缓冲整帧应用 |
