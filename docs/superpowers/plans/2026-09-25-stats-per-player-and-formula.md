# 逐人统计面上提 + 新计分公式（kscore / ACS / MVP）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把逐人统计（含 `deaths` / `dealt` / `taken` / `assists` / 惩罚项）从 `TeamHost` **上提到
`MatchState` 底座**，并把计分从「按敌方存活人数加权 + 死亡不扣分」换成**三模式通用、含死亡与惩罚**的
一套（`kscore` / `acs` / `mvp` 全部读时推导）。

**Architecture:** 三层分工，缺一层都会让口径漂：
① **纯逻辑层** 新建 `core/sim/score_rules.gd`（`ScoreRules`，无 autoload、`-s` 可测）—— 公式与权重
**只有这一份**，它能被 `-s` 冒烟直接钉性质；
② **底座** `MatchState` 持原始计数 + 读时推导（`_kscore_of` / `_acs_of` / `stats_payload` / `mvp_role`），
由此三模式共用（1v1 与大乱斗的**写入点**归计划 3，本计划只保证底座接得住）；
③ **写入钩子** `MatchCombat._on_player_hit`（`took_hit` 的唯一消费者）—— 三模式**已经**都接在这条线上
（`MatchHost._wire_hit_feedback`），故 `dealt`/`taken` 自动覆盖三模式，一行都不用改各模式的 `_ready`。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`-s` 冒烟 + 场景探针（`--headless`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-stats-and-results-design.md` §3.1 + §3.2 + §3.3
（计划 1/3，另见 `.superpowers/sdd/stats-spec-verify.md` 的核验结论）。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless` 或 `-s`、**不占任何端口**；**实机验收归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，
  别用 `-m "…"`（双引号会**静默吞掉**反引号与 `$`）。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`；本计划不引入新字号）。
- 改 GDScript 只需重导出，别重编裁剪模板。
- ★ **新建 `class_name` 文件后必须跑一次 `--import`**：全局类缓存不刷，引用处一律 Parse Error
  （本仓既有教训）。Task 1 Step 3 有确切命令。
- ★ **子类不得重复声明基类成员** —— 那是**硬 Parse Error**
  （`The member "…" already exists in parent class …`，引擎源码 `gdscript_analyzer.cpp:301`）。
  本计划上提 `_left` / `_stats` / `_left_round` / `ATTRIB_WINDOW` / `ATTRIB_FRESH_MS`，
  **同一步里必须删掉子类那几行声明**（`server/team_host.gd:28,71,78,79,80`、
  `server/royale_host.gd:26,253`）。
- ★ **底座代码里不得出现 `_attributed_killer` 这个字面量**（`tests/kh_l5_probe.gd:544-549` 的反向
  断言按**剥注释后的子串**扫基类并集，命中即红，且它把 5 个名字列为"子类方法不得进基类"）。
  注释会被剥掉、安全；写进**字符串**就红。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `core/sim/score_rules.gd` | 计分口径（纯静态、无 autoload、`-s` 可测） | **全新建** |
| `tests/score_rules_smoke.gd` | `-s` 冒烟：钉**性质**（不是数值） | **全新建** |
| `server/match_state.gd` | 对局底座：状态 + 出生点 + RPC 助手 | **加**逐人统计的字段与推导口（从 `TeamHost` 上提）；**加** `ATTRIB_WINDOW`/`ATTRIB_FRESH_MS` |
| `server/match_combat.gd` | 子弹/爆炸/光束裁决域 | `_on_player_hit` **加** `dealt`/`taken` 累计（从 `TeamHost` 上提） |
| `server/team_host.gd` | 3v3 权威对局 | **删**逐人统计那一整段 + 旧公式 + `_on_player_hit` 覆写 + 5 处重复声明 |
| `server/royale_host.gd` | 大乱斗权威对局 | **删** `var _left` 与 `const ATTRIB_WINDOW`（上提到基类） |
| `tests/team_host_probe.gd` | 3v3 权威探针（⑬ 一族 = 逐人数据/ACS/MVP） | **改写** ⑬d/⑬e/⑬f/⑬g/⑬h 的期望值与夹具、`dmg`→`dealt`、新增"旧公式已删"的负向断言 |
| `CLAUDE.md` | 项目约定 | **订正** `stats` 载荷的字段集与计分口径 |

---

### Task 1: 新纯逻辑 `ScoreRules` + `-s` 冒烟（先红后绿）

**Files:**
- Create: `core/sim/score_rules.gd`
- Create: `tests/score_rules_smoke.gd`

**Interfaces:**
- Produces（给 Task 2 与计划 2 用）:
  - `ScoreRules.KILL_SCORE` = 100 / `ASSIST_SCORE` = 50 / `DAMAGE_PER_POINT` = 5 /
    `DEATH_PENALTY` = 50 / `TEAM_KILL_PENALTY` = 100
  - `ScoreRules.penalty(team_damage: int, self_damage: int, team_kills: int) -> int`
  - `ScoreRules.kscore(kills, assists, dealt, deaths, team_damage := 0, self_damage := 0, team_kills := 0) -> int`
  - `ScoreRules.acs(total_kscore: int, rounds: int) -> float`

- [ ] **Step 1: 先写冒烟（此时会红 —— `load()` 拿不到文件）**

创建 `tests/score_rules_smoke.gd`：

```gdscript
extends SceneTree

# 计分口径的**性质**冒烟(纯逻辑,无 autoload)。
# 跑法: source tests/env.sh && "$GODOT" --headless --path . -s res://tests/score_rules_smoke.gd
# 通过 = `SCORE RULES: ALL-OK` 退出 0。
#
# ★★ 本文件**刻意不钉权重数值**(100/50/5/50/100 是首版默认值、预期会被调,见 spec §3.2),
#   钉的是**性质**:击杀更多 ⇒ ACS 更高 / 死亡更多 ⇒ ACS 更低 / 惩罚 ⇒ ACS 更低 /
#   助攻 ⇒ ACS 更高 / **伤害只被计入一次**。
#   调权重不该让本文件变红;把某一项从公式里删掉**必须**让它变红(见 Task 3 Step 1 的反证)。
#
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。

