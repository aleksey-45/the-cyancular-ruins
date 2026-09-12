# 进场拉取 match_sync + 删除跨场景交接（实施计划 · 批次 3 主体）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把开局三载荷（昵称/色相/生效选项）的投递从「服务器**推** → 大厅缓存 → 新场景取用」换成「新场景进场**主动拉**一次」；删掉整条交接机制。

**Architecture:** 加一个 `match_sync` 请求/应答（走 `NetBus`，与 `match_start` 同层），worker 按 role 回一份完整快照。客户端在对局场景 `_ready` 里拉。**先做加法（拉通了再删推）**，避免中间态两端都不通。

**Tech Stack:** Godot 4.7.1 标准版、GDScript。

## Global Constraints

- Godot 不在 PATH：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **多进程冒烟由用户跑**（会起 headless 服务器 + `kill_port`）。单进程探针与 `-s` 冒烟实现者可自跑。
- **判据必须是 grep 标记文本**，不能只看退出码。
- **本仓已被抓过五次「验收门假绿」**。本批新增一条教训（2026-09-12 实测踩到）：
  **源码级 grep 冒烟不编译目标脚本** —— 文本全对但文件编不过，它照样报 OK。凡源码冒烟，
  断言前先 `load()` + `reload() != OK` 真编译一次（`load()` 解析失败时**不返回 null**，判据必须用 `reload()`）。
- 探针若有独立测试函数，`_ready` 里必须有**完成戳**防线。
- **两边改一处必须同步改另一处**：新增 RPC 要同时在 `net_bus.gd` 声明、worker 侧注册、客户端侧调用。

## 依据

- 设计：`docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §4.2、§3C、§3G（§3G 已于 `b2b8eea` 落地）
- `CLAUDE.md` §网络与 PvP 的「开局三条一次性载荷有两条投递路径」整段 —— **改完要重写**

---

## 设计决策（已定，实现者按此做，不要再另择）

| 决策点 | 定案 | 理由 |
|---|---|---|
| 走哪个节点 | **`NetBus`**（不是 `NetBusExt`） | 它是**核心对局协议**（1v1 与大乱斗都要），与 `match_start`/`snapshot` 同层。`NetBusExt` 是"原版服务端不认识就静默丢弃"的旁路扩展层 |
| 谁应答 | **worker 的 `server_main.gd`**（`_on_match_sync(caller)`） | 它手里有 `_claims`/`_claim_names`/`_claim_opts`，并且是它建的对局宿主 |
| 载荷形状 | `{names: {role:int->String}, hues: {role:int->float}, options: Dictionary, roles: Array[int], spawns: {role:int->Vector2i}}` | 一次拉全；`roles`/`spawns` 顺带把「这局有哪些 role、各自出生点」也变成**进场可得** |
| 可靠性 | `@rpc("any_peer", "call_remote", "reliable")` 请求；应答 `"authority", "call_remote", "reliable"` | 一次性、必须到；不能像快照那样用 unreliable |
| 与 `match_start` 的关系 | **`match_start` 保留**（客户端要先知道 `map_path` 才能建世界），但它带的 `spawn` 不再是权威 —— 以 `match_sync` 的 `spawns` 为准，到达后**校正一次** | 建世界必须先有地图；而出生点在拉取到之前只是"先摆着" |
| 拉取时机 | 对局场景 `_ready` **末尾**（订阅完之后） | 订阅在前，晚到的应答也收得到（拉取本身是请求-应答，不存在"早于订阅"） |

**为什么这样可以彻底删掉交接**：B2 的根因是「服务器在**同一次 poll** 里推 4 条，而客户端那一刻正在切场景、订阅方不存在」。拉取把这个方向反转了 —— 客户端**建好之后**才开口要，晚到也无所谓（它按 role 应答，不依赖时序）。

---

### Task 1: 加 `match_sync`（纯加法，先跑通）

**Files:**
- Modify: `core/net_bus.gd`（加 1 个 c→s RPC + 1 个 s→c RPC + 1 个 local 信号）
- Modify: `server/server_main.gd`（`_run_worker` 里注册；新增 `_on_match_sync`）
- Modify: `server/royale_host.gd`（暴露 `_round_spawns` 的**只读**取法，别让 `server_main` 直接读私有字段）
- Modify: `server/match_host.gd`（1v1 侧同样暴露"本局各 role 的出生点"）
- Modify: `scenes/pvp_client.gd`、`scenes/royale_game.gd`（`_ready` 末尾拉一次并应用）

**Interfaces:**
- Produces: `NetBus.match_sync`（c→s）、`NetBus.match_sync_data(payload)`（s→c）、`NetBus.local_match_sync`
- Produces: `MatchHost.role_spawns() -> Dictionary`（role → Vector2i；`RoyaleHost` 覆写为 `_round_spawns`）

- [ ] **Step 1: 写守卫（红）—— 新增 `tests/match_sync_probe.tscn`**

单进程场景探针：真建一个 `MatchHost`（`role_peers` 传空，与 `match_host_hygiene_probe` 同法避免 RPC），
断言 `role_spawns()` 覆盖 `players` 里的全部 role（1v1 侧由 `_spawn_cell` 得来）；再真建一个
`RoyaleHost`（传显式 `spawns`），断言 `role_spawns()` 与传入的**逐项相同**。
末行 `MATCH SYNC PROBE: ALL-OK`。带完成戳防线。

- [ ] **Step 2: 跑确认红**（`role_spawns` 还不存在）

- [ ] **Step 3: 实现服务端**

`net_bus.gd`：
```gdscript
signal local_match_sync(payload: Dictionary)
@rpc("any_peer", "call_remote", "reliable")
func match_sync() -> void:
	match_sync_received.emit(multiplayer.get_remote_sender_id())
