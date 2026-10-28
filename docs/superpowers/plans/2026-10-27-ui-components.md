# UI 组件场景化重构（P1）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **写于 2026-10-27**（用户已批准 spec `docs/superpowers/specs/2026-10-27-ui-components-design.md`）。
> ★ **执行方式**：本计划按仓库档位执行（Phase 0/1/3/4/5 = 档 1 纯表现；Phase 2 = 档 2 单子系统），**不逐任务评审**，最后整体评审 + 全量复核。若用户改选 subagent-driven，则每任务加一次独立 review。
> ★ **开工前置（硬）**：并行会话的未提交工作先由本会话替其提交（见 §0 Prereq）；然后 `git status` 必须只剩本计划自己的改动。共用工作树纪律：**逐个文件 `git add`、逐 hunk 认领**，绝不 `git add -A`。

**Goal:** 把「运行时用 `.gd` 现建 UI」收成 `.tscn` 场景 + 薄脚本 + Theme 变体，让版式在编辑器可改且有单一来源；行为与外观不变（菜单系逐像素不变；HUD 同夹具截图 + 关键读数等价）。

**Architecture:** 新建 `ui/components/` 放跨屏部件；整屏/弹层进 `ui/screens/`，HUD 专用进 `ui/hud/`。`.tscn` 承载结构与版式，脚本只绑数据/信号/切 theme variation；HUD 底板/武器框/文字档等新增为 `tools/gen_menu_theme.gd` 生成的 Theme 变体（颜色全部来自 `UiFactory.C_*`）。UiFactory 收缩为「调色板 + token + 动态样式」，Phase 5 删掉零调用的构造器。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）/ GDScript / `.tscn` 场景 / 生成式 Theme。

**Spec:** [`docs/superpowers/specs/2026-10-27-ui-components-design.md`](../specs/2026-10-27-ui-components-design.md)（执行者两篇都读）

## Global Constraints

- **行为零变化**：不改玩法/协议/存档/导出配置；不动 `core/`、`server/`、`net*`。本批只碰 `ui/`、`scenes/{main_menu,settings_menu,info_menu,beta_menu,mp_lobby}*`、`tools/gen_menu_theme.gd`、`docs/eng/ui.md`。
- **调色板单一来源**：颜色只从 `UiFactory.C_*` 取；`.tscn` 不新增 `Color(...)` 字面量（现有 tscn 里的历史字面量不动，除非本任务把它换成 theme variation）。
- **字号 16 倍数**：一律经 `UiFactory.style_control()`（内置 assert）或 theme 变体。
- **主题是生成物**：改 `tools/gen_menu_theme.gd` 后必须 `"$GODOT" --headless --path . -s res://tools/gen_menu_theme.gd` + `--import`，不手改 `menu_theme.tres`。
- **不可破坏的契约**（spec §6）：`MpLobby._grid/_wait_body/_wait_count/_wait_start`、`MapPicker.selected/select_path/picked/_cards`、`PauseMenu.toggled/open/close/toggle/go_menu/is_pvp`、`Broadcast.set_broadcast/start_countdown/stop_countdown/is_counting/tick/big/sub/mask`、`StatusBanner.set_text`、`Minimap.setup/setup_multi`、`WatchHud.build_dial_texture`、`TimeSymbolHud`、各场景路径、`%UniqueName` 集合。
- **判据一律 grep 判词文本**（`GEN THEME: OK` / `AUTOTEST[...]: DONE` / `RUN_ALL …` / `ALL-OK`），退出码不作判据。
- **取图/量几何必须带窗口**（`--headless` 下视口纹理是空壳）；量几何的 dump 脚本要选出一条**只依赖布局**的路径（headless 可跑）。
- **不新增永久守卫**；Phase 2 按档 2 做**一条**承重断言变异验证（武器框数 = 背包把数）。
- **证据归档**：`docs/audit/2026-10-27-ui/p1/<phase>/`（before/after PNG + diff 数字 + 读数 json），与代码同 commit。
- **真链路不跑**：需要 7777 的 `rejoin/team_match` watcher 本批不跑（spec D8），只在报告里写「未跑 + 理由」。
- **共享工作树**：开工前 `git status` 确认只含本任务文件；发现他人改动立即停下报告。

## Review Focus

