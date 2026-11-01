# UI 组件场景化重构（P1）设计

> 状态：**待评审**（2026-10-27）。评审通过后才写实施计划。
> 上游：P0（标题带规则 / 汉字顶格 / 边距）已按用户裁定落盘（commit `2edb5483`）；本 spec 只覆盖 P1。
> 已拍板（2026-10-27，仓主）：**范围 = D（菜单系 + HUD 全量迁移）**；**验收 = A（分级：菜单系逐像素不变；HUD 同夹具截图 + 关键读数等价）**；**不引任何运行时 UI 框架**。
> 基线：`main` @ `2b2bbcae`；写本 spec 时工作区有他人在飞的 5 个未提交文件（`core/net/net_bus_ext.gd` / `docs/eng/registered-debt.md` / `scenes/pvp_match_client.gd` / `scenes/weapons/bullet_base.gd` / `server/match/match_host.gd`），**均不属本批，开工时不得碰、不得提交**。

## 0. 目标与非目标

**Goal**：把「运行时用 `.gd` 现建 UI」收敛成 **`.tscn` 场景 + 薄脚本 + Theme 变体** 的固定结构，让版式在编辑器里可改、类型/间距/对齐有单一来源；**行为与外观不变**（菜单系逐像素；HUD 关键读数等价）。

**非目标（本轮不做，避免范围蔓延）**
1. 不改玩法 / 协议 / 存档 / 导出配置；不引插件（调研结论见 §3）。
2. 不做视觉重设计：P0 的标题带规则已落地；`docs/archive/audit/2026-10-27-ui/00-总览与结论.md` 里剩下的结构问题（大厅 IP 提示压昵称框、≥5 房卡出屏、长房主名撑破房卡、选图卡出屏、地图卡不填栏、加入弹层无遮罩）**另批**，不混进本次纯结构迁移。
3. 不做全量节点改名：生产 `.tscn` 里 `Label1` / `PanelContainer1` 这种通用名**只在被本次改动触及的节点上**改成语义名（全量改名零行为收益、且逐条对照 `parent=` 路径，风险不成比例）。新组件一律语义名 + `%UinqueName` 作为公开接口。
4. 不把「单 Label 的动态行」硬做成场景（见 §2.1 判定规则）——那是反模式。

## 1. 现状盘点（已核实，2026-10-27）

| 组件 | 位置 | 规模 | 结构现状 | 动态程度 | 迁移价值 |
|---|---|---|---|---|---|
| PauseMenu | `ui/screens/pause_menu.gd` | 73 行 / 4 处 `.new()` | **全代码**（`_init(pvp)` 里建 root/panel/标题带/两颗按钮） | 低（仅 is_pvp 两态文案） | 高（首个样板） |
| StatusBanner | `ui/hud/status_banner.gd` + `.tscn` | 79 / 3 | `.tscn` 只有 CanvasLayer 壳，面板/标签在代码里建并手算居中 | 低（一句文案） | 高 |
| Broadcast | `ui/hud/broadcast.gd` + `.tscn` | 110 / 3 | `.tscn` 空壳，Mask/Center/Panel/标题带/大字/副题全在代码里建 | 中（倒计时/脉冲） | 高 |
| MapPicker | `ui/map_picker.gd` | 101 / 5 | 全代码：标题带 + Scroll + Grid + 卡片（每张卡 4 个子节点）| 卡片 N 张（数据驱动） | 高：拆 `map_card.tscn` |
| RoomList 房卡 | `scenes/mp_lobby/room_list.gd` | 293 / 12 | 每张卡 = Button + frame + col + 卡头 + 卡体（≈15 节点）在代码里拼 | 卡片 N 张 | 高：拆 `room_card.tscn` |
| WaitRoom 名单行 | `scenes/mp_lobby/wait_room.gd` | 165 | 名单行是**单个 Label**（文本格式在 `_roster_row`） | N 行 | 低：保留代码，仅把文本格式集中（见 §2.1） |
| 单人开局面板 | `scenes/main_menu.gd::_fill_sp_panel` + `ui/screens/sp_launch_panel.tscn` | ~60 行 | `.tscn` 是空壳（注释写明内容由代码建），标题带/选图器/禁用武器列/两颗按钮全在代码里 | 低 | 高：填场景 |
| 禁用武器勾选行 | `scenes/main_menu.gd` / `scenes/lobby_page.gd::_add_weapon_grid` | ~25 行 | 逐把枪现建 `CheckButton`（图标是运行时纹理） | N 把 | 中：拆 `weapon_check_row.tscn` |
| Hud（单机 HUD） | `ui/hud/hud.gd` | 362 / 15 | 血条竖段（数量由 `max_hp` 决定）、氧条（宽度由 `max_waterproof` 决定）、左下武器列（背包决定）、击杀计数器（已是 `kill_counter.tscn`） | **高** | 中：静态外壳场景化 + 动态段保留代码 |
| WatchHud | `ui/watch_hud.gd` | 168 / 1 | `_draw()` 画表盘 + 3 个 Label 代码建 | 中（滚动数字/指针） | 中：Label 进场景，表盘绘制留代码 |
| TimeSymbolHud | `ui/time_symbol_hud.gd` | 46 / 1 | 2 个 Label 代码建 | 低 | 高（小） |
| Minimap | `ui/hud/minimap.gd` | 149 / 2 | 圆 + shader 材质 Static，点位动态 N 个 `ColorRect` | 高 | 中：静态圆/描边进场景，点位留代码 |
| RoyaleHud | `ui/hud/royale_hud.gd` + `.tscn` | 171 / 1 | 静态块已在 tscn；排行榜行（Label）按人数建 | 高 | 中：行保留代码（单 Label），样式走 theme |
| PvpHud / TeamHud | 已有 `.tscn` | — | 结构已声明；grace/ping 文案与显隐在代码 | 中 | 低（补 theme 变体即可） |
| 主题 | `tools/gen_menu_theme.gd` → `ui/theme/menu_theme.tres` | 10 个变体 | **只有菜单系**；HUD 底板/武器框/选中态全是代码 `StyleBoxFlat` | — | 必做：补 HUD 变体 |
| UiFactory | `ui/factory/ui_factory.gd` | 356 行 | 调色板 + 样式 + **版式构造器**混在一起 | — | 收缩职责 |

