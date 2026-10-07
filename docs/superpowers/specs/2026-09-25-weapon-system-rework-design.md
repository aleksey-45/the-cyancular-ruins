# 武器系统重做 — 设计（2026-09-25）

**一句话**：把"哪把枪"这件事从**三套互相错位的表示**收敛成两个词（`type_id` / `inst`），
把"有哪些枪"从**五处硬编码 + 三张 GDScript 表**收敛成一份 `data/weapons.json`，
并把容量与把数从编译期常量改成可配。**不改协议语义，只改上行数据包的含义**（下标 → `inst`）。

---

## ★ 2026-09-25 事实核验订正（**动笔 / 实施前必读**）

逐条核验见 `.superpowers/sdd/weapon-spec-verify.md`（42 条：23 ✅ / 14 ⚠️ / **5 ❌**）。
下面按**核实后的事实**执行，别照本 spec 正文写：

1. **★★ §4.3 要的机制已经做完了**（`eeda162` + `f33249b`）：`current_inst()`、
   `restore_inventory(entries, want_inst)`、`sync_soft_state` 比 `winst`、`_apply_weapon_state`
   的 `by_inst` 重建分流**全在位**，`ground_client_probe` ④b 还在两条路径上做了行为断言。
   ★ 本 spec 提议的判据 `winst != weapons.current_inst()` **是错的** —— 它跑在 `restore_inventory`
   之后，解析成功时**恒假**，照它写会**绕过**现有的重建落点。**别再动 §4.3 的机制**；
   真要动，先复现残余症状（用户 2026-09-23 报的 UI 高亮错已由 `f33249b` 修掉）。
2. **"加第 7 把枪 = 零 GDScript"还差几处**，本 spec 全篇未提：① `export_presets.cfg` 的
   `include_filter` 里**没有**任何 `data/*.json` 的兜底（它现在只列了 `maps/*.cyrm,data/enemies.json`）
   —— ★ **机制存疑，别照任何一方的结论写**：`data/` 下没有 `.import`、`.godot/imported/` 里没有
   json 产物、而 `TileDefs` 是 `FileAccess.open` **裸读**，按 Godot 的导出规则裸读文件**需要**列进
   `include_filter`（`data/enemies.json` 被列上大概正是这个原因）；但 `data/tile_defs.json`
   恰恰没被列，而它今天在用 ⇒ 也可能 `all_resources` 本就带上了它。
   **动作**：把新 json 显式列进过滤器（成本为零的保险），并在**导出产物**里确认它真的在
   —— 这条只能由发布产物回答，别在文档里断言。⚠ 顺带登记：`data/tile_defs.json` 不在过滤器里
   这一条**可能是既有的发布版缺陷**（`TileDefs` 有"未加载时非 0 即墙"的兜底 ⇒ 表现为梯子不可爬、
   水变实心、可破坏砖不可破坏，而**不会崩**）—— 值得单独查一次；
   ② `tests/level0_weapon_scatter_probe.gd:48` 硬断言 `== 12`；
   ③ §4.1 的协议改动会**反证** `tests/net_ground_probe.gd:144` 与 `tests/ground_client_probe.gd` ⑥
   （后者明确断言上行值**不得**是 type id）—— 这两条**必须改写**，而不是 §7.4 写的"保持全部通过"；
   ④ `tests/kh_l3_probe.gd:187` 是一张**武器** id 列表（核验报告误记成"无关 role 列表"），
   第 7 把枪会让 `:190` 红。
3. **§5 的"与 `EnemySpawner` 同款"不成立**：`enemy_spawner.gd:29-31` 对**逐条**的问题（缺字段 /
   非 Dictionary）是 `continue` **静默跳过、不 push_error**；`push_error` + 整表留空只发生在
   **文件级**。"逐条校验 + 跳过坏条 + push_error"是**新约定**，别声称同款。
4. **§6.1 的"5/6 号键那两个动作还在"是假的**：`project.godot` 的 input 段只有 `1`–`4`
   （`:97/:102/:107/:112`），且 `kh_l3_probe.gd:116-118` **否定断言** 5–0 不得有动作。
   把数调到 5+ 时第 5 把**只能靠滚轮**；要开 5/6 号键得先加动作 + 改 `LocalInputSource` 的
   `range(1, 5)`。
