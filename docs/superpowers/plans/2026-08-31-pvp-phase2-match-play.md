# PvP 阶段 2：对局互通(移动 + 武器对射) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B1 已让双方进竞技场、本地能动。本计划把「对局互通」打通：客户端每 tick 上报输入 → 服务器权威模拟双方（含开火/子弹/命中）→ 快照广播 → 客户端插值渲染远端副本 + 自己校正。**能真正打起来**（含武器对射、服务器裁决命中、血量/倒地经快照权威）。

**Architecture:** 沿用 NetBus(autoload, 唯一网络收口)。新增输入包(60Hz reliable)、快照包(30Hz unreliable)、事件包(reliable: hit/bullet_spawn)。服务器每房间一个 `MatchHost`(server/match_host.gd)，用 `WorldBuilder` 建世界(只碰撞不渲染)、注入 `NetworkInputSource` 驱动两个 `Player.tscn` 实例权威模拟；客户端 `pvp_game` 本地玩家照常 C2(读真实输入) + `PlayerReplica` 纯视觉副本(最短路径插值) + 快照自校正。子弹：本地玩家子弹本地生成(零延迟视觉)、对手子弹由服务器广播 `bullet_spawn` 生成确定性副本、命中由服务器裁决发 `hit` 事件。

**Tech Stack:** Godot 4.7.1 标准版，ENet 高层多人(ENetMultiplayerPeer + MultiplayerAPI RPC)，无测试框架(冒烟 `-s` + 多进程 loopback)。

## Global Constraints

- Godot 可执行：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **新增 `class_name` 文件后必须 `--import` 刷新全局类缓存**，否则引用处 Parse Error(已存记忆)。
- **行为不变纪律**：Task 2 的输入抽象扩展必须让 `enemy_logic_smoke.gd` / `player_contract_smoke.gd` 保绿；单机玩法逐字节不变。
- 服务器进程 = 场景模式(`server_main.tscn`)运行，不能用 `-s`；用 `--headless`。
- 测试由用户跑；本计划每步写验证命令。
- 提交直接到 `main`(仓库惯例)。
- **环面纪律**(设计文档 §4.3)：协议只传 canonical `[0,MAP)` 坐标；渲染各端归最近副本(`anchor_to_nearest`)；插值走最短路径增量(`toroidal_delta_px`)；校正用最短路径增量，不 set 绝对位置。
- 血量/倒地/防水以服务器快照为权威；本地 hit 事件只做即时反馈(白闪/击退)。

---

## Task 0: 收尾工作树 + PvP 地图出生点

**Files:**
- Modify: `factory_1V1(260827).cyrm`(加 `# player2 133 64`)
- Modify: `server/room_manager.gd`(服务器 pin PvP 地图)

**Context:** 工作树有未提交遗留(8 个 .tscn 的 texture UID 修正 + 11 个新 .uid 文件 + untracked `factory_1V1(260827).cyrm`)。这是编辑器重导入的陈旧 UID 修正与新脚本 UID 缓存，应一起提交。PvP 需要玩家2出生点。

- [ ] **Step 1: 给 factory map 补 player2 出生点**

在 `factory_1V1(260827).cyrm` 的 `# player 17 65` 下一行加：

```
# player2 133 64
```

> 坐标来自探测：`(133,64)` 是合法地板格(EMPTY 且正下方 SOLID)，距 player1 环面距离最大、地形开阔(镜像于 (132,65))。地图是 150×100(比 demo 的 125×75 大)。

- [ ] **Step 2: 服务器 pin PvP 地图**

`server/room_manager.gd` 的 `_start_match` 里 `var map_path := MazeGenerator.map_file_path()` 改为 pin 固定 PvP 地图：

```gdscript
const PVP_MAP := "res://factory_1V1(260827).cyrm"

func _start_match(room: Room) -> void:
	MazeGenerator.set_map_file(PVP_MAP)
	var map_path := MazeGenerator.map_file_path()
	...
```

> 这样服务器与两端客户端都加载同一张 1v1 地图，且含 player2 出生点。

- [ ] **Step 3: 提交收尾**

```bash
git add factory_1V1(260827).cyrm server/room_manager.gd
git add Scenes/Enemies/EnemyJumpBird.tscn Scenes/Enemies/enemy_bullet.tscn Scenes/Player/Player.tscn Scenes/Weapons/grenade_launcher.tscn Scenes/Weapons/m82a1.tscn Scenes/Weapons/pistol_test.tscn Scenes/Weapons/rifle_test.tscn Scenes/Weapons/s686.tscn
git add Globals/*.uid Scenes/*.uid Scenes/Player/*.uid Scenes/Weapons/*.uid Scenes/Enemies/*.uid Scenes/Effects/*.uid server/*.uid Tests/*.uid
git commit -m "chore: 收尾纹理 UID 修正 + 新 .uid + factory map 补 player2 出生点"
```

- [ ] **Step 4: 验证——headless 启动 5 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

Expected: 无 `SCRIPT ERROR`。

---

## Task 1: 输入源扩展(攻击/切枪注入)——NetworkInputSource + player/weapon 接线

**Files:**
- Modify: `Globals/input_source.gd`(基类加攻击/切枪方法，默认委托真实 Input)
- Create: `Globals/network_input_source.gd`(`class_name NetworkInputSource`, 消费输入包)
- Modify: `Scenes/Player/player.gd`(切枪改轮询 input_source、攻击查询方法、R 重载加 PvP 守卫)
- Modify: `Scenes/Weapons/weapon_base.gd`(攻击输入统一走 player 查询，本地委托 Input)

