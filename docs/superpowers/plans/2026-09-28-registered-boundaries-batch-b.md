# B 档:「登记边界」六项修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉用户 2026-09-28 清单里 B 档的六条「登记不修」边界(`#2 / #6a / #6b / #7 / #8 / #10 / #11`),
每条都配一条**先看着它报错失败**的判据。

**Architecture:** 全部是**单点行为修复**,不新增协议字段、不改任何 RPC 签名、不动 `NetBus` 方法表。
两个新增判据文件(`late_match_probe` 场景探针 + `duel_spawn_timeout_smoke` 的 `-s` 冒烟),
两个既有判据文件各加断言。**设计依据 = `docs/superpowers/specs/2026-09-28-registered-boundaries-batch-b-design.md`**
(下称 spec),凡本计划与 spec 冲突,以 spec 为准并回报。

**Tech Stack:** Godot 4.7.1 标准版(非 mono)/ GDScript。

## Global Constraints

* **引擎路径**:`tests/*.sh` 读环境变量 `GODOT`(console 版),未设时回落本机默认
  `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`。
  本计划的命令统一写成 `"$GODOT"`,执行前先 `source tests/env.sh`。
* **判据一律是文本,不看退出码** —— 探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打。
  `grep ALL-OK` **只证明「没有任何断言失败」,不证明「每条断言都跑过」**(权威表述:
  `tests/lib/probe_base.gd` 文件头)。
* **判据必须明确是文本还是退出码,两者不许混用**。`timeout … | tail -20; echo "EXIT=$?"` 报的是
  **`tail` 的**退出码(恒 0),区分不出"被掐"与"自己退出" —— 照抄会得到**相反**的结论。
  本仓的默认是**文本判据**;要退出码就**重定向到文件再取 `$?`**,不要接管道。
* **`-s` 阶段 autoload 尚未实例化** —— 需要 autoload 的测试**不能**写 `-s`,必须写场景探针。
  反向:`-s` 冒烟必须写空载守卫(`load()` 后立刻判 null → `quit(1); return`),否则抛错后
  走不到 `quit()`,进程**永久挂起**而不是干净失败。
* **场景探针的 `--quit-after` 统一给 3600**(安全网;探针跑完自己 `quit()`)。
* **协议无需修改**:不动 `NetBus` / `NetBusExt` 的 RPC 方法表,不动任何数据字段名。
* **分层(用户 2026-09-28 裁定)**:`server/**` 归本会话;`scenes/ ui/ tests/ docs/` 归 peer。
  本计划被**具名让渡**的只有 `scenes/player/weapon_component.gd` 与 `scenes/weapons/weapon_base.gd`
  (实际只用后者)+ 四个 `tests/` 文件。**别的 `scenes/` 文件一个都不许碰。**
* **不许碰** `tests/team_match_*`(peer 正在复验)与 `tests/royale_c2_probe*`(peer 阶段 3 要用)。
* **`server/server_main.gd` 的 `_expire_graces` 归 peer**(他的阶段 3 要在里面加
  `opponent_left` 发送点,且必须排在 `quit(0)` **之前**)。本计划**在这份文件上**动的是
  `_process` 的 1v1 报到梯那一段 **加上 `_ready()` 的两处**(`_worker = is_worker` 落进实例标志、
  大厅分支末尾收一句 `set_process(false)`;**2026-09-28 重审订正** —— 此前这条写的是"只动
  `_process`",在加固补丁落地后**已经不成立**)。★ 该约束的**用意**(不碰 `_expire_graces`、
  不改 `quit(0)` 的任何一处位置)仍然**逐字成立**,变的只是它的字面。
* ★★ **`_process` 那一段现在被在源码层面通过断言约束了**(`tests/duel_spawn_timeout_smoke.gd` 的判据①②):
  任何人在 1v1 报到梯的门控里写出 `not _royale` / `not _team_mode` / `not _worker`
  (含 `not (_royale or _team_mode)` 这类拼写),或在 `_ready` 里把 `set_process(false)`
  挪走/在其上插一条早退,都会**当场让那条冒烟报错失败**。**peer 改这一段之前先读那份冒烟的注释**,
  别把"冒烟红了"读成"功能坏了"。