5. **§附 的 `refill_current_weapon` 行已过时**：该函数 2026-09-25 已删除（计划 1 落地），
   `kh_l4_probe` 那两条断言也一并删了。

**要紧的 ⚠️（同样按核实后的事实执行）**

- **§4.2 的 registry 必须返回裸 `int`，不能返回 `WeaponBase.Tier`** —— `weapon_base.gd:7` 有
  `preload("res://scenes/weapons/bullet.tscn")`，引它会把 autoload 拖进 `-s`，破坏本 spec 自己
  要求的"`-s` 可测"（`weapon_inventory.gd:6-9` 记的正是这条）。与 `WeaponInventory` 同款：**注入**。
- **§4.4 不是"只把 const 改成字段"**：静态读 `WeaponInventory.CAPACITY` 另有 **8 处**
  （`ui/weapon_slots.gd:81,87,90,102`、`tests/ground_action_probe.gd:195,196,208,209`），
  外加 `enemy_logic_smoke.gd:1158-1159` 读类常量 —— 改实例字段后这些是**静默 / 报错面**。
- **§4.1 那个键被大量探针手动编写**：上行键 **≥14 处**、下行快照 `"weapon"` **≥5 处**夹具；改键名要一并改。
- **§4.2 的"五处"实为 6 个字面量 / 5 个文件**（`weapon_component.gd:71` 是第二处）；
  本 spec 引的那条 grep 原样跑返回 **11 行**（另 5 行是无关的 role 列表）。
- **§3 的 rename 表漏了外部调用方**：`set_enabled_slots` 在 `level_0.gd:241` /
  `pvp_match_client.gd:130` / `match_host.gd:82`（+ 探针 ≥12 处）；`default_slot()` 在
  `level_0.gd:497`；`push/consume_net_slot` 在 `pvp_match_client.gd:202`。
- **§10.2 的结论未被证据支持**：引擎源码里输入泵在本帧 physics **之前**
  （`os_windows.cpp:2352`），探针日志与"跨帧间隙"相容、但推不出"同帧不会互相覆盖"。
  它属"已排除的伪发现"，不影响设计，**但别照它写断言**。
- `weapon_icons.gd:68` 是 `"%d %s"`（本 spec 引作 `"%d. %s"`）。

---

## 1. 背景

### 1.1 症状（用户报的，2026-09-25）

多人模式下**尤其**出问题，具体三类：

1. **切枪不对**（数字键/滚轮切不动、切完跳回、或切到另一把）
2. **同型号两把时错乱**（残弹串、UI 高亮错）
3. **子弹剩余量不对**

### 1.2 结构诊断

代码**写法**不差（注释密度、探针覆盖、边界登记都在平均线之上）；问题是**表示法**：
同一个概念存在多份表示，靠人工与探针互相对齐。最集中的一处是"哪把枪"：

| 用途 | 今天的表示 | 取值 |
|---|---|---|
| 武器类型 | 整数类型 id | 1–6 |
| 按键选枪 | 背包**位置** | 1–4 |
| HUD 容量 | 容量**格子** | 1–8 |
| 增删武器 | `inst`（逐把唯一） | 自增整数 |

四套数，其中三套被叫成 `slot`（`_current_slot` 是类型 id、`push_net_slot` 收位置、
`is_slot_enabled` 收类型、`enabled_slots` 是类型数组、`WeaponSlots` 是容量格）。

**后果不是"难读"，是"错了不报错"**：`推送→消费` 两侧量纲不同时，症状只是"切不动"，
而代码里没有任何一处会红。2026-09-17 修过的那次（滚轮上行发类型 id、消费端按位置读）
就是这条的产物。

### 1.3 实测与已排除（2026-09-25 当场验的）

- **弹数被回滚抹掉**：`--headless` 场景探针实测确认 —— `restore_state` 排下的
  `_restore_mag.call_deferred` 的值在**重放之前**捕获、帧末执行，于是抹掉重放期间打出的每一发。
  这是症状 3 的根因，**已单独立计划**（见 §8 计划 1）。
- **`_unhandled_input` 的派发在 `_physics_process` 之后**（实测 `P1…P8 U8 P9…`）。
- **GUI 不会吃掉滚轮**：读引擎源码 `scene/main/viewport.cpp::_gui_call_input()` 定案 ——
  `MOUSE_FILTER_STOP` 会 `set_input_as_handled()`，但有一条例外
  `!(is_scroll_event && force_pass_scroll_events)`，而 `control.h:286` 的
  `force_pass_scroll_events = true` 是默认值。**⇒ 我原先"武器面板吃掉滚轮"的推断被推翻。**

