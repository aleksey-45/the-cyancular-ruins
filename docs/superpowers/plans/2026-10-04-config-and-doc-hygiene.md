# 配置与文档卫生实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把审计 §1 里"配置/文档"这一类小账还清：恢复被写坏的 `[debug]` 日志键（并给它一条守卫）、补 `.bat` 的 EOL 规则、订正探针里的第三套陈旧窗口数字、把"已裁定不做"的判决与 §3/§4 的复核结论**落在纸上**（后者只出文档，不动代码）。

**Architecture:** 五个互不依赖的小任务；前两个改配置、第三个改一条测试常量、后两个是纯文档。**没有任何生产逻辑改动** ⇒ 除 `[debug]` 键那条外都不需要真链路验证。

**Tech Stack:** Godot 4.7.1（非 mono）、GDScript `-s` 冒烟、`.gitattributes`、Markdown。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §1.2/§1.3/§1.4 相关条 + §3/§4 全部条 + 用户裁定（Q1/Q4/Q5/Q7）。

## Global Constraints

- **判据是 grep 文本**（`SMOKE OK`），不看退出码。
- `-s` 冒烟**必须写空载守卫**（`load()` 后立刻 `if X == null: print(...); quit(1); return`），否则抛错走不到 `quit()` ⇒ 进程**永久挂起**；跑新冒烟一律套外层 `timeout`。
- **版本号唯一来源**是 `project.godot` 的 `application/config/version`，**只能写数字+点**（写 `v0.5.0`/字母会让导出失败）⇒ 本计划**不得**碰它。
- 逐个文件点名 `git add`；**绝不** `git add -A`。
- ★ 本计划**不碰** `CLAUDE.md`（协调者统一订正）；要改的是 `docs/eng/` 与 `project.godot`。

## Review Focus

1. **`[debug]` 那三行的现状不是"名字写错"而是"键名被吞进乱码"**（Task 1）⇒ 必须**整块替换**，不能只改值；改错会让"文件日志"静默失效（`max_log_files` 读不到就回落默认，**不报错**）。
2. **守卫必须能回答"去掉什么它才红"**（Task 1）⇒ 断言 `has_setting` + `max_log_files == 64`；只断言"没有乱码"是查子串，抓不到"键名被改错但没乱码"。
3. **`aim_probe` 是"预测器"不是"校验器"**（Task 3）⇒ 改它的常量会**改变它的输出**，所以必须"改 + 重跑 + 把新读数记回文件头注"，否则留下的是一份**参数已变、结论未复核**的输出。
4. **§3/§4 复核只出文档**（Task 5）⇒ 用户裁定"先不动代码"；文档里每条要给**三问的答案**（理由是否仍成立 / 值不值得 / 有没有更主流替代），并显式区分"判定"与"待办"。
5. **"已裁定不做"必须带翻案条件**（Task 4）⇒ 否则下一代 agent 会把 §2.7/§2.8 当新问题**重查一遍**（本仓已发生过多次）。

---

### Task 1: 恢复 `[debug]` 的文件日志三键 + 一条守卫

**Files:**
- Modify: `project.godot:33-36`
- Create: `tests/smoke/project_settings_smoke.gd`（`-s`）

**Interfaces:**
- Consumes: Godot 的 `ProjectSettings`（`has_setting(path)` / `get_setting(path)`）；仓内 `-s` 冒烟的空载守卫惯例（见 Global Constraints）。
- Produces: `project.godot` 的 `[debug]` 段恢复为三个真键 —— 后续无人消费，只为"文件日志真的开着"。

- [ ] **Step 1: 写失败的断言**

`tests/smoke/project_settings_smoke.gd`（`extends SceneTree`）断言：
① `ProjectSettings.has_setting("debug/file_logging/enable_file_logging")` 且值为 `true`；
② `…/enable_file_logging.pc` 存在且为 `true`；
③ `int(ProjectSettings.get_setting("debug/file_logging/max_log_files")) == 64`。
打印 `SMOKE OK` 后 `quit(0)`；任一条不成立打印失败项 + `quit(1)`。★ 写空载守卫。

- [ ] **Step 2: 跑它，确认红**

Run: `timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/project_settings_smoke.gd`
Expected: 不出现 `SMOKE OK`；三条断言全红（现状是乱码键，真键**一条都不存在**）。

- [ ] **Step 3: 整块替换那一段**

把 `project.godot:33-36`（`[debug]` + 两行乱码键）替换成：
```ini
[debug]

file_logging/enable_file_logging=true
file_logging/enable_file_logging.pc=true
file_logging/max_log_files=64
```
★ **不要**保留任何乱码行；★ 值写裸 `true`/`64`（Godot 的 ini 解析器对 `"…"=true` 那种写法本来就认不出来）。

- [ ] **Step 4: 跑它，确认绿 + 变异**

