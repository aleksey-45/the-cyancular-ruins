# 渲染管线与补间形变

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 像素契约(2026-11-10,阶段 0 + 方案 A)

> 口径:**地形/水/背景 1 美术像素 = 2 世界像素**;**角色/武器/拾取物 = 2.5 世界像素**(恢复旧版视觉权重与碰撞尺寸);**子弹视觉 = 1 世界像素**。`cam_zoom = 1.0` ⇒ 1 世界像素 = 1 屏幕像素,所以角色/武器 1 美术像素 = 2.5 屏幕像素(非整数,旧版是 1.875,同样非整数)。
> 这是"场景/敌人/武器/主角看起来是不是同一款游戏"的总闸;改任何 scale / zoom 前先读这一节。

- **密度分档**:地形/水由图集管线固定(32px 源砖 → 8×8 象限 → 最近邻 2× → 16px tile ⇒ 2 世界px/美术px);玩家、玩家副本、黑鸟、跳鸟、飞鸟、武器、地面拾取的根 `scale = 2.5`(与旧版一致;root 2.5 也把碰撞体恢复到旧尺寸)。子弹根 scale 仍是 `bullet_size`(物理口径不变),由 Sprite2D 局部缩放补到 `ART_WORLD_PX/size`(`ART_WORLD_PX = 1.0`)⇒ 子弹视觉 1 世界px/美术px,不抢角色/武器的视觉权重,碰撞体不随视觉放大。蓄力箭世界缩放 = `ART_WORLD_PX × 1.5`(与飞行箭同标尺)。
- **相机**:`PlayerParams.cam_zoom = 1.0`;相机每帧末尾把 `global_position` 吸附到整数屏幕像素(`round(pos × zoom) / zoom`)。平滑/前瞻/震屏都是连续浮点,不吸附的话栅格逐帧落在新的亚像素相位上。
- **过滤**:世界内一律 NEAREST。项目默认 `rendering/textures/canvas_textures/default_texture_filter = 0`;`WallLayer`(TileMapLayer)另显式 `texture_filter = 1` —— 它此前继承引擎默认 Linear,是全画面"场景糊、精灵锐"的唯一来源(实测砖纹理内部同值率 78%→84%)。
- **鱼眼默认关**:`PostProcess` 的 `barrel_enabled = false`(`toggle_barrel` 仍可临时开)。桶形是逐半径连续重采样:中心 1:1、边缘 ≈0.78×,颗粒度随屏幕位置漂移 20~30%,与固定像素栅格不可兼得。
- **像素化光照(色阶 + 抖动)**:地形受光/斜影/精灵形体光的采样坐标吸附到美术像素块(`art_px = 2 * cam_zoom` 视口像素);`lighting_params.tres` 全局默认 `terrain_steps = 4` / `terrain_dither = 0.35`、`form_steps = 3` / `form_dither = 0.3`;玩家/副本用各自 attach 里的 override(`steps 5` / `dither 0.25`)⇒ 明暗是几档硬层、层边用 4×4 Bayer(格 = 1 美术像素)打散成细点。把 steps 设 0/1 = 连续亮度(可选)。★ 2×2 Bayer 只有 4 阈值会成规则格纹;抖动格与美术像素不对齐会变成屏幕噪点。精灵侧 `form_light` 的 ndl 重映射窗口 = `form_edge_lo/edge_hi`(默认 0.00/0.70,下移 = 亮面更大),圆度 = `shape_round`(玩家/副本 1 = 正圆,鸟/枪 0 = 拟合椭圆)。
- **已知例外(有意保留,改前先想清楚)**:① 爆炸 `scale = 13`(≈13 屏幕px/美术px;要统一得把 48px 帧重画到 ~312px);② 背景四层 texel = 12/16/24/48 屏幕px(景深设计;层 4 的 f=0.75 在 zoom=1 下是 21.33px,非整数);③ squash & stretch 把 `animator.scale` 写成 0.94~1.06 非均匀值(落地/起跳瞬间短暂破坏栅格);④ 武器/子弹按角度连续旋转 + 枪口 bob —— 旋转本身不可能轴对齐。
- **代价(方案 A 落地时已知)**:可视世界从 2560×1920 缩到 1920×1440 世界px(边长 −25%、面积 −44%);角色/武器根 scale 保持 2.5(视觉与碰撞尺寸与旧版一致,非整数美术像素由 NEAREST 承担)。
- **验收**:渲染域零自动守卫(见 [`test-economy.md`](test-economy.md) §1),以上观感项只能人眼 + 同机位截图对比。

## 渲染管线(`scenes/level_0.tscn`)

