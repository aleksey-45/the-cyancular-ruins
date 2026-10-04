# 窗口与显示设置（A4）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让玩家在设置页能选**分辨率**与**全屏**，而**默认窗口仍是当前硬编码的 1920×1440**，且**不改任何一处版式**（`mp_lobby.tscn` 那 21 处 `layout_mode = 0` 的绝对定位逐像素不变）。

**Architecture:** 保留 `window/size/viewport_*` 作为**逻辑空间**（1920×1440），补上 **`window/stretch/aspect`** 让"窗口尺寸 ≠ 基准尺寸"时逻辑空间**仍是** 1920×1440（等比缩放 + 黑边）。`Settings` 加两个字段（分辨率档索引 + 全屏档）+ 一个 `apply_display()`，由 autoload `_ready()` 在 `load_settings()` 之后调用；设置页新增一组"显示"，只写 `Settings` 再调 `apply_display()`。★ `stretch/mode` 的两个候选（`viewport` = 保像素 / `canvas_items` = 文字清晰）**由取图定夺**（Task 0），两者都是一行配置 ⇒ **不 fork** 后续任务。

**Tech Stack:** Godot 4.7.1（非 mono）、GDScript、`Settings` autoload、`DisplayServer`、场景探针 + **非 headless 取图**。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §1.4 + 用户裁定（「默认窗口还是当前硬编码的数字，然后设置添加分辨率/全屏之类的选项」）。

## Global Constraints

- **视觉验收看图判断**，不把对比度/数值当验收标准（用户明确取消过一次）；★ **取图一律不带 `--headless`**（带了就没有视口纹理、**静默不存图**），且跑前明确告知会弹窗抢焦点。
- `tests/probe/settings_display_section_probe.gd` **必须保持绿**，其中 `:83-84` 断言「**「联机显示」这个标题恰好出现 1 次**」、`:98-99` 断言它与「通用/按键映射」的相对顺序 ⇒ 新组别**不得**复用这些标签文本。
- 新增控件的**字号载体字面量必须是 16 的倍数**（`kh_l4_probe.gd:149-171` / `kh_l5_probe.gd:364-389` 机械扫全仓）。
- `scenes/level_0.tscn:13` 的 `size = Vector2i(2208, 1728)`（世界 SubViewport）**不得**跟着基准改 —— 它是"基准 + 2×144 裁剪边"的结果，与窗口尺寸无关。
- 逐个文件点名 `git add`；**绝不** `git add -A`。

## Review Focus

按"最可能咬到人"排序，每条都在下面的任务里配了断言或取图。

1. **逻辑空间必须仍是 1920×1440**（Task 1）。破了它，这些会一起漂：`scenes/mp_lobby.tscn` 的 21 处绝对 `offset_*`、`scenes/mp_lobby.gd:524` 的 `1920.0 - PAGE_MARGIN * 2.0`、`ui/hud/minimap.gd:107` 的 `Vector2(1920.0 - EDGE - …, 1440.0 - …)`、`scenes/main_menu.gd:74-75` 的 `BG_VIEW_CELLS := 26.6667`（横向铺 26.67 格 ⇒ 72 屏幕像素/格，只对逻辑宽 1920 成立）。
2. **`stretch/mode` 选 `disabled` / `keep_width` / `keep_height` / `expand` 都会破前提**（Task 1）⇒ 只允许 `{canvas_items, viewport} × {keep, ignore}`，且 `ignore` 会把圆压成椭圆（不推荐）⇒ 实际就两个候选。
3. **`core/present/post_process.gd:49-50` 的 `crop_scale` 只在 `_ready` 算一次**（Task 1）。逻辑尺寸不变的档**不需要**重算；一旦选了会让逻辑尺寸变的档，就必须挂 `get_tree().root.size_changed` 重算，否则裁剪比例停在开窗那刻。
4. **新增的 CheckButton 会被 `settings_display_section_probe._set_all_keys()` 一并翻转**（Task 3）⇒ 它必须像既有开关一样只在 `toggled` 里写 `Settings`，且 `Settings` 必须能被该探针的 `_restore(orig)` 还原（实现前先读 `:150-160` 确认口径）。
5. **headless 下不能调 `DisplayServer.window_set_mode`**（Task 2）⇒ `apply_display()` 用仓内既有惯例 `DisplayServer.get_name() == "headless"` 早退（`tests/smoke/menu_autotest.gd:504` 是同一写法的先例）。
6. **分辨率索引越界**（Task 2）⇒ 照 `core/config/settings.gd:156` 的既有权衡写法 `clampf(float(cf.get_value(...)), lo, hi)` 回落，别让坏存档把窗口设成 0×0。

