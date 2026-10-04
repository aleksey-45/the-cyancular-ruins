# 去掉字符串反射与输入兜底（audit §2.5 / §2.6）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把审计 §2 里"**静态检查被绕过去**"的两类收口：① 时间回溯路径上对武器域的**字符串反射**（`get`/`call`/`set` 带字符串）改成**真类型访问**；② `WeaponBase` 里三处 `Input.is_action_*` **兜底读全局输入**收掉（武器永远只读**注入**进来的输入）。

**Architecture:** 两条都在 `scenes/` 层，互不依赖。①是**类型层面的收口**（加 `class_name` / 标类型 ⇒ 拼错名字当场编译报错，而不是运行期静默 `null`）；②是**依赖方向层面的收口**（输入只从 `player` 注入，不从全局总线偷偷兜底）。两者的验收都便宜且机械：**`grep` 那两个模式必须为 0** + 跑既有的回溯/武器探针。

**Tech Stack:** GDScript（Godot 4.7.1 标准版）、`-s` 冒烟、场景探针。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.5 / §2.6 + 用户裁定（"§2 也可以做，拆分细一点"）。

## Global Constraints

- **判据是 grep 文本 / 计数**，不是退出码；`-s` 自己跑套 `timeout 60`。
- 逐个文件点名 `git add`；**绝不** `git add -A`。★ 共用工作树：提交前逐文件 `git diff` **认领每个 hunk**。
- **不许改行为**：这两条都是**等价重构** —— 回溯后弹量/手持武器仍必须与改动前**逐字段相同**；武器开火判定仍必须**同一帧同一结果**。若有测试依赖旧兜底，那是**要修测试的发现**，不是放宽改动的理由（除非测试本身在测错东西 ⇒ 报告里说清）。
- ★ **先 `grep` 再动手**：本计划里所有 `文件:行号` 都是**写作当时**的；成员属主、调用者、依赖兜底的测试都**必须自己查**（本仓踩过十几次"照抄文档里的清单"）。
- 本计划**不碰**协议/`@rpc`/输入包内容（那是 Plan A），**不碰** `tools/`（那是 Plan C）。

## Review Focus

1. **反射的"为什么"要先答**（Task 1）：先 `grep` 出 `inventory` / `_current_index` / `equip_index` / `current_weapon` / `mag_ammo` 各属于哪个类、那个类**有没有 `class_name`**、`player.gd` 里那个变量**声明成什么类型**。★ 若答案是"没有 `class_name` 所以只能反射"⇒ 加 `class_name`（那正是 §2.5 的修法）；若答案是"类型就在手边，反射是历史遗留"⇒ 直接标类型。**别跳过这一步**：它决定改动是"加 1 行"还是"要动类结构"。
2. **`mag_ammo` 那种 `set` 尤其值得看**（Task 1）：`live2.set("mag_ammo", …)` 是**写别人的私有字段** —— 改类型化时要确认那个字段**应该**是公开的（加 setter 或改 `public`）还是**本来就不该从外面写**（那就该走一个方法）。★ 这一条可能会暴露出**真缺陷**（回溯直接改私有状态），发现就**报告**，别顺手改设计。
3. **兜底那三处是不是同一件事**（Task 2）：`_attack_pressed` / `_attack_just_pressed` / `_attack_just_released` 各有一句 `Input.is_action_*` 兜底 ⇒ 先数清**全仓还有几处**这类"兜底读全局输入"（审计说 4 处，别信，自己 `grep`），再决定是"三处一起收"还是"分两步"。
4. **谁在依赖兜底**（Task 2）：`grep` 出所有构造/持有 `WeaponBase` 的地方（含 `tests/`），判断"没有 `is_attack_*` 方法的 player"**真实存在吗**：若只在探针里存在 ⇒ 那些探针自己该改；若生产路径真有一条（例：某个模式用的是 `Node2D` 占位）⇒ 那是**设计问题**，写进 [`registered-debt.md`](../eng/registered-debt.md) 而不是硬删。

---

### Task 1: 去掉武器域的字符串反射（audit §2.5）

**Files:**
- Modify: `scenes/player/player.gd`（`:958-968` 一带，回溯写回武器状态那段）
- Modify: 被反射访问的类文件（**仅当**需要补 `class_name` / 类型标注 / setter 时）

