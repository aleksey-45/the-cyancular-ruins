# 2026-09-17 清理批次设计：小地图圆形化 / 单机播报删除 / 武器偏移 / 枪械解卡

分支 `cleanup/stage1-bugs-and-hygiene`。四条互相独立的小改动，一次做完一次验收。

**四条的内容**（用户原话 → 落点）：

| # | 用户原话 | 落点 |
|---|---|---|
| 1 | 把小地图变成以玩家为中心的圆形，只有敌人在小地图范围内才会提示 | `ui/minimap.gd` 绘制层重写 + 新 shader；两个联机挂载点不动 |
| 2 | 删除单机模式下所有击杀播报代码 | `CombatFeedback` 的单机触发链 + 随之死掉的显示名链 + 敌人侧归因写入 |
| 3 | 有一些枪械在根节点上应用了偏移，能不能把偏移改到贴图上，同时清理相关代码 | 根节点偏移归零（A1）+ 删掉 `visual_offset` 整套（A4） |
| 4 | 如果枪械或者鸟穿模了，把它们向上挤 | 只处理枪：新增 `Unstick` + `WeaponPickup` 两处调用 |

**已确认的范围裁定**（用户 2026-09-17 逐条选定）：

- 小地图**只改联机那两个**（1v1 / 大乱斗）。单机 `level_0` 本来就没挂小地图，维持现状。
- 播报删除**连带清掉随之死掉的代码**（显示名链 + 敌人侧归因写入），不是只摘触发那一行。
- 武器偏移走 **A1 + A4**（根节点归零 + 删 `visual_offset`）。
- 穿模**只处理枪**，鸟维持现有的"向下逃逸"逻辑不动。

**§3 中途推翻过一次方案**，理由记在 §3.1 —— 那条是本次唯一"用户先选了、后被技术事实推翻"的地方，别照旧结论改回去。

---

## 1. 小地图 → 圆形、以玩家为中心

### 1.1 现状

`ui/minimap.gd`（114 行，`class_name Minimap extends CanvasLayer`）：

- `_ready` 把 `MazeGenerator.current_grid` 逐格上色成一张 **cols×rows 像素**的 `ImageTexture`（1 像素 = 1 格），按 `CELL_PX = 2.0` 铺成 300×200 的 `TextureRect` 贴在**右下角**（`1920-EDGE-map_w`, `1440-EDGE-map_h`）。
- `_process` 每帧把玩家/敌人点用 `_world_to_map` 贴到那张整图缩略上。
- **整张地图始终全部可见**，对敌人**没有任何范围过滤**（只有 `Settings.pvp_minimap_show_enemy` 总开关 + `is_finite()`）。

挂载点只有两个：`scenes/pvp_game.gd:88`、`scenes/royale_game.gd:74`（同一个 `Settings.pvp_show_minimap` 开关）。

### 1.2 改法

**地形改用着色器画圆**，新增 `ui/minimap_circle.gdshader`：

- 节点从 `TextureRect` 换成 **`ColorRect`，尺寸 `2R×2R`**，挂 `ShaderMaterial`，位置仍是右下角（圆的外接方框距右/下边 `EDGE`）。
- 采样器开 **`repeat_enable`** —— 地图贴图正好是 `cols×rows`、四周无留白，所以 `uv` 越过 1.0 就是"绕到地图另一头"，**环面回绕是免费的**，不需要铺 3×3 副本。

```glsl
shader_type canvas_item;

uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size    = vec2(1.0);   // 格数 (cols, rows)
uniform vec2  center_cell = vec2(0.0);   // 玩家所在格(canonical)
uniform float px_per_cell = 7.0;
uniform float radius      = 140.0;
uniform float ring        = 2.0;         // 圆内缘描边宽度

void fragment() {
    vec2  p = UV * (2.0 * radius) - vec2(radius);   // 以圆心为原点的屏幕像素
    float d = length(p);
    if (d > radius) { discard; }
    // +0.5:uv 按像素归一化,取格中心要半格偏移;越界由 repeat_enable 绕回
    vec2 uv = (center_cell + p / px_per_cell + 0.5) / map_size;
    COLOR = texture(map_tex, uv);
    if (d > radius - ring) {
        COLOR.rgb = mix(COLOR.rgb, vec3(0.05, 0.09, 0.13), 0.75);   // 暗环:不然只读到一团色斑
    }
}
```

