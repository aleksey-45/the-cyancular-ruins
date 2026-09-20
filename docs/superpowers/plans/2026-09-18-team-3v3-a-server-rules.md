# 3v3 团队模式【A 册：服务端与规则】实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「队伍」这一维做进服务器权威层 —— 队伍表、子弹穿透队友、按队出生/复活、按队计分与胜负、只复位击杀者、换边、掉线后整队走光才终局、`--team/--teams` 启动契约 —— 并用探针证明每一条。

**Architecture:** 队伍归属是**一个字典**（role → 1/2），由大厅经 worker 命令行显式传入（role 号有空洞、**不能**从编号推导）。它住在 `MatchState._team_of`（共享状态底座 —— 父类方法解析不了子类符号，故必须住这里），对子类暴露只读口 `team_of()` / `same_team()`。规则层是新的 `TeamHost extends MatchHost`（与 `RoyaleHost` 平级的第二个模式宿主），照 `RoyaleHost` 那套"中间层纪律 + `_init` 先算出生点再 `super`"写。**C2 四条不变量、`MatchBootstrap`、`RoyaleHost` 的行为一律不动。**

**Tech Stack:** Godot 4.7.1 GDScript；`NetBus`（方法表**一个字不动**，本册**不新增任何 RPC**）；场景探针（`tests/*.tscn`，判据 grep `ALL-OK`）与 `-s` 冒烟。

## Global Constraints

- **本项目约定：测试由用户自己跑，不要代跑。** 计划里每条 `Run:` 都是**写给用户**的；agent 自己可执行的是 `--import`、不占端口的 `--quit-after` 自检、以及**不占端口的场景探针**。任何要占 7777 的东西（`royale_probe` / `pvp_room_smoke` / `--autotest-*` 带大厅的）一律留给用户。
- **引擎路径**：环境变量 `GODOT`，未设时回落 `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`（**console 版**）。
- **`NetBus` 的方法表一律不动**（原 NetBus 要与原版服务端逐字节一致）。本册**不新增任何 RPC**，只改 worker 的命令行与权威层内部。
- **定向发送前一律先判活**：`NetBus.is_peer_live(id)`，`NetBus.reply(...)`（本册新写到的发送点只有 `TeamHost.start_on` 的两条 `rpc_id`，照 `RoyaleHost.start_on:65-68` 的形状判活）。
- **中间层不得定义生命周期钩子**：`_init/_ready/_enter_tree/_exit_tree/_physics_process` 不准出现在 `MatchSnapshot/MatchGround/MatchState` 这些中间层（`match_state.gd:14-16`）。`TeamHost` 是末端子类，可以定义。
- **基类常量不可同名遮蔽**：`MatchState` 已有 `KILLS_TO_WIN=5` / `ROUNDS_TO_WIN=2`，`TeamHost` 自己的那份必须叫 `TEAM_KILLS_TO_WIN` / `TEAM_ROUNDS_TO_WIN`（同名会在编译期报"遮蔽基类成员"）。
- **场景探针 `--quit-after` 统一给 3600**（安全网只在探针挂住时用得上；给少了会把"跑得慢"读成"功能坏了"）。
- **判据 grep 文本 `ALL-OK`，不看退出码**。
- **`-s` 冒烟必须写空载守卫**（`load()` 之后 `if X == null: print(...); quit(1); return`，否则抛错就走到不 `quit()` → 进程永久挂起）。
- **改成共享层时"空参数 = 原行为"**：`MatchHost._init` 的第 5 个参数、`same_team()` 在无队伍时返回 false —— 1v1 / 大乱斗 / 单机的既有探针**必须全绿**，那是本册的回归线。
- **提交信息用单引号或 `-F 文件`**，不带任何 Claude/AI 署名行；提交后回读 `git show --stat`。
- 每次 `git add` **只加本任务点名的文件**。工作区有未跟踪的 `_crashtest/`，**不要动**。
- **字号只用 16 的倍数**（`kh_l4/l5` 会扫 `res://tests`）。

## 文件结构

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| ~~`tests/team_rules_smoke.gd`~~ | **已删除** | ★ 计划最初列了这个 `-s` 冒烟，**开工后撤销**：`TeamHost` 在 `-s` 阶段**加载不起来**（它的继承链会连带 preload 引用 autoload 的脚本，正是本仓"`-s` 冒烟别静态引用重链"那条教训），而 `compute_swap_spawns` 的覆盖已由 Task 4/7 的**场景探针**断言承担（同一个函数的真断言，不必再来一份纯逻辑的） |
| `server/match_state.gd` | 修改 | `_team_of` 字段 + `team_of()` / `same_team()` 只读口（**必须住这里**，见文件头约束） |
| `server/match_host.gd` | 修改 | `_init` 第 5 个参数 `teams` |
| `server/match_combat.gd` | 修改 | 子弹与榴弹直击**跳过队友**（不结算、也不 break） |
| `core/sim/spawn_picker.gd` | **新建** | 从 `RoyaleHost` 逐字搬出的静态出生点几何（地板格/连通区/优选池） |
| `server/royale_host.gd` | 修改 | 只把上述静态函数**改成委派** `SpawnPicker`（行为逐字不变） |
| `server/team_host.gd` | **新建** | 3v3 权威宿主：按队散点、按队计分、只复位击杀者、换边、整队走光才终局 |
| `server/worker_launcher.gd` | 修改 | `spawn_team_worker()` + `TEAM_PORT_REUSE_DELAY`（与解析端逐字对应） |
| `server/server_main.gd` | 修改 | `--team`/`--teams` 解析 + 开局分支 + 超时梯 + `_on_peer_left`/`_expire_graces` 的 team 分支 + `match_sync` 带 `teams` |
| `tests/room_sweep_smoke.gd` | 修改 | 双向断言扩到 `--team`/`--teams` |
| `tests/team_table_probe.tscn/.gd` | **新建** | 队伍表进权威底座 + 子弹穿透队友 |
| `tests/team_host_probe.tscn/.gd` | **新建** | 按队出生散点 / 按队计分 / 只复位击杀者 / 换边 |
| `tests/team_disconnect_probe.tscn/.gd` | **新建** | 掉线双向：掉 1 人不得终局 / 整队走光必须终局 |

---

## Task 1: 前置检查（依赖重连批次）

**Files:** 无（只读命令）

**Interfaces:**
- Consumes: 无
- Produces: 一个"可以开工"的判定

- [ ] **Step 1: 确认工作区干净**

Run: `git status --short`
Expected: 只有 `?? _crashtest/`（那是历史遗留的未跟踪目录，别动）。**若出现 `M server/match_state.gd` 一类未提交改动 → 停下**，那是并发 agent 的在制品。

- [ ] **Step 2: 确认断线重连 2-A 已落地**

Run: `git log --oneline -8`
Expected: 能看到 2-A 的六个任务（`destroyed_cells()` / `match_sync 带 destroyed` / `客户端应用 destroyed` / 先清后灌 + 重连拉 match_sync / 探针相⑦ / CLAUDE.md）。**缺哪个就等哪个** —— 本册的第二、四、五个任务都要改 `server/match_state.gd`、`server/server_main.gd`，与那批是同一批文件。

- [ ] **Step 3: 建分支（若不在动手分支上）**

Run: `git switch -c feat/team-3v3-a`
Expected: `Switched to a new branch 'feat/team-3v3-a'`

---

## Task 2: 队伍表进权威底座 + 子弹穿透队友

**Files:**
- Modify: `server/match_state.gd`（字段区 `:21-27` 之后；`_role_of` 在 `:106`）
- Modify: `server/match_host.gd:10-11`（`_init` 签名）
- Modify: `server/match_combat.gd:44-53`（`_adjudicate_bullets`）与 `:69-77`（`_adjudicate_grenade`）
- Create: `tests/team_table_probe.gd` + `tests/team_table_probe.tscn`

**Interfaces:**
- Consumes: 无
- Produces:
  - `MatchState._team_of: Dictionary`（role(int) → 队号(int)，**唯一权威表**）
  - `MatchState.team_of(role: int) -> int`（无队伍返回 0）
  - `MatchState.same_team(a_role: int, b_role: int) -> bool`（任一方为 0 → false）
  - `MatchHost._init(map_path, role_peers, options = {}, ai_roles = [], teams = {})`（**第 5 个参数**）

- [ ] **Step 1: 写失败的探针 `tests/team_table_probe.gd`**

```gdscript
extends Node

# 队伍表进权威底座 + 子弹穿透队友。场景模式(root 有 autoload/`multiplayer`)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_table_probe.tscn
# 通过 = `TEAM TABLE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 队伍表算错/传丢的表现**全是静默的**:子弹照样飞、伤害照样结算,只是队友挨了枪。
#   数值断言(距离/伤害)在"队友被误伤"这件事上一条都不会红。
# ★ 反向那条(不传 teams → 全 0、`same_team` 恒 false)是"空参数 = 原行为"的**唯一证据**:
#   1v1/大乱斗的探针跑的是别的路径,照不到这里。
# 做法同 match_host_hygiene_probe:真建宿主,但 **role_peers 传空** —— 不建玩家、不排 peer、不发包;
# 玩家由探针自己按 `MatchHost._init` 的建法手工摆进 `players`。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _host = null
var _ran_to_end := false   # 见 destroyed_cells_probe 的同名注释:跑完闩,防"运行期报错却打 ALL-OK"


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_run()
	_finish()


