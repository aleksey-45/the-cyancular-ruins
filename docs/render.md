# 渲染

单人和对战使用 Godot 的 Mobile 渲染方法和 1920×1440 逻辑视口。`MatchController` 用 `MatchSampler` 对本地模拟与服务器状态采样，再由 `MatchPresenter` 组装 `MatchFrame`。单人和联机对局共用 `MatchView`，由它更新世界画面、后期效果和 HUD。场景树独立推进受击反馈、后期效果和联机倒计时，单人暂停或联机断线期间这些效果仍可更新。[对局控制器](../scenes/match_controller.gd) · [表现数据组装](../core/present/match_presenter.gd) · [对局场景](../scenes/match_view.tscn) · [视图更新](../core/present/match_view.gd)

`WorldView` 根据角色动作与受击状态选择动画，计算武器和特效的显示位置。`WorldCanvas` 批量绘制角色、武器、掉落物、弹丸和残影的贴图，也绘制光束、弹道线、伤害数字、名牌和生命条。控制器按武器发射位置与弹道参数计算瞄准辅助线。爆炸碎屑根据引爆位置附近的地形生成。[世界视图](../core/present/world_view.gd) · [世界画布](../core/present/world_canvas.gd)

`SquashTracker` 根据玩家和敌人的动作计算挤压与拉伸，只缩放精灵的局部坐标轴。武器挂点和瞄准沿用角色变换。`AfterImageField` 管理冲刺、加速、回溯等动作的残影与淡出，并限制存续的残影数量。[动作形变](../core/present/squash_tracker.gd) · [残影](../core/present/after_image_field.gd)

激光命中在开火时结算，模拟保留当时的折线路径 15 个物理帧。每个渲染帧直接采样仍然可见的光束，按剩余时间淡出。本地光束取自当前模拟，远端光束与射手共用服务器快照的播放时刻。[战斗模拟](../core/sim/combat_simulator.gd) · [画面采样](../core/present/match_frame.gd)

## 摄像机与插值

`MatchCamera` 直接更新自身的 `Camera2D.position`。镜头跟随点按角色的水平速度向行进方向偏移。半速时偏移 50 个世界像素，达到标准跑速时封顶 100 个，停下时目标偏移归零。时间回溯时按倒放方向前瞻。

角色穿过地图边缘时，摄像机移到同一侧再继续平滑跟随。瞄准计算使用摄像机的基准位置，显示位置再叠加抖动。联机位置校正的显示偏移在 50 毫秒内衰减，复活时直接对齐新位置。本机角色发射的弹丸从本地预测帧采样，远端角色和弹丸共用服务器快照的播放时刻，位置沿跨边界的最短方向插值。[摄像机](../scenes/match_camera.gd) · [位置校正与状态采样](../core/present/match_sampler.gd)

## 地图与后期处理

`TerrainAtlas` 根据地图纹理和色彩参数生成墙体及水体图集。`TerrainView` 绘制场景层，在地图边缘覆盖半个视野加 512 世界像素，并按子格更新被破坏或恢复的墙体。水面按色彩参数分批，顶点着色器根据关卡传入的时间改变波形。[地形图集](../core/present/terrain_atlas.gd) · [地形视图](../core/present/terrain_view.gd) · [水面](../core/present/water_surface_batch.gd)

对局默认以 1.00× 显示 1920×1440 世界像素的矩形视野，窗口等比缩放。按 `Delete` 切换鱼眼畸变。后期处理读取世界视口纹理，添加受击时的红色闪光、低生命值暗角和时间技能滤镜。HUD 绘制在后期处理层上方，避免界面文字和图标受畸变与时间技能滤镜影响。主菜单按 `newfactory` 场景层的子格索引取样瓦片纹理，脚本更新视野中心与旋转角度，着色器处理鱼眼畸变、模糊和色差。[后期处理](../core/present/post_process.gd) · [主菜单背景](../core/present/menu_background.gd)

## 单人片头

`MatchView` 在每个渲染帧更新视口前采集战场的绘制项、镜头、地形和后期参数。游戏的渲染上限为每秒 60 帧，缓存最多保留 300 帧。超出容量时按倒放时间轴抽帧，始终保留首尾画面。[视图采样](../core/present/match_view.gd) · [抽帧与存档](../core/present/run_intro.gd)

正式单人倒地、返回主菜单或正常关闭游戏时，片头写入 `user://last_run_intro.dat`。存档带有上一局的地图，下一次正式单人开局时用独立视图重绘。片头叠加底片反色、扫描线、色差和横向抖动，随着倒放加速而增强，在开局前淡出。片头播完或跳过后清除存档，再开始对局。[单人流程](../scenes/solo_level.gd) · [操作](player.md#单人时间技能)
