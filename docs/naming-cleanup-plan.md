# 命名与目录整改方案(The Cyancular Ruins)

> 目标:把"大小写/文件命名"层面的不一致一次理清,给出**单一规范 + 防复发手段**。
> 性质:方案文档。是否执行、执行到哪一阶段,由你决定后再动手。

## 1. 现状盘点(命名事实)

**目录大小写**
- 顶层目录全小写:`assets/ globals/ scenes/ server/ tests/ shaders/ editor/ map/ docs/ tools/`(构建产物 `builds/ backup/` 已 gitignore)。
- `scenes/` 的**子目录却是 PascalCase**:`Enemies/ Player/ Weapons/ Effects/` —— 与顶层风格不一致(历史遗留,正是这次 88 条大小写重复的来源)。

**脚本文件名(共 64 个 .gd,33 个声明 class_name)**
- 主流:**snake_case** + PascalCase class(`enemy_base.gd` → `EnemyBase`、`water.gd` → `Water`)。
- 混入 **camelCase** 文件名:`globals/gameParameters.gd`(autoload `GameParameters`)、`globals/enemyParams.gd`(`EnemyParams`)、`globals/playerParams.gd`(`PlayerParams`)。
- 场景 `.tscn` 为 **PascalCase**(`EnemyFlyBird.tscn`、`Player.tscn`),与其脚本 `enemy_fly_bird.gd`/`player.gd` 不同名——目前无运行错误,但不统一。

**类名 ↔ 文件名整体一致性**
- 所有 class_name 均 Pascal;绝大多数与"类名转 snake"对得上。异常仅上述 3 个 camel 文件。
- `HUD`、`PvpHud`、`Level0`、`PostProcess` 等类与其 snake 文件名匹配约定一致(Level0→level_0 可读性一般但成例)。

**autoload(project.godot `[autoload]`,共 2 个)**
- `GameParameters="*res://globals/gameParameters.gd"`、`NetBus="*res://globals/net_bus.gd"`——autoload 标识 Pascal,文件 snake/camel 混。

**术语/命名**
- "PvP" 大小写不一:PvpSession、PvpHud(class + file `pvp_*`)与注释里的 PvP 混用;服务器目录/测试名 `pvp_*` 全小写(一致)。
- 复数/单数不一致:地图目录 `map/`(单数)vs 其余类别目录多为复数(`assets scenes tests`)。

**其它**
- Godot 4.4+ 会给脚本生成 `.uid` 伴生文件(`pixel_font.gd.uid`),入库与否要统一口径(建议入库)。
- 本次大小写去重**尚未提交**(暂存 88 个大写路径删除 + backup/editor.rar)。

## 2. 问题分类与严重度

| # | 问题 | 影响 | 严重度 |
|---|---|---|---|
| N1 | 顶层小写 vs scenes 子目录 Pascal | 大小写敏感平台/导出翻车;历史上已引发重复条目 | 高(已发生) |
| N2 | 脚本文件名 snake 为主、3 个 camel 混入 | 检索/直觉不一致 | 中 |
| N3 | `.tscn` Pascal 与 `.gd` snake 脱节 | 改名/找文件靠猜 | 中(成对约定可接受) |
| N4 | autoload 文件与标识符大小写风格不一 | 小 | 低 |
| N5 | PvP/Pvp 大小写混用 | 检索不一致 | 低 |
| N6 | `map/` 单数 | 视觉不一致 | 低(建议保留不折腾) |

## 3. 目标规范(单一来源,写成 CLAUDE.md/README 约定)

1. **目录一律小写**(含 `scenes/` 子目录 → `enemies player weapons effects`)。
2. **脚本文件名一律 snake_case**,class_name 保持 Pascal,名字=类名转 snake(规范外一律先问)。
3. **场景 `.tscn` 保持 PascalCase** 且与其根脚本同名不同写是**成例**:例如 `EnemyFlyBird.tscn` 对 `enemy_fly_bird.gd` —— 写入约定,不改。
4. **autoload 标识 Pascal,文件名 snake**。
5. 术语前缀:类/文件统一 `pvp_`/`Pvp`,注释允许 PvP(展示词)。
6. `map/` 保留单数(内容是一个地图集目录),`tile_defs.json` 归属写在 README(已做)。
7. 新增 `.gd/.tscn/.gdshader` 默认 snake 文件 + Pascal class,违者由 check 拦。

## 4. 整改步骤