signal match_sync_received(caller: int)
@rpc("authority", "call_remote", "reliable")
func match_sync_data(payload: Dictionary) -> void:
	local_match_sync.emit(payload)
```

`match_host.gd` 加（**只读**取法，别让上层直接读私有字段）：
```gdscript
# 本局各 role 的出生点(canonical 格)。1v1 由 _spawn_cell 得来;大乱斗覆写为开局散点。
# 进场拉取(match_sync)与 match_start 必须用**同一份** —— 见 RoyaleHost._init 的单一来源注释。
func role_spawns() -> Dictionary:
	var out := {}
	for role in players:
		out[int(role)] = _spawn_cell(int(role))
	return out
```
`royale_host.gd` 覆写：`return _round_spawns.duplicate()`

`server_main.gd`：`_run_worker` 里 `NetBus.match_sync_received.connect(_on_match_sync)`；
```gdscript
# 进场拉取:对局场景建好后主动要一次。**取代**原来"服务器推三载荷"的路径 ——
# 推的根因问题是"推给一个正在切场景的客户端"(同一次 poll 里订阅方还不存在),拉则天然无此竞态。
func _on_match_sync(caller: int) -> void:
	var role := 0
	for r in _claims:
		if _claims[r] == caller:
			role = int(r)
			break
	if role == 0 or _host == null:
		return   # 不在本局 → 静默丢弃(与 NetBusExt 的旁路语义一致,不报错)
	NetBus.rpc_id(caller, "match_sync_data", {
		"names": _claim_names, "hues": _claim_hues(), "roles": _role_set,
		"options": _claim_opts.get(1, {}),
		"spawns": _host.role_spawns() if _host.has_method("role_spawns") else {},
	})
```

- [ ] **Step 4: 实现客户端**

两个对局场景 `_ready` 末尾各加：
```gdscript
	NetBus.local_match_sync.connect(_on_match_sync)
	NetBus.rpc_id(1, "match_sync")   # 进场拉一次(建好之后才要,晚到也无所谓)
```
`_on_match_sync(payload)`：
```gdscript
func _on_match_sync(payload: Dictionary) -> void:
	if not (payload.get("names", {}) as Dictionary).is_empty():
		_on_peer_info(payload["names"])
	if not (payload.get("hues", {}) as Dictionary).is_empty():
		_on_peer_hues(payload["hues"])
	if not (payload.get("options", {}) as Dictionary).is_empty():
		_on_match_options(payload["options"])
	# 出生点以这一份为准(权威):与 match_start 带的那份不同就校正一次
	var sp: Dictionary = payload.get("spawns", {})
	if sp.has(PvpSession.role) and PvpSession.spawn != sp[PvpSession.role]:
		PvpSession.spawn = sp[PvpSession.role]
		_apply_spawn_correction()
