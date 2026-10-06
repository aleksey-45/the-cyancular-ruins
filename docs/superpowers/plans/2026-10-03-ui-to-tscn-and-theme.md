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

## Task 0（2026-10-03 补做，计划初稿没有这一步）：把 `menu_theme.tres` 刷成**当前**语汇

**为什么必须有这一步**：Task 1 建的 `.tres` 停在**旧档**（按钮内容边距 30/14、面板是单层 28/20），
而 `UiFactory` 此后经过两轮放大（`_btn_box` 40/20、`menu_panel` 64/46、`header_strip` 40/20）
并新增了整族菜单语汇（`C_HEADER`/`C_INNER`/`C_EDGE`/`C_GOLD`/`C_TEXT_MUTE` + `menu_button` 的
primary/quiet/gold/accent 四档）。**拿旧档当迁移基准 = 一挂上去外观就变**，而迁移的定义是"外观不变"。

**做法**：新增 `tools/gen_menu_theme.gd`（`-s`，从 `UiFactory` 的现取值**生成** `.tres`，
不手抄 —— 手抄 float32 会撞 `ui_palette_single_source_smoke` ⑥ 的 1/65536 容差，且会漂移），
外加把 `_make_switch()` 的胶囊导成两个 PNG（Theme 引用不到运行时生成的 `ImageTexture`）。

- [x] Step 1: 调色板加 `C_TRANSPARENT`（Theme 里那层"只画线不画底"的内亮线要它；
      `ui_palette_single_source_smoke` ⑥ 要求 Theme 里每个颜色都等于某个 `const C_*`）
- [x] Step 2: 写 `tools/gen_menu_theme.gd` + 两趟跑法（先导 PNG → `--import` → 再生成）
- [x] Step 3: 写 `tests/smoke/menu_theme_mirror_smoke.gd` —— **镜像守卫**。
      ★ 判据**直接读生产产出**（`UiFactory` 的函数挂到控件上之后 `get_theme_stylebox()` 读回来），
      **不**在守卫里重写一份构造 —— 那会与生成器共享同一个错误源（两边一起错 ⇒ 恒绿）。
      647 条比对。
- [x] Step 4: 两个 PNG 的 `.import` 里 `process/fix_alpha_border` 改 `false`
      （默认 true 会改写透明边缘的 RGB，逐像素比对实测差 **100 个像素**）
- [x] Step 5: 验证：`ui_palette_single_source_smoke` ALL-OK / `menu_style_probe` ALL-OK(20 条) /
      `kh_l5_probe` ALL-OK(扫 401 个 `.gd`/`.tscn` + 1 个 `.tres`，载体 90) /
      `menu_theme_mirror_smoke` ALL-OK(647 条)

★ **漂移纪律（本步引入的新风险，已用守卫堵住）**：以后**改了 `UiFactory` 的菜单系样式，
      必须重跑 `tools/gen_menu_theme.gd`**，否则 `.tres` 静默停在旧值上 —— `menu_theme_mirror_smoke`
      就是为这条而立的（它是那类"改了 A 忘了 B、不报错"的唯一拦截）。

★ 另记两条**与计划文本不符**的现状（迁移时按实际走）：
1. **六屏全部是裸场景**（1 个 node + 脚本）—— 计划里"`match_result` 早有骨架 `.tscn`"那句是错的。
2. **Task 3/4 的"美化"半边已经做完了**（信息页 `40082ba` / Beta 页 `f87b2dc` / 结算页 `c31b941`）
   ⇒ 这两条任务实际是**纯迁移**，不是"迁移与美化一次做完"。

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

> ### ✅ 已收口(2026-10-03):本任务的前提**基本不成立**,实际可删面远小于计划设想
>
> 跑了一遍完整的 `UiFactory` 样式面清点(过程报告是 gitignored 的 scratch,结论已全部抄在本节),
> 结论:
> - **Step 1 的门按字面写永远不可能为真** —— 实测**没有任何 `.tscn` 含施加器名**(0 行):
>   六屏残留**100% 在动态代码路径**(房卡/名单行/表单动态块那一族),它们**按设计留代码**,
>   所以那些施加器**永远有调用点**。⇒ 门改成「**六屏静态骨架零命中 + 具名例外清单**」,今天已为真(commit `ae5e0d1` 交付)。
> - **实际删掉的只有四个零调用死构造器**:`menu_separator` / `check_row` / `slider_row` / `menu_filter_button`
>   (第四个由 T3a 追加实测发现)。**`style_row_button` 刻意保留** —— 它是 `menu_theme_mirror_smoke` 里
>   `RowButton` 那条臂的**供给**(靠"调它就地覆写再把值读回来"才有比较对象),删了等于**零收益砍覆盖**;
>   它与 `_btn_box`/`panel_box`/`row_box`/`_row_sb`/`switch_icons` 同属**生成器/守卫供给面**。
> - **永久保留的具名例外**(每条都有机制,不许只写"保留"):`ui/factory/weapon_icons.gd:56`(共享工厂,字号传参)·
>   `scenes/main_menu.gd:442`(该面板挂在 `%UILayer`,是 Theme 子树的**兄弟** ⇒ 删了掉回**引擎默认主题**)·
>   `scenes/lobby_page.gd:70/125/519` · 对局内 HUD 七处(`hud.gd` ×4 / `royale_hud.gd` ×1 / `status_banner.gd` ×2)·
>   `ui/map_picker.gd:113`。
> - **`apply_font_recursive` 单独立项**(不并进删除批):它在 `lobby_page.gd:70` 有生产调用,
>   而"Theme 的 `default_font` 能不能替它"是**行为断言**,要像素证据。
> - ★ **纪律**:上面所有 grep 都**以具体目录为 root**(`scenes ui core server tests`),**绝不用 `.`** ——
>   `.claude/worktrees/*` 与 `.superpowers/sdd/{_b2_backup,_gen}` 的旧副本会造幽灵命中(实测 `check_row` 18 条)。

