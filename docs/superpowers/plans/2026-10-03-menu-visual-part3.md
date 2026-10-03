# 菜单系视觉重做（③ 换皮）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把**菜单系**（主菜单 / 设置 / 信息 / 统一大厅 / Beta / 结算页 / 暂停菜单）换成设计 §3.9 定下的「**方向 B · 遗迹青铜**」：青主色保留、琥珀做强调、面板用「外深线 + 内亮线」的凿刻压边、区块用标题带。

**Architecture:** 分两步——先把**新 token** 与**菜单专属的 stylebox 工厂**加进 `UiFactory`（HUD 一个像素都不动），再逐屏套用。每个屏一个任务，各自取图人眼验收。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`StyleBoxFlat`（无圆角、无渐变 —— 本项目用 DOS 位图字体，渐变/圆角/模糊都用不了）。

**上游设计文档：** `docs/superpowers/specs/2026-10-03-mp-lobby-unification-design.md`（下称「设计」）§3.9。
**前置：** ① `2026-10-03-mp-lobby-unification-part1-core.md`（**已完成**）、② `2026-10-03-settings-and-info-part2.md`（**必须先执行** —— 它建的 `info_menu` 是本计划的覆盖对象之一）。

## Global Constraints

- **字号必须是 16 的倍数**。在本任务里这条更要紧：`kh_l5_probe` 会扫**整个生产目录**的字号载体。
- ★★ **共享 token 一个都不许改**（用户 2026-10-03 裁定「HUD 优先」）。下列 token 被**对局内 HUD**读取，**值必须逐位不变**：
  `C_ACCENT`（`ui/hud/hud.gd:16` 击杀色、`royale_hud.gd:17` 的「我」那行等 22 处）、
  `C_TEXT` / `C_TEXT_DIM`（`hud.gd:236`、`royale_hud.gd:18` 等）、
  `C_DANGER`（`hud.gd:176`、`status_banner.gd:100`）、`C_WARN`（`hud.gd:131`）、
  `C_PLATE` / `C_SLOT_EMPTY` / `C_SLOT_FILLED` / `C_SLOT_ACTIVE` / `C_GRACE` / `C_TEAM_A` / `C_TEAM_B` / `C_MODE_TEAM` / `C_MODE_ROYALE`。
  ★ 设计 §3.9.1 的 token 表里 `C_ACCENT` 与 `C_TEXT_DIM` 写的是**另一个值** —— 那是设计文档的内部矛盾（它同时写着"HUD 一行不动"）。**以本约束为准，别照那张表改。** Task 1 会加一条守卫把这件事钉住。
- ★★ **`UiFactory.panel_box()` 的形状也不许改** —— `ui/hud/status_banner.gd:88`（**重连横幅**）在用 `panel_box(false)`。菜单要的凿刻压边走**新**的 `UiFactory.menu_panel()`。
- **颜色只在 `ui/factory/ui_factory.gd` 定义**；各屏一律引用，不写 `Color(...)` 字面量。
- 面板底必须**不透明**。
- **判据一律是文本**（`ALL-OK`），**不看退出码**。场景探针 `--quit-after 3600`。
- **不动 `ui/hud/**`**（除了"不许改它依赖的 token"这一条，本计划一行都不碰它）。
- **不动 `CLAUDE.md`**（协调者统一处理）。
- ★★ **与另一个 Claude 会话共用同一棵工作树**。**提交一律逐个文件点名 `git add`，绝不 `git add -A`**；提交前 `git status --short` 看一眼。
- ★★ **每个"改了外观"的任务都必须取图并自己读图**（本仓纪律：数值全绿而画面是坏的，抓到的全是自己看图那一步）。**别把图推回给用户。**

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `ui/factory/ui_factory.gd` | 改 | **新增** 5 个 token + `menu_panel()` / `menu_button()` / `header_strip()` 三个菜单专属工厂；**既有 token 与 `panel_box()` 一字不动** |
| `tests/probe/menu_style_probe.gd` / `.tscn` | 建 | 新 token 的存在性 + **共享 token 的冻结守卫** + 菜单 stylebox 的形状断言 |
| `scenes/main_menu.gd` | 改 | 套新皮 |
| `scenes/beta_menu.gd` | 改 | 套新皮 |
| `scenes/settings_menu.gd` | 改 | 套新皮 + 两栏重排（设计 §3.9.3 的版式） |
| `scenes/info_menu.gd` | 改 | 套新皮（★ 由计划 ② 建出） |
| `scenes/mp_lobby.gd` | 改 | 套新皮（顶栏 / 筛选 / 房卡 / 创建弹层 / 等待室） |
| `ui/screens/match_result.gd` | 改 | 套新皮 |
| `ui/screens/pause_menu.gd` | 改 | 套新皮 |

