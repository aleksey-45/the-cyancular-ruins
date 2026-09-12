# 大乱斗 role 集合 + 房间拆除收口（实施计划 · 批次 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「大厅↔worker 传人数 + role 上界两个整数」换成**显式 role 集合**；把散在五处的房间拆除收成**一个函数**。

**Architecture:** 两处独立改动，都只动大厅/worker 的协议与编排，不碰对局内的任何逻辑。A 段换协议（argv）；B 段抽函数（无行为变化）。

**Tech Stack:** Godot 4.7.1 标准版、GDScript。

## Global Constraints

- Godot 不在 PATH：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **多进程冒烟（`royale_probe` / `royale_bound_probe` / `royale_soak_probe` / `pvp_*_smoke`）留给用户**：会起 headless 服务器 + `taskkill`/`kill_port`，本仓在那里留过僵尸占 7777。
- 单进程探针（`room_sweep_smoke` 是 `-s`；`kh_l5_probe`/`kh_l6_probe` 是场景模式）实现者可自跑。
- **判据必须是 grep 标记文本**，不能只看退出码。
- 探针的 `_ready` 若有**独立测试函数**，必须有完成戳防线（Godot 运行时错误只中断当前函数，`_ready` 照常往下 → 假绿）。
- 改完 GDScript 只需重导出，**不要重编模板**。
- **两边改一处必须同步改另一处**：`room_manager._spawn_royale_worker` 生成的 argv 与 `server_main._ready` 的解析是逐字契约（`CLAUDE.md` 明文）。

## 依据

- 设计：`docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §3E（拆除散五处）、§3F（role 用人数兼上界）、§4.6
- `CLAUDE.md` §大乱斗 第 2 条末（`--players`/`--max-role` 双语义那段）与第 3 条（`_role_bound`）——**改完必须同步改这两段**

---

## 背景：为什么要换掉那个双整数协议

`--players N` 与 `--max-role R` 是两个**量纲不同**的东西用同一套"人数"心智模型表达：

- `N` = 预期报到总人数 → 收齐判据 `_claims.size() >= N - AI 数`
- `R` = **合法 role 号上界** → claim 越界判据

role 由 `royale_join` 的「最小空闲号」分配且**有人退出后不重排** → 编号会留空洞（3 人房里中间那位
退出 → 房里是 `{1,3}`，成员数 2 < 最高 role 3）。历史上**拿人数当上界**把手持 3 号的真客户端当串线
踢掉过（B1，只剩 1 个 claim → 超时梯走完 worker 退出 → 两名客户端卡在「连接对局服务器超时」）。

B1 的即时修法是补一个 `_royale_role_bound`（取实际最高 role）。但**根本问题**是：协议里根本没有
「这局有哪些 role」这个信息，只能从人数**推导**，而推导必然出错（需要额外的特例函数来兜）。
⇒ 直接把它**传过去**。

`--roles 1,3` 之后：
- 「合法 role」= 在集合内（精确，不再有"宽松多少"的余地）
- 「收齐」= `_claims.size() >= _roles.size() - AI 数`（同一个集合，减法天然成立）
- `_royale_role_bound` **整个删掉** —— 特例函数的存在本身就是协议缺陷的症状

---

### Task 1: argv 换成显式 role 集合

**Files:**
- Modify: `server/server_main.gd`（argv 解析 L34-59、`_on_role_claimed` L204-228、`_process` L172-185、`_on_peer_left` L296-309）
- Modify: `server/room_manager.gd`（`royale_start` L391-398、`royale_start_ai` L477-482、删 `_royale_role_bound` L486-499、`_spawn_royale_worker` L518-541）

**Interfaces:**
- Produces: worker argv `--roles 1,2,3`（**含 AI 补位号的全集**，逗号串）；`server_main._role_set: Array[int]`
- 删除：`--players`、`--max-role`、`_expected_players`、`_role_bound`、`_royale_role_bound`

- [ ] **Step 1: 先写/改守卫断言（红）**

`tests/room_sweep_smoke.gd` 是源码级冒烟（`-s` 跑）。在它里面加一条**反向**断言：`server_main.gd`
与 `room_manager.gd` 里**不得**再出现 `--players` / `--max-role` / `_role_bound` / `_expected_players`
（用同样的逐行扫描法，跳过注释行）。这条红着写，实现完转绿 —— 它的价值是**防止旧协议半途复活**
（两边只改一边是这套 argv 契约的历史故障模式）。

- [ ] **Step 2: 跑它确认红**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: 报出两个文件里残留的旧标识符，末行非 `SMOKE_ROOM_SWEEP OK`

- [ ] **Step 3: 改 `server_main.gd`**

解析段（替换 `--players` / `--max-role` 两个 case）：

```gdscript
			"--roles":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var r := int(tok.strip_edges())
						if r >= 1 and r <= 8:
							_role_set.append(r)
