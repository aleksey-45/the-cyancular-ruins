# ESC 菜单 + PvP HUD 微调 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PvP 双方头顶名字统一中性亮白;PvP 中央公告两行各自水平居中;单机与 PvP 加 ESC 呼出菜单(灰色遮罩 + 「退出」按钮),单机呼出即暂停、两种模式退出都回主菜单。

**Architecture:** 新一份可复用 ESC 菜单场景(`ui/esc_menu.tscn` + `ui/esc_menu.gd`,`class_name EscMenu`),由两个宿主分别接线:单机 `Level0`(`scenes/level_0.gd`)接成「开= `get_tree().paused`、退出=解暂停回主菜单」;PvP `pvp_client` 接成「开=锁本地输入(`set_controls_locked`)、退出= `NetBus.stop()` 回主菜单」,均不写死进 `Level0.tscn`(PvP 也会实例化 `Level0` 当世界,塞进去会双菜单)。名字颜色与公告居中是纯常量/tscn 小改。

**Tech Stack:** Godot 4.7.1 标准版(GDScript)。测试 = `extends SceneTree` 冒烟,用 `-s` 跑(`tests/esc_menu_smoke.gd`)。视觉项(颜色/居中/mask 观感)由用户肉眼验收。

## Global Constraints

- 编辑器与冒烟均用绝对路径:`D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe`。
- 新建 `.gd` 会附带生成 `.gd.uid`,须 `--headless --path . --import` 一次生成后一并入库(本仓库随 .gd 跟踪 .uid;新 `class_name` 还要靠这次 import 刷全局类缓存)。
- 测试跑法按仓库惯例(CLAUDE.md 冒烟命令);视觉/手感项用户亲自验,不代跑。
- 冒烟脚本是 `extends SceneTree`;`-s` 阶段 autoload 未实例化,引用脚本一律在函数内 `load()`,禁止文件级静态 `preload` 带出 autoload 链。
- 退出路径统一回 `res://scenes/main_menu.tscn`;切场景前若处于暂停必须先把 `get_tree().paused` 复位。

---

### Task 1: EscMenu 场景 + 脚本 + 冒烟(TDD)

**Files:**
- Create: `ui/esc_menu.gd`(含 `class_name EscMenu`)
- Create: `ui/esc_menu.tscn`
- Test: `tests/esc_menu_smoke.gd`

**Interfaces:**
- Produces:`EscMenu`(extends CanvasLayer)公开 API:
  - `signal toggled(open: bool)` — 每次开/关切换发一次(宿主据此暂停/锁输入)
  - `var exit_callback: Callable` — 宿主注入「退出」动作
  - `var can_toggle := true` — false 时忽略 ESC(PvP 对局结束后关掉)
  - `func toggle() -> void` — 翻转开/关并发 `toggled`(`_process` 里 ESC 也走它;冒烟直接调它)
  - `func is_open() -> bool` / `func set_open(open: bool) -> void`
  - 场景节点:`Mask`(全屏 ColorRect)、`Center/VBox/ExitButton`(Button)
  - 内部行为:根 `process_mode = ALWAYS`;`_process` 在 `can_toggle` 且按 `ui_cancel` 时 `toggle()`;`ExitButton.pressed` → `exit_callback.call()`;`_ready` 先 `set_open(false)`。

- [ ] **Step 1: 写失败冒烟**

Create `tests/esc_menu_smoke.gd`:

```gdscript
extends SceneTree
# EscMenu 源码级冒烟:实例化 tscn(不渲染/不真实输入),直接驱动公开 API,
# 验证开关状态/toggled 信号/单机接法(open→paused)/退出按钮→exit_callback。
# 宿主契约由宿主各自接:这里验 EscMenu 自身 + 单机「开=暂停」这一种典型接法。

var _fail := 0

func _initialize() -> void:
	var scene: PackedScene = load("res://ui/esc_menu.tscn")
	if scene == null:
		printerr("FAIL - 无法 load esc_menu.tscn")
		quit(1)
		return
	var menu: Node = scene.instantiate()
	root.add_child(menu)
	_check(!menu.is_open(), "初始应为关闭")
	_check(menu.process_mode == Node.PROCESS_MODE_ALWAYS, "process_mode 应为 ALWAYS(暂停期可用)")

	var fired := false
	menu.exit_callback = func() -> void: fired = true

	var paused := false
	menu.toggled.connect(func(open: bool) -> void: paused = open)   # 单机接法:开=暂停

	menu.toggle()
	_check(menu.is_open(), "toggle 后应打开")
	_check(paused, "单机接法:打开时 paused 应为 true")

	var exit_btn: Button = menu.get_node("Center/VBox/ExitButton")
	exit_btn.pressed.emit()
	_check(fired, "按退出应触发 exit_callback")

	menu.toggle()
	_check(!menu.is_open(), "再 toggle 应关闭")
	_check(not paused, "单机接法:关闭时 paused 应为 false")

	menu.queue_free()
	if _fail == 0:
		print("ESC MENU SMOKE OK")
	quit(0 if _fail == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok - " + msg)
	else:
		_fail += 1
		printerr("FAIL - " + msg)
```

