# 助攻表 + 惩罚记账（服务端）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 三模式通用的逐人统计里补上**助攻**（今天全仓没有这个概念）与**惩罚**
（对队友/自己造成的伤害、击杀队友）—— 前者走一张新的「受害者 → 攻击者 → 时刻」小表，
后者走 `_on_player_hit` 与倒地边沿上的两笔新账，两者都只影响 `kscore`，**不进 `dealt` / `taken`**。

**Architecture:** 计划 1 已把统计面与公式上提到 `MatchState` / `ScoreRules`，并留好了
`assists` / `team_damage` / `self_damage` / `team_kills` 四个**原始计数键**（恒 0）。
本计划只做三件事：① 加一张助攻表 + 一个写入点（`MatchCombat._on_player_hit`，所有伤害路径
的**唯一汇聚点**）；② 在 `_record_down` 里读表记助攻、并给"击杀队友"记一笔；
③ 补一条**自伤标记**通道 —— 这是 spec §3.5 说"不需要新机制"、而实际**必须新增**的那一处
（见 `.superpowers/sdd/stats-spec-verify.md` ❌ 24：`attribute()` 对自伤静默跳过，
`_on_player_hit` 里"自伤"与"归因不到"**完全不可区分**）。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、场景探针（`--headless`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-stats-and-results-design.md` §3.4 + §3.5（计划 2/3）。
**依赖**：计划 1（`docs/superpowers/plans/2026-09-25-stats-per-player-and-formula.md`）——
本计划用的字段集、`_kscore_of` / `_record_down` / `_stat_entry` 与 `ScoreRules.penalty` 全部来自它。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless`、**不占任何端口**；**实机验收归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件；提交信息含引号/反引号时用 `git commit -F - <<'EOF'`。
- 字号必须是 **16 的倍数**（本计划不引入新字号）。
- 改 GDScript 只需重导出，别重编裁剪模板。
- ★ **助攻窗口复用 `CombatFeedback.ATTRIB_WINDOW_MS`（3s，底座常量 `ATTRIB_WINDOW`）**，
  **不新开第二个窗口常量**（"归因口径只有一处来源"）。§5.3 已登记：将来要分开调是另一件事。
- ★ **`same_team` 的 0 语义不许"优化"**：任一方 0 → false。1v1 / 大乱斗的队伍表为空 ⇒
  那两模式**天然拿不到助攻**、也天然不会把队友伤害算进惩罚 —— 这是本计划的免费正确性，
  改成 `same_team(0,0) == true` 会让 1v1 的两人互为队友、子弹互相穿透。
- ★ **本计划不改伤害本身**：爆炸对队友满效是用户既有裁定，`Explosion.apply_aoe` 的伤害/击退
  一个数都不动 —— 只**加一笔标记**（Task 2 Step 2）。
- ★ 本计划**不碰协议**（`stats` 的字段集在计划 1 已定，键名不变）。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `server/match_state.gd` | 对局底座（计划 1 起持有逐人统计） | **加** `_assist_times` 表 + `_note_hit` + `_respawn_player` 清表；`_record_down` 记助攻与击杀队友 |
| `server/match_combat.gd` | 子弹/爆炸/光束裁决域 | `_on_player_hit` **加**助攻表写入、`self_damage` / `team_damage` 两笔账 |
| `server/match_round.gd` | 回合机（1v1 与另两模式的公共基类） | `_respawn_player` **加**一行：清该受害者的助攻表（一处覆盖三模式） |
| `ui/combat_feedback.gd` | 归因写端（UI 层上的静态入口） | **加** `note_self_hit` / `is_fresh_self_hit`（自伤标记通道） |
| `core/sim/explosion.gd` | 爆炸 AoE（纯静态） | 玩家循环里 **加**一笔自伤标记（`shooter == pp` 时） |
| `tests/team_host_probe.gd` | 3v3 权威探针 | **加** ⑬k（助攻三档）/ ⑬l（队伍表空 ⇒ 无助攻）/ ⑬m（队友击杀惩罚）/ ⑬n（自伤惩罚）/ ⑬n2（敌方爆炸的正向对照） |
| `CLAUDE.md` | 项目约定 | **加**助攻/惩罚的口径与"自伤需要标记通道"这条 |

---

### Task 1: 助攻（探针先红，再补表）

**Files:**
- Modify: `tests/team_host_probe.gd`（先加 ⑬k/⑬l → 红）
- Modify: `server/match_state.gd`
- Modify: `server/match_combat.gd`
- Modify: `server/match_round.gd`

**Interfaces:**
- Consumes: 计划 1 的 `_stat_entry(role)`、`_record_down(victim_role, killer_role)`、
  `ATTRIB_WINDOW`、`_fresh_attacker_role(victim_role)`、`same_team(a, b)`、`_kscore_of(role)`。
- Produces:
  - `MatchState._assist_times: Dictionary`（`victim_role -> {attacker_role: 时刻ms}`）
  - `MatchState._note_hit(victim_role: int, attacker_role: int) -> void`
  - `MatchState._clear_assist_table(victim_role: int) -> void`
  - 行为：受害者倒地边沿，表里**除击杀者之外**、在窗口内、且与击杀者**同队**（并与受害者**不同队**）
    的 attacker 各 `assists += 1`。

- [ ] **Step 1: 先写 ⑬k/⑬l（会红 —— 助攻恒 0）**

★ **相序是硬约束**（本计划的五段 ⑬ 与 ⑬j 的相对位置**不可调换**）：
`⑬j → ⑬k → ⑬m → ⑬n → ⑬n2 → ⑬l → `_ran_to_end = true``。
两条理由：① **⑬l 必须最后** —— 它新建第二个宿主，`MatchHost._init` 会重载全局
`MazeGenerator.current_grid`（`⑬b3/⑬m/⑬n/⑬n2` 都靠 `_find_dry_point()` 读它）；
② `⑬h` 已经把 role 6 从 `players` 里摘掉（`mark_disconnected(6)`），后面任何一段都
**不许再引用 `players[6]`**（裸取会 `Invalid get index '6'` ⇒ 探针中断）。

在 `tests/team_host_probe.gd` 的 ⑬j 之后、`_ran_to_end = true` 之前插入。

**先加两个助攻表读数助手**（放在既有 `_kscore` / `_acs` 旁边）：

