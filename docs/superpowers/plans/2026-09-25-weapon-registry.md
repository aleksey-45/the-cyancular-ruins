# 武器注册表单一来源（`data/weapons.json`）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"有哪些枪"从**三张 GDScript 常量表 + 6 处硬编码的 `[1..6]` 字面量**收敛成一份
`data/weapons.json` + 一个纯静态的 `WeaponRegistry`；此后**加第 7 把枪 = 改 1 个 json +
加 1 个 tscn，零 GDScript 改动**。

**Architecture:** 新增 `core/sim/weapon_registry.gd`（`class_name WeaponRegistry`、`RefCounted`、
**纯静态、无 autoload、`-s` 可测** —— 与 `MapFormat` / `GridPathfinder` / `Weapon` 同款）
+ `data/weapons.json`（与 `data/enemies.json` / `data/tile_defs.json` 同款的数据文件）。
删掉 `WeaponComponent.WEAPONS` / `DISPLAY_NAMES` / `TIERS` 三张表，调用方一律改问 registry；
6 处 `[1, 2, 3, 4, 5, 6]` 字面量改成 `WeaponRegistry.all_ids()`。
`WeaponInventory` 的 tiers 仍是**注入**（`WeaponRegistry.tiers_map()`）—— 那正是它今天
不 import 任何武器类的原因。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`-s` 冒烟、场景探针（`--headless --quit-after`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-weapon-system-rework-design.md` §4.2 + §5
（**其顶部「2026-09-25 事实核验订正」块优先于正文**）。

## ★★ 与另两份计划的关系（开工前必读）

本计划与 `2026-09-25-weapon-naming-and-inst-protocol.md`（下称**计划 2**）、
`2026-09-25-weapon-capacity-config.md`（下称**计划 4**）**共同触碰
`scenes/player/weapon_component.gd`，三者必须串行、不得并行**。执行顺序：

**计划 2 → 计划 3（本计划）→ 计划 4。**

原因：本计划给 `weapon_component.gd` 的**改名后的**函数体里插代码
（`_init` / `set_enabled_types` / `_equip_index`），而计划 2 正是那个把
`set_enabled_slots` 改成 `set_enabled_types`、`_current_slot` 改成 `_current_type` 的人。
**本计划全篇使用 spec §3 的词汇**（`type_id` / `inst` / `index`），一处都不写旧名。

★★ **但 spec §3 那张表是不完整的** —— 计划 2 的改名范围比它长，多出来的几条本计划**会碰到**
（`cell_start` / `used_cell_count()` / `CELL_COST` / `equip_type(int)`，以及形参/循环变量
`slot`→`type_id`）。**以计划 2 的改名表为准，不以 spec §3，也不以本计划的片段为准**
（Global Constraints 有完整清单）。核验报告实测：照 spec §3 的 9 项写会让后两份计划
出现 **2 处 Parse Error + 2 处运行时挂起** —— 那是本批代价最高的一致性缺陷。

**Task 1 的 Step 0 是这条前提的机械检查**：旧名若还在，停下、先跑计划 2。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless`、**不占任何端口**；**实机开一局归用户**。
- **判据一律是 grep 文本**，不看退出码：场景探针挂住时 `--quit-after` 到期仍 `exit 0`
  且一行裁决都不打印。★ 更尖的一层（`tests/lib/probe_base.gd` 文件头）：
  **grep 到 `ALL-OK` 只证明"没有任何断言失败"，不证明"该跑的断言都跑过"**。
- ★★ **命令里的 `2>&1` 一个都不能省。** `enemy_logic_smoke._check` 的失败行走的是
  **`printerr`（stderr）**(`tests/enemy_logic_smoke.gd:64`)，`level0_weapon_scatter_probe._check`
  同理（`printerr("  FAIL - " …)`）；去掉 `2>&1` 会把"红了"读成"没有输出"，
  而"没有输出"在本仓恰好是**另一种**已知故障形态（脚本没跑起来）—— 两者会撞车。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，
  别用 `-m "…"`（双引号会**静默吞掉**反引号与 `$`）。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`；本计划不引入字号）。
- 改 GDScript **只需重导出**，不要重编裁剪模板。
- ★ **往 json 里加第 7 把枪，不许再动 `export_presets.cfg`** —— 本计划把
  `include_filter` 改成 **目录 glob**（`data/*.json`），此后任何新的 data json 都自动在列。
  ★ 关于这条的**已核实事实**：`data/weapons.json` 其实**不改过滤器也在导出包里** ——
  `.json` 是 Godot 的 **Resource 类型**（`core/io/json_resource_format.cpp:75-86` 注册扩展名
  `json`、类型名 `JSON`），而本仓两个预设都是 `export_filter="all_resources"`，导出器只跳过
  类型为 `TextFile` 的文件（`editor/export/editor_export_platform.cpp:644-649`），
  `.json` 的类型由 `ResourceLoader::get_resource_type()` 给出、非空 ⇒ **不是** `TextFile`
  ⇒ 已被收录（同目录的 `data/tile_defs.json` 今天就不在 `include_filter` 里却工作正常，
  是同一个机制）。故改 glob 是**保险带**（挡住"将来有人把 export_filter 换个模式"），
  **不是**这条功能的机制。别在文档里把它写成"不加就导出没有枪"。
- ★ **`WeaponRegistry` 不得 `load()` 任何武器场景**；`tier_of()` 返回**裸 `int`**。
  理由见 Task 2 的文件头注释（`weapon_base.gd:7` 的 export 默认值 preload 了 `bullet.tscn`）。
- ★★ **词汇与行号口径（本批的核验报告点名过这条，代价最高）**：
  本计划的所有代码都写在**计划 1 之后**的世界里。计划 1 是**唯一**做改名的那一份，它的改名表
  比 spec §3 的 9 项更长，本计划会碰到的有：`WeaponInventory.slot_start`→**`cell_start`**、
  `used_slots`→**`used_cell_count()`**、`SLOT_COST`→**`CELL_COST`**、
  `equip(String)`→**`equip_type(int)`**，以及形参/循环变量 `slot`→**`type_id`**
  （`player_replica._swap_weapon`、`weapon_icons.silhouette`、`level_0`/`match_ground`/
  `lobby_page`/`main_menu` 四处循环）。**照抄旧名 = Parse Error 或运行时错，不是行为变化。**
  保留 `slot` 的只有：`Player.weapon_slot` 挂点、`WeaponSlots` / `C_SLOT_*` 容量格 UI、
  `capture_state()` 的 `wslot` 键。**拿不准时以计划 1 的改名表为准，不以本计划的片段为准。**
- ★ **行号只作参考。** 本计划的行号取自 `main`（计划 1 **之前**）。计划 1 会给
  `scenes/player/weapon_component.gd` **插入若干新函数**（`inst_at_index` / `equip_inst` /
  `take_uplink_switch`）并删掉一行 ⇒ 该文件的行号会漂。每处改动都给了"改前"的原文片段，
  **按内容定位**；行号对不上时不要怀疑改动本身。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `data/weapons.json` | **新增**：武器身份的唯一来源（id/name/tier/scene） | 全新建（6 条，顺序 = 菜单 = 散落） |
| `core/sim/weapon_registry.gd` | **新增**：`class_name WeaponRegistry`，纯静态查询 | 全新建 |
| `export_presets.cfg` | 导出过滤器（**两个**预设） | `include_filter` 的 `data/enemies.json` → `data/*.json` |
| `scenes/player/weapon_component.gd` | 武器子系统（注册表/背包/换枪） | **删**三张表；`_init` / `set_enabled_types` / `_equip_index` 改问 registry |
| `scenes/level_0.gd` | 单机世界 | `_default_weapon_types` 的 `[1..6]` → `all_ids()` |
| `server/match_ground.gd` | 联机地面武器权威 | `_server_weapon_types` 同上 |
| `scenes/lobby_page.gd` | 两个大厅页共用的基类 | `_add_weapon_grid` 的 `[1..6]` → `all_ids()` |
| `scenes/main_menu.gd` | 主菜单 | `_fill_sp_panel` 的 `[1..6]` → `all_ids()`；**`i + 1` → `ids[i]`** |
| `scenes/player/player_replica.gd` | 对手视觉副本 | `WEAPONS.get(str(slot))` → `WeaponRegistry.scene_of(type_id)`（形参已被计划 1 改名为 `type_id`） |
| `scenes/weapons/weapon_pickup.gd` | 地面武器（独立场景） | `WEAPONS.get(...)` → `WeaponRegistry.scene_of(...)` |
| `ui/weapon_icons.gd` | 剪影 + 选择格（纯 UI） | `WEAPONS` / `DISPLAY_NAMES` → registry |
| `ui/hud.gd` | 单机 HUD | `DISPLAY_NAMES.get(t, "空手")` → registry + 兜底 |
| `tests/enemy_logic_smoke.gd` | 主冒烟 | `_phase_weapon_registry` **改判据**：json ↔ tscn ↔ 枚举 + ④⑤⑥ 新守卫 |
| `tests/weapon_pickup_probe.gd` | 地面武器探针 | `WeaponComponent.WEAPONS.keys()` / `[str(pk.type_id)]` → registry |
| `tests/level0_weapon_scatter_probe.gd` | 单机散落探针 | `== 12` → 按注册表算；**加**覆盖性断言 |
| `tests/kh_l3_probe.gd` | L3 场景探针 | `set_enabled_types([1, 2, 3, 4, 5, 6])` → `all_ids()` |
| `CLAUDE.md` | 项目文档 | §敌人 / §砖块属性与破坏 旁登记武器注册表 |

---

### Task 1: 新守卫先行 —— 把"可加第 7 把枪"变成可断言的红灯

**Files:**
- Modify: `tests/enemy_logic_smoke.gd`（`_phase_weapon_registry`，:1113-1159 整体改写）

**Interfaces:**
- Consumes: 现成的 `_check(cond: bool, msg: String)`、`ScanUtil`（`tests/lib/scan_util.gd`
  的 `class_name ScanUtil`，纯静态）。
- Produces: 一个**会红**的 `_phase_weapon_registry`，红的组分别是
  ① 文件缺席、④⑥ 生产代码里还有硬编码、⑤ 五处宿主还没改问注册表。

- [ ] **Step 0: 确认计划 2 已落地（前提检查）**

Run:
```bash
source tests/env.sh
# ★ 先确认这四个文件都在。不做这一步的话,文件缺失/被删会让下面的 `grep -c` 因为
#   **读不到输入**而打印 0,而"0 个旧名"这条期望就被**假满足**了 ——
#   这是机械命令静默失效的典型形态(命令本身没报错,只是没在看东西)。
missing=0
for f in scenes/player/weapon_component.gd ui/weapon_slots.gd \
         core/sim/weapon_inventory.gd scenes/level_0.gd; do
  if [ ! -f "$f" ]; then echo "MISSING: $f"; missing=1; fi
done
if [ "$missing" = 1 ]; then echo "★ 上面有 MISSING —— 停下,下面的计数不可信"; fi
# 剥掉注释再数:`sed 's/#.*//'` —— 注释里提到旧名不算数(计划 2 未必逐条改注释)。
sed 's/#.*//' scenes/player/weapon_component.gd \
  | grep -cE "_current_slot|set_enabled_slots|is_slot_enabled|enabled_slots|current_slot_int|default_slot|push_net_slot|consume_net_slot"