**Interfaces:**
- Consumes: 现状 —— 回溯路径上：`wc.get("inventory")`、`inv.get("held")`、`wc.get("_current_index")`、`wc.call("equip_index", …)`、`wc.call("current_weapon")`、`live2.set("mag_ammo", …)`。★ `WeaponBase` / `WeaponInventory` **已有 `class_name`** ⇒ 反射**可能**只是历史遗留（Step 1 定论）。
- Produces: 同一段逻辑用**类型化访问**写成（字段直取 / 方法直调）。

- [ ] **Step 1: 定位（别动手先查清三件事）**

Run: `grep -n "var weapons\|@onready var weapons\|weapons =" scenes/player/player.gd | head`（那个变量的**声明类型**）
Run: `grep -rn "inventory\|_current_index\|func equip_index\|func current_weapon\|mag_ammo" scenes/weapons/*.gd core/sim/weapon_inventory.gd | head -20`（成员属主 + 有没有 `class_name`）
Run: `grep -rn "\.get(\"\|\.call(\"\|\.set(\"" scenes/player/player.gd | head -20`（**全仓这一带的反射总量** —— 顺手数清，别只修这一处）
★ 把三条输出写进报告，并回答 Review Focus 1。

- [ ] **Step 2: 写"能红"的守卫（先写成红的）**

★ 反射的坏处是"**拼错名字静默变 `null`**" ⇒ 守卫要能抓住它。两个候选（选其一，报告里说明为什么）：
  (a) **文本守卫**：`grep` 断言 `player.gd` 里那一带的 `\.get("`/`\.call("`/`\.set("` 计数为 **0**；
  (b) **功能守卫**：跑既有的回溯探针/冒烟（Step 1 里顺手 `grep` 出名字，例 `tests/probe/*rewind*` 或带 `wmags` 的断言），断言回溯后**弹量/手持武器逐字段等于快照值**。
★ 首选 (b) 当主判据（它测真行为），(a) 当"形状守卫"补一句。若 (b) 已经存在且会绿 ⇒ 你要**先证明它有牙**：临时把 `equip_index` 改名 ⇒ 它必须红（这就是"去掉什么它才红"）。

- [ ] **Step 3: 跑它，确认红**

Run: 你选的那条 ⇒ 改前（反射版本）**(a) 必红**；(b) 应在改名变异下红（复原）。把输出原文写进报告。

- [ ] **Step 4: 改**

把字符串访问换成类型化访问：变量标上真类型（或 `class_name` 补上）、字段直取、方法直调。★ **行为必须逐字段相同**（尤其 `held[i]["mag"]` 那段的边界：`mini(held.size(), mags.size())`、`>= 0` 的下标守卫都要原样保留）。
★ `mag_ammo` 若通过 `set` 写：按 Review Focus 2 判断是补 setter / 改公开 / 或**报告为真缺陷**。

- [ ] **Step 5: 跑它，确认绿 + 变异**

Run: 同 Step 3 ⇒ 绿；再跑 Step 1 里找到的**回溯功能探针** ⇒ 仍绿。
变异（档 2 至少一条）：把补齐的类型/方法里**任一处**故意改错名字（例：`equip_index` → `equip_indx`）
⇒ 必须**当场报错**（★ 2026-10-04 实测订正：原稿写"**编译期**就报错"**在本平台做不到** ——
Godot 4.7.1 对 `class_name` 脚本类型上的未知成员只按**警告级** `UNSAFE_*` 处理，`project.godot` 也没把
`unsafe_*` 升成错误 ⇒ 类型化写法拼错**同样是运行期** SCRIPT ERROR。真正买到的是：`get`/`set` 拼错
从"引擎一声不吭"变成"**当场点名成员 + 文件:行号**"；`call` 拼错报得更准。★ 这是控制器 brief 的第 11 次
写错；后续任务**不要**再照"编译期"这个口径写报告）；复原。

- [ ] **Step 6: 提交**

```bash
git add scenes/player/player.gd <被反射访问的类文件>
git commit -m "refactor(player): 回溯路径去掉武器域的字符串反射(改类型化访问 ⇒ 拼错名字编译期就红);行为逐字段不变"
```

---

### Task 2: 武器不再兜底读全局输入（audit §2.6）

