# 3v3 团队模式【B 册：接入与客户端】实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 A 册的权威层接到玩家手里 —— 大厅的选边房间、三条协议的互斥与三态化、客户端对局场景与最小 HUD —— 交付一个**六个人真能打起来**的 3v3。

**Architecture:** 完全照第三个模式的既有形状:`NetBusExt` 加一组 `team_*` RPC（**`NetBus` 方法表一个字不动**）→ `LobbyRooms` 加第三张注册表 `team_rooms` → `RoomManager` 拉起 `--team` worker（A 册已备好 `spawn_team_worker`）→ 客户端新页 `team_lobby`（extends `LobbyPage`，只写差异）→ 新场景 `team_game`（extends `PvpMatchClient`，副本数与队伍染色）。**C2 链路一行不改**。

**Tech Stack:** Godot 4.7.1 GDScript；`NetBusExt`（旁路扩展协议）；`NetBus`（方法表不动）；场景探针 + 真链路探针（判据 grep `ALL-OK`）。

## Global Constraints

- **本项目约定：测试由用户自己跑，不要代跑。** 计划里 `Run:` 是**写给用户**的；agent 自己可跑的是 `--import`、不占端口的 `--quit-after`、以及**不占 7777 的探针**。占 7777 的（`royale_probe` / `pvp_room_smoke` / `--autotest-*`）一律留给用户。
- **引擎路径**：`GODOT` 环境变量，未设时回落 `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`。
- **★ `NetBus` 的方法表一律不动**：新 RPC 全进 `NetBusExt`，且**不得与 `NetBus` 的任何方法同名**（同名 = 接收端挂错节点 = 静默 no-op，`beam_fired` 是那个先例）。守卫：`tests/reconnect_smoke.gd` 的节点归属双向断言，本册扩一条 `team_*` 的。
- **★ 定向发送前一律先判活**：`NetBus.reply(id, method, …)`（大厅侧答复 caller 的收口）或 `NetBus.is_peer_live(id)`。**不要**用 `multiplayer.get_peers()`（它滞后）。
- **大乱斗/1v1 的既有行为一行不改**（除 Task 3 那处**必要**的三态化扩展：`is_royale` 二分 → 三态）。
- **新 `class_name` 文件建完先 `--import`** 刷全局类缓存（否则引用处 Parse Error）。
- 场景探针 `--quit-after` 统一 **3600**；判据 grep `ALL-OK`，**不看退出码**。
- 提交信息用单引号或 `-F 文件`，不带任何 Claude/AI 署名行；提交后回读。每次 `git add` **只加本任务点名的文件**；未跟踪的 `_crashtest/` 不要动。
- **字号只用 16 的倍数**（`kh_l4/l5` 扫 `res://tests`）。新增 HUD 场景后要给 `tests/hud_declarative_probe.gd` 的 `PAIRS` 加一行。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `core/net/net_bus_ext.gd` | 修改 | `team_*` 五条上行 RPC + 两条下发 + 七个信号 |
| `server/lobby_rooms.gd` | 修改 | `TeamRoom` 注册表 + 建房/加入/选边/离开/列表/状态广播 + **三条路径互斥** + `teardown_room` 三态化 |
| `server/room_manager.gd` | 修改 | `team_start`（房主开局）+ `_sweep_stale_rooms` 的 team 分支 |
| `scenes/team_lobby.tscn/.gd` | **新建** | 3v3 大厅页（extends `LobbyPage`）：建房 / 房间列表 / 等待室**选边** |
| `scenes/main_menu.gd` | 修改 | 入口按钮 + `menu_autotest` 的 `must_reach` |
| `scenes/team_game.tscn/.gd` | **新建** | 对局客户端（extends `PvpMatchClient`）：5 副本 + 队伍染色 |
| `ui/team_hud.tscn/.gd` | **新建** | 最小记分条（按队）+ 中央广播 + 延迟 |
| `ui/minimap.gd` | 修改 | `setup_multi` 加**可选**的颜色提供器（版式不动） |
| `ui/ui_factory.gd` | 修改 | 两个队色 token（**占位**，UI 重做那份再定稿） |
| `tests/hud_declarative_probe.gd` | 修改 | `PAIRS` 加 `ui/team_hud` |
| `tests/team_room_smoke.gd` | **新建** | `-s`：纯逻辑（满员判据 / 最小空闲号 / 队满拒绝） |
| `tests/team_match_probe.tscn` + `.sh` | **新建** | 6 人真链路端到端探针 |
| `tests/reconnect_smoke.gd` | 修改 | 节点归属双向断言扩到 `team_*` |
| `CLAUDE.md` | 修改 | 记录 B 册 |

---

## Task 1: 前置检查（依赖 A 册）

**Files:** 无（只读命令）

- [ ] **Step 1: 确认 A 册已落地**

Run: `git log --oneline -12`
Expected: 能看到 A 册的十个提交（队伍表 / 穿透队友 / SpawnPicker / TeamHost 骨架 / 计分 / 复位 / 换边 / 掉线 / `--team` 契约 / `match_sync` 带 teams）。**缺哪个就停下等**。

- [ ] **Step 2: 确认工作区干净**

Run: `git status --short`
Expected: 只有 `?? _crashtest/`。

- [ ] **Step 3: 建分支**

Run: `git switch -c feat/team-3v3-b`
Expected: `Switched to a new branch 'feat/team-3v3-b'`

---

## Task 2: `NetBusExt` 的 `team_*` 协议

**Files:**
- Modify: `core/net/net_bus_ext.gd`（追加在 `royale_*` 那一区之后）
- Modify: `tests/reconnect_smoke.gd`（节点归属双向断言扩一条）

**Interfaces:**
- Consumes: 无
- Produces（全部在 `NetBusExt`，autoload 名 `NetBusExt`）：
  - 信号：`team_create_requested(caller, opts)` / `team_join_requested(caller, code, invite)` / `team_pick_requested(caller, team)` / `team_leave_requested(caller)` / `team_start_requested(caller)` / `local_team_rooms(rooms: Array)` / `local_team_room_state(state: Dictionary)`
  - RPC（`any_peer reliable`）：`team_create(opts)` / `team_join(code, invite)` / `team_pick(team)` / `team_leave()` / `team_start()`
  - RPC（`authority reliable`）：`team_rooms(rooms)` / `team_room_state(state)`

- [ ] **Step 1: 追加协议**