sed 's/#.*//' ui/weapon_slots.gd | grep -c "slot_start"
echo "--- 计划 2 的新名必须在位（否则上面那两个 0 只是'文件被删了'）---"
grep -c "_current_type\|enabled_types\|set_enabled_types" scenes/player/weapon_component.gd
grep -c "cell_start" ui/weapon_slots.gd
```
Expected: **没有任何 `MISSING`**；前两行都是 **0**，紧接着两行都 **≥ 1**。
任何一个不对 ⇒ 计划 2 未落地，**停下**，先跑计划 2
（本计划的代码写的是改名后的词汇，硬上会写进错的名字 —— 那是 Parse Error，不是行为变化）。
★ 只查"旧名为 0"会被"文件不存在/被清空"骗过，所以**正反两面都要查**。

- [ ] **Step 1: 改写 `_phase_weapon_registry`**

`tests/enemy_logic_smoke.gd` 里把 `:1113-1159` 的整个 `_phase_weapon_registry()` 换成下面这版，
并在它**上方**补三个文件级常量（紧挨该函数，别塞到文件顶）：

```gdscript
const REGISTRY_SRC := "res://core/sim/weapon_registry.gd"
const REGISTRY_JSON := "res://data/weapons.json"
# json 的 tier 字符串 → 数值。★ 这是**探针自己**的一份口径,刻意不引注册表 ——
#   本相要在"注册表文件还不存在"时也跑得出干净的断言(见下面 wr 的取法)。
#   它与 WeaponBase.Tier 的对齐由本相 ③ 钉着。
const TIER_STRINGS := {"light": 0, "medium": 1, "heavy": 2}


# ── 武器注册表单一来源(data/weapons.json,2026-09-25)──
# 旧口径(三张 GDScript 常量表)下,加新武器时漏填的表现各不相同:
#   WEAPONS 漏 → 切枪时 load("") 报错(响);DISPLAY_NAMES 漏 → HUD 显示空(看得见);
#   TIERS 漏 → **容量算错**(轻武器被当成重武器,8 格只能带两把),完全不报错。
# 现在三样都在**同一份 json 的同一行**里,结构性地不可能漏一半;但"改了 json 忘了改
# tscn 的 tier export"仍然可能(两份数据刻意重复,与 `data/enemies.json` 同构),故逐条比。
#
# ★★ 为什么用 `load()` 拿到 GDScript 再调它的**静态函数**,而不直接写 `WeaponRegistry.xxx()`:
#   本文件是 `-s` 冒烟,而**全局类名在文件不存在时会让整个脚本 Parse Error** ⇒ 一条断言都
#   跑不到、进程挂死(`-s` 脚本抛错走不到 quit(),本仓踩过)。`load()` + 空守卫让"文件还没建"
#   表现为**干净的红**,而不是超时。
#   ★ 静态函数**可以**在 GDScript 对象上调:引擎 `modules/gdscript/gdscript.cpp:928-940` 的
#   `GDScript::callp` 就是查 `member_functions` 并 `ERR_FAIL` 掉非 static 的那一个。
func _phase_weapon_registry() -> void:
	var wc: GDScript = load("res://scenes/player/weapon_component.gd")
	var wi: GDScript = load("res://core/sim/weapon_inventory.gd")
	var wb: GDScript = load("res://scenes/weapons/weapon_base.gd")
	_check(wc != null and wi != null and wb != null, "武器注册表三件套可加载")
	if wc == null or wi == null or wb == null:
		return

	# ── ① 注册表文件到位 ──
	var json_text := FileAccess.get_file_as_string(REGISTRY_JSON)
	_check(not json_text.is_empty(), "读得到 " + REGISTRY_JSON + "(读不到 = 文件还没建)")
	var wr: GDScript = null
	if ResourceLoader.exists(REGISTRY_SRC):
		wr = load(REGISTRY_SRC)
	_check(wr != null, "core/sim/weapon_registry.gd 存在且可加载")

	# ── ② json ↔ 各 .tscn 的 tier export ↔ 枚举值(逐条对账)──
	var rows := {}   # id -> {name, tier, scene}
	if not json_text.is_empty():
		var parsed: Variant = JSON.parse_string(json_text)
		var ok_shape := typeof(parsed) == TYPE_DICTIONARY and (parsed.get("weapons", []) is Array)
		_check(ok_shape, "weapons.json 顶层是 {\"weapons\": [...]}")
		if ok_shape:
			for raw in parsed["weapons"]:
				if typeof(raw) != TYPE_DICTIONARY:
					_check(false, "每条都应是对象(实际 %s)" % str(raw))
					continue
				var e: Dictionary = raw
				# ★ 用 `int(...)` 归一化:JSON 的数字在 GDScript 里解析成 float,
				#   不归一化的话 `rows.has(id)` 会永远假(1.0 != 1),而 `row.size()` 却是对的 ——
				#   那种"一半对一半错"最难查。
				var id := int(e.get("id", 0))
				var tier_s := str(e.get("tier", ""))
				var scene_path := str(e.get("scene", ""))
				var wname := str(e.get("name", ""))
				_check(id > 0, "id 是正整数(实际 %s)" % str(e.get("id")))
				_check(not rows.has(id), "id %d 不重复" % id)
				_check(not wname.is_empty(), "id %d 有 name" % id)
				_check(TIER_STRINGS.has(tier_s), "id %d 的 tier 是三值之一(实际 \"%s\")" % [id, tier_s])
				var tscene: PackedScene = load(scene_path)
				_check(tscene != null, "id %d 的 scene 能 load(%s)" % [id, scene_path])
				if tscene != null:
					var inst: Node = tscene.instantiate()
					var want_tier := int(TIER_STRINGS.get(tier_s, -1))
					_check(int(inst.tier) == want_tier,
							"id %d:tscn 的 tier(%d)必须等于 json 的 \"%s\"(%d)" % [
								id, int(inst.tier), tier_s, want_tier])
					inst.free()
				rows[id] = {"name": wname, "tier": tier_s, "scene": scene_path}
	# ★ 这一条**放在 if 外面**:json 文件缺席时它也要红(否则"文件没建"这件事只有上面
	#   那一条在报,而"json 建了但一条都不合格"这条路径就没有守卫)。
	_check(rows.size() > 0, "json 至少有 1 条合格条目(实际 %d)" % rows.size())

	# ── ③ 注册表的查询结果 == 上面那份 json(防"json 对、注册表映射写错")──
	if wr != null:
		var reg_ids: Array = wr.all_ids()
		_check(reg_ids.size() == rows.size(),
				"注册表条数应等于 json 合格条数(%d vs %d)" % [reg_ids.size(), rows.size()])
		for id in rows:
			var r: Dictionary = rows[id]
			_check(int(wr.tier_of(int(id))) == int(TIER_STRINGS[r["tier"]]),
					"tier_of(%d) 应 = %d(实际 %d)" % [id, int(TIER_STRINGS[r["tier"]]), int(wr.tier_of(int(id)))])
			_check(str(wr.scene_of(int(id))) == str(r["scene"]),
					"scene_of(%d) 应 = %s(实际 %s)" % [id, str(r["scene"]), str(wr.scene_of(int(id)))])
			_check(str(wr.name_of(int(id))) == str(r["name"]),
					"name_of(%d) 应 = %s(实际 %s)" % [id, str(r["name"]), str(wr.name_of(int(id)))])
			_check(wr.has(int(id)), "has(%d) 为真" % id)
			_check(not wr.has(int(id) + 9000), "has(%d) 为假(越界 id 不该命中)" % (int(id) + 9000))
		var want_map := {}
		for id in rows:
			want_map[id] = int(TIER_STRINGS[(rows[id] as Dictionary)["tier"]])
		var got_map: Dictionary = wr.tiers_map()
		var map_ok := got_map.size() == want_map.size()
		for id in want_map:
			if int(got_map.get(id, -1)) != int(want_map[id]):
				map_ok = false
		_check(map_ok, "tiers_map() 与 json 逐条一致(实际 %s、期望 %s)" % [str(got_map), str(want_map)])

	# ── ④ WeaponInventory 的 tier 常量与 WeaponBase.Tier 数值对齐(旧版原有,一处没动)──
	#    (wi 刻意不 import weapon_base,所以这条对齐是**约定**而不是编译器保证的。
	#     WeaponRegistry.TIER_NAMES 直接复用 wi.TIER_*,故本相 ③ 的比对已覆盖它。)
	_check(int(wi.TIER_LIGHT) == int(wb.Tier.LIGHT), "TIER_LIGHT 与 WeaponBase.Tier.LIGHT 对齐")
	_check(int(wi.TIER_MEDIUM) == int(wb.Tier.MEDIUM), "TIER_MEDIUM 与 WeaponBase.Tier.MEDIUM 对齐")
	_check(int(wi.TIER_HEAVY) == int(wb.Tier.HEAVY), "TIER_HEAVY 与 WeaponBase.Tier.HEAVY 对齐")
	# ★ 下面两条**原样保留**(旧版 `:1158-1159`)。它们是"容量 8 / 把数上限 4 是游戏规则"
	#   的钉子,归**计划 4**(容量/把数可配)改判据 —— 那时它们会改成读
	#   `DEFAULT_CAPACITY` / `DEFAULT_MAX_WEAPONS`。本计划**别删**它们。
	_check(int(wi.MAX_WEAPONS) == 4, "WeaponInventory.MAX_WEAPONS == 4")
	_check(int(wi.CAPACITY) == 8, "WeaponInventory.CAPACITY == 8")

	# ── ⑤ 生产代码里不得再有硬编码的武器 id 列表 ──
	# 6 个字面量 / 5 个文件(weapon_component.gd 里有两处)全部改问 all_ids() 之后,本相零命中。
	# ★ 判据用**剥注释 + 去空格**的视图:`[1,2,3,4,5,6]`(无空格)也要挡住。
	# ★ 只扫生产目录(scenes/core/server/ui):tests 里的 `[1, 2, 3, 4, 5, 6]` 有合法的
	#   **role 列表**用途(`team_host_probe.gd:373,421`、`team_spawn_smoke.gd:28,36`),扫进
	#   tests 会恒红 —— 唯一例外(`kh_l3_probe.gd:187` 那处真是武器列表)由 Task 4 点名处理。
	var offenders: Array = []
	for path in ScanUtil.collect(["res://scenes", "res://core", "res://server", "res://ui"]):
		var src := ScanUtil.read(path)
		if src.is_empty():
			continue
		if ScanUtil.code_only(src).replace(" ", "").contains("[1,2,3,4,5,6]"):
			offenders.append(path)
	_check(offenders.is_empty(),
			"生产代码里不得再有硬编码的武器 id 列表(命中:%s)" % str(offenders))

	# ── ⑥ 六处字面量的**宿主**确实改问了注册表 ──
	# ★ ⑤ 挡的是"还留着老写法",⑥ 挡的是"新写法没接上" —— 只有 ⑤ 时,把
	#   `_default_weapon_types` 整个删掉(或改成 `return []`)照样全绿。
	# ★ 按**函数体**判,不按整文件 contains:同一文件里别处出现 `all_ids()` 不能替这一处背书
	#   (level_0.gd 有 600+ 行)。
	#
	# ★★ **`weapon_component.gd` 那一处锚在 `_init` 上是刻意的,而且它约束了实现形状**
	#   (2026-09-26 订正):该文件的两个字面量分别在 `:54`(**class 级**的
	#   `var enabled_types: Array = [1, 2, 3, 4, 5, 6]`)与 `:71`(`set_enabled_types` 体内),
	#   **`_init` 的函数体里一个字面量都没有** ⇒ 这条断言今天为假。
	#   为什么不锚 `:54`:**`ScanUtil.func_body` 表达不了 class 级的 `var`** ——
	#   它按 `"func " + name + "("` 找起点,没有函数就没有起点。
	#   为什么选"把默认值搬进 `_init`"而不是"换个锚点":默认值只能活在两处之一是
	#   **语言事实** —— class 级 initializer 或 `_init`;而 ⑦ 要求"刚 `new()` 出来"
	#   的组件就带全量启用表 ⇒ 必须在构造期完成。既然 class 级那处**无法被任何机制断言**,
	#   就把它搬进 `_init`(Task 3 Step 1 做的正是这件事)。
	#   ⇒ **⑤ + ⑥ 合起来把实现形状钉死了**:`:54` 的字面量必须消失(⑤),
	#     且 `_init` 体内必须出现 `all_ids()`(⑥)。两种改法能满足:
	#     ① `var enabled_types: Array = []` + `_init` 里 `enabled_types = all_ids()`
	#        ← **本计划选这条**(Task 3 Step 1 就是这个形状);
	#     ② `var enabled_types: Array = []` + `_init` 里 `set_enabled_types([])`
	#        ← 也能过 ⑥,但多绕一层、且与 `set_enabled_types` 的"入参是被禁表"语义易混,
	#        **不采用**。
	#   ★ 别把 `:54` 改成 `WeaponRegistry.all_ids()` 了事 —— 那样 ⑤ 绿、⑥ 红,
	#     而 ⑥ 的红会看起来像"`_init` 没接上",查半天。
	var sites := [
		{"path": "res://scenes/level_0.gd", "func": "_default_weapon_types"},
		{"path": "res://scenes/lobby_page.gd", "func": "_add_weapon_grid"},
		{"path": "res://scenes/main_menu.gd", "func": "_fill_sp_panel"},
		{"path": "res://server/match_ground.gd", "func": "_server_weapon_types"},
		{"path": "res://scenes/player/weapon_component.gd", "func": "_init"},
		{"path": "res://scenes/player/weapon_component.gd", "func": "set_enabled_types"},
	]
	for s in sites:
		var src := ScanUtil.read(s["path"])
		if src.is_empty():
			_check(false, "读到 %s(读不到就是红,不是静默跳过)" % s["path"])
			continue
		var body := ScanUtil.func_body(ScanUtil.code_only(src), s["func"])
		if body.is_empty():
			_check(false, "在 %s 里找到函数 %s()" % [s["path"], s["func"]])
			continue
		_check(body.contains("WeaponRegistry.all_ids()"),
				"%s 的 %s() 应改用 WeaponRegistry.all_ids()" % [s["path"], s["func"]])

	# ── ⑦ 覆盖性:默认启用表必须**等于**注册表全部 id ──
	# 这是 spec §4.2 点名要加、而今天**没有**的那条守卫。
	# ★ 三处散落/菜单/禁用网格现在都从 all_ids() 取数 ⇒ "覆盖"是构造性的(由 ⑥ 保证);
	#   真正会漂的是**默认启用表** —— 它今天是一条硬编码的 `[1, 2, 3, 4, 5, 6]`,
	#   加第 7 把枪时漏改它,新枪**永远拿不到也开不了**,而**完全不报错**。
	if wr != null:
		var want_ids: Array = wr.all_ids()
		var comp = wc.new()
		_check(comp.enabled_types == want_ids,
				"默认启用表必须等于注册表全部 id(实际 %s、注册表 %s)" % [
					str(comp.enabled_types), str(want_ids)])
		comp.free()
