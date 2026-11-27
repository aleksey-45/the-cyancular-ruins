# 渲染

单人和联机对局共用 `MatchView`，使用 Godot 的 Mobile 渲染器和 1920×1440 逻辑视口。`MatchController` 通过 `MatchSampler` 从本地模拟和服务器快照采样，由 `MatchPresenter` 整理成 `MatchFrame`，供 `MatchView` 更新世界画面、后期处理和 HUD。场景树独立更新受击反馈、后期效果和联机倒计时，单人暂停或联机断线期间这些效果仍可更新。[对局控制器](../scenes/match_controller.gd) · [对局帧数据](../core/present/match_presenter.gd) · [对局场景](../scenes/match_view.tscn) · [视图更新](../core/present/match_view.gd)

`WorldView` 根据角色动作与受击状态选择动画，计算武器和特效的显示位置。`WorldCanvas` 绘制角色、武器、掉落物、弹丸和残影，相邻且使用同一材质的精灵可共用同一绘制批次，以保留遮挡顺序。它也绘制光束、弹道线、伤害数字、名牌和生命条。控制器按武器发射位置与弹道参数计算瞄准辅助线。爆炸碎屑根据引爆位置附近的地形生成。[世界视图](../core/present/world_view.gd) · [世界画布](../core/present/world_canvas.gd)

`SquashTracker` 根据玩家和敌人的动作计算挤压与拉伸，只缩放精灵的局部坐标轴。武器挂点和瞄准沿用角色变换。`AfterImageField` 管理冲刺、加速、回溯等动作的残影与淡出，并限制存续的残影数量。[动作形变](../core/present/squash_tracker.gd) · [残影](../core/present/after_image_field.gd)

激光在开火时结算命中，光束路径保留 15 个模拟帧。每个渲染帧按光束剩余时间计算透明度。本机角色的光束取自本地模拟，远端光束与射手按同一快照时间轴显示。[战斗模拟](../core/sim/combat_simulator.gd) · [画面采样](../core/present/match_sampler.gd)

## 摄像机与插值

`MatchCamera` 按角色的水平速度，将摄像机的跟随目标向行进方向偏移。半速时偏移 50 个世界像素，达到标准跑速时偏移达到上限 100 个世界像素，停下时目标偏移归零。回溯时，摄像机向角色倒退的方向偏移。

角色穿过地图边界时，摄像机同步移到另一侧并继续平滑跟随。瞄准使用摄像机抖动前的位置。服务器校正本机角色位置后，画面上的校正偏移在 50 毫秒内衰减，复活时则直接对齐新位置。本机角色发射的弹丸从本地预测帧采样，远端角色和弹丸按同一快照时间轴显示，并沿环绕地图上的最短路径插值。[摄像机](../scenes/match_camera.gd) · [位置校正与状态采样](../core/present/match_sampler.gd)

## 地形、光照与后期处理

`TerrainAtlas` 根据纹理和色彩参数生成墙体与水体图集。`TerrainView` 绘制地图的场景层，在环绕边界绘制平移副本，覆盖半个摄像机视野再加 512 个世界像素，并按子格更新被破坏或恢复的墙体。水面按色彩参数分组，顶点着色器随关卡时间改变水波形状。[地形图集](../core/present/terrain_atlas.gd) · [地形视图](../core/present/terrain_view.gd) · [水面](../core/present/water_surface_batch.gd)