> ★ **守卫边界(2026-11-08 仓主裁定)**:渲染表现与数据细节**不写自动守卫**(见 [`test-economy.md`](test-economy.md) §1);渲染域唯一的自动守卫是启动结构探针 [`tests/probe/level0_boot_probe.tscn`](../../tests/probe/level0_boot_probe.tscn)(23 条:世界数据/四视口/墙体铺贴/地形剪影镜像/水体合批/PostProcess 通道/地形掩码与剪影通道/相机与通道相机同步/形体光/碰撞/收尾状态)。原 water_atlas / wall_tint / tint_parity / bg_parallax / torus_camera 五支数据契约探针已删除。

- 根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体 / 玩家 / 敌人)渲染进 SubViewport,`PostProcess`(`post_process.gd`)把世界纹理合成到屏幕:中心裁剪(鱼眼默认关,见上)+ **天空合成 + 昼夜光照(环境光 / 斜投影影)+ 发光通道叠加** + 受击/低血/时间玩法视效(倒地暗角、残血边缘暗角只在屏幕边缘,中心保持干净,纯客户端、不挡 HUD)。
- **世界里的一切都会被乘 `ambient`** —— 这是理解渲染层的第一句话:UI 辅助层(换弹读条 / 预瞄线)挂在世界子树里就会一起被压暗;发光体想"夜里更亮"就必须走发光通道(见下)。
- 渲染材料分三层:`core/present/day_cycle.gd`(纯函数:一整天怎么亮)→ `post_process.gd`(把结果喂 shader)→ `core/present/form_light.gd`(逐精灵的形体光)。shader 只做合成与逐像素光照,不持有第二个真相源。

- 相机 `core/present/camera_2d.gd` 在 `_process` 里跟随目标:死区(`PlayerParams.cam_deadzone`)+ 指数平滑(`cam_smooth_x/y`)+ 前瞻(`cam_lookahead_x`,按 `vx / move_speed` 归一)+ `cam_y_bias`;**末尾统一吸附到整数屏幕像素**(像素契约,见上节);环面世界走连续空间跟随,单帧位移 > `SNAP_DIST = 400px` 视为真传送(复活 / 回退 / 换边)直接重锚、不做平滑。另有 `shake(amount, duration)`:包络 = `amount * (剩余/时长)^0.7`(尾段比线性长),且**不降级**——比当前剩余包络弱的震动被忽略,否则开火/受击的小震会把爆炸大震顶掉。联机里爆炸震由 `Explosion.client_cam_shake()` 在视觉副本爆炸时补(客户端 bullet 是 `apply_damage=false`)。`PlayerParams.cam_lookahead_y` 目前无人读,别按它改行为。零守卫(原 `torus_camera_probe` 已删):改跟随/死区/震屏只能人眼试玩。

- 图集构造 `core/sim/terrain_atlas.gd`(`TerrainAtlas`):源砖 → 图集 → TileSet;`Level0._create_wall_tileset()` 只剩转发。**图集按描述符行烘**(行 = 去重排序后的 v4 描述符,颜色辅码烘进像素),不再按"每纹理一行"。
  - **像素数学 `TerrainAtlas.tint_color(c, desc)`** = 旧浏览器编辑器 tint 数学的移植(唯一规范;源已退役,历史见 git):HSV(不是 HSL)、色相偏移 (hue档−4)×15°(fposmod 360)、bri/sat 是**乘法**乘数 (档+6)/10、alpha = a×档/7、8 位落地只有一条规则 round(clamp01(x)×255)。★ **零守卫**(原 `tint_parity_probe` 已删):改 `tint_color` 只能人工对拍 golden 向量。
  - **墙体 = 16px 象限**:`make_wall_tileset_for(descs)` / `build_atlas_image_for(descs)` 把每块 32px 源砖拆成 4×4 个 8×8 象限、逐像素 tint、各最近邻 2× 放大成 16×16,拼成 16 列(4×4 象限)× descs.size() 行的 TileSet(`tile_size = 16`);`_paint_maze_copies` 铺 16px 子格,瓦片坐标 = `Vector2i((y%4)*4 + (x%4), _desc_row[desc])`(desc 取 `MazeGenerator.current_subdesc`;**只铺视口可见环带**——中心整图 + 其余 8 份按 `视口尺寸 / cam_zoom` 裁条带,整圈全铺是 5~6 倍浪费:newfactory 实测 559,728 → 176,024 格)。缺失描述符走 `TerrainAtlas.fallback_row` 回落**该纹理的中性行**并 push_warning 一次;合成网格路径(subdesc 为空,探针直写 current_subgrid)行号语义退回"每纹理一行中性"。回溯 `_restore_sub` / 换局 `reset_destructibles` 的瓦片行号同走 `_desc_row`(后者取 `_pristine_subdesc`,与 `_pristine_subgrid` 同点保存)。零守卫(原 `wall_tint_probe` 已删):改图集行/tint 只能人眼。
  - **水体 = 单层合批,不走 TileMap**:`Level0._paint_water_copies` 把**所有液体格**按格级描述符(`_water_desc_of`,该格 16 子格的多数描述符,平票取小)分桶;每桶建一张两行图集(`_make_water_atlas`:上行水体砖 / 下行为水面砖,都按该描述符 tint),交给 `scenes/effects/water_surface_batch.gd`(`WaterSurfaceBatch`)画成一张静态网格——顶点起伏 + 横向流动条纹。水面与水体同色、同 alpha、同管线,所以没有"两层对不齐"的接缝。`TerrainAtlas.make_water_tileset_for()` 现只剩探针在用(生产不再铺水 TileMap)。
    ⚠ **零守卫**:分桶规则(多数票 / 平票取小)、两行图集的行序、两块水砖的 0-based 下标都是**实现细节**,不写自动守卫(渲染观感按 [`test-economy.md`](test-economy.md) §1 只能人眼;原 `water_atlas_probe` 已删)。
  - 主菜单背景 `bake_map_image(path, cell_px, air)` 同样吃描述符(`MapFormat.load_subgrid_with_descs` 的 descs,内部自建 row_of)⇒ 辅码颜色一并烘进背景,与对局是同一套像素。
