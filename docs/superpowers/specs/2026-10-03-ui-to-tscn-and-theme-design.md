# UI 从代码搬进 .tscn + Theme 资源

**日期**：2026-10-03 ｜ **状态**：设计，待评审
**性质**：纯重构 + 结构性迁移 —— **目标是不改变运行时外观**（除了正在做的视觉重做本身）

---

## 0. 决策摘要

| # | 事项 | 裁定 | 来源 |
|---|---|---|---|
| 1 | 要不要搬 | **搬** —— 四个菜单屏现在是「裸 Control + 全在代码里建 UI」，改一个间距都要改代码 + 重跑 + 截图 | 用户裁定 |
| 2 | 范围 | **四个菜单屏一次做完**（主菜单 / 设置 / 信息 / 统一大厅） | 用户裁定 |
| 3 | 动态部分 | **静态骨架进 `.tscn`；数量不定的行（房卡、名单行）仍由代码建** | 用户裁定 |
| 4 | 样式放哪 | **`Theme` 资源（`.tres`）**，不是逐控件的 `theme_override_*` —— 后者会把样式抄散到每个场景（与本仓「控件工厂唯一来源」的初衷相反） | 本设计 |
| 5 | 字号怎么表达 | 用 **Theme Type Variation**（`H1` / `Body` / `Small` 三档），场景里只写 `theme_type_variation` | 本设计 |
| 6 | 调色板怎么办 | **`.tres` 里写死颜色值**，由 `ui_palette_single_source_smoke` **读文本钉它逐位等于调色板常量** —— 该守卫**已有同款先例**（它现在就钉着两个 `.tscn` 的 `bg_color`） | 本设计 |
| 7 | 字体怎么办 | 把 `_sharpen` 三项**烘进 `.ttf` 的导入设置**，CJK 回退链做成一个 `FontVariation` `.tres` ⇒ 字体变成 Theme 引用得到的资源 | 本设计 |
| 8 | `PixelFont.shared()` | 迁移后**删除**（其职责被"导入设置 + `.tres`"接管）；★ 但**先并存验证**，见 §3.4 | 本设计 |

---

## 1. 背景与现状

### 1.1 现在是"裸 Control + 代码建 UI"

四个菜单屏的场景文件**只有一个节点**：

| 场景 | 节点数 |
|---|---|
| `scenes/main_menu.tscn` | 1 |
| `scenes/settings_menu.tscn` | 1 |
| `scenes/mp_lobby.tscn` | 1 |
| `scenes/info_menu.tscn` | 1 |

全部控件在 `_ready()` 里建，位置是**散落的魔数**（`Vector2(60, 120)` 之类）。

**代价（用户的直接痛点）**：改一个间距 = 改 `.gd` → 重跑 → 截图 → 再看。**编辑器里看不到任何东西**，也没法自己拖。

### 1.2 本仓其实已有混合先例

`ui/screens/sp_launch_panel.tscn`（7 节点）与 `ui/hud/pvp_hud.tscn`（12 节点）就是混合的，注释写着：

> 「两个弹出面板的**骨架**在场景里（容器/滚动区/标签/锚点看得见）；按钮与勾选框仍由 `UiFactory` 建、数据由 `_fill_*` 填」

### 1.3 当初不这么做的理由，以及它现在为什么能解

原话是：**「控件进场景就得在使用处补 `style_control` + `style_button`，等于把「控件工厂唯一来源」这条纪律散回各处」**。

这条理由**当年成立、今天可以被 `Theme` 资源化解**：Godot 的 `Theme` 可以被根节点引用一次，其下的控件**自动**继承字体、字号与各状态的 `StyleBox` —— 样式仍然只有**一处**（那个 `.tres`），而且是编辑器里看得见、能直接改的一处。**这比现在的"更单一"**（现在是散在 `UiFactory` 的若干工厂函数里，且只有运行时才存在）。

---

## 2. 目标与非目标

**目标**