# 照 `MatchHost._init:32-44` 的建法手工摆一个玩家(那条路径在 role_peers 为空时不会跑)。
func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	var src := PacketInputSource.new()
	p.set_input_source(src)
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	host.input_sources[role] = src
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


func _run() -> void:
	# ── ① 带队伍表建局:team_of / same_team 是那张表 ──
	_host = MatchHost.new(MAP, {}, {}, [], TEAMS)
	add_child(_host)
	_host.set_physics_process(false)   # 手工驱动(不关的话 quit(0) 帧末生效,中间还会跑一帧物理)
	_check(_host.team_of(1) == 1, "role1 在 1 队")
	_check(_host.team_of(4) == 2, "role4 在 2 队")
	_check(_host.team_of(9) == 0, "表外的 role → 0(不是猜一个)")
	_check(_host.same_team(1, 3), "1 与 3 同队")
	_check(not _host.same_team(1, 4), "1 与 4 不同队")
	_check(not _host.same_team(0, 0), "★ 0 与 0 不算同队(无队伍 = 不豁免)")

	# ── ② 反向:不传 teams → 表空、same_team 恒 false(= 1v1/大乱斗的原行为)──
	var plain = MatchHost.new(MAP, {}, {}, [])
	add_child(plain)
	plain.set_physics_process(false)
	_check(plain.team_of(1) == 0, "★ 不传 teams 时 team_of 恒 0")
	_check(not plain.same_team(1, 1), "★ 不传 teams 时 same_team 恒 false")

	# ── ③ 子弹穿透队友:同队不结算、异队结算 ──
	# 摆两个玩家:role4(2 队)与 role5(2 队,队友)、role1(1 队,敌人)。全部站在同一格附近。
	var a := _place(_host, 4, Vector2i(20, 20))
	var mate := _place(_host, 5, Vector2i(21, 20))
	var foe := _place(_host, 1, Vector2i(22, 20))
	await get_tree().physics_frame   # 玩家 _ready(@onready combat/weapons)要跑过一帧
	# 子弹:由 4 号发射,位置压在 5 号身上(队友)→ 不该结算;再压到 1 号身上 → 该结算。
	var hit_mate := _fire_probe_bullet(_host, a, mate.global_position, 5)
	_check(not hit_mate, "★ 子弹穿过队友(4 号打 5 号不结算)")
	var hit_foe := _fire_probe_bullet(_host, a, foe.global_position, 1)
	_check(hit_foe, "子弹打敌人照常结算(1 号)")

	_ran_to_end = true


# 造一颗探针子弹(由 shooter 发射),摆在目标身上,跑一次裁决,返回"目标是否被结算"。
# ★ 判定用目标自身的**受伤证据**(hp 下降),不是读内部表 —— 与玩家实现解耦。
func _fire_probe_bullet(host, shooter: Node2D, at: Vector2, victim_role: int) -> bool:
	var victim: Node2D = host.players[victim_role]
	var before: int = victim.hp
	var b: CharacterBody2D = preload("res://scenes/weapons/bullet.tscn").instantiate()
	b.shooter = shooter
	b.hit_damage = 7
	host.add_child(b)
	b.global_position = at
	host._adjudicate_bullets()
	var after: int = victim.hp
	if is_instance_valid(b):
		b.queue_free()
	return after < before


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM TABLE: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM TABLE: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾(运行期脚本错误吃掉了一个断言段)")
		get_tree().quit(1)
```

- [ ] **Step 2: 写 `tests/team_table_probe.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/team_table_probe.gd" id="1"]

[node name="TeamTableProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次确认它红**

Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_table_probe.tscn`
Expected: `Parse Error`（`MatchHost.new` 还没有第 5 个参数 / `team_of` 还不存在）。

- [ ] **Step 4: 在 `server/match_state.gd` 加字段与只读口**

放在字段区（`grid` / `_base_grid` 那两行）之后：

```gdscript
# 队伍表:role(int) -> 队号(1/2)。**唯一权威** —— 由大厅在 worker 命令行 `--teams` 显式传入。
# ★ 为什么不从 role 号推导:role 由大厅的「最小空闲号」分配、有人退出后不重排,编号会留空洞
#   ({1,3,5} 而只有 3 人),奇偶/区间推导必然出错。
# ★ 空表 = 无队伍(1v1 / 大乱斗 / 单机):`team_of` 恒 0、`same_team` 恒 false,行为与今天一致。
var _team_of: Dictionary = {}


# 某 role 的队号;无队伍/不在表里 → 0(调用方按 0 处理为"不豁免、不分组",别让它变成 1)。
func team_of(role: int) -> int:
	return int(_team_of.get(int(role), 0))


# 两个 role 是否同队 —— **单一来源**:子弹穿透队友、出生/复活分组、复位归属都问它。
# ★ 任一方为 0(无队伍)一律 false:0 == 0 若算同队,1v1 里两个玩家会被判成队友、子弹全穿。
func same_team(a_role: int, b_role: int) -> bool:
	var a := team_of(a_role)
	var b := team_of(b_role)
	return a > 0 and a == b
```

- [ ] **Step 5: 在 `server/match_host.gd` 的 `_init` 加第 5 个参数**

```gdscript
func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], teams: Dictionary = {}) -> void:
	_options = options
	_team_of = teams.duplicate()
	...
```

（其余行不动。`RoyaleHost._init` 与 `MatchBootstrap.start_on` 都不传第 5 个参数 → 走默认空表 → 行为不变。）

- [ ] **Step 6: 在 `server/match_combat.gd` 两处裁决里跳过队友**

`_adjudicate_bullets`（`:44-53`）改成：

```gdscript
		# 命中裁决:对非射手玩家算 toroidal 距离
		# ★ 队友**穿透**:`continue` 而不是 `break` —— 队友不挡弹道,后面若有敌人照样打得到。
		#   射手 role 只查一次(循环外),别在循环里反复 _role_of。
		var shooter_role := _role_of(bullet.shooter)
		for role in players:
			var p: Node2D = players[role]
			if p == bullet.shooter:
				continue
			if same_team(shooter_role, int(role)):
				continue
			var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < HIT_RADIUS:
				_on_bullet_hit(bullet, p, role)
				break
```

`_adjudicate_grenade`（`:69-77`）改成（**只改直击那一层**：榴弹的**直击**和子弹同口径穿透队友；**爆炸那一层不动** —— 规则是"爆炸对队友满效"）：

```gdscript
	for role in players:
		var p: Node2D = players[role]
		if p == bullet.shooter:
			continue
		# ★ 直击穿透队友(与普通弹同口径)。**别顺手把爆炸也豁免** —— 用户裁定:
		#   子弹穿透队友、爆炸对队友满效(伤害 + 击退都照吃)。爆炸走 Explosion.apply_aoe,
		#   那条路径**按现状不动**(它本来就对所有玩家满效)。
		if same_team(_role_of(bullet.shooter), int(role)):
			continue
		var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < HIT_RADIUS:
			_grenade_direct_hit(bullet, p)
			break
```

- [ ] **Step 7: `--import` 自检**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error。

- [ ] **Step 8: 让用户跑探针确认绿**

Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_table_probe.tscn`
Expected: `TEAM TABLE: ALL-OK`

- [ ] **Step 9: 跑 1v1/大乱斗的回归探针（安全网）**

Run（**让用户跑**）：`timeout 600 "$GODOT" --headless --path . --quit-after 3600 res://tests/match_host_hygiene_probe.tscn`
Run（**让用户跑**）：`timeout 600 "$GODOT" --headless --path . --quit-after 3600 res://tests/royale_disconnect_count_probe.tscn`
Expected: 两个各自的 `ALL-OK`。这是"空参数 = 原行为"的回归线。

- [ ] **Step 10: 提交**

```bash
git add server/match_state.gd server/match_host.gd server/match_combat.gd \
  tests/team_table_probe.gd tests/team_table_probe.gd.uid tests/team_table_probe.tscn
git commit -m 'feat(team): 队伍表进权威底座 + 子弹穿透队友(爆炸对队友满效,不动)'
```

---

## Task 3: 抽出 `SpawnPicker`（RoyaleHost 委派，行为不变）

**Files:**
- Create: `core/sim/spawn_picker.gd`
- Modify: `server/royale_host.gd:76-183`（静态出生几何改成委派）

**Interfaces:**
- Consumes: `MazeGenerator.current_grid`、`MazeGenerator.is_floor_cell_with_headroom`
- Produces（`class_name SpawnPicker`，全部 `static`）：
  - `grid_dims() -> Vector2i`（cols, rows）
  - `floor_cells() -> Array`（EMPTY + 正下方 SOLID + 头顶留空）
  - `floor_cells_has(c: Vector2i) -> bool`（O(1) 判据版，与 `floor_cells` 同判据）
  - `region_sizes() -> Dictionary`（地板格 → 同层连通区规模）
  - `roomy_floor(c: Vector2i) -> bool`（头顶 2 格净空 + 左右邻格空）
  - `spawn_candidates() -> Array`（开阔优选池，不足逐级回退）
  - `cells_within(center: Vector2i, radius: int) -> Array`（**新增**：基座附近候选格，按环面距离过滤）
  - `reset_cache() -> void`

