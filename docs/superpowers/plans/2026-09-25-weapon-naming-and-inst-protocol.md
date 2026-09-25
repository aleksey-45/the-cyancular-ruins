# 武器命名纪律 + 实例身份协议（上行传 `inst`）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"哪把枪"这件事从**三套互相错位的表示**收敛成两个词（`type_id` / `inst`），并让上行输入包传
**解析结果（`inst`）**而不是**寻址方式（背包位置）** —— 于是"两端背包逐元素同序"这条隐含前提被彻底拆掉。

**Architecture:** 现状是三处错位：① `_current_slot` 是**类型 id**、`push_net_slot` 收**背包位置**、
`is_slot_enabled` 收**类型**、`enabled_slots` 是**类型数组** —— 四个 `slot` 三个含义；
② 上行包 `"weapon"` 带的是**背包位置（1-based）**，服务器用它**自己的** `held` 数组解
（`player.gd` 的 `equip_index(wslot - 1)`）⇒ 拾取/丢弃是服务器裁决、客户端不预测，那 ≈1 RTT 的窗口里
同一个下标在两端解出**不同的枪**（症状 1 的结构性来源）；③ 下行快照的 `"weapon"`（值是类型 id）
与上行同名不同义。本计划：**先做纯重命名（行为逐字不变）**，再把上行值从位置换成 `inst`、
下行键改名 `type_id`，最后把 `equip()` 的"没有就加"降级为 `push_error`。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、场景探针（`--headless --quit-after`）+ 一个**真建两个
`player.tscn`** 的行为探针。

**来源 spec:** `docs/superpowers/specs/2026-09-25-weapon-system-rework-design.md` §3 + §4.1 + §4.5。

**事实基线:** `.superpowers/sdd/weapon-spec-verify.md`（42 条：23 ✅ / 14 ⚠️ / **5 ❌**）。
本计划按**核实后的事实**写。下面三条是那 5 条 ❌ 里与本计划直接相关的，**已按核实后的事实执行**：

- **§4.3 整体不做**（spec 自己已划掉）：`current_inst()` / `restore_inventory(entries, want_inst)` /
  `_apply_weapon_state` 的 `by_inst` 重建分流**全在位**（`eeda162` + `f33249b`），
  `ground_client_probe` ④b 已在两条路径上做了行为断言。spec 提议的判据
  `winst != weapons.current_inst()` 跑在 `restore_inventory` **之后**、解析成功时**恒假**，
  照它写会**绕过**现有的重建落点。**本计划不碰 `_apply_weapon_state` 的那段分流。**
- **§7.4 里两条"应保持全绿"的守卫是假的**：`tests/net_ground_probe.gd:137-145`（源码级，断言
  `equip_index(wslot - 1)` **必须**在 `player.gd` 里）与 `tests/ground_client_probe.gd:247-274`（行为级，
  断言上行值 = 背包位置、并**明确规定不得是 type id**）被 §4.1 **直接反证**。本计划 Task 2 **改写**它们，
  不是"保持绿"。
- **§4.1 的键被大量探针手搓**：上行键 **14 个文件**、下行快照夹具 **6 个文件** —— 逐个点名在 Task 2/3 里。

---

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  本计划全部探针都是 `--headless`、**不占任何端口**；**实机验收（1v1 + 大乱斗各一局）归用户**。
- **判据一律是 grep 文本**，不看退出码：探针挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
  ★ 更尖的一层（`tests/lib/probe_base.gd` 文件头是权威落点）：**`ALL-OK` 只证明"没有任何断言失败"，
  不证明"该跑的断言都跑过"** —— 脚本错误只让**出错的那个函数当场结束**，调用方继续。
  故本计划里凡是"整相可能被跳过"的地方，都配有**完成戳**或**具名失败**，不做静默 `return`。
- `--quit-after` **统一给 3600 帧**（安全网，只在挂住时用得上；给少了会在负载重时先耗尽）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，别用 `-m "…"`
  （双引号会**静默吞掉**反引号与 `$`）。
  ★ 新建的 `tests/weapon_switch_inst_probe.gd/.tscn` 会由 Godot 在首次导入时生成
  `*.gd.uid` / `*.tscn.uid` —— 若 `git status` 显示就**一并 `git add`**（漏了会在下次导入时被重新分配）。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`）。本计划**不引入任何新字号**；
  Task 1 改 `ui/weapon_icons.gd:68` 与 `scenes/main_menu.gd:345` 时**只删格式串里的数字前缀**，
  `UiFactory.label(…)` 的**实参个数与字号实参位置都不变**（`kh_l4_probe._scan_factory_arg` 按
  **下标 1** 取 `UiFactory.label` 的字号实参、按下标 2 取 `make_weapon_check` 的 —— 位置动了它就扫错东西）。
- 只改 GDScript ⇒ **只需重导出**，别去重编裁剪模板。
- ★★ **本计划改的是网络包 ⇒ 客户端与服务器必须跑同一个 build**（本仓既有纪律，与 `BIT_RELOAD` /
  `BIT_PICKUP` / `BIT_DROP` 那三条同款）。这是 demo 级 LAN 对局，**无跨版本兼容需求**；
  但反过来说：**严禁"只改了客户端"或"只改了服务端"的半成品状态** —— 半成品**不报错**，
  表现只是"切枪没反应"（上行）或"对手的枪凭空消失"（下行）。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `scenes/player/weapon_component.gd` | 武器子系统：背包/换枪/待发切枪 | **重命名** 9 个符号 + `equip_type`；**加** `inst_at_index` / `equip_inst` / `take_uplink_switch`；**改** `request_net_cycle` 上行 inst；**改** `equip_type` 的"没有就加"分支（§4.5） |
| `scenes/player/player.gd` | 玩家根：物理帧编排 | **改** `_physics_process` 的切枪段（拆成"本地位置"与"权威 inst"两条路）；`equip` → `equip_type` |
| `core/net/player_input.gd` | 输入源纯接口 | **重命名** `get_weapon_slot_pressed`/`_weapon_slot_raw`；**加** `consume_switch_inst()`（frozen 短路的公开读口）+ `_switch_inst_raw()`（可选钩子，默认 0） |
| `core/net/packet_input_source.gd` | 输入包**编码端唯一来源** + 解码端 | **删** `_weapon` 字段与 `"weapon"` 键，**加** `_switch_inst` 字段与 `"winst"` 键；`_switch_index_raw()` 恒 0 |
| `core/net/local_input_source.gd` / `ai_input_source.gd` | 本地 / AI 输入源 | 只改钩子名 |
| `core/sim/weapon_inventory.gd` | 背包纯逻辑 | **重命名** `slot_start`→`cell_start`、`used_slots`→`used_cell_count`、`SLOT_COST`→`CELL_COST` |
| `scenes/pvp_match_client.gd` | 客户端 C2 循环 + 组包 | **改** 组包段：`take_uplink_switch(...)` → `pkt["winst"]` |
| `server/match_snapshot.gd` | 下行世界包生产端 | **改名** `"weapon"` → `"type_id"` |
| `scenes/player/player_replica.gd` | 对手副本 | **改名** 读 `"type_id"`；`_weapon_slot_int`→`_weapon_type_int`；`_swap_weapon(slot)`→`(type_id)` |
| `scenes/level_0.gd` / `scenes/lobby_page.gd` / `scenes/main_menu.gd` / `scenes/royale_lobby.gd` / `ui/weapon_icons.gd` / `ui/hud.gd` / `ui/weapon_slots.gd` / `server/match_host.gd` / `server/match_ground.gd` | 调用方与菜单 | 重命名 + **菜单编号去掉** |
| `tests/weapon_switch_inst_probe.gd` / `.tscn` | **新探针**：命名纪律 + 上行 inst 端到端 + 下行键两端同源 | 全新建 |
| `tests/net_ground_probe.gd` / `tests/ground_client_probe.gd` | 被 §4.1 **反证**的两条守卫 | **改写**判据（不是保持绿） |
| `tests/kh_l3_probe.gd` | 闸门/滚轮/残弹记忆 | 重命名 + **加** §4.5 的红断言 |
| 其余 ~20 个探针 / watcher | 手搓上下行键的夹具 | 逐处改名（上行清单 = Task 2 Step 8；下行清单 = Task 3 Step 4） |

---

### Task 1: 词汇重命名 —— 行为逐字不变

**Files:**
- Modify: `scenes/player/weapon_component.gd`、`scenes/player/player.gd`、`scenes/player/player_replica.gd`、
  `core/net/player_input.gd`、`core/net/packet_input_source.gd`、`core/net/local_input_source.gd`、
  `core/net/ai_input_source.gd`、`core/sim/weapon_inventory.gd`、`scenes/pvp_match_client.gd`、
  `scenes/level_0.gd`、`scenes/lobby_page.gd`、`scenes/main_menu.gd`、`scenes/royale_lobby.gd`、
  `ui/weapon_icons.gd`、`ui/hud.gd`、`ui/weapon_slots.gd`、`server/match_host.gd`、`server/match_ground.gd`、
  `core/config/run_options.gd`、`core/net/pvp_session.gd`
- Modify（测试）: `tests/kh_l3_probe.gd`、`tests/level0_weapon_scatter_probe.gd`、`tests/ground_action_probe.gd`、
  `tests/ground_client_probe.gd`、`tests/ground_net_watcher.gd`、`tests/pvp_reconcile_smoke.gd`、
  `tests/pvp_twin_smoke.gd`、`tests/snapshot_size_probe.gd`、`tests/team_match_watcher.gd`、
  `tests/weapon_pickup_probe.gd`、`tests/weapon_inventory_smoke.gd`、`tests/ai_input_source_smoke.gd`、
  `tests/team_bot_input.gd`、`tests/ground_bot_input.gd`、`tests/soak_bot_input.gd`、
  `tests/royale_bound_watcher.gd`、`tests/enemy_logic_smoke.gd`、`tests/menu_autotest.gd`、
  **`tests/preview_visibility_probe.gd`**（★ 它只被本 Task 改一行 `:50` 的 `equip`，但那行**必须**在
  Files 清单里 —— 见 Step 3 那张表的"第 9 处"）

**Interfaces:**
- Consumes: 无（本 Task 不新增任何接口）。
- Produces: 下面 15 个新名字 —— `_current_type` / `current_type_id()` / `is_type_enabled()` /
  `enabled_types` / `set_enabled_types()` / `default_type()` / `cycle_index()` /
  `get_switch_index_pressed()` / `_switch_index_raw()` / `_weapon_type_int` /
  `cell_start()` / `used_cell_count()` / `CELL_COST` / `equip_type()`，以及 `weapon_changed(type_id)`。

★ **本 Task 的行为必须逐字不变**（`equip_type` 的签名从 `String` 变 `int`，但**语义与今天完全一致**，
包括那条"没有就加"的分支 —— 它归 Task 4）。判据 = 既有探针全绿 + Step 6 的 grep 闸门为空。

★ **本 Task 刻意不碰 `push_net_slot` / `consume_net_slot` / `_net_slot`**：那三个名字的**值**会从
"背包位置"变成"inst"，改名与改语义必须同时发生（否则会出现"参数名叫 `inst` 而里面装的是位置"这种
比现状更糟的中间态）。它们归 Task 2。

- [ ] **Step 1: 采一条基线（改动前）**

```bash
source tests/env.sh
for t in kh_l3_probe level0_weapon_scatter_probe weapon_pickup_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
"$GODOT" --headless --path . -s res://tests/weapon_inventory_smoke.gd 2>&1 | grep -E "OK|FAIL"
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "SMOKE OK|FAIL"
```
Expected: 全绿 —— `KH L3 PROBE: ALL-OK` / **`LEVEL0 SCATTER: ALL-OK`** /
**`WEAPON PICKUP: ALL-OK`**（★ 这两个串**不带 `PROBE` 一词**，别按名字猜）/
`WEAPON_INVENTORY OK` / `SMOKE OK`。
★ **把这一趟的原文留着** —— Task 1 的验收是"与它逐条相同"，不是"看起来绿"。

- [ ] **Step 2: 符号级重命名（逐符号、逐文件，不做"rename all"）**

`perl` 用 `\b…\b` 词边界，**顺序无关**（`\b_current_slot\b` 不会命中 `current_slot_int`，
`\bcurrent_slot_int\b` 只命中全名）。逐条跑：

```bash
# 1) _current_slot → _current_type
perl -pi -e 's/\b_current_slot\b/_current_type/g' \
  scenes/player/weapon_component.gd scenes/player/player.gd ui/hud.gd tests/level0_weapon_scatter_probe.gd

# 2) current_slot_int → current_type_id
perl -pi -e 's/\bcurrent_slot_int\b/current_type_id/g' \
  scenes/player/weapon_component.gd scenes/player/player.gd server/match_ground.gd server/match_snapshot.gd \
  ui/hud.gd tests/ground_action_probe.gd tests/ground_client_probe.gd tests/ground_net_watcher.gd \
  tests/kh_l3_probe.gd tests/level0_weapon_scatter_probe.gd tests/pvp_reconcile_smoke.gd \
  tests/pvp_twin_smoke.gd tests/snapshot_size_probe.gd tests/team_match_watcher.gd tests/weapon_pickup_probe.gd

# 3) is_slot_enabled → is_type_enabled
perl -pi -e 's/\bis_slot_enabled\b/is_type_enabled/g' \
  scenes/player/weapon_component.gd scenes/level_0.gd scenes/pvp_match_client.gd tests/kh_l3_probe.gd

# 4) set_enabled_slots → set_enabled_types（★ 必须先于 5 —— 见下面那句说明）
perl -pi -e 's/\bset_enabled_slots\b/set_enabled_types/g' \
  scenes/player/weapon_component.gd scenes/level_0.gd scenes/pvp_match_client.gd server/match_host.gd \
  core/config/run_options.gd core/net/pvp_session.gd \
  tests/kh_l3_probe.gd tests/weapon_pickup_probe.gd

# 5) enabled_slots → enabled_types
perl -pi -e 's/\benabled_slots\b/enabled_types/g' \
  scenes/player/weapon_component.gd scenes/level_0.gd scenes/pvp_match_client.gd server/match_host.gd \
  core/config/run_options.gd core/net/pvp_session.gd \
  tests/kh_l3_probe.gd tests/royale_bound_watcher.gd tests/weapon_pickup_probe.gd

# 6) default_slot → default_type
perl -pi -e 's/\bdefault_slot\b/default_type/g' \
  scenes/player/weapon_component.gd scenes/player/player.gd scenes/level_0.gd tests/kh_l3_probe.gd

# 7) cycle_slot → cycle_index
perl -pi -e 's/\bcycle_slot\b/cycle_index/g' \
  scenes/player/weapon_component.gd scenes/player/player.gd tests/kh_l3_probe.gd

# 8) get_weapon_slot_pressed → get_switch_index_pressed
perl -pi -e 's/\bget_weapon_slot_pressed\b/get_switch_index_pressed/g' \
  core/net/player_input.gd core/net/packet_input_source.gd scenes/player/player.gd \
  tests/ai_input_source_smoke.gd tests/team_bot_input.gd

# 9) _weapon_slot_raw → _switch_index_raw
perl -pi -e 's/\b_weapon_slot_raw\b/_switch_index_raw/g' \
  core/net/player_input.gd core/net/local_input_source.gd core/net/ai_input_source.gd \
  core/net/packet_input_source.gd tests/ground_bot_input.gd tests/soak_bot_input.gd \
  tests/team_bot_input.gd tests/kh_l3_probe.gd

# 10) _weapon_slot_int → _weapon_type_int
perl -pi -e 's/\b_weapon_slot_int\b/_weapon_type_int/g' \
  scenes/player/player_replica.gd tests/ground_client_probe.gd