> 重要:先做 P0,再做改名;改名全部基于**已小写去重**的索引,避免二次混乱。

### P0 — 提交既有大小写清理(前置,必须先做)
- `git add -A && git commit` 落盘:88 个大写重复路径删除、`backup/editor.rar` 移出、此前 UI/性能改动、`.gitignore`、README。
- 产出:一棵已去重、无大小写双条目的干净树,后续改名基于它。**本步本身就要你确认提交内容**。

### P1 — 立规范 + 防复发(低风险)
- 把第 3 节约定写进 `CLAUDE.md`(给 agent)与 `README.md`(给人)。
- 加一个仓库级**命名检查脚本**(`tools/check_naming.gd` 或 `.sh`,~30 行):遍历 tracked 文件,
  - 报"目录含大写 / scenes 子目录非全小写";
  - 报"`class_name` 名 ≠ 文件名转 snake";
  - 退出码非 0。CI/本地可跑。**不改代码**,只拦截未来。
- 可选:`.gitattributes` 固定 `*.gd eol=lf` 等,消除 CRLF 噪音,并为未来大小写敏感导出打底。

### P2 — 文件级改名(低风险,约 4 处,手工可审)
把 3 个 camel 参数文件改 snake,并同步 autoload 路径:
- `globals/gameParameters.gd → globals/game_parameters.gd`(仅 `project.godot` `[autoload]` 一处路径引用)
- `globals/enemyParams.gd → globals/enemy_params.gd`
- `globals/playerParams.gd → globals/player_params.gd`
- 类名/调用点(`GameParameters/EnemyParams/PlayerParams.xxx`)**不受影响**(经 class_name / autoload 标识,不按路径引)。
- 验证:`--import` 无错、`enemy_logic_smoke` + 各 probe 通过、`pvp_room/match` smoke 可跑。
- 注:文件里已带 `.uid` 的同步更名(引擎会自动,不必手工)。

### P3 — 目录级改名(高风险、需脚本化;收益 = 根治 N1)
把 `scenes/` 四个 Pascal 子目录整体改小写:
- `scenes/Enemies→scenes/enemies`、`Player→player`、`Weapons→weapons`、`Effects→effects`。
- 机械步骤:
  1. **两段式 `git mv`**(Windows 大小写不敏感,直接改会失败):先移成唯一临时名(`scenes/_enemies_tmp`),再移到目标小写名;每个目录独立做。
  2. 全局替换前缀文本:对 tracked 的 `.gd/.tscn/.gdshader/.md` 把 `res://scenes/Enemies/` 等 4 个前缀统一替换为小写(约 40 个文件,`tools/` 用脚本一次性做,先生成 diff 供审)。
  3. 重开 `.tscn` 的 ext_resource 由编辑器或脚本按新路径重写(确保每个 tscn 里 script/预载路径落盘为小写)。
  4. 删 `.godot` 缓存 → 全新 `--import`,确认零 "case mismatch / hides class"。
  5. 回归:`enemy_logic_smoke`、`water_probe`、`climb/grenade/tile_destroy`、`pvp_room/match` smoke、场景启动(Level0/main_menu/matchmaking/pvp_game/pvp_hud)。
- 回滚:本阶段不提交前用 `git reset --hard HEAD` 即可整体回退(前提是 P0 已提交作为安全点)。

### P4 — 收尾
- 更新 `CLAUDE.md` / `README.md` 目录图与路径示例到最终形态。
- `.uid` 伴生文件入库口径写入 P1 约定。
- 保留 `map/`(见 N6)并在文档注明单数是有意的。

## 5. 建议执行范围(避免过度)
- **必做**:P0(提交去重)→ P1(规范+check)→ P2(文件级改名)。三者风险低、收益确定。
- **可选(改动面大)**:P3 目录小写化。若暂不执行,只需 P1 约定里注明"scenes 子目录暂为 Pascal、待 P3 统一",并保留 check 对该项的告警。
- **不做**:N5(PvP/Pvp)/N6(map)仅文档说明,不改名。

## 6. 验证清单(每阶段出口)
1. `--import` 干净(无 case/hides/parse)。
2. `enemy_logic_smoke.gd` = SMOKE OK;`water_probe` = WATER OK;其余 probe 退出 0。
3. 三个 UI 场景 + Level0 + pvp 相关场景 headless 启动无脚本错误。
4. 编辑器打开关键场景无缺失资源(ext_resource 全部可解析)。

