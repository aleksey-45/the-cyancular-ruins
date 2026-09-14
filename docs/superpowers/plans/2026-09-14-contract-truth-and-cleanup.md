# 契约对齐与清理批次实施计划（H2 / H4 / M4a / M4b / M6 / M7 / M21）

> ## ✅ 已执行完毕（2026-09-14，分支 `cleanup/contract-truth-2026-09-14`，12 笔提交）
>
> 7 个 Task 全部落地。执行期间有 4 处**偏离计划**，照实登记（下文的 Expected / 行号是撰写时的快照，未回改）：
> 1. **计划 Task 1 写错了一条事实**：计划里把「角色色相」归入「本机显示项、不上发」——实际它**经服务器中转**（随 `player_options` 上发 → `server_main.gd:313 _claim_hues()` 按 role 汇总 → `match_sync` 的 `hues` 回下发）。已按核实结果改写注释，未照抄计划。
> 2. **计划 Task 2 的 Step 4 是占位**（「按 Step 2 的同一段代码」）——违反「不给占位符」，执行时已把三段代码逐字回填进文档。
> 3. **计划 Task 4 Step 2 的 Expected 写错**：预测 `FAIL(8 条)`，实测 `FAIL(4 条)`。原因是 `AIInputSource` 把 `is_action_pressed` / `is_action_just_released` / `is_attack_just_released` / `get_weapon_slot_pressed` 实现成**常量**，那 4 条断言不具鉴别力；具鉴别力的恰好是另外 4 条。红→绿闭环仍成立。
> 4. **计划漏了三处外部消费者**（`server_main.gd:131-132` 的 `_worker_port_span_text`、`royale_lobby.gd:369-370` 的同款文案、`CLAUDE.md:134`），且**计划明确排在本批次之外的 M1 被提前修掉**——因为 Task 7 的改名让 `room_sweep_smoke` 的收口门失明，修好门后它立刻咬出 M1（详见 `6a5abfd` 的提交信息）。
>
> **本批次额外产出**：worker 端口范围文档漂移（`7800~7999` → `7800~8299`，4 处）+ `start_server.bat` 的 `findstr` 杀僵尸模式只覆盖 78xx/79xx（已在注释里登记为待修缺口）。
>
> ⚠ **数字口径**：本计划正文章节里引用的「N 行」是**函数跨度**（含注释与空行），在本仓这种高注释密度下虚高 30~40%。阶段 5 已于 2026-09-14 按**净代码行**重排并逐条给出更正后的数字（见该节顶部）。
>
> **验收状态**：7 个 `-s` 冒烟 + 13 个场景探针（含 `royale_bound`（B1）/ `royale_c2`）+ 5 个多进程 `.sh` 全绿；两处探针修正均做了反证（注入违规→咬红，还原→转绿）。**未跑**（留待用户）：需真实渲染的 `menu_autotest` / `kh_l3|4_visual_probe` / `combat_hud_visual_probe`，以及 `royale_probe` / `royale_soak_probe` / `brawl_rollback_probe` / `snapshot_size_probe` / `perf_probe`。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「文档/注释/契约承诺了某件事、实现没做到（或反过来）」这一类可维护性负担清干净，并把 `server/room_manager.gd` 的两块**无 Node 依赖**的职责抽成独立文件。全程**不改变任何运行时行为**（Task 4 除外——它修的是一个真实失效的契约，行为面在 Task 4 内单独说明）。

**Architecture:** 两类动作——(a) 改说辞：让注释/文档与代码事实一致；(b) 纯搬迁：把 `room_manager.gd` 里不依赖 `multiplayer`/`get_tree()` 的两块（建局引导、worker 进程与端口池）移到独立文件，`RoomManager` 保留 RPC 入口与编排。**不做**房间注册表的拆分（它依赖 `multiplayer` 与 autoload 信号接线，见「本计划明确不做的事」）。

**Tech Stack:** Godot 4.7.1 标准版（非 mono），GDScript，无单测框架（冒烟 = `extends SceneTree` 的 `-s` 脚本 + 场景模式探针）。

## Global Constraints

- **Godot 可执行文件绝对路径**（不在 PATH）：
  `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **新建带 `class_name` 的文件后必须先刷全局类缓存**，否则引用处 Parse Error：
  `..." --headless --path . --import`
- **探针判据必须是 grep 文本**：`-s` 冒烟看 `SMOKE OK` / `AI INPUT SMOKE: OK`；场景探针看 `ALL-OK`。**不能只看退出码**（中途报错时 `--quit-after` 仍 exit 0）。
- **测试由用户自己跑。** 本计划里的验证命令是给实施者自查用的；每个 Task 末尾不要自动代跑整套冒烟，把「待用户验收」的命令列出来即可。
- **行号是撰写时的快照。** 每个 Task 的 Step 都给了 `grep` 锚点；若行号对不上，**以锚点内容为准**，别按行号硬改。
- **不要动**：`NetBus`/`NetBusExt` 的 RPC 方法表与信号清单（原版服务端逐字节兼容面）、`server/match_host.gd` 的 C2 四条（`note_post_step`/`reconcile`/输入 FIFO 消费/快照 `c2`）、`RoyaleHost._init` 顺序与 `_spawned_once` 闩锁、`kh_l*_probe` 的断言体（除本计划点名的两处）。
- **本批次是纯搬迁 + 改说辞**：Task 6/7 里任何「顺手修 bug」的念头都要收住——`M1`（失败分支不清 `worker_port`）**明确不在本批次**，见「后续问题排序」。
- 每个 Task 独立提交。提交信息用中文，与仓库既有风格一致。

---

## 文件结构（本批次新增 / 修改清单）

| 文件 | 动作 | 职责 |
|---|---|---|
| `core/input_source.gd` | 修改 | 冻结（`frozen`）收归本类的公开读口；新增 8 个 `_*_raw()` 覆写钩子 |
| `core/network_input_source.gd` | 修改 | 8 个覆写改名为 `_*_raw()`，不再各自处理 `frozen` |
| `core/ai_input_source.gd` | 修改 | 同上 |
| `tests/soak_bot_input.gd` | 修改 | 同上；顺带删掉手抄的 `frozen` 短路 |
| `tests/ai_input_source_smoke.gd` | 修改 | **新增**冻结契约回归断言（本批次唯一的「新失败测试」） |
| `core/pvp_session.gd` | 修改 | 删 4 个无读者字段；标注权威来源 |
| `core/run_options.gd` | 修改 | 标注权威来源（不删） |
| `scenes/matchmaking.gd` | 修改 | 修两处与事实相反的注释；删 1 行死赋值 |
| `scenes/main_menu.gd` | 修改 | 删 1 行死赋值 |
| `scenes/royale_lobby.gd` | 修改 | 删 1 行死赋值 |
| `scenes/pvp_client.gd` | 修改 | 3 个 handler 改名 `_apply_*`；删 1 行死赋值 |
| `scenes/royale_game.gd` | 修改 | 3 个 handler 改名 `_apply_*`；删 1 行死赋值 |
| `README.md` | 修改 | 目录段 + 切枪槽位 |
| `CLAUDE.md` | 修改 | 寻路函数名 + 加新敌人步骤 |
| `export_presets.cfg` | 修改 | 删陈旧的 `DevTools/*` 排除项 |
| `tests/kh_l1_probe.gd` | 修改 | 删对已删字段的 reset 断言（按仓内惯例：改探针认新入口） |
| `tests/royale_bound_watcher.gd` | 修改 | 同上（删冗余见证断言，保留权威那条） |
| `tests/royale_soak_probe.gd` | 修改 | 删 1 行死赋值 |
| **`server/match_bootstrap.gd`** | **新建** | worker 进程内的建局引导（`start_on` + `PVP_MAP`） |
| **`server/worker_launcher.gd`** | **新建** | worker 子进程与端口池（分配/释放/拉起/杀/日志路径） |
| `server/room_manager.gd` | 修改 | 上述两块移出；保留 RPC 入口、房间注册表、拆除收口、清扫 |
| `server/server_main.gd` | 修改 | 改调 `MatchBootstrap.start_on` |

---

### Task 1: M6 — 修 `matchmaking.gd` 两处与事实相反的注释

**Files:**
- Modify: `scenes/matchmaking.gd:118-127`（`_build_options_panel` 顶部 ⚠ 块）
- Modify: `scenes/matchmaking.gd:476-478`（`_claim_role_worker` 内 ⚠ 行）

**Interfaces:**
- Consumes: 无
- Produces: 无（纯注释改动）

**背景（已逐行核实）：** 注释写「⚠ 本面板的选项**暂时不生效**…… `_claim_role_worker` 里照发的 `player_options` 目前被服务器**静默丢弃**（main 的 server/ 对该 RPC 零消费者）。即：现在勾选不会改变对局行为。」

**事实恰好相反**，链路是通的：

```
scenes/matchmaking.gd  NetBusExt.rpc_id(1,"player_options",{…})   ← 本文件 :479
  → core/net_bus_ext.gd:17   player_options()  emit player_options_received
  → server/server_main.gd:170  connect(_on_player_options)
  → server/server_main.gd:206  _on_player_options → 归档进 _claim_opts
  → server/server_main.gd:300  RoomManager.start_match_on(_claims, _MAP, _claim_opts.get(1, {}), …)
  → server/match_host.gd:60    _round_full_heal = bool(options.get("round_full_heal", false))
  → server/match_host.gd:61    var raw_disabled: Array = options.get("disabled_weapons", [])
  → server/match_host.gd:126   set_enabled_slots(...)
  → server/match_host.gd:579   回合回满血
  同一份载荷还在 server/server_main.gd:237 作为 match_sync_data.options 回给客户端（**回读副本**）
```

**这条要单列的理由：** 它不会让代码出错，它会让**后来人按错信息动手**——读到「面板是死 UI」的结论，要么删掉面板，要么「再补一次接线」，而那正好造出**第二条投递路径**，就是这个项目刚为「双投递」付过代价（自检 B2）的那个形状。

- [ ] **Step 1: 确认两处锚点**

```bash
grep -n "暂时不生效\|静默丢弃\|消费方在 L5/L6" scenes/matchmaking.gd
```

Expected: 恰好 2 组命中（`:120` 附近的 `暂时不生效` 与 `:127`、`静默丢弃`，以及 `:477` 的 `静默丢弃`/`消费方在 L5/L6`）。**若命中数不是 4 个词组（暂不生效 / 静默丢弃 ×2 / 消费方在 L5/L6），停止本 Task** 并记录到计划末尾的「未预期发现」。

- [ ] **Step 2: 替换 `_build_options_panel` 顶部的 ⚠ 块**

把从 `# ── 对战选项面板(右侧)──` 下一行起、到 `func _build_options_panel() -> void:` 上一行止的整块 ⚠ 注释（原文 9 行）替换为：

```gdscript
# ── 对战选项面板(右侧)──
# 本面板的选项**已生效**，链路（2026-09-14 核实，勿再照旧注释改成"待接线"）：
#   勾选写进 Settings 并存档 → _claim_role_worker 随 player_options 上发 →
#   server_main._on_player_options 归档 → RoomManager.start_match_on 取 **role1(房主)** 那份 →
#   MatchHost 读 round_full_heal / disabled_weapons。
#   ★ 服务器权威规则项以**房主(role1)**的选项为准；非房主勾了也不生效（这是设计，不是缺陷）。
#   ★ 角色色相(hue)与"显示敌方血条/小地图/拖尾"三项是**本机显示项**，只读 Settings，不上发。
# 入口三处：server_main.gd:206(归档) / :300(取 role1) / match_host.gd:60-61(消费)。
func _build_options_panel() -> void:
```

（`_build_options_panel` 的函数体一行不动。）

- [ ] **Step 3: 替换 `_claim_role_worker` 内的 ⚠ 行**

原文三行：

```gdscript
	# ⚠ 本包目前被服务器静默丢弃(server/ 对 player_options 零消费者)→ 选项不生效,
	#   消费方在 L5/L6;见 _build_options_panel 顶部注释。
	NetBusExt.rpc_id(1, "player_options", {
```

改为：

```gdscript
	# 本包是**本局权威规则项**的唯一来源(服务器按 role1 那份生效);链路见 _build_options_panel 顶部注释。
	NetBusExt.rpc_id(1, "player_options", {
```

- [ ] **Step 4: 确认无残留**

```bash
grep -n "暂时不生效\|静默丢弃\|消费方在 L5/L6" scenes/matchmaking.gd
```

Expected: 无输出。

- [ ] **Step 5: 启动自检**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，输出无 `SCRIPT ERROR` / `Parse Error`。

- [ ] **Step 6: 提交**

```bash
git add scenes/matchmaking.gd
git commit -m "docs(matchmaking): 修「选项暂时不生效/被服务器静默丢弃」两处与事实相反的注释——链路实为 server_main.gd:206 归档 → :300 取 role1 → match_host.gd:60-61 消费;留着会诱人再补一次接线,造出第二条投递路径(自检 B2 的形状)"
```

---

