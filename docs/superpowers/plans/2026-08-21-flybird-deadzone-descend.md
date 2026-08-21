# FlyBird 死区先下飞 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 死区(寻路空路径)时 FlyBird 先逐行下潜到可走格,再重寻路;当前行水平逃逸降级为兜底。

**Architecture:** 改 `EnemyFlyBase._find_escape_column()`(从「只扫当前行」改为「逐行下探优先、当前行水平兜底」)+ `_follow_path()` 逃逸分支(朝带 y 的完整逃逸目标对角下飞)。下潜目标取可走格**格中心**(`cell.y*T + T/2`),因为飞行高度中心会让鸟落在格上两行、重回死区(A* 从被堵格起路返回空路径)。

**Tech Stack:** GDScript(Godot 4.7.1)、无测试框架,冒烟脚本 `Tests/enemy_logic_smoke.gd`(`extends SceneTree`, `-s` 运行)。

## Global Constraints

- **测试由用户自己跑,不要代跑**(CLAUDE.md 约定)。计划里每个 Run 步骤给出命令与期望输出,执行时交用户运行。
- Godot 不在 PATH,用绝对路径(4.7.1 标准 console):
  `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd`
- 成功输出 `SMOKE OK` 且退出码 0;有断言失败则打印 `FAILURES: [...]` 且退出码非 0。
- `-s` 阶段 autoload 未实例化:`GameParameters.MAP_WIDTH/HEIGHT` 为 0,但 `toroidal_delta_px`/`anchor_to_nearest` 在 w/h=0 时是安全的 no-op,不要为测试补设它们。
- 所有敌人参数进 `EnemyParams.FlyBird`(RefCounted const 类,静态访问)。
- 代码注释风格与周边一致(中文、解释 why)。
- 本计划只动 `Globals/enemyParams.gd`、`Scenes/Enemies/enemy_fly_base.gd`、`Tests/enemy_logic_smoke.gd` 三个文件。

---

### Task 1: 红测试 —— 宽天花板死区断言

**Files:**
- Modify: `Tests/enemy_logic_smoke.gd`(在 `jdc.free()` 之后、`if _failures.is_empty():` 之前插入)

**Interfaces:**
- Consumes: `fb_scene`(本函数已在 Task 5 行 430 加载,作用域可见)、`MazeGenerator.{current_grid,SOLID,EMPTY,cell_of}`、`GameParameters.TILE_SIZE`、实例方法 `_find_escape_column()`/`_bird_can_pass()`/`_follow_path()`。
- Produces: 三个必须失败的断言(下飞方向 / 目标格可走 / 下潜运动),证明旧实现「只水平、不下潜」。

- [ ] **Step 1: 在冒烟测试末尾插入死区下潜断言块**

在 `jdc.free()`(现有最后一行,约 791 行)之后、`if _failures.is_empty():` 之前插入:

```gdscript
	# ── Task 7: FlyBird 死区先下飞(逐行下探)──
	# 宽天花板:行 10..12 全实心横跨 300 列。鸟被压到行 13,该行按飞行高度判全撞墙
	# (A* 空路径)。旧逃逸只在当前行左右扫,找不到列就原地悬停;新逻辑逐行下探到
	# 行 17(箱体 y∈[218,272],全在天花板 208 之下)取可走格,鸟真正下潜。
	var esc_grid: Array[Array] = []
	for _y in range(30):
		var row_e: Array[int] = []
		row_e.resize(300)
		row_e.fill(MazeGenerator.EMPTY)
		esc_grid.append(row_e)
	for _r in range(10, 13):
		for _c in range(300):
			esc_grid[_r][_c] = MazeGenerator.SOLID
	MazeGenerator.current_grid = esc_grid
	var esc := fb_scene.instantiate()
	esc.global_position = Vector2(2400, 13 * 16 + 8)
	root.add_child(esc)
	await physics_frame
	var esc_t := esc._find_escape_column()
	_check(esc_t.y > esc.global_position.y, "死区逃逸先下飞(目标在鸟下方)")
	var esc_cell := MazeGenerator.cell_of(esc_t, 16, 300, 30)
	_check(esc._bird_can_pass(esc_cell), "下潜目标格可走(A* 可起路)")
	# 下潜运动:_follow_path 逃逸分支应给向下的速度(旧实现锁 y,只水平飞)
	esc._path = []
	esc._escape_target = esc_t
	esc._follow_path(0.01, Vector2.ZERO)
	_check(esc.velocity.y > 0.0, "死区逃逸对角下潜(velocity.y>0)")
	# 窄檐回归:天花板只覆盖部分列,鸟仍能逃到可走格,不原地卡死
	var esc2_grid: Array[Array] = []
	for _y in range(30):
		var row_e2: Array[int] = []
		row_e2.resize(300)
		row_e2.fill(MazeGenerator.EMPTY)
		esc2_grid.append(row_e2)
	for _r in range(10, 13):
		for _c in range(80):
			esc2_grid[_r][_c] = MazeGenerator.SOLID
	MazeGenerator.current_grid = esc2_grid
	var esc2 := fb_scene.instantiate()
	esc2.global_position = Vector2(640, 13 * 16 + 8)
	root.add_child(esc2)
	await physics_frame
	var esc2_t := esc2._find_escape_column()
	_check(esc2_t != esc2.global_position, "窄檐仍能逃逸(不停在原地)")
	var esc2_cell := MazeGenerator.cell_of(esc2_t, 16, 300, 30)
	_check(esc2._bird_can_pass(esc2_cell), "窄檐逃逸目标格可走")
	esc.free()
	esc2.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 2: 跑冒烟,确认三个新断言失败(红)**

Run(用户执行):
`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd`

Expected:
- `FAIL - 死区逃逸先下飞(目标在鸟下方)`(旧 `_find_escape_column` 返回 `global_position`,y 不变)
- `FAIL - 下潜目标格可走(A* 可起路)`(旧返回格的 cell 是行 13,`_bird_can_pass` false)
- `FAIL - 死区逃逸对角下潜(velocity.y>0)`(旧 `_follow_path` 锁 y,velocity.y=0)
- `ok  - 窄檐仍能逃逸(不停在原地)`、`ok  - 窄檐逃逸目标格可走`(旧实现在窄檐本就能逃,回归护栏)
- 其余既有断言仍 `ok`,末尾 `FAILURES: [...]` 列出上述 3 条。

---

### Task 2: 实现逐行下探 + 对角下潜(绿)

**Files:**
- Modify: `Globals/enemyParams.gd:58`(在 `escape_search_range` 后加参数)
- Modify: `Scenes/Enemies/enemy_fly_base.gd:94-106`(`_find_escape_column` 重写)
- Modify: `Scenes/Enemies/enemy_fly_base.gd:60-64`(`_follow_path` 逃逸分支)

**Interfaces:**
- Consumes: Task 1 的断言。
- Produces: `EnemyParams.FlyBird.escape_max_descent: int = 8`;`_find_escape_column()` 返回可走格中心(Vector2,含 y);`_follow_path` 逃逸分支朝完整 `_escape_target` 对角飞行。

- [ ] **Step 1: 加参数**

`Globals/enemyParams.gd`,在 `escape_search_range` 那行后追加:

```gdscript
	const escape_max_descent: int = 8      # 死区逃逸下探行数上限(当前行无解时往下逐行找)
