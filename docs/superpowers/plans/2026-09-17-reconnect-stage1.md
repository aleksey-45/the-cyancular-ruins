# 断线重连【阶段 1】实施计划（token + 宽限期 + reclaim + 局内自动重连）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 1v1 与 大乱斗的客户端在**与 worker 的连接闪断**后，能在宽限期内自动回到原局；掉线期间其身体留在场上不动。

**Architecture:** 三块 —— ①**大厅生成一次性 token**，客户端转连 worker 前经 `NetBusExt` 收到、claim 时报给 worker（`go_match`/`claim_role` 签名一律不动）；②worker 侧一个**宽限期状态机**：掉线不立刻移出（大乱斗）也不立刻退进程（1v1），而是把该 role 的输入源置空、记到期时刻，到点才走既有"移出/收场"语义；③新增 `NetBusExt.reclaim_role(role, token)`，宽限期内校验 token 后**重绑 peer 与输入源**。因为身体从不销毁，服务端的对局状态**一条都不用恢复**。

**Tech Stack:** Godot 4.7.1 GDScript；ENet（`NetBus` / `NetBusExt` 两条 autoload RPC 通道）；`-s` 冒烟（`extends SceneTree`）与 `tests/*.tscn` 场景探针。

## Global Constraints

- **本项目约定：测试由用户自己跑，不要代跑。** 计划里每条 `Run:` 是**写给用户**的；agent 只负责改代码，除非用户明确说"你跑一下"。agent 能自己执行的是 `--import`（刷类缓存）与 `node level_editor/*.js`（生成器）。
- **引擎路径**：`$GODOT` = console 版（未设时回落 `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`）。
- **新建 `class_name` 文件后必须 `--import` 刷全局类缓存**，否则引用处 Parse Error。
- **`-s` 冒烟必须写空载守卫**：`load()` 后立刻 `if X == null: print(...); quit(1); return`（抛错走不到 `quit()` = 进程永久挂起）；跑时套 `timeout`。
- **场景探针 `--quit-after` 一律 3600 帧**；判据 grep 文本 `ALL-OK`，不看退出码。
- **★ `NetBus` 的方法表一律不动**（硬纪律：原 NetBus 要与原版服务端逐字节一致，改方法表会让与之的 RPC 全部失联）。本阶段所有新 RPC 都进 `NetBusExt`。
- **提交信息用单引号或 `-F 文件`**，别在双引号里放反引号/`$`；提交后回读。
- 每次提交只 `git add` 本任务提到的文件。工作区有未跟踪的 `_crashtest/`，**不要动**。
- **字号只用 16 的倍数**（`kh_l4/l5` 会扫 `res://tests`）。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `core/net/grace_window.gd` (+`.uid`) | **新建** | 宽限期表：`enter/leave/has/expired/size`。纯逻辑、不读时钟 |
| `tests/grace_window_smoke.gd` (+`.uid`) | **新建** | `-s` 冒烟钉 `GraceWindow` 语义 |
| `core/net/net_bus_ext.gd` | 修改 | 新增 3 条 RPC + 3 个信号（`session_token` / `report_token` / `reclaim_role`） |
| `core/net/pvp_session.gd` | 修改 | 新增 `token` / `worker_port` 两个**有读者**的字段 |
| `server/lobby_rooms.gd` | 修改 | `Room`/`RoyaleRoom` 加 `in_match` + `tokens`；生成 token 的收口 |
| `server/room_manager.gd` | 修改 | 三处 spawn 后**先发 token 再发 go_match** |
| `scenes/lobby_page.gd` | 修改 | 接 `session_token`，`_do_go_match` 落到 `PvpSession`；claim 时报给 worker |
| `server/server_main.gd` | 修改 | 宽限期状态机 + `reclaim_role` 处理 + 收 token |
| `scenes/pvp_match_client.gd` | 修改 | 断开检测 + 自动重连 + reclaim + 重置 C2 |
| ~~`scenes/pvp_game.gd`~~ | **本阶段不改** | 「重连中…」可见提示归 spec **阶段 3**（见 Task 6 Step 4 的理由） |
| `server/worker_launcher.gd` | 修改 | `WORKER_PORT_REUSE_DELAY` 30 → 120（≥ 宽限期） |
| `tests/reconnect_smoke.gd` (+`.uid`) | **新建** | `-s` 源码级：三条 RPC 在 NetBusExt 且**不在** NetBus；PvpSession 字段在位 |
| `tests/reconnect_probe.tscn/.gd` (+`.uid`) | **新建** | 真链路：掉线 → 身体留场且冻结 → reclaim 成功/错 token 被拒 → 宽限到点移出 |
| `CLAUDE.md` | 修改 | §网络与 PvP 新增一节 |

---

## Task 1: `GraceWindow`（纯逻辑 + 冒烟）

**Files:**
- Create: `core/net/grace_window.gd`
- Test: `tests/grace_window_smoke.gd`

**Interfaces:**
- Produces: `GraceWindow.DEFAULT_SECONDS: float`；`enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void`；`has(role: int) -> bool`；`leave(role: int) -> void`；`expired(now_ms: int) -> Array[int]`；`size() -> int`

- [ ] **Step 1: 写失败的测试 `tests/grace_window_smoke.gd`**