func _initialize() -> void:
	var script = load("res://core/sim/score_rules.gd")
	if script == null:
		print("SCORE RULES: FAIL(load res://core/sim/score_rules.gd 失败 —— 文件还没建?)")
		quit(1)
		return
	var fails: Array[String] = []
	# 直取静态口:本文件不 `new()`,全部是 static func。
	var SR: GDScript = script

	# ① 击杀更多 ⇒ ACS 更高
	var a_k := SR.acs(SR.kscore(1, 0, 0, 0), 1)
	var b_k := SR.acs(SR.kscore(3, 0, 0, 0), 1)
	if not (b_k > a_k):
		fails.append("★ 击杀更多 ⇒ ACS 更高 不成立(%f → %f)" % [a_k, b_k])

	# ② 死亡更多 ⇒ ACS 更低(今天**不成立**;这条是新性质,也是"MVP 常在败方"的守卫)
	var a_d := SR.acs(SR.kscore(3, 0, 0, 0), 1)
	var b_d := SR.acs(SR.kscore(3, 0, 0, 3), 1)
	if not (b_d < a_d):
		fails.append("★ 死亡更多 ⇒ ACS 更低 不成立(%f → %f);★ 反证用:把 kscore 里的死亡项删掉即红"
				% [a_d, b_d])

	# ③ 惩罚 > 0 ⇒ ACS 更低
	var a_p := SR.acs(SR.kscore(3, 0, 0, 0, 0, 0, 0), 1)
	var b_p := SR.acs(SR.kscore(3, 0, 0, 0, 0, 0, 1), 1)   # 击杀队友 1 次
	if not (b_p < a_p):
		fails.append("★ 惩罚 > 0 ⇒ ACS 更低 不成立(%f → %f)" % [a_p, b_p])

	# ④ 助攻 ⇒ ACS 更高
	var a_a := SR.acs(SR.kscore(2, 0, 0, 0), 1)
	var b_a := SR.acs(SR.kscore(2, 2, 0, 0), 1)
	if not (b_a > a_a):
		fails.append("★ 助攻 ⇒ ACS 更高 不成立(%f → %f)" % [a_a, b_a])

	# ⑤ ★★ **伤害只被计入一次**(spec §1.4 那条必须写死的口径)
	#   构造"只把伤害 +100、其余全同"的两个 case,断言 ACS 的增量**恰好**等于
	#   `100 ÷ DAMAGE_PER_POINT ÷ 局数` —— 而不是它再加上那 100 伤害本身。
	#   ★ 两个数(2 局):`d0 = (0 + 100/5)/2 = 10`、`d1 = (0 + 200/5)/2 = 20`
	#     ⇒ 期望增量 = `100/5/2` = **10**。
	#   ★ 鉴别力:`acs = (kscore + dealt) / 局数` 那种双计实现给出 `d0 = (20+100)/2 = 60`、
	#     `d1 = (40+200)/2 = 120` ⇒ 增量 **60**(不是 10)⇒ 当场红。
	var d0 := SR.acs(SR.kscore(0, 0, 100, 0), 2)     # 总伤害 100、2 局
	var d1 := SR.acs(SR.kscore(0, 0, 200, 0), 2)     # 只多 100 伤害
	var want_delta := 100.0 / float(SR.DAMAGE_PER_POINT) / 2.0
	if absf((d1 - d0) - want_delta) > 0.0001:
		fails.append("★ 伤害只被计入一次:期望 ACS 增量 %f,实得 %f(差值 %f)—— 差得更大就是双计"
				% [want_delta, d1 - d0, (d1 - d0) - want_delta])

	# ⑥ 惩罚的构成:队友/自己伤害按**同倍率**(与伤害 1:1 冲销),击杀队友另加一份重罚
	var p_dmg := SR.penalty(50, 50, 0)               # (50+50)/5 = 20
	var p_kill := SR.penalty(0, 0, 1)                # 0 + 1×TEAM_KILL_PENALTY
	if p_dmg != 50 / int(SR.DAMAGE_PER_POINT) * 2:
		fails.append("★ 惩罚的伤害项应 = (友伤+自伤)/5(50+50 → 20),实得 %d" % p_dmg)
	if p_kill != int(SR.TEAM_KILL_PENALTY):
		fails.append("★ 惩罚的击杀队友项应 = TEAM_KILL_PENALTY,实得 %d" % p_kill)

	# ⑦ 局数下限 1:0 局不得除零(既有口径 `maxi(rounds, 1)`)
	if SR.acs(SR.kscore(1, 0, 0, 0), 0) != float(SR.kscore(1, 0, 0, 0)):
		fails.append("★ 局数 0 时必须按 1 局算(不得除零/不得给 0)")

	if fails.is_empty():
		print("SCORE RULES: ALL-OK")
		quit(0)
	else:
		print("SCORE RULES: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
```

- [ ] **Step 2: 跑一次，确认它红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/score_rules_smoke.gd 2>&1 | grep -E "SCORE RULES"
```
Expected: `SCORE RULES: FAIL(load res://core/sim/score_rules.gd 失败 —— 文件还没建?)`

- [ ] **Step 3: 建 `core/sim/score_rules.gd`**

```gdscript
class_name ScoreRules
extends RefCounted

# 逐人计分口径(**纯静态、无 autoload、可 `-s` 测**)。
# ★ 为什么单独成文件:口径要能被 `-s` 冒烟直接钉(性质断言),而宿主链
#   (`MatchState` → …)引用 `NetBus`,静态引用它会连带编译到 autoload ⇒ `-s` 里
#   **连 `_initialize()` 都进不去、直接挂到 timeout**。与 `core/sim/weapon_inventory.gd` /
#   `core/sim/explosion.gd` 同款取舍(纯逻辑、可 `-s` 测)。
# ★ 三模式共用**同一份** —— 这正是统计面能上提到基类的前提:旧口径
#   `kill_bonus_score(敌方存活人数)` 在 1v1(两人)与大乱斗(自由混战)里根本没有对应物。
#
# ★★ 五个权重是**首版默认值,属于平衡参数、预期会被调**(spec §3.2)。守卫在 `tests/score_rules_smoke.gd`
#   里钉的是**性质**(死亡多 ⇒ ACS 低…),不是这几个数本身 —— 调数不该让任何探针红。

const KILL_SCORE := 100          # 一个击杀
const ASSIST_SCORE := 50         # 一次助攻
const DAMAGE_PER_POINT := 5      # 伤害 ÷ 5:打光一个人(玩家满血 50)≈ 10 分
const DEATH_PENALTY := 50        # 死一次 = 半个击杀:疼,但不至于让"敢冲"亏本
const TEAM_KILL_PENALTY := 100   # 击杀队友:额外重罚一个击杀的分量


# 惩罚 = (对队友造成的伤害 + 对自己造成的伤害) ÷ 5 + 击杀队友 × 100
# ★ 伤害项与"伤害"**同倍率**(`DAMAGE_PER_POINT`)⇒ 友伤在伤害那一项上 1:1 冲销,不双重惩罚。
# ★ 三项都记在**肇事者**身上(调用方保证),只减分、不进 `dealt` / `taken`。
static func penalty(team_damage: int, self_damage: int, team_kills: int) -> int:
	return (team_damage + self_damage) / DAMAGE_PER_POINT + team_kills * TEAM_KILL_PENALTY


# 总积分。★ **伤害只在这里出现一次** —— 读端(`acs`)不得再加:那正是"伤害被算两次"的
# 唯一入口,而且双计**不报错**,只是所有排名静默偏移(spec §1.4)。
static func kscore(kills: int, assists: int, dealt: int, deaths: int,
		team_damage: int = 0, self_damage: int = 0, team_kills: int = 0) -> int:
	return kills * KILL_SCORE \
			+ assists * ASSIST_SCORE \
			+ dealt / DAMAGE_PER_POINT \
			- deaths * DEATH_PENALTY \
			- penalty(team_damage, self_damage, team_kills)


# 场均。局数下限 1(与既有 `_acs_of` 的 `maxi(_rounds_for(role), 1)` 同口径)。
static func acs(total_kscore: int, rounds: int) -> float:
	return float(total_kscore) / float(maxi(rounds, 1))
```

- [ ] **Step 4: 刷类缓存 + 跑冒烟，确认转绿**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . --import >/dev/null 2>&1
"$GODOT" --headless --path . -s res://tests/score_rules_smoke.gd 2>&1 | grep -E "SCORE RULES"
```
Expected: `SCORE RULES: ALL-OK`。
★ **`--import` 这一步不可省**：`ScoreRules` 是新 `class_name`，缓存不刷的话 Task 2 里
`match_state.gd` 引用它一律 Parse Error。

- [ ] **Step 5: 提交**

```bash
git add core/sim/score_rules.gd tests/score_rules_smoke.gd
git commit -m "feat(stats): 三模式通用计分口径 ScoreRules(纯静态 + 性质冒烟)"
```

---

### Task 2: 统计面上提到 `MatchState`（探针先改红，再改生产）

**Files:**
- Modify: `tests/team_host_probe.gd`（先改 —— 让它对新公式红）
- Modify: `server/match_state.gd`（上提）
- Modify: `server/match_combat.gd`（`_on_player_hit` 加累计）
- Modify: `server/team_host.gd`（删被上提的那一大段）
- Modify: `server/royale_host.gd`（删两处重复声明）

**Interfaces:**
- Consumes: Task 1 的 `ScoreRules`。
- Produces（计划 2 / 3 依赖）:
  - 底座字段 `_stats`（原始计数）/ `_left` / `_left_round`、常量 `ATTRIB_WINDOW` / `ATTRIB_FRESH_MS`
  - 底座函数 `_stat_entry(role) -> Dictionary`、`_kscore_of(role) -> int`、`_acs_of(role) -> float`、
    `_rounds_for(role) -> int`、`_roster() -> Dictionary`、`stats_payload() -> Dictionary`、
    `mvp_role() -> int`、`_fresh_attacker_role(victim_role) -> int`、
    `_attributed_role_within(victim, window_ms) -> int`、`_record_down(victim_role, killer_role) -> void`
  - 原始计数的键集：`kills` / `deaths` / `assists` / `dealt` / `taken` / `team_damage` /
    `self_damage` / `team_kills`（后三个由计划 2 写，本计划只保证存在且为 0）
  - `stats_payload()` 的每条 = `{kills, deaths, assists, dealt, taken, kscore, acs}`

- [ ] **Step 1: 先改探针（让它对新口径红）**

★ **定位规则(本步有 (a)~(j) 十处协同编辑)**:下面给的行号是**本次读到的**行号;
`(a)` 一执行,整份探针的行号就整体下移(本批约 +15 行)⇒ **从 (b) 起一律按代码块内容定位**
(每处都给了可搜索的锚点字符串/原行原文),行号只用来**先扫一眼确认位置**,不要按它跳。
收尾有一道机械兜底:`(e)` 末尾那条 `grep -n '"dmg"' tests/team_host_probe.gd` 必须零命中。

**(a) 三个读数助手**（替换 `tests/team_host_probe.gd:103-107` 的 `_stat`，并在其后加两个）：

```gdscript
# ── ⑬(逐人数据 + ACS/MVP)的小工具 ──
# 读一个人的**原始计数**(缺条目 = 0,与生产 `_stat_entry` 的默认值同口径)。
# ★ 原始条目里**没有** `kscore` 这个键(它是读时推导出来的)⇒ 积分一律走 `_kscore`。
func _stat(host, role: int, key: String) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get(key, 0))