1. 四个菜单屏的**静态骨架**（容器、分栏、定宽标签列、固定按钮、锚点）落在 `.tscn` 里，编辑器可见、可拖。
2. 样式（字体/字号/各状态 StyleBox）收进一个 `Theme` 资源。
3. **运行时外观不变**（这一条是硬验收：迁移前后逐屏取图对比）。
4. 用户从此可以自己在编辑器里调间距/大小，不必等我改代码。

**不做**

- **不动对局内 HUD 的视觉**（`ui/hud/**` 的既有约束继续有效）。★ 但**字体**那一项会全局生效，所以 HUD 必须被"像素级验证"而不是"承诺"（§3.4）。
- 不搬**逻辑**：信号连接、数据填充、动态行构造、超时梯、模式分派**全部留在 `.gd`**。
- 不改任何**文案**、不改任何**协议**、不改任何**布局**（迁移不是重排；重排是视觉计划的事）。
- 不引入新的美术资源。

---

## 3. 设计

### 3.1 Theme 资源（`ui/theme/menu_theme.tres`）

一个 `Theme`，内含：

| 项 | 内容 |
|---|---|
| `default_font` | 指向 §3.4 的字体资源链 |
| 字号（Type Variation） | `H1` = 48、`Body` = 32、`Small` = 16（**全是 16 的倍数**） |
| `Button` | normal / hover / pressed / focus / disabled 五态 `StyleBoxFlat`；`font_color` 各态 |
| `PanelContainer` | 面板底（**不透明**） |
| `LineEdit` | normal / focus 两态 + 占位符/caret 色 |
| `CheckButton` | 开/关两个图标（§3.5）+ 字色 |
| `HSlider` | 轨道 / 已填充段 |

★ **Type Variation 是关键**：Godot 的 `Theme` 只能按**控件类型**给一套字号，而本项目同一个 `Label` 类型要 16/32/48 三档 ⇒ 用 Theme Type Variation 定义三个变体，场景里控件的 `theme_type_variation` 指到对应的那个。
★ 场景里因此**不出现任何 `theme_override_*font_size*`** —— 这正是让 §4.2 那条守卫还能守住的前提。

### 3.2 各屏 `.tscn`

静态骨架 + `theme_type_variation`。以统一大厅为例：

```
MpLobby (Control, theme = menu_theme.tres)
├── TopBar (VBox)
│   ├── Row1 (HBox): Label(H1?) + LineEdit
│   └── Row2 (HBox): Label + LineEdit + Button(刷新) + Button(启服)
├── FilterRow (HBox): Button×4 + Spacer + Button(＋创建房间) + Button(加入房间)
├── CardArea (ScrollContainer)          ← 代码往里塞房卡
├── StatusBar (PanelContainer): Label + Button(返回)
├── CreateDialog (PanelContainer)       ← 代码填房主选项的**行**
└── WaitRoom (PanelContainer)           ← 代码填**名单行**
```

★ **哪些是"动态"**（留在 `.gd`）：
- 房卡整卡（数量不定、内容随模式变）
- 等待室的名单行、两队分档
- 创建弹层里**按模式显隐**的那几行（`_form_rows`）
- 禁用武器网格的格子（由 `WeaponIcons.make_weapon_check` 生成）
- 地图选择器（`MapPicker` 是整个类）

★ **哪些是"静态"**（进 `.tscn`）：上面那些的**容器与外框**、所有固定文案的 `Label`、所有固定按钮、分栏与锚点。

### 3.3 `UiFactory` 的去向

**保留**：
- **调色板常量**（统一数据源不变，Theme 的值由守卫钉着 —— §4.2）
- **动态构造用的助手**：`check_row` / `slider_row` / `line_edit` / `make_weapon_check` 一族的调用方
  - ★ 墓碑：`check_row` / `slider_row` 已于 2026-10-03 删除（T3a 清扫零调用死构造器），相关版式改由 `.tscn` 显式节点承担。
- `apply_font_recursive`（**仅**给 `.tscn` 里没挂 Theme 的子树兜底；迁移完成后可评估删除）

