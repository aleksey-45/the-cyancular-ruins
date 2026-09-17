# 武器地面拾取（联机）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把单机已落地的"背包 + 地面武器"接上 PvP / 大乱斗：服务器权威地面武器表与背包，客户端渲染副本并等服务器确认。

**Architecture:** 服务器侧在 `MatchHost` 继承链里插一个新域文件 `server/match_ground.gd`（地面武器表 + 拾取/丢弃裁决 + 两条事件广播）；初始分布随现有的 `match_sync` 进场拉取一并下发（**不走推送**，理由见 spec §6.3）；背包进 `capture_state` 让 rollback 重放有正确初态；客户端在 `PvpMatchClient`（1v1 与大乱斗的共同基类）持一份只读表 + 一组 `WeaponPickup` 渲染节点。

**Tech Stack:** Godot 4.7 标准版、GDScript、ENet RPC（`NetBus` autoload）、C2 客户端预测 + rollback。

**依据 spec:** `docs/superpowers/specs/2026-09-15-weapon-slots-and-pickup-design.md` §6 / §7.3 / §8

## Global Constraints

- **缩进一律用 TAB**；字号必须是 16 的倍数。
- **`-s` 冒烟必须有空载守卫** + 跑新冒烟一律套 `timeout`（抛错会永久挂起）。
- **测试由用户自己跑**；需要真实渲染的探针由实施者跑并**自己读图**。
- **继承链约束**：`RoyaleHost → MatchHost → MatchRound → MatchCombat → MatchSnapshot → MatchState`。中间层（MatchRound 及以下）**不得定义** `_init/_ready/_enter_tree/_exit_tree/_physics_process`（`match_state.gd:14-16`）；新增域的**普通函数**可以放中间层，生命周期钩子只能放 `MatchHost`/`RoyaleHost`。
- ★ **新事件只进 `NetBus`，不进 `NetBusExt`** —— 两者 `beam_fired` 重名（`net_bus.gd:148` / `net_bus_ext.gd:41`），挂错节点会**静默 no-op**。
- ★ **`inv` 进 `capture_state`/`restore_state`，绝不进 `_close_enough`** —— 后者是**显式白名单**（只比 `down`/`hp`/`pos`/`vel`，`prediction_rollback.gd:148-157`），所以只要不主动加进去就自动满足。
- ★ **不做客户端预测**（spec §6.4）：按 F/Q 只上行，客户端等服务器事件回来才动背包。
- **加位 = 改协议**（`BIT_PICKUP`=32 / `BIT_DROP`=64 已在 Task 4 落地，本计划只是**消费**它们）。

---

## 文件结构

**新建**

| 文件 | 职责 |
|---|---|
| `server/match_ground.gd` | 服务器地面武器域：表、拾取/丢弃裁决、两条事件广播、初始分布、换局重置 |

**修改**

| 文件 | 改动 |
|---|---|
| `scenes/player/player.gd` | `capture_state` 加 `inv`；`restore_state` **先**重建背包**再** `equip` |
| `core/net/net_bus.gd` | 加 `weapon_spawned` / `weapon_removed` 两条 RPC + 两个 `local_*` 信号 |
| `server/match_state.gd` | 链尾插入点（`match_snapshot.gd` 的 `extends` 改指 `MatchGround`） |
| `server/match_host.gd` | `_physics_process` 消费输入后调地面武器裁决 |
| `server/match_round.gd` | `_respawn_player` 改"除随机一把外全丢"；`_reset_world_and_clear_dynamics` 加地面武器重置 |
| `server/server_main.gd` | `match_sync_data` 载荷加 `ground_weapons` |
| `scenes/pvp_match_client.gd` | 持只读表 + 渲染节点；消费 `match_sync` 与两条事件 |
| `scenes/weapons/weapon_pickup.gd` | 渲染位置改为"锚到最近副本"（canonical 与渲染分离） |
| `scenes/level_0.gd` | 单机侧也提供锚点（同一个 bug 在单机也存在） |
| `ui/pvp_hud.gd` + `ui/royale_hud.gd` | 接 `WeaponSlots` |

**本文档中 headless 命令的 `$GODOT`** = `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`。

---

### Task 1: `capture_state` / `restore_state` 带 `inv`

**Files:**
- Modify: `scenes/player/player.gd`（`capture_state` 末尾、`restore_state` 的武器段）
- Test: `tests/pvp_twin_smoke.sh`（扩一条断言）

**Interfaces:**
- Consumes: `WeaponComponent.snapshot_inventory() -> Array`、`WeaponComponent.restore_inventory(entries: Array) -> void`（单机计划已落地）
- Produces: `capture_state()` 多一个键 `"inv"`

- [ ] **Step 1: 改 `capture_state`**

在 `scenes/player/player.gd` 的 `capture_state()` 里，`st["wslot"] = weapons._current_slot` 那一行之后加：

