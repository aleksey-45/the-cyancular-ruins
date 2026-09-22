# 对局中的房:看得见、进不去【实施计划】

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 三个模式的大厅列表里**都能看到正在进行的房**(含有人掉线、正在宽限期里的那一档),而**谁都进不去** —— 列表照列、行点不动、服务端 join 当场拒。附带:房记录因此要**活过客户端转连**,并补上替代的回收路径(判据 = 这一局的 worker 进程还在不在)。

**Architecture:**

1. **房记录的寿命从「最后一个人离开」改到「这一局的 worker 进程退出」** —— 不新立表:记录就住在它原本那一张注册表(`rooms` / `royale_rooms` / `team_rooms`)里,于是三张表的房号空间重叠这件事**结构上无从发生**(不需要 `mode` 判别字段,也不需要跨表反查)。记录上多两个字段:`worker_pid`(spawn 成功后登记)与 `roster`(开局那一刻冻结的名单 —— 成员转连后 `players` 会空、`_peer_names` 会被擦)。
2. **回收改判「worker 进程还在不在」**(`OS.is_process_running`),30s 一条梯,走**同一处拆除收口** `teardown_room`;既有的 2h 超龄清扫原样保留作兜底。★ 为什么不能按宽限期收:宽限期是 worker 侧的状态,大厅看不见;照字面收会把房在开打 60 秒后拆掉。
3. **列表载荷各加一个同名同义的键 `in_match: bool`**(加法式扩展,老客户端忽略未知键),列表构造抽成**纯函数** `*_list_payload()` —— 因为 `NetBus.reply` 在无对端时静默跳过,不抽出来探针根本观测不到列表内容。
4. **可见性与拒绝是同一件事的两半**:列表照列(服务端)+ 行 `disabled`(界面,只是体验)+ 服务端 `join` 守卫(保证)。三模式拒绝文案统一成「该房间的对局已进行中,无法加入」,并断言**拒绝本身**(用非满房构造,否则会被"房间已满"喂绿)。

**Tech Stack:** Godot 4.7.1 GDScript;`worker_launcher.gd`(端口池 + 子进程)、`lobby_rooms.gd`(房间账本 + 拆除收口)、`room_manager.gd`(进程编排 + 定时梯);测试 = `-s` 冒烟 + 场景探针;判据一律 **grep 文本**,不看退出码。

**前置:** 无。这是独立的一批,**先于** `docs/superpowers/plans/2026-09-21-rejoin-after-leaving.md`(回大厅后回局)落地 —— 那份计划消费本计划交付的 `WorkerLauncher.pid_of/pid_alive`、房记录上的 `worker_pid`、以及「房活过转连」这条性质。

## Global Constraints

- ★★ **另一个会话正在主工作树(`E:\Workspace\godot\the-cyancular-ruins`)的 `main` 上并发开发**。本计划的一切都在 **worktree `E:\Workspace\godot\the-cyancular-ruins\.claude\worktrees\3v3-fixes`**(分支 `feat/3v3-fixes`)里做。**绝不 `cd` 到主仓库根、绝不对它做 git 操作。**
- ★ **Bash 工具在本 worktree 里会被 git 守卫误伤** ⇒ **用 PowerShell 工具**跑 Godot。console 版路径:`D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64_console.exe`。
- **测试分工**:agent 可跑 = `--import`、全部 `-s` 冒烟(`& $GODOT --headless --path . -s res://tests/<名>.gd`)、本批新增的两个场景探针、以及各页面的 `--quit-after 120 <场景>` 启动自检;**用户跑** = `tests/room_sweep_smoke.sh`(它自带的收尾会按端口杀,脚本化更稳)与**一切碰 7777 的既有脚本**(`tests/pvp_room_smoke.sh` / `tests/pvp_match_smoke.sh` / `tests/team_match_probe.sh` / `tests/royale_soak_probe.sh`)。**7777 属于用户**,agent 不得去连、去杀、去占。
- **颜色只在 `ui/ui_factory.gd` 定义**(本批**不新增任何颜色字面量**,复用既有的 `disabled` 样式);**字号只用 16 的倍数**。
- ★ **`NetBus` 的方法表一个字不动**。本批**不需要**任何新 RPC:列表载荷的形状与 RPC 名都不变,只是内容多一个键。
- ★ **定向发送前一律先判活**(`NetBus.reply` / `NetBus.is_peer_live`)—— 本批**不改**这些发送点,但列表发送点从"内联循环"变成"调纯构造函数",改的时候**别顺手把判活那层删掉**。
- ★★ **判据一律是文本**(`ALL-OK` / 探针自己的串),**不看退出码**。而本仓**实测**过:`ALL-OK` 只证明"没有任何一条断言失败",**不证明"该跑的断言都跑过"**(出错在 helper / lambda 里时调用方照常继续、判词照打,完整表述在 `tests/lib/probe_base.gd` 文件头)。**因此两个新探针都维护 `_checks` 计数并在收尾断言 `_checks >= EXPECTED_CHECKS`**;凡"这条守卫真的能咬住吗"的地方,计划里都要求做一次**变异反证**(注入缺陷 ⇒ 该条断言必须红 ⇒ 还原 ⇒ 复绿),两段输出都写进报告。
- ★ **场景探针的 `--quit-after` 逐个按预算给,不许照抄"统一 3600"**:本仓已经踩过 —— `tests/brawl_rollback_probe.tscn` 用 3600 **跑不完**(实测要 30000),安全网耗尽时进程 **exit 0、一行 `ALL-OK` 都没有**,在批量里被读成红。本批两个探针的取值都在各自任务里**写清推导**。
- ★ **新建 `.gd` 文件后跑 `--import`**(刷全局类缓存),并把 `.uid` 一起 `git add`。
- 提交信息用**单引号**或 `git commit -F 文件`,**不带任何 Claude/AI 署名行**;提交后回读一遍。每次 `git add` 只加本任务点名的文件。
- 工作区有未跟踪的 `_crashtest/` 与 `.superpowers/`(后者自带 `.gitignore`),**不要动**。
- 本批**不改** worker 侧(`server/server_main.gd` / `MatchHost` / `TeamHost` / `RoyaleHost`),**不改** `NetBusExt`,`不改`宽限期与端口归还延迟的**数值**。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `server/worker_launcher.gd` | 修改 | 新增 `_worker_pids` 表 + `pid_of(port)` + `static pid_alive(pid)`;`release_now` 一并清 pid;三个 `spawn_*` 成功后登记 |
| `server/lobby_rooms.gd` | 修改 | 三个房类各加 `worker_pid`/`roster`;新增 `freeze_roster(room)`;三个 `*_list_payload()` 纯构造;`on_peer_left` / `royale_leave` / `team_leave` 对局中不拆房;三条 `join` 的拒绝文案统一 |
| `server/room_manager.gd` | 修改 | 四个 spawn 点:`freeze_roster` + `worker_pid`;新增 `MATCH_SWEEP_INTERVAL` / `_match_sweep_acc` / `_reclaim_finished_matches()` / `static _match_over(port, pid)`,`_process` 里接上 |
| `scenes/matchmaking.gd` | 修改 | `_on_room_list` 把 `in_match` 行画成不可点的一行 |
| `scenes/royale_lobby.gd` | 修改 | `_on_royale_rooms` 同款 |
| `scenes/team_lobby.gd` | 修改 | `_on_team_rooms` 同款 |
| `tests/room_sweep_smoke.gd` | 修改 | 新增三条:①worker pid 的登记/归还 ②回收梯的接线 ③三条 join 的守卫与统一文案 |
| `tests/lobby_visibility_probe.tscn` + `.gd` + `.uid` | **新建** | 服务端面:房寿命 / 列表可见性 / 名单冻结 / 拒绝入房(三模式)/ 回收梯 |
| `tests/lobby_row_probe.tscn` + `.gd` + `.uid` | **新建** | 界面面:三个大厅页把对局中的那一行画成 `disabled` + 无 handler + `FOCUS_NONE` |
| `CLAUDE.md` | 修改 | 记录房寿命/回收判据/列表可见性/拒绝两半这几条纪律 |

## 契约(全计划共用)

```
# 端口 → worker 进程(WorkerLauncher)
pid_of(port: int) -> int        # 未登记 / 已归还 ⇒ 0
static pid_alive(pid: int) -> bool   # pid <= 0 ⇒ false

# 房记录新增(三个房类同名同义)
var worker_pid: int = 0         # spawn 成功后登记;0 = 拉起中
var roster: Array = []          # [{role:int, name:String}],开局那一刻冻结

# 列表载荷新增键(三模式同名同义)
"in_match": bool                # 对局中:照列,不可进

# 三模式统一的拒绝文案(逐字)
"该房间的对局已进行中,无法加入"
```

---

## Task 1: `WorkerLauncher` 记下每端口的 worker pid

**Files:**
- Modify: `server/worker_launcher.gd`(`:44` 一带的字段区 / `release_now:48` / `pick_port:55` 之后 / 三个 `spawn_*`:`99` `:137` `:184`)
- Modify: `tests/room_sweep_smoke.gd`(`_initialize():44` 之后 + 新函数)

**Interfaces:**
- Produces:
  - `WorkerLauncher.pid_of(port: int) -> int`(未登记 / 已归还 ⇒ 0)
  - `WorkerLauncher.pid_alive(pid: int) -> bool`(**静态**;`pid <= 0` ⇒ false)

- [ ] **Step 1: 先加冒烟断言(此时必红)**

在 `tests/room_sweep_smoke.gd` 的 `_initialize()` 里,`_check_team_spawn_guard()` **之后**、`_finish()` **之前**插一行:

```gdscript
	_check_worker_pid_tracking()
```

在同文件末尾 `_finish()` 之前加函数:

```gdscript
# ── 2026-09-21(「看得见进不去」批)新增:worker pid 的登记与归还 ──
# ★ 为什么钉它:「对局中的房什么时候消失」这条判据是**这一局的 worker 进程还在不在**
#   (三种模式的 worker 都在对局结束时自己退)。pid 的来源就是这里:端口 → pid 的映射。
# ★ 归还端口时**不清 pid** 的后果是**静默**的:大厅会认为一个已经结束(甚至端口已被复用给
#   别的局)的对局还活着 —— 房永远不出现在回收名单里,而端口与列表位一直占着。
func _check_worker_pid_tracking() -> void:
	if _fail != "":
		return
	var L := WorkerLauncher.new()
	# 直接摆内部表(与 _check_team_spawn_guard 只喂非法输入同一个取向:本冒烟不该真拉起子进程)。
	# 端口取 7770:在 WorkerLauncher 的端口池(7800~8299)之外,故意不碰大厅/worker 的号段。
	L.set("_worker_pids", {7770: 4242})
	if L.pid_of(7770) != 4242:
		_fail = "WorkerLauncher.pid_of 没读到登记过的 pid"
		return
	if L.pid_alive(0) or L.pid_alive(-1):
		_fail = "★ pid_alive(<=0) 必须是 false(登记发生在 spawn 成功之后,那之前的窗口别判成活着)"
		return
	L.release_now(7770)
	if L.pid_of(7770) != 0:
		_fail = "★ 端口归还后未清 pid(房会被判成「还在」→ 永久占着列表位与端口)"
		return
```

★ 这段代码里**不要**嵌半角双引号(会破字符串)—— 需要引号时用「」(本仓文档的既有写法)。

- [ ] **Step 2: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP FAIL: WorkerLauncher.pid_of 没读到登记过的 pid`(方法还没写 → 会先报 `Invalid call … pid_of`,同样算红)。

- [ ] **Step 3: 实现**

在 `server/worker_launcher.gd` 的 `var _worker_ports: Dictionary = {}`(`:44`)之后加字段:

```gdscript
var _worker_pids: Dictionary = {}   # port(int) -> pid(int):回收要判"这一局还在不在"
```

`release_now`(`:48`)补一行(**必须同一个函数**:归还端口与忘记 pid 是同一件事的两面):

```gdscript
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)
	# ★ 必须一起清:pid 与"端口在不在用"是同一份事实。只清一半的后果是回收梯把一个
	#   已经结束(甚至端口已被复用给别的局)的对局判成"还在" → 房永不被回收,一直挂在列表里。
	_worker_pids.erase(port)
```

在 `pick_port()` 之后追加两个访问器(紧挨端口池那两个函数,读起来才是一件事):

```gdscript
# 本端口上那具 worker 的 pid(没拉起过 / 已归还 → 0)。
# ★ 谁需要它:大厅的「这一局结束了吗」判据(`RoomManager._reclaim_finished_matches`)——
#   三种模式的 worker 都在对局结束时自己退,"进程还在吗"是唯一的精确答案;任何按
#   "一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口与列表位)。
func pid_of(port: int) -> int:
	return int(_worker_pids.get(port, 0))


# 这个 pid 还在跑吗?★ **pid <= 0 一律 false**(= "不在")。理由:pid 的登记发生在
# `OS.create_process` 成功**之后**,而 `started/in_match = true` 在它之前 —— 中间那个窗口
# 里 pid 还是 0;判"活着"会让"开局那一瞬被自己的回收梯拆掉"成为可能,判"不在"最多让那一局
# 晚一个梯周期(30s)才被发现(那时它已经有 pid 了)。
static func pid_alive(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)
```

三个 `spawn_*` 函数里,在 `var pid := OS.create_process(exe, args)` **之后**、`print(...)` **之前**各加(三处逐字相同):

```gdscript
	if pid > 0:
		_worker_pids[port] = pid
```

`spawn_worker`(`:99` 一带)/ `spawn_royale_worker`(`:137` 一带)/ `spawn_team_worker`(`:184` 一带)各一处。★ `spawn_team_worker` 里要在 `create_process` 之后、`return pid > 0` 之前 —— 那个函数中间还夹着一个 `print`。

- [ ] **Step 4: 跑冒烟确认全绿**

Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`(末尾那行照实报三档的界)。

- [ ] **Step 5: 变异反证(证明这条断言真的咬得住)**

把 `release_now` 里新加的 `_worker_pids.erase(port)` 那一行注释掉 ⇒ 跑冒烟 ⇒ 必须红在
「★ 端口归还后未清 pid(房会被判成「还在」→ 永久占着列表位与端口)」⇒ **逐字还原** ⇒ 复绿。两段输出写进报告。

- [ ] **Step 6: 提交**

```bash
git add server/worker_launcher.gd tests/room_sweep_smoke.gd
git commit -m 'feat(net): WorkerLauncher 记端口→worker pid(房回收的判据)+ 结构冒烟'
```

---

## Task 2: 1v1 —— 房活过转连 + 列表可见 + 拒绝入房(+ 三模式拒绝文案统一)

**Files:**
- Modify: `server/lobby_rooms.gd`(`Room:33` / `_generate_code:155` 之后 / `on_list_rooms:143` / `join_room:220` / `on_peer_left:244`)
- Modify: `server/room_manager.gd`(`_start_match:245`)
- Modify: `tests/room_sweep_smoke.gd`(新函数 `_check_join_refusal_guards`)
- Create: `tests/lobby_visibility_probe.tscn` + `tests/lobby_visibility_probe.gd` + `.uid`

**Interfaces:**
- Consumes: Task 1 的 `WorkerLauncher.pid_of(port)`
- Produces:
  - `LobbyRooms.Room` 多两个字段:`worker_pid: int` / `roster: Array`
  - `LobbyRooms.freeze_roster(room) -> void`
  - `LobbyRooms.room_list_payload() -> Array`(含 `"in_match"`)
  - 判据文本 `LOBBY VISIBILITY PROBE: ALL-OK`

★ **本任务的探针是本批两个探针之一**(不占任何端口、不拉子进程),后面 Task 3/4 都往它里面加相。

- [ ] **Step 1: 写 `tests/lobby_visibility_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/lobby_visibility_probe.gd" id="1"]

[node name="LobbyVisibilityProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写探针的骨架 + 相①(此时必红)**

```gdscript
extends Node

# 大厅侧「对局中的房:看得见、进不去」的服务端面场景探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn
# 判据: 文本 `LOBBY VISIBILITY PROBE: ALL-OK`(不看退出码 —— 探针挂住时 --quit-after 到期仍
#       exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ★ `--quit-after 3600`(=60s @60fps)的取值依据:本探针**全部断言都在 `_ready` 里同步跑完**,
#   跑完自己 `quit()` —— 安全网**只在探针挂住时**才用得上。本仓的教训是"安全网给薄了会把跑得
#   慢读成功能坏了"(`tests/brawl_rollback_probe.tscn` 用 3600 就跑不完,实测要 30000),
#   而这里没有任何等待(不 await、不开 socket、不拉子进程),故 3600 是"绝不可能耗尽"的量级。
#
# ═══ 为什么需要它 ═══
# ★ 本批改的是一组**闭环**:房在"客户端转连 worker"那一刻不再被拆(否则"看得见"无从谈起),
#   于是"房什么时候消失"从"有人断开"变成了"worker 退了"。三张注册表各一处判断,写错任何一处
#   都是**静默**的(房不死 = 端口与列表位永久占用;房早死 = 谁也看不见)。
# ★ 列表可见性与拒绝入房是**同一件事的两半**:房留着才会出现在列表里,而出现之后必须**进不去**。
#   只断言"列表里有它"会让一个"能点进去"的实现全绿 —— 那正是把第三人放进了别人的对局里。
#   ★★ 故拒绝那一半用**非满房**造:1v1 房里 1 人 / 大乱斗 2 人(上限 8)/ 3v3 房里 2 人时,
#   唯一的拒绝理由只剩 `started` / `in_match` —— 用满房造会被「房间已满」喂绿(等于没验)。
# ★ 本探针建的是**真 RoomManager + 真 LobbyRooms**(与生产同一条构造路径),房记录由探针手工摆:
#   本批的逻辑全在大厅进程内,不需要 socket、也不需要真 worker。
# ★ `NetBus.reply` 在"没有对端"时静默跳过 ⇒ 通过 RPC 应答观测的结果**读不到**;故列表抽成
#   `*_list_payload()` 纯构造(可直调)、拒绝看**副作用**(调用方没被 append 进 players)。
#   发送那一半由真链路探针覆盖(见设计 §6.4)。

const ROOM_1V1 := "9001"
const P_A := 101     # 假 peer id:本探针不开 socket,这些数字只用来占位
const P_B := 102
const P_C := 103

# ★★ 断言计数:ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"** ——
#   helper/lambda 里出错会让调用方照常继续、判词照打(见 tests/lib/probe_base.gd 文件头)。
#   少跑一条就红。★ 改探针**必须**同步改这个数(每个任务的步骤里都写明当次的值)。
const EXPECTED_CHECKS := 8

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


func _ready() -> void:
	_rm = RoomManager.new()
	add_child(_rm)
	# ★ 关掉大厅自己的两条梯:本探针手工驱动(与 `match_host_hygiene_probe` 关 `_physics_process`
	#   同款)。不关的话跑到 30s 时回收梯会自动触发,把探针刚摆好的房收掉 —— 断言会在
	#   "什么错都没有"的情况下变红。
	_rm.set_process(false)
	_phase_1v1()
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY VISIBILITY PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY VISIBILITY PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# ── ① 1v1:房活过"全员转连 worker",且第三人**看得见、进不去** ──
func _phase_1v1() -> void:
	var r := LobbyRooms.Room.new()
	r.code = ROOM_1V1
	r.players = [P_A, P_B]
	r.player_role = {P_A: 1, P_B: 2}
	r.started = true
	r.worker_port = 29901
	r.worker_pid = 0        # 本相不涉及回收(相④才摆 pid)
	_rm.lobby.rooms[r.code] = r
	# ★ 名单必须在**开局那一刻**冻结:成员转连 worker 后会陆续断开大厅,`players` 会空、
	#   `_peer_names` 会被擦掉 —— 靠它们渲染的列表会退化成"玩家/玩家"。
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(r)
	_check(r.roster.size() == 2, "① 开局时名单被冻进房记录(2 条)")

	# 转连:两个成员都断开大厅
	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.rooms.has(ROOM_1V1), "① ★ 全员断开大厅后房**仍在**(看得见的前提)")
	_check(r.players.is_empty(), "① 房内在线名单已空(players 的语义仍是「此刻还连在大厅这个房里的人」)")

	# C 看列表:房照列、带 in_match 标记、名字来自**冻结的那份**
	var row := _find_row(_rm.lobby.room_list_payload(), ROOM_1V1)
	_check(not row.is_empty(), "① ★ 第三人能在列表里**看到**这个房(今天它会整个消失)")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "① 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"],
			"① ★ 名单取自冻结的那份(players/_peer_names 都已空),实得 %s" % str(row.get("names", [])))
	_check(not row.is_empty() and int(row.get("players", 0)) == 2,
			"① 列表显示 2 人(取自 roster,不是取值 0 的空 players)")

	# C 试图进房:必须被拒。★ 房里只放 1 人,让**唯一**可能的拒绝理由只剩 started
	r.players = [P_A]
	var before := r.players.size()
	_rm.lobby.join_room(P_C, ROOM_1V1)
	_check(r.players.size() == before and not r.players.has(P_C),
			"① ★ 第三人 join_room 被拒(房里 1 人:唯一能拒它的就是 started)")