## 2. 目标架构

### 2.1 目录与命名

```
ui/components/          ← 跨屏复用的小部件（本轮新建）
  header_strip.tscn/.gd      标题带（替代 15 条手写 HeaderStrip + 4 处代码调用）
  weapon_check_row.tscn/.gd  禁用武器勾选行（图标/文案/@export type_id）
  room_card.tscn/.gd         大厅房卡
  map_card.tscn/.gd          选图卡
ui/screens/             ← 整页/弹层
  pause_menu.tscn/.gd        （P1 新增，替换纯代码版）
  sp_launch_panel.tscn/.gd   （填壳，内容进场景）
  match_result.tscn           （保持；只把 section 行里的样式换成 theme）
ui/hud/                 ← HUD 专用
  broadcast.tscn/.gd          （填壳，删代码建节点）
  status_banner.tscn/.gd      （从代码搬进场景）
  hud.tscn/.gd                （静态外壳；动态段保留代码）
  weapon_box.tscn             （左下角一张武器框，HUD 动态实例化）
  watch_hud.tscn/.gd / time_symbol_hud.tscn/.gd / minimap.tscn/.gd
```

- 文件一律 snake_case；新脚本 `class_name` = 文件名转 Pascal（`header_strip.gd` → `class_name HeaderStrip`，若与现有主题变体名冲突则用 `HeaderStripPanel`）。新增 `.gd` 连 `.gd.uid` 一起入库；`.tscn.uid` 零跟踪（仓库口径）。
- **判定规则（什么进 .tscn）**：① 整屏 / 弹层；② ≥3 个节点且版式固定的组件；③ 需要被编辑器调参的公共件。**单 Label 的动态行**（名单行 / 排行榜行 / ping 行）不进场景——它们只有文案在变，进场景只会多一层实例化与节点名耦合。

### 2.2 组件契约（所有新组件遵守）

1. `.tscn` 可独立实例化；根节点类型表达语义（`PanelContainer` / `Button` / `CanvasLayer` / `Control`）。
2. 薄脚本只做三件事：**数据绑定、信号转发、运行时样式档切换**（只切 `theme_type_variation`，不写 `Color(...)` 字面量）。版式（锚点/偏移/间距/内边距/尺寸）一律在 `.tscn` 或主题里。
3. 静态可调参数走 `@export`（文案、`centered`、枚举档位、`type_id`）；节点用语义名 + `%UniqueName` 作为组件公开接口。
4. 字体与字号统一走 `UiFactory.style_control()`（16 倍数 assert 仍在）或 theme variation；调色板仍只从 `UiFactory.C_*` 取。
5. 组件脚本 >100 行时注释 ≤15%（仓库额度），历史理由搬到 `docs/eng/ui.md`，脚本留一句指针。