```gdscript
extends SceneTree

# 宽限期表冒烟:进入/到期/续期/离开/确定性排序。
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd
# 通过 = `GRACE_WINDOW OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 时间是**参数**不是时钟 —— 本类刻意不读 Time.get_ticks_msec(),否则冒烟只能靠 sleep,
#   既慢又不确定。这里全部用假时间推进。
# ★ 到期判据是 `now >= until`(**含边界**):边界取 > 会让"正好到点"永远不算到期,
#   而宽限期常量取 0 时那条分支就永不触发(不可反证的历史教训,同 attribute 的时效窗口)。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _initialize() -> void:
	var G: GDScript = load("res://core/net/grace_window.gd")
	# ★ 空载守卫:load() 失败还往下走会抛错,而 -s 抛错走不到 quit() → 永久挂起
	if G == null:
		print("GRACE_WINDOW FAILED: 找不到 core/net/grace_window.gd")
		quit(1)
		return
	var w = G.new()

	# ── ① 没进过 → has false、expired 空 ──
	_check(not w.has(1), "没进过的 role 不应在宽限期里")
	_check(w.expired(999999) == [], "空表 expired 应为空")

	# ── ② 进入 → 到期前不 expired、到期(含边界)才 expired ──
	w.enter(1, 1000, 30.0)          # 到期 = 31000
	_check(w.has(1), "enter 后 has 应为 true")
	_check(w.size() == 1, "size = 1(实际 %d)" % w.size())
	_check(w.expired(30999) == [], "到期前不得 expired")
	var e1: Array = w.expired(31000)
	_check(e1 == [1], "★ 正好到点(now == until)必须 expired(实际 %s)" % str(e1))

	# ── ③ leave 后立刻不在表里(即使还没到期)──
	w.leave(1)
	_check(not w.has(1), "leave 后 has 应为 false")
	_check(w.size() == 0, "leave 后 size = 0")

	# ── ④ 多个 role 同时到期 → 按 role 升序返回(确定性;字典迭代顺序不保证)──
	w.enter(3, 0, 1.0)              # 到期 1000
	w.enter(1, 0, 1.0)
	w.enter(2, 0, 1.0)
	var e2: Array = w.expired(1000)
	_check(e2 == [1, 2, 3], "多个到期应按 role 升序(实际 %s)" % str(e2))

	# ── ⑤ 重新掉线 = 刷新到期时刻(不是叠加)──
	w.enter(1, 5000, 30.0)          # 到期 35000
	w.enter(1, 20000, 30.0)         # 到期 50000
	_check(w.expired(35000) == [], "重复 enter 应刷新到期时刻,不是叠加/取旧")
	_check(w.expired(50000) == [1, 2, 3], "新到期时刻生效(实际 %s)" % str(w.expired(50000)))

	# ── ⑥ 时长用常量默认值时也算得出(防"默认参数写错导致永不进表")──
	var w2 = G.new()
	w2.enter(7, 0)
	_check(w2.has(7), "用默认时长 enter 后也应在表里")
	_check(w2.expired(int(G.DEFAULT_SECONDS * 1000.0)) == [7], "默认时长到期应可算")
	_check(w2.expired(int(G.DEFAULT_SECONDS * 1000.0) - 1) == [], "默认时长到期前 1ms 不应 expired")

	if _fail == 0:
		print("GRACE_WINDOW OK")
		quit(0)
	else:
		print("GRACE_WINDOW FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑一次确认它红**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW FAILED: 找不到 core/net/grace_window.gd`，退出 1。

- [ ] **Step 3: 写 `core/net/grace_window.gd`**

```gdscript
class_name GraceWindow
extends RefCounted

# 掉线宽限期表(纯逻辑、无 autoload、`-s` 可测)。
#
# 语义:某 role 掉线后 `enter`;宽限内它可以被 `reclaim_role` 重连;`expired` 报出到期仍未
# 回来的 role,由调用方走既有的"移出对局"语义。`leave` 是"这件事结束了"的完成信号
# (重连成功 / 主动移出 / 服务端收场,三处都调)。
#
# ★ **时间由调用方传入(ms),本类不读时钟** —— 否则冒烟只能靠 sleep。
# ★ 到期判据是 `now >= until`(**含边界**):取 > 会让"正好到点"永不算到期,
#   而时长取 0 时那条分支永不触发(同 CombatFeedback.ATTRIB_WINDOW_MS 的注释)。
# ★ 重复 enter 是**刷新**到期时刻,不叠加 —— 掉线两次不该得到两倍宽限。

const DEFAULT_SECONDS := 30.0   # ★ 宽限期时长的唯一入口(改时长只改这里)

var _until: Dictionary = {}     # role(int) -> 到期时刻 ms


# 进入宽限。seconds 默认走常量;重复调用刷新到期时刻。
func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


# "这件事结束了":重连成功 / 主动移出 / 收场,三处都调它。
func leave(role: int) -> void:
	_until.erase(int(role))


# 已到期的 role,**按 role 升序**(字典迭代顺序不保证,排序是为了确定性)。
# 调用方拿到后应自行 `leave()` —— 本类不改调用方的对局状态。
func expired(now_ms: int) -> Array[int]:
	var out: Array[int] = []
	for r in _until:
		if now_ms >= int(_until[r]):
			out.append(int(r))
	out.sort()
	return out


func size() -> int:
	return _until.size()
```

- [ ] **Step 4: 刷类缓存**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 `Could not resolve class` 报错；生成 `core/net/grace_window.gd.uid` 与 `tests/grace_window_smoke.gd.uid`。

- [ ] **Step 5: 跑冒烟确认绿**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/grace_window_smoke.gd`
Expected: `GRACE_WINDOW OK`，退出 0。

- [ ] **Step 6: 提交**

```bash
git add core/net/grace_window.gd core/net/grace_window.gd.uid tests/grace_window_smoke.gd tests/grace_window_smoke.gd.uid
git commit -m 'feat(net): GraceWindow 宽限期表(纯逻辑)+ 冒烟'
```

---

## Task 2: `NetBusExt` 三条新 RPC + `PvpSession` 两个字段

**Files:**
- Modify: `core/net/net_bus_ext.gd`（末尾追加）
- Modify: `core/net/pvp_session.gd`（字段区）
- Test: `tests/reconnect_smoke.gd`

**Interfaces:**
- Consumes: 无
- Produces:
  - `NetBusExt.session_token(token: String)`（`@rpc("authority","reliable")`）+ 信号 `local_session_token(token: String)`
  - `NetBusExt.report_token(token: String)`（`@rpc("any_peer","reliable")`）+ 信号 `token_reported(caller: int, token: String)`
  - `NetBusExt.reclaim_role(role: int, token: String)`（`@rpc("any_peer","reliable")`）+ 信号 `reclaim_requested(caller: int, role: int, token: String)`
  - `PvpSession.token: String`、`PvpSession.worker_port: int`

- [ ] **Step 1: 写失败的测试 `tests/reconnect_smoke.gd`**

```gdscript
extends SceneTree

# 重连协议的**源码级**契约冒烟:
#   ① 三条新 RPC 必须住在 NetBusExt,**且 NetBus 里一个都不许有**(放错节点 = 静默 no-op)
#   ② PvpSession 的两个新字段在位(重连要靠它们)
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/reconnect_smoke.gd
# 通过 = `RECONNECT SMOKE OK` 退出 0。
#
# ═══ 为什么是源码级 ═══
# ★ RPC 放错节点**不会报错**:原 NetBus 与原版服务端逐字节一致是硬纪律,而 NetBusExt 对
#   原版 worker 不存在 → 放错的 RPC 静默丢弃、优雅降级。症状是"重连永远失败"却一行错都不打。
#   同款先例:weapon_spawned/weapon_removed 的 node 归属由 tests/net_ground_probe 双向钉住
#   (**缺了要红、多了也要红**)。这里照抄那条纪律。

const NETBUS := "res://core/net/net_bus.gd"
const NETBUS_EXT := "res://core/net/net_bus_ext.gd"
const SESSION := "res://core/net/pvp_session.gd"

# 本次新增的三条:必须在 Ext,不得在 NetBus
const N_EXT_RPCS := ["session_token", "report_token", "reclaim_role"]

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 剥掉 `#` 注释与字符串外的空白,只留代码本体 —— 否则注释里提到的方法名会假绿
func _code(text: String) -> String:
	var out := ""
	for line in text.split("\n"):
		var i := line.find("#")
		out += (line if i < 0 else line.substr(0, i)) + "\n"
	return out


# 该文件里有没有 `func <name>(` 定义
func _defines(code: String, name: String) -> bool:
	return code.contains("func %s(" % name)


func _initialize() -> void:
	var ext := _code(_read(NETBUS_EXT))
	var bus := _code(_read(NETBUS))
	var ses := _code(_read(SESSION))
	_check(not ext.is_empty(), "读不到 %s" % NETBUS_EXT)
	_check(not bus.is_empty(), "读不到 %s" % NETBUS)
	_check(not ses.is_empty(), "读不到 %s" % SESSION)

	for n in N_EXT_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)

	# 三个信号也要在(worker/客户端都靠信号解耦)
	for s in ["local_session_token", "token_reported", "reclaim_requested"]:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)

	# PvpSession 两个字段:必须 `static var`(本类全是静态)
	for f in ["token", "worker_port"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)

	if _fail == 0:
		print("RECONNECT SMOKE OK")
		quit(0)
	else:
		print("RECONNECT SMOKE FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑一次确认它红**

Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE FAILED: 6`（三条 RPC × 2 条断言全红）。

- [ ] **Step 3: 在 `core/net/net_bus_ext.gd` 末尾追加三条 RPC**

```gdscript
# ── 断线重连(2026-09-17)──
# ★ 全部进本节点,理由见文件头:原 NetBus 的方法表一律不动(改了会让与原版服务端的 RPC
#   全部失联)。对原版 worker 本节点不存在 → 这三条静默丢弃,优雅降级成"不能重连"。
#
# 一次性会话令牌:大厅生成(它必须知道 token,否则"回大厅后回局"无法把客户端对回那一局),
# 在客户端**转连 worker 之前**下发(必须早于 go_match —— go_match 一到客户端就 NetBus.stop()
# 断大厅,之后再发就丢了)。两者都是 reliable 同通道,保序到达。
signal local_session_token(token: String)

@rpc("authority", "reliable")
func session_token(token: String) -> void:
	local_session_token.emit(token)

# 客户端 → worker:把 token 报到本局(claim 之后立刻发)。worker 存 role→token 供日后核验。
signal token_reported(caller: int, token: String)

@rpc("any_peer", "reliable")
func report_token(token: String) -> void:
	token_reported.emit(multiplayer.get_remote_sender_id(), token)

# 客户端 → worker:宽限期内重新认领自己那个 role。token 不对一律拒(并踢连接)。
signal reclaim_requested(caller: int, role: int, token: String)

@rpc("any_peer", "reliable")
func reclaim_role(role: int, token: String) -> void:
	reclaim_requested.emit(multiplayer.get_remote_sender_id(), role, token)
```

- [ ] **Step 4: 在 `core/net/pvp_session.gd` 加两个字段**

在 `static var spawn` 那一行之后插入：

```gdscript
# ── 断线重连(2026-09-17)──
# ★ 与本文件的其他字段一样:**加之前先 grep 确认有读者**。
#   token      : 大厅生成、随 session_token 下发;claim 时报给 worker;重连时用来 reclaim
#   worker_port: 客户端重连要直连**同一个端口**,不重新走大厅(局内自动重连那条路径)
static var token: String = ""
static var worker_port: int = 0
```

并同步 `reset()`（`:41-45`）—— 加两行，否则换模式时会带着上一局的 token 去连新局：

```gdscript
	token = ""
	worker_port = 0
```

- [ ] **Step 5: 刷类缓存并确认冒烟转绿**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 60 "$GODOT" --headless --path . -s res://tests/reconnect_smoke.gd`
Expected: `RECONNECT SMOKE OK`。

- [ ] **Step 6: 提交**

```bash
git add core/net/net_bus_ext.gd core/net/pvp_session.gd tests/reconnect_smoke.gd tests/reconnect_smoke.gd.uid
git commit -m 'feat(net): NetBusExt 重连三 RPC + PvpSession.token/worker_port + 源码级契约冒烟'
```

---

## Task 3: 大厅生成 token 并在 `go_match` **之前**下发

**Files:**
- Modify: `server/lobby_rooms.gd`（`Room`/`RoyaleRoom` 加字段 + 生成收口）
- Modify: `server/room_manager.gd`（三处 spawn 后先发 token 再发 go_match）
- Modify: `scenes/lobby_page.gd`（接 token → `PvpSession`）

**Interfaces:**
- Consumes: `NetBusExt.session_token`（Task 2）
- Produces: `LobbyRooms.new_token() -> String`（静态）；`Room.tokens: Dictionary`、`RoyaleRoom.tokens: Dictionary`（peer → token）；客户端 `PvpSession.token` 在 `_do_go_match` 时已就位

- [ ] **Step 1: 在 `server/lobby_rooms.gd` 的 `Room` / `RoyaleRoom` 各加一个 `tokens` 字段**

`Room`（现 `:28-34`）与 `RoyaleRoom`（现 `:40-53`）各加一行：

```gdscript
	var tokens: Dictionary = {}          # peer_id -> 一次性会话令牌(断线重连用;开局时按 role 下发)
```

- [ ] **Step 2: 在 `server/lobby_rooms.gd` 加 token 生成收口**

放在 `_generate_code`（`:94-95`）附近，同一条纪律（生成逻辑单一来源）：

```gdscript
# 一次性会话令牌(16 位 hex)。★ 旧 Godot 的 `randi()` 是 32 位,拼两次取 16 hex 得 64 位熵 ——
# 够防"误顶替"(同网段知道房号的人猜不中),**不防**恶意爆破(本设计不承担反作弊,见 spec §2)。
static func new_token() -> String:
	return "%016x" % ((int(randi()) << 32) | (int(randi()) & 0xFFFFFFFF))
```

- [ ] **Step 3: 在 `server/room_manager.gd` 的三处 spawn 后、`go_match` 前下发 token**

三处：`royale_start`（现 `:57-75`）、`royale_start_ai`（`:142-158`）、`_start_match`（`:165-181`）。
**共同做法**：在 `pick_port` 成功后立刻为每个参战 peer 生成 token 并写进房间记录，然后**在 spawn 之前**发（早于 go_match 是硬要求，见 Task 2 注释）。

以 `_start_match` 为例，在 `room.worker_port = port`（现 `:172`）与 `_launcher.spawn_worker(port)`（`:173`）**之间**插入：

```gdscript
	# ★ token 必须在 **go_match 之前**发到客户端:go_match 一到客户端就 NetBus.stop() 断大厅,
	#   之后再发就静默丢失(Task 2 的 session_token 注释)。spawn 之前发则一定更早。
	for pid in room.players:
		var tk := LobbyRooms.new_token()
		room.tokens[pid] = tk
		if lobby.is_peer_online(pid):
			NetBusExt.rpc_id(pid, "session_token", tk)
```

`royale_start` / `royale_start_ai` 同款（把 `room.players` 换成 `rr.players`、`rr.tokens`）。

- [ ] **Step 4: 修 `_send_go_match*` —— 把 token 附在 `go_match` 之后的时序断言**

不需要改发送代码，但**必须在 `_send_go_match_1v1` / `_send_go_match` 的注释里写死时序**（防后人把 token 挪到后面）。在 `_send_go_match_1v1`（现 `:186-192`）函数头加：

```gdscript
# ★ token 由调用方在 **spawn 之前**已经发出(见 `_start_match` 里那段注释)。本函数只发
#   go_match —— 客户端收到它就 NetBus.stop() 断大厅,所以任何"跟着 go_match 一起发"的
#   载荷都必须更早。别把 token 挪到这里。
```

- [ ] **Step 5: 客户端接 token（`scenes/lobby_page.gd`）**

在 `_on_go_match`（现 `:252-257`）**之前**新增接收与暂存：

```gdscript
# 大厅在 go_match **之前**下发的一次性会话令牌(断线重连用)。
# ★ 先存进 `_pending_token` 而不是直接写 PvpSession:go_match 也是本帧到达的,两者由
#   `_do_go_match.call_deferred` 在帧末一起落到 PvpSession,顺序就不会被 RPC 到达次序左右。
var _pending_token := ""

func _on_session_token(token: String) -> void:
	_pending_token = token
```

并在 `_connected` 建立时连接信号（`lobby_page.gd` 里已有一处 `NetBus.local_go_match.connect(...)`，照抄一行）：

```gdscript
	NetBusExt.local_session_token.connect(_on_session_token)
```

`_do_go_match`（现 `:260-277`）里，在 `PvpSession.role = role` 之后补两行：

```gdscript
	PvpSession.token = _pending_token
	PvpSession.worker_port = port      # 局内自动重连要直连同一个端口
	_pending_token = ""
```

- [ ] **Step 6: claim 时把 token 报给 worker**

`_claim_role_worker`（现 `:279-284`）里，`player_options` 那一行后面补：

```gdscript
	# token 走扩展节点(原 NetBus 的 claim_role 签名一律不动)。原版 worker 无本节点 →
	# 静默丢弃 → 那局就是"不能重连",不影响对局本身。
	if PvpSession.token != "":
		NetBusExt.rpc_id(1, "report_token", PvpSession.token)
```

- [ ] **Step 7: `--import` 并让用户跑一遍大厅链路冒烟**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`bash tests/pvp_room_smoke.sh`（建房/加入/开局；**跑前确认 7777 空闲**）
Expected: 通过（本步只证明**没有把现有配对链路改坏**；token 是否送达由 Task 8 的真链路探针证明）。

- [ ] **Step 8: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd scenes/lobby_page.gd
git commit -m 'feat(net): 大厅生成一次性 token 并在 go_match 之前下发;客户端 claim 时报给 worker'
```

---

## Task 4: worker 侧宽限期状态机

**Files:**
- Modify: `server/server_main.gd`（新增字段 + `_on_peer_left` 改宽限 + `_process` 到期轮询 + 收 token）

**Interfaces:**
- Consumes: `GraceWindow`（Task 1）、`NetBusExt.token_reported`（Task 2）
- Produces: `server_main._grace: GraceWindow`、`_tokens: Dictionary`（role → token）；私有 `_enter_grace(role) -> void`、`_expire_graces(now_ms) -> void`

- [ ] **Step 1: 加字段**

在 `server/server_main.gd` 的 `var _match_started := false`（现 `:27`）之后：

```gdscript
# ── 断线宽限期(2026-09-17,断线重连)──
# 掉线的 role 先进 `_grace`,不立刻移出(大乱斗)/不立刻退进程(1v1);宽限内可被 reclaim_role
# 认领回来。到点仍未回来 → 走既有的"移出对局 / 收场退出"语义。
# ★ 时长唯一入口是 `GraceWindow.DEFAULT_SECONDS`。
var _grace := GraceWindow.new()
var _tokens: Dictionary = {}   # role(int) -> token(String),客户端经 report_token 报来
```

- [ ] **Step 2: 收 token**

在 `_on_player_options`（现 `:204-208`）之后新增：

```gdscript
# 客户端 claim 之后立刻报来的一次性令牌(claim 与它同一次 poll 到达)。按 caller 反查 role 归档。
# ★ 只归档,不在这里校验 —— 校验发生在宽限期里的 reclaim_role(那时才有"该不该放行"的问题)。
func _on_token_reported(caller: int, token: String) -> void:
	for r in _claims:
		if _claims[r] == caller:
			_tokens[int(r)] = token
			return
```

并在 `_run_worker` 挂信号处（现 `:167-171` 那一批）加一行：

```gdscript
	NetBusExt.token_reported.connect(_on_token_reported)
```

- [ ] **Step 3: 改 `_on_peer_left` —— 大乱斗分支进宽限而非直接移出**

把现 `:335-350` 的大乱斗分支整段替换为：

```gdscript
		if _royale:
			# 大乱斗:单个参与者掉线 = **先进宽限期**(不立刻移出,身体留在场上),
			# 宽限内可被 reclaim_role 认领回来;到点仍未回来才走 mark_disconnected。
			# ★ 身体不销毁是本设计最省的一处:分数/阵亡/血量/背包/位置/世界破坏/地面武器
			#   全在活着的节点与进程内存里,一条都不用恢复(见 spec §4)。
			var role := 0
			for r in _claims:
				if _claims[r] == peer_id:
					role = int(r)
					break
			if role == 0:
				return
			_claims.erase(role)
			_enter_grace(role)
			if _claims.is_empty() and _grace.size() == 0:
				print("worker: 全员离开,大乱斗结束")
				get_tree().quit(0)
			else:
				print("worker: 玩家掉线进宽限(剩 %d 人在线)" % _claims.size())
			return
```

- [ ] **Step 4: 改 `_on_peer_left` —— 1v1 分支进宽限而非退进程**

把现 `:351-354` 整段替换为：

```gdscript
		# 1v1:一方掉线**不再拆局退进程** —— 进宽限期等它回来(spec §3.2)。
		# ★ 这是 1v1 能做重连的**前提**:原实现 `_host.queue_free()` + `quit(0)` 会让进程
		#   直接消失,对局状态随之蒸发,重连无从谈起。
		var role1 := 0
		for r in _claims:
			if _claims[r] == peer_id:
				role1 = int(r)
				break
		if role1 == 0:
			return
		_claims.erase(role1)
		_enter_grace(role1)
		print("worker: 玩家掉线进宽限(1v1)")
		return
```

- [ ] **Step 5: 写 `_enter_grace` 与到期轮询**

```gdscript
# 把一个 role 放进宽限期。★ 必须**置空它的输入源**:
# `PacketInputSource` 在队列空时沿用上一包(held,见 match_host 的每 tick 消费注释),
# 不置空的话掉线者的身体会保持他断开前最后一帧的输入 —— 一直朝那个方向跑、或一直开枪。
func _enter_grace(role: int) -> void:
	_grace.enter(role, Time.get_ticks_msec())
	if _host != null:
		var src = _host.input_sources.get(role, null)
		if src != null and src.has_method("reset_state"):
			src.reset_state()
		_host.peer_by_role.erase(role)
		if _host.has_method("_broadcast_round_state"):
			_host._broadcast_round_state()   # 让 HUD 显示"某人掉线中"


# 到期仍未回来的 role → 走既有语义。每秒轮询一次即可(精度无关,宽限期以秒计)。
func _expire_graces(now_ms: int) -> void:
	for role in _grace.expired(now_ms):
		_grace.leave(role)
		if _royale:
			if _host != null and _host.has_method("mark_disconnected"):
				_host.mark_disconnected(role)
		else:
			# 1v1:宽限内没回来 → 收场退进程(原行为,只是晚了几十秒)
			if is_instance_valid(_host):
				_host.queue_free()
			print("worker: 1v1 宽限期到,对手未归,对局结束")
			get_tree().quit(0)
```

并在 `_process`（现 `:188-201`）**开头**插入轮询（在两条大乱斗梯之前，两者互不影响）：

```gdscript
	# 宽限期到期轮询(每秒一次足够;不与下面两条大乱斗的报到梯纠缠)
	_grace_check_timer += delta
	if _grace_check_timer >= 1.0:
		_grace_check_timer = 0.0
		_expire_graces(Time.get_ticks_msec())
```

配套加一个累加器字段（放在 Step 1 那两个字段旁边）：

```gdscript
var _grace_check_timer := 0.0
```

- [ ] **Step 6: 让用户跑现有的 1v1 / 大乱斗 冒烟，确认没把既有链路改坏**

Run（**让用户跑**）：
```bash
bash tests/pvp_match_smoke.sh
bash tests/pvp_room_smoke.sh
```
Expected: 全过。★ 注意 `pvp_match_smoke` 会走"一方离开"的路径 —— 改后它不再立刻退进程，而是**等 30s 宽限**。若该脚本因此超时，把它收尾用的等待改成"接受宽限行为"（脚本里加长等待或直接判 worker 仍在监听），**不要为了让它过而把宽限期删掉**。

- [ ] **Step 7: 提交**

```bash
git add server/server_main.gd
git commit -m 'feat(net): worker 宽限期状态机(掉线不立刻移出/不退进程,输入源置空,到点走既有语义)'
```

---

## Task 5: worker 侧 `reclaim_role` 处理

**Files:**
- Modify: `server/server_main.gd`

**Interfaces:**
- Consumes: `GraceWindow`、`NetBusExt.reclaim_requested`、`_tokens`
- Produces: `server_main._on_reclaim(caller: int, role: int, token: String) -> void`；失败一律 `disconnect_peer(caller)`

- [ ] **Step 1: 写处理函数**

```gdscript
# 宽限期内重新认领 role(断线重连)。**三条拒绝条件一条都不能少**:
#   ① 没开局 —— 那时走正常 claim_role,不走这里
#   ② 该 role 不在宽限期里 —— 没掉线,或已超时移出(不允许"提前占坑"或"死后回归")
#   ③ token 不匹配 —— 防同网段的人顶替
# 任何一条不满足都**踢连接**(与 `_on_role_claimed` 的防串线同款):不能让它静默留在局里收快照。
func _on_reclaim(caller: int, role: int, token: String) -> void:
	var why := ""
	if not _match_started or _host == null:
		why = "尚未开局"
	elif not _grace.has(role):
		why = "该 role 不在宽限期"
	elif str(_tokens.get(role, "")) != token or token == "":
		why = "令牌不匹配"
	if why != "":
		print("worker: 拒绝 reclaim(role=%d,peer=%d):%s" % [role, caller, why])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	# ── 接受:重绑 peer 与输入源 ──
	# ★ **玩家节点不重建**:身体从未销毁(spec §3.2),所以服务端的对局状态一条都不用恢复。
	_claims[role] = caller
	_host.peer_by_role[role] = caller
	# ★ 换输入源**不是** `PacketInputSource.new(role, caller)` —— 它不收参数(`match_host.gd:34`
	#   的装配方式是 `var src := PacketInputSource.new()` 然后 `p.set_input_source(src)`)。
	#   所以要把新源**挂回那个还活着的玩家节点**,只换表里的引用是不够的(玩家手里仍攥着旧源)。
	var src := PacketInputSource.new()
	(_host.players[role] as Node2D).set_input_source(src)
	_host.input_sources[role] = src
	_host._pending_input[role] = []
	_host._ack_seq[role] = 0      # C2 锚点重协商:客户端 rollback ring 已失(见 spec §3.4)
	_grace.leave(role)
	# 回一条 match_start 让客户端重进对局场景(载荷与首次开局同源,不另造一份)。
	var sp: Vector2i = _host.role_spawns().get(role, Vector2i(-1, -1)) \
			if _host.has_method("role_spawns") else Vector2i(-1, -1)
	NetBus.rpc_id(caller, "match_start", role, sp, MazeGenerator.map_file_path())
	if _host.has_method("_broadcast_round_state"):
		_host._broadcast_round_state()
	print("worker: role %d 重连成功(peer=%d)" % [role, caller])
```

★ `MazeGenerator.map_file_path()` 已确认为公开静态（`core/sim/maze_generator.gd:18`），直接用。
★ `_host.players[role]` 在宽限期内**一直有效**（身体不销毁），可直接取用。

- [ ] **Step 2: 挂信号**

在 `_run_worker` 的挂信号处（Step 3 of Task 4 已加了一行 `token_reported`）再加：

```gdscript
	NetBusExt.reclaim_requested.connect(_on_reclaim)
```

- [ ] **Step 3: `--import` 自检**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error。（`PacketInputSource.new()` 无参 + `player.set_input_source(src)` 的装配方式已按 `server/match_host.gd:34/35` 查证；若 Godot 报未知标识符，先看 `core/net/packet_input_source.gd` 是否给了 `class_name`。）

- [ ] **Step 4: 提交**

```bash
git add server/server_main.gd
git commit -m 'feat(net): worker 侧 reclaim_role(三条拒绝条件 + 重绑 peer/输入源 + 重发 match_start)'
```

---

## Task 6: 客户端局内自动重连

**Files:**
- Modify: `scenes/pvp_match_client.gd`（断开检测 + 重试 + reclaim + 重置 C2）
- Modify: `scenes/pvp_game.gd`（「重连中…」提示的显隐）

**Interfaces:**
- Consumes: `PvpSession.token` / `worker_port`、`NetBusExt.reclaim_role`
- Produces: `PvpMatchClient._reconnecting: bool`、`_begin_reconnect() -> void`、`_try_reclaim() -> void`、`_abort_reconnect(reason: String) -> void`

- [ ] **Step 1: 加状态字段与常量（`scenes/pvp_match_client.gd`）**

放在 `_ground_nodes` 那一批字段附近：

```gdscript
# ── 断线重连(2026-09-17,spec §3.4 路径甲)──
const RECONNECT_RETRY_MS := 2000   # 重试间隔
var _reconnecting := false
var _reconnect_started_ms := 0
```

- [ ] **Step 2: 订阅服务器断开**

`NetBus` 已有 `local_server_message`（`net_bus.gd:65` 在 server_disconnected 时发 `"服务器断开"`）。
在 `pvp_match_client` 的订阅区（与 `NetBus.local_round_state.connect(...)` 同一批）加：

```gdscript
	# ★ 对局场景此前**没人订阅**这条(local_server_message 的消费者只有 lobby_page),
	#   所以服务器一断客户端毫无反应 —— 玩家卡在静止世界里只能按 ESC(spec §1.3 记录的既有缺陷)。
	NetBus.local_server_message.connect(_on_server_message)
```

```gdscript
func _on_server_message(msg: String) -> void:
	if _match_ended or _reconnecting:
		return
	if msg.contains("断开") or msg.contains("断开连接"):
		_begin_reconnect()
```

- [ ] **Step 3: 重连循环**

```gdscript
# 局内自动重连:不切场景、不重建世界 —— 本地世界原样保留,只把连接接回去。
# ★ 这条路径下破坏态/地面武器/副本位置全都还在原地,所以**不需要** match_sync 的
#   `destroyed` 那一套(那是路径乙"回大厅后回局"才需要的,见 spec §3.5)。
func _begin_reconnect() -> void:
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")   # 原版 worker / 老大厅 → 优雅降级
		return
	_reconnecting = true
	_reconnect_started_ms = Time.get_ticks_msec()
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


func _retry_connect() -> void:
	if not _reconnecting:
		return
	# ★ 宽限期到了就别再试 —— 服务器那边的 `_expire_graces` 会把你移出,再连上去
	#   也会被 reclaim 拒(不该在宽限外偷偷续上)。
	if Time.get_ticks_msec() - _reconnect_started_ms \
			> int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	NetBus.stop()
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0).timeout.connect(_retry_connect)
		return
	multiplayer.connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)