1. **HUD 半透明底板**：`C_PLATE`(黑 0.1) 类底板在浅蓝地图上的对比度——像素对比夹具会把地图隐藏，**能过像素门但可能掩盖观感退化**；每个 HUD 任务完成后必须在真 `level_0/pvp_game` 里人眼看一眼（本计划每个 HUD 任务都带这条）。
2. **数据绑定初值时序**：HUD/面板场景化后节点在 `_ready` 前已存在，但 `group("player")`、`Settings`、`PvpSession` 的读取时机不能变；若变，首帧会出现空血条/空武器框/错文案。Covers: T6/T8/T12 的「同夹具首帧读数」。
3. **节点/unique name 改名**：`%NameEdit` 等被代码 `get_node("%…")` 或测试 `.get("_…")` 读取；改名/搬到子场景会静默拿 null。Covers: T3/T16 的 grep 契约清单 + 每个改到的场景跑一次 headless 实例化 dump（能取到全部 `%` 节点）。
4. **主题变体漂移**：生成器与工厂是两份值且无守卫；新变体值必须逐项抄自现有代码/tscn。Covers: 每个加变体的任务都带「生成后取图 diff=0」。
5. **输入路径只吃一次**：暂停菜单进场景后 `process_mode=ALWAYS`、Esc `set_input_as_handled` 的顺序不能变，否则双触发（暂停又立即恢复）。Covers: T4 的 `--autotest-sp` Esc 断言。

---

## 0. Prereq：替并行会话提交 + 开工检查（人工步骤，非 checkbox）

1. 等对方任务静默（无 Godot 进程 + `git status` 连续 3 分钟不变）。
2. 只看对方文件：`git status --short` → 逐个 `git diff -- <file>` 认领 → 推断 scope 写一句 `type(scope): 中文一句话` → **逐个文件** `git add` → commit。
3. `git status --short` 必须为空；`git log --oneline -2` 记下新 HEAD 作为 P1 基线。
4. 若静默后 `git status` 已空（对方自己提交了）：记录 HEAD，跳过 commit。

---

## Phase 0 — 基建（档 1）

### Task 1: 取图/对比基建 + 迁移前基线

**Files:**
- Create: `.superpowers/sdd/_gen/p1_shots.gd`、`.superpowers/sdd/_gen/p1_shots.tscn`、`.superpowers/sdd/_gen/p1_diff.py`（整目录 gitignored，只作一次性量具）
- Create: `docs/audit/2026-10-27-ui/p1/phase0/before/*.png`（入库证据）

**Interfaces:**
- 产出：`p1_shots.gd` 约定 `-- <输出子目录>`；固定 14 个镜头：`settings_top` / `info_top` / `beta_menu` / `main_sp_panel` / `lobby_empty` / `lobby_rooms` / `lobby_create_pvp` / `lobby_create_team` / `lobby_create_royale` / `lobby_join` / `wait_pvp` / `wait_royale` / `wait_team` / `pause_menu`。
- `p1_diff.py <before_dir> <after_dir>` → 逐图打印 `changed_px` 与总 `mean_abs`；`changed_px > 0` 时列出差异图（`diff_<name>.png`）。

- [ ] **Step 1: 写取图驱动**，复用 `docs/audit/2026-10-27-ui/_drivers/ui_audit_shots.gd` 的流程（同 `add_child` + `_save`），但**固定夹具**：`PvpSession.server_address = "127.0.0.1"`；大厅状态栏文本由夹具直接灌死（`lobby.get("_status").text = "夹具"`），避免「连接中/超时/共 N 个房间」时序抖动；`pause_menu` 用 `level_0.tscn` + `PauseMenu` 打开态。
- [ ] **Step 2: 跑两遍，证明夹具确定**。命令（窗口模式，不要 `--headless`）：
      `"$GODOT" --path . --quit-after 3600 res://.superpowers/sdd/_gen/p1_shots.tscn -- docs/audit/2026-10-27-ui/p1/phase0/before`
      跑两次到 `before/` 与临时 `before2/`，`python .superpowers/sdd/_gen/p1_diff.py before before2`，期望 **changed_px = 0**。若不为 0，逐个镜头找随机源并钉死（设置/地址/随机地图/随机房间数据），直到 0。
