# PvP 阶段 1：匹配与进图 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 搭起联网骨架：主菜单 → 匹配（建房/输房间号）→ 服务器开房、签发房间号、双方就绪 → 两端进入竞技场（`pvp_game`），本地玩家能动（C2 本地模拟）。**本期不做对局互通**（输入/快照/远端副本 = 阶段 2）。

**Architecture:** 新增 `NetBus` autoload 作为唯一网络 RPC 收口（服务器与客户端共用同一节点路径 `/root/NetBus`，跨场景常驻）。服务器端 `server_main` + `RoomManager`（房间注册表）；客户端 `main_menu` → `matchmaking` → `pvp_game`。会话配置用静态 `PvpSession` 传递。地图由服务器钉定、发文件名，客户端 `set_map_file` 加载同一张。

**Tech Stack:** Godot 4.7.1 标准版，ENet 高层多人（`ENetMultiplayerPeer` + `MultiplayerAPI` RPC），无测试框架（`-s` 冒烟 + headless 启动 + 多进程 loopback 冒烟）。

## Global Constraints

- Godot 可执行：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **新增 `class_name` 文件后必须 `--import` 刷新全局类缓存**，否则引用处 Parse Error（已存记忆）。
- `NetBus` 成为**第二个 autoload**（打破"唯一 autoload 是 GameParameters"约定，计划末尾同步 CLAUDE.md）。
- 服务器进程 = 场景模式（`server_main.tscn`）运行，不能用 `-s`（需要 autoload）；用 `--headless`。
- 冒烟 `enemy_logic_smoke.gd` 成功打印 `SMOKE OK` 退出 0；`player_contract_smoke.gd` 打印 `CONTRACT OK`。
- 测试由用户跑；本计划期间的验证命令写在每步里。
- 提交直接到 `main`（仓库惯例）。

---

### Task 1: NetBus autoload（网络收口）

**Files:**
- Create: `Globals/net_bus.gd`
- Modify: `project.godot`（`[autoload]` 段加 `NetBus`）

**Interfaces:**
- Produces: 全局可用 `NetBus`（autoload）：
  - `start_server(port=7777) -> Error` / `start_client(addr, port=7777) -> Error` / `stop()`
  - 服务器端被调（`@rpc("any_peer")`）：`create_room()` / `join_room(code: String)`
  - 客户端端被调（`@rpc("authority")`）：`room_created(code)` / `room_joined(role)` / `match_start(role, spawn: Vector2i, map_path)` / `server_message(text)`
  - 信号：`local_room_created` / `local_room_joined` / `local_match_start` / `local_server_message`
- Consumes: 服务器端依赖 `RoomManager.instance`（Task 4 产出）；客户端 UI 订阅本地信号（Task 5）。

- [ ] **Step 1: 新建 `Globals/net_bus.gd`**

```gdscript
extends Node
# 网络总线(autoload,PvP 唯一网络收口):服务器与客户端共用同一节点路径 /root/NetBus,
# RPC 才能跨场景路由(autoload 常驻,不随场景切换销毁)。方法按"调用方"区分两端。

signal local_room_created(code: String)
signal local_room_joined(role: int)
signal local_match_start(role: int, spawn: Vector2i, map_path: String)
signal local_server_message(text: String)

const DEFAULT_PORT := 7777

var is_server_mode: bool = false

func _ready() -> void:
	multiplayer.peer_connected.connect(func(id: int) -> void: print("NetBus: 玩家连入 peer=%d" % id))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func() -> void: print("NetBus: 已连接服务器"))
	multiplayer.connection_failed.connect(func() -> void: local_server_message.emit("连接失败"))
	multiplayer.server_disconnected.connect(func() -> void: local_server_message.emit("服务器断开"))

func _on_peer_disconnected(id: int) -> void:
	print("NetBus: 玩家断开 peer=%d" % id)
	if is_server_mode and RoomManager.instance != null:
		RoomManager.instance.on_peer_left(id)

func start_server(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 16)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = true
	return err

func start_client(addr: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port)
	if err == OK:
		multiplayer.multiplayer_peer = peer
		is_server_mode = false
	return err

func stop() -> void:
	multiplayer.multiplayer_peer = null
	is_server_mode = false

# ── 客户端 → 服务器 ──
@rpc("any_peer", "reliable")
func create_room() -> void:
	var caller := multiplayer.get_remote_sender_id()
	if RoomManager.instance != null:
		RoomManager.instance.create_room(caller)

@rpc("any_peer", "reliable")
func join_room(code: String) -> void:
	var caller := multiplayer.get_remote_sender_id()
	if RoomManager.instance != null:
		RoomManager.instance.join_room(caller, code)

# ── 服务器 → 客户端(权威方=peer1 可调)──
@rpc("authority", "reliable")
func room_created(code: String) -> void:
	local_room_created.emit(code)

@rpc("authority", "reliable")
func room_joined(role: int) -> void:
	local_room_joined.emit(role)

@rpc("authority", "reliable")
func match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	local_match_start.emit(role, spawn, map_path)

@rpc("authority", "reliable")
func server_message(text: String) -> void:
	local_server_message.emit(text)
```