```gdscript
	# 背包整表(每条 {type, inst, mag})。★ 即便不做客户端预测也必须进整态:
	#   restore_state 会 equip(wslot),若不先重建背包,重放时可能切到客户端背包里
	#   **没有的类型** → 走到 equip() 的"没有就加"分支 → 凭空造出一把服务器没有的枪。
	# ★ 与 mag/rld 同口径:只进 capture/restore,**不进** `_close_enough` 的比对
	#   (后者是显式白名单,只要不主动加进去就自动满足)。
	st["inv"] = weapons.snapshot_inventory()
```

- [ ] **Step 2: 改 `restore_state`**

把 `restore_state` 里武器那两行：

```gdscript
	var wslot := int(st.get("wslot", weapons._current_slot))
	if wslot > 0 and wslot != weapons._current_slot:
		weapons.equip(str(wslot))
```

换成：

```gdscript
	# ★ 顺序不可反:**先读 wslot**(此时 _current_slot 还有旧值,可作默认),
	#   **再重建背包**(restore_inventory 会把 _current_slot 清 0),**最后** equip。
	#   反过来的话:restore 之后 _current_slot 已是 0,wslot 的默认值就丢了;
	#   而先 equip 再 restore 会让 equip 在**旧背包**上工作(凭空造枪/丢枪)。
	var wslot := int(st.get("wslot", weapons._current_slot))
	weapons.restore_inventory(st.get("inv", []))
	if wslot > 0 and wslot != weapons._current_slot:
		weapons.equip(str(wslot))
```

- [ ] **Step 3: 扩 `pvp_twin_smoke.sh`**

在既有的 capture/restore 往返断言后加一条：摆一个已知背包（`p.set_initial_inventory([1, 3])`）、打掉几发、`capture_state()` → `restore_state()` → 断言 `held.size()` 与两条的 `mag` 都还原。

- [ ] **Step 4: 跑**

```bash
bash tests/pvp_twin_smoke.sh
```
Expected: PASS（脚本自带 taskkill + kill_port 收尾）。

- [ ] **Step 5: 提交**

```bash
git add scenes/player/player.gd tests/pvp_twin_smoke.sh
git commit -m "feat(net): 背包整表进 capture/restore —— rollback 重放才有正确初态"
```

---

### Task 2: 服务器地面武器域 `server/match_ground.gd`

**Files:**
- Create: `server/match_ground.gd`
- Modify: `server/match_snapshot.gd:2`（`extends MatchState` → `extends MatchGround`）
- Modify: `core/net/net_bus.gd`（两条 RPC + 两个信号）
- Modify: `server/match_host.gd`（`_physics_process` 里挂钩）

**Interfaces:**
- Consumes: `GroundWeaponField`、`WeaponPickup`、`GridPathfinder.spread_cells`、`MatchState._rpc_all`
- Produces:
  - `ground_weapons: GroundWeaponField`
  - `_spawn_ground_weapon(type_id, mag, pos, vel, inst := 0, self_role := -1) -> int`
  - `_remove_ground_weapon(inst) -> void`
  - `_scatter_ground_weapons(types: Array) -> void`
  - `_setup_ground_weapons() -> void`（开局：铺 + 每人随机拿 1）
  - `_reset_ground_weapons() -> void`（换局：清 + 重铺 + 重置各人背包）
  - `_drop_all_but_one(p: Node2D, role: int) -> void`（复活）
  - `_handle_ground_actions(role: int, src: PacketInputSource) -> void`
  - `ground_weapons_payload() -> Array`（给 `match_sync_data`）
  - `_sync_ground_positions() -> void`

- [ ] **Step 1: 加两条 RPC 与信号**

`core/net/net_bus.gd`，在 `round_state` 那条附近加：

```gdscript
# ── 地面武器事件(2026-09-15)──
# ★ 只进 NetBus,**不要**在 NetBusExt 里也加一份:两者 beam_fired 重名(net_bus.gd:148 /
#   net_bus_ext.gd:41),接收端挂错节点会**静默 no-op**(对手的枪凭空消失且不报错)。
@rpc("authority", "reliable")
func weapon_spawned(data: Dictionary) -> void:
	local_weapon_spawned.emit(data)

@rpc("authority", "reliable")
func weapon_removed(data: Dictionary) -> void:
	local_weapon_removed.emit(data)
```

信号区加：

```gdscript
signal local_weapon_spawned(data: Dictionary)
signal local_weapon_removed(data: Dictionary)
```

- [ ] **Step 2: 建 `server/match_ground.gd`**