- [ ] **Step 3: 生成正式基线**，存档到 `phase0/before/`，commit。
- [ ] **Step 4: Commit**：`git add docs/audit/2026-10-27-ui/p1/phase0/before` + `git commit -m "test(ui): P1 迁移前基线截图(逐像素对比夹具)"`

### Task 2: `header_strip_panel` 组件

**Files:**
- Create: `ui/components/header_strip_panel.gd`、`ui/components/header_strip_panel.tscn`
- Test（一次性 scratch）: `.superpowers/sdd/_gen/p1_strip_probe.gd/.tscn`

**Interfaces:**
- `class_name HeaderStripPanel extends PanelContainer`
- `@export var title: String = ""`；`@export var centered := false`；`@export var title_size := 32`
- `func apply(title_text: String, size: int, center: bool) -> void`（给代码调用点）
- 场景结构：根 `PanelContainer`（`theme_type_variation = &"HeaderStrip"`，`mouse_filter` 默认 STOP）→ 子 `Label` 名 `Title`（`theme_type_variation = &"HeaderTitle"`，`mouse_filter = 2`，`unique_name_in_owner = true`）。

- [ ] **Step 1: 先写量具断言**（scratch probe）：用 `UiFactory.header_strip("测试标题", 32, false)`（旧实现）与 `load("res://ui/components/header_strip_panel.tscn").instantiate()`（新组件，`apply("测试标题",32,false)`）分别入树，打印两者的 `get_combined_minimum_size()`、Label 的 `font_size`/`horizontal_alignment`/`font_color`。期望新组件缺失 → 脚本报 FAIL。
- [ ] **Step 2: 建组件**：脚本 `_ready()` 里 `%Title.text = title`、`%Title.horizontal_alignment = CENTER if centered else LEFT`、`UiFactory.style_control(%Title, title_size)`；`apply()` 同时支持运行时改。场景里**不写字号/颜色覆盖**（走 `HeaderTitle` 变体：32 号、`C_GOLD`）。
- [ ] **Step 3: 跑 probe**，期望两组读数逐项相等（min size / font_size / alignment / font_color）；不相等则按旧实现校正组件。
- [ ] **Step 4: Commit**：`git add ui/components/header_strip_panel.gd ui/components/header_strip_panel.gd.uid ui/components/header_strip_panel.tscn` + `git commit -m "feat(ui): 抽 HeaderStripPanel 组件(标题带单一来源)"`

### Task 3: 迁移 15 条 `.tscn` 标题带 + 4 处代码调用

**Files:**
- Modify: `scenes/settings_menu.tscn`（6 条）、`scenes/info_menu.tscn`（4 条）、`scenes/beta_menu.tscn`（1 条）、`scenes/mp_lobby.tscn`（4 条）
- Modify: `scenes/main_menu.gd`（2 处 `header_strip`）、`scenes/beta_menu.gd`（1 处）、`ui/map_picker.gd`（1 处）
- 不动的调用点（各自阶段再迁）：`ui/screens/pause_menu.gd`（T4）、`ui/hud/broadcast.gd`（T9）、`ui/screens/match_result.gd`（保持工厂到 Phase 5 再定）

**Interfaces:**
- 每条旧 `[node HeaderStrip PanelContainer] + [node Label]` 两节点，替换为**一个实例节点**：`[node name="Header" parent="<原父>" instance=ExtResource("<新 ext id>")]`，属性只写非默认：页首/弹层标题 `title = "<原文案>"`、`title_size = 48`（仅页首）; 分区标题 `title = "<原文案>"`（`centered` 默认 false 不写）。
- 代码侧：`MapPicker.setup()` 里 `add_child(header_strip(title, 32))` → `var h := HeaderStripPanel` 场景实例 + `h.apply(title, 32, false)`。

- [ ] **Step 1: 逐个改 4 个 tscn**（每次一个文件，改完 headless 实例化确认无 `SCRIPT ERROR`）。
- [ ] **Step 2: 改 3 个 `.gd` 调用点**（main_menu ×2：`"—— 单人开局 ——",48,true` / `"禁用武器(勾选 = 本局不可用)",32,false`；beta_menu ×1 `centered=true`；map_picker ×1 `false`）。
- [ ] **Step 3: 几何复核**：跑 Task 2 的 probe 扩展到「实例化整个场景后遍历 HeaderStripPanel」：期望 15 个组件全部左/右内边距 24，页首 6 条 `alignment=CENTER`、分区 9 条 `LEFT`。
- [ ] **Step 4: 取图 diff**：`p1_shots` 跑 after，`python p1_diff.py phase0/before <after>`，期望 **changed_px = 0**（14 镜头全 0）；若非 0 停在第一个不为 0 的镜头查原因。
- [ ] **Step 5: Commit**：逐个 add 4 tscn + 3 gd + `docs/audit/2026-10-27-ui/p1/phase0/after` + `p1_diff.txt`，`git commit -m "refactor(ui): 15 条标题带 + 4 处代码调用改用 HeaderStripPanel"`