---

## 2. 目标与非目标

### 目标

1. **加第 7 把枪 = 改 1 个 json + 加 1 个 tscn，零 GDScript 改动。**（本设计的成败判据）
2. 上行数据包不再要求"两端背包逐元素同序"。
3. 同型号两把之间换手持时，残弹/高亮/丢弃不再串。
4. 命名上不再有"同名不同义"的词。

### 非目标（本次明确不做）

- **不拆 `WeaponBase`**、不把弹夹/子弹分层进"射击型"中间层（等真加近战武器时再做，见 §5）。
- **不把背包泛化成通用物品栏**（消耗品另有一套系统）。
- **不做能力/解锁系统**（只把容量与把数改成**可配**，默认值不变）。
- **类型 id 不改字符串**（保留整数 1–N）。
- **容量 8 格与 4 把上限都不删** —— 用户裁定二者都是游戏规则，不是冗余。
- **不给 `weapons.json` 预加 `kind` 字段**（近战用同样四个字段就够，见 §5）。

---

## 3. 命名纪律（本设计的核心关键点）

**全程只有三个词，且不许互相借用：**

| 词 | 含义 | 出现在哪 |
|---|---|---|
| `type_id` | 整数 1–N，**哪一种**武器。**与键位、与背包位置都无关**（用户 2026-09-25 明确定） | 注册表键、禁用武器列表、快照的"枪型"、菜单 |
| `inst` | **哪一把**（同一把从生成到销毁不变） | 输入包、服务端权威状态（`capture_state`）、UI 高亮、残弹记账 |
| `index` | 背包里的**第几个**（0-based） | **只在本地**：按键解析、HUD 行号、`WeaponInventory.slot_start` |

**`slot` 一词整体退休。** 逐处改名：

| 今天 | 改成 | 位置 |
|---|---|---|
| `_current_slot` | `_current_type` | `weapon_component.gd` |
| `current_slot_int()` | `current_type_id()` | 同上（`match_snapshot.gd` 是唯一协议消费者） |
| `is_slot_enabled(slot)` | `is_type_enabled(type_id)` | 同上 |
| `enabled_slots` | `enabled_types` | 同上 + `set_enabled_slots` → `set_enabled_types` |
| `default_slot() -> String` | `default_type() -> String` | 同上（返回的是 `str(type_id)`） |
| `push_net_slot(slot)` / `consume_net_slot()` | `push_switch_inst(inst)` / `consume_switch_inst()` | 同上 |
| `equip(slot: String)` | `equip_type(type_id: int)` | 同上 |
| `weapon_slot`（`player.tscn` 的节点名） | **保留**（它是"挂枪的那个挂点"，与"武器槽位"是两件事） | `player.gd` / `player.tscn` |

★ `WeaponInventory.slot_start(index)` 里的 `slot` 指的是**容量格**，与键位无关 —— 改名
`cell_start(index)`，并把它与 `cost_of` 一起统一成"格子"语汇。

**唯一合法的"数字 = 键位"是 HUD 左下角武器框的行首数字**（`ui/hud.gd` 的
`key_lbl.text = str(held_index + 1)`）—— 它指的就是背包位置，而背包位置就是键位。

**菜单上的编号必须去掉**：`scenes/main_menu.gd` 与 `ui/weapon_icons.gd` 今天渲染
`"%d. %s" % [type_id, name]`（→「1. 手枪 … 6. 激光枪」），**那个数字看起来就是键位**，
而它与键位毫无关系 ⇒ 只留"图标 + 名字"。

---

## 4. 设计

### 4.1 上行传"解析结果"，不传"寻址方式"

**今天**：输入包 `{"weapon": <背包位置 1-4>}`（`packet_input_source.gd`），服务器
`player.gd` 读 `equip_index(wslot - 1)` —— 用**它自己的** `held` 数组解。

**为什么必须改**：数字键与滚轮的语义**本来就是"位置"**（按 `2` = 我背包里第 2 把、
滚轮 = 往下一把）。那是**本地交互**，只有客户端知道玩家点的是第几个；把它过网，
就等于要求"两端 `held` 数组逐元素同序"。而拾取/丢弃是**服务器裁决、客户端不预测**的
⇒ 那 ≈1 RTT 的窗口里，同一个下标在两端解出**不同的枪**。这是症状 1 的结构性来源。