```gdscript
# ── 3v3 团队大厅(与 1v1 / 大乱斗三套协议并存;RPC 名不同互不干扰)──
# ★ 命名纪律:一律带 `team_` 前缀。既避开 NetBus 的方法表(硬纪律),也避开 royale_*(同名 = 挂错节点
#    = 静默 no-op,beam_fired 那个先例)。
# ★ 选边(`team_pick`)是 3v3 独有的上行:队伍**不由服务器推导**(role 号有空洞),玩家自己点。

signal team_create_requested(caller: int, opts: Dictionary)
signal team_join_requested(caller: int, code: String, invite: String)
signal team_pick_requested(caller: int, team: int)
signal team_leave_requested(caller: int)
signal team_start_requested(caller: int)
signal local_team_rooms(rooms: Array)             # 大厅 → 客户端:公开 3v3 房间列表
signal local_team_room_state(state: Dictionary)   # 大厅 → 客户端:房间实时状态(等待室/选边)

# 客户端 → 大厅:建房。opts = {is_public:bool, invite_code:String}
@rpc("any_peer", "reliable")
func team_create(opts: Dictionary) -> void:
	team_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

# 客户端 → 大厅:加入(私密房须带邀请码)
@rpc("any_peer", "reliable")
func team_join(code: String, invite: String) -> void:
	team_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite)

# 客户端 → 大厅:选边(team = 1 或 2)。该队已满 → 大厅回 server_message 拒绝
@rpc("any_peer", "reliable")
func team_pick(team: int) -> void:
	team_pick_requested.emit(multiplayer.get_remote_sender_id(), team)

# 客户端 → 大厅:退出所在 3v3 房间(开局前)
@rpc("any_peer", "reliable")
func team_leave() -> void:
	team_leave_requested.emit(multiplayer.get_remote_sender_id())

# 客户端 → 大厅:房主请求开局(**两队各 3 人**才允许;服务端再判一次)
@rpc("any_peer", "reliable")
func team_start() -> void:
	team_start_requested.emit(multiplayer.get_remote_sender_id())

# 大厅 → 客户端:公开房间列表 [{code, players, max_players, names}]
@rpc("authority", "reliable")
func team_rooms(rooms: Array) -> void:
	local_team_rooms.emit(rooms)

# 大厅 → 客户端:房间实时状态 {code, is_public, invite_code, host_role, team_size,
#   players: [{role, name, team}], in_match, your_role}(等待室靠它渲染两队名单)
@rpc("authority", "reliable")
func team_room_state(state: Dictionary) -> void:
	local_team_room_state.emit(state)
```

- [ ] **Step 2: 扩 `tests/reconnect_smoke.gd` 的节点归属断言**

该文件现有"三条 RPC 的节点归属双向断言"。加一段同样的形状（**双向**：RPC 名必须在 `NetBusExt` 里出现、且**不得**在 `net_bus.gd` 里出现）：

```gdscript
	# 3v3 的七条 team_* 同样必须**只**在 NetBusExt(挂错节点 = 静默 no-op)
	for m in ["team_create", "team_join", "team_pick", "team_leave", "team_start",
			"team_rooms", "team_room_state"]:
		if not ext_src.contains("func %s(" % m):
			_fail = "NetBusExt 缺 %s" % m
		if bus_src.contains("func %s(" % m):
			_fail = "★ %s 同时出现在 NetBus(应只在 NetBusExt)" % m
```

（`ext_src` / `bus_src` 用该文件已有的读法；实施时按它现成的变量名对齐。）

- [ ] **Step 3: `--import` + 让用户跑**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_smoke.tscn`（若该探针是 `-s` 形态则用 `-s` 跑法，按文件首行判断）

Expected: 该探针的 `ALL-OK`。

- [ ] **Step 4: 提交**

```bash
git add core/net/net_bus_ext.gd tests/reconnect_smoke.gd
git commit -m 'feat(team): NetBusExt 加 team_* 协议(五上行两下发;节点归属双向断言)'
```

---

## Task 3: `LobbyRooms.TeamRoom` + 三态化

**Files:**
- Modify: `server/lobby_rooms.gd`
- Create: `tests/team_room_smoke.gd`（`-s`）

**Interfaces:**
- Consumes: `LobbyRooms.launcher`、`_peer_names`、`teardown_room`
- Produces:
  - `class TeamRoom`：`code / host_peer / players / player_role / team_of / is_public / invite_code / in_match / worker_port / created_at / tokens`
  - `LobbyRooms.TEAM_SIZE := 3`、`LobbyRooms.TEAM_ROLES := 6`
  - `team_rooms: Dictionary`（code → TeamRoom）
  - `team_room_of(caller) -> TeamRoom`、`_in_team_room(caller) -> bool`、`team_room_ready(tr) -> bool`
  - handler：`team_create / team_join / team_pick / team_leave / team_list`
  - `_broadcast_team_state(tr)` / `_flush_team_state(tr)`
  - `teardown_room` 支持 `TeamRoom`（三态）

- [ ] **Step 1: 写失败的 `-s` 冒烟 `tests/team_room_smoke.gd`**

```gdscript
extends SceneTree

# 3v3 房间的**纯逻辑**冒烟(满员判据 / 最小空闲号 / 队满拒绝 / 互斥判定)。
# 跑法: "$GODOT" --headless --path . -s res://tests/team_room_smoke.gd
# 通过 = `TEAM ROOM SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ `-s` 阶段 autoload 不存在,故这里**只测不碰 autoload 的纯函数**:把判据收成
#   `LobbyRooms` 的静态函数,再由 RPC handler 调用(单一来源)。判据错了的表现是静默的:
#   "两队人数不等也能开"会让 3v3 变成 4v2。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。