`WorldCanvas` 更新环境光、方向光、玩家眼灯和路灯。Mobile 渲染器中，每个 `CanvasItem` 最多接收 15 个点光源。当玩家数与视野内点亮的路灯副本数合计超过 15，多名玩家的身体分开绘制，引擎按每个身体的位置筛选光源。[世界画布](../core/present/world_canvas.gd) · [昼夜与玩家光照](world.md) · [Godot 4.7.1 光源计数](https://github.com/godotengine/godot/blob/4.7.1-stable/servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp#L2165-L2182)

对局默认显示 1920×1440 个世界像素的矩形视野，画面随窗口等比缩放。按 `Delete` 切换鱼眼畸变。后期处理采样世界视口纹理，添加受击红色闪光、低生命值暗角和时间技能滤镜。HUD 绘制在这层效果之上，文字和图标保持清晰。[后期处理](../core/present/post_process.gd)

主菜单背景使用 `newfactory` 的场景层。脚本更新视野中心与旋转角度，着色器根据子格索引采样瓦片纹理，并应用鱼眼畸变、模糊和色差。[主菜单背景](../core/present/menu_background.gd) · [菜单着色器](../core/present/menu_fisheye.gdshader)

### 受光材质

玩家、手持与掉落武器、三种鸟、地形和水面使用 Godot 的 `CanvasTexture`。底色、法线和镜面图共用帧矩形。法线图用切线空间的 X+、Y+、Z+ 约定。镜面图的 RGB 控制反光颜色与强度，Alpha 控制光泽度，值越大亮斑越窄。各纹理的 `specular_shininess` 取 0.6。玩家沿用原有法线和分档明暗，在同一着色器内读取 Godot 采样的镜面参数。[玩家材质](../assets/textures/player_canvas_texture.tres) · [玩家着色器](../core/present/player_body_lighting.gdshader) · [Godot 镜面光计算](https://github.com/godotengine/godot/blob/4.7.1-stable/servers/rendering/renderer_rd/shaders/canvas.glsl#L432-L448)

枪管和铁链的高光较强且集中，握把、梯子和树干的反光较弱。鸟的喙和爪与羽毛使用不同的光泽。残影、发光叠层和乌鸫的受击剪影使用原画的底色和透明度。地形按同一套子格坐标拼接三张图，地图调色只作用于底色。水面在采样的法线上叠加与波形同步的倾斜，水纹、透明度与回溯效果由水面着色器处理。[武器材质](../assets/textures/weapons_surface.tres) · [地形图集](../core/present/terrain_atlas.gd) · [水面着色器](../core/present/water_current.gdshader)

修改原画后，可以在仓库根目录运行 `python tools/bake_surface_maps.py` 重建配套纹理。工具使用 NumPy 与 Pillow，根据原画轮廓、像素色阶、枪托握把的遮罩及地形材质生成法线和镜面图。修改玩家的姿势或眼睛位置时，另运行 `python tools/bake_eye_light.py` 更新眼灯挂点和烘焙底色。[材质贴图生成](../tools/bake_surface_maps.py) · [玩家眼灯烘焙](../tools/bake_eye_light.py)

### 路灯照明

灯具宽 16、高 80 世界像素。灯杆和玻璃使用带法线和高光的 `CanvasTexture`，灯芯单独绘制。暖白光为 `#FFD69C`，冷青光为 `#86D9E8`。原生 `PointLight2D` 高度为 32，满亮能量为 0.9。灯芯亮度和点光能量随天色连续变化，夜间系数为 `1 - smoothstep(0.22, 0.64, 环境色亮度)`。[灯具场景](../core/present/street_lamp.tscn) · [昼夜色带采样](../core/present/daylight.gd)

眼灯与路灯共用受光层，照亮地形、水面、角色、装备和灯杆。天空、视差背景、名牌和 HUD 保持各自的颜色。路灯的光斑半径为 160 世界像素，小地图取最短边长的一半作为上限。地图边缘按灯杆与光斑的联合范围绘制副本，屏外灯也能照进视野。灯光按距离衰减，可以照到隔墙的表面。[路灯与环面副本](../core/present/street_lamps.gd) · [地图点位和支座](world.md#路灯)

## 单人片头

正式单人对局中，`MatchView` 在渲染前记录战场的绘制项、摄像机位置、地形和后期参数。渲染帧率上限为 60 FPS，缓存最多保留 300 帧。超出容量时，根据倒放时间轴上的采样间隔删减中间帧，保留首尾画面。[画面采集](../core/present/match_view.gd) · [抽帧与存档](../core/present/run_intro.gd)

玩家倒地、返回主菜单或正常关闭游戏时，画面记录与地图一并保存到 `user://last_run_intro.dat`。下次正式单人开局时，独立的对局视图将上一局画面倒放为片头。底片反色、扫描线、色差和横向抖动随倒放加速而增强，在开局前淡出。片头播完或跳过后清除存档，再开始对局。[单人流程](../scenes/solo_level.gd) · [操作](player.md#单人时间技能)