# 11) slot_start → cell_start
perl -pi -e 's/\bslot_start\b/cell_start/g' \
  core/sim/weapon_inventory.gd ui/weapon_slots.gd tests/weapon_inventory_smoke.gd

# 12) used_slots → used_cell_count
perl -pi -e 's/\bused_slots\b/used_cell_count/g' \
  core/sim/weapon_inventory.gd scenes/player/weapon_component.gd \
  tests/ground_action_probe.gd tests/weapon_inventory_smoke.gd tests/weapon_pickup_probe.gd

# 13) SLOT_COST → CELL_COST
perl -pi -e 's/\bSLOT_COST\b/CELL_COST/g' \
  core/sim/weapon_inventory.gd scenes/player/weapon_component.gd tests/weapon_inventory_smoke.gd
```

★ **第 4 步先于第 5 步**（安全边际，不是必需）：`\benabled_slots\b` 因 `_` 是词字符而**不会**命中
`set_enabled_slots` 里的那一段，故两条独立；但把它们按"长名在前"排，将来有人把 `\b` 去掉时不会
把 `set_enabled_slots` 撕成 `set_enabled_types` 后再被第二条二次命中。

★ 名字**没有碰撞**（逐条查过，全仓 0 命中）：`_current_type` / `current_type_id` / `is_type_enabled` /
`enabled_types` / `set_enabled_types` / `default_type` / `cycle_index` / `get_switch_index_pressed` /
`_switch_index_raw` / `_weapon_type_int` / `cell_start` / `CELL_COST`。
★ `used_cell_count` 是**刻意**避开 `used_cells` 的：`tests/menu_autotest.gd:295` 有一处
`wl.get_used_cells()`（Godot `TileMapLayer` 的 API）—— 同名会让全仓 grep 出现假命中。

- [ ] **Step 3: `equip` → `equip_type` —— 必须逐调用点改，不能 perl 全仓**

★ **`equip` 这个名字在仓里有两个不同的方法**：`WeaponComponent.equip(String)`（本 Task 改名）
与 `WeaponBase.equip(player: Node2D, inherit_cooldown: float)`（**不动**）。
一条 `s/\bequip\b/equip_type/g` 会把后者一起撕掉。
**下面 9 个调用点逐个改（+ 定义那一行，共 10 处），其它一处都不碰**：

| 文件:行 | 今天 | 改成 |
|---|---|---|
| `scenes/player/weapon_component.gd:176-177` | `func equip(slot: String) -> void:` / `\tvar type_id := int(slot)` | `func equip_type(type_id: int) -> void:` / （**删掉** `var type_id := int(slot)` 这一行） |
| `scenes/player/player.gd:677` | `weapons.equip(str(wslot))` | `weapons.equip_type(wslot)` |
| `tests/enemy_logic_smoke.gd:454` | `p.weapons.equip("2")` | `p.weapons.equip_type(2)` |
| `tests/enemy_logic_smoke.gd:460` | `p.weapons.equip("1")` | `p.weapons.equip_type(1)` |
| `tests/kh_l3_probe.gd:177` | `wep.equip("1")` | `wep.equip_type(1)` |
| `tests/kh_l3_probe.gd:182` | `wep.equip("4")` | `wep.equip_type(4)` |
| `tests/menu_autotest.gd:168` | `player.weapons.equip("5")` | `player.weapons.equip_type(5)`（Task 4 会把这一行再改一次，见那里） |
| `tests/menu_autotest.gd:183` | `player.weapons.equip("5")` | `player.weapons.equip_type(5)` |
| `tests/menu_autotest.gd:206` | `player.weapons.equip("1")` | `player.weapons.equip_type(1)` |
| **`tests/preview_visibility_probe.gd:50`** | **`wep.equip(HEAVY_SLOT)`** | **`wep.equip_type(int(HEAVY_SLOT))`** |
| `tests/snapshot_size_probe.gd:38`（**注释**） | `# _ready 跑完(weapons.equip("1") 等)再取 capture_state` | `# …(weapons.equip_type(1) 等)…`（注释引用已改名的符号等于把读者引向不存在的名字） |

★★ **第 9 处（`preview_visibility_probe.gd:50`）是本计划最容易漏的一处**：它的实参是个
**`String`**（`const HEAVY_SLOT := "3"`，该文件 `:21`），而 `wep = player.weapons`
（`:49`）⇒ 这是 `WeaponComponent.equip(String)`。改成 `equip_type(int)` 之后，
**照旧传 String 是运行时类型错**（`Cannot convert argument 1 from String to int`）⇒
`current_weapon()` 为 null ⇒ `PREVIEW VISIBILITY: FAIL(1 条)`（那行 `槽 %s 是 heavy_aim 武器`）。
★ 它**不在** Task 1 Step 6 的 13 符号闸门里（闸门查的是那 13 个名字，`equip` **不在列**
—— 正因为 `WeaponBase.equip` 同名，见下面那句），所以闸门**结构性地看不见它**。
**判据只有 Step 7 的回归跑得到它** —— 所以 `tests/preview_visibility_probe.gd` **必须**进
Step 7 的回归组（已列）。

★★ **绝对不许动**（这些是 `WeaponBase.equip`，接收者类型不同、签名是 `(Node2D, float)`）：
`tests/aim_direction_probe.gd:43`、`tests/enemy_logic_smoke.gd:294,376,428`、
`tests/kh_l3_probe.gd:430`、`tests/laser_team_probe.gd:162`。
**自查办法**（改完跑）。★ 这里是 `equip` **唯一的可行闸门** —— 13 符号闸门（Step 6）**看不见 `equip`**
（`WeaponBase.equip` 同名，不在那 13 个名字里）。排除名单必须**精确到行**：
只排除整文件会让 `enemy_logic_smoke.gd` 里那 **2 个真调用点**（:454/:460）被一起藏起来，
而它们正是要改的（早期版本就踩过这个 —— `kh_l3_probe:430` 这种写法**根本匹配不上**
`kh_l3_probe.gd:430`，整条排除静默失效）。

**改动前**它列出**恰好 10 行** = **9 个真调用点**（`player.gd:677`、`enemy_logic_smoke:454,460`、
`kh_l3_probe:177,182`、`menu_autotest:168,183,206`、`preview_visibility_probe:50`）
\+ `snapshot_size_probe:38` 的**注释**；**Task 1 Step 3 改完之后必须为空**：
```bash
grep -rn "\.equip(" --include=*.gd --exclude-dir=.claude --exclude-dir=_crashtest \
  --exclude-dir=.godot --exclude-dir=.superpowers --exclude-dir=docs scenes core server ui tests \
  | grep -vE "(aim_direction_probe\.gd:43|laser_team_probe\.gd:162|weapon_component\.gd:228|kh_l3_probe\.gd:430|enemy_logic_smoke\.gd:(294|376|428))"
```
Expected: **零输出**。★ 若还剩 `weapons.equip(` 一类 ⇒ 漏改；若是 `w.equip(stub)` /
`_weapon.equip(body, …)` ⇒ 那是 `WeaponBase.equip`，**别动它**（回到上表核接收者）。

- [ ] **Step 4: 参数名 / 循环变量 / 信号参数 / meta 键（`slot` 一词的最后一批落点）**

★ 这些是**局部名**，用 perl 会误伤（`slot_i` 之类），逐个手改：

| 文件:行 | 今天 | 改成 |
|---|---|---|
| `scenes/player/weapon_component.gd:42` | `signal weapon_changed(slot: int)` | `signal weapon_changed(type_id: int)` |
| `scenes/player/weapon_component.gd:83` | `func is_type_enabled(slot: int) -> bool:` | `func is_type_enabled(type_id: int) -> bool:` |
| `scenes/player/weapon_component.gd:84` | `return enabled_types.has(slot)` | `return enabled_types.has(type_id)` |
| `ui/hud.gd:306` | `func _on_weapon_changed(_slot: int) -> void:` | `func _on_weapon_changed(_type_id: int) -> void:` |
| `ui/weapon_slots.gd:57` | `func _on_changed(_slot: int) -> void:` | `func _on_changed(_type_id: int) -> void:` |
| `scenes/level_0.gd:504-507` | `for slot in [1, 2, 3, 4, 5, 6]:` + 3 处 `slot` | `for type_id in [1, 2, 3, 4, 5, 6]:` + 3 处 `type_id` |
| `server/match_ground.gd:33-36` | 同上 | 同上 |
| `scenes/lobby_page.gd:106-117` | `for slot: int in [...]` / `var slot_i := slot` + 6 处 `slot_i` | `for type_id: int in [...]` / `var type_i := type_id` + 6 处 `type_i`（注释同步）★ 那句"循环变量来自**字面量数组**"里的**理由**在本计划之后**仍然成立** —— 本计划不动那 5 处 `[1,2,3,4,5,6]` 硬编码（改成 `WeaponRegistry.all_ids()` 是 **§4.2 / 另一份计划**的事，届时那句注释才需要重写）。**别在这里顺手删它。** |
| `scenes/main_menu.gd:343-349` | `for slot in [...]` + 4 处 `slot` | `for type_id in [...]` + 4 处 `type_id` |
| `scenes/royale_lobby.gd:125` | `func(cell: Node, slot: int) -> void:` | `func(cell: Node, type_id: int) -> void:` |
| `scenes/royale_lobby.gd:128` | `cb.set_meta("slot", slot)` | `cb.set_meta("type_id", type_id)` |
| `scenes/royale_lobby.gd:220` | `cb.get_meta("slot", 0)` | `cb.get_meta("type_id", 0)` |
| `ui/weapon_icons.gd:14`（注释） | `纯白像素剪影缓存(slot → Texture2D)` | `(type_id → Texture2D)` |
| `ui/weapon_icons.gd:18-22,42` | `silhouette(slot: int)` + 4 处 `slot` | `silhouette(type_id: int)` + `type_id` |
| `ui/weapon_icons.gd:48` | `make_weapon_check(slot: int, checked: bool, font_size: int, on_toggle: Callable)` | `make_weapon_check(type_id: int, …)`（**后三个参数名与顺序不动**） |
| `ui/weapon_icons.gd:60` | `icon.texture = silhouette(slot)` | `icon.texture = silhouette(type_id)` |
| `scenes/player/player_replica.gd:198-202`（**三处注释**） | `slot == 0` / `slot > 0 and slot != ...` / `slot 变了` | `type_id == 0` / `type_id > 0 and type_id != ...` / `type_id 变了`（★ 它们描述的就是 `:203` 那个局部量 —— **改代码不改注释**等于把读者引向不存在的名字，而 Step 6 的 13 符号闸门**查不到**这里的 `slot`，只有这条清单管得住） |
| `scenes/player/player_replica.gd:203-205` | `var slot := int(data.get("weapon", 0))` / `if slot != _weapon_type_int:` / `_swap_weapon(slot)` | `var type_id := int(data.get("weapon", 0))` / `if type_id != _weapon_type_int:` / `_swap_weapon(type_id)`（`"weapon"` 这个**键**归 Task 3） |
| `scenes/player/player_replica.gd:233-238` | `func _swap_weapon(slot: int)` + 2 处 `slot` | `func _swap_weapon(type_id: int)` + `type_id` |
| `tests/team_bot_input.gd:148`（注释） | `get_weapon_slot_pressed()` | `get_switch_index_pressed()` |

★★ **明确保留 `slot` 一词的地方**（写进 Step 6 的白名单，**别去改**）：

- `Player.weapon_slot`（`player.gd:39`）+ `player.tscn:122,128` 的 `WeaponSlot` 节点 + 同族注释
  （`weapon_component.gd:4,215,216,227`）—— **这是"挂枪的挂点"**，spec §3 明文保留。
- `player_replica.gd:85,131,132,133,245` 的 `_weapon_slot_node` / `"WeaponSlot"` —— 同一件事（副本侧的挂点）。
- `ui/weapon_slots.gd` + `class_name WeaponSlots` + `ui/hud.gd` 的 `_slots` / `_build_weapon_slots` /
  `_place_weapon_slots` / `WEAPON_SLOTS_GAP` + `ui/ui_factory.gd` 的 `C_SLOT_EMPTY/FILLED/ACTIVE` +
  `ui/ui_factory.gd:158` 注释里的 `l3_slots_on_map` —— **容量格 UI 控件与它的配色**，与"哪把枪"无关。
- ★★ **`wslot`（`capture_state()` 的 c2 键 + 它的局部变量与注释）明确不改**：
  它是**第三条协议面**（本人包 `c2`），与 §4.1 改的两条（上行 / 下行世界包）不是同一条载荷；
  spec §3 自己那句"capture_state 的 `wslot` … 全按类型 id 走"把它排除在外。
  **登记为后续可选清查项**，本计划不碰。
  ★ **以 grep 为准，别抄下面这种行号清单**（CLAUDE.md 对同类"会漂的数"立过同样的规矩）：
  ```bash
  grep -rn "\bwslot\b" --include=*.gd --exclude-dir=.claude --exclude-dir=.godot \
    --exclude-dir=_crashtest --exclude-dir=.superpowers --exclude-dir=docs \
    scenes core server ui tests
  ```
  **这些命中全部保留**（生产端今天 28 行：`player.gd` 18 + `weapon_component.gd` 9 +
  `prediction_rollback.gd` 1；另加探针里所有 `{"wslot": …}` 夹具）。
  ★ **一处过渡态，两件事都对、别去"修"它**：`player.gd` 的 `_physics_process` 里有个**局部** `wslot`
  （今天 `:192,193,195,198`）—— 它是**上行**那条链的局部量，**Task 2 会把整段重写成 `idx`/`winst`**。
  所以 Task 1 之后它还在、Task 2 之后它就不在了 —— **Task 1 里别手改它**，
  Task 2 也不要去"保留"它。

- [ ] **Step 5: 菜单上的编号去掉（spec §3 末段）**

★ 两处的格式串**不一样**（核验报告 §E 已订正 spec 的引用）：

`scenes/main_menu.gd:345` 今天：
```gdscript
		cb.text = "%d. %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]]
```
改成：
```gdscript
		# ★ 不带编号:那个数字**看起来**是键位,而 type_id 与键位毫无关系(用户 2026-09-25 定)。
		cb.text = WeaponComponent.DISPLAY_NAMES[type_id]
```

`ui/weapon_icons.gd:68` 今天（**注意:无点号**）：
```gdscript
	var l := UiFactory.label("%d %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]], font_size)
```
改成：
```gdscript
	# ★ 不带编号(理由同上)。`font_size` 的**实参位置不动** —— kh_l4_probe 按下标 1 取它。
	var l := UiFactory.label(WeaponComponent.DISPLAY_NAMES[type_id], font_size)
```

★ **唯一合法的"数字 = 键位"仍是 HUD 左下角武器框的行首数字**（`ui/hud.gd:243` 的
`key_lbl.text = str(held_index + 1)`）—— 它指的就是背包位置，而背包位置就是键位。**不动它。**

- [ ] **Step 6: grep 闸门（本 Task 的主要判据）**

```bash
cd "$(git rev-parse --show-toplevel)"
for sym in _current_slot current_slot_int is_slot_enabled enabled_slots set_enabled_slots \
           default_slot cycle_slot get_weapon_slot_pressed _weapon_slot_raw _weapon_slot_int \
           slot_start used_slots SLOT_COST; do
  hits=$(grep -rn --include=*.gd --include=*.tscn "$sym" \
      --exclude-dir=.claude --exclude-dir=.godot --exclude-dir=_crashtest \
      --exclude-dir=.superpowers --exclude-dir=docs scenes core server ui tests || true)
  if [ -n "$hits" ]; then echo "STALE: $sym"; echo "$hits"; fi
done
echo "== 上面除 STALE 外不得有输出 =="
```
Expected: **逐符号零输出**（连注释里都不许残留 —— 注释引用已改名的符号等于把读者引向不存在的名字）。

