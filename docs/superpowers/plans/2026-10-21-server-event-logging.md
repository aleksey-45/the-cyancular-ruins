# 服务端运维审计日志实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让服务端(大厅 + 每个 worker)有一条**默认开、可跨进程对齐、崩溃后仍在**的运维审计事件流,并补上"关窗优雅停止"与"worker 引擎日志按端口归档",使"worker 崩了 / 房没开起来 / 谁关的房"事后可查。

**Architecture:** 不新建日志模块 —— 在既有的 `core/net/net_diag.gd` 上加一条**常开审计通道**(`audit()`),复用它的 JSON 行格式、`t/pid/role` 对齐、`urgent` flush 与"IO 失败只 warning"的边界;审计只在**非 client 进程**生效。事件在已有的决策点就地发出,不新增状态机。

**Tech Stack:** Godot 4.7.1 GDScript(标准版)、`FileAccess`/`DirAccess`/`JSON`、`-s` 冒烟(`extends SceneTree`)。

**Spec:** [`docs/superpowers/specs/2026-10-21-server-event-logging-design.md`](../specs/2026-10-21-server-event-logging-design.md)

## Global Constraints

- **注释额度(硬线)**:`.gd` >100 行 ⇒ 整行注释 ÷ 非空行 ≤15%。**本批要动的三个文件已经超标**:
  `core/net/net_diag.gd` **20.0%**、`server/server_main.gd` **15.49%**、`server/lobby/lobby_rooms.gd` **17.7%**
  ⇒ 对这三个文件**只许加行尾注释**,不许净增整行注释;存量不追补。代码注释**不许 Markdown**(只用 `★`/`⚠`)。
- **脚本总数闸**:`allscript_probe.EXPECTED_SCRIPTS` 当前 **190**;本批新增 1 个 `.gd`(冒烟)⇒ 改成 **191**,
  并核对 `git ls-files '*.gd' | wc -l` 与 `git ls-files --others --exclude-standard '*.gd'`(=0)。
- 新守卫**必须自带 `EXPECTED_CHECKS` 条数闸**;新建 `.gd` 必须与 `.gd.uid` 一起提交(`--import` 生成)。
- 服务端代码**禁用 `RegEx`**(裁剪模板 `module_regex_enabled:false`)。
- 提交:逐文件 `git add`(绝不 `git add -A`),信息 `type(scope): 中文一句话`。
  ★ `assets/textures/player.png` / `scenes/player/player.tscn` 是**另一个会话的改动,永远不要 add**。
- `audit()` **绝不允许**打断业务:开文件失败只 `push_warning` + 置失败位,后续调用直接返回(照 `NetDiag._open_failed` 的既有做法)。
- 事件字段值里**不许出现换行**(一行一条是所有 `grep`/保留策略的前提);`tail` 字段的换行压成 ` ↵ `。
- 验证 Godot 时把 `$env:APPDATA` 指到临时目录(否则 `user://` 写失败会让进程直接退出)。

## Review Focus

以下是 spec 隐含、但任务里的自动断言**测不到**的失败模式(每条在指定任务里落地验证方式):

1. **把审计开到玩家客户端** ⇒ 每个玩家机器都多一份无人读的 ops 文件 ⇒ Task 1 的 `should_audit("client") == false` 断言。
2. **`audit()` 在只读盘/无权限目录上抛错** ⇒ 把建房/开局路径带崩(日志把业务搞挂)⇒ Task 2 的实现约束 + Task 2 的"坏路径不崩"验证。
3. **worker 端口复用** ⇒ 不归档则新生局覆盖上一局崩溃现场(排障最需要的那份)⇒ Task 6 的连开两局手动证据。
4. **关窗时仍有房间** ⇒ 不优雅停止会留孤儿 worker,端口要等 120/360 秒 ⇒ Task 3 的手动关窗证据。
5. **`lobby_stop` 写两条**(`_notification` 与 `_exit_tree` 各一条)⇒ 审计里"关服次数"翻倍、误导排查 ⇒ Task 3 的 `_stop_logged` 去重与断言。

---

### Task 1: `NetDiag` 的三个纯判据 + 冒烟

**Files:**
- Modify: `core/net/net_diag.gd`(`log_event` 之后,约 `:74`)
- Create: `tests/smoke/ops_log_smoke.gd`