```gdscript
class_name MatchGround
extends MatchState

# 地面武器域(服务器权威):表 + 拾取/丢弃裁决 + 事件广播 + 初始分布/换局重置。
#
# ★ 本文件是继承链的**中间层**(…→ MatchSnapshot → MatchGround → MatchState),
#   按 match_state.gd 的规矩**不得定义** _init/_ready/_physics_process ——
#   编排仍由 MatchHost._physics_process 每帧显式调用下面的函数。
#
# ★ 为什么服务器要**真的实例化 WeaponPickup**:落体决定最终落点,而落点直接决定
#   "够不够得着"。纯逻辑表只存位置、不会算落体;复用 WeaponPickup 的物理就两端同源。
#   代价是 headless 服务器上多 12 个(带哑视觉的)节点 —— 可忽略,真要省再说。

var ground_weapons := GroundWeaponField.new()
var _next_ground_inst := 1
var _ground_nodes: Dictionary = {}     # inst -> WeaponPickup(服务器侧;headless 不渲染)
var _self_drop_until: Dictionary = {}  # role -> {inst: 解禁时刻(ms)},防"丢完立刻捡回"

func _server_weapon_types() -> Array:
	var out: Array = []
	for slot in [1, 2, 3, 4, 5, 6]:
		if not _disabled_weapons.has(slot):
			out.append(slot)
			out.append(slot)   # 每种 2 把(与单机同款)
	return out

func _grid_dims_cells() -> Vector2i:
	return Vector2i(maxi(1, int(GameParameters.MAP_WIDTH / GameParameters.TILE_SIZE)),
			maxi(1, int(GameParameters.MAP_HEIGHT / GameParameters.TILE_SIZE)))

func _spawn_ground_weapon(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_role: int = -1) -> int:
	if inst <= 0:
		inst = _next_ground_inst
		_next_ground_inst += 1
	else:
		_next_ground_inst = maxi(_next_ground_inst, inst + 1)
	var node: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	node.configure(type_id, inst, mag, vel)
	add_child(node)          # 与碰撞层同级(WorldBuilder.build_sim 也挂在 host 上)
	node.global_position = pos
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_ground_nodes[inst] = node
	if self_role >= 0:
		if not _self_drop_until.has(self_role):
			_self_drop_until[self_role] = {}
		(_self_drop_until[self_role] as Dictionary)[inst] = \
			Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return inst

func _remove_ground_weapon(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_ground_nodes.erase(inst)
	for role in _self_drop_until:
		(_self_drop_until[role] as Dictionary).erase(inst)

# 服务器每帧把落体的**实际**位置同步回表(落点由 WeaponPickup 的物理决定)。
func _sync_ground_positions() -> void:
	for inst in _ground_nodes:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			var e: Dictionary = ground_weapons.get_entry(int(inst))
			if not e.is_empty():
				e["pos"] = (n as Node2D).global_position

func ground_weapons_payload() -> Array:
	return ground_weapons.entries.duplicate(true)

func _broadcast_weapon_spawned(inst: int) -> void:
	var e: Dictionary = ground_weapons.get_entry(inst)
	if e.is_empty():
		return
	_rpc_all("weapon_spawned", [{"inst": inst, "type_id": int(e["type_id"]),
			"mag": int(e["mag"]), "pos": e["pos"], "vel": e["vel"]}])

func _broadcast_weapon_removed(inst: int, by_role: int) -> void:
	_rpc_all("weapon_removed", [{"inst": inst, "by_role": by_role}])
```

> **实施说明**：`_disabled_weapons` 在 `MatchState` 上（`match_host.gd:16` 往它 append）。若实际名字不同，按 `match_state.gd` 里的真实字段名改。

- [ ] **Step 3: 把新域插进继承链**

`server/match_snapshot.gd` 第 2 行：`extends MatchState` → `extends MatchGround`。
链变成 `RoyaleHost → MatchHost → MatchRound → MatchCombat → MatchSnapshot → MatchGround → MatchState`。

跑 `"$GODOT" --headless --path . --quit-after 3600` 确认 0 报错（链断了会立刻报）。

- [ ] **Step 3b: 把"F/Q 只归单机走"改成显式守卫**

★ 现状（考察得来，**是本计划的隐藏前提**）：`player.gd` 的 `_try_pickup()` / `_try_drop()` 都要求 `get_tree().current_scene is Level0`，而 PvP 的 current_scene 是 `PvpGame`/`RoyaleGame`（Level0 只是**子节点**）—— 所以今天 F/Q 在 PvP 下**是死的**（客户端与服务器 worker 都直接 return）。

本计划之后：**服务器**要靠输入包里的边沿来裁决（Task 2 Step 4），**客户端**不做预测（spec §6.4）。两条都不该经过 `player._try_*`。所以别依赖上面那个巧合，把它写成显式条件：

```gdscript
# player.gd 的 _poll_pickup_drop() 开头
func _poll_pickup_drop(delta: float) -> void:
	# ★ 只归单机走:联机的拾取/丢弃是**服务器权威**(读输入包里的 BIT_PICKUP/BIT_DROP),
	#   客户端不做预测。不挡的话客户端本地会自己捡一把、服务器那边却没有 ——
	#   而 `_try_*` 里那句 `current_scene is Level0` 只是**碰巧**在 PvP 里为假,别依赖巧合。
	if Level0.pvp_mode:
		return
	...
```

