# AGENTS.md

> **开发者与 AI 编程助手开发指南。**
> 子系统技术细节以 [`CLAUDE.md`](CLAUDE.md) 与 [`docs/eng/`](docs/eng/) 目录为准。本文档提供快速上手、改动分级与必须遵守的工程约束。
> **代码权威准则**：若文档与源码不一致，一律以**最新源码实现**为准。

> **术语约定**：中文文档、代码注释和提交说明统一使用“校正”和“卡顿”。涉及帧间隔、tick 或处理阶段耗时的卡顿统计，应保留具体阈值与统计口径；英文日志字段、事件名和文件路径保持接口原名。

---

## 零、工程概览

「The Cyancular Ruins」（天青色废墟）是一款基于 **Godot 4.7.1（标准版，非 Mono）** 开发的 2D 横版平台跳跃射击演示项目。

- **显示规格**：视口分辨率 1920×1440，渲染后端使用 `rendering/mobile`。
- **空间几何**：环形世界（环面几何），实体、子弹与摄像机平滑跨越地图接缝。
- **单人模式**：核心关卡 `Level0`，加载 `.cyrm` 地图，支持时间回溯与时间加速。
- **多人对战**：1v1 回合死斗、2–10 人团队对抗、多人大乱斗；专用服务端权威、客户端预测回滚、EasyTier 应用层 P2P。
- **版本与发布命名**：版本号唯一来源为 `project.godot` 的 `application/config/version`；发布包为 `The-Cyancular-Ruins.zip`，内部目录使用 UTC+8 时间戳。

---

## 一、快速上手与常用命令

若未将 Godot 加入系统环境变量，使用绝对路径调用。控制台与导出环境分别通过 `GODOT`、`GODOT_EDITOR` 配置。

### 1. 原生依赖

首次运行前安装 `scons==4.9.1 cmake==3.31.6 ninja==1.11.1.4`，依次执行 `python tools/build_process_group.py` 与 `python tools/build_gns.py`，再用 Godot `--headless --editor --path . --import` 导入。模拟逻辑由 `core/sim/`、`core/net/`、`core/config/` 下的 GDScript 实现；只有 `native/gns/` 与 `native/process_group/` 需要编译。

### 2. 本地服务与检查

```bash
# 专用服务端（单进程单端口，默认 7777）
"$GODOT" --headless --path . res://server/server_main.tscn

# 无头客户端 90 帧，排查场景加载与脚本语法
"$GODOT" --headless --path . --quit-after 90

# 命名、类名映射、文档链接检查
python tools/check_naming.py
```

### 3. 验证范围

关键行为检查见 [tests.md](docs/eng/tests.md)，一次启动执行所需分组，不自动重试。按改动范围验证必要玩法；不得用全状态录制推断正常性能。网络验证使用动态端口，退出后回收子进程。性能方法见[低开销性能观测](docs/eng/low_overhead_performance.md)。

---

## 二、代码修改规范

### 1. 改动风险分级

| 风险级别 | 适用范围 | 必需验证 |
|---|---|---|
| **一级（表现层）** | 文案、颜色、布局、纯视觉参数 | 检查相关界面 |
| **二级（单子系统）** | 敌人行为、武器数值、UI 数据流、单人玩法 | 脚本加载 + 关联玩法 |
| **三级（核心架构）** | 网络协议、输入包、预测回滚、地图二进制、碰撞/伤害 | 编译、导入、关联行为分组；必要时真实对局 |

### 2. 核心约束

- **配置驱动**：武器、敌人、瓦片分别以 `data/weapons.json`、`data/enemies.json`、`data/tile_defs.json` 为唯一来源，禁止在业务逻辑硬编码类型/常量映射。
- **统一 UI 工厂**：界面元素、按钮风格、面板底色通过 [`UiFactory`](ui/factory/ui_factory.gd) 构造；字号保持 16 的整数倍。
- **文件规范**：新建 `.gd` 同步添加 `.gd.uid`；目录与 `.tscn` 使用 snake_case。
- **性能边界**：热路径继续使用固定槽数组、稳定 RID、复用查询参数；不要改成每 tick 构造节点或 Dictionary 事件。

---

## 三、系统索引

行为细节以源码和 `docs/eng/` 为准，此处只保留入口：

| 主题 | 文档 |
|---|---|
| 场景内模拟、战斗、地形 | [simulation](docs/eng/simulation.md)、[combat_simulation](docs/eng/combat_simulation.md)、[terrain](docs/eng/terrain.md) |
| 角色、武器、敌人 | [player](docs/eng/player.md)、[weapons](docs/eng/weapons.md)、[enemies](docs/eng/enemies.md) |
| 联机、模式、预测 | [netplay](docs/eng/netplay.md)、[modes](docs/eng/modes.md)、[local_prediction_design](docs/eng/local_prediction_design.md)、[prediction_reuse](docs/eng/prediction_reuse.md) |
| 世界、地图、水体 | [world](docs/eng/world.md) |
| 渲染、UI、工具 | [render](docs/eng/render.md)、[ui](docs/eng/ui.md)、[tools](docs/eng/tools.md) |
| 验证、性能、资料 | [tests](docs/eng/tests.md)、[low_overhead_performance](docs/eng/low_overhead_performance.md)、[architecture_references](docs/eng/architecture_references.md) |

必须保持的跨子系统不变量：

- **环面坐标**：逻辑/物理坐标始终在 `[0, width) × [0, height)`；渲染才用 `anchor_to_nearest()`；距离、射线、击退统一用 `toroidal_delta_px()`。
- **地形所有权**：`Terrain` 独占网格、子格 HP、碰撞分块、预测差分与回溯；TileMapLayer 只负责显示。
- **时间控制**：仅单人 `Level0` 启用；不修改全局 `Engine.time_scale`，在实体步进和速度计算中分层缩放。
- **网络权威**：伤害、生成/销毁、拾取、胜负由服务端裁决；客户端只做预测与表现；大厅与对局共用单进程单端口。
- **碰撞查询**：只用 Godot 物理；角色代理、弹丸扫掠、光束/爆炸查询分别走 `cast_motion()`、`move_and_collide()` 与 `intersect_shape()/intersect_ray()`。

更完整的目录、所有权与每 tick 顺序见 [PORT_PLAN.md](PORT_PLAN.md)。

---

## 四、验证与文档

按改动风险选择[关键行为检查](docs/eng/tests.md)。必要验证通过后停止，不为数量或覆盖率追加测试。性能观测采用固定容量标量聚合，专项问题再短时采样；方法见[性能观测](docs/eng/low_overhead_performance.md)。

实现文档只介绍当前行为、接口、所有权与约束。注释解释必要边界和不直观的原因，省略代码复述、任务编号、修改历史和大段运行说明。调研报告只写资料来源、可参考的部分、当前已经采用的部分，并明确证据和适用范围。不记录逐轮修改、阶段进度、旧架构或验证流水；修改历史由版本控制保存。
