# 回大厅后回局【阶段 2-B】实施计划（+ 三模式宽限期改 60s）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 玩家按 ESC 回主菜单之后，**能凭手里的凭据回到原来那一局**（不重开对局、不丢世界状态）；同一个改动让「对局中的房」在**三个模式**的大厅列表里**看得见、进不去**。附带：宽限期 30s → **60s**（三模式统一），以及随之必须复核的端口归还延迟与全部测试预算。

**Architecture:**

1. **房记录活过大堂转连**。今天两条链路都在"客户端转连 worker"那一刻拆房（1v1 是第一个 `peer_left` 就拆、大乱斗/3v3 是 `players` 空掉时拆），用意是防幽灵房与僵尸 worker。改成：**`in_match`（1v1 是 `started`）的房不在 `on_peer_left` 里拆**，并**同时**补上替代的回收机制 —— 判据是 **worker 进程还在不在**（三种模式的 worker 都在对局结束时自己退），由一个 30s 的梯轮询，走**同一处拆除收口**。房活着，列表才看得见它；进不去由既有的 `in_match` / `started` 守卫保证（两半缺一不可）。
2. **回局凭据独立成表**。token 原先存在 `Room.tokens` / `RoyaleRoom.tokens` / `TeamRoom.tokens`，随 `teardown_room` 一起消失。新立一张 `server/rejoin_registry.gd`（`class_name RejoinRegistry`，纯逻辑、不读时钟、`-s` 可测），三个房类的 `tokens` 字段**整体删除**（同一件事不留第二份记录）。凭据里带 `worker_pid`：回局查询因此**不需要房对象**，答案也是精确的。
3. **`rejoin_request(room_code, token)` + 复用 `go_match`**。大厅判据抽成纯函数 `RejoinRegistry.decision()`（`""` = 放行），三种拒绝理由（凭据失效 / 房间号不符 / 对局已结束）各自可测。应答走**原 `go_match`** —— 于是客户端那条"连 worker → 认领 role → 进对局场景"的路与首次进场**逐字同一条**，唯一分叉是认领那一步要走 `reclaim_role`（对局已经开着，`claim_role` 会被 worker 当串线踢掉）。
4. **入口**：主菜单一颗「回到对局」按钮（只在 `PvpSession.can_rejoin()` 时出现），三个大厅页共用基类 `LobbyPage` 的回局支路。

**Tech Stack:** Godot 4.7.1 GDScript；`NetBus`（客户端 ↔ worker/大厅的 RPC 通道，**方法表一个字不动**，扩展一律走 `NetBusExt`）；`-s` 冒烟 + 场景探针 + 真链路多进程探针；判据一律 grep 文本。

## Global Constraints

- ★★ **另一个会话正在主工作树（`E:\Workspace\godot\the-cyancular-ruins`）的 `main` 上并发开发**。本计划的一切都在 **worktree `E:\Workspace\godot\the-cyancular-ruins\.claude\worktrees\3v3-fixes`**（分支 `feat/3v3-fixes`）里做。**绝不 `cd` 到主仓库根、绝不对它做 git 操作。**
- ★ **Bash 工具在本 worktree 里会被 git 守卫误伤** ⇒ **用 PowerShell 工具**跑 Godot。console 版路径：`D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe`。
- **测试由用户自己跑**（本仓默认）。agent 可跑：`--import`、`-s` 冒烟、**不占 7777 且不占 worker 端口池 (7800~8299)** 的探针。**需要用户跑**：一切碰 7777 的（`tests/pvp_room_smoke.sh` / `tests/pvp_match_smoke.sh` / `tests/team_match_probe.sh` / `tests/royale_soak_probe.sh` / `royale_probe.sh` / `pvp_reconcile_smoke.sh` / `pvp_twin_smoke.sh`），以及本计划新加的 `tests/rejoin_probe.sh`（它**不占 7777**，但它的真大厅会从 worker 端口池里发端口 —— 与用户自己的大厅同池，必须由人看着跑）。
- **颜色只在 `ui/ui_factory.gd` 定义**；字号只用 **16 的倍数**；HUD 底板那套透明深底的数值纪律见 CLAUDE.md（本计划**不改**任何底板）。
- ★ **`NetBus` 的方法表一个字不动**（改它会让与原版服务端的 RPC 全部失联）。本批新增的两条 RPC（`rejoin_request` / `rejoin_denied`）全在 `NetBusExt`。
- ★ **定向发送前一律先判活**（`NetBus.reply` / `NetBus.is_peer_live`）。大厅里 `NetBusExt` 的定向发送也要显式判一次（`royale_list` 是先例）。
- ★★ **判据一律是文本**（`ALL-OK` / 探针自己的串），**不看退出码**。而本仓**实测**过：`ALL-OK` 只证明"没有任何一条断言失败"，**不证明"该跑的断言都跑过"** —— 出错在 helper / lambda 里时调用方照常继续、verdict 照打（完整表述在 `tests/lib/probe_base.gd` 文件头）。**因此凡"这条守卫真的能咬住吗"的地方，计划里都要求做一次变异反证**（注入缺陷 ⇒ 该条断言必须红 ⇒ 还原 ⇒ 复绿），两段输出都写进报告。
- ★ **场景探针的 `--quit-after` 逐个按预算给，不许照抄"统一 3600"**：本仓已经踩过 —— `tests/brawl_rollback_probe.tscn` 用 3600 **跑不完**（22 趟 × 368 tick ≈ 8100 物理帧），安全网耗尽时进程 **exit 0、一行 `ALL-OK` 都没有**，在批量里被读成红（实测给它 30000 即绿，约 135s）。本批三个新探针的取值都在各自任务里**写清推导**。
- ★ **新建 `.gd` 文件后跑 `--import`**（刷全局类缓存），并把 `.uid` 一起 `git add`。
- 提交信息用**单引号**或 `git commit -F 文件`，**不带任何 Claude/AI 署名行**；提交后回读一遍。每次 `git add` 只加本任务点名的文件。
- 工作区有未跟踪的 `_crashtest/` 与 `.superpowers/`（后者自带 `.gitignore`），**不要动**。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `core/net/grace_window.gd` | 修改 | `DEFAULT_SECONDS` 30 → **60**（+ 把它牵动的三处时序写进注释） |
| `server/worker_launcher.gd` | 修改 | 三档 `*_PORT_REUSE_DELAY` 改 360（同值）+ `pid_of(port)` / `pid_alive(pid)` |
| `server/rejoin_registry.gd` + `.uid` | **新建** | 回局凭据表（纯逻辑、不读时钟、`-s` 可测）+ 纯判据 `decision()` |
| `server/lobby_rooms.gd` | 修改 | 三个房类：删 `tokens`、加 `roster`/`worker_pid`；`on_peer_left` 不拆 in-match 房；列表载荷抽成可测的 `*_list_payload()` 并含 in-match 房；`freeze_roster()`；`on_rejoin_request()`；`teardown_room` 里 `rejoin.drop_room()` |
| `server/room_manager.gd` | 修改 | 四个 spawn 点：记 `worker_pid` + 登记凭据 + 冻名单；新增 `_reclaim_finished_matches()` 30s 梯 |
| `core/net/net_bus_ext.gd` | 修改 | 两条 RPC（`rejoin_request` any_peer / `rejoin_denied` authority）+ 两个信号 |
| `core/net/pvp_session.gd` | 修改 | `room_code` / `mode` / `rejoin` 三个字段 + `can_rejoin()` / `clear_rejoin()`；`reset()` 一起清 |
| `scenes/lobby_page.gd` | 修改 | 回局支路（连大厅 → `rejoin_request` → `go_match`）、`_claim_role_worker` 的 reclaim 分叉、`_do_go_match` 的 token 保留、回局超时梯 |
| `scenes/matchmaking.gd` / `royale_lobby.gd` / `team_lobby.gd` | 修改 | 记 `room_code`/`mode`；`_process` 加回局超时梯；列表把 in-match 房画成不可点的一行 |
| `scenes/main_menu.gd` | 修改 | 「回到对局」按钮（唯一不调 `PvpSession.reset()` 的联机入口） |
| `tests/grace_window_smoke.gd` | 修改 | 钉 `DEFAULT_SECONDS == 60` + **归还延迟必须严格大于宽限期**这条跨文件不变量 |
| `tests/room_sweep_smoke.gd` | 修改 | 钉 `WorkerLauncher.pid_of` 的登记/归还语义 |
| `tests/reconnect_smoke.gd` | 修改 | 两条新 RPC 的节点归属/注解 + `PvpSession` 三个字段与 `reset()` |
| `tests/reconnect_probe.gd` | 修改 | 时间预算随宽限期 60 重算（`GRACE_MIN/MAX`、`FINAL_TIMEOUT`、子进程兜底） |
| `tests/team_match_watcher.gd` / `tests/team_match_probe.gd` | 修改 | 相⑤ 观察窗与 `RESULT_WAIT` 按同一口径重算 |
| `tests/rejoin_registry_smoke.gd` + `.uid` | **新建** | `-s`：凭据表 + 判据（三种拒绝 + 放行） |
| `tests/rejoin_lobby_probe.tscn` + `.gd` + `.uid` | **新建** | 场景探针：房寿命 / 列表可见性 / 拒绝入房 / 回收梯 / 回局判据（三模式） |
| `tests/rejoin_probe.tscn` + `.gd` + `.uid` + `tests/rejoin_watcher.gd` + `.uid` + `tests/rejoin_probe.sh` | **新建** | **真链路**端到端回局探针（真大厅 + 真 worker + 3 个真客户端；**用户跑**）。★ 观察者**没有 `.tscn`**：它由探针 `load(...).new()` 挂到 `root` 上（与 `reconnect_watcher` / `team_match_watcher` 同款） |
| `CLAUDE.md` | 修改 | 记录 2-B 的四条纪律 + 宽限期 60 的连带 |

## 契约（全计划共用）

```
# 回局凭据（RejoinRegistry 的一条）
token(String) -> { "code": String, "role": int, "worker_port": int,
                   "worker_pid": int, "expires_at": int(ms) }

# rejoin_request(room_code, token) 的三条出口
放行   → NetBus.reply(caller, "go_match", role, worker_port)      # 与首次进场同一条 RPC
拒绝   → NetBusExt.rpc_id(caller, "rejoin_denied", reason)        # reason 是给玩家看的一句话

# 列表载荷新增一个键（三个模式同名同义，老客户端忽略未知键）
"in_match": bool     # 对局中：照列、不可进
```

---

## Task 1: 宽限期 30 → **60** 秒 + 钉住「归还延迟必须严格大于宽限期」

**Files:**
- Modify: `core/net/grace_window.gd`（常量在 `:15`）
- Modify: `tests/grace_window_smoke.gd`（追加 ⑧）

**Interfaces:**
- Produces: `GraceWindow.DEFAULT_SECONDS == 60.0`（唯一入口；`pvp_match_client._on_reconnect_retry_tick:766` 读的就是它）

- [ ] **Step 1: 先加冒烟断言（此时必红）**

在 `tests/grace_window_smoke.gd` 的 `_check(G.ACTION_REMOVE != G.ACTION_TEARDOWN, …)` 之后、`if _fail == 0:` **之前**追加：

```gdscript
	# ── ⑧ 时长常量 + 「端口归还延迟必须**严格大于**宽限期」这条跨文件不变量(2026-09-21,阶段 2-B)──
	# ★ 为什么把它钉在这里:三个归还延迟是"重连的客户端手里那个端口还能不能连回**原来那一局**"
	#   的唯一保障 —— 宽限期到点那一刻端口就可以被复用(`WorkerLauncher.pick_port` 只看占用集合),
	#   而重连的客户端攥着旧端口 → 连到**别的局**。★ 相等同样不安全(30 == 30 当年就是这么翻的)。
	#   两个常量分居两个文件,靠人眼对齐必然漂;这条断言让"改一个漏一个"当场红。
	_check(absf(G.DEFAULT_SECONDS - 60.0) < 0.001,
			"★ 宽限期应为 60.0 秒(用户裁定:1v1 / 3v3 / 大乱斗三模式统一)。实得 %.1f" % G.DEFAULT_SECONDS)
	var W: GDScript = load("res://server/worker_launcher.gd")
	# ★ 空载守卫:load 失败还往下走会抛错,而 -s 抛错走不到 quit() → 进程永久挂起
	if W == null:
		print("GRACE_WINDOW FAILED: 找不到 core/net/worker_launcher.gd(归还延迟的不变量无从校验)")
		quit(1)
		return
	var delays := {
		"WORKER_PORT_REUSE_DELAY(1v1)": float(W.WORKER_PORT_REUSE_DELAY),
		"ROYALE_PORT_REUSE_DELAY(大乱斗)": float(W.ROYALE_PORT_REUSE_DELAY),
		"TEAM_PORT_REUSE_DELAY(3v3)": float(W.TEAM_PORT_REUSE_DELAY),
	}
	for k in delays:
		_check(float(delays[k]) > float(G.DEFAULT_SECONDS),
				"★ %s = %.0f 必须**严格大于**宽限期 %.0f(相等也不行:到点那一刻端口就能被复用,"
				% [k, delays[k], G.DEFAULT_SECONDS]
				+ "重连的客户端会被送到别的局)")
```

- [ ] **Step 2: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW FAILED: 1`（只有"宽限期应为 60.0"那一条红；三条不等式此时都还成立，因为 120/360/360 都 > 60）。

- [ ] **Step 3: 改常量 + 把它牵动的三处时序写进注释**

把 `core/net/grace_window.gd:15` 那一行：

```gdscript
const DEFAULT_SECONDS := 30.0   # ★ 宽限期时长的唯一入口(改时长只改这里)
```

换成：

```gdscript
# ★ 宽限期时长的唯一入口(改时长只改这里)。
# ★★ 2026-09-21:30 → **60**(用户裁定:1v1 / 3v3 / 大乱斗三个模式统一,不再分档)。
#   改这一个数会同时动**三处**,改之前三处一起看:
#     ① `scenes/pvp_match_client.gd` 的重连重试预算(`_on_reconnect_retry_tick` 的第一条判据)
#        读的就是本常量 —— 单一来源,不会漂;60s 下 `RECONNECT_RETRY_MS`(2s)与
#        `RECONNECT_ATTEMPT_TIMEOUT_MS`(5s)不变,一次闪断里的重试次数由 ~15 变 ~30,
#        是"更从容"而不是行为变化。
#     ② **三个 `*_PORT_REUSE_DELAY` 必须严格大于本值**(`server/worker_launcher.gd`):
#        它们才是"重连的客户端手里那个端口还在不在"的保障。守卫在
#        `tests/grace_window_smoke` ⑧ —— 三个档逐个断言这条不等式。
#     ③ **测试预算**:凡按"宽限期多久"算出来的窗口都要重算 —— `tests/reconnect_probe.gd`
#        的 `GRACE_MIN/MAX` 与 `FINAL_TIMEOUT`、`tests/team_match_watcher.gd` 的 `OBSERVE_MAX`、
#        `tests/team_match_probe.gd` 的 `RESULT_WAIT`(它的头部注释要求**逐项求和**算,别凭印象)。
#        这三处是 Task 3。
const DEFAULT_SECONDS := 60.0
```

- [ ] **Step 4: 跑冒烟确认全绿**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW OK`。

- [ ] **Step 5: 变异反证（证明 ⑧ 真的咬得住）**

把 `worker_launcher.gd` 的 `WORKER_PORT_REUSE_DELAY` 临时改成 `60.0`（**等于**宽限期）→ 跑冒烟 → 确认那条不等式**变红**（这才是"相等不安全"那条纪律的真正守卫）→ **逐字还原** → 复绿。两段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add core/net/grace_window.gd tests/grace_window_smoke.gd
git commit -m 'feat(net): 宽限期 30 → 60 秒(三模式统一)+ 钉住「归还延迟必须严格大于宽限期」'
```

---

## Task 2: 三档端口归还延迟统一改成 **360**（并订正注释）

**Files:**
- Modify: `server/worker_launcher.gd`（`:31` / `:38` / `:42`）

**Interfaces:**
- Consumes: Task 1 的 `GraceWindow.DEFAULT_SECONDS == 60`
- Produces: 三档 `= 360.0`，全部严格大于 60（6× 余量）

**为什么改 1v1 那档**（spec §0 第 2 条，本次照做）：

- 120 本来就只剩 2× 余量，而宽限期涨到 60 后只剩一倍；
- 更要紧的是它**依赖一个实现细节**：今天 1v1 的归还计时是从**拆房**起算的，而本批（Task 5）之后"拆房"这件事从"开局那一刻"挪到了"对局结束那一刻" —— 也就是说这条延迟的起点会**因为另一个任务的改动而改变**。把三个档拉成同一个值，等于让"重连期间端口一定还在手里"只依赖**一个**数（360 > 60），不再依赖"那两件事的先后顺序没被人改回去"。
- 代价是端口占用变长（spec §7 风险 3）。算一次：占用 ≈ 一局 + 宽限 60 + 归还 360；3v3 最坏 1800+60+360 = **2220s ≈ 37 分钟**。`WORKER_PORT_SPAN = 500`，要在这 37 分钟里开满 500 局才会耗尽 —— 本作的量级差着两三个数量级。**照实记在注释里**。

- [ ] **Step 1: 改三个常量并重写它们上方的注释**

`server/worker_launcher.gd` 里 `WORKER_PORT_REUSE_DELAY`（连同它上面那段"2026-09-17:30 → 120"的说明）整段替换成：

```gdscript
# ★★ 三档现在**同值 = 360**（2026-09-21,阶段 2-B）。原来 1v1 是 120、另两档 360,
#   拉齐有两个理由:
#     ① 宽限期从 30 涨到 60(见 GraceWindow.DEFAULT_SECONDS)后,120 只剩一倍余量;
#     ② 更要紧:1v1 那条的计时起点是**拆房**,而阶段 2-B 把"拆房"从开局那一刻挪到了
#        **对局结束那一刻**(对局中的房不再在客户端转连时被拆,见 LobbyRooms.on_peer_left)。
#        拉齐成一个数,"重连期间端口一定还在手里"就只依赖 360 > 60 这一条,不再依赖
#        "那两件事的先后顺序别被人改回去"。
# ★★ 不变量(硬纪律):**每个档都必须严格大于 `GraceWindow.DEFAULT_SECONDS`** ——
#   宽限期到点那一刻端口就能被 `pick_port` 发给新 worker,而重连的客户端手里攥着**旧端口**
#   → 连到**别的局**。★ 相等同样不安全(30 == 30 是**相等**而不是"短于",当年就是踩了这条)。
#   守卫:`tests/grace_window_smoke` ⑧ 逐档断言这条不等式(变异反证见该任务的 Step 5)。
# ★ 端口池压力(照实算过):占用 ≈ 一局 + 宽限 60 + 归还 360,3v3 最坏 ≈ 37 分钟;
#   池子 `WORKER_PORT_SPAN = 500`,要在这段时间里开满 500 局才耗尽,本作量级够用。
# max_size(历史,留档):1v1 那档 30 → 120 是 2026-09-17 断线重连阶段 1 的教训 ——
#   原值 30 与宽限期相等,重连的客户端会被送到别的局。
const WORKER_PORT_REUSE_DELAY := 360.0
```

`ROYALE_PORT_REUSE_DELAY` 与 `TEAM_PORT_REUSE_DELAY` 的**数值改 360.0**（它们已经是 360，这一行实际不变），但把两处"已知边界"注释订正成现在的事实：

```gdscript
# 大乱斗 worker 的端口归还延迟。★ 2026-09-21 起与另两档同值(见上面那段)。取值不再是
# "一局默认时长 + 收尾估":计时起点是对局结束那一刻(阶段 2-B 之后房只在对局结束时被回收),
# 故这个数只兜"大厅还没发现 worker 已经退了"的那一小段(梯的周期 30s)。
# ★ 已知边界(照实登记,本次不放宽):房主可用建房页把一局配到 30 分钟,此时一条**只按
#   默认时长**推的界会不够 —— 现在这条延迟不再是那个界(界由"worker 进程还在不在"回答),
#   但 `_sweep_stale_rooms` 的在局宽限**仍是**按默认时长估的,那一处的边界见该函数注释。
const ROYALE_PORT_REUSE_DELAY := 360.0
```

```gdscript
# 3v3 worker 的端口归还延迟。★ 2026-09-21 起与另两档同值(见上面那段)。
# ★ 别把它单独并回一个更小的数:那条线是"**短于或等于**宽限期会让重连的客户端连到别的局"
#   的老坑(1v1 从 30 → 120 的教训),三档一起动、一起复核。
const TEAM_PORT_REUSE_DELAY := 360.0
```

- [ ] **Step 2: 跑冒烟确认仍然绿（此时 1v1 那档从 120 变 360，不等式更宽松）**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW OK`。