### Task 2: M7 — 三个载荷 handler 改名 `_apply_*` 并修注释

**Files:**
- Modify: `scenes/pvp_client.gd`（6 处：3 个调用点 + 3 个定义）
- Modify: `scenes/royale_game.gd`（6 处：同上）

**Interfaces:**
- Consumes: 无
- Produces: `_apply_peer_names(names: Dictionary) -> void`、`_apply_peer_hues(hues: Dictionary) -> void`、`_apply_match_options(opts: Dictionary) -> void`（两个客户端各一份）

**背景（已逐行核实）：**
- `NetBus.peer_info`（`core/net_bus.gd:206`）、`NetBusExt.match_options`（`core/net_bus_ext.gd:22`）、`NetBusExt.peer_hues`（`core/net_bus_ext.gd:27`）三个 `@rpc` 入口**全仓零调用**（生产与测试都没有）。
- 对应的 `NetBus.local_peer_info`、`NetBusExt.local_peer_hues`、`NetBusExt.local_match_options` 三个信号在**生产侧零 `connect`**（只有 `tests/royale_bound_watcher.gd:56-60` 与 `.superpowers/` 脚手架里连）。
- 所以这三个 handler 的**唯一真实入口**是 `_on_match_sync`（`pvp_client.gd:143/146/149`、`royale_game.gd:122/125/128`）。
- 但它们的注释写的是「worker 开局广播 peer_info」「扩展 peer_hues 下发」——指向一条已不存在的推送路径。**风险与 Task 1 同型**：新人按注释找不到 `connect`，会判定「漏接线」并补上 → 载荷走两条路。

**动手前先确认 Task 1 已完成**（Task 1 改的是 `matchmaking.gd`，与本 Task 无重叠；此处仅提醒两个 Task 都属「改说辞」，一起验收更方便）。

- [ ] **Step 1: 确认锚点**

```bash
grep -n "_on_peer_info\|_on_peer_hues\|_on_match_options" scenes/pvp_client.gd scenes/royale_game.gd
```

Expected: 每个文件 6 处（3 调用 + 3 定义），共 12 处。`pvp_client.gd` 的行号应接近 `143/146/149`（调用）与 `492/508/517`（定义）；`royale_game.gd` 接近 `122/125/128` 与 `462/469/501`。

- [ ] **Step 2: `pvp_client.gd` — 3 个定义改名**

把

```gdscript
func _on_peer_hues(hues: Dictionary) -> void:
```
→
```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBusExt.local_peer_hues —— 那条**推送**路径在本项目已不存在(worker 不再广播),
#   连上去会让本载荷走两条路(推送 + 拉取),正是自检 B2 那个形状。
func _apply_peer_hues(hues: Dictionary) -> void:
```

把

```gdscript
func _on_match_options(opts: Dictionary) -> void:
```
→
```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBusExt.local_match_options —— 同 _apply_peer_hues 的告警。
func _apply_match_options(opts: Dictionary) -> void:
```

把

```gdscript
func _on_peer_info(names: Dictionary) -> void:
```
→
```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBus.local_peer_info —— 同 _apply_peer_hues 的告警。
func _apply_peer_names(names: Dictionary) -> void:
```

- [ ] **Step 3: `pvp_client.gd` — 3 个调用点改名**

在 `_on_match_sync` 内（`grep -n "_on_peer_info(names)" scenes/pvp_client.gd` 定位）：

```gdscript
		_on_peer_info(names)
```
→
```gdscript
		_apply_peer_names(names)
```

```gdscript
		_on_peer_hues(hues)
```
→
```gdscript
		_apply_peer_hues(hues)
```

```gdscript
		_on_match_options(opts)
```
→
```gdscript
		_apply_match_options(opts)
```

- [ ] **Step 4: `royale_game.gd` — 同样 6 处（代码照抄如下，不要回看 Step 2/3）**

三个定义改成（`royale_game.gd` 里这三个函数的签名与 `pvp_client.gd` 完全相同）：

```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBusExt.local_peer_hues —— 那条**推送**路径在本项目已不存在(worker 不再广播),
#   连上去会让本载荷走两条路(推送 + 拉取),正是自检 B2 那个形状。
func _apply_peer_hues(hues: Dictionary) -> void:
```

```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBusExt.local_match_options —— 同 _apply_peer_hues 的告警。
func _apply_match_options(opts: Dictionary) -> void:
```

```gdscript
# 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取)。
# ★ 不要连回 NetBus.local_peer_info —— 同 _apply_peer_hues 的告警。
func _apply_peer_names(names: Dictionary) -> void:
```

三个调用点（都在 `_on_match_sync` 内）：

```gdscript
		_on_peer_info(names)
```
→
```gdscript
		_apply_peer_names(names)
```

```gdscript
		_on_peer_hues(hues)
```
→
```gdscript
		_apply_peer_hues(hues)
```

```gdscript
		_on_match_options(opts)
```
→
```gdscript
		_apply_match_options(opts)
```

- [ ] **Step 5: 确认改名完成且旧名无残留**

```bash
grep -rn "_on_peer_info\|_on_peer_hues\|_on_match_options" scenes/ server/ core/ ui/
```

Expected: 无输出。

```bash
grep -rn "_apply_peer_names\|_apply_peer_hues\|_apply_match_options" scenes/
```

Expected: 每个名字 2 处（`pvp_client.gd` 1 调用 + 1 定义，`royale_game.gd` 同），共 12 处。

- [ ] **Step 6: 确认没有把死信号连回来**

```bash
grep -rn "local_peer_info.connect\|local_peer_hues.connect\|local_match_options.connect" scenes/
```

Expected: 无输出（只有 `tests/` 里那两处 connect 是探针自用的）。

- [ ] **Step 7: 启动自检**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，输出无 `SCRIPT ERROR` / `Parse Error`。

- [ ] **Step 8: 提交**

```bash
git add scenes/pvp_client.gd scenes/royale_game.gd
git commit -m "refactor(pvp): 开局三载荷 handler 改名 _apply_* 并标注唯一入口=_on_match_sync——原名/注释指向已不存在的推送路径(三个 @rpc 与三个 local_* 信号全仓已无生产者/消费者),照注释补 connect 会造出第二条投递路径"
```

---

### Task 3: M21 — 修 5 处文档漂移

**Files:**
- Modify: `README.md:87-93`（目录段）
- Modify: `README.md:19`（切枪槽位）
- Modify: `CLAUDE.md:42`（寻路函数名）
- Modify: `CLAUDE.md:56`（加新敌人步骤）
- Modify: `export_presets.cfg:13,87`（陈旧排除项）

**Interfaces:**
- Consumes: 无
- Produces: 无（纯文档）

- [ ] **Step 1: `README.md` 目录段（替换 `README.md:87-93` 整个代码块内容）**

原文：

```
scenes/   场景(Godot 惯例 PascalCase 的 .tscn;脚本 snake_case)
core/  autoload + 静态工具(MazeGenerator/TileDefs/NetBus/Water…)
server/   服务端:大厅(server_main)+ 房间(RoomManager)+ 每局权威(MatchHost)
tests/    -s 冒烟/探针
editor/   浏览器地图编辑器(structure-editor.html + smoke.js)
maps/      .cyrm 文本地图
tools/    发布/控制台脚本(build_release.py、make_server_console.py)
```

改为：

```
scenes/   场景(页面与对局场景;脚本 snake_case,场景文件命名现状见 CLAUDE.md)
core/     autoload + 静态工具(MazeGenerator/TileDefs/NetBus/Water…)
server/   服务端:大厅(server_main)+ 房间(RoomManager)+ 每局权威(MatchHost)
ui/       跨场景 UI:UiFactory(唯一调色板/工厂)、单机 HUD、对局 HUD、暂停菜单
render/   后处理(post_process.gd + shaders/post_process.gdshader)
tests/    -s 冒烟/探针(分层见 tests/README.md)
level_editor/  浏览器地图编辑器(structure-editor.html + smoke.js + sync-*.js)
maps/     .cyrm 文本地图
data/     tile_defs.json / enemies.json(与编辑器共享的属性表与敌人注册表)
assets/   字体(含中文像素字体 unifont)与纹理
shaders/  post_process.gdshader
tools/    发布/控制台脚本(build_release.py、make_server_console.py)
```

**注意**：`editor/` 是整改前的旧目录名，实际目录是 `level_editor/`（`docs/naming-cleanup-plan.md` 那次改了 CLAUDE.md，漏了 README）。本步同时补齐之前整段漏列的 `ui/ render/ data/ assets/ shaders/`。

- [ ] **Step 2: `README.md:19` 切枪槽位**

原文：

```markdown
- `1`~`5` 切枪(手枪/步枪/重狙/霰弹/榴弹)
```

改为：

```markdown
- `1`~`6` 切枪(手枪/步枪/重狙 M82A1/霰弹 S686/榴弹发射器/激光枪)
```

（槽位注册表在 `scenes/player/weapon_component.gd:8-15` 的 `WEAPONS`；显示名同文件 `:18` 的 `DISPLAY_NAMES`——两处都是 1~6。）

- [ ] **Step 3: `CLAUDE.md:42` 寻路函数名**

原文（行首）：

```markdown
  - 寻路:`bfs_path` / `bfs_path_nearest` / `astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
```

改为：

```markdown
  - 寻路:`astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
```

（全文核过：`bfs_path` / `bfs_path_nearest` 在仓库里**零命中**，`core/maze_generator.gd` 只有 `astar_path_nearest`(`:410`)。）

- [ ] **Step 4: `CLAUDE.md:56` 加新敌人步骤**

原文：

```markdown
- **加新敌人** = 一个 .tscn + `EnemySpawner.TYPES` 加一行(键名 → 场景路径),spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。
```

改为：

```markdown
- **加新敌人** = 一个 .tscn + 在 **`data/enemies.json`** 的 `enemies` 数组加一条(`id`/`name`/`scene`/`color`;`EnemySpawner.TYPES` 是它的运行时加载结果,不手改) + 在 `scenes/effects/combat_feedback.gd:19` 的 `ENEMY_NAMES` 补一条中文显示名(键 = enemies.json 的 `name` 字段;**漏加会静默回落英文原名**,不报错)。spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。
- 编辑器侧的敌人注册表(`level_editor/structure-editor.html` 内嵌)由 `node level_editor/sync-enemies.js` 从 `data/enemies.json` 重新生成。
```

- [ ] **Step 5: `export_presets.cfg` 删陈旧排除项（两处，`:13` 与 `:87`）**

原文（两行相同）：

```
exclude_filter="*.md,DevTools/*,.superpowers/*"
```

改为：

```
exclude_filter="*.md,.superpowers/*"
```

（`DevTools/` 目录不存在；`.superpowers/` 要保留——它是 4.4 MB 的 agent 脚手架产物，必须排除出包。）

- [ ] **Step 6: 复核全仓文档路径**

```bash
grep -rn "editor/" README.md CLAUDE.md RELEASE.md | grep -v "level_editor/"
```

Expected: 无输出。

```bash
grep -n "DevTools" export_presets.cfg
```

Expected: 无输出。

```bash
grep -n "bfs_path" CLAUDE.md
```

Expected: 无输出。

- [ ] **Step 7: 提交**

```bash
git add README.md CLAUDE.md export_presets.cfg
git commit -m "docs: 修 5 处文档漂移——README 目录段仍写 editor/(实为 level_editor/)且漏列 ui/render/data/assets/shaders、切枪写 1~5(实有第 6 槽激光枪);CLAUDE.md 称有 bfs_path/bfs_path_nearest(实际只有 astar_path_nearest)、加新敌人写错注册表位置(实为 data/enemies.json 且漏了 ENEMY_NAMES);export_presets 的 DevTools/* 目录不存在"
```

---

### Task 4: H2 — `InputSource` 冻结契约下沉（含新增回归断言）

**Files:**
- Modify: `tests/ai_input_source_smoke.gd`（新增断言段落，Step 1）
- Modify: `core/input_source.gd`（整份重写）
- Modify: `core/network_input_source.gd:51-88`（8 个覆写改名）
- Modify: `core/ai_input_source.gd:16-42`（8 个覆写改名）
- Modify: `tests/soak_bot_input.gd:83-115`（8 个覆写改名 + 删手抄的 `frozen`）

**Interfaces:**
- Consumes: 无
- Produces（基类新的覆写钩子，**子类只许覆写这些**）：
  - `InputSource._axis_raw(neg: String, pos: String) -> float`
  - `InputSource._action_pressed_raw(action: String) -> bool`
  - `InputSource._action_just_pressed_raw(action: String) -> bool`
  - `InputSource._action_just_released_raw(action: String) -> bool`
  - `InputSource._attack_pressed_raw() -> bool`
  - `InputSource._attack_just_pressed_raw() -> bool`
  - `InputSource._attack_just_released_raw() -> bool`
  - `InputSource._weapon_slot_raw() -> int`

**背景（已逐行核实，这是本批次唯一改变行为的 Task）：**

