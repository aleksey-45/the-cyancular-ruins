# 小地图"我"那个点 + 未知队号口径 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 3v3 小地图上"我"那个点可辨认（队色 + 一圈与颜色正交的白描边），并把"未知队号"在客户端的两种口径统一到"不属于任何队"。

**Architecture:** `Minimap` 的第三参颜色提供器是**数组**形状（与"他人点"同序），它没有 role 入参、
也回填不了自己那个点 —— 故**新增一个可选第四参** `self_color_provider: () -> Color`
（team_game 传具名方法 `_minimap_self_color`，内部 `_team_color(PvpSession.role)`）。
必须是**每帧求值的 Callable** 而不是建点时定下的 `Color`：队色由 `match_sync` 下发、比小地图建立晚。
同时给"我"那个点加一圈白描边 —— 同队同色时**颜色本身分不出"我"与队友**，需要正交维度。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、真渲染场景探针（必须**不加** `--headless`）。

**来源 spec:** `docs/superpowers/specs/2026-09-25-team-faction-fixes-design.md` §3.2 + §3.3（计划 2/2）。

## Global Constraints

- **本会话内由实现者跑探针**（用户 2026-09-25 裁定，覆盖 CLAUDE.md 的"跑法分工"默认）。
  ★ **本计划的探针必须真渲染**（不是 `--headless`）：headless 下 `get_viewport().get_texture().get_image()`
  返回 null，取色判据全部拿不到像素 —— 那会**静默跳过**全部像素断言。既有的 `minimap_circle_probe`
  就是真渲染探针，照它的跑法。
- **判据一律是 grep 文本**，不看退出码。
- `--quit-after` **统一给 3600 帧**（安全网）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- 提交**按名 `git add`** 单个文件；提交信息单行；含引号/反引号时用 `git commit -F - <<'EOF'`。
- 字号必须是 **16 的倍数**（`kh_l4`/`kh_l5` 会扫 `res://ui` 与 `res://tests`；本计划不引入字号）。
- **不要新增参数给 1v1 / 大乱斗的调用点** —— 新增的那个是**可选**参数，那两处**一个字都不改**
  （它们的"自己那个点"用 `SELF_COLOR` 青 vs 他人点红，本来就分得开，没有这个问题）。
- 只改 GDScript ⇒ **只需重导出**，别去重编裁剪模板。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `ui/minimap.gd` | 圆形小地图（地形着色器 + 点） | **加**可选第四参 `self_color_provider`、白描边节点 `_ring_self`；`_process` 每帧回填自色 |
| `scenes/team_game.gd` | 3v3 客户端（队色 / 幽灵体层 / 小地图提供器） | **加** `_minimap_self_color()`；**传**第四参；**改** `_ghost_layer_of` 的表外分支 |
| `tests/minimap_circle_probe.gd` | 小地图真渲染探针（已有渲染 rig：`_shot`/`_near`/`_count_near`/`_frames`） | **加**相⑤（自色 + 描边）与相⑥（回到无提供器 ⇒ `SELF_COLOR`） |
| `tests/team_room_smoke.gd` | 3v3 房间纯逻辑 + 源码级接线断言 | **加**两条函数体断言（接在既有 `ghost_body` 那组之后）：`_ghost_layer_of` 的表外分支必须落到层 2 |

---

### Task 1: `Minimap` 支持"自色提供器" + 白描边

**Files:**
- Modify: `ui/minimap.gd`

**Interfaces:**
- Consumes: 现有 `_make_dot(color) -> ColorRect`、`_circle_center() -> Vector2`、
  `SELF_COLOR`、`_color_provider`（第三参，数组形状，**不动**）。
- Produces: `Minimap.setup_multi(local_provider, others_provider, color_provider := Callable(), self_color_provider := Callable())`
  —— 新增第四参 `self_color_provider: () -> Color`；空 `Callable()` ⇒ 行为与今天逐字不变。
  以及节点字段 `_ring_self: ColorRect`（白描边，仅在有自色提供器时可见）。