### 2.3 主题层扩展（`tools/gen_menu_theme.gd` → `menu_theme.tres`）

新增 HUD 变体（值全部来自现有 `UiFactory.C_*`，不新增颜色）：

| 变体 | 类型 | 取值 | 替代现在的代码写法 |
|---|---|---|---|
| `HudPlate` | PanelContainer | `C_PLATE`(黑 0.1) + 8/6 内边距 | HUD 各底板 `StyleBoxFlat` |
| `HudPlateBoard` | PanelContainer | 黑 0.25（大乱斗排行榜例外） | `royale_hud._board_bg` |
| `HudPlateNoFill` | PanelContainer | `C_PLATE` + `draw_center=false` + 16/6 | 击杀计数器外框、武器区外框 |
| `HudWeaponBox` | PanelContainer | 全透明 + 8/4 | 武器框未选中态 |
| `HudWeaponBoxSel` | PanelContainer | 黑 0.28 + 8/4 | 武器框选中态 |
| `HudAccentText` / `HudText` / `HudDimText` | Label | `C_ACCENT` / `C_TEXT` / `C_TEXT_DIM` + 字号 32 | HUD 里 `add_theme_color_override` 的散落写法 |
| `CardHeader` | PanelContainer | `C_HEADER` + 下边线 `C_BORDER` + 左右 0 / 上下 12 | `room_list._card_header` 的第二份字面量 |
| `RoomCard` | Button | `C_SURFACE` + 1px `C_BORDER`，hover/focus `C_ACCENT` | `_style_card` |
| `MapCardOff` / `MapCardOn` | PanelContainer | `row_box()` / 青描边选中态 | `map_picker._style_off/_style_on` |

- 生成器仍是唯一来源；`.tres` 是生成物。**改变体必须重跑 `gen_menu_theme.gd`**（写进 `docs/eng/ui.md`）。
- 主题变体仍是「外观」的唯一声明地：`HeaderStrip` 保持左右 24 / 上下 20（P0 规则）；`header_strip.tscn` 组件只负责 text/size/centered 三个参数，不再自带内边距值 ⇒ P0 留下的「工厂与主题两份值」债在 Phase 0 消失。

### 2.4 UiFactory 收缩

- **保留**：调色板常量、`style_control()`、`pixel_font()`、`fit_name()`、以及给「动态样式必须由代码算」的少数函数（`_row_sb` / `style_row_button` / `style_check` / `style_slider` 等仍被动态列表使用）。
- **迁移后删除**（Phase 5，判据 = `grep` 零调用）：`header_strip()`、`menu_panel()`、`skin_menu_panel()`、`menu_button()`、`label()`、`panel_box()`、`row_box()`、`style_line_edit()`、`style_button()` 中已被 theme 变体替代的部分。
- 禁止新增 `Control.new()` 构造器（HUD 动态段除外，见 §2.5）。

### 2.5 HUD 的特殊边界（照实登记）

有些 HUD 元素**由玩家数值决定形状**，改成场景就会改像素数学 ⇒ 本轮保留代码构造，只把「外壳/静态部分」场景化：

- 血条竖段：数量 = `max_hp`，逐段 x 位置按 `SEG_W/SEG_GAP` 算 → 保留代码（`_build_segments`）。
- 氧条：宽度 = `WATERPROOF_W * max_waterproof` → 保留代码（`_build_waterproof`）。
- 武器框列表：数量 = 背包把数，每框 5 节点 → **场景模板 `weapon_box.tscn` + 代码实例化/填值**（这是本轮唯一进 .tscn 的动态列表）。
- 小地图点位 / 排行榜行 / ping 行 / 名单行：单点或单 Label → 保留代码。
- 其余静态外壳（击杀计数器、怀表、时间符号、左上底板、右下延迟条、任务提示）进 `.tscn`。
- `hud.tscn` 的加载方式不变：`level_0.tscn` 的 HUD 节点仍挂 `hud.gd`（场景根换成 `.tscn` 后由 `level_0.tscn` 直接实例化）。

## 3. 方案对比（为什么是 A）

