# 对局中的房:看得见、进不去 —— 设计

**日期**：2026-09-21 ｜ **状态**：设计，待评审 ｜ **分支**：`feat/3v3-fixes`
**前置**：无（这是**独立的一批**，不依赖任何未落地的计划）
**后继**：`docs/superpowers/plans/2026-09-21-rejoin-after-leaving.md`（回大厅后回局，**依赖本设计交付的房寿命与 pid 判据**）

## 0. 决策摘要

| # | 事项 | 裁定 | 谁提的 |
|---|---|---|---|
| 1 | 可见性范围 | **甲**：三张注册表**各自独立**，每页只列自己模式的房；**对局中的房也列**。**不做**跨模式合并列表 | 用户 |
| 2 | 对局中的房能不能进 | **不能**。可见 ≠ 可加入（用户原话：「所有人都可以看到所有房间(包括游戏已经进行的房间)…无论在对战还是掉线 C 都不应该进去」） | 用户 |
| 3 | 「记录」放哪 | **不新立表**：让既有的三个房类的**寿命从「最后一个人离开」延长到「这一局的 worker 进程退出」**。三个房类的记录**就是**那份记录 | 本设计（见 §2） |
| 4 | 怎么退役 | **worker 进程活性**（`OS.is_process_running(pid)`，30s 梯轮询）+ 既有的 2h 超龄清扫兜底 | 本设计（见 §2.4，含**照实登记的 pid 复用风险**） |
| 5 | 数据包怎么加 | 三个模式的房间列表数据各加**同名同义**的一个键 `in_match: bool`（向后兼容扩展，老客户端忽略未知键） | 本设计（见 §3） |
| 6 | 拒绝怎么保证 | **两半**：服务端 join 守卫（保证）+ 界面 `disabled` 行（体验）。★ 只做列表不做拒绝 = 陷阱 | 本设计（见 §5） |

**范围外（明确不做，见 §7）**：回局（token / `reclaim_role` / 场景重建 / 主菜单入口）、HUD 的「掉线中·重连中」、观战、补位加入、跨模式合并列表、worker 崩溃恢复。

---

## 1. 今天为什么看不见（事实，带行号）

三条链路**都在「客户端转连 worker」那一刻把房拆掉**，所以第三人刷新列表时它已经不存在了：

| 模式 | 拆房的那一行 | 为什么它一定会被走到 |
|---|---|---|
| 1v1 | `server/lobby_rooms.gd:254` `if room.players.is_empty() or room.started:` → `:262` `teardown_room(room)` | `started` 在配对那一刻就被置真（`server/room_manager.gd:248`，在 spawn 之前）。两个玩家拿到 `go_match` 后都会 `NetBus.stop()` 断开大厅 → **第一个** `peer_left` 就命中 `or room.started`，房当场被拆 |
| 大乱斗 | `server/lobby_rooms.gd:270` `if rr.players.is_empty():` → `:273` `teardown_room(rr)` | 全员转连后 `players` 空掉 → 拆 |
| 3v3 | `server/lobby_rooms.gd:301` `if tr.players.is_empty():` → `:302` `teardown_room(tr)` | 逐字同款 |

★ 就算房活下来，**列表这一侧也还会再挡一道**：`royale_list`（`:458`）与 `team_list`（`:623`）都写着 `if rr.in_match or ... : continue`。1v1 更彻底 —— `on_list_rooms`（`:143`）连 `in_match` 这个概念都没有（只跳过空房），因为在那之前房就已经没了。

**这个拆除不是多余的**，它挡的是两个已经付过代价的失败模式（注释就在现场：`:250-254`、`:266-273`、`:284-290`）：

- **幽灵房**：对局实际已死，房却常驻列表，可被反复加入 → 重复拉起 worker；
- **僵尸 worker / 端口泄漏**：worker 还占着 UDP 端口，房却没人认领。本层为「端口泄漏」这**同一个**失败模式补过三次，最后收成单一统一收拢 `teardown_room`（`:686`），并由 `tests/room_sweep_smoke.gd:83` 的 `_check_teardown_funnel` 断言约束纪律：**端口归还与注册表删除只能出现在 `teardown_room` 与 `_release_port_later` 两个函数体内**（模式表在 `:120`：`_release_port_later(` / `launcher.release_now(` / `royale_rooms.erase(` / `team_rooms.erase(` / `rooms.erase(`）。