* **跨会话次序**:本计划的 **Task 2(#10)** 必须在 peer 的阶段 3 Task 3 之前落地
  (两者都动 `server_main.gd` 的 `_process` 同段)。Task 2 完成后**立刻通知 peer**。
* **提交纪律**:本仓全在 `main` 上开发,没有分支可并。每个 Task 一次提交,
  `git add` 按**文件名**逐个加(peer 在同一棵工作树上动 `scenes/ tests/ docs/`)。
* **改完不许 `git checkout`/`stash`/`rebase`** —— 工作树上有 peer 的改动。

---

### Task 0: 基线(动手前必做)

**Files:** 无改动。

**Interfaces:**
- Produces: 一份「修前是红的 / 修前是绿的」的基线读数,后面每个 Task 的"报错失败/变绿"都相对它。

- [ ] **Step 0.1: 确认工作树里没有别人的半成品**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git status --porcelain
```

Expected: 只出现 `?? _crashtest/`(既有、与任何会话无关)。**若还有别的条目,停下来问**,
不要 stash、不要 checkout。

- [ ] **Step 0.2: 采基线读数**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | tail -5
timeout 180 "$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd 2>&1 | tail -5
```

Expected: `AMMO ROLLBACK PROBE: ALL-OK(...)` 与 `SMOKE_ROOM_SWEEP OK: ...`。
**记下这两行** —— 它们本批结束时必须还是绿的(本批不改它们覆盖的行为,只加断言)。

- [ ] **Step 0.3: 确认没有残留 godot 进程**

```bash
tasklist | grep -i godot || echo "干净"
```

Expected: `干净`。**非空就先清掉** —— 残留的 worker 会占着 7800 段端口,
让后面 Task 2 的真链路冒烟连到僵尸上(症状是探针挂到外层 timeout、一行裁决都不打)。

---

### Task 1: #2 —— 未入树窗口里的假换弹

**Files:**
- Modify: `scenes/weapons/weapon_base.gd`(`_mag_ready` 声明 / `_ready()` / `fire()`)
- Test: `tests/ammo_rollback_probe.gd`(末尾加一相)

**Interfaces:**
- Consumes: `WeaponBase.equip(p, inherit_cooldown)`(已存在,`:214`)、`WeaponBase.tick(delta)`(`:227`)、
  `WeaponBase.is_reloading() -> bool`(`:121`)、`WeaponBase._reloading: bool`、
  `WeaponBase.mag_ammo: int`、`WeaponRegistry.scene_of(id) -> String`、
  `PacketInputSource.reset_state()`(`core/net/packet_input_source.gd:130`)。
- Produces: `WeaponBase._mag_ready: bool` —— 语义 **"`mag_ammo` 已不是声明初值"**,
  由 `_ready()` 置真一次。**别的判断不许用它**(见 spec §5 风险 4)。

- [ ] **Step 1.1: 写会失败的判据**

在 `tests/ammo_rollback_probe.gd` 的 `_ready()` **最末行之后**加一行调用:

```gdscript
	_run_pre_tree_tick_phase()   # 相②:未入树窗口的 tick()(2026-09-28)
```

并在文件末尾(`_finish()` 之前或之后皆可)加这个函数:

```gdscript
# ── 相②(2026-09-28):未入树窗口的 `tick()` 不得把权威 `_reloading=false` 冲成 true ──
# 复现 `WeaponComponent._equip_index` 那个窗口:`equip()` 是**同步**的,而 `add_child` 是
# **deferred** 的 ⇒ 入树前 `player` 已非空、`_player_ok()` 为真 ⇒ `tick()` 照跑,
# 而 `mag_ammo` 还是**声明初值 0**(`_ready()` 才置 `mag_size`)⇒ `fire()` 的
# "空弹夹自动换弹"被这个**假前提**触发 ⇒ `start_reload()` 把权威刚写下的 `_reloading = false`
# 冲成 true,并多播一次没按键的 `Sfx.play("reload")`。
# ★ 判据分两截:① **前提**(未入树时 `mag_ammo` 仍是 0 —— 前提不成立时下面是恒绿的空断言);
#   ② **结论**(`_reloading` 仍为 false)。
func _run_pre_tree_tick_phase() -> void:
	var scene: PackedScene = load(WeaponRegistry.scene_of(1))
	if scene == null:
		_check(false, "相② 读不到手枪场景(WeaponRegistry.scene_of(1) 返回了空路径)")
		return
	var w: WeaponBase = scene.instantiate()
	# ★ 顺序与 `_equip_index` 逐字一致:先 `equip()`(同步写好 player)——
	#   本相**刻意不** `add_child`,就是要停在那一个窗口里。
	w.equip(P, 0.0)
	w._reloading = false           # 模拟 `_apply_weapon_state` 刚写下的权威值
	_check(not w.is_inside_tree(),
			"相② 前提:武器确实**不在**树上(否则本相验的不是那个窗口)")
	_check(int(w.mag_ammo) == 0,
			"相② 前提:未入树时 `mag_ammo` 仍是声明初值 0(实得 %d;若已非 0,本相恒绿)"
			% int(w.mag_ammo))
	_apply_attack()                # 按住开火(与 C1 相共用同一个输入源)
	w.tick(1.0 / 60.0)
	_check(not w.is_reloading(),
			"★ 未入树窗口里 `tick()` 把权威 `_reloading=false` 冲成了 true(未按键的假换弹)")
	w.free()                       # 不在树上 ⇒ 必须 free(),queue_free() 不会回收它
	# ★ 收尾复位输入源:本相按下的 attack 若留在 `_held` 里,会让紧接的 C1 相提前打光弹夹,
	#   那一相的"期望 3、实得 4"就变成**假红**。`clear_edges()` **不清 `_held`**,必须用
	#   `reset_state()`。
	(P.input_source as PacketInputSource).reset_state()
```

- [ ] **Step 1.2: 跑它,确认报错失败**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | tail -8
```

Expected: FAIL,判词含
`★ 未入树窗口里 tick() 把权威 _reloading=false 冲成了 true`。
**若这条是绿的** ⇒ 本相没有鉴别力,先停下来查:
① `equip()` 之后 `player` 是否真的非空;② `_apply_attack()` 的包是否落到了 `P.input_source` 上。

- [ ] **Step 1.3: 实现**

`scenes/weapons/weapon_base.gd`,在 `var pending_mag: int = MAG_UNSET`(`:111`)之后加:

```gdscript
# 弹数是否已落定。★ 语义**只有一个**:`_ready()` 已跑过、`mag_ammo` 不再等于声明初值 0。
# ★ 为什么需要它:新武器实例由 `WeaponComponent._equip_index` 用
#   `call_deferred("add_child")` 入树,而那里的 `equip(body, cd)` 是**同步**的 ⇒ 入树前的
#   那个窗口里 `player` 已非空、`tick()` 会照跑,而 `mag_ammo` 仍是 0 ⇒ `fire()` 的
#   "空弹夹自动换弹"被一个假前提触发,把权威的 `_reloading = false` 冲成 true。
# ★ 为什么**不是** `is_inside_tree()` 守卫(那条已被明文否决):它会丢帧,并会把
#   `_auto_aim()` 的朝向一起冻住 ⇒ 那本身造成**真分歧**,比它修掉的问题更坏。
#   这里只让**依赖弹数的那个判断**在弹数未落定前失效,`tick()` 其余部分照跑。
# ★ 别把它用到别的判断上 —— 它只在 `_ready()` 置真一次。
var _mag_ready := false
```

同文件 `_ready()`(`:176`)里,在 `_base_sprite_pos = sprite.position` **之前**加一行:

```gdscript
	_mag_ready = true
```

同文件 `fire()` 的空弹夹分支(`:277`):

```gdscript
	if mag_ammo <= 0:
		# ★ 弹数未落定(未入树窗口)时这里的 0 是**声明初值**,不是"空弹夹" ——
		#   照常起换弹会把权威刚写下的 `_reloading = false` 冲成 true(见 `_mag_ready`)。
		if _mag_ready:
			start_reload()
		return
```

- [ ] **Step 1.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | tail -5
```

Expected: `AMMO ROLLBACK PROBE: ALL-OK(N 条断言)`,`N` 比 Step 0.2 那次**大 3**
(基准那次实测 **3** ⇒ 本步应为 **6**)。★ 不是 4:相② 的函数体里有 4 个 `_check(` 调用点,
但其中一个在 `if scene == null: … return` 早退之后,**正常路径上永远不会跑** ——
按"前提两截 + 结论一截"算是 3。**不要为了凑数补一条断言**(那是加一条 brief 没要求的判据);
反而是本条的读数就该是 3+3=6。
★ 若只大了 2 或更少,说明有断言没跑到 —— 按 `probe_base` 的纪律查。

- [ ] **Step 1.5: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add scenes/weapons/weapon_base.gd tests/ammo_rollback_probe.gd
git commit -F - <<'EOF'
fix(weapon): 未入树窗口的 tick() 不再把权威 _reloading=false 冲成 true

equip() 是同步的、add_child 是 deferred 的 ⇒ 入树前那个窗口里 player 已非空、
tick() 照跑,而 mag_ammo 还是声明初值 0 ⇒ fire() 的「空弹夹自动换弹」被假前提
触发,把 _apply_weapon_state 刚写下的 _reloading=false 冲成 true,并多播一次
没按键的 Sfx.play("reload");活过 reload_time 还会白送一个满弹夹。

修法是 _mag_ready(「弹数已落定」),只让依赖弹数的那个判断失效 ——
tick() 其余部分含 _auto_aim() 一字未动,故不丢帧、不冻朝向
(is_inside_tree() 守卫那条路已被明文否决,理由见注释)。

判据:tests/ammo_rollback_probe 相②(前提两截 + 结论一截 + 输入源复位)。
EOF
```

---

### Task 2: #10 —— 1v1 worker 的报到梯(★ 必须最先落地,peer 在等)

**Files:**
- Modify: `server/server_main.gd`(`_process` 的 if/elif 梯,加第四支)
- Create: `tests/duel_spawn_timeout_smoke.gd`

**Interfaces:**
- Consumes: `WorkerLauncher`(`server/worker_launcher.gd`):`spawn_worker(port, ai_roles := []) -> bool`、
  `log_path(port) -> String`、`kill_worker(port) -> void`;worker 的两行日志
  `"worker 就绪,等待两名玩家……(port %d)"`(`server_main.gd:247`)与本 Task 新增的
  `"worker: 1v1 报到超时(%d/2),退出释放端口"`。
- Produces: 1v1 worker 在「无 claim」30 秒后 `quit(0)` 释放端口。
  **peer 的阶段 3 Task 3 会往同一个 `_process` 里插 `_sync_grace_snapshot()`** ——
  完成本 Task 后立刻通知 peer。

- [ ] **Step 2.1: 写会失败的判据**

创建 `tests/duel_spawn_timeout_smoke.gd`:

```gdscript
extends SceneTree

# 「1v1 worker 在**一个 claim 都没有**时会自己退出」—— 真拉起一个 worker,再读它自己的日志。
# 跑法: source tests/env.sh && timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd
# 通过 = `DUEL SPAWN TIMEOUT SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# `server_main._process` 的报到梯原先只有三支:`_team_mode`(30s 退出)、
# `_royale` 且 ≥2 人(20s 降级开局)、`_royale` 且 <2 人(10s 退出)。
# **纯 1v1 一支都没有** ⇒ 大厅配对完、worker 已拉起,而两个客户端都没 `claim_role`
# (转连失败 / 都在 go_match 后立刻消失)时,worker **永驻**、端口白占到 2h 超龄兜底。
#
# ═══ 三条纪律(与 team_spawn_smoke 同款)═══
# ① 端口必须落在**真大厅的 worker 端口池之外**(池 = 7800 + 500)⇒ 固定用 29015。
# ② **跑前先删日志**:`--log-file` 沿用旧文件会让上一次的"报到超时"行让本跑**假绿**。
# ③ 判成败只看最末那行文本,不数 ERROR、也不看退出码。
#
# ★ **两条断言缺一不可**:`就绪` 证明 worker 本身是健康的(把"开机即崩"与"按梯退出"分开),
#   `报到超时` 才是本项要的行为。少了前者,一个开机就 quit(1) 的 worker 会让后者也失败,
#   而失败原因完全指错方向。
# ★ 30s 的来历(改这里要一起看):客户端侧内建兜底是 **12s 转连 / 25s claim** ⇒ worker
#   必须**晚于**它们退;`RECONNECT` 那套的超时也在这个量级。三处同源,别单独调一个。

const PORT := 29015                      # 池外(池 = 7800..8299)
const READY_MARK := "worker 就绪,等待两名玩家"
const TIMEOUT_MARK := "1v1 报到超时"
const READY_WAIT_MS := 40000             # 冷启动 headless worker + 建世界,给足
const LADDER_WAIT_MS := 60000            # 30s 梯 + 余量


func _initialize() -> void:
	# ★ 空载守卫:load 失败立刻 quit(1),否则后面抛错走不到 quit() → 进程**永久挂起**。
	var L: GDScript = load("res://server/worker_launcher.gd")
	if L == null:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(读不到 worker_launcher.gd)")
		quit(1)
		return
	var launcher = L.new()
	var fails: Array[String] = []
	var log_path: String = launcher.log_path(PORT)

	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)          # 纪律 ②
	if not launcher.spawn_worker(PORT):              # 1v1:无 --royale / --team / --ai-roles
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(1v1 worker 拉起失败)")
		quit(1)
		return

	var ready_text := _wait_for(log_path, READY_MARK, READY_WAIT_MS)
	if not ready_text.contains(READY_MARK):
		fails.append("worker 日志里没有「%s」(等了 %.1fs)—— worker 本身没起来,后面的梯无从谈起。日志尾部:%s"
				% [READY_MARK, READY_WAIT_MS / 1000.0, ready_text.right(400)])
	else:
		var t0 := Time.get_ticks_msec()
		var text := _wait_for(log_path, TIMEOUT_MARK, LADDER_WAIT_MS)
		if not text.contains(TIMEOUT_MARK):
			fails.append("★ 无人 claim 时 worker 没在报到梯上退出(等了 %.1fs;缺「%s」)。"
					% [LADDER_WAIT_MS / 1000.0, TIMEOUT_MARK]
					+ "日志尾部:%s" % text.right(400))
		else:
			print("  [info] 报到梯在就绪后 %.1fs 点火(期望 ≥30s:必须晚于客户端 12s 转连 / 25s claim)"
					% ((Time.get_ticks_msec() - t0) / 1000.0))

	launcher.kill_worker(PORT)
	_finish(fails)


