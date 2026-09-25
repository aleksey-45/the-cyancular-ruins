# 容量 / 把数可配（`WeaponInventory.CAPACITY` / `MAX_WEAPONS` 字段化）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"背包 8 格容量"与"最多 4 把"从**编译期常量**改成**实例字段**（带 setter、
默认值不变），并让左下角容量格子阵的**行数/面板高**由容量派生。
**默认值一个字不变 ⇒ 协议零改动、对局行为零改动。**

**Architecture:** 两条闸门都在 `core/sim/weapon_inventory.gd` 的 `can_hold()` 里，改成读
实例字段；`ui/weapon_slots.gd` 的 `capacity` 从背包取、`rows` / `panel_h` 由它派生
（`COLS` 恒 4，容量长大时格阵**向下长**，不换行宽）——
`PANEL_W` 只跟列数有关 ⇒ **仍是常量**，`PANEL_H` 与 `ROWS` 两个常量**删掉**。
`PANEL_H` 的静态读者（`ui/hud.gd:303` 是**全仓唯一**一处，加上 `attach_to` 自己那两行）
改读实例字段 `panel_h`。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`-s` 冒烟、场景探针（`--headless --quit-after`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-weapon-system-rework-design.md` §4.4 + §6.2
（**其顶部「2026-09-25 事实核验订正」块优先于正文**）。

## ★★ 与另两份计划的关系（开工前必读）

本计划与 `2026-09-25-weapon-naming-and-inst-protocol.md`（**计划 2**）、
`2026-09-25-weapon-registry.md`（**计划 3**）**共同触碰
`scenes/player/weapon_component.gd` 与 `ui/weapon_slots.gd`，三者必须串行、不得并行**。
执行顺序：

**计划 2 → 计划 3 → 计划 4（本计划）。**

原因：① `ui/weapon_slots.gd:85` 调的是 `WeaponInventory.cell_start(index)`，而
`slot_start → cell_start` 那个改名是**计划 2** 做的；② 计划 3 会改
`weapon_component.gd` 的 `_init`（`WeaponInventory.new(WeaponRegistry.tiers_map())`），
本计划**不动那一行**（它仍是一次普通构造，默认参数正好给出 8 / 4）。
**本计划全篇使用 spec §3 的词汇**（`type_id` / `inst` / `index`），一处都不写旧名。

★★ **spec §3 那张表是不完整的** —— 计划 2 的改名范围比它长，多出来的几条本计划**每一处都要用**
（`used_slots()`→**`used_cell_count()`**、`SLOT_COST`→**`CELL_COST`**，以及
`cell_start()` / `equip_type(int)` / 形参或循环变量 `slot`→`type_id`）。
**以计划 2 的改名表为准，不以 spec §3，也不以本计划的片段为准。**
核验报告实测：照 spec §3 的 9 项写，本计划的替换片段会造成 **1 处 Parse Error + 2 处运行时挂起**
（其中一处会让本计划 Step 6 的"若命令 hang ⇒ 某个探针写成了直接取属性"这条判读规则**指错方向**）。

**Task 1 的 Step 0 是这条前提的机械检查**。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless`、**不占任何端口**；**实机开一局归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0`
  且一行裁决都不打印。★ 更尖的一层（`tests/lib/probe_base.gd` 文件头）：
  **grep 到 `ALL-OK` 只证明"没有任何断言失败"，不证明"该跑的断言都跑过"**。
  本计划要新增的断言大多落在 `-s` 冒烟里，而 `-s` 冒烟里"出错的那个函数当场结束、
  调用方继续"⇒ 后面的断言被**静默跳过**、verdict 照打 `SMOKE OK`。故**凡是要碰
  新接口的地方，一律先做一次不抛错的探测**（`get_property_list()` /
  `get_script_constant_map()` / 源码文本），探到了才敢调。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- ★★ **命令里的 `2>&1` 一个都不能省。** `enemy_logic_smoke._check` 与
  `level0_weapon_scatter_probe._check` 的失败行走的是 **`printerr`（stderr）**
  （`tests/enemy_logic_smoke.gd:64`）；去掉 `2>&1` 会把"红了"读成"没有输出"，
  而"没有输出"在本仓恰好是**另一种**已知故障形态（脚本没跑起来 / 挂住）—— 两者会撞车。
  （`weapon_inventory_smoke._check` 与 `ground_action_probe._check` 走的是 `print`（stdout），
  但统一带 `2>&1` 更省心。）
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，
  别用 `-m "…"`（双引号会**静默吞掉**反引号与 `$`）。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`；本计划不引入字号）。
- 改 GDScript **只需重导出**，不要重编裁剪模板。
- ★★ **`CAPACITY` / `MAX_WEAPONS` 两个常量名要删干净，不要留成"默认值"的别名。**
  留着它们的话，8 处静态读（`ui/weapon_slots.gd` 4 处 + `tests/ground_action_probe.gd` 4 处）
  会**照样编得过**，但读的是"默认值"而不是"这个背包的容量" —— 那是**静默的错值**，
  正是本计划要消灭的东西（spec §4.4）。默认值改名叫 `DEFAULT_CAPACITY` /
  `DEFAULT_MAX_WEAPONS`，含义是"构造时的默认"，不是"任何实例的容量"。
- ★★ **本计划的全部代码都写在计划 2 改名之后的词汇上。** 会碰到的改名（以计划 2 的改名表为准）：
  `used_slots()`→**`used_cell_count()`**、`SLOT_COST`→**`CELL_COST`**、`slot_start`→`cell_start`、
  `equip(String)`→`equip_type(int)`、`_current_slot`→`_current_type`、`is_slot_enabled`→
  `is_type_enabled`、`enabled_slots`→`enabled_types`、`set_enabled_slots`→`set_enabled_types`，
  以及形参/循环变量 `slot`→`type_id`。保留 `slot` 的只有 `Player.weapon_slot` 挂点、
  `WeaponSlots` / `C_SLOT_*` 容量格 UI、`capture_state()` 的 `wslot` 键。
  **`CAPACITY` / `MAX_WEAPONS` 不在改名表里**（它们是本计划要删的）。
  ★ 写回旧名 = Parse Error 或运行时错；**运行时错在 `-s` 冒烟里表现为"挂住"，不是"红"**
  （Step 6 的判读规则专门写了这一条，别把它读成别的成因）。