**Interfaces:**
- Produces: `InputSource.is_attack_pressed()/is_attack_just_pressed()/is_attack_just_released()/get_weapon_slot_pressed() -> int`(基类委托真实 Input)
- Produces: `NetworkInputSource`(class_name)：`begin_tick()` / `apply_packet(pkt)` + 上述方法覆写(从注入包取)
- Produces: `player.gd` 公开方法 `is_attack_pressed()/is_attack_just_pressed()/is_attack_just_released()`(委托 input_source)
- Consumes: `weapon_base` 攻击路径改走 `player.is_attack_*()`(has_method 守卫回退 Input，兼容冒烟 StubPlayer)

- [ ] **Step 1: 扩展 `Globals/input_source.gd` 基类**

在 `get_aim_dir_override()` 后加：

```gdscript
# ── 攻击与切枪(本地委托真实 Input;NetworkInputSource 覆写)──
func is_attack_pressed() -> bool:
	return Input.is_action_pressed("attack")

func is_attack_just_pressed() -> bool:
	return Input.is_action_just_pressed("attack")

func is_attack_just_released() -> bool:
	return Input.is_action_just_released("attack")

# 本轮按下的武器槽位(0=无,1-5)。本地用 Input 事件,网络由注入包提供。
func get_weapon_slot_pressed() -> int:
	for i in range(1, 6):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0
```

- [ ] **Step 2: 新建 `Globals/network_input_source.gd`**

```gdscript
class_name NetworkInputSource
extends InputSource

# 网络注入输入(服务器权威模拟的唯一消费方):从输入包取轴/按键/边沿/切枪/瞄准。
# 服务器 Match 每物理帧 begin_tick()+apply_packet() 后,玩家 _physics_process 读到的就是注入状态。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8

var _axis := 0.0
var _held := 0
var _pressed := 0
var _released := 0
var _weapon := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)

# 清空边沿(每 tick 消费新包前调用,避免上一 tick 边沿残留)。
func begin_tick() -> void:
	_pressed = 0
	_released = 0
	_weapon = 0

func apply_packet(pkt: Dictionary) -> void:
	_axis = pkt.get("ax", 0.0)
	_held = pkt.get("held", 0)
	_pressed = pkt.get("pressed", 0)
	_released = pkt.get("released", 0)
	_weapon = pkt.get("weapon", 0)
	_aim = pkt.get("aim", Vector2.ZERO)

func get_axis(_neg: String, _pos: String) -> float:
	return _axis

func is_action_pressed(action: String) -> bool:
	return _held & _bit(action) != 0

func is_action_just_pressed(action: String) -> bool:
	return _pressed & _bit(action) != 0

func is_action_just_released(action: String) -> bool:
	return _released & _bit(action) != 0

func is_attack_pressed() -> bool:
	return _held & BIT_ATTACK != 0

func is_attack_just_pressed() -> bool:
	return _pressed & BIT_ATTACK != 0

func is_attack_just_released() -> bool:
	return _released & BIT_ATTACK != 0

func get_weapon_slot_pressed() -> int:
	return _weapon

func get_aim_dir_override() -> Vector2:
	return _aim

static func _bit(action: String) -> int:
	match action:
		"up": return BIT_UP
		"down": return BIT_DOWN
		"charge": return BIT_CHARGE
		"attack": return BIT_ATTACK
	return 0
```

- [ ] **Step 3: 改 `player.gd`——切枪轮询 + 攻击查询 + R 守卫**

3a. 在 `_physics_process` 开头(在 `combat.update_iframe_blink(delta)` 之后)加切枪轮询：

```gdscript
	combat.update_iframe_blink(delta)

	# 切枪走 input_source 轮询(本地=Input 事件,网络=注入包)。放移动逻辑前,先装备再算移动惩罚。
	var wslot := input_source.get_weapon_slot_pressed()
	if wslot > 0:
		weapons.equip(str(wslot))
```

3b. `_unhandled_input` 改为只保留倒地 R 重载(加 PvP 守卫)，移除切枪循环：

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if combat.is_downed():
		# PvP 倒地不重载场景(服务器权威管复活/回合,阶段4);单人照旧。
		if not Level0.pvp_mode and event.is_action_pressed("R"):
			get_tree().reload_current_scene()
		return
```

3c. 加攻击查询公开方法(weapon_base 经 has_method 守卫调用)：

```gdscript
func is_attack_pressed() -> bool:
	return input_source.is_attack_pressed()

func is_attack_just_pressed() -> bool:
	return input_source.is_attack_just_pressed()

func is_attack_just_released() -> bool:
	return input_source.is_attack_just_released()
```

- [ ] **Step 4: 改 `weapon_base.gd`——攻击输入统一走 player 查询**

4a. 加三个查询辅助(has_method 守卫回退真实 Input，兼容冒烟 StubPlayer)：

```gdscript
# 攻击输入查询:优先走 player 的注入输入(NetworkInputSource);本地/冒烟无该方法时回退真实 Input。
func _attack_pressed() -> bool:
	if player != null and player.has_method("is_attack_pressed"):
		return player.is_attack_pressed()
	return Input.is_action_pressed("attack")

func _attack_just_pressed() -> bool:
	if player != null and player.has_method("is_attack_just_pressed"):
		return player.is_attack_just_pressed()
	return Input.is_action_just_pressed("attack")

func _attack_just_released() -> bool:
	if player != null and player.has_method("is_attack_just_released"):
		return player.is_attack_just_released()
	return Input.is_action_just_released("attack")
