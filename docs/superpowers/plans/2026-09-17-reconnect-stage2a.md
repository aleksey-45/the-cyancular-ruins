# 断线重连【阶段 2-A】实施计划（重连后补齐破坏态与地面武器）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 闭合阶段 1 留下的缺口 —— 掉线那 30 秒里**被拆的墙**与**变动过的地面武器**在重连后补回客户端，消掉"幻影墙"导致的预测分歧。

**Architecture:** 不新造通道。`match_sync` 本来就是**客户端主动拉取**的进场数据包（且已带 `ground_weapons`）—— 给它加一个 `destroyed` 字段（服务端 `grid` 与 `_base_grid` 的差异格），并让**重连成功后也拉一次**。一箭双雕：`destroyed` 与 `ground_weapons` 一起回来，覆盖掉线期间丢掉的两类可靠事件。客户端侧**复用现有的 `_on_remote_tile_destroyed`**（它已经会清瓦片 + 碰撞层），只给它加一个"静默"开关（补态时不播碎片）。

**Tech Stack:** Godot 4.7.1 GDScript；`NetBus`（客户端 ↔ worker 的 RPC 通道，**方法表一律不动**）；`-s` 冒烟与 `tests/*.tscn` 场景探针。

## Global Constraints

- **本项目约定：测试由用户自己跑，不要代跑。** 计划里每条 `Run:` 是**写给用户**的；agent 自己可执行的是 `--import`、不占端口的 `--quit-after` 自检、以及**不占 7777 的探针**（`reconnect_probe` 用池外端口 29001/29002/29090，可自己跑；`royale_probe`/`pvp_room_smoke` 一律留给用户）。
- **引擎路径**：`GODOT` 环境变量，未设时回落 `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`（**console 版**）。
- **★ `NetBus` 的方法表一律不动**（原 NetBus 要与原版服务端逐字节一致）。本批**不新增任何 RPC** —— 全部复用 `match_sync` / `match_sync_data`。
- **★ 定向发送前一律先判活**（`NetBus.reply` / `is_peer_live`）。
- **★ 新建 `class_name` 文件后 `--import` 刷类缓存**（本批不新建，但改了 `match_state.gd` 等要 `--import` 自检）。
- **场景探针 `--quit-after` 给足**：本仓既有教训是"安全网太薄会把'跑得慢'读成'功能坏了'"。`reconnect_probe` 用 **14400**（它要跑满 30s 宽限期，整跑 ≈42s 墙钟）。
- 判据 grep 文本 `ALL-OK`，**不看退出码**。
- **提交信息用单引号或 `-F 文件`**，不带任何 Claude/AI 署名行；提交后回读。
- 每次 `git add` 只加本任务明确指定的文件。工作区有未跟踪的 `_crashtest/`，**不要动**（`.superpowers/` 已自带 `.gitignore`）。
- **字号只用 16 的倍数**（`kh_l4/l5` 扫 `res://tests`）。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `server/match_state.gd` | 修改 | 新增 `destroyed_cells()` —— `grid` 与 `_base_grid` 的差异格（纯查询，住在字段所在的那一层） |
| `tests/destroyed_cells_probe.gd/.tscn/.uid` | **新建** | 场景探针：真建 `MatchHost`（`role_peers` 传空）钉 `destroyed_cells()` 的语义 |
| `server/server_main.gd` | 修改 | `_on_match_sync` 的应答里**有差异时**带 `destroyed` |
| `scenes/pvp_match_client.gd` | 修改 | ① `_on_remote_tile_destroyed(cell, silent)` 加静默开关；② 应用 `destroyed`；③ `_on_resumed` 追加拉 `match_sync`；④ 地面武器**先清后灌** |
| `tests/reconnect_probe.gd` | 修改 | 加一相：掉线期间**拆一堵墙 + 掉一把枪**，重连后断言两端一致 |
| `CLAUDE.md` | 修改 | 记录 2-A（含"路径甲现在也要拉 `match_sync`"这条反直觉的点） |

---

## Task 1: `MatchHost.destroyed_cells()` + 探针

