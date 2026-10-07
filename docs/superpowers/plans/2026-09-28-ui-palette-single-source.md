# 统一 UI 调色板配置（底板色 + 队色）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 底板色与队色各收敛到**一个数值源**；两个结构上派生不了的 `.tscn` 落点用守卫把「改漏」从**静默**变成**响亮**。

**Architecture:** 调色板 `ui/ui_factory.gd` 新增 `C_PLATE` 作为底板色的唯一源 → 四个 `.gd` 落点改成**别名**（`const PLATE_COLOR := UiFactory.C_PLATE`，别名里**没有字面量** ⇒ 不构成第二个源）→ 两个 `.tscn` 的 `bg_color` **结构上引用不到 GDScript 的 const**（它是 `StyleBoxFlat` 的属性，不是资源引用），故**保留字面量 + 新增一条 `-s` 守卫读文本断言约束逐位相等** → `BODY_BASE_COLOR` 同样改成 `C_TEAM_A` 的别名。
本计划**不引入 Theme / `.tres`、不改任何渲染初始化顺序**（那是 spec §7 明确不做的事）。

**Tech Stack:** Godot 4.7.1（标准版）、GDScript、`ScanUtil`（`tests/lib/scan_util.gd`，纯静态、无 Node 依赖、`-s` 可用）。

**来源 spec:** `docs/superpowers/specs/2026-09-28-ui-palette-single-source-design.md`。

---

## Global Constraints

- **本计划不改任何一个像素。** 若某个**真渲染**探针出的图变了，那是 bug，不是预期 —— 停下来查。
- **判据一律是 grep 文本**，不看退出码：脚本挂住时 `--quit-after` 到期仍 `exit 0` 且一行裁决都不打印。
- **`--quit-after` 统一给 3600 帧**（安全网，只在挂住时用得上）。
- 引擎二进制走环境变量：先 `source tests/env.sh`，再用 `"$GODOT"`。
- **跑法分工**：本计划新增的守卫是 `-s`（headless、不占端口、可由 agent 跑）；被回归波及的
  `hue_tint_probe` / `kh_l3_visual_probe` / `combat_hud_visual_probe` 是**真渲染**探针
  （**不能加 `--headless`**，headless 下 `get_image()` 给 null ⇒ 直接 FAIL）—— 它们由**用户**跑并读图。
- ★ **两支 Godot 测试之间查一次残留**：`tasklist | grep -i godot` 应为空。本计划的探针都不起子进程，
  但这是本仓 2026-09-27 起的新纪律（孤儿 worker 会让下一支**静默挂住**）。
- 提交**按名 `git add`** 单个文件，不用 `git add -A` / `git add .`；提交信息单行。
  本仓在 Windows 上经 Git Bash 跑：提交信息含引号/反引号时用 `git commit -F - <<'EOF'`，
  别用 `-m "…"`（双引号会**静默吞掉**反引号与 `$`）。
- **字号必须是 16 的倍数**（`kh_l4`/`kh_l5` 扫 `res://ui` 与 `res://tests`）。本计划**不引入任何新字号**。
- ★★ **本计划会改 `res://ui` 与 `res://tests` 下的文件**，而 `kh_l5_probe` 的「新接口归属」扫描
  （含否定断言：基类不得含子类方法）与字号规范都覆盖这两个目录 ⇒ Task 4 必须跑 `kh_l4` / `kh_l5`。
- 改 GDScript **只需重导出**，不要重编裁剪模板。

---

## File Structure

| 文件 | 责任 | 本计划怎么动 |
|---|---|---|
| `ui/ui_factory.gd` | **UI 的唯一工厂与唯一调色板** | 新增 `const C_PLATE`（+ 把 `ui/hud.gd` 那段 WCAG 推导整体搬来） |
| `ui/hud.gd` | 单机 HUD | `PLATE_COLOR` 改**别名**；长注释搬走后原地留一行指路 |
| `ui/weapon_slots.gd` | 左下角武器格子控件 | `PLATE_COLOR` 改**别名** |
| `ui/world_label.gd` | 头顶 ID 标签 | `PLATE_COLOR` 改**别名** |
| `ui/royale_hud.gd` | 大乱斗 HUD | `_plate_box()` 的**内联字面量**改引用（★ `_board_bg` 的 0.25 一字不动） |
| `ui/pvp_hud.tscn` | 1v1 HUD | `Plate` 的 `bg_color` **原样保留**，加一行 `;` 注释说明它是「副本」 |
| `ui/team_hud.tscn` | 3v3 HUD | 同上 |
| `scenes/pvp_match_client.gd` | PvP 客户端基类（染色 / 快照消费） | `BODY_BASE_COLOR` 改**别名** |
| `tests/ui_palette_single_source_smoke.gd` | **新守卫**：统一调色板配置 | 全新建（`-s`、headless） |
| `CLAUDE.md` | 项目说明 | §UI 那段「已知落点 + grep 命令」改写成指向唯一源与守卫 |

---

### Task 1: 守卫先行 —— 让「6 个源」变成可断言的红灯

**Files:**
- Create: `tests/ui_palette_single_source_smoke.gd`