`core/input_source.gd:8-11` 的类头注释承诺：*「frozen:PvP COUNTDOWN/局间冻结。置 true 后一切输入读口返回中性值」*。实现方式是**在公开读口里** `if frozen: return <中性值>`（`:14/19/24/29/44/49/54/60` 共 8 处）。

但全仓 `grep -rn "frozen"` 在生产代码里**只有 `scenes/player/player.gd:132` 一处，而且是写**（`input_source.frozen = locked`），**没有任何一处读**——因为三个子类（`NetworkInputSource`、`AIInputSource`、`tests/soak_bot_input.gd`）**覆写了全部 9 个公开读口**，基类的短路整个被子类绕过。

于是 `set_controls_locked(true)` 对网络/AI 输入源是**静默空操作**。现在没炸纯靠两处旁路纪律：服务器另调 `NetworkInputSource.reset_state()`（`server/match_host.gd:174`）、AI 自己按 `RoundState.PLAYING` 收手。默认的 `InputSource.new()`（`player.gd:47`）走基类，**C2 客户端的本地玩家恰好是它**，所以 CLAUDE.md 里「客户端 `set_controls_locked` 连带冻结整个 input_source」这句在联机主链路上侥幸成立。

**行为面（本 Task 唯一的运行时差异，提交信息里必须写明）：**
1. `NetworkInputSource` / `AIInputSource` 在 `frozen == true` 时**现在真的返回中性值**了。当前生产路径下这两者在冻结期本来就没有有效输入（服务器清空缓冲 + `reset_state()`；AI 自查 `RoundState`），**故实际无可观测差异**——但契约从此是真的。
2. 冻结期子类的 `_*_raw()` **不再被调用**，因此不再有副作用：`AIInputSource._action_just_pressed_raw("up")` 不再吃掉 `_jump_edge`、`soak_bot_input._weapon_slot_raw()` 不再吃掉 `_slot`。**这是期望语义**（冻结不该改状态），但属行为变化。
3. `get_aim_dir_override()` **刻意不参与 frozen**（原样保留）：冻住的是移动/开火/切枪，武器仍要按注入方向摆枪。

- [ ] **Step 1: 先写会失败的断言（TDD）**

在 `tests/ai_input_source_smoke.gd` 里，紧跟现有的

```gdscript
	_check(not src.is_action_just_pressed("up"), "跳跃是**边沿**不是电平(第二次读为假)")
```

之后、`# 不逐条断言那些"在基类与覆写里都是同一个常量"的读口` 那段注释**之前**，插入：

```gdscript
	# ★ frozen 契约回归(2026-09-14):基类承诺「置 true 后一切输入读口返回中性值」,
	#   而三个子类覆写了全部公开读口 → 短路被子类绕过,set_controls_locked 对网络/AI 源
	#   是**静默空操作**。此断言把该契约钉死在**子类**身上(基类自己的实现无法证明子类听话)。
	#   口径来自 core/input_source.gd 的类头注释与 player.set_controls_locked 的调用点。
	src.aim = Vector2.UP
	src.axis = -1.0
	src.fire = true
	src.press_jump()
	src.frozen = true
	_check(is_zero_approx(src.get_axis("left", "right")), "frozen:get_axis 为 0")
	_check(not src.is_action_pressed("up"), "frozen:is_action_pressed 为 false")
	_check(not src.is_action_just_pressed("up"), "frozen:is_action_just_pressed 为 false")
	_check(not src.is_action_just_released("up"), "frozen:is_action_just_released 为 false")
	_check(not src.is_attack_pressed(), "frozen:is_attack_pressed 为 false")
	_check(not src.is_attack_just_pressed(), "frozen:is_attack_just_pressed 为 false")
	_check(not src.is_attack_just_released(), "frozen:is_attack_just_released 为 false")
	_check(src.get_weapon_slot_pressed() == 0, "frozen:get_weapon_slot_pressed 为 0")
	# 瞄准是**刻意**不冻的:冻结期武器仍要按注入方向摆枪
	_check(src.get_aim_dir_override() == Vector2.UP, "frozen:瞄准刻意不冻(武器仍按注入方向摆枪)")
	src.frozen = false
```

- [ ] **Step 2: 跑它，确认它**失败**（这是本 Task 的核心证据）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/ai_input_source_smoke.gd
```

Expected: **FAIL**，且失败项恰好是上面 8 条 `frozen:*`（`get_axis`/`is_action_pressed`/`just_pressed`/`just_released`/`is_attack_pressed`/`just_pressed`/`just_released`/`weapon_slot`），末行 `AI INPUT SMOKE: FAIL(8 条)`。瞄准那条应**通过**（它本来就没被 frozen 保护，两种实现下行为一致）。

**若 8 条 `frozen:*` 全部通过**：说明有人已经修过这个契约，停止本 Task，把 `core/input_source.gd` 的现状抄进计划末尾的「未预期发现」。

- [ ] **Step 3: 整份重写 `core/input_source.gd`**

```gdscript
class_name InputSource
extends RefCounted

# 玩家输入抽象:基类默认行为 = 委托真实 Input(即本地玩家现状)。
# AIInputSource / NetworkInputSource / tests/soak_bot_input.gd 覆写 **_*_raw() 钩子**。
#
# ★ frozen 的归属(2026-09-14 修):
#   本类此前把 frozen 短路写在**公开读口**里,而三个子类各自覆写了全部公开读口 →
#   短路被子类整个绕过,`player.set_controls_locked(true)` 对它们是**静默空操作**。
#   现在冻结收在本类的公开读口,子类只覆写不碰 frozen 的 `_*_raw()` 钩子 —— 契约从此无法绕过。
#   历史代价(记下来别再犯):客户端 COUNTDOWN 冻结曾靠"客户端恰好用默认 InputSource"侥幸成立;
#   服务器靠 MatchHost 另调 NetworkInputSource.reset_state()、AI 靠自己查 RoundState 兜住。
#
# frozen:PvP COUNTDOWN/局间冻结。置 true 后一切输入读口返回中性值(轴 0、无按键/边沿/切枪),
# 玩家像服务器不喂输入那样静止 —— C2 本地预测下倒计时里不自走(服务器权威冻结,客户端预测必须同款冻结,
# 否则预测移动、服务器不消费 → PLAYING 起 ack 跳变 → 大 rollback)。
# ★ 冻结期**不调用**子类的 _*_raw():冻结不该改子类状态(边沿不被消费、切枪槽位不被取走)。
# ★ 瞄准读口 get_aim_dir_override() 刻意**不**参与冻结:武器仍要按注入方向摆枪。
var frozen := false


# ── 公开读口:frozen 一律在此短路,子类**不得覆写这些**(覆写了就等于绕开冻结)──

func get_axis(neg: String, pos: String) -> float:
	if frozen:
		return 0.0
	return _axis_raw(neg, pos)

func is_action_pressed(action: String) -> bool:
	return not frozen and _action_pressed_raw(action)

func is_action_just_pressed(action: String) -> bool:
	return not frozen and _action_just_pressed_raw(action)

func is_action_just_released(action: String) -> bool:
	return not frozen and _action_just_released_raw(action)

func is_attack_pressed() -> bool:
	return not frozen and _attack_pressed_raw()

func is_attack_just_pressed() -> bool:
	return not frozen and _attack_just_pressed_raw()

func is_attack_just_released() -> bool:
	return not frozen and _attack_just_released_raw()

func get_weapon_slot_pressed() -> int:
	if frozen:
		return 0
	return _weapon_slot_raw()


# ── 覆写钩子:子类只改这里。基类默认 = 真实 Input(本地玩家)──

func _axis_raw(neg: String, pos: String) -> float:
	return Input.get_axis(neg, pos)

func _action_pressed_raw(action: String) -> bool:
	return Input.is_action_pressed(action)

