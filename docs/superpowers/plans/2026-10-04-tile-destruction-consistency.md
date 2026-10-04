# 拆砖一致性（幽灵砖 / 服务器清错格）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让"一格砖被拆掉"这件事在**单机与服务器两侧**都把三处状态一起推进（渲染+碰撞 / `current_grid` / 两张 HP 表），并让回溯复原把同一批状态一起还原。

**Architecture:** 不新增第四套真相源，而是把**已有的两条破坏路径收口**：(1) 服务器侧 `MatchHost._on_tile_destroyed` 仍在，但它清的是**错的子格坐标**（2×2）——改成 4×4；(2) 单机侧 `Level0` **根本没接**格级回调——接上，并在 `TileDefs` 里加一个"格级销毁/HP 读写"的收口 API，让两张 HP 表的写口都留在 `TileDefs`。激光**继续走格级 `damage_tile`**（用户已定：打整格的行为与手感不变），所以**不动** `laser_weapon_base.gd`。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）、GDScript、`extends Node` 场景探针（`.tscn` + `--quit-after`）、判据一律 **grep 文本**。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) —— §1.1（单机幽灵砖）、§3 顶部订正块第 4 条（服务器 2×2 在真 PvP 局可达）、§10（用户裁定：§1 都得做；A1 选 (b)）。

## Global Constraints

- **判据是文本，不是退出码**：本计划两条判词 —— `TILE COLLISION PROBE: ALL-OK`、`DESTROYED CELLS: ALL-OK`。★ 且必须**先读 `_notes`/失败清单再读 `ALL-OK`**（本仓硬规则：`ALL-OK` 只证明"没有任何断言失败"）。
- **场景探针一律 `--quit-after 3600`**；`--quit-after` 单位是**帧**。
- 跑探针**前后** `tasklist | grep -i godot` 必须为空（worker 是孙进程）。本计划**不占 7777**（两个探针都 `role_peers` 传空/单机）。
- **提交纪律**：逐个文件点名 `git add`；**绝不 `git add -A`**；新建 `.gd` 连 `.gd.uid` 一起加（`.tscn` 不用）。提交前 `git status --short` + 逐文件 `git diff` 认领每个 hunk。
- **档 3 的义务**（本计划三条都触及"命中与碰撞判定 / 联机权威"）：**每条承重断言逐条变异验证** + **逐任务评审**（做完一条先审再进下一条）。
- 不许出现非 16 倍数的**字号载体字面量**（全仓机械扫描会红）。本计划不新增 UI。

## Review Focus

按"最可能咬到人"排序。每条都在下面的任务里配了断言，括注所属任务。

1. **环面接缝另一侧的副本没被清**（Task 2/3）：玩家在接缝附近拆一格，3×3 铺贴里另外 8 个副本必须一起没；否则跨接缝能看到/撞到"幽灵砖"。→ 断言含 `±MAP_WIDTH` 采样的 `_terrain_at`。
2. **`_destructible_sub` 与 `sub_hp` 分家**（Task 2）：只写 `_destructible_sub` 而不写 `sub_hp`，`CollisionBuilder.build_sub` 会按 `sub_alive` 把碰撞**复活**（`core/sim/collision_builder.gd:49`）⇒ 看不见的墙。→ 断言走 `_scan()` 的**碰撞那一维**（它读的就是 `build_sub` 的规则）。
3. **清到别处**（Task 1）：`match_combat` 的坐标算错时，被拆那一格没清、**另一格凭空开洞**，而 `rebuild_chunk` 读的就是那份脏数组 ⇒ **洞不自愈**。→ Task 1 的**反向断言**（别的格一个都不许被清）。
4. **复原后 `hp_grid` 仍为 0 ⇒ 下一发激光一发即碎**（Task 3）：原本 4 发才碎的一格，复原后一发就没。→ 断言回溯后 `hp_grid_at(cell)` 回到满血。
5. **复原把整格当成"16 次子格复原"**（Task 3）：`_restore_sub` 是按**子格**调用的，格级销毁后它会被调 16 次 ⇒ `hp_grid` 的补写必须**幂等**（16 次都写同一个满血值，不能被中间态覆盖）。→ 断言：相⑥b 里 16 个子格各复原一次之后，`hp_grid_at(cell)` **恰好**等于 `hp_of(tex)`（写成"每格 −1"或"取最小值"之类的实现会当场露出来）。

