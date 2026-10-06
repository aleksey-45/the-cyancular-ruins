# 代码与资源命名规范及目录重构方案 (2026-09-05)

> 本文档记录工程目录结构调整、命名规范统一方案及落地执行结果。旨在统一大小写风格与文件命名规约，消除跨平台文件系统大小写敏感性问题（Case-Sensitivity Mismatch），并优化模块化目录组织。

---

## 一、 命名与组织规范

以下规范作为全工程统一规范，并已同步纳入 `CLAUDE.md` 与 `README.md`：

1. **目录命名**：全小写下划线或连字符风格（根目录与 `scenes/` 下各级子目录均遵循此规则）。
2. **GDScript 脚本命名**：文件使用 `snake_case.gd`；类声明 `class_name` 使用 `PascalCase`（类名与文件名保持一一对应的转换规则）。
3. **场景文件命名**：场景文件统一采用 `snake_case.tscn`，与其挂载的根脚本名称保持一致（如 `enemy_fly_bird.tscn` ↔ `enemy_fly_bird.gd`）。
   - 注：历史版本中曾要求场景采用 PascalCase，但实际工程中已有 90% 以上场景符合 snake_case。为保持规则统一与工具可维护性，已全面统一为 snake_case，并由静态检查脚本 `tools/check_naming.py` 实施自动化校验。
4. **Autoload 全局单例**：单例声明标识符使用 `PascalCase`，对应脚本文件使用 `snake_case.gd`。
5. **专有名词统一**：
   - PvP 相关类与文件统一使用 `Pvp` / `pvp_` 前缀。
   - 地图相关目录统一采用复数形式 `maps/`。
6. **数据与配置文件**：静态配置及共享数据存放在 `data/` 目录，禁止与源代码混杂。

---

## 二、 重构执行记录

### 1. 目录架构调整
- `globals/` 重命名为 `core/`，收敛核心逻辑、全局服务与静态工具类；将 `tile_defs.json` 归档至 `data/tile_defs.json`。
- `editor/` 模块解耦：
  - 运行时敌人配置 `enemies.json` 归档至 `data/`；
  - 基于 Web 的关卡编辑器及配套同步工具移至 `level_editor/`；
  - `tools/` 保留作为构建与打包工具专用目录。
- `map/` 目录更名为 `maps/`（包含 `demo.cyrm`、`factory1v1.cyrm` 等地图文件）。
- 场景目录小写化：`scenes/Enemies|Player|Weapons|Effects` 统一重命名为 `scenes/enemies|player|weapons|effects`。
- 提取表现层与渲染层组件：从 `scenes/` 根目录抽出通用 HUD（`hud.gd`、`pvp_hud.gd/tscn`）至 `ui/`；后处理效果抽出至 `render/`。

### 2. 核心文件重命名
- 驼峰命名脚本更名：`core/gameParameters.gd`、`enemyParams.gd`、`playerParams.gd` 统一修改为 `game_parameters.gd`、`enemy_params.gd`、`player_params.gd`，并同步更新 `project.godot` 中的 Autoload 配置。

### 3. 依赖与引用同步
- 全工程自动化改写 `res://` 内部资源引用、`.tscn` 场景外部资源引用（ext_resource）、`enemies.json` 场景路径、`project.godot` 配置项以及 `export_presets.cfg` 的导出包含过滤规则（覆盖 67 个文件）。
- 重建 `.godot` 引擎导入缓存：执行 `--import` 重新索引，确认无废弃资源引用、无大小写歧义且无解析报错。
- 自动化测试回归：
  - 逻辑冒烟测试 `enemy_logic_smoke.gd` 与 `water_probe.gd` 正常通过；
  - 各核心场景（`main_menu`、`matchmaking`、`ui/pvp_hud`、`Level0`、`pvp_game`）以无头模式加载无脚本异常。

---

## 三、 持续保障机制

- 后续新增功能模块与资源必须严格遵循本命名规范。
- 引入命名合规性检查脚本 `tools/check_naming.py`，遍历校验类名与文件名映射、目录大小写规范，纳入 CI 及本地自检流程。