## 7. 目录语义(名字"意义不明")分析与建议

不只大小写,几个目录名**名不副实 / 语义含糊**。逐项:

| 现名 | 语义问题 | 建议 | 理由 |
|---|---|---|---|
| `globals/` | 不是"全局变量":80% 是纯静态助手,夹 2 个 autoload + `tile_defs.json` | `core/` | "共享核心代码"名实相符;json 贴着 loader 保留原位 |
| `scenes/`(根里的 `hud.gd`/`pvp_hud.gd`/`post_process.gd`) | 不是场景,是 HUD 覆盖层/后处理 | 抽 `ui/`(hud、pvp_hud)+ `render/`(post_process) | 语义归位;`scenes/` 只剩可加载场景与实体 |
| `scenes/Enemies|Player|Weapons|Effects` | 语义清楚,大小写不统一 | 全小写 `enemies/player/weapons/effects` | 见 §3/§4 P3 |
| `editor/` | 与 Godot 内置 Editor 撞名,且**一目录塞两样**:浏览器关卡工具(html/js/同步脚本)+ **运行时读的定义/素材**(`enemies.json` 被 `EnemySpawner.load_types()` 读、`structure.png` 副本) | **不合并**。运行时定义挪出(见下),工具本体可更名 `level_editor/` | 工具与运行时数据分离;`level_editor` 注明"浏览器版,与 Godot 编辑器无关" |
| `tools/` | 仅发布/构建自动化(`build_release.py` 等),与 `editor/` **不是一类** | 保留(语义正确),与关卡工具分家 | 构建脚本 ≠ 可视化编辑器 |
| `map/` | 单数 + 混 `old_map.txt`/预览 png | `maps/`(只留 `.cyrm` + 说明) | 复数一致、杂物清走 |
| `server/ tests/ assets/ docs/ shaders/` | 清楚 | 不变 | — |

> 修正:原先建议"editor 并入 tools"**是错的**——两者分别是"构建脚本"与"关卡编辑器 + 运行时定义",语义不同。正确做法是拆,不是并。运行时定义(`enemies.json`、`tile_defs.json`、`structure.png` 副本)不属"编辑器":把 `enemies.json` 等挪到数据/内容层(`data/` 或贴消费代码),工具本体(html/js/sync)单独成目录。

推荐目标形态(小写 + 语义,合一改动,脚本化一次做):

```
assets/  maps/  data/  core/  server/  tests/  docs/  tools/  level_editor/
scenes/            # 玩法实体目录(名可保留)
  enemies/  player/  weapons/  effects/      # 原 Enemies/Player/…,小写
  Level0.tscn  main_menu.tscn  matchmaking.tscn  pvp_game.tscn   # 场景文件保持 Pascal
  level_0.gd  main_menu.gd  matchmaking.gd  pvp_client.gd        # 直属脚本同行
ui/                # hud.gd pvp_hud.gd pvp_hud.tscn
render/            # post_process.gd
data/              # 运行时定义:enemies.json / tile_defs.json(structure.png 进 assets)
level_editor/      # 原 editor/ 的 html + js + sync 工具
```

推荐目标形态(小写 + 语义,合一改动,脚本化一次做):

```
assets/  maps/  core/  server/  tests/  docs/  tools/(含关卡编辑器)  shaders/
scenes/            # 玩法实体目录(名可保留)
  enemies/  player/  weapons/  effects/      # 原 Enemies/Player/…,小写
  Level0.tscn  main_menu.tscn  matchmaking.tscn  pvp_game.tscn   # 场景文件保持 Pascal
  level_0.gd  main_menu.gd  matchmaking.gd  pvp_client.gd        # 直属脚本同行
ui/                # hud.gd pvp_hud.gd pvp_hud.tscn
render/            # post_process.gd
```

关联与顺序:目录语义改名与 §4 P3(scenes 子目录小写)本质是同一类"目录重组",建议合并成一个脚本化阶段(§4 的 P3 改为"目录重组:小写 + 语义")。改名会牵动 `res://` 引用、`enemies.json` 加载路径(`EnemySpawner`→`res://editor/enemies.json`)、tscn ext_resource 与 `.uid`,全部脚本化替换 + 删 `.godot` 重 import + §6 回归验证。

取舍:若只要"名字更有意义"且不想大动,可只做**必改前三项**(globals→core、scenes 系统抽出、editor→tools 合并),保留 scenes 子目录与 map 现状并在文档注明。

