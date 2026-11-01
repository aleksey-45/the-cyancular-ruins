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

### 出生/复活点:按阵营半区的地图数据(`# respawn <1|2> <col> <row>`)

**出生/复活点是地图数据,不是运行时生成的**:`.cyrm` v4 的 meta 文本行(格式层不动,仍是 `u16 meta_len` + UTF-8 文本)按**阵营半区**写死:

| 行 | 含义 | 约束 |
|---|---|---|
| `# respawn 1 <col> <row>` | **侧 1** 的复活点列表 | 侧 1 = **左半**(`x < cols/2`);每侧 **≥5**(当前两张图各写 9 个) |
| `# respawn 2 <col> <row>` | **侧 2** 的复活点列表 | 侧 2 = **右半**(`x ≥ cols/2`);同侧按文件顺序**去重**(首次出现生效) |
| `# player` / `# player2` | 单机玩家 / PvP 第二出生点 | **向后兼容保留**:单机入口、`MapCatalog` 的 PvP 图校验(要求两点都有)与老图无 `# respawn` 时的回退路径还读它们 |
| `# enemy <type> <col> <row>` | 敌人出生点 | 不变 |

- **半区语义**(常量在 `SpawnChooser.SIDE_LEFT = 1` / `SIDE_RIGHT = 2`,`side_of` / `side_offset` / `bucket_of` 是唯一划分):
  - **1v1**:role1 默认侧 1(左半)、role2 侧 2(右半);每局换边(`MatchState._side_swap`)时互换 ⇔ "每人只在自己那半边出生/复活"。
  - **对抗(team)**:队 1 → 侧 1、队 2 → 侧 2;换边(下一局,`TeamHost._side_swap_round`)时两队互换侧。
  - **大乱斗**:无阵营 ⇒ 用**两侧列表的并集**当候选(全图散布),开局散点与复活都从并集里取。
  - ⚠ 环面世界:左右接缝在 `x = 0`,所以两侧在接缝处也是相邻的。这是世界几何的固有边界,不改变"各占半区"的定义;1v1 的两人最小间距(`SpawnPicker.FAR_CELLS`)只是**软约束**(点不够时逐级放宽)。
- **"均匀散布"判据**(写死可校验,工具与探针同源 `SpawnChooser.bucket_of`):把**该侧半区**按 3 列 × 3 行切成 9 个桶(列以半区宽度为范围、行以整幅地图高度为范围)⇒ **每桶 ≥1 个点**,且**同侧两两环面距离 ≥ 5 格**;不允许"全挤一条带/一个角落/一个高度"。另要求**离本侧的两条边界(环面接缝 `x=0`/`cols` 与半区中线 `x=cols/2`)都 ≥ `SpawnChooser.SIDE_EDGE_MARGIN = 10` 格** —— 环面上"两半"在这两处都相邻,贴边会让对面半区的点落在几格内。`newfactory`(PvP)每侧 9 点、9/9 桶覆盖(同侧最小两两距 13/18 格);`demo`(单机、无 `# player2` 锚点)主可达区只够 6/5 点、6/9 与 5/9 桶 —— 非 PvP 图按「≥5 + 可达 + 边界 + 间距」放行(见下条 ⚠)。
- **点合格判据**(全部在 `SpawnPicker`,工具 `--check` / 探针 / 运行时同源):地板格(本格空 + 正下方挡路 + 头顶 1 格空)+ 头顶 2 格净空 + 本格 EMPTY(不在水里)+ **可抵达**。
  - **可抵达** = 落在「跳跃感知图」的**主连通分量**里(`SpawnPicker.reachable_spawn_cells`,跳跃感知图 = 可站格 + 走 / 跳落组合 / 爬 / 游泳的边,主分量 = 节点数最大者)。这是对用户实报「复活点落进完全不联通的封闭空间」的修复:上一版只要求"同层连通区 ≥2",四面是墙的 2 格小密室也满足 ⇒ 已废弃。
  - **近似口径(照实,不是物理精确)**:升降包络按 `jump_velocity=1000 / gravity0=1600` 推出最高 ≈4.88 格(保守取 4)、空中横移取 6 格;同时覆盖"升→横移→直落"的跳沟/跳台/跳下;落体按直落最多 29 格;攀爬只认 `climb_speed > 0` 的道格;液体格算可游节点(可从岸边入水/游到相邻可站格)。**不支持**多段跳 / 冲刺 / 空中被外力改写轨迹,也不模拟砖块被拆开路后的新连通(静态地图口径)。
  - ⚠ 比 `spawn_candidates()` 的"开阔"门槛(`area_threshold`)宽 —— 严格档会把 `newfactory` 全部合格点压到底部一条开阔带(用户已否决,见 [`registered-debt.md`](registered-debt.md) §四十六)。
  - ⚠ `demo.cyrm` 是单机多房间图(无 `# player2`),其主可达区只覆盖部分桶(6/9 与 5/9)⇒ 非 PvP 图只强制「每侧 ≥5 + 可达 + 边界 + 间距」,不强制 3×3 桶覆盖;`newfactory`(PvP 图)必须 9/9。
