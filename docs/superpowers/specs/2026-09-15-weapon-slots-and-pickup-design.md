# 武器槽位 + 捡起/丢弃 设计

2026-09-15。前置现状考察见本文 §2（几条与直觉不符的现状，改之前先读）。

## 1. 目标与非目标

### 目标

1. **8 格武器槽位**：玩家有一个 8 格容量预算，轻/中/重武器分别占 2/3/4 格；另有**独立的 4 把上限**（不是容量推出来的）。左下角 4×2 方格 UI 实时显示占用，四种状态用三种颜色区分。
2. **键位 1-4 切枪 + 滚轮切枪**：四个持有位；滚轮在持有的武器之间循环。
3. **武器可丢可捡**：武器落地是一个有矩形碰撞箱的物理实体（只与地形/其它掉落物碰撞，不与玩家/敌人/子弹碰），按 F 捡、长按 Q（≥2s）丢。
4. **初始状态重做**：单机开局空手、12 把武器散落全图；PvP/大乱斗每人随机 1 把、其余散落。
5. **联机同步**：地面武器与背包由服务器权威，PvP 与大乱斗同一条链路。

### 非目标

- 敌人掉落武器（本设计不做）。
- 地面武器被爆炸推开 / 被子弹打飞（不做——子弹碰撞掩码不含掉落物层，天然穿过）。
- 武器在地面上旋转（保持水平，矩形碰撞箱因此不必处理旋转；见 §5.3）。
- 拾取/丢弃的**客户端预测**（用户已裁定走"等服务器确认"，见 §6.4）。
- 第 5 个持有位（5/6 数字键退休，但 InputMap 动作保留不删，见 §4.5）。

## 2. 现状考察（改之前必须知道的几条）

| # | 事实 | 位置 | 影响 |
|---|---|---|---|
| 1 | `tier`（轻/中/重）**字段已存在**，6 把枪已各自标注：手枪/霰弹=LIGHT、步枪/激光=MEDIUM、重狙/榴弹=HEAVY | `weapon_base.gd:4,14`；各 `.tscn` 的 `tier =` | 正好 2/2/2，与 2/3/4 格一一对应。**但 gameplay 零消费**，全仓只有 `enemy_logic_smoke.gd:335` 读它 |
| 2 | `WeaponBase` **没有任何 `_process`/`_physics_process`**，`tick()` 完全由 Player 显式驱动 | `weapon_base.gd:207` | 一个没人驱动的武器实例**天然静止**。这是 §5 方案 B 能成立的关键前提 |
| 3 | 武器是纯 `Node2D`（根 + `Sprite2D` + `Muzzle` Marker2D），**全无碰撞体/物理体** | `scenes/weapons/*.tscn` | 加碰撞箱是从零加，没有旧结构要拆 |
| 4 | 武器是 `Player` 的子节点，**继承根的 `scale = 2.5`** | `player.tscn:123`、`weapon_base.gd:348,373` | 手持与落地视觉差 2.5 倍。**任何方案都得在某处处理一次** |
| 5 | 玩家朝向走 `animator.flip_h`，**不用 `scale.x`** | `player.gd:309` | `WeaponSlot` 不翻转，武器自己 `scale.x = facing` |
| 6 | `_current_slot` 存的是**武器类型 id（1-6）**，不是背包位置；快照 `weapon` 字段、`capture_state` 的 `wslot`、副本 `_swap_weapon(slot)` 全按类型 id | `match_snapshot.gd:23`、`player.gd:458`、`player_replica.gd:98,109,145` | **只要背包里仍以类型 id 标识每把枪，PvP 协议与副本一行都不用改** |
| 7 | 滚轮切枪**已实现**，但被 `Settings.wheel_switch` 卡着且**默认 false** | `player.gd:623`、`settings.gd:23` | "添加滚轮切枪"其实是"改默认值 + 改循环范围" |
| 8 | 数字键不走 `Input.is_action_*`，走 `input_source.get_weapon_slot_pressed()` | `player.gd:159` | 改键位范围要动 `InputSource` 三件套，不是动 `_unhandled_input` |
| 9 | **没有 `F` / `Q` 动作** | `project.godot [input]` | 要新增，且要进 `Settings.REMAPPABLE_ACTIONS` |
| 10 | `_mag_state` **按槽位号记账** | `weapon_component.gd:24,111,124` | 新系统里"槽位"语义变了；且**允许重复武器**（用户裁定）意味着按类型记账会串——见 §4.3 |
| 11 | `player.gd:147` 在 `_ready` 里**硬编码** `equip("1")` | `player.gd:147` | 不是 `default_slot()`；单机靠 `level_0.gd:239` 事后纠正，服务器靠 `match_host.gd:81`。**新增"开局给什么枪"的入口时这是绕过点** |
| 12 | 散点布点算法**长在 `RoyaleHost` 实例上**（`plan_spawns` / `_spawn_candidates` / `_floor_cells`） | `royale_host.gd:72-215` | 单机用不了。判据本体 `MazeGenerator.is_floor_cell_with_headroom` 已是共享的 |
| 13 | 开局三载荷踩过"客户端正在切场景 → RPC 静默丢失"的坑，解法是**客户端 `_ready` 末尾主动拉取**（`match_sync`） | CLAUDE.md §网络；`match_sync_probe` 有反向断言 | **初始地面武器分布必须走 `match_sync` 一起下发**，不能靠 `weapon_spawned` 推 |
| 14 | 子弹 `collision_mask = 5`（地形+敌人） | `bullet_base.gd` | 不含新的掉落物层 → 子弹天然穿过地上的枪，无需额外处理 |