```

4b. `_process` 的攻击分支改为轮询(移除对 `Input.is_action_pressed("attack")` 的直接引用)：

```gdscript
	if heavy_aim:
		if _attack_just_pressed():
			_aiming = true
		if _attack_just_released():
			_aiming = false
			_update_laser()
			try_fire()
		_update_laser()
	elif full_auto:
		if _attack_pressed():
			try_fire()
	else:
		if _attack_just_pressed():
			try_fire()
```

> 原 `_process` 里 `elif full_auto and Input.is_action_pressed("attack"):` 的 full_auto 分支与 `_unhandled_input` 的攻击处理都被上面替换。删除 `_unhandled_input` 方法(它只处理攻击事件)。本地玩家行为由 60Hz 轮询 `Input.is_action_just_pressed` 等价模拟(Input 状态在帧内一致)。

- [ ] **Step 5: 刷新类缓存 + 跑两个冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import 2>&1 | grep -E "NetworkInputSource" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "SMOKE OK|FAIL" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd 2>&1 | grep -E "CONTRACT OK|FAIL"
```

Expected: `SMOKE OK` + `CONTRACT OK`，退出 0。

- [ ] **Step 6: 提交**

```bash
git add Globals/input_source.gd Globals/network_input_source.gd Scenes/Player/player.gd Scenes/Weapons/weapon_base.gd
git commit -m "feat: 输入源扩展(攻击/切枪注入) + NetworkInputSource——weapon_base 攻击走 player 查询,行为不变"
```

---

## Task 2: 输入包协议 + NetBus RPC + 客户端上报

**Files:**
- Modify: `Globals/net_bus.gd`(加 send_input RPC + input_received 信号)
- Modify: `Scenes/pvp_client.gd`(每物理帧打包输入上报)

**Interfaces:**
- Produces: `NetBus.send_input(pkt: Dictionary)` `@rpc("any_peer","reliable")` → 服务器 `input_received(caller:int, pkt)` 信号
- Consumes: Task 3 的 MatchHost 连 `NetBus.input_received` 消费

- [ ] **Step 1: `net_bus.gd` 加信号 + RPC**

信号区加：

```gdscript
signal input_received(caller: int, pkt: Dictionary)
```

RPC 区(客户端 → 服务器)加：

```gdscript
@rpc("any_peer", "reliable")
func send_input(pkt: Dictionary) -> void:
	input_received.emit(multiplayer.get_remote_sender_id(), pkt)
```

- [ ] **Step 2: `pvp_client.gd` 加每帧输入打包**

`_ready` 末尾记录本地玩家引用，加 `_physics_process`：

```gdscript
var _local: Node2D = null

func _ready() -> void:
	...
	_local = level0.get_node("WorldViewport/Player")
	...

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	var src: InputSource = _local.input_source
	var held := 0
	var pressed := 0
	var released := 0
	# 用 NetworkInputSource 的位常量,避免重复定义
	const B := {
		"up": NetworkInputSource.BIT_UP, "down": NetworkInputSource.BIT_DOWN,
		"charge": NetworkInputSource.BIT_CHARGE, "attack": NetworkInputSource.BIT_ATTACK,
	}
	for act in ["up", "down", "charge", "attack"]:
		if src.is_action_pressed(act):
			held |= B[act]
		if src.is_action_just_pressed(act):
			pressed |= B[act]
	for act in ["up", "down", "attack"]:
		if src.is_action_just_released(act):
			released |= B[act]
	var aim := _local.get_current_aim_dir()
	var pkt := {
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
		"weapon": src.get_weapon_slot_pressed(),
		"aim": aim,
	}
	NetBus.rpc_id(1, "send_input", pkt)
```

> 需要 `player.gd` 加 `get_current_aim_dir()`：返回当前武器实际瞄准方向(本地=鼠标计算)。在 weapon_base 加公开方法：

```gdscript
# weapon_base.gd
func get_current_aim_dir() -> Vector2:
	return _aim_world_dir()
```

> player.gd 转发：

```gdscript
func get_current_aim_dir() -> Vector2:
	if weapons != null and weapons._weapon != null:
		return weapons._weapon.get_current_aim_dir()
	return Vector2(float(facing_direction), 0.0)
```

- [ ] **Step 3: 验证——headless 起 pvp_game 60 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://scenes/pvp_game.tscn --quit-after 60 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

> 无服务器时 `rpc_id` 会告警但不崩溃；仅验证脚本无 Parse Error。

- [ ] **Step 4: 提交**

```bash
git add Globals/net_bus.gd Scenes/pvp_client.gd Scenes/Player/player.gd Scenes/Weapons/weapon_base.gd
git commit -m "feat: 输入包协议——客户端每 tick 上报按键/边沿/切枪/瞄准"
```

---

## Task 3: 服务器 MatchHost 权威模拟(建世界 + 双玩家 + 输入注入)

**Files:**
- Create: `server/match_host.gd`(`class_name MatchHost`, 每房间一个)
- Modify: `server/room_manager.gd`(开局后创建 MatchHost 挂树)

**Interfaces:**
- Produces: `MatchHost`(class_name, extends Node)：
  - 构造 `MatchHost.new(map_path: String, players: Dictionary /* peer->role */, peer_by_role: Dictionary /* role->peer */)`
  - `_ready()`: 建世界(WorldBuilder)+ 生成两个 Player(NetworkInputSource 注入)+ 连 `NetBus.input_received`
  - `_physics_process`: 消费输入 → 快照(本任务先不做,Task 4 加)
- Consumes: `NetBus.input_received`、`WorldBuilder.load_grid/build_sim`、`MazeGenerator.load_spawns`

- [ ] **Step 1: 新建 `server/match_host.gd`**

