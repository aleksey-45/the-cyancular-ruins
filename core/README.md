# core/ — 核心通用模块

本目录包含游戏跨场景共享的核心算法、物理模拟、网络通信、配置与表现层模块。按功能职责划分为四个子目录：

```text
sim/      物理模拟与空间几何：环形世界坐标计算、地图格式编解码、碰撞检测与时间控制系统
net/      网络同步与联机：网络通信通道、输入抽象、客户端预测与回滚、P2P 隧道与会话管理
config/   系统配置与参数：游戏全局参数、角色与敌人属性、用户本地设置及版本信息
present/  视听表现与特效：像素字体适配、音效播放、贴图边界计算与激光渲染
```

## 子目录职责说明

- `sim/`（物理模拟与空间几何）
  - 维护 16px 子格地形破坏、射线检测、环形世界寻路与碰撞判定。
  - `actor_collider` 为服务端与客户端提供站立、蹲伏矩形阻挡，按模拟顺序映射到最近环面位置。
  - 包含地图格式编解码（`map_format`、`map_format_v4`）、时间控制系统（`time_field`、`grain_account`、`world_rewind`、`tile_ledger`）等玩法核心算法。
- `net/`（网络同步与联机）
  - 负责网络数据传输（`net_bus`、`net_codec`）、输入缓冲与调度（`input_buffer`）、客户端预测回滚（`prediction_rollback`）与远端快照播放（`snapshot_buffer`）。
  - 提供统一的玩家输入源抽象（`player_input`），支持本地键鼠输入（`local_input_source`）、网络数据包输入（`packet_input_source`）及 AI 机器人（`ai_input_source`）。
  - 提供基于 EasyTier 的应用层 P2P 网络隧道（`tunnel`）与 Windows 进程管理（`net_session`）。
- `config/`（配置与参数）
  - 集中管理游戏全局常量与运行参数（`game_parameters`）、角色与敌人配置（`player_params`、`enemy_params`）、本地设置（`settings`）以及构建版本信息（`build_info`）。
- `present/`（视觉与音频表现）
  - 负责渲染与视听反馈效果，与游戏逻辑解耦。
  - 包含像素字体渲染（`pixel_font`）、程序化音效合成（`sfx`）、贴图不透明包围盒测量（`sprite_bounds`）以及激光光束渲染（`laser_visual`）。

## 全局 Autoload 单例

在 `project.godot` 中配置的 Autoload 单例：

- `GameLog` (`core/config/game_log.gd`)：接管日志输出，分流写入本地日志文件。
- `GameParameters` (`core/config/game_parameters.gd`)：全局共享常量与世界边界尺寸。
- `NetBus` (`core/net/net_bus.gd`)：基于 GNS 的网络通信核心接口。
- `NetSession` (`core/net/net_session.gd`)：联机会话与子进程生命周期管理；Windows 使用 Job，macOS 使用生命期管道与进程组。
- `Settings` (`core/config/settings.gd`)：用户本地配置管理，持久化存储于 `user://settings.cfg`。

## 数据配置文件关联

运行时基础数据集中在 `data/` 目录维护：
- 瓦片属性定义：`data/tile_defs.json`（由 `tile_defs.gd` 解析）
- 武器配置数据：`data/weapons.json`（由 `WeaponRegistry` 解析）
- 敌人属性配置：`data/enemies.json`（由 `EnemySpawner` 解析）
