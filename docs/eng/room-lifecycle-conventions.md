# 房间生命周期约定（端口 / 拆除 / 三张注册表 / 宽限界）

> **这份文档是什么**:它是"房间从建到拆"这一带的**约定清单**——每条 = 一个不变量 + 违反后的**症状** + 为什么。
> **为什么有它**:这些约定原先只以"源码文本断言"的形式活着（`tools/room_sweep_lint.gd`，827 行、
> **83 处 `_fail = "…"` 全是读产品源码判形态、0 条行为断言**）。2026-10-08 按
> [`test-economy.md`](test-economy.md) 的 **D6** 把那份文件删掉了 —— **代码可以删，理由不能丢**，
> 所以把约定搬到这里，作为**人工核查清单**。
>
> ★★ **现状（必须说清，别误读）**：**下面这些约定今天没有任何自动化守卫。**
> 它们的位置、命名、调用链都不再被断言；改这一带的人要**自己按第 4 节自查**。
> 这不是"降级"，而是把一份**假的覆盖**（grep 源码文本）换成**明确的人工约定**。

## 1. 为什么删掉那份"守卫"

那份 827 行文件的头部**自己就是一部编年史**：至少 8 个带日期的段落，形状全是
「**上一版守卫被绕过了 ⇒ 打补丁**」：

| 被绕过的形态（原文摘） | 补丁 |
|---|---|
| "留头行、掏空体时上面四条全绿" | 补"循环体必须真的 `append`" |
| "此前 3v3 一条都没有"（只扫了 1v1 / royale） | 补 3v3 的对称断言 |
| "整行字面量对无害改写**响亮假红**" | 改成片段匹配 |
| "链是**两环**"（只钉住 settings 的钳位） | 补到三环（秒换算、写入端） |
| "环三的**家搬了**"（`_build_match_time_row()` 随迁移删除） | 判据改读 `.tscn` 的节点 |
| `contains("15")` 挡不住 `15.0 → 150.0`（**含子串**） | 改成判数值 |

它甚至自带一整套机制（原文件 `:53-66`）专门对付这条：**GDScript 脚本错误不赋值 `_fail`** ⇒
"该跑的断言被静默跳过，而判词照打 `OK`"。**一份 0 行为断言、8 轮补丁、判词写着"结构齐备"的"测试"** ——
这就是 [`test-economy.md`](test-economy.md) 第 1 节那条"回归套件是墓地"的本仓实例。

## 2. 约定清单

> 每条格式：**不变量** → *违反后的症状* → 为什么。

### A. 拆除必须走单一收口

**A1** 端口归还、注册表删除、杀 worker，**只许**出现在 `LobbyRooms.teardown_room(...)` 体内。
→ *症状*：新加一条拆除路径时漏掉其中一步 ⇒ **静默端口泄漏**（房看着没了，worker 还占着端口）。
→ 为什么：这条失败模式在本层**补过三次**（`on_peer_left` 空房分支 / `royale_leave` / `ai_duel` 摘房前的手动释放）——
没有单一收口时，每加一条路径就重新赌一次。

**A2** `room_manager.gd`（编排层）里**不许**出现 `rejoin.drop_port(` / `rejoin.drop_room(`。
→ *症状*：绕道写在编排层 ⇒ 收口那条根本看不见它。
→ 注：`drop_room(code)` 是**旧名**；按 code 作废会**误伤同号空间的另一间房**（三张注册表的房号空间重叠），
现行是 `drop_port(worker_port)`。

### B. 端口与 pid 的账

**B1** 建房/开局登记 pid 必须发生在 `spawn` **成功之后**；`pid_alive(<=0)` 必须是 `false`。
→ *症状*：登记早于 spawn ⇒ 那一窗口里房被判"还在"。
**B2** 端口归还后**必须清 pid**。
→ *症状*：房被判成"还在" ⇒ **永久占着列表位与端口**。
**B3** `_match_over` 必须把 `port/pid <= 0` 判成"**没结束**"。
→ *症状*：开局那一瞬会被自己的回收梯回收掉。
**B4** `WorkerLauncher.pid_of` 必须能读到登记过的 pid（登记与查询同一张表）。

### C. 清扫必须覆盖**三张**注册表

**C1** `_sweep_stale_rooms` 必须同时扫 `1v1` / `royale`（`royale_rooms`）/ `3v3`（`team_rooms`）。
→ *症状*：漏一张 ⇒ 那张的房**与端口永不被回收**；而"汇总列表那行照旧在、断言全绿"。
**C2** "无超龄房则提前 return"那条守卫必须**引用全部三张表**。
→ *症状*：只引用一张 ⇒ 另两张的房被跳过（静默泄漏）。
**C3** 每个收集块的**循环体**必须真的 `append`（只留 `for …` 头行 = 同粒度空洞）。
**C4** 汇总 `print` 必须报出 3v3 那一档（`stale_team.size()`）—— 不报 = 那一档坏了你看不见。

### D. 「一局限时」上界是**三环链**

**D1** 环一：`core/config/settings.gd` 的**钳位**（`royale_match_min`）。
**D2** 环二：`scenes/mp_lobby.gd` 的**秒换算**。
**D3** 环三：**写入端** —— 今天住在 `scenes/mp_lobby.tscn` 的 `MatchTimeSlider.max_value`（`HSlider`，**恰一个**）；
`mp_lobby.gd` 只灌 `value = Settings.royale_match_min` 并接 `value_changed`，**不许**再碰 `max_value`。
→ *症状*：只放宽环三 ⇒ 环一环二照绿而**上界失效**（下发值可以超过宽限）。
→ 为什么写进文档：原文件头部记着"把它写进 header 是为了让下一个读到『两环』的人知道**还有一环**"。

