# 回大厅后回局【阶段 2-B】实施计划(+ 三模式宽限期改 60s)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> ★★ **Tasks 1–5 已执行完毕(2026-09-21 同日),它们的正文是「当时写的」,不是现状。**
> 执行时它们各自**修掉了本计划自身的若干缺陷**(简报里拦不住自己要拦的错的守卫、编译不过的冒烟、自相矛盾的用例、
> 一个会误伤同号房的归键),并有多处**按实测偏离了正文的写法**。
> **准确记录 = `.superpowers/sdd/progress-plan3.md`**(逐任务:提交号 + 实测 + 裁定)。
> 本文件里 **Tasks 1–5 的正文只作历史留档** —— 核对现状请看那份台账与代码,别照着它们反推。
> **Tasks 6–9 尚未执行**,已按后续的**用户裁定与实测**修订:入口由按钮改为**列表里点自己那间房**(见下「架构」第 3 条
> 与 Task 7);`drop_room` 改名 `drop_port`(Task 3/4/9);探针计数改按实得的 **31** 起算(Task 6);
> 私密房玩家的回局入口 = **乙:接受"回不去"**(2026-09-21 用户裁定;只登记不写代码,见 Task 7 末尾)。

**Goal:** 玩家按 ESC 回主菜单之后,**能凭手里的凭据回到原来那一局**(不重开对局、不丢世界状态)。附带:宽限期 30s → **60s**(三模式统一),以及随之必须复核的测试预算。

**Architecture:**

1. **回局凭据独立成表**。token 原先存在 `Room.tokens` / `RoyaleRoom.tokens` / `TeamRoom.tokens`,随 `teardown_room` 一起消失。新立一张 `server/rejoin_registry.gd`(`class_name RejoinRegistry`,纯逻辑、不读时钟、`-s` 可测),三个房类的 `tokens` 字段**整体删除**(同一件事不留第二份记录)。凭据里带 `worker_pid`:回局查询因此**不需要房对象**,答案也是精确的。
2. **`rejoin_request(room_code, token)` + 复用 `go_match`**。大厅判据抽成纯函数 `RejoinRegistry.decision()`(`""` = 放行),三种拒绝理由(凭据失效 / 房间号不符 / 对局已结束)各自可测。应答走**原 `go_match`** —— 于是客户端那条"连 worker → 认领 role → 进对局场景"的路与首次进场**逐字同一条**,唯一分叉是认领那一步要走 `reclaim_role`(对局已经开着,`claim_role` 会被 worker 当串线踢掉)。
3. **入口**:玩家**自己在普通房间列表里找到自己那间房、点它**。对局中的房那一行对**持有有效凭据的本人**
   变成**可点**(点了走回局),对其他人照旧"看得见、点不动"(大厅 `join_room` / `*_join` 那三条守卫仍是那一半的保证)。
   ★ **不设**「回到对局」按钮 —— 用户裁定原话:「不能有回到对局按钮」「玩家必须自己找到对应的房间」。
   ★ 私人房**不进列表**(`royale_list_payload` / `team_list_payload` 跳过非公开房)⇒ **私密房玩家没有回局入口** —— 用户裁定 **乙:接受"回不去"**(2026-09-21,只登记不写代码;甲候选留档在 Task 7 末尾),
   三条候选写在 **Task 7 末尾**,由控制者裁定后回填。

★ **「对局中的房看得见、进不去」不在本计划里** —— 那是**前置计划**(见下)。本计划**只**做"谁能回到那一局"。

**Tech Stack:** Godot 4.7.1 GDScript;`NetBus`(客户端 ↔ worker/大厅的 RPC 通道,**方法表一个字不动**,扩展一律走 `NetBusExt`);`-s` 冒烟 + 场景探针 + 真链路多进程探针;判据一律 grep 文本。

---

## ★★ 前置:显示方案必须先落地(本计划从它那里消费什么)

本计划**依赖** `docs/superpowers/plans/2026-09-21-in-progress-room-visibility.md`(下称**显示方案**),它**必须先合入**。理由不是"顺序好看":路径乙的本质是"玩家离开大厅之后**那一局还在、而且房记录还活着**",而"房活过客户端转连 + 谁在打谁的回收判据"正是显示方案交付的东西。**下面的名字/签名/字段逐字来自显示方案 —— 没看过那份计划的人照这张表用就行,不要在本计划里重造任何一个。**

| 消费什么 | 在哪 | 形状 / 签名 |
|---|---|---|
| worker 进程活性(唯一精确的"这一局还在不在"判据) | `server/worker_launcher.gd` | `pid_of(port: int) -> int`(未登记 / 已归还 ⇒ 0);`static pid_alive(pid: int) -> bool`(`pid <= 0` ⇒ false) |
| 房记录上的 pid | `LobbyRooms.Room` / `RoyaleRoom` / `TeamRoom` | `var worker_pid: int` —— ★ **已由 `RoomManager` 在 spawn 成功后登记,本计划不再登记它** |
| 房记录上的冻结名单 | 同上 | `var roster: Array`(`[{role:int, name:String}]`)+ `LobbyRooms.freeze_roster(room) -> void` |
| 房**活过**客户端转连 | `LobbyRooms.on_peer_left` / `royale_leave` / `team_leave` | in-match(`started` / `in_match`)的房在这些路径上**不拆** |
| 对局结束即回收 | `server/room_manager.gd` | `const MATCH_SWEEP_INTERVAL := 30.0`、`_reclaim_finished_matches()`(本计划**只在它开头加一行 GC**)、`static _match_over(port, pid)` |
| 大厅侧的场景探针 | `tests/lobby_visibility_probe.tscn` + `.gd` | 真 `RoomManager` + 三张注册表 + 关掉的梯;`EXPECTED_CHECKS` 计数(收尾比期望条数)★ 相⑤⑥**已落地**(计数 27 → **31**:比当时写的多一条 —— 走信号验 `reconnect` 接线的那条);本计划余下的**相⑦**再把计数抬到 **37** |
| 拒绝入房的守卫与统一文案 | `server/lobby_rooms.gd` | `join_room` / `royale_join` / `team_join` 的 `started` / `in_match` 守卫 + 「该房间的对局已进行中,无法加入」 |

★ **反向纪律**:本计划**不得**再写一份 `pid_of` / `pid_alive` / `freeze_roster` / `*_list_payload` / `_reclaim_finished_matches`,也**不得**动显示方案的列表载荷与页面渲染。
★ **一处例外,写清楚理由**:显示方案**保留**了三个房类的 `tokens` 字段(它不需要它,也就没删);**本计划删**它(Task 4),因为它的替代品正是本计划的 `RejoinRegistry`。

## Global Constraints

- ★★ **另一个会话正在主工作树(`E:\Workspace\godot\the-cyancular-ruins`)的 `main` 上并发开发**。本计划的一切都在 **worktree `E:\Workspace\godot\the-cyancular-ruins\.claude\worktrees\3v3-fixes`**(分支 `feat/3v3-fixes`)里做。**绝不 `cd` 到主仓库根、绝不对它做 git 操作。**
- ★ **Bash 工具在本 worktree 里会被 git 守卫误伤** ⇒ **用 PowerShell 工具**跑 Godot。console 版路径:`D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe`。
- **测试由用户自己跑**(本仓默认)。agent 可跑:`--import`、`-s` 冒烟、**不占 7777 且不占 worker 端口池 (7800~8299)** 的探针(`tests/lobby_visibility_probe.tscn`)。**需要用户跑**:一切碰 7777 的(`tests/pvp_room_smoke.sh` / `tests/pvp_match_smoke.sh` / `tests/team_match_probe.sh` / `tests/royale_soak_probe.sh` / `royale_probe.sh` / `pvp_reconcile_smoke.sh` / `pvp_twin_smoke.sh`),以及本计划新加的 `tests/rejoin_probe.sh`(它**不占 7777**,但它的真大厅会从 worker 端口池里发端口 —— 与用户自己的大厅同池,必须由人看着跑)。
- **颜色只在 `ui/ui_factory.gd` 定义**;字号只用 **16 的倍数**;HUD 底板那套透明深底的数值纪律见 CLAUDE.md(本计划**不改**任何底板与版式常量)。
- ★ **`NetBus` 的方法表一个字不动**(改它会让与原版服务端的 RPC 全部失联)。本批新增的两条 RPC(`rejoin_request` / `rejoin_denied`)全在 `NetBusExt`。
- ★ **定向发送前一律先判活**(`NetBus.reply` / `NetBus.is_peer_live`)。大厅里 `NetBusExt` 的定向发送也要显式判一次(`royale_list` 是先例)。
- ★★ **判据一律是文本**(`ALL-OK` / 探针自己的串),**不看退出码**。而本仓**实测**过:`ALL-OK` 只证明"没有任何一条断言失败",**不证明"该跑的断言都跑过"** —— 出错在 helper / lambda 里时调用方照常继续、verdict 照打(完整表述在 `tests/lib/probe_base.gd` 文件头)。**因此凡"这条守卫真的能咬住吗"的地方,计划里都要求做一次变异反证**(注入缺陷 ⇒ 该条断言必须红 ⇒ 还原 ⇒ 复绿),两段输出都写进报告。★ 追加到显示方案那个探针里的相,必须**同步抬 `EXPECTED_CHECKS`**(那个常量就是这条纪律的落点)。
- ★ **场景探针的 `--quit-after` 逐个按预算给,不许照抄"统一 3600"**:本仓已经踩过 —— `tests/brawl_rollback_probe.tscn` 用 3600 **跑不完**(22 趟 × 368 tick ≈ 8100 物理帧),安全网耗尽时进程 **exit 0、一行 `ALL-OK` 都没有**,在批量里被读成红(实测给它 30000 即绿,约 135s)。本计划新加的真链路探针(`tests/rejoin_probe.tscn`,Task 8)与它追加到显示方案探针里的相,各自的取值都在对应任务里**写清推导**。
- ★ **新建 `.gd` 文件后跑 `--import`**(刷全局类缓存),并把 `.uid` 一起 `git add`。
- 提交信息用**单引号**或 `git commit -F 文件`,**不带任何 Claude/AI 署名行**;提交后回读一遍。每次 `git add` 只加本任务点名的文件。
- 工作区有未跟踪的 `_crashtest/` 与 `.superpowers/`(后者自带 `.gitignore`),**不要动**。
- 本计划**不改** worker 侧(`server/server_main.gd` / `MatchHost` / `TeamHost` / `RoyaleHost` / `GraceWindow` 的三个动作枚举),**不改** `NetBus`,`不改`显示方案交付的任何东西(唯一例外 = Task 4 往 `_reclaim_finished_matches` 开头加一行 GC,理由写在那一处)。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `core/net/grace_window.gd` | 修改 | `DEFAULT_SECONDS` 30 → **60**(+ 把端口不变量的**新口径**写进注释) |
| `server/worker_launcher.gd` | 修改 | **只改注释**:三档 `*_PORT_REUSE_DELAY` 的说明订正到新口径(数值不动) |
| `server/rejoin_registry.gd` + `.uid` | **新建** | 回局凭据表(纯逻辑、不读时钟、`-s` 可测)+ 纯判据 `decision()` |
| `server/lobby_rooms.gd` | 修改 | 三个房类:删 `tokens`;加 `var rejoin := RejoinRegistry.new()`;`teardown_room` 里 **`rejoin.drop_port(port)`**(★ 归键是 **worker 端口**,不是房间号 —— 落地时按实测改的,理由见 Task 4 Step 3 的 ★★ 段) |
| `server/room_manager.gd` | 修改 | 四个 spawn 点:token 收进 `granted`、spawn 成功后 `_grant_rejoin`;`_reclaim_finished_matches` 开头加一行凭据 GC |
| `core/net/net_bus_ext.gd` | 修改 | 两条 RPC(`rejoin_request` any_peer / `rejoin_denied` authority)+ 两个信号 |
| `core/net/pvp_session.gd` | 修改 | `room_code` / `rejoin` 两个字段 + `can_rejoin()` / **`can_rejoin_to(code)`** / `clear_rejoin()`;`reset()` 一起清。★ **`mode` 已删**(它的唯一读者是那颗被取消的按钮 —— 没读者的字段本仓不立) |
| `scenes/lobby_page.gd` | 修改 | 回局支路(在**已连着大厅**的页上发 `rejoin_request`)、`try_rejoin_row(code)`(行被按下时的"这是我的房吗"那一问)、`_claim_role_worker` 的 reclaim 分叉、`_do_go_match` 的 token 保留、回局超时梯 |
| `scenes/matchmaking.gd` / `royale_lobby.gd` / `team_lobby.gd` | 修改 | 记 `room_code`;`_on_room_list` 里**自己那间对局中的房改成可点**(先问"是不是我的房 + 凭据还在",**再**轮到"对局中即 disabled");`_process` 第一行加回局超时梯 |
| `scenes/main_menu.gd` | **不改** | ★ 原「回到对局」按钮**已取消**(用户裁定:不能有回到对局按钮)⇒ 入口改为列表里自己那间房,**本文件一个字不动** |
| `tests/grace_window_smoke.gd` | 修改 | 钉 `DEFAULT_SECONDS == 60` + 「归还延迟 > 宽限期」这条**次要 belt**(口径写在注释里) |
| `tests/reconnect_smoke.gd` | 修改 | 两条新 RPC 的节点归属/注解(**Task 5 已落地**)+ `PvpSession` 的字段与 `reset()`(Task 6) |
| `tests/reconnect_probe.gd` | 修改 | 时间预算随宽限期 60 重算(`GRACE_MIN/MAX`、`FINAL_TIMEOUT`、子进程兜底) |
| `tests/team_match_watcher.gd` / `tests/team_match_probe.gd` | 修改 | 相⑤ 观察窗与 `RESULT_WAIT` 按同一口径重算 |
| `tests/rejoin_registry_smoke.gd` + `.uid` | **新建** | `-s`:凭据表 + 判据(三种拒绝 + 放行)+ TTL 与宽限期的跨文件不变量 |
| `tests/lobby_visibility_probe.gd`(显示方案交的) | 修改 | 追加相⑦(`EXPECTED_CHECKS` **31 → 37** —— 31 是相⑤⑥ 落地后的实得值,见上表) |
| `tests/rejoin_probe.tscn` + `.gd` + `.uid` + `tests/rejoin_watcher.gd` + `.uid` + `tests/rejoin_probe.sh` | **新建** | **真链路**端到端回局探针(真大厅 + 真 worker + 3 个真客户端;**用户跑**)。★ 观察者**没有 `.tscn`**:它由探针 `load(...).new()` 挂到 `root` 上(与 `reconnect_watcher` / `team_match_watcher` 同款) |
| `CLAUDE.md` | 修改 | 记录 2-B 的纪律 + 宽限期 60 的连带 |