func _find_row(arr: Array, code: String) -> Dictionary:
	for e in arr:
		if e is Dictionary and str(e.get("code", "")) == code:
			return e
	return {}
```

- [ ] **Step 3: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: 红在 `Invalid call. Nonexistent function 'freeze_roster'`(方法还没写),且末尾**必须没有** `ALL-OK`。

- [ ] **Step 4: `Room` 类加两个字段**

`server/lobby_rooms.gd` 的 `class Room:`(`:33`)整段替换成:

```gdscript
class Room:
	var code: String = ""
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> 1/2
	var started := false                 # 已拉起 worker/已配对:拒绝再次加入
	var worker_port: int = 0              # 本房间拉起的 worker 用的 UDP 端口(关房时归还)
	# worker 进程的 pid(拉起成功后由 RoomManager 登记)。★ 它是"这一局还在不在"的唯一精确判据:
	# 三种模式的 worker 都在对局结束时自己退;0 = 还没登记(拉起中)→ 一律判**没结束**。
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超时清理用)
	var tokens: Dictionary = {}          # peer_id -> 一次性会话令牌(断线重连用;开局时按 role 下发)
	# 开局那一刻冻结的名单 [{role:int, name:String}]。★ 成员转连 worker 后会陆续断开大厅:
	# `players` 会空掉、`_peer_names` 会被擦掉 —— 对局中房间的列表渲染**只能**读这一份
	# (否则第三人看到的是"玩家, 玩家")。冻结点在 RoomManager 的四处开局。
	var roster: Array = []
```

- [ ] **Step 5: 加 `freeze_roster` **

在 `_generate_code()`(`:155`)之后加:

```gdscript
# 把"开局那一刻在房里的名单"冻进房记录(role + 昵称快照)。
# ★ 谁调:RoomManager 在**每一处开局**调一次(`_start_match` / `royale_start` /
#   `royale_start_ai` / `team_start`)—— 那是"这一局有哪些人"唯一确定的时刻。
# ★ 为什么是快照而不是"读时现算":成员转连 worker 时会**陆续断开大厅**(`on_peer_left`),
#   而那时 `players` 会被清空、`_peer_names` 会被擦掉;对局中的房要在列表里显示名单,
#   就只能靠这份冻结的副本。名单错了不报错,只会让第三人看到"玩家, 玩家"。
func freeze_roster(room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)),
				"name": str(_peer_names.get(pid, "玩家"))})
	room.roster = out
```

- [ ] **Step 6: `on_peer_left` 的 1v1 分支不拆 in-match 房**

把 `on_peer_left`(`:242`)里 1v1 那个循环的收尾(`:250-262`)整段换成:

```gdscript
		# 关房条件:**只有"还没开局"的房才因空而关**。
		# ★★ 对局中(`started`)的房**不拆**(2026-09-21):客户端转连 worker 时会**全部**断开
		#   大厅,拆了它就再也不会出现在列表里 —— "看得见"与"回局"两件事都要求它活到对局结束。
		#   回收改由 `RoomManager._reclaim_finished_matches` 按"**worker 进程还在不在**"判(精确)。
		# ★ 这里**不再发**"配对已取消(对手离开)"那句提示:房没有被取消,那句话会是假的。
		#   真出问题(对手根本没连上 worker)由客户端自己的 12s 转连兜底 / 25s claim 兜底收尾。
		# ★ 代价照实登记(见设计 §2.4):双方都在 go_match 后立刻消失时,那一个 worker 与那一个
		#   端口会白占到 2h 超龄清扫为止;玩家不会卡住。
		if room.started:
			continue
		if room.players.is_empty():
			teardown_room(room)   # 延迟归还端口(worker 会自己退;见 WORKER_PORT_REUSE_DELAY)
```

- [ ] **Step 7: `on_list_rooms` 拆成纯构造 + 发送**

把 `on_list_rooms`(`:143-153`)整段换成:

```gdscript
# 房间列表的**纯构造**(不含发送)。★ 抽出来是为了可测:探针没有对端,`NetBus.reply` 会静默
# 跳过 → 列表内容**观测不到**(与"拒绝为什么看副作用"同一个理由)。
# ★ `started`(= 对局中)的房**照列**:第三人要看得见它(用户裁定),而"进不去"由 `join_room`
#   那一侧的 `started` 守卫保证 —— 可见性与拒绝入房是同一件事的两半,缺一条就是"看不见"或"进得去"。
# ★ 对局中那一行的名单取**冻结的那份**:`players` 已空、`_peer_names` 已擦,读它们只会得到
#   "玩家/玩家"这种退化读数。
func room_list_payload() -> Array:
	var arr: Array = []
	for code in rooms:
		var room: Room = rooms[code]
		if room.players.is_empty() and not room.started:
			continue
		var names: Array = []
		var count := 0
		if room.started:
			for e in room.roster:
				names.append(str((e as Dictionary).get("name", "玩家")))
			count = room.roster.size()
		else:
			for peer_id in room.players:
				names.append(_peer_names.get(peer_id, "玩家"))
			count = room.players.size()
		arr.append({"code": code, "players": count, "names": names, "in_match": room.started})
	return arr


func on_list_rooms(caller: int) -> void:
	NetBus.reply(caller, "room_list", room_list_payload())
```

- [ ] **Step 8: 三模式的拒绝文案统一**

`join_room` 里 `if room.started:` 那一支(`:220-223`)换成:

```gdscript
	if room.started:
		# 对局中(worker 已拉起):成员已转连对局,**照列在列表里但进不去**。
		# ★ 文案不能再说"房间已满":房里可能只剩 1 人在线(对手掉线 / 自己还没转连),那是假话,
		#   而且「房间已满」会命中大厅页 `matchmaking._on_server_message` 的**自动刷新**分支 ——
		#   刷新对这一个房毫无意义(它本来就该一直在列表里)。三模式文案**逐字统一**。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
```

`royale_join` 里 `if rr.in_match:` 那一支(`:413-415`)换成:

```gdscript
	if rr.in_match:
		# 同 join_room:对局中照列但进不去;文案三模式逐字统一(见那里为什么不能说"房间已满")。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
```

`team_join` 里 `if tr.in_match:` 那一支(`:560-562`)换成:

```gdscript
	if tr.in_match:
		# 同 join_room / royale_join:文案三模式逐字统一。
		NetBus.reply(caller, "server_message", "该房间的对局已进行中,无法加入")
		return
```

★ **`matchmaking._on_server_message`(`:201-218`)一个字都不改**:它的自动刷新分支只认旧文案
(`房间已满` / `房间不存在`),新文案落到 `else` —— **只显示、不刷新**(房本就该一直在列表里)。
这是"改一个字符串静默改了行为"的典型,故 Step 10 有一条**源码级**断言钉住它。

- [ ] **Step 9: `room_manager._start_match` 冻结名单 + 登记 pid**

在 `_start_match`(`:245`)里,`room.started = true`(`:248`)之后立刻加:

```gdscript
	# ★ 开局那一刻把名单冻进房记录:成员转连 worker 后会陆续断开大厅,靠 players/_peer_names
	#   渲染的对局中列表会退化成"玩家/玩家"(见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(room)
```

在 `if not _launcher.spawn_worker(port):` 那一支 **之后**(即 spawn 成功之后)、`await get_tree().create_timer(0.3).timeout` **之前**加:

```gdscript
	# ★ spawn 成功后登记 pid:回收梯靠它判"这一局还在不在"(`WorkerLauncher.pid_of` 读的正是
	#   那张端口→pid 表)。★ 位置不能挪到 spawn 之前:拉起失败那一刻 pid 还是 0,
	#   登记一个 0 等于让回收梯晚一个周期才发现(不致命,但没有理由)。
	room.worker_pid = _launcher.pid_of(port)
```

- [ ] **Step 10: `room_sweep_smoke` 加「三条 join 的守卫 + 统一文案」断言**

在 `_initialize()` 里 `_check_worker_pid_tracking()` **之后**加一行 `_check_join_refusal_guards()`,并加函数:

```gdscript
# ── 2026-09-21(「看得见进不去」批)新增:三条 join 的**拒绝守卫与文案** ──
# ★ 为什么是源码级:文案是**发给玩家看的字符串**,而探针里没有对端 ——
#   `NetBus.reply` 在 `is_peer_live(caller)` 为假时**静默跳过**(见 NetBus.reply 的注释),
#   所以那句话在探针里根本观测不到。行为面(调用方没被 append 进 players)由
#   `tests/lobby_visibility_probe.tscn` 相①/②/③ 断言,这里断言的是**那句话本身**。
# ★ 为什么文案值得一条断言:1v1 原先对"对局进行中"说的是「房间已满」—— 那是假话,而且会命中
#   大厅页 `_on_server_message` 的**自动刷新**分支(那条只认旧文案)。改文案 = 静默改行为。
# ★ 另钉一条反向:三条守卫必须**用"这一局在进行中"判**(started / in_match),不许退化成
#   "房满 / 人数"之类的替代判据 —— 后者在"房里只剩 1 人"时放行,正是本批要堵的那档。
func _check_join_refusal_guards() -> void:
	if _fail != "":
		return
	var code := ScanUtil.code_only(ScanUtil.read("res://server/lobby_rooms.gd"))
	var cases := [
		["join_room", "if room.started:"],
		["royale_join", "if rr.in_match:"],
		["team_join", "if tr.in_match:"],
	]
	for c in cases:
		var body := ScanUtil.func_body(code, str(c[0]))
		if body.is_empty():
			_fail = "找不到 %s 的函数体" % c[0]
			return
		if not body.contains(c[1]):
			_fail = "★ %s 缺少「对局中即拒绝」的守卫(%s)—— 对局中的房会被第三人加入" % [c[0], c[1]]
			return
		if not body.contains('"该房间的对局已进行中,无法加入"'):
			_fail = "%s 的拒绝文案不是三模式统一的那一句" % c[0]
			return