- [ ] **Step 2: 注册 autoload（改 `project.godot`）**

`[autoload]` 段在 `GameParameters="*res://core/game_parameters.gd"` 下一行加：

```
NetBus="*res://core/net_bus.gd"
```

- [ ] **Step 3: 验证——headless 启动 5 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

Expected: 无 `SCRIPT ERROR`（NetBus 是 autoload，_ready 会跑，不应报错）。

- [ ] **Step 4: 提交**

```bash
git add Globals/net_bus.gd project.godot
git commit -m "feat: NetBus autoload——PvP 网络 RPC 唯一收口(第二个 autoload,约定放宽)"
```

---

### Task 2: PvpSession + 钉住地图

**Files:**
- Create: `Globals/pvp_session.gd`
- Modify: `Globals/maze_generator.gd`（加 `set_map_file`）
- Modify: `Tests/enemy_logic_smoke.gd`（加 set_map_file 断言）

**Interfaces:**
- Produces: `PvpSession`（静态 RefCounted）：`server_address/port/room_code/role/spawn/map_path` + `reset()`。
- Produces: `MazeGenerator.set_map_file(path: String)`（钉住会话地图）。
- Consumes: Task 3 菜单 `PvpSession.reset()`；Task 5 匹配读写；Task 6 对局读取；Task 4 服务器 `MazeGenerator.map_file_path()` 定图 + `set_map_file`。

- [ ] **Step 1: 新建 `Globals/pvp_session.gd`**

```gdscript
class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。

static var server_address: String = "127.0.0.1"
static var port: int = 7777
static var room_code: String = ""
static var role: int = 1          # 1=P1, 2=P2
static var map_path: String = ""
static var spawn: Vector2i = Vector2i(-1, -1)

static func reset() -> void:
	server_address = "127.0.0.1"
	port = 7777
	room_code = ""
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
```

- [ ] **Step 2: 改 `maze_generator.gd`——加钉图入口**

在 `static func map_file_path() -> String:` 函数之后加：

```gdscript
# 钉住地图文件(PvP:服务器定图,客户端加载同名文件;覆盖会话随机读的缓存)。
static func set_map_file(path: String) -> void:
	_picked_map = path
```

- [ ] **Step 3: 加冒烟断言（TDD：先失败）**

在 `Tests/enemy_logic_smoke.gd` 的 `"map_size: 从地图文件读取列/行数(125×75)"` 检查**之前**加：

```gdscript
	# ── Task 2: 钉住地图 ──
	MazeGenerator.set_map_file("res://maps/demo.cyrm")
	_check(MazeGenerator.map_file_path() == "res://maps/demo.cyrm", "set_map_file 钉住地图")
```

> 该行之后的 `map_size` 检查改读 demo.cyrm（125×75，断言不变）。跑一次冒烟应 FAIL（`set_map_file` 尚未定义 → `map_file_path` 返回随机路径）。

- [ ] **Step 4: 刷新类缓存 + 跑冒烟确认绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import 2>&1 | grep -E "PvpSession" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "set_map_file|SMOKE OK|FAIL"
```

Expected: `ok - set_map_file 钉住地图` + `SMOKE OK`，退出 0。

- [ ] **Step 5: 提交**

```bash
git add Globals/pvp_session.gd Globals/maze_generator.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: PvpSession 会话配置 + MazeGenerator.set_map_file 钉图"
```

---

### Task 3: 主菜单（单人/多人）+ 默认场景

**Files:**
- Create: `Scenes/main_menu.gd`、`Scenes/main_menu.tscn`
- Modify: `project.godot`（`run/main_scene` 改到菜单）

**Interfaces:**
- Produces: 默认场景 = 主菜单；单人 → `Level0.tscn`（先 `Level0.pvp_mode=false` 复位）；多人 → `PvpSession.reset()` + 匹配场景。

- [ ] **Step 1: 新建 `Scenes/main_menu.gd`**

```gdscript
extends Control
# 主菜单:单人 → Level0;多人 → 匹配场景。

