# 三模式 `stats` 投递 + 结算页五列（客户端 + 两个宿主）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 1v1 与大乱斗也把逐人统计随 `round_state` 发出去（**协议加法**：新增 `stats` 键，
1v1 另加 `mvp`；老接收端忽略未知键，**不需要两端同版本**），并把结算页从"K/D（3v3 另有伤害/ACS）"
扩成 **K/D/A + 造成 + 承受（+ ACS）**。

**Architecture:** 三块，缺一块用户就看不到数字：
① **两个宿主**（`server/match_round.gd` = 1v1、`server/royale_host.gd` = 大乱斗）各自在**倒地边沿**
调基础层已有的 `_record_down`（计划 1 上提的那一个），并在 `_broadcast_round_state` 里挂 `stats` / `mvp`
—— 3v3 那一半**早就挂着**（`server/team_host.gd:523-527`），照它的形状抄；
② **适配器** `ui/match_result_payload.gd` 三个分支改读 `stats`、列按 spec §3.6 排列；
③ **结算页** `ui/match_result.gd` 的 `COLUMN_TITLES` 补三个标题、`dmg` 改名 `dealt`。
★ **三个客户端（`scenes/pvp_game.gd` / `royale_game.gd` / `team_game.gd`）一行都不用改** ——
它们各自只把整条 `round_state` 存进基类的 `_last_round_state`，再交给适配器。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、场景探针（`--headless`；结算页版式那条要**真渲染**）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-stats-and-results-design.md` §3.6 + §4（计划 3/3）。
**依赖**：计划 1（字段集 / `stats_payload` / `mvp_role` / 计分口径）与计划 2（助攻与惩罚的记账）。
**★ 这是一份"碰协议"的计划**：`stats` 对 1v1 / 大乱斗是**新增键（向后兼容增量扩展）**，`mvp` 对 1v1 是新增键 ——
spec §7 的表格把本计划标为"碰协议? **是**"。加法的性质是**老接收端忽略未知键**，
所以不协商版本、不设开关；但**同一个 exe/同一份仓库的两端一起更新**是前提
（不做"老服务端 + 新客户端"的回退读——那会引入第二份真相）。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  `tests/stats_delivery_probe.tscn` 与各 `-s` 冒烟都是 `--headless`、**不占任何端口**；
  `tests/match_result_probe.tscn` **必须真渲染**（不加 `--headless`，判据落在像素与版式上）；
  **实机验收（3v3 打完一局看五列、故意炸死队友看分掉）归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件；提交信息含引号/反引号时用 `git commit -F - <<'EOF'`。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`；本计划**不新增字号**，
  列标题沿用 `MatchResult.SIZE_BODY` = 32）。
- **★ 不许改三个适配器的签名与调用点实参顺序**：`kh_l6_probe` ⑯ 按位置钉着
  `for_duel(round_state, names, PvpSession.role)` / `for_royale(round_state, names, PvpSession.role)`
  （`tests/kh_l6_probe.gd:832-862`），`team_room_smoke` ⑨⑤ 钉着 `for_team` 的四个实参
  （`tests/team_room_smoke.gd:269-283`）。本计划**只改函数体**。
- ★ `columns` 的**顺序**就是显示顺序；"模式没有的列不进"（spec §3.6 + 既有口径）：
  大乱斗**不列 ACS**（单局死斗 ⇒ `acs ≡ kscore`，恒等列零信息；spec §3.3）、**不列助攻**
  （自由混战无归属）。**也不给大乱斗 `mvp`** —— spec §3.6 的大乱斗那一行没有它、§4 也只说
  "3v3 已有；1v1 也可给"；`mvp_role()` 在基础层上现成，将来要加是另一件事。
- 改 GDScript 只需重导出，别重编裁剪模板。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `server/match_round.gd` | 回合机（**1v1 的实际宿主**；另两模式整体覆写它） | 倒地边沿 **加** `_record_down`；`_broadcast_round_state` **加** `stats` / `mvp` |
| `server/royale_host.gd` | 大乱斗权威对局 | 倒地边沿 **加** `_record_down`（并删 `_deaths` 那份重复计数）；`_broadcast_round_state` **加** `stats`、`deaths` 改从逐人表读 |
| `ui/match_result.gd` | 结算页（模式无关） | `COLUMN_TITLES` **加**三个标题、`dmg`→`dealt` |
| `ui/match_result_payload.gd` | 三个模式的适配器（纯函数） | 三个分支改读 `stats`、列按 §3.6、`_row` 加三个字段 |
| `tests/stats_delivery_probe.gd` / `.tscn` | **新探针**：1v1/大乱斗的统计写入与投递 | 全新建 |
| `tests/match_result_payload_smoke.gd` | 适配器 `-s` 冒烟 | 改三处列断言 + 全部夹具；**加**"缺 `stats` 键 ⇒ 空榜不崩" |
| `tests/match_result_probe.gd` | 结算页版式（真渲染；已有"面板必须装得下视口"断言） | 改列数断言与夹具（`dmg`→`dealt`）；③ 那一发**现在就是 6 列** ⇒ 既有那张图开始承担六列的宽度守卫，**不新增图** |
| `CLAUDE.md` | 项目约定 | 登记三模式投递与五列 |

---

### Task 1: 1v1 的统计写入与投递（新探针先红）

**Files:**
- Create: `tests/stats_delivery_probe.gd`
- Create: `tests/stats_delivery_probe.tscn`
- Modify: `server/match_round.gd`

**Interfaces:**
- Consumes: 计划 1 的 `_record_down(victim_role, killer_role)` / `stats_payload()` / `mvp_role()` /
  `_stat_entry(role)`；`MatchCombat._on_player_hit` 的 `dealt` / `taken` 累计（计划 1 已生效，三模式共用）。
- Produces: 1v1 的 `round_state` 里出现 `stats`（任何状态，非空即带）与 `mvp`（仅 MATCH_OVER）。

- [ ] **Step 1: 写探针（会红）**

创建 `tests/stats_delivery_probe.gd`：

```gdscript
extends Node

# 1v1 / 大乱斗的逐人统计**写入与投递**守卫(3v3 的那一半在 `tests/team_host_probe` ⑬g)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn
# 判据: 文本 `STATS DELIVERY: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ═══ 为什么需要它 ═══
# `round_state` 是**广播**出去的(经 `_rpc_all` 的 RPC),探针手里没有 peer ⇒ 拿不到那份字典
# (`_rpc_all` 直接跳过)。故"投递"这一半只能**源码级**(函数体里必须出现 `data["stats"]`),
# 与 `team_host_probe` ⑬g 对 3v3 用的同一条手法;"数值"那一半则**真建宿主**、走生产倒地边沿后
# 读 `stats_payload()`。
# ★ 两半缺一不可:只断数值 ⇒ 键没挂上去(客户端永远收不到)照样全绿;只断源码 ⇒ 数值算错也全绿。
#
# ★ 宿主构造走本仓既有手法(`match_host_hygiene_probe` / `team_host_probe`):
#   真建宿主、`role_peers` 传空、玩家手工摆位、显式补调生产的 `_wire_hit_feedback()`。
# ★ 段数对账(本仓"假绿"纪律:`ALL-OK` 只证明"没有断言失败",不证明"该跑的断言都跑过")
#   —— 末尾拿 `_done` 与 `CHECK_NAMES` 对账,名单不全即红。

