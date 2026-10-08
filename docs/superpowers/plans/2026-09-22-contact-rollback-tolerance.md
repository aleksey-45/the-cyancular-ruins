# 接触期自适应容差 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 C2 客户端预测在"与远端玩家贴身"时使用一个更宽的位置容差,从而把贴身缠斗的回滚次数从"贴着阈值跳变"变成稳定低位 —— 且非接触期保持严格。

**Architecture:** 接触与否的判据取自**物理真值**(本地玩家本物理步的滑动碰撞里有没有非地形层),由 `Player.touching_player()` 暴露;`PredictionRollback` 新增 `in_contact` + `contact_pos_tol` 两个字段,`_close_enough` 按 `in_contact` 在两条容差之间选;接线只有一处(`PvpMatchClient._physics_process`)。**服务端与协议无需修改**。

**Tech Stack:** Godot 4.7.1(标准版,非 mono)· GDScript · 本仓自研的 `-s` 冒烟 + `--headless` 场景探针(无单测框架)

**Spec:** `docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md`

## Global Constraints

- 引擎不在 PATH,一律走 `source tests/env.sh` 取 `$GODOT`;不要往脚本里抄绝对路径。
- **判据一律是 grep 文本**(`ALL-OK` / `SMOKE OK`),**不看退出码** —— 探针挂住时 `--quit-after` 到期仍 exit 0 且一行裁决都不打印。
- **`ALL-OK` 只证明"没有任何断言失败",不证明"该跑的断言都跑过"**(权威表述在 `tests/lib/probe_base.gd` 文件头)。**每加一条断言,先证明它会红**(看着报错失败再还原),别拿"加了之后全部通过"当证据。
- 注释用中文,密度与周边一致;本仓注释风格是"写清为什么 + 踩过的坑"。
- **不许**改协议、不许改服务端任何文件、不许改 `player.tscn` 的碰撞层/掩码。
- `player.gd` **不得新增任何 import**(不引 `server/`、不引 `player_replica`)。
- 测试跑法分工:**agent 可跑** = 全部 `-s` 冒烟 + 不占端口的 `--headless` 场景探针;**用户跑** = 一切占 7777 的脚本与真链路探针(`royale_c2_probe` / `reconnect_probe`)。
- commit message 用 `type(scope): 中文描述`,与仓库现有风格一致。

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `core/net/prediction_rollback.gd` | 改 | 载体:两个新字段 + `_close_enough` 选容差 |
| `scenes/player/player.gd` | 改 | 接触判据 `touching_player()`(只读函数,无状态) |
| `scenes/pvp_match_client.gd` | 改 | **唯一**接线点(三个客户端共用这个 `_physics_process`) |
| `tests/rollback_fidelity_probe.gd` | 改 | 容差逻辑的双向行为断言 + 接线源码守卫 |
| `tests/replica_ghost_probe.gd` | 改 | 接触判据的双向行为断言(在位命中 / 摘除不命中) |
| `tests/brawl_rollback_probe.gd` | 改 | CONTACT 族扫描 + 三条判据 |

---

### Task 1: `PredictionRollback` 的接触期容差

**Files:**
- Modify: `core/net/prediction_rollback.gd:53-54`(常量与 `pos_tol` 之后)与 `_close_enough`(约 161 行)
- Test: `tests/rollback_fidelity_probe.gd`

**Interfaces:**
- Consumes: 无(本任务是最底层)
- Produces: `PredictionRollback.contact_pos_tol: float`(= `DEFAULT_CONTACT_POS_TOL`,初值 2.0)、`PredictionRollback.in_contact: bool`(默认 `false`)

- [ ] **Step 1: 写失败的测试**

在 `tests/rollback_fidelity_probe.gd` 的 `_test_torus_compare()` **之后**追加夹具与测试(放在 `_check_source_guard()` 定义之前):