---

### Task 1: 服务器侧清格子格的坐标算法（2×2 → 4×4）

**Files:**
- Modify: `server/match/match_combat.gd:9-13`
- Test: `tests/probe/destroyed_cells_probe.gd`（加"相③ 走真破坏路径"，`tests/probe/destroyed_cells_probe.tscn` 不改）

**Interfaces:**
- Consumes: `MatchHost._debug_destroy_tile(delta)`（`server/match/match_host.gd:288-296`，读 `MatchState.test_destroy_cell` / `test_destroy_after`，内部调 `TileDefs.damage_tile(cell, 999999, "explosion")`）；`MatchHost.destructible_sub`（按**子格**坐标索引的二维数组，空 = `MazeGenerator.EMPTY`）。
- Produces: 无新 API —— `destructible_sub` 的语义被修正为"按子格坐标、清满 4×4"。

- [ ] **Step 1: 写失败的断言**

在 `tests/probe/destroyed_cells_probe.gd` 的 `_run()` 里、**相② 之后**加相③（沿用该文件既有的 `_check(ok, what)`，`_host` 已建好且 `:38` 已关宿主物理帧）：

```gdscript
	# ── ③ 走**真破坏路径**(worker 用的那条) → 该格 16 子格全清,且**别的格一格没动** ──
	var cell := Vector2i(9, 6)
	_host._base_grid[cell.y][cell.x] = MazeGenerator.SOLID   # 与相② 同款:先钉基线,免恒红
	MatchState.test_destroy_cell = cell
	MatchState.test_destroy_after = 0.0
	_host._debug_destroy_tile(0.0)
	var left := 0
	for sy in range(4):
		for sx in range(4):
			if _host.destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] != MazeGenerator.EMPTY:
				left += 1
	_check(left == 0, "格 %s 的 16 子格应被清光(残留 %d)" % [str(cell), left])
	# ★ 反向断言:2×2 的越界写法会去清**别的格** ⇒ 这里是唯一能抓住"清到别处"的判据。
	var others := 0
	var rows: int = _host.destructible_sub.size()
	var cols: int = _host.destructible_sub[0].size()
	for y in range(rows):
		for x in range(cols):
			if _host.destructible_sub[y][x] != MazeGenerator.EMPTY:
				var owner_cell := Vector2i(x / 4, y / 4)
				if owner_cell != cell:
					others += 1
	_check(others == 0, "不该有别的格被清(实际 %d 个子格)" % others)
```

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/destroyed_cells_probe.tscn`
Expected: **不出现** `DESTROYED CELLS: ALL-OK`；失败清单里点名上面两条中的至少一条（今天 `* 2` 的写法会清到格 `(4, 3)` 的左上 2×2 ⇒ `others` > 0，而 `left` = 16）。

- [ ] **Step 3: 改 `server/match/match_combat.gd:9-13`**

把那三行换成按 **4×4** 展开、且格子格坐标从**当前格**算出（同文件 `:25` 已有反向换算 `Vector2i(sub.x / 4, sub.y / 4)`，此处是它的逆）：

```gdscript
		for sy in range(4):
			for sx in range(4):
				destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] = MazeGenerator.EMPTY
