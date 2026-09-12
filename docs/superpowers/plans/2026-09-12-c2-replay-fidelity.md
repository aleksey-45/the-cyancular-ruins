# C2 回放保真（实施计划 · 批次 1）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 C2 回滚重放「同一时代」—— 重放某一步时，对手身体回到那一步当时的位置；顺带修掉跨接缝的假分歧与倒地幽灵体旋转。

**Architecture:** `PredictionRollback` 增加一对「世界状态」钩子（`capture_world`/`restore_world` 由接入方实现，控制器只存按 seq 索引的世界快照），重放循环里逐步倒回。接入方（PvP 客户端）就是那个持有副本的场景，传 `self`。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）、GDScript。测试是 `tests/*.tscn` 场景模式探针（无单测框架），判据一律 grep 末行标记文本。

---

## ★ 执行结果（2026-09-12 收尾时回写）

| 任务 | 状态 |
|---|---|
| Task 1 环面 `_close_enough` | ✅ 落地（`adc3a67`） |
| Task 2 **世界状态钩子 + 重放倒回** | ❌ **前提被实测证伪，改动已撤销、未提交** —— 见下 |
| Task 3 客户端接线 + 探针改造 | ✅ 落地（`9b51555`），内容按实测重定：接 `map_px` + 源码守卫 + 用缠斗探针**否掉「外推」** |
| Task 4 倒地幽灵体旋转 | ✅ 落地（`5357d39`） |

**Task 2 为什么废掉**：`move_and_slide()` 在同一帧内看不到静态刚体的位移（物理空间要等下一个
物理步），而整个回滚重放跑在**一个** `_physics_process` 里。
判别实验：把 restore 目标整体 **+5000px** → 回滚数一字不变；把幽灵体**冻在固定位置**（跨帧生效）
→ 179→225。**机制不可行，不是接线问题。**

**本批真正的杠杆是 `pos_tol`（位置容差）**：1px → 2px 把频率砍 ~95% 而接触期偏差一行不变。
读数与推导见 `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §2.1 / §4.4b。

**另外两条纪律，写在这里免得下一个人重踩**：
1. **探针的模拟必须每帧一步**（在 `_physics_process` 里）。把整段模拟塞进一帧，幽灵体一次都动不了
   —— `rollback_fidelity_probe` 的 B 组就是这么废掉的（PROD 与 EXTRAP 读数一字不差）。
2. **探针的 `_ready` 必须有完成戳防线**。Godot 的运行时错误只中断当前函数，调用它的 `_ready()`
   照常往下走 → 一条 `_check` 都没跑到却照样打印 ALL-OK（本批实测踩到，见 `91b9210`）。

---

## Global Constraints

- Godot 不在 PATH：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **测试由用户自己跑为主**（`CLAUDE.md`）。本计划里的探针除特别说明外都由用户跑；**本计划作者代跑的是 §2.1 那两个已落档的测量探针**。
- 探针两种跑法按首行区分：`extends SceneTree` → `-s res://tests/<名>.gd`；`extends Node` → `--quit-after <帧数> res://tests/<名>.tscn`。
- **判据必须是 grep 标记文本**，不能只看退出码（`--quit-after` 在中途报错时仍 exit 0 且不打印标记）。
- `-s` 阶段 autoload 未实例化 → 凡引用 `GameParameters`/`Settings` 等 autoload 的探针必须是**场景模式**。
- 改完 GDScript 只需重导出，**不要重编模板**（`RELEASE.md` §2.4）。
- 本仓已被抓过四次「验收门假绿」：**每条新断言都必须给出反证并实跑**，反证做不到就说做不到。

## 依据

- 设计：`docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §2.1（实测）、§4.4、§4.4b、§7
- 实测数字出处：`tests/brawl_rollback_probe.tscn`（本计划 Task 3 会把它改造成本批的守卫）

**要修的到底是什么**（一句话，供每个任务的实现者对齐）：`PredictionRollback._handle_ack` 回滚时 `restore_state(S)` 后重放输入，但**对手的幽灵体没有被倒回** —— 它们停在**当前**位置，而当初那次预测用的是**更早**的对手位置。重放算出的碰撞因此与原始预测对不上 → `_captures[s]` 被写成「错误时代」的状态 → 下一个 ack 再不符 → **级联回滚**。实测：对手静止时回滚**恰好 0**，对手一动就 ~35 次/秒。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `core/prediction_rollback.gd` | C2 控制器。新增：`map_px`、`_worlds` 环、`capture/restore world` 调用点 | Modify |
| `scenes/player/player_replica.gd` | 远端副本。修：倒地时幽灵体跟着转 90° | Modify |
| `scenes/pvp_client.gd` | 1v1 客户端。实现 `capture_world`/`restore_world` 并 `bind(_local, self)` | Modify |
| `tests/rollback_fidelity_probe.gd` + `.tscn` | **新建**。A 组：环面比较；B 组：重放保真（最小双 sim） | Create |
| `tests/brawl_rollback_probe.gd` | 改造：变体换成 STATIC/NONE/PROD/WORLD（原 L1/L3 变体作废） | Modify |
| `tests/replica_ghost_probe.gd` | 加一条：倒地快照下幽灵体旋转必须为 0 | Modify |

`royale_game.gd` **不在本批**：它还没有 rollback 控制器（那属迁移批次 5）。它接 C2 时调用同一对方法。

---

### Task 1: 环面感知的分歧判定

**Files:**
- Modify: `core/prediction_rollback.gd`（顶部字段区 + `_close_enough`）
- Create: `tests/rollback_fidelity_probe.gd`、`tests/rollback_fidelity_probe.tscn`

**Interfaces:**
- Consumes: 无
- Produces: `PredictionRollback.map_px: Vector2`（默认 `Vector2.ZERO` = 退回裸距离比较，保持既有行为与 `-s` 可测）

- [ ] **Step 1: 写失败的探针**

新建 `tests/rollback_fidelity_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/rollback_fidelity_probe.gd" id="1"]

