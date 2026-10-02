# 目录结构规范化（core/ui/server/tests）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `render/` 并入 `core/present/`、`ui/` 拆三组、`server/` 拆四组、`tests/` 拆五组；先建一条**路径一致性守卫**，让每一次搬动都能被机械验证。

**Architecture:** 先用一个 `-s` 冒烟探针把「全仓 `res://` 字面量是否都指向真实存在的资源」变成可反复运行的红/绿判据；拿到**全绿基线**之后再逐目录 `git mv`（`.gd` 连同 `.gd.uid` 一起走），搬完用 python 按**显式映射表**重写 `.gd`/`.tscn` 里的路径字面量，再跑守卫确认仍全绿。不依赖 Godot 编辑器做路径改写。

**Tech Stack:** Godot 4.7（标准版非 mono）、git、python3（仅做确定性文本替换）、`tests/lib/scan_util.gd`（`class_name ScanUtil`，纯静态、`-s` 可用）。

## Global Constraints

- 分支 `refactor/dir-structure`，基于 `main`。
- **不动 `maps/` 与 `data/`**：`export_presets.cfg` 的 `include_filter="maps/*.cyrm,data/*.json"` 是字面量，改了位置不改这行 ⇒ 地图与表**不进包**，且**只在发布版现形**。
- **不动 `core/{config,net,sim}/`、`scenes/` 顶层、`assets/`**：它们已经是功能式布局；`scenes/` 顶层拆分收益小、改动面 72 处，本 plan 刻意不做。
- `.gd` 文件**内部没有 uid**，uid 只存在于 `.gd.uid` 边车 ⇒ **`.gd` 与 `.gd.uid` 必须一起 `git mv`**。`.tscn` 的 uid 在它自己的 `[gd_scene … uid=]` 头里，磁盘上**没有** `.tscn.uid`。
- **不要手改 `.tscn` 的 `uid="uid://…"` 字段**，只改 `path="res://…"`。
- 搬完必须跑一次 `--import`（刷新 `.godot/` 里的 uid 缓存）。
- 本项目约定「测试由用户自己跑」。**例外**：Task 1 建的守卫是**迁移的验证工具**（`-s`、不占端口、秒级），实施者每搬一步都要跑它才能知道自己有没有搬坏；其余场景探针/真链路脚本仍由用户跑。
- 本 plan 的守卫判据是**文本** `PATH INTEGRITY: ALL-OK`，**不看退出码**（本仓既有纪律）。

## 执行顺序（★ 与下面的 Task 编号顺序**不同**）

编号只是 ID，实际按这个顺序跑：

| 序 | Task | 为什么在这个位置 |
|---|---|---|
| 1 | **Task 1** 路径守卫 | 全套的前提。没有它，后面每一次搬动都是"改错了不报错" |
| 2 | **Task 7** 常量表漂移 | 与目录无关，立刻交付两个修复；零目录风险，先拿它热身 |
| 3 | **Task 2** `render/` | 引用面最小（1 处），用它把「守卫 → 搬 → 重写 → 跑守卫」这条流水跑顺 |
| 4 | **Task 3** `ui/` | 生产侧 14 处 |
| 5 | **Task 4** `server/` | 生产侧 3 处，但测试侧约 98 处 |
| 6 | **Task 5** `tests/` | 最大（325 个文件），放最后 |
| 7 | **Task 6** 文档同步 | **必须在 Task 2~5 全做完之后**，否则写进去的是半截结构 |

两处顺序耦合，实施时别搞混：

- ★ **Task 7 排在 Task 5 之前** ⇒ 它的守卫落在 `tests/settings_actions_smoke.gd`。Task 5 的 `*_smoke` 规则会把它**自动**搬进 `tests/smoke/`，不需要手工干预。
- ★ **Task 5 会把 Task 1 的守卫搬走**：`tests/path_integrity_probe.gd` → `tests/probe/path_integrity_probe.gd`（`*_probe` 规则）。所以 **Task 5 内部**跑守卫必须用新路径（见 Task 5 Step 5）；Task 2~4 期间它还在老路径。

---

### Task 1: 路径一致性守卫（先建基线，再搬任何东西）

> ✅ **已完成**（提交 `8f73bf9` + `1606f58`，两轮评审 Approved）。基线：`PATH INTEGRITY: ALL-OK（扫描 344 个文件，其中 .sh 11 个，跳过 0 个读不到）`。
>
> ⚠️ **下面 Step 1 的代码是初稿，有 bug —— 别照抄。最终实现以 `tests/path_integrity_probe.gd` 为准。**
> 教训集中在**同一个语义**上：`ResourceLoader.exists()` **只认已导入资源**，对普通文件恒假。它在这份代码里咬了三口：
> 1. `_exists_any` 缺 `FileAccess.file_exists` ⇒ `maps/*.cyrm`、`tests/*.txt` 被判不存在，**28 条假红**；
> 2. `_load_allow` 走 `ScanUtil.read`（首行也是那道闸门）⇒ 豁免文件是 `.txt`，**豁免表恒空**，放进去的路径照样报红；
> 3. 扫描面扩到 `.sh` 后，`.sh` 同样读不出 ⇒ **11 个全落进 SKIP**（"看着扩了、其实一条没查"）。
>
> 引擎侧依据：`resource_loader.cpp:1247` 的 `exists()` 在 loader 不认路径时 **`:1267` 直接 `return false`，没有 `FileAccess` 兜底**。
> 另外本轮还加了两条：读不到的文件**不静默**（有账本、印进 verdict 行）、以及**覆盖面边界与豁免无条件性写进守卫自己的注释**。

**Files:**
- Create: `tests/path_integrity_probe.gd`（`extends SceneTree`，`-s` 跑）
- Create: `tests/path_integrity_allow.txt`（豁免清单，每行一个路径 + `#` 起的原因）

**Interfaces:**
- Produces: 命令 `"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd`，打印 `PATH INTEGRITY: ALL-OK` 或 `PATH INTEGRITY: FAILED: N`。
- Produces: 豁免文件格式 —— 每行 `res://完整路径\t# 原因`，空行与 `#` 开头忽略。Task 2~5 若搬出新的"故意不存在"路径，往这里追加。