- ★ **行号只作参考**：本计划的行号取自 `main`（计划 2 之前），且计划 3 会改
  `enemy_logic_smoke.gd` 的 `_phase_weapon_registry`（那一段落在我 Task 1 Step 3 的锚点上）。
  每处都给了"改前"的原文片段，**按内容定位**。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `core/sim/weapon_inventory.gd` | 背包纯逻辑（两条闸门 / 残弹记账） | `MAX_WEAPONS` / `CAPACITY` **常量删除** → 实例字段 `max_weapons` / `capacity`；加 `DEFAULT_*` 与 setter；`_init` 收三个参数 |
| `ui/weapon_slots.gd` | 左下角容量格子（自绘） | `ROWS` / `PANEL_H` **常量删除** → `capacity` / `rows` / `panel_h` 实例字段；加 `rows_for()` / `panel_h_for()` / `_derive_layout()`；4 处静态读改本地 |
| `ui/hud.gd` | 单机 HUD | `WeaponSlots.PANEL_H` → `_slots.panel_h`（:303 一处） |
| `tests/weapon_inventory_smoke.gd` | 背包纯逻辑冒烟 | `:74-78` 默认值两条改指 `DEFAULT_*`；**新增**一段"容量/把数可配" |
| `tests/enemy_logic_smoke.gd` | 主冒烟 | 两条 `wi.MAX_WEAPONS`/`wi.CAPACITY` 改指 `DEFAULT_*`；**末尾追加** `_phase_weapon_capacity()` |
| `tests/ground_action_probe.gd` | 联机拾取/丢弃探针 | 4 处 `WeaponInventory.CAPACITY` → `p.weapons.inventory.capacity` |
| `tests/level0_weapon_scatter_probe.gd` | 单机散落/版式探针 | `_phase_slot_placement` 加一条"默认容量下面板高 = 59" |
| `CLAUDE.md` | 项目文档 | §参数体系 / §武器背包 登记"两条闸门可配" + **已知边界** |

---

### Task 1: 新断言先行 —— 把"可配"变成可断言的红灯

**Files:**
- Modify: `tests/weapon_inventory_smoke.gd`（:74-77 改指默认值常量；新增一段）
- Modify: `tests/enemy_logic_smoke.gd`（`_phase_weapon_registry` 末尾两条；**追加**一个新相）
- Modify: `tests/level0_weapon_scatter_probe.gd`（`_phase_slot_placement` 加一条）

**Interfaces:**
- Consumes: `WI.get_script_constant_map()`、`WI.new(tiers)`、`ScanUtil`
  （`tests/lib/scan_util.gd` 的纯静态助手）、现成的 `_check` / `_fail`。
- Produces: 一组**会红**的断言，红的成因分两拨：
  （a）`DEFAULT_CAPACITY` / `DEFAULT_MAX_WEAPONS` 两个常量还不存在；
  （b）`capacity` / `max_weapons` 两个实例字段、`rows_for()` / `panel_h_for()` 两个静态派生
  函数还不存在。

- [ ] **Step 0: 确认前提（计划 2 与计划 3 已落地）**

Run:
```bash
source tests/env.sh
echo "--- 计划 2：改名 ---"
# ★ 剥掉注释再数:`sed 's/#.*//'` —— 注释里提到旧名不算数(计划 2 未必逐条改注释)。
sed 's/#.*//' scenes/player/weapon_component.gd \
  | grep -cE "_current_slot|set_enabled_slots|is_slot_enabled|enabled_slots|slot_start"
sed 's/#.*//' ui/weapon_slots.gd | grep -c "slot_start"
echo "--- 计划 1：新名必须已经在（否则上面那两个 0 只是"文件被删了"）---"
grep -c "used_cell_count\|CELL_COST" core/sim/weapon_inventory.gd
grep -c "cell_start" ui/weapon_slots.gd
echo "--- 计划 3：注册表 ---"
sed 's/#.*//' scenes/player/weapon_component.gd | grep -c "WeaponRegistry"
```
Expected: 前两行都是 `0`；**紧接着两行都必须 ≥ 1**（计划 1 的新名已在位 —— 只查"旧名为 0"
会被"文件根本不存在/被清空"骗过）；最后一行的注册表计数 ≥ 1。
任何一个不对 ⇒ 对应计划未落地，**停下**。

- [ ] **Step 1: `weapon_inventory_smoke.gd` 的默认值两条改口径**

`:74-78` 现在是直接取 `WI.MAX_WEAPONS` / `WI.CAPACITY` / `WI.CELL_COST`
（★ 第三个在计划 1 之前叫 `SLOT_COST`；计划 1 之后应当是 `CELL_COST`，若还是旧名说明计划 1
没跑完）。**常量一删或一改名，直接取属性就会抛错**，而 `-s` 脚本抛错走不到 `quit()`
⇒ **进程永久挂起**（不是"干净的红"）。改成查常量表 + 读默认值：

```gdscript
	# ★ 默认值一律走 `get_script_constant_map()`:常量不存在时直接取属性会抛错,而 -s 脚本
	#   抛错走不到 quit() → **进程永久挂起**(本仓铁律,见上面 WI == null 那段)。
	#   `.get(name, -1)` 的存在性检查让"常量还没改名"表现为**干净的红**。
	# ★ `CELL_COST` 是计划 1 改的名(原 `SLOT_COST`)—— 写回旧名同样会抛错 ⇒ 挂起。
	var wconsts: Dictionary = WI.get_script_constant_map()
	var def_cap := int(wconsts.get("DEFAULT_CAPACITY", -1))
	var def_max := int(wconsts.get("DEFAULT_MAX_WEAPONS", -1))
	_check(def_max == 4, "DEFAULT_MAX_WEAPONS 必须恰好是 4(实际 %d)" % def_max)
	_check(def_cap == 8, "DEFAULT_CAPACITY 必须恰好是 8(实际 %d)" % def_cap)
	_check(int(WI.CELL_COST[int(WI.TIER_LIGHT)]) == 2, "轻武器必须恰好占 2 格")
	_check(int(WI.CELL_COST[int(WI.TIER_LIGHT)]) * def_max == def_cap,
		"轻武器 cost × 4 应恰好等于容量(这条等式一旦不成立,上面那条注释就该重写)")
```
★ 上面那段注释里"上面那条注释"指的是本节开头那段**关于两条闸门互相蕴含**的长注释
（`:71-78`），**保留不动** —— 它讲的道理（`4 把 × 2 格 == 8` 让把数闸门被容量蕴含，
但它不是死代码）正是本次改动之后仍然成立的那件事。

- [ ] **Step 2: `weapon_inventory_smoke.gd` 追加"容量/把数可配"一段**

插在 `# ── 紧凑排布 ──` 那一段**之前**（即紧接上面那组两条闸门的断言之后）：

