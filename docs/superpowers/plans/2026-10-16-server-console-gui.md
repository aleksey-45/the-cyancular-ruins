# 服务端控制台(Server Console)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让双击 `Cyancular Ruins Server.exe` 得到一个进程内运维面板:一屏看清房间 / worker / 端口,能关掉单间房,能看某局 worker 的日志尾部。

**Architecture:** 不给服务端加任何新协议、新端口、新进程。改导出标记让该 exe 拿回显示驱动(`dedicated_server=false` + `custom_features="serverui"` + 主场景 feature 覆盖),面板作为 `CanvasLayer` 挂在 `server/server_main.tscn` 上;**直接读大厅进程里的 `LobbyRooms` / `WorkerLauncher`**,动作直接调既有的唯一拆除收口 `teardown_room`。数据按「纯函数(可冒烟)/ 适配层(不可冒烟)」切两半。

**Tech Stack:** Godot 4.7.1 标准版(非 mono)· GDScript · 既有 `UiFactory` / `ui/theme/menu_theme.tres` · `-s` SceneTree 冒烟.

**Spec:** [`docs/superpowers/specs/2026-10-16-server-console-gui-design.md`](../specs/2026-10-16-server-console-gui-design.md) —— 执行者**必须两份一起读**:本计划只记决策与接口,版式/几何/规则在 spec。

## Global Constraints

- 引擎:**Godot 4.7.1 标准版(非 mono)**。`$GODOT` = console 版,`$GODOT_EDITOR` = 标准编辑器版;两个二进制不能混用。
- 默认路径 `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`;换机器用环境变量 `GODOT` 覆盖,**不改脚本里的绝对路径**。
- **进导出包的脚本禁用 `RegEx`**(裁剪模板 `module_regex_enabled: false` ⇒ 整个脚本解析失败,而编辑器里全绿)。
- **颜色只许来自 `UiFactory` 的常量**,不写 `Color(...)` 字面量;`StyleBoxFlat` 可以用,但颜色必须引用常量。
- **字号只有 16 / 32 / 48**(`UiFactory.style_control` 里 `assert(size % 16 == 0)`)。
- ★ **`-s` 冒烟里 autoload 标识符编译期不可解析**:任何冒烟脚本**不许引用** `NetBus` / `NetBusExt` / `Settings` / `GameParameters`,也**不许引用 `LobbyRooms`**(它引用 `NetBus`)。
- ★ **`-s` 脚本一旦抛错就走不到 `quit()`,进程永久挂起** ⇒ 每次跑冒烟一律套外层 `timeout 30`,期望"编译失败 = 超时/非 0",不要干等。
- 提交:逐个文件点名 `git add`(**绝不 `git add -A`**);新建 `.gd` 连 `.gd.uid` 一起加,`.tscn` 不用;提交信息 `type(scope): 中文一句话`。
- 命名检查:`python tools/check_naming.py` 必须过(目录小写 / `class_name` 与文件名对齐 / `.tscn` snake_case)。
- ★ **跑测试前先问用户**:列出「这轮要跑哪些测试」,用户认领的自己跑,其余由 agent 跑。
- ★ **非 headless**(会弹窗口抢焦点)跑前**明确告知用户**。
- ★ 任何会占 7777 的步骤先查 `lobby_alive`(`tests/env.sh`),为真则跳过并问 —— 大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局。
- 不碰:`--worker` 分支语义、`teardown_room` 语义、`NetBus` 协议表、worker spawn 的 `--headless`、`server_main.gd:12` 的死字段 `_wait_timer`。

## Review Focus

按"最可能咬到使用者"排序。每条都已在某个 task 里配了对应用例。

1. **端口池的"已分配但还没 spawn"窗口** —— `pick_port()` 之后、`create_process` 成功之前,端口已被占用但 `pid == 0`。面板若把它当空闲,运维会以为"端口没用着"而实际有 worker 正要抢。→ Task 1。
2. **对局中的房间 `players` 是空表** —— 全体成员已转连 worker。任何拿 `players.size()` 显示人数的代码都会让局中房间显示 **0 人**。必须改读冻结的 `roster`。→ Task 2。
3. **worker 已退出但房还没被回收的 ~30s 窗口** —— 必须显示成红字异常态,而不是"对局中"。→ Task 2。
4. **`--headless` 下实例化面板** —— 会让 `build_release.py` 的产物冒烟与所有测试跑批一起红。→ Task 3。
5. **点「关闭房间」到执行之间房没了** —— 必须 no-op 且不报错;房号空间三张表共用,**按房号反查可能查到另一张表的同号房**,必须连模式一起核对。→ Task 6。