[node name="RollbackFidelityProbe" type="Node"]
script = ExtResource("1")
```

新建 `tests/rollback_fidelity_probe.gd`：

```gdscript
extends Node

# C2 回放保真探针(场景模式:要真 Player,故 autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn
# 期望:末行 "ROLLBACK FIDELITY PROBE: ALL-OK"。判据 grep 该文本,不只看退出码。
#
# A 组 · 环面比较:`_close_enough` 原先比 pos 用裸 distance_to。环面上客户端与服务器在
#   跨接缝那一帧可能相差**一整幅地图宽**(其实同一个物理点)→ 误判分歧、白跑一次回滚。
# B 组 · 重放保真:回滚重放时对手身体没被倒回 → 重放与原始预测对不上 → 级联回滚。
#   这两条是本批的全部内容,故断言都钉在这里。

const DT := 1.0 / 60.0
const MARKER := "ROLLBACK FIDELITY PROBE: ALL-OK"

var _failures: Array[String] = []

func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[fid]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[fid]   ✗ %s" % msg)


func _ready() -> void:
	_test_torus_compare()
	if _failures.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("ROLLBACK FIDELITY PROBE: FAIL")
		for f in _failures:
			print("[fid]   ✗ %s" % f)
		get_tree().quit(1)


# ── A 组:环面上「差一整幅地图宽」= 同一个物理点,不该判分歧 ──
func _test_torus_compare() -> void:
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var p: Node2D = preload("res://scenes/player/Player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(w * 0.5, h * 0.5)

	var c := PredictionRollback.new()
	c.bind(p)
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"weapon": 0, "aim": Vector2(1.0, 0.0)})

	# 取两个真实 capture,把它们的位置平移**整整一幅地图宽** —— 环面上仍是同一个物理点
	var s14: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s14["pos"] = (s14["pos"] as Vector2) + Vector2(float(w), 0.0)
	var s15: Dictionary = (c._captures[15] as Dictionary).duplicate()
	s15["pos"] = (s15["pos"] as Vector2) + Vector2(float(w), 0.0)

	# ① 设了 map_px → 判为「预测被证实」,不回滚
	c.map_px = Vector2(float(w), float(h))
	var rb0 := c.rollback_count()
	c.on_authoritative(14, s14)
	c.reconcile()
	_check(c.rollback_count() == rb0,
			"① 环面同一物理点(差一整幅地图宽)不判分歧(回滚 ×%d→×%d)" % [rb0, c.rollback_count()])

	# ② 反证:map_px 归零 → 同一份形状的载荷必须判成分歧(证明 ① 不是空转断言)
	c.map_px = Vector2.ZERO
	var rb1 := c.rollback_count()
	c.on_authoritative(15, s15)
	c.reconcile()
	_check(c.rollback_count() == rb1 + 1,
			"② 去掉环面处理后同一份载荷判为分歧(回滚 ×%d→×%d)" % [rb1, c.rollback_count()])

	p.queue_free()
```

- [ ] **Step 2: 跑探针确认它失败**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: `[fid]   ✗ ① …`，末行 `ROLLBACK FIDELITY PROBE: FAIL`（`map_px` 还不存在 → 更可能是脚本解析报错 `Invalid access to property 'map_px'`；两种都算「失败」）

- [ ] **Step 3: 实现**

在 `core/prediction_rollback.gd` 的字段区（`var _pending: Array = []` 一行之后）加：

```gdscript
# 环面地图尺寸(像素)。ZERO = 不做环面处理(退回裸距离比较)。
# 刻意不引 autoload(与 core/ 其它纯逻辑件同例):由接入方显式设,`-s` 下也能空跑。
var map_px: Vector2 = Vector2.ZERO
```

把 `_close_enough` 里比 `pos` 的两行：

```gdscript
	var pa: Vector2 = a.get("pos", Vector2.ZERO)
	var pb: Vector2 = b.get("pos", Vector2.ZERO)
	if pa.distance_to(pb) > 1.0:
		return false
```

改为：

```gdscript
	if _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) > 1.0:
		return false
