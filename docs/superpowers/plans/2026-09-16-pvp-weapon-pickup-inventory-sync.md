# 局内拾取/丢枪：权威背包不下发到客户端（根因 + 修法）

2026-09-16。**这份接在 `2026-09-16-pvp-weapon-crash-probe-plan.md` 后面。**
那份的边界写得很清楚：「只造复现框架，**不含成因结论**」。这份给的是**已经跑出来的读数**
与**一个已确证的成因** —— 但只覆盖"背包不下发"这一条，**崩溃本身仍未复现**（见 §3.2）。

## 0. 两份文档的关系

| | 那份（crash-probe-plan） | 这份 |
|---|---|---|
| 目标 | 把"没有堆栈、没有复现步骤"变成能确定性触发的红灯 | 记录探针**已经**跑出来的结论，并给出修法 |
| 状态 | §5 的 5 条都是**待验证假设** | §5 的第 1 条已被证实并**改写**（见 §2.3） |
| 产物 | 探针设计 + 分层（L1–L6） | 已落地的探针（§1）+ 根因（§2）+ 修法任务（§5） |

**不要**把这份当成"那份的替代"：那份 §2.1/§2.2 的场景矩阵（10 个动作 × 6 类时机 × 3 条通道）
仍然没跑完，仍然要做。

---

## 1. 已经落地的探针

| 文件 | 层 | 覆盖 | 现状 |
|---|---|---|---|
| `tests/ground_action_probe.tscn` | 服务器权威侧（无网络） | 捡 / 替换 / 丢 / 自身冷却 / 40 轮连打 / 复活掉枪 | **ALL-OK** |
| `tests/ground_client_probe.tscn` | 客户端侧（无网络） | `weapon_removed` 删节点、权威背包变化后 `restore_inventory`+`equip`、60 轮交替 | **ALL-OK** |
| `tests/ground_net_probe.tscn` + `ground_net_watcher.gd` + `ground_bot_input.gd` | **L1**（真大厅 + 真 worker + 2 个真 `royale_game`） | 机器人走「长按 Q 丢 → 走过去 → 按 F 捡」循环，判据是**真事件**（`weapon_spawned`/`weapon_removed`）而不是"没报错" | 跑得通，**当前判 FAIL**（判据本身就是红灯，见 §2.2） |
| `tests/menu_autotest.gd` 新增 `--autotest-ground/<场景名>` | 工具 | 让探针能跑在**导出 exe** 上 | 已就位 |

**本批附带完成（与 §5 的三个任务独立，已落地）**：`ui/hud.gd` 的左下角容量格子不再贴一个
写死的 y，改为跟武器面板的**实际**顶边（`_weapon_wrap.position.y - WEAPON_SLOTS_GAP`，
由 `wrap.resized` 跟随 —— 面板高度是随内容收缩的，写死会在"只带一把枪"时飘在半空）。
守卫是 `level0_weapon_scatter_probe` 新增的 `_phase_slot_placement()`：1/2/3/4 把枪各测一遍，
断言"不压面板 + 间隙恒定 8px + 留在画面内"（实测 y = 1254/1204/1154/1104）。

跑法：

```bash
# 服务器侧 / 客户端侧（各自自足，秒级）
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn

# 真链路（跑前先确认 7777 空闲）—— ★ `--test-ground-teleport` 要带上，见 §1.2
"$GODOT" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport
"$GODOT" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport --render
```

**现状**：`PROBE: ALL-OK`（两端 `丢=8 捡=10 轮=4 地面=8 背包=2`）。

### 1.2 仅测试用的服务器入口：`--test-ground-teleport`

**为什么加**：探针要真客户端在真对局里反复捡/丢，而拾取判定在服务器侧、按 64px 半径走。
让机器人**自己走过去**需要寻路 —— 实测两轮都没跑满轮数：只会"水平走 + 卡住跳"的机器人在
窄台上会永久卡死，而且地图是**每进程随机选一份 `.cyrm`**，时好时坏。加了这个开关就完全
不用走位。

**它做什么**（`MatchGround._debug_keep_weapon_within_reach`，由 `MatchHost._physics_process`
每帧调）：给每个站着、且脚下 64px 内**没有捡得动的**武器的玩家，把场上最近的一把挪到他脚下。
判据用的是 `weapon_pickup_radius` **本身**，且排除 `_live_self_drops`（他自己刚丢下、冷却中的
那些）—— 否则喂到脚下的可能正是被排除的那把，探针看着"枪在脚边却捡不起来"，而服务器完全正确。