Run: 同 Step 2 ⇒ `SMOKE OK`。
变异（档 1，挑一条）：把 `max_log_files` 改成 `32` ⇒ 断言 ③ 必须红；复原。

- [ ] **Step 5: 提交**

```bash
git add project.godot tests/smoke/project_settings_smoke.gd
git commit -m "fix(config): 恢复 [debug] 的文件日志三键(原键名被乱码吞掉 ⇒ 文件日志静默失效)+ -s 守卫"
```

---


- ★★ **控制器追认（2026-10-04，实现者实测）—— 本 Step 的断言 ①② 在 Godot 4.7.1 上"部分恒真"**

实现者拿空工程实测:`debug/file_logging/*` 这三个键都是**引擎内置设置** ⇒ `has_setting(...)` 与
"文件里有没有写"**无关**(连本仓从未写过的 `log_path` 也返回 true);而 **`.pc` 的引擎默认值就是 `true`**
⇒ 断言 ② **删掉那行也照样绿**。真正跟着 `project.godot` 走的只有 ①(`enable_file_logging` 引擎默认 **false**)
与 ③(`max_log_files` 引擎默认 **5**)。

⇒ 控制器裁定:**保留实现者另加的 ④**(读 `project.godot` **原文**判三行**逐字**存在)作为**承重断言** ——
它才是唯一拦得住 `d6d2440` 那次事故(键名被乱码吞掉)的形状。①② 保留但**不算守卫**(它们"存在性"那半边恒真)。
★ 踩坑记录(实现者):初版 ④ 用 `"\n" + kv + "$"` **假红过 3 条** —— Godot 的 `RegEx` 里 `$` 是**整个字符串**的
末尾、**不按行**;改成两侧夹换行才对(已写进注释)。

### Task 2: `.bat` 的 EOL 规则（Q4 裁定：只加规则，不归一化工作树）

**Files:**
- Modify: `.gitattributes`
- Modify（若其自述不实）: `start_server.bat` 的头注

**Interfaces:**
- Consumes: `.gitattributes` 现状（`* text=auto eol=lf` + `*.ps1 text eol=crlf`）。
- Produces: `*.bat` 一律 CRLF 的仓库规则。

- [ ] **Step 1: 加规则**

在 `*.ps1 text eol=crlf` 之后加：
```
# Windows 批处理同样必须 CRLF。
*.bat text eol=crlf
```

- [ ] **Step 2: 核对 `start_server.bat` 的自述**

读它的头注：若写着"纯 ASCII"而实际不成立（有中文/全角字符），就地订正那句；★ **不要**顺手把文件内容整体转码。

- [ ] **Step 3: 提交（只点两个文件）**

```bash
git add .gitattributes start_server.bat
git commit -m "chore(eol): .bat 一律 CRLF(与 .ps1 同规则);订正 start_server.bat 的自述"
```
★ **不动**那 30 个 CRLF 漂移的工作树文件（用户裁定：只加规则，不做全量归一化 —— 归一化会制造一个巨大的、与本批无关的 diff）。

---

### Task 3: `aim_probe` 的第三套陈旧窗口/SubViewport 数字

**Files:**
- Modify: `tests/probe/aim_probe.gd`（头注 `:4-8` 与 `const VP := Vector2(2496, 1872)`）
- Modify: `tests/probe/aim_probe.gd` 头注（把重跑后的新读数写回去）

**Interfaces:**
- Consumes: 生产真值 —— 窗口基准 `1920×1440`（`project.godot:40-41`）、世界 SubViewport `2208×1728`（`scenes/level_0.tscn:13`）。
- Produces: 一份**参数与生产一致**的瞄准预测器。

- [ ] **Step 1: 先确认生产真值（别抄本计划）**

Run: `grep -n "viewport_width\|viewport_height" project.godot; grep -n "size = Vector2i" scenes/level_0.tscn`
⇒ 用**读到的**值，不用记忆里的。

- [ ] **Step 2: 改常量 + 头注**

把 `const VP` 改成生产值（写作当时是 `2208×1728`）；头注里那句"SubViewport2496×1872"一并订正，并注明改动日期与原因（"原先用的是更早的裁剪边口径"）。

- [ ] **Step 3: 重跑并把新读数记回头注**

Run: `timeout 300 "$GODOT" --headless --path . -s res://tests/probe/aim_probe.gd`
把它打印的关键读数（弧线在哪些鼠标位置被截断）与**改动前**的读数对比；若结论变了，在头注里写下"改前/改后"两行。
★ 这个探针**只是打印**（无断言）⇒ 它不是守卫，别在文档里把它写成守卫。

- [ ] **Step 4: 提交**

```bash
git add tests/probe/aim_probe.gd
git commit -m "fix(probe): aim_probe 的 SubViewport 用生产真值(原 2496×1872 是更早的裁剪边口径)+ 重跑读数记回头注"
```

---