## 3. 已裁定的设计决定

| 项 | 决定 |
|---|---|
| 容量 | 8 格；轻 2 / 中 3 / 重 4 |
| 持有上限 | **4 把**，与容量是**两条并行闸门**（容量给 100 也是最多 4 把） |
| 放不下时 | **替换手上当前那把**（被换下的掉在玩家脚下） |
| 重复武器 | **允许**，无特例（可以有 2 把手枪甚至 4 把） |
| 单机初始 | 玩家**空手**；12 把（每种 2 把）随机散落全图 |
| PvP / 大乱斗初始 | 每人随机 1 把进背包；其余散落；同样每种 2 把共 12 把 |
| 复活 | **除背包内随机一把外，其余全丢在死亡点**；保留的那把从背包里随机抽 |
| 残弹 | **跟着枪走**（丢下剩 3 发，捡回来还是 3 发） |
| 地面实体 | 方案 B：独立 `weapon_pickup.tscn`（`CharacterBody2D` 根） |
| 联机手感 | 方案 ①：不做客户端预测，按 F/Q 只上行，等服务器确认 |
| 格子 UI | 单机 HUD 与 PvP/大乱斗 HUD **都要** |
| 滚轮 | `Settings.wheel_switch` **默认改 true**；数字键只认 1-4；5/6 键退休 |

## 4. 阶段 A：背包与槽位

### 4.1 新模块 `core/sim/weapon_inventory.gd`

`class_name WeaponInventory extends RefCounted`。纯逻辑、无 autoload、可 `-s` 测。

```gdscript
# tier 数值刻意与 WeaponBase.Tier 对齐(LIGHT=0/MEDIUM=1/HEAVY=2),
# 但**不 import weapon_base.gd** —— 它的 @export 默认值 preload 了 bullet.tscn,
# 会连带把 autoload 拖进 -s 冒烟(见 tests 里"autoload 尚未实例化"的注释)。
# 对齐关系由 enemy_logic_smoke 的断言钉住。
const TIER_LIGHT := 0
const TIER_MEDIUM := 1
const TIER_HEAVY := 2
const SLOT_COST := {TIER_LIGHT: 2, TIER_MEDIUM: 3, TIER_HEAVY: 4}
const MAX_WEAPONS := 4
const CAPACITY := 8
```

**背包条目**（`held: Array[Dictionary]`），每条：

```gdscript
{"type": int, "inst": int, "mag": int}
#  type = 武器类型 id(1-6,与 WeaponComponent.WEAPONS 同键)
#  inst = 实例序号(全局单调递增),用来区分同类型的两把(残弹各记各的)
#  mag  = 该把当前的残弹
```

`inst` 是必需的：用户裁定**允许重复武器**，而残弹要跟着具体那把枪走。按类型记账会让"丢了一把空弹手枪、捡起一把满地手枪"变成免费换弹。

**残弹不再走 `_mag_state`**：那套 `_mag_state` + `_restore_mag.call_deferred` 的时序竞态（`weapon_component.gd:103-111` 的注释）整体删除，残弹直接存在背包条目里——切枪时把 `mag_ammo` 写回条目，`equip` 时从条目恢复。

**API**：

```gdscript
func _init(tiers: Dictionary) -> void          # 传入 type_id -> tier 表(生产是 WeaponComponent.TIERS,测试传假表)
var held: Array[Dictionary]

func used_slots() -> int                        # Σ cost
func can_hold(type_id: int) -> bool             # held.size() < 4 且 used_slots()+cost <= 8
func has_room_for_any() -> bool
func add(type_id: int, mag: int) -> int         # 返回新条目的 inst;调用方须先 can_hold
func remove_at(index: int) -> Dictionary        # 返回被移除的条目
func index_of_inst(inst: int) -> int            # -1 = 不在
func first_index_of_type(type_id: int) -> int   # -1 = 不在
func slot_start(index: int) -> int              # 第 index 把的起始格(紧凑排布)
func total_cost_of(types: Array) -> int         # 纯静态查询,不依赖 held
```

**紧凑排布**：第 `i` 把占据格子 `[slot_start(i), slot_start(i)+cost_i)`，`slot_start(0) = 0`。删中间一把后其后所有武器左移——HUD 会看到整段移动，这是接受的表现（换来实现上的"格子永不空洞"）。

### 4.2 tier 注册表

`WeaponComponent` 新增（与 `DISPLAY_NAMES` 同款做法，单一来源、不实例化场景）：

