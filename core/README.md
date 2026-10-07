# core/ — 核心通用逻辑与系统模块

本目录包含游戏跨场景共享的核心算法、模拟逻辑、网络系统、配置与表现层模块。目录按功能职责划分为四个子系统：

```
sim/      世界模拟与几何：环面物理计算、地图格式编解码、碰撞判定与时间控制
net/      网络同步与联机：网络通信总线、输入源抽象、会话编排、预测回滚与网络隧道
config/   系统配置与参数：游戏玩法常量、玩家/敌人属性参数、持久化设置与运行元数据
present/  视听表现与特效：像素字体排版、音效合成与激光/粒子视觉呈现
```

## 子目录职责说明

- `sim/`（模拟与世界几何）
  - 维护地形破坏、射线检测、环面几何寻路与碰撞判定。
  - 包含地图格式编解码（`map_format`、`map_format_v4`）、时间控制（`time_field`、`grain_account`、`world_rewind`）等核心玩法算法。
- `net/`（网络同步与联机）
  - 维护客户端与服务端网络协议、RPC 通信总线（`net_bus`、`net_bus_ext`）与 EasyTier 网络隧道（`tunnel`）。
  - 提供统一的输入源抽象接口（`player_input`），支持本地输入（`local_input_source`）、网络数据包（`packet_input_source`）及 AI 机器人（`ai_input_source`）无缝替换。
  - 包含客户端预测与回滚机制（`prediction_rollback`）及断线重连宽限期保护。
- `config/`（配置与参数）
  - 集中维护全局常量、平衡性数值及配置文件持久化。
  - 包含游戏运行参数（`game_parameters`）、玩家/敌人属性（`player_params`、`enemy_params`）、设置持久化（`settings`）及版本构建元数据（`app_info`、`build_info`）。
- `present/`（视觉与音频表现）
  - 负责纯表现层的视听效果实现，与游戏玩法逻辑解耦。
  - 包含像素字体抗锯齿优化（`pixel_font`）、程序化白噪声与音效合成（`sfx`）、贴图非透明边界测量（`sprite_bounds`）以及激光光束渲染（`laser_visual`）。

## 全局 Autoload 单例

项目在 `project.godot` 中注册的 Autoload 单例：

- `GameParameters` (`core/config/game_parameters.gd`)：全局共享常量与世界尺寸状态，关卡加载时初始化地图宽高。
- `NetBus` (`core/net/net_bus.gd`)：专用服务端与客户端核心 RPC 通信总线。
- `NetBusExt` (`core/net/net_bus_ext.gd`)：联机扩展协议总线，提供旁路消息与向后兼容支持。
- `Settings` (`core/config/settings.gd`)：客户端本地设置管理，持久化存储于 `user://settings.cfg`。

> 注意：调整 Autoload 脚本路径时，必须同步更新 `project.godot` 中的配置。

## 数据驱动文件关联

核心运行时配置数据独立维护于 `data/` 目录：
- 瓦片属性定义：`data/tile_defs.json`（由 `tile_defs.gd` 加载解析）
- 武器配置数据：`data/weapons.json`（由 `WeaponRegistry` 加载解析）
- 敌人属性配置：`data/enemies.json`（由 `EnemySpawner` 加载解析）