const MAP := "res://maps/factory1v1.cyrm"
# 载荷七个字段的**逐码点升序**(`_keys_of` 走 `Array.sort()`)。
# ★★ `dealt` 排在 `deaths` **之前**,别"顺手纠正"成字母表顺序:Godot 的 `Array.sort()` 对 String
#   走**逐码点**比较(`Variant::operator<` → `String::operator<` → `str_compare`),不是按
#   "dealt < deaths 看着不像"的直觉 —— 第 4 个字符 `l`(0x6C) vs `t`(0x74) ⇒ `dealt < deaths`。
#   写成 `[…, deaths, dealt, …]` 会让**生产改对了形状断言照样红**;而错误的修法(放宽成
#   "包含这七个键就行")会把"载荷字段集"这条真契约拆掉 —— 所以这里必须是逐码点升序。
const WANT_KEYS := ["acs", "assists", "dealt", "deaths", "kills", "kscore", "taken"]
const CHECK_NAMES := ["duel_phase", "duel_kill_rule", "royale_phase", "delivery_source"]

var _fails: Array[String] = []
var _done: Array[String] = []


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
func _ready() -> void:
	await _run()
	_finish()


func _finish() -> void:
	# ★ 段数对账:每个 `_check_*` 末行都要把自己的名字记进 `_done`;名单不全 = 有一段
	#   中途出错被静默跳过(脚本错误只让**出错的那个函数**结束,调用方继续 ⇒ verdict 照打 ALL-OK)。
	var missing: Array[String] = []
	for n in CHECK_NAMES:
		if not _done.has(n):
			missing.append(n)
	if not missing.is_empty():
		print("STATS DELIVERY: FAIL —— ★★ 这些检查**没跑到尾**:%s" % str(missing))
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("STATS DELIVERY: ALL-OK")
	else:
		print("STATS DELIVERY: FAIL —— " + str(_fails))
	get_tree().quit(0 if _fails.is_empty() else 1)


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


# 逐人条目的原始计数(缺条目 = 0,与生产 `_stat_entry` 同口径)。
func _stat(host, role: int, key: String) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get(key, 0))


# 生产那条"强制倒地"入口(`CombatComponent.force_down`;K 键自杀走的也是它)。
func _force_down(host, role: int) -> void:
	(host.players[int(role)] as Node).get_node("Combat").force_down()


func _kscore(host, role: int) -> int:
	return int(host.stats_payload()[int(role)]["kscore"])


func _keys_of(host, role: int) -> Array:
	var row: Dictionary = host.stats_payload().get(int(role), {})
	var k: Array = row.keys()
	k.sort()
	return k


func _run() -> void:
	await _check_duel_phase()
	await _check_duel_kill_rule()
	await _check_royale_phase()
	_check_delivery_source()