```gdscript
const TIERS: Dictionary = {
    1: WeaponBase.Tier.LIGHT,    # 手枪
    2: WeaponBase.Tier.MEDIUM,   # 步枪
    3: WeaponBase.Tier.HEAVY,    # 重狙 M82A1
    4: WeaponBase.Tier.LIGHT,    # 霰弹 S686
    5: WeaponBase.Tier.HEAVY,    # 榴弹发射器
    6: WeaponBase.Tier.MEDIUM,   # 激光枪
}
```

与 `.tscn` 里的 `tier =` export **重复**，这条重复是刻意的（避免为了问"这枪多重"而实例化一个会 preload 子弹的武器场景）。**由 `enemy_logic_smoke` 的断言钉住两边一致**，漂移即红。

### 4.3 `WeaponComponent` 改造

- `_current_slot: int` **语义不变**（当前手持的**类型 id**）。快照 `weapon` 字段、`capture_state` 的 `wslot`、副本 `_swap_weapon` 因此全部零改动。
- 新增 `inventory: WeaponInventory`，`_init` 里 `WeaponInventory.new(TIERS)`。
- **删** `_mag_state`、`_restore_mag`、`_restore_mag.call_deferred` 整条链（残弹进背包条目）。
- `enabled_slots`（禁用武器闸门）**语义不变**，仍按类型 id。被禁的类型不出现在初始分布里、不能被捡。
- `equip(slot: String)` 语义调整为：按类型 id 切换到背包里**第一个**该类型的条目；**若背包里没有该类型，则加入一条**。
  - 这条"没有就加"是**必需的**，不是便利：联机不做客户端预测（§6.4），服务器说"你现在有重狙"时客户端背包里可能还没有它；`restore_state` 重放 `wslot` 时会走到这条路径。**这也是 `inv` 必须进 `capture_state` 的原因**（§6.5）。
- 新增 `equip_index(i: int)`：按背包位置切枪。数字键 1-4 与滚轮走这条。
- `cycle_slot(dir)` / `_peek_cycle(dir)`：循环范围从 `enabled_slots`（1-6 的启用表）改为**背包内的位置序列**。
- 新增：
  ```gdscript
  func pick_up(type_id: int, mag: int) -> int   # 返回被替换掉的类型 id(0=没替换,直接放入)
  func drop_current() -> Dictionary             # 取出当前条目 {type, mag};背包随之少一条
  func random_keep_one() -> Array[Dictionary]   # 复活用:随机留一条,返回其余(供生成掉落物)
  func snapshot_inventory() -> Array            # capture_state 用
  func restore_inventory(entries: Array) -> void
  ```
- `refill_current_weapon()` / `reset_mag_state()` 按新模型重写（前者改为"把当前条目 mag 补满"）。

### 4.4 加新武器时的改动面（更新 CLAUDE.md 的那一行）

现在"加新武器 = 一个继承 WeaponBase 的 .tscn + `WEAPONS` 加一行"。新系统下变成**三行**：`WEAPONS` + `DISPLAY_NAMES` + `TIERS`。三条漂移各自的表现不同（前两条是 UI 显示错，第三条是**容量算错**），所以 §8 的断言要一次钉齐三条。

### 4.5 输入

- `project.godot [input]` 新增 **`F`**（physical 70）、**`Q`**（physical 81）。动作名用大写字母，与现有 `R` 的约定一致。
- `Settings.REMAPPABLE_ACTIONS` 加 `"F"`、`"Q"`。
- **`Settings.wheel_switch` 默认值改 `true`**（`settings.gd:23`）。
- 数字键**动作注册保留**（InputMap 里 `1`~`0` 一个都不删），但 `InputSource._weapon_slot_raw()` 的三个实现改为**只回 1-4**，5/6 返回 0。理由：删 InputMap 动作没有任何收益，而留着以后想开第 5 个位时不必再动 `project.godot`。
- `PlayerInput` 新增两个读口：
  ```gdscript
  func is_pickup_pressed() -> bool       # F 的按下边沿 (联机走包)
  func is_drop_pressed() -> bool         # Q 长按满 2s 后的那一次边沿 (客户端判定,见 §5.6)
  ```
  三种实现（`LocalInputSource` / `PacketInputSource` / `AiInputSource`）各自实现。`AiInputSource` 恒 `false`——**AI 不捡也不丢枪**（大乱斗补位 AI 开局照样随机 1 把，复活照样走 §7.3）。
  - `frozen` 短路契约照旧：冻结期 F/Q 读口也返回中性值。
- 包协议新增两位（`packet_input_source.gd`）：
  ```gdscript
  const BIT_PICKUP := 32
  const BIT_DROP   := 64
  ```
  ★ **加位 = 改协议，两端必须同版本**（文件里 `BIT_RELOAD` 已有同款注释）。

### 4.6 HUD 格子控件

新控件 `ui/weapon_slots.gd`（`class_name WeaponSlots extends Control`）：

