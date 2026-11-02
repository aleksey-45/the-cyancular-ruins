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
| 调色板与 UiFactory、菜单语汇、HUD、小地图、大厅版式 | [`ui.md`](ui.md) |
| 大厅 / worker、匹配进图、房间与回合、回到大厅、重连、RPC 归属 | [`netplay.md`](netplay.md)；重连 → [`netplay-reconnect.md`](netplay-reconnect.md)、房间寿命与回局 → [`netplay-rooms.md`](netplay-rooms.md)、RPC 通道号单一来源 → [`netplay-rpc-channels.md`](netplay-rpc-channels.md) |
| 快照管线、输入上行、插值与输入、增量与量化、16 人局读数、tick 率、playout 时钟、抖动缓冲 | `netcode-*.md`（快照那份：[`netcode-snapshots.md`](netcode-snapshots.md)） |
| 对抗（原 3v3）、结算页、大乱斗及其已知差异 | [`modes.md`](modes.md) |
| 时间玩法（回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕）、它的不变量与常量来源 | [`time.md`](time.md) |
| 探针怎么跑 / 怎么判、真链路纪律、守卫边界；测试该不该写、写哪一档（桶划分与不写清单） | [`tests.md`](tests.md)、[`test-economy.md`](test-economy.md) |
| 浏览器地图编辑器（怎么开、怎么打包成单文件）、sync-*.js、导入 / 导出工具 | [`tools.md`](tools.md)；编辑器各层：[core](editor-core.md) / [ui](editor-ui.md) / [render](editor-render.md) / [io+worker](editor-io.md) / [server](editor-server.md) |
| 注释怎么写（含**注释额度**：>100 行的 `.gd` ≤15%）、守卫幻觉怎么标 | [`comment-style.md`](comment-style.md) |
| 房间 / 端口生命周期约定（回收梯、超龄扫、端口池） | [`room-lifecycle-conventions.md`](room-lifecycle-conventions.md) |
| **动手前必看**：既有红 / 待还的债 / 已裁定不做 | [`registered-debt.md`](registered-debt.md) |
| 追溯"当时为什么这么定"（旧计划 / 旧审计） | `git log` / `git log -p -- <path>` —— **本仓不设归档目录**，历史不入库 |