# ── ① 1v1:伤害进 dealt/taken、倒地记 deaths、击杀记给对手、载荷七个字段 ──
func _check_duel_phase() -> void:
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelHost"
	add_child(host)
	# ★ 合成/真图都行:本段只用「归因 + take_hit + 倒地边沿 + 逐人表」,不碰几何。
	#   真图 `factory1v1.cyrm` 有 `# player`/`# player2` 出生点,`_respawn_player` 才可用。
	GameParameters.refresh_map_size()
	_place(host, 1, Vector2i(17, 65))
	_place(host, 2, Vector2i(133, 64))
	host._wire_hit_feedback()     # ★ 手工摆位路径必须补调**生产那一份**接线(否则一条线都没有)
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame     # 让 `@onready` 的 combat/weapons 就绪

	# (a) 一次已知伤害 → dealt 记给射手、taken 记给受害者
	var dealt0 := _stat(host, 1, "dealt")
	var taken0 := _stat(host, 2, "taken")
	CombatFeedback.attribute(host.players[2], host.players[1])
	(host.players[2] as Node2D).take_hit(Vector2.ZERO, 7)
	_check(_stat(host, 1, "dealt") - dealt0 == 7,
			"★ ① 1v1:己方伤害进**射手**的 dealt(实际 +%d,期望 +7)"
			% (_stat(host, 1, "dealt") - dealt0))
	_check(_stat(host, 2, "taken") - taken0 == 7,
			"★ ① 1v1:同一笔进**受害者**的 taken(实际 +%d,期望 +7)"
			% (_stat(host, 2, "taken") - taken0))

	# (b) 倒地 → deaths 一律 +1、击杀记给对手(1v1 的计分口径)
	_force_down(host, 2)     # 走生产那条强制倒地入口
	host._match_round_tick(0.016)
	_check(_stat(host, 2, "deaths") == 1,
			"★ ① 1v1:倒地边沿记 deaths(实际 %d,期望 1)" % _stat(host, 2, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			"★ ① 1v1:击杀记给对手(实际 %d,期望 1)" % _stat(host, 1, "kills"))
	_check(_kscore(host, 1) == 100 + 7 / 5,
			("★ ① 1v1:kscore = 击杀×100 + 伤害÷5(实际 %d,期望 %d)"
			+ " —— 这条把「公式真的走在生产路径上」与逐人表接起来")
			% [_kscore(host, 1), 100 + 7 / 5])
	_check(_keys_of(host, 1) == WANT_KEYS,
			"★ ① 1v1:载荷每行恰好七个字段(实际 %s)" % str(_keys_of(host, 1)))
	host.free()

	_done.append("duel_phase")
	await get_tree().process_frame


# ── ② 1v1 的击杀规则是**无归因**的:自杀也给对手 +1(结算页必须与记分条同口径)──
func _check_duel_kill_rule() -> void:
	var host = MatchHost.new(MAP, {}, {})
	host.name = "StatsDuelSuicideHost"
	add_child(host)
	GameParameters.refresh_map_size()
	_place(host, 1, Vector2i(17, 65))
	var p2: Node2D = _place(host, 2, Vector2i(133, 64))
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	# 自杀:K 键那条路 = 先清归因 meta、再 `force_down`(见 `RoyaleHost.request_suicide_role`)
	for m in ["last_damager", "last_damager_time"]:
		if p2.has_meta(m):
			p2.remove_meta(m)
	_force_down(host, 2)
	host._match_round_tick(0.016)
	_check(_stat(host, 2, "deaths") == 1, "★ ② 1v1:自杀照记 deaths(实际 %d)" % _stat(host, 2, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			("★ ② 1v1:**无归因的死亡也算对手的击杀**(实际 %d,期望 1)"
			+ " —— 1v1 的计分口径是「不分死因、对方死亡都算」(用户裁定);"
			+ "照 3v3 的『只算有归因的击杀』写会让结算页的击杀数**低于**记分条上的分数") % _stat(host, 1, "kills"))
	host.free()

	_done.append("duel_kill_rule")
	await get_tree().process_frame


# ── ③ 大乱斗:同一个倒地边沿记 deaths/击杀,`deaths` 载荷只从逐人表来 ──
func _check_royale_phase() -> void:
	var host = RoyaleHost.new(MAP, {}, {}, [], {})
	host.name = "StatsRoyaleHost"
	add_child(host)
	GameParameters.refresh_map_size()
	_place(host, 1, Vector2i(20, 20))
	_place(host, 2, Vector2i(40, 20))
	_place(host, 3, Vector2i(60, 20))
	host._wire_hit_feedback()
	host._round_state = MatchHost.RoundState.PLAYING
	await get_tree().physics_frame
	CombatFeedback.attribute(host.players[3], host.players[1])
	(host.players[3] as Node2D).take_hit(Vector2.ZERO, 8)
	_force_down(host, 3)
	host._match_round_tick(0.016)
	_check(_stat(host, 3, "deaths") == 1,
			"★ ③ 大乱斗:倒地边沿记 deaths(实际 %d,期望 1)" % _stat(host, 3, "deaths"))
	_check(_stat(host, 1, "kills") == 1,
			"★ ③ 大乱斗:有归因的击杀记给射手(实际 %d,期望 1)" % _stat(host, 1, "kills"))
	_check(_stat(host, 3, "taken") == 8 and _stat(host, 1, "dealt") == 8,
			"★ ③ 大乱斗:dealt/taken 与 1v1 同源(实际 %d/%d,期望 8/8)"
			% [_stat(host, 1, "dealt"), _stat(host, 3, "taken")])
	_check(_keys_of(host, 3) == WANT_KEYS,
			"★ ③ 大乱斗:载荷每行恰好七个字段(实际 %s)" % str(_keys_of(host, 3)))
	check_royale_deaths_source()
	host.free()

	_done.append("royale_phase")
	await get_tree().process_frame


# 大乱斗载荷里的 `deaths` 必须**从逐人表读**(旧的 `_deaths` 是同一件事的第二份计数,已删)。
func check_royale_deaths_source() -> void:
	var body := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/royale_host.gd")), "_broadcast_round_state")
	_check(not body.is_empty(), "取不到 royale_host._broadcast_round_state 的函数体(改名/挪走了?)")
	if body.is_empty():
		return
	_check(body.contains("_roster()"),
			"★ ③ 大乱斗载荷的 `deaths` 必须从逐人表的 role 集合(`_roster()`)构造(第二份计数会漂)")


# ── ④ 投递那一半(源码级):`stats` / `mvp` 真的挂在两个宿主的 round_state 上 ──
func _check_delivery_source() -> void:
	var duel := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_broadcast_round_state")
	_check(not duel.is_empty(), "取不到 match_round._broadcast_round_state 的函数体")
	if not duel.is_empty():
		_check(duel.contains('data["stats"]'), "★ ④ 1v1 的 round_state 挂上 `stats`")
		_check(duel.contains('data["mvp"]'), "★ ④ 1v1 的 round_state 挂上 `mvp`(MATCH_OVER 分支)")
		_check(duel.contains("if not table.is_empty():"),
				"★ ④ 1v1 的 `stats` **只在非空时**带该键(与 teams / destroyed / 3v3 同款纪律)")
	var roy := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/royale_host.gd")), "_broadcast_round_state")
	_check(not roy.is_empty(), "取不到 royale_host._broadcast_round_state 的函数体")
	if not roy.is_empty():
		_check(roy.contains('data["stats"]'), "★ ④ 大乱斗的 round_state 挂上 `stats`")
		# ★ 反向:大乱斗**不给** `mvp`(spec §3.6/§4 都没要求;`acs ≡ kscore` 且榜已按击杀排)。
		#   这条不是洁癖 —— 加上去之后 `for_royale` 不读它,那才是"没有读者的键"。
		_check(not roy.contains('data["mvp"]'),
				"★ ④ 大乱斗**不该**带 `mvp`(本计划的既定取舍;要加是另一件事)")
	# 反向:1v1 的统计**必须**由 `MatchRound._match_round_tick` 的倒地边沿写(不能只靠子类)。
	var tick := ScanUtil.func_body(
			ScanUtil.code_only(ScanUtil.read("res://server/match_round.gd")), "_match_round_tick")
	_check(not tick.is_empty(), "取不到 match_round._match_round_tick 的函数体")
	if not tick.is_empty():
		_check(tick.contains("_record_down("),
				"★ ④ 1v1 的倒地边沿必须调 `_record_down`(不写 = deaths/kills 恒 0,不报错)")

	_done.append("delivery_source")
```

- [ ] **Step 2: 建场景**

创建 `tests/stats_delivery_probe.tscn`（与 `tests/team_host_probe.tscn` 逐字同构，只改名字）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/stats_delivery_probe.gd" id="1"]

[node name="StatsDeliveryProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次，确认它红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn 2>&1 | grep -E "STATS DELIVERY|ok  |FAIL"
```
Expected（改宿主**之前**）—— 表里左列是**会红的那一条**，右列是**夹具怎么到达那个状态**：

| 红在哪 | 期望 → 实际 | 为什么夹具能到达 |
|---|---|---|
| ① `倒地边沿记 deaths` | 1 → **0** | `server/match_round.gd` 的 `_match_round_tick`(1v1 的倒地边沿)**从不写逐人表** ⇒ `_record_down` 一次都没被调 |
| ① `击杀记给对手` | 1 → **0** | 同上 |
| ① `kscore = 击杀×100 + 伤害÷5` | 101 → **1** | kills 恒 0，只剩那 7 点伤害的 `7/5 = 1`（`dealt` 由计划 1 的共用钩子记上） |
| ② `无归因的死亡也算对手的击杀` | 1 → **0** | 同上（自杀那一步清掉 meta 后 `force_down`，而表里没人写） |
| ③ `大乱斗:倒地边沿记 deaths` | 1 → **0** | `RoyaleHost._match_round_tick` 写的是 `_deaths`（另一份计数），没调 `_record_down` |
| ③ `大乱斗:有归因的击杀记给射手` | 1 → **0** | 同上（它写的是 `_scores`） |
| ③ `大乱斗载荷的 deaths 必须从逐人表构造` | `_roster()` 在位 → **不在位** | `royale_host.gd:325` 现写 `"deaths": _deaths` |
| ④ `1v1 round_state 挂上 stats` / `挂上 mvp` / `if not table.is_empty():` | 三条 → **三条全无** | `match_round.gd:150-163` 的 payload 里没有这两行 |
| ④ `1v1 倒地边沿必须调 _record_down` | 有 → **没有** | 同 ① 的成因，这一条是它的**源码级**表述 |
| ④ `大乱斗 round_state 挂上 stats` | 有 → **没有** | `royale_host.gd:321-331` 的 payload 里没有 |

**改宿主之前就该是绿的**（计划 1 的成果，对本计划是**正向对照** —— 少了它们，
"什么都没接"的坏实现也能让上面的红全部通过）：
- ① 的 `dealt` / `taken` 两条、① 的字段集那条（`_on_player_hit` 与 `stats_payload` 是**三模式共用**的，
  计划 1 已接通）；
- ③ 的 `dealt`/`taken` 两条与字段集那条（同一钩子）；
- ④ 的 `大乱斗**不该**带 mvp`（否定断言，与本次改动无关）。

★ 红是**值不匹配**（或"函数体里没有那一行"），不是"跑不起来"：本探针读的都是计划 1 已经
提供的口（`stats_payload` / `_stats` / `stats_payload()[r]["kscore"]`），故 Step 1 的探针能在
**旧宿主**上正常跑完并打印 `STATS DELIVERY: FAIL —— [...]`。

- [ ] **Step 4: 1v1 宿主接上**

`server/match_round.gd` 的 `_match_round_tick`，在 `_drop_all_but_one(p, role)`（`:25`）之后、
`var scorer := _opponent_of(role)`（`:28`）之前插入：

```gdscript
		# 逐人统计(★ 2026-09-25):倒地边沿记 death(一律)与击杀。
		# ★ 击杀记给**对手**,口径与下面的 `scorer` 逐字一致 —— 1v1 的计分规则是
		#   「不分死因、对方死亡都算」(用户裁定),它**没有归因**:自杀/溺水也让对方 +1 分。
		#   结算页的 kills 必须与记分条同口径,否则"5 杀取胜"的局在结算页上只显示 3 杀(不报错)。
		# ★ **不能**在这里用击杀归因那个具名函数:它住子类,而基类并集里出现它的名字会让
		#   `tests/kh_l5_probe.gd:544-549` 的反向断言变红(子类方法不得泄漏进基类)。
		_record_down(int(role), _opponent_of(int(role)))
```

`server/match_round.gd` 的 `_broadcast_round_state`（`:150-163`），在 MATCH_OVER 那一支里加 `mvp`、
在函数末尾加 `stats`（照 `server/team_host.gd:508-528` 的形状抄）：

```gdscript
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
		# MVP:整场 ACS 最高者(并列 → 击杀多者 → 阵亡少者 → role 升序,见底座 `mvp_role`)。
		# ★ 与 `match_winner` **同款时机**:只在 MATCH_OVER 带(局中还没有"整场"可言)。
		# ★ 1v1 也给 —— spec §4 明说"1v1 也可给";口径与 3v3 **逐字相同**,不限制在胜方
		#   (换公式之后"MVP 常在败方"的那个结构性来源已经没了,见 spec §1.3)。
		data["mvp"] = mvp_role()
	# 逐人数据:与 `destroyed` / `ground_weapons` / 3v3 同款纪律 —— **只在非空时带该键**
	# (1v1 只有两个 role,一次广播多几十字节;空表不占带宽,旧客户端忽略未知键)。
	# ★ 本函数是 **1v1 专用**:`RoyaleHost` 与 `TeamHost` 都整体覆写了 `_broadcast_round_state`,
	#   不会与本段叠加(同一份数据只投递一次)。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
```

- [ ] **Step 5: 跑 —— 确认 ①/②/④ 转绿（③ 仍红）**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn 2>&1 | grep -E "STATS DELIVERY|FAIL"
```
Expected: ① 与 ② 全部通过；④ 里与 **1v1** 有关的三条（`data["stats"]` / `data["mvp"]` /
`_record_down(`）**新变绿**；**仍红的只剩 ③ 那三条 + ④ 的「大乱斗的 round_state 挂上 `stats`」**。
★ ④ 的第六条（「大乱斗**不该**带 `mvp`」）与本次改动无关、**本来就绿、改完也仍绿**
（大乱斗至今没有任何 `mvp`）—— 它是一条**否定断言**，不是红灯，别等它变。

- [ ] **Step 6: 提交（与 Task 2 合并为一次提交亦可；本计划按 Task 分开提交）**

```bash
git add server/match_round.gd tests/stats_delivery_probe.gd tests/stats_delivery_probe.tscn
git commit -F - <<'EOF'
feat(stats): 1v1 的逐人统计(倒地边沿记 death/kill + round_state 带 stats/mvp)
EOF
```

---

### Task 2: 大乱斗的统计写入与投递

**Files:**
- Modify: `server/royale_host.gd`

**Interfaces:**
- Consumes: Task 1 的探针（③ 相就是本 Task 的红灯）；计划 1 的 `_record_down` / `stats_payload` /
  `_roster()`。
- Produces: 大乱斗 `round_state` 的 `stats` 键；`deaths` 键的来源改为逐人表（**键名与形状不变**，
  `ui/royale_hud.gd:151-152` 与 `tests/royale_soak_probe` 一个字不用改）。

- [ ] **Step 1: 先跑一次，确认 ③ 是最初的红（Task 1 之后）**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn 2>&1 | grep -E "STATS DELIVERY|大乱斗"
```
Expected —— **四条，全在大乱斗那一侧**：
| 红在哪 | 期望 → 实际 | 为什么夹具能到达 |
|---|---|---|
| ③ `大乱斗:倒地边沿记 deaths` | 1 → **0** | `royale_host.gd:228` 写的是 `_deaths`（另一份计数），没调 `_record_down` |
| ③ `大乱斗:有归因的击杀记给射手` | 1 → **0** | 同上（击杀写的是 `_scores`） |
| ③ `大乱斗载荷的 deaths 必须从逐人表构造` | `_roster()` 在位 → **不在位** | `royale_host.gd:325` 现写 `"deaths": _deaths` |
| ④ `大乱斗 round_state 挂上 stats` | 有 → **没有** | `royale_host.gd:321-331` 的 payload 里没有这一行 |

**此时仍是绿的**：③ 的 `dealt/taken 与 1v1 同源`（`_on_player_hit` 是三模式共用的钩子，
计划 1 已接通 —— 它的存在是为了证明"这一相真的跑到了伤害那一步"，不是红灯）；
④ 里 **1v1 那三条也已绿**（Task 1 改完了）。别把它们当"还没修的"去追。

- [ ] **Step 2: 倒地边沿接上，删掉重复计数**

`server/royale_host.gd` 的 `_match_round_tick` 的 PLAYING 分支里，把
`_deaths[int(role)] = int(_deaths.get(int(role), 0)) + 1   # 阵亡计数`（`:228`）那一行改成
"先取归因、再一次性记账"：

```gdscript
				_down_counted[role] = true
				# 掉落:倒地**这一刻**在原地丢下除随机保留一把外的全部武器(与基类同款)。
				_drop_all_but_one(p, int(role))
				var killer := _attributed_killer(p)
				# 逐人统计(★ 2026-09-25):倒地边沿记 death(一律)与击杀(仅在归因到时)。
				# ★ `_deaths` 那份**独立的**阵亡计数已删 —— 它与逐人表记的是同一件事,
				#   两份计数必然漂(载荷里的 `deaths` 改从逐人表构造,见 `_broadcast_round_state`)。
				_record_down(int(role), killer)
				if killer != 0:
					_scores[killer] = int(_scores.get(killer, 0)) + 1
					_broadcast_kill(killer, role)
				_broadcast_round_state()
```

并删除文件顶部 `var _deaths: Dictionary = {}`（`:25`）那一行。

- [ ] **Step 3: 数据包改从逐人表来 + 加 `stats`**

`server/royale_host.gd` 的 `_broadcast_round_state`（`:304-336`）：

1. 把 `"deaths": _deaths,`（`:325`）换成构造出来的字典（**键名与形状不变**）：
```gdscript
	# `deaths` 仍是逐 role 计数(royale_hud 的排行榜按它显示"阵亡"),但来源改成**逐人统计表**
	# —— 原先的 `_deaths` 是同一件事的第二份计数(两份必然漂,且不会有任何断言变红)。
	var deaths := {}
	for role in _roster():
		var s: Dictionary = _stats.get(int(role), {})
		deaths[int(role)] = int(s.get("deaths", 0))
```
   并把 `data` 字面量里的 `"deaths": _deaths,` 改成 `"deaths": deaths,`。
2. 在 `data["match_winner"] = _match_winner()`（`:333`）之后加：
```gdscript
	# 逐人数据:与 `destroyed` / `ground_weapons` / 3v3 同款纪律 —— **只在非空时带该键**。
	# ★ 大乱斗**不带 `mvp`**(spec §3.6/§4 都没要求;结算页那一栏也不列 ACS) ——
	#   加了它就会是一个没有读者的键。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
```

- [ ] **Step 4: 跑 —— 确认全部通过**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn 2>&1 | grep -E "STATS DELIVERY|ok  |FAIL"
```
Expected: 全 `ok  `，末行 `STATS DELIVERY: ALL-OK`。

- [ ] **Step 5: 反证（把 1v1 那条边沿撤掉，确认 ①/②/④ 回红）**

临时注释掉 Task 1 插进 `MatchRound._match_round_tick` 的 `_record_down(...)` 那一行，跑：
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/stats_delivery_probe.tscn 2>&1 | grep -E "STATS DELIVERY|FAIL"
```
Expected（★ 2026-09-26 实测订正：**六条**红、不是五条 —— 本表是该计划**第四张**被实测纠正的
期望表；另相号也变了，见下）—— 全在 1v1 那一侧：
- `★ ① 1v1:倒地边沿记 deaths(实际 0,期望 1)`
- `★ ① 1v1:击杀记给对手(实际 0,期望 1)`
- `★ ① 1v1:kscore = 击杀×100 + 伤害÷5(实际 1,期望 101)` ← **这条也会红**（kills 恒 0，
  只剩那 7 点伤害的 `7/5 = 1`）
- `★ ② 1v1:无归因的死亡也算对手的击杀(实际 0,期望 1)`
- `★ ② 1v1:自杀照记 deaths(实际 0,期望 1)` ← **补上的一条**：它与上一条是**同一个 ② 夹具里
  读同一个 `_stat(host,2,"deaths")` 格**的兄弟断言 ⇒ `_record_down` 一撤，它在**结构上**不可能
  保持绿（初稿漏列）
- `★ ④ 1v1 的倒地边沿必须调 _record_down`（**路线**守卫，仍在 ④）

而 **③ 那三条与 ⑤ 的「大乱斗确实带 `stats`」保持绿** —— 大乱斗走的是它自己那个宿主的
`_record_down` 调用点（Task 2 加的），与这一行无关 ⇒ 证明这六条红的成因就是那一行，不是环境。
★ 相号（2026-09-26 评审修复波之后）：**数据包真的带没带键**全部归相 **⑤ `delivery_payload`**
（子类覆写 `_rpc_all`、调用时刻深拷贝）；④ 只剩**来源/路径**两条源码级守卫。
★ 顺带：① 的 dealt/taken 两条与字段集那条**也仍绿**（`_on_player_hit` 是共用钩子，没动）。
确认后**改回来**。

- [ ] **Step 6: 提交**

```bash
git add server/royale_host.gd
git commit -F - <<'EOF'
feat(stats): 大乱斗的逐人统计(倒地边沿记 death/kill + stats;deaths 改从逐人表构造)
EOF
```

---

### Task 3: 结算页五列（适配器 + 标题）

**Files:**
- Modify: `tests/match_result_payload_smoke.gd`（先改 → 红）
- Modify: `ui/match_result_payload.gd`
- Modify: `ui/match_result.gd`
- Modify: `tests/match_result_probe.gd`

**Interfaces:**
- Consumes: 各模式 `round_state` 的 `stats`（Task 1/2 + 既有的 3v3）与 `mvp`（1v1 / 3v3）。
- Produces:
  - `MatchResultPayload.C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]`
  - `MatchResultPayload.C_ROYALE := ["kills", "deaths", "dealt", "taken"]`
  - `MatchResultPayload.C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]`
  - `MatchResultPayload._row(nm, kills, deaths, assists, dealt, taken, acs, mvp := false)`
  - `MatchResult.COLUMN_TITLES` 含 `assists` / `dealt` / `taken`（删除 `dmg`）
  - ★ **三个适配器的签名与实参顺序不变**（`kh_l6_probe` ⑯ / `team_room_smoke` ⑨⑤ 钉着）。

- [ ] **Step 1: 先改 `-s` 冒烟（会红）**

`tests/match_result_payload_smoke.gd`：

**(a)** ① 的列断言（`:26-27`）改成：

```gdscript
	var duel: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 7, "deaths": 2, "assists": 0, "dealt": 500, "taken": 200, "kscore": 800, "acs": 400},
			2: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 300, "taken": 400, "kscore": 250, "acs": 125}},
			"rounds_won": {1: 2, 2: 1}, "mvp": 1, "match_winner": 1 }, names, 1)
	# ★ 1v1 的列 = K/D/造成/承受/ACS(spec §3.6;无助攻 —— 1v1 拿不到助攻,见 §3.4)
	if duel["columns"] != ["kills", "deaths", "dealt", "taken", "acs"]:
		fails.append("★ 1v1 的 columns 应为 [kills, deaths, dealt, taken, acs],实得 %s" % [duel["columns"]])
```

**(b)** ② / ②b 的两处 `for_duel` 夹具也换成 `stats` 形状（②b 的"缺条目照样出行"那条**必须保留**，
它现在验的是"`stats` 里缺 role ⇒ 出行且该行是 0"）：

```gdscript
	var draw: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200},
			2: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200}},
			"match_winner": 0 }, names, 1)
```
```gdscript
	var one_sided: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 5, "deaths": 0, "assists": 0, "dealt": 100, "taken": 0, "kscore": 500, "acs": 500}},
			"rounds_won": {1: 2, 2: 0}, "match_winner": 1 }, names, 2)
```

**(c)** ③ / ③b 的大乱斗夹具换成 `stats`，列断言改成四列：

```gdscript
	# ③ 大乱斗:kills/deaths/dealt/taken 四列,按 kills 降序(无 ACS —— 单局死斗 ⇒ acs ≡ kscore)
	var roy: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 2 }, names, 1)
	if roy["columns"] != ["kills", "deaths", "dealt", "taken"]:
		fails.append("大乱斗 columns 应为 [kills,deaths,dealt,taken],实得 %s" % [roy["columns"]])
	# ★★ 「榜首仍是 9 杀」那条(**原 :72-73**)必须**同时**改成这个形状,而且**必须先判空**:
	#   新夹具去掉了 `scores`,而本步跑的时候 `for_royale` **还没改**(它仍读 `scores`)
	#   ⇒ `rows` 为空 ⇒ 原来那句 `roy["sections"][0]["rows"][0]["kills"]` **越界**
	#   ⇒ `_initialize()` 当场中断 ⇒ **不 `quit()`** ⇒ 进程**永久挂起、连一行 verdict 都没有**
	#   (`-s` 没有 `--quit-after` 兜底;★ 挂住与真失败在输出上**不可分**,都是"看不到 FAIL")。
	#   改完的判据见下面 ③ 的那两条。
	③b / ③ 之后那三条**标题**断言（`"游戏结束"`，含 `my_role == match_winner` 与平局两档）
   **照旧** —— 它们只验标题与 `stats` 无关，但夹具同样要换成上面的 `stats` 形状。

**(c2)** 把**原 `:72-73`** 的榜首断言换成"先判空、再判值"（顺手把 → 的期望写在同处）：
```gdscript
	# ★★ 先判空:见上一条说明 —— 空榜时 `rows[0]` 会越界,而越界的后果是**挂住**。
	var rrows: Array = roy["sections"][0]["rows"]
	if rrows.is_empty():
		fails.append("★ 大乱斗榜为空(夹具缺 `stats` / 适配器还没改读 `stats`?)—— 不判空的话"
				+ " `rows[0]` 会越界,整支冒烟会**挂住**而不是失败(本仓判据:挂住与失败不可分)")
	elif int(rrows[0]["kills"]) != 9:
		fails.append("★ 大乱斗榜首应是 9 杀(降序排错)")
```
★ 新夹具下排序后榜首仍是 role 2(9 杀)⇒ `rrows[0]["kills"] == 9` 这条**语义没变**,变的是
"它现在从 `stats` 来"。

**(d)** ④ 的列断言（`:104-105`）与夹具的键名：

```gdscript
	var stats := {1: {"kills": 5, "deaths": 3, "assists": 2, "dealt": 400, "taken": 250, "kscore": 600, "acs": 200},
			2: {"kills": 2, "deaths": 5, "assists": 1, "dealt": 150, "taken": 400, "kscore": 200, "acs": 66},
			4: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 300, "taken": 200, "kscore": 350, "acs": 100},
			5: {"kills": 8, "deaths": 1, "assists": 3, "dealt": 900, "taken": 150, "kscore": 1200, "acs": 400}}
	...
	if team["columns"] != ["kills", "deaths", "assists", "dealt", "taken", "acs"]:
		fails.append("3v3 columns 应为 [kills,deaths,assists,dealt,taken,acs],实得 %s" % [team["columns"]])
```

**(e)** 新增一段 ⑦（**缺 `stats` 键 ⇒ 空榜、不崩**；本页的硬契约是"缺键一律取默认"）：

```gdscript
	# ⑦ ★ 数据包里**没有 `stats` 键**(老服务端 / 极端路径)⇒ 空榜、不崩。
	#   ★ 本适配器**不做**回退读 `scores`/`deaths`:那会让同一件事有两个来源(两份真相),
	#     而两端由同一份仓库/同一个 exe 一起更新 —— 加法的性质是"老**接收端**忽略未知键",
	#     不是"新接收端兼容老服务端"。
	var no_stats_duel: Dictionary = script.for_duel({ "match_winner": 1 }, names, 1)
	if (no_stats_duel["sections"][0]["rows"] as Array).size() != 2:
		fails.append("★ 缺 `stats` 时 1v1 仍应出两行(0 值),实得 %d 行"
				% (no_stats_duel["sections"][0]["rows"] as Array).size())
	var no_stats_roy: Dictionary = script.for_royale({ "match_winner": 1 }, names, 1)
	if (no_stats_roy["sections"][0]["rows"] as Array).size() != 0:
		fails.append("★ 缺 `stats` 时大乱斗应是空榜(不硬造行),实得 %d 行"
				% (no_stats_roy["sections"][0]["rows"] as Array).size())
```

- [ ] **Step 2: 跑一次，确认它红**

Run（★ **必须套 `timeout`** —— `-s` 脚本没有 `--quit-after` 兜底，而本步要跑的是
**还没改过适配器**的代码：一旦哪条断言越界，进程会**永久挂住**）:
```bash
source tests/env.sh && timeout 120 "$GODOT" --headless --path . -s res://tests/match_result_payload_smoke.gd 2>&1 | grep -E "MATCH RESULT|★"
```
Expected —— ★ **实测订正：九条红，不是四条**（本计划**第五张**被实测纠正的期望表）。而且
**进程必须正常退出**（看到 `MATCH RESULT PAYLOAD: FAIL` 那一行、`EXIT=1`）：

```
  - ★ 1v1 的 columns 应为 [kills, deaths, dealt, taken, acs],实得 ["kills"]
  - 1v1 榜首应是 7 杀
  - ★ 缺条目的 role 那一行应仍是 role 2 的昵称,实得 阿甲
  - 大乱斗 columns 应为 [kills,deaths,dealt,taken],实得 ["kills", "deaths"]
  - ★ 大乱斗榜为空(夹具缺 `stats` / 适配器还没改读 `stats`?)—— 不判空的话 `rows[0]` 会越界,…
  - 3v3 columns 应为 [kills,deaths,assists,dealt,taken,acs],实得 ["kills", "deaths", "dealt", "acs"]
  - ★ MatchResultPayload 里找不到 `C_DUEL`(列常量改名了?)
  - ★ MatchResultPayload 里找不到 `C_ROYALE`(列常量改名了?)
  - ★ MatchResultPayload 里找不到 `C_TEAM`(列常量改名了?)
```

**四处与初稿不同（逐条都有实测）**：
1. **初稿只列了四条** —— 漏了 1v1 的 `榜首应是 7 杀`、`缺条目的 role 那一行应仍是 role 2 的昵称`
   （见 ③）与 Step 1 那三条"找不到 `C_*` 常量"（常量是本 Task 才加的）。
2. **有两条在源码里**没有 `★`** —— 而本步给的命令是 `grep -E "MATCH RESULT|★"`
   ⇒ **照 brief 自己的命令根本看不到这两行**（内容对、标记错）。
   ★ **订正（评审复核）**：这两条是 **`1v1 榜首应是 7 杀`（`:33`）** 与
   **`大乱斗 columns 应为 …`（`:80`）**；**`★ 大乱斗榜为空…`（`:87`）是**带 `★` 的**
   —— 本段初稿把它错点成了"没有 `★`"的那一条。
3. **漏了一条真红**：`★ 缺条目的 role 那一行应仍是 role 2 的昵称,实得 阿甲`。
   成因值得记住：旧适配器下**两行 kills 都是 0** ⇒ 三级排序落到**昵称级**，
   `"bob"(0x62) < "阿甲"(0x963F)` ⇒ **两行互换** ⇒ `rows[1]` 不再是 bob。
   （初稿说这条"此时仍绿" —— 它同块里的**前两条**确实绿、**第三条**红。）
4. **3v3 那条的"实得"初稿写 `dmg`，实际是 `dealt`** —— 探针夹具早在 `60860fd` 就是 `dealt`
   ⇒ Step 5(b) 那个 `dmg`→`dealt` 的改动是**空操作**。

★ 进程**没有挂住**（verdict 正常打印）⇒ (c2) 的判空守卫确实堵住了初稿预言的那个挂住形状
（旧 `for_royale` 读不到 `scores` ⇒ `rows` 空 ⇒ 原 `:72` 的 `rows[0]` 越界）。

★★ **挂住 ≠ 失败，而它们在本仓的输出里长得一样**（都是"看不到 FAIL 文本"）：本步若
`timeout` 到点后**一行 verdict 都没打印**，先回去看 (c2) 的判空守卫有没有加 —— 那是本步
**唯一**会造成挂住的已知形状，不是"探针没意见"。
★ 「缺 `stats` ⇒ 大乱斗空榜」那一条 ⑦：旧实现（读 `scores`）在 `scores` 缺席时**也是空榜**
⇒ **此时绿**；它真正的鉴别力在重建之后的"别顺手加回退读 `scores`"上。

- [ ] **Step 3: 改适配器**

`ui/match_result_payload.gd`：

**(a)** 常量（替换 `C_KILLS`）：

```gdscript
# 各模式的列 —— **顺序就是显示顺序**,由 spec §3.6 定;"模式没有的列不进"是既有口径:
#   · 大乱斗无 ACS(单局死斗 ⇒ `acs ≡ kscore`,恒等列零信息)、无助攻(自由混战无归属);
#   · 1v1 无助攻(`same_team` 恒 false ⇒ 那模式拿不到助攻,见 spec §3.4)。
const C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]
const C_ROYALE := ["kills", "deaths", "dealt", "taken"]
const C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]
```

**(b)** `_row`（`:109-111`）加三个字段：

```gdscript
static func _row(nm: String, kills: int, deaths: int, assists: int, dealt: int, taken: int,
		acs: int, mvp: bool = false) -> Dictionary:
	return {"rank": 0, "name": nm, "kills": kills, "deaths": deaths, "assists": assists,
			"dealt": dealt, "taken": taken, "acs": acs, "mvp": mvp}