# 逐人积分 / 场均:**读生产载荷**(推导值),别自己重算公式 —— 重算就是第二份真相。
# ★ 这条读法在"改生产之前"也能跑(`stats_payload` 两个世界都有),故本 Task 的红是**干净的值不匹配**,
#   不是"方法不存在 ⇒ 出错 ⇒ 整段静默跳过 ⇒ 假绿"。
func _kscore(host, role: int) -> int:
	return int(host.stats_payload()[int(role)]["kscore"])


func _acs(host, role: int) -> float:
	return float(host.stats_payload()[int(role)]["acs"])
```

**(b) `_set_stats` 夹具**（替换 `:146-150`）—— 六列、键按新口径：

```gdscript
# 手摆逐人表(⑬f/⑬g/⑬h 要的是**精确相等**的读数,靠真打摆不出来)。
# rows = [[role, kills, deaths, assists, dealt, taken], …];惩罚三键一律 0(那是计划 2 的面),
# 于是读数完全由前五项 + 局数决定,手算得出(`acs` 走生产 `_acs_of`)。
func _set_stats(host, rows: Array) -> void:
	host._stats = {}
	for row in rows:
		host._stats[int(row[0])] = {
			"kills": int(row[1]), "deaths": int(row[2]), "assists": int(row[3]),
			"dealt": int(row[4]), "taken": int(row[5]),
			"team_damage": 0, "self_damage": 0, "team_kills": 0}
```

**(c) ⑬ 重置块里删一行**（`:869` 的 `_host._round_kills = {}`）—— `_round_kills` 随多杀加成一起删除。
把那一行整行删掉（连同 ⑬ 开头那段注释里提到它的字眼）。

**(d) 改一行读数**：把 `_set_stats(_host, [[1, 3, 1, 300]])`（`:1130`）改成
`_set_stats(_host, [[1, 3, 1, 0, 300, 0]])`。

**(e) ⑬a / ⑬i / ⑬b2 / ⑬b3 / ⑬c 的字符串键 `"dmg"` 一律改成 `"dealt"`**（共 **18** 处，
行号：`:885`、`:888`、`:890`、`:891`、`:902`、`:915`、`:917`、`:942`、`:954`、`:956`、`:978`、`:993`、
`:996`、`:1006`、`:1007`、`:1016`、`:1018`、`:1019`；`_set_stats` 里的 `:150` 与 ⑬g 里的
`:1134`/`:1152` 由上面的 (b)/(i) 整块替换，不必单独改）。
★ **变量名不用改**（`st_dmg0` / `st_bdmg0` 之类照旧 —— 它们是读数变量，不是字段键）。
★ **断言的文字里也写着 "dmg"**（如 `攻击者 dmg 恰好 +7`、`不去掉异队过滤就是「朝队友扔雷刷 ACS」`
那一条的括号里）—— 一并把那个词改成 `dealt`，免得下一个人以为这几条断言验的是另一个字段。
★ 收尾核对：`grep -n '"dmg"' tests/team_host_probe.gd` 必须**零命中**。

**(f) ⑬d 整段替换**（`:1021-1051`）—— 静态表删掉，改成"不再按敌方存活人数加权" + 源码级负向断言：

```gdscript
	# ── ⑬d 击杀分不再依赖敌方存活人数(旧 `kill_bonus_score` 那张表已删)──
	# ★ 旧口径按"倒下瞬间的敌方存活人数"加权(70/90/110),在**局内复活**的规则下语义反转
	#   (spec §1.3:败方每个击杀更值钱)。新公式里一个击杀恒为 `ScoreRules.KILL_SCORE`。
	# ★ 本段的期望值写**字面量**、不从生产函数取 —— 两张一起才既钉住"权重是多少上下文无关"、
	#   又钉住"生产真的走了这条"。
	var st_want_kill := 100
	# (d1) 敌方 3 人全在时击杀 → +100
	_next_round_clean(_host)
	_check(_team_alive(_host, 2) == 3,
			"[仪器] ⑬d 阶段①:2 队 3 人全在(实际 %d)" % _team_alive(_host, 2))
	var st_ks1 := _kscore(_host, 1)
	_down(_host, 4, 1)
	var st_gain1 := _kscore(_host, 1) - st_ks1
	_check(st_gain1 == st_want_kill,
			"★ ⑬d 敌方 3 人全在时击杀 → kscore +%d(实际 +%d)" % [st_want_kill, st_gain1])
	# (d2) 敌方只剩 1 人(= 受害者本人)时击杀 → **同样** +100
	_next_round_clean(_host)
	_down(_host, 5, 0)          # 无归因:不计任何人的击杀(deaths 照计)
	_down(_host, 6, 0)
	_check(_team_alive(_host, 2) == 1,
			"[仪器] ⑬d 阶段②:2 队只剩 1 人(实际 %d)" % _team_alive(_host, 2))
	var st_ks3 := _kscore(_host, 3)
	_down(_host, 4, 3)
	var st_gain3 := _kscore(_host, 3) - st_ks3
	_check(st_gain3 == st_want_kill,
			("★ ⑬d 敌方只剩 1 人时击杀 → **同为 +%d**(实际 +%d)—— 两档增量必须**相等**;"
			+ "按存活人数加权的旧实现给出 110 与 70") % [st_want_kill, st_gain3])
	# (d3) 源码级负向断言:旧公式那一族在生产目录里**零命中**(删干净了,不是"还在但没人调")
	var st_old_needles := ["kill_bonus" + "_score", "_enemy_alive" + "_including_victim",
			"MULTI_KILL" + "_BONUS"]
	for st_nd in st_old_needles:
		var st_hits: Array[String] = []
		for st_f in ScanUtil.collect(["res://server", "res://core"]):
			if ScanUtil.code_only(ScanUtil.read(st_f)).contains(st_nd):
				st_hits.append(st_f)
		_check(st_hits.is_empty(),
				"★ ⑬d 旧公式残留:%s 命中 %s(新公式没有多杀加成、也不看敌方存活人数)"
				% [st_nd, ", ".join(st_hits)])
