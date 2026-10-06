# 激光不打队友（3v3 友伤）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 3v3 里激光枪不再对队友造成伤害，且与子弹/榴弹直击的"穿透"口径一致 —— 队友既不掉血、也不挡住光束。

**Architecture:** 激光是**即时命中**、不走 `_adjudicate_bullets`，所以 `same_team` 的既有调用点
（全在 `server/`）一处都覆盖不到它 —— 它在权威侧**直接**结算伤害。修法有两条：
① 在 `MatchState` 上加一个给**武器**用的公开判据 `is_friendly(a, b)`（武器只拿得到节点、拿不到 role）；
② 在 `LaserWeaponBase._damage_path_targets` 的玩家循环里加一条 `continue`。
只改权威侧即可 —— 客户端的视觉副本由 `_authoritative()` 门控先行 return，**根本不结算伤害** ⇒
不碰协议、两端无需同版本。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、场景探针（`--headless --quit-after`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-team-faction-fixes-design.md` §3.1（计划 1/2 中的第 1 份）。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless`、**不占任何端口**；**`tests/pvp_match_smoke.sh` 与实机验收归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，别用 `-m "…"`
  （双引号会**静默吞掉**反引号与 `$`）。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`；本计划不引入新字号）。
- 改 GDScript **只需重导出**，不要重编裁剪模板。
- **只改权威侧**：本计划不碰 `NetBus` / `NetBusExt` 的任何 RPC，不动协议。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `server/match_state.gd` | 对局底座：队伍表 / 逐人状态 / 出生点原语 | **加** `is_friendly(a: Node, b: Node) -> bool`（`_role_of` + `same_team` 的公开包装） |
| `scenes/weapons/laser_weapon_base.gd` | 即时光束武器基类（几何/结算/视觉三缝） | `_damage_path_targets` 的玩家循环**加一条 `continue`** |
| `tests/laser_team_probe.gd` / `.tscn` | **新探针**：3v3 队友穿透 | 全新建 |

---

### Task 1: 探针先行 —— 让"激光打队友"变成红灯

**Files:**
- Create: `tests/laser_team_probe.gd`
- Create: `tests/laser_team_probe.tscn`

**Interfaces:**
- Consumes: `TeamHost.new(map_path, role_peers, options, ai_roles, spawns, teams)`、
  `TeamHost.plan_team_spawns`（本计划**不用**，见下）、`Player.take_hit`、
  `WeaponBase.equip(p, inherit_cooldown)`、`WeaponBase.try_fire()`、
  `PacketInputSource.get_aim_dir_override()`（返回注入的 `aim`）。
- Produces: 一个**会红**的探针。判据是文本 `LASER TEAM PROBE: ALL-OK`。

- [ ] **Step 1: 写探针**

创建 `tests/laser_team_probe.gd`：

```gdscript
extends Node
# 3v3 激光友伤:队友在光束路径上**不掉血**,而队友**身后**的敌人照常掉血(穿透语义)。
#
# 跑法:`--headless --quit-after 3600 res://tests/laser_team_probe.tscn`
# 判据:文本 `LASER TEAM PROBE: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ★ 这条 bug 能活到今天,是因为既有的 `team_table_probe` ③④ 断的是**子弹与爆炸**,
#   激光不在其中 —— 而激光是即时命中、不走 `_adjudicate_bullets`,而 `same_team` 的调用点
#   全在 `server/`(`match_combat` ×2 / `team_host` ×2;`match_state` 那处是定义)。本探针补这个洞。
#
# ★ 后半条(队友**身后**的敌人照常掉血)是**鉴别点**:只断言"队友不掉血"的话,
#   把整个玩家循环删掉也能过。
#
# ★ 与 `tests/team_host_probe.gd` 同款手法:真建 `TeamHost`(`role_peers` 传空)+ 手工摆位,
#   走的是**生产代码路径**(`_damage_path_targets` 是本特性的被改函数)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
const COLS := 60
const ROWS := 12
const TILE_WALL := 31
const ROW := 10          # 射手/队友/敌人桩都站这一行(同一 y ⇒ 水平光束必然穿过身体)