- `setup(player: Node)` / `refresh()`；订阅 `weapons.weapon_changed` 与一条新的 `inventory_changed` 信号。
- 4 列 × 2 行，每格 **32×32**，格间距 **4**（整体 140×68，与现有左下角武器显示区尺寸兼容）。尺寸都是 16 的倍数，避开 `kh_l4`/`kh_l5` 的字号规范扫描。
- 三种颜色**在 `ui/ui_factory.gd` 新增**（CLAUDE.md 硬约定：颜色只在那里定义）：
  ```gdscript
  C_SLOT_EMPTY  = #333B45   # 未占据:淡灰
  C_SLOT_FILLED = #7FB8B8   # 已占据:淡青
  C_SLOT_ACTIVE = #2F9E9E   # 手持那把占的格:深青(高饱和)
  ```
  ★ **"深青"按"高饱和/更醒目"实现，不按"更暗"**：这几块 UI 垫在**不透明深底板**上（`panel_box()`），若手持格比已占格更暗，视觉上反而更弱，出现"当前武器最不显眼"的倒挂。**真正的不变量是：手持格必须比已占格对比度更高**。色值以实图为准（用户 2026-09-15 的 HUD 改色就是这么定的）。
- **不画键位号**：从左到右的顺序即键位 1-4 的顺序，再画数字是冗余（且 32px 格里塞 16px 字会挤）。
- **控件必须自包含**：`WeaponSlots` 是一个能自己 `new()` 出来、挂到任意 `CanvasLayer` 下就能用的控件，**不依赖任何 HUD 的继承关系**。因为 `PvpHud` 与 `RoyaleHud` 是**并列的两个 `CanvasLayer extends`**（`pvp_hud.gd:1-2` / `royale_hud.gd:1-2`），**没有继承关系**，不存在"大乱斗复用 PvP 那块"这条路。定位参数抽成控件内的常量，三处（单机 / 1v1 / 大乱斗）引用同一组值。
- 单机（`ui/hud.gd`）：左下角重排——`WeaponSlots` 与原有"图标 + 中文名 + 残弹"那一排构成一个整体块，共用一个 `PanelContainer` 底板（底板继续遵守全局的"黑 0.1"）。
- 1v1（`ui/pvp_hud.tscn` 挂 `PvpHud`）与大乱斗（`RoyaleHud`）各自 `WeaponSlots.new()` 挂到自己的 `CanvasLayer` 下，位置用控件内的同一组常量。

## 5. 阶段 B：地面武器

### 5.1 新场景 `scenes/weapons/weapon_pickup.tscn`

根 **`CharacterBody2D`**，脚本 `scenes/weapons/weapon_pickup.gd`（`class_name WeaponPickup`）：

```
WeaponPickup (CharacterBody2D)      ← 本脚本
  CollisionShape2D                  ← 运行时由 sprite 像素生成(见 §5.2)
```

**视觉**：`_ready` 里把 `WeaponComponent.WEAPONS[type_id]` 实例化，作为**哑子节点**挂上。它不会动——`WeaponBase` 没有 `_process`，`tick()` 没人调（§2 事实 2）。这是方案 B 能避免"另做一套武器外观"的原因。
- 视图缩放：哑武器实例自己 `scale.x = 1`；`WeaponPickup` 根设 `scale = Vector2(2.5, 2.5)` 以对齐手持时的世界尺寸（§2 事实 4）。**2.5 这个数字只在这里出现一次**，出处写进注释。

**字段**：

```gdscript
@export var type_id: int = 1      # 武器类型 id(1-6)
var inst: int = 0                 # 全局唯一 id(与背包条目的 inst 同一命名空间,服务器分配)
var mag: int = 0                  # 落地时的残弹("残弹跟着枪走")
var drop_velocity: Vector2 = Vector2.ZERO   # 初速,供客户端本地模拟
```

入 `weapon_pickup` 组。

### 5.2 像素碰撞箱：`core/present/sprite_bounds.gd`

`class_name SpriteBounds extends RefCounted`，静态工具。

```gdscript
static func from_sprite(spr: Sprite2D, alpha_threshold: float = 0.05) -> Rect2
```

- 取 `spr.texture` 的 `Image`（`is_compressed()` 先 `decompress()`，`WeaponIcons.silhouette` 已有同款处理可参照）。
- 若 `spr.region_enabled`，只扫 `region` 矩形。
- 求 `alpha > threshold` 像素的包围盒，**以 `spr` 的局部原点为参考**返回 `Rect2`（不是贴图坐标系）。
- 结果按 `(texture 引用, region)` 缓存（静态 `Dictionary`）。

**注意与手持态的差异**：`weapon_base.gd` 的 sprite 有 `_base_sprite_pos` 偏移、且会因换弹/后坐抖动（`weapon_base.gd:134`），还有 `facing` 的 `scale.x`。地面态一律用 **`facing = 1`、无抖动**的基准位置求一次即可。

### 5.3 物理与碰撞层

**新碰撞层 4「掉落物」**（值 8）。现在只用了 1/2/3（地形/玩家/敌人）。

| | `collision_layer` | `collision_mask` |
|---|---|---|
| `WeaponPickup` | 8 | `1 \| 8` = 9（地形 + 其它掉落物） |