- ★★ **两块水砖是合批图集的两行**(不是两个 TileMapLayer):`TerrainAtlas.WATER_BODY_BRICK = 20`(0-based ⇒ 纹理 21「水」,均匀半透明填充)在上行;`WATER_SURFACE_BRICK = 21`(纹理 22「水面」,自带顶边水线)在下行。每行都按格级描述符 tint ⇒ 水面与水体同色。零守卫。
  - `TerrainAtlas.SKY_COLOR`(`2f4256`)只做「空气格 / 清屏色」:主菜单背景底色与 `Level0` 的 `RenderingServer.set_default_clear_color()` 读它。★ **对局里的天空不在这一层** —— 世界视口是 `transparent_bg`,空气 alpha=0,天空由 `post_process.gdshader` 按昼夜合成(见「昼夜与光照」)。别把它当对局天空色去调,也别改 `MapCatalog.BG`(选图缩略图底色,语义不同)。
- 碰撞 `core/sim/collision_builder.gd`(`CollisionBuilder`,静态可测):形状掩码展开成 16px 子格(每 64px 格 → 4×4),贪心合并矩形后按 9 环面副本偏移实例化(每块矩形 ×9,共享同一 shape)。永久墙建一个整图节点(9 环面副本各一份,物理跨接缝必需)、建一次不动;可破坏层按分块存节点(块边长 12 格),摧毁时只重建所在块。只有 type=wall 产生碰撞。
- `core/sim/collision_aabb.gd`(`CollisionAabb`:从任意节点求**启用中**碰撞体的世界 AABB)是激光命中、water 脚底偏移、飞鸟避障矩形的共同几何来源;三者各带兜底值,只在目标真没有碰撞体时生效。多边形与形状必须分开判(`CollisionPolygon2D` 与 `CollisionShape2D` 是并列类);本作所有身体(三敌人 + 玩家 5 个姿态箱)都只用多边形。
- `core/sim/unstick.gd`(`Unstick`):`push_up_dy(rect, ts, max_cells) -> float` 逐格向上找第一个整框清空的位置(0 = 没卡住),不是整格跳。探测矩形四边内缩 `PROBE_INSET`(0.5px):`floori(rect.end / ts)` 含端点,不收会多算一格。唯一调用方 `WeaponPickup._physics_process`(`move_and_slide` 之后 + `_settled` 早退分支里)。几何走 `CollisionAabb.world_rect`。
- 世界构建 `core/sim/world_builder.gd`(`WorldBuilder`,静态):`load_grid()`(地图 → current_grid / TileDefs / 地图像素尺寸)、`build_sim(parent, grid)`(碰撞:永久墙 + 可破坏分块 + 攀爬基座条)。单人 Level0 与 PvP 客户端 / 服务器共用。

## 昼夜与光照

数据流:`DayCycle`(纯函数,无节点依赖)→ `PostProcess` 写 shader uniforms → `post_process.gdshader` 合成。

