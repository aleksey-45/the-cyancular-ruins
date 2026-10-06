# 渲染管线与补间形变

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:渲染管线(Level0.tscn) · 补间形变(squash & stretch)。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 渲染管线(Level0.tscn)

根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体/玩家/敌人)渲染进 SubViewport,`PostProcess`(post_process.gd)做像素缩放裁切 + 倒地暗角。相机 `camera_2d.gd` 带前瞻/死区。注意:冒烟测试把武器挂到根 Window 而非 SubViewport。

- **墙体/水体图集构造 = `core/sim/terrain_atlas.gd`(`class_name TerrainAtlas`,2026-10-03 从 `Level0` 上提)**:「源砖 → 图集 → TileSet」那半收在本类,`Level0._create_wall_tileset()` / `_create_water_tileset()` 现在只剩**转发**(墙体就一行 `return`;水体多一行给水面 shader 赋采样源)—— 行为逐字不变。★ **上提的唯一理由**:主菜单背景要"**真实的那个世界**",必须与 `Level0` 用**同一份**像素映射 —— 复制一份 = 第二个真相源(源砖换了 / 象限映射改了,菜单里的世界与游戏里的就对不上,且**不报错**)。★ **搬的只是构造**;铺贴(`_paint_maze` / `_paint_water`,依赖 TileMapLayer 与 3×3 环面副本)仍留在 `Level0`。★ 本类**零 autoload 依赖**(TILE_SIZE 由调用方传参),可 `-s` 测。
  - **墙体 = 16px 象限制**:`make_wall_tileset()` 把每块 32px 源砖拆成 4×4 个 8×8 象限、各最近邻 2× 放大成 16×16,拼成 **16 列(4×4 象限)× 22 行(纹理 1-22)** 的 TileSet(`tile_size=16`);`_paint_maze` 铺 **16px 子格**,瓦片坐标 = `Vector2i((y%4)*4 + (x%4), tex-1)`(**子格取哪个象限由它在格内的位置推出**,不是按形状掩码),3×3 环面。(★ 旧文档那句「墙体 64px / `Vector2i(shape, texture-1)` / 16×20 atlas」是 **cyrm v4 之前**的形态,已随 v4 子格化改掉。)
  - **水体 = 64px 整格**:`make_water_tileset(ts)` 走另一套(水砖放大到 ts×ts,按 2×2 shape 掩码挖象限 → **16 形状列 × 1 行**),`_paint_water` 按 `shape_of(v)` 取列。
  - ★ **`TerrainAtlas.SKY_COLOR`(= `b0e5f6`)是"空气格 / 清屏色"的单一来源**:`Level0` 的 `RenderingServer.set_default_clear_color()` 与主菜单背景底色**都读它**(用户 2026-10-03:"背景颜色不对,要和局内一致")。★ 它是**世界底色**,**不是** UI 调色板 token(不归 `UiFactory`),也**别**拿去改 `MapCatalog.BG`(那是选图面板缩略图的底,语义不同)。
- **碰撞**:`core/sim/collision_builder.gd`(`class_name CollisionBuilder`,静态可测)把形状掩码展开成 250×150 的 32px 子格(每 64px 格 → 2×2),贪心合并矩形(ts=32)后按 **9 环面副本偏移**实例化(每块矩形 ×9,共享同一 shape)。**永久墙建一个整图节点、建一次不动;可破坏层按分块存节点**(块边长 12 格 ≈ √地图边长,块内一次贪心 + 9 副本),摧毁时只重建所在块 → 重建成本 O(块面积)。**只有 type=wall 产生碰撞**,通道(梯子/锁链)可走/可爬。
- **`core/sim/collision_aabb.gd`(`CollisionAabb`,静态:从任意节点求**启用中**碰撞体的世界 AABB)是三个调用方的共同几何来源**——激光命中、water 脚底偏移、飞鸟避障矩形;各自自备兜底值(18px / 24px / 40×40),**只在目标真没有碰撞体时才该生效**。★ **多边形与形状必须分开判**:Godot 4 里 `CollisionPolygon2D` 与 `CollisionShape2D` 是**并列类**(编译器会拒绝 `多边形 is CollisionShape2D`),而本作**所有**身体(三敌人 + 玩家 5 个姿态箱)都只用多边形 —— 只判形状 = 三个调用方**全部静默走兜底**(2026-09-15 修:激光判定框长期是"原点周围 36×36"、与身体无关)。守卫:`enemy_logic_smoke` 末节 `_phase_collision_aabb`。
- **`core/sim/unstick.gd`(`Unstick`,静态:把压进实心格的矩形**向上挤出去**)**:`push_up_dy(rect, ts, max_cells) -> float` 返回**刚好清空**所需的最小位移(0 = 没卡住),逐格向上找第一个整框清空的位置 —— **不是整格跳**(一格 64px,轻嵌就弹一整格很突兀,也让"落点与何时开始模拟无关"更难对)。格范围骨架走 `TileQuery.topmost_solid_row()`(住 `tile_query.gd`)。★ **探测矩形四边内缩 `PROBE_INSET`(0.5px)不是可选项**:`floori(rect.end / ts)` **含端点**,正好对齐格线的矩形会把右边那一列也算进去 —— 那一列是墙的话会每帧判成"卡住"往上弹。当前唯一调用方是 `WeaponPickup._physics_process`(两处:`move_and_slide` 之后**以及 `_settled` 的早退分支里** —— 停稳后 `move_and_slide` 再也不跑,被后盖上的可破坏砖压住会**永久钉死**)。几何走 `CollisionAabb.world_rect`。FlyBird 的"向下逃逸"是另一套,**没动**。守卫:`tests/smoke/unstick_smoke.gd`(`-s`,含"正好对齐贴墙不算卡"这条钉内缩的用例)。
- **世界构建**:`core/sim/world_builder.gd`(`class_name WorldBuilder`,静态):`load_grid()`(地图→current_grid/TileDefs/地图像素尺寸)、`build_sim(parent, grid)`(碰撞:永久墙+可破坏分块+攀爬基座条)。单人 Level0 与 PvP 客户端/服务器共用。