- [ ] **Step 2: 跑冒烟确认失败(缺文件)**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/esc_menu_smoke.gd`
Expected: FAIL(load 不到 esc_menu.tscn)或脚本解析报错,退出码非 0。

- [ ] **Step 3: 建 `ui/esc_menu.gd`**

```gdscript
class_name EscMenu
extends CanvasLayer
# ESC 菜单(单机/PvP 共用):全屏灰色遮罩 + 居中「退出」按钮。
# 是否暂停由宿主决定(见 toggled 信号接线),本脚本只负责:
#   1) ESC 开/关 + 发 toggled(open)  2) ExitButton → exit_callback
# 根 process_mode=ALWAYS:单机暂停期间仍能收键鼠。菜单自带节点都在 esc_menu.tscn。

signal toggled(open: bool)

# 宿主注入:「退出」按下后的动作(单机=解暂停回主菜单;PvP=断连回主菜单)。
var exit_callback: Callable = Callable()
# false 时忽略 ESC(PvP 对局已结束/对手已走就关掉,免得与自动回菜单打架)。
var can_toggle := true

@onready var _center: Control = $Center
@onready var _mask: ColorRect = $Mask

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	($Center/VBox/ExitButton as Button).pressed.connect(_on_exit_pressed)
	set_open(false)

func _process(_delta: float) -> void:
	if can_toggle and Input.is_action_just_pressed("ui_cancel"):
		toggle()

func toggle() -> void:
	set_open(not is_open())
	toggled.emit(is_open())

func is_open() -> bool:
	return _center.visible

func set_open(open: bool) -> void:
	_center.visible = open
	_mask.visible = open

func _on_exit_pressed() -> void:
	if exit_callback.is_valid():
		exit_callback.call()
```

- [ ] **Step 4: 建 `ui/esc_menu.tscn`**

```text
[gd_scene load_steps=3 format=3 uid="uid://c000escmenu00a"]

[ext_resource type="Script" path="res://ui/esc_menu.gd" id="1"]
[ext_resource type="FontFile" path="res://assets/fonts/less_perfect_dos_vga.ttf" id="2"]

[node name="EscMenu" type="CanvasLayer"]
layer = 150
process_mode = 3
script = ExtResource("1")

[node name="Mask" type="ColorRect" parent="."]
visible = false
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
color = Color(0.16, 0.17, 0.19, 0.62)

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
theme_override_constants/separation = 24

[node name="ExitButton" type="Button" parent="Center/VBox"]
custom_minimum_size = Vector2(360, 96)
theme_override_font_sizes/font_size = 56
theme_override_fonts/font = ExtResource("2")
text = "退出"
```

- [ ] **Step 5: 刷 import(生成 .uid + 刷 class cache)**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --import`
Expected: 正常退出;出现 `ui/esc_menu.gd.uid`、`tests/esc_menu_smoke.gd.uid`。

- [ ] **Step 6: 跑冒烟确认通过**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/esc_menu_smoke.gd`
Expected: 打印 `ESC MENU SMOKE OK`,退出码 0。

- [ ] **Step 7: Commit**

```bash
git add ui/esc_menu.gd ui/esc_menu.gd.uid ui/esc_menu.tscn tests/esc_menu_smoke.gd tests/esc_menu_smoke.gd.uid
git commit -m "feat: 新增 EscMenu 场景(灰色遮罩+退出按钮,ESC 开关)——process_mode ALWAYS、toggled 信号/exit_callback 供宿主接线;esc_menu 冒烟"
```

---

### Task 2: PvP 名字统一亮白 + 中央公告两行各自居中(纯小改,视觉用户验)

**Files:**
- Modify: `scenes/pvp_client.gd:36`(const 区)、`scenes/pvp_client.gd:357-360`(`_on_peer_info`)
- Modify: `ui/pvp_hud.tscn`(BigLabel / SubLabel 各加一行)

**Interfaces:**
- Consumes: `world_label.set_label(text: String, color: Color)` 不变。
- Produces:(无新接口)名字颜色常量 `NAME_COLOR`;公告两行布局改为各自居中。

- [ ] **Step 1: pvp_client 名字改亮白**

`scenes/pvp_client.gd` 第 36 行整行(删除 `ROLE_COLOR` 常量):

```gdscript
const ROLE_COLOR := {1: Color(0.72, 0.93, 1.0), 2: Color(1.0, 0.82, 0.62)}
```

改为:

```gdscript
# 头顶名字统一中性亮白(不再按角色区分颜色;P2 靠身体色相 shader 区分)。world_label 内部再叠 0.85 alpha。
const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)
```

`_on_peer_info` 里(第 359-360 行)两处 `ROLE_COLOR.get(...)` 调用改为 `NAME_COLOR`:

```gdscript
	_id_self.set_label(nm_self, NAME_COLOR)
	_id_opp.set_label(nm_opp, NAME_COLOR)