---

### Task 0: 导出标记可行性验证(方案 A′ 的生死门)

**Files:**
- Modify: `export_presets.cfg:79-88`(preset.1)
- Modify: `project.godot:24` 之后(新增一行 feature 覆盖)

**Interfaces:**
- Consumes: 无
- Produces: 一个**双击即出窗口**的服务端 exe;后续所有 task 都建立在"这个 exe 能开窗"这个事实上

- [ ] **Step 1: 改 preset.1 的两行**

`export_presets.cfg` 里 `[preset.1]` 段(`name="Dedicated Server"`):

```ini
dedicated_server=false
custom_features="serverui"
```

- [ ] **Step 2: 加主场景的 feature 覆盖**

`project.godot` 的 `[application]` 段,紧跟现有的 `run/main_scene.dedicated_server="res://server/server_main.tscn"` 之后新增一行:

```ini
run/main_scene.serverui="res://server/server_main.tscn"
```

- [ ] **Step 3: 确认 headless 路径没坏**

Run:
```bash
timeout 60 "$GODOT" --headless --path . --quit-after 90 res://server/server_main.tscn
```
Expected: 打出 `服务器就绪,等待玩家……` 与 `本机局域网 IP`,退出码 0,**不出现** `SCRIPT ERROR`。
(这一步不占端口的风险由 `--quit-after` 兜住;若 7777 已被占,E2E 会打 `服务器: 监听失败`,先查 `lobby_alive`。)

- [ ] **Step 4: 真导一次并**由用户**双击验证(★ 非 headless,跑前告知)**

Run:
```bash
python tools/build_release.py            # 或按 RELEASE.md §1 只导 Dedicated Server 预设
python tools/make_server_console.py      # 保留控制台窗口(可选,但推荐:大厅自身日志仍靠它)
```
然后**请用户双击 `Cyancular Ruins Server.exe`**。

Expected(**这是本 task 的判据,全部满足才算过**):
1. 出现一个 Godot 窗口(此刻是空的,`server_main.tscn` 还是光秃秃的 `Node2D`);
2. 控制台打出 `服务器就绪,等待玩家……`,7777 监听正常;
3. 用客户端建一间房 → 大厅控制台出现 `房间 … 创建`,窗口不崩。

**红则停**:说明 feature 覆盖或模板行为与 spec §4 的推断不符 ⇒ **回退这两处改动,回到 B′ 方案**,不要在错的假设上继续。

- [ ] **Step 5: Commit**

```bash
git add export_presets.cfg project.godot
git commit -m "build(server): 服务端 exe 拿回显示驱动(serverui feature + 主场景覆盖)"
```

---

### Task 1: `WorkerLauncher.classify()` + `busy_ports()`

**Files:**
- Modify: `server/lobby/worker_launcher.gd`(在 `pid_of()` 附近加两个函数)
- Create: `tests/smoke/server_status_smoke.gd`

**Interfaces:**
- Consumes: 现有私有字段 `_worker_ports: Dictionary`(port → true)、`_worker_pids: Dictionary`(port → pid)
- Produces:
  - `static func classify(ports: Array, pids: Dictionary) -> Array[Dictionary]` —— 每项 `{port: int, pid: int, alive: bool}`
  - `func busy_ports() -> Array[Dictionary]` —— 转发 `classify(_worker_ports.keys(), _worker_pids)`

- [ ] **Step 1: 写失败的冒烟(先只写 classify 这一组)**

Create `tests/smoke/server_status_smoke.gd`:

