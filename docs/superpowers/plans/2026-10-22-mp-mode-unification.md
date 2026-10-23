# 三模式联机统一 + 模块化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 1v1 / 3v3 / 大乱斗的重复实现收敛到单一来源，并把三个巨型脚本（`pvp_match_client.gd` 66KB、`mp_lobby.gd` 60KB、`lobby_rooms.gd` 45KB）按职责拆成小文件；协议与玩家可见行为不变。

**Architecture:** ①新增 `core/mp/`（模式描述/房间规则/选项/argv 上下文，全部纯函数、可 `-s` 测）；②客户端基类保留编排、把拾取/拆砖/结算拆成组合件；③大厅三个 Room 类合并为 `RoomTypes`（带 mode）+ `RoomRegistry`，`LobbyRooms` 退化为门面；④服务端只在入口做 `ModeContext` 收口，6 层对局链不动。

**Tech Stack:** Godot 4.7.1 标准版 / GDScript；测试 = `-s` 冒烟（`extends SceneTree`）+ 场景探针 + 真链路 `.sh`；判据一律 grep 文本。

**Spec:** `docs/superpowers/specs/2026-10-22-mp-mode-unification-design.md`（本计划按评审追加要求扩展了两处：**B 批准执行**、**新增模块化拆分**）

## Global Constraints

- **协议零变化**：RPC 名/通道号/字段、worker argv、房间号空间、端口池、结算列集都不改。
- **行为零变化**：改完三模式真链路判决与改前**同形**（3v3 现状为 `TEAM MATCH PROBE: 3 条失败`，全部在探针相③；不要求转绿）。
- **模式语义保持三分**（1v1 三局两胜/击杀复位、3v3 换边与队分、大乱斗死斗无 ACS）。
- 新 `-s` 冒烟必须带 `EXPECTED_CHECKS` 条数闸；每条断言要能回答"去掉什么才会红"。
- 禁止 `RegEx`（导出模板关掉该模块）。
- `--` 之后的开关才算数；`-s` 脚本一律套外层 `timeout`。
- 逐文件 `git add`；新 `.gd` 连 `.gd.uid` 一起加；每个 Task 一个 commit。
- 草稿/临时探针只放 `.superpowers/bughunt/tmp/`，不进 `tests/`。
- 与另一条工作线冲突时**以本计划为准**（用户 2026-10-22 裁定）；提交前 `git status` 核对，不带走别人的 hunk。

## 进度(2026-10-22)

- ✅ **Task 1–11 全部完成**:`core/mp/` 四模块 / 客户端 round_state 模板 + 结算页·拾取·拆砖三组件 / 大厅 Room(mode)+RoomRegistry 门面 / `mp_lobby` 四面板 / 服务端散点与输入队列拆件。
- ✅ 单进程全绿:allscript **190(0 失败)**、`mode_*`/`net_diag`/`room_registry` 共 6 支冒烟、`replica_smoothness`/`resync_world`/`tile_collision` 三支探针、`room_sweep_lint` **10 项**、`check_naming` OK。
- ✅ 真链路回归(持锁串行):1v1 三支 `SMOKE PASS`/`SMOKE PASS`/`REJOIN PROBE: ALL-OK(5)`;大乱斗 4 人 `SOAK: ALL-OK(4/4)`;9 人 `ROLE CAP PROBE: ALL-OK(9/9)`(**X1 端到端已修**);3v3 `TEAM MATCH PROBE: ALL-OK`(子弹穿透半边实际验到;榴弹半边因枪种抽签跳过,见 known-red 2026-10-23 补记)。
- ✅ 新增真链路守卫 `tests/probe/royale_role_cap_probe.sh`(9 人档,钉 role 上界,已进 `run_real.sh` 的 `ENTRIES`)。
- ✅ **Task 12 收档完成**:全量真链路批与文档同步(落点/注释漂移/known-red 补记/allscript 条数闸 190)。

## Review Focus

