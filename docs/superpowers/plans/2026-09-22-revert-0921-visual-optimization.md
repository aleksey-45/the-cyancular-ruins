# 副本位置平滑改回「自身差分指数追赶」（只动这一条线）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把**对手副本的位置平滑**从「双快照 tick 域 alpha 插值」改回「自身差分指数追赶」，消除多人模式里「对手位置一跳一跳、看起来敌方掉帧」。

**Architecture:** 复用 `feat/3v3-fixes` 分支已落地并验证过的实现（`6e2ef6d` 的**甲**部分），但**不能 cherry-pick** —— 那个提交把三件事打包在一起，其中两件用户明确要求不动。所以本方案是**手工移植甲**：只改 `player_replica.gd` 的位置那一段 + 删掉随之变成死代码的 `SnapshotInterp`，其余一律不碰。

**Tech Stack:** Godot 4.7.1 标准版、GDScript、headless 探针。

## Global Constraints

- **引擎路径走环境变量 `GODOT`**（console 版）。未设时默认
  `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`。下文命令一律写 `"$GODOT"`。
- **判据一律 grep 输出文本**（`ALL-OK` / `OK` / `SMOKE OK` / `ALL-OK`），**不看退出码** —— 探针中途报错时 `--quit-after` 仍 exit 0 且什么都不打印。
- **不要碰工作区里那 6 个未提交文件**（`core/net/local_server.gd`、`scenes/main_menu.gd`、`scenes/royale_lobby.gd`、`scenes/team_lobby.gd`、`server/server_main.gd`、`tests/menu_autotest.gd`）与未跟踪目录 `_crashtest/`。
- **不要跑会占 7777 的探针**（`royale_probe` / `royale_c2_probe` / `team_match_probe`）。
- **★ 绝对不要 `git cherry-pick 6e2ef6d`。** 它同时改了形变（删副本形变 + 加 `set_landing_only` 模式限制条件），而用户明确裁定「剩下都别动」。

---

## 范围（用户 2026-09-22 裁定）

| 线 | 本次动不动 |
|---|---|
| **副本位置平滑** | ★ **动** —— 改回「自身差分指数追赶」 |
| 补间形变 squash（组件 / 参数 `0.06/16.0/0.10` / 副本形变 / 模式限制条件） | **不动** |
| 小地图（09-17 圆形视野） | **不动** |
| 角色色相 / 队色（09-19 那批） | **不动** |
| 副本枪口折叠（`9239469`） | **不动** |

## 为什么是这一条（诊断）

用户报「所有多人模式都卡得要死」。定位：

1. **不是 CPU 问题。** 实测本机全机占用 3.42%（20 核），无僵尸进程、7777/7800 均无占用。形变每帧只写一次 `animator.scale`，掉不了帧。
2. **是对手副本的渲染在抖。** main 走 `core/net/snapshot_interp.gd` 的双快照 alpha 插值。`6e2ef6d` 记的实测：`SnapshotInterp.push()` 每收一包就把渲染时钟重置到 `latest - 1`，而 `advance()` 每帧推 `delta * 60` —— **60fps 渲染 + 60Hz 快照**下恰好 1.0 tick ⇒ 下一帧时钟正落在 `latest`、`sample()` 走「冻结在最新」那一支 ⇒ **渲染的就是最新包的原值**，与绕过插值直落**逐项相同**。于是对手平滑度 == 网络到达平滑度：抖动 8/25ms 时 **49.6% 的帧零位移、50.4% 走两步**。用户原话就是「**位置一跳一跳，看起来敌方掉帧**」。
3. 三种多人模式都有对手副本、单机没有 —— 与「只有多人卡」吻合。
4. **main 上还没有这个回滚**（main 的 HEAD `ead8934` 早于 `6e2ef6d`）。⇐ 这就是本次要补的。

## 甲的确切内容（从 `6e2ef6d` 摘出，供核对）