```gdscript
extends SceneTree
# 服务端控制台数据层冒烟:WorkerLauncher.classify 的三种端口占法 + (Task 2) server_status.build 的判据。
# ★ autoload-free:本文件不许引用 NetBus / LobbyRooms(/ -s 下编译期就解析不到)。
# 用法: "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd(外层套 timeout)

const WL := preload("res://server/lobby/worker_launcher.gd")


func _initialize() -> void:
	var fail := 0

	# ① 已分配、还没 spawn:pid 表里没有它
	var a: Array = WL.classify([7800], {})
	fail += _check("已分配未 spawn: 出现在结果里", a.size() == 1)
	fail += _check("已分配未 spawn: pid = 0", a.size() == 1 and int(a[0]["pid"]) == 0)
	fail += _check("已分配未 spawn: alive = false", a.size() == 1 and bool(a[0]["alive"]) == false)

	# ② 已 spawn 且活着
	var b: Array = WL.classify([7800], {7800: 12345})
	fail += _check("已 spawn: pid 带回", b.size() == 1 and int(b[0]["pid"]) == 12345)
	fail += _check("已 spawn: alive = true", b.size() == 1 and bool(b[0]["alive"]) == true)

	# ③ 已 spawn 但已退出:pid 登记了、进程不在(用一个大到不可能存在的 pid 模拟)
	#    判据 = WorkerLauncher.pid_alive(pid) 为假 ⇒ alive=false,但 pid 本身要原样带回(面板要显示它)
	var c: Array = WL.classify([7800], {7800: 999999999})
	fail += _check("已 spawn 已退出: pid 仍带回", c.size() == 1 and int(c[0]["pid"]) == 999999999)
	fail += _check("已 spawn 已退出: alive = false", c.size() == 1 and bool(c[0]["alive"]) == false)

	# ④ 空池
	fail += _check("空池 → 空数组", WL.classify([], {}).is_empty())

	if fail == 0:
		print("SERVER_STATUS_OK: classify 三种占法可区分")
		quit(0)
	else:
		printerr("SERVER_STATUS_FAIL: %d 项断言失败" % fail)
		quit(1)


func _check(name: String, cond: bool) -> int:
	if cond:
		print("  ok  - " + name)
		return 0
	printerr("  FAIL- " + name)
	return 1
```

- [ ] **Step 2: 跑它确认失败**

Run: `timeout 30 "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd`
Expected: **非 0 或 124** —— `classify` 不存在 ⇒ 编译失败 ⇒ 脚本走不到 `quit()` ⇒ 被 `timeout` 杀掉。
★ **这就是预期**,不要以为是环境坏了。

- [ ] **Step 3: 实现 classify + busy_ports**

在 `server/lobby/worker_launcher.gd` 里 `pid_of()` 之后加:

```gdscript
# 端口池快照:三种占法必须可区分(已分配未 spawn / 已 spawn 活着 / 已 spawn 已退出)。纯函数 ⇒ -s 可测。
# ★ "活着"用 WorkerLauncher.pid_alive 判,不要在这里另写一份 OS.is_process_running —— 那是第二份真相。
static func classify(ports: Array, pids: Dictionary) -> Array[Dictionary]:
	# 每项 {port, pid, alive};ports 是"已分配"集合,pids 只在 spawn 成功后才登记。
	...


func busy_ports() -> Array[Dictionary]:
	return classify(_worker_ports.keys(), _worker_pids)
```

- [ ] **Step 4: 跑冒烟确认通过**

Run: `timeout 30 "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd`
Expected: `SERVER_STATUS_OK: classify 三种占法可区分` 且退出码 0。

- [ ] **Step 5: Commit**

```bash
git add server/lobby/worker_launcher.gd tests/smoke/server_status_smoke.gd
git commit -m "feat(server): WorkerLauncher.classify/busy_ports —— 端口三种占法可区分"
```

---

### Task 2: `server_status.build()` 纯判据

**Files:**
- Create: `server/gui/server_status.gd`
- Modify: `tests/smoke/server_status_smoke.gd`(追加 `build` 那一组断言)

**Interfaces:**
- Consumes: Task 1 的 `ports` 形状 `[{port,pid,alive}]`
- Produces:
  - `static func build(rooms: Array[Dictionary], ports: Array[Dictionary], now_unix: float) -> Dictionary`
  - 返回 `{counts: Dictionary, rooms: Array[Dictionary], ports: Array[Dictionary]}`
  - `counts` 键:`rooms` / `waiting` / `in_match` / `lobby_players` / `workers_alive` / `ports_used` / `ports_total`
  - 返回的每个 room 项 = 输入项 + `{state: "waiting"|"in_match"|"stale", age_sec: float, worker_alive: bool, online_known: bool}`
  - ★ **`rooms` 的顺序必须与输入一致**(面板按下标取;冒烟靠这条断言 `out["rooms"][1]` 是局中那间)
  - ★ 输入 room 键(spec §6.1):`kind` / `code` / `players` / `cap` / `in_match` / `host` / `map` / `worker_port` / `worker_pid` / `created_at` / `roster`

- [ ] **Step 1: 在冒烟里追加失败断言**

先把 `server_status` 的 preload 提到**类级**(GDScript 的 `const` 只能在类级声明,函数体里不行):