**两个可视参数分开**（这是本次唯一的"待定值"入口）：

```gdscript
const RADIUS_PX   := 140.0   # 圆在屏幕上的半径(像素)
const RANGE_CELLS := 20.0    # 圆覆盖的世界半径(格)★ 用户说"之后问我",给值时只改这一行
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0
```

`RANGE_CELLS` 单独改只换缩放、圆在屏幕上的大小不变。

**敌人点：范围过滤 + 环面最短向量**（`_process`）：

```gdscript
var p: Vector2 = _local_provider.call()                       # 玩家世界坐标
var w := float(GameParameters.MAP_WIDTH)
var h := float(GameParameters.MAP_HEIGHT)
mat.set_shader_parameter("center_cell", MazeGenerator.wrap_to_range(p, w, h) / TILE_SIZE)
# 自己:永远在圆心
_dot_self.position = circle_top_left + Vector2(RADIUS_PX, RADIUS_PX) - _dot_self.size * 0.5
# 敌人:最短向量 → 屏幕偏移;超出半径直接不显示
var d := GridPathfinder.toroidal_delta_px(p, enemy_pos, w, h)   # 玩家 → 敌人,世界像素
var s := d / float(TILE_SIZE) * PX_PER_CELL                     # 圆心 → 该点的屏幕像素偏移
var show := Settings.pvp_minimap_show_enemy and s.length() <= RADIUS_PX
```

`toroidal_delta_px(a, b, w, h)` 返回 **a→b**（`grid_pathfinder.gd:20`），所以参数顺序是 `(玩家, 敌人, W, H)`。用它而不是直接相减，**跨接缝的敌人不会被误判成"很远"** —— 这正是"只有范围内才提示"在环面世界里的正确实现。

`_world_to_map()` / `_map_px` / `CELL_PX` 整个删除。

### 1.3 保持不变

`setup()` / `setup_multi()` 两个入口签名、`layer = 131`、`Settings.pvp_show_minimap`（是否挂载）与 `Settings.pvp_minimap_show_enemy`（是否显示敌人点）两个开关的语义、地形三色（空气深色半透明 / 水蓝 / 墙亮灰）。

`_ready` 里 `current_grid.is_empty() → set_process(false)` 的早退**照旧**（没有重建路径这件事是既有脆弱点，本次不动，见 §6）。

### 1.4 守卫

新增 **`tests/minimap_circle_probe.tscn/.gd`**（场景模式、**必须真实渲染**，照 `combat_hud_visual_probe.tscn` 的先例）：

- 往 `MazeGenerator.current_grid` 塞一张合成网格（非空即可），实例化 `Minimap` 并 `setup(...)` 喂假 provider。
- 断言：**范围外的敌人点不显示、范围内的显示、跨接缝的（对玩家取最短向量后在范围内）也显示**。
- 背景铺一块已知纯色，取图后断言**圆外像素仍是背景色**（= `discard` 生效）、**圆内出现地形色**。
- 存一张 PNG。★ **图要自己读**（这个项目里数值全绿而画面错的事出过两次）。

---

## 2. 删除单机击杀播报（连带清理）

### 2.1 关键区分：UI 是共用的，只有触发是单机的

`ui/combat_feedback.gd` 同时承担两件事，**不能整份删**：

| 职责 | 谁在用 | 本次 |
|---|---|---|
| 命中 X 标记 `hit_marker` / `HitMarker` | 单机 + PvP 都在用 | **保留** |
| 击杀文字 + 骷髅 + 连杀 + `Sfx.play("kill")` | **单机**（`notify_enemy_killed`）**与 PvP**（`kill_event` → `kill()`）**共用同一套显示** | **保留**（PvP 还在用） |
| 归因 `attribute` / `attribute_hit` / `ATTRIB_WINDOW_MS` | 大乱斗计分（`royale_host._attributed_killer` 读**玩家**的 `last_damager`）+ 服务器榴弹直击 | **保留** |

