# 联机大厅合一 + 菜单系视觉重做

**日期**：2026-10-03 ｜ **状态**：设计定稿，待写实现计划
**性质**：前端重构为主（三个大厅页 → 一个）+ 服务端**加法式**扩键 + 菜单系换皮

---

## 0. 决策摘要

| # | 事项 | 裁定 | 来源 |
|---|---|---|---|
| 1 | 「合一」合到哪一层 | **UI 合一 + 房间列表合一**；服务端三套注册表与全部 RPC **原样保留** | 用户裁定 |
| 2 | 大厅主视图 | 混合列表 + 模式筛选器（`全部 / 1v1 / 3v3 / 大乱斗`） | 用户裁定 |
| 3 | 房卡形状 | **正方卡**，带地图缩略图；玩家名用名单行排布 | 用户裁定 |
| 4 | 创建/加入位置 | 筛选行右端两颗大按钮（`＋创建房间` / `加入房间`），加入走小弹层 | 用户裁定 |
| 5 | 右侧房主面板 | 收进**创建房间弹层**，点 `＋创建房间` 才展开 | 用户裁定 |
| 6 | 房卡字段 | **全都要**：扩 `is_public` / `host` / `map` / `match_time` / 队伍分布 五个键 | 用户裁定 |
| 7 | 主菜单 | 只剩 `单 人 模 式` / `多 人 模 式`；**Beta 保留为弱化按钮** | 用户裁定 |
| 7b | 版本信息 | 按钮改名 **`信 息`**，从**弹层**改成**整页**（新场景），内含 版本信息 / 开发团队 / 致谢 | 用户裁定 |
| 8 | 视觉风格 | **方向 B「遗迹青铜」**：青主色 + 琥珀强调、双层压边、标题带 | 用户裁定 |
| 9 | 风格覆盖范围 | **菜单系**（主菜单 / 设置 / 信息页 / 统一大厅 / Beta 页 / 结算页 / 暂停菜单）；**对局内 HUD 一律不动** | 用户裁定 |
| 10 | 本机显示 4 项 | 移到**设置页**新开一节「联机显示」 | 用户裁定 |
| 11 | 角色颜色 | 留在**等待室**，**不放创建弹层** | 本设计（沿用既有 D1 裁定） |
| 12 | 统一列表要不要新 RPC | **不要**：大厅页调三次现有列房 RPC、前端合并打标 | 本设计 |
| 13 | 模式色 | 1v1 青 / 3v3 **紫** / 大乱斗 琥珀 —— 3v3 **刻意避开队色蓝** | 本设计（§3.9.2） |
| 14 | 凭据模型 | `mode` 从「从哪个菜单按钮进来」改成「**凭据自带模式**」 | 本设计（§3.8） |
| 15 | 三个旧大厅页 | **整体退役删除**，不留兼容壳 | 本设计（§3.1.3） |

---

## 1. 背景与现状（带行号）

### 1.1 三个平行副本

| 页面 | 脚本 | 右侧面板 | 等待室 |
|---|---|---|---|
| 1v1 | `scenes/matchmaking.gd` | 「对战选项」**常驻**（`matchmaking.gd:87-124`） | **无**（两人凑齐自动开局） |
| 3v3 | `scenes/team_lobby.gd` | 「创建 3v3 房间」常驻（`team_lobby.gd:118-151`） | 有（`team_lobby.gd:332-363`，两队 + 未选边 + 选边按钮） |
| 大乱斗 | `scenes/royale_lobby.gd` | 「创建大乱斗房间」常驻（`royale_lobby.gd:106-141`） | 有（`royale_lobby.gd:346-378`，名单 + 角色颜色行） |

三者都 `extends LobbyPage`（`scenes/lobby_page.gd`，625 行）：连接状态机、转连 worker、回局路径、超时梯全在基类；子类只留版式、列表渲染、`_on_server_message`、超时梯顺序。

### 1.2 「不合理」的三处具体形态

1. **右侧面板在三个页面里语义不同**：1v1 那栏是**混合**的 —— 一半是服务器权威规则项（禁用武器 / 每回合回满血，以 role1 为准），一半是本机显示项（子弹尾迹 / 敌方血条 / 小地图）。加入者在看别人的房主设置，而房主设置对他无效（`matchmaking.gd:74-86` 自己把这件事写成了三段注释）。
2. **房间列表信息量太少**：三页都是 `620×46` 横条，只有「房间号 + 人数 + 玩家名」，而截图里列表区有大片空白。
3. **同一条概念留了三份实现**：列表渲染、建房面板、等待室在三页各一份，改一处漏两处**不报错**。

### 1.3 服务端现状：三套并行注册表

`server/lobby/lobby_rooms.gd`（910 行）持有 `rooms` / `royale_rooms` / `team_rooms` 三张表，各有一套 RPC：

- 1v1：`create_room(caller)` / `join_room` / `list_rooms` —— **走原版 `NetBus`**
- 大乱斗：`royale_create(caller, opts)` / `royale_join` / `royale_list(caller, token)` —— 走 `NetBusExt`
- 3v3：`team_create(caller, opts)` / `team_join` / `team_list(caller, token)` —— 走 `NetBusExt`