func _on_reconnect_failed() -> void:
	get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0).timeout.connect(_retry_connect)


func _try_reclaim() -> void:
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)
	# ★ 等 worker 回的 match_start(它带 spawn/map_path)。等到了才算成功,见 _on_resumed。
	get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0).timeout.connect(func() -> void:
		if _reconnecting:
			_retry_connect())   # 没等到应答 → 再试一轮


# worker 接受 reclaim 后会重发 match_start → 走既有入口。在那里收尾:
# 重置本地 C2 状态(见 spec §3.4 的 ★:不重置会把断线前的记录当"未确认输入"重放)。
func _on_resumed() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_input_seq = 0
	_have_prev_seq = false
	_prev_sent_seq = -1
	_rollback = PredictionRollback.new()
	print("[pvp] 重连成功")


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)
```

★ **`_on_resumed` 的接线**：`match_start` 会走 `lobby_page._on_match_start`（那条在大厅页，对局中不在树上）。**实施时改为**：`pvp_game` 已经在 `NetBus.local_match_start` 上挂了入口（进场时用的），确认它在**对局内再次收到 `match_start`** 时不会重切场景 —— 若会，就在 `pvp_game._on_match_start` 里加一条：`if _level0 != null and not _reconnecting: return`（已在对局里就不再进场），并在 `_reconnecting` 时改调 `_on_resumed()`。**这一步必须真机验证，不能靠推断。**

- [ ] **Step 4: 本阶段**不做**可见提示（只打日志）**

★ 「重连中…」那行字的**可见提示归 spec 阶段 3**（spec §7 把"HUD 掉线中／重连中"整块放在阶段 3）。理由：现成可挂的地方都不干净 —— `pvp_game` / `royale_game` 是 Node2D，直接挂 Control 要么另起 CanvasLayer、要么寄生在 `_hud`（而 `_hud` 在两个模式里是**不同类型**）；`UiFactory.panel_box()` 返回的是 **StyleBoxFlat 不是节点**，也没有现成的轻提示控件可复用。阶段 1 先用日志，等阶段 3 连同"对手掉线中"一起把 HUD 那层设计好再做，避免现在造一个马上要重写的控件。

所以本阶段把上面代码里对 `_set_reconnect_notice(...)` 的三处调用**换成 `print`**：

```gdscript
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
```
（`_begin_reconnect` 开头一处；`_on_resumed` 里打 `"[pvp] 重连成功"`；`_abort_reconnect` 里已有的 `print` 保留。）

---

## Task 7: 1v1 端口归还延迟提到 ≥ 宽限期

**Files:**
- Modify: `server/worker_launcher.gd:26`

**Interfaces:**
- Consumes: `GraceWindow.DEFAULT_SECONDS`
- Produces: `WORKER_PORT_REUSE_DELAY` 从 30 → **120**

- [ ] **Step 1: 改常量**

```gdscript
# ★ 2026-09-17:30 → **120**。原值 30s **短于**断线宽限期(30s) —— 宽限期内端口会被
#   `pick_port` 发给新 worker,而重连的客户端手里攥着旧端口 → 连到**别的局**。
#   120 = 宽限期 30s + 一局的重连余量,与 royale 的 360s 同一条纪律(那边见 ROYALE_PORT_REUSE_DELAY)。
const WORKER_PORT_REUSE_DELAY := 120.0
```

- [ ] **Step 2: 提交**

```bash
git add server/worker_launcher.gd
git commit -m 'fix(net): 1v1 端口归还延迟 30→120s(原值短于断线宽限期,会让重连连到别的局)'
```

---

## Task 8: 真链路探针 `tests/reconnect_probe.tscn`

**Files:**
- Create: `tests/reconnect_probe.gd` + `.tscn` + `.uid`

**Interfaces:**
- Consumes: 全部前序任务
- Produces: 判据 `RECONNECT PROBE: ALL-OK`

**做法**（照 `tests/royale_c2_probe.tscn` 的先例：自当大厅/裁判 + 拉真 worker + 真客户端；**跑前确认 7777 空闲**）：

- [ ] **Step 1: 四个相**

```
① 正向:客户端 A 主动 NetBus.stop() 模拟闪断 → 3s 后自动重连成功
   断言:reclaim 被接受、A 的 _scores 未变、A 的玩家节点还是**同一个 instance_id**
        (证明身体没被销毁 = 状态一条都不用恢复)