**怎么 gate 的**（生产路径不可达）：
`static var test_ground_teleport := false`（默认关）→ `server_main.gd` 解析 worker 的
`--test-ground-teleport` → `worker_launcher.spawn_royale_worker` 只在**大厅自己也带了**这个
开关时才往 worker 传。所以真实大厅/真实对局里它永远是 false。
★ 开关**必须写在 `--` 之后**（`worker_launcher` 读 `OS.get_cmdline_user_args()`；写在前面会被
Godot 丢掉、静默失效 —— 与 `--worker` 同一个坑）。

**它的代价（探针里的已知边界）**：客户端**不知道**那把枪被服务器挪过，它本地那份模拟位置是旧的
→ 那件武器的**视觉位置**在客户端是错的。探针不依赖它（改走"站着按 F"），但别拿这个模式的截图
去验收画面。

### 1.1 关于"在发布产物上跑探针"

导出 exe 的裁剪模板编译时带了 `disable_path_overrides=yes`，所以 `<exe> res://x.tscn`
会被引擎**当场拒绝**：

```
ERROR: Scene path was specified on the command line, but this Godot binary was compiled
       without support for path overrides. Aborting.
```

想在**发布产物**上跑探针，只能借主菜单那条既有通道（`main_menu.gd` 读
`OS.get_cmdline_user_args()`，不受 path override 限制，且 `tests/` 已在
`export_filter="all_resources"` 里）：

```bash
"./The Cyancular Ruins.exe" --headless --log-file _probe.log -- --autotest-ground/ground_client_probe
```

★ 客户端 exe 是 GUI 子系统，**stdout 回不到终端**，`--log-file` 不能省。

---

## 2. 根因：权威背包只在"发生回滚"时才到客户端

### 2.1 代码路径

`core/net/prediction_rollback.gd`：

```gdscript
func _handle_ack(ack: int, S: Dictionary) -> void:
	...
	var predicted: Dictionary = _captures[ack]
	if _close_enough(predicted, S):
		_trim(ack)          # ←── 预测被证实：只修剪，**不应用权威态**
		return
	_rollbacks += 1
	_p.restore_state(S)     # ←── 全项目唯一一处应用权威态的地方
```

而 `_close_enough` 是**显式白名单**，只比 `down` / `hp` / `pos` / `vel`：

```gdscript
func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	if a.get("down", false) != b.get("down", false): return false
	if int(a.get("hp", 0)) != int(b.get("hp", 0)): return false
	if _pos_dist(...) > pos_tol: return false
	return va.distance_to(vb) < 20.0
```

`inv` / `wslot` / `mag` / `rld` **刻意不在内** —— 这条纪律本身是对的（CLAUDE.md 已记：
加了就会每帧判分歧 → 无限回滚循环）。

**但它推不出"背包自然会同步"**：`restore_state` 是 `restore_inventory` 的**唯一**调用者
（`grep -rn "restore_inventory\|restore_state(" --include=*.gd .` 验证），于是

> **只要本地预测与权威逐位一致，客户端就永远不会应用权威背包。**

而 C2 的常态恰恰是"逐位一致"——两点之间没有外部事件时，客户端重放出的状态与服务器**就是**
同一个模拟结果。

### 2.2 实测证据（`ground_net_probe`，一局 90s）

心跳每 5s 一行（`ground_net_watcher.gd` 的 `_debug_step`）：

```
♥ t=10 相=1 本地背包=0 槽=0 我丢=1 我捡=0 全场丢=2 捡=0 地面=12
        rb=last=427 ack=423 caps=4 seqs=4 pend=0 rollback=0
♥ t=30 相=1 本地背包=0 槽=0 我丢=1 我捡=0 全场丢=2 捡=0 地面=12
        rb=last=1631 ack=1625 caps=6 seqs=6 pend=1 rollback=0
```

三行一起读才有意义：