**Interfaces:**
- Produces: `NetDiag.should_audit(role: String) -> bool`;
  `NetDiag.ops_file_name(role: String, pid: int, stamp: String) -> String`;
  `NetDiag.ops_files_to_keep(names: PackedStringArray, keep: int) -> PackedStringArray`;
  `const NetDiag.OPS_KEEP := 60`、`const NetDiag.OPS_WARN_BYTES := 8 * 1024 * 1024`

- [ ] **Step 1: 写失败测试**

`tests/smoke/ops_log_smoke.gd`:`extends SceneTree`、`const ND := preload("res://core/net/net_diag.gd")`、
`const EXPECTED_CHECKS := 5`、`var _checks := 0`、`_check(name, cond)` 计数、结尾条数闸、成功打印 `OPS_LOG_OK(%d checks)` 后 `quit(0)`。

```gdscript
fail += _check("client 不审计", ND.should_audit("client") == false)
fail += _check("server 审计", ND.should_audit("server") == true)
fail += _check("文件名带 role/pid/stamp",
		ND.ops_file_name("server", 4321, "20261021_210433") == "ops-server-4321-20261021_210433.jsonl")
var names := PackedStringArray(["ops-server-1-a.jsonl", "ops-server-1-c.jsonl",
		"ops-server-1-b.jsonl", "diag-server-1-a.jsonl"])
var kept := ND.ops_files_to_keep(names, 2)
fail += _check("只留最新 2 份且不动非 ops 文件",
		kept.size() == 2 and kept.has("ops-server-1-c.jsonl") and kept.has("ops-server-1-b.jsonl")
		and not kept.has("diag-server-1-a.jsonl"))
fail += _check("不足 keep 时全留", ND.ops_files_to_keep(PackedStringArray(["a.jsonl"]), 60).size() == 1)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `"$GODOT" --headless --path . -s res://tests/smoke/ops_log_smoke.gd`(外层 `timeout 30`)
Expected: `Static function "should_audit()" not found`

- [ ] **Step 3: 实现三个纯函数**

- `should_audit(role)`:`role != "client"`(空串也算审计 —— `role()` 在认不出时会退回 client,但这里按"不是 client 就开"写更安全,注释里写清理由)。
- `ops_file_name(role, pid, stamp)`:`"ops-%s-%d-%s.jsonl" % [role, pid, stamp]`。
- `ops_files_to_keep(names, keep)`:过滤出 `begins_with("ops-") and ends_with(".jsonl")`,**按名倒序**取前 `keep`,返回 `PackedStringArray`;其余文件原样忽略(**不返回待删名单**,返回保留名单,删谁由调用方做差集 —— 这样纯函数不掺 I/O)。

- [ ] **Step 4: 跑测试确认通过**;Expected: `OPS_LOG_OK(5 checks)`、`rc=0`
- [ ] **Step 5: 提交**

```bash
git add core/net/net_diag.gd tests/smoke/ops_log_smoke.gd tests/smoke/ops_log_smoke.gd.uid
git commit -m "feat(net): 审计通道的纯判据 + 冒烟"
```

---

### Task 2: `audit()` 落盘 —— 常开、每条 flush、失败不许打断业务

**Files:**
- Modify: `core/net/net_diag.gd`(`_ensure_open` 旁新增 `_ensure_audit_open`;文件末尾测试钩子区新增 `begin_audit_for_test` / `end_audit_for_test`)
- Modify: `tests/smoke/ops_log_smoke.gd`(`EXPECTED_CHECKS` 5 → 9)

**Interfaces:**
- Consumes: Task 1 的 `should_audit` / `ops_file_name` / `ops_files_to_keep`
- Produces: `NetDiag.audit(event: String, data: Dictionary = {}) -> void`;
  `NetDiag.audit_path() -> String`;`NetDiag.begin_audit_for_test(path: String) -> void`;`NetDiag.end_audit_for_test() -> void`

- [ ] **Step 1: 写失败测试**(追加到同一冒烟)

