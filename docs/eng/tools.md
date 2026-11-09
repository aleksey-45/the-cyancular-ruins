# 工具与格式（`tools/`）

> 本文件覆盖**仓库工具**（发布 / 守卫 / 地图数据 / 场景生成）与 `.ps1`·`.bat` 的硬约束。
> 地图编辑器本身见 [`editor-godot.md`](editor-godot.md)；`.cyrm` 格式契约见 [`editor-core.md`](editor-core.md)。
> 返回索引：[`README.md`](README.md)。★ 冲突以源码为准，读之前先 `grep` 复核。

## 1. 地图与数据

- **砖块属性表**：唯一真相源 = [`data/tile_defs.json`](../../data/tile_defs.json)。游戏侧 [`TileDefs`](../../core/sim/tile_defs.gd) 与
  编辑器 [`EditorValidate`](../../core/editor/editor_validate.gd) 都直接读它，**没有第二份生成副本**（旧浏览器编辑器那份
  `tile_defs.js` 已随 `level_editor/` 退役）。
- **敌人注册表**：唯一真相源 = [`data/enemies.json`](../../data/enemies.json)（`EnemySpawner` 读它）。
- [`tools/map_spawn_meta.gd`](../../tools/map_spawn_meta.gd)（`-s` 跑）：地图出生点/按侧复活点的校验与写盘。
  - `--check` 校验地图现有数据（每侧 ≥5 / 在自己半区 / 每个点合格 / 9 桶覆盖 / 同侧间距）；
  - `--suggest [--side 1|2]` 按半区均匀撒点建议（只打印、不写盘）；
  - `--list` / `--inspect "x,y;..."`；`--respawn1 "x,y;..." --respawn2 "..." --write` 写盘。
  - 写盘走 `MapFormatV4.replace_meta`：只替换 meta 文本段，**层块字节逐字节原样保留**（走 `serialize()` 会从格级网格重铺场景层，
    丢掉编辑器画的 16px 混排）；写后自动回读校验。
- [`tools/migrate_map_textures.gd`](../../tools/migrate_map_textures.gd)：旧纹理 id 的一次性迁移工具（legacy 映射规则见
  [`editor-core.md`](editor-core.md) §6）。

## 2. 发布工具

- [`tools/build_release.py`](../../tools/build_release.py)：一次导出**两份 Windows 产物 + 两份 macOS + Web**，然后自动跑产物冒烟
  （客户端直接启动 / 服务端 `--worker` / 武器注册表 / **编辑器入口**两条断言），最后归档到 `builds/`。流程与判词见
  [`RELEASE.md`](../../RELEASE.md)。
- [`tools/archive_build.py`](../../tools/archive_build.py)：把两产物按「版本号 + 时间戳」归档（`build_release.py` 末尾调用）。
- [`tools/make_server_console.py`](../../tools/make_server_console.py)：把服务端 exe 打回 CONSOLE 子系统（裁剪模板无官方 console-wrapper）。
- [`tools/build_cyancular.bat`](../../tools/build_cyancular.bat) / [`tools/make_launchers.c`](../../tools/make_launchers.c)：Windows 启动器打包。
- 版本号唯一来源 = `project.godot` 的 `application/config/version`；发布前缀 = 同文件 `release_prefix`。**别在文档里另抄数字。**

## 3. 仓库守卫

- [`tools/check_naming.py`](../../tools/check_naming.py)：目录小写 / `class_name`↔文件名 / 文档路径 / `.tscn` snake_case /
  `.ps1`·`.bat` 的 CRLF 与编码 / 入口文档预算与 `CLAUDE.md` 副本一致。规则 A~F 的原文就是该文件的函数注释。
- [`tools/gen_rpc_channel_table.py`](../../tools/gen_rpc_channel_table.py)：`docs/eng/netplay-rpc-channels.md` 的 RPC 通道表 ↔ 代码 `@rpc`
  声明的生成式对账（`--check` 只校验不写盘，漂移退 1；`--write` 幂等重写；`--self-test` 纯函数自测）。
- [`tools/sync_agents_md.py`](../../tools/sync_agents_md.py)：`AGENTS.md` → `CLAUDE.md` 生成副本（改了 AGENTS 必须跑一次）。
- [`tools/clean_comments.py`](../../tools/clean_comments.py)：注释风格/额度的批量清理工具（一次性；日常改代码别顺手全仓跑）。
- [`tools/pixel_diff.py`](../../tools/pixel_diff.py)：两张图逐像素 diff（视觉整改的验收工具）。

## 4. 场景生成

- [`tools/gen_menu_scene.gd`](../../tools/gen_menu_scene.gd)：主菜单骨架（`scenes/main_menu.tscn`）的生成器，双模式 ——
  `-- main_menu` 是**构建模式**（从零搭容器树并写盘，产物自检 unique name/按钮顺序/0 绝对 offset，不过就 FAIL 不写）；其它屏名保留旧的 `.tscn` 转换路径（只用于 `.superpowers/sdd/_gen/` 手工对照，info/beta/match_result 迁移后该路径已失效，不在默认批）。
  ★ 改菜单版式 = 改生成器再重跑 + 改前/改后截图；编辑器入口仍是**运行期**按 feature 追加，不在骨架里。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd)：菜单主题资源生成器（Theme 2.0：Button Primary/Quiet/Danger/Icon、Panel Card/Plain/Bar、Label H1/H2/Body/Dim/Field、Kit 承载 CheckButton/ScrollBar/Tab/Split/Dialog）。改样式只改生成器再重跑。
- [`tools/ui_shots.py`](../../tools/ui_shots.py)：**非 headless** 页面截图工具（`python tools/ui_shots.py [页面名] [--size WxH]`），出图到 `.tmp/ui_shots/`；只给迁移/评审对比用，不进默认批。

## 5. 抓现场 / 一次性

- [`tools/crashlog_capture.py`](../../tools/crashlog_capture.py)：崩溃日志抓取。
- [`tools/_shot_scene.gd`](../../tools/_shot_scene.gd) / [`.tscn`](../../tools/_shot_scene.tscn)：截图探针（非 headless，跑前告知用户）。

## 6. Windows 脚本的两条硬约束（改 `.ps1` / `.bat` 前必看）

- **换行**：`.ps1` 与 `.bat` **必须 CRLF** —— 裸 LF 的 `.ps1` 会被 PowerShell 解析成一条怪命令；`.bat` 会被 cmd 吃掉行尾。
- **编码**：`.ps1` = 「**纯 ASCII 或带 UTF-8 BOM**」（无 BOM 的非 ASCII 在中/英区域会按 GBK 读 ⇒ 中文全乱、字符串被截断）；`.bat` 不查编码。
- 两条都由 [`check_naming.py`](../../tools/check_naming.py) 的**规则 E** 逐文件守。红了的标准修法是 `rm <file> && git checkout -- <file>` 重新落盘（**纯 EOL，不动内容**）。
- **带空格的路径**在 PowerShell 里要**手工内嵌双引号**（`& "C:\Program Files\..."`）；传参给 `.bat` 同理。

## 7. 地图编辑器怎么打开

客户端产物（`custom_features="editor"`）的主菜单里有「地图编辑器」按钮；开发态直接加载
`res://scenes/editor/editor_root.tscn`。画布/工具/导出/校验的操作说明见 [`editor-godot.md`](editor-godot.md) §6。