- [ ] **Step 3: 跑结构冒烟（`teardown_room` 的三态分档没被动过）**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`（不看退出码；末尾那行会照实报三档的界）。

- [ ] **Step 4: 提交**

```bash
git add server/worker_launcher.gd
git commit -m 'chore(net): 三档端口归还延迟统一 360(严格大于宽限期 60);注释订正计时起点'
```

---

## Task 3: 宽限期 60 牵动的**测试预算**全部重算

**Files:**
- Modify: `tests/reconnect_probe.gd`（`:7,:88,:108,:113,:114` 一带）
- Modify: `tests/team_match_watcher.gd`（`:28,:55`）
- Modify: `tests/team_match_probe.gd`（`RESULT_WAIT` 及其头部推导）
- Modify: `scenes/pvp_match_client.gd`（把注释里写死的"30 秒"订正成 60）

**Interfaces:**
- Consumes: Task 1 的 60s
- Produces: 三处窗口自洽（都不撞自己的安全网）

★ **这一步不能省**：这三处都是**按宽限期算出来的窗口**，不重算的话症状是"探针一行 `ALL-OK` 都没有"（安全网先耗尽），而它长得跟真失败一模一样 —— 本仓已经为此误判过至少两次。

- [ ] **Step 1: `tests/reconnect_probe.gd`**

| 常量 | 旧 | 新 | 为什么 |
|---|---|---|---|
| `GRACE_MIN` | 29.0 | **59.0** | 相④ 判"宽限期到点耗时"（`_expire_graces` 每秒轮询 + 采样粒度） |
| `GRACE_MAX` | 36.0 | **68.0** | 同上的上界，给负载留余量 |
| `FINAL_TIMEOUT` | 58.0 | **118.0** | 整跑从 ~42s 变成 ~72s，收工上限必须大于它 |
| `CHILD_QUIT_AFTER` | 9000 | **18000** | 子进程兜底（原 150s）现在贴着整跑长度了，翻倍留余量 |

同时把 `:7`、`:88` 两处注释里的"跑满一个 30s 宽限期 / 整跑 ~42s"改成"60s / ~72s"，`:329` 那句 `(GraceWindow.DEFAULT_SECONDS=30)` 改成 `=60`。顶层 `--quit-after 14400`（240s）**保持不动**（240 > 118 + 子进程收尾余量）。

★ `tests/reconnect_probe.tscn` 的跑法注释一并订正（它写在 `.gd` 文件头里，改 `.gd` 即可）。

- [ ] **Step 2: `tests/team_match_watcher.gd`**

```gdscript
const OBSERVE_MAX := 110.0       # 相⑤ 观察窗(宽限期 60s + 余量;★ 改宽限期必须重算这里)
```

并把 `:28` 那句"两条都要等宽限期(30s)到点才成立 —— 观察窗按它定，见 OBSERVE_MAX"改成 60s。

- [ ] **Step 3: `tests/team_match_probe.gd` 的 `RESULT_WAIT`**

按该文件自己的纪律（"**逐项按 watcher 的常量求和算出来**……别凭印象写"）重算，并把**推导过程写进注释**：

```
  进局 ~5s + SETTLE 1.2 + RENDEZVOUS_MAX 100 + BRAWL_MAX 210 + 换局 SETTLE 1.2
  + OBSERVE_MAX 110 + PEER_WAIT 120 ≈ 547.4s;
  进局那一档的硬上限是 ENTER_TIMEOUT **90s**(不是 5s),最坏 ≈ 632.4s ⇒ 取 680 兜住两种走法。
```

```gdscript
const RESULT_WAIT := 680.0
```

`FINAL_TIMEOUT`（780.0）与 `CHILD_QUIT_AFTER`（54000 ≈ 900s）都仍大于 680，**不动**；但要在注释里点明"`RESULT_WAIT` 一旦超过 780 就必须同步抬 `FINAL_TIMEOUT`"。

- [ ] **Step 4: `scenes/pvp_match_client.gd` 的注释订正（只动注释）**

文件里所有把宽限期写死成"30 秒"的注释改成"宽限期(`GraceWindow.DEFAULT_SECONDS`)秒"，**不再写数字**（下次改时长就不会再有这句漂）：`_on_reconnect_retry_tick` 上方那条、`_retry_connect` 里"长于 30s 的宽限期""而不是设计的 30 秒"、`_begin_reconnect` 上方的"掉线那 30 秒里服务器照跑"与"30 秒预算的起算点"、`_on_resumed` 里"世界在掉线那 30 秒里变过"。★ **判据取的是 `GraceWindow.DEFAULT_SECONDS` 本身**（`:766`），不是这些数字 —— 数字只是读起来方便，写错不报错，故改成"不写死"。

- [ ] **Step 5: 自检（本轮只跑不占端口的）**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd` → `GRACE_WINDOW OK`
Run（**让用户跑**）：`timeout 900 "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn` → `RECONNECT PROBE: ALL-OK`（整跑约 72s）
★ 跑前确认没有别的 godot 在跑（探针用池外端口，不冲突，但**不要杀用户的大厅**）。

- [ ] **Step 6: 提交**

```bash
git add tests/reconnect_probe.gd tests/team_match_watcher.gd tests/team_match_probe.gd scenes/pvp_match_client.gd
git commit -m 'test: 宽限期 60 之后重算三处窗口(reconnect_probe / team_match_watcher / team_match_probe)'
```

---

## Task 4: `RejoinRegistry`（回局凭据表）+ `-s` 冒烟

**Files:**
- Create: `server/rejoin_registry.gd` + `.uid`
- Create: `tests/rejoin_registry_smoke.gd` + `.uid`

**Interfaces:**
- Produces（Task 6/7/8 都按这个签名用）：
  - `RejoinRegistry.grant(token: String, code: String, role: int, worker_port: int, worker_pid: int, now_ms: int) -> void`
  - `RejoinRegistry.lookup(token: String, now_ms: int) -> Dictionary`（过期 ⇒ `{}`；**不改表**）
  - `RejoinRegistry.decision(entry: Dictionary, code: String, worker_alive: bool) -> String`（**静态纯函数**；`""` = 放行）
  - `RejoinRegistry.drop_token(token) -> void` / `drop_room(code) -> int` / `prune(now_ms) -> int` / `size() -> int`
  - `RejoinRegistry.TOKEN_TTL_SECONDS := 3600.0`

- [ ] **Step 1: 写失败的 `-s` 冒烟 `tests/rejoin_registry_smoke.gd`**

```gdscript
extends SceneTree

# 回局凭据表(`server/rejoin_registry.gd`)的纯逻辑冒烟。
# 跑法: "$GODOT" --headless --path . -s res://tests/rejoin_registry_smoke.gd
# 通过 = `REJOIN REGISTRY: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这张表的错法全是**静默**的:TTL 边界取 > 会让"正好到点"永不过期(表只增不减);
#   判据顺序写反会把"凭据根本不存在"报成"房间号不符"(玩家看到的提示是错的、排查方向也是错的);
#   `drop_room` 按前缀匹配会把别的房的凭据一起清掉(那一局的玩家再也回不去,而没有任何日志)。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。

func _initialize() -> void:
	var S: GDScript = load("res://server/rejoin_registry.gd")
	if S == null:
		print("REJOIN REGISTRY: FAIL(加载 rejoin_registry.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	var r = S.new()

	# ── ① 登记 → 查得到,字段逐一对上 ──
	r.grant("tk_a", "1234", 1, 29001, 4242, 0)
	var e: Dictionary = r.lookup("tk_a", 0)
	if e.is_empty():
		fails.append("★ 登记后查不到凭据")
	else:
		if str(e.get("code", "")) != "1234":
			fails.append("凭据的 code 字段不对:%s" % str(e.get("code", "")))
		if int(e.get("role", 0)) != 1:
			fails.append("凭据的 role 字段不对:%s" % str(e.get("role", 0)))
		if int(e.get("worker_port", 0)) != 29001:
			fails.append("凭据的 worker_port 字段不对:%s" % str(e.get("worker_port", 0)))
		if int(e.get("worker_pid", 0)) != 4242:
			fails.append("凭据的 worker_pid 字段不对:%s" % str(e.get("worker_pid", 0)))
	if r.size() != 1:
		fails.append("登记一条后 size 应为 1,实得 %d" % r.size())

	# ── ② TTL 边界(与 GraceWindow 同口径:**含边界**)──
	var ttl := int(float(S.TOKEN_TTL_SECONDS) * 1000.0)
	if r.lookup("tk_a", ttl - 1).is_empty():
		fails.append("★ TTL 到期前 1ms 不该失效")
	if not r.lookup("tk_a", ttl).is_empty():
		fails.append("★ 正好到点(now == expires_at)必须失效 —— 取 > 会让它永不过期、表只增不减")
	if r.size() != 1:
		fails.append("★ lookup 不得改变表(GC 只走 prune),实得 size=%d" % r.size())

	# ── ③ prune:清过期的、不动没过期的、返回清掉的条数 ──
	r.grant("tk_b", "5678", 2, 29002, 4243, 0)
	var n := r.prune(ttl)
	if n != 1:
		fails.append("prune 应清掉 1 条过期凭据,实得 %d" % n)
	if r.size() != 1:
		fails.append("prune 之后应剩 1 条(tk_b),实得 %d" % r.size())
	if r.lookup("tk_b", ttl).is_empty():
		fails.append("★ prune 不得动没过期的凭据")

	# ── ④ 判据:三种拒绝 + 放行,且**优先级**是对的 ──
	var live: Dictionary = r.lookup("tk_b", 0)
	if r.decision({}, "5678", true) == "":
		fails.append("★ 凭据不存在必须拒绝(不能放行)")
	if not r.decision({}, "5678", true).contains("凭据"):
		fails.append("★ 凭据不存在时给的**理由**必须是「凭据失效」(顺序写反会报成「房间号不符」、把人引向错方向)")
	if r.decision(live, "9999", true) == "":
		fails.append("★ 房间号不符必须拒绝")
	if r.decision(live, "5678", false) == "":
		fails.append("★ worker 已退必须拒绝(否则会把客户端送到一个可能已经属于别人的端口)")
	if r.decision(live, "5678", true) != "":
		fails.append("★ 三者都对必须放行,实得理由:%s" % r.decision(live, "5678", true))

	# ── ⑤ drop_room 只掉那一间房的凭据(另一间房的必须还在)──
	r.grant("tk_c", "5678", 1, 29003, 4244, 0)
	r.grant("tk_d", "7777", 1, 29004, 4245, 0)
	var dropped := r.drop_room("5678")
	if dropped != 2:
		fails.append("drop_room(5678) 应清掉 2 条(tk_b + tk_c),实得 %d" % dropped)
	if r.lookup("tk_d", 0).is_empty():
		fails.append("★ drop_room 不得动别的房的凭据(按 code **全等**比,不是前缀/包含)")
	if r.size() != 1:
		fails.append("drop_room 之后 size 应为 1,实得 %d" % r.size())

	# ── ⑥ drop_token 只掉那一个 ──
	r.grant("tk_e", "7777", 2, 29004, 4245, 0)
	r.drop_token("tk_e")
	if not r.lookup("tk_e", 0).is_empty():
		fails.append("drop_token 之后不该还查得到")
	if r.lookup("tk_d", 0).is_empty():
		fails.append("★ drop_token 不得误伤别的凭据")

	if fails.is_empty():
		print("REJOIN REGISTRY: ALL-OK")
		quit(0)
	else:
		print("REJOIN REGISTRY: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
```

★ 上面第 ④ 条那几句断言消息里**不要**再嵌半角双引号（会破字符串）—— 需要引号时用「」（本仓文档的既有写法）。

- [ ] **Step 2: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd`
Expected: `REJOIN REGISTRY: FAIL(加载 rejoin_registry.gd 失败)`。

- [ ] **Step 3: 写 `server/rejoin_registry.gd`**

```gdscript
class_name RejoinRegistry
extends RefCounted

# 大厅侧的**回局凭据表**(spec §3 第 2 条):token → 这一局是哪个 worker 的、给谁的。
#
# ★★ 为什么它必须独立于房对象:原先 token 存在 `Room.tokens` / `RoyaleRoom.tokens` /
#   `TeamRoom.tokens`,而那三个字典随 `teardown_room` 一起消失。回局的查询要**在大厅侧活过拆除**
#   —— 客户端从主菜单回来时,房可能已经因为对局结束被回收了(见 RoomManager._reclaim_finished_matches)
#   → 查询落到一张**独立**的表上,答案才是一个明确的"这局没了",而不是"房找不到 → 什么都不知道"。
#   ★ 因此三个房类的 `tokens` 字段**已整体删除**(2026-09-21):同一件事只留一处记录。
#
# ★ 纯逻辑、不引 autoload、**不读时钟**(now 由调用方传入)⇒ `-s` 可测(同 GraceWindow)。
# ★ 键是 token 本身(16 位 hex,来自 `LobbyRooms.new_token()`);value 是一份**自足**的小字典
#   —— 回局**不需要**再问房对象(房可能已经没了)。
#
# ★ TTL 只是**表的 GC 上界**,不是"这一局还能不能回去"的判据:真正的判据是 worker 进程还活着吗
#   (`decision()` 的 `worker_alive` 入参)。分开的理由:"一局打多久"三种模式各不同、且没有可读
#   常量(见 room_manager.TEAM_MATCH_ESTIMATE 的注释),而"worker 退了吗"是精确且与模式无关的。
#   TTL 取 1h:长到覆盖任何一局 + 玩家在菜单里发呆的时间,短到表不会无限长大。
const TOKEN_TTL_SECONDS := 3600.0

var _by_token: Dictionary = {}   # token(String) -> {code, role, worker_port, worker_pid, expires_at}


# 登记一份回局凭据。★ **必须在 worker 拉起成功之后调**(要它的 pid 才能判"这局还在不在")
# —— 见 RoomManager 四个 spawn 点(它们先发 `session_token`、再 spawn、最后登记)。
func grant(token: String, code: String, role: int, worker_port: int, worker_pid: int,
		now_ms: int) -> void:
	_by_token[token] = {
		"code": code,
		"role": int(role),
		"worker_port": int(worker_port),
		"worker_pid": int(worker_pid),
		"expires_at": now_ms + int(TOKEN_TTL_SECONDS * 1000.0),
	}


# 查一份凭据。过期的**当作不存在**(返回空字典)。★ 本函数**不改表**(GC 走 `prune`)——
# "查一次顺手删一条"会让同一个查询在不同调用点有不同副作用,而这张表有两个读者(大厅的
# 回局 handler 与回收梯的 GC)。
func lookup(token: String, now_ms: int) -> Dictionary:
	if not _by_token.has(token):
		return {}
	var e: Dictionary = _by_token[token]
	if now_ms >= int(e.get("expires_at", 0)):
		return {}
	return e


# 回局请求的**纯判据**:返回 "" = 放行,否则是给玩家看的拒绝理由。
# ★ 三种拒绝各有各的成因,合并不了,而且**顺序有意义**:凭据根本不存在时先报"凭据失效"
#   (那才是玩家该知道的事;报"房间号不符"会把人引向"房间号填错了"这个错方向)。
# ★ 做成静态纯函数是为了可测:`-s` 冒烟把四种组合逐个钉住,而生产侧只有一次调用、一次比较。
static func decision(entry: Dictionary, code: String, worker_alive: bool) -> String:
	if entry.is_empty():
		return "凭据已失效(对局可能已结束)"
	if str(entry.get("code", "")) != code:
		return "房间号与凭据不符"
	if not worker_alive:
		return "对局已结束"
	return ""


func drop_token(token: String) -> void:
	_by_token.erase(token)


# 某一间房的全部凭据(房被拆除时调,见 LobbyRooms.teardown_room)。
# ★ 按 code **全等**反查,而不是让房自己记一串 token:房侧那份记录(`tokens`)已经删了,
#   留着它就是第二份真相。返回值是清掉的条数(调用方只在日志里用)。
func drop_room(code: String) -> int:
	var n := 0
	for tk in _by_token.keys():
		if str((_by_token[tk] as Dictionary).get("code", "")) == code:
			_by_token.erase(tk)
			n += 1
	return n


# 清掉已过期的条目,返回清掉的条数(调用点 = RoomManager 的回收梯,30s 一次)。
func prune(now_ms: int) -> int:
	var n := 0
	for tk in _by_token.keys():
		if now_ms >= int((_by_token[tk] as Dictionary).get("expires_at", 0)):
			_by_token.erase(tk)
			n += 1
	return n


func size() -> int:
	return _by_token.size()
```

- [ ] **Step 4: `--import` + 跑冒烟确认全绿**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd`
Expected: `REJOIN REGISTRY: ALL-OK`。

- [ ] **Step 5: 变异反证（两条）**

1. 把 `lookup` 的 `now_ms >= int(...)` 改成 `now_ms > int(...)` ⇒ ② 那条（"正好到点必须失效"）应红；还原。
2. 把 `decision` 里"凭据为空"与"code 不符"两条**对调** ⇒ ④ 的"理由"那条应红；还原。

两段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add server/rejoin_registry.gd server/rejoin_registry.gd.uid \
  tests/rejoin_registry_smoke.gd tests/rejoin_registry_smoke.gd.uid
git commit -m 'feat(net): 回局凭据表 RejoinRegistry(纯逻辑 + 三种拒绝判据)+ -s 冒烟'
```

---

## Task 5: `WorkerLauncher` 记下每端口的 worker pid

**Files:**
- Modify: `server/worker_launcher.gd`（`release_now` / `pick_port` 一带 + 三个 `spawn_*`）
- Modify: `tests/room_sweep_smoke.gd`（新增 `_check_worker_pid_tracking()`）

**Interfaces:**
- Produces: `WorkerLauncher.pid_of(port: int) -> int`（未登记/已归还 ⇒ 0）、`WorkerLauncher.pid_alive(pid: int) -> bool`（**静态**；pid ≤ 0 ⇒ false）

- [ ] **Step 1: 先加冒烟断言（此时必红）**

在 `tests/room_sweep_smoke.gd` 的 `_initialize()` 里 `_check_team_spawn_guard()` **之后**插一行 `_check_worker_pid_tracking()`，并加函数：

```gdscript
# ── 阶段 2-B(2026-09-21)新增:worker pid 的登记与归还 ──
# ★ 为什么钉它:回局与"对局结束后回收房"这两件事的判据都是"**这一局的 worker 进程还在不在**"
#   —— 那是三种模式的**唯一**精确界(worker 都在对局结束时自己退)。而 pid 的来源就是这里:
#   端口 → pid 的映射。★ 归还端口时**不清 pid** 的后果是静默的:回局查询会认为一个已经
#   结束(甚至端口已被复用给别的局)的对局还活着,把玩家送过去 → 那边的 worker 一拒一踢。
func _check_worker_pid_tracking() -> void:
	if _fail != "":
		return
	var L := WorkerLauncher.new()
	# 直接摆内部表(与 team_match_probe 摆 `_next_port` 同款手法):真拉起一个子进程不该发生在这里
	L.set("_worker_pids", {7770: 4242})
	if L.pid_of(7770) != 4242:
		_fail = "WorkerLauncher.pid_of 没读到登记过的 pid"
		return
	if L.pid_alive(0) or L.pid_alive(-1):
		_fail = "★ pid_alive(<=0) 必须是 false(登记发生在 spawn 成功之后,那之前的窗口别判成活着)"
		return
	L.release_now(7770)
	if L.pid_of(7770) != 0:
		_fail = "★ 端口归还后未清 pid(回局会把一个已经结束的对局判成「还在」)"
		return
```

★ 这条探针的代码里**不要**嵌半角双引号（用「」）。

- [ ] **Step 2: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP FAIL: WorkerLauncher.pid_of 没读到登记过的 pid`（方法还没写 → 会先报 `Invalid call … pid_of`，同样算红）。

- [ ] **Step 3: 实现**

在 `_worker_ports` 旁边加字段：

```gdscript
var _worker_pids: Dictionary = {}   # port(int) -> pid(int):回局/回收要判"这一局还在不在"
```

在 `release_now` 里补一行（**必须在同一个函数里**：归还端口与忘记 pid 是同一件事的两面）：

```gdscript
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)
	# ★ 必须一起清:pid 与"端口在不在用"是同一份事实。只清一半的后果是回局查询把一个
	#   已经结束(甚至端口已被复用给别的局)的对局判成"还在" → 把玩家送过去被踢。
	_worker_pids.erase(port)
```

在 `pick_port()` 之后追加两个访问器（紧挨端口池那两个函数，读起来才是一件事）：

```gdscript
# 本端口上那具 worker 的 pid(没拉起过 / 已归还 → 0)。
# ★ 谁需要它:大厅的「对局结束了吗」判据(`RoomManager._reclaim_finished_matches` 与
#   LobbyRooms.on_rejoin_request)—— 三种模式的 worker 都在对局结束时自己退,"进程还在吗"
#   是唯一的精确答案;任何按"一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口)。
func pid_of(port: int) -> int:
	return int(_worker_pids.get(port, 0))


# 这个 pid 还在跑吗?★ **pid <= 0 一律 false**(= "不在")。理由:pid 的登记发生在
# `OS.create_process` 成功**之后**,而 `started/in_match = true` 在它之前 —— 中间那个窗口里
# pid 还是 0;判"活着"会让"开局那一瞬被自己的回收梯拆掉"成为可能,判"不在"最多让那一局晚
# 一个梯周期(30s)才被发现(那时它已经有 pid 了)。
static func pid_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)
```

三个 `spawn_*` 函数在 `var pid := OS.create_process(exe, args)` 之后、`print(...)` 之前各加一处：

```gdscript
	if pid > 0:
		_worker_pids[port] = pid
