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
5. **复原把整格当成"16 次子格复原"**（Task 3）：`_restore_sub` 是按**子格**调用的，格级销毁后它会被调 16 次 ⇒ `hp_grid` 的补写必须**幂等**（16 次都写同一个满血值，不能被中间态覆盖）。→ 断言：相④b 里 16 个子格各复原一次之后，`hp_grid_at(cell)` **恰好**等于 `hp_of(tex)`（写成"每格 −1"或"取最小值"之类的实现会当场露出来）。

---

### Task 1: 服务器侧清格子格的坐标算法（2×2 → 4×4）

**Files:**
- Modify: `server/match/match_combat.gd:9-13`
- Test: `tests/probe/destroyed_cells_probe.gd`（加"相③ 走真破坏路径"，`tests/probe/destroyed_cells_probe.tscn` 不改）

**Interfaces:**
- Consumes: `MatchHost._debug_destroy_tile(delta)`（`server/match/match_host.gd:288-296`，读 `MatchState.test_destroy_cell` / `test_destroy_after`，内部调 `TileDefs.damage_tile(cell, 999999, "explosion")`）；`MatchHost.destructible_sub`（按**子格**坐标索引的二维数组，空 = `MazeGenerator.EMPTY`）。
- Produces: 无新 API —— `destructible_sub` 的语义被修正为"按子格坐标、清满 4×4"。

- [ ] **Step 1: 写失败的断言**

在 `tests/probe/destroyed_cells_probe.gd` 的 `_run()` 里、**相② 之后**加相③（沿用该文件既有的 `_check(ok, what)`；`_host` 已建好且 `:38` 已关宿主物理帧）。

★★ **控制器追认（2026-10-04，评审 ⚠️(a)）**：本 Step 的**初稿片段照抄必失败**——实现者实测出三处硬缺陷并做最小偏离，控制器裁定**偏离成立**（spec 意图不变，坏的是初稿的可执行细节）。三处如下，**下面是落地的版本**（`7453b9d`）：

| # | 初稿原文 | 实测为什么不可用 | 落地改法 |
|---|---|---|---|
| ① | `var rows/cols` | 与 `_run()` 顶部 `:44-45` 重名 ⇒ `Parse Error: There is already a variable named "rows"`，**整个探针加载失败**（连红都跑不出来） | 改名 `sub_rows` / `sub_cols` |
| ② | `var cell := Vector2i(9, 6)` 且 `_base_grid[cell] = SOLID` | newfactory 的 (9,6) 是**空气** ⇒ `damage_tile` 首行 return、回调根本不跑 ⇒ "16 子格全清"**恒真**（一个行为都没验）；而写 `_base_grid` 会凭空多一个差异，把**既有相④**打成 `3 != 2` | 把那格钉成**可破坏纹理**的非空格（`MapFormat.pack(15, 15)`）+ 钉满 16 子格；**只钉 `grid`、不钉 `_base_grid`** |
| ③ | `others == 0`（全图非空计数） | `destructible_sub` 是**整图**可破坏子格表（实测非空 **7624**）⇒ 该断言**恒红**，Step 4 永远到不了绿 | 反向断言改取**前后差**，并把 `* 2` 会误清的那 4 个子格**先钉实**（否则越界写是"把空气写成空气"，变异跑不红） |

★ 两条断言文本**原样保留**；★ 完整实测原文与变异实数见 `task-1-report.md`。

- [ ] **Step 1（落地版）**

先加一个 helper（放在该文件既有 helper 区）：

```gdscript
# 相③ 用:`destructible_sub` 里**不属于** cell 的非空子格数。
# ★ 为什么读"数"而不直接读"被清了哪些":`destructible_sub` 是**整图**的可破坏子格表
#   (newfactory 实测非空 7624 个),绝对值恒 > 0 ⇒ 只有**前后两次之差**才等于"别的格被清掉几个"。
func _solid_outside(cell: Vector2i) -> int:
	var n := 0
	var sub_rows: int = _host.destructible_sub.size()
	var sub_cols: int = _host.destructible_sub[0].size()
	for y in range(sub_rows):
		for x in range(sub_cols):
			if _host.destructible_sub[y][x] != MazeGenerator.EMPTY \
					and Vector2i(x / 4, y / 4) != cell:
				n += 1
	return n
```

