# 联机大厅合一（① 结构与服务端）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 1v1 / 3v3 / 大乱斗三个大厅页合成一个 `mp_lobby`，服务端三套注册表原样保留、只对列表载荷加法式扩键；主菜单的联机入口收成一颗。

**Architecture:** 复用现有 `LobbyPage` 基类（连接状态机 / 转连 worker / 回局路径 / 超时梯全在它里面），新页只写版式与三模式分派。列表**不新增统一 RPC** —— 一页并发调三次现有列房 RPC，前端合并打标。凭据模型从「从哪个菜单按钮进来」改成「凭据自带模式」。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、ENet（`NetBus` / `NetBusExt` autoload）。

**上游设计文档：** `docs/superpowers/specs/2026-10-03-mp-lobby-unification-design.md`（下称「设计」）。本计划只覆盖设计 §8.1 的**第 1~3 段**；设置页/信息页（第 4 段）与视觉重做（第 5 段）是另外两份计划。

## Global Constraints

- **不动 `NetBus` 的方法表**：`create_room` / `join_room` / `list_rooms` / `go_match` / `claim_role` 的签名一律不改。新增 RPC 只进 `NetBusExt`。
- **字号必须是 16 的倍数**（16 / 32 / 48）。布局度量（separation / custom_minimum_size）**不受**此限。
- **颜色只在 `ui/factory/ui_factory.gd` 定义**；面板底必须不透明。
- **测试由用户自己跑**。本计划里的命令是给用户/执行者照抄的，不要代跑占 7777 的脚本。
- Godot 路径走环境变量 `"$GODOT"`（console 版）；未设时回落 `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`。
- 场景探针一律 `--quit-after 3600`（帧，不是秒）—— 它是安全网，只在探针挂住时才用得上。
- **判据是文本**（`ALL-OK` 之类），**不看退出码**。
- 新建 `.gd` **要连 `.gd.uid` 一起 `git add`**；新建 `.tscn` **不用**（本仓不跟踪 `.tscn.uid`）。
- ★★ **`.uid` 是引擎在导入时生成的**：新建 `.gd` 之后、`git add` 之前，**必须**先跑一次
  `"$GODOT" --headless --path . --import`，否则 `<file>.gd.uid` **根本不存在**，
  `git add` 会直接报 `pathspec did not match`。每个新建 `.gd` 的任务在提交前都要走这一步
  （Task 1 / 3 / 4 / 5 各有一次）。
- 每个新增/改动的 `-s` 冒烟脚本必须写空载守卫（`load()` 之后判 null 就 `print` + `quit(1)` + `return`），否则脚本一报错进程**永久挂起**。
- **本计划只覆盖设计 §8.1 的第 1~3 段**：设置页/信息页是计划 ②，视觉重做是计划 ③。本计划一律用 `UiFactory` 的**既有** token，不新增颜色 —— 新增 token 是计划 ③ 的事。
- **UI 构造类步骤的详略口径**：凡"写错了不报错"的地方（服务端键名、房主校验、`can_rejoin_to` 的判据、卡片的可点性两半、守卫改点）给**完整代码**；纯布局排布给**度量表 + 函数签名**，按设计 §3.2 执行，不逐行抄。引用外部 API（`MapCatalog` / `MapPicker` / `LocalServer`）时**以调用处为准** —— 本计划里凡引用它们的地方都已核过签名，但实现时若发现不符，改计划而不是改调用约定。

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `server/lobby/lobby_rooms.gd` | 改 | 三个房类各加 `map` / `match_time`；三个 `*_list_payload()` 扩键；新增 `on_room_map` + 两个私有助手 |
| `core/net/net_bus_ext.gd` | 改 | 新增 `room_map` 上行 RPC + `room_map_requested` 信号 |
| `server/lobby/room_manager.gd` | 改 | 把 `room_map_requested` 接到 `lobby.on_room_map` |
| `core/net/pvp_session.gd` | 改 | `room_mode` 取代 `mode`；`note_room(code, mode)` / `can_rejoin_to(code, mode)`；删 `enter_mode` |
| `scenes/mp_lobby.gd` / `.tscn` | 建 | 统一大厅页（**取代**三个旧页） |
| `scenes/lobby_page.gd` | 改 | 基类：`try_rejoin_row` 加 `mode` 形参 |
| `scenes/main_menu.gd` | 改 | 联机入口收成一颗「多 人 模 式」 |
| `scenes/beta_menu.gd` | 改 | 两张卡改指向 `mp_lobby` + 预选模式 |
| `scenes/matchmaking.*` / `royale_lobby.*` / `team_lobby.*` | 删 | 三个旧页退役 |
| `tests/probe/lobby_payload_probe.gd` / `.tscn` | 建 | 新守卫：载荷扩键 + `room_map` 房主校验 |
| `tests/probe/lobby_row_probe.gd` | 改 | 单页化（卡片可点性的两半） |
| `tests/probe/lobby_visibility_probe.gd` | 改 | 单页化 + 相⑦ 加「模式不同 ⇒ 不可点」 |
| `tests/smoke/lobby_parse_smoke.gd` | 改 | 目标场景换成 `mp_lobby.tscn` |
| `tests/smoke/reconnect_smoke.gd` | 改 | 页面常量合一 + 凭据模型断言重写 |
| `tests/smoke/room_sweep_smoke.gd` | 改 | 上界链环二改读 `mp_lobby.gd` |
| `tests/probe/kh_l5_probe.gd` | 改 | `L5_FONT_FILES` 换 `mp_lobby.gd` |
| `tests/smoke/menu_autotest.gd` | 改 | mp/royale/team 三模式指向同一场景 |
| `tests/harness/*.gd`（watcher） | 改 | 场景/脚本名替换 |

---

## Task 1: 服务端列表载荷扩键 + `room_map`

**Files:**
- Modify: `server/lobby/lobby_rooms.gd`（三个房类定义 + 三个 `*_list_payload()` + 新增两个函数）
- Modify: `core/net/net_bus_ext.gd`（`room_map` RPC）
- Modify: `server/lobby/room_manager.gd`（接线一行）
- Test: `tests/probe/lobby_payload_probe.gd` / `.tscn`（新建）

**Interfaces:**
- Produces:
  - `LobbyRooms.on_room_map(caller: int, code: String, path: String) -> void`
  - `LobbyRooms.room_list_payload() -> Array` 每条含 `code, players, names, in_match, is_public, host, map`
  - `LobbyRooms.royale_list_payload(token := "") -> Array` 另含 `max_players, beta, match_time`
  - `LobbyRooms.team_list_payload(token := "") -> Array` 另含 `max_players, beta, team_counts`
  - `NetBusExt.room_map(code: String, path: String) -> void`（`any_peer`）与信号 `room_map_requested(caller, code, path)`
  - 三个房类的字段 `var map := ""`；`RoyaleRoom` 另加 `var match_time := 0`

- [ ] **Step 1: 写失败的探针**

新建 `tests/probe/lobby_payload_probe.gd`：

```gdscript
extends Node

# 大厅**列表载荷形状**与 `room_map` 房主校验的服务端面探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
# 判据: 文本 `LOBBY PAYLOAD PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:房卡要吃 is_public / host / map / match_time / team_counts 五个键,
#   而"服务端给了但客户端没渲染"和"客户端渲染了但服务端没给"**都不报错** —— 只表现为
#   卡片上那一行空着。本探针钉服务端那一半。
# ★ 建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径);房记录由探针手工摆,
#   不需要 socket、不需要 worker(与 lobby_visibility_probe 同款)。
# ★ 断言计数:ALL-OK 只证明"没有一条断言失败",不证明"该跑的都跑过"(见 tests/lib/probe_base.gd
#   文件头)。少跑一条就红 —— 改本探针必须同步改这个数。
const EXPECTED_CHECKS := 20

const P_HOST := 201
const P_OTHER := 202

var _rm: Node = null
var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _find(arr: Array, code: String) -> Dictionary:
	for r in arr:
		if typeof(r) == TYPE_DICTIONARY and str(r.get("code", "")) == code:
			return r
	return {}