```gdscript
const WL := preload("res://server/lobby/worker_launcher.gd")
const SS := preload("res://server/gui/server_status.gd")   # ← 本 task 新增(文件此时还不存在 ⇒ 编译失败)
```

然后在 `_initialize()` 里、`if fail == 0:` 之前追加:

```gdscript
	# ── server_status.build 的判据 ──
	var now := 1000.0
	# ① 局中房间:players 空是**正常**的(成员已转连 worker),人数必须按 roster 算
	var waiting := {"kind": "1v1", "code": "3310", "players": 1, "cap": 2, "in_match": false,
			"host": "阿伟", "map": "demo.cyrm", "worker_port": 0, "worker_pid": 0,
			"created_at": now - 30.0, "roster": []}
	var playing := {"kind": "royale", "code": "4821", "players": 0, "cap": 4, "in_match": true,
			"host": "阿伟", "map": "newfactory.cyrm", "worker_port": 7821, "worker_pid": 12345,
			"created_at": now - 100.0,
			"roster": [{"role": 1, "name": "阿伟"}, {"role": 2, "name": "玩家"}]}
	var stale := {"kind": "team", "code": "7734", "players": 0, "cap": 6, "in_match": true,
			"host": "玩家", "map": "newfactory.cyrm", "worker_port": 7822, "worker_pid": 999999999,
			"created_at": now - 50.0, "roster": [{"role": 1, "name": "玩家"}]}
	var ports := WL.classify([7821, 7822, 7899], {7821: 12345, 7822: 999999999})
	var out: Dictionary = SS.build([waiting, playing, stale], ports, now)

	fail += _check("counts.rooms = 3", int(out["counts"]["rooms"]) == 3)
	fail += _check("counts.waiting = 1", int(out["counts"]["waiting"]) == 1)
	fail += _check("counts.in_match = 2", int(out["counts"]["in_match"]) == 2)
	fail += _check("counts.ports_used = 3", int(out["counts"]["ports_used"]) == 3)
	fail += _check("counts.workers_alive = 1", int(out["counts"]["workers_alive"]) == 1)

	var r0: Dictionary = out["rooms"][0]
	var r1: Dictionary = out["rooms"][1]
	var r2: Dictionary = out["rooms"][2]
	# ★★ 局中房间人数按 roster(2),不是 players(0)
	fail += _check("局中房间人数按 roster = 2", int(r1["players"]) == 2)
	fail += _check("局中 state = in_match", str(r1["state"]) == "in_match")
	fail += _check("局中 online_known = false", bool(r1["online_known"]) == false)
	fail += _check("等待 state = waiting 且 online_known = true",
			str(r0["state"]) == "waiting" and bool(r0["online_known"]) == true)
	# ★★ worker 已退出必须 stale,不能显示成"对局中"
	fail += _check("worker 已退出 ⇒ state = stale", str(r2["state"]) == "stale")
	fail += _check("worker 已退出 ⇒ worker_alive = false", bool(r2["worker_alive"]) == false)
	fail += _check("房龄 = now - created_at", is_equal_approx(float(r0["age_sec"]), 30.0))
```

- [ ] **Step 2: 跑它确认失败**

Run: `timeout 30 "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd`
Expected: 非 0 或 124(`server/gui/server_status.gd` 不存在 ⇒ preload 编译失败 ⇒ 挂起被 timeout 杀)。

- [ ] **Step 3: 实现 `server/gui/server_status.gd`**

纯静态、**零 autoload 依赖**、**不引用 `LobbyRooms`**。`build()` 里:
- 逐房:人数 = `roster.size()` if `in_match` else `players`;`state` 按 `in_match` + `worker_alive` 判
  (见 Review Focus 2 / 3);`age_sec = now_unix - created_at`;`online_known = (state == "waiting")`;
- `counts` 从**归一化后的** rooms + ports 汇总(`workers_alive` 数 `ports` 里 `alive == true` 的项);
- `ports_total` 用 `WorkerLauncher.WORKER_PORT_SPAN`(★ 单一来源,别写 500);
- 原样带回 `ports`(UI 要显示色/序号)。

- [ ] **Step 4: 跑冒烟确认通过**

Run: `timeout 30 "$GODOT" --headless --path . -s res://tests/smoke/server_status_smoke.gd`
Expected: `SERVER_STATUS_OK` 且退出码 0。

- [ ] **Step 5: 变异验证(档 2 的必做项)**

