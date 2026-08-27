# PvP 阶段 0：共享重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PvP 需要的 6 项共享改动做成**行为不变的重构**落到主线，单机玩起来和今天一模一样，两个冒烟测试保持绿。

**Architecture:** 每项重构都是对现有单人代码的等价改写（输入改走可注入 InputSource、瞄准加覆盖钩子、子弹带射手引用、spawn 解析支持双出生点、世界构建抽成 WorldBuilder、Level0 加 pvp_mode 标志）。不做任何新功能，不写网络代码。

**Tech Stack:** Godot 4.7.1 标准版（非 mono），GDScript，无测试框架（`-s` SceneTree 冒烟脚本）。

## Global Constraints

- Godot 可执行：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **测试由用户自己跑**，本计划不代跑。每个任务以"跑冒烟 + 手动试玩确认"为验证。
- 唯一 autoload 是 `GameParameters`；`PlayerParams`/`EnemyParams`/`MazeGenerator` 是静态 `RefCounted`。
- `-s` 阶段 autoload 尚未实例化：冒烟脚本避免实例化引用 autoload 的脚本（player.gd 引用 GameParameters，故不可在 `-s` 实例化——契约测试走源码级检查）。
- 现有冒烟：`enemy_logic_smoke.gd` 成功打印 `SMOKE OK` 退出 0；`player_contract_smoke.gd` 成功打印 `CONTRACT OK` 退出 0。
- 提交直接到 `main`（仓库惯例，近期提交全在 main）。
- **行为不变铁律**：每项重构后，单机输入/瞄准/伤害/地图/碰撞与重构前完全一致。

---

### Task 1: 输入源抽象（player.gd 不再直接读全局 Input）

**Files:**
- Create: `Globals/input_source.gd`
- Modify: `Scenes/Player/player.gd`（7 处 `Input.*` 轮询读取 + 2 个新方法）
- Modify: `Tests/player_contract_smoke.gd`（加 2 条契约守卫）

**Interfaces:**
- Produces: `class_name InputSource extends RefCounted`，方法 `get_axis(neg,pos)->float` / `is_action_pressed(action)->bool` / `is_action_just_pressed(action)->bool` / `is_action_just_released(action)->bool` / `get_aim_dir_override()->Vector2`（默认返回 `Vector2.ZERO`）。
- Produces: `player.gd` 新方法 `func set_input_source(src: InputSource)`、`func get_aim_dir_override() -> Vector2`。
- Consumes: Task 2 用 `player.get_aim_dir_override()`；Plan B 用 `set_input_source()` 注入 `NetworkInputSource`。

- [ ] **Step 1: 新建 `Globals/input_source.gd`**

```gdscript
class_name InputSource
extends RefCounted

# 玩家输入抽象(行为不变重构):基类默认行为 = 委托真实 Input,即本地玩家现状。
# Plan B 的 NetworkInputSource 覆写这些方法,消费网络输入包驱动服务器上的远端玩家。
# 目标:player.gd 不再直接读全局 Input,输入来源可注入。

func get_axis(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func is_action_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)

func is_action_just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func is_action_just_released(action: String) -> bool:
	return Input.is_action_just_released(action)

# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO
```

- [ ] **Step 2: 改 `Scenes/Player/player.gd`——加字段/方法**

在文件顶部 `@export var weapon_slot: Node2D` 附近加：

```gdscript
# 输入来源(行为不变重构):默认委托真实 Input;服务器注入 NetworkInputSource 驱动远端玩家。
var input_source: InputSource = InputSource.new()

func set_input_source(src: InputSource) -> void:
	input_source = src

# 瞄准覆盖:本地返回 ZERO → 武器用鼠标;服务器注入的网络输入返回瞄准方向。
func get_aim_dir_override() -> Vector2:
	return input_source.get_aim_dir_override()
```

- [ ] **Step 3: 改 `Scenes/Player/player.gd`——7 处轮询读取换成 `input_source.*`**

逐处精确替换（保持上下文不变）：

1. `var horizontal_input = Input.get_axis("left", "right")` → `var horizontal_input = input_source.get_axis("left", "right")`
2. `if Input.is_action_just_pressed("up"):` → `if input_source.is_action_just_pressed("up"):`
3. `if not jump_cut_applied and Input.is_action_just_released("up") and velocity.y < 0.0:` → `if not jump_cut_applied and input_source.is_action_just_released("up") and velocity.y < 0.0:`
4. `if Input.is_action_just_pressed("down"):`（下蹲分支，2 处：on_floor 下蹲 + 空中 charge_down）两处都换成 `input_source.is_action_just_pressed("down"):`
5. `if Input.is_action_just_released("down"):` → `if input_source.is_action_just_released("down"):`
6. `if Input.is_action_just_pressed("charge"):` → `if input_source.is_action_just_pressed("charge"):`