**Files:**
- Modify: `scenes/weapons/weapon_base.gd`（`:220-233` 一带三个查询函数）
- Modify: 依赖兜底的地方（**仅当** Review Focus 4 判定"那些调用方该自己提供注入"时）

**Interfaces:**
- Consumes: 现状 —— 三个查询函数各写 `if player != null and player.has_method("is_attack_*"): return player.is_attack_*()`，否则 `return Input.is_action_*("attack")`；注释自陈"本地/冒烟无该方法时回退真实 Input"。
- Produces: 三个查询**只**读注入输入；没有注入时**响亮失败**（`push_error` + 返回 `false`），而不是偷偷读全局。

- [ ] **Step 1: 数清与定位**

Run: `grep -rn "Input.is_action" scenes/ | grep -v "^scenes/player/" | head -20`（**全仓**这类兜底到底几处）
Run: `grep -rn "is_attack_pressed\|is_attack_just_pressed\|is_attack_just_released" --include=*.gd . | head -20`（生产者与消费者）
Run: `grep -rn "WeaponBase\|\.equip(" tests/ scenes/ | head -20`（谁在构造/持有武器 —— 特别是**有没有不提供 `is_attack_*` 的宿主**）
★ 三条输出写进报告，并回答 Review Focus 3/4。

- [ ] **Step 2: 写"能红"的守卫（先写成红的）**

(a) 形状守卫：`grep -c 'Input.is_action' scenes/weapons/weapon_base.gd` ⇒ **0**；
(b) 行为守卫：跑武器相关冒烟/探针（Step 1 里 `grep` 出名字），确认开火判定不变（★ 若某探针**本来**依赖兜底 ⇒ 它会在这一步红 ⇒ 按 Review Focus 4 处置，并在报告里点名）。

- [ ] **Step 3: 跑它，确认红** ⇒ (a) 改前必红。

- [ ] **Step 4: 实现**

三个函数改成：`if player == null or not player.has_method("is_attack_*"): push_error("<谁> 没有注入输入接口 —— 武器禁止读全局 Input"); return false`，否则返回注入值。
★ 若 Step 1 发现**生产路径**真有不提供接口的宿主 ⇒ **停下报告**，改为在 `registered-debt.md` 登记该边界（不要为了绿而保留兜底）。
★ 顺手：三处重复的 `has_method` 判断可收成一个私有 helper（`_injected_input_available()`），但**别**把行为改成"缺方法就静默 false"而不报错。

- [ ] **Step 5: 跑它，确认绿 + 变异**

变异：把 `push_error` 那支改成 `return Input.is_action_pressed("attack")`（即恢复兜底）⇒ 形状守卫 (a) 必红；复原。

- [ ] **Step 6: 提交**

```bash
git add scenes/weapons/weapon_base.gd <必要时其它文件>
git commit -m "refactor(weapons): 去掉三处 Input.is_action_* 兜底(武器只读注入输入,缺接口就 push_error 而不是偷读全局)"
```

---

### Task 3: 同族反射的**生产端**（单机）—— `world_rewind.gd` + `swim_component.gd`

★ **来源**：Task 1 的定位发现"审计 §2.5 只清了**消费端**"。本任务清单机的**生产端**。

**Files:**
- Modify: `core/sim/world_rewind.gd`（`:98-114` 一带 —— 先 `grep` 复核）
- Modify: `scenes/player/swim_component.gd`（`:31` —— 先 `grep` 复核），**必要时**给类补 `class_name`

**Interfaces:**
- Consumes: `world_rewind.gd:98-103` 的注释**自己记着这族反射引发的真事故** —— `_current_slot` 改名成
  `_current_type` 之后 `get` 返回 null ⇒ **快照值静默恒为 0**（不报错、不中断）；`:104-114` 是同一族。
- Produces: 类型化访问；★ `swim_component.gd:31` 若要类型化得**给 player 根加 `class_name`** ⇒ 那是**动类结构**，**先报告再动**。