1. **大厅端口归还/回收梯**（B 合并表最危险）：`teardown_room` 三态、`_release_port_later`（120s/360s）、`_reclaim_finished_matches` 必须逐条保持；错一处=端口永久占用。
2. **换局复位顺序**：客户端"清子弹 → 复位砖 → 拉 match_sync"的相对顺序是 3v3 承重顺序，拆件时必须逐字搬。
3. **3v3 第二条 MATCH_OVER 载荷**：`team_game` 刻意没有 `and not _match_ended` 闸；模板化后仍必须每次刷新结算页。
4. **重连窗口**：`reconnect` 状态机留在基类不拆（本轮只拆拾取/拆砖/结算），避免把"先置 `_resync_pull_pending` 再拉"的时序拆散。
5. **`-s` 可加载性**：`core/mp/` 不得在文件层引用 autoload（`GameParameters`/`NetBus`/`PvpSession`），否则 `-s` 冒烟 `load()` 到空成员、断言被静默跳过（本仓踩过）。

---

## 文件结构（先定边界，再派任务）

**新增 `core/mp/`（纯函数，无 autoload 静态引用）**
| 文件 | 职责 | 关键接口 |
|---|---|---|
| `core/mp/mode_defs.gd` | 模式常量与表：ID、显示名、角色上界、选项键、结算列 | `MODE_IDS`、`ROLE_MAX`、`OPTION_KEYS(mode)`、`RESULT_COLUMNS(mode)` |
| `core/mp/mode_room_rules.gd` | 房间规则纯函数 | `min_players/max_players/team_size/needs_teams/start_allowed/port_return_seconds/visible_in_match/freeze_roster` |
| `core/mp/mode_options.gd` | 选项下发（按模式取键） | `build(mode: String, snapshot: Dictionary) -> Dictionary` |
| `core/mp/mode_context.gd` | worker argv 解析 + 校验（含 X1 role 上界） | `from_args(args: PackedStringArray) -> Dictionary`（`ok/error/…`） |

**大厅（B）**
- 新增 `server/lobby/room_types.gd`（`Room` 带 `mode` + 各模式附加字段）、`server/lobby/room_registry.gd`（注册表/房号/冻结名单/按 mode 列表）。
- `server/lobby/lobby_rooms.gd` 退化为门面（目标 < 15KB），公开符号（`rooms`/`royale_rooms`/`team_rooms` 的读取点）改成 `registry.of(mode)`，**外部调用点逐个改**。

**客户端拆分**
- 新增 `scenes/mp_client/pickup_sync.gd`（拾取节点/提示/事件/诊断）、`scenes/mp_client/tile_sync.gd`（拆砖订阅/补态）、`scenes/mp_client/result_screen.gd`（结算挂载/刷新/离场）。
- `scenes/pvp_match_client.gd` 只留编排 + `_on_round_state` 模板 + 钩子；目标 < 30KB。
- 三个子类只剩：`_ready` 装配、`_on_countdown_round` 钩子、`_result_payload`、队色覆写。

**UI / 服务端后续拆分（P3，B 稳定后）**
- `scenes/mp_lobby/`：`create_panel.gd` / `room_list.gd` / `wait_room.gd` / `options_form.gd`。
- `server/hosts/team_spawn.gd` / `royale_spawn.gd`（散点/队层/复活选格从 Host 抽出）。
- `server/match/input_intake.gd`（队列/丢包/netstat 从 `match_host.gd` 抽出）。

---

## 任务

### Task 1: `core/mp/mode_defs.gd`（模式表单一来源）

**Files:** Create `core/mp/mode_defs.gd`; Test `tests/smoke/mode_defs_smoke.gd`
**Interfaces:** `ModeDefs.MODE_PVP/MODE_ROYALE/MODE_TEAM: String`（值必须等于 `PvpSession.MODE_*` 的 `"pvp"/"royale"/"team"`）、`MODE_IDS: Array[String]`、`ROLE_MAX := 16`、`TEAM_SIZE := 3`、`TEAM_COUNT := 2`、`OPTION_KEYS(mode) -> Array[String]`、`RESULT_COLUMNS(mode) -> Array[String]`、`LABEL(mode) -> String`
**Steps:**
- [ ] 写失败冒烟：`MODE_IDS` 恰 3 项且等于 `["pvp","royale","team"]`；`ROLE_MAX==16`；`OPTION_KEYS("team")` **不含** `disabled_weapons` 且含 `hue`；`RESULT_COLUMNS("pvp")==["kills","deaths","dealt","taken","acs"]`、`("team")` 含 `assists`、`("royale")` 不含 `acs`；未知 mode 返回空表（`_chk` + `EXPECTED_CHECKS`）
- [ ] 跑冒烟确认红（`class_name` 未定义）
- [ ] 实现 `mode_defs.gd`（纯常量 + `match` 分派；不引 autoload）
- [ ] 跑绿；`allscript_probe` 条数闸同步（+1，见 Task 12 统一处理）
- [ ] commit `feat(mp): ModeDefs —— 三模式常量/选项键/结算列单一来源`