```

并在 `_close_enough` 之后新增：

```gdscript
# 两个位置在**环面**上是否几乎同位。裸 distance_to 在跨接缝那一帧会给出「一整幅地图宽」的
# 假分歧(客户端已取模、服务器还没,或反之)—— 那其实同一个物理点,却会白跑一次回滚。
func _pos_dist(a: Vector2, b: Vector2) -> float:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return a.distance_to(b)
	return MazeGenerator.toroidal_delta_px(a, b, map_px.x, map_px.y).length()
```

- [ ] **Step 4: 跑探针确认通过**

Run: 同 Step 2 的命令
Expected: 两个 `✓`，末行 `ROLLBACK FIDELITY PROBE: ALL-OK`

- [ ] **Step 5: 提交**

```bash
git add core/prediction_rollback.gd tests/rollback_fidelity_probe.gd tests/rollback_fidelity_probe.tscn
git commit -m "fix(c2): 分歧判定走环面最短向量,跨接缝不再误判回滚"
```

---

### ~~Task 2: 世界状态钩子 + 重放倒回~~（❌ 已证伪，勿实现）

> **本节作废。** 见文首「执行结果」。下面的步骤保留只为留档「当时假设的是什么」，
> **不要再照它实现** —— 机制在 Godot 的帧结构下不成立（同帧移动刚体对 `move_and_slide` 不可见）。

#### 原计划（作废）

**Files:**
- Modify: `core/prediction_rollback.gd`（`bind`、`advance`、`note_post_step`、`_handle_ack`、`_trim`）
- Modify: `tests/rollback_fidelity_probe.gd`（加 B 组）

**Interfaces:**
- Consumes: Task 1 的 `map_px`
- Produces:
  - `PredictionRollback.bind(p, world = null) -> void` —— `world` 是**鸭子类型**对象，需实现 `capture_world() -> Dictionary` 与 `restore_world(d: Dictionary) -> void`。不传 = 行为与今天完全一致（既有 `bind(p)` 调用点零改动）。
  - 世界快照的约定形状：`{ role:int -> 幽灵体 global_position: Vector2 }`。

- [ ] **Step 1: 写失败的探针（B 组）**

在 `tests/rollback_fidelity_probe.gd` 顶部补常量与字段：

```gdscript
const B_COLS := 200
const B_ROWS := 12
const B_TILE := 64
const B_DELAY := 8          # 权威整态投递延迟(tick),与 pvp_reconcile_smoke 同款
const B_RUN := 300          # 每趟 tick 数(5s)
const B_LAYER_AUTH := 32    # 权威侧层
const B_LAYER_GHOST := 2    # 客户端侧 P 认的层(幽灵体在这层)

var _b_host: Node2D = null
var _b_ghost_pos: Dictionary = {}   # role -> 幽灵体世界位置(本探针当"世界状态"提供者)
var _b_ghosts: Dictionary = {}      # role -> GhostBody
var _b_noop := false                # 反证用:钩子接上但 restore_world 空转
```

再给本探针补一个与 `replica_ghost_probe` 同款的 `_fail`（`_brawl_pass` 里要用）：

```gdscript
func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[fid]   ✗ %s" % msg)
```

`_ready` 改为：

```gdscript
func _ready() -> void:
	Engine.max_fps = 60   # 让 idle 与物理 1:1(副本插值时钟按 idle 推进)
	_test_torus_compare()
	await _test_replay_fidelity()
	if _failures.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("ROLLBACK FIDELITY PROBE: FAIL")
		for f in _failures:
			print("[fid]   ✗ %s" % f)
		get_tree().quit(1)
```

新增 B 组（本探针自己当世界状态提供者，鸭子类型，不新增 class）：

```gdscript
# ── 本探针兼任「世界状态提供者」(与 PvP 客户端要实现的同一对方法)──
func capture_world() -> Dictionary:
	return _b_ghost_pos.duplicate()

func restore_world(w: Dictionary) -> void:
	for role in w:
		var g = _b_ghosts.get(role)
		if g != null and is_instance_valid(g):
			(g as Node2D).global_position = w[role]


# ── B 组:重放保真 ──
# 搭最小双 sim:权威侧 A + 一具**会动**的对手真身(互相碰撞);客户端侧 P + 一具副本幽灵体。
# 对照两组:PROD(不接世界钩子=今天的行为) vs WORLD(接上)。
# 判据不是"归零",而是 WORLD 的斜率**显著低于** PROD —— 设计 §7 定的口径。
func _test_replay_fidelity() -> void:
	var prod := await _brawl_pass(false)
	var world := await _brawl_pass(true)
	print("[fid] PROD(今天)回滚 ×%d;WORLD(接世界钩子)回滚 ×%d" % [prod, world])
	_check(world < prod, "接通世界钩子后回滚下降(×%d → ×%d)" % [prod, world])
	# 反证:钩子接上但 restore 空转 → 必须回到 PROD 水平
	var noop := await _brawl_pass(true, true)
	_check(noop > world, "把 restore_world 变成空操作后回滚回到基线(×%d vs ×%d)" % [noop, world])
