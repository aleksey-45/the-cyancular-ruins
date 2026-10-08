# 断线重连 阶段 2 + 3 设计

**日期**：2026-09-17 ｜ **状态**：设计，待评审 ｜ **前置**：阶段 1 已合入 `main`（`0bd4c1a`）

承 `docs/superpowers/specs/2026-09-17-reconnect-and-rejoin-design.md`（下称**原 spec**）的 §7 分阶段表。阶段 1 已交付并推送。

## 0. 决策摘要

| # | 事项 | 裁定 / 推荐 | 来源 |
|---|---|---|---|
| 1 | **掉线窗口内被拆的墙不同步**（幻影墙） | **阶段 2-A 闭合**（本节新增，原 spec 排在阶段 2） | 阶段 1 最终审查的执行者发现它是"阶段 1 可用性"的真缺口 |
| 2 | 1v1 端口归还延迟 120 还是 360 | **推荐 360**（与 royale 一致）—— 一行常量 | 阶段 1 Task 7 审查 |
| 3 | 最后一个真人也掉线时：立刻收场 vs 给满宽限期 | **保留现状（给满）并写进文档** | 阶段 1 Task 4 实现者的偏离 |
| 4 | `ai_duel` 是第 4 个 `go_match` 发送点、没发 token | **不扩面** —— 审查者查明该路径**无 UI 调用点（D13）→ 实际不可达** | 阶段 1 Task 3 审查 |
| 5 | ★ `RoyaleHost.start_on` 的网格预载是**条件式**的，疑似 `plan_spawns` 用到**另一张图**的格 | **另立评估**（与重连无关的既有问题，见 §5） | 阶段 1 最终修复波的实现者 |
| 6 | 重连是自动还是手动 / 宽限期内身体 / token 由谁生成 | 已在原 spec §0 裁定（自动 + 留场 + 大厅生成） | 阶段 1 已落地 |

★ 第 2/3/4 条**都能在阶段 2 里顺手做掉**（各自 1 行到 10 行），不必另开。

---

## 1. 阶段 1 交付后剩下的缺口（事实，带行号）

阶段 1 把"闪断后自动回原局"跑通了，但**掉线那 30 秒里世界变过的东西不会补**：

| 事件 | 投递方式 | 掉线期间丢失的后果 |
|---|---|---|
| `tile_destroyed` | `NetBus` reliable | 客户端**留着服务器已摧毁的墙** → 玩家撞上**幻影墙** → 本地预测与服务端分歧 → 可能**回滚循环**（原 spec §9 风险 3 只说了"看不到墙"，实际更重） |
| `weapon_spawned` / `weapon_removed` | `NetBus` reliable | **幽灵枪**（看着在、按 F 无效）与**缺失枪**（服务器有、客户端看不见） |
| `bullet_spawn` | `NetBus` unreliable | **可接受**：子弹是瞬态，续上后新子弹照常广播 |

`round_state` **已被覆盖**（阶段 1 的 `_on_reclaim` 重绑 peer 后补发了一次），所以 `_round_locked` 卡死那一档不存在。

**为什么阶段 1 没做**：原 spec §7 把 `destroyed` 排进了阶段 2。但阶段 1 的最终审查指出——**幻影墙会让这半个功能看起来是坏的**，所以 2-A 应视为**阶段 1 的收尾**而不是新功能。

---

## 2. 阶段 2-A：重连后补齐破坏态与地面武器（闭合 §1）

### 2.1 机制：复用现成的 `match_sync`，不新造通道

`match_sync` 本来就是**客户端主动拉取**的进场数据包（原 spec §3.5、`server_main._on_match_sync`），现在已经带 `names` / `hues` / `options` / `roles` / `spawns` / **`ground_weapons`**。

**做法**：给它加一个 `destroyed` 字段，并让**重连成功后（路径甲）也拉一次**。一箭双雕——`destroyed` 与 `ground_weapons` 一起回来，正好覆盖 §1 表格里那两类丢失。

★ 关键点：**路径甲原来不需要 `match_sync`**（场景没重建，本地世界还在）。现在需要了——因为**世界在掉线期间变过**。这条要写进代码注释，否则后人会以为"路径甲不需要拉"。

### 2.2 服务端：`MatchHost.destroyed_cells()`

`MatchHost` 有 `grid`（当前）与 `_base_grid`（建局基线深拷贝，`match_state.gd:25-26`）。二者差异即被摧毁的格。