★ 注意 `Level0.pvp_mode` 在**服务器 worker 进程**里是 `false`(那个进程不实例化 Level0) —— 所以服务器侧还得**另外**挡住:服务器上 `_try_*` 依赖的 `get_tree().current_scene is Level0` 本来就是假(worker 的 current_scene 是 `server_main.tscn`),那条早退继续兜底。**两处都要留**,理由不同。

- [ ] **Step 4: 在 `MatchHost._physics_process` 挂钩**

`server/match_host.gd` 消费输入那段，`_ack_seq[role] = ...` 之后加：

```gdscript
				# 地面武器:拾取/丢弃的边沿(PacketInputSource.clear_edges 在本轮开头已清,
				# apply_packet 刚写入本包边沿 —— 所以必须**紧跟在 apply_packet 之后**读)
				_handle_ground_actions(role, src)
```

并在 `_physics_process` 的**最前**加 `_sync_ground_positions()`（落体位置先同步进表,拾取判定才用得上最新落点）。

- [ ] **Step 5: 写裁决函数**

`server/match_ground.gd` 追加：

```gdscript
func _live_self_drops(role: int) -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	if not _self_drop_until.has(role):
		return out
	var m: Dictionary = _self_drop_until[role]
	for inst in m.keys():
		if int(m[inst]) > now:
			out.append(inst)
		else:
			m.erase(inst)
	return out

func _handle_ground_actions(role: int, src: PacketInputSource) -> void:
	if not players.has(role):
		return
	var p: Node2D = players[role]
	if p.is_downed():
		return
	if src.is_pickup_pressed():
		_try_server_pickup(p, role)
	if src.is_drop_pressed():
		_try_server_drop(p, role)

# 拾取:一次只捡**最近的一把**(与单机同规则)。服务器裁决,客户端等事件。
func _try_server_pickup(p: Node2D, role: int) -> void:
	var e: Dictionary = ground_weapons.nearest_within(
			p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops(role))
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped < 0:
		return   # 被闸门拒绝,地面那件留着(与单机同款哨兵)
	var dp := p.global_position
	_remove_ground_weapon(inst)
	_broadcast_weapon_removed(inst, role)
	if dropped > 0:
		# 放不下 → 被换下的那把掉在玩家脚下(残弹跟着枪走)
		var d: Dictionary = p.weapons.take_last_dropped()
		var ni := _spawn_ground_weapon(dropped, int(d.get("mag", WeaponInventory.MAG_FULL)),
				dp + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
				Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
				0, role)
		_broadcast_weapon_spawned(ni)

func _try_server_drop(p: Node2D, role: int) -> void:
	if p.weapons.current_slot_int() == 0:
		return
	var e: Dictionary = p.weapons.drop_current()
	if e.is_empty():
		return
	var ni := _spawn_ground_weapon(int(e["type"]), int(e["mag"]),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
			0, role)
	_broadcast_weapon_spawned(ni)
```

- [ ] **Step 6: 提交**

```bash
git add server/match_ground.gd server/match_snapshot.gd server/match_host.gd core/net/net_bus.gd
git commit -m "feat(net): 服务器地面武器域 —— 权威表 + 拾取/丢弃裁决 + weapon_spawned/removed 事件"
```

---

### Task 3: 初始分布 + `match_sync_data` 带 `ground_weapons`

**Files:**
- Modify: `server/match_ground.gd`（`_setup_ground_weapons` / `_scatter_ground_weapons`）
- Modify: `server/match_host.gd:75`（`_ready` 调 `_setup_ground_weapons`）
- Modify: `server/server_main.gd:229-235`（载荷加字段）

**Interfaces:**
- Produces: `match_sync_data` 载荷多一个 `"ground_weapons": Array`

- [ ] **Step 1: 写分布函数**

`server/match_ground.gd` 追加：

