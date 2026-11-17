# docs/eng —— 域正文索引

> **返回入口：** [`AGENTS.md`](../../AGENTS.md)（怎么跑 / 怎么干 / 去哪查）。
> 本目录 = **域正文的真相源**；这份 README 只做**按域路由**，不重复任何域内结论。
> 域的权威清单以 `ls docs/eng/*.md` 为准 —— 本文件不抄文件清单（抄了必过期）。

## 按域路由

| 什么时候读 | 文件 |
|---|---|
| 改地图格式（cyrm）、环面几何 / 寻路、参数体系、砖块属性与破坏、水、碰撞层 | [`world.md`](world.md) |
| 加 / 改敌人、AI 状态机、寻路、精英与掉落 | [`enemies.md`](enemies.md) |
| 加 / 改武器与子弹、弹道与命中、背包容量、地面拾取、武器注册表 | [`weapons.md`](weapons.md) |
| 移动 / 跳跃 / 冲刺 / 下蹲、姿态碰撞箱、输入注入、残弹与换弹 | [`player.md`](player.md) |
| Level0 渲染管线、图集、后处理、补间形变 | [`render.md`](render.md) |
| 调色板与 UiFactory、菜单语汇、HUD、小地图、大厅版式；**设计系统 v1（Token/Theme/组件/布局/适配规则）** | [`ui.md`](ui.md)（页面现状）、[`ui-design-system.md`](ui-design-system.md)（唯一入口） |
| 大厅 / worker、匹配进图、房间与回合、回到大厅、重连、RPC 归属 | [`netplay.md`](netplay.md)；重连 → [`netplay-reconnect.md`](netplay-reconnect.md)、房间寿命与回局 → [`netplay-rooms.md`](netplay-rooms.md)、RPC 通道号单一来源 → [`netplay-rpc-channels.md`](netplay-rpc-channels.md) |
| 快照管线、输入上行、插值与输入、增量与量化、16 人局读数 | `netcode-*.md`（快照那份：[`netcode-snapshots.md`](netcode-snapshots.md)） |
| 对抗（原 3v3）、结算页、大乱斗及其已知差异 | [`modes.md`](modes.md) |
| 时间玩法（回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕）、它的不变量与常量来源 | [`time.md`](time.md) |
| 探针怎么跑 / 怎么判、真链路纪律、守卫边界；测试该不该写、写哪一档（桶划分与不写清单） | [`tests.md`](tests.md)、[`test-economy.md`](test-economy.md) |
| 地图编辑器（`.cyrm` 编解码 / 编辑器场景 / 导出两动作 / 两份产物） | [editor-core.md](editor-core.md)（格式契约 + `core/editor/` 12 模块 + 守卫）/ [editor-godot.md](editor-godot.md)（场景、画布、导出、产物自检）；发布流程见 [RELEASE.md](../../RELEASE.md)、工具清单见 [tools.md](tools.md) |
| 注释怎么写（含**注释额度**：>100 行的 `.gd` ≤15%）、守卫幻觉怎么标 | [`comment-style.md`](comment-style.md) |
| 房间 / 端口生命周期约定（回收梯、超龄扫、端口池） | [`room-lifecycle-conventions.md`](room-lifecycle-conventions.md) |
| **动手前必看**：既有红 / 待还的债 / 已裁定不做 | [`registered-debt.md`](registered-debt.md) |
| 追溯"当时为什么这么定"（旧计划 / 旧审计） | `git log` / `git log -p -- <path>` —— **本仓不设归档目录**，历史不入库 |

## 目录契约

> 与 [`tools/check_architecture.py`](../../tools/check_architecture.py) 的规则 R1–R5 同源：R5 会校验**每个顶层源码目录与 `core/` 子目录都出现在这张表里**（漏一个 = 红；更深层的目录继承其父目录那一行），所以不需要每个目录放 README。
> 表只写"一句话职责 + 依赖方向"，不写文件清单（清单必过期，以 `ls` 为准）。**改目录或改依赖方向 = 同时改这张表与工具规则。**

| 目录 | 一句话职责 | 允许依赖 | 禁止 |
|---|---|---|---|
| `core/sim/` | 纯逻辑：几何 / 命中 / 规则 / 时间账本 | 自身、`core/config` | 场景树、`scenes/`、`server/`、`get_tree()` |
| `core/net/` | 协议、编解码、快照、预测回滚 | `core/sim` | `scenes/`、`server/` |
| `core/present/` | 渲染与表现辅助（后处理、相机、对象池、录像带） | 引擎 API | `server/` |
| `core/config/` | 数值与全局配置的单一来源 | 自身 | 场景、网络 |
| `core/editor/` | `.cyrm` 编解码与编辑器数据 | `core/sim` | `scenes/`、`server/` |
| `core/mp/` | 模式定义 / 选项 / 队伍规则（各模式共用的常量与判据） | `core/sim` | 场景、网络 |
| `core/ui/` | 跨场景共用的 UI 件（如加载屏） | `core/` | `server/` |
| `scenes/` | 实体与场景（Godot 节点树、编辑期可见） | `core/`、`ui/` | `server/` |
| `scenes/player/` | 玩家实体 + 其内部模块（motor / present / pickup / state） | `core/`、`scenes/weapons/` | 其它实体的内部模块 |
| `server/` | 权威端：大厅、worker、裁决、回合 | `core/`、`scenes/` | — |
| `ui/` | HUD / 菜单 / 设计系统 | `core/` | `server/` |
| `tests/`、`tools/` | 验证与仓库守卫 | 全部（允许） | 不进导出包 |
| `assets/`、`data/`、`maps/` | 美术 / 注册表 / 地图数据 | — | 不含 `.gd` |
