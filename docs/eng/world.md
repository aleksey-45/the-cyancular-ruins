# 世界与地形(环面 / 地图格式 / 参数 / 砖块 / 水 / 碰撞层)

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:环面世界与地图 · 参数体系(重要约定) · 砖块属性与破坏(data/tile_defs.json) · 水 · 碰撞层(按位)。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 环面世界与地图

- 地图:ASCII 文本 **`.cyrm`**(如 `maps/demo.cyrm`)。**v3 格式**(带 `# cyrm-v3` 标记):125×75 格 × 64px = 8000×4800 世界像素;每格 **4 字符 = [纹理 3 位 0xx][形状hex]**(纹理 `000`=空气/`001`-`022`=1-22,structure.png 两行各 10 块 + 第3行两块水;形状 hex `0`-`F` = 2×2 子格掩码,15=全砖,0=空气占位)。**旧格式**(250×150 单字符,无标记)加载时自动 2×2 转换(packed 值 + spawn 坐标 ÷2)。`#` 开头是注释(含出生点 `# player <col> <row>`;`# player2 <col> <row>` 为双人第二出生点,PvP 用)。加载:`MazeGenerator.map_file_path()` 优先随机取 exe 旁 `.cyrm`,否则随机取 `maps/*.cyrm`(**同目录多份随机读一份**,会话内固定);`maps/*.cyrm` 已在导出 include_filter 里。★ **游戏侧读的只有 v3 文本与旧字母格式两种**(编辑器**写**的是 v4 二进制,游戏还读不了,详见 §编辑器工具)。
- **地图与环面核心 = `MazeGenerator` + 两个实现类**(阶段 5.7;三个都 `RefCounted` + `class_name`,非 autoload):
  - **`MazeGenerator`(core/sim/maze_generator.gd)只留会话状态 + 转发** —— 会话状态就两件:选中的地图文件(`_picked_map`/`set_map_file`/`map_file_path`)与 `current_grid`(静态,由 Level0 赋值,空网格一律无路)。其余全是**一行转发**,保住全仓上百处 `MazeGenerator.xxx` 调用面。**别在这里加实现**:新格式逻辑进 `MapFormat`、新几何/寻路进 `GridPathfinder`。
  - **`MapFormat`(core/sim/map_format.gd)= `.cyrm` 格式**,**无会话状态**(路径/行由参数传入):格值 packed 编解码(`pack/texture_of/shape_of`、`EMPTY=0`、`SOLID=31` 纹理1 全砖)、`load_map_file(path)` / `map_size(path)` / `load_spawns(path)` / `parse_spawn_metadata(lines)`、`convert_old_grid` / `serialize_v3_grid`(单一转换源;旧 v2 字母版地图用 `tests/scripts/convert_map.gd` 转 v3)。v3 与旧格式都返回转换后 125×75;行宽不一致的抬头行会被跳过。
  - **`GridPathfinder`(core/sim/grid_pathfinder.gd)= 环面几何与寻路**,同样**无会话状态**(网格由 `grid` 参数传入):`toroidal_dist`(格级)、`toroidal_delta_px`(像素最短向量)、`anchor_to_nearest`(实体锚到玩家最近副本)、`wrap_to_range`(取模回中间副本)、`cell_of`、`is_floor_cell(_with_headroom)`、`astar_path_nearest` / `has_line_of_sight`(Bresenham);A* 的静态暂存缓冲与 `astar_calls` 计数住这里。
  - 挡路判定走 `TileDefs.is_blocked`(非 0 且 type=wall)。探针取图类脚本(`climb_probe` / `perf_probe` 等)不钉图 → **每进程随机选一份 `.cyrm`,跨进程输出不可比**。
- **关键区分**:玩家每帧 `wrap_to_range`(只留中间副本);敌人/子弹用 `anchor_to_nearest`(锚定到玩家附近的副本)。墙体按 3×3 铺贴,相机跨接缝才能看到另一侧——实体若取模回 `[0,MAP)` 会在接缝处"消失"。

### 参数体系(重要约定)

- **autoload 四个**(project.godot):
  - `GameParameters`(core/config/game_parameters.gd):gravity0、TILE_SIZE=64、地图像素尺寸、敌人数/出生距离。`_ready()` 里从 `MazeGenerator.map_size()` 回写 `MAP_WIDTH/HEIGHT`。
  - `NetBus`(core/net/net_bus.gd,PvP 网络 RPC 唯一收口):服务器/客户端共用 `/root/NetBus` 跨场景常驻,RPC 才能路由;建房/加入/断线经转交信号给大厅(`LobbyRooms`)。
  - `NetBusExt`(core/net/net_bus_ext.gd,旁路扩展协议:对局选项/角色色/`hit_confirm`/大乱斗房 RPC)。**与原版 NetBus 刻意分离**——改它的方法表会让与原版服务端的 RPC 全部失联;对原版 worker 本节点不存在 → 扩展 RPC 静默丢弃、优雅降级。★ 激光 `beam_fired` **不走这里**(KH 遗留重复,收上去静默 no-op)。
  - `Settings`(core/config/settings.gd,持久化:音量/键位重映射/滚轮切枪/血条显示,落盘 `user://settings.cfg`)。**换弹恒开、无可选项**——原 `reload_enabled` 开关已删除,设置菜单里也没有该勾选框。★ 2026-09-15 起换弹对**全模式**开放(1v1/大乱斗亦然):原先 `WeaponBase.reload_active()` 在 `pvp_mode`/网络输入源下恒 false,那道闸门已整个删除 —— **别再按"PvP 不换弹"解释任何东西**;`mag_ammo`/`_reloading`/`_reload_t` 已进 `Player.capture_state()`(与 `fire_cd` 同口径:进 capture/restore,**不进** `_close_enough` 的比对)。
