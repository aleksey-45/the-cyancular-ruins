# 清理批次实施计划（小地图圆形化 / 单机播报删除 / 武器偏移 / 枪械解卡）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-09-17-cleanup-batch-design.md` 落地四条互相独立的小改动。

**Architecture:** 四条各自闭环、各自可独立提交与验收，**顺序任意**（Task 5 与 Task 6 与其余三条毫无交集；Task 2/3/4 都碰 `weapon_pickup.gd`，按编号顺序做即可避免冲突）。唯一的新抽象是 `core/sim/unstick.gd`（纯静态、`-s` 可测）。

**Tech Stack:** Godot 4.7.1 标准版（GDScript）、`.cyrm` 环面地图、CanvasItem 着色器、`tests/*.gd` 冒烟（`-s`，`extends SceneTree`）与 `tests/*.tscn` 场景探针（`extends Node/Control`，`--quit-after N`）。

## Global Constraints

- **本项目约定：测试由用户自己跑，不要代跑。** 计划里每条 `Run:` 命令是**写给用户**的；执行的 agent 只负责改代码，除非用户明确说"你跑一下"，否则**不要**执行那些命令。agent 能自己做的只有 `node level_editor/sync-enemies.js`（生成器，不是测试）与 `--import`（刷新类缓存）。
- **引擎路径**：`$GODOT` = console 版（环境变量未设时回落 `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`）。本仓 `tests/*.sh` 一律 `source tests/env.sh` 取它。
- **新建 `class_name` 文件后必须先刷类缓存**：加载项目时用 `--import`，否则引用处 Parse Error（`Could not resolve class Unstick`）。
- **`-s` 冒烟必须写空载守卫**：`load()` 之后立刻 `if X == null: print(...); quit(1); return` —— `_initialize()` 里抛错就走不到 `quit()`，进程**永久挂起**（不是干净失败，是超时）。
- **场景探针的 `--quit-after` 一律给 3600 帧**；`--quit-after` 的单位是**帧**不是秒；它是安全网，只在探针挂住时才用得上。
- **判据必须是 grep 文本 `ALL-OK` / `OK`**，不能只看退出码（中途报错时 `--quit-after` 仍 exit 0）。
- **提交信息里的引号**：用单引号或 `git commit -F 文件`，别在双引号里放反引号/`$`（会被 shell 静默吞掉）；提交后回读一遍。
- **字号只用 16 的倍数**（`kh_l4/kh_l5` 会扫 `res://tests`，新加的源码里不许出现非 16 倍数的字号载体字面量）。
- 每次提交只 `git add` 本任务提到的文件；工作区里有个未跟踪的 `_crashtest/`，**不要动它**。

---

## 文件结构（本次涉及的全部文件）

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `core/sim/tile_query.gd` | 修改 | 新增 `topmost_solid_row()` —— "矩形覆盖的格里最靠上的实心行" |
| `core/sim/unstick.gd` | **新建** | `Unstick.push_up_dy()` —— "向上挤出所需的最小位移"策略 |
| `core/sim/unstick.gd.uid` | 引擎生成 | 随 `--import` 出，一并提交 |
| `tests/unstick_smoke.gd` (+`.uid`) | **新建** | `-s` 冒烟：解卡语义（含"对齐贴墙不算卡"） |
| `scenes/weapons/weapon_pickup.gd` | 修改 | 接上解卡；A4：视觉中心 = body 原点，删 `visual_offset` |
| `scenes/weapons/m82a1.tscn` | 修改 | A1：根节点偏移归零 |
| `server/match_ground.gd` | 修改 | A4 调用点改 `canonical_pos` |
| `scenes/level_0.gd` | 修改 | A4 调用点改 `canonical_pos` |
| `scenes/pvp_match_client.gd` | 修改 | A4 调用点改 `canonical_pos` |
| `ui/combat_feedback.gd` | 修改 | 删单机播报触发链 + 敌人显示名 |
| `scenes/enemies/enemy_base.gd` | 修改 | 删 `notify_enemy_killed` 调用 |
| `scenes/enemies/enemy_spawner.gd` | 修改 | 删显示名表与 `display_name_of` |
| `data/enemies.json` | 修改 | 删 `display_name` 字段 |
| `level_editor/sync-enemies.js` | 修改 | 删该字段的手抄 |
| `level_editor/structure-editor.html` | 重新生成 | 内嵌注册表（跑 sync 脚本产出） |
| `core/sim/explosion.gd` | 修改 | 敌人分支归因 → `hit_marker` |
| `scenes/weapons/laser_weapon_base.gd` | 修改 | `_apply_to_enemy` 归因 → `hit_marker` |
| `scenes/weapons/bullet_base.gd` | 修改 | 删 `_register_player_hit`，三处改 `hit_marker` |
| `ui/minimap.gd` | 重写绘制层 | 圆形、以玩家为中心、敌人点按范围过滤 |
| `ui/minimap_circle.gdshader` (+`.uid`) | **新建** | 圆形裁剪 + 环面 `repeat_enable` 采样 |
| `tests/minimap_circle_probe.tscn/.gd/.uid` | **新建** | 真渲染探针：圆形裁剪 / 敌人范围 / 跨接缝 |
| `tests/feedback_probe.gd` | 修改 | 单机播报段落改写 |
| `tests/ground_action_probe.gd` | 修改 | ⓪ 相判据收成 `pos == 判定圆心` |
| `tests/level0_weapon_scatter_probe.gd` | 修改 | 去掉 `visual_offset` 补偿 |
| `tests/ground_client_probe.gd` | 修改 | `visual_center()` → `canonical_pos` |
| `tests/weapon_pickup_probe.gd` | 修改 | 新增"碰撞箱在原点"断言 |
| `CLAUDE.md` | 修改 | 四节同步 |

---

## Task 1: `TileQuery.topmost_solid_row` + `Unstick` + 冒烟

**Files:**
- Modify: `core/sim/tile_query.gd`
- Create: `core/sim/unstick.gd`
- Test: `tests/unstick_smoke.gd`, `tests/unstick_smoke.tscn`? —— **不需要 tscn**，`extends SceneTree` 用 `-s` 跑

**Interfaces:**
- Consumes: `MazeGenerator.current_grid`、`TileDefs.is_blocked`、`TileDefs.load_defs()`
- Produces:
  - `TileQuery.topmost_solid_row(rect: Rect2, ts: int) -> int`
  - `Unstick.push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float`

- [ ] **Step 1: 写失败的测试 `tests/unstick_smoke.gd`**

```gdscript
extends SceneTree

# 解卡(向上挤)冒烟:对齐贴墙不算卡 / 最小位移 / 嵌墙 / 上方也堵 / 空网格。
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/unstick_smoke.gd
# 通过 = `UNSTICK OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 最容易错的一条是**"正贴着墙/地"不得判为卡住**:TileQuery 的格范围是
#   floori(rect.end / ts) 且**含端点**,一个正好 64 宽、正好对齐格线的矩形会多算进
#   右边那一列 —— 若那一列是墙,它每帧都会"解卡"往上弹一下(而且不报错)。
#   `PROBE_INSET` 内缩就是为了这条。

