# 弹药在回滚中的保真（C1）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 C2 回滚不再抹掉本地打出的弹药 —— 删掉 `_restore_mag` 这条「帧末延迟写回」，改为「入树前设 `pending_mag`、由 `_ready` 一次消费」。

**Architecture:** 现状的弹数写入分两条路：**入树后同步写**（`player._apply_weapon_state` 里
`w.mag_ammo = st["mag"]`）与**帧末延迟写**（`WeaponComponent._restore_mag.call_deferred`，用在
`_equip_index` 重建实例、以及 `restore_inventory` 解析成功后）。延迟写是必需的 —— 新武器实例由
`call_deferred("add_child")` 入树，`WeaponBase._ready()` 会把 `mag_ammo` 重置为 `mag_size`，
所以同步写会被 `_ready` 冲掉。但**延迟写会在帧末覆盖它之后发生的一切写入**，包括回滚重放期间
打出的每一发。本计划把「延迟写」换成**实例上的一个字段**：入树前把残弹塞进 `pending_mag`，
`_ready` 里消费掉。写入从此是同步的、顺序确定的，没有"谁最后跑"这个问题。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、SceneTree 场景探针（`--headless --quit-after`）。

## Global Constraints

- **测试由用户自己跑**（本仓约定）。本计划的命令写出来是给实现者的，agent 不代跑。
- **判据一律 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- 探针的 `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`，本计划不引入新字号）。
- 改 GDScript **只需重导出**，不要重编裁剪模板（那要 10~15 分钟近全量）。
- 引擎路径走环境变量 `$GODOT`（`tests/env.sh`），别把绝对路径抄进脚本。

---

## 背景：根因（已实测，非推断）

**症状**：多人模式下「子弹剩余量不对」，且**只增不减**（客户端弹数偏多）。

**实测证据**（2026-09-25，`--headless` 场景探针，原始输出）：

```
③ 快照:条目 mag=10, weapon.mag_ammo=10
   restore 当帧:weapon.mag_ammo=10(应=10)
   随后手动写 9(模拟 restore 之后又打出一发)
   过两帧:weapon.mag_ammo=10 → ★ C1 成立(deferred 覆盖了后写的 9)
```

**机制**：`WeaponComponent.restore_inventory` 在解析成功后执行

```gdscript
var mag := int(inventory.held[idx]["mag"])          # ← 此刻读的是 ack 那一 tick 的旧值
if mag != WeaponInventory.MAG_FULL and _weapon != null and is_instance_valid(_weapon):
    _restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
```

`mag` 是**按值**在调用点捕获的，而重放发生在之后：

1. `reconcile()` → `restore_state(S)` → 上面两行当场把旧弹数排进 deferred 队列；
2. `PredictionRollback._handle_ack` 重放 `(ack, last_applied]` 的输入 → 重放里每一发 `fire()` 都 `mag_ammo -= 1`；
3. 本帧玩家自己的 `_physics_process` 再打几发；
4. **帧末**，那条 deferred 才执行，把弹数写回第 1 步的旧值。

而服务器照常扣（它处理同一串输入）⇒ 客户端弹数偏高，且**误差只增不减**：
`PredictionRollback._close_enough` 不比 `mag`，`Player.sync_soft_state` 的指纹只比
`wslot`/`winst`/背包结构（结构一致就 early return，那句本来能救命的
`w.mag_ammo = int(st.get("mag", ...))` 稳态下**一次都不会执行**）。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `scenes/weapons/weapon_base.gd` | 单把武器的运行时状态（弹夹/装填/后坐） | **加** `MAG_UNSET` 常量与 `pending_mag` 字段；`_ready` 里消费它 |
| `scenes/player/weapon_component.gd` | 注册表 / 背包 / 换枪 / 残弹记账 | **删** `_restore_mag` 与两个调用点；**删** 死路径 `refill_current_weapon`/`_refill_mag`；**加** 一个静态写入口 `apply_mag` |
| `scenes/player/player.gd` | 玩家编排 + C2 整态捕获/恢复 | `_apply_weapon_state` 的弹数写入改走 `WeaponComponent.apply_mag` |
| `tests/pvp_twin_smoke.gd` | 唯一逐 tick 比对两端状态的孪生冒烟 | **加**开火输入 + `mag_ammo` 断言 |
| `tests/kh_l4_probe.gd` | L4 源码级接口在位扫描 | **改**：`refill_current_weapon` 那两条断言随死路径一起删 |

---

### ~~Task 1: 把 C1 变成红灯~~（★ 2026-09-25 作废）

> **本节 Step 1–4 全部作废,不要执行。** 实现者逐字落地后实测证明这条路走不通
> (两条独立成因,见文末「Task 1R」的成因表)。**改按文末的 `Task 1R` 执行。**

### Task 1（原始版，已作废，仅存档）

**Files:**
- Modify: `tests/pvp_twin_smoke.gd`

**Interfaces:**
- Consumes: 现有 `A`（参照玩家）、`B`（被测玩家）、`_compare(a, b, snap, restored)`、`_build_plan()`、`_apply_input(src, i)`、`_inv_key(p)`。
- Produces: 一个**会红**的断言 —— 后续 Task 修完必须转绿。