```

★ **`_phase_weapon_registry()` 的调用点不动**（`tests/enemy_logic_smoke.gd:127`，
已经在 `_initialize()` 末尾）。本相**改的是判据、不是次序** —— `_initialize` 里那 27 节
的顺序仍是回归基线，别顺手挪。

- [ ] **Step 2: 跑一次，逐条记下红在哪**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd \
  2>&1 | tail -60
```
Expected（改动前，**必须是这一组、恰好 10 条**）:
```
  FAIL - 读得到 res://data/weapons.json(读不到 = 文件还没建)
  FAIL - core/sim/weapon_registry.gd 存在且可加载
  FAIL - json 至少有 1 条合格条目(实际 0)
  FAIL - 生产代码里不得再有硬编码的武器 id 列表(命中:[res://scenes/level_0.gd, ...])
  FAIL - res://scenes/level_0.gd 的 _default_weapon_types() 应改用 WeaponRegistry.all_ids()
  FAIL - res://scenes/lobby_page.gd 的 _add_weapon_grid() 应改用 WeaponRegistry.all_ids()
  FAIL - res://scenes/main_menu.gd 的 _fill_sp_panel() 应改用 WeaponRegistry.all_ids()
  FAIL - res://server/match_ground.gd 的 _server_weapon_types() 应改用 WeaponRegistry.all_ids()
  FAIL - res://scenes/player/weapon_component.gd 的 _init() 应改用 WeaponRegistry.all_ids()
  FAIL - res://scenes/player/weapon_component.gd 的 set_enabled_types() 应改用 WeaponRegistry.all_ids()
FAILURES: ["读得到 …weapons.json(读不到 = 文件还没建)", … 共 10 条]
```
（10 = ① 2 条 + `json 至少有 1 条` 1 条 + ④ 1 条 + ⑥ 6 条。）
★★ **尾行不是 `SMOKE OK`，而且这一趟的退出码是 1 —— 那是正常的红，不是崩溃。**
`tests/enemy_logic_smoke.gd:130-135` 是：
```gdscript
	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("FAILURES: " + str(_failures))   # ← 有失败时走这一支
		quit(1)
```
⇒ 有失败时**打的是 `FAILURES: […]`（走 `printerr`，即 stderr）并 `quit(1)`**。
★ 命令里的 **`2>&1` 不能省**（不然连 `FAILURES:` 都看不到），而且**别把 `quit(1)` 当失败信号**
去 `set -e` —— 本相的整趟run 预期就是"退出码 1 + 恰好 10 条 FAIL"。
★ **判读规则**（这几条不成立就不要往下走）：
- ④ 的命中清单必须**恰好是 5 个文件**：`scenes/level_0.gd`、`scenes/lobby_page.gd`、
  `scenes/main_menu.gd`、`server/match_ground.gd`、`scenes/player/weapon_component.gd`。
  多出别的文件 ⇒ 扫到了假阳性，先查清（多半是某个 `[1, 2, 3, 4, 5, 6]` 被写成了别的含义）。
- ③ 与 ⑦ **不得出现**在 FAIL 列表里：`wr == null` ⇒ ③ 整段被跳过（`if wr != null`），
  ⑦ 同理。这是设计如此，不是漏跑。
- ② 的逐条断言**不得出现**：json 是空的 ⇒ `if not json_text.is_empty():` 整块跳过。
  这一条是"json 文件建好之后"的事（Task 2 Step 5 才验）。
- ④ 组里的 tier 对齐三条（`TIER_LIGHT` / `TIER_MEDIUM` / `TIER_HEAVY`）与容量两条
  （`wi.MAX_WEAPONS` / `wi.CAPACITY`）今天**本来就是绿的**，若它们红了，说明
  `WeaponInventory` 被人改过，与本次无关 —— 停下报告。
- ★ **若连一行 `FAIL - ` 都没有（或整条命令挂住不返回）**：那是**脚本错误**
  （旧名残留、或 `ScanUtil` 解析不出来），不是"断言失败"。本计划全文用计划 1 之后的词汇；
  出现这种形状时，第一嫌疑是某处把 `slot` / `used_slots` / `SLOT_COST` 之类的旧名写回去了。