# 敌人桩:3v3 场上没有敌人,但"队友身后的东西照常掉血"是穿透语义的**鉴别点**。
# 无碰撞体 ⇒ `_body_rect` 走兜底 36×36、以节点原点为中心(laser_weapon_base.gd:172-177)。
class StubEnemy extends Node2D:
	var hits := 0
	func hurt(_dmg: int, _dir: Vector2, _impact: float) -> void:
		hits += 1


var _host = null
var _shooter: Node2D = null
var _mate: Node2D = null
var _foe: StubEnemy = null
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
func _ready() -> void:
	await _run()
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("LASER TEAM PROBE: ALL-OK")
	else:
		print("LASER TEAM PROBE: FAIL —— " + str(_fails))
	get_tree().quit(0 if _fails.is_empty() else 1)


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(TILE_WALL if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _run() -> void:
	seed(20260925)
	# ★ 合成平地网格:**不钉真地图** —— 探针要的是"一条无遮挡的水平光束",不是关卡几何。
	#   先填 `current_grid`,`TeamHost._init` 的 `if grid.is_empty()` 守卫就不会再去读地图。
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	GameParameters.refresh_map_size()
	# spawns 显式传:不传的话 `TeamHost._init` 会调 `plan_team_spawns`(它按真实地图挑格),
	# 在合成网格上是另一份散点,与探针要摆的位置无关 —— 摆了也会被 `_place` 覆盖,但白白多算一次。
	var spawns := {1: Vector2i(5, ROW), 2: Vector2i(9, ROW), 3: Vector2i(30, ROW),
			4: Vector2i(34, ROW), 5: Vector2i(38, ROW), 6: Vector2i(42, ROW)}
	_host = TeamHost.new(MAP, {}, {}, [], spawns, TEAMS)
	add_child(_host)
	# ★★ 2026-09-25 订正:合成网格必须在 `TeamHost.new` **之后**重设一次。
	#   本代码块上面那句注释("先填 `current_grid`,`TeamHost._init` 的 `if grid.is_empty()`
	#   守卫就不会再去读地图")**不成立** —— `TeamHost._init` 自己那道守卫只管它那一小段,
	#   它随后调的**超类** `MatchHost._init`(`server/match_host.gd:19-21`)是**无条件**的:
	#       `MazeGenerator.set_map_file(map_path)` + `grid = WorldBuilder.load_grid()`
	#   ⇒ 先进树的合成网格**必被覆盖**。实测(实现者留档):生效的是 `factory1v1.cyrm`
	#   (150×100),光束在里面撞墙**反射折返**、二次扫过敌人 ⇒ 红的成因是几何、与本特性无关,
	#   那样的探针修复后也会因同样几何原因红 = **等于没验**。
	MazeGenerator.current_grid = _build_grid()
	# ★ 关掉宿主自己的物理帧:`quit(0)` 是帧末生效,不关的话中间还会跑一帧 `_physics_process`
	#   → 快照广播去读尚未摆位的 `players`,在断言全过之后刷一屏 SCRIPT ERROR
	#   (与 `team_host_probe` / `royale_disconnect_count_probe` 同款理由)。
	_host.set_physics_process(false)
	for role in TEAMS:
		var p: Node2D = _place(_host, role, spawns[role])
		if role == 1:
			_shooter = p
		elif role == 2:
			_mate = p
	_host._apply_team_layers()
	await get_tree().physics_frame
	# ★ 清无敌帧:出生/复活可能带无敌,不清的话"队友不掉血"这条在**修复前也会绿**(假绿)。
	#   修复前的红本身就是"伤害确实打进去了"的证明;这一步是双保险。
	_mate.combat.iframes = 0.0
	_shooter.combat.iframes = 0.0
	# 敌人桩:放在队友**身后**同一行 —— 证明光束是**穿过去**的,而不是停在队友身上。
	# ★ y 取队友身体的 y(与射手同一行 ⇒ 水平光束的高度落在身体框内)。
	_foe = StubEnemy.new()
	_foe.add_to_group("enemies")
	_host.add_child(_foe)
	_foe.global_position = Vector2(14 * GameParameters.TILE_SIZE + 32, _mate.global_position.y)
	# 武器:直接挂到射手身上并 `equip`(同步入树 ⇒ `@onready` 的 muzzle/sprite 立即有效,
	# 不走 `WeaponComponent` 那条 `call_deferred("add_child")` 的路)。
	var laser: WeaponBase = preload("res://scenes/weapons/laser_gun.tscn").instantiate()
	_shooter.add_child(laser)
	laser.equip(_shooter, 0.0)
	await get_tree().physics_frame
	# 瞄准方向走**输入源的覆盖钩子**(`Player.get_aim_dir_override` → `PacketInputSource._aim`):
	# headless 没有鼠标,落回鼠标会得到一个无意义的方向。
	var src := _shooter.input_source as PacketInputSource
	src.clear_edges()
	src.apply_packet({"seq": 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
			"weapon": 0, "aim": Vector2.RIGHT})
	var hp_before := int(_mate.combat.hp)
	laser.try_fire()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_mate.combat.hp == hp_before,
			"队友在光束路径上**不掉血**(受伤前 %d、受伤后 %d)" % [hp_before, int(_mate.combat.hp)])
	_check(_foe.hits == 1,
			"队友**身后**的敌人照常掉血(命中 %d 次)—— 这是'穿透'的鉴别点" % _foe.hits)