func _action_just_pressed_raw(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func _action_just_released_raw(action: String) -> bool:
	return Input.is_action_just_released(action)

func _attack_pressed_raw() -> bool:
	return Input.is_action_pressed("attack")

func _attack_just_pressed_raw() -> bool:
	return Input.is_action_just_pressed("attack")

func _attack_just_released_raw() -> bool:
	return Input.is_action_just_released("attack")

func _weapon_slot_raw() -> int:
	for i in range(1, 7):
		if Input.is_action_just_pressed(str(i)):
			return i
	return 0


# 瞄准覆盖:本地返回 ZERO → 武器落回鼠标计算;网络驱动的玩家返回注入的瞄准方向。
# ★ 不参与 frozen(见类头)。
func get_aim_dir_override() -> Vector2:
	return Vector2.ZERO

# 该输入源是否网络注入(NetworkInputSource=true)。网络驱动玩家的武器瞄准**永不读 OS 鼠标**:
# 注入方向为 ZERO 时用玩家朝向兜底(见 weapon_base._aim_world_dir)。
# ★ 不参与 frozen。
func is_network_driven() -> bool:
	return false
```

- [ ] **Step 4: `core/network_input_source.gd` — 8 个覆写改名**

把 `:51-88` 的 8 个函数定义按左列改右列（**函数体一行不动**，只改函数名；各自的 `# 垂直轴由 held 位推导…` 注释块保持在 `_axis_raw` 上方）：

| 原 | 新 |
|---|---|
| `func get_axis(neg: String, pos: String) -> float:` | `func _axis_raw(neg: String, pos: String) -> float:` |
| `func is_action_pressed(action: String) -> bool:` | `func _action_pressed_raw(action: String) -> bool:` |
| `func is_action_just_pressed(action: String) -> bool:` | `func _action_just_pressed_raw(action: String) -> bool:` |
| `func is_action_just_released(action: String) -> bool:` | `func _action_just_released_raw(action: String) -> bool:` |
| `func is_attack_pressed() -> bool:` | `func _attack_pressed_raw() -> bool:` |
| `func is_attack_just_pressed() -> bool:` | `func _attack_just_pressed_raw() -> bool:` |
| `func is_attack_just_released() -> bool:` | `func _attack_just_released_raw() -> bool:` |
| `func get_weapon_slot_pressed() -> int:` | `func _weapon_slot_raw() -> int:` |

并在 `:51` 上方（`reset_state()` 之后）插入一行分节注释：

```gdscript
# ── 覆写钩子(公开读口由基类持有并对 frozen 短路;本类不再各自处理冻结)──
```

`get_aim_dir_override()`(`:90`)、`is_network_driven()`(`:94`)、`static func _bit()`(`:97`) **不改名、不动**。

- [ ] **Step 5: `core/ai_input_source.gd` — 8 个覆写改名**

按 Step 4 的**同一张对照表**改 `:16-42` 的 8 个（`func get_axis(neg: String, _pos: String) -> float:` 的形参名 `_pos` 保持原样）。同样在 `get_axis` 上方插入 Step 4 那句分节注释。`get_aim_dir_override()`(`:44`)、`is_network_driven()`(`:57`) **不动**（后者的长注释也一行不动）。

- [ ] **Step 6: `tests/soak_bot_input.gd` — 8 个覆写改名 + 删手抄的 frozen**

`:83-115` 的 8 个函数改成钩子名并**去掉各自的 `frozen` 判断**（冻结现在由基类兜住）：

```gdscript
# ── 覆写钩子(公开读口由基类持有并对 frozen 短路,本类不再自己认 frozen)──
func _axis_raw(neg: String, _pos: String) -> float:
	if neg == "left":
		return axis
	# 垂直轴:climb/swim 走 get_axis("up","down")
	return (1.0 if bool(_held.get("down", false)) else 0.0) \
			- (1.0 if bool(_held.get("up", false)) else 0.0)

func _action_pressed_raw(action: String) -> bool:
	return bool(_held.get(action, false))

func _action_just_pressed_raw(action: String) -> bool:
	return bool(_pressed.get(action, false))

func _action_just_released_raw(action: String) -> bool:
	return bool(_released.get(action, false))

func _attack_pressed_raw() -> bool:
	return bool(_held.get("attack", false))

func _attack_just_pressed_raw() -> bool:
	return bool(_pressed.get("attack", false))

func _attack_just_released_raw() -> bool:
	return bool(_released.get("attack", false))

func _weapon_slot_raw() -> int:
	var s := _slot
	_slot = 0        # 读一次即清,与真实 Input 的"本轮刚按下"语义一致
	return s
```

`get_aim_dir_override()`(`:117`)、`is_network_driven()`(`:122`) **不动**。

**`step()`（`:32-39`）的 `if frozen:` 分支保留**——那是本类自己的「冻结期不推进脚本」逻辑（清 `_held`/`_prev_held`/边沿），与基类的读口短路是两件事，不要删。

同时把类头 `:9-11` 的注释改掉（它现在描述的是旧实现）：

```gdscript
# frozen:PvP 的 COUNTDOWN/结算冻结会置它(set_controls_locked)。基类把公开读口对 frozen 短路,
# 本类只覆写不碰 frozen 的 _*_raw() 钩子 → 无需自己认。下方 step() 里那个 `if frozen` 是**本类自己的**
# 「冻结期不推进脚本」逻辑(清 held/边沿),与基类短路无关,勿删。
```

- [ ] **Step 7: 确认没有子类再覆写公开读口**

```bash
grep -rn "func get_axis\|func is_action_pressed\|func is_action_just_pressed\|func is_action_just_released\|func is_attack_pressed\|func is_attack_just_pressed\|func is_attack_just_released\|func get_weapon_slot_pressed" core/ scenes/ server/ tests/
```

Expected: 只剩 `core/input_source.gd` 里那 8 个（基类公开读口）。**任何其他文件命中即失败**——那意味着某个子类还在覆写公开读口，契约仍可被绕过。

- [ ] **Step 8: 确认钩子齐全且无遗漏的 frozen**

```bash
grep -c "_raw(" core/network_input_source.gd core/ai_input_source.gd tests/soak_bot_input.gd
```

Expected: `8` / `8` / `8`。

```bash
grep -rn "frozen" core/ scenes/ server/
```

Expected: 只有 `core/input_source.gd`（1 个 `var` + 8 处短路）与 `scenes/player/player.gd:132`（1 处写）。**其他命中即失败。**

- [ ] **Step 9: 跑断言，确认转绿**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/ai_input_source_smoke.gd
```

Expected: `AI INPUT SMOKE: OK`，退出码 0（`frozen:*` 8 条 + 原有的覆写断言全绿）。

- [ ] **Step 10: 回归冒烟（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出码 0。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/player_contract_smoke.gd
```

Expected: 通过（该探针 `:34` 断言 `player.gd` 源码含 `input_source.get_axis`——本 Task 未改 `player.gd`，应仍绿）。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/network_input_smoke.gd
```

Expected: 通过。**该冒烟直接验 `NetworkInputSource` 的读口，是本 Task 改名后最该跑的一个。**

**行为等价性必须由用户确认的两点**（探针覆盖不到，见「行为面」）：
1. 进 PvP 跑一局，COUNTDOWN 3 秒里本地玩家不自走、不能开火（与改前一致）。
2. 大乱斗 AI 补位局跑一局，AI 行为与改前一致（`--ai-roles` 本就待验收，此条顺带压一遍）。

- [ ] **Step 11: 提交**

```bash
git add core/input_source.gd core/network_input_source.gd core/ai_input_source.gd tests/soak_bot_input.gd tests/ai_input_source_smoke.gd
git commit -m "fix(input): 把 frozen 短路收回 InputSource 公开读口,子类只覆写 _*_raw() 钩子——此前三个子类覆写了全部公开读口,基类的 if frozen 整个被绕过,set_controls_locked 对网络/AI 源是静默空操作(仅靠 reset_state 与 AI 自查 RoundState 兜住)。行为面:①网络/AI 源在 frozen 时真返回中性值(当前生产路径本来就没有有效输入,无可观测差异);②冻结期不再调用子类 raw 钩子 → 边沿不被消费/切枪槽位不被取走(期望语义);③瞄准读口刻意仍不冻结。新增 ai_input_source_smoke 的 8 条 frozen 断言,先跑红(FAIL(8 条))后转绿"
```

---

### Task 5: H4 — 删 `PvpSession` 4 个无读者字段 + 标注权威来源

**Files:**
- Modify: `core/pvp_session.gd`（删 4 字段 + `reset()` 对应行 + 加权威注释）
- Modify: `core/run_options.gd`（只加权威注释）
- Modify: `scenes/main_menu.gd:190`
- Modify: `scenes/matchmaking.gd`（`_join_code` 内 1 行）
- Modify: `scenes/pvp_client.gd`（`_apply_match_options` 内 1 行）
- Modify: `scenes/royale_game.gd`（`_apply_match_options` 内 1 行）
- Modify: `scenes/royale_lobby.gd`（`_on_go_match` 内 1 行）
- Modify: `tests/kh_l1_probe.gd:85-94`
- Modify: `tests/royale_bound_watcher.gd:168-171`
- Modify: `tests/royale_soak_probe.gd:229`

**Interfaces:**
- Consumes: Task 2 的改名结果（`_on_match_options` → `_apply_match_options`）
- Produces: 无（删字段；`PvpSession` 保留 `server_address`/`role`/`player_name`/`map_path`/`spawn`）

**背景（逐字段核过生产引用）：**

| 字段 | 生产引用 | 实情 |
|---|---|---|
| `port` | **0** | 连赋值都没有（只有声明与 `reset()`） |
| `room_code` | 0 读 | 唯一写入点 `matchmaking.gd:328`，无读者（真房间号走 `join_room` 的实参） |
| `disabled_weapons` | 0 读 | 两个写入点；**真正生效的是同 handler 下一行的 `set_enabled_slots(disabled)`**。唯一读者是 `tests/royale_bound_watcher.gd:169` |
| `royale` | 0 读 | 两个写入点赋 `true`，全仓无读（`CLAUDE.md:129` 却写它「标记分支」——实际分支靠「从哪个场景进来」） |

**`disabled_weapons` 的删法（关键）：** `tests/royale_bound_watcher.gd` **已经**在 `:175-179` 有一条权威断言（读真玩家的 `weapons.enabled_slots`），`:169` 那条读 `PvpSession.disabled_weapons` 只是**冗余见证**。按仓内惯例「**改探针认新入口，别为探针保留死字段**」：删字段 + 删那条冗余断言，保留权威那条。

**`CLAUDE.md:129` 也要一起改**（它说 `PvpSession.royale` 标记分支）。

- [ ] **Step 1: 确认锚点**

```bash
grep -rn "PvpSession\.\(port\|room_code\|royale\|disabled_weapons\)" --include=*.gd scenes/ server/ core/ ui/ tests/
```

Expected（**恰好 11 处**，多一处就要重新评估）：

```
scenes/main_menu.gd:190          PvpSession.royale = true
scenes/matchmaking.gd:328        PvpSession.room_code = code
scenes/pvp_client.gd:512         PvpSession.disabled_weapons = disabled
scenes/royale_game.gd:505        PvpSession.disabled_weapons = disabled
scenes/royale_lobby.gd:572       PvpSession.royale = true
tests/kh_l1_probe.gd:86,88,90,91,93
tests/royale_bound_watcher.gd:169,171
tests/royale_soak_probe.gd:229
```

- [ ] **Step 2: 重写 `core/pvp_session.gd`**

```gdscript
class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。
#
# ★ 本类只放**真的有人读**的字段。2026-09-14 删掉了 4 个"只写不读"的字段
#   (`port` / `room_code` / `royale` / `disabled_weapons`),它们制造了一个假象:
#   读的人在找一个根本不以它为权威的入口。各自的真权威见下方逐条注释。
#   规则:加字段前先 grep 确认**有读者**;只写不读的字段一律不要加。

static var server_address: String = "120.53.107.140"   # 默认服务器(云)
static var role: int = 1          # 1=P1(…N=大乱斗中的第 N 人)。真读者很多(出生点/副本/上报)
static var player_name: String = "Anon"   # 匹配界面输入的昵称(默认 Anon;头上显示;会话内不清)
static var map_path: String = ""       # 服务器定图:worker 在 match_start 里下发,对局场景加载同名文件
static var spawn: Vector2i = Vector2i(-1, -1)   # 本端出生点(match_sync 下发,与服务器同源)

# ── 「开局三载荷的跨场景交接」已删除(2026-09-12)──
# 原先 worker 在 match_start 同一批 flush 里**推** peer_info/peer_hues/match_options,而客户端
# 那一刻正在帧末切场景 → 订阅方一个都不存在 → 静默丢失(自检 B2:对手颜色不生效 / 昵称表空到
# 连自己头顶 ID 都建不出来 / 禁武器闸门没上)。当时的解法是大厅先接住、缓存成本文件的
# pending_* 静态字段、新场景进场景时取用。
# 现在改成**进场拉取**(`NetBus.match_sync`):新场景建好、订阅齐了才开口要,时序不敏感。
# 于是缓存这一层连同 pending_* 一并删除 —— 只留一条投递路径,也就不存在"只改一条"的错法。
# 守卫:`tests/match_sync_probe` 的反向断言,全仓不得再出现这些标识符。

# ── 「本局禁了哪些枪」的权威在哪(2026-09-14 加,别再四处找)──
#   · 联机对局:**服务器 MatchHost**。客户端侧的真生效点是 `player.weapons.set_enabled_slots(disabled)`
#     (`pvp_client._apply_match_options` / `royale_game._apply_match_options` 里紧跟载荷解析那一行),
#     载荷来自 match_sync 的 options(服务器按 role1 的 player_options 生效)。
#   · 单机:**`RunOptions.disabled_weapons`**(菜单写入,`level_0.gd:94` 读)。
#   · `Settings.pvp_disabled_weapons` / `Settings.sp_disabled_weapons` 是**本机持久化的选择**,
#     不是权威——它们只是下次开面板时的回显默认值。
#   原先还有一个 `PvpSession.disabled_weapons` 静态镜像,已删(只写不读,且让人误以为它是权威)。

static func reset() -> void:
	server_address = "120.53.107.140"
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
```

（`player_name` 刻意**不**在 `reset()` 里清——原实现也没清，注释写明「会话内不清」，照旧。）

- [ ] **Step 3: `core/run_options.gd` 加权威注释**

在 `:7` 的 `disabled_weapons` 行上方插入：

```gdscript
# 「本局禁了哪些枪」在**单机**下的权威就是本字段(菜单写入,level_0.gd:94 读)。
# 联机对局的权威是服务器 MatchHost,客户端侧真生效点是 weapons.set_enabled_slots()
# —— 完整对照见 core/pvp_session.gd 的「权威在哪」小节。
```

- [ ] **Step 4: 删 4 行死赋值**

四处各删一行（连同它的缩进）：

`scenes/main_menu.gd:190` —— 删 `		PvpSession.royale = true`（`PvpSession.reset()` 那行**保留**，它仍有意义）。

`scenes/matchmaking.gd` 的 `_join_code` 内 —— 删 `	PvpSession.room_code = code`（下一行的 `_with_lobby(...)` 里已经把 `code` 传给 `join_room`，删掉不影响）。

`scenes/pvp_client.gd` 的 `_apply_match_options` 内 —— 删 `	PvpSession.disabled_weapons = disabled`，**保留**下一行 `	if _local != null: _local.weapons.set_enabled_slots(disabled)`。

`scenes/royale_game.gd` 的 `_apply_match_options` 内 —— 同上，删一行、保留 `set_enabled_slots` 那两行。

`scenes/royale_lobby.gd` 的 `_on_go_match` 内 —— 删 `	PvpSession.royale = true`（`PvpSession.role = role` 那行**保留**）。

- [ ] **Step 5: `tests/kh_l1_probe.gd` —— 删对已删字段的 reset 断言**

把 `:85-94` 整段：

```gdscript
	# 5) pvp_session 两个新字段 + reset 清得掉
	if PvpSession.royale:
		failures.append("PvpSession.royale 重置后应为 false")
	if PvpSession.disabled_weapons.size() != 0:
		failures.append("PvpSession.disabled_weapons 重置后应为空")
	PvpSession.royale = true
	PvpSession.disabled_weapons.append(3)
	PvpSession.reset()
	if PvpSession.royale or PvpSession.disabled_weapons.size() != 0:
		failures.append("PvpSession.reset() 未清 royale/disabled_weapons")
```

改为（**换成仍在的字段**，别只是删掉——reset 行为本身仍值得钉）：

```gdscript
	# 5) pvp_session 的 reset 清得掉(2026-09-14:原断言的两个字段 royale/disabled_weapons
	#    已作为"只写不读"删除;改钉仍在的 map_path/spawn —— 换局时它们必须回到初值,
	#    否则上一局的地图/出生点会漏进下一局)
	PvpSession.map_path = "res://maps/factory1v1.cyrm"
	PvpSession.spawn = Vector2i(9, 9)
	PvpSession.reset()
	if PvpSession.map_path != "":
		failures.append("PvpSession.reset() 未清 map_path(换局会漏上一局的地图)")
	if PvpSession.spawn != Vector2i(-1, -1):
		failures.append("PvpSession.reset() 未清 spawn(换局会漏上一局的出生点)")
```

- [ ] **Step 6: `tests/royale_bound_watcher.gd` —— 删冗余见证断言**

把 `:168-171`：

```gdscript
	# 3) 禁武器闸门(match_options):PvpSession 与真玩家武器槽位都要被闸住
	if PvpSession.disabled_weapons != [DISABLED_SLOT]:
		problems.append("PvpSession.disabled_weapons=%s ≠ [%d] → match_options 没进新场景" % [
				str(PvpSession.disabled_weapons), DISABLED_SLOT])
```

改为：

```gdscript
	# 3) 禁武器闸门(match_options):判据是**真玩家的武器槽位**(下面的 local.weapons.enabled_slots)。
	#    2026-09-14:PvpSession.disabled_weapons 已作为"只写不读"删除,原先那条对它的断言是冗余见证
	#    (同一条链路上已经有下面的权威断言),按仓内惯例改探针认新入口,不为探针保留死字段。
```

**下面那段 `var local: Node = game.get("_local")` 起的断言一行不动**——它是本条的权威判据。

- [ ] **Step 7: `tests/royale_soak_probe.gd:229` —— 删死赋值**

`_on_go_match` 内删 `	PvpSession.royale = true`（`PvpSession.role = role` **保留**）。

- [ ] **Step 8: 确认旧字段全仓无残留**

```bash
grep -rn "PvpSession\.\(port\|room_code\|royale\|disabled_weapons\)" --include=*.gd .
```

Expected: 无输出。

- [ ] **Step 9: `CLAUDE.md` 改两处**

`CLAUDE.md:129` 附近（大乱斗章节）——把

```markdown
`PvpSession.royale = true` 标记分支。
```

改为：

```markdown
分支靠**从哪个场景进来**判定(`royale_lobby` → `royale_game`);原先的 `PvpSession.royale`
静态标记已删(只写不读)。
```

同时 `CLAUDE.md` 的「参数体系」段里若有 `PvpSession` 字段清单，按新的 5 字段更新。

- [ ] **Step 10: 启动自检 + 探针（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，无 `SCRIPT ERROR` / `Parse Error`。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 600 res://tests/kh_l1_probe.tscn 2>&1 | grep ALL-OK
```

Expected: 一行 `ALL-OK`。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 600 res://tests/kh_l4_probe.tscn 2>&1 | grep ALL-OK
```

Expected: 一行 `ALL-OK`。**该探针 `:340` 的注释里提到了 `PvpSession.royale` 这个标识符**，跑它是为了确认注释与判据没被本次删除影响。

- [ ] **Step 11: 提交**

```bash
git add core/pvp_session.gd core/run_options.gd scenes/main_menu.gd scenes/matchmaking.gd scenes/pvp_client.gd scenes/royale_game.gd scenes/royale_lobby.gd tests/kh_l1_probe.gd tests/royale_bound_watcher.gd tests/royale_soak_probe.gd CLAUDE.md
git commit -m "refactor(session): 删 PvpSession 4 个只写不读字段(port/room_code/royale/disabled_weapons)+ 标注禁武器权威在哪——disabled_weapons 真生效点是 weapons.set_enabled_slots(),royale 的分支靠进场场景判定。全仓共 4 个同名 disabled_weapons 且命名不提示权威,是本次主要成本。探针按惯例改认新入口(kh_l1 改钉 map_path/spawn 的 reset;royale_bound_watcher 删冗余见证,保留读真玩家 enabled_slots 的权威那条)"
```

---

### Task 6: M4a — 抽 `server/match_bootstrap.gd`（纯移动）

**Files:**
- Create: `server/match_bootstrap.gd`
- Modify: `server/room_manager.gd:744-761`（`start_match_on` 整段移出）、`:10`（`PVP_MAP` 移出）
- Modify: `server/server_main.gd:300`（改调用点）

**Interfaces:**
- Consumes: 无
- Produces:
  - `MatchBootstrap.PVP_MAP: String`（= `"res://maps/factory1v1.cyrm"`）
  - `MatchBootstrap.start_on(role_peers: Dictionary, map_path: String = PVP_MAP, options: Dictionary = {}, ai_roles: Array = []) -> Node`

**背景：** `start_match_on` 是 `static func`，注释自己写明「在 worker 进程调用」——它和 `RoyaleHost.start_on` 是一对孪生，却一个住在**大厅的房间文件**里、一个住在对局宿主文件里。worker 进程只需要建局，却因为 `class_name RoomManager` 连带加载整张房间注册表、房间状态广播、端口池与 PowerShell 杀进程代码。这是本批次里**零 Node 依赖**的一块（只用 `MazeGenerator`/`GameParameters`/`NetBus`/`NetBusExt`/`MatchHost`/`RoyaleHost`），可以安全搬。

- [ ] **Step 1: 确认锚点**

```bash
grep -n "PVP_MAP\|start_match_on" server/room_manager.gd server/server_main.gd
```

Expected: `room_manager.gd` 有 `:10`（`const PVP_MAP`）、`:748`（`static func start_match_on`）、`:749`（默认参数引用 `PVP_MAP`）；`server_main.gd` 有 `:5`（注释）、`:300`（调用）。**若 `server_main.gd:300` 的实参形状与下面 Step 3 写的不一致，停止本 Task** 并记录。

- [ ] **Step 2: 建 `server/match_bootstrap.gd`**

把 `room_manager.gd:744-761` 的整段（`# ── 建局(在 worker 进程调用)…` 注释起、到 `start_match_on` 函数体结束）**逐字搬过来**，只改函数名与类头：

```gdscript
class_name MatchBootstrap
extends RefCounted

# 建局:在 **worker 进程**里调用 —— 重算世界尺寸 + 给两端发 match_start + 建权威对局宿主。
#
# ★ 为什么单独成文件(2026-09-14):它原本住在 server/room_manager.gd(RoomManager)里,
#   而 RoomManager 是大厅侧的房间注册表(+ 端口池 + 房间状态广播 + PowerShell 杀进程)。
#   worker 进程只需要建局,却因为 class_name 连带加载整张大厅注册表。
#   MatchHost / RoyaleHost 都住在"对局宿主"这一侧,建局引导也该在这一侧。
#
# role_peers = {role: peer_id};options = 房主(role1)的对局选项(禁武器/回合回血等,见 MatchHost);
# ai_roles = AI 补位 role 列表(实验性):这些 role 由服务端 AI 驱动,不发 match_start。
# 与 RoomManager.start_match_on 逐字同逻辑,只是搬了家(纯搬迁,行为零变化)。

const PVP_MAP := "res://maps/factory1v1.cyrm"

static func start_on(role_peers: Dictionary, map_path: String = PVP_MAP,
		options: Dictionary = {}, ai_roles: Array = []) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	var spawns := MazeGenerator.load_spawns()
	var s1: Vector2i = spawns.get("player", Vector2i(-1, -1))
	var s2: Vector2i = spawns.get("player2", Vector2i(-1, -1))
	for role in role_peers:
		var peer_id: int = role_peers[role]
		var spawn := s1 if role == 1 else s2
		NetBus.rpc_id(peer_id, "match_start", role, spawn, map_path)
		NetBus.rpc_id(peer_id, "server_message", "对局开始")
	var host := MatchHost.new(map_path, role_peers, options, ai_roles)
	return host
```

**以上函数体是从 `server/room_manager.gd:750-761` 逐字抄来的**（含 `s1`/`s2`/`spawn` 的名字与那两行 `rpc_id`），照抄，不要重写、不要"顺手改"。上面的分节注释 `# ── 建局(在 worker 进程调用)…` 三行也一并搬来（放在 `const PVP_MAP` 上方）。

- [ ] **Step 3: 刷全局类缓存**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```

Expected: 无 Parse Error。**这一步不能省** —— 新建 `class_name` 后不刷缓存，下一步的引用处会报 Parse Error。

- [ ] **Step 4: 删 `room_manager.gd` 的原件**

删掉 `:744-761` 整段（`# ── 建局(在 worker 进程调用)…` 到文件末的 `start_match_on`）。同时删掉 `:10` 的 `const PVP_MAP := "res://maps/factory1v1.cyrm"` —— **但先确认它在 `room_manager.gd` 内没有别的用处**：

```bash
grep -n "PVP_MAP" server/room_manager.gd
```

Expected（删掉 `:744-761` 之后）：**无输出**。若有输出，说明还有别处用它，把 `:10` 的 `const` 留下（并在此处记一笔「两个 PVP_MAP 常量并存」到「未预期发现」）。

- [ ] **Step 5: 改 `server_main.gd` 的调用点**

`:300`：

```gdscript
		_host = RoomManager.start_match_on(_claims, RoomManager.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
```

改为：

```gdscript
		_host = MatchBootstrap.start_on(_claims, MatchBootstrap.PVP_MAP, _claim_opts.get(1, {}), _ai_roles)
```

`:5` 的注释里 `RoomManager.start_match_on 建权威 MatchHost` 改为 `MatchBootstrap.start_on 建权威 MatchHost`。

- [ ] **Step 6: 确认搬迁干净**

```bash
grep -rn "start_match_on" --include=*.gd server/ core/ scenes/
```

Expected: 无输出（旧名彻底消失）。

```bash
grep -rn "MatchBootstrap" --include=*.gd server/
```

Expected: `server/match_bootstrap.gd`（定义）+ `server/server_main.gd`（两处：调用 + 注释）。

- [ ] **Step 7: 两模式冒烟（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，无 `SCRIPT ERROR` / `Parse Error`。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn
```

Expected: 打印大厅 banner 与 `[server] 版本 …`，**无** Parse Error。按 Ctrl+C 退出（或直接关窗口）。这是本 Task 最该跑的一条——`start_match_on` 只在 worker 进程里被调用，而 worker 是 `server_main` 的 `--worker` 分支。

（完整链路验证由 Task 7 之后一起做，见「批次收尾」。）

- [ ] **Step 8: 提交**

```bash
git add server/match_bootstrap.gd server/match_bootstrap.gd.uid server/room_manager.gd server/server_main.gd
git commit -m "refactor(server): 抽 MatchBootstrap.start_on(RoomManager.start_match_on 搬家)+ PVP_MAP 随迁——它是 worker 进程内的建局引导,与 MatchHost/RoyaleHost 同侧;原先住在 RoomManager(大厅房间注册表)里,让 worker 因 class_name 连带加载整张大厅注册表。纯搬迁,行为零变化"
```

---

### Task 7: M4b — 抽 `server/worker_launcher.gd`（纯移动）

**Files:**
- Create: `server/worker_launcher.gd`
- Modify: `server/room_manager.gd`（搬出端口池与进程族；调用点改转发）

**Interfaces:**
- Consumes: 无
- Produces（`WorkerLauncher extends RefCounted`）：
  - `const WORKER_PORT_BASE := 7800`、`const WORKER_PORT_SPAN := 500`
  - `const WORKER_PORT_REUSE_DELAY := 30.0`、`const ROYALE_PORT_REUSE_DELAY := 360.0`
  - `func pick_port() -> int`
  - `func release_now(port: int) -> void`
  - `func spawn_worker(port: int, ai_roles: Array = []) -> bool`
  - `func spawn_royale_worker(port: int, roles: Array, ai_roles: Array = []) -> bool`
  - `func kill_worker(port: int) -> void`
  - `func log_path(port: int) -> String`

**背景：** 端口分配/释放、worker 子进程拉起、按端口杀进程、日志落盘——四件事都是**进程与端口**，与「房间」无关。`RoomManager` 因为持有它们而变成 761 行。搬出后 `RoomManager` 缩小约 130 行。

**⚠ 本 Task 是纯搬迁，明确不修 M1。** `_worker_ports.erase(port)` 在失败/拆除分支里的**语义原样保留**（包括 `royale_start`/`ai_duel` 那两条不清 `room.worker_port` 的分支）——M1 是独立一项，见「后续问题排序」阶段 1。搬完这条路径的行为必须与搬前逐字一致。

**⚠ `release_now` 只是 `_worker_ports.erase(port)` 的新名字**（`port <= 0` 的早退守卫对现有调用点无影响——所有调用点的 `port` 都来自 `pick_port()` 的返回值，恒 `> 0`）。**不要**顺手加 `is_busy` 检查、不要加日志。

- [ ] **Step 1: 确认锚点与调用点清单**

```bash
grep -n "_pick_worker_port\|_release_port_later\|_spawn_worker\|_spawn_royale_worker\|_kill_worker\|_worker_log_path\|_worker_ports\|_next_port" server/room_manager.gd
```

Expected（撰写时的快照，**逐条核对数量**）：

| 目标 | 定义行 | 调用/引用行 |
|---|---|---|
| `_pick_worker_port` | 624 | 376, 427, 459, 536 |
| `_release_port_later` | 616 | 593 |
| `_spawn_worker` | 638 | 432, 544 |
| `_spawn_royale_worker` | 504 | 382, 468 |
| `_kill_worker` | 738 | 588 |
| `_worker_log_path` | 667 | 512, 517, 528, 642, 646, 656 |
| `_worker_ports` | 29 | 384, 433, 470, 589, 591, 620, 630, 631 |
| `_next_port` | 28 | 626, 627, 628, 629 |

**`_release_port_later` 留在 `RoomManager` 不动**——它 `await get_tree().create_timer(delay)`，需要树；搬进 RefCounted 就没有 `get_tree()`。它只需把最后一行改成转发（Step 4）。

**`_worker_log_path` 的 6 个调用点全在被搬走的那两个 spawn 函数体内**，随迁，Step 4 不必单独处理。

- [ ] **Step 2: 建 `server/worker_launcher.gd`（完整内容如下）**

以下内容由 `room_manager.gd` 的对应原件**逐字搬来**（只改函数名与内部互调），照抄，不要重写、不要"顺手改"：

```gdscript
class_name WorkerLauncher
extends RefCounted

# 每局 worker 子进程的**端口池 + 进程管理**:分配端口、拉起 headless worker、按端口杀、日志落盘。
#
# ★ 为什么单独成文件(2026-09-14):这四件事都是"进程与端口",与"房间"无关,原先挤在
#   server/room_manager.gd(RoomManager)里让它长到 761 行。搬出后 RoomManager 只留房间与拆除编排。
#
# ★ 端口分配必须是「唯一递增 + 占用集合」(理由见下方 WORKER_PORT_BASE 上方的原注释):
#   **不要**改成在本进程 bind 探测空闲 —— worker 是独立进程,大厅探测看不到别的进程已占端口,
#   并发会把同一端口发给两个 worker。
#
# ★ release_now() 只是原来那句 `_worker_ports.erase(port)` 的新名字。**纯搬迁,语义未变**:
#   失败分支里"立刻归还端口"的既有行为(含 room_manager.gd 里那条已知缺陷 M1)原样保留。

# 对局 worker 端口分配:每次 spawn 发**不重复**的端口。注意不能用本进程 bind 探测"空闲"
# —— worker 是独立进程,大厅本进程绑定测试看不到其它进程已占的 socket(并发时会把同端口
# 发给两个 worker,后者绑定失败退出)。唯一递增 + 占用集合即可保证并发零冲突。
const WORKER_PORT_BASE := 7800
const WORKER_PORT_SPAN := 500
# 端口归还延迟(秒)。不能在房间清空时立刻归还:玩家转连 worker 的瞬间大厅就关房,
# 而旧 worker 要等客户端真正断开(对局结束/退菜单)才退出,窗口期可达数分钟;
# 立刻复用会把同端口发给新 worker → bind 冲突,或旧 worker 抢到新局的客户端(跨房间串线)。
# 30s 足够旧 worker 走完收尾;极端情况(客户端僵死不断开)由 500 端口轮回兜底。
const WORKER_PORT_REUSE_DELAY := 30.0
# 大乱斗 worker 的端口归还延迟:按**默认**一局时长(RoyaleHost.MATCH_TIME=300)+ 收尾估,
# 沿用 30s 会让对局中途端口被发给新 worker(串线/bind 冲突)——自检 M2。
# ★ 已知边界(照实登记,本次不放宽):房主可用建房页的「一局限时」把一局配到 30 分钟
# (Settings.royale_match_min → player_options 的 match_time → RoyaleHost),此时本延迟短于
# 一局,端口可能在**旧 worker 还在跑**时就被复用。与 sweep 在局宽限同一根因(都拿默认时长
# 当上界),修法同样要让界读**本局实际时长**(只在 worker 里)——见 _sweep_stale_rooms 的注释。
const ROYALE_PORT_REUSE_DELAY := 360.0
var _next_port := WORKER_PORT_BASE
var _worker_ports: Dictionary = {}   # 正在使用(未释放)的 worker 端口


# 立刻把端口还给池子(不等 worker 退出)。调用方语义见 room_manager 的 TEARDOWN_* 三档。
func release_now(port: int) -> void:
	if port <= 0:
		return
	_worker_ports.erase(port)


# 分配一个当前未占用的 worker 端口(唯一递增 + 占用集合;见类头注释,勿用 bind 探测)。
func pick_port() -> int:
	for _tries in range(WORKER_PORT_SPAN):
		var p := _next_port
		_next_port += 1
		if _next_port >= WORKER_PORT_BASE + WORKER_PORT_SPAN:
			_next_port = WORKER_PORT_BASE
		if not _worker_ports.has(p):
			_worker_ports[p] = true
			return p
	return -1


# ── worker 的引擎日志落盘(两个 spawn 共用)──
# worker 是**独立进程**,它的 stdout 父进程看不到(Windows CreateProcess 不继承句柄)→ 服务端侧
# 出问题时(worker 崩了/报错/提前退出)大厅这边**一个字都收不到**,只能从客户端的表象反推。
# 2026-09-12 排查「大乱斗击杀后对手崩溃」时就卡在这个盲区上:大厅日志从头到尾是干净的,
# 而真正跑对局的 worker 说了什么**没人知道**。故给每个 worker 一份引擎日志。
# ⚠ `--log-file` 是**引擎选项**,必须排在 `--` 之前 —— 那之后是 server_main._ready 自己解析的
#   用户参数(`--worker`/`--port`/`--roles`),顺序错了会被当用户参数吞掉。
func log_path(port: int) -> String:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("worker_%d.log" % port)


# 拉起 headless worker 子进程(同一可执行文件 + --worker)。editor(开发)要带 --path 与场景;
# 导出的专用服务端 exe(disable_path_overrides)靠 main_scene.dedicated_server 起 server_main。
# ai_roles 非空 → 透传 --ai-roles(worker 侧这些 role 由服务端 AI 驱动,不等 claim)。
func spawn_worker(port: int, ai_roles: Array = []) -> bool:
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--port", str(port)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--port", str(port)])
	if not ai_roles.is_empty():
		var roles := []
		for r in ai_roles:
			roles.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(roles))
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn worker pid=%d port=%d editor=%s ai=%s 日志=%s" % [pid, port,
			str(OS.has_feature("editor")), str(ai_roles), log_path(port)])
	return pid > 0