```

（`spawn_worker` / `spawn_royale_worker` / `spawn_team_worker` 三处各一行，`spawn_team_worker` 里那处放在 `create_process` 之后、`return pid > 0` 之前。）

- [ ] **Step 4: 跑冒烟确认全绿**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`。

- [ ] **Step 5: 变异反证**

把 `release_now` 里新加的 `_worker_pids.erase(port)` 注释掉 ⇒ 冒烟必须红在"端口归还后未清 pid"；还原 ⇒ 复绿。两段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add server/worker_launcher.gd tests/room_sweep_smoke.gd
git commit -m 'feat(net): WorkerLauncher 记端口→worker pid(回局与回收的判据)+ 结构冒烟'
```

---

## Task 6: 房活过「客户端转连 worker」+ 列表可见性（三模式）

**Files:**
- Create: `tests/rejoin_lobby_probe.tscn` + `tests/rejoin_lobby_probe.gd` + `.uid`
- Modify: `server/lobby_rooms.gd`（三个房类 / `on_peer_left` / `on_list_rooms` / `royale_list` / `team_list` / `royale_leave` / `team_leave`）
- Modify: `server/room_manager.gd`（四个 spawn 点调 `lobby.freeze_roster(...)`）

**Interfaces:**
- Produces:
  - `LobbyRooms.Room / RoyaleRoom / TeamRoom` 各多两个字段：`roster: Array`（`[{role:int, name:String}]`，开局那一刻冻结）、`worker_pid: int`
  - `LobbyRooms.freeze_roster(room) -> void`
  - `LobbyRooms.room_list_payload() -> Array` / `royale_list_payload() -> Array` / `team_list_payload() -> Array`（各含 `"in_match": bool`）
  - 三个房类的 `tokens` 字段**删除**
- 判据文本：`REJOIN LOBBY PROBE: ALL-OK`

★ **本任务的探针是本批唯一能在 agent 侧跑的场景探针**（不占任何端口，不拉子进程）—— 后面 Task 7/8/9 都往它里面加相。

- [ ] **Step 1: 写 `tests/rejoin_lobby_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/rejoin_lobby_probe.gd" id="1"]

[node name="RejoinLobbyProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写探针的骨架 + 相①②③（此时必红）**

```gdscript
extends Node

# 大厅侧的**房寿命 / 列表可见性 / 拒绝入房**场景探针(阶段 2-B,2026-09-21)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn
# 判据: 文本 `REJOIN LOBBY PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印)。
# ★ `--quit-after 3600`(=60s @60fps)是**安全网**,本探针 `_ready` 里同步跑完全部断言后自己
#   `quit()`;取值依据:它不 await 任何东西(全是同步断言),3600 是"绝不可能耗尽"的量级。
#   本仓的教训是"安全网太薄会把跑得慢读成功能坏了",而这里没有任何等待,故不需要更长。
#
# ═══ 为什么需要它 ═══
# ★ 本批改的是一组**闭环**:房在"客户端转连 worker"那一刻不再被拆(否则回局与列表可见性都
#   无从谈起),于是"房什么时候消失"从"有人断开"变成了"worker 退了" —— 三张注册表各一处判断,
#   写错任何一处都是**静默**的(房不死 = 端口与列表位永久占用;房早死 = 回局永远失败)。
# ★ 列表可见性与拒绝入房是**同一件事的两半**:房留着才会出现在列表里,而出现之后必须**进不去**。
#   只断言"列表里有它"会让一个"能点进去"的实现全绿 —— 那正是把 C 放进了 A/B 的对局里。
#   ★★ 故拒绝那一半用**非满房**造:房里 1 人(1v1)/ 3 人(3v3)/ 2 人(大乱斗上限 8)时,
#   唯一的拒绝理由只剩 `in_match` —— 用满房造会被"房间已满"喂绿(等于没验)。
# ★ 探针建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径),房记录由探针手工摆:
#   本批的逻辑全在大厅进程内,不需要 socket、也不需要真 worker。
# ★ `NetBus.reply` 在"没有对端"时静默跳过 ⇒ 通过 RPC 应答观测的结果**读不到**;故本批把
#   "判据"与"发送"分开:列表抽成 `*_list_payload()`(可测),回局判据抽成
#   `RejoinRegistry.decision()`(可测)。发送那一半由真链路探针(`tests/rejoin_probe`)覆盖。

const ROOM_1V1 := "9001"
const ROOM_ROYALE := "9002"
const ROOM_TEAM := "9003"
const P_A := 101     # 假 peer id:本探针不开 socket,这些数字只用来占位
const P_B := 102
const P_C := 103

var _rm: Node = null
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_rm = RoomManager.new()
	add_child(_rm)
	# ★ 关掉大厅自己的两条梯:本探针手工驱动(与 `match_host_hygiene_probe` 关 `_physics_process`
	#   同款)。不关的话跑到 30s 时回收梯会自动触发,把探针刚摆好的房收掉 —— 断言会在
	#   "什么错都没有"的情况下变红。
	_rm.set_process(false)
	_phase_lifetime_1v1()
	_phase_lifetime_royale()
	_phase_lifetime_team()
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("REJOIN LOBBY PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("REJOIN LOBBY PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# ── ① 1v1:房活过"全员转连 worker",且第三人**看得见、进不去** ──
func _phase_lifetime_1v1() -> void:
	var r := LobbyRooms.Room.new()
	r.code = ROOM_1V1
	r.players = [P_A, P_B]
	r.player_role = {P_A: 1, P_B: 2}
	r.started = true
	r.worker_port = 29901
	r.worker_pid = 0        # 本相不涉及回收(相④才摆 pid)
	_rm.lobby.rooms[r.code] = r
	# ★ 名单必须在**开局那一刻**冻结:成员转连 worker 后会陆续断开大厅,`players` 会空、
	#   `_peer_names` 会被擦掉 —— 靠它们渲染的列表会退化成"玩家/玩家"。
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(r)
	_check(r.roster.size() == 2, "① 开局时名单被冻进房记录(2 条)")

	# 转连:两个成员都断开大厅
	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.rooms.has(ROOM_1V1), "① ★ 全员断开大厅后房**仍在**(回局与列表可见性都要它)")
	_check(r.players.is_empty(), "① 房内在线名单已空(players 的语义仍是「此刻还连在这个大厅房里的人」)")

	# C 看列表:房照列、带 in_match 标记、名字来自**冻结的那份**
	var list: Array = _rm.lobby.room_list_payload()
	var row := _find_row(list, ROOM_1V1)
	_check(not row.is_empty(), "① ★ 第三人能在列表里**看到**这个房(今天它会整个消失)")
	if not row.is_empty():
		_check(bool(row.get("in_match", false)), "① 列表行带 in_match=true")
		var names: Array = row.get("names", [])
		_check(names == ["阿甲", "bob"],
				"① ★ 名单取自冻结的那份(players/_peer_names 都已空),实得 %s" % str(names))
		_check(int(row.get("players", 0)) == 2, "① 列表显示 2 人(取自 roster,不是取值 0 的空 players)")

	# C 试图进房:必须被拒。★ 房里只放 1 人,让**唯一**可能的拒绝理由只剩 started
	r.players = [P_A]
	var before := r.players.size()
	_rm.lobby.join_room(P_C, ROOM_1V1)
	_check(r.players.size() == before and not r.players.has(P_C),
			"① ★ 第三人 join_room 被拒(房里 1 人:唯一能拒它的就是 started)")


# ── ② 大乱斗:同上(in_match 门控 + 非满房)──
func _phase_lifetime_royale() -> void:
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = ROOM_ROYALE
	rr.host_peer = P_A
	rr.players = [P_A, P_B]
	rr.player_role = {P_A: 1, P_B: 2}
	rr.max_players = 8
	rr.in_match = true
	rr.worker_port = 29902
	_rm.lobby.royale_rooms[rr.code] = rr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(rr)
	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.royale_rooms.has(ROOM_ROYALE), "② ★ 全员断开大厅后大乱斗房仍在")
	_check(rr.players.is_empty(), "② 在线名单已空")
	var row := _find_row(_rm.lobby.royale_list_payload(), ROOM_ROYALE)
	_check(not row.is_empty(), "② ★ 第三人能看到这个房")
	if not row.is_empty():
		_check(bool(row.get("in_match", false)), "② 列表行带 in_match=true")
		_check(row.get("names", []) == ["阿甲", "bob"], "② 名单取自冻结的那份")
	# ★ 非满房:2/8 —— 唯一能拒的理由就是 in_match
	rr.players = [P_A]
	_rm.lobby.royale_join(P_C, ROOM_ROYALE, "")
	_check(not rr.players.has(P_C), "② ★ 第三人 royale_join 被拒(2/8 非满房:唯一能拒它的是 in_match)")


# ── ③ 3v3:同上 ──
func _phase_lifetime_team() -> void:
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = ROOM_TEAM
	tr.host_peer = P_A
	tr.players = [P_A, P_B]
	tr.player_role = {P_A: 1, P_B: 2}
	tr.team_of = {1: 1, 2: 2}
	tr.in_match = true
	tr.worker_port = 29903
	_rm.lobby.team_rooms[tr.code] = tr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(tr)
	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.team_rooms.has(ROOM_TEAM), "③ ★ 全员断开大厅后 3v3 房仍在")
	_check(tr.players.is_empty(), "③ 在线名单已空")
	var row := _find_row(_rm.lobby.team_list_payload(), ROOM_TEAM)
	_check(not row.is_empty(), "③ ★ 第三人能看到这个房")
	if not row.is_empty():
		_check(bool(row.get("in_match", false)), "③ 列表行带 in_match=true")
		_check(row.get("names", []) == ["阿甲", "bob"], "③ 名单取自冻结的那份")
	# ★ 非满房:2/6 —— 唯一能拒的理由就是 in_match
	tr.players = [P_A]
	tr.team_of = {1: 1}
	_rm.lobby.team_join(P_C, ROOM_TEAM, "")
	_check(not tr.players.has(P_C), "③ ★ 第三人 team_join 被拒(2/6 非满房:唯一能拒它的是 in_match)")


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}
```

- [ ] **Step 3: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn`
Expected: 红（`Invalid call. Nonexistent function 'freeze_roster'` 之类），且**必须**是这条而不是"探针自己被 gc 回收"。

- [ ] **Step 4: 改 `server/lobby_rooms.gd` 的三个房类**

三个类各加两行、删一行（`tokens`）：

```gdscript
class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> 1/2
	var started := false                 # 已拉起 worker/已配对:拒绝再次加入
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
	# worker 进程的 pid(拉起成功后填;回局与回收都靠它判"这一局还在不在")
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)
	# 开局那一刻冻结的名单 [{role:int, name:String}]:★ 成员转连 worker 后会陆续断开大厅,
	# `players` 会空掉、`_peer_names` 会被擦掉 —— 对局中房间的列表渲染**只能**读这一份
	# (否则 C 看到的是"玩家, 玩家")。
	var roster: Array = []
```

`RoyaleRoom`（`:46` 起）与 `TeamRoom`（`:66` 起）做**同样三件事**：**删掉** `var tokens: Dictionary = {…}` 那一行、在 `worker_port` 之后**加** `var worker_pid: int = 0`、在 `created_at` 之后**加** `var roster: Array = []`（两行都照抄上面的注释）。改完它们各自的字段区是：

```gdscript
class RoyaleRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(房内成员,**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..N,大乱斗角色号)
	var is_public := true
	var invite_code := ""                 # 私密房凭此码进入
	var max_players := ROYALE_DEFAULT_MAX
	var options: Dictionary = {}          # 房主对局选项(禁武器/回合回血),开局随房主生效
	var in_match := false                 # 已开局(拒绝加入;成员转连 worker 后房**仍保留**,见 on_peer_left)
	var worker_port: int = 0              # 本房拉起的大乱斗 worker 端口(关房时归还)
	# worker 进程的 pid(拉起成功后填;回局与回收都靠它判"这一局还在不在")
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超龄清理用,与 Room.created_at 同形)
	# 开局那一刻冻结的名单 [{role:int, name:String}](理由见 Room.roster 的注释)
	var roster: Array = []
```

```gdscript
class TeamRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..6,最小空闲号)
	var team_of: Dictionary = {}          # role(int) -> 1/2(**选边前不在表里**)
	var is_public := true
	var invite_code := ""
	var in_match := false
	var worker_port: int = 0
	# worker 进程的 pid(拉起成功后填;回局与回收都靠它判"这一局还在不在")
	var worker_pid: int = 0
	var created_at := 0.0
	# 开局那一刻冻结的名单 [{role:int, name:String}](理由见 Room.roster 的注释)
	var roster: Array = []
```

