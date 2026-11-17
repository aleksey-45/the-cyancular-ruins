# UI 设计系统 v1（Token / Theme / 布局 / 适配）

> 2026-11-09 用户裁定：**路线 A，全部一起做掉** —— 用 Godot 原生方案重构全仓 UI，不引第三方 UI 框架。
> 本文件是**设计系统唯一入口**；具体页面的版式现状仍见 [`ui.md`](ui.md)（迁移完成后逐步收编到本文件）。
> 返回索引：[`README.md`](../../README.md)。

## 0. 结论：为什么不用第三方「UI 框架」

调研（2026-11-09）结论：Godot 生态没有「成熟到能当框架」的第三方 UI 方案；成熟的是**官方 Control/Container/Theme**体系。

| 方案 | 现状 | 结论 |
|---|---|---|
| 官方 Control/Container/Theme | 引擎内建、长期维护；容器 + Theme type variations + anchors 覆盖本项目全部需求 | ✅ **采用**（[容器文档](https://docs.godotengine.org/en/stable/tutorials/ui/gui_containers.html) / [多分辨率](https://docs.godotengine.org/en/stable/tutorials/rendering/multiple_resolutions.html)） |
| [godot-flexbox](https://github.com/citizenll/godot-flexbox)（194⭐，C++/GDExtension/Yoga，MIT） | 布局能力强，但需要原生扩展；本仓导出用**裁剪模板**，引入要重编模板 + 三平台导出链验证 | ❌ 不做 |
| [GMUI](https://github.com/godothub/gmui)（147⭐，GDScript，MVVM，最后 push 2025-07） | 状态管理（数据→UI 绑定），不是布局/控件库；本仓规模用不上 | ❌ 不做 |
| [FlexContainer](https://github.com/Lefrec/FlexContainer)（6⭐） / [godot-theme-generator](https://github.com/Calinou/godot-theme-generator)（16⭐，WIP，2023） | 太新/太小/作者自标 WIP | ❌ 不做 |

**本项目「UI 不稳」的根因不是缺库**：固定 1920×1440 逻辑空间 + 大量绝对坐标（`scenes/*.tscn` 87 处 `offset_*`）+ 主题半生成半手写（`UiFactory` 每处 `new StyleBoxFlat`）+ 编辑器另起炉灶。重构目标是把这些收成四层。

## 1. 四层结构

```
Token（数值/颜色）  →  Theme（type variations）  →  Component（UiKit）  →  Screen（容器布局）
ui/factory/ui_factory.gd   ui/theme/menu_theme.tres   ui/components/ui_kit.gd    scenes/*.tscn|gd
（唯一来源，生成器写）      （tools/gen_menu_theme.gd） （薄封装，无样式）          （零绝对坐标）
```

## 2. Token（单一来源 = `ui/factory/ui_factory.gd`）

- 颜色：`C_*`（已有，见 [`ui.md`](ui.md)「调色板与 UiFactory」；页面禁止 `Color(...)` 字面量，动态色除外）。
- 间距：`SP_0=0 / SP_1=4 / SP_2=8 / SP_3=12 / SP_4=16 / SP_5=24 / SP_6=32 / SP_7=40 / SP_8=48 / SP_9=64 / SP_10=80`。
- 字号：`T_HUGE=128 / T_H1=48 / T_H2=32 / T_BODY=16 / T_LABEL=16`（像素字体只在 16 的倍数下锐利；`style_control` 保留 assert）。
- 圆角/描边：`R_SM=3 / R_MD=4 / R_LG=6 / BORDER_W=2 / BORDER_W_DIM=1`。
- ★ 规则：页面里禁止 `custom_minimum_size = Vector2(<魔法数>, …)`；用 token 组合或写清「内容驱动」。

## 3. Theme 2.0（`ui/theme/menu_theme.tres`，生成物）

由 [`tools/gen_menu_theme.gd`](../../../tools/gen_menu_theme.gd) 生成；**改样式只改生成器再重跑**。

| 控件 | variation | 用途 |
|---|---|---|
| Button | `Primary` / `Quiet` / `Danger` / `Icon` | 主按钮 / 次按钮 / 危险操作 / 图标按钮 |
| PanelContainer | `Card` / `Plain` / `Bar` | 卡片 / 无边框 / 顶部与底部条 |
| Label | `H1` / `H2` / `Body` / `Dim` / `Field` | 标题 / 小标题 / 正文 / 弱化 / 表单标签 |
| LineEdit | `Field` | 输入框 |
| CheckButton / CheckBox | `Kit` | 开关 |
| ScrollBar | `Kit` | 滚动条 |
| TabContainer / HSplitContainer / VSplitContainer | `Kit` | 分页与分栏（编辑器 / 大厅） |
| AcceptDialog / ConfirmationDialog / FileDialog | `Kit` | 统一弹层皮肤 |

- ★ **不设基础类型 Button 皮肤**：会让 CheckButton 沿类链穿上按钮皮（见生成器头注释）。
- 旧 API（`menu_button` / `menu_panel` / `label` / `style_*`）保留兼容，内部改成设置 variation；新页面只用 §4 的 `UiKit`。

## 4. 组件库（`ui/components/ui_kit.gd`）

`UiKit` 只做**结构**（容器 + token + variation），不做样式（样式全在 Theme）：

```gdscript
static func page(parent: Control, margin := SP_6, gap := SP_5) -> VBoxContainer
static func toolbar(parent: Control) -> HBoxContainer          # Bar 面板 + HBox(SP_3)
static func status_bar(parent: Control) -> HBoxContainer       # Bar 面板 + HBox(SP_3)
static func split(parent: Control, min_left := 320, min_right := 320) -> HSplitContainer
static func tab_panel(parent: Control, min_width := 320) -> TabContainer
static func add_tab(tabs: TabContainer, title: String) -> VBoxContainer
static func card(parent: Control, title := "") -> VBoxContainer
static func section(parent: Control, title: String) -> VBoxContainer
static func list_row(parent: Control, icon: Texture2D, title: String, subtitle: String) -> PanelContainer
static func dialog(parent: Node, title: String, ok_text := "确定") -> AcceptDialog
```

页面里**禁止**：手写 `StyleBoxFlat` / `add_theme_stylebox_override`（动态状态色除外）、`position =` / `size =`（画布、自绘控件、HUD 锚点除外）、`Color(...)` 字面量。

## 5. 布局规则（容器优先）

- 根布局：`MarginContainer`（SP_*）→ `VBoxContainer` / `HBoxContainer` / `GridContainer` / `ScrollContainer` / `SplitContainer` / `TabContainer`。
- 文本：`autowrap_mode` 或显式截断（`UiFactory.fit_name`）；行高由容器 + token 决定，禁止「必须手动抬到 N px」的约定。
- HUD：用 anchors + `MARGIN`/`SP_*` 表达，禁止 `1920.0 - …` / `1367` / `1784` 这类从逻辑分辨率反推的坐标（改成 anchor 或相对容器位置）。
- 弹层：统一 `AcceptDialog` / `ConfirmationDialog` / `FileDialog`（Theme `Kit`），不再手搓居中 `PanelContainer`。
- 列表行：`UiKit.list_row` / 卡片容器；行高由内容 min size 决定。

## 6. 分辨率策略

- **保留** `window/stretch/mode="viewport"` + `aspect="keep"` 的 **1920×1440 逻辑空间**：像素字体锐利、世界 SubViewport + PostProcess 不动、四档 4:3 等比缩放。这是像素风的关键取舍（改成 `canvas_items` 会让像素字体与非整数缩放发虚）。
- 修复 `Settings.fit_resolution()`：在 `DISPLAY_RESOLUTIONS` 里选**能放进可用区的最大 4:3 档**；一档都放不下时**等比缩到 4:3 窗口、绝不超屏**（1366×768 / 1280×720 / 800×600 不再出现「窗口比屏幕还高」）。
- `DISPLAY_RESOLUTIONS` 增补小屏档 `1024×768` / `1152×864`；仍是 4:3。
- UI 的「响应式」在本项目 = **内容驱动**（容器 + min size + scroll），不是随窗口改逻辑分辨率；窗口尺寸变化只做等比缩放。

## 7. 迁移状态（2026-11-09 全部完成）

| 页面 | 结果 |
|---|---|
| `scenes/editor/editor_root` | ✅ 顶栏（菜单/保存/撤销重做/文件名/跳转/帮助/视图）+ HSplit（左栏工具/画刷/按层渐进披露 ｜ 画布（含小地图） ｜ 右栏图层常驻 + TabContainer(2 页)）+ 状态栏 + ConfirmationDialog；`EDITOR SCENE PROBE` 60 条（2026-11-17 UX 二次补全后；版式不自动化，观感靠截图） |
| `scenes/main_menu` | ✅ 生成器改**构建模式**输出容器树（标题 HeaderStrip / 按钮列 720 / 版本号）；21 节点 16 unique name、0 offset |
| `scenes/settings_menu` | ✅ 运行时 `UiKit.page` 构建；5 张卡 + 两列 + 滚动；12 个 unique name 运行时登记（`%` 12/12 命中） |
| `scenes/info_menu` / `beta_menu` | ✅ root-only `.tscn` + 代码构建；H1/H2 标题 + 卡片；unique name 运行时登记 |
| `scenes/mp_lobby`（74 节点）+ `room_list` | ✅ 整文件重写：0 offset；单列房卡（Button + RowButton variation + meta）；49 个旧 unique name 全保留 |
| HUD（`ui/hud/*`） | ✅ anchors + `UiFactory.MARGIN/SP_*`；`hud_plate()` 唯一底板构造点；**前后截图逐像素 diff=0** |
| 结算 / 暂停 / 大厅弹层 | ✅ pause = Control 叠加层（契约例外）、match_result = CenterContainer + Card 状态屏；弹层统一 Theme 2.0 皮肤 |

- 迁移完成判据（逐页）：改前/改后截图 + 布局探针绿 + `run_all` 绿；全部页面 0 新增绝对 offset。
- 视觉变化属预期：标题带统一 HeaderStrip / H2、按钮统一 80 高、卡片化分组；文本/按钮顺序/信号/协议/存档语义全部未变。

## 8. 守卫

- `tests/probe/ui_layout_probe.tscn`（布局探针，54 条）：9 个页面 × 6 条 —— 场景可加载/可实例化/根拿到 1920×1440/有子节点/关键节点或 API 在/**可见 Control 的 global_rect 都在逻辑屏幕内**（ScrollContainer 内容区不查，本来就会被裁）。判词 `UI LAYOUT PROBE: ALL-OK(54 条断言)` + 条数闸。
- `tools/ui_shots.py`（非 headless，人工触发）：按页面 × 分辨率出截图到 `.tmp/ui_shots/`，供迁移前后评审；不进默认批。
- `python tools/check_naming.py` 与 `bash tests/run_all.sh` 每步必跑；判据一律 grep 判词。
- 不在默认批里加「源码里禁止 offset_*」这类形态守卫（D6）：先靠布局探针的行为判据，等迁移完再评估是否值得加。

## 9. 历史

- 2026-11-09：本文件建立；同日完成全仓迁移（编辑器 + 主菜单 + 设置 + 信息/Beta + 大厅/房间列表 + HUD + 暂停/结算/启动面板），布局探针 54 条、`run_all` 62 支全绿；旧 `ui.md` 的页面级现状已同步为迁移后口径。