★ **本 Task 刻意留活**：`push_net_slot` / `consume_net_slot` / `_net_slot` 三个名字**仍在**
（Task 2 连同语义一起改）。**别把它们加进上面的名单** —— 加了会红，而那是预期的。
Task 2 的 Step 6 会把这三个补进闸门。

- [ ] **Step 7: 回归 —— 与 Step 1 的基线逐条相同**

```bash
source tests/env.sh
for t in kh_l3_probe level0_weapon_scatter_probe weapon_pickup_probe ground_client_probe \
         ground_action_probe pvp_twin_smoke pvp_reconcile_smoke \
         preview_visibility_probe snapshot_size_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL|SMOKE_"
done
for t in weapon_inventory_smoke enemy_logic_smoke ai_input_source_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL"
done
```
Expected: 与 Step 1 基线**逐条相同**（外加 `GROUND CLIENT PROBE: ALL-OK` /
`GROUND ACTION PROBE: ALL-OK` / `SMOKE_TWIN OK: …` / `SMOKE_RECONCILE OK: …` /
**`PREVIEW VISIBILITY: ALL-OK`** / `SNAPSHOT SIZE PROBE: ALL-OK`）。
★ `preview_visibility_probe` 是本 Task **最可能红**的一条：它是 `equip` → `equip_type` 的
**第 9 个调用点**（`:50` 传的是 `String`），改错了**不报解析错、只在这条探针上红**。
★ 特别注意 `enemy_logic_smoke`（它读 `WeaponComponent` 的三张 const 表与 `WeaponInventory`
的类常量，**本 Task 一个都没动**，它必须原样全绿）。

★ 若某条探针**一行都不打印**：那是**解析/加载失败**（重命名漏了该文件里的某个符号），不是超时。
先按真失败查 —— 本仓踩过"批量里红、单跑绿"就断定超时的坑。

- [ ] **Step 8: 提交**

```bash
git add scenes/player/weapon_component.gd scenes/player/player.gd scenes/player/player_replica.gd \
        core/net/player_input.gd core/net/packet_input_source.gd core/net/local_input_source.gd \
        core/net/ai_input_source.gd core/sim/weapon_inventory.gd scenes/pvp_match_client.gd \
        scenes/level_0.gd scenes/lobby_page.gd scenes/main_menu.gd scenes/royale_lobby.gd \
        ui/weapon_icons.gd ui/hud.gd ui/weapon_slots.gd server/match_host.gd server/match_ground.gd \
        core/config/run_options.gd core/net/pvp_session.gd \
        tests/kh_l3_probe.gd tests/level0_weapon_scatter_probe.gd tests/ground_action_probe.gd \
        tests/ground_client_probe.gd tests/ground_net_watcher.gd tests/pvp_reconcile_smoke.gd \
        tests/pvp_twin_smoke.gd tests/snapshot_size_probe.gd tests/team_match_watcher.gd \
        tests/weapon_pickup_probe.gd tests/weapon_inventory_smoke.gd tests/ai_input_source_smoke.gd \
        tests/team_bot_input.gd tests/ground_bot_input.gd tests/soak_bot_input.gd \
        tests/royale_bound_watcher.gd tests/enemy_logic_smoke.gd tests/menu_autotest.gd \
        tests/preview_visibility_probe.gd
git commit -m "refactor(weapon): 词汇重命名 —— 三套 slot 收敛为 type_id / inst / index；菜单去掉假的键位编号"
```

---

### Task 2: 上行传 `inst`（§4.1）—— 两端 `held` 反序也必须切到同一把

**Files:**
- Create: `tests/weapon_switch_inst_probe.gd`、`tests/weapon_switch_inst_probe.tscn`
- Modify: `scenes/player/weapon_component.gd`、`scenes/player/player.gd`、`core/net/player_input.gd`、
  `core/net/packet_input_source.gd`、`scenes/pvp_match_client.gd`
- Modify（夹具）: `tests/network_input_smoke.gd`、`tests/move_feel_smoke.gd`、`tests/pvp_match_smoke.gd`、
  `tests/pvp_reconcile_smoke.gd`、`tests/pvp_twin_smoke.gd`、`tests/ammo_rollback_probe.gd`、
  `tests/brawl_rollback_probe.gd`、`tests/ground_action_probe.gd`、`tests/kh_l3_probe.gd`、
  `tests/laser_team_probe.gd`、`tests/rollback_fidelity_probe.gd`、`tests/squash_host_water_probe.gd`、
  `tests/replica_ghost_probe.gd`、`tests/reconnect_watcher.gd`
- Modify（**被反证的守卫**）: `tests/net_ground_probe.gd`、`tests/ground_client_probe.gd`

**Interfaces:**
- Consumes: Task 1 的 `cycle_index()` / `get_switch_index_pressed()` / `_switch_index_raw()` / `equip_index()`。
- Produces:
  - `WeaponComponent.inst_at_index(index: int) -> int`（0-based；越界 0）
  - `WeaponComponent.equip_inst(inst: int) -> void`（找不到**静默不动**）
  - `WeaponComponent.push_switch_inst(inst: int) -> void` / `consume_switch_inst() -> int`
    （**取代** `push_net_slot(slot)` / `consume_net_slot()`；`_net_slot` → `_switch_inst`）
  - `WeaponComponent.take_uplink_switch(key_index: int) -> int`
  - `PlayerInput.consume_switch_inst() -> int`（公开读口，frozen 短路）+ `_switch_inst_raw() -> int`（可选钩子，默认 0）
  - 上行包键 `"winst"`（`"weapon"` **删除**）

★ **红绿分界 = 相① 的源码级断言**（九条里**八条今天红**，逐条点名见 Step 3）
\+ **相② 的单行变异反证**（Step 5）。
相① 负责把"新 API 还不存在"变成**具名红**；相② 负责证明它**确实在修那个分歧**
（只靠相① 的话，把新 API 全都加上但**接错了**——比如上行仍推位置——它会全绿）。

- [ ] **Step 1: 写新探针**

创建 `tests/weapon_switch_inst_probe.gd`：

```gdscript
extends ProbeBase

# 武器命名纪律 + **上行传 inst** 的守卫(§4.1)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_switch_inst_probe.tscn
# 判据:文本 `KH weapon-inst PROBE: ALL-OK`(grep 文本,**不看退出码**)。
#
# ═══ 本探针要守的那件事 ═══
# 上行包**曾**带"背包位置(1-based)",服务器用**它自己的** held 数组解(`equip_index(wslot - 1)`)。
# 拾取/丢弃是服务器裁决、客户端不预测 ⇒ 那 ≈1 RTT 的窗口里同一个下标在两端解出**不同的枪**
# ——「切不动 / 切到另一把」的结构性来源。改成上行 **inst**(逐把唯一)之后,两端 held 的**顺序**
# 不再是前提。
#
# ═══ 为什么相② 要写 `has_method` + `Object.call()` ═══
# 新 API(`take_uplink_switch` / `equip_inst` / `inst_at_index` / `push_switch_inst` /
# `PlayerInput.consume_switch_inst`)在改动前**不存在**。
# 若在**带类型标注**的变量上直接调它们,整份脚本是 **Parse Error** —— 那意味着本探针
# **一行都不打印**(判据 grep 不到 = 红,但红的形状是"跑不起来"而不是"断言失败",读者看不出是哪一件事)。
# 故:① 相① 用**源码级断言**把"新 API 还没实现"变成**具名红**;
#     ② 相②/③/④ 一律走 `Object.call("…")`(**动态派发,不需要符号存在**)+ `has_method` 守卫,
#        守卫缺失时记一条**具名失败**并跳过解引用(绝不静默 return)。
#     ③ 每个带守卫的相最后留**完成戳**(`_require_ran`,照 `tests/rollback_fidelity_probe.gd` 的先例):
#        守卫哪天被写成静默 `return`,整相消失而 verdict 照打 ALL-OK —— 那是本仓抓过的假绿形状。

func probe_id() -> String:
	return "weapon-inst"


# 带守卫的相的完成戳:没跑到最后一行 ⇒ 本趟读数不可信。
var _ran: Dictionary = {}


func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_check(false, "%s 没跑到最后一行(被跳过或中途报错)→ 本趟读数不可信" % name)


# 某个玩家手上那把的 **inst**;空手/越界返回 -1(与 type_id 区分开:同型号两把 type_id 恒等)。
func _inst_of(p: Node2D) -> int:
	var w = p.weapons
	var i: int = w._current_index
	if i < 0 or i >= w.inventory.held.size():
		return -1
	return int(w.inventory.held[i]["inst"])


# 合成平地:本探针只验"切枪解析成哪一把",不需要任何关卡几何。
const COLS := 40
const ROWS := 12


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(31 if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _ready() -> void:
	# ★ 必须 `await _run()` 再 `_finish()`(与 `laser_team_probe` 同款,**只此一处** `_finish()`)。
	#   为什么不能写成 `_run(); _finish()`:`_run()` 是个协程,同步调它会在它**第一个 await
	#   处**就返回(`_run` 尾部那三帧等待),于是 `quit()` 排在等待**之前** —— 那三帧就不等了,
	#   `call_deferred("add_child")` 入树的武器可能连同玩家一起被计成退出期泄漏
	#   (`N ObjectDB instances / 1 RID leaked`,实测踩过)。断言本身不受影响,受影响的只是收尾。
	await _run()
	_finish()


func _run() -> void:
	_phase_source_contract()
	_phase_opposite_order()
	_require_ran("opposite_order")
	_phase_missing_inst()
	_require_ran("missing_inst")
	_phase_index_resolution()
	_require_ran("index_resolution")
	# ★ 收尾等几帧:见 `_ready()` 的注释。★ **这里不调 `_finish()`** —— 它归 `_ready()`,
	#   两处都调会把 verdict 打两遍(初稿就是两处都调,被评审照出来)。
	for i in 3:
		await get_tree().physics_frame


# ── 相① 源码级:协议与解析点的形状(★ 改动前**逐条红**)──
func _phase_source_contract() -> void:
	var before := _failures.size()
	var wc := _code_only(_read("res://scenes/player/weapon_component.gd"))
	var pl := _code_only(_read("res://scenes/player/player.gd"))
	var pis := _code_only(_read("res://core/net/packet_input_source.gd"))
	var pmc := _code_only(_read("res://scenes/pvp_match_client.gd"))

	var rnc := _func_body(wc, "request_net_cycle")
	_check(not rnc.is_empty(), "request_net_cycle 找得到")
	# ★ 这条**接管**了 net_ground_probe ④c 原先那条(它断言的是 `push_net_slot(next + 1)` —— 被本 Task 反证)。
	_check(rnc.contains("push_switch_inst(inst_at_index(next))"),
			"滚轮待发值不是**目标那把的 inst** —— 传背包位置会让两端 held 顺序不同时切到不同的枪")

	_check(pis.contains("\"winst\":"),
			"pack_record 没产出 winst 键(上行传的还是寻址方式,不是解析结果)")
	_check(not pis.contains("\"weapon\":"),
			"pack_record 还在产出旧键 \"weapon\" —— 同名不同义正是本设计要消灭的东西")

	var pmcp := _func_body(pmc, "_physics_process")
	_check(pmcp.contains("take_uplink_switch("),
			"客户端组包没走 take_uplink_switch —— 数字键那条上行的还是背包位置")
	_check(pmcp.contains("pkt[\"winst\"]"), "客户端组包没把 winst 塞进输入包")

	var plp := _func_body(pl, "_physics_process")
	_check(plp.contains("consume_switch_inst()"),
			"player.gd 没读 input_source.consume_switch_inst() —— 上行 inst 没人消费")
	_check(plp.contains("equip_inst(winst)"), "player.gd 没按 inst 切枪")
	# ★ 与 net_ground_probe:144 那条**同一个字符串、方向相反** —— 本 Task 把那条改写掉,这一条接管。
	_check(not plp.contains("equip_index(wslot - 1)"),
			"player.gd 还在按**背包位置**解上行值 —— 两端 held 顺序不同时会切到不同的枪")
	_summary(before, "相① 协议与解析点的形状")


# ── 相② 两端 held 顺序相反 → 按同一个键必须切到同一把 ──
# 构造(与 spec §7 判据 2 同款,但走的是**真生产函数**而不是手搓的算术):
#   客户端 held = [重狙 inst=2, 手枪 inst=1]   ← 与服务器**反序**
#   服务器 held = [手枪 inst=1, 重狙 inst=2]
# 两边都从位置 0 起手 ⇒ **两端一开始拿的就是不同的枪**(本身就是那条 bug 的现场)。
func _phase_opposite_order() -> void:
	var before := _failures.size()
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	GameParameters.refresh_map_size()
	# ★ 两个真 player.tscn:一端当客户端(LocalInputSource)、一端当服务器(PacketInputSource)。
	#   `_equip_index` 需要 `body.weapon_slot` 非空 —— 只有真 player.tscn 有那个挂点。
	var p_c: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p_c.set_input_source(LocalInputSource.new())
	add_child(p_c)
	var p_s: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p_s.set_input_source(PacketInputSource.new())
	add_child(p_s)
	p_c.weapons.set_enabled_types([])
	p_s.weapons.set_enabled_types([])
	# want_inst 传 0 ⇒ 走"按类型兜底",两端都会落到空手;随后各自 equip_index(0) 摆成既定状态。
	p_c.weapons.restore_inventory([
			{"type": 3, "inst": 2, "mag": -1},
			{"type": 1, "inst": 1, "mag": -1}], 0)
	p_s.weapons.restore_inventory([
			{"type": 1, "inst": 1, "mag": -1},
			{"type": 3, "inst": 2, "mag": -1}], 0)
	p_c.weapons.equip_index(0)      # 客户端手上 = 位置 0 = 重狙 inst 2
	p_s.weapons.equip_index(0)      # 服务器手上 = 位置 0 = 手枪 inst 1
	_check(_inst_of(p_c) == 2 and _inst_of(p_s) == 1,
			"前置:两端起手必须是**不同的枪**(客户端 inst=%d、服务器 inst=%d)" % [_inst_of(p_c), _inst_of(p_s)])

	# ── 对照组:旧语义(上行"背包位置"、服务器按位置解)⇒ 两端分家 ──
	# ★ 这是一条**特征化**断言(它断言的是"分歧确实存在",故恒真、不红不绿)。它存在的唯一
	#   理由是证明相② 不是恒真的:同一对背包、同一个键,只换解的量纲就**分家**。
	# ★ 必须**完整走一遍旧链路**,不能只改服务器那一步 —— 旧链路里客户端**也**本地切了
	#   (同一次按键),所以上行的"位置 2"对应客户端的**位置 1**(手枪 inst 1),
	#   而服务器的位置 1 是**另一把**(重狙 inst 2)。只改服务器那一步会得出"两端相等"
	#   (两端都落在 inst 2),那条断言会红 —— 而它红得没有意义(是探针写错了,不是发现了 bug)。
	p_c.weapons.equip_index(1)        # 旧链路:客户端本地切到**它的**位置 1 → 手枪 inst 1
	_check(_inst_of(p_c) == 1, "对照组:客户端本地切到 inst=1(实际 %d)" % _inst_of(p_c))
	p_s.weapons.equip_index(2 - 1)    # 旧消费端:服务器按**它自己的**位置解 key_index - 1 → 位置 1
	_check(_inst_of(p_s) != _inst_of(p_c),
			"对照组:按位置解时两端**不同把**(客户端 %d / 服务器 %d)—— 这正是要修的分歧"
					% [_inst_of(p_c), _inst_of(p_s)])

	# ── 新语义:客户端本地解析成 inst → 过真 PacketInputSource → 服务器按 inst 解 ──
	var missing: Array[String] = []
	for m in ["take_uplink_switch", "equip_inst", "inst_at_index", "push_switch_inst"]:
		if not p_c.weapons.has_method(m):
			missing.append(m)
	if not p_s.input_source.has_method("consume_switch_inst"):
		missing.append("PlayerInput.consume_switch_inst")
	if not missing.is_empty():
		_check(false, "§4.1 的落点还没实现,相② 无法执行:缺 %s" % str(missing))
		_ran["opposite_order"] = true
		return

	# 1) 客户端滚轮:走**生产函数** `request_net_cycle` —— 它一次做完两件事:
	#    本地立即切(`_equip_index`)+ 把**目标那一把的 inst** 记进待发槽(`push_switch_inst`)。
	#    ★★ 必须用 `request_net_cycle`,**不能**用 `cycle_index` —— 后者是**单机**那条路
	#       (`weapon_component.gd:116-122`),只做 `_peek_cycle` + `_equip_index`,**从不 push**;
	#       用它的话 `take_uplink_switch` 恒读到 0,这一相**永远绿不了**。
	#       PvP 与单机的分叉在 `player.gd` 的滚轮分支(`Level0.pvp_mode` → `request_net_cycle`)。
	p_s.weapons.equip_index(0)        # 把两端都摆回位置 0 再走一遍
	p_c.weapons.equip_index(0)
	p_c.weapons.request_net_cycle(1)  # 位置 0 → 位置 1(客户端的位置 1 = 手枪 inst 1)
	_check(_inst_of(p_c) == 1, "客户端本地已切到 inst=1(实际 %d)" % _inst_of(p_c))
	var uplink: int = int(p_c.weapons.call("take_uplink_switch", 0))
	_check(uplink == 1, "上行必须是**目标那把的 inst**(=1),实际 %d" % uplink)

	# 2) 过真解码端:组包 → apply_packet → 服务器取走(与生产同款;`clear_edges` 走 `MatchHost` 的口径)
	# ★ 显式标 Variant:`input_source` 是从 Node2D 上取的不安全访问,标了具体类型会让
	#   `clear_edges()` / `apply_packet()` 变成静态检查(它们不在 `PlayerInput` 上)。
	var srv_src: Variant = p_s.input_source
	srv_src.clear_edges()
	srv_src.apply_packet({"seq": 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
			"winst": uplink, "aim": Vector2.RIGHT})
	var winst: int = int(srv_src.call("consume_switch_inst"))
	_check(winst == 1, "服务器从包里取出的 winst 应为 1(实际 %d)" % winst)
	_check(int(srv_src.call("get_switch_index_pressed")) == 0,
			"网络输入源的**位置**读口必须恒 0(包里的值不是位置)")
	if winst > 0:
		p_s.weapons.call("equip_inst", winst)
	_check(_inst_of(p_s) == _inst_of(p_c),
			"★ 两端 held **顺序相反**时,按同一个键必须切到**同一把**(客户端 inst=%d、服务器 inst=%d)"
					% [_inst_of(p_c), _inst_of(p_s)])
	_ran["opposite_order"] = true
	_summary(before, "相② 两端反序 → 同一把")


# ── 相③ 服务器手里没有那把 ⇒ **静默不动**,不切到别的枪 ──
func _phase_missing_inst() -> void:
	var before := _failures.size()
	var p_s: Node2D = _players_server_side()
	if p_s == null or not p_s.weapons.has_method("equip_inst"):
		_check(false, "相③ 需要相② 建好的服务器侧玩家(或 equip_inst 缺失)")
		_ran["missing_inst"] = true
		return
	var t_before: int = p_s.weapons.current_type_id()
	var i_before := _inst_of(p_s)
	p_s.weapons.call("equip_inst", 999)
	_check(_inst_of(p_s) == i_before and p_s.weapons.current_type_id() == t_before,
			"服务器找不到该 inst 时必须**静默不动**(实测 inst %d → %d)" % [i_before, _inst_of(p_s)])
	p_s.weapons.call("equip_inst", 0)
	_check(_inst_of(p_s) == i_before, "equip_inst(0) 也必须不动(0 = 无请求)")
	_ran["missing_inst"] = true
	_summary(before, "相③ 找不到就不动")


# ── 相④ 数字键那条:1-based 背包位置 → 那一把的 inst ──
func _phase_index_resolution() -> void:
	var before := _failures.size()
	var p_c: Node2D = _players_client_side()
	if p_c == null or not p_c.weapons.has_method("inst_at_index"):
		_check(false, "相④ 需要相② 建好的客户端侧玩家(或 inst_at_index 缺失)")
		_ran["index_resolution"] = true
		return
	_check(int(p_c.weapons.call("inst_at_index", 0)) == 2,
			"位置 0 的 inst 应为 2(实际 %d)" % int(p_c.weapons.call("inst_at_index", 0)))
	_check(int(p_c.weapons.call("inst_at_index", 1)) == 1,
			"位置 1 的 inst 应为 1(实际 %d)" % int(p_c.weapons.call("inst_at_index", 1)))
	_check(int(p_c.weapons.call("inst_at_index", 9)) == 0,
			"越界位置必须返回 0(实际 %d)" % int(p_c.weapons.call("inst_at_index", 9)))
	# 数字键"2"(1-based) ⇒ 位置 1 ⇒ inst 1;且**必须把滚轮的待发值一起取走**(读一次即清,
	# 免得它漏到下一帧变成一次迟到的切枪 —— 与旧 consume_net_slot 同款)。
	p_c.weapons.call("push_switch_inst", 2)
	_check(int(p_c.weapons.call("take_uplink_switch", 2)) == 1,
			"数字键 2 应解析成位置 1 的 inst(=1)")
	_check(int(p_c.weapons.call("take_uplink_switch", 0)) == 0,
			"滚轮的待发值必须已被取走(第二问读到 %d,应为 0)" % int(p_c.weapons.call("take_uplink_switch", 0)))
	_ran["index_resolution"] = true
	_summary(before, "相④ 数字键按位置解析成 inst")


# 相② 建的两位端玩家(位置固定:先 client 后 server)。
func _players_client_side() -> Node2D:
	for c in get_children():
		if c is Node2D and c.has_method("set_input_source") and c.input_source is LocalInputSource:
			return c
	return null


func _players_server_side() -> Node2D:
	for c in get_children():
		if c is Node2D and c.has_method("set_input_source") and c.input_source is PacketInputSource:
			return c
	return null
```