func _ready() -> void:
	_rm = RoomManager.new()
	add_child(_rm)
	_rm.set_process(false)   # 关掉回收梯:不关的话跑到 30s 它会收掉探针刚摆好的房
	var lobby = _rm.lobby

	# 昵称只有经 `_peer_names` 才有 —— 探针直接塞(生产里由 on_lobby_name 写)
	lobby._peer_names[P_HOST] = "房主甲"

	# ── 1v1 ──
	var r1: LobbyRooms.Room = LobbyRooms.Room.new()
	r1.code = "9101"
	# ★ 用 append 而不是 `= [P_HOST] as Array[int]`:后者不是合法的 GDScript 转型写法,
	#   `players` 是 `Array[int]`,赋值一个裸 Array 会在运行时被拒。
	r1.players.append(P_HOST)
	r1.player_role[P_HOST] = 1
	lobby.rooms["9101"] = r1
	var p1 := _find(lobby.room_list_payload(), "9101")
	_check(int(p1.get("players", -1)) == 1, "1v1 载荷 players 仍是人数")
	_check(p1.get("is_public", null) == true, "1v1 载荷 is_public 恒 true(1v1 没有私密房)")
	_check(str(p1.get("host", "")) == "房主甲", "1v1 载荷 host = 建房者昵称(实得「%s」)" % str(p1.get("host", "")))
	_check(p1.has("map") and str(p1["map"]) == "", "1v1 载荷带 map 键且初值为空串")

	# ── 大乱斗 ──
	var rr: LobbyRooms.RoyaleRoom = LobbyRooms.RoyaleRoom.new()
	rr.code = "9102"
	rr.host_peer = P_HOST
	rr.players.append(P_HOST)
	rr.player_role[P_HOST] = 1
	rr.max_players = 6
	rr.is_public = false
	rr.match_time = 300
	lobby.royale_rooms["9102"] = rr
	var pr := _find(lobby.royale_list_payload(""), "9102")
	_check(pr.is_empty(), "私密房对无凭据者不列出(既有语义没被破坏)")
	# ★ 签名是 grant(token, code, role, worker_port, worker_pid, now_ms) —— 六个参数。
	#   worker_pid 传 0 = "拉起中",与 `owns()` 无关(它只看 TTL,不看 worker 活性)。
	lobby.rejoin.grant("tk-probe", "9102", 1, 0, 0, Time.get_ticks_msec())
	var pr2 := _find(lobby.royale_list_payload("tk-probe"), "9102")
	_check(not pr2.is_empty(), "私密房对持凭据者列出")
	_check(pr2.get("is_public", null) == false, "大乱斗载荷 is_public 透出 false")
	_check(int(pr2.get("match_time", -1)) == 300, "大乱斗载荷 match_time 透出房间上的值")
	_check(str(pr2.get("host", "")) == "房主甲", "大乱斗载荷 host = host_peer 的昵称")

	# ── 3v3 ──
	var tr: LobbyRooms.TeamRoom = LobbyRooms.TeamRoom.new()
	tr.code = "9103"
	tr.host_peer = P_HOST
	tr.players.append(P_HOST)
	tr.players.append(P_OTHER)
	tr.player_role[P_HOST] = 1
	tr.player_role[P_OTHER] = 3
	tr.team_of[1] = 1
	lobby.team_rooms["9103"] = tr
	var pt := _find(lobby.team_list_payload(""), "9103")
	_check(pt.get("is_public", null) == true, "3v3 载荷 is_public 透出 true")
	_check(int(pt.get("max_players", -1)) == LobbyRooms.TEAM_ROLES, "3v3 载荷 max_players 仍是 TEAM_ROLES")
	var tc: Dictionary = pt.get("team_counts", {})
	_check(int(tc.get("1", -1)) == 1 and int(tc.get("2", -1)) == 0 and int(tc.get("0", -1)) == 1,
			"3v3 载荷 team_counts 数对了(A=1 / B=0 / 未选边=1;实得 %s)" % str(tc))

	# ── room_map:房主可写 ──
	lobby.on_room_map(P_HOST, "9102", "maps/demo.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "房主上报地图 → 写进房记录")
	var pr3 := _find(lobby.royale_list_payload("tk-probe"), "9102")
	_check(str(pr3.get("map", "")) == "maps/demo.cyrm", "再拉列表能看到这张图")

	# ── room_map:非房主一律不写 ──
	lobby.on_room_map(P_OTHER, "9102", "maps/hack.cyrm")
	_check(str(rr.map) == "maps/demo.cyrm", "★ 非房主上报被拒(房记录一字不动)")
	lobby.on_room_map(P_HOST, "9999", "maps/x.cyrm")
	_check(true, "未知房号不崩(静默丢弃)")

	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY PAYLOAD PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY PAYLOAD PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
```

新建 `tests/probe/lobby_payload_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/probe/lobby_payload_probe.gd" id="1"]

[node name="LobbyPayloadProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 跑探针，确认它红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
```

期望：**脚本报错或断言失败**（`is_public` / `host` / `room_map` 都还不存在）。若输出里出现 `Parser Error`，那也是"红"，但要确认红在**缺函数**上，不是别的手误。

- [ ] **Step 3: 三个房类各加字段**

`server/lobby/lobby_rooms.gd`，`Room` 类（约 `:33`）末尾加：

```gdscript
	# 房主上报的地图(`room_map` RPC 写；仅用于**列表展示**)。空串 = 随机/未上报。
	# ★ 它与真正定图的 `player_options.map`(报到那一刻 worker 取 role1 那份)是**两个真值** ——
	#   房主建房后改设置会让两者不一致(设计 §6 第 3 条,已知边界)。
	var map := ""
```

`RoyaleRoom` 类（约 `:52`）末尾加：

```gdscript
	var map := ""
	# 一局限时(秒)。由 `royale_create` 的 opts 带入(仅用于列表展示;权威仍是
	# `player_options.match_time` —— 同一处两真值问题,见 Room.map 的注释)。
	var match_time := 0
```

`TeamRoom` 类（约 `:79`）末尾加：

```gdscript
	var map := ""
```

- [ ] **Step 4: 三个载荷扩键**

`room_list_payload()` 的 `arr.append({...})` 改成：

```gdscript
		# host 取 `players[0]`(create_room 的 caller = 建房者);已开局 players 已空,
		# 退回 roster 第一条。is_public 恒 true(1v1 没有私密房这条路径)。
		var host_name := "玩家"
		if not room.players.is_empty():
			host_name = str(_peer_names.get(room.players[0], "玩家"))
		elif not room.roster.is_empty():
			host_name = str((room.roster[0] as Dictionary).get("name", "玩家"))
		arr.append({"code": code, "players": count, "names": names, "in_match": room.started,
				"is_public": true, "host": host_name, "map": room.map})
```

`royale_list_payload()` 的两处 `arr.append({...})`（in_match 分支与非 in_match 分支）各加三个键 + `match_time`：

```gdscript
			arr.append({"code": code, "players": rr.roster.size(), "max_players": rr.max_players,
					"names": dn, "in_match": true, "beta": rr.beta,
					"is_public": rr.is_public, "host": _host_name_of(_room_host_role(rr), rr.roster),
					"map": rr.map, "match_time": rr.match_time})
```

非 in_match 分支：

```gdscript
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names, "in_match": false, "beta": rr.beta,
				"is_public": rr.is_public, "host": str(_peer_names.get(rr.host_peer, "玩家")),
				"map": rr.map, "match_time": rr.match_time})
```

`team_list_payload()` 同款（`is_public` / `host` / `map`），另加队伍分布：

```gdscript
			arr.append({"code": c, "players": tr.roster.size(), "max_players": TEAM_ROLES,
					"names": dn, "in_match": true, "beta": tr.beta,
					"is_public": tr.is_public, "host": _host_name_of(_room_host_role(tr), tr.roster),
					"map": tr.map, "team_counts": _team_counts_of(tr)})
```

非 in_match 分支：

```gdscript
		arr.append({"code": c, "players": tr.players.size(),
				"max_players": TEAM_ROLES, "names": names, "in_match": false, "beta": tr.beta,
				"is_public": tr.is_public, "host": str(_peer_names.get(tr.host_peer, "玩家")),
				"map": tr.map, "team_counts": _team_counts_of(tr)})
```

在 `team_list_payload()` 之前加三个私有助手：

```gdscript
# 已开局的房:host_role 由 player_role[host_peer] 得来,再从 roster 里按 role 取名。
# ★ roster 是 [{role, name}](开局那一刻冻结);成员转连 worker 后 players/_peer_names 都会空,
#   对局中的房**只能**读这一份(否则第三人看到的是「玩家」)。
func _room_host_role(rr) -> int:
	if rr is RoyaleRoom or rr is TeamRoom:
		return int(rr.player_role.get(rr.host_peer, 0))
	return 0


func _host_name_of(role: int, roster: Array) -> String:
	for e in roster:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("role", 0)) == role:
			return str((e as Dictionary).get("name", "玩家"))
	return "玩家"


# 3v3 的三档人数:{1: A 队, 2: B 队, 0: 未选边}。
# ★ 键一律**字符串**,读端用 `str(k)` 取。它是**刻意的约定**,不是因为类型会丢 ——
#   本仓的 RPC 走二进制 Variant 编码,int 键其实能活下来(初稿的注释写成"JSON 往返后会变
#   字符串",那句是错的:这条链路上没有 JSON)。
func _team_counts_of(tr: TeamRoom) -> Dictionary:
	var counts := {"1": 0, "2": 0, "0": 0}
	for role in tr.player_role.values():
		var t := int(tr.team_of.get(int(role), 0))
		var k := str(t if t == 1 or t == 2 else 0)
		counts[k] = int(counts[k]) + 1
	return counts
```

- [ ] **Step 5: `royale_create` 收 `match_time`**

`royale_create` 里创建 `RoyaleRoom` 之后（找到 `rr.max_players = ...` 那一行附近）加：

```gdscript
	# 列表要显示限时 ⇒ 建房这一刻就得知道它。★ 与 `_player_options` 那份是**两个真值**
	# (权威仍是报到时 role1 那份),见 Room.map 的注释。
	rr.match_time = int(opts.get("match_time", 0))
```

- [ ] **Step 6: 加 `on_room_map` 与两个助手**

在 `team_list(caller, token)` 之后加：

```gdscript
# 客户端 → 大厅:房主上报本房的地图(仅用于**列表展示**)。
# ★ 静默丢弃的**两种**情况都不回话、不踢人:找不到房 / caller 不是房主。
#   回话没有意义(客户端无从处理),踢人更没道理(可能只是建完房还没同步完)。
# ★ 刻意**不**判"房是空的":写一个展示字段无害,而多一个分支就多一条没人测的路径
#   (初稿的注释曾声称这里判了空房 —— 一句与代码不符的注释,别照它读)。
func on_room_map(caller: int, code: String, path: String) -> void:
	var r: Variant = _room_any(code)
	if r == null:
		return
	if not _is_room_host(r, caller):
		return
	r.map = path


# 三张表按 code 找房(顺序固定:1v1 → 大乱斗 → 3v3)。
# ★ 房号空间三张表共用 ⇒ 同号共存是允许的,故这条查法**只对"上报地图"这种幂等写入安全**;
#   要拆房请走 `teardown_room` 的 `room is RoyaleRoom` 判定(那里错拆是静默的)。
func _room_any(code: String) -> Variant:
	if rooms.has(code):
		return rooms[code]
	if royale_rooms.has(code):
		return royale_rooms[code]
	if team_rooms.has(code):
		return team_rooms[code]
	return null


# 这个 caller 是不是这间房的房主?
# ★ 三张表的房主表示不同:`Room`(1v1)**没有** host 字段(建房者 = players[0],见 create_room);
#   另两张有 `host_peer`。写成"一律读 host_peer"会让 1v1 的上报**永远被拒**且不报错。
func _is_room_host(r: Variant, caller: int) -> bool:
	if r is RoyaleRoom or r is TeamRoom:
		return r.host_peer == caller
	if r is Room:
		return r.players.size() > 0 and r.players[0] == caller
	return false
```

- [ ] **Step 7: 加 `room_map` RPC**

`core/net/net_bus_ext.gd`，在 `team_room_state` 之后加：

```gdscript
# ── 统一大厅:房主上报本房地图(仅用于列表展示)──
# ★ 为什么所有模式统一走它:1v1 的 `create_room` 是**原版 NetBus 的 RPC、签名冻结**,塞不进
#   payload;而 royale/team 的 create 载荷虽是字典(加键免费),用两条机制会让"地图从哪来"
#   这件事分叉 —— 同一概念只留一份实现。
# ★ 它写的只是**列表上那张缩略图**;真正定图的仍是 `player_options.map`(报到那一刻读
#   `Settings`、由 role1 那份生效)。两个真值,见设计 §6 第 3 条。
signal room_map_requested(caller: int, code: String, path: String)

@rpc("any_peer", "reliable")
func room_map(code: String, path: String) -> void:
	room_map_requested.emit(multiplayer.get_remote_sender_id(), code, path)
```

`server/lobby/room_manager.gd` 的 `_enter_tree()`，在 `NetBusExt.team_start_requested.connect(team_start)` 之后加：

```gdscript
	# 统一大厅:房主上报地图(只写房记录的展示字段,不拉 worker、不碰对局)
	NetBusExt.room_map_requested.connect(lobby.on_room_map)
```

- [ ] **Step 8: 跑探针，确认全绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
```

期望：`LOBBY PAYLOAD PROBE: ALL-OK(20 条断言)`。

- [ ] **Step 9: 回归既有大厅探针（必须仍绿）**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
```

期望：`LOBBY VISIBILITY PROBE: ALL-OK`（45 条）。**这一条不能被本任务弄红** —— 载荷只是加键，可见性语义一字未动。

- [ ] **Step 10: 刷导入缓存，再提交**

新建了 `.gd` ⇒ 先让引擎生成它的 `.uid`（否则下面的 `git add` 会报 `pathspec did not match`）：

```bash
"$GODOT" --headless --path . --import
ls tests/probe/lobby_payload_probe.gd.uid    # 必须存在
```

```bash
git add server/lobby/lobby_rooms.gd core/net/net_bus_ext.gd server/lobby/room_manager.gd \
        tests/probe/lobby_payload_probe.gd tests/probe/lobby_payload_probe.gd.uid \
        tests/probe/lobby_payload_probe.tscn
git commit -m "feat(lobby): 列表载荷扩键(is_public/host/map/match_time/队伍分布) + room_map 上报