```

以及 `_brawl_pass(use_hook: bool, noop_restore: bool = false) -> int`：

```gdscript
func _brawl_pass(use_hook: bool, noop_restore: bool = false) -> int:
	_cleanup_b()
	var w := float(B_COLS * B_TILE)
	var h := float(B_ROWS * B_TILE)
	GameParameters.MAP_WIDTH = int(w)
	GameParameters.MAP_HEIGHT = int(h)
	MazeGenerator.current_grid = _flat_grid()   # 直接塞网格,不走文件(与 brawl_rollback_probe 同款)
	TileDefs.load_defs()
	_b_host = Node2D.new()
	add_child(_b_host)
	WorldBuilder.build_sim(_b_host, MazeGenerator.current_grid)
	_b_ghost_pos = {}
	_b_ghosts = {}
	_b_noop = noop_restore

	var spawn := Vector2(3.0 * B_TILE, float((B_ROWS - 1) * B_TILE) - 80.0)
	var opp_home := spawn + Vector2(200.0, 0.0)

	# 权威 A:层 AUTH,mask 含 AUTH → 与对手真身互相碰撞
	var a: Node2D = _mk("BA", spawn)
	a.collision_layer = B_LAYER_AUTH
	a.collision_mask = 1 | B_LAYER_AUTH
	var src_a := NetworkInputSource.new()
	a.set_input_source(src_a)

	# 对手真身:同层
	var o: Node2D = _mk("BO", opp_home)
	o.collision_layer = B_LAYER_AUTH
	o.collision_mask = 1 | B_LAYER_AUTH
	var src_o := NetworkInputSource.new()
	o.set_input_source(src_o)

	# 被预测 P:层 0(谁也看不见它),mask 含幽灵层
	var p: Node2D = _mk("BP", spawn)
	p.collision_layer = 0
	p.collision_mask = 1 | B_LAYER_GHOST

	# 副本 + 幽灵体
	var rep: Node2D = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	_b_host.add_child(rep)
	_b_ghosts[2] = rep.get_node_or_null("GhostBody")
	if _b_ghosts[2] == null:
		_fail("副本没有 GhostBody 节点")
		return 0

	var c := PredictionRollback.new()
	if use_hook:
		c.bind(p, self)
	else:
		c.bind(p)

	var a_hist: Array[Dictionary] = []
	var o_hist: Array[Dictionary] = []
	for t in range(B_RUN):
		# 权威步进(对手按 120 tick 周期、96 压 / 24 撤 → 持续贴身 + 相对速度不断变)
		var rec_a := {"seq": t + 1, "ax": 1.0 if (t % 120) < 96 else -1.0,
				"held": 0, "pressed": 0, "released": 0, "weapon": 0, "aim": Vector2(1.0, 0.0)}
		src_a.clear_edges()
		src_a.apply_packet(rec_a)
		a._physics_process(DT)
		a_hist.append(a.capture_state())
		var ph := (t + 23) % 120
		var rec_o := {"seq": t + 1, "ax": -1.0 if ph < 96 else 1.0,
				"held": 0, "pressed": 0, "released": 0, "weapon": 0, "aim": Vector2(-1.0, 0.0)}
		src_o.clear_edges()
		src_o.apply_packet(rec_o)
		o._physics_process(DT)
		o_hist.append(o.capture_state())

		# 到期投递(同一延迟):A → 控制器;对手 → 副本幽灵体
		var at := t - B_DELAY
		if at >= 0:
			var ost: Dictionary = o_hist[at]
			var gp: Vector2 = MazeGenerator.anchor_to_nearest(ost["pos"], p.global_position, w, h)
			_b_ghost_pos[2] = gp
			(_b_ghosts[2] as Node2D).global_position = gp
			c.on_authoritative(at + 1, a_hist[at])
		c.advance(rec_a)
	await get_tree().process_frame
	var rb := c.rollback_count()
	_cleanup_b()
	return rb
```

再加辅助：

```gdscript
func _mk(nm: String, pos: Vector2):
	var n = preload("res://scenes/player/Player.tscn").instantiate()   # 不写类型标注:免去显式 cast
	n.name = nm
	_b_host.add_child(n)
	n.global_position = pos
	return n

func _flat_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(B_ROWS):
		var row: Array[int] = []
		for x in range(B_COLS):
			row.append(31 if y == B_ROWS - 1 else 0)
		grid.append(row)
	return grid

func _cleanup_b() -> void:
	if _b_host != null and is_instance_valid(_b_host):
		_b_host.queue_free()
	_b_host = null
```

★ `noop_restore` 的接法：`restore_world` 里判 `_b_noop` 直接 return。把上面的 `restore_world` 改成：

```gdscript
func restore_world(w: Dictionary) -> void:
	if _b_noop:
		return   # 反证用:钩子接上但倒回空转
	for role in w:
		var g = _b_ghosts.get(role)
		if g != null and is_instance_valid(g):
			(g as Node2D).global_position = w[role]