- [ ] **Step 2: 建场景**

创建 `tests/weapon_switch_inst_probe.tscn`（与 `tests/net_ground_probe.tscn` 同构，只改名字与脚本路径）。
★ **`uid=` 刻意不写**：新场景由 Godot 自己在首次导入时分配并回写 —— 手写一个 uid 有撞号/格式风险，
不写则必然正确（导入后 `git status` 会多出 `.tscn.uid` 与 `.gd.uid`，**一并 `git add`**）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/weapon_switch_inst_probe.gd" id="1_p"]

[node name="WeaponSwitchInstProbe" type="Node"]
script = ExtResource("1_p")
```

- [ ] **Step 3: 跑 —— 确认相① 今天**逐条红**（这是本 Task 的红绿分界）**

★ 首次跑新探针前可先 `"$GODOT" --headless --path . --import`（生成 `.uid`，本仓新场景的常规动作）；
本计划**没有新建 `class_name`**，故不需要为类缓存额外做什么。

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 \
  res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|FAIL|✗|Script Error|Parse Error"
```
Expected（改动前）:
```
KH weapon-inst PROBE: FAIL | ...pack_record 没产出 winst 键...; ...player.gd 没读 input_source.consume_switch_inst()...; ...player.gd 还在按**背包位置**解上行值...; ...
```
★ 判读规则（三条，别跳）：
- 红里**必须**同时出现这八条（相① 的九条断言里，只有"`request_net_cycle` 找得到"今天就是绿的）：
  ① `滚轮待发值不是**目标那把的 inst**…`；② `pack_record 没产出 winst 键…`；
  ③ `pack_record 还在产出旧键 "weapon"…`；④ `客户端组包没走 take_uplink_switch…`；
  ⑤ `客户端组包没把 winst 塞进输入包`；⑥ `player.gd 没读 input_source.consume_switch_inst()…`；
  ⑦ `player.gd 没按 inst 切枪`；⑧ `player.gd 还在按**背包位置**解上行值…`。
  少一条说明相① 没跑完（回到 Step 1 查）。
  ★ 逐条核过今天的源码，这八条都对得上现在的事实
  （`weapon_component.gd:157` 是 `push_net_slot(next + 1)`、`packet_input_source.gd:85` 是 `"weapon": …`、
  `pvp_match_client.gd:200-204` 无 `take_uplink_switch`、`player.gd:192-198` 是 `equip_index(wslot - 1)`）。
- 相②/③/④ 的 `§4.1 的落点还没实现…` 是**预期**的具名失败。
- 若**一行都不打印**（连 `PROBE:` 都没有）⇒ 本文件**加载失败**了（几乎只能是 `Object.call` 写错成
  了静态调用）—— 先修探针，**别**继续。

- [ ] **Step 4: 改生产代码**

**(a) `scenes/player/weapon_component.gd`**

把 `push_net_slot` / `consume_net_slot` / `_net_slot` 整段（今天 :142-169）换成：

```gdscript
# ── PvP 切枪:本地立即切(即时反馈),再把**目标那一把的 inst** 打包进输入包由服务器权威同步 ──
# (滚轮事件不在输入包协议里,只本地切会被快照的防脱同步切回旧槽位 →「只有音效」)
# ★★ 上行的是 **inst**,不是背包位置 —— 这是本设计最要紧的一处(§4.1):
#   "第 N 把"的含义由**本端背包**决定,而拾取/丢弃是服务器裁决、客户端**不预测**;
#   那 ≈1 RTT 的窗口里,同一个下标在两端解出**不同的枪**(滚轮切不动 / 切到另一把的结构性来源)。
#   `inst` 逐把唯一,与两端 `held` 的**顺序**无关。
#   历史代价(留档):这里曾经发 `inventory.held[next]["type"]`(类型id)、而消费端按位置读 ——
#   背包 `[步枪2, 手枪1]` 从步枪滚一下发 1 → 服务器切回步枪(等于没切);`[手枪1, 重狙3]` 发 3
#   → 越界早退(压根没切)。两条都只表现为「滚轮切不动」,而代码里没有任何一处会红。
var _switch_inst := 0   # 待发切枪的目标 **inst**(>0 = 待发,打包后清零)

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	push_switch_inst(inst_at_index(next))
	_equip_index(next)


# 入参 = 目标那一把的 **inst**;由 `pvp_match_client` 的组包处取走塞进输入包的 winst 字段。
func push_switch_inst(inst: int) -> void:
	_switch_inst = inst


func consume_switch_inst() -> int:
	var v := _switch_inst
	_switch_inst = 0
	return v


# 客户端上行前把"玩家想切到**哪一把**"解析成 inst(§4.1:上行传解析结果,不传寻址方式)。
# 两条来源都是**本地交互**,只有客户端知道玩家点的是第几个:
#   · 数字键 → `key_index`(1-based 背包位置)→ 查那一把的 inst
#   · 滚轮   → `request_net_cycle` 已本地切好并 push_switch_inst(目标 inst)
# 数字键优先;滚轮那条无论如何**都取走**(读一次即清 —— 别让它漏到下一帧变成一次迟到的切枪)。
# 返回 0 = 本次没有切枪请求。
func take_uplink_switch(key_index: int) -> int:
	var wheel_inst := consume_switch_inst()
	if key_index > 0:
		var inst := inst_at_index(key_index - 1)
		if inst > 0:
			return inst
	return wheel_inst


# 第 index 条(0-based)的 inst;越界返回 0。数字键上行解析用。
func inst_at_index(index: int) -> int:
	if index < 0 or index >= inventory.held.size():
		return 0
	return int(inventory.held[index]["inst"])
```

并把 `current_inst()`（今天 :441-444）改成走同一个来源：

```gdscript
func current_inst() -> int:
	return inst_at_index(_current_index)
```

把 `equip`（Task 1 已改名 `equip_type`）**之后**新增：

```gdscript
# 按 **inst** 切枪(网络上行 / 权威落点走这条)。
# ★ 找不到那把时**静默不动** —— 语义比"下标越界"准确:`inst` 逐把唯一,服务器手里没有它
#   只可能是那一把已经不在了(被丢/被换),此时切到别的枪是**错的**。
#   (旧路径 `equip_index(wslot - 1)` 在那种情况下会越界早退,或更糟:切到位置上的另一把。)
func equip_inst(inst: int) -> void:
	if inst <= 0:
		return
	var idx := inventory.index_of_inst(inst)
	if idx < 0:
		return
	_equip_index(idx)
```

**(b) `core/net/player_input.gd`**

`get_switch_index_pressed()`（Task 1 已改名）改为调 `_switch_index_raw()`（已改）；并在 `is_drop_pressed()` 之后加：

```gdscript
# 本帧上行包里的**权威切枪目标**(inst)。只有 `PacketInputSource` 覆写 `_switch_inst_raw()`
# (它读包里的 winst);本地 / AI / 机器人输入源**一律不覆写** —— 它们那次切枪由
# `get_switch_index_pressed()` 那条**本地路径**直接成交,不经网络。
# ★ 与 `get_aim_dir_override()` 同款:**默认空操作**的可选钩子(不是"必须覆写"那族)。
# ★ `frozen` 短路照旧收在公开读口 —— 冻结期一切输入读口返回中性值,这条不能例外
#   (子类覆写的是 `_*_raw()`,绕不过冻结)。
func consume_switch_inst() -> int:
	if frozen:
		return 0
	return _switch_inst_raw()
```

并在 `_weapon_slot_raw` 那一段（Task 1 已改名 `_switch_index_raw`）之后加：

```gdscript
# 可选钩子:默认 0 = "本次上行没有切枪目标"。见 `consume_switch_inst()`。
func _switch_inst_raw() -> int:
	return 0
```

**(c) `core/net/packet_input_source.gd`**

`pack_record` 的返回字典（今天 :79-87）里，把那行 `"weapon": …` 换成：

```gdscript
		# ★ 上行键 = winst,值是**目标那一把的 inst**。旧的 `"weapon"` 键**已删除** ——
		#   它带的是背包位置(1-based),而位置的含义由**本端背包**决定(见 weapon_component
		#   的 request_net_cycle 注释)。本函数是**编码端唯一来源**,故 inst 在这里是**空的**:
		#   `pack_record` 只拿得到 `PlayerInput`、拿不到背包 —— 解析由组包处补上
		#   (`pvp_match_client` 的 `weapons.take_uplink_switch(src.get_switch_index_pressed())`)。
```

并把 `"weapon"` 那一行**整行删掉**（不是改成别的）。`pack_record` 的签名与其它键**一律不动**。

`_weapon` 字段（今天 :92）与它的**四处**使用改为 `_switch_inst` —— 逐处核过：
`apply_packet`（:106-108 读键 + 赋值）、`clear_edges`（:116）、`reset_state`（:125）、
`_switch_index_raw`（:168 的 `return _weapon`）。**四处一处都不能漏**：

```gdscript
var _switch_inst := 0      # 上行包里的权威切枪目标(**inst**);>0 = 本次有切枪请求
```

`apply_packet`（今天 :102-110；**上面那条"新包到达…"的文档注释原样保留**，只改体内）：
```gdscript
func apply_packet(pkt: Dictionary) -> void:
	_axis = pkt.get("ax", 0.0)
	_held = pkt.get("held", 0)
	_aim = pkt.get("aim", Vector2.ZERO)
	# 与旧 `_weapon` 同款语义:>0 才覆盖(0 = 本包没有切枪请求),由 clear_edges() 清空。
	var inst: int = pkt.get("winst", 0)
	if inst > 0:
		_switch_inst = inst
	_pressed |= pkt.get("pressed", 0)
	_released |= pkt.get("released", 0)
```