**移除**（职责被 Theme 接管，且它们的存在正是"样式散在代码里"的来源）：
- `style_button` / `style_control` / `style_check` / `style_line_edit` / `style_slider` / `panel_box` / `row_box` / `style_row_button` 的**调用点**
- ★ 但**函数体先别删** —— 见 §5 的迁移顺序（先并存，后删除）

### 3.4 字体：从"运行时构造"变成"资源"

**现状**（`core/present/pixel_font.gd`）：`shared()` 在运行时 `load()` 两个字体、调 `_sharpen()`（关抗锯齿/微调/子像素）、再把 `fallbacks` 设成 `[Unifont, SystemFont(宋体…)]`。

**`.tres` 引用不到"运行时才被设上的属性"** ⇒ 必须把这三件事变成资源：

1. **`_sharpen` 三项烘进导入设置**：`assets/fonts/less_perfect_dos_vga.ttf.import` 与 `unifont-….otf.import` 现在都是 `antialiasing=1 / hinting=3 / subpixel_positioning=4`（**没关**），改成 `0 / 0 / 0`。
   ★ **这影响全项目用这两个字体的每一个地方，包括对局内 HUD** —— 必须按 §4.3 验证。
   ★ 理论上与 `_sharpen()` 的运行时结果**逐像素等价**（它设的就是这三个属性），但"理论"不算数，要取图。
2. **CJK 回退链做成资源**：新建 `assets/fonts/menu_font.tres`，一个 `FontVariation`：`base_font` = DOS VGA，`fallbacks` = [Unifont, SystemFont(宋体…)]。
3. Theme 的 `default_font` 指向它。

★ **过渡期两者并存**：先建好资源、让 Theme 用它，**同时保留 `PixelFont.shared()` 不动**；等 §4.3 的 HUD 像素验证通过后，再删 `shared()`。
★ **回退**：若导入设置一改就出现肉眼可见的差异，退路是**放弃把字体放进 Theme**（Theme 只带 StyleBox，字体仍由代码 `apply_font_recursive` 挂），并在文档里如实登记"编辑器里的字与运行时不同"。

### 3.5 自绘图标（`switch_icons()`）

`CheckButton` 的开/关胶囊图标是 `UiFactory._make_switch()` **程序化画的**（`Image.create` + 逐像素画胶囊）。Theme 引用不到运行时生成的 `ImageTexture`。

**做法**：把它**导出成两个 PNG**（`ui/theme/switch_off.png` / `switch_on.png`，由现有 `_make_switch` 逻辑一次性生成后写入磁盘），Theme 引用这两个文件。
★ 生成脚本**留下**（`tools/` 下一个一次性脚本），并注明"改了胶囊尺寸要重跑"。
★ 若评估后觉得不值，退路是**这两个图标继续由代码挂**，Theme 只管其余 —— 登记为已知不一致。

### 3.6 迁移不是重排（这条是纪律）

搬进 `.tscn` 时**逐屏保持当前的位置与尺寸**。任何"顺手调一下间距"都**不做** —— 否则"外观不变"这条验收标准就没了，而我们会分不清"搬错了"与"本来想改"。
★ 视觉调整走**另一条线**（计划 ③），两者**不同时做**。

---

## 4. 守卫影响（**这是本设计最大的风险面**）

### 4.1 会因"字号搬走"而**静默失明**的守卫（必须同步改）

| 守卫 | 现在扫什么 | 为什么失明 | 改法 |
|---|---|---|---|
| `tests/probe/kh_l5_probe.gd` | 只扫 `.gd` 源码里的字号载体（`add_theme_font_size_override(...)`、`font_size = N`、`const …FONT_SIZE`） | 字号搬进 `.tscn` / `.tres` 后它**一个都扫不到** ⇒ 「字号必须是 16 的倍数」这条规则**看起来还在守、其实空了** | 扩展扫描面到 `.tscn` + `.tres`（`theme_override_font_sizes/font_size = N`、Theme 的 `font_sizes/*`），并把"扫到的字号总数"打出来做人眼复核 |

★ 这条是**本设计里最危险的一处**：不扩它就等于**主动制造一个"守卫比它读起来弱"的实例** —— 而本仓已经出过十次。