```

**(c)** `for_duel`（`:23-41`）整体替换：

```gdscript
# 1v1。行数据一律读 `stats`(服务端算好的七字段),**不再读 `scores`**——
# `scores` 是"本局击杀"(每局清零),它不是结算页要的整场口径。
# ★ 遍历仍写死 `[1, 2]`:1v1 只有这两个 role,**缺条目 = 0**(不是"没有这个人的数据")——
#   写成 `if not stats.has(role): continue` 会在一局 5-0 时画出**只有一行**的榜,
#   输的那位从**自己的**结算页上消失(他正是要看到自己那一行的人)。
# 列 = K/D/造成/承受/ACS(spec §3.6)。
# ★ MVP 的落点与 `for_team` 同一形状:`_row` 的第 8 个实参就是"这一行是不是 MVP",
#   排序之后再去找那个 `mvp == true` 的行 —— **别**想着"按 role 反查行"
#   (`_row` 只承载展示字段,没有 role 键;要靠 role 找行就得另开一个临时结构)。
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var rows: Array = []
	for role in [1, 2]:
		var s: Dictionary = stats.get(role, {})
		rows.append(_row(_name_of(names, role), int(s.get("kills", 0)), int(s.get("deaths", 0)),
				int(s.get("assists", 0)), int(s.get("dealt", 0)), int(s.get("taken", 0)),
				int(s.get("acs", 0)), int(role) == mvp_role))
	_finish(rows, "kills")
	# mvp 的行号必须在**排完序之后**数,否则高亮会落在错的那一行(与 `for_team` 同款)
	var mvp_pos := {}
	for ri in rows.size():
		if bool(rows[ri]["mvp"]):
			mvp_pos = {"section": 0, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_DUEL,
		"sections": [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": mvp_pos,
	}
```

**(d)** `for_royale`（`:54-67`）整体替换：

```gdscript
# 大乱斗。自由混战:行数据读 `stats`(`scores`/`deaths` 那两条键**留给局内 HUD** ——
# `ui/royale_hud.gd` 的排行榜按它们显示实时比分,与本页是两回事)。
# 列 = K/D/造成/承受(spec §3.6):**无 ACS**(单局死斗 ⇒ `acs ≡ kscore`)、**无助攻**。
# ★★ 标题恒为「游戏结束」,**与 `match_winner` 无关**(用户 2026-09-21 裁定:
#    「大乱斗结算榜单不应该有任何胜利/失败,而是游戏结束」)。故**刻意不调 `_verdict`**。
# ★ `my_role` 仍是第 3 个形参(调用方 `royale_game._build_result_payload` 传 `PvpSession.role`,
#   签名不动 —— `kh_l6_probe` ⑯ 按位置钉着那个实参);本函数用不到它,但**不要**删。
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var rows: Array = []
	for role in stats:
		var s: Dictionary = stats[role]
		rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
				int(s.get("deaths", 0)), int(s.get("assists", 0)),
				int(s.get("dealt", 0)), int(s.get("taken", 0)), int(s.get("acs", 0))))
	_finish(rows, "kills")
	return {
		"title": "游戏结束",
		"subtitle": "",
		"columns": C_ROYALE,
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}
```

**(e)** `for_team`（`:73-106`）只改两处：`_row` 的实参与列常量。

```gdscript
			rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
					int(s.get("deaths", 0)), int(s.get("assists", 0)),
					int(s.get("dealt", 0)), int(s.get("taken", 0)),
					int(s.get("acs", 0)), int(role) == mvp_role))