三个列表载荷（`lobby_rooms.gd:175` / `:541` / `:734`）**字段集完全一致且只有 6 个**：

```
code, players, max_players, names, in_match, beta
```

房卡上想要的 `is_public` / `host` / `map` / `match_time` / 队伍分布 **一个都没有**。

### 1.4 「对局中的房已经能看见」——这半边**已经做完了**

- 三个载荷都带 `in_match`（1v1 是 `room.started`，另两个是 `tr.in_match`）；
- 客户端 `btn.disabled = in_match and not mine`（`matchmaking.gd:219-231` / `royale_lobby.gd:281-293` / `team_lobby.gd:231-243`）；
- 服务端 `join_room` / `royale_join` / `team_join` 都拒（可见性与拒绝是同一件事的两半）。

**本设计只改它画成什么样（整体压暗 + 角标），不改这条语义。**

### 1.5 「房号空间三张表共用」是凭据模型的全部理由

`_generate_code()`（`lobby_rooms.gd:199`）是 `"%04d" % (randi() % 10000)`，三张表各查各的 `has(code)` ⇒ **同号共存是允许的**。因此 `PvpSession.mode`（`core/net/pvp_session.gd:35-66`）存在的唯一理由是：判「我在 1v1 攒的凭据 `room_code=9021`」会不会让**同号的 3v3 房**看起来像"我的房"。

它今天的写入点是**主菜单那三个按钮**（`main_menu.gd:234/240/245` 调 `enter_mode`），`reconnect_smoke` 有**正向**断言钉着这三处（`reconnect_smoke.gd:291-293`）。

---

## 2. 目标与非目标

**目标**

1. 三个联机模式**一个入口、一页大厅、一张混合列表**。
2. 房卡从横条变**正方卡**，显示模式 / 状态 / 人数 / 房主 / 地图 / 名单。
3. 房主选项从「常驻右栏」搬进「创建房间弹层」。
4. 菜单系（6 个界面）统一到方向 B 的视觉语言。

**不做**（写下来是为了防"顺手也做了"）

- **不动 `NetBus` 方法表**：`create_room` / `join_room` / `list_rooms` / `go_match` / `claim_role` 的签名一律不改（与原版服务端逐字节兼容是硬纪律）。新增一律进 `NetBusExt`。
- **不合并服务端三套注册表**，不合并 `RoyaleHost` / `TeamHost` / `MatchHost`。
- **不动对局内任何东西**：`ui/hud/`（`hud.gd` / `weapon_slots.gd` / `pvp_hud` / `royale_hud` / `team_hud` / `minimap`）、`level_0` 世界渲染、C2 链路 —— 一行不改。
- **不动单机流程**（`main_menu → sp_launch_panel → level_0`）。
- 不做观战 / 回放 / 好友系统 / 聊天。
- 不改三个对局场景（`pvp_game` / `royale_game` / `team_game`）与 worker 的任何行为。

---

## 3. 设计

### 3.1 入口与场景

#### 3.1.1 主菜单

```
The Cyancular Ruins
──────────────────
  单 人 模 式
  多 人 模 式
      (空档)
  设 置
  信 息
      (空档)
  Beta        ← quiet
  退 出        ← quiet
```

- `多 人 模 式` → `PvpSession.reset()` + `beta_mode = false` → `change_scene_to_file("res://scenes/mp_lobby.tscn")`
  - ★ **不再调 `enter_mode()`**（该函数整体删除，见 §3.8）。`reset()` 本身**不碰凭据**（`pvp_session.gd:138-158` 那条纪律原样成立）。
- `Beta` → 保留 `scenes/beta_menu.tscn`，但两张卡的目标场景改成 `mp_lobby.tscn`，并在切场景前置 `PvpSession.beta_mode = true` + 预选模式。

#### 3.1.2 统一大厅

新场景 `scenes/mp_lobby.tscn`（裸 `Control`，UI 全在代码里建 —— 与现有三页同款）+ `scenes/mp_lobby.gd`（`extends LobbyPage`）。

**基类 `LobbyPage` 保留并继续复用**（连接状态机 / 回局 / 超时梯是它最有价值的部分）。子类只剩 `mp_lobby` 一个。

#### 3.1.3 三个旧页退役

`scenes/matchmaking.{gd,tscn}` / `scenes/royale_lobby.{gd,tscn}` / `scenes/team_lobby.{gd,tscn}` **整体删除**（含 `.gd.uid`）。

**不留兼容壳**：本仓的判据一贯是"同一概念只有一份实现"，留三份瘦身壳等于把本次要消灭的重复原地保留。代价是 §5 那一批守卫要改（已逐条列出）。

### 3.2 大厅页版式（1920×1440，真实像素）

```
┌ 页边距 40 ─────────────────────────────────────────────────────────────┐
│ 昵称      [__________________520×64__________________]                 │
│ 服务器地址 [__________________520×64____] [刷新列表] [启动/重启本机服务器]   │  右侧：本机局域网 IP
│                                                                        │
│ [全部][1v1][3v3][大乱斗]  共 N 个房间 · 点击卡片直接加入   [＋创建房间][加入房间] │
│                                                                        │
│ ┌─房卡─┐ ┌─房卡─┐ ┌─房卡─┐ ┌─房卡─┐                                        │
│ └──────┘ └──────┘ └──────┘ └──────┘                                        │
│ ┌─房卡─┐ ┌─房卡─┐ …                                                       │
│                                                                        │
│ ┌ 状态栏 ─────────────────────────────────────────────[返回主菜单] ┐      │
└────────────────────────────────────────────────────────────────────────┘
```

