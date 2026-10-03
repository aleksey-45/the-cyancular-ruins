# UI 搬进 .tscn + Theme 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把四个菜单屏从「裸 Control + 代码里建 UI」改成「`.tscn` 骨架 + `Theme` 资源供样式」，让版式在 Godot 编辑器里**看得见、拖得动**，同时**不改变运行时外观**。

**Architecture:** 样式收进一个 `Theme` 资源（字号用 Theme Type Variation 表达）；静态骨架进 `.tscn`；数量不定的行（房卡、名单行）仍由代码建。设计见 `docs/superpowers/specs/2026-10-03-ui-to-tscn-and-theme-design.md`（下称「设计」）。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`Theme` / `StyleBoxFlat` / `FontVariation`。

**★ 与计划 ③ 的关系**：③ 已经给**主菜单**与**统一大厅**换过皮（方向 B），并做了**广播组件**与**暂停菜单**。本计划接手：**设置页 / 信息页 / Beta 页 / 结算页这四屏的视觉还没做** ⇒ 它们**迁移与美化一次做完**（省一遍工）；**主菜单与统一大厅**已经好看，只需迁移（保持外观）。

## Global Constraints

- **字号必须是 16 的倍数**（16/32/48）。★ 迁移后这条规则的守卫必须**跟得上**（见 Task 1）。
- **共享 token 一个都不许改**（用户裁定「HUD 优先」）：`C_ACCENT` / `C_TEXT` / `C_TEXT_DIM` / `C_DANGER` / `C_WARN` / `C_PLATE` / `C_SLOT_*` / `C_TEAM_*` / `C_GRACE` / `C_MODE_*` **值逐位不变**。
- **`panel_box()` 的形状不变**（对局内**重连横幅** `ui/hud/status_banner.gd:88` 在用）。
- **不动对局内 HUD 的视觉**。★ 唯一会全局生效的是**字体导入设置**（Task 2），它**必须逐屏取图验收**。
- **判据一律是文本**（`ALL-OK` 等），**不看退出码**。
- ★★ **共用工作树**：**提交一律逐个文件点名 `git add`，绝不 `git add -A`**；提交前 `git status --short` 看一眼。**`CLAUDE.md` 不要动**（协调者统一处理）。
- ★★ **取图命令一律不带 `--headless`** —— headless 下没有视口纹理，探针会打印「跳过截图」并**静默地什么都不存**。
- ★★ **每屏迁移后必须"前后取图对比"**（迁移的定义是"外观不变"，只有图能证明）。
- ★ **文案一个字都不许改**（多条探针按文案找控件）。

---

## Task 1: Theme 资源（先不含字体）+ 扩两条守卫

**Files:**
- Create: `ui/theme/menu_theme.tres`
- Modify: `tests/probe/kh_l5_probe.gd`（扩扫描面到 `.tscn` / `.tres`）
- Modify: `tests/smoke/ui_palette_single_source_smoke.gd`（加钉 Theme 的颜色字面量）
- Test: 既有全部守卫应保持绿

**Interfaces:**
- Produces: `ui/theme/menu_theme.tres` —— 一个 `Theme`，含 `H1`/`Body`/`Small` 三个 **Theme Type Variation**（48/32/16）与 Button/PanelContainer/LineEdit 的 `StyleBoxFlat`（**先照抄 `UiFactory` 现在的值**，逐位相同）

- [ ] **Step 1: ★ 先扩 `kh_l5_probe` 的扫描面（**这一步是安全网，必须最先做**）**

`tests/probe/kh_l5_probe.gd` 现在只扫 `.gd` 源码里的字号载体（`add_theme_font_size_override(...)`、`font_size = N`、`const …FONT_SIZE`）。

**★ 实测订正(2026-10-03)**：本计划初稿说"它只扫 `.gd`"—— **那句是错的**。`ScanUtil.walk:38` 收 `.gd` **与 `.tscn`**，而 C 类正则本来就命中 `.tscn` 里的 `theme_override_font_sizes/font_size = N`。
⇒ 真正会失明的只有 **`.tres`（Theme）** 那一支；`.tscn` 早就在覆盖内。**别照着初稿那句去重复造轮子。**
★ 仍然成立的那半：`.tres` 里的字号（`font_sizes/<Type>/<name> = N`）**一个都扫不到** —— 而迁移正是要把字号搬进 Theme ⇒ 不补它，「字号必须是 16 的倍数」就会**看起来还在守、其实空了**（本仓已出过十次的那类失效）。

