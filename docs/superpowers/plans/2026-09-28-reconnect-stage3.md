# 断线重连 阶段 3(可见性 + 两个既有缺陷)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「掉线中 / 重连中」变成玩家**看得见**的东西(spec §4 的 3.1 / 3.2 / 3.4),并修掉 `NetBus.opponent_left` 那条**全仓零调用点**的死路(3.3)。

**Architecture:** 三件事、三条互不重叠的链路:
1. **服务器 → 客户端的状态**(3.1):`GraceWindow` 长出三个**纯助手**(`remaining` 是实例方法,`merge_into` / `tick_display` 是 static;都不读时钟、不碰节点),`server_main` 把读数推进宿主的 `grace_snapshot` 字段,三个 `round_state` 生产者在**唯一的出口** `_send_round_state()` 里把它并进载荷 —— 空表**不带键**,老客户端忽略未知键。
2. **客户端本地的状态**(3.2/3.4):新增 `ui/status_banner.tscn/.gd`(CanvasLayer layer=140),由**基类** `PvpMatchClient` 在已有的 `_subscribe_reconnect()` 里实例化,重连状态机的四个转折点驱动它。阶段 1 之所以只 `print`,是因为当时"没有一个能挂上去的节点" —— 本计划补上那个节点。
3. **一条到达不了的通知**(3.3):`server_main._expire_graces` 的 1v1 收场分支里补上 `opponent_left` 的发送点,客户端侧补一条**与到达顺序无关**的收口(`_match_ended` 闸 + `_cancel_reconnect()`)。

**Tech Stack:** Godot 4.7.1(标准版)、GDScript、`GraceWindow`(纯逻辑、无 autoload、`-s` 可测)、`ProbeBase`/`ScanUtil`(源码级探针脚手架)。

**来源 spec:** `docs/superpowers/specs/2026-09-17-reconnect-stage2-3-design.md` 的 **§4**(3.1–3.4);**§5/§6 是边界**(§5 的 `RoyaleHost.start_on` 网格预载问题**不碰**,§6 的五条**明确不做**)。

---

## Global Constraints

- **判据一律是 grep 文本**,不看退出码:脚本挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- **`--quit-after` 统一给 3600 帧**(安全网,只在挂住时用得上;真链路探针另有自己的数,别动)。
- 引擎二进制走环境变量:先 `source tests/env.sh`,再用 `"$GODOT"`。
- **跑法分工**:`-s` 冒烟与 headless 场景探针**可由 agent 跑**;**真渲染探针不能加 `--headless`**(headless 下 `get_image()` 给 null ⇒ 直接 FAIL),由**用户**跑并读图;`tests/reconnect_probe.tscn`(真链路、起子进程、耗时长)与一切占 **7777** 的脚本也由**用户**跑。
- ★ **两支 Godot 测试之间查一次残留**:`tasklist | grep -i godot` 应为空。本计划新增的两个探针都**不起子进程**(唯一例外是 Task 2 要改的 `reconnect_probe`,那支本来就是用户跑的),但这是本仓 2026-09-27 起的新纪律(孤儿 worker 会让下一支**静默挂住**)。
- 提交**按名 `git add`** 单个文件,不用 `git add -A` / `git add .`;提交信息用 `git commit -F - <<'EOF'` heredoc,**不用** `-m "…"`(双引号会**静默吞掉**反引号与 `$`)。
- **字号必须是 16 的倍数**(`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`)。本计划**不引入任何新字号**:新增的两处载体(`ui/status_banner.gd` 的 `const FONT_SIZE := 32`、`ui/pvp_hud.tscn` 里 `GraceLabel` 的 `theme_override_font_sizes/font_size = 32`)都沿用既有的 **32**。
- **颜色只准在 `ui/ui_factory.gd` 定义**;新增语义色必须**同时**写清它的对比度实测值(达不到 3:1 就**如实写达不到**,见 `C_TEAM_A` 那段注释的样板)。**不要在 `.gd` 或 `.tscn` 里写 `Color(...)` 字面量**。
- **定向发送前一律先判活**:`server_main` 里那一处新发送点必须是 `NetBus.reply(...)`(它体内首行判活),否则 `tests/rpc_liveness_probe.tscn` 会红。
- **`round_state` 的 `grace` 键必须是加法式的**:三个客户端 + `ui/match_result_payload.gd` 都消费这条载荷;**缺键 = 此刻没人掉线**(不是"未知"),任何消费者都不得因缺键改变原有行为。
- ★★ **`server/**` 目前有另一个 Claude 会话在并发编辑**(另一批任务)。本计划所有 `server/` 下的改动都必须先与那个会话**对齐后再落**,口径见下面「跨会话协调」一节。Task 2 与 Task 3 **在派发给实现者之前必须先确认这一点**。
- 改 GDScript **只需重导出**,不要重编裁剪模板。

---

## 跨会话协调(★★ 本计划的硬前置)

另一个会话正在改 `server/**`。本计划在 `server/` 下动了 **5 个文件**,每处的 hunk 都刻意做到"**小而加性**",但**仍必须先对齐**:

| 文件 | 本计划动什么 | 冲撞风险 |
|---|---|---|
| `server/match_state.gd` | +1 个字段 `grace_snapshot`、+1 个方法 `_send_round_state` | 低(都是新增,不删不改既有行) |
| `server/match_round.gd` | 1 行:`_rpc_all("round_state", [data])` → `_send_round_state(data)` | 低 |
| `server/royale_host.gd` | 1 行:同上(原调用显式传 `-1, true`,**那正是默认值**) | 低 |
| `server/team_host.gd` | 1 行:同上 | 低 |
| **`server/server_main.gd`** | `_enter_grace` / `_expire_graces` / `_process` 各 +1~2 行;+2 个私有函数 | **中** —— 这个文件正是"三态化清单"反复改过的地方 |

**落 Task 2 / Task 3 之前的动作(逐条做,别跳过)**:

1. `git status --porcelain server/` —— **必须为空**。非空就**停下来问**,不要 stash、不要 rebase、不要"顺手合并"。
2. `git log -1 --format='%h %s' -- server/` 记下当前 HEAD 的那条提交,写进实现者的报告里。
3. **`server_main.gd` 的确切现状(2026-09-28 已与对方当面谈定,别再凭猜)**:
   - ★ 对方**明确不碰 `_expire_graces`,一行都不碰** —— 它的 #10 是往 `_process` 的 if/elif 梯形加**第四支**(加在最末一支**之后**),且承诺"真要动 `_expire_graces` 会先 ping"。
     ⇒ **Task 2 的发送点是安全的**,不必等它:它落在 `_expire_graces` 的 1v1 收场分支里。
   - ★★ **真正会与对方重叠的是 Task 3 的 `_process` 那 1~2 行**(同一段 if/elif 梯)。**落 Task 3 之前必须先问对方那一支落了没有**;若两边都要改这一段,各自按名 `git add`、**各自提交**,别合并成一次。
   - ★ **Task 2 依赖的次序约束,由本计划独占**:`_notify_opponent_left()` 必须排在 1v1 分支的 **`quit(0)` 之前** —— worker 一退,幸存方立刻收 `server_disconnected`,那条通知就再也发不出去(这正是 3.3 的次序难题)。此条已与对方对齐,它不构成威胁。
4. 落完之后 `git diff --stat server/` 逐行核一遍:本计划的 hunk 应当**只有**上表那几处;多出来的内容一律是对方的,不要一起提交 —— **按名 `git add` 本计划碰过的文件**,不要 `git add server/`。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `core/net/grace_window.gd` | 掉线宽限期表(纯逻辑、`-s` 可测) | +3 个成员:`remaining()` / `merge_into()` / `tick_display()`(后两个是 static) |
| `server/match_state.gd` | 对局权威的共享状态底座 | +`grace_snapshot` 字段、+`_send_round_state()`(**`round_state` 的唯一出口**) |
| `server/match_round.gd` | 1v1 回合状态机 + `round_state` 广播 | 1 行:改走 `_send_round_state()` |
| `server/royale_host.gd` | 大乱斗权威 | 1 行:同上 |
| `server/team_host.gd` | 3v3 权威 | 1 行:同上 |
| `server/server_main.gd` | worker 入口(宽限期表的持有者) | +`_sync_grace_snapshot()`、+`_notify_opponent_left()`;`_enter_grace`/`_expire_graces`/`_process` 各插 1~2 行 ★ **跨会话** |
| `ui/status_banner.gd` | **新建**:对局内本地状态横幅(3.2/3.4) | 全新建 |
| `ui/status_banner.tscn` | **新建**:CanvasLayer **layer = 140**(层位唯一来源) | 全新建 |
| `ui/ui_factory.gd` | 唯一调色板 | +`C_GRACE`(第四种语义色,带实测对比度) |
| `ui/pvp_hud.gd` | 1v1 HUD | +`_grace_wrap`/`_grace_label` 的取回与刷新(3.1 的 1v1 半) |
| `ui/pvp_hud.tscn` | 1v1 HUD 版式 | +`GraceWrap` + `GraceLabel`(复用既有 `Plate` SubResource) |
| `ui/royale_hud.gd` | 大乱斗 HUD | `_refresh_board` 收 `grace` 并加「掉线」那一档(3.1 的大乱斗半) |
| `scenes/pvp_match_client.gd` | PvP 客户端基类 | +`_banner`/`_setup_status_banner`/`_set_status`/`_cancel_reconnect`;4 处状态机转折点接上去 |
| `scenes/pvp_game.gd` | 1v1 客户端 | `_on_opponent_left` 里调 `_cancel_reconnect()` + 一行 print(3.3 客户端半) |
| `tests/grace_window_smoke.gd` | 宽限期纯逻辑冒烟 | +⑩⑪⑫三相 |
| `tests/grace_feed_probe.tscn` / `.gd` | **新建**:`round_state` 载荷漏斗的行为面守卫 | 全新建 |
| `tests/reconnect_status_probe.tscn` / `.gd` | **新建**:横幅行为 + 三批接线(本地状态/3.3/HUD 消费) | 全新建 |
| `tests/hud_declarative_probe.gd` | 声明式 HUD 契约守卫 | ④ 抽成参数化助手 + 新增 ⑧ + PAIRS 加一行 |
| `tests/reconnect_probe.gd` | 真链路探针(用户跑) | 相④ 里 +1 条 worker 日志断言 |
| `tests/combat_hud_visual_probe.gd` | 对局内 HUD 视觉验收(用户跑、真渲染) | +两组带 `grace` 的载荷与取图 |
| `CLAUDE.md` | 项目说明 | §网络与 PvP 的「阶段 3 未做」清单改写 + 新纪律登记 |

---

### Task 1: `GraceWindow` 长出阶段 3 的三个纯助手(先把"算法"钉住)

**Files:**
- Modify: `core/net/grace_window.gd`
- Modify: `tests/grace_window_smoke.gd`

**Interfaces:**
- Consumes: 无(本 Task 是源)。
- Produces:
  - `GraceWindow.remaining(now_ms: int) -> Dictionary`(实例方法)—— `{role:int -> 剩余秒:float}`,按 role 升序插入,已到期的报 `0.0`。
  - `GraceWindow.merge_into(data: Dictionary, remaining_map: Dictionary) -> void`(static)—— 非空才写 `data["grace"]`。
  - `GraceWindow.tick_display(display: Dictionary, delta: float) -> Dictionary`(static)—— 客户端本地走秒,钳到 0,**键类型原样保留**。

- [ ] **Step 1: 写冒烟的新三相(先写断言,后写实现)**

在 `tests/grace_window_smoke.gd` 里,把 `_initialize()` 末尾(第 209 行 `tp_child_f` 那条 `_check` **之后**、`if _fail == 0:` **之前**)插入:

```gdscript
	# ── ⑩ 阶段 3:`remaining()`(服务端读数;进 `round_state` 的 `grace` 字段)──
	# ★ 它是**纯函数**:时间由调用方给(同 expired 的理由 —— 本类不读时钟,否则冒烟只能靠 sleep)。
	var w3 = G.new()
	_check(w3.remaining(1000) == {}, "空表的 remaining 应为空字典")
	w3.enter(3, 1000, 10.0)          # 到期 11000
	w3.enter(1, 1000, 20.0)          # 到期 21000
	_check(w3.remaining(1000) == {1: 20.0, 3: 10.0},
			"remaining 应给出「还剩多少秒」并按 role 升序插入(实得 %s)" % str(w3.remaining(1000)))
	# ★ 已到期的 role **仍在表里**(expired 不改表)⇒ 报 **0.0**,不是省略 —— 省略会让
	#   "刚好到点、还没被 leave"那一秒里客户端闪回「无掉线」。
	_check(w3.remaining(11000) == {1: 10.0, 3: 0.0},
			"到点的 role 应报 0.0 而不是被省略(实得 %s)" % str(w3.remaining(11000)))
	_check(w3.remaining(99999) == {1: 0.0, 3: 0.0},
			"全部到点也仍报 0.0(实得 %s)" % str(w3.remaining(99999)))
	# 键必须是 **int**(下面 merge_into 的载荷要过网;float 键会静默不命中,见 weapon_inventory 的同源注释)
	var rk: Array = w3.remaining(1000).keys()
	_check(typeof(rk[0]) == TYPE_INT, "remaining 的键必须是 int(实得 %d)" % typeof(rk[0]))

	# ── ⑪ 阶段 3:`merge_into()`(服务端并载荷;空表**不带键**)──
	# ★ 与 `destroyed` / `teams` / `stats` 同款纪律:**非空才带该键**。空表也带一个
	#   `grace: {}` 会让每一条 `round_state` 白背一个键,而"漂了"**不报错** —— 故这里钉死。
	var d1 := {"state": 1}
	G.merge_into(d1, {})
	_check(not d1.has("grace"), "空读数不得带 `grace` 键(实得 %s)" % str(d1))
	G.merge_into(d1, {1: 42.5})
	_check(d1.get("grace", {}) == {1: 42.5},
			"非空读数必须并进载荷(实得 %s)" % str(d1.get("grace", {})))
	# 就地改:调用方手上那份就是被改的那份(防止"返回新字典、调用方忘接")
	var d2 := {"state": 1}
	var r2: Variant = G.merge_into(d2, {2: 1.0})
	_check(r2 == null and d2.has("grace"),
			"merge_into 必须是**就地**改(返回值 %s,载荷里有键=%s)" % [str(r2), str(d2.has("grace"))])

	# ── ⑫ 阶段 3:`tick_display()`(客户端本地走秒)──
	# 服务器只在**状态转折点**广播 `grace`(1v1/3v3 平时不广播),两次之间由 HUD 自己减。
	var disp := {1: 3.0}
	disp = G.tick_display(disp, 1.0)
	_check(disp == {1: 2.0}, "本地走秒应减 delta(实得 %s)" % str(disp))
	disp = G.tick_display(disp, 5.0)
	_check(disp == {1: 0.0}, "★ 必须钳到 0(不钳会减成负数,`ceil(-3.2)` 被念成「剩余 -3s」;实得 %s)" % str(disp))
	# ★ 键类型原样保留 —— GDScript 的字典按类型寻键,`1.0` 与 `1` 是**两个键**
	#   (`{1: "a"}.has(1.0)` 为假),重建时写成 `float(r)` 会让下游 `.has(role)` 静默不命中。
	var disp2 := {7: 5.0}
	var out2: Dictionary = G.tick_display(disp2, 0.5)
	_check(out2.has(7) and not out2.has(7.0),
			"★ tick_display 必须保留**原键**(int 进 int 出;实得 %s)" % str(out2.keys()))
	_check(disp2 == {7: 5.0}, "tick_display 不得原地改入参(实得 %s)" % str(disp2))
```