**度量**

| 元素 | 值 |
|---|---|
| 页边距 | 40 |
| 输入框 / 按钮高 | 64（字号 32） |
| 标签列宽 | 200（字号 32） |
| 筛选行高 | 60，gap 12 |
| 卡网格 | 4 列，gap 22 ⇒ 卡宽 `(1920 − 80 − 66) / 4 ≈ 443` |
| 卡高 | 内容决定（约 400，两行共 822，落在可用高度 ~1000 内） |
| 字号 | 48（房间号）/ 32（正文、按钮、输入）/ 16（次要说明）—— **全是 16 的倍数** |

**「加入房间」小弹层**：`房间号` 输入 + `邀请码(私密)` 输入 + `加入` 按钮。私密房不在列表里（只有持凭据的本人看得见），所以邀请码输入是加入私密房的**唯一**途径，必须留。

**模式筛选**：纯**客户端**过滤 —— 三份载荷合并后按模式打标，筛选器只决定画哪些。

### 3.3 房卡字段

```
┌──────────────────────────────┐
│ 大 乱 斗            等待中    │ ← 标题带：模式色底 + 状态
├──────────────────────────────┤
│ C7F2                         │ ← 房间号 48px
│ 公开 · 限时 5 分              │ ← 一行副标
│ ┌────┐ 人数 3 / 8            │
│ │地图│ 房主 Anon             │ ← 左缩略图 + 右键值
│ │缩略│                       │
│ └────┘                       │
│ · Anon（房主）                │ ← 玩家名单行
│ · 一个很长的昵称              │
│ · Bbb                        │
└──────────────────────────────┘
```

**字段 → 数据来源**

| 卡片字段 | 来源 | 现状 |
|---|---|---|
| 模式 | 前端合并三张表时打标 | ✅ 免费 |
| 房间号 | `payload.code` | ✅ 已有 |
| 状态 | `payload.in_match` | ✅ 已有 |
| 人数 | `payload.players` / `max_players` | ✅ 已有（1v1 载荷无 `max_players`，前端补恒 2） |
| 名单 | `payload.names` | ✅ 已有 |
| 公开·私密 | **新增 `is_public`** | ⚠️ 现在私密房靠"过滤掉"实现，载荷不告诉你这是私密房 |
| 房主 | **新增 `host`**（昵称串） | ❌ 需新增 |
| 地图 | **新增 `map`**（路径；空 = 随机） | ❌ 需新增，**且创建时要上报**（§3.7.2） |
| 限时 | **新增 `match_time`**（秒，仅大乱斗） | ❌ 需新增 |
| 队伍分布 | **新增 `team_counts`**（仅 3v3） | ❌ 需新增 |

**名单行会被卡片高度限制**：最多画 3 行，超出显示 `…等 N 人`。长度用 `UiFactory.fit_name(name, N)` 定宽截断（与结算页同款，别另写一份）。

**「对局中」的卡**：整体 `modulate.a ≈ 0.55` + 状态角标改 `对局中` + **不接 handler、不吃键盘焦点**（与今天逐字同款的两半：`disabled` 是观感，真正的"点不动"是没连 handler）。自己的房（持凭据）**例外**：正常亮度、可点回局。

### 3.4 创建房间弹层

点 `＋创建房间` 弹出，**居中 + 半透明压暗罩**；右上角 `×` 关闭，`Esc` 也能关。

```
┌ 创 建 房 间 ──────────────────────────────── [×] ┐
│ 模式                                            │
│ [1 v 1][3 v 3][大乱斗]        ← 分段按钮          │
│ 房间                                            │
│ [公开][私密]  [邀请码(留空自动生成)]              │
│ 人数上限  ▬▬▬●────  4 人      ← 仅大乱斗          │
│ 一局限时  ▬▬●──────  5 分      ← 仅大乱斗          │
│                                                 │
│ 禁用武器（勾选 = 本局不可用）  地图               │
│ ◻ 手枪    ◻ 步枪            [随机][newfactory][demo] │
│ ◻ 重狙    ◻ 霰弹              ← 仅 1v1 / 大乱斗    │
│ ◻ 榴弹    ◻ 激光                                 │
│                                                 │
│                    [取 消]  [创 建 房 间]         │
└─────────────────────────────────────────────────┘
```

**按模式变形的行**（这是本弹层唯一的分支，收在一处 `_apply_create_form(mode)`）：

| 行 | 1v1 | 3v3 | 大乱斗 |
|---|---|---|---|
| 人数上限 / 一局限时 | 隐藏 | 隐藏（容量恒 `LobbyRooms.TEAM_ROLES`、赛制三局两胜） | 显示 |
| 禁用武器 | 显示 | **隐藏**（3v3 规则表里没有它；且那两个勾选框写的是 `Settings.pvp_disabled_weapons`，在 3v3 勾一下会**连带改掉另两个模式**） | 显示 |
| 地图 | 显示 | 显示 | 显示 |
| Beta 时间参数 | beta 态显示 | 同左 | 同左 |