**单机播报的唯一触发点**是 `EnemyBase._begin_death()` → `CombatFeedback.notify_enemy_killed(self)`（`enemy_base.gd:238`）——单机**没有** `kill_event` 信号。PvP 走 `NetBus.kill_event` → `pvp_game.gd:169` / `royale_game.gd:193` → `CombatFeedback.kill(名字)`。所以"删除单机播报"= 摘掉 `notify_enemy_killed` 这条链。

### 2.2 删除清单

**A. 触发链**

- `ui/combat_feedback.gd`：删 `notify_enemy_killed()`（:80-95）、`enemy_display_name()`（:98-104）；`attribute()` / `attribute_hit()` / `kill()` 的文档注释里凡是指向"供 notify_enemy_killed 读"的话一并改写（归因现在**只**服务大乱斗计分）。
- `scenes/enemies/enemy_base.gd:236-238`：删调用与那两行注释。

**B. 随之死掉的显示名链**

- `scenes/enemies/enemy_spawner.gd`：删 `DISPLAY_NAMES` 静态表、`display_name_of()`、`_load_registry` 里填它的那一行。
- `data/enemies.json`：删 3 条记录里的 `display_name` 字段。
- `level_editor/sync-enemies.js`：删 map 里的 `display_name` 字段级手抄。★ **键覆盖守卫保留**（`NOT_IN_EDITOR` 机制不动）——它现在覆盖剩下的 4 个字段，仍然拦得住"json 加了字段忘抄"。
- `level_editor/structure-editor.html`：跑 `node level_editor/sync-enemies.js` 重新生成内嵌注册表。★ 编辑器**不用** `display_name`（只按 `id` 查表，见 `enemyById`），删掉安全。
- 注意别误伤同名不同物的东西：`core/config/settings.gd` 的 `_event_display_name`（键位名）、`WeaponComponent.DISPLAY_NAMES`（武器中文名）、`RoyaleHost._display_names`（玩家昵称表）**都与此无关**。

**C. 只服务播报的敌人侧归因写入**

敌人的 `last_damager` meta 原先**只有** `notify_enemy_killed` 一个读者（玩家侧的读者是大乱斗计分，不受影响），所以敌人分支的归因写入全部降级为纯命中标记：

- `core/sim/explosion.gd:27`（敌人分支 `attribute_hit(e, shooter)`）→ `CombatFeedback.hit_marker()`
- `scenes/weapons/laser_weapon_base.gd:216`（`_apply_to_enemy`）→ `CombatFeedback.hit_marker()`
- `scenes/weapons/bullet_base.gd`：**删 `_register_player_hit()`**（三处调用点 :104 / :109 / :181 目标全是 `enemies` 分组），三处直接调 `CombatFeedback.hit_marker()`；`_direct_hit` 同理。相关注释里"归因必须在伤害之前"的纪律一并删掉——那条纪律是为播报存在的，命中标记没有时序要求。

**玩家侧一律不动**：`explosion.gd:53` 的 `attribute`、`laser_weapon_base._apply_to_player` 的 `attribute_hit`、`royale_host.gd:428`、`server/match_combat.gd:84` —— 这些服务大乱斗计分。

### 2.3 明确保留

单机 HUD 右上角的三位击杀**计数器**（`ui/hud.gd` 的 `_kills` / `_on_enemy_died`）不是播报，**保留**。用户确认过。

### 2.4 守卫

- `tests/feedback_probe.gd`：删掉显示名断言（:142-148）与"归因 → 播报"的段落；`_check_writer_register_player_hit` 因 `_register_player_hit` 被删而要改写为"敌人命中只出 X 标记"；三个 e2e 段（直接命中 / 爆炸 AoE / 激光）判据从"写了 `last_damager`"改成"出了命中标记"。**`kill()` + 文字/骷髅/连杀的断言保留**（PvP 仍在用）。
- 实施时逐个核对（按"探针因重构变红时改探针认新入口，别回退重构"的既有纪律）：`kh_l4_probe.gd:83-105`、`kh_l5_probe.gd:290`、`kh_l6_probe.gd`、`hud_declarative_probe.gd:24`、`grenade_player_hit_probe.gd:68-70`、`royale_soak_probe.gd:159`、`enemy_logic_smoke`。

