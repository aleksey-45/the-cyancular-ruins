# 武器槽位与地面拾取（单机）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把武器从"按类型 id 直接切枪"改成"有容量预算的背包 + 地上可捡可丢的物理实体"，单机侧完整可玩。

**Architecture:** 背包逻辑收进纯 `RefCounted`（`WeaponInventory`，无 autoload、可 `-s` 测）；地面武器是独立的 `CharacterBody2D` 场景（`WeaponPickup`），视觉复用武器场景实例（`WeaponBase` 无 `_process`，不驱动即静止），碰撞箱由 sprite 像素包围盒生成；布点算法从 `RoyaleHost` 抽成静态工具供单机复用。`_current_slot` **保持"类型 id"语义**，因此 PvP 快照协议与 `PlayerReplica` 在本计划中零改动。

**Tech Stack:** Godot 4.7 标准版、GDScript、无单测框架（`extends SceneTree` 的 `-s` 冒烟 + `extends Node` 的场景探针）。

**依据 spec:** `docs/superpowers/specs/2026-09-15-weapon-slots-and-pickup-design.md`

## Global Constraints

- **缩进一律用 TAB**（GDScript 本仓约定），不要用空格。
- **字号必须是 16 的倍数**（`kh_l4`/`kh_l5` 有源码级扫描，`res://tests` 也在扫描范围内）。新控件里不得出现非 16 倍数的字号载体字面量。
- **颜色只在 `ui/ui_factory.gd` 定义**，别处不许出现 `Color(...)` 字面量。
- **`-s` 脚本（`extends SceneTree`）阶段 autoload 尚未实例化**：新冒烟里不要静态引用会连带 preload autoload 的脚本，要 `load()` 的放在 `_initialize()` 内。
- ★ **`-s` 冒烟必须有空载守卫**：`_initialize()` 里一旦抛错就走不到 `quit()`，进程会**永久挂起**（不是干净失败，是超时）。每个新冒烟在 `load()` 之后立刻写：
  ```gdscript
	if XXX == null:
		print("<探针名> FAILED: 找不到 <路径>")
		quit(1)
		return
  ```
  跑新冒烟时**一律套 `timeout`**（`timeout 60 "<godot>" …`），否则红了会把会话卡死。
- **测试由用户自己跑**，实施者只负责写测试与跑"红→绿"那两步所需的命令。
- `docs/` 之外的源码改动一律**不得**改动 `Player.tscn` 的碰撞层常量（`enemy_logic_smoke` 有 `player mask == 5` 断言）。
- **中间态说明**：Task 3 落地后到 Task 11 之前，单机的初始背包是临时的 3 把（`[1,2,6]` = 8 格刚好占满），重狙/霰弹/榴弹在单机里暂时拿不到。**这是计划内的中间态**，Task 10/11 落地后恢复完整（12 把散落在地图上）。不要为了让中间态"好看"而临时放宽容量闸门。

---

## 文件结构

**新建**

| 文件 | 职责 |
|---|---|
| `core/sim/weapon_inventory.gd` | 背包纯逻辑：持有表、容量/把数两条闸门、紧凑排布、快照/恢复 |
| `core/sim/ground_weapon_field.gd` | 地面武器表的纯逻辑：增删查 + 环面最近拾取 |
| `core/present/sprite_bounds.gd` | 从 `Sprite2D` 像素求包围盒（地面武器碰撞箱的来源） |
| `ui/weapon_slots.gd` | 4×2 格子控件（自包含，可挂任意 `CanvasLayer`） |
| `scenes/weapons/weapon_pickup.gd` / `.tscn` | 地面武器实体 |

**修改**

| 文件 | 改动 |
|---|---|
| `scenes/player/weapon_component.gd` | 换成背包模型；删 `_mag_state` 一族 |
| `scenes/player/player.gd` | F/Q 读口、Q 长按计时、初始背包注入、拾取/丢弃接线 |
| `core/net/player_input.gd` + 三个实现 | 两个新读口；`_weapon_slot_raw` 只回 1-4 |
| `core/config/settings.gd` | `wheel_switch` 默认 true；`REMAPPABLE_ACTIONS` 加 F/Q |
| `core/config/player_params.gd` | 拾取/丢弃/落地摩擦参数 |
| `project.godot` | 新增 `F` / `Q` 动作 |
| `ui/ui_factory.gd` | 三个格子颜色常量 |
| `ui/hud.gd` | 左下角接上 `WeaponSlots` |
| `core/sim/grid_pathfinder.gd` | 新增 `spread_cells` |
| `server/royale_host.gd` | `plan_spawns` 改调 `spread_cells` |
| `scenes/level_0.gd` | 单机散落 12 把；`restart_single` 重开 |

**测试**：`tests/weapon_inventory_smoke.gd`、`tests/ground_weapon_field_smoke.gd`、`tests/sprite_bounds_smoke.gd`、`tests/weapon_pickup_probe.tscn`（新）；`tests/enemy_logic_smoke.gd`、`tests/kh_l3_probe.gd`、`tests/kh_l3_visual_probe.gd`（改）。

**本文档中所有 headless 命令的 `$GODOT`** = `D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`（可用环境变量覆盖）。

---

### Task 1: `WeaponInventory` 纯逻辑模块

**Files:**
- Create: `core/sim/weapon_inventory.gd`
- Test: `tests/weapon_inventory_smoke.gd`

**Interfaces:**
- Consumes: 无
- Produces: `class_name WeaponInventory extends RefCounted`；`_init(tiers: Dictionary)`；字段 `held: Array[Dictionary]`（每条 `{type:int, inst:int, mag:int}`）；方法 `tier_of(type_id)->int`、`cost_of(type_id)->int`、`used_slots()->int`、`can_hold(type_id)->bool`、`add(type_id, mag)->int`、`remove_at(index)->Dictionary`、`index_of_inst(inst)->int`、`first_index_of_type(type_id)->int`、`slot_start(index)->int`、`snapshot()->Array`、`restore(entries)->void`、`clear()->void`；常量 `TIER_LIGHT=0`/`TIER_MEDIUM=1`/`TIER_HEAVY=2`、`SLOT_COST`、`MAX_WEAPONS=4`、`CAPACITY=8`

- [ ] **Step 1: 写失败的测试**

创建 `tests/weapon_inventory_smoke.gd`：

```gdscript
extends SceneTree

# 武器背包纯逻辑冒烟。跑法(默认引擎路径):
#   "D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" \
#       --headless --path . -s res://tests/weapon_inventory_smoke.gd
# 成功打印 SMOKE OK 退出 0。
#
# ★ 在 _initialize() 里 load(),不用全局类名 —— -s 阶段 autoload 未实例化,
#   且类名缓存不保证已就绪(见 CLAUDE.md「测试」一节)。

var _fail := 0

func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)

func _initialize() -> void:
	var WI: GDScript = load("res://core/sim/weapon_inventory.gd")
	# 假 tier 表:1/2 = 轻,3/4 = 中,5 = 重,6 = 重
	var tiers := {1: 0, 2: 0, 3: 1, 4: 1, 5: 2, 6: 2}

	# ── 容量与把数上限是两条**独立**闸门 ──
	var inv = WI.new(tiers)
	_check(inv.used_slots() == 0, "空背包占 0 格")
	_check(inv.can_hold(5), "空背包放得下重武器")
	inv.add(1, 5)           # 轻,2 格
	inv.add(2, 5)           # 轻,2 格
	inv.add(3, 5)           # 中,3 格 → 共 7 格 / 3 把
	_check(inv.used_slots() == 7, "2轻+1中 = 7 格(实际 %d)" % inv.used_slots())
	_check(not inv.can_hold(5), "7 格放不下 4 格的重武器(容量闸门)")
	# 7 格只剩 1 格,而最便宜的档是 2 格 → 此时什么都放不下。
	# (实施时我在这里写过 `can_hold(1) 应为 true` —— 那是把 7+2=9 看成了 8。
	#  实现拒绝加才是对的。留着这条正好钉住"闸门按剩余**格数**算,不是按把数算"。)
	_check(not inv.can_hold(1), "7 格只剩 1 格,放不下 2 格的轻武器")
	var freed: Dictionary = inv.remove_at(2)
	_check(int(freed["type"]) == 3, "腾出的是中武器")
	_check(inv.used_slots() == 4 and inv.held.size() == 2, "腾出后 4 格 / 2 把")
	_check(inv.can_hold(5), "腾出后放得下 4 格的重武器(4+4=8)")

	# 恰好占满 8 格:任何一档都放不下了
	var inv_b = WI.new(tiers)
	inv_b.add(1, 5)
	inv_b.add(5, 5)
	inv_b.add(2, 5)         # 2+4+2 = 8 格 / 3 把
	_check(inv_b.used_slots() == 8 and inv_b.held.size() == 3, "恰好 8 格 / 3 把")
	_check(not inv_b.can_hold(1), "满容量后最便宜的档也放不下")

	# ★ 关于"把数闸门独立于容量闸门"的实话:**按今天的 cost 表它其实被容量蕴含** ——
	#   最便宜的轻武器 2 格,4 把 × 2 = 8 = CAPACITY,所以 used_slots() ≤ 8 已蕴含 size ≤ 4。
	#   造不出"容量还有余、但已满 4 把"的局面(要造就得有 cost=1 的档)。
	#   但它**不是死代码**:用户把它定为硬规则(「就算容量给 100 也最多四把」),
	#   一旦有人把轻武器改成 1 格、或把 CAPACITY 调大,这个承诺就只剩这一条在守。
	#   退而钉住常量本身 + 那条临界等式,别假装验了闸门的独立性。
	_check(int(WI.MAX_WEAPONS) == 4, "MAX_WEAPONS 必须恰好是 4")
	_check(int(WI.CAPACITY) == 8, "CAPACITY 必须恰好是 8")
	_check(int(WI.SLOT_COST[int(WI.TIER_LIGHT)]) * int(WI.MAX_WEAPONS) == int(WI.CAPACITY),
		"轻武器 cost × 4 应恰好等于容量(这条不成立时,上面那段注释就该重写)")
	var inv2 = WI.new(tiers)
	for i in 4:
		inv2.add(1, 5)      # 4 把轻武器 = 8 格,把数与容量同时到顶
	_check(inv2.held.size() == 4 and inv2.used_slots() == 8, "4 把轻武器 = 4 把 / 8 格")
	_check(not inv2.can_hold(1), "4 把轻武器后不能再装")

	# ── 紧凑排布 ──
	var inv3 = WI.new(tiers)
	inv3.add(1, 5)          # 轻 2
	inv3.add(5, 5)          # 重 4
	_check(inv3.slot_start(0) == 0, "第 0 把起始格 = 0")
	_check(inv3.slot_start(1) == 2, "第 1 把起始格 = 2(实际 %d)" % inv3.slot_start(1))

	# ── 允许重复:两把同类型各有各的 inst 与残弹 ──
	var inv4 = WI.new(tiers)
	var a: int = inv4.add(1, 11)
	var b: int = inv4.add(1, 3)
	_check(a != b, "同类型两把的 inst 不同(%d vs %d)" % [a, b])
	_check(inv4.held.size() == 2, "允许持有两把同类型武器")
	_check(inv4.index_of_inst(b) == 1, "index_of_inst 找得到第二把")
	_check(inv4.first_index_of_type(1) == 0, "first_index_of_type 返回第一把")

	# ── 删中间条目:后面的索引与残弹不错位 ──
	var inv5 = WI.new(tiers)
	inv5.add(1, 11)         # idx 0
	inv5.add(3, 22)         # idx 1
	inv5.add(6, 33)         # idx 2
	var gone: Dictionary = inv5.remove_at(1)
	_check(int(gone["mag"]) == 22, "remove_at 返回被删条目的残弹(实际 %s)" % str(gone))
	_check(inv5.held.size() == 2, "删后剩 2 条")
	_check(int(inv5.held[0]["mag"]) == 11 and int(inv5.held[1]["mag"]) == 33,
		"删中间条目后其余残弹不串位")
	_check(inv5.slot_start(1) == 2, "删后第 1 把起始格重算 = 2(实际 %d)" % inv5.slot_start(1))

	# ── 快照 / 恢复 ──
	var snap: Array = inv5.snapshot()
	_check(snap.size() == 2, "snapshot 出 2 条")
	var inv6 = WI.new(tiers)
	inv6.restore(snap)
	_check(inv6.held.size() == 2 and int(inv6.held[1]["type"]) == 6,
		"restore 后类型正确")
	_check(inv6.used_slots() == inv5.used_slots(), "restore 后占用格一致")
	# restore 必须把 _next_inst 顶到已用 inst 之上,否则新加的条目会与旧条目撞 inst
	var c: int = inv6.add(1, 0)
	_check(inv6.index_of_inst(c) == 2 and c > int(inv5.held[1]["inst"]),
		"restore 后新加的 inst 不与已有条目冲突")

	# ── clear ──
	inv6.clear()
	_check(inv6.held.is_empty() and inv6.used_slots() == 0, "clear 清空持有表")

	if _fail == 0:
		print("SMOKE OK")
		quit(0)
	else:
		print("SMOKE FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑测试确认它失败**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/weapon_inventory_smoke.gd
```
Expected: FAIL —— `res://core/sim/weapon_inventory.gd` 不存在，`load()` 返回 null，随即在 `WI.new(tiers)` 处报 "Invalid call. Nonexistent function 'new' in base 'Nil'"。