★ 三处 `tokens` 字段**删掉**，并**同时删掉 `server/room_manager.gd` 里那 4 处写入点**（`rr.tokens[pid] = tk` ×2 / `tr.tokens[pid] = tk` / `room.tokens[pid] = tk`，各一行）—— ★ 两件事必须**同时**做：字段一删，那 4 行就是"往一个不存在的属性写"，下一次 `--import` 当场 Parse Error（而那时实施者正在跑别的命令，症状会看着像"别的地方坏了"）。删那 4 行是**安全的**：token 照旧经 `session_token` 发到客户端（那几行不动），只是"大厅侧不再留一份记录"——**回局凭据的登记在 Task 8 补上**，而在 Task 8 之前没有任何东西读它。

之后 `grep -rn "\.tokens" server/ scenes/ core/ tests/ --include=*.gd` 必须只剩 **`server/server_main.gd` 的 `_tokens`**（那是 **worker 侧** role→token 的表，**别动**）。

- [ ] **Step 5: 加 `freeze_roster` + 改三处 `on_peer_left`**

在 `_generate_code()` 之后加：

```gdscript
# 把"开局那一刻在房里的名单"冻进房记录(role + 昵称快照)。
# ★ 谁调:RoomManager 在**每一处开局**调一次(`_start_match` / `royale_start` /
#   `royale_start_ai` / `team_start`)—— 那是"这一局有哪些人"唯一确定的时刻。
# ★ 为什么是快照而不是"读时现算":成员转连 worker 时会**陆续断开大厅**(`on_peer_left`),
#   而那时 `players` 会被清空、`_peer_names` 会被擦掉;对局中的房要在列表里显示名单,
#   就只能靠这份冻结的副本。名单错了不报错,只会让 C 看到"玩家, 玩家"。
func freeze_roster(room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)),
				"name": str(_peer_names.get(pid, "玩家"))})
	room.roster = out
```

`on_peer_left` 的三个循环各改一处：

```gdscript
	for code in rooms.keys():
		var room: Room = rooms[code]
		if not room.players.has(peer_id):
			continue
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
		# ★ 对局中(阶段 2-B):**不拆**。客户端转连 worker 时会**全部**断开大厅,拆了它们
		#   就再也回不来 —— 回局(路径乙)与「C 看得见这个房」都要求房活到对局结束;
		#   回收改由 RoomManager._reclaim_finished_matches 按"worker 进程还在不在"判(精确)。
		#   ★ 这里**不再发**"配对已取消"那句提示:房没有被取消,那句话会是假的。真出问题
		#   (对手根本没连上 worker)由 worker 侧的 claim 守卫与客户端 25s 的 claim 兜底收尾。
		if room.started:
			continue
		if room.players.is_empty():
			teardown_room(room)   # 延迟归还端口(worker 会自己退;见 WORKER_PORT_REUSE_DELAY)
```

```gdscript
		rr.players.erase(peer_id)
		rr.player_role.erase(peer_id)
		if rr.in_match:
			continue   # 对局中:房活到 worker 退出(理由同上,大乱斗逐字同款)
		if rr.players.is_empty():
			teardown_room(rr)
		else:
			if rr.host_peer == peer_id:
				rr.host_peer = rr.players[0]
				print("大乱斗房 %s 房主转移 → peer %d" % [rcode, rr.host_peer])
			if not rr.in_match:
				_broadcast_royale_state(rr)
```

（3v3 那一段逐字同款：`if tr.in_match: continue`，其余不动。）

★ **`_flush_royale_state` / `_flush_team_state` 里那两条 `if rr.in_match: return` 保持不动** —— 它们挡的是"开局那一刻正在转连的成员还收到等待室广播"。

- [ ] **Step 6: 改三处列表 + 两处 `*_leave`**

`on_list_rooms` 拆成"纯构造 + 发送"：

```gdscript
# 房间列表的**纯构造**(不含发送)。★ 抽出来是为了可测:探针没有对端,`NetBus.reply` 会静默
# 跳过 → 列表内容**观测不到**(与回局判据抽成纯函数同一个理由)。
# ★ `in_match` 的房**照列**:C 要看得见 A 与 B 的房间(用户裁定),而"进不去"由 `join_room`
#   那一侧的 `started` 守卫保证 —— 可见性与拒绝入房是同一件事的两半,缺一条就是"看不见"或"进得去"。
func room_list_payload() -> Array:
	var arr: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if room.players.is_empty() and not room.started:
			continue
		var names: Array = []
		var count := 0
		if room.started:
			# 对局中:名单取**冻结的那份** —— `players` 已空、`_peer_names` 已擦,
			# 读它们只会得到"玩家/玩家"这种退化读数。
			for e in room.roster:
				names.append(str((e as Dictionary).get("name", "玩家")))
			count = room.roster.size()
		else:
			for peer_id in room.players:
				names.append(_peer_names.get(peer_id, "玩家"))
			count = room.players.size()
		arr.append({"code": code, "players": count, "names": names, "in_match": room.started})
	return arr


func on_list_rooms(caller: int) -> void:
	NetBus.reply(caller, "room_list", room_list_payload())
```

`royale_list`：

```gdscript
# 公开房间列表的纯构造(只列**公开**房;调用方的过滤不在本函数里,见 royale_list)。
# ★ in_match 的房照列(理由同 room_list_payload);未开局的空房仍不列(那是幽灵房)。
func royale_list_payload() -> Array:
	var arr: Array = []
	for code in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[code]
		if not rr.is_public:
			continue
		if rr.in_match:
			var dn: Array = []
			for e in rr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": code, "players": rr.roster.size(), "max_players": rr.max_players,
					"names": dn, "in_match": true})
			continue
		if rr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in rr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names, "in_match": false})
	return arr


func royale_list(caller: int) -> void:
	# 判活同 NetBus.reply:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload())
```

`team_list` 逐字同款（`team_list_payload()` / `team_list(caller)`，`TEAM_ROLES` 作 max_players）。

两处 `*_leave` 的空房分支加 `in_match` 守卫（与 `on_peer_left` 同一形状）：

```gdscript
	if rr.players.is_empty() and not rr.in_match:
		teardown_room(rr)
	else:
		if rr.host_peer == caller:
			rr.host_peer = rr.players[0]
		if not rr.in_match:
			_broadcast_royale_state(rr)
```

★ 3v3 同款。★ 注意 `else` 分支里 `rr.players[0]` 在 `players` 为空时会越界 —— 把 host 转移那一行也包进 `if not rr.players.is_empty()`：

```gdscript
	else:
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]
```

- [ ] **Step 7: `room_manager.gd` 的四个 spawn 点调 `freeze_roster`**

`_start_match`（在 `room.started = true` 之后、`pick_port()` 之前）、`royale_start` / `royale_start_ai`（在 `rr.in_match = true` 之后）、`team_start`（在 `tr.in_match = true` 之后）各加：

```gdscript
	# ★ 开局那一刻把名单冻进房记录:成员转连 worker 后会陆续断开大厅,靠 players/_peer_names
	#   渲染的对局中列表会退化成"玩家/玩家"(见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(room)   # royale/team 那三处把 room 换成 rr / tr
```

- [ ] **Step 8: `--import` + 跑探针 + 硬校验**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn`
Expected: `REJOIN LOBBY PROBE: ALL-OK`。
Run（PowerShell）：`Select-String -Path server\lobby_rooms.gd -Pattern 'tokens'` → **0 命中**；`Select-String -Path server\room_manager.gd -Pattern 'tokens'` → **0 命中**；`Select-String -Path server\server_main.gd -Pattern '_tokens'` → **仍在**（worker 侧那张表，**不许动**）。

- [ ] **Step 9: 变异反证（三条，逐条还原）**

1. 把 `on_peer_left` 的 1v1 分支 `if room.started: continue` 删掉 ⇒ ① 的"房仍在"应红。
2. 把 `room_list_payload()` 里 `if room.started:` 那块名字来源换回 `_peer_names` ⇒ ① 的"名单取自冻结的那份"应红。
3. 把 `join_room` 的 `if room.started:` 守卫删掉 ⇒ ① 的"第三人被拒"应红。

三段输出写进报告。

- [ ] **Step 10: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd \
  tests/rejoin_lobby_probe.gd tests/rejoin_lobby_probe.gd.uid tests/rejoin_lobby_probe.tscn
git commit -m 'feat(net): 对局中的房活过转连(三模式)+ 列表可见/拒绝入房 + 场景探针'
```

---

## Task 7: 对局结束即回收（`_reclaim_finished_matches`）+ 探针相④

**Files:**
- Modify: `server/room_manager.gd`（`MATCH_SWEEP_INTERVAL` / `_process` / `_reclaim_finished_matches` / 四个 spawn 点记 `worker_pid`）
- Modify: `server/lobby_rooms.gd`（`var rejoin := RejoinRegistry.new()` —— 本任务的回收梯要顺手做凭据表的 GC）
- Modify: `tests/rejoin_lobby_probe.gd`（追加相④）

**Interfaces:**
- Consumes: `WorkerLauncher.pid_alive(pid)`（Task 5）、`RejoinRegistry.prune`（Task 4）
- Produces: `RoomManager.MATCH_SWEEP_INTERVAL := 30.0`、`RoomManager._reclaim_finished_matches() -> void`、`LobbyRooms.rejoin: RejoinRegistry`

★ **为什么必须有这一步**（spec §3 第 1 条的后半句）：房不再在转连那一刻被拆，**就没有任何东西会拆它** → 端口与列表位永久占用。这是本层"端口泄漏"补过的第五次，故回收**必须走同一处拆除收口**（`room_sweep_smoke` 的 `_check_teardown_funnel` 在盯着）。

- [ ] **Step 1: 追加探针相④（此时必红）**

在 `tests/rejoin_lobby_probe.gd` 的 `_ready()` 里 `_phase_lifetime_team()` 之后插 `_phase_reclaim()`，并加：

```gdscript
# ── ④ 对局结束即回收:worker 进程还在 → 房不许动;worker 退了 → 房必须被回收 ──
# ★ 判据是"**worker 进程还在不在**":三种模式的 worker 都在对局结束时自己退,而任何按
#   "一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口与列表位)。
# ★ 反向那一半(**活的 pid 不回收**)不能省:只断言"死的会收"会让一个"见谁收谁"的实现全绿,
#   而那会把正在进行的对局连端口一起端掉。
func _phase_reclaim() -> void:
	# 活的 pid:用**本进程自己**——它一定活着,不需要拉起任何子进程
	var live := OS.get_process_id()
	var r := LobbyRooms.Room.new()
	r.code = "9011"
	r.started = true
	r.worker_port = 29911
	r.worker_pid = live
	_rm.lobby.rooms[r.code] = r
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = "9012"
	rr.in_match = true
	rr.worker_port = 29912
	rr.worker_pid = 999999        # 本机上不该存在的 pid
	_rm.lobby.royale_rooms[rr.code] = rr
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = "9013"
	tr.in_match = true
	tr.worker_port = 29913
	tr.worker_pid = 0             # ★ 还没登记 pid(拉起中)→ **不得**被判成结束
	_rm.lobby.team_rooms[tr.code] = tr

	_rm._reclaim_finished_matches()
	_check(_rm.lobby.rooms.has("9011"), "④ ★ worker pid 活着(本进程)→ 房**不许**被回收")
	_check(not _rm.lobby.royale_rooms.has("9012"), "④ worker pid 已退 → 大乱斗房必须被回收")
	_check(_rm.lobby.team_rooms.has("9013"), "④ ★ pid 还没登记(拉起中)→ 不得判成结束")
```

- [ ] **Step 2: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn`
Expected: 红在 `Nonexistent function '_reclaim_finished_matches'`。

- [ ] **Step 3: 实现回收梯 + 在四个 spawn 点记 pid**

**先在 `server/lobby_rooms.gd` 的 `var team_rooms: Dictionary = {}` 之后加凭据表的字段**（本任务的回收梯要顺手做它的 GC；表本身的读写接线在 Task 8）：

```gdscript
# 回局凭据表(阶段 2-B,spec §3 第 2 条)。★ 它**独立于房对象**:房被拆除时凭据要不要跟着
# 消失,由 `teardown_room` **显式**决定(`rejoin.drop_room`),而不是由"房对象还在不在"隐式决定
# —— 回局的查询要在大厅侧活过拆除(见 RejoinRegistry 的类头)。
var rejoin := RejoinRegistry.new()
```

然后改 `server/room_manager.gd`。顶部常量区（挨着 `SWEEP_INTERVAL` / `MAX_ROOM_AGE`）加：

```gdscript
# 对局中房间的回收梯周期(秒)。★ 比 SWEEP_INTERVAL(600s)密得多,因为判据与目的都不同:
# 那条是"房挂太久了"(超龄清扫),这条是"**这一局结束了**"—— 端口与列表位白占的代价是
# "池子少一个 / 列表里挂着一个死房",10 分钟一轮意味着每局结束后要多占最多 10 分钟。
# 30s 是"比回收延迟(360s)小一个量级"的量级选择,与宽限期无关(判据不读宽限期)。
const MATCH_SWEEP_INTERVAL := 30.0
var _match_sweep_acc := 0.0
```

`_process` 末尾追加（**不动**上面那条 600s 的梯）：

```gdscript
	# ★ 对局中房间的回收走**另一条更密的**梯(判据与目的都不同,见 MATCH_SWEEP_INTERVAL)。
	_match_sweep_acc += delta
	if _match_sweep_acc >= MATCH_SWEEP_INTERVAL:
		_match_sweep_acc = 0.0
		_reclaim_finished_matches()
```

加函数（放在 `_sweep_stale_rooms` 之后）：

```gdscript
# 对局结束即回收(阶段 2-B,spec §3 第 1 条的后半句):`in_match`(1v1 是 `started`)的房不再在
# "客户端转连 worker"那一刻被拆,于是**必须有替代的回收路径** —— 否则端口与列表位永久占用
# (本层为「端口泄漏」这同一个失败模式补过的第五次)。
# ★ 判据 = **worker 进程还在不在**(`WorkerLauncher.pid_alive`):三种模式的 worker 都在对局
#   结束时自己退(1v1 宽限到点收场 / 大乱斗与 3v3 全员走光),这是"这局结束了吗"的**精确**答案;
#   任何按"一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口)。
# ★ 兜底仍在:2h 超龄清扫(`_sweep_stale_rooms`)会把"worker 一直不退"的僵尸房连进程一起杀掉
#   —— 两条路径并存,不是二选一。
# ★ 回收**必须走拆除单一收口**(端口归还/注册表删除只许出现在那里;`room_sweep_smoke` 盯着)。
func _reclaim_finished_matches() -> void:
	# token 表的 GC 搭这条梯(30s 一次):TTL 只是表的上界,不需要独立定时器
	lobby.rejoin.prune(Time.get_ticks_msec())
	var done: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if room.started and _match_over(room.worker_port, room.worker_pid):
			done.append(room)
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		if rr.in_match and _match_over(rr.worker_port, rr.worker_pid):
			done.append(rr)
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		if tr.in_match and _match_over(tr.worker_port, tr.worker_pid):
			done.append(tr)
	for room in done:
		var kind := "大乱斗房" if room is LobbyRooms.RoyaleRoom \
				else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间")
		print("[lobby] 对局结束,回收%s %s(端口 %d)" % [kind, room.code, room.worker_port])
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)


# 这一局结束了吗(worker 进程已经不在)?★ `port <= 0` 或 `pid <= 0` 一律**不算**结束 ——
# 那两种取值都只出现在"拉起中"的窗口里(`worker_port` 在 `pick_port` 之后才赋值,pid 在
# `create_process` 成功之后才登记),判成结束会让开局那一瞬被自己的回收梯拆掉。
static func _match_over(port: int, pid: int) -> bool:
	if port <= 0 or pid <= 0:
		return false
	return not WorkerLauncher.pid_alive(pid)
```

四个 spawn 点里，在 **spawn 成功之后**补记 pid（1v1 `_start_match` / `royale_start` / `royale_start_ai` / `team_start`）：

```gdscript
	room.worker_pid = _launcher.pid_of(port)   # royale/team 三处换成 rr / tr
```

★ 位置：紧跟 `if not _launcher.spawn_*(port, …): … return` 那个 `if` **之后**（`TEARDOWN_ABORT` 那条路上不会有 pid，也就不该有）。

- [ ] **Step 4: `--import` + 跑探针确认全绿**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn`
Expected: `REJOIN LOBBY PROBE: ALL-OK`。

- [ ] **Step 5: 跑两条既有冒烟（回收改动必须没碰坏清扫）**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd` → `SMOKE_ROOM_SWEEP OK: …`

- [ ] **Step 6: 变异反证**

把 `_reclaim_finished_matches` 里 `lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)` 换成直接 `lobby.royale_rooms.erase(room.code)` ⇒ `room_sweep_smoke` 的 `_check_teardown_funnel` 必须红（"拆除必须走单一收口"）⇒ 还原。两段输出写进报告。

- [ ] **Step 7: 提交**

```bash
git add server/room_manager.gd tests/rejoin_lobby_probe.gd
git commit -m 'feat(net): 对局结束即回收房(判据 = worker 进程还在不在;30s 梯;走拆除收口)'
```

---

## Task 8: 回局凭据的登记与清理（四个 spawn 点 + 拆除收口）

**Files:**
- Modify: `server/lobby_rooms.gd`（`teardown_room` 里 `drop_room`）
- Modify: `server/room_manager.gd`（四个 spawn 点：token 收进 `granted`、spawn 成功后 `_grant_rejoin`）

**Interfaces:**
- Consumes: `RejoinRegistry.grant/drop_room`（Task 4）、`LobbyRooms.rejoin`（Task 7 已加好的字段）
- Produces: `RoomManager._grant_rejoin(code, port, granted) -> void`

- [ ] **Step 1: 拆除时清掉该房的凭据**

★ 凭据表本身（`var rejoin := RejoinRegistry.new()`）**已经在 Task 7 加好了**（回收梯要做它的 GC）—— 本步骤只做"拆除时作废凭据"这一件事，**不要**再声明一次那个字段。

`teardown_room` 里，在 `print("%s %s 拆除…")` 之后、`if disconnect_peers:` 之前插入：

```gdscript
	# ★ 这一局的凭据随房一起作废:房都拆了,worker 要么已经退了、要么马上会被杀,留着凭据
	#   只会让回局把客户端送到一个已经不属于它的端口上(而且**没有一行报错**)。
	var ntk := rejoin.drop_room(room.code)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