```gdscript
# ── C 组:接触期容差(贴身时用 contact_pos_tol,非接触期保持 pos_tol)──
# 手法与 A 组同款:直接摆 _captures + on_authoritative + reconcile,不依赖真实物理世界。
# 造一个已跑到 20 帧的控制器 + 它绑的玩家,并把 seq14 那份 capture 的 pos 挪 10px 当"权威"。
func _make_contact_fixture() -> Dictionary:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_HEIGHT * 0.5)
	var c := PredictionRollback.new()
	c.bind(p)
	c.pos_tol = 2.0
	c.contact_pos_tol = 24.0   # 测试用值,与生产常量**解耦**(常量日后改了这条断言不该跟着漂)
	c.map_px = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"weapon": 0, "aim": Vector2(1.0, 0.0)})
	# 权威态 = 该帧 capture 平移 10px(> pos_tol 2px,< contact_pos_tol 24px)
	var s: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s["pos"] = (s["pos"] as Vector2) + Vector2(10.0, 0.0)
	return {"ctrl": c, "player": p, "state": s}


func _test_contact_tolerance() -> void:
	# ① 非接触期:10px > pos_tol(2px)⇒ 真分歧 ⇒ 必须回滚
	var f1: Dictionary = _make_contact_fixture()
	var c1: PredictionRollback = f1["ctrl"]
	c1.in_contact = false
	var rb0 := c1.rollback_count()
	c1.on_authoritative(14, f1["state"])
	c1.reconcile()
	_check(c1.rollback_count() == rb0 + 1,
			"③ 非接触期 10px 偏差判为分歧(回滚 ×%d→×%d)" % [rb0, c1.rollback_count()])
	(f1["player"] as Node).queue_free()

	# ② 接触期:**同一份形状的载荷**、只把 in_contact 翻成 true ⇒ 必须**不**回滚
	#    ★ 两份夹具各自独立(不复用控制器):①的回滚会重放并改写 capture,复用会让 ② 比到别的东西。
	var f2: Dictionary = _make_contact_fixture()
	var c2: PredictionRollback = f2["ctrl"]
	c2.in_contact = true
	var rb1 := c2.rollback_count()
	c2.on_authoritative(14, f2["state"])
	c2.reconcile()
	_check(c2.rollback_count() == rb1,
			"④ 贴身时同一份载荷不再判分歧(回滚 ×%d→×%d,容差 2→24px)" % [rb1, c2.rollback_count()])
	(f2["player"] as Node).queue_free()

	_ran["contact_tol"] = true   # ★ 完成戳必须在最后一行:中途报错就到不了这里(见文件头说明)
```

在 `_ready()` 里 `_test_torus_compare()` 那一行之后插入两行:

```gdscript
	_test_contact_tolerance()
	_require_ran("contact_tol")
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: 打印 `ROLLBACK FIDELITY PROBE: FAIL`,并有一行 `✗ _test_contact_tolerance 没跑到最后一行...` 或 `Invalid assignment of property 'in_contact'`(字段尚不存在 ⇒ 函数中途报错 ⇒ 完成戳没盖上)。

★ 这一步的"红"必须**亲眼看到**。若它反而打印 `ALL-OK`,说明完成戳没生效,先修探针再往下。

- [ ] **Step 3: 写最小实现**

`core/net/prediction_rollback.gd` —— 在 `var pos_tol: float = DEFAULT_POS_TOL`(约 54 行)之后插入:

```gdscript
# 接触期(与远端玩家**身体**贴身)的位置容差。★ 凭什么能放宽:贴身时那点位置分歧由**接触几何**
# 决定,而回滚纠正不动它 —— 实测(见 tests/brawl_rollback_probe)1/2/4/8px 四档的接触期偏差
# **逐项相同**(中位 1.6 / p95 25~30),即那每帧一次的回滚"本来就没买到精度"。
# ★ 取值先与 pos_tol 同值(2.0)落地 —— 此时行为与改动前**逐字相同**;扫描出结论后只改这一行。
#   取值依据见 docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md §3.4。
const DEFAULT_CONTACT_POS_TOL := 2.0
var contact_pos_tol: float = DEFAULT_CONTACT_POS_TOL

# 接入方每物理步写一次:本帧是否正在贴身(`Player.touching_player()`)。
# ★ 默认 false = 改动前的行为。★ 它**不进 capture_state()/restore_state()**、不上行 ——
#   纯客户端本地量(它只是"这次的偏差要不要较真"的提示,不是模拟状态)。
var in_contact: bool = false
```

`_close_enough` 里把位置那一条(约 161 行)改成:

```gdscript
	# 容差按**接触与否**二选一:非接触期的位置分歧是真的(要立刻纠正),
	# 接触期的位置分歧是接触几何噪声(实测纠正不动,见 contact_pos_tol 的说明)。
	var tol: float = contact_pos_tol if in_contact else pos_tol
	if _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) > tol:
		return false
```

- [ ] **Step 4: 跑测试确认它通过**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: 末行 `ROLLBACK FIDELITY PROBE: ALL-OK`,且能看到 `✓ ③ 非接触期 10px 偏差判为分歧` 与 `✓ ④ 贴身时同一份载荷不再判分歧`。

- [ ] **Step 5: 变异验证(证明这两条断言真的会红)**

把 `_close_enough` 里那行临时改成恒用 `pos_tol`:

```gdscript
	var tol: float = pos_tol