```

**(g) ⑬e 整段替换**（`:1053-1069`）—— 多杀加成已删，改成"第二次击杀同价"：

```gdscript
	# ── ⑬e 不再有多杀加成:同一局内第 2 杀的增量与第 1 杀**相同**──
	# ★ 2026-09-25:旧的「同一局内第 2、3… 个击杀各 +50」已随加权公式一起删除
	#   (`MULTI_KILL_BONUS` / `_round_kills`)。本段留着是因为"加成被悄悄加回来"**不会有别处变红**。
	_next_round_clean(_host)
	var st_m0 := _kscore(_host, 1)
	_down(_host, 4, 1)          # 第 1 杀
	var st_m1 := _kscore(_host, 1) - st_m0
	_down(_host, 5, 1)          # 第 2 杀(旧口径:90 + 50 多杀加成 = 140)
	var st_m2 := _kscore(_host, 1) - st_m0 - st_m1
	_check(st_m1 == 100, "★ ⑬e 第 1 杀 = 100(实际 +%d)" % st_m1)
	_check(st_m2 == 100,
			"★ ⑬e 同一局内第 2 杀**同为 100**(实际 +%d;旧实现是 140)" % st_m2)
```

**(h) ⑬f 的三处夹具与读数替换**（`:1077`、`:1080`、`:1087`、`:1094`、`:1114`）：

| 原行 | 改成 |
|---|---|
| `_set_stats(_host, [[1, 0, 0, 300], [3, 0, 0, 100]])` | `_set_stats(_host, [[1, 0, 0, 0, 300, 0], [3, 0, 0, 0, 100, 0]])` |
| `_set_stats(_host, [[3, 0, 0, 300], [5, 0, 0, 300]])` | `_set_stats(_host, [[3, 0, 0, 0, 300, 0], [5, 0, 0, 0, 300, 0]])` |
| `_set_stats(_host, [[3, 2, 0, 300], [5, 5, 0, 300]])` | `_set_stats(_host, [[3, 2, 0, 0, 1500, 0], [5, 5, 0, 0, 0, 0]])` |
| `_set_stats(_host, [[3, 2, 5, 300], [5, 2, 1, 300]])` | `_set_stats(_host, [[3, 2, 5, 0, 1300, 0], [5, 2, 1, 0, 300, 0]])` |
| `_set_stats(_host, [[5, 2, 1, 300], [3, 2, 1, 300]])` | `_set_stats(_host, [[5, 2, 1, 0, 300, 0], [3, 2, 1, 0, 300, 0]])` |

★★ **f3 与 f4 的新夹具都不是随手填的** —— 新公式下"ACS 并列"必须**手工配平**，
而配平式子是 `kscore = kills×100 + dealt/5 − deaths×50`（协助 0、惩罚 0）：
· **f3**（ACS 并列 → 比击杀数）：kills 2 vs 5 ⇒ 只差击杀一项就有 `300` 分的缺口
  ⇒ 伤害项要补掉它：`dealt/5` 差 300 ⇒ **dealt 差 1500**（1500 vs 0）。
  配平后两边 kscore 都是 `200+300 = 500` ⇒ ACS 并列成立，击杀多者（5 号）胜出。
  ★ 原先写的 `dealt 300 / 300` 在**旧**公式下才"并列"（两边都取不到 `dealt` ⇒ 都 0），
  在新公式下是 `260 vs 560` —— 那样**该档自己的 `[仪器] 前提：两人 ACS 并列` 断言会红**，
  即"生产改对了这一档照样红"。别照旧公式配平。
· **f4**（ACS 与击杀都并列 → 比阵亡数）：kills 同为 2 ⇒ `200 + dealt/5 − deaths×50`；
  deaths 5 与 1 差 4 ⇒ 伤害项要补 `4×50 = 200` 分 ⇒ `dealt/5` 差 200 ⇒ **dealt 差 1000**
  （1300 vs 300）。配平后两边 kscore 都是 210 ⇒ 并列成立、阵亡才有得比（MVP 给 5 号）。
★ 同时把 `st_pay[3]["acs"]` 等**读法**统一换成 `_acs(_host, 3)`；
把 `float(st_pay[...]["acs"])` 那一族断言里的读数替换掉（`stats_payload()` 的键名不变，故也可以
保留 `st_pay` 只改值 —— 选一种，别两套混用）。
★ (f2) 的期望不是"数值 300 并列"而是"**ACS 并列**"（新值 60）—— 断言本身没变，故这一档不用改文字。

**(i) ⑬g 整段替换**（`:1129-1160`）—— 键集从 5 个变 7 个，acs 期望 310：

```gdscript
	# ── ⑬g 载荷与口径 ──
	_set_stats(_host, [[1, 3, 1, 0, 300, 0]])
	_host._round_num = 1
	var st_pay2: Dictionary = _host.stats_payload()
	var st_shape_bad: Array[String] = []
	# ★★ 顺序是 `dealt` **在 `deaths` 之前** —— 别"顺手纠正"回去:
	#   Godot 的 `Array.sort()` 对 String 走**逐码点**比较(`Variant::operator<` →
	#   `String::operator<` → `str_compare`),而不是按字母表直觉 —— `"dealt"` 与 `"deaths"`
	#   第 4 个字符是 `l`(0x6C) vs `t`(0x74) ⇒ `dealt < deaths`。`String.to_lower()` 也好、
	#   "字典序看着像错"也好,都不影响这条;写成 `[…, deaths, dealt, …]` 会让**生产改对了
	#   形状断言照样红**,而错误的修法(放宽成"包含这七个键就行")会把"载荷字段集"这条
	#   真契约拆掉 —— 所以这里必须是**逐码点升序**。
	var st_want_keys := ["acs", "assists", "dealt", "deaths", "kills", "kscore", "taken"]
	for st_k in _host.players:
		var st_row: Dictionary = st_pay2.get(int(st_k), {})
		if st_row.is_empty():
			st_shape_bad.append("role %d 缺行" % int(st_k))
			continue
		var st_keys: Array = st_row.keys()
		st_keys.sort()
		if st_keys != st_want_keys:
			st_shape_bad.append("role %d 的键 %s" % [int(st_k), str(st_keys)])
	_check(st_shape_bad.is_empty(),
			"★ ⑬g 载荷形状:在场者**人人一行**、键恰好七个(问题:%s)" % str(st_shape_bad))
	# 手算:kscore = 3 kills×100 + 300 dealt/5 − 1 death×50 = 300 + 60 − 50 = 310;acs = 310/1
	_check(absf(float(st_pay2[1]["acs"]) - 310.0) < 0.0001,
			("★ ⑬g acs = kscore / 局数 = (3×100 + 300/5 − 1×50)/1 = 310(实际 %f)"
			+ ";★ 反证:把 ScoreRules 的死亡项删掉这里会变成 360)")
			% float(st_pay2[1]["acs"]))
	_check(int(st_pay2[1]["kills"]) == 3 and int(st_pay2[1]["deaths"]) == 1
			and int(st_pay2[1]["dealt"]) == 300,
			"★ ⑬g kills/deaths/dealt 原样带出(实际 %d/%d/%d)"
			% [int(st_pay2[1]["kills"]), int(st_pay2[1]["deaths"]), int(st_pay2[1]["dealt"])])