- [ ] **Step 1: 加字段**

`ui/minimap.gd` 的 `_color_provider` 声明（约 :44-48）之后加：

```gdscript
# 3v3 的"我"那个点:队色提供器 `() -> Color`。**可选**第四参(见 setup_multi)。
# ★ 为什么必须是**每帧求值**的 Callable、而不是建点时定下的 `Color`:队色由 `match_sync`
#   下发,比小地图建立晚 —— 与 `_other_dots` 那条"队色每帧回填"是**同一条理由**。
# ★ 不传 ⇒ 自己那个点走 `SELF_COLOR`,1v1 / 大乱斗的行为逐字不变。
var _self_color_provider: Callable = Callable()
# 自己那个点的**白描边**。★ 同队同色时颜色本身分不出"我"与队友,故需要一个与颜色**正交**
# 的维度 —— 去掉它就等于没修(这不是表现细节,spec §3.2)。1v1 / 大乱斗不显示它。
var _ring_self: ColorRect
```

并加一个常量（放在 `RING_PX` 附近）：

```gdscript
const RING_SELF_PX := 4.0   # "我"那个点的白描边宽度(四边各 4px ⇒ 点 8×8、描边框 16×16)
```

- [ ] **Step 2: 扩 `setup_multi`**

```gdscript
func setup_multi(local_provider: Callable, others_provider: Callable,
		color_provider := Callable(), self_color_provider := Callable()) -> void:
	_local_provider = local_provider
	_others_provider = others_provider
	_color_provider = color_provider
	_self_color_provider = self_color_provider
```

★ 第四参**必须有默认值**：1v1 (`setup`) 与大乱斗 (`setup_multi` 两参) 的调用点**一个字都不改**。

- [ ] **Step 3: `_ready` 里建描边**

`ui/minimap.gd` 的 `_ready` 末尾（`_dot_self = _make_dot(SELF_COLOR)` 之前）加：

```gdscript
	# ★ 描边先建、点后建:Godot 的绘制顺序 = 子节点顺序,后建的在上层 ⇒ 点压在框上。
	_ring_self = _make_dot(Color(1.0, 1.0, 1.0, 1.0))
	_ring_self.size = Vector2(8, 8) + Vector2(RING_SELF_PX, RING_SELF_PX) * 2.0
	_dot_self = _make_dot(SELF_COLOR)
```

- [ ] **Step 4: `_process` 每帧回填自色 + 描边显隐**

1. 位置未知那一段（`_dot_self.visible = false` 那几行）里，一并 `_ring_self.visible = false`。
2. 「自己：恒在圆心」那一段改成：

```gdscript
	# 自己:恒在圆心
	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5
	# ★ 3v3(有自色提供器):自己的点 = **队色**(与身体 / 头顶 ID 同源)+ 一圈白描边。
	#   1v1 / 大乱斗不传它 ⇒ `use_team_self` 为假 ⇒ 走 SELF_COLOR,行为逐字不变。
	var use_team_self := _self_color_provider.is_valid()
	if use_team_self:
		_dot_self.color = _self_color_provider.call()
		_ring_self.visible = true
		_ring_self.position = _circle_center() - _ring_self.size * 0.5
	else:
		_ring_self.visible = false
```

★ `_dot_self.color` **只在有提供器时才覆写** —— 无提供器时保持 `_ready` 里的 `SELF_COLOR`
（每帧重写同一个值也不会错，但"只在需要时写"让 1v1 / 大乱斗那条路径**可读地**不变）。

- [ ] **Step 5: 跑既有探针，确认没弄坏**

Run（真渲染，**不加** `--headless`）:
```bash
source tests/env.sh && "$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn 2>&1 | grep -E "MINIMAP|FAIL|ok  "
```
Expected: 与改动前**逐条相同**的 ok 列表（末行 `MINIMAP CIRCLE PROBE: ALL-OK`）。
★ 本步只证明没弄坏既有断言；自色的鉴别力由 Task 3 的新相提供。