`clear_edges`（今天 :113-116）：
```gdscript
func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_switch_inst = 0
```

`reset_state`（今天 :121-127）：把 `_weapon = 0` 换成 `_switch_inst = 0`。

`_weapon_slot_raw`（Task 1 已改名 `_switch_index_raw`，今天 :167-168）整体换成：
```gdscript
# ★ 网络输入源**没有"背包位置"这个量**(上行传的是 inst)⇒ 位置读口恒 0。
#   服务器取切枪目标走 `_switch_inst_raw()`(见 `PlayerInput.consume_switch_inst`)。
func _switch_index_raw() -> int:
	return 0


func _switch_inst_raw() -> int:
	return _switch_inst
```

**(d) `scenes/player/player.gd`** — `_physics_process` 的切枪段（今天 :191-198）整段替换：

```gdscript
	# 切枪走 input_source 轮询,两条**不同量纲**的路,别合并:
	#   ① 本地交互(本地输入源):数字键 = 本端背包的**第 N 把**(1-based)→ 就地按位置切。
	#      网络输入源这条恒 0(它的上行值不是位置)。
	#   ② 权威切枪(网络输入源):上一包带的目标 **inst** → 按 inst 找到那一把再切。
	#      本地输入源这条恒 0(它那次切枪已由 ① 当场成交)。
	# ★ 为什么上行必须是 inst:位置的含义由**本端背包**决定,而拾取/丢弃是服务器裁决、
	#   客户端不预测 —— 那 ≈1 RTT 的窗口里同一个下标在两端解出**不同的枪**(见 spec §4.1)。
	var idx := input_source.get_switch_index_pressed()
	if idx > 0:
		weapons.equip_index(idx - 1)
	var winst := input_source.consume_switch_inst()
	if winst > 0:
		weapons.equip_inst(winst)
```

**(e) `scenes/pvp_match_client.gd`** — 组包段（今天 :201-204）替换：

```gdscript
	# 滚轮/数字键切枪:**本地解析成目标那把的 inst** 再随输入包上行(§4.1)。
	# ★ 位置不能过网 —— 两端 held 的顺序可能不同(拾取/丢弃只由服务器裁决),
	#   同一下标会解出不同的枪。数字键按背包位置解、滚轮取已本地切好的那把。
	var switch_inst: int = _local.weapons.take_uplink_switch(src.get_switch_index_pressed())
	if switch_inst > 0:
		pkt["winst"] = switch_inst
```

- [ ] **Step 5: 反证（单行变异，证相② 不是恒真）**

把 `weapon_component.gd` 的 `request_net_cycle` 里那一行

```gdscript
	push_switch_inst(inst_at_index(next))
```
改成（即"上行传的是**背包位置**"这一句回来了）：
```gdscript
	push_switch_inst(next + 1)
```

★ **变异点必须落在 `request_net_cycle`，不能落在 `take_uplink_switch`**：相② 走的是**滚轮**
（`take_uplink_switch(0)` 的 `key_index` = 0），`take_uplink_switch` 里那个
`if key_index > 0:` 分支**根本进不去** —— 在它身上做变异是个**空操作**，不会有任何 ✗。

跑：

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 \
  res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|✗"
```
Expected: 相② 的**三条** **✗** ——
① `上行必须是**目标那把的 inst**(=1)`（实得 **2**）；
② `服务器从包里取出的 winst 应为 1`（实得 **2**）；
③ `★ 两端 held **顺序相反**时,按同一个键必须切到**同一把**`（客户端 inst=**1**、服务器 inst=**2**）；
相①/③/④ 仍绿。

★ 为什么这一行就够、且夹具**确实到得了**那个状态：客户端 `held = [重狙(inst 2), 手枪(inst 1)]`、
服务器 `held = [手枪(inst 1), 重狙(inst 2)]`（探针里显式摆的反序，前置断言钉住"起手就是不同的枪"）。
`request_net_cycle(1)` 本地切到**客户端的位置 1 = 手枪 inst 1**；变异的推送值 `next + 1 = 2` 是
**服务器背包的位置号**，服务器 `index_of_inst(2)` 落回**它自己的位置 1 = 重狙 inst 2** ——
正是"同一个下标在两端解出不同的枪"本身。
确认后**改回来**。

- [ ] **Step 6: 跑 —— 确认全绿**

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 \
  res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|✗|✓"
```
Expected: 每条 `✓`，末行 `KH weapon-inst PROBE: ALL-OK`。

- [ ] **Step 7: 改写两条**被 §4.1 反证**的守卫**

**(a) `tests/net_ground_probe.gd`** —— 今天 :133-145 的 ④c（源码级）：

```gdscript
	# ④c 切枪：上行传**目标那一把的 inst**（§4.1，2026-09-25 换）。
	#     ★ 这条**取代**了原先那句"滚轮应上行背包位置（next + 1）" —— 位置不能过网：
	#       拾取/丢弃是服务器裁决、客户端不预测，那 ≈1 RTT 的窗口里同一个下标在两端解出
	#       **不同的枪**（历史症状：滚轮切不动 / 切到另一把，代码里没有任何一处会红）。
	#     ★ 端到端守卫在 `tests/weapon_switch_inst_probe.tscn`（真两端、真解码端）；
	#       这里只钉**源码形状**，与它分工。
	var wc := _code_only(_read("res://scenes/player/weapon_component.gd"))
	var rnc := _func_body(wc, "request_net_cycle")
	_check(not rnc.is_empty(), "request_net_cycle 找得到")
	_check(rnc.contains("push_switch_inst(inst_at_index(next))"),
			"滚轮切枪上行不是目标那把的 inst —— 传背包位置会让两端 held 顺序不同时切到不同的枪")
	_check(_func_body(pl, "_physics_process").contains("equip_inst(winst)"),
			"消费端没按 inst 切（equip_inst(winst)）—— 上行值没人解")
	_check(not _func_body(pl, "_physics_process").contains("equip_index(wslot - 1)"),
			"消费端又按**背包位置**解上行值了 —— 两端 held 顺序不同时切到不同的枪")
```

**(b) `tests/ground_client_probe.gd`** —— 今天 :247-274 的 ⑥（行为级）整体替换：

```gdscript
# ── ⑥ 切枪包的上行值 = **目标那一把的 inst**（§4.1，2026-09-25 换）──
# ★ 这一相**整段改写了**：原先断的是"上行值 = 背包位置，且**不得**是 type id"。
#   那条契约已被 §4.1 反证 —— 新的契约是：上行的是**目标那把的 inst**，与两端 `held` 的**顺序无关**。
# 为什么必须换：位置的含义由**本端**背包决定，而拾取/丢弃是服务器裁决、客户端不预测
# ——那 ≈1 RTT 的窗口里同一个下标在两端解出不同的枪。历史症状是「滚轮切不动」（见 ④c 的注释）。
# ★ 选 `[3, 1]`（重狙 / 手枪）：**类型 id 与背包位置不同**，能把两者区分开；`[1, 2]` 那种
#   恰好相等，测了也白测（红绿一样）。而 inst 与两者都不同，故三条量纲互相可分。
func _phase_switch_field_contract() -> void:
	print("[gc] ── ⑥ 切枪包上行值 = 目标那把的 inst ──")
	var w: WeaponComponent = _local.weapons
	w.set_initial_inventory([3, 1])   # 位置 0 = 重狙(类型 3)、位置 1 = 手枪(类型 1)
	var inst1 := int(w.inventory.held[1]["inst"])
	# ★ 前置:目标那把的 inst 必须与"位置"(1)和"类型 id"(3)**都不同**,否则下面两条
	#   鉴别断言恒真。inst 由 WeaponInventory 的 `_next_inst` **单调分配、跨相累积**
	#   (本文件前面的相已经把计数器顶到 ~160),不会小到撞上 1/3 —— 但**别靠"不会"**,
	#   把前提变成一条断言,撞上了就让探针如实红。
	_check(inst1 != 1 and inst1 != 3,
			"前置:目标那把的 inst(%d)必须与位置(1)和类型 id(3)都不同,否则鉴别断言是空转" % inst1)
	_check(w.inventory.held.size() == 2 and w.current_type_id() == 3,
			"先摆成两把(实际 %d 把,手上类型 %d)" % [w.inventory.held.size(), w.current_type_id()])
	# 从位置 0 往正方向滚一次 → 目标位置 1
	w.request_net_cycle(1)
	var sent: int = w.consume_switch_inst()
	_check(sent == inst1, "滚轮上行的是**目标那把的 inst** %d(实际 %d)" % [inst1, sent])
	_check(sent != 1, "上行值**不得**是背包位置(1)—— 位置在两端可能解出不同的枪")
	_check(sent != 3, "上行值**不得**是类型 id(3)—— 同型号两把恒等,区分不了是哪一把")
	_check(w._current_index == 1 and w.current_type_id() == 1,
			"本地同刻切到位置 1(实际 index=%d 类型=%d)" % [w._current_index, w.current_type_id()])
	# 再走一遍**消费端口径**(服务器 `player.gd` 的那句):同一个值必须还原出同一把
	w.equip_index(0)
	_check(w._current_index == 0, "先切回位置 0(实际 %d)" % w._current_index)
	w.equip_inst(sent)
	_check(w._current_index == 1 and w.current_type_id() == 1,
			"按消费端口径 equip_inst(inst) 落回同一把(实际 index=%d 类型=%d)" % [
					w._current_index, w.current_type_id()])
	_check(is_instance_valid(_local), "切枪后本地玩家仍有效")
```

- [ ] **Step 8: 把上行夹具的 `"weapon": 0` 改成 `"winst": 0`（**20 处 / 14 个文件，按行号逐处**）**

★ **先看清楚这 20 处的共同点**：它们**全部**传 `0`（= "本包没有切枪请求"）。
所以这次改名 **不会** 让任何一条断言变红 —— 也就是说，**这 20 处一条都拦不住"漏改"**。
（认了这件事，才不会把"改完全绿"误读成"改对了"。真正的拦阻是 Step 7 那两条 + Step 1 的相①。）

★★ **绝不做全仓替换**：同一个文件里可能**同时**有上行夹具与下行夹具 ——
`tests/replica_ghost_probe.gd` 就是（它的 `:127`/`:292` 是**下行快照**、`:215` 才是上行记录）。
一条 `s/"weapon":/"winst":/g` 会把下行那两处也改成 `winst` ⇒ 副本读不到键 ⇒ **静默空手**。
故下面**按 `文件:行号` 逐处 `sed`**：

```bash
# network_input_smoke.gd —— 4 处。★ 这四行的是 `"weapon": 0})`,**没有逗号后缀**,
#   用 `"weapon": 0,` 的模式一处都匹配不上(踩过:整条命令"成功"执行而一处没改)。
sed -i -e '12s/"weapon": 0})/"winst": 0})/' -e '17s/"weapon": 0})/"winst": 0})/' \
       -e '21s/"weapon": 0})/"winst": 0})/' -e '25s/"weapon": 0})/"winst": 0})/' \
       tests/network_input_smoke.gd
# move_feel_smoke.gd:62
sed -i '62s/"weapon": 0,/"winst": 0,/' tests/move_feel_smoke.gd
# pvp_match_smoke.gd:138
sed -i '138s/"weapon": 0,/"winst": 0,/' tests/pvp_match_smoke.gd
# pvp_reconcile_smoke.gd:133
sed -i '133s/"weapon": 0,/"winst": 0,/' tests/pvp_reconcile_smoke.gd
# pvp_twin_smoke.gd:185
sed -i '185s/"weapon": 0,/"winst": 0,/' tests/pvp_twin_smoke.gd
# ammo_rollback_probe.gd:128
sed -i '128s/"weapon": 0,/"winst": 0,/' tests/ammo_rollback_probe.gd
# brawl_rollback_probe.gd:448
sed -i '448s/"weapon": 0,/"winst": 0,/' tests/brawl_rollback_probe.gd
# ground_action_probe.gd:387
sed -i '387s/"weapon": 0,/"winst": 0,/' tests/ground_action_probe.gd
# kh_l3_probe.gd:503, 516, 537
sed -i -e '503s/"weapon": 0,/"winst": 0,' -e '516s/"weapon": 0,/"winst": 0,' \
       -e '537s/"weapon": 0,/"winst": 0,' tests/kh_l3_probe.gd
# laser_team_probe.gd:169
sed -i '169s/"weapon": 0,/"winst": 0,/' tests/laser_team_probe.gd
# rollback_fidelity_probe.gd:72, 114
sed -i -e '72s/"weapon": 0,/"winst": 0,' -e '114s/"weapon": 0,/"winst": 0,' \
       tests/rollback_fidelity_probe.gd
# squash_host_water_probe.gd:248
sed -i '248s/"weapon": 0,/"winst": 0,/' tests/squash_host_water_probe.gd
# ★★ replica_ghost_probe.gd:**只改 :215**。:127 与 :292 是**下行快照**,归 Task 3。
sed -i '215s/"weapon": 0,/"winst": 0,/' tests/replica_ghost_probe.gd
# reconnect_watcher.gd:378
sed -i '378s/"weapon": 0,/"winst": 0,/' tests/reconnect_watcher.gd
```

★ **行号在 Task 1 之后仍然有效**：Task 1 对上面这些文件的改动**全是同行替换**（名字换名字、
循环变量换名字），**不增删任何一行**（逐处核过：`kh_l3_probe` 的 59/156/162/164-169/172-235/503+、
`ground_action_probe` 的 182-214/387、其余同理）。唯一一处删行的编辑在 `weapon_component.gd:177`
（删 `var type_id := int(slot)`），而它不在本清单里。
★ **但行号是"今天"的** —— 实施时若中途改过这些文件的行数，先 `grep -n '"weapon"' <file>` 重新定位，
**别照抄数字**。

★ 改完逐行核对（每一处都必须从 `"weapon"` 变成 `"winst"`）：

```bash
grep -rn '"weapon"' --include=*.gd --exclude-dir=.claude --exclude-dir=.godot \
  --exclude-dir=_crashtest --exclude-dir=.superpowers --exclude-dir=docs \
  scenes core server ui tests | grep -v 'weapon_name'
```
Expected: 恰好剩 **14 处 / 8 个文件**，与"下行"清单**逐条**对上（一句话：Task 3 的全部活）——
生产端 **2 处**：`server/match_snapshot.gd:23`、`scenes/player/player_replica.gd:203`；
夹具 **12 处**：`tests/preview_visibility_probe.gd:79,94,102,125`（4）、
`tests/replica_ghost_probe.gd:127,292`（2）、`tests/replica_smoothness_probe.gd:120`（1）、
`tests/squash_replica_probe.gd:283`（1）、`tests/ground_client_probe.gd:289,297,305`（3）、
`tests/snapshot_size_probe.gd:93`（1）。
★ **数不上就是漏了**（初稿在这里只列了 3 个文件、写成"8 处"，被评审照出来）。
★ `grep -v 'weapon_name'` 挡的是 `scenes/weapons/weapon_base.gd:16` 的
`@export var weapon_name: String = "weapon"` —— 那是**默认名字符串**，一字不许动。

★ `"winst": 0` 与生产端的语义要对齐：`apply_packet` 只在 `> 0` 时覆盖，`clear_edges()` 清 ——
与旧 `"weapon": 0` 的语义**逐字相同**（0 = 无请求）。

- [ ] **Step 9: grep 闸门（补上 Task 1 三个刻意留活的名字）**