**改法**：把 `.tscn` 与 `.tres` 也纳入扫描面，识别这些写法：
- `.tscn`：`theme_override_font_sizes/font_size = N`
- `.tres`（Theme）：`font_sizes/<Type>/<name> = N`
- 以及 `theme_type_variation` 引用的变体名（**它的字号在 Theme 里定义**，所以要能追过去）

★ **并加一条"扫描量下限"**：把"扫到的字号载体总数"打出来。若某次重构让这个数**掉到 0**，守卫必须**红**而不是静默通过（本仓的老坑：扫描坏了 = 零命中 = 假绿）。

★ **本步不改任何屏** ⇒ 全部守卫应保持现状（绿）。

- [ ] **Step 2: 扩 `ui_palette_single_source_smoke`**

它现在读两个 `.tscn` 的原文、断言 `bg_color` 与 `UiFactory.C_PLATE` **逐位相等**（该文件头写着"结构上引用不到 const ⇒ 只能留字面量，由本守卫读文本断言"）。

**加**：读 `ui/theme/menu_theme.tres` 原文，把里面**每一个** `Color(...)` 字面量抽出来，断言它**等于调色板里某个常量**。
★ 覆盖上限照实登记在文件头：它钉的是**值**，钉不住"某个控件忘了挂 Theme 于是用了 Godot 默认样式"。

- [ ] **Step 3: 建 Theme**

`ui/theme/menu_theme.tres`：**先只放 StyleBox 与字号，不放字体**（字体是 Task 2 的事，它是唯一会全局生效的一步，单独做）。
★ 新建的 `.tres` 在编辑器里打开、把 `UiFactory` 现有的值**照搬进去**（`C_SURFACE` 面板底、`C_HEADER` 按钮填充、`C_EDGE` 描边、`C_ACCENT` 悬停、`C_GOLD` 主行动 …）。

- [ ] **Step 4: 跑全套守卫，必须全绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/ui_palette_single_source_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
```
★ **特意验证扩扫描面有效**：临时往 `menu_theme.tres` 里塞一个 `font_size = 33`，跑 `kh_l5_probe` **必须红**；删掉复原。
★ 同法验证调色板守卫：临时把 Theme 里某个颜色改一位，**必须红**。

- [ ] **Step 5: 提交**

```bash
git add ui/theme/menu_theme.tres tests/probe/kh_l5_probe.gd tests/smoke/ui_palette_single_source_smoke.gd
git commit -m "feat(ui): Theme 资源基座 + 扩两条守卫(字号扫描面 / 调色板钉 .tres)"
```

---

## Task 2: 字体资源化（★ 唯一全局生效的一步，单独验收）

**Files:**
- Modify: `assets/fonts/less_perfect_dos_vga.ttf.import`、`assets/fonts/unifont-17.0.05.otf.import`
- Create: `assets/fonts/menu_font.tres`
- Modify: `ui/theme/menu_theme.tres`（挂 `default_font`）

**为什么必须做**：`PixelFont.shared()` 是**运行时**给字体关抗锯齿/微调/子像素、再挂 CJK 回退链的 —— **`.tres` 引用不到运行时属性**。

- [ ] **Step 1: 先取"改前"的 HUD 图（基线）**

```bash
"$GODOT" --path . --quit-after 3600 res://tests/probe/combat_hud_visual_probe.tscn
"$GODOT" --path . --quit-after 3600 res://tests/probe/kh_l3_visual_probe.tscn
"$GODOT" --path . --quit-after 3600 res://tests/probe/minimap_circle_probe.tscn
```
图存进 `.superpowers/sdd/`，**先自己读一遍**（这是 Task 2 的对照基线）。

- [ ] **Step 2: 烘导入设置**

两个字体文件的 `.import`：
```
antialiasing=1        → 0
hinting=3             → 0
subpixel_positioning=4 → 0
```
★ **运行时会重导**；改完跑一次 `"$GODOT" --headless --path . --import`。

- [ ] **Step 3: 建字体资源链**

`assets/fonts/menu_font.tres`：一个 `FontVariation`，`base_font` = DOS VGA，`fallbacks` = [`unifont-….otf`, `SystemFont(font_names=["SimSun","宋体","Microsoft YaHei"])`]。
★ `SystemFont` 也是资源，可以内嵌在 `.tres` 里。

- [ ] **Step 4: Theme 挂上它，然后**取"改后"的图逐张比对**

重跑 Step 1 的三条，**把改前改后的图逐张对照**。
★ **若有任何肉眼可见差异 ⇒ 停下来，走设计 §3.4 的退路**（放弃把字体放进 Theme；Theme 只带 StyleBox，字体仍由代码 `apply_font_recursive` 挂），并在文档里如实登记"编辑器里的字与运行时不同"。

- [ ] **Step 5: 提交**

★ 提交前确认 `PixelFont.shared()` **还没有删**（它在 Task 7 才删 —— 先并存）。

```bash
git add assets/fonts/less_perfect_dos_vga.ttf.import assets/fonts/unifont-17.0.05.otf.import \
        assets/fonts/menu_font.tres ui/theme/menu_theme.tres
