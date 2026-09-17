# UI 代码生成节点搬迁到 .tscn — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把四套「在 `_ready()` 里用 `new()` 拼出来」的界面布局搬进 `.tscn`，让节点树与锚点变成**编辑器里看得见、探针钉得住**的东西；脚本只留数据驱动逻辑。

**Architecture:** 每套界面「脚本 ↔ 场景」一一配对：场景声明**节点树 + 锚点 + 字体资源**，脚本用 `@onready $路径` 取回句柄。样式（`StyleBoxFlat` / 颜色 token）**继续留在代码里由 `UiFactory` 发**——搬进场景就会把调色板抄成第二处真值。数据驱动的节点（行数随人数/背包/血量变）**继续留在代码里**。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）、GDScript、`.tscn` 文本场景、仓内 `extends ProbeBase` 源码级探针 + `extends SceneTree/Node` 冒烟。

---

## Global Constraints

以下每一条都是本仓已写进 `CLAUDE.md` 或探针里的硬约定，**每个任务的要求都隐含包含这一节**：

1. **字号必须是 16 的倍数**（16/32/48/64/144…）。`kh_l4_probe` 第 3 条与 `kh_l5_probe` 第 8 条会**机械扫描全仓 `.gd` 与 `.tscn`**（`ScanUtil.collect` 收 `.tscn`；载体 C 类即 `.tscn` 的 `…font_size = N`）——搬进场景**不会**逃逸这条闸门，别指望。
2. **调色板唯一来源是 `ui/ui_factory.gd`** 的 `C_*` 常量。→ 本次搬迁**一律把 `StyleBox` 留在代码里**（`UiFactory.panel_box()` / 常量 / 局部函数），场景只搬节点树与几何。**例外**：`ColorRect.color` 这类节点自带属性可以写进场景（`pvp_hud.tscn` 的 `Mask` 已有先例）。
3. **纯搬运，不改任何数值。**`PLATE_COLOR` 的 0.1、排行榜底板那 +34、槽位 22px、所有 `offset`/`separation` **一律照抄**。这些是用户看实图定的审美值。
4. **节点名 = 现有成员名。** 探针按**成员名**读（`pvp._score_label` / `royale._rows` / `_fx._marker`）；改名 = 探针**静默失明**或直接报错。
5. **测量类探针 `--quit-after` 给足 3600 帧**，判据一律 **grep 文本 `ALL-OK`**，不能只看退出码（中途脚本报错时 `--quit-after` 仍 exit 0 且不打印 ALL-OK）。
6. **测试由用户自己跑。** 计划里的命令是给执行者/用户手动执行的；不要因为"想确认一下"就代跑一遍再改。
7. **改动落在分支上、每个任务一次提交。** 当前分支 `cleanup/stage1-bugs-and-hygiene`。
8. `-s` 冒烟与场景探针的跑法按脚本首行区分；本计划只涉及**场景模式**探针（`extends ProbeBase` / `extends Node`）。

**引擎路径**（不在 PATH；可用环境变量覆盖）：

```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
```

---

## 背景：为什么是这四项

盘点了 `ui/` 下 12 个 .gd，只有 `pvp_hud` 有配套 `.tscn`。**`pvp_hud` 就是本仓的对照组**——它的文件头写着「布局已迁进 pvp_hud.tscn，这里只留信号驱动逻辑」，106 行；而 `royale_hud.gd` 建**同一套** mask/Center/Big/Sub/Ping，314 行。

更关键的是 **`tests/kh_l6_probe.gd` 第 10 条已经在守这个模式**（bug 编号 B11）：

> main 的 `ui/pvp_hud.gd` 是**声明式**的：`@onready $子节点` 6 个。`.new()` 建出的节点没有子节点 → `_ready` 里 `_set_broadcast` 解引用 null → **硬崩溃**。

也就是说「脚本改声明式之后，宿主必须改走场景实例化」这件事，本仓**已经踩过一次并留了守卫**。本计划的三个搬迁项会重复这个模式，所以每个任务都要同时改掉 `.new()` 的调用点。

**判据**（为什么这四项赢）：

| 坑 | 现成的证据 | 场景化之后 |
|---|---|---|
| 不可见的默认值 | `hud.gd:407` 注释：想给击杀计数去底色，只删了 `bg_color` 赋值 → `StyleBoxFlat` 默认底色是**不透明灰** → 变成实心灰板，用户当场看出 | 节点树在编辑器里看得见 |
| 静默失效的 theme 键 | `ui_factory.gd:33`：`RichTextLabel` 读 `normal_font` 不读 `font`，传进工厂**不报错但不生效** → `combat_feedback.gd` 至今手抄 8 行 override | 场景里是显式资源赋值 |
| 锚点被顺手改掉、零报错 | `tests/pvp_hud_layout_probe.tscn` 存在的唯一理由 | 矩形在编辑器里可见 |

**必须先知道的两条本仓特有约束**（调查得到，不是常识）：

- **★ `PixelFont.shared()` 的副作用是「全局」的。** `core/present/pixel_font.gd` 的 `shared()` 把 `res://assets/fonts/less_perfect_dos_vga.ttf` 的**共享缓存实例**就地改成「关抗锯齿/微调/子像素」**并挂上 CJK 回退链**。场景里写 `[ext_resource type="FontFile" path=".../less_perfect_dos_vga.ttf"]` 拿到的就是同一个实例 —— 所以**只要调用过一次 `PixelFont.shared()`，场景里的 Label 也会锐利且有汉字回退**；反过来，**没调用过就是带抗锯齿、且汉字没有回退字形**（`royale_hud` 的标签全是中文：「—— 击杀排行榜 ——」「延迟 -- ms」「存活/复活中/离开」）。`pvp_hud.gd:26` 那句 `PixelFont.shared()   # 一次：共享字体…本场景所有像素 Label 全局锐利` 正是为此。**本计划每个新场景的宿主脚本都要显式调它。**
- **★ 脚本 `preload` 自己的场景 = 环。** `combat_feedback.gd` 里 `preload("res://ui/combat_feedback.tscn")` 会构成「脚本 → 场景 → 脚本」的循环引用，Godot 解析期直接报错。该处必须用**运行期 `load()`**（Task 2）。其余任务的加载方都是**另一个文件**，用 `preload` 无环。

**统一的搬迁口径**（四个任务共用，别再逐个讨论）：

- **Label → 进场景**（字体用 `ExtResource` 指向 ttf，照 `pvp_hud.tscn` 的先例）。
- **Button / CheckButton / HSlider / LineEdit → 留代码**走 `UiFactory`。搬进场景就得在使用处补 `style_control + style_button` 两行，等于把「控件工厂唯一来源」这条纪律散回各处。
- **`StyleBoxFlat` / 颜色 token → 留代码**（Global Constraints 第 2 条）。
- **数量随数据变的节点（排行榜行、提交历史行、武器勾选、血条段、背包方框、房间行）→ 留代码。**
- **`_draw()` 自绘控件（`HitMarker` / `KillSkull` / `WeaponSlots` / `PickupPrompt` / `ReloadRing` / `EnemyHpBar` / `world_label`）→ 不搬**，它们不是节点树问题；`HitMarker`/`KillSkull` 保持内部类，由代码建好塞进场景预留的**槽位**（Task 2）。

---

## 文件结构

**新建（5 个场景 + 1 组守卫探针）：**

| 文件 | 职责 |
|---|---|
| `ui/royale_hud.tscn` | 大乱斗 HUD 的 4 个静态区块（排行榜骨架 / 广播层 / 延迟 / 按键提示） |
| `ui/combat_feedback.tscn` | 打击反馈层的静态布局（root + 两个自绘槽位 + 击杀播报 + 连杀数） |
| `ui/version_panel.tscn` | 主菜单「版本信息」弹层的骨架 |
| `ui/sp_launch_panel.tscn` | 主菜单「单人开局」弹层的骨架 |
| `ui/kill_counter.tscn` | 单机 HUD 右上角击杀计数器的骨架（无脚本） |
| `tests/hud_declarative_probe.gd` + `.tscn` | **声明式契约守卫**：脚本 ↔ 场景配对、零 `.new()`、`@onready` 路径在场景里全声明 |

**修改：**