### Task 4: `registered-debt.md` 新增「已裁定不做（won't fix）」

**Files:**
- Modify: `docs/eng/registered-debt.md`（新增 **§七**；现状是 §一…§六）
- Modify: `docs/2026-09-17-duel-probe-lobby-rpc-blocker.md`（订正被本次修复弄过期的一句）

**Interfaces:**
- Consumes: 用户裁定（§2.7 手柄焦点、§2.8 i18n「记录而不修改」；"发布版不再有菜单自动探针"）。
- Produces: 一份"判决 + 翻案条件"的落点 —— 下一代 agent 读了不会再重查。

- [ ] **Step 1: 照本文件既有的三段式写**

每条 = **症状 / 为什么判"不做" / 什么条件下翻案**。至少写：
① `audit §2.7`（手柄焦点模型）—— 判不做的理由 + 翻案条件（真做手柄支持时）；
② `audit §2.8`（i18n / 文案表）—— 同上；
③ **发布版里"菜单自动探针"退化为 no-op**：`scenes/main_menu.gd` 里那条依赖被 `ResourceLoader.exists("res://tests/smoke/menu_autotest.gd")` 守着 ⇒ 导出包剔掉 `tests/*` 之后它**静默不跑**（不是坏，是**没有**）—— 写清"所以发布版没有菜单端到端守卫"，翻案条件 = 把那条探针作为运行期资源随包发布（并说明代价）。

- [ ] **Step 1b: 补一条守卫覆盖上限到 §五** —— `tests/smoke/project_settings_smoke.gd` 测不到"日志**真的**落到 `user://logs/`"(只测设置值与文件原文),也测不到**导出模板的 release 半边**(本机跑的是 debug 模板)⇒ 写进 §五,并按 [`tests.md`](../eng/tests.md) 的口径写明"它测不到什么"。
- [ ] **Step 1c: 订正被本次修复弄过期的文档** —— `docs/2026-09-17-duel-probe-lobby-rpc-blocker.md:18-21` 仍写"该键**从未生效** ⇒ 配额仍是默认 5";`[debug]` 三键恢复后这句**已经反了** ⇒ 就地订正并注明 2026-10-04 恢复。★ 这是 `AGENTS.md` §2 完成标准里的"改了 A 就会过期的 B 都要 `grep` 过并订正"。

- [ ] **Step 2: 提交**

```bash
git add docs/eng/registered-debt.md
git commit -m "docs(debt): 新增 §七 已裁定不做(won't fix),含 §2.7/§2.8 与发布版无菜单自动探针(带翻案条件)"
```

---

### Task 5: §3/§4 的复核结论落成文档（**只出文档，不动代码**）

**Files:**
- Create: `docs/eng/conventions-review-2026-10.md`

**Interfaces:**
- Consumes: `audit-2026-10-04-design-conventions.md` 的 **§3（一致性债）** 与 **§4（有理由的偏离）** 全部条目。
- Produces: 一份**逐条判定**的文档（用户 Q5 裁定的形态）：每条给三问答案 + 处置归属（本批已做 / 后续批次 / 判不做 / 待复核）。

- [ ] **Step 1: 逐条读原文**

把 §3/§4 的每一条抄成一行（条目 id + 一句话），**不要**只读标题 —— 这两节里带着订正块，先读订正块再读条目。

- [ ] **Step 2: 逐条答三问**

① **理由是否仍成立**（回去 `grep` 源码，**不以文档为据**）；② **值不值得改**（改动面 vs 收益，按 `AGENTS.md` 的档位表定档）；③ **有没有更主流的替代做法**（有就写出来，这是本计划唯一需要"外部知识"的地方 —— 拿不准就标"待查"而不是编）。

- [ ] **Step 3: 落文档并给出归属**

每条一行：`结论 | 档位 | 归属（本批已做 / 建议批次 / 判不做 / 待复核）`。★ 文档头部写明"这份是**复核结论**，不是待办清单；要动手的条目按归属进各自批次"。

- [ ] **Step 4: 提交**

```bash
git add docs/eng/conventions-review-2026-10.md
git commit -m "docs(eng): §3/§4 逐条复核结论(三问 + 档位 + 归属),只落文档不动代码"
```

---

## 本计划**不含**

- **30 个 CRLF 漂移文件的工作树归一化** —— 用户裁定制只加 `.gitattributes` 规则（Q4）。
- **`[debug]` 之外的 `project.godot` 改动**（版本号、`[display]` —— 后者是 [窗口与显示设置](2026-10-04-window-and-display-settings.md) 的地盘）。
- **按 §3/§4 的结论动代码** —— 用户裁定制"先不动代码"；真要动，按 Task 5 给出的归属另开批次。
- **发布包裁剪**（`export_presets.cfg` 的 `exclude_filter`）—— 见 [发布包裁剪](2026-10-04-export-package-trimming.md)。