**Interfaces:**
- Consumes: `ScanUtil.read(path: String) -> String`、`ScanUtil.code_only(text: String) -> String`、
  `ScanUtil.collect(dirs: Array) -> Array[String]`（`tests/lib/scan_util.gd`，均静态、无 Node 依赖）。
- Produces: 一个**会红**的守卫。判据是文本 `UI PALETTE: ALL-OK`。

- [ ] **Step 1: 写守卫**

创建 `tests/ui_palette_single_source_smoke.gd`（完整内容如下）：

```gdscript
extends SceneTree

# UI 调色板**单一来源**守卫(底板色 + 队色)。纯源码级、`-s` 可跑、不占端口、**不需要渲染**。
#
# 跑法:  source tests/env.sh && timeout 120 "$GODOT" --headless --path . \
#            -s res://tests/ui_palette_single_source_smoke.gd
# 判据:  文本 `UI PALETTE: ALL-OK`(**不看退出码** —— 挂住时一行裁决都不打印)。
#
# ═══ 为什么需要它 ═══
# 底板色 `Color(0, 0, 0, 0.1)` 原先有 **6 个**独立落点(3 个 `.gd` 常量 + 1 处内联 +
# **2 个 `.tscn` 字面量**),而**一个守卫都没有** —— 漏改是**静默**的,只靠 `CLAUDE.md` 里
# 一条"手工 grep 对账"的纪律维持。本守卫钉死两件事:
#   ① 四个 `.gd` 落点**必须引用** `UiFactory.C_PLATE`(而不是又写一个字面量);
#   ② 两个 `.tscn` 的 `bg_color` **结构上引用不到 GDScript 的 const**(它是 StyleBoxFlat 的
#      属性,不是资源引用)⇒ 只能留字面量 —— 由本守卫**读文本**断言它与 `C_PLATE` **逐位相等**。
# 队色同理:`BODY_BASE_COLOR` 必须引用 `UiFactory.C_TEAM_A`(两份逐位相同的字面量 → 一份)。
#
# ★ 判据一律**剥注释后**匹配(`ScanUtil.code_only`) —— 否则那些"这是唯一源"的说明文字会把它
#   自己判红。
# ★ `.tscn` 不是 GDScript,`code_only` 不适用 ⇒ 那两处读**原文**,并归一化空白后比较。
# ★ 为什么另立 `-s` 而不并进 `hue_tint_probe`:后者是**真渲染**探针(headless 下
#   `get_image()` 给 null ⇒ 直接 FAIL 并 return),源码级断言不该寄生在它里面。
#
# ★★ **已知的判据上限(登记,别当漏洞)**:本守卫只钉这 **6 处**具名落点 + 一条"全仓再无
#    游离字面量"的反向断言。将来新增第 7 处时,反向断言会红 —— **前提是它写成
#    `Color(0, 0, 0, 0.1)` 字面量**;若写成第三种 `const` 名字,反向断言抓不到。

const PALETTE := "res://ui/ui_factory.gd"
# 底板色字面量的**归一化后**形态(空白在 `_norm` 里被去掉)。
const PLATE_LITERAL := "Color(0,0,0,0.1)"
# 队 1 token 的重复字面量(改前 `BODY_BASE_COLOR` 就是这个) —— 归一化后。
const TEAM_A_LITERAL := "Color(99.0/255.0,155.0/255.0,1.0)"

# 四个 `.gd` 落点:三处 `const PLATE_COLOR` + 一处内联(`royale_hud._plate_box`)。
const GD_SITES := [
	"res://ui/hud.gd",
	"res://ui/weapon_slots.gd",
	"res://ui/world_label.gd",
	"res://ui/royale_hud.gd",
]
# 两个**结构上无法派生**的落点:`.tscn` 里 StyleBoxFlat 的 bg_color。
const TSCN_SITES := [
	"res://ui/pvp_hud.tscn",
	"res://ui/team_hud.tscn",
]
# 队色那一半。
const BODY_BASE_SITE := "res://scenes/pvp_match_client.gd"
# ⑤ 反向断言的白名单 = 允许出现底板色**字面量**的文件:
#   调色板自己(它就是源)+ 两个 `.tscn`(结构上派生不了)+ **本文件自己**
#   (`PLATE_LITERAL` 这个常量本身就把那串字写在了源码里 —— 不白名单它,⑤ 会自己判自己红)。
const LITERAL_ALLOWED := [PALETTE, "res://ui/pvp_hud.tscn", "res://ui/team_hud.tscn",
		"res://tests/ui_palette_single_source_smoke.gd"]
# ⑤ 扫的目录(生产 + 测试)。
const SCAN_DIRS := ["res://ui", "res://scenes", "res://core", "res://server", "res://tests"]


func _initialize() -> void:
	var fails: Array[String] = []

	# ── ① 唯一源在位,并取出它的值(原文) ──
	var pal_code := ScanUtil.code_only(ScanUtil.read(PALETTE))
	if pal_code.is_empty():
		# 读不到 = 本守卫失明 ⇒ 直接红,不静默跳过。
		print("  FAIL ① 读不到 %s(读不到就是红,不是静默跳过)" % PALETTE)
		print("UI PALETTE: FAIL(1 条)")
		quit(1)
		return
	var plate_rhs := _rhs_of(pal_code, "const C_PLATE")
	if plate_rhs == "":
		fails.append("① `%s` 里没有 `const C_PLATE`(唯一源不存在)" % PALETTE)
	elif _norm(plate_rhs) != PLATE_LITERAL:
		fails.append("① `C_PLATE` 的值不是底板色(实得「%s」)" % plate_rhs)

	# ── ② 四个 `.gd` 落点:必须引用源,**且不许留字面量** ──
	for path in GD_SITES:
		var code := ScanUtil.code_only(ScanUtil.read(path))
		if code.is_empty():
			fails.append("② 读不到 %s(读不到就是红)" % path)
			continue
		if not code.contains("UiFactory.C_PLATE"):
			fails.append("② %s 没有引用 `UiFactory.C_PLATE`(它该是别名/引用,不是第二个源)" % path)
		if code.contains(PLATE_LITERAL):
			fails.append("② %s 里还有底板色**字面量**(别名里不该有字面量)" % path)

	# ── ③ `BODY_BASE_COLOR` 必须引用 `UiFactory.C_TEAM_A` ──
	var body := ScanUtil.code_only(ScanUtil.read(BODY_BASE_SITE))
	if body.is_empty():
		fails.append("③ 读不到 %s(读不到就是红)" % BODY_BASE_SITE)
	else:
		if not body.contains("UiFactory.C_TEAM_A"):
			fails.append("③ %s 的 `BODY_BASE_COLOR` 没有引用 `UiFactory.C_TEAM_A`" % BODY_BASE_SITE)
		if body.contains(TEAM_A_LITERAL):
			fails.append("③ `BODY_BASE_COLOR` 那份**重复字面量**还在(应改成别名)")

	# ── ④ 两个 `.tscn`:读原文,断言 bg_color 与 `C_PLATE` **逐位相等** ──
	#    ★ 比的是**调色板里那个值**(不是本文件里那串字) —— 这样"改了 C_PLATE 却没改 .tscn"
	#      才会红。① 已经失败时这里必然也红(没有可比的值),那是正确的连带。
	for path in TSCN_SITES:
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("④ 读不到 %s(读不到就是红)" % path)
			continue
		var got := _tscn_bg_color(raw)
		if got == "":
			fails.append("④ %s 里找不到 `bg_color = Color(...)`(形状变了 ⇒ 本守卫失明)" % path)
			continue
		if plate_rhs == "" or _norm(got) != _norm(plate_rhs):
			fails.append("④ %s 的 `bg_color` 与 `C_PLATE` 不等(实得「%s」,期望「%s」)"
					% [path, got, plate_rhs])
		if _norm(got) != PLATE_LITERAL:
			fails.append("④ %s 的 `bg_color` 不是底板色(实得「%s」)" % [path, got])

	# ── ⑤ 反向:全仓再无**游离**的底板色字面量(白名单见 LITERAL_ALLOWED) ──
	for path in ScanUtil.collect(SCAN_DIRS):
		if LITERAL_ALLOWED.has(path):
			continue
		var code := ScanUtil.code_only(ScanUtil.read(path))
		if code.is_empty():
			continue
		if code.contains(PLATE_LITERAL):
			fails.append("⑤ %s 里有游离的底板色字面量(白名单只有调色板与两个 .tscn)" % path)

	if fails.is_empty():
		print("UI PALETTE: ALL-OK")
		quit(0)
	else:
		for f in fails:
			print("  FAIL " + f)
		print("UI PALETTE: FAIL(%d 条)" % fails.size())
		quit(1)


# 取 `code` 里含 `needle` 的那一行的**右值**(`:=` 之后的原文);找不到/没有 `:=` 给 ""。
func _rhs_of(code: String, needle: String) -> String:
	for l in code.split("\n"):
		if not l.contains(needle):
			continue
		var i := l.find(":=")
		return "" if i < 0 else l.substr(i + 2).strip_edges()
	return ""


# 取 `.tscn` 原文里 `bg_color = <Color(...)>` 的右值;找不到给 ""。
# ★ 用正则而不是 `split("=")` —— 要容忍空格差异,且 `StyleBoxFlat` 段里还有别的 `=` 行。
func _tscn_bg_color(raw: String) -> String:
	var re := RegEx.create_from_string("bg_color\\s*=\\s*(Color\\([^)]*\\))")
	var m := re.search(raw)
	return "" if m == null else m.get_string(1)


# 归一化:去掉所有空白与换行 ⇒ `Color(0,0,0,0.1)` 与 `Color(0, 0, 0, 0.1)` 相等。
func _norm(s: String) -> String:
	return s.replace(" ", "").replace("\t", "").replace("\n", "")
```