---

### Task 0: `stretch/mode` 取图对比（**决定点**，产出图交用户定）

**Files:**
- Modify（临时，最终值由裁决落定）: `project.godot:38-43` 的 `[display]`
- Test: 复用仓内**既有取图手法**（见 Step 1），不改代码

**Interfaces:**
- Consumes: `project.godot` 的 `[display]`（现状逐字：`:40` `window/size/viewport_width=1920`、`:41` `..._height=1440`、`:42` `window/size/resizable=false`、`:43` `window/stretch/mode="viewport"`；**无** `stretch/aspect`、**无** `window_width_override`）。
- Produces: **裁决**（二选一）+ 四张对比图 —— 后续 Task 1 只落这一行。

- [ ] **Step 1: 找出仓内既有的取图手法并列出来**

Run: `grep -rn "save_png\|get_texture()\|viewport_get_texture" tests/probe/*.gd | head -30`，挑一个已能取**菜单类**画面的探针（没有就照最接近的那个写法最小新增一个取图探针）。
★ 这一条要**先把手法列进报告**（取图探针文件名 + 关键行），因为「取图探针怎么写」是本仓既有约定，不该由本任务发明。

- [ ] **Step 2: 取图（两组配置 × 各 2 张）**

对 `stretch/mode` 的 `"viewport"` 与 `"canvas_items"` 各跑一次，每次**加** `window/stretch/aspect="keep"`，取：
① 设置页（新组别落定前用现有页面即可，看**文字清晰度**）；② 主菜单（看 `BG_CELL_PX`/`BG_VIEW_CELLS` 的取景与背景网格）。
Run（示例，**不带 `--headless`**）:
`"$GODOT" --path . --quit-after 300 res://tests/probe/<取图探针>.tscn`
★ 跑前告知用户"会弹窗口"。

- [ ] **Step 3: 交用户看图定**

把四张图与"两组各是什么代价"（保像素 vs 文字清晰）一起给用户；**不要**替用户拍这个板。
产出：`stretch/mode` 的最终值（写进 Task 1 的 Step）。

---

> ★ **2026-10-04 裁决（用户）**：`stretch/mode` 选 **`"viewport"`**（硬边/保像素）—— 用户原话「肯定选择前者的硬边」。
> 依据：① 实测 4.7.1 的整块画布 blit 走**最近邻**（与 NEAREST 平均绝对差 0.00004 / 与 BILINEAR 0.01362），
> 与"硬边"一致；② **默认窗口 1920×1440 在这台机器上根本不存在缩放**（屏 2560×1600、窗口居中且 1:1），
> 这个选择只在玩家主动挑小分辨率时才现形；③ 与本仓既有像素风纪律一致。
> ⇒ **Task 1 的 `mode` 一行不改**（现状即定案）。取图对照与取证见
> `.superpowers/sdd/2026-10-04-window-and-display-settings/shots/`（视口模式那张是 `viewport-*.png`）。

> ★ **仍待裁决的一件事（与 mode 无关）**：**首次运行在"装不下 1920×1440"的屏上（如 1080p，高 1080 < 1440）要不要自适应换个小窗口？**
> 本机实测 1920×1440 是**放得下且居中的**（`pos=(320,44)`、3/3 次一致）⇒ 这台机器不需要；但 1080p 屏需要。
> 两个方向：`window_width_override`/`window_height_override`（只改**窗口**、**逻辑空间仍 1920×1440** ⇒ 零版式改动、代价是非整数缩放丢像素），
> 或让 `Task 2` 的 `apply_display()` 在首次运行挑"能放下的最大 4:3"。★ 这条**不阻塞** Task 2/3/4。