```

Run: 同 Step 4 的命令
Expected: `ROLLBACK FIDELITY PROBE: FAIL`,且**只有 ④ 红**(③ 应当仍是 ✓ —— 因为它本来就期望回滚)。
**然后还原**成 `contact_pos_tol if in_contact else pos_tol` 并重跑确认 `ALL-OK`。

- [ ] **Step 6: 提交**

```bash
git add core/net/prediction_rollback.gd tests/rollback_fidelity_probe.gd
git commit -m "feat(net): PredictionRollback 加接触期容差字段(默认与 pos_tol 同值,行为不变)"
```

---

### Task 2: `Player.touching_player()` 接触判据

**Files:**
- Modify: `scenes/player/player.gd`(放在 `is_charging()` 之后,约 476 行)
- Test: `tests/replica_ghost_probe.gd`

**Interfaces:**
- Consumes: 无
- Produces: `Player.touching_player() -> bool`(只读,**无状态** —— 每次调用现扫当前滑动碰撞)

- [ ] **Step 1: 写失败的测试**

`tests/replica_ghost_probe.gd` 三处改动:

(a) 单趟状态区(`var _ghost_on := true` 附近)加一个成员:

```gdscript
var _touched_any := false   # 本趟里 P.touching_player() 命中过没有(判据不是空转的证据)
```

(b) `_run_pass()` 开头的重置区(紧挨 `_max_px = -INF`)加一行:

```gdscript
	_touched_any = false
```

(c) `_physics_process` 里,在 `_max_px = maxf(_max_px, pp.x)` 那一行**之后**、`_tick += 1` **之前**插入:

```gdscript
	# 接触判据读数(生产里由 PvpMatchClient 在玩家步进前读一次,见 pvp_match_client.gd)
	if P.touching_player():
		_touched_any = true
```

(d) `_run_pass()` 的断言区 —— 在 `if ghost_on:` 分支末尾(`②` 那条 `_check` 之后)加:

```gdscript
		# ⑤ 判据确实命中过(本趟 P 全程顶在幽灵体上)⇒ 证明它不是在空转
		_check(_touched_any, "⑤ 幽灵体在位时 touching_player() 命中过")
```

在 `else:` 分支末尾(`④` 之后)加:

```gdscript
		# ⑥ 负向对照:幽灵体被摘除(层置 0)后**全程不得命中**。
		#    ★ 这条同时钉住"地形不算接触":P 全程踩在地板上(层 1),判据若写成
		#      `collision_layer != 0`(忘了 `& ~1`)会**恒真**,这里当场红。
		_check(not _touched_any, "⑥ 摘掉幽灵体后 touching_player() 全程为假(地形层不算接触)")
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/replica_ghost_probe.tscn`
Expected: 打印 `REPLICA GHOST PROBE: FAIL`,并列出 `✗ ⑤ ...`(函数不存在 ⇒ 中途报错 ⇒ ⑤ 一条都没跑到 ⇒ 完成戳缺失)。

★ 若它反而 `ALL-OK`,说明 `_ran` 完成戳没起作用 —— 先查探针,别往下走。

- [ ] **Step 3: 写最小实现**

`scenes/player/player.gd`,在 `is_charging()` 之后插入:

```gdscript
# 本物理步的滑动碰撞里有没有"非地形"的碰撞体(= 远端玩家身体所在的层)。
# ★ 用途:C2 客户端预测把「是否正在贴身」喂给 PredictionRollback,让它只在贴身时放宽容差
#   (见 docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md)。
# ★ 判**层**不判组名/节点名:判 `player_replica` 组要在本文件写字面量,而 player_replica.gd 在
#   `_ready` 里 preload 了 player.tscn ⇒ 两边互相引用成环;判 `TeamHost.TEAM_ENEMY_LAYER` 又会把
#   `server/` 拖进核心玩家类。层判据零字符串耦合,且同时覆盖 1v1/大乱斗(层 2)与 3v3 敌方(层 16)。
# ★ 地形恒为层 1 ⇒ `& ~1` 就是"非地形"。本地玩家的 mask 里除地形外只有对手幽灵体;
#   3v3 队友的幽灵体在层 2、而本地 mask 不含 2 ⇒ 根本不产生滑动碰撞 ⇒ 队友不算接触(与"队友不互挡"一致)。
# ★ 写成**函数**而不是每帧刷新的字段:本文件 move_and_slide() 有 3 个调用点
#   (_physics_process / _tick_downed / restore_state),做字段必然漏刷一处,而漏了**不报错**。
func touching_player() -> bool:
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		if col == null:
			continue
		var co := col.get_collider() as CollisionObject2D
		if co != null and (co.collision_layer & ~1) != 0:
			return true
	return false
```

- [ ] **Step 4: 跑测试确认它通过**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/replica_ghost_probe.tscn`
Expected: 末行 `REPLICA GHOST PROBE: ALL-OK`,并能看到 `✓ ⑤` 与 `✓ ⑥`。

- [ ] **Step 5: 变异验证(两条断言各红一次)**

变异 A:把判据改成 `if co != null:`(即忘了 `& ~1`)
Run: 同 Step 4
Expected: `REPLICA GHOST PROBE: FAIL`,**⑥ 红**(地形被当成接触),⑤ 仍 ✓。

变异 B:把 `func touching_player() -> bool:` 的首行改成 `return false`
Run: 同 Step 4
Expected: `REPLICA GHOST PROBE: FAIL`,**⑤ 红**,⑥ 仍 ✓。

**两次都还原**,重跑确认 `ALL-OK`。

- [ ] **Step 6: 提交**