- 玩家 `mask = 5`、敌人 mask 不含 4 → **天然不碰**（玩家/敌人不会被地上的枪挡住，也不需要改它们的掩码）。
- 子弹 `mask = 5` → **天然穿过**（地上的枪不挡子弹）。
- ★ **PvP 有一处要核**：`match_host.gd:37` 与两端客户端给玩家补了 `collision_mask |= 2`（为对手互撞）。**2 是玩家层，不是掉落物层**，两条不冲突——但实现时要确认这两处 `|=` 没有被顺手写成 `|= 2 | 8`。

**运动**（自写 `_physics_process`，与仓里敌人同款风格）：

```
重力 → velocity += gravity * delta
水平摩擦 → velocity.x *= exp(-friction * delta)   # 落地后;空中用较小的 air_drag
velocity.y 若 abs < stop_eps 且在地面 → 置零
move_and_slide()
取模回 canonical: 位置 = wrap_to_range(位置)
```

**不旋转**：矩形碰撞箱 + 横版简化。地面态恒定 `rotation = 0`、`scale.x = 1`。

★ **停止位置必须与"何时开始模拟"无关**——这是 §6.4 "客户端本地模拟落体"能对上的前提。要求：摩擦用**速度衰减 + 阈值置零**（不是"滑行固定时长"），且 `move_and_slide` 的位移不受帧率影响。指数衰减 + 固定物理帧下，总位移 ≈ `v0/k`，起点时刻不同只带来亚像素级离散误差。**若日后把摩擦改成"按时间停"，这条前提就破了，联机端会出现"看着够不着/看着够得着"的偏差。**

### 5.4 拾取判定：一次 F 只捡**最近的一把**

新模块 `core/sim/ground_weapon_field.gd`（`class_name GroundWeaponField extends RefCounted`），纯逻辑、可 `-s` 测：

```gdscript
func add(entry: Dictionary) -> void        # {inst, type_id, mag, pos, vel}
func remove(inst: int) -> Dictionary
func get_entry(inst: int) -> Dictionary
func nearest_within(pos: Vector2, radius: float, exclude: Array = []) -> Dictionary
    # 环面最短距离(GridPathfinder.toroidal_delta_px),并列时按 inst 升序 —— 稳定排序
```

**"多把武器距离太近、捡不起来某些枪"的解法就是这条规则本身**：

- 每次按 F **只捡距离最近的那一把**，不做"范围里能捡的全捡"。
- 由于本设计的替换规则（§3）保证**任何武器都捡得起来**（要么直接放入，要么替换手上那把），不存在"最近那把捡不动、把后面能捡的挡住了"的情形。连着按 F 就能把叠在一起的一堆逐把捡走。
- 并列距离（两把完全重合）按 `inst` 升序，保证确定性——否则两台客户端可能各自挑中不同的一把。

**拾取半径**：`PlayerParams.weapon_pickup_radius = 64`（1 格）。

### 5.5 丢弃

- 长按 **Q ≥ `PlayerParams.weapon_drop_hold_time`（2.0s）** 触发。松手未满则取消，无副作用。
- 丢的是**手上当前那把**（`drop_current()`）。
- 生成 `WeaponPickup` 于玩家身前：`pos = 玩家位置 + Vector2(facing * 24, -8)`，
  `velocity = Vector2(facing * weapon_drop_speed, -weapon_drop_up)`。
- 参数全部进 `PlayerParams`：`weapon_drop_hold_time = 2.0`、`weapon_drop_speed = 400.0`、`weapon_drop_up = 220.0`、`weapon_ground_friction = 12.0`、`weapon_air_drag = 0.4`。
- **长按反馈**：手上武器轻微抖动 + 一条丢弃进度条（复用 `ui/hud.gd` 现有换弹进度条的同款画法）。**没有反馈的长按在两秒尺度上是不可用的**——玩家会以为按键没生效。

### 5.6 F/Q 的边沿语义与判定位置

- **F**：本地玩家按下的那一物理帧 → 一次边沿。`LocalInputSource` 直接读 `Input.is_action_just_pressed("F")`；`PacketInputSource` 读 `pressed` 位里的 `BIT_PICKUP`。
- **Q**：**客户端自己累计按住时长**，满 2.0s 的那一刻发一次边沿（`BIT_DROP`）。**不把"按住"上行**——长按是纯本地判定，上行的只是一个完成信号。这样包协议只多两个位，不需要为 Q 再加一个 held 位。
  - 触发后必须**等 Q 松开**才能再次触发（否则按住不放会连丢）。

## 6. 阶段 C：联机

### 6.1 权威归属

**服务器（`MatchHost`）权威**：地面武器表、每个玩家的背包内容、当前手持类型。客户端只负责渲染与上行输入。

### 6.2 新事件

| 事件 | 载荷 | 通道 |
|---|---|---|
| `weapon_spawned` | `{inst, type_id, mag, pos, vel}` | `NetBus`，reliable |
| `weapon_removed` | `{inst, by_role}` | `NetBus`，reliable |