---

## 3. 武器偏移：根节点归零（A1）+ 删 `visual_offset`（A4）

### 3.1 先记一笔：字面"搬进 `Sprite2D.offset`"被证伪

用户最初选的是"把 `Sprite2D.position` 搬进 `Sprite2D.offset`"。**细化时发现该做法会改掉换弹手感**，故推翻：

Godot 的 `Sprite2D` 绘制矩形在**节点局部空间**是 `Rect2(offset - size/2, size)`，再整体乘节点变换。于是：

- `position` 是**节点变换的平移**，精灵自身的 `rotation` 绕**节点原点**转；
- `offset` 是**局部空间里的绘制偏移**，会**跟着精灵自身的 rotation 一起转**。

而换弹压枪正是 `sprite.rotation = RELOAD_TILT * k`（`weapon_base.gd:136`，`RELOAD_TILT = 0.9` ≈ 51°）。搬成 `offset` 之后，枪会绕着**武器根节点原点（= 玩家原点）**甩出去 51°，而不是原地压枪。`offset` 与 `position` 只在**精灵自身 rotation 为 0** 时等价——本作的瞄准俯仰/朝向镜像都写在**武器根节点**上（`weapon_base.gd:348/397` 的 `scale.x = facing` + `rotation = clamp_pitch(...)`），那两条确实等价；唯独换弹这条不等价。

要真让 `offset` 成立，得把支点烘进图集（重排 `weapons.png` 让每把枪的支点落在 region 中心），代价是图集重排 + `ui/weapon_icons.gd` 图标跟着变 + 手持位置重新对齐一次——用户已排除。

**结论：`Sprite2D.position` 保持不动，`SpriteBounds` 也不需要改**（`offset` 全项目仍为 0）。

### 3.2 A1：根节点偏移归零

六把枪里**只有 m82a1 的根节点带 `position`**。把它并进子节点，根节点就全部是零变换：

| 文件 | 改动 |
|---|---|
| `scenes/weapons/m82a1.tscn` | 删根节点 `position = Vector2(6, 3)`；`Sprite2D.position` `(18,6)` → **`(24,9)`**；`Muzzle.position` `(48,2)` → **`(54,5)`** |
| 其余五把 | 不动（根节点本来就是 `(0,0)`） |

**唯一行为差异**：m82a1 的**俯仰旋转支点**从 `(6,3)` 变到 `(0,0)`。俯仰角 θ 下枪身位置差 `(6,3) - R(θ)·(6,3)`，最大（θ=±45°）约 6.7 局部像素 ≈ **16.8 世界像素**。θ=0 时完全一致，且 `(0,0)`（玩家原点）作为支点比 `(6,3)` 更合理。枪口/弹道起点在 θ=0 时逐像素一致。

枪口/弹道相关的既有硬编码测试**不受影响**（它们钉的是榴弹发射器 `Muzzle.position = (31,8)`，本次不动）：`enemy_logic_smoke.gd:397-404`、`preview_probe.gd:34-35`、`aim_probe.gd:34-35`。

### 3.3 A4：让地面态 body 原点 = 枪的可视中心，删掉 `visual_offset`

**动机**：`visual_offset`（= 精灵偏移 × `WORLD_SCALE`）这套东西存在的唯一原因是"body 原点 ≠ 画出来的枪中心"。它引出了一整套跨端补偿，且**已经出过一次真 bug**：

- `weapon_pickup.gd:131` 只把 `spr.position` 算进去，**漏了武器根节点自己的 `position`** → m82a1 的判定圆心/按 F 提示比画出来的枪偏 **`(6,3)×2.5 = (15, 7.5)` 世界像素**（拾取半径才 64px）。

改法：在 `WeaponPickup` 里把 Visual **反向平移**，让画出来的枪中心落在 body 原点上，于是碰撞箱、判定圆心、渲染位置三者天然重合，`visual_offset` 与 `visual_center()` 可以整套删除。

`scenes/weapons/weapon_pickup.gd`：