- 解析:`MapFormat.parse_spawn_metadata` → `load_spawns()` 的 `respawns: {1: [...], 2: [...]}`(两侧都空时连键都不带 ⇒ 老图回退判据成立)。非法行(负数 / 非整数 / 缺列 / 侧号不是 1|2)`push_warning` 后跳过、**不抛错**;坐标是格(col = x,row = y),越界不做重排(界外由工具/探针报红)。旧格式(2×2→1)的坐标同样 ÷2。
- 写盘工具 [`tools/map_spawn_meta.gd`](../../tools/map_spawn_meta.gd)(SceneTree 脚本,`-s` 跑):
  - `--check` 校验地图现有数据(每侧 ≥5 / 在自己半区 / 每个点合格 / 9 桶覆盖 / 同侧间距);
  - `--suggest [--side 1|2]` 按半区**均匀撒点建议**(每桶挑一个"离已选点最远"的合格格;只打印、不写盘,人确认后用固定坐标写死);
  - `--list` / `--inspect "x,y;..."`;`--respawn1 "x,y;..." --respawn2 "..." --write` 写盘。
  写盘走 `MapFormatV4.replace_meta`:只替换 meta 文本段,**层块字节逐字节原样保留**(走 `serialize()` 会从格级网格重铺场景层,丢掉编辑器画的 16px 混排);写后自动回读:两侧列表与场景层逐格都要与写入前一致。
- 浏览器编辑器(`level_editor/`)对未知 meta 行的处理:它们被 `parseMeta` 归入 `comments`、`buildMeta` 原样以 `# ` 前缀回写 ⇒ **`# respawn` 行不会丢**(行内容逐字保留;行顺序会被挪到注释区且首尾空白被 trim)。编辑器里没有复活点的可视化 UI:改点用上面的工具或直接改 meta 文本。v1/v2/v3 老图**不新增**这些行,也不会报错(空列表 → 各模式回退路径)。
- 运行时选点(唯一随机实现 = [`core/sim/spawn_chooser.gd`](../../core/sim/spawn_chooser.gd) 的 `SpawnChooser.pick` / `pick_many`):
  - **排除上一次位置 = 硬约束**(若整张列表都被排除,才让位 —— 宁可重选自己的旧点,也不与对手同格);**最小间距 = 软约束**,按 `RELAX_STEP = 5` 逐级放宽到 0(点不够是地图数据的边界,不该把人甩到 (-1,-1) 的墙角)。
  - **1v1**:`MatchBootstrap.plan_spawns` 让每个 role 从**自己半区**的列表随机取一格(并广播同一份);`MatchState._spawn_cell` 在**本 role 自己的半区**里重选(复活 / 换局 / 击杀后复位),排除自己上一次落点,并与对手尽量保持 `FAR_CELLS`;`role_spawns()` 只读不重算(match_sync 会重复拉)。**缺 `# respawn` 的老图**逐字回退改造前行为:`# player` / `# player2` 两点 + `_side_swap` 换边(role2 缺失时 `far_spawn_from` 现挑),并 `push_warning` 一次。
  - **对抗**:`TeamSpawn.plan_team_spawns(teams, last, side_swap)` 每局按队取侧,每人随机、排除本 role 上一局点位、队内尽量拉开;**局内复活** `TeamSpawn.respawn_cell` 也用**本队这一局所在侧**的数据(不跨侧、不回退几何),筛「离存活敌人 ≥ `RESPAWN_CLEARANCE`」且排除自己上一次落点。缺数据 / 某队人数超过该侧列表 ⇒ 回退改造前的几何生成(重试循环原样保留)并 `push_warning` 一次。
  - **大乱斗**:`RoyaleSpawn.plan_spawns` 从**两侧并集**取 N 人(两两尽量 ≥ `SPAWN_CLEARANCE`);`respawn_cell` 用同一并集,筛「距所有存活玩家 ≥ `RESPAWN_CLEARANCE`」且 `≠ _last_spawn[role]`,全筛空时退化为同池随机(不再回 (-1,-1) 角落)。**缺数据时回退现有 `SpawnPicker` 几何生成并 `push_warning` 一次**;数据点不够 N 人时用地板格补足(与改造前同一条兜底)。