临时把 `build()` 里"局中人数按 roster"改成 `players`(即改回 bug),重跑冒烟 ⇒ 必须红;改回来 ⇒ 必须绿。
★ 这一步就是本计划承诺的那条承重断言的变异验证,做完恢复原状。

- [ ] **Step 6: Commit**

```bash
git add server/gui/server_status.gd server/gui/server_status.gd.uid tests/smoke/server_status_smoke.gd
git commit -m "feat(server): server_status.build —— 房间/端口快照纯判据(含局中人数与 stale 判据)"
```

---

### Task 3: 面板骨架(概览条 + 房间表)+ 适配层 + 接线

**Files:**
- Create: `server/gui/lobby_snapshot.gd`(适配层,**不可冒烟**)
- Create: `server/gui/server_panel.tscn` + `server/gui/server_panel.gd`
- Modify: `server/server_main.gd:118`(留住 RoomManager 引用)、`server_main.gd:110-125`(大厅分支实例化面板)

**Interfaces:**
- Consumes: Task 2 的 `server_status.build(rooms, ports, now_unix)`;`WorkerLauncher.busy_ports()`
- Produces:
  - `lobby_snapshot.gd`:`static func collect(lobby: LobbyRooms, launcher: WorkerLauncher) -> Array[Dictionary]`(**room 输入字典**的数组,键同 Task 2)
  - `server_panel.gd`:`func setup(room_manager: RoomManager) -> void` —— 面板唯一入口,由 `server_main.gd` 注入
  - ★ **取 launcher 的路径**:`room_manager.lobby.launcher` —— `LobbyRooms.launcher` 是**公开字段**
    (`lobby_rooms.gd:23`,由 RoomManager 注入),而 `RoomManager._launcher` 是私有的。
    **不要**为面板新增公开口:那是为一个读者加一层门。

- [ ] **Step 1: 写适配层 `server/gui/lobby_snapshot.gd`**

把 `lobby.rooms` / `lobby.royale_rooms` / `lobby.team_rooms` 读成 Task 2 要的那组字典。三个来源的字段不同,按各自类取:
- `Room`(1v1):`cap = 2`、`in_match = started`、`host` 取 `players[0]` 的昵称(空则 `roster[0]`)
- `RoyaleRoom`:`cap = max_players`、`in_match = in_match`、`host` 用 `_host_name_of(_room_host_role(rr), rr.roster)` 同款逻辑
- `TeamRoom`:`cap = LobbyRooms.TEAM_ROLES`、`in_match = in_match`
- `roster`:`room.roster` 原样(局中已冻结);`created_at` 取各自字段
- ★ 处内不能有判据逻辑(判据全在 `server_status.build`),这里只做**字段搬运**;判据搬进来 = 又一份真相。

- [ ] **Step 2: 改 `server_main.gd` 的大厅分支(保持承重行的位置)**

`server_main.gd:118` 那行改成留引用:

```gdscript
	_room_manager = RoomManager.new()
	add_child(_room_manager)
	_add_console_panel()          # 新增;内部 headless 早退
```
并在类头加 `var _room_manager: RoomManager = null`。
★ **不许动**这行与 `set_process(false)`(第 125 行)之间的结构:注释明写那一段的位置是承重的,
且钉它的探针已删·2026-10-09 ⇒ 今天零守卫(见 spec §6)。

- [ ] **Step 3: 写 `_add_console_panel()`(headless 守卫 + 窗口尺寸)**

```gdscript
# 服务端控制台面板:只在有真显示后端时挂载。★ --headless 下必须一个节点都不建 ——
# 产物冒烟(build_release.py)与所有测试跑批都在 headless 下起服务端,实例化面板会让它们一起红。
func _add_console_panel() -> void:
	if DisplayServer.get_name() == "headless":
		return
	# ★ Settings.apply_display() 在非 headless 下会按**玩家存档**改窗口尺寸/全屏(settings.gd:113);
	#   服务端窗口必须是固定的小窗,故在这里显式覆盖回来。别去改 Settings:那是公共配置层。
	get_window().size = Vector2i(1280, 960)
	get_window().mode = Window.MODE_WINDOWED
	var panel = preload("res://server/gui/server_panel.tscn").instantiate()
	add_child(panel)
	panel.setup(_room_manager)
```

- [ ] **Step 4: 写面板场景 + 脚本(只读:标题带 + 概览条 + 房间表)**

