# 世界与地形(环面 / 地图格式 / 参数 / 砖块 / 水 / 碰撞层)

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 环面世界与地图

- 逻辑视口 **1920×1440**(`project.godot` 的 `window/size/viewport_*`);世界 = 地图格数 × 64px:`demo` 125×75 = 8000×4800,`newfactory` 150×100 = 9600×6400。
- 左右/上下无缝回绕:玩家每帧 `GridPathfinder.wrap_to_range`(只留中间副本),敌人/子弹用 `anchor_to_nearest`(锚到玩家附近的副本);墙体按 3×3 铺贴,相机跨接缝才看得到另一侧。
- `MazeGenerator` 只放会话状态(`_picked_map`、`current_grid`、`current_subgrid`)+ 一行转发;格式在 `MapFormat`,环面几何与寻路在 `GridPathfinder`。
- 选图:`MazeGenerator.map_file_path()` 先随机取 exe 旁 `.cyrm`,否则随机取 `res://maps/*.cyrm`;选中后整个会话固定,`set_map_file(path)` 覆盖(PvP 服务器定图)。`maps/*.cyrm` 在导出 include_filter 里。

### `.cyrm` v4(二进制)

- 头 20 字节:`CYRM` magic(4)/ `version=4`(1)/ `compression`(1:0 = 裸 body,1 = zlib deflate)/ `body_size` u32LE(解压后)/ `body_crc32` u32LE / `sub_cols` u16LE / `sub_rows` u16LE / `layer_flags`(1)/ reserved(1)。校验:`sub_cols` / `sub_rows` 必须非零且为 4 的倍数;`body_size` 必须在解压前按 `MAX_BODY_SIZE = 64MB` 拦;`compression=0` 时 `body_size` 必须恰等于文件余量;CRC32 不符即失败。
- body = `u16 meta_len` + meta UTF-8(含出生点行)+ 逐层块;层块 `kind=1` = 调色板 + 索引流,`kind=2` = 整块 RGBA;调色板描述符 u32 是 hue/brightness/saturation/alpha/texture 位域。
- `layer_flags` bit0 前景 / bit1 场景 / bit2 后景 / bit3 背景;游戏只消费**场景层**,`flatten_scene()` 把 4×4 子格扁平化回「单纹理 + 2×2 形状掩码」。
- 子格:一格 64px = 4×4 个 16px 子格(`MapFormatV4.SUB_PER_CELL = 4`)。格值 packed = `texture*16 + shape`;`EMPTY = 0`、`SOLID = 31`(纹理 1 全砖)。
- v3 文本(`# cyrm-v3`,每格 4 字符 = 3 位十进制纹理 + 1 位形状 hex)与单字符文本格式仍可读,加载时转换为 125×75;出生点 `# player <col> <row>`、`# player2 <col> <row>`(PvP 第二出生点),读口 `MapFormat.load_spawns` / `parse_spawn_metadata`。

## 参数体系