```gdscript
var tmp := "user://logs/_ops_smoke.jsonl"
DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://logs"))
ND.begin_audit_for_test(tmp)
ND.audit("unit_seeded", {"room": "4821", "n": 3})
ND.audit("unit_seeded", {"room": "4821", "n": 3})
var txt := FileAccess.get_file_as_string(tmp)
var lines := txt.strip_edges().split("\n")
var ok_line := false
if lines.size() >= 1:
	var obj = JSON.parse_string(lines[0])
	ok_line = typeof(obj) == TYPE_DICTIONARY and obj.has("t") and obj.has("pid") \
			and obj.has("role") and str(obj.get("event", "")) == "unit_seeded" \
			and int(obj.get("data", {}).get("n", 0)) == 3
fail += _check("audit 写出带 t/pid/role/event/data 的 JSON 行", ok_line)
fail += _check("两次调用写两行", lines.size() == 2)
fail += _check("audit_path 指向注入路径", ND.audit_path() == tmp)
# ★ 冒烟进程的 role() 是 client(命令行里既没有 --worker 也没有 --server)⇒ end 之后必须**不再写**:
#   这条同时钉住 Review Focus 1(不许把审计开到玩家客户端)。
ND.end_audit_for_test()
ND.audit("after_end", {})
fail += _check("client 进程不再写", FileAccess.get_file_as_string(tmp).strip_edges().split("\n").size() == 2)
DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
```

- [ ] **Step 2: 跑测试确认失败**;Expected: `Static function "audit()" not found`
- [ ] **Step 3: 实现 `audit()` 与 `_ensure_audit_open()`**

`_ensure_audit_open()` 与既有 `_ensure_open()` 同构,差别:① 先判 `should_audit(role())`,假就直接置 `_ops_skipped=true` 并返回;
② 文件名用 `ops_file_name(...)`;③ 先把同目录 `ops-*.jsonl` 列表喂给 `ops_files_to_keep(names, OPS_KEEP)`,**差集逐个 `DirAccess.remove_absolute`**;
④ 首行写 `session_start`(同 diag 的形状);⑤ 打开失败 ⇒ `_ops_failed = true` + `push_warning`,后续 `audit()` 直接 return。
`audit()`:若 `_ops_skipped`/`_ops_failed` 直接 return;`_ensure_audit_open()`;`store_line(JSON.stringify({t, pid, role, event, data}))`;
**每行都 `flush()`**(崩溃后必须在);若 `get_length() > OPS_WARN_BYTES` 且还没警告过 ⇒ `push_warning` 一次。
★ 全程**不许** `push_error`,**不许**让异常逃出去(文件打不开就只是不落盘)。

- [ ] **Step 4: 跑测试确认通过**;Expected: `OPS_LOG_OK(9 checks)`
- [ ] **Step 5: 手动证据** —— 起大厅(headless,`--quit-after 120`),`Get-ChildItem $APPDATA\Godot\app_userdata\The Cyancular Ruins\logs` 里应出现 `ops-server-<pid>-<stamp>.jsonl`,内容首行 `session_start`。

- [ ] **Step 6: 提交** `git add core/net/net_diag.gd tests/smoke/ops_log_smoke.gd` + `git commit -m "feat(net): 常开审计通道(每条 flush,IO 失败不打断业务)"`

---

### Task 3: 大厅生命周期审计 + 关窗优雅停止

**Files:**
- Modify: `server/server_main.gd`(大厅分支 `_ready` `:35`;就绪打印 `:70` 之后;文件末尾新增 `_notification` / `_exit_tree`)

**Interfaces:**
- Consumes: `NetDiag.audit`
- Produces: 事件 `lobby_start`、`lobby_stop`;`var _stop_logged := false`

- [ ] **Step 1: `lobby_start`** —— `print("服务器就绪…")`(`:70`)之后一行
  `NetDiag.audit("lobby_start", {"version": <与 `:36` 同一个 build_info 表达式>, "port": NetBus.DEFAULT_PORT})`(行尾注释说明,不新增整行注释)
- [ ] **Step 2: 优雅停止** —— 大厅分支 `_ready` 里 `get_tree().auto_accept_quit = false`;新增
  `func _notification(what: int) -> void:` 处理 `NOTIFICATION_WM_CLOSE_REQUEST`:
  ① 对 `lobby.rooms` / `lobby.royale_rooms` / `lobby.team_rooms` 三张**只读视图**各自 `duplicate()` 后遍历,
  逐个 `lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL)`(先拷贝再拆,别在遍历中改表);
  ② `_stop_logged = true`;`NetDiag.audit("lobby_stop", {"reason": "close_request", "rooms_left": 0})`;
  ③ `get_tree().quit()`