```
```gdscript
		"columns": C_TEAM,
```
★ 其余（按队分两节、`_finish(rows, "acs")`、`pos` 的两段循环、`_verdict_team`）**一字不动**。

- [ ] **Step 4: 改结算页的列标题**

`ui/match_result.gd:25`：

```gdscript
# ★ 键名 = 适配器给的列名(`MatchResultPayload.C_*`),标题才是给人看的。
#   `dmg` 已改名 `dealt`(与数据字段同步);新增的三个与 §3.6 的列一一对应。
const COLUMN_TITLES := {"kills": "击杀", "deaths": "阵亡", "assists": "助攻",
		"dealt": "造成", "taken": "承受", "acs": "ACS"}
```

- [ ] **Step 5: 跑两次 —— `-s` 冒烟转绿；版式探针改夹具后转绿**

**(a)**
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/match_result_payload_smoke.gd 2>&1 | grep -E "MATCH RESULT|★"
```
Expected: `MATCH RESULT PAYLOAD: ALL-OK`。

**(b)** 改 `tests/match_result_probe.gd` 的夹具与列数：

- ② 1v1 那一发（`:79-90`）的载荷换成 `stats` 形状（与 `-s` 冒烟同款），列数断言改成
  **`g.columns == 2 + 5`** 与 **`g.get_child_count() == 7 + 2 * 7`**；