★ **为什么抽**：`TeamHost` 的按队出生/复活要用同一套"别出生在密封小间"的优选逻辑。抄一份 = 改一处漏一处，而本仓为这类重复付过代价（`spread_cells` 当初就是这么从 `RoyaleHost` 抽到 `GridPathfinder` 的，见 `grid_pathfinder.gd:325-327` 的注释）。
★ **与原计划的偏差（照实登记）**：设计 §1 曾写"`RoyaleHost` 一行不改"。**改成"行为一行不改"** —— 下面这几步是把它的静态函数**逐字搬走**、原位置换成一行委派，不碰它任何实例方法、任何标签、任何常量值。

- [ ] **Step 1: 建 `core/sim/spawn_picker.gd`（逐字搬 + 新增 `cells_within`）**

把 `server/royale_host.gd:76-183` 的 `_grid_dims` / `_floor_cells` / `_region_sizes` / `_floor_cells_has` / `_roomy_floor` / `_spawn_candidates`、常量 `OPEN_AREA_MIN` / `PREFER_MIN`、以及三个 `static var` 缓存**原样搬入**（**保留每一条注释**，它们是踩过的坑），并把函数名去掉下划线前缀：

```gdscript
class_name SpawnPicker
extends RefCounted

# 出生/复活点的**静态几何池**(2026-09-18 从 RoyaleHost 逐字搬出):地板格 / 同层连通区规模 /
# 开阔优选格。抽出来的理由与 `GridPathfinder.spread_cells` 当初那条一样 —— 大乱斗与 3v3
# 都要用同一套"别出生在走不出去的密封小间"的判据,抄第二份就会改一处漏一处。
# ★ 全部 `static`、且**不引任何 autoload**(只读 `MazeGenerator.current_grid`,它本身是 class_name
#   的 RefCounted)→ 本文件可被 `-s` 测试加载。
# ★ 缓存是**每进程**的(与搬出前同款行为):worker 进程一局一进程,故没有跨局失效问题。

const OPEN_AREA_MIN: int = 20    # 出生可走连通区最小规模(格);密封死角小间远小于此
const PREFER_MIN: int = 8        # 优选格不足此数才回退下一级宽松判据

static var _floor_cell_cache: Array = []   # 本局地板格(懒采集;砖被拆不刷新,够用)
static var _prefer_cache: Array = []       # 出生优选格缓存(开阔可走区;见 spawn_candidates)
static var _region_cache: Dictionary = {}  # 地板格 Vector2i -> 同层连通区规模


# 清空三张缓存。换图/换局时调用方自己决定要不要清(搬出前的行为是**从不主动清** —— 保持)。
static func reset_cache() -> void:
	_floor_cell_cache = []
	_prefer_cache = []
	_region_cache = {}

# ...(以下 grid_dims / floor_cells / region_sizes / floor_cells_has / roomy_floor /
#     spawn_candidates 六个函数,把 royale_host.gd:76-183 的对应实现**逐字**粘过来,
#     仅做三处机械改名:去掉 `_` 前缀、`_tdist`/`_grid_dims` 调用点跟着改名)


# 基座附近的候选格(环面距离 ≤ radius 格)。给 3v3 的"队内散开"用:
# 先选两个相距 ≥ SPAWN_CLEARANCE 的基座,再在各自附近取 3 个点 —— 这样"队内聚、队间远"。
# ★ 池子为空时返回全量候选(= 放弃"队内聚",但绝不返回空导致调用方少点)。
static func cells_within(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	if center.x < 0 or center.y < 0:
		return spawn_candidates()
	var d := grid_dims()
	for c in spawn_candidates():
		if GridPathfinder.toroidal_dist(c, center, d.x, d.y) <= radius:
			out.append(c)
	return out if not out.is_empty() else spawn_candidates()
```

- [ ] **Step 2: 改 `server/royale_host.gd` —— 原位置的函数体换成委派**

把 `:76-183` 那段整体替换成下面这几行（**保留原注释块**，后面追加一行"已搬到 SpawnPicker"的说明；`plan_spawns` 与 `_spawn_cell` **一个字不改**，它们调用的名字不变）：

```gdscript
# ── 出生点几何:已搬到 `core/sim/spawn_picker.gd`(SpawnPicker)──
# 2026-09-18 逐字搬迁(3v3 要共用同一套"别出生在密封小间"的判据),这里只留转发,
# 保证本文件所有调用点(`plan_spawns` / `_spawn_cell` / `_spawn_candidates`)名字不变。
static func _grid_dims() -> Vector2i:
	return SpawnPicker.grid_dims()

static func _floor_cells() -> Array:
	return SpawnPicker.floor_cells()

static func _floor_cells_has(c: Vector2i) -> bool:
	return SpawnPicker.floor_cells_has(c)

static func _region_sizes() -> Dictionary:
	return SpawnPicker.region_sizes()

static func _roomy_floor(c: Vector2i) -> bool:
	return SpawnPicker.roomy_floor(c)

static func _spawn_candidates() -> Array:
	return SpawnPicker.spawn_candidates()
```

并把 `const OPEN_AREA_MIN` / `PREFER_MIN` 两行**删掉**（已随实现搬走，留在原处会变成"两份常量"），并在类头注释里补一句它们现在住 `SpawnPicker`。

- [ ] **Step 3: `--import` + 启动自检**

Run: `"$GODOT" --headless --path . --import`
Run: `timeout 120 "$GODOT" --headless --path . --quit-after 90`
Expected: 无 Parse Error / 无 ERROR。

- [ ] **Step 4: 回归（大乱斗的出生几何没变）**

Run（**让用户跑**）：`timeout 900 "$GODOT" --headless --quit-after 3600 --path . res://tests/royale_c2_probe.tscn`
Expected: `PROBE: ALL-OK`（它跑真 `royale_game`，会走 `plan_spawns`）。
★ 跑前确认没有别的 godot 占着 7777。

- [ ] **Step 5: 提交**

```bash
git add core/sim/spawn_picker.gd core/sim/spawn_picker.gd.uid server/royale_host.gd
git commit -m 'refactor(sim): 出生点几何抽到 SpawnPicker(RoyaleHost 改为委派,行为逐字不变)'
```

---

## Task 4: `TeamHost` 骨架 + 按队出生散点

**Files:**
- Create: `server/team_host.gd`
- Create: `tests/team_host_probe.gd` + `.tscn`

**Interfaces:**
- Consumes: `SpawnPicker.*`、`GridPathfinder.spread_cells`、`MatchState._team_of`
- Produces（`class_name TeamHost extends MatchHost`）：
  - `const TEAM_KILLS_TO_WIN := 9` / `TEAM_ROUNDS_TO_WIN := 2` / `TEAMMATE_CLEARANCE := 3` / `SPAWN_CLEARANCE := 15` / `SPAWN_BASE_RADIUS := 30` / `RESPAWN_CLEARANCE := 8`
  - `static plan_team_spawns(teams: Dictionary) -> Dictionary`
  - `static compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary`
  - `static start_on(role_peers, map_path, options = {}, teams = {}) -> Node`
  - `_init(map_path, role_peers, options = {}, ai_roles = [], spawns = {}, teams = {})`
  - `_spawn_cell(role) -> Vector2i` 覆写 / `role_spawns() -> Dictionary` 覆写 / `team_map() -> Dictionary`
  - `_enemy_team_of(role: int) -> int`

- [ ] **Step 1: 写 `server/team_host.gd`（骨架 + 出生）**