```

字段区：删 `_expected_players` / `_role_bound`，加

```gdscript
# 本局的**全部参战 role**(含 AI 补位号)。由大厅显式传入 —— 不再从"人数"推导:
# role 由 royale_join 的「最小空闲号」分配且有人退出后不重排,编号会留空洞(房里 {1,3} 而
# 成员 2 人),拿人数当上界会把持 3 号的真客户端当串线踢掉(自检 B1)。集合传过来则精确。
var _role_set: Array[int] = []
```

`_worker_human_roles()` 助手：

```gdscript
# 需要真人 claim 的 role 数 = 全集 − AI 补位号
func _human_role_count() -> int:
	var n := 0
	for r in _role_set:
		if not _ai_roles.has(int(r)):
			n += 1
	return n
```

`_on_role_claimed` 的越界判据：`(_royale and not _role_set.has(role))`，收齐判据
`_claims.size() >= _human_role_count()`。`_process` 与 `_on_peer_left` 里所有 `_expected_players`
的打印/判据换成 `_role_set.size()`。

**`worker` 分支的兜底**：`--roles` 缺失（手工命令行）时，回落到 `[1, 2]`（1v1 形态）；`--royale`
且集合为空 → 打印一条明确错误并 `quit(1)`，**不要**静默用一个猜出来的集合开局。

- [ ] **Step 4: 改 `room_manager.gd`**

```gdscript
# 拉起 N 人大乱斗 worker(--royale --roles 1,2,3;其余同 _spawn_worker)
# roles = **本局全部参战 role**(真人已分配号 + AI 补位号),由大厅显式传入 ——
# 不再传"人数 + role 上界"两个整数(那两者量纲不同、且都得从人数推导,是 B1 的根因)。
func _spawn_royale_worker(port: int, roles: Array, ai_roles: Array = []) -> bool:
	...	"--roles", ",".join(role_strs)