func _initialize() -> void:
	var script = load("res://server/lobby_rooms.gd")
	if script == null:
		print("TEAM ROOM SMOKE: FAIL(加载 lobby_rooms.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	# ① 满员判据:两队各 3 人才算准备好
	var ready := {1: [1, 2, 3], 2: [5, 6, 7]}   # 队号 -> 该队 role 列表
	if not script.team_ready(ready):
		fails.append("两队各 3 人应当 ready")
	var lopsided := {1: [1, 2, 3, 4], 2: [5, 6]}
	if script.team_ready(lopsided):
		fails.append("★ 4v2 不得 ready(满 6 人才开)")
	var half := {1: [1, 2, 3]}
	if script.team_ready(half):
		fails.append("只有一队不得 ready")
	# ② 选边闸门:该队满 3 人 → 拒绝
	if script.team_can_join({1: [1, 2, 3], 2: []}, 1):
		fails.append("★ 1 队满 3 人后不得再加入")
	if not script.team_can_join({1: [1, 2, 3], 2: []}, 2):
		fails.append("2 队有空位应当允许")
	if fails.is_empty():
		print("TEAM ROOM SMOKE: ALL-OK")
		quit(0)
	else:
		print("TEAM ROOM SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
```

- [ ] **Step 2: 跑确认它红**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/team_room_smoke.gd`
Expected: `FAIL(加载…失败)` 或 `Nonexistent function 'team_ready'`。

- [ ] **Step 3: 在 `server/lobby_rooms.gd` 加 TeamRoom 与静态判据**

```gdscript
const TEAM_SIZE := 3     # 每队人数
const TEAM_ROLES := 6    # 两队合计(满员才开局,无 AI 补位、无降级)


class TeamRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids
	var player_role: Dictionary = {}      # peer id -> role(1..6,最小空闲号)
	var team_of: Dictionary = {}          # role(int) -> 1/2(**选边前不在表里**)
	var is_public := true
	var invite_code := ""
	var in_match := false
	var worker_port: int = 0
	var created_at := 0.0
	var tokens: Dictionary = {}           # peer_id -> 会话令牌(断线重连用)

var team_rooms: Dictionary = {}   # code -> TeamRoom


# ── 3v3 的**纯判据**(静态:`-s` 可测;RPC handler 与 RoomManager 都调它们,判据只有这一份)──
# 入参形状统一是 `{1: [role, …], 2: [role, …]}`(`_by_team()` 造),别在别处另算一遍。

# 两队是否都满员(满 6 人才允许开局)。★ 4v2 也算 6 人,但那不是 3v3。
static func team_ready(by_team: Dictionary, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(1, []) as Array).size() == size \
			and (by_team.get(2, []) as Array).size() == size

# 该队还能不能再进人
static func team_can_join(by_team: Dictionary, team: int, size: int = TEAM_SIZE) -> bool:
	return (by_team.get(team, []) as Array).size() < size

- [ ] **Step 4: 加 handler 与状态广播（照 `royale_*` 那一套逐条写）**

```gdscript
# ── 3v3 房间:建房/加入/选边/离开/列表(与 1v1、大乱斗**三路互斥**)──

# 某 role 的队号;未选边 → 0
func _team_of(tr: TeamRoom, role: int) -> int:
	return int(tr.team_of.get(role, 0))

# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)
func _by_team(tr: TeamRoom) -> Dictionary:
	var out := {1: [], 2: []}
	for role in tr.team_of:
		var t := int(tr.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


# 这个房能不能开局(RoomManager.team_start 调;**对外的公开口** —— 别让它去读 `_by_team`)。
func team_room_ready(tr: TeamRoom) -> bool:
	return team_ready(_by_team(tr))


func team_room_of(caller: int) -> TeamRoom:
	for c in team_rooms:
		if (team_rooms[c] as TeamRoom).players.has(caller):
			return team_rooms[c]
	return null


# 该 caller 是否已在 3v3 房间里。★ 三条路径互斥要**双向**判:本函数给 1v1/大乱斗的建房入口用,
# `_in_1v1_room` / `royale_room_of` 给本节的入口用 —— 只加一头会出现"从 1v1 房直接开 3v3 房"。
func _in_team_room(caller: int) -> bool:
	return team_room_of(caller) != null


func team_create(caller: int, opts: Dictionary) -> void:
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	var code := _generate_code()
	while team_rooms.has(code):
		code = _generate_code()
	var tr := TeamRoom.new()
	tr.code = code
	tr.host_peer = caller
	tr.players.append(caller)
	tr.player_role[caller] = 1
	tr.created_at = Time.get_unix_time_from_system()
	tr.is_public = bool(opts.get("is_public", true))
	tr.invite_code = str(opts.get("invite_code", "")).strip_edges()
	if not tr.is_public and tr.invite_code.is_empty():
		tr.invite_code = _generate_code()
	team_rooms[code] = tr
	print("3v3 房 %s 创建(房主 peer=%d,%s)" % [code, caller, "公开" if tr.is_public else "私密"])
	_broadcast_team_state(tr)


func team_join(caller: int, code: String, invite: String) -> void:
	if not team_rooms.has(code):
		NetBus.reply(caller, "server_message", "房间不存在")
		return
	if _in_team_room(caller):
		NetBus.reply(caller, "server_message", "你已在 3v3 房间中")
		return
	if _in_1v1_room(caller) or royale_room_of(caller) != null:
		NetBus.reply(caller, "server_message", "你已在其他房间,请先退出")
		return
	var tr: TeamRoom = team_rooms[code]
	if tr.in_match:
		NetBus.reply(caller, "server_message", "对局已开始")
		return
	if tr.players.size() >= TEAM_ROLES:
		NetBus.reply(caller, "server_message", "房间已满(6 人)")
		return
	if not tr.is_public and invite.strip_edges() != tr.invite_code:
		NetBus.reply(caller, "server_message", "邀请码错误")
		return
	# role = 最小空闲号(与 royale 同款:**不重排**,有人退会留空洞 → 队伍表必须显式下发)
	var role := 1
	while tr.player_role.values().has(role):
		role += 1
	tr.players.append(caller)
	tr.player_role[caller] = role
	# ★ 进房**不自动分队**:3v3 的规则是玩家自己选边(用户裁定)。未选边 = team_of 里没有该 role,
	#   等待室会把他列在"未选边"那一档。
	print("3v3 房 %s 加入(peer=%d,role=%d,%d/%d)" % [code, caller, role, tr.players.size(), TEAM_ROLES])
	_broadcast_team_state(tr)


# 选边。该队满 3 人 → 拒绝(回 server_message);已在别的队 → 改投(留空出的位置)。
func team_pick(caller: int, team: int) -> void:
	var tr := team_room_of(caller)
	if tr == null or tr.in_match:
		return
	if team != 1 and team != 2:
		return
	var role := int(tr.player_role.get(caller, 0))
	if role == 0:
		return
	var by_team := _by_team(tr)
	if not team_can_join(by_team, team):
		NetBus.reply(caller, "server_message", "该队已满 3 人")
		return
	tr.team_of[role] = team
	_broadcast_team_state(tr)


func team_leave(caller: int) -> void:
	var tr := team_room_of(caller)
	if tr == null:
		return
	tr.players.erase(caller)
	tr.player_role.erase(caller)
	# 把该 peer 的 role 从队伍表里摘掉(role 号会被下一个加入者复用)
	for r in tr.team_of.keys():
		if not tr.player_role.values().has(int(r)):
			tr.team_of.erase(r)
	if tr.players.is_empty():
		# ★ 「退出房间」按钮**不断开大厅 peer** → on_peer_left 不会为它触发;房间随即摘除,
		#   而 sweep / on_peer_left 只遍历注册表 → 之后再无路径归还端口(与 royale_leave 同款坑)。
		teardown_room(tr)
	else:
		if tr.host_peer == caller:
			tr.host_peer = tr.players[0]
		if not tr.in_match:
			_broadcast_team_state(tr)


func team_list(caller: int) -> void:
	var arr: Array = []
	for c in team_rooms:
		var tr: TeamRoom = team_rooms[c]
		if tr.in_match or not tr.is_public or tr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in tr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": c, "players": tr.players.size(),
				"max_players": TEAM_ROLES, "names": names})
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "team_rooms", arr)


# 房间状态广播(等待室/选边)。与 royale 那两条同款:call_deferred + 帧末再等一帧 + 开局后不再发。
func _broadcast_team_state(tr: TeamRoom) -> void:
	_flush_team_state.call_deferred(tr)


func _flush_team_state(tr: TeamRoom) -> void:
	await get_tree().process_frame
	if tr.in_match:
		return
	var plist: Array = []
	for peer_id in tr.players:
		var role := int(tr.player_role[peer_id])
		plist.append({"role": role, "name": _peer_names.get(peer_id, "玩家"),
				"team": _team_of(tr, role)})
	var state := {
		"code": tr.code, "is_public": tr.is_public, "invite_code": tr.invite_code,
		"host_role": tr.player_role.get(tr.host_peer, 0), "team_size": TEAM_SIZE,
		"players": plist, "in_match": tr.in_match,
	}
	for peer_id in tr.players:
		if is_peer_online(peer_id):
			var mine := state.duplicate()
			mine["your_role"] = tr.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "team_room_state", mine)