```gdscript
class_name TeamHost
extends MatchHost

# 3v3 团队对抗权威对局(第三个模式宿主,与 RoyaleHost 平级)。
#  - 6 人(两队各 3)、三局两胜、每队先到 TEAM_KILLS_TO_WIN 击杀赢一局、局间**整队换边**;
#    局内死亡 2s 复活;击杀后**只把击杀者本人**送回本方出生点(队友不动)。
#  - 计分**不分死因**:任一玩家倒地 → 对方队 +1(枪杀/爆炸/溺水/自伤/队友误炸一律如此)。
#  - 子弹穿透队友(在 MatchCombat 裁决层,按 role 判);**爆炸对队友满效**(现状行为,未改)。
#  - 队伍归属来自 `MatchState._team_of`(由大厅经 `--teams` 显式传入)。
#
# ★ 继承链与中间层纪律同 RoyaleHost:本类是末端子类,生命周期钩子只能出现在这里。
# ★ `_init` 顺序不可整理:父类 `_init` 会**虚调** `_spawn_cell(role)` 摆位,那时 `_round_spawns`
#   必须已就绪(与 RoyaleHost 同一个坑,见 royale_host.gd:35-37)。

const TEAM_KILLS_TO_WIN := 9     # ★ 不能叫 KILLS_TO_WIN:基类 MatchState 已有该常量,同名遮蔽会报错
const TEAM_ROUNDS_TO_WIN := 2    # ★ 同上,基类是 ROUNDS_TO_WIN
const SPAWN_CLEARANCE := 15      # 两个基座的最小环面距离(格)
const TEAMMATE_CLEARANCE := 3    # 队内三人最小间距(格):够散开,又不至于走出"队形"
const SPAWN_BASE_RADIUS := 30    # 基座附近取点半径(格);池子不够会退回全量候选
const RESPAWN_CLEARANCE := 8     # 复活点离**存活敌人**的最小环面距离(格)
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS   # 击杀归因时效(3s),与 RoyaleHost 同源

var _round_spawns: Dictionary = {}   # role -> Vector2i(本局出生点,与 match_start 广播的同一份)
var _swap_spawns: Dictionary = {}    # role -> Vector2i(换边后的点;两队点集整体对调)
var _spawned_once: Dictionary = {}   # role -> true(首次摆位走出生点,之后走动态复活点)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:
	# 散点必须在 super._init() 之前就绪(父类 _init 会虚调 _spawn_cell 摆位)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_team_of = teams.duplicate()
	# ★ spawns 传空 = 手工/测试路径,才自己算一份。常规路径由 start_on 算好传进来 ——
	#   `plan_team_spawns` 内部走 `spread_cells`(有 shuffle),重算会得到**另一份**散点,
	#   而广播给客户端的是 start_on 那一份(与 RoyaleHost 完全同款纪律)。
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
	_swap_spawns = compute_swap_spawns(_round_spawns, _team_of)
	super._init(map_path, role_peers, options, ai_roles, teams)


# ── 开局(在 worker 进程调用):算散点 → 逐角色 match_start → 建 TeamHost ──
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_team_spawns(teams)
	for role in role_peers:
		# 判活:报到与开局之间客户端可能已断开,定向可靠包发往正在断开的 peer 就是那条
		# channel 0 错误(判据见 NetBus.is_peer_live,与 RoyaleHost.start_on 同款)
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "3v3 开始")
	# 把**同一份**散点传进宿主:它据此摆位,而上面已把同一份经 match_start 广播给客户端
	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# 按队出生散点:① 取两个相距 ≥ SPAWN_CLEARANCE 的基座;② 每队基座附近取 3 个散点(队内 ≥
# TEAMMATE_CLEARANCE)。→ 队内聚、队间远。
# ★ 与 `RoyaleHost.plan_spawns` 同一条纪律:**不得在广播之后再调一次**(内部有 shuffle)。
static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	var d := SpawnPicker.grid_dims()
	var bases: Array = GridPathfinder.spread_cells(
			SpawnPicker.spawn_candidates().duplicate(), 2, SPAWN_CLEARANCE, d.x, d.y)
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if by_team.has(t):
			by_team[t].append(int(role))
	var out := {}
	for t in [1, 2]:
		(by_team[t] as Array).sort()   # 确定性:同队的 role 按号升序拿点
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out


# 换边用的点集:把两个队的点**整体对调**(队 A 第 i 人 ↔ 队 B 第 i 人)。
# ★ 前提:两队人数严格相等(满 6 人开局保证)。不相等 → 返回空表,`_start_next_round` 据此**不换边**
#   (宁可这局不换,也不要把人送到错的一侧)。纯函数,可 `-s` 测。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a: Array = []
	var b: Array = []
	for role in teams:
		if int(teams[role]) == 1:
			a.append(int(role))
		else:
			b.append(int(role))
	a.sort()
	b.sort()
	var out := {}
	if a.is_empty() or a.size() != b.size():
		return out
	for i in range(a.size()):
		out[a[i]] = spawns.get(b[i], Vector2i(-1, -1))
		out[b[i]] = spawns.get(a[i], Vector2i(-1, -1))
	return out


# 本局各 role 的出生点(供 match_sync 下发)。★ 覆写不可省:基类实现走 `_spawn_cell`,
# 而本类的 `_spawn_cell` 第二次起返回**动态复活点**且带 `_spawned_once` 副作用
# (与 RoyaleHost.role_spawns 同一个坑)。
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


# 队伍表的只读取法(给 `match_sync` 下发用)。★ 客户端**不能**自己从 roles 推导。
func team_map() -> Dictionary:
	var out := {}
	for role in _team_of:
		out[int(role)] = int(_team_of[role])
	return out


func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(int(role), Vector2i(-1, -1))
	return _respawn_cell_for(int(role))


# 复活点:优选开阔格中,离**所有存活敌人** ≥ RESPAWN_CLEARANCE 的第一个(池子洗牌后取首个)。
# ★ 判据是"离敌人远",**不是**"离所有玩家远" —— 队友在附近复活是好事(royale 那条是全员互敌,
#   故它判所有存活玩家;这里语义变了,别照抄)。
func _respawn_cell_for(role: int) -> Vector2i:
	for pool: Array in [SpawnPicker.spawn_candidates(), SpawnPicker.floor_cells()]:
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or same_team(role, int(other)):
					continue   # 队友不用躲(语义与 royale 那条"离所有存活玩家远"不同,见上面注释)
				var op: Node2D = players[other]
				if op == null or not is_instance_valid(op) or op.is_downed():
					continue
				var oc := Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
						int(op.global_position.y) / GameParameters.TILE_SIZE)
				if MazeGenerator.toroidal_dist(c, oc, SpawnPicker.grid_dims().x,
						SpawnPicker.grid_dims().y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				return c
	return Vector2i(-1, -1)


# 某 role 的**对方队号**(计分归属用)。无队伍 → 0。
func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1
```

- [ ] **Step 2: 写探针 `tests/team_host_probe.gd` + `.tscn`**

```gdscript
extends Node

# TeamHost:按队出生散点 / 按队计分 / 只复位击杀者 / 换边。场景模式。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn
# 通过 = `TEAM HOST: ALL-OK`。
#
# ═══ 为什么需要它 ═══
# ★ 这些判断错了**都不报错**:出生点算错=开局挤在一起(玩家只会觉得"怎么老出生在一块");
#   计分算错=比分不动或两边同涨(要打完一整局才发现);复位算错=把人往错的地方送。
# ★ 真建 TeamHost(role_peers 传空)+ 手工摆 6 个玩家 —— 走的是**生产代码路径**,
#   不是"调方法断言返回值"。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _host = null
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_run()
	_finish()


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


func _run() -> void:
	var teams := TeamHost.plan_team_spawns(TEAMS)
	_check(teams.size() == 6, "6 个 role 都有出生点")
	# ── ① 队内近、队间远 ──
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 99999
	for ra in TEAMS:
		for rb in TEAMS:
			if ra >= rb:
				continue
			var dist := MazeGenerator.toroidal_dist(teams[ra], teams[rb], d.x, d.y)
			if TEAMS[ra] == TEAMS[rb]:
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	_check(min_cross > max_in, "★ 队间最小距离 > 队内最大距离(实际 %d vs %d)" % [min_cross, max_in])

	# ── ② 换边:两队点集整体对调;人数不等则不换 ──
	var swapped := TeamHost.compute_swap_spawns(teams, TEAMS)
	_check(swapped.get(1) == teams.get(4), "换边后 role1 拿 2 队的点")
	_check(swapped.get(4) == teams.get(1), "换边后 role4 拿 1 队的点")
	_check(TeamHost.compute_swap_spawns(teams, {1: 1, 2: 1, 3: 2}).is_empty(), "★ 人数不等 → 不换边")

	# ── ③ 建宿主:出生点 = 开局散点(不是复活点)──
	_host = TeamHost.new(MAP, {}, {}, [], teams, TEAMS)
	add_child(_host)
	_host.set_physics_process(false)
	_check(_host.role_spawns() == teams, "role_spawns() 返回的就是广播的那一份")
	for role in TEAMS:
		_place(_host, role, teams[role])
	await get_tree().physics_frame
	_check(_host.team_of(3) == 1 and _host.team_of(6) == 2, "宿主的队伍表已就位")

	# ── ④ 按队计分:role4 倒地 → **1 队** +1(不是 role 层面的对手)──
	_host._round_state = MatchHost.RoundState.PLAYING
	var p4: Node2D = _host.players[4]
	(p4.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == 1, "★ 2 队的人倒地 → 1 队 +1(实际 %s)" % str(_host._scores))
	_check(int(_host._scores.get(2, 0)) == 0, "2 队没涨分")
	_ran_to_end = true


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM HOST: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM HOST: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾")
		get_tree().quit(1)
```

★ ④ 里的 `_round_state` 用 **`MatchHost.RoundState.PLAYING`**，不要写字面量 `1`（枚举顺序一变就静默错）。本任务只要求 ①②③④ 绿 —— ⑤/⑥/⑦/⑧（复位、9 杀收局、换边）分别随 Task 5/6/7 追加到本探针末尾。

- [ ] **Step 3: 跑确认它红**

Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: `Invalid call` / `Nonexistent function 'plan_team_spawns'`（`TeamHost` 还没建）。

- [ ] **Step 4: 按上面 Step 1 落 `server/team_host.gd`，`--import`**

Run: `"$GODOT" --headless --path . --import`
Expected: 无 Parse Error（★ 新 `class_name` 文件必须先 `--import` 刷全局类缓存，否则别处引用它报 `Parse Error`）。

- [ ] **Step 5: 让用户跑，确认 ①②③④ 绿**

Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: 前四条 `ok`，`TEAM HOST: ALL-OK`（⑤ 还没写，探针里不要留空断言块）。

- [ ] **Step 6: 提交**

```bash
git add server/team_host.gd server/team_host.gd.uid \
  tests/team_host_probe.gd tests/team_host_probe.gd.uid tests/team_host_probe.tscn
git commit -m 'feat(team): TeamHost 骨架 + 按队出生散点(队内聚/队间远)+ 探针'
```

---

## Task 5: 按队计分与胜负（覆写 `_match_round_tick`）

**Files:**
- Modify: `server/team_host.gd`
- Modify: `tests/team_host_probe.gd`（补断言）

**Interfaces:**
- Consumes: `_enemy_team_of`（Task 4）、`MatchState._scores` / `_rounds_won`
- Produces: `TeamHost._match_round_tick(delta)`、`_round_over(team: int)`、`_match_winner() -> int`、`_broadcast_round_state()` 覆写、**`_attributed_killer(victim) -> int`**（本任务的 `kill_event` 就要用它，故在这里落；Task 6 只加复位）