git commit -m "feat(ui): 字体资源化(烘导入设置 + FontVariation 回退链) ⇒ Theme 可引用

改导入设置是全局的(含对局内 HUD) ⇒ 单独一步 + 前后取图逐张比对。"
```

---

## Task 3: 设置页 + 信息页 → `.tscn` + Theme（**迁移与美化一次做完**）

**Files:** `scenes/settings_menu.tscn` / `.gd`、`scenes/info_menu.tscn` / `.gd`

**做法**：
1. **静态骨架进 `.tscn`**：设置页的**两栏版式**（左栏 音量/通用/联机显示，右栏 按键映射）、信息页的**左右两栏**（版本信息 / 开发团队 + 致谢）、所有标题带、所有固定按钮、底部动作行。
   ★ 设置页的两栏是**已经批准过的版式**（设计 §3.9.3 + 定稿视觉稿），现在正是在 `.tscn` 里落它的时机。
2. **动态部分留代码**：键位表的每一行（`Settings.REMAPPABLE_ACTIONS` 循环）、禁用武器网格、地图选择器、提交历史行、开发团队/致谢的名单行。
   ★ 名单与致谢是**用户给定、逐字照抄**的（`Lord Nahiz Waugh` 是**一个人**）。
3. **样式走 Theme**：控件加 `theme_type_variation`（`H1`/`Body`/`Small`），**不再调** `UiFactory.style_control` 一族。

- [ ] **Step 1: 取改前的图**（`-- --autotest-set` 与 `-- --autotest-ver`，**不带 `--headless`**）
- [ ] **Step 2: 迁移 + 美化**
- [ ] **Step 3: 跑这两屏的常驻探针**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
"$GODOT" --headless --path . -s res://tests/probe/settings_esc_probe.gd
"$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
```
★ 这两个探针**按标签文案找控件**、并按**行的结构**找 `CheckButton` —— 节点结构变了**可能**要同步改探针。改探针时**只许改"怎么找"，不许改"断言什么"**。

- [ ] **Step 4: 取改后的图、自己读、与改前对比**
- [ ] **Step 5: 提交**

---

## Task 4: Beta 页 + 结算页 → `.tscn` + Theme（同样一次做完）

**Files:** `scenes/beta_menu.tscn` / `.gd`、`ui/screens/match_result.tscn` / `.gd`

★ `match_result` 早有骨架 `.tscn`（列宽/标题由 `match_result_payload` 决定）—— 它主要是**换皮**，不是从零迁。
★ `match_result` 的 `MASK_COLOR`（0.55 全屏压暗罩）**保持不动**（调色板例外）。
★ 结算页的**列数据/标题一字不动**（`match_result_payload_smoke` 在守）。

