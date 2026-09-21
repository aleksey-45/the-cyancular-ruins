# 对局结算画面 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MATCH_OVER 之后不再"挂 6 秒大字然后自动回主菜单",而是进入一个**玩家自己退**的结算页,显示该模式现有的逐人数据。

**Architecture:** 一个**模式无关**的控件 `ui/match_result.gd`(只吃一份统一载荷、画出来、发一个 `leave_requested` 信号)+ 一组**纯静态适配器** `ui/match_result_payload.gd`(把三个模式各不相同的 `round_state` 折成那一个载荷形状)+ 三个客户端各自把 MATCH_OVER 分支从"起定时器"改成"挂结算页、等信号"。**服务端零改动**。

**Tech Stack:** Godot 4.7.1 GDScript；`UiFactory`(UI 唯一工厂与调色板)；场景探针 + `-s` 冒烟；判据 grep 文本。

## Global Constraints

- ★★ **另一个会话正在主工作树(`E:\Workspace\godot\the-cyancular-ruins`)的 `main` 上并发开发**。本计划的一切都在 **worktree `E:\Workspace\godot\the-cyancular-ruins\.claude\worktrees\3v3-fixes`**(分支 `feat/3v3-fixes`)里做。**绝不 `cd` 到主仓库根、绝不对它做 git 操作。**
- ★ **Bash 工具在本 worktree 里会被 git 守卫误伤** ⇒ **用 PowerShell 工具**跑 Godot。console 版路径：`D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe`。
- **本项目默认：测试由用户自己跑。** agent 可跑：`--import`、不占 7777 的探针。★ 需要**真渲染**的探针(带取图的)headless 下跑不出像素 —— 那类写完留给用户，但**实施者要先自己读一遍取图**(本仓纪律)。
- **颜色只在 `ui/ui_factory.gd` 定义**；字号只用 **16 的倍数**；`NetBus` 的方法表**一个字不动**。
- 判据一律**文本**(`ALL-OK` / 探针自己的串)，**不看退出码**；场景探针 `--quit-after` 统一给足 **3600**。
- 提交信息用**单引号**或 `git commit -F 文件`，**不带任何 Claude/AI 署名行**；每次 `git add` 只加本任务点名的文件。
- ★ **`kh_l6_probe.gd` 第 9/9b 条**守着 MATCH_OVER 退场块(菜单失效 + `is_inside_tree()` 早退)。动了那两块必须**同步改它**，**不许放宽**。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `ui/match_result.gd` + `.tscn` | **新建** | 结算控件：把载荷画出来 + 一个 `leave_requested` 信号。**不知道任何模式规则** |
| `ui/match_result_payload.gd` | **新建** | 三个**纯静态**适配器：模式 `round_state` → 统一载荷 |
| `ui/ui_factory.gd` | 修改 | `fit_name()` 收口(从 `RoyaleHud` 提上来) |
| `ui/royale_hud.gd` | 修改 | `_fit_name` 改为委托 `UiFactory.fit_name`(行为不变) |
| `scenes/pvp_match_client.gd` | 修改 | **公共挂载/离场**:`_show_result()` / `_leave_to_main_menu()` + `_build_result_payload()` 默认钩子(三个客户端本就都 extends 它) |
| `scenes/pvp_game.gd` | 修改 | MATCH_OVER 分支 + `_build_result_payload()` **覆写** |
| `scenes/royale_game.gd` | 修改 | 同上 |
| `scenes/team_game.gd` | 修改 | 同上(两节 + `mvp`) |
| `tests/match_result_payload_smoke.gd` | **新建** | `-s`：三个适配器的纯逻辑冒烟 |
| `tests/match_result_probe.tscn` + `.gd` | **新建** | 场景探针：版式取图 + 信号防重入 |
| `tests/hud_declarative_probe.gd` | 修改 | `PAIRS` 加 `ui/match_result` 一行(每条**三个**元素：脚本/场景/类名) |
| `tests/kh_l6_probe.gd` | 修改 | 第 9/9b 条随改动同步(**不放宽**) |
| `CLAUDE.md` | 修改 | 记录结算页三条纪律 |

---

## 载荷契约(全计划共用，Task 2/3/4 都产出这个形状)

```
{
  "title":    String,          # "胜利!" / "失败" / "平 局"
  "subtitle": String,          # 可空
  "columns":  Array[String],   # ["kills","deaths","dmg","acs"] 的子集，**由数据决定**
  "sections": [ { "label": String, "color": Color, "rows": [ row, … ] } ],
  "mvp":      Dictionary,      # 可空；{ "section": i, "row": j }
}
row = { "rank": int, "name": String, "kills": int, "deaths": int,
        "dmg": int, "acs": int, "mvp": bool }
```

| 模式 | `columns` | `sections` | `mvp` |
|---|---|---|---|
| 1v1 | `["kills"]` | 1 节，2 行 | 空 |
| 大乱斗 | `["kills","deaths"]` | 1 节，N 行 | 空 |
| 3v3 | `["kills","deaths","dmg","acs"]` | **2 节**(A/B 队) | 指向 ACS 最高者 |

---

## Task 1: `UiFactory.fit_name` 收口

**Files:**
- Modify: `ui/ui_factory.gd`(在 `pixel_font()` / `label()` 那一区之后追加)
- Modify: `ui/royale_hud.gd:99-118`(`_fit_name` 改为委托)

**Interfaces:**
- Produces: `UiFactory.fit_name(s: String, max_units: int) -> String`(静态；按显示宽度截断 + 补满)

- [ ] **Step 1: 把 `RoyaleHud._fit_name` 逐字搬到 `UiFactory`**

在 `ui/ui_factory.gd` 的 `label()` 之后追加(★ **逐字**搬 `ui/royale_hud.gd` 现有那份的实现与注释，只把 `static func _fit_name` 改成 `static func fit_name`)：

```gdscript
# 昵称**定宽**成一列:按显示宽度(汉字/全角算 2 个半角单位)截断,超出补 …,
# 不足的用半角空格补满。截断保证后面的列不被顶出面板;补满让各列在行与行之间纵向对齐。
# 单位宽度按字体算:拉丁走 8x16 的 DOS 位图(半角 8px),汉字走 16px 网格的 Unifont ——
# 在 32px 字号下半角 16px、全角 32px,故「1 单位 = 半角字符宽」成立。**换字体要重算 max_units。**
# ★ 2026-09-20 从 royale_hud 提上来(结算页也要用):两处各留一份的话,
#   改截断口径时必然只改一处,而漏改**不报错**,只是列错位。
static func fit_name(s: String, max_units: int) -> String:
	var units := 0
	var out := ""
	for i in s.length():
		var w := 2 if s.unicode_at(i) > 0x2E80 else 1
		if units + w > max_units:
			out += "…"
			units += 1
			break
		units += w
		out += s[i]
	while units < max_units:
		out += " "
		units += 1
	return out
```

- [ ] **Step 2: `RoyaleHud` 改为委托(行为逐字不变)**

把 `ui/royale_hud.gd` 里那个 `static func _fit_name(...)` 的**函数体**换成一行委托，**保留函数名与签名**(调用点不动)：