再在 `_run()` 的相② 之后插入相③：

```gdscript
	# ── ③ 走**真破坏路径**(worker 用的那条) → 该格 16 子格全清,且**别的格一格没动** ──
	var cell := Vector2i(9, 6)
	_host.grid[cell.y][cell.x] = MapFormat.pack(15, 15)
	for sy in range(4):
		for sx in range(4):
			_host.destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] = MazeGenerator.SOLID
	# ★ 变异判据的**前置**:`* 2` 的越界写法会去清格 (cell.x/2, cell.y/2) 的 sx∈{2,3}×sy∈{0,1}
	#   象限(右上 32px)。那 4 个子格必须**先钉实**,否则越界写的是"把空气写成空气",变异跑不红。
	var bug_cell := Vector2i(cell.x / 2, cell.y / 2)
	for sy in range(2):
		for sx in range(2):
			_host.destructible_sub[bug_cell.y * 4 + sy][bug_cell.x * 4 + 2 + sx] = MazeGenerator.SOLID
	var others_before := _solid_outside(cell)
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
	var others := others_before - _solid_outside(cell)   # 被清掉的、属于**别的格**的子格数
	_check(others == 0, "不该有别的格被清(实际 %d 个子格)" % others)
```

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/destroyed_cells_probe.tscn`
Expected: **不出现** `DESTROYED CELLS: ALL-OK`；失败清单里点名相关断言（初稿落地前的红：`* 2` 会清到格 `(4, 3)` 的**右上** 32px 象限 ⇒ `others` > 0 而 `left` = 16）。

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

- [ ] **Step 7: 修复轮（2026-10-04，评审 ⚠️(c) 被裁定为**真缺陷**）**

★ **本步把改动面扩到 `core/sim/tile_defs.gd`**（上面 Files 行未列，以本步为准）。

**缺陷**：Step 3/4 只清了 `destructible_sub`，而**服务器的碰撞最终不按它建** —— `core/sim/collision_builder.gd:47-49` 的 `build_sub()` 注释与代码都写明"已被摧毁的子格（**子格 HP 表**已初始化且 hp≤0）不产生碰撞"，筛的是 **`TileDefs.sub_alive`（即 `sub_hp`）**；`server/match/match_round.gd:151` 与 `match_host.gd:53` 都用 `WorldBuilder.build_sim(...)` 生成 `destructible_sub` ⇒ 那个数组是**可破坏层碰撞数组**、由 `sub_hp` 现算。

★ **机制订正（2026-10-04，实现者回源码订正了我，我接受）**：初稿写的是"标了脏块之后 `rebuild_chunk` 按 `build_sub` 重算 ⇒ 碰撞又长回来" —— **错**。`CollisionBuilder.rebuild_chunk(sub, chunk, parent)`（`collision_builder.gd:147-153`）用的是**传入的数组**，局内重建不会回读 `sub_hp`。真正的缺口是**每局复位**：复位路径只 `init_hp` + `build_sim`，`sub_hp` 停在上一局的死亡状态 ⇒ `build_sim` 少建那些子格 ⇒ **下一局服务器少墙**（而客户端 `level_0.gd:474-476` 是还原两套表的）。⇒ 结论不变（修 `sub_hp` 必要），但**理由换了**：不是"脏块重建"，是"**复位时现算**"。

**做法（TDD）**：
1. `destroyed_cells_probe.gd` 相③ 里：选点改为扫 `MazeGenerator.current_subgrid` 找一格 **16 子格全 `sub_alive` 且 `explosion_destroyable`**（找不到就 `_check(false, …)` 早退）；加**前置断言**"销毁前 16 子格全 `sub_alive`"与**目标断言**"走完真路径后 16 子格 `sub_alive` **全假**"（今天**必红** —— 这就是缺口的证据）。
   ★ 为什么不能用现在钉 `_host.grid` 的那一格：`sub_hp` 是 `init_sub_hp(MazeGenerator.current_subgrid)` 建的（`match_host.gd:52`），只钉 `grid` 不会让那 16 格"活着" ⇒ 新断言会**恒真**。
2. `core/sim/tile_defs.gd` 新增**静默** API `static func zero_cell_sub_hp(cell: Vector2i) -> void`：把该格 16 个子格的 `sub_hp` 清零（`restore_sub(sub, 0)` 即可），**不**触发 `on_sub_destroyed`；`sub_cols == 0`（未初始化）时直接返回。
3. `server/match/match_combat.gd` 的 `_on_tile_destroyed`：在 4×4 清 `destructible_sub` **之前**调一次 `TileDefs.zero_cell_sub_hp(cell)`。
   ★ **为什么静默**：服务器侧的 `on_sub_destroyed` 是 `MatchCombat._on_sub_destroyed`，每次都会 `_rpc_all_ext("sub_destroyed", …)`；走带回调的路径会把 **1 条** `tile_destroyed` 广播变成 **17 条** —— **广播契约不动**（本任务不碰协议）。
4. 变异验证：注释掉那句 `zero_cell_sub_hp` ⇒ 新断言必须红。
5. 顺带订正两处**过期散文**（评审 Minor，属"改了 A 就会过期的 B"）：`server/match/match_combat.gd:10` 的"左上象限"→"**右上**"（`* 2` 落的是列 18-19 = 右半、行 12-13 = 上半）；`tests/probe/resync_world_probe.gd:142` 的"该格 2×2 子格"→"4×4"。
   **不动**：`tests/probe/perf_probe.gd:179/205-211`（评审定性为"口径已分家的合成消融"，登记时别写成"重复真相源待合并"）。


- [ ] **Step 8: §R6（2026-10-04，修复轮1 实测发现）—— 服务器复位漏了 `init_sub_hp`**

**症状（实测，非推断）**：`[tmp] 服务器复位后 grid=287 sub_alive=0 solid=0`（同一格 destroy 后是 `0/0/0`）⇒ 复位只把 `grid`/`hp_grid` 拉回基线，`sub_hp` 与由此建出的可破坏碰撞**停在上一局**。客户端 `reset_destructibles`（`level_0.gd:474-476`：`current_subgrid = copy_grid(_pristine_subgrid)` → `init_sub_hp(...)`）是还原的 ⇒ **下一局"客户端有墙、服务器没有" ⇒ 可穿墙分歧**。

**裁定（控制器，2026-10-04）**：**补进本轮**（不另开任务）。依据是**单侧遗漏**（客户端做了、服务器没做），且这条正是先前挂着待用户确认的 Q12(b)（"是有意还是漏了"）—— 现按"漏了"处理，**用证据代答**；判错代价 = 一行可回退。

**做法（TDD）**：
1. 先在 `destroyed_cells_probe.gd` 加一相：走完真破坏路径（该格 16 子格 `sub_alive` 全假）→ 调复位路径 → 断言 ①16 子格 `sub_alive` **恢复全真** ②`_host.destructible_sub` 该格 16 项**恢复实心**（两套表一起回基线）。今天**必红**。
2. `server/match/match_round.gd`：在 `TileDefs.init_hp(g)` 与 `destructible_sub = WorldBuilder.build_sim(self, g)` **之间**插入 `TileDefs.init_sub_hp(MazeGenerator.current_subgrid)`（★ 顺序不能反：`build_sim` → `build_sub` 就是按 `sub_hp` 筛的；服务器**不需要**先还原 `current_subgrid` —— 破坏从不改纹理表）。
3. 顺带订正 `scenes/level_0.gd:465` 那句过期注释。
4. 变异：注释掉新加的 `init_sub_hp` ⇒ 新断言必须红。

★ **覆盖上限照实写**：若探针在夹具里调不动真复位路径、退化成"手工照抄复位那几行"，那**照抄 = 我喂进去的输入，不构成对生产函数的验证** —— 这句必须写进探针注释。

- [ ] **验证边界（2026-10-04，评审 ⚠️(b)）**

"真 PvP 局**可达**"是**静态分析**结论（服务器不实例化 `Level0` ⇒ `Level0.pvp_mode` 恒假 ⇒ 激光走格级 `damage_tile` ⇒ 回调可达）。本计划**有意不占 7777**（见 Global Constraints）⇒ 本次提交**没有端到端证据**。要闭环必须由用户跑一次真链路（`tests/smoke/pvp_room_smoke.sh` / `pvp_match_smoke.sh`，**占 7777**，跑前先过 `lobby_alive`）。在那之前，本条只能记作"**静态可达 + 单进程探针覆盖**"，**不得**当成已证事实。

---

### Task 2: 单机格级销毁收口（`TileDefs.destroy_cell` + `Level0` 接线）

**Files:**
- Modify: `core/sim/tile_defs.gd`（在 `restore_sub`（:284）附近新增 `destroy_cell`）
- Modify: `scenes/level_0.gd:241`（接线）+ 新增 `_on_tile_destroyed`（紧邻 `_on_sub_destroyed`（:448））
- Test: `tests/probe/tile_collision_probe.gd`（在**相③ 与 相④ 之间**插入"相③b 格级路径"；该文件现**无**跑完闩，一并补）

**Interfaces:**
- Consumes: `TileDefs.damage_tile(cell, amount, source)`（格级；销毁时改 `current_grid` + `hp_grid` 并调 `on_destroyed`）、`TileDefs.restore_sub(sub, hp)`（:284，只写 `sub_hp`）、`TileDefs.sub_alive(sub)`（:237）、`Level0._on_sub_destroyed(sub, pre_hp, owner)`（:448，负责渲染 9 副本 + `_destructible_sub` + 脏块 + 瓦片账本 `_tile_pending`）。
- Produces: `TileDefs.destroy_cell(cell: Vector2i) -> void`（**供 Task 3 复用**；签名固定为单参数、无返回）。

- [ ] **Step 1: 写失败的断言**

在 `tests/probe/tile_collision_probe.gd` 的**相③ 与 相④ 之间**（`:219` 与 `:221`）插入新相。★ **动手前先读这三处既有代码**（本计划初稿在这里写错过，按下面修正版走）：

- **`_find_target()` 返回的是子格坐标**（`:128-141`）；相① 是 `Vector2i(target.x / 4, target.y / 4)` 才变成格（`:175`）——**不要**把它当格用。
- **"相⑥"这个编号已被占用**：`:279-280` 是"相⑥ 再扫一遍全场"。你的新相叫 **相③b**。
- **回溯只触发一次**：相④（`:221-225`）用 `Input.action_press("rewind")` 触发。新相必须插在相④**之前**，借那一次回溯一并复原；**不要**自己再按一次 rewind（冷却与历史长度不由你控制）。

```gdscript
	# ── 相③b 格级路径:激光真调的 API(`damage_tile`)打光整格 ⇒ 渲染/碰撞/hp 必须一起没 ──
	# 存在理由:该探针此前的破坏全走 `damage_sub`(相②/③/⑤),而**格级**这条链单机根本没接回调
	# ⇒ "整格已碎、16 子格仍 sub_alive"的幽灵砖在本探针与另外三条探针下**全绿**。
	# ★ 选点要求三条:① 该格 16 子格全 `sub_alive` 且纹理非 0;② 纹理 `explosion_destroyable`
	#   (激光传的 source 就是 "explosion";不满足则 `damage_tile` 第一行 return = 断言恒真);
	#   ③ 与相① 选中的格不同(别把相③ 的后果混进来)。
	var cell3b := Vector2i(-1, -1)
	var subs3b: Array = []
	for y in MazeGenerator.current_subgrid.size():
		for x in (MazeGenerator.current_subgrid[0] as Array).size():
			var cc := Vector2i(x / 4, y / 4)
			if cc == cell:
				continue
			var all_alive := true
			var tex3b := 0
			for s in _cell_subs(cc):
				if not TileDefs.sub_alive(s) or _tex(s) == 0:
					all_alive = false
					break
				tex3b = _tex(s)
			if all_alive and TileDefs.explosion_destroyable(tex3b) \
					and TileDefs.type_id_of(tex3b) == TileDefs.TYPE_WALL:
				cell3b = cc
				subs3b = _cell_subs(cc)
				break
		if cell3b.x >= 0:
			break
	if cell3b.x < 0:
		_fail("相③b 找不到一整格全活的可爆砖(用例前置不成立)")
	else:
		var base3b: Array = []
		for s in subs3b:
			base3b.append([_painted(s), _terrain_at(world, _sub_center(s))])
		TileDefs.damage_tile(cell3b, 999999, "explosion")
		await _wait_ms(300)                       # 脏块分帧重建(与相② 同款等待)
		var ghost := 0
		for s in subs3b:
			if _painted(s):
				ghost += 1
		if ghost != 0:
			_fail("相③b 格级销毁后仍有 %d/16 子格在画(幽灵砖)" % ghost)
		var c3b := Vector2(cell3b.x * 64 + 32, cell3b.y * 64 + 32)
		if _terrain_at(world, c3b) or _terrain_at(world, c3b + Vector2(mx, 0.0)) \
				or _terrain_at(world, c3b - Vector2(mx, 0.0)):
			_fail("相③b 格级销毁后格心(含 ±MAP_WIDTH 副本)仍有碰撞(看不见的墙)")
		if TileDefs.hp_grid[cell3b.y][cell3b.x] != 0:
			_fail("相③b 格级销毁后 hp_grid[%s] 应为 0(实得 %d)"
					% [str(cell3b), TileDefs.hp_grid[cell3b.y][cell3b.x]])
		print("[相③b] 格级销毁目标格 %s(基线已记 %d 项)残留画=%d" % [str(cell3b), base3b.size(), ghost])