```gdscript
# 铺 types 里每种武器到全图开阔地板格(复用 RoyaleHost 那套判据,避免枪落进密封小间)。
func _scatter_ground_weapons(types: Array) -> void:
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var d := _grid_dims_cells()
	var cells: Array = _ground_spawn_cells()
	var picked: Array = GridPathfinder.spread_cells(cells, types.size(), 10, d.x, d.y)
	var ts := float(GameParameters.TILE_SIZE)
	var half := ts * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * ts + Vector2(half, half)
		_spawn_ground_weapon(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)

# 开阔地板格。1v1 用基类的判据扫描;RoyaleHost 可覆写成自己的 `_spawn_candidates()`
# (那边还要求同层连通区 ≥ OPEN_AREA_MIN,淘汰密封死角)。
func _ground_spawn_cells() -> Array:
	var out: Array = []
	if grid.is_empty():
		return out
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				out.append(c)
	return out

# 开局:铺 12 把(每种 2 把、跳过禁用),再让每个玩家(含 AI)从池子里随机拿 1 把
# → 地上剩 12 - N 把。
func _setup_ground_weapons() -> void:
	_scatter_ground_weapons(_server_weapon_types())
	for role in players:
		var p: Node = players[role]
		if p.weapons == null:
			continue
		var t := 1
		if not ground_weapons.entries.is_empty():
			var idx := randi() % ground_weapons.entries.size()
			var e: Dictionary = ground_weapons.remove(int(ground_weapons.entries[idx]["inst"]))
			_remove_ground_weapon(int(e["inst"]))
			t = int(e["type_id"])
		p.weapons.set_initial_inventory([t])

# 换局:清空重铺 + 每人背包重置为随机一把(与"两端每局从同一基线出发"同一纪律)。
func _reset_ground_weapons() -> void:
	for inst in _ground_nodes.keys():
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_ground_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()
	_next_ground_inst = 1
	_setup_ground_weapons()
```

- [ ] **Step 2: `_ready` 里调它**

`server/match_host.gd` 的 `_ready()`，在 `set_enabled_slots` 那个循环**之后**加：

```gdscript
	# 地面武器:铺 12 把 + 每人随机拿 1 把。
	# ★ 必须排在 set_enabled_slots **之后** —— 与单机 `_give_starting_weapon` 同款理由:
	#   先给再禁的话,手上一旦是禁用武器会被判成空手。
	_setup_ground_weapons()
```

- [ ] **Step 3: `match_sync_data` 加字段**

`server/server_main.gd` 的 `_on_match_sync` 里，载荷那处加一行：

```gdscript
	NetBus.rpc_id(caller, "match_sync_data", {
		"names": _claim_names, "hues": _claim_hues(),
		"options": _claim_opts.get(1, {}), "roles": _role_set, "spawns": spawns,
		# ★ 地面武器**必须走这条**(不走 weapon_spawned 推送):开局那批若靠推送,
		#   会撞上"客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失"那类事故。
		"ground_weapons": _host.ground_weapons_payload(),
	})
```

★ 若 `_host` 可能还是 null（`match_sync` 早于建局到达），按现有 `spawns` 的处理方式同样兜底（现有代码已有 `push_warning` + 取 `role_spawns()` 的分支，照抄其守卫）。

- [ ] **Step 4: 提交**

```bash
git add server/match_ground.gd server/match_host.gd server/server_main.gd
git commit -m "feat(net): 联机初始地面武器分布 + match_sync 一并下发(不走推送)"
```

---

### Task 4: 复活与换局

**Files:**
- Modify: `server/match_ground.gd`（`_drop_all_but_one`）
- Modify: `server/match_round.gd:65-77`（`_respawn_player`）+ `:106-117`（`_reset_world_and_clear_dynamics`）
- Test: `tests/royale_disconnect_count_probe.tscn`（同款手法的探针可复用）

**Interfaces:**
- Consumes: `WeaponComponent.random_keep_one() -> Array[Dictionary]`（单机计划已落地）
- Produces: `_drop_all_but_one(p: Node2D, role: int) -> void`

- [ ] **Step 1: 写"除随机一把外全丢"**

`server/match_ground.gd` 追加：

```gdscript
# 复活:从背包**随机**保留一条,其余在死亡点散开掉出(用户 2026-09-15 裁定)。
# ★ 不补满弹:与"残弹跟着枪走"一致,也与改动前的行为一致。
func _drop_all_but_one(p: Node2D, role: int) -> void:
	if p.weapons == null:
		return
	var rest: Array = p.weapons.random_keep_one()   # 内部已 equip 保留的那把
	if rest.is_empty():
		return
	var pos := p.global_position
	var n := maxi(rest.size(), 1)
	for i in rest.size():
		var e: Dictionary = rest[i]
		var ang := TAU * float(i) / float(n)
		var vel := Vector2(cos(ang), -absf(sin(ang))) * 380.0
		var inst := _spawn_ground_weapon(int(e["type"]), int(e.get("mag", WeaponInventory.MAG_FULL)),
				pos + Vector2(0.0, -12.0), vel, 0, role)
		_broadcast_weapon_spawned(inst)
```

- [ ] **Step 2: 接进 `_respawn_player`**

`server/match_round.gd:75` 那行 `p.weapons.equip(p.weapons.default_slot())` 换成：

```gdscript
	# 复活:除随机一把外全丢在死亡点(见 MatchGround._drop_all_but_one)。
	# ★ 换掉了原来的 equip(default_slot()) —— 那条会把手上的枪换回默认槽,
	#   而背包现在是玩家资产,复活只该"随机留一把"。
	_drop_all_but_one(p, role)
```