- **外部视口**:主菜单背景/编辑器预览这类运行时才建视口的调用方,在设完 `WorldViewport/BgViewport/PreviewViewport` 尺寸后必须调 `PostProcess.refresh_viewport_bindings()`(重算 `crop_scale`/`viewport_size`)。`PostProcess._ready` 里按默认 2×2 算的那份值,不重算会让地形受光/影子和镜头移动错位。\n- **时钟**:`DayCycle.DAY_CYCLE_SECONDS = 120`(现实 120s = 游戏 24h,1s = 12 分钟;2026-11-09 用户口径),开局 `DAY_START_HOUR = 6.0`。`PostProcess.day_hour` 是唯一当前时刻;加速/倒流由 `PostProcess._time_rate()` 乘进推进速率(只影响时钟,不影响物理)。主菜单的实时光影背景也走这条时钟(`ui/menu_backdrop.gd` 的 PostProcess)。
- **太阳高度角是三角波,不是正弦**:`DayCycle.sun_at(h)` = `elev = 90 − |15·(h−12)|`(二分点/赤道的化简式),`azim = ∓1` 以正午为界。所以影子方向一天里**自己翻面**。月亮与之反相(18:00 升、00:00 天顶)。
- **环境光** `DayCycle.ambient_for(hour, moon_amt)` ∈ [0,1],乘性。★ **准确的不变量**:「世界层的乘性链」(ambient → 影子 → 地形受光)只压不抬,**最终像素不受此约束** —— 早先文档写成「永不发光是结构保证」,已经失真。现有例外(改动时别再把它们当违例):`form_light` 的 `boost`(亮面 1.15×)、天空是绝对值不经过 ambient、发光通道 `COLOR.rgb += gl`、受击红闪、回溯贷款 `+= `、`amb_sky_link` 把 ambient 抬到自然曲线之上(仍 ≤1)。真正的判据是「亮度变化是否跟随光源、幅度是否克制」,不是「是否 >1」。白天 = 辐照 ∝ sin(高度角);太阳项把有效高度抬高 18°(民用晨昏),否则黎明/黄昏会掉到天光底、比半夜还黑。月光峰值 `MOON_SCALE = 0.26` 必须低于晨昏的太阳项。**正午环境光恰为 1.0(全天最亮的一帧)**。
- **天空色** = `DayCycle.sky_base(hour)`,17 个关键帧按时刻插值。★ 插值走 **RGB 直线**,不走 HSV 色轮:最短弧从橙到蓝会经过品红/紫、黄昏"各种颜色乱窜"(实测)。★ 直线插值的坑是中点掉饱和(橙→夜蓝中点只有 0.31),所以黄昏→夜手工插了玫红/紫罗兰/靛蓝三帧把路径"拱"起来 —— **单纯增加采样点无效**(直线上的点还在直线上)。
- **天空纵向渐变**:shader 用屏幕纵坐标做一个弯曲坐标(`sky_curve` + `sky_band_pow`)在 `sky_top`/`sky_bottom` 之间插值,上亮下暗。**不做量化**(曾试过 8/16 条带,量化就是"像素风条带",用户否决)。
- **斜投影影**:遮挡源分两种(见 `_occ_shadow`):**地形像素**的投影用世界纹理 alpha(地形+实体,玩家/敌人能像环境物体一样把影子投到墙面/地面);**实体/空气像素**只用 `TerrainViewport` 的地形剪影(否则实体会在空气里拖出浮空影子)。`SOLID_A = 0.90` —— 只有不透明才算遮挡体,半透明(水、子弹曳尾 alpha 0.55、预瞄线 0.6)不投影。★ 地形受光(`_terrain_lit`)仍只用地形剪影。判据是"先沿光方向穿出自己,再撞到的东西才挡我",少了穿出自我的那步会让整面墙均匀变暗。影长是**像素常量**(`CAST_PX_DUSK`,晨昏最长 8px),不是 `1/tan(高度角)` —— 世界是薄 z 横切面,没有厚度可投。影子落在空气与实体上;深浅按"最近一次被挡"的位置衰减(`SHADOW_FAR`)。
- **环境光是颜色不是标量**:`ambient_color = (天光色相 × amb_tint_strength 混白) × 强度`。天光色相取当前 `sky_base` 归一化到最大通道 1(丢掉亮度),所以黄昏偏暖橙、夜里偏蓝、正午近白;三通道恒 ≤ 1,只染色不提亮。参数 `amb_tint_strength`(默认 0.35,0 = 纯白)。
- **地形受光**:TileMap 没有逐格法线,所以对每个实心像素向上 / 左 / 右各走 8 步 × 6px 探测空气(`_march_steps`,三步距离合成近似外法线),再与 `sun_dir` 点积——墙的左右脸随太阳方向变化,不是"只向上找顶面"。★ 这是**几何**,所以同一面墙无论移到屏幕哪里亮度都一样。★「实心」的判据来自 `TerrainViewport` 的地形剪影,不是世界纹理 alpha(否则精灵像素会被当成地形、再乘一次地形受光,即玩家下半身硬边黑块)。**已删除**旧的"屏幕空间大气压暗"(`atmo_depth`):它按屏幕高度压暗,是滤镜不是光照,也是"一切都黑"的来源之一。
- **光照像素化(色阶 + 抖动)**:量化的是**光照系数**(地形深度比值 / 精灵 `ndl`),不是最终屏幕色 —— 后者会毁掉美术调色板、让天空重新出色带、破坏「世界层乘性链」。色阶数默认 6(`form_steps` / `terrain_steps`);地形用 **4×4** 有序 Bayer(格 = 1 美术像素),精灵侧也是 **4×4**(`form_light.gdshader`)。★ 抖动必须**锚在精灵本地坐标 / 世界纹理坐标**,锚屏幕的话相机一动图案就会在物体上"爬"。量化后 `clamp(x, 0, 1)`,所以仍 ≤ 1。
- **暗部颜色**:影子乘数 = 当前**环境光色相再压暗**(月光下再压一档),不是写死的冷蓝——阴影是"这种光更少",不是"换了一种蓝光"。规则同上:压红留蓝,不用中性灰;乘性、三通道 ≤ 1。