```
`_apply_spawn_correction()`：把本地玩家摆到 `PvpSession.spawn`（**只在开局 COUNTDOWN 期做**；已开局则只记日志不硬拉，
避免把玩家从对局里拽走 —— 正常路径下两者本就该相同，走到这里说明有 bug，日志要留痕）。

- [ ] **Step 5: 跑守卫确认绿 + 跑单进程冒烟**

`match_sync_probe`、`room_sweep_smoke`、`kh_l5_probe`、`kh_l6_probe`、boot（含**大厅分支**真起一次 ——
见 Global Constraints：主菜单 boot 不加载 server 脚本）

- [ ] **Step 6: 提交**（`feat(net): 对局场景进场拉取 match_sync(纯加法,推路径暂留)`）

---

### Task 2: 删掉推路径与整条交接

**Files:**
- Modify: `core/pvp_session.gd`（删 `pending_*` + `clear_pending_payloads` + `reset()` 里的调用）
- Modify: `scenes/matchmaking.gd`、`scenes/royale_lobby.gd`（删 `_cache_*` 三个 handler 与订阅、两处 `clear_pending_payloads()`）
- Modify: `scenes/pvp_client.gd`、`scenes/royale_game.gd`（删 `_consume_pending_payloads` 及其调用）
- Modify: `server/server_main.gd`（`_begin_match` 里删 `peer_info`/`peer_hues` 两行推送）
- Modify: `server/match_host.gd`（`_broadcast_match_options` 删或改为 no-op —— 见 Step 3 的判据）
- Modify: `CLAUDE.md`（重写「开局三条一次性载荷有两条投递路径」整段）

- [ ] **Step 1: 加反向源码守卫（红）**

`room_sweep_smoke` 或新建 `tests/match_sync_probe` 内加：全仓 `.gd` 里**不得**再出现
`pending_peer_info` / `pending_peer_hues` / `pending_match_options` / `clear_pending_payloads` /
`_consume_pending_payloads`（跳过注释行）。与批次 2 的 argv 断言同法。

- [ ] **Step 2: 跑确认红**

- [ ] **Step 3: 删代码**

**保留什么**：`_on_peer_info` / `_on_peer_hues` / `_on_match_options` 三个 **handler 本身**（它们现在是
`match_sync` 的应用端）；删的是它们的**第二条投递路径**（pending 缓存）与**生产者**（推送）。
`NetBus.local_peer_info` / `NetBusExt.local_peer_hues` / `NetBusExt.local_match_options` 的**订阅也删**
（不再有人 emit）—— 除非 Step 4 证明还有别的生产者。

- [ ] **Step 4: 核「还有谁 emit 那三个信号」**

Run: `grep -rn "peer_info\|peer_hues\|match_options" --include=*.gd server/ core/ scenes/`
对每一处 emit 判定：是 `match_sync` 的应用端（留）还是推送端（删）。**结论写进提交信息**。

- [ ] **Step 5: 跑单进程冒烟 + boot（含大厅分支）**

- [ ] **Step 6: 提交**（`refactor(net): 删掉开局三载荷的推送与跨场景交接(拉取取代)`）

---

### Task 3: 重做确定性守卫（`royale_bound_probe --payload`）

**Files:**
- Modify: `tests/royale_bound_probe.gd` + `tests/royale_bound_watcher.gd`

**为什么必须改**：那条变体的**全部鉴别力**来自"载荷在触发换场**之前**注入 → 只能靠 `PvpSession`
交接才能活到新场景"。交接一删，它测的东西就不存在了。

**改成什么**：让探针**自任服务器**应答 `match_sync`（在 `NetBus` 上真注册 `match_sync_received`，
回一份 `match_sync_data`）。这样确定性变体测的变成**新的**东西：「新场景的拉取请求发得出去、
应答到得了、三个 handler 都被应用」——比原来更贴真实链路（原来测的是缓存，不是链路）。

★ 按 `docs/.../probe-conflict` 的既定纪律：**改探针认新入口，别回退重构**；改完必须做反证
（把 `_on_match_sync` 的应答摘掉 → 探针必须红）。

- [ ] **Step 1: 改探针为"自任服务器应答 match_sync"**
- [ ] **Step 2: 跑无参模式（真大厅+真 worker 全链路）→ 必须 ALL-OK**
- [ ] **Step 3: 反证：摘掉应答 → 必须红**
- [ ] **Step 4: 提交**

---

## 收官

- [ ] 用户跑：`royale_probe`、`royale_bound_probe`（无参 + `--payload`）、`pvp_room_smoke`、`pvp_match_smoke`
- [ ] 真机联调（用户）：建房→开局，确认**对手颜色/昵称/本人头顶 ID/禁武器闸门**四项在前 30 秒内正确
      （这四项正是 B2 当年静默失效的那四样 —— 拉取改完后它们必须有可见的验收）
- [ ] 更新 spec §3C/§4.2 标为已落地；更新 ledger

## 本批不做的

- 不动快照拆包（批次 4）、不动大乱斗接 C2（批次 5）。
- 不顺手删 `NetBusExt.beam_fired` 那个 KH 遗留重复（批次 6 收尾）。