```

- [ ] **Step 11: `--import` + 跑探针 + 跑冒烟**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: `LOBBY VISIBILITY PROBE: ALL-OK(8 条断言)`。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`。

- [ ] **Step 12: 变异反证(三条,逐条还原)**

1. 把 `on_peer_left` 的 1v1 分支 `if room.started: continue` 删掉 ⇒ 相① 的「房**仍在**」应红。
2. 把 `room_list_payload()` 里 `if room.started:` 那块的名字来源换回 `_peer_names` ⇒ 相① 的「名单取自冻结的那份」应红。
3. 把 `join_room` 的 `if room.started:` 守卫删掉 ⇒ 相① 的「第三人 join_room 被拒」应红。

三段输出写进报告。

- [ ] **Step 13: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd tests/room_sweep_smoke.gd \
  tests/lobby_visibility_probe.gd tests/lobby_visibility_probe.gd.uid tests/lobby_visibility_probe.tscn
git commit -m 'feat(net): 1v1 对局中的房活过转连(可见/不可进/名单冻结)+ 三模式拒绝文案统一'
```

---

## Task 3: 大乱斗 + 3v3 —— 同款(两处,一次改齐)

**Files:**
- Modify: `server/lobby_rooms.gd`(`RoyaleRoom:46` / `TeamRoom:66` / `on_peer_left` 的大乱斗与 3v3 两段 / `royale_list:454` / `team_list:619` / `royale_leave:431` / `team_leave:598` / 两条 join 的文案已在 Task 2 改完)
- Modify: `server/room_manager.gd`(`royale_start:56` / `royale_start_ai:155` / `team_start:201`)
- Modify: `tests/lobby_visibility_probe.gd`(相②③,`EXPECTED_CHECKS` 8 → 24)

**Interfaces:**
- Consumes: Task 2 的 `freeze_roster` / `worker_pid` / `room_list_payload` 的形状
- Produces: `LobbyRooms.royale_list_payload() -> Array` / `team_list_payload() -> Array`(各含 `"in_match"`)

- [ ] **Step 1: 探针追加相②③(此时必红)**

把 `tests/lobby_visibility_probe.gd` 顶部的常量改成:

```gdscript
const ROOM_1V1 := "9001"
const ROOM_ROYALE := "9002"
const ROOM_TEAM := "9003"
const P_A := 101     # 假 peer id:本探针不开 socket,这些数字只用来占位
const P_B := 102
const P_C := 103

# ★ 本值随相的增加而变(Task 3 加 ②③ 共 16 条 → 24;Task 4 加 ④ 共 3 条 → 27)。
#   少跑一条就红 —— 这正是"ALL-OK 不等于全都跑过"那条纪律的落点。
const EXPECTED_CHECKS := 24
```

在 `_ready()` 里 `_phase_1v1()` 之后插 `_phase_royale()` 与 `_phase_team()`,并加两个函数:

```gdscript
# ── ② 大乱斗:同 ①(门控是 in_match,不是 started)──
func _phase_royale() -> void:
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = ROOM_ROYALE
	rr.host_peer = P_A
	rr.players = [P_A, P_B]
	rr.player_role = {P_A: 1, P_B: 2}
	rr.max_players = 8
	rr.in_match = true
	rr.worker_port = 29902
	rr.worker_pid = 0
	_rm.lobby.royale_rooms[rr.code] = rr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(rr)
	_check(rr.roster.size() == 2, "② 开局时名单被冻进房记录(2 条)")

	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.royale_rooms.has(ROOM_ROYALE), "② ★ 全员断开大厅后大乱斗房仍在")
	_check(rr.players.is_empty(), "② 房内在线名单已空")

	var row := _find_row(_rm.lobby.royale_list_payload(), ROOM_ROYALE)
	_check(not row.is_empty(), "② ★ 第三人能在列表里看到这个房")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "② 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"], "② 名单取自冻结的那份")
	_check(not row.is_empty() and int(row.get("players", 0)) == 2, "② 列表显示 2 人(取自 roster)")

	# ★ 非满房:2/8 —— 唯一能拒的理由就是 in_match
	rr.players = [P_A]
	var before := rr.players.size()
	_rm.lobby.royale_join(P_C, ROOM_ROYALE, "")
	_check(rr.players.size() == before and not rr.players.has(P_C),
			"② ★ 第三人 royale_join 被拒(2/8 非满房:唯一能拒它的是 in_match)")


# ── ③ 3v3:同上(与大乱斗逐字同款,门控也是 in_match)──
func _phase_team() -> void:
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = ROOM_TEAM
	tr.host_peer = P_A
	tr.players = [P_A, P_B]
	tr.player_role = {P_A: 1, P_B: 2}
	tr.team_of = {1: 1, 2: 2}
	tr.in_match = true
	tr.worker_port = 29903
	tr.worker_pid = 0
	_rm.lobby.team_rooms[tr.code] = tr
	_rm.lobby._peer_names[P_A] = "阿甲"
	_rm.lobby._peer_names[P_B] = "bob"
	_rm.lobby.freeze_roster(tr)
	_check(tr.roster.size() == 2, "③ 开局时名单被冻进房记录(2 条)")

	_rm.lobby.on_peer_left(P_A)
	_rm.lobby.on_peer_left(P_B)
	_check(_rm.lobby.team_rooms.has(ROOM_TEAM), "③ ★ 全员断开大厅后 3v3 房仍在")
	_check(tr.players.is_empty(), "③ 房内在线名单已空")

	var row := _find_row(_rm.lobby.team_list_payload(), ROOM_TEAM)
	_check(not row.is_empty(), "③ ★ 第三人能在列表里看到这个房")
	_check(not row.is_empty() and bool(row.get("in_match", false)), "③ 列表行带 in_match=true")
	_check(not row.is_empty() and row.get("names", []) == ["阿甲", "bob"], "③ 名单取自冻结的那份")
	_check(not row.is_empty() and int(row.get("players", 0)) == 2, "③ 列表显示 2 人(取自 roster)")

	# ★ 非满房:2/6 —— 唯一能拒的理由就是 in_match
	tr.players = [P_A]
	tr.team_of = {1: 1}
	var before := tr.players.size()
	_rm.lobby.team_join(P_C, ROOM_TEAM, "")
	_check(tr.players.size() == before and not tr.players.has(P_C),
			"③ ★ 第三人 team_join 被拒(2/6 非满房:唯一能拒它的是 in_match)")
```

- [ ] **Step 2: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: 红在 `Invalid call. Nonexistent function 'royale_list_payload'`(两个新函数还没写),且末尾没有 `ALL-OK`。

- [ ] **Step 3: 两个房类各加两个字段**

`class RoyaleRoom:`(`:46`)的字段区整段替换成:

```gdscript
class RoyaleRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(房内成员,**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..N,大乱斗角色号)
	var is_public := true
	var invite_code := ""                 # 私密房凭此码进入
	var max_players := ROYALE_DEFAULT_MAX
	var options: Dictionary = {}          # 房主对局选项(禁武器/回合回血),开局随房主生效
	var in_match := false                 # 已开局(拒绝加入;成员转连 worker 后房**仍保留**,见 on_peer_left)
	var worker_port: int = 0              # 本房拉起的大乱斗 worker 端口(关房时归还)
	# worker 进程的 pid(拉起成功后由 RoomManager 登记;0 = 拉起中 → 判"没结束")。理由见 Room.worker_pid
	var worker_pid: int = 0
	var created_at: float = 0.0           # 创建时间戳(unix 秒;超龄清理用,与 Room.created_at 同形)
	var tokens: Dictionary = {}          # peer_id -> 一次性会话令牌(断线重连用;开局时按 role 下发)
	# 开局那一刻冻结的名单 [{role:int, name:String}](理由见 Room.roster 的注释)
	var roster: Array = []
```

`class TeamRoom:`(`:66`)的字段区整段替换成:

```gdscript
class TeamRoom:
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []          # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}      # peer id -> role(1..6,最小空闲号)
	var team_of: Dictionary = {}          # role(int) -> 1/2(**选边前不在表里**)
	var is_public := true
	var invite_code := ""
	var in_match := false
	var worker_port: int = 0
	# worker 进程的 pid(拉起成功后由 RoomManager 登记;0 = 拉起中 → 判"没结束")。理由见 Room.worker_pid
	var worker_pid: int = 0
	var created_at := 0.0
	var tokens: Dictionary = {}           # peer_id -> 会话令牌(断线重连用)
	# 开局那一刻冻结的名单 [{role:int, name:string}](理由见 Room.roster 的注释)
	var roster: Array = []