- ③ 3v3 那一发（`:96-100`）的 `dmg` 键改成 `dealt`，列数断言改成
  **`g.columns == 2 + 6`** 与 **`g.get_child_count() == 8 + 2 * 8`**；
- ⑤ 的 `for_team` 夹具（`:199-202`）同样 `dmg` → `dealt`；
- ★ **不新增图**：③ 那一发现在就是 6 列 —— `_shot` 已经会存一张 PNG，
  人眼要读的就是它（列从 4 变 6 之后，`_check_centred` 的"面板必须装得下视口"那条
  （`:278-282`）会**自动**开始守 6 列的宽度）。

```bash
source tests/env.sh && "$GODOT" --path . --quit-after 3600 res://tests/match_result_probe.tscn 2>&1 | grep -E "MATCH RESULT|FAIL"
```
Expected: `MATCH RESULT PROBE: ALL-OK`。
★ **必须真渲染**（不加 `--headless`）：headless 下 `get_image()` 返回 null ⇒ 像素与居中/装得下
三类断言全被静默跳过（探针会在那里响亮地记一条 FAIL，见 `tests/match_result_probe.gd:306-309`）。
★ 若红在 **`★ 面板必须装得下视口`** —— 那是真实的功能缺陷（列跑到屏幕外），本计划范围内修：
把 `ui/match_result.gd:26` 的 `NAME_UNITS` 从 12 降到 10 或把 `_build_section` 的
`h_separation`（24）降到 16；改完重跑并**自己读那张 PNG**（`.superpowers/sdd/` 下不存，
它在 `user://match_result_*.png`）确认五~六列都读得出来。

