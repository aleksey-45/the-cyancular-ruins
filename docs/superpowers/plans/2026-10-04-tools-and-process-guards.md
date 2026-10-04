# 工具与流程守卫（audit §2.1 / §2.10 / §2.11）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把审计 §2 里"**规则与机制对不上**"这一类收口：让目录命名规则**真的覆盖顶层目录**、让 `.ps1` 那条自订规则**与现实一致且有机制守**、让 `start_server.bat` 那条**结构性永不命中**的清理行真的能用、并给"无差别强杀端口属主"加上护栏。

**Architecture:** 三条互不依赖的小任务。前两条改**检查器**（`tools/check_naming.py` + `AGENTS.md` 的规则文字），第三条改**一条批处理 + 一处平台工具**（`start_server.bat` / `core/net/proc_util.gd`）。★ 共同点：**都是"文档/规则说了一件事，机制做的是另一件事"** —— 修的时候两边一起对。

**Tech Stack:** Python 3（检查器）、Windows 批处理、GDScript（`ProcUtil`）、`AGENTS.md` 文档。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.1 / §2.10 / §2.11 + 用户裁定（"§2 也可以做，执行计划拆分细一点"）。

## Global Constraints

- **判据是 grep 文本 / 计数**，不是退出码。
- 逐个文件点名 `git add`；**绝不** `git add -A`。
- ★ 检查器（`tools/check_naming.py`）是**全仓守卫**：改它之后 `python tools/check_naming.py` 必须仍 **OK** —— 若新规则让**现存的**某个文件变红，那是**真发现**，要按 Task 的处置规矩办（要么修文件，要么把该文件写进 `ACCEPTED_CLASS_FILES` 并注明何时销），**不许**把规则调松到看不见它。
- ★ **规则文字与机制必须一起改**：不许只改 `AGENTS.md` 的文字（那就是本轮要消灭的病）。
- **不动** `.godot/`、`builds/`、`releases/`；不动任何 `res://` 运行期代码（第三条只动 `ProcUtil` 的一个函数 + 一条 `.bat`）。

## Review Focus

1. **规则 A 的修法不能只看"顶层"**（Task 1）：`walk_dirs()` 现在 `rel == "."` 就 `continue`，修完要保证**顶层与各层都 yield**，且**点开头的目录/`SKIP_DIRS` 仍被跳过**（别把 `.godot/` `.superpowers/` 拖进来）。
2. **"能红"必须自证**（Task 1/2）：新增/修改的规则要配一条**自测**（喂一个故意违规的合成名，断言它**必须**被报出来）—— 否则就是又一条"守卫比读起来少"。
3. **`.ps1` 那条规则的真相是"CRLF + （纯 ASCII 或 UTF-8 BOM）"**（Task 2）：`tools/gamelog/capture_session.ps1` 实测 **49 行非 ASCII、带 BOM、224 CRLF** ⇒ 带 BOM 时非 ASCII 是**安全**的；写成"必须纯 ASCII"是**比现实严**，与"绝不扫 `[7800,8300)`"同一类毛病。修法是**对齐 + 补机制**，不是把那 49 行删掉。
4. **`tokens=5` 是死行**（Task 3）：`netstat -ano` 的 **UDP 行只有 4 列**（实测），`tokens=5` **取不到 PID** ⇒ `start_server.bat` 的"杀旧大厅"从来没生效过。改成 `tokens=4` 才有用；★ 改完要**验证它真的取到 PID**（用一条只查不杀的 dry-run）。
5. **强杀护栏的失败模式**（Task 3）：护栏若写得太紧（只认某个进程名），**发布版 exe 被改名**时大厅就清不掉 7777 ⇒ bind 失败闪退（正是 `proc_util.gd:5-9` 记载的那个坑）。所以护栏要**保守**：**证不出是别人的**才杀；**证出来是别人的**要**明确报错**而不是静默杀。

---

### Task 1: 目录命名规则 A 覆盖顶层（audit §2.10）

**Files:**
- Modify: `tools/check_naming.py`（`walk_dirs()` + 新增 `--self-test`）

**Interfaces:**
- Consumes: 现状 —— `walk_dirs()` 在 `rel == "."` 时 `continue`（**顶层目录名从不被 yield**）⇒ 大写顶层目录（例：曾经存在的 `DevTools/`）**永远通不过检查也永远不被报**。
- Produces: `walk_dirs()` 覆盖顶层；`python tools/check_naming.py --self-test`（退出码 0 = 自测通过）。

- [ ] **Step 1: 先看现状与 SKIP_DIRS**

Run: `sed -n '20,40p;68,80p' tools/check_naming.py`（看 `SKIP_DIRS` 与 `walk_dirs`）
Run: `ls -d */ | tr -d '/' | grep -vE '^\.' | grep -E '[A-Z]'` ⇒ **顶层有没有已经不合规的目录**（有的话先报告再动手：那是真发现）

- [ ] **Step 2: 写"能红"的自测（先写成红的）**