按 spec §5.1 / §5.7 的几何与常量实现:
- `CanvasLayer`(层号自定义,注释"本进程唯一")→ 满屏 `Control`,`theme = preload("res://ui/theme/menu_theme.tres")` → `ColorRect(C_BG)` → `MarginContainer`(四边 **76**)→ `VBoxContainer`(separation **24**)
- 标题带:`UiFactory.header_strip("服 务 器 控 制 台")` + **就地覆盖左右内边距到 32**(spec §5.7 的坑:工厂默认左 0 是菜单页的决定)
- 概览条:`UiFactory.menu_panel(Vector2(32, 14))`;主行 32 号 = 房间/待开局/对局中/worker 在跑/端口 x·500/已运行;脚注 **16** = 公网/转发提示 + 本机 IP
- 房间表:行高 **60**、间隔 **8**、`ScrollContainer(MAXIMIZE_FIRST, custom_maximum_size.y = 6*60+5*8)`;列头 **32** 号 `C_TEXT_DIM`;每行 `row_box`,7 列(房号/模式/人数/状态/端口/房龄/地图),地图列 `UiFactory.fit_name(map, 15)`
- 刷新:自己的 `_process`,**每 0.5s**;每次刷新**只调一次** `lobby_snapshot.collect()` + 一次 `build()`(spec §6 的"一次刷新只读一次快照");房号集合不变则**原地改文字**,变了才增删行
- ★ 行状态颜色:`waiting → C_TEXT_DIM`、`in_match → C_GOLD`、`stale → C_DANGER`(spec §5.6)

- [ ] **Step 5: 加 `--panel-audit` 诊断开关(设计期仪器的落点)**

仿 `--matchsync-diag` 的纪律(开关关着时**一行都不打**):`OS.get_cmdline_user_args().has("--panel-audit")` 为真时,
延迟 3 帧后遍历所有 `Label`/`Button`/`RichTextLabel`/`VScrollBar`,打印它们到最近一层 `PanelContainer` 的四向内缩
(格式:`INSET <类> L.. R.. T.. B.. <文本前 20 字>`),然后不打别的。这是**设计期仪器,不是守卫**。

- [ ] **Step 6: headless 不回归(agent 自跑)**

Run:
```bash
timeout 60 "$GODOT" --headless --path . --quit-after 90 res://server/server_main.tscn
```
Expected: 照常打出 `服务器就绪,等待玩家……`,**无** `SCRIPT ERROR`,退出码 0。

- [ ] **Step 7: 非 headless 看版式(★ 先告知用户会弹窗,再由用户或 agent 跑)**

Run:
```bash
"$GODOT" --path . res://server/server_main.tscn -- --panel-audit
```
Expected: 窗口出现,几何账三面都成立——① 所有文字不顶格(审计里除标题带左 32 外无 `L 0`);② 整页在 76 边距内;
③ 列头与数据行**同列**。版式细节按 spec §5 人眼验收(**不写自动化守卫**)。
★ 若此时已无空房,客户端建一间再刷新。

- [ ] **Step 8: Commit**

```bash
git add server/gui/lobby_snapshot.gd server/gui/lobby_snapshot.gd.uid \
        server/gui/server_panel.tscn server/gui/server_panel.gd server/gui/server_panel.gd.uid \
        server/server_main.gd
git commit -m "feat(server): 控制台面板骨架(概览条 + 房间表)—— 只读,headless 早退"
```

---

### Task 4: 名单块 + 选中态

**Files:**
- Modify: `server/gui/server_panel.gd`

**Interfaces:**
- Consumes: Task 3 的 `_snapshot()`(本 task 内改名成返回 `(rooms, counts)` 的取数口)
- Produces: 无(内部)

- [ ] **Step 1: 加「所选房间」+「名单」两块(右列 648 宽)**

按 spec §5.7:**点房间行 = 选中**;刷新时**按房号保持选中**;房没了 ⇒ 退回空态并隐藏右列两块(**不退回第一行**)。
- 所选房间:房号 **48**(全屏唯一主角)+ 模式徽标 32 + `端口 x · 进程 y 在` 32 + 「关闭房间」按钮 **420×64**(本 task 只占位,不接动作)
- 名单:一行一人(序号 32 `C_TEXT_DIM` + `UiFactory.fit_name(名, 14)` 32 + 状态),行高 **44**、间隔 8、
  `ScrollContainer(MAXIMIZE_FIRST, custom_maximum_size.y = 5*44+4*8)`;标题右侧显示人数
- ★ **局中房间的名单来自冻结 roster**,标题必须写「局中快照」;`online_known == false` 时**不许**标「在线」(spec §5.6)