房卡要显示模式/状态/人数/房主/地图/名单,而三个列表载荷只有 6 个键。
按设计 §3.7 加法式扩键(不改任何 RPC 签名),地图走一条新的 NetBusExt RPC
(1v1 的 create_room 是原版 NetBus 的冻结签名,塞不进 payload)。
新增 lobby_payload_probe 钉住载荷形状与 room_map 的房主校验。"
```

---

## Task 2: 凭据模型 —— `PvpSession.room_mode`

**Files:**
- Modify: `core/net/pvp_session.gd`
- Modify: `scenes/lobby_page.gd`（`try_rejoin_row` 加 `mode` 形参）
- Modify: `scenes/main_menu.gd`（三个按钮去掉 `enter_mode`）
- Modify: `scenes/matchmaking.gd` / `scenes/royale_lobby.gd` / `scenes/team_lobby.gd`（各传自己的模式）
- Modify: `scenes/beta_menu.gd`（`enter_mode` 调用改成 `reset()`）
- Modify: `tests/smoke/reconnect_smoke.gd`
- Modify: `tests/probe/lobby_visibility_probe.gd`（相⑦）

**Interfaces:**
- Consumes: `PvpSession.MODE_PVP` / `MODE_ROYALE` / `MODE_TEAM`（已存在）
- Produces:
  - `PvpSession.room_mode: String`（**凭据**的模式）
  - `PvpSession.entry_mode: String`（进大厅时的**初始筛选**；由 Beta 页写、`mp_lobby` 读。★ 与 `room_mode` 语义不同，**不要合并** —— 详见 Task 3 的 `_enter_match_scene`）
  - `PvpSession.note_room(code: String, mode: String) -> void`
  - `PvpSession.can_rejoin_to(code: String, mode: String) -> bool`
  - `LobbyPage.try_rejoin_row(code: String, in_match: bool, mode: String) -> bool`
  - **删除**：`PvpSession.enter_mode()` / `PvpSession.mode`

- [ ] **Step 1: 改探针 —— 相⑦ 加「模式不同 ⇒ 不可点」**

`tests/probe/lobby_visibility_probe.gd` 的相⑦（约 `:294-315`）。把每一处 `PvpSession.can_rejoin_to("9021")` 改成带模式第二参，并**新增一条**跨模式的断言：

```gdscript
	# ⑦c(本批新增):**模式不同 ⇒ 不可点**。三张注册表的房号空间共用(同号共存是允许的),
	#   只看房号会让"我在 1v1 攒的凭据"把**同号的 3v3 房**判成"我的房" —— 点下去是回局请求,
	#   而大厅按凭据里的模式一查就知道不对,玩家收到一句与眼前那间房无关的拒绝。
	#   ★ 反向对照就在上面两条:**模式相同**时它必须仍然是可点的。
	_check(not PvpSession.can_rejoin_to("9021", PvpSession.MODE_TEAM),
			"⑦c 模式不同 ⇒ 不可点(同号房分属两张注册表)")
	_check(PvpSession.can_rejoin_to("9021", PvpSession.MODE_PVP),
			"⑦c 正向对照:模式相同 ⇒ 仍可点")
```

再加 **⑦d：`note_room()` 的**行为**断言（3 条）**：

```gdscript
	# ⑦d `note_room()` —— ★ **行为级**，不是源码级。理由见下。
	# ★★ 源码级的 `_check(nr.contains("clear_rejoin()"))` 只能证明**那个调用在函数里存在**,
	#    证明不了**它在正确的分支上**:把 `if a or b:` 改成 `if a and b:`(一个 token),
	#    换房号但模式不变时就**不再清凭据** —— 四条 `contains` 全都还在,全绿。
	#    ⇒ 这三条直接调函数验结果:静态字段可赋值,不需要开 socket。
	PvpSession.clear_rejoin()
	PvpSession.token = "tk-7d"
	PvpSession.worker_port = 7
	PvpSession.room_code = "1111"
	PvpSession.room_mode = PvpSession.MODE_PVP
	PvpSession.note_room("2222", PvpSession.MODE_PVP)          # 换房号、同模式
	_check(not PvpSession.can_rejoin(), "⑦d 换房号(同模式) ⇒ 凭据作废")
	PvpSession.clear_rejoin()
	PvpSession.token = "tk-7d"
	PvpSession.worker_port = 7
	PvpSession.room_code = "1111"
	PvpSession.room_mode = PvpSession.MODE_PVP
	PvpSession.note_room("1111", PvpSession.MODE_TEAM)         # 同房号、换模式
	_check(not PvpSession.can_rejoin(), "⑦d 换模式(同房号) ⇒ 凭据作废")
	# ★★ 反向对照,**必需**:等待室每收到一次房间状态就会走一遍 `note_room`,
	#    无条件清会把刚拿到的凭据抹掉(那正是当年 C1 那场事故的形状)。
	PvpSession.clear_rejoin()
	PvpSession.token = "tk-7d"
	PvpSession.worker_port = 7
	PvpSession.room_code = "1111"
	PvpSession.room_mode = PvpSession.MODE_PVP
	PvpSession.note_room("1111", PvpSession.MODE_PVP)          # 同房号、同模式
	_check(PvpSession.can_rejoin(), "⑦d 同房号同模式 ⇒ 凭据**保留**(等待室刷新不能抹凭据)")
	# ★★ 第 4 格:**记录**那一半。上面三格只验了"该清时清了",验不到"该记时记了" ——
	#    一个**只清不记**的 note_room(漏掉 `room_code = code` / `room_mode = mode`)
	#    上面三格**全过**,而后果是 `can_rejoin_to()` 永远匹配不上 ⇒ 那一行恒灰
	#    (正是 C1 那类症状)。记录那一半原先只有 `reconnect_smoke` 的源码 `contains` 守着 ——
	#    那正是本轮要替换掉的守卫风格,只是换了个属性。这一格把它也变成行为断言。
	PvpSession.clear_rejoin()
	PvpSession.token = "tk-7d"
	PvpSession.worker_port = 7
	PvpSession.room_code = "1111"
	PvpSession.room_mode = PvpSession.MODE_PVP
	PvpSession.note_room("3333", PvpSession.MODE_ROYALE)       # 换到另一间、另一个模式
	# ★★ 这里**必须再给一份 token**:换了房 ⇒ `note_room` 会先 **`clear_rejoin()`**(token 也清了),
	#    而 `can_rejoin_to()` = `can_rejoin() and …`,少了这一步两条断言对**正确实现也恒假**
	#    (与"有没有记"无关)。★ 本计划初稿就漏了这一步 —— 已订正。
	PvpSession.token = "tk-7d"
	PvpSession.worker_port = 7
	_check(PvpSession.can_rejoin_to("3333", PvpSession.MODE_ROYALE),
			"⑦d 换房之后 ⇒ 新的一对被**记下**了(只清不记的实现这里必红)")
	_check(not PvpSession.can_rejoin_to("1111", PvpSession.MODE_PVP),
			"⑦d 且旧的那一对不再成立(记录是**覆盖**,不是追加)")
	PvpSession.clear_rejoin()
```

★ ⑦d 的**覆盖上限**（写进探针注释）：它验的是"按值调用的结果"，验不到"生产里谁在什么时候调它" ——
那一半靠 ① 的源码级断言（`_on_room_created` / `_on_room_joined` / room_state 三处都走 `note_room`）。
两半缺一不可。★ 另有一格**刻意不测**：`(房号变 ∧ 模式也变)` 同时发生 —— 所有自然实现都会在那清，
且 GDScript 没有 `xor`，构造不出自然的单 token 变异；登记为覆盖边界，不补。
★ 反向对照那句注释里**别写"C1 事故的形状"** —— C1 的机制是 `reset()` 抹凭据（见 `pvp_session.gd`
里 `reset()` 上方那段），与"等待室刷新"是两回事。要引就引 `note_room` 自己那段注释。

同时把相⑦ 的 setup 段改成写 `PvpSession.room_mode = PvpSession.MODE_PVP`，并把 `EXPECTED_CHECKS` 从 **45** 改成 **52**（⑦c 新增 2 条 + ⑦d 新增 **5** 条），同步改文件头那句「相⑨ 加 7 条 → 45」后面的计数说明。

★ ⑦d 的**覆盖上限**（写进探针注释）：它验的是"按值调用的结果"，验不到"生产里谁在什么时候调它" —— 那一半靠 ① 的源码级断言（`_on_room_created` / `_on_room_joined` / room_state 三处都走 `note_room`）。两半缺一不可。

- [ ] **Step 2: 跑探针，确认它红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
```

期望：红在 `can_rejoin_to()` 参数个数 / `room_mode` 不存在上。

- [ ] **Step 3: 改 `PvpSession`**

`core/net/pvp_session.gd`：

把 `static var mode: String = ""`（`:56`）改成：

```gdscript
# 凭据**属于哪个模式**。★ 它取代了原先的 `mode` + `enter_mode()`:那套的写入点是
# 主菜单的三个联机按钮,而合一后**没有那三个按钮了**,凭据的归属改由"记房号"那一拍确定
# (`note_room(code, mode)`)。三张注册表的房号空间共用这个前提一个字没变 ⇒ 判据必须留着。
static var room_mode: String = ""
```

**删除** `enter_mode()`（`:62-66`）整段，连同它上面那段只讲它的注释。

再在 `room_mode` 那一行**下面**加一个**语义不同**的字段：

```gdscript
# 进大厅时预选的**筛选**模式(Beta 页写、统一大厅读)。空串 = 不预选(从主菜单直接进来)。
# ★★ 它**不是** `room_mode` —— 那个是**凭据**的模式,`can_rejoin_to()` 拿它判"这一行是
#   不是我的房"。把"从 Beta 页进大乱斗"写进 `room_mode` 会让一个凭据字段被写成非凭据的值
#   (`enter_mode` 当年那套的残留形态)。两个量语义不同,别合并。
static var entry_mode: String = ""
```

并在 `reset()` 末尾加一行 `entry_mode = ""` —— 顺序是安全的：`beta_menu` 与主菜单都先 `reset()` 再各自决定要不要置它。

把 `can_rejoin_to`（`:78-79`）改成：

```gdscript
# 「**这一行**是不是我的房、而且我还能回去?」—— 房间列表每一行渲染时与行被按下时**共用**
# 这**一个**判据(两处各写一遍是漂的成因:漏一处就是"看着可点、点了没用"或反过来)。
# ★ 为什么必须带房号:光判 `can_rejoin()` 会让**别人那间对局中的房**也可点。
# ★ 为什么必须带**模式**:三张注册表的房号空间共用(见 `room_mode` 上方那段),只看房号会让
#   同号的另一模式的房看起来像我的。
static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode
```

把 `note_room`（`:110-113`）改成：

```gdscript
static func note_room(code: String, mode: String) -> void:
	if code != room_code or mode != room_mode:
		clear_rejoin()
	room_code = code
	room_mode = mode
```

把 `clear_rejoin()` 里的注释清单（`:85-89` 那段「凭据真正死掉的四处」）第 ① 条从 `enter_mode()` 改成「`note_room()` 里换了**房号或模式**」（四处变三处）。

把 `reset()` 上面那段解释 `enter_mode` 的注释（`:138-153`）里对 `enter_mode` 的引用改成「主菜单那颗『多 人 模 式』按钮」，并保留「**不碰凭据**」那条纪律与它给的理由。

- [ ] **Step 4: 改 `LobbyPage.try_rejoin_row`**

`scenes/lobby_page.gd`：