> 注意：`_unhandled_input` 里 `event.is_action_pressed("R")` 和 `event.is_action_pressed(slot)` 是事件驱动的，**保持原样**（Phase 0 本地路径不变；网络切枪由 Plan B 的输入包直接调 `weapons.equip`，不走事件）。

- [ ] **Step 4: 加契约守卫到 `Tests/player_contract_smoke.gd`**

在 `# 根公开方法` 循环之后加：

```gdscript
	# 输入源抽象(行为不变重构):根不再直接读全局 Input,且可注入
	_check(src.contains("input_source.get_axis"), "player.gd 输入走 input_source")
	_check(src.contains("func set_input_source("), "player.gd 输入可注入")
```

- [ ] **Step 5: 跑两个冒烟，确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/player_contract_smoke.gd
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `CONTRACT OK` + `SMOKE OK`，均退出 0。

- [ ] **Step 6: 手动试玩确认手感不变**（用户跑游戏，移动/跳/冲刺/下蹲/切枪表现与之前一致）

- [ ] **Step 7: 提交**

```bash
git add Globals/input_source.gd Scenes/Player/player.gd Tests/player_contract_smoke.gd
git commit -m "refactor: 玩家输入走可注入 InputSource(本地委托真实 Input,行为不变)"
```

---

### Task 2: 瞄准覆盖钩子（weapon_base 网络瞄准预留）

**Files:**
- Modify: `Scenes/Weapons/weapon_base.gd`（`_aim_world_dir()` 顶部加短路）

**Interfaces:**
- Consumes: `player.gd::get_aim_dir_override() -> Vector2`（Task 1 产出）。
- Produces: 当玩家是网络驱动时返回注入瞄准方向；本地玩家返回 `Vector2.ZERO` → 落回原鼠标计算，**行为逐字节不变**。

- [ ] **Step 1: 改 `_aim_world_dir()`**

在 `func _aim_world_dir() -> Vector2:` 内部第一行（`var cam: Camera2D = get_viewport().get_camera_2d()` 之前）加：

```gdscript
	# 网络驱动的玩家(服务器上的远端模拟)用注入的瞄准;本地玩家返回 ZERO → 落回鼠标。
	# has_method 守卫:冒烟里的 StubPlayer 没有该方法时跳过,不破坏测试。
	if player != null and player.has_method("get_aim_dir_override"):
		var override: Vector2 = player.get_aim_dir_override()
		if override != Vector2.ZERO:
			return override
```

- [ ] **Step 2: 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出 0（冒烟挂武器到根 Window 开火，短路不触发 → 走原鼠标路径）。

- [ ] **Step 3: 手动试玩确认瞄准手感不变**（用户跑游戏，鼠标瞄准/重狙预瞄/榴弹弧线与之前一致）

- [ ] **Step 4: 提交**

```bash
git add Scenes/Weapons/weapon_base.gd
git commit -m "refactor: 瞄准加 get_aim_dir_override 覆盖钩子(本地返回 ZERO 落回鼠标,行为不变)"
```

---

### Task 3: 子弹射手引用（击杀归因前置）

**Files:**
- Modify: `Scenes/Weapons/bullet_base.gd`（加 1 字段）
- Modify: `Scenes/Weapons/weapon_base.gd`（fire 里赋值 1 行）

**Interfaces:**
- Produces: `BulletBase.shooter: Node`——子弹的射手玩家节点。Plan B 服务器用它裁决击杀归因（A 的子弹杀 B → A +1）。
- 本地单人：该字段无人消费，行为不变。

- [ ] **Step 1: `bullet_base.gd` 加字段**

在 `var source: Node = null` 下一行加：

```gdscript
var shooter: Node = null  # 射手玩家(击杀归因用):本地=武器持有者;服务器=权威模拟里的玩家
```

- [ ] **Step 2: `weapon_base.gd` `fire()` 里赋值**

在 `b.setup(...)` 那一行之后、`b.gravity_factor = bullet_gravity` 之前加：

```gdscript
		b.shooter = player
```

- [ ] **Step 3: 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出 0。

- [ ] **Step 4: 提交**