```gdscript
# 与建局基线的差异格(已摧毁/已变化的格)。给重连与"回大厅后回局"补破坏态用。
# ★ 上限:一格 = 125×75 = 9375;全被拆也只有 9k 条 Vector2i。
# ★ 只在**有差异**时才进载荷(空数组不带该字段),避免每局固定多几 KB。
func destroyed_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var rows := mini(grid.size(), _base_grid.size())
	for y in range(rows):
		var cur: Array = grid[y]
		var base: Array = _base_grid[y]
		var cols := mini(cur.size(), base.size())
		for x in range(cols):
			if int(cur[x]) != int(base[x]):
				out.append(Vector2i(x, y))
	return out
```

`server_main._on_match_sync` 的应答里加：

```gdscript
	var d := _host.destroyed_cells()
	if not d.is_empty():
		data["destroyed"] = d
```

### 2.3 客户端：应用 `destroyed`

**复用现有的 `_on_remote_tile_destroyed(cell)` 路径**（它已经会清瓦片渲染 + 碰撞层 + 播碎片）——**不另写一套**。逐格调它即可。

★ 它内部会 `TileHitFx.spawn(...)` 播碎片粒子。重连补态时**不该播碎片**（那不是"刚被拆"，是"你不在时被拆的"）——所以要给那条路径加一个"静默"开关（参数或一个 `_bulk_resync` 标志），这是本设计唯一需要改动既有函数签名的地方。

### 2.4 客户端：重连成功后拉 `match_sync`

在 `_on_resumed()` 里（阶段 1 已存在）追加一次 `NetBus.rpc_id(1, "match_sync")`。

★ **顺序要紧**：`_on_resumed()` 里**先重置 C2**（现有行为），**再**拉 `match_sync`。反了的话，`match_sync` 的应答会与重置竞争。

★ **地面武器要"先清后灌"**：`match_sync` 的 `ground_weapons` 是**全量**，而客户端 `GroundWeaponField` 里可能还留着掉线前的条目 → 必须**先 clear + 拆掉 `_pickup_nodes` 的全部节点**，再按数据包重建。否则幽灵枪会**永久留下**（这正是 §1 那半个缺口）。这条要有断言。

---

## 3. 阶段 2-B：回大厅后回局（原 spec §3.4 路径乙 + §3.7）

内容与原 spec 一致，这里只登记**必须解决的三件事**（都是阶段 1 的审查在执行中发现的）：

1. **大厅侧的房间记录要活过"客户端转连 worker"那一刻**。今天两条链路都会在客户端转连时拆房（1v1 是第一个 `peer_left` 就拆、大乱斗是 `rr.players` 空掉时拆），用意是防 1/2 幽灵房与僵尸 worker。阶段 2 要改成"`in_match` 的房不在 `on_peer_left` 里拆，改由 sweep 按宽限期收"，并**同时**补上替代的回收机制（否则端口永久占用）。
2. **token 的登记表必须独立于房对象**。阶段 1 把 token 存在 `Room.tokens` / `RoyaleRoom.tokens`，而房被 `teardown_room` 摘掉时它随之消失。**回局查询要在大厅侧活过拆除** → 另立一张 `token → (code, role, worker_port, 过期时刻)` 的登记表（阶段 1 Task 3 审查的 S6 已预警）。
3. **`rejoin_request(room_code, token)` + `go_match` 复用**（原 spec §3.7）。

---

## 4. 阶段 3：可见性 + 两个既有缺陷

| 项 | 内容 | 备注 |
|---|---|---|
| 3.1 | **HUD「掉线中」**：`round_state` 数据包加 `grace` 字段（`{role: 剩余秒}`），大乱斗排行榜的行状态加一档、1v1 记分条旁显示对手状态 | 阶段 1 的 `_enter_grace` 里那次 `_broadcast_round_state()` 目前**什么都没表达**（数据包逐字段不变）—— 加了这个字段它才有意义 |
| 3.2 | **HUD「重连中」**：本地状态驱动，不需要服务器广播 | 阶段 1 刻意降级成 `print`（见阶段 1 计划 Task 6 Step 4：`pvp_game`/`royale_game` 是 Node2D、`_ui_.panel_box()` 返回 StyleBoxFlat 不是节点 → 没有现成能挂的地方）。要在这一阶段连同 3.1 一起把 HUD 那层设计好 |
| 3.3 | ★ **`NetBus.opponent_left` 不可达**：该 RPC 在服务端**全仓没有调用点**，而 `pvp_game.gd:228-242` 的「对手已离开 → 2.5s 回主菜单」挂着它 → CLAUDE.md 把它列为"三条离开对局世界的路径"之一，实际不是 | 要么补上服务端的调用点，要么删掉那段死代码并改文档 |
| 3.4 | **对局中服务器断线无提示** | 阶段 1 已给「服务器断开」加了订阅者（`local_server_message`），但那只是触发重连；**没有重连失败前的可见反馈** —— 与 3.2 是同一块 UI |

