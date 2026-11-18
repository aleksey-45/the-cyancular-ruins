# 渲染

单人和对战使用 Godot 的 Mobile 渲染方法和 1920×1440 逻辑视口。`MatchController` 从本地模拟和网络快照取得位置、地形变化和 HUD 数据，写入 `MatchFrame`。两个对局场景都实例化同一棵视图子树，其中声明了世界视口、摄像机、地形、画布、后期处理、HUD 和暂停菜单。`MatchView` 将帧数据交给这些节点。场景树独立推进受击反馈、后期效果和联机倒计时，单人暂停或联机断线期间这些效果仍可更新。[对局控制器](../scenes/match_controller.gd) · [帧数据](../core/present/match_frame.gd) · [对局场景](../scenes/match_view.tscn) · [视图更新](../core/present/match_view.gd)

`WorldView` 根据角色动作与受击状态选择动画，计算武器和特效的显示位置。`WorldCanvas` 批量绘制角色、武器、掉落物、弹丸和残影的贴图，也绘制光束、弹道线、伤害数字、名牌和生命条。控制器按武器发射位置与弹道参数计算瞄准辅助线。爆炸碎屑根据引爆位置附近的地形生成。[世界视图](../core/present/world_view.gd) · [世界画布](../core/present/world_canvas.gd)

激光命中在开火时结算，模拟保留当时的折线路径 15 个物理帧。每个渲染帧直接采样仍然可见的光束，按剩余时间淡出。本地光束取自当前模拟，远端光束与射手共用服务器快照的播放时刻。[战斗模拟](../core/sim/combat_simulator.gd) · [画面采样](../core/present/match_frame.gd)

## 摄像机与插值

`MatchCamera` 直接更新自身的 `Camera2D.position`。镜头跟随点按角色的水平速度向行进方向偏移。半速时偏移 50 个世界像素，达到标准跑速时封顶 100 个，停下时目标偏移归零。时间回溯时按倒放方向前瞻。

角色穿过地图边缘时，摄像机移到同一侧再继续平滑跟随。瞄准计算使用摄像机的基准位置，显示位置再叠加抖动。联机的常规位置校正以及进入或退出时间回溯时，本地角色可在 50 毫秒内过渡到校正位置。复活时直接对齐新位置。远端角色与弹丸沿跨边界的最短方向插值，预测弹丸和服务器事件按弹丸 ID 更新同一条显示记录。[摄像机](../scenes/match_camera.gd) · [本地位置校正](../scenes/local_motion.gd) · [弹丸插值](../core/net/projectile_track.gd)

## 地图与后期处理

`TerrainAtlas` 根据地图纹理和色彩参数生成墙体及水体图集。`TerrainView` 绘制场景层，在地图边缘覆盖半个视野加 512 世界像素，并按子格更新被破坏或恢复的墙体。水面按色彩参数分批，顶点着色器根据关卡传入的时间改变波形。[地形图集](../core/present/terrain_atlas.gd) · [地形视图](../core/present/terrain_view.gd) · [水面](../core/present/water_surface_batch.gd)

后期处理读取世界视口纹理，添加镜头畸变、受击时的红色闪光、低生命值暗角和时间技能滤镜。HUD 绘制在后期处理图层之上。主菜单使用 `newfactory` 的场景层生成背景纹理，由脚本更新视野中心与旋转角度，着色器处理鱼眼畸变、模糊和色差。[后期处理](../core/present/post_process.gd) · [主菜单背景](../core/present/menu_background.gd)