★ **所以本设计的第一条硬约束**：拆房这件事只是**换了触发时机**，不是取消 —— 任何"不拆"的改动都必须**同时**给出替代的回收路径，而那条路径必须仍然走 `teardown_room`。

---

## 2. 记录的形状与寿命

### 2.1 裁定：不新立表，改**寿命**

房记录里已经有的东西，恰好就是列表要用的全部：`code` / `players` / `player_role` / `worker_port` / `created_at`，加上区分"在对局中"的那一个布尔（1v1 是 `started`，另两模式是 `in_match`）。

**要改的是它的寿命，不是它的位置**：

| 事件 | 今天 | 本设计 |
|---|---|---|
| 成员转连 worker（断开大厅） | **拆房**（可见性死亡） | `players` 里摘掉（它的语义仍然是「此刻还连在大厅这个房里的人」），**房不拆** |
| 成员点「退出房间」（`royale_leave:431` / `team_leave:598`） | 空房即拆 | 在对局中时不拆（同上） |
| 这一局的 worker 进程退出 | 无此路径 | 回收梯发现（≤30s）→ `teardown_room(..., TEARDOWN_DELAYED)` |
| 房龄 > 2h（`MAX_ROOM_AGE`） | 强杀 + 拆（`_sweep_stale_rooms`） | **不变**（兜底） |
| 拉起 worker 失败 | `TEARDOWN_ABORT` 立即归还 + 拆 | **不变** |

### 2.2 多加两个字段

```gdscript
var worker_pid: int = 0     # spawn 成功后登记;回收判据的输入
var roster: Array = []      # 开局那一刻冻结 [{role:int, name:String}]
```

- `worker_pid`：由 `RoomManager` 在 `OS.create_process` 成功之后经 `WorkerLauncher.pid_of(port)` 登记。
- `roster`：由 `freeze_roster(room)` 在**每一处开局**（`_start_match` / `royale_start` / `royale_start_ai` / `team_start`）冻结一次。★ **必须冻结**：成员转连后 `players` 会空、`_peer_names` 会被 `on_peer_left:243` 擦掉，对局中的列表如果读它们，渲染出来就是「玩家, 玩家」。

**键 = 房号，但只在自己那一张注册表里。** 这直接回答"怎么避开三张表的房号空间重叠"：

- 三张表的房号空间**重叠**（都是 `_generate_code()` 的 4 位号，`:155`），这条坑本仓已经踩过并写在 `teardown_room` 的注释里（`:688-692`）——**判据必须用 `is`，不能拿 `code` 去三张表里撞库**。
- 记录留在各自的注册表里 ⇒「一个 code + 它的 mode」永远是**同一个对象、同一处取**，不存在"反查"这回事，重叠也就无从发生。
- ⇒ **不引入 `mode` 判别字段**。那东西的唯一用途是支撑一次跨模式合并查询，而合并正是本设计禁止的（§0 第 1 条）——加一个 `mode` 键等于给那个方向留接口。

### 2.3 被否决的替代：另立一张「对局中的房」表

看起来更"干净"（房照旧在转连时被拆，新表记一份副本），但：

1. **同一件事两处写**。新表要跟着房的生命周期增删 —— 多出一条"忘了删"的路径，而它要防的正是这类 bug。本仓对"第二份真相"的态度是明令禁止的（三个房类的 `tokens` 字段后来被整体删除、`_royale_role_bound` 被删除、`pending_*` 交接层被删除，都是同一条纪律）。
2. **它必须携带 `worker_port`/`worker_pid`，而这两个值正是端口归还决策的输入**。放进副本 = 决策读副本而归还读本体，两边一旦不同步就是"按一个已经不存在的端口去杀进程"（`ai_duel` 的历史事故就是这个形状，`room_manager.gd:130-135` 有留档）。
3. 房的**寿命**本来就要改（端口必须一直被占着，见 §2.4），所以"让房活下来"不是额外代价，而是本来就要做的事。

### 2.4 退役：worker 进程活性（并回答「为什么不是按宽限期收」）

回收梯 `RoomManager._reclaim_finished_matches()`，30s 一次：

```
对三张注册表逐个扫：凡 in_match(1v1 是 started) 且 _match_over(worker_port, worker_pid) → teardown_room(room, TEARDOWN_DELAYED)
_match_over(port, pid) := port > 0 and pid > 0 and not WorkerLauncher.pid_alive(pid)
```