★ **角色颜色不在这里**：它在**等待室**。理由是既有裁定（`royale_lobby.gd:132-134`）：创建面板一进等待室就隐藏，放这儿等于"房主建完房改不了、加入者全程没见过"。

### 3.5 等待室

一个面板，按模式渲染（今天 royale / team 各有一份，1v1 没有）：

| 模式 | 内容 |
|---|---|
| 1v1 | `等待对手… 1 / 2` + `退出房间`（**新增**：今天 1v1 建房后没有任何"我在等"的界面，状态只落在状态栏） |
| 3v3 | 两队名单 + 未选边档 + `加入 A 队` / `加入 B 队` + 房主 `开始游戏` + `退出房间` |
| 大乱斗 | 名单 + `N / M 人` + 房主 `开始游戏` + `退出房间` |

**共有的尾巴**：`自己角色颜色` 行（**仅 1v1 / 大乱斗**；3v3 用队色、个人色相无效）+ `退出房间`。

★ **编号印行序不印 role**（role 是最小空闲号分配、有人退出不重排）—— 沿用现有两页的注释纪律。

### 3.6 设置页新增「联机显示」

`scenes/settings_menu.gd` 现在只有两节（`:38` 音量 / `:52` 按键映射）。新增第三节：

```
—— 联机显示 ——
显示子弹尾迹(所有子弹)        [开关]
显示敌方血量条                [开关]
打开小地图                    [开关]
小地图显示敌方位置            [开关]
```

四项各直写 `Settings.pvp_show_trajectories` / `pvp_show_enemy_hp` / `pvp_show_minimap` / `pvp_minimap_show_enemy` + `save()`。**这四个键一个都不新增、不上报**（它们只有本机读者：`pvp_match_client` / `royale_game` / `team_game` 在 `_ready` 里读）。

### 3.7 服务端

#### 3.7.1 列表载荷扩键（三处，纯加法）

`room_list_payload()` / `royale_list_payload()` / `team_list_payload()` 各加：

```gdscript
"is_public": <bool>,          # 1v1 恒 true（1v1 没有私密房）
"host":      <String>,        # 房主昵称；1v1 = 房间创建者（role1）
"map":       <String>,        # 空串 = 随机（§3.7.2）
```

大乱斗载荷另加 `"match_time": <int 秒>`；3v3 载荷另加 `"team_counts": {"1": n, "2": n, "0": n}`。

- **`host` 的取法**（三张表的房对象形状不同，逐类写死）：
  - `RoyaleRoom` / `TeamRoom` 有 `host_peer`（`lobby_rooms.gd:53` / `:80`）⇒ 未开局取 `_peer_names.get(host_peer)`；已开局取 `roster` 里 `role == player_role[host_peer]` 那条的 `name`（`roster` 是 `[{role, name}]`）。
  - `Room`（1v1）**没有 host 概念** ⇒ 取 `players[0]` 的昵称（`create_room` 的 caller，即建房者）。已开局时 `players` 已空，退回 `roster[0].name`。
- **`is_public`**：`RoyaleRoom` / `TeamRoom` 直接读字段；`Room`（1v1）**恒 `true`** —— `create_room(caller)` 没有私密房这条路径。
- **`map`**：读房记录上由 `room_map`（§3.7.2）写入的字段；**没写过就是 `""`**（含所有在本次改动之前建的房）。

#### 3.7.2 地图上报：一条新 `NetBusExt` RPC

```
NetBusExt.room_map(code: String, path: String)      # 客户端 → 大厅
```

- **谁发**：建房成功后由**房主端**发一次（房主 = 建房的那个人；1v1 里就是 role1）。
- **服务端**：找不到该 code / caller 不是该房成员 ⇒ 静默丢弃（不踢、不回话）。写进房记录的 `map` 字段。
- **为什么所有模式统一走它**：1v1 的 `create_room` 是**原版 NetBus 的 RPC，签名冻结**，塞不进 payload。而大乱斗/3v3 的 create 载荷虽然是字典（加键免费），但用两条机制会让"地图从哪来"这件事分叉 —— 本仓一贯的判据是同一概念只留一份实现。

**已知窗口（照实登记）**：`create` 与 `room_map` 之间有一个 RTT，期间**别的**客户端刷新列表会看到这张卡暂时没有缩略图（下一次刷新自愈）。本端**自己**那张卡直接用本地 `Settings.mp_map_path` 乐观渲染，不受影响。

#### 3.7.3 不需要统一列表 RPC

大厅页在 `_request_list` 里**同时发三条**：

```gdscript
NetBus.rpc_id(1, "list_rooms")
NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
NetBusExt.rpc_id(1, "team_list", PvpSession.token)
```

三条应答各自到达、各自并入一张客户端表（按 mode 打标），全部到齐或超时后重绘。`token` 仍然要带（B1 甲案：私密房只对持凭据的本人列出，见 `royale_lobby.gd:428-432`）。