- 玩家/敌人参数**不是** autoload:`PlayerParams`、`EnemyParams` 是 `RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。加新敌人 = 在 `EnemyParams` 加一个嵌套类。
- ★ **武器容量/把数(`WeaponInventory.capacity` / `max_weapons`)也是游戏规则**,可配但**默认值不变** —— 别因为它们变成字段就顺手把它塞进 `capture_state` / `match_options`(协议零改动是刻意的,理由见 §武器背包的「两条闸门」)。

### 砖块属性与破坏(data/tile_defs.json)

- **属性表** `data/tile_defs.json` 是单一来源:每块 name/type(墙/通道/液体/气体)/hp/explosion_decay/bullet_destroyable/explosion_destroyable/elastic/climb_speed/friction。编辑器副本 `level_editor/tile_defs.js` 由 `node level_editor/sync-tiles.js` 生成(`--check` 只校验不写盘)。
- 纹理 1-10 墙(hp1,不可破坏);11 梯子、12-14 锁链上中下 = 通道(climb_speed 1.6× 最快);15-18 树叶(墙,hp8,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,hp30,爆炸可破);21 水、22 水面 = 液体(无碰撞,可游)。爆炸衰减统一 0.75(水 0.25)、摩擦 1.0。
- 加载:`TileDefs.load_defs()`(level_0._ready);挡路 = `TileDefs.is_blocked`(非 0 且 type=wall),寻路/LOS/碰撞共用。
- **破坏**:`TileDefs.damage_tile(cell, dmg, "bullet"/"explosion")` → hp≤0 变空气(改 `MazeGenerator.current_grid` + `Level0.on_tile_destroyed` 清 3×3 瓦片 + 持久可破坏子格 2×2,标记所在分块下帧重建)。子弹撞树叶扣血;爆炸对树叶/树干按距离衰减×0.75 扣血。
- **攀爬**:玩家中心(或脚底)在通道格(梯子/锁链)「**刚按上**」主动攀附(不受重力):上爬 ×`tile.climb_speed`(梯 1.6/锁链 2.0),下降 ×`tile.climb_descent_speed`(梯 2.0);**锁链无下降倍率 → 按下自由落体**(解除攀附交给重力);松开挂住不坠落;**到顶 = 脚底进入梯子上方一格**,再按上 = 跳离梯子;进入靠「刚按下上」而非按住;攀附空闲可水平走离;**仅锁链顶/底基座有薄碰撞条**(`CollisionBuilder.build_climb_ledges`,全宽 64×6px;梯顶不加)。上爬与梯子下行再整体 × `PlayerParams.climb_vertical_mult`(1.2)。**身在梯/链格上不能空中下冲**(`climb.is_over_climb_tile()`)。
- **弹性**:碰树叶(elastic)被弱弹(PlayerParams.elastic_bounce=150)。

### 水

- **瓦片**:纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked`=false)。地图只画 21;水面(22)由 `Level0._paint_water` 自动派生(该格上方非 liquid → 水面层)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;**水面起伏**由 `water_surface.gdshader` 做逐格正弦上下拉伸(锚底无缝、相位逐格错开),水体层不挂 shader。
- **`Water` 助手**(core/sim/water.gd,静态,不引 autoload,-s 可测):`is_in_water` / `surface_y_at`(所在列向上扫到最顶液体格的顶边) / `submerged`(中心低于水面线=没顶) / `feet_offset` / `water_mult`(爆炸×水格 decay) / `bullet_drag_factor`。约定:脚底(中心+半身)在水格 = 在水中。
- **主角**(`scenes/player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右=水平游(×`player_swim_speed`),按上=上浮(`player_swim_up`)、不按=下沉(`player_swim_down`);不做水面悬停/浮力弹簧——出水由 `in_water` 判回 false 自动恢复普通物理。水下扣血未做。**呼吸(氧气)按「大部分没入」扣**:判定参考线比中心低 `PlayerParams.water_breath_line_offset`(10px,≈胸口下沿)——水面到胸口就开始扣,要浮到水面低于此线才回气(比原"中心没入"更早扣、更难回气)。
- **敌人**(`EnemyBase._apply_water`):落水浮力回水面;水平朝 `_water_swim_dir()` 游(JumpBird/BlackBird 覆写为朝玩家,基类=漂着);**溺水**:没顶累计,`drown_delay`(5s)后每 `drown_interval`(1s)扣 `drown_damage`(5),浮在水面不算。FlyBird 寻路把水当障碍,但正下方是水仍可飞越。
- **爆炸衰减**:目标所在格是水 → 爆炸伤害/击退 × 该水格 `explosion_decay`(0.25)。LOS 遮挡 75% 不变(仅墙后掩体;梯/链不挡也不减)。
- **子弹阻力**:子弹在水里 `velocity_vec *= exp(-water_bullet_drag·Δt)`,玩家 + 敌人子弹共用。
- **水粒子**(`scenes/effects/water_fx.gd`,运行期挂主角 + 敌人):水中**移动**才喷;中心贴水面 → 溅水花,没入深 → 上浮气泡。

### 碰撞层(按位)

层1=地形、层2=玩家、层3=敌人、**层4=掉落物(值 8)**。玩家/玩家子弹 mask=5(1+3);敌人占层 3(值4)、mask 侦测玩家。**地面武器**(`WeaponPickup`)`layer=8`/`mask=9`(地形+其它掉落物):玩家与敌人的掩码都不含 4、子弹 mask=5 也不含 → 三者**天然不碰**,无需改它们的掩码。★ `match_host.gd` 与两端客户端给玩家补的 `|= 2` 是**玩家层**,与掉落物层无关,别顺手写成 `|= 2 | 8`。