```gdscript
	# ══ 容量 / 把数可配(2026-09-25)══
	# ★★ 探字段**必须**先探再调:直接写 `probe.capacity` 在改动前会抛 "Invalid get index"
	#   → `_initialize()` 当场中断 → **走不到 quit() → 进程永久挂起**。
	#   探不到就报 FAIL 并**用 if 包住**后续(不要 early return —— return 同样到不了 quit)。
	var probe = WI.new(tiers)
	var has_capacity := false
	var has_max := false
	for pr in probe.get_property_list():
		# ★ 用 if/elif,不用 `match` —— GDScript 的 match 体内 `continue` 是 **fall-through**
		#   (落到下一个 pattern、两支都跑),本仓踩过;这里虽没写 continue,但别开这个头。
		var n := str(pr.get("name", ""))
		if n == "capacity":
			has_capacity = true
		elif n == "max_weapons":
			has_max = true
	_check(has_capacity, "★ WeaponInventory 应有**实例字段** capacity(不再是类常量 CAPACITY)")
	_check(has_max, "★ WeaponInventory 应有**实例字段** max_weapons(不再是类常量 MAX_WEAPONS)")
	if has_capacity and has_max:
		# ① 不带额外实参 ⇒ 默认值不变(协议零改动的前提)
		var dflt = WI.new(tiers)
		_check(dflt.capacity == 8 and dflt.max_weapons == 4,
				"缺省构造 = 8 格 / 4 把(实际 %d / %d)" % [dflt.capacity, dflt.max_weapons])
		# ② 构造实参生效
		var wide = WI.new(tiers, 12, 6)
		_check(wide.capacity == 12 and wide.max_weapons == 6,
				"构造实参生效(实际 %d / %d)" % [wide.capacity, wide.max_weapons])
		wide.add(5, 5)
		wide.add(5, 5)
		wide.add(5, 5)                      # 三把重型 = 12 格(加起来正好到顶)
		_check(wide.used_cell_count() == 12,
				"宽松配置下三把重型 = 12 格(实际 %d)" % wide.used_cell_count())
		_check(not wide.can_hold(1), "★ 容量闸门读的是**字段**:12 格满了,最便宜的档也放不下")
		# ③ 两条闸门**互相独立** —— 这是本节的核心断言,今天靠真表造不出来(见上面那段长注释)
		var by_cap = WI.new(tiers, 4, 9)
		by_cap.add(5, 5)                    # 重型 4 格 = 正好占满 4 格,而把数还剩 8
		_check(by_cap.used_cell_count() == 4,
				"容量 4 的背包放一把重型正好占满(实际 %d)" % by_cap.used_cell_count())
		_check(not by_cap.can_hold(1), "★ 容量闸门单独生效(把数上限 9 没拦,是容量拦的)")
		var by_max = WI.new(tiers, 100, 1)
		by_max.add(1, 5)                    # 轻 2 格,容量还剩 98
		_check(by_max.used_cell_count() == 2,
				"容量 100 的背包放一把轻型只占 2 格(实际 %d)" % by_max.used_cell_count())
		_check(not by_max.can_hold(1), "★ 把数闸门单独生效(容量剩 98 格,是把数上限拦的)")
		# ④ setter 路径
		by_max.set_capacity(0)
		by_max.set_max_weapons(0)
		_check(by_max.capacity >= 1 and by_max.max_weapons >= 1,
				"setter 必须把容量/把数**钳到 ≥ 1**(0 会让闸门变成'永远放不下'的死锁;实际 %d / %d)"
						% [by_max.capacity, by_max.max_weapons])
		by_max.set_capacity(12)
		by_max.set_max_weapons(6)
		_check(by_max.capacity == 12 and by_max.max_weapons == 6,
				"setter 设值生效(实际 %d / %d)" % [by_max.capacity, by_max.max_weapons])
	else:
		_check(false, "★ 容量/把数可配的四组行为断言被跳过(字段还没改,期望在这一步红)")
```

- [ ] **Step 3: `enemy_logic_smoke.gd` 的两条默认值断言改口径**

`_phase_weapon_registry()` **末尾**那两条（**计划 3 改完之后**的版本；按内容定位 ——
那句 `_check(int(wi.MAX_WEAPONS) == 4, …)` 与紧邻的 `_check(int(wi.CAPACITY) == 8, …)`）改成：

```gdscript
	# ★ 原先是 `int(wi.MAX_WEAPONS)` / `int(wi.CAPACITY)` 直取属性 —— 常量改名成字段之后
	#   那是运行时错,而本文件是 -s 冒烟 ⇒ 错在 helper 里"该函数当场结束、调用方继续"
	#   ⇒ 后面断言被静默跳过、verdict 照打 SMOKE OK(**假绿**)。故走常量表 + 哨兵默认值。
	var wconsts: Dictionary = wi.get_script_constant_map()
	_check(int(wconsts.get("DEFAULT_MAX_WEAPONS", -1)) == 4,
			"WeaponInventory.DEFAULT_MAX_WEAPONS == 4(实际 %s)" % str(wconsts.get("DEFAULT_MAX_WEAPONS")))
	_check(int(wconsts.get("DEFAULT_CAPACITY", -1)) == 8,
			"WeaponInventory.DEFAULT_CAPACITY == 8(实际 %s)" % str(wconsts.get("DEFAULT_CAPACITY")))
```
★ **这两行是计划 3 点名"别删"的**（它的 ④ 组末尾写着"归容量可配那份计划改判据"）——
按内容找它们，行号会被计划 3 改写的那一段带漂。

- [ ] **Step 4: `enemy_logic_smoke.gd` 追加 `_phase_weapon_capacity()`**

① 在 `_initialize()` 的末尾加一行（**`main` 上最后一行是 `:128` 的 `_phase_spread_cells()`**，
计划 3 只改写 `:127` 那个函数体、不增删行 ⇒ 插在 `_phase_spread_cells()` **之后**）：
```gdscript
	_phase_weapon_capacity()        # ★ 同上,只追加在末尾
```
② 在 `_phase_weapon_registry()` 之后新增这个函数：