## 地形剪影通道(TerrainViewport)

- 世界纹理的 alpha 不能当地形遮挡用:地形与精灵在里面都是不透明像素。`level_0.tscn` 另有一个 SubViewport `TerrainViewport`(`transparent_bg`、半分辨率、自带 `TerrainCamera`),里面只放 `TerrainLayer`(与 `WallLayer` 同一份 TileSet、同一份 cells)⇒ 渲染出**只含地形**的剪影图。`PostProcess._bind_terrain()` 发现同级 `TerrainViewport` 后,把纹理与 `terrain_occ_gain = 1` 推给 shader。
- shader 的地形判定入口 `_occ()`:有剪影通道时采 `terrain_tex`(`filter_nearest`),否则退回 `occ_tex`(= 世界纹理 alpha,旧行为)。因此精灵像素落在空气/地形洞里时 `_occ = 0`,地形受光不再被刷到实体上。斜投影影走 `_occ_shadow(suv, allow_world)`:地形像素允许世界 alpha 参与(实体可投影),实体/空气像素只用地形剪影。**其余光照公式一行未改。**
- 铺贴必须镜像:`Level0` 的墙层写点全部走 `_set_wall_cell` / `_erase_wall_cell`(整图铺贴、砖被摧毁、回溯复原、换局复位),两层 cells 一致是硬约束。★ 漏镜像不报错,只会让实体重新被地形光误伤 —— 承重判据 = 探针里「两层 TileSet 相同且 used_cells 数一致」。
- 相机同步在 `_sync_glow_camera()` 里:`global_position` / `rotation` 与世界相机相同,`zoom = 世界 zoom × 0.5`(半分辨率覆盖同一片世界;shader 按 uv 采样,与分辨率无关)。
- **降级**:找不到 `TerrainViewport`(主菜单实时光影背景、编辑器预览这类运行时自建视口的调用方)⇒ `terrain_occ_gain = 0` ⇒ 退回世界纹理 alpha,行为与加通道之前完全一致,调用方不用改接线。
- 代价:铺墙多写一份 cells(加载时间略增);遮挡判定降到半分辨率(1 texel = 2 世界像素 = 1 美术像素),地形边缘的受光 / 影子最多差 1~2 世界像素。观感(实体不再被地形光误伤、地形亮度不变)零自动守卫,只能同机位截图 + 人眼对比。

## 发光通道(GlowViewport)

- 发光通道用独立的 SubViewport:`GlowViewport`(半分辨率、`transparent_bg`)+ `GlowCamera`。`PostProcess._sync_glow_camera()` 每帧把世界相机的 `global_position/zoom/rotation` 抄过去(用实际位置,跟着震屏动)。
- 发光体必须挂在 `PostProcess.glow_root()` 返回的通道里,由 shader 在**整个光照之后**用 `COLOR.rgb += gl.rgb` 叠加。★ 为什么不能画在世界里:世界里的一切都被乘过 `ambient`,发光体会跟着变暗 —— 与"夜里更亮"正好相反。
- 发光资产是**美术遮罩**:`<name>_light.png` 与主图集同布局,白色标记 + **A 通道装强度**;帧数据里用 `light_image` 字段指过去,`SpriteFramesIO` 用同一套 cells 构帧 ⇒ 帧索引天然同步。
- 需要"很弱的边缘光"时不用重画遮罩:`light_halo_px` / `light_halo_strength` 让 `SpriteFramesIO` 在加载时按 smoothstep 径向衰减生成光晕(只增不减,原标记的 alpha 保留)。
- `glow_gain = 0` 表示没有通道(其它场景/测试),整段跳过。

## 形体光(`core/present/form_light.gd`)

- 目的:让玩家/武器/敌人有体积。环境光只是**全局乘一个标量**,不区分朝向,所以精灵会读成平贴纸。
- **TAG 驱动渲染策略**:`light_model` = `flat`(默认,不做形体光)/ `ellipsoid`(鸟)/ `cylinder`(枪)/ `parts`(运行时按连通块切 5 块的兜底)/ `guide`(玩家:读打光辅助图)。`sdf` 分支(距离场法线图)与 `SpriteNormalMap.for_texture()` 现网**不可达**,别按它改行为。
  挂载时显式传参:`FormLight.attach(animator, "ellipsoid")`;敌人走 `@export var light_model`。
- **解析形状,不用距离场**:椭球法线 `p = v_local / light_size`(clamp ±1)、`z = sqrt(1 − p·p)`。
  ★ 距离场的梯度在"最近边切换"处**不连续**,一定留下宝石切面(实测玩家被读成圆锥/棱锥);解析形状的法线是连续函数,没这个问题。