- [ ] **Step 6: 人眼验收（自己读图，别推回给用户）**

读 `user://match_result_2.png`（3v3 那张，路径见探针的 `OUT` 常量）：**A/B 两节各六列**
（击杀 / 阵亡 / 助攻 / 造成 / 承受 / ACS），MVP 那一行的 `★` 落在正确的人上。

- [ ] **Step 7: 反证（把列常量改回单列，确认冒烟回红）**

临时把 `C_DUEL` 改成 `["kills"]`，跑 Step 5(a) 的命令。
Expected: 红在 **`★ 1v1 的 columns 应为 [kills, deaths, dealt, taken, acs],实得 [kills]`**。
确认后改回来。

- [ ] **Step 8: 提交**

```bash
git add ui/match_result_payload.gd ui/match_result.gd \
        tests/match_result_payload_smoke.gd tests/match_result_probe.gd
git commit -F - <<'EOF'
feat(result): 结算页扩成 K/D/A + 造成 + 承受(+ACS);三模式适配器改读 stats
EOF
```

---

### Task 4: 回归 + 登记

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 回归（本计划碰了三个模式的宿主与结算页，覆盖面要拉满）**

Run:
```bash
source tests/env.sh
for t in stats_delivery_probe team_host_probe team_table_probe team_disconnect_probe \
         match_host_hygiene_probe royale_disconnect_count_probe grenade_player_hit_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
for t in score_rules_smoke team_room_smoke match_result_payload_smoke enemy_logic_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR"
done
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l6_probe.tscn 2>&1 | grep -E "KH L6|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn 2>&1 | grep -E "KH L5|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | grep -E "KH HUD|FAIL"
"$GODOT" --path . --quit-after 3600 res://tests/match_result_probe.tscn 2>&1 | grep -E "MATCH RESULT|FAIL"
```
Expected: 全绿。**四条必须复跑的常驻守卫**，各自守的东西不同：
- `kh_l6_probe` ⑯：结算载荷的**实参顺序**（本计划只改函数体，签名与调用点不该动）；
- `kh_l5_probe` ⑨：**基类不得含子类方法**（`MatchRound` 在它的 `HOST_SRC` 并集里；
  本计划往 `match_round.gd` 加的东西里**不得**出现那 5 个名字）；