# 轮询日志直到出现 `mark` 或超时;返回**最终**读到的全文(调用方自己判 contains)。
func _wait_for(path: String, mark: String, max_ms: int) -> String:
	var text := ""
	var waited := 0
	while waited < max_ms:
		OS.delay_msec(250)
		waited += 250
		text = _read(path)
		if text.contains(mark):
			break
	return text


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _finish(fails: Array[String]) -> void:
	if fails.is_empty():
		print("DUEL SPAWN TIMEOUT SMOKE: ALL-OK")
		quit(0)
	else:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
```

- [ ] **Step 2.2: 跑它,确认报错失败**

```bash
source tests/env.sh
timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd 2>&1 | tail -8
```

Expected: FAIL,判词含 `★ 无人 claim 时 worker 没在报到梯上退出`(约 100 秒后)。
**若它绿了**,说明 1v1 worker 本来就会退 —— 先查是不是 worker 启动失败了(判词会变成"没有就绪"那一支)。

- [ ] **Step 2.3: 实现**

`server/server_main.gd` 的 `_process` 里,在现有三支梯的**最末一支之后**(即
`elif _royale and not _match_started and _host == null and _claims.size() < 2:` 那一支的 `quit(0)`
之后)加第四支:

```gdscript
	# 1v1:一个 `claim_role` 都没到就干等没有意义 —— 配对**早已在大厅完成**,报到应在秒级到达。
	# 这是三种模式里唯一**原先没有**报到梯的一支:纯 1v1 既不是 `_royale` 也不是 `_team_mode`,
	# 于是前两支都命中不了 ⇒ 两个客户端都在 `go_match` 后消失时 worker 永驻、端口白占到
	# 2h 超龄兜底为止(`_reclaim_finished_matches` 按 worker 进程活性回收,而它一直活着)。
	# ★ 30s 的来历是**承重的**:客户端侧内建兜底是 12s 转连 / 25s claim ⇒ worker 必须
	#   **晚于**它们退,否则客户端还在重试、端口已经没了(把"转连慢"变成"连不上")。
	# ★ 判据是 `not _match_started and _host == null`,故它同时覆盖两种子情形:一个 claim
	#   都没有、以及只到一个(1v1 要 2 人齐才开)。AI 对战单人即可开局,不走这一支。
	# ★ `_understaffed_wait` 是**与上面两支共享**的计时量,别在别处再写它。
	elif not _royale and not _team_mode and not _match_started and _host == null:
		_understaffed_wait += delta
		if _understaffed_wait > 30.0:
			print("worker: 1v1 报到超时(%d/2),退出释放端口" % _claims.size())
			get_tree().quit(0)
```

- [ ] **Step 2.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd 2>&1 | tail -5
```

Expected: `[info] 报到梯在就绪后 ~30.x s 点火` 然后 `DUEL SPAWN TIMEOUT SMOKE: ALL-OK`。

- [ ] **Step 2.5: 确认没有留下僵尸 worker**

```bash
tasklist | grep -i godot || echo "干净"
```

Expected: `干净`。**非空就 `taskkill //PID <pid> //F` 清掉** —— 留下的 worker 会占着池外端口,
毒掉下一跑(症状是"连到上一支的僵尸、一行裁决都不打")。

- [ ] **Step 2.6: 提交,然后立刻通知 peer**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/server_main.gd tests/duel_spawn_timeout_smoke.gd
git commit -F - <<'EOF'
fix(server): 1v1 worker 补上报到梯 —— 无人 claim 时 30s 后退出释放端口

_process 的报到梯原先只有 _team_mode(30s)与 _royale(20s/10s)三支,
纯 1v1 一支都没有 ⇒ 大厅配对完、worker 已拉起,而两个客户端都没 claim_role
时 worker 永驻、端口白占到 2h 超龄兜底(回收梯按 worker 进程活性判,
而它一直活着)。

30s 不是随手取的:客户端内建兜底是 12s 转连 / 25s claim,worker 必须晚于它们退,
否则会把「转连慢」变成「连不上」。判据是 not _match_started and _host == null,
故同时覆盖「一个都没有」与「只到一个」。

判据:tests/duel_spawn_timeout_smoke.gd(真拉起 1v1 worker、池外端口 29015,
两条断言缺一不可:就绪证明 worker 健康 + 报到超时才是本项)。
EOF
git log --oneline -1
```

然后 `SendMessage` 给 `the-cyancular-ruins-71`:「#10 已落(`<commit>`),`_process` 的第四支在链尾,
你可以插 `_sync_grace_snapshot()` 了;`_understaffed_wait` 是共享量,别写它。」

---

### Task 3: #6b —— MATCH_OVER 之后的倒地记账(1v1 + 3v3)

**Files:**
- Create: `tests/late_match_probe.gd`、`tests/late_match_probe.tscn`
- Modify: `server/match_round.gd`(`_match_round_tick` 循环体首)、`server/team_host.gd`(同)

**Interfaces:**
- Consumes: `MatchHost.new(map, {})` / `TeamHost.new(map, {}, {}, [], spawns, teams)`(空 role_peers
  ⇒ 不建玩家、不排 peer、广播静默早退)、`MatchHost.RoundState.PLAYING` / `.MATCH_OVER`、
  `host.players: Dictionary`、`host._stats: Dictionary`、`host._scores: Dictionary`、
  `host._match_round_tick(delta)`、`host.set_physics_process(false)`、
  `CombatFeedback.attribute(victim, shooter)`、`Combat` 节点的 `force_down()`。
- Produces: `tests/late_match_probe.tscn` —— 本 Task 建 ⓐ①② 两相,Task 4 加 ③,Task 5 加 ④⑤。
  共用脚手架(后续 Task 直接复用,不重写):
  `_check(ok, msg)`、`_place(host, role)`、`_down(host, victim, killer)`、
  `_deaths(host, role) -> int`、`_new_host(tag) -> Node`。

- [ ] **Step 3.1: 建探针骨架 + ①② 两相(此时还没有修复)**

创建 `tests/late_match_probe.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/late_match_probe.gd" id="1"]

[node name="LateMatchProbe" type="Node"]
script = ExtResource("1")
```

创建 `tests/late_match_probe.gd`:

```gdscript
extends Node

# 「对局尾段的记账与判胜口径」探针(场景模式;`-s` 做不了 —— 要真建宿主,autoload 在 `-s` 里不存在)。
# 跑法:`"$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn`
# 判据:文本 `LATE MATCH PROBE: ALL-OK`(**不看退出码** —— 场景探针脚本报错时
#       `--quit-after` 到点仍 exit 0,退出码与"跑通了"不可分)。
#
# 收的是用户 2026-09-28 裁定要修的三条「终局/离场之后」的口径:
#   ①② MATCH_OVER 之后倒地**不再进任何记账**(1v1 / 3v3 各一相)
#   ③   3v3 离场者 ACS 的分母 = **掉线那一刻**的局号,不是宽限到点的局号
#   ④⑤  大乱斗 `_match_winner` 的并列候选集(全场 0 杀 + 有人离开 ⇒ 平局,不是幸存者独胜)
#
# ★★ 为什么大乱斗那一处**没有**对应的"MATCH_OVER 后倒地"相:三个模式的倒地边沿是
#    **同一个契约的三份落地**,但**大乱斗那一份的形状本来就不同** —— 它的整支
#    `_match_round_tick` 就是一个 `match _round_state:`,倒地边沿住在 `RoundState.PLAYING`
#    分支里 ⇒ 终局后天然不记账。1v1(`match_round.gd`)与 3v3(`team_host.gd`)那两份把边沿
#    写在 `match` **之前**,故有病。**给没有病的那一处也写一条断言 = 写一条恒绿的摆设**。
#
# 手法照 `tests/death_drop_probe.gd`:真建宿主、**role_peers 传空**(不建玩家、不排 peer、
# 广播静默早退),玩家由本探针自己摆进 `host.players`,宿主自己的物理帧关掉(只手动推状态机)。
# 地图钉死 `factory1v1.cyrm`;出生点显式传(不走任何 shuffle ⇒ 跨进程可复现)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
const TEAM_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65),
		4: Vector2i(133, 64), 5: Vector2i(136, 64), 6: Vector2i(139, 64)}