| 文件 | 改什么 |
|---|---|
| `ui/royale_hud.gd` | 删 4 个 `_build_*`，改 `@onready`；加 `PixelFont.shared()` |
| `ui/combat_feedback.gd` | `_ready` 的布局段删掉，改 `@onready` + 两个槽位；`spawn()` 改 `load()` |
| `ui/hud.gd` | `_build_kill_label` 改为加载 `kill_counter.tscn` |
| `scenes/main_menu.gd` | `_build_ver_panel` / `_build_sp_panel` 改为「实例化场景 + 填数据」 |
| `scenes/royale_game.gd:86` | `RoyaleHud.new()` → 场景实例化 |
| `tests/combat_hud_visual_probe.gd:45` | `RoyaleHud.new()` → 场景实例化 |
| `tests/royale_hud_cost_probe.gd:44` | `RoyaleHud.new()` → 场景实例化 |

---

## Task 0：建立声明式契约守卫（先写、先红）

> 这个任务**不产生任何搬迁**，只立闸门。它先红（`royale_hud.tscn` 还不存在），Task 1 做完转绿。
> 没有它，后面三个任务都会以「节点路径打错 → 运行期 null 解引用」的方式静默失败——`kh_l6` 第 10 条记录的 B11 就是这个。

**Files:**
- Create: `tests/hud_declarative_probe.gd`
- Create: `tests/hud_declarative_probe.tscn`

**Interfaces:**
- Consumes: `tests/lib/probe_base.gd`（`class_name ProbeBase extends Node`，提供 `_check(ok, msg)` / `_summary(fails_before, msg)` / `_finish()` / `_read(path)` / `_code_only(src)`；子类**必须**覆写 `probe_id() -> String`）。
- Produces: 判据行 `KH HUD PROBE: ALL-OK`。Task 1/2/3 各自往 `PAIRS` 里加一行。

- [ ] **Step 1: 写探针脚本（此时 PAIRS 里先放一行，指向还不存在的场景）**

创建 `tests/hud_declarative_probe.gd`：