- `ack=423 caps=4` → **ak 在 ring 里有对应的整态**，不是"没有 capture 所以跳过"；
- `pend=0..2` → 权威快照在被正常消费，链路是活的；
- `rollback=0` → `_close_enough` 每次都返回 true → **`restore_state` 一次都没跑**；
- `本地背包=0 槽=0` → 客户端手上**始终没枪**；
- 同一时刻 `我丢=1`（且日志里有 `丢弃成功(weapon_spawned 已到,inst=14)`）
  → **服务器那边丢弃/拾取全都成功了**。

即：**服务器认得出你捡了枪，客户端不知道。** 两层探针分开测时都是绿的，因为
`ground_client_probe` 是**直接调** `restore_state` 的 —— 它绕过了"什么时候会调"这一问。

### 2.3 与那份 plan §5 的关系

那份的假设 1 是「`restore_state` 里的 `equip()` 会 `queue_free` 当前武器，而刚被释放的那把
仍可能被别处引用 —— **先查这里**」。本次实测把它的前半段**改写**了：

> 真正的第一条不是"`restore_state` 被频繁调用"，而是**它根本不被调用**。
> 结论相同（问题就在 `inv`/`wslot` 这条线上），但方向相反：`restore_state` 是**低频**的，
> 低频不等于安全 —— 它意味着"背包突变"这种事在客户端**长期不落地**，而一旦落地就是一次
> 大跳变（从 0 把直接跳到 4 把）。

---

## 3. 它解释了哪些现象 / 没解释哪些

### 3.1 解释了

- **为什么只在 1v1 和大乱斗里**：单机没有快照下行、没有 C2 回滚，`Level0.try_pickup_for`
  就地改背包，客户端即权威。（单机那条路有 `level0_weapon_scatter_probe` 钉着，一直是绿的。）
- **为什么"捡起来像没捡"**：服务器发的事件把**地上的枪**收走了（客户端 `_remove_pickup_node`
  正常删节点），但**背包没变** → 手上还是原来那把（或空手）。表现就是"枪没了、手上也没多"。
- **为什么时好时坏**：一旦发生任何**外部事件**（被打掉血、被击退、复活瞬移），
  `_close_enough` 立刻为假 → 回滚 → 那一瞬间背包**全量**补上。所以是"有时候能捡到"。

### 3.2 没解释（**仍然悬着**）

- **硬崩溃没有复现。** 三个探针（含 `-- --render` 真渲染档）跑完整局都不崩。
  用户那次（`user://logs/godot2026-09-16T22.18.41.log`）的进程是 **`custom_build`（导出 exe）**，
  日志停在 `进入大乱斗:角色 3 出生点 (140, 10)` 之后，末行：

  ```
  ERROR: Trying to call an RPC while no multiplayer peer is active.
     at: rpcp (modules/multiplayer/scene_rpc_interface.cpp:475)
  ```

  同一条 ERROR 在探针里**复现到了**（掉线后 `pvp_match_client.gd:113` 继续 `send_input`），
  但进程活着继续跑。所以它**不必然是**崩溃原因。
  → 下一步应把 `ground_net_probe` 挪到**导出 exe** 上跑（§1.1 的通道已经打通）。
- 那份 plan §5 的假设 2/3/4/5 本次**一个字都没验**，原样有效。

---

## 4. 修法设计

### 4.1 做法

**在"预测被证实"那一支，补一次"只同步、不重放"的软回灌。**

理由：`_close_enough` 证实的是**被预测的那几个量**；`inv`/`wslot` 是**非预测字段**
（拾取/丢弃/复活/换局全由服务器裁决，客户端从不预测它们），两者之间没有蕴含关系。

### 4.2 取舍（为什么不选别的）

| 备选 | 为什么不选 |
|---|---|
| 把 `inv`/`wslot` 加进 `_close_enough` | **明确违反既有纪律**（CLAUDE.md 记着：加了就每帧判分歧 → 无限回滚）。而且"背包不同"根本不该触发重放 —— 重放的是**输入**，背包不是输入推出来的 |
| 每个 ack 无脑 `restore_state(S)` | 同样是把权威位置强写进正在预测的玩家 = 橡皮筋；还会每个 ack 跑一次重放 |
| 让服务器再推一条 `inventory_changed` 事件 | 多一条投递路径，且**与快照竞争**（事件可能先于/晚于快照到达，客户端要处理乱序）。快照里本来就有 `inv`，白放着不用 |
| 什么都不做，靠回滚兜住 | 就是今天的行为：静默失效 |