```

并更新上方注释（原文说"清 3×3 环面副本对应格 + 持久子格该格 2×2"的口径已过期）：写明"cyrm v4 起子格是 16px（64px 格 → 4×4）；这里必须按当前格展开，别用 `* 2`——那会清到 `(x/2, y/2)` 的左上象限"。

- [ ] **Step 4: 跑它，确认绿**

Run: 同 Step 2。Expected: `DESTROYED CELLS: ALL-OK`（且无 `  - ` 失败行）。

- [ ] **Step 5: 变异验证（档 3，逐条）**

把 `* 4` 改回 `* 2` 再跑一次 ⇒ 必须红在 `不该有别的格被清`（并观察 `16 子格应被清光` 也红）。**改回来**，再跑一次确认绿。

- [ ] **Step 6: 提交**

```bash
git add server/match/match_combat.gd tests/probe/destroyed_cells_probe.gd
git commit -m "fix(match): 服务器拆砖按 4×4 子格清当前格(原 2×2 清到了 (x/2,y/2) 的左上象限,真格留幽灵墙)"
```

---

### Task 2: 单机格级销毁收口（`TileDefs.destroy_cell` + `Level0` 接线）

**Files:**
- Modify: `core/sim/tile_defs.gd`（在 `restore_sub`（:284）附近新增 `destroy_cell`）
- Modify: `scenes/level_0.gd:241`（接线）+ 新增 `_on_tile_destroyed`（紧邻 `_on_sub_destroyed`（:448））
- Test: `tests/probe/tile_collision_probe.gd`（加"相⑥ 格级路径"；该文件现**无**跑完闩，一并补）

**Interfaces:**
- Consumes: `TileDefs.damage_tile(cell, amount, source)`（格级；销毁时改 `current_grid` + `hp_grid` 并调 `on_destroyed`）、`TileDefs.restore_sub(sub, hp)`（:284，只写 `sub_hp`）、`TileDefs.sub_alive(sub)`（:237）、`Level0._on_sub_destroyed(sub, pre_hp, owner)`（:448，负责渲染 9 副本 + `_destructible_sub` + 脏块 + 瓦片账本 `_tile_pending`）。
- Produces: `TileDefs.destroy_cell(cell: Vector2i) -> void`（**供 Task 3 复用**；签名固定为单参数、无返回）。

- [ ] **Step 1: 写失败的断言**

在 `tests/probe/tile_collision_probe.gd` 的 `_run()` 末尾（现有相⑤ 之后、`TILE COLLISION PROBE: ALL-OK` 那行之前）加相⑥：

```gdscript
	# ── 相⑥ 格级路径:激光真调的 API(`damage_tile`)打光整格 ⇒ 渲染/碰撞/hp 必须一起没 ──
	# 存在理由:此前该探针的破坏全走 `damage_sub`,而**格级**这条链单机根本没接回调
	# ⇒ "整格已碎、16 子格仍 sub_alive"的幽灵砖在四条探针下全绿。
	var cell6: Vector2i = _find_target()          # 复用既有选点(它保证是可破坏的墙)
	var subs6: Array = _cell_subs(cell6)
	TileDefs.damage_tile(cell6, 999999, "explosion")
	await _wait_ms(300)                           # 脏块分帧重建(与相④ 同款等待)
	var ghost := 0
	for s in subs6:
		if _painted(s):
			ghost += 1
	if ghost != 0:
		_fail("[相⑥] 格级销毁后仍有 %d/16 子格在画(幽灵砖)" % ghost)
	var c6 := _sub_center(subs6[0])
	if _terrain_at(world, c6):
		_fail("[相⑥] 格级销毁后格心仍有碰撞(看不见的墙)")
	if TileDefs.hp_grid[cell6.y][cell6.x] != 0:
		_fail("[相⑥] 格级销毁后 hp_grid[%s] 应为 0(实得 %d)" % [str(cell6), TileDefs.hp_grid[cell6.y][cell6.x]])