```bash
cd "$(git rev-parse --show-toplevel)"
for sym in push_net_slot consume_net_slot _net_slot; do
  hits=$(grep -rn --include=*.gd "$sym" --exclude-dir=.claude --exclude-dir=.godot \
      --exclude-dir=_crashtest --exclude-dir=.superpowers --exclude-dir=docs \
      scenes core server ui tests || true)
  if [ -n "$hits" ]; then echo "STALE: $sym"; echo "$hits"; fi
done
grep -rn '"weapon": src\.' --include=*.gd --exclude-dir=.claude --exclude-dir=.godot \
  --exclude-dir=_crashtest --exclude-dir=.superpowers --exclude-dir=docs scenes core server ui tests \
  && echo "STALE: pack_record 还在产出旧键"
echo "== 上面除 STALE 外不得有输出 =="
```

- [ ] **Step 10: 回归**

```bash
source tests/env.sh
# ① 场景探针
for t in weapon_switch_inst_probe net_ground_probe ground_client_probe ground_action_probe \
         rollback_fidelity_probe replica_ghost_probe laser_team_probe kh_l3_probe \
         brawl_rollback_probe move_feel_smoke pvp_twin_smoke pvp_reconcile_smoke ammo_rollback_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL|SMOKE_"
done
# ② 纯逻辑冒烟
for t in network_input_smoke enemy_logic_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL"
done
```
Expected: 全绿 —— `KH weapon-inst PROBE: ALL-OK` / `KH net-ground PROBE: ALL-OK` /
`GROUND CLIENT PROBE: ALL-OK` / `GROUND ACTION PROBE: ALL-OK` / `ROLLBACK FIDELITY PROBE: ALL-OK` /
`REPLICA GHOST PROBE: ALL-OK` / `LASER TEAM PROBE: ALL-OK` / `KH L3 PROBE: ALL-OK` /
`BRAWL ROLLBACK PROBE: ALL-OK` / `SMOKE_MOVE_FEEL OK: …` / `SMOKE_TWIN OK: …` /
`SMOKE_RECONCILE OK: …` / `AMMO ROLLBACK PROBE: ALL-OK` / `NET_INPUT_OK: …` / `SMOKE OK`。
★ **`pvp_match_smoke.sh` / `ground_net_probe.tscn` / `reconnect_probe.tscn` 归用户跑**
（真链路、占端口 —— 见 Global Constraints）。

- [ ] **Step 11: 提交**

```bash
git add scenes/player/weapon_component.gd scenes/player/player.gd core/net/player_input.gd \
        core/net/packet_input_source.gd scenes/pvp_match_client.gd \
        tests/weapon_switch_inst_probe.gd tests/weapon_switch_inst_probe.tscn \
        tests/net_ground_probe.gd tests/ground_client_probe.gd \
        tests/network_input_smoke.gd tests/move_feel_smoke.gd tests/pvp_match_smoke.gd \
        tests/pvp_reconcile_smoke.gd tests/pvp_twin_smoke.gd tests/ammo_rollback_probe.gd \
        tests/brawl_rollback_probe.gd tests/ground_action_probe.gd tests/kh_l3_probe.gd \
        tests/laser_team_probe.gd tests/rollback_fidelity_probe.gd tests/squash_host_water_probe.gd \
        tests/replica_ghost_probe.gd tests/reconnect_watcher.gd
git commit -F - <<'EOF'
feat(weapon): 上行传"解析结果"而不是"寻址方式" —— 输入包 winst 带目标那把的 inst

"weapon" 键带的是背包位置(1-based),而位置的含义由本端背包决定;拾取/丢弃
是服务器裁决、客户端不预测,那 ~1RTT 的窗口里同一个下标在两端解出不同的枪
(「切不动/切到另一把」的结构性来源)。改成 inst 后两端 held 的顺序不再是前提。

反证了两条既有守卫并改写:net_ground_probe ④c(源码级 equip_index(wslot-1))
与 ground_client_probe ⑥(行为级"上行值=背包位置且不得是 type id")。
EOF
```

---

### Task 3: 下行键 `"weapon"` → `"type_id"`

**Files:**
- Modify: `server/match_snapshot.gd`、`scenes/player/player_replica.gd`
- Modify（夹具）: `tests/preview_visibility_probe.gd`、`tests/replica_ghost_probe.gd`、
  `tests/replica_smoothness_probe.gd`、`tests/squash_replica_probe.gd`、`tests/ground_client_probe.gd`、
  `tests/snapshot_size_probe.gd`
- Modify: `tests/weapon_switch_inst_probe.gd`（加相⑤）

**Interfaces:**
- Consumes: Task 1 的 `current_type_id()`。
- Produces: 下行世界包键 `"type_id"`（`"weapon"` 删除），**生产端与消费端同名**。

★★ **这是本批唯一一处"改一半完全静默"的地方**：消费端 `player_replica.gd:203` 今天读的是
`int(data.get("weapon", 0))`，一旦改成 `int(data.get("type_id", 0))` 而**生产端仍发 `"weapon"`**，
它就**读不到键**、拿到默认 `0` ⇒ 副本**一直空手**（对手的枪凭空消失），**不报错、不断言**。
故 Step 1 的红断言必须**两端一起钉**，Step 6 的反证也钉这一点。

- [ ] **Step 1: 给探针加相⑤（源码级，**今天逐条红**）**

在 `tests/weapon_switch_inst_probe.gd` 里加这个函数，并把它**紧接在 `_phase_source_contract()`
之后**加进 `_run()`：

```gdscript
# ── 相⑤ 下行:世界包的"拿的是哪种枪"字段叫 type_id,且**两端同名**(★ 改动前逐条红)──
# ★ 为什么必须**两端一起**断言:只改一端**不报错** —— 副本那句 `data.get("type_id", 0)`
#   读不到键会拿到默认 0 ⇒ 副本**一直空手**(对手的枪凭空消失)。这是本批唯一
#   "改一半完全静默"的地方,故判据是**一对**而不是一条。
func _phase_downlink_key() -> void:
	var before := _failures.size()
	var mss := _code_only(_read("res://server/match_snapshot.gd"))
	var pre := _code_only(_read("res://scenes/player/player_replica.gd"))
	_check(mss.contains("\"type_id\": p.weapons.current_type_id()"),
			"下行快照生产端没把 weapon 字段改名 type_id")
	_check(not mss.contains("\"weapon\": p.weapons."),
			"下行快照生产端还发着旧键 weapon —— 与上行同名不同义")
	_check(pre.contains("data.get(\"type_id\", 0)"),
			"副本没读 type_id —— 生产端改了名而它照旧读 weapon 的话,副本会**静默空手**")
	_summary(before, "相⑤ 下行键两端同源")
```

并把它加进 `_run()`：
```gdscript
	_phase_downlink_key()
	_require_ran("downlink_key")
```

- [ ] **Step 2: 跑一次，确认相⑤ 红**

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 \
  res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|✗"
```
Expected: 相⑤ 那三条 **✗**（其余相已由 Task 2 转绿）。

- [ ] **Step 3: 改生产端与消费端（**必须同一次改完**）**

`server/match_snapshot.gd:23`：
```gdscript
			"type_id": p.weapons.current_type_id(),
```
★ 只改键名与函数名 —— 值仍是**类型 id**（下行要的是"用哪种枪的静态外观"，副本按它换武器场景）。

`scenes/player/player_replica.gd:203`：
```gdscript
	var type_id := int(data.get("type_id", 0))
```
（Task 1 已把局部名从 `slot` 改成 `type_id`；本步只把**键名** `"weapon"` 改成 `"type_id"`。）

- [ ] **Step 4: 改 6 个快照夹具文件（12 处，按行号逐处）**

★★ **先重新定位行号**：Task 2 Step 7 把 `tests/ground_client_probe.gd` 的 ⑥ **整段替换**过
（28 行 → 约 35 行）⇒ **该文件的行号已经漂了**。别照抄下面的数字：

```bash
for f in tests/preview_visibility_probe.gd tests/replica_ghost_probe.gd \
         tests/replica_smoothness_probe.gd tests/squash_replica_probe.gd \
         tests/ground_client_probe.gd tests/snapshot_size_probe.gd; do
  echo "--- $f ---"; grep -n '"weapon"' $f