- autoload 四个(`project.godot`):`GameParameters`(gravity0、`TILE_SIZE = 64`、地图像素尺寸、敌人数/出生距离)、`Wire`(PvP RPC 唯一收口,`/root/Wire` 跨场景常驻)、`Wire`(旁路扩展:对局选项 / 角色色 / `hit_confirm` / 大乱斗房 RPC;未装扩展的 worker 上该节点不存在 ⇒ 扩展 RPC 静默丢弃)、`Settings`(音量 / 键位重映射 / 滚轮切枪 / 血条显示,落盘 `user://settings.cfg`)。`GameParameters.MAP_WIDTH/HEIGHT` 在 `_ready()` 由 `MazeGenerator.map_size()` 回写,`core/sim/world_builder.gd` 加载网格后再按网格写一次;两者之间没有一致性断言。
- `PlayerParams`、`EnemyParams` 不是 autoload:`RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。

## 砖块属性与破坏(data/tile_defs.json)

| 纹理 | 属性 |
|---|---|
| 1-10 | 墙,hp 1,不可破 |
| 11 梯子 | passage,climb 1.6 / descent 2.0 |
| 12-14 锁链 | passage,climb 2.0,**无下降倍率** |
| 15-18 树叶 | 墙,hp 8,子弹/爆炸可破,`elastic`(弱弹 150) |
| 19-20 树干 | 墙,hp 30,子弹/爆炸可破 |
| 21 水 / 22 水面 | `liquid`,无碰撞 |

全局 `explosion_decay` 0.75(水 0.25)、`friction` 1.0。

- `data/tile_defs.json` 是单一来源(每块 name / type / hp / explosion_decay / bullet_destroyable / explosion_destroyable / elastic / climb_speed / friction);编辑器副本 `level_editor/tile_defs.js` 由 `node level_editor/sync-tiles.js` 生成(`--check` 只校验不写盘)。
- 加载 `TileDefs.load_defs()`(`level_0._ready`);挡路 = `TileDefs.is_blocked`(非 0 且 type=wall),寻路 / LOS / 碰撞共用;只有 type=wall 产生碰撞。
- 破坏:`TileDefs.damage_tile(cell, dmg, "bullet"/"explosion")` → hp≤0 变空气(改 `MazeGenerator.current_grid` + 格级回调 `TileDefs.on_destroyed` + 持久可破坏子格);子格按 16px(64px 格 → 4×4)计,清完标记所在分块下帧重建,`Level0.MAX_REBUILD_PER_FRAME = 2`。格级 `on_destroyed` 单机在 `scenes/level_0.gd` → `TileDefs.destroy_cell`,服务器在 `server/match/match_host.gd` → `MatchCombat._on_tile_destroyed`。碰撞真相源是 `sub_hp`(`CollisionBuilder.build_sub` 按 `sub_alive` 筛),不是 `destructible_sub`;每局复位必须同时还原 `init_hp` 与 `init_sub_hp`。
- 攀爬:玩家中心(或脚底)在通道格「刚按上」攀附(不受重力),上爬 × `tile.climb_speed`(梯 1.6 / 锁链 2.0),下降 × `tile.climb_descent_speed`(梯 2.0);锁链无下降倍率 ⇒ 按下自由落体。松开挂住不坠落;到顶 = 脚底进入梯子上方一格,再按上 = 跳离;进入靠「刚按下上」而非按住;攀附空闲可水平走离。仅锁链顶/底基座有薄碰撞条(`CollisionBuilder.build_climb_ledges`,全宽 64×6px,梯顶不加)。上爬与梯子下行再 × `PlayerParams.climb_vertical_mult`(1.2)。身在梯/链格上不能空中下冲。

## 水

- 纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked = false`)。地图只画 21;水面 22 由 `Level0._paint_water` 派生(该格上方非 liquid → 水面层)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;水面起伏由 `scenes/effects/water_surface_batch.gd`(合批静态网格 + 内联 canvas vertex shader)做逐格正弦上下拉伸(格底锚定、相位逐格错开),水体层不挂 shader。
- `Water`(`core/sim/water.gd`,静态,不引 autoload,`-s` 可测):`is_in_water` / `surface_y_at`(所在列向上扫到最顶液体格的顶边)/ `submerged`(中心低于水面线)/ `feet_offset` / `water_mult` / `bullet_drag_factor`;脚底(中心 + 半身)在水格 = 在水中。
- 主角(`scenes/player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右 = 水平游(× `player_swim_speed`),按上 = 上浮(`player_swim_up`)、不按 = 下沉(`player_swim_down`);没有水面悬停/浮力弹簧,出水由 `in_water` 判回 false 自动恢复普通物理。呼吸按「大部分没入」扣,判定线比中心低 `PlayerParams.water_breath_line_offset`(10px);氧气上限 `player_waterproof_max = 10`,空后每秒扣 `player_waterproof_damage = 5`。敌人(`EnemyBase._apply_water`)落水浮力回水面,水平朝 `_water_swim_dir()` 游(JumpBird / BlackBird 覆写为朝玩家,基类 = 漂着);没顶时防水值按 `GameParameters.water_drain_interval`(1s)掉 1、出水按 `water_recover_interval`(0.3s)回 1,上限 `waterproof_max`(black / jump 6,fly 10);归零后每 `EnemyParams.shared.drown_interval`(1.5s)扣 `shared.drown_damage`(5)。FlyBird 寻路把水当障碍,但正下方是水仍可飞越。
- 爆炸:目标格是水 ⇒ 伤害/击退 × 该格 `explosion_decay`(0.25);LOS 遮挡 75% 不变(仅墙后掩体,梯/链不挡也不减)。子弹阻力 `velocity_vec *= exp(-water_bullet_drag·Δt)`,玩家与敌人子弹共用。水粒子(`scenes/effects/water_fx.gd`,运行期挂主角 + 敌人)水中移动才喷,贴水面溅水花、没入深上浮气泡。

## 碰撞层(按位)

- 层 1 = 地形 / 层 2 = 玩家 / 层 3 = 敌人(值 4) / 层 4 = 掉落物(值 8,`WeaponPickup` layer 8 / mask 9) / 层 5 = 3v3 队 B(`TeamSpawn.TEAM_ENEMY_LAYER`,值 16)。

- 玩家 / 玩家子弹 mask = 5(1+3);敌人占层 3(值 4)、mask 侦测玩家。地面武器 layer = 8 / mask = 9(地形 + 其它掉落物):玩家与敌人的掩码都不含 4、子弹 mask 也不含 ⇒ 三者天然不碰。
- `match_host.gd` 与两端客户端给玩家补的 `|= 2` 是**玩家层**,与掉落物层无关,别写成 `|= 2 | 8`。层 6 / 值 32 无生产代码引用;`project.godot` 没有 `layer_names`,层义只活在代码里,加第 7 层时没有任何自动提醒。