## 契约(全计划共用)

```
# 回局凭据(RejoinRegistry 的一条)
token(String) -> { "code": String, "role": int, "worker_port": int,
                   "worker_pid": int, "expires_at": int(ms) }

# rejoin_request(room_code, token) 的三条出口
放行   → NetBus.reply(caller, "go_match", role, worker_port)      # 与首次进场同一条 RPC
拒绝   → NetBusExt.rpc_id(caller, "rejoin_denied", reason)        # reason 是给玩家看的一句话

# 本计划对显示方案的**唯一**改动
server/room_manager.gd 的 _reclaim_finished_matches() 首行加一句凭据 GC:
    lobby.rejoin.prune(Time.get_ticks_msec())
```

---

## Task 1: 宽限期 30 → **60** 秒 + 重述端口不变量的口径

**Files:**
- Modify: `core/net/grace_window.gd`(常量在 `:15`)
- Modify: `tests/grace_window_smoke.gd`(追加 ⑧)

**Interfaces:**
- Produces: `GraceWindow.DEFAULT_SECONDS == 60.0`(唯一入口;`scenes/pvp_match_client.gd` 的重连重试预算读的就是它)

- [ ] **Step 1: 先加冒烟断言(此时必红)**

在 `tests/grace_window_smoke.gd` 的 ⑦ 那一块(`_check(G.ACTION_REMOVE != G.ACTION_TEARDOWN, …)`)之后、`if _fail == 0:` **之前**追加:

```gdscript
	# ── ⑧ 宽限期时长 + 端口归还延迟的**次要 belt**(2026-09-21,阶段 2-B)──
	# ★ 为什么钉时长:重连的重试预算直接读这个常量(`scenes/pvp_match_client.gd` 的
	#   `_on_reconnect_retry_tick` 第一条判据),单一来源不会漂;但**测试预算**是按它算出来的
	#   窗口(`reconnect_probe` 的 GRACE_MIN/MAX/FINAL_TIMEOUT、`team_match_watcher.OBSERVE_MAX`、
	#   `team_match_probe.RESULT_WAIT`),那些不会自己跟着动 → 症状是"一行 ALL-OK 都没有"
	#   (安全网先耗尽),与真失败长得一模一样。故在这里钉住这个数。
	_check(absf(G.DEFAULT_SECONDS - 60.0) < 0.001,
			"宽限期应为 60.0 秒(用户裁定:1v1 / 3v3 / 大乱斗三模式统一)。实得 %.1f" % G.DEFAULT_SECONDS)
	# ★★ 下面这条不等式**已经不是承重的那条了**(2026-09-21,显示方案落地后):
	#   承重的换成了「**worker 进程活着 ⇒ 房对象与它占的端口都还在**」—— 房活到 worker 退出,
	#   而端口只在 `teardown_room` 里归还,所以宽限期内的客户端手里那个端口一定还有效,
	#   **与延迟常量的取值无关**。真正的"这个端口还是不是我的局"由凭据里的 `worker_pid`
	#   精确回答(`RejoinRegistry.decision` 的 worker_alive 入参),不再是定时估的。
	#   保留这条 belt 的理由:它拦不住真正的病,但能在"有人把某个延迟改成荒谬的小数"时
	#   当场响一声 —— ★ 它**必须**写在注释里说明自己是 belt,否则后代会把它当承重件去优化。
	var W: GDScript = load("res://server/worker_launcher.gd")
	# ★ 空载守卫:load 失败还往下走会抛错,而 -s 抛错走不到 quit() → 进程永久挂起
	if W == null:
		print("GRACE_WINDOW FAILED: 找不到 server/worker_launcher.gd(归还延迟的 belt 无从校验)")
		quit(1)
		return
	var delays := {
		"WORKER_PORT_REUSE_DELAY(1v1)": float(W.WORKER_PORT_REUSE_DELAY),
		"ROYALE_PORT_REUSE_DELAY(大乱斗)": float(W.ROYALE_PORT_REUSE_DELAY),
		"TEAM_PORT_REUSE_DELAY(3v3)": float(W.TEAM_PORT_REUSE_DELAY),
	}
	for k in delays:
		_check(float(delays[k]) > float(G.DEFAULT_SECONDS),
				"★ %s = %.0f 应大于宽限期 %.0f(belt:worker 退出后别立刻把端口发出去)"
				% [k, delays[k], G.DEFAULT_SECONDS])
```

- [ ] **Step 2: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW FAILED: 1`(只有"宽限期应为 60.0"那一条红;三条不等式此时都还成立,因为 120/360/360 都 > 60)。

- [ ] **Step 3: 改常量 + 把新口径写进注释**

把 `core/net/grace_window.gd:15` 那一行:

```gdscript
const DEFAULT_SECONDS := 30.0   # ★ 宽限期时长的唯一入口(改时长只改这里)
```

换成:

```gdscript
# ★ 宽限期时长的唯一入口(改时长只改这里)。
# ★★ 2026-09-21:30 → **60**(用户裁定:1v1 / 3v3 / 大乱斗三个模式统一,不再分档)。
#   改这一个数会同时动**两处**,改之前两处一起看:
#     ① `scenes/pvp_match_client.gd` 的重连重试预算(`_on_reconnect_retry_tick` 的第一条判据)
#        读的就是本常量 —— 单一来源,不会漂;60s 下 `RECONNECT_RETRY_MS`(2s)与
#        `RECONNECT_ATTEMPT_TIMEOUT_MS`(5s)不变,一次闪断里的重试次数由 ~15 变 ~30,
#        是"更从容"而不是行为变化。
#     ② **测试预算**:凡按"宽限期多久"算出来的窗口都要重算 —— `tests/reconnect_probe.gd`
#        的 `GRACE_MIN/MAX` 与 `FINAL_TIMEOUT`、`tests/team_match_watcher.gd` 的 `OBSERVE_MAX`、
#        `tests/team_match_probe.gd` 的 `RESULT_WAIT`(它的头部注释要求**逐项求和**算,别凭印象)。
#        这三处是 Task 2。
# ★ 端口归还延迟(`WorkerLauncher` 的三个 `*_PORT_REUSE_DELAY`)**不再与本值绑定**:
#   承重的是"worker 进程活着 ⇒ 房与它占的端口都还在"(房活到 worker 退出,见
#   `RoomManager._reclaim_finished_matches`)。守卫只留一条 belt 形式的宽松下界
#   (`tests/grace_window_smoke` ⑧),口径写在那一处。
const DEFAULT_SECONDS := 60.0
```

- [ ] **Step 4: 跑冒烟确认全绿**

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW OK`。

- [ ] **Step 5: 变异反证(证明 ⑧ 真的咬得住)**

把 `DEFAULT_SECONDS` 临时改回 `30.0` ⇒ 跑冒烟 ⇒ 那条"宽限期应为 60.0"必须**变红** ⇒ **逐字还原** ⇒ 复绿。两段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add core/net/grace_window.gd tests/grace_window_smoke.gd
git commit -m 'feat(net): 宽限期 30 → 60 秒(三模式统一)+ 端口不变量改述为 belt'
```

---

## Task 2: 宽限期 60 牵动的**测试预算**全部重算 + 端口归还延迟的注释订正

**Files:**
- Modify: `tests/reconnect_probe.gd`(`:7,:88,:108,:113,:114,:329` 一带)
- Modify: `tests/team_match_watcher.gd`(`:28,:55`)
- Modify: `tests/team_match_probe.gd`(`RESULT_WAIT` 及其头部推导)
- Modify: `scenes/pvp_match_client.gd`(把注释里写死的"30 秒"订正成"不写死数字")
- Modify: `server/worker_launcher.gd`(**只改注释**,三个常量数值不动)

**Interfaces:**
- Consumes: Task 1 的 60s
- Produces: 三处窗口自洽(都不撞自己的安全网);`worker_launcher.gd` 的注释与新的承重事实一致

★ **这一步不能省**:这三处都是**按宽限期算出来的窗口**,不重算的话症状是"探针一行 `ALL-OK` 都没有"(安全网先耗尽),而它长得跟真失败一模一样 —— 本仓已经为此误判过至少两次。

- [ ] **Step 1: `tests/reconnect_probe.gd`**

| 常量 | 旧 | 新 | 为什么 |
|---|---|---|---|
| `GRACE_MIN` | 29.0 | **59.0** | 相④ 判"宽限期到点耗时"(`_expire_graces` 每秒轮询 + 采样粒度) |
| `GRACE_MAX` | 36.0 | **68.0** | 同上的上界,给负载留余量 |
| `FINAL_TIMEOUT` | 58.0 | **118.0** | 整跑从 ~42s 变成 ~72s,收工上限必须大于它 |
| `CHILD_QUIT_AFTER` | 9000 | **18000** | 子进程兜底(原 150s)现在贴着整跑长度了,翻倍留余量 |

同时把 `:7`、`:88` 两处注释里的"跑满一个 30s 宽限期 / 整跑 ~42s"改成"60s / ~72s",`:329` 那句 `(GraceWindow.DEFAULT_SECONDS=30)` 改成 `=60`。顶层 `--quit-after 14400`(240s)**保持不动**(240 > 118 + 子进程收尾余量)。

★ `tests/reconnect_probe.tscn` 的跑法注释一并订正(它写在 `.gd` 文件头里,改 `.gd` 即可)。

- [ ] **Step 2: `tests/team_match_watcher.gd`**

```gdscript
const OBSERVE_MAX := 110.0       # 相⑤ 观察窗(宽限期 60s + 余量;★ 改宽限期必须重算这里)
```

并把 `:28` 那句"两条都要等宽限期(30s)到点才成立 —— 观察窗按它定,见 OBSERVE_MAX"改成 60s。

- [ ] **Step 3: `tests/team_match_probe.gd` 的 `RESULT_WAIT`**

按该文件自己的纪律("**逐项按 watcher 的常量求和算出来**……别凭印象写")重算,并把**推导过程写进注释**:

```
  进局 ~5s + SETTLE 1.2 + RENDEZVOUS_MAX 100 + BRAWL_MAX 210 + 换局 SETTLE 1.2
  + OBSERVE_MAX 110 + PEER_WAIT 120 ≈ 547.4s;
  进局那一档的硬上限是 ENTER_TIMEOUT **90s**(不是 5s),最坏 ≈ 632.4s ⇒ 取 680 兜住两种走法。