- [ ] **Step 2: 跑它,确认**它红**(逐条核对红的是哪几条)**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd
```

Expected（**改前**，逐条核对，**不是**只看"有 FAIL"）:
- `① ... 里没有 const C_PLATE(唯一源不存在)`
- `②` **8 条**：`res://ui/hud.gd` / `weapon_slots.gd` / `world_label.gd` / `royale_hud.gd` **每个**出两条
  ——「没有引用 `UiFactory.C_PLATE`」+「里还有底板色**字面量**」（改前那四处**就是**字面量 ⇒ 两条都该出）
- `③` **2 条**：「没有引用 `C_TEAM_A`」+「那份**重复字面量**还在」
- `④` **2 条**（两个 `.tscn` 各 1 条）：`plate_rhs` 为空 ⇒「与 `C_PLATE` 不等」成立（**无法比较**）；
  同一段里的「不是底板色」那个分支**不**成立（`.tscn` 里**就是**底板色）
- `⑤` **0 条**（改前没有第 7 个游离落点）
- 末行 `UI PALETTE: FAIL(13 条)`（① 1 + ② 8 + ③ 2 + ④ 2 + ⑤ 0）

★ 把这段输出**原文留着** —— Task 3 修完后必须变成 `UI PALETTE: ALL-OK`。数不对就说明夹具/判据写歪了，先查再往下走。