### 4.3 频率与代价（**这条决定了实现细节**）

`sync_soft_state` 会被每个 ack 调一次（~60Hz）。所以：

- **必须先比指纹再动手。** `WeaponComponent.restore_inventory` 结尾会 `inventory_changed.emit()`
  → `ui/hud.gd::_refresh_weapon_boxes()` **整体重建武器框**（新建/销毁一堆 Control）。
  无脑调 = 每帧重建一次 HUD。
- **指纹只比结构（`type`/`inst` 的有序对），不比 `mag`。** `mag` 是连续量、本地每帧都在变，
  比它等于每帧都"不一致"，守卫当场失效。
- 结构一致且 `wslot` 相同时**直接返回**，一个字节都不动。

---

## 5. 任务

> 纪律：**先红后绿**。每个任务都先写出会红的判据、跑一遍看到红，再动生产代码。
> 测试**由用户自己跑**（本仓约定）—— 下面的命令是给实现者的，不是让 agent 代跑。

### Task 1：把"背包变化必须落地"变成红灯

**Files:**
- Modify: `tests/pvp_reconcile_smoke.gd`

**Interfaces:**
- Consumes: 现有的 `A`（权威孪生）、`P`（被预测玩家）—— 两者都是**真 `Player.tscn`**，已带真
  `WeaponComponent`；现有的 `ctrl`（`PredictionRollback`，已 `bind(P)`）、`_a_hist`（tick→A 整态）、
  `_tick`、`_violation`/`_assert_state(t)`/`_finish()`；`A`/`P` 都 `set_physics_process(false)`，
  由冒烟逐帧驱动。
- Produces: `_assert_inventory_landed()`、`INV_EVENT_TICK`/`INV_TYPE` 常量、
  `_inv_event_fired` / `_rb_before_inv` / `_rb_after_inv` 变量。

- [ ] **Step 1：给两边同一个起始背包**

`_ready()` 里 `ctrl.bind(P)` 之后加：

```gdscript
	# 两边给同一个起始背包:否则"事件后两边不一致"这条判据分不清是事件造成的还是开局就有的。
	# (player.tscn 自身 _ready 给的是空背包 —— 见 CLAUDE.md「服务器玩家必须有枪」那一段)
	A.weapons.set_initial_inventory([1])
	P.weapons.set_initial_inventory([1])
```

- [ ] **Step 2：加一个"只改背包、不动位置"的服务器事件**

常量区（`EVENT_TICK` 旁）加：

```gdscript
# 只改背包、**不动位置**的服务器外部事件:权威孪生给自己发一把枪。
# ★ 与 EVENT_TICK 那次瞬移刻意分开:那次改的是**被预测的量**(位置)→ 今天就会回滚、会收敛;
#   这次改的 inv/wslot 是**非预测字段** → 今天既不回滚、也不落地 —— 这条正是要钉的洞。
const INV_EVENT_TICK := 320
const INV_TYPE := 3          # 重狙(任意一个与开局不同的类型即可)
```

变量区加：

```gdscript
var _inv_event_fired := false
var _rb_before_inv := 0
var _rb_after_inv := 0
```

`_physics_process` 里，紧跟现有 `if t == EVENT_TICK:` 那一块**之后**加：

```gdscript
	if t == INV_EVENT_TICK:
		# 直接改权威孪生的背包(等价于服务器 `MatchGround._try_server_pickup` 的成效):
		# 位置/速度/血量一律不动,唯一的变化就是背包。
		A.weapons.set_initial_inventory([1, INV_TYPE])
		_inv_event_fired = true
		_rb_before_inv = ctrl.rollback_count()
	elif t > INV_EVENT_TICK + DELAY + 5:
		_rb_after_inv = ctrl.rollback_count()
```

- [ ] **Step 3：写断言（此刻必须是红的）**

在 `_assert_state(t)` 的**末尾**加一行 `_assert_inventory_landed()`（放 `_physics_process`
里会漏掉"`_violation` 已被置位后提前返回"那条早退），函数体：