- [ ] **Step 1: 输入计划里加开火**

`_build_plan()` 目前只造 `{h, p, r, ax}`（移动/跳/冲/蹲）。加一条攻击边沿，与既有周期互质错开，
保证「开火」与「每 12 tick 的 restore」有重叠。

在 `_build_plan()` 的 `for i in range(ACTIVE):` 循环体内，`var ax := 0.0` 那几行之后加：

```gdscript
		# ★ 开火:半自动手枪每 7 tick 一发。7 与 RESTORE_EVERY(12) 互质 ⇒ 两者必然交错,
		#   "restore 之后当帧又打了一发"这个场景每 84 tick 必被走到一次。
		var atk := (i % 7 == 3)
```

并把末尾的 `prev` 记账与 `_plan.append` 一起改（`prev` 现在要带 `attack`）：

```gdscript
		var p := 0
		var r := 0
		if up: h |= BIT_UP
		if down: h |= BIT_DOWN
		if charge: h |= BIT_CHARGE
		if atk: h |= PacketInputSource.BIT_ATTACK
		if up and not prev.up: p |= BIT_UP
		if not up and prev.up: r |= BIT_UP
		if down and not prev.down: p |= BIT_DOWN
		if not down and prev.down: r |= BIT_DOWN
		if charge and not prev.charge: p |= BIT_CHARGE
		if atk and not prev.get("attack", false): p |= PacketInputSource.BIT_ATTACK
		if not atk and prev.get("attack", false): r |= PacketInputSource.BIT_ATTACK
		prev = {"up": up, "down": down, "charge": charge, "attack": atk}
		_plan.append({"h": h, "p": p, "r": r, "ax": ax})
```

同时把 `_build_plan()` 开头那句 `var prev := {"up": false, "down": false, "charge": false}` 补上 `"attack": false`。

- [ ] **Step 2: 加 `mag_ammo` 断言 —— 用 `is_inside_tree()` 精确守卫**

`_compare()` 的 `checks` 字典末尾（`"inv": _inv_key(a) == _inv_key(b),` 之后）加：

```gdscript
		# ★★ 弹数:**入树才比**。旧版本这里刻意不比 `_weapon.mag_ammo`,理由是它由
		#   `_restore_mag.call_deferred` 在帧末回填、同帧比会假红 —— 那个理由随本批消失
		#   (延迟写被删掉了)。剩下的唯一例外是「本帧刚重建过实例」,而那一档
		#   `is_inside_tree()` 恰好精确表达,不需要再靠"永远不比"来回避。
		"mag": _mag_of(a) == _mag_of(b),
```

并在 `_inv_key()` 旁边加辅助函数：

```gdscript
# 手持武器的弹数;**实例未入树**(本帧刚重建)时返回 -1,与任何真实弹数都不相等
# —— 由调用方保证两个都入树,故 -1 只在"两边都没入树"时相等,而那种情况不会发生
# (两个玩家的重建时机由各自的背包变化决定,不会同步)。
func _mag_of(p) -> int:
	var w = p.weapons.current_weapon()
	if w == null or not w.is_inside_tree():
		return -1
	return int(w.mag_ammo)
```

★ 注意：`_compare` 在 `restored=true` 那一轮（刚 `restore_state`）两边实例都可能未入树 ⇒ 两边都是
`-1` ⇒ 断言恒真。这是**可接受的**：那一轮的判据本来就在 `wslot`/`inv` 上。真正的鉴别力来自
`restored=false` 的那些轮（每 tick 都跑）。

- [ ] **Step 3: 跑一次，确认它红**

Run:
```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$G" --headless --path . --quit-after 3600 res://tests/pvp_twin_smoke.tscn 2>&1 | grep -E "SMOKE_TWIN|字段"
```
Expected: `SMOKE_TWIN FAIL: 字段 mag 发散 tick=…`（不是 `inv`、不是 `pos`）。
★ 这一步是**唯一的红绿分界**：如果打出的是 `字段 inv 发散` 或别的字段名，说明改动引入了别的
问题，先回到 Step 1/2 排查，不要继续。

- [ ] **Step 4: 把红的原始输出记进提交信息**

留着后面 Task 3 用完当反证证据。**不提交**（本 Task 与 Task 2 的代码改动合并为一次提交前，
红灯状态本身不值得单独提交 —— 它是 TDD 的中间态）。

---

### Task 2: `WeaponBase.pending_mag`（入树前设定、`_ready` 消费）

**Files:**
- Modify: `scenes/weapons/weapon_base.gd`

**Interfaces:**
- Produces:
  - `const MAG_UNSET := -2`（`WeaponBase` 上的常量；与 `WeaponInventory.MAG_FULL = -1` 不同码）
  - `var pending_mag: int = MAG_UNSET`（实例字段，非 `@export`）
  - `_ready()` 消费语义：`pending_mag == MAG_UNSET` ⇒ 不动（保持 `mag_size`）；否则
    `mag_ammo = clampi(pending_mag, 0, mag_size)` 并把 `pending_mag` 复位为 `MAG_UNSET`。