### Task 1: `[display]` 定档（按 Task 0 的裁决落一行）

**Files:**
- Modify: `project.godot:38-43`
- Modify（若需要）: `scenes/main_menu.gd` / `ui/hud/minimap.gd` —— ★ **只在取图证明必要时**才动（见 Review Focus 1）

**Interfaces:**
- Consumes: Task 0 的裁决值。
- Produces: `project.godot` 的 `[display]` 成为"窗口可 ≠ 基准"的合法配置 —— 后续任务的 `apply_display()` 依赖它。

- [ ] **Step 1: 落配置**

在 `:43` 之后加 `window/stretch/aspect="keep"`；把 `:42` 改成 `window/size/resizable=true`（用户已定：允许玩家自由拖，`keep` 负责加黑边）；按 Task 0 的裁决改/保留 `:43` 的 `mode`。
★ **不要**改 `:40`/`:41` 的 1920/1440（用户已定：默认窗口保持当前硬编码数字）。

- [ ] **Step 2: 取图复核"零版式改动"**

按 Task 0 的手法，窗口分别取 **默认（1920×1440）**、**1280×960**、**一个非 4:3 尺寸（如 1600×900）** 三张，逐张确认：
① `mp_lobby` 的绝对定位与默认档**逐像素一致**（等比缩放而非重排）；② 非 4:3 时**有黑边**且内容未被拉伸变形。

- [ ] **Step 3: 跑既有视觉/版式守卫**

Run: `"$GODOT" --path . --quit-after 300 res://tests/probe/kh_l4_probe.tscn`（与 `kh_l5_probe.tscn`）⇒ 判据是它们既有的 OK 文本；字号扫描不得因本次改动变红。
★ 这两个探针**非 headless**（要真渲染）⇒ 跑前告知。

- [ ] **Step 4: 提交**

```bash
git add project.godot
git commit -m "feat(display): 补 stretch/aspect=keep 并放开 resizable(窗口≠基准时逻辑空间仍 1920×1440 ⇒ 零版式改动)"
```

---

### Task 2: `Settings` 两字段 + `apply_display()`

**Files:**
- Modify: `core/config/settings.gd`（字段区 `:13-43` 之后、`save()` `:113`、`load_settings()` `:140`、新增 `apply_display()`）
- Create: `tests/smoke/settings_display_smoke.gd`（`-s`；空载守卫 + 外层 `timeout`）

**Interfaces:**
- Consumes: `DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)`、`DisplayServer.window_set_size(Vector2i)`（Godot 4.7 枚举名）；`Settings` 的既有存取惯例（`cf.set_value("audio", "master_volume", master_volume)` `:115`、`cf.get_value("audio", "master_volume", 0.8)` `:145`、越界回落 `:156` 的 `clampf`）。
- Produces: `Settings.display_res_index: int`、`Settings.display_fullscreen: bool`、`Settings.apply_display() -> void`（**Task 3 要调它**）、`Settings.DISPLAY_RESOLUTIONS: Array[Vector2i]`（单一来源：设置页下拉与 `apply_display()` 都读它）。

- [ ] **Step 1: 写失败断言**

`tests/smoke/settings_display_smoke.gd` 断言：
① `Settings.DISPLAY_RESOLUTIONS` 非空、**含 1920×1440**、且全是 **4:3**（`size.x * 3 == size.y * 4`，保证 `keep` 下无黑边）；
② 出厂默认 `display_res_index` 指向 1920×1440、`display_fullscreen == false`；
③ 把一个越界索引喂给 load 路径（或直接构造坏值）后，**回落**到合法范围（照 `:156` 的 clamp 惯例）；
④ `apply_display()` 在 **headless** 下**不抛错**（`DisplayServer.get_name() == "headless"` 早退）。
★ 每条断言都要能回答"去掉什么它才红"；`-s` 必须写空载守卫，否则抛错会**永久挂起**。

- [ ] **Step 2: 跑它，确认红**

Run: `timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/settings_display_smoke.gd`
Expected: 不出现 `SMOKE OK`；报"`DISPLAY_RESOLUTIONS` 不存在"之类。

- [ ] **Step 3: 实现**