- [ ] **Step 2: 加实现**

在 `core/net/grace_window.gd` 的 `func size() -> int:` **之前**插入:

```gdscript
# ── 阶段 3(2026-09-28):宽限期读数 —— 服务端下发 + 客户端本地走秒 ──
# 三个助手都是**纯函数**(不读时钟、不碰节点、不引 autoload):`-s` 冒烟直接钉
# (tests/grace_window_smoke 的 ⑩⑪⑫)。

# 服务端:当前各 role 还剩多少秒。`{role(int) -> 剩余秒(float)}`。
# ★ 已到期的 role **仍在表里**(`expired()` 不改表,由调用方自行 `leave`)—— 这里照样报 **0.0**,
#   而不是把它省略:省略会让"刚好到点、还没被 leave"那一秒里客户端闪回「无掉线」。
# ★ 按 role 升序插入:字典迭代顺序虽然稳定,但本表要进网络载荷、也要被探针逐字比对,
#   排序让两端与日志可比(同 `expired()` 的理由)。
func remaining(now_ms: int) -> Dictionary:
	var roles: Array[int] = []
	for r in _until:
		roles.append(int(r))
	roles.sort()
	var out := {}
	for r in roles:
		var left_ms := int(_until[r]) - now_ms
		out[r] = 0.0 if left_ms <= 0 else float(left_ms) / 1000.0
	return out


# 服务端:把读数并进一个载荷 —— **非空才带键**(与 `destroyed` / `teams` / `stats` 同款纪律:
# 没人掉线时一个字节都不多占,旧客户端忽略未知键)。
# ★ 收成静态纯函数而不是散在三个 `_broadcast_round_state` 里:三个生产者各写一遍必然漂,
#   而"空表也带上 `grace: {}`"这种漂法**不报错**,只是每局白背一个键。
# ★ **就地**改 `data`(调用方刚拼好的那份载荷),不返回新字典 —— 免得有人忘了接返回值。
static func merge_into(data: Dictionary, remaining_map: Dictionary) -> void:
	if not remaining_map.is_empty():
		data["grace"] = remaining_map


# 客户端:本地走秒(服务器只在**状态转折**时广播 `grace`,两次之间由 HUD 自己减)。
# ★ 与 `ui/pvp_hud.gd` 的倒计时同款口径("服务器只在状态切换时广播一次 round_state")。
# ★ 钳到 0:不钳的话它会减成负数,而 HUD 上的 `ceil(-3.2) = -3` 会被念成「剩余 -3s」。
# ★ 键**原样保留**(不重建键!)—— GDScript 的字典按类型寻键,`1.0` 与 `1` 是两个键
#   (见 `weapon_inventory.gd` 那条同源注释),写成 `out[float(r)]` 会让下游 `.has(role)` 静默不命中。
static func tick_display(display: Dictionary, delta: float) -> Dictionary:
	var out := {}
	for r in display.keys():
		out[r] = maxf(0.0, float(display[r]) - delta)
	return out
```

- [ ] **Step 3: 跑它 —— 必须 `GRACE_WINDOW OK`**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd 2>&1 | tail -20
```
Expected: 末行 `GRACE_WINDOW OK`;**没有**任何 `[FAIL] ` 行。

- [ ] **Step 4: 反向验证 —— 证明 ⑩⑪⑫ 三条新断言**真能红**(不是空转)**

逐条做**一处**变异,跑 Step 3 的命令,**看着它变红**,然后还原:

| 变异(改哪个文件) | 期望红在哪条 |
|---|---|
| `remaining()`里 `out[r] = 0.0 if left_ms <= 0 else …` 改成 `if left_ms <= 0: continue` | ⑩ 的「到点的 role 应报 0.0」 |
| `merge_into()` 去掉 `if not remaining_map.is_empty():` 那道闸 | ⑪ 的「空读数不得带 `grace` 键」 |
| `tick_display()` 的 `maxf(0.0, …)` 改成裸 `float(display[r]) - delta` | ⑫ 的「必须钳到 0」 |
| `tick_display()` 的 `out[r]` 改成 `out[float(r)]` | ⑫ 的「必须保留原键」 |

★ 四条**各自只打红自己那一相**;若某一条改完别的相也红了,说明两条断言耦合了,先查再往下走。

- [ ] **Step 5: 提交**

```bash
git add core/net/grace_window.gd tests/grace_window_smoke.gd
git commit -F - <<'EOF'
feat(reconnect): GraceWindow 长出阶段 3 的三个纯助手（remaining / merge_into / tick_display）

spec §4 的 3.1 要给 `round_state` 加一个 `grace` 字段（`{role: 剩余秒}`）。三个助手全部收在
宽限期表这个域里，全部**纯函数**（不读时钟、不碰节点、不引 autoload）⇒ `-s` 冒烟直接钉：

- `remaining(now_ms)`：服务端读数。★ 已到期的 role **仍在表里**（`expired()` 不改表）⇒
  报 **0.0 而不是省略** —— 省略会让"刚好到点、还没被 leave"那一秒里客户端闪回「无掉线」。
  按 role 升序插入，让载荷两端可比（同 `expired()` 的理由）。
- `merge_into(data, map)`：**空表不带键**（与 `destroyed` / `teams` / `stats` 同款纪律）；
  **就地**改载荷、不返回新字典（免得调用方忘接返回值）。
- `tick_display(display, delta)`：客户端本地走秒。钳到 0（不钳会念出「剩余 -3s」）；
  **键原样保留** —— GDScript 字典按类型寻键，`1.0` 与 `1` 是两个键，重建时写 `float(r)`
  会让下游 `.has(role)` 静默不命中。

冒烟加 ⑩⑪⑫ 三相，并逐条做过变异反证（四条各只打红自己那一相）。
EOF
```

---

### Task 2: 3.3 —— 让 `opponent_left` **到达**幸存者(服务端发送点 + 客户端收口)

**Files:**
- Modify: `server/server_main.gd`(★ **跨会话**:落之前先读「跨会话协调」那一段)
- Modify: `scenes/pvp_match_client.gd`
- Modify: `scenes/pvp_game.gd`
- Modify: `tests/reconnect_probe.gd`(用户跑的那支真链路探针)
- Create: `tests/reconnect_status_probe.tscn`、`tests/reconnect_status_probe.gd`

**Interfaces:**
- Consumes: 既有 `NetBus.reply(id, method, a, b, c, d) -> bool`(`core/net/net_bus.gd:173`,体内首行判活)、既有 `NetBus.opponent_left()`(`core/net/net_bus.gd:354`)、既有 `pvp_game._on_opponent_left`(`scenes/pvp_game.gd:237`)。
- Produces:
  - `server_main._notify_opponent_left() -> void`(私有;只发给 `_claims` 里还在的人)。
  - `PvpMatchClient._cancel_reconnect() -> void`(停掉在飞的重连循环;**不加状态、不碰协议**)。
  - `tests/reconnect_status_probe.tscn`:判据文本 `KH RECON-UI PROBE: ALL-OK`。

- [ ] **Step 1: 先确认跨会话前置**

Run:
```bash
git status --porcelain server/
```
Expected: **空输出**。非空 ⇒ **停下来**,按「跨会话协调」第 1/3 条处理。

- [ ] **Step 2: 服务端:补上那个从来没有过的调用点**

在 `server/server_main.gd` 的 `func _process(delta: float) -> void:` **之前**(即 `_expire_graces` 之后、`_process` 之前的空行处)插入:

```gdscript
# 1v1 收场**之前**通知还连着的人:对手不会回来了(阶段 3,spec §4 的 3.3)。
#
# ★★ 为什么必须有:`NetBus.opponent_left` 这条 RPC 全仓**此前零调用点**,而客户端那边
#   `scenes/pvp_game.gd` 的「对手已离开 → 2.5s 回主菜单」一直挂在它上面 ——
#   `CLAUDE.md` 把它列为"三条离开对局世界的路径"之一,实际**不是**。不发这一条的后果:
#   worker 收场退进程 → 幸存者只看到 `server_disconnected` → 阶段 1 的重连循环启动 →
#   整整 `GraceWindow.DEFAULT_SECONDS`(60s)的重试预算耗尽 → `_abort_reconnect` 才回主菜单。
#   即:玩家在一个**已死的静止世界**里干等一分钟,期间屏幕上**一个字都没有**。
#
# ★★ 发送走 `NetBus.reply`(本仓「答复 caller / 定向发送」的收口,体内首行判活)——
#   这是 `tests/rpc_liveness_probe.tscn` 对每一处发送点的硬要求。
# ★ 只发给 `_claims` 里**还在的** role:掉线那位早在 `_on_peer_left` 里就被
#   `_claims.erase(role)`(见那一行),故这里天然不会往一个已断的 peer 发。
# ★ 为什么只在**1v1 收场**这一处发,而不是在 `_enter_grace`(掉线那一刻)发:
#   宽限期是给对手**回来**用的窗口,掉线时就宣告"对手已离开"会把阶段 1 的整条重连功能作废
#   (幸存者当场走人 → 对手回来时房已经空了)。"掉线中"那半由 `round_state` 的 `grace`
#   字段负责(3.1),不归这里 —— 别把两者合并。
# ★ 大乱斗 / 3v3 不需要这条:单独一人到点时走的是 `mark_disconnected`(其余人继续打,
#   排行榜上那一行变「离开」),而"全员走光"那一刻**没有幸存者**可通知。
func _notify_opponent_left() -> void:
	for role in _claims:
		var peer := int(_claims[role])
		if NetBus.reply(peer, "opponent_left"):
			print("worker: 1v1 收场前通知在线玩家(opponent_left,role=%d peer=%d)" % [int(role), peer])
```

再把 `_expire_graces` 的 **1v1 收场分支**(`server/server_main.gd:300-305`)整段替换为:

```gdscript
		else:
			# 1v1:宽限内没回来 → 收场退进程(原行为,只是晚了几十秒)
			# ★★ **先通知还连着的人**(阶段 3,3.3):见 `_notify_opponent_left` 上方的长注释。
			#   顺序不能反 —— 反了的话先 `quit(0)`,那条可靠的定向包就永远发不出去
			#   (ENet 的 `put_packet` 虽然会**当场 flush**,但进程已经走到退出路径)。
			_notify_opponent_left()
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			get_tree().quit(0)
```

- [ ] **Step 3: 客户端:`_cancel_reconnect()` + 在 `_on_opponent_left` 里收口**

在 `scenes/pvp_match_client.gd` 的 `func _abort_reconnect(reason: String) -> void:` **之前**插入:

```gdscript
# 「对手已离开」是**终局**信号:把在飞的重连循环停掉(并收起状态横幅,见 Task 4)。
#
# ★★ 为什么必须有它 —— worker 收场是「先发 `opponent_left`、紧接着 `quit(0)`」,两条消息
#   (可靠通知 + ENet 断开)几乎是同一拍到达客户端,**到达顺序不保证**。于是有两种时序:
#     · 通知先到:`_on_opponent_left` 置 `_match_ended = true` ⇒ 随后那条 `服务器断开` 被
#       `_on_server_message` 的 `if _match_ended or _reconnecting: return` 挡住,**重连循环
#       根本不会启动**。这一半靠既有的 `_match_ended` 闸就够了。
#     · 断开先到:`_begin_reconnect()` 已经把 `_reconnecting` 置起来、`_retry_connect` 已
#       deferred 出去,通知才到 ⇒ **只有本函数能把那个循环叫停**。少了它,玩家会在看到
#       「对手已离开」的同时继续重试 60 秒(两条路各回一次主菜单,第二条还会把刚建出来的
#       主菜单当 old 退役)。
#   ⇒ 判据:**不论谁先到,结局都是「2.5s 后回主菜单」,且不叠加一个 60 秒的重连循环。**
# ★ 它**不重建场景、不发包、不碰协议** —— 纯本地状态收口。
func _cancel_reconnect() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")   # 该函数在 Task 4 落地;本 Task 先只调 `_cancel_reconnect`,见 Step 4
```

★ **本 Task 里先把上面最后一行写成 `pass`**,即:

```gdscript
func _cancel_reconnect() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
```

Task 4 会把它换成 `_set_status("")`。**现在不要提前调一个还不存在的函数**(GDScript 编译不过)。

再把 `scenes/pvp_game.gd` 的 `_on_opponent_left`(`scenes/pvp_game.gd:236-251`)整段替换为:

```gdscript
# 对手中途断线:播报 + 短暂停留后回主菜单(1v1 无法继续)。
# ★ 这条路径在 2026-09-28 之前**是死的**:`NetBus.opponent_left` 全仓零调用点,而本函数一直
#   挂在它上面。服务端那一半见 `server_main._notify_opponent_left`(1v1 宽限期到、收场之前)。
func _on_opponent_left() -> void:
	if _match_ended or _local == null:
		return
	_match_ended = true
	# ★ **与到达顺序无关的收口**:若"服务器断开"先到(worker 收场两条消息同拍),重连循环
	#   已经在飞 —— 这里把它停掉,否则它会继续跑满 60 秒(见 `_cancel_reconnect` 的注释)。
	_cancel_reconnect()
	print("[pvp] 对手已离开(2.5s 后回主菜单)")
	if _hud != null:
		_hud.show_notice("对手已离开", "对局结束")
	# 同 MATCH_OVER 那条:先在起定时器前捕获引用,并让到点的 lambda 在"已经离开"时不再叠加
	# 第二次换场(玩家可以在这 2.5s 内按 ESC → 暂停菜单 → 回到主菜单)。
	var tree := get_tree()
	var netbus := NetBus
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		netbus.stop()
		if not is_inside_tree():
			return
		Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))