```gdscript
# 助攻表读数(表: victim_role -> {attacker_role: 时刻ms})。
# ★★ 必须走 `host.get("_assist_times")` 而**不是** `host._assist_times`。
#   字段在本 Task 的红阶段**还不存在**,而不存在的属性**直接取**会抛
#   `Invalid access to property or key '_assist_times'`(**实测**)。
#   ★★ 但它**不是**假绿 —— **实测**形态是:错误只结束**这个助手**,调用方照常往下走
#   (受影响的 `_check` 拿到 null/空值 ⇒ 照样**红**),`_ran_to_end` 也会被走到 ⇒
#   verdict 是 **`FAIL`**。(拿一个临时场景探针量过:助手内部报错后,紧随其后的断言**照跑**、
#   `ran_to_end=true`、verdict `FAIL`。)⇒ 保留 `Object.get()` 的理由是**诊断质量**:
#   它把"字段还没落地"变成一条**带着表内容**的值不匹配,而不是一行 SCRIPT ERROR + 一个
#   null 派生出来的怪值。**别"简化"回直接取**,但也别再拿"防假绿"当理由。
func _assist_table(host, victim_role: int) -> Dictionary:
	var t: Variant = host.get("_assist_times")
	if not (t is Dictionary):
		return {}
	var sub: Variant = (t as Dictionary).get(int(victim_role))
	return sub if sub is Dictionary else {}


# 把表里那一笔的时刻往前挪(等 3s 不现实)。返回 false = 表/条目还不存在。
# ★ 与 `_assist_table` 同款理由:字段不存在时**什么都不做**,由调用方的 `_check` 把它变成
#   一条**干净的红**(实测:助手内部报错只结束助手本身,调用方继续、后面的断言照样跑、
#   verdict 是 `FAIL` —— 不是假绿)。
func _age_assist(host, victim_role: int, attacker_role: int, ago_ms: int) -> bool:
	var t: Variant = host.get("_assist_times")
	if not (t is Dictionary):
		return false
	var outer: Variant = (t as Dictionary).get(int(victim_role))
	if not (outer is Dictionary):
		return false
	(outer as Dictionary)[int(attacker_role)] = Time.get_ticks_msec() - int(ago_ms)
	return true


# 把**除 `keep` 之外**的全部在场玩家挪到远点(⑬m/⑬n/⑬n2 的爆炸半径 100 ⇒ 只打得到爆心那一人)。
# ★ 判据用"遍历 `players` 减掉例外"而**不是**写死 role 列表:⑬h 已经把 role 6 从 `players`
#   摘掉(`team_host.gd:582` 的 `players.erase`),写死列表既会漏掉新 role,又会取到不存在的
#   6 号 —— 后者是 `Invalid get index '6' on Dictionary` ⇒ `_run()` 中断(⑬j 之后的三段
#   全在这个坑上,而探针里既有的 `[2,3,4,5,6]` 写法是**在 ⑬h 之前**跑的,照抄会踩)。
func _park_all_but(host, keep: Array, at: Vector2) -> void:
	for r in host.players:
		var role := int(r)
		if keep.has(role):
			continue
		var p: Node2D = host.players[r]
		if p != null and is_instance_valid(p):
			p.global_position = at
```

然后是 ⑬k 本段：

> ★★ **落地版与本代码块有两处已实现的差异**（评审 F6-1/F6-2 的补丁，`tests/team_host_probe.gd`
> 是权威）：① **(k1) 放两位攻击者**（甲打 20、丁(3 号)再打 60，两位都得 +1）—— 只有一个候选的
> 夹具里"只给一位 attacker 记账"的实现全绿；两枪的顺序不能反（先 60 会把 50 血的乙当场打倒，
> 而 `take_hit` 在 `downed` 时早退 ⇒ 第二枪**静默不入表**）。② 末尾多一条 **(k4)**：乙(2 号,1 队)
> 先被**敌人**(4 号)与**队友**(3 号)各打一下，再由乙的**队友**(1 号)补掉乙 ⇒ **谁都不记助攻**。
> ★ **(k4) 的实测鉴别力矩阵**（先看这条，免得照 F6-2 的直觉去等一个不会红的变异）：**只**把助攻块
> 挪到 `same_team(killer_role, victim_role)` 早退**之前** ⇒ **整跑仍 `ALL-OK`、156 ok、零 FAIL**
> —— 因为"attacker 与击杀者同队"为真 ⇒ 队号 = 击杀者的队 = 受害者的队 ⇒ 后半句
> `same_team(attacker, victim_role)` 必为真 ⇒ 照样挡掉；**早退与后半句互为保险带**，
> 只拆一条**不可观测**。真正能红的是两条实现路径各拆一条：挪块 **且** 删后半句 ⇒ 队友那条红
> （`实际 +1`）、挪块 **且** 删前半句 ⇒ 敌人那条红（`实际 +1`，⑬l 同时红）。

```gdscript
	# ── ⑬k 助攻:甲打乙 60、丙补掉乙 ⇒ 丙记击杀、**甲记助攻**;窗口外不记 ──
	# ★ spec §6.2 的三档;★ 后半档是**鉴别点** —— 只断言"甲记了助攻"的话,
	#   把窗口判据删掉也能过。
	# ★ 助攻表住在 `_assist_times`(role -> role -> 时刻),写入点是生产的
	#   `MatchCombat._on_player_hit`(所有伤害路径的唯一汇聚点),本段**不手写表** ——
	#   甲那 60 点是走真归因写端 + 真 `take_hit` 落进去的。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	_host._left = {}
	_host._left_round = {}
	# ★ 逐人原始表也清一次:⑬k/⑬m/⑬n 有几条读数是**增量**(不怕残余),但把表清空能让
	#   它们与 ⑬l 的绝对读数(「队伍表为空 ⇒ 助攻恒 0」)都建立在可手算的基线上。
	_host._stats = {}
	for st_kr in _host.players:
		_host._respawn_player(int(st_kr))
	# (k1) 甲(1 号,1 队)打乙(4 号,2 队)60 伤害
	var st_a_k1 := _stat(_host, 1, "assists")
	var st_a_k2 := _stat(_host, 2, "assists")
	CombatFeedback.attribute(_host.players[4], _host.players[1])
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 60)
	# ★★ `st_a_ks1` 必须在**那 60 伤害之后**读:这一枪本身就给甲 `dealt += 60` ⇒ kscore 已 +12
	#   (`ScoreRules.kscore(0, 1, 60, …) == 62`,实测)。在伤害**之前**读的话,下面那条
	#   "助攻进 kscore" 要断的就是 **+62**(助攻 50 + 伤害 12)而不是 +50 ⇒ **实现正确也不会绿**;
	#   同理 Step 2 的红也不是表里写的 `+0` 而是 `+12`。移到伤害之后读,两处都回到干净的值。
	var st_a_ks1 := _kscore(_host, 1)
	_check(_assist_table(_host, 4).has(1),
			"★ ⑬k [仪器] 甲的那一枪必须进了助攻表(否则下面两条恒真;表=%s)"
			% str(_assist_table(_host, 4)))
	# 丙(2 号,1 队)补掉乙 —— `_down` 会先把归因写成丙,再走倒地边沿
	_down(_host, 4, 2)
	_check(_stat(_host, 2, "kills") == 1, "★ ⑬k 丙(补刀的)记击杀(实际 %d)" % _stat(_host, 2, "kills"))
	_check(_stat(_host, 1, "assists") - st_a_k1 == 1,
			"★ ⑬k 甲**记一次助攻**(实际 +%d,期望 +1)"
			% (_stat(_host, 1, "assists") - st_a_k1))
	_check(_kscore(_host, 1) - st_a_ks1 == 50,
			"★ ⑬k 助攻进 kscore(+50,实际 +%d)" % (_kscore(_host, 1) - st_a_ks1))
	_check(_stat(_host, 2, "assists") - st_a_k2 == 0,
			"★ ⑬k 击杀者本人**不**记助攻(实际 +%d)" % (_stat(_host, 2, "assists") - st_a_k2))
	# ★ 清空点是**复活**而不是倒地 ⇒ 倒地之后、复活之前表**还在**。
	#   ★ 这两条是**一对**:只断"复活后是空的"的话,"从来就没有这张表"也全绿。
	_check(not _assist_table(_host, 4).is_empty(),
			"★ ⑬k [仪器] 复活**之前**表还在(证下面那条清空不是恒真)")
	_host._respawn_player(4)
	_check(_assist_table(_host, 4).is_empty(),
			"★ ⑬k 复活时清空该受害者的助攻表(不清的话上一条命的命中会算进下一条命)")

	# (k2) 窗口外不记助攻 —— 把表里那一笔的时刻往前挪出 3s
	# ★ 这里是**直接改表**(唯一一处手写表):等 3s 不现实,而窗口判据必须被验到。
	#   `_age_assist` 的防御写法见它的注释(字段不存在时返回 false,由下面这条断言红出来)。
	# ★★ 但改表**之前必须先重打一枪**:清空点是**复活**,而 (k1) 末尾刚复活过 4 号 ⇒ 此刻
	#   `_assist_times[4]` 整张子表已被 `_clear_assist_table` 抹掉。少了这一枪,`_age_assist` 会因
	#   "条目不存在"返回 false ⇒ 那条 [仪器] 断言在**正确实现下也会红**(它守的是"窗口判据真的
	#   被验到",而不是"表是空的")。★ 与 (k1) 同理,必须在 (k1) 的**复活之后**、且是**新的**一枪。
	CombatFeedback.attribute(_host.players[4], _host.players[1])
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 5)
	_check(_assist_table(_host, 4).has(1), "[仪器] ⑬k 前提:重打的那一枪进了表")
	_check(_age_assist(_host, 4, 1, TeamHost.ATTRIB_WINDOW + 1000)
			and Time.get_ticks_msec() - int(_assist_table(_host, 4).get(1, 0)) > TeamHost.ATTRIB_WINDOW,
			"[仪器] ⑬k 前提:表里那一笔确实**已超窗**(否则下面那条验的不是窗口判据)")
	var st_a_k3 := _stat(_host, 1, "assists")
	_down(_host, 4, 2)
	_check(_stat(_host, 1, "assists") - st_a_k3 == 0,
			("★ ⑬k 甲的最后一次命中在窗口(3s)外 ⇒ **不记助攻**(实际 +%d);"
			+ "删掉窗口判据这里会变成 +1") % (_stat(_host, 1, "assists") - st_a_k3))

	# (k3) 队友误伤 **不算**助攻:乙的队友(5 号,2 队)炸过乙,随后敌人补掉乙
	# ★★ 这是本段最要紧的一条:没有 `same_team(attacker, killer)` 那道过滤,
	#   5 号会**因为打死自己人**拿到一次助攻。
	_host._respawn_player(4)
	var st_a_k4 := _stat(_host, 5, "assists")
	var st_a_k5 := _stat(_host, 1, "assists")
	CombatFeedback.attribute(_host.players[4], _host.players[5])   # 队友(5 号,2 队)打乙(4 号,2 队)
	(_host.players[4] as Node2D).take_hit(Vector2.ZERO, 10)
	_check(_assist_table(_host, 4).has(5),
			"[仪器] ⑬k 前提:队友那一枪**确实进了表**(没进的话下面那条是空转)")
	_down(_host, 4, 1)          # 敌人(1 号,1 队)补掉乙
	_check(_stat(_host, 5, "assists") - st_a_k4 == 0,
			("★ ⑬k 受害者的**队友**误伤之后、敌人补刀 ⇒ 那位队友**不得**记助攻"
			+ "(实际 +%d);删掉**整条** same_team 过滤(两个合取项都不留)这里才会变 +1 ——"
			+ "只删前半句**不会**(实测):后半句 `same_team(attacker, victim)` 仍把他挡住")
			% (_stat(_host, 5, "assists") - st_a_k4))
	_check(_stat(_host, 1, "assists") - st_a_k5 == 0,
			"★ ⑬k [仪器] 击杀者本人仍不记助攻(实际 +%d)" % (_stat(_host, 1, "assists") - st_a_k5))
```