- 新增 `const INTERP_RATE := 12.0`（取自 2026-09-03 的 `aa1d8f0^`，旧平滑方案的最后一个版本；刻意复用旧值不新调参）
- 删 `const KEEP_TICKS := 8`
- 新增 `var _placed := false`（首次定位直落）
- 删 `var _interp: SnapshotInterp = null` 与 `_ensure_interp()`
- `apply_snapshot` 第三参改名 `_tick`（不再参与计算，保留是为了不改调用面）
- `apply_snapshot` 里删掉 `_ensure_interp()` + `_interp.push(tick, data["pos"])`
- `_process` 的插值块换成「锚到最近副本 → 首次直落 / 否则差量指数追赶 → 再锚一次」
- 删 `core/net/snapshot_interp.gd`(+`.uid`) 与 `tests/snapshot_interp_smoke.gd`(+`.uid`)
- `core/README.md` 相应订正

★ **两个 `anchor_to_nearest` 是核心关键的，别"顺手简化"掉**：旧方案当年有致命缺陷 —— 渲染位置与目标相隔整幅地图时最短向量为 0 ⇒ 副本一旦漂到远副本就**永远留在那儿**（对手被渲染到屏幕外「看不见」）。解法是把**目标点**锚到本地玩家最近副本再以普通差量追赶；这与「平滑 vs 插值」无关，是独立的一件事。

---

## Task 1: 先量出「一跳一跳」—— 副本渲染平滑度探针

**为什么先做:** 没有这条读数，改完仍然无法回答「到底治没治好」。本 Task 把用户的抱怨变成可重复的断言：改**前**红（≈50% 帧零位移），改**后**绿（≈0%）。测的是**结果**（渲染位置每帧有没有动），不是实现 —— 所以它不会随 `snapshot_interp.gd` 被删而失效。

**Files:**
- Create: `tests/replica_smoothness_probe.gd`
- Create: `tests/replica_smoothness_probe.tscn`

**Interfaces:**
- Consumes: `scenes/player/player_replica.tscn` 的 `apply_snapshot(data: Dictionary, local_anchor: Vector2, tick: int) -> void` 与 `_process(delta: float)`（`tests/squash_replica_probe.gd` 用的是同一对）。
- Produces: 判据文本 `REPLICA SMOOTHNESS PROBE: ALL-OK` / `REPLICA SMOOTHNESS PROBE: FAIL | <原因>`。

- [ ] **Step 1: 写探针脚本**

创建 `tests/replica_smoothness_probe.gd`：