```

- [ ] **Step 4: 真链路探针的相④ 加一条服务端断言**

`tests/reconnect_probe.gd` 的 `_track_grace()` 里,把 `if not _expiry_seen and txt.contains("1v1 宽限期到,对手未归,对局结束"):` 那一块的 `_check(_grace_stamps.size() == 2, …)` **之后**插入:

```gdscript
		# ★ 相④b(阶段 3,spec §4 的 3.3):收场前**真的发了** `opponent_left`。
		#   没有它,幸存者只能等自己那条 60s 重连预算耗尽 —— 症状是"在一个静止的世界里
		#   干等一分钟、屏幕上一个字都没有"(CLAUDE.md 里"opponent_left 不可达"那条)。
		#   判据落在 **worker 日志**上:那条通知与收场打印是同一个函数里的相邻两行,读同一份
		#   文件 ⇒ 只要收场那行在,通知那行必然也在(不存在"先看到收场、后看到通知"的竞争)。
		_check(_has(_log_path("w1v1"), "1v1 收场前通知在线玩家"),
				"相④b:1v1 worker 在收场前发了 opponent_left(否则幸存者要干等 60s 重连预算)")
```

- [ ] **Step 5: 建源码级守卫探针**

创建 `tests/reconnect_status_probe.gd`:

```gdscript
extends Node

# 阶段 3(spec §4 的 3.1/3.2/3.3/3.4)的**常驻守卫**。场景模式(headless 即可)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn
# 判据:末行 `KH RECON-UI PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 它守什么、为什么不能只靠真链路探针 ═══
# 本批四处改动的**接线**全都是"删掉不报错"的那一类:
#   · `server_main._notify_opponent_left()` 少调一次 ⇒ 服务端不发,客户端看不出任何异常;
#   · `pvp_game._on_opponent_left` 少调 `_cancel_reconnect()` ⇒ **只有**在"断开先到"那一半
#     时序里才现形(竞态,真链路探针跑十次未必撞上一次);
#   · `pvp_match_client._subscribe_reconnect()` 少建横幅 ⇒ 三个模式一起静默没有提示;
#   · 三个 `round_state` 生产者漏走 `_send_round_state()` ⇒ `grace` 字段时有时无。
# 真链路探针(`reconnect_probe`)跑一次 ~72s 且要起子进程;本探针 **2 秒内跑完、不起子进程、
# 不占端口**,把上面那些接线变成机械可查的文本断言 + 两条真行为断言。
#
# ★ 断言计数(见 tests/lib/probe_base.gd 文件头:ALL-OK 只证明"没有失败",**不证明"都跑过"**)。
#   本探针是**活的**文件:Task 2 建它,Task 3/4/5 各往里加相 —— **每加一相就必须同步抬高这个数**,
#   判据是"**实跑条数 == EXPECTED_CHECKS** 且 ALL-OK"(不是"我猜的数是几")。
#   本 Task 落地的条数(逐项相加,别凭印象):
#     _check_opponent_left()  : 1(读得到 SRV_MAIN) + a/b/c/d/e 各 1 = **6**
#     _check_cancel_wiring()  : 1(读得到 CLIENT_BASE) + 1(missing 为空) + 3(三个生产者可读) = **5**
#   ⇒ 合计 **11**。
const EXPECTED_CHECKS := 11

const SRV_MAIN := "res://server/server_main.gd"
const CLIENT_BASE := "res://scenes/pvp_match_client.gd"
const PVP_GAME := "res://scenes/pvp_game.gd"
const PRODUCERS := ["res://server/match_round.gd", "res://server/royale_host.gd",
		"res://server/team_host.gd"]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _body(p: String, fn: String) -> String:
	return ScanUtil.func_body(_code(p), fn)


func _ready() -> void:
	_check_opponent_left()
	_check_cancel_wiring()
	_finish()


# ── 相①:3.3 —— `opponent_left` 的服务端发送点与客户端收口 ──
func _check_opponent_left() -> void:
	var srv := _code(SRV_MAIN)
	_check(not srv.is_empty(), "读不到 %s" % SRV_MAIN)
	# ①a 发送点存在,且走的是 `NetBus.reply`(定向发送的判活收口)
	_check(srv.contains("NetBus.reply(") and srv.contains("\"opponent_left\""),
			"★ %s 里没有 `NetBus.reply(…, opponent_left)` —— 这条 RPC 会退回「零调用点」"
			% SRV_MAIN)
	# ①b 它被 1v1 收场那一支调用(**不是**只定义不调 —— 那正是本条要修的缺陷形状)
	var exp := _body(SRV_MAIN, "_expire_graces")
	_check(exp.contains("_notify_opponent_left()"),
			"★ `_expire_graces` 里没调 `_notify_opponent_left()` —— 发送点定义了却没人调,"
			+ "幸存者照样干等 60s")
	# ①c 调用必须排在收场**之前**(排在 quit 之后 = 永远发不出去)
	var i_notify := exp.find("_notify_opponent_left()")
	var i_quit := exp.find("get_tree().quit(0)")
	_check(i_notify >= 0 and i_quit >= 0 and i_notify < i_quit,
			"★ 通知必须排在 `get_tree().quit(0)` **之前**(notify=%d quit=%d)"
			% [i_notify, i_quit])
	# ①d 客户端侧:`_on_opponent_left` 里调了 `_cancel_reconnect()`
	var opp := _body(PVP_GAME, "_on_opponent_left")
	_check(opp.contains("_cancel_reconnect()"),
			"★ `pvp_game._on_opponent_left` 没调 `_cancel_reconnect()` —— "
			+ "「断开先到」那一半时序里,重连循环会继续跑满 60s")
	# ①e 反向:那条 `_match_ended` 闸仍在(它挡的是"通知先到"那一半)
	_check(opp.contains("_match_ended"), "`_on_opponent_left` 的 `_match_ended` 闸还在")