- [ ] **Step 1: 加常量与字段**

`weapon_base.gd` 里 `var mag_ammo: int = 0` 那一组字段附近加：

```gdscript
# 入树前的"待生效残弹"。0 是合法弹数,故哨兵不能用 0;`WeaponInventory.MAG_FULL` 是 -1,
# 故哨兵用 -2。
# ★ 为什么需要它:新武器实例由 `WeaponComponent._equip_index` 用
#   `call_deferred("add_child")` 入树,而 `_ready()` 会把 `mag_ammo` 重置为 `mag_size`
#   ⇒ 入树前同步写残弹会被冲掉。原先的对策是"排一个帧末 deferred 写回",但那个写回会
#   覆盖它之后发生的一切(含回滚重放期间打出的每一发)。改成入树前设好、`_ready` 一次消费,
#   写入就同步且顺序确定。
const MAG_UNSET := -2
var pending_mag: int = MAG_UNSET
```

- [ ] **Step 2: `_ready` 里消费**

`weapon_base.gd` 的 `_ready()` 首行是 `mag_ammo = mag_size`。改成：

```gdscript
func _ready() -> void:
	mag_ammo = mag_size
	# ★ 入树前若有人塞了残弹,在这里一次消费掉 —— 这是"入树前写入"唯一生效的地方。
	#   消费后复位哨兵,免得后续 `_ready`(理论上不会跑第二次)或探针误读。
	if pending_mag != MAG_UNSET:
		mag_ammo = clampi(pending_mag, 0, mag_size)
		pending_mag = MAG_UNSET
	_base_sprite_pos = sprite.position
```

（其余 `_ready` 内容原样保留。）

- [ ] **Step 3: 写一条只验这一条逻辑的断言**

Run（复用现成探针，它已经覆盖"切枪后残弹记忆"）：
```bash
"$G" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn 2>&1 | grep -E "KH L3 PROBE"
```
Expected: `KH L3 PROBE: ALL-OK`。这一步只是确认**没弄坏既有路径**（本 Task 自己还没接上调用方，
故不可能让 Task 1 的红灯转绿）。

---

### Task 3: 删掉 deferred 写回，改走同步/`pending_mag`

**Files:**
- Modify: `scenes/player/weapon_component.gd`
- Modify: `scenes/player/player.gd`

**Interfaces:**
- Consumes: Task 2 的 `WeaponBase.MAG_UNSET` / `pending_mag`。
- Produces: `WeaponComponent.apply_mag(w: WeaponBase, mag: int) -> void`（静态）。
  - `w == null` 或 `not is_instance_valid(w)` ⇒ 什么都不做。
  - `w.is_inside_tree()` ⇒ `w.mag_ammo = clampi(mag, 0, w.mag_size)`（`_ready` 已跑过，同步写是终值）。
  - 否则 ⇒ `w.pending_mag = clampi(mag, 0, w.mag_size)`（交给 `_ready` 消费）。

- [ ] **Step 1: 加 `apply_mag`**

`weapon_component.gd` 里，`_restore_mag` **原地替换**为：

```gdscript
# 把一个权威/条目里的弹数写到武器实例上。**同步**,不再排 deferred。
# ★ 分支只有一条判据 —— `is_inside_tree()`:
#   · 已入树:`_ready` 早已跑过(mag_ammo 被设成 mag_size),同步写就是终值;
#   · 未入树:本帧刚 `instantiate` 出来,`_ready` 还没跑,直接写会被它冲掉 ⇒ 交给 pending_mag。
#   这个判据与 `_equip_index` 里那处"残弹写回只认已入树的枪"是同一条(那里防的是读未 _ready 的 0)。
static func apply_mag(w: WeaponBase, mag: int) -> void:
	if w == null or not is_instance_valid(w):
		return
	if w.is_inside_tree():
		w.mag_ammo = clampi(mag, 0, w.mag_size)
	else:
		w.pending_mag = clampi(mag, 0, w.mag_size)
```

- [ ] **Step 2: 改 `_equip_index` 的重建路径**

`_equip_index` 里这两行：

```gdscript
	_weapon = scene.instantiate() as WeaponBase
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
	var mag := int(inventory.held[index]["mag"])
	if mag != WeaponInventory.MAG_FULL:
		_restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
```

改成：

```gdscript
	_weapon = scene.instantiate() as WeaponBase
	# ★ 必须在 add_child **之前**:add_child 是 deferred 的,而 `_ready` 会把 mag_ammo 重置为满
	#   ⇒ 入树后再同步写会晚于 `_ready`?不会 —— 但入树前写**根本无效**(会被 `_ready` 冲掉)。
	#   故这里直接把条目残弹塞进 pending_mag,由 `_ready` 消费。
	#   MAG_FULL(-1)语义是"满弹",交给 `_ready` 的 mag_size 即可,不设 pending。
	if int(inventory.held[index]["mag"]) != WeaponInventory.MAG_FULL:
		_weapon.pending_mag = clampi(int(inventory.held[index]["mag"]), 0, _weapon.mag_size)
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
```