- [ ] **Step 1: 在 `server/team_host.gd` 追加回合机（计分键 = 队）**

```gdscript
# ── 回合机(团队版:计分键 = **队号**,不是 role)──
# ★ 为什么整段覆写而不是改基类:`MatchRound._match_round_tick` 的计分键、胜负判据、复位对象
#   三方都绑在 role 上,逐处插分支会让 1v1 那条路长出团队语义(1v1 的探针照样绿,但已经变了)。
func _match_round_tick(delta: float) -> void:
	for role in players:
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁(与基类同款:旧实现把它塞在闩锁内,曾导致复活永不安排)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 击杀定义(继承 1v1 的"不分死因"):任一玩家倒地 → **对方队** +1。
		# 队友误炸也照此(用户裁定):乱扔雷 = 给对面送分,惩罚是自带的,不必另立规则。
		var scorer := _enemy_team_of(int(role))
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			# kill_event 的载荷仍是 **role 粒度**(射手 = 归因得到,0 = 无归因),
			# 客户端用 match_sync 的队伍表映射到队 —— 协议不为团队改字段(设计 §6)。
			_broadcast_kill(_attributed_killer(p), int(role))
			_broadcast_round_state()
			_reset_killer_only(p, int(role))
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
		RoundState.PLAYING:
			_handle_respawns(delta)
			for t in [1, 2]:
				if int(_scores.get(t, 0)) >= TEAM_KILLS_TO_WIN:
					_round_over(t)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass


func _round_over(winner_team: int) -> void:
	_last_round_winner = winner_team
	_rounds_won[winner_team] = int(_rounds_won.get(winner_team, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()


# 平局不可能(三局两胜,每局必有胜者),但仍按"局胜高者"取,返回**队号**。
func _match_winner() -> int:
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# round_state:`scores` / `rounds_won` 的**键是队号**;`winner` / `match_winner` 也是队号。
# ★ 队伍表**不在这里**下发:只走 `match_sync`(进场/重连各拉一次)。两条投递路径是自检 B2 那类
#   事故的形状,别为了"顺手"加第二条。
func _broadcast_round_state() -> void:
	var data := {
		"state": _round_state,
		"round": _round_num,
		"scores": _scores,
		"rounds_won": _rounds_won,
		"timer": _round_timer,
	}
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
	_rpc_all("round_state", [data])


# ── 击杀归因(自带一份,不从基类上提)──
# `kill_event` 要带"是谁杀的"(归因不到就带 0),Task 6 的"只复位击杀者"也读它,故在这里落。
# ★ 为什么自带而不是把 `RoyaleHost._attributed_killer` 上提到基类:基类的归属由
#   `tests/kh_l5_probe.gd` 的"新接口归属(基类不得含子类方法)"反向断言守着,为省 12 行去动
#   那条探针不划算;两份都不足 15 行,读的还是同一个 meta(单一来源仍是 CombatFeedback)。
func _attributed_killer(victim: Node2D) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) > ATTRIB_WINDOW:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0
```

- [ ] **Step 2: `--import` + 让用户跑**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: `TEAM HOST: ALL-OK`

- [ ] **Step 3: 在探针里补一条"到 9 杀就收局"的断言**

```gdscript
	# ── ⑥ 9 杀收局:把 1 队刷到 9 → ROUND_OVER,局胜记在**队**上 ──
	_host._scores = {1: 8, 2: 0}
	var p5: Node2D = _host.players[5]
	# 5 号在 2 队 → 倒地给 1 队 +1 = 9 → 收局
	(p5.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(int(_host._scores.get(1, 0)) == 9, "1 队到 9 杀")
	_check(int(_host._round_state) == int(MatchHost.RoundState.ROUND_OVER), "★ 到 9 杀收局")
	_check(int(_host._rounds_won.get(1, 0)) == 1, "局胜记在**队**上(1 队 = 1)")
```

- [ ] **Step 4: 提交**

```bash
git add server/team_host.gd tests/team_host_probe.gd
git commit -m 'feat(team): 按队计分与 9 杀收局(scores/rounds_won 的键 = 队号)+ 探针断言'
```

---

## Task 6: ⑩ 只复位击杀者

**Files:**
- Modify: `server/team_host.gd`
- Modify: `tests/team_host_probe.gd`

**Interfaces:**
- Consumes: `_attributed_killer`（Task 5）、`CombatFeedback.attribute` 写下的 `last_damager` / `last_damager_time` meta
- Produces: `TeamHost._reset_killer_only(victim: Node2D, victim_role: int) -> void`

- [ ] **Step 1: 在 `server/team_host.gd` 加复位**

```gdscript
# 击杀后复位:**只把击杀者本人**送回本方出生点(保留血量,不治疗),队友不动。
# (1v1 是"另一方即活方回出生点";三人队里"活方"没有唯一解 —— 用户裁定只动击杀者。)
# ★ 三个"不复位"的档,一个都不能省:
#   · 无归因(溺水/自伤/K 自杀)→ killer 0;
#   · 队友互炸(归因指向同队的人)→ 得分照样给对方队,但**不把队友送回出生点**;
#   · 击杀者自己也倒了(同归于尽)→ 他去走自己的复活流程。
func _reset_killer_only(victim: Node2D, victim_role: int) -> void:
	var killer_role := _attributed_killer(victim)
	if killer_role == 0:
		return
	if same_team(killer_role, victim_role):
		return
	var killer: Node2D = players.get(killer_role)
	if killer == null or not is_instance_valid(killer) or killer.is_downed():
		return
	var spawn: Vector2i = _round_spawns.get(killer_role, Vector2i(-1, -1))
	var ts := GameParameters.TILE_SIZE
	killer.global_position = Vector2(spawn.x * ts + ts * 0.5, spawn.y * ts + ts * 0.5)
	killer.velocity = Vector2.ZERO
	if killer.has_method("cancel_jump_state"):
		killer.cancel_jump_state()
```

- [ ] **Step 2: 在探针里补 ⑤（三条"不复位"档 + 一条"复位"档）**

```gdscript
	# ── ⑦ ⑩:只复位击杀者 ──
	# (a) 无归因:2 队的人倒地 → 1 队 +1,但**没有任何人被复位**
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._scores = {}
	var p2: Node2D = _host.players[2]
	var home2 := p2.global_position
	(p2.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(p2.global_position.is_equal_approx(home2) or (p2.get_node("Combat") as Node).is_downed(),
			"★ 无归因 · 无人被复位(实际位置 %s)" % str(p2.global_position))

	# (b) 异队击杀:给 6 号写归因(1 队的人),再让 6 号... —— 直接验"击杀者回本方出生点"
	var p1: Node2D = _host.players[1]
	var away := _host._round_spawns[4]   # 把 1 号挪到 2 队的点上,便于区分"有没有被送回去"
	var ts := GameParameters.TILE_SIZE
	p1.global_position = Vector2(away.x * ts + ts * 0.5, away.y * ts + ts * 0.5)
	CombatFeedback.attribute(p2, p1)   # 1 号打了 2 号
	(p2.get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	var home1: Vector2i = _host._round_spawns[1]
	var want := Vector2(home1.x * ts + ts * 0.5, home1.y * ts + ts * 0.5)
	_check(p1.global_position.distance_to(want) < 2.0, "★ 异队击杀 · 击杀者被送回本方出生点")

	# (c) 队友互炸:4 号(2 队)打 5 号(2 队)→ 5 号倒地,4 号**不动**
	var p4b: Node2D = _host.players[4]
	var p4_home := p4b.global_position
	CombatFeedback.attribute(_host.players[5], p4b)
	(_host.players[5].get_node("Combat") as Node).force_down()
	_host._match_round_tick(0.016)
	_check(p4b.global_position.distance_to(p4_home) < 2.0, "★ 队友误炸 · 击杀者不被复位")
```

★ 实施注意：`CombatFeedback.attribute` 是**单机/大乱斗的归因写端**（`ui/combat_feedback.gd:65-71`），探针直接调用它是"用生产入口摆前提"，不是绕过实现。

- [ ] **Step 3: `--import` + 让用户跑**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: `TEAM HOST: ALL-OK`

- [ ] **Step 4: 提交**

```bash
git add server/team_host.gd tests/team_host_probe.gd
git commit -m 'feat(team): 击杀后只复位击杀者本人(三条不复位档:无归因/队友误炸/同归于尽)+ 探针'
```

---

## Task 7: 三局两胜 + 整队换边

**Files:**
- Modify: `server/team_host.gd`
- Modify: `tests/team_host_probe.gd`

**Interfaces:**
- Consumes: `compute_swap_spawns`（Task 4）、`_reset_world_and_clear_dynamics`（基类）
- Produces: `TeamHost._start_next_round() -> void` 覆写

- [ ] **Step 1: 追加 `_start_next_round`**

```gdscript
# 换局:局胜到 TEAM_ROUNDS_TO_WIN → MATCH_OVER;否则**整队换边** + 下一局。
# ★ 与基类的三处实质差异:
#   ① 局胜的键是**队号**(基类按 role 查,团队下永远是 0 → 永远打不完);
#   ② 换边 = `_round_spawns` 与 `_swap_spawns` **整体互换**(基类只翻一个 `_side_swap` 布尔);
#   ③ 换边后要**清 `_spawned_once`** —— 否则 `_spawn_cell` 走"动态复活点"分支,
#      开局六个人会被撒到"离敌人远"的随机格,而不是本方出生点。
func _start_next_round() -> void:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			_round_state = RoundState.MATCH_OVER
			_broadcast_round_state()
			return
	_reset_world_and_clear_dynamics()
	if not _swap_spawns.is_empty():
		var tmp := _round_spawns
		_round_spawns = _swap_spawns
		_swap_spawns = tmp
	_spawned_once.clear()
	_round_num += 1
	_scores = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()
```