**并在 `⑬j` 之后、`_ran_to_end = true` 之前再加 ⑬l**（★ 这一段**必须放在最后**：它新建第二个
宿主，`MatchHost._init` 会重载全局 `MazeGenerator.current_grid`，放在中间会影响 ⑬b3 的
`_find_dry_point()`）：

```gdscript
	# ── ⑬l 队伍表为空(1v1 / 大乱斗的形状)⇒ **拿不到任何助攻**,而击杀照记 ──
	# ★ 这是 spec §3.4「免费的正确性」的守卫:`same_team(0,0)` 恒 false ⇒ 助攻过滤天然不成立。
	#   ★ 正向对照(击杀照记)不可省:只断言"assists == 0"的话,一个**什么都没接**的宿主
	#   (或"助攻永远不记"的坏实现)照样全绿。
	#   ★ 本段**最后**跑:新建宿主会重载全局网格,前面几段(尤其 ⑬b3 的 `_find_dry_point`)
	#   依赖它保持不动。
	var st_plain = TeamHost.new(MAP, {}, {},
			[], {1: Vector2i(5, 10), 2: Vector2i(9, 10), 4: Vector2i(30, 10)}, {})
	add_child(st_plain)
	st_plain.set_physics_process(false)
	for st_pr in [1, 2, 4]:
		_place(st_plain, st_pr, {1: Vector2i(5, 10), 2: Vector2i(9, 10), 4: Vector2i(30, 10)}[st_pr])
	st_plain._wire_hit_feedback()
	st_plain._round_state = MatchHost.RoundState.PLAYING
	CombatFeedback.attribute(st_plain.players[4], st_plain.players[1])
	(st_plain.players[4] as Node2D).take_hit(Vector2.ZERO, 60)
	_down(st_plain, 4, 2)
	_check(_stat(st_plain, 2, "kills") == 1,
			"★ ⑬l [正向对照] 队伍表为空时**击杀照记**(实际 %d)" % _stat(st_plain, 2, "kills"))
	_check(_stat(st_plain, 1, "assists") == 0,
			"★ ⑬l 队伍表为空 ⇒ **没有任何助攻**(实际 %d)" % _stat(st_plain, 1, "assists"))
	st_plain.free()
```

- [ ] **Step 2: 跑一次，确认它红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|⑬k|⑬l"
```
Expected（补表**之前**）—— 五条，逐条对：

| 红在哪 | 期望 → 实际 | 为什么夹具能到达 |
|---|---|---|
| ⑬k `[仪器] 甲的那一枪必须进了助攻表` | 表里有 role 1 → **空表** | `_assist_times` 这个字段还不存在 ⇒ `_assist_table()` 防御读返回 `{}` |
| ⑬k `甲**记一次助攻**` | +1 → **+0** | 表空 ⇒ `_record_down` 循环里一个候选都没有 |
| ⑬k `助攻进 kscore` | +50 → **+0** | 同上（`assists` 恒 0） |
| ⑬k `[仪器] 复活**之前**表还在` | 非空 → **空** | 同上 |
| ⑬k `[仪器] 前提：重打的那一枪进了表` | true → **false** | 同上（(k2) 那一枪也进不去表） |
| ⑬k `[仪器] 前提：表里那一笔确实**已超窗**` | true → **false** | `_age_assist()` 对不存在的字段返回 false |
| ⑬k `[仪器] 前提：队友那一枪确实进了表` | true → **false** | 同上 |
| （⑬k 其余两条 + ⑬l 两条） | —— | **此时是绿的**，见下 |

★ **⑬k 里"击杀者本人不记助攻"/"窗口外不记助攻"/"队友误伤不算助攻"与 ⑬l 的两条,在补表之前
必然通过**（助攻恒 0 ⇒ 所有"不该记"的断言都成立）。别把它们当"漏改"去追 —— 它们的鉴别力
在 Step 6 之后（各自的变异见 Step 7），⑬l 尤其如此（恒 0 的实现下它必然绿）。
★ 本步**不会再假绿**：探针读表一律走 `_assist_table()` / `_age_assist()` 两个**防御**助手
（`host.get("_assist_times")` 对不存在的属性静默返回 null），所以上面六条都是**干净的值不匹配**。
★ **别把这两个助手"简化"回 `host._assist_times`** —— 直接取不存在的属性会抛
`Invalid access to property or key …`（**实测**）。★ 它的形态**不是**假绿而是**更难读的红**：
错误只结束**助手**、调用方继续、后面的断言**照样跑**、verdict 是 `FAIL`（拿临时场景探针量过）。
⇒ 保留防御读是为了让红**带着表内容**可读，不是为了"防假绿"。
★ 因此本步 Expected 与探针写法**必须成对**改：只改一半（探针直接取字段 / Expected 照旧写
一串 FAIL）会让差分不清成因。

- [ ] **Step 3: 底座加表（先只加字段与写入口，读端留空）**

`server/match_state.gd`，在计划 1 加的 `_stats` 那一组字段之后加：

```gdscript
# 助攻表:**每受害者一张小表** —— `victim_role -> {attacker_role: 最后命中时刻(ms)}`。
# ★ 为什么需要它:归因只有 `CombatFeedback.attribute` 写的单个 `last_damager` meta,只够判
#   "谁拿的击杀",回答不了"还有谁打过他"。
# ★ 写入口唯一(`_note_hit`,由 `MatchCombat._on_player_hit` 调):所有伤害路径
#   (子弹 / 榴弹直击 / 爆炸 AoE / 激光)都汇到那一个钩子 —— 与 `dealt`/`taken` 同源。
# ★ 表的时刻是**墙钟**(`Time.get_ticks_msec`),窗口复用 `ATTRIB_WINDOW`,不新开常量。
var _assist_times: Dictionary = {}
```

同一文件、`_record_down` **之前**加两个小函数：

```gdscript
# 记一笔"谁打过谁"。(写端**不过滤队伍** —— 过滤只有一处,在 `_record_down` 的读端;
# 写端过滤会让"队友误伤拿助攻"这条规则散成两份判断。)
func _note_hit(victim_role: int, attacker_role: int) -> void:
	victim_role = int(victim_role)
	attacker_role = int(attacker_role)
	if not _assist_times.has(victim_role):
		_assist_times[victim_role] = {}
	(_assist_times[victim_role] as Dictionary)[attacker_role] = Time.get_ticks_msec()