- [ ] **Step 2: 非 headless 复核(★ 先告知用户会弹窗)**

Run: `"$GODOT" --path . res://server/server_main.tscn -- --panel-audit`
Expected: 右列两块不溢出 648(审计里 `R` 不小于 32)、名单 32 号字与 `fit_name(…,14)` 生效、
选中行有 2px `C_ACCENT` 描边;切一间局中房 → 名单标题显示「局中快照」。

- [ ] **Step 3: Commit**

```bash
git add server/gui/server_panel.gd
git commit -m "feat(server): 面板右列 —— 所选房间 + 名单(局中标注快照)"
```

---

### Task 5: 日志区(可见滚动条 + tail + 跟随)

**Files:**
- Modify: `server/gui/server_panel.gd`
- Modify: `server/lobby/worker_launcher.gd`(只读复用 `log_path(port)`)

**Interfaces:**
- Consumes: `WorkerLauncher.log_path(port) -> String`(已存在)
- Produces: 无(内部)

- [ ] **Step 1: 加日志块**

按 spec §8:
- `menu_panel` + 标题「日 志」+ 右侧 `worker_<port>.log ▾ · 自动跟随中`
- `ScrollContainer(AUTO)` + `fit_content = true` 的 `RichTextLabel`(正文 **16**,`normal_font` 用
  `res://assets/fonts/menu_font.tres`,`normal_font_size = 16`)
- ★ **`EXPAND_FILL` 设在日志面板上**,不是内层 `ScrollContainer`(spec §8 实测坑:只设内层 ⇒ 面板只有 90px)
- 滚动条:宽 **16**;轨道 `C_FIELD`、滑块 `C_BORDER`、`grabber_highlight/pressed` = `C_ACCENT`
- 增量读:记住 `(路径, offset)`;路径变了就重置;每 **0.5s** 读新增字节,`max_lines` 上限约 2000 行,超了从头截断

- [ ] **Step 2: 跟随/暂停**

默认跟随到底。用户手动上滚(`scroll` 的 `get_v_scroll_bar().value` 离底部 > 阈值)⇒ 暂停跟随,
标题改为「已暂停 · 点此回到底部」;点标题或滚到底部 ⇒ 恢复跟随。
★ 面板/房间切换时重置 offset 与跟随状态。

- [ ] **Step 3: 非 headless 复核(★ 先告知用户会弹窗)**

Run: `"$GODOT" --path . res://server/server_main.tscn -- --panel-audit`
Expected(**spec §8 的三条**):① 滚动条**看得见**;② 手动上滚后新日志不再把视图拽到底、标题变「已暂停」;
③ 滚回底部/点标题 ⇒ 恢复跟随。★ 需要真打一局产生 `worker_<port>.log`,内容短于视口时滚动条不出现属正常。

- [ ] **Step 4: Commit**

```bash
git add server/gui/server_panel.gd
git commit -m "feat(server): 日志区 —— 可见滚动条 + worker 日志 tail + 跟随/暂停"
```

---

### Task 6: 「关闭房间」+ 二次确认 + 边界登记 + 文档同步

**Files:**
- Modify: `server/gui/server_panel.gd`
- Modify: `docs/eng/registered-debt.md`
- Modify: `docs/eng/netplay.md`(大厅/worker 一节补一句面板的存在与边界)
- Modify: `export_presets.cfg:13`(客户端预设 exclude 收口)

**Interfaces:**
- Consumes: `LobbyRooms.teardown_room(room, mode, msg, disconnect_peers)`;`LobbyRooms._room_any(code)`(见 Step 2)

- [ ] **Step 1: 接「关闭房间」+ 二次确认**

按钮先变「确认关闭 <房号>?」(`C_WHITE`),**3 秒**无操作回退成「关 闭 房 间」(`C_DANGER`);
第二次点才执行。执行体:
```
1. 按 (code, kind) 重新解析出**当前的**房对象;解析不到 ⇒ 不执行,刷新,面板上提示一句。
   ★ 房号空间三张表共用(都是 4 位号)⇒ 只按 code 反查会查到另一张表的同号房 ⇒ 连 kind 一起核对。
2. lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "服主关闭了本房间", true)
3. 刷新;若被关的正是当前选中房 ⇒ 清选中、退回空态
```
★ **绝不**直接动 `rooms` / `royale_rooms` / `team_rooms` / `_worker_ports` —— 端口归还与注册表删除只许出现在
`teardown_room` / `_release_port_later` 里(`tools/room_sweep_lint.gd` 钉着)。