| 方案 | 做法 | 优点 | 代价/结论 |
|---|---|---|---|
| **A. 场景化 + 薄脚本 + theme 变体（推荐）** | `.tscn` 承载结构与版式；脚本只绑数据/信号；外观进主题生成器 | 编辑器里可改版式；版式单一来源；与仓库既有「主题是生成物 / 调色板单一来源」纪律同向；无新依赖 | 一次性搬迁工作量大；需要逐组件像素对比证明不变 |
| B. 只抽组件类，不建 `.tscn` | 把 `new()` 封装成 `SomeWidget.create()` | 改动小 | **不解决用户诉求**：版式仍在代码里，编辑器看不到 |
| C. 引第三方 UI 框架/插件 | 见 2026-10-27 调研（ThemeGen / Maaack / ProperUI / Theme Editor Extension…） | 部分能省编辑器操作 | 运行时框架与「调色板单一来源 / 导出裁剪 / 零 addons」冲突；美术主题配色不符；无一个能接管我们的 theme。**裁定：不引运行时框架**；编辑器侧工具另议，不进本 spec |

## 4. 分阶段实施（每阶段独立提交、独立回滚）

> 每阶段完成 = 该阶段证据归档 + 逐文件 `git add` + 一个独立 commit。阶段顺序保证「先基建 → 再样板 → 再批量」。

### Phase 0 — 基建（档 1）
1. 建 `ui/components/`；把 `header_strip.tscn` + `.gd` 落地（`@export title/centered/size`）。
2. 15 条 `.tscn` 的 `HeaderStrip` + 4 处代码调用换成该组件；删掉 15 条手写 `horizontal_alignment` 与对 `HeaderStrip` 变体内边距的依赖说明。
3. `gen_menu_theme.gd` 增加 §2.3 的 HUD 变体（先生成、先不消费）；重跑生成器 + `--import`。
4. 取图/对比夹具：把 P0 归档里的 `_drivers/ui_audit_shots.gd` 扩成「按屏取图 + 前后逐像素 diff」一次性脚本（放 `.superpowers/sdd/_gen/`，gitignored）。
   **验收**：15 条标题带所在 12 屏 before/after 逐像素 diff = 0；`check_naming` OK。

### Phase 1 — 样板：PauseMenu（档 1）
1. `ui/screens/pause_menu.tscn`（CanvasLayer，layer 145 / `process_mode=ALWAYS` 进场景；根 Control + 压暗罩 + 居中面板 + 标题带 + 两颗按钮）。
2. `pause_menu.gd` 只留：`is_pvp`（改为 `@export`/实例化后赋值）、`toggled` 信号、`toggle/open/close/go_menu`、`_unhandled_input`。
3. **API 变更**：`PauseMenu.new(false)` → `preload(...).instantiate()` + `is_pvp = false`（调用点 4 处：`level_0.gd:620`、`pvp_game.gd:82`、`royale_game.gd:82`、`team_game.gd:67`；`pvp_match_client.gd:44` 只是类型声明，赋值在子类）。
   **验收**：单机暂停 / PvP 菜单两态的 before/after 逐像素 = 0；Esc 开合与「回到主菜单」行为不变（`menu_autotest` 的 sp 流程跑一次人眼确认）。

### Phase 2 — HUD（档 2：单子系统、行为不变）
1. `weapon_box.tscn` + `hud.gd` 武器区改用该模板（保留 `_refresh_weapon_boxes` 的排序/选中逻辑）。
2. `watch_hud.tscn` / `time_symbol_hud.tscn`：Label/底板进场景，`_draw` 表盘与数字滚动留脚本。
3. `hud.tscn`：静态外壳 + 击杀计数器（`kill_counter.tscn` 实例）+ 怀表/时间符号挂载点；血条段/氧条保留代码（§2.5）。
4. `minimap.tscn`：圆 + shader 材质 + 外描边进场景；点位仍代码。
5. `broadcast.tscn` / `status_banner.tscn`：删代码建节点，改场景声明（见 Phase 3 亦可；按依赖顺序放在 Phase 2 末）。
6. `pvp_hud.tscn` / `team_hud.tscn` / `royale_hud.tscn`：把代码里剩下的 `add_theme_*` 散写换成 `Hud*` 变体。
   **验收**（用户已拍板 A）：HUD 夹具（黑底、固定假玩家/背包/血量/时间、固定帧号）截图，HUD 区域逐像素 diff = 0；读数 json 完全相等（节点 rect/文本/数量）。
   档 2 额外要求：为「武器框数量 / 血条段数 / 排行榜行数」挑**一条**做变异验证（改坏 → 断言红）。