```

- [ ] **Step 2: 跑探针确认它失败**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/rollback_fidelity_probe.tscn`
Expected: A 组两条 ✓；B 组报 `✗ 接通世界钩子后回滚下降(×N → ×N)`（同一个数，因为 `bind(p, self)` 第二个参数还不存在 → 更可能是解析/参数报错）

- [ ] **Step 3: 实现**

`core/prediction_rollback.gd`：

**(a) 字段区**（`var _rollbacks := 0` 之后）加：

```gdscript
# ── 世界状态(对手身体的当时位置)──
# 回滚重放必须「同一时代」:重放第 s 步时,对手身体要回到**当初预测第 s 步时**的位置。
# 否则重放的碰撞与原始预测对不上 → _captures[s] 被写成错误时代的状态 → 下一个 ack 再不符
# → 级联回滚(实测 ~35 次/秒;对手静止时因为位置恒定,重放天然保真,回滚恰好 0)。
# 由接入方实现 capture_world/restore_world(鸭子类型);不接 = 行为与从前完全一致。
var _world = null
var _worlds: Dictionary = {}   # seq(int) -> 世界快照
var _prev_world: Dictionary = {}
```

**(b) `bind`**：

```gdscript
func bind(p, world = null) -> void:
	_p = p
	_world = world
```

**(c) `advance`**（手动步进驱动：步进**当场**发生，故「现在」的世界就是这一步的世界）：

```gdscript
func advance(record: Dictionary) -> void:
	reconcile()
	if _p == null:
		return
	var seq := int(record.get("seq", _last_applied + 1))
	_capture_world(seq)
	_step(record)
	_last_applied = seq
	_inputs[seq] = record
	_captures[seq] = _p.capture_state()
	_seqs.append(seq)
	_trim_ring()
```

**(d) `note_post_step`**（引擎自步进驱动：本函数在玩家的**下一步之前**被调用，而 `capture` 是**上一步之后**的状态 —— 故"现在"的世界属于**下一个** seq。把上一次抓的世界配给本次 seq，正是「产生该 capture 的那一步所用的世界」）：

```gdscript
func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	# 一行之差:<本 seq 配"上一次抓的世界">,再把"现在"的世界留给下一个 seq。见上方注释。
	if _world != null:
		_worlds[seq] = _prev_world
		_prev_world = _world.capture_world()
	_captures[seq] = capture
	_seqs.append(seq)
	_trim_ring()
```

**(e) 抽出环清理**（`advance` 与 `note_post_step` 原先各自内联的那段 `while _seqs.size() > KEEP` 合并成一个）：

```gdscript
func _trim_ring() -> void:
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_inputs.erase(old)
		_captures.erase(old)
		_worlds.erase(old)
```

**(f) 世界抓取**：

```gdscript
func _capture_world(seq: int) -> void:
	if _world == null:
		return
	var w: Dictionary = _world.capture_world()
	_worlds[seq] = w
	_prev_world = w
```

**(g) `_handle_ack` 的重放循环**：

```gdscript
	# 真性分歧 → 权威锚定 + 重放未确认输入(错在哪补哪,非拉拢)
	_rollbacks += 1
	var saved_world: Dictionary = _world.capture_world() if _world != null else {}
	_p.restore_state(S)
	for s in _seqs:
		if s > ack and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			if _world != null and _worlds.has(s):
				_world.restore_world(_worlds[s])   # ★ 同一时代:对手身体回到当初那一步的位置
			_step(rec)
			_captures[s] = _p.capture_state()   # 刷新为重放后的真实整态
	if _world != null:
		_world.restore_world(saved_world)       # 重放把我们挪到过去了,挪回来
	_trim(ack)
```

**(h) `_trim` 同时清世界**：

```gdscript
func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)
		_worlds.erase(s)
```

**(i) `advance` 里原先那段 `while _seqs.size() > KEEP:` 删除**（已被 `_trim_ring()` 取代）。

- [ ] **Step 4: 跑探针确认通过**

Run: 同 Step 2 的命令
Expected: `[fid] PROD(今天)回滚 ×N;WORLD(接世界钩子)回滚 ×M` 且 **M < N**；三条 ✓；末行 `ROLLBACK FIDELITY PROBE: ALL-OK`

- [ ] **Step 5: 跑既有 C2 冒烟确认没带坏**

Run: `bash tests/pvp_reconcile_smoke.sh` 与 `bash tests/pvp_twin_smoke.sh`
Expected: 分别打印 `SMOKE_RECONCILE OK` / `SMOKE_TWIN OK`（两者都走 `bind(p)` 单参形式 → 行为应逐帧不变）

- [ ] **Step 6: 提交**

```bash
git add core/prediction_rollback.gd tests/rollback_fidelity_probe.gd
git commit -m "feat(c2): 回滚重放倒回对手身体(世界状态钩子),治级联回滚"
```

---

### Task 3: 1v1 客户端接线 + 把缠斗探针改造成守卫