---

### Task 2: `team_game` 接线 + 未知队户口径

**Files:**
- Modify: `scenes/team_game.gd`（`setup_multi` 调用点 :81-86、`_minimap_colors` 附近、`_ghost_layer_of` :207-208）

**Interfaces:**
- Consumes: Task 1 的第四参 `self_color_provider`；现有 `_team_color(role) -> Color`、
  `_minimap_entries()`、`PvpSession.role`。
- Produces: `TeamGame._minimap_self_color() -> Color`（新）；
  `_ghost_layer_of(role)` 的表外分支改为 `2`。

- [ ] **Step 1: 传第四参**

`scenes/team_game.gd` 的小地图建立处（约 :80-86）：

```gdscript
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		# ★ 四个提供器**同序/同源**对应(错位 = 队友点画成敌人色,不报错只误导人)。
		#   后三个用**具名方法**而不是内联 lambda —— 见下面 _minimap_* 三兄弟。
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			Callable(self, "_minimap_others"),
			Callable(self, "_minimap_colors"),
			Callable(self, "_minimap_self_color"))
		add_child(minimap)
```

- [ ] **Step 2: 加 `_minimap_self_color`**

紧挨 `_minimap_colors()`（约 :264-267）之后加：

```gdscript
# "我"那个点的颜色:与**身体 / 头顶 ID 同源** —— 三处都问 `_team_color(role)`(单一来源)。
# ★ 惰性求值(每帧被 Minimap 调一次),不是建点时定色:队色由 `match_sync` 下发,比小地图建立晚。
# ★ 自己那具的身体自 2026-09-21 起也走队色(用户裁定"3v3 青队玩家还是看见自己是蓝色的"被修)——
#   本条让**小地图上那个点**跟上同一口径,此前它是恒定的 SELF_COLOR(`#99F2FF`),
#   与队色 `C_TEAM_B`(`#80F4FF`)只差 Δ=(25,2,0) ⇒ 青队玩家分不清自己与队友。
func _minimap_self_color() -> Color:
	return _team_color(PvpSession.role)
```

- [ ] **Step 3: 统一"未知队号"的落层**

`scenes/team_game.gd:207-208` 改成：

```gdscript
# 副本幽灵体代表的那名玩家,其队号 → 幽灵体该放的碰撞层。
# ★ **未知队号(0 / 表外 role / 队伍表还没到)一律返回 2** —— 与服务端 `_apply_team_layers`
#   的"什么都不配 = 保持 `_ready` 的层 2"**逐值对齐**。
#   旧实现是 `return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER` ——
#   它把"未知"当成了**队 2**,于是客户端与服务端对同一具身体放**不同的层**
#   (服务端层 2 / 客户端幽灵体层 16),而两队掩码不同 ⇒ 队 2 的玩家在服务端**会**被挡住、
#   在客户端**不会** ⇒ C2 每帧分歧。
# ★ 今天这条在**生产路径上到不了**(3v3 worker 的 `team_map()` 恒非空),所以修它是
#   "消除一个静默不对称",不是修一个用户可见的 bug —— 别把它写成用户报的症状。
func _ghost_layer_of(role: int) -> int:
	match _team_of_role(role):
		1:
			return 2
		2:
			return TeamHost.TEAM_ENEMY_LAYER
	return 2   # 表外 / 表未到:与服务端"什么都不配"(保持层 2)对齐,不再落到队 2 的层