**Files:**
- Modify: `server/match_state.gd`（`grid` / `_base_grid` 就在 `:25-26`）
- Create: `tests/destroyed_cells_probe.gd` + `tests/destroyed_cells_probe.tscn`

**Interfaces:**
- Consumes: `MatchState.grid: Array`、`MatchState._base_grid: Array`
- Produces: `MatchHost.destroyed_cells() -> Array[Vector2i]`（**按 y 升序、同 y 按 x 升序**，确定性）

- [ ] **Step 1: 写失败的探针 `tests/destroyed_cells_probe.gd`**

```gdscript
extends Node

# `MatchHost.destroyed_cells()` 探针(场景模式:root 有 autoload/`multiplayer`)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/destroyed_cells_probe.tscn
# 通过 = `DESTROYED CELLS: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这个方法喂的是"重连后补破坏态"的载荷。它算错的表现是**静默**的:客户端少补几格墙
#   (留下幻影墙 → 预测分歧)或多补几格(凭空拆墙)。两种都不报错,只有真比对才照得出来。
# ★ 确定性:顺序必须是"按 y 升序、同 y 按 x 升序",否则同样的地图会给出不同的数组,
#   载荷无法逐字比对(联机侧要能复现)。
# 做法同 match_host_hygiene_probe:真建 MatchHost,但 **role_peers 传空** —— 不建玩家、不排 peer、不发包。

const MAP := "res://maps/factory1v1.cyrm"

var _fails: Array[String] = []
var _host = null


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_host = MatchHost.new(MAP, {}, {}, [])
	add_child(_host)
	# ★ 关掉宿主自己的物理帧:本探针手工摆 `grid`,不需要它自跑(不关的话 `quit(0)` 是帧末生效,
	#   中间还会跑一帧 `_physics_process` 去读桩对象 → 在断言全过之后刷一屏 SCRIPT ERROR)。
	_host.set_physics_process(false)
	_run()
	_finish()


func _run() -> void:
	var rows: int = _host.grid.size()
	var cols: int = _host.grid[0].size()
	_check(rows > 0 and cols > 0, "宿主建局后有网格(%d×%d)" % [rows, cols])

	# ── ① 未动过 → 空数组 ──
	_check(_host.destroyed_cells().is_empty(), "刚建局的网格差异应为空")

	# ── ② 拆 3 格 → 恰好 3 个,且**顺序确定**(按 y 升序、同 y 按 x 升序)──
	# 故意逆序拆,看返回是否仍按序
	_host.grid[5][7] = MazeGenerator.EMPTY
	_host.grid[2][3] = MazeGenerator.EMPTY
	_host.grid[5][1] = MazeGenerator.EMPTY
	var d: Array = _host.destroyed_cells()
	_check(d.size() == 3, "拆 3 格应报 3 个(实际 %d)" % d.size())
	_check(d == [Vector2i(1, 5), Vector2i(3, 2), Vector2i(7, 5)] as Array,
			"★ 顺序必须是「按 y 升序、同 y 按 x 升序」(实际 %s)" % str(d))

	# ── ③ 反向:只改回一格 → 只剩 2 个(证明它比的是**差异**不是"非实心")──
	_host.grid[2][3] = _host._base_grid[2][3]
	_check(_host.destroyed_cells().size() == 2, "改回一格后应剩 2 个")

	# ── ④ 反向:凭空**加**一格实心(基线是空的地方填实心)也要报 ──
	# ★ 不能只比"当前是不是 EMPTY" —— 服务器理论上不会加砖,但契约是"与基线不同",
	#   写成"当前为空"会在将来加砖时静默漏报。
	var ey := -1
	var ex := -1
	for y in range(rows):
		for x in range(cols):
			if int(_host._base_grid[y][x]) == MazeGenerator.EMPTY and int(_host.grid[y][x]) == MazeGenerator.EMPTY:
				ey = y
				ex = x
				break
		if ey >= 0:
			break
	_check(ey >= 0, "地图里能找到一格基线为空的位置")
	if ey >= 0:
		_host.grid[ey][ex] = MazeGenerator.SOLID
		var d4: Array = _host.destroyed_cells()
		_check(d4.has(Vector2i(ex, ey)), "★ 与基线不同就该报(不管变空还是变实心)(实际 %s)" % str(d4))
		_host.grid[ey][ex] = MazeGenerator.EMPTY