---

## Task 1: 新增 5 个 token + 共享 token 的冻结守卫

**Files:**
- Modify: `ui/factory/ui_factory.gd`（只在调色板区**追加**）
- Test: `tests/probe/menu_style_probe.gd` / `.tscn`（新建）

**Interfaces:**
- Produces（Task 2-6 全部要用）：
  - `UiFactory.C_HEADER` = `#1B242C`（标题带底 / 按钮填充）
  - `UiFactory.C_INNER` = `#1E2830`（面板**内**亮线）
  - `UiFactory.C_EDGE` = `#46545F`（按钮描边）
  - `UiFactory.C_GOLD` = `#E0A94F`（琥珀：分区标题 / 主行动按钮）
  - `UiFactory.C_TEXT_MUTE` = `#6C7885`（比 `C_TEXT_DIM` 更弱的禁用文本）

- [ ] **Step 1: 写失败的探针（含冻结守卫）**

新建 `tests/probe/menu_style_probe.gd`：

```gdscript
extends Node

# 菜单系视觉重做的基座守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
# 判据: 文本 `MENU STYLE PROBE: ALL-OK`(不看退出码)。
#
# ★★ 本探针最要紧的不是"新 token 在不在",而是**共享 token 冻结**那几条:
#    改菜单配色最容易顺手改到 `C_ACCENT` / `C_TEXT_DIM`,而它们被**对局内 HUD**读
#    (`ui/hud/hud.gd:16` 击杀色、`royale_hud.gd:17/18` 的「我」那行与「复活中」)——
#    改了不会有任何编译错误,只表现为"打起来之后 HUD 颜色不对",而那时你早忘了。
#    ★ 这四条钉的是**值**,不是名字:把颜色调深一点也会红。
# ★ 断言计数:改本探针必须同步改这个数(见 tests/lib/probe_base.gd 文件头)。
const EXPECTED_CHECKS := 15

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	# ── 新增的 5 个 token(菜单专用) ──
	_check(UiFactory.C_HEADER == Color("#1B242C"), "C_HEADER 存在且值正确")
	_check(UiFactory.C_INNER == Color("#1E2830"), "C_INNER 存在且值正确")
	_check(UiFactory.C_EDGE == Color("#46545F"), "C_EDGE 存在且值正确")
	_check(UiFactory.C_GOLD == Color("#E0A94F"), "C_GOLD 存在且值正确")
	_check(UiFactory.C_TEXT_MUTE == Color("#6C7885"), "C_TEXT_MUTE 存在且值正确")

	# ── ★★ 冻结守卫:被 HUD 读的 token 逐位不变 ──
	# 期望值是**本计划开始前**的实测值(不是设计 §3.9.1 那张表 —— 那张表与
	# "HUD 一行不动"自相矛盾,已由用户裁定以 HUD 为准)。
	_check(UiFactory.C_ACCENT == Color(0.349, 0.851, 0.902),
			"★ C_ACCENT 未变(对局内击杀色/「我」那行在用)")
	_check(UiFactory.C_TEXT_DIM == Color(0.510, 0.573, 0.639),
			"★ C_TEXT_DIM 未变(对局内「复活中」在用)")
	_check(UiFactory.C_TEXT == Color(0.878, 0.914, 0.949), "★ C_TEXT 未变")
	_check(UiFactory.C_DANGER == Color(0.900, 0.400, 0.400), "★ C_DANGER 未变(对局内「离开」/延迟条在用)")

	# ── 面板底仍然不透明 ──
	var sb := UiFactory.panel_box()
	_check(sb.bg_color.a == 1.0, "panel_box() 的底仍是不透明")

	# ── 新工厂：菜单面板要有**外描边 + 内亮线**两条线 ──
	# ★ 判据落在"两个 stylebox 的 border 颜色确实不同"上 —— 它比"存在两个节点"
	#   更贴近这条视觉规则本身;把内线改成与外线同色 ⇒ 这条红。
	var mp := UiFactory.menu_panel()
	_check(mp != null and mp is PanelContainer, "menu_panel() 返回 PanelContainer")
	# ★★ **光断言两层的 border_color 是看不见"重合"的** —— 初版探针就是这么写的,
	#    而当时两层边框其实落在同一条 1px 环上(外层被完全盖住),四条断言照样全绿。
	#    必须**量位置**:内层 `Body` 必须真的从外层**内缩**,否则"两条线"不成立。
	#    (本探针是 Node,故要真入树才能拿到 rect。)
	add_child(mp)
	await get_tree().process_frame
	var body_n := mp.get_node_or_null("Body")
	_check(body_n != null and body_n.position.x >= 1.0 and body_n.position.y >= 1.0,
			"★ 内亮线**真的内缩**(否则它与外线落在同一像素环上,只看得见一条)")
	_check(body_n != null and body_n.size.x <= (mp as PanelContainer).size.x - 2.0,
			"★ 内层宽度 < 外层 − 两侧各 1px")
	if mp is PanelContainer:
		var outer := (mp as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		var body := (mp as PanelContainer).get_node_or_null("Body")
		_check(outer != null and outer.border_color == UiFactory.C_BORDER,
				"menu_panel() 的外描边是 C_BORDER")
		var inner := null
		if body is PanelContainer:
			inner = (body as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		_check(inner != null and inner.border_color == UiFactory.C_INNER,
				"menu_panel() 的内亮线是 C_INNER(凿刻感的来源)")
	_finish()


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MENU STYLE PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("MENU STYLE PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
```