```

- [ ] **Step 2: 建场景**

创建 `tests/laser_team_probe.tscn`（与 `tests/team_host_probe.tscn` 逐字同构，只改名字与脚本）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/laser_team_probe.gd" id="1"]

[node name="LaserTeamProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次，确认它红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/laser_team_probe.tscn 2>&1 | grep -E "LASER TEAM|ok  |FAIL"
```
Expected（修复前）:
```
  ok  队友**身后**的敌人照常掉血(命中 1 次)—— 这是'穿透'的鉴别点
  FAIL 队友在光束路径上**不掉血**(受伤前 50、受伤后 44)
LASER TEAM PROBE: FAIL —— [...]
```

★ **这是本批唯一的红绿分界**，三条判读规则：
- 若**两条都 ok**（探针绿）⇒ 队友根本没被光束扫到（多半是位置或瞄准错了），停下排查，
  **不要**继续 —— 那样的探针在修复后也是绿的，等于没验。
- 若**敌人那条也 FAIL**（`hits = 0`）⇒ 光束压根没发出来（多半是 `try_fire` 被冷却/弹药挡住，
  或瞄准覆盖没生效），同样停下排查。
- 若红的是"队友不掉血"**且**敌人那条 ok ⇒ 正是要的状态，继续。

- [ ] **Step 4: 反证（记下来，Task 2 用完后核对）**

把 Step 3 的输出原文留着 —— Task 2 修完后必须变成全 ok。**本 Step 不提交**（Task 1 是 TDD 的中间态，
与 Task 2 合并为一次提交）。

---

### Task 2: 加 `is_friendly` 并在激光里用它

**Files:**
- Modify: `server/match_state.gd`（`_role_of` 旁边，约 :139-143）
- Modify: `scenes/weapons/laser_weapon_base.gd`（`_damage_path_targets`，:130-142）

**Interfaces:**
- Consumes: 现有 `MatchState.same_team(a_role, b_role) -> bool` 与 `MatchState._role_of(node) -> int`。
- Produces: `MatchState.is_friendly(a: Node, b: Node) -> bool`（公开；给**武器**用）。

- [ ] **Step 1: 加 `is_friendly`**

`server/match_state.gd` 的 `_role_of` 之后（同文件、紧邻）加：

