# 渲染管线与补间形变

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 渲染管线(`scenes/level_0.tscn`)

- 根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体 / 玩家 / 敌人)渲染进 SubViewport,`PostProcess`(`post_process.gd`)做像素缩放裁切 + 倒地暗角。
- 相机 `core/present/camera_2d.gd` 在 `_process` 里直贴目标位置(加 `cam_y_bias`),另有 `shake()`:无前瞻、无死区、无平滑。`PlayerParams.cam_lookahead_x` / `cam_lookahead_y` / `cam_deadzone` 全仓无人读,别按它们改行为。

- 图集构造 `core/sim/terrain_atlas.gd`(`TerrainAtlas`):源砖 → 图集 → TileSet;`Level0._create_wall_tileset()` / `_create_water_tileset()` 只剩转发。
  - **墙体 = 16px 象限**:`make_wall_tileset()` 把每块 32px 源砖拆成 4×4 个 8×8 象限、各最近邻 2× 放大成 16×16,拼成 16 列(4×4 象限)× 22 行(纹理 1-22)的 TileSet(`tile_size = 16`);`_paint_maze` 铺 16px 子格,瓦片坐标 = `Vector2i((y%4)*4 + (x%4), tex-1)`,3×3 环面。
  - **水体 = 64px 整格**:`make_water_tileset(ts)`,水砖放大到 ts×ts、按 2×2 shape 掩码挖象限 → 16 形状列 × 1 行;`_paint_water` 按 `shape_of(v)` 取列。
  - `TerrainAtlas.SKY_COLOR`(`b0e5f6`)是「空气格 / 清屏色」的唯一来源:`Level0` 的 `RenderingServer.set_default_clear_color()` 与主菜单背景底色都读它。它是世界底色,不是 UI token,也别改 `MapCatalog.BG`(选图缩略图底色,语义不同)。
- 碰撞 `core/sim/collision_builder.gd`(`CollisionBuilder`,静态可测):形状掩码展开成 16px 子格(每 64px 格 → 4×4),贪心合并矩形后按 9 环面副本偏移实例化(每块矩形 ×9,共享同一 shape)。永久墙建一个整图节点、建一次不动;可破坏层按分块存节点(块边长 12 格),摧毁时只重建所在块。只有 type=wall 产生碰撞。
- `core/sim/collision_aabb.gd`(`CollisionAabb`:从任意节点求**启用中**碰撞体的世界 AABB)是激光命中、water 脚底偏移、飞鸟避障矩形的共同几何来源;三者各带兜底值,只在目标真没有碰撞体时生效。多边形与形状必须分开判(`CollisionPolygon2D` 与 `CollisionShape2D` 是并列类);本作所有身体(三敌人 + 玩家 5 个姿态箱)都只用多边形。
- `core/sim/unstick.gd`(`Unstick`):`push_up_dy(rect, ts, max_cells) -> float` 逐格向上找第一个整框清空的位置(0 = 没卡住),不是整格跳。探测矩形四边内缩 `PROBE_INSET`(0.5px):`floori(rect.end / ts)` 含端点,不收会多算一格。唯一调用方 `WeaponPickup._physics_process`(`move_and_slide` 之后 + `_settled` 早退分支里)。几何走 `CollisionAabb.world_rect`。
- 世界构建 `core/sim/world_builder.gd`(`WorldBuilder`,静态):`load_grid()`(地图 → current_grid / TileDefs / 地图像素尺寸)、`build_sim(parent, grid)`(碰撞:永久墙 + 可破坏分块 + 攀爬基座条)。单人 Level0 与 PvP 客户端 / 服务器共用。

## 补间形变(squash & stretch)