- [ ] **Step 3: 写最小实现**

创建 `core/sim/weapon_inventory.gd`：

```gdscript
class_name WeaponInventory
extends RefCounted

# 武器背包的**纯逻辑**:持有表 + 容量预算。无 autoload 依赖、可 -s 测。
#
# ★ tier 数值刻意与 WeaponBase.Tier 对齐(LIGHT=0/MEDIUM=1/HEAVY=2),但**不 import
#   weapon_base.gd** —— 它的 @export 默认值 preload 了 bullet.tscn,会连带把 autoload
#   拖进 -s 冒烟(见 tests 里"autoload 尚未实例化"的注释)。对齐关系由
#   enemy_logic_smoke 的断言钉住(漂移即红)。
#
# ★ 容量(8 格)与把数上限(4 把)是**两条独立闸门**,不是一条推另一条
#   —— 用户 2026-09-15 明确裁定「就算容量给 100 也最多四把」。

const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const SLOT_COST: Dictionary = {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}

const MAX_WEAPONS := 4
const CAPACITY := 8

# 条目里的 mag == MAG_FULL 表示「满弹」:入树后不覆盖 _ready 设的满弹。
const MAG_FULL := -1

# 背包条目,按获得顺序。每条 {"type": 类型 id 1-6, "inst": 实例序号, "mag": 残弹}
# ★ inst 是必需的:允许持有同类型两把,残弹必须按**具体那把**记,
#   按类型记会让「丢一把空弹手枪、捡一把满地手枪」变成免费换弹。
var held: Array[Dictionary] = []

var _tiers: Dictionary         # type_id -> tier
var _next_inst: int = 1

func _init(tiers: Dictionary) -> void:
	_tiers = tiers

func tier_of(type_id: int) -> int:
	return int(_tiers.get(type_id, TIER_LIGHT))

func cost_of(type_id: int) -> int:
	return int(SLOT_COST.get(tier_of(type_id), SLOT_COST[TIER_LIGHT]))

func used_slots() -> int:
	var n := 0
	for e in held:
		n += cost_of(int(e["type"]))
	return n

# 两条闸门都在这里。调用方必须先问过它再 add() —— add() 自己不代替闸门
# (加了就是"静默超容",出问题时看不出是哪一步放进去的)。
func can_hold(type_id: int) -> bool:
	if held.size() >= MAX_WEAPONS:
		return false
	return used_slots() + cost_of(type_id) <= CAPACITY

func add(type_id: int, mag: int) -> int:
	var inst := _next_inst
	_next_inst += 1
	held.append({"type": type_id, "inst": inst, "mag": mag})
	return inst

func remove_at(index: int) -> Dictionary:
	if index < 0 or index >= held.size():
		return {}
	return held.pop_at(index)

func index_of_inst(inst: int) -> int:
	for i in held.size():
		if int(held[i]["inst"]) == inst:
			return i
	return -1

func first_index_of_type(type_id: int) -> int:
	for i in held.size():
		if int(held[i]["type"]) == type_id:
			return i
	return -1

# 紧凑排布:第 index 把占据格子 [slot_start(index), slot_start(index)+cost)。删中间一条,其后左移。
func slot_start(index: int) -> int:
	var n := 0
	for i in range(0, mini(index, held.size())):
		n += cost_of(int(held[i]["type"]))
	return n

func snapshot() -> Array:
	var out: Array = []
	for e in held:
		out.append({"type": int(e["type"]), "inst": int(e["inst"]), "mag": int(e["mag"])})
	return out

func restore(entries: Array) -> void:
	held.clear()
	for e in entries:
		var d: Dictionary = e
		var inst := int(d.get("inst", 0))
		held.append({"type": int(d.get("type", 1)), "inst": inst, "mag": int(d.get("mag", MAG_FULL))})
		# ★ 必须把 _next_inst 顶到已用 inst 之上 —— 否则恢复后新加的条目会与旧条目撞 inst,
		#   而 inst 是"哪把是哪个"的唯一凭据(撞了 = 残弹串到另一把枪上)。
		_next_inst = maxi(_next_inst, inst + 1)

func clear() -> void:
	held.clear()
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: `SMOKE OK`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add core/sim/weapon_inventory.gd tests/weapon_inventory_smoke.gd
git commit -m "feat(weapons): WeaponInventory 纯逻辑 —— 8格容量 + 4把上限两条独立闸门"
```

---

### Task 2: `TIERS` 注册表与三条对齐断言

**Files:**
- Modify: `scenes/player/weapon_component.gd`（在 `DISPLAY_NAMES` 之后加 `TIERS`）
- Test: `tests/enemy_logic_smoke.gd`（在文件末尾追加一节）

**Interfaces:**
- Consumes: Task 1 的 `WeaponInventory.TIER_*` 常量与 `SLOT_COST`
- Produces: `WeaponComponent.TIERS: Dictionary`（`type_id -> WeaponBase.Tier`）

- [ ] **Step 1: 写失败的测试**

在 `tests/enemy_logic_smoke.gd` 里找到 `_initialize()` 的最后一段（最后一个 `_phase_*` 调用之后），加一行 `_phase_weapon_registry()`，然后在文件末尾追加：

```gdscript
# 三条注册表对齐断言。加新武器时漏填注册表的表现各不相同:
#   WEAPONS 漏 → 切枪时 load("") 报错(响);DISPLAY_NAMES 漏 → HUD 显示 "?"(看得见);
#   TIERS 漏 → **容量算错**(轻武器被当重武器,8 格只能带两把),完全不报错。
# 第三条最容易漏,所以三条一起钉。
func _phase_weapon_registry() -> void:
	var wc: GDScript = load("res://scenes/player/weapon_component.gd")
	var wi: GDScript = load("res://core/sim/weapon_inventory.gd")
	var wb: GDScript = load("res://scenes/weapons/weapon_base.gd")

	# ① 三个注册表键集相同
	# ★ 必须**归一化成 int** 再比:WEAPONS 的键是字符串("1".."6",因为装备路径是
	#   equip(str(slot)) → load(WEAPONS[slot])),而 DISPLAY_NAMES / TIERS 的键是整数。
	#   直接比数组永远不等 —— 而"永远不等"看起来像真发现了漏填,其实是类型没归一。
	var keys_w: Array = (wc.WEAPONS as Dictionary).keys().map(func(k): return int(k))
	var keys_n: Array = (wc.DISPLAY_NAMES as Dictionary).keys().map(func(k): return int(k))
	var keys_t: Array = (wc.TIERS as Dictionary).keys().map(func(k): return int(k))
	keys_w.sort()
	keys_n.sort()
	keys_t.sort()
	_check(keys_w == keys_n, "WEAPONS 与 DISPLAY_NAMES 键集相同(归一化后)")
	_check(keys_w == keys_t, "WEAPONS 与 TIERS 键集相同(归一化后)")

	# ② TIERS 与各 .tscn 的 tier = export 逐条一致(两份数据是刻意重复的:
	#    不实例化武器场景就问得到"这枪多重",代价是要有这条断言兜住漂移)
	for k in keys_w:
		var slot := int(k)
		var scene: PackedScene = load(wc.WEAPONS[str(slot)])
		_check(scene != null, "槽 %d 的武器场景加载失败" % slot)
		if scene == null:
			continue
		var inst: Node = scene.instantiate()
		_check(int(inst.tier) == int(wc.TIERS[slot]),
			"槽 %d 的 tscn tier=%d 与注册表 %d 不一致" % [slot, int(inst.tier), int(wc.TIERS[slot])])
		inst.free()

	# ③ WeaponInventory 的 tier 常量与 WeaponBase.Tier 数值对齐
	#    (wi 刻意不 import weapon_base,所以这条对齐是**约定**而不是编译器保证的)
	_check(int(wi.TIER_LIGHT) == int(wb.Tier.LIGHT), "TIER_LIGHT 与 WeaponBase.Tier.LIGHT 数值不一致")
	_check(int(wi.TIER_MEDIUM) == int(wb.Tier.MEDIUM), "TIER_MEDIUM 与 WeaponBase.Tier.MEDIUM 数值不一致")
	_check(int(wi.TIER_HEAVY) == int(wb.Tier.HEAVY), "TIER_HEAVY 与 WeaponBase.Tier.HEAVY 数值不一致")
	_check(int(wi.MAX_WEAPONS) == 4, "MAX_WEAPONS 不是 4")
	_check(int(wi.CAPACITY) == 8, "CAPACITY 不是 8")
	_ok("武器注册表三条对齐")
```

若 `enemy_logic_smoke.gd` 里没有 `_ok` 助手，改用与文件内既有写法一致的打印（该文件用的是 `_check` + 末尾汇总；照着已有的 `_check` 用法即可，把 `_ok(...)` 那行删掉）。

- [ ] **Step 2: 跑测试确认它失败**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: FAIL —— `weapon_component.gd` 上还没有 `TIERS`，`wc.TIERS` 取值为 null，`(wc.TIERS as Dictionary).keys()` 报错或断言 ① 失败。

- [ ] **Step 3: 写最小实现**

在 `scenes/player/weapon_component.gd` 的 `DISPLAY_NAMES` 常量之后（原第 18 行后）插入：

```gdscript
# 武器重量档(轻/中/重),决定占几格(见 WeaponInventory.SLOT_COST)。
# ★ 与各 .tscn 的 `tier =` export **刻意重复** —— 这份表让"这枪多重"不必实例化武器场景
#   就能问(实例化会连带 preload bullet.tscn)。漂移由 enemy_logic_smoke 的
#   `_phase_weapon_registry` 逐条钉住。加新武器时**这里也要加一行**。
const TIERS: Dictionary = {
	1: WeaponBase.Tier.LIGHT,    # 手枪
	2: WeaponBase.Tier.MEDIUM,   # 步枪
	3: WeaponBase.Tier.HEAVY,    # 重狙 M82A1
	4: WeaponBase.Tier.LIGHT,    # 霰弹 S686
	5: WeaponBase.Tier.HEAVY,    # 榴弹发射器
	6: WeaponBase.Tier.MEDIUM,   # 激光枪
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: 打印 `SMOKE OK`（或该文件既有的成功行），退出码 0；`_phase_weapon_registry` 一节零 FAIL。

- [ ] **Step 5: 提交**

```bash
git add scenes/player/weapon_component.gd tests/enemy_logic_smoke.gd
git commit -m "feat(weapons): TIERS 注册表 + 三条注册表对齐断言(键集/tscn/枚举数值)"
```

---

### Task 3: `WeaponComponent` 换成背包模型

**Files:**
- Modify: `scenes/player/weapon_component.gd`（整体重写 `_current_slot` 之后的全部逻辑）
- Modify: `scenes/player/player.gd:147`（临时初始背包）
- Test: `tests/kh_l3_probe.gd`（残弹与切枪两节按新语义重写）

**Interfaces:**
- Consumes: Task 1 的 `WeaponInventory`；Task 2 的 `WeaponComponent.TIERS`
- Produces:
  - `weapon_changed(slot: int)`、`inventory_changed()` 两个信号
  - `inventory: WeaponInventory` 字段；`_current_slot: int`（类型 id，0 = 空手）
  - `set_initial_inventory(types: Array[int]) -> void`
  - `equip(slot: String) -> void`（类型 id；背包里没有则加入）
  - `equip_index(i: int) -> void`
  - `cycle_slot(dir: int)` / `request_net_cycle(dir: int)`（改为在背包位置间循环）
  - `pick_up(type_id: int, mag: int) -> int`（返回被替换掉的类型 id；0 = 无替换）
  - `drop_current() -> Dictionary`（`{type, mag}`；空 = 空手）
  - `random_keep_one() -> Array[Dictionary]`（复活用）
  - `snapshot_inventory() -> Array` / `restore_inventory(entries: Array) -> void`
  - `refill_current_weapon()`（改为把当前条目补满）

- [ ] **Step 1: 改写 `weapon_component.gd`**

把 `scenes/player/weapon_component.gd` 从第 20 行（`signal weapon_changed`）到文件末尾整体替换为：

```gdscript
signal weapon_changed(slot: int)   # equip 成功后发射(菜单图标/HUD 武器显示跟随)
signal inventory_changed()          # 背包内容/残弹变化(格子 UI 跟随)