# 清掉某受害者的助攻表 —— 由 `MatchRound._respawn_player` 调(复活 = 新的一条命,
# 与"助攻只算这一次倒地之前"一致)。★ 一处覆盖三模式:`RoyaleHost` / `TeamHost` 的
# `_respawn_player` 都 `super` 到 `MatchRound` 那一份。
func _clear_assist_table(victim_role: int) -> void:
	_assist_times.erase(int(victim_role))
```

- [ ] **Step 4: 两个写入点**

**(a)** `server/match_combat.gd` 的 `_on_player_hit`：把计划 1 加的那一段改成（**只多**
`_note_hit` 一行 + 注释，`dealt`/`taken` 的判据一个字不动）：

```gdscript
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0:
		# 助攻表:所有**归因得到**的命中都记一笔(含队友误伤 —— 读端按 `same_team` 过滤,
		# 见 `_record_down`;写端不过滤才能让那条规则只有一处)。
		# ★ 与 `dealt` 的门槛**不同款**是刻意的:`dealt` 只算敌人,助攻候选人要连队友一起
		#   收下来、再由读端判"与击杀者同队"(spec §3.4 那条荒谬助攻的堵法)。
		_note_hit(int(role), stat_attacker)
		if not same_team(stat_attacker, int(role)):
			var sa := _stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
```

**(b)** `server/match_round.gd` 的 `_respawn_player`（`:73-83`）末尾加一行：

```gdscript
	_respawn_pending.erase(role)
	_down_counted[role] = false
	# 助攻表:复活 = 新的一条命,上一次倒地之前的命中历史作废(与"助攻只算这一次倒地之前"一致)。
	# ★ 住在这里一处覆盖三模式 —— 另两个模式的 `_respawn_player` 都 `super` 到本函数。
	# ★ 用**复活**而不是**倒地**作为清空点:倒地后 `take_hit` 会因 `downed` 早退
	#   (`scenes/player/combat_component.gd:43`),两者在观测上等价,但复活点与 spec §3.4 的
	#   口径逐字一致、且是玩家"重新开始"的语义点。
	_clear_assist_table(role)
```

- [ ] **Step 5: `_record_down` 记助攻**

`server/match_state.gd` 的 `_record_down`（计划 1 写的版本）整体替换为：

```gdscript
func _record_down(victim_role: int, killer_role: int) -> void:
	victim_role = int(victim_role)
	killer_role = int(killer_role)
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0:
		return          # 无归因:不计任何人的击杀,**也不计任何人的助攻**
	if same_team(killer_role, victim_role):
		# ★ 队友击杀:不记 kills(用户裁定 ②),**也不记助攻**(没有"自己队的击杀"这回事)。
		#   "击杀队友"的代价记在**肇事者**行上,由惩罚那一项承担(见 Task 2)。
		var tm := _stat_entry(killer_role)
		tm["team_kills"] = int(tm["team_kills"]) + 1
		return
	var k := _stat_entry(killer_role)
	k["kills"] = int(k["kills"]) + 1
	# ── 助攻:表里**除击杀者之外**、且在归因窗口内、且**与击杀者同队**的 attacker ──
	# ★★ 前半句 `same_team(attacker, killer)` 是**唯一承重**的那半:没有它,受害者的**队友**
	#   误伤过他(爆炸),随后敌人把他补掉 ⇒ 那位队友**因为打死自己人而拿到助攻**(spec §3.4)。
	# ★★ 后半句 `same_team(attacker, victim)` 是**死代码** —— 但**不是"恒真"**(初稿写错过
	#   这一点,评审 F1 订正):上面那道 `if same_team(killer_role, victim_role): … return`
	#   已经保证**击杀者与受害者异队**,于是"attacker 是受害者的队友"为真 ⇒ attacker 与 killer
	#   **必定不同队** ⇒ `not same_team(attacker, killer)` 早就为真 ⇒ 那个 `or` 的结果
	#   **永远不受后半句影响**。而"attacker 是受害者队友"这一档**确实可达**(⑬k 的 (k3)
	#   夹具就是:attacker 5 / victim 4 同属 2 队)⇒ 单看这一项它就是 true,挡掉它的始终是前半句。
	# ★ 留着它是**保险带**:哪天上面那道 `same_team(killer_role, victim_role)` 守卫改了
	#   (例如"队友击杀也算击杀"),它当场变成活的;照 spec §3.4 的写法也读得出来。
	#   ★ 变异实测(HEAD):只删后半句 ⇒ `ALL-OK`、**没有任何断言察觉**
	#     (ok 数不变:评审当时 150,本批 ⑬k 扩容后 156);
	#   只留后半句(删前半句)⇒ **只有 ⑬l 红**,(k3) 仍绿 —— 即"必须与击杀者同队"这条规则
	#   今天**只由 ⑬l 咬住**。
	# ★ 1v1 / 大乱斗:队伍表空 ⇒ `same_team` 恒 false ⇒ **天然拿不到任何助攻**,
	#   不需要特判(守卫:⑬l)。
	var now := Time.get_ticks_msec()
	var table: Dictionary = _assist_times.get(victim_role, {})
	for a in table:
		var attacker := int(a)
		if attacker == killer_role:
			continue
		if now - int(table[a]) > ATTRIB_WINDOW:
			continue
		if not same_team(attacker, killer_role) or same_team(attacker, victim_role):
			continue
		var sa := _stat_entry(attacker)
		sa["assists"] = int(sa["assists"]) + 1
```

- [ ] **Step 6: 跑 —— 确认转绿**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|FAIL"
```
Expected: `TEAM HOST: ALL-OK`，零 `FAIL`。
★ 若 ⑬k (k1) 的 `[仪器]` 那条红，说明 `take_hit` 那一下没走成（多半是 4 号当时 `downed` ——
检查上一档 `_down` 之后有没有 `_respawn_player(4)`）。

- [ ] **Step 7: 反证（把整条过滤拿掉，确认 ⑬k(k3) 红）**

临时把 `_record_down` 里**整行**删掉：
`if not same_team(attacker, killer_role) or same_team(attacker, victim_role):` + 它的 `continue`
（两行一起删；或该 `if` 改成 `if false:`），跑同样的命令。
Expected: 红**两条** —— **`★ ⑬k 受害者的**队友**误伤之后、敌人补刀 ⇒ 那位队友**不得**记助攻(实际 +1)`**
与 **`★ ⑬l 队伍表为空 ⇒ **没有任何助攻**(实际 1)`**。确认后**改回来**。