```

★ 断言口是 `_fail(m: String)`（:34），**不是** `_check`。`world` / `mx` / `cell` 都是 `_run()` 里**既有**的局部变量（`:163-164`、`:175`），直接用。`_cell_subs()` / `_painted()` / `_sub_center()` / `_terrain_at()` / `_tex()` / `_wait_ms()` 都是既有 helper，别另写。
★ `cell3b` / `subs3b` / `base3b` 三个局部量 **Task 3 要用**（回溯后比对），不要改名、不要删。

同时给该文件补**跑完闩**（照 `tests/probe/destroyed_cells_probe.gd:22` 的先例，比逐条计数闸省事且等价）：`var _ran_to_end := false`，在 `_run()` 最后一行置 `true`，在打 `ALL-OK` 之前判 `if not _ran_to_end: quit(1)` 并打印"`_run()` 没跑完"。

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn`
Expected: **不出现** `TILE COLLISION PROBE: ALL-OK`；打印 `相③b 格级销毁后仍有 16/16 子格在画(幽灵砖)`（今天 `level_0.gd:241` 只接 `on_sub_destroyed`，格级回调无人接）。

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
- Test: `tests/probe/tile_collision_probe.gd`（在相④ 之后加"相④b 格级销毁 → 回溯"；复用 Task 2 留下的 `cell3b`/`subs3b`/`base3b` 与**那一次**回溯）