- [ ] **Step 1: 定位** —— `grep -n 'get("\|set("\|call("' core/sim/world_rewind.gd scenes/player/swim_component.gd` + 弄清每个成员属主与有没有 `class_name`
- [ ] **Step 2: 写"能红"的守卫** —— **优先**扩既有单机回溯探针（`rewind_probe` 已覆盖录制/位置/HP/怪复活/精英/免疫/恢复/磁带钟/二次回溯），补一条"**生产端的快照值非 0 / 逐字段等于真值**"的断言（★ 这正是当年那次事故的形态）；形状守卫（那两文件的字符串反射计数 **0**）作副判据
- [ ] **Step 3: 先红** → **Step 4: 类型化** → **Step 5: 绿 + 变异** → **Step 6: 提交**
★ 覆盖上限：`swim_component.gd` 那处若要给根加 `class_name`，**先报告**（动类结构的爆炸半径不同）。

---

### Task 4: 同族反射的 **PvP 生产端 + 写回端**（★ 档 3）

**Files:**
- Modify: `server/match/match_host.gd`（`:402-413` / `:455-465` —— 先 `grep` 复核）

★ **档 3**（「回滚与快照」在档位表里是承重面）⇒ 逐条变异 + **真链路跑批** + **逐任务评审**。

- [ ] **Step 1: 定位**（同上，并弄清这两段的**读写方向**：谁是生产、谁是写回）
- [ ] **Step 2: 写"能红"的守卫** —— 优先用既有 PvP 探针扩一条"快照字段**逐字段**等于真值"（★ 先证明它有牙：把某个成员名拼错 ⇒ 必红）
- [ ] **Step 3: 先红** → **Step 4: 类型化** → **Step 5: 绿 + 逐条变异**
- [ ] **Step 6: 真链路**（★ 先列测试请用户认领；`lobby_alive` 检查；前后 `tasklist` 空；收尾 `kill_port_range 7800 8300`；同配置跑两次再下时序结论）
- [ ] **Step 7: 提交**

---

### Task 5: 两处**实测的**回溯保真缺陷（★ 档 3；来源 = Task 1 的实测）

★ **两处都是既有缺陷、不是 Task 1 引入的**；Task 1 逐位未改、只报告。

**Files:**
- Modify: `scenes/player/player.gd`（`_equip_index` 一带 —— 先 `grep` 复核）
- Modify（必要时）: `scenes/weapons/weapon_component.gd`

**Interfaces:**
- Consumes（实测原文）：
  - **A 切枪帧**：`_equip_index` 用 `call_deferred` 入树 + 先置 `pending_mag`（条目值）⇒ 回溯写下的
    `live2.mag_ammo = wlive` 被 `_ready` 冲掉（仪器：切枪帧 mag=**9** → 入树后 **4** → 下一帧 **9**）。
  - **B 走掉那把**：`_equip_index` 会把**走掉那把**的实弹出膛值写回条目，冲掉刚回溯好的快照值
    （实测 `wmags=[11,1]` / `widx=1` ⇒ `held[0]=3` 而非 **11**）。
- Produces: 回溯后**弹量与快照逐字段一致**（含切枪帧与跨武器两种情形）。

- [ ] **Step 1: 把这两条写成断言**（在 `rewind_weapon_probe` 里；若现有 28 条功能断言已覆盖这两种情形却仍绿，说明它们没测到点上 ⇒ 报告）
- [ ] **Step 2: 跑出红**（把两组实测数字变成断言）
- [ ] **Step 3: 修** —— 候选：走 `WeaponComponent.apply_mag` 而不是裸写字段 / 调整语句序 / 让 `_ready` 不覆盖已回溯的值。★ **修法会改行为** ⇒ 必须写清"新行为是什么、为什么更好"，且 `rewind_weapon_probe` 的**旧断言**要继续绿（若旧断言钉的正是**错行为**，改它并说明理由）
- [ ] **Step 4: 绿 + 逐条变异**
- [ ] **Step 5: 真链路**（档 3）+ **逐任务评审**
- [ ] **Step 6: 把 `registered-debt.md` §六 那两条从"未修"改口为"已修"**（附提交号）

---

## 本计划**不含**

- **§2.2/§2.3/§2.4（协议/权威：轴无界、队列无上限、`@rpc` 无 channel）** —— Plan A（其中 2.4 单独一份）。
- **§2.1 / §2.9 / §2.10 / §2.11（工具与流程）** —— Plan C。
- **§2.7 / §2.8** —— 已判"记录而不修改"（`registered-debt.md` §七）。
- **`scenes/player/` 里其它形式的类型松散**（例：泛型容器里的 `Dictionary` 取字段）—— 本计划只收 §2.5 点名的那一段**反射**；别扩大战线。