---

## Phase 1 — 样板：PauseMenu（档 1）

### Task 4: `pause_menu.tscn` + 调用点改造

**Files:**
- Create: `ui/screens/pause_menu.tscn`
- Rewrite: `ui/screens/pause_menu.gd`
- Modify: `tools/gen_menu_theme.gd`（新增 `PanelCarvedBodyInset72` 变体）、`ui/theme/menu_theme.tres`（生成物）
- Modify 调用点：`scenes/level_0.gd:620`、`scenes/pvp_game.gd:82`、`scenes/royale_game.gd:82`、`scenes/team_game.gd:67`
- 证据: `docs/audit/2026-10-27-ui/p1/phase1/`

**Interfaces:**
- 场景：`CanvasLayer`(layer=145，`process_mode=3`) → `Root Control`(full rect, visible=false) → `Dim ColorRect`(0,0,0,0.55) + `Center CenterContainer` → `Panel PanelContainer`(`PanelCarved`) → `Body PanelContainer`(`PanelCarvedBodyInset72`) → `VBox`(sep 28) → `Header HeaderStripPanel`(`title_size=64`,`centered=true`) + `Resume Button`(`BtnGold`, min 480×72) + `Back Button`(`BtnQuiet`, min 480×72)。
- 脚本：删掉 `_init`/`_ready` 里建节点的全部代码；`is_pvp` 仍是 `var`（场景实例化后、`add_child` 前由宿主赋值）；`_ready` 里按 `is_pvp` 设 Header 文案 + `Root.visible=false`；`apply` 顺序、信号、`open/close/toggle/go_menu`、`_unhandled_input` 原样保留。
- 调用点：`PauseMenu.new(false)` → `(preload("res://ui/screens/pause_menu.tscn") as PackedScene).instantiate() as PauseMenu`，随后 `is_pvp = false/true`，再 `add_child`。
- `PanelCarvedBodyInset72`：在 `gen_menu_theme.gd` 的 `_panel_variants()` 里复制 `PanelCarvedBody` 的全部属性（bg 透明、1px `C_INNER` 边框、不设 content_margin 的那条纪律见原注释），只把 content margins 改成 **72/44**（值抄自 `UiFactory.menu_panel(Vector2(72,44))` 的实现，执行前先读源码核对）。

- [ ] **Step 1: 取 before 证据**：`p1_shots` 增加两个镜头并在旧代码上跑一遍：`pause_sp`（level_0 + `PauseMenu` 打开）与 `pause_pvp`（pvp_game + `_pause_menu.open()`）→ `phase1/before/`。
- [ ] **Step 2: 加 theme 变体 + 重跑生成器**：`grep "GEN THEME: OK"` 判据；`--import`。
- [ ] **Step 3: 写场景 + 重写脚本**（只留行为）；headless 实例化场景确认无 ERROR、`%` 节点可取。
- [ ] **Step 4: 改 4 个调用点**；`grep -n "PauseMenu.new"` 必须为空。
- [ ] **Step 5: 行为验证**：`"$GODOT" --headless --path . --quit-after 3600 -- --autotest-sp`，grep 判据：`AUTOTEST: Esc后 paused= true`、`再Esc后 paused= false`、`AUTOTEST[sp]: DONE`。
- [ ] **Step 6: 像素验证**：after 取图，diff 期望 0（`pause_sp` / `pause_pvp` 两张）。
- [ ] **Step 7: Commit**：`git commit -m "refactor(ui): 暂停菜单场景化(去掉 _init/_ready 现建节点)"`

---

## Phase 2 — HUD（档 2：单子系统、行为不变）

> 每个 HUD 任务都含：**同夹具截图 diff = 0 + 读数 json 全等 + 真场景人眼一眼**（Review Focus 1）。

