# 设置页「联机显示」+「信 息」整页（② 内容）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 1v1 页面上那四个**本机显示项**（随三个旧大厅页一起消失）安置到设置页新开的一节；把「版本信息」从主菜单上的弹层改成独立的**整页**，并补上开发团队与致谢。

**Architecture:** 两件互不依赖的小事，各自独立可测。设置页沿用现有的单列版式（两栏重排是计划 ③ 的事）；信息页新建一个场景，`version_string()` / `commit_log()` 从 `main_menu.gd` 抽到新的纯静态类 `AppInfo`，让两个页面都能读。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript。

**上游设计文档：** `docs/superpowers/specs/2026-10-03-mp-lobby-unification-design.md`（下称「设计」）§3.6 与 §3.10。
**姊妹计划：** ① `2026-10-03-mp-lobby-unification-part1-core.md`（**已完成**）；③ 视觉重做（**尚未写**）。

## Global Constraints

- **字号必须是 16 的倍数**（16 / 32 / 48 / 64）。布局度量（separation / custom_minimum_size）**不受**此限。
- **颜色只在 `ui/factory/ui_factory.gd` 定义**；**本计划不新增颜色**、不写 `Color(...)` 字面量（换皮是计划 ③）。
- 面板底必须**不透明**（`UiFactory.panel_box()`）。
- **判据一律是文本**（`ALL-OK` 之类），**不看退出码**。
- 场景探针一律 `--quit-after 3600`（帧）；`-s` 冒烟必须有空载守卫（否则脚本报错会**永久挂起**）。
- **不动 `NetBus` 的方法表**（本计划也不涉及网络）。
- **不动 `CLAUDE.md`** —— 另一个 Claude 会话正在改它，由协调者在最后统一处理。
- ★★ **与另一个 Claude 会话共用同一棵工作树**（它在改 `scenes/enemies/*`、`CLAUDE.md`、`AGENTS.md`）。
  **提交一律逐个文件点名 `git add <具体文件>`，绝不 `git add -A`。** 提交前 `git status --short` 看一眼。
- 新建 `.gd` 后、`git add` 前**必须**先跑 `"$GODOT" --headless --path . --import` 生成 `.uid`。
- ★ **一条贯穿本仓的纪律**：**别写一条比它实际守护强的断言/注释**。这条链上同一个形态已经出过 8 次，
  失明方向**恒绿**。每条新断言请在注释里写清「**把什么去掉它才会红**」——写不出来就别写。

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `scenes/settings_menu.gd` | 改 | 在「通用」与「按键映射」之间插入「联机显示」一节（4 个开关） |
| `core/config/app_info.gd` | 建 | `class_name AppInfo`，纯静态：`version_string()` / `commit_log()`（从 `main_menu.gd` 搬来） |
| `scenes/info_menu.gd` / `.tscn` | 建 | 「信 息」整页：版本信息 + 开发团队 + 致谢 |
| `scenes/main_menu.gd` | 改 | 按钮改名 `信 息` + 切场景；删弹层一族（`_ver_panel` / `_fill_version_panel` / `_on_version_pressed` / `VERSION_PANEL_SCENE`）+ 两个静态函数 |
| `ui/screens/version_panel.tscn` | 删 | 被 `info_menu` 整页取代 |
| `tests/probe/settings_display_section_probe.gd` / `.tscn` | 建 | 设置页新一节的常驻守卫 |
| `tests/probe/info_page_probe.gd` / `.tscn` | 建 | 信息页的常驻守卫 |
| `tests/smoke/app_info_smoke.gd` | 建 | `AppInfo` 的 `-s` 冒烟 |
| `tests/smoke/menu_autotest.gd` | 改 | `--autotest-ver` 从「弹层、不切场景」反转为「切场景」 |

---

## Task 1: 设置页新增「联机显示」一节

**Files:**
- Modify: `scenes/settings_menu.gd`
- Test: `tests/probe/settings_display_section_probe.gd` / `.tscn`（新建）

**Interfaces:**
- Consumes: `Settings.pvp_show_trajectories` / `pvp_show_enemy_hp` / `pvp_show_minimap` / `pvp_minimap_show_enemy`（均已存在，`core/config/settings.gd:36,38,42,43`，各自的读者见下）、`UiFactory.check_row(text, initial, label_w, on_toggle)`、`settings_menu.gd` 既有的 `_section(text)` 与 `CHECK_LABEL_W`（= 320）
- Produces: 无（纯新增 UI；不改任何对外接口）

**背景（必读，决定了这一节为什么必须存在）**：这四个开关原先只长在 **1v1 大厅页的右侧面板**上。那个页面在计划 ① 里被删除了 ⇒ 它们的**唯一写入方消失**，而四个键**仍有读者**：