```gdscript
static func _fit_name(s: String, max_units: int) -> String:
	return UiFactory.fit_name(s, max_units)
```

- [ ] **Step 3: 核对行为未变**

Run（**让用户跑**，或实施者用 PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn`
Expected: 现有四张图的断言全绿(该探针断言大乱斗榜的可见性与行数 —— 昵称列宽若变了它会红)。

- [ ] **Step 4: 提交**

```bash
git add ui/ui_factory.gd ui/royale_hud.gd
git commit -m 'refactor(ui): 昵称定宽 fit_name 收进 UiFactory(结算页要用,避免两份截断口径)'
```

---

## Task 2: `MatchResultPayload` 三个适配器 + `-s` 冒烟

**Files:**
- Create: `ui/match_result_payload.gd`
- Test: `tests/match_result_payload_smoke.gd`(`-s`)

**Interfaces:**
- Consumes: `UiFactory.C_TEAM_A` / `C_TEAM_B` / `C_TEXT`
- Produces:
  - `MatchResultPayload.for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary`
  - `MatchResultPayload.for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary`
  - `MatchResultPayload.for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary`

★ 放 `ui/` 层而不是 `core/sim/`：本仓 `core/` **零引用 `UiFactory`**(已核)，而适配器要用队色 token。

- [ ] **Step 1: 写失败的 `-s` 冒烟**

```gdscript
extends SceneTree

# 结算页**适配器**的纯逻辑冒烟(三个模式 -> 统一载荷)。
# 跑法: "$GODOT" --headless --path . -s res://tests/match_result_payload_smoke.gd
# 通过 = `MATCH RESULT PAYLOAD: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 三个适配器是**纯函数**,但它们的错法全是静默的:列多一列会画出一个恒 0 的列
#   (读起来像"这人打了但什么都没干");排序非确定会让同一局两次跑给出不同的榜;
#   平局走 1v1 兜底会把「平 局」念成「P1 获胜」。这些都不会报错。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() -> 进程永久挂起。