```bash
git add Scenes/Weapons/bullet_base.gd Scenes/Weapons/weapon_base.gd
git commit -m "refactor: 子弹带 shooter 引用(击杀归因前置,本地无消费,行为不变)"
```

---

### Task 4: 双出生点解析（`# player2`）

**Files:**
- Modify: `Globals/maze_generator.gd`（`parse_spawn_metadata` 加 `player2` 分支 + `load_spawns` 旧格式 ÷2）
- Modify: `Tests/enemy_logic_smoke.gd`（加解析断言）

**Interfaces:**
- Produces: `load_spawns()` 结果可含 `"player2": Vector2i`（与 `"player"` 并存）。Plan B 服务器/PvP 场景用它布 P2 出生点。

- [ ] **Step 1: 加失败测试（TDD：先让新断言失败）**

在 `Tests/enemy_logic_smoke.gd` 的 `"spawn 全部位于地板上面"` 检查之后加：

```gdscript
	# ── Task 4: 双出生点解析(# player2)──
	var meta := MazeGenerator.parse_spawn_metadata(["# player2 3 4"])
	_check(meta.get("player2") == Vector2i(3, 4), "player2 spawn 解析")
	var meta2 := MazeGenerator.parse_spawn_metadata(["# player 1 2", "# player2 5 6"])
	_check(meta2.get("player") == Vector2i(1, 2) and meta2.get("player2") == Vector2i(5, 6), "player+player2 并存")
```

跑一次确认失败：

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: 打印 `FAIL - player2 spawn 解析`，退出 1。

- [ ] **Step 2: 实现 `parse_spawn_metadata` 的 `player2` 分支**

在 `"player":` 分支之后、`"enemy":` 之前，加一个镜像 `"player"` 的分支：

```gdscript
			"player2":
				if parts.size() >= 3:
					var x := int(parts[1])
					var y := int(parts[2])
					if x >= 0 and y >= 0:
						result["player2"] = Vector2i(x, y)
					else:
						push_warning("MazeGenerator: 非法 player2 坐标 %s" % text)
```

- [ ] **Step 3: `load_spawns` 旧格式对 `player2` 同样 ÷2**

在 `if result.has("player"):` 块之后加：

```gdscript
	if result.has("player2"):
		result["player2"] = Vector2i(result["player2"].x / 2, result["player2"].y / 2)
```

- [ ] **Step 4: 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出 0；新增两断言 `ok`。

- [ ] **Step 5: 提交**

```bash
git add Globals/maze_generator.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: spawn 解析支持 # player2 双出生点"
```

---

### Task 5: 抽取 WorldBuilder（地图加载 / 碰撞构建复用）

**Files:**
- Create: `Globals/world_builder.gd`
- Modify: `Scenes/level_0.gd`（`_ready` 的加载块换 `WorldBuilder.load_grid()`；`_build_wall_collision` 换成 `WorldBuilder.build_sim()`）

**Interfaces:**
- Produces: `WorldBuilder.load_grid() -> Array`（加载地图→current_grid/TileDefs.load_defs/地图像素尺寸，返回网格，空=失败）；`WorldBuilder.build_sim(parent: Node, grid: Array) -> Array`（建碰撞：永久墙+可破坏分块+攀爬基座条，返回持久可破坏子格）。
- Consumes: Plan B 服务器用 `load_grid`+`build_sim`（headless，无渲染节点）建权威世界。

- [ ] **Step 1: 新建 `Globals/world_builder.gd`**

```gdscript
class_name WorldBuilder
extends RefCounted

# 世界构建(地图加载/碰撞),单人 Level0 与 PvP 客户端/服务器共用。
# 行为不变重构:Level0._ready 改为调用此处,单机表现不变。
# build_sim 把碰撞节点挂到 parent 下(客户端=WorldViewport,服务器=服务器世界节点)。

# 加载地图 → current_grid + TileDefs + 地图像素尺寸;返回网格(空=失败)。
static func load_grid() -> Array:
	var grid := MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("WorldBuilder: 地图加载失败")
		return []
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = grid.size() * GameParameters.TILE_SIZE
	return grid

# 建碰撞(永久墙 + 可破坏分块 + 攀爬基座条),挂到 parent;返回持久可破坏子格(摧毁重建用)。
static func build_sim(parent: Node, grid: Array[Array]) -> Array:
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), parent, "WallCollision")
	var sub := CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(sub, parent)
	CollisionBuilder.build_climb_ledges(grid, parent)
	return sub
```