### Task 2: `core/mp/mode_context.gd`（argv 解析 + X1 收口）

**Files:** Create `core/mp/mode_context.gd`；Modify `server/server_main.gd:35-110`（解析段）；Test `tests/smoke/mode_context_smoke.gd`
**Interfaces:** `ModeContext.from_args(args: PackedStringArray) -> Dictionary`：键 `ok:bool, error:String, worker:bool, royale:bool, team:bool, port:int, roles:Array[int], ai_roles:Array[int], teams:Array[int], team_of:Dictionary`；`ROLE_MAX` 取 `ModeDefs.ROLE_MAX`
**Steps:**
- [ ] 失败冒烟：`--royale --team` ⇒ `ok=false`；`--team --roles 1,2 --teams 1` ⇒ `ok=false`（不等长）；`--royale --roles 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16` ⇒ `roles.size()==16`（X1 回归）；`--roles 0,17` ⇒ 被丢/报错（按实现二选一，测试锁定）；`--port 7999` ⇒ `port==7999`；`--worker` ⇒ `worker=true`
- [ ] 跑红 → 实现 → 跑绿
- [ ] `server_main.gd` 改为调用 `ModeContext.from_args` 并从返回字典落字段（行为逐字不变；`push_error`/`quit(1)` 保留在原位）
- [ ] `allscript` 绿；commit `refactor(server): argv 解析收进 ModeContext（role 上界单一来源）`

### Task 3: `core/mp/mode_room_rules.gd`（房间规则表）

**Files:** Create `core/mp/mode_room_rules.gd`；Test `tests/smoke/mode_room_rules_smoke.gd`
**Interfaces:** `min_players(mode)->int`（pvp 2 / royale 2 / team 6）、`max_players(mode)->int`（pvp 2 / royale 16 / team 6）、`team_size(mode)->int`（team 3，其余 0）、`needs_teams(mode)->bool`、`start_allowed(mode, humans:int, teams:Dictionary)->bool`、`port_return_seconds(mode)->float`（pvp 120 / royale 360 / team 360）、`visible_in_match(mode)->bool`（true）、`freeze_roster(mode)->bool`（true）
**Steps:** 失败冒烟（表逐值 + `start_allowed` 边界：3v3 5 人 false、6 人 true；大乱斗 2 人 true）→ 实现 → 跑绿 → commit `feat(mp): ModeRoomRules —— 房间规则表`

### Task 4: `core/mp/mode_options.gd`（选项下发按模式取键，修 X5）

**Files:** Create `core/mp/mode_options.gd`；Modify `scenes/lobby_page.gd:337`、`scenes/mp_lobby.gd:1027-1037`；Test `tests/smoke/mode_options_smoke.gd`
**Interfaces:** `ModeOptions.build(mode: String, snapshot: Dictionary) -> Dictionary`；snapshot 键 = `hue/round_full_heal/disabled_weapons/match_time/map/time`（调用方从 `Settings` 组装）
**Steps:**
- [ ] 失败冒烟：pvp 含 `disabled_weapons`；**team 不含**；royale 含 `match_time`、pvp 也含（现状）但 team 不含 `time`（现状：team 的 `time` 走 beta 分支，按现行为锁定）；未知 mode 返回基础表
- [ ] 实现后改 `_player_options()`：先组 snapshot，再 `ModeOptions.build(PvpSession.room_mode/_current_mode, snapshot)`
- [ ] 跑绿；3v3 的 `match_sync.options` 不含该键（真链路判据见 Task 12）
- [ ] commit `fix(lobby): 选项下发按模式取键（3v3 不再上发禁用武器）`