### 补间形变(squash & stretch)

`scenes/effects/squash_stretch.gd`(`class_name SquashStretch extends Node`)—— 纯表现层组件,挂到玩家 / 三只敌鸟 / 对手副本上,**只写 `animator.scale`**。计算模型是两个标量相加:`_air`(每帧由 `vel_y` 重算,无状态)+ `_impulse`(事件累加 + `MathUtil.approach` 指数回归)。**单标量**是刻意的 —— "冲刺中落地""起跳瞬间被击中"这类同时事件天然叠加,不需要优先级状态机。幅度上限 `squash_amount` = **0.06**(用户 2026-09-21 实测后从 0.10 收到 0.06;同批 `squash_recover` 9→16、`squash_air` 0.30→0.10),`v` 钳在 `[-1,1]` 故永不越界。

- ★ **落地挤压由 `vel_y` 无状态推导**,不需要 `_was_on_floor`:判据是 `if on_floor and vel_y > _land_min_vy`,阈值**不是字面量** —— 玩家侧 = `PlayerParams.squash_land_min_vy`、敌人侧 = `EnemyParams.squash_land_min_vy`(当前**同值 220.0**)。与之配套,宿主必须在 `move_and_slide()` **之前**缓存 `_pre_move_vy`(与帧首的 `is_on_floor()` 配对),且**必须自己把"不是摔下来的"下坠速度滤掉**。
- ★★ **"只在落地那一帧成立"是过滤之后的结论,不是判据本身的性质**:"`is_on_floor()` 时不施重力 ⇒ 地面上 `vel_y` 恒 0"这个前提**只对重力路径成立** —— 水中下沉(`player_swim_down` = 320)与梯子下行(720)都是"站在地面/水里仍然写正 `velocity.y`",不滤就会每帧重触发落地项(梯底按住 S 是整个对局里真正的每帧违规)。故**宿主的契约**是:传进 `tick()` 的 `vel_y` 必须是"地面真正吸收掉的"那个下坠速度,否则传 0 —— 玩家侧即 `_pre_move_vy = 0.0 if (in_water or latched) else velocity.y`(敌人侧**刻意不过滤**,见下)。敌人侧状态事件走 `_on_state_entered(s)` 虚钩 —— 三只鸟各有自己的 `enum State`,基类不能硬编码状态名。
- ★ **纯视觉:不进 `capture_state()`/`restore_state()`、不碰碰撞箱。** 玩家侧 `tick` 放 `_physics_process` **最首行**(倒地早退之前),否则倒地后 scale 会卡在最后一个形变值上;敌人侧同理(放 `_is_far_sleeping()` 早退之前)。
- ★★ **已知表现副产物(登记不修)**:缩放绕精灵**中心**(`AnimatedSprite2D` 没有 pivot)⇒ 挤压时**画出来的底边会上抬 ~4~5px**、拉伸时下沉 ~3.5px(约体高的 4%)。**这是真现象、不是缺陷**,为 ±6% 的观赏性特征不值得给 `animator.offset` 补反向平移(**那会破"只写 `animator.scale`"**)。**别把它当 bug"修"**:用 `offset` 补正是**没有任何探针看得见**的那种改法,`squash_stretch_probe.tscn` 专门加了一条 `offset == Vector2.ZERO` 的断言堵它。★ 那两个数**每次跑都被打印**(三栏像素包围盒)。
- ★ **倒地必须 `suppressed = true`**:副本给根节点设了 `rotation = -90°`,而 animator 是其**子节点** → 此时写 `scale` 会沿**转过的轴**挤压,尸体横着变宽。
- ★ **已知边界(登记不修)**:`prediction_rollback.gd` 的重放是**直接调 `_physics_process`**,而 `_impulse` 不在 `capture_state()` 里 → 回滚时挤压包络会**重播一次**(纯视觉,表现是"弹一下")。`_air` 项无状态,不受影响。
- ★ **`_impulse` 有两个写入口,各自钳一次 `[-1,1]`**:`impulse()` 的加法,以及 `tick()` 里 `_impulse -= _land_gain * k` **之后紧跟的一行 `clampf`**。`_apply()` 里钳 `final` 只保住**画面**不越界,保不住内部量 —— 宿主违约时那一次减法每帧重来,而无钳位时会收敛到定点 ⇒ 之后任意一次 `impulse()` 的**正**增益都加在更负的基数上,起跳/冲刺的拉伸被压低。守卫:`squash_stretch_smoke.gd` ⑦e。
- 守卫:`tests/smoke/squash_stretch_smoke.gd`(`-s`,纯逻辑:参数镜像 / 九相 / 上下行饱和 / ⑦e 写入口钳位)+ **四条场景探针**:`squash_stretch_probe.tscn`(真渲染,含"形变不得改变全局位置"与"形变不碰碰撞箱"两条硬约束断言 + **像素级方向断言**,取图供人眼验收 —— **图自己读**)/ `squash_host_water_probe.tscn`(玩家侧过滤谓词)/ `squash_host_enemy_probe.tscn`(敌鸟侧:状态映射 / SLEEP 不挂钩 / HURT / 睡眠缓存归零 —— 这一面是本特性**唯一真出过 bug**的地方)/ `squash_replica_probe.tscn`(副本)。
- ★ **对手副本**复用同一个组件,数据从快照的 `vel`/`pose` 本地推导 —— `vel` 本来就在载荷里,只是副本此前没读,**协议零改动**。★ 副本**不做受击挤压**(快照里没有受击事件,从 `hp` 下降推会在 AoE 多段伤害时误触发)。tick 放副本的 `_process` 而非 `apply_snapshot`(后者没有 `delta`)。
- ★★ **副本的落地判据是「两半」,`pose != FLY` 那一半单独不够**:副本没有物理,`on_floor` 是**推导**出来的(`(not _downed) and _pose != POSE_FLY and absf(_vel.y) < LAND_VEL_EPS`)。`pose` 只是"站在地上"的**代理**,它在**水中下沉**(姿态被强制成 MOVE/STAND,而 `vel.y` 恒为 `player_swim_down` = 320)与**空中冲刺**两种状态下**同样为真、而 `vel.y` 并不趋于 0** —— 只看代理会让落地项每帧重触发,把对手压成持续/反向的形变。★ 水项用**客户端本地网格查询**(`_in_water()`)而**不是协议字段**:本体的 `in_water` 本身就是纯位置网格查询。注:爬梯那一半**刻意不补**(客户端只有无状态的位置代理,对"路过梯子"会误触发),残留如实登记。
- 守卫:**`squash_replica_probe.tscn`**(四相,断言全落在 `animator.scale` 上:水中下沉全程中性 / 干地真落地仍挤压(反例)/ 落地判据两半都在 / 倒地强制中性)。四相各配一条**具名变异**且已验证"只打红自己那一相"。★ 相④ 的判据窗口是**倒地后 8 帧**的 max dev。★ 另有一条**相⓪**:把夹具字典的**键集**与 `server/match/match_snapshot.gd` 里那张玩家载荷字段表**双向对账** —— 夹具键是手写的、无人校验,而删掉生产端的 `"vel": p.velocity` 会让**四相全绿**、对局里对手的形变**静默消失**;读不到源文件时报**红**。
- ⚠ **两侧的水过滤刻意不同款,别去"统一"**:玩家侧滤 `in_water or latched`,**敌人侧刻意用裸 `velocity.y`**(原地有登记注释)。实测敌人侧 `_in_water ∧ is_on_floor()` 的重叠**真实存在**,但水的写入被钳在 −260/+160、**下沉侧 160 < 阈值 220** ⇒ "幽灵挤压"结构上不可达,而过滤**会吃掉真实的落水挤压**。两侧结论不同是**实测差异**,不是不一致。

