# 命名与目录整改 — 执行记录(2026-09-05)

> 本文档是整改方案 + 执行结果。目标:统一大小写与文件命名规范,消灭"大小写双条目 / case mismatch",并让目录名名副其实。

## 采用的规范(单一来源,已写进 CLAUDE.md / README)
1. 目录一律小写(顶层与 `scenes/` 子目录)。
2. 脚本文件名一律 snake_case;`class_name` 保持 Pascal(名字 = 类名转 snake)。
3. 场景 `.tscn` 保持 PascalCase,与其 snake 脚本成对(`EnemyFlyBird.tscn` ↔ `enemy_fly_bird.gd`)——这是约定,不算不一致。
4. autoload 标识 Pascal、文件 snake。
5. 术语:类/文件用 `pvp_`/`Pvp`;`map`→`maps`、目录取复数。
6. 数据文件进 `data/`,不塞在代码目录。

## 执行结果(已完成,未提交)

**目录重组**
- `globals/` → `core/`(共享代码/静态助手);`tile_defs.json` → `data/tile_defs.json`。
- `editor/` 拆分:运行时定义 `enemies.json` → `data/`;浏览器关卡工具(html/js/sync/png)→ `level_editor/`;`tools/` 保留(构建脚本)。
- `map/` → `maps/`(含 `demo.cyrm`/`factory1v1.cyrm` 等)。
- `scenes/Enemies|Player|Weapons|Effects` → `scenes/enemies|player|weapons|effects`。
- 从 `scenes/` 根抽出横切系统:`hud.gd`、`pvp_hud.gd|tscn` → `ui/`;`post_process.gd` → `render/`。

**文件级改名**
- `core/gameParameters.gd|enemyParams.gd|playerParams.gd` → `game_parameters.gd|enemy_params.gd|player_params.gd`(autoload 路径随 `project.godot` 更新)。

**引用同步**
- 全库 `res://` 与 tscn ext_resource、`enemies.json` 内场景路径、`project.godot` autoload、`export_presets.cfg` include_filter 统一改写(脚本化,67 个文件)。
- `.godot` 缓存整删重建 → `--import` 零 hides / 零 case mismatch / 零解析错误。
- 回归:`enemy_logic_smoke` SMOKE OK、`water_probe` WATER OK、场景(main_menu / matchmaking / ui/pvp_hud / Level0 / pvp_game)headless 启动无脚本错误。
- 已知遗留:grenade_smoke 的 "墙后敌人保留 75% 伤(26)" 失败为**既存问题**(基线即失败,与本次无关)。

**git 现状**
- 已提交 `9572e51`(去重 + UI/性能等,安全点)。
- 目录/文件改名与引用改写为未提交改动(大量 rename),待审后提交。

## 防复发
- 规范见上;此后新增文件按规范命名。
- 可选:加一个 `tools/check_naming`(遍历 class_name↔文件名、目录大小写),CI/本地可跑。