### Phase 3 — 菜单组件（档 1）
1. `sp_launch_panel.tscn`：标题带（组件）/地图选择器/禁用武器列/两颗按钮全部进场景；`main_menu.gd::_fill_sp_panel` 缩成「接信号 + 读数」。
2. `weapon_check_row.tscn`：勾选行（CheckButton + 运行时图标 + 文案），两处调用点（单人面板 / 建房弹层）共用。
3. `map_picker.tscn` + `map_card.tscn`：`setup()` 只负责按 `MapCatalog` 填卡与选中态；保留 `selected` / `select_path` / `picked` / `_cards`。
4. `room_card.tscn`：房卡进场景（卡头用 `CardHeader` 变体、卡体三段）；`room_list.gd` 只填名字/人数/角标/禁用态。
   **验收**：`main_sp_panel` / `lobby_create_*` / `lobby_join` / `wait_*` / `lobby_rooms` 逐像素 diff = 0。

### Phase 4 — 大厅骨架收口（档 1）
1. 等待室/建房/加入面板：被本次触及的通用节点名改成语义名（**只改触及的**，见非目标 3）；`WaitRoom` 名单行文本格式集中到一个函数（不建场景）。
2. 保留 `MpLobby` 的 `_grid/_wait_body/_wait_count/_wait_start` 字段与 `MapPicker._cards`（`tests/harness/*_watcher.gd` / `menu_autotest.gd` 读取点）。
   **验收**：同 Phase 3；`grep` 确认 watcher 读点未变。

### Phase 5 — 收尾（档 1）
1. 删死工厂（`grep` 零调用后逐个删）；`UiFactory` 注释更新为「调色板 + token + 动态样式」。
2. `docs/eng/ui.md` 更新：组件目录、契约、什么进 .tscn、HUD 边界（§2.5）、主题变体表。
3. 全屏取图复核（29 状态）；`python tools/check_naming.py`；`bash tests/run_all.sh` 前后同一绿基线；headless boot 冒烟。
   **验收**：无回归 + 文档同步完成。

**工期估算**（单会话）：Phase0 ≈ 0.5d / Phase1 ≈ 0.5d / Phase2 ≈ 2d / Phase3 ≈ 1.5d / Phase4 ≈ 1d / Phase5 ≈ 0.5d，合计 ≈ 6 个工作日。

## 5. 验收与证据（用户拍板的 A 口径）

| 类别 | 判据 | 证据归档 |
|---|---|---|
| 菜单系 / 整屏 / 弹层 | **逐像素 diff = 0**（fixture 固定：钉服务器地址、固定设置、关背景动画；`Image.diff` 统计变化像素数） | `docs/archive/audit/2026-10-27-ui/p1/phaseN/`：before/after PNG + diff 数字 |
| HUD | **同夹具截图 + 读数 json 完全相等**（黑底独立实例化，不依赖随机世界）：血条段数/rect、武器框数量/rect/文本、击杀计数、排行榜行数、怀表文本、延迟条 rect | 同上：PNG + `readouts.json` |
| 回归 | `bash tests/run_all.sh` 绿基线（headless 默认批；跑前后各一次，判据 grep 文本）；`python tools/check_naming.py`；headless boot 冒烟 | 日志片段写进阶段报告 |
| 真链路 | `rejoin/team_match` watcher 需要 7777 ⇒ **不在本批自动跑**；开工前问用户是否认领。契约靠 `grep` 静态核对 + 真链路留到用户跑 |

- **不新增永久守卫**：纯结构重构、无新逻辑；能写的守卫都会落进仓库「不写清单」（同源重复 / 读源码判形态 / 观感类）。档 2 的 HUD 阶段按仓库要求做**一条**承重断言的变异验证（例如「武器框数 == 背包把数」），验证完按既有口径登记（注释写清最强保证与测不到什么）。
- 每次 commit 前：`git status --short` + 逐文件 `git diff` 认领 hunk；**绝不 `git add -A`**；不碰他人在飞的 5 个文件。

## 6. 不可破坏的公开契约（清单）