- [ ] **Step 3: 本 Step 本应不提交（★ 已被现实推翻，见下）**

Task 1 是 TDD 的中间态（测试红、实现还没写），原计划与 Task 2、Task 3 **合并为一次提交**。
★★ **实际执行时被派工指令覆盖了**：Task 1 已**单独**提交为 `128ef7c`
（`tests/enemy_logic_smoke.gd` only，+149/−40），**留下了一个红状态的提交**。
计划方（协调者）会把 Task 2 改成 `git reset --soft HEAD~1` 让测试文件与迁移一起落，
**不要**再按本 Step 的"不提交"去理解历史。**对本计划文本的其余部分没有影响** ——
Task 2/3 的判据仍按"注册表到位之后"写。

---

### Task 2: 建 `data/weapons.json` + `core/sim/weapon_registry.gd` + 导出过滤器

**Files:**
- Create: `data/weapons.json`
- Create: `core/sim/weapon_registry.gd`
- Modify: `export_presets.cfg`（两个预设的 `include_filter`，:12 与 :86）

**Interfaces:**
- Consumes: `WeaponInventory.TIER_LIGHT/MEDIUM/HEAVY`（`core/sim/weapon_inventory.gd:18-20`）。
- Produces:
  `WeaponRegistry.all_ids() -> Array[int]`、`has(type_id) -> bool`、`scene_of(type_id) -> String`、
  `name_of(type_id) -> String`、`tier_of(type_id) -> int`、`tiers_map() -> Dictionary`、
  `reload() -> void`（只给测试）。

- [ ] **Step 1: 写 `data/weapons.json`（完整内容，逐字）**

顺序 = 菜单顺序 = 散落顺序（今天 `[1..6]` 的循环顺序就是这个，现在显式化成数据）。
`id` **就是**那个整数 `type_id`；`name` / `tier` / `scene` 与今天三张表**逐字相同**。

```json
{
  "weapons": [
    { "id": 1, "name": "手枪",       "tier": "light",  "scene": "res://scenes/weapons/pistol_test.tscn" },
    { "id": 2, "name": "步枪",       "tier": "medium", "scene": "res://scenes/weapons/rifle_test.tscn" },
    { "id": 3, "name": "重狙 M82A1", "tier": "heavy",  "scene": "res://scenes/weapons/m82a1.tscn" },
    { "id": 4, "name": "霰弹 S686",  "tier": "light",  "scene": "res://scenes/weapons/s686.tscn" },
    { "id": 5, "name": "榴弹发射器", "tier": "heavy",  "scene": "res://scenes/weapons/grenade_launcher.tscn" },
    { "id": 6, "name": "激光枪",     "tier": "medium", "scene": "res://scenes/weapons/laser_gun.tscn" }
  ]
}
```
★ tier 的来源是各 tscn 的 `tier =` export（缺省 = `Tier.LIGHT` = 0）：
`pistol_test.tscn` 与 `s686.tscn` **没写** `tier`（默认 light）；`rifle_test.tscn` = 1、
`laser_gun.tscn` = 1（medium）；`m82a1.tscn` = 2、`grenade_launcher.tscn` = 2（heavy）。
与今天 `weapon_component.gd:33-40` 的 `TIERS` **逐条一致**。

- [ ] **Step 2: 写 `core/sim/weapon_registry.gd`（完整源码，逐字）**

```gdscript
class_name WeaponRegistry
extends RefCounted

# 武器注册表:唯一来源 `data/weapons.json`(与 data/enemies.json / data/tile_defs.json 同款)。
#
# ★ 纯静态、无 autoload、`-s` 可测(与 MapFormat / GridPathfinder 同款)。
#
# ★★ **绝不 `load()` 武器场景**,`tier_of()` 返回**裸 int**,不返回 `WeaponBase.Tier`:
#   `weapon_base.gd:7` 的 `@export var bullet_scene = preload("res://scenes/weapons/bullet.tscn")`
#   会把 autoload 拖进 `-s` —— `weapon_inventory.gd:6-9` 记的正是这条,它宁可让调用方
#   **注入** tiers 表也不 import 那个类。数值对齐由 enemy_logic_smoke 逐条钉住。
#
# ★ 只装身份(id / name / tier / scene 路径)。数值(fire_cooldown / damage / mag_size /
#   reload_time / recoil / …)继续留在各枪的 .tscn @export 里 —— 保住 Godot 编辑器里
#   可视化调参的能力,与 data/enemies.json 同构。
#
# ★ json **数组顺序 = 菜单顺序 = 散落顺序**(`all_ids()` 原样按 json 顺序返回)。
#   重排 json 会改变菜单与散落顺序 —— 不是 bug,但没有守卫拦误排(登记,本次不做)。

const PATH := "res://data/weapons.json"

# tier 字符串 → 数值。★ 数值直接取 `WeaponInventory.TIER_*`,**不另立一套整数** ——
#   那一套与 `WeaponBase.Tier` 的对齐由 enemy_logic_smoke 钉着(约定,不是编译器保证)。
#   const 里引用别的类的常量是本仓既有写法(见 weapon_component 旧 TIERS 表的 `WeaponBase.Tier.*`)。
const TIER_NAMES: Dictionary = {
	"light": WeaponInventory.TIER_LIGHT,
	"medium": WeaponInventory.TIER_MEDIUM,
	"heavy": WeaponInventory.TIER_HEAVY,
}

static var _entries: Array[Dictionary] = []   # [{id, name, tier, scene}],json 顺序
static var _loaded := false


# 懒加载:首次查询时读一次。不需要调用方记得先 load —— 本仓有 6 处调用点分散在
# `_ready` 的很早阶段(菜单/大厅/关卡),漏一处就是"菜单少一把枪"。
static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true   # ★ 先置位:解析失败时不要每次查询都重读+重报一遍
	_entries = []
	var text := FileAccess.get_file_as_string(PATH)
	if text.is_empty():
		push_error("WeaponRegistry: 读不到 %s —— 导出包里没有它?" % PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("weapons", []) is Array):
		push_error("WeaponRegistry: %s 顶层必须是 {\"weapons\": [...]}" % PATH)
		return
	var seen := {}
	var idx := -1
	for raw in parsed["weapons"]:
		idx += 1
		# ★★ 逐条校验:**不合格 push_error + 跳过该条**。
		#   ⚠ 这**不是** EnemySpawner 的约定 —— 它(`enemy_spawner.gd:29-31`)对逐条的坏数据
		#   只是 `continue`,一个字都不打;`push_error` + 整表留空只发生在**文件级**。
		#   本文件是"每条坏数据都有声音"的**新约定**,别拿这条去改 EnemySpawner。
		if typeof(raw) != TYPE_DICTIONARY:
			push_error("WeaponRegistry: weapons[%d] 不是对象,已跳过" % idx)
			continue
		var e: Dictionary = raw
		# ★★ `int(...)` **不是可选的美化**:JSON 的数字一律解析成 float(`1` 变 `1.0`),
		#   而 `1.0` 当字典键 / 当 `int` 形参 / 去 `.has(type_id)` 都会**静默不命中**。
		#   id 全程必须是真 int —— 出口 `all_ids()` 里那一次 `int(...)` 是二次保险,
		#   这里这次才是正本(顺带把非数字的 `id` 归一成 0、被下面那条挡掉)。
		var id := int(e.get("id", 0))
		if id <= 0:
			push_error("WeaponRegistry: weapons[%d].id 不是正整数(实际 %s),已跳过" % [idx, str(e.get("id"))])
			continue
		if seen.has(id):
			push_error("WeaponRegistry: id %d 重复(weapons[%d]),已跳过" % [id, idx])
			continue
		var tier_name := str(e.get("tier", ""))
		if not TIER_NAMES.has(tier_name):
			push_error("WeaponRegistry: id %d 的 tier 非法(实际 \"%s\";只认 light/medium/heavy),已跳过" % [id, tier_name])
			continue
		var wname := str(e.get("name", ""))
		if wname.is_empty():
			push_error("WeaponRegistry: id %d 缺 name,已跳过" % id)
			continue
		var scene := str(e.get("scene", ""))
		# ★ 只查"路径存在",**不 load** —— load 会把武器场景(以及它 preload 的 bullet.tscn)
		#   拖进 `-s`,而本文件必须能 `-s` 空跑。真正的"能不能 load / tier 对不对"由
		#   enemy_logic_smoke 的 _phase_weapon_registry 逐条验(它本来就要实例化比 tier)。
		#   ★ `ResourceLoader.exists()` 内部会走 `_path_remap`(引擎 resource_loader.cpp:1254),
		#   故导出包里 `.tscn` 的改名不影响它。
		if scene.is_empty() or not ResourceLoader.exists(scene):
			push_error("WeaponRegistry: id %d 的 scene 不存在(%s),已跳过" % [id, scene])
			continue
		seen[id] = true
		_entries.append({"id": id, "name": wname, "tier": tier_name, "scene": scene})
	if _entries.is_empty():
		# ★ 这条是**故意吼的**:它同时兜住两种"整表为空"的成因 —— json 里一条都不合格,
		#   以及导出包里没有这份 json(那种情况下上面第一条已经 push_error 了)。
		#   本特性最坏的失效模式是"发布版里一把枪都没有",不能让它静默。
		push_error("WeaponRegistry: 注册表为空 —— json 里没有合格条目,或导出包漏了 %s" % PATH)


# ★★ **必须返回真正的 int,一个 float 都不能有**(2026-09-26 订正)。
#   坑在 JSON:`JSON.parse_string` 把**所有数字都解析成 float** ⇒ `e["id"]` 是 `1.0` 而不是 `1`。
#   两步都要 `int(...)`:装载时 `var id := int(e.get("id", 0))`(那一步同时做校验),
#   以及这里 `out.append(int(e["id"]))`(二次保险,也是**要命的那一步**)。
#   为什么不容忍 float:`type_id` 全仓当 int 用 —— 它是 `tier_of(type_id: int)` /
#   `is_type_enabled(type_id: int)` / `WeaponInventory.SLOT_COST` 一类**字典的键**、
#   以及 `enabled_types.has(type_id)` 的入参;混进 float 会在这些地方**静默不命中**。
#   ★ 更直接的一条(已实测):`Array[int] [1,2,3] == Array [1,2,3]` 为**真**,
#   但 `== [1, 2, 3.0]` 为**假** —— 于是任何拿 id 数组去比**字面量 int 数组**的断言
#   (enemy_logic_smoke 的 ⑦、以及将来任何探针)会变成**假红**,而且看起来像"接线漏了"。
#   那正是本文件 ② 那条"float 当键会让 has() 永远假"的镜像。
static func all_ids() -> Array[int]:
	_ensure_loaded()
	var out: Array[int] = []
	for e in _entries:
		out.append(int(e["id"]))
	return out


static func has(type_id: int) -> bool:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return true
	return false


static func scene_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["scene"])
	return ""


static func name_of(type_id: int) -> String:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return str(e["name"])
	return ""


# ★ 返回**裸 int**(与 `WeaponInventory.TIER_*` 同值)。别改成返回 `WeaponBase.Tier`。
static func tier_of(type_id: int) -> int:
	_ensure_loaded()
	for e in _entries:
		if int(e["id"]) == type_id:
			return int(TIER_NAMES[str(e["tier"])])
	return WeaponInventory.TIER_LIGHT


# {type_id: tier} —— 供 `WeaponInventory.new(...)` **注入**(它刻意不 import 任何武器类)。
static func tiers_map() -> Dictionary:
	_ensure_loaded()
	var out := {}
	for e in _entries:
		out[int(e["id"])] = int(TIER_NAMES[str(e["tier"])])
	return out


# 只给测试:重读 json(改了 json 后不必重启进程)。
static func reload() -> void:
	_loaded = false
	_entries = []
	_ensure_loaded()
```