**背景（为什么守卫是第一步）：** 实测去注释后生产代码里有 **45 个不同的 `res://` 字面量、共 77 处出现**；裸 grep 会把**注释**里的路径也数进来（那 45 里有相当一部分、以及 762 这个总数，大部分是注释与 `.tscn` 的 `ext_resource`）。漏改一处字符串路径**不会报错**，只会在运行到那条代码时才崩 —— 这正是本仓「改错了不报错」那一类，必须有守卫。

- [ ] **Step 1: 写守卫**

```gdscript
extends SceneTree

# 路径一致性守卫:全仓 .gd / .tscn 里出现的每个 `res://` 字面量都必须指向真实存在的
# 文件或目录。目录重构期间每搬一步跑一次。
#
# 跑法: "$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
# 通过 = `PATH INTEGRITY: ALL-OK` 退出 0。
#
# ★ 必须剥注释再扫:注释里的 `res://old/path` 不是代码(本仓 kh_l6 与 ui_palette 的
#   注释里就各有一句假路径)。直接 grep 会既假红又漏改。
# ★ .tscn 只查 ext_resource 的 path=;uid= 字段不查(uid 由 .gd.uid 边车与 .tscn 头承载)。
# ★ 豁免走 tests/path_integrity_allow.txt,每行一个完整路径 + 可选 `# 原因`。

# ★ 只扫这几根:ScanUtil.collect 只收 .gd / .tscn,所以放没有 GDScript 的目录
#   (tools/ level_editor/) 进去是白扫。Task 2 搬完 render/ 后要把 "res://render" 删掉。
const SCAN_ROOTS := ["res://core", "res://scenes", "res://server", "res://ui",
	"res://render", "res://tests"]
const ALLOW_PATH := "res://tests/path_integrity_allow.txt"
const SCAN_UTIL_PATH := "res://tests/lib/scan_util.gd"

var _fail := 0
var _su: GDScript = null      # ★ 显式 load,不用全局类名 —— 本仓所有 -s 冒烟都走这条路

func _strip_line_comment(line: String) -> String:
	var quote := ""
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line

func _code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s := _strip_line_comment(line).strip_edges()
		if not s.is_empty():
			out.append(s)
	return "\n".join(out)

func _load_allow() -> Dictionary:
	var allow := {}
	var src: String = _su.read(ALLOW_PATH)
	if src.is_empty():
		# 豁免文件不存在 = 空豁免,不是错误
		return allow
	for line in src.split("\n"):
		var s := _strip_line_comment(line).strip_edges()
		if not s.is_empty():
			allow[s] = true
	return allow

func _exists_any(p: String) -> bool:
	# `res://` 裸串与 `res://dir/` 这类是**目录**;ResourceLoader 只认资源。
	# 用 DirAccess.open 而不是 dir_exists_absolute:后者对 res:// 前缀不保证成立。
	if ResourceLoader.exists(p):
		return true
	var d := DirAccess.open(p)
	if d == null:
		return false
	d.list_dir_end()
	return true

func _initialize() -> void:
	# ★ 空载守卫:load() 失败还往下走会在 null 上抛错,而 -s 抛错走不到 quit() → 永久挂起
	_su = load(SCAN_UTIL_PATH)
	if _su == null:
		print("PATH INTEGRITY: FAILED: 找不到 ", SCAN_UTIL_PATH)
		quit(1)
		return

	var allow := _load_allow()
	var re := RegEx.new()
	re.compile("res://[A-Za-z0-9_./-]*")

	var bad: Array[String] = []
	var seen := {}
	var files: Array = _su.collect(SCAN_ROOTS)
	if files.size() < 50:
		# 扫到的文件太少 = 扫描根写错了,别静默放行
		print("PATH INTEGRITY: FAILED: 只扫到 %d 个文件,扫描根可疑" % files.size())
		quit(1)
		return

	for f in files:
		var src: String = _su.read(f)
		if src.is_empty():
			continue
		var code := _code_only(src)
		for m in re.search_all(code):
			var p := m.get_string()
			if allow.has(p) or _exists_any(p):
				continue
			var key := "%s\t%s" % [p, f]
			if seen.has(key):
				continue
			seen[key] = true
			bad.append("[%s] %s" % [f, p])

	if bad.is_empty():
		print("PATH INTEGRITY: ALL-OK（扫描 %d 个文件）" % files.size())
		quit(0)
	else:
		for b in bad:
			print("[FAIL] ", b)
		print("PATH INTEGRITY: FAILED: %d" % bad.size())
		quit(1)
```

- [ ] **Step 2: 写豁免文件（先只放一条，就是当前唯一已知的故意不存在路径）**

`tests/path_integrity_allow.txt`：

```
res://__l5_synthetic__.gd	# kh_l5_probe 故意造的不存在脚本,用来验"读不到源码要报红"
```

- [ ] **Step 3: 跑守卫，拿到全绿基线**

Run:
```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
```
Expected: `PATH INTEGRITY: ALL-OK（扫描 N 个文件）`，N ≈ 400+。

**若报红**：先把报出来的每一条判定是「真断链」还是「又一个故意不存在的路径」。
- 真断链 ⇒ **停下来**，它说明仓库现在就有坏的路径引用，先单独修（那是本 plan 之外的既有 bug）。
- 故意不存在 ⇒ 追加进豁免文件，重跑。

**搬任何文件之前，这一条必须是绿的。**

- [ ] **Step 4: 提交**

```bash
git add tests/path_integrity_probe.gd tests/path_integrity_probe.gd.uid tests/path_integrity_allow.txt
git commit -m "test: 加路径一致性守卫(目录重构的前置安全网)"
```

---

### Task 2: `render/` 并入 `core/present/`

**Files:**
- Move: `render/camera_2d.gd`(+`.uid`) → `core/present/camera_2d.gd`(+`.uid`)
- Move: `render/post_process.gd`(+`.uid`) → `core/present/post_process.gd`(+`.uid`)
- Move: `render/post_process.gdshader`(+`.uid`) → `core/present/post_process.gdshader`(+`.uid`)
- Modify: 所有含 `res://render/` 的 `.gd` 与 `.tscn`
- Delete dir: `render/`