```gdscript
# ★ 判据是"预测侧的背包与权威**逐条一致**",不是"预测侧背包非空" ——
#   非空可能只是它自己开局那把还在,证明不了"权威那把到了"。
func _assert_inventory_landed() -> void:
	if not _inv_event_fired:
		return
	var want: Array = A.weapons.inventory.snapshot()
	var got: Array = P.weapons.inventory.snapshot()
	if want.size() != got.size():
		_violation = "背包没落地:权威 %d 把,预测 %d 把(非预测字段在'预测被证实'那一支被跳过了)" % [
				want.size(), got.size()]
		return
	for i in want.size():
		# 只比 (type, inst):mag 是连续量、两边每帧都在各自演化,比它会把这条判据变成噪声源。
		if int(want[i]["type"]) != int(got[i]["type"]) \
				or int(want[i]["inst"]) != int(got[i]["inst"]):
			_violation = "背包内容不一致:权威 %s,预测 %s" % [str(want), str(got)]
			return
	if int(P.weapons.current_slot_int()) != int(A.weapons.current_slot_int()):
		_violation = "手持槽位没落地:权威 %d,预测 %d" % [
				A.weapons.current_slot_int(), P.weapons.current_slot_int()]
		return
	# ★ 反向断言:这条修复**不得**引入新的回滚 —— 它买的是"零回滚也能同步",
	#   不是"多回滚几次"。撤掉 Task 2 的改动这条会红在上面那条,而不是这条。
	if _rb_after_inv > _rb_before_inv:
		_violation = "背包同步引入了额外回滚(%d → %d)—— 那是把它塞进 _close_enough 的写法" % [
				_rb_before_inv, _rb_after_inv]
```

- [ ] **Step 4：跑，确认红**

```bash
"$GODOT" --headless --path . res://tests/pvp_reconcile_smoke.tscn
```
Expected: `SMOKE_RECONCILE FAIL: 背包没落地:...`（**不是** OK、也不是 `外部事件未触发 rollback`）。

- [ ] **Step 5：提交**

```bash
git add tests/pvp_reconcile_smoke.gd
git commit -m "test(c2): 钉住"权威背包变化必须在零回滚下也落地"(当前红)"
```

### Task 2：在"预测被证实"那一支补软回灌

**Files:**
- Modify: `core/net/prediction_rollback.gd:125-127`
- Modify: `scenes/player/player.gd:535-553`

**Interfaces:**
- Consumes: Task 1 的判据；`Player.restore_state(st)` 里那段武器回灌（将被抽出）。
- Produces: `Player.sync_soft_state(st: Dictionary) -> void`（新公开口）、
  `Player._apply_weapon_state(st: Dictionary) -> void`（私有共用）、
  `Player._inv_structure_equal(want: Array) -> bool`（私有守卫）。

- [ ] **Step 1：先把武器回灌抽成共用函数（纯重构，不改行为）**

把 `scenes/player/player.gd::restore_state` 里从注释
`# 武器:先重建**背包**,再按 wslot 切枪。` 到 `w._reload_t = ...` 的整段**原样剪出**，
成为：

```gdscript
# 武器/弹药的权威字段回灌(restore_state 与 sync_soft_state 共用)。
# ★ 顺序不可反:先读 wslot(此时 _current_slot 还有值,可作默认),再 restore_inventory
#   (它会把 _current_slot 清 0),最后 equip。反过来的话——先 restore,wslot 的默认值
#   就丢了;先 equip 再 restore,则 equip 是在**旧背包**上工作(凭空造枪/丢枪)。
func _apply_weapon_state(st: Dictionary) -> void:
	var wslot := int(st.get("wslot", weapons._current_slot))
	weapons.restore_inventory(st.get("inv", []))
	if wslot > 0 and wslot != weapons._current_slot:
		weapons.equip(str(wslot))
	var w: WeaponBase = weapons._weapon
	if w != null:
		w.fire_cd_timer = float(st.get("fire_cd", w.fire_cd_timer))
		w._aiming = bool(st.get("aiming", w._aiming))
		w._fire_buffered = bool(st.get("fire_buf", w._fire_buffered))
		w._aim_facing = int(st.get("aim_f", w._aim_facing))
		w._current_aim_facing = int(st.get("aim_cf", w._current_aim_facing))
		w.mag_ammo = int(st.get("mag", w.mag_ammo))
		w._reloading = bool(st.get("rld", w._reloading))
		w._reload_t = float(st.get("rld_t", w._reload_t))
```

`restore_state` 里那一整段替换成一行 `_apply_weapon_state(st)`。
（★ 剪的时候注意别把夹在注释与代码之间的 `var` 一起吞掉 —— 本仓踩过。）