```gdscript
func _build_collision() -> void:
    var vis := get_node_or_null("Visual")
    ...
    var r: Rect2 = SpriteBounds.from_sprite(spr)
    if r.size == Vector2.ZERO:
        return
    # ★ 把"画出来的枪中心"挪到 body 原点:三者(渲染/碰撞/判定)从此天然重合,
    #   不需要任何补偿(原先靠 visual_offset 把判定圆心搬回视觉中心)。
    #   注意 gun_center 必须带上**武器根节点自己**的 position —— 漏它正是
    #   m82a1 判定圆心偏 (15,7.5) 世界像素的成因。
    var gun_center := vis.position + spr.position + r.position + r.size * 0.5
    vis.position -= gun_center
    var cs := CollisionShape2D.new()
    cs.name = "Shape"
    var rect := RectangleShape2D.new()
    rect.size = r.size
    cs.shape = rect
    cs.position = Vector2.ZERO      # 视觉中心已在原点
    add_child(cs)
```

删除：`var visual_offset`、`func visual_center()`。渲染锚定（`sync_render_from_canonical`）逻辑不变 —— `canonical_pos` 从此**就是**视觉中心。

**调用点改 `canonical_pos`**：

| 文件 | 改动 |
|---|---|
| `scenes/level_0.gd:633, :646` | `pk.visual_center()` → `pk.canonical_pos` |
| `server/match_ground.gd:89` | `_sync_ground_positions` 里 `e["pos"] = canonical_pos` |
| `server/match_ground.gd:116-123` | `_debug_keep_weapon_within_reach`：去掉"反着减 `visual_offset`"，直接 `pk.canonical_pos = p.global_position` |
| `server/match_ground.gd:126-142` | `_canonical_of` 的注释与兜底 warning 文案改写 |
| `scenes/pvp_match_client.gd:330, :352` | 同 `level_0` |

**CLAUDE.md 里那整段 `★ 下发出去的 pos 一律是 canonical，不是判定圆心`（:84）要重写** —— 这个"两个位置"的区别消失了，`pos` 与判定圆心**本来就是同一个**。`_canonical_of` / `ground_weapons_payload` / `_broadcast_weapon_spawned` 的结构保留（它们解决的是"读已被 `_sync_ground_positions` 刷新的表"这个另一回事），只是不再需要区分两个中心。

**改完之后的对应关系**（★ 别把它读成"画面上会平移"）：

| | body 原点 | 碰撞箱（body 局部） | 画出来的枪中心 |
|---|---|---|---|
| 改前 | `B` | `cs.position ≈ (24, 5.6)` | `B + (60, 14)` 世界像素 |
| 改后 | `B'` | `Vector2.ZERO` | `B'` |

**"枪停在地板上"这件事前后完全一致**（两种写法下"包围盒底边贴地"是同一个约束）。变的是 **body 原点自己在哪**：`B' = B + (60, 14)`，也就是 `canonical_pos` 平移了约 `(60, 14)` 世界像素（≈ 1 格）—— 这**正是原先要用 `visual_center()` 补回来的那个量**。它的两个可观察后果：

1. **掉落落点**：枪现在从 `player + weapon_drop_offset` 那个点直接落下去（改前是落在它右边约 60 世界像素处）。枪的视觉中心与它自己的物理位置从此是同一个点。
2. **判定圆心**：`nearest_within(玩家位置, canonical_pos)` 与"看得见的那把枪"**逐像素重合**，不再需要任何补偿。

手持视觉**零变化**（§3.2 的支点差除外）。

**验证过的不变量**：`GroundWeaponField.nearest_within` 与 `PlayerParams.weapon_drop_offset` 是独立机制，**不在此次删除范围**。

### 3.4 守卫

- `tests/ground_action_probe.gd:79-111`（⓪ 相）：判据从 `载荷 pos + visual_offset == 判定圆心` 收成 `载荷 pos == 判定圆心`。
- `tests/level0_weapon_scatter_probe.gd:172-174, :215`：站到 `target.visual_offset` / `anchor_pk.visual_offset` → 直接站到节点位置。
- `tests/ground_client_probe.gd:112`：`pk.visual_center()` → `pk.canonical_pos`。
- `tests/sprite_bounds_smoke.gd` / `weapon_pickup_probe.gd`：**预期不动**（`SpriteBounds` 不改），实施时确认。
- 新增断言（可选，落在 `level0_weapon_scatter_probe` 或 `weapon_pickup_probe`）：**六把枪逐个实例化后，`CollisionShape2D.position` 都必须是 `Vector2.ZERO`，且 Visual 的平移使枪的 alpha 包围盒中心落在原点**——这条直接钉住 m82a1 那个错位不再回来。