```gdscript
# ── 容量格子面板的派生(2026-09-25)──
# 判据分两半:① 派生公式本身(纯静态,不需要实例化 Control);
# ② **接线** —— 公式必须真的被 setup()/refresh() 用上。只有 ① 的话,把两个静态函数写出来
#    却没人调,断言照样全绿(本仓反复在删那种"加了断言之后全绿"的假证据)。
func _phase_weapon_capacity() -> void:
	var ws: GDScript = load("res://ui/weapon_slots.gd")
	_check(ws != null, "ui/weapon_slots.gd 可加载")
	if ws == null:
		return
	var src := ScanUtil.read("res://ui/weapon_slots.gd")
	_check(not src.is_empty(), "读到 ui/weapon_slots.gd(读不到就是红,不是静默跳过)")
	# ★★ 必须先看源码文本再敢调:`ws.rows_for(...)` 在函数不存在时会**抛错**,
	#   而 -s 冒烟里 helper 抛错 ⇒ 本函数当场结束、调用方继续 ⇒ verdict 照打 SMOKE OK(**假绿**)。
	#   本函数是 helper(不是 _initialize),所以这里 `return` 是安全的、不会挂进程。
	var has_derivation := src.contains("static func rows_for") and src.contains("static func panel_h_for")
	_check(has_derivation, "★ WeaponSlots 应导出 rows_for() / panel_h_for() 两个静态派生函数")
	if not has_derivation:
		return
	# ① 派生公式
	_check(int(ws.COLS) == 4, "COLS 恒为 4(加容量只向下长,不换行宽;实际 %s)" % str(ws.COLS))
	_check(is_equal_approx(float(ws.PANEL_W), 109.0),
			"PANEL_W 与行数无关,仍是 109(实际 %s)" % str(ws.PANEL_W))
	_check(int(ws.rows_for(8)) == 2, "rows_for(8) = 2(实际 %s)" % str(ws.rows_for(8)))
	_check(int(ws.rows_for(12)) == 3, "rows_for(12) = 3(实际 %s)" % str(ws.rows_for(12)))
	_check(int(ws.rows_for(16)) == 4, "rows_for(16) = 4(实际 %s)" % str(ws.rows_for(16)))
	_check(int(ws.rows_for(1)) == 1, "rows_for(1) = 1(至少一行,不能 0;实际 %s)" % str(ws.rows_for(1)))
	_check(is_equal_approx(float(ws.panel_h_for(8)), 59.0),
			"panel_h_for(8) = 59(默认值**一个字没变**;实际 %s)" % str(ws.panel_h_for(8)))
	_check(is_equal_approx(float(ws.panel_h_for(12)), 84.0),
			"panel_h_for(12) = 84(实际 %s)" % str(ws.panel_h_for(12)))
	_check(is_equal_approx(float(ws.panel_h_for(1)), 34.0),
			"panel_h_for(1) = 34(实际 %s)" % str(ws.panel_h_for(1)))
	# ② 接线(按**函数体**判,不按整文件 contains —— 同一文件里别处出现 `_derive_layout()`
	#    不能替 `setup()` 那一处背书)
	var body_setup := ScanUtil.func_body(ScanUtil.code_only(src), "setup")
	_check(body_setup.contains("_derive_layout()"),
			"WeaponSlots.setup() 必须调 _derive_layout()(否则容量只活在公式里,格子阵不长)")
	var body_refresh := ScanUtil.func_body(ScanUtil.code_only(src), "refresh")
	_check(body_refresh.contains("_derive_layout()"),
			"WeaponSlots.refresh() 必须重取容量(容量改了之后 UI 要能跟上)")
	var body_derive := ScanUtil.func_body(ScanUtil.code_only(src), "_derive_layout")
	_check(body_derive.contains("inventory.capacity"),
			"_derive_layout() 必须从**背包**读容量(不能是另一个写死的数)")
```

- [ ] **Step 5: `level0_weapon_scatter_probe.gd` 加一条"默认容量下面板高"**

`tests/level0_weapon_scatter_probe.gd` 的 `_phase_slot_placement()` 里，紧跟既有的
`_check(slots_bottom > 0.0 and slots.position.y > 0.0, …)` 之后加：

```gdscript
		# ★ 默认容量(8)下格子面板的高**必须仍是 59** —— 这是"把 ROWS/PANEL_H 改成派生时
		#   没有改动默认观感"的钉子。判据取**实测的 size.y**(= offset_bottom - offset_top),
		#   不是去读常量:与上面那条间隙断言同一个口径(取"实际边",不取同源常量)。
		_check(is_equal_approx(slots.size.y, 59.0),
				"%d 把枪时容量面板高应仍是 59px(实际 %.1f)" % [plan.size(), slots.size.y])
```
★ 这条在改动**前后都是绿的**(默认值不变) —— 它是**回归钉**、不是红绿分界；
它的牙齿由 Task 2 Step 5 的变异证明。

- [ ] **Step 6: 跑一次，逐条记下红在哪**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/weapon_inventory_smoke.gd 2>&1 | tail -20
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 \
  | grep -E "FAIL|SMOKE" | tail -20
"$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn \
  2>&1 | grep -E "ALL-OK|FAIL"
```
Expected（改动前，**必须是这一组**）:
```
[FAIL] DEFAULT_MAX_WEAPONS 必须恰好是 4(实际 -1)
[FAIL] DEFAULT_CAPACITY 必须恰好是 8(实际 -1)
[FAIL] 轻武器 cost × 4 应恰好等于容量(这条等式一旦不成立,上面那条注释就该重写)
[FAIL] ★ WeaponInventory 应有**实例字段** capacity(不再是类常量 CAPACITY)
[FAIL] ★ WeaponInventory 应有**实例字段** max_weapons(不再是类常量 MAX_WEAPONS)
[FAIL] ★ 容量/把数可配的四组行为断言被跳过(字段还没改,期望在这一步红)
WEAPON_INVENTORY FAILED: 6
```
★★ **逐条来历（核验报告点名要求过的"红为什么会出现"，别只抄数字）**：
- 前两条：`DEFAULT_*` 还**不是**常量（本计划的 Task 2 才加），`get_script_constant_map()`
  查不到 ⇒ `.get(name, -1)` 拿到哨兵 `-1` ⇒ `-1 == 4` / `-1 == 8` 为假 ⇒ 干净 FAIL。
- 第三条：`CELL_COST[TIER_LIGHT] = 2`，而 `def_max = -1`、`def_cap = -1`
  ⇒ `2 * (-1) = -2 != -1` ⇒ FAIL。
  ★ **这一条是"计划 1 已改名"的证据**：若这里还写着 `SLOT_COST`，取 GDScript 对象的
  不存在常量会抛错 ⇒ `_initialize()` 中断 ⇒ **挂住，一行都不打印**，
  而下面那条判读规则会把挂住误判成"守卫写错了"。所以名字必须一次写对。
- 第四、五条：`capacity` / `max_weapons` 还**不是**实例字段（`get_property_list()` 里没有）。
- 第六条的 `if has_capacity and has_max:` 为假 ⇒ 走 `else` ⇒ 那四组行为断言（含
  `used_cell_count()` 三处）**一条都不执行** —— 这正是守卫存在的理由：改动前碰到
  不存在的字段/函数会抛错，而 `-s` 冒烟里抛错 = 挂住。
- `WEAPON_INVENTORY FAILED: 6`：`_check` 只累加计数、不抛错，故**计数与退出码都正常**。
```
  FAIL - WeaponInventory.DEFAULT_MAX_WEAPONS == 4(实际 <null>)
  FAIL - WeaponInventory.DEFAULT_CAPACITY == 8(实际 <null>)
  FAIL - ★ WeaponSlots 应导出 rows_for() / panel_h_for() 两个静态派生函数