```bash
git add scenes/player/player.gd tests/replica_ghost_probe.gd
git commit -m "feat(player): touching_player() 接触判据(滑撞里有没有非地形层)"
```

---

### Task 3: 基类接线(唯一一处)

**Files:**
- Modify: `scenes/pvp_match_client.gd:188-191`
- Test: `tests/rollback_fidelity_probe.gd`(`_check_source_guard()`)

**Interfaces:**
- Consumes: Task 1 的 `_rollback.in_contact`;Task 2 的 `_local.touching_player()`
- Produces: 无(终点)

- [ ] **Step 1: 写失败的测试**

在 `tests/rollback_fidelity_probe.gd` 的 `_check_source_guard()` 末尾(`pvp_client 给控制器设了 map_px` 那条 `_check` 之后)追加:

```gdscript
	# ② 接触提示的接线(`in_contact` 必须在 reconcile() 之前写)。
	#    漏了这一行 = 静默退回 2px 容差:不报错、探针全绿、真机行为与改动前逐帧一致。
	#    ★ 日后若换了入口,请把这里改成认新入口,**别删掉这条断言**。
	var txt2 := FileAccess.get_file_as_string("res://scenes/pvp_match_client.gd")
	var lines := txt2.split("\n")
	var hint_line := -1
	var note_line := -1
	var hint_count := 0
	for i in range(lines.size()):
		var line := lines[i]
		if line.strip_edges().begins_with("#"):
			continue
		if line.contains("_rollback.in_contact =") and line.contains("touching_player()"):
			hint_count += 1
			hint_line = i
		if line.contains(".note_post_step(") and note_line < 0:
			note_line = i
	_check(hint_count == 1,
			"接触提示只许有**一处**赋值(实得 %d 处 —— 0 = 漏接线,>1 = 有两处在抢)" % hint_count)
	_check(hint_line >= 0 and note_line >= 0 and hint_line < note_line,
			"接触提示的赋值排在 note_post_step/reconcile 之前(hint@%d, note@%d)" % [hint_line, note_line])
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: `ROLLBACK FIDELITY PROBE: FAIL`,两条新断言都红(实得 0 处、hint@-1)。

- [ ] **Step 3: 写最小实现**

`scenes/pvp_match_client.gd`,把 188-191 行改成:

```gdscript
	if _rollback != null:
		if _have_prev_seq:
			# 贴身提示:只在**接触期**放宽容差(见 core/prediction_rollback.gd 的 contact_pos_tol)。
			# ★ 必须在 reconcile() 之前 —— 它是消费方。★ 漏了这一行 = **静默**退回 2px 容差,
			#   故 rollback_fidelity_probe 有一条源码守卫钉住它的位置与唯一性。
			_rollback.in_contact = _local.touching_player()
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
```

★ `_local` 声明为 `Node2D` 而 `touching_player()` 是 Player 的方法 —— 这与同文件 194 行的
`_local.get_current_aim_dir()` **是同一种调用形状**(那行本来就在跑),故可编译。

- [ ] **Step 4: 跑测试确认它通过**

Run: `source tests/env.sh && "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: 末行 `ROLLBACK FIDELITY PROBE: ALL-OK`。

★ 同时做一次脚本加载自检 —— `rollback_fidelity_probe` **不加载** `pvp_match_client.gd`，
所以它抓不到那个文件的解析错:

```bash
source tests/env.sh && "$GODOT" --headless --path . res://scenes/pvp_game.tscn --quit-after 120 2>&1 \
    | grep -i "parse error\|script error" || echo "无脚本错"
```
Expected: **不得**出现含 `pvp_match_client` 的 `Parse Error` / `SCRIPT ERROR`。
★ 其它报错（世界建不起来、`PvpSession` 没状态）是 headless 裸跑对局场景的正常现象，**不算红** ——
判据只认"指向我们改的那个文件的解析错"。

- [ ] **Step 5: 变异验证**

把 `_rollback.in_contact = _local.touching_player()` 这一行**注释掉**。
Run: 同 Step 4
Expected: `ROLLBACK FIDELITY PROBE: FAIL`,那条 `接触提示只许有一处赋值(实得 0 处)` 红。
**还原**并重跑确认 `ALL-OK`。

- [ ] **Step 6: 提交**

```bash
git add scenes/pvp_match_client.gd tests/rollback_fidelity_probe.gd
git commit -m "feat(net): 三个客户端共用一处接触提示接线 + 源码守卫钉位置与唯一性"
```

---

### Task 4: 探针 CONTACT 族 + 扫描

**Files:**
- Modify: `tests/brawl_rollback_probe.gd`

**Interfaces:**
- Consumes: Task 1 的 `contact_pos_tol` / `in_contact`;Task 2 的 `touching_player()`
- Produces: 三档 CONTACT 的读数(供 Task 5 定值)

- [ ] **Step 1: 加 CONTACT 族(改探针,不改生产)**

五处改动:

(a) 枚举与两张平行表(约 55-66 行):

```gdscript
enum Variant { NONE, STATIC, PROD, TOL2, TOL4, TOL8, EXTRAP, CONTACT8, CONTACT16, CONTACT32 }

const VARIANT_NAME := ["幽灵体摘除(对照)", "对手站着不动(健全性对照)",
		"容差 1px(历史基线)", "容差 2px(已采纳)", "容差 4px", "容差 8px", "幽灵体外推(已证伪)",
		"接触期 8px", "接触期 16px", "接触期 32px"]

const VARIANT_TOL := [1.0, 1.0, 1.0, 2.0, 4.0, 8.0, 1.0, 2.0, 2.0, 2.0]

# 三档 CONTACT 的**接触期**容差(与 Variant.CONTACT8..CONTACT32 同序)。
# ★ pos_tol 对它们恒为 2.0 —— 本族要验的是"非接触期保持严格、接触期放宽"。
const CONTACT_TOLS := [8.0, 16.0, 32.0]

static func _is_contact_variant(v: int) -> bool:
	return v >= int(Variant.CONTACT8)
```

(b) 单趟状态区(`var _max_dev := 0.0` 附近)加:

```gdscript
var _hint_ticks := 0    # 本趟里接触提示命中的 tick 数(恒 0 = 本档等同 2px 档 = 空转)
```

(c) `_run_pass()` 的重置区(紧挨 `_max_dev = 0.0`)加:

```gdscript
	_hint_ticks = 0
```

并在 `ctrl.pos_tol = VARIANT_TOL[variant]` 之后加:

```gdscript
	# CONTACT 族:接触期容差显式给(与 pos_tol 一样是"显式写死才可比"的道理)。
	# ★ 写成 if/else 而不是三元:三元在 GDScript 里两支都要求值,`CONTACT_TOLS[variant - 7]`
	#   对非 CONTACT 档会算出负下标 —— 那种错报在探针启动时,看着像探针坏了。
	if _is_contact_variant(variant):
		ctrl.contact_pos_tol = CONTACT_TOLS[variant - int(Variant.CONTACT8)]
	else:
		ctrl.contact_pos_tol = VARIANT_TOL[variant]
```

(d) `_physics_process` 里,在 `ctrl.advance(recA)` **之前**插入:

```gdscript
	# ★ 接触提示按**生产同款**喂:读 P 上一次步进留下的滑动碰撞(生产里是基类在玩家步进前读
	#   `_local.touching_player()`)。★ 别用本探针那个 `|o.x - A.x| < 90` 的几何代理 ——
	#   那量的是"权威侧在不在接触",与生产喂进去的不是同一个量。
	if _is_contact_variant(_variant):
		ctrl.in_contact = P.touching_player()
		if ctrl.in_contact:
			_hint_ticks += 1
```

(e) `_run_pass()` 的断言区,在"处于贴身状态"那条 `_check` 之后追加:

```gdscript
	# CONTACT 族的三条判据(缺一条本改动就可能是空转 —— 见 spec §3.4)
	if _is_contact_variant(variant):
		_check(_hint_ticks > 0,
				"N=%d %s 接触提示确实命中过(命中 %d tick / 几何接触 %d tick);恒 0 = 本档等同 2px 档"
				% [n, VARIANT_NAME[variant], _hint_ticks, _contact_ticks])
		var med := _pct(_devs, 0.50)
		var p95 := _pct(_devs, 0.95)
		_check(med <= 3.0 and p95 <= 35.0,
				"N=%d %s 放宽后接触期偏差没有变大(中位 %.1f / p95 %.1f;基线 1.6 / 25~30)"
				% [n, VARIANT_NAME[variant], med, p95])
		# ★ bar 是「**严格**优于 2px 档」而不是「不超过它的一半」:GDScript 的 `/` 是**整除**
		#   (`9 / 2 == 4`),而 N=2 在**任何**容差下回滚数都停在 5(那 5 次是容差去不掉的)
		#   ⇒ `5 <= 4` 恒假 ⇒ N=2 接线前红、接线后也红,这条在 N=2 上**没有鉴别力**。
		#   `base > 0` 那半保留:它防的是 `_find` 取不到(返回 -1)。
		var base := _find(Variant.TOL2, n)
		# ★★ 这条判据**只对已采纳的那一档打分**(Variant.CONTACT8);16px/32px 两档照旧**打印
		#   读数**、只是**不判**。为什么:它比的是两个**各自都在抖的离散量** —— 本档的 `rb`
		#   与 2px 档的分母 `base`,而分母自己就会在 13~17 之间跳(与本次改动无关)。
		#   实账:Task 4 §7.4 记着同配置 5 遍假红 1 遍(`N=8 接触期 16px`:回滚 15 < 2px 档 13),
		#   定值 8px 那天又在 32px 档复现同一格(`N=8 接触期 32px`:15 < 13)。已采纳档 CONTACT8
		#   至今一次没红过 ⇒ 能承载这条断言的只有它。
		#   ⚠ 但**不删** 16/32 的读数:本探针是**扫描仪器** —— 日后重调容差要拿这三档比,
		#   读数必须留着(下面 else 照打)。收窄的只是「判据」,不是「仪器」。
		if variant == Variant.CONTACT8:
			_check(base > 0 and rb < base,
					"N=%d %s 确实买到了东西(回滚 %d < 2px 档 %d,严格更少)"
					% [n, VARIANT_NAME[variant], rb, base])
		else:
			print("[brawl]   · N=%d %s 读数:回滚 %d vs 2px 档 %d(未采纳档,只记读数不判)"
					% [n, VARIANT_NAME[variant], rb, base])
```