- [ ] **Step 3: 退出兜底(去重)** —— `func _exit_tree() -> void:`:若 `_stop_logged` 则 return,否则写
  `audit("lobby_stop", {"reason": "quit", "rooms_left": <三表基数之和>})`。★ 只在大厅分支生效(worker 分支不写)
- [ ] **Step 4: headless 证据** —— `--headless --quit-after 300` 跑完,`grep` 审计文件里 `lobby_start` 与 `lobby_stop` **各 1 条**
- [ ] **Step 5: 真窗口证据(Review Focus 4 + 5)** —— 非 headless 起大厅(★ 弹窗),不建任何房直接点关闭;
  Expected: 审计里 `lobby_stop` **恰好 1 条**且 `reason=close_request`;`tasklist | grep -i godot` 为空(无孤儿 worker)
- [ ] **Step 6: 提交** `git add server/server_main.gd` + `git commit -m "feat(server): 大厅生命周期审计 + 关窗优雅停止"`

---

### Task 4: 房间 / 玩家 / 关房审计

**Files:**
- Modify: `server/lobby/lobby_rooms.gd`(`create_room:135`(print `:158`)、`join_room:161`(`:188`)、
  `on_peer_left:196`(房主转移 `:216`)、royale 建房 `:306`/加入 `:346`、team 建房 `:447`/加入 `:485`、`teardown_room:662`(print `:687`))
- Modify: `server/gui/server_panel.gd`(`_close_room` 里那处 `teardown_room` 调用)

**Interfaces:**
- Produces: 事件 `room_created` / `player_join` / `player_leave` / `host_transfer` / `room_closed`;
  `teardown_room(room, mode := TEARDOWN_DELAYED, msg := "", disconnect_peers := false, reason := "")`

- [ ] **Step 1: 给 `teardown_room` 加** `reason: String = ""`(默认参数 ⇒ 现有调用点全部照旧可编译),在函数**末尾**写
  `audit("room_closed", {"room": room.code, "mode": room.mode, "reason": <reason 为空时按 mode 兜底>, "port": port, "players": <拆前人数>, "uptime_sec": <now - created_at>})`;
  兜底映射:`TEARDOWN_KILL`→`"closed"` / `TEARDOWN_ABORT`→`"abort"` / 其余→`"delayed"`。
  人数与房龄要在**删表之前**取(拆完就没了)
- [ ] **Step 2: 7 处事件型 `print` 换成 `audit` 并**删掉原 print**(一份事实一处写):`:158`、`:188`、`:306`、`:346`、`:447`、`:485`、`:687`。
  字段按 spec §4;`nick` 取 `_peer_names.get(peer, "玩家")`,`mode` 用 `room.mode`
- [ ] **Step 3: `on_peer_left` 里**在移除成员**之前取到 `room` / `mode` / `players.size()`,发 `player_leave`;
  `:216` 那处房主转移换成 `audit("host_transfer", {"room": code, "mode": room.mode, "from_peer": <旧 host>, "to_peer": room.host_peer})`
- [ ] **Step 4: 面板关房传因** —— `server_panel.gd` 的 `_close_room` 调用改成
  `teardown_room(room, LobbyRooms.TEARDOWN_KILL, "服主关闭了本房间", true, "operator")`(行尾注释:唯一写操作的审计因)
- [ ] **Step 5: 证据** —— 起大厅 + 一个客户端建房/加入/退出/关房,审计文件里四个事件各至少 1 条;`grep '"room_closed"' | grep operator` 命中面板关房那条
- [ ] **Step 6: 提交** `git add server/lobby/lobby_rooms.gd server/gui/server_panel.gd` + `git commit -m "feat(server): 房间与玩家审计事件(含关房原因)"`

---

### Task 5: 对局生命周期 + `worker_lost`(代替拿不到的退出码)

**Files:**
- Modify: `server/lobby/room_manager.gd`(`royale_start:56`(print `:94`)、`ai_duel:121`(`:146`)、`royale_start_ai:151`(`:191`)、
  `team_start:199`(`:241`)、`_start_match:247`(`:281`)、`_sweep_stale_rooms:307`(`:336`/`:345`)、`_reclaim_finished_matches:353`(`:371`))
- Modify: `core/net/net_diag.gd`(新增 `tail_lines(path, n)` 静态助手 —— 读文件是 I/O,但只有 10 行,和 `_ensure_open` 同居一层)