```

★ 位置要在 `royale_rooms.erase(...)` **之前或之后都行**（`drop_room` 只按 `room.code` 全等匹配，与注册表无关），但**必须在同一个函数体内** —— `room_sweep_smoke` 的收口纪律只允许端口归还/注册表删除出现在 `teardown_room` / `_release_port_later` 里，而 `rejoin.drop_room(` 这个串不匹配任何被监视的模式，故是安全的；**别把这段挪到调用方**。

- [ ] **Step 2: `RoomManager` 四个 spawn 点登记凭据**

`_grant_rejoin` 辅助函数（放在 `_send_go_match` 之前）：

```gdscript
# 把这一局的回局凭据登进大厅的凭据表。
# ★ **必须在 spawn 成功之后调**:凭据里带 worker 的 pid,而"这一局还在不在"就是靠它判的
#   (见 RejoinRegistry.decision 的 worker_alive 入参)。
# ★ granted 的构造在 spawn **之前**(token 必须先于 go_match 发到客户端,见那两处的注释),
#   故它是 `[[role, token], …]` 这份中间形态 —— 不是"发送"与"登记"两件事分家,而是同一条
#   数据在两处各取所需。
func _grant_rejoin(code: String, port: int, granted: Array) -> void:
	var pid := _launcher.pid_of(port)
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), code, int(g[0]), port, pid, now)
```

`_start_match` 里把 token 循环改成"先收再登记"（★ `room.tokens[pid] = tk` 那一行**已经在 Task 6 删掉了**；若它还在这儿，说明 Task 6 没做完，**回去补**）：

```gdscript
	room.worker_port = port
	# ★ token 必须在 **go_match 之前**发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,
	#   之后再发就静默丢失(既有注释)。登记进回局表则要等 spawn 成功(要 pid)→ 先收起来。
	var granted: Array = []   # [[role, token], …]
	for pid in room.players:
		var tk := LobbyRooms.new_token()
		granted.append([int(room.player_role[pid]), tk])
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	if not _launcher.spawn_worker(port):
		NetBus.reply(room.players[0], "server_message", "无法启动对局")
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_ABORT, "配对失败,房间已关闭——请重新建房/加入")
		return
	room.worker_pid = _launcher.pid_of(port)
	_grant_rejoin(room.code, port, granted)
```

`royale_start` / `royale_start_ai` / `team_start` 三处同款（`room` → `rr` / `tr`；三个 `spawn_*` 的失败分支原样保留）。★ `royale_start_ai` 的 token 循环只给 `rr.players`（AI 号没有 peer，既有的 `if lobby.is_peer_online(pid)` 已经表达了这一点），`granted` 的构造范围**与之一致**。

- [ ] **Step 3: 硬校验（`tokens` 这条链彻底消失）**

Run（PowerShell）：`Select-String -Path server\*.gd -Pattern '\.tokens'` → **0 命中**。
Run（PowerShell）：`& $GODOT --headless --path . --import` → 无 Parse Error。
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn` → `REJOIN LOBBY PROBE: ALL-OK`。
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd` → `SMOKE_ROOM_SWEEP OK: …`。

- [ ] **Step 4: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd
git commit -m 'feat(net): 回局凭据的登记(spawn 成功后带 pid)与拆除时作废;删掉三个房类的 tokens'
```

---

## Task 9: `NetBusExt` 两条 RPC（+ `reconnect_smoke` 扩容）

**Files:**
- Modify: `core/net/net_bus_ext.gd`（末尾"断线重连"一节之后）
- Modify: `tests/reconnect_smoke.gd`

**Interfaces:**
- Produces: `NetBusExt.rejoin_request(code, token)`（any_peer reliable）→ 信号 `rejoin_requested(caller, code, token)`；`NetBusExt.rejoin_denied(reason)`（authority reliable）→ 信号 `local_rejoin_denied(reason)`

- [ ] **Step 1: 先在 `reconnect_smoke.gd` 里加断言（此时必红）**

常量区追加：

```gdscript
# ── 回大厅后回局(阶段 2-B,2026-09-21)──
# 两条:一条上行(客户端 → 大厅)、一条下发(大厅 → 客户端)。与上面那些**同款纪律**:
# 必须在 NetBusExt、**不得**在 NetBus(挂错节点 = 静默 no-op,而症状只是"回局永远失败")。
const N_REJOIN_RPCS := ["rejoin_request", "rejoin_denied"]

const N_REJOIN_RPC_ANN := {
	"rejoin_request": "@rpc(\"any_peer\", \"reliable\")",
	"rejoin_denied": "@rpc(\"authority\", \"reliable\")",
}

const N_REJOIN_SIGNALS := ["rejoin_requested", "local_rejoin_denied"]
```

在 `_initialize()` 的 `if _fail == 0:` **之前**追加：

```gdscript
	# ── 回局协议的两条(阶段 2-B)──
	for n in N_REJOIN_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)
	for s in N_REJOIN_SIGNALS:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)
	# ★ 方向写反是**静默**的:`rejoin_denied` 若写成 any_peer = 任何客户端都能伪造"你的对局结束了";
	#   `rejoin_request` 若写成 authority = 客户端的上行被直接拒("按钮点了没反应")。
	for n in N_REJOIN_RPC_ANN:
		var rann := _rpc_ann(ext, n)
		_check(rann == N_REJOIN_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_REJOIN_RPC_ANN[n], rann])
```

- [ ] **Step 2: 跑一次确认它红**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE FAILED: …`（列出缺的四条）。

- [ ] **Step 3: 加两条 RPC**

`core/net/net_bus_ext.gd` 末尾（"回局"这一节要**自成一段**，并在类头那段"三载荷"的说明之后点一句）：

```gdscript
# ── 回大厅后回局(阶段 2-B,2026-09-21)──
# 玩家按 ESC 回主菜单 → 主菜单的「回到对局」把他送回对应的大厅页 → 大厅凭(房间号, token)
# 把 `go_match` **原样再发一次**,客户端于是走与首次进场**逐字同一条**转连/认领路径。
# ★ 成功那一路**不另开信号**:复用的是原 NetBus 的 `go_match`(方法表一个字不动)。
# ★ 失败那一路必须显式告诉客户端 —— 否则它会一直等一个永不到来的 go_match,而主菜单那颗
#   按钮还亮着(凭据没清)。
signal rejoin_requested(caller: int, code: String, token: String)

@rpc("any_peer", "reliable")
func rejoin_request(code: String, token: String) -> void:
	rejoin_requested.emit(multiplayer.get_remote_sender_id(), code, token)

# 大厅 → 客户端:这一局回不去了(凭据失效 / 房间号不符 / 对局已结束)。
signal local_rejoin_denied(reason: String)

@rpc("authority", "reliable")
func rejoin_denied(reason: String) -> void:
	local_rejoin_denied.emit(reason)
```

- [ ] **Step 4: `LobbyRooms` 接上 handler（**并给出回局判据**）**

`_enter_tree` / `_exit_tree` 各加一行：

```gdscript
	NetBusExt.rejoin_requested.connect(on_rejoin_request)
```
```gdscript
	NetBusExt.rejoin_requested.disconnect(on_rejoin_request)
```

加 handler（放在 `team_list` 之后）：

```gdscript
# ── 回大厅后回局(spec §3.4 路径乙)──
# 客户端从主菜单凭(房间号, token)要回原来那一局。**应答复用 `go_match`**(方法表一个字不动),
# 于是客户端那条"连 worker → 认领 role → 进对局场景"的路与首次进场**逐字同一条**。
# ★ 这里**不判对局状态**("你还在宽限期吗"只有 worker 手里的 `_grace` 知道),只判两件事:
#   凭据对不对得上、以及**这一局的 worker 还在不在** —— 后者防止把一个客户端送到一个已经结束、
#   端口可能已被复用给别的对局的地址上。★ "晚了"的那一档(认领时该 role 已不在宽限期)由
#   worker 的 `_on_reclaim` 判并踢连接,客户端会回到大厅页并看到失败提示(路径乙的已知边界)。
# ★ 判据本体是**纯函数**(`RejoinRegistry.decision`):四种组合在 `-s` 冒烟里逐个钉住,
#   本函数只做"查 → 判 → 发",不在这里再写一遍 if/else(那正是漂的成因)。
func on_rejoin_request(caller: int, code: String, token: String) -> void:
	var now := Time.get_ticks_msec()
	var e := rejoin.lookup(token, now)
	var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))
	var why := RejoinRegistry.decision(e, code, alive)
	if why != "":
		# ★ worker 已经退了 → 这份凭据再也不会成立,当场清掉:留着它只会让**下一个**请求
		#   再走一遍同样的拒绝(而且它已经骗过一次了 —— 列表里那个房也会在 30s 内被回收)。
		if not e.is_empty() and not alive:
			rejoin.drop_token(token)
		print("[lobby] 拒绝回局(peer=%d):%s" % [caller, why])
		if NetBus.is_peer_live(caller):
			NetBusExt.rpc_id(caller, "rejoin_denied", why)
		return
	print("[lobby] 回局:房间 %s role %d → worker 端口 %d" % [
			code, int(e.get("role", 0)), int(e.get("worker_port", 0))])
	# 复用原版 go_match:签名与首次进场完全相同(role, port)
	NetBus.reply(caller, "go_match", int(e.get("role", 0)), int(e.get("worker_port", 0)))
```

- [ ] **Step 5: 探针追加相⑤⑥（判据面）**

在 `tests/rejoin_lobby_probe.gd` 的 `_finish()` 之前插 `_phase_rejoin()`：

```gdscript
# ── ⑤⑥ 回局判据在**生产 handler** 上的行为(不是只测那个纯函数)──
# ★ 为什么两半都要:纯函数测过了,而 handler 里"查 → 判 → 发"这三步的**接线**没测 ——
#   把 `lookup` 写成 `lookup(token, now + 一个很大的数)` 或把 `code` 传错,纯函数照样全绿。
# ★ 本探针**观测不到 go_match**(没有对端 → `NetBus.reply` 静默跳过),故这里能断言的是
#   拒绝路径的**副作用**(死 worker 时凭据被清)。**放行路径的真实发送**由真链路探针覆盖
#   (`tests/rejoin_probe`),这条边界照实登记。
func _phase_rejoin() -> void:
	var now := Time.get_ticks_msec()
	# ① 房间号不符:拒绝,且凭据**不被**清(绑定还在宽限期里,值得让玩家重试一次)
	_rm.lobby.rejoin.grant("tk_x", "9021", 1, 29921, OS.get_process_id(), now)
	_rm.lobby.on_rejoin_request(P_C, "9999", "tk_x")
	_check(not _rm.lobby.rejoin.lookup("tk_x", now).is_empty(),
			"⑤ 房间号不符:拒绝但**不清**凭据(worker 还活着,能重试)")
	# ② worker 已退:拒绝 + **清掉**凭据(它再也不会成立)
	_rm.lobby.rejoin.grant("tk_y", "9021", 1, 29922, 999999, now)
	_rm.lobby.on_rejoin_request(P_C, "9021", "tk_y")
	_check(_rm.lobby.rejoin.lookup("tk_y", now).is_empty(),
			"⑥ ★ worker 已退:拒绝并把这份凭据当场作废(留着只会骗下一个请求)")
	# ③ 凭据根本不存在:拒绝,且不得凭空造出凭据
	_rm.lobby.on_rejoin_request(P_C, "9021", "tk_not_exist")
	_check(_rm.lobby.rejoin.lookup("tk_not_exist", now).is_empty(),
			"⑥ 未知 token:拒绝且不登记任何东西")
```

- [ ] **Step 6: `--import` + 两条冒烟 + 探针**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd` → `RECONNECT SMOKE OK`
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd` → `REJOIN REGISTRY: ALL-OK`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn` → `REJOIN LOBBY PROBE: ALL-OK`

- [ ] **Step 7: 变异反证**

把 `on_rejoin_request` 里 `var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))` 改成 `var alive := true` ⇒ 相⑥ 的"拒绝并作废"应红；还原 ⇒ 复绿。两段输出写进报告。

- [ ] **Step 8: 提交**

```bash
git add core/net/net_bus_ext.gd tests/reconnect_smoke.gd server/lobby_rooms.gd tests/rejoin_lobby_probe.gd
git commit -m 'feat(net): rejoin_request / rejoin_denied 两条 RPC + 大厅侧回局 handler + 源码级冒烟'
```

---

## Task 10: `PvpSession` 三个字段 + `LobbyPage` 回局支路

**Files:**
- Modify: `core/net/pvp_session.gd`
- Modify: `scenes/lobby_page.gd`
- Modify: `tests/reconnect_smoke.gd`（字段与 `reset()`）
- Modify: `tests/rejoin_lobby_probe.gd`（`can_rejoin()` / `clear_rejoin()` 的真值表）

**Interfaces:**
- Produces:
  - `PvpSession.room_code: String` / `mode: String` / `rejoin: bool`
  - `PvpSession.can_rejoin() -> bool` / `PvpSession.clear_rejoin() -> void`
  - `LobbyPage._request_rejoin()` / `_on_rejoin_denied(reason)` / `_tick_rejoin_timeout() -> bool`

- [ ] **Step 1: 先加冒烟断言（此时必红）**

`tests/reconnect_smoke.gd` 里 `for f in ["token", "worker_port"]:` 那个循环扩成：

```gdscript
	for f in ["token", "worker_port", "room_code", "mode", "rejoin"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)
```

`reset()` 的断言区补三条：

```gdscript
	_check(reset_body.contains("room_code = \"\""),
			"★ PvpSession.reset() 未清 room_code(换模式会拿着上一局的房号去请求回局)")
	_check(reset_body.contains("mode = \"\""),
			"★ PvpSession.reset() 未清 mode(回局会把人送进错的大厅页)")
	_check(reset_body.contains("rejoin = false"),
			"★ PvpSession.reset() 未清 rejoin(下一局会拿 claim_role 去当回局、被 worker 当串线踢掉)")
	_check(ses.contains("static func can_rejoin()") and ses.contains("static func clear_rejoin()"),
			"PvpSession 缺 can_rejoin() / clear_rejoin()(主菜单按钮与回局失败路径都要用)")
```

跑一次确认红：

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE FAILED: …`

- [ ] **Step 2: 改 `core/net/pvp_session.gd`**

在 `static var worker_port: int = 0` 之后加：

```gdscript
# ── 「回大厅后回局」(路径乙)的三个字段(2026-09-21,阶段 2-B)──
# ★ 与上面两条同款纪律:**加字段前先 grep 确认有读者**。三个都有:
#   room_code : 回局请求要带上它(大厅按它**交叉核对**凭据;主键仍是 token)。
#               ★ 它当年被删过一次(只写不读)—— 现在有读者了才回来。
#   mode      : 主菜单那颗「回到对局」要知道把玩家送回**哪个大厅页**("pvp"/"royale"/"team")。
#               ★ 它**不是**"是不是大乱斗局"的判据(那条仍然是"从哪个场景进来",见本文件
#                 下面那段)—— 它只回答"回局走哪一页",故名字取 mode 而不是 royale。
#   rejoin    : 一次性开关:下一次 `go_match` 是**回局**(认领 role 走 `reclaim_role`,
#               而不是 `claim_role`)。
static var room_code: String = ""
static var mode: String = ""
static var rejoin: bool = false


# 手里还攥着一局的凭据吗?(主菜单那颗「回到对局」按钮的唯一判据。)
# ★ 做成函数而不是让调用方各写一遍与条件:它还要求 mode 已知 —— 不然按钮点了没有去处。
static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != "" and mode != ""


# 清掉回局凭据(大厅答"回不去了" / 回局超时时调)。
# ★ 与 `reset()` **分开**:`reset()` 会把 `server_address` 也拨回云默认 —— 在人家的自建服上
#   调它等于把玩家踢到另外一台机器去。
static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	mode = ""
	rejoin = false
```

`reset()` 里补三行（挨着 `token = ""` / `worker_port = 0`）：

```gdscript
	room_code = ""
	mode = ""
	rejoin = false
```

- [ ] **Step 3: `LobbyPage` 加回局支路**

`_finish_lobby_ready`（`:63`）里把最后那行 `_request_list.call_deferred(...)` 换成：

```gdscript
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	# ★ 「回局」与「进大厅拉列表」是**同一个位置的两条岔路**:回局的玩家一进本页就该找大厅要
	#   `go_match`,而不是拉房间列表(列表对他没有意义,他手上有更硬的凭据)。
	if PvpSession.rejoin:
		_request_rejoin.call_deferred()
	else:
		_request_list.call_deferred("正在连接服务器获取房间列表…")
```

在 `_do_go_match` 之上加一整节：

```gdscript
# ── 回大厅后回局(spec §3.4 路径乙;2026-09-21)──
# 玩家按 ESC 回主菜单 → 主菜单的「回到对局」把他送回**本页**(那条路刻意**不**调
# `PvpSession.reset()` —— token/worker_port/room_code 就是凭据)。本页做三件事:
#   ① 连大厅(地址取 `PvpSession.server_address`,**不看地址框**);
#   ② 发 `rejoin_request(房间号, token)`;
#   ③ 大厅复用 `go_match` 把它送回原 worker —— 之后与首次进场**逐字同一条路**。
# ★ 唯一的岔路在 `_claim_role_worker`(对局已经开着 → 必须发 `reclaim_role`)。
var _rejoin_sent_ms := 0


func _request_rejoin() -> void:
	# 凭据不完整(理论上到不了:按钮本就不该亮)→ 退回正常的拉列表,别把玩家卡在空白页
	if not PvpSession.can_rejoin():
		PvpSession.rejoin = false
		_request_list.call_deferred("正在连接服务器获取房间列表…")
		return
	# ★ 地址必须取 `PvpSession.server_address` 而不是地址框:三个大厅页的地址框默认值**不同**
	#   (大乱斗/3v3 页默认 127.0.0.1,1v1 页默认云地址)—— 照地址框走会连到**另一个**大厅,
	#   症状只是"回不去",而房其实好好地在另一台机器上。
	_addr_edit.text = PvpSession.server_address
	_status.text = "正在回到对局…"
	_with_lobby(func() -> void:
		_rejoin_sent_ms = Time.get_ticks_msec()
		_status.text = "正在回到对局…"
		NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token))