★ 注意 `_weapon.mag_size` 在 `instantiate()` 之后**已经可用**（`@export` 值在实例化时套用）。

- [ ] **Step 3: 删 `restore_inventory` 里的那一整段弹数写入**

`restore_inventory` 的 `idx >= 0` 分支里，删掉：

```gdscript
		var mag := int(inventory.held[idx]["mag"])
		if mag != WeaponInventory.MAG_FULL and _weapon != null and is_instance_valid(_weapon):
			_restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
```

**为什么可以直接删**：`restore_inventory` 的生产调用点只有一个（`player._apply_weapon_state`），
而它紧接着就会写弹数（Step 4）。两处写同一个值，删掉后者就是**消除一次重复写入**，
不是丢失行为。

- [ ] **Step 4: `_apply_weapon_state` 改走 `apply_mag`**

`player.gd` 的 `_apply_weapon_state` 里，`w.mag_ammo = int(st.get("mag", w.mag_ammo))` 那行改成：

```gdscript
		# ★ 走 apply_mag:本帧刚重建过实例时 `_weapon` 还没入树,同步写会被 `_ready` 冲掉。
		#   这是个**同步**调用(不再排 deferred)—— 回滚重放期间打出的每一发因此得以保留。
		WeaponComponent.apply_mag(w, int(st.get("mag", w.mag_ammo)))
```

★ 保留它后面那两行 `w._reloading` / `w._reload_t` 原样（它们不是"入树前会被冲掉"的量，
`WeaponBase._ready` 不碰它们）。

- [ ] **Step 5: 跑 Task 1 的探针，确认转绿**

Run:
```bash
"$G" --headless --path . --quit-after 3600 res://tests/pvp_twin_smoke.tscn 2>&1 | grep -E "SMOKE_TWIN|字段"
```
Expected: `SMOKE_TWIN OK: … 0 字段发散`。

- [ ] **Step 6: 反证（把修复撤掉，确认又红）**

把 Step 4 那行**临时**改回 `w.mag_ammo = int(st.get("mag", w.mag_ammo))`（即绕开 `apply_mag`），
再跑 Step 5 的命令，**必须重新红在 `mag` 上**。确认后改回来。
★ 这一步不可省：Task 1 Step 3 那条红可能红在别的字段上，反证才证明**是这条修复**让 `mag` 转绿。

- [ ] **Step 7: 提交**

```bash
git add scenes/weapons/weapon_base.gd scenes/player/weapon_component.gd scenes/player/player.gd \
        tests/pvp_twin_smoke.gd tests/ammo_rollback_probe.gd tests/ammo_rollback_probe.tscn
git commit -m "fix(pvp): 回滚不再抹掉弹数 —— 删掉 _restore_mag 帧末写回,改 pending_mag 入树前设定"
```

---

### Task 4: 删掉 `refill_current_weapon` 这条死路径

**Files:**
- Modify: `scenes/player/weapon_component.gd`
- Modify: `tests/kh_l4_probe.gd`

**Interfaces:**
- Consumes: 无。
- Produces: 无（纯删除）。`WeaponComponent` 的公开面**去掉** `refill_current_weapon()`。

**证据（为什么是死路径）**：全仓 `grep -rn "refill_current" --include=*.gd scenes core server ui tests`
的命中只有：它自己的声明、`_refill_mag` 的声明与唯一调用点、`player.gd` 里一句**注释**、
以及 `tests/kh_l4_probe.gd` 的 4 处（2 处注释 + 2 处断言）。**没有任何生产调用点。**

它存在过的理由是 `_refill_mag.call_deferred` 必须排在 `_restore_mag.call_deferred` 之后
（`weapon_component.gd` 里那段注释写着："换弹必须 call_deferred —— equip() 排下的 _restore_mag
会在帧末把旧残弹写回"）。**Task 3 删掉 `_restore_mag` 之后，这个理由整体消失。**

- [ ] **Step 1: 删函数**

`weapon_component.gd` 里删掉 `refill_current_weapon()`、`_refill_mag()` 两个函数，
以及它们上面那段以「复活/重启用:把当前武器的弹夹补满」开头的注释块。

- [ ] **Step 2: 教 `kh_l4_probe` 认新形状（不要回退）**

`tests/kh_l4_probe.gd` 里删掉这两条断言：

```gdscript
	_check(_read("res://scenes/player/weapon_component.gd").contains("_refill_mag.call_deferred("),
			"weapon_component.refill_current_weapon 未用 call_deferred(会被 _restore_mag 覆盖 = 复活不满弹)")
```

以及函数名单里 `["res://scenes/player/weapon_component.gd", "refill_current_weapon"],` 那一项。
★ **方向是"改探针认新代码"，不是"把函数加回来让探针绿"** —— 见
`tests/kh_l4_probe.gd:238` 附近那段注释，它整段都在描述一条已经不存在的约束。
连带把那两处注释里提到 `refill_current_weapon` 的字样一并订正。

- [ ] **Step 3: 跑**

Run:
```bash
"$G" --headless --path . --quit-after 3600 res://tests/kh_l4_probe.tscn 2>&1 | grep -E "KH L4 PROBE"
```
Expected: `KH L4 PROBE: ALL-OK`。