```

★ `tokens` 这一行**本批保留**(它是断线重连阶段 1 的遗留;由后继的回局计划整体删除并换成独立凭据表)。

- [ ] **Step 4: `on_peer_left` 的两段不拆 in-match 房**

大乱斗那一段(`:264-283`)里 `if rr.players.is_empty():` 那一支(`:270-273`)换成:

```gdscript
		# ★ 对局中(`in_match`)的房**不拆**(2026-09-21):成员转连 worker 时会全部断开大厅,
		#   拆了就再也不会出现在列表里。回收改由 `_reclaim_finished_matches` 按"worker 进程还在不在"判。
		#   ★ 这里**不再发**那句"配对已取消"式的提示(与 1v1 同款理由:房没有被取消)。
		if rr.in_match:
			continue
		if rr.players.is_empty():
			# 大乱斗按默认一局时长给更长的回收延迟(远长于 1v1,自检 M2);已知边界见
			# WorkerLauncher.ROYALE_PORT_REUSE_DELAY 的常量注释
			teardown_room(rr)
		else:
			if rr.host_peer == peer_id:
				rr.host_peer = rr.players[0]
				print("大乱斗房 %s 房主转移 → peer %d" % [rcode, rr.host_peer])
			# ★ 已开局的房**不广播等待室状态**(既有理由:成员正在转连 worker,发给它们必然踩
			#   "max channels: 0" 且包丢)。这一条 `if` 现在永远为真(in_match 已在上面 continue),
			#   但**保留**它:它是那件事的守卫,不是死代码 —— 删了会让后来者以为"开局后也可以广播"。
			if not rr.in_match:
				_broadcast_royale_state(rr)
```

3v3 那一段(`:291-310`)里 `if tr.players.is_empty():` 那一支(`:301-302`)换成:

```gdscript
		if tr.in_match:
			continue   # 对局中:房活到 worker 退出(理由与大乱斗逐字同款)
		if tr.players.is_empty():
			teardown_room(tr)
		else:
			if tr.host_peer == peer_id:
				tr.host_peer = tr.players[0]
				print("3v3 房 %s 房主转移 → peer %d" % [tcode, tr.host_peer])
			if not tr.in_match:
				_broadcast_team_state(tr)
```

- [ ] **Step 5: 两条 `*_leave` 加同款守卫**

`royale_leave`(`:431`)的空房分支整段换成:

```gdscript
	if rr.players.is_empty() and not rr.in_match:
		# 「退出房间」按钮**不断开大厅 peer** → on_peer_left 不会为它触发;房间随即从注册表摘除,
		# 而 sweep / on_peer_left 都只遍历注册表 → 之后**再无任何路径**能归还本房端口。
		# 故与其他大乱斗拆除路径同法归还,并同样走大乱斗那条更长的复用延迟。
		# ★ 对局中不拆(与 on_peer_left 同款):否则"看得见"与"回局"都没了。
		teardown_room(rr)
	else:
		# ★ 房主转移那一行必须带 `not rr.players.is_empty()`:对局中的房可能**一个人都不在线**
		#   (全体转连走了),而 `rr.players[0]` 在空数组上会**越界报错**(静默改行为的典型)。
		if rr.host_peer == caller and not rr.players.is_empty():
			rr.host_peer = rr.players[0]
		# 已开局的房不广播等待室状态(与 on_peer_left 同一理由)
		if not rr.in_match:
			_broadcast_royale_state(rr)
```

`team_leave`(`:598`)的空房分支整段换成:

```gdscript
	if tr.players.is_empty() and not tr.in_match:
		# ★ 「退出房间」按钮**不断开大厅 peer** → on_peer_left 不会为它触发;房间随即摘除,
		#   而 sweep / on_peer_left 只遍历注册表 → 之后再无路径归还端口(与 royale_leave 同款坑)。
		teardown_room(tr)
	else:
		# ★ 同 royale_leave:对局中的房可能一个人都不在线,`tr.players[0]` 之前必须判空。
		if tr.host_peer == caller and not tr.players.is_empty():
			tr.host_peer = tr.players[0]
		if not tr.in_match:
			_broadcast_team_state(tr)
```

- [ ] **Step 6: 两条列表拆成纯构造 + 发送**

`royale_list`(`:454-469`)整段换成:

```gdscript
# 公开房间列表的**纯构造**(理由同 room_list_payload:无对端时 reply 静默跳过 ⇒ 不抽出来
# 探针观测不到)。★ 只列**公开**房;`in_match` 的房**照列**(第三人要看得见),未开局的空房
# 仍不列(那是幽灵房)。
func royale_list_payload() -> Array:
	var arr: Array = []
	for code in royale_rooms:
		var rr: RoyaleRoom = royale_rooms[code]
		if not rr.is_public:
			continue
		if rr.in_match:
			var dn: Array = []
			for e in rr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": code, "players": rr.roster.size(), "max_players": rr.max_players,
					"names": dn, "in_match": true})
			continue
		if rr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in rr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": code, "players": rr.players.size(),
				"max_players": rr.max_players, "names": names, "in_match": false})
	return arr


func royale_list(caller: int) -> void:
	# 判活同 NetBus.reply:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	# 本节点(NetBusExt)没有自己的 reply 助手 —— 判据是**跨节点的单一来源**(NetBus.is_peer_live),
	# 所以这里显式判一次;大厅里其余 NetBusExt 站定走的是 `is_peer_online` 包一层。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "royale_rooms", royale_list_payload())
```

`team_list`(`:619-632`)整段换成:

```gdscript
# 公开 3v3 房间列表的**纯构造**(与 royale_list_payload 逐字同款,`max_players` 取 TEAM_ROLES)
func team_list_payload() -> Array:
	var arr: Array = []
	for c in team_rooms:
		var tr: TeamRoom = team_rooms[c]
		if not tr.is_public:
			continue
		if tr.in_match:
			var dn: Array = []
			for e in tr.roster:
				dn.append(str((e as Dictionary).get("name", "玩家")))
			arr.append({"code": c, "players": tr.roster.size(), "max_players": TEAM_ROLES,
					"names": dn, "in_match": true})
			continue
		if tr.players.is_empty():
			continue
		var names: Array = []
		for peer_id in tr.players:
			names.append(_peer_names.get(peer_id, "玩家"))
		arr.append({"code": c, "players": tr.players.size(),
				"max_players": TEAM_ROLES, "names": names, "in_match": false})
	return arr


func team_list(caller: int) -> void:
	# 判活同 royale_list:请求与断开可能挤在同一次 poll 里(见 NetBus.reply 的注释)。
	if NetBus.is_peer_live(caller):
		NetBusExt.rpc_id(caller, "team_rooms", team_list_payload())
```

- [ ] **Step 7: `room_manager` 的三个 spawn 点冻结名单 + 登记 pid**

`royale_start`(`:56`)、`royale_start_ai`(`:155`)、`team_start`(`:201`)三处,各做两件事:

1. 在 `rr.in_match = true`(或 `tr.in_match = true`)**之后**加:

```gdscript
	# ★ 开局那一刻把名单冻进房记录(理由见 LobbyRooms.freeze_roster 的注释)。
	lobby.freeze_roster(rr)   # team_start 里把 rr 换成 tr
```

2. 在 `if not _launcher.spawn_royale_worker(...):` / `if not _launcher.spawn_team_worker(...):` 那一支 **之后**、`await get_tree().create_timer(0.3).timeout` **之前**加:

```gdscript
	rr.worker_pid = _launcher.pid_of(port)   # team_start 里把 rr 换成 tr
```

★ `ai_duel`(`:115`)**不在这四处里**:它是"单人 + AI"、当场就把房从注册表摘掉的既有路径,与本批无关,**一个字不动**。

- [ ] **Step 8: `--import` + 跑探针 + 硬校验**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: `LOBBY VISIBILITY PROBE: ALL-OK(24 条断言)`。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/team_room_smoke.gd`
Expected: `TEAM ROOM SMOKE: ALL-OK`(回归:三路互斥**双向**判定没被碰坏)。

- [ ] **Step 9: 变异反证(三条,逐条还原)**

1. 把大乱斗那一段的 `if rr.in_match: continue` 删掉 ⇒ 相② 的「大乱斗房仍在」应红。
2. 把 `royale_list_payload()` 里 `if rr.in_match:` 那一块与普通那一块的**顺序对调**(即先判 `players.is_empty() → continue`)⇒ 相② 的「第三人能看到这个房」应红。
3. 把 `team_join` 的 `if tr.in_match:` 守卫删掉 ⇒ 相③ 的「team_join 被拒」应红,且 `room_sweep_smoke` 的守卫断言也应红(两条一起红才算真的验到了)。

三段输出写进报告。

- [ ] **Step 10: 提交**

```bash
git add server/lobby_rooms.gd server/room_manager.gd tests/lobby_visibility_probe.gd
git commit -m 'feat(net): 大乱斗/3v3 对局中的房活过转连 + 列表纯构造(含 in_match)'
```

---

## Task 4: 对局结束即回收(`_reclaim_finished_matches`)+ 探针相④

**Files:**
- Modify: `server/room_manager.gd`(`:28` 一带的常量区 / `_process:289` / `_sweep_stale_rooms` 之后)
- Modify: `tests/room_sweep_smoke.gd`(新函数 `_check_reclaim_ladder`)
- Modify: `tests/lobby_visibility_probe.gd`(相④,`EXPECTED_CHECKS` 24 → 27)

**Interfaces:**
- Consumes: Task 1 的 `WorkerLauncher.pid_alive(pid)`
- Produces:
  - `RoomManager.MATCH_SWEEP_INTERVAL := 30.0`
  - `RoomManager._reclaim_finished_matches() -> void`
  - `static RoomManager._match_over(port: int, pid: int) -> bool`

★ **为什么必须有这一步**(设计 §2.4):房不再在转连那一刻被拆,**就没有任何东西会拆它** → 端口与列表位永久占用。这是本层"端口泄漏"补过的第五次,故回收**必须走同一处拆除收口**。

- [ ] **Step 1: 探针追加相④(此时必红)**

`tests/lobby_visibility_probe.gd`:把 `EXPECTED_CHECKS` 改成 `27`,`_ready()` 里 `_phase_team()` 之后插 `_phase_reclaim()`,并加函数:

```gdscript
# ── ④ 对局结束即回收:worker 进程还在 → 房不许动;worker 退了 → 房必须被回收 ──
# ★ 判据是"**worker 进程还在不在**":三种模式的 worker 都在对局结束时自己退,而任何按
#   "一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口与列表位)。
# ★ 反向那一半(**活的 pid 不回收**)不能省:只断言"死的会收"会让一个"见谁收谁"的实现全绿,
#   而那会把正在进行的对局连端口一起端掉。
# ★ 第三条(pid 还没登记)**同样不能省**:`worker_pid` 的登记发生在 `create_process` 成功
#   **之后**,把 0 判成"结束"会让开局那一瞬被自己的回收梯拆掉。
func _phase_reclaim() -> void:
	# 活的 pid:用**本进程自己** —— 它一定活着,不需要拉起任何子进程
	var live := OS.get_process_id()
	var r := LobbyRooms.Room.new()
	r.code = "9011"
	r.started = true
	r.worker_port = 29911
	r.worker_pid = live
	_rm.lobby.rooms[r.code] = r
	var rr := LobbyRooms.RoyaleRoom.new()
	rr.code = "9012"
	rr.in_match = true
	rr.worker_port = 29912
	rr.worker_pid = 999999        # 本机上不该存在的 pid
	_rm.lobby.royale_rooms[rr.code] = rr
	var tr := LobbyRooms.TeamRoom.new()
	tr.code = "9013"
	tr.in_match = true
	tr.worker_port = 29913
	tr.worker_pid = 0             # ★ 还没登记 pid(拉起中)→ **不得**被判成结束
	_rm.lobby.team_rooms[tr.code] = tr

	_rm._reclaim_finished_matches()
	_check(_rm.lobby.rooms.has("9011"), "④ ★ worker pid 活着(本进程)→ 房**不许**被回收")
	_check(not _rm.lobby.royale_rooms.has("9012"), "④ worker pid 已退 → 大乱斗房必须被回收")
	_check(_rm.lobby.team_rooms.has("9013"), "④ ★ pid 还没登记(拉起中)→ 不得判成结束")
```

- [ ] **Step 2: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: 红在 `Invalid call. Nonexistent function '_reclaim_finished_matches'`,且末尾没有 `ALL-OK`。

- [ ] **Step 3: 实现回收梯**

`server/room_manager.gd` 常量区(`:28` 的 `TEAM_MATCH_ESTIMATE` 之后)加:

```gdscript
# 对局中房间的回收梯周期(秒)。★ 比 SWEEP_INTERVAL(600s)密得多,因为判据与目的都不同:
# 那条是"房挂太久了"(超龄清扫),这条是"**这一局结束了**" —— 端口与列表位白占的代价是
# "池子少一个 / 列表里挂着一个死房",10 分钟一轮意味着每局结束后要多占最多 10 分钟。
# 30s 是"比端口归还延迟(120/360)小一个量级"的量级选择,与宽限期无关(判据不读宽限期)。
const MATCH_SWEEP_INTERVAL := 30.0
var _match_sweep_acc := 0.0
```

`_process`(`:289`)末尾追加(**不动**上面那条 600s 的梯):

```gdscript
	# ★ 对局中房间的回收走**另一条更密的**梯(判据与目的都不同,见 MATCH_SWEEP_INTERVAL)。
	_match_sweep_acc += delta
	if _match_sweep_acc >= MATCH_SWEEP_INTERVAL:
		_match_sweep_acc = 0.0
		_reclaim_finished_matches()
```

在 `_sweep_stale_rooms` 之后加:

```gdscript
# 对局结束即回收:`in_match`(1v1 是 `started`)的房不再在"客户端转连 worker"那一刻被拆,
# 于是**必须有替代的回收路径** —— 否则端口与列表位永久占用(本层为「端口泄漏」这同一个失败
# 模式补过的第五次)。
# ★ 判据 = **worker 进程还在不在**(`WorkerLauncher.pid_alive`):三种模式的 worker 都在对局
#   结束时自己退(1v1 宽限到点收场退进程 / 大乱斗与 3v3 全员走光),这是"这局结束了吗"的
#   **精确**答案;任何按"一局大约多久"估的界都会既早(收掉还在打的局)又晚(白占端口)。
# ★ 兜底仍在:2h 超龄清扫(`_sweep_stale_rooms`)会把"worker 一直不退"的僵尸房连进程一起杀掉
#   —— 两条路径并存,不是二选一。
# ★ 回收**必须走拆除单一收口**(端口归还/注册表删除只许出现在 `lobby_rooms.teardown_room`
#   与 `_release_port_later` 里;`room_sweep_smoke` 的 `_check_reclaim_ladder` 钉住本函数)。
func _reclaim_finished_matches() -> void:
	var done: Array = []
	for code in lobby.rooms:
		var room: LobbyRooms.Room = lobby.rooms[code]
		if room.started and _match_over(room.worker_port, room.worker_pid):
			done.append(room)
	for rcode in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[rcode]
		if rr.in_match and _match_over(rr.worker_port, rr.worker_pid):
			done.append(rr)
	for tcode in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[tcode]
		if tr.in_match and _match_over(tr.worker_port, tr.worker_pid):
			done.append(tr)
	for room in done:
		var kind := "大乱斗房" if room is LobbyRooms.RoyaleRoom \
				else ("3v3 房" if room is LobbyRooms.TeamRoom else "房间")
		print("[lobby] 对局结束,回收%s %s(端口 %d)" % [kind, room.code, room.worker_port])
		lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)


# 这一局结束了吗(worker 进程已经不在)?★ `port <= 0` 或 `pid <= 0` 一律**不算**结束 ——
# 那两种取值都只出现在"拉起中"的窗口里(`worker_port` 在 `pick_port` 之后才赋值,pid 在
# `create_process` 成功之后才登记),判成结束会让开局那一瞬被自己的回收梯拆掉。
static func _match_over(port: int, pid: int) -> bool:
	if port <= 0 or pid <= 0:
		return false
	return not WorkerLauncher.pid_alive(pid)
```

- [ ] **Step 4: `room_sweep_smoke` 加「回收梯接线」断言**

在 `_initialize()` 里 `_check_join_refusal_guards()` **之后**加一行 `_check_reclaim_ladder()`,并加函数:

```gdscript
# ── 2026-09-21 新增:对局中房间的**回收梯接线** ──
# ★ 为什么"接线"要单独钉:行为探针(`tests/lobby_visibility_probe.tscn` 相④)是**手工调**
#   `_reclaim_finished_matches()` 的 —— 把 `_process` 里那次调用删掉,行为探针**照样全绿**,
#   而生产里房永远不会被回收(端口与列表位白占)。本仓对这类"两半"的既有先例:
#   `team_room_smoke` ⑨①(接线面)对 `hud_declarative_probe` ③(行为面)—— 缺一不可。
# ★ 另一条:回收不能绕道直接删注册表。既有的 `_check_teardown_funnel` 只扫
#   `server/lobby_rooms.gd`,**扫不到写在 room_manager 里的绕道** —— 那正是本函数存在的理由。
func _check_reclaim_ladder() -> void:
	if _fail != "":
		return
	var src := ScanUtil.read("res://server/room_manager.gd")
	if src.is_empty():
		_fail = "无法读取 room_manager.gd"
		return
	var code := ScanUtil.code_only(src)
	if not code.contains("const MATCH_SWEEP_INTERVAL := 30.0"):
		_fail = "缺 MATCH_SWEEP_INTERVAL=30 常量(回收梯的周期)"
		return
	var proc := ScanUtil.func_body(code, "_process")
	if proc.is_empty():
		_fail = "找不到 RoomManager._process"
		return
	if not proc.contains("_reclaim_finished_matches()"):
		_fail = "★ _process 没调 _reclaim_finished_matches —— 对局结束后房与端口永不被回收"
		return
	var fn := ScanUtil.func_body(code, "_reclaim_finished_matches")
	if fn.is_empty():
		_fail = "找不到 _reclaim_finished_matches"
		return
	if not fn.contains("teardown_room("):
		_fail = "★ 回收梯没走拆除单一收口(端口归还/注册表删除只许出现在 teardown_room)"
		return
	# 三张注册表都要被扫:漏一张 = 那张的房永不被回收(静默端口泄漏,本层补过五次的那个模式)
	for pat in ["for code in lobby.rooms", "for rcode in lobby.royale_rooms", "for tcode in lobby.team_rooms"]:
		if not fn.contains(pat):
			_fail = "★ 回收梯漏扫了一张注册表(%s)→ 那张的房与端口永不被回收" % pat
			return
	var mo := ScanUtil.func_body(code, "_match_over")
	if mo.is_empty():
		_fail = "找不到 _match_over"
		return
	if not mo.contains("pid <= 0") or not mo.contains("port <= 0"):
		_fail = "★ _match_over 没把 port/pid <= 0 判成「没结束」(开局那一瞬会被自己的回收梯拆掉)"
		return
```

- [ ] **Step 5: `--import` + 跑探针与冒烟**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn`
Expected: `LOBBY VISIBILITY PROBE: ALL-OK(27 条断言)`。
Run(PowerShell):`& $GODOT --headless --path . -s res://tests/room_sweep_smoke.gd`
Expected: `SMOKE_ROOM_SWEEP OK: …`。

- [ ] **Step 6: 变异反证(三条,逐条还原)**

1. 把 `_match_over` 的 `if port <= 0 or pid <= 0: return false` 删掉 ⇒ 相④ 的「pid 还没登记不得判成结束」应红。
2. 把 `_reclaim_finished_matches` 里 `lobby.teardown_room(room, LobbyRooms.TEARDOWN_DELAYED)` 换成 `lobby.royale_rooms.erase(room.code)` ⇒ `room_sweep_smoke` 的「回收梯没走拆除单一收口」应红。
3. 把 `_process` 里新加的三行删掉 ⇒ `room_sweep_smoke` 的「`_process` 没调 `_reclaim_finished_matches`」应红。

三段输出写进报告。

- [ ] **Step 7: 提交**

```bash
git add server/room_manager.gd tests/room_sweep_smoke.gd tests/lobby_visibility_probe.gd
git commit -m 'feat(net): 对局结束即回收房(判据 = worker 进程还在不在;30s 梯;走拆除收口)'
```

---

## Task 5: 三个大厅页把对局中的房画成**看得见、点不动**的一行