**Interfaces:**
- Produces: `res://core/present/camera_2d.gd`、`res://core/present/post_process.gd`、`res://core/present/post_process.gdshader`。Task 3~5 不依赖它们。

**为什么**：`render/` 只有 4 个文件（相机 + 后处理 + 着色器），而 `core/present/` 已经是"表现层"（`laser_visual` / `pixel_font` / `sfx` / `sprite_bounds`）。两个目录职责重叠，且 `render/` 这名字读起来像"整个渲染管线"。无重名冲突。

- [ ] **Step 1: `git mv` 六个文件（源码 + `.uid` 一起）**

```bash
git mv render/camera_2d.gd core/present/camera_2d.gd
git mv render/camera_2d.gd.uid core/present/camera_2d.gd.uid
git mv render/post_process.gd core/present/post_process.gd
git mv render/post_process.gd.uid core/present/post_process.gd.uid
git mv render/post_process.gdshader core/present/post_process.gdshader
git mv render/post_process.gdshader.uid core/present/post_process.gdshader.uid
```

- [ ] **Step 2: 确认旧目录已空**

```bash
ls render/     # 期望：无输出
```

- [ ] **Step 3: 重写全仓的 `res://render/` → `res://core/present/`**

这是**前缀替换**，两种载体都覆盖（`.gd` 的字符串字面量 + `.tscn` 的 `ext_resource path=`）：

```bash
python - <<'PY'
import pathlib, re
roots = ["core","scenes","server","ui","tests","tools","render","project.godot","export_presets.cfg"]
changed = []
for r in roots:
    p = pathlib.Path(r)
    files = [p] if p.is_file() else [f for f in p.rglob("*") if f.suffix in (".gd",".tscn",".tres",".godot")]
    for f in files:
        s = f.read_text(encoding="utf-8", errors="surrogateescape")
        if "res://render/" in s:
            f.write_text(s.replace("res://render/", "res://core/present/"),
                         encoding="utf-8", errors="surrogateescape")
            changed.append(str(f))
print("改写文件数:", len(changed))
for c in changed: print("  ", c)
PY
rmdir render 2>/dev/null; ls render/ 2>&1 | head -1
```

- [ ] **Step 4: 跑守卫，确认仍全绿**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
```
Expected: `PATH INTEGRITY: ALL-OK`

- [ ] **Step 5: 刷新 uid 缓存 + 确认没有残留引用**

```bash
"$GODOT" --headless --path . --import > /dev/null 2>&1
grep -rn "res://render/" --include=*.gd --include=*.tscn --include=*.cfg --include=*.godot . 2>/dev/null | grep -v '^\./\.claude' | grep -v '^\./\.godot'
# 期望：无输出
```

- [ ] **Step 6: 把 `res://render` 从守卫的 `SCAN_ROOTS` 里删掉**

`render/` 已经不存在，`ScanUtil.walk` 对打不开的目录**静默返回** —— 留着它只会让扫描面悄悄少一块而无任何提示。改 `tests/path_integrity_probe.gd`：

```gdscript
const SCAN_ROOTS := ["res://core", "res://scenes", "res://server", "res://ui",
	"res://tests"]
```

改完再跑一次守卫确认仍全绿：

```bash
"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
```
Expected: `PATH INTEGRITY: ALL-OK`

- [ ] **Step 7: 提交**

```bash
git add -A core scenes server ui render project.godot
git commit -m "refactor(dir): render/ 并入 core/present/(职责本就是一回事)"
```

---

### Task 3: `ui/` 拆成 `factory/ hud/ screens/`

**Files:**
- Create dirs: `ui/factory/`, `ui/hud/`, `ui/screens/`
- Move: 27 个文件（+ 各自 `.uid`）按 Step 1 的表
- Modify: 所有含被移动路径的 `.gd` 与 `.tscn`

**Interfaces:**
- Consumes: Task 1 的守卫。
- Produces: `res://ui/factory/*`、`res://ui/hud/*`、`res://ui/screens/*`。Task 4~5 不依赖。

**分类判据（按"谁用谁"分，不按文件类型）：**
- `factory/` = **给别的 UI 用的工具**（调色板+控件工厂、武器图标、世界空间标签）
- `hud/` = **对局内常驻显示**
- `screens/` = **全屏页**（结算页、暂停菜单、两个面板）

- [ ] **Step 1: `git mv` 全部 27 个文件**

```bash
mkdir -p ui/factory ui/hud ui/screens

# ── factory/（3）──
for n in ui_factory weapon_icons world_label; do
  git mv "ui/$n.gd" "ui/factory/$n.gd"; git mv "ui/$n.gd.uid" "ui/factory/$n.gd.uid"
done

# ── hud/（18）──
for n in hud pvp_hud royale_hud team_hud minimap enemy_hp_bar reload_ring \
         pickup_prompt combat_feedback status_banner weapon_slots; do
  git mv "ui/$n.gd" "ui/hud/$n.gd"; git mv "ui/$n.gd.uid" "ui/hud/$n.gd.uid"
done
for n in pvp_hud royale_hud team_hud combat_feedback kill_counter status_banner; do
  git mv "ui/$n.tscn" "ui/hud/$n.tscn"
done
git mv ui/minimap_circle.gdshader ui/hud/minimap_circle.gdshader
git mv ui/minimap_circle.gdshader.uid ui/hud/minimap_circle.gdshader.uid

# ── screens/（6）──
for n in match_result match_result_payload pause_menu; do
  git mv "ui/$n.gd" "ui/screens/$n.gd"; git mv "ui/$n.gd.uid" "ui/screens/$n.gd.uid"
done
for n in match_result sp_launch_panel version_panel; do
  git mv "ui/$n.tscn" "ui/screens/$n.tscn"
done
```

- [ ] **Step 2: 确认 `ui/` 顶层已空**

```bash
ls ui/    # 期望：只有 factory/ hud/ screens/ 三个目录
```

- [ ] **Step 3: 按映射表重写路径**