```gdscript
func try_rejoin_row(code: String, in_match: bool, mode: String) -> bool:
	if not PvpSession.can_rejoin_to(code, mode):
		return false
	# 第二问:**这一行是不是"对局中"**(I2,2026-09-22 加)
	if not in_match:
		return false
	PvpSession.rejoin = true
	_request_rejoin()
	return true
```

（函数体其余不变；把它的文档注释里 `can_rejoin_to(code)` 改成 `can_rejoin_to(code, mode)`。）

- [ ] **Step 5: 三个旧页各传自己的模式**

每个页面文件顶部加一个常量，并把两处调用改掉：

`scenes/matchmaking.gd`（1v1）：

```gdscript
const MODE := PvpSession.MODE_PVP
```

- `:219` `var mine := PvpSession.can_rejoin_to(code)` → `PvpSession.can_rejoin_to(code, MODE)`
- `:230` `if not try_rejoin_row(code, in_match):` → `if not try_rejoin_row(code, in_match, MODE):`
- `:262` `PvpSession.note_room(code)` → `PvpSession.note_room(code, MODE)`
- `:269` `PvpSession.note_room(_join_code_pending)` → `PvpSession.note_room(_join_code_pending, MODE)`

`scenes/royale_lobby.gd`：

```gdscript
const MODE := PvpSession.MODE_ROYALE
```

- `:281` / `:291` / `:308` 同款改法。

`scenes/team_lobby.gd`：

```gdscript
const MODE := PvpSession.MODE_TEAM
```

- `:231` / `:241` / `:260` 同款改法。

- [ ] **Step 6: 主菜单与 Beta 页去掉 `enter_mode`**

`scenes/main_menu.gd` 三处（`:234` / `:240` / `:245`）：

```gdscript
		PvpSession.enter_mode(PvpSession.MODE_PVP)
```
→
```gdscript
		PvpSession.reset()   # 不碰回局凭据(见 pvp_session.gd 的 reset 注释)
```

（三处同款；`MODE_TEAM` / `MODE_ROYALE` 两处同理。`beta_mode` 由 `reset()` 清成 false，符合原语义。）

`scenes/beta_menu.gd:118`：

```gdscript
	PvpSession.enter_mode(str(c["mode"]))
```
→
```gdscript
	PvpSession.reset()
```

并把文件头 `:10-11` 那段「`enter_mode` 会 reset(`beta_mode=false`)，所以先 enter_mode 再置 beta_mode = true」改成「`reset()` 会把 `beta_mode` 清成 false，所以先 reset 再置 true」。

- [ ] **Step 7: 改 `reconnect_smoke`**

`tests/smoke/reconnect_smoke.gd`：

1. `:268-273`（`enter_mode` 的函数体断言）**整段删除**，替换为对新模型的断言：

```gdscript
	# ★ 凭据模型(2026-10-03,大厅合一):模式**记进凭据** —— `note_room(code, mode)` 在
	#   换了房号**或换了模式**时作废凭据;`can_rejoin_to(code, mode)` 两个都要对上。
	#   原先那套(主菜单三个按钮走 `enter_mode`)随合一整体删除,别再加回来。
	var nr := _func_body(ses, "note_room")
	_check(not nr.is_empty(), "★ PvpSession 缺 note_room()(记房号 + 记模式的唯一入口)")
	_check(nr.contains("code != room_code") and nr.contains("mode != room_mode"),
			"★ note_room() 必须「换了房号**或换了模式** ⇒ 清掉凭据」——漏掉模式那一半 ="
			+ "同号的另一模式房被当成我的房")
	_check(nr.contains("room_mode = mode"), "★ note_room() 必须把模式记进 room_mode")
	var crt := _func_body(ses, "can_rejoin_to")
	_check(crt.contains("room_code == code") and crt.contains("room_mode == mode"),
			"★ can_rejoin_to() 必须同时比对房号与模式")
	_check(not ses.contains("func enter_mode"), "★ enter_mode() 已删除(合一后没有三个菜单按钮了)")
```

2. `:291-293`（主菜单三处 `enter_mode` 的正向断言）**整段删除**，替换为：

```gdscript
	# 主菜单那颗「多 人 模 式」必须走 reset()(每次进页复位 role/spawn/地址),
	# 而 reset() **不得**碰凭据 —— 那四行 2026-09-22 删掉的纪律原样成立。
	var mm := _read(MAIN_MENU)
	_check(mm.contains("PvpSession.reset()"), "★ 主菜单联机入口未走 PvpSession.reset()")
	_check(not mm.contains("PvpSession.enter_mode("), "★ 主菜单仍在调已删除的 enter_mode()")
```

3. `:222` 的页面清单：把 `"res://scenes/matchmaking.gd", "res://scenes/royale_lobby.gd", "res://scenes/team_lobby.gd"` 换成 `"res://scenes/mp_lobby.gd"`（该文件本任务还没建 ⇒ 见 Step 8 的顺序说明）。

4. `:317-318`（三页各自 `note_room(`）：改成只查 `mp_lobby.gd`。

> ★ **本 Step 与 Task 3 的顺序**：`mp_lobby.gd` 要到 Task 3 才存在，所以本任务的 3/4 两处改动会让 `reconnect_smoke` **暂时红**。两条路都对：**(甲)** 本任务先只改 1/2 两处、把 3/4 留到 Task 3；**(乙)** 本任务连同 3/4 一起改，接受它红到 Task 3 结束。**推荐甲** —— 每一步都要有一份能跑的绿灯。

- [ ] **Step 8: 跑冒烟，确认绿**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/reconnect_smoke.gd
```

期望：`RECONNECT SMOKE: ALL-OK`（或该文件既有的判词）。

- [ ] **Step 9: 回归（必须仍绿）**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/smoke/lobby_parse_smoke.tscn
```

期望：三条各自 `ALL-OK`。**三个旧页此刻仍可用**（它们各传了自己的 `MODE`）。

- [ ] **Step 10: 提交**

```bash
git add core/net/pvp_session.gd scenes/lobby_page.gd scenes/main_menu.gd scenes/beta_menu.gd \
        scenes/matchmaking.gd scenes/royale_lobby.gd scenes/team_lobby.gd \
        tests/smoke/reconnect_smoke.gd tests/probe/lobby_visibility_probe.gd
git commit -m "refactor(pvp-session): 回局凭据自带模式,删除 enter_mode

三张注册表的房号空间共用,而 'mode' 原先的写入点是主菜单三个按钮 ——
合一后没有那三个按钮,凭据的归属改由 note_room(code, mode) 那一拍确定。
can_rejoin_to 同时比对房号与模式;lobby_visibility_probe 相⑦ 补
「模式不同 ⇒ 不可点」+ 一条正向对照。"
```

---

## Task 3: `mp_lobby` 骨架

**Files:**
- Create: `scenes/mp_lobby.gd` / `.tscn`
- Modify: `ui/factory/ui_factory.gd`（加 **3** 个模式色 token，见 Step 5）
- Test: `tests/probe/lobby_row_probe.gd`（改写为单页）

**Interfaces:**
- Consumes: `LobbyPage`（基类）、`PvpSession.room_mode`（**只读**，判"这一行是不是我的房"）、`PvpSession.entry_mode`（初始筛选）、三个列房 RPC
- Produces（供 Task 4/5/6 使用）：
  - `MpLobby._current_mode: String`（**我当前所在那间房**的模式；`_enter_match_scene` 与 `note_room` 都用它。★ **与 `PvpSession.room_mode` 不是一回事**，别合并）
  - `MpLobby._mode: String`（当前**筛选**：`""` = 全部，否则 `MODE_*`）
  - `MpLobby._rooms_by_mode: Dictionary`（`mode -> Array[Dictionary]`，每条已打上 `"mode"` 键）
  - `MpLobby._ingest_rooms(mode: String, rooms: Array) -> void`
  - `MpLobby._redraw_cards() -> void`
  - `MpLobby._set_filter(mode: String) -> void`
  - `MpLobby._join_code(code: String, mode: String) -> void`
  - `MpLobby._toggle_join_panel() -> void`
  - `MpLobby._open_create_dialog() -> void`（Task 4 实现）
  - `MpLobby._create_payload(mode: String) -> Dictionary`（Task 4 实现）
  - `MpLobby._show_wait_room(state: Dictionary, mode: String) -> void` / `_hide_wait_room()`（Task 5 实现）
  - `MpLobby._grid: GridContainer`（探针据此找卡；卡上 `set_meta("code", code)` 与 `set_meta("mode", mode)`）

- [ ] **Step 1: 改写 `lobby_row_probe` 成单页**

`tests/probe/lobby_row_probe.gd`：把 `_ready()` 换成

```gdscript
func _ready() -> void:
	_check_page([ROWS_1V1, ROWS_N, ROWS_N], ["pvp", "royale", "team"])
	_finish()
```

并把 `_check_page` 改成"把三份载荷分别喂给 `_on_room_list` / `_on_royale_rooms` / `_on_team_rooms`，再对**同一张网格**断言"：

```gdscript
const EXPECTED_CHECKS := 8

# 三份载荷(1v1 / 大乱斗 / 3v3)分别喂进页面,断言**合并后那张网格**里
# 「对局中的卡点不动 / 普通卡可点」两半都在。
# ★ 断言用**卡上那颗 Button**(卡本体就是 Button):`disabled` 只是观感,
#   真正的"点了没有反应"是**没连任何 handler** —— 两半都断,否则"画成灰的但仍然连着
#   handler"会全绿(那种实现里键盘焦点按下去照样会加入)。
func _check_page(rows_per_mode: Array, modes: Array) -> void:
	var p: Node = (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	# ★ 不入树:入树会跑 `_ready` → `_finish_lobby_ready` 里那句 `_request_list.call_deferred`
	#   会真的去连大厅。本探针只想验**画出来的卡**,不开任何 socket。
	p.set("_grid", GridContainer.new())
	p.set("_status", Label.new())
	# ★ 三次 `_ingest_rooms`:第三次(三份都到齐)自己会触发一次 `_redraw_cards`。
	#   这里**不再**补调一次 —— 同帧调两遍会考出"网格里两批卡叠着"(见 `_redraw_cards` 里
	#   那句 remove_child 的注释);生产里三条 RPC 应答确实可能落在同一帧。
	for i in modes.size():
		p.call("_ingest_rooms", modes[i], rows_per_mode[i])
	var grid: Node = p.get("_grid")
	var live := _find_card(grid, "5678")     # 对局中的那张
	var open_ := _find_card(grid, "1234")    # 普通的那张(正向对照)
	_check(live != null and open_ != null,
			"合并后两种卡都在网格里(live=%s / 普通=%s)" % [str(live), str(open_)])
	if live == null or open_ == null:
		p.free()
		return
	_check(live.disabled, "★ 对局中的卡 disabled = true")
	_check(live.pressed.get_connections().is_empty(),
			"★ 对局中的卡没接任何 handler(disabled 只是观感,不接 handler 才是真的点不动)")
	_check(live.focus_mode == Control.FOCUS_NONE,
			"★ 对局中的卡不吃键盘焦点(焦点环落到它上面 = 邀请一次注定失败的按下)")
	_check(live.modulate.a < 1.0, "对局中的卡整体压暗(modulate.a=%.2f)" % live.modulate.a)
	_check(_has_label_text(live, "对局中"), "对局中的卡上有「对局中」角标")
	_check(not open_.disabled, "普通卡不是 disabled(正向对照)")
	_check(open_.pressed.get_connections().size() == 1,
			"普通卡恰有一个 handler(还能加入;正向对照)")
	p.free()


# 卡是 Button,内容全在子节点里 —— 按 meta 找卡、递归找文案。
# ★ 不能按 `Button.text` 找:卡的 `text` 是空串(内容自绘),那是**有意**的。
func _find_card(grid: Node, code: String) -> Button:
	for c in grid.get_children():
		if c is Button and str((c as Button).get_meta("code", "")) == code:
			return c
	return null


func _has_label_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for c in node.get_children():
		if _has_label_text(c, needle):
			return true
	return false
```