**为什么判据是「进程还在不在」而不是「宽限期到了没」**：

- 三种模式的 worker **都在对局结束时自己退**（1v1：宽限到点 → `GraceWindow.ACTION_TEARDOWN` → 收场退进程；大乱斗/3v3：`ACTION_REMOVE` → `mark_disconnected`，直到「全员走光」那条判据满足才退）。所以"进程还在吗"是**精确**答案，且与模式无关。
- 按"一局大约多久"估一个界，**既早又晚**：早 = 收掉正在打的局（连端口一起端掉）；晚 = 白占端口与列表位。本仓已经为这个形状的估值吃过苦（`RoomManager.TEAM_MATCH_ESTIMATE` 与 `_sweep_stale_rooms` 的两条已知边界可作证）。
- 按"宽限期"收更糟：宽限期是 **worker 侧**的状态，大厅看不见它；照字面做（开局后宽限期到点就收）会把房在**开打 60 秒后**拆掉 —— 于是"看得见"只延续 60 秒，而**一局打到中段掉线的玩家再也回不去**（回局依赖房记录与它持有的端口）。

**`pid <= 0` 必须判成「没结束」**：`worker_port` 在 `pick_port()` 之后才赋值、`worker_pid` 在 `create_process` 成功之后才登记 —— 中间那个窗口里判"结束"会让开局那一瞬被自己的回收梯拆掉。判"没结束"的代价最多是晚一个梯周期（30s）才发现，那时 pid 已经在了。

**与既有的 2h 超龄清扫并存，不是二选一**：`_sweep_stale_rooms` 原样保留，它兜住"worker 一直不退"的僵尸房（那条路径是 `TEARDOWN_KILL`，强杀 + 立即归还）。

#### ★ 继承的风险（照实登记）

1. **pid 复用**：Windows 会回收 pid。worker 退出后若另一个进程拿到同一个 pid，`pid_alive` 会报"还在" → 这一条记录（与它占着的**一个**端口位）会一直挂到 2h 兜底。**影响面**：一条列表行 + 一个端口（`WORKER_PORT_SPAN = 500`）。**误判方向是"多留"而不是"错杀"**，所以不会打断进行中的对局。
2. **对局结束后列表里还挂 ≤30s 是有意的**（梯周期），不是 bug。
3. **1v1 worker 在"一个 claim 都没有"时会一直挂着**（既有行为：`server_main` 只给 `--royale` / `--team` 配了报到超时梯）。于是"双方都在 `go_match` 之后立刻消失"的 1v1 房会挂到 2h 兜底才被清。**玩家不会卡住**（客户端侧有 12s 转连兜底与 25s claim 兜底把他送回大厅），**但那一个 worker 与那一个端口会白占**。★ 本批**不修**：修法是给 1v1 worker 配一条报到超时梯，属 worker 侧的另一批。
4. **`on_peer_left` 不再给对局中房里的幸存者发「配对已取消」**了 —— 那句话是假的（房没有被取消，是一局在打的比赛）。幸存者由自己的客户端兜底救回（12s 转连 / 25s claim）。**代价**：见第 3 条那一个白占的端口。
5. `_sweep_stale_rooms` 的在局宽限仍是**估**的（大乱斗取 `RoyaleHost.MATCH_TIME` 默认值、3v3 取 `TEAM_MATCH_ESTIMATE`）——本批**不放宽**（真正的界只在 worker 里，两条既有边界照旧）。
6. 1v1 现在会活进对局，所以 `_sweep_stale_rooms` 那条「1v1 不享受在局宽限」（裸 `MAX_ROOM_AGE`）从"够不着"变成"理论上够得着"。**实测够不着**：房龄 2h 而一局 1v1 只有几分钟，且清扫 10 分钟才跑一次。**照实登记，本批不改**。

### 2.5 端口不变量：核心关键的那条换了一个

**今天**核心关键的是 `WorkerLauncher` 的三个 `*_PORT_REUSE_DELAY`（`server/worker_launcher.gd:31/38/42`）—— 因为房在转连那一刻就被拆了，端口从那一刻起倒计时，所以只能靠"延迟 > 宽限期"来保证重连的客户端手里那个端口还有效（`WORKER_PORT_REUSE_DELAY` 的注释就是这条教训：`30 == 30` 是**相等**而不是"短于"，相等同样不安全）。