- `MpLobby`：字段 `_grid` / `_wait_body` / `_wait_count` / `_wait_start`（`tests/harness/rejoin_watcher.gd:298`、`team_match_watcher.gd:320,377,380,443` 用 `.get()` 读）。
- `MapPicker`：`selected`、`select_path(path, from_click)`、`picked` 信号、`_cards`（`tests/harness/menu_autotest.gd:94` 读 `picker._cards`）。
- `PauseMenu`：`toggled(open)` 信号、`open/close/toggle/go_menu`、`is_pvp`；调用点 `level_0.gd:620` / `pvp_game.gd:82` / `royale_game.gd:82` / `team_game.gd`。
- `Broadcast`：`set_broadcast` / `start_countdown` / `stop_countdown` / `is_counting` / `tick` / `countdown_finished` 信号；公有字段 `big` / `sub` / `mask`（三个 HUD 读）。
- `StatusBanner.set_text(text)`；场景路径 `res://ui/hud/status_banner.tscn`（`pvp_match_client.gd:790` preload）。
- `Hud`（`level_0.tscn` 挂 `hud.gd`）、`PvpHud`（`pvp_game.gd:76` preload）、`TeamHud`、`RoyaleHud`（`royale_game.gd:79` preload，注释写明**不可 `.new()`**）、`Minimap.setup/setup_multi`、`WatchHud.build_dial_texture/absorb/tremble/flash_locked`（`beta_menu.gd:71` 等）、`TimeSymbolHud`。
- 场景内被代码取名的节点：`kill_counter.tscn` 的 `KillLabel`（`hud.gd`）、`pvp_hud.tscn` 的 `ScoreWrap/ScoreLabel`、`PingWrap/PingLabel`、`GraceWrap/GraceLabel`、`team_hud.tscn` 同款、`match_result.tscn` 的 `$Root/Panel/Body/VBox/...`（`match_result.gd` 的 `@onready`）。
- 15 条 `%UniqueName` 的语义（`%NameEdit` / `%CardGrid` / `%WaitPanel` / `%BindGrid` …）不变量：(1) 存在；(2) 类型不变；(3) 所属组件职责不变。

## 7. 风险与边界

1. **共用工作树**：写 spec 时已有他人 5 个未提交文件；P1 开工前再查一次 `git status`，若 UI 侧出现他人改动 ⇒ 先协调再动。
2. **主题镜像无守卫**：`UiFactory` 与 `gen_menu_theme` 是两份值；Phase 0 后标题带不再来自工厂，此风险减半；其余样式仍靠「改一处必须改两处」的人工纪律（写进 `docs/eng/ui.md`）。
3. **HUD 动态段**：血条段/氧条宽度若场景化会改像素数学 ⇒ 本轮保留代码（§2.5 已登记）。**测不到**：`hud.gd` 的段数/宽度在极端数值（满血 5000 / 0 氧）下的行为仍无自动守卫。
4. **像素对比的局限**：fixture 能覆盖静态布局与文案，覆盖不了真机时序（倒计时 tween、击杀播报淡出）。这些靠人眼抽查 + 现有 `menu_autotest`。
5. **注释额度**：迁移后脚本变薄，>100 行脚本注释可能超 15% ⇒ 历史理由搬 `docs/eng/ui.md`。
6. **导出裁剪**：只用内建 Control/Theme，无新模块、无 addons；`.tscn` 增加不影响裁剪。
7. **性能**：场景实例化发生在进入菜单/对局时一次；HUD 动态段构造路径不变。无可测回归。
8. **回滚**：每 Phase 一个 commit，坏一处 `git revert <phase-commit>` 即可；无数据/协议迁移。

## 8. 本 spec 的决策记录（评审时请重点看）

| # | 决策 | 理由 |
|---|---|---|
| D1 | `header_strip` 做成组件场景，删掉工厂构造器 | 一举消掉「15 条手写 + 工厂 + 主题镜像」三份来源，且 title 可在编辑器改 |
| D2 | HUD 变体进 `gen_menu_theme.gd`（生成器改名不改文件名） | 保持「主题是生成物」纪律；文件名改动会牵连文档与工具头，收益为零 |
| D3 | PauseMenu API 改为 `instantiate()` + `is_pvp` 赋值 | CanvasLayer 场景根不能带 `_init` 参数；4 个调用点一次性改，行为不变 |
| D4 | 单 Label 动态行不进场景 | 反模式；只会增加实例化与节点名耦合，无版式收益 |
| D5 | 血条段 / 氧条宽度保留代码构造 | 形状由玩家数值决定，场景化会改像素数学 ⇒ 违反「外观不变」验收 |
| D6 | 不做全量节点改名 | 零行为收益、`parent=` 路径风险大；只改被触及节点 + 新组件强制语义名 |
| D7 | 不新增永久守卫，证据用一次性像素/读数对比 + 既有测试绿基线 | 纯重构无新逻辑；守卫会进「不写清单」，而 HUD 动态段的一次性读数可作档 2 变异验证 |
| D8 | Phase 4 不跑真链路 watcher | 占 7777；按仓库纪律需用户认领/批准，写进阶段报告让用户决定 |