断言 8 条（与上面代码逐条对应）：两卡都在 / `disabled` / 0 连接 / 不吃焦点 / `modulate.a < 1` / 「对局中」文案 / 普通卡不 disabled / 普通卡恰 1 个 handler。

- [ ] **Step 2: 跑探针，确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
```

期望：`mp_lobby.tscn` 不存在 ⇒ 加载失败 / 报错。

- [ ] **Step 3: 建 `mp_lobby.gd` 骨架**

新建 `scenes/mp_lobby.gd`：

```gdscript
extends LobbyPage

# 统一联机大厅(**取代** matchmaking / royale_lobby / team_lobby 三个页)。
# 顶栏(昵称/地址/启服) → 模式筛选 + 创建/加入 → 房卡网格 → 状态栏。
# 三套服务端注册表原样保留:本页**并发调三次**现有列房 RPC,前端合并打标(设计 §3.7.3)。
#
# ★ 一条纪律:三个模式在这里的差异**全部**收在 `_mode` 这一个变量上
#   (筛选值 / 创建弹层的形态 / 等待室的形态 / 转连方式)。别再按"哪个页面"分叉 ——
#   那正是本次要消灭的重复。
# ★ 本页的梯顺序 = `[worker → claim → 大厅 → ack]`(与旧的大乱斗/3v3 页同款):
#   1v1 旧页那条 `[worker → join → 大厅 → claim]` 随三页一起退役;合并后**只有**这一条,
#   而它必须容纳三模式 —— join 那条梯的职责由 ack 那条(建房/加入 8s 无应答)覆盖。

# ── 版式常量(真实像素;1920×1440 设计稿)──
const PAGE_MARGIN := 40.0
const CARD_COLUMNS := 4
const CARD_GAP := 22.0
const ROW_H := 64.0

var _mode := ""                    # "" = 全部;否则 PvpSession.MODE_*
var _rooms_by_mode := {}           # mode -> Array(载荷条目,已打 "mode" 键)
var _grid: GridContainer = null
var _filter_btns := {}             # mode -> Button
var _join_panel: PanelContainer = null

# 建房/加入的 8s 无应答兜底(合并后只剩这一条 ack 梯)
var _ack := true
var _sent_ms := 0

# 三个模式各自的"已收到应答"标记(三条 RPC 各自到达)
var _got := {"pvp": false, "royale": false, "team": false}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()
	_build_top_bar()
	_build_filter_bar()
	_build_card_grid()
	_build_status_bar()

	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state_royale)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state_team)

	_finish_lobby_ready()
```

`_build_top_bar()` 按设计 §3.2 的度量建：昵称行（标签 200 宽 + 输入框 520×64，字号 32）、服务器地址行（同上 + `刷新列表` + `启动/重启本机服务器`）、右侧本机 IP 标签（`LocalServer.lan_ip_hint()`）。

`_build_filter_bar()`：`全部 / 1 v 1 / 3 v 3 / 大乱斗` 四颗按钮 + 右侧 `＋ 创建房间`（调 `_open_create_dialog`）与 `加入房间`（调 `_toggle_join_panel`）。

`_build_card_grid()`：

```gdscript
func _build_card_grid() -> void:
	_grid = GridContainer.new()
	_grid.columns = CARD_COLUMNS
	_grid.add_theme_constant_override("h_separation", int(CARD_GAP))
	_grid.add_theme_constant_override("v_separation", int(CARD_GAP))
	_grid.position = Vector2(PAGE_MARGIN, 470)
	_grid.size = Vector2(1920.0 - PAGE_MARGIN * 2.0, 0)
	add_child(_grid)
```

- [ ] **Step 4: 合并与重绘**

```gdscript
# 三个载荷入口各自把条目并入同一张表,再统一重绘。
# ★ 每条都**打上 mode 标** —— 卡片要显示模式,筛选器也按它过滤;服务端载荷里没有这个键
#   (三套注册表各管各的,谁也不该知道别人)。
func _ingest_rooms(mode: String, rooms: Array) -> void:
	var tagged: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (r as Dictionary).duplicate()
		d["mode"] = mode
		tagged.append(d)
	_rooms_by_mode[mode] = tagged
	_got[mode] = true
	_ack = true
	_sent_ms = 0
	if _got.values().all(func(v: bool) -> bool: return v):
		_redraw_cards()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	# Beta 房与普通房互不可见(客户端侧;服务器侧 join 守卫是第二道)
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


# 重绘整张网格。
# ★★ **必须先 `remove_child` 再 `queue_free`** —— 只 `queue_free` 的话旧节点要到**帧末**才没,
#   同帧再建一次就会在网格里留下**两批卡叠着**(而且它们都还是 `_grid` 的子节点,
#   `get_children()` 数得出来)。生产里三条 RPC 应答**确实可能落在同一帧**
#   (`_ingest_rooms` 每收到一条就可能触发一次重绘)。本仓在"热重建视觉"那处踩过同款
#   (`WeaponPickup.configure` 的注释)。
func _redraw_cards() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		for r in _rooms_by_mode.get(mode, []):
			total += 1
			if _mode != "" and mode != _mode:
				continue
			_grid.add_child(_make_card(r))
			shown += 1
	if shown == 0:
		var empty := UiFactory.label("暂无房间 —— 点「＋ 创建房间」开一局吧", 32, UiFactory.C_TEXT_DIM)
		_grid.add_child(empty)
	_status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]
```

**排序**：旧的 1v1 页把"未满"排在前面、对局中的排最后（它的注释说这是"在打的排最后、可加入的排前面"）。合并后**在每个模式内部**保持这条：进 `for r in ...` 之前先

```gdscript
		var rows: Array = _rooms_by_mode.get(mode, []).duplicate()
		# ★★ `sort_custom` 的比较函数返回 true = **a 排在 b 前面**(不是"a 该往后挪")。
		#    要"未满的在前、满的在后",就得在 **a 未满而 b 满** 时返回 true —— 本计划初稿把
		#    条件写反了(返回 true 当 a 满),结果是**满房排在了前面**,与自己的注释/状态栏/
		#    旧页(`matchmaking.gd` 的 `partial + full`)全都相反,且没有断言覆盖顺序。
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_full := int(a.get("players", 0)) >= int(a.get("max_players", 2))
			var b_full := int(b.get("players", 0)) >= int(b.get("max_players", 2))
			return not a_full and b_full)
```

（1v1 的载荷没有 `max_players` ⇒ 取默认 2，与卡片那一处同一个默认值。）
★ **在 `for r in rows:` 里遍历 `rows`，不要再遍历 `_rooms_by_mode[mode]`** —— 排完序不遍历它等于没排。

- [ ] **Step 5: 造卡**

```gdscript
# 一张房卡 = **一颗 Button**(卡本体就是可点区域)。
# ★ 为什么不是 PanelContainer + 覆盖层:那样"点不动"就要靠探针去数覆盖层的连接数,
#   而 `disabled` / `focus_mode` / `pressed` 这三个原生属性都在 Button 上 —— 探针的三条
#   断言(`disabled` / 0 连接 / 不吃焦点)直接落在同一个节点上,没有第二处真值。
# ★ 子节点一律 `mouse_filter = IGNORE`:内容画在 Button 之上,但点击必须落到卡本体,
#   否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	UiFactory.style_button(btn, "primary")
	btn.custom_minimum_size = Vector2(_card_width(), 400)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""   # 内容全部自绘

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 8)
	btn.add_child(col)

	col.add_child(_card_header(mode, r))
	col.add_child(_card_body(r))

	# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**(`can_rejoin_to` 已在上面算好),
	#    这一档**可点**(点了走回局);不是我的房,才轮到「对局中 ⇒ 禁用」那一档。
	#    反过来写 = 回局这一档连点都点不到,而**一行报错都没有**。
	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)   # 整体压暗:一眼看出这间进不去
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			# ★★ 回局那条路**也要**记下模式 —— 与"加入"那条同款。本计划初稿只让
			#    `_join_code` 那一支记账,于是**回局**时 `_current_mode` 是空串:
			#    ESC 回主菜单 → 多人模式(新页,`_current_mode == ""`)→ 点自己那间对局中的房
			#    → `try_rejoin_row` → `go_match` → `match_start` → `_enter_match_scene()`
			#    落进 else ⇒ **回局也会进 `team_game.tscn`**。
			#    这与 Task 2 修掉的那个洞是同一个(当时只覆盖了三个入口里的一个)。
			_current_mode = mode
			if not try_rejoin_row(code, in_match, mode):
				_join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))