**Interfaces:**
- Consumes: `NetDiag.audit`、`NetDiag.tail_lines`、`WorkerLauncher.log_path`
- Produces: `match_start` / `match_end` / `worker_lost` / `worker_spawn_failed`;`NetDiag.tail_lines(path: String, n: int) -> String`

- [ ] **Step 1: `tail_lines(path, n)`** —— 读全文 → `split("\n")` → 过滤空行 → 取最后 `n` 条 → `" ↵ "` 连接;文件不存在返回 `""`(不抛)
- [ ] **Step 2: 5 处开局 print → `audit("match_start", {...})`**(`room`/`mode`/`port`/`players`/`ai`),删原 print
- [ ] **Step 3: `_reclaim_finished_matches` 的 `:371`** → `audit("match_end", {"room","mode","port","uptime_sec"})`
- [ ] **Step 4: `worker_lost`(Review Focus:崩溃证据)** —— 在 `:371` 同一处,若这间房**此前没有** `match_end` 记录(用回收梯自己的判据:worker 不在但房仍在局),额外
  `audit("worker_lost", {"room","mode","port","pid","alive_sec": <now - created_at>, "tail": NetDiag.tail_lines(launcher.log_path(port), 3)})`;
  ★ `tail` 必须在**下一局开新 worker 之前**读(端口复用会覆盖,见 Task 6 的归档顺序:回收先读 tail,归档在 spawn 前)
- [ ] **Step 5: `_sweep_stale_rooms` 的 `:336`/`:345`** → `audit("room_closed", {"reason": "sweep_timeout", ...})`(与 Task 4 **同事件名**,不发明第二个)
- [ ] **Step 6: `worker_spawn_failed`** —— `worker_launcher` 三个 `spawn_*` 里 `pid <= 0` 的分支加
  `audit("worker_spawn_failed", {"room": "", "mode": "", "port": port})`(拉不起来时房对象可能已拆,留空串而不是编造)
- [ ] **Step 7: 证据** —— 起大厅开局,用 `Stop-Process` 杀掉 worker,等一个回收周期;审计里应出现 `worker_lost` 且 `tail` 字段非空
- [ ] **Step 8: 提交** `git add core/net/net_diag.gd server/lobby/room_manager.gd server/lobby/worker_launcher.gd` + `git commit -m "feat(server): 对局生命周期审计 + worker 失联证据"`

---

### Task 6: worker 侧审计 + worker 引擎日志归档

**Files:**
- Modify: `server/server_main.gd`(worker 分支:就绪打印 `:189`/`:193`/`:196` 之后;结束/提前退出 `:245`/`:250`/`:274`/`:284`/`:292`)
- Modify: `server/lobby/worker_launcher.gd`(`log_path:80`;三个 `spawn_*` 入口 `:87`/`:112`/`:150`)
- Modify: `tests/smoke/ops_log_smoke.gd`(`EXPECTED_CHECKS` 9 → 13)

**Interfaces:**
- Consumes: `NetDiag.audit`
- Produces: 事件 `match_boot` / `match_over` / `abort`;
  `WorkerLauncher.archive_name(path: String, stamp: String) -> String`;
  `WorkerLauncher.prune_worker_logs(names: PackedStringArray, port: int, keep: int) -> PackedStringArray`;
  `func _archive_log(port: int) -> void`;`const WORKER_LOG_KEEP := 20`

- [ ] **Step 1: 写失败测试**(追加到冒烟:两个纯函数,4 条断言;冒烟顶部加 `const WL := preload("res://server/lobby/worker_launcher.gd")` —— 它不引用 `NetBus`,`-s` 里可加载)

```gdscript
fail += _check("归档名插在扩展名前",
		WL.archive_name("user://logs/worker_7800.log", "210433") == "user://logs/worker_7800_210433.log")
var wn := PackedStringArray(["worker_7800.log", "worker_7800_210431.log",
		"worker_7800_210432.log", "worker_7801_210432.log"])
var keptw := WL.prune_worker_logs(wn, 7800, 2)
fail += _check("只留该端口最新 2 份归档",
		keptw.size() == 2 and keptw.has("worker_7800_210432.log") and keptw.has("worker_7800_210431.log"))
fail += _check("不碰别的端口", not keptw.has("worker_7801_210432.log"))
fail += _check("不含未归档的活文件", not keptw.has("worker_7800.log"))
```