- [ ] **Step 2: 探针补一条换边断言**

```gdscript
	# ── ⑧ 换边:第 2 局开局后,role1 站在原 role4 的出生点上 ──
	var before1: Vector2i = _host._round_spawns[1]
	var before4: Vector2i = _host._round_spawns[4]
	_host._rounds_won = {}     # 清成 0:0,保证这一局是"下一局"而不是终局
	_host._start_next_round()
	_check(_host._round_spawns[1] == before4 and _host._round_spawns[4] == before1,
			"★ 换边:两队出生点整体对调")
	var ts2 := GameParameters.TILE_SIZE
	var want1 := Vector2(before4.x * ts2 + ts2 * 0.5, before4.y * ts2 + ts2 * 0.5)
	_check((_host.players[1] as Node2D).global_position.distance_to(want1) < 2.0,
			"★ 换边后玩家真的站在新的一侧(不是只在表里对调)")
```

- [ ] **Step 3: `--import` + 让用户跑**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: `TEAM HOST: ALL-OK`

- [ ] **Step 4: 提交**

```bash
git add server/team_host.gd tests/team_host_probe.gd
git commit -m 'feat(team): 三局两胜 + 整队换边(点集对调 + 清 _spawned_once)+ 探针'
```

---

## Task 8: 掉线 —— 整队走光才终局

**Files:**
- Modify: `server/team_host.gd`（`mark_disconnected` 覆写）
- Create: `tests/team_disconnect_probe.gd` + `.tscn`

**Interfaces:**
- Consumes: 基类 `RoyaleHost` 之外无 —— `MatchHost` 没有 `mark_disconnected`，本册自己定；`server_main._expire_graces` 会按 `has_method` 调它
- Produces: `TeamHost.mark_disconnected(role: int) -> void`

- [ ] **Step 1: 在 `server/team_host.gd` 加掉线处理**

```gdscript
# ── 中途掉线(宽限期到点后由 server_main 调)—— 移出对局,但**整队走光才终局** ──
# ★ 判据是"某个队一个人都不剩",**不是** royale 那条"players.size() < 2":
#   6 人局里掉 1 个就终局 = 剩下的人白打(用户裁定:该队少人继续打)。
# ★ 也不能数 `peer_by_role`(那是"有网络连接的人"):3v3 没有 AI 补位,两者当前同键集,
#   但判据写成"每队还剩几个**在场上**的人"才表达得出这条规则的本意。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true
	_respawn_pending.erase(role)
	_down_counted[role] = true
	if players.has(role):
		var p: Node = players[role]
		if is_instance_valid(p):
			p.queue_free()
		players.erase(role)
	if input_sources.has(role):
		input_sources.erase(role)
	peer_by_role.erase(role)
	_broadcast_round_state()
	if _round_state == RoundState.MATCH_OVER:
		return
	# 还有人的队:统计(队伍表里没出现的队号不算)
	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2:
		_finish_match()


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


var _left: Dictionary = {}   # role -> true(已移出对局;排行榜/比分判据用)
```

★ `_left` 的声明放到类顶部字段区（与 `_round_spawns` 并列），别留在函数下面 —— GDScript 允许，但本仓的字段都在顶部。

- [ ] **Step 2: 写 `tests/team_disconnect_probe.gd` + `.tscn`（双向）**

```gdscript
extends Node

# TeamHost.mark_disconnected:**整队走光才终局**(双向断言)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/team_disconnect_probe.tscn
# 通过 = `TEAM DISCONNECT: ALL-OK`。
#
# ═══ 为什么需要它(照 royale_disconnect_count_probe 的先例)═══
# ★ 只断言"掉 1 人不终局"的话,一个**永不终局**的实现也能全绿 —— 本探针另配一条反向断言
#   (整队走光**必须**终局),两条一起才说明判据是"按队"而不是"恒 false"。
# ★ 这条判据错了的表现同样是静默的:要么"掉一个就结束"(玩家白打),要么"永远不结束"
#   (worker 僵持占端口)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

var _fails: Array[String] = []
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_run()
	_finish()


func _place(host, role: int) -> void:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	host.players[role] = p


func _run() -> void:
	var host = TeamHost.new(MAP, {}, {}, [], {}, TEAMS)
	add_child(host)
	host.set_physics_process(false)
	for role in TEAMS:
		_place(host, role)
	await get_tree().physics_frame

	# ── ① 掉 1 人(1 队的 3 号)→ **不得**终局 ──
	host.mark_disconnected(3)
	_check(int(host._round_state) != int(MatchHost.RoundState.MATCH_OVER),
			"★ 掉 1 人不终局(该队少人继续打)")
	_check(host.players.size() == 5, "掉线者已移出 players")
	# ── ② 同队再掉一人(1 号)→ 仍不终局 ──
	host.mark_disconnected(1)
	_check(int(host._round_state) != int(MatchHost.RoundState.MATCH_OVER), "★ 同队掉 2 人仍不终局")
	# ── ③ 1 队最后一人也走 → **必须**终局 ──
	# ★ 这条是反向验证的**区分点**:此刻场上还剩 2 队的 4/5/6 共 **3 人**,
	#   royale 那条 `players.size() < 2` 判据在这里**不会**终局 —— 两条判据答案相反。
	host.mark_disconnected(2)
	_check(host.players.size() == 3, "场上还剩 2 队的 3 个人")
	_check(int(host._round_state) == int(MatchHost.RoundState.MATCH_OVER),
			"★ 整队走光 → 必须终局(反向断言:royale 那条判据在这里给 false)")
	_ran_to_end = true


func _finish() -> void:
	if _fails.is_empty() and _ran_to_end:
		print("TEAM DISCONNECT: ALL-OK")
		get_tree().quit(0)
	else:
		print("TEAM DISCONNECT: FAIL")
		for f in _fails:
			print("  - %s" % f)
		if not _ran_to_end:
			print("  - ★ 探针没跑到末尾")
		get_tree().quit(1)
```

- [ ] **Step 3: `--import` + 让用户跑（含反向验证）**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_disconnect_probe.tscn`
Expected: `TEAM DISCONNECT: ALL-OK`

- [ ] **Step 4: 反向验证（照本仓纪律，把红跑出来）**

把 `mark_disconnected` 末尾的 `if alive_teams.size() < 2: _finish_match()` 两行**临时换成** royale 的那条判据：

```gdscript
	if players.size() < 2:
		_finish_match()
```

重跑 → 期望 **③ 的"必须终局"那条变红**（此刻场上还有 3 人，royale 判据判 false）。把两次输出写进报告，然后**换回**按队判据、再跑一次确认绿。

- [ ] **Step 5: 提交**

```bash
git add server/team_host.gd tests/team_disconnect_probe.gd tests/team_disconnect_probe.gd.uid \
  tests/team_disconnect_probe.tscn
git commit -m 'feat(team): 掉线整队走光才终局(mark_disconnected 覆写)+ 双向探针'
```

---

## Task 9: `--team` / `--teams` 启动契约

**Files:**
- Modify: `server/worker_launcher.gd`（新增 `spawn_team_worker` + `TEAM_PORT_REUSE_DELAY`）
- Modify: `server/server_main.gd`（解析 + 分支 + 超时梯 + `_begin_match` + `_on_peer_left` + `_expire_graces`）
- Modify: `tests/room_sweep_smoke.gd`（双向断言）

**Interfaces:**
- Consumes: `TeamHost.start_on`（Task 4）
- Produces:
  - `WorkerLauncher.spawn_team_worker(port: int, roles: Array, teams: Array) -> bool`
  - `WorkerLauncher.TEAM_PORT_REUSE_DELAY := 360.0`
  - `server_main._team: bool`、`_team_of_role: Dictionary`（role → 队号）

- [ ] **Step 1: 在 `server/worker_launcher.gd` 加常量与 spawn**

```gdscript
# 3v3 worker 的端口归还延迟:一局最长 = 三局两胜 × 9 杀(比 1v1 长得多),与 royale 同档。
# ★ 已知边界照旧(与 WORKER_PORT_REUSE_DELAY 的同款问题):计时从**房间拆除(≈开局)**起算,
#   不是从局内断线起算 —— 一局中后段掉线时端口可能已被复用。
const TEAM_PORT_REUSE_DELAY := 360.0


# 拉起 3v3 worker(--team --roles r,r,... --teams t,t,...;其余同 spawn_royale_worker)。
# roles 与 teams **同序**、**等长**:第 i 个 role 的队号就是 teams[i]。
# ★ 为什么队号要显式传、不从 role 号推:role 由大厅「最小空闲号」分配,有人退出会留空洞
#   ({1,3,5} 而 3 人),奇偶/区间推导必然出错(与 --roles 同一条纪律)。
# ★ 本函数与 server_main.gd 的 argv 解析**逐字对应**,两边改一处必须同步改另一处
#   (守卫见 tests/room_sweep_smoke.gd 的双向断言)。
func spawn_team_worker(port: int, roles: Array, teams: Array) -> bool:
	if roles.size() != teams.size():
		push_error("spawn_team_worker: roles 与 teams 长度不等(%d vs %d),拒绝拉起" % [roles.size(), teams.size()])
		return false
	var role_strs := []
	for r in roles:
		role_strs.append(str(int(r)))
	var team_strs := []
	for t in teams:
		team_strs.append(str(int(t)))
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--team",
				"--port", str(port), "--roles", ",".join(role_strs),
				"--teams", ",".join(team_strs)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--team",
				"--port", str(port), "--roles", ",".join(role_strs),
				"--teams", ",".join(team_strs)])
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn team worker pid=%d port=%d roles=%s teams=%s 日志=%s" % [pid, port,
			str(roles), str(teams), log_path(port)])
	return pid > 0