### Task 5: 客户端 `_on_round_state` 模板化

**Files:** Modify `scenes/pvp_match_client.gd`（新增模板 + 钩子）、`scenes/pvp_game.gd:134-157`、`scenes/royale_game.gd:185-205`、`scenes/team_game.gd:303-334`；Test `tests/probe/round_state_template_probe.tscn`（新）
**Interfaces:** 基类 `_on_round_state(data)`；钩子 `_on_countdown_round(round:int)`、`_on_match_over_extra(data)`、`_result_payload(data) -> Dictionary`
**Steps:**
- [ ] 失败探针：三模式各起一个 `PvpMatchClient` 壳（真实 Level0 世界），喂 COUNTDOWN(round=2) 与 MATCH_OVER 两帧，断言：①子弹清空；②砖复位被调用一次；③输入锁刷新；④结算页 `visible`；⑤**再喂第二条 MATCH_OVER 仍刷新**（`_show_result` 的"挂载一次、每次刷新"）
- [ ] 跑红 → 把三份公共段搬进基类（顺序逐字保持）→ 子类改钩子
- [ ] 三模式真链路同形（Task 12 统一跑）
- [ ] commit `refactor(mp-client): round_state 四态收进基类模板，三子类只留钩子`

### Task 6: 拆 `result_screen.gd`（结算挂载/离场）

**Files:** Create `scenes/mp_client/result_screen.gd`；Modify `scenes/pvp_match_client.gd:521-550`（`_show_result`/`_build_result_payload`/离场）
**Interfaces:** `ResultScreen.bind(client, payload_builder: Callable, leave_scene: Callable)`；`show(payload) -> void`；`is_shown() -> bool`
**Steps:** 失败探针（同 Task 5 的 ⑤ 与 ESC 离场）→ 实现 → 跑绿 → commit `refactor(mp-client): 结算页挂载/离场拆成 ResultScreen`

### Task 7: 拆 `pickup_sync.gd` + `tile_sync.gd`

**Files:** Create `scenes/mp_client/pickup_sync.gd`、`scenes/mp_client/tile_sync.gd`；Modify `scenes/pvp_match_client.gd`（拾取/拆砖两段）
**Interfaces:** `PickupSync.bind(client)` + `on_spawned/on_removed/tick`；`TileSync.bind(client)` + `on_cell/on_sub`
**Steps:** 现有 `1v1-subcell-ghost` 探针 + `--diag` 事件名作为回归（事件名不变）→ 实现 → 跑绿 → commit `refactor(mp-client): 拾取/拆砖拆成组合件`

### Task 8: 大厅 `room_types.gd`（B 第一步：三 Room 合一）

**Files:** Create `server/lobby/room_types.gd`；Modify `server/lobby/lobby_rooms.gd:26-100`（三类定义）
**Interfaces:** `class_name RoomTypes` 内 `Room`：`mode:String`、`code`、`host_peer`、`players:Array`、`player_role:Dictionary`、`in_match`、`worker_port`、`worker_pid`、`roster`、`created_at`、`is_public`、`invite_code`、`team_of`、`max_players`、`beta`、`time_rules`；`is_team()/is_royale()/is_duel()`
**Steps:** 失败冒烟（构造三种 mode 的 Room，断言字段默认值与 `mode` 判定）→ 实现 → 改 `lobby_rooms.gd` 内部引用 → 默认批绿 → commit `refactor(lobby): Room 加 mode，三房型合并`

### Task 9: 大厅 `room_registry.gd`（B 第二步：三表合一 + 门面）

**Files:** Create `server/lobby/room_registry.gd`；Modify `server/lobby/lobby_rooms.gd`（门面化）、`server/lobby/room_manager.gd`（调用点）、`tools/room_sweep_lint.gd`（改读表）
**Interfaces:** `RoomRegistry.of(mode) -> Dictionary`（只读）、`add/erase/find(code)`、`next_code()`、`freeze_roster(room)`、`list_payload(mode)`、`teardown_room(room, reason, ...)`（保留三态端口归还语义）
**Steps:**
- [ ] 失败冒烟（纯逻辑，不碰端口）：同一 code 空间下三种 mode 不串；`find` 按 mode 过滤；`of(mode)` 只读
- [ ] 实现 + `LobbyRooms` 门面（`rooms`/`royale_rooms`/`team_rooms` 外部读取点改 `of()`）
- [ ] `room_sweep_lint` 绿（它钉"端口归还/注册表删除只在两处"）
- [ ] 真链路三模式跑批（Task 12）
- [ ] commit `refactor(lobby): 三张房间表合并为 RoomRegistry，LobbyRooms 退化为门面`