func _finish() -> void:
	if _fails.is_empty():
		print("DESTROYED CELLS: ALL-OK")
		get_tree().quit(0)
	else:
		print("DESTROYED CELLS: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)
```

- [ ] **Step 2: 写 `tests/destroyed_cells_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/destroyed_cells_probe.gd" id="1"]

[node name="DestroyedCellsProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次确认它红**

Run（**让用户跑**）：`timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/destroyed_cells_probe.tscn`
Expected: 报 `Invalid call. Nonexistent function 'destroyed_cells'`（方法还没写）。

- [ ] **Step 4: 在 `server/match_state.gd` 加方法**

放在 `grid` / `_base_grid` 两个字段之后（`_dirty_chunks` 之前），紧挨它操作的两个字段：

```gdscript
# 与建局基线(`_base_grid`)**不同**的格。给"重连后补破坏态"与"回大厅后回局"用:
# 客户端重进/重连时只拿 `match_path` 重建初始地图,而服务器上是破坏后的 `grid`
# → 不补这一份,客户端会留着服务器已摧毁的墙(**幻影墙** → 玩家撞上去 → 本地预测与服务端
# 分歧 → 可能回滚循环),或是凭空少墙。
# ★ 判据是"与基线不同",**不是**"当前为空":后者在将来出现"加砖"类改动时会静默漏报。
# ★ 顺序确定性(y 升序、同 y 升序 x):载荷要能在两端逐字比对。
# ★ 规模上限:125×75 = 9375 格,全被拆也只有 9k 条 Vector2i —— 调用方**只在非空时才带**该字段。
func destroyed_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var rows := mini(grid.size(), _base_grid.size())
	for y in range(rows):
		var cur: Array = grid[y]
		var base: Array = _base_grid[y]
		var cols := mini(cur.size(), base.size())
		for x in range(cols):
			if int(cur[x]) != int(base[x]):
				out.append(Vector2i(x, y))
	return out
```

- [ ] **Step 5: `--import` 并让用户跑探针确认绿**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 120 "$GODOT" --headless --path . --quit-after 3600 res://tests/destroyed_cells_probe.tscn`
Expected: `DESTROYED CELLS: ALL-OK`。

- [ ] **Step 6: 提交**

```bash
git add server/match_state.gd tests/destroyed_cells_probe.gd tests/destroyed_cells_probe.gd.uid tests/destroyed_cells_probe.tscn
git commit -m 'feat(net): MatchHost.destroyed_cells() —— 与建局基线的差异格(补破坏态用)+ 探针'
```

---

## Task 2: `match_sync_data` 带上 `destroyed`

**Files:**
- Modify: `server/server_main.gd`（`_on_match_sync` 的应答字典）

**Interfaces:**
- Consumes: `MatchHost.destroyed_cells()`（Task 1）
- Produces: `match_sync_data` 数据包新增可选字段 `destroyed: Array[Vector2i]`（**空数组时不带该键**）

- [ ] **Step 1: 改 `_on_match_sync` 的应答**

在 `var ground: Array = []` 那一段之后、`if not NetBus.is_peer_live(caller):` **之前**插入：

```gdscript
	# 掉线窗口内被拆的墙:与基线不同才带(**空数组不带该键**,避免每局固定多几 KB)。
	# ★ 为什么放在 match_sync 而不是新开一条 RPC:这条本来就是"客户端主动拉取的全量进场载荷",
	#   复用它可以不碰 NetBus 的方法表(硬纪律),也让"重连后补态"与"进场建态"走同一条路。
	var destroyed: Array = []
	if _host != null and _host.has_method("destroyed_cells"):
		destroyed = _host.destroyed_cells()
```

应答字典改成（先构造再按需塞键，保持"空则不带"）：

```gdscript
	var data := {
		"names": _claim_names,
		"hues": _claim_hues(),
		"options": _claim_opts.get(1, {}),
		"roles": _role_set,
		"spawns": spawns,
		"ground_weapons": ground,
	}
	if not destroyed.is_empty():
		data["destroyed"] = destroyed
	NetBus.rpc_id(caller, "match_sync_data", data)
```

- [ ] **Step 2: `--import` 自检**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error。

- [ ] **Step 3: 提交**

```bash
git add server/server_main.gd
git commit -m 'feat(net): match_sync 应答带 destroyed(与基线不同的格;空则不带该键)'
```

---

## Task 3: 客户端应用 `destroyed`（含"静默"开关）

**Files:**
- Modify: `scenes/pvp_match_client.gd`（`_on_remote_tile_destroyed` 与 `_on_match_sync`）

**Interfaces:**
- Consumes: `match_sync_data.destroyed`（Task 2）
- Produces: `PvpMatchClient._on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void`（**签名加了一个带默认值的参数**，既有唯一的调用点不受影响）

- [ ] **Step 1: 给 `_on_remote_tile_destroyed` 加静默开关**

现在是：

```gdscript
func _on_remote_tile_destroyed(cell: Vector2i) -> void:
	if _world == null:
		TileDefs.damage_tile(cell, 999999, "explosion")
		return
	...
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)
```

改成：

```gdscript
# silent=true 用于"重连后补破坏态":那些砖是**掉线期间**被拆的,不是刚被拆的 ——
# 逐格播碎片会变成一屏不该有的粒子(而且几十格同时炸)。
func _on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void:
	if _world == null:
		TileDefs.damage_tile(cell, 999999, "explosion")
		return
	# 取被拆砖原纹理(决定碎片颜色:树叶绿/树干棕),再清砖
	var tex := 0
	var grid := MazeGenerator.current_grid
	if not grid.is_empty() and cell.y >= 0 and cell.y < grid.size():
		var row: Array = grid[cell.y]
		if cell.x >= 0 and cell.x < row.size():
			tex = MazeGenerator.texture_of(int(row[cell.x]))
	TileDefs.damage_tile(cell, 999999, "explosion")
	if silent:
		return
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)
```

- [ ] **Step 2: 在 `_on_match_sync` 里应用 `destroyed`**

在 `_on_match_sync` 的**末尾**（`ground_weapons` 那段之后）追加：

```gdscript
	# 掉线窗口内被拆的墙:重连后补回(进场那次该字段为空 —— 刚建的世界与基线一致)。
	# ★ 复用 `_on_remote_tile_destroyed` 的静默形态,不另写一套清瓦片/清碰撞的逻辑。
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)
```

★ **必须放在地面武器那段之后**：两段互不依赖，但顺序固定便于比对与阅读。

- [ ] **Step 3: `--import` 自检**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error。

- [ ] **Step 4: 提交**

```bash
git add scenes/pvp_match_client.gd
git commit -m 'feat(pvp): 客户端应用 match_sync 的 destroyed(静默补态,不播碎片)'
```

---

## Task 4: 重连后拉 `match_sync` + 地面武器「先清后灌」

**Files:**
- Modify: `scenes/pvp_match_client.gd`（`_on_resumed` 与 `_on_match_sync`）

**Interfaces:**
- Consumes: `_on_match_sync`（既有）、`NetBus.rpc_id(1, "match_sync")`（既有请求口）
- Produces: `PvpMatchClient._clear_ground_weapons() -> void`

- [ ] **Step 1: 加 `_clear_ground_weapons()`**

放在 `_spawn_pickup_node`（现 `:299`）旁边：

```gdscript
# 清空本端的地面武器表与全部拾取物节点。给 `_on_match_sync` 的"先清后灌"用。
# ★ 为什么必须先清:`match_sync` 的 `ground_weapons` 是**全量**,而重连时本地表里还留着
#   掉线前的条目 —— 不清就直接 add,掉线期间**已被服务器移除**的那些会变成**永久幽灵枪**
#   (看着在、按 F 无效)。这正是阶段 2-A 要闭合的两类缺口之一。
#   进场那次本地本来是空的,清一遍是 no-op(所以统一走这条路,不为两种情况分叉)。
func _clear_ground_weapons() -> void:
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	ground_weapons.clear()
	_self_drop_until.clear()
```

★ `ground_weapons.clear()` 与 `_self_drop_until.clear()` 要用 `GroundWeaponField` 与本地表**已有的**清空口 —— 实施时先 grep 确认这两个名字在位（`ground_weapons` 是 `GroundWeaponField`，`clear()` 在阶段 1 之前就有；`_self_drop_until` 是客户端的 `inst → ms` 表）。

- [ ] **Step 2: `_on_match_sync` 改成先清后灌**

把 `_on_match_sync` 里那段地面武器的循环：

```gdscript
	var gw: Array = payload.get("ground_weapons", [])
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)
```

改成：

```gdscript
	# ★ **先清后灌**:载荷是全量,本地可能还留着掉线前的条目 → 不清会产生幽灵枪(见 _clear_ground_weapons)。
	var gw: Array = payload.get("ground_weapons", [])
	_clear_ground_weapons()
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)
```

- [ ] **Step 3: `_on_resumed` 末尾拉一次 `match_sync`**

在 `_on_resumed()` 的**最后一行**（现在是 `print("[pvp] 重连成功")`）**之前**插入：

```gdscript
	# ★ 路径甲(局内自动重连)**原来不需要 `match_sync`** —— 场景没重建、本地世界还在。
	#   现在需要了:**世界在掉线那 30 秒里变过**。这一拉把两类丢掉的可靠事件一次补回:
	#     · destroyed   —— 被拆的墙(不补 → 幻影墙 → 预测分歧)
	#     · ground_weapons —— 掉落/被捡走的枪(不补 → 幽灵枪 / 看不见的枪)
	#   ★ 顺序要紧:上面已经把 C2 重置完了(新 rollback / _input_seq=0),**再**拉。
	#     反过来的话,应答里的出生点校正(_correct_local_spawn)会与重置打架。
	#   ★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了**不报错**,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")
```

★ **实施时确认**：`_on_resumed()` 现在是在**基类** `pvp_match_client.gd` 里（阶段 1 Task 6 加的）—— 就近插入即可，两个模式共用 ✓。

- [ ] **Step 4: `--import` + 启动自检**

Run: `"$GODOT" --headless --path . --import`
Run: `timeout 120 "$GODOT" --headless --path . --quit-after 90` → exit 0、无 ERROR。

- [ ] **Step 5: 提交**

```bash
git add scenes/pvp_match_client.gd
git commit -m 'feat(pvp): 重连成功后拉 match_sync 补破坏态;地面武器改为先清后灌'
```

---

## Task 5: 真链路探针加一相

**Files:**
- Modify: `tests/reconnect_probe.gd`（沿用它的六相骨架与 `reconnect_watcher`）

**Interfaces:**
- Consumes: 前四个任务的产物
- Produces: 判据仍是 `RECONNECT PROBE: ALL-OK`

- [ ] **Step 1: 加"相⑦：掉线期间世界变过,重连后两端一致"**

在本探针既有的相里插一相（沿用现有的 actor/witness 与 `_check` 风格）：

```
相⑦ 步骤:
  ① actor 进对局、确认世界就绪后,**记录当前墙面状态**:挑一堵**可破坏**的墙
     (用 MazeGenerator.current_grid 找一格 texture 15-20 的墙 —— 树叶/树干,不可破坏的墙拆不掉)。
  ② 让 actor 掉线(沿用相① 的触发方式,即直接调 `_begin_reconnect()`)。
  ③ **掉线窗口内**(actor 不在线时)由裁判在**服务端**那侧制造两处变化:
     · 对那格调用服务端权威的破坏路径(与既有的 `tile_destroyed` 广播同源),
       让服务器 `grid` 真的变、并广播给 witness;
     · 再喂一把地面武器(用探针已有的"喂枪"入口,或直接调 `MatchGround` 的生成口)。
  ④ 等 actor 重连成功(`_on_resumed` 已跑)。
  ⑤ 断言:
     · actor 本地**那格墙已被拆**(读 `MazeGenerator.current_grid` 该格 == EMPTY);
     · actor 本地的地面武器表里**有**那把新枪(按 inst 查 `ground_weapons.get_entry(inst)` 非空);
     · 反向:再让服务器**移除**一把 actor 掉线前就存在的枪 → actor 重连后本地表里**没有**它
       (这条专钉"先清后灌"—— 只 add 不 clear 的实现会在这里红)。
```

★ **否定断言不能省**：只断言"补上了新的"会让"只 add 不 clear"的实现全部通过，而那正是幽灵枪的成因。

★ 相⑦ 需要裁判能在**服务端侧**动手（本探针的 worker 是它自己拉起的，`_host` 可达）。若现有骨架取不到 `_host`，就用**已有的喂枪/拆墙调试入口**（阶段 1 之前的 `weapon_pickup` 探针就有"仅测试用的喂枪入口"，`tests/ground_action_probe` 也用过）。

- [ ] **Step 2: 跑（可自己跑，不占 7777）**

Run: `timeout 900 "$GODOT" --headless --path . --quit-after 14400 res://tests/reconnect_probe.tscn`
Expected: `RECONNECT PROBE: ALL-OK`（七相全部通过）。
★ 跑前确认没有别的 godot 在跑（本机可能有个真大厅占着 7777 —— 探针用池外端口，不冲突，但**不要杀它**）。

- [ ] **Step 3: 反向验证**

把 Task 4 Step 2 的 `_clear_ground_weapons()` 那一行**去掉** → 重跑 → 确认相⑦ 的**否定断言报错失败** → 加回。
把两次输出写进报告。

- [ ] **Step 4: 提交**

```bash
git add tests/reconnect_probe.gd
git commit -m 'test(net): 相⑦ —— 掉线期间世界变过,重连后墙与地面武器两端一致(含反向断言)'
```

---

## Task 6: 同步 `CLAUDE.md`

- [ ] **Step 1: 记进「断线重连」那一节**

必须写进去的三点（每点都是"后人会踩"的）：

1. **`match_sync` 现在带 `destroyed`**（`grid` 与 `_base_grid` 的差异格，空则不带该键），客户端用**静默形态**的 `_on_remote_tile_destroyed` 逐格应用。
2. **★ 路径甲（局内自动重连）现在也要拉 `match_sync`** —— 反直觉，因为"场景没重建、本地世界还在"，但**世界在掉线期间变过**。漏了不报错，只是世界悄悄不一致（幻影墙 / 幽灵枪）。
3. **地面武器一律"先清后灌"** —— `match_sync` 的 `ground_weapons` 是全量，不清直接 add 会让"掉线期间已被服务器移除"的枪变成**永久幽灵枪**。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录阶段 2-A(destroyed / 路径甲也要拉 match_sync / 地面武器先清后灌)'
```

---

## 自检记录

**spec 覆盖**：spec §2.1（复用 `match_sync` + 路径甲也要拉）→ Task 4；§2.2（`destroyed_cells()` + 只在非空时带）→ Task 1/2；§2.3（复用 `_on_remote_tile_destroyed` + 静默开关）→ Task 3；§2.4（先清后灌 + 顺序：先重置 C2 再拉）→ Task 4；§7 风险 1（数据包大小）→ Task 1 的注释记了规模上限，Task 5 可量一次；§7 风险 2（空窗）→ Task 4 Step 2 的注释；§7 风险 3 → 属 2-B，不在本计划。

**本计划不做**（属 2-B / 3）：`rejoin_request` 与大厅房间保留、HUD 可见性、`opponent_left` 不可达、`ai_duel`、端口 360（§0 第 2 条，一行常量，可并入 2-B）。

**现场确认项**（计划里已标 ★，不是占位符而是"必须看真实签名"）：
1. `GroundWeaponField.clear()` 与客户端 `_self_drop_until` 的清空口名字（Task 4 Step 1）。
2. 相⑦ 能否从探针侧取到服务端 `_host`（Task 5 Step 1）。