- `hud_declarative_probe` ③⑤⑥⑦：`MatchResult` 的挂载/刷新/出路三件事（本计划只动 `COLUMN_TITLES`）；
- `match_result_probe`：版式（**真渲染**，不加 `--headless`）。

- [ ] **Step 2: 登记进 CLAUDE.md**

在 §网络与 PvP 的「3v3 团队模式」那条 `stats` / `mvp` 登记之后补一段（并订正"哪些模式带哪些键"）：

```markdown
- **三模式投递与结算页五列(2026-09-25 补)**：`stats` 键从 3v3 独有扩成**三模式通用**，
  1v1 另加 `mvp`；**大乱斗刻意不带 `mvp`**（spec §3.6/§4 都没要求，加了就是没有读者的键）。
  投递点各自在 `_broadcast_round_state`：1v1 `server/match_round.gd`、大乱斗
  `server/royale_host.gd`、3v3 `server/team_host.gd`（后者本来就挂着）—— 三个函数**互不叠加**
  （另两个都整体覆写它）。★ 两处"改错了不报错"的落点：**1v1 的击杀记给对手且不看归因**
  （口径与它的记分条一致，见 `_match_round_tick` 里那段）、**大乱斗数据包的 `deaths` 从逐人表构造**
  （原先的 `_deaths` 是同一件事的第二份计数）。结算页列 = spec §3.6：
  1v1 `[kills,deaths,dealt,taken,acs]` / 大乱斗 `[kills,deaths,dealt,taken]` /
  3v3 `[kills,deaths,assists,dealt,taken,acs]`，标题在 `ui/match_result.gd::COLUMN_TITLES`
  （`dmg` 已改名 `dealt`）。**三个客户端一行未改**（它们只把整条 `round_state` 交给适配器）。
  守卫：`tests/stats_delivery_probe.tscn`（新）、`tests/match_result_payload_smoke.gd`、
  `tests/match_result_probe.tscn`（真渲染，六列宽度由它已有的"面板必须装得下视口"那条守着）。
```

- [ ] **Step 3: 实机验收（归用户）**

3v3 打完一局 → 结算页应出现 **六列**且 MVP 星落在正确行；**故意炸死一次队友** →
自己那一行的 `kscore`/ACS 应下降（`deaths`/`kills` 不变）。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 登记 stats 三模式投递与结算页五列(含"大乱斗不带 mvp"的取舍)
EOF
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3.6 + §4）：
§4 `stats` 三模式投递 ✅ Task 1（1v1）/ Task 2（大乱斗）/ 3v3 既有；`mvp` ✅ Task 1（1v1）
+ 3v3 既有；"只在非空时带该键" ✅ 两处 `if not table.is_empty():`（源码级断言在探针 ④）；
"加法式、老接收端忽略未知键、不需两端同版本" ✅（不协商、不设开关，Global Constraints 里写明
不做回退读的理由）。
§3.6 `COLUMN_TITLES` 加三键 + `dmg`→`dealt` ✅ Task 3 Step 4；三模式的列 ✅ Task 3 Step 3 的
三个常量；"`match_result_payload.gd` 三条口径原样保留" ✅（`columns` 由数据决定、`_finish` 的
三级排序、`_verdict*` 的平局判定一个字都没动）。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。三处脚注已做过的"别走那条路"提示都写在
注释里（如 `for_duel` 的 MVP：**别按 role 反查行** —— `_row` 不承载 role），代码块本身只有要写的那一版。
探针、适配器、`COLUMN_TITLES` 都是完整可跑的代码，不是骨架。

**3. 类型一致性**：`_row(nm, kills, deaths, assists, dealt, taken, acs, mvp := false)` 的 8 个形参
与三处调用点逐位对应；`C_DUEL`/`C_ROYALE`/`C_TEAM` 的字符串与 `_row` 写的键名、
`MatchResult.COLUMN_TITLES` 的键名**三方逐字一致**（漏一个会让 `_build_section` 的
`COLUMN_TITLES.get(col, col)` 把英文键名画到屏幕上 —— 不报错，只是标题变成 `dealt`）；
`_record_down(victim_role, killer_role)` 与 1v1 的 `_record_down(int(role), _opponent_of(int(role)))`
逐位对应；大乱斗的 `_record_down(int(role), killer)` 里 `killer` 是 `_attributed_killer` 的返回值(int) ✅。

**4. 已知边界（登记不修）**：
- `-s` 冒烟**必须套 `timeout`**（Task 3 Step 2 已写明）：`-s` 没有 `--quit-after` 兜底，
  一次越界就是**永久挂住**，而"挂住"与"真失败"在输出上不可分（都看不到 FAIL 文本）。
  本计划的已知挂住形状只有一处：③ 那条读 `rows[0]` 的旧断言 —— (c2) 的判空守卫已把它堵死。
- 1v1 的 `kills` 与记分条同口径（**无归因**：自杀/溺水也算对手的击杀）—— 这是**决定**，
  不是 spec 明文（spec 没写 1v1 的击杀口径），理由写在 Task 1 Step 4 的注释里。
- 大乱斗不列 ACS（`acs ≡ kscore`）、不列助攻、不带 `mvp`（三条都是 §3.6/§3.3 的推论）。
- 适配器**不做**"老服务端没有 `stats`"的回退读（同一份仓库/同一个 exe 两端一起更新；
  回退读 = 同一件事两个来源）。探针 ⑦ 钉住"缺键时是良构的空榜、不崩"。
- 结算页把 `acs` 当 int 画（`MatchResult._build_section` 的 `str(int(r.get(c, 0)))`
  与适配器的 `int(s.get("acs", 0))`）—— 小数被截断，本次不改。
