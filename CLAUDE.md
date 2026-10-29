# CLAUDE.md

本文档为项目的工程开发指南与架构索引。

> **架构文档索引**：各子系统的技术细节请查阅 [`docs/eng/`](docs/eng/) 目录。本文档提供**项目概览**、**常用命令**、**系统架构说明**与**开发规范**。
> **代码权威原则**：若文档与代码实现不一致，以**最新源码实现**为准。

---

## 一、 项目概览

「The Cyancular Ruins」（天青色废墟）是一款基于 Godot 4.7（标准版，非 Mono）开发的 2D 横版平台跳跃射击游戏演示项目。
- **渲染规格**：视口分辨率 1920×1440，使用 `rendering/mobile` 渲染后端。
- **空间几何**：**环形世界（环面几何）**，地图在水平与垂直方向均首尾相连循环连通，实体、子弹与摄像机平滑跨越边界。
- **单人模式**：核心关卡 `Level0`，加载 `.cyrm` 格式地图，支持时间控制系统（时空回溯与时间加速机制）。
- **多人对战**：包含 1v1 回合死斗、3v3 团队对抗以及多人大乱斗模式。采用专用服务端权威架构，支持客户端预测与回滚、断线重连保护，以及基于 EasyTier 的免驱动应用层 P2P 网络隧道。

---

## 二、 常用开发与测试命令

若未将 Godot 目录加入系统 `PATH` 环境变量，需使用绝对路径调用。主用版本为 **Godot 4.7.1 标准版**。

**环境变量配置**：脚本支持通过环境变量 `GODOT`（指向控制台版 `Godot_*_console.exe`）与 `GODOT_EDITOR`（指向标准编辑器版）进行路径覆盖。未设置时自动回退到各脚本内预设的默认路径。

```bash
# 1. 启动无头专用服务端（默认单进程单端口模式，监听 7777 端口）
godot --headless --path . res://server/server_main.tscn

# 2. 无头模式启动游戏并在 90 帧后退出（用于验证场景加载与脚本语法是否存在异常）
godot --headless --path . --quit-after 90

# 3. 执行命名与路径规范检查（校验目录小写、类名与文件名映射、文档引用有效性）
python tools/check_naming.py

# 4. 导出单可执行文件发布版本
godot --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

**版本号与构建规范**：
- 版本号唯一来源为 `project.godot` 中的 `application/config/version`，格式遵循标准数字点分格式（例如 `0.5.0`，不带 `v` 前缀）。
- 构建脚本 `tools/build_release.py` 会在导出前将版本号与时间戳写入 `core/config/build_info.gd`，导出完成后还原为开发占位符。
- 发布压缩包为 `The-Cyancular-Ruins.zip`，内部根目录为 `The-Cyancular-Ruins-YYYYMMDDHHMM/`（时间戳使用 UTC+8）。
- 自定义启动参数必须放在 `--` 之后传递（由 `server_main.gd` 通过 `OS.get_cmdline_user_args()` 读取），`--` 之前的非引擎参数会被 Godot 忽略。

---

少量关键行为检查见 [验证说明](docs/eng/tests.md)，原生固定容量统计与开销口径见 [低开销性能观测](docs/eng/low_overhead_performance.md)。地形状态和计算归属见 [原生地形](docs/eng/native_terrain.md)。

## 三、 架构文档索引

| 主题 | 当前实现 |
|---|---|
| 世界、地形、地图与水体 | [世界](docs/eng/world.md)、[原生地形](docs/eng/native_terrain.md) |
| 角色、武器、敌人 | [玩家](docs/eng/player.md)、[武器](docs/eng/weapons.md)、[敌人](docs/eng/enemies.md) |
| 高频模拟与表现边界 | [原生模拟](docs/eng/native_scene_simulation.md)、[原生战斗](docs/eng/native_combat_simulation.md) |
| 联机、模式与预测 | [联机](docs/eng/netplay.md)、[模式](docs/eng/modes.md)、[本地预测](docs/eng/local_prediction_design.md)、[历史复用](docs/eng/prediction_reuse.md) |
| 画面与界面 | [渲染](docs/eng/render.md)、[UI](docs/eng/ui.md) |
| 开发与验证 | [工具](docs/eng/tools.md)、[关键行为检查](docs/eng/tests.md)、[性能观测](docs/eng/low_overhead_performance.md) |
| 资料及适用范围 | [调研索引](docs/eng/architecture_references.md)、[实现边界](docs/eng/registered-debt.md) |

实现文档只说明当前行为、接口与约束；注释说明必要边界和不直观的原因。调研报告只保留资料来源、可参考部分和当前采用情况。修改过程、阶段进度、旧架构和逐轮验证结果不写入这些文档。

---

## 四、 核心开发约束与设计准则

在修改代码或增加新功能时，请遵循以下规范：

### 1. 配置驱动与统一配置源
- **数据表配置**：武器定义唯一来源为 `data/weapons.json`，敌人定义唯一来源为 `data/enemies.json`，瓦片属性唯一来源为 `data/tile_defs.json`。严禁在业务逻辑中硬编码类型列表或 ID 数组。
- **UI 风格与颜色**：界面颜色统一使用 `UiFactory`（[`ui/factory/ui_factory.gd`](ui/factory/ui_factory.gd)）中定义的语义常量，禁止在业务代码中硬编码 `Color(...)` 字面量。
- **UI 字号规范**：界面控件字号必须为 16 的整数倍（如 16px、32px 等），以确保像素字体渲染清晰不失真。

### 2. 环形地图几何规则
- **坐标规范化**：角色的逻辑位置约束在 `[0, MAP_WIDTH)` 与 `[0, MAP_HEIGHT)` 区间内，每帧通过 `GridPathfinder.wrap_to_range()` 处理越界取模。
- **就近副本对齐**：渲染远端实体、敌方镜像与子弹时，必须调用 `GridPathfinder.anchor_to_nearest()` 映射到相对本地玩家最近的可视副本位置，确保跨边界视野连续无缝，避免画面闪烁或消失。
- **环形最短距离计算**：所有实体间的距离判定、射线检测与击退方向向量必须调用 `GridPathfinder.toroidal_delta_px()` 计算环形最短位移，严禁直接相减。

### 3. 网络与状态同步规范
- **服务端权威原则**：伤害结算、子弹生成与销毁、拾取判定以及胜负判定均由服务端权威执行；客户端仅负责本地操作预测与视觉模拟表现。
- **输入序列与确认机制**：客户端按控制阶段（epoch）与递增序号（seq）发送输入包，服务端每物理帧消费一条，通过 ACK 确认已执行的输入并清理过期指令。客户端收到权威状态后先比较同 tick 状态与依赖，保留有效前缀并重放失效后缀；历史缺失时恢复权威锚点；预测重放期间不重复执行表现层动作。
- **单进程单端口会话**：大厅与对战运行于同一个 GNS UDP 端口上，开局时直接将 `AuthorityWorld` 节点挂载至服务端场景树，客户端无需断开或重连。

### 4. 验证与提交流程
- **验证结果**：编译与资源导入需退出码为 0 且无脚本解析错误；运行关联行为分组；是否验证实际对局按修改范围判断，测试范围与风险对应。
- **进程与端口清理**：运行网络集成测试前后，确保无残留子进程；端口分配需动态申请空闲端口，避免冲突。
- **命名规范自检**：提交前必须运行 `python tools/check_naming.py`，保证目录小写、类名与文件名对应、文档引用路径有效。