```

（⑬g 后半段那两条**源码级**断言 —— `data["stats"]` / `data["mvp"]` / `if not table.is_empty():`
与 `_wire_hit_feedback` 的归属 —— **原样保留**，一个字不动。）

**(j) ⑬h 的夹具与期望**（`:1169`、`:1178-1182`）：

```gdscript
	_set_stats(_host, [[1, 0, 0, 0, 500, 0], [6, 0, 0, 0, 300, 0]])
```
```gdscript
	_check(absf(float(st_pay3[6]["acs"]) - 30.0) < 0.0001,
			("★ ⑬h 离开者:分母 = 他实际参与的局数(kscore 60 ÷ 2 局 = 30,实际 %f;"
			+ "按全场 5 局算会是 12)") % float(st_pay3[6]["acs"]))
	_check(absf(float(st_pay3[1]["acs"]) - 20.0) < 0.0001,
			"★ ⑬h 在场者:分母仍是**全场局数**(kscore 100 ÷ 5 = 20,实际 %f)" % float(st_pay3[1]["acs"]))
```

★ ⑬j 的注释里那句"6 号的 ACS = 300/2 = 150 高于 1 号的 500/5 = 100"要同步改成
"60/2 = 30 高于 100/5 = 20"（`tests/team_host_probe.gd:1185-1191`）—— 注释不改会让下一个人
按旧数读懂不了这条守的到底是什么。**断言本身（`mvp_role() == 6`）不变**。

- [ ] **Step 2: 跑一次，确认它红（红在"值不对"，不是"跑不起来"）**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|FAIL"
```
Expected（改生产**之前**）—— 下面这些**逐条**应当红（这是**改过一遍的**清单：核验时原稿
漏了 ⑬a/⑬i/⑬b3/⑬e 的第一条/⑬h/⑬j，并把⑬f 那一条写成了会红的样子 —— 实际 ⑬f 只有 (f2) 会红）：

| 红在哪 | 期望 → 实际（旧生产） | 为什么夹具能到达 |
|---|---|---|
| ⑬a `攻击者 dealt 恰好 +7` | 7 → **0** | 旧 `_on_player_hit` 写的是 `dmg` 键，新探针读 `dealt` |
| ⑬i `伤害记到射手 dealt` | +11 → **+0** | 同上（子弹那一路也走同一个钩子） |
| ⑬b3 `敌方爆炸照常计入 dealt` | +30 → **+0** | 同上（爆炸 AoE 也走同一个钩子） |
| ⑬d `敌方 3 人全在 → +100` | 100 → **110** | 旧 `kill_bonus_score(3) = 50+20×3`（`team_host.gd:676`） |
| ⑬d `敌方只剩 1 人 → 同为 +100` | 100 → **70** | 旧 `kill_bonus_score(1) = 70` |
| ⑬d `旧公式残留`（3 条） | 零命中 → **命中 3 处** | 三个词条都还在 `server/team_host.gd`（`:44` / `:676` / `:746`） |
| ⑬e `第 1 杀 = 100` | 100 → **110** | 与 ⑬d 第一条同因 |
| ⑬e `第 2 杀同为 100` | 100 → **140** | 旧：`90 + MULTI_KILL_BONUS`（`:735-739`） |
| ⑬f **(f2)** `ACS 并列 → 击杀多者(5 号)` | 3 → **1** | 旧 `_acs_of` 读不到 `dealt` ⇒ 六人 ACS 全 0；`_roster()` 含全部 6 个 `players`，`roles.sort()` 后**第一个是 role 1**，而 `mvp_role` 只在**严格更优**时替换 ⇒ 全 0 并列时胜者是 1 号 |
| ⑬g 形状（键集） | 7 个 → **5 个** | 旧 `stats_payload` 给 `{kills,deaths,dmg,kscore,acs}` |
| ⑬g `acs = 310` | 310 → **0.0** | 旧 `_acs_of` = `(kscore + dmg)/局数`，两个键都缺席 |
| ⑬g `dealt 原样带出` | 300 → **0** | 同上 |
| ⑬h `离开者 acs = 30` | 30 → **0.0** | 同上（分母对、分子恒 0） |
| ⑬h `在场者 acs = 20` | 20 → **0.0** | 同上 |
| ⑬j `已离开者仍是 MVP 候选` | 6 → **1** | 与 (f2) 同因（全 0 并列 → role 升序 → 1 号） |
| ⑬j 的确定性那条 | 3 → **1**（也红） | 同上 |

★ **⑬f 的 (f1)/(f3)/(f4)/(f5) 与 ⑬b/⑬b2/⑬c 在改生产**之前是绿的** —— 别把它们当"漏改"去追：
- (f1) 期望 MVP=1 号，而全 0 并列时升序第一个正是 1 号 ⇒ **照旧通过**（这正是原稿写错的一条：
  它以为会红）；
- (f3)/(f4)/(f5)：旧读法下六人 ACS 全 0、kills/deaths 却能从新夹具读出来（旧 payload 也读
  `kills`/`deaths` 两个键）⇒ 并列**成立**、并列判据本身给出了期望的那个人 ⇒ 通过；
- ⑬b / ⑬b2 / ⑬c 是**纯负向**断言（"不该涨"）⇒ 恒 0 的实现下必然通过。它们的鉴别力全在
  **改完之后**（去掉 `same_team` 过滤/新鲜度判据就会红），这正是本仓反复强调的
  "负向断言必须配正向对照"—— 那三条的正向对照分别是 ⑬a/⑬i/⑬b3。

★ **为什么红是"值不匹配"而不是"跑不起来"**：`_set_stats` 直接写 `host._stats`（绕过生产统计写入），
而旧 `_acs_of`（`server/team_host.gd:772-775`）读的是条目里的 `kscore`/`dmg` 两个键 —— 新夹具
按新口径写的是 `kills/deaths/assists/dealt/taken`，两个旧键都缺席 ⇒ 恒 0。
助手走 `stats_payload()`（旧生产里也在）而**不是** `host._kscore_of()`：
后者在旧生产里是 `Invalid call. Nonexistent function` ⇒ `_run()` 当场结束、`_finish()` 照打
`ALL-OK` = **假绿**（本仓的已知陷阱；这条差别就是"探针真的会红"与"探针假绿"的差别）。

- [ ] **Step 3: 底座加字段与推导口**

`server/match_state.gd`，在 `var _last_round_winner := 0`（`:108`）之后加：