const TS := 64

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


# rows×cols 的网格:默认全空,再把 solid_rows 里的行填成实心砖。
# ★ 必须用**带类型**的 Array[Array] / Array[int]:MazeGenerator.current_grid 是
#   `static var current_grid: Array[Array]`,把无类型的 Array 赋给它会在运行期报类型错。
#   同款写法见 tests/beam_trace_smoke.gd 的 _make_grid。
func _grid(rows: int, cols: int, solid_rows: Array) -> Array[Array]:
	var g: Array[Array] = []
	for y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.SOLID if solid_rows.has(y) else MazeGenerator.EMPTY)
		g.append(row)
	return g


func _initialize() -> void:
	var U: GDScript = load("res://core/sim/unstick.gd")
	# ★ 空载守卫:load() 失败还往下走会抛错,而 -s 抛错走不到 quit() → 永久挂起
	if U == null:
		print("UNSTICK FAILED: 找不到 core/sim/unstick.gd")
		quit(1)
		return
	TileDefs.load_defs()   # is_blocked 依赖属性表,不自带惰性加载

	# ── ① 正踩在地板上沿(600..640,地板行 10 从 640 起)→ 不卡 ──
	MazeGenerator.current_grid = _grid(20, 20, [10])
	var resting := Rect2(300.0, 600.0, 40.0, 40.0)
	_check(U.push_up_dy(resting, TS) == 0.0,
			"正踩在地板上沿不得判为卡住(实际 %f)" % U.push_up_dy(resting, TS))

	# ── ② 正好 64 宽、正好对齐格线地嵌在 1 格宽竖井里(左右都是墙)→ 不卡 ──
	# 竖井 = 第 5 列(x 320..384)。矩形 x 320..384:不加内缩时 floori(384/64)=6
	# 会把第 6 列(实心)也算进去 → 误判成卡住。这一条专门钉内缩。
	var shaft := _grid(20, 20, [])
	for y in range(20):
		shaft[y][4] = MazeGenerator.SOLID
		shaft[y][6] = MazeGenerator.SOLID
	MazeGenerator.current_grid = shaft
	var in_shaft := Rect2(320.0, 320.0, 64.0, 64.0)
	_check(U.push_up_dy(in_shaft, TS) == 0.0,
			"正好对齐并贴着竖井两侧墙不得判为卡住(实际 %f)" % U.push_up_dy(in_shaft, TS))

	# ── ③ 压进地板 20px → **刚好**擦出去 20px(不是整格 64)──
	MazeGenerator.current_grid = _grid(20, 20, [10])
	var sunk := Rect2(300.0, 620.0, 40.0, 40.0)     # 620..660,地板行 10 = 640..704
	_check(absf(U.push_up_dy(sunk, TS) - 20.0) < 0.01,
			"压进地板 20px 应上移 20px(实际 %f)" % U.push_up_dy(sunk, TS))

	# ── ④ 嵌在 8/9/10 三行实心里 → 推到最上行(8)的上边 ──
	# 矩形 500..540:覆盖行 7、8;最上实心行 = 8 → 位移 = 540 - 8*64 = 28
	MazeGenerator.current_grid = _grid(20, 20, [8, 9, 10])
	var buried := Rect2(300.0, 500.0, 40.0, 40.0)
	_check(absf(U.push_up_dy(buried, TS) - 28.0) < 0.01,
			"嵌墙时推到最上实心行的上边(实际 %f)" % U.push_up_dy(buried, TS))

	# ── ⑤ 全实心 → 迭代到上限仍返回累计值,不崩不挂 ──
	MazeGenerator.current_grid = _grid(20, 20, range(0, 20))
	var dy_all: float = U.push_up_dy(resting, TS)
	_check(dy_all > 0.0, "全实心时也应有位移(实际 %f)" % dy_all)

	# ── ⑥ 空网格 → 0(TileQuery 的空网格语义:一律"没压到东西")──
	var empty: Array[Array] = []
	MazeGenerator.current_grid = empty
	_check(U.push_up_dy(sunk, TS) == 0.0, "空网格应返回 0")

	if _fail == 0:
		print("UNSTICK OK")
		quit(0)
	else:
		print("UNSTICK FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑一次确认它红**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/unstick_smoke.gd`
Expected: `UNSTICK FAILED: 找不到 core/sim/unstick.gd`，退出 1。

- [ ] **Step 3: 给 `core/sim/tile_query.gd` 加 `topmost_solid_row`**

在 `rect_overlaps_solid_or_liquid()` 与 `_overlaps()` 之间插入（**`_overlaps` 与三个既有调用方一律不动**）：

```gdscript
# 矩形覆盖的格中**最靠上**的那一行实心格的**行号**(格坐标,**未取模**;无 → -1)。
# 「向上挤出」(core/sim/unstick.gd)靠它算"刚好清空"的最小位移 —— 只判 bool 是不够的。
# ★ 与 _overlaps 是同一套格范围骨架(两端 floori + 逐格 posmod),改一处要一起改。
static func topmost_solid_row(rect: Rect2, ts: int) -> int:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return -1
	var rows := grid.size()
	var cols := grid[0].size()
	var x0 := floori(rect.position.x / ts)
	var x1 := floori(rect.end.x / ts)
	var y0 := floori(rect.position.y / ts)
	var y1 := floori(rect.end.y / ts)
	# gy 升序 → 第一个命中的就是最靠上的那一行
	for gy in range(y0, y1 + 1):
		var ry := posmod(gy, rows)
		for gx in range(x0, x1 + 1):
			if TileDefs.is_blocked(grid[ry][posmod(gx, cols)]):
				return gy
	return -1
```

同时把文件头的说明补一句（在第一段说明里加一行）：`本类另提供 topmost_solid_row()：「压在哪一行」，供向上挤出用。`

- [ ] **Step 4: 写 `core/sim/unstick.gd`**

```gdscript
class_name Unstick
extends RefCounted

# 「把一个压进实心格的矩形向上挤出去」的单一来源。纯静态、不引 autoload(格尺寸由参数传入,
# 同 core/tile_query.gd / core/collision_aabb.gd 的约定),故 `-s` 可 load。
#
# 目前只有地面武器(scenes/weapons/weapon_pickup.gd)在用 —— 贴墙丢弃、或停稳后
# 可破坏砖被重铺盖在它身上时会嵌进实心格。EnemyFlyBase 的"向下逃逸"是另一套
# (只在 A* 空路径时触发、且方向相反),日后要接同一套可复用本类。
#
# ★ 为什么不整格跳:一格 = 64 世界像素,轻微嵌进去就弹一整格,视觉上很突兀,
#   也会让"落点与何时开始模拟无关"这条联机地基更难对(两端嵌入深度可能不同)。
#   本类每步只推"刚好清空当前最靠上那一行"的量。

const PROBE_INSET := 0.5   # 探测矩形四边内缩(像素)


# 返回把 rect 向上推出实心格所需的**最小位移**(≥0;0 = 没卡住)。
# max_cells 同时是迭代上限与"最多推几格"的安全阀(被推上去可能又贴到更上面的墙 --
# 那是收敛,不是死循环;上限到了就返回累计值,不崩)。
static func push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float:
	if ts <= 0:
		return 0.0
	var total := 0.0
	for _i in range(max_cells):
		var cur := Rect2(rect.position - Vector2(0.0, total), rect.size)
		# ★ 内缩不能省:TileQuery 的格范围是 floori(rect.end / ts) 且**含端点**,
		#   一个正好 64 宽、正好对齐格线的矩形会把右边那一列也算进去 —— 那一列若是墙,
		#   每帧都会判成"卡住"往上弹。内缩还顺带保证下面 need 恒 ≥ PROBE_INSET。
		var probe := cur.grow(-PROBE_INSET)
		if probe.size.x <= 0.0 or probe.size.y <= 0.0:
			return total
		var top := TileQuery.topmost_solid_row(probe, ts)
		if top < 0:
			return total
		# 把框底推到那一行的上边。取**最靠上**的行 → 它 ×ts 最小 → need 最大 →
		# 一步就清掉当前所有被压的行。
		var need := cur.end.y - float(top) * float(ts)
		if need <= 0.0:
			return total
		total += need
	return total
```

- [ ] **Step 5: 刷类缓存**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 `Could not resolve class` 报错；生成 `core/sim/unstick.gd.uid`。

- [ ] **Step 6: 跑冒烟确认绿**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/unstick_smoke.gd`
Expected: `UNSTICK OK`，退出 0。

- [ ] **Step 7: 提交**

```bash
git add core/sim/tile_query.gd core/sim/unstick.gd core/sim/unstick.gd.uid tests/unstick_smoke.gd tests/unstick_smoke.gd.uid
git commit -m 'feat(sim): Unstick 向上解卡(纯逻辑)+ TileQuery.topmost_solid_row + 冒烟'
```

---

## Task 2: `WeaponPickup` 接上解卡

**Files:**
- Modify: `scenes/weapons/weapon_pickup.gd`（`_physics_process` 两处 + 新私有函数）
- Test: 由 Task 1 的 `unstick_smoke` 覆盖纯逻辑；本任务的接入由 `tests/level0_weapon_scatter_probe` 与 `tests/weapon_pickup_probe` 连带覆盖

**Interfaces:**
- Consumes: `Unstick.push_up_dy(rect, ts, max_cells)`、`CollisionAabb.has_any(n)`、`CollisionAabb.world_rect(n)`
- Produces: `WeaponPickup._unstick_up() -> bool`（私有）

- [ ] **Step 1: 抽出 `_recompute_canonical()`**

`_physics_process` 里那段"物理走出来的是世界坐标，取模回 canonical"要被解卡复用，先抽成函数。把现有 :154-162 整段替换为 `_recompute_canonical()`，并新增：

```gdscript
# 物理/解卡动过位置之后,把世界坐标取模回 canonical。渲染位置再由它锚到玩家最近副本
# (两者分工见 canonical_pos 的字段注释)。
func _recompute_canonical() -> void:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if w > 0.0 and h > 0.0:
		canonical_pos = Vector2(fposmod(global_position.x, w), fposmod(global_position.y, h))
	else:
		canonical_pos = global_position
```

- [ ] **Step 2: 写 `_unstick_up()`**

```gdscript
# 嵌进实心格(贴墙丢弃、或停稳后可破坏砖被重铺盖在它身上)→ 向上挤出去。
# ★ 为什么在 _settled 分支也要调:停稳后 `move_and_slide` 再也不跑(见 _physics_process
#   的早退),被后盖上的墙压住会**永久钉死**,连 Godot 内建的 penetration recovery 都不触发。
# 返回是否真的动过。
func _unstick_up() -> bool:
	if not CollisionAabb.has_any(self):
		return false        # 没有碰撞体就没东西可挤(精灵全透明等)
	# 几何来源统一走 CollisionAabb(已含 body 的 scale),不自己再拼一遍
	var dy := Unstick.push_up_dy(CollisionAabb.world_rect(self), GameParameters.TILE_SIZE)
	if dy <= 0.0:
		return false
	global_position.y -= dy
	velocity.y = 0.0
	_settled = false        # 解掉停稳,让重力重新接管(可能被推进了空中)
	_recompute_canonical()
	return true
```

- [ ] **Step 3: 在两处调用**

`_physics_process` 改成（只列改动后的全貌）：

```gdscript
func _physics_process(delta: float) -> void:
	_age += delta
	if _settled:
		# 停稳后**位置**不变,但**锚点**在变(玩家在动、可能绕过接缝)——
		# 不在这儿补一次的话,跨接缝时停稳的枪会留在旧副本上"消失"。
		# ★ 解卡也在这儿:停稳后 move_and_slide 不再跑,被后盖上的墙压住只能靠它。
		_unstick_up()
		sync_render_from_canonical()
		return
	velocity.y += PlayerParams.weapon_fall_gravity * delta
	if is_on_floor():
		velocity.x *= exp(-PlayerParams.weapon_ground_friction * delta)
	else:
		velocity.x *= exp(-PlayerParams.weapon_air_drag * delta)
	move_and_slide()
	_recompute_canonical()
	_unstick_up()
	sync_render_from_canonical()
	# ★ 停止必须是"速度阈值置零"而不是"滑固定时长":前者让**落点与何时开始模拟无关** ——
	#   这是联机端"客户端晚一个 RTT 才收到事件、却要落在同一位置"的前提。
	#   改成按时间停 → 两端落点发散 → 出现"看着够不着/看着够得着"。
	if is_on_floor() and absf(velocity.x) < PlayerParams.weapon_stop_eps:
		velocity = Vector2.ZERO
		_settled = true
```

- [ ] **Step 4: 编译自检**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error。

- [ ] **Step 5: 提交**

```bash
git add scenes/weapons/weapon_pickup.gd
git commit -m 'fix(weapon): 地面武器嵌进实心格时向上挤出(含停稳后被盖住的情形)'
```

---

## Task 3: A1 —— m82a1 根节点偏移归零

**Files:**
- Modify: `scenes/weapons/m82a1.tscn`
- Test: `tests/muzzle_probe.gd` / `tests/aim_probe.gd` / `enemy_logic_smoke.gd` 的枪口断言（钉的是榴弹发射器，**预期不动**）

**Interfaces:**
- Consumes: 无
- Produces: 六把武器的根节点**全部**是零变换（后续 Task 4 与将来的视觉代码可以假定这一点）

- [ ] **Step 1: 改 `scenes/weapons/m82a1.tscn`**

三处，逐字：

- 根节点 `[node name="M82A1" type="Node2D" ...]` 下面的 `position = Vector2(6, 3)` 这一行 **删掉**。
- `Sprite2D` 的 `position = Vector2(18, 6)` → `position = Vector2(24, 9)`（= `(6,3) + (18,6)`）。
- `Muzzle` 的 `position = Vector2(48, 2)` → `position = Vector2(54, 5)`（= `(6,3) + (48,2)`）。

为什么这么算：`position` 与 `offset` 只在精灵自身 `rotation` 为 0 时等价（见 spec §3.1），本作枪的朝向镜像与瞄准俯仰都写在**武器根节点**上，所以把根偏移折进子节点的 `position`、再让根归零，在俯仰角 0 时**逐像素一致**。

- [ ] **Step 2: 确认其余五把没被动过**

Run: `git diff --stat scenes/weapons/`
Expected: 只有 `m82a1.tscn` 一个文件。

- [ ] **Step 3: 让用户跑枪口/瞄准三个探针**

Run（**让用户跑**）：
```bash
timeout 120 "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/muzzle_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/aim_probe.tscn
```
Expected: 三个都打印各自的 `ALL-OK` / `SMOKE OK`。（它们钉的是榴弹发射器的枪口 `(31,8)`，本次不动 m82a1 以外的枪，所以**预期全绿**。若 m82a1 出现在某个硬编码里，按新值 `(54,5)` 更新那条断言 —— 那是探针跟不上重构，不是回退重构。）

- [ ] **Step 4: 提交**

```bash
git add scenes/weapons/m82a1.tscn
git commit -m 'refactor(weapon): m82a1 根节点偏移折进 Sprite2D/Muzzle,六把枪根节点全归零'
```

---

## Task 4: A4 —— 地面态 body 原点 = 枪的可视中心，删 `visual_offset`

**Files:**
- Modify: `scenes/weapons/weapon_pickup.gd`（`_build_collision`、删字段与 `visual_center()`）
- Modify: `server/match_ground.gd`、`scenes/level_0.gd`、`scenes/pvp_match_client.gd`
- Modify: `tests/ground_action_probe.gd`、`tests/level0_weapon_scatter_probe.gd`、`tests/ground_client_probe.gd`、`tests/weapon_pickup_probe.gd`

**Interfaces:**
- Consumes: `SpriteBounds.from_sprite(spr) -> Rect2`（语义**不变**，仍以 sprite 局部原点为参考、不含 `spr.offset`）
- Produces: `WeaponPickup.canonical_pos` **就是**视觉中心；`visual_offset` 与 `visual_center()` **不再存在**

- [ ] **Step 1: 改 `_build_collision()` —— 视觉中心挪到 body 原点**

替换现有 `_build_collision()` 的函数体为：

```gdscript
func _build_collision() -> void:
	var vis := get_node_or_null("Visual")
	if vis == null:
		return
	var spr: Sprite2D = vis.get_node_or_null("Sprite2D")
	if spr == null:
		return
	var r: Rect2 = SpriteBounds.from_sprite(spr)
	if r.size == Vector2.ZERO:
		return
	# ★ 把"画出来的枪中心"挪到 body 原点:渲染位置 / 碰撞箱 / 拾取判定圆心从此**天然重合**,
	#   不需要任何补偿(原先靠 visual_offset 把判定圆心搬回视觉中心)。
	#   gun_center 必须带上**武器根节点自己**的 position —— 漏它正是 m82a1 判定圆心
	#   偏 (6,3)×WORLD_SCALE 世界像素的成因(拾取半径才 64px)。
	#   本行在 _build_visual 之后跑,故 vis.position 此刻还是 tscn 里那份。
	var gun_center := vis.position + spr.position + r.position + r.size * 0.5
	vis.position -= gun_center
	var cs := CollisionShape2D.new()
	cs.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = r.size
	cs.shape = rect
	cs.position = Vector2.ZERO      # 视觉中心已在原点
	add_child(cs)
```

- [ ] **Step 2: 删 `visual_offset` 与 `visual_center()`**

删掉字段声明（现 :41-44 那三行注释 + `var visual_offset: Vector2 = Vector2.ZERO`）与 `visual_center()`（现 :136-138）。`canonical_pos` 的字段注释里补一句：

```gdscript
# ★ 本值**就是**这把枪看起来所在的位置:视觉中心已在 _build_collision 里被挪到节点原点,
#   渲染、碰撞箱、拾取判定圆心三者重合,不存在"第二个中心"(2026-09-17 前有一个
#   visual_offset 把它们分开,已删)。
```

- [ ] **Step 3: 改三个生产调用点**

`server/match_ground.gd`：

- :89 `e["pos"] = (n as WeaponPickup).visual_center()` → `e["pos"] = (n as WeaponPickup).canonical_pos`
- :119 `pk.canonical_pos = p.global_position - pk.visual_offset` → `pk.canonical_pos = p.global_position`，并把上面 :116-118 那段"反着减 visual_offset"的注释整段删掉。
- :123 `near["pos"] = pk.visual_center()` → `near["pos"] = pk.canonical_pos`
- `_canonical_of()`（:126-142）的注释改写为："`entries[].pos` 与 `canonical_pos` 现在是**同一个东西**（视觉中心即节点原点），此处保留取节点的写法只是为了拿"活节点的权威值"并对陈旧条目留痕。" 兜底 warning 改成 `"MatchGround._canonical_of: inst %d 没有活节点,退回表里的 pos(可能与实际落点不符)"`。
- `ground_weapons_payload()`（:145-155）与 `_broadcast_weapon_spawned()`（:158-172）的注释里凡是指向"visual_offset / 两个中心"的话一并改写；**代码一行不动**（`_canonical_of(inst)` 照用）。

`scenes/level_0.gd`：
- :633 `e0["pos"] = pk0.visual_center()` → `= pk0.canonical_pos`
- :646 `pk.visual_center()` → `pk.canonical_pos`

`scenes/pvp_match_client.gd`：
- :330 `e["pos"] = pk.visual_center()` → `= pk.canonical_pos`
- :352 `GridPathfinder.toroidal_delta_px(pk.visual_center(), lp, w, h)` → `pk.canonical_pos`

- [ ] **Step 4: 改四个探针**

`tests/ground_action_probe.gd` 的 ⓪ 相：`bad_center` 那条的判据改成"载荷 pos == 服务器判定表里的 pos"：

```gdscript
		if (e["pos"] as Vector2).distance_to(entry["pos"] as Vector2) > 0.5:
			bad_center += 1
	_check(bad_center == 0,
			"载荷 pos == 服务器判定圆心(%d/%d 不符)—— 视觉中心已是节点原点,两者必须同一个值" % [bad_center, checked])
```
并把该相函数上方的注释块里"差整整一个 offset"那段的时态改成过去式（"2026-09-17 前两者差一个 visual_offset，现已合并"）。

`tests/level0_weapon_scatter_probe.gd`：
- :174 `(player as Node2D).global_position = target.global_position + target.visual_offset` → `= target.global_position`
- :185-187 的调试打印去掉 `pk.visual_center()`，改成打印 `canonical_pos` 与 `global_position`
- :215 `= anchor_pk.global_position + anchor_pk.visual_offset` → `= anchor_pk.global_position`

`tests/ground_client_probe.gd`：:112 `_local.global_position = pk.visual_center()` → `= pk.canonical_pos`

`tests/weapon_pickup_probe.gd`：`_phase_collision_shape()` 里已有 `pk` 与 `cs` 两个局部变量，在 `if cs != null and cs.shape is RectangleShape2D:` 那个分支内、`_check(sz.x > 4.0 …)` 之后追加一行：

```gdscript
		# ★ A4(2026-09-17):视觉中心已被挪到 body 原点 → 碰撞箱必须在 Vector2.ZERO。
		#   这条同时钉住 m82a1 那个"根节点偏移没被算进判定圆心"的历史 bug 不再回来。
		_check(cs.position == Vector2.ZERO,
				"碰撞箱须在节点原点(实际 %s)" % str(cs.position))
```

- [ ] **Step 5: 让用户跑武器侧四个探针**

Run（**让用户跑**）：
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_pickup_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn
"$GODOT" --headless --path . -s res://tests/sprite_bounds_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
```
Expected: 四个各自 `ALL-OK` / `OK`。`sprite_bounds_smoke` **预期不动**（`SpriteBounds` 本次不改）。

- [ ] **Step 6: 提交**

```bash
git add scenes/weapons/weapon_pickup.gd server/match_ground.gd scenes/level_0.gd scenes/pvp_match_client.gd tests/ground_action_probe.gd tests/level0_weapon_scatter_probe.gd tests/ground_client_probe.gd tests/weapon_pickup_probe.gd
git commit -m 'refactor(weapon): 地面武器视觉中心=节点原点,删掉 visual_offset 整套补偿'
```

---

## Task 5: 删除单机击杀播报（连带清理）

**Files:**
- Modify: `ui/combat_feedback.gd`、`scenes/enemies/enemy_base.gd`、`scenes/enemies/enemy_spawner.gd`、`data/enemies.json`、`level_editor/sync-enemies.js`
- Regenerate: `level_editor/structure-editor.html`
- Modify: `core/sim/explosion.gd`、`scenes/weapons/laser_weapon_base.gd`、`scenes/weapons/bullet_base.gd`
- Modify: `tests/feedback_probe.gd`

**Interfaces:**
- Consumes: 无（纯删除）
- Produces: `CombatFeedback` 保留的公开面 = `spawn(host)` / `hit_marker()` / `kill(who)` / `reset_streak()` / `attribute(victim, attacker)` / `attribute_hit(victim, attacker)` / `ATTRIB_WINDOW_MS` / `current`。**`notify_enemy_killed` 与 `enemy_display_name` 不存在了。**

- [ ] **Step 1: 摘掉 `ui/combat_feedback.gd` 的单机触发链**

- 删 `notify_enemy_killed()`（现 :80-95）与 `enemy_display_name()`（现 :98-104）两个函数，连同它们的 doc 注释块。
- `kill()` 的 doc 注释里"w 单机由 notify_enemy_killed 算出来"之类的话删掉，改成"who = 被击杀者显示名（PvP 由 `kill_event` 载荷给出）"。
- `reset_streak()` 的注释里"单机仅按时间窗清零"删掉（单机不再有连杀）。
- `attribute()` 的注释里"供 `notify_enemy_killed` 读"→"供 `RoyaleHost._attributed_killer` 读（大乱斗计分）"；"必须写在**伤害调用之前**"那条纪律保留但把理由改成归因读取者（`royale_host` 的倒地边沿）而不是播报。
- `attribute_hit()` 的注释同理改写。
- 文件头第 4 行"屏幕中心 FPS 式命中 X 标记 +「击杀 XXX」像素播报"保留（PvP 仍两者都有）。

- [ ] **Step 2: 摘掉 `EnemyBase` 的调用**

`scenes/enemies/enemy_base.gd` 删掉 :236-238 三行：

```gdscript
	# 击杀播报(CombatFeedback):只有玩家造成的死亡才出「击杀 XXX」文字+音效
	# (子弹/爆炸命中时写入的 last_damager meta 归因;溺水等环境死安静销毁)
	CombatFeedback.notify_enemy_killed(self)
```

- [ ] **Step 3: 摘掉敌人显示名链**

`scenes/enemies/enemy_spawner.gd`：
- 删 `static var DISPLAY_NAMES: Dictionary = {}` 那一行及其注释。
- 删 `display_name_of()` 整个函数（现 :15-24）。
- `_load_registry()` 里删 `DISPLAY_NAMES = {}`（现 :29）与 `DISPLAY_NAMES[scene_path] = ...`（现 :43）两行。
- `TYPES` 的注释里"两张表一起填"改成"一张表"。

`data/enemies.json`：删 3 条记录里的 `"display_name": "…",`。

`level_editor/sync-enemies.js`：删 map 里的 `display_name` 那 3 行（注释 + 赋值）。**`NOT_IN_EDITOR` 键覆盖守卫保留**（现在是空数组，覆盖剩下的 4 个字段）。

- [ ] **Step 4: 重新生成编辑器内嵌注册表**

Run: `node level_editor/sync-enemies.js`
Expected: 打印 `ok: 敌人注册表已同步 jump_bird, fly_bird, black_bird`。

Run: `node level_editor/sync-enemies.js --check`
Expected: 打印 `ok: structure-editor.html 的敌人注册表与 data/enemies.json 一致(...)`，退出 0。

- [ ] **Step 5: 敌人侧归因降级为命中标记**

`core/sim/explosion.gd`（敌人分支，现 :24-27 的注释 + `CombatFeedback.attribute_hit(e, shooter)`）改成：

```gdscript
		# 命中标记(屏幕中心 X)。★ 敌人不再写 last_damager 归因 —— 那个 meta 原先的唯一
		# 读者是单机击杀播报(notify_enemy_killed),播报删除后写入即死数据。
		# 玩家分支的 attribute() 保留:大乱斗 RoyaleHost 靠它判击杀分。
		CombatFeedback.hit_marker()
```

`scenes/weapons/laser_weapon_base.gd` 的 `_apply_to_enemy()`（现 :212-216）改成：

```gdscript
	# 命中标记(X)。敌人侧不写归因 —— 见 core/sim/explosion.gd 的同款说明。
	CombatFeedback.hit_marker()
```

`scenes/weapons/bullet_base.gd`：
- 删 `_register_player_hit()` 整个函数（现 :186-192）。
- :104 的 `_register_player_hit(hit)` → `CombatFeedback.hit_marker()`，并把上面那句"★归因 meta 必须在 apply_hit 之前落盘…"的注释整段删掉。
- :109 的 `_register_player_hit(hit)   # ★同上:先写归因再结算伤害` → `CombatFeedback.hit_marker()`。
- :181 的 `_register_player_hit(hit)   # ★先写归因(Task 15):hurt 可能同帧判死并当场播报` → `CombatFeedback.hit_marker()`，`_direct_hit` 的 doc 注释里"归因"字样改掉。

- [ ] **Step 6: 改 `tests/feedback_probe.gd`**

逐条（行号按改动前的现文件）：

| 位置 | 处置 |
|---|---|
| `_mount_feedback()` :80 `_CF.notify_enemy_killed(_victim_killed_by(null))` | **删这一行**（函数已不存在；"无实例时静态入口空转"这条断言由同一段里的 `_CF.kill("无人")` / `_CF.hit_marker()` 继续覆盖） |
| `_check_marker_and_banner()` :90-111 | **整段保留**——`kill()` / `hit_marker()` / `Sfx._stream("kill")` 全都还在（PvP 在用）。一行都不用改 |
| `_check_attribution_basic()` :113-148 | **整个函数删掉**，连同 `_ready()` 里的调用与 `if _aborted: return` 两行。它的全部断言都挂在 `notify_enemy_killed` 上，函数末尾那两条显示名断言（:142-148）也随之消失 |
| `_check_writer_register_player_hit()` :150-167 | **整个函数删掉**，连同 `_ready()` 里的调用。★ 它结束后把 `bullet_scene` 置好了供后面用，删除后要**把 `bullet_scene = load("res://scenes/weapons/bullet.tscn")` 与它的空载守卫搬到 `_check_e2e_direct_hit()` 开头**（那里正好也在用 `bullet_scene`） |
| `_victim_killed_by()` :56-62 | **保留** —— `_check_attribute_entry()` :259 起还在用 |
| `_check_scene_change_idempotent()` / `_check_attribute_entry()` :246-278 | **整段保留**（换场幂等与归因写端入口都还在用） |

三个 e2e 段（`_check_e2e_direct_hit` / `_check_e2e_explosion_aoe` / `_check_e2e_laser`）的判据从"播报了击杀"改成"出了命中标记 + 敌人身上**没有**归因 meta"。以 `_check_e2e_direct_hit()` 为例，把 `_fx._kill_label.text = ""` 与末尾的播报断言换成：

```gdscript
	_fx._hit_age = -1.0                       # 清掉上一次的 X 标记,便于断言
	b2.call("_direct_hit", enemy)            # ← 真实命中路径(内部 hit_marker → hurt)
	if _fx._hit_age < 0.0:
		_failures.append("致命一击未出命中标记(_direct_hit 的反馈路径断了)")
	if enemy.has_meta("last_damager"):
		_failures.append("敌人身上不该再有 last_damager meta(单机播报的产物,已随播报删除)")
```

`_hit_age` 由 `_show_hit()` 同步置 0.0、由 `_process` 递增清零，所以**同步调用后立即判 `>= 0.0`** 是可靠的（`_check_marker_and_banner` 已经是这个读法）。另外两段同款改写（爆炸段用 `Explosion.apply_aoe(...)`、激光段用 `laser.call("_apply_beam_damage", …)`，调用行本身不动）。

文件头 :4-5 的能力说明同步：`1) 击杀播报(文本设置 + 浮现动画)` 改成 `1) 击杀播报(PvP 侧:文本设置 + 浮现动画)`，`3) 击杀归因(玩家 last_damager meta 才播报…)` 改成 `3) 归因写端(attribute/attribute_hit 只服务大乱斗计分)`。

- [ ] **Step 7: 让用户跑受影响的探针**

Run（**让用户跑**）：
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/feedback_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l4_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l6_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn
```
Expected: 全部 `ALL-OK`。**若某个探针因本次重构变红，改探针认新实现，别回退重构**（既有纪律）；只有探针确实在断言"播放了单机播报"时才把那段断言删掉。

- [ ] **Step 8: 提交**

```bash
git add ui/combat_feedback.gd scenes/enemies/enemy_base.gd scenes/enemies/enemy_spawner.gd data/enemies.json level_editor/sync-enemies.js level_editor/structure-editor.html core/sim/explosion.gd scenes/weapons/laser_weapon_base.gd scenes/weapons/bullet_base.gd tests/feedback_probe.gd
git commit -m 'refactor(feedback): 删除单机击杀播报链(触发+显示名表+敌人侧归因写入),PvP 播报保留'
```

---

## Task 6: 小地图圆形化（以玩家为中心 + 敌人范围过滤）

**Files:**
- Rewrite: `ui/minimap.gd`
- Create: `ui/minimap_circle.gdshader`
- Create: `tests/minimap_circle_probe.gd` + `tests/minimap_circle_probe.tscn`

**Interfaces:**
- Consumes: `MazeGenerator.current_grid` / `.EMPTY` / `.texture_of()` / `.wrap_to_range()`、`MazeGenerator.wrap_to_range`、`GridPathfinder.toroidal_delta_px(a, b, w, h)`（**返回 a→b**）、`GameParameters.MAP_WIDTH/HEIGHT/TILE_SIZE`、`Settings.pvp_minimap_show_enemy`
- Produces: `Minimap.setup(local_provider, enemy_provider)` / `Minimap.setup_multi(local_provider, others_provider)` —— **签名与语义不变**，两个挂载点不用改

- [ ] **Step 1: 写失败的探针 `tests/minimap_circle_probe.gd`**

```gdscript
extends Control

# 圆形小地图探针(**必须带真实渲染,不能加 --headless**)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn
# 判据: 圆外的像素仍是背景色(discard 生效)+ 圆内有地形 + 敌人点只在范围内显示。
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# ★ 判据为什么是这三个:圆形裁剪与"范围过滤"都是**数值断言抓不住**的东西 ——
#   旧实现(整图缩略贴右下角)在这三条里会挂第一条,而它看起来"功能正常"。

const OUT_DIR := "res://.superpowers/sdd"
const BG := Color(1.0, 0.0, 1.0)          # 品红背景:与地图三色都不会撞
const WALL := Color(0.62, 0.68, 0.75)     # ui/minimap.gd 里墙的颜色

var _failures: Array[String] = []
var _local := Vector2(1600.0, 1600.0)     # 玩家 canonical 位置
var _enemy := Vector2.INF


func _ready() -> void:
	Settings.pvp_minimap_show_enemy = true

	# 合成地图:125×75 全实心(整张都是墙色)。★ 尺寸必须与 GameParameters 的
	# MAP_WIDTH/HEIGHT 一致 —— 小地图的着色器把"格数"当贴图尺寸、把"世界像素"当坐标,
	# 两者不一致时圆里画的是错位的图(而断言可能照样绿)。
	var grid: Array[Array] = []
	for y in range(75):
		var row: Array[int] = []
		row.resize(125)
		row.fill(MazeGenerator.SOLID)
		grid.append(row)
	GameParameters.MAP_WIDTH = 125.0 * float(GameParameters.TILE_SIZE)
	GameParameters.MAP_HEIGHT = 75.0 * float(GameParameters.TILE_SIZE)
	MazeGenerator.current_grid = grid

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var mm := Minimap.new()
	mm.setup(func() -> Vector2: return _local, func() -> Vector2: return _enemy)
	add_child(mm)

	# ── ① 范围内的敌人点必须显示 ──
	_enemy = _local + Vector2(64.0 * 3.0, 0.0)
	await _frames(3)
	_check(mm._dot_enemy.visible, "范围内(3 格)的敌人点应显示")

	# ── ② 范围外的敌人点必须不显示 ──
	_enemy = _local + Vector2(64.0 * 60.0, 0.0)
	await _frames(3)
	_check(not mm._dot_enemy.visible, "范围外(60 格)的敌人点不得显示")

	# ── ③ 跨接缝:地图另一头、但环面距离在范围内的敌人**必须**显示 ──
	# MAP_WIDTH 取自 GameParameters;把敌人放到玩家左边整整一张图宽再回退 2 格
	var w := float(GameParameters.MAP_WIDTH)
	_enemy = Vector2(_local.x - w + 64.0 * 2.0, _local.y)
	await _frames(3)
	_check(mm._dot_enemy.visible, "跨接缝 2 格的敌人点应显示(走环面最短向量)")

	# ── ④ 取图:圆外必须还是背景色,圆内必须出现墙色 ──
	var img := await _shot("minimap_circle.png")
	if img.get_width() > 0:
		var d := _circle_geom(img)
		# 圆的**外接方框**左上角往内 4px —— 在方框内、但在圆外
		var outside := Vector2i(int(d["left"]) + 4, int(d["top"]) + 4)
		var inside := Vector2i(int(d["cx"]), int(d["cy"]))
		_check(_near(img.get_pixelv(outside), BG, 0.08),
				"圆外像素应仍是背景色(实际 %s)" % str(img.get_pixelv(outside)))
		_check(_near(img.get_pixelv(inside), WALL, 0.12),
				"圆内应画出地形(实际 %s)" % str(img.get_pixelv(inside)))

	_finish()


# 圆在屏幕上的几何:与 ui/minimap.gd 的常量保持一致
func _circle_geom(img: Image) -> Dictionary:
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r: float = Minimap.RADIUS_PX
	var cx := (1920.0 - Minimap.EDGE - r * 2.0 + r) * s.x
	var cy := (1440.0 - Minimap.EDGE - r * 2.0 + r) * s.y
	return {"cx": cx, "cy": cy, "top": cy - r * s.y, "left": cx - r * s.x}


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		_failures.append("截图 %s 写入失败(%s)" % [png_name, path])
	else:
		print("[MINIMAP] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[MINIMAP] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[MINIMAP] ✗ %s" % msg)


func _finish() -> void:
	if _failures.is_empty():
		print("MINIMAP CIRCLE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MINIMAP CIRCLE PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
```

- [ ] **Step 2: 写 `tests/minimap_circle_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/minimap_circle_probe.gd" id="1"]

[node name="MinimapCircleProbe" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次确认它红**

Run（**让用户跑**）：`"$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn`
Expected: `MINIMAP CIRCLE PROBE: FAIL`，①②④ 三条红（旧实现无范围过滤、也不是圆形）；`--quit-after` 是安全网，探针自己会 `quit()`。

- [ ] **Step 4: 写 `ui/minimap_circle.gdshader`**

```glsl
shader_type canvas_item;

// 圆形小地图的地形:以玩家所在格为中心采样地图贴图,圆外直接 discard。
// ★ 采样器开 repeat_enable:地图贴图正好是 cols×rows、四周无留白,于是 uv 越过 1.0
//   就是"绕到地图另一头" —— 环面回绕不需要铺 3×3 副本。
uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size    = vec2(1.0, 1.0);   // 格数 (cols, rows)
uniform vec2  center_cell = vec2(0.0, 0.0);   // 玩家所在格(canonical)
uniform float px_per_cell = 7.0;              // 每格多少屏幕像素
uniform float radius      = 140.0;            // 屏幕半径(像素)
uniform float ring        = 2.0;              // 圆内缘描边宽度

void fragment() {
	// 以圆心为原点的屏幕像素(V 轴向下,与 Godot 一致)
	vec2 p = UV * (2.0 * radius) - vec2(radius);
	float d = length(p);
	if (d > radius) {
		discard;
	}
	// +0.5:uv 按像素归一化,取格中心要半格偏移;越界由 repeat_enable 绕回
	vec2 uv = (center_cell + p / px_per_cell + 0.5) / map_size;
	COLOR = texture(map_tex, uv);
	if (d > radius - ring) {
		// 暗环:地图开阔区是浅灰蓝,不描边时圆形轮廓读不出来
		COLOR.rgb = mix(COLOR.rgb, vec3(0.05, 0.09, 0.13), 0.75);
	}
}
```

- [ ] **Step 5: 重写 `ui/minimap.gd`**

```gdscript
class_name Minimap
extends CanvasLayer

# 小地图(可选视觉,实验分支 KikuchiHeinr):**以玩家为中心**的圆形视野。
# 地形由 ui/minimap_circle.gdshader 画圆(圆外直接 discard),敌人点只在圆内
# (世界距离 ≤ RANGE_CELLS 格)才显示。由 pvp_client / royale_game 按设置挂载。
#
# ★ 环面:地形靠采样器 repeat_enable 免费回绕;敌人距离走 toroidal_delta_px 的
#   最短向量 —— 玩家在接缝附近时,地图另一头的敌人**其实就在身边**,直接相减会
#   把它判成"很远"而误藏。

const RADIUS_PX := 140.0    # 圆在屏幕上的半径(像素)
const RANGE_CELLS := 20.0   # 圆覆盖的世界半径(格)★ 调"圆形范围"只改这一行
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0          # 圆的外接方框距屏幕右/下边缘
const RING_PX := 2.0        # 圆内缘描边宽度

const SHADER_PATH := "res://ui/minimap_circle.gdshader"
const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)

var _local_provider: Callable = Callable()   # () -> Vector2 本地玩家世界坐标
var _enemy_provider: Callable = Callable()   # () -> Vector2 对手世界坐标(INF=无)
var _others_provider: Callable = Callable()  # 多目标(大乱斗)() -> Array[Vector2]
var _mat: ShaderMaterial = null
var _rect_pos := Vector2.ZERO
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _other_dots: Array[ColorRect] = []


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


# 大乱斗多目标版:others_provider 返回全部对手世界坐标数组
func setup_multi(local_provider: Callable, others_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider


func _ready() -> void:
	layer = 131   # 盖在 PvpHud(130) 之上、不影响输入
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	# 地形底图:墙=亮灰,水=蓝,空气=深色半透明(1 像素 = 1 格,着色器按 PX_PER_CELL 放大)
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			if v == MazeGenerator.EMPTY:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif Water.is_liquid(MazeGenerator.texture_of(v)):
				img.set_pixel(x, y, Color(0.15, 0.38, 0.85, 0.85))
			else:
				img.set_pixel(x, y, Color(0.62, 0.68, 0.75, 0.95))

	_rect_pos = Vector2(1920.0 - EDGE - RADIUS_PX * 2.0, 1440.0 - EDGE - RADIUS_PX * 2.0)

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	var view := ColorRect.new()
	view.name = "Circle"
	view.material = _mat
	view.position = _rect_pos
	view.size = Vector2(RADIUS_PX, RADIUS_PX) * 2.0
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)

	_dot_self = _make_dot(SELF_COLOR)
	_dot_enemy = _make_dot(ENEMY_COLOR)


func _make_dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.size = Vector2(8, 8)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.visible = false
	add_child(d)
	return d


func _process(_delta: float) -> void:
	if _dot_self == null:
		return
	var p := Vector2.INF
	if _local_provider.is_valid():
		p = _local_provider.call()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if not p.is_finite() or w <= 0.0 or h <= 0.0:
		_dot_self.visible = false
		_dot_enemy.visible = false
		for d in _other_dots:
			d.visible = false
		return
	var canonical := MazeGenerator.wrap_to_range(p, w, h)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))

	# 自己:恒在圆心
	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5

	if _others_provider.is_valid():
		var others: Array = _others_provider.call()
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		_place_enemy_dot(_dot_enemy, _enemy_provider.call(), p, w, h)


func _circle_center() -> Vector2:
	return _rect_pos + Vector2(RADIUS_PX, RADIUS_PX)


# 敌人点:环面最短向量 → 圆心偏移;超出半径(即世界距离 > RANGE_CELLS 格)不显示。
func _place_enemy_dot(dot: ColorRect, enemy: Vector2, player: Vector2, w: float, h: float) -> void:
	if not Settings.pvp_minimap_show_enemy or not enemy.is_finite():
		dot.visible = false
		return
	# ★ 参数顺序:toroidal_delta_px(a, b, …) 返回 **a→b**,故是 (玩家, 敌人)
	var d := GridPathfinder.toroidal_delta_px(player, enemy, w, h)   # 世界像素
	var s := d / float(GameParameters.TILE_SIZE) * PX_PER_CELL       # 圆心 → 该点的屏幕像素
	if s.length() > RADIUS_PX:
		dot.visible = false
		return
	dot.visible = true
	dot.position = _circle_center() + s - dot.size * 0.5
```

- [ ] **Step 6: 让用户跑探针并读图**

Run（**让用户跑**）：`"$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn`
Expected: `MINIMAP CIRCLE PROBE: ALL-OK`，并存下 `res://.superpowers/sdd/minimap_circle.png`。

★ **存下的 PNG 由实施者自己读一遍**（这个项目里出过两次"数值全绿、画面错"）：确认圆是圆的、地形在图里、右下角位置合理。

- [ ] **Step 7: 真机进 1v1 / 大乱斗各看一眼**

Run（**让用户跑**）：`start_server.bat` + 两个客户端。或至少单进程进一次「大乱斗 → 一键起本服」。
Expected: 小地图是右下角的圆、以自己为中心、对手在范围内才出现红点；走出范围红点消失。

- [ ] **Step 8: 提交**

```bash
git add ui/minimap.gd ui/minimap.gd.uid ui/minimap_circle.gdshader ui/minimap_circle.gdshader.uid tests/minimap_circle_probe.gd tests/minimap_circle_probe.gd.uid tests/minimap_circle_probe.tscn
git commit -m 'feat(ui): 小地图改为以玩家为中心的圆形,敌人点按范围过滤'
```

---

## Task 7: 同步 `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 四处改**

1. **§UI** 新增一小节「小地图」：圆形、以玩家为中心、`RANGE_CELLS`（`ui/minimap.gd`）是"圆形范围"的唯一入口；地形靠 `ui/minimap_circle.gdshader` 的 `repeat_enable` 免费回绕；敌人距离走 `GridPathfinder.toroidal_delta_px(玩家, 敌人, W, H)`（**参数顺序 = a→b**）；两个开关 `Settings.pvp_show_minimap` / `pvp_minimap_show_enemy` 语义不变；`_ready` 空 grid 早退的脆弱性仍在。
2. **§武器背包与地面拾取**：把 `★ 下发出去的 pos 一律是 canonical，不是判定圆心` 那整段（原 :84）改写为「**只有一个中心**」——视觉中心已在 `_build_collision` 里被挪到节点原点，`canonical_pos` 就是画出来的枪的位置；`visual_offset` / `visual_center()` 已删；`_canonical_of` 仍保留（拿活节点的权威值 + 对陈旧条目留痕）。同时把 §1 里 `WeaponPickup` 那条 `visual_offset = cs.position * WORLD_SCALE` 的描述改成新写法。
3. **§敌人**：删掉「中文显示名走同一条记录的 `display_name` 字段（2026-09-14 起收口…）经 `EnemySpawner.display_name_of` 按场景路径查；漏填会静默回落英文原名」那一段（**显示名链已整体移除**），改成「`data/enemies.json` 只有 `id`/`name`/`scene`/`color` 四个字段；单机击杀播报已删（2026-09-17），PvP 的 `kill_event → CombatFeedback.kill` 仍保留」。`node level_editor/sync-enemies.js --check` 的说法保留（`NOT_IN_EDITOR` 守卫仍在）。
4. **§碰撞** / §常用命令附近**新增** `core/sim/unstick.gd` 的位置与用途：地面武器嵌进实心格时向上挤出（含"停稳后被盖住"），几何走 `CollisionAabb.world_rect` + `TileQuery.topmost_solid_row`；`tests/unstick_smoke.gd` 钉语义（含"对齐贴墙不算卡"）。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 同步本批次(小地图圆形化/播报删除/武器偏移/unstick)'
```

---

## 完成后的整体验收（让用户跑）

```bash
# 主冒烟
timeout 120 "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
# 层验收探针(判据是 grep 文本 ALL-OK)
for t in kh_l1 kh_l3 kh_l4 kh_l5 kh_l6; do
  "$GODOT" --headless --path . --quit-after 3600 "res://tests/${t}_probe.tscn" | grep -q ALL-OK \
    && echo "$t ok" || echo "$t FAIL"
done
# 本批次新增
timeout 60 "$GODOT" --headless --path . -s res://tests/unstick_smoke.gd
"$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn
# 编辑器侧
node level_editor/sync-enemies.js --check
node level_editor/sync-tiles.js --check
node level_editor/smoke.js
```

---

## 自检记录（写计划时跑过的检查）

**spec 覆盖**：§1 → Task 6；§2 → Task 5；§3.2(A1) → Task 3；§3.3(A4) → Task 4；§4 → Task 1+2；§5 → 各任务的"让用户跑"步 + Task 7。**无遗漏**。

**写计划时修正的两处 spec 内容**（已回写进 spec）：

1. §4.2 —— 原稿把"向上挤出"整段放在新文件 `Unstick` 里，会**重写一遍** `TileQuery` 文件头明令唯一的"按 AABB 求格范围 → posmod → 双层 for"骨架。改为拆两层：`TileQuery.topmost_solid_row()`（骨架留原地）+ `Unstick.push_up_dy()`（策略另立门户）。
2. §4.2 —— 原稿说 `PROBE_INSET` 是为了"贴地不算卡"。实际那条由 `need <= 0` 早退兜住；内缩真正拦的是**正好 64 宽、正好对齐格线**的矩形把相邻列也算进去（`floori(rect.end/ts)` 含端点），并保证 `need` 恒 ≥ 0.5。冒烟 ② 专门钉这条。

**类型一致性**：`Unstick.push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float` 在 Task 1 定义、Task 2 按同签名调用；`TileQuery.topmost_solid_row(rect: Rect2, ts: int) -> int` 同；`WeaponPickup._unstick_up() -> bool` 只在 Task 2 内使用；`Minimap.RADIUS_PX` / `Minimap.EDGE` 被 Task 6 的探针按常量读取，两份实现里同名同值。