- [ ] **Step 1: 改前取图**（`-- --autotest-beta`；`match_result_probe`）
- [ ] **Step 2: 迁移 + 换皮**
- [ ] **Step 3: 回归**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/match_result_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/match_result_payload_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/hud_declarative_probe.tscn
"$GODOT" --headless --path . --quit-after 250 -- --autotest-beta
```

- [ ] **Step 4: 取图自己读 + 提交**

---

## Task 5: 主菜单 + 统一大厅 → `.tscn`（**保持外观**）

**Files:** `scenes/main_menu.tscn` / `.gd`、`scenes/mp_lobby.tscn` / `.gd`

★ 这两屏**已经好看**（计划 ③ 做的）⇒ 本任务的定义是**外观不变**，只是把它搬进 `.tscn`。
★ 主菜单有一层**鱼眼漂移背景**（`core/present/menu_fisheye.gdshader`）—— 它进 `.tscn` 时**别把 shader 的 uniform 弄丢**。
★ 大厅的**动态部分**（房卡、名单行、`_form_rows`、地图选择器）留代码；`meta("code")` / `meta("mode")` / 按钮文案**一个不动**。

- [ ] **Step 1: 改前取图**（`kh_l4_visual_probe` 出主菜单；`-- --autotest-mp` 出大厅）
- [ ] **Step 2: 迁移**（★ 逐屏保持当前位置与尺寸 —— **迁移不是重排**）
- [ ] **Step 3: 回归**

```bash
"$GODOT" --path . --quit-after 3600 res://tests/probe/kh_l4_visual_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l4_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_wait_room_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . --quit-after 250 -- --autotest-ver
```

- [ ] **Step 4: 取图自己读，与改前**逐张**对比（背景的漂移相位不同，**只比布局与元素**）**
- [ ] **Step 5: 提交**

---

## Task 6: 收尾 —— 删被 Theme 接管的样式函数

**Files:** `ui/factory/ui_factory.gd`

- [ ] **Step 1: 先确认零调用点**

```bash
grep -rn "style_control\|style_button\|style_check\|style_line_edit\|style_slider\|panel_box\|row_box\|style_row_button" \
  --include=*.gd --include=*.tscn scenes/ ui/ core/ | grep -v "ui/factory/ui_factory.gd"
```
★ **必须零命中**。有命中就说明那一屏还没迁完 —— **别删**。

- [ ] **Step 2: 删**

★ **`_btn_box` / `panel_box` / `style_button` 等可能仍被 `UiFactory` 自己的其它函数用**（如 `menu_button`）—— 删之前看清谁还在用。
★ **`PixelFont.shared()`**：确认没有 `.gd` 再调它之后删（`apply_font_recursive` 一并评估）。

- [ ] **Step 3: 全量回归 + 提交**

---

## 收尾检查

- [ ] **六屏逐张取图人眼验收**（主菜单 / 设置 / 信息 / 大厅 / Beta / 结算）+ 倒计时 + 暂停菜单
- [ ] **HUD 未动的证据**：`combat_hud_visual_probe` + `kh_l3_visual_probe` + `minimap_circle_probe` 三条绿，**且与 Task 2 的基线图一致**
- [ ] **字号守卫真的在看 `.tscn`/`.tres`**：往任一 `.tscn` 塞 `font_size = 33` ⇒ `kh_l5_probe` 必须红
- [ ] **调色板守卫真的在看 Theme**：改 Theme 里任一颜色一位 ⇒ 必须红
- [ ] **用户能自己在编辑器里拖**：打开 `scenes/settings_menu.tscn`，确认控件与布局**可见可编辑**（这是整个计划的**最终目的**，必须有人真的打开看过）

## 已知边界

1. **编辑器里看不到动态行**（房卡、名单行）—— 「静态骨架进 `.tscn`、动态留代码」这个裁定的必然代价。
2. **`.tscn` 里的魔数不会消失** —— 它们只是从 `.gd` 搬到 `.tscn`。改变的是**可见性与可编辑性**。
3. **Theme 管不到"忘了挂 Theme"** —— 那种控件会用 Godot 默认样式且**不报错**；逐屏取图是唯一拦截。
4. **字体导入设置是全局的** —— Task 2 的前后对比图是它的唯一验收。
5. **本计划不改任何视觉**（Task 3/4 除外 —— 那两屏的视觉本来就还没做）。