```

(grep 已确认 `ROLE_COLOR` 全仓仅此两处引用,删除安全。)

- [ ] **Step 2: pvp_hud 两行各自居中**

`ui/pvp_hud.tscn`:`Center/VBox/BigLabel` 与 `Center/VBox/SubLabel` 各自在 `text = ""` 之后加一行 `horizontal_alignment = 2`。改完两个节点块为:

```text
[node name="BigLabel" type="Label" parent="Center/VBox"]
theme_override_colors/font_color = Color(0.95, 0.95, 0.95, 0.9)
theme_override_font_sizes/font_size = 150
theme_override_fonts/font = ExtResource("2")
text = ""
horizontal_alignment = 2

[node name="SubLabel" type="Label" parent="Center/VBox"]
theme_override_colors/font_color = Color(0.82, 0.84, 0.9, 0.85)
theme_override_font_sizes/font_size = 64
theme_override_fonts/font = ExtResource("2")
text = ""
horizontal_alignment = 2
```

- [ ] **Step 3: 解析验证(不代跑视觉)**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 60`
Expected: 无脚本解析报错即可(单机世界能起)。名字颜色/两行居中的实际观感由用户进 PvP 肉眼确认。

- [ ] **Step 4: Commit**

```bash
git add scenes/pvp_client.gd ui/pvp_hud.tscn
git commit -m "tweak: PvP 头顶名字统一中性亮白(删 ROLE_COLOR);PvP 中央公告 Big/Sub 两行各自水平居中"
```

---

### Task 3: 单机接线——Level0 挂菜单(暂停 + 退出回主菜单)

**Files:**
- Modify: `scenes/level_0.gd`(单机分支末尾;类首加字段声明按需)

**Interfaces:**
- Consumes: `EscMenu`(`ui/esc_menu.tscn`):`toggled` / `exit_callback`;`Level0.pvp_mode`(static bool,本任务不建菜单时靠它区分,PvP 已在 `pvp_client` 接线)。
- Produces:单机在 Level0 运行时按 ESC 弹菜单并 `get_tree().paused = true`;点「退出」解暂停回 `res://scenes/main_menu.tscn`。

- [ ] **Step 1: 加接线代码**

`scenes/level_0.gd` `_ready()` 单机分支末尾(`call_deferred("add_child", pp)` 那行之后、`func _ready` 收尾 `}` 之前)追加一行:

```gdscript
	_build_esc_menu()
```

文件末尾追加方法(注意 `_build_esc_menu` 只会在单机分支被调,PvP 下 `_ready` 早 return 不执行):

```gdscript
# 单机 ESC 菜单:呼出=暂停整份模拟,退出=解暂停后回主菜单。
# (PvP 菜单由 pvp_client._ready 自建——PvP 下本方法不会被调,见 _ready 的 pvp_mode 早 return。)
func _build_esc_menu() -> void:
	var esc := (load("res://ui/esc_menu.tscn") as PackedScene).instantiate()
	add_child(esc)
	esc.exit_callback = func() -> void:
		get_tree().paused = false   # 先复位暂停再切场景,别把暂停带进主菜单
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	esc.toggled.connect(func(open: bool) -> void:
		get_tree().paused = open)
```