| 键 | 读者 |
|---|---|
| `pvp_show_trajectories` | `scenes/weapons/bullet_base.gd:65` |
| `pvp_show_enemy_hp` | `scenes/pvp_game.gd:69` / `royale_game.gd:167` / `team_game.gd:343` |
| `pvp_show_minimap` | `scenes/pvp_game.gd:91` / `royale_game.gd:91` / `team_game.gd:82` |
| `pvp_minimap_show_enemy` | `ui/hud/minimap.gd:197` |

⇒ 今天玩家只能改 `user://settings.cfg`。本节把它们放回界面上。

- [ ] **Step 1: 写失败的探针**

新建 `tests/probe/settings_display_section_probe.gd`（**照 `tests/probe/menu_weapon_grid_probe.gd` 的形状写** —— 那个文件是"某页真的建出了 N 个控件"的既有模板；文件头也照它写清跑法与判据）：

```gdscript
extends Node

# 设置页「联机显示」一节的常驻守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
# 判据: 文本 `SETTINGS DISPLAY SECTION PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:四个开关原先只长在 1v1 大厅页上,那页在计划①里被删了 ⇒ 键还在、
#   读者还在,但**界面上再也改不了它们**。本探针钉住"这一节真的建出来了、且每个开关
#   真的写了对应的 Settings 键"。
# ★ 断言计数:ALL-OK 只证明"没有一条失败",不证明"该跑的都跑过"(见 tests/lib/probe_base.gd
#   文件头)。少跑一条就红 —— 改本探针必须同步改这个数。
const EXPECTED_CHECKS := 11

const SCENE := "res://scenes/settings_menu.tscn"