SMOKE OK
```
（第三条之后 `_phase_weapon_capacity()` 就 `return` 了 ⇒ 后面那些 `rows_for(...)` 断言
**不执行** —— 它们要等 `has_derivation` 为真。末尾仍须有 `SMOKE OK`。）
（`level0_weapon_scatter_probe` 那一条**应当是绿的**，理由见 Step 5。）
★ **判读规则**：
- `weapon_inventory_smoke` **必须打完** `WEAPON_INVENTORY FAILED: 6` 再退出。
- ★★ **若命令超时/hang**（一行 `WEAPON_INVENTORY` 都不打印）：先用
  `grep -n "used_slots\|SLOT_COST" tests/weapon_inventory_smoke.gd` 查**旧名残留**
  （那会抛错 ⇒ 挂住），**再**去查 Step 2 的 `if has_capacity and has_max:` 守卫。
  ★ 顺序不能反 —— 这条判读规则上一版写成"hang ⇒ 一定是守卫少了"，而计划自己在
  Step 1 里留着 `SLOT_COST` 时**恰好**会以那种形状挂住，会把人指到错的方向（核验报告 §2.6）。
- `enemy_logic_smoke` 的文件末尾**必须仍有 `SMOKE OK`** —— 那正是"新断言被静默跳过"
  与"新断言干净地红了"的分界：本次预期是**红了但没打断**。若连 `SMOKE OK` 都没有，
  说明抛错了，回去核 Step 3/4 的守卫。

- [ ] **Step 7: 本 Step 不提交**

Task 1 是 TDD 的中间态（断言红、实现还没写）。它与 Task 2 **合并为一次提交**（见 Task 2 Step 6）。

---

### Task 2: 生产改造 —— 两条闸门字段化 + 格子面板派生

**Files:**
- Modify: `core/sim/weapon_inventory.gd`（:11-16 注释、:23-24 常量、:38-39 `_init`、:59-62 `can_hold`）
- Modify: `ui/weapon_slots.gd`（:14-21 常量、:32-44 `attach_to`、:47-54 `setup`、:61-62 `refresh`、:67、:80-98 `_draw`、:101-106 `_draw_empty_cells`）
- Modify: `ui/hud.gd`（:303）
- Modify: `tests/ground_action_probe.gd`（:190-191 注释、:195-196、:208-209）

**Interfaces:**
- Consumes: 无（本计划只改自己的两个类）。
- Produces:
  `WeaponInventory.DEFAULT_CAPACITY`（= 8）/ `DEFAULT_MAX_WEAPONS`（= 4）、
  实例字段 `capacity` / `max_weapons`、`set_capacity(n)` / `set_max_weapons(n)`、
  `_init(tiers, new_capacity := DEFAULT_CAPACITY, new_max_weapons := DEFAULT_MAX_WEAPONS)`；
  `WeaponSlots.capacity` / `.rows` / `.panel_h`、静态 `rows_for(cap)` / `panel_h_for(cap)`。

- [ ] **Step 1: `weapon_inventory.gd` 常量改字段**

`:11-16` 那段注释里的"容量(8 格)"与"4 把"改成"**默认** 8 格 / **默认** 4 把"，并补一句
为什么可配。`:23-24` 的两个常量换成：

```gdscript
# 两条闸门的**默认值**。★ 名字带 `DEFAULT_` 是刻意的:它们只在**构造**时用一次,
# 之后每个实例各自持有 `capacity` / `max_weapons` —— 别再让调用方读这两个常量当"容量"
# (那会得到"默认值"而不是"这个背包的容量",是**静默的错值**)。
const DEFAULT_MAX_WEAPONS := 4
const DEFAULT_CAPACITY := 8

var max_weapons: int = DEFAULT_MAX_WEAPONS
var capacity: int = DEFAULT_CAPACITY
```

`:38-39` 的 `_init` 改成（新增两个可选形参，默认值就是原来那两个数）：

```gdscript
func _init(tiers: Dictionary, new_capacity: int = DEFAULT_CAPACITY,
		new_max_weapons: int = DEFAULT_MAX_WEAPONS) -> void:
	_tiers = tiers
	# ★ 钳到 ≥ 1:0 格 / 0 把会让 `can_hold()` 恒假 ⇒ 玩家永远捡不起任何枪(死锁),
	#   而那种配置错误在实机上表现为"拾取没反应",查起来很久。
	capacity = maxi(1, new_capacity)
	max_weapons = maxi(1, new_max_weapons)


func set_capacity(n: int) -> void:
	capacity = maxi(1, n)


func set_max_weapons(n: int) -> void:
	max_weapons = maxi(1, n)
```

`:59-62` 的 `can_hold` 改成读字段（**判据结构一个字不动**，只换数据源）：

```gdscript
func can_hold(type_id: int) -> bool:
	if held.size() >= max_weapons:
		return false
	return used_cell_count() + cost_of(type_id) <= capacity
```
★ `can_hold` 里那个 `used_slots()` 是**计划 1 改过名的 `used_cell_count()`** —— 本 Step 只换
数据源（常量 → 字段），**不改名**。写回 `used_slots()` 是**同一脚本内的调用** ⇒ **Parse Error**
（响亮，不会静默）。
★ `weapon_inventory.gd` 里**没有别的** `CAPACITY`/`MAX_WEAPONS` 读者（本文件的
`used_cell_count` / `cost_of` / `add` / `restore` 都不碰它们）—— 改完
`grep -n "MAX_WEAPONS\|CAPACITY" core/sim/weapon_inventory.gd`
在这个文件里应当只剩 `DEFAULT_*` 与 `max_weapons`/`capacity`。

- [ ] **Step 2: `ui/weapon_slots.gd` 派生**

`:14-21` 那一块换成：

```gdscript
const COLS := 4
const CELL := 22.0        # 格子边长(用户 2026-09-16「缩小一点」:32 → 22)
const GAP := 3.0          # 格间距
const PAD := 6.0          # 底板内边距