- [ ] **Step 3: 不提交**

★ **本 Task 不提交。** 它只产出一个"会红"的守卫（TDD 的中间态）；红灯提交会把 `git bisect` 引错。
它与 Task 2/3 合并提交。

---

### Task 2: 调色板加唯一源 + 四个 `.gd` 落点改别名

**Files:**
- Modify: `ui/ui_factory.gd`（在 `const C_WARN` 之后、`# ── 队伍色(3v3)──` 之前插入）
- Modify: `ui/hud.gd:24-38`（整段注释 + 常量）
- Modify: `ui/weapon_slots.gd:32-33`
- Modify: `ui/world_label.gd:13-15`
- Modify: `ui/royale_hud.gd:83-90`

**Interfaces:**
- Consumes: 无（本 Task 是源）。
- Produces: `UiFactory.C_PLATE: Color` —— 后面所有 Task 与全部 UI 代码引用它。

- [ ] **Step 1: 调色板新增 `C_PLATE`（并把 WCAG 推导搬过来）**

在 `ui/ui_factory.gd` 的 `const C_WARN        := Color(0.950, 0.850, 0.550)   # 金色:**只**用于「低弹量/耗尽」语义`
那一行**之后**、`# ── 队伍色(3v3)──` **之前**，插入：

```gdscript
# ── 底板色(唯一源;2026-09-28)──
# HUD 元素一律垫它。★★ **唯一的数值源**:`ui/hud.gd` / `ui/weapon_slots.gd` /
#   `ui/world_label.gd` 三处的 `PLATE_COLOR` 是它的**别名**,`ui/royale_hud.gd` 的
#   `_plate_box()` 直接引用它 —— 别名/引用里**没有字面量** ⇒ 不构成第二个源。
#   `ui/pvp_hud.tscn` / `ui/team_hud.tscn` 的 `bg_color` 是**结构上无法派生**的副本
#   (`.tscn` 引用不到 GDScript 的 const),由 `tests/ui_palette_single_source_smoke.gd`
#   钉住与它逐位相等。
# ★ 用户 2026-09-15 定为 0.15、同日又下调到 0.1(当天这几个元素先被去掉底板、又垫回来)。
# ★ **例外:大乱斗排行榜 `royale_hud._board_bg` 单独是 0.25** —— 用户点名把那张玩家栏
#   排除在这轮下调之外(玩家名次表要更实的底);别看到"统一"就把那处也一起改了。
#   (`pvp_hud` 的 `Mask` 与 royale 的 `_mask` 是**全屏压暗罩**,不是底板,别顺手一起改。)
# ⚠ 0.1 是**薄薄压一层**,不是当年那套底板。按 WCAG 相对亮度算(底色取地图开阔区 #78969F):
#     alpha 0(不垫)→ 底色 L=0.283,青血条 1.87:1、金残弹 2.26:1、白字 2.57:1
#     alpha 0.10   → 底色 L=0.225,青血条 2.27:1、金残弹 2.74:1、白字 3.11:1   ← 现在
#     alpha 0.15   → 底色 L=0.199,青血条 2.50:1、金残弹 3.03:1、白字 3.44:1   ← 上一版
#     alpha 0.45   → 底色 L=0.080,青血条 4.81:1、金残弹 5.81:1、白字 6.60:1   ← 当年那套(≥4.5:1)
#   即现在只是把这几样从「勉强」提到「稍好」,血条仍低于大字下限 3:1。这是用户看过实图后的
#   选择,别拿对比度理由把它调回去;真要提对比度得动元素自身的颜色(血条青/金色残弹),另一件事。
const C_PLATE       := Color(0, 0, 0, 0.1)
```

- [ ] **Step 2: `ui/hud.gd` —— 长注释搬走，常量改别名**

把 `ui/hud.gd:24-38`（从 `# HUD 底板:武器区 / 血条 / 氧条 / 右上角击杀数,**四处共用这一个值**` 起到
`const PLATE_COLOR := Color(0, 0, 0, 0.1)` 止，**共 15 行**）**整段替换**为：

```gdscript
# HUD 底板:武器区 / 血条 / 氧条 / 右上角击杀数,**四处共用这一个值**。
# ★ 唯一源在 `ui/ui_factory.gd` 的 `C_PLATE` —— 那里有各档 alpha 的 WCAG 对比度实测,
#   以及「大乱斗排行榜 `_board_bg` 单独是 0.25」「全屏压暗罩不是底板」两条例外。
#   本处是**别名**,不存字面量(改色只动调色板那一处)。
const PLATE_COLOR := UiFactory.C_PLATE
```