```

★ **`return 2` 必须写在 `match` 之外**：GDScript 的 `match` 体内 `continue` 是 fall-through
（落到下一个 pattern、两支都跑），把它当"跳过本次匹配"用会**静默多跑一支**。

- [ ] **Step 4: 启动自检（本 Task 的落点都在这两个文件里）**

Run:
```bash
source tests/env.sh && for i in 1 2; do "$GODOT" --headless --path . --quit-after 120 res://scenes/main_menu.tscn 2>&1 | grep -cE "SCRIPT ERROR|Parse Error"; done
```
Expected: 两行都是 `0`。

---

### Task 3: 探针相⑤⑥ —— 自色是队色且带描边；无提供器时退回 `SELF_COLOR`

**Files:**
- Modify: `tests/minimap_circle_probe.gd`

**Interfaces:**
- Consumes: 该探针已有的 `_shot(png_name) -> Image`、`_near(a, b, tol)`、`_count_near(img, g, want, tol)`、
  `_frames(n)`、`_check(ok, msg)`、`_local`、`BG`；Task 1 的 `Minimap._ring_self` / 第四参。
- Produces: 相⑤（有提供器）与相⑥（无提供器）两组断言，外加一张供**人眼**验收的图
  （`.superpowers/sdd/minimap_self_dot.png`，图**自己读**，别推回给用户）。

- [ ] **Step 1: 加相⑤⑥**

`tests/minimap_circle_probe.gd` 里，在 `_finish()` **之前**插入（`mm` 是既有那个 Minimap，
它是 `setup` 两参建的 —— 先把它 `visible = false`，否则两个圆叠在一起、取色取到的是叠加结果）：

```gdscript
	# ── ⑥ 3v3:自己那个点 = **队色** + 一圈白描边(与颜色正交的维度)──
	# ★ 编号从 ⑥ 起:`tests/minimap_circle_probe.gd` 里 ①②③④⑤ **都已被占用**
	#   (⑤ 是"圆不压延迟条"那条几何断言)—— 别再用 ⑤,否则同一个文件里两个 ⑤。
	# ★ 必须真渲染:判据落在像素上(headless 下 get_image() 返回 null ⇒ 整段静默跳过)。
	mm.visible = false
	var TEAM_B := UiFactory.C_TEAM_B
	var mm_team := Minimap.new()
	mm_team.setup_multi(
		func() -> Vector2: return _local,
		func() -> Array: return [],          # 无他人点:本相只验"我"
		func() -> Array: return [],
		func() -> Color: return TEAM_B)
	add_child(mm_team)
	await _frames(2)
	var img_team := await _shot("minimap_self_dot.png")
	if img_team.get_width() > 0:
		var center := _circle_center_on_screen()
		# ① 点的**底色**是队色,不是 SELF_COLOR
		var px_dot := img_team.get_pixelv(Vector2i(int(center.x), int(center.y)))
		_check(_near(px_dot, TEAM_B, 0.08),
				"3v3 自己那个点的底色应是队色(实际 %s、期望 %s、SELF_COLOR 是 %s)" % [
					str(px_dot), str(TEAM_B), str(Minimap.SELF_COLOR)])
		_check(not _near(px_dot, Minimap.SELF_COLOR, 0.08),
				"★ 反向:底色**不得**还是 SELF_COLOR(那就是没修)")
		# ② 描边存在:点在点外侧、但仍在描边框内的一圈取色(8×8 点 + 4px 边框 ⇒ 半径 4..8 那一带)
		var ring_px := 0
		for i in range(24):
			var a := TAU * float(i) / 24.0
			# ★ 变量名**不能**叫 `q`:`_ready()` 上面那条"圆不压延迟条"的几何断言
			#   (`var q := Vector2(...)`)已经在**同一个函数作用域**里声明过它 ⇒ 重名是 Parse Error,
			#   而后果是**整段探针一条断言都不跑**(2026-09-25 实现者实测踩到,已改名)。
			var q_ring := Vector2i(int(center.x + cos(a) * 6.0), int(center.y + sin(a) * 6.0))
			if _near(img_team.get_pixelv(q_ring), Color(1, 1, 1), 0.08):
				ring_px += 1
		_check(ring_px >= 18,
				"自己那个点应有**白描边**(24 个采样点里 %d 个命中白色,期望 ≥ 18)" % ring_px)
		# ③ 正交维度的**鉴别力**:把描边关掉,同样的采样必须掉下来
		# ★ 必须先 `set_process(false)` —— `Minimap._process` 每帧都会把 `_ring_self.visible`
		#   按 `_self_color_provider` 写回去,直接改 `visible` 会被下一帧覆盖
		#   ⇒ 两张图一模一样 ⇒ 下面那条**必然**失败(那是探针自己的错,不是实现的错)。
		mm_team.set_process(false)
		mm_team._ring_self.visible = false
		await _frames(2)
		var img_no_ring := await _shot("minimap_self_dot_noring.png")
		if img_no_ring.get_width() > 0:
			var ring2 := 0
			for i in range(24):
				var a2 := TAU * float(i) / 24.0
				var q_ring2 := Vector2i(int(center.x + cos(a2) * 6.0), int(center.y + sin(a2) * 6.0))
				if _near(img_no_ring.get_pixelv(q_ring2), Color(1, 1, 1), 0.08):
					ring2 += 1
			_check(ring2 < 6,
					"★ 关掉描边后白色采样必须掉下来(实际 %d)—— 否则上面那条是恒真的" % ring2)
		mm_team.set_process(true)
		mm_team._ring_self.visible = true

	# ── ⑦ 反向对照:不传自色提供器 ⇒ 退回 SELF_COLOR、且描边不可见 ──
	# ★ 这条是"1v1 / 大乱斗行为逐字不变"的守卫 —— 没有它,把默认分支写成"恒走队色"
	#   (或干脆恒真)也能让相⑤全绿,而那会让那两模式的小地图自己那个点变成中性亮白。
	mm_team.visible = false
	var mm_plain := Minimap.new()
	mm_plain.setup_multi(
		func() -> Vector2: return _local,
		func() -> Array: return [],
		func() -> Array: return [])
	add_child(mm_plain)
	await _frames(2)
	_check(_near(mm_plain._dot_self.color, Minimap.SELF_COLOR, 0.001),
			"不传自色提供器 ⇒ 自己那个点应保持 SELF_COLOR(实际 %s)" % str(mm_plain._dot_self.color))
	_check(not mm_plain._ring_self.visible,
			"不传自色提供器 ⇒ 白描边**不可见**(1v1 / 大乱斗没有这个问题,别给它们加标记)")