```gdscript
# ── 逐人统计(三模式共用;★ 2026-09-25 从 `TeamHost` 上提,见下)──
# ★ 为什么现在才提得上去:计分口径换成了不依赖队伍语义的 `ScoreRules`(见
#   core/sim/score_rules.gd)。旧口径 `kill_bonus_score(敌方存活人数)` 在 1v1(两人)与
#   大乱斗(自由混战)里**没有对应物** —— 公式与"上提"是因果关系,不是两件顺手的事。
# ★ 条目存的是**原始计数**(下面 8 个键);`kscore` / `acs` 一律**读时推导**。存一份算好的
#   kscore 就意味着"加了一项新惩罚却忘了同步"这种**不报错**的静默缺陷。
# ★ 载荷才用 spec §3.1 那七个字段(kills/deaths/assists/dealt/taken/kscore/acs)。
var _stats: Dictionary = {}          # role -> 原始计数(整场累计,不随局清零)
var _left_round: Dictionary = {}     # role -> 离开时所处的局号(ACS 的"实际参与局数"口径)
# role -> true(已移出对局)。★ **必须住底座**:`_roster()` / `mvp_role()` 都要读它,
# 而 `RoyaleHost` 与 `TeamHost` 原先**各声明了一份**(上提时那两行必须一起删 —— 子类重复声明
# 基类成员是硬 Parse Error,见 Global Constraints)。
var _left: Dictionary = {}
# 归因时效(3s)。★ 三个读者原先各抄一份(`RoyaleHost`/`TeamHost` 各一个同名常量 + 单机播报);
# 收在底座,子类那两行删掉(同名遮蔽报错)。
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS
# "**这一下**伤害是谁打的" —— 归因必须**新鲜**的阈值(ms)。
# ★ 与 `ATTRIB_WINDOW` 是**两个问题、两个窗口**:`ATTRIB_WINDOW`(3s)答"这次死亡算谁的击杀",
#   本阈值答"这一下伤害是谁打的"。★ 不能与击杀口径共用:击杀读的 3s 是"打一枪后 3s 内溺水
#   仍算你的击杀";拿它判"**这一下**伤害是谁打的"太宽(一次 0.4s 引信的榴弹自爆就会被计入)。
# ★ 阈值怎么定:真实命中路径的 `attribute()` → `take_hit()` → `took_hit` 信号是**同一调用栈**,
#   年龄 ≈ 0~1ms;而**上一物理帧**留下的归因至少 ~16.7ms 之前(60Hz)。8ms 落在两者之间:
#   容得下跨一次毫秒边界,又把"上一帧那次命中"挡在外面。
# ★★ 阈值成立的前提是"**归因与伤害同一调用栈**"(真实命中路径 ≈ 0~1ms)。**将来新增
#   「延迟扣血」型伤害必须自己每帧重写归因** —— `LaserWeaponBase` 的**缝 2**(命中结算)明确
#   把"持续/灼烧型"列为**预定扩展位**,而那种实现是"命中时写一次归因、后续帧再扣血":扣血
#   那一刻 meta 的年龄早已 > 8ms ⇒ 被**静默**判成"无攻击者",逐人伤害恒少且不报错
#   (没有断言、没有日志,只是 ACS 偏低)。写端不重写归因的话,这条阈值就是那个扩展位的唯一提示。
#   ★ 本段随常量一起从 `team_host.gd` 搬来(`CLAUDE.md` 的 3v3 小节原先把它的权威落点
#     指在 `team_host.gd` 的 `ATTRIB_FRESH_MS` 上方 —— 那处指针已随本批改到**这里**)。
const ATTRIB_FRESH_MS := 8
```

同一文件、`_role_of` / `is_friendly`（`:139-154`）之后加（**`_attributed_killer` 这个字面量
一个字都不许出现**）：

```gdscript
# ── 逐人统计的读写口(三模式共用;写入点见 MatchCombat._on_player_hit 与各模式的倒地边沿)──

# role 的原始计数条目(惰性建:谁上过场谁才有条目;`stats_payload` 会把在场者补齐)。
func _stat_entry(role: int) -> Dictionary:
	role = int(role)
	if not _stats.has(role):
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0}
	return _stats[role]


# 逐人总积分。★ **唯一推导点** —— 伤害只在 `ScoreRules.kscore` 里出现一次。
func _kscore_of(role: int) -> int:
	var s: Dictionary = _stats.get(int(role), {})
	return ScoreRules.kscore(int(s.get("kills", 0)), int(s.get("assists", 0)),
			int(s.get("dealt", 0)), int(s.get("deaths", 0)),
			int(s.get("team_damage", 0)), int(s.get("self_damage", 0)),
			int(s.get("team_kills", 0)))


# ACS = kscore ÷ 局数。★ **不得再加伤害** —— 它已经在 kscore 里了(spec §1.4:
# 今天 `(kscore + 伤害)/局数` 之所以成立,仅仅因为今天的 kscore **不含**伤害)。
func _acs_of(role: int) -> float:
	return ScoreRules.acs(_kscore_of(int(role)), _rounds_for(int(role)))


# ACS 的"局数"口径:**全场已进行的局数**(`_round_num`);中途离开者**冻结在他离开时所处的局号**
# = 他实际参与的局数。★ 代价(分母更小 ⇒ ACS 偏高)是**有意**的口径,不是 bug。
# ★ 卡在 MATCH_OVER 时 `_round_num` 恰好等于"打过的局数"(`_start_next_round` 在终局分支
#   提前 return,不推进局号)⇒ 终局那一份 ACS 的分母正是整场局数。
func _rounds_for(role: int) -> int:
	return int(_left_round.get(int(role), _round_num))


# 逐人表的 role 集合:在场者 ∪ 已离开者 ∪ 有数据的。
# ★ 在场者**哪怕一次伤害都没打过**也要出现(面板要的是"所有参战者各一行")。
func _roster() -> Dictionary:
	var roles := {}
	for role in players:
		roles[int(role)] = true
	for role in _left:
		roles[int(role)] = true
	for role in _stats:
		roles[int(role)] = true
	return roles


# 逐人数据载荷:`{role: {kills, deaths, assists, dealt, taken, kscore, acs}}`
# (给 `round_state` 的 `stats` 键;三模式同一份)。
func stats_payload() -> Dictionary:
	var out := {}
	for r in _roster():
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		out[role] = {
			"kills": int(s.get("kills", 0)),
			"deaths": int(s.get("deaths", 0)),
			"assists": int(s.get("assists", 0)),
			"dealt": int(s.get("dealt", 0)),
			"taken": int(s.get("taken", 0)),
			"kscore": _kscore_of(role),
			"acs": _acs_of(role),
		}
	return out


# MVP = **整场 ACS 最高者**;并列 → 击杀多者 → 阵亡少者 → **role 号升序**。
# ★ 确定性:候选按 role 升序遍历 + 只在**严格更优**时替换 ⇒ 完全并列时天然胜者是最小 role,
#   不依赖字典迭代顺序(同一份状态调多少次都是同一个答案)。
# ★★ **已离开者照样参与评选 —— 用户裁定,不是遗漏**:取向与大乱斗"按分判胜"一致;
#   他会因"分母 = 实际参与局数"(更小)而更容易胜出,那**也是**有意的口径。
func mvp_role() -> int:
	var best_role := 0
	var best_acs := -1.0
	var best_kills := -1
	var best_deaths := 1 << 30
	var roles: Array = _roster().keys()
	roles.sort()
	for r in roles:
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		var acs := _acs_of(role)
		var kills := int(s.get("kills", 0))
		var deaths := int(s.get("deaths", 0))
		if acs > best_acs \
				or (acs == best_acs and (kills > best_kills
						or (kills == best_kills and deaths < best_deaths))):
			best_role = role
			best_acs = acs
			best_kills = kills
			best_deaths = deaths
	return best_role


# 逐人数据的唯一写入口(每次倒地边沿调一次)。
# ★ `deaths` **一律** +1:队友误炸 / 自杀 / 溺水全算死。
# ★ `kills` **只在"归因到且异队"**时记给杀手 —— 无归因与同队误炸不计**任何人**的击杀
#   (与"那一分照样给对方队"是两件事)。助攻与惩罚由计划 2 在此处/在受击钩子上补。
func _record_down(victim_role: int, killer_role: int) -> void:
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0 or same_team(killer_role, victim_role):
		return
	var k := _stat_entry(killer_role)
	k["kills"] = int(k["kills"]) + 1


# "**这一下**伤害是谁打的" —— 归因必须**新鲜**(`ATTRIB_FRESH_MS`)。无 → 0。
# ★ 为什么必须有一个**紧**窗口(8ms)而不是复用 3s:写端 `CombatFeedback.attribute` 在
#   `attacker == victim` 时**静默跳过**,于是自伤路径上 meta 会**停在上一名敌人**身上,而读端
#   只看"有没有 meta + 在不在时效内" ⇒ "自己的榴弹炸自己"会被错记成那名敌人的伤害。
#   真实命中路径的 `attribute()` → `take_hit()` → `took_hit` 是**同一调用栈**(年龄 ≈ 0~1ms),
#   而上一物理帧留下的归因至少 ~16.7ms 之前 ⇒ 8ms 落在两者之间。
# ★★ 已知边界(登记不修):同**一帧**内先被敌人打中、再被自己的爆炸炸到,meta 仍是那名敌人
#   且年龄 ≈ 0 —— 那一下会被记到敌人账上。
func _fresh_attacker_role(victim_role: int) -> int:
	var victim: Node2D = players.get(int(victim_role))
	if victim == null or not is_instance_valid(victim):
		return 0
	return _attributed_role_within(victim, ATTRIB_FRESH_MS)


# "上一个打 victim 的人"的 role,且归因年龄 ≤ `window_ms`(超窗/无归因/自伤 → 0)。
# ★ 读端有两处,问的是**两个不同的问题**,故窗口是参数而不是常量:击杀归属(子类的
#   `ATTRIB_WINDOW` = 3s)与逐人伤害(`ATTRIB_FRESH_MS` = 8ms)。
# ★ `shooter == victim` 的守卫不可省:写端自伤时静默跳过,但万一有人绕过写端直接 set_meta,
#   这里不能再把自伤算成"自己杀自己"。
# ★ 本函数**住在底座**,但**调用它的击杀归因函数住子类** ——
#   `tests/kh_l5_probe.gd:544-549` 的反向断言把那个名字列为"不得出现在基类并集里"。
func _attributed_role_within(victim: Node2D, window_ms: int) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) > window_ms:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0
```

