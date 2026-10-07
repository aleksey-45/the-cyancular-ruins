# CLAUDE.md

本文件为项目工程指南与核心架构索引，面向使用 Claude Code 或其他 AI 编程助手的开发者。

> **架构文档索引**：本项目核心机制与子系统技术细节已按领域拆分至 [`docs/eng/`](docs/eng/) 目录下。本文件保留**项目概览**、**常用命令**、**全局架构总览**及**开发关键约束**。
> **历史全量归档**：[`docs/claude-md-full-archive.md`](docs/claude-md-full-archive.md) 记录了早期版本的完整推导过程与测试数据，供历史查证。
> **权威准则**：任何文档与代码出现冲突时，一律以**最新源码实现与自动化测试断言**为最终准则。

---

## 一、 项目概览

「The Cyancular Ruins」（天青色废墟）是一款基于 Godot 4.7（标准版，非 Mono）开发的 2D 横版平台跳跃动作射击游戏演示项目。
- **视口规格**：分辨率 1920×1440，渲染后端使用 `rendering/mobile`。
- **空间几何**：**环面世界**，地图水平与垂直方向均无缝循环连通，实体、子弹与摄像机平滑跨越地图接缝。
- **单人模式**：包含关卡 `Level0`，加载 `.cyrm` 格式地图，支持时间控制系统（时空回溯与时间加速）。
- **多人对战**：支持 1v1 回合决斗、3v3 团队对抗及多人大乱斗，具备专用服务端权威模拟、客户端预测与回滚、断线重连，以及基于 EasyTier 的免驱动应用层 P2P 网络隧道。

---

## 二、 常用开发与测试命令

若 Godot 未加入系统 `PATH` 环境变量，需使用绝对路径调用。主用版本为 **Godot 4.7.1 标准编辑器**（控制台版本与导出编辑器版本分离）。

**环境变量覆盖**：脚本统一支持读取环境变量 `GODOT`（指向控制台版本 `Godot_*_console.exe`）与 `GODOT_EDITOR`（指向标准编辑器版本，用于导出构建）。未设置时使用各脚本入口定义的本机默认路径（如 `tests/env.sh`、`start_server.bat`、`tools/build_release.py`）。