### 4.2 统一调色板配置

`.tres` 里的 `StyleBoxFlat` 颜色是**字面量**，引用不到 GDScript 的 `const`。
⇒ 由 `tests/smoke/ui_palette_single_source_smoke.gd` **读 `.tres` 原文**，断言每个颜色与调色板常量**逐位相等**。
★ 该守卫**已有同款先例**（它现在就钉着 `ui/hud/pvp_hud.tscn` 与 `team_hud.tscn` 的 `bg_color`，注释写着"结构上引用不到 const ⇒ 只能留字面量，由本守卫读文本断言逐位相等"）。
★ 覆盖上限照实登记：它钉的是**值**，钉不住"某个控件忘了挂 Theme 于是用默认样式"。

### 4.3 "HUD 没动"的**证据**（不是承诺）

字体导入设置是**全局**的 ⇒ 必须取图对比：
- `tests/probe/combat_hud_visual_probe.tscn`（HUD 取色，**真实渲染**）
- `tests/probe/kh_l3_visual_probe.tscn`（武器槽三态）
- `tests/probe/minimap_circle_probe.tscn`
- **迁移前后各取一次图，逐张人眼比对**（数值全部通过而画面坏了，本仓抓到过）

### 4.4 其余可能受影响的守卫

- `tests/probe/kh_l4_probe.gd` / `kh_l4_visual_probe.gd`（主菜单按钮数 / 按钮文案）
- `tests/probe/menu_weapon_grid_probe.tscn`（菜单勾选框计数）
- `tests/probe/info_page_probe.tscn` / `settings_display_section_probe.tscn`（按**标签文案**找控件 —— 文案一字不动，但**节点结构变了**可能影响"按行找 CheckButton"的写法）
- `lobby_*_probe` 四个（按 `meta("code")` / 按钮文案找卡与按钮）
- `tests/probe/hud_declarative_probe.tscn`（层位只住 `.tscn` 里那条 —— 迁移会新增 `.tscn`，别把层位写错）

---

## 5. 迁移顺序（**逐屏、每屏都要"前后取图对比"**）

1. **基座**：建 `menu_theme.tres`（先不含字体）+ 扩 `kh_l5_probe` 的扫描面 + 扩 `ui_palette_single_source_smoke`。**此时不改任何屏**，全部守卫应保持绿。
2. **字体资源化**：烘导入设置 + 建 `menu_font.tres`；Theme 挂上它。★ **这一步单独做、单独取图验 HUD**（它是唯一一处会全局生效的改动）。通过后再进第 3 步；不通过就走 §3.4 的退路。
3. **逐屏迁移**（主菜单 → 信息页 → 设置页 → 统一大厅），**每屏一提交**，每屏取图对比。★ 顺序按"风险从低到高"：主菜单最简单、统一大厅最复杂（它有四块动态区域）。
4. **收尾**：删掉 `UiFactory` 里已被 Theme 接管的样式函数（**只在确认零调用点之后**）。

★ **第 1、2 步完成前不要碰任何屏** —— 否则"外观不变"这条验收线就断了。

---

## 6. 已知边界（照实登记）

1. **编辑器里的预览与运行时仍可能不同**：动态行（房卡、名单行）在编辑器里只能看到一个空容器。这是"静态骨架进 `.tscn`、动态行留代码"这个裁定的必然代价。
2. **Theme 的覆盖上限**：它管不到"忘了给某个控件挂 Theme"这一档 —— 那种情况下控件会用 Godot 默认样式，而**不会报错**。第 3 步的逐屏取图是唯一的拦截手段。
3. **`.tscn` 里的魔数不会消失**：它们只是从 `.gd` 搬到 `.tscn`。改变的是**可见性与可编辑性**，不是"没有魔数了"。
4. **字体导入设置是全局的**：改它对**所有**文本生效，包括对局内。§4.3 是它的唯一验收。
5. **本设计不改任何视觉** —— 视觉重做（计划 ③）是另一条线，两者**不同时进行**。