**Files:**
- Modify: `scenes/pvp_client.gd`（`_ready` 的 bind 一行 + 新增两个方法）
- Modify: `tests/brawl_rollback_probe.gd`（变体换成 STATIC/NONE/PROD/WORLD）

**Interfaces:**
- Consumes: Task 2 的 `bind(p, world)`、`capture_world()/restore_world()` 约定（`{role:int -> Vector2}`）
- Produces: `pvp_client.capture_world() -> Dictionary` / `pvp_client.restore_world(d) -> void` —— 迁移批次 5 的 `royale_game` 照抄这两个方法（副本从 1 个变 N−1 个）

- [ ] **Step 1: 观察改造前的基线**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/brawl_rollback_probe.tscn`
Expected: 末行 `BRAWL ROLLBACK PROBE: ALL-OK`，记下 `N=2 幽灵体·最新(L1)` 那行的回滚数（改造成 WORLD 后要跟它比）

- [ ] **Step 2: 客户端接线**

`scenes/pvp_client.gd` 的 `_ready`，把：

```gdscript
		if _rollback == null:
			_rollback = PredictionRollback.new()
		_rollback.bind(_local)
```

改为：

```gdscript
		if _rollback == null:
			_rollback = PredictionRollback.new()
		# 第二个参数 = 世界状态提供者(本场景自己):回滚重放时把对手身体倒回同代位置。
		# 不接的话重放拿"当前"的对手去重算历史,与原始预测对不上 → 级联回滚(见 core/prediction_rollback.gd)。
		_rollback.bind(_local, self)
		_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

> `map_px` 也可放在 `bind` 之后任意时机设；必须在第一次 `reconcile()` 之前。

在 `_apply_local_state` 之前新增两个方法：

```gdscript
# ── 世界状态:交给 PredictionRollback 在回滚重放时倒回(见其 _worlds)──
# 只抓**幽灵碰撞体**的位置,不抓副本视觉 —— 物理只认幽灵体(副本的插值位置是渲染用的)。
# 形状 {role:int -> Vector2};大乱斗接入时同一对方法把 _replicas 全部收进来即可。
func capture_world() -> Dictionary:
	var d := {}
	if _remote_replica != null and is_instance_valid(_remote_replica):
		var g := _remote_replica.get_node_or_null("GhostBody") as Node2D
		if g != null:
			d[3 - PvpSession.role] = g.global_position
	return d


func restore_world(w: Dictionary) -> void:
	if _remote_replica == null or not is_instance_valid(_remote_replica):
		return
	var g := _remote_replica.get_node_or_null("GhostBody") as Node2D
	if g == null:
		return
	var role := 3 - PvpSession.role
	if w.has(role):
		g.global_position = w[role]
```

- [ ] **Step 3: 把缠斗探针改造成本批的守卫**

`tests/brawl_rollback_probe.gd`：删掉 `INTERP/LATEST/LATEST_INSET` 三个变体（设计 §2.1 已判定它们买不到目标，留它们是死代码），换成四个：

```gdscript
enum Variant { STATIC, NONE, PROD, WORLD }

const VARIANT_NAME := ["对手不动(健全性对照)", "幽灵体摘除(负向对照)",
		"今天的行为(无世界钩子)", "回放保真(接世界钩子)"]
```

`_ready` 里的跑批循环随之改成（`STATIC`/`NONE` 两个对照只跑 N=2 与 8，两个正式变体跑 2/4/8）：

```gdscript
	for v in [Variant.STATIC, Variant.NONE]:
		for n in [2, 8]:
			await _run_pass(v, n)
	for v in [Variant.PROD, Variant.WORLD]:
		for n in [2, 4, 8]:
			await _run_pass(v, n)
```

`_run_pass` 里接控制器的地方：

```gdscript
	if _variant == Variant.WORLD:
		ctrl.bind(P, self)
		ctrl.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	else:
		ctrl.bind(P)
```

幽灵体定位：**四个变体统一走「最新已收快照」的显式写位置**（`INTERP` 变体已删，不再依赖副本的 `_process` 插值 —— 那正是它在探针里不可复现的原因）：

```gdscript
	# 一律显式写位置:副本的 _process 插值时钟在探针里不可控(实测同配置两次跑出 98/240),
	# 而回滚只取决于幽灵体在哪,与副本视觉无关。
	for r in _replicas:
		(r as Node).set_process(false)
```

对手输入：`STATIC` 返回 0.0，其余按原脚本。

探针自身实现世界状态提供者（与 `pvp_client` 同一对方法）。为此把 `_replicas` / `_ghosts` 从**下标数组**改成**按 role 索引的字典** —— 世界快照的形状约定就是 `{role -> Vector2}`，用下标硬凑会在 role 不连续时错位：

```gdscript
var _replicas: Dictionary = {}      # role(int) -> PlayerReplica
var _ghosts: Dictionary = {}        # role(int) -> GhostBody
var _ghost_pos: Dictionary = {}     # role(int) -> Vector2(幽灵体世界位置)

func capture_world() -> Dictionary:
	return _ghost_pos.duplicate()

func restore_world(w: Dictionary) -> void:
	for role in w:
		var g = _ghosts.get(role)
		if g != null and is_instance_valid(g):
			(g as Node2D).global_position = w[role]
```