func _initialize() -> void:
	var script = load("res://ui/match_result_payload.gd")
	if script == null:
		print("MATCH RESULT PAYLOAD: FAIL(加载 match_result_payload.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	var names := {1: "阿甲", 2: "bob", 3: "阿丙", 4: "dave", 5: "阿戊", 6: "frank"}
	var teams := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

	# ① 1v1:只有 kills 一列(服务端没有逐人阵亡) -> 不许出现 deaths 列
	var duel: Dictionary = script.for_duel({ "scores": {1: 7, 2: 3}, "rounds_won": {1: 2, 2: 1},
			"match_winner": 1 }, names, 1)
	if duel["columns"] != ["kills"]:
		fails.append("★ 1v1 的 columns 应恰为 [kills](服务端没有逐人阵亡),实得 %s" % [duel["columns"]])
	if str(duel["title"]) != "胜利!":
		fails.append("1v1 我赢了应念「胜利!」,实得 %s" % duel["title"])
	if int(duel["sections"][0]["rows"][0]["kills"]) != 7:
		fails.append("1v1 榜首应是 7 杀")

	# ② 1v1 平局:match_winner == 0 必须念「平 局」,不许走 1v1 兜底念成 P 某人获胜
	var draw: Dictionary = script.for_duel({ "scores": {1: 2, 2: 2}, "match_winner": 0 }, names, 1)
	if str(draw["title"]) != "平 局":
		fails.append("★ 1v1 平局应念「平 局」,实得 %s" % draw["title"])

	# ③ 大乱斗:kills + deaths 两列,按 kills 降序
	var roy: Dictionary = script.for_royale({ "scores": {1: 3, 2: 9, 3: 0},
			"deaths": {1: 5, 2: 2, 3: 4}, "match_winner": 2 }, names, 1)
	if roy["columns"] != ["kills", "deaths"]:
		fails.append("大乱斗 columns 应为 [kills,deaths],实得 %s" % [roy["columns"]])
	if int(roy["sections"][0]["rows"][0]["kills"]) != 9:
		fails.append("★ 大乱斗榜首应是 9 杀(降序排错)")
	if str(roy["title"]) != "失败":
		fails.append("大乱斗我没赢应念「失败」,实得 %s" % roy["title"])

	# ④ 3v3:两节、列含 dmg/acs、mvp 指向 ACS 最高者
	var stats := {1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			2: {"kills": 2, "deaths": 5, "dmg": 150, "kscore": 200, "acs": 66},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}}
	var team: Dictionary = script.for_team({ "stats": stats, "mvp": 4, "match_winner": 2 }, names, teams, 1)
	if team["columns"] != ["kills", "deaths", "dmg", "acs"]:
		fails.append("3v3 columns 应为 [kills,deaths,dmg,acs],实得 %s" % [team["columns"]])
	if (team["sections"] as Array).size() != 2:
		fails.append("★ 3v3 必须两节(按队分栏),实得 %d" % (team["sections"] as Array).size())
	if int(team["mvp"].get("section", -1)) != 1 or int(team["mvp"].get("row", -1)) != 0:
		fails.append("★ mvp 应指向第 2 节第 1 行(role 4 属 2 队且 ACS 最高),实得 %s" % [team["mvp"]])
	if str(team["title"]) != "失败":
		fails.append("3v3 我(1 队)输了应念「失败」,实得 %s" % team["title"])

	# ⑤ ★ 某 role 没有 stats 条目 -> 跳过该行,不硬造 0
	var partial: Dictionary = script.for_team({ "stats": {1: stats[1]}, "mvp": 1,
			"match_winner": 1 }, names, teams, 1)
	if int((partial["sections"][1]["rows"] as Array).size()) != 0:
		fails.append("★ 没有 stats 条目的 role 不许硬造 0 行(2 队应 0 行)")

	# ⑥ ★ 排序确定性:同一份输入连算两次,载荷必须逐字段相同
	if str(script.for_team({ "stats": stats, "mvp": 4, "match_winner": 2 }, names, teams, 1)) \
			!= str(team):
		fails.append("★ 同一输入两次调用给出了不同的榜(排序不确定)")

	if fails.is_empty():
		print("MATCH RESULT PAYLOAD: ALL-OK")
		quit(0)
	else:
		print("MATCH RESULT PAYLOAD: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
```

- [ ] **Step 2: 跑确认它红**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/match_result_payload_smoke.gd`
Expected: `FAIL(加载 match_result_payload.gd 失败)`。

- [ ] **Step 3: 写实现**

```gdscript
class_name MatchResultPayload
extends RefCounted

# 结算页的**适配器**:把三个模式各自的 round_state 形状,折成 MatchResult 认的那一个载荷。
#
# ★★ 为什么单独一个文件、而不是写在三个客户端里:
#   ① 它们是**纯函数**(入参全是字典/常量,不碰节点、不读 autoload)⇒ `-s` 冒烟直接钉;
#      写在 pvp_game / royale_game / team_game 里就得把整个游戏场景实例化才测得到;
#   ② 三个模式**共用**「列标题 / 没有的列不列 / 平局文案」这些口径 —— 抄三份必然漂。
# ★ 反过来,`ui/match_result.gd` **不知道任何模式规则**;模式差异全部收在本文件。
#
# ★★ 三条不改会静默出错的口径:
#   ① `columns` **由数据决定** —— 某模式没有的数不进 columns,而不是补一列恒 0
#      (恒 0 的列读起来像"这人打了但什么都没干",而事实是他根本没这项统计);
#   ② 排序必须**确定性** —— 同样的局两次跑要给出同一个榜(主键降序 → 阵亡升序 → 昵称升序);
#   ③ `match_winner == 0` 是**平局**。1v1 那条别照抄 `ui/pvp_hud.gd` 的兜底
#      (`"P%d 获胜!" % (1 if w1 > w2 else 2)`)—— 那会把平局念成「P1 获胜」。

const C_KILLS := ["kills"]


# 1v1。`scores` 是 role -> **击杀数**(局胜在 `rounds_won`);**没有逐人阵亡** ⇒ 只列 kills。
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var scores: Dictionary = round.get("scores", {})
	var rows: Array = []
	for role in [1, 2]:
		if not scores.has(role):
			continue
		rows.append(_row(_name_of(names, role), int(scores[role]), 0, 0, 0))
	_finish(rows, "kills")
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_KILLS,
		"sections": [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 大乱斗。自由混战:`scores` / `deaths` 都是 role -> 计数。**没有 dmg/acs** ⇒ 不列。
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var scores: Dictionary = round.get("scores", {})
	var deaths: Dictionary = round.get("deaths", {})
	var rows: Array = []
	for role in scores:
		rows.append(_row(_name_of(names, int(role)), int(scores[role]), int(deaths.get(role, 0)), 0, 0))
	_finish(rows, "kills")
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "",
		"columns": ["kills", "deaths"],
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 3v3。两节(A/B 队),栏内按 ACS 排;`mvp` 指向 ACS 最高者。
# ★ `stats` 按 role、`names` 也按 role ⇒ 直接可拼。
# ★ 某 role 没有 stats 条目(掉线 / 中途加入)⇒ **跳过该行,不硬造 0**。
static func for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var sections: Array = []
	for t in [1, 2]:
		var rows: Array = []
		for role in stats:
			if int(teams.get(int(role), 0)) != t:
				continue
			var s: Dictionary = stats[role]
			rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
					int(s.get("deaths", 0)), int(s.get("dmg", 0)), int(s.get("acs", 0)),
					int(role) == mvp_role))
		_finish(rows, "acs")
		sections.append({
			"label": "A 队" if t == 1 else "B 队",
			"color": UiFactory.C_TEAM_A if t == 1 else UiFactory.C_TEAM_B,
			"rows": rows,
		})
	# mvp 的行号必须在**排完序之后**数,否则高亮会落在错的那一行
	var pos := {}
	for si in sections.size():
		var rows: Array = sections[si]["rows"]
		for ri in rows.size():
			if bool(rows[ri]["mvp"]):
				pos = {"section": si, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict_team(int(round.get("match_winner", 0)), my_team),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": ["kills", "deaths", "dmg", "acs"],
		"sections": sections,
		"mvp": pos,
	}


static func _row(nm: String, kills: int, deaths: int, dmg: int, acs: int, mvp: bool = false) -> Dictionary:
	return {"rank": 0, "name": nm, "kills": kills, "deaths": deaths,
			"dmg": dmg, "acs": acs, "mvp": mvp}


# 确定性排序 + 填名次:主键降序 → 阵亡升序 → 昵称升序。
static func _finish(rows: Array, key: String) -> void:
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a[key]) != int(b[key]):
			return int(a[key]) > int(b[key])
		if int(a["deaths"]) != int(b["deaths"]):
			return int(a["deaths"]) < int(b["deaths"])
		return str(a["name"]) < str(b["name"]))
	for i in rows.size():
		rows[i]["rank"] = i + 1


static func _name_of(names: Dictionary, role: int) -> String:
	return str(names.get(role, "玩家%d" % role))


# 1v1 与大乱斗的 `match_winner` 是 **role 号**。0 = 平局(两人局胜相同)。
static func _verdict(match_winner: int, my_role: int) -> String:
	if match_winner == 0:
		return "平 局"
	return "胜利!" if match_winner == my_role else "失败"


# 3v3 的 `match_winner` 是 **队号**。0 = 平局(两队都走光 —— 见 TeamHost 的走光即弃权)。
static func _verdict_team(match_winner: int, my_team: int) -> String:
	if match_winner == 0:
		return "平 局"
	if my_team == 0:
		return "失败"     # 队伍表还没到(倒计时窗口) —— 不谎报胜利
	return "胜利!" if match_winner == my_team else "失败"
```

- [ ] **Step 4: 跑冒烟确认全绿**

Run（PowerShell）：`& $GODOT --headless --path . -s res://tests/match_result_payload_smoke.gd`
Expected: `MATCH RESULT PAYLOAD: ALL-OK`。

- [ ] **Step 5: 变异反证(至少两条)**

把以下两处各改一次，跑冒烟确认**变红**，然后**逐字还原**再跑确认绿。两段输出都写进报告：
1. 把 `for_duel` 的 `"columns": C_KILLS` 改成 `["kills", "deaths"]` ⇒ ① 那条应红。
2. 把 `_finish` 的 `sort_custom` 整段注释掉 ⇒ ③ 或 ⑥ 应红。

- [ ] **Step 6: 提交**

```bash
git add ui/match_result_payload.gd ui/match_result_payload.gd.uid \
  tests/match_result_payload_smoke.gd tests/match_result_payload_smoke.gd.uid
git commit -m 'feat(ui): 结算载荷适配器(三模式 -> 统一形状)+ 纯逻辑冒烟'
```

★ **两个 `.uid` 必须一起 add**(`--import` 会生成它们)。本仓跟踪 `.uid`(共 201 个),Task 3 的 Step 6 也明确列了 —— 原先这一行漏写,实施者按字面执行后如实登记,已补。

---

## Task 3: `MatchResult` 控件 + 场景探针

**Files:**
- Create: `ui/match_result.gd`, `ui/match_result.tscn`
- Create: `tests/match_result_probe.gd`, `tests/match_result_probe.tscn`
- Modify: `tests/hud_declarative_probe.gd`

**Interfaces:**
- Consumes: `UiFactory.label/button/panel_box/apply_font_recursive/fit_name`；Task 2 的载荷形状
- Produces: `MatchResult`(`class_name`，`extends CanvasLayer`)，`show_result(payload: Dictionary) -> void`，信号 `leave_requested`

- [ ] **Step 1: 建 `ui/match_result.tscn`(最小骨架 —— 面板全部由 `_ready()` 用 `UiFactory` 建)**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/match_result.gd" id="1"]

[node name="MatchResult" type="CanvasLayer"]
layer = 150
script = ExtResource("1")
```

★ 层位 **150**：三个 HUD 是 130、小地图 131、暂停菜单 145 ⇒ 盖住一切。
★ 面板不在 `.tscn` 里手写锚点，而是 `_ready()` 里用 `UiFactory` 建、`set_anchors_preset` 居中 —— 手写锚点是"改错了不报错"的一类。

- [ ] **Step 2: 写 `ui/match_result.gd`**

```gdscript
class_name MatchResult
extends CanvasLayer

# 对局结算页(**模式无关**)。层位 150。
#
# ★★ 两条纪律,改之前先想清楚:
#   ① 本控件**不知道任何模式的规则** —— 不读 NetBus / Settings / 不 import 任何 *Host。
#      模式差异全部由 `ui/match_result_payload.gd` 的三个适配器折成载荷。谁能被 grep 到
#      跨过这条线,谁就是缺陷。
#   ② `leave_requested` **只发一次**(见 `_leaving`):下游 `safe_change_scene` 是一次换场,
#      连发两次会叠加第二次换场(把刚建出来的主菜单当 old 退役)。
#
# ★ ESC 的**双重语义**在本页是安全的,但依赖一处外部事实:对局中 ESC = 暂停菜单,
#   而 MATCH_OVER 时三个客户端都把暂停菜单 `queue_free` 掉了 ⇒ 不会同时触发两件事。
#   ⚠ 谁将来删掉那两行"销毁暂停菜单",ESC 就会在本页同时开菜单 —— 届时必须回来处理。

signal leave_requested

const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "dmg": "伤害", "acs": "ACS"}
const NAME_UNITS := 12                 # 昵称定宽(半角单位);换字体要重算
const SIZE_TITLE := 48
const SIZE_BODY := 32
const MASK_COLOR := Color(0, 0, 0, 0.55)   # 全屏压暗罩 —— 与暂停菜单同值。★ 它不是 HUD 底板,不属 `0.1` 那一条
const MVP_MARK := "★ "                 # ★ 取图确认它能渲染(Unifont 覆盖 U+2605);出豆腐块就改 "MVP "