# 拉起大乱斗 worker(--royale --roles 1,2,3 [--ai-roles r,r];其余同 spawn_worker)
func spawn_royale_worker(port: int, roles: Array, ai_roles: Array = []) -> bool:
	var role_strs := []
	for r in roles:
		role_strs.append(str(int(r)))
	var exe := OS.get_executable_path()
	var args: PackedStringArray
	# editor 与 template_debug(调试引擎)都要带 --path+场景;仅导出 exe 可省(dedicated_server 主场景)
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn", "--", "--worker", "--royale",
				"--port", str(port), "--roles", ",".join(role_strs)])
	else:
		args = PackedStringArray(["--headless", "--log-file", log_path(port),
				"--", "--worker", "--royale",
				"--port", str(port), "--roles", ",".join(role_strs)])
	if not ai_roles.is_empty():
		var ai_strs := []
		for r in ai_roles:
			ai_strs.append(str(int(r)))
		args.append("--ai-roles")
		args.append(",".join(ai_strs))
	var pid := OS.create_process(exe, args)
	print("[lobby] spawn royale worker pid=%d port=%d roles=%s ai=%s 日志=%s" % [pid, port,
			str(roles), str(ai_roles), log_path(port)])
	return pid > 0


# 杀指定 UDP 端口的进程(worker)。Windows:PowerShell 取该端口属主进程 → Stop-Process。
# 与 server_main._kill_port_holder 同法;不能只靠 OS.create_process 返回的 pid(跨进程需查端口)。
func kill_worker(port: int) -> void:
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" -ErrorAction SilentlyContinue | Select -ExpandProperty OwningProcess -Unique; " + \
			"if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)