```gdscript
class_name MatchHost
extends Node

# 服务器权威对局模拟(每房间一个):建世界(只碰撞不渲染)+ 两个 Player(NetworkInputSource 注入)。
# 每物理帧消费双方输入包注入,玩家 _physics_process 自动跑(Player 是 CharacterBody2D,父先于子)。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> NetworkInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> 最新输入包
var grid: Array = []
var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}

func _init(map_path: String, room_players: Dictionary, role_peers: Dictionary) -> void:
	MazeGenerator.set_map_file(map_path)
	# 记录 role->peer
	peer_by_role = role_peers.duplicate()
	# 建世界:碰撞 + 瓦片属性(不渲染)
	grid = WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("MatchHost: 地图加载失败")
		return
	TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")
	TileDefs.init_hp(grid)
	destructible_sub = WorldBuilder.build_sim(self, grid)
	# 生成两个玩家
	var spawns := MazeGenerator.load_spawns()
	for role in role_peers:
		var p: Node2D = preload("res://scenes/player/Player.tscn").instantiate()
		var src := NetworkInputSource.new()
		p.set_input_source(src)
		add_child(p)
		var spawn: Vector2i = spawns.get("player" if role == 1 else "player2", Vector2i(-1, -1))
		var ts := GameParameters.TILE_SIZE
		p.global_position = Vector2(spawn.x * ts + ts / 2.0, spawn.y * ts + ts / 2.0)
		players[role] = p
		input_sources[role] = src

func _enter_tree() -> void:
	NetBus.input_received.connect(_on_input)

func _exit_tree() -> void:
	NetBus.input_received.disconnect(_on_input)

func _on_input(caller: int, pkt: Dictionary) -> void:
	for role in peer_by_role:
		if peer_by_role[role] == caller:
			_pending_input[role] = pkt
			return

func _physics_process(delta: float) -> void:
	# 消费输入(父先于子 → 玩家 _physics_process 读到的已是最新注入)
	for role in input_sources:
		var src: NetworkInputSource = input_sources[role]
		src.begin_tick()
		if _pending_input.has(role):
			src.apply_packet(_pending_input[role])
	# 玩家/子弹的 _physics_process 由树自动跑(子节点)
	# 分帧重建可破坏碰撞块(爆炸拆墙)
	if not _dirty_chunks.is_empty():
		var processed := 0
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			if processed >= 2:
				_dirty_chunks[ch] = true
				continue
			CollisionBuilder.rebuild_chunk(destructible_sub, ch, self)
			processed += 1

func _on_tile_destroyed(cell: Vector2i) -> void:
	# 服务器无瓦片渲染层,只需清持久子格 + 标记分块重建
	if not destructible_sub.is_empty():
		for qy in range(2):
			for qx in range(2):
				destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
```

> 注：`_init` 里建世界用了 `MazeGenerator.set_map_file`/`WorldBuilder`——MatchHost 是服务器进程的根场景子节点，`-s` 阶段 autoload 未实例化，但服务器走 `server_main.tscn` 场景模式(autoload 已就绪)，故 OK。

- [ ] **Step 2: `room_manager.gd` 开局后创建 MatchHost**

`_start_match` 末尾(广播 match_start 之后)加：

```gdscript
	# 创建权威对局模拟(每房间一个 MatchHost)
	var role_peers := {}
	for peer_id in room.players:
		role_peers[room.player_role[peer_id]] = peer_id
	var match_host := MatchHost.new(map_path, room.player_role, role_peers)
	add_child(match_host)
	room.match_host = match_host
```

`Room` 类加字段：

```gdscript
	var match_host: Node = null
```

> 同时 RoomManager 需要一个新方法 `get_room_for_peer(peer_id)`，断线清理时把 MatchHost 一并 free(本计划先挂树上，断线逻辑 Task 7 统一处理)。

- [ ] **Step 3: 刷新类缓存 + 验证——headless 起服务器 120 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import 2>&1 | grep -E "MatchHost" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn --quit-after 120 2>&1 | grep -E "服务器就绪|SCRIPT ERROR|ERROR" | head -8
```

Expected: 打印 `服务器就绪`,无 `SCRIPT ERROR`。

- [ ] **Step 4: 提交**

```bash
git add server/match_host.gd server/room_manager.gd
git commit -m "feat: MatchHost 服务器权威模拟——建世界 + 双玩家 + 输入注入"
```

---

## Task 4: 快照协议 + PlayerReplica 副本 + 自己校正

**Files:**
- Modify: `Globals/net_bus.gd`(加 snapshot RPC + local_snapshot 信号)
- Modify: `server/match_host.gd`(30Hz 广播快照)
- Create: `Scenes/Player/player_replica.gd`(纯视觉副本)+ `Scenes/Player/player_replica.tscn`
- Modify: `Scenes/pvp_client.gd`(收快照 → replica 插值 + 自己校正)

**Interfaces:**
- Produces: `NetBus.snapshot(snap)` `@rpc("authority","unreliable")` → 客户端 `local_snapshot(snap)` 信号
- Produces: `PlayerReplica`(Node2D)：`apply_snapshot(data: Dictionary, local_anchor: Vector2)`、`_process` 最短路径插值
- Produces: `player.gd` `apply_authoritative_state(hp: int, waterproof: int, downed: bool)`
- Consumes: `pvp_client` 收 `NetBus.local_snapshot`

- [ ] **Step 1: `net_bus.gd` 加快照 RPC**

信号区加：

```gdscript
signal local_snapshot(snap: Dictionary)
```

RPC 区(服务器 → 客户端)加：

```gdscript
@rpc("authority", "unreliable")
func snapshot(snap: Dictionary) -> void:
	local_snapshot.emit(snap)