- [ ] **Step 3: 导出过滤器改成目录 glob（两个预设都要改）**

`export_presets.cfg` 的 **:12** 与 **:86** 两行现在是同一串，都改成：

```
include_filter="maps/*.cyrm,data/*.json"
```
★ 两个预设（`[preset.0]` "Windows Desktop" 与 `[preset.1]` "Dedicated Server"）
**必须一起改**：漏改服务端那个 = 服务端 exe 里没有武器表 = 联机落地时服务器铺不出枪
（而客户端有），是一条只在发布产物上现形的分叉。
★ 为什么是 glob 而不是再点一个文件名：约束是"**加第 7 把枪不许再动这个文件**"。
（已核实：`.json` 本来就是 Resource 类型、已被 `all_resources` 收录，所以这条改的是**保险**
而不是机制 —— 论证见 Global Constraints 那条。）

- [ ] **Step 4: 刷新全局类缓存**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --import 2>&1 | tail -5
```
Expected: 无 `Parse Error` / `SCRIPT ERROR`。
★ 这一步**不可省**：新建的 `class_name` 文件不进全局类缓存的话，Task 3 里那些
`WeaponRegistry.xxx()` 引用会当场 `Could not resolve class`（见 CLAUDE.md 的「测试」一节）。

- [ ] **Step 5: 跑 Task 1 的冒烟，确认 ① ② ③ ④ 转绿、⑤ ⑥ 仍红**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd \
  2>&1 | grep -E "  FAIL - |FAILURES"
```
Expected: FAIL 列表**恰好 7 条** = ⑤ 一条（命中的 6 个字面量）+ ⑥ 六条（还没改的宿主函数），
末尾是 **`FAILURES: [… 7 条 …]`（stderr）+ 退出码 1** ——
**不是 `SMOKE OK`**（有失败时 `enemy_logic_smoke.gd:130-135` 走 `else` 支，见 Task 1 Step 2）。
★ 删掉命令里的 `2>&1` 会把这一行整条吞掉，剩下的输出看着像"什么都没发生"。
`读得到 res://data/weapons.json` / `core/sim/weapon_registry.gd 存在且可加载` /
`json 至少有 1 条合格条目` / 所有 `tier_of(...)` / `tiers_map()` / `scene_of(...)` /
`name_of(...)` / `has(...)` / `默认启用表必须等于注册表全部 id` —— 这些**必须已不在 FAIL 列表里**。
★ 若 `默认启用表必须等于注册表全部 id` 红了：`enabled_types` 还是那条硬编码
`[1, 2, 3, 4, 5, 6]`，而注册表也是 `[1..6]` ⇒ 本该相等。红了说明 json 的 id 集合不是
`{1..6}`（多半手抖写了 0 或 7），回去核 Step 1 的内容。
★ ⑦ 那条能绿的**前提**是 `all_ids()` 返回的是**真 int**（不是 JSON 来的 float）——
`Array[int] [1,2,3] == Array [1,2,3]` 为真、`== [1,2,3.0]` 为**假**。
真红了先看 `all_ids()` 有没有漏掉 `int(...)`，别急着怀疑接线（见 Task 2 Step 2 的注释）。

- [ ] **Step 6: 反证（把 json 改坏，确认 ② 会红并点名）**

临时把 `data/weapons.json` 里 id 1 的 `"tier": "light"` 改成 `"tier": "medium"`，跑：
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd \
  2>&1 | grep -E "id 1|FAIL" | head -8
```
Expected: `FAIL - id 1:tscn 的 tier(0)必须等于 json 的 "medium"(1)`。
★ 这一条证明 ② **真的在读盘上的 json**，而不是在读某个缓存/常量。
确认后**改回来**，再跑一次 Step 5 的命令确认恢复。

★ 本 Step **不提交**（工作区此刻仍有 ⑤⑥ 红，与 Task 3 合并提交）。

---

### Task 3: 生产迁移 —— 6 处字面量 + 4 个调用方 + 删掉三张表

**Files:**
- Modify: `scenes/player/weapon_component.gd`（删 3 张表；`_init` / `set_enabled_types` / `_equip_index`）
- Modify: `scenes/level_0.gd`（`_default_weapon_types`，:502-508）
- Modify: `server/match_ground.gd`（`_server_weapon_types`，:31-37）
- Modify: `scenes/lobby_page.gd`（`_add_weapon_grid`，:107）
- Modify: `scenes/main_menu.gd`（`_fill_sp_panel`，:343 / :345 / :360）
- Modify: `scenes/player/player_replica.gd`（`_swap_weapon`，:238）
- Modify: `scenes/weapons/weapon_pickup.gd`（`_build_visual`，:101）
- Modify: `ui/weapon_icons.gd`（:22 / :68）
- Modify: `ui/hud.gd`（:265）
- Modify: `tests/weapon_pickup_probe.gd`（:102 / :322 —— **不改就是 Parse Error**）

**Interfaces:**
- Consumes: Task 2 的 `WeaponRegistry` 七个函数。
- Produces: ⑤⑥ 转绿；项目里不再有 `WeaponComponent.WEAPONS` / `DISPLAY_NAMES` / `TIERS`。

- [ ] **Step 1: `weapon_component.gd` 删表 + 三处改问 registry**

★ 本 Step 的**行号取自 `main`（计划 1 之前）**，且计划 1 会给这个文件插入新函数 ⇒
按下面给出的**内容**定位（三块 `const` 的名字 + 三个函数的原文），别硬按行号跳。

删掉 `:15-22`（`WEAPONS`）、`:25`（`DISPLAY_NAMES`）、`:33-40`（`TIERS`）三块的
`const` 声明**连同它们上方的说明注释**（注释讲的是三张表互相对账，判据已搬到 json 上）。

`:54` 那个 `enabled_slots`（计划 1 后叫 `enabled_types`）声明，改成**空表 + 注释**
（**这一处与下面 `_init` 那一行是同一条改动**，形状由 Task 1 的 ⑤+⑥ 共同钉死）：

```gdscript
# 启用的武器**类型 id**。默认全开 = 注册表里全部 id(**在 `_init` 里赋值** —— 不在这里);
# 单机由 Level0 按 RunOptions 设置;PvP 由客户端按服务器下发的 match_options 设置。
# 数字键/滚轮切枪都会跳过被禁的类型。
# ★ 从前这里是硬编码的 `[1, 2, 3, 4, 5, 6]`:加第 7 把枪时漏改它,新枪**永远拿不到也开不了**,
#   且**完全不报错**。赋值搬进 `_init` 不是风格偏好 —— `ScanUtil.func_body` 断言不了
#   class 级的 `var`,只有把它放进函数体, ⑥ 那条守卫才存在。
var enabled_types: Array = []
```

`:61-63` 的 `_init` 改成：

```gdscript
func _init() -> void:
	# 在 _init 而不是 _ready 建:探针会 new() 出组件直接调方法,不一定入树。
	inventory = WeaponInventory.new(WeaponRegistry.tiers_map())
	# ★★ **默认启用表必须在构造期就填好,且必须走 `all_ids()`** —— 两件事都只在这一行成立:
	#   ① ⑦(`comp.enabled_types == registry.all_ids()`)读的是**刚 new() 出来**的组件;
	#   ② Task 1 的 ⑥ 锚在**函数体**上:`ScanUtil.func_body` 表达不了 class 级的 `var`,
	#      所以 `:54` 那条 `var enabled_types: Array = [1, 2, 3, 4, 5, 6]` 必须**先变成空表**,
	#      再由这一行填 —— 只把 `:54` 改成 `all_ids()` 会让 ⑤ 绿、⑥ 红。
	enabled_types = WeaponRegistry.all_ids()
```

`:70-80` 的 `set_enabled_slots`（计划 1 已改名为 `set_enabled_types`）改成：

```gdscript
func set_enabled_types(disabled: Array[int]) -> void:
	enabled_types = WeaponRegistry.all_ids().filter(func(t: int) -> bool: return not disabled.has(t))
	if enabled_types.is_empty():
		# 不允许全禁:至少留**注册表里的第一把**(今天 = 1 号手枪)。
		# ★ 这里从前写死 `[1]`。注册表化之后"手枪"这个概念只活在 json 的顺序里,
		#   写死一个 id 会在将来重排 json / 删号时**静默**指到别的枪。
		var ids := WeaponRegistry.all_ids()
		enabled_types = [ids[0]] if not ids.is_empty() else []
	# 当前拿着的枪被禁 → 切到背包里第一把没被禁的;没有就空手
	if _current_type > 0 and not is_type_enabled(_current_type):
		var fallback := _first_enabled_index()
		if fallback >= 0:
			_equip_index(fallback)
		else:
			_unequip()