- [ ] **Step 4: 提交**

```bash
git add scenes/player/weapon_component.gd tests/kh_l4_probe.gd
git commit -m "refactor(weapon): 删掉 refill_current_weapon 死路径 —— 它的 deferred 理由随 _restore_mag 一起消失"
```

---

### Task 5: 全量回归、真链路验收、登记残余

**Files:**
- Modify: `CLAUDE.md`（**玩家小节**：登记 `apply_mag`/`pending_mag` 这个唯一写入口 + 下面的残余边界。
  ★ 2026-09-25 订正:原文写的是"武器小节:把 `_restore_mag` 的描述换成 `pending_mag`" —— 那是**空操作**，
  `CLAUDE.md` 里 `_restore_mag` 的 grep 命中是 **0**。要写的是**新接口本身**，不是替换一段不存在的描述。）

- [ ] **Step 1: 跑全部受影响的既有探针**

Run:
```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
for t in pvp_twin_smoke kh_l3_probe kh_l4_probe weapon_pickup_probe ground_client_probe ground_action_probe; do
  echo "--- $t ---"
  "$G" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL|SMOKE_TWIN|SMOKE OK"
done
"$G" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "SMOKE OK|FAIL|SCRIPT ERROR"
"$G" --headless --path . -s res://tests/weapon_inventory_smoke.gd 2>&1 | grep -E "OK|FAIL"
```
Expected: 全部通过。★ 特别注意 `weapon_pickup_probe`（它验"落点与起始时刻无关"）——
本批没碰落体，若它红了说明改动越界。

- [ ] **Step 2: 真链路验收（用户跑）**

Run:
```bash
bash tests/pvp_match_smoke.sh          # 先确认 7777 空闲
```
Expected: 判据行全部通过。

- [ ] **Step 3: 实机验收（探针答不了的那半）**

两人开一局 1v1，**持续交火 30 秒以上并观察自己的弹数**：
1. 弹数应当**只随自己开火下降**，不应出现"打了几发又跳回更多"；
2. 打空自动换弹时，换弹后的满弹数与对手看到的应当一致（让对手报一下你手上的枪名）。

★ 这两条探针答不了（探针里两侧跑在同一进程、无网络抖动），必须人眼。

- [ ] **Step 4: 登记残余（**不改代码**，写进 CLAUDE.md）**

在 CLAUDE.md 的武器小节登记两条已知边界：

1. **弹数仍没有"常规"纠正路径**：`_close_enough` 不比 `mag`，`sync_soft_state` 的指纹只比结构。
   本批把**误差的产生源**（每次回滚抹掉重放消耗）删掉了，但没有新增纠正路径。
   ⇒ 若将来出现非回滚来源的弹数分歧（**已知候选**：榴弹的 `max_live_projectiles` ——
   客户端数得到的在飞弹数与服务器可能不同，一边扣弹一边不扣），它仍会**静默保留**。
   判据：给 `pvp_match_client` 加一条 `-- --wepdiag` 每 30 帧打本端/上一条权威的 `mag`。
2. **`pending_mag` 是一次性消费的**：`_ready` 消费后复位。若将来有人在**入树后**写
   `pending_mag`，它会永远不被消费（静默无效）。写入口只有 `WeaponComponent.apply_mag`，
   它按 `is_inside_tree()` 分流，故正常路径到不了。