```

```gdscript
# 模式色(与对局**无关**的一套,只在菜单系用)。★ 3v3 刻意**不用蓝** —— `#639BFF` 就是
# `UiFactory.C_TEAM_A`(队 1 的队色),而队色在 3v3 里是**有玩法语义**的颜色
# ("一眼看出谁是队友")。拿它当模式色会让大厅的「3v3」与对局的「队 1」撞色。
# ★★ 那两个模式色**必须先落到 `ui/factory/ui_factory.gd` 里**（本 Step 稍后给了那三行），
#    再在这里引用。**不要**在本文件写 `Color(...)` 字面量 —— 调色板单一来源是本项目的硬约束
#    （`CLAUDE.md`：「颜色只在那里定义…不要再写 `Color(...)` 字面量」），
#    而本计划初稿正是在这里直接写了字面量、与本计划自己的 Global Constraints 打架。
#    漏走的后果不是报错：是计划 ③ 的调色板工作会**再定义一遍同样的颜色**，两份静默漂移。
const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "3 v 3",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}
```

**同一 Step 里，先往 `ui/factory/ui_factory.gd` 的调色板区（`C_ACCENT` 附近）加三个 token**：

```gdscript
# ── 模式色(2026-10-03,大厅合一)──
# 只在**菜单系**用(房卡标题带 / 筛选器),与对局内任何颜色无关。
# ★ 3v3 **刻意不用蓝**:`#639BFF` 就是 `C_TEAM_A`(队 1 的队色),而队色在 3v3 里是
#   **有玩法语义**的颜色("一眼看出谁是队友")。拿它当模式色会让大厅的「3v3」与对局的
#   「队 1」撞色 —— 那是"认不出队友"那类问题的同一个源。
# ★ 1v1 直接复用 `C_ACCENT`(设计 §3.9.2),不另立一个同值 token。
const C_MODE_TEAM   := Color(0.627, 0.549, 1.0)      # #A08CFF 紫
const C_MODE_ROYALE := Color(0.910, 0.639, 0.239)    # #E8A33D 琥珀
```


# 卡头一行:左 = 模式名(模式色),右 = 状态角标。
# ★ 角标三档的**次序**:`对局中` 优先于 `私密 · 我的` —— 一间对局中的私密房对**别人**
#   根本不列出,能同时满足两条的只有"我的房且已开局",那时"对局中"是更有用的信息。
func _card_header(mode: String, r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)

	var name_l := UiFactory.label(str(MODE_LABEL[mode]), 32, MODE_COLOR[mode])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_l)

	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var badge := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	# ★ 三档取色**刻意避开 `C_WARN`** —— 它在调色板里被钉死为「弹夹见底」**单一语义**
	#   (`ui_factory.gd` 的 `C_WARN` 注释明写"**只**用于「低弹量/耗尽」")。拿它表"私密"
	#   会让那个金色在大厅与 HUD 里指两件事。这里用中性亮白:不抢强调色,也不借用语义色。
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	row.add_child(UiFactory.label(badge, 32, badge_col))
	return row


# 卡身:房间号(48) → 副标(32) → [地图缩略图 120×120 | 人数/房主] → 名单(最多 3 行)。
func _card_body(r: Dictionary) -> Control:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)

	box.add_child(UiFactory.label(str(r.get("code", "")), 48, UiFactory.C_TEXT))
	box.add_child(UiFactory.label(_card_subtitle(mode, r), 32, UiFactory.C_TEXT_DIM))

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_theme_constant_override("separation", 16)
	mid.add_child(_card_map_thumb(mode, str(r.get("map", ""))))
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 1v1 的载荷**没有** max_players(1v1 恒 2 人)—— 前端补,而不是去动那三个载荷的形状。
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("players", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


# 副标按模式给不同的一行(它就是各模式"规则摘要"的位置)。
func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


# 地图缩略图。★ 复用 MapCatalog 那套(选图面板已经在用它现画地形简略图)——
#   **不要**另写一份画法:两份必然漂,而漂了不报错,只是两张图长得不一样。
#   `map` 为空(= 未上报 / 随机)时退化成一块模式色占位,而不是留一个空洞。
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# ★ 签名是 `MapCatalog.texture(path: String, cell_px: int = CELL_PX) -> ImageTexture`
		#   —— 与 `ui/map_picker.gd:54` 同一个入口(那边也是 `MapCatalog.texture(str(m["path"]))`)。
		tex.texture = MapCatalog.texture(map_path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.add_child(tex)
	else:
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = MODE_COLOR[mode]
		fill.color.a = 0.25
		frame.add_child(fill)
	return frame


# 名单行:**最多 3 行**,超出显示 `…等 N 人`。
# ★ 名字走 `UiFactory.fit_name(名字, 14)` 定宽截断(与结算页同款)—— 不截的话长昵称会
#   把卡顶宽(卡宽是 4 列网格算出来的固定值,顶宽 = 整行错位)。
func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				32, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 32, UiFactory.C_TEXT_DIM))
	return box
```

★ 本卡片的缩略图与选图面板用的是**同一个** `MapCatalog.texture()`（已核对签名，见上）。

地图缩略图用 `MapCatalog`：`r["map"]` 为空时画一块模式色占位。

- [ ] **Step 6: 拉列表（三条并发）**

```gdscript
# 基类钩子。★ **不是一条统一 RPC** —— 三条并发、各自到达,合并后重绘。
#   代价照实登记:刷新延迟由最慢那份决定(设计 §3.7.3)。
func _send_list_request() -> void:
	_got = {"pvp": false, "royale": false, "team": false}
	_rooms_by_mode.clear()
	NetBus.rpc_id(1, "list_rooms")
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
	NetBusExt.rpc_id(1, "team_list", PvpSession.token)
```

- [ ] **Step 7: 加入弹层与其余基类钩子**

`_toggle_join_panel()`：居中弹层，`房间号` + `邀请码(私密)` + `加入` 按钮；`加入` 调 `_join_code(code, _mode if _mode != "" else "")` —— 模式未知时先按 1v1 发（大厅三张表都会查，见 Step 8 的说明）。

```gdscript
# 加入某房间号。★ 模式未知(从"全部"列表点的、或手敲房号)时,三张表**都试一次**:
#   三次请求里只有一间存在,其余两句「房间不存在」由 `_on_server_message` 吞掉不显示
#   (见下面的 `_swallow_absent`)。
# ★★ 三件事一件都不能少:
#   ① `_join_pending = code`(**本计划初稿漏了这一半**)—— 服务端是**先**回 `room_joined`、
#      **后**配对开局,所以 `_on_room_joined` 只有拿到这个暂存才能记下"我加的是哪一间"。
#      漏了它的后果是**两条**:`_current_mode` 停在空串 ⇒ `_enter_match_scene()` 落进 else
#      ⇒ **1v1 的加入者被送进 `team_game.tscn`**;以及 `note_room()` 从不被调用 ⇒
#      自己那间房永远是灰的(C1 症状)。
#   ② 模式未知("全部"列表里点的、或手敲房号)**三张表都问一次**(只有一间会成功)。
#   ③ `invite` 是**必须的第三参**(设计 §3.2:邀请码是进私密房的**唯一**途径)。
func _join_code(code: String, mode: String, invite: String = "") -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		_join_pending = code          # ★ 见上:漏了它 = 场景选错 + 凭据记不上
		_status.text = "加入房间 %s,等待配对…" % code
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_PVP:
			NetBus.rpc_id(1, "join_room", code)
		else:
			# 模式未知:三张表都问一次(只有一间会成功)
			NetBus.rpc_id(1, "join_room", code)
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode))
```

**加入成功时**(`_on_room_joined(role)` / 两个 `room_state` 首帧):

```gdscript
	if not _join_pending.is_empty():
		_current_mode = mode            # ★ 与 _join_pending 配对:没有它 = 场景选错
		PvpSession.note_room(_join_pending, mode)
		_join_pending = ""
```

其余基类钩子（本任务先给"能跑"的实现，Task 6 按 `_mode` 精修）：

```gdscript
func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


func _lobby_action_allowed() -> bool:
	return true


# 三个模式的权威规则项都上发,worker 各取自己认得的键(`server_main._on_player_options`
# 与 `MatchBootstrap` 都按 role1 那份生效)。不认得的键被静默忽略 —— 这是既有行为。
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
	}


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"
```

- [ ] **Step 8: 转连与超时梯**

```gdscript
# ★★ 判据必须是**本页的 `_current_mode`**(我当前所在那间房的模式),**不是**
#   `PvpSession.room_mode`。后者是**凭据**的模式(供列表里判"这一行是不是我的房"),
#   它在"建了房但 `note_room` 还没跑到"这一档上是**空串** —— 那时下面这个 else 会把
#   1v1 的对局**静默切进 `team_game.tscn`**(不报错,只是一个场景选错了)。
#   ⇒ 两个量语义不同,不要合并成一个字段。
# ★ 两页**刻意不同**的那条纪律现在按 `_current_mode` 分派(设计 §3.1.2):
#   1v1 直切;大乱斗/3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内
#   到达,栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
# ★★ else 那一支**刻意什么都不做、只 push_error**,不默认切任何一个场景。
#    理由:本函数有三条进入路径(建房 / 加入 / 回局),任何一条漏记 `_current_mode` 都会
#    落到这里 —— 那时"切一个默认场景"是**静默的错值**(玩家进了错误的对局场景,只是看起来怪),
#    而"留在原地 + 一条红"是**响的**。本仓的取向一贯是前者不可接受。
#    ★ 本计划初稿写的是 `else: 切 team_game` —— 那正是让"1v1 加入者进 team_game"
#      这个洞**不报错**的原因。
func _enter_match_scene() -> void:
	if _current_mode == PvpSession.MODE_PVP:
		get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
	elif _current_mode == PvpSession.MODE_ROYALE:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/royale_game.tscn")
	elif _current_mode == PvpSession.MODE_TEAM:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/team_game.tscn")
	else:
		# ★★ 格式化的写法有讲究:GDScript 里 `%` 的**优先级高于 `+`**,写成
		#    `"前半" + "后半" % x` 会被解析成 `前半 + (后半 % x)` —— 而"后半"没有占位符
		#    ⇒ 运行时 `not all arguments converted`。那条 ERROR 会**盖住真信息**
		#    (本仓有先例:一行格式错误淹掉探针的真失败)。所以**先拼成一条**再 `%`:
		push_error("mp_lobby: match_start 到了但 _current_mode 是「%s」—— 建房/加入/回局三条路里有一条没记模式。**不切场景**(切错的场景比留在原地更难查)。" % _current_mode)


# 梯顺序 `[worker → claim → 大厅 → ack]`(合并后唯一的一条;见文件头)。
# ★ 别重排:1v1 旧页那条 join 梯的职责由末尾的 ack 梯覆盖(建房/加入 8s 无应答)。
func _process(_delta: float) -> void:
	if _tick_rejoin_timeout():
		return
	if _tick_worker_connect_timeout():
		return
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	if not _ack and _sent_ms > 0 and Time.get_ticks_msec() - _sent_ms > 8000:
		_sent_ms = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"
```

- [ ] **Step 9: 跑探针，确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
```

期望：`LOBBY ROW PROBE: ALL-OK(8 条断言)`。

- [ ] **Step 10: 刷导入缓存，再提交**

新建了 `.gd` ⇒ 先跑 `"$GODOT" --headless --path . --import` 生成 `.uid`（见 Global Constraints）。

```bash
git add scenes/mp_lobby.gd scenes/mp_lobby.gd.uid scenes/mp_lobby.tscn \
        tests/probe/lobby_row_probe.gd
git commit -m "feat(lobby): mp_lobby 骨架 —— 合并列表 + 模式筛选 + 房卡网格

一页取代三页的第一刀:顶栏/筛选/四列房卡/加入弹层。
列表并发调三次现有列房 RPC、前端合并打标(不新增统一 RPC)。
lobby_row_probe 改为单页断言。"
```

---

## Task 4: 创建房间弹层

**Files:**
- Modify: `scenes/mp_lobby.gd`
- Test: `tests/probe/lobby_create_form_probe.gd` / `.tscn`（新建）

**Interfaces:**
- Consumes: `MpLobby._mode`、`LobbyPage._add_map_picker(vb)`、`LobbyPage._add_weapon_grid(parent, h_sep, on_cell)`、`LobbyPage._add_hue_row(...)`（本任务**不用**色相行，它在等待室）
- Produces:
  - `MpLobby._open_create_dialog() -> void`
  - `MpLobby._apply_create_form(mode: String) -> void`
  - `MpLobby._create_payload(mode: String) -> Dictionary`

- [ ] **Step 1: 写失败的探针**

新建 `tests/probe/lobby_create_form_probe.gd`：不入树实例化 `mp_lobby.tscn`，依次调 `_apply_create_form(各模式)`，断言：

1. `MODE_ROYALE` ⇒ 人数行可见、限时行可见
2. `MODE_TEAM` ⇒ 人数行**不可见**、限时行**不可见**
3. `MODE_PVP` ⇒ 人数行不可见、限时行不可见
4. `MODE_TEAM` ⇒ **禁用武器网格不可见**（★ 这条有真实危害：那两个勾选框写的是 `Settings.pvp_disabled_weapons`，在 3v3 勾一下会**连带改掉另两个模式**）
5. `MODE_PVP` / `MODE_ROYALE` ⇒ 禁用武器网格可见
6. 三个模式都可见地图选择器
7. 弹层右上角有一颗 `×` 按钮（文案就是 `×`）
8. `_create_payload(MODE_TEAM)` 不含 `disabled_weapons` 键
9. `_create_payload(MODE_ROYALE)` 含 `match_time` 键且为整数
10. `_create_payload(MODE_PVP)` 含 `is_public` 与 `invite_code` 键

`EXPECTED_CHECKS := 10`。

- [ ] **Step 2: 跑探针，确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
```