`_run_pass` 里建副本那段随之改成按 role 建（对手 role 从 2 起，与 `pvp_client` 的 `3 - PvpSession.role` 同一套编号思路）：

```gdscript
	for i in range(n - 1):
		var role := i + 2
		var r: Node2D = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
		_host.add_child(r)
		var g := r.get_node_or_null("GhostBody") as StaticBody2D
		if g == null:
			_fail("副本没有 GhostBody 节点(player_replica._build_ghost_body 没跑或被改名)")
			return
		if variant == Variant.NONE:
			g.collision_layer = 0
		_replicas[role] = r
		_ghosts[role] = g
```

每 tick 投递对手位置那一处（原 `for i in range(_replicas.size())` 循环）改成遍历 role，并把位置记进世界快照：

```gdscript
	if ack_t >= 0:
		for role in _replicas:
			var st: Dictionary = (_opp_hist[role - 2] as Array)[ack_t]
			var gp: Vector2 = MazeGenerator.anchor_to_nearest(
					st["pos"], P.global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			_ghost_pos[role] = gp
			(_ghosts[role] as Node2D).global_position = gp
```

（`_opp_hist` 仍按对手下标存，`role - 2` 即其下标；`_run_pass` 开头要一并 `_replicas = {}` / `_ghosts = {}` / `_ghost_pos = {}`。）

收官断言：

```gdscript
	if _variant == Variant.STATIC:
		_check(rb == 0, "N=%d 对手不动时零回滚(rb=%d)" % [n, rb])
	if _variant == Variant.NONE:
		_check(rb > 0, "N=%d 摘掉幽灵体后确实回滚(rb=%d)" % [n, rb])
```

并在 `_summarize` 里加一条跨变体断言。为此把 `_rows` 从 `Array[String]` 换成 `Array[Dictionary]`（要按 N+变体取数，字符串拼回去取不出来）：

```gdscript
var _rows: Array = []      # 每项 {n:int, variant:int, rb:int, text:String}

func _find(variant: int, n: int) -> int:
	for r in _rows:
		if int(r["variant"]) == variant and int(r["n"]) == n:
			return int(r["rb"])
	return -1
```

`_run_pass` 收官处由 `_rows.append(line)` 改为：

```gdscript
	_rows.append({"n": n, "variant": variant, "rb": rb, "text": line})
```

`_summarize` 里打印改成遍历 `r["text"]`，并追加跨变体断言：

```gdscript
	# WORLD 必须低于 PROD(同 N),否则本批白做
	for n in [2, 4, 8]:
		var prod := _find(Variant.PROD, n)
		var world := _find(Variant.WORLD, n)
		if prod > 0 and world >= 0:
			_check(world < prod, "N=%d 回放保真把回滚从 ×%d 降到 ×%d" % [n, prod, world])
```

- [ ] **Step 4: 跑改造后的探针**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/brawl_rollback_probe.tscn`
Expected: `STATIC` 全 0；`NONE` 爆炸；**`WORLD` 明显低于 `PROD`**；末行 `BRAWL ROLLBACK PROBE: ALL-OK`

- [ ] **Step 5: 反证（必须实跑）**

把 `restore_world` 的第一行临时改成 `return`（倒回空转），重跑。
Expected: `WORLD` 回到 `PROD` 水平 → `_check` 报 `✗ N=… 回放保真把回滚从 ×N 降到 ×N` 并 FAIL。**改回来。**

- [ ] **Step 6: 跑 1v1 全链冒烟**

Run: `bash tests/pvp_room_smoke.sh`、`bash tests/pvp_match_smoke.sh`、`bash tests/pvp_reconcile_smoke.sh`、`bash tests/pvp_twin_smoke.sh`
Expected: 四个都 OK（`pvp_match_smoke` 是硬门：`ack_seq >= 30` 与 `c2` 全态一致）

- [ ] **Step 7: 提交**

```bash
git add scenes/pvp_client.gd tests/brawl_rollback_probe.gd
git commit -m "feat(c2): 1v1 客户端接入世界状态钩子;缠斗探针改为 PROD/WORLD 对照守卫"
```

---

### Task 4: 倒地时幽灵体不跟着旋转

**Files:**
- Modify: `scenes/player/player_replica.gd`（`apply_snapshot` 的倒地分支）
- Modify: `tests/replica_ghost_probe.gd`（加一条断言）

**Interfaces:**
- Consumes: 无
- Produces: 无（内部修正）

**为什么**：倒地时副本根节点设 `rotation = -PI/2 * facing` 做转体，而幽灵体是**子节点** → 碰撞箱跟着转 90°。但服务器 `player.gd` 的倒地分支**不旋转**（全文件零 `rotation`），尸体停在最后姿态的箱子上。紧挨着的注释写着「幽灵体不跟着变……否则'倒地的对手还挡不挡路'两端不一致」—— 意图正确，被 `rotation` 那一行抵消了。

- [ ] **Step 1: 写失败的断言**

`tests/replica_ghost_probe.gd` 在 `_check_source_guard()` 之前加一条：

```gdscript
	# 倒地时幽灵体**不得**跟着副本根节点转体:服务器侧 player.gd 的倒地分支不旋转,