- [ ] **Step 3: 接进换局重置**

`server/match_round.gd:_reset_world_and_clear_dynamics()`，在 `_seen_bullets.clear()` 之后加：

```gdscript
	# 地面武器清零 + 重新分布 + 各人背包重置 —— 换局纪律是"两端每局从同一基线出发"
	# (与"还原可破坏砖 + 清子弹"同理,装备也是本局的进度)。
	_reset_ground_weapons()
```

- [ ] **Step 4: 确认大乱斗不吃重复重置**

`server/royale_host.gd` 覆写了 `_respawn_player`（只额外清 `last_damager` meta 后调 `super`），所以它自动继承新规则 ✓。大乱斗**不调** `_reset_world_and_clear_dynamics`（见 `match_combat.gd` 的注释），所以换局重置对它无影响——**确认这一点**：若大乱斗也要"每局重置装备"，需另加钩子（本计划不做，大乱斗是单局 5 分钟死斗）。

- [ ] **Step 5: 提交**

```bash
git add server/match_ground.gd server/match_round.gd
git commit -m "feat(net): 复活除随机一把外全丢 + 换局重置地面武器与背包"
```

---

### Task 5: 客户端渲染地面武器

**Files:**
- Modify: `scenes/pvp_match_client.gd`
- Modify: `scenes/weapons/weapon_pickup.gd`（canonical 与渲染分离）
- Modify: `scenes/level_0.gd`（单机也给锚点）

**Interfaces:**
- Consumes: `NetBus.local_match_sync`、`NetBus.local_weapon_spawned`、`NetBus.local_weapon_removed`、`GroundWeaponField`、`WeaponPickup.set_anchor(pos)`
- Produces: `PvpMatchClient.ground_weapons: GroundWeaponField`、`_spawn_pickup_node(...)`、`_remove_pickup_node(inst)`

- [ ] **Step 1: `WeaponPickup` 拆出 canonical 与渲染位置**

★ **为什么**：世界是环面的,协议只传 canonical 坐标。玩家在接缝附近时,一件在"地图另一头"的武器**其实就在身边** —— 但节点画在 canonical 位置就是屏幕外。与敌人/子弹/副本同款,渲染要**锚到玩家的最近副本**。

`scenes/weapons/weapon_pickup.gd` 改：

```gdscript
# 权威位置(始终取模回 canonical)。★ 与**渲染位置**(global_position)分开:
#   渲染位置每帧由 set_anchor() 给的锚点锚到最近副本,权威位置永远在 [0,MAP)。
var canonical_pos: Vector2 = Vector2.ZERO
var _anchor: Vector2 = Vector2.ZERO
var _has_anchor: bool = false

func set_anchor(p: Vector2) -> void:
	_anchor = p
	_has_anchor = true

func sync_render_from_canonical() -> void:
	global_position = GridPathfinder.anchor_to_nearest(canonical_pos, _anchor,
			float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT)) if _has_anchor else canonical_pos
```

`_physics_process` 里：物理积分用 `canonical_pos`（把 `global_position` 当工作变量但最后归位），末尾改成：

```gdscript
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if w > 0.0 and h > 0.0:
		canonical_pos = Vector2(fposmod(global_position.x, w), fposmod(global_position.y, h))
	else:
		canonical_pos = global_position
	sync_render_from_canonical()
```

`configure()` 里也设 `canonical_pos = pos`；`_ready()` 里若 `canonical_pos == ZERO` 则从 `global_position` 初始化。

- [ ] **Step 2: 单机侧给锚点**

`scenes/level_0.gd`：地面武器挂在 `$WorldViewport` 下,**但锚点是玩家**。在 `_process()` 里加：

```gdscript
	# 地面武器渲染锚点 = 本地玩家(环面:接缝另一侧的枪要画在身边那一份上)
	var pl := $WorldViewport.get_node_or_null("Player") as Node2D
	if pl != null:
		for n in _pickup_nodes.values():
			if is_instance_valid(n):
				(n as WeaponPickup).set_anchor(pl.global_position)
```

（`_process` 已在跑,这循环是 12 次赋值,可忽略。）

- [ ] **Step 3: 客户端持表 + 建/删节点**

`scenes/pvp_match_client.gd` 加字段与方法：

