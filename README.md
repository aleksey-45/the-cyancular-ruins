# The Cyancular Ruins

<p align="center">
  <img src="assets/textures/icon.svg" alt="The Cyancular Ruins" width="128" height="128" />
</p>

[![Godot 4.7.1](https://img.shields.io/badge/Godot-4.7.1-478CBF?logo=godotengine&logoColor=white)](https://godotengine.org/)
[![支持平台：Windows x64、macOS](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20macOS-0078D4)](RELEASE.md)
[![构建与测试状态](https://github.com/aleksey-45/the-cyancular-ruins/actions/workflows/build.yml/badge.svg?branch=feat%2Fupstream-main-migration)](https://github.com/aleksey-45/the-cyancular-ruins/actions/workflows/build.yml?query=branch%3Afeat%2Fupstream-main-migration)
[![MIT 许可证](https://img.shields.io/badge/license-MIT-green)](#许可证)

基于 Godot 开发的像素风 2D 横版平台动作射击游戏，支持玩家建房联机和专用服务器。

## 项目结构

客户端从主菜单进入单人关卡、联机大厅或地图编辑器。联机建房时，客户端另起一个服务器进程管理房间与对局。单人关卡是一个本地席位的权威对局。它与服务器共用开局和模拟步进，联机客户端以同一世界逻辑执行预测。[主菜单场景](scenes/main_menu.tscn) · [专用服务器场景](server/server_main.tscn)

| 目录 | 内容 |
|---|---|
| `core/sim/` | 地图读取、角色移动、碰撞查询、战斗、装备、地形破坏、回合规则与时间技能 |
| `core/net/` | 消息编解码、输入缓冲、状态快照、客户端预测与回滚、联机会话 |
| `core/config/` | 玩法参数、房间选项、显示与输入设置、性能统计 |
| `core/present/` | 对局画面与 HUD、地形图集、着色器、字体与音效 |
| `scenes/` 与 `ui/` | 场景控制器、角色和敌人、菜单与 HUD |
| `server/` | 专用服务器入口、房间管理与对局同步 |
| `data/` 与 `maps/` | 地形材质、武器资源、EasyTier 组件清单和内置地图 |
| `native/` | UDP 消息传输与子进程管理的 GDExtension |
| `ui/map_editor/` | 主菜单内的 CYRM 地图编辑器与关卡试玩 |
| `tools/` 与 `tests/` | 构建、打包和测试入口 |

## 开发文档

| 主题 | 文档 |
|---|---|
| 从源码运行、自动加载节点、关卡编辑器与发布 | [运行与工具](docs/tools.md) · [构建与发布](RELEASE.md) |
| 地图格式、水体与可破坏地形 | [世界与地图](docs/world.md) · [地形](docs/terrain.md) |
| 移动、敌人、装备与伤害 | [模拟与战斗](docs/simulation.md) · [玩家](docs/player.md) · [敌人](docs/enemies.md) · [武器与装备](docs/weapons.md) |
| 多人玩法与网络同步 | [对战模式](docs/modes.md) · [联机系统](docs/netplay.md) |
| 画面与交互 | [渲染](docs/render.md) · [界面与交互](docs/ui.md) |
| 自动化测试与运行性能 | [测试](docs/tests.md) · [性能监测](docs/performance.md) |

## 致谢

- [Godot Engine](https://godotengine.org/)（MIT 许可证）
- [GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets)（BSD-3-Clause 许可证）
- [EasyTier](https://github.com/EasyTier/EasyTier)（LGPL-3.0 许可证）
- GNU Unifont 点阵字体（SIL OFL 1.1 许可证）
- Less Perfect DOS VGA 像素字体（Zeh Fernando / Laemeur）

世界观受博尔赫斯《环形废墟》与艾略特《四个四重奏》启发。

## 许可证

项目采用 MIT 许可证。第三方组件与资源各自适用的许可证见 [第三方声明](THIRD_PARTY_NOTICES.txt)。