# 当前手持的**类型 id**(1-6);0 = 空手(背包为空)。
# ★ 刻意保持"类型 id"而不是"背包位置":快照 weapon 字段、PlayerReplica._swap_weapon、
#   capture_state 的 wslot 全按类型 id 走 —— 协议与副本因此零改动。
var _current_slot: int = 0
var _current_index: int = -1        # 在 inventory.held 里的下标;-1 = 空手
var _weapon: WeaponBase = null
var inventory: WeaponInventory
var body: CharacterBody2D

# 启用的武器槽位(1-6)。单机由 Level0 按 RunOptions 设置;PvP 由客户端按服务器
# 下发的 match_options 设置。数字键/滚轮切枪都会跳过禁用槽位。
var enabled_slots: Array = [1, 2, 3, 4, 5, 6]

func _init() -> void:
	# 在 _init 而不是 _ready 建:探针会 new() 出组件直接调方法,不一定入树。
	inventory = WeaponInventory.new(TIERS)

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func set_enabled_slots(disabled: Array[int]) -> void:
	enabled_slots = [1, 2, 3, 4, 5, 6].filter(func(s: int) -> bool: return not disabled.has(s))
	if enabled_slots.is_empty():
		enabled_slots = [1]   # 不允许全禁:至少留手枪
	# 当前拿着的枪被禁 → 切到背包里第一把没被禁的
	if _current_slot > 0 and not is_slot_enabled(_current_slot):
		var fallback := _first_enabled_index()
		if fallback >= 0:
			_equip_index(fallback)
		else:
			_unequip()

func is_slot_enabled(slot: int) -> bool:
	return enabled_slots.has(slot)

func _first_enabled_index() -> int:
	for i in inventory.held.size():
		if is_slot_enabled(int(inventory.held[i]["type"])):
			return i
	return -1

# 默认槽位 = 最小的启用槽位(出生/复活用它,防止出生武器被禁后空手)。
func default_slot() -> String:
	return str(enabled_slots[0]) if enabled_slots.size() > 0 else "1"

# ── 初始背包 ──
# 由调用方决定:单机 = 空表(开局空手,枪散落在地图上);联机 = 一条随机武器。
# ★ 排在任何 equip 之前调用。
func set_initial_inventory(types: Array) -> void:
	inventory.clear()
	_unequip()
	for t in types:
		if is_slot_enabled(int(t)):
			inventory.add(int(t), WeaponInventory.MAG_FULL)
	inventory_changed.emit()
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)