★ **`EXPECTED_CHECKS` 请按你实际写下的 `_check(` 条数改**（上面是 12 条：5 + 4 + 1 + 2）。★ `Color("#1B242C")` 与 `Color(0.106, 0.125, 0.157)` **不完全相等**（8bit 量化）—— 实现时**以 `ui_factory.gd` 里你实际写的写法为准**统一两侧，别一边用 hex 一边用浮点，否则探针恒红。

新建 `tests/probe/menu_style_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/probe/menu_style_probe.gd" id="1"]

[node name="MenuStyleProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 跑探针确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
```

期望：红在 `C_HEADER` 等**新 token 不存在**上（`Invalid get index`）。★ 冻结那四条**此刻应当是绿的** —— 若它们现在就红，说明有人已经动过共享 token，**停下来报告**。

- [ ] **Step 3: 追加 5 个 token**

`ui/factory/ui_factory.gd` 的调色板区（`C_WARN` 之后、`C_GRACE` 之前）**追加**：

```gdscript
# ── 菜单系视觉(方向 B「遗迹青铜」,2026-10-03)──
# ★★ **只给菜单系用**(主菜单/设置/信息/统一大厅/Beta/结算页/暂停菜单)。
#    **对局内 HUD 一律不用它们**,也不会因为它们的加入而改变一个像素。
# ★★ **上面那批 token(`C_ACCENT` / `C_TEXT` / `C_TEXT_DIM` / `C_DANGER` / `C_WARN` /
#    `C_PLATE` / `C_SLOT_*` / `C_TEAM_*` / `C_GRACE` / `C_MODE_*`)** 一个都不许改** ——
#    它们被 `ui/hud/**` 读取(见 `menu_style_probe` 的冻结守卫)。
#    设计 §3.9.1 的 token 表里 `C_ACCENT` / `C_TEXT_DIM` 给的是另一个值,那是设计文档的
#    内部矛盾(它同时写着「HUD 一行不动」);用户 2026-10-03 裁定**以 HUD 为准**。
const C_HEADER     := Color(0.106, 0.141, 0.173)   # #1B242C 标题带底 / 按钮填充
const C_INNER      := Color(0.118, 0.157, 0.188)   # #1E2830 面板**内**亮线(凿刻感的来源)
const C_EDGE       := Color(0.275, 0.329, 0.373)   # #46545F 按钮描边
const C_GOLD       := Color(0.878, 0.663, 0.310)   # #E0A94F 琥珀:分区标题 / 主行动按钮
const C_TEXT_MUTE  := Color(0.424, 0.471, 0.522)   # #6C7885 比 C_TEXT_DIM 更弱一档(禁用)
```

★ **浮点值按上面的 8bit 反算写**（`0x1B/255 = 0.1059`，取 `0.106`）—— 与探针里的 `Color("#1B242C")` 会差 1/255 以内。**为避免"看着一样但断言红"**，请**统一**：要么两侧都用 hex 字符串（`Color("#1B242C")`），要么两侧都用同一组浮点。**推荐都用 hex** —— 它对 8bit 是精确的，而浮点要手算且容易差一位。

- [ ] **Step 4: 加 `menu_panel()`**

同一个文件，放在 `panel_box()` **之后**（**不要改 `panel_box()` 本身** —— 重连横幅在用）：

```gdscript
# 菜单系的面板底(方向 B 的凿刻感 = **外深线 + 内亮线**两条线)。
#
# ★ 为什么不让 `panel_box()` 直接改成这样:`ui/hud/status_banner.gd:88`(对局内的
#   **重连横幅**)在用 `panel_box(false)` —— 改它会连带改到对局内 HUD,而本次的硬约束是
#   "HUD 一行不动"。⇒ 菜单要的形状走**新函数**,两个函数各管各的。
# ★ 实现用**两层嵌套的 PanelContainer**:`StyleBoxFlat` 一条边只能有一个颜色,
#   要两条线就得两层。内容加到 `Body` 里:
#       var p := UiFactory.menu_panel()
#       (p.get_node("Body") as Container).add_child(<你的 VBox>)
static func menu_panel(padding: Vector2 = Vector2(28, 20)) -> PanelContainer:
	var outer := PanelContainer.new()
	var osb := StyleBoxFlat.new()
	osb.bg_color = C_SURFACE
	osb.border_color = C_BORDER
	osb.set_border_width_all(1)
	osb.set_corner_radius_all(0)
	# ★★ **不要设 `content_margin_* = 0.0`** —— 本计划初稿这么写了,**是错的**:
	#    `StyleBox::get_margin()` 只在 `content_margin < 0` 时才回落到 border width;
	#    显式设 0 会让子节点铺满**整个外层矩形** ⇒ 两层边框落在**同一条 1px 环**上,
	#    内层的 `C_INNER` 把外层的 `C_BORDER` 完全盖住 —— "外深线 + 内亮线"**根本不成立**,
	#    而画面上看着只是"一条线",很容易被当成做对了。
	#    (实现时实测:`body.rect = (0,0,400,300)` = 外层全尺寸;引擎侧见
	#     `panel_container.cpp` 的 `fit_child_in_rect`。)
	#    ⇒ **留默认的 -1**,让子节点自动内缩一个 border width。
	outer.add_theme_stylebox_override("panel", osb)

	var body := PanelContainer.new()
	body.name = "Body"   # ★ 名字是公开契约:调用方靠 `get_node("Body")` 拿内容容器
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0, 0, 0)   # ★ 内层只画线、不画底(否则把外层的底盖掉)
	isb.border_color = C_INNER
	isb.set_border_width_all(1)
	isb.set_corner_radius_all(0)
	isb.content_margin_left = padding.x
	isb.content_margin_right = padding.x
	isb.content_margin_top = padding.y
	isb.content_margin_bottom = padding.y
	body.add_theme_stylebox_override("panel", isb)
	outer.add_child(body)
	return outer
```

★ **内层 `bg_color` 必须是全透明** —— 写成 `C_SURFACE` 会把外层的底盖掉（看着一样、但外层那条 `C_BORDER` 外线会被内层的边距挤掉一层）。

- [ ] **Step 5: 跑探针确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
```

期望：`MENU STYLE PROBE: ALL-OK(15 条断言)`。

- [ ] **Step 6: 回归（必须仍绿）**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/ui_palette_single_source_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/combat_hud_visual_probe.tscn
```

★ `combat_hud_visual_probe` 是 HUD 的取色探针 —— **它绿就是"HUD 没动"的最直接证据**。

- [ ] **Step 7: 刷导入缓存，再提交**

```bash
"$GODOT" --headless --path . --import
git add ui/factory/ui_factory.gd tests/probe/menu_style_probe.gd \
        tests/probe/menu_style_probe.gd.uid tests/probe/menu_style_probe.tscn
git commit -m "feat(ui): 菜单系视觉基座 —— 新增 5 个 token + menu_panel()

共享 token 一个不改(HUD 优先,用户裁定):设计 §3.9.1 的表里 C_ACCENT/C_TEXT_DIM
给的是另一个值,与它自己那句『HUD 一行不动』矛盾。menu_panel() 走新函数,
不动 panel_box()(对局内重连横幅在用)。新守卫把这两件事都钉住。"
```

---

## Task 2: 菜单专属按钮 / 标题带工厂

**Files:**
- Modify: `ui/factory/ui_factory.gd`（**追加**，不改 `_btn_box` / `style_button`）
- Test: `tests/probe/menu_style_probe.gd`（**追加断言**，`EXPECTED_CHECKS` 上调）

**Interfaces:**
- Produces:
  - `UiFactory.menu_button(text, size, min_size := Vector2(420, 64), variant := "primary") -> Button`
  - `UiFactory.header_strip(text, size := 32) -> PanelContainer`（标题带 = `C_HEADER` 底 + 下边 `C_BORDER` 一条线 + 标题 Label）

★ **为什么不改 `style_button()`**：它被 `ui/hud/status_banner` 之外的菜单广泛使用，而**结算页/暂停菜单也在本计划的覆盖范围里** —— 直接改它会让"改一屏、动全部"，无法逐屏验收。所以新增 `menu_button()`，逐屏切换。

- [ ] **Step 1: 追加断言**

`tests/probe/menu_style_probe.gd` 的 `_ready()` 里**追加**：

```gdscript
	# ── 菜单按钮:常态描边用 C_EDGE,悬停转 C_ACCENT ──
	var b := UiFactory.menu_button("测试", 32, Vector2(200, 48))
	var bn := b.get_theme_stylebox("normal") as StyleBoxFlat
	var bh := b.get_theme_stylebox("hover") as StyleBoxFlat
	_check(bn != null and bn.border_color == UiFactory.C_EDGE, "menu_button() 常态描边是 C_EDGE")
	_check(bh != null and bh.border_color == UiFactory.C_ACCENT, "menu_button() 悬停描边转 C_ACCENT")
	_check(bn != null and bn.bg_color == UiFactory.C_HEADER, "menu_button() 填充是 C_HEADER")
	# ── 标题带:C_HEADER 底 + 下边一条 C_BORDER 线 + 金色标题 ──
	var strip := UiFactory.header_strip("测 试", 32)
	var ssb := (strip as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	_check(ssb != null and ssb.bg_color == UiFactory.C_HEADER, "header_strip() 的底是 C_HEADER")
	_check(ssb != null and ssb.border_width_bottom == 1 and ssb.border_color == UiFactory.C_BORDER,
			"header_strip() 只有**下边**一条 C_BORDER 线(其余三边为 0)")
```

并把 `EXPECTED_CHECKS` 从 12 改成 **18**。

- [ ] **Step 2: 跑探针确认红**

- [ ] **Step 3: 实现两个工厂**

`ui/factory/ui_factory.gd` **追加**（`menu_panel()` 之后）：

```gdscript
# 菜单系的按钮(方向 B)。★ **不改 `_btn_box` / `style_button`** —— 它们被结算页/暂停菜单等
# 共用,改一处动全部,没法逐屏验收。本函数是菜单系的新入口,分屏切换。
# variant 语义与 `style_button` 一致:"primary" 常态 / "quiet" 弱化(退出等)。
# "gold" 是新增的第三档:**主行动**(创建房间 / 开始游戏)—— 琥珀描边 + 琥珀字。
static func menu_button(text: String, size: int, min_size: Vector2 = Vector2(420, 64),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	var edge := C_EDGE
	var fg := C_TEXT
	if variant == "quiet":
		edge = C_BORDER_DIM
		fg = C_TEXT_MUTE
	elif variant == "gold":
		edge = C_GOLD
		fg = C_GOLD
	b.add_theme_stylebox_override("normal", _btn_box(C_HEADER, edge))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _btn_box(C_HEADER, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_HEADER, C_BORDER_DIM))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_MUTE)
	return b


# 标题带:一片 `C_HEADER` 的横条 + **只有下边**一条 `C_BORDER` 线 + 金色标题。
# 它是方向 B"器物感"的主要来源(设计 §3.9 的"标题带")。
# ★ 只画下边一条线是刻意的:四边都画就变成又一个面板,与 `menu_panel()` 的凿刻压边打架。
static func header_strip(text: String, size: int = 32) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = C_BORDER
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, size, C_GOLD))
	return p
```

- [ ] **Step 4: 跑探针确认绿**（期望 `ALL-OK(18 条断言)`）

- [ ] **Step 5: 提交**

```bash
git add ui/factory/ui_factory.gd tests/probe/menu_style_probe.gd
git commit -m "feat(ui): 菜单专属按钮与标题带工厂(不动共用的 style_button)"
```

---

## Task 3: 主菜单 + Beta 页

**Files:** `scenes/main_menu.gd`、`scenes/beta_menu.gd`

**改成什么（逐条，设计 §3.9 + 定稿视觉稿的实测版式）：**

1. **标题**：`The Cyancular Ruins` 保持 **青色**（`C_ACCENT`）、**去掉**设计稿里的 `— RUINS —` 副题（用户 2026-10-03 明确要求去掉）。
2. **页面底**：`C_BG`（`#0A0F18`）不变；**压暗罩保留**（`_build_ui_layer` 的 `dim`），但值改成设计里的 `Color(0, 0, 0, 0.45)` → **保持现状不改**（它是全屏压暗罩，属调色板例外）。
3. **按钮**：全部从 `UiFactory.button(...)` 换成 `UiFactory.menu_button(...)`；「退 出」用 `variant = "quiet"`；「Beta」用 `variant = "quiet"`。
4. **分组空档**：`play_group` / `opt_group` / `quit` 三组的 `separation` 保持现状（34 / 14）。
5. **Beta 页的卡片**：`_card_style()` 的两色描边改成 `C_EDGE` + 悬停 `C_ACCENT`；卡片底用 `C_SURFACE`；标题/简介/版本三行的颜色改走调色板（现在有两处 `Color(...)` 字面量 — `desc` 与 `ver`）。

★ **本任务的硬约束**：`--autotest-mp/royale/team/ver` 四条都要仍能走通（它们按**按钮文案**找控件）。**按钮文案一个字都不要改**。

- [ ] **Step 1: 改并跑四条自检**

```bash
"$GODOT" --headless --path . --quit-after 200 -- --autotest-mp
"$GODOT" --headless --path . --quit-after 200 -- --autotest-ver
"$GODOT" --headless --path . --quit-after 200 -- --autotest-beta
"$GODOT" --headless --path . --quit-after 200 -- --autotest-set
```

- [ ] **Step 2: 取图并自己读**

```bash
# ★ 去掉 --headless(见下方说明);headless 下探针不会存图
"$GODOT" --path . --quit-after 200 -- --autotest-ver
```
图在 `user://autotest_ver.png`（主菜单那屏）。**打开看**：标题是青的、没有副题、按钮是凿刻描边、退出/Beta 明显弱化。

- [ ] **Step 3: 回归 + 提交**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l4_visual_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l4_probe.tscn
```
```bash
git add scenes/main_menu.gd scenes/beta_menu.gd
git commit -m "style(menu): 主菜单与 Beta 页换成方向 B"
```

---

## Task 4: 设置页（含两栏重排）+ 信息页

**Files:** `scenes/settings_menu.gd`、`scenes/info_menu.gd`

**★ 前置：计划 ② 必须先执行完**（`info_menu` 由它建出）。

1. **设置页两栏重排**（设计 §3.9.3 的版式，定稿视觉稿的实测版式）：
   - 左栏（宽 1）：`音 量` / `通 用` / `联机显示` 三节
   - 右栏（宽 1）：`按 键 映 射`（键位表从"挤在左列"搬过来）
   - 底部：`恢复默认键位` / `返 回(Esc)`
   - 两栏各套 `menu_panel()`，节标题用 `header_strip()`
   - ★ 现在设置页只用了左边 900px、右半屏空着 —— 两栏是**修掉这个**，不只是换色。
2. **信息页**：三块换成 `menu_panel()` + `header_strip()`；`返 回` 用 `menu_button(..., "quiet")`。

★ **字号纪律**：`kh_l5_probe` 扫生产目录的字号载体 —— 新增的字号只许用 16 的倍数（16/32/48）。

- [ ] **Step 1: 改 + 跑三条自检 + 取两张图自己读**

```bash
# ★ 去掉 --headless(见下方说明);headless 下探针不会存图
"$GODOT" --path . --quit-after 200 -- --autotest-set
# ★ 去掉 --headless(见下方说明);headless 下探针不会存图
"$GODOT" --path . --quit-after 200 -- --autotest-ver
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
```

★ **设置页的自检图是这一屏唯一能看出"两栏有没有做对"的手段**（探针只断言控件在不在、文案对不对）。

- [ ] **Step 2: 回归 + 提交**

```bash
"$GODOT" --headless --path . -s res://tests/probe/settings_esc_probe.gd
"$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
```
```bash
git add scenes/settings_menu.gd scenes/info_menu.gd
git commit -m "style(menu): 设置页两栏重排 + 信息页换方向 B"
```

---

## Task 5: 统一大厅 `mp_lobby`

**Files:** `scenes/mp_lobby.gd`

**改成什么**（设计 §3.2 + §3.9）：

1. **顶栏**：昵称/地址两行的标签与输入框字号 32；`刷新列表` / `启动/重启本机服务器` 用 `menu_button(..., 32, Vector2(0,64))`。
2. **筛选行**：四颗模式筛选按钮 —— **选中态用该模式的模式色**（`C_ACCENT` / `C_MODE_TEAM` / `C_MODE_ROYALE`，`MODE_COLOR` 已有）、未选中用 `C_EDGE`。「＋创建房间」用 `menu_button(..., "gold")`。
3. **房卡**：`menu_panel()` 做底；**卡头**改成 `header_strip` 风格的一条带（模式名用模式色 + 右侧状态角标）；房间号 48、正文 32、次要 16。
   ★ 卡片的 `text` 恒空、房号住 `meta("code")` —— **别改这个形状**（`lobby_row_probe` / `team_match_watcher` 都靠它找卡）。
4. **创建弹层 / 等待室**：面板换 `menu_panel()`，标题换 `header_strip()`；压暗罩保持现状（它是调色板例外）。
5. **状态栏**：底部那条用 `menu_panel(padding)`。

★ **本任务的硬约束**（都是探针在守的，改错就红）：`_grid` 与卡的 `meta("code")` / `meta("mode")`、`_form_rows` 的键名、`_wait_*` 成员的可见性逻辑、`_set_create_visible` 的两半（面板 + 遮罩）、五颗 `_find_button` 按文案找的按钮（`＋ 创建房间` / `加入房间` / `开 始 游 戏` / `加 入 A 队` / `加 入 B 队` / `退 出 房 间` / `×` / `取 消` / `创 建 房 间` / `返 回`）**文案一个字都不要改**。

- [ ] **Step 1: 改 + 跑五条大厅探针**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_row_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_wait_room_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_visibility_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_payload_probe.tscn
```

- [ ] **Step 2: 取图自己读**（`-- --autotest-mp` → `user://autotest_mp.png`）：五列？不，**四列**房卡、模式色标题带、筛选行选中态、右上两颗入口按钮。

- [ ] **Step 3: 回归 + 提交**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/reconnect_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
```
```bash
git add scenes/mp_lobby.gd
git commit -m "style(lobby): 统一大厅换成方向 B(顶栏/筛选/房卡/弹层/等待室)"
```

---

## Task 6: 结算页 + 暂停菜单

**Files:** `ui/screens/match_result.gd`、`ui/screens/pause_menu.gd`

1. 两屏的面板换 `menu_panel()`、按钮换 `menu_button()`、表格/列表行底用 `C_ROW` + `C_HEADER`。
2. **`MASK_COLOR := Color(0, 0, 0, 0.55)` 保持不动** —— 它是全屏压暗罩，属调色板例外（`match_result.gd:35` 的注释已写明）。★ 别为了"统一"把它并进 `C_PLATE`。
3. 结算页的 `COLUMN_TITLES` / 列宽等**数据面一个字不动**（`match_result_payload_smoke` 在守）。

- [ ] **Step 1: 改 + 跑两条**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/match_result_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/match_result_payload_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/hud_declarative_probe.tscn
```

- [ ] **Step 2: 取图自己读**（`match_result_probe` 会存图）—— 列没错位、胜负文案没被裁。

- [ ] **Step 3: 提交**

```bash
git add ui/screens/match_result.gd ui/screens/pause_menu.gd
git commit -m "style(ui): 结算页与暂停菜单换成方向 B"
```

---

## 收尾检查

- [ ] **全量回归**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_style_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l4_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l4_visual_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/combat_hud_visual_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l3_visual_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/ui_palette_single_source_smoke.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
```

- [ ] ★★ **"HUD 没动"的正面证据**：`combat_hud_visual_probe` 与 `kh_l3_visual_probe` 都是 HUD 的取色探针 —— 两条绿 + `menu_style_probe` 的四条冻结守卫绿，合起来才是"改菜单没动 HUD"的证据链。**别只看菜单的图**。

- [ ] **逐屏取图人眼验收**（六屏）：`--autotest-{ver,set,mp,royale,team,beta}` + `match_result_probe` + pause 的图。**自己读**。

---

★★ **取图那一步不要带 `--headless`** —— headless 下没有视口纹理,探针会打印
「headless 无视口纹理,跳过截图」并**静默地什么都不存**。照初稿带 `--headless` 跑,
你会以为图在 `user://` 里、其实永远没有。**去掉 `--headless`,跑真窗口。**(计划 ② Task 4 实测踩到。)

## 已知边界（本计划**不**处理的）

1. **对局内 HUD 一行不动** —— 这是本计划的第一约束，`menu_style_probe` 的四条冻结守卫 + 两个 HUD 取色探针是它的证据。
2. **不新增/不修改任何游戏逻辑**：纯表现层。任何"顺手改一下这个判断"都不属于本计划。
3. **设计 §3.9.1 的 token 表里 `C_ACCENT` / `C_TEXT_DIM` 两个值与"HUD 一行不动"矛盾** —— 已由用户裁定以 HUD 为准（见 Global Constraints）。**计划 ③ 结束时不改它们**。
4. **`C_PLATE` / `C_SLOT_*` / `C_TEAM_*` / `C_GRACE` / `C_WARN` / `C_DANGER` / `C_MODE_*` 一个都不动**（HUD 或语义钉死的）。
5. **`panel_box()` 与 `style_button()` 保持原样**（前者被重连横幅用，后者被大量既有调用点用）—— 菜单走 `menu_panel()` / `menu_button()`。