### E. 回收梯与回局凭据

**E1** `room_manager._process` 必须调 `_reclaim_finished_matches`，且 `_sweep_stale_rooms` 挂在 `SWEEP_INTERVAL(10min)` 上。
→ *症状*：对局结束后**房与端口永不被回收**。
**E2** 回局凭据必须**在四个 `spawn` 点各自登记**，且 `_grant_rejoin(` **排在 spawn 之后**。
→ *症状*：`worker_pid` 会是 `0`；那**一个模式**永远回不去（安静地只坏一个模式）。
**E3** 回收梯必须清过期凭据（`lobby.rejoin.prune`）。
→ *症状*：凭据表**只增不减**，无限增长。

### F. 启动协议

**F1** 模式开关走 `--roles` **集合**；旧的单值 argv 标识符不许回流。
**F2** `--royale` 与 `--team` **互斥**，且互斥分支里必须真有 `quit(1)`。
→ *症状*：空块 = 守卫守不住 ⇒ **静默开成错的那个模式**。
**F3** 拒绝文案三模式统一（别各写各的）。

### G. 模式答案必须来自单一来源

**G1** 宽限分派必须来自 `GraceWindow.expire_action` 的返回值，**不许**手写 `if _royale:` / `if _team_mode:`。
**G2** `_expire_graces` 的移出分支必须调 `mark_disconnected`（3v3 少人应继续打）。
**G3** `_on_role_claimed` 的越界守卫必须**按模式集合**判，不能只认 `_royale`。

### H. 3v3 开局三律

**H1** **满员才开**：收齐判据用 `_claims.size() >= _team_of_role.size()`；**不许**用 `_role_set.size()`
（role 会重复/留空洞 ⇒ 分母错）。
**H2** 报到超时梯必须 `quit(0)` —— 收不齐就**退出释放端口**，**不许**调 `_begin_match` 降级开局
（用户裁定：满 6 人才开）。
**H3** "全员走光才退出"判据必须含 `_team_mode`。→ *症状*：3v3 全员走光后 **worker 永驻占端口**。

### I. 超龄判据的输入

**I1** `create_room` / `royale_create` 必须给 `created_at` 赋时间戳（超龄判据的输入）。
**I2** 1v1 的超龄判断**不再**是裸 `MAX_ROOM_AGE`（有宽限）。
**I3** 大乱斗在局宽限必须引用 `ROYALE_MATCH_TIME_CEILING`（**可证上界**，不是 `RoyaleHost.MATCH_TIME` 那个默认值）
与 `rr.in_match` 门控，且**含** `SWEEP_INTERVAL`。

## 3. 相关文件

- 拆除收口 / 账本：[`server/lobby/lobby_rooms.gd`](../../server/lobby/lobby_rooms.gd)
- 编排 / 清扫 / 回收梯：[`server/lobby/room_manager.gd`](../../server/lobby/room_manager.gd)
- worker 进程：[`server/lobby/worker_launcher.gd`](../../server/lobby/worker_launcher.gd)
- 大厅与上限链：[`scenes/mp_lobby.gd`](../../scenes/mp_lobby.gd) + [`scenes/mp_lobby.tscn`](../../scenes/mp_lobby.tscn)
- 宽限分派：[`core/net/grace_window.gd`](../../core/net/grace_window.gd)
- 启动协议：[`server/server_main.gd`](../../server/server_main.gd)、[`server/lobby/room_manager.gd`](../../server/lobby/room_manager.gd)

★ **上列路径按内容读，别抄行号**（本仓的文档引用过期过多次）。

## 4. 人工自查（改这一带时按序做）

1. `grep -rn "teardown_room\|drop_port\|kill_worker" server/ scenes/` —— 端口归还/注册表删除/杀 worker
   **是否只出现在 `teardown_room` 体内**（A1/A2）。
2. `grep -n "stale_" server/lobby/room_manager.gd` —— 清扫列表与"提前 return"守卫**是否引用三张表**（C1–C4）。
3. `grep -n "max_value\|royale_match_min\|MATCH_TIME_CEILING" core/config/settings.gd scenes/mp_lobby.gd scenes/mp_lobby.tscn`
   —— 三环链是否都还在（D1–D3）。
4. `grep -n "prune\|_grant_rejoin\|pid_alive\|_reclaim_finished_matches" server/` —— E1–E3、B1–B4。
5. `grep -n "GraceWindow.expire_action\|if _royale\|if _team_mode" server/` —— G1 是否还有人手写模式分派。
6. **真链路跑一遍** 3v3 与 1v1：建房 → 开局 → 全员走光 → 确认 worker 退出、端口释放
   （`tests/probe/team_match_probe.sh` / `tests/smoke/pvp_room_smoke.sh`；★ 3v3 真链路今天**仍没有可信的端到端守卫**，见 [`registered-debt.md`](registered-debt.md) §一）。

## 5. 翻案条件（把某条变回自动化守卫）

**只有一种做法算数**：写**行为**断言 —— 让那条不变量在**运行期**可观测（例如"全员走光后 worker 进程真的退出"、
"超龄房被扫后 `worker_port` 被归还"），而不是再回去 grep 源码文本。

★ 反面教材就是被删掉的那份文件：它的判据是"**某人有没有写这段字**"，所以它**抓不到行为错**，
只能抓"写法变了"；而"写法变了"未必是错 —— 这正是它 8 轮补丁的来源。