- [ ] **Step 5: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(claude): 武器小节登记 pending_mag 与弹数纠正路径的残余边界"
```

---

## Task 1R（2026-09-25 修订）: 专用探针 —— 让 C1 变成红灯

> 本 Task **取代**上面的 Task 1（后者已作废,只存档）。**先读本节,再动手。**

**Files:**
- Create: `tests/ammo_rollback_probe.gd`
- Create: `tests/ammo_rollback_probe.tscn`
- Modify: `tests/pvp_twin_smoke.gd` —— **撤掉** `"mag"` 断言与 `_mag_of()`,订正三处陈旧注释,
  并修掉它自己那处 `mag_ammo = 4` 空操作。

**Interfaces:**
- Consumes: `Player.capture_state()` / `restore_state()`、`WeaponComponent.reset_mag_state()`、
  `WeaponComponent.apply_mag()`（Task 3 产出）、`PacketInputSource.{clear_edges, apply_packet, BIT_ATTACK}`。
- Produces: 一个**会红**的探针。判据是文本 `AMMO ROLLBACK PROBE: ALL-OK`。

**为什么必须另起探针（实测，非推断）**

2026-09-25 实现者把原 Task 1 逐字落地后实测到两条**独立**成因，任一条都足以让那条断言失效：

| # | 现象 | 成因 |
|---|---|---|
| ① | `"mag"` 在**每个** restore 轮恒假 | 孪生的 sabotage（`set_initial_inventory([])`）每次清空 B 的背包 ⇒ 每次 restore 都**重建武器实例** ⇒ 比较那一刻 B 的枪**未入树**（`_mag_of` 只能返回哨兵 `-1`），而 A 从没被搞乱、枪一直在树里。原计划注释里"两边都是 -1"的前提不成立。 |
| ② | 去掉 ① 之后断言**修复前就是绿的** | 手枪 `fire_cooldown = 0.3s` 量化到 7-tick 输入网格上，**有效开火周期 = 21 tick**（冷却中不重置冷却）⇒ 开火 tick ≡ 1 (mod 3)，而 `RESTORE_EVERY = 12` ⇒ restore tick ≡ 0 (mod 3) ⇒ **永不同帧**，C1 从未被走到。原计划那句"7 与 12 互质 ⇒ 每 84 tick 必被走到一次"漏算了冷却量化。 |

⇒ 所以本 Task 不再"靠周期碰运气"，而是**把 C1 的序列直接构造出来**。

- [ ] **Step 1: 写探针**

创建 `tests/ammo_rollback_probe.gd`：

```gdscript
extends Node
# C1 专用探针:`restore_state` 之后**同帧**打出的那一发,会不会被帧末的延迟写回抹掉。
#
# 跑法:`--headless --quit-after 3600 res://tests/ammo_rollback_probe.tscn`
# 判据:文本 `AMMO ROLLBACK PROBE: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍
#       exit 0,一行裁决都不打印)。
#
# 机制(修复前):`WeaponComponent.restore_inventory` 把权威弹数按
# `_restore_mag.call_deferred(...)` 排到帧末,而 `restore_state` 之后**同帧**打出的每一发
# 都排在它之前 ⇒ 帧末被覆盖回旧值,客户端弹数只增不减。本探针把那个序列直接构造出来:
#   ① 等玩家落地、武器入树,把手上弹数置成非满(4),并同步进**背包条目**;
#   ② 取快照 → `restore_state(快照)` —— 修复前这一步排下 deferred(值 = 4);
#   ③ **同一物理帧**内按一次开火边沿 ⇒ 玩家 `_physics_process` 打出一发(4 → 3);
#   ④ 等 SETTLE 帧读 `mag_ammo`:修复前 = 4(被覆盖),修复后 = 3。
#
# ★ 为什么每条前置都要显式断言:本探针每一步都踩在同一类陷阱上 ——
#   「**未入树时写状态会被 `_ready` 冲掉,而且不报错**」。
#   · 手上弹数要在**武器入树之后**写(否则被 `_ready` 的 `mag_ammo = mag_size` 冲掉);
#   · 背包条目的 mag 要**显式**同步(条目默认是 `MAG_FULL = -1`,而 `restore_inventory` 只在
#     条目 mag ≠ MAG_FULL 时才排 deferred ⇒ 不同步的话 C1 那一支**根本不会被走到**,
#     探针在修复前也是绿的 = 零鉴别力);
#   · `reset_mag_state()` / `_flush_current_mag()` 自身也只在武器入树时才写。
#   三者任一失效,探针都会静默退化成"永远绿",故每一条都配一条断言。

const COLS := 24
const ROWS := 10
const TILE_WALL := 31      # 纹理 1 全砖(墙)
const WARMUP := 30         # 无输入:落地 + 等武器入树
const MAG_START := 4       # 非满弹(mag_size = 12);必须 ≠ MAG_FULL(-1),否则 deferred 那一支不排
const SETTLE := 3          # 打出那一发之后等几帧再读(帧末 flush 至少要一帧)

