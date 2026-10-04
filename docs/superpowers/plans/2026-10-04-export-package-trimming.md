# 发布包裁剪实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让两个导出预设**不再把 `tests/*`（实测 336 条 `res://tests/*` 路径）与 `tools/*` 打进 exe**，并**用二进制 grep 证明**收窄真的生效。

**Architecture:** 只改 `export_presets.cfg` 的两处 `exclude_filter`（两个预设各一行）。★ 改裁剪**不需要**重编模板（模板只在增删类/模块时才要，单次 ≈10~15 分钟；改 GDScript 或裁剪过滤只需**重导出**）。验证分两级：**导出到临时路径**（不动仓库根的两个 exe、不写 `builds/`/`releases/`）先证"排除生效"；再由用户点头跑一次真发布。

**Tech Stack:** Godot 4.7.1 **标准编辑器**（`GODOT_EDITOR`，与跑测试用的 console 版**不是同一个二进制**）、`export_presets.cfg`、二进制 grep。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §1.3 + [`RELEASE.md`](../../RELEASE.md) + 用户裁定（"发布包裁剪要做，但真导出那步要我先点头"）。

## Global Constraints

- 引擎路径：导出读 **`GODOT_EDITOR`**（[`tools/build_release.py`](../../tools/build_release.py) 里那一处默认值），跑测试读 `GODOT`（[`tests/env.sh`](../../tests/env.sh)）；**两个二进制不能混用**。
- **判据是 grep 文本 + 计数**，不看退出码；二进制里数 `res://tests/` 用 `grep -a -o … | wc -l`。
- 导出会写盘 ⇒ ★ **真发布那一跑必须先问用户**（它会覆盖仓库根的两个 exe 并写 `builds/`/`releases/`）；本计划的 Task 1/2 **不写**这些位置。
- 逐个文件点名 `git add`；**绝不** `git add -A`。
- 新增/改动的文档不得另抄版本号（版本唯一来源是 `project.godot` 的 `application/config/version`）。

## Review Focus

1. **`exclude_filter` 的 `*` 是否能跨 `/`**（Task 2）⇒ `tests/*` 在 Godot 的过滤器里未必递归匹配子目录。**别假设，用二元验证**：导出后 grep exe 数 `res://tests/`；若不为 0，改 `tests/**` 或逐个列 `tests/smoke/*,tests/probe/*,tests/harness/*,tests/scripts/*`，直到计数为 0。
2. **别把运行期真要的东西剔掉**（Task 1）⇒ 改之前先在**生产代码**里 grep 有没有 `res://tests/` 或 `res://tools/` 的引用；已知唯一一处是 `scenes/main_menu.gd` 的菜单自动探针依赖，它被 `ResourceLoader.exists(...)` 守着 ⇒ 剔掉后**静默退化为 no-op**（已登记进 debts，见 [配置与文档卫生](2026-10-04-config-and-doc-hygiene.md) Task 4）。
3. **两个预设都要改**（Task 1）⇒ `export_presets.cfg:13` 与 `:87` 是同一行文本的两份（客户端 + 服务端）⇒ 只改一处会留下**另一个 exe 仍然带 336 条**。
4. **不要顺手动裁剪模板**（Task 1/2）⇒ 改模板要重编 ≈10~15 分钟，且本批只动 `exclude_filter`。
5. **产物冒烟要真跑**（Task 3）⇒ `build_release.py` 自带产物冒烟（服务端走 `-- --worker --port 7999`、不碰 7777，并**断言输出里有「worker 就绪」**）；只报"没报错"会漏掉"零错误地跑错分支"。

---

### Task 1: 收窄两个预设的 `exclude_filter`

**Files:**
- Modify: `export_presets.cfg:13` 与 `:87`
- Modify: `scenes/main_menu.gd:154-155`（订正会随裁剪过期的那句注释 —— 见 Step 2b）

**Interfaces:**
- Consumes: 现状逐字 `exclude_filter="*.md,.superpowers/*"`（两处）；`DevTools/*` **不需要**加 —— 那 3 个文件已由 `git rm` 出库（见本会话更早的提交）。
- Produces: 两个预设都不再打包 `tests/*` 与 `tools/*`。

- [ ] **Step 1: 先查生产代码有没有引用**

Run: `grep -rn "res://tests/\|res://tools/" --include=*.gd core/ scenes/ server/ ui/ | grep -v "^tests/"` ⇒ 列出所有命中，**逐条判断**运行期是否需要（已知 `scenes/main_menu.gd` 那条是 `ResourceLoader.exists` 守卫的）。
★ 把这份清单写进报告：它是"裁剪安全性"的证据，不是走过场。

- [ ] **Step 2: 改两处**

两处都改成 `exclude_filter="*.md,.superpowers/*,tests/*,tools/*"`。
★ **逐个文件认领 hunk**：该文件里 `patch_delta_exclude_filters` / `encryption_exclude_filters`（`:20`/`:22`/`:94`/`:96`）**不要**动。