- **`v_local` 必须来自 `vertex()` 的 varying**:`fragment()` 里的 `VERTEX` 是**世界坐标**,直接除以半尺寸会被 clamp 到 ±1 ⇒ 法线恒定、明暗完全消失。
- **半尺寸走质心椭圆拟合**:按图集 alpha 加权质心 + 二阶矩(`SpriteNormalMap.ellipse_fit`),不是逐帧包围盒——包围盒会被单帧凸起带偏;一个尺寸全帧共用(逐帧算会让动画中明暗跳动)。
- **先提亮、再只压暗面**:`COLOR *= (1 + boost) × mix(1−gain, 1, ndl)`。`boost` 让亮面可高于贴图原值(默认 0.15 ⇒ 正午最亮 1.15×),
  这是**有意**破例,别按"最终像素 ≤ 贴图"去校验;`形式光` 只保证"光照系数"这一层是乘性的。
- **量化 + 抖动**:`ndl` 先按 `edge_lo/edge_hi` 重映射(默认 0.00/0.70),再量化 `form_steps`(默认 6)档,配 4×4 Bayer(`_bayer4`,`form_dither`,锚精灵本地坐标)。
- **打光辅助图(玩家专属,`assets/textures/player_shade.png`)**:与 `player.png` 同布局(200×200、48px 网格);**R/G = 该像素所属部位的局部受光坐标**(0.5=部位中心),**B = 贴体 AO**(手/腿贴住处压暗),A = 不透明掩码。`guide` 模型采它算明暗并乘 `1 - ao * ao_strength`;文件缺失时自动回退 `parts`(运行时连通块切 5 块)。工具:`gen_player_shade.gd`(见 git 历史/一次性脚本),改受光与接触暗部直接改这张图。
- **玩家专属 override**:玩家/副本 `FormLight.attach(..., "guide", 1.10, 1.0, {...})` 里给 `steps 5 / dither 0.25 / bulge 2.0 / edge(-0.20, 0.80) / part_flat 0.45 / ao_strength 0.35`;`part_flat` 压平分部球面(1=按部位椭球,0=全平),`flip_x` 由玩家每帧写入(朝向翻转时 UV 镜像,不补偿会让亮面跟着朝向跑)。鸟/枪仍用全局 `form_gain` 参数。
- 材质按 `(图集, 模型, 半尺寸)` 缓存;**每帧一次 `FormLight.push(sun_dir, gain)` 推给所有材质**,成本与精灵数量无关。
- ⚠ **fragment() 不允许 `return`**:写一个 return 会让整个材质编译失败,精灵**静默**降级成无光照 —— 这是排查"形体光没生效"要看的第一个地方。
- ⚠ **零守卫**:以上全部观感项,只能人眼验收;改法线/色阶/天色时必须出图对比。


## 背景四层景深(`core/present/parallax_bg.gd`)

- 地图的四个背景层(层 3-6,`layer_flags` bit3-6)是**颜色层**(每子格 `u32 0xRRGGBBAA`),景深系数 f = **1.0 / 0.75 / 0.5 / 0.25**(层 3 最近、层 6 最远)。编辑器右栏四个「背景 xx%」行就是它们。
- `Level0._ready` 用 `MapFormat.load_bg_layers()` 取图;`ParallaxBg.setup(layers, 地图格数)` 只在**有相机的渲染路径**建(服务器 / headless 跳过),层缺失不建节点。给 `WorldViewport` 的最底层(z_index = −100+i)。
- 视差数学只有两式(纯静态函数):**节点世界坐标 = cam × (1 − f)**;环面用 **3×3 副本**(每层 9 个 sprite,偏移 = ±1 个世界尺寸,与墙体 `_ring_copies` 同一套)⇒ 相机位移 Δ 时该层屏幕位移 = −f·Δ。
- **尺寸与平铺**（2026-11-08 用户口径，已逐条实现）：**四个背景 = 四张不同的图**（各从自己那层的色层数据烘出，互不共用纹理）；**像素尺寸随景深变小**（`newfactory` 实测 600×400 / 450×300 / 300×200 / 150×100，双线性降采样）；**显示一律铺满世界**（`scale = 世界像素 / 图像素`，最近邻放大 ⇒ 远层更块、更像远景）；**平铺只为环面**——每张图随世界的 **3×3 环面副本**一起摆（9 个 sprite，偏移 ±1 个世界尺寸），**没有 `texture_repeat`、没有内部再平铺、不按视口算份数**。
- 烘图:`bake_layer_image()` 每 64px 格烘 4px(`CELL_PX = 4`)并对 4×4 子格做 **alpha 加权**均值(直接平均透明格会把黑混进来,背景边缘发暗)。颜色层只画渐变/底色,降采样观感无损;`150×100` 格 → `600×400`,四层显存可忽略。
- **独立视口（2026-11-08 管线补丁）**：背景四层渲染进运行时建的 `BgViewport`（SubViewport、`transparent_bg`、自带相机每帧跟随世界相机），**不进 WorldViewport**。因此遮挡掩码 `occ_tex`（= 世界视口 alpha）与 `_terrain_lit` 都**看不到背景** ⇒ 背景不遮挡、不投假影、不吃地形明暗，只吃全局 `ambient_color`（昼夜变暗 / 色相）。**不透明剪影因此是安全的**（此前靠 α<0.90 的半透明绕开）。PostProcess 合成口径：`under = sky*(1-bg.a) + bg.rgb*ambient_color; COLOR = under*(1-world.a) + lit_world`（三者都是预乘 alpha）。
- 不进快照 / 回滚 / 网络包：纯视觉，两端都从同一张地图文件现算 ⇒ 天然一致。零守卫（原 `bg_parallax_smoke` 已删）：改视差两式 / 烘焙权重只能人工对拍。人眼项：与天空 shader、光照投影的合成次序；**着色器编译只能真渲染验**（headless 不编译）。