```

★ 实现者注意：该文件的断言口是 `_fail(m: String)`（:34），**不是** `_check`；`_fail("")` 是空失败——**不要**照抄上面那行占位，直接写成 `if ghost != 0: _fail(...)` 三段。`world` 用 `_run()` 里既有的那个变量名（照相① 的写法）。`_find_target()` / `_cell_subs()` / `_painted()` / `_sub_center()` / `_terrain_at()` 都是该文件已有的 helper，别另写。

同时给该文件补**跑完闩**（照 `tests/probe/destroyed_cells_probe.gd:22` 的先例，比逐条计数闸省事且等价）：`var _ran_to_end := false`，在 `_run()` 最后一行置 `true`，在打 `ALL-OK` 之前判 `if not _ran_to_end: quit(1)` 并打印"`_run()` 没跑完"。

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn`
Expected: **不出现** `TILE COLLISION PROBE: ALL-OK`；打印 `[相⑥] 格级销毁后仍有 16/16 子格在画(幽灵砖)`（今天 `level_0.gd:241` 只接 `on_sub_destroyed`，格级回调无人接）。

- [ ] **Step 3: 实现 `TileDefs.destroy_cell`**

在 `core/sim/tile_defs.gd` 的 `restore_sub`（:284）附近新增（**只动子格侧**，`grid`/`hp_grid` 由 `damage_tile` 已经处理完）：

```gdscript
## 格级销毁的"子格侧"收口:把该格 16 个子格的 sub_hp 清零,并逐子格发 on_sub_destroyed
## (渲染 9 副本 / `_destructible_sub` / 脏块 / 瓦片账本 一律由回调处理)。
## ★ 存在理由:格级回调此前只接了服务器 ⇒ 单机激光打光整格后 16 子格仍 sub_alive ⇒ 幽灵砖。
## ★ 不要手写 `_destructible_sub`:build_sub 按 sub_alive 重建,只写数组会被复活。
static func destroy_cell(cell: Vector2i) -> void:
	for sy in range(4):
		for sx in range(4):
			var sub := Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)
			if not sub_alive(sub):
				continue
			var pre_hp: int = sub_hp[sub.y * sub_cols + sub.x]
			restore_sub(sub, 0)
			if on_sub_destroyed.is_valid():
				on_sub_destroyed.call(sub, pre_hp, null)
```

★ 变量名以该文件现有实现为准（`sub_cols` 由 `init_sub_hp`（:213-214）设置；`sub_hp` 的索引写法照 `:238`）。先 `grep -n "sub_cols\|sub_hp\[" core/sim/tile_defs.gd` 核对，别照抄本计划的字面。

- [ ] **Step 4: 接线 `Level0`**

`scenes/level_0.gd:241` 旁（紧接着 `TileDefs.on_sub_destroyed = ...` 那行）加：

```gdscript
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
```

并在 `_on_sub_destroyed`（:448）上方新增：

```gdscript
## 格级销毁(单机):激光走的是格级 damage_tile ⇒ 把子格侧收口交给 TileDefs.destroy_cell。
## 渲染/碰撞/账本由它逐子格回调 _on_sub_destroyed 完成,这里不做第二遍。
func _on_tile_destroyed(cell: Vector2i) -> void:
	TileDefs.destroy_cell(cell)
```

- [ ] **Step 5: 跑它，确认绿**

Run: 同 Step 2。Expected: `TILE COLLISION PROBE: ALL-OK(...)`。

- [ ] **Step 6: 变异验证（档 3，逐条）**

逐条拆掉一处、各跑一次，确认每次都红在**对应**那条断言上，然后复原：
① 删 `level_0.gd:241` 旁那行接线 ⇒ 红在"幽灵砖"；② 把 `destroy_cell` 里的 `restore_sub(sub, 0)` 注释掉 ⇒ 红在"幽灵砖"（`sub_alive` 仍真）；③ 只把 `restore_sub` 换成直接写 `_destructible_sub` 的写法（或把 `sub_hp` 写入去掉）⇒ 红在**碰撞那一维**（`_scan` 的碰撞不符计数）。