② 反向(必须):用**错 token** 发 reclaim_role → 断言被拒(worker 打 "拒绝 reclaim" 且连接被踢)
   ★ 没有这条,"谁都能顶替"会假绿
③ 身体冻结:掉线后 3s 内,该 role 的玩家 global_position 不变
   ★ 这条钉的是 `_enter_grace` 里的 `reset_state()` —— 不调的话身体会保持掉线前的输入一直跑
④ 超时移出:让一个客户端掉线后**不回来**,断言 GraceWindow.DEFAULT_SECONDS 之后
   worker 打了 mark_disconnected(大乱斗)/ 退了进程(1v1)
```

- [ ] **Step 2: 判据**

```gdscript
func _finish() -> void:
	if _failures.is_empty():
		print("RECONNECT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("RECONNECT PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
```

- [ ] **Step 3: 跑**

Run（**让用户跑**，跑前确认 7777 空闲）：
`"$GODOT" --headless --path . --quit-after 3600 res://tests/reconnect_probe.tscn`
Expected: `RECONNECT PROBE: ALL-OK`。

- [ ] **Step 4: 提交**

```bash
git add tests/reconnect_probe.gd tests/reconnect_probe.gd.uid tests/reconnect_probe.tscn
git commit -m 'test(net): 断线重连真链路探针(含错 token 反向断言与身体冻结断言)'
```

---

## Task 9: 同步 `CLAUDE.md`

- [ ] **Step 1: §网络与 PvP 新增一节「断线重连（阶段 1）」**

必须写进去的要点（每条都是"后人会踩"的）：

1. **token 由大厅生成**、在 `go_match` **之前**下发（`NetBusExt.session_token`）；`go_match`/`claim_role` 的**签名一律不动**（原 NetBus 逐字节纪律）。
2. **宽限期**唯一入口 `GraceWindow.DEFAULT_SECONDS`（30s）；同时是 1v1 的"送分时长"（用户裁定接受，别再放大）。
3. **掉线者身体不销毁** → 服务端对局状态一条都不用恢复（本设计最省的一处）。
4. **`_enter_grace` 必须 `reset_state()` 置空输入源** —— 否则身体保持掉线前的输入一直跑。
5. **1v1 端口延迟必须 ≥ 宽限期**，改一处要改齐两处。
6. `local_server_message` 在对局场景新增了订阅者（此前只有大厅页接）—— §1.3 那两个既有缺陷记一条。
7. 阶段 2/3 未做（回大厅后回局 / `match_sync` 带破坏态 / HUD 可见性）。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录断线重连阶段 1(token/宽限期/身体不销毁/端口延迟)'
```

---

## 自检记录

**spec 覆盖**：spec §3.1（token 大厅生成 + NetBusExt）→ Task 2/3；§3.2（宽限期状态机 + 输入源置空）→ Task 1/4；§3.3（reclaim_role）→ Task 5；§3.4 路径甲（局内自动重连 + C2 重置）→ Task 6；§3.7 端口延迟 → Task 7；§5 超时 → Task 1/4/6；§6 探针 → Task 8；§1.3 既有缺陷 → Task 6 Step 2 + Task 9。
**本阶段不做**（属 spec 阶段 2/3）：路径乙「回大厅后回局」、`rejoin_request`、`match_sync` 带 `destroyed`、HUD「对手掉线中」的完整可见性、`opponent_left` 不可达的修复。

**已知需要在实施时现场确认的一处**：`pvp_game._on_match_start` 在**已在对局中**再次收到 `match_start`（reclaim 成功时 worker 会重发）时的行为（Task 6 Step 3）——这条必须真机验证，不能靠推断。其余签名（`PacketInputSource.new()` 无参 + `set_input_source()`、`MazeGenerator.map_file_path()` 公开静态、`UiFactory.panel_box` 返回 StyleBoxFlat）都已在写计划时查证。