var _leaving := false
var _sections_box: HBoxContainer = null
var _title_label: Label = null
var _sub_label: Label = null


func _ready() -> void:
	UiFactory.apply_font_recursive(self)
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = MASK_COLOR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(1120, 0)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 24)
	panel.add_child(vb)

	_title_label = UiFactory.label("", SIZE_TITLE, UiFactory.C_TEXT)
	_title_label.name = "TitleLabel"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title_label)

	_sub_label = UiFactory.label("", SIZE_BODY, UiFactory.C_TEXT_DIM)
	_sub_label.name = "SubLabel"
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_sub_label)

	_sections_box = HBoxContainer.new()
	_sections_box.name = "Sections"
	_sections_box.add_theme_constant_override("separation", 48)
	_sections_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(_sections_box)

	var back := UiFactory.button("返 回 主 菜 单", SIZE_BODY, Vector2(420, 64))
	back.name = "BackButton"
	back.pressed.connect(_request_leave)
	vb.add_child(back)


# 唯一入口。★ 缺键一律取默认:**绝不因为缺一个键就崩** —— 结算页崩了玩家就卡在对局里出不去。
func show_result(payload: Dictionary) -> void:
	_title_label.text = str(payload.get("title", ""))
	_sub_label.text = str(payload.get("subtitle", ""))
	_sub_label.visible = not _sub_label.text.is_empty()
	for c in _sections_box.get_children():
		c.queue_free()
	var columns: Array = payload.get("columns", [])
	var mvp: Dictionary = payload.get("mvp", {})
	var sections: Array = payload.get("sections", [])
	for i in sections.size():
		_sections_box.add_child(_build_section(sections[i], i, columns, mvp))
	visible = true
	set_process_unhandled_input(true)


func _request_leave() -> void:
	if _leaving:
		return
	_leaving = true
	leave_requested.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_leave()


func _build_section(sec: Dictionary, idx: int, columns: Array, mvp: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Section%d" % idx
	box.add_theme_constant_override("separation", 12)
	box.add_child(UiFactory.label(str(sec.get("label", "")), SIZE_BODY,
			sec.get("color", UiFactory.C_TEXT)))

	var grid := GridContainer.new()
	grid.name = "Rows"
	grid.columns = 2 + columns.size()          # 名次 + 昵称 + 数据列
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	grid.add_child(UiFactory.label("#", SIZE_BODY, UiFactory.C_TEXT_DIM))
	grid.add_child(UiFactory.label("昵称", SIZE_BODY, UiFactory.C_TEXT_DIM))
	for col in columns:
		grid.add_child(UiFactory.label(str(COLUMN_TITLES.get(col, col)), SIZE_BODY,
				UiFactory.C_TEXT_DIM))

	var rows: Array = sec.get("rows", [])
	for ri in rows.size():
		var r: Dictionary = rows[ri]
		var is_mvp: bool = int(mvp.get("section", -1)) == idx and int(mvp.get("row", -1)) == ri
		# ★ MVP 行用**亮文本**、其余行用暗文本 + MVP 前缀标记 —— 不复用 C_WARN
		#   (它只表「弹夹见底」)也不复用 C_ACCENT(它与队 B 的 `#80F4FF` 太近)。
		var col: Color = UiFactory.C_TEXT if is_mvp else UiFactory.C_TEXT_DIM
		var mark := MVP_MARK if is_mvp else ""
		grid.add_child(UiFactory.label("%s%d" % [mark, int(r.get("rank", ri + 1))], SIZE_BODY, col))
		grid.add_child(UiFactory.label(UiFactory.fit_name(str(r.get("name", "")), NAME_UNITS),
				SIZE_BODY, col))
		for c in columns:
			grid.add_child(UiFactory.label(str(int(r.get(c, 0))), SIZE_BODY, col))
	box.add_child(grid)
	return box
```

★ `_ready()` 里**不显示**自己(`visible` 默认 true,但内容为空)⇒ 调用方 `add_child` 之后立刻 `show_result()`。若你发现空窗可见，在 `_ready()` 末尾加 `visible = false` 并在 `show_result()` 里置 true —— **但探针要断言"空载荷不崩"仍然成立**。
★★ **`show_result()` 的清理必须 `remove_child` 再 `queue_free`**(与 `WeaponPickup.configure` 同款纪律):只 `queue_free` 的话旧节在本帧余下时间仍是子节点 → ① Godot 把新加的 `Section0` **自动改名**成 `Section0@2`(名字还被占着),② 随后那次 `get_combined_minimum_size()` **把两份一起算**,面板被设成约两倍宽且**此后再不重算**。触发点是真实存在的:3v3 的 `round_state` 可能在 MATCH_OVER 之后再广播一条带新 `mvp` 的终局载荷(见 CLAUDE.md §逐人数据/ACS/MVP 边界 ②)。
★ **探针也用 `.tscn` 实例化**(不是 `MatchResult.new()`)—— 与生产同一条构造路径,否则 `layer` 这类「只写在场景里」的值探针**照不到**;并补一条 `layer == 150` 断言。

- [ ] **Step 3: 写场景探针(取图 + 信号防重入)**

`tests/match_result_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/match_result_probe.gd" id="1"]

[node name="MatchResultProbe" type="Node"]
script = ExtResource("1")
```

`tests/match_result_probe.gd`（`extends Node`，场景模式）：

```gdscript
extends Node

# 结算页的**版式与信号**守卫(必须真渲染;**headless 下取不到像素**,那是留给用户的跑法)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/match_result_probe.tscn
# 判据: 文本 `MATCH RESULT PROBE: ALL-OK`。
#
# ═══ 为什么需要它 ═══
# ★ 版式是"改了不报错"的一类:两节画成一栏、列数不随 columns 变、MVP 高亮落错行,
#   全都不会报错,只会画出一张读不出来的图。所以要**取图 + 节点级断言**两条一起。
# ★ 信号那一条是本页唯一的行为:连点两次按钮若发两次 leave_requested,
#   下游 safe_change_scene 会被调两次 —— 第一次切到主菜单、第二次把刚建出来的主菜单当 old 退役。
# ★ 空载荷不崩是硬要求:结算页崩了玩家卡在对局里出不去。

const OUT := "user://match_result_%d.png"

var _fails: Array[String] = []
var _count := 0


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	await _run()
	if _fails.is_empty():
		print("MATCH RESULT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MATCH RESULT PROBE: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)


func _run() -> void:
	# ① 空载荷:不崩，且只画标题
	await _shot({"title": "空"}, func(m): _check(
			m.get_node_or_null("Root/Panel/VBox/Sections").get_child_count() == 0,
			"空载荷应 0 节"))

	# ② 1v1 单节两行：列数 == 2 + columns.size()
	await _shot(MatchResultPayload.for_duel({"scores": {1: 7, 2: 3}, "rounds_won": {1: 2, 2: 1},
			"match_winner": 1}, {1: "阿甲", 2: "bob"}, 1), func(m):
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section0/Rows")
		_check(g.columns == 3, "1v1 表头列数应为 2+1=3,实得 %d" % g.columns)
		_check(g.get_child_count() == 3 + 2 * 3, "1v1 应有 3 表头 + 2 行×3 格"))

	# ③ 3v3 两节 + MVP 标记恰好一次
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}},
			"mvp": 4, "match_winner": 2}, {1: "阿甲", 4: "dave"}, {1: 1, 4: 2}, 1), func(m):
		var box: HBoxContainer = m.get_node("Root/Panel/VBox/Sections")
		_check(box.get_child_count() == 2, "3v3 应画 2 节,实得 %d" % box.get_child_count())
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section1/Rows")
		_check(g.columns == 6, "3v3 表头列数应为 2+4=6,实得 %d" % g.columns)
		_check(_count_marks(m) == 1, "★ MVP 标记应恰好出现 1 次,实得 %d" % _count_marks(m))

	# ④ 连点两次按钮 -> 只发一次信号
	var mm := MatchResult.new()
	add_child(mm)
	mm.show_result({"title": "信号"})
	var fired := [0]
	mm.leave_requested.connect(func() -> void: fired[0] += 1)
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	_check(fired[0] == 1, "★ 连点两次应只发一次 leave_requested,实得 %d" % fired[0])
	mm.queue_free()