★★ **别用"只删前半句"当变异**：`if same_team(attacker, victim_role): continue`（= 去掉
"与击杀者同队"那半、留着"与受害者同队"那半）**不会让 (k3) 变红** —— (k3) 的 attacker 是
**受害者的队友**（5 号 vs 4 号同属 2 队）⇒ 后半个合取项**照样把它挡掉**。照那个变异去"验证"
会得出"这条断言没有鉴别力"的**错误结论**。实测（HEAD 逐条跑过）：**只有 ⑬l 红**（`实际 1`）、
(k3) 仍绿、`ok` 从 150 掉到 149（⑬k 扩容后：从 156 掉到 155）—— 即"必须与击杀者同队"这条规则
**今天只由 ⑬l 咬住**。

★★ **两个合取项并不对称**（初稿写"互为冗余"、且说后半个"恒真"，**两条都错**，评审 F1 订正）：
删**后半句** `or same_team(attacker, victim_role)` ⇒ `ALL-OK`、**没有任何断言察觉**
(ok 数不变:评审当时 150、评测夹具扩容后 156)
⇒ 它是**死代码** —— 给定上面那道 `same_team(killer_role, victim_role)` 早退，"attacker 与 victim
同队"为真 ⇒ attacker 与 killer 必定不同队 ⇒ 前半句早已为真，`or` 的结果永远不由后半句决定。
但它**不是"恒真"**：(k3) 夹具里 attacker 5 / victim 4 就是队友 ⇒ 单看这一项它是 **true**，
只是被前半句"抢先"决定了。留着它是**保险带**：那道早退守卫哪天改了（例如"队友击杀也算击杀"），
它当场变活；照 spec §3.4 的写法也读得出来。

- [ ] **Step 8: 提交**

```bash
git add server/match_state.gd server/match_combat.gd server/match_round.gd \
        tests/team_host_probe.gd
git commit -m "feat(stats): 助攻表(受害者->攻击者->时刻)+ 倒地边沿记助攻,窗口复用 3s"
```

---

### Task 2: 惩罚（队友伤害 / 自伤 / 击杀队友）

**Files:**
- Modify: `tests/team_host_probe.gd`（先加 ⑬m/⑬n/⑬n2 → 红）
- Modify: `ui/combat_feedback.gd`（自伤标记通道）
- Modify: `core/sim/explosion.gd`（写标记）
- Modify: `server/match_combat.gd`（两笔新账）
- Modify: `server/match_state.gd`（`_record_down` 记 `team_kills`）

**Interfaces:**
- Consumes: Task 1 的 `_assist_times` / `_note_hit`；计划 1 的 `ATTRIB_FRESH_MS`、
  `_stat_entry`；`ScoreRules.penalty(team_damage, self_damage, team_kills)`
  （计划 1 已把它接进 `kscore` —— 本 Task **不改 `ScoreRules`**）。
- Produces:
  - `CombatFeedback.note_self_hit(victim: Node) -> void`
  - `CombatFeedback.is_fresh_self_hit(victim: Node, window_ms: int) -> bool`
  - 行为：`team_damage` / `self_damage`（各 ÷5 后从 `kscore` 减）+ `team_kills`（每次 −100）。

- [ ] **Step 1: 先写 ⑬m/⑬n/⑬n2（会红）**

接在 ⑬k 之后、**⑬l 之前**（相序硬约束：`⑬j → ⑬k → ⑬m → ⑬n → ⑬n2 → ⑬l`；⑬l 会新建宿主、
必须留在最后 —— 见 Task 1 Step 1 那段说明。另：**三段都不许引用 `_host.players[6]`**，
role 6 已被 ⑬h 摘掉）。