★ **代价照实登记**：三次往返、三份应答，列表刷新的延迟由最慢那份决定。这是"不动服务端注册表"换来的。

### 3.8 凭据模型修正

**问题**：`mode` 今天是「玩家从主菜单按了哪个按钮」，写入点是三个按钮（`main_menu.gd:234/240/245`）。合一后**没有这三个按钮了**，而"三张表房号空间重叠"这个前提**一个字没变** ⇒ 不修就会串模式。

**新形状**：把模式**记进凭据本身**。

```gdscript
static var room_mode: String = ""    # 凭据所属模式（替代 mode 的旧语义）

static func note_room(code: String, mode: String) -> void:
    if code != room_code or mode != room_mode:
        clear_rejoin()
    room_code = code
    room_mode = mode

static func can_rejoin_to(code: String, mode: String) -> bool:
    return can_rejoin() and room_code == code and room_mode == mode
```

- `enter_mode()` **删除**（连同它的 `mode` 字段）。
- `reset()` 仍**不碰凭据**（那条纪律原样保留）。
- 三个调用点（建房成功 / 加入成功 / 等待室状态）都改成 `note_room(code, mode)`。
- `try_rejoin_row(code, in_match)` 加一个 `mode` 形参，**两个条件的次序不变**（先问"是不是我的房 + 凭据还在"，再轮到 `in_match`）—— 那条次序是本仓用一次全绿事故换来的（见 `main_menu.gd:225-230` 与 `lobby_page.gd:298-304`）。

**为什么这版更准**：旧模型下"换个模式看看"会把凭据清掉（哪怕玩家还会回来）；新模型下凭据绑定的是**那间房**，与玩家当前在浏览什么无关。

### 3.9 视觉规格（方向 B「遗迹青铜」）

#### 3.9.1 调色板扩展（唯一来源仍是 `ui/factory/ui_factory.gd`）

| token | 值 | 用途 |
|---|---|---|
| `C_BG` | `#0C1116` | 页面底（内层再加 `inset 0 0 0 2px #0A0E12` 做压边） |
| `C_SURFACE` | `#141A20` | 面板底（**不透明** —— 半透明会让下层透上来重影，既有纪律） |
| `C_HEADER` | `#1B242C` | 标题带 / 按钮填充 |
| `C_FIELD` | `#0E1419` | 输入框底（比面板更暗 = 凹） |
| `C_BORDER` | `#2A3540` | 面板外描边 |
| `C_INNER` | `#1E2830` | 面板内亮线（凿刻感的那一层） |
| `C_EDGE` | `#46545F` | 按钮描边 |
| `C_ACCENT` | `#5AD1DE` | 强调青（**与对局内 HUD 同源**，一像素不改） |
| `C_GOLD` | `#E0A94F` | 琥珀：分区标题 / 主行动按钮（创建房间） |
| `C_TEXT` | `#E0E9F2` | 主文本 |
| `C_TEXT_DIM` | `#93A0AE` | 次要文本 |
| `C_TEXT_MUTE` | `#6C7885` | 禁用文本 |

**三条纪律不变**：① 颜色只在 `UiFactory` 定义；② 字号必须是 16 的倍数；③ 面板底不透明。

#### 3.9.2 模式色（新增，独立于队色）

| 模式 | 色 | 值 |
|---|---|---|
| 1v1 | 青（= `C_ACCENT`） | `#5AD1DE` |
| 3v3 | **紫** | `#A08CFF` |
| 大乱斗 | 琥珀 | `#E8A33D` |

★ **3v3 不用蓝是刻意的**：`#639BFF` **就是** `UiFactory.C_TEAM_A`（队 1 的队色），而队色是 3v3 里**有玩法语义**的颜色（"一眼看出谁是队友"）。拿它当模式色会让大厅里的"3v3"标签与对局里的"队 1"撞色。

#### 3.9.3 覆盖范围与不动的东西

**改**：`main_menu` / `settings_menu` / **`info_menu`** / `mp_lobby` / `ui/screens/match_result` / `ui/screens/pause_menu` / `beta_menu`。

**一律不动**：`ui/hud/**`（含 `weapon_slots` / `pvp_hud` / `royale_hud` / `team_hud` / `minimap`）、`ui/factory/weapon_icons`、`ui/map_picker`（只换外框）与全部世界空间渲染。

★ `C_PLATE` / `C_SLOT_*` / `C_TEAM_*` / `C_GRACE` / `C_WARN` **一个都不动** —— 它们服务对局内 HUD，本次不碰。

### 3.10 「信 息」页（取代版本信息弹层）

主菜单那颗 `版 本 信 息` 改名 **`信 息`**，点击**切场景**到一个新页面（不再是在主菜单上弹面板）。

**布局**（1920×1440）：标题 `信 息` → 左右两栏 → 底部 `返 回(Esc)` 居中。

| 栏 | 内容 |
|---|---|
| 左（宽 1.25） | **版本信息**：当前版本 + 构建时间 + 提交历史（`ScrollContainer`，最多 20 条） |
| 右（宽 1） | **开发团队** 面板 + **致谢** 面板 |

**开发团队**（用户给定，**不分职责、按序一人一行**；共 **4** 人）：