- [ ] **Step 2：加软回灌口**

```gdscript
# ── 非预测字段的"软同步"(拾取/丢弃/复活/换局改的就是这些)──
# ★ 与 restore_state 的分工:那个是"整态覆盖 + 让调用方重放未确认输入",用在**真分歧**上;
#   这个**只补字段、不重放** —— 位置/速度是预测出来的,拿权威覆盖它们才是橡皮筋,
#   而背包/残弹**不是预测出来的**,它们只由服务器裁决。
# ★ 由 PredictionRollback 在"预测被证实"那一支调用(每个 ack 一次,~60Hz),
#   所以**先比指纹再动手**:restore_inventory 会 emit inventory_changed →
#   ui/hud.gd 整体重建武器框,无脑调 = 每帧新建/销毁一堆 Control。
func sync_soft_state(st: Dictionary) -> void:
	if int(st.get("wslot", weapons._current_slot)) == weapons._current_slot \
			and _inv_structure_equal(st.get("inv", [])):
		return
	_apply_weapon_state(st)


# 只比**结构**(type/inst 的有序对):mag 是连续量、本地每帧都在变,比它等于每帧都"不一致",
# 守卫当场失效(而且那正是"不该拿连续量判分歧"的同一条纪律)。
func _inv_structure_equal(want: Array) -> bool:
	var held: Array = weapons.inventory.held
	if held.size() != want.size():
		return false
	for i in held.size():
		if int(held[i]["type"]) != int(want[i].get("type", 0)):
			return false
		if int(held[i]["inst"]) != int(want[i].get("inst", 0)):
			return false
	return true
```

- [ ] **Step 3：在控制器里接上**

`core/net/prediction_rollback.gd`：

```gdscript
	if _close_enough(predicted, S):
		# ★ "预测被证实"只说明 down/hp/pos/vel 对得上。背包(inv/wslot)与残弹是
		#   **非预测字段** —— 拾取/丢弃/复活/换局全由服务器裁决,客户端从不预测它们,
		#   两者之间没有蕴含关系。不在这里补一次,客户端就只会在**碰巧发生回滚**时
		#   (被打/复活/瞬移)才看见自己捡了枪 —— 表现为"捡起来的枪不在手上、开不了火",
		#   而且一条报错都没有。实测:整局 90s `rollback_count()==0`、`本地背包=0`。
		# ★ has_method 守卫:`PredictionRollback` 是纯逻辑件,冒烟里配的是桩对象。
		if _p.has_method("sync_soft_state"):
			_p.sync_soft_state(S)
		_trim(ack)
		return
```

- [ ] **Step 4：跑，确认绿**

```bash
"$GODOT" --headless --path . res://tests/pvp_reconcile_smoke.tscn
```
Expected: `SMOKE_RECONCILE OK: ...`（且回滚计数与改动前**同量级** —— 反向断言在 Task 1 Step 3 里钉着）。

- [ ] **Step 5：跑既有回归，确认没打破别的**

```bash
"$GODOT" --headless --path . res://tests/pvp_twin_smoke.tscn
"$GODOT" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn
```
Expected: 前者 `OK`；后者 `PROBE: ALL-OK`（**这就是 §2.2 那条红灯转绿的时刻**）。

- [ ] **Step 6：提交**

```bash
git add core/net/prediction_rollback.gd scenes/player/player.gd
git commit -m "fix(c2): 预测被证实时也回灌权威背包(拾取/丢弃在客户端不再静默失效)"
```

### Task 3：堵掉软回灌让"幽灵枪"变得可达的那条路

**为什么必须有这一步**：软回灌之后，`restore_inventory` 的"清空手持"分支**每个 ack 都可能走到**
（服务器说空手，例如你把自己最后一把丢了）。而那条分支现在只清索引、**不释放武器实例**：

```gdscript
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()      # ← _weapon 还活着
```

`WeaponBase.tick()` / `fire()` 只看 `_player_ok()`（= `player != null and not downed`），
**不看索引** → 手上会留一把"索引 -1 但仍能开火"的幽灵枪。改动前它很难走到（要等一次回滚），
改动后是常路。

**Files:**
- Modify: `scenes/player/weapon_component.gd:358-361`
- Test: `tests/ground_client_probe.gd`