const ROYALE_SPAWNS := {1: Vector2i(17, 65), 2: Vector2i(20, 65), 3: Vector2i(23, 65)}

var _failures: Array[String] = []


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[lm]   ok   %s" % msg)
	else:
		_failures.append(msg)
		print("[lm]   FAIL %s" % msg)


func _ready() -> void:
	_phase_down_accounting("1v1", [1, 2])
	_phase_down_accounting("3v3", [1, 4])
	if _failures.is_empty():
		print("LATE MATCH PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("LATE MATCH PROBE: FAIL(%d 条)" % _failures.size())
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)


# ── 脚手架(后续 Task 复用)────────────────────────────────────────────────

# 按模式造一具**新**宿主。★ 每相各用一具:`_down_counted` 闩与 `_stats` 都留在宿主上,
# 复用会让后续相直接吃 `continue`(闩已置位)⇒ 断言恒绿。
func _new_host(tag: String) -> Node:
	match tag:
		"1v1":
			return MatchHost.new(MAP, {})
		"3v3":
			return TeamHost.new(MAP, {}, {}, [], TEAM_SPAWNS, TEAMS)
		"royale":
			return RoyaleHost.new(MAP, {}, {}, [], ROYALE_SPAWNS)
	push_error("unknown tag: %s" % tag)
	return null


func _mount(tag: String, roles: Array) -> Node:
	var host: Node = _new_host(tag)
	add_child(host)
	# ★ 关掉宿主自己的 `_physics_process`:本探针只**手动**推一帧状态机。不关的话帧末那一跑
	#   会让快照/复活调度来搅局(与 death_drop_probe / team_host_probe 同款理由)。
	host.set_physics_process(false)
	for r in roles:
		_place(host, int(r))
	return host


func _place(host: Node, role: int) -> Node2D:
	var p: Node2D = (preload("res://scenes/player/player.tscn") as PackedScene).instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	host.players[role] = p
	# ★ 出生点取**宿主自己那张表**(显式传 spawns ⇒ 首局 `_spawn_cell` 返回的就是那格;
	#   `death_drop_probe` 的 3v3 相已证明这条路径可用)。取到无效格时退到 (1,1) ——
	#   本文件的四条口径**都不依赖**玩家站在哪,位置只影响可读性,但 (-1,-1) 会让玩家
	#   落在世界原点、可能压在实心格里。
	var spawn: Vector2i = host._spawn_cell(role)
	if spawn.x < 0 or spawn.y < 0:
		spawn = Vector2i(1, 1)
	var ts: int = GameParameters.TILE_SIZE
	p.global_position = Vector2(float(spawn.x) * ts + ts * 0.5,
			float(spawn.y) * ts + ts * 0.5)
	p.set_physics_process(false)     # 本探针不验玩家物理
	return p


# 制造一次倒地边沿(照 team_host_probe 的 `_down`):写归因 meta → force_down → 推一帧。
func _down(host: Node, victim: int, killer: int) -> void:
	var v: Node2D = host.players[victim]
	if killer == 0:
		v.remove_meta("last_damager")
		v.remove_meta("last_damager_time")
	else:
		CombatFeedback.attribute(v, host.players[killer])
	(v.get_node("Combat") as Node).force_down()
	host._match_round_tick(0.016)


# 逐人表的原始 deaths(缺条目 = 0,与生产 `_stat_entry` 的默认值同口径)。
func _deaths(host: Node, role: int) -> int:
	var s: Dictionary = host._stats.get(int(role), {})
	return int(s.get("deaths", 0))


# ── ①② MATCH_OVER 之后倒地不记账(1v1 / 3v3 各一相)──────────────────────────
func _phase_down_accounting(tag: String, roles: Array) -> void:
	print("[lm] ── %s:MATCH_OVER 之后倒地不记账 ──" % tag)
	var victim: int = int(roles[0])
	var killer: int = int(roles[1])

	# ── 反向对照(必须先有):PLAYING 里**照常**记账 ──
	# 没有这一相,"把整个倒地边沿块删掉"也能让下面那条通过(恒 0 = 恒绿)。
	var h1: Node = _mount(tag, roles)
	h1._round_state = MatchHost.RoundState.PLAYING
	_down(h1, victim, killer)
	_check(_deaths(h1, victim) == 1,
			"[%s] ★ 反向对照:PLAYING 里倒地**照常**记 death(实得 %d;若为 0,说明记账路径根本没接上,"
			% [tag, _deaths(h1, victim)]
			+ "下面那条就是恒绿的摆设)")

	# ── 本项:MATCH_OVER 里倒地**不得**记账 ──
	var h2: Node = _mount(tag, roles)
	h2._round_state = MatchHost.RoundState.MATCH_OVER
	_down(h2, victim, killer)
	_check(_deaths(h2, victim) == 0,
			"[%s] ★ MATCH_OVER 之后倒地**不得**进 `_stats`(实得 deaths=%d;"
			% [tag, _deaths(h2, victim)]
			+ "终局后残留的爆炸致死会走到这条边沿 —— 它会 +1 death、再掉一次武器、并再广播一次带新 mvp 的终局载荷)")
	if tag == "1v1":
		# 1v1 的击杀计分与 deaths 是同一块里的两件事,一并不许动。
		_check(h2._scores.is_empty(),
				"[1v1] ★ MATCH_OVER 之后倒地**不得**给对方加分(实得 _scores=%s)"
				% str(h2._scores))
```

- [ ] **Step 3.2: 刷新导入并跑它,确认报错失败**

```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . --import 2>&1 | tail -3
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -12
```

Expected: `1v1` 与 `3v3` 各 FAIL 一条,判词含
`★ MATCH_OVER 之后倒地**不得**进 _stats`,同时两条 `反向对照` 是 `ok`。
**若反向对照也红**:先查 `_mount` 是否真的把玩家摆进了 `host.players`、`force_down()` 是否生效。
**若两条 `MATCH_OVER` 相本来就是绿的**:说明边沿已被某处状态闸挡住 —— 停下来查,别硬改。

- [ ] **Step 3.3: 实现(两处各加同一道闸)**

`server/match_round.gd` 的 `_match_round_tick`(`:7`),把 `for role in players:` 的循环体首改成:

```gdscript
	for role in players:
		# ★ MATCH_OVER 之后**不再产生任何记账**(终局后残留的爆炸致死仍会把玩家打倒地):
		#   没有这道闸,`deaths` 会 +1、尸体再掉一次武器、并**再广播一次带新 mvp 的终局载荷**。
		#   大乱斗那一支**天然没有这个问题**(它的倒地边沿住在 `RoundState.PLAYING` 分支里,
		#   见 `RoyaleHost._match_round_tick`)—— 两处形状一致是**刻意**的
		#   (三个模式的倒地边沿是**同一个契约的三份落地**),别把这句当成多余而删掉。
		#   ★ 只排除 MATCH_OVER:`ROUND_OVER` 期间倒地照旧入账(既有行为,不在本项里)。
		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
```

`server/team_host.gd` 的 `_match_round_tick`(`:301`)**同样处理**:在 `for role in players:` 之后、
`var p: Node2D = players[role]` 之前插入同一道闸,注释相同
(★ 那里已有一段"与基类同款"的注释,新注释接在它前面即可,不要删掉既有注释)。

- [ ] **Step 3.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -8
```

Expected: `LATE MATCH PROBE: ALL-OK`。

- [ ] **Step 3.5: 回归 —— 倒地掉落那一族没被这道闸误伤**

```bash
source tests/env.sh
timeout 240 "$GODOT" --headless --path . --quit-after 3600 res://tests/death_drop_probe.tscn 2>&1 | tail -5
```

Expected: `DEATH DROP PROBE: ALL-OK`。
★ 这条是**必须**的:那道闸加在循环体首,写错条件(如 `!= PLAYING`)会让 PLAYING 的倒地也不记账
⇒ 死亡掉落整体失效,而 `late_match_probe` 的反向对照**照绿**(它只查 deaths)。

- [ ] **Step 3.6: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/match_round.gd server/team_host.gd tests/late_match_probe.*
git commit -F - <<'EOF'
fix(server): MATCH_OVER 之后倒地不再进 _stats(1v1 + 3v3)

倒地边沿块排在 match _round_state 之前、且不看状态 ⇒ 终局之后残留的爆炸致死
仍会 deaths+1、_drop_all_but_one 再掉一次武器、并再广播一次带新 mvp 的终局载荷。

大乱斗**天然免疫**(它整支 _match_round_tick 就是一个 match,倒地边沿住在
RoundState.PLAYING 分支里),故只修 1v1(match_round.gd)与 3v3(team_host.gd)
两处 —— 三份落地里的两份。只排除 MATCH_OVER,ROUND_OVER 期间照旧入账。