```gdscript
	# ── ⑬m 惩罚之一:炸死队友 ──
	# ★ spec §6.3:甲的 kscore **减少**、deaths 不变、kills 不变;
	#   ★ 并且**不进** `dealt`(伤害那一列只算敌人)—— 与 `taken`(受害者那一侧)同样不进。
	# 布景与 ⑬b3 同款:受害者摆在**爆心**(d == 0 ⇒ 内圈满伤、免疫遮挡),其余人摆到 600px 外。
	_host._respawn_player(2)     # 队友乙:2 号(1 队)
	var st_p_pt := _find_dry_point()
	if st_p_pt.x < 0:
		st_p_pt = (_host.players[2] as Node2D).global_position
	(_host.players[2] as Node2D).global_position = st_p_pt
	# ★ 其余人(在场的**全部**,含扔雷的 1 号)一律挪到 600px 外 ⇒ 半径 100 的爆炸只够得到 2 号。
	#   ★ 用 `_park_all_but` 而不是写死 role 列表:⑬h 已把 6 号摘出 `players`(见助手注释)。
	_park_all_but(_host, [2], st_p_pt + Vector2(600.0, 0.0))
	var st_p_ks0 := _kscore(_host, 1)
	var st_p_kills := _stat(_host, 1, "kills")
	var st_p_deaths := _stat(_host, 1, "deaths")
	var st_p_dealt := _stat(_host, 1, "dealt")
	var st_p_taken := _stat(_host, 2, "taken")
	var st_p_team := _stat(_host, 1, "team_damage")
	var st_p_tkill := _stat(_host, 1, "team_kills")
	var st_p_hp2: int = int(_host.players[2].hp)
	Explosion.apply_aoe(st_p_pt, 100.0, 60, 400.0, _host.players[1])
	_host._match_round_tick(0.016)      # 倒地边沿(60 > 满血 50 ⇒ 必然死)
	_check(int(_host.players[2].hp) < st_p_hp2 or (_host.players[2] as Node2D).is_downed(),
			"★ ⑬m [仪器] 那一下爆炸**真的打中了队友**(否则下面所有读数恒 0)")
	# ★ 读数一律取**增量**:座位表可能带着前面几段的残余(本档只关心"这一下记了什么"),
	#   而"`dealt` 增量必须是 0"同时兼任**布景仪器** —— 若有别的队在爆区里被蹭到,
	#   `dealt` 会涨(它按队伍分账),这条就会红。
	_check(_stat(_host, 1, "team_damage") - st_p_team == 60,
			"★ ⑬m 对队友造成的伤害进 team_damage(实际 +%d,期望 +60)"
			% (_stat(_host, 1, "team_damage") - st_p_team))
	_check(_stat(_host, 1, "team_kills") - st_p_tkill == 1,
			"★ ⑬m 击杀队友记一次(实际 +%d,期望 +1)"
			% (_stat(_host, 1, "team_kills") - st_p_tkill))
	_check(_kscore(_host, 1) - st_p_ks0 == -(60 / 5 + 100),
			("★ ⑬m 炸死队友 ⇒ kscore **减少** %d(实际 %d)—— 伤害 ÷5 与击杀队友 ×100 两项")
			% [-(60 / 5 + 100), _kscore(_host, 1) - st_p_ks0])
	_check(_stat(_host, 1, "kills") == st_p_kills and _stat(_host, 1, "deaths") == st_p_deaths,
			"★ ⑬m 肇事者的 kills / deaths **不变**(实际 %d/%d)"
			% [_stat(_host, 1, "kills"), _stat(_host, 1, "deaths")])
	_check(_stat(_host, 1, "dealt") == st_p_dealt and _stat(_host, 2, "taken") == st_p_taken,
			("★ ⑬m 惩罚**不进** dealt / taken(实际 %d/%d;伤害那两列只算敌人)"
			+ " —— 惩罚是**另一笔账**,与 dealt/taken 不共用(spec §3.5)")
			% [_stat(_host, 1, "dealt"), _stat(_host, 2, "taken")])

	# ── ⑬n 惩罚之二:**自伤**同样扣 ──
	# ★★ 本档是"自伤标记通道"的**唯一**守卫(spec §3.5 说"不需要新机制",实测**需要**:
	#   `attribute()` 对 attacker == victim 静默跳过 ⇒ 自伤与"归因不到"在 `_on_player_hit`
	#   里完全不可区分)。把 `Explosion` 里那笔 `note_self_hit` 删掉,本档立刻红。
	# ★ 20 伤 < 满血 50 ⇒ 故意**不打死**,只量伤害账。
	_host._respawn_player(1)
	var st_s_pt := _find_dry_point()
	if st_s_pt.x < 0:
		st_s_pt = (_host.players[1] as Node2D).global_position
	(_host.players[1] as Node2D).global_position = st_s_pt
	_park_all_but(_host, [1], st_s_pt + Vector2(600.0, 0.0))
	var st_s_ks0 := _kscore(_host, 1)
	var st_s_deaths := _stat(_host, 1, "deaths")
	var st_s_self := _stat(_host, 1, "self_damage")
	var st_s_hp1: int = int(_host.players[1].hp)
	Explosion.apply_aoe(st_s_pt, 100.0, 20, 400.0, _host.players[1])   # 投掷者 = 受害者本人
	_check(int(_host.players[1].hp) == st_s_hp1 - 20,
			"★ ⑬n [仪器] 自己那一下**真的炸到自己了**(hp %d → %d,期望 -20;`apply_aoe` 不排除投掷者)"
			% [st_s_hp1, int(_host.players[1].hp)])
	_check(_stat(_host, 1, "self_damage") - st_s_self == 20,
			("★ ⑬n 自伤进 self_damage(实际 +%d,期望 +20);★ 删掉 `Explosion` 里那笔 "
			+ "`note_self_hit` 这条就变 0")
			% (_stat(_host, 1, "self_damage") - st_s_self))
	_check(_kscore(_host, 1) - st_s_ks0 == -(20 / 5),
			"★ ⑬n 自伤 ⇒ kscore 减少 %d(实际 %d)" % [-(20 / 5), _kscore(_host, 1) - st_s_ks0])
	_check(_stat(_host, 1, "deaths") == st_s_deaths,
			"★ ⑬n 没打死 ⇒ deaths 不变(实际 %d)" % _stat(_host, 1, "deaths"))

	# ── ⑬n2 正向对照:同一个爆炸打在**敌人**身上照常进 dealt / taken,且不进惩罚 ──
	# ★ 与 ⑬m/⑬n 互为一组:少了它,"什么都记不上"的坏实现能让那两条全绿(本仓反复清的那种假绿)。
	# ★ 布景与 ⑬m 逐字同款,只把受害者换成**敌方**(4 号,2 队),且投掷者(1 号)自己远远站着
	#   —— 远到不在爆区内 ⇒ **不会**写出自伤标记(半径 100 < 600)。
	_host._respawn_player(4)
	var st_n2_pt := _find_dry_point()
	if st_n2_pt.x < 0:
		st_n2_pt = (_host.players[4] as Node2D).global_position
	(_host.players[4] as Node2D).global_position = st_n2_pt
	_park_all_but(_host, [4], st_n2_pt + Vector2(600.0, 0.0))
	var st_n2_dealt := _stat(_host, 1, "dealt")
	var st_n2_taken := _stat(_host, 4, "taken")
	var st_n2_team := _stat(_host, 1, "team_damage")
	var st_n2_self := _stat(_host, 1, "self_damage")
	Explosion.apply_aoe(st_n2_pt, 100.0, 30, 400.0, _host.players[1])
	_check(_stat(_host, 1, "dealt") - st_n2_dealt == 30
			and _stat(_host, 4, "taken") - st_n2_taken == 30,
			"★ ⑬n2 敌方爆炸照常进 dealt/taken(实际 +%d/+%d,期望 +30/+30)"
			% [_stat(_host, 1, "dealt") - st_n2_dealt, _stat(_host, 4, "taken") - st_n2_taken])
	_check(_stat(_host, 1, "team_damage") == st_n2_team
			and _stat(_host, 1, "self_damage") == st_n2_self,
			"★ ⑬n2 敌方伤害**不进**惩罚那两笔账(实际 %d/%d)"
			% [_stat(_host, 1, "team_damage"), _stat(_host, 1, "self_damage")])
```

- [ ] **Step 2: 跑一次，确认它红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|⑬m|⑬n"
```
Expected（补账**之前**）—— 五条红、四条绿，逐条对：

| 红在哪 | 期望 → 实际（补账前） | 为什么夹具能到达 |
|---|---|---|
| ⑬m `对队友造成的伤害进 team_damage` | +60 → **+0** | 队友伤害那一支还没写 ⇒ 恒 0 |
| ⑬m `击杀队友记一次` | +1 → **+0** | `_record_down` 的 same_team 分支还没记 `team_kills` |
| ⑬m `炸死队友 ⇒ kscore 减少 -112` | -112 → **0** | 两项都缺席（伤害项 12 + 击杀队友 100） |
| ⑬n `自伤进 self_damage` | +20 → **+0** | 自伤标记通道还没建（`Explosion` 里没有 `note_self_hit`） |
| ⑬n `自伤 ⇒ kscore 减少 -4` | -4 → **0** | 同上 |
| （⑬m 的 `[仪器] 真的打中了队友`） | —— | **绿**：`apply_aoe` 的 60 伤本来就会让 2 号倒地 |
| （⑬m 的 kills/deaths 不变、惩罚不进 dealt/taken） | —— | **绿**：补账前那两项本来就是 0 ⇒ 纯负向断言必然通过 |
| （⑬n 的 `[仪器] 真的炸到自己了`） | —— | **绿**：`apply_aoe` 不排除投掷者（既有行为） |
| （⑬n2 全段） | —— | **绿**：`dealt`/`taken` 由计划 1 已接上，而惩罚那两笔账补账前就是 0 |

★ 那四条绿的是**正向对照**（⑬n2）与**负向断言**（⑬m 的不变项）—— 它们的鉴别力在
Step 6 之后：⑬n2 会在"惩罚口径把敌方伤害也吃进去"时红，⑬m 的不变项会在"惩罚写进了
`dealt`/`taken`"时红。别把它们当"漏改"去追。

★ **为什么夹具能到达这些状态**：⑬m 的 `Explosion.apply_aoe(爆心, 100, 60, …, players[1])` 中
受害者 2 号**站在爆心**（`d == 0 < radius×0.4`）⇒ `_falloff` 满值、`cover_multiplier` 免疫遮挡
⇒ 伤害恰好 60 > 满血 50 ⇒ `_match_round_tick` 的倒地边沿必然触发。

- [ ] **Step 3: 自伤标记通道（`CombatFeedback` + `Explosion`）**

`ui/combat_feedback.gd`，紧接 `attribute()`（`:65-71`）之后加：

```gdscript
## 自伤标记:**爆炸的投掷者本人**在爆区里时,由 `Explosion.apply_aoe` 写一笔。
## ★ 为什么必须新增这条通道:`attribute()` 在 `attacker == victim` 时**静默跳过**(自伤不归因给
##   自己 —— 那是对的,否则"自己炸自己"会被记成自己的击杀),但它让自伤在 `_on_player_hit` 里
##   与"归因不到"**完全不可区分**(读端唯一的攻击者来源是那个 meta,而自伤路径上它停在
##   **上一名敌人**身上或干脆不存在)。
##   惩罚要扣"对自己造成的伤害",就必须有一条**只表示自伤**的通道。
## ★ 它是一个**时刻标量**而不是"谁":自伤的攻击者恒为受害者本人,没有第二方。
## ★ 与 `attribute` 同款:只写元数据、不做任何判定、**headless 服务器下同样安全**
##   (不碰 `current`,不碰任何 UI 节点)。
static func note_self_hit(victim: Node) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	victim.set_meta("last_self_hit_time", Time.get_ticks_msec())