字段 + `DISPLAY_RESOLUTIONS`（**4:3 四档**：1280×960 / 1600×1200 / 1920×1440 / 2560×1920）+ `save()`/`load_settings()` 各一行（`"display"` 段）+ `apply_display()`（headless 早退；否则按索引 `window_set_size`、按开关 `window_set_mode`）；在 `_ready()`（`:45-47`）的 `load_settings()` **之后**调 `apply_display()`。

- [ ] **Step 4: 跑它，确认绿 + 变异**

Run: 同 Step 2 ⇒ `SMOKE OK`。
变异（档 2 至少一条）：把 `DISPLAY_RESOLUTIONS` 里 1920×1440 改成 1600×1200 ⇒ 断言 ② 必须红；复原。

- [ ] **Step 5: 提交**

```bash
git add core/config/settings.gd tests/smoke/settings_display_smoke.gd
git commit -m "feat(settings): 加显示档(4:3 四档 + 全屏开关)+ apply_display(headless 早退;越界按既有 clamp 惯例回落)"
```

---

- ★★ **控制器追认（2026-10-04）—— 三条偏离全部接受 + 一条覆盖上限交 Task 4**

  ① **`save()`/`load_settings()` 各加可选 `path: String = SAVE_PATH`**：目的是让断言 ③ 能验"坏存档回落 + 落盘/读回"
  **而不碰玩家真的 `user://settings.cfg`**。默认值即原路径、grep 确认全部 **32 处调用点无参** ⇒ 行为零变化。
  **接受** —— 这是把"测试不许改玩家状态"落成可测的 **seam**，不是接口膨胀。★ 控制器另做了决定性实验：
  跑冒烟前后玩家真 cfg 的 mtime **逐秒相同**、且 `settings.gd` **无退出时保存** ⇒ 该 seam 确实没副作用。
  ② **默认档下标改在 `_init()` 里反查**（而非成员初始值）：实测 **GDScript 成员初始值不走 setter** ⇒
  `.find()` 失手时的 `-1` 会原样漏进字段（变异 ① 实得就是 `-1`；窗口化时 `DISPLAY_RESOLUTIONS[-1]` 直接报错）。
  **接受** —— brief 给的形状本身有隐患。
  ③ ★★ **brief 的断言 ④"headless 下不抛错"在 headless 下结构性不可证伪**：变异 ② 实测 —— 删掉早退后
  `apply_display()` 真调了 `window_set_*`，输出里**一个 ERROR 都没有**（dummy DisplayServer 是**静默空实现**）。
  ⇒ ④ 的牙齿落在**源码半边**（早退必须排在两个窗口调用**之前**；`_ready()` 必须在 `load_settings()` **之后**调它），
  实现者把它写成**按源码位置**的断言，并**拒绝**假造一条 `_check(true, …)`。⇒ **这是控制器 brief 的错**
  （"断言恒真"一类在本次会话已是第 6 次），本条即追认记录。
  ④ **覆盖上限（交 Task 4 登记）**：`apply_display()` 的**非早退分支（真开窗/真全屏）至今只有源码级证据** ——
  本任务绿跑全在 headless（非 headless 会抢焦点）。真要闭环得跑一次**非 headless** 并取几何/取图（与 Task 0 同性质）。
  ★ 另外记一笔**写法税**（实现者已写进两边注释）：因冒烟按源码文本查这两个字面量，`apply_display()` **函数体内**
  的注释**不得**出现 `window_set_size` / `window_set_mode`。

### Task 3: 设置页新增「显示」组

**Files:**
- Modify: `scenes/settings_menu.tscn`（左栏，插在「联机显示」(`:139-146`) 之后、「按键映射」之前）
- Modify: `scenes/settings_menu.gd`（`@onready` `:34-41`、`_ready()` 灌值区 `:57-72`）
- Test: `tests/probe/settings_display_section_probe.gd`（**不改**，只要求保持绿）+ 取图

**Interfaces:**
- Consumes: `Settings.DISPLAY_RESOLUTIONS` / `display_res_index` / `display_fullscreen` / `apply_display()`（Task 2）；`_check(cb, on, on_toggle)` helper（`:93-97`）；既有 `@onready var _minimap: CheckButton = %MinimapCheck`（`:39`）的写法。
- Produces: 设置页的「显示」组（分辨率下拉 + 全屏开关），玩家可见可用。