# 大厅答"回不去了"(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。
# ★ 必须清:否则主菜单那颗按钮永远亮着、按了永远失败(而玩家完全不知道为什么)。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason


# 回局请求发出后大厅一直没应答的兜底(15s)。没有它,玩家会停在一句"正在回到对局…"上,
# 而本页的其它兜底梯(worker 转连 / claim)此时**都还没启动**(它们要等 `go_match` 之后)。
# ★ 判据里带 `PvpSession.rejoin`:回局成功时它已被清掉,这条梯自然失效(claim 那条接管)。
func _tick_rejoin_timeout() -> bool:
	if PvpSession.rejoin and _rejoin_sent_ms > 0 \
			and Time.get_ticks_msec() - _rejoin_sent_ms > 15000:
		_rejoin_sent_ms = 0
		PvpSession.clear_rejoin()
		_status.text = "回局请求无响应——已放弃,请重新建房/加入"
		return true
	return false
```

`_do_go_match`（`:272`）里改 token 的赋值：

```gdscript
	PvpSession.role = role
	# ★ 只在**真收到新 token** 时才覆盖:回局那条路大厅**不重发** `session_token`(客户端那
	#   一份就是凭据本身),无条件写会把手里唯一能证明"我是原来那个人"的串抹成空
	#   → `reclaim_role` 必被 worker 拒(理由"令牌不匹配")并**踢连接**,而现场一个字都没有。
	if _pending_token != "":
		PvpSession.token = _pending_token
	_pending_token = ""
```

`_claim_role_worker`（`:294`）改成：

```gdscript
func _claim_role_worker(role: int) -> void:
	_connecting_worker = false
	_claimed_ms = Time.get_ticks_msec()
	# ★★ 回局(路径乙)与首次进场的**唯一分叉**:对局**已经开着**,`claim_role` 会被 worker 的
	#   `_on_role_claimed` 当串线连接**踢掉**(它的第一款判据就是 `_match_started`),必须改发
	#   `reclaim_role`(宽限期内重新认领自己那个 role)。用错那一条的症状是"刚连上就被踢",
	#   且没有任何报错 —— 只有 worker 日志里一行"拒绝串线连接"。
	# ★ 回局时**不发** `player_options`/`report_token`:worker 侧两条 handler 都按
	#   `_claims[r] == caller` 反查,而此刻新 peer 还没进 `_claims`(要等 reclaim 被接受)
	#   → 两条都静默 no-op;而 token 首次 claim 时就报过一次,worker 手里那份正是要比对的那份。
	if PvpSession.rejoin:
		PvpSession.rejoin = false
		NetBusExt.rpc_id(1, "reclaim_role", role, PvpSession.token)
		return
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)
```

`_return_to_lobby`（`:308`）里清回局态：

```gdscript
func _return_to_lobby(msg: String) -> void:
	_connecting_worker = false
	_claimed_ms = 0
	# ★ 回局失败的各种兜底都汇到这里:不清 `rejoin` 就会让页停在"回局态"反复重试(每次都失败)。
	#   `token` **不清** —— 它可能还有效(比如只是 worker 端口没放行),玩家可以回主菜单再试。
	PvpSession.rejoin = false
	_rejoin_sent_ms = 0
	_on_return_to_lobby()
	...
```

- [ ] **Step 4: 三个子类各接一条超时梯（`_process` 顺序不许重排）**

三个页面的 `_process` **第一行**各加（`matchmaking.gd:234` / `royale_lobby.gd:356` / `team_lobby.gd:350`）：

```gdscript
	# 0) 回局(路径乙):请求发出后大厅 15s 无应答 —— 早于下面几条梯,因为此刻它们都还没启动
	if _tick_rejoin_timeout():
		return
```

★ 每条梯的**相对顺序**别动（1v1 是 `[worker → join → 大厅 → claim]`、另两页是 `[worker → claim → 大厅 → ack]`）；回局那条插在最前面是安全的：它只在 `PvpSession.rejoin` 为真时可能返回 true，而那一段里下面几条梯的判据都还不成立。

- [ ] **Step 5: 探针补 `can_rejoin()` 的真值表**

在 `tests/rejoin_lobby_probe.gd` 的 `_phase_rejoin()` 之后插 `_phase_session_flags()`：

```gdscript
# ── ⑦ 凭据判据的真值表(`PvpSession.can_rejoin()` / `clear_rejoin()`)──
# ★ 放在这个**场景**探针里而不是 `-s` 冒烟:`-s` 阶段 autoload 尚未实例化,而本仓已有教训
#   ——`-s` 脚本碰全局类要走 load()/get_script_constant_map() 那套绕法,为一个真值表不值得。
# ★ 这一条防的是"按钮亮着但按了没用":can_rejoin() 少判一个字段(比如漏了 mode),
#   按钮就会出现,而回局必然失败。
func _phase_session_flags() -> void:
	var keep := [PvpSession.token, PvpSession.worker_port, PvpSession.room_code, PvpSession.mode]
	PvpSession.token = "tk"; PvpSession.worker_port = 29901
	PvpSession.room_code = "9021"; PvpSession.mode = "pvp"
	_check(PvpSession.can_rejoin(), "⑦ 四个字段齐 → 可回局")
	PvpSession.mode = ""
	_check(not PvpSession.can_rejoin(), "⑦ ★ mode 缺 → 不可回局(否则按钮点了没有去处)")
	PvpSession.mode = "pvp"; PvpSession.room_code = ""
	_check(not PvpSession.can_rejoin(), "⑦ room_code 缺 → 不可回局(回局请求带不上房号)")
	PvpSession.room_code = "9021"; PvpSession.token = ""
	_check(not PvpSession.can_rejoin(), "⑦ token 缺 → 不可回局")
	PvpSession.token = "tk"; PvpSession.worker_port = 0
	_check(not PvpSession.can_rejoin(), "⑦ worker_port 缺 → 不可回局")
	PvpSession.rejoin = true
	PvpSession.clear_rejoin()
	_check(PvpSession.token == "" and PvpSession.worker_port == 0 \
			and PvpSession.room_code == "" and PvpSession.mode == "" and not PvpSession.rejoin,
			"⑦ ★ clear_rejoin() 必须把五个字段一起清(漏一个就是「按钮永远亮着」)")
	PvpSession.token = keep[0]; PvpSession.worker_port = keep[1]
	PvpSession.room_code = keep[2]; PvpSession.mode = keep[3]
```

★ `PvpSession` 的静态字段是**全局**的:探针必须**还原**自己在 Step 1 摆过的值(上面最后两行),否则后面的探针在同一进程里会读到脏值(本探针是独立进程,但同仓的纪律如此)。

- [ ] **Step 6: `--import` + 三条冒烟 + 探针**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd` → `RECONNECT SMOKE OK`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn` → `REJOIN LOBBY PROBE: ALL-OK`

- [ ] **Step 7: 提交**

```bash
git add core/net/pvp_session.gd scenes/lobby_page.gd scenes/matchmaking.gd scenes/royale_lobby.gd \
  scenes/team_lobby.gd tests/reconnect_smoke.gd tests/rejoin_lobby_probe.gd
git commit -m 'feat(net): 回局支路(连大厅 → rejoin_request → go_match → reclaim_role)+ PvpSession 凭据字段'
```

---

## Task 11: 主菜单「回到对局」按钮 + 三个大厅页记 `room_code`/`mode`

**Files:**
- Modify: `scenes/main_menu.gd`（`_build_menu_buttons` 与 `_btn_group` 一带）
- Modify: `scenes/matchmaking.gd` / `scenes/royale_lobby.gd` / `scenes/team_lobby.gd`（记两个字段）

**Interfaces:**
- Consumes: `PvpSession.can_rejoin()` / `PvpSession.mode` / `PvpSession.rejoin`
- Produces: 主菜单上一个 `name = "RejoinButton"` 的按钮（真链路探针按这个名字找它）

- [ ] **Step 1: 三个大厅页记下"这一局从哪来"**

`scenes/matchmaking.gd`：`_on_room_created` 里加 `PvpSession.room_code = code`；`_join_code` 里在发 `join_room` **之前**加 `PvpSession.room_code = code`；`_enter_match_scene`：

```gdscript
func _enter_match_scene() -> void:
	# ★ 记下"本局从哪个大厅页进来" —— 回局(路径乙)靠它把玩家送回**对的**那一页。
	#   它**不是**"是不是大乱斗局"的判据(那条仍是"从哪个场景进来"),只是回局的路由标签。
	PvpSession.mode = "pvp"
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
```

`scenes/royale_lobby.gd`：`_on_room_state` 开头加 `PvpSession.room_code = str(state.get("code", ""))`；`_enter_match_scene` 里在 `get_tree().call_deferred(...)` 之前加 `PvpSession.mode = "royale"`。

`scenes/team_lobby.gd`：同款（`"team"`，`_enter_match_scene` 里 call_deferred 之前）。

- [ ] **Step 2: 主菜单加按钮**

在 `_build_menu_buttons`（`scenes/main_menu.gd:186`）里，`team_btn` 之后、注释「字间距一律单空格」之前插入：

```gdscript
	# ★ 「回到对局」:只有**手里还攥着一局的凭据**时才出现(按 ESC 回主菜单之后想回去)。
	#   它是**唯一一个不调 `PvpSession.reset()` 的联机入口** —— reset 会把 token/worker_port/
	#   room_code 清掉,而那三样正是回局唯一的凭据(与 `reconnect_smoke` 的 reset 断言看着相反,
	#   其实守的是两件事:`reset()` 必须清干净,而这条路**根本不走** reset)。
	# ★ 名字写死给真链路探针用(`tests/rejoin_watcher` 按名字找它并 emit pressed)。
	var rejoin_btn := UiFactory.button("回 到 对 局", 32)
	rejoin_btn.name = "RejoinButton"
	rejoin_btn.visible = PvpSession.can_rejoin()
	rejoin_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.rejoin = true
		get_tree().change_scene_to_file(_rejoin_scene_path()))
```

把它加进 play 组与返回数组：

```gdscript
	for b in [start_btn, multi_btn, royale_btn, team_btn, rejoin_btn]:
		play_group.add_child(b)
	...
	return [start_btn, multi_btn, royale_btn, team_btn, rejoin_btn, settings_btn, ver_btn, quit_btn]
```

★ 浮现动画对隐藏按钮无副作用（`_emerge` 只推 `modulate:a`），不必特殊处理。

在 `_build_menu_buttons` 之后加：

```gdscript
# 回局要回**哪一页**:凭据里记着 `mode`(三个大厅页各写一次)。未知 mode 兜到 1v1 页
# (can_rejoin() 已经把空 mode 挡在按钮之外,这里只是不给一条 null 路径)。
func _rejoin_scene_path() -> String:
	match PvpSession.mode:
		"royale":
			return "res://scenes/royale_lobby.tscn"
		"team":
			return "res://scenes/team_lobby.tscn"
		_:
			return "res://scenes/matchmaking.tscn"
```

- [ ] **Step 3: 自检（启动不报错 + 三个大厅页仍能起）**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120` → exit 0、无 `SCRIPT ERROR`（主菜单是默认场景）
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120 res://scenes/matchmaking.tscn` → 无 `SCRIPT ERROR`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120 res://scenes/team_lobby.tscn` → 无 `SCRIPT ERROR`

- [ ] **Step 4: 提交**

```bash
git add scenes/main_menu.gd scenes/matchmaking.gd scenes/royale_lobby.gd scenes/team_lobby.gd
git commit -m 'feat(ui): 主菜单「回到对局」按钮(唯一不走 PvpSession.reset 的联机入口)+ 三页记凭据字段'
```

---

## Task 12: 三个大厅页把「对局中」的房画成**看得见、点不动**的一行

**Files:**
- Modify: `scenes/matchmaking.gd`（`_on_room_list`）
- Modify: `scenes/royale_lobby.gd`（`_on_royale_rooms`）
- Modify: `scenes/team_lobby.gd`（`_on_team_rooms`）

**Interfaces:**
- Consumes: 列表载荷的新键 `in_match`（Task 6）
- Produces: 三个模式里 in-match 房都渲染成 `disabled` 的行，文案含「对局中」

- [ ] **Step 1: `matchmaking._on_room_list`**

把行构造改成：

```gdscript
	for r in order:
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		# ★ 对局中的房**照列**但**不可点**(用户要求:"C 要看得见 A 与 B 的房间,但进不去")。
		#   服务端 `join_room` 那边也拒(`room.started`)—— 界面这道只是别让玩家白点一下;
		#   两半都要:`disabled` 是体验,服务端那道才是保证(命令行/旧客户端绕过界面照样进不去)。
		var in_match := bool(r.get("in_match", false))
		var occ: String = ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   玩家: " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s    %s%s" % [code, "对局中" if in_match else "%d/2" % players, occ]
		UiFactory.style_control(btn, 16)
		UiFactory.style_row_button(btn)
		btn.custom_minimum_size = Vector2(600, 46)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.disabled = in_match
		btn.focus_mode = Control.FOCUS_ALL
		if not in_match:
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				_join_code(code))
		_list_box.add_child(btn)
```

`_status.text` 那行末尾追加一句计数（便于人眼确认房确实还在列表里）：

```gdscript
	_status.text = "共 %d 个房间(未满优先;对局中的房照列但不可进)" % order.size()
```

- [ ] **Step 2: `royale_lobby._on_royale_rooms` / `team_lobby._on_team_rooms`**

两处循环里各加同一段（`royale` 用 `maxp`、`team` 用 `LobbyRooms.TEAM_ROLES`，其余逐字相同）：

```gdscript
		var in_match := bool(r.get("in_match", false))
		var btn := UiFactory.button("房间 %s      %s%s" % [code,
				"对局中" if in_match else "%d/%d" % [players, maxp], occ], 32, Vector2(620, 46))
		# ★ 对局中的房照列但点不动(与 1v1 页同款:可见性与拒绝入房是同一件事的两半;
		#   服务端 `royale_join`/`team_join` 的 `in_match` 守卫才是那道保证)。
		btn.disabled = in_match
		if not in_match:
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				_join_room(code, ""))
		_list_box.add_child(btn)
```

两页的 `_status.text = "共 %d 个公开房间" % rooms.size()` 都改成 `"共 %d 个公开房间(对局中的照列但不可进)"`。

- [ ] **Step 3: 自检**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120 res://scenes/matchmaking.tscn` → 无 `SCRIPT ERROR`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120 res://scenes/royale_lobby.tscn` → 无 `SCRIPT ERROR`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 120 res://scenes/team_lobby.tscn` → 无 `SCRIPT ERROR`
Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/rejoin_lobby_probe.tscn` → `REJOIN LOBBY PROBE: ALL-OK`（探针跑的是载荷,渲染改动不该影响它 —— 这条是回归）

★ 版式**不取图**：本批只是把一行的文案与可点状态改掉，没有动版式常量（`UiFactory` 的 `disabled` 样式早就有了，`style_button:280`）。按本仓「不折腾视觉」的取向，人眼验收留给用户跑真链路探针时顺带看一眼列表。

- [ ] **Step 4: 提交**

```bash
git add scenes/matchmaking.gd scenes/royale_lobby.gd scenes/team_lobby.gd
git commit -m 'feat(ui): 三个大厅页把对局中的房画成「对局中」且不可点(C 看得见、进不去)'
```

---

## Task 13: 真链路端到端回局探针（**用户跑**）

**Files:**
- Create: `tests/rejoin_probe.tscn` + `tests/rejoin_probe.gd` + `.uid`
- Create: `tests/rejoin_watcher.gd` + `.uid`（观察者挂在 root 上）
- Create: `tests/rejoin_probe.sh`

**Interfaces:**
- Consumes: 前面全部任务
- Produces: 判据文本 `REJOIN PROBE: ALL-OK`

**覆盖什么**（1v1，三端）：

| 端 | 角色 | 干什么 |
|---|---|---|
| c1 | actor（role 1） | 建房 → 开局 → 进 `pvp_game` → 打到 PLAYING → **按 ESC → 点「回到主菜单」** → 在主菜单点「回到对局」→ 回到**原局**。断言：role 与离开前一致 + **回局后重新收到服务器广播**（PLAYING 计数严格增长） |
| c2 | 对手（role 2） | 点列表加入 → 进 `pvp_game` → 全程保持在线（它是"这一局还在"的见证） |
| c3 | 第三人 | 只连大厅：**列表里看得见这个房**（`in_match == true`）+ **加入被拒**（收不到 `room_joined`/`go_match`，收到 `server_message`） |

**不覆盖什么（照实登记）**：大乱斗 / 3v3 的回局端到端（那要 6~8 个客户端与一条更长的比赛）；这两个模式的**差异部分**（`in_match` 门控、列表、拒绝入房）已由 `tests/rejoin_lobby_probe` 在三模式上逐个钉住，而回局的客户端代码（`LobbyPage` + `PvpMatchClient`）三个模式**共用同一份**。

★ **端口纪律**（沿用 `team_match_probe` 的成规，改之前先读它的文件头）：本探针的大厅起在**池外** `29300`，worker 起投点拨到池外 `29350`（`_rm.get("_launcher").set("_next_port", 29350)`）。**不占 7777**。跑前仍要确认本机没有别的 Godot 占着 7777 —— 本探针**不会杀**它。

- [ ] **Step 1: 写 `tests/rejoin_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/rejoin_probe.gd" id="1"]