func _ready() -> void:
	var title := Label.new()
	title.text = "The Cyancular Ruins"
	title.position = Vector2(60, 60)
	title.add_theme_font_size_override("font_size", 40)
	add_child(title)

	var single := Button.new()
	single.text = "单人"
	single.position = Vector2(60, 180)
	single.size = Vector2(200, 48)
	single.pressed.connect(func() -> void:
		Level0.pvp_mode = false  # 复位 PvP 标志,避免上次 PvP 残留
		get_tree().change_scene_to_file("res://scenes/Level0.tscn"))
	add_child(single)

	var multi := Button.new()
	multi.text = "多人"
	multi.position = Vector2(60, 240)
	multi.size = Vector2(200, 48)
	multi.pressed.connect(func() -> void:
		PvpSession.reset()
		get_tree().change_scene_to_file("res://scenes/matchmaking.tscn"))
	add_child(multi)
```

- [ ] **Step 2: 新建 `Scenes/main_menu.tscn`**

```
[gd_scene format=3 uid="uid://mainmenu0000a1"]
[ext_resource type="Script" path="res://scenes/main_menu.gd" id="1"]
[node name="MainMenu" type="Control"]
script = ExtResource("1")
```

> 若编辑器提示该 uid 非法/冲突,打开场景保存一次由编辑器重新分配即可。

- [ ] **Step 3: 改 `project.godot` 默认场景**

`run/main_scene="uid://c1xl4jcmy2e6c"` 改为：

```
run/main_scene="res://scenes/main_menu.tscn"
```

- [ ] **Step 4: 验证——headless 启动 5 帧（应进主菜单,无脚本错误）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 5 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 5: 提交**

```bash
git add Scenes/main_menu.gd Scenes/main_menu.tscn project.godot
git commit -m "feat: 主菜单(单人/多人),默认场景改为菜单"
```

---

### Task 4: 服务器（server_main + RoomManager 房间协议）

**Files:**
- Create: `server/server_main.gd`、`server/server_main.tscn`、`server/room_manager.gd`

**Interfaces:**
- Produces: `server_main.tscn`（headless 运行入口）：`NetBus.start_server()` + 挂 `RoomManager`。
- Produces: `class_name RoomManager extends Node`（静态 `instance`）：
  - `create_room(caller: int)` → 生成房间号 → `NetBus.rpc_id(caller, "room_created", code)`
  - `join_room(caller: int, code: String)` → 满则拒；成功 → `room_joined(role)` + 2 人满 → `_start_match`
  - `on_peer_left(peer_id)` → 清理房间
  - `_start_match` → 服务器定图（`map_file_path()`）+ 读出生点 → 给双方发 `match_start(role, spawn, map_path)`
- Consumes: `NetBus`（Task 1）、`MazeGenerator`（定图/出生点）。

- [ ] **Step 1: 新建 `server/room_manager.gd`**

```gdscript
class_name RoomManager
extends Node

# 房间注册表(服务器端):房间号 → 玩家;2 人就绪发 match_start。

static var instance: RoomManager = null

class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> 1/2

var rooms: Dictionary = {}   # code -> Room

func _enter_tree() -> void:
	instance = self

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _generate_code() -> String:
	return "%04d" % (randi() % 10000)

func create_room(caller: int) -> void:
	var code := _generate_code()
	while rooms.has(code):
		code = _generate_code()
	var room := Room.new()
	room.code = code
	room.players.append(caller)
	room.player_role[caller] = 1
	rooms[code] = room
	print("房间 %s 创建(房主 peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_created", code)

func join_room(caller: int, code: String) -> void:
	if not rooms.has(code):
		NetBus.rpc_id(caller, "server_message", "房间不存在")
		return
	var room: Room = rooms[code]
	if room.players.size() >= 2:
		NetBus.rpc_id(caller, "server_message", "房间已满")
		return
	room.players.append(caller)
	room.player_role[caller] = 2
	print("房间 %s 加入(peer=%d)" % [code, caller])
	NetBus.rpc_id(caller, "room_joined", 2)
	_start_match(room)

func on_peer_left(peer_id: int) -> void:
	for code in rooms.keys():
		var room: Room = rooms[code]
		room.players.erase(peer_id)
		room.player_role.erase(peer_id)
		if room.players.is_empty():
			rooms.erase(code)
			print("房间 %s 关闭" % code)