---

## 4. 枪械穿模 → 向上挤

### 4.1 现状（为什么需要）

`WeaponPickup` 落地后完全**没有**"卡进墙里"的处理：

- `_physics_process` 里唯一的移动是 `move_and_slide()`；Godot 内建的 penetration recovery 按**最短轴**挤出（可能是水平、甚至向下），不是向上。
- **`_settled = true` 之后整个函数早退**（`weapon_pickup.gd:143-147`），`move_and_slide` 再也不跑 —— 之后即使可破坏砖被重铺盖在它身上，枪会**永久钉在墙里**，连 recovery 都不会再触发。
- 最现实的触发路径是**玩家贴墙丢弃**（`weapon_drop_offset = (24,-8)`、初速 `(±400, -220)`）。

### 4.2 新增纯逻辑 `core/sim/unstick.gd`

```gdscript
class_name Unstick
extends RefCounted

# 「把一个压进实心格的矩形向上挤出去」的单一来源。纯静态、不引 autoload(格尺寸由参数传入,
# 同 core/tile_query.gd / collision_aabb.gd 的约定),故 `-s` 可 load。
```

**核心**：`static func push_up_dy(rect: Rect2, ts: int, max_cells: int = 8) -> float`，返回把 `rect` 向上推出实心格所需的**最小位移**（0 = 没卡住）。

算法（每步都是"刚好清空"的最小量，不是整格跳）：

1. 先把矩形**四边各内缩 `PROBE_INSET = 0.5` 像素**再判重叠。
   ★ **这一步不能省**：`TileQuery._overlaps` 的格范围是 `floori(rect.end / ts)` 且**含端点**（`tile_query.gd:39-42`），一个正踩在地板上的矩形 `end.y` 恰好等于地板格的上边 → `floori` 落在地板那一行 → **被报成"压到实心格"**。不内缩的话，每一个正常停稳的枪每帧都会"解卡"往上弹。
2. 求当前覆盖范围内**最靠上**的实心行 `r_top`；没有则返回累计值。
3. `need = rect.end.y - r_top * ts`（把框底推到那一行的上边）。取最靠上的行 → `r_top*ts` 最小 → `need` 最大 → **一步就清掉当前所有被压的行**。
4. 累计位移、重判；最多迭代 `max_cells` 次（被推上去后可能又贴到更上面的墙，这是收敛而非死循环）。

环面注意：行号用 `posmod` 取回（沿用 `TileQuery`），且 `max_cells * ts` 远小于地图高度，不会绕圈。

### 4.3 `WeaponPickup` 两处调用

```gdscript
func _physics_process(delta: float) -> void:
    _age += delta
    if _settled:
        _unstick_up()          # ★ 停稳后 move_and_slide 不再跑,被后盖上的墙压住要靠这里
        sync_render_from_canonical()
        return
    ... 重力 / 摩擦 / move_and_slide() ...
    _recompute_canonical()
    _unstick_up()
    sync_render_from_canonical()
    if is_on_floor() and absf(velocity.x) < PlayerParams.weapon_stop_eps:
        velocity = Vector2.ZERO
        _settled = true
```

```gdscript
# 嵌进实心格(贴墙丢弃 / 停稳后砖被重铺盖住)→ 向上挤出去。
func _unstick_up() -> bool:
    if not CollisionAabb.has_any(self):
        return false                    # 没有碰撞体就没东西可挤(精灵全透明等)
    var dy := Unstick.push_up_dy(CollisionAabb.world_rect(self), GameParameters.TILE_SIZE)
    if dy <= 0.0:
        return false
    global_position.y -= dy
    velocity.y = 0.0
    _settled = false                    # 解掉停稳,让重力重新接管(可能被推进了空中)
    _recompute_canonical()
    return true
```

矩形来源是 **`CollisionAabb.world_rect(self)`**（已含 body 的 `scale = 2.5`）—— 与激光命中/水脚底/飞鸟避障同一个几何来源，不自己再拼一遍。