- [ ] **Step 3: `ui/weapon_slots.gd` —— 常量改别名**

把 `ui/weapon_slots.gd:32-33`：

```gdscript
# 与全局 HUD 底板同值(黑 0.1,见 CLAUDE.md 的「HUD 元素一律垫半透明深底板」)。
# 单机 HUD 的那块挂在既有 PanelContainer 底板上,这个值只被联机两处用到。
const PLATE_COLOR := Color(0, 0, 0, 0.1)
```

**整段替换**为：

```gdscript
# HUD 底板(黑 0.1)。★ 唯一源是 `UiFactory.C_PLATE` —— 本处是**别名**,不存字面量。
# 单机 HUD 的那块挂在既有 PanelContainer 底板上,这个值只被联机两处用到。
const PLATE_COLOR := UiFactory.C_PLATE
```

- [ ] **Step 4: `ui/world_label.gd` —— 常量改别名（该文件**首次**引 `UiFactory`）**

把 `ui/world_label.gd:13-15`：

```gdscript
# 底板:黑 0.1 —— 与单机 HUD 的 `PLATE_COLOR`、`pvp_hud.tscn` 的 `Plate` 同值(见 ui/hud.gd
# 该常量注释里的各档对比度实测)。**不乘文字 alpha**:它是垫在字下面的静态底,不是文字的一部分。
const PLATE_COLOR := Color(0, 0, 0, 0.1)
```

**整段替换**为：

```gdscript
# 底板(黑 0.1)。★ 唯一源是 `UiFactory.C_PLATE` —— 本处是**别名**,不存字面量。
# **不乘文字 alpha**:它是垫在字下面的静态底,不是文字的一部分。
const PLATE_COLOR := UiFactory.C_PLATE
```

- [ ] **Step 5: `ui/royale_hud.gd` —— 内联字面量改引用（★ `_board_bg` 一字不动）**

把 `ui/royale_hud.gd:83-90`：

```gdscript
# HUD 元素底板(与单机 HUD 同一套做法,见 ui/hud.gd 的 PLATE_COLOR):
# ⚠ 这里与单机 HUD 的 `PLATE_COLOR`、`pvp_hud.tscn` 的 `Plate` 是**同一个数值**(0.1,
#   用户 2026-09-15 统一下调);改一处就得改齐三处(场景那份是 .tscn 里的字面量,无法共享常量)。
#   ★ 本文件的 `_board_bg`(排行榜)**不在其中** —— 那张玩家栏被用户点名排除,单独是 0.25。
static func _plate_box(pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.1)
```

**整段替换**为：

```gdscript
# HUD 元素底板(与单机 HUD 同一套做法)。★ 唯一源是 `UiFactory.C_PLATE` —— 本处直接引用,
# 不再有内联字面量(本文件其它地方早就引 `UiFactory`,这里是漏网的那一处)。
# ★ 本文件的 `_board_bg`(排行榜)**不在其中** —— 那张玩家栏被用户点名排除,单独是 0.25。
static func _plate_box(pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_PLATE
```

- [ ] **Step 6: 跑守卫 —— 应只剩 ③ ④ 红**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd
```

Expected：末行 `UI PALETTE: FAIL(2 条)`，且**只剩 `③` 的那两条** ——
`①` / `②` / `④` / `⑤` **一条都不该再出现**（`④` 归零是因为两个 `.tscn` 现在真的等于 `C_PLATE` 了）。

★ **如果 ④ 没有清零**：说明 `_tscn_bg_color`/`_norm` 写歪了（最可能是空白归一化），先修守卫的解析，
别去改 `.tscn` 的值。

- [ ] **Step 7: 不提交**

★ **本 Task 不提交**（守卫此刻仍是红的 —— `③` 未修）。与 Task 3 合并提交。

---

### Task 3: `BODY_BASE_COLOR` 改别名 + 两个 `.tscn` 加副本注释 → 守卫全部通过

**Files:**
- Modify: `scenes/pvp_match_client.gd:67`
- Modify: `ui/pvp_hud.tscn:7`
- Modify: `ui/team_hud.tscn:7`

**Interfaces:**
- Consumes: `UiFactory.C_TEAM_A`（既有，`ui/ui_factory.gd:132`）、`UiFactory.C_PLATE`（Task 2 建的）。
- Produces: 守卫全部通过。

- [ ] **Step 1: `BODY_BASE_COLOR` 改成 `C_TEAM_A` 的别名**

把 `scenes/pvp_match_client.gd:67` 那一行：

```gdscript
const BODY_BASE_COLOR := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)   # #639BFF
```

改为：

```gdscript
# ★ 唯一源是 `UiFactory.C_TEAM_A`(队 1 token,同值)—— 本处是**别名**,不存字面量。
#   ★ 上面那段"实测出来的众数色"仍是**独立的一维**:`tests/hue_tint_probe.gd` 的守卫 D
#     钉的是 `C_TEAM_A == BODY_BASE_COLOR == player.png 众数` —— 换了 sprite 素材而没改
#     调色板时,它照样红。别因为这里变成别名就把那条守卫删了。
const BODY_BASE_COLOR := UiFactory.C_TEAM_A   # #639BFF(本体主色 == 队 1 token)
```

- [ ] **Step 2: 两个 `.tscn` 各加一行「这是副本」注释**

在 `ui/pvp_hud.tscn` 的 `[sub_resource type="StyleBoxFlat" id="Plate"]` 那一行**之后**、
`bg_color = ...` 那一行**之前**，插入一行（`.tscn` 的注释前缀是 `;`）：

```
; ★ 这是**副本**:唯一源是 ui/ui_factory.gd 的 C_PLATE(`.tscn` 引用不到 GDScript 的 const)。
;   改底板色必须同步这一行 —— tests/ui_palette_single_source_smoke.gd 会钉住两者相等。
```

对 `ui/team_hud.tscn` 做**同样**的插入（位置与文字逐字相同）。

- [ ] **Step 3: 跑守卫 —— 必须 `ALL-OK`**

Run:
```bash
source tests/env.sh
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd
```

Expected: `UI PALETTE: ALL-OK`（**没有**任何 `  FAIL ` 行）。

- [ ] **Step 4: 反向验证 —— 证明 ④ 这条断言**真能红**（不是空转）**

★ 这一步是**变异验证**（本仓纪律：每条"会红"的断言都要证明它**真能红**，"加了断言之后全部通过"不是证据）。

把 `ui/pvp_hud.tscn` 的 `bg_color = Color(0, 0, 0, 0.1)` 临时改成 `bg_color = Color(0, 0, 0, 0.2)`，
重跑 Step 3 的命令。Expected：出现
`  FAIL ④ res://ui/pvp_hud.tscn 的 bg_color 与 C_PLATE 不等(实得「Color(0, 0, 0, 0.2)」,期望「Color(0, 0, 0, 0.1)」)`
**且 `team_hud.tscn` 那一条不出现**（只红改的那一个文件 ⇒ 断言是按文件独立的，不是一锅端）。