- [ ] **Step 7: 提交**

```bash
git add core/sim/tile_defs.gd scenes/level_0.gd tests/probe/tile_collision_probe.gd
git commit -m "fix(tiles): 单机格级销毁收口 —— TileDefs.destroy_cell 清 16 子格并发回调,Level0 接上 on_destroyed(此前只有服务器接了,单机留幽灵砖)"
```

---

### Task 3: 复原时把 `hp_grid` 一起还原（+ 登记回溯保真度边界）

**Files:**
- Modify: `core/sim/tile_defs.gd`（新增 `hp_grid_at` / `set_hp_grid`）
- Modify: `scenes/level_0.gd` 的 `_restore_sub`（:421-445）
- Modify: `docs/eng/registered-debt.md`（§四 那类"已知边界"落点）
- Test: `tests/probe/tile_collision_probe.gd`（在相⑥ 之后加"相⑥b 格级销毁 → 回溯"）

**Interfaces:**
- Consumes: **Task 2 已落地的格级链**（`Level0` 的 `on_destroyed` → `destroy_cell`）—— 本任务的前提是 **Task 2 的相⑥ 已绿**（否则相⑥b 的"前置条件"那句会先红，那是夹具问题不是本任务的结论）；`TileDefs.hp_of(texture)`（:129）；`Level0._restore_sub(sub, hp)`（:421-445，已写 `sub_hp` / 9 副本 / `_destructible_sub` / 脏块 / `_pristine_grid` 回填）。
- Produces: `TileDefs.hp_grid_at(cell: Vector2i) -> int`、`TileDefs.set_hp_grid(cell: Vector2i, hp: int) -> void`。

- [ ] **Step 1: 写失败的断言**

在 `tile_collision_probe.gd` 相⑥ 之后加相⑥b（先格级销毁，再触发**与相④ 同款**的回溯复原）：

```gdscript
	# ── 相⑥b 格级销毁 → 回溯复原:hp_grid 必须跟着回来,否则"下一发激光一发即碎" ──
	var cell6b: Vector2i = _find_target()
	var tex6b: int = _tex(_cell_subs(cell6b)[0])
	TileDefs.damage_tile(cell6b, 999999, "explosion")
	await _wait_ms(300)
	# ★ 这里插入"触发回溯"的那几行 —— 照抄本文件**相④**里触发回溯的写法(同一世界、同一等待)
	await _wait_ms(300)
	var back_ok := true
	for s in _cell_subs(cell6b):
		if not _painted(s) or not _terrain_at(world, _sub_center(s)):
			back_ok = false
	if not back_ok:
		_fail("[相⑥b] 回溯后该格渲染/碰撞未复原(前置条件不成立,先查相④)")
	var want_hp := TileDefs.hp_of(tex6b)
	if TileDefs.hp_grid_at(cell6b) != want_hp:
		_fail("[相⑥b] 回溯后 hp_grid[%s] 应回到 %d(实得 %d)⇒ 下一发激光会一发即碎"
				% [str(cell6b), want_hp, TileDefs.hp_grid_at(cell6b)])
```

★ `<触发回溯复原…>` 那行**照抄相④ 里触发回溯的那几行**（同文件、同世界、同等待），不要新造机制。

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn`
Expected: **不出现** `ALL-OK`；打印 `[相⑥b] 回溯后 hp_grid[...] 应回到 30(实得 0)`（或该砖的 `hp_of` 值）。★ 若第一句"渲染/碰撞未复原"也红，说明相④ 的回溯用法抄错了——**先修夹具再谈结论**。

- [ ] **Step 3: 加两个 HP 读写口**

`core/sim/tile_defs.gd` 新增（越界返回 0 / 越界静默不写，与 `sub_alive` 的越界口径一致）：

```gdscript
## 格级 HP 的读取端(越界返回 0)。存在理由:两张 HP 表此前只有"写"没有"读回来的口",
## 于是"复原时补 hp_grid"这件事没有合法写法。
static func hp_grid_at(cell: Vector2i) -> int:
	if cell.y < 0 or cell.y >= hp_grid.size() or cell.x < 0 or cell.x >= hp_grid[cell.y].size():
		return 0
	return int(hp_grid[cell.y][cell.x])