**Interfaces:**
- Consumes: **Task 2 已落地的格级链**（`Level0` 的 `on_destroyed` → `destroy_cell`）+ Task 2 在 `_run()` 里留下的 `cell3b` / `subs3b`（★ `base3b` **不可用**:它声明在 `else:` 块内(`tile_collision_probe.gd:282`),GDScript 有**块作用域** ⇒ 相④b 看不见它;改用探针既有的 `_expect(sub)` 与「游戏自己的规则」对账,比拿快照比对**更强**),以及**相④ 那一次回溯**（★ **不要**自己再按 rewind：冷却与历史长度不由你控制）—— 本任务的前提是 **Task 2 的相③b 已绿**；`TileDefs.hp_of(texture)`（:129）；`Level0._restore_sub(sub, hp)`（:421-445，已写 `sub_hp` / 9 副本 / `_destructible_sub` / 脏块 / `_pristine_grid` 回填）。
- Produces: `TileDefs.hp_grid_at(cell: Vector2i) -> int`、`TileDefs.set_hp_grid(cell: Vector2i, hp: int) -> void`。

- [ ] **Step 1: 写失败的断言**

在 `tile_collision_probe.gd` 的**相④ 基线断言之后**（`:238` 那句 `_fail("相④ 回溯后子格 …")` 之后、相⑤ 之前）插入相④b。★ 它**不触发新的回溯** —— 相④ 那一次已经同时复原了相③b 拆掉的那一格。