# ★ PANEL_W 只跟**列数**有关 ⇒ 仍是常量(容量长大时格阵向下长,不换行宽)。
const PANEL_W := COLS * CELL + (COLS - 1) * GAP + PAD * 2.0   # 109.0

# 本实例的容量(= 背包容量,`_derive_layout` 里取)与由它派生的行数/面板高。
# ★ `ROWS := 2` / `PANEL_H := 59.0` 两个常量**已删**(2026-09-25):它们现在由容量派生。
#   删干净是刻意的 —— 留着常量名会让"静态读一个失效的值"编得过(**静默**),
#   而删掉之后每一处漏改都是解析期的错。
# ★ 三个初始化式的**声明顺序**是承重的:`rows`/`panel_h` 读上面那个 `capacity`。
var capacity: int = WeaponInventory.DEFAULT_CAPACITY
var rows: int = rows_for(capacity)
var panel_h: float = panel_h_for(capacity)
```

在 `var _weapons: WeaponComponent = null`（原 `:27`）附近加两个静态派生函数：

```gdscript
# 容量 → 行数。列数恒 COLS,容量长大时**向下长**。
static func rows_for(cap: int) -> int:
	return maxi(1, ceili(float(cap) / float(COLS)))


# 容量 → 面板高(与 PANEL_W 同一套 PAD/GAP)。默认容量 8 ⇒ 2 行 ⇒ 59.0(与改动前逐字相同)。
static func panel_h_for(cap: int) -> float:
	var r := rows_for(cap)
	return r * CELL + (r - 1) * GAP + PAD * 2.0


# 从背包重取容量并重算行数/面板高。`setup()` 与 `refresh()` 都调它。
func _derive_layout() -> void:
	var cap := WeaponInventory.DEFAULT_CAPACITY
	if _weapons != null and _weapons.inventory != null:
		cap = _weapons.inventory.capacity
	capacity = maxi(1, cap)
	rows = rows_for(capacity)
	panel_h = panel_h_for(capacity)
```

`:32-44` 的 `attach_to`，**只改 `PANEL_H` 那两处**（`PANEL_W` 留着）：

```gdscript
	s.offset_top = -112.0 - s.panel_h - 8.0   # 落在既有武器区(offset_top=-112)正上方
	s.offset_right = s.offset_left + PANEL_W
	s.offset_bottom = s.offset_top + s.panel_h
```
★ 那两行排在 `s.setup(weapons)` **之后** ⇒ `panel_h` 已经是本实例的值（`setup` 里调
`_derive_layout()`）。**顺序不能反**。

`:47-54` 的 `setup`：

```gdscript
func setup(weapons: WeaponComponent) -> void:
	_weapons = weapons
	_derive_layout()
	custom_minimum_size = Vector2(PANEL_W, panel_h)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _weapons != null:
		_weapons.weapon_changed.connect(_on_changed)
		_weapons.inventory_changed.connect(refresh)
	refresh()
```

`:61-62` 的 `refresh`：

```gdscript
func refresh() -> void:
	# ★ 每次重取容量:容量/把数现在是**实例字段**(将来按能力分叉),改了之后格子阵要跟着长。
	#   今天生产路径上没有运行时改容量的地方 ⇒ 这一步恒等于 no-op(见已知边界)。
	_derive_layout()
	queue_redraw()
```

`:67` 的底板与 `:80-98` 的 `owner_of` 循环（**只有 `CAPACITY` → `capacity` 与
`PANEL_H` → `panel_h` 两处改名**）：

```gdscript
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, panel_h)), PLATE_COLOR, true)
```
```gdscript
	# 容量格 → 归属的背包下标(-1 = 未占)。紧凑排布保证是连续段。
	var owner_of: Array[int] = []
	owner_of.resize(capacity)
	owner_of.fill(-1)
	for i in held.size():
		var cost: int = inv.cost_of(int(held[i]["type"]))
		# ★ 这一行的函数名是**计划 2** 改的(`slot_start` → `cell_start`);开工时按当时的
		#   文件名写。本计划改的只有下面那几个 `CAPACITY`。
		var start: int = inv.cell_start(i)
		for c in range(start, start + cost):
			if c >= 0 and c < capacity:
				owner_of[c] = i

	for cell in capacity:
		var col := cell % COLS
		# ★ 整数除法(`cell` 与 `COLS` 都是 int):3 行的格阵靠它算出行号,别改成 float 除法。
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		var oi: int = owner_of[cell]
		var col_c := UiFactory.C_SLOT_EMPTY
		if oi >= 0:
			col_c = UiFactory.C_SLOT_ACTIVE if oi == _weapons._current_index else UiFactory.C_SLOT_FILLED
		draw_rect(Rect2(p, Vector2(CELL, CELL)), col_c, true)
```

`:101-106` 的 `_draw_empty_cells`：

```gdscript
func _draw_empty_cells() -> void:
	for cell in capacity:
		var col := cell % COLS
		var row := cell / COLS
		var p := Vector2(PAD + col * (CELL + GAP), PAD + row * (CELL + GAP))
		draw_rect(Rect2(p, Vector2(CELL, CELL)), UiFactory.C_SLOT_EMPTY, true)
```

- [ ] **Step 3: `ui/hud.gd:303` 改读实例字段**

```gdscript
	_slots.offset_right = MARGIN.x + WeaponSlots.PANEL_W
	_slots.offset_bottom = _weapon_wrap.position.y - WEAPON_SLOTS_GAP
	_slots.offset_top = _slots.offset_bottom - _slots.panel_h
```
★ `PANEL_W` **不动**（它是常量）；只有 `PANEL_H` 那个静态读换成实例读。
★ 这是全仓**唯一**的 `WeaponSlots.PANEL_H` 静态读（`attach_to` 自己那两处也在本文件里，
Step 2 已改）。

- [ ] **Step 4: `tests/ground_action_probe.gd` 的 4 处静态读改实例读**

`_phase_pickup_replaces_when_full()`（:188 起）。在 `var p: Node2D = _players[1]`（:190）
之后加一行，并把注释里的"= CAPACITY"改成"= 默认容量"：

```gdscript
	var p: Node2D = _players[1]
	# ★ 容量取**这个背包自己的**字段,不再读类常量(常量已删;语义也从"默认值"变成"本实例")。
	var cap: int = p.weapons.inventory.capacity
	# 先把背包塞满:两把重型 = 4+4 = 8 格 = 默认容量(★ 用 set_initial_inventory 是**发放**路径,
	# 它照 `add()` 直加、不过容量闸门;要测闸门就得自己摆成"刚好满"的合法状态,别拿它塞 4 把)