```

```gdscript
const RESULT_WAIT := 680.0
```

`FINAL_TIMEOUT`(780.0)与 `CHILD_QUIT_AFTER`(54000 ≈ 900s)都仍大于 680,**不动**;但要在注释里点明"`RESULT_WAIT` 一旦超过 780 就必须同步抬 `FINAL_TIMEOUT`"。

- [ ] **Step 4: `scenes/pvp_match_client.gd` 的注释订正(只动注释)**

文件里所有把宽限期写死成"30 秒"的注释改成"宽限期(`GraceWindow.DEFAULT_SECONDS`)秒",**不再写数字**(下次改时长就不会再有这句漂):`_on_reconnect_retry_tick` 上方那条、`_retry_connect` 里"长于 30s 的宽限期""而不是设计的 30 秒"、`_begin_reconnect` 上方的"掉线那 30 秒里服务器照跑"与"30 秒预算的起算点"、`_on_resumed` 里"世界在掉线那 30 秒里变过"。★ **判据取的是 `GraceWindow.DEFAULT_SECONDS` 本身**,不是这些数字 —— 数字只是读起来方便,写错不报错,故改成"不写死"。

- [ ] **Step 5: `server/worker_launcher.gd` 的三段注释订正到新口径(数值一个都不改)**

`WORKER_PORT_REUSE_DELAY`(`:31`)连同它上面那段"2026-09-17:30 → 120"的说明整段替换成:

```gdscript
# ★★ 端口归还延迟的**职责变了**(2026-09-21,显示方案落地后),但**取值没动**:
#   今天承重的**不是**这个延迟,而是「**worker 进程活着 ⇒ 房对象与它占的端口都还在**」——
#   房不再在"客户端转连 worker"那一刻被拆,它活到 worker 退出
#   (`RoomManager._reclaim_finished_matches`),而端口只在 `teardown_room` 里归还。
#   于是宽限期一定落在 worker 的存活期内(大乱斗/3v3 的 worker 判据里明确要求
#   `_grace.size() == 0` 才退),**宽限期内重连的客户端手里那个端口一定还有效**,
#   与这个常量取多少无关。回局侧"这个端口还是不是我的局"另由凭据里的 `worker_pid`
#   精确回答(`RejoinRegistry.decision` 的 worker_alive 入参)。
# ★ 那本常量现在管什么:只兜「worker 刚退出、别立刻把它的端口发给新 worker」这一小段
#   (给进程收尾与 UDP socket 释放留时间)。30 → 120 的历史教训(30 == 30 是**相等**而不是
#   "短于",相等同样不安全)留档在此,但那条不等式的**承重地位**已由上面那段取代
#   —— 守卫只剩 `tests/grace_window_smoke` ⑧ 的一条 belt。
const WORKER_PORT_REUSE_DELAY := 120.0
```

`ROYALE_PORT_REUSE_DELAY`(`:38`)的注释里那句"已知边界:房主可把一局配到 30 分钟,此时本延迟短于一局"**保留**(它照实登记了 `_sweep_stale_rooms` 那条估值的界),但把"端口可能在旧 worker 还在跑时就被复用"改成:

```gdscript
# ★ 已知边界(照实登记,本次不放宽):房主可用建房页把一局配到 30 分钟。★ 现在这条延迟
#   **不再是**"端口会不会被提前复用"的界了(房活到 worker 退出 ⇒ 端口一直被占着)——
#   但 `_sweep_stale_rooms` 的在局宽限**仍是**按默认时长估的,那一处的边界照旧,见该函数注释。
const ROYALE_PORT_REUSE_DELAY := 360.0
```

`TEAM_PORT_REUSE_DELAY`(`:42`)的注释里那句"计时从房间拆除(≈开局)起算,不是从局内断线起算"**已经过时**(房现在活到对局结束才拆)整段换成:

```gdscript
# 3v3 worker 的端口归还延迟:一局最长 = 三局两胜 × 9 杀(比 1v1 长得多),与大乱斗同档。
# ★ 2026-09-21 起,"计时起点"这句话不再适用:房只在**对局结束**(worker 退出)后被拆,
#   所以本值只兜"worker 刚退"那一小段(与另两档同一条职责)。
# ★ 别把它单独并回一个更小的数:三档一起动、一起复核(理由见 WORKER_PORT_REUSE_DELAY 上方)。
const TEAM_PORT_REUSE_DELAY := 360.0
```

- [ ] **Step 6: 自检(本轮只跑不占端口的)**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/grace_window_smoke.gd` → `GRACE_WINDOW OK`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd` → `SMOKE_ROOM_SWEEP OK: …`

- [ ] **Step 7: 提交**

```bash
git add tests/reconnect_probe.gd tests/team_match_watcher.gd tests/team_match_probe.gd \
  scenes/pvp_match_client.gd server/worker_launcher.gd
git commit -m 'test: 宽限期 60 之后重算三处窗口;端口归还延迟的注释订正到新口径(取值不动)'
```

★ **让用户跑**(它耗时且按 PID 杀子进程):`timeout 900 "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn` → `RECONNECT PROBE: ALL-OK`(整跑约 72s)。★ 跑前确认没有别的 godot 在跑(探针用池外端口,不冲突,但**不要杀用户的大厅**)。

---

## Task 3: `RejoinRegistry`(回局凭据表)+ `-s` 冒烟

**Files:**
- Create: `server/rejoin_registry.gd` + `.uid`
- Create: `tests/rejoin_registry_smoke.gd` + `.uid`

**Interfaces:**
- Consumes: `GraceWindow.DEFAULT_SECONDS`(Task 1;用于一条跨文件不变量)
- Produces(Task 4/5/6 都按这个签名用):
  - `RejoinRegistry.grant(token: String, code: String, role: int, worker_port: int, worker_pid: int, now_ms: int) -> void`
  - `RejoinRegistry.lookup(token: String, now_ms: int) -> Dictionary`(过期 ⇒ `{}`;**不改表**)
  - `RejoinRegistry.decision(entry: Dictionary, code: String, worker_alive: bool) -> String`(**静态纯函数**;`""` = 放行)
  - `RejoinRegistry.drop_token(token) -> void` / **`drop_port(worker_port) -> int`** / `prune(now_ms) -> int` / `size() -> int`
    ★ **归键是 worker 端口,不是房间号**(落地时按 Task 5 的实证改名):三张注册表共享同一个 4 位房号空间,
      按 code 作废会**一次清掉同号另一间房的凭据**(实测 2 份 vs 1 份,且一行日志都没有)。守卫 `tests/rejoin_keying_probe.tscn`。
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
	var G: GDScript = load("res://core/net/grace_window.gd")
	if G == null:
		print("REJOIN REGISTRY: FAIL(加载 grace_window.gd 失败)")
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

	# ── ②b 跨文件不变量:凭据的 TTL 必须**不短于**宽限期 ──
	# ★ 为什么这条要在这里钉:宽限期内玩家手里那份凭据必须是有效的。TTL 短于宽限期会让一个
	#   **还在宽限期里**的玩家被大厅以「凭据已失效」拒掉,而那条拒绝与"对局真的结束了"
	#   在日志与提示上一模一样(玩家与排查者都会读成"这局没了")。
	if float(S.TOKEN_TTL_SECONDS) < float(G.DEFAULT_SECONDS):
		fails.append("★ 凭据 TTL(%.0fs)不得短于宽限期(%.0fs)—— 宽限期内凭据必须有效"
				% [float(S.TOKEN_TTL_SECONDS), float(G.DEFAULT_SECONDS)])

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

★ 上面那些断言消息里**不要**再嵌半角双引号(会破字符串)—— 需要引号时用「」(本仓文档的既有写法)。

- [ ] **Step 2: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd`
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

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd`
Expected: `REJOIN REGISTRY: ALL-OK`。

- [ ] **Step 5: 变异反证(三条)**

1. 把 `lookup` 的 `now_ms >= int(...)` 改成 `now_ms > int(...)` ⇒ ② 那条("正好到点必须失效")应红;还原。
2. 把 `decision` 里"凭据为空"与"code 不符"两条**对调** ⇒ ④ 的"理由"那条应红;还原。
3. 把 `TOKEN_TTL_SECONDS` 临时改成 `10.0` ⇒ ②b 那条(不短于宽限期)应红;还原。

三段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add server/rejoin_registry.gd server/rejoin_registry.gd.uid \
  tests/rejoin_registry_smoke.gd tests/rejoin_registry_smoke.gd.uid
git commit -m 'feat(net): 回局凭据表 RejoinRegistry(纯逻辑 + 三种拒绝判据 + TTL 不短于宽限期)'
```

---

## Task 4: 回局凭据的登记与清理(四个 spawn 点 + 拆除收口)

**Files:**
- Modify: `server/lobby_rooms.gd`(三个房类删 `tokens`;`var rejoin := …`;`teardown_room`)
- Modify: `server/room_manager.gd`(四个 spawn 点 + `_reclaim_finished_matches` 首行 GC)

**Interfaces:**
- Consumes: `RejoinRegistry.grant/drop_room/prune`(Task 3)、`WorkerLauncher.pid_of`(显示方案)
- Produces: `LobbyRooms.rejoin: RejoinRegistry`、`RoomManager._grant_rejoin(code, port, granted) -> void`

★ 本任务是**唯一**往显示方案交付的代码里插一行的地方(`_reclaim_finished_matches` 的凭据 GC)—— 理由写在那一段的注释里。

- [ ] **Step 1: 三个房类删 `tokens`,并给 `LobbyRooms` 加凭据表字段**

`server/lobby_rooms.gd` 里三处 `var tokens: Dictionary = {}` 那一行**整行删掉**(`Room` / `RoyaleRoom` / `TeamRoom` 各一处),并在 `var team_rooms: Dictionary = {}` 之后加:

```gdscript
# 回局凭据表(阶段 2-B)。★ 它**独立于房对象**:房被拆除时凭据要不要跟着消失,由
# `teardown_room` **显式**决定(`rejoin.drop_room`),而不是由"房对象还在不在"隐式决定
# —— 回局的查询要在大厅侧活过拆除(见 RejoinRegistry 的类头)。三个房类原先各有一份
# `tokens` 字段,随本次一起删除:同一件事只留一处记录。
var rejoin := RejoinRegistry.new()
```

★★ **同时删掉 `server/room_manager.gd` 里那 4 行写入点**(`rr.tokens[pid] = tk` 在 `:78` 与 `:181`、`tr.tokens[pid] = tk` 在 `:222`、`room.tokens[pid] = tk` 在 `:261`,各一行;Step 4 给的新循环里已经不再有它们)。**两件事必须同时做**:字段一删,那 4 行就是"往一个不存在的属性写",下一次 `--import` 当场 Parse Error(而那时实施者正在跑别的命令,症状会看着像"别的地方坏了")。
★ 删它们是**安全的**:这 4 行是**只写不读**的(全仓 `grep -rn "\.tokens" server/ scenes/ core/ tests/ --include=*.gd` 只有这 4 处命中,没有任何读者;worker 侧那张 `server_main.gd` 的 `_tokens` 是**另一张表**,别动)—— token 照旧经 `session_token` 发到客户端(那几行不动),只是"大厅侧不再留一份记录",替代品是 Task 3 的 `RejoinRegistry`(Step 4 补上登记)。

- [ ] **Step 2: 硬校验(`tokens` 这条链彻底消失)**

Run(PowerShell):`Select-String -Path server\lobby_rooms.gd -Pattern '\.tokens'` → **0 命中**。
Run(PowerShell):`Select-String -Path server\room_manager.gd -Pattern '\.tokens'` → **0 命中**(那 4 行写入点在 Step 4 一起删)。
Run(PowerShell):`Select-String -Path server\server_main.gd -Pattern '_tokens'` → **仍在**(那是 **worker 侧**的表,**不许动**)。

- [ ] **Step 3: 拆除时作废该房的凭据**

`teardown_room` 里,`print("%s %s 拆除(端口 %d %s)" % …)` 之后、`if disconnect_peers:` 之前插入:

```gdscript
	# ★ 这一局的凭据随房一起作废:房都拆了,worker 要么已经退了、要么马上会被杀,留着凭据
	#   只会让回局把客户端送到一个已经不属于它的端口上(而且**没有一行报错**)。
	var ntk := rejoin.drop_room(room.code)
	if ntk > 0:
		print("  同时作废 %d 份回局凭据" % ntk)