加 `--self-test`：① 断言 `walk_dirs()` 的产出**包含**某个已知顶层目录（例：`tests`）—— **改前这条必红**；② 断言一个**合成的大写顶层名**（例：把 `DevTools` 喂给目录名判定函数）**会被报出来**；③ 断言 `.godot` / `.superpowers` 这类**点开头目录仍被跳过**。
★ 为了让 ② 可测，把"目录名合不合规"抽成一个**纯函数**（例：`bad_dir_name(name: str) -> bool`），`check_dirs()` 与自测共用它。

- [ ] **Step 3: 跑它，确认红**

Run: `python tools/check_naming.py --self-test` ⇒ **不出现**通过字样（改前 `walk_dirs()` 不 yield 顶层 ⇒ ① 红）。

- [ ] **Step 4: 修 `walk_dirs()`**

让顶层也产出（例：`rel == "."` 时 `yield d`，否则 `yield rel + "/" + d`）；保持 `SKIP_DIRS` 与点开头目录的跳过行为不变。★ 注意规则 A 的报错文本里 `path` 的形态（顶层没有 `/` 前缀）—— 别让消息变成 `/tests`。

- [ ] **Step 5: 跑它，确认绿 + 全仓仍 OK**

Run: `python tools/check_naming.py --self-test` ⇒ 通过；Run: `python tools/check_naming.py` ⇒ **命名检查 OK**（若这条变红 ⇒ Step 1 那个 `ls` 应该已经预告过 ⇒ 按 Global Constraints 处置）。

- [ ] **Step 6: 变异验证**

把 `walk_dirs()` 改回 `continue` ⇒ `--self-test` 必须红；复原。

- [ ] **Step 7: 提交**

```bash
git add tools/check_naming.py
git commit -m "fix(tools): check_naming 规则 A 覆盖顶层目录(原先 rel=='.' 直接 continue ⇒ 大写顶层目录永不报,DevTools/ 就是这样漏的)+ --self-test 能红"
```

---

### Task 2: `.ps1` 那条规则与现实对齐，并补机制（audit §2.11）

**Files:**
- Modify: `AGENTS.md:102`（规则文字）
- Modify: `tools/check_naming.py`（新增规则 E：`.ps1` 的 EOL 与编码）
- Modify: `tools/gamelog/capture_session.ps1`（**仅在**它真的违反新规则时才动）

**Interfaces:**
- Consumes: 实测 —— `capture_session.ps1` **225 行 / 49 行含非 ASCII / 带 UTF-8 BOM / 224 CRLF**；`.gitattributes` 已钉 `*.ps1 text eol=crlf` ✓。
- Produces: 规则文字 = "`.ps1` 必须 **CRLF**；**含非 ASCII 时必须带 UTF-8 BOM**"；机制 = 新规则 E 逐文件核这两点。

- [ ] **Step 1: 先量现状（别抄本计划）**

Run: `python - <`(读每个 `.ps1` 的字节) —— 对 `tools/**/*.ps1` 逐个报：**行数 / 含非 ASCII 的行数 / 有无 BOM / CRLF 数**。★ 把结果写进报告。

- [ ] **Step 2: 改规则文字（`AGENTS.md:102`）**

把"`.ps1` 保持**纯 ASCII** + CRLF"改成与机制一致的表述：**必须 CRLF；含非 ASCII 时必须有 UTF-8 BOM**（并保留"PowerShell 起带空格的路径要手工内嵌双引号"那半句）。
★ 顺手把"`.bat` 现已由 `.gitattributes` 钉 CRLF"也写进同一行附近（`b815c68` 已落地，避免这行再过期）。

- [ ] **Step 3: 写"能红"的自测 + 规则 E**

规则 E：对每个 `.ps1` 断言 ① 无裸 LF（或 CRLF 覆盖全部换行）② `纯 ASCII 或 有 BOM`；违反则计入 `_fail`。
自测：把合成内容（`b"echo hi\n"` = 裸 LF 无 BOM）喂给判定函数 ⇒ 必须报；喂 `b"\xef\xbb\xbf" + "非ASCII".encode()` ⇒ 必须**不**报。

- [ ] **Step 4: 跑全仓**

Run: `python tools/check_naming.py` ⇒ 若 `capture_session.ps1` 变红，说明它还有**裸 LF**（BOM 那半它满足）⇒ 修它的 EOL（★ **不要**动它的注释文字）；若全绿 ⇒ 什么都不用改那个文件。

- [ ] **Step 5: 变异验证**

把规则 E 的两个分支各破坏一次（① 把 CRLF 判定写成恒真 ② 把 BOM 判定删掉）⇒ 自测必须各自红；复原。

- [ ] **Step 6: 提交**

```bash
git add AGENTS.md tools/check_naming.py tools/gamelog/capture_session.ps1
git commit -m "fix(rule): .ps1 规则与现实对齐(CRLF + 含非 ASCII 须带 BOM —— 原先写'必须纯 ASCII'比现实严)+ check_naming 新增规则 E 逐文件核这两点(带能红的自测)"
```

---

### Task 3: `start_server.bat` 的死行 + 强杀护栏（audit §2.1）