## 补间形变(squash & stretch)

- `scenes/effects/squash_stretch.gd`(`SquashStretch extends Node`)是纯表现层组件,挂玩家 / 三只敌鸟 / 对手副本,只写 `animator.scale`。
- 计算模型 = `_air`(每帧由 `vel_y` 重算,无状态)+ `_impulse`(事件累加 + `MathUtil.approach` 指数回归);单标量叠加,同时事件天然叠加。幅度上限来自 `squash_amount`(玩家侧 `PlayerParams.squash_amount`、敌人侧 `EnemyParams.squash_amount`,数值在各自 `.tres`,此处不抄),`v` 钳在 `[-1,1]`。
- 落地判据 `if on_floor and vel_y > squash_land_min_vy`;阈值不是字面量 —— 玩家侧 `PlayerParams.squash_land_min_vy`、敌人侧 `EnemyParams.squash_land_min_vy`(两侧各由自己的 `.tres` 定,**不在此处抄数值**)。宿主必须在 `move_and_slide()` **之前**缓存 `_pre_move_vy`。
- 宿主契约:传进 `tick()` 的 `vel_y` 必须是「地面真正吸收掉的」那个下坠速度,否则传 0。玩家侧 = `_pre_move_vy = 0.0 if (in_water or latched) else velocity.y`;敌人侧刻意用裸 `velocity.y`(水的写入钳在 `-EnemyParams.shared.bird_max_float` / `+EnemyParams.shared.bird_max_sink` 之间,下沉侧那个值小于落地阈值,故落水不会误判为落地 —— 两者的大小关系由 `.tres` 里的数值保证,改数值时要一并复核这条)。
- `tick` 放 `_physics_process` 最首行(倒地早退之前),敌人侧同理(`_is_far_sleeping()` 早退之前);形变不进 `capture_state()` / `restore_state()`,不碰碰撞箱。
- 倒地必须 `suppressed = true`:副本根节点 `rotation = -90°`,写 `scale` 会沿转过的轴挤压。
- 副本:数据从快照的 `vel` / `pose` 本地推导;`on_floor = (not _downed) and _pose != POSE_FLY and absf(_vel.y) < LAND_VEL_EPS`;水项用客户端本地网格查询 `_in_water()`,不是协议字段;不做受击挤压;`tick` 放副本的 `_process`。
- 已知表现副产物:缩放绕精灵中心,挤压时画出的底边上抬 ~4~5px、拉伸下沉 ~3.5px。`animator.offset` 必须保持 `Vector2.ZERO`。
- `_impulse` 有两个写入口,各自钳一次 `[-1,1]`:`impulse()` 的加法,以及 `tick()` 里 `_impulse -= _land_gain * k` 之后紧跟的 `clampf`。
- 残影 `scenes/effects/after_image.gd`(`AfterImage`):复制 `AnimatedSprite2D` 当前帧贴图成一张 `Node2D + Sprite2D`,淡出后自毁。两个消费点:加速残影(`player.gd`,红/蓝交替,物理 tick 发射)、冲刺残影(`player.gd` / `player_replica.gd`,淡蓝白 alpha 0.30、0.20s、0.02s 间隔,**渲染帧发射**,服务器/无相机路径跳过;本体除了冲刺态,下冲后还有 `DOWN_DASH_GHOST_TIME = 0.06s` 的发射窗口 —— 副本只认 `POSE_CHARGE`,故对手的下冲没有残影,已知差异)。纯表现,不进 `capture_state()` / 快照。

## 载入