```
RoFtaCD
KikuchiH
Lord Nahiz Waugh
siri2048
```

★ `Lord Nahiz Waugh` 是**一个人**（三段名），**不是** `Lord Nahiz` + `Waugh` 两人 —— 初稿在这里拆错过一次。

**致谢**（用户给定，五条；前三条是软件/素材，后两条是文学灵感，**写拉丁字母全名**）：

```
Godot Engine            MIT
GNU Unifont             SIL OFL 1.1
Less Perfect DOS VGA    Zeh Fernando / Laemeur
Thomas Stearns Eliot
Jorge Luis Borges
```

★ 第三条的人员归属**不是猜的**：从 `assets/fonts/less_perfect_dos_vga.ttf` 的 `name` 表读出
`manufacturer = "zeh;laemeur"`、版权 URL 为 `fatorcaos.com.br` 与 `laemeur.com`（族名 `Less Perfect DOS VGA`，版本 2013 v1.0）。仓里**没有**该字体的许可文件（只有 `unifont-LICENSE.txt`），故本行**只署名、不断言许可条款**。

★ **后两条是作品来源，不是软件依赖** —— Borges 的 *Las ruinas circulares*（《环形废墟》，标题 *The Cyancular Ruins* 的出处）与 Eliot 的 ***Four Quartets*（《四个四重奏》）**是本作标题与气质的出处。按用户要求**写全名**（T. S. Eliot 的常用缩写形式不采用）。

★ **KH 不单列一条**：用户明确 `KH` 即 `KikuchiH`，已在开发团队名单里。

**保留下来的两条既有纪律**（来自被取代的 `version_panel.tscn` / `main_menu._fill_version_panel`）：

1. **提交行钉死行宽 + 末尾省略号** —— `ScrollContainer` 不收缩子节点，不钉的话超长标题会在右沿被切成半个字（`main_menu.gd:343-349` 的实测记录）。
2. **`--nover` 的收口在 `version_string()` 内部**（`main_menu.gd:118-130`），不在调用方分叉 —— 该函数随本次搬家一起走。

**`version_string()` / `commit_log()` 的归处**：它们今天是 `main_menu.gd` 的静态函数（`:118` / `:134`），而搬家后**两个页面都要用**（主菜单左下角仍有版本号行）。新增一个纯静态、零 autoload 依赖的 `core/config/app_info.gd`（`class_name AppInfo`，与 `WeaponRegistry` 同形），两个页面都从它读。
★ **不能放进 `core/config/build_info.gd`** —— 那个文件由 `tools/build_release.py` 在导出前**覆盖写入**、导出后还原，扔进去会被构建流程盖掉。

---

## 4. 数据流

```
主菜单「多人模式」
   └─ PvpSession.reset()（不碰凭据）
      └─ change_scene → mp_lobby

mp_lobby._ready
   ├─ _finish_lobby_ready()（基类：接信号 + 递归补字体 + 自动拉一次列表）
   └─ 拉列表 = 三条 RPC 并发
        ├─ list_rooms      → _on_room_list(1v1)      ┐
        ├─ royale_list     → _on_royale_rooms        ├─→ _merge_and_draw()
        └─ team_list       → _on_team_rooms          ┘   （按 mode 打标 → 筛选 → 画卡）

点卡片
   ├─ can_rejoin_to(code, mode) 且 in_match  → try_rejoin_row → rejoin_request → go_match
   ├─ in_match（不是我的）                    → 不连 handler、不吃焦点
   └─ 其他                                    → _join_code(code, mode, invite)

点「＋创建房间」→ 弹层 → 选定模式 → 建房 RPC（按模式分派）
   └─ 成功 → note_room(code, mode) → room_map(code, Settings.mp_map_path) → 等待室
```

---

## 5. 守卫与测试影响（**逐条**，这是本设计最大的回归面）

### 5.1 会因为"三个页没了"而**变红**的（必须同步改）