```

`_equip_index` 体内那三行换表查询（**`main` 上是 `:210-214`；计划 1 往这个文件里插了函数，
现已漂到 `:248-252`**）改成：

```gdscript
	var type_id := int(inventory.held[index]["type"])
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene == null:
		push_error("weapon scene not found: id=%d(%s)" % [type_id, scene_path])
		return
```
★ 定位方式：找 `load(WEAPONS.get(str(type_id), ""))` 那一行（全文件只有一处）。
★ 同文件里的 `:54`（`enabled_types` 的 class 级声明）**这一步先不动**，它在下一步一起改 ——
两处的形状是**一条**改动，别只改一半（只改一处的结果：⑤ 红或 ⑥ 红，见上面 `_init` 的注释）。

★ 本 Step **只替代"换表查询"这三处**。函数名与调用名一律是**计划 1 改完的**：
`is_type_enabled`（原 `is_slot_enabled`）、`_current_type`（原 `_current_slot`）、
`equip_type(...)`（原 `equip(String)`，签名从 `String` 变 `int`）、`used_cell_count()`
（原 `used_slots()`）、`CELL_COST`（原 `SLOT_COST`）、`cell_start()`（原 `slot_start`）。
**上游名写回去 = Parse Error**；`_first_enabled_index` / `_unequip` / `pick_up` / `add` 没改名，
**别顺手改别的语义**。

- [ ] **Step 2: 四处 `[1, 2, 3, 4, 5, 6]` 改成 `WeaponRegistry.all_ids()`**

★ 下面四段里的循环变量一律是 **`type_id`** —— 计划 1 的 Task 1 Step 4 **已经**把
`level_0` / `match_ground` / `lobby_page` / `main_menu` 四处循环里的 `slot`/`slot_i`
改成了 `type_id`/`type_i`。本 Step 改的是**列表来源**，不是再改一次名字。

`scenes/level_0.gd:502-508`：

```gdscript
# 单机初始武器清单:每种 2 把,跳过本局被禁的类型。
# (禁用武器不该出现在地图上 —— 与 set_enabled_types 同源:RunOptions.disabled_weapons)
# ★ 清单来自注册表(json 顺序 = 散落顺序)。加第 7 把枪只改 json,这里一个字不动。
func _default_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not RunOptions.disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out
```

`server/match_ground.gd:31-37`：

```gdscript
# 本局投放的武器类型清单:每种 2 把,跳过被禁的类型。
# ★ 与单机 `Level0._default_weapon_types` **同源**(都取注册表),差别只在禁用表是哪个。
func _server_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not _disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out
```

`scenes/lobby_page.gd:107`（只改循环的**来源**；函数体里那 6 处 `type_i` 是计划 1 改的名，
**不动**）：

```gdscript
	for type_id: int in WeaponRegistry.all_ids():
```
★ 该行上方的注释（**现状**：`# 显式 int:循环变量来自字面量数组,`var type_i := type_id`
推断不出类型会整文件解析失败`）
**必须一并改写**：`all_ids()` 返回 `Array[int]`，不再是"字面量数组"这个理由了。
改成：`# 显式 int:入库的是 Array[int],循环变量跟着同类型,别让它退化成 Variant。`
（核验报告 §2.8 点名了这条注释：理由不成立而注释留着就是误导。）
★ 这里改完，`_add_weapon_grid` 的函数体就让 Task 1 的 ⑥ 满足了。

`scenes/main_menu.gd:343` 起的那一段（`for` 用计划 1 的 `type_id`；`cb.text` **不带编号**
—— 编号是计划 1 Step 5 刚删掉的，别装回来）。
★ **行号已漂**：计划 1 Step 5 在原文案那行**上方加了一行注释**，故现在是
**`:343` 循环 / `:346` `cb.text`（原文案的下方多了一行注释）/ `:361` `i + 1`**（原 `:360`）。
按给出的原文定位，别按旧行号跳：

```gdscript
	var ids: Array[int] = WeaponRegistry.all_ids()
	for type_id: int in ids:
		var cb := CheckButton.new()
		# ★ 保留计划 1 加的那行注释(它讲的是"编号看起来像键位",与本改动无关)。
		cb.text = WeaponRegistry.name_of(type_id)
		cb.icon = WeaponIcons.silhouette(type_id)   # 纯白像素剪影,便于辨认
		cb.expand_icon = false
		UiFactory.style_check(cb, 32)
		cb.button_pressed = Settings.sp_disabled_weapons.has(type_id)
		checks.append(cb)
		check_list.add_child(cb)
```
★★ **`:361` 的 `i + 1` 必须一起改成 `ids[i]`**（同一段 `go.pressed` 的闭包里）：

```gdscript
		for i in checks.size():
			if checks[i].button_pressed:
				# ★ 必须是 `ids[i]`:**不能**写成 `i + 1`。序号只在"json 恰好是 1..N 的
				#   稠密连续段"时才等于 type_id —— 一旦重排 json 或留下空洞,`i + 1` 会
				#   **静默禁用错的那把枪**(而今天 ids == [1..6],两种写法同结果,正是
				#   "改了不报错"的那一类)。
				Settings.sp_disabled_weapons.append(int(ids[i]))
		Settings.save()
```
★ `ids` 是闭包外层的局部变量，`go.pressed` 的 lambda **能**捕获它 —— 与今天那段
`for i in checks.size(): if checks[i].button_pressed:` 捕获 `checks` 是**同一机制、同一个
lambda**，不是新引入的写法。

- [ ] **Step 3: 四个"按 id 查场景/名字"的调用方改问 registry**

★ 下面两处的形参名是 **`type_id`** —— 计划 1 的 Task 1 Step 4 已经把
`player_replica._swap_weapon(slot)` 与 `weapon_icons.silhouette(slot)` 的形参改成了 `type_id`。
**照抄写成 `slot` 就是 Parse Error**（那是本批核验报告点名的两处硬错）。

`scenes/player/player_replica.gd`（`_swap_weapon` 体内，原 `:238`）：

```gdscript
	var scene_path: String = WeaponRegistry.scene_of(type_id)
	if scene_path.is_empty():
		return
```

`scenes/weapons/weapon_pickup.gd:100-104`（`_build_visual` 开头；这里 `type_id` 是**成员变量**，
计划 1 没动它）：

```gdscript
func _build_visual() -> void:
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene == null:
		push_warning("WeaponPickup: 槽 %d 没有武器场景,地面掉落物将是空壳" % type_id)
		return
```

`ui/weapon_icons.gd:22`（`silhouette` 开头）：

```gdscript
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
```

`ui/weapon_icons.gd:69`（`make_weapon_check` 体内，形参同样是计划 1 改过的 `type_id`；
★ 行号已漂：计划 1 Step 5 在上方加了一行注释，`main` 上的 `:68` 现在是 `:69`）：

```gdscript
	var l := UiFactory.label(WeaponRegistry.name_of(type_id), font_size)
```
★ **不带编号** —— 计划 1 的 Step 5 刚把 `"%d %s"` 那个假键位编号删掉，
本 Step 只换**名字的来源**，别把它装回来。`font_size` 的实参位置也不动
（`kh_l4_probe` 按下标 1 取它）。

`ui/hud.gd:265`（`t` 是 `:209` 的 `var t := int(e["type"])`，计划 1 **没动**它）：

```gdscript
			var nm := WeaponRegistry.name_of(t)
			_weapon_name.text = nm if not nm.is_empty() else "空手"
```
★ 兜底留着的理由：`t` 来自**背包条目**（`ui/hud.gd:209`），不是来自注册表 —— 老存档/异常
背包里可能有注册表已删掉的 id，那种时候显示"空手"而不是空串。

- [ ] **Step 4: `tests/weapon_pickup_probe.gd` 跟着改（**不改就是 Parse Error**）**

`:102` 与 `:322` 两处直接引用 `WeaponComponent.WEAPONS`，表删了就编不过
（两处行号**已核**：计划 1 只是同行改名，没增删这两行）：

```gdscript
	for t in WeaponRegistry.all_ids():
		var type_id := int(t)
```
（`:102` 那处，原来是 `for t in WeaponComponent.WEAPONS.keys():`。）

```gdscript
	var want: PackedScene = load(WeaponRegistry.scene_of(int(pk.type_id)))
```
（`:322` 那处，原来是 `load(WeaponComponent.WEAPONS[str(pk.type_id)])`。）