两条都走 **`NetBus`**（不是 `NetBusExt`）——与 `beam_fired` 同款理由：KH 侧 `net_bus_ext.gd` 里有同名遗留重复，接收端挂错节点会**静默 no-op**（对手的枪凭空消失且不报错）。这一点写进探针（§8）。

**为什么是事件而不是每帧快照**：地面武器最多 12 把，进 60Hz 快照会让大乱斗本已存在的"快照体积随人数线性增长"问题进一步恶化（CLAUDE.md §已知风险 1）。掉落/捡起是低频事件（一局几十次），事件 + 本地模拟足够。

### 6.3 初始分布走 `match_sync`，不走 `weapon_spawned`

★ **这是本阶段最容易踩的坑**。开局那批地面武器若用 `weapon_spawned` 逐条推给客户端，会**精确复现** CLAUDE.md 记录过的事故：客户端在 `match_start` 后那一帧正在帧末切场景，订阅方一个都不存在 → **静默丢失**（当年是三载荷丢失，现在是整批地面武器消失）。

**做法**：服务器的 `match_sync_data` 载荷增加一个 `ground_weapons` 字段（`Array[Dictionary]`，与客户端 `GroundWeaponField.add` 的条目同构），客户端 `_ready` 末尾主动 `rpc_id(1, "match_sync")` 拉取时一并拿到。这与现有 `names`/`hues`/`options`/`roles`/`spawns` 走的是**同一条**路径，不再新增投递路径。

**之后的动态掉落/捡起**才走 `weapon_spawned` / `weapon_removed`——那时客户端早就订阅好了。

### 6.4 不做客户端预测

按 F/Q 只上行，客户端**等服务器事件回来才动背包**。

- **延迟**：局域网 1 个 RTT（<50ms），捡枪一局十几次，无感。
- **落体视觉**：客户端收到 `weapon_spawned` 后用载荷里的 `pos` + `vel` **本地模拟**落体（两端同一套 §5.3 的运动代码与参数）。因为 §5.3 保证了"停止位置与何时开始模拟无关"，客户端即使晚 1 个 RTT 才开始，落点也与服务器一致。
- **抢枪**：两个玩家同时按 F 抢同一把 → 服务器裁决，输的一方**本地从未预测过**，所以不需要回滚，只是没收到该事件而已。这正是选方案 ① 的主要收益。
- **本地即时反馈的缺失**要补偿：按 F 那一帧给一个"拾取尝试"的音效/提示（不改变背包状态），避免按下到落地之间的静默。

### 6.5 `capture_state` 增补 `inv`

**即便不做客户端预测，背包也必须进 `capture_state`**：

`restore_state` 会 `equip(str(wslot))`（`player.gd:514`）。若不重建背包，重放时可能：
- 切到客户端背包里没有的类型 → 走到 §4.3 的"没有就加"分支，**凭空造出一把服务器没有的枪**；
- 或背包里有而服务器没有 → 重放出的开火/弹夹与权威不符。

**做法**：

```gdscript
# player.gd capture_state()
"inv": weapons.snapshot_inventory(),   # Array[Dictionary],每条 {type, inst, mag}
```

`restore_state` **先** `weapons.restore_inventory(st.get("inv", []))` **再** `equip(wslot)`——顺序不能反。

★ **`inv` 进 capture/restore，但绝不进 `_close_enough` 的比对**——与 `mag_ammo`/`_reloading`/`_reload_t` 同口径（CLAUDE.md 已记录这条纪律）。否则每帧判分歧，变成无限回滚循环。

### 6.6 服务器侧的执行点

`MatchHost` 在 `_physics_process` 消费输入包时（`match_host.gd:106-130`）：

```
若 pkt.pressed & BIT_PICKUP:
    最近的可拾取武器 = field.nearest_within(该玩家位置, radius, exclude=[该玩家刚丢下的])
    若有 → 拾取: player.weapons.pick_up(type, mag); field.remove(inst)
          若返回了被替换的类型 → 在同一位置 field.add(被替换的枪) + 广播 weapon_spawned
          广播 weapon_removed{inst, by_role}
若 pkt.pressed & BIT_DROP:
    entry = player.weapons.drop_current()
    若 entry 非空 → field.add(...) + 广播 weapon_spawned
```

★ **`exclude` 的理由**：玩家丢枪后枪就落在身前 `24px` 处，若同一帧（或紧接着）按 F，会立刻捡回来。`exclude` 传"该玩家最近一次丢下的 inst"，且该 inst 在**离开拾取半径或经过了 `weapon_pickup_self_delay`（建议 0.5s）之前**不参与判定。**只做 `exclude` 不做延时是不够的**：玩家可以丢完往前走一步再按 F，把刚丢的枪原地捡回，形成"丢-捡"抖动。

### 6.7 客户端侧