### Task 10: 拆 `mp_lobby` 四个面板

**Files:** Create `scenes/mp_lobby/create_panel.gd`、`room_list.gd`、`wait_room.gd`、`options_form.gd`；Modify `scenes/mp_lobby.gd`（只留编排与 RPC）
**Steps:** 先做纯搬运（节点路径/信号不变）→ `bash tests/smoke/pvp_room_smoke.sh` + 大乱斗/3v3 真链路同形 → commit `refactor(lobby-ui): mp_lobby 拆四面板`

### Task 11: 服务端 Host 拆散点/输入队列

**Files:** Create `server/hosts/team_spawn.gd`、`server/hosts/royale_spawn.gd`、`server/match/input_intake.gd`；Modify `team_host.gd`/`royale_host.gd`/`match_host.gd`
**Steps:** 纯函数搬出（散点/队层/复活选格；队列/丢包/netstat）→ 现有探针绿（`tile_collision_probe`/`replica_smoothness_probe`/真链路同形）→ commit `refactor(mp-server): 散点与输入队列拆成模块`

### Task 12: 守卫、lint 与真链路回归（每阶段收尾）

**Files:** `tests/smoke/*`（新增 4 支）、`tools/room_sweep_lint.gd`、`tests/probe/allscript_probe.gd`（条数闸）、`docs/eng/tests.md`、`docs/eng/modes.md`（只改"实现落点"表述）
**Steps:**
- [ ] `bash tests/run_all.sh --only mode_` ⇒ 全绿
- [ ] `python tools/check_naming.py` ⇒ OK
- [ ] 真链路串行：`pvp_match_smoke`、`pvp_room_smoke`、`rejoin_probe`、`royale_soak_probe 4`、`team_match_probe`（判据=与改前同形；3v3 仍是探针相③ 红）
- [ ] 收尾：无残留 Godot、7777/端口池空、锁释放
- [ ] commit `test(mp): 统一重构的守卫与真链路回归存档`

---

## 执行顺序与并行建议

1. 串行：Task 1 → 2 → 3 → 4（纯模块，互相依赖小，但都要先进 `core/mp/`）。
2. 之后可并行：Task 5/6/7（客户端）与 Task 8/9（大厅）**不共享文件**，可派两个执行者；Task 10/11 在各自主线稳定后做。
3. Task 12 在每批结束都跑一次（不只最后）。
4. 每批结束更新 spec 的"实际落点"与本计划的勾选；`docs/eng/modes.md` 的 Q&A 式表述同步（实现位置变了，语义没变）。

## Self-Review

- **Spec 覆盖**：A1(Task 4)、A2(Task 5)、A3(Task 9 的 `_enter_check` 表)、A4(Task 2)、A5(Task 1 的 `RESULT_COLUMNS` + Task 5 的 `_result_payload`)、B(Task 8/9)、模块化(Task 6/7/10/11)。**B 的六个入口收敛**拆在 Task 9（`LobbyRooms` 门面里统一入口），未单列任务 —— 若 Task 9 过大，执行时拆成 9a/9b。
- **类型一致性**：`ModeDefs.MODE_*` 字符串值与 `PvpSession.MODE_*` 相同；`ModeRoomRules.port_return_seconds` 单位秒；`ModeOptions.build` 返回完整 options 字典。
- **Review Focus 覆盖**：端口归还（Task 9 + lint）、换局顺序（Task 5 探针）、第二条 MATCH_OVER（Task 5 ⑤）、重连不拆（文件结构已注明）、`-s` 可加载性（Task 1-4 均为纯文件）。
- **比例**：本计划约 1.3 倍 spec 长度，步骤留给执行者决策、不抄实现。