```bash
python - <<'PY'
import pathlib
FACTORY = ["ui_factory","weapon_icons","world_label"]
HUD_GD  = ["hud","pvp_hud","royale_hud","team_hud","minimap","enemy_hp_bar",
           "reload_ring","pickup_prompt","combat_feedback","status_banner","weapon_slots"]
HUD_TS  = ["pvp_hud","royale_hud","team_hud","combat_feedback","kill_counter","status_banner"]
SCR_GD  = ["match_result","match_result_payload","pause_menu"]
SCR_TS  = ["match_result","sp_launch_panel","version_panel"]

mapping = {}
for n in FACTORY: mapping[f"res://ui/{n}.gd"] = f"res://ui/factory/{n}.gd"
for n in HUD_GD:  mapping[f"res://ui/{n}.gd"] = f"res://ui/hud/{n}.gd"
for n in HUD_TS:  mapping[f"res://ui/{n}.tscn"] = f"res://ui/hud/{n}.tscn"
mapping["res://ui/minimap_circle.gdshader"] = "res://ui/hud/minimap_circle.gdshader"
for n in SCR_GD:  mapping[f"res://ui/{n}.gd"] = f"res://ui/screens/{n}.gd"
for n in SCR_TS:  mapping[f"res://ui/{n}.tscn"] = f"res://ui/screens/{n}.tscn"

# 长键先替换,免得 res://ui/match_result.gd 被 res://ui/match_result.tscn 的规则误伤
keys = sorted(mapping, key=len, reverse=True)
roots = ["core","scenes","server","ui","tests","tools"]
hits = {}
for r in roots:
    for f in pathlib.Path(r).rglob("*"):
        if f.suffix not in (".gd",".tscn"): continue
        s = f.read_text(encoding="utf-8", errors="surrogateescape")
        o = s
        for k in keys:
            if k in s:
                hits[k] = hits.get(k, 0) + s.count(k)
                s = s.replace(k, mapping[k])
        if s != o:
            f.write_text(s, encoding="utf-8", errors="surrogateescape")
for k in keys:
    print(f"{hits.get(k,0):3}  {k}  ->  {mapping[k]}")
PY
```

- [ ] **Step 4: 跑守卫，确认仍全绿**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
```
Expected: `PATH INTEGRITY: ALL-OK`

- [ ] **Step 5: 刷新 uid 缓存 + 确认无残留**

```bash
"$GODOT" --headless --path . --import > /dev/null 2>&1
grep -rn 'res://ui/[a-z_]*\.\(gd\|tscn\|gdshader\)' --include=*.gd --include=*.tscn . 2>/dev/null | grep -v '^\./\.claude'
# 期望：无输出（剩下的必须是 res://ui/factory|hud|screens/...）
```

- [ ] **Step 6: 提交**

```bash
git add -A ui core scenes server tests
git commit -m "refactor(dir): ui/ 拆成 factory/hud/screens 三组"
```

---

### Task 4: `server/` 拆成 `lobby/ match/ hosts/ ai/`

**Files:**
- Create dirs: `server/lobby/`, `server/match/`, `server/hosts/`, `server/ai/`
- Move: 14 个 `.gd`（+ `.uid`）；`server_main.gd` 与 `server_main.tscn` **留在 `server/` 顶层**
- Modify: 所有含被移动路径的 `.gd` 与 `.tscn`

**Interfaces:**
- Consumes: Task 1 的守卫。
- Produces: `res://server/{lobby,match,hosts,ai}/*.gd`。`res://server/server_main.tscn` **路径不变**（`project.godot` 的 `main_scene.dedicated_server` 依赖它）。

**分类判据（按继承链与职责）：**
- `lobby/` = 大厅侧：房间账本、进程编排、worker 拉起、回局凭据表
- `match/` = 对局底座（`MatchSnapshot → MatchGround → MatchState` 那条继承链 + 战斗/宿主基类/启动器）
- `hosts/` = 三个模式的权威宿主（都 `extends MatchHost`）
- `ai/` = AI 导航

- [ ] **Step 1: `git mv` 14 个 `.gd`**

```bash
mkdir -p server/lobby server/match server/hosts server/ai

for n in lobby_rooms room_manager worker_launcher rejoin_registry; do
  git mv "server/$n.gd" "server/lobby/$n.gd"; git mv "server/$n.gd.uid" "server/lobby/$n.gd.uid"
done

for n in match_state match_snapshot match_ground match_combat match_host match_bootstrap match_round; do
  git mv "server/$n.gd" "server/match/$n.gd"; git mv "server/$n.gd.uid" "server/match/$n.gd.uid"
done

for n in royale_host team_host; do
  git mv "server/$n.gd" "server/hosts/$n.gd"; git mv "server/$n.gd.uid" "server/hosts/$n.gd.uid"
done

git mv server/ai_navigator.gd server/ai/ai_navigator.gd
git mv server/ai_navigator.gd.uid server/ai/ai_navigator.gd.uid
```

- [ ] **Step 2: 确认顶层只剩两个入口文件**

```bash
ls server/
# 期望：ai/ hosts/ lobby/ match/ server_main.gd server_main.gd.uid server_main.tscn
```

- [ ] **Step 3: 按映射表重写路径**

```bash
python - <<'PY'
import pathlib
LOBBY = ["lobby_rooms","room_manager","worker_launcher","rejoin_registry"]
MATCH = ["match_state","match_snapshot","match_ground","match_combat",
         "match_host","match_bootstrap","match_round"]
HOSTS = ["royale_host","team_host"]
AI    = ["ai_navigator"]
mapping = {}
for n in LOBBY: mapping[f"res://server/{n}.gd"] = f"res://server/lobby/{n}.gd"
for n in MATCH: mapping[f"res://server/{n}.gd"] = f"res://server/match/{n}.gd"
for n in HOSTS: mapping[f"res://server/{n}.gd"] = f"res://server/hosts/{n}.gd"
for n in AI:    mapping[f"res://server/{n}.gd"] = f"res://server/ai/{n}.gd"

roots = ["core","scenes","server","ui","tests","tools"]
hits = {}
for r in roots:
    for f in pathlib.Path(r).rglob("*"):
        if f.suffix not in (".gd",".tscn"): continue
        s = f.read_text(encoding="utf-8", errors="surrogateescape")
        o = s
        for k, v in mapping.items():
            if k in s:
                hits[k] = hits.get(k, 0) + s.count(k)
                s = s.replace(k, v)
        if s != o:
            f.write_text(s, encoding="utf-8", errors="surrogateescape")
for k in sorted(mapping):
    print(f"{hits.get(k,0):3}  {k}  ->  {mapping[k]}")
PY
```