```
`:195-196` / `:208-209`（★ `used_slots()` → **`used_cell_count()`** 是**计划 1 改的名**；
本 Step 只把常量换成字段。这里在探针里是**动态调用**，写回旧名不报错、只在运行时炸）：

```gdscript
	_check(p.weapons.inventory.used_cell_count() == cap,
			"且正好占满容量(%d/%d)" % [p.weapons.inventory.used_cell_count(), cap])
```
```gdscript
	_check(p.weapons.inventory.used_cell_count() <= cap,
			"替换后不超容(%d/%d)" % [p.weapons.inventory.used_cell_count(), cap])
```

- [ ] **Step 5: 跑 —— 应该全绿；然后逐条反证**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/weapon_inventory_smoke.gd 2>&1 | tail -5
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "FAIL|SMOKE"
"$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn \
  2>&1 | grep -E "ALL-OK|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn \
  2>&1 | grep -E "ALL-OK|FAIL"
"$GODOT" --headless --path . --quit-after 120 res://scenes/main_menu.tscn 2>&1 \
  | grep -cE "SCRIPT ERROR|Parse Error"
```
Expected: `WEAPON_INVENTORY OK`、`SMOKE OK`（无 FAIL）、
`LEVEL0 SCATTER: ALL-OK`、`GROUND ACTION PROBE: ALL-OK`、最后一行 `0`。

**反证（逐条，改回来再跑下一条）**：
1. **闸门读的到底是字段吗**：把 `weapon_inventory.gd` 的 `can_hold` 里
   `<= capacity` 临时改回 `<= DEFAULT_CAPACITY`，跑第 1 条命令。
   Expected: `[FAIL] ★ 容量闸门单独生效(把数上限 9 没拦,是容量拦的)` ——
   成因：`by_cap` 的配置是 4 格容量、占 4 格，判据换回常量 8 之后 `4 + 2 <= 8` 成立 ⇒
   本该"放不下"的那一下变成"放得下"。
   ★ **如实记下**：`★ 容量闸门读的是**字段**:12 格满了…` 那一条**不会**红（`12 + 2 > 8`
   同样为假）—— 一条变异只打红它该打红的那条，这正是要观察的东西，别指望"全红"。
2. **setter 真的写进字段吗**：把 `weapon_inventory.gd` 的 `set_capacity` 函数体临时改成
   `pass`，跑第 1 条命令。
   Expected: `[FAIL] setter 设值生效(实际 100 / 6)`（`by_max` 的容量停在构造时的 100）。
3. **派生公式有没有牙齿**：把 `rows_for` 的 `return` 临时改成 `return 2`，跑第 2 条命令。
   Expected: `FAIL - rows_for(12) = 3(实际 2)` / `rows_for(16) = 4(实际 2)` /
   `rows_for(1) = 1(实际 2)` / `panel_h_for(12) = 84(实际 59)` / `panel_h_for(1) = 34(实际 59)`
   一起红。
4. **接线在不在**：把 `setup()` 里那行 `_derive_layout()` 临时删掉，跑第 2 条命令。
   Expected: `FAIL - WeaponSlots.setup() 必须调 _derive_layout()(…)`。
5. **默认观感有没有变**：把 `panel_h_for` 的 `return` 临时改成 `return 60.0`，跑第 3 条命令。
   Expected: `FAIL - 1 把枪时容量面板高应仍是 59px(实际 60.0)`（四个 loadout 各一条，共 4 条）。
   ★ **同时**会红一条**不在本组命令里**的：`enemy_logic_smoke` 的 `panel_h_for(8) = 59(实际 60.0)`
   —— 那是同一处变异的第二个观测点（跑第 2 条命令能看到）。两条一起红是预期的，
   别按"越界"读。
   ★ 既有的**间隙**断言（`间隙恒为 8px`）**不会**红 —— `offset_top` 与 `size.y` 都由同一个
   `panel_h` 推出，两者一起平移 ⇒ 间隙不变。所以要钉住"默认高没变"只能靠这一条。
6. 全部改回来，再跑一遍上面那组命令确认恢复全绿。

- [ ] **Step 6: 提交（Task 1 + Task 2 合并为一次）**

```bash
git add core/sim/weapon_inventory.gd ui/weapon_slots.gd ui/hud.gd \
        tests/weapon_inventory_smoke.gd tests/enemy_logic_smoke.gd \
        tests/ground_action_probe.gd tests/level0_weapon_scatter_probe.gd
git commit -F - <<'EOF'
feat(weapon): 容量/把数改成可配的实例字段;容量格子面板由容量派生
EOF
```

---

### Task 3: 回归 + 登记（含"按能力分叉必须进权威同步"那条已知边界）

**Files:**
- Modify: `CLAUDE.md`（§参数体系 的 `Settings` 那条之后、§武器与子弹 的「武器背包与地面拾取」小节内）

**Interfaces:**
- Consumes: 无。
- Produces: 无（回归 + 文档）。

- [ ] **Step 1: 全量回归**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "FAIL|SMOKE"
for t in weapon_pickup_probe level0_weapon_scatter_probe ground_action_probe \
         ground_client_probe net_ground_probe kh_l3_probe kh_l4_probe kh_l5_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
done
for t in weapon_inventory_smoke ground_weapon_field_smoke laser_weapon_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR" | tail -3
done
"$GODOT" --headless --path . -s res://tests/pvp_twin_smoke.gd 2>&1 | grep -E "OK|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_replica_probe.tscn 2>&1 \
  | grep -E "ALL-OK|FAIL"
```
Expected: 逐行 `ALL-OK` / `SMOKE OK` / `*_OK`，无 FAIL。
★ `kh_l3_probe` 里 `enabled_types` 的**条数**断言（`set_enabled_types([1, 2])` 后
`size() == 4`）与容量无关，本计划没碰启用表，应当原样绿。
★ `kh_l4`/`kh_l5` 扫的是 `res://ui` 与 `res://tests` 的**字号规范** —— 本计划在
`weapon_slots.gd` 里没引入任何字号载体（`CELL`/`GAP`/`PAD` 是像素尺寸，不受该约定限制），
应当原样绿。
★ `squash_replica_probe` 的**相⓪**按函数体/字段清单对账 `match_snapshot.gd` 的玩家载荷表 ——
本计划不动协议，应当原样绿；它红了说明越界了。