- [ ] **Step 2: 补一个只读解析口(最小改动)**

若 `LobbyRooms` 里没有可用的 (code, kind) 解析口,加一个**只读**方法:

```gdscript
# 面板用:按 (房号, 种类) 精确取房对象;找不到返回 null。★ 只读,不做任何变更 ——
# 拆除仍必须走 teardown_room 单一收口。三张表房号空间重叠,故必须带 kind。
func room_for_panel(code: String, kind: String) -> Variant
```

- [ ] **Step 3: 客户端预设排除面板代码**

`export_presets.cfg:13`(preset.0 `Windows Desktop`)的 `exclude_filter` 末尾追加 `,server/gui/*`。
Expected: 客户端 exe 不再带运维面板资源(服务端 preset.1 **不要**加)。

- [ ] **Step 4: 跑命名检查**

Run: `python tools/check_naming.py`
Expected: 退出码 0。

- [ ] **Step 5: 端到端手验(★ 先告知用户会弹窗 + 会占 7777)**

1. 起服务端(GUI),客户端建一间 1v1 房并让两人配对开局;
2. 面板选中那间房 → 点「关闭房间」两次;
3. Expected: 房从列表消失、两端客户端收到断开/回局提示、面板概览的房间数 -1;
   **`user://logs/` 下该端口的日志文件仍在**(日志不删),端口在延迟梯到点后归还。

- [ ] **Step 6: 登记欠账**

在 `docs/eng/registered-debt.md` 追加 spec §9 的五条(面板版式零守卫 / 导出标记零守卫 / 2⁄3 非整数缩放 /
`server_main.gd:118` 位置零守卫 / `lobby_snapshot.gd` 适配层零守卫)。★ 按该文件现有分节体例插入,别另起一套。

- [ ] **Step 7: 文档同步**

`docs/eng/netplay.md` 大厅/worker 一节补**一句**:服务端 exe 现在默认带运维面板(`--headless` 下不挂载),
面板只读大客户端状态、关房走 `teardown_room`。★ 别写手抄几何数字(会漂),指针指到 spec。

- [ ] **Step 8: 全批回归(先问用户谁跑)**

Run(agent 自跑时守"真链路跑批前后 `tasklist | grep -i godot` 必须为空"):
```bash
bash tests/run_all.sh
```
Expected: 判词 `RUN_ALL OK`,且新冒烟在枚举清单里(`--list` 能看到 `server_status_smoke.gd`)。

- [ ] **Step 9: Commit**

```bash
git add server/gui/server_panel.gd server/lobby/lobby_rooms.gd \
        export_presets.cfg docs/eng/registered-debt.md docs/eng/netplay.md
git commit -m "feat(server): 关闭房间(二次确认,走 teardown_room)+ 边界登记与文档同步"
```

---

## Self-Review(计划写完后的自查)

**1. Spec 覆盖:** §2 约束 → Global Constraints 全部落条;§3 选型 → 不进计划(决策已定);
§4 构建形态 → Task 0;§5 页面设计 → Task 3/4/5;§6 数据层 → Task 1/2;§7 动作 → Task 6;
§8 日志 → Task 5;§9 守卫 → Task 2 的冒烟 + Task 6 的登记;§10 分期 → 与 Task 0–6 一一对应;§11/§12 → 不进计划。

**2. 步骤扫描:** 每个 step 一条动作;没有 "TBD / 适当校验 / 处理边界" 这类空话。
唯一的"算法由实现者写"的正文是 `classify()` 与 `build()` 的**函数体**——它们的签名与断言已把行为钉死,故只给签名。

**3. 类型一致:** `classify` → `busy_ports`,形状 `[{port,pid,alive}]`;
`server_status.build(rooms, ports, now_unix)` 的输入键与 `lobby_snapshot.collect()` 的产出键一一对应;
`state` 三值 `waiting|in_match|stale` 在 Task 2/3/6 中同名同义;`panel.setup(room_manager)` 在 Task 3 定义并调用。

**4. Review Focus:** 5 条各自落在 Task 1(端口窗口)/ Task 2(局中人数、stale)/ Task 3(headless)/ Task 6(关房竞态),
且都有对应用例或手验步骤。

**5. 篇幅:** 计划 ≈ spec 的 1.1 倍;代码块只含**测试**与**必须固定形状的片段**(配置两行、接线函数、
签名),不含面板实现正文。