- [ ] **Step 4: 跑守卫 + 确认 `server_main` 两个路径没被动**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
grep -n 'main_scene.dedicated_server' project.godot
# 期望：路径仍是 res://server/server_main.tscn
```
Expected: `PATH INTEGRITY: ALL-OK` 且那行未变。

- [ ] **Step 5: 刷新 uid 缓存 + 确认无残留**

```bash
"$GODOT" --headless --path . --import > /dev/null 2>&1
grep -rn 'res://server/[a-z_]*\.gd' --include=*.gd --include=*.tscn . 2>/dev/null | grep -v '^\./\.claude'
# 期望：只有 res://server/server_main.gd
```

- [ ] **Step 6: 提交**

```bash
git add -A server core scenes ui tests
git commit -m "refactor(dir): server/ 拆成 lobby/match/hosts/ai 四组"
```

---

### Task 5: `tests/` 拆成 `smoke/ probe/ harness/ scripts/`

> ★ **本 task 可独立停下** —— Task 1~4 已是一个完整可发布的单元。若想分批，Task 5 单独走一次。

**Files:**
- Create dirs: `tests/smoke/`, `tests/probe/`, `tests/harness/`, `tests/scripts/`
- Move: `tests/` 下 325 个文件（`tests/lib/` **不动**）
- Modify: 所有 `.sh` 里的 `res://tests/…`、以及全仓 `.gd`/`.tscn` 里的测试路径

**Interfaces:**
- Consumes: Task 1 的守卫。
- Produces: `res://tests/{smoke,probe,harness,scripts}/…`；`res://tests/lib/…` 不变。

**分类判据（按文件名后缀，规则化）：**

| bucket | 规则 | 组数 |
|---|---|---|
| `lib/`（不动） | 已存在 | 2 |
| `smoke/` | stem 以 `_smoke` 结尾 | 30 |
| `probe/` | stem 以 `_probe` 结尾（含 `kh_l*_probe`） | 73 |
| `harness/` | `*_watcher` / `*_bot_input` / `*_client` / `net_lag_proxy.py` | 11 |
| `scripts/` | 三个诊断工具（`convert_map` / `seam_analyze` / `seam_screenshot`） | 3 |
| **留在 `tests/` 顶层** | `env.sh`（共享基础设施）、`README.md` | 2 |
| **需人工定位** | 见 Step 2 的表 | 5→1 |

**★ 一个 stem 的**所有**伴随文件（`.gd` + `.gd.uid` + `.tscn` + `.sh` + `.log`）必须进同一个 bucket** —— 否则 `*_probe.sh` 找不到它的 `.gd`，或 `.log` 散在别处。

- [ ] **Step 1: 规则化搬迁（四个 bucket 一次性做完）**

```bash
cd tests
mkdir -p smoke probe harness scripts

# ── smoke/：stem 以 _smoke 结尾的全部伴随文件 ──
for f in *_smoke.gd *_smoke.gd.uid *_smoke.tscn *_smoke.sh *_smoke.log; do
  [ -e "$f" ] && git mv "$f" smoke/
done

# ── probe/：stem 以 _probe 结尾（含 kh_l*_probe）──
for f in *_probe.gd *_probe.gd.uid *_probe.tscn *_probe.sh *_probe.log; do
  [ -e "$f" ] && git mv "$f" probe/
done

# ── harness/：子进程观察者、机器人、裸客户端、代理 ──
for f in *_watcher.gd *_watcher.gd.uid *_bot_input.gd *_bot_input.gd.uid \
         net_lag_client.gd net_lag_client.gd.uid net_lag_client.tscn net_lag_proxy.py; do
  [ -e "$f" ] && git mv "$f" harness/
done
git mv pvp_smoke_client.gd pvp_smoke_client.gd.uid pvp_smoke_client.tscn harness/
cd ..
```

★ **`env.sh` **不搬** —— 它是所有脚本共享的基础设施，没有"伙伴文件"，留在 `tests/` 顶层。**（搬家后每个 `.sh` 都下沉了一层，`source "$(dirname "$0")/env.sh"` 会**失效**，见 Step 4b。）

- [ ] **Step 2: 人工定位剩下 5 个 stem（必须逐个决定，不能靠规则）**

| 文件 | 去处 | 理由 |
|---|---|---|
| `menu_autotest.gd`(+`.uid`) | `smoke/` | 是 `-- --autotest-*` 的自检脚本，与 `*_smoke` 同类；但名字不含 `_smoke`，规则抓不到 |
| `convert_map.gd`(+`.uid`) | `scripts/` | 一次性地图格式转换工具，不是测试 |
| `seam_analyze.gd`(+`.uid`) | `scripts/` | 环面接缝**诊断**工具（人工看图），不做断言 |
| `seam_screenshot.gd`(+`.uid`) | `scripts/` | 同上，截图版 |
| `README.md` / `import.log` / `reconcile_run.log` | **删除或留顶层** | 见 Step 3 |

```bash
cd tests
git mv menu_autotest.gd menu_autotest.gd.uid smoke/
for n in convert_map seam_analyze seam_screenshot; do
  git mv "$n.gd" "scripts/$n.gd"; git mv "$n.gd.uid" "scripts/$n.gd.uid"
done
cd ..
```

- [ ] **Step 3: 处理跑批产生的日志（`.log` 是被 gitignore 的，大概率未跟踪）**

```bash
cd tests
rm -f import.log reconcile_run.log      # 跑批副产物,可重建
ls -F | grep -v '/$'                     # 期望:只剩 README.md 与 env.sh
cd ..
```
`tests/README.md` 留在 `tests/` 顶层（它是这一整块的入口说明）。

- [ ] **Step 4: 按映射重写路径**