- 维护本地 `GroundWeaponField` + 一组 `WeaponPickup` 节点（`inst → 节点`）。
- 收到 `weapon_spawned` → 建节点（本地模拟落体）；收到 `weapon_removed` → 删节点。
- 渲染位置跨接缝走 `GridPathfinder.anchor_to_nearest`（与敌人/子弹同款，**不是** `wrap_to_range`）——否则相机跨接缝时地上的枪会"消失"。
- 背包状态由快照与事件共同驱动，**不做本地预测**（§6.4）。

## 7. 初始状态与复活

### 7.1 抽公共布点工具

把 `royale_host.gd:185-215 plan_spawns` 的几何部分抽成静态工具：

```gdscript
# core/sim/grid_pathfinder.gd
static func spread_cells(cells: Array, count: int, clearance: int) -> Array
    # 洗牌 → 贪心取环面距离(toroidal_dist) ≥ clearance 的格 → 不足则 clearance 逐级 -5 放宽
```

`RoyaleHost.plan_spawns` 改为调它（保持"不在广播后重调"的既有纪律——内部有 `shuffle()`）。

**地面武器布点**复用同一函数，用同一套 `_spawn_candidates()`（头顶 2 格净空 + 左右邻格空 + 同层连通区 ≥ `OPEN_AREA_MIN`），避免"枪落在走不出去的密封小间里"。

**均匀性**：`spread_cells` 的环面距离贪心就是"尽量均匀"的实现。12 把比人数多得多，`clearance` 会逐级放宽，最终分布是"洗牌后尽量互相远离"。

`plan_spawns` 里的**判据本体** `MazeGenerator.is_floor_cell_with_headroom` 已是共享的，不动。

### 7.2 单机

- ~~**开局空手**~~ → **★ 已改（2026-09-15 用户实机后裁定：单机开局携带手枪）**：`player.gd` 的硬编码 `equip("1")` 删掉；改为 `WeaponComponent` 暴露 `set_initial_inventory(types)`，由调用方决定：
  - `level_0.gd`（单机）→ `_give_starting_weapon()` 发 `[default_slot()]`（★ 排在 `set_enabled_slots` **之后**，且用 `default_slot()` 而非写死 `"1"`：先给再禁会把手上那把判成空手，写死则在禁用手枪时发一把本局不让用的枪）
  - `match_host.gd`（联机）→ 传**一条随机武器**（§7.3）
  - `player.tscn` 自身的 `_ready` 仍是**空背包**（无模式默认）；发什么枪由各模式自己决定，两条路不打架。
- 12 把（每种 2 把）散落全图。**禁用武器（`RunOptions.disabled_weapons`）不出现在分布里**。
- 开局空手时 HUD 武器区显示"空手"，无法开火（`weapon_component.tick` 在 `_weapon == null` 时本就不跑，`weapon_component.gd:170`）。
- **按 R 重启（`restart_single`）**：语义定为"完全重开"——清空背包、清空并重新散落 12 把。与现有行为（还原可破坏砖、清子弹/敌人重刷、玩家回出生点满血）一致。

### 7.3 PvP / 大乱斗

- **开局**：12 把（每种 2 把）；每个玩家（含 AI 补位）从这 12 把里随机拿 1 把进背包，其余散落。N 人局 → 地上 `12 - N` 把。
- **复活**（`match_round.gd:65 _respawn_player` 与 `royale_host.gd:436` 的覆写）：
  1. `random_keep_one()` 从背包随机留一条；
  2. 其余条目在死亡点生成掉落物（带初速散开，`inst` 递增）；
  3. 背包 = `[保留的那条]`；`equip` 它；
  4. 满血 / 防水 / 位置回出生点（现有逻辑不动）。
  - **不补满弹**：与现状一致（现在服务器复活只 `equip(default_slot())`，弹夹走残弹恢复），且与"残弹跟着枪走"一致。
- **换局**（`match_round.gd:106 _reset_world_and_clear_dynamics`）：除现有的"还原可破坏砖 + 清子弹"外，增加**清空地面武器并重新散落 12 把 + 每个玩家背包重置为随机 1 把**。理由：现有的换局纪律是"两端每局从同一基线出发，无幽灵墙/跨局残留"，装备同理。
- **1v1 与 8 人大乱斗共用同一条链路**（批次 5 之后两者同走 C2，不另开分支）。

## 8. 测试计划

**遵循仓内纪律**：用户自己跑测试；`-s` 脚本不得静态引用会连带 preload autoload 的脚本。