```

★ 位置在 `royale_rooms.erase(...)` 之前或之后都行(全等匹配那一间),但**必须在同一个函数体内** —— `room_sweep_smoke` 的收口纪律只允许**端口归还 / 注册表删除**出现在 `teardown_room` / `_release_port_later` 里,而 `rejoin.drop_room(` 这个串不匹配它监视的任何一个模式(`_release_port_later(` / `launcher.release_now(` / `royale_rooms.erase(` / `team_rooms.erase(` / `rooms.erase(`),故是安全的;**别把这段挪到调用方**(那时它就成了"第二处拆除动作")。

★★ **上面这段代码块落地时改了一处标识符(2026-09-21,Task 5 的实证)**:`rejoin.drop_room(room.code)` → **`rejoin.drop_port(port)`**
(`teardown_room` 手里本来就有 `port`)。**归键必须是 worker 端口,不是房间号** —— 三张注册表的房号空间**重叠**
(都是 `_generate_code()` 的 4 位号),构造"两间同号的房"实测:按 code 作废会**一次清掉 2 份凭据**(同号另一间房的玩家
再也回不来,而一行日志都没有),按端口只清 1 份。★ 这与 `teardown_room` 自己那句"**别拿 `room.code` 去三张表里撞库**"
是同一条纪律,只是当年没把它应用到这张新表上。守卫:`tests/rejoin_keying_probe.tscn`;冒烟侧 `tests/rejoin_registry_smoke` ⑤
(别名 `drop_room` **不复存在**,别再按老名字写)。

- [ ] **Step 4: `RoomManager` 四个 spawn 点登记凭据**

先加辅助函数(放在 `_send_go_match` 之前):

```gdscript
# 把这一局的回局凭据登进大厅的凭据表。
# ★ **必须在 spawn 成功之后调**:凭据里带 worker 的 pid,而"这一局还在不在"就是靠它判的
#   (见 RejoinRegistry.decision 的 worker_alive 入参)。
# ★ granted 的构造在 spawn **之前**(token 必须先于 go_match 发到客户端,见那两处的既有注释),
#   故它是 `[[role, token], …]` 这份中间形态 —— 不是"发送"与"登记"两件事分家,而是同一条
#   数据在两处各取所需。
func _grant_rejoin(code: String, port: int, granted: Array) -> void:
	var pid := _launcher.pid_of(port)
	var now := Time.get_ticks_msec()
	for g in granted:
		lobby.rejoin.grant(str(g[1]), code, int(g[0]), port, pid, now)
```

`_start_match` 里把 token 循环改成"先收再登记"(★ `room.tokens[pid] = tk` 那一行**已经在 Step 1 的字段删除里失去了意义**;若它还在这儿,说明 Step 1 没做完,**回去补**):

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
```

并在 spawn 成功之后(紧挨显示方案那行 `room.worker_pid = _launcher.pid_of(port);` 的**下一行**)加:

```gdscript
	# ★ 凭据登记必须在 spawn 成功之后(要 pid 才判得出"这局还在不在")。
	_grant_rejoin(room.code, port, granted)
```

`royale_start` / `royale_start_ai` / `team_start` 三处**同款**(`room` → `rr` / `tr`;三个 `spawn_*` 的失败分支原样保留,`_grant_rejoin` 那一行同样紧跟在 `rr.worker_pid = …` / `tr.worker_pid = …` 之后)。★ `royale_start_ai` 的 token 循环只给 `rr.players`(AI 号没有 peer,既有的 `if lobby.is_peer_online(pid)` 已经表达了这一点),`granted` 的构造范围**与之一致**。

- [ ] **Step 5: 凭据表的 GC 搭显示方案的回收梯**

`server/room_manager.gd` 的 `_reclaim_finished_matches()` **首行**加:

```gdscript
	# ★ 凭据表的 GC 搭这条梯(30s 一次):TTL 只是表的上界,不需要独立定时器。
	#   ★ 这是本计划对**显示方案交付的函数**做的唯一一处改动 —— 理由是"30s 梯只有一个合理的主人",
	#   再立一条梯就是第二个定时器(本仓禁止的"同一件事两处实现")。
	lobby.rejoin.prune(Time.get_ticks_msec())
```

- [ ] **Step 6: 硬校验 + 跑既有冒烟/探针(全绿才算没碰坏显示方案)**

Run(PowerShell):`& $GODOT --headless --path . --import` → 无 Parse Error。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd` → `SMOKE_ROOM_SWEEP OK: …`(★ 它的 `_check_reclaim_ladder` 与 `_check_teardown_funnel` 都还在看着)。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd` → `REJOIN REGISTRY: ALL-OK`。
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn` → `LOBBY VISIBILITY PROBE: ALL-OK(27 条断言)`(回归:显示方案那一面一个字没坏)。

- [ ] **Step 7: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd
git commit -m 'feat(net): 回局凭据的登记(spawn 成功后带 pid)与拆除时作废;删掉三个房类的 tokens'
```

---

## Task 5: `NetBusExt` 两条 RPC + 大厅侧回局 handler(+ 探针相⑤⑥)

**Files:**
- Modify: `core/net/net_bus_ext.gd`(末尾"断线重连"一节之后)
- Modify: `tests/reconnect_smoke.gd`
- Modify: `tests/lobby_visibility_probe.gd`(相⑤⑥,**落地为** `EXPECTED_CHECKS` 27 → **31** —— ★ 比这里当时写的 30 多一条:走**信号**(`emit`)验那行 `connect` 接线的那条,三条直调 handler 的断言照不到它)

**Interfaces:**
- Consumes: `RejoinRegistry`(Task 3)、`LobbyRooms.rejoin`(Task 4)、`WorkerLauncher.pid_alive`(显示方案)
- Produces: `NetBusExt.rejoin_request(code, token)`(any_peer reliable)→ 信号 `rejoin_requested(caller, code, token)`;`NetBusExt.rejoin_denied(reason)`(authority reliable)→ 信号 `local_rejoin_denied(reason)`;`LobbyRooms.on_rejoin_request(caller, code, token) -> void`

- [ ] **Step 1: 先在 `reconnect_smoke.gd` 里加断言(此时必红)**

常量区追加:

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

在 `_initialize()` 的 `if _fail == 0:` **之前**追加:

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

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE FAILED: …`(列出缺的四条)。

- [ ] **Step 3: 加两条 RPC**

`core/net/net_bus_ext.gd` 末尾("断线重连"那一节之后)追加:

```gdscript
# ── 回大厅后回局(阶段 2-B,2026-09-21)──
# 玩家按 ESC 回主菜单 → 主菜单的「回到对局」把他送回**对应模式**的大厅页 → 大厅凭
# (房间号, token) 把 `go_match` **原样再发一次**,客户端于是走与首次进场**逐字同一条**
# 转连/认领路径。
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

- [ ] **Step 4: `LobbyRooms` 接上 handler**

`_enter_tree` / `_exit_tree` 各加一行(与既有的 `NetBusExt.team_list_requested` 那批放一起):

```gdscript
	NetBusExt.rejoin_requested.connect(on_rejoin_request)
```
```gdscript
	NetBusExt.rejoin_requested.disconnect(on_rejoin_request)
```

加 handler(放在 `team_list` 之后):

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
		#   再走一遍同样的拒绝。
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

- [ ] **Step 5: 探针追加相⑤⑥(判据面)**

`tests/lobby_visibility_probe.gd`:把 `EXPECTED_CHECKS` 改成 `30`,`_ready()` 里 `_phase_reclaim()` 之后插 `_phase_rejoin()`,并加函数:

```gdscript
# ── ⑤⑥ 回局判据在**生产 handler** 上的行为(不是只测那个纯函数)──
# ★ 为什么两半都要:纯函数测过了(`tests/rejoin_registry_smoke`),而 handler 里
#   "查 → 判 → 发"这三步的**接线**没测 —— 把 `lookup` 写成 `lookup(token, now + 一个很大的数)`
#   或把 `code` 传错,纯函数照样全绿。
# ★ 本探针**观测不到 go_match**(没有对端 → `NetBus.reply` 静默跳过),故这里能断言的是
#   拒绝路径的**副作用**(死 worker 时凭据被清)。**放行路径的真实发送**由真链路探针覆盖
#   (`tests/rejoin_probe`),这条边界照实登记。
func _phase_rejoin() -> void:
	var now := Time.get_ticks_msec()
	# ① 房间号不符:拒绝,且凭据**不被**清(worker 还活着,值得让玩家重试一次)
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

- [ ] **Step 6: `--import` + 三条冒烟 + 探针**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd` → `RECONNECT SMOKE OK`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd` → `REJOIN REGISTRY: ALL-OK`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn` → `LOBBY VISIBILITY PROBE: ALL-OK(30 条断言)`

- [ ] **Step 7: 变异反证**

把 `on_rejoin_request` 里 `var alive := WorkerLauncher.pid_alive(int(e.get("worker_pid", 0)))` 改成 `var alive := true` ⇒ 相⑥ 的"拒绝并作废"应红;还原 ⇒ 复绿。两段输出写进报告。

- [ ] **Step 8: 提交**

```bash
git add core/net/net_bus_ext.gd tests/reconnect_smoke.gd server/lobby_rooms.gd tests/lobby_visibility_probe.gd
git commit -m 'feat(net): rejoin_request / rejoin_denied 两条 RPC + 大厅侧回局 handler + 源码级冒烟'
```

---

## Task 6: `PvpSession` 两个字段 + `LobbyPage` 回局支路(+ 探针相⑦)

**Files:**
- Modify: `core/net/pvp_session.gd`
- Modify: `scenes/lobby_page.gd`
- Modify: `scenes/matchmaking.gd` / `scenes/royale_lobby.gd` / `scenes/team_lobby.gd`(`_process` 第一行)
- Modify: `tests/reconnect_smoke.gd`(字段与 `reset()`)
- Modify: `tests/lobby_visibility_probe.gd`(相⑦,`EXPECTED_CHECKS` **31 → 37**)

**Interfaces:**
- Produces:
  - `PvpSession.room_code: String` / `rejoin: bool`
  - `PvpSession.can_rejoin() -> bool` / `can_rejoin_to(code: String) -> bool` / `clear_rejoin() -> void`
  - `LobbyPage.try_rejoin_row(code) -> bool`(行被按下时的**唯一**问句,三页共用)/ `_request_rejoin()` / `_on_rejoin_denied(reason)` / `_tick_rejoin_timeout() -> bool`

★★ **本任务相对原稿的最大改动 = 入口换了**(详见 Task 7 与本文件顶部那条 ★★):回局**不再**由主菜单的「回到对局」
按钮触发(用户裁定**取消那颗按钮**),而是**玩家在房间列表里点自己那间房**。由此三处跟着变,且都写在下面的步骤里:

1. `PvpSession.mode` **删掉**(它唯一的读者是那颗被取消的按钮里"把玩家送回哪一页"的路由)——
   ★ 本仓纪律:**没读者的字段不立**(这条纪律就写在本任务 Step 2 的注释里,原文如此)。
2. `_request_rejoin()` **不再连大厅、也不碰地址框**:触发它的那一行本身就是 `room_list` 载荷里来的 ⇒ 本页
   **此刻一定连着大厅**。原来那套"地址取 `PvpSession.server_address`、不看地址框"的绕法是为了绕开
   "三个大厅页地址框默认值不同"—— 入口一改,那个陷阱**整个消失**(连 `_with_lobby` 都不需要了)。
3. 承重的问句从"按钮亮不亮"变成 **`can_rejoin_to(code)`**("这是我的房吗 + 凭据还成立吗"),
   且它必须**早于**"对局中即 disabled"被问到(见 Task 7 Step 1)。

- [ ] **Step 1: 先加冒烟断言(此时必红)**

`tests/reconnect_smoke.gd` 里 `for f in ["token", "worker_port"]:` 那个循环扩成:

```gdscript
	for f in ["token", "worker_port", "room_code", "rejoin"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)
```

`reset()` 的断言区补四条:

```gdscript
	_check(reset_body.contains("room_code = \"\""),
			"★ PvpSession.reset() 未清 room_code —— 下一局会拿着上一局的房号去问「这行是不是我的房」")
	_check(reset_body.contains("rejoin = false"),
			"★ PvpSession.reset() 未清 rejoin(下一局会拿 claim_role 去当回局、被 worker 当串线踢掉)")
	_check(ses.contains("static func can_rejoin()") and ses.contains("static func can_rejoin_to(")
			and ses.contains("static func clear_rejoin()"),
			"PvpSession 缺 can_rejoin() / can_rejoin_to() / clear_rejoin()(行的可点性与回局失败路径都要用)")
	_check(not ses.contains("static var mode"),
			"★ PvpSession 不该再有 mode —— 它唯一的读者(主菜单那颗按钮的路由)已随用户裁定取消")
```

跑一次确认红:

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE FAILED: …`

- [ ] **Step 2: 改 `core/net/pvp_session.gd`**

在 `static var worker_port: int = 0` 之后加:

```gdscript
# ── 「回大厅后回局」(路径乙)的两个字段(2026-09-21,阶段 2-B)──
# ★ 与上面两条同款纪律:**加字段前先 grep 确认有读者**。两个都有:
#   room_code : ① 回局请求要带上它(大厅按它**交叉核对**凭据;主键仍是 token);
#               ② **行可点性的那一半判据**(`can_rejoin_to` 拿它比"这一行是不是我的房")。
#               ★ 它当年被删过一次(只写不读)—— 现在有读者了才回来。
#   rejoin    : 一次性开关:下一次 `go_match` 是**回局**(认领 role 走 `reclaim_role`,
#               而不是 `claim_role`)。置位点是 `LobbyPage.try_rejoin_row()`(列表里点自己那间房)。
# ★★ **原稿里的第三个字段 `mode` 已删除**:它的唯一用途是"那颗按钮要把玩家送回哪个大厅页"
#   的路由(`main_menu._rejoin_scene_path()`),而**用户裁定取消那颗按钮** —— 玩家自己在
#   对应的那页找房间 ⇒ 没有读者。本仓纪律:没读者的字段不立(它自己就是我们当年删掉
#   `room_code` 的理由)。★ 别再"顺手把它加回来留念":那会让 `reconnect_smoke` 的反向断言红。
static var room_code: String = ""
static var rejoin: bool = false


# 手里还攥着**某一局**的凭据吗?(粗判据:三个字段齐。)
static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != ""


# 「**这一行**是不是我的房、而且我还能回去?」—— 房间列表每一行渲染时与行被按下时**共用**
# 这**一个**判据(两处各写一遍是漂的成因:漏一处就是"看着可点、点了没用"或反过来)。
# ★ 为什么必须带上房号:光判 `can_rejoin()` 会让**别人那间对局中的房**也可点 —— 点下去发出的是
#   回局请求,而凭据里的房号对不上,玩家看到的是"回局被拒"(一句与眼前那间房无关的话)。
static func can_rejoin_to(code: String) -> bool:
	return can_rejoin() and room_code == code


# 清掉回局凭据(大厅答"回不去了" / 回局超时时调)。
# ★ 与 `reset()` **分开**:`reset()` 会把 `server_address` 也拨回云默认 —— 在人家的自建服上
#   调它等于把玩家踢到另外一台机器去。
static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false
```

`reset()` 里补两行(挨着 `token = ""` / `worker_port = 0`):

```gdscript
	room_code = ""
	rejoin = false
```

- [ ] **Step 3: `LobbyPage` 加回局支路**

`_finish_lobby_ready()` 里**只补一行信号接线**(其余原样保留 —— 进页照常拉房间列表):

```gdscript
	NetBusExt.local_rejoin_denied.connect(_on_rejoin_denied)
	UiFactory.apply_font_recursive(self)
	# 进页自动连大厅拉房间列表(列表区域不再是一片空白;手动刷新仍可用)
	_request_list.call_deferred("正在连接服务器获取房间列表…")
```

★★ **原稿在这里有的那个 `if PvpSession.rejoin: _request_rejoin()` 岔路已删除**,理由不是"简化"而是**入口变了**:
触发回局的是**列表里的那一行**,而列表本来就要拉 ⇒ "进页先拉列表"与"进页先请求回局"不再是同一个位置的两条岔路
(拉列表是回局的前置)。留着那条岔路还会**抢跑**:行还没渲染出来就先发了回局请求。

在 `_do_go_match` 之上加一整节:

```gdscript
# ── 回大厅后回局(spec §3.4 路径乙;2026-09-21)──
# 入口 = **本页房间列表里"自己那间房"那一行被按下**(见 `try_rejoin_row`;三个大厅页共用这一份)。
# 本页做三件事:
#   ① 发 `rejoin_request(房间号, token)` —— ★ **此刻本页一定连着大厅**(那一行就是 `room_list`
#      载荷里来的),故这里**不连大厅、不碰地址框、也不走 `_with_lobby`**:照原稿搬会
#      `NetBus.stop()` + 重连一次,把刚拿到的列表连同自己那一行一起丢掉。
#   ② 大厅复用 `go_match` 把它送回原 worker —— 之后与首次进场**逐字同一条路**。
#   ③ 唯一的岔路在 `_claim_role_worker`(对局已经开着 → 必须发 `reclaim_role`)。
# ★ 原稿那条"地址取 `PvpSession.server_address` 而不是地址框(三个页的地址框默认值不同)"的绕法
#   随入口一起作废:它防的是"从主菜单按按钮进来时页还没连上、只能照地址框连"那一档,而现在
#   玩家**就站在已经连上的那一页**上。
var _rejoin_sent_ms := 0


# 房间列表里某一行被按下时,**先问这一句**(三页的 `_on_room_list` 都调它)。
# 返回 true = 这一行是我的房且凭据还在 ⇒ 已走回局;false = 交给调用方走普通加入。
# ★★ 它同时是**行可点性**的判据(页面渲染那一行时也要问同一句)—— 两处共用一个函数,
#    免得"看着可点、点了没用"或反过来。
func try_rejoin_row(code: String) -> bool:
	if not PvpSession.can_rejoin_to(code):
		return false
	PvpSession.rejoin = true
	_request_rejoin()
	return true


func _request_rejoin() -> void:
	# 凭据不完整(理论上到不了:行本就不该可点)→ 清掉开关,别把玩家卡在"回局态"
	if not PvpSession.can_rejoin():
		PvpSession.rejoin = false
		_status.text = "回局凭据已失效,请重新建房/加入"
		return
	_rejoin_sent_ms = Time.get_ticks_msec()
	_status.text = "正在回到对局…"
	NetBusExt.rpc_id(1, "rejoin_request", PvpSession.room_code, PvpSession.token)


# 大厅答"回不去了"(凭据失效 / 房间号不符 / 对局已结束):清掉凭据并留在本页。
# ★ 必须清:否则那一行**永远是可点的**,而每次点都是同一句失败(玩家完全不知道为什么)。
func _on_rejoin_denied(reason: String) -> void:
	PvpSession.clear_rejoin()
	_rejoin_sent_ms = 0
	_status.text = "无法回到对局:%s(可在此重新建房/加入)" % reason
	# ★ 凭据一清,那一行在**下一次渲染**时必须回到"对局中(灰色、点不动)"。本页没有"就地改一行"
	#   的路径,重拉列表是唯一的重渲染入口 —— 少了它,玩家眼前那行还停在"可点"的样子上。
	_request_list("已刷新房间列表")


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

`_do_go_match()` 里改 token 的赋值:

```gdscript
	PvpSession.role = role
	# ★ 只在**真收到新 token** 时才覆盖:回局那条路大厅**不重发** `session_token`(客户端那
	#   一份就是凭据本身),无条件写会把手里唯一能证明"我是原来那个人"的串抹成空
	#   → `reclaim_role` 必被 worker 拒(理由"令牌不匹配")并**踢连接**,而现场一个字都没有。
	if _pending_token != "":
		PvpSession.token = _pending_token
	_pending_token = ""
```

`_claim_role_worker(role)` 整段改成:

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
	# claim_role 保持原版 2 参(大厅/worker 兼容);本端选项走扩展节点 NetBusExt
	NetBus.rpc_id(1, "claim_role", role, PvpSession.player_name)
	NetBusExt.rpc_id(1, "player_options", _player_options())
	# token 走扩展节点(原 NetBus 的 claim_role 签名一律不动)。原版 worker 无本节点 →
	# 静默丢弃 → 那局就是"不能重连",不影响对局本身。
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)
```

`_return_to_lobby(msg)` 开头加两行清回局态:

```gdscript
func _return_to_lobby(msg: String) -> void:
	_connecting_worker = false
	_claimed_ms = 0
	# ★ 回局失败的各种兜底都汇到这里:不清 `rejoin` 就会让页停在"回局态"反复重试(每次都失败)。
	#   `token` **不清** —— 它可能还有效(比如只是 worker 端口没放行),玩家可以在列表里再点一次那一行。
	PvpSession.rejoin = false
	_rejoin_sent_ms = 0
	_on_return_to_lobby()
	...   # 以下既有实现原样保留
```

- [ ] **Step 4: 三个子类各接一条超时梯(`_process` 顺序不许重排)**

三个页面的 `_process` **第一行**各加(`scenes/matchmaking.gd` 的 `_process` / `scenes/royale_lobby.gd` / `scenes/team_lobby.gd`):

```gdscript
	# 0) 回局(路径乙):请求发出后大厅 15s 无应答 —— 早于下面几条梯,因为此刻它们都还没启动
	if _tick_rejoin_timeout():
		return
```

★ 每条梯的**相对顺序**别动(1v1 是 `[worker → join → 大厅 → claim]`、另两页是 `[worker → claim → 大厅 → ack]`);回局那条插在最前面是安全的:它只在 `PvpSession.rejoin` 为真时可能返回 true,而那一档只在**玩家点过自己那间房之后**才出现 —— 那一刻下面几条梯的判据都还不成立(它们要等 `go_match`)。

- [ ] **Step 5: 探针补 `can_rejoin_to()` 的真值表(相⑦)**

`tests/lobby_visibility_probe.gd`:把 `EXPECTED_CHECKS` 改成 **`37`**(★ **基数取实得的 31**,不是原稿写的 30/36 —— 详见文件结构表那一行与 `_phase_rejoin` 的函数头),`_ready()` 里 `_phase_rejoin()` 之后插 `_phase_session_flags()`,并加函数:

```gdscript
# ── ⑦ 凭据判据的真值表(`PvpSession.can_rejoin_to()` / `clear_rejoin()`)──
# ★ 放在这个**场景**探针里而不是 `-s` 冒烟:`-s` 阶段 autoload 尚未实例化,而本仓已有教训
#   ——`-s` 脚本碰全局类要走 load()/get_script_constant_map() 那套绕法,为一个真值表不值得。
# ★ 这一条防的是"那一行看着可点、点了没用":`can_rejoin_to()` 少判一个字段(比如漏了房号),
#   列表里**别人那间对局中的房**也会变可点 —— 点下去发的是回局请求,而凭据里的房号对不上,
#   玩家看到的是"回局被拒"(一句与眼前那间房无关的话)。房号那一条就是为它立的。
# ★ `PvpSession` 的静态字段是**全局**的:本函数结束时必须**还原**自己摆过的值,
#   否则同一进程里后面的相会读到脏值(本探针是独立进程,但同仓的纪律如此)。
func _phase_session_flags() -> void:
	var keep := [PvpSession.token, PvpSession.worker_port, PvpSession.room_code]
	PvpSession.token = "tk"; PvpSession.worker_port = 29901; PvpSession.room_code = "9021"
	_check(PvpSession.can_rejoin_to("9021"), "⑦ 凭据齐 + 房号对上 → 这一行可点(回局)")
	_check(not PvpSession.can_rejoin_to("9999"),
			"⑦ ★ 房号不符 → 不可点(防的是「别人那间对局中的房」也变可点,点下去只会收到一句无关的拒绝)")
	PvpSession.token = ""
	_check(not PvpSession.can_rejoin_to("9021"), "⑦ token 缺 → 不可点")
	PvpSession.token = "tk"; PvpSession.worker_port = 0
	_check(not PvpSession.can_rejoin_to("9021"), "⑦ worker_port 缺 → 不可点(连不回那一局)")
	PvpSession.worker_port = 29901; PvpSession.room_code = ""
	_check(not PvpSession.can_rejoin_to("9021"), "⑦ room_code 缺 → 不可点(回局请求带不上房号)")
	PvpSession.room_code = "9021"; PvpSession.rejoin = true
	PvpSession.clear_rejoin()
	_check(PvpSession.token == "" and PvpSession.worker_port == 0 \
			and PvpSession.room_code == "" and not PvpSession.rejoin,
			"⑦ ★ clear_rejoin() 必须把四个字段一起清(漏一个就是「那一行永远可点」)")
	PvpSession.token = keep[0]; PvpSession.worker_port = keep[1]; PvpSession.room_code = keep[2]
```

★ **新断言共 6 条**(31 → 37),与原稿的条数一致但**换了一条**:原稿第 2 条是"`mode` 缺 → 不可回局",
而 `mode` 已随按钮一起取消(Step 2),替换它的是**房号那一条** —— 它守的是新入口独有的那档错
(列表里点**别人**对局中的房),比原稿那条更贴现在这个设计。★ 别把这条省了去凑"少一条也没关系":
`can_rejoin_to` 的 `room_code == code` 那半一旦漏掉,列表里每一间对局中的房都会变成可点,
而**探针与真链路都不会红**(点下去才失败,玩家看到的是"回局被拒")。

- [ ] **Step 6: `--import` + 三条冒烟 + 探针**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/reconnect_smoke.gd` → `RECONNECT SMOKE OK`
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/rejoin_registry_smoke.gd` → `REJOIN REGISTRY: ALL-OK`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn` → `LOBBY VISIBILITY PROBE: ALL-OK(37 条断言)`

- [ ] **Step 7: 变异反证(两条)**

1. 把 `can_rejoin_to()` 里的 `and room_code == code` 删掉(退化成只看 `can_rejoin()`)⇒ 相⑦ 的
   「房号不符 → 不可点」应红;还原。
2. 把 `_do_go_match` 里那句 `if _pending_token != "":` 的守卫删掉(退化成无条件覆盖)⇒ 这一条**探针照不到**(它没有对端、走不到 `_do_go_match`)—— ★ **照实登记**:该行的守卫由真链路探针 `tests/rejoin_probe` 的相 c1 覆盖(见 Task 8 Step 6 的反证**第 3 条**)。

两段(或一段 + 一条登记)写进报告。

- [ ] **Step 8: 提交**

```bash
git add core/net/pvp_session.gd scenes/lobby_page.gd scenes/matchmaking.gd \
  scenes/royale_lobby.gd scenes/team_lobby.gd tests/reconnect_smoke.gd tests/lobby_visibility_probe.gd
git commit -m 'feat(net): 回局支路(列表里点自己那间房 → rejoin_request → go_match → reclaim_role)+ PvpSession 凭据字段'
```

---

## Task 7: 三个大厅页记 `room_code` + **自己那间房那行改成可点**(回局入口)

**Files:**
- Modify: `scenes/matchmaking.gd` / `scenes/royale_lobby.gd` / `scenes/team_lobby.gd`
- ★ **`scenes/main_menu.gd` 一个字不动** —— 原「回到对局」按钮**已取消**

**Interfaces:**
- Consumes: `PvpSession.can_rejoin_to(code)` / `PvpSession.rejoin` / `LobbyPage.try_rejoin_row(code)`
- Produces: 三个页面的 `_on_room_list` 里,**自己那间对局中的房那一行可点**(点了走回局)

### ★★ 为什么不是按钮(用户裁定,别再往回改)

用户原话:**「不能有回到对局按钮」**、**「玩家必须自己找到对应的房间」**。
于是入口必须落在**玩家自己找房**的那条既有动作上 —— 也就是大厅页的房间列表:
「对局中的房看得见、进不去」那条路已经建好了(前置计划),它现在长出**第二个状态**:

| 点这一行的人 | 那一行 | 点下去 |
|---|---|---|
| **手里有这间房的有效凭据的本人** | **可点**(与普通房间同样的外观/焦点) | 走回局(`try_rejoin_row` → `rejoin_request` → `go_match` → `reclaim_role`) |
| 其他任何人 | 照旧 `disabled`、不吃焦点(前置计划已交付) | 点不动(服务端 `join_room`/`*_join` 三条守卫仍是那一半的保证) |

### ★ 顺序是承重的:先问"这是我的房吗",**再**问"对局中吗"

三个页面的 `_on_room_list` 今天都是**直接** `btn.disabled = in_match`(1v1 在 `scenes/matchmaking.gd` 的
`_on_room_list`,`in_match` 取自列表载荷;大乱斗/3v3 同款)。**照原样加"自己那间房可点"会在这一行上翻车**:
`in_match` 为真 ⇒ 那行已经被 `disabled` + `FOCUS_NONE` 收拾掉了,**回局这一档连点都点不到** ——
表现只是"回到大厅以后列表里自己那间房是灰的,回不去",而**一行报错都没有**。

故判据的**次序**是本任务唯一的硬约束:

```
  ① 先问 `PvpSession.can_rejoin_to(code)`(这是我的房 + 凭据还在)→ 是 ⇒ **可点**(走回局)
  ② 不是我的房,才轮到"in_match ⇒ disabled"这一档(前置计划的既有行为,一个字不改)
```

### ★ 前置计划留下的"对局中的房一律拒绝"那几条断言:口径要改述,行为不动

| 断言在哪 | 本批要不要动 |
|---|---|
| `tests/lobby_visibility_probe.gd` 相①②③(三人各一模式) | **断言本体一字不改** —— 它们用的 `P_C` 是**没有凭据的第三人**,新设计下**仍然必拒**;要改的是**它表达的那句话**:「对局中的房**一律**拒绝」→「对局中的房**对无凭据者**一律拒绝」。★ 该探针**观测不到补集那一半**(凭据持有者不被拒):它没有对端,而凭据那一侧走的是大厅的 `on_rejoin_request`(**相⑤⑥ 已落地**)与**客户端**的行可点性(**只有真链路探针咬得住**,Task 8 相 c1) |
| `tests/team_room_smoke.gd` | ★ **实测无关** —— 全文件既没有 `in_match` 也没有任何"对局中拒绝"的断言(`grep -n in_match tests/team_room_smoke.gd` **0 命中**),本批不动它 |
| `tests/room_sweep_smoke.gd` 的 `_check_join_refusal_guards` | **照旧有效,但它的前提要在注释里写明**:三条 join 守卫(`if room.started:` / `if rr.in_match:` / `if tr.in_match:`)不变、文案不变,**凭据那条路不许进这三条守卫** —— 即**不许**在 `join_room`/`royale_join`/`team_join` 里插"有凭据就放行"的分支:那等于把"回局"混进"入房"语义,而 `room_sweep_smoke` 那条守卫(`同款断言:守卫必须用'这一局在进行中'判`)会当场变成一句空话。回局一律走 `rejoin_request`(Task 5 已落地) |

- [ ] **Step 1: 三个大厅页记 `room_code` + 自己那行改成可点**

`scenes/matchmaking.gd`:
- `_on_room_created(code)` 里加 `PvpSession.room_code = code`;
- `_join_code(code)` 里在发 `join_room` **之前**加 `PvpSession.room_code = code`;
- `_enter_match_scene()` **不动**(原稿要在这里写的 `PvpSession.mode = "pvp"` 随 `mode` 一起取消);
- `_on_room_list` 里那两行 `btn.disabled = in_match` / `if in_match:` 换成:

```gdscript
		# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**,这一档**可点**(点了走回局);
		#    不是我的房,才轮到「对局中 ⇒ disabled」那一档(前置计划交付的既有行为)。
		#    反过来写(先按 in_match 禁用)= 回局这一档连点都点不到,而**一行报错都没有**
		#    —— 表现只是"回到大厅后自己那间房是灰的,回不去"。
		var mine := PvpSession.can_rejoin_to(code)
		btn.disabled = in_match and not mine
		if btn.disabled:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.focus_mode = Control.FOCUS_ALL
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				# 我的房 ⇒ `try_rejoin_row` 自己走回局并返回 true;否则走普通加入
				if not try_rejoin_row(code):
					_join_code(code))
```

★ 上面那段**整段照抄**到 `scenes/royale_lobby.gd` 与 `scenes/team_lobby.gd` 的 `_on_room_list`,
只把最后那个 `_join_code(code)` 换成各自既有的 `_join_room(code, "")`(另两页没有 `_join_code` 这个方法名);
两页的 `_on_room_state(state)` 开头照旧记 `PvpSession.room_code = str(state.get("code", ""))`
(★ 原稿要它们顺带记的 `mode` 一并取消),`_enter_match_scene()` **不动**。

★ 三页的状态栏文案里那句「对局中的照列但**不可进**」要顺手订正(1v1 页是
`"共 %d 个房间(未满优先;对局中的照列但不可进)"`,另两页同款)—— 现在是"**对局中的照列:自己的房可点(回局),
别人的点不动**"。★ 文案是**给玩家看的唯一线索**,而探针**一条都照不到它**(没有断言、没有取图):
漏改不报错,只是玩家读到的说明与实际行为相反。

- [ ] **Step 2: 自检(启动不报错 + 四个入口都能起)**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120` → exit 0、无 `SCRIPT ERROR`(主菜单是默认场景 —— 本批**没碰它**,这一跑是回归)
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/matchmaking.tscn` → 无 `SCRIPT ERROR`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/royale_lobby.tscn` → 无 `SCRIPT ERROR`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/team_lobby.tscn` → 无 `SCRIPT ERROR`

★ 这一跑**照不到"次序写反"**(没有对端、列表永远空)⇒ 那一档由 Task 8 相 c1 咬住(它走真列表、
真点那一行)。照实登记。

- [ ] **Step 3: 提交**

```bash
git add scenes/matchmaking.gd scenes/royale_lobby.gd scenes/team_lobby.gd
git commit -m 'feat(ui): 回局入口改为列表里自己那间房(先问"是不是我的房"再轮到"对局中即禁用");三页记 room_code'
```

### ★★ 已裁定(2026-09-21,**乙**):**私密房**玩家的回局入口 —— 接受"回不去",只登记不写代码

**用户裁定:乙。** 不写代码;把这条边界**照实登记**进 `CLAUDE.md`(Task 9 第 4 条)与本计划的自检记录。私密房里按 ESC 回主菜单的玩家,列表里没有那一行可点,**只能重新建房 / 让房主重开**。★ **不许在文档里把它写成"已支持"。** 之后可能会改(甲候选仍在下方留档)。



回局的入口是"列表里点自己那间房",而**私密房根本不进列表**:
`royale_list_payload` 与 `team_list_payload` 各有一行 `if not rr.is_public: continue`
(`server/lobby_rooms.gd`,两条载荷都在 `server/` 侧构造)。★ 1v1 房**没有** `is_public` 概念
(`room_list_payload` 不过滤),故**本项只影响大乱斗与 3v3**。
⇒ 后果:在私密房里打到一半按 ESC 回主菜单的玩家,**列表里没有那一行可点**,回局入口整个不存在
(而凭据其实还在他手里,大厅也会放行)。

三条候选(★ **本计划不选** —— 用户尚未裁定;控制者裁定后在此回填,并同步改 Task 6 的
`can_rejoin_to` 用法、Task 8 的相 c1 与 Task 9 第 4 条):

- **(甲) 只对本人列出他自己的私密房**:`*_list_payload` 增加一个"请求者 peer 在不在这间房的 `roster` 里"
  的判据 —— ★ 注意载荷目前是**纯构造、拿不到调用者上下文**(`royale_list`/`team_list` 拿到 `caller` 之后才调它),
  故这条会**改载荷签名与两个调用点**(`royale_list` / `team_list`),不是一行 if。
- **(乙) 接受"私密房不能回局"**:不写代码,把这条边界**照实登记**进 `CLAUDE.md`(Task 9 第 4 条)与本计划的自检记录;
  私密房里回主菜单的玩家只能重新建房/让房主重开。
- **(丙) 给私密房另开一个入口**(例如邀请码框旁边一颗「回到我的对局」):能满足需求,但**方向上是那颗被否掉的
  按钮的回归** —— 用户原话是「不能有回到对局按钮」「玩家必须自己找到对应的房间」,选它等于把那两条裁定绕过去。
  ★ 除非用户改口,否则不该选。

---

## Task 8: 真链路端到端回局探针(**用户跑**)

**Files:**
- Create: `tests/rejoin_probe.tscn` + `tests/rejoin_probe.gd` + `.uid`
- Create: `tests/rejoin_watcher.gd` + `.uid`(观察者挂在 `root` 上)
- Create: `tests/rejoin_probe.sh`

**Interfaces:**
- Consumes: 前面全部任务(含显示方案)
- Produces: 判据文本 `REJOIN PROBE: ALL-OK`

**覆盖什么**(1v1,三端):

| 端 | 角色 | 干什么 |
|---|---|---|
| c1 | actor(role 1) | 建房 → 开局 → 进 `pvp_game` → 打到 PLAYING → **按 ESC → 点「回到主菜单」** → **(在主菜单上)重新进入 1v1 大厅页 → 在房间列表里找到自己那间房那一行 → 点它** → 回到**原局**。断言:① 自己那行**可点**(`disabled == false`,而别人看到的是灰的);② role 与离开前一致;③ **回局后重新收到服务器广播**(PLAYING 计数严格增长) |
| c2 | 对手(role 2) | 点列表加入 → 进 `pvp_game` → 全程保持在线(它是"这一局还在"的见证) |
| c3 | 第三人 | 只连大厅:**列表里看得见这个房**(`in_match == true`)+ **加入被拒**(收不到 `room_joined`/`go_match`,收到拒绝提示)。★ 这一相是**显示方案**的线上投递证据(显示方案自己没有真链路探针,见那份计划的自检记录);★ 它同时是**新入口的反向对照**:同一行,`c3` 手里没有凭据 ⇒ 客户端**不**把它变成可点(`try_rejoin_row` 返回 false 走普通加入),服务端也照旧拒 |

**不覆盖什么(照实登记)**:大乱斗 / 3v3 的回局端到端(那要 6~8 个客户端与一条更长的比赛);这两个模式的**差异部分**(`in_match` 门控、列表、拒绝入房)已由显示方案的 `tests/lobby_visibility_probe` 在三模式上逐个钉住,而回局的客户端代码(`LobbyPage` + `PvpMatchClient`)三个模式**共用同一份**。

★ **端口纪律**(沿用 `team_match_probe` 的成规,改之前先读它的文件头):本探针的大厅起在**池外** `29300`,worker 起投点拨到池外 `29350`(`_rm.get("_launcher").set("_next_port", 29350)`)。**不占 7777**。跑前仍要确认本机没有别的 Godot 占着 7777 —— 本探针**不会杀**它。

- [ ] **Step 1: 写 `tests/rejoin_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/rejoin_probe.gd" id="1"]

[node name="RejoinProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写 `tests/rejoin_probe.gd`(裁判 + 客户端分发)**

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
#   的"等一个不会来的 room_joined"自带 40s 窗口。取 600s = 20 倍余量。★ 本仓教训:安全网给薄了
#   会把"跑得慢"读成"功能坏了"(`tests/brawl_rollback_probe.tscn` 就是被 3600 误判过的那一个,
#   实测要 30000),故这里按量级 ×20 给,而不是照抄别处的数。
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


# 相① 房建起来了(c1 建房),并且配对完成
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
# 客户端那一半由 c3 自己断言)。★ 这一相同时是**显示方案**的回归(房活过转连)。
func _stage_started() -> void:
	if _room_code == "" or not _rm.lobby.rooms.has(_room_code):
		_finish("房 %s 消失了(开局那一刻不该被拆 —— 那正是显示方案要改掉的旧行为)" % _room_code)
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
			_check(row.get("names", []) == ["BOT1", "BOT2"],
					"相② ★ 名单取自冻结的那份(实得 %s)" % str(row.get("names", [])))
			_check(int(room.worker_pid) > 0, "相② ★ spawn 成功后登记了 worker pid(回收判据的输入)")
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
#        **重新进入 1v1 大厅页 → 在房间列表里找到自己那间房那一行 → 点它** → 回到**原局**。
#        断言三条:
#          ⓪ 那一行**可点**(`disabled == false`)—— ★ 这是**新入口本身**的断言:前置计划交付的行为是
#             "对局中的房一律 disabled",而回局这一档要在**同一行**上把它翻过来。少了这一条,
#             "次序写反"(先按 in_match 禁用)会以"c1 一直点不动 → 超时"的形式表现,与"回局坏了"分不开。
#          ① 回局后 `PvpSession.role` 与离开前**一致**(大厅把凭据里的 role 发对了);
#          ② **重新收到服务器广播**(PLAYING 的 `round_state` 计数严格增长)—— 这是"真的回到
#             那一局"的唯一客观证据:离场期间客户端断着、一条广播都收不到。
#        ★ 不拿 instance_id 做断言:路径乙**会重建场景**,节点 ID 必然不同 —— 服务端那具身体
#          确实没销毁,但客户端**观测不到**它,写成断言就是伪断言。服务端身体未销毁由
#          `tests/reconnect_probe` 相①(路径甲,不重建场景)钉住。
#        ★ **不点主菜单里那颗按钮**(它已随用户裁定取消):回主菜单之后,本端**自己再挂一份大厅页**
#          (与首次挂载同一手法,见 `_attach_page_in`)—— 探针要在意的"玩家自己找到那间房"这一段,
#          落在**列表里点行**上;而主菜单那几步(点「1 v 1」)只是换场,不承载判据。
#   c2 = 对手:点列表加入 → 进 pvp_game → 全程在线(它是"这一局还在"的见证)。
#   c3 = 第三人:**只连大厅**:①列表里看得见这个房(in_match=true)②加入被拒。
#        ★ ② 是用户点名的要求("C 可以看到 A 与 B 的房间,尽管无论在对战还是掉线 C 都不应该进去")
#          —— 服务端的 `join_room` 守卫由这一条在**真链路**上验一次。
#        ★ 它同时是 c1 那一行的**反向对照**:同一行、同一份载荷,c3 手里没有凭据 ⇒ 客户端不该
#          把它变可点(本端断言:那一行 `disabled == true`)。
# 失败时把结果写进 `user://rejoin_probe_<who>.result`(子进程 stdout 父进程看不到)。
#
# ★ 与 team_match_watcher 同款的两条纪律:
#   ① **先置位再入树**:大厅页 `_ready` 会 deferred 跑一次 `_request_list`,只有"已连同地址"
#      那一支会复用现有连接(否则它会 `NetBus.stop()` 并按默认端口重连)。
#   ② 页挂在**探针场景**下(不是本节点下):换场时它随探针场景一起被 free —— 那正是生产的形状。

const LOBBY_ADDR := "127.0.0.1"
const ENTER_TIMEOUT := 60.0      # 从挂页到"进 pvp_game 且到 PLAYING"
const PLAY_SETTLE := 3.0         # PLAYING 后静置(让快照跑起来,身体有个明确的位置读数)
const REJOIN_TIMEOUT := 30.0     # 点了自己那行之后等回到 pvp_game
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
var _row_seen := false           # c1:自己那间房那一行已经出现在列表里
var _row_disabled := true        # c1:那一行的 `disabled`(新入口的断言:必须是 false)
var _c3_row_disabled := true     # c3:同一行的 `disabled`(反向对照:必须是 true)
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
	_attach_page_in(get_tree().current_scene,
			(on_create if who == "c1" else on_refresh))


# 把一份**真**大厅页挂进当前场景(首次进场与 c1 回局前各一次,同一份实现)。
# ★ 三行"先置位再入树"里**有两行是本批实测出来的**(原稿只有 `_connected` / `_connected_addr`):
#   ① `PvpSession.server_address = LOBBY_ADDR` —— `matchmaking.gd` 的地址框**默认值取的就是它**
#      (`ui_factory.line_edit(..., PvpSession.server_address)`),而 `_with_lobby` 的快路判据是
#      `_connected_addr == _addr_edit.text` ⇒ 不拨它,页 `_ready` 那次 deferred `_request_list`
#      会判"地址变了"→ `NetBus.stop()` + 按**默认端口 7777** 重连:本进程与探针大厅(29300)的
#      连接当场拆掉,而本探针明确规定不碰 7777(症状是"c1 从这一刻起什么都收不到")。
#   ② 同一行对**转连 worker** 也是必需的:`_do_go_match` 用 `PvpSession.server_address` 连 worker,
#      而 worker 就在 127.0.0.1 —— 不拨它,c1/c2 会去连**云地址**上的 29350(必失败)。
func _attach_page_in(cs: Node, action: Callable) -> void:
	if cs == null or _page != null:
		return
	_page = load("res://scenes/matchmaking.tscn").instantiate()
	PvpSession.server_address = LOBBY_ADDR
	_page.set("_connected", true)
	_page.set("_connected_addr", LOBBY_ADDR)
	cs.add_child(_page)
	_log("真大厅页已挂载(%s)" % cs.name)
	action.call()


func on_create() -> void:
	_page.call("_on_create_pressed")


func on_refresh() -> void:
	_page.call("_on_refresh_pressed")


# 在房间列表里按**房号**找那一行(三页的按钮文案都是 `"房间 %s …" % code`,逐字对应)。
# ★ 找不到时调用方必须**立刻 FAIL**,不能静默等超时 —— 那种失败与"回局坏了"在输出上长得一样。
func _find_row_button(code: String) -> Button:
	if not is_instance_valid(_page) or _page.get("_list_box") == null or code == "":
		return null
	for c in _page.get("_list_box").get_children():
		if c is Button and (c as Button).text.begins_with("房间 %s" % code):
			return c
	return null


func _on_room_list(rooms: Array) -> void:
	if who == "c1":
		# ★ c1 读的是那一行的**可点性**:手里的凭据就是"这一行是我的"的证明 ⇒ 必须可点。
		#   它只能在这里取 —— `disabled` 是客户端**渲染出来的 Button** 上的状态,载荷里没有这个字段。
		var mine := _find_row_button(_room_code)
		if mine != null:
			_row_seen = true
			_row_disabled = mine.disabled
			_rec("ROW code=%s disabled=%s" % [_room_code, str(_row_disabled)])
		return
	if who != "c3":
		return
	var in_match := 0
	for r in rooms:
		if typeof(r) == TYPE_DICTIONARY and bool(r.get("in_match", false)):
			in_match += 1
			_room_code = str(r.get("code", ""))
			_rec("ROW code=%s in_match=1 names=%s" % [_room_code, str(r.get("names", []))])
	_room_rows = in_match
	if in_match == 1:
		# ★ c3 读的是同一行的**另一半**:它**没有**凭据 ⇒ 必须不可点(`try_rejoin_row` 会返回 false
		#   走普通加入)。c1 与 c3 这两条合起来才说明"可点性"是**按人**判的,而不是"一律可点"。
		var row := _find_row_button(_room_code)
		if row != null:
			_c3_row_disabled = row.disabled
		if _phase == 0:
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


# 每帧重认对局场景。★ **绝不能缓存**:本端的剧本里游戏场景会连换三次
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


# ── c1(actor)──
var _c1_sub := 0      # 0 建房/等开局 1 打一会 2 已按 ESC 回主菜单 3 已点自己那间房那一行
func _tick_c1() -> void:
	# ★ 只看**总预算**,不看 `_page` 的死活:相 2 里本端**故意**要经历"页被换场带走 → 再挂一份",
	#   把 `not is_instance_valid(_page)` 写进这条守卫会让相 2 永远进不去(总超时兜底)。
	#   各相自己的界(等列表 / 等回局)写在各自的 `_phase_t` 判据里。
	if _phase_t > ENTER_TIMEOUT + REJOIN_TIMEOUT + RESULT_WAIT:
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
				_log("PLAYING 就位(role=%d,PLAYING 计数=%d);按 ESC 回主菜单" % [_role_before, _playing_at_leave])
				_esc_and_menu()
				_c1_sub = 2
				_phase_t = 0.0
			return
		2:
			# ★ 回到主菜单之后,本端**自己再挂一份大厅页**(与首次进场同一手法)。生产里玩家是
			#   在主菜单点「1 v 1」进这一页的,那一步只是换场、不承载任何判据;本探针要在意的
			#   是**"自己在列表里找到那间房"那一段**,也就是下面的点行。
			if _game != null:
				return                    # 还在对局场景里(换场还没发生)
			if is_instance_valid(_page) and not _page.is_inside_tree():
				_page = null              # 旧的被换场带走了(它挂在旧场景下 = 生产的形状)
			if not is_instance_valid(_page):
				_page = null
				_attach_page_in(get_tree().current_scene, on_refresh)
				return
			if not _row_seen:
				if _phase_t > ENTER_TIMEOUT:
					_fail("c1 ★ 回到大厅页后 %.0fs 没在列表里看到自己那间房(%s)" % [ENTER_TIMEOUT, _room_code])
					_finish("")
				return                    # 列表还没到
			var row := _find_row_button(_room_code)
			if row == null:
				# ★ 立刻 FAIL,不静默等超时(那种失败与"回局坏了"长得一样)
				_fail("c1 ★ 列表里没有自己那间房那一行(code=%s)—— 显示方案那一半坏了?" % _room_code)
				_finish("")
				return
			if row.disabled:
				# ★★ 这一条就是**新入口本身**:同一个房、同一份载荷,别人(见 c3)看到的是
				#    disabled,而**手里有凭据的本人**必须可点。次序写反(先按 in_match 禁用)
				#    会在这一条上当场红 —— 而不是以"点了没反应"的形式混进超时里。
				_fail("c1 ★ 自己那间对局中的房那一行是 disabled —— 回局入口不存在(次序写反?)")
			else:
				_ok("c1 ★ 自己那间对局中的房那一行**可点**(disabled=false)")
			_log("找到自己那间房那一行 → 点它")
			row.pressed.emit()
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
		# ★ 反向对照(c1 那条断言的另一半):同一行、同一份载荷,手里**没有凭据**的人看到的
		#   必须是"点不动"。两条合起来才说明可点性是**按人**判的,而不是"那一刻所有人都能进"。
		if not _c3_row_disabled:
			_fail("c3 ★ 那一行对**没有凭据的第三人**也是可点的 —— 可点性不是按人判的")
		else:
			_ok("c3 ★ 同一行对第三人仍是 disabled(按人判:凭据在他的手里,不在我手里)")
		if _joins != 0:
			_fail("c3 ★ 加入被拒失败:收到了 room_joined(%d 次)" % _joins)
		if _go_match != 0:
			_fail("c3 ★ 加入被拒失败:收到了 go_match(%d 次)" % _go_match)
		var refused := false
		for m in _server_msgs:
			if m.contains("无法加入") or m.contains("对局已进行中") or m.contains("房间不存在"):
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
	#   活着** —— c2 是对手,它一退,worker 就把 role 2 送进宽限期(相② 的前提"这一局还在"就
	#   变了味);c3 虽然不在局里,留着也不花任何代价。真正的收尾是**裁判按 PID 杀**
	#   (`_kill_children`),子进程另有一条 `--quit-after` 兜底。
	#   c1 是 actor:它的剧本跑完就该退,退出不改变任何结论。
	if hold_alive:
		print("WATCHER[%s] 结果已落盘,保持在线等裁判收尾" % who)
		return
	get_tree().quit(0 if _fails.is_empty() else 1)
```

★★ **`_game` 是每帧重认的**(`_refresh_game()`):本端的剧本里游戏场景会连换三次,**绝不能缓存一个已退役的实例** —— 本仓有 `Invalid access … previously freed` 的实测教训(`team_match_watcher` 文件头那条)。`_game == null` 就表示"此刻不在对局里",各段剧本按它推进。

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

- [ ] **Step 5: 跑(**让用户跑**;agent 不代跑)**

Run(**让用户跑**):`timeout 900 bash tests/rejoin_probe.sh`
Expected: `REJOIN PROBE: ALL-OK`。失败时先看 `tests/rejoin_probe.log` 与 `user://rejoin_probe_c{1,2,3}.godlog`。

- [ ] **Step 6: 反证(**让用户跑**,三条)**

1. **次序反证(新入口独有,先跑这条)**:把三页 `_on_room_list` 里的
   `btn.disabled = in_match and not mine` 改回前置计划的 `btn.disabled = in_match`
   (即"先按对局中禁用")⇒ 再跑一次 ⇒ c1 必须**红**,且**红在那条专门的断言上**
   (“自己那间对局中的房那一行是 disabled”),而不是以"点了没反应"混进超时里。还原 → 复绿。
   ★ 这条是**本批新入口**的守卫:没有它,"次序写反"只表现为 c1 卡在大厅页。
2. 把 `scenes/lobby_page.gd` 的 `_claim_role_worker` 里那段 `if PvpSession.rejoin:` 分支**删掉**(让它永远走 `claim_role`)⇒ 再跑一次 ⇒ c1 的"回到对局"必须**红**(被 worker 当串线踢掉,卡在大厅页)。还原。
3. 把 `scenes/lobby_page.gd` 的 `_do_go_match` 里那句 `if _pending_token != "":` 守卫**删掉**(退化成无条件 `PvpSession.token = _pending_token`)⇒ 再跑一次 ⇒ c1 必须**红**:回局那条路上大厅**不重发** `session_token`,无条件覆盖会把凭据抹成空串 → `reclaim_role` 被 worker 以"令牌不匹配"拒并踢连接。还原 → 复绿。

三段输出写进报告。

- [ ] **Step 7: 提交**

```bash
git add tests/rejoin_probe.gd tests/rejoin_probe.gd.uid tests/rejoin_probe.tscn \
  tests/rejoin_watcher.gd tests/rejoin_watcher.gd.uid tests/rejoin_probe.sh
git commit -m 'test(net): 回局真链路端到端探针(actor 离场再回局 + 第三人看得见进不去)'
```

---

## Task 9: `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`(「网络与 PvP」一节的「断线重连」小节)

- [ ] **Step 1: 记录这几条(每条都是"后人会踩"的)**

1. **宽限期 = 60 秒(三模式统一)**,唯一入口 `GraceWindow.DEFAULT_SECONDS`;`pvp_match_client` 的重连预算读的就是它(同源,不用改)。★ **测试预算**里凡按宽限期算出来的窗口(`reconnect_probe` 的 `GRACE_MIN/MAX/FINAL_TIMEOUT`、`team_match_watcher.OBSERVE_MAX`、`team_match_probe.RESULT_WAIT`)**必须同步重算**,否则症状是"一行 ALL-OK 都没有",与真失败分不开。★ **端口归还延迟与宽限期不再绑定**:承重的是"worker 进程活着 ⇒ 房与它占的端口都还在"(房活到 worker 退出),那条"延迟 > 宽限期"只剩 belt 地位(守卫 `grace_window_smoke` ⑧,注释里写明它是 belt)。
2. **回局凭据表 `server/rejoin_registry.gd`**(`RejoinRegistry`):token → `(code, role, worker_port, worker_pid, expires_at)`。★ 三个房类的 `tokens` 字段**已删除**(同一件事只留一处记录)。★ 判据是**纯函数** `decision()`;**TTL 只是表的 GC 上界**(1h,且**不得短于宽限期**), "这一局还在不在"由 `worker_pid` 的活性回答(`WorkerLauncher.pid_alive`)。★ `teardown_room` 里作废该房凭据走 **`rejoin.drop_port(worker_port)`** —— ★★ **文档里必须写清"为什么按端口而不是按房号"**:三张注册表(1v1 / 大乱斗 / 3v3)的房号**共用同一个 4 位空间**(`_generate_code()`),按 `room.code` 反查会**误伤同号的另一间房**;实测构造两间同号房:按 code 作废一次清掉 **2** 份凭据、按端口只清 **1** 份 —— 而失效那间的玩家只是"回不去",**一行日志都没有**。★ 这与 `teardown_room` 自己那句"**别拿 `room.code` 去三张表里撞库**"是同一条纪律(守卫 `tests/rejoin_keying_probe.tscn`)。★ 表的 GC 搭显示方案的 30s 回收梯(`_reclaim_finished_matches` 首行),不另立定时器。
3. **回局路径 = 复用 `go_match`**:玩家在**大厅页的房间列表里点自己那间房**那一行 → `LobbyPage.try_rejoin_row(code)` → `rejoin_request(room_code, token)` → 大厅 `NetBus.reply(caller, "go_match", role, port)` → 客户端与首次进场**逐字同一条路**(转连 worker、等 `match_start`、进对局场景),**唯一分叉**是认领那一步走 `reclaim_role`(对局已开着,`claim_role` 会被 `_on_role_claimed` 当串线踢)。★ `_do_go_match` 里"只在收到新 token 时才覆盖"那一行是**承重**的:回局路上大厅不重发 `session_token`,无条件覆盖会把凭据抹成空串。
4. **入口 = 列表里自己那间房那一行(★ 用户裁定:`不能有回到对局按钮`、`玩家必须自己找到对应的房间`;别再把它做成主菜单按钮)**:对局中的房那一行**对持有该房有效凭据的本人可点**、对其他人照旧 `disabled`,判据是 `PvpSession.can_rejoin_to(code)`,且它必须**先于**"`in_match` ⇒ disabled"被问到(次序写反 = 回局入口不存在,且不报错)。`PvpSession` 新增 `room_code` / `rejoin` 两个字段(都有读者)+ `can_rejoin()` / `can_rejoin_to()` / `clear_rejoin()`;★ 原先计划的 `mode` 字段与 `main_menu.gd` 的改动**随按钮一起取消**(`mode` 的唯一读者就是那颗按钮的路由 —— 没读者的字段不立)。★★ **照实登记一条缺口**:私密房**不进列表**(`royale_list_payload` / `team_list_payload` 跳过非公开房;1v1 无此概念)⇒ **私密房玩家目前没有回局入口**,三条候选(甲只对本人列出 / 乙接受不能回局 / 丙另给入口=那颗被否掉的按钮的回归)由用户裁定 —— ★ **别在文档里把它写成"已支持"**。
5. **前置**:本批依赖**显示方案**(`docs/superpowers/plans/2026-09-21-in-progress-room-visibility.md`)先落地 —— 房活过转连、`worker_pid`/`roster` 字段、`WorkerLauncher.pid_of/pid_alive`、30s 回收梯、以及**"对局中的房照列但点不动"那一行的既有渲染**都是它交付的。★ 别再在本批里重造任何一个;★ 本批对它的**唯一**改动 = Task 4 往 `_reclaim_finished_matches` 首行加一句凭据 GC,以及**客户端**那一行的 `disabled` 判据多了"是我的房则例外"这一档(服务端三条 join 守卫一个字不动)。
6. **守缺口照实登记**:`lobby_visibility_probe` 观测不到回局**放行路径的真实 `go_match` 发送**(无对端 ⇒ `NetBus.reply` 静默跳过)—— 那一条只由真链路探针 `rejoin_probe` 覆盖;`can_rejoin_to()` 的真值表在探针里(相⑦),**而"三页 `_on_room_list` 真的按它判那一行"只有真链路相 c1 咬得住**(`room_sweep_smoke` 那三条 join 守卫管的是**服务端**,且**刻意**不含凭据分支);`_do_go_match` 的 token 守卫也只有真链路能咬住。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录阶段 2-B(凭据表/回局复用 go_match/宽限期 60/依赖显示方案)'
```

---

## 自检记录

**spec 覆盖**:§3 第 1 条(房活过转连 + 替代回收)→ **显示方案**(前置);§3 第 2 条(凭据表独立于房)→ Task 3 + Task 4;§3 第 3 条(`rejoin_request` + 复用 `go_match`)→ Task 5 + Task 6;用户追加的**宽限期三模式 60s** → Task 1(+ 连带 Task 2);用户追加的**三模式可见性/拒绝入房** → **显示方案**(前置);**入口可达** → Task 7;真链路证据 → Task 8;文档 → Task 9。

### 与 spec 的刻意偏离(两条保留 + 一条被前置取代)

1. **回收判据不是"按宽限期收",而是"worker 进程还在不在"**(spec 原话是"`in_match` 的房不在 `on_peer_left` 里拆,改由 sweep 按宽限期收")。照字面做(开局后宽限期到点就收)会把房在**开打 60 秒后**拆掉 —— 于是"看得见"只延续 60 秒、而**一局打到中段掉线的玩家再也回不去**。
   ★ **本偏离已随"可见性"一起移交显示方案**(它现在是显示方案 §2.4 的裁定),本计划只**继承**它(消费 `WorkerLauncher.pid_alive` 与房上的 `worker_pid`),不再自己实现。
2. **`worker_pid` 进了凭据**(spec 给的形状是 `token → (code, role, worker_port, 到期时刻)`)。多一个 pid 是为了让**回局查询不需要房对象**就能回答"这一局还在不在"。
   ★ **本偏离部分移交**:房记录上的 `worker_pid` 字段由显示方案交付(它的回收梯要用);**凭据里的 `worker_pid`** 仍是本计划的(Task 3 的 `grant` 形状),因为它是"查询不需要房对象"这条性质的来源。
3. **★ 端口归还延迟的"计时起点"这条改动已被前置取代,本计划不再做**。上一版计划里有"三档延迟统一改 360"这一步,理由是"计时起点要从拆房挪到对局结束,拉齐成一个数就不再依赖那两件事的先后顺序"。**显示方案已经把计时起点挪好了**(房活到 worker 退出 ⇒ 端口一直被占着),于是:
   - 「重连的客户端手里那个端口还在不在」**不再由延迟常量保证**,而由**凭据里的 `worker_pid`** 精确回答(`decision()` 的 `worker_alive`):worker 一退,凭据当场就不再放行 —— 这才是那个问题的正解,而且**端口被复用给别的局**也正是被这一条挡住的(客户端连过去会被 `_on_reclaim` 拒并踢连接)。
   - 所以 **1v1 的 120 → 360 这一步被撤销**(数值一个都不改,只订正注释)。理由:一个既不再承重、又改动了常量、还会拉长端口占用的改动,不该留着。
   - **保留的部分**:三档延迟的注释按新职责重写(Task 2 Step 5),以及 `grace_window_smoke` ⑧ 里那条**降级为 belt** 的不等式(注释里写明它不再是承重件)。

**本计划未覆盖 / 已知边界(照实登记)**:

- **回局只在宽限期内真正成功**:宽限到期后 worker 会 `mark_disconnected`(大乱斗/3v3)或收场退进程(1v1),此时大厅仍可能放行(凭据还在、worker 还活着),客户端连过去会被 `_on_reclaim` 的判据②("该 role 不在宽限期")**踢连接**,表现为回到大厅页 + 一条失败提示。要在客户端侧提前拦(比如凭据带"断开时刻")属于**另行评估** —— 本批不做。
- **`_sweep_stale_rooms` 的在局宽限仍是估的**(大乱斗取 `RoyaleHost.MATCH_TIME` 默认值、3v3 取 `TEAM_MATCH_ESTIMATE`),CLAUDE.md 早已登记这条边界;本批**不放宽**,因为真正的界(本局实际时长)只在 worker 里。
- **1v1 worker 在"一个 claim 都没有"时会一直挂着**(既有行为,`server_main` 只给 royale/team 配了超时梯):本批不修,房与端口的泄漏由 2h 超龄清扫兜住(显示方案那条路径会 `TEARDOWN_KILL` 连 worker 一起杀)。
- **端口池压力的数字**:占用 ≈ 一局 + 最多一个梯周期(30s)+ 归还延迟;3v3 最坏 ≈ 一局 + 30 + 360。池子 `WORKER_PORT_SPAN = 500`,本作量级无虞。
- **HUD 的「掉线中 / 重连中」可见性**(spec §4 阶段 3)本批**不做** —— 回局这条路的可用性不依赖它(玩家在**自己那间房那一行**上就能看出能不能回去:可点 = 能回)。★ 这是**明确的范围裁量**,不是漏写。
- **`_do_go_match` 的 token 守卫在本批的探针里咬不住**(`lobby_visibility_probe` 没有对端、走不到那条路)—— 已登记,由 Task 8 的反证第 3 条与真链路相 c1 覆盖。
- **大乱斗 / 3v3 的回局端到端没有真链路覆盖**(要 6~8 个客户端与一条更长的比赛);这两个模式的差异部分由显示方案的三模式探针钉住,而回局的客户端代码三个模式**共用同一份**。
- ★ **私密房玩家没有回局入口**(私密房不进列表 ⇒ 没有那一行可点)—— **用户裁定:乙,接受"回不去"**(2026-09-21)。**不写代码**,只登记;私密房玩家按 ESC 回主菜单后只能重新建房或让房主重开。★ **别在文档里写成"已支持"**;甲候选(只对本人列出自己的私密房)在 Task 7 末尾留档,以后可能改。
- ★ **"那一行可点"在本批的抽成性守卫里只到客户端渲染层**:`room_sweep_smoke` 那三条 join 守卫的源码断言管的是**服务端**那一半(它们保持"对局中即拒绝"),"是不是我的房 + 凭据还在"这一问只存在于 `PvpSession.can_rejoin_to()` 与三页的 `_on_room_list` —— 前者有 相⑦ 的真值表,后者的**接线**只有真链路相 c1(点行 → 回局成功)咬得住。

**占位符扫描**:无 TBD / TODO / "类似 Task N";每个改代码的步骤都给了完整代码(含 Task 8 的观察者:`_refresh_game()` / `_is_game()` / `_find_row_button()` / `_attach_page_in()` 都是逐行可抄的实现,不是"照别的文件写")。★ **唯一的开放项**是 Task 7 末尾那条「私密房玩家的回局入口」—— 它按用户裁定缺席,故写成**控制者回填**的三选一标记,不是占位符。

**类型一致性**:`RejoinRegistry.decision(entry, code, worker_alive) -> String` 在 Task 3 定义、Task 5 按同一签名调用;`RejoinRegistry.grant(token, code, role, worker_port, worker_pid, now_ms)` 在 Task 3 定义、Task 4 的 `_grant_rejoin` 按同一签名调用;★ 作废走 **`RejoinRegistry.drop_port(worker_port)`**(Task 3/4 落地时按实证改名,`drop_room` **不存在**);`WorkerLauncher.pid_of/pid_alive` 由**显示方案**定义、Task 4/5 按同一签名调用;`LobbyRooms.rejoin` 在 Task 4 定义并被 Task 5(`lookup`/`drop_token`)与 Task 4 的回收梯(`prune`)按同一名字用;`PvpSession.{room_code, rejoin, can_rejoin, can_rejoin_to, clear_rejoin}` 在 Task 6 定义,**Task 6 Step 3 的 `try_rejoin_row` 与 Task 7 的行渲染**按同一名字用;追加到显示方案探针里的相:相⑤⑥ **已落地**(`EXPECTED_CHECKS` 27 → **31**,4 条),相⑦ 再抬到 **37**(6 条)—— 与 Task 6 Step 5 里那条"新断言共 6 条"的算术一致。

**跑法分工**:agent 可跑 = `--import`、全部 `-s` 冒烟、`tests/lobby_visibility_probe.tscn`、各页面的 `--quit-after 120` 启动自检;**用户跑** = `tests/reconnect_probe.tscn`(池外端口,但耗时长且按 PID 杀子进程)、`tests/rejoin_probe.sh`(真大厅 + 真 worker,与用户自己的大厅**共用一个 worker 端口池**)、以及一切占 7777 的既有脚本(`tests/pvp_room_smoke.sh` / `tests/room_sweep_smoke.sh` 等)。