---

## 5. 需另立评估（不在本 spec 范围）

★ **`RoyaleHost.start_on` 的网格预载是条件式的**：`if current_grid == null or is_empty()` 才重载地图。阶段 1 的最终修复波观察到一次"actor 的身体卡在几何里一直落着"，而那一跑 r1 的出生格 `(121,28)` 在 `factory1v1` 里**确是合法地板格** → 疑似 `plan_spawns` 用到了**另一张图**的格。

这是**既有的、与重连无关**的问题，但影响大乱斗的出生点正确性。**建议单独立项**（先复现、再定性）。

> ★★ **2026-09-29 执行结果（欠账清扫 C1）：那个"疑似"是误归因，已推翻；真因是当时的出生池缺陷，且早已修掉。**
>
> - **推翻的判据就是上面引的那个数**：`(121,28)` 在 `demo.cyrm` 里**根本不是地板格**（实测
>   `is_floor_cell = false`、`is_floor_cell_with_headroom = false`），而 `plan_spawns` 只可能产出地板格
>   （主池 `spawn_candidates()`、兜底 `floor_cells()`，两者都是地板格的子集）⇒ 那一跑的网格**就是
>   factory1v1**。（`maps/` 下只有 `demo.cyrm` 与 `factory1v1.cyrm` 两张图，没有第三个候选。）
> - **真因**：那一跑是 **2026-09-17 23:19**（`.superpowers/sdd/rc1-final-fix-report.md` 与
>   `_run1_prefix.log` 仍在盘上；worker 29002，r1 出生格 `(121,28)`、r2 `(79,13)`）。当时
>   `OPEN_AREA_MIN = 20` 是**绝对**阈值，而 factory1v1 的**最大**地板连通区只有 **13 格** ⇒
>   `spawn_candidates()` 前两档**恒空**、池子**静默退化**成全部 **843** 个地板格（其中 155 个是孤立
>   单格区）。实测 `(121,28)` 的连通区规模 = **4**，而今天 `area_threshold()` = 7 ⇒ **已被排除**；
>   修复前它**在池里** ⇒ 玩家生在 4 格小间里 = "卡在几何里一直落着"。
> - **根因已于 2026-09-19 由 `fc00db7` 修掉**（出生池分档自适应）。⇒ spec 本节建议的"单独立项"
>   不再需要：观察已解释、根因已修、今天的池子（122 格）不含该格。
> - **条件式预载本身**：机制已复现（先加载 `demo` 再钉 `factory1v1` ⇒ 预载被跳过 ⇒ 网格与已钉地图
>   不匹配），但**生产路径上实测没复现过**（插桩真 royale worker：`current_grid` 在 `start_on` 时是空的、
>   预载那一支确实被走到）。剩下的只是"同一进程内先后用两张不同的图跑两次 `start_on`"这一条潜伏路径
>   —— 今天没有这样的路径，也没有任何东西禁止它。详见 `CLAUDE.md` §断线重连 的那条登记。

---

## 6. 明确不做

- worker 进程**崩溃**后的恢复（要状态写入磁盘/回传，另一量级 —— 原 spec §2 已排除）。
- 观战、语音。
- 反作弊级身份验证。
- `ai_duel` 的 token（§0 第 4 条）。
- 改 `NetBus` 的方法表（扩展一律走 `NetBusExt`）。

## 7. 已知风险

1. **`match_sync` 数据包变大**：`destroyed` 最坏 9k 条 `Vector2i`（≈72KB 未压缩）。虽然只在有差异时带，但一局打到一半可能接近上限。**缓解**：真需要时改增量（带一个 `since_tick`）—— 本阶段先做全量，并在探针里量一次实际大小。
2. **先清后灌地面武器**会有一帧"场上没有枪"的空窗（清完到 `match_sync` 应答回来之间）。若体感明显，改成"应答到达后一次性替换"（构建新的 `GroundWeaponField` 再整体换掉引用）。
3. **大厅房间保留**会拉长端口占用（§3 第 1 条的代价）—— 需与 §0 第 2 条的 360s 一起评估端口池（`WORKER_PORT_SPAN = 500`）的压力。