# 一节里应当出现的四个标签 + 它们各自对应的 Settings 键。
const ROWS := [
	["显示子弹尾迹(所有子弹)", "pvp_show_trajectories"],   # ★ 必须与 check_row 的文案**逐字相等**
	["显示敌方血量条", "pvp_show_enemy_hp"],
	["打开小地图", "pvp_show_minimap"],
	["小地图显示敌方位置", "pvp_minimap_show_enemy"],
]

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
	var p: Node = (load(SCENE) as PackedScene).instantiate()
	if p == null:
		print("SETTINGS DISPLAY SECTION PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	# ★ 不入树:入树会跑 `_ready`,而设置页 `_ready` 里 `Settings` 的读写与字体补全都会跑一遍。
	#   本探针只想验**建出来的控件**。设置页的控件全在 `_ready` 里建,故必须入树再摘。
	#
	# ★★ 因此这里用「加进树 → 同一同步调用栈内 free」的手法(与 lobby_create_form_probe 同款):
	#    `_ready` 跑完、控件齐全,而设置页 `_ready` 里没有 deferred 的网络动作(它不连大厅),
	#    所以没有"帧末才炸"的风险。
	var host := Node.new()
	add_child(host)
	host.add_child(p)
	var labels := _collect_labels(p)
	var section_found := false
	for l in labels:
		if str(l).contains("联机显示"):
			section_found = true
	_check(section_found, "设置页有「联机显示」一节(实得标签:%s)" % str(labels))
	var checks := _collect_checks(p)
	for row in ROWS:
		var want := str(row[0])
		var key := str(row[1])
		var cb := _find_check_by_label(checks, want)
		_check(cb != null, "开关「%s」建出来了" % want)
		if cb == null:
			continue
		# ★★ **这条必须先构造"非默认基线"才咬得住** —— 四个键的默认值**全是 true**
		#    (`core/config/settings.gd:36,38,42,43`),而 `cb.button_pressed == bool(Settings.get(key))`
		#    在 `true == true` 时恒成立 ⇒ "把 `Settings.<key>` 换成 `true` 字面量"这个变异
		#    **照样绿**,接到另一个也是 `true` 的键也绿。只有玩家恰好把那项关掉时才咬不到。
		#    ⇒ 本探针**先把四个键全翻到非默认、重建页面、再逐行比**(见上面那段"非默认基线")。
		_check(cb.button_pressed == bool(Settings.get(key)),
				"「%s」的初值来自 `Settings.%s`(已用非默认基线验)" % [want, key])
	_check(_section_precedes_keymap(p), "「联机显示」排在「按键映射」**之前**")
	# ★ 行为面:拨一下开关,断言 Settings 真的被写回(而不是只画了个控件)。
	var first := _find_check_by_label(checks, "显示子弹尾迹")
	if first != null:
		var before := Settings.pvp_show_trajectories
		first.button_pressed = not before
		first.toggled.emit(not before)
		_check(Settings.pvp_show_trajectories == (not before),
				"拨动「显示子弹尾迹」会写回 Settings(不是只画了个控件)")
		Settings.pvp_show_trajectories = before
		Settings.save()
	host.free()   # 同一同步调用栈内 free:上面的断言全是同步的
	_finish()


# 递归收所有 Label 的文本(用于断言"这一节存在"与"它排在按键映射之前")。
func _collect_labels(root: Node, out: Array = []) -> Array:
	if root is Label:
		out.append((root as Label).text)
	for c in root.get_children():
		_collect_labels(c, out)
	return out


func _collect_checks(root: Node, out: Array = []) -> Array:
	if root is CheckButton:
		out.append(root)
	for c in root.get_children():
		_collect_checks(c, out)
	return out


# 开关行 = 定宽标签列 + 紧邻控件(HBox);按标签找行、再取行里的 CheckButton。
func _find_check_by_label(checks: Array, label_text: String) -> CheckButton:
	for cb in checks:
		var row := (cb as CheckButton).get_parent()
		if row == null:
			continue
		for c in row.get_children():
			if c is Label and (c as Label).text == label_text:
				return cb
	return null


# 「联机显示」那节必须排在「按键映射」之前(与设计 §3.6 的次序一致)。
# ★ 判据是**两个节标题在遍历序里的先后**,不是它们在屏幕上的 y —— 后者会随版式变。
func _section_precedes_keymap(root: Node) -> bool:
	var labels := _collect_labels(root)
	var i_net := labels.find("联机显示")
	var i_key := -1
	for i in labels.size():
		if str(labels[i]).begins_with("按键映射"):
			i_key = i
			break
	return i_net >= 0 and i_key >= 0 and i_net < i_key


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("SETTINGS DISPLAY SECTION PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("SETTINGS DISPLAY SECTION PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
```

新建 `tests/probe/settings_display_section_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/probe/settings_display_section_probe.gd" id="1"]

[node name="SettingsDisplaySectionProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 跑探针确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
```

期望：**红**（`联机显示` 那一节还不存在）。★ 若输出里是 `Parser Error`，那也算红，但要确认红在**缺那一节**上，不是探针自己写错。

- [ ] **Step 3: 加这一节**

`scenes/settings_menu.gd`：在「通用开关」那一段**之后**、「按键映射」那一节**之前**插入：

```gdscript
	# ── 联机显示 ──
	# ★ 这四个开关原先只长在 1v1 大厅页的右侧面板上,而那页在「大厅合一」里被删了 ⇒
	#   键与读者都还在,但界面上再也改不了。这里把它们放回来。
	# ★ 它们**只写本机 Settings、不上报服务器**(与对局的「房主规则项」不是一回事):
	#   四个键的读者全在本机(pvp_game / royale_game / team_game / bullet_base / minimap)。
	vb.add_child(_section("联机显示"))
	vb.add_child(UiFactory.check_row("显示子弹尾迹(所有子弹)", Settings.pvp_show_trajectories,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_trajectories = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("显示敌方血量条", Settings.pvp_show_enemy_hp,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_enemy_hp = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("打开小地图", Settings.pvp_show_minimap,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_show_minimap = on
		Settings.save()))
	vb.add_child(UiFactory.check_row("小地图显示敌方位置", Settings.pvp_minimap_show_enemy,
			CHECK_LABEL_W, func(on: bool) -> void:
		Settings.pvp_minimap_show_enemy = on
		Settings.save()))
```

★ **文案与旧 1v1 页逐字一致**（`显示子弹尾迹(所有子弹)` / `显示敌方血量条` / `打开小地图` / `小地图显示敌方位置`）—— 探针按文案找控件，改文案要同步改探针。

- [ ] **Step 4: 跑探针确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
```

期望：`SETTINGS DISPLAY SECTION PROBE: ALL-OK(11 条断言)`。
★ 条数是**运行时**的（`ROWS` 那个循环每轮 2 条 ⇒ 静态 `grep -c '^\s*_check('` 只得 5，别拿它当判据）。

- [ ] **Step 5: 回归（必须仍绿）**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd
"$GODOT" --headless --path . -s res://tests/probe/settings_esc_probe.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
```

（`kh_l5_probe` 扫字号规范 —— 新代码里的字号只能用 16 的倍数；`check_row` 内部用的是 32，无需你操心。）

- [ ] **Step 6: 刷导入缓存，再提交**

```bash
"$GODOT" --headless --path . --import
ls tests/probe/settings_display_section_probe.gd.uid
```

```bash
git add scenes/settings_menu.gd tests/probe/settings_display_section_probe.gd \
        tests/probe/settings_display_section_probe.gd.uid tests/probe/settings_display_section_probe.tscn
git commit -m "feat(settings): 新增「联机显示」一节(4 个本机显示项)

这四个开关原先只长在 1v1 大厅页的右侧面板上,那页在「大厅合一」里被删了 ⇒
键与读者都还在但界面上改不了。放回设置页,文案与旧页逐字一致。"
```

---

## Task 2: 抽 `AppInfo`（`version_string()` / `commit_log()` 搬出 `main_menu`）

**Files:**
- Create: `core/config/app_info.gd`
- Modify: `scenes/main_menu.gd`（删两个静态函数 + 两个缓存字段，改成调 `AppInfo`）
- Test: `tests/smoke/app_info_smoke.gd`（新建）

**Interfaces:**
- Produces:
  - `AppInfo.version_string() -> String`
  - `AppInfo.commit_log() -> Array`（元素 `{hash, time, subject}`，新→旧，最多 20 条）
- Consumes: `core/config/build_info.gd` 的 `VERSION` / `display()`（**只读**，不得修改那个文件）

**为什么必须抽**：这两个函数今天是 `main_menu.gd` 的静态函数，而信息页也要用它们（主菜单左下角仍有版本号行）。**不能放进 `core/config/build_info.gd`** —— 那个文件由 `tools/build_release.py` 在导出前**覆盖写入**、导出后还原，扔进去会被构建流程盖掉。

- [ ] **Step 1: 写失败的冒烟**

新建 `tests/smoke/app_info_smoke.gd`（**`extends SceneTree`，用 `-s` 跑**；**必须有空载守卫**，否则脚本一报错进程永久挂起）：

```gdscript
extends SceneTree

# `AppInfo` 的 `-s` 冒烟。
# 跑法: "$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
# 判据: 文本 `APP INFO SMOKE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:两个函数从 `main_menu.gd` 搬到了这里,而 `version_string()` 有一个
#   **只在这个仓里成立**的分支 —— 发布版读 `build_info.gd`、开发版回落到 git。
#   搬错了(比如漏了 `--nover` 的收口)不会有任何编译错误,只表现为"版本号显示得不对"。
var _fails: Array[String] = []


func _initialize() -> void:
	var script := load("res://core/config/app_info.gd")
	if script == null:
		print("APP INFO SMOKE: FAIL(load 不到 core/config/app_info.gd)")
		quit(1)
		return
	var s: String = script.version_string()
	var log: Array = script.commit_log()
	if s.strip_edges() == "":
		_fails.append("version_string() 返回空串")
	# ★ 这一条钉的是"它真的**接**到了 git/build_info 之一",而不是恒返回占位串。
	#   把函数体改成 `return "x"` ⇒ 它照样过 —— 这条断言**给不了**那个保证,如实登记。
	if not (s == "dev" or s.contains("#") or s.contains("v") or s.length() >= 3):
		_fails.append("version_string() 的形状可疑:「%s」" % s)
	if log.size() > 20:
		_fails.append("commit_log() 超过 20 条(%d)" % log.size())
	for e in log:
		if typeof(e) != TYPE_DICTIONARY or not ((e as Dictionary).has("hash")
				and (e as Dictionary).has("time") and (e as Dictionary).has("subject")):
			_fails.append("commit_log() 的元素缺字段:%s" % str(e))
			break
	if _fails.is_empty():
		print("APP INFO SMOKE: ALL-OK(version=「%s」, commits=%d)" % [s, log.size()])
		quit(0)
	else:
		print("APP INFO SMOKE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		quit(1)
```

- [ ] **Step 2: 跑冒烟确认红**

```bash
timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
```

期望：`FAIL(load 不到 ...)`（文件还不存在）。★ **一律套 `timeout`** —— `-s` 脚本挂住时不会自己退。

- [ ] **Step 3: 建 `AppInfo`**

新建 `core/config/app_info.gd`：

```gdscript
class_name AppInfo
extends RefCounted

# 版本号与提交历史(**两个页面都要读**:主菜单左下角的版本号行 + 「信 息」整页)。
#
# ★ 为什么单独一个文件而不是留在 `main_menu.gd`:信息页也要用,而让信息页去依赖主菜单
#   是反的。★ **也不能放进 `core/config/build_info.gd`** —— 那个文件由
#   `tools/build_release.py` 在导出前**覆盖写入**、导出后还原,扔进去会被构建流程盖掉。
#
# ★ 纯静态、零 autoload 依赖(与 `WeaponRegistry` 同形)⇒ 可 `-s` 测。


# 版本号:**发布版读 `core/config/build_info.gd`**(由 `tools/build_release.py` 在导出前写入
# 真实版本号与构建时间戳),开发版回落到 git(分支名 + 提交数)。
# ★ 发布版必须走前者:发布机往往没有 git,读 git 只会得到 "dev" 且拿不到构建时间。
# 传 `--nover` 时恒为 "dev"(菜单自动探针要确定性文本)。
#
# ★ `--nover` 的收口**在本函数内部**,不在调用方分叉 —— 保持原样,别搬出去。
static var _version_cache := ""
static var _log_cache: Array = []


static func version_string() -> String:
	if "--nover" in OS.get_cmdline_user_args():
		return "dev"
	if _version_cache != "":
		return _version_cache
	var bi := preload("res://core/config/build_info.gd")
	if str(bi.VERSION) != "" and str(bi.VERSION) != "dev":
		_version_cache = bi.display()
		return _version_cache
	var branch := _git_text(["rev-parse", "--abbrev-ref", "HEAD"]).strip_edges()
	var n := _git_text(["rev-list", "--count", "HEAD"]).strip_edges()
	_version_cache = ("%s #%s" % [branch, n]) if branch != "" else "dev"
	return _version_cache


# 提交历史(新→旧,最多 20 条):[{hash,time,subject}]
static func commit_log() -> Array:
	if not _log_cache.is_empty():
		return _log_cache
	for line in _git_text(["-c", "i18n.logOutputEncoding=UTF-8",
			"log", "--pretty=%h|%cI|%s", "-20"]).split("\n"):
		var parts := line.strip_edges().split("|", true, 2)
		if parts.size() == 3:
			_log_cache.append({
				"hash": parts[0],
				"time": parts[1].replace("T", " ").substr(0, 16),
				"subject": parts[2],
			})
	return _log_cache


# 读 git 输出为 UTF-8 文本。OS.execute 在中文 Windows 上按系统码页解码 → 中文乱码;
# execute_with_pipe 拿原始流,FileAccess.get_as_text 显式按 UTF-8 解。
# ★ 逐字从 `main_menu.gd` 搬来,别"顺手优化" —— 它踩过中文乱码那个坑。
static func _git_text(args: Array) -> String:
	var res: Variant = OS.execute_with_pipe("git", args, true)
	if res is Dictionary and res.has("stdio"):
		var f: FileAccess = res["stdio"]
		if f != null:
			var bytes := PackedByteArray()
			var guard := 0
			while not f.eof_reached() and guard < 1000:
				guard += 1
				var chunk := f.get_buffer(4096)
				if chunk.size() == 0:
					break
				bytes.append_array(chunk)
			if bytes.size() > 0:
				return bytes.get_string_from_utf8()
	var out: Array = []
	OS.execute("git", args, out, true)
	return str(out[0]) if out.size() > 0 else ""
```

★ **`preload("res://core/config/build_info.gd")` 必须留着** —— 发布版靠它；本类**不修改**那个文件。

- [ ] **Step 4: `main_menu.gd` 改成调 `AppInfo`**

删掉 `main_menu.gd` 里这三块：
- `static var _version_cache := ""` 与 `static var _log_cache: Array = []`（`:7-8`）
- `static func version_string()`（`:118-130`）
- `static func commit_log()`（`:134-146`）
- `static func _git_text(args)`（`:92-111`，只被上面两个用）

然后把唯一的两处调用点改成 `AppInfo.version_string()` / `AppInfo.commit_log()`（`_build_version_label()` 与 `_fill_version_panel()` 里各一处）。

★ 改完 grep 一遍：`grep -n "_git_text\|_version_cache\|_log_cache" scenes/main_menu.gd` 应当**零命中**。

- [ ] **Step 5: 跑冒烟确认绿 + 回归**

```bash
timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
"$GODOT" --headless --path . --quit-after 200 -- --autotest-ver
```

期望：`APP INFO SMOKE: ALL-OK(...)`；`--autotest-ver` 仍能打开版本弹层（此刻它还在，Task 4 才删）。

- [ ] **Step 6: 刷导入缓存，再提交**

```bash
"$GODOT" --headless --path . --import
git add core/config/app_info.gd core/config/app_info.gd.uid \
        scenes/main_menu.gd tests/smoke/app_info_smoke.gd tests/smoke/app_info_smoke.gd.uid
git commit -m "refactor(core): 抽 AppInfo —— version_string/commit_log 搬出 main_menu

信息页也要读它们,而让信息页依赖主菜单是反的。不能进 build_info.gd:
那个文件由 build_release.py 覆盖写入。"
```

---

## Task 3: 「信 息」整页

**Files:**
- Create: `scenes/info_menu.gd` / `.tscn`
- Test: `tests/probe/info_page_probe.gd` / `.tscn`（新建）
- Consumes: `AppInfo.version_string()` / `AppInfo.commit_log()`（Task 2）

**Interfaces:**
- Produces: `scenes/info_menu.tscn`（Task 4 用它做切场景目标）

**版式**（设计 §3.10，1920×1440）：标题 `信 息` → 左栏「版本信息」（当前版本 + 构建时间 + 提交历史滚动区）+ 右栏「开发团队」「致谢」两个面板 → 底部居中 `返 回(Esc)`。

**内容（用户给定，逐字照抄，不要改写）：**

```
开发团队                    致谢
RoFtaCD                     Godot Engine            MIT
KikuchiH                    GNU Unifont             SIL OFL 1.1
Lord Nahiz Waugh            Less Perfect DOS VGA    Zeh Fernando / Laemeur
siri2048                    Thomas Stearns Eliot
                            Jorge Luis Borges
```

★ `Lord Nahiz Waugh` 是**一个人**（三段名），不是两个人。
★ 致谢后两条是**作品来源不是软件依赖**：Borges 的 *Las ruinas circulares*（游戏名出处）、Eliot 的 *Four Quartets*。按用户要求**写全名**。
★ `Less Perfect DOS VGA` 的署名**不是猜的** —— 从 `assets/fonts/less_perfect_dos_vga.ttf` 的 `name` 表读出 `manufacturer = "zeh;laemeur"`。仓里**没有**该字体的许可文件，故**只署名、不声称许可条款**。

- [ ] **Step 1: 写失败的探针**

新建 `tests/probe/info_page_probe.gd`（形状照 `menu_weapon_grid_probe.gd`）：

```gdscript
extends Node

# 「信 息」整页的常驻守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
# 判据: 文本 `INFO PAGE PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:这一页的内容(名单/致谢/版本)是**人手抄进去的**,而抄错一个字
#   没有任何东西会红 —— 它只表现为"页面上少一个人"或"致谢写错了名"。
#   本探针把那三块内容**逐字**钉住。
# ★ 断言计数:改本探针必须同步改这个数(见 tests/lib/probe_base.gd 文件头)。
const EXPECTED_CHECKS := 12

const SCENE := "res://scenes/info_menu.tscn"
const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048"]
const CREDITS := ["Godot Engine", "GNU Unifont", "Less Perfect DOS VGA",
		"Thomas Stearns Eliot", "Jorge Luis Borges"]

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
	var p: Node = (load(SCENE) as PackedScene).instantiate()
	if p == null:
		print("INFO PAGE PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	var host := Node.new()
	add_child(host)
	host.add_child(p)
	var texts := _collect_labels(p)
	_check(_has(texts, "信 息"), "标题是「信 息」")
	_check(_has(texts, "版 本 信 息"), "有「版 本 信 息」一节")
	_check(_has(texts, "开 发 团 队"), "有「开 发 团 队」一节")
	_check(_has(texts, "致 谢"), "有「致 谢」一节")
	for who in DEV_TEAM:
		_check(_has_exact(texts, who), "开发团队含「%s」" % who)
	for c in CREDITS:
		_check(_has(texts, c), "致谢含「%s」" % c)
	_check(_has(texts, "MIT"), "Godot 的许可证标了 MIT")
	_check(_has(texts, "SIL OFL 1.1"), "Unifont 的许可证标了 SIL OFL 1.1")
	var back := _find_button(p, "返 回")
	_check(back != null and back.pressed.get_connections().size() == 1,
			"「返 回」按钮存在且恰有 1 个 handler")
	# ★ 版本号那一行必须来自 AppInfo(不是写死的占位串) —— 拿 AppInfo 的真值去比。
	var ver := preload("res://core/config/app_info.gd").version_string()
	_check(_has(texts, ver), "版本号那一行是 AppInfo.version_string() 的真值(「%s」)" % ver)
	host.free()
	_finish()


func _collect_labels(root: Node, out: Array = []) -> Array:
	if root is Label:
		out.append((root as Label).text)
	for c in root.get_children():
		_collect_labels(c, out)
	return out


func _has(texts: Array, needle: String) -> bool:
	for t in texts:
		if str(t).contains(needle):
			return true
	return false


func _has_exact(texts: Array, want: String) -> bool:
	for t in texts:
		if str(t).strip_edges() == want:
			return true
	return false


func _find_button(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text == text:
		return root
	for c in root.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("INFO PAGE PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("INFO PAGE PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
```

★ `EXPECTED_CHECKS := 12` 是按上面的**断言条数**数出来的（1+3+4+5+2+1+1 = 17 —— **请照你实际写下的条数改这个常量**，并在文件头写明数法）。★ **别照抄这个 12**：它是按"每个开发团队成员一条、每条致谢一条"估的，你写完请 `grep -c '^\s*_check('` 数一遍再定。这条提醒本身就是为了避免本仓踩过的"期望条数与实际条数对不上"。

新建 `scenes/info_menu.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scenes/info_menu.gd" id="1"]

[node name="InfoMenu" type="Control"]
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")
```

- [ ] **Step 2: 跑探针确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
```

- [ ] **Step 3: 实现 `info_menu.gd`**

```gdscript
extends Control

# 「信 息」整页(2026-10-03,取代主菜单上的版本信息弹层)。
# 三块:版本信息(AppInfo) / 开发团队 / 致谢。场景是裸 Control,UI 全在代码里建;
# 控件一律走 UiFactory(像素字体与字号规范的单一来源),字号必须是 16 的倍数。
#
# ★ 名单与致谢是**用户给定、逐字照抄**的 —— 别顺手改写、别补全称、别调次序。
#   `tests/probe/info_page_probe` 把它们逐字钉住了。

const DEV_TEAM := ["RoFtaCD", "KikuchiH", "Lord Nahiz Waugh", "siri2048"]
# 致谢三段:软件/素材(带许可或署名)与文学来源,中间空一档。
const CREDITS := [
	["Godot Engine", "MIT"],
	["GNU Unifont", "SIL OFL 1.1"],
	["Less Perfect DOS VGA", "Zeh Fernando / Laemeur"],
	["Thomas Stearns Eliot", ""],
	["Jorge Luis Borges", ""],
]

# 提交行的固定宽度(见 `_fill_version_block` 里"钉死行宽"那段)。
const ROW_W := 900.0


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.position = Vector2(60, 40)
	vb.custom_minimum_size = Vector2(1800, 0)
	vb.add_theme_constant_override("separation", 20)
	add_child(vb)
	vb.add_child(UiFactory.label("信 息", 48, UiFactory.C_ACCENT))

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 30)
	vb.add_child(cols)
	_fill_version_block(cols)
	_fill_right_blocks(cols)

	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	var back := UiFactory.button("返 回", 32, Vector2(280, 48))
	back.pressed.connect(_go_back)
	back_row.add_child(back)
	vb.add_child(back_row)


func _fill_version_block(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiFactory.panel_box())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	box.add_child(UiFactory.label("版 本 信 息", 32, UiFactory.C_ACCENT))
	box.add_child(UiFactory.label("当前版本　%s" % AppInfo.version_string(), 32))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 900)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(ROW_W, 0)
	scroll.add_child(list)
	# ★ 提交行**钉死行宽 + 末尾省略号**:ScrollContainer 不收缩子节点,而提交标题长短不一,
	#   最长的那条会把 Label 的最小宽度顶到面板之外 —— 每一行都在右沿被切成半个字。
	#   (这条是从被取代的 `version_panel.tscn` / `main_menu._fill_version_panel` 继承的实测。)
	for e in AppInfo.commit_log():
		var row := UiFactory.label("%s  %s  %s" % [str(e["hash"]), str(e["time"]), str(e["subject"])],
				16, UiFactory.C_TEXT)
		row.custom_minimum_size = Vector2(ROW_W, 0)
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		list.add_child(row)


func _fill_right_blocks(parent: Node) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 24)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(col)

	var team := PanelContainer.new()
	team.add_theme_stylebox_override("panel", UiFactory.panel_box())
	var tbox := VBoxContainer.new()
	tbox.add_theme_constant_override("separation", 8)
	team.add_child(tbox)
	tbox.add_child(UiFactory.label("开 发 团 队", 32, UiFactory.C_ACCENT))
	for who in DEV_TEAM:
		tbox.add_child(UiFactory.label(who, 32))
	col.add_child(team)

	var cred := PanelContainer.new()
	cred.add_theme_stylebox_override("panel", UiFactory.panel_box())
	var cbox := VBoxContainer.new()
	cbox.add_theme_constant_override("separation", 8)
	cred.add_child(cbox)
	cbox.add_child(UiFactory.label("致 谢", 32, UiFactory.C_ACCENT))
	for pair in CREDITS:
		var right := str(pair[1])
		cbox.add_child(UiFactory.label(
				str(pair[0]) if right == "" else "%s　%s" % [str(pair[0]), right],
				32, UiFactory.C_TEXT if right != "" else UiFactory.C_TEXT_DIM))
	col.add_child(cred)


# ★ 切场景**必须延迟到帧末** —— `change_scene_to_file` 会**同步 memdelete** 当前场景,
#   同步切等于把还在调用栈上的本节点抽掉。本函数有两条调用路径(ESC 与「返 回」按钮),
#   两条都在切换之后还会碰 `self`/`get_tree()`。仓内先例:`settings_menu._go_back`。
func _go_back() -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file.call_deferred("res://scenes/main_menu.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# ★ 顺序不能反:**先**标记已处理,**再**决定去向(切换之后本节点已被移出树)。
		get_viewport().set_input_as_handled()
		_go_back()
```

- [ ] **Step 4: 跑探针确认绿**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
```

- [ ] **Step 5: 刷导入缓存，再提交**

```bash
"$GODOT" --headless --path . --import
git add scenes/info_menu.gd scenes/info_menu.gd.uid scenes/info_menu.tscn \
        tests/probe/info_page_probe.gd tests/probe/info_page_probe.gd.uid \
        tests/probe/info_page_probe.tscn
git commit -m "feat(ui): 「信 息」整页(版本信息 + 开发团队 + 致谢)

取代主菜单上的版本信息弹层。提交行沿用'钉死行宽 + 省略号'那条实测纪律;
切场景与 Esc 沿用 settings_menu._go_back 的 call_deferred 教训。"
```

---

## Task 4: 主菜单换入口 + 删弹层 + 反转 `--autotest-ver`

**Files:**
- Modify: `scenes/main_menu.gd`
- Modify: `tests/smoke/menu_autotest.gd`
- Delete: `ui/screens/version_panel.tscn`

**Interfaces:**
- Consumes: `scenes/info_menu.tscn`（Task 3）

- [ ] **Step 1: 改主菜单**

`scenes/main_menu.gd`：

1. 按钮文案 `版 本 信 息` → **`信 息`**，`pressed` 从 `_on_version_pressed` 改成切场景：

```gdscript
	var ver_btn := UiFactory.button("信 息", 32)
	ver_btn.pressed.connect(func() -> void:
		Sfx.play("ui")
		get_tree().change_scene_to_file("res://scenes/info_menu.tscn"))
```

2. **删掉弹层一族**（它们只服务旧的版本面板）：
   - `var _ver_panel: PanelContainer = null`（`:15` 附近）
   - `const VERSION_PANEL_SCENE := preload("res://ui/screens/version_panel.tscn")`（`:20`）
   - `func _on_version_pressed()`（`:313-319`）
   - `func _fill_version_panel(...)`（`:327-359`）
   - `const ROW_W := 1100.0`（`:323` 附近，只被 `_fill_version_panel` 用）

★ 删完 grep：`grep -n "_ver_panel\|VERSION_PANEL_SCENE\|_fill_version_panel\|_on_version_pressed" scenes/main_menu.gd` 应当**零命中**。
★ **`SP_PANEL_SCENE` 与 `_on_single_pressed` / `_fill_sp_panel` 一个字都不要动** —— 那是单人开局面板，与本次无关。

3. 删 `ui/screens/version_panel.tscn`：

```bash
git rm ui/screens/version_panel.tscn
```

- [ ] **Step 2: 反转 `menu_autotest` 的 `--autotest-ver`**

`tests/smoke/menu_autotest.gd` 现在写着（`:14` 一带）「`--autotest-ver` 主菜单→版本信息面板(弹层,**不切场景**,故无场景硬断言)」，并且**故意不**把 `ver` 放进 `must_reach`（`must_reach` 上面那段注释解释了为什么："版本信息是弹层，全程不切场景 —— 对它断言 scene 路径是同义反复"）。

**现在语义反转了**：信息页是**整页**。所以：

1. `:71` 一带的 `elif mode == "ver": _press_by_text(tree.current_scene, "版 本 信 息")` 改成按 **`信 息`**。
2. `must_reach` 加一条：`"ver": "info_menu.tscn"`。
3. 文件头 `:13` 那行说明改成「主菜单→信息页(**整页，会切场景**)→截图」，并把 `must_reach` 上方那段"ver 不列在此"的注释**整段删掉或改写** —— 它现在说的是反的。
   ★ **别把那段注释留着**：一段与代码相反的注释比没有注释更坏（本仓的既有教训）。

- [ ] **Step 3: 跑自检**

```bash
"$GODOT" --headless --path . --quit-after 200 -- --autotest-ver
```

期望：打 `AUTOTEST[ver]: 当前场景 = res://scenes/info_menu.tscn` 且以 `DONE` 收尾、**没有** `未抵达` 那一行。

再跑一次主菜单本身，确认弹层机制删干净后主菜单仍能起：

```bash
"$GODOT" --headless --path . --quit-after 120 res://scenes/main_menu.tscn
```

- [ ] **Step 4: 回归**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
"$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
```

- [ ] **Step 5: 提交**

```bash
git add scenes/main_menu.gd tests/smoke/menu_autotest.gd
git commit -m "feat(menu): 「版 本 信 息」→「信 息」整页;删版本弹层

menu_autotest 的 --autotest-ver 语义反转:弹层不切场景 → 整页会切场景,
故进 must_reach;那段'ver 不列在此'的注释一并删除(它现在是反的)。"
```

---

## 收尾检查

- [ ] **全量回归**

```bash
"$GODOT" --headless --path . -s res://tests/smoke/app_info_smoke.gd
"$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd
"$GODOT" --headless --path . -s res://tests/probe/settings_esc_probe.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/info_page_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/menu_weapon_grid_probe.tscn
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn
"$GODOT" --headless --path . --quit-after 200 -- --autotest-ver
"$GODOT" --headless --path . --quit-after 200 -- --autotest-set
```

- [ ] **取图人眼验收**（本仓纪律：视觉类改动要有图）

```bash
"$GODOT" --headless --path . --quit-after 200 -- --autotest-ver
"$GODOT" --headless --path . --quit-after 200 -- --autotest-set
```

图落在 `user://autotest_ver.png` / `autotest_set.png`。**自己读图**（本仓踩过"数值全绿但画面是坏的"）。

- [ ] **`CLAUDE.md`**：**本计划不要动它** —— 由协调者在收尾时统一处理（另一个会话正在改它）。

---

## 已知边界（本计划**不**处理的）

1. **设置页的两栏重排**（左栏 音量/通用/联机显示，右栏 按键映射）是**计划 ③** 的版式工作 —— 本计划把新一节插进现有的单列版式里，够用即可。
2. **颜色/字号 token 的调整**是计划 ③；本计划只用既有 token。
3. **信息页里的提交历史**仍然最多 20 条、仍然只读 git —— 与旧弹层一字不差（发布版读 `build_info.gd`，那条路径由 `build_release.py` 保证）。
4. **`pvp_show_*` 四个键的语义没有变**：它们只写本机、不上报服务器（对局的"房主规则项"是另一套，见 `_player_options()`）。