```

- [ ] **Step 5: `teardown_room` 三态化**

```gdscript
func teardown_room(room, mode: int = TEARDOWN_DELAYED, msg: String = "",
		disconnect_peers: bool = false) -> void:
	# ★ 三态(2026-09-18):原先是 `is_royale` 二分,3v3 是第三个模式 → 端口延迟各一档。
	var is_royale: bool = room is RoyaleRoom
	var is_team: bool = room is TeamRoom
	var port: int = room.worker_port
	var peers: Array = room.players.duplicate()
	if port > 0:
		match mode:
			TEARDOWN_KILL:
				launcher.kill_worker(port)
				launcher.release_now(port)
			TEARDOWN_ABORT:
				launcher.release_now(port)
			_:
				var delay := WorkerLauncher.WORKER_PORT_REUSE_DELAY
				if is_royale:
					delay = WorkerLauncher.ROYALE_PORT_REUSE_DELAY
				elif is_team:
					delay = WorkerLauncher.TEAM_PORT_REUSE_DELAY
				_release_port_later(port, delay)
	if not msg.is_empty():
		for peer_id in peers:
			if is_peer_online(peer_id):
				NetBus.reply(peer_id, "server_message", msg)
	if is_royale:
		royale_rooms.erase(room.code)
	elif is_team:
		team_rooms.erase(room.code)
	else:
		rooms.erase(room.code)
	var how := "将于延迟后回收"
	if mode == TEARDOWN_KILL:
		how = "已强杀并立即回收"
	elif mode == TEARDOWN_ABORT:
		how = "立即归还(worker 未起来)"
	var kind := "大乱斗房" if is_royale else ("3v3 房" if is_team else "房间")
	print("%s %s 拆除(端口 %d %s)" % [kind, room.code, port, how])
	if disconnect_peers:
		for peer_id in peers:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)
```

★ **同时要改的两处**:① `_enter_tree` / `_exit_tree` 里 connect/disconnect 五条 `team_*` 信号;② **反向互斥** —— `create_room`（1v1）与 `royale_create` 的守卫里各加一条 `_in_team_room(caller)`。

- [ ] **Step 6: 让用户跑冒烟**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/team_room_smoke.gd`
Expected: `TEAM ROOM SMOKE: ALL-OK`

- [ ] **Step 7: 提交**

```bash
git add server/lobby_rooms.gd tests/team_room_smoke.gd
git commit -m 'feat(team): LobbyRooms 的 3v3 房间(建房/加入/选边/离开/列表)+ 拆除三态化'
```

---

## Task 4: `RoomManager.team_start` 与 sweep 分支

**Files:**
- Modify: `server/room_manager.gd`

**Interfaces:**
- Consumes: `lobby.team_room_of` / `lobby.team_room_ready`（Task 3）、`WorkerLauncher.spawn_team_worker`（A 册）
- Produces: `RoomManager.team_start(caller: int) -> void`

- [ ] **Step 1: 接信号 + 写 `team_start`**

`_ready` 里加 `NetBusExt.team_start_requested.connect(team_start)`，`_exit_tree` 里对应 disconnect。然后：

```gdscript
# 房主开局(**两队各 3 人**才允许)→ 拉起 --team worker → 全员 go_match 转连。
# ★ 与 royale_start 的三处实质差异:
#   ① 满员判据是"两队各 3 人"(不是"人数 ≥2")—— 4v2 人数也够 6,但那不是 3v3;
#   ② 命令行多一个 `--teams`(与 `--roles` **同序等长**),它才是队伍归属的唯一来源;
#   ③ 没有 AI 补位(用户裁定:满 6 人才开)。
func team_start(caller: int) -> void:
	var tr := lobby.team_room_of(caller)
	if tr == null:
		return
	if tr.host_peer != caller:
		NetBus.reply(caller, "server_message", "只有房主能开始游戏")
		return
	if tr.in_match:
		return
	if not lobby.team_room_ready(tr):
		NetBus.reply(caller, "server_message", "两队各 3 人才能开始")
		return
	var port := _launcher.pick_port()
	if port < 0:
		NetBus.reply(caller, "server_message", "无法分配对局端口")
		return
	tr.worker_port = port
	tr.in_match = true
	# ★ token 必须在 **go_match 之前**发(go_match 一到客户端就 NetBus.stop() 断大厅;晚发静默丢失)
	for pid in tr.players:
		var tk := LobbyRooms.new_token()
		tr.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
	# ★ roles 与 teams **同序**:roles 按号升序取,teams 跟着同一个顺序取队号
	var roles: Array = tr.player_role.values()
	roles.sort()
	var teams: Array = []
	for r in roles:
		teams.append(int(tr.team_of.get(int(r), 0)))
	if not _launcher.spawn_team_worker(port, roles, teams):
		tr.in_match = false
		lobby.teardown_room(tr, LobbyRooms.TEARDOWN_ABORT, "无法启动对局")
		return
	print("3v3 房 %s 开局(roles %s / teams %s)→ worker 端口 %d" % [tr.code,
			str(roles), str(teams), port])
	await get_tree().create_timer(0.3).timeout
	_send_go_match.call_deferred(tr, port)
```

★ **现场确认**：`_send_go_match(room, port)` 若带 `RoyaleRoom` 类型标注，把它放宽成无类型（它只读 `player_role` / `players` 两个字段，`TeamRoom` 同名同义）；**不要**复制第二份。

- [ ] **Step 2: `_sweep_stale_rooms` 加 team 分支**

```gdscript
	var stale_team: Array = []
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		# 在局中的 3v3 房宽限与 royale 同款(SWEEP_INTERVAL + 一局时长)。一局比大乱斗长(三局两胜),
		# 故这里取 TeamHost 侧的上界估计:3 局 × (COUNTDOWN 3 + 打到 9 杀 + ROUND_OVER 4)。
		# ★ 已知边界照实登记:这是**估**值不是实测值;与 royale 那条同根因(正确的界要读本局实际时长)。
		var grace := (SWEEP_INTERVAL + TEAM_MATCH_ESTIMATE) if tr.in_match else 0.0
		if now - tr.created_at > MAX_ROOM_AGE + grace:
			stale_team.append(tr)
```

（`const TEAM_MATCH_ESTIMATE := 1800.0` 放 `room_manager.gd` 顶部，并在注释里写明它是**估**值。）

并把 `stale_team` 并入清扫列表与那条汇总 print。

- [ ] **Step 3: `--import` + 启动自检**

Run: `"$GODOT" --headless --path . --import`
Run: `timeout 120 "$GODOT" --headless --path . --quit-after 90`
Expected: 无 ERROR。

- [ ] **Step 4: 提交**

```bash
git add server/room_manager.gd
git commit -m 'feat(team): RoomManager.team_start(两队各 3 人才开)+ sweep 的 3v3 分支'
```

---

## Task 5: 3v3 大厅页 + 主菜单入口