- [ ] **Step 2: 改 `level_0.gd` `_ready()` 的地图加载块**

把这段：

```gdscript
	var grid = MazeGenerator.load_map_file()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	MazeGenerator.current_grid = grid
	TileDefs.load_defs()
	_grid_ref = grid
	Level0.wall_layer = $WorldViewport/WallLayer
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
```

替换为：

```gdscript
	var grid := WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	_grid_ref = grid
	Level0.wall_layer = $WorldViewport/WallLayer
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
```

> 保留 `TileDefs.init_hp(grid)` 在原位置（在 on_destroyed 接线之后，顺序与原版一致）。原版 `GameParameters.MAP_WIDTH/HEIGHT` 两行被 `load_grid()` 内部接管。

- [ ] **Step 3: 改 `level_0.gd` `_build_wall_collision`**

把整个函数体：

```gdscript
func _build_wall_collision(grid: Array[Array]) -> void:
	# 永久墙(1-14)建一次整图节点;可破坏(15-20)按分块存节点,摧毁时只重建所在块
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false),
			$WorldViewport, "WallCollision")
	_destructible_sub = CollisionBuilder.build_sub(grid, true)
	CollisionBuilder.build_destructible_chunks(_destructible_sub, $WorldViewport)
	# 攀爬结构基座薄碰撞条(梯子顶/锁链顶底),供玩家停留/落脚
	CollisionBuilder.build_climb_ledges(grid, $WorldViewport)
```

替换为：

```gdscript
func _build_wall_collision(grid: Array[Array]) -> void:
	# 永久墙 + 可破坏分块 + 攀爬基座条,逻辑迁到 WorldBuilder.build_sim(服务器复用)
	_destructible_sub = WorldBuilder.build_sim($WorldViewport, grid)
```

- [ ] **Step 4: 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出 0。

- [ ] **Step 5: 手动试玩确认世界不变**（用户跑游戏，地图/碰撞/攀爬基座/可破坏墙与之前一致）

- [ ] **Step 6: 提交**

```bash
git add Globals/world_builder.gd Scenes/level_0.gd
git commit -m "refactor: 抽取 WorldBuilder(load_grid/build_sim),Level0 复用,行为不变"
```

---

### Task 6: `Level0.pvp_mode` 标志（PvP 只建世界）

**Files:**
- Modify: `Scenes/level_0.gd`（静态标志 + `_ready` 早退）

**Interfaces:**
- Produces: `Level0.pvp_mode: bool`（静态，默认 false）。Plan B 的 `pvp_game.tscn` 先设 `Level0.pvp_mode = true` 再 `add_child(Level0 实例)`。
- 单人：默认 false，`_ready` 走原路径，行为不变。

- [ ] **Step 1: 加静态标志**

在 `static var _dirty_chunks: Dictionary = {}` 附近加：

```gdscript
# PvP 模式:只建世界(地图/瓦片/碰撞/水),玩家/敌人/相机/后处理由 PvP 场景负责。
static var pvp_mode: bool = false
```

- [ ] **Step 2: `_ready()` 尾部加早退**

在 `_build_wall_collision.call_deferred(grid)` 之后、`EnemySpawner.load_types()` 之前插入：

```gdscript
	if pvp_mode:
		return  # 世界已建;敌人/单玩家放置/后处理交给 PvP 场景
```

- [ ] **Step 3: 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出 0。

- [ ] **Step 4: 手动试玩确认单人不变**（用户跑游戏，出生/刷敌/后处理正常）

- [ ] **Step 5: 提交**

```bash
git add Scenes/level_0.gd
git commit -m "feat: Level0.pvp_mode 标志——pvp 只建世界,默认 false 单人行为不变"
```

---

## 自检（写完后）

- **Spec 覆盖**：spec §7 的共享重构 1-6 全部落地（1=Task1，2=Task2，3=Task3，4=Task4，5=Task5，6=Task6）；§7 的 7（钉地图）、8（transport）按 YAGNI 移入 Plan B（有新消费者时再做），已在文档头部说明。
- **占位符**：每步都有完整代码/命令，无 TBD。
- **类型一致**：`InputSource.get_axis/is_action_pressed/...`、`player.set_input_source/get_aim_dir_override`、`weapon_base` 读 `get_aim_dir_override`、`BulletBase.shooter`、`WorldBuilder.load_grid/build_sim`、`Level0.pvp_mode` 在全部任务中命名一致。