规则：旧路径 `res://tests/<stem>.<ext>` → 新路径按 Step 1/2 的归属表。

```bash
python - <<'PY'
import pathlib, re, os

buckets = {}
for d in ("smoke","probe","harness","scripts"):
    for f in pathlib.Path("tests", d).iterdir():
        if f.is_file():
            stem = re.sub(r'\.(gd|tscn|sh|py|log)(\.uid)?$', '', f.name)
            buckets.setdefault(stem, d)
buckets["menu_autotest"] = "smoke"
for n in ("convert_map","seam_analyze","seam_screenshot"): buckets[n] = "scripts"

roots = ["core","scenes","server","ui","tests","tools","docs"]
pat = re.compile(r'res://tests/([A-Za-z0-9_]+)\.([a-z]+)')
changed, unknown = [], set()

def fix(s):
    def sub(m):
        stem, ext = m.group(1), m.group(2)
        d = buckets.get(stem)
        if d is None:
            return m.group(0)          # lib/ 等未搬动的,原样
        return f"res://tests/{d}/{stem}.{ext}"
    return pat.sub(sub, s)

for r in roots:
    for f in pathlib.Path(r).rglob("*"):
        if f.suffix not in (".gd",".tscn",".sh",".md",".py"): continue
        s = f.read_text(encoding="utf-8", errors="surrogateescape")
        t = fix(s)
        if t != s:
            f.write_text(t, encoding="utf-8", errors="surrogateescape")
            changed.append(str(f))

# 反向核对:每个被搬到新 bucket 的 stem,它的新路径必须真的存在
missing = []
for stem, d in buckets.items():
    if not list(pathlib.Path("tests", d).glob(f"{stem}.*")):
        missing.append(f"{stem} -> tests/{d}/")
print("改写文件数:", len(changed))
if missing:
    print("★ 归属表里有但目录里没有的东西:")
    for m in missing: print("  ", m)
PY
```

- [ ] **Step 4b: 修所有被搬走的 `.sh` 的 `env.sh` 寻址（★ 漏了这步，**每个跑批脚本都会「No such file」**）**

`.sh` 原先都写 `source "$(dirname "$0")/env.sh"` —— 现在它们比 `env.sh` 低了一层：

```bash
grep -rn 'env\.sh' tests/smoke/*.sh tests/probe/*.sh tests/harness/*.sh 2>/dev/null
```

```bash
python - <<'PY'
import pathlib
n = 0
for d in ("smoke","probe","harness"):
    for f in pathlib.Path("tests", d).glob("*.sh"):
        s = f.read_text(encoding="utf-8")
        t = s.replace('$(dirname "$0")/env.sh', '$(dirname "$0")/../env.sh')
        if t != s:
            f.write_text(t, encoding="utf-8"); n += 1
            print("fixed:", f)
print("改写脚本数:", n)
PY
```

```bash
grep -rn 'env\.sh' tests/smoke/*.sh tests/probe/*.sh tests/harness/*.sh 2>/dev/null
# 期望：全部是 $(dirname "$0")/../env.sh
```

- [ ] **Step 5: 跑守卫（★ 注意**新路径** —— 守卫自己也被 `*_probe` 规则搬走了）**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/probe/path_integrity_probe.gd
```
Expected: `PATH INTEGRITY: ALL-OK`

**若报 `res://tests/<stem>.<ext>` 找不到**：说明 Step 4 的归属表和 Step 1/2 的实际搬动不一致（漏搬或多搬）。**不要**把报错的路径加进豁免文件 —— 那不是"故意不存在"，是真的没搬对。

- [ ] **Step 6: 刷新 uid 缓存 + 抽查两个真链路脚本的路径**

```bash
"$GODOT" --headless --path . --import > /dev/null 2>&1
grep -n 'res://tests/' tests/env.sh tests/probe/reconnect_probe.sh 2>/dev/null | head -20
# 期望:全部指向 tests/probe/ 或 tests/smoke/ 下的真实文件
```

- [ ] **Step 7: 提交**

```bash
git add -A tests core scenes server ui docs
git commit -m "refactor(dir): tests/ 拆成 smoke/probe/harness/scripts 四组"
```

---

### Task 6: 更新文档里的路径引用

**Files:**
- Modify: `CLAUDE.md`（约 100 处 `tests/<名>` 与 `render/`、`ui/`、`server/` 路径）
- Modify: `RELEASE.md`（若含路径）
- Modify: `docs/` 下的历史文档 —— **不改**（它们是历史记录，不是活引用）

**Interfaces:**
- Consumes: Task 2~5 完成后的新目录结构。

- [ ] **Step 1: 先量出改动面**

```bash
grep -c 'tests/' CLAUDE.md
grep -o 'tests/[a-z0-9_]*\.\(gd\|tscn\|sh\)' CLAUDE.md | sort -u | wc -l
grep -n 'res://render/\|res://ui/[a-z_]*\.\|res://server/[a-z_]*\.gd' CLAUDE.md | wc -l
```

- [ ] **Step 2: 用与 Task 5 Step 4 同一份归属表批量改写 `CLAUDE.md`**

```bash
python - <<'PY'
import pathlib, re
buckets = {}
for d in ("smoke","probe","harness","scripts"):
    for f in pathlib.Path("tests", d).iterdir():
        if f.is_file():
            stem = re.sub(r'\.(gd|tscn|sh|py|log)(\.uid)?$', '', f.name)
            buckets.setdefault(stem, d)
buckets.update({n:"smoke" for n in ["menu_autotest"]})
buckets.update({n:"scripts" for n in ["convert_map","seam_analyze","seam_screenshot"]})

p = pathlib.Path("CLAUDE.md")
s = p.read_text(encoding="utf-8")

def sub_tests(m):
    stem, ext = m.group(1), m.group(2)
    d = buckets.get(stem)
    return f"tests/{d}/{stem}.{ext}" if d else m.group(0)

s = re.sub(r'(?<!/)tests/([A-Za-z0-9_]+)\.([a-z]+)', sub_tests, s)
p.write_text(s, encoding="utf-8")
print("done")
PY
```

- [ ] **Step 3: 人眼核对改完的路径段落**