# ── 切枪 ──
# 滚轮/数字键都走背包**位置**,不再走"启用槽位表"。
func cycle_slot(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		# 无槽可切(只有一把 / 目标即当前):早退。与 request_net_cycle 同形;
		# 否则会白重建一次武器实例 + 响一声 switch(equip 每次都 instantiate)。
		return
	_equip_index(next)

func _peek_cycle(dir: int) -> int:
	var n := inventory.held.size()
	if n == 0:
		return -1
	var order: Array[int] = []
	for i in n:
		if is_slot_enabled(int(inventory.held[i]["type"])):
			order.append(i)
	if order.is_empty():
		return -1
	var idx := order.find(_current_index)
	if idx < 0:
		idx = 0
	return order[(idx + dir + order.size() * 2) % order.size()]

# ── PvP 滚轮切枪:本地立即切(即时反馈),目标槽位打包进输入包由服务器权威同步 ──
# (滚轮事件不在输入包协议里,只本地切会被快照的防脱同步切回旧槽位 →「只有音效」)
var _net_slot := 0   # 待发切枪槽位(>0 = 待发;打包后清零)

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	push_net_slot(int(inventory.held[next]["type"]))
	_equip_index(next)

func push_net_slot(slot: int) -> void:
	_net_slot = slot

func consume_net_slot() -> int:
	var v := _net_slot
	_net_slot = 0
	return v

# 按**类型 id**切枪(网络包/rollback 走这条)。
# ★ 背包里没有这个类型就**加入** —— 这不是便利,是必需:联机不做客户端预测时,
#   服务器说"你现在有重狙"而客户端背包里可能还没有它;restore_state 重放 wslot
#   会走到这条路径。容量不足时也照加:权威说有什么就是什么,超容由服务器负责。
func equip(slot: String) -> void:
	var type_id := int(slot)
	if not is_slot_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		idx = inventory.held.size()
		inventory.add(type_id, WeaponInventory.MAG_FULL)
		inventory_changed.emit()
	_equip_index(idx)

# 按背包位置切枪(数字键/滚轮走这条)。
func equip_index(i: int) -> void:
	_equip_index(i)

func _equip_index(index: int) -> void:
	if index < 0 or index >= inventory.held.size():
		return
	# 切枪继承旧武器剩余冷却:后摇不能被切枪取消(queue_free 前先捕获)
	var inherit_cd := 0.0
	if _weapon != null and is_instance_valid(_weapon):
		inherit_cd = _weapon.fire_cd_timer
		# 残弹写回条目。只认**已入树**的枪:同帧第二次切枪时,上一把枪还是 call_deferred
		# 未入树(其 _ready 未跑 → mag_ammo 仍是 0),照记会把残弹永久抹成 0。
		# 真机可达:滚轮走 _unhandled_input,一帧内缓冲的 OS 事件会一次性泵完。
		# 守卫只加在这里,不外扩:fire_cd_timer 由本函数同步写入(未入树也有效),
		# 而 queue_free 必须照跑,否则未入树的旧枪实例泄漏。
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
		_weapon = null
	var type_id := int(inventory.held[index]["type"])
	var scene: PackedScene = load(WEAPONS[str(type_id)])
	if scene == null:
		push_error("weapon scene not found: " + str(WEAPONS.get(str(type_id), "<无此槽>")))
		return
	if body == null or body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_current_index = index
	_current_slot = type_id
	_weapon = scene.instantiate() as WeaponBase
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
	var mag := int(inventory.held[index]["mag"])
	if mag != WeaponInventory.MAG_FULL:
		# 武器 _ready(入树时)会把 mag_ammo 重置为满:恢复必须排在 deferred add 之后
		_restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
	Sfx.play("switch")
	weapon_changed.emit(type_id)
	inventory_changed.emit()

# 空手:背包为空 / 当前那把被禁且没有别的可选。
func _unequip() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	weapon_changed.emit(0)
	inventory_changed.emit()

func _restore_mag(w: WeaponBase, ammo: int) -> void:
	if is_instance_valid(w):
		w.mag_ammo = ammo

# ── 拾取 / 丢弃 ──
# 拾取一把类型为 type_id、残弹为 mag 的枪。返回被**替换掉**的类型 id(0 = 没有替换)。
# ★ 替换规则(用户 2026-09-15 裁定):放不下(容量或 4 把上限)时替换**手上当前那把**,
#   被换下的那把由调用方负责生成掉落物(返回值就是它)。
func pick_up(type_id: int, mag: int) -> int:
	if not is_slot_enabled(type_id):
		Sfx.play("deny")
		return 0
	if inventory.can_hold(type_id):
		inventory.add(type_id, mag)
		inventory_changed.emit()
		_equip_index(inventory.held.size() - 1)
		return 0
	# 放不下 → 与手上那把交换。手上空着(背包空)时无处可换 —— 此时容量必然够
	# (空背包 used_slots()=0,任何 cost ≤ 4 ≤ 8),所以这条分支只在 _current_index < 0
	# 且背包非空(全被禁用)时才可能走到,直接拒绝即可。
	if _current_index < 0:
		Sfx.play("deny")
		return 0
	var dropped := int(inventory.held[_current_index]["type"])
	var dropped_mag := int(inventory.held[_current_index]["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		dropped_mag = _weapon.mag_ammo
	inventory.held[_current_index] = {"type": type_id, "inst": inventory.held[_current_index]["inst"], "mag": mag}
	_equip_index(_current_index)
	# 把被换下的那把"塞进"一个假条目,让调用方拿到残弹 —— 用返回值 + 一个查询口传递。
	_last_dropped = {"type": dropped, "mag": dropped_mag}
	return dropped

# pick_up() 换下的那把枪的残弹(返回值只带得回类型 id)。
var _last_dropped: Dictionary = {}

func take_last_dropped() -> Dictionary:
	var d := _last_dropped
	_last_dropped = {}
	return d

# 丢下手上当前那把。返回 {type, mag};空手时返回 {}。
func drop_current() -> Dictionary:
	if _current_index < 0:
		return {}
	var e: Dictionary = inventory.held[_current_index]
	var mag := int(e["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		mag = _weapon.mag_ammo
	var out := {"type": int(e["type"]), "mag": mag}
	inventory.remove_at(_current_index)
	_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()
	# 手上那把没了 → 自动拿背包里第一把(空手站着很怪);背包空则彻底空手。
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)
	else:
		weapon_changed.emit(0)
	return out

# 复活用:从背包**随机**保留一条,返回其余(供调用方在死亡点生成掉落物)。
# 背包为空时返回空表(保留的那把也就没有)。
func random_keep_one() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if inventory.held.is_empty():
		return out
	var keep := randi() % inventory.held.size()
	for i in range(0, inventory.held.size()):
		if i != keep:
			out.append(inventory.held[i].duplicate())
	inventory.held = [inventory.held[keep]]
	_equip_index(0)
	return out

# ── 快照 / 恢复(rollback 用)──
# ★ 与 mag_ammo/_reloading 同口径:进 capture/restore,**不进** _close_enough 的比对。
func snapshot_inventory() -> Array:
	_flush_current_mag()
	return inventory.snapshot()

func restore_inventory(entries: Array) -> void:
	inventory.restore(entries)
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()

func _flush_current_mag() -> void:
	if _weapon == null or not is_instance_valid(_weapon) or not _weapon.is_inside_tree():
		return
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = _weapon.mag_ammo

# ── 其余 ──
func reset_mag_state() -> void:
	# 残弹现在存在背包条目里,没有独立的记忆表可清 —— 保留本方法是为了:
	#   ① 调用方(player.restart_at)的边界不变;② 语义"把当前残弹同步进条目"。
	_flush_current_mag()

func refill_current_weapon() -> void:
	var w := _weapon
	if w != null:
		_refill_mag.call_deferred(w)

func _refill_mag(w: WeaponBase) -> void:
	if is_instance_valid(w):
		w.mag_ammo = w.mag_size
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = WeaponInventory.MAG_FULL

func current_weapon() -> WeaponBase:
	return _weapon

func current_slot_int() -> int:
	return _current_slot

func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

# 武器帧逻辑(冷却/缓冲开火/预瞄/后坐)由根每物理帧显式驱动:
# 保证与 body 跑在同一个固定 tick 上(rollback 重放需要确定性),不再依赖 idle _process。
func tick(delta: float) -> void:
	if _weapon != null:
		_weapon.tick(delta)

func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1  # 攀爬时后坐力降到 0.1(在梯/锁链上开火基本不后推)
	body.velocity.x -= body.facing_direction * push

func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()
```

- [ ] **Step 2: 改 `player.gd` 的初始装备为临时 3 把**

把 `scenes/player/player.gd:147` 的 `weapons.equip("1")` 替换为：

```gdscript
	# ★ 临时初始背包(3 把 = 2+3+3 = 8 格,刚好占满,顺带压容量边界)。
	#   这是**计划内的中间态**:地面拾取(Task 10/11)落地后这里会换成空表,
	#   单机改为"开局空手 + 12 把散落在地图上"。别为了让中间态好看而放宽容量闸门。
	weapons.set_initial_inventory([1, 2, 6])
```

- [ ] **Step 3: 跑 kh_l3 探针确认它变红**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn
```
Expected: 输出里**没有** `ALL-OK`（`_enabled_slots` / 残弹记忆两节的断言按旧语义写的，现在会红）。这一步确认探针真的在跑、真的能变红。

- [ ] **Step 4: 按新语义重写探针里的两节**

在 `tests/kh_l3_probe.gd` 里：

① 把 `_enabled_slots` 一节里"滚轮跳过禁用槽"的断言改为按**背包位置**判定：先 `wep.set_initial_inventory([1, 2, 3, 4, 5, 6])` 不可行（超容），改用 `wep.set_initial_inventory([1, 3])`（手枪 2 格 + 重狙 4 格 = 6 格，2 把），然后：
- `wep.cycle_slot(1)` 从位置 0 应到位置 1（类型 3）
- `wep.set_enabled_slots([3])` 后（禁用重狙），`cycle_slot(1)` 应停在位置 0（只剩一把可切，早退）
- `_check(wep.current_slot_int() == 1, ...)`

② 把"残弹记忆"一节改成 per-inst：`set_initial_inventory([1, 3])` → 打掉几发 → `equip_index(1)` → 再 `equip_index(0)` → 断言残弹不是满的、且**第二把的残弹不受影响**。

③ 新增反向断言（防止旧机制复活）：

```gdscript
	# 反向断言:_mag_state 一族不许复活。残弹现在按**背包条目**记(每条一个 inst),
	# 复活旧的"按槽位号记账"表 = 两套残弹记账并存 = 同类型两把必然串弹。
	# ★ 只断言 _mag_state 这一个标识符:_restore_mag / reset_mag_state 在本次改动里是
	#   **保留**的(前者是入树后恢复残弹的延迟回调,后者已改成写回条目),别一起断言掉。
	var src_text: String = ScanUtil.read("res://scenes/player/weapon_component.gd")
	_check(not src_text.contains("_mag_state"),
		"weapon_component.gd 里不应再有 _mag_state(残弹已改按背包条目记)")
```

（`ScanUtil.read_text` 是 `tests/lib/scan_util.gd` 的既有静态读文件助手；若该探针用的是别的读源方式，照它自己的写。）

- [ ] **Step 5: 跑探针确认 ALL-OK**

Run: 同 Step 3
Expected: 输出里出现 `ALL-OK`。

- [ ] **Step 6: 提交**

```bash
git add scenes/player/weapon_component.gd scenes/player/player.gd tests/kh_l3_probe.gd
git commit -m "refactor(weapons): WeaponComponent 换成背包模型 —— 容量/替换/按 inst 记残弹,删 _mag_state"
```

---

### Task 4: 输入管线（F/Q 动作、键位 1-4、滚轮默认开）

**Files:**
- Modify: `project.godot`（`[input]` 段加两个动作）
- Modify: `core/config/settings.gd:10,23`
- Modify: `core/net/player_input.gd`（两个新读口 + 两个钩子）
- Modify: `core/net/local_input_source.gd`、`core/net/packet_input_source.gd`、`core/net/ai_input_source.gd`
- Test: `tests/ai_input_source_smoke.gd`（补 frozen 断言）

**Interfaces:**
- Consumes: Task 3 的 `inventory`
- Produces:
  - `PlayerInput.is_pickup_pressed() -> bool`、`is_drop_pressed() -> bool`（公开读口，受 `frozen` 短路）；钩子 `_pickup_pressed_raw()`、`_drop_pressed_raw()`
  - `PacketInputSource.BIT_PICKUP := 32`、`BIT_DROP := 64`
  - `_weapon_slot_raw()` 三个实现一律只返回 1-4

- [ ] **Step 1: 加输入动作**

在 `project.godot` 的 `[input]` 段里，与其它动作同样的格式追加两条（放在 `R={...}` 附近）：

```
F={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":70,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
Q={
"deadzone": 0.2,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":81,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

★ 直接照抄 `R` 那一项的写法（含 `physical_keycode` 风格），只改名字与 `physical_keycode`（F=70、Q=81）。改完用编辑器打开项目确认两个动作在 项目设置 → 输入映射 里可见。

- [ ] **Step 2: 改 `settings.gd`**

`core/config/settings.gd:10`：

```gdscript
const REMAPPABLE_ACTIONS: Array[String] = ["left", "right", "up", "down", "charge", "attack", "R", "F", "Q"]
```

`core/config/settings.gd:23`：`wheel_switch` 默认改 `true`（2026-09-15：用户要求滚轮切枪直接可用；此前默认 false 等于该功能形同虚设）。

- [ ] **Step 3: 加两个读口与钩子**

`core/net/player_input.gd`，在 `get_weapon_slot_pressed()` 之后加公开读口：

```gdscript
# 拾取 / 丢弃(F 的按下边沿;Q 长按满阈值后的那一次边沿)。
# ★ 与其它读口同款:冻结一律在此短路,子类不得覆写这两个(覆写即绕开冻结)。
func is_pickup_pressed() -> bool:
	return not frozen and _pickup_pressed_raw()

func is_drop_pressed() -> bool:
	return not frozen and _drop_pressed_raw()
```

在 `_weapon_slot_raw()` 的兜底之后加钩子：

```gdscript
func _pickup_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _pickup_pressed_raw()")
	return false

func _drop_pressed_raw() -> bool:
	push_error("PlayerInput: 子类必须覆写 _drop_pressed_raw()")
	return false
```

- [ ] **Step 4: 三个实现**

`core/net/local_input_source.gd` —— 把 `_weapon_slot_raw()` 换成只认 1-4，并加两个钩子：

```gdscript
func _weapon_slot_raw() -> int:
	# ★ 只认 1-4:持有位上限是 4(WeaponInventory.MAX_WEAPONS)。
	#   5/6 的 InputMap 动作**保留不删**(以后想开第 5 个位时不必再动 project.godot),
	#   但这里不读它们 —— 读了就会切到一个不存在的背包位置。
	for i in range(1, 5):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0

func _pickup_pressed_raw() -> bool:
	return Input.is_action_just_pressed("F")

func _drop_pressed_raw() -> bool:
	# Q 的长按计时在 player.gd 里做(那里才有物理帧),这里只报"是否按着"。
	# 本函数的返回值由 player.gd 覆写包装 —— 见 player.gd 的 _poll_drop_hold()。
	return Input.is_action_pressed("Q")
```

`core/net/ai_input_source.gd` —— 加两个常量钩子：

```gdscript
func _pickup_pressed_raw() -> bool:
	return false   # AI 不捡枪(大乱斗补位 AI 只用开局随机发的那把)

func _drop_pressed_raw() -> bool:
	return false   # AI 不丢枪
```

并把它的 `_weapon_slot_raw()` 上界同样收到 4。

`core/net/packet_input_source.gd` —— 加位常量、编解码、两个钩子：

```gdscript
const BIT_PICKUP := 32
const BIT_DROP := 64
```

`pack_record()` 里 `held`/`pressed`/`released` 三段各加两行（照 `BIT_RELOAD` 的写法）：

```gdscript
	if src.is_pickup_pressed():
		pressed |= BIT_PICKUP
	if src.is_drop_pressed():
		pressed |= BIT_DROP
```

★ **`held` 段不要加**：F/Q 都是边沿语义，没有"按住"的语义（Q 的长按在客户端本地判定，见 Task 10）。

`_weapon_slot_raw()` 上界同样收到 4。新增：

```gdscript
func _pickup_pressed_raw() -> bool:
	return (_pressed & BIT_PICKUP) != 0

func _drop_pressed_raw() -> bool:
	return (_pressed & BIT_DROP) != 0
```

（`_pressed` 用本文件里 `pressed` 位的既有字段名；`clear_edges()` 里这两位的清理随 `pressed` 整段清，无需单独加。）

**本步的注释里要写明**：加位 = 改协议，两端必须同版本。

- [ ] **Step 5: 补 frozen 断言**

在 `tests/ai_input_source_smoke.gd` 既有的 `frozen:` 断言组里追加两条：

```gdscript
	_check(src.is_pickup_pressed() == false, "frozen:is_pickup_pressed 为 false")
	_check(src.is_drop_pressed() == false, "frozen:is_drop_pressed 为 false")
```

- [ ] **Step 6: 跑冒烟**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/ai_input_source_smoke.gd
"$GODOT" --headless --path . --quit-after 3600
```
Expected: 冒烟全绿；启动 0 报错（若报 "Unknown action" 说明 `project.godot` 的两个动作没加对）。

- [ ] **Step 7: 提交**

```bash
git add project.godot core/config/settings.gd core/net/player_input.gd core/net/local_input_source.gd core/net/packet_input_source.gd core/net/ai_input_source.gd tests/ai_input_source_smoke.gd
git commit -m "feat(input): F/Q 动作 + 拾取/丢弃读口 + 键位收到 1-4 + 滚轮切枪默认开"
```

---

### Task 5: 4×2 格子 HUD 控件

**Files:**
- Modify: `ui/ui_factory.gd`（加三个颜色常量）
- Create: `ui/weapon_slots.gd`
- Modify: `ui/hud.gd`（左下角接线）
- Test: `tests/kh_l3_visual_probe.gd`（加取色断言）

**Interfaces:**
- Consumes: Task 3 的 `inventory` / `weapon_changed` / `inventory_changed`
- Produces: `class_name WeaponSlots extends Control`；`setup(weapons: WeaponComponent) -> void`、`refresh() -> void`；静态 `WeaponSlots.attach_to(parent: Node, weapons: WeaponComponent) -> WeaponSlots`

- [ ] **Step 1: 加颜色常量**

在 `ui/ui_factory.gd` 的颜色常量组里加：

```gdscript
# 武器槽位格子的三态(2026-09-15 加,用户指定"未占淡灰 / 已占淡青 / 手持深青")。
# ★ "深青"按**高饱和/更醒目**实现,不按"更暗":格子垫在不透明深底板上(panel_box),
#   若手持格比已占格更暗,视觉上反而更弱,会出现"当前武器最不显眼"的倒挂。
#   真正的不变量是:**手持格必须比已占格对比度更高**。改色前先按这一条量。
const C_SLOT_EMPTY := Color("333b45")    # 未占据:淡灰
const C_SLOT_FILLED := Color("7fb8b8")   # 已占据:淡青
const C_SLOT_ACTIVE := Color("2f9e9e")   # 手持那把占的格:深青(高饱和)
```

- [ ] **Step 2: 写控件**

创建 `ui/weapon_slots.gd`：

```gdscript
class_name WeaponSlots
extends Control

# 4×2 武器槽位格子(左下角)。每格代表 1 格容量,武器按**紧凑排布**占据连续的格子
# (见 WeaponInventory.slot_start)。
#
# ★ 自包含:能自己 new() 出来挂到任意 CanvasLayer 下。**不依赖任何 HUD 的继承关系** ——
#   PvpHud 与 RoyaleHud 是并列的两个 `extends CanvasLayer`,没有继承关系,
#   不存在"大乱斗复用 PvP 那块"这条路。定位常量在本文件里,三处引用同一组值。

const COLS := 4
const ROWS := 2
const CELL := 32.0        # 格子边长(16 的倍数)
const GAP := 4.0          # 格间距
const PAD := 8.0          # 底板内边距

const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0   # 164
const PANEL_H := ROWS * CELL + (ROWS - 1) * GAP + PAD * 2.0   # 84

const PLATE_COLOR := Color(0, 0, 0, 0.1)   # 与全局 HUD 底板同值(黑 0.1)

var _weapons: WeaponComponent = null

# 便捷挂载:建实例 + 定位 + 接线。三处 HUD 都用它,保证位置一致。
static func attach_to(parent: Node, weapons: WeaponComponent) -> WeaponSlots:
	var s := WeaponSlots.new()
	s.setup(weapons)
	parent.add_child(s)
	# 左下角,与 ui/hud.gd 的武器区同一组锚点(anchor_bottom=1 + 负 offset)
	s.anchor_left = 0.0
	s.anchor_right = 0.0
	s.anchor_top = 1.0
	s.anchor_bottom = 1.0
	s.offset_left = 16.0
	s.offset_top = -112.0 - PANEL_H - 8.0
	s.offset_right = s.offset_left + PANEL_W
	s.offset_bottom = s.offset_top + PANEL_H
	return s

func setup(weapons: WeaponComponent) -> void:
	_weapons = weapons
	custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _weapons != null:
		_weapons.weapon_changed.connect(func(_s: int) -> void: refresh())
		_weapons.inventory_changed.connect(refresh)
	refresh()

func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	# 底板(与全局 HUD 底板同值;这里画在 _draw 里,不再套一层 PanelContainer ——
	# Control 自绘比容器嵌套少一层节点,且不会影响 HUD 的既有版式)
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, PANEL_H)), PLATE_COLOR, true)

	var held: Array = []
	var active_index := -1
	var starts: Array[int] = []
	if _weapons != null:
		held = _weapons.inventory.held
		active_index = _weapons._current_index
		for i in held.size():
			starts.append(_weapons.inventory.slot_start(i))

	# 8 格的所属武器下标(-1 = 未占)
	var owner_of: Array[int] = []
	owner_of.resize(WeaponInventory.CAPACITY)
	owner_of.fill(-1)
	for i in held.size():
		var cost := _weapons.inventory.cost_of(int(held[i]["type"]))
		for c in range(starts[i], starts[i] + cost):
			if c < WeaponInventory.CAPACITY:
				owner_of[c] = i

	for cell in WeaponInventory.CAPACITY:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		var oi: int = owner_of[cell]
		var col_c := UiFactory.C_SLOT_EMPTY
		if oi >= 0:
			col_c = UiFactory.C_SLOT_ACTIVE if oi == active_index else UiFactory.C_SLOT_FILLED
		draw_rect(Rect2(p, Vector2(CELL, CELL)), col_c, true)
```

- [ ] **Step 3: 单机 HUD 接线**

`ui/hud.gd`：在 `_build_weapon_display(p)` 的末尾（`box.add_child(_ammo_label)` 之后）追加：

```gdscript
	# 4×2 武器槽位格子,挂在同一个底板上、武器区上方
	_slots = WeaponSlots.attach_to(wrap, p.weapons)
	_slots.anchor_top = 0.0
	_slots.anchor_bottom = 0.0
	_slots.offset_left = 12.0
	_slots.offset_top = 0.0
	_slots.offset_right = 12.0 + WeaponSlots.PANEL_W
	_slots.offset_bottom = WeaponSlots.PANEL_H
	_slots.position = Vector2.ZERO
```

并在字段声明区加 `var _slots: WeaponSlots = null`。
★ 边做边看：`PanelContainer` 的子节点受容器布局管，自由 `offset_*` 可能被覆盖。若定位不生效，改为把 `_slots` 加到 `_build_weapon_display` 建的那个 `wrap` 的**父节点**（`self`）上、并自行算好绝对位置——判据是**格子块出现在武器区正上方且不重叠**，用 Task 的截图步骤确认。

- [ ] **Step 4: 跑视觉探针（改之前先跑一次拿基线）**

Run:
```bash
"$GODOT" --headless=false --path . res://tests/kh_l3_visual_probe.tscn
```
（该探针必须真实渲染；按它文件头记的跑法执行，取图落盘。）
Expected: 先看基线图，确认格子块位置可用。

- [ ] **Step 5: 加取色断言**

在 `tests/kh_l3_visual_probe.gd` 里按既有的 `_bright_in`/`_gold_in`/`_accent_in` 写法加三个语义判定，**双向**断言：

```gdscript
	# 格子三态:未占=灰、已占=青、手持那把的格=高对比度青。
	# ★ 双向:该青的地方必须青,**不该青的地方一个都不能有**(否则"全画成青色"也能过)。
	_check(_slot_color_in(img, 1, UiFactory.C_SLOT_ACTIVE), "手持那把应占的格是深青(高饱和)")
	_check(_slot_color_in(img, 0, UiFactory.C_SLOT_FILLED), "已占据的格是淡青")
	_check(_slot_color_in(img, 7, UiFactory.C_SLOT_EMPTY), "未占据的格是淡灰")
	# 反向:手持格**不得**是淡青(两者必须区分得开,否则玩家看不出哪把在手上)
	_check(not _slot_color_in(img, 1, UiFactory.C_SLOT_FILLED), "手持格不应等于已占格颜色")
```

`_slot_color_in(img, cell_index, want: Color) -> bool` 按格子中心像素取色、容许小量色差（照该文件既有取色助手的容差写法）。探针要先构造一个已知背包状态（`p.weapons.set_initial_inventory([1, 3])` → 手枪占格 0/1、重狙占格 2..5，手持 = 手枪 → 格 0/1 深青、格 2..5 淡青、格 6/7 淡灰）再取图。

- [ ] **Step 6: 跑探针确认 ALL-OK**

Run: 同 Step 4
Expected: 输出 `ALL-OK`，且新加的三条双向断言全过。

- [ ] **Step 7: 提交**

```bash
git add ui/ui_factory.gd ui/weapon_slots.gd ui/hud.gd tests/kh_l3_visual_probe.gd
git commit -m "feat(ui): 4x2 武器槽位格子控件(三态配色)+ 单机 HUD 接线 + 取色双向断言"
```

---

### Task 6: `SpriteBounds` 像素包围盒

**Files:**
- Create: `core/present/sprite_bounds.gd`
- Test: `tests/sprite_bounds_smoke.gd`

**Interfaces:**
- Consumes: 无
- Produces: `class_name SpriteBounds extends RefCounted`；静态 `from_sprite(spr: Sprite2D, alpha_threshold: float = 0.05) -> Rect2`（以 sprite 局部原点为参考）

- [ ] **Step 1: 写失败的测试**

创建 `tests/sprite_bounds_smoke.gd`：

```gdscript
extends SceneTree

# SpriteBounds 冒烟:像素包围盒。跑法与 weapon_inventory_smoke 同。
# 用运行时生成的贴图当输入,不依赖任何美术资产。

var _fail := 0

func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)

func _make_tex(w: int, h: int, filled: Rect2i) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for y in range(filled.position.y, filled.position.y + filled.size.y):
		for x in range(filled.position.x, filled.position.x + filled.size.x):
			img.set_pixel(x, y, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(img)

func _initialize() -> void:
	var SB: GDScript = load("res://core/present/sprite_bounds.gd")

	# ── 无 region:包围盒应贴合实心区 ──
	var spr := Sprite2D.new()
	spr.texture = _make_tex(32, 16, Rect2i(4, 2, 20, 10))
	var r: Rect2 = SB.from_sprite(spr)
	# sprite 局部原点是贴图中心(默认 centered=true),故实心区左上角 = (4,2) - (16,8) = (-12,-6)
	_check(is_equal_approx(r.position.x, -12.0) and is_equal_approx(r.position.y, -6.0),
		"包围盒左上角应为 (-12,-6),实际 %s" % str(r.position))
	_check(is_equal_approx(r.size.x, 20.0) and is_equal_approx(r.size.y, 10.0),
		"包围盒尺寸应为 (20,10),实际 %s" % str(r.size))
	spr.free()

	# ── 全透明贴图:返回空矩形,不返回"整张贴图" ──
	var spr2 := Sprite2D.new()
	spr2.texture = _make_tex(16, 16, Rect2i(0, 0, 0, 0))
	var r2: Rect2 = SB.from_sprite(spr2)
	_check(r2.size == Vector2.ZERO, "全透明贴图应返回空矩形,实际 %s" % str(r2.size))
	spr2.free()

	# ── region_enabled:只扫 region 内,坐标系仍以 sprite 原点为参考 ──
	var spr3 := Sprite2D.new()
	spr3.texture = _make_tex(64, 16, Rect2i(40, 2, 20, 10))
	spr3.region_enabled = true
	spr3.region_rect = Rect2(32, 0, 32, 16)
	var r3: Rect2 = SB.from_sprite(spr3)
	# region 左上角 (32,0) 映射到 sprite 的 (-16,-8)(region 尺寸 32x16 → 半尺寸 16x8)
	# 实心区在 region 内偏移 (8,2) → sprite 局部 (-8,-6),尺寸 (20,10)
	_check(is_equal_approx(r3.position.x, -8.0) and is_equal_approx(r3.position.y, -6.0),
		"region 包围盒左上角应为 (-8,-6),实际 %s" % str(r3.position))
	_check(is_equal_approx(r3.size.x, 20.0) and is_equal_approx(r3.size.y, 10.0),
		"region 包围盒尺寸应为 (20,10),实际 %s" % str(r3.size))
	spr3.free()

	# ── 无贴图:返回空矩形,不崩 ──
	var spr4 := Sprite2D.new()
	var r4: Rect2 = SB.from_sprite(spr4)
	_check(r4.size == Vector2.ZERO, "无贴图应返回空矩形")
	spr4.free()

	if _fail == 0:
		print("SMOKE OK")
		quit(0)
	else:
		print("SMOKE FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑测试确认它失败**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/sprite_bounds_smoke.gd
```
Expected: FAIL —— `core/present/sprite_bounds.gd` 不存在，`SB` 为 null。

- [ ] **Step 3: 写最小实现**

创建 `core/present/sprite_bounds.gd`：

```gdscript
class_name SpriteBounds
extends RefCounted

# 从 Sprite2D 的像素求"哪一块真的画了东西"的包围盒。
# 用途:地面武器(WeaponPickup)的碰撞箱 —— 武器 tscn 里没有碰撞体,手画 6 个矩形
# 既烦又会在换贴图后失真,所以按 alpha 自动求。
#
# ★ 参考系:返回的 Rect2 以 **sprite 的局部原点**为参考(不是贴图坐标系)。
#   Sprite2D 默认 centered,原点在贴图中心;region_enabled 时原点在 region 中心。
#
# ★ 与**手持态**的差异:weapon_base 的 sprite 有 _base_sprite_pos 偏移、换弹/后坐抖动
#   (weapon_base.gd:134)与 facing 的 scale.x。地面态一律取 **facing=1、无抖动** 的基准,
#   所以本工具只吃 sprite 本身,不吃那些运行时偏移。

static var _cache: Dictionary = {}

static func from_sprite(spr: Sprite2D, alpha_threshold: float = 0.05) -> Rect2:
	if spr == null or spr.texture == null:
		return Rect2()
	var tex := spr.texture
	var region := Rect2i()
	if spr.region_enabled:
		region = Rect2i(spr.region_rect)
	else:
		region = Rect2i(0, 0, tex.get_width(), tex.get_height())
	if region.size.x <= 0 or region.size.y <= 0:
		return Rect2()

	var key := "%d:%s" % [tex.get_instance_id(), str(region)]
	if _cache.has(key):
		return _cache[key]

	var img := tex.get_image()
	if img == null:
		return Rect2()
	if img.is_compressed():
		img.decompress()

	# 逐像素扫 alpha 求包围盒。武器贴图是 32px 级的小图,一次扫描开销可忽略,
	# 且结果进 _cache(同一贴图只扫一次)。
	var min_x := region.size.x
	var min_y := region.size.y
	var max_x := -1
	var max_y := -1
	for y in region.size.y:
		for x in region.size.x:
			if img.get_pixel(region.position.x + x, region.position.y + y).a > alpha_threshold:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < 0:
		_cache[key] = Rect2()
		return Rect2()

	# region 坐标 → sprite 局部坐标:减去 region 中心(centered 语义)
	var half := Vector2(region.size) * 0.5
	var out := Rect2(Vector2(min_x, min_y) - half, Vector2(max_x - min_x + 1, max_y - min_y + 1))
	_cache[key] = out
	return out
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: `SMOKE OK`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add core/present/sprite_bounds.gd tests/sprite_bounds_smoke.gd
git commit -m "feat(present): SpriteBounds —— 按 sprite 像素 alpha 求包围盒(地面武器碰撞箱的来源)"
```

---

### Task 7: `WeaponPickup` 地面武器实体

**Files:**
- Create: `scenes/weapons/weapon_pickup.gd`
- Create: `scenes/weapons/weapon_pickup.tscn`
- Modify: `core/config/player_params.gd`（落地物理参数）
- Test: `tests/weapon_pickup_probe.tscn` + `.gd`

**Interfaces:**
- Consumes: Task 6 的 `SpriteBounds.from_sprite`
- Produces: `class_name WeaponPickup extends CharacterBody2D`；字段 `type_id: int`、`inst: int`、`mag: int`、`drop_velocity: Vector2`；方法 `configure(type_id, inst, mag, vel) -> void`；组 `weapon_pickup`；碰撞层 8 / 掩码 9

- [ ] **Step 1: 加参数**

在 `core/config/player_params.gd` 的武器相关段落加：

```gdscript
# ── 武器拾取 / 丢弃(2026-09-15)──
const weapon_pickup_radius := 64.0        # 可拾取半径(1 格)
const weapon_drop_hold_time := 2.0        # 长按 Q 多久算丢弃(用户指定 2s)
const weapon_drop_speed := 400.0          # 丢弃初速(水平,朝朝向)
const weapon_drop_up := 220.0             # 丢弃初速(向上)
const weapon_drop_offset := Vector2(24.0, -8.0)   # 掉落物生成点相对玩家的偏移
const weapon_ground_friction := 12.0      # 落地摩擦(指数衰减率;"较大"= 很快停住)
const weapon_air_drag := 0.4              # 空中阻力
const weapon_fall_gravity := 1600.0       # 落体重力
const weapon_stop_eps := 6.0              # 水平速度低于此值即置零(见下面「停止位置与起始时刻无关」)
```

- [ ] **Step 2: 写实体脚本**

创建 `scenes/weapons/weapon_pickup.gd`：

```gdscript
class_name WeaponPickup
extends CharacterBody2D

# 地上的武器(可被按 F 捡起)。
#
# ★ 为什么是**独立场景**而不是"给武器场景加个落地模式":手持武器与地面武器是两种
#   生命周期完全不同的东西 —— 前者挂 Player 下、由玩家驱动 tick、开火;后者是世界实体、
#   自己走物理、只被捡起查询。合成一个类就要在 WeaponBase 里塞满 "我在地上吗" 的分支。
#   分开后有一条不可能搞错的不变量:**手持武器永远没有碰撞体,地面武器永远有**。
#
# ★ 视觉复用武器场景实例:WeaponBase **没有 _process/_physics_process**(tick 由玩家显式驱动),
#   所以一个没人驱动的武器实例天然静止,直接当哑视觉体挂进来即可,不必另做一套地面外观。

const GROUP := "weapon_pickup"

# 掉落物碰撞层 = 层 4(值 8)。掩码只含地形(1)与其它掉落物(8):
#   · 玩家 mask=5、敌人 mask 不含 4 → 天然不碰(不会被地上的枪挡住)
#   · 子弹 mask=5 也不含 4 → 天然穿过(地上的枪不挡子弹)
# ★ 改这两个数之前先看 player.tscn / bullet_base 的掩码,别顺手 |= 进来。
const LAYER_GROUND := 8
const MASK_GROUND := 9

# 世界缩放。武器挂在 Player 下时继承根的 scale=2.5(player.tscn:123),落到世界里
# 就得自己补上,否则视觉小 2.5 倍。★ 这个数字全项目只此一处。
const WORLD_SCALE := 2.5

@export var type_id: int = 1
var inst: int = 0
var mag: int = 0
var drop_velocity: Vector2 = Vector2.ZERO
var _settled: bool = false

func _ready() -> void:
	add_to_group(GROUP)
	collision_layer = LAYER_GROUND
	collision_mask = MASK_GROUND
	scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	rotation = 0.0            # 不旋转:矩形碰撞箱 + 横版简化
	_build_visual()
	_build_collision()
	velocity = drop_velocity

# 由生成方调用(必须在 add_child 之前或之后都行 —— 之后调用会重新建视觉)。
func configure(p_type_id: int, p_inst: int, p_mag: int, p_vel: Vector2) -> void:
	type_id = p_type_id
	inst = p_inst
	mag = p_mag
	drop_velocity = p_vel
	velocity = p_vel
	if is_inside_tree():
		for c in get_children():
			c.queue_free()
		_build_visual()
		_build_collision()

func _build_visual() -> void:
	var scene: PackedScene = load(WeaponComponent.WEAPONS.get(str(type_id), ""))
	if scene == null:
		return
	var w: Node2D = scene.instantiate()
	w.name = "Visual"
	# 哑视觉:朝向固定为右、不参与任何驱动(WeaponBase 没有 _process,不 tick 就是静止的)。
	# ★ 不要在这里写 w.player = null —— WeaponBase.player 默认就是 null(没人调过 equip),
	#   而按类型标注的 Node2D 动态写一个不存在的属性会在运行时炸。
	w.scale = Vector2.ONE
	w.rotation = 0.0
	add_child(w)

func _build_collision() -> void:
	var vis := get_node_or_null("Visual")
	if vis == null:
		return
	var spr: Sprite2D = vis.get_node_or_null("Sprite2D")
	if spr == null:
		return
	var r: Rect2 = SpriteBounds.from_sprite(spr)
	if r.size == Vector2.ZERO:
		return
	var poly := CollisionShape2D.new()
	poly.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = r.size
	poly.shape = rect
	poly.position = r.position + r.size * 0.5 + spr.position
	add_child(poly)

func _physics_process(delta: float) -> void:
	if _settled:
		return
	velocity.y += PlayerParams.weapon_fall_gravity * delta
	if is_on_floor():
		velocity.x *= exp(-PlayerParams.weapon_ground_friction * delta)
	else:
		velocity.x *= exp(-PlayerParams.weapon_air_drag * delta)
	move_and_slide()
	# 环面:取模回 canonical(渲染侧再锚到玩家最近副本)
	var gs := Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position = Vector2(fposmod(global_position.x, gs.x), fposmod(global_position.y, gs.y))
	# ★ 停止必须是"速度阈值置零"而不是"滑固定时长":前者让**落点与何时开始模拟无关**,
	#   这是联机端"客户端晚一个 RTT 才收到事件、却要落在同一位置"的前提。
	#   改成按时间停 → 两端落点发散 → 出现"看着够不着/看着够得着"。
	if is_on_floor() and absf(velocity.x) < PlayerParams.weapon_stop_eps:
		velocity = Vector2.ZERO
		_settled = true
```

- [ ] **Step 3: 建场景**

创建 `scenes/weapons/weapon_pickup.tscn`：

```
[gd_scene load_steps=2 format=3 uid="uid://bwpn0pickup001"]

[ext_resource type="Script" path="res://scenes/weapons/weapon_pickup.gd" id="1_pickup"]

[node name="WeaponPickup" type="CharacterBody2D"]
collision_layer = 8
collision_mask = 9
script = ExtResource("1_pickup")
```

★ `uid` 必须**唯一**（新建文件时用编辑器保存一次会自动分配；手写的话随便取一个不冲突的即可）。建完用 `--import` 刷一次资源数据库：
```bash
"$GODOT" --headless --path . --import
```

- [ ] **Step 4: 建探针场景并写断言**

创建 `tests/weapon_pickup_probe.gd`（`extends Node`）与 `tests/weapon_pickup_probe.tscn`（根节点挂该脚本）。`_ready()` 里真建一个 `WeaponPickup` 并断言：

```gdscript
# 地面武器探针:钉三件日常看不出来的事。
#   ① 碰撞层/掩码归属(玩家与子弹都不该碰它)
#   ② 视觉有碰撞箱(像素包围盒真的生成了)
#   ③ 落点与"何时开始模拟"无关(联机不预测落体的前提)
# 跑法:
#   "…console.exe" --headless --path . --quit-after 3600 res://tests/weapon_pickup_probe.tscn
# 判据:grep 输出里的 ALL-OK
```

断言要点（按本仓探针的 `_check`/`_summary` 写法）：

```gdscript
	# ① 层与掩码
	_check(pickup.collision_layer == 8, "地面武器应在层 4(值 8)")
	_check(pickup.collision_mask == 9, "地面武器掩码应为 地形|掉落物 = 9")
	_check((pickup.collision_mask & 2) == 0, "地面武器不得与玩家(层2)碰撞")
	_check((pickup.collision_mask & 4) == 0, "地面武器不得与敌人(层3)碰撞")
	# 反向:玩家的掩码里也不该出现掉落物层(一改就是"玩家被地上的枪挡住")
	var player := preload("res://scenes/player/player.tscn").instantiate()
	_check((player.collision_mask & 8) == 0, "玩家掩码不应含掉落物层")
	# 子弹同理
	var bullet_src := FileAccess.get_file_as_string("res://scenes/weapons/bullet_base.gd")
	_check(not bullet_src.contains("collision_mask = 9"), "子弹掩码不应被改成含掉落物层")

	# ② 像素碰撞箱真的建出来了
	_check(pickup.get_node_or_null("Shape") != null, "应按 sprite 像素生成 CollisionShape2D")
	# ③ 落点一致性:两个同初速、**不同延迟启动**的掉落物,最终横坐标应一致(容差 1px)
```

③ 的做法：建两个 `WeaponPickup`，同样的 `configure(1, 1, 0, Vector2(400, -220))`，第二个延迟 30 个物理帧后再 `configure` 同样初速，等两者 `_settled` 都变 true，比较 `global_position.x`，容差 1px。

- [ ] **Step 5: 跑探针**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_pickup_probe.tscn
```
Expected: 输出 `ALL-OK`，退出码 0。

- [ ] **Step 6: 提交**

```bash
git add scenes/weapons/weapon_pickup.gd scenes/weapons/weapon_pickup.tscn core/config/player_params.gd tests/weapon_pickup_probe.gd tests/weapon_pickup_probe.tscn
git commit -m "feat(weapons): WeaponPickup 地面武器实体 —— 独立碰撞层 + 像素碰撞箱 + 落点与起始时刻无关"
```

---

### Task 8: `GroundWeaponField` 拾取查询

**Files:**
- Create: `core/sim/ground_weapon_field.gd`
- Test: `tests/ground_weapon_field_smoke.gd`

**Interfaces:**
- Consumes: `GridPathfinder.toroidal_delta_px`
- Produces: `class_name GroundWeaponField extends RefCounted`；`add(entry: Dictionary) -> void`（`{inst, type_id, mag, pos, vel}`）、`remove(inst) -> Dictionary`、`get_entry(inst) -> Dictionary`、`size() -> int`、`clear() -> void`、`nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary`（无则 `{}`）

- [ ] **Step 1: 写失败的测试**

创建 `tests/ground_weapon_field_smoke.gd`：

```gdscript
extends SceneTree

# 地面武器表冒烟:环面最近拾取 + 并列确定性。
var _fail := 0

func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)

func _initialize() -> void:
	var GW: GDScript = load("res://core/sim/ground_weapon_field.gd")
	var f = GW.new()
	# 地图 640x480(用两格宽的假地图,验跨接缝)
	f.map_size = Vector2(640, 480)

	f.add({"inst": 1, "type_id": 1, "mag": 5, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	f.add({"inst": 2, "type_id": 3, "mag": 5, "pos": Vector2(130, 100), "vel": Vector2.ZERO})
	f.add({"inst": 3, "type_id": 5, "mag": 5, "pos": Vector2(620, 100), "vel": Vector2.ZERO})

	# ── 环面最短距离:玩家在 (5,100),id=3 在 (620,100) —— 直线距离 615,
	#    但绕接缝只有 25 格像素,比 id=1 的 95 更近 ──
	var near: Dictionary = f.nearest_within(Vector2(5, 100), 64.0)
	_check(not near.is_empty() and int(near["inst"]) == 3,
		"跨接缝时最近的是绕过去的那把(实际 %s)" % str(near.get("inst", "<无>")))

	# ── 半径外不选中 ──
	var far: Dictionary = f.nearest_within(Vector2(300, 400), 64.0)
	_check(far.is_empty(), "半径外应返回空字典")

	# ── 并列时按 inst 升序(确定性:两台客户端必须挑中同一把) ──
	var f2 = GW.new()
	f2.map_size = Vector2(640, 480)
	f2.add({"inst": 7, "type_id": 1, "mag": 0, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	f2.add({"inst": 4, "type_id": 2, "mag": 0, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	var tie: Dictionary = f2.nearest_within(Vector2(100, 100), 64.0)
	_check(int(tie["inst"]) == 4, "完全重合时取 inst 小的(实际 %s)" % str(tie.get("inst", "<无>")))

	# ── exclude 不参与判定(刚丢下的枪不该被自己立刻捡回) ──
	var ex: Dictionary = f2.nearest_within(Vector2(100, 100), 64.0, [4])
	_check(int(ex["inst"]) == 7, "exclude 里的 inst 不参与判定(实际 %s)" % str(ex.get("inst", "<无>")))

	# ── 增删查 ──
	_check(f.size() == 3, "add 后 size = 3")
	var gone: Dictionary = f.remove(1)
	_check(int(gone["type_id"]) == 1, "remove 返回被删条目")
	_check(f.size() == 2 and f.get_entry(1).is_empty(), "remove 后查不到")
	f.clear()
	_check(f.size() == 0, "clear 清空")

	if _fail == 0:
		print("SMOKE OK")
		quit(0)
	else:
		print("SMOKE FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑测试确认它失败**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/ground_weapon_field_smoke.gd
```
Expected: FAIL —— `core/sim/ground_weapon_field.gd` 不存在。

- [ ] **Step 3: 写最小实现**

创建 `core/sim/ground_weapon_field.gd`：

```gdscript
class_name GroundWeaponField
extends RefCounted

# 场上地面武器的**纯逻辑表**(服务器与单机各持一个实例;客户端侧另有一份只读的)。
# 不碰节点 —— 建/删 WeaponPickup 由持有方负责。
#
# ★ 「多把武器距离太近、捡不起来某些枪」的解法在 nearest_within 的**调用约定**上:
#   调用方一次只捡**最近的一把**,不做"范围里能捡的全捡"。
#   因为拾取规则保证任何武器都捡得起来(容量够就放入、不够就替换手上那把),
#   不存在"最近那把捡不动、把后面能捡的挡住了"的情形 —— 连着按 F 就能逐把捡走。

var map_size: Vector2 = Vector2.ZERO
var entries: Array[Dictionary] = []   # {inst, type_id, mag, pos, vel}

func size() -> int:
	return entries.size()

func clear() -> void:
	entries.clear()

func add(entry: Dictionary) -> void:
	entries.append(entry)

func remove(inst: int) -> Dictionary:
	for i in entries.size():
		if int(entries[i]["inst"]) == inst:
			return entries.pop_at(i)
	return {}

func get_entry(inst: int) -> Dictionary:
	for e in entries:
		if int(e["inst"]) == inst:
			return e
	return {}

# 距离 pos 最近的、在 radius 内的条目(环面最短距离)。无则返回空字典。
# ★ 半径判定与排序都用**环面最短距离**:武器可能在接缝另一侧,
#   用绝对坐标差会得出"隔了整幅地图"→ 贴脸也捡不到。
# ★ 并列(两把完全重合)按 inst 升序 —— 必须确定性,否则两台客户端各自挑中不同的一把。
func nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for e in entries:
		var inst := int(e["inst"])
		if exclude.has(inst):
			continue
		# ★ toroidal_delta_px 的签名是 (a, b, w, h) —— 宽高是**两个 float 参数**,
		#   不是传一个 Vector2。传错了不会报错,只会静默按 0 宽高算距离。
		var d := GridPathfinder.toroidal_delta_px(e["pos"], pos, map_size.x, map_size.y).length()
		if d > radius:
			continue
		if best.is_empty() or d < best_d or (is_equal_approx(d, best_d) and inst < int(best["inst"])):
			best = e
			best_d = d
	return best
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2
Expected: `SMOKE OK`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add core/sim/ground_weapon_field.gd tests/ground_weapon_field_smoke.gd
git commit -m "feat(weapons): GroundWeaponField —— 环面最近拾取 + 并列按 inst 确定性排序"
```

---

### Task 9: `spread_cells` 布点工具（并让 `RoyaleHost` 改调它）

**Files:**
- Modify: `core/sim/grid_pathfinder.gd`（加静态 `spread_cells`）
- Modify: `server/royale_host.gd:185-215`（`plan_spawns` 改调它）
- Test: `tests/enemy_logic_smoke.gd`（加 `_phase_spread_cells`）

**Interfaces:**
- Consumes: `GridPathfinder.toroidal_dist`
- Produces: `static GridPathfinder.spread_cells(cells: Array, count: int, clearance: int, map_size: Vector2) -> Array`（返回 ≤ count 个格）

- [ ] **Step 1: 写失败的测试**

在 `tests/enemy_logic_smoke.gd` 末尾追加：

```gdscript
# 布点工具:必须(a)尽量互相远离、(b)确定性(同输入同输出)、(c)格数不足时优雅降级。
func _phase_spread_cells() -> void:
	var cells: Array = []
	for y in 10:
		for x in 10:
			cells.append(Vector2i(x, y))
	var ms := Vector2(640, 640)

	var picked: Array = GridPathfinder.spread_cells(cells.duplicate(), 5, 3, ms)
	_check(picked.size() == 5, "应取满 5 个点(实际 %d)" % picked.size())
	# 两两环面距离 ≥ clearance(贪心保证,除非放宽过 —— 10x10 格放 5 个点不会放宽)
	for i in picked.size():
		for j in range(i + 1, picked.size()):
			var d := GridPathfinder.toroidal_dist(picked[i], picked[j], 10, 10)
			_check(d >= 3, "点 %d 与 %d 的距离 %d < clearance 3" % [i, j, d])

	# 池子不够大时:`clearance` 逐级放宽,最终必须凑满 count(而不是返回空)
	var few: Array = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]
	var got: Array = GridPathfinder.spread_cells(few.duplicate(), 3, 9, ms)
	_check(got.size() == 3, "池子小时应放宽 clearance 凑满(实际 %d)" % got.size())

	# count 超过池子大小:返回全部,不越界
	var over: Array = GridPathfinder.spread_cells(few.duplicate(), 10, 3, ms)
	_check(over.size() == 3, "count 超过池子应返回全部(实际 %d)" % over.size())
```

- [ ] **Step 2: 跑测试确认它失败**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: FAIL —— `GridPathfinder.spread_cells` 不存在。

- [ ] **Step 3: 写实现**

在 `core/sim/grid_pathfinder.gd` 加：

```gdscript
# 从候选格里挑 count 个**互相尽量远离**的格(环面距离贪心)。
# 洗牌后逐个取,要求与已选点两两环面距离 ≥ clearance;不足则 clearance 逐级 -5 放宽,
# 全部放宽完仍不够就直接补任意剩余的格。
#
# ★ 抽自 royale_host.plan_spawns(原先长在 RoyaleHost 实例上,单机用不了)。
# ★ **内部有 shuffle()**:同一组输入两次调用结果不同。调用方不得在广播之后再调一次
#   (RoyaleHost 原有纪律,别丢)。
static func spread_cells(cells: Array, count: int, clearance: int, map_size: Vector2) -> Array:
	var pool := cells.duplicate()
	pool.shuffle()
	var cols := maxi(1, int(map_size.x / GameParameters.TILE_SIZE))
	var rows := maxi(1, int(map_size.y / GameParameters.TILE_SIZE))
	var picked: Array = []
	var used: Dictionary = {}
	var cl := clearance
	while picked.size() < count:
		for c in pool:
			if picked.size() >= count:
				break
			if used.has(c):
				continue
			var ok := true
			for p in picked:
				# ★ toroidal_dist(a, b, cols, rows):cols/rows 是**两个 int 参数**
				if toroidal_dist(c, p, cols, rows) < cl:
					ok = false
					break
			if ok:
				picked.append(c)
				used[c] = true
		if picked.size() >= count:
			break
		if cl <= 0:
			break
		cl -= 5
		cl = maxi(cl, 0)
	# 兜底:放宽到头仍不够,补任意剩余的格(宁可挤,不可少)
	if picked.size() < count:
		for c in pool:
			if picked.size() >= count:
				break
			if not used.has(c):
				picked.append(c)
				used[c] = true
	return picked
```

- [ ] **Step 4: 改 `RoyaleHost.plan_spawns` 调它**

`server/royale_host.gd:185-215` 的 `plan_spawns`：把内层的"洗牌 + 贪心 + 逐级放宽"整段替换为对 `GridPathfinder.spread_cells` 的调用，保留它原有的"候选池 → 回退到全地板格"两段结构与 `_round_spawns` 赋值。

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600
```
Expected: 0 报错。

- [ ] **Step 5: 跑冒烟确认通过**

Run: 同 Step 2
Expected: `SMOKE OK`。

- [ ] **Step 6: 提交**

```bash
git add core/sim/grid_pathfinder.gd server/royale_host.gd tests/enemy_logic_smoke.gd
git commit -m "refactor(sim): 散点布点抽成 GridPathfinder.spread_cells,RoyaleHost.plan_spawns 改调它"
```

---

### Task 10: 单机世界侧 —— 12 把散落 + F 捡 / Q 长按丢

**Files:**
- Modify: `scenes/level_0.gd`（建地面武器表 + 散落 + 拾取执行）
- Modify: `scenes/player/player.gd`（F/Q 接线 + Q 长按计时）
- Modify: `ui/hud.gd`（丢弃进度反馈）

**Interfaces:**
- Consumes: Task 3 的 `pick_up`/`drop_current`/`take_last_dropped`；Task 7 的 `WeaponPickup`；Task 8 的 `GroundWeaponField`；Task 9 的 `spread_cells`
- Produces: `Level0.scatter_weapons(types: Array[int]) -> void`、`Level0.spawn_pickup(type_id, mag, pos, vel) -> WeaponPickup`、`Level0.remove_pickup(inst) -> void`、`Level0.ground_weapons: GroundWeaponField`

- [ ] **Step 1: `Level0` 建地面武器层**

在 `scenes/level_0.gd` 加：

```gdscript
# ── 地面武器(2026-09-15)──
# 单机的权威就是本场景;联机的权威在 MatchHost(见联机计划)。
var ground_weapons := GroundWeaponField.new()
var _next_pickup_inst := 1
var _pickup_nodes: Dictionary = {}   # inst -> WeaponPickup

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")

func spawn_pickup(type_id: int, mag: int, pos: Vector2, vel: Vector2, inst: int = 0) -> WeaponPickup:
	if inst <= 0:
		inst = _next_pickup_inst
		_next_pickup_inst += 1
	else:
		_next_pickup_inst = maxi(_next_pickup_inst, inst + 1)
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, mag, vel)
	node.global_position = pos
	$WorldViewport.add_child(node)
	ground_weapons.map_size = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_pickup_nodes[inst] = node
	return node

func remove_pickup(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)

func clear_pickups() -> void:
	for n in _pickup_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	ground_weapons.clear()

# 把 types 里每种武器铺 n 份到全图开阔地板格上。
func scatter_weapons(types: Array) -> void:
	clear_pickups()
	ground_weapons.map_size = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var cells: Array = $EnemySpawner.open_floor_cells(MazeGenerator.current_grid)
	var total := types.size()
	var picked := GridPathfinder.spread_cells(cells, total, 10, ground_weapons.map_size)
	if picked.size() < total:
		# 地板格不够(小地图/密封图):有多少放多少,不报错也不能卡住开局
		total = picked.size()
		picked = picked.slice(0, total)
	var half := float(GameParameters.TILE_SIZE) * 0.5
	for i in total:
		# 格中心:格坐标 × 64 + 32
		var pos := Vector2(picked[i]) * float(GameParameters.TILE_SIZE) + Vector2(half, half)
		spawn_pickup(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)
```

- [ ] **Step 2: `EnemySpawner` 暴露开阔地板格**

`scenes/enemies/enemy_spawner.gd` 加一个只读入口（判据本体已是共享的 `MazeGenerator.is_floor_cell_with_headroom`）：

```gdscript
# 全图"头顶 2 格净空"的开阔地板格。地面武器布点用(联机侧 RoyaleHost 有同款)。
# ★ 判据本体在 MazeGenerator,本函数只做扫描 —— 别再抄一份判定条件。
func open_floor_cells(grid: Array) -> Array:
	var out: Array = []
	if grid.is_empty():
		return out
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				out.append(c)
	return out
```

- [ ] **Step 3: `player.gd` 接 F/Q**

在 `scenes/player/player.gd` 字段区加：

```gdscript
var _drop_hold_t := 0.0     # Q 已按住多久
var _drop_latched := false  # 本次长按是否已触发过(防按住不放连丢)
```

在 `_physics_process(delta)` 里，**排在切枪之后、移动之前**插入：

```gdscript
	_poll_pickup_drop(delta)
```

并加：

```gdscript
# F 捡起 / Q 长按丢弃。
# ★ F 与 Q 都走 input_source 读口(不是 _unhandled_input 的原始 InputEvent):
#   权威服务器没有输入事件,只有注入包 —— 读原始事件的话联机端永远收不到。
#   这与 R 换弹 2026-09-15 的迁走是同一个理由。
func _poll_pickup_drop(delta: float) -> void:
	# Q 长按计时:本地判定,满阈值发一次边沿(见联机计划:上行的是完成信号,不是"按住")
	if input_source.is_action_pressed("Q"):
		if not _drop_latched:
			_drop_hold_t += delta
			if _drop_hold_t >= PlayerParams.weapon_drop_hold_time:
				_drop_latched = true
				_try_drop()
	else:
		_drop_hold_t = 0.0
		_drop_latched = false

	if input_source.is_pickup_pressed():
		_try_pickup()

func _try_pickup() -> void:
	var lvl := get_tree().current_scene
	if not (lvl is Level0):
		return
	(lvl as Level0).try_pickup_for(self)

func _try_drop() -> void:
	if weapons.current_slot_int() == 0:
		return   # 空手没什么可丢
	var e: Dictionary = weapons.drop_current()
	if e.is_empty():
		return
	var lvl := get_tree().current_scene
	if lvl is Level0:
		(lvl as Level0).spawn_pickup(int(e["type"]), int(e["mag"]),
			global_position + PlayerParams.weapon_drop_offset * Vector2(float(facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * facing_direction, -PlayerParams.weapon_drop_up))
```

- [ ] **Step 4: `Level0` 执行拾取**

在 `scenes/level_0.gd` 加：

```gdscript
# 一次 F 只捡**最近的一把**(不捡"范围里能捡的全部")—— 这是"多把叠在一起捡不起来"的解法:
# 连着按 F 就能逐把捡走。见 GroundWeaponField 的类头注释。
func try_pickup_for(p: Node2D) -> void:
	if p.weapons == null:
		return
	var e: Dictionary = ground_weapons.nearest_within(p.global_position,
		PlayerParams.weapon_pickup_radius)
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped_type: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	remove_pickup(inst)
	if dropped_type > 0:
		# 放不下 → 被换下的那把掉在玩家脚下(残弹跟着枪走)
		var d: Dictionary = p.weapons.take_last_dropped()
		spawn_pickup(dropped_type, int(d.get("mag", WeaponInventory.MAG_FULL)),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up))
```

- [ ] **Step 5: `restart_single` 里清地面武器**

在 `scenes/level_0.gd` 的 `restart_single()` 里，清子弹的那几行旁边加：

```gdscript
	clear_pickups()
```

并在敌人重刷之后加回散落（Task 11 会把它换成统一的"重开"路径）。

- [ ] **Step 6: 长按 Q 的进度反馈**

★ **没有反馈的两秒长按是不可用的** —— 玩家会以为按键没生效。在 `ui/hud.gd` 里加一条按住的进度条：

- 字段区加 `var _drop_bar: ColorRect = null`（复用 `_bar_back` 所在的 `bar_holder`，**不要**新建一套：那条槽位本来就在武器区下方）。
- 在 `_process()` 的换弹条逻辑旁边加：

```gdscript
	# 丢弃进度:长按 Q 时占用同一条槽位(换弹优先——换弹时不可能是丢弃)
	if _player != null and _drop_bar != null:
		var holding := Input.is_action_pressed("Q") and not _player.combat.is_downed() \
			and _player.weapons.current_slot_int() > 0
		if holding and not _player.weapons.current_weapon().is_reloading():
			_drop_bar.visible = true
			if _bar_back != null:
				_bar_back.visible = true
			var t := clampf(_player.drop_hold_progress(), 0.0, 1.0)
			_drop_bar.size = Vector2(WEAPON_ICON_W * t, 4)
		elif not _player.weapons.current_weapon().is_reloading():
			_drop_bar.visible = false
```

- `_drop_bar` 的 `color` 用 `UiFactory.C_DANGER`（丢弃是破坏性操作；`C_WARN` 金已被"弹夹见底"独占，别抢）。
- 在 `player.gd` 加一个只读入口给 HUD：

```gdscript
# 长按 Q 的进度 0..1(只读,HUD 的丢弃进度条用)。
func drop_hold_progress() -> float:
	if _drop_latched:
		return 1.0
	return clampf(_drop_hold_t / PlayerParams.weapon_drop_hold_time, 0.0, 1.0)
```

- [ ] **Step 7: 跑起来手验**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600
```
Expected: 0 报错。

然后**用户手工验收**（实施者跑不了带画面的验收）：开局背包里有 3 把枪、地上有 12 把、走近按 F 能捡、长按 Q 有进度条且满了才丢。

- [ ] **Step 8: 提交**

```bash
git add scenes/level_0.gd scenes/enemies/enemy_spawner.gd scenes/player/player.gd ui/hud.gd
git commit -m "feat(weapons): 单机地面武器 —— 12 把散落 + F 捡最近一把 + Q 长按 2s 丢弃(含进度反馈)"
```

---

### Task 11: 单机开局空手 + 重启语义

**Files:**
- Modify: `scenes/player/player.gd:147`（改回空表）
- Modify: `scenes/level_0.gd`（`_ready` 散落 12 把；`restart_single` 完全重开）

**Interfaces:**
- Consumes: Task 10 的 `scatter_weapons` / `clear_pickups`
- Produces: 无新接口

- [ ] **Step 1: 开局空手**

`scenes/player/player.gd` 里把 Task 3 加的临时初始背包替换为：

```gdscript
	# 单机开局**空手**:武器全部散落在地图上,由 Level0._ready 铺(见 scatter_weapons)。
	# 联机由 MatchHost 调 set_initial_inventory 发随机一把(见联机计划)。
	weapons.set_initial_inventory([])
```

- [ ] **Step 2: `Level0._ready` 铺 12 把**

在 `scenes/level_0.gd` 的 `_ready` 里、`$EnemySpawner.spawn_all.call_deferred(spawns)` 附近加：

```gdscript
	# 单机初始武器:每种 2 把,共 12 把,随机散落全图。
	# ★ 禁用武器不出现在分布里(与 set_enabled_slots 同源:RunOptions.disabled_weapons)。
	var weapon_types: Array = []
	for slot in [1, 2, 3, 4, 5, 6]:
		if not RunOptions.disabled_weapons.has(slot):
			weapon_types.append(slot)
			weapon_types.append(slot)
	scatter_weapons.call_deferred(weapon_types)
```

★ 用 `call_deferred`：`scatter_weapons` 要读 `MazeGenerator.current_grid`，而网格由 `WorldBuilder.load_grid()` 在本帧更早处写入；延迟到帧末避免读到半初始化的状态。

- [ ] **Step 3: `restart_single` 改成完全重开**

在 `scenes/level_0.gd` 的 `restart_single()` 里，把 Task 10 加的裸 `clear_pickups()` 换成"清空 + 重新散落"，并把玩家背包清空：

```gdscript
	# 单机按 R = 完全重开:背包清空、地面武器重新散落(与"还原可破坏砖 + 清子弹/敌人重刷"同一语义)
	clear_pickups()
	var weapon_types: Array = []
	for slot in [1, 2, 3, 4, 5, 6]:
		if not RunOptions.disabled_weapons.has(slot):
			weapon_types.append(slot)
			weapon_types.append(slot)
	scatter_weapons(weapon_types)
	$WorldViewport/Player.weapons.set_initial_inventory([])
```

并删掉 `player.gd` 的 `restart_at()` 里那三行旧的武器复位（`reset_mag_state` / `equip(default_slot())` / `refill_current_weapon()`）—— 背包现在由 `Level0.restart_single` 统一重置，玩家自己再 equip 一次会与之打架。改为只留 `weapons.cancel_aim()`。

★ 注意：`restart_at` 也被联机侧调用（PvP 复活），所以**不能**把背包重置放进 `restart_at`；联机的复活武器规则不同（除随机一把外全丢），见联机计划。

- [ ] **Step 4: 跑起来手验**

Run:
```bash
"$GODOT" --headless --path . --quit-after 3600
```
Expected: 0 报错。

**用户手工验收**：开局空手、HUD 格子全灰；地图上能找到枪；捡起来后格子变色；按 R 重启后回到空手 + 12 把重新散落。

- [ ] **Step 5: 提交**

```bash
git add scenes/player/player.gd scenes/level_0.gd
git commit -m "feat(weapons): 单机开局空手 + 12 把散落;按 R 重启改为完全重开(背包清空 + 重新散落)"
```

---

### Task 12: 同步 CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 更新相应段落**

- 「参数体系」一节：说明 `PlayerParams` 新增的拾取/丢弃参数。
- 「武器与子弹」一节：加"武器现在可丢可捡"的说明，指向 `WeaponPickup` / `WeaponInventory` / `GroundWeaponField` / `SpriteBounds`；把"加新武器"那句从**两行**改成**三行**（`WEAPONS` + `DISPLAY_NAMES` + **`TIERS`**），并写明第三条漏填的表现是**容量算错且不报错**。
- 「碰撞层」一节：加"层 4 = 掉落物（值 8）"，并写明它在联机里另有归属。
- 「常用命令」/「测试」一节：登记新冒烟 `weapon_inventory_smoke` / `ground_weapon_field_smoke` / `sprite_bounds_smoke` 与新探针 `weapon_pickup_probe`。
- UI 一节：加 4×2 格子控件与三个颜色常量的说明（含"深青按高饱和实现"的理由）。

- [ ] **Step 2: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE): 武器槽位/地面拾取落地后的架构与约定同步"
```

---

## 自查记录

**spec 覆盖**：spec §4（背包/容量/键位/滚轮/HUD）→ Task 1-5；§5（地面实体/碰撞层/像素箱/拾取/丢弃）→ Task 6-8、10；§7.1/§7.2（布点工具/单机初始）→ Task 9、11；§8 测试计划 → 各 Task 内。**spec §6（联机）与 §7.3（复活/换局）不在本计划**，属独立的"联机"计划。

**已知的中间态**：Task 3 落地后到 Task 11 之间，单机初始背包是临时的 `[1,2,6]`（重狙/霰弹/榴弹暂时拿不到）。已在 Global Constraints 里写明，不要为它放宽容量闸门。

**耦合提醒**：`restart_at()` 被单机与联机共用，本计划只允许删掉它的武器复位三行（迁到 `Level0.restart_single`），**不得**把"背包清空"塞进 `restart_at` —— 联机复活的武器规则不同。