```gdscript
	# ── 相④b 相③b 那一格在回溯后必须连 hp_grid 一起回来 ──
	# ★ 复用 Task 2 留下的 cell3b / subs3b / base3b,并复用相④ 的**那一次**回溯。
	# ★ 与相④ 同款:拿**游戏自己的两条规则**(`_expect`)对账,而不是拿快照 —— 后者只能证明
	#   "回到了拆之前",前者还要求"拆之前本来就是对的"。
	var back_wrong := 0
	for s in subs3b:
		var e := _expect(s)
		if _painted(s) != bool(e[0]) or _terrain_at(world, _sub_center(s)) != bool(e[1]):
			back_wrong += 1
	if back_wrong != 0:
		_fail("相④b 回溯后相③b 那格有 %d 个子格与规则不符(渲染/碰撞有一样没回来)" % back_wrong)
	# 纹理表 `current_subgrid` 从不被破坏改动 ⇒ 回溯后读它与破坏前同值,可当满血基准
	var want3b := TileDefs.hp_of(_tex(subs3b[0]))
	if TileDefs.hp_grid_at(cell3b) != want3b:
		_fail("相④b 回溯后 hp_grid[%s] 应回到 %d(实得 %d)⇒ 下一发激光会一发即碎"
				% [str(cell3b), want3b, TileDefs.hp_grid_at(cell3b)])
```