| 探针 | 类型 | 钉什么 |
|---|---|---|
| `tests/weapon_inventory_smoke.gd` | `-s` | 容量/4 把上限**两条闸门各自独立生效**；放不下时替换；紧凑排布 `slot_start`；**允许重复**（两把同类型各有各的 inst/mag）；删中间条目后索引与残弹不错位 |
| `tests/ground_weapon_field_smoke.gd` | `-s` | `nearest_within` 的**环面最短距离**（跨接缝）；距离并列时按 `inst` 升序（确定性）；半径外不选中 |
| `tests/sprite_bounds_smoke.gd` | `-s` | 像素包围盒：含透明边的贴图、`region_enabled` 的图集切片、全透明返回空矩形 |
| `enemy_logic_smoke.gd`（补断言） | `-s` | ① `WeaponComponent.TIERS` 与 6 个 `.tscn` 的 `tier =` export **逐条一致**；② `WeaponInventory.TIER_*` 与 `WeaponBase.Tier` 数值对齐；③ `WEAPONS`/`DISPLAY_NAMES`/`TIERS` 三个注册表**键集相同**（加新武器漏填其一的守卫） |
| `tests/kh_l3_probe.gd`（**重写**） | `extends Node`，场景 | 现有那一大批 `enabled_slots`/`cycle_slot`/残弹记忆断言要按新语义改：循环范围变成背包位置、残弹记账变成 per-inst。**加反向断言**：`_mag_state` 一族标识符一个都不许复活；`BIT_PICKUP`/`BIT_DROP` 的位值不许被改动（改位 = 改协议） |
| `tests/kh_l3_visual_probe.gd`（扩） | 真实渲染 | 4×2 格子的**三种颜色各在正确位置**：未占=灰、已占=青、**手持那把的格=高对比度青**。双向断言（该青的要青，不该青的一个都不能有）——沿用现有 `_bright_in`/`_gold_in`/`_accent_in` 的写法 |
| `tests/weapon_pickup_probe.tscn` | 场景 | 真建一个 `WeaponPickup`：碰撞层/掩码是 8/9；**玩家 mask 与子弹 mask 都不含 4**（反向断言：把掉落物放在玩家脚下，玩家照样能走过去、子弹照样穿过）；落体停止位置与起始时刻无关（同一初速、不同延迟启动，落点一致） |
| `tests/pvp_match_smoke.sh`（扩） | 脚本 | 拾取/丢弃链路：上行位 → 服务器裁决 → `weapon_spawned`/`weapon_removed` 到达；`weapon_spawned` 走的是 **`NetBus`** 而非 `NetBusExt`（走错会静默 no-op） |
| `tests/match_sync_probe.tscn`（扩） | 场景 | `match_sync_data` 带 `ground_weapons`；**反向断言**：不得新增"推给正在切场景的客户端"的第二条投递路径 |
| `tests/pvp_twin_smoke.sh`（扩） | 脚本 | `capture_state`/`restore_state` 的 `inv` 往返完整；**`inv` 不在 `_close_enough` 的比对字段里**（反向断言，防每帧判分歧） |
| `tests/pvp_reconcile_smoke.sh`（扩） | 脚本 | 服务器权威改变背包（模拟"别人抢走了我刚捡的枪"）后，客户端 `reconcile()` 一次性收敛，且重放不会凭空造枪 |

## 9. 风险与已知边界

1. **`capture_state` 每帧多一份 `Array[Dictionary]` 拷贝**（最多 4 条）。60Hz 下开销可忽略，但若日后背包条目变复杂（附件、皮肤），要重新评估。
2. **地面武器不进快照** → 客户端的位置是"事件起点 + 本地模拟"。§5.3 的"落点与起始时刻无关"是这条成立的前提，**改摩擦模型必须先回来看这一条**。
3. **12 把地面武器在 8 人大乱斗里只剩 4 把散落**。若日后人数上限提高，`每种 2 把` 的基数要跟着调。
4. **单个 worker 的地面武器表没有上限保护**：理论上玩家可以反复丢/捡造出很多条目。实际受"场上最多 12 把（12 种投放量）+ 每人背包 4 把"约束，不会无界增长——但**这条是推论不是断言**，若日后加"武器箱"之类的投放源要重新论证。
5. **AI 不捡枪**（`AiInputSource` 恒 false）。大乱斗补位 AI 只会用开局随机发的那把，死后也只留随机一把。**`--ai-roles` 首次实跑本就待用户验收**（CLAUDE.md 已登记），本设计不改变这个状态。
6. **5/6 数字键退休但 InputMap 动作保留**。若日后恢复 5 个持有位，只需要改 `MAX_WEAPONS` 与 `_weapon_slot_raw` 的上界，`project.godot` 不用动。
7. **"深青"的语义**（§4.6）：按字面"更暗"实现会让当前武器在深底板上最不显眼。本设计按"高饱和"实现并把不变量定为"手持格对比度最高"。**若用户要的是字面的更暗，需换 HUD 底板色或加描边**。

## 10. 实施顺序

三个阶段各自可独立提交、独立验收；阶段之间建议按序（后一阶段碰前一阶段动过的同一批文件）。

- **阶段 A（背包与槽位）**：§4 全部。验收 = 单机拿现有方式装上武器后，格子 UI/键位 1-4/滚轮/容量与 4 把上限全部正确；武器仍从现有入口获得，不涉及地面实体。
- **阶段 B（地面武器）**：§5 + §7.1/§7.2。验收 = 单机开局空手，能在地图上找到枪、按 F 捡、长按 Q 丢、捡回来的残弹对得上、叠放的枪能逐把捡走。
- **阶段 C（联机）**：§6 + §7.3。验收 = PvP 与大乱斗里开头各拿 1 把、地上有枪、双方都能捡、抢同一把时服务器裁决正确、复活除随机一把外全掉。