```

- [ ] **Step 2: 重写 `_find_escape_column()`**

`Scenes/Enemies/enemy_fly_base.gd`,把整个函数(含上方注释)替换为:

```gdscript
# 死区逃逸目标:寻路空路径(A* 无路)时鸟找不到可走的飞行格。先在当前列逐行下探,
# 找第一个「鸟所在格可走」的行 —— 越贴近地面越开阔,宽天花板/悬挑基本必能脱困;
# 下潜失败(如地板级矮檐)退回当前行水平逃逸(与改动前一致)。目标是可走格的格中心
# (不是飞行高度):鸟必须真的落进这个可走格,A* 才能从该格起路;飞行高度中心会让鸟
# 停在格上两行(悬停高度 40px ≈ 2.5 格)、重回死区。
func _find_escape_column() -> Vector2:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return global_position
	var cols := grid[0].size()
	var rows := grid.size()
	var bc := _cell_of(global_position)
	var ts := GameParameters.TILE_SIZE
	for drop in range(1, EnemyParams.FlyBird.escape_max_descent + 1):
		var row := posmod(bc.y + drop, rows)
		for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
			for side in [-1, 1]:
				var cell := Vector2i(posmod(bc.x + side * dist, cols), row)
				if _bird_can_pass(cell):
					return Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)
	for dist in range(1, EnemyParams.FlyBird.escape_search_range + 1):
		for side in [-1, 1]:
			var cell := Vector2i(posmod(bc.x + side * dist, cols), bc.y)
			if _bird_can_pass(cell):
				return Vector2(cell.x * ts + ts * 0.5, global_position.y)
	return global_position
```

- [ ] **Step 3: 改 `_follow_path` 逃逸分支**

`Scenes/Enemies/enemy_fly_base.gd`,第 60-64 行的逃逸分支:

```gdscript
		if fallback_target != Vector2.INF:
			# 死区逃逸:寻路空路径时先水平脱离悬挑(保持当前高度),别直线撞墙。
			if _escape_target != Vector2.INF:
				_fly_straight_to(Vector2(_escape_target.x, global_position.y), delta)
			else:
				_fly_straight_to(fallback_target, delta)
```

替换为:

```gdscript
		if fallback_target != Vector2.INF:
			# 死区逃逸:寻路空路径时朝逃逸目标巡航(先下潜到可走格,窄檐则水平挪出悬挑),
			# 别直线撞墙。目标带 y,鸟真正下飞,不再锁死当前高度。
			if _escape_target != Vector2.INF:
				_fly_straight_to(_escape_target, delta)
			else:
				_fly_straight_to(fallback_target, delta)
```

- [ ] **Step 4: 跑冒烟,确认全绿**

Run(用户执行): 同 Task 1 Step 2 的命令。

Expected: 三个新断言全部 `ok`(下飞目标、目标格可走、velocity.y>0),窄檐两条 `ok`,其余既有断言全部 `ok`,末尾打印 `SMOKE OK` 退出 0。

---

### Task 3: 提交

**Files:** 无改动,仅 git。

- [ ] **Step 1: 提交**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Globals/enemyParams.gd Scenes/Enemies/enemy_fly_base.gd Tests/enemy_logic_smoke.gd
git commit -m "fix: FlyBird 死区先下飞(逃逸列逐行下探,不再顶着天花板悬停)"
```

Expected: 提交成功,`git log --oneline -1` 显示该提交。