判据:tests/late_match_probe.tscn ①②(每模式两相:PLAYING 反向对照 + MATCH_OVER
本项;两相各用一具新宿主,否则 _down_counted 闩会让第二相恒绿)。
回归:tests/death_drop_probe.tscn 必须仍绿(闸写错条件会让死亡掉落整体失效)。
EOF
```

---

### Task 4: #6a —— 离场者的局数分母

**Files:**
- Modify: `tests/late_match_probe.gd`(加 ③ 相)
- Modify: `server/match_state.gd`(加 `_leave_round` + `note_disconnect_round()`)
- Modify: `server/server_main.gd`(`_enter_grace` 调它)
- Modify: `server/team_host.gd`(`mark_disconnected` 改读它)

**Interfaces:**
- Consumes: `TeamHost._start_next_round()`(`server/match_round.gd:146`,会把 `_round_num += 1`)、
  `MatchState._round_num: int`、`MatchState._rounds_for(role) -> int`(`:227`)、
  `TeamHost.mark_disconnected(role)`(`:362` 附近)、`host._rounds_won`、
  `host._round_state = MatchHost.RoundState.PLAYING`。
- Produces: `MatchState.note_disconnect_round(role: int) -> void` 与 `MatchState._leave_round: Dictionary`。

- [ ] **Step 4.1: 写会失败的判据**

在 `tests/late_match_probe.gd` 的 `_ready()` 里,`_phase_down_accounting("3v3", [1, 4])` **之后**加:

```gdscript
	_phase_disconnect_round()
```

并加这个函数:

```gdscript
# ── ③ 3v3:离场者 ACS 的分母 = **掉线那一刻**的局号 ─────────────────────────────
# 病根:`mark_disconnected` 由 `server_main._expire_graces` 在**宽限期(60s)到点**时调,
# 而它写的是**那一刻**的 `_round_num`。这 60s 若跨过一次换局,离开者的分母就**多算一局**
# ⇒ ACS 被压低,与「已离开者分母更小 ⇒ 更容易胜出」(用户裁定的取向)恰好**相反**。
func _phase_disconnect_round() -> void:
	print("[lm] ── 3v3:离场者的局数分母 = 掉线那一刻 ──")
	# ★ 三个人:1、2 同队、4 敌队 —— 掉 1 之后两队都还有人,不会触发"走光即弃权"那条收场。
	var host: Node = _mount("3v3", [1, 2, 4])
	host._round_state = MatchHost.RoundState.PLAYING
	_check(host._round_num == 1,
			"[仪器] 掉线时局号 == 1(实得 %d)" % host._round_num)

	# 掉线**当场**记一笔 —— 生产里由 `server_main._enter_grace` 调本函数。
	host.note_disconnect_round(1)

	# 宽限期内换了一局(★ 与 team_host_probe 的 `_next_round_clean` 同款:
	#   `_start_next_round` 见到 `_rounds_won` 达标会直接进 MATCH_OVER 并 return)。
	host._rounds_won = {}
	host._start_next_round()
	_check(host._round_num == 2,
			"[仪器] 换局后局号 == 2(实得 %d;若仍是 1,说明 `_start_next_round` 没走到换局那一支,本相白测)"
			% host._round_num)

	# 宽限到期,正式移出
	host.mark_disconnected(1)
	_check(host._rounds_for(1) == 1,
			"★ 离场者的局数分母应是**掉线那一刻**的 1,不是宽限到点的 2(实得 %d)"
			% host._rounds_for(1))
```

- [ ] **Step 4.2: 跑它,确认报错失败**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -8
```

Expected: ③ 相 FAIL,判词 `★ 离场者的局数分母应是掉线那一刻的 1,不是宽限到点的 2(实得 2)`。
★ 若报的是 `Nonexistent function 'note_disconnect_round'`,那是**预期的**
(函数还不存在)—— 但 GDScript 的这类错误只让函数当场结束、不写 `_fail`
⇒ 本题的"红"必须是**上面那条判词**,不是脚本错误。**先把 Step 4.3 的函数签名加上、再重跑一次确认判词**,
否则你验的是一条不存在的断言(本仓登记过的假绿形态)。

- [ ] **Step 4.3: 实现**

`server/match_state.gd`,在 `var _left_round: Dictionary = {}`(`:118`)之后加:

```gdscript
# role -> **掉线那一刻**所处的局号(与 `_left_round` 是两件事:`_left_round` 是**移出**时写下的
# 最终值,本表是掉线当场写下的原值)。★ 为什么必须分开:掉线与"宽限期到点移出"之间隔着
# 整整一个宽限期(60s),这段时间里可能换过局 —— 离开者的 ACS 分母要的是"他实际参与了几局",
# 即**掉线那一刻**的局号,不是宽限到点的。
var _leave_round: Dictionary = {}
```

并在 `_rounds_for` 附近加:

```gdscript
# 记下"这个 role 是在第几局掉线的"。★ 由 `server_main._enter_grace` 在掉线**当场**调用。
# ★ 覆盖写、**不需要**在 reclaim 时清:reclaim 之后若再次掉线,本函数会写上新局号;
#   若不再掉线,`mark_disconnected` 根本不会被调,那条记录是惰性的。
func note_disconnect_round(role: int) -> void:
	_leave_round[int(role)] = _round_num
```

`server/team_host.gd` 的 `mark_disconnected`(`:362`),把那一行

```gdscript
	_left_round[role] = _round_num
```

改成:

```gdscript
	_left_round[role] = int(_leave_round.get(role, _round_num))
```

并在它上方那段注释里补一句:

```gdscript
	# ★ 取**掉线那一刻**的局号(`_leave_round`,由 `_enter_grace` 当场写下),不是宽限到点
	#   这一刻的 —— 两者之间隔着整个宽限期,可能已经换过局。缺省回落 `_round_num`
	#   保证没有任何调用路径会比旧行为**更差**。
```

`server/server_main.gd` 的 `_enter_grace`(`:262`),在 `_grace.enter(role, Time.get_ticks_msec())`
**之后**、`if _host != null:` **之内**(紧跟 `_host._pending_input[role] = []` 那一组):

```gdscript
		# ACS 的分母口径:离开者实际参与了几局 = **掉线这一刻**的局号。
		# ★ 必须在这里记:宽限期有 60s,到点的 `mark_disconnected` 读到的 `_round_num`
		#   可能已经因为换局而 +1(那会让离开者的 ACS 被**压低**,与"分母更小"的取向相反)。
		_host.note_disconnect_round(role)
```

- [ ] **Step 4.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -8
```

Expected: `LATE MATCH PROBE: ALL-OK`。

- [ ] **Step 4.5: 回归 —— 3v3 逐人数据那一族**

```bash
source tests/env.sh
timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | tail -5
```

Expected: `TEAM HOST: ALL-OK`。

- [ ] **Step 4.6: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/match_state.gd server/team_host.gd server/server_main.gd tests/late_match_probe.gd
git commit -F - <<'EOF'
fix(server): 3v3 离场者的局数分母改取「掉线那一刻」的局号

mark_disconnected 由 _expire_graces 在宽限期(60s)到点时调,而它写的是那一刻的
_round_num。这 60s 若跨过一次换局,离开者的分母就多算一局 ⇒ ACS 被压低,
与「已离开者分母更小 ⇒ 更容易胜出」(用户裁定的取向)恰好相反。

修法:MatchState 新增 _leave_round + note_disconnect_round(role),由 _enter_grace
在掉线当场写下;mark_disconnected 读它,缺省回落 _round_num(保证没有任何调用
路径会比旧行为更差)。覆盖写、不需要在 reclaim 时清。

判据:tests/late_match_probe.tscn ③(掉线记 1 → 换局到 2 → 移出,断言分母是 1)。
EOF
```

---

### Task 5: #7 —— 大乱斗 `_match_winner` 的并列候选集

**Files:**
- Modify: `tests/late_match_probe.gd`(加 ④⑤ 两相)
- Modify: `server/royale_host.gd`(`_match_winner` 的候选集)

**Interfaces:**
- Consumes: `RoyaleHost._match_winner() -> int`(`server/royale_host.gd:278`)、
  `RoyaleHost.mark_disconnected(role)`(`:362`)、`RoyaleHost._scores: Dictionary`、
  `RoyaleHost._left: Dictionary`(住在基类 `MatchState`)。
- Produces: 无新接口。

- [ ] **Step 5.1: 写会失败的判据**

在 `tests/late_match_probe.gd` 的 `_ready()` 里,`_phase_disconnect_round()` **之后**加:

```gdscript
	_phase_royale_winner()
```

并加:

```gdscript
# ── ④⑤ 大乱斗:`_match_winner` 的并列候选集 ────────────────────────────────────
# 病根:候选 = `players ∪ _scores`。一个**0 杀**的离开者两边都不在(`mark_disconnected` 把他从
# `players` 里 erase,`_scores` 里也没有他的条目)⇒ 少一个并列候选 ⇒ **全场 0 杀**时
# "多人并列 ⇒ 平局"被**翻转**成幸存者独胜。
# ★ `scenes/royale_game.gd:221` 那道 `and not _match_ended` 门正是为挡这次翻转而立的
#   (它的注释写着「要删先修 `_match_winner`」)—— 但删它不在本批范围(peer 的层 + 需要用户点头)。
func _phase_royale_winner() -> void:
	print("[lm] ── 大乱斗:_match_winner 的并列候选集 ──")
	# ── ④ 全场 0 杀 + **掉到只剩一人** ⇒ 平局 ──
	# ★★ 订正(实现期实测,2026-09-28):本相**照原稿写是修前绿的** ——
	#   3 个 role 掉 **1** 个还剩 **2** 个幸存者,而他们**彼此**已在 0 杀上并列 ⇒ 平局照样被检出
	#   (实测 `实得 0`)。"少一个并列候选"只在**幸存者恰好 1 人**时才翻转结果(平局要有 ≥2 个候选
	#   共享最高分)⇒ 必须掉到只剩一人。那也正是生产里"最后一个对手离开 ⇒ `_finish_match()`"的落点
	#   (`mark_disconnected` 的 `players.size() < 2` 分支)。
	#   ★ 实际落地形状以 `tests/late_match_probe.gd` 为准(它对 [1,2,3] 连掉两个);本段保留原始
	#     意图,避免把"计划里的代码块"当成已经过验证的实现读。
	var h1: Node = _mount("royale", [1, 2, 3])
	h1._round_state = MatchHost.RoundState.PLAYING
	h1.mark_disconnected(2)
	h1.mark_disconnected(3)      # 掉到只剩 role 1 ⇒ 幸存者 1 人
	_check(h1._scores.is_empty(),
			"[仪器] 全场 0 杀(实得 _scores=%s;若非空,下面这条测的就不是「并列」)" % str(h1._scores))
	_check(h1._match_winner() == 0,
			"★ 全场 0 杀 + 只身幸存 ⇒ 平局 0,不是幸存者独胜(实得 %d)" % h1._match_winner())

	# ── ⑤ 反向对照:有分差时仍判分高者 ──
	# 没有它,"恒返回 0"也能让 ④ 通过。
	var h2: Node = _mount("royale", [1, 2, 3])
	h2._round_state = MatchHost.RoundState.PLAYING
	h2._scores[1] = 2
	h2._scores[2] = 1
	h2.mark_disconnected(3)
	_check(h2._match_winner() == 1,
			"★ 反向对照:有分差时判分高者(期望 1,实得 %d)" % h2._match_winner())

	# ── ⑤b 得分者离开后,他的分仍参与比较(既有语义,防被本次改动破坏)──
	var h3: Node = _mount("royale", [1, 2, 3])
	h3._round_state = MatchHost.RoundState.PLAYING
	h3._scores[3] = 5
	h3.mark_disconnected(3)
	_check(h3._match_winner() == 3,
			"★ 离开者**有分**时仍按分判胜(期望 3,实得 %d)" % h3._match_winner())
```

- [ ] **Step 5.2: 跑它,确认报错失败**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -8
```

Expected(★ 已订正,见 Step 5.1 的 ④ 注释):④ 相 FAIL,判词
`★ 全场 0 杀 + 只身幸存 ⇒ 平局 0,不是幸存者独胜`,实得值 = **幸存的那个 role**(修前)。
⑤ 与 ⑤b 应已 `ok`(它们测的是既有语义)。
★ 原稿此处写的"实得值可能是 1 或 3、取决于遍历顺序"是**错的**:3 人掉 1 个的 fixture 修前本就是平局(绿),
所以那一版**根本红不了**。判断此类断言时,先把"平局需要 ≥2 个候选"这条数清楚。

- [ ] **Step 5.3: 实现**

`server/royale_host.gd` 的 `_match_winner`(`:287` 起),在现有两个候选来源之后加第三个:

```gdscript
	var candidates := {}
	for role in players:
		candidates[int(role)] = true
	for role in _scores:
		candidates[int(role)] = true
	# ★ 已移出但对局仍在继续的人(`_left`)也必须进候选:一个 **0 杀**离开者的分数**不在**
	#   `_scores` 里(`mark_disconnected` 又把他从 `players` 里 erase 了)⇒ 他两边都不在,
	#   于是"全场 0 杀 ⇒ 多人并列 ⇒ 平局"会被**翻转**成幸存者独胜。
	#   `_left` 是这种离开者**唯一**的痕迹。
	# ★ 这一条落地后,`scenes/royale_game.gd:221` 那道 `and not _match_ended` 门**失去了理由**
	#   (它正是为挡这次翻转而立的)—— 但删它在 peer 的层、且需要用户点头,本批**不动**。
	for role in _left:
		candidates[int(role)] = true
```

- [ ] **Step 5.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -10
```

Expected: `LATE MATCH PROBE: ALL-OK`(①②③④⑤⑤b 全部通过)。

- [ ] **Step 5.5: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/royale_host.gd tests/late_match_probe.gd
git commit -F - <<'EOF'
fix(server): 大乱斗 _match_winner 的并列候选集补上已离开者

候选原先是 players ∪ _scores。一个 0 杀离开者两边都不在(mark_disconnected
把他从 players 里 erase,_scores 里也没有他的条目)⇒ 少一个并列候选 ⇒
全场 0 杀时「多人并列 ⇒ 平局」被翻转成幸存者独胜。

已逐档推演:只在「剩下的人全 0 杀 + 有 0 杀离开者」这一档改变结果,
其余档逐字不变(离开者有分时本来就在 _scores 里,照旧按分判胜)。

判据:tests/late_match_probe.tscn ④(平局)+ ⑤(有分差仍判高者)+ ⑤b(离开者
有分仍按分判胜)。⑤ 是必需的反向对照 —— 没有它,「恒返回 0」也能过。

★ 连带登记(本批不动):scenes/royale_game.gd:221 的 and not _match_ended 门
因此失去理由,删它在 peer 的层且需用户点头。
EOF
```

---

### Task 6: #8 —— 删掉 `same_team` 的死代码半句

**Files:**
- Modify: `server/match_state.gd`(`_record_down` 的助攻过滤,`:353`)

**Interfaces:**
- Consumes: `same_team(a_role, b_role) -> bool`(`:42`)、`_assist_times`、`ATTRIB_WINDOW`。
- Produces: 无新接口。**本 Task 刻意不新增断言**(见 Step 6.3)。

- [ ] **Step 6.1: 先证明"删它没有断言察觉"(基线)**

```bash
source tests/env.sh
timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | tail -3
```

Expected: `TEAM HOST: ALL-OK`。**记下这条**,Step 6.4 必须还是它。

- [ ] **Step 6.2: 实现(删半句 + 把前提写成注释)**

`server/match_state.gd` 的 `_record_down`,`:353` 那一行:

```gdscript
		if not same_team(attacker, killer_role) or same_team(attacker, victim_role):
```

改成:

```gdscript
		if not same_team(attacker, killer_role):
```

并把上面那两段注释(`:327`–`:344`)整体换成:

```gdscript
	# ── 助攻:表里**除击杀者之外**、且在归因窗口内、且**与击杀者同队**的 attacker ──
	# ★★ 规则只有这**一条**。原先这里还挂着一个 `or same_team(attacker, victim_role)`,
	#   它是**死代码**(2026-09-28 删除):上面那道 `if same_team(killer_role, victim_role): … return`
	#   早退已经保证**击杀者与受害者异队**,而"attacker 是受害者的队友" ⇒ attacker 与 killer
	#   **必定不同队** ⇒ 前半句早已为真 ⇒ 那个 `or` 永远不改变结果。
	# ★★ **删它的前提是"上面那道同队早退还在"** —— 那条前提有**行为面**守卫:
	#   `tests/team_host_probe.gd` 的 (k4)(`_down(_host, 2, 1)`:受害者的**队友**补刀
	#   ⇒ 谁都不记助攻 + 记一次 `team_kills`)。⇒ 删的是**冗余**,不是**守卫**。
	#   哪天要让"队友击杀也算击杀",这道早退会一起改,而那正是本条规则失效的时刻 ——
	#   (k4) 会当场红。
	# ★ 本条**刻意不新增断言**:再加一条"源码里不得出现 `same_team(attacker, victim_role)`"
	#   的文本守卫,恰好是本仓点过名的**失明高发形态**(见 `tests/lib/probe_base.gd` 与
	#   CLAUDE.md 的源码文本守卫条目)。前提已被 (k4) 从**行为**面钉住。
	# ★ 1v1 / 大乱斗:队伍表空 ⇒ `same_team` 恒 false ⇒ **天然拿不到任何助攻**,
	#   不需要特判(守卫:⑬l)。
```

- [ ] **Step 6.3: 自查没有别处读那半句**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
grep -rn "same_team(attacker, victim_role)" server/ scenes/ ui/ tests/ || echo "生产与测试里都没有别处引用"
```

Expected: `生产与测试里都没有别处引用`。
★ 若 `tests/` 里有命中,那是 peer 的文件 —— **先问他**,别自己改。

- [ ] **Step 6.4: 回归 —— 行为面必须逐条不变**

```bash
source tests/env.sh
timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | tail -3
```

Expected: `TEAM HOST: ALL-OK`,**与 Step 6.1 的读数逐字相同**(ok 条数也一样)。
★ 这正是本条的**判据形态**:删的是死代码,所以"绿 → 绿"就是预期结果;
能证明它的是 (k4) 与 ⑬l 的 **ok 行一条不少**。若读数有变,说明删错了东西。