```gdscript
extends Node

# tests/replica_smoothness_probe.gd —— 「对手看起来卡/掉帧」的常驻守卫。
#
# 症状(用户原话):「位置一跳一跳,看起来敌方掉帧」。
# 机制:副本位置若**直接跟随快照到达**(渲染的就是最新包原值),对手的平滑度就等于网络的
#   到达平滑度 —— 抖动 8/25ms 时约一半的帧零位移、另一半走两步。`6e2ef6d` 实测:
#   alpha 插值 49.6% 零位移;指数追赶 0.0%(max 5.5px,理想 5.0)。
#
# ★ 本探针只量「渲染位置上每帧有没有动」,不关心走的是哪套实现 ——
#   故它在改前改后都能跑(改前红、改后绿),且不会随实现被删而失效。
#
# 跑法:"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_smoothness_probe.tscn
# 判据:输出文本里的 `REPLICA SMOOTHNESS PROBE: ALL-OK`(不看退出码)。
#
# 相 A:平滑度(平地上按抖动到达喂快照,数零位移帧)
# 相 B:跨接缝不卡远副本(旧方案的致命缺陷守卫)

const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")

const DT: float = 1.0 / 60.0          # 渲染帧
const FRAMES := 600                   # 相 A 的帧数(10 秒)
const STEP_PX := 5.0                  # 每包前进的世界像素(60Hz × 5px = 300px/s,普通移速)
# 快照到达间隔(ms):8/25 交替(和 = 33ms ≈ 2 帧,均值仍是 60Hz)——
# 复现 `6e2ef6d` 记录的那组到达抖动。
const GAPS_MS := [8.0, 25.0]
const STILL_EPS := 0.05               # 位移小于此值 = 这一帧画面上没动
const STILL_RATIO_MAX := 0.10         # 零位移帧占比上限(旧法 ≈ 0.496,新法 0.0)
const MAX_STEP_PX := 8.0              # 单帧最大位移上限(新法实测 5.5,理想 5.0)
const CANON_X := 1000.0               # 相 A 采样点:开阔处,只由快照驱动,与地形/物理无关
const CANON_Y0 := 1000.0
const SEAM_NEAR_PX := 200.0           # 相 B:渲染位置到锚点的**未回绕** |Δx| 上限

var _rep: Node2D = null
var _canon := Vector2(CANON_X, CANON_Y0)
var _tick := 0
var _f := 0
var _prev := Vector2.ZERO
var _still := 0
var _acc_ms := 0.0
var _gap_i := 0
var _max_step := 0.0
var _phase := "A"
var _seam_f := 0


func _ready() -> void:
	_rep = REPLICA_SCENE.instantiate()
	# ★ 空载守卫(与 squash_replica_probe 同款):`player_replica.gd` 一旦解析不过,
	#   tscn 的根会退化成裸 Node2D —— 场景照样加载、一行判据都不打印、退出码还是 0,
	#   那正是 CLAUDE.md 记的"看着像功能坏了"的形态。这里把它变成一条响亮的 FAIL。
	if not _rep.has_method("apply_snapshot"):
		print("REPLICA SMOOTHNESS PROBE: FAIL | PlayerReplica 脚本没加载起来(解析错?根节点是 %s)" % _rep.get_class())
		get_tree().quit(1)
		return
	add_child(_rep)
	_rep.global_position = _canon
	# 逐帧显式调 `_process(DT)`,不交给引擎(与 squash_replica_probe 同款)
	_rep.set_process(false)
	_prev = _rep.global_position
	print("[replica_smoothness] 相A %d 帧 / 到达间隔 %s ms 交替 / 每包 %.1f px" % [FRAMES, str(GAPS_MS), STEP_PX])


# 键与 server/match_snapshot.gd 的 world["players"][role] 逐字一致(内容取中性可过值)。
func _snapshot_dict(pos: Vector2) -> Dictionary:
	return {
		"pos": pos,
		"vel": Vector2.ZERO,
		"facing": 1,
		"pose": 1,
		"weapon": 0,
		"hp": 100,
		"waterproof": 100.0,
		"downed": false,
		"aim": Vector2(1.0, 0.0),
		"previewing": false,
	}


func _physics_process(_delta: float) -> void:
	if _rep == null:
		return
	if _phase == "A":
		_phase_a()
	else:
		_phase_b()


func _phase_a() -> void:
	# 到达:按 GAPS_MS 交替计时(25ms 的间隔会跨帧,故用 while 补足)
	_acc_ms += DT * 1000.0
	while _acc_ms >= GAPS_MS[_gap_i]:
		_acc_ms -= GAPS_MS[_gap_i]
		_gap_i = (_gap_i + 1) % GAPS_MS.size()
		_canon.y += STEP_PX
		_rep.apply_snapshot(_snapshot_dict(_canon), _canon, _tick)
		_tick += 1
	_rep._process(DT)
	var p: Vector2 = _rep.global_position
	var d := p.distance_to(_prev)
	if d < STILL_EPS:
		_still += 1
	_max_step = maxf(_max_step, d)
	_prev = p
	_f += 1
	if _f >= FRAMES:
		_finish_a()


func _finish_a() -> void:
	var ratio := float(_still) / float(_f)
	print("[replica_smoothness] 相A 零位移帧 %d/%d = %.4f(上限 %.2f);单帧最大位移 %.3f px(上限 %.1f)"
			% [_still, _f, ratio, STILL_RATIO_MAX, _max_step, MAX_STEP_PX])
	if ratio > STILL_RATIO_MAX or _max_step > MAX_STEP_PX:
		_fail("相A 零位移占比 %.4f / 最大位移 %.3f px(对手会看起来一跳一跳)" % [ratio, _max_step])
		return
	# 进相 B —— 复现旧方案那条**致命缺陷**:把副本**强行摆到一个"远副本"**上(与锚点相隔
	# 整幅地图宽、但环面坐标相同),再看它能不能自己回到锚点所在的那一份。
	# ★ 为什么必须"强行摆"而不是"把锚点放到地图另一头":环面距离是**对称**的 —— 锚到最近副本
	#   与留在原地,量出来的环面距离**相同**(都等于 canonical↔anchor 的环面距离),那种写法两边
	#   都会通过,是条空断言。缺陷只在"渲染位置与目标相隔整幅地图"时现形。
	var w := float(GameParameters.MAP_WIDTH)
	_rep.apply_snapshot(_snapshot_dict(_canon), _canon, _tick)
	_tick += 1
	_rep.global_position = Vector2(CANON_X + w, CANON_Y0)   # 远副本:环面同一格,但差了整整一幅地图
	print("[replica_smoothness] 相B 远副本:把渲染位置摆到 %.1f(锚点 %.1f,地图宽 %.1f)"
			% [CANON_X + w, CANON_X, w])
	_phase = "B"


func _phase_b() -> void:
	# 锚点恒定、canonical 恒定,喂 10 帧看它是否自己回来
	_rep.apply_snapshot(_snapshot_dict(_canon), _canon, _tick)
	_rep._process(DT)
	_seam_f += 1
	if _seam_f < 10:
		return
	# 判据用**未回绕**的绝对坐标:正确实现下渲染位置必须落回锚点那一份(CANON_X 附近);
	# 若"卡在远副本"它会是 CANON_X + w,差整整一幅地图。这里刻意**不做环面包裹**。
	var dx := absf(_rep.global_position.x - CANON_X)
	var tor := GridPathfinder.toroidal_delta_px(_canon, _rep.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	print("[replica_smoothness] 相B 渲染位置.x=%.1f 距锚点(未回绕)=%.1f px;环面距离=%.1f px(上限 %.1f)"
			% [_rep.global_position.x, dx, tor, SEAM_NEAR_PX])
	if dx > SEAM_NEAR_PX:
		_fail("相B 副本卡在远副本(|Δx| = %.1f px,地图宽 %.1f)—— 对手会被渲染到屏幕外「看不见」" % [dx, w])
		return
	print("REPLICA SMOOTHNESS PROBE: ALL-OK")
	get_tree().quit(0)


func _fail(msg: String) -> void:
	print("REPLICA SMOOTHNESS PROBE: FAIL | " + msg)
	get_tree().quit(1)
```