**改成**：

```
客户端：本地解析（数字键按 index、滚轮按相对位置）→ 得到"目标那一把" → 取它的 inst
上行  ：{ "winst": <inst> }        # 新增键；旧的 "weapon" 键**删掉**
服务器：index_of_inst(inst) → 找到就切；找不到就不动
```

- 两端 `held` 顺序不同**不再是问题**（`inst` 逐把唯一）。
- 服务器找不到那把（已被丢弃）时**静默不动** —— 语义比"下标越界"准确。
- 数字键/滚轮的**本地即时切**照旧（那是手感，不能过网）。

★ **旧键 `"weapon"` 必须删掉，不能留** —— 留一个同名不同义的键就是本设计要消灭的那个病。
`match_snapshot.gd` 里下行的 `"weapon"`（值是 `type_id`）**保留**，但**改名 `"type_id"`**，
让"上行 inst / 下行 type_id"在字段名上就分得开。

★ **协议改动 = 两端必须同版本**（本仓既有纪律）。这是 demo 级 LAN 对局，无跨版本兼容需求。

### 4.2 统一注册表数据源

新增 `core/sim/weapon_registry.gd`（`class_name WeaponRegistry`、`RefCounted`、
**纯静态、无 autoload、`-s` 可测** —— 与 `MapFormat` / `GridPathfinder` 同款）：

```
all_ids() -> Array[int]        # json 数组顺序 = 菜单顺序 = 散落顺序
has(type_id) -> bool
scene_of(type_id) -> String
name_of(type_id) -> String
tier_of(type_id) -> int        # → WeaponBase.Tier 枚举
tiers_map() -> Dictionary      # {type_id: tier}，供 WeaponInventory 注入
```

- **删掉** `WeaponComponent.WEAPONS` / `DISPLAY_NAMES` / `TIERS` 三张表；调用方一律改问 registry。
- `WeaponInventory.new(TIERS)` 保持**注入**（那正是它今天不引 autoload 的原因），
  注入源换成 `WeaponRegistry.tiers_map()`。
- **五处硬编码的 `[1, 2, 3, 4, 5, 6]` 改成 `WeaponRegistry.all_ids()`**：

  | 位置 | 干什么 |
  |---|---|
  | `scenes/level_0.gd` `_default_weapon_types()` | 单机散落哪些枪 |
  | `scenes/lobby_page.gd` 禁用武器网格 | 对战选项勾选列 |
  | `scenes/main_menu.gd` 单人面板 | 同上（单机） |
  | `server/match_ground.gd` `_server_weapon_types()` | 联机铺哪些枪 |
  | `scenes/player/weapon_component.gd` `enabled_types` 初始化 | 启用表本身 |

  ★ 这五处**今天没有任何东西在管它们与注册表的关系** —— 加第 7 把枪时漏改
  `enabled_types` 会让新枪**永远拿不到也开不了**，且不报错。

- **守卫改判据**：`tests/enemy_logic_smoke.gd` 的 `_phase_weapon_registry` 今天比的是
  "三张 const 表的键集 ↔ tscn 的 `tier` export ↔ 枚举值"。改成
  **json ↔ tscn export ↔ 枚举值**，并**新增一条今天没有的**：
  `all_ids()` 必须覆盖散落/菜单/禁用网格实际用到的每一个 id。

### 4.3 同型号两把的重建判据

`player._apply_weapon_state` 今天用

```gdscript
if wslot > 0 and wslot != weapons._current_slot:   # 两边都是**类型 id**
```

决定"要不要重建武器实例"。**同型号两把之间换手持时这个判据恒为假 ⇒ 永不重建**，
于是 `_current_index` 已经指向 B、而场上活着的 `_weapon` 还是为 A 建的那个节点。
类型相同所以几何无差别，**但 `mag_ammo` 挂在实例上** —— 两边就此分家，而 HUD 读实例。

~~**改成判 `inst`**：`if winst > 0 and winst != weapons.current_inst()`。重建后
`equip_index(index_of_inst(winst))`。~~