```gdscript
extends ProbeBase

# 声明式 HUD 契约守卫(阶段:UI 代码生成节点搬进 .tscn)。
#
# 守的是什么:凡「由 .tscn 声明节点、脚本只 @onready 取」的界面,
#   ① 宿主必须用 (load/preload(...tscn)).instantiate() 建,**绝不** <类>.new();
#   ② 脚本里每个 `@onready var x = $A/B/C` 的**叶子名** C,必须在配套 .tscn 里
#      有 `[node name="C"` 声明。
# 为什么值一条探针:.new() 建出来的节点**没有子节点**,而声明式脚本的 _ready 会直接
#   解引用它们 → 硬崩溃。这不是假设 —— tests/kh_l6_probe.gd 第 10 条记的正是 B11
#   (pvp_hud 那次)。本探针把同一份契约扩到后续搬的三套;kh_l6 第 10 条仍只守 pvp_hud,
#   **不要去改它**(改一条已绿的探针收益低于风险)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn
# 判据:末行 "KH HUD PROBE: ALL-OK"(grep 文本,不看退出码)。
#
# ★ 注意本文件是源码级探针,但被 kh_l4/kh_l5 的字号扫描覆盖(res://tests 在 ALL_DIRS 里)
#   —— 正文里不许出现非 16 倍数的字号载体字面量。本文件没有字号,安全。

# [脚本, 配套 tscn, 类名] —— 每搬一套加一行
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
]

# 参数下限:防止 PAIRS 被误删成空表 → 零循环 → 恒绿
const MIN_PAIRS := 1

# @onready var <名>[: 类型] = $<路径>   → 捕获组 2 = 路径
const RE_ONREADY := "@onready\\s+var\\s+(\\w+)\\s*(?::\\s*[\\w\\[\\]]+\\s*)?=\\s*\\$([\\w/]+)"


func probe_id() -> String:
	return "HUD"


func _ready() -> void:
	var before := _failures.size()
	_check(PAIRS.size() >= MIN_PAIRS,
			"PAIRS 只剩 %d 组(判据退化:至少要有 %d 组,否则本探针变成恒绿)" % [PAIRS.size(), MIN_PAIRS])
	for p in PAIRS:
		_check_pair(str(p[0]), str(p[1]), str(p[2]))
	_summary(before, "声明式契约:扫 %d 组「脚本 ↔ 场景」,零 .new()、@onready 路径全声明" % PAIRS.size())
	_finish()


func _check_pair(script_path: String, tscn_path: String, cls: String) -> void:
	var before := _failures.size()
	var exists := ResourceLoader.exists(tscn_path)
	_check(exists, "%s 不存在(%s 声称自己走声明式场景,却没有配套 tscn)" % [tscn_path, script_path])
	if not exists:
		_summary(before, "%s:场景缺失,跳过" % script_path)
		return
	var code := _code_only(_read(script_path))
	var tscn := _read(tscn_path)
	_check(not code.is_empty(), "读不到 %s" % script_path)
	if code.is_empty() or tscn.is_empty():
		_summary(before, "%s:读文件失败" % script_path)
		return

	# ① 全文不得出现 <类>.new(
	var re_new := RegEx.new()
	re_new.compile("\\b" + cls + "\\.new\\(")
	var hits := re_new.search_all(code)
	_check(hits.is_empty(),
			"%s 里出现 %s.new( 共 %d 处(声明式脚本不能用 .new():建出来的节点没有子节点,_ready 解引用必崩)" % [
					script_path, cls, hits.size()])

	# ② @onready $路径 的叶子名必须在 tscn 里声明
	var re := RegEx.new()
	re.compile(RE_ONREADY)
	var paths := re.search_all(code)
	_check(paths.size() >= 1,
			"%s 的 @onready $子节点 解析出 %d 个(判据可能退化成恒绿:一个 $路径都没有)" % [script_path, paths.size()])
	var missing: Array[String] = []
	for m in paths:
		var leaf: String = (m.get_string(2) as String).split("/")[-1]
		if not tscn.contains("[node name=\"" + leaf + "\""):
			missing.append(leaf)
	_check(missing.is_empty(),
			"%s 的 @onready 子节点 %s 在 %s 里没有声明(契约破了 → 运行期解引用 null)" % [
					script_path, ", ".join(missing), tscn_path])
	_summary(before, "%s ↔ %s:%d 个 @onready 子节点全声明、零 %s.new(" % [
			script_path, tscn_path, paths.size(), cls])
```

- [ ] **Step 2: 写场景包装（场景模式探针的固定壳）**

创建 `tests/hud_declarative_probe.tscn`：

```
[gd_scene load_steps=2 format=3 uid="uid://huddeclprobe0001"]

[ext_resource type="Script" path="res://tests/hud_declarative_probe.gd" id="1"]

[node name="HudDeclarativeProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 跑一次，确认它**红**（这是 TDD 的「先看它失败」）**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | tail -20
```

期望：打印 `ui/royale_hud.tscn 不存在(...)` 与 `KH HUD PROBE: FAIL | ...`，退出码 1。

> ⚠️ 如果这里**打印了 ALL-OK**，说明 `ResourceLoader.exists` 或 `PAIRS` 写错了 —— 先修探针，别往下走。

- [ ] **Step 4: 提交**

```bash
git add tests/hud_declarative_probe.gd tests/hud_declarative_probe.tscn
git commit -m "test(hud): 声明式 HUD 契约守卫(脚本↔场景配对/零 .new()/@onready 路径全声明)

B11 那次(pvp_hud 的 .new() → _ready 解引用 null)只有 kh_l6 第 10 条守着,且只守
pvp_hud 一个。后续三套界面要搬进 tscn,先把这个契约变成可复用的探针。
当前红灯是预期的:royale_hud.tscn 还没建。"
```

---

## Task 1：`royale_hud` 搬进 `.tscn`

**收益最高的一项**：它建的四个区块与 `pvp_hud.tscn` 逐节点同构（遮罩 0.3 / CenterContainer / BigLabel 144 / SubLabel 64 / PingWrap+Plate），搬完等于把一份已验证过的树复用两次，并消灭 `1920 - BOARD_W - 16` 这种硬编码屏幕坐标（`royale_hud.gd:74`、`:79`）。

**Files:**
- Create: `ui/royale_hud.tscn`
- Modify: `ui/royale_hud.gd`（删 `_build_board` / `_build_broadcast` / `_build_ping` / `_build_hint` / `var _board_title`；加 `@onready` 块）
- Modify: `scenes/royale_game.gd:86`
- Modify: `tests/combat_hud_visual_probe.gd:45`
- Modify: `tests/royale_hud_cost_probe.gd:44`
- Modify: `tests/hud_declarative_probe.gd`（`PAIRS` 加行）

**Interfaces:**
- Consumes: `PixelFont.shared()`（`core/present/pixel_font.gd`，静态，返回共享 `FontFile`）；`UiFactory.C_ACCENT` = `Color(0.349, 0.851, 0.902)`、`UiFactory.C_TEXT` = `Color(0.878, 0.914, 0.949)`、`UiFactory.C_TEXT_DIM` = `Color(0.510, 0.573, 0.639)`。
- Produces: `class_name RoyaleHud` 保持不变（`kh_l5_probe.gd:549` 有正断言）；成员名 `_board_bg` / `_board_vbox` / `_timer_label` / `_mask` / `_center` / `_big` / `_sub` / `_ping_label` / `_rows` 全部保持（`combat_hud_visual_probe.gd` 读 `royale._rows`、`royale._board_bg`）。

> **★ 尺寸换算（1920×1440 视口，`window/stretch/mode="viewport"`，换算后位置与现在完全等价）：**
> `BOARD_W = 720.0`
> - `BoardBg`：右锚（`anchor_left = anchor_right = 1.0`），`offset_left = -(720+16) = -736`，`offset_right = -16`，`offset_top = 96`，`offset_bottom = 160`（初始高 64，运行期由 `_refresh_board` 重算）
> - `BoardBox`：右锚，`offset_left = -(720-4) = -716`，`offset_right = -4`，`offset_top = 102`，`offset_bottom = 102` + `grow_vertical = 1`
> - `PingWrap`：四锚 1.0 + `grow 0/0`，四个 `offset = -24`（**照抄 `pvp_hud.tscn` 的 PingWrap**）
> - `HintWrap`：左下锚（`anchor_top = anchor_bottom = 1.0`），`offset_left = 16`，`offset_right = 16`，`offset_top = -54`（= 1386-1440），`offset_bottom = -30`（= 1410-1440），`grow_horizontal = 1`、`grow_vertical = 0`

- [ ] **Step 1: 往 `PAIRS` 加一行**（让守卫开始覆盖这一项，此刻仍是红的）

`tests/hud_declarative_probe.gd`：

```gdscript
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
]
```

（本步只是确认它仍在红 —— Step 3 建出场景后转绿。）

- [ ] **Step 2: 写 `ui/royale_hud.tscn`**

```
[gd_scene load_steps=3 format=3 uid="uid://royalehud000001"]

[ext_resource type="Script" path="res://ui/royale_hud.gd" id="1"]
[ext_resource type="FontFile" path="res://assets/fonts/less_perfect_dos_vga.ttf" id="2"]

[node name="RoyaleHud" type="CanvasLayer"]
layer = 130
script = ExtResource("1")

[node name="BoardBg" type="ColorRect" parent="."]
anchor_left = 1.0
anchor_right = 1.0
offset_left = -736.0
offset_top = 96.0
offset_right = -16.0
offset_bottom = 160.0
grow_horizontal = 0
mouse_filter = 2
color = Color(0, 0, 0, 0.25)

[node name="BoardBox" type="VBoxContainer" parent="."]
anchor_left = 1.0
anchor_right = 1.0
offset_left = -716.0
offset_top = 102.0
offset_right = -4.0
offset_bottom = 102.0
grow_horizontal = 0
grow_vertical = 1
mouse_filter = 2
theme_override_constants/separation = 4

[node name="BoardTitle" type="Label" parent="BoardBox"]
theme_override_colors/font_color = Color(0.349, 0.851, 0.902, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 32
text = "—— 击杀排行榜 ——"

[node name="TimerLabel" type="Label" parent="BoardBox"]
theme_override_colors/font_color = Color(0.878, 0.914, 0.949, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 32

[node name="Mask" type="ColorRect" parent="."]
visible = false
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2
color = Color(0, 0, 0, 0.3)

[node name="Center" type="CenterContainer" parent="."]
visible = false
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2

[node name="VBox" type="VBoxContainer" parent="Center"]
mouse_filter = 2
alignment = 1

[node name="BigLabel" type="Label" parent="Center/VBox"]
theme_override_colors/font_color = Color(0.878, 0.914, 0.949, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 144

[node name="SubLabel" type="Label" parent="Center/VBox"]
theme_override_colors/font_color = Color(0.51, 0.573, 0.639, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 64

[node name="PingWrap" type="PanelContainer" parent="."]
anchor_left = 1.0
anchor_top = 1.0
anchor_right = 1.0
anchor_bottom = 1.0
offset_left = -24.0
offset_top = -24.0
offset_right = -24.0
offset_bottom = -24.0
grow_horizontal = 0
grow_vertical = 0
mouse_filter = 2

[node name="PingLabel" type="Label" parent="PingWrap"]
theme_override_colors/font_color = Color(0.51, 0.573, 0.639, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 32
text = "延迟 -- ms"

[node name="HintWrap" type="PanelContainer" parent="."]
anchor_top = 1.0
anchor_bottom = 1.0
offset_left = 16.0
offset_top = -54.0
offset_right = 16.0
offset_bottom = -30.0
grow_horizontal = 1
grow_vertical = 0
mouse_filter = 2

[node name="HintLabel" type="Label" parent="HintWrap"]
theme_override_colors/font_color = Color(0.51, 0.573, 0.639, 1)
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 16
text = "K = 自杀脱困(卡住时)"
```

> **★ 子节点顺序 = 绘制顺序，必须与现在的 `add_child` 顺序一致**：`BoardBg → BoardBox → Mask → Center → PingWrap → HintWrap`。
> 现在的代码是「先 `_build_board`（bg+vbox），再 `_build_broadcast`（mask+center），再 ping、再 hint」——**`Mask` 盖在排行榜之上**是现状，照抄。
> `_rows` 由代码 `add_child` 到 `BoardBox`，所以它们排在 `TimerLabel` 之后（与现在一致）。

> **★ 这里用 0.25 / 0.3 两个 `ColorRect.color` 字面量，是**有意的**：`ColorRect` 的颜色是节点自带属性，场景里写它不引入第二处调色板常量（`pvp_hud.tscn` 的 `Mask` 已有先例）。**但两块 `PanelContainer` 的 `StyleBoxFlat` 不在场景里** —— 见 Step 3。

- [ ] **Step 3: 改 `ui/royale_hud.gd`**

把 `_ready` 之前插入 `@onready` 块，并**删掉** `_build_board` / `_build_broadcast` / `_build_ping` / `_build_hint` 四个函数与 `var _board_title: Label`（它在旧代码里只被赋值、从未被读）。

替换 `_ready`（原 `ui/royale_hud.gd:52-64`）：

```gdscript
@onready var _board_bg: ColorRect = $BoardBg
@onready var _board_vbox: VBoxContainer = $BoardBox
@onready var _timer_label: Label = $BoardBox/TimerLabel
@onready var _mask: ColorRect = $Mask
@onready var _center: CenterContainer = $Center
@onready var _big: Label = $Center/VBox/BigLabel
@onready var _sub: Label = $Center/VBox/SubLabel
@onready var _ping_wrap: PanelContainer = $PingWrap
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _hint_wrap: PanelContainer = $HintWrap


func _ready() -> void:
	layer = LAYER
	# ★ 一次:共享字体关抗锯齿/微调/子像素并挂 CJK 回退链。场景里那些 Label 引用的
	#   就是同一个共享 FontFile 实例 —— 不调这句,它们会带抗锯齿、且**汉字没有回退字形**
	#   (本 HUD 的字全是中文:排行榜标题/存活/复活中/离开)。同 pvp_hud.gd:26。
	PixelFont.shared()
	_my_name = PvpSession.player_name
	# 两块底板样式**仍由代码给**:颜色 token(C_*)的唯一来源是 UiFactory,
	# 抄进 .tscn 就是第二处真值(见 ui_factory.gd 文件头第 1 条纪律)。
	_ping_wrap.add_theme_stylebox_override("panel", _plate_box(14.0, 6.0))
	_hint_wrap.add_theme_stylebox_override("panel", _plate_box(10.0, 4.0))
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_set_broadcast(true, "大乱斗", "等待开局…")
```

**保持不变**：`_plate_box`、`_make_label`、`_fit_name`、`_set_broadcast`、`show_notice`、`_process`、`_on_ping`、`_on_round_state`、`_refresh_board`、`_refresh_broadcast`，以及 `_rows` / `_last_row_count` / `_state` / `_countdown` / `_in_countdown` / `_my_name` 这些成员。

> **★ 别把 `_make_label(32, COLOR_BOARD)` 里的 `32` 挪进变量或常量。** `kh_l5_probe.gd:365-367` 有一条断言：字号扫描**必须**在 `res://ui/royale_hud.gd` 里碰到载体（`census.has(p)`）。搬走 `_build_*` 之后，`_refresh_board` 里这处 `_make_label(32, …)` 的**实参 32**（B 类：helper 实参，由函数体 `style_control(l, size)` 机械推导）就是该文件剩下的唯一字号载体。挪进变量 → 扫描不到 → 探针红。

- [ ] **Step 4: 改宿主 `scenes/royale_game.gd:86`**

```gdscript
	# HUD(左上角击杀排行榜)+ Esc 菜单
	# ★ 声明式场景实例化,不能 RoyaleHud.new() —— 那个建出来的 CanvasLayer 没有子节点,
	#   HUD 的 _ready 会解引用 null(B11,见 tests/hud_declarative_probe 与 kh_l6 第 10 条)。
	_hud = preload("res://ui/royale_hud.tscn").instantiate() as RoyaleHud
	add_child(_hud)
```

- [ ] **Step 5: 改两个探针的 `.new()` 调用点**（同一个 B11，只是发生在测试里）

`tests/combat_hud_visual_probe.gd:45`：

```gdscript
	var royale: RoyaleHud = (load("res://ui/royale_hud.tscn") as PackedScene).instantiate() as RoyaleHud
```

`tests/royale_hud_cost_probe.gd:44`（在 `_measure(n)` 里）：

```gdscript
	var hud := (load("res://ui/royale_hud.tscn") as PackedScene).instantiate() as RoyaleHud
```

> 用 `load` 而不是 `preload`：这两处是探针，保持与 `combat_hud_visual_probe.gd:22` 已有的 `const PVP_HUD_SCENE := "res://ui/pvp_hud.tscn"` + `load(...)` 同款写法（`pvp_hud_layout_probe.gd:32` 也是 `load`）。生产侧 `royale_game.gd` 用 `preload`（同文件已在用 `preload` 建 replica）。

- [ ] **Step 6: 跑守卫探针，确认转绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | tail -20
```

期望：`[HUD] ✓ ui/royale_hud.gd ↔ res://ui/royale_hud.tscn:10 个 @onready 子节点全声明、零 RoyaleHud.new(` 且末行 `KH HUD PROBE: ALL-OK`。

- [ ] **Step 7: 跑回归探针**

```bash
# ① headless 启动无脚本错误(最便宜的"有没有拼错节点路径")
"$GODOT" --headless --path . --quit-after 90 2>&1 | grep -iE "error|SCRIPT" | head

# ② 行复用与耗时(这条同时守住"排行榜行没有被改成每次重建")
"$GODOT" --headless --path . --quit-after 3600 res://tests/royale_hud_cost_probe.tscn 2>&1 | tail -20

# ③ 真实渲染的版式验收(**不能加 --headless**)
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn 2>&1 | tail -30
```

期望：① 零命中；② `ROYALE HUD COST PROBE: ALL-OK`；③ `COMBAT HUD VISUAL PROBE: ALL-OK`，并打印「态3 底板 = …」那行。

- [ ] **Step 8: 人眼验收取图**（这一步**必须自己看图**，别把图推给别人）

打开 ③ 存下的 `_hud_3_royale_board.png`（以及终局态的 `_hud_4_*.png`），逐条核对：

- 排行榜底板仍在**右上角**、标题「—— 击杀排行榜 ——」在**最上方**、计时行在其下、行之间不错位
- 中文**没有变方框/tofu**（`PixelFont.shared()` 生效的证据）、笔画是**硬边**不是糊的
- 底部留白与之前一致（底板下沿与末行之间那一截）
- 延迟条在**右下角**、按键提示在**左下角**、中央广播的遮罩/大字位置对

任何一条不对 → 回到 Step 2/3 对锚点，**别改数值**（Global Constraints 第 3 条）。

- [ ] **Step 9: 提交**

```bash
git add ui/royale_hud.tscn ui/royale_hud.gd scenes/royale_game.gd \
        tests/combat_hud_visual_probe.gd tests/royale_hud_cost_probe.gd \
        tests/hud_declarative_probe.gd
git commit -m "refactor(ui): royale_hud 的四个静态区块迁进 royale_hud.tscn

与 pvp_hud.tscn 逐节点同构的四块(排行榜骨架/广播层/延迟/按键提示)从 _ready 里
的 new() 搬进场景;脚本只留 @onready 与数据驱动逻辑(行池、底板高度、广播文案)。
顺带消灭 robale_hud.gd 里硬编码的 1920 屏幕坐标,改走右锚/下锚。

★ 两处宿主(RoyaleHud.new())同步改场景实例化 —— 声明式脚本用 .new() 建出来的节点
  没有子节点,_ready 解引用必崩(kh_l6 第 10 条的 B11,同一类)。
★ _ready 补 PixelFont.shared():场景里的 Label 引用的是共享 FontFile 实例,不调这句
  它们带抗锯齿、且汉字没有回退字形(本 HUD 全中文)。"
```

---

## Task 2：`combat_feedback` 的 `_ready` 布局搬进 `.tscn`

70 行纯几何 + 主题，**零数据依赖**。而且它正是「静默失效的 theme 键」那个坑的现场：`ui_factory.gd:33` 记着 `RichTextLabel` 读 `normal_font` / `normal_font_size`（不是 `font` / `font_size`），传进工厂**不报错但不生效** —— 所以这个文件至今手抄 8 行 override。进场景后是显式资源赋值。

**Files:**
- Create: `ui/combat_feedback.tscn`
- Modify: `ui/combat_feedback.gd`（`_ready` 的 112-181 行那段；`spawn()`；删 `const PIXEL_FONT`）
- Modify: `tests/hud_declarative_probe.gd`（`PAIRS` 加行）

**Interfaces:**
- Consumes: `PixelFont.shared()`；内部类 `HitMarker` / `KillSkull`（**保持内部类，不搬**）。
- Produces: 成员名 `_marker` / `_kill_label` / `_skull` / `_streak_label` / `_hit_age` / `_kill_age` **必须保持** —— `tests/feedback_probe.gd:98,104,107` 与 `tests/kh_visual_probe.gd:149,155,161,167` 直接读它们。静态入口 `spawn(host)` 名字不变（`kh_l4_probe` 第 2 条断言 `CombatFeedback.spawn(` 在生产路径**恰好 1 处**且必须落在 `res://scenes/level_0.gd`）。

> **★ 为什么 `HitMarker` / `KillSkull` 不搬进场景**：它们是 `_draw()` 自绘控件（`combat_feedback.gd:246`、`:263` 的内部类），场景化零收益；而且**内部类不能在 `.tscn` 里当节点脚本**。方案是场景里预留两个**空槽位**，代码建好实例往里塞 —— 槽位决定 z 序，顺序写在场景里、看得见。
> **★ 现在的 z 序**（= `add_child` 顺序）：`_marker`(X 标记) → `_kill_label`(击杀文字) → `_skull`(骷髅) → `_streak_label`(连杀数)。槽位必须按这个顺序声明，否则 X 标记会盖到文字上。

> **★ `spawn()` 必须用 `load()`，不能用 `preload()`** —— 这个脚本 `preload` 自己的场景会形成「脚本 → 场景 → 脚本」的循环引用，Godot 解析期报错。本项目其余场景的加载方都是**另一个文件**，所以只有这里需要让步。

- [ ] **Step 1: 往 `PAIRS` 加第二行**

```gdscript
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
	["res://ui/combat_feedback.gd", "res://ui/combat_feedback.tscn", "CombatFeedback"],
]
```

同时把 `MIN_PAIRS` 改成 `2`。

- [ ] **Step 2: 跑守卫，确认新这一行是红的**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | tail -20
```

期望：`ui/combat_feedback.tscn 不存在(...)`，其余行仍是 ✓。

- [ ] **Step 3: 写 `ui/combat_feedback.tscn`**

```
[gd_scene load_steps=3 format=3 uid="uid://combatfx0000001"]

[ext_resource type="Script" path="res://ui/combat_feedback.gd" id="1"]
[ext_resource type="FontFile" path="res://assets/fonts/less_perfect_dos_vga.ttf" id="2"]

[node name="CombatFeedback" type="CanvasLayer"]
layer = 131
script = ExtResource("1")

[node name="Root" type="Control" parent="."]
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2

[node name="HitMarkerSlot" type="Control" parent="Root"]
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2

[node name="KillLabel" type="RichTextLabel" parent="Root"]
modulate = Color(1, 1, 1, 0)
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -600.0
offset_top = -166.0
offset_right = 600.0
offset_bottom = -66.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2
bbcode_enabled = true
scroll_active = false
horizontal_alignment = 1
vertical_alignment = 1
theme_override_colors/default_color = Color(0.55, 0.95, 1, 1)
theme_override_colors/font_outline_color = Color(0.05, 0.08, 0.12, 0.95)
theme_override_constants/outline_size = 16
theme_override_fonts/normal_font = ExtResource("2")
theme_override_fonts/bold_font = ExtResource("2")
theme_override_font_sizes/normal_font_size = 64
theme_override_font_sizes/bold_font_size = 64

[node name="SkullSlot" type="Control" parent="Root"]
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -40.0
offset_top = -40.0
offset_right = 40.0
offset_bottom = 40.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2

[node name="StreakLabel" type="Label" parent="Root"]
modulate = Color(1, 1, 1, 0)
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = 44.0
offset_top = -24.0
offset_right = 300.0
offset_bottom = 24.0
grow_horizontal = 2
grow_vertical = 2
theme_override_colors/font_color = Color(1, 0.84, 0.43, 1)
theme_override_colors/font_outline_color = Color(0.05, 0.08, 0.12, 0.95)
theme_override_constants/outline_size = 10
theme_override_fonts/font = ExtResource("2")
theme_override_font_sizes/font_size = 48
```

> **★ 四处必须是 `normal_font` / `normal_font_size`**（`RichTextLabel` 的键），不是 `font` / `font_size`。写错了不报错、只是字体不生效 —— 这正是 `ui_factory.gd:33` 记的那个坑。
> `horizontal_alignment = 1` 是 `HORIZONTAL_ALIGNMENT_CENTER`，`vertical_alignment = 1` 是 `VERTICAL_ALIGNMENT_CENTER`（原子节点两个都设了）。
> `modulate = Color(1, 1, 1, 0)` 对应原代码的 `modulate.a = 0.0`（两个标签初始不可见，靠 `_process` 里的 tween/直接赋值浮现）。
> `outline_size` 不在字号闸门里（`kh_l4` 的 C 类正则要求含 `font_size`），但 16 / 10 照抄原值。

- [ ] **Step 4: 改 `ui/combat_feedback.gd`**

**删掉** `const PIXEL_FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"`（原第 16 行；搬进场景后本文件不再用它，全仓无别处引用）。

**替换** `spawn()`（原 `ui/combat_feedback.gd:25-29`）：

```gdscript
## 由对局场景挂载(重复调用安全;换局由 _exit_tree 自清)
## 幂等判据不能只看 current 是否存在:换场时(safe_change_scene 先 add_child 新场景、后 remove_child 旧世界)
## 旧实例仍在树上且仍是 current,只看存在性会让新世界提前 return → 反馈层静默消失。
## 故须满足「current 有效 **且** 已是本 host 的后代」才幂等返回。
##
## ★ 用 load 而非 preload:本场景的 ext_resource 指回本脚本,preload 会构成
##   「脚本 → 场景 → 脚本」的循环引用,Godot 解析期直接报错。运行期 load 不参与解析,
##   且资源只载一次(引擎缓存)。
static func spawn(host: Node) -> void:
	if current != null and is_instance_valid(current) and host.is_ancestor_of(current):
		return
	var fx: CombatFeedback = load("res://ui/combat_feedback.tscn").instantiate() as CombatFeedback
	host.add_child.call_deferred(fx)
```

**替换** `_ready()`（原 `ui/combat_feedback.gd:112-181`，整段替换）：

```gdscript
@onready var _kill_label: RichTextLabel = $Root/KillLabel
@onready var _streak_label: Label = $Root/StreakLabel


func _ready() -> void:
	layer = LAYER
	current = self
	process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停时动画也能收尾
	# 一次:共享字体关抗锯齿/微调/子像素并挂 CJK 回退链。场景里的两个 Label 引用的
	# 就是同一个共享 FontFile 实例 —— 不调这句,它们带抗锯齿、且汉字没有回退字形
	# (本层必画中文:「击杀 测试鸟」)。同 pvp_hud.gd:26。
	PixelFont.shared()
	# 两个自绘控件(X 标记 / 击杀骷髅)保持内部类、由代码建,挂进场景预留的**槽位** ——
	# ★ 槽位在 .tscn 里按声明顺序决定 z 序,顺序必须与搬迁前一致:
	#   HitMarkerSlot(X 标记,在最下) → KillLabel → SkullSlot → StreakLabel。
	#   提前 add_child 不走 move_child,顺序天然对齐。
	_marker = HitMarker.new()
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	$Root/HitMarkerSlot.add_child(_marker)

	_skull = KillSkull.new()
	_skull.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.visible = false
	$Root/SkullSlot.add_child(_skull)
```

**保持不变**：`_exit_tree`、`_show_hit`、`_show_kill`、`_process`、`attribute`、`attribute_hit`、`notify_enemy_killed`、`enemy_display_name`、`hit_marker`、`kill`、`reset_streak`、`current`、`HitMarker`、`KillSkull` 两个内部类，以及所有 `var _marker: HitMarker` / `var _skull: KillSkull` 声明（**类型标注照旧**：内部类仍在同一文件里，`HitMarker` 这个名字仍然可解析）。

- [ ] **Step 5: 跑守卫，确认转绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn 2>&1 | tail -20
```

期望：两组都 ✓，末行 `KH HUD PROBE: ALL-OK`。

- [ ] **Step 6: 跑回归探针**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/feedback_probe.tscn 2>&1 | tail -25
```

期望：打印 `FEEDBACK PROBE: ALL-OK(击杀播报/X 标记/归因/音效 全部通过)`。它会走 `spawn` → 读 `_fx._marker.visible`、`_fx._kill_label.text`、`_fx._kill_label.modulate.a` —— 这条路绿灯即证明三个成员名与行为都没漂。

另外跑一次真实渲染的截图探针，人眼确认 X 标记与击杀文字的相对层级没反：

```bash
"$GODOT" --path . --quit-after 3600 res://tests/kh_visual_probe.tscn 2>&1 | tail -20
```

打开它存的击杀播报截图，确认**骷髅在文字右侧**、**X 标记在文字之下**（不是盖在「击杀 XXX」上面）。

- [ ] **Step 7: 提交**

```bash
git add ui/combat_feedback.tscn ui/combat_feedback.gd tests/hud_declarative_probe.gd
git commit -m "refactor(ui): combat_feedback 的布局段迁进 combat_feedback.tscn

_ready 里 70 行纯几何+主题(root/RichTextLabel/连杀 Label 的锚点与 8+7 条 theme
override)搬进场景。RichTextLabel 走 normal_font/normal_font_size —— 这两个键写错
不报错只是静默失效(ui_factory.gd:33 记过),进场景后是显式资源赋值。

★ HitMarker/KillSkull 保持内部类不搬(_draw 自绘、且内部类不能在 tscn 里当节点
  脚本):场景预留两个空槽位决定 z 序,顺序与原 add_child 一致。
★ spawn() 改 load() 而非 preload() —— 脚本 preload 自己的场景是循环引用,解析期报错。"
```

---

## Task 3：主菜单两个弹出面板的骨架搬进 `.tscn`

**收益中等、风险也中等。** 搬的是**容器骨架**（`PanelContainer` / `VBoxContainer` / `ScrollContainer` / 标签 / 锚点），**不是**按钮与勾选框 —— 那些走 `UiFactory`，搬进场景反而要在使用处补 `style_control + style_button`，把「控件工厂唯一来源」散回各处。

**Files:**
- Create: `ui/version_panel.tscn`
- Create: `ui/sp_launch_panel.tscn`
- Modify: `scenes/main_menu.gd`（`_build_ver_panel` → `_fill_version_panel`；`_build_sp_panel` → `_fill_sp_panel`）

**Interfaces:**
- Consumes: `UiFactory.panel_box()` / `UiFactory.label(text, size, color)` / `UiFactory.button(text, size, min_size)`；`commit_log()`（同文件静态）；`version_string()`（同文件静态）；`WeaponIcons.silhouette(slot)`；`Settings.sp_disabled_weapons`。
- Produces: 保持 `_sp_panel` / `_ver_panel` 两个成员与「首次点击才建、再点 toggle」的行为（`menu_autotest.gd` 的 `-- --autotest-sp` / `-- --autotest-ver` 按**按钮文本**递归找按钮，不看路径，搬容器安全）。

> **★ `UiFactory.panel_box()` 必须留在代码里。** `version_panel.tscn` 的 `PanelContainer` **不写** `StyleBox`；`_fill_version_panel` 里 `panel.add_theme_stylebox_override("panel", UiFactory.panel_box())`。抄进场景就是把 `C_SURFACE` / `C_BORDER` 变成第二处真值。
> （`_build_sp_panel` 现在**没有**给 panel 覆写 StyleBox —— 用默认主题。**照旧，不要顺手加**，那是另一件事。）
> **★ 子容器顺序 = 声明顺序。** 数据驱动的节点由代码 `add_child` 到**场景里预留的容器**，所以要给它们留位置：版本面板的 `Scroll/List`、单人面板的 `CheckList`，都必须声明在需要排在它们**之后**的节点前面。直接 `vb.add_child(cb)` 会追加到 `ButtonRow` **之后** —— 按钮行会跑到武器勾选上面去。

- [ ] **Step 1: 写 `ui/version_panel.tscn`**

```
[gd_scene load_steps=2 format=3 uid="uid://versionpanel0001"]

[ext_resource type="FontFile" path="res://assets/fonts/less_perfect_dos_vga.ttf" id="1"]

[node name="VersionPanel" type="PanelContainer"]
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
grow_horizontal = 2
grow_vertical = 2

[node name="VBox" type="VBoxContainer" parent="."]
custom_minimum_size = Vector2(1180, 0)
theme_override_constants/separation = 10

[node name="Title" type="Label" parent="VBox"]
theme_override_colors/font_color = Color(0.349, 0.851, 0.902, 1)
theme_override_fonts/font = ExtResource("1")
theme_override_font_sizes/font_size = 48
text = "—— 版本信息 ——"

[node name="VersionLabel" type="Label" parent="VBox"]
theme_override_fonts/font = ExtResource("1")
theme_override_font_sizes/font_size = 32

[node name="Scroll" type="ScrollContainer" parent="VBox"]
custom_minimum_size = Vector2(1100, 620)

[node name="List" type="VBoxContainer" parent="VBox/Scroll"]
custom_minimum_size = Vector2(1100, 0)
theme_override_constants/separation = 6

[node name="BackRow" type="HBoxContainer" parent="VBox"]
alignment = 1
```

> `ROW_W = 1100.0` 那个常量**留在 `main_menu.gd`**（它给的是日志行的 `custom_minimum_size`，与 `Scroll`/`List` 的 `custom_minimum_size` 同值 —— 原代码里就是两处独立的字面量，照旧）。
> `Title` / `VersionLabel` 不写 `mouse_filter`：`Label` 在 Godot 4 默认就是 `MOUSE_FILTER_IGNORE`，与 `UiFactory.label` 显式设的一致。

- [ ] **Step 2: 写 `ui/sp_launch_panel.tscn`**

```
[gd_scene load_steps=2 format=3 uid="uid://splaunchpanel001"]

[ext_resource type="FontFile" path="res://assets/fonts/less_perfect_dos_vga.ttf" id="1"]

[node name="SpLaunchPanel" type="PanelContainer"]
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
grow_horizontal = 2
grow_vertical = 2

[node name="VBox" type="VBoxContainer" parent="."]
custom_minimum_size = Vector2(560, 0)
theme_override_constants/separation = 14

[node name="Title" type="Label" parent="VBox"]
theme_override_colors/font_color = Color(0.349, 0.851, 0.902, 1)
theme_override_fonts/font = ExtResource("1")
theme_override_font_sizes/font_size = 48
text = "—— 单人开局 ——"

[node name="Subtitle" type="Label" parent="VBox"]
theme_override_fonts/font = ExtResource("1")
theme_override_font_sizes/font_size = 32
text = "禁用武器(勾选 = 本局不可用)"

[node name="CheckList" type="VBoxContainer" parent="VBox"]

[node name="ButtonRow" type="HBoxContainer" parent="VBox"]
alignment = 1
theme_override_constants/separation = 24
```

> 原代码里武器勾选是**直接** `vb.add_child(cb)`（没有中间容器）、默认 separation。这里加了 `CheckList` 容器只是为了给它们一个**插在 ButtonRow 之前**的位置 —— `CheckList` 自身 separation 保持默认（0 个覆盖），与原 VBox 的 14 不同，见下一步的说明。

- [ ] **Step 3: 改 `scenes/main_menu.gd`**

在文件顶部（`const ROW_W` 附近）加：

```gdscript
const VERSION_PANEL_SCENE := preload("res://ui/version_panel.tscn")
const SP_PANEL_SCENE := preload("res://ui/sp_launch_panel.tscn")
```

`_on_version_pressed` 改为：

```gdscript
func _on_version_pressed() -> void:
	Sfx.play("ui")
	if _ver_panel != null:
		_ver_panel.visible = not _ver_panel.visible
		return
	_ver_panel = _fill_version_panel(VERSION_PANEL_SCENE.instantiate() as PanelContainer)
	_ui_layer.add_child(_ver_panel)
```

`_on_single_pressed` 改为：

```gdscript
func _on_single_pressed() -> void:
	Sfx.play("ui")
	if _sp_panel != null:
		_sp_panel.visible = not _sp_panel.visible
		return
	_sp_panel = _fill_sp_panel(SP_PANEL_SCENE.instantiate() as PanelContainer)
	_ui_layer.add_child(_sp_panel)
```

用下面两个函数**替换** `_build_ver_panel`（原 `main_menu.gd:279-328`）与 `_build_sp_panel`（原 `:332-376`）：

```gdscript
# 版本信息面板:场景给骨架(面板/滚动区/两个标签/返回行),这里只填数据与样式。
# ★ StyleBox 留在代码:调色板唯一来源是 UiFactory,抄进 .tscn 就是第二处真值。
func _fill_version_panel(panel: PanelContainer) -> PanelContainer:
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	(panel.get_node("VBox/VersionLabel") as Label).text = "当前版本: %s" % version_string()

	var list: VBoxContainer = panel.get_node("VBox/Scroll/List")
	var log := commit_log()
	if log.is_empty():
		list.add_child(UiFactory.label("(读不到 git 历史:仓库不可用或未安装 git)", 32, Color(0.9, 0.6, 0.5)))
	for i in range(log.size()):
		var e: Dictionary = log[i]
		var row := UiFactory.label("%s  %s  %s" % [str(e["hash"]), str(e["time"]), str(e["subject"])],
				16, Color(0.92, 0.95, 1.0))
		# 提交标题长短不一,最长的那条会把 Label 的**最小宽度**顶到面板之外 —— ScrollContainer
		# 不收缩子节点,于是每一行都在面板右沿被切成半个字(实测最长行约 1400px vs 面板 1180)。
		# 钉死行宽 + 末尾省略号:行宽不再由文本决定,超长标题截断而不是溢出。
		row.custom_minimum_size = Vector2(ROW_W, 0)
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		list.add_child(row)

	# 返回键不拉满面板宽度:1180 宽的横条里居中两个字符,两侧全是死区。
	var back_row: HBoxContainer = panel.get_node("VBox/BackRow")
	var back := UiFactory.button("返 回", 32, Vector2(280, 48))
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	back_row.add_child(back)
	return panel


# 单人开局面板:场景给骨架(标题/副标题/勾选列/按钮行),武器勾选与按钮仍走工厂。
func _fill_sp_panel(panel: PanelContainer) -> PanelContainer:
	var checks: Array[CheckButton] = []
	var check_list: VBoxContainer = panel.get_node("VBox/CheckList")
	for slot in [1, 2, 3, 4, 5, 6]:
		var cb := CheckButton.new()
		cb.text = "%d. %s" % [slot, WeaponComponent.DISPLAY_NAMES[slot]]
		cb.icon = WeaponIcons.silhouette(slot)   # 纯白像素剪影,便于辨认
		cb.expand_icon = false
		UiFactory.style_check(cb, 32)
		cb.button_pressed = Settings.sp_disabled_weapons.has(slot)
		checks.append(cb)
		check_list.add_child(cb)

	var row: HBoxContainer = panel.get_node("VBox/ButtonRow")
	var go := UiFactory.button("开 始 探 索", 32)
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		Settings.sp_disabled_weapons.clear()
		for i in checks.size():
			if checks[i].button_pressed:
				Settings.sp_disabled_weapons.append(i + 1)
		Settings.save()
		RunOptions.disabled_weapons = Settings.sp_disabled_weapons.duplicate()
		_enter_level0())
	var back := UiFactory.button("返回", 32)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		panel.visible = false)
	row.add_child(go)
	row.add_child(back)
	return panel
```

> **★ `CheckList` 的 separation 与原版不同，这是唯一一处「版式偏差」**：原代码 6 个 `CheckButton` 是 VBox 的直接子节点、吃 VBox 的 `separation = 14`；现在它们进了 `CheckList`，而 `CheckList` 的 separation 是默认值。**修法**：在 `ui/sp_launch_panel.tscn` 的 `CheckList` 节点上补一行 `theme_override_constants/separation = 14`，让它与原版**逐像素一致**。
> **★ `version_string()` 现在是「先给场景标签设文本」** —— 若 `VersionLabel` 在场景里被误留了 `text`，代码这行会覆盖它，不会出现双份。

- [ ] **Step 4: 补 `CheckList` 的 separation（见上一条）**

`ui/sp_launch_panel.tscn` 的 `CheckList` 节点改为：

```
[node name="CheckList" type="VBoxContainer" parent="VBox"]
theme_override_constants/separation = 14
```

- [ ] **Step 5: 跑菜单流转自动探针（两个面板各有一条）**

```bash
# 单人开局面板:主菜单→单机面板→开始探索→Esc 暂停/恢复→回主菜单→截图
"$GODOT" --path . --quit-after 3600 -- --autotest-sp 2>&1 | tail -20

# 版本信息面板:主菜单→版本信息弹层(**不切场景**)→截图
"$GODOT" --path . --quit-after 3600 -- --autotest-ver 2>&1 | tail -20
```

期望：两条都走到 `AUTOTEST[sp]: DONE` / `AUTOTEST[ver]: DONE`（`menu_autotest.gd` 按**按钮文本**递归找按钮，`_press_by_text` 不依赖容器层级）。

- [ ] **Step 6: 人眼验收两张截图**

打开 `user://autotest_sp.png` 与 `user://autotest_ver.png`（`--autotest-*` 会存到 `user://`），逐条核对：

- **sp 面板**：标题「—— 单人开局 ——」在上、副标题其下、**6 个武器勾选框在中间且行距与之前一致**、最后的「开 始 探 索 / 返回」两个按钮在**最下面一行**居中（不是跑到勾选上面去）
- **ver 面板**：标题、当前版本行、滚动区里的提交列表（**长标题在面板右沿被截断成 `…`，不是溢出**）、返回按钮居中
- 两个面板的**底色是不透明的深色**（`UiFactory.panel_box()` 生效的证据 —— 半透明面板会让下层菜单文字透上来重影）

- [ ] **Step 7: 跑一次 KH 层探针**（主菜单被 `kh_l4` 的菜单约束覆盖）

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l4_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3
```

期望：`KH L4 PROBE: ALL-OK`。

- [ ] **Step 8: 提交**

```bash
git add ui/version_panel.tscn ui/sp_launch_panel.tscn scenes/main_menu.gd
git commit -m "refactor(ui): 主菜单两个弹出面板的骨架迁进 tscn

版本信息 / 单人开局两个面板的容器骨架(PanelContainer/VBox/ScrollContainer/标签/
锚点)搬进场景;按钮与武器勾选框仍走 UiFactory —— 搬进场景就得在使用处补
style_control + style_button,等于把控件工厂的纪律散回各处。
StyleBox 也留在代码(panel_box()),场景里不抄调色板。

首次点击才建、再点 toggle 的行为不变;menu_autotest 按按钮文本找控件,不受影响。"
```

---

## Task 4：单机 HUD 击杀计数器搬进 `.tscn`

**四项里收益最小的一项（约 15 行），也是唯一可以砍掉的。** 保留它是因为你点了名，且改动本身零风险。搬的是**骨架**（`PanelContainer` 的右上角锚点 + `Label`）；`KILL_COLOR` / `KILL_FONT_SIZE` / `PLATE_COLOR` 那块 `StyleBoxFlat` **全部留在代码**，所以不会多出一份调色板字面量。

**Files:**
- Create: `ui/kill_counter.tscn`（**无脚本**）
- Modify: `ui/hud.gd`（`_build_kill_label`，原 `ui/hud.gd:405-437`）

**Interfaces:**
- Consumes: `UiFactory.style_control(c, size)` / `UiFactory.C_ACCENT`；本文件的 `PLATE_COLOR` / `KILL_COLOR` / `KILL_FONT_SIZE` / `KILL_MARGIN`。
- Produces: 成员 `_kill_label: Label` / `_kills: int` 保持不变（`_on_enemy_died` 写 `_kill_label.text`）。

> **★ 为什么是独立场景而不是塞进 `level_0.tscn`**：`tests/kh_l3_visual_probe.gd:305` 用 `Hud.new()` 建单机 HUD 来做取色断言。若把计数器节点声明进 `level_0.tscn`，`Hud.new()` 建出的节点就没有它 → 该探针立刻红，还得改成实例化整个 `level_0.tscn`（重）。独立场景由 `hud.gd` 自己 `load`，**创建方式无关**，`Hud.new()` 照旧可用。
> 附带好处：`ui/kill_counter.tscn` **没有脚本**，`ui/hud.gd` `preload` 它不构成任何环。
> **★ 这个场景里不写字体、不写颜色。** 骨架只有「`PanelContainer` 的锚点 + 一个 `Label`」；字体走 `UiFactory.style_control`（它才带 `PixelFont.shared()` 那套锐化 + CJK 回退），颜色走 `KILL_COLOR`。**写入场景 = 第三份调色板真值**，且会绕开工厂的字号纪律。

> **★ 尺寸换算**：原 `wrap.offset_left = -KILL_MARGIN.x = -32`、`offset_right = -32`（右锚，宽由文本撑开）、`offset_top = 16`、`offset_bottom = 16` + `grow_horizontal = BEGIN(0)`、`grow_vertical = END(1)`。

- [ ] **Step 1: 写 `ui/kill_counter.tscn`**

```
[gd_scene format=3 uid="uid://killcounter00001"]

[node name="KillCounter" type="PanelContainer"]
anchor_left = 1.0
anchor_right = 1.0
offset_left = -32.0
offset_top = 16.0
offset_right = -32.0
offset_bottom = 16.0
grow_horizontal = 0
grow_vertical = 1
mouse_filter = 2

[node name="KillLabel" type="Label" parent="."]
text = "000"
```

- [ ] **Step 2: 改 `ui/hud.gd` 的 `_build_kill_label`**

在 `WEAPON_ICON_W` 常量附近加：

```gdscript
# 右上角击杀计数器的**骨架**在场景里(锚点/生长方向看得见);字体与底色仍由本文件给 ——
# 写进 .tscn 就绕开 UiFactory 的字号纪律,且 PLATE_COLOR 会变成第三份调色板真值。
const KILL_COUNTER_SCENE := preload("res://ui/kill_counter.tscn")
```

用下面这段**替换**原 `_build_kill_label`（`ui/hud.gd:405-437` 整体）：

```gdscript
# 右上角击杀计数:初始 000,每死一个敌人 +1(三位零填充)。
func _build_kill_label() -> void:
	# 底板 2026-09-15 按用户要求去掉过、同日又按用户要求垫回(见 PLATE_COLOR)。
	# ⚠ **底色必须显式给**:StyleBoxFlat 的默认底色是**不透明灰 (0.6,0.6,0.6,1.0)**、
	#   `draw_center` 默认 true —— 想"去掉底色"却只删掉 `bg_color` 赋值那一行,等于把半透明
	#   黑板换成一块**实心灰板**(比原来还显眼;实测发过一版,用户当场看出「右上角怎么还有框」)。
	#   当时是靠 `draw_center = false` 救的,现在底色回来了就不要那行。
	var wrap := KILL_COUNTER_SCENE.instantiate() as PanelContainer
	var sb := StyleBoxFlat.new()
	sb.bg_color = PLATE_COLOR
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	wrap.add_theme_stylebox_override("panel", sb)

	_kill_label = wrap.get_node("KillLabel") as Label
	_kill_label.text = "%03d" % _kills
	_kill_label.add_theme_color_override("font_color", KILL_COLOR)
	UiFactory.style_control(_kill_label, KILL_FONT_SIZE)      # 像素字体 + 字号(16 倍数)
	call_deferred("add_child", wrap)
```

> `wrap.get_node("KillLabel")` 在 `add_child` **之前**调用是安全的：`instantiate()` 返回时子节点已经存在，`get_node` 不要求在树内。`call_deferred("add_child", wrap)` 与原实现一致（延到帧末入树）。
> `KILL_MARGIN` 常量**保留**（换成锚点后它在代码里不再被引用 —— 若 `kh_l4`/`kh_l5` 没有对它的断言，可一并删除；先保留以缩小 diff，删不删不影响行为）。

- [ ] **Step 3: 跑回归探针**

```bash
# ① 单机 HUD 的视觉/取色(它用 Hud.new() 建 HUD —— 本任务刻意保住这条路)
"$GODOT" --path . --quit-after 3600 res://tests/kh_l3_visual_probe.tscn 2>&1 | grep -E "ALL-OK|FAIL" | tail -3

# ② headless 启动无脚本错误
"$GODOT" --headless --path . --quit-after 90 2>&1 | grep -iE "error|SCRIPT" | head
```

期望：① `KH L3 VISUAL: ALL-OK`（注意这行**不带 `PROBE`**，是 KH 视觉探针自己的收尾串）；② 零命中。

- [ ] **Step 4: 人眼验收击杀计数器**

跑一次带真实渲染的单机截图（`"$GODOT" --path . --quit-after 3600 -- --autotest-level`，或直接起游戏），确认右上角的「000」：

- 仍在**右上角**、离右边缘 32px、离上边缘 16px
- 底下**有一块很淡的深色底板**（不是实心灰板 —— 见 `_build_kill_label` 的注释）
- 数字是**强调青**（`C_ACCENT`）、字是**硬边**像素

- [ ] **Step 5: 提交**

```bash
git add ui/kill_counter.tscn ui/hud.gd
git commit -m "refactor(ui): 单机 HUD 击杀计数器的骨架迁进 kill_counter.tscn

右上角计数器的锚点/生长方向从 _build_kill_label 的 12 行 offset 赋值搬进场景;
字体与底色仍由 hud.gd 给(写进 .tscn 会绕开 UiFactory 的字号纪律,且 PLATE_COLOR
会变成第三份调色板真值)。

刻意做成**无脚本的独立场景**而不是塞进 level_0.tscn:kh_l3_visual_probe 用
Hud.new() 建单机 HUD,塞进 level_0.tscn 会让它立刻红。"
```

---

## 范围外（明确不做，别顺手扩）

1. **`ui/plate_style.tres` 共享底板资源。** 底板那个 `0.1` 现在有**四处**手抄：`ui/hud.gd` 的 `PLATE_COLOR`、`ui/royale_hud.gd` 的 `_plate_box()`、`ui/pvp_hud.tscn` 的 `Plate` sub_resource、`ui/weapon_slots.gd` 的 `PLATE_COLOR`。`CLAUDE.md` 自己写着「场景里是字面量，**无法共享常量，只能人工对齐**」。一份共享 `.tres` 是真正的解法（改一处就改齐），**但它是独立的一次改动**，不在本次四项之内。本计划的口径「样式留代码」保证**不会新增第五份**。
2. **`ui/pvp_hud.gd` / `ui/pvp_hud.tscn`。** 它已经是目标形态，一个字都不动。
3. **`tests/kh_l6_probe.gd` 第 10 条。** 它继续只守 `pvp_hud`。新的三套由 `hud_declarative_probe` 守 —— 逻辑有重复，但改一条已绿的探针风险高于收益。若日后要合一，再评估。
4. **`ui/hud.gd` 其余 19 个节点**（血条段 / 氧条 / 武器框 / 槽位）。血条段数 = `max_hp`、武器框数 = 背包持有数，**数据驱动，代码生成是对的**。
5. **`ui/weapon_slots.gd` / `ui/pickup_prompt.gd` / `ui/reload_ring.gd` / `ui/enemy_hp_bar.gd` / `ui/world_label.gd`。** 纯 `_draw()` 自绘 + 世界空间，场景化零收益。
6. **`ui/minimap.gd`。** 底图必须运行期从 `current_grid` 生成，点数是数据驱动。它内部硬编码的 `1920/1440`（`:60`、`:113`）确实该换成锚点，但那是**独立的清理**，不属于「搬 tscn」。
7. **`ui/pause_menu.gd`。** 只有 28 行，且 `_init(pvp: bool)` 构造参数与 `.tscn` 的 `instantiate()` 不兼容 —— 搬它要先加 `setup(is_pvp)` 后置调用，等于顺手改接口。收益不抵风险。
8. **房间列表 / 排行榜行 / 提交历史行 / 武器勾选 / 血条段** —— 全部数量随数据变，留代码。
9. **任何数值调整。** 包括但不限于 `PLATE_COLOR` 的 0.1、`_board_bg` 那个 `+34`、`royale_hud` 的 `BOARD_W = 720`、槽位 `CELL = 22`、以及 `BigLabel` 的 144。**这是纯搬运。**

---

## 验证清单（全部四项做完后的收口）

按顺序跑完，**每条都 grep `ALL-OK` 文本**而不是看退出码：

| # | 命令 | 期望 |
|---|---|---|
| 1 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn` | `KH HUD PROBE: ALL-OK`（两组都 ✓） |
| 2 | `"$GODOT" --headless --path . --quit-after 90` | 零 `SCRIPT ERROR` |
| 3 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/feedback_probe.tscn` | `FEEDBACK PROBE: ALL-OK(击杀播报/X 标记/归因/音效 全部通过)` |
| 4 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/royale_hud_cost_probe.tscn` | `ROYALE HUD COST PROBE: ALL-OK`（行复用未破坏） |
| 5 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l4_probe.tscn` | `KH L4 PROBE: ALL-OK`（字号规范 + 零演示残留） |
| 6 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l5_probe.tscn` | `KH L5 PROBE: ALL-OK`（`royale_hud.gd` 仍在字号载体清单里） |
| 7 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/kh_l6_probe.tscn` | `KH L6 PROBE: ALL-OK`（pvp_hud 那条未被动到） |
| 8 | `"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn` | `ALL-OK` + **人眼看图** |
| 9 | `"$GODOT" --path . --quit-after 3600 res://tests/kh_l3_visual_probe.tscn` | `KH L3 VISUAL: ALL-OK`（该行不带 `PROBE`） |
| 10 | `"$GODOT" --path . --quit-after 3600 -- --autotest-sp` / `--autotest-ver` | `DONE` + **人眼看图** |

**判据**：与 `enemy_logic_smoke` 同级 —— 逐条 grep `ALL-OK`。

**回滚**：四项各自独立提交，任一任务出问题直接 `git revert <该任务的 commit>`，不影响其他三项。

---

## Self-Review（写完后自查，已执行）

1. **规格覆盖**：用户点名的 1/2/3/4 各对应 Task 1/2/3/4 ✓；四项共同需要的「契约守卫」独立成 Task 0（先写先红）✓；调查中发现的三条硬约束（`PixelFont.shared()`、`preload` 自引用环、`kh_l5` 字号载体清单）分别写进 Task 1 / Task 2 / Task 1 的警告框 ✓。
2. **占位符扫描**：无 TBD / TODO / 「类似上文」；每个改代码的步骤都给了完整代码块 ✓。
3. **类型与命名一致性**：`_marker` / `_kill_label` / `_skull` / `_streak_label`（Task 2）与 `_board_bg` / `_board_vbox` / `_timer_label` / `_mask` / `_center` / `_big` / `_sub` / `_ping_label` / `_rows`（Task 1）与 `_kill_label` / `_kills`（Task 4）与 `_sp_panel` / `_ver_panel`（Task 3）全部沿用**现状名**，与各探针的读取点逐一核对过 ✓。`_build_ver_panel` → `_fill_version_panel`、`_build_sp_panel` → `_fill_sp_panel` 两个新名字在 Task 3 内前后一致 ✓。

**已知的、写进计划但未解决的两处**（不是漏写，是明确接受）：

- **Task 3 的 `CheckList` separation** 是唯一一处「原实现里勾选是 VBox 直接子节点」的结构差异 —— 已给出补 `separation = 14` 的修法（Step 4），并要求人眼核对行距。
- **`hud_declarative_probe` 与 `kh_l6` 第 10 条逻辑重复** —— 已在「范围外」第 3 条明确记录并说明为什么本轮不合。