```

- [ ] **Step 2: 跑 —— 先确认相⑤会红**

临时把 `ui/minimap.gd` 的第四参接线**绕过**（例如把 `_process` 里 `use_team_self` 硬写成
`false`），跑：

```bash
source tests/env.sh && "$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn 2>&1 | grep -E "MINIMAP|FAIL"
```
Expected: 相⑤ 的底色与描边两条 **FAIL**。确认后改回来。
★ 这一步证明相⑤**真的会红**（而不是恒真）—— 本仓反复在删那种"加了断言之后全绿"的假证据。

- [ ] **Step 3: 跑 —— 确认全绿**

Run:
```bash
source tests/env.sh && "$GODOT" --path . --quit-after 3600 res://tests/minimap_circle_probe.tscn 2>&1 | grep -E "MINIMAP|FAIL|ok  "
```
Expected: 全 ok，末行 `MINIMAP CIRCLE PROBE: ALL-OK`。

- [ ] **Step 4: 读图（人眼验收，自己读）**

Read `.superpowers/sdd/minimap_self_dot.png`：圆心那个点应是**青色**（`C_TEAM_B` = `#80F4FF`）
且**带一圈白边**，与既有那张无描边的对照图肉眼可分。**自己读，别推回给用户。**

---

### Task 4: `_ghost_layer_of` 的源码级守卫 + 回归 + 登记