- **所有模式同一条载入路径**:`Level0._ready` **第一行**就 `LoadingScreen.show_loading`,进度覆盖 读图 → 墙体图集烘焙 → 铺墙 → 水体合批 → 碰撞(逐块);单机由 `main_menu._enter_level0`、联机由 `MpLobby._enter_match_scene` + `PvpMatchClient._boot_world` 提前挂载入屏,覆盖 `change_scene`/建场景那段黑屏。
- 墙体图集按地图路径缓存(`_wall_ts_cache`,static):同进程重开(重连/换模式/单机重载)复用,省 ~87ms;首开仍重建。水体合批图集按描述符每次现烘(量很小),不缓存。
- 铺贴只画可见环带(见上),碰撞仍逐块建(渐进,`BOOT_BUDGET_US = 8ms/帧`);载入期间 `get_tree().paused = true`,完成才解。
- 实测(demo/headless):`coll_chunks` 阶段 CPU ~30ms、其余时间主要在首帧与铺图;整段配置从 ~1.5s 级降到 ~1.1s 级,铺图格数降 68%(newfactory)。
- 地图数据深拷贝 `GridPathfinder.copy_grid` 改成逐行 `duplicate()`(C++);`TileDefs.init_sub_hp` 按地图路径缓存 pristine `PackedInt32Array`(抽样校验,命中 bulk duplicate)⇒ newfactory 首次加载 `load_grid` 134→86ms、`tile_defs+copy` 104→56ms;同进程重开(缓存命中)再省图集与这两段。


## 远端玩家副本的表现层(`scenes/player/player_replica.gd`)

- **渲染层带**:`level_0.tscn` 的子节点顺序是 `Camera2D → Player → WallLayer → WaterSurfaceLayer(z 5)`。所以本体被墙体 / 梯子 / 建筑(都铺在 `WallLayer`)盖住,却又被水体合批(`WaterSurfaceLayer`,z 5)压住;而远端副本是运行时 `add_child` 到世界末尾的 ⇒ 默认盖住墙体 / 梯子 / 建筑(现状 = 只有别人的角色压在地形上)。副本在 `_ready` 里用 `Level0.wall_layer` 把自己挪到那一层之前(`_reorder_before_structures`),与本体同一条层带。★ 只动绘制顺序,不碰碰撞与位置。
- **位置插值**:下行 60Hz ⇒ 直出最新快照就是「一格一格跳」(单步 = 移速 × 16.7ms,走速 ≈5px)。改成 playout 缓冲插值:渲染「最新快照 − `PLAYOUT_TICKS`」那一刻的两样本夹逼插值,`PLAYOUT_TICKS = 2`(60Hz tick 域)= 2 个发包间隔 ≈ **33ms**。样本之间用三次 Hermite(切线 = 快照里的权威速度 × 本段时长)⇒ 起跳 / 下落 / 急停转弯不再折线;这个延迟是选出来的常量(不是低通滤波器的涌现滞后)。
- **两端**:比最老还老冻在最老、不倒退;比最新还新(underrun)时不再一律冻结,用最新权威速度**最多补 2 tick(≈33ms)、总位移 ≤60px**,超出即冻结(丢一个快照就停 16.7ms = 肉眼可见卡顿,所以加了这个有界外插)。跨接缝的那一对样本先锚进同一个副本空间再插。
- **大跳变**:相邻两条权威样本的环面距离 > `SNAP_DIST = 128 px` ⇒ 清位置历史、一帧落位。依据:常态相邻包位置差 ≈ 10px(300px/s × 33ms)、丢包 200ms 也只有 ≈60px,而回溯 / 重生 / 换边是几百~几千 px ⇒ 128 落在两者之间,两侧各留约 2 倍余量。
- **外观态与位置同一条时间线**:`pose` / `facing` / `aim` / `downed` / `type_id` / `vel` 与位置一起进历史环,渲染时按同一个 `render_tick` 取样。连续量(`aim` 方向向量、`vel`)在相邻两条历史之间插值(`slerp` / `lerp`),离散量(`pose` / `facing` / `downed` / `type_id`)仍取整条。★ 这条不是可选项:外观态逐包瞬跳时,动画/枪口比身体早一拍多,对手停下后腿还在走(用户报的「滑」);只延迟不插 `aim` 时,枪口每 33ms 跳一次(用户报的「对手有点卡」)。
- **副本不参与碰撞**:2026-11-10「玩家之间不互挡」后副本只剩渲染 + 一个零碰撞几何探针(`HurtProbe`,`layer`/`mask` 恒 0,只给受击面 / 脚底提供几何)。**几何不吃插值**:探针位置跟最新快照锚点、姿态箱按最新 `pose` 切;但 `hurt_rect_rendered()` 的**位置**仍取渲染位置(插值)—— 形状与服务器裁决同源、位置与玩家眼睛同源。
- ⚠ **零守卫**:以上都是观感项,按仓主裁定不写自动守卫(见 [`tests.md`](tests.md) 的「不写清单」),只能人眼验收;改动时盯「对手横向跑动是否连续、是否被梯子 / 墙盖住」。