func _count_marks(n: Node) -> int:
	var c := 0
	if n is Label and (n as Label).text.begins_with(MatchResult.MVP_MARK):
		c += 1
	for ch in n.get_children():
		c += _count_marks(ch)
	return c


func _shot(payload: Dictionary, verify: Callable) -> void:
	var m := MatchResult.new()
	add_child(m)
	m.show_result(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	verify.call(m)
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
```

★ **取图落 `user://`**（`user://match_result_0..2.png`）—— 本仓 `combat_hud_visual_probe` 的先例。跑完**实施者要先自己读这三张图**再回报。

- [ ] **Step 4: `hud_declarative_probe` 加一行**

在 `tests/hud_declarative_probe.gd` 的 `PAIRS` 里追加(★ 每条是**三个**元素)：

```gdscript
	["res://ui/match_result.gd", "res://ui/match_result.tscn", "MatchResult"],
```

- [ ] **Step 5: `--import` + 跑探针 + 自己读图**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（**让用户跑**，要窗口）：`& $GODOT --path . --quit-after 3600 res://tests/match_result_probe.tscn`
Expected: `MATCH RESULT PROBE: ALL-OK`，且 `user://match_result_0..2.png` 三张图能看出版式。
★ 若你在无窗口环境：跳过本步，在报告里写明"探针与取图留给用户"，**但**至少跑 `--import` 与 `hud_declarative_probe`(那条是 headless 可跑的)。

- [ ] **Step 6: 提交**

```bash
git add ui/match_result.gd ui/match_result.tscn ui/match_result.gd.uid \
  tests/match_result_probe.gd tests/match_result_probe.tscn tests/match_result_probe.gd.uid \
  tests/hud_declarative_probe.gd
git commit -m 'feat(ui): 结算页控件(模式无关载荷 + leave_requested 防重入)+ 版式/信号探针'
```

---

## Task 4: 公共挂载/离场进基类 + 1v1 接入

**Files:**
- Modify: `scenes/pvp_match_client.gd`(**公共** `_show_result` / `_leave_to_main_menu` / `_build_result_payload` 默认钩子)
- Modify: `scenes/pvp_game.gd`(MATCH_OVER 分支 + `_build_result_payload()` 覆写)

**Interfaces:**
- Consumes: `MatchResultPayload.for_duel`、`MatchResult`
- Produces:
  - `PvpMatchClient._show_result() -> void`、`PvpMatchClient._leave_to_main_menu() -> void`(Task 5/6 **直接复用,不得再写一份**)
  - `PvpMatchClient._build_result_payload() -> Dictionary`(默认返回 `{}`;子类覆写)
  - 基类成员 `_result: MatchResult`、`_last_round_state: Dictionary`

★ **为什么不三份逐字复制**:`scenes/pvp_game.gd` / `royale_game.gd` / `team_game.gd` **本来就都** `extends PvpMatchClient`(`:1` 行),不存在"要动的继承链"。两个挂载/离场函数放基类,三个子类只各留一个 `_build_result_payload()` 覆写 —— 这正是本仓 `_apply_peer_hues_or_team` / `_minimap_colors` 的既有形状。另:kh_l6 第 12 条的 `_func_body` **本来就会回落到基类**找函数体,放基类让那条的改法更干净。

- [ ] **Step 1: ★ 先核 `scores` 的语义(spec §5.3)**

在 `server/match_round.gd` 里读 `_scores` 的**写入端**，确认它在 1v1 里数的是**击杀**还是别的。
★ 若不是击杀，本任务里 `MatchResultPayload.for_duel` 的列名(现在写"击杀")要跟着改，**不许含糊**。
把结论写进报告。

- [ ] **Step 2: 往**基类** `scenes/pvp_match_client.gd` 加三个函数 + 两个成员**

★ 这一步**只做一次**(本任务是第一个接入的模式)。Task 5 / Task 6 **绝不许再写一份** —— 那是本计划唯一被明令消除的重复。

成员区(挨着既有的 `_match_ended` / `_menu_open` 一带)加:

```gdscript
var _result: MatchResult = null             # 结算页(挂载一次,由 _show_result 建)
var _last_round_state: Dictionary = {}      # 最近一条 round_state(结算载荷的输入之一)
```

函数加在文件里合适的位置:

```gdscript
# ★★ 必须走**场景实例化**,不能用 `MatchResult.new()`:`layer = 150` **只写在
#   `ui/match_result.tscn` 里**(脚本不设 layer —— 三个现有 HUD 同款写法,层位值只有那
#   一处来源)。用 `.new()` 会拿到 CanvasLayer 默认的 **layer 1**,结算页画在 HUD(130)/
#   小地图(131) **下面**、压暗罩盖不住它们,而计划自己的类头注释却写着「盖住一切」。
const RESULT_SCENE := preload("res://ui/match_result.tscn")

# 结算页:玩家自己退(不再是 N 秒后自动回主菜单)。三个模式共用 —— 它们都 extends 本类,
# 各自只覆写 `_build_result_payload()`。
# ★★ **挂载一次、但每次都要刷新**(`if _result == null` 只包住"建 + 连线")。
#   写成 `if _result != null: return` 会把"挂载幂等"顺手变成"**更新也只一次**":
#   第二条 MATCH_OVER 载荷就永远到不了屏幕上,而 `MatchResult.show_result` 的清场重建
#   (`ui/match_result.gd` 的 remove_child→queue_free 那段,Task 3 花了整轮评审修它)
#   在生产里**一次都不会跑** —— 探针却直接调它、照绿。**探针比产品更绿**是这里最难发现的形状。
#   ★ 第二条载荷**可达**(不是假想):1v1 —— `server_main.gd` 在每次 reclaim 成功后重播当前
#     `round_state`,掉线重连的客户端就会收到第二条 MATCH_OVER;3v3 —— `team_host.gd` 的
#     `_finish_match()` 在战斗进行中直接把 PLAYING→MATCH_OVER,而倒地边沿检测在
#     `match _round_state:` **之前**且**不看状态** ⇒ MATCH_OVER 之后再死人会再广播一条
#     带新 `stats`/`mvp` 的终局载荷;`mark_disconnected` 那条同款。
func _show_result() -> void:
	if _result == null:
		_result = RESULT_SCENE.instantiate()
		add_child(_result)
		_result.leave_requested.connect(_leave_to_main_menu)
	_result.show_result(_build_result_payload())


# 结算页 -> 主菜单。★ 离开仍走 Level0.safe_change_scene —— 游戏世界含全量碰撞,
# 裸 change_scene_to_file 会同步 memdelete → 偶发原生段错误。
# ★ 防重入由 MatchResult 自己那次发信号 + safe_change_scene 的 _switching 双层兜住;
#  这里只负责"在树上才切"(原定时器 lambda 里那条 is_inside_tree() 早退的**意图**搬到这里)。
func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


# 结算页载荷(默认空)。三个子类各覆写一份 —— 模式差异只有这一点。
func _build_result_payload() -> Dictionary:
	return {}
```

★ 原 MATCH_OVER 分支里"起定时器**之前**捕获 `tree`/`netbus`"那两行**随定时器一起删**(它们存在只是因为 lambda 到点才求值;`_leave_to_main_menu` 是同帧直接调用,`get_tree()` 现取即可)。

- [ ] **Step 3: `scenes/pvp_game.gd` 加覆写 + 改 MATCH_OVER 分支**

★ 成员区**不要**再声明 `_result` / `_last_round_state`(基类已有)。在 `_on_round_state` **开头**加一行记录:

```gdscript
	_last_round_state = data
```

加覆写:

```gdscript
# 结算页载荷的唯一来源。★ 本函数只读状态、不碰节点树(适配器是纯函数)。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_duel(_last_round_state, _names, PvpSession.role)
```

把 MATCH_OVER 分支里**起 `create_timer(5.0)` 那一段**整段删掉(连同上面那两行 `var tree := get_tree()` / `var netbus := NetBus`),换成:

```gdscript
		# 结算页:玩家自己退(不再是 5 秒后自动回主菜单)。
		_show_result()
```

★ `_pause_menu.queue_free()` 与 `_refresh_input_lock()` 那几行**原样保留**(ESC 双重语义依赖前者,见 `ui/match_result.gd` 的类头注释)。

- [ ] **Step 4: `--import` + 跑 1v1 相关探针**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（**让用户跑**）：`timeout 300 bash tests/pvp_match_smoke.sh`(占 7777，用户跑)
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add scenes/pvp_match_client.gd scenes/pvp_game.gd
git commit -m 'feat(pvp): 结算页挂载/离场收进 PvpMatchClient 基类 + 1v1 接入'
```

---

## Task 5: 大乱斗接入

**Files:**
- Modify: `scenes/royale_game.gd`(MATCH_OVER 分支，`scenes/royale_game.gd:211-235`)

**Interfaces:**
- Consumes: `MatchResultPayload.for_royale`、`MatchResult`
- Produces: `RoyaleGame._build_result_payload() -> Dictionary`

- [ ] **Step 1: 加 `_build_result_payload()`**

```gdscript
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_royale(_last_round_state, _names, PvpSession.role)
```

★ `_last_round_state` 是**基类**成员(Task 4 加的)—— 不要在本文件再声明,只在 `_on_round_state` **开头**记一行 `_last_round_state = data`。

- [ ] **Step 2: 改 MATCH_OVER 分支**

删掉 `get_tree().create_timer(6.0).timeout.connect(...)` 那一段(连同其中捕获 `tree`/`netbus` 那两行)，换成:

```gdscript
		# 结算页:玩家自己退(不再是 6 秒后自动回主菜单)。
		_show_result()
```

★★ **`_show_result` / `_leave_to_main_menu` 一个字都不要再写** —— Task 4 已把两者放进 `scenes/pvp_match_client.gd`,而本文件 `extends PvpMatchClient`,直接可用。本任务在这个文件里**只加 `_build_result_payload()` 覆写 + 换掉 MATCH_OVER 那几行**。若你写了第二份,报告里如实写明(那是缺陷,不是取舍)。

★ `_pause_menu.queue_free()` 那几行**原样保留**(ESC 双重语义依赖它，见 `ui/match_result.gd` 的类头注释)。
★ `_match_ended` 的输入锁语义保留 —— `_refresh_input_lock()` 照旧调用。

- [ ] **Step 3: `--import` + 跑探针**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（**让用户跑**）：`timeout 1800 bash tests/royale_soak_probe.sh`（跑到 MATCH_OVER，顺带验离场）

- [ ] **Step 4: 提交**

```bash
git add scenes/royale_game.gd
git commit -m 'feat(royale): 接入结算页(玩家自己退，不再 6 秒自动回菜单)'
```

---

## Task 6: 3v3 接入

**Files:**
- Modify: `scenes/team_game.gd`(MATCH_OVER 分支)

**Interfaces:**
- Consumes: `MatchResultPayload.for_team`、`MatchResult`、`_teams`、`_names`
- Produces: `TeamGame._build_result_payload() -> Dictionary`

- [ ] **Step 1: 加 `_build_result_payload()`**

★ `_last_round_state` 是**基类**成员(Task 4)—— 本文件不声明,只在 `_on_round_state` 开头记一行 `_last_round_state = data`。

```gdscript
# ★ `my_team` 取自 `_team_of_role(PvpSession.role)` —— 队伍表从 match_sync 来;
#   队号 0(表还没到)时 `_verdict_team` 念「失败」而不是谎报胜利。
func _build_result_payload() -> Dictionary:
	return MatchResultPayload.for_team(_last_round_state, _names, _teams,
			_team_of_role(PvpSession.role))
```

- [ ] **Step 2: 改 MATCH_OVER 分支**

删掉 6 秒定时器那一段(连同其中捕获 `tree`/`netbus` 那两行)，换成:

```gdscript
		# 结算页:玩家自己退(不再是 6 秒后自动回主菜单)。
		_show_result()
```

★★ **`_show_result` / `_leave_to_main_menu` 一个字都不要再写** —— Task 4 已把两者放进 `scenes/pvp_match_client.gd`(本文件的基类)。本任务只加 `_build_result_payload()` 覆写 + 换掉 MATCH_OVER 那几行。

- [ ] **Step 3: `--import` + 跑探针**

Run（PowerShell）：`& $GODOT --headless --path . --import`
Run（**让用户跑**）：`timeout 1800 bash tests/team_match_probe.sh`（六人真链路跑到 MATCH_OVER）

- [ ] **Step 4: 提交**

```bash
git add scenes/team_game.gd
git commit -m 'feat(team): 3v3 接入结算页(两节按队 + MVP)'
```

---

## Task 7: `kh_l6_probe` 同步 + `CLAUDE.md`

**Files:**
- Modify: `tests/kh_l6_probe.gd`(**第 9 / 9b / 12 三条**)
- Modify: `CLAUDE.md`

★★ **是三条,不是两条**。计划原先只点名 9 / 9b;实测第 **12** 条 `_check_exit_paths()` 也压在同一段 MATCH_OVER 退场块上,Task 4 删掉定时器后它**必然变红**,而它不在原文件清单里 —— **一并改**。

- [ ] **Step 1: 先跑一次,把三条的红都看清楚**

Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/kh_l6_probe.tscn`
Expected: FAIL。三条各自的红点(动手前先逐条对上):

| 条 | 位置 | 红的原因 |
|---|---|---|
| 9 | `_check_match_over_menu_kill`,断言 `blk.contains(N_TIMER)` | 定时器被删了 |
| 9b | 同上、对象是 `scenes/royale_game.gd`;另断言 `blk.contains(N_INSIDE)` | 同上 |
| 12 | `_check_exit_paths()` 的 `for spec in [["_on_round_state", …], ["_on_opponent_left", …]]` | `_on_round_state` 的函数体里**再没有换场调用**了 |

- [ ] **Step 2: 逐条重定向(★ 只改入口,**不许放宽**)**

三条要保住的**原意**:
① MATCH_OVER 时暂停菜单当场失效;
② 换场前有 `is_inside_tree()` 早退;
③ 退场路径(换场调用)没被删。

改法:

1. **第 9 / 9b 条**:`blk.contains(N_TIMER)` 那条断言**整个删掉** —— 它是唯一真正作废的一条("退场定时器必须在"随"定时器没了"一起失效,留着就是要求新代码把定时器加回来)。其余两条(菜单 `queue_free()` 在场、小写菜单路径)**原样留在原对象上**:菜单失效仍在各子类的 MATCH_OVER 块里,不动。
2. **第 9b 条的 `N_INSIDE` 断言**:`is_inside_tree()` 已随函数搬进**基类**的 `_leave_to_main_menu`,故这一条的扫描对象从"royale 的 MATCH_OVER 块"改成"`_leave_to_main_menu` 的函数体"。
3. **第 12 条**:那个 `for spec in […]` 里 `_on_round_state` 那一项改成 `["_leave_to_main_menu", "② MATCH_OVER 退场"]`;`_on_opponent_left` 那一项**一个字不动**(它的 2.5s 定时器本计划刻意没动)。第 657 行的 `body.contains(N_BARE) or body.contains(N_SAFE)` 与 658 行"换场调用被删了?"的消息文本随扫描对象一起走。

★ **工具已就绪**:`_func_body`(约 764 行)在 `pvp_game.gd` 里找不到函数时**会自动回落到 `BASE`**(`pvp_match_client.gd`),所以指到 `_leave_to_main_menu` 能直接取到基类那份函数体。
★ ⚠ **一个可预见的假红**:第 12 条循环里的菜单路径 needle 由 `_menu_path_needles(_pc_lines)` 从 **`pvp_game.gd` 的行**里抽 —— 而 `safe_change_scene(…, "res://scenes/main_menu.tscn")` 现在只在**基类**文件里。若 needles 因此为空、或取不到,就把该处的行来源一并扩到 `_base_lines`(**扩来源是让守卫看到正确对象,不是放宽**)。别用"把断言删掉"收场。
★ 判据一律是**文本** `ALL-OK`,不看退出码。

- [ ] **Step 3: 复跑三条所在的探针**

Run（PowerShell）：`& $GODOT --headless --path . --quit-after 3600 res://tests/kh_l6_probe.tscn`
Expected: `ALL-OK`。

★ **反证一条**(证明新入口真的被验到,而不是断言被架空):把基类 `_leave_to_main_menu` 里 `is_inside_tree()` 那两行注释掉 → 探针必须**变红**;还原 → 复绿。两段输出写进报告。

- [ ] **Step 4: `CLAUDE.md` 记录四条**

在「网络与 PvP」一节里补一小段，写清:
1. **结算页是模式无关的**:`ui/match_result.gd` 不知道任何模式规则，载荷由 `ui/match_result_payload.gd` 的三个适配器产出;`columns` **由数据决定**(没数据的列不列，不硬造 0)。
2. **`leave_requested` 只发一次**(防重入)，下游仍走 `Level0.safe_change_scene`。
3. ★ **ESC 的双重语义依赖"MATCH_OVER 时销毁暂停菜单"**:对局中 ESC = 菜单，结算页上 ESC = 返回主菜单。删掉那两行会让两者同时触发。
4. `ui/match_result.tscn` 层位 **150**(三个 HUD 130、小地图 131、暂停菜单 145)。
5. ★ **结算页的挂载/离场在 `PvpMatchClient` 基类**(`_show_result` / `_leave_to_main_menu`),三个客户端**只各覆写 `_build_result_payload()`** —— 它们本就都 extends 它。加新模式的结算 = 写一个覆写,别在子类里再抄一份挂载。
6. ★ **订正 `CLAUDE.md` 里「grep ALL-OK」那句的一处事实错误**(2026-09-21 Task 3 实测定案)。
   原句:「判据必须是 **grep 文本 `ALL-OK`**(中途报错时 `--quit-after` 仍 exit 0 **且不打印 ALL-OK**,只看退出码会把"没跑完"读成"通过")」。
   ★ **「且不打印 ALL-OK」只对一种形状成立:出错在 `_ready()` 自己身上。** 实测(Godot 4.7.1 headless,三层各跑一遍,故障 = `get_node("nope").some_method()`):
   - 出错在 **lambda / helper** 里 → 它当场结束,**调用方继续** → **照打 `ALL-OK`**;
   - 出错在 **`_run()` 自己**里 → `_run` 结束,`_ready()` 的 `await _run()` 照常恢复 → **照打 `ALL-OK`**。
   ⇒ **假绿**:后面那些断言被**静默跳过**,而 verdict 读成"全过"。
   ★ 更尖的一层:`ProbeBase._summary` 在没有**新增**失败时打 **✓**,所以**整组一条都没跑就出错**时,那个 ✓ 汇总行**也会打** —— 汇总行与最终 verdict **一起读成通过**。
   ★ **保留不变的部分**:退出码从来不是判据(出错时照样 exit 0,与"跑通了"在退出码上不可分)—— 这条结论没变,改的只是它旁边那句"不打印 ALL-OK"。
   ★ 完整表述已写进 `tests/lib/probe_base.gd` 的文件头(那里是这条纪律的权威落点);CLAUDE.md 这句改成与它一致的简短版并指向它。
7. ★ **把 `CLAUDE.md:121` 那句「昵称走 `_fit_name(名字, 14)`」改成指 `UiFactory.fit_name(名字, 14)`** —— Task 1 之后权威实现已搬到 `UiFactory`,`RoyaleHud._fit_name` 只剩一行委托。该行的**口径描述**(显示宽度、截断 + 补满、换字体要重算 `BOARD_W`/`NAME_UNITS`)**原样保留**,只改函数名归属。(Task 1 自己发现并登记:Step 4 限定它只 `git add` 那两个 UI 文件,所以那处文档留到本任务。)
8. ★★ **补三个模式的**接线**断言**(Task 5 / Task 6 评审登记:**三条调用目前零常驻覆盖**)。
   本任务已经把第 9b / 12 条的扫描对象重指向基类 —— 顺手补齐:
   - **`scenes/royale_game.gd` 的 `state == 3` 块里必须含 `_show_result()`**;
   - **`scenes/team_game.gd` 的 `state == 3` 块里必须含 `_show_result()`**;
   - ★★ **`scenes/team_game.gd` 的 `_build_result_payload()` 里 `_names` 与 `_teams` 的实参顺序不得写反。**
     理由:基类那两条常驻守卫(扫 `MatchResult.new(`、扫 `_show_result` 不得早退)**只扫基类**;而三个模式各自的调用点是临时探针验的,已删。★ 计划给 Task 5 点名的验收跑法(`royale_soak_probe.sh`「顺带验离场」)**其实验不到它**:该探针的客户端在 MATCH_OVER 自己就退出了(`tests/royale_soak_probe.gd:421-423`),永远走不到大乱斗结算页那一段。
   ★★ **那两个 Dictionary 实参写反了**会**照样编译、照样全绿**:`for_team(round, names, teams, my_team)` 里 `_names` 与 `_teams` 都是 `Dictionary`,写反只会让榜渲染成乱码/空表,而**所有常驻测试都不会红**。这是本计划里最安静的一种错法。
   ★ **不需要新探针文件**:`tests/team_room_smoke.gd` 已经在读 `res://scenes/team_game.gd` 并按**函数体**断言(见该文件 ⑨ 一族),在那里加两行即可。
9. ★ **四处被这次改动证伪的注释要一起订正**(Task 5 评审登记;它们都不支撑任何断言,所以**不会红**,但正是"半年后让人白花一小时"的那类):
   - `server/royale_host.gd:238` —— `# 结果展示阶段:客户端 6s 后自行回菜单`
   - `tests/royale_soak_probe.gd:25-26` 与 `:420` —— 「那条 6s 换场会把本探针一起摘掉」
   - `tests/royale_c2_watcher.gd:429` —— 拿 6s 定时器解释 watcher 为什么死
10. **登记(不改)**:`scenes/royale_game.gd:219` 那句「退出只走结算页这一条路(与 `pvp_client` / `team_game` 同款)」对 `pvp_client` 已是事实、对 `team_game` 是**前瞻**(它 Task 6 之前仍走自己的定时器)。`scenes/royale_game.gd:240-243` 是一条**孤儿注释**:它描述 `_refresh_input_lock`,而那个函数**根本不在本文件里**(在基类),且基类注释已说明合并后 1v1 也带 `_match_ended` —— 该说法是**反的**。
11. ★★ **登记(绝对不要"顺手对齐")**:`scenes/royale_game.gd:215` 的 `and not _match_ended` 门**是承重的,不是不一致**。`RoyaleHost._match_winner()` 迭代的是 `players ∪ _scores`(`server/royale_host.gd:283-296`),所以**移除一个没有 `_scores` 条目(0 杀)的玩家**会少一个并列候选 ⇒ **全场都是 0 杀**时 `match_winner` 会从 `0` 翻成幸存的那个 role。今天这道门**挡住了**那次翻转;谁为了"和基类契约对齐"删掉它,大乱斗就会把该念「平 局」的场面念成「胜利!/失败」。**要删先修 `_match_winner`。**

- [ ] **Step 5: 提交**

```bash
git add tests/kh_l6_probe.gd CLAUDE.md
git commit -m 'test/docs: kh_l6 第 9/9b/12 认结算页的退场块 + CLAUDE.md 记录结算页纪律'
```

---

## 自检

**spec 覆盖**：§3.1 控件 → Task 3；§3.2 适配器 → Task 2；§3.3 挂载与离场 → Task 4(基类公共挂载 + 1v1)/ Task 5 / Task 6；§4 载荷契约 → Task 2 的产出 + Task 3 的消费；§5 数据缺口 → Task 2 的 `_finish`/`_verdict*` 与 Task 4 Step 1；§6 边界 → Task 3 的 `show_result` 默认值 + `_request_leave` 防重入 + 类头 ESC 注释；§7 测试 → Task 2/3 的探针 + Task 4/5/6 的真链路跑法；Task 1 是 §3.1 里"`0.1` 常量"那条之外的 DRY 收口(`fit_name`)。

**2026-09-20 执行前修订(控制者,经用户裁定)**：
- Task 4/5/6 原写"三个客户端各抄一份 `_show_result` / `_leave_to_main_menu`",理由是"抽公共基类要动 `PvpMatchClient` 的继承链" —— **该理由不成立**:三个客户端本来就都 `extends PvpMatchClient`(`:1` 行)。改为**放基类 + 子类只覆写 `_build_result_payload()`**。逐字重复逻辑块是评审规则会判缺陷的那类。
- Task 7 原只点名 `kh_l6_probe` 第 9 / 9b 条;**第 12 条 `_check_exit_paths()` 也压在同一段退场块上**(断言 `_on_round_state` 体内必须有换场调用),Task 4 删定时器后必然变红 → 一并纳入 Task 7。

**占位符扫描**：无 TBD/TODO；每个改代码的步骤都给了代码。

**类型一致性**：`MatchResultPayload.for_duel/for_royale/for_team` 的签名在 Task 2 定义、Task 4/5/6 按同一签名调用；`MatchResult.show_result(payload: Dictionary)` 与 `leave_requested` 在 Task 3 定义、Task 4/5/6 按同一名字用；`MVP_MARK` 在 Task 3 定义并被同任务的探针按 `MatchResult.MVP_MARK` 引用。

**已知未覆盖**：`pvp_game._on_opponent_left`（对手中途离开）**仍走它自己的 2.5 秒自动回菜单**，本计划**刻意不动** —— 那是"对局被放弃"不是"打完"，改成结算页属产品决定，另行评估。