★ **2026-09-25 订正：本节要的机制已经落地（`eeda162` + `f33249b`），且上面那个判据是错的** ——
它跑在 `restore_inventory` **之后**、解析成功时**恒假**，会**绕过**现有的重建落点。
现状：`restore_inventory(entries, want_inst)` 先按 inst 解析手持下标（解析成功时**故意**保持
`_current_slot = keep_type`），`_apply_weapon_state` 用 `by_inst` 决定重建落点（成功走
`equip_index(_current_index)`、兜底才走 `equip(str(wslot))`），`sync_soft_state` 的指纹已含 `winst`，
`ground_client_probe` ④b 在两条路径上各指一把同型号枪做了**行为级**断言。
⇒ **本节的机制不要再动**；要动先复现残余症状。

### 4.4 容量与把数可配（不接能力系统）

- `WeaponInventory` 的 `CAPACITY` / `MAX_WEAPONS` 从 `const` 变成**实例字段**，
  构造时带默认值 8 / 4，配 setter。
- `ui/weapon_slots.gd` 的 `COLS := 4` / `ROWS := 2` 变成**派生**：
  `COLS` 固定 4、`ROWS = ceili(capacity / 4.0)`（容量长大时格阵**向下长**，不换行宽）。
  `PANEL_W` / `PANEL_H` 随之派生。
- **协议无需修改**：默认值不变 ⇒ 两端天然一致，容量**不进** `capture_state`、
  **不进** `match_options`。
- ★ **为什么今天可以不进同步**：`pick_up` 的 `can_hold`（容量 + 把数）是**服务器裁决**的，
  而客户端 UI 也读它。今天它不需要同步**仅仅因为它是常量**。将来真的按能力分叉时，
  **它必须进服务端权威同步**，否则就是"客户端显示还能捡、服务器说满了" —— 又一个不报错的分叉。
  **这条写进 §6 已知边界，别当成"已经想清楚了"。**

### 4.5 `equip()` 的"背包里没有就加入"要降级

`WeaponComponent.equip()` 今天有一条 **"没有就加"** 分支：按类型找不到时**当场 `add()` 一把**。
它的注释写明这是**联机兜底**——"服务器说'你现在有重狙'而客户端背包里可能还没有它"。

**§4.1 落地后这条兜底不再需要**：客户端背包只从服务端权威状态（`inv`）重建，而 `winst` 也在同一份
数据包里；`restore_inventory` 先跑、重建判据再判 `inst`（§4.3），所以"权威说的那把不在本地表里"
**只可能是真异常**，不是常态。

⇒ 改成 **`push_error` + 不加入**。理由与"凭空造枪"是同一条：今天它会**静默改变背包长度**，
而那正是"两端 `held` 不同序"的另一条产生源（§4.1 要消灭的东西）。

★ 注意：这条**只在联机路径上可降级**。单机的 `pick_up` 走的是 `WeaponInventory.add`，
不经过 `equip()`，不受影响。

---

## 5. 数据形状：`data/weapons.json`

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

- **只装身份**，数值（`fire_cooldown` / `damage` / `mag_size` / `reload_time` / …）
  **继续留在各枪的 `.tscn` 的 `@export`** —— 与 `data/enemies.json` 同构，保留在 Godot
  编辑器里可视化调参的能力。
- `id` **就是**那个整数 `type_id`，**不是另一个名字**（不能出现 `{"id": "pistol", "slot": 3}`
  —— 那是又开一条 id 空间）。
- `tier` 是**值不是标识**：用字符串（`light`/`medium`/`heavy`）与 `tile_defs.json`
  （`"wall"`/`"liquid"`）同风格，由注册表映射回 `WeaponBase.Tier`。
- **数组顺序 = 菜单顺序 = 散落顺序**（今天 `[1..6]` 的循环顺序就是这个，必须显式化成数据）。
- **加载时校验**：`id` 唯一且为正整数、`scene` 能 `load`、`tier` 是三值之一 ——
  不合格 `push_error` **并跳过该条**（与 `EnemySpawner` 的"格式错 → push_error、表保持空"
  同款，不静默吃下坏数据）。

### 关于"近战武器"（本次不做，但形状已被约束）

用户 2026-09-25 明确：**将来只有近战与远程两类，且都不是消耗品**（消耗品另有一套系统）。
⇒ 近战武器用**同样四个字段**就够（匕首 = `{"id": 7, "name": "匕首", "tier": "light", "scene": …}`），
**数据面无需修改**。要动的只有将来那层 `WeaponBase` 分层（把弹夹/子弹搬进"射击型"中间层），
以及届时 `capture_state` 的 `mag` 与 HUD 的 `%d/%d` 需要一个"不适用"的表达。