**服务器自动继承**：`MatchGround` 实例化的是同一个 `WeaponPickup` 场景，跑同一套物理。

### 4.4 守卫

新增 **`tests/unstick_smoke.gd`**（`extends SceneTree`、`-s` 可跑，直接给 `MazeGenerator.current_grid` 赋一张合成网格）：

- **贴地不算卡**（★ 最容易错的一条）：把矩形正踩在地板格上沿 → `push_up_dy == 0`。
- 压进地板半格 → 返回**刚好擦出去的最小位移**（不是整格）。
- 整框嵌在墙里 → 返回能清空的最小位移；上方是通道 → 一次到位。
- 上方也全是墙 → 连续迭代到 `max_cells` 上限，返回累计值且不崩。
- 空网格 → 返回 0（沿 `TileQuery` 的空网格语义）。

`-s` 冒烟按既有纪律写：`load()` 之后立刻判 `null` 并 `quit(1)`（否则 `_initialize()` 抛错 = 进程永久挂起），跑的时候套 `timeout`。

---

## 5. 探针与文档同步

**新增**：

- `tests/minimap_circle_probe.tscn/.gd`（真渲染，§1.4）
- `tests/unstick_smoke.gd`（`-s`，§4.4）

**改写**：`tests/feedback_probe.gd`（§2.4）、`tests/ground_action_probe.gd` ⓪ 相、`tests/level0_weapon_scatter_probe.gd`、`tests/ground_client_probe.gd`（§3.4）。

**实施时逐个核对**（不预设结论）：`kh_l1/l3/l4/l5/l6_probe`、`hud_declarative_probe`、`grenade_player_hit_probe`、`royale_soak_probe`、`weapon_pickup_probe`、`sprite_bounds_smoke`、`enemy_logic_smoke`。

**CLAUDE.md**：

- §UI 新增小地图一节（圆形/以玩家为中心/`RANGE_CELLS` 是范围唯一入口/环面走 `toroidal_delta_px`）。
- §武器背包与地面拾取：`★ 下发出去的 pos 一律是 canonical…`（:84）整段重写（两个中心已合并）；`visual_offset` 相关段落改写。
- §敌人：删掉 `display_name` 收口那段（显示名链已整体移除），`data/enemies.json` 的字段说明同步。
- §碰撞/新增 `core/sim/unstick.gd` 的位置与用途。

`node level_editor/sync-enemies.js --check` 与 `node level_editor/smoke.js` 在实施后各跑一次（用户自己跑）。

---

## 6. 明确不做

- **不给单机加小地图**（用户裁定只改联机那两个）。
- **不动鸟的解卡**：`EnemyFlyBase._find_escape_column()` 只搜"向下"和"本行水平"、且只在 A* 返回空路径时触发，这个缺口本次不补（`Unstick` 做成通用纯逻辑，日后鸟要接随时可接）。
- **不修小地图 `_ready` 空 grid 早退的脆弱性**（`set_process(false)` 后无重建路径，挂早了就静默失效）—— 既有问题，与本次改造正交。
- **不删单机 HUD 击杀计数器**。
- **不重排 `weapons.png`**、不动任何 `Sprite2D.position`、不改 `SpriteBounds` 语义。
- **不动 `GroundWeaponField.nearest_within` 与 `PlayerParams.weapon_drop_offset`**（独立机制）。

## 7. 已知风险（实施时盯）

1. **§4 的推挤与两端一致性**：客户端靠 `pos`+`vel` 本地重放落体。若某次推挤只在服务器发生（两端地块状态不一致），落点会发散。可接受范围待实测；地块变更本身有 `tile_destroyed` 广播与换局重铺，理论上同步。
2. **§4 的推挤-下落振荡**：枪被推进薄夹层后可能反复"推上去—掉下来"。`_settled = false` 是有意的（让它重新找落点），若实测抖动再收。
3. **§1 的 `RANGE_CELLS` 默认值 20 格**是占位，等用户给值。
4. **§3.2 的 m82a1 俯仰支点变化**（≤16.8 世界像素 @45°）是本次唯一的手持视觉差异。