- [x] **Step 1: 先确认零调用点**(改为按 R12 的"六屏静态骨架零命中 + 具名例外清单")

```bash
grep -rn "style_control\|style_button\|style_check\|style_line_edit\|style_slider\|panel_box\|row_box\|style_row_button" \
  --include=*.gd --include=*.tscn scenes/ ui/ core/ | grep -v "ui/factory/ui_factory.gd"
```
★ **必须零命中**。有命中就说明那一屏还没迁完 —— **别删**。

- [x] **Step 2: 删**(2026-10-03 按 R12/R26 收口 —— 实际只删**四个零调用死构造器**
  `menu_separator` / `check_row` / `slider_row` / `menu_filter_button`(`ae5e0d1`);**`style_row_button` 刻意保留**
  —— 它是 `menu_theme_mirror_smoke` 里 `RowButton` 那条臂的**供给**(删了等于零收益砍覆盖)。详见上方 ✅ 收口块
  与本节的清点结论)

★ **`_btn_box` / `panel_box` / `style_button` 等可能仍被 `UiFactory` 自己的其它函数用**（如 `menu_button`）—— 删之前看清谁还在用。
★ **`PixelFont.shared()`**：确认没有 `.gd` 再调它之后删（`apply_font_recursive` 一并评估）。

- [x] **Step 3: 全量回归 + 提交**(`ae5e0d1`;回归面结论见本节)。
  ★ 连带清掉一条**同批发现的既有红**:`allscript_probe` 的 `SKIP_DIRS` 漏了 gitignored 的 `res://_crashtest` ⇒
  它**改前就红 3/288**、全仓没有可用的编译面闸;补上后为 `OK(283 个脚本全部加载)`(`c77a53b`)。

---

## 收尾检查

- [ ] **六屏逐张取图人眼验收**（主菜单 / 设置 / 信息 / 大厅 / Beta / 结算）+ 倒计时 + 暂停菜单
- [ ] **HUD 现状的证据**(★ 2026-10-03 F1 订正:原句是「HUD **未动**的证据…**且与 Task 2 的基线图一致**」,
  那半句**已被 R18/R20 证伪**,改成一条**今天真能跑、真能 grep** 的判据):`combat_hud_visual_probe` +
  `kh_l3_visual_probe` + `minimap_circle_probe` 三条绿,**外加** `combat_hud_visual_probe` 里那条
  **广播面板几何断言**(`6a4b39e` 钉住的值,量具是 `Control.size`:外框 **866×371**、标题带 **720×185**)
  —— 它才是"**被接受的 HUD 现状**"的判据。
  ★ 为什么"与 Task 2 的基线图一致"不成立(两条,缺一不可):① 那份基线图**只活在 gitignored 的 scratch 里**
  (没有 pair/md5 进版本控制)⇒ 今天**已经找不回来**、无从复跑;② 更要紧的是 **"未动"这句话本身为假** ——
  `671e610` 把共享构造器 `header_strip()` 的内边距 28/14 → 40/20,而复用它的大厅内广播面板因此
  **连带变宽 +24 像素**(外框 841→865/866、标题带 696→720,见「已知边界」第 6 条)。⇒ 拿那份(若还在的)旧图来
  比对**必然红**,而它红的是**已经被裁决接受**的连带改动 —— 用它会把一个已接受的变更判成回归。
- [ ] **字号守卫真的在看 `.tscn`/`.tres`**：往任一 `.tscn` 塞 `font_size = 33` ⇒ `kh_l5_probe` 必须红
- [ ] **调色板守卫真的在看 Theme**：改 Theme 里任一颜色一位 ⇒ 必须红
- [ ] **用户能自己在编辑器里拖**：打开 `scenes/settings_menu.tscn`，确认控件与布局**可见可编辑**（这是整个计划的**最终目的**，必须有人真的打开看过）