验证完**改回 `Color(0, 0, 0, 0.1)` 并重跑 Step 3**，确认回到 `ALL-OK`。

- [ ] **Step 5: 提交（探针 + 全部生产改动，一次）**

```bash
git add tests/ui_palette_single_source_smoke.gd ui/ui_factory.gd ui/hud.gd \
        ui/weapon_slots.gd ui/world_label.gd ui/royale_hud.gd \
        ui/pvp_hud.tscn ui/team_hud.tscn scenes/pvp_match_client.gd
git commit -F - <<'EOF'
refactor(ui): 底板色与队色收敛到唯一源 —— C_PLATE + 别名 + 一条钉 .tscn 的 `-s` 守卫

底板色 `Color(0, 0, 0, 0.1)` 原先有 **6 个**独立落点（3 个 `.gd` 常量 + 1 处内联 +
**2 个 `.tscn` 字面量`），而**一个守卫都没有** —— 漏改是**静默**的，只靠 `CLAUDE.md` 里
一条「手工 grep 对账」的纪律维持；三处注释自己就写着「改一处要改齐 N 处」。
`C_TEAM_A` 与 `BODY_BASE_COLOR` 则是一对**逐位相同**的字面量（有守卫 D 钉相等 ⇒ 不静默，
但仍是两个源）。

- `ui/ui_factory.gd`：新增 `const C_PLATE`（**唯一源**），并把 `ui/hud.gd:22-37` 那段 WCAG
  对比度推导整体搬过来（那里还有「排行榜 `_board_bg` 单独是 0.25」「全屏压暗罩不是底板」
  两条**例外**，一并随迁）。
- 四个 `.gd` 落点改**别名/引用**：`ui/hud.gd` / `ui/weapon_slots.gd` / `ui/world_label.gd`
  的 `const PLATE_COLOR := UiFactory.C_PLATE`（**保留各自的名字** —— 保住外部读者
  `tests/kh_l3_visual_probe.gd:132` 读的 `WeaponSlots.PLATE_COLOR`；别名里**没有字面量**，
  不构成第二个源）；`ui/royale_hud.gd` 的 `_plate_box()` 内联字面量直接引用它。
- `scenes/pvp_match_client.gd`：`BODY_BASE_COLOR` 改成 `UiFactory.C_TEAM_A` 的别名。
  ★ 守卫 D **保留** —— 它钉的 `player.png` 众数那一维仍是独立的。
- 两个 `.tscn` 的 `bg_color`：**结构上引用不到 GDScript 的 const**（它是 `StyleBoxFlat` 的
  属性），故**保留字面量** + 各加一行「这是副本」注释。
- **新守卫** `tests/ui_palette_single_source_smoke.gd`（`-s`、headless、`ScanUtil` 剥注释）：
  ① 唯一源在位；② 四个 `.gd` 落点引用它**且不含字面量**；③ `BODY_BASE_COLOR` 引用 `C_TEAM_A`；
  ④ **两个 `.tscn` 的 `bg_color` 与 `C_PLATE` 逐位相等**（★ 这就是「改漏 `.tscn`」的唯一信号）；
  ⑤ 反向：全仓再无游离的底板色字面量。