- [ ] **Step 2: 解析验证 + 用户手感验收**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 60`
Expected: 无解析报错。**用户手动**:单机开局按 ESC → 菜单出现且敌人/子弹/玩家全冻结;再按 ESC → 恢复;点「退出」→ 回主菜单、主菜单能正常点按钮(未残留暂停)。

- [ ] **Step 3: Commit**

```bash
git add scenes/level_0.gd
git commit -m "feat: 单机 ESC 菜单接线——呼出暂停(process_mode ALWAYS 保活)、退出解暂停回主菜单"
```

---

### Task 4: PvP 接线——pvp_client 挂菜单(锁本地输入 + 断连退出)

**Files:**
- Modify: `scenes/pvp_client.gd`(字段区 ~L32、`_ready` ~L86、`_on_round_state`、文件内加两个方法)

**Interfaces:**
- Consumes: `EscMenu.toggled` / `EscMenu.can_toggle` / `EscMenu.exit_callback`;玩家方法 `set_controls_locked(b: bool)`(已有,`has_method` 守卫);`PvpSession`/`NetBus` 现成。
- Produces:PvP 运行中按 ESC 弹菜单,本地输入冻结;点「退出」`NetBus.stop()` 回主菜单;对局已结束(`_match_ended`)后不再响应 ESC。

- [ ] **Step 1: 加字段**

`scenes/pvp_client.gd` 字段区(约 L30 附近,`_match_ended` 下)追加:

```gdscript
var _esc_menu: CanvasLayer = null
var _round_locked := false   # COUNTDOWN 冻结态(菜单关时按它还原,别把倒计时里提前解锁)
```

- [ ] **Step 2: _ready 挂菜单**

`scenes/pvp_client.gd` `_ready()` 里 `_apply_p2_tint()` 之后(约 L89)追加:

```gdscript
	# ESC 菜单(PvP 不暂停,对手实时):打开锁本地输入,退出断连回主菜单
	var esc: CanvasLayer = (load("res://ui/esc_menu.tscn") as PackedScene).instantiate()
	add_child(esc)
	_esc_menu = esc
	esc.exit_callback = _esc_exit
	esc.toggled.connect(_on_esc_toggled)
```

- [ ] **Step 3: _on_round_state 记冻结态**

现有段(约 L277-279):

```gdscript
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(state == 0)
```

改为:

```gdscript
	if _local != null and _local.has_method("set_controls_locked"):
		_round_locked = state == 0
		_local.set_controls_locked(_round_locked)
```

`state == 3`(MATCH_OVER)分支里 `_match_ended = true` 之后追加一行(关掉 ESC,避免与 5s 自动回菜单打架):

```gdscript
		if _esc_menu != null:
			_esc_menu.can_toggle = false
```

- [ ] **Step 4: 加两个方法**

文件内追加(放 `_on_opponent_left` 之后):

```gdscript
# ESC 菜单开关:打开期间连 COUNTDOWN 冻结一起锁本地输入;关闭按当前对局冻结态还原。
func _on_esc_toggled(open: bool) -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(open or _round_locked)

# ESC 菜单「退出」:断连对局回主菜单(与断线/MATCH_OVER 同路径;服务器拆局、对手看到离开)。
func _esc_exit() -> void:
	if _match_ended:
		return   # 已排程自动回菜单(NetBus.stop 幂等但不必重复切场景)
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
```

- [ ] **Step 5: 解析验证 + 用户手感验收**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 60`
Expected: 无解析报错。**用户手动**(双开本地服务端 + 两端 PvP):局内按 ESC → 弹菜单、本地角色不响应移动/开火;点「退出」→ 断连回主菜单,对手端弹出「对手已离开」并回主菜单。

- [ ] **Step 6: Commit**

```bash
git add scenes/pvp_client.gd
git commit -m "feat: PvP ESC 菜单接线——打开锁本地输入、退出断连回主菜单、MATCH_OVER 后关闭 ESC"
```

---

## Self-Review(计划自查)

- **Spec 覆盖**:① 名字同色 → Task 2 Step 1 ✓;② 公告两行各自居中 → Task 2 Step 2 ✓;③ ESC 菜单结构/灰色 mask/退出按钮 → Task 1 ✓;单机暂停 + 退出回菜单 → Task 3 ✓;PvP 不暂停、锁本地输入、退出回菜单 → Task 4 ✓;spec 的 `_round_locked`/`_match_ended`/退出复位暂停边界全部落进对应任务 ✓。
- **占位符**:无 TBD/TODO;每个改动都给足代码。
- **类型一致性**:`EscMenu` 公开名 `toggle/is_open/set_open/toggled/exit_callback/can_toggle` 在 Task 1 定义、Task 3/4 与冒烟引用一致;宿主均按 `load("res://ui/esc_menu.tscn")` 路径实例化,不依赖跨任务 class 缓存顺序;`_on_round_state` 变量名 `_round_locked` 在 Task 4 内自洽。
