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

`WorldCanvas` 更新环境光、方向光和玩家眼灯。Mobile 渲染器中，每个 `CanvasItem` 最多接收 15 个点光源。角色数超过 15 时，每个玩家身体单独使用一个画布节点绘制，缩小引擎为单个节点查找光源的范围。[世界画布](../core/present/world_canvas.gd) · [昼夜与玩家光照](world.md) · [Godot 4.7.1 光源计数](https://github.com/godotengine/godot/blob/4.7.1-stable/servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp#L2165-L2182)

对局默认显示 1920×1440 个世界像素的矩形视野，画面随窗口等比缩放。按 `Delete` 切换鱼眼畸变。后期处理采样世界视口纹理，添加受击红色闪光、低生命值暗角和时间技能滤镜。HUD 绘制在这层效果之上，文字和图标保持清晰。[后期处理](../core/present/post_process.gd)

主菜单背景使用 `newfactory` 的场景层。脚本更新视野中心与旋转角度，着色器根据子格索引采样瓦片纹理，并应用鱼眼畸变、模糊和色差。[主菜单背景](../core/present/menu_background.gd) · [菜单着色器](../core/present/menu_fisheye.gdshader)

## 单人片头

正式单人对局中，`MatchView` 在渲染前记录战场的绘制项、摄像机位置、地形和后期参数。渲染帧率上限为 60 FPS，缓存最多保留 300 帧。超出容量时，根据倒放时间轴上的采样间隔删减中间帧，保留首尾画面。[画面采集](../core/present/match_view.gd) · [抽帧与存档](../core/present/run_intro.gd)

玩家倒地、返回主菜单或正常关闭游戏时，画面记录与地图一并保存到 `user://last_run_intro.dat`。下次正式单人开局时，独立的对局视图将上一局画面倒放为片头。底片反色、扫描线、色差和横向抖动随倒放加速而增强，在开局前淡出。片头播完或跳过后清除存档，再开始对局。[单人流程](../scenes/solo_level.gd) · [操作](player.md#单人时间技能)