★ **不改渲染初始化、不引 Theme/`.tres`**（spec §7 明确不做）。**本计划不改任何像素。**
★ 反证已做：把 `pvp_hud.tscn` 改成 `0.2` ⇒ 只有该文件那一条 ④ 红，改回即 ALL-OK。
EOF
```

---

### Task 4: 回归 + 改 `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`（§UI 里那段「HUD 元素一律垫半透明深底板 … 改一处要改齐」）

**Interfaces:**
- Consumes: Task 3 落地的 `UiFactory.C_PLATE` 与 `tests/ui_palette_single_source_smoke.gd`。
- Produces: 无（文档 + 回归）。

- [ ] **Step 1: 回归（agent 可跑的那一半）**

Run:
```bash
source tests/env.sh
for t in enemy_logic_smoke player_contract_smoke weapon_inventory_smoke; do
  echo "--- $t ---"; timeout 300 "$GODOT" --headless --path . -s "res://tests/$t.gd" 2>&1 | grep -E "OK|FAIL" | tail -2
done
for t in kh_l3_probe kh_l4_probe kh_l5_probe kh_l6_probe ground_client_probe; do
  echo "--- $t ---"; timeout 400 "$GODOT" --headless --path . --quit-after 3600 "res://tests/$t.tscn" 2>&1 | grep -E "ALL-OK|FAIL" | tail -2
done
timeout 120 "$GODOT" --headless --path . -s res://tests/ui_palette_single_source_smoke.gd
```

Expected: 逐个 `SMOKE OK` / `CONTRACT OK` / `WEAPON_INVENTORY OK` / `KH L* PROBE: ALL-OK` /
`GROUND CLIENT PROBE: ALL-OK`，末行 `UI PALETTE: ALL-OK`。**无 FAIL。**

★ `kh_l5_probe` 与 `kh_l4_probe` 是**必须**的：它们扫 `res://ui` 与 `res://tests` 的字号规范与
「新接口归属」（含否定断言：**基类不得含子类方法**），而本计划在这两个目录里都改了文件。
★ `kh_l6_probe` 必须绿：它第 15 条钉的 `NAME_COLOR` **本计划一个字都没动** —— 它红了说明越界了。

- [ ] **Step 2: 请用户跑真渲染探针并读图**

Run（**不加 `--headless`**，会弹窗）:
```bash
"$GODOT" --path . --quit-after 3600 res://tests/kh_l3_visual_probe.tscn
"$GODOT" --path . --quit-after 3600 res://tests/combat_hud_visual_probe.tscn
"$GODOT" --path . --quit-after 3600 res://tests/hue_tint_probe.tscn
```

Expected: `KH L3 VISUAL: ALL-OK` / `COMBAT HUD VISUAL PROBE: ALL-OK` / `KH HUE-TINT PROBE: ALL-OK`，
且**图上的底板观感与改动前一致**（本计划**不该改变任何像素**）。
★ 探针存的图**自己读**（`kh_l3_slots_on_map.png` / `combat_hud_*.png`），别推回给用户。

- [ ] **Step 3: 改 `CLAUDE.md` §UI 那段**

把 `CLAUDE.md` §UI 里以
`- **HUD 元素一律垫半透明深底板,全项目同一个数值 `黑 0.1`**` 开头的那一整条 bullet
（含 `★★ **本条刻意不写"共 N 处"**` 与那条三行 grep 命令）**整条替换**为：

```markdown
- **HUD 元素一律垫半透明深底板,数值的唯一源 = `UiFactory.C_PLATE`(黑 0.1)**(2026-09-15 用户
  统一,先前 0.45 → 0.15 → 0.1;2026-09-28 收敛到唯一源)。四个 `.gd` 落点是它的**别名/引用**:
  `ui/hud.gd` / `ui/weapon_slots.gd` / `ui/world_label.gd` 的 `PLATE_COLOR`、`ui/royale_hud.gd`
  的 `_plate_box()`;两个 `.tscn`(`ui/pvp_hud.tscn` / `ui/team_hud.tscn` 的 `Plate`)的 `bg_color`
  **结构上引用不到 GDScript 的 const** ⇒ 保留字面量,**由 `tests/ui_palette_single_source_smoke.gd`
  钉住与 `C_PLATE` 逐位相等**。⇒ 改底板色**只动调色板一处**;漏改 `.tscn` 会**响亮地红**,
  不再是静默(旧纪律是「改一处要改齐 + 手工 grep 对账」)。
  ★ **例外一:大乱斗排行榜 `royale_hud._board_bg` 单独是 0.25** —— 用户 2026-09-15 点名把那张
  「pvp 玩家栏」排除在这轮下调之外(比别处都实);别看到"统一"就把那处一起改。
  ★ **例外二:右上角击杀计数器(青色 `000`)不垫底板**(2026-09-17 用户要求删,三个模式一起生效)。
  ⚠ 去掉它**只能靠 `draw_center = false`**,不能只删 `bg_color` 那行 —— `StyleBoxFlat` 默认底色是
  **不透明灰 (0.6,0.6,0.6,1)**、`draw_center` 默认 true,只删颜色等于把半透明黑板换成实心灰板
  (09-15 实测踩过)。氧条那组底板与条/空槽同一 tween 淡入淡出,满氧时整组不出现。
  ★ 各档 alpha 的对比度实测(为什么 0.1 达不到大字下限 3:1 却仍是用户的选择)写在
  `ui/ui_factory.gd` 的 `C_PLATE` 注释里 —— 那是**唯一**的落点,别在别处再抄一份。
  ★ **全屏压暗罩不在此列**(`pvp_hud` 的 `Mask` / royale 的 `_mask` = 0.3、暂停菜单 0.55、
  敌人血条底 `enemy_hp_bar.gd` 的 0.45),它们不是底板。
  ★ **金色(`C_WARN`)只表「弹夹见底」**这一个语义 —— 满弹用中性色,装填进度条用强调青;
  丢弃进度条用 `C_DANGER`。
```