```

**与原件的差异（仅此两处，其余逐字一致）：**
1. 函数名：`_pick_worker_port`→`pick_port`、`_spawn_worker`→`spawn_worker`、`_spawn_royale_worker`→`spawn_royale_worker`、`_kill_worker`→`kill_worker`、`_worker_log_path`→`log_path`（**内部互调也已一并改名**）。
2. 新增 `release_now()`（`port <= 0` 守卫见上）。

**★ 四组常量的注释必须逐字保留**（尤其 `ROYALE_PORT_REUSE_DELAY` 上方那段「已登记的已知边界」——它是 CLAUDE.md 里同一条已知边界的代码侧登记，丢了就只剩文档、代码里查不到了）。**不要**把长注释压缩成一行。

- [ ] **Step 3: 刷全局类缓存**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```

Expected: 无 Parse Error。

- [ ] **Step 4: `room_manager.gd` — 加持有者、删原件、调用点改转发**

在 `:29` 的位置（`_worker_ports` 原本所在处）改为：

```gdscript
var _launcher := WorkerLauncher.new()   # worker 端口池 + 子进程(见 server/worker_launcher.gd)
```

`_release_port_later`（`:616-621`）只剩转发：

```gdscript
# 延迟归还 worker 端口(delay:1v1=30s;大乱斗房传 ROYALE_PORT_REUSE_DELAY,一局可长达 5 分钟)。
# 本方法留在 RoomManager 是因为它要 await get_tree() —— RefCounted 没有树(见 WorkerLauncher 类头)。
func _release_port_later(port: int, delay: float = WorkerLauncher.WORKER_PORT_REUSE_DELAY) -> void:
	if port <= 0:
		return
	await get_tree().create_timer(delay).timeout
	_launcher.release_now(port)
```

**删除** `:14-15`、`:20`、`:27`、`:28` 的 4 组常量与 `_next_port`，以及 `:504-529`、`:624-635`、`:638-658`、`:660-670`、`:738-742` 五段。

**其余全部调用点改转发**（一一对应，**逐条都要改**）：

| 原 | 新 |
|---|---|
| `_pick_worker_port()` | `_launcher.pick_port()` |
| `_spawn_worker(port)` | `_launcher.spawn_worker(port)` |
| `_spawn_worker(port, [2])` | `_launcher.spawn_worker(port, [2])` |
| `_spawn_royale_worker(port, roles)` | `_launcher.spawn_royale_worker(port, roles)` |
| `_spawn_royale_worker(port, roles, ai_roles)` | `_launcher.spawn_royale_worker(port, roles, ai_roles)` |
| `_kill_worker(port)` | `_launcher.kill_worker(port)` |
| `_worker_ports.erase(port)`（`:384` `:433` `:470` `:589` `:591` 五处） | `_launcher.release_now(port)` |
| `WORKER_PORT_REUSE_DELAY` / `ROYALE_PORT_REUSE_DELAY`（`:593`） | `WorkerLauncher.WORKER_PORT_REUSE_DELAY` / `WorkerLauncher.ROYALE_PORT_REUSE_DELAY` |

**注意 `:620` 那处**（在 `_release_port_later` 内）已由 Step 4 的转发覆盖，不要重复改。

**`:29` 的 `_worker_ports` 与 `:631` 的 `_worker_ports[p] = true`** 都在搬走的原件里，随 Step 4 的删除一起消失。

- [ ] **Step 5: 确认搬迁干净、无残留旧名**

```bash
grep -n "_pick_worker_port\|_spawn_worker\|_spawn_royale_worker\|_kill_worker\|_worker_log_path\|_worker_ports\|_next_port" server/room_manager.gd
```

Expected: 无输出。

```bash
grep -n "WORKER_PORT_BASE\|WORKER_PORT_SPAN\|WORKER_PORT_REUSE_DELAY\|ROYALE_PORT_REUSE_DELAY" server/room_manager.gd
```

Expected: 只剩 `:579` 与 `:615` 附近**注释里**的提及（若注释描述的是常量语义，改成「见 WorkerLauncher」；若只是背景说明可保留字面量）。**任何代码位置的命中都要改成 `WorkerLauncher.` 前缀。**

```bash
grep -c "func " server/worker_launcher.gd
```

Expected: `7`（`pick_port` / `release_now` / `spawn_worker` / `spawn_royale_worker` / `kill_worker` / `log_path` + 若 `_worker_log_path` 的分节注释不算则 6；以实际搬入的方法数为准，**必须 ≥6**）。

- [ ] **Step 6: 行数复核（本 Task 的核心收益指标）**

```bash
wc -l server/room_manager.gd server/worker_launcher.gd
```

Expected: `room_manager.gd` 从 761 降到 **≈620-640**；`worker_launcher.gd` **≈130-150**。