```gdscript
# 两名玩家是否同队。给**武器**用(它们只拿得到节点,拿不到 role)。
# ★ 1v1 / 大乱斗 / 单机:队伍表为空 ⇒ `team_of` 恒 0 ⇒ `same_team` 恒 false ⇒ 本函数恒 false
#   ⇒ 调用方(激光)的行为与今天**逐字不变**。这是本接口的安全性质,别改成"没表就返回 true"。
# ★ `_role_of` 查不到时返回 **-1**(不是 0),而 `same_team(-1, -1)` 同样是 false
#   (`team_of` 对未登记返回 0,判据是 `a > 0 and a == b`)—— 两种"查不到"都安全。
func is_friendly(a: Node, b: Node) -> bool:
	if a == null or b == null:
		return false
	return same_team(_role_of(a), _role_of(b))
```

- [ ] **Step 2: 在激光的玩家循环里用它**

`scenes/weapons/laser_weapon_base.gd` 的 `_damage_path_targets`。判据的取法照抄**同文件已有的先例**
（`:234` 的 `player.get_parent()` + `has_method` 守卫）—— 别新开一条路：

```gdscript
func _damage_path_targets(pts: PackedVector2Array) -> void:
	var targets: Array = []
	for t in get_tree().get_nodes_in_group("enemies"):
		if t is Node2D:
			targets.append([t, true])
	# ★ 宿主的队伍判据:与 `:234` 的 `notify_direct_hit` 同一条形状 —— 单机下
	#   `player.get_parent()` 是 WorldViewport、`has_method("is_friendly")` 为假 ⇒ team_aware 为假
	#   ⇒ 行为与改动前**逐字相同**。PvP 服务器下父节点是 MatchHost(继承 MatchState)⇒ 判据可用。
	var host := player.get_parent() if player != null else null
	var team_aware := host != null and host.has_method("is_friendly")
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:  # 射手本人不吃自己这发
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		if team_aware and host.is_friendly(player, p):
			continue     # ★ 队友穿透:与子弹/榴弹直击同口径(不伤害、也不挡光束)
		targets.append([p, false])
	# （其余部分原样不动）
```

★ **是 `continue` 不是 `break`** —— 队友**不挡弹道**，后面的敌人照打。这一点由 Task 1 探针的
后半条断言钉住（与子弹路径 `if same_team(...): continue` 同语义）。
★ 客户端那份视觉副本**到不了这里**：`_spawn_projectiles` 开头的 `if not _authoritative(): return`
（`:61`）已经把非权威端挡在结算之前 ⇒ 本修法不碰协议、两端无需同版本。

- [ ] **Step 3: 跑 Task 1 的探针，确认转绿**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/laser_team_probe.tscn 2>&1 | grep -E "LASER TEAM|ok  |FAIL"
```
Expected: 两条 `ok  `，末行 `LASER TEAM PROBE: ALL-OK`。

- [ ] **Step 4: 反证（把修复撤掉，确认又红）**

临时把 Step 2 加的那两行（`if team_aware and host.is_friendly(player, p): continue`）注释掉，
再跑 Step 3 的命令，**必须重新红在"队友不掉血"那条上、且敌人那条仍 ok**。确认后改回来。
★ 这一步不可省：它证明**是这条判据**让探针转绿，而不是位置/瞄准碰巧变了。

- [ ] **Step 5: 提交**

```bash
git add server/match_state.gd scenes/weapons/laser_weapon_base.gd \
        tests/laser_team_probe.gd tests/laser_team_probe.tscn