**Files:**
- Modify: `tests/team_room_smoke.gd`（⑨② 那组源码级接线断言附近）
- Modify: `CLAUDE.md`（§网络与 PvP 的 3v3 小节）

**Interfaces:**
- Consumes: `ScanUtil`（`tests/lib/scan_util.gd`，探针已 `extends ProbeBase`）。
- Produces: 两条新的函数体断言（复用现成的 `tcode` / `ghost_body`）。

- [ ] **Step 1: 加两条断言（接在既有的 `ghost_body` 那段之后，复用现成变量）**

`tests/team_room_smoke.gd` **已经**在函数体断言那一段里取了 `_ghost_layer_of` 的函数体：

```gdscript
			var ghost_body := ScanUtil.func_body(tcode, "_ghost_layer_of")
```

紧跟着（约 :211-213）有三条"按队两支"的断言。★★ **那三条区分不了本次要修的两种写法**：
旧的一行三元 `return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER` 同样含
`_team_of_role(` / `return 2` / `TeamHost.TEAM_ENEMY_LAYER`，三条全过。

在那一组断言之后**紧接着**加两条，**复用现成的 `tcode` 与 `ghost_body`，不要另取一份**：

```gdscript
			# ★★ 表外 / 队伍表未到时的**落层**必须与服务端"什么都不配"(保持 `_ready` 里那句层 2)
			#   对齐。旧实现把"未知"当成了**队 2**:客户端幽灵体层 16、服务端层 2 ⇒ 队 2 的玩家
			#   在服务端**会**被挡住、在客户端**不会** ⇒ C2 每帧分歧(不报错)。
			#   ★ 上面那一组"按队两支"**区分不了**这两种写法(旧的一行三元三样全含)——
			#     鉴别点在**结构**:新形状是 `match` + 两支 + **match 之外**的兜底 `return 2`,
			#     故 `return 2` 出现**两次**,而旧写法只有一次。
			if ghost_body.count("return 2") < 2:
				fails.append("★ _ghost_layer_of 丢了表外兜底:未知队号必须落到层 2(与服务端'什么都不配'对齐);旧写法把未知当队 2 ⇒ 两端层不一致 ⇒ C2 每帧分歧,不报错")
			if not ghost_body.contains("match"):
				fails.append("★ _ghost_layer_of 的形状不对:必须是 `match _team_of_role(...)` + 两支 + match **之外**的 `return 2`(GDScript 的 match 体内 `continue` 是 fall-through,兜底写进 match 会静默多跑一支)")
```

★ 本文件是 **`extends SceneTree` 的 `-s` 冒烟**（不是 `ProbeBase` 场景探针），
报失败用 **`fails.append(...)`**；函数体取法用 **`ScanUtil.func_body(code_only源码, "函数名")`**。

- [ ] **Step 2: 跑 —— 先证明这两条会红**

临时把 `_ghost_layer_of` 改回旧的一行三元
（`return 2 if _team_of_role(role) == 1 else TeamHost.TEAM_ENEMY_LAYER`），跑：

```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/team_room_smoke.gd 2>&1 | grep -E "TEAM ROOM|_ghost_layer_of"
```
Expected: `FAIL`，且点名 `_ghost_layer_of`。确认后改回新实现。

- [ ] **Step 3: 回归**

Run:
```bash
source tests/env.sh
for t in team_host_probe team_table_probe team_disconnect_probe; do
  echo "--- $t ---"
  "$GODOT" --headless --path . --quit-after 3600 res://tests/$t.tscn 2>&1 | grep -E "ALL-OK|FAIL"
done
"$GODOT" --headless --path . -s res://tests/team_room_smoke.gd 2>&1 | grep -E "TEAM ROOM|FAIL"
"$GODOT" --path . --quit-after 3600 res://tests/hue_tint_probe.tscn 2>&1 | grep -E "KH HUE-TINT|FAIL"
```
Expected: 全绿（`hue_tint_probe` **必须真渲染**，不加 `--headless`；它的守卫 C/D/E 覆盖 1v1/大乱斗/3v3
三条色相链，本批动了 `team_game`，必须复跑）。