**本设计之后**核心关键的是**房的寿命**：房活到 worker 退出 ⇒ **端口一直被占着**（端口只在 `teardown_room` 里归还，而拆房现在发生在对局结束之后）。于是：

- 宽限期 ⊆ worker 的存活期（大乱斗/3v3 的 worker 判据里明确要求 `_grace.size() == 0` 才退，见 `server_main.gd` 的 `_expire_graces` 末条），所以**宽限期内的客户端手里那个端口一定还有效**，与延迟常量的取值无关；
- 三个延迟常量的职责缩成一条：**"worker 刚退出，别立刻把它的端口发出去"**（给进程收尾与 UDP socket 释放留时间）。它们的取值**本批不动**。

★ 这条换位要写进 `worker_launcher.gd` 的注释（旧的"必须严格大于宽限期"作为**次要 belt** 保留，但要说清它不再是核心关键的那条）。详见后继计划的 Task 2。

---

## 3. 房间列表数据

三个页面的房间列表数据各加**一个同名同义的键**：

```
1v1   : {code, players, names, in_match}                  ← 新增 in_match
大乱斗 : {code, players, max_players, names, in_match}     ← 新增 in_match
3v3   : {code, players, max_players, names, in_match}      ← 新增 in_match
```

- 对局中那一行：`players` = **冻结名单的条数**（因为 `players` 已经空了），`names` 来自冻结名单；`max_players` 对 1v1 没有（房间恒 2 人，客户端本来就写死 `%d/2`）。
- **向后兼容增量扩展兼容**：三个页面的消费点一律是 `.get(键, 默认)`（如 `royale_lobby.gd:260-264`），未知键被忽略。老客户端因此会把这一行画成**可点**、点下去被服务端拒（§5），落到 `server_message` 显示一句文案。**新版客户端的"看得见"与服务端的"进不去"各自独立成立**，不需要两端同时升级。
- **不加 `mode` 键**（理由见 §2.2）。
- **提取为纯构造** `LobbyRooms.room_list_payload()` / `royale_list_payload()` / `team_list_payload()`，发送点只留一行 `NetBus.reply(caller, "room_list", room_list_payload())` / `NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload())`。★ 理由不是"整洁"：**`NetBus.reply` 在无对端时会静默跳过**（见 `NetBus.reply` 的判活注释），所以探针里"列表内容"**根本观测不到** —— 只有把构造提取为可直调的纯函数，它才是可测的。发送那一半由真链路探针覆盖（后继计划的 `tests/rejoin_probe.tscn` 相 c3）。

---

## 4. 三个大厅页的渲染

| 页 | 渲染函数 | 对局中那一行 |
|---|---|---|
| 1v1 | `scenes/matchmaking.gd:157` `_on_room_list` | 人数段显示「对局中」而不是 `%d/2`；`disabled = true`；不接 `pressed` |
| 大乱斗 | `scenes/royale_lobby.gd:246` `_on_royale_rooms` | 同款（人数段 `%d/%d` 换成「对局中」） |
| 3v3 | `scenes/team_lobby.gd:194` `_on_team_rooms` | 同款 |

- **配色不新增任何字面量**：`UiFactory.style_row_button`（1v1 用，`ui/ui_factory.gd:225`）与 `UiFactory.button`（另两页用，`:272`）**都已经**有 `disabled` 的 StyleBox（`:230` / `:280`：填充 `C_BTN_FILL` + 描边 `C_BORDER_DIM`、文字 `C_TEXT_DIM`）。这就是"看得见但后退"那一档，不用新色（颜色只许在 `ui_factory.gd` 定义）。
- **字号沿用各页现有的 16 / 32**（16 的倍数）。
- `focus_mode`：对局中的行设 `FOCUS_NONE`，其余 `FOCUS_ALL` —— 焦点环能落到它上面等于邀请一次键盘按下。
- 1v1 的排序不用改：对局中的房 `players` = 2（冻结名单），本来就会落进 `full` 那一档排到最后（`matchmaking.gd:165`），正是想要的观感。
- 三个页面的状态栏各补一句计数，供人眼确认"房确实还在列表里"。