- [ ] **Step 1: 先读两处既有实现再动手**

① `settings_display_section_probe.gd:150-160`（`_set_all_keys` / `_restore`）—— 确认新开关会被一并翻转、且 `Settings` 能被还原（Review Focus 4）；
② `settings_menu.tscn:139-146` 那组的节点结构（`theme_type_variation` = `HeaderStrip` / `HeaderTitle`、行的 `HBoxContainer` + `Label` 的 `custom_minimum_size`），照抄形状。
★ **按实况**再定：本计划给的行号是写作当时的，先 `grep` 复核。

- [ ] **Step 2: 建场景节点**

在「联机显示」之后插一组：标题文本用 **"显示"**（★ **不得**用"联机显示"——那条断言要求它恰好 1 次）；行内 = 标签 + `OptionButton`（分辨率，`unique_name_in_owner = true`）+ `CheckButton`（全屏）。**不要**写非 16 倍数的字号。

- [ ] **Step 3: 接线（3 处）**

`@onready var _res: OptionButton = %ResOption`；`_ready()` 里灌 `selected = Settings.display_res_index` 并连 `item_selected`（写 `Settings.display_res_index` + `Settings.save()` + `Settings.apply_display()`）；全屏用既有 `_check(Settings.display_fullscreen, …)` 包一层（同样 `save()` + `apply_display()`）。

- [ ] **Step 4: 跑守卫 + 取图**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn` ⇒ 必须仍是它的 OK 文本（"联机显示"仍恰好 1 次、顺序断言仍真）。
再**非 headless** 取一张设置页图，确认新组与既有三组**同款版式**（标题样式、行高、间距）。

- [ ] **Step 5: 提交**

```bash
git add scenes/settings_menu.tscn scenes/settings_menu.gd
git commit -m "feat(ui): 设置页新增「显示」组(分辨率下拉 + 全屏开关),写回 Settings 并即时 apply_display"
```

---

### Task 4: 文档 + 边界登记

**Files:**
- Modify: `docs/eng/ui.md`（设置页那一节补「显示」组与两个字段）
- Modify: `README.md`（若有"操作/设置"清单）
- Modify: `docs/eng/registered-debt.md`（§六 或 §五，见下）

**Interfaces:** Consumes 前三个任务的产物；Produces 文档与登记。

- [ ] **Step 1: 补文档**

`docs/eng/ui.md`：说明"基准 1920×1440 是**逻辑空间**、`stretch/aspect=keep` 让窗口任意大小时逻辑空间不变"这条**为什么**；列出四档分辨率与全屏开关落在 `Settings` 的哪两个字段。

- [ ] **Step 2: 登记未验证的边界**

写进 [`registered-debt.md`](../eng/registered-debt.md)：**真窗口/真全屏在 OS 层的行为未测**（多显示器、Windows 缩放非 100%、Alt+Enter 与 `WINDOW_MODE_FULLSCREEN` 的交互、2560×1920 在 1080p 屏上超出后 OS 的钳制方式）—— 本次只验了"逻辑空间不变 + 取图无变形"。★ 这条与 audit §5 第 1 条是同一件事，销账时一起销。

- [ ] **Step 3: 提交**

```bash
git add docs/eng/ui.md README.md docs/eng/registered-debt.md
git commit -m "docs(display): 补显示设置说明 + 登记 OS 层窗口行为未验证"
```

---

## 本计划**不含**

- **改基准尺寸**（1920×1440 → 别的）—— 用户已定"默认窗口保持当前硬编码数字"；改它会连带 `level_0.tscn:13` 的 2208×1728、`minimap.gd:107`、`main_menu.gd:74-75`、`info_menu.gd:33` 的 `ROW_W := 760`，是另一个量级的决定。
- **`stretch/mode` 选 `disabled` / `keep_*` / `expand`** —— 会破"逻辑空间恒 1920×1440"这个前提（Review Focus 2）。
- **窗口位置/多显示器选择**（记在哪块屏上开）—— 没在需求里。