★ 若 `back_wrong != 0` 先红，说明相④ 的回溯没覆盖到相③b 那格（多半是台账没记上）—— **先查夹具再谈结论**，别急着改 `hp_grid` 那半。

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn`
Expected: **不出现** `ALL-OK`；打印 `相④b 回溯后 hp_grid[...] 应回到 NN(实得 0)`（NN = 该砖的 `hp_of`；树叶 8 / 树干 30）。★ 若第一句"没回到基线"也红，说明相④ 的回溯没覆盖相③b 那格 —— **先修夹具再谈结论**。

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

★ **按实况**(已核实):`_restore_sub(e: Dictionary)` 的形参是**字典** `e`(读 `e["sub"]` / `e["hp"]`),里面**已有** `var cell := Vector2i(sub.x / 4, sub.y / 4)` 与 `var tex := int(MazeGenerator.current_subgrid[sub.y][sub.x])`(纹理表从不被破坏改动 ⇒ 它**就是**基线纹理)。所以写回用的是**既有局部量**,别新加变量;要补的那一行是 `TileDefs.set_hp_grid(cell, TileDefs.hp_of(tex))`(不是 `hp_of(_pristine_grid[...])` —— 那是**打包值**不是纹理)。

- [ ] **Step 5: 跑它，确认绿**

Run: 同 Step 2。Expected: `TILE COLLISION PROBE: ALL-OK(...)`。

- [ ] **Step 6: 变异验证（档 3）**

把 Step 4 补的那两行注释掉 ⇒ 必须红在相④b 的 `hp_grid` 那条（渲染/碰撞那条仍绿）。复原后再跑一次确认绿。

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