- [ ] **Step 4: 受击钩子加 `dealt`/`taken` 累计**

`server/match_combat.gd` 的 `_on_player_hit`（`:206`），在**广播循环之前**插入：

```gdscript
func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	# ── 逐人统计(三模式共用;★ 2026-09-25 从 `TeamHost._on_player_hit` 上提)──
	# 一个钩子覆盖**全部**伤害来源(子弹 / 榴弹直击 / 爆炸 AoE / 激光):它们的共同点是
	# "归因写入 `CombatFeedback.attribute` 都在 `take_hit` 之前"(本仓明文纪律,见
	# core/sim/explosion.gd:54 与 scenes/weapons/laser_weapon_base.gd:233),于是
	# `took_hit` 这一刻读 meta 就拿到攻击者。**不必去改 `Explosion`**。
	# ★ `dealt` 与 `taken` **口径对称**(spec §3.1):都只算**敌人** ——
	#   队友爆炸炸到我不进 `taken`、自己炸自己也不进(那两类的代价走**惩罚**,记在肇事者行上)。
	# ★ 三档都不记:自伤(写端静默跳过 ⇒ 由新鲜度挡掉)/ 队友伤害(按队过滤)/
	#   归因不到。★ 后两档在 1v1 / 大乱斗里**天然不成立**:队伍表空 ⇒ `same_team` 恒 false
	#   ⇒ 这两列就等于"对所有人的伤害",不需要特判(spec §5.6 的免费正确性,别去"优化"它)。
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0 and not same_team(stat_attacker, int(role)):
		var sa := _stat_entry(stat_attacker)
		sa["dealt"] = int(sa["dealt"]) + int(damage)
		var sv := _stat_entry(int(role))
		sv["taken"] = int(sv["taken"]) + int(damage)
	for r in peer_by_role:
		# 判活:这是**每次伤害**都发的定向包(交火时最密的一处),原先完全不判 ——
		# 往"正在断开"的 peer 发就是那条 channel 0 错误(判据为何不能用 get_peers 见 NetBus)。
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)
```

- [ ] **Step 5: 从 `TeamHost` / `RoyaleHost` 删掉被上提的一切**

`server/team_host.gd`：
1. **整段删除** `:34-66`（`KILL_BONUS_BASE` … `ATTRIB_FRESH_MS` 那一整块常量与它们的注释）——
   连同 `MULTI_KILL_BONUS` / `ATTRIB_FRESH_MS`。新公式没有加权、没有多杀加成，这些常量**没有读者**。
2. **删除** `:28` 的 `const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS`（上提到基类）。
3. **删除** `:71` 的 `var _left`、`:78-80` 的 `var _stats` / `var _round_kills` / `var _left_round`
   （全部上提；`_round_kills` 随多杀加成一起**彻底删除**）。
4. `:456` 的 `_round_kills = {}` 那一行**删除**（`_start_next_round` 里）。
5. **整段删除** `:549-561`（`_attributed_role_within`，上提到基类）。
6. **整段删除** `:667-837`（`_stat_entry` / `kill_bonus_score` / `_fresh_attacker_role` /
   `_on_player_hit` / `_record_down` / `_enemy_alive_including_victim` / `_rounds_for` / `_acs_of` /
   `_roster` / `stats_payload` / `mvp_role`）—— 全部由底座/`MatchCombat` 提供。
   ★ 该段上方 `:652-663` 的说明注释（用户三条裁定）**不要一起删**：把"逐人数据 / ACS / MVP"
   那三条裁定改写成一段 6 行的指针注释（"这套口径已上提到 `MatchState`，见
   `core/sim/score_rules.gd` 与 `_stat_entry`；本文件只留 3v3 特有的两处写入
   （倒地边沿调 `_record_down`、`_on_bullet_hit` 补归因）"）。
7. **保留不动**：`_attributed_killer`（`:538-539`，子类必须自带）、`_on_bullet_hit`（`:719-721`）、
   `_record_down` 的**调用点**（`:362`）、`_broadcast_round_state`（`:508-528`，`stats`/`mvp`
   两个键的投递原样）。

`server/royale_host.gd`：
1. **删除** `:26` 的 `var _left: Dictionary = {}`（上提到基类）。
2. **删除** `:253` 的 `const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS`（上提到基类）。
   ★ `_attributed_killer`（`:255-268`）里对 `ATTRIB_WINDOW` 的引用**不用改** —— 继承常量照常解析。

- [ ] **Step 6: 跑 —— 确认转绿**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . --import >/dev/null 2>&1
"$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|FAIL"
"$GODOT" --headless --path . -s res://tests/score_rules_smoke.gd 2>&1 | grep -E "SCORE RULES"
```
Expected: `TEAM HOST: ALL-OK` + `SCORE RULES: ALL-OK`，两行都**零 FAIL**。
★ 若有 `Parse Error`，先看 Global Constraints 那条"子类不得重复声明基类成员"——
`_left` / `_stats` / `_left_round` / `ATTRIB_WINDOW` 五处声明是否都删干净了。

- [ ] **Step 7: 反证（把死亡项撤掉，确认又红）**

临时把 `core/sim/score_rules.gd` 的 `kscore` 里 `- deaths * DEATH_PENALTY \` 一行删掉，跑：
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/score_rules_smoke.gd 2>&1 | grep -E "SCORE RULES|死亡"
"$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | grep -E "TEAM HOST|⑬g"
```
Expected: 冒烟红在 **`★ 死亡更多 ⇒ ACS 更低 不成立`**；探针红在
**`★ ⑬g acs = kscore / 局数 = … = 310(实际 360.0)`**。
★ **会连带红一条**：⑬f 的 (f4) —— 那一档的 `[仪器] 前提：两人 ACS 并列` 是新公式下**手工配平**
出来的（dealt 1300 vs 300 正是为了抵掉 `5×50` 与 `1×50` 的差），死亡项一撤，`460 vs 260`，
**前提当场不成立**。那是同一个成因的连带，不是第二处独立缺陷（确认成因后一起还原）。
★ 两步缺一不可：只跑冒烟证明不了"生产真的走了 `ScoreRules`"（探针那条是生产路径的读数）。
确认后**改回来**，再跑一次上一步确认全绿。