- [ ] **Step 2: 跑测试确认失败**;Expected: `Static function "archive_name()" not found`
- [ ] **Step 3: 实现两个纯函数**(命名用 `get_base_dir()`/`get_file().get_basename()`,别手拼 `/`;过滤 `worker_<port>_*.log` 用 `begins_with`/`ends_with`,**不许用 `RegEx`**)
- [ ] **Step 4: `_archive_log(port)`** —— 若 `log_path(port)` 存在:`DirAccess.rename_absolute(log_path(port), archive_name(...))`,时间戳 `HHMMSS`;
  再列同目录,把 `prune_worker_logs(...)` 之外的 `worker_<port>_*.log` 逐个删
- [ ] **Step 5: 三个 `spawn_*` 入口各调一次** `_archive_log(port)`(**在 `OS.create_process` 之前**,`pick_port` 之后)
- [ ] **Step 6: 跑冒烟**;Expected: `OPS_LOG_OK(13 checks)`
- [ ] **Step 7: worker 侧审计** —— 就绪打印之后 `audit("match_boot", {"port","mode","roles","map"})`;
  收场打印(`:245`/`:250`)与提前退出(`:274`/`:284`/`:292`)分别换成 `audit("match_over", ...)` / `audit("abort", {"reason": ...})`(**删原 print**)
- [ ] **Step 8: 连开两局证据(Review Focus 3)** —— 同端口打两局 1v1;`user://logs` 里应出现 `worker_7800_<HHMMSS>.log`,上一局内容不被覆盖;且两份 `ops-worker-*.jsonl` 各含 `match_boot`/`match_over`
- [ ] **Step 9: 提交** `git add server/server_main.gd server/lobby/worker_launcher.gd tests/smoke/ops_log_smoke.gd` + `git commit -m "feat(server): worker 侧审计 + 每局日志归档"`

---

### Task 7: 收尾 —— 条数闸、文档、登记、全量验证

**Files:**
- Modify: `tests/probe/allscript_probe.gd`(`EXPECTED_SCRIPTS` 190 → 191)
- Modify: `docs/eng/tests.md`(「结构化诊断」章节补 audit 通道 + 保留策略)
- Modify: `docs/eng/debt/guard-strength-gaps.md`(§五 新增一条:三条不写守卫的边界)
- Modify: `docs/eng/netplay.md`(一句指针到 spec,不抄数字)

- [ ] **Step 1: 复核脚本数** —— `git ls-files '*.gd' | wc -l` = **191**、未跟踪 = **0**;不符先查 `.uid`
- [ ] **Step 2: 改条数闸** —— `EXPECTED_SCRIPTS := 191`,行尾注明 `2026-10-21: +1 = tests/smoke/ops_log_smoke.gd`
- [ ] **Step 3: `docs/eng/tests.md`** —— 在「结构化诊断」下加一小段:`ops` 通道常开(仅非 client)、文件命名、每条 flush、保留 60、8MB 警告、与 `--diag` 的分工
- [ ] **Step 4: 登记三条不写的边界**(`guard-strength-gaps.md` §五):
  ① 事件**调用时机**零守卫(要真房间 ⇒ 真链路/人眼);② ops 保留/worker 归档的**真实磁盘行为**零守卫(写盘不进默认批);③ 关窗优雅停止零守卫(要真关窗口)。并写明"`audit()` IO 失败只 warning"这条靠评审。
- [ ] **Step 5: 全量验证**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/ops_log_smoke.gd                  # OPS_LOG_OK(13 checks)
"$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd           # 不回归
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/allscript_probe.tscn  # ALLSCRIPT: OK(191 ...)
python tools/check_naming.py                                                        # OK
bash tests/run_all.sh                                                               # RUN_ALL OK(...)
```
- [ ] **Step 6: 注释额度复核** —— 六个被改的 `.gd` 逐个量;三个已超标的文件**不许比本批开始时更差**(记录改动前后的百分比)
- [ ] **Step 7: 提交** `git add tests/probe/allscript_probe.gd docs/eng/tests.md docs/eng/debt/guard-strength-gaps.md docs/eng/netplay.md` + `git commit -m "chore(server): 审计通道的条数闸、文档与边界登记"`
- [ ] **Step 8: 出包(可选)** `python tools/build_release.py` —— 新 exe 才带审计通道