- [ ] **Step 6.5: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/match_state.gd
git commit -F - <<'EOF'
refactor(server): 删掉 _record_down 里的死代码半句(助攻过滤)

`not same_team(attacker, killer_role) or same_team(attacker, victim_role)`
的后半句永不改变结果:上面那道 `if same_team(killer_role, victim_role): … return`
早退已保证击杀者与受害者异队 ⇒ "attacker 是受害者的队友" ⇒ attacker 与 killer
必定不同队 ⇒ 前半句早已为真。

删的是冗余、不是守卫:那条前提有行为面守卫 —— team_host_probe 的 (k4)
(受害者的队友补刀 ⇒ 谁都不记助攻 + 记 team_kills)。注释里写明了这个依赖,
并说明为什么本条**刻意不加**新的源码文本守卫(本仓点过名的失明高发形态)。

回归:team_host_probe 修前修后同为 ALL-OK 且 ok 条数相同 —— 这正是"删的是
死代码"的判据形态。
EOF
```

---

### Task 7: #11 —— royale 在局宽限的 1800s 缺口

**Files:**
- Modify: `server/room_manager.gd`(新常量 + 谓词 + 日志文案)
- Modify: `tests/room_sweep_smoke.gd`(三条断言 + 两处文案)

**Interfaces:**
- Consumes: `server/room_manager.gd:28` 的 `TEAM_MATCH_ESTIMATE`(并列位置)、
  `:408` 的 `in_match_grace` 谓词、`:433` 的清扫日志、`RoyaleHost.MATCH_TIME`;
  `core/config/settings.gd:147` 的装载钳位行;`tests/room_sweep_smoke.gd` 的
  `_check(src)`(源码扫描)与 `CHECK_NAMES` 对账机制。
- Produces: `RoomManager.ROYALE_MATCH_TIME_CEILING := 1800.0`。
  **不新增 `_check_*` 函数** ⇒ `CHECK_NAMES` **不需要**改(这也是一条纪律:
  改了名单就要同步,漏同步会红)。

- [ ] **Step 7.1: 写会失败的判据**

`tests/room_sweep_smoke.gd` 的 `_check()` 里,把这一截(`:398`–`:399`):

```gdscript
	if not pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限缺 RoyaleHost.MATCH_TIME(宽限被删/被写死?)"; return
```

换成:

```gdscript
	# ★ 2026-09-28 改认上界常量:原先这里认 `RoyaleHost.MATCH_TIME`,而它只是**默认值** ——
	#   房主可在建房页把一局配到 15 分钟(装载钳位到 30),于是"等了近 2h 才开局 + 配了长时长"
	#   的房会在**对局中途**被判超龄、连 worker 一起杀掉(缺口最大约 1500s)。
	if not pred.contains("ROYALE_MATCH_TIME_CEILING"):
		_fail = "大乱斗在局宽限缺 ROYALE_MATCH_TIME_CEILING(宽限被删/被改回默认时长?)"; return
	if pred.contains("RoyaleHost.MATCH_TIME"):
		_fail = "大乱斗在局宽限又用回了 RoyaleHost.MATCH_TIME(它只是默认值,不是上界)"; return
```

并在同一个 `_check()` 里(紧接这段之后)加两条:

```gdscript
	# ── 2026-09-28:上界常量本身 + **它的前提**。三条缺一不可 ──
	if not src.contains("const ROYALE_MATCH_TIME_CEILING := 1800.0"):
		_fail = "缺 ROYALE_MATCH_TIME_CEILING=1800(或值被改小了 —— 它必须盖得住装载钳位的上界)"; return
	# ★★ 前提钉在**它住的地方**:上界 1800 = 30 分钟 × 60,而 30 来自 `Settings.royale_match_min`
	#   的**装载钳位**。钳位一放宽(比如到 60 分钟),上面两条**照绿**,而缺口**复现** ——
	#   只有这一条会红。改钳位时回来一起改。
	var settings_src := FileAccess.get_file_as_string("res://core/config/settings.gd")
	if not settings_src.contains("royale_match_min = clampf(float(cf.get_value(\"royale\", \"match_min\", 5.0)), 1.0, 30.0)"):
		_fail = ("★ Settings.royale_match_min 的装载钳位变了 —— ROYALE_MATCH_TIME_CEILING "
				+ "(=30min×60=1800)不再盖得住它,大乱斗在局宽限的缺口复现。改钳位要一起改上界常量。"); return
```

再把文件里两处描述文案改掉:

* `:5` 的 `RoyaleHost.MATCH_TIME` → `ROYALE_MATCH_TIME_CEILING`
* `:14` 那句不动(它讲的是 3v3 的 `TEAM_MATCH_ESTIMATE`)
* `:664` 的 OK 串里 `大乱斗 RoyaleHost.MATCH_TIME` → `大乱斗 ROYALE_MATCH_TIME_CEILING(可证上界)`

- [ ] **Step 7.2: 跑它,确认报错失败**

```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd 2>&1 | tail -6
```

Expected: `SMOKE_ROOM_SWEEP FAIL: ... 大乱斗在局宽限缺 ROYALE_MATCH_TIME_CEILING ...`,退出码 1。

- [ ] **Step 7.3: 实现**

`server/room_manager.gd`,在 `const TEAM_MATCH_ESTIMATE := 1800.0`(`:28`)之后加:

```gdscript
# 大乱斗一局长度的**可证上界**(秒)。来历:`Settings.royale_match_min` 在
# `core/config/settings.gd` 的**装载钳位**是 [1.0, 30.0] 分钟(建房页滑块只到 15,
# 但 settings.cfg 里可以到 30)⇒ 秒数上界 = 30 × 60 = 1800。
# ★ 为什么用**硬上界**而不是"把房主配的时长存到房上":`_player_options()` 是**报到那一刻**
#   才读 `Settings`,而 `royale_create` 是**更早的另一刻**(实测它压根不转发 `match_time`)
#   ⇒ 存下来的是**下界**,缺口照留。硬上界是**保守**的(永不误杀活局),代价只是泄漏的房
#   多留 ~25 分钟(与端口池 500 相比微不足道)。⇒ 保守 + 可证,胜过精确但可错。
# ★★ **跨文件不变量**:钳位一旦放宽到 30 分钟以上,本上界**静默失效**(不再覆盖)。
#   守卫在 `tests/room_sweep_smoke.gd` —— 它会去读 settings.gd 的钳位行,钳位变了就红。
const ROYALE_MATCH_TIME_CEILING := 1800.0
```

同文件 `:408` 的谓词:

```gdscript
		var in_match_grace := (SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING) if rr.in_match else 0.0
```

同文件 `:433` 的日志参数:

```gdscript
			MAX_ROOM_AGE + SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING,
```

同文件 `:428` 上方那两行注释里的 `RoyaleHost.MATCH_TIME` 也一并改成
`ROYALE_MATCH_TIME_CEILING`。**`:390`–`:397` 那段"已知边界(本次不修)"整体删除** ——
本项就是来修它的,留着就是一条与原裁定冲突的墓碑(用户 2026-09-28 明确要求开始修)。

- [ ] **Step 7.4: 跑它,确认变绿**

```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd 2>&1 | tail -4
```

Expected: `SMOKE_ROOM_SWEEP OK: ... (N 项检查全部跑到尾)`,退出码 0。
★ `N` 必须与 Step 7.2 之前**一样**(本 Task 不新增 `_check_*` 函数、不改 `CHECK_NAMES`)。
`N` 变了说明名字对账机制被触发了,回去看 `_finish()` 的判词。

- [ ] **Step 7.5: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add server/room_manager.gd tests/room_sweep_smoke.gd
git commit -F - <<'EOF'
fix(lobby): 大乱斗在局宽限改用可证上界,不再是默认时长

在局宽限原取 SWEEP_INTERVAL + RoyaleHost.MATCH_TIME(300s),而 MATCH_TIME 只是
**默认值** —— 房主可在建房页配到 15 分钟(装载钳位到 30)⇒「等了近 2h 才开局 +
配了长时长」的房会在**对局中途**被判超龄、连 worker 一起杀掉(缺口最大约 1500s)。

改用 ROYALE_MATCH_TIME_CEILING = 1800(= settings.gd 装载钳位 [1,30] 分钟的上界)。
刻意不走「把 match_time 存到房上」:那存的是**下界**(建房与报到是两刻、读的是不同的
Settings 快照),缺口照留。硬上界保守(永不误杀活局),代价只是泄漏的房多留 ~25 分钟。

★ 顺带改三处文案,不改它们就是「日志说谎」而非风格问题:
  · room_manager.gd 清扫日志里打印的界
  · room_sweep_smoke.gd:398 的既有断言(原先要求谓词含 RoyaleHost.MATCH_TIME,
    换常量后它当场红)—— 改认新常量 + 一条反向「不得又用回默认时长」
  · 同文件 :5 与 :664 的描述串
★ 判据新增第三条钉住**前提**:settings.gd 的装载钳位行必须仍是 [1.0, 30.0] ——
  钳位一放宽,前两条照绿而缺口复现,只有它会红。

★ ROYALE_PORT_REUSE_DELAY **不动**:房活到 worker 退出、端口只在 teardown_room
  归还 ⇒ 那三档的计时起点是 worker 退出,已不是「端口会不会被提前复用」的界。
EOF
```