git commit -m "fix(team): 3v3 激光不再打队友 —— MatchState.is_friendly + 激光目标列表按队穿透"
```

（`tests/laser_team_probe.gd.uid` 由 Godot 自行生成，若 `git status` 显示就一并加上。）

---

### Task 3: 回归 + 登记

**Files:**
- Modify: `CLAUDE.md`（§网络与 PvP 的 3v3 小节：把"激光不在其中"这条缺口登记为已闭合）

**Interfaces:**
- Consumes: 无。
- Produces: 无（回归 + 文档）。

- [ ] **Step 1: 跑受影响的既有探针**

Run:
```bash
source tests/env.sh
for t in team_host_probe team_table_probe team_disconnect_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
for t in team_room_smoke laser_weapon_smoke enemy_logic_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR"
done
```
Expected: 全绿（`TEAM HOST: ALL-OK` / `TEAM TABLE: ALL-OK` / `TEAM DISCONNECT: ALL-OK` /
`TEAM ROOM SMOKE: ALL-OK` / `SMOKE OK`）。

★ 特别注意 `team_table_probe` 的 ③④：**它们断的是子弹与爆炸，激光不在其中** —— 这正是这条 bug
能存活至今的原因（spec §1.2 ①）。本批**没有**改它们的判据（那是另一条路径），它们应当原样全绿；
若其中任何一条变红，说明改动越界，停下来报告。

- [ ] **Step 2: 登记进 CLAUDE.md**

在 CLAUDE.md 的 **§网络与 PvP 的「3v3 团队模式」** 小节里，紧挨「子弹穿透队友、爆炸对队友满效」
那一段，补一条：

```markdown
- **激光也穿透队友(2026-09-25 补)**：激光是**即时命中**、不走 `_adjudicate_bullets`，故
  `same_team` 的既有调用点一处都够不到它 —— 修法是 `MatchState.is_friendly(a, b)`（`_role_of` +
  `same_team` 的公开包装，给只拿得到节点的**武器**用）+ `LaserWeaponBase._damage_path_targets`
  玩家循环里一条 `continue`（**不是 `break`**：队友不挡弹道，身后的敌人照打）。
  单机 / 1v1 / 大乱斗下队伍表为空 ⇒ `is_friendly` 恒 false ⇒ 行为逐字不变。
  守卫：`tests/laser_team_probe.tscn`（队友不掉血 **且** 队友身后的敌人照常掉血）。
```

★ 同时订正 spec 的一处计数口径：`same_team` **修前**全仓是 **5 个调用点** —— 构成为
`match_combat` ×2（:52 / :81）+ **`team_host` ×3**（:296 / :704 / :731）；`match_state.gd:42`
是**定义**，另计。spec §1.2 ① 写的"7 个"是 grep 的**行数**（含定义行与一句注释）。
★ 本次改动**又新增了一个调用点**（`match_state.gd` 的 `is_friendly` 体内）⇒ 文档里一律说
"**修前** 5 个"，别写"今天共 N 个" —— CLAUDE.md 相邻那条 bullet 明文立过"本条刻意不写共 N 处、
以 grep 为准"的规矩（那个数**漂过**）。

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(claude): 3v3 激光穿透队友 —— 登记 is_friendly 与 5 个 same_team 调用点"
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3.1）：新接口 ✅ Task 2 Step 1；调用点 ✅ Task 2 Step 2；
"只改权威侧、不碰协议" ✅（`_authoritative()` 门控，Task 2 Step 2 的注释）；
验收判据 1（新探针 + 反证）✅ Task 1/Task 2 Step 4；判据 3（既有探针全绿）✅ Task 3 Step 1；
判据 4（实机）—— **归用户**，已在 Global Constraints 声明。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"；每个改动都给了完整代码块与确切路径。
探针代码是完整可跑的，不是骨架。

**3. 类型一致性**：`is_friendly(a: Node, b: Node) -> bool`（Task 2 定义、Step 2 使用）一致；
`StubEnemy.hurt(_dmg: int, _dir: Vector2, _impact: float)` 与生产调用点
`laser_weapon_base.gd:218` 的 `t.hurt(damage, dir, impact)` **逐位对应**（3 个实参）；
`_place(host, role, at: Vector2i)` 与 `team_host_probe.gd` 的同名助手签名一致。

**4. 明确不在本计划范围**（spec §3.2/§3.3 归第 2 份计划）：小地图自己那个点、未知队户口径。
本计划**不碰** `ui/minimap.gd` / `scenes/team_game.gd` —— 两份计划因此可并行且互不干扰。

**5. 已知边界（承自 spec §4，登记不修）**：爆炸对队友仍满效（用户既有裁定）⇒ 修完激光之后
3v3 里仍会有友伤，来源只剩爆炸，**那是故意的**，别当回归。