```

- [ ] **Step 2: `match_host.gd` 加 30Hz 快照广播**

类字段加：

```gdscript
var _snapshot_accum := 0.0
const SNAPSHOT_INTERVAL := 1.0 / 30.0
```

`_physics_process` 末尾(玩家移动后)加：

```gdscript
	_snapshot_accum += delta
	if _snapshot_accum >= SNAPSHOT_INTERVAL:
		_snapshot_accum = 0.0
		_broadcast_snapshot()
```

加方法：

```gdscript
func _broadcast_snapshot() -> void:
	var snap := {"players": {}}
	for role in players:
		var p: Node2D = players[role]
		snap["players"][str(role)] = {
			"pos": p.global_position,          # canonical(玩家 wrap_to_range 在 [0,MAP))
			"vel": p.velocity,
			"facing": p.get_facing(),
			"pose": p.state,
			"weapon": p.weapons.current_slot_int(),
			"hp": p.hp,
			"waterproof": p.waterproof,
			"downed": p.is_downed(),
		}
	for role in peer_by_role:
		NetBus.rpc_id(peer_by_role[role], "snapshot", snap)
```

> 需要 `weapon_component.gd` 加 `current_slot_int()`(当前武器槽位 int)。在 `equip` 记录槽位：

```gdscript
var _current_slot: int = 1

func equip(slot: String) -> void:
	_current_slot = int(slot)
	...

func current_slot_int() -> int:
	return _current_slot
```

- [ ] **Step 3: 新建 `Scenes/Player/player_replica.gd`**

```gdscript
extends Node2D
# PvP 远端玩家副本:纯视觉(复用 Player 的 SpriteFrames/动画),由快照驱动 pose/facing/position。
# 不做物理(避免 set position 与物理引擎打架)。插值走最短路径(toroidal_delta_px)。

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

const INTERP_RATE := 12.0  # 指数插值速率(越大越跟手)

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var _target := Vector2.ZERO
var _have_target := false