| 守卫 | 现状 | 改法 |
|---|---|---|
| `tests/smoke/lobby_parse_smoke.gd:9` | 硬编码 `TARGETS` = 三个 `.tscn` | 换成 `res://scenes/mp_lobby.tscn` |
| `tests/probe/lobby_row_probe.gd` | 三页 × 8 条 = 24，比对期望条数 | 改成对 `mp_lobby` 的一页断言（卡不可点 = `disabled` + **0 连接**，两半都要） |
| `tests/smoke/reconnect_smoke.gd:41-43` | `PAGE_1V1/PAGE_ROYALE/PAGE_TEAM` 三个常量 | 合一为 `PAGE_MP`；§「主菜单三个按钮走 enter_mode」那条正向断言（`:291-293`）**整体重写**为 `note_room(code, mode)` 的判别 |
| `tests/smoke/reconnect_smoke.gd:222` | 页面清单里三个页 | 换 `mp_lobby.gd` |
| `tests/smoke/reconnect_smoke.gd:317-318` | 三页各自 `note_room(` | 只查 `mp_lobby.gd` |
| `tests/probe/lobby_visibility_probe.gd` | 相⑤⑥⑦⑧⑨ 直接挂三个页 | 全部改挂 `mp_lobby`；**相⑧ 那条次序断言与它的正向对照必须保留** |
| `tests/smoke/room_sweep_smoke.gd:454-469` | 读 `scenes/royale_lobby.gd` 的秒换算（上界链**环二**） | 改读 `scenes/mp_lobby.gd` 的同一行（`Settings.royale_match_min * 60.0`）。**这一条绝不能漏** —— 漏了 = `ROYALE_MATCH_TIME_CEILING` **静默失效** |
| `tests/probe/kh_l5_probe.gd:55` | `L5_FONT_FILES` 含 `royale_lobby.gd` | 换 `mp_lobby.gd` |
| `tests/smoke/menu_autotest.gd:63-69` | `--autotest-{mp,royale,team}` 三个模式、`must_reach` 三个场景 | 合一：`mp/royale/team` 都指向 `mp_lobby.tscn`（+ 对应的筛选态） |
| `tests/smoke/menu_autotest.gd:71` + `:14` | `--autotest-ver` 按「**弹层，不切场景**」写：**不列进 `must_reach`**，注释明说"对它断言 scene 路径是同义反复" | **语义反转**：信息页现在**切场景** ⇒ `must_reach` 加 `"ver": "info_menu.tscn"`，`:14` 的注释同步改。★ 反过来，**主菜单的 `信 息` 按钮文案**也进了这条链（按 `_press_by_text` 找按钮），按钮改名必须与探针同时改 |
| `tests/harness/*_watcher.gd`（4 个） | 按名找 `matchmaking.gd` / `royale_lobby.gd` | 换 `mp_lobby.gd` |
| `tests/probe/{rejoin_probe,royale_bound_probe,royale_c2_probe,royale_soak_probe,team_match_probe}.gd` | 引用旧页场景 | 换 `mp_lobby` |
| `server/lobby/room_manager.gd:43-45` | 注释指 `scenes/royale_lobby.gd` | 改指 `mp_lobby.gd` |
| `scenes/pvp_match_client.gd:1073` | 注释指 `matchmaking`/`royale_lobby` | 改指 `mp_lobby` |

### 5.2 被 §3.9 视觉改动作到、需要**人眼重取图**的

`tests/probe/kh_l4_visual_probe.gd`（主菜单/暂停菜单取图）、`menu_autotest` 的 `--autotest-{mp,royale,team,set,ver}` 截图。

### 5.3 明确**不受影响**的

`ui_palette_single_source_smoke`（只钉 `C_PLATE` 与两个 `.tscn`，本次不动它们）、`kh_l3_visual_probe`（HUD 三态）、`pvp_hud_layout_probe`、`hud_declarative_probe`、`minimap_circle_probe`、`combat_hud_visual_probe`、`squash_*`、全部对局内探针。

### 5.4 本次**没有**守卫、要靠新守卫兜的（写进实现计划）

1. **房卡四个新字段真的画出来了**（`is_public` / `host` / `map` / `match_time` / `team_counts`）—— 载荷给了但没渲染，今天**不报错**。
2. **`room_map` 的房主校验**（非房主发 ⇒ 不写）。纯服务端逻辑，可 `-s` 测。
3. **三个载荷的键集**（`lobby_parse_smoke` 那类"载荷形状"断言目前**不存在**）。
4. **创建弹层的按模式变形**（3v3 不显示禁用武器 / 人数行）—— 今天没有守卫，且这条有真实危害（在 3v3 页勾禁用武器会污染 `Settings.pvp_disabled_weapons` ⇒ 连带改掉另两个模式）。

---

## 6. 已知边界（照实登记，别读成"已处理"）

1. **列表刷新由最慢的那条 RPC 决定**（§3.7.3），三条并发、三份应答。
2. **地图上报有一个 RTT 的窗口**（§3.7.2）：别的客户端在此期间看到无缩略图的卡。
3. **地图的"两处真值"**：列表上的 `map` 是**创建时**上报的快照；而真正决定本局建什么世界的仍是 `_player_options()` 里**报到那一刻**读的 `Settings.mp_map_path`（`server_main._on_player_options` → `MapCatalog.resolve_pvp_map`）。房主在建房后改设置，会让卡片显示与实际地图**不一致**。本次**不统一**（统一要动 worker 的定图路径，超出范围）。
4. **1v1 的等待室是新增的**（今天没有），它不影响开局逻辑（1v1 仍是两人凑齐自动开局）。
5. **私密房仍然只对持凭据的本人列出**（B1 甲案不变）；卡上的「私密 · 我的」角标只在那一档出现。
6. **`beta` 房与普通房互不可见**的语义**不动**（客户端过滤 + 服务端 join 守卫两道都在）。

---

## 7. 风险

| 风险 | 缓解 |
|---|---|
| 删三个页 = 一批守卫同时红，容易"改到绿为止"而放过真问题 | §5.1 是**逐文件清单**，实现计划按它逐条走；每条改完必须在**改之前**确认它红得"有理由"（不是 Parse Error） |
| 上界链环二（`room_sweep_smoke` 读 royale_lobby.gd）漏改 ⇒ 静默失效 | 单列一行（§5.1），且实现计划里作为**独立任务**，附变异验证（改坏 `match_time` 那一行 ⇒ 该守卫必须红） |
| `enter_mode` 删除后**回局凭据串模式**（三张表房号重叠） | §3.8 的新判据 + `lobby_visibility_probe` 相⑦ 的真值表扩一条"**模式不同 ⇒ 不可点**"，并配一条**正向对照**（模式相同仍可点） |
| 视觉改动把菜单系改丑 | 每个界面改完取图人眼验收（本仓既有纪律），不是"跑绿就算" |