- `scenes/effects/squash_stretch.gd`(`SquashStretch extends Node`)是纯表现层组件,挂玩家 / 三只敌鸟 / 对手副本,只写 `animator.scale`。
- 计算模型 = `_air`(每帧由 `vel_y` 重算,无状态)+ `_impulse`(事件累加 + `MathUtil.approach` 指数回归);单标量叠加,同时事件天然叠加。幅度上限 `squash_amount = 0.06`,`v` 钳在 `[-1,1]`。
- 落地判据 `if on_floor and vel_y > squash_land_min_vy`;阈值不是字面量 —— 玩家侧 `PlayerParams.squash_land_min_vy`、敌人侧 `EnemyParams.squash_land_min_vy`(当前同值 220.0)。宿主必须在 `move_and_slide()` **之前**缓存 `_pre_move_vy`。
- 宿主契约:传进 `tick()` 的 `vel_y` 必须是「地面真正吸收掉的」那个下坠速度,否则传 0。玩家侧 = `_pre_move_vy = 0.0 if (in_water or latched) else velocity.y`;敌人侧刻意用裸 `velocity.y`(水的写入钳在 −260/+160,下沉侧 160 < 阈值 220)。
- `tick` 放 `_physics_process` 最首行(倒地早退之前),敌人侧同理(`_is_far_sleeping()` 早退之前);形变不进 `capture_state()` / `restore_state()`,不碰碰撞箱。
- 倒地必须 `suppressed = true`:副本根节点 `rotation = -90°`,写 `scale` 会沿转过的轴挤压。
- 副本:数据从快照的 `vel` / `pose` 本地推导;`on_floor = (not _downed) and _pose != POSE_FLY and absf(_vel.y) < LAND_VEL_EPS`;水项用客户端本地网格查询 `_in_water()`,不是协议字段;不做受击挤压;`tick` 放副本的 `_process`。
- 已知表现副产物:缩放绕精灵中心,挤压时画出的底边上抬 ~4~5px、拉伸下沉 ~3.5px。`animator.offset` 必须保持 `Vector2.ZERO`。
- `_impulse` 有两个写入口,各自钳一次 `[-1,1]`:`impulse()` 的加法,以及 `tick()` 里 `_impulse -= _land_gain * k` 之后紧跟的 `clampf`。

## 远端玩家副本的表现层(`scenes/player/player_replica.gd`)

- **渲染层带**:`level_0.tscn` 的子节点顺序是 `Camera2D → Player → WallLayer → WaterLayer(z 4) → WaterSurfaceLayer(z 5)`。所以本体被墙体 / 梯子 / 建筑(都铺在 `WallLayer`)盖住,却又被水层压住;而远端副本是运行时 `add_child` 到世界末尾的 ⇒ 默认盖住墙体 / 梯子 / 建筑(现状 = 只有别人的角色压在地形上)。副本在 `_ready` 里用 `Level0.wall_layer` 把自己挪到那一层之前(`_reorder_before_structures`),与本体同一条层带。★ 只动绘制顺序,不碰碰撞与位置。
- **位置插值**:下行 30Hz ⇒ 直出最新快照就是「一格一格跳」(单步 = 移速 × 33ms,走速 ≈10px,到达抖动还直接透传)。改成 playout 缓冲插值:渲染「最新快照 − `PLAYOUT_TICKS`」那一刻的两样本夹逼插值,`PLAYOUT_TICKS = 4`(60Hz tick 域)= 2 个发包间隔 ≈ **67ms**。这个延迟是选出来的常量(不是低通滤波器的涌现滞后);改大更抗抖动但对手更迟,改 0 = 退回直出。
- **两端冻结**:取样比最新还新(underrun)冻在最新、不外插(外插会让对手飞出去);比最老还老冻在最老、不倒退。跨接缝的那一对样本先锚进同一个副本空间再 lerp。
- **大跳变**:相邻两条权威样本的环面距离 > `SNAP_DIST = 128 px` ⇒ 清位置历史、一帧落位。依据:常态相邻包位置差 ≈ 10px(300px/s × 33ms)、丢包 200ms 也只有 ≈60px,而回溯 / 重生 / 换边是几百~几千 px ⇒ 128 落在两者之间,两侧各留约 2 倍余量。
- **幽灵碰撞体不跟插值**:它跟未经平滑的最新快照锚点(预测面要最小陈旧)。代价:看得见的对手比「挡你的对手」晚 ≤ 67ms —— 有意的交换,别把幽灵体也接上插值。
- ⚠ **零守卫**:以上都是观感项,按仓主裁定不写自动守卫(见 [`tests.md`](tests.md) 的「不写清单」),只能人眼验收;改动时盯「对手横向跑动是否连续、是否被梯子 / 墙盖住」。