**为什么是"看得见但点不动"而不是"藏起来"**：用户要的就是"所有人都能看到所有房间（包括已经在打的）"—— 可见是**信息**（有人在打、哪个房号、有谁），点不动是**不给一次注定失败的点击**。

---

## 5. 拒绝入房（两半，缺一不可）

### 5.1 守卫已经在位

三条 join 各自的守卫今天就有：`join_room:220` `if room.started:`、`royale_join:413` `if rr.in_match:`、`team_join:560` `if tr.in_match:`。本设计**不新增判据**，只做两件事：把**文案**改准，并把**拒绝本身变成断言**。

### 5.2 文案（三模式逐字统一）

今天 1v1 说的是「房间已满」（`:222`）—— 对"房里只剩 1 人、对局正在进行"是**假话**，而且会踩 `matchmaking.gd:201-218` `_on_server_message` 的自动刷新分支（`_auto_refreshed` 只自动刷一次；第二次点就只剩一句「房间已满」，玩家会读成"满了"而不是"进不去"）。

统一改成：**「该房间的对局已进行中,无法加入」**（三模式逐字同款）。同时 `matchmaking._on_server_message` 的自动刷新分支**保持只认旧文案**（`房间已满` / `房间不存在`）—— 新文案落到 `else`：**只显示、不刷新**（房本就该一直在列表里，刷新没有意义）。★ 这是"改一个字符串静默改了行为"的典型，故计划里有一条**源码级**断言断言约束它。

### 5.3 覆盖两档"进行中"

- **对局正在打**：`in_match` / `started` 为真。
- **有参与者正在宽限期里**：房**仍然是** `in_match`（宽限期是 worker 内部状态，大厅看不见，也**不需要**看见——"worker 还活着 ⇒ 房还在对局中"这一条已经把两档一起包含进来了）。

### 5.4 断言的是**拒绝**，不是列表

只断言"列表里有它"会让一个"能点进去"的实现全部通过 —— 那正是把第三人放进了别人的对局里。所以拒绝那一半必须**单独断言**，且**用非满房构造**：

- 1v1：房里只留 **1 人** → 唯一可能拒它的理由只剩 `started`（满房那条守卫要走 `players.size() >= 2`，够不着）；
- 大乱斗：**2/8**；
- 3v3：**2/6**。

用满房造会被「房间已满」喂绿，等于没验。断言形态 = **调用方没有被 append 进 `room.players`**。

### 5.5 界面那道只是体验

玩家仍然可以在「房间号」输入框里手敲房号走 `_join_code`（`matchmaking.gd:146`）→ 服务端拒 → 看到那句文案。**这条路径是"拒绝真的存在"的人眼可见证据**，也是老客户端（不认 `in_match` 键）的实际遭遇。

---

## 6. 测试与反证

### 6.1 测试面

| 测试 | 类型 | 覆盖 |
|---|---|---|
| `tests/lobby_visibility_probe.tscn` + `.gd` | 场景探针（agent 可跑） | 三个模式各：房活过转连 / 列表里有它且名单来自冻结那份 / 第三人**进不去**；回收梯：活 pid 不回收、死 pid 回收、**pid 未登记不回收** |
| `tests/lobby_row_probe.tscn` + `.gd` | 场景探针（agent 可跑） | 三个大厅页各：对局中那一行存在、`disabled`、**没有任何 handler**、`FOCUS_NONE`、文案含「对局中」、名单来自数据包；普通行不是 disabled 且**接了一个 handler**（正向对照） |
| `tests/room_sweep_smoke.gd`（既有，`-s`） | 源码级/结构级 | 新增：①`WorkerLauncher` 的 pid 登记与归还语义；②回收梯的**接线**（常量在、`_process` 调它、走 `teardown_room`、`_match_over` 对 `pid <= 0` 判否）；③三条 join 的守卫 + 统一文案在位。既有：拆除统一收拢纪律（`_check_teardown_funnel`） |
| `tests/team_room_smoke.gd`（既有，`-s`） | 源码级 | **回归**：三路互斥仍是**双向**判定 |

### 6.2 ★ 断言计数（本仓实测过的坑）

`ALL-OK` 只证明"**没有任何一条断言失败**"，**不证明"该跑的断言都跑过"**：helper / lambda 里出错会让调用方照常继续、判词照打（完整表述在 `tests/lib/probe_base.gd` 文件头）。