## 该受害者**这一下**是不是自伤(`window_ms` 内刚被标记过)。无标记/超窗 → false。
static func is_fresh_self_hit(victim: Node, window_ms: int) -> bool:
	if victim == null or not is_instance_valid(victim):
		return false
	if not victim.has_meta("last_self_hit_time"):
		return false
	return Time.get_ticks_msec() - int(victim.get_meta("last_self_hit_time")) <= window_ms
```

`core/sim/explosion.gd` 的玩家循环（`:47-57`）：在 `CombatFeedback.attribute(pp, shooter)`
那一行**之前**插入：

```gdscript
			# ★ 自伤标记(必须在 `take_hit` **之前**,与 attribute 同一纪律):`attribute` 对
			#   attacker == victim 静默跳过,自伤因此没有归因通道 —— 惩罚要扣"对自己造成的伤害",
			#   靠这一笔把"自伤"与"归因不到"分开。
			#   ★ 只有**投掷者本人**在爆区里才写 ⇒ 别人炸不到这条路径;`shooter` 为 null
			#   (无主爆炸/敌方弹药)时 `pp == null` 恒 false,天然不写。
			#   ★ 本函数**只写标记**,伤害与击退一个数都不动(爆炸对队友满效是用户既有裁定)。
			if shooter == pp:
				CombatFeedback.note_self_hit(pp)
			CombatFeedback.attribute(pp, shooter)   # 归因写端统一入口
```

- [ ] **Step 4: `_on_player_hit` 记两笔账**

`server/match_combat.gd` 的 `_on_player_hit`：把 Task 1 Step 4 那段整体替换为：

★★ **先看清边界，别顺手删掉一段登记**：下面这个代码块是按**计划 1 时代的净版**写的，而工作区里
该函数的头注在此之后多了一段（`9ab85af` 加的登记）：

> 「"覆盖全部来源"说的是**钩子**、不是**归因写端**；子弹直击的 `attribute` 写在
> `RoyaleHost`/`TeamHost` 的覆写里、基类 `_on_bullet_hit` **不写** ⇒ **1v1 的子弹不计入
> `dealt`**（今天无害，接投递那天表现为系统性偏低 ACS 且无探针会红；修法见 CLAUDE.md）。」

**那一段要原样留住** —— 本代码块只替换它**下面的**（`# ★ `dealt` 与 `taken` 口径对称…` 起、
到 `for r in peer_by_role:` 之前）。同理，块里把"**不必去改 `Explosion`**"改写成
"**不必去改 `Explosion` 的伤害逻辑**"——**以块为准**：本 Task 正要往 `Explosion` 里**加一笔自伤
标记**，旧措辞会被读成"别碰这个文件"。

```gdscript
	# ── 逐人统计(三模式共用;★ 2026-09-25 从 `TeamHost._on_player_hit` 上提)──
	# 一个钩子覆盖**全部**伤害来源(子弹 / 榴弹直击 / 爆炸 AoE / 激光):它们的共同点是
	# "归因写入 `CombatFeedback.attribute` 都在 `take_hit` 之前"(本仓明文纪律),于是
	# `took_hit` 这一刻读 meta 就拿到攻击者。**不必去改 `Explosion` 的伤害逻辑**。
	var stat_victim: Node2D = players.get(int(role))
	var stat_self := stat_victim != null and is_instance_valid(stat_victim) \
			and CombatFeedback.is_fresh_self_hit(stat_victim, ATTRIB_FRESH_MS)
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0:
		# 助攻表:所有**归因得到**的命中都记一笔(含队友误伤 —— 读端按 `same_team` 过滤)。
		_note_hit(int(role), stat_attacker)
		if not same_team(stat_attacker, int(role)):
			# `dealt` / `taken` **口径对称**(spec §3.1):都只算**敌人**。
			# ★ 1v1 / 大乱斗:队伍表空 ⇒ `same_team` 恒 false ⇒ 这两列就等于"对所有人的伤害",
			#   不需要特判(§5.6 的免费正确性,别去"优化"它)。
			var sa := _stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
	# ── 惩罚的两笔账:只减分,**不进** dealt / taken(spec §3.5)──
	# ★ 自伤优先判定:自伤时 meta 通常还是上一名敌人(或为空),两者不同时成立;真同时成立
	#   (同帧内先被敌人打中、再被自己的爆炸炸到)时按**自伤**记 —— 那一下的来源就是自己的爆炸。
	#   ★★ 已知边界(登记不修,承自 `ATTRIB_FRESH_MS` 的既有边界):上面那个 `if` 若成立,
	#     同一笔伤害会**同时**记进 `dealt`(给那位敌人)与 `self_damage`(给自己)—— 两个不同的
	#     账户,不是双计;`acs` 只读 kscore,而 kscore 里两者各出现一次。
	if stat_self:
		var ss := _stat_entry(int(role))
		ss["self_damage"] = int(ss["self_damage"]) + int(damage)
	elif stat_attacker != 0 and same_team(stat_attacker, int(role)):
		var sm := _stat_entry(stat_attacker)
		sm["team_damage"] = int(sm["team_damage"]) + int(damage)
	for r in peer_by_role:
		# 判活:这是**每次伤害**都发的定向包(交火时最密的一处),原先完全不判 ——
		# 往"正在断开"的 peer 发就是那条 channel 0 错误(判据为何不能用 get_peers 见 NetBus)。
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)
```

- [ ] **Step 5: `_record_down` 记 `team_kills`**

★ **已经在 Task 1 Step 5 写进去了**（那一版的 `same_team(killer, victim)` 分支里就有
`tm["team_kills"] += 1`）。本步只做核对：`server/match_state.gd` 的 `_record_down` 里
`same_team(killer_role, victim_role)` 那一支必须**既** `return`（不记 kills/助攻）**又**记了
`team_kills` —— 用 `grep -A4 'if same_team(killer_role, victim_role):' server/match_state.gd` 确认。
★ 若 Task 1 实施时把这一行漏了，⑬m 的 `team_kills` 断言会红（它就是这一步的守卫）。

- [ ] **Step 6: 跑 —— 确认转绿**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|FAIL"
```
Expected: `TEAM HOST: ALL-OK`，零 `FAIL`。

- [ ] **Step 7: 反证（两条，各撤掉一处，确认红在指定的那条）**

**(a) 撤掉自伤标记**：把 `core/sim/explosion.gd` 里 `if shooter == pp:` 那两行注释掉，跑：
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|⑬n "
```
Expected: 红在 **`★ ⑬n 自伤进 self_damage(实际 0,期望 20)`** 与
**`★ ⑬n 自伤 ⇒ kscore 减少 -4(实际 +0)`**，而 ⑬m / ⑬n2 **仍绿**（证明红只由自伤标记一条通道引起）。
★ 这一步是本计划**最要紧**的一次反证：它就是 spec §3.5「不需要新机制」那句话的反面证据。

**(b) 撤掉队友伤害那笔账**：把 `_on_player_hit` 里 `elif stat_attacker != 0 and same_team(...)`
那一支的 `sm["team_damage"] = ...` 一行注释掉 —— ★ **必须在原位补一句 `pass`**
（或者连 `elif` 的条件一起注释掉）：GDScript 的空块是 **Parse Error**，而那是
"场景根没有脚本 ⇒ 一行都不打印"的形状，与真失败在输出上**不可分**（本仓明文纪律）。
跑同样的命令。
Expected: 红在 **`★ ⑬m 对队友造成的伤害进 team_damage(实际 0,期望 60)`** 与
**`★ ⑬m 炸死队友 ⇒ kscore **减少** -112(实际 -100)`**（`team_kills` 的 100 仍在 ⇒ 只剩伤害项缺席）。
确认后**都改回来**，再跑 Step 6 的命令确认全绿。