## 已知边界

1. **编辑器里看不到动态行**（房卡、名单行）—— 「静态骨架进 `.tscn`、动态留代码」这个裁定的必然代价。
2. **`.tscn` 里的魔数不会消失** —— 它们只是从 `.gd` 搬到 `.tscn`。改变的是**可见性与可编辑性**。
3. **Theme 管不到"忘了挂 Theme"** —— 那种控件会用 Godot 默认样式且**不报错**；逐屏取图是唯一拦截。
4. **字体导入设置是全局的** —— Task 2 的前后对比图是它的唯一验收。
5. **本计划不改任何视觉**（Task 3/4 除外 —— 那两屏的视觉本来就还没做）。
6. ★ **"对局内 HUD 一个像素都不改"这句话不准确**(2026-10-03 实测修正):被冻结的是 **`UiFactory` 的共享 token *值***;
   而 **`header_strip()` / `menu_panel()` 这类共享构造器的 *尺度* 不是冻结面** —— `671e610` 把 `header_strip()` 的内边距
   28/14 → 40/20(左右各 +12),而 `ui/hud/broadcast.gd` 复用它 ⇒ 对局内广播面板**连带变宽 +24 像素**
   (外框 841→865/866,标题带 696→720;两个量具互印)。★ **`get_global_rect()` 含 `_apply_punch()` 脉冲缩放,
   不能做判据** —— 判据量 `Control.size`。已由 `combat_hud_visual_probe` 的显式几何断言钉住"被接受的值"(`6a4b39e`)。
7. ★ **迁移产生了四个"孤儿页底色"**:`scenes/{beta_menu:22, info_menu:20, mp_lobby:639, settings_menu:21}.tscn`
   的 `ColorRect1` 上是 `Color(0.07, 0.09, 0.13, 1)` —— 它原本由 `lobby_page.gd` 的 `_add_lobby_background()` 画,
   而该 helper 被本次迁移当作"只服务被删 builder"退役(四个迁移提交各删一处 `.gd` 落点)⇒
   **没有任何代码拥有它,也没有守卫看得见它**(调色板 smoke ⑤ 只钉底板色、只认 `bg_color =`)。**登记不修**:
   修它要"加调色板常量 + 重生成那 4 个场景",属拥有 theme 生成器的那一批。
8. ★ **一处覆盖缺口(登记)**:`kh_l3_visual_probe` 里那条"环画出来了"的像素断言被证明**无鉴别力**
   (环留着差值照样 76 —— 量到的是玩家帧动画)⇒ 删掉后该性质**只剩人眼图**;要有鉴别力得先有稳定参考帧,成本不成比例。
9. ★ **登记收口说明(2026-10-03,最终整体评审 + F1 修复波)**:评审点的"六条登记项"全部落在这里 ——
   其中 **R40(四处孤儿坐标)= 上面第 7 条**、**R39(环像素覆盖缺口)= 上面第 8 条**;
   下面 10–13 是其余四条,14–15 是**本波(F1)新登记**的两条,16 是**四个验收态像素对**的持久记录。
   ★ 为什么不写进 `docs/eng/registered-debt.md`(`AGENTS.md` 把它称作"唯一清单"):那份文件属**另一个会话**,
   本波**不许动别人的文件** ⇒ 记录落在这里,并**交还给属主**去并进那份清单(见第 13 条同一道理)。
10. ★ **R34 那一类:`.tscn` 里的颜色字面量还有 214 处**(108 处 `[sub_resource]` **逐位等于**某个 `C_*`;
    106 处是**节点属性**,其中 **30 处按值不等于任何常量、且按设计就不在调色板里**:
    modulate 10 + hack 2 + 对局内 HUD 文本色 4 + 战斗反馈 4 + 激光 3 + 压暗罩 2 + 排行榜板底 1 + 孤儿 4)。
    ⇒ **今天不扩调色板守卫**:扩了只能靠 ~30 条豁免撑绿,而"豁免表"正是下一批假绿的温床。**登记,不修。**
11. ★ **`MODE_COLOR`(`scenes/mp_lobby.gd:436-441`)与场景里 7 颗按钮上烙的 stylebox / `font_pressed_color`**
    是**两份真相源、彼此无对账** —— 改一处不会红。要么将来上生成式(模式色 → 按钮态资源),要么补一条对账守卫;
    今天**只登记**(它与第 10 条同源:Theme 表达不了的运行时参数被场景内联接管)。