- [ ] **Step 4: 登记进 CLAUDE.md**

在 §网络与 PvP 的 3v3 小节、以及 §UI 的小地图那一条里各补一句：

```markdown
- **自己那个点(2026-09-25 补)**:3v3 下 = `_team_color(PvpSession.role)`(与身体/头顶 ID 同源)
  **+ 一圈白描边**(`Minimap.RING_SELF_PX`,与颜色正交 —— 同队同色时颜色本身分不出"我"与队友,
  去掉它就等于没修)。走 `setup_multi` 的**可选第四参** `self_color_provider`(每帧求值的 Callable;
  队色由 `match_sync` 下发、比小地图建立晚,建点时定色会定成中性亮白)。**1v1 / 大乱斗不传该参**
  ⇒ 保持 `SELF_COLOR`,行为逐字不变(守卫:相⑥)。
```

并订正 §3.3 那条:把"未知队号在三个消费点三种口径"改为**两处已统一**(客户端颜色 / 幽灵体层都表示
"不属于任何队"),服务端仍是"什么都不配 = 保持默认层"(不在服务端引入"未知"这个概念)。

- [ ] **Step 5: 提交**

```bash
git add ui/minimap.gd scenes/team_game.gd tests/minimap_circle_probe.gd tests/team_room_smoke.gd CLAUDE.md
git commit -m "feat(team): 小地图自己那个点改队色 + 白描边;未知队号幽灵体层统一为 2"
```

---

## Self-Review

**1. 覆盖面**（对照 spec §3.2 + §3.3）：可选第四参 ✅ Task 1 Step 2；每帧求值 ✅ Task 1 Step 4；
白描边（正交维度）✅ Task 1 Step 3；team_game 接线 ✅ Task 2 Step 1/2；1v1/大乱斗不变 ✅ 相⑥；
未知队号统一 ✅ Task 2 Step 3 + Task 4 那两条函数体断言；验收判据 2（新渲染断言 + 反证）✅ Task 3 Step 2；
判据 3（既有探针全绿）✅ Task 4 Step 3。

**2. 占位符扫描**：无 TBD / "类似 Task N"；每处改动都给了完整代码与确切锚点。
唯一一处"照抄既有写法"是 Task 4 Step 1 的函数体取法 —— 那是**刻意的**（同文件的 ⑨② 已经有
一套取法，再抄一份进计划会让两处漂移），并已指明去看 ⑨② 。

**3. 类型一致性**：`self_color_provider: () -> Color`（Task 1 定义、Task 2 Step 2 实现、
Task 3 传 `func() -> Color: return TEAM_B`）三处一致；`_ring_self: ColorRect` 与 `_make_dot`
的返回类型一致；`RING_SELF_PX` 只在 Task 1 内使用。

**4. 与计划 1 的关系**：两份计划**完全独立**（不同文件、不同模式面）——
本计划碰 `ui/minimap.gd` / `scenes/team_game.gd` / `tests/minimap_circle_probe.gd` / `tests/team_room_smoke.gd`，
计划 1 碰 `server/match_state.gd` / `scenes/weapons/laser_weapon_base.gd` / `tests/laser_team_probe.*`。
可并行；若要串行，**先计划 1 后计划 2**（计划 1 修的是用户实际报的友伤 bug）。

**5. 已知边界（承自 spec §4，登记不修）**：`_team_color` 的表外分支返回中性亮白，而服务端对表外是
"保持默认层" —— 两者的"未知"在**颜色**与**碰撞**上仍不是同一个概念。本次只把客户端自己的两处
（颜色 / 幽灵体层）对齐，**没有**在服务端引入"未知"。大乱斗的小地图上所有他人点仍恒为红色（无提供器）。