★ **上面这段是订正后的形态**(2026-09-22 定案):本计划初稿写的是
`_check(base > 0 and rb <= base / 2, "… ≤ 2px 档 %d 的一半")`,**那是错的、且错得没鉴别力** ——
GDScript 的 `/` 是**整除**(`9 / 2 == 4`),而 N=2 在**每一种**容差下的可达下界都是 **5**
⇒ `5 <= 4` 恒假 ⇒ 那条 bar 在 N=2 上**接线前红、接线后也红**,量不出任何东西。
实账见 `.superpowers/sdd/task-4-report.md` §6.1 与 §7。

★ 另有一处(2026-09-23 用户裁定):**这条判据只在「已采纳档」`Variant.CONTACT8` 上打分**,
16px/32px 两档**照旧打印读数、只是不判** —— 它比的是两个各自都在抖的离散量(2px 档的分母自己
在 13~17 之间跳),三档全判会有低频假红(Task 4 §7.4 同配置 5 遍假红 1 遍;定值当天又在 32px 档复现)。
读数**不删**是因为本探针是**扫描仪器**;理由与实账见 spec §3.4「扫描结果」末尾。

(f) `_ready()` 的跑批清单:在现有两个循环**之后**(必须之后 —— 判据要用 `_find(Variant.TOL2, n)`)加:

```gdscript
	# CONTACT 族放最后:上面那条"买到了东西"的判据要读 2px 档的读数(_find),它得先跑完。
	for v in [Variant.CONTACT8, Variant.CONTACT16, Variant.CONTACT32]:
		for n in [2, 4, 8]:
			passes.append([v, n])
```

- [ ] **Step 2: 先红给现状看(这一步是本任务的核心产出)**

先确认探针本身有鉴别力:**把 (d) 加的那两行临时代码改成 `ctrl.in_contact = false`**
(即模拟"生产没接线"),跑:

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 40000 res://tests/brawl_rollback_probe.tscn 2>&1 | tail -30
```

Expected: 三档 CONTACT 的**回滚数与修正量与 `容差 2px(已采纳)` 那一档逐字相同**(N=2 9 / N=4 181 / N=8 13),
且 `接触提示确实命中过` 那条红、`买到了东西` 那条红。
**这条就是"提示没生效 = 静默退回 2px"的可观测证据** —— 先看到它,再还原 (d)。

- [ ] **Step 3: 还原并跑正式扫描**

把 `ctrl.in_contact = false` 还原成 `ctrl.in_contact = P.touching_player()`(连同 `_hint_ticks` 累加),重跑同一条命令。

Expected: 末行 `BRAWL ROLLBACK PROBE: ALL-OK`(三档全部满足三条判据),读数形如:

```
N=2 接触期 8px   回滚×<个位数>   ...  接触期偏差 中位 1.6 p95 <35
N=4 接触期 8px   回滚×<远小于 181> ...
N=8 接触期 8px   ...
```

- [ ] **Step 4: 把读数交用户过目并定值**

把汇总表原样贴给用户,并**按 spec §3.4 的定值规则**提出建议:在满足判据 2 的档位里取最小;
三档全满足则取 **16**(★ **本句已被实测取代,见下**);若没有任何一档满足判据 2(**接触期偏差随容差显著变大**),
**停下来报告,不要硬填一个"看起来能压住次数"的值**。

★ **本节末尾这句"三档全满足则取 **16**"已被实测取代**(2026-09-22 定案):三档**确实**全满足判据 2,
但**频率也全同档**(8px = N2 5 / N4 8 / N8 5;16px 与 32px 在 N=2 也是 5,在 N=4/N=8 上**跨轮次抖动**
—— N=4 约 **8~21**、N=8 约 **4~15**,离散读数、只记大致范围 —— 且无系统性更低)
⇒ 按"满足判据 2 的档里取最小"得到的采纳值是 **8.0**,不是 16。
依据与读数见 `docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md` §3.4
的「扫描结果」。**别照上面那句去填 16。**

- [ ] **Step 5: 提交(探针)**

```bash
git add tests/brawl_rollback_probe.gd
git commit -m "test(net): 贴身回滚探针加 CONTACT 族(接触提示命中率 + 偏差不恶化 + 确实买到东西)"
```

---

### Task 5: 定值 + 采纳守卫 + 回归

**Files:**
- Modify: `core/net/prediction_rollback.gd`(`DEFAULT_CONTACT_POS_TOL`)
- Modify: `tests/brawl_rollback_probe.gd`(采纳守卫)

**Interfaces:**
- Consumes: Task 4 的读数
- Produces: 生效的 `DEFAULT_CONTACT_POS_TOL`

- [ ] **Step 1: 填值**

按 Task 4 Step 4 定下的数,把 `core/net/prediction_rollback.gd` 的

```gdscript
const DEFAULT_CONTACT_POS_TOL := 2.0
```

改成选定值(例:`16.0`),并把**依据写进紧邻的注释**(哪一档、为什么不是更小/更大、
扫描读数区间)。★ 不许只改数字不写依据 —— 下一个读这段的人无从判断它还能不能动。

- [ ] **Step 2: 加采纳守卫(防静默退回 2px)**

`tests/brawl_rollback_probe.gd` 的 `_ready()` 里,紧挨既有的

```gdscript
	var tol: float = PredictionRollback.new().pos_tol
	_check(tol >= 2.0, "控制器默认容差已采纳(要求 >= 2px,实际 %.1f px)" % tol)