# 尸体停在最后姿态的箱子上。副本根节点转 -90°(视觉转体)会连子节点一起转 → 两端不一致。
	await _test_downed_ghost_rotation()
```

并新增：

```gdscript
func _test_downed_ghost_rotation() -> void:
	var rep: Node2D = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	_host.add_child(rep)
	await get_tree().process_frame
	rep.apply_snapshot({"pos": _spawn, "facing": 1, "aim": Vector2.RIGHT, "weapon": 0,
			"previewing": false, "hp": 0, "pose": 0, "downed": true}, _spawn, 1)
	await get_tree().process_frame
	var g := rep.get_node_or_null("GhostBody") as Node2D
	if g == null:
		_fail("副本没有 GhostBody 节点")
		return
	var deg := rad_to_deg(absf(g.global_rotation))
	_check(deg < 1.0, "倒地时幽灵体不旋转(实测 %.1f°;>1° = 碰撞箱跟着转了)" % deg)
	rep.queue_free()
	await get_tree().process_frame
```

- [ ] **Step 2: 跑探针确认它失败**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/replica_ghost_probe.tscn`
Expected: `[ghost]   ✗ 倒地时幽灵体不旋转(实测 90.0°…)`，末行 `REPLICA GHOST PROBE: FAIL`

- [ ] **Step 3: 实现**

`scenes/player/player_replica.gd` 的 `apply_snapshot`，倒地分支：

```gdscript
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)   # 倒地转体(与 player._downed 一致)
		# 幽灵体**不跟着变**:服务器侧 player.gd 的倒地分支在姿态碰撞箱切换之前就 return,
		# 尸体停在最后一个姿态的箱子上 —— 副本要同款,否则"倒地的对手还挡不挡路"两端不一致。
```

改为（在原地补一行；`rotation` 是**副本根节点**的视觉转体，幽灵体是子节点会被一起转）：

```gdscript
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)   # 倒地转体(仅视觉:只转身体精灵,不转幽灵体)
		# 幽灵体**不跟着变**:服务器侧 player.gd 的倒地分支在姿态碰撞箱切换之前就 return,
		# 尸体停在最后一个姿态的箱子上 —— 副本要同款,否则"倒地的对手还挡不挡路"两端不一致。
		# ★ 上面那行 rotation 转的是**根节点**,而幽灵体是它的子节点 → 会连碰撞箱一起转 90°。
		#   故这里把幽灵体的世界旋转压回 0(子节点局部旋转抵消父节点),碰撞箱保持与服务器一致。
		if _ghost != null:
			_ghost.global_rotation = 0.0
```

- [ ] **Step 4: 跑探针确认通过**

Run: 同 Step 2 的命令
Expected: 该条 ✓，末行 `REPLICA GHOST PROBE: ALL-OK`

- [ ] **Step 5: 跑与本改动相关的冒烟**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd`
Expected: `SMOKE OK`（`Player.tscn` 未被改动，`player mask == 5` 断言应仍绿）

- [ ] **Step 6: 提交**

```bash
git add scenes/player/player_replica.gd tests/replica_ghost_probe.gd
git commit -m "fix(pvp): 倒地时幽灵碰撞体不再跟着副本转体(与服务器一致)"
```

---

## 收官

- [ ] 跑全部受影响的探针与冒烟（由用户执行）：
  `rollback_fidelity_probe`、`brawl_rollback_probe`、`replica_ghost_probe`、
  `pvp_room_smoke`、`pvp_match_smoke`、`pvp_reconcile_smoke`、`pvp_twin_smoke`、
  `kh_l5_probe`、`kh_l6_probe`、`grenade_player_hit_probe`、`preview_visibility_probe`
- [ ] 真机联调（用户）：1v1 贴身缠斗，看是否还有可见抖动 —— headless 量不到观感，这是唯一能判 L4 取值与「2~7px 修正量可不可感」的途径
- [ ] 更新 `CLAUDE.md`：§武器与子弹/§网络与 PvP 补「回滚重放倒回对手身体」一句；测试段加两个新探针
- [ ] 更新 `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md`：§2.1 的「未测项」里划掉已量的，补本批落地后的 PROD/WORLD 实测对照

## 本批不做的（别顺手做）

- **不做 L1 的「幽灵体用最新权威位置」、不做 L3 的「幽灵体内缩」** —— 设计 §2.1 实测两者都买不到目标，L3 在 N=8 反而更差。理由与读数在 spec §4.4/§8。
- **不接 `cam_lookahead/smooth/deadzone` 那组死参数** —— 那是全面的手感改动，需另行裁定。
- **不动大乱斗**（`royale_game.gd`）—— 它还没有 rollback 控制器，接 C2 属迁移批次 5。