```bash
grep -n 'tests/smoke/\|tests/probe/\|tests/harness/\|tests/scripts/' CLAUDE.md | head -30
```

★ **必须抽查**：CLAUDE.md 里有大量"守卫:`tests/xxx_probe.tscn`"式的引用，批量替换的判据是 stem —— 若有同 stem 不同 bucket 的情况，会静默改错。

- [ ] **Step 4: 提交**

```bash
git add CLAUDE.md RELEASE.md
git commit -m "docs: 同步目录重构后的路径引用"
```

---

### Task 7: 两张常量表的漂移修复（与 Task 1~6 **无依赖**，可随时单独跑）

> ★ 本 task 改的是**常量内容**，与目录搬动无关。按「执行顺序」它排在 **Task 5 之前**，所以守卫落在 `tests/settings_actions_smoke.gd`；Task 5 的 `*_smoke` 规则会把它自动搬进 `tests/smoke/`，本 task 不必预判。
> ★ 起因：一次 const 穷举盘点（478 条 / 74 个文件）里捞出两个**已经在漂**的表。其余 476 条经判定**一条都不该外置**（理由见「明确不做的事」）。

**Files:**
- Create: `tests/settings_actions_smoke.gd`（`extends SceneTree`，`-s`）+ 其 `.gd.uid`
- Modify: `scenes/settings_menu.gd:7-10`（补两条）
- Modify: `scenes/royale_lobby.gd:12`（删一行）

**Interfaces:**
- Consumes: 无（独立于 Task 1~6）。
- Produces: 判据文本 `SETTINGS ACTIONS OK`。

**两个已知缺陷（均已实测确认，不是推测）：**

1. **`scenes/royale_lobby.gd:12` 的 `WEAPON_NAMES` 是死代码 + 陈旧副本。**
   全仓**零读取**（`.claude/` 与 `.superpowers/` 之外只有声明行本身）；它是 `data/weapons.json` 的手抄副本，且**已经漂了**：5 条 vs 注册表 **6** 条（缺 id 6 激光枪），名字也不同（注册表是「重狙 M82A1」「霰弹 S686」「榴弹发射器」）。`.superpowers/sdd/progress.md` 里当年把它登记成 Minor（「只写不读（KH 亦如此，逐字照搬保留）」）—— 登记了但一直没清。
   ⚠ **它不是"该转 json"，是"该删"**：武器名的唯一来源已经是 `WeaponRegistry.name_of()`。

2. **`scenes/settings_menu.gd:7` 的 `ACTION_NAMES` 覆盖不全，且兜底是静默的。**
   表里 7 条，`Settings.REMAPPABLE_ACTIONS` 有 **9** 条（多 `F` / `Q`）。调用点是
   `UiFactory.label(ACTION_NAMES.get(action, action), 32)` —— 漏一条**不报错**，只是设置页那一行显示裸的 `"F"` / `"Q"` 而不是中文名。全仓**没有任何探针**钉这张表的覆盖。
   ⚠ **转 json 不解决"漏了一条"**；要的是补全 + 一条覆盖断言。

- [ ] **Step 1: 先写守卫（TDD:让它先红）**

`tests/settings_actions_smoke.gd`：

```gdscript
extends SceneTree

# 设置页动作名覆盖守卫:`REMAPPABLE_ACTIONS` 里的每个动作都必须有中文显示名。
# 跑法: "$GODOT" --headless --path . -s res://tests/settings_actions_smoke.gd
# 通过 = `SETTINGS ACTIONS OK` 退出 0。
#
# ★ 为什么需要它:`settings_menu` 用的是 ACTION_NAMES.get(action, action) —— 漏一条
#   不报错,只是那一行显示裸的动作名(F/Q 曾经就是这样,实测)。
# ★ 用 get_script_constant_map() 读常量,不直接取属性:取不存在的属性会抛错,
#   而 -s 抛错走不到 quit() → 永久挂起。
# ★ 两个方向都查:漏了要红;表里留着已经不可重映射的陈旧动作也要红。

var _fail := 0

func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)

func _const_map(path: String) -> Dictionary:
	var gs: GDScript = load(path)
	return {} if gs == null else gs.get_script_constant_map()

func _initialize() -> void:
	var st := _const_map("res://core/config/settings.gd")
	var sm := _const_map("res://scenes/settings_menu.gd")
	# ★ 空载守卫:读不到就 quit,免得在空表上把"零条"当成"全过"
	if st.is_empty() or sm.is_empty():
		print("SETTINGS ACTIONS FAILED: 读不到 settings.gd / settings_menu.gd 的常量表")
		quit(1)
		return

	var actions: Array = st.get("REMAPPABLE_ACTIONS", [])
	var names: Dictionary = sm.get("ACTION_NAMES", {})
	_check(actions.size() > 0, "REMAPPABLE_ACTIONS 不应为空")
	_check(names.size() > 0, "ACTION_NAMES 不应为空")

	for a in actions:
		_check(names.has(a), "动作 %s 在 ACTION_NAMES 里没有中文显示名" % a)
	for k in names:
		_check(actions.has(k), "ACTION_NAMES 里的 %s 不在 REMAPPABLE_ACTIONS 中(陈旧)" % k)

	if _fail == 0:
		print("SETTINGS ACTIONS OK（%d 个动作）" % actions.size())
		quit(0)
	else:
		print("SETTINGS ACTIONS FAILED: %d" % _fail)
		quit(1)
```

- [ ] **Step 2: 跑它，确认**红**（这一步是"红灯验得住"的证据，不能跳）**

```bash
source tests/env.sh
"$GODOT" --headless --path . -s res://tests/settings_actions_smoke.gd
```
Expected:
```
[FAIL] 动作 F 在 ACTION_NAMES 里没有中文显示名
[FAIL] 动作 Q 在 ACTION_NAMES 里没有中文显示名
SETTINGS ACTIONS FAILED: 2
```

**若它直接绿**：说明 Step 1 的判据写错了（例如 `get_script_constant_map()` 取到了别的东西）。**停下来查，别把绿当成"本来就没问题"。**

- [ ] **Step 3: 补全 `scenes/settings_menu.gd` 的 `ACTION_NAMES`**