- [ ] **Step 3: 实现弹层**

```gdscript
var _create_panel: PanelContainer = null
var _form_rows := {}      # "max_players" / "match_time" / "weapons" / "map" -> Control
var _create_mode := PvpSession.MODE_PVP
var _public_check: CheckButton = null
var _invite_edit: LineEdit = null
var _max_slider: HSlider = null
var _time_slider: HSlider = null
var _weapon_checks: Array[CheckButton] = []


# 点「＋ 创建房间」才建/显示。★ 只建一次、之后只改可见性(重建会把滑块拖回默认值)。
func _open_create_dialog() -> void:
	if _create_panel == null:
		_build_create_panel()
	_create_mode = _mode if _mode != "" else PvpSession.MODE_PVP
	_apply_create_form(_create_mode)
	_create_panel.visible = true
```

`_build_create_panel()`：居中 + 半透明压暗罩；标题带 `创 建 房 间` + 右上角 `×`（`Button`，`text = "×"`，`pressed` ⇒ `_create_panel.visible = false`）；左列＝模式分段按钮（三颗，`pressed` ⇒ `_apply_create_form(m)`）+ 公开/私密 + 邀请码 + 人数行 + 限时行；右列＝禁用武器网格（`_add_weapon_grid(vb, 20, on_cell)`）+ 地图选择（`_add_map_picker(vb)`）；底部 `取 消` / `创 建 房 间`。

```gdscript
# 按模式变形 —— 本弹层**唯一**的分支(设计 §3.4 的那张表)。
# ★ 3v3 关掉禁用武器不只是"规则里没有":那两个勾选框写的是 `Settings.pvp_disabled_weapons`,
#   在 3v3 页勾一下会**连带改掉另两个模式**。那是功能缺陷,不是审美。
func _apply_create_form(mode: String) -> void:
	_create_mode = mode
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	_form_rows["max_players"].visible = is_royale
	_form_rows["match_time"].visible = is_royale
	_form_rows["weapons"].visible = not is_team
	for b in _create_mode_btns:
		(b as Button).disabled = false
	(_create_mode_btns[mode] as Button).disabled = true   # 当前模式置灰(与等待室的选边同款)
```

- [ ] **Step 4: 建房载荷**

```gdscript
# 按模式给三套 payload 的**公共部分** + 各自的私有键。
# ★ `map` 三个模式都上发(设计 §3.7.2):1v1 的 `create_room` 签名冻结、塞不进 payload,
#   故地图一律走 `room_map` 那条独立的 RPC —— 建房成功后由本端补发一次。
func _create_payload(mode: String) -> Dictionary:
	var d := {
		"is_public": _public_check.button_pressed,
		"invite_code": _invite_edit.text.strip_edges(),
		"map": Settings.mp_map_path,
	}
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = int(_max_slider.value)
		d["match_time"] = int(_time_slider.value) * 60
		d["round_full_heal"] = false
		d["disabled_weapons"] = _checked_weapons()
	elif mode == PvpSession.MODE_PVP:
		d["disabled_weapons"] = _checked_weapons()
	return d
```

`_on_create_pressed()` 按模式分派三个 RPC（1v1 用 `NetBus.rpc_id(1, "create_room")`，另两个用 `NetBusExt`），`_beta_payload()` 合并进去。

★★ **`_on_server_message` 必须对「任何」服务端消息解除 ack 兜底**（清 `_ack` / `_sent_ms`），
不能只对白名单里那三条（`房间已满` / `房间不存在` / `配对已取消…`）。
理由：兜底的语义是"**服务器一个字都没回**"，而收到任何一句服务端文案**本身就证明它回了**。
漏掉的后果**不是**"少一条提示"：8 秒后 `_process` 会把**真正的拒绝文案覆盖成**
「8 秒无响应——地址不通,或该服务器不是最新版」—— 玩家看到的是与实情相反的解释。
★ 这条有**本任务自己引入**的可达路径：私密房邀请码填错 ⇒ 服务端回 `邀请码错误` ⇒ 若不在白名单里，
8 秒后它就变成"地址不通"。同族文案还有 `你已经在房间里了` / `该房间的对局已进行中,无法加入` 等。

- [ ] **Step 5: 建房成功后补发地图**

在 `_on_room_created(code)` 与两个模式的 `room_state` 首帧里（即 `note_room` 那一拍之后）加：

```gdscript
	# 补发地图(设计 §3.7.2)。★ 只有**房主**该发 —— 非房主发会被服务端静默拒(**不报错**,
	# 所以必须自己判,否则每个加入者都会白发一次)。
	NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
```

`_on_room_created(code)`（1v1）里**无条件**发这一句 —— 建房者就是房主。

两个 `room_state` handler（大乱斗 / 3v3）里**要判**：

```gdscript
	# ★ 判据用服务器下发的 `host_role` / `your_role` 两条(它们按 peer 单独下发,
	#   不是按昵称反查 —— 两人同名时会命中先出现的那个,本仓踩过)。
	if int(state.get("host_role", 0)) == int(state.get("your_role", 0)):
		NetBusExt.rpc_id(1, "room_map", code, Settings.mp_map_path)
```

- [ ] **Step 6: 跑探针，确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
```

期望：`LOBBY CREATE FORM PROBE: ALL-OK(10 条断言)`。

- [ ] **Step 7: 刷导入缓存，再提交**

新建了 `.gd` ⇒ 先跑 `"$GODOT" --headless --path . --import` 生成 `.uid`（见 Global Constraints）。

```bash
git add scenes/mp_lobby.gd tests/probe/lobby_create_form_probe.gd \
        tests/probe/lobby_create_form_probe.gd.uid tests/probe/lobby_create_form_probe.tscn
git commit -m "feat(lobby): 创建房间弹层(点＋才展开,按模式变形)

房主选项从常驻右栏搬进弹层。3v3 关掉禁用武器行 —— 那两个勾选框写的是
Settings.pvp_disabled_weapons,在 3v3 勾一下会连带改掉另两个模式。
建房成功后房主补发 room_map。"
```

---

## Task 5: 等待室（按模式）

**Files:**
- Modify: `scenes/mp_lobby.gd`
- Test: `tests/probe/lobby_wait_room_probe.gd` / `.tscn`（新建）

**Interfaces:**
- Consumes: `MpLobby._open_create_dialog` 等
- Produces:
  - `MpLobby._show_wait_room(state: Dictionary, mode: String) -> void`
  - `MpLobby._hide_wait_room() -> void`

- [ ] **Step 1: 写失败的探针**

`EXPECTED_CHECKS := 8`：

1. 1v1 状态 ⇒ 等待室可见、标题含房间号、有 `退出房间` 按钮、**没有**选边按钮
2. 3v3 状态 ⇒ 两队标题都在（`A 队` / `B 队`）、未选边档在、两颗选边按钮在
3. 大乱斗状态 ⇒ 名单行数 == 载荷 players 条数
4. 3v3 且我在 A 队 ⇒ 「加入 A 队」按钮**不可见**（已在队里，少一次无意义上行）
5. 只有房主且两队各满 ⇒ `开始游戏` 可见
6. 非房主 ⇒ `开始游戏` 不可见
7. 1v1 / 大乱斗 ⇒ 角色颜色行可见；3v3 ⇒ 不可见（3v3 用队色）
8. 名单行编号印**行序**（1./2./3.）而不是 role —— 喂一份 `roles = [1, 3]` 的载荷，断言第 2 行文案以 `2.` 开头

- [ ] **Step 2: 跑探针，确认红**

- [ ] **Step 3: 实现**

三个模式的等待室共用**一个** `PanelContainer`（居中锚点必须在入树之后设 —— 未入树时父级尺寸为 0，面板会飞到屏幕左上角外，两页旧稿都踩过）。`_show_wait_room(state, mode)` 清空重填：

- 标题：`—— {模式名}房间 {code} ——`（私密房追加 `邀请码 XXXXXX`）
- 1v1：`等待对手… 1 / 2`
- 3v3：A 队 / B 队 / 未选边三档 + 两颗选边按钮（自己那支的按钮置灰 —— 既少一次无意义上行，也让"已在该队时再点该队"那条幂等 wart 不可达）
- 大乱斗：名单 + `N / M 人`
- **角色颜色行**（仅 1v1 / 大乱斗，走基类 `_add_hue_row(vb, "自己角色颜色:", Vector2(320, 30), Vector2(46, 30))`）
- 底部：房主 `开始游戏`（3v3 要求两队各满）+ `退出房间`

★ **编号印行序不印 role**：role 是「最小空闲号」分配、有人退出不重排 —— 印 role 会出现 1、3。

- [ ] **Step 4: 跑探针，确认绿**

- [ ] **Step 5: 刷导入缓存，再提交**

新建了 `.gd` ⇒ 先跑 `"$GODOT" --headless --path . --import` 生成 `.uid`（见 Global Constraints）。

```bash
git add scenes/mp_lobby.gd tests/probe/lobby_wait_room_probe.gd \
        tests/probe/lobby_wait_room_probe.gd.uid tests/probe/lobby_wait_room_probe.tscn
git commit -m "feat(lobby): 统一等待室(按模式渲染) + 1v1 也有一间

1v1 原先建房后没有任何'我在等'的界面(状态只落状态栏),现在与另两个模式
共用同一个面板。角色颜色行只在 1v1/大乱斗出现(3v3 用队色)。"
```

---

## Task 6: 切换入口（主菜单两颗 + `beta_menu` + `menu_autotest`）

**Files:**
- Modify: `scenes/main_menu.gd`
- Modify: `scenes/beta_menu.gd`
- Modify: `tests/smoke/menu_autotest.gd`

**Interfaces:**
- Consumes: `scenes/mp_lobby.tscn`
- Produces: 主菜单只剩 `单 人 模 式` / `多 人 模 式`

- [ ] **Step 1: 改主菜单**

`_build_menu_buttons()`（`:206-274`）把三颗联机按钮换成一颗：

```gdscript
	# 三个联机模式的入口收进统一大厅(2026-10-03)。★ 只走 `reset()`:
	#   它**不碰**回局凭据(那四行 2026-09-22 删掉的纪律),而凭据的模式归属由
	#   `note_room(code, mode)` 在进房那一拍确定 —— 见 pvp_session.gd 的 `room_mode`。
	var multi_btn := UiFactory.button("多 人 模 式", 32)
	multi_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		PvpSession.reset()
		get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn"))
```

返回数组改成 `[start_btn, multi_btn, settings_btn, ver_btn, beta_btn, quit_btn]`（浮현动画次序同步）。

- [ ] **Step 2: 改 `beta_menu`**

两张卡的 `scene` 改 `res://scenes/mp_lobby.tscn`，`_on_card_pressed` 里：

```gdscript
	PvpSession.reset()
	PvpSession.beta_mode = true
	PvpSession.entry_mode = str(c["mode"])   # 预选**筛选**,不是凭据
	get_tree().change_scene_to_file("res://scenes/mp_lobby.tscn")
```

★ `CARDS[i]["mode"]` **不是死字段**（删掉 `enter_mode` 后它一度看着像死的）：Task 6 起它重新有读者，就是上面这一行。

`mp_lobby._ready()` 末尾加：