两个新探针因此都维护 `_checks` 计数，并在收尾断言 `_checks >= EXPECTED_CHECKS` —— **少跑一条就红**。`EXPECTED_CHECKS` 是常量，改探针必须同步改它（每个任务的步骤里都写明当次的值）。

### 6.3 反证（每个任务都要做，两段输出写进报告）

| 注入的缺陷 | 必须报错失败的那条 |
|---|---|
| `WorkerLauncher.release_now` 不清 pid | `room_sweep_smoke` 的"端口归还后未清 pid" |
| `on_peer_left` 的 `if room.started: continue` 删掉 | 探针相①「房**仍在**」 |
| `room_list_payload` 的名单来源换回 `_peer_names` | 探针相①「名单取自冻结那份」 |
| `join_room` 的 `if room.started:` 删掉 | 探针相①「第三人 join 被拒」 |
| 对局中的行改回 `btn.disabled = false` 并接上 `pressed` | `lobby_row_probe` 的 disabled / 连接数两条 |
| `_reclaim_finished_matches` 里把 `teardown_room(...)` 换成直接 `royale_rooms.erase(...)` | `room_sweep_smoke` **新增的**接线断言「回收梯没走拆除单一统一收拢」（★ 不是既有的 `_check_teardown_funnel` —— 那个只扫 `server/lobby_rooms.gd`，写在 `room_manager.gd` 里的绕道它照不到；两条断言各自守自己那个文件的统一收拢纪律） |
| `_match_over` 对 `pid <= 0` 返回 true | 探针相④「pid 还没登记不得判成结束」 |
| `_process` 里不调 `_reclaim_finished_matches` | `room_sweep_smoke` 的接线断言（行为探针是**手工**调它的，接不上时它照样全部通过） |

### 6.4 未覆盖（照实登记）

- **线上投递**：探针断言的是数据包构造函数与页面渲染，不是"这份数据包真的过了 UDP"。发送点各只改一行（换成调 payload 构造器），RPC 名与数据包形状都没变。★ 真链路上的"第三人看得见 + 进不去"由**后继计划**的 `tests/rejoin_probe.tscn` 相 c3 覆盖（同一个机制，一条探针，不重复造一个）。
- **视觉**：不取图。本批没有动任何版式常量，只用既有的 `disabled` 样式；按本仓「别折腾视觉」的取向，人工视觉核验留给用户跑真链路探针时顺带看一眼列表。

---

## 7. 明确不做（边界要说死）

1. **回局（原 spec §3.4 路径乙）**：token、`rejoin_request` / `rejoin_denied` 两条 RPC、`reclaim_role` 分叉、场景重建、`PvpSession` 的凭据字段、主菜单「回到对局」入口、宽限期时长、端口归还延迟的取值 —— **都不在本设计里**。本设计只让房**活得够久、看得见、进不去**；**谁能进去**是另一份计划（`docs/superpowers/plans/2026-09-21-rejoin-after-leaving.md`）的事，本设计是它的**前置**。
2. **HUD 的「掉线中 / 重连中」可见性**（断线重连 spec §4 阶段 3）—— 与本设计无关的另一块。
3. **观战**、把对局中的房变成**可加入**（补位）。
4. **三张注册表合并成一张跨模式列表**（§0 第 1 条：范围甲）。
5. **worker 进程崩溃后的恢复**。
6. **给 1v1 worker 配报到超时梯**（§2.4 风险 3 —— 本批只登记，不改 worker）。

## 8. 已知风险

1. **端口与列表位占得更久**：一条房记录从"转连那一刻"活到"worker 退出 + 回收梯 ≤30s"。端口归还延迟（120/360）照旧，所以单局占用 ≈ 一局 + 最多 30s + 延迟。池子 `WORKER_PORT_SPAN = 500`，本作量级无虞。
2. **pid 复用**（§2.4 风险 1）：最坏情况一条记录挂到 2h。误判方向是"多留"。
3. **回收梯依赖 `_process` 在跑**：`RoomManager` 在大厅进程里常驻，`_process` 一直在跑（`SWEEP_INTERVAL` 那条梯本来就在用同一条）。守卫是 `room_sweep_smoke` 的接线断言。
4. **对局中断的房会白占一个 worker**（§2.4 风险 3）：代价是一个 worker 进程 + 一个端口，上限 2h，玩家侧有兜底不卡住。