[node name="RejoinProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写 `tests/rejoin_probe.gd`（裁判 + 客户端分发）**

```gdscript
extends Node

# 「回大厅后回局」(阶段 2-B)的**真链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法(用户侧):
#   timeout 900 bash tests/rejoin_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 36000 res://tests/rejoin_probe.tscn
# 判据:**文本 `REJOIN PROBE: ALL-OK`**(不看退出码 —— 探针挂住时 --quit-after 到期仍 exit 0
#       且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# ★ `--quit-after 36000`(=600s @60fps)的**推导**:本跑的量级 = 进局 ~8s + PLAYING 静置 ~3s
#   + 离场/主菜单/回局各 ~2s + 收尾 ~5s ≈ **25s**;但收尾要等**三份**客户端结果文件,而 c3
#   的"等一个不会来的 room_joined"自带 8s 窗口。取 600s = 20 倍余量。★ 本仓教训:安全网给薄了
#   会把"跑得慢"读成"功能坏了"(`brawl_rollback_probe` 就是被 3600 误判过的那一个,实测要 30000),
#   故这里按量级 ×20 给,而不是照抄别处的数。
#
# ═══ 拓扑(自当大厅/裁判;全部子进程由本进程 `OS.create_process` 直接拉起)═══
#   本进程 = **真大厅**(`NetBus.start_server(LOBBY_PORT)` + `RoomManager`),不进 7777
#   c1/c2/c3 = 3 个 headless 客户端,各自跑**真** `matchmaking` → **真** `pvp_game`
#   worker = 由**真** `RoomManager._start_match` 经 `WorkerLauncher.spawn_worker` 拉起
#            (与生产逐字同一条路径;探针只把起投端口拨到池外)
#
# ═══ 前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本探针不占 7777,也别杀掉用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 每个子进程都带
#   `--log-file`;失败时把每份引擎日志的尾部一起打印。收尾**按 PID 杀**全部子进程 + 按端口兜底。

const PREFIX := "rejoin_probe_"
const LOBBY_PORT := 29300
const WORKER_PORT_OUT := 29350
const POOL_LOW := 7800
const POOL_HIGH := 8300
const CHILD_QUIT_AFTER := "36000"
const BOOT_TIMEOUT := 40.0
const FINAL_TIMEOUT := 180.0
const RESULT_WAIT := 90.0

var _role := "lobby"
var _rm: Node = null
var _t := 0.0
var _stage := 0
var _done := false
var _child_pids: Array[int] = []
var _failures: Array[String] = []
var _notes: Array[String] = []
var _worker_port := 0
var _room_code := ""
var _start_t := 0.0
var _room_seen := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--who="):
			_role = a.trim_prefix("--who=")
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


func _run_orchestrator() -> void:
	var err := NetBus.start_server(LOBBY_PORT)
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(端口 %d 被占?本探针不占 7777)" % [err, LOBBY_PORT])
		get_tree().quit(1)
		return
	_rm = RoomManager.new()
	add_child(_rm)
	# ★ worker 起投拨到池外(理由同 team_match_probe:本机可能同时跑着用户自己的大厅,
	#   它往池 7800~8299 里发端口,而本探针收尾会按端口杀 worker —— 撞上就是误杀别人的对局)。
	_rm.get("_launcher").set("_next_port", WORKER_PORT_OUT)
	_clean()
	print("PROBE: 大厅就绪(port %d,池外);worker 起投 %d" % [LOBBY_PORT, WORKER_PORT_OUT])
	_spawn_client("c1")
	_spawn_client("c2")
	_spawn_client("c3")


func _spawn_client(who: String) -> void:
	var argv := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path(who),
			"res://tests/rejoin_probe.tscn", "--", "--who=" + who])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	if pid > 0:
		_child_pids.append(pid)
	print("PROBE: 拉起客户端 %s(pid=%d)" % [who, pid])


func _process(delta: float) -> void:
	if _role != "lobby" or _done:
		return
	_t += delta
	if _t > FINAL_TIMEOUT:
		_finish("超时(%.0fs;阶段 %d)\n%s" % [FINAL_TIMEOUT, _stage, _dump()])
		return
	match _stage:
		0:
			_stage_room()
		1:
			_stage_started()
		2:
			_stage_collect()


# 相① 房建起来了(c1 建房),并且**名单被冻住了**(开局前不做断言:开局那一刻才冻)
func _stage_room() -> void:
	if _rm == null or _rm.lobby.rooms.is_empty():
		if _t > BOOT_TIMEOUT:
			_finish("%.0fs 内没有 1v1 房(c1 没建成?)\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	_room_code = str(_rm.lobby.rooms.keys()[0])
	var room = _rm.lobby.rooms[_room_code]
	if room.players.size() < 2 or room.worker_port <= 0:
		if _t > BOOT_TIMEOUT:
			_finish("房 %s 一直没配对(players=%d port=%d)\n%s"
					% [_room_code, room.players.size(), room.worker_port, _dump()])
		return
	_worker_port = int(room.worker_port)
	_check(_worker_port < POOL_LOW or _worker_port >= POOL_HIGH,
			"相① worker 端口 %d 落在真大厅的端口池 [%d,%d) 之外" % [_worker_port, POOL_LOW, POOL_HIGH])
	print("PROBE: 房 %s 配对完成 → worker 端口 %d(t=%.1fs)" % [_room_code, _worker_port, _t])
	_stage = 1


# 相② 房开局后**仍然在列表里**、且带 in_match(这是"C 看得见"的服务端那一半;
# 客户端那一半由 c3 自己断言)
func _stage_started() -> void:
	if _room_code == "" or not _rm.lobby.rooms.has(_room_code):
		_finish("房 %s 消失了(开局那一刻不该被拆 —— 那正是本批要改掉的旧行为)" % _room_code)
		return
	var room = _rm.lobby.rooms[_room_code]
	if not room.started:
		if _t > BOOT_TIMEOUT + 10.0:
			_finish("房 %s 一直没开局(worker 没起来?)\n%s" % [_room_code, _dump()])
		return
	if not _room_seen:
		_room_seen = true
		_start_t = _t
		var row := _find_row(_rm.lobby.room_list_payload(), _room_code)
		_check(not row.is_empty(), "相② ★ 开局后房**仍在**房间列表里(旧实现此刻已拆房 → C 什么都看不见)")
		if not row.is_empty():
			_check(bool(row.get("in_match", false)), "相② 列表行带 in_match=true")
			_check(row.get("names", []) == ["BOT1", "BOT2"], "相② ★ 名单取自冻结的那份(实得 %s)" % str(row.get("names", [])))
		print("PROBE: 房 %s 已开局(t=%.1fs),等三端结果" % [_room_code, _t])
	_stage = 2


func _stage_collect() -> void:
	if _results_ready() >= 3 or _t - _start_t > RESULT_WAIT:
		_finish("" if _results_ready() >= 3 else "只收到 %d/3 份客户端结果" % _results_ready())


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if _child_pids.is_empty():
		_check(false, "没有子进程 → 跨端断言一条都没跑(这一跑不判通过)")
	for who in ["c1", "c2", "c3"]:
		var txt := _read_result(who)
		if txt == "":
			_check(false, "%s 没写出结果文件" % who)
		elif txt.begins_with("OK"):
			_notes.append("%s: %s" % [who, txt.split("\n")[0]])
		else:
			_check(false, "%s: %s" % [who, txt.split("\n")[0]])
	_kill_children()
	if why != "":
		_check(false, why)
	print("═══ 探针明细 ═══")
	for n in _notes:
		print("  · " + n)
	for f in _failures:
		print("  ✗ " + f)
	if _failures.is_empty():
		print("REJOIN PROBE: ALL-OK")
	else:
		print("REJOIN PROBE: %d 条失败" % _failures.size())
		print(_dump())
	get_tree().quit(0 if _failures.is_empty() else 1)


# ── 小组手(与 team_match_probe 同款)──
func _check(ok: bool, msg: String) -> void:
	if ok:
		print("  OK  %s" % msg)
	else:
		_failures.append(msg)
		print("  FAIL %s" % msg)


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}


func _results_ready() -> int:
	var n := 0
	for who in ["c1", "c2", "c3"]:
		if _read_result(who) != "":
			n += 1
	return n


func _kill_children() -> void:
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	for p in [LOBBY_PORT, WORKER_PORT_OUT]:
		ProcUtil.kill_udp_port(p)


func _log_path(kind: String, who: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s_%s.godotlog" % [PREFIX, kind, who])


func _godot_log_path(who: String) -> String:
	return _log_path("client", who)


func _worker_log_path() -> String:
	return str(_rm.get("_launcher").call("log_path", _worker_port))


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _read_result(who: String) -> String:
	return _read(ProjectSettings.globalize_path("user://%s%s.result" % [PREFIX, who])).strip_edges()


func _tail(path: String, n: int = 20) -> String:
	var lines := _read(path).split("\n")
	if lines.size() <= n:
		return "\n".join(lines)
	return "…(前 %d 行省略)\n" % (lines.size() - n) + "\n".join(lines.slice(lines.size() - n))


func _dump() -> String:
	var out := ""
	for who in ["c1", "c2", "c3"]:
		out += "  [%s 引擎日志]\n%s\n" % [who, _tail(_godot_log_path(who))]
	out += "  [worker 日志]\n%s\n" % _tail(_worker_log_path())
	return out


# 开工前清掉上一跑的产物。★ 删除**必须看返回值**(理由见 reconnect_probe 的同名函数:残留进程
# 攥着同名文件时删除会失败,而失败被忽略的后果是"新进程截断、残留进程按旧偏移续写" → 日志里
# 出现空洞与陈旧行,人会照着这些行做错误归因)。
func _clean() -> bool:
	var ok := true
	for who in ["c1", "c2", "c3"]:
		for suffix in ["result", "godotlog"]:
			var p := "user://%s%s.%s" % [PREFIX, who, suffix]
			if not FileAccess.file_exists(p):
				continue
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(p)) != OK:
				ok = false
				push_warning("PROBE: 删不掉上一跑的 %s —— 多半是上一跑的进程还活着" % p)
	return ok


# 观察者挂 `root`(不是本场景):大厅页 → `pvp_game` → 主菜单 → 再进 `pvp_game` 这一串换场
# 都不会把它带走。
func _run_client() -> void:
	var w: Node = load("res://tests/rejoin_watcher.gd").new()
	w.set("who", _role)
	w.set("lobby_port", LOBBY_PORT)
	print("PROBE[%s]: 客户端就绪" % _role)
	get_tree().root.add_child.call_deferred(w)
```

- [ ] **Step 3: 写 `tests/rejoin_watcher.gd`**

```gdscript
extends Node

# 回局真链路探针的**观察者**(每端一个,挂在 root 上;换场不会把它带走)。
# 三端各跑一条剧本:
#   c1 = actor:建房 → 开局 → 进 pvp_game → 到 PLAYING → **ESC + 点「回到主菜单」** →
#        主菜单点「回到对局」→ 回到**原局**。断言两条:
#          ① 回局后 `PvpSession.role` 与离开前**一致**(大厅把凭据里的 role 发对了);
#          ② **重新收到服务器广播**(PLAYING 的 `round_state` 计数严格增长)—— 这是"真的回到
#             那一局"的唯一客观证据:离场期间客户端断着、一条广播都收不到。
#        ★ 不拿 instance_id 做断言:路径乙**会重建场景**(诊断用快照),节点 ID 必然不同 ——
#          服务端那具身体确实没销毁(spec §3.2),但客户端**观测不到**它,写成断言就是伪断言。
#          服务端身体未销毁由 `reconnect_probe` 相①(路径甲,不重建场景)钉住。
#   c2 = 对手:点列表加入 → 进 pvp_game → 全程在线(它是"这一局还在"的见证)。
#   c3 = 第三人:**只连大厅**:①列表里看得见这个房(in_match=true)②加入被拒。
#        ★ ② 是用户点名的要求("C 可以看到 A 与 B 的房间,尽管无论在对战还是掉线 C 都不应该进去")
#          —— 服务端的 `join_room` 守卫由这一条在**真链路**上验一次。
# 失败时把结果写进 `user://rejoin_probe_<who>.result`(子进程 stdout 父进程看不到)。
#
# ★ 与 team_match_watcher 同款的两条纪律:
#   ① **先置位再入树**:大厅页 `_ready` 会 deferred 跑一次 `_request_list`,只有"已连同地址"
#      那一支会复用现有连接(否则它会 `NetBus.stop()` 并按默认端口重连)。
#   ② 页挂在**探针场景**下(不是本节点下):换场时它随探针场景一起被 free —— 那正是生产的形状。

const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 60.0      # 从挂页到"进 pvp_game 且到 PLAYING"
const PLAY_SETTLE := 3.0         # PLAYING 后静置(让快照跑起来,身体有个明确的位置读数)
const REJOIN_TIMEOUT := 30.0     # 按「回到对局」后等回到 pvp_game
const RESULT_WAIT := 40.0        # c3 等"一个不会来的 room_joined"的上限

var who := ""
var lobby_port := 29300

var _page: Node = null
var _game: Node = null
var _t := 0.0
var _phase := 0
var _phase_t := 0.0
var _done := false
var _fails: Array[String] = []
var _body_id_before := 0
var _playing_seen := false       # 已收到服务器广播的 PLAYING(state==1)
var _playing_count := 0          # PLAYING 广播的累计条数(回局后必须严格增长)
var _playing_at_leave := 0       # 离场那一刻的计数(回局后拿它比对)
var _role_before := 0            # 离场前的 role(回局后不许变)
var _joins := 0                  # c3:收到 room_joined 的次数
var _go_match := 0               # c3:收到 go_match 的次数
var _server_msgs: Array[String] = []
var _room_rows := -1             # c3:最近一次列表里"对局中"的行数
var _room_code := ""
# c2/c3 落盘后**保持在线**(见 _finish:裁判还要继续观察这一局),只有 c1(actor)自己退。
var hold_alive := false


func _ready() -> void:
	hold_alive = who != "c1"
	NetBus.local_room_created.connect(func(code: String) -> void:
		_room_code = code
		_log("建房成功:%s" % code))
	NetBus.local_room_joined.connect(func(_role: int) -> void:
		_joins += 1
		_log("收到 room_joined(第 %d 次)" % _joins))
	NetBus.local_go_match.connect(func(_role: int, port: int) -> void:
		_go_match += 1
		_log("收到 go_match(第 %d 次,port=%d)" % [_go_match, port]))
	NetBus.local_room_list.connect(_on_room_list)
	# ★ PLAYING 的判据取**服务器广播的 round_state**(state==1),不是本地 `_round_locked` 的
	#   默认值 —— 后者在第一条 round_state 到达**之前**就是 false,照它判会在刚进场景那一帧
	#   就"以为"开打了(`team_match_watcher` 用的是同一个读数)。
	NetBus.local_round_state.connect(func(data: Dictionary) -> void:
		if int(data.get("state", 0)) == 1:
			_playing_seen = true
			_playing_count += 1)
	NetBus.local_server_message.connect(func(t: String) -> void:
		_server_msgs.append(t)
		_log("server_message: %s" % t))
	multiplayer.connected_to_server.connect(_on_lobby_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_fail("连大厅失败(%s:%d)" % [LOBBY_ADDR, lobby_port]))
	NetBus.start_client(LOBBY_ADDR, lobby_port)


func _on_lobby_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", "BOT%d" % (1 if who == "c1" else (2 if who == "c2" else 3)))
	_attach_page.call_deferred()


func _attach_page() -> void:
	if _page != null:
		return
	var cs := get_tree().current_scene
	if cs == null:
		return
	_page = load("res://scenes/matchmaking.tscn").instantiate()
	# ★ 先置位再入树(理由见文件头)
	_page.set("_connected", true)
	_page.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(_page)
	_log("真大厅页已挂载")
	if who == "c1":
		_page.call("_on_create_pressed")
	elif who == "c2":
		_page.call("_on_refresh_pressed")     # 等列表到了再点加入
	else:
		_page.call("_on_refresh_pressed")


func _on_room_list(rooms: Array) -> void:
	if who != "c3":
		return
	var in_match := 0
	for r in rooms:
		if typeof(r) == TYPE_DICTIONARY and bool(r.get("in_match", false)):
			in_match += 1
			_room_code = str(r.get("code", ""))
			_rec("ROW code=%s in_match=1 names=%s" % [_room_code, str(r.get("names", []))])
	_room_rows = in_match
	if who == "c3" and in_match == 1 and _phase == 0:
		# 看见了 → 立刻试图进去(必须被拒)
		_phase = 1
		_phase_t = 0.0
		_page.call("_join_code", _room_code)


func _physics_process(delta: float) -> void:
	if _done:
		return
	_refresh_game()          # ★ 每帧重认对局场景(离场再进 = 一具**全新**的节点树)
	_t += delta
	_phase_t += delta
	match who:
		"c1":
			_tick_c1()
		"c2":
			_tick_c2()
		"c3":
			_tick_c3()


# 每帧重认对局场景。★ **绝不能缓存**：本端的剧本里游戏场景会连换三次
# (大厅 → pvp_game → 主菜单 → pvp_game),旧那具早被 `safe_change_scene` 退役掉,
# 对着已释放实例取字段会报 `Invalid access to property or key … on a base object of type
# 'previously freed'`(本仓实测踩过,见 team_match_watcher 文件头)。`_game` 为 null 表示
# "此刻不在对局里"(大厅页 / 主菜单 / 换场中间),各段剧本按它推进。
func _refresh_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_game(cs):
		_game = null
		return
	if cs.get("_local") == null:
		return     # 场景 `_ready` 还没跑完(局部玩家未就位)
	if _game != cs:
		_log("进入对局场景(role=%d)" % PvpSession.role)
	_game = cs


# 与 team_match_watcher._is_game 同款:按**脚本类型**认(名字会随场景改,类型不会)
func _is_game(n: Node) -> bool:
	return n is PvpMatchClient


func _find_rejoin_button(n: Node) -> Button:
	if n == null:
		return null
	if n is Button and n.name == "RejoinButton":
		return n
	for c in n.get_children():
		var b := _find_rejoin_button(c)
		if b != null:
			return b
	return null


# ── c1(actor)──
var _c1_sub := 0      # 0 建房/等开局 1 打一会 2 已按 ESC 回主菜单 3 已点「回到对局」
func _tick_c1() -> void:
	if _page == null or _phase_t > ENTER_TIMEOUT + REJOIN_TIMEOUT + RESULT_WAIT:
		_finish("c1 超时(阶段 %d)" % _c1_sub)
		return
	match _c1_sub:
		0:
			if _game != null:
				_c1_sub = 1
				_phase_t = 0.0
			return
		1:
			if _game != null and _playing_seen and _phase_t > PLAY_SETTLE:
				_body_id_before = int(_game.get("_local").get_instance_id())
				_playing_at_leave = _playing_count
				_role_before = int(PvpSession.role)
				_log("PLAYING 就位(role=%d,身体 instance_id=%d,PLAYING 计数=%d);按 ESC 回主菜单"
						% [_role_before, _body_id_before, _playing_at_leave])
				_esc_and_menu()
				_c1_sub = 2
				_phase_t = 0.0
			return
		2:
			# 等主菜单出现,点「回到对局」
			var btn := _find_rejoin_button(get_tree().current_scene)
			if btn == null:
				return
			_log("找到「回到对局」按钮 → 点它")
			btn.pressed.emit()
			_c1_sub = 3
			_phase_t = 0.0
			return
		3:
			if _game == null:
				return
			if not _playing_seen or _playing_count <= _playing_at_leave:
				return    # 还没重新收到服务器的广播
			_ok("c1 回到对局并进入 pvp_game")
			if int(PvpSession.role) != _role_before:
				_fail("c1 ★ 回局后 role 变了(%d → %d):大厅把凭据里的 role 发错了" %
						[_role_before, int(PvpSession.role)])
			else:
				_ok("c1 ★ 回局后 role 与离开前一致(%d)" % _role_before)
			# ★ 这一条才是"真的回到那一局"的证据:离场期间**没有任何** round_state 到达
			#   (客户端断着),回来之后又开始收 —— 计数必须**严格增长**。
			_ok("c1 ★ 回局后重新收到服务器广播(PLAYING 计数 %d → %d)" % [_playing_at_leave, _playing_count])
			_rec("BACK id_before=%d role=%d plays=%d→%d" % [_body_id_before, _role_before,
					_playing_at_leave, _playing_count])
			_finish("")
			return


func _esc_and_menu() -> void:
	var pm: Node = null
	for c in _game.get_children():
		if c is PauseMenu:
			pm = c
			break
	if pm == null:
		_fail("对局场景里没找到 PauseMenu")
		return
	# 真 ESC(理由见 team_match_watcher._esc_leave:keycode 与 physical_keycode 都要给)
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	pm.call("_unhandled_input", ev)
	_log("按 ESC 打开暂停菜单(opened=%s)→ 点「回 到 主 菜 单」" % str(bool(pm.get("_open"))))
	pm.call("go_menu")


# ── c2(对手)──
var _c2_joined := false
func _tick_c2() -> void:
	if _page == null:
		return
	if not _c2_joined and _room_code != "" and _page.get("_list_box").get_child_count() > 0:
		# 列表已到 → 点第一行(就是 c1 的房)
		for c in _page.get("_list_box").get_children():
			if c is Button:
				(c as Button).pressed.emit()
				_c2_joined = true
				_log("点了房间列表第一行加入")
				break
	if _game != null:
		_rec("IN_GAME")
		_finish("")


# ── c3(第三人)──
func _tick_c3() -> void:
	if _phase == 1 and _phase_t > RESULT_WAIT:
		# 等够了:这才是 c3 的结论时刻
		if _room_rows != 1:
			_fail("c3 ★ 没在列表里看到那个对局中的房(实得 %d 行)" % _room_rows)
		_ok("c3 ★ 第三人能看到对局中的房(%d 行,code=%s)" % [_room_rows, _room_code])
		if _joins != 0:
			_fail("c3 ★ 加入被拒失败:收到了 room_joined(%d 次)" % _joins)
		if _go_match != 0:
			_fail("c3 ★ 加入被拒失败:收到了 go_match(%d 次)" % _go_match)
		var refused := false
		for m in _server_msgs:
			if m.contains("房间已满") or m.contains("对局已开始") or m.contains("房间不存在"):
				refused = true
		if not refused:
			_fail("c3 ★ 没收到任何拒绝提示(server_message 实得 %s)" % str(_server_msgs))
		_ok("c3 ★ 加入被拒(无 room_joined / 无 go_match / 有拒绝提示)")
		_finish("")


# ── 结果与日志 ──
func _log(s: String) -> void:
	print("WATCHER[%s] t=%.1f %s" % [who, _t, s])


func _ok(msg: String) -> void:
	print("WATCHER[%s] OK " % who + msg)
	_rec("OK " + msg)


func _fail(msg: String) -> void:
	_fails.append(msg)
	print("WATCHER[%s] FAIL " % who + msg)


func _rec(line: String) -> void:
	var f := FileAccess.open("user://rejoin_probe_%s.result" % who, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://rejoin_probe_%s.result" % who, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
	f.close()


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if why != "" and _fails.is_empty():
		_fail(why)
	var head := "OK" if _fails.is_empty() else "FAIL(%d)" % _fails.size()
	var f := FileAccess.open("user://rejoin_probe_%s.result" % who, FileAccess.WRITE)
	if f != null:
		f.store_line(" %s" % head)
		for e in _fails:
			f.store_line("  - %s" % e)
		f.close()
	# ★★ **c2 / c3 落盘后不退出**(`hold_alive`):它们的结果只是"我这边的读数",而**对局必须继续
	#   活着** —— c2 是对手,它一退,worker 就把 role 2 送进宽限期(相① 的前提"这一局还在"就
	#   变了味);c3 虽然不在局里,留着也不花任何代价。真正的收尾是**裁判按 PID 杀**
	#   (`_kill_children`),子进程另有一条 `--quit-after` 兜底。
	#   c1 是 actor:它的剧本跑完就该退,退出不改变任何结论。
	if hold_alive:
		print("WATCHER[%s] 结果已落盘,保持在线等裁判收尾" % who)
		return
	get_tree().quit(0 if _fails.is_empty() else 1)
```

★★ **`_game` 是每帧重认的**（`_refresh_game()`，见上面那段代码）：本端的剧本里游戏场景会连换三次，**绝不能缓存一个已退役的实例** —— 本仓有 `Invalid access … previously freed` 的实测教训（`team_match_watcher` 文件头那条）。`_game == null` 就表示"此刻不在对局里"，各段剧本按它推进。

- [ ] **Step 4: 写 `tests/rejoin_probe.sh`**

```bash
#!/usr/bin/env bash
# 「回大厅后回局」的真链路端到端探针(三端:actor / 对手 / 第三人;详见 tests/rejoin_probe.gd 文件头)。
#
# 用法:  timeout 900 bash tests/rejoin_probe.sh
# 判据:  文本 `REJOIN PROBE: ALL-OK`(**不看退出码** —— 挂住时 --quit-after 到期仍 exit 0
#        且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
# 整跑量级:约 30~90 秒。
#
# ⚠ **跑前先确认没有别的 Godot 占着 7777** —— 本探针**不占 7777**(自当大厅,池外端口 29300;
#   worker 起投也拨到池外 29350),可本机上可能跑着用户自己的服务端。**本脚本绝不杀 7777 的
#   属主**(与 royale_soak_probe.sh 的"发现占用就 kill_port 7777"刻意不同)。
# ⚠ 本探针的真大厅会经**真 `WorkerLauncher`** 拉 worker,而那个端口池(7800~8299)与用户自己的
#   大厅**是同一个池** —— 故本跑要**由人看着跑**(别在别人开局的同时跑)。
set -u

# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
LOG="tests/rejoin_probe.log"

if netstat -ano 2>/dev/null | grep -qE "[:.]7777[[:space:]].*LISTENING"; then
  echo "[rejoin] 注意:7777 已被占用(大概是用户自己的服务端)。本探针不占 7777,**照跑不误、不会动它**。"
fi

echo "[rejoin] 起探针(大厅 29300,worker 起投 29350;整跑约 30~90 秒)"
echo "[rejoin] 若长时间无输出:看 user://rejoin_probe_c1.godotlog(子进程 stdout 父进程看不到)"
"$GODOT" --headless --path . --quit-after 36000 res://tests/rejoin_probe.tscn 2>&1 | tee "$LOG"
# ★ 取**探针进程自己**的退出码,不是 tee 的(管道最后一环恒 0,照它写会打印一个结构性恒真的数)
RC=${PIPESTATUS[0]}

echo "[rejoin] 清理本探针自己的两个端口(兜底;正常路径探针已按 PID 杀干净)"
kill_port 29300
kill_port 29350

echo
if grep -q "REJOIN PROBE: ALL-OK" "$LOG"; then
  echo "[rejoin] PASS —— 读数见 $LOG"
  exit 0
fi
echo "[rejoin] FAIL(退出码 $RC)—— 见 $LOG"
grep -nE "SCRIPT ERROR|Parse Error|FAIL|✗" "$LOG" | head -30
exit 1
```

- [ ] **Step 5: 跑（**让用户跑**；agent 不代跑）**

Run（**让用户跑**）：`timeout 900 bash tests/rejoin_probe.sh`
Expected: `REJOIN PROBE: ALL-OK`。失败时先看 `tests/rejoin_probe.log` 与 `user://rejoin_probe_c{1,2,3}.godotlog`。

- [ ] **Step 6: 反证（**让用户跑**，两条）**

1. 把 `scenes/lobby_page.gd` 的 `_claim_role_worker` 里那段 `if PvpSession.rejoin:` 分支**删掉**（让它永远走 `claim_role`）⇒ 再跑一次 ⇒ c1 的"回到对局"必须**红**（被 worker 当串线踢掉，卡在大厅页）。还原。
2. 把 `server/lobby_rooms.gd` 的 `team_join`/`royale_join`/`join_room` 里 `in_match` / `started` 那三处守卫**删掉** ⇒ c3 的"加入被拒"必须**红**。还原 → 复绿。

两段输出写进报告。

- [ ] **Step 7: 提交**

```bash
git add tests/rejoin_probe.gd tests/rejoin_probe.gd.uid tests/rejoin_probe.tscn \
  tests/rejoin_watcher.gd tests/rejoin_watcher.gd.uid tests/rejoin_probe.sh
git commit -m 'test(net): 回局真链路端到端探针(actor 离场再回局 + 第三人看得见进不去)'
```

---

## Task 14: `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`（「断线重连」一节 + 「3v3 团队模式」/「大乱斗」两节里与大厅房间寿命有关的那几句）

- [ ] **Step 1: 记录这几条（每条都是"后人会踩"的）**

1. **宽限期 = 60 秒（三模式统一）**，唯一入口 `GraceWindow.DEFAULT_SECONDS`；`pvp_match_client` 的重连预算读的就是它（同源，不用改）。★ **硬不变量**：三档 `*_PORT_REUSE_DELAY` **必须严格大于**宽限期（守卫 `grace_window_smoke` ⑧）。★ 并记：**测试预算**里凡按宽限期算出来的窗口（`reconnect_probe` 的 `GRACE_MIN/MAX/FINAL_TIMEOUT`、`team_match_watcher.OBSERVE_MAX`、`team_match_probe.RESULT_WAIT`）**必须同步重算**，否则症状是"一行 ALL-OK 都没有"，与真失败分不开。
2. **★ `in_match`（1v1 是 `started`）的房不再在"客户端转连 worker"那一刻被拆**；回收改由 `RoomManager._reclaim_finished_matches`（30s 梯）按 **worker 进程还在不在**判 —— 那是三种模式唯一的精确界。**兜底**仍是既有的 2h 超龄清扫（两条路径并存）。★ 这条同时是「C 看得见 A 与 B 的房间」的前提：**房的寿命与列表可见性是同一件事**。★ **可见性与拒绝入房是两半**（列表照列 + `join_room`/`royale_join`/`team_join` 的 `in_match`/`started` 守卫），改一半就是"看不见"或"进得去"。
3. **回局凭据表 `server/rejoin_registry.gd`**（`RejoinRegistry`）：token → `(code, role, worker_port, worker_pid, expires_at)`。★ 三个房类的 `tokens` 字段**已删除**（同一件事只留一处记录）。★ 判据是**纯函数** `decision()`；**TTL 只是表的 GC 上界**（1h），"这一局还在不在"由 `worker_pid` 的活性回答。★ `teardown_room` 里 `rejoin.drop_room(room.code)` 作废该房凭据。
4. **回局路径 = 复用 `go_match`**：`LobbyPage` 连大厅 → `rejoin_request(room_code, token)` → 大厅 `NetBus.reply(caller, "go_match", role, port)` → 客户端与首次进场**逐字同一条路**（转连 worker、等 `match_start`、进对局场景），**唯一分叉**是认领那一步走 `reclaim_role`（对局已开着，`claim_role` 会被 `_on_role_claimed` 当串线踢）。★ `_do_go_match` 里"只在收到新 token 时才覆盖"那一行是**承重**的：回局路上大厅不重发 `session_token`，无条件覆盖会把凭据抹成空串。
5. **入口**：主菜单 `RejoinButton`（`PvpSession.can_rejoin()` 为真才显示）是**唯一不调 `PvpSession.reset()` 的联机入口**。`PvpSession` 新增 `room_code` / `mode` / `rejoin` 三个字段（都有读者）+ `can_rejoin()` / `clear_rejoin()`。
6. **列表载荷新增 `in_match` 键**（三模式同名同义）；大厅侧把列表抽成了 `*_list_payload()` **纯构造**（理由：`NetBus.reply` 在无对端时静默跳过 ⇒ 列表内容不可观测 ⇒ 抽出来才可测）。
7. **守缺口照实登记**：`rejoin_lobby_probe` **观测不到放行路径的真实 `go_match` 发送**（无对端 ⇒ `NetBus.reply` 静默跳过）—— 那一条只由真链路探针 `rejoin_probe` 覆盖。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录阶段 2-B(房寿命/凭据表/回局复用 go_match/宽限期 60)'
```

---

## 自检记录

**spec 覆盖**：§3 第 1 条（房活过转连 + 替代回收）→ Task 6 + Task 7；§3 第 2 条（凭据表独立于房）→ Task 4 + Task 8；§3 第 3 条（`rejoin_request` + 复用 `go_match`）→ Task 9 + Task 10；§0 第 2 条（1v1 归还延迟 → 360）→ Task 2；用户追加的**宽限期三模式 60s** → Task 1（+ 连带 Task 3）；用户追加的**三模式可见性/拒绝入房** → Task 6（服务端两半）+ Task 12（界面）；**入口可达** → Task 11；真链路证据 → Task 13；文档 → Task 14。

**与 spec 的刻意偏离（两处，都已写进代码注释）**：

1. **回收判据不是"按宽限期收"，而是"worker 进程还在不在"**。spec 的原话是"`in_match` 的房不在 `on_peer_left` 里拆，改由 sweep 按宽限期收"。照字面做（开局后 `宽限期` 到点就收）会把房在**开打 60 秒后**拆掉 —— 于是"C 看得见"只延续 60 秒、而**一局打到中段掉线的玩家再也回不去**（回局依赖房记录与它持有的端口）。本计划改成按 **worker 进程存活**回收：它是"这一局结束了吗"的**精确**答案（三种模式的 worker 都在对局结束时自己退），且与模式无关（不必给三种模式各估一个"一局多久"）。既有的 2h 超龄清扫仍是兜底。
2. **`worker_pid` 进了凭据**（spec 给的形状是 `token → (code, role, worker_port, 到期时刻)`）。多一个 pid 是为了让**回局查询不需要房对象**就能回答"这一局还在不在"，也是上面第 1 条的判据来源。

**plan 未覆盖 / 已知边界（照实登记）**：

- **回局只在宽限期内真正成功**：宽限到期后 worker 会 `mark_disconnected`（大乱斗/3v3）或收场退进程（1v1），此时大厅仍可能放行（凭据还在、worker 还活着），客户端连过去会被 `_on_reclaim` 的判据②（"该 role 不在宽限期"）**踢连接**，表现为回到大厅页 + 一条失败提示。要在客户端侧提前拦（比如凭据带"断开时刻"）属于**另行评估** —— 本批不做。
- **`_sweep_stale_rooms` 的在局宽限仍是估的**（royale 取 `RoyaleHost.MATCH_TIME` 默认值、3v3 取 `TEAM_MATCH_ESTIMATE`），CLAUDE.md 早已登记这条边界；本批**不放宽**，因为真正的界（本局实际时长）只在 worker 里。
- **1v1 worker 在"一个 claim 都没有"时会一直挂着**（既有行为，`server/_process` 只给 royale/team 配了超时梯）：本批没有修它，但房与端口的泄漏被 2h 超龄清扫兜住（那一条会 `TEARDOWN_KILL` 连 worker 一起杀）。
- **端口池压力的数字**：占用 ≈ 一局 + 宽限 60 + 归还 360；3v3 最坏 ≈ 37 分钟。池子 500 个，本作量级无虞（算过，写进了 `worker_launcher.gd` 的注释）。
- **可见性只做了"看得见 + 进不去"**：spec §4 阶段 3 的**HUD 可见性**（局内「掉线中/重连中」提示）本批**不做** —— 回局这条路的可用性不依赖它（玩家在**主菜单**上看到那颗按钮就知道能回去），但它确实是"掉线时玩家不知道自己被宽限了"这个体验缺口的正解，独立成批。★ 这一条是**明确的范围裁量**，不是漏写。

**占位符扫描**：无 TBD / TODO；每个改代码的步骤都给了完整代码（含 Task 13 的观察者：`_refresh_game()` / `_is_game()` / `_find_rejoin_button()` 都是逐行可抄的实现，不是"照别的文件写"）。

**类型一致性**：`RejoinRegistry.decision(entry, code, worker_alive) -> String` 在 Task 4 定义、Task 9 按同一签名调用；`WorkerLauncher.pid_of/pid_alive` 在 Task 5 定义、Task 7/9 按同一签名调用；`LobbyRooms.rejoin` 在 Task 8 定义、Task 7（`prune`）与 Task 9（`lookup`/`drop_token`）按同一名字用；`LobbyRooms.freeze_roster` / `*_list_payload()` 在 Task 6 定义并被同任务与 Task 7 的探针调用；`PvpSession.{room_code, mode, rejoin, can_rejoin, clear_rejoin}` 在 Task 10 定义，Task 11（按钮）与 Task 12 按同一名字用。

**跑法分工**：agent 可跑 = `--import`、全部 `-s` 冒烟、`tests/rejoin_lobby_probe.tscn`、以及各页面的 `--quit-after 120` 启动自检；**用户跑** = `tests/reconnect_probe.tscn`（池外端口，但耗时长且按 PID 杀子进程）、`tests/rejoin_probe.sh`（真大厅 + 真 worker，与用户自己的大厅**共用一个 worker 端口池**）、以及一切占 7777 的既有脚本。