---

## 6. 已知边界与残余（登记，不修）

1. **`MAX_WEAPONS > 4` 时第 5 把没有数字键。** 键位固定 1–4（因为"id 与键位无关"），
   所以把数被调到 5+ 时，第 5 把**只能靠滚轮**切。将来真要开 5/6 号键：
   `project.godot` 里那两个动作**还在**（今天的死代码届时正好派上用场），
   但 `LocalInputSource._weapon_slot_raw()` 的 `range(1, 5)` 要一并改。
2. **容量/把数一旦按能力分叉，必须进服务端权威同步。** 见 §4.4 末尾。今天不进的唯一理由是
   "默认值不变 ⇒ 两端天然一致"。
3. **弹数仍没有常规纠正路径。** `PredictionRollback._close_enough` 不比 `mag`，
   `Player.sync_soft_state` 的指纹只比结构。计划 1 删掉的是**误差的产生源**
   （每次回滚抹掉重放消耗），**没有新增纠正路径**。已知候选残余：榴弹的
   `max_live_projectiles`（客户端数得到的在飞弹数与服务器可能不同 ⇒ 一边扣弹一边不扣）。
4. **`_equip_index` 重建那一帧 `get_viewport()` 为 null（推断，未复现）。** 新武器实例由
   `call_deferred("add_child")` 入树，而同帧 `player._physics_process` 会 `weapons.tick()`
   → `fire()` → `_spawn_projectiles` 里 `get_viewport().add_child(b)`；未入树的节点
   `get_viewport()` 返回 null。若成立，它是"回滚 + 同帧开火"时的一条报错（不是崩溃）。
   **本次不顺手修**，在计划 1 的实机验收里留意 stdout。
5. **五处 `[1..6]` 改成 `all_ids()` 之后，"菜单顺序"依赖 json 数组顺序。** 有人重排 json
   就会改变菜单与散落顺序（不是 bug，但没有守卫阻止误排）。若要断言约束，加一条
   "顺序变化即测试报错"的探针 —— 本次不做，登记。

---

## 7. 验收判据

1. **加第 7 把枪 = 改 1 个 json + 加 1 个 tscn，零 GDScript 改动**（删掉 `enabled_types` 那条
   硬编码之后成立）。这条要靠**实际走一遍**验证，不是靠读代码。
2. **新探针：两端 `held` 顺序不同时，切枪仍切到同一把。** 构造：让客户端与服务器的背包
   获得顺序相反（如服务器先给 A 后给 B、客户端拿到的是 `[B, A]`），按同一个键，
   断言两端 `_current_index` 指向**同一把 `inst`**。这条探针在**今天必然红**（今天按下标解）。
3. 同型号两把之间换手持时，残弹 / HUD 高亮 / 丢弃**不串**（§4.3）。
4. **既有探针全部通过**，逐个显式指定：
   `pvp_twin_smoke` / `kh_l3_probe`（同帧滚轮残弹记忆）/ `kh_l4_probe` /
   `weapon_pickup_probe` / `weapon_inventory_smoke` / `ground_client_probe` /
   `ground_action_probe` / `net_ground_probe` / `enemy_logic_smoke._phase_weapon_registry` /
   `level0_weapon_scatter_probe`。
5. 实机：1v1 与大乱斗各打一局，**捡第二把后**用数字键与滚轮来回切，不出现"切不动/跳回"。

---

## 8. 计划拆分（按依赖序）

| # | 计划 | 覆盖 | 碰协议? |
|---|---|---|---|
| 1 | **弹药在回滚中的保真** | 症状 3 的根因（C1，已实测确认） | 否 |
| 2 | **命名纪律 + 实例身份** | §3 + §4.1 + §4.3；症状 1、2 | **是** |
| 3 | **统一注册表数据源** | §4.2 + §5 | 否 |
| 4 | **容量/把数可配** | §4.4 | 否 |

- 计划 1 **已写好**：`docs/superpowers/plans/2026-09-25-ammo-rollback-fidelity.md`
  （它与本 spec 的 §3–§5 **完全正交** —— 不碰身份、不碰注册表、不碰容量）。