```

两个调用点：
- `royale_start`：`_spawn_royale_worker(port, rr.player_role.values())`
- `royale_start_ai`：`_spawn_royale_worker(port, rr.player_role.values() + ai_roles, ai_roles)`

删掉 `_royale_role_bound` 整个函数，以及两处打印里的 `_royale_role_bound(...)`。

- [ ] **Step 5: 跑守卫确认绿**

Run: 同 Step 2
Expected: `SMOKE_ROOM_SWEEP OK`

- [ ] **Step 6: 同步改 `CLAUDE.md`**

§大乱斗 第 2 条末的 argv 段（`--players N --max-role R [--ai-roles r,r]`）整段重写为 `--roles 1,2,3 [--ai-roles r,r]`；
删掉「**`--players N` 与 `--max-role R` 是两个语义，别合并**」那整条（它描述的问题已从协议层消失，改记
「role 集合由大厅显式传，因为从人数推导必然出错（历史 B1）」）；第 3 条里的「role 越界（用 `_role_bound`，
不是人数）」改为「role 不在集合内」。

- [ ] **Step 7: 提交**

```bash
git add server/server_main.gd server/room_manager.gd CLAUDE.md tests/room_sweep_smoke.gd
git commit -m "refactor(royale): 大厅↔worker 改传显式 role 集合,删掉--players/--max-role 双整数协议"
```

---

### Task 2: 房间拆除收口成一个函数

**Files:**
- Modify: `server/room_manager.gd`（新增 `_teardown_room`；改 `on_peer_left` L188-198 / L206-212、`royale_leave` L338-349、`_sweep_stale_rooms` L682-707、`ai_duel` L449-450）

**Interfaces:**
- Produces: `_teardown_room(room, kill: bool = false, msg: String = "", disconnect_peers: bool = false) -> void`
  —— `room` 是 `Room` 或 `RoyaleRoom`（鸭子类型，按 `room is RoyaleRoom` 分注册表与端口延迟）

**为什么**：本层为「端口泄漏」这**同一个**失败模式补过三次（`on_peer_left` 空房分支、`royale_leave`
空房分支、`ai_duel` 摘房前的手动释放）。散着写就还会漏第四次 —— 收口后「新加一条拆除路径」这件事
本身变得不可能漏（没有第二条路可走）。

- [ ] **Step 1: 写源码守卫（红）**

`tests/room_sweep_smoke.gd` 加一条：`room_manager.gd` 里 `_release_port_later(` 与 `rooms.erase(` /
`royale_rooms.erase(` 的**非注释调用点**只能出现在 `_teardown_room` 与 `_release_port_later` 自身之内。
（这条比"数调用点个数"稳：个数会随实现漂，而"只能出现在这一处"是契约本身。）

> 若实现后发现确有正当的例外（如 `_pick_worker_port` 的占用登记），把例外**连同理由**写进断言里，
> 别删断言。

- [ ] **Step 2: 跑确认红**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: 报出散落的调用点，非 OK

- [ ] **Step 3: 实现 `_teardown_room` 并改五条路径**

```gdscript
# ── 房间拆除的**单一收口** ──
# 全部拆除路径都必须走它。理由不是"整洁":本层为「端口泄漏」这同一个失败模式补过三次
# (on_peer_left 空房分支 / royale_leave 空房分支 / ai_duel 摘房前的手动释放),散着写还会再漏。
# 收口后"新加一条拆除路径"这件事本身不可能漏 —— 没有第二条路可走。
#
# kill            true=强杀 worker 并**立即**回收端口(僵尸清扫:worker 还活着占着端口)
#                 false=**延迟**归还端口(正常关房:worker 会自己退,立刻复用会撞车)
# msg             给房内玩家发的 server_message(空串=不发)
# disconnect_peers true=立刻断开房内玩家(清扫路径要;正常关房由 peer_left 自然收尾)
# 端口延迟分两档:1v1=WORKER_PORT_REUSE_DELAY(30s);大乱斗=ROYALE_PORT_REUSE_DELAY(360s,一局更长)
func _teardown_room(room, kill: bool = false, msg: String = "", disconnect_peers: bool = false) -> void:
	var is_royale := room is RoyaleRoom
	var port: int = room.worker_port
	var peers: Array = room.players.duplicate()
	if port > 0:
		if kill:
			_kill_worker(port)
			_worker_ports.erase(port)
		else:
			_release_port_later(port, ROYALE_PORT_REUSE_DELAY if is_royale else WORKER_PORT_REUSE_DELAY)
	if not msg.is_empty():
		for peer_id in peers:
			if _peer_online(peer_id):
				NetBus.rpc_id(peer_id, "server_message", msg)
	if is_royale:
		royale_rooms.erase(room.code)
	else:
		rooms.erase(room.code)
	print("%s %s 拆除(端口 %d %s)" % [
			"大乱斗房" if is_royale else "房间", room.code, port,
			"已强杀并回收" if kill else "将于延迟后回收"])
	if disconnect_peers:
		for peer_id in peers:
			if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(peer_id):
				multiplayer.disconnect_peer(peer_id)
```

五个调用点（**保持各自原有的通知文案与时机**）：
| 原处 | 改成 |
|---|---|
| `on_peer_left` 1v1 关闭 | `_teardown_room(room)` —— 幸存者通知留在调用点之前（它的文案与"配对已取消"语义是那条路径特有的） |
| `on_peer_left` 大乱斗空房 | `_teardown_room(rr)` |
| `royale_leave` 空房 | `_teardown_room(rr)` |
| `_sweep_stale_rooms` 1v1 | `_teardown_room(room, true, "房间超时(>2h),已关闭", true)` |
| `_sweep_stale_rooms` 大乱斗 | `_teardown_room(rr, true, "房间超时(>2h),已关闭", true)` |
| `ai_duel` | `_release_port_later(port)` + `rooms.erase(...)` → `_teardown_room(host_room)`（注意：它在此之前**没有** `rr.worker_port` 赋值路径的差别，`worker_port` 已在 L440 设好） |

`_sweep_stale_rooms` 收尾那段「立即断开被清理房间的玩家」（L703-707）由 `disconnect_peers=true` 接管，删掉。

- [ ] **Step 4: 跑守卫确认绿 + 跑受影响的探针**

Run: `room_sweep_smoke`（`-s`）、`kh_l5_probe`（场景模式，grep `KH L5 PROBE: ALL-OK`）
Expected: 都 OK

- [ ] **Step 5: 提交**

```bash
git add server/room_manager.gd tests/room_sweep_smoke.gd
git commit -m "refactor(lobby): 房间拆除收口成 _teardown_room(单一拆除路径,端口不再可能漏还)"
```

---

## 收官（**多进程验证留给用户**）

- [ ] 用户跑：`bash tests/royale_probe.sh`（若存在）或 `res://tests/royale_probe.tscn` 全链路；
      `res://tests/royale_bound_probe.tscn`（**B1 的守卫** —— role 空洞 `{1,3}` 那条正是本次改动的
      核心场景）；`bash tests/pvp_room_smoke.sh`、`bash tests/pvp_match_smoke.sh`（1v1 未被带坏的硬门）
- [ ] 更新 `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §3E/§3F 标为已落地
- [ ] 更新 ledger

## 本批不做的

- 不动 §4.2 进场拉取（批次 3）、§4.1 拆包（批次 4）——它们各自独立。
- 不顺手改 `_sweep_stale_rooms` 里那条**已登记**的已知边界（长时长房 >300s 被误杀）——那是另一件事，
  spec 里已如实登记。