func _ready() -> void:
	# 复用 Player.tscn 的内联 SpriteFrames
	var tmp := preload("res://scenes/player/Player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()

func apply_snapshot(data: Dictionary, local_anchor: Vector2) -> void:
	var canonical: Vector2 = data["pos"]
	# 目标副本 = 锚到本地玩家最近副本
	_target = MazeGenerator.anchor_to_nearest(canonical, local_anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_have_target = true
	animator.flip_h = int(data["facing"]) < 0
	if bool(data.get("downed", false)):
		animator.stop()
	else:
		var pose: int = int(data["pose"])
		animator.play(POSE_ANIM.get(pose, "idle"))

func _process(delta: float) -> void:
	if not _have_target:
		return
	# 最短路径插值:增量 = 当前渲染位置 → 目标副本位置的最短向量 × 插值系数
	var d := MazeGenerator.toroidal_delta_px(global_position, _target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position += d * (1.0 - exp(-INTERP_RATE * delta))
```

- [ ] **Step 4: 新建 `Scenes/Player/player_replica.tscn`**

```
[gd_scene format=3 uid="uid://replica00000a1"]

[ext_resource type="Script" path="res://scenes/player/player_replica.gd" id="1"]

[node name="PlayerReplica" type="Node2D"]
scale = Vector2(2.5, 2.5)
script = ExtResource("1")

[node name="AnimatedSprite2D" type="AnimatedSprite2D" parent="."]
texture_filter = 1
autoplay = "idle"
```

> 若编辑器提示 uid 冲突,打开场景保存一次由编辑器重分配。

- [ ] **Step 5: `pvp_client.gd` 收快照 → replica + 自己校正**

`_ready` 加：

```gdscript
	NetBus.local_snapshot.connect(_on_snapshot)
	# 远端副本(角色 = 3 - 自己的 role)
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	level0.get_node("WorldViewport").add_child(replica)
	_remote_replica = replica
```

加方法：

```gdscript
var _remote_replica: Node2D = null

func _on_snapshot(snap: Dictionary) -> void:
	var players_snap: Dictionary = snap["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role == PvpSession.role:
			_self_correct(data)
		else:
			if _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
				_remote_replica.apply_snapshot(data, _local.global_position)

const SELF_CORRECT_DIST := 96.0  # 位置校正阈值(px)

func _self_correct(data: Dictionary) -> void:
	if _local == null:
		return
	# 血量/防水/倒地:服务器权威,直接采纳
	var hp := int(data["hp"])
	var wp := int(data["waterproof"])
	var downed := bool(data["downed"])
	if _local.hp != hp or _local.waterproof != wp or _local.is_downed() != downed:
		_local.apply_authoritative_state(hp, wp, downed)
	# 位置:差异超阈值才校正(最短路径增量,不 set 绝对位置)
	var d := MazeGenerator.toroidal_delta_px(_local.global_position, data["pos"],
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if d.length() > SELF_CORRECT_DIST:
		_local.global_position += d
```

- [ ] **Step 6: `player.gd` 加权威状态采纳**

```gdscript
# 服务器快照权威状态:血量/防水/倒地直接采纳(本地 hit 事件只做视觉,血量以快照为准)。
func apply_authoritative_state(hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	combat.hp = clampi(hp_val, 0, combat.max_hp)
	combat.hp_changed.emit(combat.hp, combat.max_hp)
	waterproof = clampi(waterproof_val, 0, max_waterproof)
	waterproof_changed.emit(waterproof, max_waterproof)
	if downed_val and not combat.is_downed():
		combat.force_down()
	elif not downed_val and combat.is_downed():
		combat.revive()
```

`combat_component.gd` 加：

```gdscript
# 服务器权威倒地/复活(PvP 用;单人按 R 重载场景不涉及)。
func force_down() -> void:
	if not downed:
		_downed()

func revive() -> void:
	if not downed:
		return
	downed = false
	hp = max_hp
	body.rotation = 0.0
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.play("idle")
```

> `hp` 是 `combat.hp`，player 暴露只读 `hp`。这里直接写 combat 内部字段(同一模块内合法)。

- [ ] **Step 7: 刷新类缓存 + 验证——headless 起 pvp_game 60 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import 2>&1 | grep -E "PlayerReplica" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://scenes/pvp_game.tscn --quit-after 60 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

- [ ] **Step 8: 提交**

```bash
git add Globals/net_bus.gd server/match_host.gd Scenes/Player/player_replica.gd Scenes/Player/player_replica.tscn Scenes/pvp_client.gd Scenes/Player/player.gd Scenes/Player/combat_component.gd Scenes/Player/weapon_component.gd
git commit -m "feat: 快照协议 + PlayerReplica 最短路径插值 + 自己校正"
```

---

## Task 5: 武器对射(服务器裁决命中 + 客户端子弹视觉)

**Files:**
- Modify: `Globals/net_bus.gd`(加 bullet_spawn / hit_event RPC + 信号)
- Modify: `Scenes/Weapons/bullet_base.gd`(apply_damage 开关 + 进 bullet 组)
- Modify: `Globals/explosion.gd`(apply_aoe 遍历所有 player)
- Modify: `server/match_host.gd`(裁决命中 + 广播 bullet_spawn/hit)
- Modify: `Scenes/pvp_client.gd`(收 bullet_spawn 生成本地子弹副本 + 收 hit 事件)

**Interfaces:**
- Produces: `NetBus.bullet_spawn(data)` / `NetBus.hit_event(victim_role, damage, source_pos)`(服务器 → 客户端, reliable) + `local_bullet_spawn` / `local_hit_event` 信号
- Produces: `BulletBase.apply_damage: bool`(默认 true;客户端视觉副本设 false,只出特效不裁决)
- Consumes: `pvp_client` 收两个事件

- [ ] **Step 1: `net_bus.gd` 加事件 RPC**

信号区加：

```gdscript
signal local_bullet_spawn(data: Dictionary)
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2)
```

RPC 区加：

```gdscript
@rpc("authority", "reliable")
func bullet_spawn(data: Dictionary) -> void:
	local_bullet_spawn.emit(data)

@rpc("authority", "reliable")
func hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	local_hit_event.emit(victim_role, damage, source_pos)
```

- [ ] **Step 2: `bullet_base.gd`——apply_damage 开关 + 进组**

类字段加：

```gdscript
var apply_damage: bool = true  # 客户端视觉副本设 false:只出特效/轨迹,不裁决伤害
```

`_ready()` 加进组：

```gdscript
	add_to_group("bullet")
```

`_explode()` 里 AoE 判定加开关：

```gdscript
func _explode() -> void:
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	if apply_damage:
		Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback)
```

> 命中敌人分支也受 apply_damage 保护：`_physics_process` 里两处 `hit.is_in_group("enemies")` 分支与 `_direct_hit` 前加 `if apply_damage:` 守卫(视觉副本不应触发任何 hurt)。撞墙拆瓦片保持(视觉副本轨迹要撞墙反弹,拆瓦由服务器裁决后事件同步——本计划先不做 tile_destroyed 事件,服务器拆墙由 Match 自身重建碰撞,客户端视觉副本撞到已拆墙的残余碰撞由快照/重建自愈,可接受)。

- [ ] **Step 3: `explosion.gd`——apply_aoe 遍历所有 player**

`apply_aoe` 里单玩家逻辑改为遍历：

```gdscript
	for p in tree.get_nodes_in_group("player"):
		if not (p is Node2D) or p == null:
			continue
		var pp := p as Node2D
		if pp.has_method("take_hit") and not (pp.has_method("is_downed") and pp.is_downed()):
			var d := _dist(center, pp.global_position)
			if d <= radius:
				var blocked := has_grid and not _has_los(center, pp, grid)
				var mult := BLOCKED_FRACTION if blocked else 1.0
				mult *= Water.water_mult(pp.global_position, grid)
				pp.take_hit(center, int(_falloff(d, radius, max_damage) * mult), true,
						_falloff(d, radius, max_knockback) * mult)
```

> 相机震动只对第一个玩家做(原 `_cam_shake(center, radius, p)` 保留在循环外,用第一个 player)。单机组里只有本地玩家 → 行为不变。

- [ ] **Step 4: `match_host.gd`——裁决命中 + 广播事件**

类字段加：

```gdscript
const HIT_RADIUS := 40.0   # 子弹命中判定半径(px, 玩家缩放 2.5 的碰撞箱量级)
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次)
var _bullet_seq := 0
```

`_physics_process` 末尾(快照前)加：

```gdscript
	_adjudicate_bullets()
```

加方法：

```gdscript
func _adjudicate_bullets() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as CharacterBody2D
		# 新子弹:广播给非射手客户端(射手已本地生成视觉)
		var bid: int = bullet.get_instance_id()
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)
		# 命中裁决:对非射手玩家算 toroidal 距离
		for role in players:
			var p: Node2D = players[role]
			if p == bullet.shooter:
				continue
			var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < HIT_RADIUS:
				_on_bullet_hit(bullet, p, role)
				break

func _broadcast_bullet_spawn(bullet: CharacterBody2D) -> void:
	var scene_path := ""
	if bullet.scene_file_path != "":
		scene_path = bullet.scene_file_path
	elif bullet.has_meta("scene_path"):
		scene_path = bullet.get_meta("scene_path")
	var data := {
		"scene": scene_path,
		"pos": bullet.global_position,
		"vel": bullet.velocity_vec,
		"speed": bullet.speed,
		"range": bullet.max_range,
		"size": bullet.size,
		"color": bullet.bullet_color,
		"gravity": bullet.gravity_factor,
		"hit_damage": bullet.hit_damage,
		"hit_impact": bullet.hit_impact,
		"explodes": bullet.explodes,
		"direct_damage": bullet.direct_hit_damage,
		"fuse": bullet.fuse_time,
		"hit_fuse": bullet.hit_fuse_time,
		"radius": bullet.explosion_radius,
		"expl_damage": bullet.explosion_damage,
		"expl_knock": bullet.explosion_knockback,
	}
	if bullet.explosion_visual != null:
		data["visual"] = bullet.explosion_visual.resource_path
	# 发给非射手客户端
	for role in peer_by_role:
		if players.has(role) and players[role] != bullet.shooter:
			NetBus.rpc_id(peer_by_role[role], "bullet_spawn", data)

func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	if victim.has_method("take_hit"):
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
		# 广播命中事件给双方客户端(受害者白闪/击退反馈)
		for role in peer_by_role:
			NetBus.rpc_id(peer_by_role[role], "hit_event", victim_role, bullet.hit_damage, bullet.global_position)
	bullet.queue_free()
```

> `bullet.shooter` 是玩家引用(子弹带射手引用,阶段0已做)。服务器玩家是 Player 实例,`shooter` 指向它。
> 子弹场景路径:`bullet_scene` 是 `PackedScene`,子弹实例的 `scene_file_path` 在运行时已加载场景时可能为空;需在 `weapon_base.fire()` 给子弹设 meta：

```gdscript
# weapon_base.fire() 里 b.setup(...) 之后加:
	b.set_meta("scene_path", bullet_scene.resource_path)
```

- [ ] **Step 5: `pvp_client.gd` 收事件生成本地子弹副本**

`_ready` 连信号：

```gdscript
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_hit_event.connect(_on_hit_event)
```

加方法：

```gdscript
func _on_bullet_spawn(data: Dictionary) -> void:
	var scene: PackedScene = load(data["scene"])
	if scene == null:
		return
	var b: BulletBase = scene.instantiate()
	b.setup(data["vel"].normalized(), data["speed"], data["range"], data["size"], data["color"], null)
	b.gravity_factor = data["gravity"]
	b.hit_damage = data["hit_damage"]
	b.hit_impact = data["hit_impact"]
	b.apply_damage = false   # 视觉副本:不裁决伤害
	if data["explodes"]:
		b.explodes = true
		b.direct_hit_damage = data["direct_damage"]
		b.fuse_time = data["fuse"]
		b.hit_fuse_time = data["hit_fuse"]
		b.explosion_radius = data["radius"]
		b.explosion_damage = data["expl_damage"]
		b.explosion_knockback = data["expl_knock"]
		if data.has("visual"):
			b.explosion_visual = load(data["visual"])
	b.global_position = data["pos"]
	level0.get_node("WorldViewport").add_child(b)

func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		# 本地玩家被击中:即时反馈(白闪/击退),血量以快照权威为准
		_local.take_hit(source_pos, damage, false, -1.0)
```

> 本地玩家自己开火时,武器 fire() 本地已生成子弹(apply_damage 默认 true)。但 PvP 里本地子弹也应只做视觉、不裁决(否则本地命中本地玩家 → 自伤)。需在 `pvp_client.gd` 里对本地玩家武器生成的子弹设 apply_damage=false。武器 fire 由 weapon_base 生成,统一处理最稳妥：在 `weapon_base.fire()` 里加 `b.apply_damage = not Level0.pvp_mode`(PvP 下所有本地生成子弹均为视觉;服务器权威子弹在服务器进程,Level0.pvp_mode=false)。

```gdscript
# weapon_base.fire() 里 b.setup(...) 之后加:
	b.apply_damage = not Level0.pvp_mode
```

- [ ] **Step 6: 验证——headless 起 pvp_game 60 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://scenes/pvp_game.tscn --quit-after 60 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

- [ ] **Step 7: 提交**

```bash
git add Globals/net_bus.gd Scenes/Weapons/bullet_base.gd Scenes/Weapons/weapon_base.gd Globals/explosion.gd server/match_host.gd Scenes/pvp_client.gd
git commit -m "feat: 武器对射——服务器裁决命中 + bullet_spawn/hit 事件 + 客户端视觉子弹"
```

---

## Task 6: loopback 冒烟全链路(输入→移动→射击→命中)

**Files:**
- Create: `Tests/pvp_match_smoke.gd` + `Tests/pvp_match_smoke.tscn`(无头冒烟客户端:发送固定输入,断言收到快照/命中)
- Create: `Tests/pvp_match_smoke.sh`(起服务器 + 双客户端 loopback)

**Interfaces:**
- Consumes: `NetBus`(send_input/snapshot/hit_event/bullet_spawn)、`PvpSession`

- [ ] **Step 1: 新建 `Tests/pvp_match_smoke.gd`**

```gdscript
extends Node
# B2 loopback 冒烟客户端:建房后发送固定输入(右移 + 开火),断言收到快照/命中事件。
# 用法: godot --headless --path . Tests/pvp_match_smoke.tscn -- --role create
#       godot --headless --path . Tests/pvp_match_smoke.tscn -- --role join --code 0000

var role: String = ""
var code: String = ""
var _frames := 0
var _got_snapshot := false
var _got_hit := false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role": role = args[i + 1]
			"--code": code = args[i + 1]
	if role.is_empty():
		printerr("SMOKE_MATCH FAIL: 缺 --role")
		get_tree().quit(1)
		return
	NetBus.local_snapshot.connect(func(s: Dictionary) -> void:
		_got_snapshot = true)
	NetBus.local_hit_event.connect(func(vr: int, dmg: int, sp: Vector2) -> void:
		print("SMOKE_MATCH: hit victim_role=%d dmg=%d" % [vr, dmg])
		_got_hit = true)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	NetBus.start_client("127.0.0.1")

func _on_connected() -> void:
	match role:
		"create":
			NetBus.rpc_id(1, "create_room")
		"join":
			NetBus.rpc_id(1, "join_room", code)

func _physics_process(_delta: float) -> void:
	_frames += 1
	# 建房客户端:先右移,再开火;加入方:不动,挨打
	if role == "create":
		var held := NetworkInputSource.BIT_ATTACK if _frames > 120 else 0
		var pkt := {
			"ax": 1.0,
			"held": held,
			"pressed": NetworkInputSource.BIT_ATTACK if _frames == 121 else 0,
			"released": 0,
			"weapon": 0,
			"aim": Vector2(1, 0),
		}
		NetBus.rpc_id(1, "send_input", pkt)
	# 建房方:等命中/或 360 帧超时
	if role == "create" and _got_hit:
		print("SMOKE_MATCH OK: 命中裁决收到")
		get_tree().quit(0)
	if _frames > 600:
		printerr("SMOKE_MATCH FAIL: 超时 role=%s got_snapshot=%s got_hit=%s" % [role, _got_snapshot, _got_hit])
		get_tree().quit(1)
```

- [ ] **Step 2: 新建 `Tests/pvp_match_smoke.tscn`**

```
[gd_scene format=3 uid="uid://pvpmatches000a1"]
[ext_resource type="Script" path="res://tests/pvp_match_smoke.gd" id="1"]
[node name="PvpMatchSmoke" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 新建 `Tests/pvp_match_smoke.sh`**

```bash
#!/usr/bin/env bash
# B2 loopback 冒烟:起服务器 + 建房/加入客户端,断言命中裁决链路。
set -e
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
cd "$(dirname "$0")/.."

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp2_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 客户端 A 建房 =="
"$GODOT" --headless --path . res://tests/pvp_match_smoke.tscn -- --role create > /tmp/pvp2_a.log 2>&1 &
A_PID=$!
sleep 2
CODE=$(grep -oP '房间号 \K[0-9]+' /tmp/pvp2_server.log | head -1)
if [ -z "$CODE" ]; then
  CODE=$(grep -oP '房间号 \K[0-9]+' /tmp/pvp2_server.log | tail -1)
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://tests/pvp_match_smoke.tscn -- --role join --code "$CODE" > /tmp/pvp2_b.log 2>&1 &
B_PID=$!

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill $SERVER_PID 2>/dev/null || true

if grep -q "SMOKE_MATCH OK" /tmp/pvp2_a.log; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL"
  cat /tmp/pvp2_server.log; cat /tmp/pvp2_a.log; cat /tmp/pvp2_b.log
  exit 1
fi
```

- [ ] **Step 4: 验证——跑 loopback 冒烟(用户跑)**

```bash
bash Tests/pvp_match_smoke.sh
```

Expected: `SMOKE PASS`。若建房客户端 121 帧开火时两台玩家已能互相射击、命中裁决广播到达,冒烟退出 0。

> 该脚本是 `.sh`,在 Git Bash 下运行。

- [ ] **Step 5: 提交**

```bash
git add Tests/pvp_match_smoke.gd Tests/pvp_match_smoke.tscn Tests/pvp_match_smoke.sh
git commit -m "test: B2 loopback 冒烟——输入上报→快照→射击→命中裁决"
```

---

## 收尾：CLAUDE.md 更新

- [ ] **Step 1: 更新 `CLAUDE.md`**

在「网络与 PvP」小节补 B2 内容：输入包(60Hz reliable)、快照(30Hz unreliable)、事件包(bullet_spawn/hit)、`MatchHost` 服务器权威模拟、`NetworkInputSource`、`PlayerReplica` 副本插值、自己校正、`apply_damage` 视觉子弹开关、`pvp_match_smoke.sh`。网络协议走 canonical、渲染归最近副本、插值最短路径。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 更新 B2 对局互通小节"
```

---

## 自检(写完后)

- **Spec 覆盖**：设计文档 §4.1 三套包(输入/快照/事件)由 Task 2/4/5 落地；§4.2 子弹确定性本地模拟+服务器裁决由 Task 5 落地；§4.3 环面纪律由 replica 插值 + 自校正落地；§3.4 MatchHost 由 Task 3 落地；§6 数据流(输入→模拟→快照→插值→校正→事件)全链路由 Task 2-6 落地。阶段 4(回合/记分/复活/换边)明确不在本期。
- **占位符**：每步有完整代码/命令，无 TBD。
- **类型一致**：`NetworkInputSource.BIT_*`、`NetBus.send_input/snapshot/bullet_spawn/hit_event`、`MatchHost.new(map_path, players, role_peers)`、`PlayerReplica.apply_snapshot`、`player.apply_authoritative_state`、`BulletBase.apply_damage` 全计划命名一致。
- **已知遗留**：断线时 MatchHost 清理、tile_destroyed 事件同步、回合状态机/记分/复活 = 阶段4；客户端视觉子弹与服务器权威子弹散射随机量不同(本地掷定)导致轨迹微差——命中由服务器裁决,可接受。`pvp_client` 的 `get_current_aim_dir` 依赖 weapon_base 公开方法,已规划。