```gdscript
# ── 地面武器(2026-09-15):服务器权威,本端只渲染 + 等事件 ──
var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}   # inst -> WeaponPickup

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")

func _spawn_pickup_node(data: Dictionary) -> void:
	if _world == null:
		return
	var inst := int(data.get("inst", 0))
	if _pickup_nodes.has(inst):
		return
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(int(data.get("type_id", 1)), inst, int(data.get("mag", 0)),
			data.get("vel", Vector2.ZERO))
	_world.add_child(node)
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor(_local.global_position if _local != null else Vector2.ZERO)
	node.sync_render_from_canonical()
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": int(data.get("type_id", 1)),
			"mag": int(data.get("mag", 0)), "pos": node.canonical_pos, "vel": data.get("vel", Vector2.ZERO)})
	_pickup_nodes[inst] = node

func _remove_pickup_node(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)

func _on_weapon_spawned(data: Dictionary) -> void:
	_spawn_pickup_node(data)

func _on_weapon_removed(data: Dictionary) -> void:
	_remove_pickup_node(int(data.get("inst", 0)))

# 每帧把锚点推给所有地面武器(与单机同款:接缝另一侧的枪要画在身边那一份)
func _tick_ground_weapon_anchor() -> void:
	if _local == null:
		return
	var lp: Vector2 = (_local as Node2D).global_position
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n != null and is_instance_valid(n):
			(n as WeaponPickup).set_anchor(lp)
			(n as WeaponPickup).sync_render_from_canonical()
```

并**在订阅处**（`_ready` 或场景里的连接处，与既有 `local_*` 订阅同处）加：

```gdscript
	NetBus.local_weapon_spawned.connect(_on_weapon_spawned)
	NetBus.local_weapon_removed.connect(_on_weapon_removed)
```

- [ ] **Step 4: 消费 `match_sync` 的 `ground_weapons`**

`_on_match_sync(payload)` 末尾加：

```gdscript
	var gw: Array = payload.get("ground_weapons", [])
	for e in gw:
		_spawn_pickup_node(e)   # 开局那批:随进场拉取一次拿到,不再靠推送(见 spec §6.3)
```

- [ ] **Step 5: 每帧推锚点**

`scenes/pvp_match_client.gd:_physics_process` 里加一行 `_tick_ground_weapon_anchor()`（放在移动/上报附近即可）。

- [ ] **Step 6: 跑端到端**

```bash
bash tests/pvp_match_smoke.sh
bash tests/royale_c2_probe.sh 2>/dev/null || "$GODOT" --headless --path . --quit-after 3600 res://tests/royale_c2_probe.tscn
```
Expected: PASS / `PROBE: ALL-OK`。

- [ ] **Step 7: 提交**

```bash
git add scenes/pvp_match_client.gd scenes/weapons/weapon_pickup.gd scenes/level_0.gd
git commit -m "feat(net): 客户端地面武器渲染 —— 事件建删 + 环面锚到最近副本(单机侧同修)"
```

---

### Task 6: PvP / 大乱斗 HUD 接 `WeaponSlots`

**Files:**
- Modify: `ui/pvp_hud.gd`、`ui/royale_hud.gd`

**Interfaces:**
- Consumes: `WeaponSlots.attach_to(parent, weapons)`

- [ ] **Step 1: ★ 先确认 PvP 里是不是**已经**有一块了（别加第二块）**

`ui/hud.gd`（单机 HUD,`layer = 129`）是 **`level_0.tscn` 里的节点**,而 PvP 的两个场景**也实例化 Level0**（`pvp_game.gd` / `royale_game.gd`）。它的 `_ready` 用 `get_tree().get_first_node_in_group("player")` 找玩家并调 `_build_weapon_slots(p)` —— 而 PvP 的本地玩家 `player.gd:136` 正是 `add_to_group("player")`。

**所以 PvP 里极可能已经有一块槽位格子。** 先跑一次真机（或 `combat_hud_visual_probe` 取图）确认：

```bash
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn
```

- **已经有一块** → 本任务**到此为止**：什么都不用加，`PvpHud`/`RoyaleHud` 都不用改。把它记进提交信息（"PvP 已由单机 HUD 那块覆盖"），跳到 Step 3。
- **没有（或位置不对）** → 走 Step 2。

- [ ] **Step 2: 没有才补（并且只补一次）**

两个 HUD 都**拿不到玩家**（它们只读静态 `PvpSession`，运行时数据全来自 `round_state` 载荷），所以要加一个 setup 口：

```gdscript
# ui/pvp_hud.gd 与 ui/royale_hud.gd 各加
var _slots: WeaponSlots = null

func add_weapon_slots(weapons: WeaponComponent) -> void:
	if _slots != null:
		return   # 幂等:重复调不叠第二块
	_slots = WeaponSlots.attach_to(self, weapons)
```

由**宿主场景**在拿到本地玩家之后调用（`_hud` 已存在）：

```gdscript
# scenes/pvp_game.gd(_ready 里 _hud 建好之后)
	_hud.add_weapon_slots(_local.weapons)
# scenes/royale_game.gd 同款
	_hud.add_weapon_slots(_local.weapons)
```

★ 先确认单机 HUD 那块**没有**在 PvP 里显示；若它显示了又要保留下面的，就会**叠两块** —— 那种情况应当改由单机 HUD 那一处接管（把它的 `_build_weapon_slots` 收到"仅单机"条件里），而不是再挂一块。