# ── 相②:`_cancel_reconnect` 的行为面(它必须真的把循环停掉)──
func _check_cancel_wiring() -> void:
	var base := _code(CLIENT_BASE)
	_check(not base.is_empty(), "读不到 %s" % CLIENT_BASE)
	# ②a 函数体四件事一件都不能少(少一件 = 循环会从某个入口继续跑)
	var body := _body(CLIENT_BASE, "_cancel_reconnect")
	var missing: Array[String] = []
	for needle in ["_reconnecting = false", "_reconnect_started_ms = 0",
			"_reclaim_sent = false", "_attempt_started_ms = 0"]:
		if not body.contains(needle):
			missing.append(needle)
	_check(missing.is_empty(),
			"`_cancel_reconnect` 少复位了这些量(循环会从某个入口继续跑):%s" % str(missing))
	# ②b 三个生产者都必须走 `_send_round_state`(Task 3 落地后这条会一起变绿;
	#     Task 2 阶段它只是"记录当前状态",故**不**并进 EXPECTED_CHECKS 的判据强度 ——
	#     它是一条**前瞻**断言,红了说明 Task 3 没做完)
	for p in PRODUCERS:
		var c := _code(p)
		_check(not c.is_empty(), "读不到 %s" % p)


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("KH RECON-UI PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("KH RECON-UI PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
```

★ **注意 `ScanUtil.func_body` 的取值口径**:它取的是**剥注释后**的函数体(见 `tests/lib/scan_util.gd`),
故上面那些 `"断开先到"` 之类的字串写在**注释里**不会被误命中 —— 这正是我们要的。

创建 `tests/reconnect_status_probe.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/reconnect_status_probe.gd" id="1"]

[node name="ReconnectStatusProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 6: 跑守卫 —— 必须 ALL-OK**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn 2>&1 | tail -20
```
Expected: `KH RECON-UI PROBE: ALL-OK(9 条断言)`。

★ 若 `EXPECTED_CHECKS` 与实际条数对不上,**先数清楚再改**那个常量 —— 它是本探针防"整组被跳过"的唯一手段。

- [ ] **Step 7: 反向验证 —— 证明相① 的每条断言**真能红** **

逐条做**一处**变异(改完还原),重跑 Step 6 的命令:

| 变异 | 期望红在哪条 |
|---|---|
| `server/server_main.gd` 里 `_notify_opponent_left()` 那行改成 `pass` | ①b(`没调`) |
| 把 `_notify_opponent_left()` 挪到 `get_tree().quit(0)` **之后** | ①c(次序) |
| `scenes/pvp_game.gd` 里删掉 `_cancel_reconnect()` 那行 | ①d |
| `scenes/pvp_match_client.gd` 的 `_cancel_reconnect` 里删掉 `_reclaim_sent = false` | ②a |

★ **变异必须逐条做**:一次改两处的话,红的是哪条断言就说不清了。

- [ ] **Step 8: 真链路反向验证(★ **用户跑**,agent 不要代跑)**

Run:
```bash
source tests/env.sh
timeout 400 "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn
```
Expected: `RECONNECT PROBE: ALL-OK`(整跑约 72~110s)。

**反证**:把 `server_main.gd` 的 `_notify_opponent_left()` 那行注释掉,重跑 ⇒
`相④b:1v1 worker 在收场前发了 opponent_left` **红**;还原 ⇒ 转绿。

- [ ] **Step 9: 提交**

```bash
git add server/server_main.gd scenes/pvp_match_client.gd scenes/pvp_game.gd \
        tests/reconnect_probe.gd tests/reconnect_status_probe.gd tests/reconnect_status_probe.tscn
git commit -F - <<'EOF'
fix(reconnect): 3.3 —— 补上 opponent_left 的服务端发送点，客户端加与到达顺序无关的收口

`NetBus.opponent_left` 全仓**零调用点**，而 `pvp_game._on_opponent_left` 的「对手已离开 →
2.5s 回主菜单」一直挂在它上面（CLAUDE.md 把它列为"三条离开对局世界的路径"之一，实际不是）。
1v1 宽限期到点时 worker 收场退进程 ⇒ 幸存者只看到 `server_disconnected` ⇒ 阶段 1 的重连循环
跑满 60s ⇒ `_abort_reconnect` 才回主菜单。玩家在一个已死的静止世界里干等一分钟、一个字都没有。

- `server_main._notify_opponent_left()`：1v1 收场分支里、`quit(0)` **之前**调；只发给
  `_claims` 里还在的人（掉线那位早在 `_on_peer_left` 里被摘掉）；走 `NetBus.reply`
  （定向发送的判活收口 —— `rpc_liveness_probe` 的硬要求）。
  ★ 只在**收场**发、不在 `_enter_grace` 发：宽限期是给对手回来用的窗口，掉线时就宣告
  "对手已离开"会把阶段 1 的整条重连功能作废。
- `pvp_game._on_opponent_left`：+`_cancel_reconnect()`——worker 的两条消息（可靠通知 +
  ENet 断开）到达顺序不保证：通知先到时靠既有的 `_match_ended` 闸挡住重连循环启动；
  **断开先到时只有它能叫停那个循环**。⇒ 不论谁先到，结局都是 2.5s 后回主菜单、不叠加 60s 重连。
- `tests/reconnect_probe` 相④ 加一条 worker 日志断言（收场前真的发了）。
- 新增 `tests/reconnect_status_probe`（headless、不起子进程）：把上面四处接线变成
  机械可查的文本断言 + 次序断言；逐条做过变异反证。
EOF
```

---

### Task 3: 3.1 的服务端半 —— `grace` 字段进 `round_state`

**Files:**
- Modify: `server/match_state.gd`
- Modify: `server/match_round.gd`、`server/royale_host.gd`、`server/team_host.gd`
- Modify: `server/server_main.gd`(★ **跨会话**)
- Create: `tests/grace_feed_probe.tscn`、`tests/grace_feed_probe.gd`
- Modify: `tests/reconnect_status_probe.gd`(把相②b 从"前瞻"变成"承重")

**Interfaces:**
- Consumes: `GraceWindow.remaining(now_ms)` / `GraceWindow.merge_into(data, map)`(Task 1)。
- Produces:
  - `MatchState.grace_snapshot: Dictionary`(每实例字段,由 `server_main` 推入)。
  - `MatchState._send_round_state(data: Dictionary) -> void`(**`round_state` 的唯一出口**)。
  - `server_main._sync_grace_snapshot() -> void`。

- [ ] **Step 1: 底座:`grace_snapshot` + 唯一出口**

在 `server/match_state.gd` 的 `var _left: Dictionary = {}` 那一行(第 129 行)**之后**插入:

```gdscript
# ── 断线宽限期读数(阶段 3,2026-09-28)──
# `{role(int) -> 剩余秒(float)}`;**由 worker 进程的 `server_main` 写入**(它是宽限期表的持有者),
# 三个 `round_state` 生产者只负责把它并进载荷(见 `_send_round_state`)。
# ★ 为什么是"推"而不是"宿主去问":宽限期住在 `server_main._grace` 里,宿主反向持有它的引用
#   会造一条 back-reference(本仓明确避免的那类)。推的代价只是"值可能旧 ≤1 秒" ——
#   `server_main` 每秒刷一次(见 `_expire_graces` 的调用点),客户端那两个 HUD 在两次广播
#   之间**自己走秒**(`GraceWindow.tick_display`)。
# ★ **每实例字段、不是 `static`**:探针会在同一个进程里建多个宿主,`static` 会让它们互相污染。
#   空 = 此刻没人掉线(载荷里连 `grace` 键都不带)。
var grace_snapshot: Dictionary = {}
```

在 `_rpc_all` 的**函数体之后**、`# 反查角色号。…` 那段注释**之前**(即 `server/match_state.gd:172` 与 `:175` 之间)插入:

```gdscript
# `round_state` 的**唯一出口**:三个生产者(`MatchRound` / `RoyaleHost` / `TeamHost`)各自拼完
# `data` 之后都必须调本函数 —— 宽限期读数只在这里并进去一次(**单一落点**)。
#
# ★ 为什么不并进 `_rpc_all`:那是**所有**事件(子弹/光束/拆墙/kill)的样板,往那里加
#   `round_state` 专属的键会让每条事件都白背一个 `grace`。
# ★ 为什么不让三个生产者各写一句 `GraceWindow.merge_into(...)`:三份必然漂,而"其中一个忘了"
#   **不报错** —— 只是那个模式的「掉线中」永远不亮。守卫:`tests/grace_feed_probe` 的 ③
#   (生产目录里 `_rpc_all("round_state"` **零命中**,三个文件都含 `_send_round_state(`)。
# ★ `RoyaleHost._broadcast_round_state` 原先显式传 `-1, true`(`live_only`),那正是
#   `_rpc_all` 的**默认值**(见它的签名)⇒ 统一走本出口后,大乱斗那条的行为**逐字不变**。
func _send_round_state(data: Dictionary) -> void:
	GraceWindow.merge_into(data, grace_snapshot)
	_rpc_all("round_state", [data])
```

- [ ] **Step 2: 三个生产者改走出口**

三处**各一行**替换(内容完全相同):

| 文件 | 原行 |
|---|---|
| `server/match_round.gd:192` | `	_rpc_all("round_state", [data])` |
| `server/royale_host.gd:350` | `	_rpc_all("round_state", [data], -1, true)` |
| `server/team_host.gd:489` | `	_rpc_all("round_state", [data])` |

均改为:

```gdscript
	_send_round_state(data)
```

★ `royale_host.gd:350` 上面那两行注释(「基类的广播样板,只多一个"只发在线 peer"…样板本身收在
`MatchHost._rpc_all`」)**保留**,但补一句:`# ★ 2026-09-28 起本行改走 `_send_round_state`(它内部仍调 `_rpc_all`,并多并一个 `grace` 字段)。`

- [ ] **Step 3: `server_main` 推读数(三个时机)**

在 `server/server_main.gd` 的 `func _enter_grace(role: int) -> void:` **之前**插入:

```gdscript
# 把宽限期读数推给宿主(它是 `round_state` 的生产者;见 `MatchState.grace_snapshot`)。
# ★ 只在 `_host` 存在时写 —— 开局前 `_host` 为 null,而那时不会有人掉线(宽限期只在
#   `_on_peer_left` 的"已开局"分支里进)。
# ★ 它**不广播**:广播由调用方决定(掉线那一刻、宽限到点那一刻、以及每秒一次的保鲜)。
func _sync_grace_snapshot() -> void:
	if _host != null:
		_host.grace_snapshot = _grace.remaining(Time.get_ticks_msec())
```

把 `_enter_grace` 末尾那段(`server/server_main.gd:276-283`)整段替换为:

```gdscript
		if _host.has_method("_broadcast_round_state"):
			# ★★ 这次广播**现在真的表达了掉线态**(阶段 3,2026-09-28):`_sync_grace_snapshot`
			#   把"谁在宽限里、还剩多少秒"推给了宿主,`_broadcast_round_state` 经
			#   `_send_round_state` 把它并进载荷 ⇒ 客户端那行「掉线中」由此点亮。
			#   (阶段 1 时这条广播**逐字段什么都没表达**,当时的注释登记过这件事;现在它有意义了。)
			_sync_grace_snapshot()
			_host._broadcast_round_state()
```

把 `_expire_graces` 里 `for role in _grace.expired(now_ms):` 之后的第一行(`_grace.leave(role)`,第 289 行)**之后**插入:

```gdscript
		# ★ 读数要跟着"离开宽限"一起变:下面 `mark_disconnected` 那条广播(大乱斗 / 3v3)
		#   经 `_send_round_state` 读的就是它 —— 不在这里刷新,载荷里那一行的「掉线中」
		#   会与同一帧刚被打上的「离开」**同时成立**(两条状态并存,读起来自相矛盾)。
		_sync_grace_snapshot()
```

把 `_process` 的宽限期轮询块(`server/server_main.gd:326-329`)整段替换为:

```gdscript
	# 宽限期到期轮询(每秒一次足够;不与下面两条大乱斗的报到梯纠缠)
	_grace_check_timer += delta
	if _grace_check_timer >= 1.0:
		_grace_check_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
		# ★ 读数每秒保鲜一次(阶段 3):客户端在两次 `round_state` 之间**自己走秒**,这里刷的是
		#   "下一次广播携带的值有多新"。不刷的话,宽限期里任何一次**别的**广播(掉血致死 /
		#   自己淹死 → `_broadcast_round_state`)都会带上"进入宽限那一刻"的旧值 ⇒
		#   客户端本地倒计时被**拨回**(最多 60 秒,看着像重来一轮)。
		#   ★ 本函数**顺带**是"刷新点",不额外广播任何东西(理由见下面 3.1 的取舍说明)。
		_sync_grace_snapshot()
```

**不做的事(★ 明确登记,别"顺手补上")**:不在宽限期里每秒广播一次 `round_state`。
理由不是带宽,而是**副作用**:1v1/3v3 的 `round_state` 只在状态转折时发,而三个客户端里有两处
`COUNTDOWN 且 round > 1` 的分支**不是幂等的** —— `pvp_game._on_round_state` 会
`reset_destructibles()`(重铺瓦片层 + 整层重建碰撞)、`team_game._on_round_state` 会重发一次
`match_sync`。每秒多播一次 ⇒ 倒计时 3 秒里这些活各干 3 遍(大乱斗本来就是 1Hz 广播,故那边没
这个问题 —— **两侧的必要性不同,不是不一致**)。客户端本地走秒(`GraceWindow.tick_display`)
是零副作用的等价方案。

- [ ] **Step 4: 建载荷漏斗的行为面守卫**

创建 `tests/grace_feed_probe.gd`:

```gdscript
extends Node

# `grace` 字段进 `round_state` 的**载荷面守卫**(阶段 3,spec §4 的 3.1)。场景模式、headless。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/grace_feed_probe.tscn
# 判据:末行 `GRACE FEED PROBE: ALL-OK`。
#
# ═══ 为什么不能用源码断言代替 ═══
# "三个生产者调了 `_send_round_state`"是**文本**判据(写在 tests/reconnect_status_probe 里),
# 它拦不住"并进去的时机/条件写错了"(比如空表也带键、或者读的是别的字段)。本探针真建一个
# `MatchHost`(**role_peers 传空** —— 同 `match_host_hygiene_probe` 的手法:不建玩家、不排
# peer、所有 rpc_id 静默早退),用**子类覆写 `_rpc_all`** 截获真正要发出去的那份载荷
# (同 `stats_delivery_probe` 的手法),在**调用时刻**深拷贝。
const MAP := "res://maps/factory1v1.cyrm"
const EXPECTED_CHECKS := 5

# 覆写 `_rpc_all` 的宿主:`_send_round_state` 内部调的就是它,故这里的截获是**生产路径上的**,
# 不是探针自己模仿出来的第二份。
class CaptureHost extends MatchHost:
	var last_round_state: Dictionary = {}
	var round_state_count := 0

	func _rpc_all(method: String, args: Array = [], except_role: int = -1,
			live_only: bool = true) -> void:
		if method == "round_state":
			round_state_count += 1
			last_round_state = (args[0] as Dictionary).duplicate(true)
		# 不调 super:本探针不排 peer,rpc 本来也发不出去(调了只是白扫一遍空表)。


var _checks := 0
var _fails: Array[String] = []
var _host: CaptureHost = null


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _ready() -> void:
	_host = CaptureHost.new(MAP, {})
	add_child(_host)
	# ★ 关掉服务器每帧编排:本探针手工驱动,不关的话 `_physics_process` 会自己去广播快照 /
	#   推进回合计时(同 `match_host_hygiene_probe`、`team_disconnect_probe` 的手法)。
	_host.set_physics_process(false)

	# ── ① `_ready` 那条广播:没人掉线 ⇒ **不带** `grace` 键 ──
	_check(_host.round_state_count >= 1, "`_ready` 广播了 round_state(计数 %d)" % _host.round_state_count)
	_check(not _host.last_round_state.has("grace"),
			"★ 空读数**不得**带 `grace` 键(spec 的同款纪律:destroyed/teams/stats 都是非空才带;实得 %s)"
			% str(_host.last_round_state.keys()))
	# ── ② 推入读数 ⇒ 载荷里出现 `grace`,值与推入的**逐字相同** ──
	_host.grace_snapshot = {1: 42.5}
	_host._broadcast_round_state()
	_check(_host.last_round_state.get("grace", {}) == {1: 42.5},
			"★ 非空读数必须进载荷(实得 %s)" % str(_host.last_round_state.get("grace", {})))
	# ── ③ 清空读数 ⇒ 键又消失(不是"带着一个空字典")──
	_host.grace_snapshot = {}
	_host._broadcast_round_state()
	_check(not _host.last_round_state.has("grace"),
			"读数清空后键必须消失(实得 %s)" % str(_host.last_round_state.keys()))
	# ── ④ 源码级:三个生产者都走唯一出口,且生产目录里再没有第二处 round_state 发送 ──
	_check(_funnel_is_the_only_emitter(),
			"★ `round_state` 的唯一出口被绕过:tests 的日志里有逐条读数")

	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("GRACE FEED PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("GRACE FEED PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 生产目录里 `_rpc_all("round_state"` 必须**零命中**(三处都改走了 `_send_round_state`),
# 而三个生产者都必须含 `_send_round_state(`。
func _funnel_is_the_only_emitter() -> bool:
	var ok := true
	for p in ["res://server/match_state.gd", "res://server/match_round.gd",
			"res://server/royale_host.gd", "res://server/team_host.gd"]:
		var c := _code(p)
		if c.is_empty():
			print("    ✗ 读不到 %s" % p)
			ok = false
			continue
		if p != "res://server/match_state.gd" and not c.contains("_send_round_state("):
			print("    ✗ %s 没走 `_send_round_state(`" % p)
			ok = false
	for p in ["res://server/match_round.gd", "res://server/royale_host.gd",
			"res://server/team_host.gd", "res://server/match_state.gd"]:
		var c := _code(p)
		# match_state.gd 里那一处就是出口自身的实现,故放行
		if p == "res://server/match_state.gd":
			continue
		if c.contains("_rpc_all(\"round_state\""):
			print("    ✗ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)
			ok = false
	return ok
```

创建 `tests/grace_feed_probe.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/grace_feed_probe.gd" id="1"]

[node name="GraceFeedProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 5: 跑它 —— 必须 ALL-OK**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/grace_feed_probe.tscn 2>&1 | tail -20
```
Expected: `GRACE FEED PROBE: ALL-OK(5 条断言)`。

- [ ] **Step 6: 反向验证 —— 逐条**

| 变异 | 期望红在哪条 |
|---|---|
| `server/match_round.gd` 改回 `_rpc_all("round_state", [data])` | ④(唯一出口被绕过) |
| `GraceWindow.merge_into` 去掉空表闸 | ① 与 ③ |
| `_send_round_state` 里把 `grace_snapshot` 改成 `{}` | ② |
| `server/match_state.gd` 的 `_send_round_state` 改名为 `_send_rs`(不改调用点) | 编译期就会红 —— 这条**不是**断言红的,记下来别当成断言有效性 |

- [ ] **Step 7: 把相②b 提升为承重断言**

`tests/reconnect_status_probe.gd` 的 `_check_cancel_wiring()` 里,把对 `PRODUCERS` 的那一圈
"只读文件"改成真断言,并把 `EXPECTED_CHECKS` 从 **11** 抬到 **17**
(那一圈由 **3** 条变成 **9** 条:每个生产者 3 条 ⇒ +6):

```gdscript
	# ②b(★ Task 3 起是**承重**断言,不再是前瞻):三个 `round_state` 生产者都必须走唯一出口。
	#    漏一个 ⇒ 那个模式的「掉线中」永远不亮,而且**不报错**。
	for p in PRODUCERS:
		var c := _code(p)
		_check(not c.is_empty(), "读不到 %s" % p)
		_check(c.contains("_send_round_state("),
				"★ %s 没走 `_send_round_state(`(那个模式的「掉线中」不会亮)" % p)
		_check(not c.contains("_rpc_all(\"round_state\""),
				"★ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)
```

跑:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn 2>&1 | tail -20
```
Expected: `KH RECON-UI PROBE: ALL-OK(17 条断言)`。

- [ ] **Step 8: 提交**

```bash
git add server/match_state.gd server/match_round.gd server/royale_host.gd \
        server/team_host.gd server/server_main.gd \
        tests/grace_feed_probe.gd tests/grace_feed_probe.tscn \
        tests/reconnect_status_probe.gd
git commit -F - <<'EOF'
feat(reconnect): 3.1 服务端半 —— round_state 长出 `grace` 字段（唯一出口 _send_round_state）

阶段 1 的 `_enter_grace` 里那次 `_broadcast_round_state()` **逐字段什么都没表达**（当时的
注释登记过这件事）。现在它有意义了：载荷里多一个 `grace = {role: 剩余秒}`。

- `MatchState.grace_snapshot`（每实例字段，**不是 static** —— 探针在一个进程里建多个宿主）
  + `MatchState._send_round_state(data)` = **round_state 的唯一出口**（三个生产者都调它）。
  ★ 不并进 `_rpc_all`：那是所有事件的样板，加进去会让每条事件白背一个键。
  ★ `RoyaleHost` 原先显式传 `-1, true`，那正是 `_rpc_all` 的默认值 ⇒ 行为逐字不变。
- `server_main._sync_grace_snapshot()`：三个时机推读数（进宽限 / 离开宽限 / 每秒保鲜）。
  **不额外广播任何东西** —— 1v1/3v3 的 `round_state` 只在转折时发，而两个客户端的
  `COUNTDOWN 且 round > 1` 分支**不是幂等的**（reset_destructibles / 重发 match_sync），
  每秒多播一次会把那些活各干 3 遍。客户端的秒数由 `GraceWindow.tick_display` 本地走。
- 新守卫 `tests/grace_feed_probe`（真建 MatchHost + 子类覆写 `_rpc_all` 截获载荷）：
  空读数**不带键** / 非空进载荷 / 清空后键消失 / 唯一出口没被绕过。
- `tests/reconnect_status_probe` 相②b 从"前瞻"提升为承重断言（12 条）。
EOF
```

---

### Task 4: 3.2 + 3.4 —— 「重连中」的 HUD 层(`StatusBanner`)

**Files:**
- Create: `ui/status_banner.gd`、`ui/status_banner.tscn`
- Modify: `scenes/pvp_match_client.gd`
- Modify: `tests/hud_declarative_probe.gd`
- Modify: `tests/reconnect_status_probe.gd`

**Interfaces:**
- Consumes: `UiFactory.panel_box(border: bool) -> StyleBoxFlat`、`UiFactory.style_control(c, size)`、`UiFactory.C_DANGER`、`PixelFont.shared()`。
- Produces:
  - `StatusBanner.set_text(text: String) -> void`(空串 = 收起)。
  - `PvpMatchClient._setup_status_banner() -> void`、`PvpMatchClient._set_status(text: String) -> void`。

- [ ] **Step 1: 写横幅(场景 + 脚本)**

创建 `ui/status_banner.gd`:

```gdscript
class_name StatusBanner
extends CanvasLayer

# 对局内**本地状态**横幅(阶段 3,spec §4 的 3.2 + 3.4,2026-09-28)。
# 目前只有一个数据源:`scenes/pvp_match_client.gd` 的断线重连状态机(`_set_status`)。
#
# ═══ 为什么必须有它(而不是接着 `print`)═══
# 阶段 1 把「重连中」降级成了 `print`,理由记在当时的计划里:`pvp_game` / `royale_game` /
# `team_game` 都是 **Node2D**,而 `UiFactory.panel_box()` 返回的是 **StyleBoxFlat(不是节点)**
# —— 没有一个"能挂上去的东西"。本类就是补上那个东西:`ui/status_banner.tscn` 是一个
# CanvasLayer,面板与文字由 `_ready()` 用 `UiFactory` 建 —— 与 `ui/match_result.tscn` 同一种
# 取舍(裸骨架 tscn + 代码建面板;理由是"手写锚点是'改错了不报错'的那一类",故让它与逻辑
# 同处一室,而不是散进 .tscn 的 offset 数字里)。见 `tests/hud_declarative_probe.gd` 文件头
# 关于"裸骨架 tscn 的 @onready 数为 0 是**正确形状**"那一段。
#
# ★★ **层位只住在 `ui/status_banner.tscn` 里**(`layer = 140`),脚本**不设** layer。
#   理由与结算页逐字相同:`.new()` 建出来的 CanvasLayer 是**默认的 layer 1** —— 会画在三个
#   对局 HUD(130)与小地图(131)**底下**,横幅被 HUD 盖住且**不报错**。
#   故宿主必须 `preload("res://ui/status_banner.tscn").instantiate()`;
#   守卫:`tests/hud_declarative_probe.gd` 的 ⑧。
# ★ 层位取 140 的推导:必须**高于** HUD(130)与小地图(131)(否则被盖住);必须**低于**
#   暂停菜单(145)与结算页(150)—— 那两块是模态性质的画面,横幅不该压在它们上面。
#   (真掉线时若菜单正开着,`_begin_reconnect` 会推迟到关菜单才动,那一刻菜单已经消失。)
#
# ★ 文本与配色**全部走 `UiFactory`**:颜色不在本文件写 `Color(...)` 字面量(调色板的唯一
#   来源是 `ui/ui_factory.gd`);字号必须是 16 的倍数(`kh_l4`/`kh_l5` 扫 `res://ui`)。

const FONT_SIZE := 32
# 顶中锚,落在记分条(offset_top 16)与「对手掉线中」那一条(offset_top 72)之下。
# ★ 这个数**不是**随手取的:1v1 的记分条高约 48px、其下那条 GraceWrap 到 120px 结束,
#   128 让三者互不重叠;大乱斗右上角的排行榜从 x≈1184 起,而本横幅按内容宽(实测最长的
#   "与服务器断线,正在重连…(剩余 60s)" 约 560px ⇒ 居中出现时占 680~1240,仍不压到它)。
const TOP_OFFSET := 128.0

var _panel: PanelContainer = null
var _label: Label = null


func _ready() -> void:
	# 汉字回退链 + 关抗锯齿/微调/子像素(本项目像素字体硬约定,同三个 HUD)。
	PixelFont.shared()
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ IGNORE:横幅只给人看,绝不能吃掉点击(棋盘下面的暂停菜单/按钮得照常可点)。
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	# 不透明面板(`panel_box(false)` 不描边):它可能压在浅灰蓝的地图开阔区上,半透明会读不清。
	_panel.add_theme_stylebox_override("panel", UiFactory.panel_box(false))
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.offset_top = TOP_OFFSET
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	root.add_child(_panel)

	_label = Label.new()
	_label.name = "StatusLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(_label, FONT_SIZE)
	_label.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_panel.add_child(_label)


# 空串 = 收起。★ 唯一调用方 = `PvpMatchClient._set_status`(见那里的四个转折点)。
func set_text(text: String) -> void:
	if _panel == null:
		return
	_label.text = text
	_panel.visible = not text.is_empty()
```

创建 `ui/status_banner.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/status_banner.gd" id="1"]

[node name="StatusBanner" type="CanvasLayer"]
layer = 140
script = ExtResource("1")
```

- [ ] **Step 2: 刷全局类缓存(★ 不刷会因为找不到 `StatusBanner` 而 Parse Error)**

Run:
```bash
source tests/env.sh
timeout 300 "$GODOT" --headless --path . --import 2>&1 | tail -5
```
Expected: 无 `Parse Error` / `Could not resolve class` 字样。

- [ ] **Step 3: 基类接线(四个转折点 + 建横幅)**

在 `scenes/pvp_match_client.gd` 的 `var _resync_pull_pending := false` 那一段**之后**插入:

```gdscript
# ── 本地状态横幅(阶段 3,spec §4 的 3.2 + 3.4)──
# ★ 它**只有一个数据源**:本文件的断线重连状态机。服务器侧的「谁掉线了」走 `round_state`
#   的 `grace` 字段(那是另一条链,见 `MatchState.grace_snapshot`),两者刻意不共用同一个节点
#   —— 一条是"我这边断了",一条是"对面断了",同时显示会互相覆盖。
# ★ 它由 `_subscribe_reconnect()` 里建(三个子类**都已经**在各自 `_ready` 里调它)——
#   **不加新调用点**,也就不存在"某个模式漏调 ⇒ 那个模式静默没有提示"这一档。
var _banner: StatusBanner = null
```

在 `_subscribe_reconnect()`(`scenes/pvp_match_client.gd:788`)的函数体**末尾**追加一行:

```gdscript
	_setup_status_banner()   # 本地状态横幅(3.2 / 3.4);建在这里 = 三个模式零新调用点
```

在 `_subscribe_reconnect()` **之后**插入两个新函数:

```gdscript
# 建横幅(幂等)。★ 必须从**场景**实例化:层位 140 只住在 `ui/status_banner.tscn` 里,
# `.new()` 建出来的是 CanvasLayer 默认的 **layer 1** —— 画在三个对局 HUD(130)与小地图(131)
# **底下**,横幅被盖住且**不报错**。守卫:`tests/hud_declarative_probe.gd` 的 ⑧。
func _setup_status_banner() -> void:
	if _banner != null:
		return
	_banner = preload("res://ui/status_banner.tscn").instantiate() as StatusBanner
	add_child(_banner)


# 设/清横幅文字(空串 = 收起)。见 `_banner` 上方那段。
func _set_status(text: String) -> void:
	if _banner != null:
		_banner.set_text(text)
```

把 `_begin_reconnect()` 里 `_reconnecting = true` 那一段(`scenes/pvp_match_client.gd:854-855`)替换为:

```gdscript
	_reconnecting = true
	# ★ 阶段 3(3.2 / 3.4):**断开一被侦测到就亮横幅**,而不是等某次重试失败之后。
	#   这正是 3.4 说的"重连失败**之前**的可见反馈" —— 阶段 1 只打了 print。
	_set_status("与服务器断线,正在重连…")
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
```

把 `_on_reconnect_retry_tick()` 的首行守卫(`scenes/pvp_match_client.gd:930-932`)后面插入:

```gdscript
	# 横幅上显示**还剩多少预算**(spec §4 的 3.2/3.4:失败之前就要有可见反馈)。
	# ★ 读的是 `GraceWindow.DEFAULT_SECONDS` —— 与下面那条收场判据**同一个常量**,不会漂。
	var left := int(GraceWindow.DEFAULT_SECONDS) \
			- int((Time.get_ticks_msec() - _reconnect_started_ms) / 1000)
	_set_status("与服务器断线,正在重连…(剩余 %ds)" % maxi(left, 0))
```

把 `_on_resumed()` 里 `_attempt_started_ms = 0` 那一行(`scenes/pvp_match_client.gd:977`)**之后**插入:

```gdscript
	_set_status("")   # 重连成功 → 收起横幅(阶段 3)
```

把 `_abort_reconnect()`(`scenes/pvp_match_client.gd:1008`)整段替换为:

```gdscript
func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	# ★ 先收起横幅再换场:换场是 `await` 一帧的(`safe_change_scene` 的防重入首行),留着文字
	#   只会在主菜单上闪一帧,读起来像 bug。原因本身仍留在下面那行 `print` 里(以及调用方
	#   写在 `reason` 里的那句话)。
	_set_status("")
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)
```

把 Task 2 里写下的 `_cancel_reconnect()` 的最后一行补上(它当时是空的):

```gdscript
func _cancel_reconnect() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")   # 「对手已离开」是终局:横幅一并收起,让位给 HUD 的中央播报
```

- [ ] **Step 4: `hud_declarative_probe`:④ 抽成参数化助手 + 新增 ⑧ + PAIRS 加一行**

把 `tests/hud_declarative_probe.gd` 的 `PAIRS` 常量(第 51-56 行)整段替换为:

```gdscript
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
	["res://ui/combat_feedback.gd", "res://ui/combat_feedback.tscn", "CombatFeedback"],
	["res://ui/team_hud.gd", "res://ui/team_hud.tscn", "TeamHud"],
	["res://ui/match_result.gd", "res://ui/match_result.tscn", "MatchResult"],
	# 阶段 3(2026-09-28):层位 140,挂在 `scenes/pvp_match_client.gd` 的 `_setup_status_banner()`。
	["res://ui/status_banner.gd", "res://ui/status_banner.tscn", "StatusBanner"],
]
```

把 `_check_result_scene_instantiation()` 的函数体(`tests/hud_declarative_probe.gd:158-182`)整段替换为
"一层薄转发 + 一个抽出来的参数化助手":

```gdscript
func _check_result_scene_instantiation() -> void:
	var before := _failures.size()
	_scan_forbidden_literal(RESULT_SCAN_ROOT, RESULT_FORBIDDEN, "MatchResult",
			"layer = 150 只写在 ui/match_result.tscn 里,用 .new() 会落到 CanvasLayer 默认的 layer 1,"
			+ "结算页画在 HUD(130)/小地图(131)下面且压暗罩盖不住(静默,只能靠眼睛看出来)。要从场景实例化。")
	_summary(before, "结算页实例化:%s 的零 %s 断言" % [RESULT_SCAN_ROOT, RESULT_FORBIDDEN])


# ── ⑧ 状态横幅同理:`res://scenes/` 下零 `StatusBanner.new(`(阶段 3,2026-09-28)──────
# ★ 与 ④ 是**同一条规则**(CanvasLayer 的层位只住在 .tscn 里,`.new()` 落到 layer 1 且静默),
#   故共用下面那个参数化助手 —— 抄第二份扫描函数就是"第二份真相"。
# ★ 扫描面也是**走盘**而不是手写清单:接线点在**基类** `scenes/pvp_match_client.gd`
#   (`_setup_status_banner`),三个子类一行都不改 —— 手写清单必然写错对象(④ 的成因)。
const BANNER_FORBIDDEN := "StatusBanner.new("


func _check_banner_scene_instantiation() -> void:
	var before := _failures.size()
	_scan_forbidden_literal(RESULT_SCAN_ROOT, BANNER_FORBIDDEN, "StatusBanner",
			"layer = 140 只写在 ui/status_banner.tscn 里,用 .new() 会落到 CanvasLayer 默认的 layer 1,"
			+ "横幅画在三个对局 HUD(130)/小地图(131)底下、被盖住(静默,只能靠眼睛看出来)。要从场景实例化。")
	_summary(before, "状态横幅实例化:%s 的零 %s 断言" % [RESULT_SCAN_ROOT, BANNER_FORBIDDEN])


# 走盘扫 `root` 下全部 .gd,**剥注释后**断言 `literal` 零命中。读不到源文件一律报红
# (contains 断言在它身上恒假 —— 那正是这类探针最典型的失明方式)。
func _scan_forbidden_literal(root: String, literal: String, cls: String, why: String) -> void:
	var all := _collect([root])
	var files: Array[String] = []
	for p in all:
		if str(p).ends_with(".gd"):
			files.append(p)
	# ★ 下限守卫:走盘走空(目录改名/被排除)时下面那条 `for` 一次都不转 ⇒ 恒绿。
	_check(files.size() >= 1,
			"%s 下扫到 0 个 .gd(判据退化:走盘走空 ⇒ 「零 %s」恒真)" % [root, literal])
	var hits: Array[String] = []
	var unreadable: Array[String] = []
	for p in files:
		var code := _code_only(_read(p))
		if code.is_empty():
			unreadable.append(p)
			continue
		if code.contains(literal):
			hits.append(p)
	_check(unreadable.is_empty(), "读不到这些源文件(contains 断言在它们身上恒假):%s" % ", ".join(unreadable))
	_check(hits.is_empty(),
			"这些文件用了 %s:%s —— %s" % [cls + ".new(", ", ".join(hits), why])
```

在 `_ready()`(`tests/hud_declarative_probe.gd:69-81`)里 `_check_result_scene_instantiation()` 那一行**之后**插入:

```gdscript
	_check_banner_scene_instantiation()
```

- [ ] **Step 5: 跑 `hud_declarative_probe` —— 必须 ALL-OK**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | tail -20
```
Expected: `KH HUD PROBE: ALL-OK`。

- [ ] **Step 6: 反向验证 ⑧(定向变异)**

把 `scenes/pvp_match_client.gd` 的 `_setup_status_banner()` 那一行临时改成:

```gdscript
	_banner = StatusBanner.new()   # 变异:.tscn 里的 layer 140 没了
```

重跑 Step 5 的命令。Expected: 出现一条
`这些文件用了 StatusBanner.new(:res://scenes/pvp_match_client.gd —— layer = 140 只写在 …`;
而 ④(MatchResult)那一组**不受影响**。验证完**还原**并重跑确认回到 ALL-OK。

- [ ] **Step 7: 状态探针加横幅的行为相**

在 `tests/reconnect_status_probe.gd` 里:

(a) 顶部常量区加:

```gdscript
# ★ 本探针是**活的**文件:每加一相加一次这个数(见文件头),判断标准是"实跑 == 期望"。
#   本 Task 加的两相加 **10** 条(`_check_status_banner` 5 条 + `_check_status_call_sites` 5 条)
#   ⇒ 17 + 10 = **27**。
```
并把 `const EXPECTED_CHECKS := 17` 改成 `:= 27`。

(b) 在 `_check_cancel_wiring()` 的函数**之后**(文件末尾 `_finish()` 之前)新增两个函数:

```gdscript
# ── 相③:横幅的行为面(建得出来、层位对、能显能收)──
# ★ 它**必须真建一个** PvpMatchClient 子类实例:纯源码断言拦不住"`.new()` 出来的 layer 是 1"
#   这一类 —— 而那正是这条横幅最容易踩、且**完全静默**的坑(层位只住在 .tscn 里)。
# ★ 用桩子而不是真 `pvp_game.tscn`:真场景会建整个世界 + 连 NetBus 发 `match_sync`,
#   而本相要验的只是"横幅挂上去了没有、层位对不对"。桩子只提供基类的那一段接线。
class ClientStub extends PvpMatchClient:
	pass


func _check_status_banner() -> void:
	var stub := ClientStub.new()
	add_child(stub)
	# 生产入口:三个子类都是在 `_ready` 里调它的(Task 2 的守卫另有源码断言钉着这一点)。
	stub._subscribe_reconnect()
	var banner := stub.get_node_or_null("StatusBanner") as StatusBanner
	_check(banner != null,
			"★ `_subscribe_reconnect()` 没有把横幅挂上去(三个模式会一起静默没有提示)")
	if banner == null:
		stub.queue_free()
		return
	# ★★ 层位:这是 `.tscn` 里那个 `layer = 140` 的**行为**判据。写成 `.new()`、或者有人
	#   从 .tscn 里删掉那一行,这里当场红 —— 而源码断言一条都照不到(值在 .tscn 里)。
	_check(banner.layer == 140,
			"★ 横幅层位必须是 140(实得 %d);层位只住在 ui/status_banner.tscn 里" % banner.layer)
	# 显 / 收
	stub._set_status("与服务器断线,正在重连…(剩余 42s)")
	_check(banner._panel.visible and banner._label.text.contains("42s"),
			"设了文字就应该可见且文字正确(visible=%s text=%s)"
			% [str(banner._panel.visible), banner._label.text])
	stub._set_status("")
	_check(not banner._panel.visible, "空串必须收起横幅(visible=%s)" % str(banner._panel.visible))
	# ★ 反向:文字为空但面板仍可见 = "永远挂着一块空黑板",是本类最容易出的错
	stub._set_status("正在重连…")
	_check(banner._panel.visible, "非空文字必须重新亮出来(否则收起之后再也回不来)")
	stub.queue_free()


# ── 相④:四个转折点真的驱动了横幅(源码面)──
# 行为面只能验"设了文字会显示",验不了"状态机在四个转折点上真的调了它" ——
# 后者是"删掉不报错"的一类,必须机械钉住。
func _check_status_call_sites() -> void:
	for fn in ["_begin_reconnect", "_on_reconnect_retry_tick", "_on_resumed", "_abort_reconnect",
			"_cancel_reconnect"]:
		var body := _body(CLIENT_BASE, fn)
		_check(body.contains("_set_status("),
				"★ `%s` 没调 `_set_status(`(那个转折点的提示会静默消失)" % fn)
```

(c) 在 `_ready()` 里 `_check_cancel_wiring()` 那一行**之后**依次加两行:

```gdscript
	_check_status_banner()
	_check_status_call_sites()
```

★ `class ClientStub` 的声明位置:`GDScript` 的 `class` 是**缩进 0 的顶层语句**,放在两个函数
之间是合法的(`tests/hud_declarative_probe.gd` 的 `class ResultPayloadStub` 就是写在文件中间的,
照那个先例)。

★ **报红时先数条数再改常量**:`KH RECON-UI PROBE: FAIL` 里那条「只跑了 N 条断言(期望 ≥ M)」
就是本探针防"整组被跳过"的手段。若 M 与实跑的 N 不符,**先把输出里的 `ok`/`FAIL` 行数一遍**,
确认是自己写漏了一条断言(而不是实现少跑了一组),再改 `EXPECTED_CHECKS`。

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn 2>&1 | tail -40
```
Expected: `KH RECON-UI PROBE: ALL-OK(27 条断言)`。**实得条数必须是 27** —— 不是就按上面那句先数再改。

- [ ] **Step 8: 提交**

```bash
git add ui/status_banner.gd ui/status_banner.tscn scenes/pvp_match_client.gd \
        tests/hud_declarative_probe.gd tests/reconnect_status_probe.gd
git commit -F - <<'EOF'
feat(reconnect): 3.2 + 3.4 —— 断线/重连的本地状态横幅（ui/status_banner，layer 140）

阶段 1 把「重连中」降级成 print，理由是当时"没有一个能挂上去的节点"（pvp_game / royale_game /
team_game 是 Node2D，而 `UiFactory.panel_box()` 返回 StyleBoxFlat 不是节点）。本批把它补上。

- 新 `ui/status_banner.tscn/.gd`：CanvasLayer **layer = 140**（高于 HUD 130 / 小地图 131，
  低于暂停菜单 145 / 结算页 150）。面板与文字由 `_ready()` 用 UiFactory 建（与
  `ui/match_result.tscn` 同一种取舍：裸骨架 tscn + 代码建面板）。根 Control 与面板都是
  MOUSE_FILTER_IGNORE —— 横幅只给人看，绝不吃点击。
- `PvpMatchClient`：`_banner` / `_setup_status_banner()` / `_set_status(text)`；建在**已有的**
  `_subscribe_reconnect()` 里 ⇒ 三个模式**零新调用点**（不存在"某模式漏调"那一档）。
  四个转折点接上：`_begin_reconnect`（亮）/ `_on_reconnect_retry_tick`（报剩余预算）/
  `_on_resumed`（收）/ `_abort_reconnect`（收）；`_cancel_reconnect` 也收（3.3 的终局）。
  ⇒ 3.4 要的"重连失败**之前**的可见反馈"由第一处提供，不再只靠 print。
- `tests/hud_declarative_probe`：④ 的**扫描体**抽成参数化助手 `_scan_forbidden_literal`
  （④ 的那两条 `_check` 与判词**一字不改**，只把走盘/剥注释/读不到报红那段收成共用助手），
  新增 ⑧ 用同一助手钉 `StatusBanner.new(`；PAIRS 加一行（@onready 契约 + 零 .new）。
- `tests/reconnect_status_probe`：+横幅行为相（**真建**一个 PvpMatchClient 子类实例，
  断言层位 == 140 —— 那是 .tscn 里的值，源码断言一条都照不到）+ 四个转折点的调用点断言。
EOF
```

---

### Task 5: 3.1 的客户端半 —— 两个 HUD 把「掉线中」画出来

**Files:**
- Modify: `ui/ui_factory.gd`(新增 `C_GRACE`)
- Modify: `ui/pvp_hud.tscn`、`ui/pvp_hud.gd`(1v1 半)
- Modify: `ui/royale_hud.gd`(大乱斗半)
- Modify: `tests/combat_hud_visual_probe.gd`(真渲染、用户跑)
- Modify: `tests/reconnect_status_probe.gd`

**Interfaces:**
- Consumes: `round_state` 的 `grace` 键(Task 3)、`GraceWindow.tick_display`(Task 1)、既有 `UiFactory.C_*`。
- Produces: `UiFactory.C_GRACE: Color`;`PvpHud._grace: Dictionary` + `PvpHud._refresh_grace()`;`RoyaleHud._grace: Dictionary`。

- [ ] **Step 1: 调色板加第四种语义色**

在 `ui/ui_factory.gd` 的 `const C_WARN        := Color(0.950, 0.850, 0.550)   # 金色:**只**用于「低弹量/耗尽」语义`
那一行(第 102 行)**之后**插入:

```gdscript
# ── 断线「掉线中」语义色(阶段 3,2026-09-28)──
# **只**给「某人掉线中,还在宽限期内、可能会回来」这一个语义用。
# ★ 为什么不复用现成的三档:`C_WARN`(金)被钉死为「弹夹见底」单一语义;`C_DANGER`(红)已表
#   「离开」(**不可逆**的终态);`C_TEXT_DIM` 已表「复活中」(对局内的正常状态)。
#   「掉线中」是第四种:可能回来、也可能不回来 —— 单独一档,免得被读成上面任何一种。
# ★★ **如实记对比度,不声称达标**(口径与 `C_TEAM_A` 那段同一套:WCAG 相对亮度)。
#   底板 = `C_PLATE` 压在地图开阔区 #78969F 上 ≈ **#6C8790**(L=0.2253):
#     本色 `#B89EE6` → **1.65:1**      ← 达不到大字下限 3:1
#   ★ 达不到**不是这一档的问题**:L=0.2253 的底上要凑够 3:1,文字亮度得 ≥0.775(近白)或
#     ≤0.042(近黑)—— 本项目自己的标准文本色 `C_TEXT` 也只有 3.11:1。
#   ★ 大乱斗的排行榜那一行是画在 `_board_bg`(**黑 0.25**)上的,底更暗:本色 **2.24:1**,
#     而既有那两档更低(「离开」的 `C_DANGER` 只有 **1.59:1**、「复活中」的 `C_TEXT_DIM` 更低)
#     —— 即本档在排行榜上比既有两档都**更显眼**,这是它取这个亮度的全部理由。
#   ★ 色值是**审美值**,以实图为准:`tests/combat_hud_visual_probe` 会连同既有几档一起取图,
#     由人眼验收("一眼能从满屏文字里挑出掉线的那一行")。要调整就调这一个数。
const C_GRACE       := Color(0.72, 0.62, 0.90)      # #B89EE6
```

- [ ] **Step 2: 排版守卫先看一眼(改了 `res://ui` 必须跑)**

Run:
```bash
source tests/env.sh
timeout 200 "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l4_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
timeout 200 "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd 2>&1 | tail -3
```
Expected: `KH L4 PROBE: ALL-OK` / `KH L5 PROBE: ALL-OK` / `UI PALETTE: ALL-OK`(三条都必须绿 ——
`C_GRACE` 不是 `Color(0, 0, 0, 0.1)`,调色板守卫 ⑤ 的"零游离底板色字面量"不受影响)。

- [ ] **Step 3: `pvp_hud.tscn` 加一条「对手掉线中」**

在 `ui/pvp_hud.tscn` 的 `[node name="ScoreLabel" ...]` 那一块**之后**、`[node name="PingWrap" ...]`
那一行**之前**插入:

```
; 「对手掉线中」(阶段 3,spec §4 的 3.1)。★ 与记分条**共用**同一个 Plate SubResource
;   ⇒ **不新增任何 bg_color 字面量**, ui_palette_single_source_smoke 的 ④(读第一条 bg_color)
;   与 ⑤(零游离字面量)都不受影响。
;   ★ 颜色**不在这里写**:由 ui/pvp_hud.gd 的 _ready 从 UiFactory.C_GRACE 取(调色板单一来源)。
;   ★ 位置:记分条(offset_top 16,高约 48)之下,offset_top = 72;状态横幅(layer 140)在 128。
[node name="GraceWrap" type="PanelContainer" parent="."]
visible = false
anchor_left = 0.5
anchor_right = 0.5
offset_top = 72.0
grow_horizontal = 2
grow_vertical = 1
mouse_filter = 2
theme_override_styles/panel = SubResource("Plate")

[node name="GraceLabel" type="Label" parent="GraceWrap"]
mouse_filter = 2
horizontal_alignment = 1
theme_override_font_sizes/font_size = 32
theme_override_fonts/font = ExtResource("2")
text = ""
```

- [ ] **Step 4: `pvp_hud.gd` 消费 `grace`**

把 `ui/pvp_hud.gd` 的 `@onready` 段(第 15-20 行)**之后**、`var _countdown := 0.0` 之前插入:

```gdscript
@onready var _grace_wrap: PanelContainer = $GraceWrap
@onready var _grace_label: Label = $GraceWrap/GraceLabel
```

并在 `var _in_countdown := false` 那一行**之后**插入:

```gdscript
# 「对手掉线中」(阶段 3,spec §4 的 3.1):role(int) -> 剩余秒。
# ★ 服务器只在**状态转折点**广播 `grace`,两次之间由本类**自己走秒**(与下面 `_countdown`
#   同款口径);那份减法的唯一实现是 `GraceWindow.tick_display`(别在这里手写一份)。
var _grace: Dictionary = {}
```

把 `_ready()` 整段替换为:

```gdscript
func _ready() -> void:
	PixelFont.shared()   # 一次:共享字体关抗锯齿/微调/子像素,本场景所有像素 Label 全局锐利
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	# 颜色只从调色板取(本次新增的第四种语义色,见 UiFactory.C_GRACE 那段的对比度实测)
	_grace_label.add_theme_color_override("font_color", UiFactory.C_GRACE)
	_set_broadcast(true, "对战开始", "第 1 局")
```

把 `_process(delta)` 整段替换为:

```gdscript
# 倒计时数字本地走秒(服务器只在状态切换时广播一次 round_state);
# 「对手掉线中」的秒数同理 —— 两者共用一个 `_process`。
func _process(delta: float) -> void:
	if _in_countdown:
		_countdown -= delta
		if _countdown > 0.0:
			_big.text = str(maxi(ceili(_countdown), 1))
		else:
			_in_countdown = false
	# ★ 不受 `_in_countdown` 的早退影响(上面那两行是**缩进在 if 里**的,别改成早退):
	#   掉线可能发生在倒计时里,那时这两个数字都要各自走秒。
	if not _grace.is_empty():
		_grace = GraceWindow.tick_display(_grace, delta)
		_refresh_grace()
```

在 `_on_round_state` 的**首行**(`var state: int = data.get("state", ST_PLAYING)`)**之前**插入:

```gdscript
	# 「对手掉线中」(阶段 3,spec §4 的 3.1):载荷里 `grace` = {role -> 剩余秒}。
	# ★ **缺键 = 此刻没人掉线**(服务端空表不带上该键,见 `GraceWindow.merge_into`)——
	#   不是"未知",也不是错误。老客户端忽略未知键、新客户端拿到缺键都走同一支。
	_grace = data.get("grace", {})
	_refresh_grace()
```

在 `_on_round_state` 的**末尾**(函数最后一个缩进块之后)追加:

```gdscript
	_refresh_grace()   # 本帧的权威值覆盖本地走秒的结果(服务器值恒是新的)
```

在 `_process` **之后**插入:

```gdscript
# 「对手掉线中,等待重连… 剩余 Ns」。
# ★ 1v1 的对手 role 恒为 `3 - 自己`(与副本、击杀播报、P2 染色同源)。
# ★ 判据写 `has(opp)` 而**不是**"取 `_grace` 的第一个键":后者在将来多出一个 role 时
#   (比如观战位)会印错人,而且**不报错**。
func _refresh_grace() -> void:
	var opp := 3 - PvpSession.role
	var has_opp: bool = _grace.has(opp)
	_grace_wrap.visible = has_opp
	if has_opp:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % int(ceilf(float(_grace[opp])))
```

- [ ] **Step 5: `royale_hud.gd` 给排行榜加「掉线」那一档**

在 `ui/royale_hud.gd` 的 `const COLOR_LEFT := UiFactory.C_DANGER` 那一行(第 19 行)**之后**插入:

```gdscript
# 「掉线中」= 还在宽限期内、**可能回来**(阶段 3,spec §4 的 3.1)。
# ★ 与上三档是并列的第四种语义,故用调色板里新加的那一档(理由与实测对比度见
#   `UiFactory.C_GRACE` 那段)。别为了省一个常量把它并进任何一档。
const COLOR_GRACE := UiFactory.C_GRACE
```

在 `var _state := ST_COUNTDOWN` 那一行(第 55 行)**之后**插入:

```gdscript
# role(int) -> 剩余秒(**只由服务器下发**)。★ 大乱斗的 `RoyaleHost` 本来就 **1Hz 广播**
# `round_state`(HUD_SYNC_INTERVAL),而 `server_main` 也是每秒刷一次读数 ⇒ 这里的值恒新,
# **不需要** 1v1 那样的本地走秒(`GraceWindow.tick_display`)。两侧必要性的差异是**实测**的:
# 1v1/3v3 只在状态转折时广播,故它们那边必须本地走 —— 别为了"统一"给大乱斗也加一遍。
var _grace: Dictionary = {}
```

把 `_on_round_state` 整段替换为:

```gdscript
func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", ST_PLAYING))
	_state = state
	var names: Dictionary = data.get("names", {})
	var alive: Dictionary = data.get("alive", {})
	var left: Array = data.get("left", [])
	var deaths: Dictionary = data.get("deaths", {})
	var scores: Dictionary = data.get("scores", {})
	# ★ **缺键 = 此刻没人掉线**(服务端空表不带上该键,见 `GraceWindow.merge_into`)。
	_grace = data.get("grace", {})
	var rows := _refresh_board(names, scores, deaths, alive, left, _grace, state)
	_refresh_broadcast(state, data, names, rows, alive)
```

`_refresh_board` 只改**两处** —— 其余部分(签名与 `var rows: Array = []` 之间那几行、
`if _rows.size() != _last_row_count:` 那一整段、`for i in range(rows.size()):` 的开头)**一字不动**。

**改法一 —— 签名那一行**(现 `ui/royale_hud.gd:162-163`),**整两行**替换为下面那两行(只多一个形参):

```gdscript
func _refresh_board(names: Dictionary, scores: Dictionary, deaths: Dictionary,
		alive: Dictionary, left: Array, grace: Dictionary, state: int) -> Array:
```

**改法二 —— 行的标签/配色那一段**(现 `ui/royale_hud.gd:193-200`,从 `var tag := "存活"` 起、
到 `col = COLOR_DEAD if not is_me else COLOR_ME` 止)**整段**替换为:

```gdscript
		var tag := "存活"
		var col := COLOR_BOARD if not is_me else COLOR_ME
		if left.has(e["role"]):
			tag = "离开"
			col = COLOR_LEFT
		elif grace.has(e["role"]):
			# 「掉线」= 还在宽限期内、可能会回来(阶段 3,spec §4 的 3.1)。
			# ★ 排在「离开」**之后**:离开是终态(`mark_disconnected` 已把它移出对局),
			#   而两者在**同一帧**都可能成立(服务器刚 `_grace.leave` 完就 `mark_disconnected`,
			#   载荷里的 `grace` 已不含他 —— 但万一快照旧了一拍,「离开」才是该显示的那个)。
			# ★★ 标签**刻意取短**:这一行本来就贴着面板宽(9 字昵称实测 ≈690px / 面板 720),
			#   「掉线 42s」(8 半角单位)比既有的「复活中」(6 单位)只多 2 单位。
			#   **不要**改成「掉线中,等待重连…」那种长句 —— 会把末段顶出面板(`clip_text`
			#   静默裁掉,不是崩)。
			tag = "掉线 %ds" % int(ceilf(float(grace[e["role"]])))
			col = COLOR_GRACE
		elif not bool(alive.get(e["role"], true)) and state == ST_PLAYING:
			tag = "复活中"
			col = COLOR_DEAD if not is_me else COLOR_ME
```

- [ ] **Step 6: 加冒烟/探针断言(把 HUD 消费变成机械可查)**

在 `tests/reconnect_status_probe.gd` 里加:

```gdscript
# ── 相⑤:两个 HUD 真的消费了 `grace`(阶段 3 的 3.1 客户端半)──
# ★ 3v3 **刻意不消费**(spec §4 的 3.1 只点了大乱斗与 1v1):6 人一队,单行"对手状态"没有意义。
#   这是一条**有意的不对称**,故这里也断言 `team_hud` 不掉进"顺手套一份"的坑 ——
#   它要是也消费了,说明有人把 `grace` 当成了通用字段。
func _check_hud_consumers() -> void:
	var pvp := _code(PVP_HUD)
	_check(pvp.contains("GraceWindow.tick_display("),
			"★ pvp_hud 没有本地走秒(`GraceWindow.tick_display` 是那份减法的唯一实现)")
	var body := _body(PVP_HUD, "_refresh_grace")
	_check(body.contains("3 - PvpSession.role"),
			"★ `_refresh_grace` 没按「对手 role = 3 - 自己」取数(实得「%s」)" % body)
	_check(body.contains("_grace.has(opp)"),
			"★ `_refresh_grace` 必须是 `has(opp)` 判定,不能「取第一个键」(多一个 role 时会印错人)")
	var roy := _code(ROYALE_HUD)
	_check(roy.contains("UiFactory.C_GRACE"),
			"★ royale_hud 的「掉线」那一档没有引调色板的新色")
	_check(roy.contains("_refresh_board(") and roy.contains("grace: Dictionary"),
			"★ `_refresh_board` 没有把 `grace` 收进去")
	_check(not _code(TEAM_HUD).contains("grace"),
			"★ team_hud 也在消费 `grace` —— 3v3 **刻意不做**(spec §4 的 3.1 只点大乱斗与 1v1);"
			+ "要做也是在结算/记分条上另设计,不是这条单行状态")
```

★ 常量区补三个路径常量:

```gdscript
const PVP_HUD := "res://ui/pvp_hud.gd"
const ROYALE_HUD := "res://ui/royale_hud.gd"
const TEAM_HUD := "res://ui/team_hud.gd"
```

`_ready()` 里在 `_check_status_call_sites()` **之后**加 `_check_hud_consumers()`;
`EXPECTED_CHECKS` 由 **27** 抬到 **33**(本相加 6 条;判据是"实跑 == 期望且 ALL-OK")。

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_status_probe.tscn 2>&1 | tail -40
```
Expected: `KH RECON-UI PROBE: ALL-OK(33 条断言)`。

- [ ] **Step 7: 扩展真渲染探针(★ 用户跑、读图)**

在 `tests/combat_hud_visual_probe.gd` 的 1v1 与 大乱斗两段**各自**再加一次 `_on_round_state` +
取图(与既有几次并列,**不删不改**既有的):

```gdscript
	# 阶段 3(3.1):1v1 的「对手掉线中」。`grace` 的键是**对手**的 role。
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "grace": {2: 42.0}})
	# …既有那次 `_save("pvp_grace")` 同款的取图调用…
```
```gdscript
	# 阶段 3(3.1):大乱斗排行榜的「掉线 42s」那一行(role 2 掉线中,自己(role 1)排第一)。
	royale._on_round_state({"state": 1, "round": 1, "scores": {1: 7, 2: 3, 3: 1},
			"deaths": {1: 0, 2: 1, 3: 2}, "rounds_won": {}, "timer": 214.0,
			"names": {1: "阿甲", 2: "bob", 3: "电脑玩家3-computer"},
			"alive": {1: true, 2: false, 3: true}, "left": [], "grace": {2: 42.0}})
	# …既有那次 `_save("royale_grace")` 同款的取图调用…
```

★ 具体的 `_save`/取图调用**照抄同一文件里相邻那两次**(本探针的取图写法只有一个,别新造)。
★ **必须真渲染跑**(不加 `--headless`),命令与既有那几次相同 —— 由**用户**跑并读图:

```bash
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn
```
Expected: `COMBAT HUD VISUAL PROBE: ALL-OK`,且两张新图里:
① 1v1 的「对手掉线中,等待重连… 剩余 42s」在记分条**正下方**、不与记分条重叠;
② 大乱斗排行榜里 role 2 那一行念「掉线 42s」,**末段没有被裁掉**(`clip_text` 会静默裁)。
★ 图**自己读**(探针存的那几张 png),别推回给用户。

- [ ] **Step 8: 提交**

```bash
git add ui/ui_factory.gd ui/pvp_hud.gd ui/pvp_hud.tscn ui/royale_hud.gd \
        tests/combat_hud_visual_probe.gd tests/reconnect_status_probe.gd
git commit -F - <<'EOF'
feat(reconnect): 3.1 客户端半 —— 1v1 记分条下的「对手掉线中」与大乱斗排行榜的「掉线 Ns」

- `UiFactory.C_GRACE`：调色板新增**第四种语义色**（金=弹夹见底 / 红=离开 / 灰=复活中 都已被
  占用，"掉线中"是"可能回来也可能不回来"的第四种）。★ 如实记对比度（底板 1.65:1、
  排行榜底 2.24:1 —— **都达不到 3:1**，与既有几档同一量级；`C_DANGER` 在排行榜上只有 1.59:1，
  故本档反而**更显眼**，这是取这个亮度的全部理由）。
- `ui/pvp_hud.tscn/.gd`：记分条正下方新增 `GraceWrap/GraceLabel`（**复用**既有的 `Plate`
  SubResource ⇒ 不新增任何 bg_color 字面量，调色板守卫的 ④/⑤ 不受影响）；
  按「对手 role = 3 - 自己」取数；缺键 = 没人掉线（服务端空表不带键）。
  ★ 秒数本地走秒（1v1 只在转折点广播 round_state），实现走 `GraceWindow.tick_display`。
- `ui/royale_hud.gd`：`_refresh_board` 收 `grace`，标签档位 离开 > **掉线** > 复活中 > 存活；
  标签取「掉线 42s」（8 半角单位）而不是长句 —— 那一行本来就贴着面板宽（`clip_text` 会静默裁）。
- 3v3 **刻意不消费**（spec §4 的 3.1 只点大乱斗与 1v1；6 人一队时单行"对手状态"没有意义），
  探针有一条反向断言钉住这个不对称是有意的。
- `tests/combat_hud_visual_probe`：+两组带 `grace` 的载荷与取图（真渲染，用户跑并读图）。
EOF
```

---

### Task 6: 全量回归 + `CLAUDE.md` 同步

**Files:**
- Modify: `CLAUDE.md`
- (无生产代码改动)

**Interfaces:**
- Consumes: Task 1–5 的全部产物。
- Produces: 无。

- [ ] **Step 1: agent 可跑的那一半回归**

Run:
```bash
source tests/env.sh
for t in enemy_logic_smoke player_contract_smoke weapon_inventory_smoke grace_window_smoke; do
  echo "--- $t ---"; timeout 300 "$GODOT" --headless --path . -s "res://tests/$t.gd" 2>&1 | grep -E "OK|FAIL" | tail -2
done
for t in kh_l3_probe kh_l4_probe kh_l5_probe kh_l6_probe hud_declarative_probe \
         rpc_liveness_probe grace_feed_probe reconnect_status_probe lobby_visibility_probe; do
  echo "--- $t ---"; timeout 400 "$GODOT" --headless --path . --quit-after 3600 "res://tests/$t.tscn" 2>&1 | grep -E "ALL-OK|FAIL" | tail -2
done
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd 2>&1 | tail -3
```
Expected: 逐个 `SMOKE OK` / `CONTRACT OK` / `WEAPON_INVENTORY OK` / `GRACE_WINDOW OK` /
`KH L* PROBE: ALL-OK` / `KH HUD PROBE: ALL-OK` / `KH RPC-LIVE PROBE: ALL-OK` /
`GRACE FEED PROBE: ALL-OK` / `KH RECON-UI PROBE: ALL-OK` / `LOBBY VISIBILITY PROBE: ALL-OK` /
`UI PALETTE: ALL-OK`。**无 FAIL。**

★ `kh_l4` / `kh_l5` / `hud_declarative_probe` / `rpc_liveness_probe` 是**必须**的:
前两个扫 `res://ui` 与 `res://tests`(本计划在这两个目录里都改了文件),
第三个管新场景的声明式契约,第四个管新发送点的判活。
★ `kh_l6_probe` 必须绿:它第 9 条钉 `pvp_game` 的 MATCH_OVER 块 —— 本计划**没动**那块;
它绿着说明没有越界。

- [ ] **Step 2: 请用户跑三支真链路/真渲染探针**

Run:
```bash
source tests/env.sh
# ① 真链路(约 72~110s;起子进程,收尾按 PID 杀;跑前确认 7777 空闲)
timeout 400 "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn
# ② 真渲染(会弹窗,不能加 --headless)
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn
# ③ 真渲染(既有,确认没被波及)
"$GODOT" --path . --quit-after 3600 res://tests/kh_l3_visual_probe.tscn
```
Expected: `RECONNECT PROBE: ALL-OK` / `COMBAT HUD VISUAL PROBE: ALL-OK` /
`KH L3 VISUAL: ALL-OK`。

★ **跑完之后 `tasklist | grep -i godot` 应为空**;非空按 `tests/env.sh` 的 `kill_port_range` 清孤儿。

- [ ] **Step 3: 人工验收(三条,缺一不可)**

1. **3.3 的端到端**(1v1):两台客户端进 1v1,一方直接关进程(不要按 ESC —— 那不会触发 `peer_left`
   的宽限路径)。另一方应该看到:记分条下方出现「对手掉线中,等待重连… 剩余 Ns」并**逐秒递减**;
   60 秒后出现「对手已离开 / 对局结束」,**2.5 秒后**回到主菜单 —— **不是**继续转一分钟。
2. **3.2 / 3.4**(1v1):一方把网线拔掉/关掉 worker 进程的宿主网络,自己那台应该在**断开被察觉的
   那一刻**立刻看到顶部横幅「与服务器断线,正在重连…(剩余 Ns)」;恢复网络后横幅消失。
3. **3.1 的大乱斗**:一局大乱斗里让一名玩家掉线,排行榜上那一行应变成「掉线 Ns」;他若在
   60 秒内回来,那一行恢复成「存活」。

- [ ] **Step 4: 改 `CLAUDE.md`**

把 §网络与 PvP 的「断线重连(阶段 1:局内自动重连,2026-09-17)」那一段里以
`**仍未做**:HUD 的「掉线中/重连中」可见提示(spec §4 阶段 3)、`opponent_left` 不可达的修复 ——`
开头的整句替换为:

```markdown
★ **阶段 3 已落地(2026-09-28)**:HUD 的「掉线中/重连中」可见提示与 `opponent_left` 的调用点
都补齐了,详见下面「阶段 3」那一节。仍未做的是 spec §5 的 `RoyaleHost.start_on` 网格预载
(与重连无关的既有问题,另立评估)。
```

并在同一小节**末尾**追加一段新内容:

```markdown
#### 阶段 3:可见性 + 两个既有缺陷(2026-09-28)

四处,三条互不重叠的链:

- **3.1 「掉线中」= `round_state` 长出 `grace` 字段**(`{role(int) -> 剩余秒(float)}`)。★ 它的
  **唯一出口是 `MatchState._send_round_state(data)`**(三个生产者 `MatchRound` / `RoyaleHost` /
  `TeamHost` 都调它)⇒ 生产目录里 `_rpc_all("round_state"` **零命中**(守卫 `tests/grace_feed_probe`
  的 ④)。读数的**持有者是 `server_main`**(宽限期表在它手里),它经 `_sync_grace_snapshot()` 把值
  **推进**宿主的 `grace_snapshot` 字段 —— **推**而不是"宿主去问",避免一条 back-reference。
  ★ **空表不带该键**(与 `destroyed`/`teams`/`stats` 同款);三个客户端 + `match_result_payload`
  都对缺键无感(加法式扩展)。
  ★★ **1v1/3v3 不每秒广播 `round_state`** —— 三个客户端里有两处 `COUNTDOWN 且 round > 1` 的分支
  **不是幂等的**(`pvp_game` 会 `reset_destructibles()`、`team_game` 会重发 `match_sync`),
  每秒多播一次 = 倒计时 3 秒里那些活各干 3 遍。秒数由客户端**本地走秒**(`GraceWindow.tick_display`),
  与既有的倒计时同款口径。大乱斗本来就 1Hz 广播,故那边不需要本地走 —— **两侧必要性的差异是
  实测出来的,不是不一致**。
  ★ 3v3 **刻意不消费** `grace`(spec §4 的 3.1 只点大乱斗与 1v1;6 人一队时单行状态没有意义),
  有反向断言钉住这个不对称是**有意**的。
- **3.2 + 3.4 「重连中」= `ui/status_banner.tscn`(CanvasLayer layer 140)**,由**基类**
  `PvpMatchClient` 在**已有的** `_subscribe_reconnect()` 里实例化 ⇒ 三个模式**零新调用点**。
  四个转折点驱动:`_begin_reconnect`(断开被察觉就亮 = 3.4 要的"失败**之前**的反馈")/
  `_on_reconnect_retry_tick`(报剩余预算)/ `_on_resumed`(收)/ `_abort_reconnect`(收)。
  ★★ 层位 **140 只住在 `.tscn` 里** —— `.new()` 建出来是 CanvasLayer 默认的 layer 1,画在
  HUD(130)/小地图(131)**底下**且**不报错**;守卫 `tests/hud_declarative_probe` 的 ⑧。
- **3.3 `opponent_left` 不再是死路**:服务端调用点在 `server_main._notify_opponent_left()`,
  由 `_expire_graces` 的 **1v1 收场分支**在 `get_tree().quit(0)` **之前**调;只发给 `_claims`
  里还在的人,走 `NetBus.reply`(判活收口)。
  ★ 只在**收场**发、**不在 `_enter_grace` 发** —— 掉线时就宣告"对手已离开"会把阶段 1 的整条
  重连功能作废。
  ★★ **两天时序都要收口**:通知先到 ⇒ 既有的 `_match_ended` 闸挡住重连循环启动;断开先到 ⇒
  只有 `_cancel_reconnect()` 能叫停已经在飞的那个循环。⇒ 不论谁先到,结局都是「2.5s 后回主菜单」,
  **不叠加一个 60 秒的重连循环**。守卫:`tests/reconnect_status_probe` 相①② + `reconnect_probe` 相④b。
```

★ 同时在 §测试 那一段的「真链路跑批的两条纪律」列表里**不变**(本计划没有新增真链路脚本)。

- [ ] **Step 5: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 阶段 3 落地 —— 「掉线中/重连中」的 HUD、grace 字段的唯一出口、opponent_left 的调用点

把「断线重连」小节里那句「**仍未做**:HUD 的『掉线中/重连中』可见提示、opponent_left 不可达
的修复」改掉，并补一节「阶段 3」记录四条**改错了不报错**的口径：

- `grace` 字段的唯一出口是 `MatchState._send_round_state`（生产目录零 `_rpc_all("round_state"`）；
  读数的持有者是 server_main，**推**给宿主的 `grace_snapshot`（避免 back-reference）；
  空表不带键。
- ★★ 1v1/3v3 **不**每秒广播 round_state —— 两个客户端的 `COUNTDOWN 且 round > 1` 分支不是幂等的
  （reset_destructibles / 重发 match_sync），秒数改由 `GraceWindow.tick_display` 本地走；
  大乱斗本来就 1Hz 广播，故两侧必要性的差异是实测的、不是不一致。
- 3v3 **刻意不消费** `grace`（有反向断言钉住这个不对称是有意的）。
- StatusBanner 的 layer **140 只住在 .tscn 里**（`.new()` → layer 1，被 HUD 盖住且不报错）。
- opponent_left 只在 1v1 **收场**发（不在 `_enter_grace` 发，否则作废阶段 1 的重连）；
  客户端两天时序都要收口（`_match_ended` 闸 + `_cancel_reconnect()`）。
EOF
```

---

## Self-Review

**1. 覆盖面(对照 spec §4)**

| spec 要求 | 本计划 |
|---|---|
| 3.1 `round_state` 加 `grace` 字段(`{role: 剩余秒}`) | Task 1(`remaining`/`merge_into`)+ Task 3(`grace_snapshot` + `_send_round_state`) |
| 3.1 大乱斗排行榜行状态加一档 | Task 5 Step 5 + 相⑤ 断言 |
| 3.1 1v1 记分条旁显示对手状态 | Task 5 Step 3/4 + 相⑤ 断言 |
| 3.2 「重连中」本地状态驱动、不需要服务器广播 | Task 4(`StatusBanner` + 四个转折点) |
| 3.2 "把 HUD 那层设计好"(阶段 1 无处可挂) | Task 4:`ui/status_banner.tscn`(独立 CanvasLayer,**与 3.1 一起设计**,而不是塞进某个模式) |
| 3.3 补上服务端调用点(用户已裁定,不删客户端) | Task 2 Step 2 + 相①② + `reconnect_probe` 相④b |
| 3.4 重连失败**之前**的可见反馈 | Task 4:`_begin_reconnect` 就亮横幅 + 每次重试报剩余预算 |
| §5 另立评估(不在范围) | **全计划零改动** `RoyaleHost.start_on` / `plan_spawns` |
| §6 改 `NetBus` 方法表? | **零改动**(`opponent_left` 是既有 RPC,只是补调用点) |

**2. 占位符扫描**:无 TBD / "类似 Task N" / "适当处理"。每个改动都给了**完整代码块**与确切锚点
(`file:line` 已按当前树核过;**若实现时行号漂了,按内容定位** —— 代码块里的原文就是锚)。

**3. 类型/名字一致性**:
- `GraceWindow.remaining` / `merge_into` / `tick_display` 在 Task 1 定义,Task 3/4/5 只调用。
- `MatchState.grace_snapshot` / `_send_round_state` 在 Task 3 定义,`server_main` 与三个生产者使用。
- `PvpMatchClient._set_status` / `_setup_status_banner` / `_cancel_reconnect` 在 Task 2/4 定义:
  ★ **顺序上 `_cancel_reconnect` 先出现(Task 2)、`_set_status` 后出现(Task 4)** ——
  Task 2 的 `_cancel_reconnect` **暂不调** `_set_status`(调一个还不存在的函数 = 编译不过),
  Task 4 Step 3 明确补上那一行。**这是本计划唯一一处跨 Task 的函数体修改**,已在两处写明。
- `UiFactory.C_GRACE` 在 Task 5 定义并在同 Task 被两个 HUD 引用。

**4. 已知的判据上限(如实登记)**

- **真链路探针只断worker 侧那一半**:`reconnect_probe` 相④b 读的是 worker 日志("发了"),
  **照不到**"幸存者收到了"(那需要等 2.5s 的换场,与探针收工时机竞争)。客户端那一半由
  `reconnect_status_probe` 的源码/行为断言 + Task 6 Step 3 的**人工验收 ①** 覆盖。
- **"断开先到"那一半是竞态**:真链路探针**跑十次未必撞上一次**,故它的守卫是
  `reconnect_status_probe` 的 `_cancel_reconnect` 函数体断言(少复位一个量就红)+ 人工验收 ①。
- **`grace` 的秒数在 1v1 是本地走秒的估计**:服务器值最多旧 1 秒(`_sync_grace_snapshot` 每秒刷),
  故显示值与真值可能差 ≤1s —— 这是**有意**的取舍(理由见 Task 3 Step 3 的"不做的事")。
- **大乱斗排行榜那一行的宽度**:标签取「掉线 42s」是**按既有行宽预算算过**的(9 字昵称那行
  ≈690px / 面板 720);昵称更长时那一行本来就靠 `clip_text` 裁,本档只多 2 半角单位。
  真渲染图是这条的唯一验收手段(Task 5 Step 7)。
- **`C_GRACE` 达不到 3:1**:底色 1.65:1、排行榜底 2.24:1 —— 已在调色板注释里**如实写明**,
  并给出"它比既有两档更显眼"这个取值理由。色值以实图为准。

---

## 开放问题(★ 实现前请先读这一节)

1. **`server_main.gd` 的跨会话冲突**(★★ 唯一一条会阻塞落地的):另一个 Claude 会话正在改
   `server/**`。Task 2 与 Task 3 都碰 `server_main.gd`(Task 3 是"1 行 + 2 个新函数"),
   其余四个 `server/` 文件对方**不碰**。**建议**:把 Task 2 的客户端半与 Task 3 的服务端半
   **拆成两次提交**(本计划已按"客户端半 → 服务端半"排,但 Task 2 是一个 Task 里两半都改),
   这样服务端那两处可以**整体延后**到对方收工之后再落。**若控制者选择延后**,Task 2 就只剩
   `_cancel_reconnect` + `pvp_game` 接线 + 探针(仍然自洽、仍然可测),服务端那两处单独成一个
   后续 Task —— **本计划不替控制者做这个决定**。
2. **`opponent_left` 的投递是"尽力而为"**:worker 发完那条可靠的定向包**紧接着** `quit(0)`。
   ★ 已核实引擎侧:Godot 的 `ENetMultiplayerPeer::put_packet` 在 `send` 之后**当场
   `hosts[0]->flush()`**(`modules/enet/enet_multiplayer_peer.cpp:390-395`),故数据确实进了内核
   socket 缓冲、会被发出去 —— 但 UDP 首包仍有丢包概率,且进程退出后**没有重传**。
   ⇒ **设计成"尽力而为、回落不变坏"**:丢了就退回今天的 60s→主菜单(不新增任何坏行为)。
   ★ **若控制者认为这条不够强**(需要一个"必达"的语义),候选是"发完之后等一个短延时/等一个 ack
   再退进程"—— 那是**新的设计**,本计划**不做**,如实登记为开放问题。
3. **3v3 不做「掉线中」是否有遗漏**:spec §4 的 3.1 明说只点大乱斗与 1v1,而 3v3 是**六人两队**
   —— 「对手掉线」在 3v3 里其实是个**有信息量**的状态(哪一队少了人)。本计划按 spec 不做,
   并用反向断言把这个"有意的不对称"钉住。**若用户希望 3v3 也有**,那该做在记分条上
   (「A 队 2/3 人」)而不是单行状态 —— 属**另行评估**。
4. **`_on_reconnect_retry_tick` 里那句 `int(...)` 的取整方向**:横幅上的"剩余 Ns"用的是
   **截断**(`int((now - start)/1000)`),与收场判据 `Time.get_ticks_msec() - _reconnect_started_ms > int(DEFAULT_SECONDS*1000)`
   的**毫秒级**比较不完全同步 —— 极端情况下横幅显示"剩余 0s"之后还可能再转 1~2 拍。
   属**表现层的 1~2 秒误差**,不影响收场时刻;若要严格对齐,把横幅那句改用与收场判据**同一个
   表达式**即可。**本计划不修**(登记为已知的小不一致)。
