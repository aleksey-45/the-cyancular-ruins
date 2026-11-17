# docs/ —— 文档总索引

> **返回入口：** [`AGENTS.md`](../AGENTS.md)（怎么跑 / 怎么干 / 去哪查）。
> 本目录 = **文档真相源**；这份 README 只做**按域路由**，不重复任何域内结论。
> 权威清单以目录树为准（`ls docs/*/ docs/*/*/`）—— 本文件不抄文件清单（抄了必过期）。

## 结构

| 目录 | 装什么 | 是不是真相源 |
|---|---|---|
| `systems/` | **系统契约**：本地实现现在怎么工作（gameplay / presentation / editor） | 是 |
| `netcode/` | **联机契约**：协议面（protocol）/ 房间面（rooms） | 是 |
| `workflow/` | **干活规范**：怎么跑、怎么写注释、工具、（债务台账在 `registered-debt.md`） | 是 |
| `design/` | **产品设计**：策划案（人读、可自由变、**不保证与代码同步**） | 是（但非实现契约） |
| `construction/` | **AI 施工产物**：review / spec / plan。★ **不是真相源**，见该目录 README | **否** |

★ **二级目录判据**：某族 **≥5 篇**，或它有**独立生命周期**（自有格式契约 / 自有产物 / 已大规模重构过）时，才设二级；否则平铺。
反例：`workflow/` 5 篇但读者与变更触发点相同 ⇒ 不设二级。正例：`systems/editor/` 只有 2 篇，但编辑器有自有 `.cyrm` 契约与导出产物 ⇒ 设二级。

## 按域路由

**systems/**

| 什么时候读 | 文件 |
|---|---|
| 改地图格式（cyrm）、环面几何 / 寻路、参数体系、砖块属性与破坏、水、碰撞层 | [`gameplay/world.md`](systems/gameplay/world.md) |
| 加 / 改敌人、AI 状态机、寻路、精英与掉落 | [`gameplay/enemies.md`](systems/gameplay/enemies.md) |
| 加 / 改武器与子弹、弹道与命中、背包容量、地面拾取、武器注册表 | [`gameplay/weapons.md`](systems/gameplay/weapons.md) |
| 移动 / 跳跃 / 冲刺 / 下蹲、姿态碰撞箱、输入注入、残弹与换弹 | [`gameplay/player.md`](systems/gameplay/player.md) |
| 对抗（原 3v3）、结算页、大乱斗及其已知差异 | [`gameplay/modes.md`](systems/gameplay/modes.md) |
| 时间玩法（回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕）、不变量与常量来源 | [`gameplay/time.md`](systems/gameplay/time.md) |
| Level0 渲染管线、图集、后处理、补间形变 | [`presentation/render.md`](systems/presentation/render.md) |
| 调色板与 UiFactory、菜单语汇、HUD、小地图、大厅版式 | [`presentation/ui.md`](systems/presentation/ui.md) |
| **设计系统 v1**（Token / Theme / 组件 / 布局 / 适配规则，唯一入口） | [`presentation/ui-design-system.md`](systems/presentation/ui-design-system.md) |
| 地图编辑器：`.cyrm` 编解码 / 格式契约 / 12 模块 / 守卫 | [`editor/editor-core.md`](systems/editor/editor-core.md) |
| 地图编辑器：Godot 场景、画布、导出两动作、产物自检 | [`editor/editor-godot.md`](systems/editor/editor-godot.md) |

**netcode/**

| 什么时候读 | 文件 |
|---|---|
| 快照管线、输入上行、插值与输入、增量与量化、16 人局读数 | [`protocol/`](netcode/protocol)（快照那份：[`netcode-snapshots.md`](netcode/protocol/netcode-snapshots.md)） |
| 大厅 / worker、匹配进图、房间与回合、回到大厅、RPC 归属 | [`rooms/netplay.md`](netcode/rooms/netplay.md) |
| 断线重连 | [`rooms/netplay-reconnect.md`](netcode/rooms/netplay-reconnect.md) |
| 房间寿命与回局 | [`rooms/netplay-rooms.md`](netcode/rooms/netplay-rooms.md) |
| RPC 通道号单一来源 | [`rooms/netplay-rpc-channels.md`](netcode/rooms/netplay-rpc-channels.md) |
| 房间 / 端口生命周期约定（回收梯、超龄扫、端口池） | [`rooms/room-lifecycle-conventions.md`](netcode/rooms/room-lifecycle-conventions.md) |

**workflow/ · design/**

| 什么时候读 | 文件 |
|---|---|
| 探针怎么跑 / 怎么判、真链路纪律、守卫边界 | [`workflow/tests.md`](workflow/tests.md) |
| 测试该不该写、写哪一档（桶划分与不写清单，**唯一真相源**） | [`workflow/test-economy.md`](workflow/test-economy.md) |
| 测试 / 探针 / 守卫**怎么写**（粒度、条数闸、确定性、源码守卫的例外） | [`workflow/test-authoring.md`](workflow/test-authoring.md) |
| 注释怎么写（含**注释额度**：>100 行的 `.gd` ≤15%）、守卫幻觉怎么标 | [`workflow/comment-style.md`](workflow/comment-style.md) |
| 工具与格式（`tools/`） | [`workflow/tools.md`](workflow/tools.md) |
| **动手前必看**：既有红 / 待还的债 / 已裁定不做 | [`registered-debt.md`](registered-debt.md) |
| 产品设计：单人模式主策划案 | [`design/CyR单人模式主策划案.md`](design/CyR单人模式主策划案.md) |
| AI 生成的 review / spec / plan（★ 结论不作数，需先提升到上面各域） | [`construction/`](construction) |
| 追溯"当时为什么这么定"（旧计划 / 旧审计） | `git log` / `git log -p -- <path>` —— 历史不入库 |

## 目录契约

> 与 [`tools/check_architecture.py`](../tools/check_architecture.py) 的规则 R1–R5 同源：R5 会校验**每个顶层源码目录与 `core/` 子目录都出现在这张表里**（漏一个 = 红；更深层的目录继承其父目录那一行），所以不需要每个目录放 README。
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