var P = null
var _tick := 0
var _fired_at := -1
var _expected := -1
var _checks := 0
var _fail := ""


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	host.name = "Host"
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	var ts := GameParameters.TILE_SIZE
	P = preload("res://scenes/player/player.tscn").instantiate()
	P.name = "AmmoProbe"
	P.set_input_source(PacketInputSource.new())
	host.add_child(P)
	P.global_position = Vector2(6 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	P.weapons.set_initial_inventory([1])   # 只给手枪(type_id 1)


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(TILE_WALL if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _physics_process(_delta: float) -> void:
	if P == null or not _fail.is_empty():
		return
	_tick += 1
	# ★ 超时自守卫:本探针每个"等一下"都可能永远等不到(武器永不入树 / 开火被冷却挡住)。
	#   没有它,探针会耗尽 `--quit-after` 才退出、**一行裁决都不打印** —— 那与真失败在输出上
	#   不可分(本仓登记过的坑)。正常路径在 `WARMUP + SETTLE` 帧内跑完,余量给足。
	if _tick > WARMUP + 120:
		_check(false, "探针超时:等了 %d 帧仍未走到裁决(武器没入树?开火被挡?)" % _tick)
		_finish()
		return
	var w = P.weapons.current_weapon()
	if _fired_at < 0:
		if _tick < WARMUP or w == null or not w.is_inside_tree():
			return        # 武器由 call_deferred 入树:没入树就继续等(此时写状态会被 _ready 冲掉)
		w.mag_ammo = MAG_START
		_check(int(w.mag_ammo) == MAG_START,
			"置残弹失败:写 %d、读回 %d(武器未入树时写会被 _ready 冲成 mag_size)" % [MAG_START, int(w.mag_ammo)])
		P.weapons.reset_mag_state()   # ★ 把手上弹数同步进**背包条目**(默认 MAG_FULL ⇒ 不排 deferred)
		_check(int(P.weapons.inventory.held[P.weapons._current_index]["mag"]) == MAG_START,
			"背包条目残弹没同步上 ⇒ restore_inventory 不会排 deferred,C1 根本没被走到(探针会假绿)")
		if not _fail.is_empty():
			return
		# ★ 同一物理帧内:restore(修复前在此排下帧末 deferred) → 开火边沿。
		#   本节点是场景根、玩家是它的孙子节点 ⇒ 玩家的 `_physics_process` 在本函数**之后**跑,
		#   那一发正落在"restore 之后、帧末 flush 之前"—— C1 的窗口就是这一段。
		P.restore_state(P.capture_state())
		_apply_attack()
		_fired_at = _tick
		_expected = MAG_START - 1
		return
	# 后续帧清掉边沿:别让 `pressed` 挂在那里、在冷却允许时又打出一发(那会让期望值变成 2)
	(P.input_source as PacketInputSource).clear_edges()
	if _tick >= _fired_at + SETTLE:
		var got := int(w.mag_ammo) if w != null else -99
		_check(got == _expected,
			"弹数被帧末写回覆盖:restore 后同帧打出一发,期望 %d、实得 %d" % [_expected, got])
		_finish()


func _apply_attack() -> void:
	var src := P.input_source as PacketInputSource
	src.clear_edges()
	src.apply_packet({
		"seq": _tick, "ax": 0.0,
		"held": PacketInputSource.BIT_ATTACK,
		"pressed": PacketInputSource.BIT_ATTACK,
		"released": 0,
		"weapon": 0,
		"aim": Vector2(1.0, 0.0),
	})


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok and _fail.is_empty():
		_fail = msg


func _finish() -> void:
	if _fail.is_empty():
		print("AMMO ROLLBACK PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("AMMO ROLLBACK PROBE: FAIL —— %s" % _fail)
		get_tree().quit(1)
```

- [ ] **Step 2: 建场景**

创建 `tests/ammo_rollback_probe.tscn`（与 `tests/pvp_twin_smoke.tscn` 逐字同构，只改名字与脚本）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/ammo_rollback_probe.gd" id="1"]

[node name="AmmoRollbackProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 先证明它会红（修复前的世界）**

当前工作区里 Task 2/3 的修复**已经应用且未提交**。先把它备份成一份可恢复的补丁，再暂存掉：

```bash
git diff -- scenes/weapons/weapon_base.gd scenes/player/weapon_component.gd scenes/player/player.gd \
  > .superpowers/sdd/ammo-fix.patch
git stash push -- scenes/weapons/weapon_base.gd scenes/player/weapon_component.gd scenes/player/player.gd
```

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | grep -E "AMMO ROLLBACK"
```
Expected: `AMMO ROLLBACK PROBE: FAIL —— 弹数被帧末写回覆盖:restore 后同帧打出一发,期望 3、实得 4`

★ **这是本批唯一的红绿分界**。若它在这里**绿**了，说明探针没踩到 C1（最可能是背包条目 `mag` 没同步上，
或 `restore_inventory` 那一支没排 deferred）—— 停下排查，**不要**继续；
若它红在 `置残弹失败`/`背包条目残弹没同步上`，那是探针自身的构造问题，同样停下排查。

- [ ] **Step 4: 恢复修复，确认转绿**

```bash
git stash pop
git diff --stat -- scenes/weapons/weapon_base.gd scenes/player/weapon_component.gd scenes/player/player.gd   # 应与 Step 3 备份前一致
```

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/ammo_rollback_probe.tscn 2>&1 | grep -E "AMMO ROLLBACK"
```
Expected: `AMMO ROLLBACK PROBE: ALL-OK(3 条断言)`

★ 若 `git stash pop` 有冲突，用 `.superpowers/sdd/ammo-fix.patch` 恢复（`git apply`），
并**在报告里记明**用了哪条路。反证步的「还原」会吃掉未提交改动，这一步必须逐字确认后再往下走。

- [ ] **Step 5: 从孪生冒烟里撤掉那条 mag 断言**

`tests/pvp_twin_smoke.gd`：
1. 删掉 `_compare()` 里实现者加的那行 `"mag": …`（**连同 `-1` 守卫一起删** —— 用户裁定：
   撤掉断言，不保留弱守卫）。
2. 删掉 `_mag_of()` 辅助函数。
3. **保留**开火输入（`atk` / `BIT_ATTACK` 那几行）—— 它让孪生覆盖到"回滚恢复期间开火"这个面。
4. 订正三处陈旧注释：文件头（`:6` 的「不开火」）、`:140`（`# aim 常量(1,0):孪生不开火,…`）、
   以及 `_inv_key()` 上方原本解释"为何不比 `_weapon.mag_ammo`"的那段（`:209-210`）——
   撤掉断言之后那段话已无对象，改成"比的是**背包条目里的** mag"即可。
5. **修掉这个文件自己的一处空操作**：`:52-58` 那句"给两人一个非空且**残弹非满**的背包"是假的 ——
   `await get_tree().physics_frame` 之后武器**仍未入树**，`w.mag_ammo = 4` 随后被 `_ready` 冲成
   `mag_size`（实测 `in=false mag=4` → 下一帧 `in=true mag=12`）。改成等到入树再写：
   在 `for p in [A, B]:` 那个循环里，先 `while w != null and not w.is_inside_tree(): await get_tree().physics_frame`，
   再写 `mag_ammo`，然后调 `p.weapons.reset_mag_state()` 同步进条目。

★ 第 5 步是**独立**的一件事：若它让孪生红在 `mag` **以外**的字段上，把这一步单独回退、
在报告里记明（那是一条新发现，不是本批的失败）——**不要**为了让孪生变绿去改判据。

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/pvp_twin_smoke.tscn 2>&1 | grep -E "SMOKE_TWIN|字段"
```
Expected: `SMOKE_TWIN OK: 640 ticks, … 0 字段发散`

- [ ] **Step 6: 提交**

```bash
git add scenes/weapons/weapon_base.gd scenes/player/weapon_component.gd scenes/player/player.gd \
        tests/pvp_twin_smoke.gd tests/ammo_rollback_probe.gd tests/ammo_rollback_probe.tscn
git commit -m "fix(pvp): 回滚不再抹掉弹数 —— 删掉 _restore_mag 帧末写回,改 pending_mag 入树前设定"
```

（`tests/ammo_rollback_probe.gd.uid` 由 Godot 自己生成，若 `git status` 显示它就一并加上。）

---

## Self-Review

**1. 覆盖面**：本计划只针对 C1（实测确认的那条）。C3（无纠正路径）**刻意不做修复**，
改为在 Task 5 Step 4 登记 —— 理由是修它会引入"每 ack 把弹数倒回一个 RTT 前"的反向橡皮筋
（要正确就得做 rewind+replay，那是 `restore_state` 已经在做的事，而它的结果正是被 C1 抹掉的）。
C1 修好后误差不再产生，YAGNI 上不该顺手加一套新的连续量同步。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"；每个改动都给了完整代码块与确切路径。

**3. 类型一致性**：`WeaponComponent.apply_mag(w: WeaponBase, mag: int) -> void`（Task 3 定义、
Task 1 无关）、`WeaponBase.MAG_UNSET`(Task 2 定义、Task 3 使用)、`WeaponBase.pending_mag`(
Task 2 定义、Task 3 两处使用)—— 三处名字一致。Task 1 定义的 `_mag_of(p)` 只在 Task 1 内使用。

**4. 未覆盖但相关（不在本计划范围，另行处理）**：
- **B2**：`_apply_weapon_state` 的「要不要重建实例」判据是 `wslot`（**类型 id**）⇒ 同型号两把
  之间换手持恒不重建。它与本计划**改同一段代码**（Task 3 Step 4 就在那几行旁边），但修法不同
  （要按 `winst` 判），**建议在本计划落地后紧接着做**，别并进来 —— 并了会让"red→green"分不清是哪一条。
  ★★ **2026-09-27 订正:这条建议已被 `eeda162`(2026-09-23)的设计取代,不再是一个待办** —— 现行设计是
  **按 `inst` 定手持下标、按类型决定要不要重建**,写在 `WeaponComponent.restore_inventory` 的头注里
  (`scenes/player/weapon_component.gd` 的 `:397-416`);且"**类型还在就不重建**"是**刻意的**:
  `restore_state` 每次 reconcile 都调它,无脑重建 = 每帧 queue_free 旧枪 + 新建 + deferred 入树,
  而入树前那一帧的 `tick()`/`fire()` 全是空转(开火边沿直接丢)。★ 关键在于 **`WeaponBase` 不携带
  `inst`**(grep 全文件无 `var inst`)⇒ 同型号换手时那个**节点**本来就无需换,"是哪一把"只活在
  背包条目里;用户可见的三件事(**残弹写哪条 / 丢弃丢哪把 / 格子高亮**)由 `_current_index` 承担,
  而它**已按 `inst` 解析**,守卫是 `ground_client_probe` ④b(三把同型号、两条独立判据分别走
  `restore_state` 与 `sync_soft_state`)。⇒ **不改**。★ 另:`progress.md` 记过,动那条判据曾引入过
  回归(把 `_current_type` 改成"表里那条的类型" ⇒ 判据恒假 ⇒ 实例永不重建 ⇒ 被清空过背包的一方
  恢复后手上没枪 ⇒ `SMOKE_TWIN FAIL: 字段 facing 发散`);改动前先读那一段。
- **推断待验**：`_equip_index` 用 `call_deferred("add_child")` ⇒ 重建那一帧里 `_weapon` 未入树，
  而 `player._physics_process` 同帧会 `weapons.tick()` → `fire()` → `_spawn_projectiles` 里
  `get_viewport().add_child(b)`；未入树的 `get_viewport()` 返回 **null**。这条**只是读代码推的，
  没有复现**。若成立，它是"回滚 + 同帧开火"时的一条报错（不是崩溃）。**本计划不顺手修**——
  先在 Task 5 的实机验收里留意 stdout 有没有 `Attempt to call function 'add_child' on a null instance`，
  有则单独立项。