**Files:**
- Modify: `start_server.bat:18-19`（`tokens=5` → `4`；加护栏）
- Modify: `core/net/proc_util.gd` 的 `kill_udp_port`（加护栏）
- Modify: `docs/eng/registered-debt.md`（若决定把"误杀"那半边登记为边界，见 Step 6）

**Interfaces:**
- Consumes: `netstat -ano` 的 UDP 行是 `UDP  0.0.0.0:7777  *:*  <PID>` = **4 列** ⇒ 现状 `tokens=5` **取不到 PID**（死行）；`proc_util.gd:20-26` 的 `kill_udp_port` 会杀掉该端口的**任意属主**（无护栏，但动机写在 `:5-9`，且有 `kh_l5_probe` 第 3 条守卫"取属主必须用 `-ExpandProperty OwningProcess`"）。
- Produces: 能真的取到 PID 的清理行 + 一个**保守**护栏（"证不出是别人的"才杀）。

- [ ] **Step 1: 先证明 `tokens=5` 是死的（别只信审计）**

Run（**只查不杀**）: `netstat -ano | findstr ":7777"` ⇒ 看列数；再跑一次现状那条 `for /f "tokens=5"` 的**等价 dry-run**（把 `taskkill` 换成 `echo`）⇒ **应打印不出 PID**。
再跑 `tokens=4` 的 dry-run ⇒ **应打印出 PID**。把两次输出写进报告。

- [ ] **Step 2: 改 `.bat`（`tokens=4`）+ 加护栏**

护栏形状（**保守**）：取到 PID 后先用 `tasklist /FI "PID eq <PID>"`（或 `wmic`/`powershell` 取 `ProcessName`）判断**属主进程名**：
- 名字是**我们这一族**（`Godot*`、`Cyancular*`、或该 exe 自己的名字）⇒ 杀；
- 名字明显是**别的程序** ⇒ **打印警告并退出**（提示"7777 被 X 占着，请手动处理"），**不杀**；
- **查不到名字**（权限/竞态）⇒ 按"保守"取向**打印警告并退出**（★ 不要默认杀）。
★ 这两条分支都要能在 dry-run 里复现（报告里给出两条实跑输出）。

- [ ] **Step 3: `proc_util.gd` 的 `kill_udp_port` 同样加护栏**

在 PowerShell 串里先取属主 PID，再取 `ProcessName`；只对"我们这一族"的进程 `Stop-Process`；否则**打印一行**（`push_warning` 或 `print`）说明"端口被别的进程占着，没有杀"。
★ **保持动机**（`proc_util.gd:5-9` 那个"双击服务端别闪退"必须仍然好使：**旧实例是我们这一族** ⇒ 仍会被杀掉）⇒ 这是本任务最重要的回归面。

- [ ] **Step 4: 跑守卫 + 回归**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/kh_l5_probe.tscn`（它的第 3 条**按去注释视图**验证"取属主必须用 `-ExpandProperty OwningProcess`" ⇒ 你的新串**必须仍满足**它）。
★ 若该守卫因你改了串而红 ⇒ **先读它的判据**（它是本仓既有的"踩过坑才修对"的守卫），要么你的写法退化了，要么守卫需要一起改（改守卫要说明理由）。

- [ ] **Step 5: 真正的回归（**需用户点头**）**

★ `start_server.bat`/大厅会在 **7777** 上起真进程 ⇒ 按 `AGENTS.md` §1 的纪律：**先查 `lobby_alive`**，为真则跳过并问。这一步建议**由用户跑**（双击 `start_server.bat`，看它是否仍能清掉旧实例、并在端口被别的程序占用时**给出警告而不是杀**）。

- [ ] **Step 6: 登记"误杀"那半边的边界**

在 `docs/eng/registered-debt.md` **§六**（功能性已知边界）或 §五 追加一条：即便加了护栏，"**属主名字判不出来**"时我们**放弃清理并报错**（而不是杀）⇒ 极端情况下双击会失败并打印提示。★ 写清"这是**有意的**取舍（宁可不杀，也不误杀）"与翻案条件。

- [ ] **Step 7: 提交**

```bash
git add start_server.bat core/net/proc_util.gd docs/eng/registered-debt.md
git commit -m "fix(net): start_server.bat 的 tokens=5 是死行(UDP 行只 4 列,从来没取到 PID)→4;强杀端口属主加保守护栏(证不出是别人的才杀,别人占着就报错不杀)"
```

---

## 本计划**不含**

- **§2.9 聚合回归入口 / CI** —— 量级最大，**单独一份**（用户裁定"拆分细一点"）。
- **§2.2/§2.3/§2.4（协议/权威）与 §2.5/§2.6（反射/兜底输入）** —— 各属"协议"与"单系统"两份计划，本计划不碰。
- **§2.7/§2.8** —— 已判"记录而不修改"，登记在 `registered-debt.md` §七。
- **`tools/gamelog/` 那套日志工具的功能改动** —— 本计划只碰 `.ps1` 的 EOL/编码（若它真违反规则）。