**Files:**
- Create: `scenes/team_lobby.tscn`（8 行的空壳，同 `royale_lobby.tscn`）+ `scenes/team_lobby.gd`
- Modify: `scenes/main_menu.gd`

**Interfaces:**
- Consumes: `LobbyPage` 的 8 个必需钩子 + 5 个可选钩子（见基类文件头）
- Produces: `scenes/team_lobby.tscn`（可被 `main_menu` 切进来）

- [ ] **Step 1: 写 `scenes/team_lobby.tscn`（照 `scenes/royale_lobby.tscn` 逐字复制，只改节点名）**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scenes/team_lobby.gd" id="1"]

[node name="TeamLobby" type="Control"]
script = ExtResource("1")
```

- [ ] **Step 2: 写 `scenes/team_lobby.gd`**

版式**照 `scenes/royale_lobby.gd` 复制后改**（左列：昵称/地址/提示/列表/房间号+邀请码/加入/状态/返回；右列：建房面板）。**必须改的**：

1. 类头注释（说清它是第三个大厅页、协议走 `team_*`、开局复用 `go_match`）。
2. 信号接线：`NetBusExt.local_team_rooms` / `NetBusExt.local_team_room_state`（对应 `_on_team_rooms` / `_on_room_state`）。
3. 建房面板：**去掉**人数上限滑块（固定 6）与一局限时滑块，换成一行说明 `"6 人房(每队 3 人);进房后自己选边 —— 房主点开始"`。
4. 八个必需钩子：

```gdscript
func _lobby_fallback_addr() -> String:
	return "127.0.0.1"   # 3v3 与大乱斗同:自建服才有本协议

func _send_list_request() -> void:
	NetBusExt.rpc_id(1, "team_list")

func _player_options() -> Dictionary:
	# 3v3 首版不上发房主规则项(禁武器/回合回血都走默认);视觉项沿用 Settings(pvp_*)
	return {}

func _go_match_status() -> String:
	return "已配对,正在进入 3v3 对局…"

func _on_worker_connect_failed() -> void:
	_return_to_lobby("连接对局服务器失败,已返回大厅")

func _worker_timeout_msg() -> String:
	return "连接对局服务器超时(端口需放行 UDP)——已返回大厅"

func _claim_timeout_msg() -> String:
	return "等待开局超时(可能有人掉线)——已返回大厅"

func _enter_match_scene() -> void:
	# ★ 必须 call_deferred:worker 的 match_start 在 NetBus.poll 调用栈内到达,栈内切场景会在
	#   这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(与大乱斗那条同因,1v1 是直切)。
	get_tree().call_deferred("change_scene_to_file", "res://scenes/team_game.tscn")