---

## 8. 给实现计划的契约

**新增/改变的接口**

```
scenes/mp_lobby.gd            extends LobbyPage        （新，取代三个子类）
scenes/mp_lobby.tscn                                    （新）
scenes/info_menu.gd / .tscn                             （新，「信 息」整页）
core/config/app_info.gd       class_name AppInfo        （新，纯静态）
                              version_string() / commit_log()
                              ← 从 main_menu.gd:118 / :134 搬来
core/config/settings.gd        无新增键（复用 4 个既有 pvp_* 显示键）
core/net/pvp_session.gd        + room_mode
                               note_room(code, mode)     ← 签名变（加参）
                               can_rejoin_to(code, mode) ← 签名变（加参）
                               − enter_mode / − mode     ← 删除
core/net/net_bus_ext.gd        + room_map(code, path)    ← 新 RPC（下行应答无）
server/lobby/lobby_rooms.gd    + on_room_map(caller, code, path)
                               三处 *_list_payload() 各加 3~5 个键
ui/factory/ui_factory.gd       + C_SURFACE/C_HEADER/C_FIELD/C_BORDER/C_INNER/C_EDGE/C_GOLD/C_TEXT_MUTE
                               + C_MODE_1V1 / C_MODE_TEAM / C_MODE_ROYALE
                               （既有 token 一个不改）
scenes/settings_menu.gd        + 「联机显示」一节（4 个开关）
scenes/main_menu.gd            按钮列重排；删 3 处 enter_mode；
                               删 _ver_panel / _fill_version_panel / _on_version_pressed
                               + version_string / commit_log（搬去 AppInfo）
                               「版 本 信 息」按钮改名「信 息」+ 改切场景
scenes/beta_menu.gd            两张卡改指向 mp_lobby + 预选模式
```

**删除**

```
scenes/matchmaking.gd / .tscn / .gd.uid
scenes/royale_lobby.gd / .tscn / .gd.uid
scenes/team_lobby.gd / .tscn / .gd.uid
ui/screens/version_panel.tscn（+ .uid）   ← 被 info_menu 整页取代
core/net/pvp_session.gd 的 enter_mode() / mode
```

**不动**

```
ui/hud/**            对局内全部
server/hosts/**      RoyaleHost / TeamHost 行为
server/match/**      MatchHost / C2 链路
scenes/{pvp,royale,team}_game.*
scenes/level_0.*
```

### 8.1 建议的实施顺序

按"先能跑、再好用、最后好看"三段，每段自己可测：

1. **服务端扩键 + `room_map`**（§3.7）—— 纯加法，三个旧页**照旧能跑**，单独可验。
2. **凭据模型**（§3.8）—— `PvpSession` 改签名 + 三个旧页跟着改（这一步旧页还在，改完它们仍可用）。
3. **合一**（§3.1-3.5）—— 建 `mp_lobby`、改主菜单、改 `beta_menu`、删三个旧页、**同步改 §5.1 全部守卫**。这是最大的一段。
4. **设置页「联机显示」**（§3.6）+ **「信 息」页**（§3.10）—— 两件独立小事，可单独做。★ 信息页依赖第 5 段的视觉 token，但不依赖它的完成：先按现有配色建页、最后一起换皮即可。
5. **视觉重做**（§3.9）—— 放在最后：此时页面结构已定型，换皮不动布局逻辑。

★ 第 3 段与第 5 段**不要并行** —— 视觉改动会大范围重写建控件的代码，与结构改动叠在一起，回归原因会分不清。

---

## 9. 附：本设计的视觉稿

浏览器的可视伴侣会话留下了全部迭代稿（`.superpowers/brainstorm/856-1790962513/content/`）：

```
room-cards.html            房卡三变体（第 1 轮）
room-cards-v2.html         房卡定形 + 创建/加入三方案
style-directions.html      三种全局风格（A 描边 / B 遗迹青铜 / C 色块）
style-b-draft.html         B 草案（含主菜单 + 大厅整页 + 创建弹层）
style-b-draft-v2.html      B 定稿（真实像素：顶部两行加大 / 4 列卡 / × 关闭）★
main-menu-two.html         主菜单改两颗 + Beta 三选一
final-menu-and-fields.html 主菜单定稿（Beta 弱化）+ 房卡字段账 ★
settings-and-version.html  设置页两栏 + 版本弹层
info-page.html             「信 息」整页（版本 / 开发团队 / 致谢）
```

★ 标记的两个是**最终定稿**：`style-b-draft-v2.html`（大厅整页 + 创建弹层）、`final-menu-and-fields.html`（主菜单）。
其余是过程稿 —— 留档是为了"当时为什么否掉那一版"有据可查，**不要照它们实现**。