```gdscript
	# Beta 页预选的**筛选**模式(直接进大厅时为 "")。
	# ★★ 它读的是 `entry_mode` 而**不是** `room_mode`:后者是**凭据**的模式,
	#   混用会让"从 Beta 页进大乱斗"这件事把一个凭据字段写成非凭据的值 ——
	#   而 `can_rejoin_to()` 正是拿 `room_mode` 判"这一行是不是我的房"。
	if PvpSession.entry_mode != "":
		_set_filter(PvpSession.entry_mode)
```

- [ ] **Step 3: 改 `menu_autotest`**

`:63-69` 三个模式的分派改成都按 `多 人 模 式`（然后按 `_mode` 断言到达同一场景）：

```gdscript
	elif mode == "mp" or mode == "royale" or mode == "team":
		_press_by_text(tree.current_scene, "多 人 模 式")
```

`must_reach`（`:84-90`）：

```gdscript
	var must_reach := {
		"sp": "level_0.tscn",
		"mp": "mp_lobby.tscn",
		"set": "settings_menu.tscn",
		"royale": "mp_lobby.tscn",
		"team": "mp_lobby.tscn",
	}
```

文件头 `:8-10` 三行说明同步改。

★★ **顺手清掉"三个联机按钮"这个写死的数量** —— 本任务把菜单收成一颗之后，下列位置的说法**全部过期**（它们今天**都是对的**，正因为对才会被漏掉）：
`core/net/pvp_session.gd` 里 `:39` 与 `:127-128` 附近、`scenes/main_menu.gd:223-225` 的注释、`tests/smoke/reconnect_smoke.gd:245,257,291,294`。一律改成不依赖数量的表述（如「主菜单的联机入口」/「联机入口按钮」）。
★ 同一批里 `reconnect_smoke:297` 那条 `count("PvpSession.reset()") >= 3` **必须一起改**（本任务后菜单只剩一颗按钮 ⇒ 它恒假、会红），改成 `>= 1` 或直接按 `_build_menu_buttons` 里的那一颗判。

- [ ] **Step 4: 跑自检**

```bash
"$GODOT" --headless --path . --quit-after 200 -- --autotest-mp
"$GODOT" --headless --path . --quit-after 200 -- --autotest-royale
"$GODOT" --headless --path . --quit-after 200 -- --autotest-team
```

期望：三条各打 `AUTOTEST[<mode>]: DONE` 且**没有** `未抵达` 那一行。

- [ ] **Step 5: 提交**

```bash
git add scenes/main_menu.gd scenes/beta_menu.gd tests/smoke/menu_autotest.gd
git commit -m "feat(menu): 联机入口收成一颗「多 人 模 式」→ mp_lobby

Beta 页两张卡改指向统一大厅 + 预选模式。menu_autotest 的
mp/royale/team 三模式改按同一颗按钮、must_reach 指向同一场景。"
```

---

## Task 7: 退役三个旧页 + 改其余守卫

**Files:**
- Delete: `scenes/matchmaking.{gd,tscn}` / `scenes/royale_lobby.{gd,tscn}` / `scenes/team_lobby.{gd,tscn}`（含三个 `.gd.uid`）
- Modify: `tests/smoke/lobby_parse_smoke.gd`、`tests/smoke/reconnect_smoke.gd`、`tests/smoke/room_sweep_smoke.gd`、`tests/probe/kh_l5_probe.gd`、`tests/probe/{rejoin_probe,royale_bound_probe,royale_c2_probe,royale_soak_probe,team_match_probe,lobby_visibility_probe}.gd`、`tests/harness/{ground_net_watcher,team_match_watcher,royale_c2_watcher,royale_bound_watcher,rejoin_watcher}.gd`、`server/lobby/room_manager.gd`（注释）、`scenes/pvp_match_client.gd`（注释）

**Interfaces:**
- Consumes: 前六个任务的全部产出

- [ ] **Step 1: 先跑一遍全量，拿到"删之前"的基线**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/smoke/lobby_parse_smoke.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_wait_room_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/reconnect_smoke.gd
"$GODOT" --headless --path . -s res://tests/smoke/room_sweep_smoke.gd
```

期望：**九条全绿**。任何一条红 = 前六个任务有欠账，先修它，别往下走。

- [ ] **Step 2: 删三个旧页**

```bash
git rm scenes/matchmaking.gd scenes/matchmaking.gd.uid scenes/matchmaking.tscn \
       scenes/royale_lobby.gd scenes/royale_lobby.gd.uid scenes/royale_lobby.tscn \
       scenes/team_lobby.gd scenes/team_lobby.gd.uid scenes/team_lobby.tscn
```

- [ ] **Step 3: 改 `lobby_parse_smoke`**

`tests/smoke/lobby_parse_smoke.gd:9` 的 `TARGETS` 换成：

```gdscript
const TARGETS := [
	"res://scenes/mp_lobby.tscn",
]
```

- [ ] **Step 4: 改 `room_sweep_smoke`（★ 最要紧的一处）**

`tests/smoke/room_sweep_smoke.gd:454-469`：把两处 `res://scenes/royale_lobby.gd` 换成 `res://scenes/mp_lobby.gd`，报错文案同步改（`无法读取 scenes/mp_lobby.gd` / `mp_lobby.gd 里找不到 "match_time" 那一行`）。文件头 `:31-39` 与 `:446-450` 里所有对 `royale_lobby.gd` 的指名同步改。

★★ **这一条漏改 = `ROYALE_MATCH_TIME_CEILING` 静默失效**。改完必须**变异验证**：把 `mp_lobby.gd` 里 `Settings.royale_match_min * 60.0` 那一行的 `* 60.0` 删掉，跑 `room_sweep_smoke` 必须**红**；再还原。

- [ ] **Step 5: 改 `reconnect_smoke` 的页面常量**

`tests/smoke/reconnect_smoke.gd:41-43`：

```gdscript
const PAGE_MP := "res://scenes/mp_lobby.gd"
```

（删 `PAGE_1V1` / `PAGE_ROYALE` / `PAGE_TEAM`，把它们的读点全换成 `PAGE_MP`。）

`:222` 的清单换成 `[LOBBY_PAGE, PAGE_MP]`；`:317-318` 的"三页各自 note_room"改成"mp_lobby 走 note_room"。

- [ ] **Step 6: 改 `kh_l5_probe`**

`tests/probe/kh_l5_probe.gd:55`：

```gdscript
const L5_FONT_FILES := ["res://ui/hud/royale_hud.gd", "res://scenes/mp_lobby.gd"]
```

- [ ] **Step 7: 改其余引用**

按 `grep -rn "matchmaking\|royale_lobby\|team_lobby" --include=*.gd .` 的结果逐条替换（**排除** `scenes/*.gd.uid` 与 `docs/`）：

- `tests/probe/lobby_visibility_probe.gd`：相⑤⑥⑦⑧⑨ 挂的页换成 `mp_lobby`；`_check_page` 那类的三页循环收敛成一页；相⑧ 的**次序断言与它的正向对照必须原样保留**（那是用一次全绿事故换来的）。
- `tests/probe/rejoin_probe.gd` / `royale_bound_probe.gd` / `royale_c2_probe.gd` / `royale_soak_probe.gd` / `team_match_probe.gd`：场景路径换成 `mp_lobby.tscn`。
- `tests/harness/*.gd`（5 个 watcher）：按脚本名匹配的地方换成 `mp_lobby.gd`。
- `server/lobby/room_manager.gd:43-45`、`scenes/pvp_match_client.gd:1073`：注释里的文件名。

- [ ] **Step 8: 全量重跑（与 Step 1 同九条）**

期望：九条**全绿**。另外补一条 grep（应当**零命中**，`docs/` 与 `.superpowers/` 除外）：

```bash
grep -rn "matchmaking\|royale_lobby\|team_lobby" --include=*.gd --include=*.tscn . \
  | grep -v "^./.claude/worktrees" | grep -v "^./docs/" | grep -v "^./.superpowers/"
```

- [ ] **Step 9: 提交**

★★ **不要 `git add -A scenes tests server`**（本计划初稿就是这么写的，**是错的**）—— 我们与另一个
Claude 会话共用这棵工作树，而它在改 `scenes/enemies/*`。按目录 add 会把**它的**改动一起带走。
一律**逐个文件点名**，把本任务真正动过的文件列全（`git rm` 那 9 个已由上一步入索引，这里只需补其余）：

```bash
git add tests/smoke/lobby_parse_smoke.gd tests/smoke/reconnect_smoke.gd \
        tests/smoke/room_sweep_smoke.gd \
        tests/probe/kh_l5_probe.gd tests/probe/lobby_visibility_probe.gd \
        tests/probe/rejoin_probe.gd tests/probe/royale_bound_probe.gd \
        tests/probe/royale_c2_probe.gd tests/probe/royale_soak_probe.gd \
        tests/probe/team_match_probe.gd \
        tests/harness/ground_net_watcher.gd tests/harness/team_match_watcher.gd \
        tests/harness/royale_c2_watcher.gd tests/harness/royale_bound_watcher.gd \
        tests/harness/rejoin_watcher.gd \
        server/lobby/room_manager.gd scenes/pvp_match_client.gd
git status --short    # ★ 提交前看一眼:凡不是你改的文件(尤其 scenes/enemies/*)一律别加
git commit -m "refactor(lobby): 三个旧大厅页退役,守卫改指 mp_lobby

删 matchmaking / royale_lobby / team_lobby(含 .uid)。
★ room_sweep_smoke 的上界链环二改读 mp_lobby.gd —— 漏改 = 大乱斗时长上界
  静默失效,已按变异验证(删掉 * 60.0 必须变红)。"
```

---

## 收尾检查（全部任务完成后跑一次）

- [ ] **全量回归**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/enemy_logic_smoke.gd
"$GODOT" --headless --path . -s res://tests/smoke/reconnect_smoke.gd
"$GODOT" --headless --path . -s res://tests/smoke/room_sweep_smoke.gd
"$GODOT" --headless --path . -s res://tests/smoke/team_room_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_wait_room_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
```

- [ ] **真链路（用户自己跑，占 7777 / 端口池）**

```bash
tests/smoke/pvp_room_smoke.sh
tests/probe/rejoin_probe.sh
```

★ 两支之间必须确认 `tasklist | grep -i godot` 为空（worker 是孙进程，孤儿会毒害下一支）。

- [ ] **更新 `CLAUDE.md`**

把「三个大厅页」相关的段落改成统一大厅的描述：§网络与PvP 的入口段、§UI 的「两个大厅页共用 `scenes/lobby_page.gd` 基类」一段、以及任何写着 `matchmaking` / `royale_lobby` / `team_lobby` 的地方。

---

## 已知边界（本计划**不**处理的，别顺手做）

1. **地图的两处真值**：列表上是 `room_map` 上报的快照，真正定图的仍是报到时 role1 的 `player_options.map`。房主建房后改设置会让两者不一致 —— 统一它要动 worker 的定图路径，超出本计划（设计 §6 第 3 条）。
2. **列表刷新延迟由最慢那条 RPC 决定**（三条并发）。
3. **视觉重做不在本计划**：本计划一律用现有 `UiFactory` 的既有 token；换皮是计划 ③。
4. **设置页「联机显示」与信息页**是计划 ②。
5. **`lobby_row_probe` 的覆盖上限**：它只断言 `mp_lobby` 画出来的卡，**不**断言三条 RPC 真的发出去了（那一半靠真链路脚本）。