**Files:**
- Modify: `scenes/matchmaking.gd`(`_on_room_list:157`)
- Modify: `scenes/royale_lobby.gd`(`_on_royale_rooms:246`)
- Modify: `scenes/team_lobby.gd`(`_on_team_rooms:194`)
- Create: `tests/lobby_row_probe.tscn` + `tests/lobby_row_probe.gd` + `.uid`

**Interfaces:**
- Consumes: Task 2/3 的列表载荷键 `in_match`
- Produces: 判据文本 `LOBBY ROW PROBE: ALL-OK`

- [ ] **Step 1: 写 `tests/lobby_row_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/lobby_row_probe.gd" id="1"]

[node name="LobbyRowProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写探针(此时必红)**

```gdscript
extends Node

# 三个大厅页把「对局中」的房画成**看得见、点不动**的一行 —— 界面面探针。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/lobby_row_probe.tscn
# 判据: 文本 `LOBBY ROW PROBE: ALL-OK`
#
# ★ `--quit-after 3600`(=60s @60fps)的取值依据:本探针**全部断言都在 `_ready` 里同步跑完**,
#   跑完自己 `quit()`;安全网只在挂住时才用得上。本仓的教训是"安全网给薄了会把跑得慢读成
#   功能坏了"(`tests/brawl_rollback_probe.tscn` 用 3600 就跑不完,实测要 30000),而这里没有
#   任何等待。3600 是"绝不可能耗尽"的量级。
#
# ═══ 为什么页面**不入树** ═══
# ★ 入树就会跑 `_ready`,而 `_finish_lobby_ready` 里有一句
#   `_request_list.call_deferred(...)` → 真的去连大厅(1v1 页默认云地址,另两页 127.0.0.1:7777)。
#   本探针只想验**画出来的行**,不想开任何 socket、更不想碰用户的 7777。
#   不入树 ⇒ `_ready` 不跑 ⇒ 没有 deferred、没有网络;只要把 `_on_*_rooms` 用到的两个成员
#   (`_list_box` / `_status`)手工摆好,就能直接调那三个渲染函数。
# ★ 判「点不动」用的是 `Button.pressed` 上的**连接数**:`disabled = true` 只是观感,真正的
#   "点了没有反应"是**没有连任何 handler**。两半都断言(disabled + 0 连接),否则"画成灰的但
#   仍然连着 handler"会全绿 —— 那种实现里键盘焦点按下去照样会加入。
#
# ═══ 断言计数 ═══
# ★ ALL-OK 只证明"没有一条断言失败",**不证明"该跑的断言都跑过"**(见 tests/lib/probe_base.gd
#   文件头)。故这里比对期望条数:三页 × 8 条 = 24,少跑一条就红。改探针必须同步改这个数。

const EXPECTED_CHECKS := 24

const ROWS_1V1 := [
	{"code": "1234", "players": 1, "names": ["阿甲"], "in_match": false},
	{"code": "5678", "players": 2, "names": ["阿甲", "bob"], "in_match": true},
]
const ROWS_N := [
	{"code": "1234", "players": 1, "max_players": 4, "names": ["阿甲"], "in_match": false},
	{"code": "5678", "players": 2, "max_players": 4, "names": ["阿甲", "bob"], "in_match": true},
]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_check_page("res://scenes/matchmaking.tscn", "_on_room_list", ROWS_1V1, "1v1")
	_check_page("res://scenes/royale_lobby.tscn", "_on_royale_rooms", ROWS_N, "大乱斗")
	_check_page("res://scenes/team_lobby.tscn", "_on_team_rooms", ROWS_N, "3v3")
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)—— 有断言没跑到,这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY ROW PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY ROW PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 一页 8 条:对局中那一行(存在 / disabled / 无 handler / 不吃焦点 / 文案含「对局中」/ 名单来自载荷)
# + 普通那一行(不是 disabled / 恰有一个 handler)。
func _check_page(scene_path: String, fn: String, rows: Array, tag: String) -> void:
	var p: Node = (load(scene_path) as PackedScene).instantiate()
	# ★ 手工摆好渲染函数用到的两个成员(不入树 ⇒ `_ready` 不跑 ⇒ 它们都还是 null)
	p.set("_list_box", VBoxContainer.new())
	p.set("_status", Label.new())
	p.call(fn, rows)
	var box: Node = p.get("_list_box")
	var live := _find_button(box, "5678")     # 对局中的那一行
	var open_ := _find_button(box, "1234")    # 普通的那一行(正向对照)
	_check(live != null and open_ != null,
			"%s 两种行都在列表里(live=%s / 普通=%s)" % [tag, str(live), str(open_)])
	if live == null or open_ == null:
		p.free()
		return
	_check(live.disabled, "%s ★ 对局中的行 disabled = true" % tag)
	_check(live.pressed.get_connections().is_empty(),
			"%s ★ 对局中的行没接任何 handler(disabled 只是观感,不接 handler 才是真的点不动)" % tag)
	_check(live.focus_mode == Control.FOCUS_NONE,
			"%s ★ 对局中的行不吃键盘焦点(焦点环落到它上面 = 邀请一次注定失败的按下)" % tag)
	_check(live.text.contains("对局中"), "%s 对局中的行文案含「对局中」(实得「%s」)" % [tag, live.text])
	_check(live.text.contains("阿甲") and live.text.contains("bob"),
			"%s 对局中的行显示**载荷里**的名单(实得「%s」)" % [tag, live.text])
	_check(not open_.disabled, "%s 普通行不是 disabled(正向对照)" % tag)
	_check(open_.pressed.get_connections().size() == 1,
			"%s 普通行恰有一个 handler(还能加入;正向对照)" % tag)
	p.free()


func _find_button(box: Node, code: String) -> Button:
	for c in box.get_children():
		if c is Button and (c as Button).text.contains(code):
			return c
	return null
```

- [ ] **Step 3: 跑一次确认它红**

Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_row_probe.tscn`
Expected: 三页各红四条 —— 「对局中的行 disabled」「没接任何 handler」「不吃键盘焦点」「文案含对局中」(此时实现仍会把对局中的行画成可点、人数段写的是 `%d/2` / `%d/%d`),且末尾没有 `ALL-OK`。★ 另四条(名单来自载荷 / 普通行两条对照)此时**本就该绿** —— 它们是正向对照,不是本任务要改的东西。

- [ ] **Step 4: `matchmaking._on_room_list`**

`scenes/matchmaking.gd:157-196` 整段换成:

```gdscript
# 房间列表:未满优先在前;已满/失效的房间由服务器拒绝并自动刷新列表
func _on_room_list(rooms: Array) -> void:
	for c in _list_box.get_children():
		c.queue_free()
	var partial: Array = []
	var full: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		# ★ 对局中的房 players 记的是**冻结名单**的条数(1v1 恒 2)→ 自然落进 full 那一档排到最后,
		#   正是想要的观感(在打的排最后,可加入的排前面),不需要为它另写一条排序。
		(full if int(r.get("players", 2)) >= 2 else partial).append(r)
	var order: Array = partial + full
	if order.is_empty():
		var empty := UiFactory.label("暂无房间 —— 点「建房」开一局吧", 16)
		empty.size = Vector2(600, 40)
		_list_box.add_child(empty)
		_status.text = "共 0 个房间"
		return
	for r in order:
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		# ★ 对局中的房**照列**但**点不动**(用户要求:"所有人都可以看到所有房间(包括游戏已经
		#   进行的房间)…无论在对战还是掉线 C 都不应该进去")。服务端 `join_room` 那边也拒
		#   (`room.started`)—— **两半都要**:`disabled` 是体验,服务端那道才是保证
		#   (在「房间号」框里手敲房号、或旧客户端绕过界面,照样进不去)。
		var in_match := bool(r.get("in_match", false))
		var occ: String = ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   玩家: " + ", ".join(names)
		var btn := Button.new()
		btn.text = "房间 %s    %s%s" % [code, "对局中" if in_match else "%d/2" % players, occ]
		UiFactory.style_control(btn, 16)
		UiFactory.style_row_button(btn)
		btn.custom_minimum_size = Vector2(600, 46)
		# 左对齐:房间号是定宽段(「房间」+定长码),人数也是定宽段,故左对齐后
		# 两行的房间号列 / 人数列天然对齐。原先居中排版,行的长短一变整串就跟着左右漂
		# ——「1/2」在两行里位置都不同,读起来是一堆居中的字而不是一张表。
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# ★ 对局中的行**不接 handler、也不吃键盘焦点**:焦点环能落到它上面等于邀请一次注定
		#   失败的按下(`UiFactory.style_row_button` 早就带了 disabled 的样式,不新增任何颜色)。
		btn.disabled = in_match
		if in_match:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.focus_mode = Control.FOCUS_ALL
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				_join_code(code))
		_list_box.add_child(btn)
	_status.text = "共 %d 个房间(未满优先;对局中的照列但不可进)" % order.size()
```

- [ ] **Step 5: `royale_lobby._on_royale_rooms` / `team_lobby._on_team_rooms`**

两处的行构造各换成(**除 `maxp` 的来源外逐字相同**;大乱斗取 `r.get("max_players", 4)`,3v3 取 `r.get("max_players", LobbyRooms.TEAM_ROLES)`):

```gdscript
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var code := str(r.get("code", ""))
		var players := int(r.get("players", 1))
		var maxp := int(r.get("max_players", 4))
		# ★ 对局中的房**照列**但**点不动**(与 1v1 页同款:可见性与拒绝入房是同一件事的两半;
		#   服务端 `royale_join` / `team_join` 的 in_match 守卫才是那道保证)。
		var in_match := bool(r.get("in_match", false))
		var occ := ""
		var names: Array = r.get("names", [])
		if not names.is_empty():
			occ = "   " + ", ".join(names)
		var btn := UiFactory.button("房间 %s      %s%s" % [code,
				"对局中" if in_match else "%d/%d" % [players, maxp], occ], 32, Vector2(620, 46))
		btn.disabled = in_match
		if in_match:
			btn.focus_mode = Control.FOCUS_NONE
		else:
			btn.pressed.connect(func() -> void:
				Sfx.play("ui")
				_join_room(code, ""))
		_list_box.add_child(btn)
	_status.text = "共 %d 个公开房间(对局中的照列但不可进)" % rooms.size()
```