func _start_match(room: Room) -> void:
	var map_path := MazeGenerator.map_file_path()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	for peer_id in room.players:
		var role: int = room.player_role[peer_id]
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	print("房间 %s 开局" % room.code)
```

- [ ] **Step 2: 新建 `server/server_main.gd`**

```gdscript
extends Node2D
# 服务器入口(headless 运行):监听端口 + 挂 RoomManager。

func _ready() -> void:
	var err := NetBus.start_server()
	if err != OK:
		push_error("服务器: 监听失败 %d" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	print("服务器就绪,等待玩家……")
```

- [ ] **Step 3: 新建 `server/server_main.tscn`**

```
[gd_scene format=3 uid="uid://servermain0000a1"]
[ext_resource type="Script" path="res://server/server_main.gd" id="1"]
[node name="ServerMain" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 4: 刷新类缓存 + 验证——headless 起服务器 60 帧无报错**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import 2>&1 | grep -E "RoomManager" ; \
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn --quit-after 60 2>&1 | grep -E "服务器|SCRIPT ERROR|ERROR" | head -5
```

Expected: 打印 `服务器就绪,等待玩家……`,无 `SCRIPT ERROR`。

- [ ] **Step 5: 提交**

```bash
git add server/server_main.gd server/server_main.tscn server/room_manager.gd
git commit -m "feat: 服务器入口 + RoomManager 房间协议(建房/加入/开局)"
```

---

### Task 5: 匹配场景（建房 / 输房间号）

**Files:**
- Create: `Scenes/matchmaking.gd`、`Scenes/matchmaking.tscn`

**Interfaces:**
- Consumes: `NetBus`（start_client + 本地信号）、`PvpSession`。
- Produces: 连接服务器 → 建房/加入 → 收 `match_start` → 存 `PvpSession` → 加载 `pvp_game.tscn`。

- [ ] **Step 1: 新建 `Scenes/matchmaking.gd`**

```gdscript
extends Control
# 匹配场景:建房 / 输入房间号加入。UI 代码式构建。

var _addr_edit: LineEdit
var _code_edit: LineEdit
var _status: Label

func _ready() -> void:
	_addr_edit = _make_line_edit(Vector2(60, 120), "服务器地址", PvpSession.server_address)
	_code_edit = _make_line_edit(Vector2(60, 180), "房间号(加入时填)", "")
	_status = Label.new()
	_status.position = Vector2(60, 320)
	_status.size = Vector2(700, 40)
	add_child(_status)

	var create_btn := _make_button(Vector2(60, 240), "建房", _on_create_pressed)
	var join_btn := _make_button(Vector2(280, 240), "加入", _on_join_pressed)
	var back_btn := _make_button(Vector2(60, 400), "返回", func() -> void:
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_server_message.connect(func(t: String) -> void: _status.text = t)
	_status.text = "输入服务器地址,选 建房 或 加入"

func _make_line_edit(pos: Vector2, placeholder: String, initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = Vector2(240, 36)
	le.placeholder_text = placeholder
	le.text = initial
	add_child(le)
	return le

func _make_button(pos: Vector2, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(200, 48)
	b.pressed.connect(fn)
	add_child(b)
	return b

func _on_create_pressed() -> void:
	PvpSession.server_address = _addr_edit.text.strip_edges() if _addr_edit.text != "" else PvpSession.server_address
	_status.text = "连接服务器……"
	multiplayer.connected_to_server.connect(func() -> void: NetBus.rpc_id(1, "create_room"), CONNECT_ONE_SHOT)
	NetBus.start_client(PvpSession.server_address)

func _on_join_pressed() -> void:
	var code := _code_edit.text.strip_edges()
	if code.is_empty():
		_status.text = "请填房间号"
		return
	PvpSession.room_code = code
	PvpSession.server_address = _addr_edit.text.strip_edges() if _addr_edit.text != "" else PvpSession.server_address
	_status.text = "连接服务器……"
	multiplayer.connected_to_server.connect(func() -> void: NetBus.rpc_id(1, "join_room", code), CONNECT_ONE_SHOT)
	NetBus.start_client(PvpSession.server_address)

func _on_room_created(code: String) -> void:
	_status.text = "房间号 %s —— 把房间号发给对手" % code

func _on_room_joined(role: int) -> void:
	PvpSession.role = role
	_status.text = "已加入,等待开始……"

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
```

- [ ] **Step 2: 新建 `Scenes/matchmaking.tscn`**

```
[gd_scene format=3 uid="uid://matchmake0000a1"]
[ext_resource type="Script" path="res://scenes/matchmaking.gd" id="1"]
[node name="Matchmaking" type="Control"]
script = ExtResource("1")
```

- [ ] **Step 3: 验证——headless 启动 5 帧（进匹配场景无报错）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://scenes/matchmaking.tscn --quit-after 5 2>&1 | grep -E "SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 4: 提交**

```bash
git add Scenes/matchmaking.gd Scenes/matchmaking.tscn
git commit -m "feat: 匹配场景(建房/输房间号)"
```

---

### Task 6: pvp_game 客户端对局场景（进竞技场 + 本地能动）

**Files:**
- Create: `Scenes/pvp_client.gd`、`Scenes/pvp_game.tscn`

**Interfaces:**
- Consumes: `PvpSession`（map_path/spawn/role）、`Level0.pvp_mode`、`PostProcess`。
- Produces: `pvp_game.tscn`：实例化 Level0（pvp 模式）+ 本地玩家定位到出生点 + 补后处理。C2 本地玩家读本地输入 → 能动。**远端副本 = 阶段 2**。

- [ ] **Step 1: 新建 `Scenes/pvp_client.gd`**

```gdscript
extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理。

func _ready() -> void:
	MazeGenerator.set_map_file(PvpSession.map_path)
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/Level0.tscn").instantiate()
	add_child(level0)
	var local: Node2D = level0.get_node("WorldViewport/Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])
```

- [ ] **Step 2: 新建 `Scenes/pvp_game.tscn`**

```
[gd_scene format=3 uid="uid://pvpgame000000a1"]
[ext_resource type="Script" path="res://scenes/pvp_client.gd" id="1"]
[node name="PvpGame" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 3: 验证——headless 启动 60 帧（应进 pvp 世界,本地玩家能跑物理,无脚本错误）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://scenes/pvp_game.tscn --quit-after 60 2>&1 | grep -E "进入竞技场|SCRIPT ERROR|Parse Error" ; echo "BOOT_DONE"
```

> 直接跑 pvp_game 时 `PvpSession.map_path` 为空 → `set_map_file("")` 会把缓存置空 → `load_map_file` 重新随机选图（可接受,仅验证用）。实际流程里 map_path 由服务器下发。

- [ ] **Step 4: 提交**

```bash
git add Scenes/pvp_client.gd Scenes/pvp_game.tscn
git commit -m "feat: pvp_game 客户端对局场景——进竞技场 + 本地玩家(C2)能动"
```

---

### Task 7: loopback 冒烟（服务器 + 双客户端建房/加入/开局）

**Files:**
- Create: `Tests/pvp_smoke_client.gd`、`Tests/pvp_smoke_client.tscn`、`Tests/pvp_room_smoke.sh`

**Interfaces:**
- Consumes: `NetBus` + 服务器（Task 4）。
- Produces: 自动化验证——服务器进程 + 两个客户端进程对 `127.0.0.1`：A 建房拿房间号 → B 加入 → 双方收到 `match_start` → 各自 quit(0)。

- [ ] **Step 1: 新建 `Tests/pvp_smoke_client.gd`**

```gdscript
extends Node
# 冒烟用无头客户端:按命令行参数扮演建房/加入,断言关键流程后退出。
# 用法: godot --headless --path . Tests/pvp_smoke_client.tscn -- --role create
#       godot --headless --path . Tests/pvp_smoke_client.tscn -- --role join --code 0000

var role: String = ""
var code: String = ""
var _expect_start := false

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		match args[i]:
			"--role": role = args[i + 1]
			"--code": code = args[i + 1]
	if role.is_empty():
		printerr("SMOKE_CLIENT FAIL: 缺 --role")
		get_tree().quit(1)
		return
	NetBus.local_server_message.connect(func(t: String) -> void: print("[server] " + t))
	NetBus.local_room_created.connect(func(c: String) -> void:
		print("ROOM_CODE=" + c)
		print("SMOKE_CLIENT OK: 建房拿号"))
	NetBus.local_room_joined.connect(func(r: int) -> void:
		print("SMOKE_CLIENT OK: 加入成功 role=%d" % r))
	NetBus.local_match_start.connect(_on_match_start)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		printerr("SMOKE_CLIENT FAIL: 连接失败")
		get_tree().quit(1))
	var err := NetBus.start_client("127.0.0.1")
	if err != OK:
		printerr("SMOKE_CLIENT FAIL: start_client %d" % err)
		get_tree().quit(1)

func _on_connected() -> void:
	match role:
		"create":
			NetBus.rpc_id(1, "create_room")
		"join":
			_expect_start = true
			NetBus.rpc_id(1, "join_room", code)
		_:
			printerr("SMOKE_CLIENT FAIL: 非法 role %s" % role)
			get_tree().quit(1)

func _on_match_start(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	print("SMOKE_CLIENT OK: match_start")
	get_tree().quit(0)
```

- [ ] **Step 2: 新建 `Tests/pvp_smoke_client.tscn`**

```
[gd_scene format=3 uid="uid://pvpsmokec0000a1"]
[ext_resource type="Script" path="res://tests/pvp_smoke_client.gd" id="1"]
[node name="PvpSmokeClient" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 新建 `Tests/pvp_room_smoke.sh`**

```bash
#!/usr/bin/env bash
# loopback 冒烟:起服务器 + 建房客户端 + 加入客户端,断言开局流程。
set -e
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
cd "$(dirname "$0")/.."

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 客户端 A 建房 =="
"$GODOT" --headless --path . res://tests/pvp_smoke_client.tscn -- --role create > /tmp/pvp_a.log 2>&1 || true
CODE=$(grep -oP 'ROOM_CODE=\K[0-9]+' /tmp/pvp_a.log | head -1)
if [ -z "$CODE" ]; then
  echo "SMOKE FAIL: 建房客户端未拿到房间号"; cat /tmp/pvp_a.log; kill $SERVER_PID; exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://tests/pvp_smoke_client.tscn -- --role join --code "$CODE" > /tmp/pvp_b.log 2>&1 || true

kill $SERVER_PID 2>/dev/null || true
grep -q "match_start" /tmp/pvp_b.log && echo "SMOKE PASS" || { echo "SMOKE FAIL: B 未收到 match_start"; cat /tmp/pvp_a.log; cat /tmp/pvp_b.log; cat /tmp/pvp_server.log; exit 1; }
```

> 该脚本是 `.sh`，在 Git Bash 下 `bash Tests/pvp_room_smoke.sh` 运行。`grep -oP` 需 GNU grep（Git Bash 自带）。

- [ ] **Step 4: 手动端到端验证（你跑）**

1. 开一个终端：`"<Godot>" --headless --path . res://server/server_main.tscn`（或直接双击导出的服务器 exe）
2. 开两个游戏窗口（进多人 → 一个建房、一个输房间号加入）
3. 双方应进入竞技场,本地玩家可移动/跳/冲刺

- [ ] **Step 5: 提交**

```bash
git add Tests/pvp_smoke_client.gd Tests/pvp_smoke_client.tscn Tests/pvp_room_smoke.sh
git commit -m "test: loopback 冒烟——服务器+双客户端 建房/加入/开局"
```

---

## 收尾：CLAUDE.md 约定更新

- [ ] **Step 1: 更新 `CLAUDE.md`**

1. 改「唯一 autoload 是 GameParameters」那句 → 加上 NetBus 与放宽说明。
2. 加一小节（网络）简述：NetBus autoload 是 PvP 网络收口、`PvpSession` 会话配置、`RoomManager` 房间注册表、`server_main.tscn` 服务器入口、`pvp_game.tscn` 客户端对局场景。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md 更新 PvP 网络约定(NetBus autoload 放宽)"
```

---

## 自检（写完后）

- **Spec 覆盖**：设计文档 §3.2（场景流程）由 Task 3/5/6 落地；§3.4（服务器/RoomManager）由 Task 4 落地；§7 的「钉住地图」由 Task 2 落地（transport 收口以 `NetBus` autoload 形式落地，比独立抽象类更贴合 Godot 惯例）；会话状态 `PvpSession` 由 Task 2 落地。阶段 2（输入/快照/副本）明确不在本期,留 Plan B2。
- **占位符**：每步有完整代码/命令,无 TBD。
- **类型一致**：`NetBus.start_client/start_server`、`NetBus.rpc_id(1,"create_room")`、`RoomManager.instance`、`PvpSession.role/spawn/map_path`、`MazeGenerator.set_map_file`、`Level0.pvp_mode` 全计划命名一致。
- **已知遗留**：`matchmaking.gd` 里 `_on_match_start` 在 `match_start` 与 `room_joined` 可能竞态（服务器先发 `room_joined` 再发 `match_start`,顺序可靠,RPC 可靠有序 → 无竞态）。`attack`/切枪未进本期输入协议（阶段 2 补）。