- 计划 2 与 3 都写在本 spec 的新词汇上（词汇是 spec 的一部分），所以先后都不返工；
  顺序按"先修 bug"排。**两者会先后改同一个文件**（`weapon_component.gd`），
  **不得并行**，只能串行。

---

## 9. 本设计明确不做的事（后续独立计划）

- **拆 `WeaponBase`**（把弹夹/子弹搬进"射击型"中间层）：等真加近战武器时做，那时手里有
  第二个形状可以验证接口规范。现在做是只有一个实现的投机性抽象。
- **泛化背包成通用物品栏**：消耗品有自己的一套系统。
- **能力/解锁系统**：本次只把两条限制条件改成可配。
- **类型 id 改字符串**：`"pistol"` 更好读，但它不修任何 bug，且要连协议 + 两个写入磁盘数组
  （`user://settings.cfg` 的禁用列表）+ 菜单 + 图标 + 若干探针一起改。YAGNI。
- **队伍色与常量的唯一定义**：`C_TEAM_A/B` + `SELF_COLOR` + 底板色 6 处，以及
  **"未知队号"在三个消费点的三种口径**（`TeamHost._apply_team_layers` 报错+什么都不配 /
  `team_game._team_color` 返回中性亮白 / `team_game._ghost_layer_of` 落到层 16 = 队 2）。
  独立的 UI/规则面，与本 spec 解耦，另立计划。
- **历史未清算的两处**（各自独立、都小）：
  - `NetBusExt.beam_fired` 与 `NetBus.beam_fired` **重名**（KH 遗留重复）。接收端挂错节点是
    **静默 no-op**。删它需要连带改 `net_ground_probe` 的双向断言。
  - 若干**文档残留**：`scenes/royale_game.gd` 的两处陈旧注释、
    `tests/kh_l{3,4,5,6}_probe.gd` 文件头"中途报错就不会打印 ALL-OK"的旧说法
    （权威表述已在 `tests/lib/probe_base.gd` 文件头）。
- **碰撞层位仍是人工约定**（1 地形 / 2 玩家 / 4 敌人 / 8 掉落物 / 16 = 队 B）。本次不动。

## 10. 已排除的伪发现（勿重复排查）

1. **"GUI 会吃掉滚轮"—— 推翻。** 见 §1.3：读引擎源码定案，`force_pass_scroll_events`
   默认为 `true`，滚轮照常到达 `_unhandled_input`。
2. **"同一 tick 里数字键 + 滚轮会分叉"—— 推翻。** 实测 `_unhandled_input` 的派发在
   `_physics_process` **之后**，两者不会在同帧互相覆盖。
3. **"删掉 `CAPACITY` 或 `MAX_WEAPONS`"—— 已裁定不做。** 用户：两者都是游戏规则，
   只是**默认值**，将来会被能力改。已改为"可配"（§4.4）。
4. **"把三张表改写成 `static var`（运行时从 json 填）就能保留调用点"—— 不采用。**
   那样键型问题（`WEAPONS` 用 String 键、另两张用 int 键）原样留着，且 `const` → `static var`
   会让今天"三张表互相对账"的守卫失去意义（它比的是 const）。
5. **"`_restore_mag` 改成同步调用即可"—— 不够。** 同步写会被新武器实例的 `_ready`
   （`mag_ammo = mag_size`）冲掉，因为入树是 `call_deferred`。正解见计划 1 的 `pending_mag`。

---

## 附：本设计引用的事实核验清单

| 事实 | 怎么核的 |
|---|---|
| `_unhandled_input` 晚于 `_physics_process` | 2026-09-25 `--headless` 场景探针，日志 `P1…P8 U8 P9…` |
| `force_pass_scroll_events` 默认 true | 读 `godot-4.7.1-src/scene/gui/control.h:286` |
| STOP 会 `set_input_as_handled()` 但有滚轮例外 | 读 `godot-4.7.1-src/scene/main/viewport.cpp::_gui_call_input()` |
| `_restore_mag` 的 deferred 会覆盖后写 | 2026-09-25 场景探针：写 9 → 过两帧读回 10 |
| `[1..6]` 硬编码在 5 处 | `grep -rn "1, 2, 3, 4, 5, 6" --include=*.gd scenes core server ui tests` |
| `refill_current_weapon` 无生产调用点 | 全仓 grep：只有声明、注释与 `kh_l4_probe` 的两条断言 |