### Task 5: HUD 夹具 + 迁移前基线

**Files:**
- Create（scratch）: `.superpowers/sdd/_gen/p1_hud.gd/.tscn`、`.superpowers/sdd/_gen/p1_hud_readouts.gd`（读节点 rect/文本）
- Create: `docs/audit/2026-10-27-ui/p1/phase2/before/`（PNG + `readouts.json`）

**Interfaces:**
- 夹具固定：`MazeGenerator.set_map_file("res://maps/newfactory.cyrm")` + `GameParameters.refresh_map_size()`（钉死地图与尺寸）；实例化 `level_0.tscn`，等 30 帧，隐藏 `WorldViewport` 与 PostProcess（HUD 半透明底板后面统一成纯背景）；固定玩家状态：满血、背包 3 把（手枪/步枪/霰弹）、氧满；截图 `hud_full`，再改状态：低血(25%)、背包 1 把、氧半，截图 `hud_low`。
- 读数：对所有 HUD 相关可见节点打印 `name|global_rect|text`（按名字排序）到 `readouts.json`。

- [ ] **Step 1: 写夹具**；跑两遍 diff 证明确定（同 Task 1 方法）。
- [ ] **Step 2: 产出 `phase2/before/`（2 PNG + readouts.json），commit。**

### Task 6: `weapon_box.tscn` + `hud.gd` 武器区

**Files:**
- Create: `ui/hud/weapon_box.tscn`（+ 薄脚本 `ui/hud/weapon_box.gd`，`class_name WeaponBox`）
- Modify: `ui/hud/hud.gd`（`_refresh_weapon_boxes` 改为实例化模板；其余排序/选中逻辑不动）
- Modify: `tools/gen_menu_theme.gd`（新增 `HudWeaponBox` / `HudWeaponBoxSel` 变体）

**Interfaces:**
- `WeaponBox.apply(index:int, selected:bool, icon:Texture2D, weapon_name:String, ammo_text:String) -> void`
- 节点：`%Row`(HBox, sep 14) 里 `%KeyLabel`(min 48, center, 32号) / `%Icon`(TextureRect) / `%Info`(VBox, sep 2) 里 `%NameLabel` / `%AmmoLabel`；根 `PanelContainer`(min 宽 320，`size_flags_horizontal=SHRINK_BEGIN`)，未选中时 `%Info.visible=false`、Icon min 58×36、`modulate=(0.45,0.45,0.50,1)`，选中时 72×46、modulate 白、换 `HudWeaponBoxSel` 变体。
- 数值全部来自现 `hud.gd` 的既有常量（执行前逐项抄，不准目测）。

- [ ] **Step 1: 改前夹具读数**（Task 5 已存）。**Step 2:** 建场景/脚本 + 两个 theme 变体（值抄现有 `bs.bg_color = Color(0,0,0,0.28) if sel else ...` → 变体 bg；内容边距 8/4）。**Step 3:** 改 `hud.gd` 实例化逻辑。**Step 4:** 夹具 after 跑 diff + 读数比对，期望 0 差异。**Step 5:** 真 `level_0` 人眼一眼（浅色地图上武器框可读）。**Step 6: Commit。**

### Task 7: `watch_hud.tscn` / `time_symbol_hud.tscn`

**Files:** Create: `ui/hud/watch_hud.tscn`、`ui/time_symbol_hud.tscn`（+ 对应薄脚本改造）；Modify: `ui/hud/watch_hud.gd`（只留数字滚动/指针 `_draw`/颜色状态）、`ui/time_symbol_hud.gd`、`ui/hud/hud.gd`（挂载改为 preload 场景实例）。
**Interfaces:** `WatchHud.build_dial_texture()` / `absorb()` / `tremble()` / `flash_locked()` 签名不变；`TimeSymbolHud` 公有方法/常量不变。Label 的 `%Big` / `%Cap` / `%Center`（按现 `_mk_label` 调用逐值搬）；字号 96/32/16 进场景。
**Steps:** 改前夹具 → 场景化 → 夹具 diff=0（含 watch 文本「上限/大数字/短时」三处）→ 真场景人眼 → commit。

### Task 8: `hud.tscn` 外壳