- [ ] **Step 2b: 顺带订正会随本步过期的那行注释**

`scenes/main_menu.gd:154-155` 现在写着「**注:「发布版会裁掉 tests/」不是这条守卫的理由**——`export_presets.cfg` 是
`export_filter="all_resources"`,`tests/` 会一起打进发布包,真实理由是文件可能不存在」。本步之后**前半句就反了**
(裁剪落地后 `tests/` **确实**不再进包) ⇒ 改成两段实况:`tests/` 曾经一起进包(所以"缺文件"才是真守卫理由),
**2026-10-04 起 `exclude_filter` 已含 `tests/*`** ⇒ 发布版里那条通道**没有了**(见 `registered-debt.md` §七 第 3 条,
它同时记着"这也是在发布产物上跑 `tests/probe/*.tscn` 的唯一通道"这个代价)。
★ 注释里**不要**再抄一份 `exclude_filter` 的值(那会变成第二处真相源);只说"已含 `tests/*`"并指向那个文件。

- [ ] **Step 3: 提交**

```bash
git add export_presets.cfg
git commit -m "build(export): exclude_filter 加 tests/*,tools/*(原先两个 exe 里各带 336 条 res://tests/* 路径)"
```

---

### Task 2: 导出到**临时路径**并数二进制里的残留

**Files:**
- 无（不改仓库文件；产物写到仓库**外**的临时目录）

**Interfaces:**
- Consumes: Task 1 的预设；`GODOT_EDITOR`；预设名（从 `export_presets.cfg` 的 `[preset.N]` 段读 `name=`，别猜）。
- Produces: "排除真的生效"的**二元证据**（计数从 336 → 0）。

- [ ] **Step 1: 读预设名与导出模板是否就绪**

Run: `grep -n "^\[preset\|^name=" export_presets.cfg | head -10`；确认导出模板已装（`builds/` 里有历史产物即说明装过）。

- [ ] **Step 2: 导出到临时路径（**不**碰仓库里的 exe）**

对**两个**预设各跑一次，输出到仓库外的临时目录（例：`$TEMP/cyr-trim-client.exe` / `-server.exe`）：
`"$GODOT_EDITOR" --headless --path . --export-release "<预设名>" "$TEMP/cyr-trim-client.exe"`
★ 若报"缺导出模板"，停下问用户（别自己下模板）。

- [ ] **Step 3: 数残留（判据）**

对**每个**产物：
`grep -a -o "res://tests/" "<exe>" | wc -l` ⇒ 期望 **0**（改前实测 336）；
`grep -a -o "res://tools/" "<exe>" | wc -l` ⇒ 期望 **0**。
★ 若不为 0 ⇒ 按 Review Focus 1 换写法（`tests/**` 或逐个列 `tests/smoke/*,…`）后**重导重数**，直到 0。把每一步的计数写进报告。

- [ ] **Step 4: 回收**

删掉临时产物（它们不是交付物）。★ 仓库工作树必须**干净**（`git status --short` 为空）。

---

### Task 3: 真发布一次（**必须先问用户**）

**Files:**
- 产物: 仓库根两个 exe + `builds/` + `releases/`（由脚本决定）

**Interfaces:**
- Consumes: Task 2 的结论；[`tools/build_release.py`](../../tools/build_release.py)（它导出、改名归档，并跑**产物冒烟**）。
- Produces: 一份"用户点头过的"发布产物 + 冒烟证据。

- [ ] **Step 1: 问用户**

明确告知：会**覆盖仓库根的两个 exe**、并在 `builds/`、`releases/` 写新产物；发布标识带时间戳（`<前缀>_v<版本>_<YYYYMMDDHHMM>`）。**得到同意再跑。**

- [ ] **Step 2: 跑**

Run: `python tools/build_release.py`
Expected: 导出成功 + **产物冒烟通过** —— 关键行是服务端那条输出里的「**worker 就绪**」；只"没报错"不算。

- [ ] **Step 3: 复核产物**

对最终产物重复 Task 2 Step 3 的两个计数（仍应为 0）；并确认版本行/归档名与 `project.godot` 的 `version`/`release_prefix` 一致（**别另抄一份版本号**）。

- [ ] **Step 4: 提交（若脚本改了工作树文件）**

`build_release.py` 会把版本写进 `core/config/build_info.gd` 再还原 ⇒ 正常情况下**工作树不脏**。若真有残留改动，**逐文件认领**后再决定是否提交。

---

## 本计划**不含**

- **重编裁剪模板**（增删类/模块）—— 本批只改 `exclude_filter`，不需要（见 Architecture）。
- **把菜单自动探针随包发布**（让发布版重新有端到端守卫）—— 已在 [配置与文档卫生](2026-10-04-config-and-doc-hygiene.md) Task 4 登记为"判不做 + 翻案条件"，要改是另一个决定。
- **`DevTools/*` 的排除** —— 那 3 个文件已 `git rm` 出库，没有可排除的对象。
- **`releases/` 的清理策略**（保留几份归档）—— 没在需求里。