```bash
# 1. 运行冒烟测试（SceneTree 纯逻辑脚本，测试通过时输出 SMOKE OK 并以状态码 0 退出）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/smoke/enemy_logic_smoke.gd

# 2. 运行场景级探针测试（通过 --quit-after 设置最大帧数作为超时保护，自动执行断言）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 3600 res://tests/probe/haste_probe.tscn

# 3. 启动无头服务端（默认单进程单端口模式，监听 7777 端口；亦可直接双击仓库根目录 start_server.bat）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 4. 无头模式启动游戏并在 90 帧后退出（用于验证场景加载与脚本语法是否存在运行时异常）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# 5. 执行命名与路径规范检查（校验目录小写、类名与文件名对齐、文档引用路径有效性）
python tools/check_naming.py

# 6. 导出单可执行文件发布版本
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

**版本号管理准则**：
- 版本号唯一来源为 `project.godot` 中的 `application/config/version`，格式必须遵循严格的数字与点分规范（例如 `0.5.0`，禁止带有前缀 `v`，否则会导致导出模板预设校验失败）。
- 构建脚本 `tools/build_release.py` 会在导出前将版本号与时间戳写入 `core/config/build_info.gd`，导出完成后自动还原为开发占位符。
- 自定义启动参数必须置于 `--` 之后传递（由 `server_main.gd` 通过 `OS.get_cmdline_user_args()` 读取），置于 `--` 之前的非引擎参数会被 Godot 静默丢弃。

---

## 三、 架构分域索引

各业务子系统的完整实现方案、接口定义与边界约束详见 [`docs/eng/`](docs/eng/) 目录下的分域文档：

| 子系统领域 | 文档路径 | 核心覆盖范围 |
|---|---|---|
| **世界与地图** | [`docs/eng/world.md`](docs/eng/world.md) | 环面空间几何、`.cyrm` 地图格式（v3 文本与 v4 二进制）、16px 子格物理碰撞与破坏判定、`TileDefs` 属性表、水体环境与流体物理、物理层掩码。 |
| **敌人系统** | [`docs/eng/enemies.md`](docs/eng/enemies.md) | 敌人继承层次、AI 状态机、飞行 A* 寻路与避障、受击白闪与死亡实体物理保留、`data/enemies.json` 数据驱动注册。 |
| **武器与弹药** | [`docs/eng/weapons.md`](docs/eng/weapons.md) | 武器基类 `WeaponBase`、即时光束 `LaserWeaponBase`、抛物线与爆炸子弹、背包双重限制（8格容量与4把上限）、地面武器管理、`data/weapons.json` 注册表。 |
| **玩家控制** | [`docs/eng/player.md`](docs/eng/player.md) | 角色平滑移动、土狼时间与跳跃缓冲、姿态碰撞多边形切换、组件化拆分（攀爬/战斗/武器）、输入源抽象接口、弹药权威状态同步。 |
| **渲染管线** | [`docs/eng/render.md`](docs/eng/render.md) | `SubViewport` 独立渲染树、瓦片图集构造器 `TerrainAtlas`、屏幕后处理 Shader、角色与敌人补间挤压拉伸形变。 |
| **UI 系统** | [`docs/eng/ui.md`](docs/eng/ui.md) | 全局调色板与工厂 `UiFactory`、16px 位图与 Unifont 字体规范、战斗 HUD、武器槽位、小地图（圆形雷达）、统一联机大厅。 |
| **网络联机** | [`docs/eng/netplay.md`](docs/eng/netplay.md) | 单进程单端口会话架构（`MatchSession`）、EasyTier 免驱动应用层 P2P 网络隧道、全链路动态端口分配、客户端预测与回滚、断线重连与宽限期。 |
| **对局模式** | [`docs/eng/modes.md`](docs/eng/modes.md) | 1v1 回合制死斗、3v3 团队对抗（分队碰撞、队伍色彩映射、助攻判定）、多人大乱斗、通用结算界面与评分规则。 |
| **测试体系** | [`docs/eng/tests.md`](docs/eng/tests.md) | 冒烟测试（`tests/smoke/`）与场景探针（`tests/probe/`）、源码级静态检测脚本、网络集成测试规范、残留子进程回收。 |
| **开发工具** | [`docs/eng/tools.md`](docs/eng/tools.md) | 基于 Web Canvas 的关卡编辑器、数据表代码同步脚本（`sync-enemies.js` / `sync-tiles.js`）、发布打包与产物冒烟工具。 |
| **技术债务** | [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md) | 当前系统记录的已知边界、历史容差处理与待重构清单。 |

---

## 四、 核心开发约束与设计准则

在修改代码或增加新功能时，必须严格遵守以下工程规范：

### 1. 配置驱动与统一数据源
- **数据驱动配置**：武器定义唯一来源为 `data/weapons.json`，敌人定义唯一来源为 `data/enemies.json`，瓦片属性唯一来源为 `data/tile_defs.json`。禁止在业务代码中硬编码类型列表或 ID 数组。
- **UI 风格与色彩**：所有颜色常量必须直接引用 `UiFactory`（`ui/factory/ui_factory.gd`）中定义的语义色值，禁止在代码中硬编码 `Color(...)` 字面量。
- **字号阶梯**：所有 UI 控件的字号必须为 16 的整数倍（16px、32px 等），以保证像素字体在渲染时边缘清晰不模糊。

### 2. 环面地图几何规则
- **坐标规范化**：角色的逻辑位置始终保持在 `[0, MAP_WIDTH)` 与 `[0, MAP_HEIGHT)` 区间内，每帧通过 `GridPathfinder.wrap_to_range()` 处理。
- **就近对齐**：渲染实体、敌方远端镜像以及子弹必须使用 `GridPathfinder.anchor_to_nearest()` 对齐至相对本地玩家最近的环面副本，确保跨接缝视野连续，避免越界消失。
- **环面距离判定**：所有距离判定与击退方向向量必须通过 `GridPathfinder.toroidal_delta_px()` 计算环面最短路径，禁止直接相减。

### 3. 网络与同步安全准则
- **服务端权威原则**：所有伤害结算、子弹生成销毁、拾取判定与胜负裁决均由服务端权威执行；客户端仅执行本地表现预测与视觉模拟。
- **输入序列协议**：客户端输入包严格按递增序号（`seq`）发送，服务端按物理帧消费并回传确认序号（`ack_seq`）。当快照状态与预测状态超出容差时，客户端执行回滚并重放未确认的输入帧。
- **单进程单端口会话**：大厅与对局运行于同一 ENet 主机端口上，通过将 `MatchSession` 节点动态挂载至场景树实现零中断无缝开局。

### 4. 自动化测试规范
- **行为断言明确**：每个新增的测试断言必须明确其失败条件与检验意图，禁止编写无实际校验价值的形式断言。
- **测试环境安全**：在运行网络集成测试前，确保后台无残留子进程；涉及端口分配的测试必须向操作系统动态申请空闲端口，避免端口占用冲突。
- **路径检查合规**：提交前必须运行 `python tools/check_naming.py`，确保所有文件命名、类名映射以及文档引用的路径完全有效。