done
```
取到的每一行都应落进下面这张表（**Task 2 收尾那 14 处里，"夹具"那 12 处**；另 2 处是生产端，
见 Step 3）。`replica_ghost_probe.gd:215` 已在 Task 2 改成 `winst`，**不该**再出现在这里。

| 文件 | 处数 | 今天的内容 | 改成 |
|---|---|---|---|
| `tests/preview_visibility_probe.gd` | 4（:79,94,102,125） | `"weapon": int(HEAVY_SLOT), "previewing": …` | `"type_id": int(HEAVY_SLOT), …` |
| `tests/replica_ghost_probe.gd` | 2（:127, :292） | `… "aim": Vector2.LEFT, "weapon": 0, "previewing": false …` / `rep.apply_snapshot({… "aim": Vector2.RIGHT, "weapon": 0, …` | 同位置的 `"weapon"` → `"type_id"` |
| `tests/replica_smoothness_probe.gd` | 1（:120） | `\t\t"weapon": 0,` | `\t\t"type_id": 0,` |
| `tests/squash_replica_probe.gd` | 1（:283） | `\t\t"weapon": 0,` | `\t\t"type_id": 0,` |
| `tests/ground_client_probe.gd` | 3 | `"hp": 100, "downed": false, "aim": Vector2.RIGHT, "weapon": 2,` / `snap["weapon"] = 0` / `snap["weapon"] = 4` | `"type_id": 2,` / `snap["type_id"] = …` |
| `tests/snapshot_size_probe.gd` | 1（:93） | `"weapon": p.weapons.current_type_id(),` | `"type_id": p.weapons.current_type_id(),` |

```bash
# 一次跑完(用 `sed` 的模式而非行号 —— 每个文件里"上行那处"此时都已经是 winst,不会误伤)
sed -i 's/"weapon": int(HEAVY_SLOT)/"type_id": int(HEAVY_SLOT)/g' tests/preview_visibility_probe.gd
# ★★ replica_ghost_probe 有**两处**、形态**不同**,必须两条 sed:
#    :127 的 "previewing" **同一行**;:292 的 "previewing" 在**下一行**(行尾就是 "weapon": 0,)。
#    只写第一条(初稿就是这样)会**静默漏掉 :292** —— 那一相守的是"倒地时幽灵体不跟转体",
#    生产端改名后它**拿到默认 0**(副本空手)却很可能**照样全绿** ⇒ 假绿。
sed -i -e 's/"weapon": 0, "previewing"/"type_id": 0, "previewing"/' \
       -e 's/"facing": 1, "aim": Vector2.RIGHT, "weapon": 0,$/"facing": 1, "aim": Vector2.RIGHT, "type_id": 0,/' \
       tests/replica_ghost_probe.gd
sed -i 's/^\(\t*\)"weapon": 0,$/\1"type_id": 0,/'                      tests/replica_smoothness_probe.gd
sed -i 's/^\(\t*\)"weapon": 0,$/\1"type_id": 0,/'                      tests/squash_replica_probe.gd
sed -i -e 's/"weapon": 2,/"type_id": 2,/' -e 's/snap\["weapon"\]/snap["type_id"]/g' tests/ground_client_probe.gd
sed -i 's/"weapon": p\.weapons\.current_type_id()/"type_id": p.weapons.current_type_id()/' tests/snapshot_size_probe.gd
```
★ 三个**模式**是刻意选窄的，各自只匹配该文件里的下行那一处/那几处：
`"weapon": 0, "previewing"`（下行独有，`replica_ghost_probe:215` 的上行那处后面跟的是 `"aim"`）、
`"facing": 1, "aim": Vector2.RIGHT, "weapon": 0,`（**行尾锚定**，专打 `:292` 那种"键在行尾"的形态）、
行首缩进 + 整行 `"weapon": 0,`（两个 `_snapshot_dict` 各只有一行）、
`"weapon": 2,`（`ground_client_probe` 的下行夹具值不是 0）。
★★ **每条 `sed` 跑完必须立刻核对**（这一条**不是可选的** —— 上面那个漏一处就是这么被抓出来的）：
对**每个**文件跑 `grep -n '"weapon"' $f`，**必须零输出**：

```bash
for f in tests/preview_visibility_probe.gd tests/replica_ghost_probe.gd \
         tests/replica_smoothness_probe.gd tests/squash_replica_probe.gd \
         tests/ground_client_probe.gd tests/snapshot_size_probe.gd; do
  n=$(grep -c '"weapon"' $f || true)
  [ "$n" = "0" ] || { echo "STALE: $f 还剩 $n 处"; grep -n '"weapon"' $f; }
done
echo "== 上面不得有输出 =="
```
★ **`tests/snapshot_size_probe.gd:134` 的 `"w": p.weapons.current_type_id()` 不动** ——
那是"短键变体"`_entry_world_thin()` 自己的一把钥匙（文件内注释写明"短键协议两端同改，值不变"），
与 `match_snapshot` 的字段名不是同一个东西。

★ 全部改完核一遍（必须**零输出**）：
```bash
grep -rn '"weapon"' --include=*.gd --exclude-dir=.claude --exclude-dir=.godot \
  --exclude-dir=_crashtest --exclude-dir=.superpowers --exclude-dir=docs \
  scenes core server ui tests | grep -v 'weapon_name'
```

- [ ] **Step 5: 跑 —— 确认相⑤ 转绿 + 副本类探针全绿**

```bash
source tests/env.sh
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|✗"
for t in ground_client_probe preview_visibility_probe replica_ghost_probe replica_smoothness_probe squash_replica_probe snapshot_size_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
```
Expected: `KH weapon-inst PROBE: ALL-OK` + 六条探针各自 `ALL-OK`。

- [ ] **Step 6: 反证（只把**消费端**退回去，确认两处都红）**

把 `scenes/player/player_replica.gd:203` 改回 `var type_id := int(data.get("weapon", 0))`
（生产端与夹具都还是 `type_id`），跑：

```bash
source tests/env.sh
"$GODOT" --headless --path . --quit-after 3600 res://tests/weapon_switch_inst_probe.tscn 2>&1 | grep -E "PROBE|✗"
"$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn 2>&1 | grep -E "PROBE|✗|ALL-OK"
```
Expected:
- `weapon_switch_inst_probe`：相⑤ 的第三条 **✗**（"副本没读 type_id"）。
- `ground_client_probe`：**⑦ 红**（`先握上一把(实际 <null>)` 与 `槽位记成 2(实际 0)`）——
  ★ 这一条是**行为级**的：它证明相⑤ 的源码级断言**不是空转**（真会把对手的枪弄丢）。
确认后**改回来**。

- [ ] **Step 7: 提交**

```bash
git add server/match_snapshot.gd scenes/player/player_replica.gd \
        tests/weapon_switch_inst_probe.gd tests/preview_visibility_probe.gd \
        tests/replica_ghost_probe.gd tests/replica_smoothness_probe.gd \
        tests/squash_replica_probe.gd tests/ground_client_probe.gd tests/snapshot_size_probe.gd
git commit -F - <<'EOF'
refactor(weapon): 下行快照的 "weapon" 改名 "type_id"，让上行 inst / 下行 type_id 在字段名上就分得开
EOF
```

---

### Task 4: `equip_type` 的"背包里没有就加"降级为 `push_error`（§4.5）

**Files:**
- Modify: `tests/kh_l3_probe.gd`（先在 `_check_gate` 末尾加红断言）
- Modify: `scenes/player/weapon_component.gd`（`equip_type` 的那条分支）
- Modify: `tests/menu_autotest.gd` + `tests/preview_visibility_probe.gd`（**连带修正**，见 Step 4）
  ★ 两者都是"真实依赖那条 add 分支"的调用点 —— 后一处**自动化跑得到**（`.tscn` 探针），
  所以它同时是本 Task 的行为判据。

**Interfaces:**
- Consumes: Task 1 的 `equip_type(type_id: int)`。
- Produces: `equip_type` 对"背包里没有这个类型"**不再 `add()`**，只 `push_error`。

★ **为什么现在可以降级**：那条注释写的是**联机兜底**（"服务器说'你现在有重狙'而客户端背包里
可能还没有它"）。§4.1 落地后客户端背包**只从权威态 `inv` 重建**，而 `restore_inventory` 先跑、
`_apply_weapon_state` 的 `by_inst` 再判重建落点 ⇒ "权威说的那把不在本地表里"**只可能是真异常**。
★ 而且它会**静默改变背包长度** —— 那正是"两端 `held` 不同序"的又一条产生源。
★ **单机不受影响**：`pick_up` 走 `WeaponInventory.add`，不经过 `equip_type`。

- [ ] **Step 1: 先在 `tests/kh_l3_probe.gd` 加红断言**

位置：`_check_gate()` **末尾**、「全禁 → 兜底」那一段（今天 :187-194，`wep.set_enabled_slots([1,2,3,4,5,6])`
→ 三条断言 → `wep.set_enabled_slots([])` → `await _frames(3)`）**之后**。
★ 那段之后 `_check_gate` 就结束了（`_check_cycle` 是**另一个函数**，由 `_run` 另行调用）——
所以插入点就是 `_check_gate` 的最后几行之后。
此时状态（**逐句核算过，别想当然**）：`enabled_types` 恢复全开（`[]` = 什么都不禁）；
背包 = `[1, 3, 4]`（手枪 2 格 + 重狙 4 格 + 霰弹 2 格）；`_current_type` = **1**。
（★ 不是 0：:187 那次"全禁"让 `_current_type` 从 4 落到 `_first_enabled_index()` = 0 = **类型 1**，
而 :193 的恢复全开不改变它。）

```gdscript
	# ⑤ 背包里没有的类型:equip_type 不得**凭空加一把**(§4.5,2026-09-25)
	# ★ 这条在改动前是**红**的:旧实现有一条"没有就加"的分支(注释写着"这不是便利,是必需")——
	#   它会让 held **悄悄变长**,而那正是"两端背包不同序"的另一条产生源(§4.1 要消灭的东西)。
	# ★ 类型选 5(榴弹发射器):此刻它**是启用的**、且**不在**背包 [1,3,4] 里 ——
	#   两个条件缺一不可(选一个被禁的类型会被闸门先挡掉,那条分支根本走不到 ⇒ 假绿)。
	# ★ 旧实现还会**静默超容**:1+3+4 = 8 格已经占满,再加一把重的 = 12 格,而 add() 不代替闸门。
	var n_before := wep.inventory.held.size()
	var t_before := wep.current_type_id()
	wep.equip_type(5)
	await _frames(3)
	_check(wep.inventory.held.size() == n_before,
			"equip_type 对背包里没有的类型**凭空加了一把**(%d → %d 把)" % [n_before, wep.inventory.held.size()])
	_check(wep.current_type_id() == t_before,
			"equip_type 对背包里没有的类型仍切了枪(类型 %d → %d)" % [t_before, wep.current_type_id()])
```

- [ ] **Step 2: 跑 —— 确认这两条红**

```bash
source tests/env.sh && "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn 2>&1 \
  | grep -E "KH L3|凭空加|仍切了枪"
```
Expected: 两条都 **✗**（`3 → 4 把` / `类型 1 → 5`），末行 `KH L3 PROBE: FAIL`。
★ 若第一条**绿**：说明 `equip_type(5)` 被别的闸门挡掉了（多半是 `is_type_enabled(5)` 为假）——
回去查"全禁"那一段有没有真的把 `enabled_types` 恢复全开，**别**往下走。
★ 若第二条**绿**（`类型 1 → 1`）：说明 `_current_type` 本来就已不是 1 —— 那你插入的位置错了
（多半落到 `_check_cycle` 之后去了），回去核一遍。

- [ ] **Step 3: 改 `equip_type`**

`scenes/player/weapon_component.gd` 的 `equip_type`（Task 1 改完后形如，注释是今天的原文）：

```gdscript
# 按**类型 id**切枪(rollback / 权威兜底走这条)。
# ★ 背包里没有这个类型 = **异常**,不再"顺手造一把"(§4.5,2026-09-25 改)。
#   旧实现有一条"没有就加"(注释写着"这不是便利,是必需…服务器说'你现在有重狙'而客户端背包里
#   可能还没有它")。§4.1 落地后这条兜底**不再需要**:客户端背包只从权威态(`inv`)重建,
#   而 `restore_inventory` 先跑、`_apply_weapon_state` 的 `by_inst` 再判重建落点
#   ⇒ "权威说的那把不在本地表里"只可能是**真异常**。
#   ★ 更要紧的是:它会**静默改变背包长度**,而那正是"两端 held 不同序"的另一条产生源
#   (§4.1 要消灭的东西)。所以这里降级成 push_error + **不加入**。
#   ★ 单机不受影响:`pick_up` 走 `WeaponInventory.add`,不经过本函数。
func equip_type(type_id: int) -> void:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		push_error("equip_type: 背包里没有类型 %d —— 不再凭空加入(§4.5;见本函数注释)" % type_id)
		return
	_equip_index(idx)
```

- [ ] **Step 4: 连带修正两个真实依赖"没有就加"的调用点**

★ 逐处核过 `equip_type` 的 **9 个调用点**（定义在 `weapon_component.gd:176`，另计），
**有两处依赖那条"没有就加"分支** —— 其余 7 处都不受影响：

| 调用点 | 那时背包里有这个类型吗 | 结论 |
|---|---|---|
| `player.gd:677`（`_apply_weapon_state` 兜底） | 有（`inv` 刚重建过） | 不受影响 |
| `enemy_logic_smoke.gd:454,460` | 有（`set_initial_inventory([1, 2])`） | 不受影响 |
| `kh_l3_probe.gd:177,182` | 有（`set_initial_inventory([1, 3, 4])`） | 不受影响 |
| `menu_autotest.gd:183` | 有（:168 已经把它拿到手了） | 不受影响 |
| `menu_autotest.gd:206` | 有（`_press_key("R")` → `restart_single` 重置背包，发的就是手枪） | 不受影响 |
| **`menu_autotest.gd:168`** | **没有**（那时背包只有开局手枪） | **必须改** |
| **`preview_visibility_probe.gd:50`** | **没有**（那时背包只有开局手枪；单机开局由 `Level0._give_starting_weapon` 发 `default_type()`） | **必须改** |

★★ **第二处（`preview_visibility_probe.gd:50`）是评审照出来的、本计划初稿漏掉的**：
Task 1 把它从 `wep.equip(HEAVY_SLOT)` 改成 `wep.equip_type(int(HEAVY_SLOT))`（类型对了），
但**背包里没有重狙** ⇒ Task 4 之后它会 `push_error` + 不加入 ⇒ `current_weapon()` 仍是手枪
⇒ `槽 %s 是 heavy_aim 武器` 那条**红**（`PREVIEW VISIBILITY: FAIL(1 条)`）。
★ 所以"只有 `menu_autotest:168` 依赖那条分支"这个断言在 Task 1 之后就**不成立**了 ——
两处都得改。

**(a) `tests/menu_autotest.gd:168`**

```gdscript
	# 打炮:切第 5 槽(榴弹发射器)轰两发,等引信炸开 + 碎砖落定
	player.weapons.equip_type(5)
```
改成：
```gdscript
	# 打炮:拿到第 5 槽(榴弹发射器)轰两发,等引信炸开 + 碎砖落定
	# ★ 必须走**发放路径**(pick_up),不能走 equip_type —— 后者自 2026-09-25 起对
	#   "背包里没有这个类型"是 push_error + 不加入(§4.5),照旧调它会**静默拿到手枪**
	#   (打炮那段变成打手枪,榴弹自杀那一段直接不倒地),而那只是个 ERROR 日志。
	player.weapons.pick_up(5, WeaponInventory.MAG_FULL)
```

**(b) `tests/preview_visibility_probe.gd:50`**

```gdscript
	wep.equip_type(int(HEAVY_SLOT))
```
改成：
```gdscript
	# ★ 同 (a):必须走**发放路径**。单机开局只发一把手枪(`default_type()`),背包里**没有**重狙
	#   ⇒ `equip_type(3)` 自 §4.5 起是 push_error + 不加入 ⇒ 这条探针会拿到手枪,
	#   `槽 %s 是 heavy_aim 武器` 直接红(PREVIEW VISIBILITY: FAIL(1 条))。
	wep.pick_up(int(HEAVY_SLOT), WeaponInventory.MAG_FULL)
```

★ 两处 `pick_up` 的闸门都成立：手枪(轻 2 格) + 重狙/榴弹(重 4 格) = 6 ≤ `CAPACITY`(8)，
2 把 ≤ `MAX_WEAPONS`(4)。

- [ ] **Step 5: 跑 —— 确认转绿**

```bash
source tests/env.sh
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l3_probe.tscn 2>&1 | grep -E "KH L3|凭空加|仍切了枪"
"$GODOT" --headless --path . --quit-after 3600 res://tests/preview_visibility_probe.tscn 2>&1 | grep -E "PREVIEW VISIBILITY|FAIL"
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd 2>&1 | grep -E "SMOKE OK|FAIL"
"$GODOT" --headless --path . -s res://tests/weapon_inventory_smoke.gd 2>&1 | grep -E "OK|FAIL"
```
Expected: `KH L3 PROBE: ALL-OK`（那两条转 ✓）+ **`PREVIEW VISIBILITY: ALL-OK`**（Step 4(b) 的落点）+
`SMOKE OK` + `WEAPON_INVENTORY OK`。
★ `push_error` 会在 stdout/stderr 上打一行 `ERROR:` + backtrace —— **那是预期的**
（红断言本身就在验这条路径）。别把它读成失败；判据仍是那行 `ALL-OK`。
★ `menu_autotest.gd` 那条改动**跑不了自动化**（它是 `-- --autotest-play` 的手/眼验收路径）——
登记为"归用户"，别为它编一个探针。

- [ ] **Step 6: 反证（把 `return` 换成 `add` 那一支，确认又红）**

把 `equip_type` 里 `idx < 0` 那一支临时改回旧行为：

```gdscript
	if idx < 0:
		idx = inventory.held.size()
		inventory.add(type_id, WeaponInventory.MAG_FULL)
		inventory_changed.emit()
```
再跑 Step 5 的第一条命令，**必须**重新看到那两条 `✗`。确认后改回来。

- [ ] **Step 7: 提交**

```bash
git add scenes/player/weapon_component.gd tests/kh_l3_probe.gd tests/menu_autotest.gd \
        tests/preview_visibility_probe.gd
git commit -F - <<'EOF'
fix(weapon): equip_type 不再"背包里没有就凭空造一把" —— 改 push_error + 不加入(§4.5)

它会静默改变背包长度,而那正是"两端 held 不同序"的另一条产生源。
§4.1 之后这条兜底不再需要(客户端背包只从权威态 inv 重建)。
连带修正两个真实依赖它的调用点(menu_autotest / preview_visibility_probe),
两者都改走 pick_up 发放路径。
EOF
```

---

### Task 5: 登记 + 全量回归

**Files:**
- Modify: `CLAUDE.md`（「武器与子弹」小节的词汇段）

**Interfaces:**
- Consumes: 无。
- Produces: 无（文档 + 回归）。

- [ ] **Step 1: 全量回归（除真链路之外的一切）**

★ 跑法**按脚本首行分**（`extends SceneTree` → `-s`；`extends Node` → `--quit-after` 跑 `.tscn`）。
下面两组**逐个核过**（文件在不在、首行是什么），别把 `.tscn` 探针塞进 `-s` 循环里
（那样 `-s` 拿到的是一份没有场景根的脚本 ⇒ 一行都不打印，看着像功能坏了）。

```bash
source tests/env.sh
# ① 场景探针(Node):必须带 --quit-after,且不带 -s
for t in weapon_switch_inst_probe net_ground_probe ground_client_probe ground_action_probe \
         weapon_pickup_probe level0_weapon_scatter_probe rollback_fidelity_probe \
         replica_ghost_probe replica_smoothness_probe squash_replica_probe preview_visibility_probe \
         laser_team_probe kh_l3_probe kh_l4_probe kh_l5_probe kh_l6_probe brawl_rollback_probe \
         snapshot_size_probe match_sync_probe resync_world_probe \
         move_feel_smoke pvp_twin_smoke pvp_reconcile_smoke ammo_rollback_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
# ② 纯逻辑冒烟(extends SceneTree)
for t in enemy_logic_smoke weapon_inventory_smoke ground_weapon_field_smoke sprite_bounds_smoke \
         network_input_smoke laser_weapon_smoke ai_input_source_smoke team_room_smoke; do
  echo "--- $t ---"
  "$GODOT" --headless --path . -s res://tests/$t.gd 2>&1 | grep -E "OK|FAIL"
done
```
Expected: 全绿。各条判据文本**逐个核过**（别只 grep 一个笼统的 `OK`，也别把 `FAIL` 漏掉）：
`KH weapon-inst PROBE: ALL-OK` / `KH net-ground PROBE: ALL-OK`（★ 该探针**文件头写的**
`NET GROUND PROBE: ALL-OK` 是**陈旧说法** —— 实际由 `ProbeBase._finish()` 拼成
`KH <probe_id()> PROBE: ALL-OK`，故 grep `ALL-OK` 即可，别去 grep 那个不存在的串）/
`GROUND CLIENT PROBE: ALL-OK` / `GROUND ACTION PROBE: ALL-OK` / `WEAPON PICKUP PROBE: ALL-OK` /
`LEVEL0 WEAPON SCATTER PROBE: ALL-OK` / `ROLLBACK FIDELITY PROBE: ALL-OK` /
`REPLICA GHOST PROBE: ALL-OK` / `REPLICA SMOOTHNESS PROBE: ALL-OK` / `SQUASH REPLICA PROBE: ALL-OK` /
`PREVIEW VISIBILITY: ALL-OK`（★ **无 `PROBE` 一词**）/ `LASER TEAM PROBE: ALL-OK` /
`KH L3 PROBE: ALL-OK` / `KH L4 PROBE: ALL-OK` / `KH L5 PROBE: ALL-OK` / `KH L6 PROBE: ALL-OK` /
`BRAWL ROLLBACK PROBE: ALL-OK` / `SNAPSHOT SIZE PROBE: ALL-OK` / `MATCH SYNC PROBE: ALL-OK` /
`RESYNC WORLD PROBE: ALL-OK` / `AMMO ROLLBACK PROBE: ALL-OK` /
`SMOKE_MOVE_FEEL OK: …` / `SMOKE_TWIN OK: …` / `SMOKE_RECONCILE OK: …`（这三条**是下划线命名**，
grep `OK` 即可）/ `SMOKE OK`（`enemy_logic_smoke`）/ `WEAPON_INVENTORY OK` /
`GROUND_WEAPON_FIELD OK` / `SPRITE_BOUNDS OK` / `NET_INPUT_OK: …` /
`SMOKE OK`（`laser_weapon_smoke`）/ `AI INPUT SMOKE: OK` / `TEAM ROOM SMOKE: ALL-OK`。

★ **归用户跑**（真链路 / 占端口 / 拉起子进程，**agent 不代跑**）：
`tests/pvp_room_smoke.sh`、`tests/pvp_match_smoke.sh`、`tests/room_sweep_smoke.sh`、
`tests/reconnect_probe.tscn`、`tests/rejoin_probe.sh`。
★ **实机验收也归用户**：1v1 与大乱斗各打一局，**捡第二把之后**用数字键与滚轮来回切，
不出现"切不动 / 跳回"。

- [ ] **Step 2: 登记进 `CLAUDE.md`**

在「武器与子弹」小节、`WeaponBase` 那一段之后，替换掉今天描述旧名字的那几句
（今天 CLAUDE.md 写的是 `_current_slot` / `enabled_slots` / `set_enabled_slots` / `push_net_slot` ——
**都已经不存在了**，照它读会把读者引向不存在的名字）：

```markdown
- **★ 词汇纪律(2026-09-25,§3)**:"哪把枪"只有三个词,不许互相借用 ——
  **`type_id`**(整数 1–N,**哪一种**;与键位、与背包位置都无关)、
  **`inst`**(逐把唯一,**哪一把**;进输入包与 `capture_state`)、
  **`index`**(背包里的第几个,0-based;**只在本地**:按键解析、HUD 行号)。
  `slot` 一词整体退休 —— `_current_slot`→`_current_type`、`current_slot_int()`→`current_type_id()`、
  `is_slot_enabled`→`is_type_enabled`、`enabled_slots`→`enabled_types`、
  `set_enabled_slots`→`set_enabled_types`、`default_slot()`→`default_type()`、
  `cycle_slot`→`cycle_index`、`push/consume_net_slot`→`push/consume_switch_inst`、
  `equip(String)`→`equip_type(int)`、`WeaponInventory.slot_start`→`cell_start`、
  `used_slots`→`used_cell_count`、`SLOT_COST`→`CELL_COST`、
  `get_weapon_slot_pressed`→`get_switch_index_pressed`、`_weapon_slot_raw`→`_switch_index_raw`。
  ★ **刻意保留** `slot` 的三处:`Player.weapon_slot` 挂点(与 `player_replica` 的 `WeaponSlot`)
  、容量格 UI(`WeaponSlots` / `C_SLOT_*`)、以及 `capture_state()` 的 `wslot` 键(第三条协议面,
  与 §4.1 改的两条不是同一条载荷)。
  ★ **菜单上的编号已去掉**:那个数字**看起来**是键位,而 `type_id` 与键位毫无关系。
  唯一合法的"数字 = 键位"是 HUD 左下角武器框的行首数字(`ui/hud.gd` 的
  `key_lbl.text = str(held_index + 1)`)。
- **★ 上行传"解析结果",不传"寻址方式"(§4.1,2026-09-25)**:输入包带 **`"winst"` = 目标那把的 `inst`**;
  客户端**本地解析**(数字键按 `index`、滚轮按相对位置)→ 取那一把的 `inst`;
  服务器 `equip_inst(inst)` = `index_of_inst` 找不到就**静默不动**。旧的 `"weapon"` 键(背包位置)
  **已删除** —— 它的语义是"本端背包的第 N 个",而拾取/丢弃是服务器裁决、客户端不预测,
  那 ≈1 RTT 的窗口里同一个下标在两端解出**不同的枪**。
  下行世界包的"枪型"字段同时改名 **`type_id`**,让上行 `inst` / 下行 `type_id` 在字段名上就分得开。
  ★ **改这个键 = 改协议 ⇒ 两端必须同一个 build**。
  守卫:`tests/weapon_switch_inst_probe.tscn`(两端 `held` **顺序相反**时按同一个键仍切到同一把 +
  上行/下行的**源码形状**两端同源)。★ `tests/net_ground_probe` ④c 与 `tests/ground_client_probe` ⑥
  是本批**改写**过来的(它们原先断言"上行值 = 背包位置、且不得是 type id" —— 被 §4.1 直接反证)。
- **★ `equip_type` 不再凭空造枪(§4.5,2026-09-25)**:对"背包里没有这个类型"是 `push_error` + **不加入**。
  旧实现有一条"没有就加"(注释写着联机兜底),它会**静默改变背包长度** —— 那正是上面要消灭的
  "两端 held 不同序"的另一条产生源。单机不受影响(`pick_up` 走 `WeaponInventory.add`)。
  ★ **唯一的例外是"发放"**:要让玩家/探针拿到一把背包里还没有的枪,走 `pick_up(type_id, MAG_FULL)`
  (生产路径)或 `set_initial_inventory([...])`,**不要**走 `equip_type`。
  本批连带改了两个**真实依赖那条旧分支**的调用点:`tests/menu_autotest.gd`(榴弹发射器)
  与 `tests/preview_visibility_probe.gd`(重狙)—— 两处都改成 `pick_up`。
  守卫:`tests/kh_l3_probe.gd` ⑤ + `tests/preview_visibility_probe.tscn`。
```

- [ ] **Step 3: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(claude): 武器词汇纪律(type_id/inst/index)+ 上行 winst + equip_type 不再凭空造枪"
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3 + §4.1 + §4.5）

| spec | 本计划 | 落点 |
|---|---|---|
| §3 rename 表 9 项 | ✅ | Task 1 Step 2 |
| §3 "`slot` 整体退休"（表外的 `cycle_slot` / `_weapon_slot_int` / 输入源读口 / 参数名 / meta 键） | ✅ | Task 1 Step 2-4（保留白名单写在 Step 4） |
| §3 菜单编号去掉 | ✅ | Task 1 Step 5（两处格式串**不同**，逐处给出） |
| §3 表遗漏的**外部调用方**（`set_enabled_slots` ×3 生产 + 探针、`default_slot()`、`push/consume_net_slot`） | ✅ | Task 1 Step 2 的文件清单逐文件点名 |
| §4.1 上行键 `winst` / 旧键删除 | ✅ | Task 2 Step 4(a)(c)(d)(e) |
| §4.1 客户端本地解析、服务器 `index_of_inst` 找不到就不动 | ✅ | Task 2 Step 4(a) 的 `take_uplink_switch` / `inst_at_index` / `equip_inst` |
| §4.1 下行 `"weapon"` → `"type_id"` | ✅ | Task 3 |
| §4.1 §7 判据 2（两端反序的探针） | ✅ | Task 2 Step 1 相② + Step 5 单行变异反证（★ 反证点落在 `request_net_cycle`，**不是** `take_uplink_switch` —— 见该步的解释） |
| §4.1 反证掉的两条守卫 | ✅ | Task 2 Step 7（**改写**，不是保持绿） |
| §4.5 `equip()` 降级 | ✅ | Task 4（+ 连带改**两个**真实依赖旧分支的调用点：`menu_autotest` / `preview_visibility_probe`） |
| **§4.3** | **明确不做**（spec 自己已划掉；核验报告 §二.A） | 见文件头"事实基线"第 1 条 |
| §4.2 注册表 / §4.4 容量可配 / §7 目标 1 | 归**另一份计划**（spec §8 的计划 3、4） | — |

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。每个改动都给了完整代码块与确切锚点；
唯一一处"照现有写法"是 Task 1 Step 3 的 `equip` 逐点表 —— 那是**刻意的**（`WeaponBase.equip` 同名，
必须逐点而不能 perl），并给了自查 grep。

**3. 类型一致性**

- `WeaponComponent.inst_at_index(index: int) -> int` / `equip_inst(inst: int) -> void` /
  `push_switch_inst(inst: int) -> void` / `consume_switch_inst() -> int` /
  `take_uplink_switch(key_index: int) -> int`：Task 2 定义与使用处**逐字一致**。
- `PlayerInput.consume_switch_inst() -> int`（公开、frozen 短路）+ `_switch_index_raw() -> int` /
  `_switch_inst_raw() -> int`（可选钩子，默认 0）：与既有 `get_axis`/`_axis_raw` 那条分层同款。
- `equip_type(type_id: int)`：Task 1 改签名（`String` → `int`），Task 4 只改体内分支；
  **9 个调用点**全部在 Task 1 Step 3 的表里（`equip_type(2)` 而非 `equip_type("2")`）——
  ★ 其中 `preview_visibility_probe.gd:50` 与 `snapshot_size_probe.gd:38` 是本计划初稿**漏掉的**，
  由评审照出；前者还连带暴露了 Task 4 的**第二个**真实破坏点。
  ★ `equip` **不在** Step 6 的 13 符号闸门里（`WeaponBase.equip` 同名），
  它的闸门是 Step 3 末尾那条**精确到行**的 `.equip(` grep。
- `current_type_id()` / `current_inst()` 两个名字**存活的语义分工**（类型 vs 哪一把）在 Task 1/2 后仍然成立。

**4. 红绿分界的**具体性**（每条都点了"哪一条断言红、为什么夹具到得了那个状态"）

| Task | 红载体 | 哪一条红 | 为什么到得了 |
|---|---|---|---|
| 1 | grep 闸门 + 基线逐条相同 | 闸门出现 `STALE: <sym>` | 逐符号查过改动前有命中（21/59/14/40/29/5/12/7/11/7/7/18/5 行） |
| 2 | 探针相①（源码级，九条断言） | **八条**具名 ✗（`滚轮待发值不是**目标那把的 inst**…` / `pack_record 没产出 winst 键…` / `pack_record 还在产出旧键 "weapon"…` / `客户端组包没走 take_uplink_switch…` / `客户端组包没把 winst 塞进输入包` / `player.gd 没读 input_source.consume_switch_inst()…` / `player.gd 没按 inst 切枪` / `player.gd 还在按**背包位置**解上行值…`）；第九条"`request_net_cycle` 找得到"今天就是绿的 | 逐条核过今天的源码（`weapon_component.gd:157,162,166`；`packet_input_source.gd:85`；`pvp_match_client.gd:200-204`；`player.gd:192-198`） |
| 2 | 探针相②（行为级） | 单行变异（`request_net_cycle` 的 `push_switch_inst(inst_at_index(next))` → `push_switch_inst(next + 1)`）后**三条** ✗：`上行必须是**目标那把的 inst**(=1)`（实得 **2**）、`服务器从包里取出的 winst 应为 1`（实得 **2**）、`★ 两端…必须切到**同一把**`（客户端 **1** / 服务器 **2**） | 两端背包**在探针里被显式摆成反序**（client `[inst2, inst1]` / server `[inst1, inst2]`），起手 `equip_index(0)` ⇒ 起手就是不同的枪（前置断言钉住）；客户端滚轮一次 → **客户端的位置 1 = 手枪 inst 1**，而变异的推送值 `next+1 = 2` 是**服务器**的位置号 → 服务器 `index_of_inst(2)` 落回它自己的位置 1 = **重狙 inst 2**。★ 变异点**必须在 `request_net_cycle`**：相② 走滚轮，`take_uplink_switch(0)` 的 `key_index` 是 0，改它那个 `if key_index > 0:` 分支是**空操作** |
| 3 | 探针相⑤（源码级，两端一起） | 三条具名 ✗ | 今天生产端是 `match_snapshot.gd:23` 的 `"weapon": …`、消费端是 `player_replica.gd:203` 的 `data.get("weapon", 0)` |
| 3 | `ground_client_probe` ⑦（行为级） | 反证时 `先握上一把(实际 <null>)` + `槽位记成 2(实际 0)` | 夹具 `{"type_id": 2}` 而消费端读 `"weapon"` ⇒ 拿到默认 0 ⇒ 副本不换武器 |
| 4 | `kh_l3_probe` ⑤（新加） | `凭空加了一把(3 → 4 把)` + `仍切了枪(类型 1 → 5)` | 那一刻 `enabled_types` 全开、背包 `[1,3,4]`、当前类型 **1**（:187 的"全禁"把当前枪从类型 4 落到 `_first_enabled_index()` = 类型 1）；选**类型 5**（启用且不在背包里）保证那条分支真的走得到 |
| 4 | `preview_visibility_probe` ①（行为级） | Step 4(b) 的落点：**改回 `equip_type` 就红** —— `槽 3 是 heavy_aim 武器`（`current_weapon()` 是手枪，不是 m82a1） | 单机开局 `Level0._give_starting_weapon` 只发一把手枪 ⇒ 背包里**没有**类型 3 ⇒ `equip_type(3)` 走 `idx < 0` 那条 ⇒ `push_error` + 不加入 |
| 5 | 全量回归 | 任一条 `FAIL` | — |

★ **两个刻意的"不红"断言，都写明了理由，不要当红用**：
`ground_client_probe` ⑥ 新版的"上行值 ≠ 1 / ≠ 3"（它们是**鉴别**：inst 与位置、与类型 id 三者互相可分；
另配了一条"inst1 必须与 1 和 3 都不同"的**前置断言**，撞上了会让探针如实红而不是空转）；
以及 Task 2 Step 8 里那句"这 **20** 处夹具全传 0 ⇒ **一条都拦不住漏改**"——**如实登记**，避免把
"改完全绿"误读成"改对了"。

**4b. 本计划在评审后修掉的三处**（留档，因为都是"会静默"的那一类）：
① 相② 原先用 `cycle_index(1)` —— 那是**单机**那条路、**从不 push**，于是 `take_uplink_switch`
恒读 0、这一相**永远绿不了**（且 Step 5 的变异断言也跟着错）。改用 `request_net_cycle(1)`，
并把反证点从 `take_uplink_switch` 挪到 `request_net_cycle`（在 `key_index == 0` 时前者是空操作）。
② `equip` → `equip_type` 漏了第 9 个调用点 `preview_visibility_probe.gd:50`（传 `String`）。
它**不在** 13 符号闸门里（`WeaponBase.equip` 同名）⇒ 结构性地看不见；补进表 + 回归组，
并把 `.equip(` 那条自查 grep 的排除名单改成**精确到行**（原先的 `kh_l3_probe:430` 这种写法
匹配不上 `kh_l3_probe.gd:430`，整条排除**静默失效**；而整文件排除又会藏起
`enemy_logic_smoke` 的 2 个真调用点）。
③ `replica_ghost_probe.gd` 的下行 sed 只命中 `:127` —— `:292` 的 `"previewing"` 在**下一行**，
形态不同 ⇒ 漏改就是**假绿**（那一相守的是"倒地时幽灵体不跟转体"，拿到默认 0 也照样绿）。
补了行尾锚定的第二条 sed + **逐文件零输出**的核对循环。

**5. 与另两份计划的关系**：`2026-09-25-ammo-rollback-fidelity.md`（计划 1）**已实施完毕**
（`_restore_mag` 删除、`pending_mag` 落地、`kh_l4_probe` 的两条断言已删）——**本计划不与之冲突**，
且 `_close_enough` 不比 `mag`、`sync_soft_state` 只比结构这两条**本计划一行未动**。
`2026-09-25-laser-friendly-fire.md` 碰 `server/match_state.gd` / `laser_weapon_base.gd` /
`tests/laser_team_probe.*`；本计划只在 `laser_team_probe.gd:169` 改一个上行键名，**无重叠**。

**6. 已知边界与残余（登记，不修）**

- **`wslot`（c2 整态键）不改**：第三条协议面，spec §3 自己把它排除在外。它是本计划唯一"明知是
  `slot` 一词而留着"的生产标识符，与"上行 `winst` / 下行 `type_id`"并不同义冲突（它确实是类型 id）。
- **§4.1 不改两端 `held` 的排序**：`WeaponInventory.held` 仍是"按获得顺序"，服务器与客户端的顺序
  **仍可能不同** —— 本计划只是让切枪**不再依赖**它。任何将来"按下标跨端通信"的新代码都会重新引入
  这个洞；本计划没有机制阻止它（除了词汇纪律本身）。
- **`--ai-roles` 的 AI 走 `AiInputSource`**：它的 `_switch_index_raw()` 恒 0、也不覆写
  `_switch_inst_raw()` ⇒ 新协议下 AI **仍然不切枪**（与今天逐字相同，不是回归）。
- **`MAX_WEAPONS > 4` 时第 5 把没有数字键**（spec §6.1，且 spec 引的"5/6 号键动作还在"**是假的**：
  `project.godot` 的 input 段只有 `1`–`4`，`kh_l3_probe.gd:116-118` 还**反向断言** 5–0 不得有动作）。
  本计划不动键位。
- **`tests/kh_l3_probe.gd:30-37` 的 `EXPECTED` 六行表**（spec §附的 ❌ 之一）本计划不碰 ——
  它归"加第 7 把枪"那份计划（§4.2）。