```

- [ ] **Step 2: 在 `server/server_main.gd` 加解析与状态**

字段区（`_royale` / `_role_set` 那一片）加：

```gdscript
# ── 3v3 worker(--team --roles r,r --teams t,t):团队对抗 ──
var _team_mode := false
var _team_of_role: Dictionary = {}   # role(int) -> 队号(1/2);由 --teams 与 --roles **同序**解析
```

`_ready` 的解析循环（`:40-66`）加两个分支：

```gdscript
			"--team":
				_team_mode = true
			"--teams":
				if i + 1 < args.size():
					for tok in str(args[i + 1]).split(","):
						var t := int(tok.strip_edges())
						if t >= 1 and t <= 2:
							_team_teams_raw.append(t)
```

（`var _team_teams_raw: Array[int] = []` 也加到字段区。）

开局前的校验（放在现有 `if is_worker:` 里、`_royale` 那一支之后）：

```gdscript
		if _team_mode:
			# --roles 与 --teams 必须等长且非空(队号按**同序**配对)。不等 = 拒绝启动:
			# 猜一个默认队号会把整局分成错的队,而且**不报错**(两队人数还可能是 3:3,看不出来)。
			if _role_set.is_empty() or _role_set.size() != _team_teams_raw.size():
				push_error("3v3 worker: --roles 与 --teams 必须等长且非空(%d vs %d),拒绝启动" % [
						_role_set.size(), _team_teams_raw.size()])
				get_tree().quit(1)
				return
			for idx in range(_role_set.size()):
				_team_of_role[_role_set[idx]] = _team_teams_raw[idx]
```

- [ ] **Step 3: 三条分支（收齐判据 / 超时梯 / `_begin_match`）**

`_on_role_claimed` 的收齐判据（`:405-414`）加一支：

```gdscript
	if _team_mode:
		print("worker: 3v3 角色 %d = peer %d (%d/%d 人)" % [role, caller,
				_claims.size(), _role_set.size()])
		# ★ 满员才开:用户裁定「满 6 人才开」,没有降级开局这一档(与 --royale 不同)
		if _claims.size() >= _role_set.size():
			_defer_begin_match()
	elif _royale:
		...
```

`_begin_match`（`:435-456`）加一支：

```gdscript
	if _team_mode:
		_host = TeamHost.start_on(_claims, MatchBootstrap.PVP_MAP, _claim_opts.get(1, {}), _team_of_role)
	elif _royale:
		...
```

`_process` 的超时梯（`:259-270`）—— ★ 3v3 **不降级**，只能退出：

```gdscript
	# 3v3:人没到齐就干等没有意义(满 6 人才开)→ 超时**退出释放端口**,绝不降级开局。
	# ★ 与 --royale 那条"20s 按已到人数开局"是**相反**的决定:那边是自由混战(N 人可打),
	#   这边两队人数必须相等才成立。
	if _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 3v3 报到超时(%d/%d),退出释放端口" % [_claims.size(), _role_set.size()])
			get_tree().quit(0)
	elif _royale and not _match_started and _host == null and _claims.size() >= 2:
		...
```

`_on_peer_left` 的"未开局"支（`:509-524`）：把 `_team_mode` 并入 `_royale` 那一支（未开局掉人就摘除继续等；但 3v3 人掉光了也没法开，交给上面那条超时梯）。**已开局**那一支：3v3 要走宽限期（同 royale）：

```gdscript
		if _royale or _team_mode:
			# 大乱斗/3v3:单个参与者掉线 = 先进宽限期(身体留在场上),宽限内可 reclaim 回来
			...
```

`_expire_graces`（`:224-249`）同理：`if _royale or _team_mode:` 走 `mark_disconnected`；1v1 那一支保持"收场退进程"。

★ **收场退出条件的核对**（这条最容易漏）：`_expire_graces` 末尾那条"全员走光才退出"现在是 `if _royale and _match_started and ...` —— 3v3 必须一起进去（否则 3v3 局里所有人走光后 worker 永驻）。

- [ ] **Step 4: 扩 `tests/room_sweep_smoke.gd` 的双向断言**

在该文件的 argv 断言段（`:79-105`）加：

```gdscript
	# ── 批次 3(3v3)新增:--team / --teams 两边必须逐字对应 ──
	for f in ["res://server/worker_launcher.gd", "res://server/server_main.gd"]:
		var src := ScanUtil.read_file(f)
		if not src.contains('"--team"'):
			_fail = "%s 未接 --team(3v3 启动协议只接了一半?)" % f
		if not src.contains('"--teams"'):
			_fail = "%s 未接 --teams(队号集合没传过去,worker 会拒绝启动)" % f
	# 反向:旧的/被取代的标识符一个都不许复活
	for bad in ["--team-size", "--players", "--max-role", "_team_bound"]:
		for f in ["res://server/worker_launcher.gd", "res://server/server_main.gd"]:
			if ScanUtil.read_file(f).contains(bad):
				_fail = "%s 里出现了不该有的标识符 %s" % [f, bad]
```

- [ ] **Step 5: `--import` + 启动冒烟（agent 自己可跑，不占端口）**

Run: `"$GODOT" --headless --path . --import`
Run: `timeout 60 "$GODOT" --headless --path . res://server/server_main.tscn -- --worker --team --port 29011 --roles 1,2,3,4,5,6 --teams 1,1,1,2,2,2`
Expected: 打印 `[server] 版本 …` 与 worker 就绪文案；**不**出现 `--roles 与 --teams 必须等长`。跑完用 `ProcUtil.kill_udp_port` 同款方式收尾（`taskkill` 按 PID；端口 29011 是池外端口）。
Run（**负向**）：同样的命令但 `--teams 1,1,1,2,2`（5 个）
Expected: `push_error("3v3 worker: --roles 与 --teams 必须等长…")` 且退出码 1。

- [ ] **Step 6: 提交**

```bash
git add server/worker_launcher.gd server/server_main.gd tests/room_sweep_smoke.gd
git commit -m 'feat(team): --team/--teams 启动契约(两处逐字对应 + 双向断言;满 6 人才开、不降级)'
```

---

## Task 10: `match_sync` 带 `teams` + `CLAUDE.md`

**Files:**
- Modify: `server/server_main.gd`（`_on_match_sync` 的应答）
- Modify: `tests/team_host_probe.gd`（源码级断言）
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `TeamHost.team_map()`（Task 4）
- Produces: `match_sync_data` 载荷新增 `teams: {role: 1|2}`（**A 册只负责发，消费在 B 册**）

- [ ] **Step 1: 在 `_on_match_sync` 的应答里加 `teams`**

在构造 `data` 之前：

```gdscript
	# 队伍表:进场/重连各拉一次,客户端据此上色/分组。
	# ★ 必须**显式下发**:role 号由大厅「最小空闲号」分配、有人退出后会留空洞,客户端
	#   从 roles 推导必然出错(这正是 --roles 那条协议当年的教训)。
	# ★ 不进 round_state:开局载荷只留**一条**投递路径(自检 B2 那类事故的形状)。
	var teams: Dictionary = {}
	if _host != null and _host.has_method("team_map"):
		teams = _host.team_map()
```

并把 `data` 的键补齐（**只在非空时带**，与 `destroyed` 同款纪律）：

```gdscript
	if not teams.is_empty():
		data["teams"] = teams
```

- [ ] **Step 2: 在探针里加源码级断言**

```gdscript
	# ── ⑨ 源码级:match_sync 的应答里必须带 teams,且来自 team_map() ──
	var src: String = FileAccess.get_file_as_string("res://server/server_main.gd")
	_check(src.contains('data["teams"] = teams'), "★ match_sync 应答带 teams")
	_check(src.contains('has_method("team_map")'), "★ teams 来自宿主的只读取法(不是就地推导)")
```

- [ ] **Step 3: 更新 `CLAUDE.md`**

在「网络与 PvP」一节之后新增小节 `#### 3v3 团队模式（A 册：服务端与规则）`，写进四条**后人会踩**的：

1. 队伍表 `MatchState._team_of` 来自 `--teams`（与 `--roles` 同序等长），**不得从 role 号推导**（编号有空洞）。
2. `same_team()` 的 0 语义：任一方 0 → false（否则 1v1 两人会被判成队友、子弹全穿）。
3. **子弹穿透队友、爆炸对队友满效** —— 后者是**现状行为**，`Explosion` 一行未改；改爆炸那条路径前先读 `bullet_base.gd:241`。
4. 掉线判据是"**整队走光**才终局"（不是 royale 的 `players.size() < 2`），且 `_expire_graces` 的收场分支必须把 `_team_mode` 一起收进去。

- [ ] **Step 4: `--import` + 让用户跑探针**

Run: `"$GODOT" --headless --path . --import`
Run（**让用户跑**）：`timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn`
Expected: `TEAM HOST: ALL-OK`

- [ ] **Step 5: 提交**