**Files:** Create: `ui/hud/hud.tscn`（根 `CanvasLayer` layer=129 + script `hud.gd`）；Modify: `scenes/level_0.tscn`（HUD 节点改成实例）、`ui/hud/hud.gd`（`_ready` 里 `%KillCounter`/`%Watch`/`%TimeSymbol`/`%WeaponWrap` 取节点，不再 new；血条段/氧条仍代码建，挂到 `%Segments`/`%Oxygen` 空 Control 下，位置公式不变）。
**Interfaces:** `Hud` 公有行为不变；`level_0.tscn` 的 HUD 节点类型仍是 `CanvasLayer`。
**Steps:** 夹具 diff=0 + 读数全等 → `level_0` 人眼 → commit。

### Task 9: `broadcast.tscn` / `status_banner.tscn` 填壳

**Files:** Modify: `ui/hud/broadcast.tscn`（Mask/Center/Panel(`PanelCarvedBodyInset72`)/HeaderStripPanel(BIG_FONT 144 居中)/Sub Label 全部场景声明）、`ui/hud/broadcast.gd`（只留倒计时/脉冲/显隐）；`ui/hud/status_banner.tscn`（Root/Panel(`panel_box(false)` 对应变体或保留代码 style？—— 该面板是**不透明**底板，需新增 `PanelOpaque` 变体：`C_SURFACE`+2px `C_BORDER`，值抄 `UiFactory.panel_box(false)`）+ `StatusLabel`）、`ui/hud/status_banner.gd`（只留 `set_text` + `_center_panel()`）。
**Interfaces:** `Broadcast.big/sub/mask` 字段改为 `@onready` 从场景取，对外仍是字段；`countdown_finished` 不变。
**Steps:** 夹具：pvp_game + `_on_round_state` 倒计时/本局结束两态 + banner 长文案，before/after diff=0 → commit。

### Task 10: `minimap.tscn` + 三个 HUD 的变体替换

**Files:** Create: `ui/hud/minimap.tscn`；Modify: `ui/hud/minimap.gd`（静态圆/描边/shader 材质进场景，点位仍代码）、`ui/hud/pvp_hud.tscn`、`ui/hud/team_hud.tscn`、`ui/hud/royale_hud.gd/.tscn`（把代码里 `add_theme_*`/`StyleBoxFlat` 换成 `Hud*` 变体）。
**Interfaces:** `Minimap.setup/setup_multi` 与 `RANGE_CELLS/RADIUS_PX` 常量不变。
**Steps:** 夹具 after diff=0（含小地图圆、排行榜底板、击杀计数器、延迟条 rect）→ 真 pvp_game/royale_game 人眼看一眼 → **变异验证（档 2 那条）**：把 `_refresh_weapon_boxes` 的循环数改成 `held-1`，夹具读数断言必须红；还原后绿。→ commit。

---

## Phase 3 — 菜单组件（档 1）

### Task 11: `weapon_check_row.tscn`
**Files:** Create: `ui/components/weapon_check_row.tscn/.gd`；Modify: `scenes/main_menu.gd`、`scenes/lobby_page.gd::_add_weapon_grid`。
**Interfaces:** `WeaponCheckRow.setup(type_id:int, checked:bool) -> void`，`toggled(on:bool)` 信号透出；文案 `WeaponRegistry.name_of`、图标 `WeaponIcons.silhouette`。
**Steps:** before/after 取图（sp panel / create dialog 三模式）diff=0 → commit。

### Task 12: `map_picker.tscn` + `map_card.tscn`
**Files:** Create: `ui/map_picker.tscn`（根 VBox + HeaderStripPanel + `%Scroll` + `%Grid`）、`ui/components/map_card.tscn/.gd`；Rewrite: `ui/map_picker.gd`（`setup()` 只填卡与选中态）。
**Interfaces:** 保留 `selected` / `select_path(path, from_click)` / `picked` / `_cards`；卡尺寸 `CARD_W=244` / `THUMB_H=132` 进场景/组件；`MapCatalog` 接口不变。
**Steps:** 夹具（地图卡选中态 + 未选中态）diff=0；`menu_autotest._verify_map_picker` 依赖 `_cards.size()>=3`（headless 可跑，grep `已在面板里选中`）→ commit。

### Task 13: `sp_launch_panel.tscn` 填壳
**Files:** Rewrite: `ui/screens/sp_launch_panel.tscn`（HeaderStripPanel(48,centered) + MapPicker 实例 + 分区标题 + WeaponCheckRow 列表宿主 + 两颗按钮）；Modify: `scenes/main_menu.gd::_fill_sp_panel`（缩成：读 Settings → 填控件 → 接信号）。
**Interfaces:** 面板公开行为不变（两按钮语义、`Settings.sp_disabled_weapons/sp_map_path` 写入逻辑原样保留，逐字搬，不改 `ids[i]` 那条注释逻辑）。
**Steps:** `main_sp_panel` before/after diff=0；勾选三把枪后「开始探索」前 `Settings` 读数用 headless 脚本验证 → commit。

### Task 14: `room_card.tscn`
**Files:** Create: `ui/components/room_card.tscn/.gd`；Modify: `scenes/mp_lobby/room_list.gd`（`redraw` 只实例化+填值）、`tools/gen_menu_theme.gd`（`CardHeader` / `RoomCard` 变体）。
**Interfaces:** 保留 `meta("code")`、`disabled/focus_mode/modulate` 的「对局中」规则、点击 handler（回局优先）；卡头内边距 0/12 的 P0 规则进 `CardHeader` 变体。
**Steps:** `lobby_rooms`（6 间假房）before/after diff=0 + 长房主名溢出行为保持（本批不修）→ commit。

---

## Phase 4 — 大厅骨架收口（档 1）

### Task 15: 等待室/建房/加入面板语义名 + 名单行文本集中

**Files:** Modify: `scenes/mp_lobby.tscn`（只改本任务触及的通用名节点）、`scenes/mp_lobby/wait_room.gd`（`_roster_row` 文本格式集中到 `_roster_row_text(n,p,my_role,host_role)`）。
**Interfaces:** `MpLobby._grid/_wait_body/_wait_count/_wait_start` 字段不变；`roster_row` 的 `set_meta` 行为可保留。
**Steps:** `grep` 契约清单逐项存在；headless 实例化 mp_lobby 后取全部 `%` 节点 dump（期望全非 null）；取图 diff=0 → commit。

---

## Phase 5 — 收尾（档 1）

### Task 16: 删死工厂 + 文档 + 全量复核

**Files:** Modify: `ui/factory/ui_factory.gd`、`docs/eng/ui.md`。
**Steps:**
1. `grep -rn "UiFactory\.\(header_strip\|menu_panel\|skin_menu_panel\|menu_button\|label\|panel_box\|row_box\)(" ui scenes tests tools` → 期待只剩 HUD 动态样式与零调用；零调用者逐个删并同步注释。
2. 更新 `docs/eng/ui.md`：组件目录、契约（什么进 .tscn / 单 Label 行不进 / HUD 边界）、theme 变体表、生成器必须重跑。
3. 全量复核：`p1_shots` 14 镜头 after vs phase0/before diff=0（P0 后基线）；`python tools/check_naming.py` 判据 `命名检查 OK`；`bash tests/run_all.sh` 前后同一绿基线（判据 grep `RUN_ALL` 汇总文本）；headless boot `--quit-after 120` 无 ERROR。
4. `grep -n "PauseMenu.new\|\.new(true)\|\.new(false)" scenes/` 为空。
5. Commit：`git commit -m "refactor(ui): P1 收尾(删死工厂 + UI 组件规范入文档)"`

---

## 附：每任务的共同验收脚手架

- 取图：`"$GODOT" --path . --quit-after 3600 res://.superpowers/sdd/_gen/p1_shots.tscn -- <输出目录>`（窗口模式）。
- 几何/读数：headless 跑 `.superpowers/sdd/_gen/p1_hud.gd`（或 `ui_audit_dump.gd` 变体）。
- 像素对比：`python .superpowers/sdd/_gen/p1_diff.py <before> <after>`；判据 = `changed_px` 全 0。
- 每次 commit 前：`git status --short` + `git diff` 逐文件认领 hunk；新 `.gd` 带 `.uid`；`.tscn.uid` 不加。

## Execution Handoff

计划保存到 `docs/superpowers/plans/2026-10-27-ui-components.md`。执行方式建议 **Native**（仓库档位不要求逐任务评审；任务间接口由本计划锁定），最后整体评审。用户已批准 spec 并指示「开工」，按 Native 执行。