★ 这次替换**必须删掉**原先那三行 grep 命令与「本条刻意不写"共 N 处"」那段 —— 它们描述的是
「手工同步 N 处」那套纪律,而本计划之后**不再需要手工同步**（剩一处 `.tscn` 副本由守卫钉着）。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): §UI 的底板色改写 —— 指向唯一源 C_PLATE 与新的 `-s` 守卫

原纪律是「HUD 元素一律垫半透明深底板 … **改一处要改齐**（下列是已知落点,不是完备枚举）」
+ 一条手工 grep 命令。2026-09-28 起底板色有了**唯一源** `UiFactory.C_PLATE`：四个 `.gd` 落点
是别名/引用，两个 `.tscn` 的 `bg_color` 结构上派生不了、由 `ui_palette_single_source_smoke.gd`
钉住相等 ⇒ **手工同步那套纪律连同那段"共 N 处"的措辞一并删除**（它们描述的机制已不存在）。

两条**例外**与「`draw_center = false` 那个坑」原样保留（它们与"几个源"无关）。
各档 alpha 的对比度实测改为指向 `ui_factory.gd` 的 `C_PLATE` 注释（**唯一**落点，不再两处各抄一份）。
EOF
```

---

## Self-Review

**1. 覆盖面（对照 spec）**

| spec 要求 | 本计划 |
|---|---|
| §2 目标 1：底板色只有一个源，改一处 4 个 `.gd` 落点全跟着变 | Task 2 Step 1-5 + 守卫 ② |
| §2 目标 2：两个 `.tscn` 让「改漏」响亮地红 | Task 3 Step 2 + 守卫 ④ + Step 4 的反证 |
| §2 目标 3：`BODY_BASE_COLOR` 与 `C_TEAM_A` 收敛为一份 | Task 3 Step 1 + 守卫 ③ |
| §2 目标 4：三处「改一处要改齐」的注释改写 | Task 2 Step 2/3/4/5 + Task 4 Step 3 |
| §3.1 调色板加 `C_PLATE` + WCAG 注释搬家 | Task 2 Step 1-2 |
| §3.2 四个 `.gd` 落点改别名（保留名字） | Task 2 Step 2-5 |
| §3.3 两个 `.tscn` 保留字面量 + 注释 + 守卫 | Task 3 Step 2 + 守卫 ④ |
| §3.4 `BODY_BASE_COLOR` 改别名，守卫 D 保留 | Task 3 Step 1 |
| §3.5 新守卫 ①~⑤ | Task 1 Step 1 |
| §4.4 `CLAUDE.md` 同步改写 | Task 4 Step 3 |
| §5.1 单向派生 | 守卫 ② （Task 2 Step 6 观察 ① ② 转绿） |
| §5.2 改漏会红 | Task 3 Step 4（定向变异） |
| §5.3 既有测试用例全部通过 | Task 4 Step 1（agent 跑）+ Step 2（用户跑真渲染） |
| §5.4 人工视觉核验：像素不变 | Task 4 Step 2 |
| §7 不引 Theme/`.tres`、不改渲染初始化 | **全计划无此类改动**（Global Constraints 与 Task 3 的提交信息都写明） |

**2. 占位符扫描**：无 TBD / "类似 Task N" / "适当处理"。每个改动都给了**完整代码块**与确切锚点
（`ui/hud.gd:22-38` 等行号已按当前树核过；若实现时行号漂了，按**内容**定位 —— 代码块里的原文就是锚）。

**3. 类型/名字一致性**：
- `UiFactory.C_PLATE`（Task 2 定义）与守卫里的 `"const C_PLATE"` 字面量、`ui/ui_factory.gd` 的插入位置一致。
- `UiFactory.C_TEAM_A` 是**既有**常量（`ui/ui_factory.gd:132`），Task 3 只引用、不新建。
- 守卫的常量名 `PLATE_LITERAL` / `TEAM_A_LITERAL` / `GD_SITES` / `TSCN_SITES` / `BODY_BASE_SITE` /
  `LITERAL_ALLOWED` / `SCAN_DIRS` 与两个助手 `_rhs_of` / `_tscn_bg_color` / `_norm` 在 Task 1 内
  自洽、且后续 Task 只通过**跑它**使用，不引用其内部名字。

**4. 已知的判据上限（从 spec §4.3 带过来，如实登记）**：守卫只钉那 **6 处**具名落点 + 一条否定断言；
将来新增第 7 处若写成**第三种 `const` 名字**，否定断言抓不到（② 只钉那四个具名文件）。
真接能力系统/新增 HUD 时，第一个要接的线是**给守卫补一个落点**。