---

### Task 8: 收尾 —— 全量回归 + CLAUDE.md 同步

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: 前七个 Task 的全部改动。
- Produces: 与代码一致的文档;一条可复跑的验收命令清单。

- [ ] **Step 8.1: 全量回归(逐条贴出实际输出,不许只看退出码)**

```bash
source tests/env.sh
echo "=== 1 ammo ===" && timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | tail -3
echo "=== 2 late ===" && timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/late_match_probe.tscn 2>&1 | tail -3
echo "=== 3 death_drop ===" && timeout 240 "$GODOT" --headless --path . --quit-after 3600 res://tests/death_drop_probe.tscn 2>&1 | tail -3
echo "=== 4 team_host ===" && timeout 300 "$GODOT" --headless --path . --quit-after 3600 res://tests/team_host_probe.tscn 2>&1 | tail -3
echo "=== 5 room_sweep ===" && timeout 120 "$GODOT" --headless --path . -s res://tests/room_sweep_smoke.gd 2>&1 | tail -3
echo "=== 6 kh_l5 ===" && timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn 2>&1 | tail -3
echo "=== 7 opponent_left/expire 源码面 ===" && timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/rpc_liveness_probe.tscn 2>&1 | tail -3
echo "=== 8 godot 残留 ===" && (tasklist | grep -i godot || echo "干净")
```

Expected(八行,逐行核对):

```
AMMO ROLLBACK PROBE: ALL-OK(...)
LATE MATCH PROBE: ALL-OK
DEATH DROP PROBE: ALL-OK
TEAM HOST: ALL-OK
SMOKE_ROOM_SWEEP OK: ...
KH L5 PROBE: ALL-OK
RPC LIVENESS PROBE: ALL-OK
干净
```

★ 任何一条红:**先按真失败查一遍**,别归因给"负载重/超时"。
★ `tests/brawl_rollback_probe` **本批不跑**(它扫的是回滚容差那一族,与本批无交集);
真要跑得给 `--quit-after 30000` —— 仓库统一的 3600 对它**不够**,而它的失败形状是
"无裁决行 + exit 0",与真失败**长得一样**。

- [ ] **Step 8.2: 复跑那条真起进程的判据**

```bash
source tests/env.sh
timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd 2>&1 | tail -5
```

Expected: `DUEL SPAWN TIMEOUT SMOKE: ALL-OK`。
★ 值得**再跑一次**(Task 2 已经跑过一次):它是唯一真起独立进程的判据,失败模式
(孤儿 worker 占端口 ⇒ 连到僵尸 ⇒ 挂到外层 timeout、一行裁决都不打)与 headless 单进程探针
**完全不同**,一次绿不能证明它稳。
★ 收尾必查 `tasklist | grep -i godot` 为空 —— 这是本仓点过名的"毒下一跑"来源。

- [ ] **Step 8.3: 同步 `CLAUDE.md`**

逐条把下面这些**登记条目改写成"已修"**并注明 commit(找不到精确段落就用
`grep -n "<关键词>" CLAUDE.md` 定位;每条都要**改写原文**,不许只在旁边加一句):

| 关键词 | 位置 | 改法 |
|---|---|---|
| `未入树的 tick()` | §玩家 的「同窗口的残留(登记,不修)」那一段 | 整段换成"已修(2026-09-28,`_mag_ready`)",并说明为什么**不是** `is_inside_tree()` 守卫 |
| `_left_round 记的是` | §3v3 团队模式 的「两条已知口径边界」 | 第 ① 条改成已修;第 ② 条(MATCH_OVER 之后的倒地)**也一并改成已修**,并写清只排除 MATCH_OVER / ROUND_OVER 照旧 |
| `_match_winner 并列候选集没修` | §结算页 的「已知风险/登记」区 | 改成已修,并保留"那道门因此失去理由,但删它不在本批"这句 |
| `same_team 后半句是死代码` | §3v3 助攻与惩罚 那条 | 改成已删除,并写明"前提由 (k4) 从行为面守卫" |
| `1v1 worker 空转` | §对局中的房 的「代价照实登记」 | 改成已修(第四支报到梯),保留"pid 复用"那条**仍未修** |
| `royale 在局宽限` | §大乱斗 的「已知边界」+ §对局中的房 | 改成已修(`ROYALE_MATCH_TIME_CEILING`),并写明"端口延迟那半已自动闭合、故不改常量" |
| `弹数没有常规纠正路径` | §玩家 | **不动**(C 档,不在本批) |
| `channel 0` / `私密房回局` | 各自位置 | **不动**(不在用户清单里) |

- [ ] **Step 8.4: 校验文档里的每一处引用**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
grep -n "ROYALE_MATCH_TIME_CEILING" CLAUDE.md server/room_manager.gd tests/room_sweep_smoke.gd
grep -n "_mag_ready" CLAUDE.md scenes/weapons/weapon_base.gd tests/ammo_rollback_probe.gd
grep -n "note_disconnect_round" CLAUDE.md server/match_state.gd server/server_main.gd server/team_host.gd
grep -n "late_match_probe\|duel_spawn_timeout_smoke" CLAUDE.md
```

Expected: 每个新符号在**生产/判据**里都出现,且 `CLAUDE.md` 里提到它们的位置与上面的表一致。
★ 这一条防的是"文档写了、代码里没有"与反向的"代码写了、文档漏了"。

- [ ] **Step 8.5: 提交**

```bash
cd /e/Workspace/godot/the-cyancular-ruins
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): B 档六条「登记边界」销账

用户 2026-09-28 裁定开始修此前登记为「已知边界/登记不修」的那批。本批销掉六条:
  · 未入树的 tick() 把权威 _reloading 冲成 true  → _mag_ready
  · _left_round 记「宽限到点」而非「断开时刻」   → note_disconnect_round
  · MATCH_OVER 之后倒地仍进 _stats(1v1 + 3v3)   → 状态闸
  · _match_winner 的并列候选集                   → 候选并上 _left
  · same_team 的死代码半句                       → 删除
  · 1v1 worker 没有报到梯                        → _process 第四支
  · royale 在局宽限的 ~1500s 缺口                → ROYALE_MATCH_TIME_CEILING

**不动**:弹数纠正路径(C 档)、channel 0 与私密房回局(不在清单里)、
royale_game.gd:221 那道门(peer 的层 + 需用户点头)、ROYALE_PORT_REUSE_DELAY。
EOF
git log --oneline -9
```

---

## Self-Review

**1. Spec coverage** —— spec §2 的七条(`#2 / #6a / #6b / #7 / #8 / #10 / #11`)逐个对应:

| spec 条目 | Task |
|---|---|
| #2 | Task 1 |
| #10 | Task 2 |
| #6b | Task 3 |
| #6a | Task 4 |
| #7 | Task 5 |
| #8 | Task 6 |
| #11 | Task 7 |
| §5 风险 1(反向对照)| Task 3 Step 3.3 的消息 + Step 3.5 的 death_drop 回归 |
| §5 风险 2(30s 耦合)| Task 2 Step 2.3 的注释 + Step 2.1 的 `[info]` 读数 |
| §5 风险 3(钳位前提)| Task 7 Step 7.1 第三条断言 |
| §5 风险 4(`_mag_ready` 语义)| Task 1 Step 1.3 的注释 |
| §4 判据落点表 | Task 1/3/5/7(既有两个文件 + 新两个文件),`team_match_*` 与 `royale_c2_probe*` 零触碰 |

**2. Placeholder scan** —— 无 TBD/TODO;每个改代码的步骤都给了**完整代码块**;
每条判词都是**逐字**的期望文本。

**3. Type consistency** —— 跨 Task 复用的符号逐一对过:

* `_check(ok: bool, msg: String)` —— Task 3 定义,Task 4/5 复用 ✔
* `_place(host, role) -> Node2D` / `_down(host, victim, killer)` / `_deaths(host, role) -> int` /
  `_mount(tag, roles)` / `_new_host(tag) -> Node` —— Task 3 定义,Task 4/5 复用 ✔
* `_mag_ready`(Task 1)/ `note_disconnect_round`(Task 4)/ `ROYALE_MATCH_TIME_CEILING`(Task 7)——
  生产与判据两侧的**拼写逐个核对过**(Step 8.4 的 grep 就是这一步的机械守卫)✔
* `MatchHost.RoundState.PLAYING` / `.MATCH_OVER` —— 与 `death_drop_probe.gd:101` 的实际用法一致 ✔
* `RoyaleHost._match_winner()`(私有名,`royale_host.gd:278`)/ `RoyaleHost.new(MAP, {}, {}, [], spawns)`
  —— 与 `death_drop_probe.gd:64` 一致 ✔