★ 两页**各自**的空列表分支(`if rooms.is_empty():`)只改状态栏文案:也带上"共 0 个公开房间(对局中的照列但不可进)"。

- [ ] **Step 6: `--import` + 跑探针 + 三页启动自检**

Run(PowerShell):`& $GODOT --headless --path . --import`
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_row_probe.tscn`
Expected: `LOBBY ROW PROBE: ALL-OK(24 条断言)`。
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/matchmaking.tscn` → 无 `SCRIPT ERROR`。
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/royale_lobby.tscn` → 无 `SCRIPT ERROR`。
Run(PowerShell):`& $GODOT --headless --path . --quit-after 120 res://scenes/team_lobby.tscn` → 无 `SCRIPT ERROR`。
Run(PowerShell):`& $GODOT --headless --path . --quit-after 3600 res://tests/lobby_visibility_probe.tscn` → `LOBBY VISIBILITY PROBE: ALL-OK(27 条断言)`(回归:载荷改动不该影响服务端面)。

★ 三页启动自检会各自连一次大厅(默认地址),失败只打状态栏文案、不报 `SCRIPT ERROR`,这是**预期的**。

★ **版式不取图**:本批只把一行的文案与可点状态改掉,没有动任何版式常量(`disabled` 样式早就有了)。按本仓「不折腾视觉」的取向,人眼验收留给用户跑真链路时顺带看一眼列表。

- [ ] **Step 7: 变异反证(两条,逐条还原)**

1. 把三个页面的 `btn.disabled = in_match` 改成 `btn.disabled = false`、并把 `pressed` 接回去(即退化成"照列且可点")⇒ `lobby_row_probe` 的「disabled」与「没接任何 handler」两条应红。
2. 把 `matchmaking` 的人数段改回 `"%d/2" % players`(不再区分)⇒ 「文案含「对局中」」应红。

两段输出写进报告。

- [ ] **Step 8: 提交**

```bash
git add scenes/matchmaking.gd scenes/royale_lobby.gd scenes/team_lobby.gd \
  tests/lobby_row_probe.gd tests/lobby_row_probe.gd.uid tests/lobby_row_probe.tscn
git commit -m 'feat(ui): 三个大厅页把对局中的房画成「对局中」且不可点(看得见、进不去)'
```

---

## Task 6: 用户侧回归 + `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`(「网络与 PvP」+「3v3 团队模式」两节里与大厅房间寿命有关的段落)

- [ ] **Step 1: 让用户跑真链路回归(agent 不代跑)**

Run(**让用户跑**):`timeout 300 bash tests/pvp_room_smoke.sh`
Expected: 建房/加入/开局三段全过(它碰 7777,**必须**由用户跑;跑前确认没有别的 Godot 占着 7777)。
Run(**让用户跑**):`timeout 300 bash tests/room_sweep_smoke.sh`
Expected: `SMOKE_ROOM_SWEEP OK: …`。

★ 这两条是本批唯一的"过真协议"回归:1v1 的建房→配对→`go_match` 走的正是被本批改过的那条
`on_peer_left` / `_start_match` 路径。**红了先看 `on_peer_left` 的 `if room.started: continue`**
—— 它现在是"房不拆"的唯一开关。

- [ ] **Step 2: 记录这几条(每条都是"后人会踩"的)**

在 `CLAUDE.md` 的「网络与 PvP」一节里补一段(位置:紧跟「断线重连(阶段 1)」小节之前或之后,自成一小段),内容:

1. **★ 对局中的房(`started` / `in_match`)不再在"客户端转连 worker"那一刻被拆**,寿命改到**worker 进程退出**;回收由 `RoomManager._reclaim_finished_matches`(30s 梯,`MATCH_SWEEP_INTERVAL`)按 **worker 进程还在不在** 判 —— 那是三种模式唯一的精确界。**兜底**仍是既有的 2h 超龄清扫(`_sweep_stale_rooms`),两条路径并存。
   - ★ **为什么不按宽限期收**:宽限期是 worker 侧状态,大厅看不见;照"开局后宽限期到点就收"做会把房在开打 60 秒后拆掉,而**一局打到中段掉线的玩家再也回不去**。
   - ★ **代价照实登记**:双方都在 `go_match` 后立刻消失时,那一个 worker 与那一个端口会白占到 2h 兜底为止(玩家侧有 12s 转连 / 25s claim 兜底,不会卡住)。
   - ★ **pid 复用风险**:worker 退出后若系统把同一个 pid 发给别的进程,回收梯会判"还在",一条记录(与一个端口)最多挂到 2h。误判方向是"多留"而非"错杀"。
2. **列表可见性与拒绝入房是同一件事的两半**:列表载荷各加 `in_match` 键(三模式同名同义、加法式扩展,老客户端忽略未知键),列表构造抽成 **`LobbyRooms.room_list_payload()` / `royale_list_payload()` / `team_list_payload()` 纯函数** —— ★ 因为 `NetBus.reply` 在无对端时静默跳过,不抽出来探针观测不到列表内容。三模式拒绝文案统一成「该房间的对局已进行中,无法加入」;★ **`matchmaking._on_server_message` 的自动刷新分支只认旧文案**(`房间已满` / `房间不存在`),新文案落到 `else` 只显示不刷新 —— 改文案 = 静默改行为,`room_sweep_smoke` 有源码级断言钉住。
3. **房记录上多了两个字段**:`worker_pid`(spawn 成功后由 `RoomManager` 登记;**0 = 拉起中,一律判"没结束"**)与 `roster`(开局那一刻由 `freeze_roster` 冻结的 `[{role, name}]`)。★ **名单必须冻结**:成员转连后 `players` 会空、`_peer_names` 会被擦掉,读它们只会渲染出"玩家, 玩家"。
4. **`WorkerLauncher` 多了端口→pid 表**:`pid_of(port)`(未登记/已归还 ⇒ 0)与 `static pid_alive(pid)`(`pid <= 0` ⇒ false)。★ `release_now` **必须同时清 pid**:只清一半会让一个已经结束的对局被判成"还在"。
5. **三张注册表仍然各管各的**(房号空间重叠是既有事实),记录**只住在自己那张表里** —— ★ 别为"看得见"去合并三张表,那正是"按 code 撞库会拆错房"那个老坑(见 `teardown_room` 的 `is` 判据)。
6. **守缺口照实登记**:本批**没有**真链路探针覆盖"线上投递的 `in_match` 行 + 真的拒绝"(探针只覆盖载荷构造与页面渲染)。那一半由**后继的回局计划**的 `tests/rejoin_probe.tscn` 相 c3 覆盖(同一个机制,一条探针)。

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -m 'docs: CLAUDE.md 记录对局中房间的寿命/回收判据/列表可见性与拒绝两半'
```

---

## 自检记录

**设计覆盖**:设计 §1(今天为什么看不见)对应本计划的**全部**任务(拆房那三处是它们各自模式的任务改的);§2.2 记录形状 → Task 2(1v1)+ Task 3(另两模式);§2.4 退役 → Task 1(判据的原料)+ Task 4(梯与接线);§2.5 端口不变量换位 → 本批**只改注释归属**,数值不动(留档在本文件 Task 4 的注释与设计 §2.5);§3 载荷 → Task 2 + Task 3;§4 渲染 → Task 5;§5 拒绝 → Task 2(文案与守卫)+ Task 3(另两模式)+ Task 5(界面那道);§6 测试 → 两个新探针 + `room_sweep_smoke` 三条 + `team_room_smoke` 回归。

**与设计的刻意偏离**:无。

**本计划未覆盖 / 已知边界(照实登记)**:

- **线上投递没有自动化覆盖**(见设计 §6.4):`in_match` 行真的过 UDP、以及真链路上的拒绝,由**后继**回局计划的 `tests/rejoin_probe.tscn` 相 c3 覆盖(那里本来就要起三个真客户端)。
- **1v1 worker 的报到超时梯本批不修**(设计 §2.4 风险 3):一个"双方都在 `go_match` 后消失"的 1v1 房会白占一个 worker + 一个端口到 2h 兜底。
- **`_sweep_stale_rooms` 的在局宽限仍是估的**(大乱斗取 `RoyaleHost.MATCH_TIME` 默认值、3v3 取 `TEAM_MATCH_ESTIMATE`):本批不放宽,两条既有边界照旧。
- **1v1 现在会活进对局**,于是「1v1 不享受在局宽限」那条既有裁剪从"够不着"变成"理论上够得着"——实测够不着(房龄 2h vs 一局几分钟),**不改**。
- **不做**观战、补位加入、跨模式合并列表、HUD 的「掉线中/重连中」(设计 §7)。

**占位符扫描**:无 TBD / TODO / "类似 Task N";每个改代码的步骤都给了完整代码(两个探针的每一行都是可抄的,不是"照别的文件写")。

**类型一致性**:`WorkerLauncher.pid_of(port) -> int` / `static pid_alive(pid) -> bool` 在 Task 1 定义,Task 4 按同一签名调用;`LobbyRooms.freeze_roster(room)` / `room_list_payload()` 在 Task 2 定义,`royale_list_payload()` / `team_list_payload()` 在 Task 3 定义(逐字同款),Task 4 的回收梯按 `worker_port` / `worker_pid` 读它们;`RoomManager._reclaim_finished_matches()` / `static _match_over(port, pid)` 在 Task 4 定义并被同任务的冒烟断言、被探针相④调用;三个页面消费的键名 `in_match` 与 Task 2/3 产出的键名逐字一致。

**跑法分工**:agent 可跑 = `--import`、`-s` 冒烟(`room_sweep_smoke` / `team_room_smoke`)、`tests/lobby_visibility_probe.tscn`、`tests/lobby_row_probe.tscn`、三个页面的 `--quit-after 120` 启动自检;**用户跑** = `tests/pvp_room_smoke.sh`、`tests/room_sweep_smoke.sh`(脚本化 + 自带按端口收尾),以及一切占 7777 的既有脚本。