```

之后追加:

```gdscript
	# 接触期容差的**采纳值守卫**:退回 2.0 会让贴身频率回到每帧一次,而那是**静默**的
	# (不报错、本探针除这一条外照绿)—— 故把"默认值本身"变成断言。
	var ctol: float = PredictionRollback.new().contact_pos_tol
	_check(ctol >= 8.0, "接触期容差已采纳(要求 >= 8px,实际 %.1f px)" % ctol)
```

- [ ] **Step 3: 跑全套回归(agent 可跑的那部分)**

```bash
source tests/env.sh
"$GODOT" --headless --path . --quit-after 40000 res://tests/brawl_rollback_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/rollback_fidelity_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_ghost_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_smoothness_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/pvp_reconcile_smoke.tscn
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: 逐个 grep 到各自的通过文本(`BRAWL ROLLBACK PROBE: ALL-OK`、
`ROLLBACK FIDELITY PROBE: ALL-OK`、`REPLICA GHOST PROBE: ALL-OK`、`SMOKE_RECONCILE OK`、`SMOKE OK`)。
**逐个看文本,不看退出码。**

★★ **本清单订正过两处(2026-09-22;初稿的两个缺陷让一位实现者白挂 8 小时,别再抄错)**:

1. **`pvp_reconcile_smoke` 是场景探针(`.tscn`)**,初稿写成 `-s res://tests/pvp_reconcile_smoke.gd`
   —— `-s` 下**没有 autoload**,于是
   `SCRIPT ERROR: Compile Error: Identifier not found: GameParameters`,**一条断言都跑不到**。
   正确形式 = `--quit-after 3600 res://tests/pvp_reconcile_smoke.tscn`,判词 `SMOKE_RECONCILE OK`。
2. **三个场景探针初稿没给 `--quit-after` 安全网**,而本仓明令场景探针一律给(统一 **3600** 帧;
   `brawl_rollback_probe` 因为要跑 28 趟而用 40000)。安全网**只在探针挂住时才用得上**,
   放宽不花代价;给少了会在机器负载重时**先耗尽**,表现为"一行 `ALL-OK` 都没有"、看着像功能坏了。

★ 怎么分两种跑法(按脚本首行):`extends SceneTree` → `-s res://tests/<名>.gd`(autoload 不存在);
`extends Node` → `--quit-after <帧数> res://tests/<名>.tscn`。跑新冒烟一律套 `timeout`。

★ 真链路两条(`tests/royale_c2_probe.tscn` / `tests/reconnect_probe.tscn`)**归用户跑**。

- [ ] **Step 4: 提交**

```bash
git add core/net/prediction_rollback.gd tests/brawl_rollback_probe.gd
git commit -m "feat(net): 接触期容差定值 <N>px(依据:<扫描结论>)+ 采纳值守卫"
```

---

### Task 6: 文档

**Files:**
- Modify: `CLAUDE.md`(§网络与 PvP 的 C2 段 + §测试 的探针清单)
- Modify: `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md`(§2.1 末尾那句)
- Modify: `docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md`(§4/§7 落点订正 + 扫描结果)
- Modify: **本计划自身**(`docs/superpowers/plans/2026-09-22-contact-rollback-tolerance.md`)
  —— ★ 本任务在落地过程中订正了**计划里写错的三处**(Task 4 (e) 的 bar、Task 4 Step 4 的"取 16"、
  Task 5 Step 3 的命令清单),故计划文件本身也在本任务的提交范围内(见 Step 4)。

**Interfaces:**
- Consumes: 全部前面的产出
- Produces: 无

- [ ] **Step 1: 订正 09-12 那句"机制不可行"**

把该文件 §2.1 末尾「★ 一条被实测证伪的推断」那段里,"同帧移动刚体对物理不可见"的**判读**改写为:

> ★ **结论不变,但理由换一条**:该方案由「回滚频率**不随幽灵体精度**变化」(摘除 75px / 准确 2px /
> 推歪 77px 都是 ~220 次)**直接排除** —— 把对手身体倒回同代位置最多改精度,不改频率。
> 下面那张判别实验表**降格为历史留档**:它移动的是 *restore 目标* 而不是幽灵体,且当时读数已接近饱和,
> 故它**不构成**"同帧移动的静态刚体对 `move_and_slide` 不可见"的证据。

- [ ] **Step 2: 订正 09-22 spec 的两处落点 + 补扫描结果**

- §4 表里"`_close_enough` 读错档"那一行:落点由 `pvp_reconcile_smoke(-s)` 改为
  `tests/rollback_fidelity_probe.gd`(与 `map_px` 那条同文件同款:都是"漏接线/惰性"类,
  且那里已有完成戳纪律)。
- §7 步骤 1 的"先红给现状看"改写为**变异形态**:"把探针的接触提示改成恒 false,
  CONTACT 档读数必须逐字等于 2px 档"(探针自己显式给 `contact_pos_tol`,与 `VARIANT_TOL` 同款,
  故"红"由变异证明,而不是靠生产常量还没填)。
- §3.4 末尾追加一小节「扫描结果」,把 Task 4 的实测表与选定的值、依据写进去。

- [ ] **Step 3: 更新 CLAUDE.md**

两处:

1. §网络与 PvP 里 `core/net/prediction_rollback.gd` 相关的那段(讲 C2 预测的地方)追加一条:
   接触期自适应容差的机制、判据(`touching_player()` 的层判据)、唯一接线点、
   以及"**贴身回滚次数由容差决定、不由幽灵体精度决定**"这条已实测的结论 + 指向本 spec。
2. §测试 的探针清单里,`brawl_rollback_probe` 那条补一句 CONTACT 族与三条判据;
   `replica_ghost_probe` 那条补 ⑤⑥;`rollback_fidelity_probe` 那条补 C 组与两条源码守卫。

★ CLAUDE.md 的写法约定:不写"N 处"这类会漂的计数(以 grep 为准),引文件用路径+符号名、
**不写行号**。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md docs/superpowers/specs/2026-09-22-contact-rollback-tolerance-design.md docs/superpowers/plans/2026-09-22-contact-rollback-tolerance.md
git commit -m "docs(net): 接触期容差落地记录 + 订正 09-12 那条证据不足的证伪理由"
```

★ 第 4 个路径(**本计划文件自己**)是本任务补上的:初稿只列了三个文档,而本任务同时订正了
计划里写错的地方(File 表里列出的三处)—— 不改它,下一读者拿到的还是一份带错 bar 与错命令的清单。
★ commit message 用 `type(scope): 中文描述`(本仓约定),故写 `docs(net):` 而不是裸 `docs:`。
★ **只 add 这四个文件** —— 不许 `git add -A`/`git add .`:本仓有过并行会话被 `git add -A`
卷走无关改动的先例。

---

## 自查(写完计划后过一遍)

**Spec 覆盖**

| spec 章节 | 落在哪个 Task |
|---|---|
| §3.1 接触判据(函数、判层) | Task 2 |
| §3.2 容差载体(两字段 + `_close_enough`) | Task 1 |
| §3.3 唯一接线点 | Task 3 |
| §3.4 探针扫描 + 三条判据 | Task 4 |
| §4 守卫表(4 行) | Task 1/2/3/4/5 各自的变异步骤 + Task 5 采纳守卫 |
| §6 已知边界 | 无需实现(登记),Task 6 落进 CLAUDE.md |
| §7 落地顺序 | 6 个 Task 的顺序即是 |
| §8 文档订正 | Task 6 Step 1 |

**与 spec 的两处刻意偏差(已在 Task 6 里回写 spec)**

1. 容差逻辑的行为断言落在 `rollback_fidelity_probe`(而非 spec 原写的 `pvp_reconcile_smoke`):
   同文件已有 `map_px` 的"漏接线"守卫与完成戳纪律,放一起比新开一处好。
2. "先红给现状看"的形态:probe 显式给 `contact_pos_tol`(与 `VARIANT_TOL` 同款),
   故"红"由**变异**证明(提示恒 false ⇒ 读数逐字退回 2px 档),而不是靠生产常量尚未填。

**占位符扫描**:无 TBD/TODO;唯一一个"待定值"是 `DEFAULT_CONTACT_POS_TOL`,
它由 Task 4 的实测经 spec §3.4 的**成文规则**决定,并含"没有一档满足就停下来报告"的出口。

**命名一致性**:`touching_player()` / `in_contact` / `contact_pos_tol` /
`DEFAULT_CONTACT_POS_TOL` / `CONTACT_TOLS` / `_hint_ticks` —— 六个名字在六个 Task 里逐字一致。