**Interfaces:**
- Consumes: `WeaponComponent.restore_inventory(entries: Array)`（既有）。
- Produces: 收尾语义变化 —— 走"清空"分支后 `current_weapon()` 必为 `null`。

- [ ] **Step 1：写会红的断言**

`tests/ground_client_probe.gd` 的 `_phase_authoritative_inventory_change()` 末尾（现有那句
`_local.restore_state({"wslot": 0, "inv": []})` 之后、`is_instance_valid(_local)` 之前）加：

```gdscript
	# ★ 权威说"空手"时不能只清索引:那把枪的实例还在,而 tick/fire 只看 _player_ok、
	#   不看索引 —— 于是手上留着一把**开得了火的幽灵枪**。
	_check(w.current_weapon() == null,
			"权威空手后不得留有可开火的武器实例(实际 %s)" % str(w.current_weapon()))
```

- [ ] **Step 2：跑，确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
```
Expected: `✗ 权威空手后不得留有可开火的武器实例`

- [ ] **Step 3：修**

`scenes/player/weapon_component.gd`：

```gdscript
	# 权威说手上那把没了(或本来空手)→ 清空手持,让调用方按 wslot 重新 equip
	# ★ 武器实例也要放掉:只清索引的话 `_weapon` 还活着,而 `tick()`/`fire()` 只判
	#   `_player_ok()`(player 非空且没倒地)、**不看索引** → 手上留着一把索引 -1 却
	#   照常开火的幽灵枪。早先这条路径要等一次回滚才走得到,现在(软回灌之后)是常路。
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()
```

- [ ] **Step 4：跑，确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn
```
Expected: 前者 `ALL-OK`；后者 `LEVEL0 SCATTER: ALL-OK`（它把单机的捡/丢/再捡整条走一遍，
是 `WeaponComponent` 改动最直接的回归线）。

- [ ] **Step 5：提交**

```bash
git add scenes/player/weapon_component.gd tests/ground_client_probe.gd
git commit -m "fix(weapons): 权威空手时释放武器实例(只清索引会留一把开得了火的幽灵枪)"
```

---

## 6. 风险与已知边界

1. **`sync_soft_state` 每个 ack 一次。** 守卫是结构比较（O(背包条目数)，≤4）。
   若日后背包条目变复杂（附件/皮肤），要重新评估 —— 这条与 CLAUDE.md 里
   "`capture_state` 每帧多一份 `Array[Dictionary]` 拷贝"是同一类账。
2. **它只搬 `inv`/`wslot`/`mag`/`rld`，不搬"服务器把我手上那把拿走了"的语义。**
   `_apply_weapon_state` 走 `restore_inventory` 的"类型还在就保持"优化 —— 若权威把
   手上那把换成了**同类型**的另一把，客户端的 `inst` 会被更新但武器实例不重建，
   残弹靠 `_restore_mag` 兜。这与改动前 `restore_state` 的行为**一致**（同一段代码），
   不是本次引入的。
3. **不是崩溃修复。** §3.2 说得很清楚：崩因仍未定位。这条修的是**功能失效**
   （捡枪在客户端等于没发生），它**可能**是用户报的"崩溃"的触发器（大跳变的背包突变
   恰好是 `restore_state` 里 `equip()` 那条易出事的路径），但**没有证据**，别把两件事
   混成一句结论。
4. **那份 plan §2.1/§2.2 的场景矩阵仍然没跑完。** 本份只交付 L1（捡/丢/冷却）与
   这条根因。替换、闸门拒绝、抢枪、接缝附近、冻结期/倒地中/换局那一帧……都还没覆盖。
5. **`ground_net_probe` 现在能稳定绿，但靠的是 §1.2 那个测试开关，不是走位。**
   机器人的走位这条路**试过、放弃**了：只会"水平走 + 卡住跳"的机器人在随机地图的窄台上
   会永久卡死（实测两轮，`走到目标超时` 的距离越拉越大直到全场武器被拉黑）。
   → 要让它**不靠开关**也能跑，得给机器人真寻路（`GridPathfinder.astar_path_nearest`
   已经在仓里，飞鸟寻路用的就是它）。那份 plan §3.3 说的"优先走位"是在**没有实测数据
   之前**写的；现在有数据了：走位脆，开关稳。