- [ ] **Step 2: 登记进 CLAUDE.md**

在 **§武器与子弹** 的「**武器背包与地面拾取（2026-09-15）**」小节里，
紧跟"**背包 = 8 格容量预算 + 4 把上限两条并行闸门**"那一条之后补一条：

```markdown
- ★ **两条闸门自 2026-09-25 起是**可配的实例字段**（`WeaponInventory.capacity` /
  `max_weapons`，构造参数 + `set_capacity()` / `set_max_weapons()`，均钳到 ≥ 1）。
  两个 `const CAPACITY / MAX_WEAPONS` **已删除**，只留**默认值**常量
  `DEFAULT_CAPACITY`(=8) / `DEFAULT_MAX_WEAPONS`(=4)。★ 删干净是刻意的：留着常量名会让
  8 处静态读（`ui/weapon_slots.gd` 4 处 + `tests/ground_action_probe.gd` 4 处）
  **编得过但读的是"默认值"而不是"这个背包的容量"** —— 那是静默的错值。
  `ui/weapon_slots.gd` 的 `capacity` / `rows` / `panel_h` 由背包容量派生
  （`COLS` 恒 4，容量长大时格阵**向下长**；`PANEL_W` 只跟列数有关，仍是常量），
  `ROWS` / `PANEL_H` 两个常量已删。
- ★★ **已知边界（登记，不修）：容量/把数一旦真的按能力分叉，它必须进权威同步。**
  今天它可以不进 `capture_state`、也不进 `match_options`，**唯一理由是默认值不变 ⇒
  两端天然一致**（`pick_up` 的 `can_hold` 是**服务器裁决**的，而客户端 UI 也读它）。
  真按能力分叉的那天，不同步就是"**客户端显示还能捡、服务器说满了**" —— 又一个不报错的
  分叉。★ 同一批还有第二半：**运行时改容量之后没有任何东西会替你重排 UI**
  （`WeaponSlots.refresh()` 会重取容量并重画格子阵，但 HUD 的 `_place_weapon_slots()`
  不在它的调用链上）—— 今天没有运行时改容量的路径，故这条**没有生产调用点**。
```

并在 **§参数体系** 那条关于"玩家/敌人参数不是 autoload"的 bullet 之后补一句：

```markdown
- ★ **武器容量/把数（`WeaponInventory.capacity` / `max_weapons`）也是游戏规则**（用户
  2026-09-15 裁定二者都不删），2026-09-25 起可配但**默认值不变** —— 别因为它们变成字段
  就顺手把它塞进 `capture_state` / `match_options`（协议零改动是刻意的，理由见 §武器与子弹
  的「两条闸门」那条）。
```

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 登记武器容量/把数可配 + "按能力分叉必须进权威同步"的已知边界
EOF
```

---

## Self-Review

**1. 覆盖面**（对照 spec §4.4）：`CAPACITY` / `MAX_WEAPONS` → 实例字段 + 默认值 + setter ✅
Task 2 Step 1；`WeaponSlots` 的 `ROWS` 派生、`COLS` 固定 4、`PANEL_W`/`PANEL_H` 跟随 ✅
Task 2 Step 2；"协议零改动" ✅（默认值不变，没有任何协议字段被碰，Task 3 Step 1 的
`squash_replica_probe` / `pvp_twin_smoke` 是它的守卫）；§6.2 的已知边界 ✅ Task 3 Step 2。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。每处改动都给了完整代码块与确切锚点。
唯一的"按当时情况写"是 `inv.cell_start(i)` 那一行 —— 那是**计划 2** 的地盘，
已就地注明（本计划改的只有 `CAPACITY` → `capacity`）。

**2b. 词汇（本批核验报告的 ❌ 项，已修）**：本计划全篇用的是**计划 2 改名之后**的名字 ——
`used_cell_count()`（原 `used_slots()`）、`CELL_COST`（原 `SLOT_COST`）、`cell_start()`
（原 `slot_start`）。★ spec §3 那张表**不完整**（不含 `used_slots` / `SLOT_COST` 两条），
照它写会让本计划的 Step 1 里留下 `WI.SLOT_COST` ⇒ 取不存在的常量 ⇒ **`-s` 冒烟挂住**
（不是红），而它又落在 `if has_capacity and has_max:` **守卫之外**、守卫拦不住 ——
而 Step 6 上一版的判读规则会把这种挂住误判成"守卫写少了"。现已：① 名字全部改对；
② Step 6 补了"先查旧名残留、再查守卫"的顺序，并把那条误导性的推断删掉。

**3. 类型一致性**：`rows_for(cap: int) -> int` / `panel_h_for(cap: int) -> float`
（Task 1 Step 4 的断言按 int / float 分别 `int(...)` 与 `is_equal_approx(float(...))`）；
`capacity` / `max_weapons` / `rows` 都是 `int`，`panel_h` 是 `float`；
`_init(tiers, new_capacity, new_max_weapons)` 与 Task 1 的 `WI.new(tiers, 12, 6)` 位置对应。
`panel_h_for(8) == 59.0` / `panel_h_for(12) == 84.0` / `panel_h_for(1) == 34.0` /
`PANEL_W == 109.0` 都按 `COLS*CELL + (COLS-1)*GAP + PAD*2` 手算核过。

**4. 与另两份计划的关系** ✅ 见文件头的"关系"一节。本计划**不碰** §3 的改名（计划 2）、
**不碰**注册表（计划 3）。唯一交叠是 `weapon_component.gd` 的 `_init` —— 本计划
**一行都不改它**（计划 3 改完之后它仍是一次普通构造，默认参数正好给出 8 / 4）。

**5. 明确不在本计划范围**
- 能力/解锁系统（spec §2 非目标、§9）：本计划只把两条闸门改成**可配**。
- 把容量/把数塞进 `capture_state` / `match_options`：**刻意不做**（默认值不变 ⇒
  两端天然一致），另一半写成了 Task 3 Step 2 的已知边界。
- 数字键 5/6（spec §6.1）：`project.godot` 的 input 段**只有** `1`–`4`
  （`:97/:102/:107/:112`），且 `kh_l3_probe.gd:116-118` **反向断言** 5–0 不得有动作。
  ⇒ 把数调到 5+ 时第 5 把**只能靠滚轮**；要开 5/6 号键得先加动作 + 改
  `LocalInputSource` 的 `range(1, 5)`。**本计划不做**（spec 明确登记为已知边界）。