```bash
git add server/server_main.gd tests/team_host_probe.gd CLAUDE.md
git commit -m 'feat(team): match_sync 下发队伍表 + CLAUDE.md 记录 A 册四条纪律'
```

---

## Task 11: 队友不互挡（分队碰撞层，服务端侧）

> ★ **本条是开工后补的**：设计初稿**漏了**"队友是否物理互挡"这条规则（探索阶段明确列过它是 3v3 必须决策的点，写 spec 时没带进去）。用户裁定：**完全穿透**。设计 §3 规则 12 与 §4.7 记了机制与代价。

**Files:**
- Modify: `server/team_host.gd`（`_init` 里 `super._init` **之后**）
- Modify: `tests/team_host_probe.gd`（补断言）

**Interfaces:**
- Consumes: `MatchHost._init` 已给每个玩家 `collision_mask |= 2`；`team_of(role)`
- Produces: `TeamHost.TEAM_ENEMY_LAYER := 16`（层位 5，队 B 的身体层）

- [ ] **Step 1: 在 `TeamHost._init` 的 `super._init(...)` 之后加分队层**

```gdscript
	# ── 队友不互挡(用户裁定"完全穿透")──
	# ★ 为什么必须"分队位"而不是改掩码:Godot 的碰撞**按节点**配,没有"按对"的开关。
	#   全部玩家同在第 2 层时,掩码含 2 就是"与所有玩家碰撞",无法只豁免队友。
	#   把队 B 挪到新层位 16,让两队掩码**互指对方的位**,即可 A↔B 挡、A↔A 与 B↔B 穿。
	# ★ 必须在 super._init **之后**:super 的建玩家循环里已经给每个人 `mask |= 2`。
	#   队 A 要把那一位**抹掉**再补上 16;队 B 则保留 super 给的 7(1|4|2)—— 正是它要的。
	# ★ 单机 / 1v1 / 大乱斗一行不受影响:它们不走本类。
	for role in players:
		var p: Node2D = players[role]
		if p == null or not is_instance_valid(p):
			continue
		if team_of(int(role)) == 1:
			p.collision_layer = 2
			p.collision_mask = (p.collision_mask & ~2) | TEAM_ENEMY_LAYER
		else:
			p.collision_layer = TEAM_ENEMY_LAYER
```

并在常量区加：

```gdscript
const TEAM_ENEMY_LAYER := 16   # 队 B 的身体层(层位 5,当前空闲:1 地形/2 玩家/3 敌人/4 掉落物)
```

- [ ] **Step 2: 探针补断言（含一条**真行为**断言，别只比掩码位）**

```gdscript
	# ── ⑨ 队友不互挡:层/掩码按队分开 ──
	var a: Node2D = _host.players[1]    # 1 队
	var b: Node2D = _host.players[4]    # 2 队
	_check(a.collision_layer == 2 and b.collision_layer == TeamHost.TEAM_ENEMY_LAYER,
			"两队的身体层分开(1 队=2 / 2 队=16)")
	_check((a.collision_mask & 2) == 0, "★ 1 队掩码**不含**玩家层(否则队友会互挡)")
	_check((a.collision_mask & TeamHost.TEAM_ENEMY_LAYER) != 0, "1 队掩码含敌队层")
	_check((b.collision_mask & 2) != 0, "2 队掩码含玩家层")
	_check((b.collision_mask & TeamHost.TEAM_ENEMY_LAYER) == 0, "★ 2 队掩码**不含**敌队层(同上)")
	# ★ 位对了不等于物理对:再用 test_move 验一次**真行为**(它读的是物理空间,不是掩码值)。
	#   把 b 挪到 a 正右一格,让 a 朝它走:应当被挡;再把队友(role3,1 队)挪到同处,应当穿过去。
	var ts := GameParameters.TILE_SIZE
	a.global_position = Vector2(20 * ts, 20 * ts)
	var mate: Node2D = _host.players[3]
	mate.global_position = Vector2(21 * ts, 20 * ts)
	b.global_position = Vector2(21 * ts, 24 * ts)
	await get_tree().physics_frame
	_check(not a.test_move(a.global_transform, Vector2(ts, 0)), "★ 行为:朝队友走**不被挡**(穿透)")
	b.global_position = Vector2(21 * ts, 20 * ts)
	mate.global_position = Vector2(21 * ts, 24 * ts)
	await get_tree().physics_frame
	_check(a.test_move(a.global_transform, Vector2(ts, 0)), "★ 行为:朝敌人走**被挡**")
```

★ 上面的坐标只是示意 —— 落的时候要**自己挑两个地面开阔、且中间没有墙的格**（用 `MazeGenerator.is_floor_cell_with_headroom` 找），否则 `test_move` 会因为墙而不是因为人返回 true（那就变成"测的是地形"）。并在报告里写明你选的是哪两格、怎么确认中间无墙。

- [ ] **Step 3: `--import` + 自跑 + 回归**

Run: `"$GODOT" --headless --path . --import`
Run（可自跑，不占端口）：`timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn` → `TEAM HOST: ALL-OK`
Run（**让用户跑**，回归线）：`timeout 600 "$GODOT" --headless --path . --quit-after 3600 res://tests/match_host_hygiene_probe.tscn` 与 `royale_disconnect_count_probe.tscn` → 各自 `ALL-OK`（"空参数 = 原行为"）

- [ ] **Step 4: 变异反证（本仓纪律）**

把 `TEAM_ENEMY_LAYER` 临时改回 `2`（= 两队同层，退化成"全员互挡"）→ 期望 Step 2 的两条 ★ 断言**变红** → 逐字还原并 `git diff` 确认。

- [ ] **Step 5: 提交**

```bash
git add server/team_host.gd tests/team_host_probe.gd
git commit -m 'feat(team): 队友不互挡(分队碰撞层:1 队 layer2 / 2 队 layer16)+ 行为断言'
```

★ **客户端那一半（本地玩家掩码按自己的队、副本幽灵体按它代表的队）归 B 册 Task 6** —— 只做服务端这一半时，3v3 还跑不起来（B 册未落地），但两侧的**契约**（层位 16 与"掩码互指"）在本任务里定死。

---

## 自检记录

**spec 覆盖**：§4.1 权威链（Task 9 的命令行 + Task 4 的 `start_on`）→ ✓；§4.2 覆写表（Task 4/5/6/7/8）→ ✓；§4.3 友伤（Task 2；**§4.3 里"给 `apply_aoe` 加参数"一说是错的** —— 队友吃爆炸满效是现状默认行为，已改为"不动"）→ ✓；§4.4 出生/复活（Task 3 的 `SpawnPicker` + Task 4）→ ✓；§4.5 三态化（**一半**：worker 侧在 Task 9；大厅侧 `teardown_room` 的三态、端口延迟的接线上归 B 册。★ **收尾批（全支最终审查）补上了清单漏掉的第五处** —— `server_main._on_suicide_request` 的闸改 `not (_royale or _team_mode)` + `TeamHost.request_suicide_role`；`TEAM_PORT_REUSE_DELAY` 零读者一条已写进 B 册计划与 `b-task-3-brief.md`）→ 部分；§4.6 掉线重连（Task 8；**宽限期机制本身不动**，`reclaim_role` 已按 role 工作、与队伍无关）→ ✓；§6 协议（Task 10 的 `teams`；`kill_event` 载荷保持 role 粒度 → Task 5 的注释）→ ✓；§7 常量（Task 4/5 的 `TEAM_*`）→ ✓；§10 守卫（各任务的探针；**6 人真链路压测归 B 册**）→ 部分。

**本册不做（明写）**：大厅选边房间与 NetBusExt RPC、`teardown_room` 三态与端口延迟接线、客户端 `team_game` 与 `TeamHud`、主菜单入口、6 人真链路压测、`match_sync.teams` 的**消费** —— 全部归 B 册。

**与原设计的两处偏差（照实登记）**：
1. §4.3 的"给 `Explosion.apply_aoe` 加队伍参数"**作废**（满效 = 现状，不必改）。
2. §1 的"`RoyaleHost` 一行不改"改为"**行为**一行不改" —— Task 3 把它的静态出生几何逐字搬到 `SpawnPicker` 并留转发（理由：3v3 必须共用同一套"别出生在密封小间"的判据，抄第二份就是本仓明令禁止的那种重复）。

**现场确认项（不是占位符，是"必须看真实签名"）**：

1. ~~Task 2 探针的子弹字段名~~ → **已核实（2026-09-18）**：`scenes/weapons/bullet_base.gd:26` `var shooter: Node = null`、`:27` `var hit_damage: int = 0`；组 `bullet` 是在 **`bullet_base.gd:62` 的 `_ready()` 里 `add_to_group("bullet")`** 加的（`bullet.tscn` 自己**没有** `groups=` 声明）→ 探针**必须先 `add_child` 再调 `_adjudicate_bullets`**，否则 `get_nodes_in_group("bullet")` 找不到它、两半断言都空转。`Player` 的 `Combat` 节点名已核实：`player.tscn:168` 就是 `[node name="Combat"]` → `p.get_node("Combat").force_down()` 可用。
2. Task 4 的 `_place()` 建的玩家是否需要 `host.input_sources[role] = src`（`_physics_process` 会遍历 `input_sources`；手工摆的玩家不入表则不被喂输入 —— 探针手工驱动，二者皆可，但**要一致**）。
3. Task 9 Step 3 的 `_on_peer_left` / `_expire_graces` 分支合并点，按当时的真实行号落。