## 格级 HP 的写入口(越界静默)。★ 写口留在本类:两张 HP 表(格级 hp_grid / 子格 sub_hp)
## 的分家正是"幽灵砖"的根因,别再让调用方直接写数组。
static func set_hp_grid(cell: Vector2i, hp: int) -> void:
	if cell.y < 0 or cell.y >= hp_grid.size() or cell.x < 0 or cell.x >= hp_grid[cell.y].size():
		return
	hp_grid[cell.y][cell.x] = hp
```

- [ ] **Step 4: 在 `_restore_sub` 里补写 `hp_grid`**

`scenes/level_0.gd:444-445` 已有"仅该格为 0 时回填 `_pristine_grid`"的分支——在**同一分支内**补一行：

```gdscript
		if TileDefs.hp_grid_at(cell) <= 0:
			TileDefs.set_hp_grid(cell, TileDefs.hp_of(pristine_tex))
```

（`cell` = `Vector2i(sub.x / 4, sub.y / 4)`，`pristine_tex` = 该分支里已经在读的那个基线纹理变量；**照现状取名**，别新加变量。）

- [ ] **Step 5: 跑它，确认绿**

Run: 同 Step 2。Expected: `TILE COLLISION PROBE: ALL-OK(...)`。

- [ ] **Step 6: 变异验证（档 3）**

把 Step 4 补的那两行注释掉 ⇒ 必须红在相⑥b 的 `hp_grid` 那条（渲染/碰撞那条仍绿）。复原后再跑一次确认绿。

- [ ] **Step 7: 登记"回溯不还原被打磨未碎的砖血"**

在 `docs/eng/registered-debt.md` 新增一行（放在该文件 §四 指向的落点风格里，症状/为什么留着/什么时候能销三段齐全）：症状 = 瓦片账本 `_tile_pending` 只在**子格死掉**时记账（`scenes/level_0.gd:451-452`）⇒ "树干 hp30 磨到 6 时回溯"，磨掉的血**不还原**；为什么留着 = 属 rewind 保真度范围，与本轮的"格级/子格分家"是两件事；何时能销 = 把"格级 HP 的变化量"也纳入回溯账本。

- [ ] **Step 8: 提交**

```bash
git add core/sim/tile_defs.gd scenes/level_0.gd tests/probe/tile_collision_probe.gd docs/eng/registered-debt.md
git commit -m "fix(tiles): 回溯复原时把 hp_grid 一起写回(+hp_grid_at/set_hp_grid 读写口);登记『回溯不还原被打磨未碎的砖血』为已知边界"
```

---

## 本计划**不含**（避免实现者顺手做）

- **`server/match/match_round.gd:150` 只 `init_hp` 不 `init_sub_hp`** —— 待用户确认"是有意还是漏了"（裁定中的 Q12(b)）后再定；**未经确认不得动**。
- **把激光改成走 `damage_sub`** —— 用户已选 (b)：**保激光的格级路径**，打整格的手感不变。改它会带来"整格耐久 ×16"的玩法变更，不在本计划内。
- **`tests/probe/aim_probe.gd:8-9` 的陈旧数字**（2496×1872 vs 生产 2208×1728）—— 属另一批（配置/文档卫生）。
- **`tile_collision_probe.gd` 加"逐条计数闸"** —— 本计划用**跑完闩**（照 `destroyed_cells_probe.gd:22` 先例）替代；给 286 行、五个既有相的老探针逐条补计数要改掉每一处断言调用点，收益不抵风险。