- [ ] **Step 7: 启动自检 + 大厅自检（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，无 `SCRIPT ERROR` / `Parse Error`。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn
```

Expected: 打印大厅 banner 与 `[server] 版本 …`，**无** Parse Error。

- [ ] **Step 8: 提交**

```bash
git add server/worker_launcher.gd server/worker_launcher.gd.uid server/room_manager.gd
git commit -m "refactor(server): 抽 WorkerLauncher(端口池 + worker 子进程 + 按端口杀 + 日志路径)——四件事都是进程与端口,与房间无关,原先挤在 RoomManager 里让它长到 761 行。纯搬迁:release_now() 就是原 _worker_ports.erase() 的新名字,失败分支'立刻归还端口'的既有语义(含 M1 那条已知缺陷)原样保留,_release_port_later 因需 await get_tree() 留在 RoomManager"
```

---

## 批次收尾

- [ ] **全仓复核：本批次承诺的「旧名字全部消失」**

```bash
grep -rn "暂时不生效\|静默丢弃" scenes/
grep -rn "_on_peer_info\|_on_peer_hues\|_on_match_options" scenes/
grep -rn "PvpSession\.\(port\|room_code\|royale\|disabled_weapons\)" --include=*.gd .
grep -rn "start_match_on" --include=*.gd .
grep -rn "func get_axis\|func is_action_pressed\|func is_attack_pressed" core/network_input_source.gd core/ai_input_source.gd tests/soak_bot_input.gd
```

Expected: 五条**全部无输出**。

- [ ] **跑全部 KH 层探针（用户执行，判据是 grep `ALL-OK`）**

```bash
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l1_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l3_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l4_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l5_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l6_probe.tscn 2>&1 | grep ALL-OK
```

Expected: 五条各打印一行 `ALL-OK`。**任何一条没有输出即失败**（不要只看退出码）。

- [ ] **跑对局链路（用户执行）——这是 Task 6/7 的唯一实质验收**

**跑前先确认 7777 空闲。**

```bash
bash tests/pvp_room_smoke.sh
bash tests/pvp_match_smoke.sh
bash tests/room_sweep_smoke.sh
```

Expected: 三条均通过。`room_sweep_smoke` 覆盖 `_sweep_stale_rooms` → `TEARDOWN_KILL` → `_launcher.kill_worker()` 这条路径，是 Task 7 最该跑的一条。

```bash
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$GODOT" --headless --path . --quit-after 600 res://tests/match_sync_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 900 res://tests/royale_bound_probe.tscn 2>&1 | grep ALL-OK
```

Expected: 两条各打印 `ALL-OK`。

- [ ] **真机验收（用户执行）**

1. 单机跑一局：手感/换弹/切枪 1~6 槽正常。
2. PvP 跑一局：COUNTDOWN 3 秒本地玩家不自走、不能开火；PLAYING 起能走能打；无「倒计时里漂移后大回滚」。
3. 大乱斗建房 + AI 补位跑一局：AI 行为正常、禁武器闸门生效（勾掉某槽后局内切不到）。
4. 关掉大厅窗口再重开：端口回收正常，能再建局。

---

## 本计划明确不做的事（各自需要独立计划）

1. **M4c —— `server/lobby_rooms.gd`（房间注册表拆分）：本批次**不做**。** 理由已核实：`RoomManager._peer_online()` 用 `multiplayer.get_peers()`、`_enter_tree`/`_exit_tree` 做 autoload 信号 connect/disconnect——两者都要求节点在树上。搬进 `RefCounted` 会立刻断掉，需要先决定它是 `extends Node`（那它就得自己进树、自己管生命周期）还是由 `RoomManager` 传 back-reference（那又没真正解耦）。**这是一个需要单独设计决策的问题，不是纯搬迁。**
2. **M1 —— `royale_start`/`ai_duel` 失败分支不清 `room.worker_port`。** 本批次是纯搬迁，**故意不动**。修法已明确（见「后续问题排序」阶段 1）。
3. **M3 —— `ai_duel` 开局即摘房、端口 30s 后归还。** 需要你判断「AI 对战房要不要留在注册表里」，属设计选择。
4. **`tests/lib/scan_util.gd` + `probe_base.gd`**（`kh_l*_probe` 的扫描工具函数已复制 5 遍）——与本批次的探针改动无交集，另立。
5. **`UiFactory` 补齐**（`check`/`line_edit`/`slider_row`/`apply_font_recursive`）——原本排在被删掉的「批次 2」之后，现改排在阶段 3。
6. **目录与命名整改**（`.tscn` 约定、`ui/` 与文件错位、`core/` 分目录）——见「后续问题排序」阶段 4。

## 未预期发现

（实施者若在任何 Step 的 Expected 复核中遇到不符，**停下来把实际情况记在这里**，不要绕过。）

---

# 后续问题排序（本批次之外的全部剩余项）

分五阶段。**阶段内的每一项都可独立提交**；阶段之间建议按序，因为后一阶段会碰到前一阶段动过的同一批文件。

## 阶段 1：真会出错 + 会误导人 —— ✅ **全部完成**（2026-09-14，分支 `cleanup/stage1-bugs-and-hygiene`）

| 序 | 项 | 状态 |
|---|---|---|
| 1.1 | **H1** AI 锁定目标后方向反 180°（瞄反 + 追逃互换） | ✅ 提交 `a2c331d`。修 `_pick_target` 黏滞分支漏的取负；给 `ai_input_source_smoke` 加两条**真调该函数**的符号断言（此前只查 host/role/src 三个成员名，照不出符号错）。反证：还原坏写法 → 只有黏滞那条 FAIL、重选仍 ok（精确隔离） |
| 1.2 | **M1** worker 起不来时留陈旧 `worker_port` | ✅ 提交 `6a5abfd`（提前于批次 1 内完成，见上） |
| 1.3 | **M2** 掉线终局判据数的是「真人」不是「玩家」 | ✅ 提交 `37c562f`。判据改 `players.size()`；**新增** `tests/royale_disconnect_count_probe.tscn`（真建 `RoyaleHost` + role_peers 传空，手工摆成 2 真人 + 2 AI）：正向断言「掉 1 真人后不得终局」+ **反向**断言「只剩 1 个玩家时必须终局」（否则正向可靠「永不终局」作弊通过）。反证：还原成数 peer → 正是那两条正向 FAIL、反向仍 ok |
| 1.4 | **M9** ★ `royale_c2_watcher` A② 合并后会**静默失效** | ✅ 提交 `64c1327`。A② 改成「持有本地玩家状态的客户端文件」**列表 + 必须在位**：每个候选文件须含 C2 接线标记才算在位；**一个在位的都没有 → 判红**并指名去改 `A2_OWNERS`（原来只防「读不到源文件」，没防「代码搬走了」）。★ 顺带立刻变强：`pvp_client.gd` 同样持有本地玩家状态、同样接了 `local_round_state`，此前**完全没有这道门**，现纳入。反证三条（含把在位标记换成不存在的串 → 走「一个都不在位」分支） |
| 1.5 | **M20** 死代码/死文件一批 | ✅ 提交 `d32de5f`。清单见下 |
| 1.6 | **`tools/check_naming.py`** | ✅ 提交 `cdd270d`。强制 A 目录全小写 / B `class_name` 转 snake == 文件名 / C 文档引用的路径存在；`.tscn` 命名**只报告不判失败**（大小写规则待 4.3 定）。★ 阶段 4.3 定下规则后，把该规则从「报告」升为「强制」并同步这条。基线只留 2 条已接受偏差（`level_0.gd`/`Level0`、`ai_player.gd`/`AINavigator`），各写明何时销 |
| 1.7 | 引擎绝对路径收口到环境变量 | ✅ 提交 `f7594ce`。新增 `tests/env.sh`（`$GODOT` + cd 仓库根 + `kill_procs`/`kill_port`），8 个 `tests/*.sh` 改 `source` 它；`start_server.bat` 走 `%GODOT%`、`build_release.py` 走 `$GODOT_EDITOR`（★ 导出用**标准编辑器**版，与 headless 的 console 版是两个二进制）。10 处散落路径 → 每个入口一处可覆盖默认值。顺带收掉三份重复 kill 样板，并让 5 个原本只能从仓库根跑的冒烟变成从哪儿跑都行 |

**1.5 的死代码清单**（每条都重新 grep 验证过零引用）：`scenes/weapons/explosion.tscn`（与 `scenes/effects/explosion.tscn` 同 uid 的重复副本，且 `ext_resource` 指向**不存在的** `res://scenes/weapons/explosion_fx.gd`）、`TileDefs.friction()`/`tile()`、`core/game_parameters.gd` 的 `enemy_count`/`enemy_spawn_min_dist`、`core/sfx.gd` 的 `"jump"`/`"teleport"`、`server/ai_player.gd` 的 `_last_x`、`server/room_manager.gd` 的 `Room.match_host`、`EnemySpawner.sample_spawn_cells`（只剩测试调它 → **搬进** `tests/enemy_logic_smoke.gd`，连 5 条断言一起保住）、`server/royale_host.gd` 的 `round_state["match_time"]`（每帧构造、无人读，且与配置键 `match_time` **同名反义**）、`maps/old_map.txt`。
★ **顺带发现**：跳跃与黑鸟瞬移目前**没有任何音效**（`jump`/`teleport` 是设计了从未接线的音色）——删的是未接分支，想加时各补 1 行 + 1 处 `Sfx.play` 调用即可。
★ `pistol_test.tscn`/`rifle_test.tscn` 的 `_test` 后缀改名**留到阶段 4**（与其它命名整改一次做完，避免两次动 `.uid`）。

### ⚠ 本阶段踩到并修掉的一个自伤（记下来，供后续同类操作参考）

在 1.6 做「反证 B」（验证 lint 能抓 `class_name` 与文件名不符）时，我往 `core/math_util.gd` **追加**了一行 `class_name TotallyWrong`；随后的另一次反证把**已被污染的文件**当基线备份又还原了回去 —— 于是这行留在工作区（幸而 1.6 提交时是按文件名显式 `git add`，**没把它提交进去**）。

**症状**：`room_sweep_smoke` 的 `reload()` 路径刷出 7 条 `Could not resolve class "MathUtil", because of a parser error`（而其他冒烟照过 —— 所以只看「绿不绿」是发现不了的）。

**怎么查出来的（这套手法值得复用）**：拿 `git worktree add /tmp/wt-XXX <ref>` + `--import` 造两棵**全新工作树**做对照 —— 一棵放 `main`、一棵放当前分支。两棵都是 0 条 → 说明不是代码、是我这棵**工作树**的状态（`.godot` 累积 / 未提交污染）。再顺着「工作区与 main 的差异」一 `git diff main -- core/math_util.gd` 就现形了。

**两条纪律**：① 反证要改文件时，备份/还原一律走 `git stash` 或 `git checkout -- <file>`（从**已提交的**状态取），别用 `cp` 到临时文件 —— 你抄的可能已经是被污染的版本；② 反证做完必须 `git status --short` 看一眼，确认没有残留。

**教训**：本次是 `git diff main -- <file>` 空不空一句话就查清了；而「所有探针都绿」这件事在**被污染的树下**同样成立 —— 所以关键改动落地后，值得用**干净工作树**再跑一遍。

## 阶段 2：契约与说辞的剩余项 —— ✅ **全部完成**（2026-09-14）

> **未按原计划合成一个提交**:2.3~2.6 各自独立成 commit(2.3 / 2.4+2.6 / 2.5),理由是这样出问题时能二分;
> 每条都单独验过。另外**每条抽取都补了「新旧实现对撞」**——把旧实现内联进临时脚本,在真实地图上大规模
> 比对(2.4: 11760 次采样 / 2.5: 18750 次逐格,均 0 不一致)。这套手法对「行为保持的几何/谓词抽取」
> 比单元测试更有说服力,已在本阶段连用两次。

| 序 | 项 | 状态 |
|---|---|---|
| 2.1 | **M13** 副本类双快照插值 18 行逐字相同 | ✅ **复议通过**(用户裁定)后抽 `core/snapshot_interp.gd`(不是原计划写的 `snapshot_buffer.gd` —— 它的职责不止缓冲,还含时钟推进与采样)。顺带**补了这段一直没被测过的热算法的行为冒烟** `tests/snapshot_interp_smoke.gd`(8 组断言,最值钱的是跨接缝必须走最短向量)。★ 写测试时被自己的断言拦下一次:keep_ticks 是「最新前 N tick **含最新**」共 N+1 条,我按 N 条写了 |
| 2.2 | **M14** `ENEMY_NAMES` 手抄第二份 | ✅ `display_name` 进 `data/enemies.json`,经新的 `EnemySpawner.display_name_of`(按**场景路径**查 + 惰性加载)取用;顺带干掉「去掉 `Enemy` 前缀再查表」那条改名即静默回落的约定。`sync-enemies.js` 是字段级手抄,已同步并重跑生成 HTML 内嵌注册表。探针按惯例改判据 |
| 2.3 | **M11** 打包格式 `16` 手写处 | ✅ 实为 **21 处**(计划列 15,漏了 `pvp_client.gd` 与 `royale_game.gd` 的拆砖视觉块 —— 那两块本身也是近乎逐字相同的拷贝)。根因是 `TileDefs` API 不一致(`is_blocked` 吃打包值、`hp_of/climb_speed` 吃纹理号),故每个调用点都得自己 `/16`。`TileDefs` 内部三处一并收口 |
| 2.4 | **M12** 「世界矩形是否压到实心格」三份同构 | ✅ 抽 `core/tile_query.gd`(两个谓词入口:实心 / 实心或液体)。**三处的空网格语义各不相同**(黑鸟「视为全清」/ 飞鸟「不可走」/ 预瞄「无墙」),故兜底留在调用方 —— 飞鸟必须保留自己的 `is_empty` 早退(方向相反)。新增 `tests/tile_query_smoke.gd` 专钉跨接缝与水 |
| 2.5 | 「地板格」谓词重复 | ✅ 实为 **5 处**(`royale_host` 里同一谓词自己就抄了三份:采集循环 / O(1) 版 / 宽松版叠层)。抽成 `is_floor_cell`(基本)+ `is_floor_cell_with_headroom`(带头上净空)。**两处语义差异刻意保留**:`match_host` 的越界即 false(helper 会把超界格 posmod 回环面,语义不同);`climb_component` 的**梯子版**谓词只有 1 处使用且语义不同,不抽 |
| 2.6 | `STOP_SNAP` 两份 | ✅ 第二份是**死副本**(`climb_component` 里全仓零使用,注释却写着"与根一致" —— 该文件此前也有一份零调用的 `_approach` 死副本,批次 1 已删)。删死副本 + 归到 `PlayerParams.stop_snap` |

## 阶段 3：**必须在 M9 之后**才能开工（客户端合并，成本合计 ~3 天）

| 序 | 项 | 位置 | 成本 |
|---|---|---|---|
| 3.1 | **H3** 输入包**编码端两份手抄、解码端一份** —— 加一个 held 位要改 3 处，漏一处**静默** | `pvp_client.gd:186-214` ↔ `royale_game.gd:162-190` | 半天（含改 `kh_l6_probe:248-278` 的组包锚点）。在 `core/network_input_source.gd` 加 `static func pack_record(src, seq, aim) -> Dictionary` |
| 3.2 | **M5** 服务器侧广播样板 7 处 + 两个 spawn + PowerShell 杀端口串两份 | `match_host.gd:208/243/293/520/691/705`、`royale_host.gd:404`；`room_manager.gd` 两个 spawn；`room_manager.gd:738-742` vs `server_main.gd:156-160` | 半天。提 `MatchHost._rpc_all(method, args, except_role := -1)`；杀端口提 `core/proc_util.gd` |
| 3.3 | **M4c** 房间注册表拆分（见「本计划明确不做的事」第 1 条——**先做设计决策**） | `server/room_manager.gd` | 1 天 |
| 3.4 | 客户端事件消费层合并（9 个函数逐字相同 ≈140 行 + 4 个近逐字；具体函数与行号对已列在评估报告里） | `pvp_client.gd` ↔ `royale_game.gd` | 1~2 天。抽 `scenes/pvp_match_client.gd` 基类。**做之前先确认 1.4 已完成** |
| 3.5 | **M8** `ENABLE_BIRDS := false` ⇒ 客户端鸟副本 ~90 行死代码 | `pvp_client.gd:22,94-95,256-262,431-459`；`royale_game.gd:12,82-83,241-247,431-459` | **先决策**：不打鸟就删 90 行；要打就抽一份进 3.4 的基类 |
| 3.6 | 两个大厅页的连接状态机重复（58 个重复块 —— 全仓第二大重复对）+ 禁用武器网格/色相行两处手抄 + `_apply_pixel_font` 8 行 100% 相同 | `matchmaking.gd` ↔ `royale_lobby.gd` | 1~2 天 |
| 3.7 | **批次 6（旧编号）**`UiFactory` 补齐 `check`/`line_edit`/`slider_row`/`apply_font_recursive` | `ui/ui_factory.gd` | 半天。**排在 3.6 之后**——那两个文件正是 3.6 要重构的，先改会撞车 |

## 阶段 4：目录与命名整改（**一次做完，别零敲碎打**，成本合计 ~2 天）

零敲碎打会反复动 `.uid` 与 `.godot` 缓存（照 `docs/naming-cleanup-plan.md` 那次的流程走）。**开工前先确认 1.6 的 `tools/check_naming.py` 已在位。**

| 序 | 项 | 内容 |
|---|---|---|
| 4.1 | **文件错位一批** | `scenes/player/enemy_hp_bar.gd`（内容是 PvP 对手血条）→ `ui/`；`scenes/effects/minimap.gd` → `ui/`；`scenes/player/world_label.gd` → `ui/`（**注意三处调用都是 `load("res://scenes/player/world_label.gd")` 硬编码字符串路径**）；`scenes/player/camera_2d.gd` → `render/`；`scenes/player/weapon_component.gd:31-83` 的 UI 部分 → 新 `ui/weapon_icons.gd` |
| 4.2 | **`ui/` 内聚 + `render/` 名副其实** | `scenes/royale_hud.gd\|tscn` → `ui/`；`shaders/post_process.gdshader` → `render/`（并删空的 `shaders/`）；`scenes/effects/combat_feedback.gd` → `ui/`（或新建 `scenes/hud/`） |
| 4.3 | **`.tscn` 命名约定反转为 snake 同名** | 现状 20 个里只有 5 个 Pascal（`Level0`/`Player`/三个 `Enemy*Bird`），README 与 naming 计划却都写着「保持 PascalCase」。**建议改约定而不是改 19 个文件**：`.tscn` 一律 snake、与其 `.gd` 同名 |
| 4.4 | 同一概念两套命名 | `scenes/pvp_game.tscn` 的脚本是 `pvp_client.gd`（**不成对**），而 `royale_game.tscn` ↔ `royale_game.gd` 成对 → 二选一统一 |
| 4.5 | 文件名与 `class_name` 不符 / 缩略语三套写法 | `server/ai_player.gd` 的 `class_name AINavigator`；缩略语现状 `HUD`（`ui/hud.gd`）/`PvpHud`/`AIInputSource` 三种 → 定一条规则（建议驼峰 `Hud`/`Ai`） |
| 4.6 | **`core/` 分目录** | 27 个条目混 4 类关注点（几何模拟/网络/配置/表现）→ `core/{sim,net,config,present}/`。**最后做**：autoload 路径在 `project.godot`，动它要同步 4 处 |

## 阶段 5：巨型函数（**等没有并发分支时做**，成本合计 ~6 天）

> **本节已于 2026-09-14 重排（用户裁定）**，依据一次按「净代码行（剔注释与空行）+ 单函数占文件比例」的重测。
> **数字口径更正**：本节此前引用的行数是**函数跨度**（含注释与空行），在本仓这种高注释密度下虚高 30~40%。实测净代码：
> `player.gd::_physics_process` 205→**143**；`enemy_black_bird::_ai` 146→**133**；`enemy_fly_bird::_ai` 124→**108**；
> `royale_lobby::_build_create_panel` 120→**102**；`main_menu::_build_new_ui` 100→**77**；`enemy_logic_smoke::_initialize` 851→**737**。
> 同理 `match_host.gd` 的「706 行」净代码只有 535、最长函数 48 行、35 个函数 —— 它是**职责宽**不是**函数深**（见 5.6）。

| 序 | 项 | 位置 | 成本 |
|---|---|---|---|
| **5.1** | ★ **`tests/enemy_logic_smoke.gd::_initialize` 净 737 行，占该文件 95%** —— 全仓最长函数，且该文件 53 次提交是**全仓改动最频繁的文件**。杠杆最高的一条，故从原 5.3 提到首位：最热文件 + 最极端巨型函数 + 纯测试无行为风险 | `tests/enemy_logic_smoke.gd` | 1~2 天。按已有的章节注释切分（AI/LOS/环面/武器/碰撞各成 `_phase_*()`），`_initialize` 只留顺序调用 |
| 5.2 | **H5** `player.gd::_physics_process` 净 **143 行**（占文件 33%），且倒地物理与正常物理**逐句复制** | `scenes/player/player.gd:150-352` | 1 天。拆 `_tick_downed`/`_tick_water_and_climb`/`_tick_vertical`/`_tick_horizontal`/`_tick_pose_and_collision`/`_tick_slide_reactions` + 公用段 `_apply_grounded_physics(delta, brake_rate)`。**改前先看 `tests/player_contract_smoke.gd` 断言了什么**（源码级契约守卫） |
| 5.3 | **M10** 三个敌人 `_ai` 巨型 `match` 单函数（净 **133** / **108** / 67 行，占各自文件 44% / 33% / 68%） | `enemy_black_bird.gd`、`enemy_fly_bird.gd`、`enemy_jump_bird.gd` | 各半天。每个状态一个 `_tick_<state>(delta, dist)`，`_ai` 只留 `match` 派发（约 20 行）。**与「睡眠/唤醒上提」(5.8) 不重叠**——本条只按 state 切函数 |
| **5.4** | ★ **探针里的巨型函数**（本次重测新增，此前完全没登记）：`tests/feedback_probe.gd::_ready` 净 **159 行占该文件 88%**；`tests/perf_probe.gd::_initialize` 净 **177 行占 65%**；`tests/kh_l3_visual_probe.gd::_ready` 84；`tests/kh_l3_probe.gd::_check_reload_state_machine` 78 | `tests/` | 共 1 天。探针无行为风险，适合作为「先练手」的一批 |
| 5.5 | 三个 UI 构建巨型函数（`royale_lobby._build_create_panel` 净 102、`main_menu._build_new_ui` 净 77、`royale_hud._ready` 67 + `_on_round_state` 74、`matchmaking._build_options_panel` 62） | — | 1~2 天。**排在 3.7（UiFactory 补齐）之后**，否则会重复造包装 |
| **5.6** | ★ **`server/match_host.gd` 按职责分文件**（**改法变更**：不是拆函数 —— 它净 535 行 / 35 个函数 / 最长仅 48 行，形状是「宽」不是「深」）。按域切：快照广播 · 子弹与爆炸裁决 · 回合状态机 · 玩家建/复活 | `server/match_host.gd` | 1 天 |
| 5.7 | `core/maze_generator.gd` 委托式拆 `grid_pathfinder.gd` + `map_format.gd`（净 478 / 33 函数 / 最长 48 —— 同样偏「宽」）；`match_host.gd` 的 `ENABLE_BIRDS=false` 鸟链搬到 `server/bird_roster.gd` | — | 1 天 |
| **—** | ~~`weapon_base.gd` 拆 `weapon_preview.gd` + `weapon_reload.gd`~~ **★ 已撤销（2026-09-14）** | — | **不做**。实测净 361 行 / 32 个函数 / 最长仅 **30 行**，是全仓形状最好的大文件之一（那 543 原始行里 132 行是注释 + 一批 `@export`）。拆完只会多两个薄文件、少一层 `@export` 就近可读性 —— 收益为负 |
| 5.8 | 旧编号批次 7：睡眠/唤醒状态机上提 | `enemy_fly_bird.gd:75-91` 等三处同构 | 半天。**必须先显式化** `enemy_base.gd:175` 的隐式契约——`_is_far_sleeping()` 硬编码 `state != 0`，隐含「所有子类 `State.SLEEP == 0`」 |
| 5.9 | `core/` 输入源三件套的语义错位 | `core/input_source.gd`、`core/prediction_rollback.gd:22,107-115` | 半天。基类改 `PlayerInput` 纯接口（`source_kind() -> int` 枚举），本地实现独立成 `local_input_source.gd`；`NetworkInputSource` → `PacketInputSource`。**排在 Task 4 之后**（同文件，且 Task 4 刚把 `_*_raw` 钩子立起来） |

**「宽 vs 深」的判据**（本节重排的依据，供后续评估复用）：文件大而最长函数 ≤50 行 → 是**职责宽**，应按域**分文件**，拆函数的收益低；最长函数占文件 ≥30% → 是**函数深**，应**先拆函数**。前者如 `match_host.gd`(48)/`maze_generator.gd`(48)/`weapon_base.gd`(30)，后者如 `player.gd`(33%)/`enemy_black_bird.gd`(44%)/`enemy_jump_bird.gd`(68%)。

**已撤销的处置**：`weapon_base.gd` 的拆分（见上）。**未采用**：把 `tests/` 整体瘦身（11702 行 vs 生产 14693 行，测试几乎和生产一样多）—— 测试的「大」危害小（读者少、改者少），只处理其中真正极端的 5.4。

## 阶段 6：测试脚手架（可随时插入，与上面都不冲突）

| 序 | 项 | 成本 |
|---|---|---|
| 6.1 | `tests/lib/scan_util.gd` + `probe_base.gd` —— `kh_l*_probe` 的扫描工具函数已复制 5 遍。**注意** `kh_l5_probe.gd:44` 的 `ALL_DIRS` **含 `res://tests`**，新增的 lib 源码不得含被扫的字面量（如非 16 倍数字号） | 半天 |
| 6.2 | `level_editor/sync-tiles.js` 加 `--check` 模式（改了 `data/tile_defs.json` 忘跑脚本会静默漂移）；`sync-enemies.js` 同 | 1 小时 |

---

## 排序依据速查

**为什么 H2/H4/M4/M6/M7/M21 排第一批**：这六项是同一类——*文档/注释/契约承诺了某件事，实现没做到（或反过来）*。它们单个都不致命，加起来是这个仓库目前最大的可维护性负担，而且**改说辞的成本最低**（多数只需改文字）。先清干净，后面拆分时才不会一边拆一边被错信息带偏。

**为什么 M9 必须排在阶段 3 之前**：它是唯一「不修就再也发现不了」的一条。`royale_c2_watcher` 的 A② 靠扫 `royale_game.gd` 整个文件里有没有 `alive` 来守「C2 下不许把 `round_state.alive` 当第二条权威入口」；代码搬进共享基类后该文件里自然就没有了 → 门恒绿。**它自己只防了「读不到源文件」，没防「代码搬走了」。**

**为什么 M4c 和 M3 需要你先决策**：M4c 的 `RoomManager` 用 `multiplayer` 与 `get_tree()`，搬进 `RefCounted` 会立刻断；M3 是「AI 对战房要不要留在注册表里」的产品选择。两者都不是纯搬迁。

**为什么阶段 5 排在最后**：它们都不出错，只是「以后改起来疼」，且会与阶段 3/4 动同一批文件。等前面落定再动，避免同一批文件被改两遍。