- [ ] **Step 2: 写场景文件**

创建 `tests/replica_smoothness_probe.tscn`（与 `tests/squash_replica_probe.tscn` 逐字同形，已核对该文件只有这 6 行）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/replica_smoothness_probe.gd" id="1"]

[node name="ReplicaSmoothnessProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑它，确认它红（bug 被复现）**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_smoothness_probe.tscn
```
Expected: `REPLICA SMOOTHNESS PROBE: FAIL | 相A ...`,且**零位移占比在 0.4~0.6 之间**（`6e2ef6d` 记的是 0.496）。

★ 若占比是 0.0（现在就绿）,**停手** —— 说明 main 上的副本已经不走 alpha 插值了,本方案的诊断前提失效,回来重新定位。
★ 若占比 1.0 且最大位移 0,说明夹具没驱动起来(副本没收到快照),同样是停手信号。
★ 相 B 在改前**本来就绿**(它在改前走不到,`_finish_a` 已经 FAIL 退出了;而 alpha 插值那条路也会把远副本锚回来)。它是**改后不许退化**的守卫,别指望它现在红。

- [ ] **Step 4: 生成 `.uid` 再提交**

本仓每个 `.gd` 都有配套 `.gd.uid`（Godot 首次导入时生成）。跑一次 Step 3 那条命令即可让它写入磁盘。

Run: `ls tests/replica_smoothness_probe.gd.uid`
Expected: 文件存在。若不存在，用 `"$GODOT" --headless --path . --import` 刷一次再确认。

```bash
git add tests/replica_smoothness_probe.gd tests/replica_smoothness_probe.gd.uid tests/replica_smoothness_probe.tscn
git commit -m "test(replica): 副本渲染平滑度探针 —— 把「对手一跳一跳」变成断言(当前红)"
```

---

## Task 2: 移植甲的代码改动

**Files:**
- Modify: `scenes/player/player_replica.gd`
- Modify: `core/README.md`
- Delete: `core/net/snapshot_interp.gd`、`core/net/snapshot_interp.gd.uid`、`tests/snapshot_interp_smoke.gd`、`tests/snapshot_interp_smoke.gd.uid`

**Interfaces:**
- Consumes: 无（本 Task 只改本类内部）
- Produces: `player_replica.gd` 新增 `const INTERP_RATE := 12.0`、`var _placed := false`；不再有 `_interp` / `_ensure_interp()` / `KEEP_TICKS`。`apply_snapshot` 签名不变（第三参改名 `_tick`）。

★ **先做一次前置检查**：确认 `SnapshotInterp` 在 main 上只有 `player_replica.gd` 一个用户。Run:
```bash
grep -rn "SnapshotInterp\|snapshot_interp\|_interp\b" --include=*.gd --include=*.tscn . | grep -v "^./tests/squash_replica_probe" | grep -v "^./tests/replica_smoothness_probe"
```
Expected: 只有 `scenes/player/player_replica.gd`、`core/net/snapshot_interp.gd` 自身、`tests/snapshot_interp_smoke.gd`。若还有别的用户,**停手报回来**。

- [ ] **Step 1: 换掉文件头的方案说明**

`scenes/player/player_replica.gd` 文件头。把这一整段：

```gdscript
#   幽灵体让预测所依据的世界与权威世界一致。★ 它只**减小**分歧不消除(副本位置是插值、落后约
#   一 tick),验收按「回滚次数下降多少」量,别按「归零」验收。
# pose/facing/aim/previewing/downed/weapon 按「最新快照」即时套用(反应不落后,位置才有插值)。
# 位置走「双快照 + tick 域 alpha 插值」:算法本身已收进 `core/snapshot_interp.gd`(SnapshotInterp,
# 2026-09-14 —— 此前本类与 enemy_replica 各有一份逐字同款;那段是环面插值的热点,CLAUDE.md 专门
# 记过教训,且有独立行为冒烟 tests/snapshot_interp_smoke.gd)。本类只负责:把勾子喂给它、
# 每帧推进时钟、以及把插值结果**锚到本地玩家(相机)最近副本**(保证渲染在可见副本,见 _process)。

const KEEP_TICKS := 8       # 位置缓冲保留窗口(最新前 8 tick;对手要更长的抗抖动窗,鸟只要 4)
```

替换为：

```gdscript
#   幽灵体让预测所依据的世界与权威世界一致。★ 它只**减小**分歧不消除(副本位置比权威落后一点),
#   验收按「回滚次数下降多少」量,别按「归零」验收。
# pose/facing/aim/previewing/downed/weapon 按「最新快照」即时套用(反应不落后,位置才平滑)。
#
# 位置走「自身差分指数追赶」:每帧朝「锚到本地玩家最近副本的目标点」按 `1 - exp(-INTERP_RATE*Δ)`
# 收敛。**2026-09-22 用户裁定,从「双快照 tick 域 alpha 插值」改回这个方案** —— 依据是实测:
# `SnapshotInterp.push()` 每收一包就把渲染时钟重置到 `latest - 1`,而 `advance()` 每帧推进
# `delta * 60`;在 **60fps 渲染 + 60Hz 快照**下那恰好是 1.0 tick ⇒ 下一帧时钟正好落在 `latest`
# 上,`sample()` 走"冻结在最新"那一支 ⇒ 渲染的就是**最新包的原值**,与"绕过插值直落"逐项相同。
# 于是对手的平滑度 == 包的到达平滑度:到达抖动 8/25ms 时 **49.6% 的帧零位移、50.4% 的帧走两步**,
# 也就是用户报的「位置一跳一跳,看起来敌方掉帧」。指数追赶对同样的到达抖动是**连续**收敛,
# 不把抖动原样透传到画面上。读数由 `tests/replica_smoothness_probe.tscn` 常驻钉住。
# ★★ 旧方案当年那条**致命缺陷已单独修掉、且必须一直保留**:渲染位置与目标相隔整幅地图时
# 最短向量为 0 ⇒ 副本一旦漂到远副本就**永远留在那儿**(对手被渲染到屏幕外「看不见」)。
# 现在的解法是把**目标点**锚到本地玩家最近副本再以普通差量追赶 —— 这与"平滑 vs 插值"**无关**,
# 是独立的一件事。**别"顺手简化"掉下面那两个 `anchor_to_nearest`。**

# 指数追赶速率(越大越跟手)。取自 2026-09-03 的 `aa1d8f0^`(旧平滑方案的最后一个版本;
# 该常量本身从 `2cfbea3` 起就是这个值)—— 刻意复用旧值,不新调参。
const INTERP_RATE := 12.0
```

- [ ] **Step 2: 加 `_placed`、删 `_interp`**

在 `var _have_data := false` 之后插入：

```gdscript
# 首次定位是否已**直落**(见 _process)。★ 指数追赶**不能**用于开场第一帧:副本被创建在世界
# 原点,直接开始追赶要十几帧才到位,而那十几帧里幽灵体停在错位置 ⇒ 本地预测与权威分歧
# ⇒ 白回滚一次(replica_ghost_probe ② 实测:直落时 rb=0,追赶时 rb=1)。旧方案(`aa1d8f0^`)
# 没有这一条,是因为那会儿副本走的是"缓冲未满时直落最新权威位置"那条支路 —— 平滑换回来时
# 这一半被一起丢了,故在此显式补回。
var _placed := false
```

并删掉这三行：

```gdscript
# ── 位置插值(算法在 core/snapshot_interp.gd;惰性构造见 _ensure_interp)──
var _interp: SnapshotInterp = null
```

- [ ] **Step 3: `apply_snapshot` 去掉缓冲推入**

签名的第三参改名（GDScript 才不报 UNUSED_PARAMETER）：

```gdscript
# ★ 第三个形参 `_tick` 现在**不参与任何计算**(位置不再走 tick 域缓冲),保留它纯粹是为了
#   不改调用面:三个生产调用点(`pvp_game` / `royale_game` / `team_game`)与一批探针都按
#   三参调用,快照的 `tick` 也确实是副本的契约字段(哪天要按 tick 丢乱序包就得用它)。
#   名字带下划线 = GDScript 不再报 UNUSED_PARAMETER。
func apply_snapshot(data: Dictionary, local_anchor: Vector2, _tick: int) -> void:
```

★ **本步不要动** `_vel = data.get("vel", Vector2.ZERO)` 与 `_pose = pose` —— 副本形变保留，它们仍被使用。

把文件末尾这两段（含 `_ensure_interp` 整个函数）**整段删除**：

```gdscript
	# 位置交给插值缓冲(pose/facing 等即时套用,位置平滑落后一小段,分毫不可感)
	_ensure_interp()
	_interp.push(tick, data["pos"])

# 惰性构造插值器:它要读地图尺寸,而尺寸由场景在 `GameParameters.refresh_map_size()` 之后才定下来。
# 放在 _ready 里会在「副本早于 refresh_map_size 创建」时**静默**拿到错的边界(环面回绕按错尺寸 →
# 出现空气墙),故推迟到**首次收到快照**才建 —— 那一定在场景 _ready 走完之后。
func _ensure_interp() -> void:
	if _interp == null:
		_interp = SnapshotInterp.new(KEEP_TICKS, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

替换为：

```gdscript
	# 位置不在这里动:本类没有 delta,而指数追赶必须逐帧推进 —— 见 _process。
```

- [ ] **Step 4: `_process` 的位置块换成追赶**

把 `_process` 里这一段：

```gdscript
		if _interp != null and _interp.ready():
			_interp.advance(delta)
			var canonical := _interp.sample()
			# 插值出的 canonical 锚到本地玩家(相机)最近副本渲染:保证在可见副本。
			# 不做自身差分追赶——旧实现那句「最短向量=0 会卡在远副本」由这里直接锚定消解。
			global_position = MazeGenerator.anchor_to_nearest(canonical, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		else:
			# 缓冲未满(开场首个快照):直落最新权威位置,不做插值
			global_position = MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

替换为：

```gdscript
		# 目标 = 对手 canonical 锚到本地玩家(相机)最近副本,每帧重算(跟随相机跨接缝)。
		var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# 首次定位**直落**(理由见 `_placed`):目标本身已锚到本地玩家最近副本,直接落上去即可。
		if not _placed:
			global_position = target
			_placed = true
		else:
			# 当前渲染位置也锚到 target 所在的副本空间,再做**普通差量**追赶。
			# ★★ 别改成 `toroidal_delta_px(global_position, target, …)` 的"最短路径"写法:渲染位置与
			#   目标相隔整幅地图时最短向量为 0,副本一旦漂到远副本就永远留在那儿(对手渲染到屏幕外
			#   「看不见」)—— 那正是旧方案被替换掉的原因。先把两端各自锚进同一副本空间,差量才是
			#   要追赶的那个真实位移。
			var current := MazeGenerator.anchor_to_nearest(global_position, target,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
			# 渲染位置归到本地玩家(相机)最近副本:确保渲染在可见副本,不留在远副本。
			global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

★ **本步不要动** 紧随其后的受击闪烁块与**补间形变块**（`var on_floor := ...` / `squash.tick(...)` / `_prev_vel_y = _vel.y`）—— 副本形变保留。

- [ ] **Step 5: 删掉已死的 `SnapshotInterp`**

```bash
git rm core/net/snapshot_interp.gd core/net/snapshot_interp.gd.uid
git rm tests/snapshot_interp_smoke.gd tests/snapshot_interp_smoke.gd.uid
```

- [ ] **Step 6: 订正 `core/README.md`**

`core/README.md` **第 21 行**是一个文件名清单，把 `snapshot_interp` 一项删掉：

```
  `net_bus` `net_bus_ext` `prediction_rollback` `snapshot_interp` `pvp_session` `proc_util`
```

改为：

```
  `net_bus` `net_bus_ext` `prediction_rollback` `pvp_session` `proc_util`
```

- [ ] **Step 7: 编译检查 + 启动检查**

Run:
```bash
"$GODOT" --headless --path . --quit-after 90
```
Expected: **无** `Parse Error` / `SCRIPT ERROR` / `Could not resolve class`。

★ `--import` 不编译脚本；最可靠的是真加载场景 —— 上面这条就是。

- [ ] **Step 8: 提交**

```bash
git add scenes/player/player_replica.gd core/README.md
git commit -m "fix(replica): 副本位置改回自身差分指数追赶(只动位置,形变不动)"
```
（`git rm` 的四个文件已在 Step 5 入索引。）

---

## Task 3: 验证

**Files:** 无改动；只跑探针。若某条红，先判断是「本改动引入」还是「探针断言随实现该更新」，**不要**为了让探针变绿而改实现。

- [ ] **Step 1: 确认 Task 1 的探针翻绿**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_smoothness_probe.tscn
```
Expected: 相A 零位移占比 ≈ 0.0000、单帧最大位移 ≈ 5.0~5.6 px；相B `|Δx| ≈ 0`（远副本被拉回锚点那一份）；末行 `REPLICA SMOOTHNESS PROBE: ALL-OK`。

★ 这就是「卡」被治好的**证据**。

- [ ] **Step 2: 跑受影响的既有探针**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/replica_ghost_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/preview_visibility_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_replica_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_host_water_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_host_enemy_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
"$GODOT" --headless --path . --quit-after 30000 res://tests/brawl_rollback_probe.tscn
"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
"$GODOT" --headless --path . -s res://tests/snapshot_size_probe.gd
"$GODOT" --headless --path . -s res://tests/player_contract_smoke.gd
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
"$GODOT" --headless --path . -s res://tests/team_room_smoke.gd
```
Expected（逐条 grep 文本）：
- `replica_ghost_probe` → `ALL-OK`,对照读数仍是「在位 0 回滚」——★ **这是 `_placed` 的守卫**：漏了 `_placed` 会让它变成 1。
- `preview_visibility_probe` → `ALL-OK`
- `squash_replica_probe` → `ALL-OK`（**本方案不删副本形变,故它的四相 squash 断言应原样通过**）。★ 若它红在"位置/读数"上，那是本改动动的面，报回来；若红在"squash 相"上，说明形变被误删了。
- `squash_stretch_probe` → `ALL-OK`（含三条像素包围盒读数）
- `squash_host_water_probe` / `squash_host_enemy_probe` → `ALL-OK`
- `ground_client_probe` → `ALL-OK`
- `brawl_rollback_probe` → `ALL-OK`
- `squash_stretch_smoke` → `ALL-OK`（**不应**出现 `set_landing_only` 相关的 ⑩b/⑩c —— 那两条属于乙,本方案没做）
- `snapshot_size_probe` → 只打印不断言，`[size]` 那几行仍在
- `player_contract_smoke` → `CONTRACT OK`
- `enemy_logic_smoke` → `SMOKE OK`
- `team_room_smoke` → `ALL-OK`

★ `tests/snapshot_interp_smoke.gd` 与 `core/net/snapshot_interp.gd` 已删 —— 若还有别处引用，上面会红。

---

## Task 4: CLAUDE.md 文档同步

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 只改「副本位置」相关的描述**

改动全在 `CLAUDE.md` **第 245 行**（那一行很长，是 `- 客户端流程:…` 那条），共两处：

**(a)** 把 `**只减小分歧不消除**(副本位置是插值、落后约一 tick),` 改为：

```
**只减小分歧不消除**(副本位置比权威平滑落后一点),
```

**(b)** 把该行**末尾**整段（从 `**副本位置插值(重要)**:` 到行尾的 `…「看不见」)。`）替换为：

```
**副本位置平滑(重要)**:`player_replica` 位置走**自身差分指数追赶** —— 每帧把目标(`_opponent_canonical` 锚到本地玩家最近副本)与当前渲染位置**各锚进同一副本空间**,再按 `1 - exp(-INTERP_RATE·Δ)`(`INTERP_RATE = 12.0`,取自 2026-09-03 的 `aa1d8f0^`,刻意复用旧值不新调参)收敛;首次定位由 `_placed` **直落**(副本创建在世界原点,开场就追赶会让幽灵体十几帧停在错位置 → 白回滚一次,`replica_ghost_probe` 实测 rb=0→1)。姿态/朝向/aim/倒地/武器仍按最新快照即时,只有位置平滑。★★ **两个 `anchor_to_nearest` 是承重的** —— 旧方案当年有致命缺陷:渲染位置与目标相隔整幅地图时最短向量=0,副本一旦落远副本就永远留在那 → 对手渲染到屏幕外「看不见」;解法是把**目标**锚到最近副本再以普通差量追赶,与「平滑 vs 插值」无关,**别顺手简化掉**。★ 2026-09-22 用户裁定**从「双快照 tick 域 alpha 插值」改回本方案**:插值那条路在 60fps 渲染 + 60Hz 快照下渲染时钟恰好落在 `latest`、`sample()` 走冻结支 ⇒ 画的就是最新包原值,到达抖动 8/25ms 时 **49.6% 的帧零位移 / 50.4% 走两步**(用户报「位置一跳一跳,看起来敌方掉帧」)。`core/net/snapshot_interp.gd` 与 `tests/snapshot_interp_smoke.gd` 已随之删除。守卫 `tests/replica_smoothness_probe.tscn`(零位移占比 / 单帧最大位移 / 跨接缝不卡远副本)。
```

★★ **绝对不要**把 `6e2ef6d` 里**乙/丙**那两段文字抄进来 —— 也就是**不要**写「副本形变整体删除」「`set_landing_only`」「形变只在单机生效」。本方案没做那两件事，抄进来会让 CLAUDE.md 与实物相反。

- [ ] **Step 2: 登记保留项**

在同一节补一句：**形变（含副本形变与参数 `0.06/16.0/0.10`）本轮刻意未动**；小地图、色相/队色、副本枪口折叠（`9239469`）同样未动。这样后来者不会以为「画面回退」是整批。

- [ ] **Step 3: 核对无残留**

Run:
```bash
grep -rn "snapshot_interp\|SnapshotInterp\|_interp\b" --include=*.gd --include=*.tscn --include=*.md . | grep -v "^./docs/superpowers/plans/2026-09-22"
```
Expected: 除本计划文档与历史计划/报告外，**生产代码与 CLAUDE.md 里一处都没有**。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md
git commit -m "docs: 副本位置改回指数追赶(形变与小地图/色相等本轮未动)"
```

---

## 验收

- [ ] `tests/replica_smoothness_probe.tscn` → `ALL-OK`，相A 零位移占比 ≈ 0、相B `|Δx| ≈ 0`
- [ ] `tests/replica_ghost_probe.tscn` → `ALL-OK` 且回滚数仍是 0（`_placed` 在位）
- [ ] 三种多人模式**实机各开一局**（1v1 / 3v3 / 大乱斗），确认对手不再「一跳一跳」—— 探针量的是位置平滑，**观感要你自己确认**
- [ ] 单机跑一局，确认形变仍在（本方案没碰它）