- [ ] **Step 3: 视觉验收（自己读图）**

```bash
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn
```
★ 该探针的底**故意铺地图开阔区的浅灰蓝**（照它的注释）。读图确认：**只有一块**格子、三态可辨、不与 1v1 记分条/大乱斗榜/K 提示（`royale_hud` 左下 `Vector2(16, 1386)`）重叠。

- [ ] **Step 4: 提交**

```bash
git add ui/pvp_hud.gd ui/royale_hud.gd scenes/pvp_game.gd scenes/royale_game.gd
git commit -m "feat(ui): 对局内 HUD 的武器槽位格子(PvP 若已由单机 HUD 覆盖则不重复挂)"
```

---

### Task 7: 探针与源码守卫

**Files:**
- Modify: `tests/match_sync_probe.tscn`（扩）
- Modify: `tests/pvp_match_smoke.sh`（扩）
- Create: `tests/net_ground_source_probe.gd`（源码级守卫）

- [ ] **Step 1: 源码级守卫**

新 `tests/net_ground_source_probe.gd`（`extends ProbeBase`，照 `kh_l5_probe` 的写法），钉：

- `NetBus` 有 `weapon_spawned` / `weapon_removed` 两条 `@rpc` 且带 `authority`+`reliable`
- ★ **`NetBusExt` 里不得有同名函数** —— 反向断言（重名 = 接收端挂错 = 静默 no-op）
- 客户端订阅的是 `NetBus.local_weapon_spawned` / `local_weapon_removed`（**不是** `NetBusExt`）
- `player.gd` 的 `capture_state` 里有 `"inv"`；`prediction_rollback.gd` 的 `_close_enough` **不含** `inv`（反向断言）
- `match_ground.gd` 是 `extends MatchState` 且**不含** `_init`/`_ready`/`_physics_process`（链规矩）

- [ ] **Step 2: `match_sync_probe` 扩**

加断言：`match_sync_data` 载荷带 `ground_weapons`，且数组元素含 `inst`/`type_id`/`mag`/`pos`/`vel` 五个键。
★ 并加**反向断言**：那些"跨场景交接"的旧标识符（`PvpSession.pending_*` 一族）一个都不许复活。

- [ ] **Step 3: `pvp_match_smoke.sh` 扩**

在既有的输入→模拟→快照链路上加一段：服务器侧直接调 `_spawn_ground_weapon(...)` → 断言客户端收到 `weapon_spawned` 且建出了对应节点；再 `_remove_ground_weapon(...)` → 断言节点被删。

- [ ] **Step 4: 跑全部**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/net_ground_source_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/match_sync_probe.tscn
bash tests/pvp_match_smoke.sh
```
Expected: 均 ALL-OK / PASS。

- [ ] **Step 5: 提交**

```bash
git add tests/net_ground_source_probe.gd tests/net_ground_source_probe.tscn tests/match_sync_probe.tscn tests/pvp_match_smoke.sh
git commit -m "test(net): 地面武器联机的源码守卫 + match_sync 载荷 + 端到端事件断言"
```

---

### Task 8: 同步 CLAUDE.md

- [ ] **Step 1: 更新**

- 「网络与 PvP」一节：加地面武器域（`server/match_ground.gd`、链上位置、两条事件**只走 `NetBus`**、初始分布走 `match_sync`、复活/换局规则）。
- 「武器背包与地面拾取」一节：把"联机未做"的措辞去掉，补 `capture_state` 的 `inv`、锚点渲染。
- 测试一节：登记新探针。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE): 地面武器联机落地后的架构与约定同步"
```

---

## 自查记录

**spec 覆盖**：§6.2/§6.6 → Task 2；§6.3 → Task 3；§6.4（不预测）→ Task 5 的实现方式；§6.5 → Task 1；§6.7 → Task 5；§7.3 → Task 3/4；§8 → Task 7。

**本计划新增的、spec 没写的一条**：**渲染锚点**。spec §6.7 只说"跨接缝走 `anchor_to_nearest`"，但落地时发现 `WeaponPickup` 原本把 `global_position` 直接取模回 canonical —— **单机也有同一个 bug**（玩家在接缝附近时,地图另一头的枪画在屏幕外）。Task 5 Step 1/2 把它一并修了（canonical 与渲染分离）。

**风险**：
1. 服务器侧真的实例化了 12 个 `WeaponPickup`（含哑视觉）。headless 下纯浪费但可忽略；若日后池子变大再改成纯逻辑落体。
2. `_sync_ground_positions()` 每帧把落体位置写回表 —— 12 次字典写/tick，可忽略。
3. 客户端**不做预测**，按 F 到生效有 1 个 RTT。spec §6.4 已裁定接受，并要求补一个"拾取尝试"的即时反馈（本计划未含，留作手感调整项）。