- [ ] **Step 5: 跑 —— 应该全绿**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "FAIL|SMOKE"
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_pickup_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn 2>&1 | grep -E "KH L3|FAIL"
```
Expected: `SMOKE OK`（且无 FAIL）、`WEAPON PICKUP PROBE: ALL-OK`、`KH L3 PROBE: ALL-OK`。
★ `enemy_logic_smoke` 的成功判据是文本 **`SMOKE OK`**；本相新增/改写的断言会让
`ok - ` 行数变多，**这是预期的**（该文件的注释把"27 节的顺序"称作回归基线 ——
**顺序没动，只是 `_phase_weapon_registry` 一节内部换了判据**）。

- [ ] **Step 6: 反证（逐个证明 ⑤⑥ 会红）**

1. 把 `scenes/level_0.gd` 的 `for type_id in WeaponRegistry.all_ids():` 临时改回
   **计划 1 之后的那句字面量**：`for type_id in [1, 2, 3, 4, 5, 6]:`，跑 Step 5 的第一条命令。
   Expected: `FAIL - 生产代码里不得再有硬编码的武器 id 列表(命中:[res://scenes/level_0.gd])`
   **且** `FAIL - res://scenes/level_0.gd 的 _default_weapon_types() 应改用 …
   WeaponRegistry.all_ids()` —— ⑤⑥ 两条**一起**红，且**点名**到那个文件。
2. 把 `weapon_component.gd` 的 `_init` 里 `enabled_types = WeaponRegistry.all_ids()`
   临时改成 `enabled_types = [1, 2, 3, 4, 5, 6]`，跑同一条命令。
   Expected: `FAIL - res://scenes/player/weapon_component.gd 的 _init() 应改用 …`
   （注意：⑦ 的"默认启用表"**不会**红 —— json 仍是 `[1..6]`，两者碰巧相等。
   ⑦ 的牙齿由 Task 5 的第 7 把枪实验证明，见那里）。
3. 两处都**改回来**，再跑一次确认全绿。

- [ ] **Step 7: 提交（Task 1 + 2 + 3 合并为一次）**

```bash
git add data/weapons.json core/sim/weapon_registry.gd export_presets.cfg \
        scenes/player/weapon_component.gd scenes/level_0.gd server/match_ground.gd \
        scenes/lobby_page.gd scenes/main_menu.gd scenes/player/player_replica.gd \
        scenes/weapons/weapon_pickup.gd ui/weapon_icons.gd ui/hud.gd \
        tests/enemy_logic_smoke.gd tests/weapon_pickup_probe.gd
git commit -F - <<'EOF'
refactor(weapon): 武器注册表收敛到 data/weapons.json —— 删三张常量表 + 6 处硬编码 id 列表
EOF
```
（`core/sim/weapon_registry.gd.uid` 由 Godot 自行生成，若 `git status` 显示就一并加上。）

---

### Task 4: 探针适配 —— 散落数量按注册表算、覆盖性断言、`kh_l3` 的"全禁"字面量

**Files:**
- Modify: `tests/level0_weapon_scatter_probe.gd`（:45-49 与 :67-71）
- Modify: `tests/kh_l3_probe.gd`（:187）

**Interfaces:**
- Consumes: `WeaponRegistry.all_ids()`（场景探针里可直接用全局类名）。
- Produces: 散落探针不再硬断言 `== 12`，且**新增**"每种注册武器都铺到了"的覆盖性断言。

- [ ] **Step 1: 散落数量改成按注册表算**

`tests/level0_weapon_scatter_probe.gd:45-49`：

```gdscript
	var all_pickups := get_tree().get_nodes_in_group("weapon_pickup")
	# ★ 数量 = 注册表条数 × 2(每种 2 把),**不再写死 12** —— 写死的话加第 7 把枪
	#   (每种 2 把 ⇒ 14 件)会把这条探针打红,而那正是本特性要支持的场景。
	var want_types: Array[int] = WeaponRegistry.all_ids()
	var expect_total := want_types.size() * 2
	_check(all_pickups.size() == expect_total,
			"开局应铺 %d 件地面武器(%d 种 × 2,实际 %d)" % [
				expect_total, want_types.size(), all_pickups.size()])
```

`:67-71` 那一段（`# 每种 2 把` 的循环）之后**追加**覆盖性断言：

```gdscript
	# ★ 覆盖性:注册表里的每一种都必须**真的铺到了**。
	#   这条是"加了第 7 把枪但散落表漏了它"的守卫 —— 上面那条按注册表算的**总数**
	#   拦不住那种情况(总数 14 对得上,但其中一种 0 件、另一种 2 件)。
	var missing: Array = []
	for t in want_types:
		if not types.has(int(t)):
			missing.append(int(t))
	_check(missing.is_empty(),
			"每种注册武器都应铺到(缺 %s;场上实际 %s)" % [str(missing), str(types)])
```

- [ ] **Step 2: `kh_l3` 的"全禁"字面量改成 `all_ids()`**

`tests/kh_l3_probe.gd:187` 那一段的本意是**把全部武器类型都禁掉**再验兜底
（按**内容**定位：那句 `wep.set_enabled_types([1, 2, 3, 4, 5, 6])`；
计划 1 对 `kh_l3_probe.gd` **不增删行**，故 `:187` 应当仍然对得上 —— 对不上就按内容找）：

```gdscript
	# 全禁 → 兜底非空(KH 的兜底是 [1]),否则出生即空手
	# ★ 入参是"被禁用的**类型 id** 列表" —— 必须取注册表,不能写死 [1, 2, 3, 4, 5, 6]:
	#   漏掉第 7 把枪时,"全禁"其实没禁上它 ⇒ 下面的 `is_type_enabled(<第一把>)` 会红
	#   (而那条红的成因看起来像"兜底坏了",查半天)。
	wep.set_enabled_types(WeaponRegistry.all_ids())
```
★ 下面三条断言（`enabled_types` 非空 / 第一把启用 / `size() == 1`）**一个字不动** ——
它们验的是同一个行为，只是入参现在真的"全"了。

- [ ] **Step 3: 跑 —— 先证明 Step 1 的覆盖性断言不是恒真**

把 `scenes/level_0.gd` 的 `_default_weapon_types` 临时加一行"跳过 5 号"：

```gdscript
	for type_id in WeaponRegistry.all_ids():
		if type_id == 5:      # ← 临时,反证用
			continue
		if not RunOptions.disabled_weapons.has(type_id):
```
Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 \
  res://tests/level0_weapon_scatter_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL|每种注册"
```
Expected: `FAIL - 每种注册武器都应铺到(缺 [5];场上实际 {1: 2, 2: 2, 3: 2, 4: 2, 6: 2})` **且**
`FAIL - 开局应铺 12 件地面武器(6 种 × 2,实际 10)` —— 两条一起红。
★ 第二条的文案必须与 Task 4 Step 1 里写的那个格式串**逐字对上**
（`"开局应铺 %d 件地面武器(%d 种 × 2,实际 %d)"`）；对不上说明 Step 1 被改动过，先核它。
★ 这一条正是"加了新枪但散落表漏了它"的可复现形态。确认后**删掉那两行**，再跑一次确认全绿。

- [ ] **Step 4: 跑 `kh_l3`**

Run:
```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn \
  2>&1 | grep -E "KH L3|FAIL|全禁"
```
Expected: `KH L3 PROBE: ALL-OK`，且 `全禁后兜底` 那三条仍是 `ok`。
★★ **本步不产生红绿分界**（6 把枪时 `[1, 2, 3, 4, 5, 6]` 与 `all_ids()` 同结果）——
它是一条**前瞻性**改动，牙齿在"第 7 把枪"那一档才露出来，所以 **Task 5 Step 1 的跑批里
必须带上 `kh_l3_probe`**：那时若 `:187` 还写着 `[1, 2, 3, 4, 5, 6]`，兜底会变成 `[7]`、
`is_type_enabled(1)` 变假 ⇒ `全禁后兜底不是 [1]` 红。没有那一档，本步就是一条**验不出差别**的
改动（本仓最该避免的形状）。

- [ ] **Step 5: 提交**

```bash
git add tests/level0_weapon_scatter_probe.gd tests/kh_l3_probe.gd
git commit -F - <<'EOF'
test(weapon): 散落数量改按注册表算 + 覆盖性断言;kh_l3 的"全禁"改用 all_ids()
EOF
```

---

### Task 5: 验收「加第 7 把枪 = 零 GDScript」+ 回归 + 登记

**Files:**
- Modify: `CLAUDE.md`（§敌人 的 `data/enemies.json` 那条旁、§砖块属性与破坏 之后）

**Interfaces:**
- Consumes: 无。
- Produces: 无（验收 + 文档）。

- [ ] **Step 1: 端到端走一遍"加第 7 把枪"（**临时，不提交**）**

往 `data/weapons.json` 的数组**末尾**临时加一条（复用现成的 1 号 tscn —— 本步验的是
"**零 GDScript 改动**"，不是"会不会做新枪的贴图"；tier 必须与被复用的那个 tscn 一致）：

```json
    { "id": 7, "name": "手枪(7 号验证)", "tier": "light", "scene": "res://scenes/weapons/pistol_test.tscn" }
```
（注意上面那条末尾要有逗号。）

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . --import 2>&1 | tail -2
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "FAIL|SMOKE"
"$GODOT" --headless --path . --quit-after 3600 res://tests/level0_weapon_scatter_probe.tscn \
  2>&1 | grep -E "ALL-OK|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_pickup_probe.tscn \
  2>&1 | grep -E "ALL-OK|FAIL"
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn \
  2>&1 | grep -E "KH L3|FAIL|全禁"
# ★ 下面这条只看数字是**不够**的:场景没跑起来时一行都不打印,而 `grep -c` 照样打 0。
#   故把行数一起打出来 —— 行数为 0 = 场景压根没跑,那不是"没有报错"。
out=$("$GODOT" --headless --path . --quit-after 120 res://scenes/main_menu.tscn 2>&1)
echo "错误行数=$(echo "$out" | grep -cE 'SCRIPT ERROR|Parse Error')  总行数=$(echo "$out" | wc -l)"
```
Expected: **全绿** —— `SMOKE OK`（无 FAIL，含 ⑦ 的"默认启用表 == 注册表全部 id"，
它现在比的是 `[1..7]`）、`LEVEL0 SCATTER: ALL-OK`（14 件）、`WEAPON PICKUP PROBE: ALL-OK`、
`KH L3 PROBE: ALL-OK`（★ 这一条是本批**唯一**能验 Task 4 Step 2 那条改动的地方，
见那里的说明）、最后一行形如 `错误行数=0  总行数=<几十以上>`。
★ **这就是 spec §7.1 要的"实际走一遍"**：注意本次**一个 `.gd` 文件都没改**。
★ 若 ⑦ 红了（`默认启用表…实际 [1,2,3,4,5,6]、注册表 [1..7]`）⇒ `enabled_types` 的赋值
没有真的走 `all_ids()`，回去看 Task 3 Step 1。
★ 若 `kh_l3_probe` 的 `全禁后兜底不是 [1](实际启用表 [7])` 红了 ⇒ Task 4 Step 2 漏了
（`:187` 还写着 `[1, 2, 3, 4, 5, 6]`）。

- [ ] **Step 2: 反证 —— 证明 ⑦ 有牙齿**

保持上一步的第 7 条 json 在场，把 `weapon_component.gd` 的 `_init` 里
`enabled_types = WeaponRegistry.all_ids()` 临时改成 `enabled_types = [1, 2, 3, 4, 5, 6]`，跑：
```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd \
  2>&1 | grep -E "默认启用表|FAILURES"
```
Expected: `FAIL - 默认启用表必须等于注册表全部 id(实际 [1, 2, 3, 4, 5, 6]、注册表 [1, 2, 3, 4, 5, 6, 7])`
**加上**尾行 `FAILURES: […]`（这一趟红了 ⇒ 走 `printerr` + `quit(1)`，**不会是 `SMOKE OK`**；
`smoke.gd:130-135`）。★ `2>&1` 不能省 —— `FAILURES` 在 stderr 上。
★ 这**就是**"加了第 7 把枪但漏改 `enabled_types` ⇒ 新枪永远拿不到也开不了、且不报错"
那条 bug 的可复现形态。确认后改回来。

- [ ] **Step 3: 还原（第 7 条必须删掉）**

把 Step 1 加的那一行 json **连同上一行末尾的逗号**一起还原成 Step 1 之前的样子，跑：
```bash
source tests/env.sh
"$GODOT" --headless --path . --import 2>&1 | tail -2
git diff --stat data/weapons.json
```
Expected: `git diff --stat` **没有任何输出**（json 与已提交版本逐字相同）。
★ 这一步不可省：留着第 7 条就等于在发布版里多加了一把枪，而本计划的目的不是加枪。

- [ ] **Step 4: 全量回归**

Run:
```bash
source tests/env.sh
# ★ 场景探针(有 .tscn,判据是文本 ALL-OK);`enemy_logic_smoke` **没有** .tscn,不在这一组。
for t in weapon_pickup_probe ground_client_probe ground_action_probe net_ground_probe \
         kh_l3_probe pvp_twin_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
done
for t in kh_l4_probe kh_l5_probe kh_l6_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
done
# ★ `-s` 冒烟(extends SceneTree)
for t in weapon_inventory_smoke ground_weapon_field_smoke laser_weapon_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL|SCRIPT ERROR" | tail -3
done
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "SMOKE"
"$GODOT" --headless --path . -s res://tests/pvp_twin_smoke.gd 2>&1 | grep -E "OK|FAIL"
```
Expected: 逐行 `ALL-OK` / `SMOKE OK` / `*_OK`。
★ 引用写法提醒：**判据文本里带空格**的那些（`SMOKE OK` / `WEAPON_INVENTORY OK`）与
`ALL-OK` 不是同一串；`grep "ALL-OK"` 抓不到 `SMOKE OK`。
★ `kh_l4`/`kh_l5` 里扫的是 `res://ui` 与 `res://tests` 的**字号规范** —— 本计划没引入字号，
它们应当原样绿；红了说明改动越界（多半是 `ui/hud.gd` 那处 `style_control` 的字号参数被碰到）。
★ `kh_l3_probe` 与 `kh_l5_probe` 里有**源码级**断言（`kh_l3_probe.gd:406` 断 `level_0.gd`
含 `set_enabled_types(RunOptions.disabled_weapons)`）—— 本计划没动那一行，应当原样绿。

- [ ] **Step 5: 登记进 CLAUDE.md**

在 **§砖块属性与破坏（`data/tile_defs.json`）** 那一节之后，紧挨着补一条新条目
（与 `data/enemies.json` / `data/tile_defs.json` 的"单一来源 + 同步脚本"体例并列）：

```markdown
### 武器注册表(data/weapons.json)
- **单一来源**:`data/weapons.json` 的 `weapons` 数组,每条 `{id, name, tier, scene}`。
  **`id` 就是整数 `type_id`**(不是另一个 id 空间);`tier` 是**值**不是标识
  (`"light"`/`"medium"`/`"heavy"` 三值,与 tile_defs.json 的 `"wall"`/`"liquid"` 同风格),
  由 `WeaponRegistry` 映射回整数。**数组顺序 = 菜单顺序 = 散落顺序**。
- **`core/sim/weapon_registry.gd`(`class_name WeaponRegistry`,纯静态、无 autoload、`-s` 可测)**
  是唯一读者:`all_ids()` / `has()` / `scene_of()` / `name_of()` / `tier_of()` / `tiers_map()`。
  ★★ **`tier_of()` 返回裸 `int`,绝不返回 `WeaponBase.Tier`** —— `weapon_base.gd:7` 的
  `bullet_scene` @export 默认值 preload 了 `bullet.tscn`,引那个类会把 autoload 拖进 `-s`
  (`weapon_inventory.gd` 的文件头记的正是这条,它宁可让调用方**注入** tiers 表也不 import)。
  本文件也**绝不 `load()` 武器场景**(只 `ResourceLoader.exists()` 查路径);
  "能不能 load / tier 对不对"由 `enemy_logic_smoke._phase_weapon_registry` 逐条验。
- **★ 已删除**:`WeaponComponent` 的 `WEAPONS` / `DISPLAY_NAMES` / `TIERS` 三张常量表。
  它们与 6 处硬编码的 `[1, 2, 3, 4, 5, 6]` 一起换成 `WeaponRegistry.all_ids()`
  (落点:`level_0._default_weapon_types` / `match_ground._server_weapon_types` /
  `lobby_page._add_weapon_grid` / `main_menu._fill_sp_panel` / `weapon_component` 的
  `_init` 与 `set_enabled_types`)。
- **加第 7 把枪 = 改 1 个 json + 加 1 个 tscn,零 GDScript 改动**。守卫:
  `enemy_logic_smoke._phase_weapon_registry` 的 ⑤(生产代码里不得再有硬编码武器 id 列表,
  按**目录扫描**判)/ ⑥(六处宿主的函数体确实调了 `all_ids()`)/ ⑦(默认启用表 == 注册表全部 id);
  `level0_weapon_scatter_probe` 的覆盖性断言(每种注册武器都铺到了)。
  ★ ⑦ 是"漏改 `enabled_types` ⇒ 新枪永远拿不到也开不了、且不报错"那条的唯一守卫,
  它的牙齿要用"临时加一条 json"来验(见计划的 Task 5)。
- **加载校验是"新约定"**:文件级格式错 → `push_error` + 整表留空(与 `EnemySpawner` 同款);
  **逐条**不合格(缺字段/非对象/`id` 非正整数/`id` 重复/`tier` 非三值/`scene` 不存在)→
  `push_error` + **跳过该条**。★ 这**不是** `EnemySpawner` 的约定 ——
  它对逐条的坏数据只是 `continue`,一个字都不打;别拿这条去改它。
- **协议零改动**:`id` 仍是整数 `type_id`,快照/输入包里的量纲一个字没变。
```

并订正 spec 的两处口径（写在同一条里，别另开一节）：
① §4.2 的"五处硬编码"实为 **6 个字面量 / 5 个文件**（`weapon_component.gd` 里 `set_enabled_types`
与 `_init` 各一处）；② §5 的"与 `EnemySpawner` 同款"**不成立**（逐条那一半是新约定，见上）。

- [ ] **Step 6: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 登记武器注册表单一来源(weapons.json / WeaponRegistry)
EOF
```

---

## Self-Review

**1. 覆盖面**（对照 spec §4.2 + §5）：registry 六个查询 + json 形状 ✅ Task 2；
"删三张表、调用方改问 registry" ✅ Task 3；"五处 `[1..6]`" ✅ Task 3（**按核实后的事实写成
6 个字面量 / 5 个文件**，含 spec 漏掉的 `weapon_component.gd:71` 那处）；
"守卫改判据 json ↔ tscn ↔ 枚举 + 新增覆盖性" ✅ Task 1（③/⑦）+ Task 4（散落覆盖性）；
"加第 7 把枪 = 零 GDScript" ✅ Task 5 Step 1（**实际走一遍**，不是读代码）。

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。`data/weapons.json` 与
`weapon_registry.gd` 都给的是**完整内容**；每处调用点都给了完整代码块与确切行号。

**2b. 词汇（本批核验报告的 ❌ 项，已修）**：本计划全篇用的是**计划 2 改名之后**的名字 ——
形参/循环变量 `type_id`（不是 `slot`）、`equip_type`、`is_type_enabled`、`_current_type`、
`cell_start()`、`used_cell_count()`、`CELL_COST`。
★ 上一版把两处写成 `WeaponRegistry.scene_of(slot)`（`player_replica._swap_weapon` 与
`weapon_icons.silhouette` 的形参已被计划 2 改名为 `type_id`）⇒ **Parse Error**；
`main_menu` / `weapon_icons` 的菜单文案还把计划 2 刚删掉的 `%d. ` 编号装了回去 ⇒
静默改回了"假键位编号"。两处都已按计划 2 改名表重写。
★ **spec §3 那张表不完整**（不含 `used_slots` / `SLOT_COST` / 形参 `slot` 那几条）——
**以计划 2 的改名表为准**。

**3. 类型一致性**：`all_ids() -> Array[int]`（Task 2 定义；Task 3 的 `for type_id: int in …`、
Task 4 的 `var want_types: Array[int] = …` 都按 int 用）；`tier_of() -> int`（**不是** `Tier`）；
`tiers_map() -> Dictionary` 喂 `WeaponInventory.new(tiers: Dictionary)`
（`core/sim/weapon_inventory.gd:38`）；`name_of` 对未知 id 返回 `""`（`ui/hud.gd` 的兜底据此写）。

**4. 与另两份计划的关系** ✅ 见文件头的"关系"一节。本计划**不碰** §3 的改名
（那是计划 2）、**不碰** `WeaponInventory.CAPACITY`/`MAX_WEAPONS`（那是计划 4）。
唯一交叠是 `weapon_component.gd` —— 三个计划按 2 → 3 → 4 串行，Task 1 Step 0 是机械检查。

**5. 已知边界（登记，不修）**
- **重排 json 会改变菜单与散落顺序**（spec §6.5）。不是 bug，但没有守卫拦误排 —— 本次不做。
- **`WeaponRegistry` 的 `scene` 校验只是"路径存在"**，不是"能 load"；真正的 load 校验在
  `enemy_logic_smoke` 的 ② 里（那条**跑在源码树上**，不跑在发布产物上）。发布产物侧的兜底是
  `_ensure_loaded` 末尾那条"注册表为空"的 `push_error`。
- **`data/weapons.json` 进导出包靠的是 `all_resources`（`.json` 是 Resource 类型）**，
  Task 2 Step 3 的 glob 是保险带而非机制（论证见 Global Constraints）。
- `tests/preview_visibility_probe.gd:21` 与 `tests/team_match_watcher.gd:1188` 的**注释**里
  仍写着 `weapon_component.WEAPONS` —— 只是注释，本计划不改（顺手改也行，不构成断言）。