12. ★ **重新落地时用到的守卫只活在 gitignored 的 scratch `_gen/t2_land.py` 里**:`[node]` 计数相等、
    `DYNAMIC_HOSTS` 空容器断言、`NEUTRALIZE` 属性白名单。生成器文件头只是**指向**它 ⇒
    **将来重新落地 `.tscn` 的人必须重新实现这三条**(或者先把它们入库),否则"重新生成"这一步没有任何拦截。
13. ★ **`docs/eng/ui.md:12` 仍写着"对局内 HUD 一个像素都不改"** —— 该句已被 R18/R20 证伪(见第 6 条,
    连带 +24px)。**属主订正,本波不动别人的文件。**
14. ★ **(F1 新登记 a)`create` 态的像素判据只覆盖 1v1 表单**:royale 专属的 MaxPlayers / MatchTime 行
    **只有行为证据**(`lobby_create_form_probe` ②③④ 的"按模式显隐")、**没有像素证据**。
    它们的差别是**显隐**而不是版式 ⇒ **登记而不补第五态**(补它要把整套改前/改后重跑一遍,成本与收益不成比例)。
15. ★ **(F1 新登记 b)`tools/gen_menu_scene.gd` 的输出不是逐字节可复现的** —— 82 个 `unique_id` 是随机生成的
    (把 id 掩掉之后两次输出一致)。⇒ T2 落地时用的是**外科式补丁 + 交叉验证**(而不是"重跑生成器覆盖"),
    下一批要重新生成的人必须先知道这一条,别把"两次输出不同"当成漂移。
16. ★ **四个验收态的像素对(入库工具可复现;此前 `wait` 那一相只能靠 gitignored 的 scratch 驱动)**。
    ★ 取图命令**一律不带 `--headless`**;`addr=` 钉住网络时序(状态栏文案是网络驱动的),`call=` / `args=<JSON>` 是带参调用:
    ```
    "$GODOT" --path . res://tools/_shot_scene.tscn -- res://scenes/mp_lobby.tscn <名>.png addr=127.0.0.1
    ...  <名>.png addr=127.0.0.1 _toggle_join_panel
    ...  <名>.png addr=127.0.0.1 _open_create_dialog
    ...  <名>.png addr=127.0.0.1 call=_show_wait_room \
         'args=[{"code":"2468","is_public":true,"players":[{"role":1,"name":"甲","team":0},{"role":2,"name":"乙","team":0},{"role":3,"name":"丙","team":0}],"your_role":2,"host_role":1,"max_players":4},"royale"]'
    ```
    ★ **改前态 = `05bdbf1` 的 4 个 blob,注意是 4 个而不是 3 个**:`scenes/mp_lobby.gd`(`7614ab…`)、
    `scenes/mp_lobby.tscn`(`4e636e…`)、`scenes/lobby_page.gd`(`b9c099…`)—— 外加 `ui/factory/ui_factory.gd`
    (`167187…`):改前那份 `mp_lobby.gd` 调 `UiFactory.menu_filter_button`,而它被**更晚的** `ae5e0d1` 当死代码删了
    ⇒ 不还原这第 4 个文件,改前态**解析不过、连图都取不到**(2026-10-03 实测)。
    改后态 = HEAD 的同样 4 个 blob(`fc2b8b…` / `09fbc6…` / `99f9d2…` / `ee1365…`)。
    ★ **别在主树里就地换这 4 个生产文件**(忘了换回来 = 生产代码被改):用隔离工作树
    `git worktree add <scratch> HEAD`,拷入 `tools/_shot_scene.{gd,tscn}`,**先跑一次
    `--headless --editor --quit` 生成 `.godot/global_script_class_cache.cfg`**(没有它会报
    `Identifier "MazeGenerator" not declared`),取完图 `git -C <scratch> checkout -- <4 文件>` 复原。
    ★ **16 个文件只有 4 个不同的 md5**(每态 before/before2/after/after2 逐字节相同 —— 即一个像素都没差):
    ```
    chrome  f1_shot_chrome_{before,before2,after,after2}.png  f44d25b78445de6b711393cf9d693553
    join    f1_shot_join_{…}                                  b133a6c4e674d123f4b0bfcfababa04c
    create  f1_shot_create_{…}                                c0a4f0baf59b95d92167c56dc8b8119a
    wait    f1_shot_wait_{…}                                  3938792328e11af511664b990f5efe84
    ```
    ★ 判据原文:每态 `before/before2`、`after/after2`、`before/after` **三条** `pixel_diff` 全为
    `DIFF 0 / 2764800` + `MAXDELTA 0`(共 12 条);且这 16 张与**旧权威集** `t2p_*` 逐对 `DIFF 0`
    ⇒ 入库工具复现出来的就是当年那批图。★ PNG 本体仍住 gitignored 的 `_gen/`(**scratch,不算记录**);
    **记录 = 上面这四行 md5 + 这段取法**。
