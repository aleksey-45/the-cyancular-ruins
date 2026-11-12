# core/ — 核心通用模块

本目录包含游戏跨场景共享的核心算法、物理模拟、网络通信、配置与表现层模块。按功能职责划分为四个子目录：

```text
sim/      物理模拟与空间几何：环形世界坐标计算、v4 地图读取、碰撞检测与时间控制系统
net/      网络同步与联机：网络通信通道、输入采集与调度、客户端预测与回滚、P2P 隧道与会话管理
config/   系统配置与参数：游戏全局参数、角色与敌人属性、用户本地设置及版本信息
present/  视听表现与特效：像素字体适配、音效播放、贴图边界计算与激光渲染
```

## 子目录职责说明

- `sim/`（物理模拟与空间几何）
  - 维护 16px 子格地形破坏、射线检测、环形世界寻路与碰撞判定。
  - `ActorBody` 持有姿态、RID 与接缝镜像；客户端代理按权威样本同步。
  - 包含 v4 地图读取（`map_format`、`map_format_v4`）、时间控制（`time_field`、`grain_account`、`world_rewind`）；地形历史由 `Terrain` 持有。
- `net/`（网络同步与联机）
  - 负责网络数据传输（`net_bus`、`net_codec`）、输入缓冲与调度（`input_buffer`）、客户端预测回滚（`prediction_rollback`）与远端快照播放（`snapshot_buffer`）。
  - 本地键鼠采集生成输入记录（`local_input_source`），服务端从输入缓冲消费同样的记录。
  - 提供基于 EasyTier 的应用层 P2P 网络隧道（`tunnel`）与 Windows 进程管理（`net_session`）。
- `config/`（配置与参数）
  - 集中管理游戏全局常量与运行参数（`game_parameters`）、角色与敌人配置（`player_params`、`enemy_params`）、本地设置（`settings`）以及构建版本信息（`build_info`）。
- `present/`（视觉与音频表现）
  - 负责渲染与视听反馈效果，与游戏逻辑解耦。
  - 包含像素字体渲染（`pixel_font`）、程序化音效合成（`sfx`）以及激光光束渲染（`laser_visual`）。

## 全局 Autoload 单例

在 `project.godot` 中配置的 Autoload 单例：

- `GameParameters` (`core/config/game_parameters.gd`)：全局共享常量与世界边界尺寸。
- `PerfMonitor` (`core/config/perf_monitor.gd`)：固定容量性能聚合，每秒发布标量；默认不写日志。
- `NetBus` (`core/net/net_bus.gd`)：基于 GNS 的网络通信核心接口。
- `NetSession` (`core/net/net_session.gd`)：联机会话与子进程生命周期管理；Windows 使用 Job，macOS 使用生命期管道与进程组。
- `Settings` (`core/config/settings.gd`)：用户本地配置管理，持久化存储于 `user://settings.cfg`。

## 数据配置文件关联

材质与敌人配置在 `data/`，武器使用原生定义：
- 瓦片属性定义：`data/tile_defs.json`（由 `tile_defs.gd` 解析）
- 武器配置数据：`core/sim/weapon_registry.gd`（数值与规则绑定）
- 敌人属性配置：`data/enemies.json`（由 `EnemySpawner` 解析）