- 已知边界(照实):
  1. **"均匀"是桶覆盖 + 同侧间距,不是连续均匀分布**:9 个点里有的桶会靠近半区边界(环面接缝两侧可能很近);两半在接缝处相邻是环面世界的固有几何。
  2. 超过数据列表人数的对局(如大乱斗 16 人 / 某队人数超过该侧列表)**混合**使用数据点 + 几何补足;数据点优先,但这不是"全部落点都在地图数据里"。
  3. "上一次位置"记录的是上一次**出生/复活点**,不是死亡地点。
  4. 脚本探针只覆盖默认图(`newfactory` / `demo`)与纯逻辑;真链路(两端 match_start / match_sync 与摆位同源、换边后客户端重拉)仍需真链路批。



## 参数体系

- autoload 四个(`project.godot`):`GameParameters`(gravity0、`TILE_SIZE = 64`、地图像素尺寸、敌人数/出生距离)、`NetBus`(PvP RPC 唯一收口,`/root/NetBus` 跨场景常驻)、`NetBusExt`(旁路扩展:对局选项 / 角色色 / `hit_confirm` / 大乱斗房 RPC;未装扩展的 worker 上该节点不存在 ⇒ 扩展 RPC 静默丢弃)、`Settings`(音量 / 键位重映射 / 滚轮切枪 / 血条显示,落盘 `user://settings.cfg`)。`GameParameters.MAP_WIDTH/HEIGHT` 在 `_ready()` 由 `MazeGenerator.map_size()` 回写,`core/sim/world_builder.gd` 加载网格后再按网格写一次;两者之间没有一致性断言。
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
- 最小破坏单位(`BulletBase.tile_break_unit`,单位 = 格):`>=1` 走格级 `damage_tile`(一次清整格 16 个子格),`>=0.5` 走 **32px 块**(2×2 子格,`damage_block32`),`<0.5` 走单子格 `damage_sub`。**榴弹 = 0.5(= 32px 块;2026-10-30 用户裁定),其余所有子弹 = 1.0(= 整 64px 格)**;爆炸用同一参数(`Explosion.apply_aoe(..., tile_unit_cells)`,整格侧对爆区内每个 64px 格**去重**后按该格最近子格的衰减值扣一次)。两本账边界:子格路径把整格 16 个子格打空时同步把格级 `hp_grid[cell]=0`(与格级路径在"格子已消失"上对齐);但**混打时两本账仍独立累计**(先子格磨、再格级打 ⇒ 格级扣的是自己的 8/30,不是剩余子格合计)——已登记 [`registered-debt.md`](registered-debt.md) §十四。
- 攀爬:玩家中心(或脚底)在通道格「刚按上」攀附(不受重力),上爬/梯子下行速度用 `PlayerParams.climb_*` 绝对值(梯 上850/下800、锁链 上800 px/s;2026-10-28 起不再乘瓦片倍率);锁链无下降倍率 ⇒ 按下自由落体。松开挂住不坠落;到顶 = 脚底进入梯子上方一格,再按上 = 跳离;进入靠「刚按下上」而非按住;攀附空闲可水平走离。仅锁链顶/底基座有薄碰撞条(`CollisionBuilder.build_climb_ledges`,全宽 64×6px,梯顶不加)。身在梯/链格上不能空中下冲。

## 水