```gdscript
const ACTION_NAMES := {
	"left": "左移", "right": "右移", "up": "跳跃/上爬", "down": "下蹲/下落",
	"charge": "冲刺", "attack": "开火", "R": "重开(单机)",
	"F": "拾取", "Q": "丢弃(长按)",
}
```

（`F` = 拾取最近一把武器，长按 `Q` = 丢弃 —— 与 `CLAUDE.md` 的 §武器背包 一致。）

- [ ] **Step 4: 再跑守卫，确认转绿**

```bash
"$GODOT" --headless --path . -s res://tests/settings_actions_smoke.gd
```
Expected: `SETTINGS ACTIONS OK（9 个动作）`

- [ ] **Step 5: 删掉 `scenes/royale_lobby.gd:12` 的死常量**

删这一行（连同它的空行）：

```gdscript
const WEAPON_NAMES := {1: "手枪", 2: "步枪", 3: "重狙", 4: "霰弹", 5: "榴弹"}
```

- [ ] **Step 6: 验证零引用（关键：本仓纪律是"删了必须能证明真的没人读"）**

```bash
grep -rn 'WEAPON_NAMES' . 2>/dev/null \
  | grep -v '/\.claude/' | grep -v '/\.godot/' | grep -v '\.superpowers/' | grep -v 'claude-md-full'
# 期望：无输出
```

**若还有输出**：那不是死常量，退回 Step 5，改为把该处的读取改问 `WeaponRegistry.name_of(id)`。

- [ ] **Step 7: 生成 `.uid` 并提交**

```bash
"$GODOT" --headless --path . --import > /dev/null 2>&1
ls tests/settings_actions_smoke.gd.uid     # 期望：存在
# ★ 新建 .gd 必须连它的 .uid 一起 git add(漏了 = 引用处靠陈旧 path 兜底)
git add tests/settings_actions_smoke.gd tests/settings_actions_smoke.gd.uid
git add scenes/settings_menu.gd scenes/royale_lobby.gd
git commit -m "fix(ui): 补全设置页动作名覆盖 + 删掉 royale_lobby 的死常量 WEAPON_NAMES

- ACTION_NAMES 缺 F/Q,靠 .get(action, action) 静默显示裸动作名;补全并加覆盖守卫
- WEAPON_NAMES 全仓零读取,且是 data/weapons.json 的陈旧副本(5 条 vs 6 条);删除"
```

---

## 收尾验收（交给用户）

实施者做完 Task 1~6 后，**由用户**跑下列检查确认没有功能性回归（本 plan 不再代跑）：

1. `"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd` → `SMOKE OK`
2. 任选三个场景探针（例如 `tests/probe/hud_declarative_probe.tscn`）→ 文本 `ALL-OK`
3. 开一次 Godot 编辑器，确认 FileSystem 面板无红色/丢失资源
4. 导出一次 exe，确认 `--registry-report` 那一步仍打 `[registry] weapons=6 ids=[…]`（证明 `data/weapons.json` 仍在包里 —— 本 plan 没动 `data/`，这步是防手滑）

## 明确不做的事

- **不动 `maps/` 与 `data/`**（`include_filter` 是字面量，见 Global Constraints）。
- **不重排 `core/{config,net,present,sim}/` 的内部结构**：已经是功能式布局，重排是纯 churn。（Task 2 会往 `core/present/` **加**三个文件，那是并入，不是重排。）
- **不拆 `scenes/` 顶层**（`level_0` / `main_menu` / 三个 `*_game` / 三个 `*_lobby` 与 4 个实体目录混在一起）：改动面 72 处引用，收益只是"看着整齐"。若日后要做，做法与本 plan Task 3/4 相同（建 `scenes/modes/`、`scenes/lobby/`、`scenes/menu/`，然后按映射表重写）。
- **不改 `assets/`**：`fonts/` + `textures/` 已合规（这是 2026-08-21 那次规范化的成果）。
- **不把调参外置成 `.tres` / `.json`**（针对 478 条 const 的盘点结论）。三条硬约束决定了外置在这个仓库里几乎全是负收益：
  1. **7 个 const 直接用作函数默认参数值**（`GraceWindow.enter(seconds = DEFAULT_SECONDS)`、`NetBus.start_server(port = DEFAULT_PORT)`、`WeaponInventory._init(capacity = DEFAULT_CAPACITY, …)`、`LobbyRooms.team_ready(size = TEAM_SIZE)`、`MatchBootstrap.start_on(map_path = PVP_MAP)`、`LobbyRooms._release_port_later(delay = …)`）。这些在**解析期**求值 —— Godot 没有"从资源取 const"，改成运行期加载会**直接编不过**，且要连带改掉每个调用点。
  2. **另有约 10 条写在别的 const 的初始化式里**：`CELL_COST := {TIER_LIGHT: 2, …}`、`PX_PER_CELL := RADIUS_PX / RANGE_CELLS`、`PANEL_W := COLS * CELL + …`、`HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS`、`BODY_BASE_COLOR := UiFactory.C_TEAM_A` 等。同样解析期。
  3. **`core/sim/*` 与 `core/config/*` 刻意是"纯静态、不引 autoload、可 `-s` 测"** —— `spawn_pool_smoke` / `squash_stretch_smoke` / `weapon_inventory_smoke` / `enemy_logic_smoke` 等直接 `load()` 这些文件读常量。外置成 `.tres` 等于给每个读者加一次加载 + 缓存，并打破这条性质。
  再加两条环境事实：**协议常量**（位掩码 / 端口 / 超时）改值 = 改协议、两端必须同 build，编译期常量在这里是**特性**；**结构不变量**那一档（约 30 组）的价值恰恰是"写在同一处 + 被探针逐位钉住"，外置反而削弱"改一处立刻红"。
  ⇒ 那份盘点里真正要动的**只有 Task 7 那两条**；其余 476 条保持不变。若日后团队里出现专职策划，**唯一**值得重估的是 `EnemyParams`（93 个值、4 个嵌套类）→ `data/` 或 `.tres`，但那时也要先解决上面第 3 条（`-s` 冒烟直读）。