- [ ] **Step 8: 提交**

```bash
git add server/match_state.gd server/match_combat.gd server/team_host.gd \
        server/royale_host.gd tests/team_host_probe.gd
git commit -m "refactor(stats): 逐人统计上提 MatchState + 新计分公式(ScoreRules:含死亡与惩罚)"
```

---

### Task 3: 回归 + 登记

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 跑受影响的既有探针**

Run:
```bash
source tests/env.sh
for t in team_host_probe team_table_probe team_disconnect_probe laser_team_probe \
         match_host_hygiene_probe royale_disconnect_count_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
for t in score_rules_smoke team_room_smoke enemy_logic_smoke match_result_payload_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR"
done
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn 2>&1 | grep -E "KH L5|FAIL"
```
Expected: 全绿（`TEAM HOST: ALL-OK` / `TEAM TABLE: ALL-OK` / `TEAM DISCONNECT: ALL-OK` /
`LASER TEAM PROBE: ALL-OK` / `SCORE RULES: ALL-OK` / `TEAM ROOM SMOKE: ALL-OK` / `SMOKE OK` /
`MATCH RESULT PAYLOAD: ALL-OK` / `KH L5 PROBE: ALL-OK`）。
★ `kh_l5_probe` **必须复跑**：本计划往 `match_state.gd` / `match_round.gd` / `match_combat.gd`
（都在它的 `HOST_SRC` 并集里）加了东西，它的反向断言（5 个名字不得进基类）与 C2 四条都在这一跑里。

- [ ] **Step 2: 登记进 CLAUDE.md**

在 §网络与 PvP 的「3v3 团队模式」里，紧挨现有那条
`★★ round_state 的 stats / mvp 两个键…` 的登记，改写它（**保留**"两个键保留、别顺手删"的裁定，
**订正**字段集与计分口径）：

```markdown
- **★★ `round_state` 的 `stats` / `mvp` 两个键（2026-09-25 改写）**：字段集已从
  `{kills, deaths, dmg, kscore, acs}` 变成 **`{kills, deaths, assists, dealt, taken, kscore, acs}`**
  （`dmg`→`dealt`，新增 `assists`/`taken`），且**逐人统计面已从 `TeamHost` 上提到 `MatchState`**
  （`_stat_entry` / `_record_down` / `_rounds_for` / `_roster` / `stats_payload` / `mvp_role` /
  `_kscore_of` / `_acs_of`）—— 1v1/大乱斗的**写入与投递**见后续计划。计分口径收在
  `core/sim/score_rules.gd`（纯静态、`-s` 可测）：`kscore = 击杀×100 + 助攻×50 + 伤害÷5
  − 死亡×50 − 惩罚`，**`acs = kscore ÷ 局数`且读端不得再加伤害**（伤害只在 kscore 里出现一次）；
  旧的 `kill_bonus_score(敌方存活人数)` 加权、`MULTI_KILL_BONUS` 多杀加成与
  `_round_kills` / `_enemy_alive_including_victim` **已整体删除**。
  ★ 三个权重是**平衡参数**：守卫钉的是**性质**（`tests/score_rules_smoke.gd`：死亡多 ⇒ ACS 低…），
  调数不该让探针红。★ "两个键保留、别顺手删"这条裁定**依然有效**，且它们**已有消费者**——
  `ui/match_result_payload.gd::for_team`（2026-09-21 结算页批次起），旧登记里"客户端一行都没消费"
  那半句已过期、照实订正。
```

- [ ] **Step 3: 同步那条"权威落点"指针（不改会变成悬空引用）**

CLAUDE.md 的 3v3 小节里另有一条独立 bullet（**不是**上面那条 `stats`/`mvp` 的）以
`team_host.gd` 的 `ATTRIB_FRESH_MS` 上方为**权威落点**：

```
- **★ `ATTRIB_FRESH_MS = 8ms` 的成立前提是"归因与伤害在**同一调用栈**":… 该提示写在 `team_host.gd` 的 `ATTRIB_FRESH_MS` 上方。
```

本计划把这个常量连同**它上方那整段契约注释**搬到了 `server/match_state.gd`（Task 2 Step 3）——
不改这一句的话，权威落点会指向一个**已经不存在的注释**（后面的人按它去 `team_host.gd` 找，
找不到就会以为那条契约被删了，从而把"延迟扣血要自己重写归因"这条要求一起丢掉）。
把结尾那句改成：

```markdown
该提示写在 `server/match_state.gd` 的 `ATTRIB_FRESH_MS` 上方(2026-09-25 随常量从 `team_host.gd` 上提到基类)。
```

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(claude): 订正逐人统计的字段集与计分口径(上提 MatchState + ScoreRules)"
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3.1 + §3.2 + §3.3）：
§3.1 统一字段集 ✅ Task 2 Step 3 的 `stats_payload` 七键 + `_stat_entry` 八键原始计数；
"上提 `MatchState`" ✅ Task 2 Step 3/5；`taken` 与 `dealt` **口径对称（都只算敌人）** ✅
Task 2 Step 4 的同一分支；
§3.2 新公式 ✅ Task 1 的 `ScoreRules.kscore`（伤害 ÷ 5 / 死亡 × 50 都是它的项）+ "不依赖队伍语义" ✅
（签名里没有队伍参数）；"权重是平衡参数、守卫钉性质" ✅ Task 1 Step 1 的文件头与断言选型；
§3.3 `acs = kscore / 局数` 且**不得再加伤害** ✅ `_acs_of` + 冒烟 ⑤；局数口径沿用 `_rounds_for` ✅
（原样上提，一字未改）；MVP 口径与并列判据不变 ✅（`mvp_role` 原样上提）。
**不做**（spec §8）：实时伤害 HUD / 改爆炸友伤 / 结算页版式 / 拆归因窗口 —— 本计划一概不碰。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。每个改动都给了完整代码块与确切锚点。
★ **两处夹具是配平出来的、不是随手填的**：⑬f 的 f3（dealt 差 1500）与 f4（dealt 差 1000）；
两处都写了配平式子与"照旧公式配平会红"的告警。
★ Task 2 Step 1 开头已声明"行号在 (a) 之后即失效、一律按代码块内容定位"。

**3. 类型一致性**：`ScoreRules.kscore(kills, assists, dealt, deaths, team_damage, self_damage,
team_kills) -> int`（Task 1 定义）与 `_kscore_of` 的调用实参**逐位对应**（7 个）；
`_record_down(victim_role: int, killer_role: int) -> void` 与调用点 `server/team_host.gd:362`
的 `_record_down(int(role), _attributed_killer(p))` 一致；
`stats_payload()` 的七个键名与 Task 2 Step 1 的 `st_want_keys` **逐字一致且都是逐码点升序**
（`dealt` 在 `deaths` 之前 —— 那一处写明了理由，别按字母表直觉改回去）；
`_stat_entry` 的八个键名与 `_set_stats` 夹具写的八个键逐字一致。

**4. 明确的已知边界（登记不修）**：
- `taken` 不含队友伤害与自伤（spec §5.1）—— 它们只出现在肇事者行的惩罚里（计划 2）。
- 归因 8ms 的"同一帧内先被敌人打中再自己炸自己"错记（承自既有实现，`ATTRIB_FRESH_MS` 上方已登记）。
- 加权的**探针性质**（"两种敌方存活人数下增量相等"）只在有人**重新加回**加权时才红；
  它钉的是"公式不再看那个量"，不是"公式一定对"。
- 1v1 / 大乱斗此时**只在底座接得住，还没有任何写入**（`deaths`/`dealt`/`taken` 都靠各模式的
  倒地边沿与 `_on_player_hit`；`_on_player_hit` 是共用的、已生效，倒地边沿归计划 3）。