- 纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked = false`)。地图只画 21;水面 22 由 `Level0._paint_water` 派生(该格上方非 liquid → 水面层)。★ 渲染侧两块砖的下标是 **0-based**(纹理 id − 1):水体图集用 `WATER_BODY_BRICK = 20`、水面合批用 `WATER_SURFACE_BRICK = 21`;混用不会报错,只会让整片水变成水面(2026-11-01 修,守卫 `tests/probe/water_atlas_probe.tscn`)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;水面起伏由 `scenes/effects/water_surface_batch.gd`(合批静态网格 + 内联 canvas vertex shader)做逐格正弦上下拉伸(格底锚定、相位逐格错开),水体层不挂 shader。
- `Water`(`core/sim/water.gd`,静态,不引 autoload,`-s` 可测):**身体查询唯一入口 `sample_body(body, was_in_water)`**,结果在 `core/sim/water_sample.gd`(纯数据)。采样点 = 活动碰撞箱的**头顶/脚底**(不再是"中心 + 半身");水面线 = 所在水袋顶边,并**归一到离身体最近的环面副本**;向上扫连续液体格有 rows 上限(全液列标 `SURFACE_FULL`,不死循环)。字段:`in_water`(脚底深度 ≥ `GameParameters.water_enter_depth`=8px 进、> `water_exit_depth`=-2px 出,**滞回**)/ `head_under`(头低于水面线才扣氧,玩家与敌人同一条线)/ `feet_depth` / `submersion_ratio` / `surface_kind`(`NONE`/`FREE`/`CEILING`/`FULL`)。点查询 `is_in_water` / `surface_y_at`(返回段顶边,已归一最近副本;点不在水里返回 pos.y)/ `submerged` 只保留给未迁移面(子弹阻力 / 爆炸 / 预瞄)。`feet_offset` 的缓存签名同时数 `CollisionShape2D` 与 `CollisionPolygon2D`(姿态切换即失效重算),爬梯与对手副本共用它。
- 主角(`scenes/player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右 = 水平游(× `player_swim_speed`),按上 = 上浮(`player_swim_up`)、不按 = 下沉(`player_swim_down`);没有水面悬停/浮力弹簧,出水由 `in_water` 滞回判回 false 自动恢复普通物理。`SwimComponent.sample` 是玩家本帧水状态的唯一来源,根只读它。呼吸按 `head_under`(头低于水面线)扣;氧气上限 `player_waterproof_max = 10`,空后每 `water_drown_damage_interval`(1.5s)扣 `player_waterproof_damage = 5`。敌人(`EnemyBase._apply_water`)落水浮力回水面(浮力目标用归一后的 `surface_y`),水平朝 `_water_swim_dir()` 游(JumpBird / BlackBird 覆写为朝玩家,基类 = 漂着);`head_under` 时防水值按 `GameParameters.water_drain_interval`(1s)掉 1、出水按 `water_recover_interval`(0.3s)回 1,上限 `waterproof_max`(black / jump 6,fly 10);归零后每 `EnemyParams.shared.drown_interval`(1.5s)扣 `shared.drown_damage`(5)。FlyBird 寻路把水当障碍,但正下方是水仍可飞越;它对水中玩家的 ×1.5 增伤用 `sample_body(player)` 判,与玩家自身同源。
- 爆炸:目标格是水 ⇒ 伤害/击退 × 该格 `explosion_decay`(0.25)(**点口径,未收口**);LOS 遮挡 75% 不变(仅墙后掩体,梯/链不挡也不减)。子弹阻力 `velocity_vec *= exp(-water_bullet_drag·Δt)`,玩家与敌人子弹共用。水粒子(`scenes/effects/water_fx.gd`,运行期挂主角 + 敌人)按 `sample_body` 的 `feet_depth` 分模式:贴水面溅水花、没入深上浮气泡。

## 碰撞层(按位)与受击面

- 层 1 = 地形 / 层 2 = 玩家 / 层 3 = 敌人(值 4) / 层 4 = 掉落物(值 8,`WeaponPickup` layer 8 / mask 9) / 层 5 = 3v3 队 B(`TeamSpawn.TEAM_ENEMY_LAYER`,值 16)。

- **碰撞层只管移动**:玩家 / 地面上敌人各自占位并互相挡路;玩家子弹与敌弹的 mask = **1(只撞地形)** —— 受击判定不再由物理碰撞承担,而是走 `core/sim/hit_shape.gd` 的"上一位置→当前位置线段 vs 受击面"扫掠。
- **受击面(hurtbox)与移动碰撞箱分离**:每个可受伤实体提供 `hurt_rect()`(玩家 = 当前姿态箱世界 AABB,敌人 = 活动碰撞箱 AABB,飞鸟按站/飞箱),客户端对手副本另提供 `hurt_rect_rendered()`(尺寸取幽灵体、位置取渲染位置)。子弹 / 敌弹 / 激光 / 爆炸 / 服务器裁决 / 客户端 cull 全部经 hit_shape 查同一套矩形;`collision_layer = 0` 或 `is_hurtable() == false`(死亡白闪的尸体 / 倒地玩家)不可受击。
- **命中裁决的时间域**:PvP 服务器结算命中时不用现时受击面,而是按**射手观看时刻**回放 `core/sim/hit_lag_history.gd` 的受击面历史(`st − LagComp.PLAYOUT_TICKS`,见 `core/net/lag_comp.gd`);移动预测 / 幽灵体仍吃最新态,AoE 不回放(边界见 [`registered-debt.md`](registered-debt.md) §十五)。
- 地面武器 layer = 8 / mask = 9(地形 + 其它掉落物):玩家与敌人的掩码都不含 4,子弹 mask 也不含 ⇒ 三者天然不碰。
- `match_host.gd` 与两端客户端给玩家补的 `|= 2` 是**玩家层**,与掉落物层无关,别写成 `|= 2 | 8`。层 6 / 值 32 与层 7 / 值 64 无生产代码引用;`project.godot` 没有 `layer_names`,层义只活在代码里,加新层时没有任何自动提醒。