```

5. 超时梯顺序**照大乱斗**（`[worker→claim→大厅→ack]`）—— 1v1 是 `[worker→join→大厅→claim]`，两者不同，**不能合并**。

- [ ] **Step 3: 选边等待室（本页的核心差异）**

```gdscript
# 等待室:两队名单 + 未选边档 + 选边按钮 + 房主开局按钮。
# ★ 编号印**行序**而不是 role(role 是最小空闲号分配、有人退会留空洞 —— 与 royale 页同一坑)。
func _on_room_state(state: Dictionary) -> void:
	_in_room = true
	_my_room = state
	var my_role := int(state.get("your_role", 0))
	_host = int(state.get("host_role", 0)) == my_role
	if _create_panel != null:
		_create_panel.visible = false
	if _wait_panel == null:
		_build_wait_panel()
	_wait_panel.visible = true
	var code := str(state.get("code", ""))
	var invite := str(state.get("invite_code", "")) if not bool(state.get("is_public", true)) else ""
	_wait_title.text = "—— 3v3 房间 %s ——%s" % [code, "  邀请码 %s" % invite if invite != "" else ""]
	for c in _wait_players.get_children():
		c.queue_free()
	var plist: Array = state.get("players", [])
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", 3))
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		var head := "%s(%d/%d)" % [tag, (buckets[t] as Array).size(), team_size]
		_wait_players.add_child(UiFactory.label("—— %s ——" % head, 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			_wait_players.add_child(UiFactory.label(_row_text(p, my_role, state), 32,
					UiFactory.C_TEXT if int(p.get("role", 0)) != my_role else UiFactory.C_ACCENT))
	if not (buckets[0] as Array).is_empty():
		_wait_players.add_child(UiFactory.label("—— 未选边 ——", 32, UiFactory.C_TEXT_DIM))
		for p in buckets[0]:
			_wait_players.add_child(UiFactory.label(_row_text(p, my_role, state), 32, UiFactory.C_TEXT))
	var mine := int(state.get("your_role", 0))
	_pick_a.visible = _team_of_role(state, mine) != 1
	_pick_b.visible = _team_of_role(state, mine) != 2
	_wait_count.text = "%d / 6 人(已选边 %d 人;两队各 3 人才可开局)" % [
			plist.size(), (buckets[1] as Array).size() + (buckets[2] as Array).size()]
	_start_btn.visible = _host and _both_ready(buckets, team_size)


func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


func _both_ready(buckets: Dictionary, size: int) -> bool:
	return (buckets[1] as Array).size() == size and (buckets[2] as Array).size() == size


func _row_text(p: Dictionary, my_role: int, state: Dictionary) -> String:
	var role := int(p.get("role", 0))
	return "%s%s%s" % [p.get("name", "玩家"), "(我)" if role == my_role else "",
			"(房主)" if role == int(state.get("host_role", 0)) else ""]
```

`_build_wait_panel()` 里加两个选边按钮（照现有 `_start_btn` 的工厂写法）：

```gdscript
	_pick_a = UiFactory.button("加入 A 队", 32, Vector2(170, 48))
	_pick_a.pressed.connect(func() -> void: NetBusExt.rpc_id(1, "team_pick", 1))
	vb.add_child(_pick_a)
	_pick_b = UiFactory.button("加入 B 队", 32, Vector2(170, 48))
	_pick_b.pressed.connect(func() -> void: NetBusExt.rpc_id(1, "team_pick", 2))
	vb.add_child(_pick_b)
```

`_start_btn` 的回调发 `NetBusExt.rpc_id(1, "team_start")`；「退出房间」发 `team_leave`（**不断开大厅 peer**，与大乱斗同款）。

- [ ] **Step 4: 主菜单入口**

`scenes/main_menu.gd` 的 `_build_menu_buttons()` 里，在大乱斗按钮之后加：

```gdscript
	var team_btn := UiFactory.button("3 v 3 团 队", 32)
	team_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()
		get_tree().change_scene_to_file("res://scenes/team_lobby.tscn"))
```

放进 `play_group`（`for b in [start_btn, multi_btn, royale_btn, team_btn]`），返回值数组也跟着加。
并把 `scenes/main_menu.gd` 里 `menu_autotest` 的 `must_reach` 表加一行 `team` → `res://scenes/team_lobby.tscn`（**现场确认**该表的确切键名与结构，`tests/menu_autotest.gd:72-77`）。

- [ ] **Step 5: `--import` + 取图（可选但推荐）**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**，要窗口）：`"$GODOT" --path . -- --autotest-team`（若 `menu_autotest` 的表已加）
Expected: `user://autotest_team.png`，人眼确认版式没崩。**这一份是"最小可用"，版式定稿归 UI 重做那份。**

- [ ] **Step 6: 提交**

```bash
git add scenes/team_lobby.tscn scenes/team_lobby.gd scenes/main_menu.gd
git commit -m 'feat(team): 3v3 大厅页(建房/列表/选边等待室)+ 主菜单入口'
```

---

## Task 6: 客户端对局场景 `team_game`

**Files:**
- Create: `scenes/team_game.tscn` + `scenes/team_game.gd`
- Modify: `ui/ui_factory.gd`（两个队色 token）

**Interfaces:**
- Consumes: `PvpMatchClient`（基类）、`NetBus.local_match_sync` 的 `teams` 字段（A 册）、`TeamHud`（Task 7）
- Produces: `TeamGame` 场景；`UiFactory.C_TEAM_A` / `UiFactory.C_TEAM_B`

- [ ] **Step 1: 在 `ui/ui_factory.gd` 加两个队色 token**

```gdscript
# ── 队伍色(3v3)──
# ★ 这是**占位值**:联机 UI/排版重做那份会给它们定稿(设计 §5 "队色具体色值归第二份")。
#   之所以现在就要有:3v3 下"一眼看出谁是队友"是**能玩**的必要条件,不是审美。
#   两条纪律不变:① 只在本文件定义颜色;② 与底板对比 ≥3:1(底板 = HUD 那块黑 0.1 压在地图浅灰蓝上)。
const C_TEAM_A := Color(0.45, 0.85, 1.0)    # 队 A:偏青
const C_TEAM_B := Color(1.0, 0.62, 0.45)    # 队 B:偏橙
```

- [ ] **Step 2: 写 `scenes/team_game.tscn`**

照 `scenes/royale_game.tscn` 的结构（Level0 由脚本实例化，场景本身只有根节点）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scenes/team_game.gd" id="1"]

[node name="TeamGame" type="Node2D"]
script = ExtResource("1")
```

- [ ] **Step 3: 写 `scenes/team_game.gd`（照 `royale_game.gd` 复制后改这几处）**

**保留不动**（逐字）：`_ready` 的建世界/本地玩家/C2 绑定/`_rollback.map_px`/后处理/信号接线清单/`_ensure_replica` / `_remove_replica` / `_on_snapshot_world` / `_on_hit_event` / `_on_beam_fired` / `_process` 的贴位 / `_replica_for` / `_unhandled_input` 的 K 自杀。

**必须改的四处**：

① 类头注释 + HUD 类型：`_hud: TeamHud`，实例化 `res://ui/team_hud.tscn`。

② **队伍表从 `match_sync` 进来**：

```gdscript
var _teams: Dictionary = {}   # role(int) -> 队号(1/2);由 match_sync 下发(★ 不得从 roles 推导)

# 应用函数(不是信号回调):唯一入口 = _on_match_sync(与大乱斗那三个载荷同款纪律)
func _apply_teams(teams: Dictionary) -> void:
	_teams = teams
	_refresh_team_colors()


func _team_of_role(role: int) -> int:
	return int(_teams.get(role, 0))


# 队色统一收在这里:自己的染色、副本染色、头顶 ID 都问它。
# ★ 3v3 下**个人色相不生效**(`peer_hues` 被队色覆盖)—— 这是规则不是审美:
#   6 个人里认不出队友,这个模式就没法玩。`_on_match_sync` 里**不要**再调 `_apply_peer_hues`。
func _team_color(role: int) -> Color:
	match _team_of_role(role):
		1:
			return UiFactory.C_TEAM_A
		2:
			return UiFactory.C_TEAM_B
	return Color(0.94, 0.95, 0.98, 1.0)   # 无队伍(理论上到不了)→ 中性亮白


func _refresh_team_colors() -> void:
	if _local != null:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), Settings.pvp_color_hue)  # 自己仍是自选色
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"), 0.0,
					_team_color(role))
	_refresh_names()
```

★ `_apply_tint(sprite, hue, override_color)` 的**第三参是新增的**：把 `royale_game._apply_tint` 抄过来时加一个可选的 `color_override`（默认 `Color(0,0,0,0)` = 不覆盖），非透明时走"直接设 `modulate`"而不是色相 shader。**这一处是新写的，不是复制**；若发现 `player.tscn` 的身体是 `AnimatedSprite2D` + shader 结构（`_apply_tint` 的现有实现），最省的做法是复用 `ui_factory.hue_preview_color()` 把队色**反解**成色相再走同一条 shader —— **实施时二选一，并在注释里写清选哪条与为什么**。

③ `_refresh_names()` 按**队色**上色（大乱斗是按 role 的 8 色板）：

```gdscript
func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		# 3v3:头顶名按**队色**(大乱斗那份是按 role 的 8 色板)
		(_id_labels[role] as Node2D).set_label(nm, _team_color(role))
```

④ `_on_match_sync`：**换成**消费 `teams`（基类那份会调 `_apply_peer_hues`，3v3 不要）：

```gdscript
func _on_match_sync(payload: Dictionary) -> void:
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	# ★ 刻意**不调** `_apply_peer_hues`:3v3 下队色覆盖个人色相(见 `_team_color` 的注释)
	var teams: Dictionary = payload.get("teams", {})
	if not teams.is_empty():
		_apply_teams(teams)
	_sync_spawn_and_payloads(payload)   # 出生点校正 + 地面武器先清后灌 + destroyed 补态(基类逻辑)
```

★ **实施注意**：基类 `_on_match_sync` 已经把"名字/色相/选项/出生点/地面武器/destroyed"六件事写在一起了。3v3 要的差异只有"色相那一段不要、多一段 teams"。**推荐做法**：在基类加一个可覆写的钩子 `_apply_peer_hues_or_team(hues)`（默认调 `_apply_peer_hues`，3v3 覆写成 `_apply_teams`），而不是把整段抄一遍 —— 抄一遍就等于把"先清后灌""静默补态"那两条纪律复制成两份，将来只改一处。**这条改动要连 1v1/大乱斗两个客户端一起验**（它们的探针全绿）。

- [ ] **Step 4: 提交**

```bash
git add scenes/team_game.tscn scenes/team_game.gd ui/ui_factory.gd scenes/pvp_match_client.gd
git commit -m 'feat(team): 客户端对局场景 team_game(5 副本 + 队色覆盖个人色相)'
```

---

## Task 7: `TeamHud` + 小地图分队上色

**Files:**
- Create: `ui/team_hud.tscn`（照 `ui/pvp_hud.tscn` 复制，只改脚本引用与初始文案）+ `ui/team_hud.gd`
- Modify: `ui/minimap.gd`（`setup_multi` 加**可选**颜色提供器）
- Modify: `tests/hud_declarative_probe.gd`（`PAIRS` 加一行）

**Interfaces:**
- Consumes: `NetBus.local_round_state`（A 册：`scores` / `rounds_won` 的键 = **队号**，`winner` / `match_winner` 也是队号）
- Produces: `TeamHud`；`Minimap.setup_multi(local, others, colors := Callable())`

- [ ] **Step 1: 写 `ui/team_hud.gd`（照 `ui/pvp_hud.gd` 复制后改记分与播报）**

```gdscript
class_name TeamHud
extends CanvasLayer

# 3v3 对局 HUD(CanvasLayer layer=130,与 PvpHud/RoyaleHud 同层)。
# 布局逐字沿用 pvp_hud.tscn(遮罩/居中文案/记分条/延迟),**只改记分与播报的语义**:
#  - 记分条:scores/rounds_won 的键是**队号**,不是 role
#  - 播报:按"我方队伍"判胜负,不按 role
# ★ 本页是**最小可用**版式:联机 UI/排版重做那份会把它一起重做(设计 §11)。

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _mask: ColorRect = $Mask
@onready var _center: CenterContainer = $Center
@onready var _big: Label = $Center/VBox/BigLabel
@onready var _sub: Label = $Center/VBox/SubLabel
@onready var _ping_label: Label = $PingWrap/PingLabel

var _countdown := 0.0
var _in_countdown := false
var _my_team := 0   # 由外部(match_sync 到达后)写入:team_game 调 set_my_team()


func set_my_team(t: int) -> void:
	_my_team = t


func _ready() -> void:
	PixelFont.shared()
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_set_broadcast(true, "对战开始", "第 1 局")


func _set_broadcast(show: bool, big: String, sub: String) -> void:
	_mask.visible = show
	_center.visible = show
	_big.text = big
	_sub.text = sub


func show_notice(big: String, sub: String = "") -> void:
	_in_countdown = false
	_set_broadcast(true, big, sub)


func _process(delta: float) -> void:
	if not _in_countdown:
		return
	_countdown -= delta
	if _countdown > 0.0:
		_big.text = str(maxi(ceili(_countdown), 1))
	else:
		_in_countdown = false


func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))


func _on_round_state(data: Dictionary) -> void:
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	# ★ 文案用"队"不用"P":键是队号(见 A 册 TeamHost._broadcast_round_state)
	_score_label.text = "A 队击杀 %d        B 队击杀 %d        局胜 %d - %d        第 %d 局" % [
			s1, s2, w1, w2, round]
	match state:
		ST_COUNTDOWN:
			_countdown = float(data.get("timer", 3.0))
			_in_countdown = true
			var sub := "对战开始" if round <= 1 else "第 %d 局" % round
			_set_broadcast(true, str(maxi(ceili(_countdown), 1)), sub)
		ST_PLAYING:
			_in_countdown = false
			_set_broadcast(false, "", "")
		ST_ROUND_OVER:
			_in_countdown = false
			var winner: int = int(data.get("winner", 0))
			if winner != 0:
				var mine := winner == _my_team
				_set_broadcast(true, "本局胜利!" if mine else "本局落败",
						("A 队" if winner == 1 else "B 队") + " 先到 9 杀")
			else:
				_set_broadcast(true, "本局结束", "局胜 %d - %d" % [w1, w2])
		ST_MATCH_OVER:
			_in_countdown = false
			var mwinner: int = int(data.get("match_winner", 0))
			if mwinner == _my_team and _my_team != 0:
				_set_broadcast(true, "胜利!", "你们赢下了整场对战")
			elif mwinner != 0:
				_set_broadcast(true, "失败", "再接再厉…")
			else:
				_set_broadcast(true, "对局结束", "返回菜单…")
```

★ `_sub` 那行里 `other` 变量没用到就删掉（避免未使用变量告警）。

- [ ] **Step 2: 写 `ui/team_hud.tscn`（照 `ui/pvp_hud.tscn` 复制）**

把 `ui/pvp_hud.tscn` **逐字复制**成 `ui/team_hud.tscn`，只改 `ext_resource` 的脚本路径 → `res://ui/team_hud.gd`，并把初始 `text` 改成 3v3 的文案（`ScoreLabel` 初始空、`BigLabel` 空、`SubLabel` 空即可）。**布局一个字不动**（这一份的版式沿用 1v1 那条顶部记分条，UI 重做那份再定）。

- [ ] **Step 3: `tests/hud_declarative_probe.gd` 的 `PAIRS` 加一行**

```gdscript
	["res://ui/team_hud.gd", "res://ui/team_hud.tscn"],
```

- [ ] **Step 4: 小地图加可选颜色提供器**

`ui/minimap.gd`：`setup_multi(local_provider, others_provider, color_provider := Callable())`，在敌人点绘制那段把 `ENEMY_COLOR` 换成"颜色提供器给了就用它"：

```gdscript
	if _others_provider.is_valid():
		var others: Array = _others_provider.call()
		var cols: Array = _color_provider.call() if _color_provider.is_valid() else []
		while _other_dots.size() < others.size():
			# 池子里的点建出来时先给默认色,颜色每帧可覆盖(队色会随 match_sync 到得晚一点)
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			if i < cols.size():
				(_other_dots[i] as ColorRect).color = cols[i]
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
```

`team_game._ready` 里传第三个参数。★ **两个提供器写成具名方法**，不要内联 lambda —— 三个内联 lambda 时中间那个要以 `return arr,` 结尾（逗号在 lambda 体内），那是本仓没写过的形状，容易踩语法/跨行歧义：

```gdscript
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"))
		add_child(minimap)


# 小地图的多目标位置(所有对手副本)—— 与大乱斗那条逐字相同
func _minimap_others() -> Array:
	var arr: Array = []
	for r in _replicas:
		if is_instance_valid(_replicas[r]):
			arr.append((_replicas[r] as Node2D).global_position)
	return arr


# 小地图的多目标**颜色**(3v3 独有):与 _minimap_others 的**同序**一一对应 —— 顺序错位会
# 让队友点画成敌人色,而小地图上错了**不报错**、只误导人。
func _minimap_colors() -> Array:
	var cols: Array = []
	for r in _replicas:
		cols.append(_team_color(int(r)))
	return cols
```

★ **1v1 与大乱斗不传第三个参数 → 行为逐字不变**（默认 `Callable()` = 不回填颜色）。

- [ ] **Step 5: `--import` + 让用户跑布局探针 + 取图**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn`
Expected: `ALL-OK`
Run（**让用户跑**，要窗口）：`"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn`
Expected: 现有那 4 张图不变（本任务没动 PvpHud/RoyaleHud）

- [ ] **Step 6: 提交**

```bash
git add ui/team_hud.gd ui/team_hud.tscn ui/minimap.gd scenes/team_game.gd tests/hud_declarative_probe.gd
git commit -m 'feat(team): TeamHud(记分按队)+ 小地图可选队色(1v1/大乱斗不传参数,行为不变)'
```

---

## Task 8: 6 人真链路探针

**Files:**
- Create: `tests/team_match_probe.tscn` + `tests/team_match_probe.gd` + `tests/team_match_probe.sh`

**Interfaces:**
- Consumes: A 册的 worker + B 册的大厅/客户端
- Produces: 判据文本 `TEAM MATCH PROBE: ALL-OK`

★ **本任务是全册唯一一个"骨架复制 + 逐相编写"的任务**：探针骨架（自当大厅 + 拉起 N 个 headless 客户端 + observer 日志 + 收尾按 PID 杀）有 400+ 行，把它抄进计划反而会与真实骨架漂移。**实施者必须先完整读这三个文件**再动手：
- `tests/royale_c2_probe.tscn`（六相真链路 + C2 收敛判据 + `--log-file` 与 observer 的用法）
- `tests/royale_soak_probe.tscn`（N 个客户端的拉起、脚本机器人、ESC 离场）
- `tests/reconnect_probe.gd`（**端口必须落在真大厅的 worker 池之外**、收尾**按 PID 杀**客户端）

- [ ] **Step 1: 按骨架复制出 `tests/team_match_probe.gd/.tscn`，写下面五相**

```
相① 六人开局:拉起真大厅(池外端口) → 6 个 headless 客户端各跑真 team_lobby → 建房 → 依次加入
     → **各自选边(3 个 A、3 个 B)** → 房主 team_start → 6 端都进 team_game。
     断言:6 端都进了 team_game;每端拿到的 match_sync.teams 与大厅下发的一致(逐端比对);
     每端本地玩家位置 == 服务器快照位置(允许插值误差)。
相② 按队散点:开局那一刻,6 端的出生点两两分组 —— **队内最大距离 < 队间最小距离**
     (与 A 册 team_host_probe 的同一条判据,这里在真链路上再验一次)。
相③ 子弹穿透队友 + 爆炸满效:让甲(队 A)朝队友乙(队 A)开一枪 → 乙 hp 不变;
     再让甲朝乙扔一颗榴弹(贴脸)→ 乙 hp **下降**且被推飞。★ 这一对正反断言缺一不可:
     只验"穿透"会让"伤害系统整个坏了"也全绿。
相④ 打满一局:脚本机器人互射到 9 杀 → ROUND_OVER → 下一局开局后 `_round_spawns` 已对调
     (换边:A 队的人站到上一局 B 队的点上)。断言各端 HUD 收到的 `scores` 键是 1/2、`rounds_won` 同步。
相⑤ 少人继续:让 6 号客户端在 PLAYING 中途**按 ESC 离场**(唯一走 safe_change_scene 的局内退出路径)
     → 断言:服务器**不**终局(该队少人继续)、其余 5 端仍持续收到快照(间隔 < 1s)、
     且排行榜里 6 号标"离开"。
```

- [ ] **Step 2: `--import` 后按"用户跑"的形态交付**

写 `tests/team_match_probe.sh`（照 `tests/royale_soak_probe.sh` 的形状：`taskkill` 按 PID + `kill_port` 兜底），并在文件头写明**跑前先确认没有别的 godot 占着 7777**（探针用池外端口，但别杀用户自己的服务端）。

- [ ] **Step 3: 让用户跑**

Run（**让用户跑**）：`timeout 1800 bash tests/team_match_probe.sh`
Expected: `TEAM MATCH PROBE: ALL-OK`
★ 失败时先看**客户端各自的 `--log-file`**（父进程看不到子进程 stdout）—— 这是本仓既有的排查纪律。

- [ ] **Step 4: 反向验证（至少做一条）**

把 A 册 `_match_round_tick` 里 `_enemy_team_of` 换成基类的 `_opponent_of`（= 回到"非我即敌"）→ 重跑 → 期望相④ 的比分断言**变红**（两队分数会在同一人倒地时都涨/乱）。写进报告后换回。

- [ ] **Step 5: 提交**

```bash
git add tests/team_match_probe.gd tests/team_match_probe.gd.uid tests/team_match_probe.tscn \
  tests/team_match_probe.sh
git commit -m 'test(team): 6 人真链路端到端探针(五相:开局/散点/友伤/换边/少人继续)'
```

---

## Task 9: `CLAUDE.md` 与收尾

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 补进「网络与 PvP」一节**

在 A 册新增的 3v3 小节里继续写 B 册这四条：

1. **三套大厅协议并存且互斥**：`rooms`（1v1）/ `royale_rooms` / `team_rooms` 三张注册表；互斥判定**必须双向**（新入口查旧的、旧入口也查新的），只加一头就能"从 1v1 房直接开 3v3 房"。
2. **`teardown_room` 是三态**（原先是 `is_royale` 二分）：端口延迟各一档（120 / 360 / `TEAM_PORT_REUSE_DELAY` 360）。
3. **队色覆盖个人色相**是 3v3 的**规则**（不是审美）：`team_game._on_match_sync` 刻意不调 `_apply_peer_hues`；改这一条前先想"六个人认不出队友"。
4. **3v3 满 6 人才开、没有降级开局**：`server_main` 的 3v3 超时梯是"退出释放端口"，与 `--royale` 那条"20s 按已到人数开局"**方向相反**，别顺手统一。

- [ ] **Step 2: 更新测试清单那一节**

在"测试"一节里加：`tests/team_room_smoke.gd`（`-s`，3v3 房间纯逻辑）、`tests/team_host_probe.tscn`（A 册）、`tests/team_table_probe.tscn`（A 册）、`tests/team_disconnect_probe.tscn`（A 册）、`tests/team_match_probe.tscn`（6 人真链路，**跑前确认 7777 空闲**）。

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录 3v3 B 册(三协议互斥/拆除三态/队色覆盖色相/满 6 人才开)'
```

---

## 自检记录

**spec 覆盖**：§4.5 三态化（Task 3 的 `teardown_room` + Task 4 的 sweep；端口延迟常量在 A 册）→ ✓；§5 客户端（Task 6/7：5 副本、队色、最小 HUD、小地图参数）→ ✓；§3 规则 2/3 的进房与选边（Task 3 的 handler + Task 5 的等待室）→ ✓；§10 的"6 人真链路压测"（Task 8）→ ✓；§11 的契约（`match_sync.teams` 的**消费**在 Task 6；其余五项是给 UI 那份的输入）→ ✓。

**本册不做（明写）**：联机 UI 的版式/配色/字号定稿（`TeamHud` 与 `team_lobby` 都是"最小可用"，版式归 UI 重做那份）；2v2/4v4；观战；`match_sync` 带破坏态（属重连阶段 2-B）。

**风险与现场确认项**：
1. Task 6 Step 3-④ 的**基类钩子**（`_apply_peer_hues_or_team`）是唯一动到 `scenes/pvp_match_client.gd` 的地方 —— 必须连 1v1/大乱斗客户端一起验（它们的探针是回归线）。
2. Task 6 Step 3-② 的队色**着色方式**（modulate 直改 vs 反解色相走 shader）二选一，实施时看 `player.tscn` 的真实结构定，并写进注释。
3. Task 7 的 `team_hud.tscn` 是 `pvp_hud.tscn` 的复制 —— **别把 `draw_center=false` 那条击杀计数器纪律带过来**（3v3 的记分条是 `ScoreWrap` PanelContainer，与 `kill_counter.tscn` 无关）。