- [ ] **Step 8: 提交**

```bash
git add server/match_state.gd server/match_combat.gd ui/combat_feedback.gd \
        core/sim/explosion.gd tests/team_host_probe.gd
git commit -m "feat(stats): 惩罚记账(队友伤害/自伤/击杀队友)+ 自伤标记通道"
```

---

### Task 3: 回归 + 登记

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 回归**

Run:
```bash
source tests/env.sh
for t in team_host_probe team_table_probe team_disconnect_probe laser_team_probe \
         grenade_player_hit_probe match_host_hygiene_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
for t in score_rules_smoke enemy_logic_smoke team_room_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR"
done
```
Expected: 全绿（`TEAM HOST: ALL-OK` / `TEAM TABLE: ALL-OK` / `TEAM DISCONNECT: ALL-OK` /
`LASER TEAM PROBE: ALL-OK` / `SMOKE OK` / `SCORE RULES: ALL-OK` / `TEAM ROOM SMOKE: ALL-OK`）。
★ `grenade_player_hit_probe` 与 `laser_team_probe` 必跑：本计划动了
`core/sim/explosion.gd` 与受击钩子，而那两个探针走的是同两条路径（爆炸直击 / 激光直击）。

- [ ] **Step 2: 登记进 CLAUDE.md**

在 §网络与 PvP 的「3v3 团队模式」里、紧挨"子弹穿透队友、爆炸对队友满效"那一条后面补：

```markdown
- **助攻与惩罚(2026-09-25 补)**：逐人统计多了 `assists` 与三个惩罚原始计数
  (`team_damage` / `self_damage` / `team_kills`)，全部只影响 `kscore`、**不进 `dealt` / `taken`**。
  · **助攻表** `MatchState._assist_times` = `victim_role -> {attacker_role: 时刻ms}`，写入口
  `_note_hit`（由 `MatchCombat._on_player_hit` 调 —— 所有伤害路径的唯一汇聚点），判定在
  `_record_down`：**除击杀者外**、窗口内、且 `same_team(attacker, killer)` 的 attacker 各 +1；
  清空在 `MatchRound._respawn_player`（一处覆盖三模式）。窗口复用 `ATTRIB_WINDOW`(3s)，
  **不新开常量**。★ 队伍表为空（1v1 / 大乱斗）⇒ `same_team` 恒 false ⇒ **那两模式天然无助攻**。
  ★★ 那条 `same_team(attacker, killer)` 过滤**不可省**：否则"受害者的队友误伤过他、随后敌人补掉"
  会让那位队友**因为打死自己人拿到助攻**。
  · **惩罚** = `(team_damage + self_damage) ÷ 5 + team_kills × 100`（收在
  `core/sim/score_rules.gd::penalty`），记在**肇事者**行上。`team_kills` 写在 `_record_down`
  的"队友击杀"那一支（该支仍然**不记** kills/助攻）。
  · ★★ **自伤必须有一条专用通道**：`CombatFeedback.attribute()` 对 `attacker == victim`
  **静默跳过**（那是对的），于是自伤在 `_on_player_hit` 里与"归因不到"**完全不可区分** ⇒
  新增 `CombatFeedback.note_self_hit` / `is_fresh_self_hit`，由 `Explosion.apply_aoe` 在
  `shooter == victim` 时写一笔（与 `attribute` 同位、同在 `take_hit` **之前**）。
  **自伤的唯一来源就是自己的爆炸**（子弹/榴弹直击/激光都跳过射手本人）。
  守卫：`tests/team_host_probe` ⑬n —— 删掉那笔标记它立刻红。
```

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 登记助攻表与惩罚记账(含"自伤需要专用标记通道")
EOF
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3.4 + §3.5）：
§3.4 表结构 ✅ `_assist_times`；写入点"所有伤害路径自动覆盖" ✅ `_note_hit` 挂在
`_on_player_hit`（**不是** spec 写的 `attribute` —— 那是 static UI helper，拿不到 role，见核验 ⚠️22）；
判定点 `_record_down` ✅；"只记与击杀者同队的 attacker" ✅ + 反证 Step 7；
"1v1/大乱斗天然无助攻" ✅ ⑬l（含正向对照）；窗口复用 3s ✅；复活时清表 ✅。
§3.5 两项数据来源 ✅（`team_damage` 走既有钩子、`self_damage` 走**新增标记**）；
"只减分，不进 dealt/taken" ✅ ⑬m 的第三条断言；"自杀不额外扣分" ✅（本计划一个字都没加自杀逻辑）；
"不改爆炸伤害" ✅（`Explosion` 只多一笔标记）。
**不在本计划**（spec §8）：把 `ATTRIB_WINDOW` 拆成两个窗口 / 局内伤害 HUD / 结算页列（计划 3）。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。五段探针都是完整可跑的代码块；
每个反证都点名**会红哪一条**并给出**夹具为什么能到达那个状态**（Step 2 的 Expected 一律是表格）。
★ 两个**防御式探针助手**是承重的、不是风格选择：`_assist_table()` / `_age_assist()` 走
`host.get("_assist_times")`（不存在的属性静默返回 null），把"字段还没建"退化成**带表内容的值不匹配**；
直接写 `host._assist_times` 会抛 `Invalid access to property or key …`（**实测**）。
★ 订正：旧稿这里写"直接写 ⇒ `_run()` 中断 ⇒ 打 `ALL-OK` = 假绿"，**实测不成立** ——
助手内部的错误只结束**助手**，调用方继续、断言照跑、verdict 是 `FAIL`（见 Step 1 助手注释里
那条实测）。保留防御读的理由是**诊断质量**，且这一条属于"本计划的错误结论"，不是笔误。
同理 `_park_all_but()` 用"遍历 `players` 减掉例外"而不是写死 role 列表（`players[6]` 已被 ⑬h
摘掉，写死会中断）。三处都写明了"别简化"。

**3. 类型一致性**：`_note_hit(victim_role: int, attacker_role: int) -> void` 与
`MatchCombat._on_player_hit` 的调用实参一致；`_clear_assist_table(victim_role: int) -> void` 与
`MatchRound._respawn_player` 的调用实参（`role`）一致；
`CombatFeedback.note_self_hit(victim: Node)` 的调用点传的是 `pp`（`Node2D`，`Node` 的子类）✅；
`is_fresh_self_hit(victim: Node, window_ms: int)` 的调用点传 `stat_victim`（`Node2D`）+ `ATTRIB_FRESH_MS`（int）✅；
`ScoreRules.penalty(team_damage, self_damage, team_kills)` 的实参顺序与 `_stat_entry` 的键名逐位对应 ✅。

**4. 已知边界（登记不修）**：
- 同一帧内"先被敌人打中、再被自己炸到"时，那一笔会同时进 `dealt`（给那位敌人）与 `self_damage`（给自己）
  —— 两个账户各记一次，不是双计；承自 `ATTRIB_FRESH_MS` 的既有边界。
- 助攻窗口 3s 是**复用**归因窗口，不是为助攻调的（spec §5.3）；要分开调是另一件事。
- 离开对局的玩家：他的 `_assist_times` 条目留在表里（几十字节，随宿主一起销毁）；
  他从"被助攻"名单里消失是自然的（他的倒地边沿不再发生）。
- 本计划**不**给 `_respawn_player` 加"清自伤标记"：8ms 的窗口自带过期，
  加清空只是多一个触点（既有那两处清 `last_damager*` 是因为它是 3s 窗口）。
