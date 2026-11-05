# 继承链治理实施计划（2026-11-04）

> 对象：① `MatchState → MatchGround → MatchSnapshot → MatchCombat → MatchRound → MatchHost`（6 个域文件的一条链）+ `TeamHost` / `RoyaleHost`；② `LobbyPage ← MpLobby`（单叶基类，8 个 `push_error` 抽象桩）；③ `EnemyFlyBase ← EnemyFlyBird`（单叶基类，预支抽象）。
> 背景与四条物理定律 = [`docs/eng/netplay.md`](../../eng/netplay.md) 的「权威宿主的继承链」；零守卫登记 = [`registered-debt.md`](../../eng/registered-debt.md)。
> **结论先行**：这条链的角色是**文件拆分器**，不是抽象阶梯。本轮目标是**消除它造成的具体错误 + 禁止再长层**，不是推平它——推平在 GDScript 里没有干净解（§5，已裁定不做）。

## 1. 判定口径（什么才值得改）

| 判定 | 特征 | 处置 |
|---|---|---|
| **伪继承（域切片）** | 中间层零生命周期钩子、零 `is` 判别、从不被单独实例化 | 不动结构；只修它造成的具体错误（§2/§3） |
| **真类型** | ≥2 个真子类、有虚钩子覆写、`super` 协作 | 保留（`MatchHost ← TeamHost\|RoyaleHost`、`PlayerInput ← Local\|Packet\|Ai`） |
| **单叶基类** | 只有 1 个真子类 + 抽象桩 / 预支抽象 | **合并或冻结**（§4） |
| **纯方法袋** | 无自有业务状态（`MatchSnapshot` 6 字段全是 diag 计数） | 不改位置；只按 §2 修错 |

## 2. 阶段 1：清错（P0，全部档 2，可并行，每项一个提交）

| ID | 改法 | 文件 | 验收 | 预估 |
|---|---|---|---|---|
| **T1.1** | `_host` 类型化：`var _host: Node` → `MatchHost`；三个 `start_on` 返回类型 `-> Node` 改 `-> MatchHost`。删 8 处**恒真** `has_method`（`_broadcast_round_state` / `is_match_over` / `role_spawns` / `mark_client_ready` / `ground_weapons_payload` / `destroyed_cells` / `damaged_partial_subs`）；4 处真模式判别改 `is TeamHost` / `is RoyaleHost`（`mark_disconnected` / `team_map` / `request_suicide_role` / `set_display_names`） | `server/server_main.gd:5`、`server/match/match_bootstrap.gd`、`server/hosts/team_host.gd`、`royale_host.gd` | 默认批全绿；`pvp_match_smoke`（真链路，需认领） | S |
| **T1.2** | 下沉空实现：`MatchState` 加 `func reset_time_rewind_state() -> void: pass`，`MatchHost` 覆写；删 `match_round.gd:182-183` 唯一的反向 `has_method`+`call` | `server/match/match_state.gd`、`match_round.gd`、`match_host.gd` | 默认批 + 换局后回溯环复位（真链路回溯支需认领） | S |
| **T1.3** | 删死开关 `adjudicate_exact_only`（全仓只声明 + 一处读取、零写入），连带去掉 `HitShape.candidate_hits` 的那个实参 | `server/match/match_combat.gd:9,109` | 默认批（`bullet_sweep_probe` 等价性） | S |
| **T1.4** | 端口延迟三常量搬 `core/mp/mode_defs.gd`，`worker_launcher.gd` 反向引 core，删 `mode_room_rules.gd` 这层包装（core 不再反向依赖 server） | `core/mp/mode_room_rules.gd`、`core/mp/mode_defs.gd`、`server/lobby/worker_launcher.gd` | 默认批（`room_view_smoke`）+ 真链路建房 | S |
| **T1.5** | 删死字段 `MatchState._options`（仅 `match_host.gd:21` 赋值、全仓零读取） | `server/match/match_state.gd:86`、`match_host.gd:21` | 默认批 | XS |
| **T1.6** | 去掉冗余覆写：`TeamHost._on_bullet_hit` / `RoyaleHost._on_bullet_hit` 与基类逐字同写（幂等），删两份叶子覆写；**先**把基类写点注释改成"三模式唯一写端"防误删 | `server/hosts/team_host.gd:430`、`royale_host.gd:230`、`match_combat.gd:271` | **档 3**：结算页 `dealt/taken` 三模式各一条（真链路需认领） | S |

> 建议顺序：T1.3/T1.4/T1.5（零行为）→ T1.2 → T1.1 → T1.6（承重，最后做）。

## 3. 阶段 2：去重（P1，档 2/3，同一 bug 只该修一次）

| ID | 改法 | 挡什么 | 验收 |
|---|---|---|---|
| **T2.1** | `_match_round_tick` 的 COUNTDOWN 分支（`match_round.gd:65-90` 与 `team_host.gd:234-257` 逐字约 28 行）提成 `MatchRound._countdown_step(delta) -> bool`；`TeamHost` 覆写里改调用，不再抄一遍 | 2026-11-01 用户实见：漏抄就绪闸 ⇒ 对抗开局倒计时从"客户端还在切场景"起算、最后 1 秒被截掉 | `down_edge_probe` + `countdown_clock_smoke` + `team_match_probe`（认领） |
| **T2.2** | 上提两段叶子逐字重复：`_respawn_player` 的 6 行 meta 清理（`team_host.gd:200-206` / `royale_host.gd:238-243`）→ `MatchRound._respawn_player`；`request_suicide_role` 13 行（:396 / :247）→ `MatchHost`，但用虚钩子 `_suicide_enabled()`（默认 false，两模式 true）保住 1v1 不响应 K 键 | 改归因规则/自杀规则要改两个文件；同批已上提的 `_detach_role`/`_finish_match` 与未上提的两段并存（纪律随机） | `down_edge_probe` + `team_match_probe` + `royale` 相关真链路（认领） |
| **T2.3** | 上提纪律落纸（不新增守卫）：判据 = "剔除注释后逐字相同 ⇒ 上提；只多 1-2 行或语义不同 ⇒ 留两份 + 注释说明为什么不合" | 下一次"该不该上提"的临时判断 | 写进本题 + `docs/eng/netplay.md`（如已有则合并） |

## 4. 阶段 3：单叶基类（P1/P2，二选一，砍掉"为 1 个实现抽的基类"）

| ID | 对象 | 方案 A（推荐） | 方案 B（冻结） | 验收 |
|---|---|---|---|---|
| **T3.1** | `scenes/lobby_page.gd`（496 行基类 + 8 个 `push_error("子类必须覆写")` 抽象桩）← 只 `MpLobby` 1 个子类（`9016e0dc` 起另两个大厅页退役） | **合并回 `mp_lobby.gd`**：基类方法/字段整体搬入子类，删 `lobby_page.gd`；`extends Control` 直连 | 保留拆分，但把 8 个抽象桩改成默认空实现，文件头标"当前仅 1 个实现，不构成抽象" | `menu_autotest` + `lobby` 手工冒烟（大厅页无自动行为守卫） |
| **T3.2** | `scenes/enemies/enemy_fly_base.gd`（181 行，覆盖 `_ready` + 10 个方法）← 只 `EnemyFlyBird` 1 个子类 | **合并**：`EnemyFlyBird extends EnemyBase`，基类方法内联；与 `enemy_base.gd` 的 3 个真子类（fly/black/jump）区分开 | 保留，但把"新增飞行敌人再改虚 getter"的预支注释删掉，标"单实现" | `enemy_logic_smoke` + `kh_*` 场景探针 |
| **T3.3** | 规则 | 新增基类必须满足：**≥2 个真子类，或有明确在飞计划**；否则不抽。写进 `docs/eng/netplay.md`「权威宿主的继承链」末段（一行） | — | — |

> T3.1/T3.2 都是**纯搬移**（不改逻辑），但合并后单文件变大；若评审认为"文件过大"优先，则走方案 B。两者都允许只做前半（先删注释/抽象桩），合并留作独立提交。

## 5. 阶段 4：链降维（**裁定不做**，翻案条件见下）

两个方案都评估过：

| 方案 | 做法 | 硬阻塞 | 结论 |
|---|---|---|---|
| A 组件化（客户端式） | `Ground/Snapshot/Combat/Round` 降为 `RefCounted` 组件 + 宿主组合 | GDScript 无接口/前向声明 ⇒ 宿主与组件互相引用**不能静态化**；组件只能 `host: Node` + 鸭子调用（= 今天 `has_method` 同样的信息损失），或退化成内联类（不能跨文件） | 不做：收益只是文件数，代价是静态类型全失 + 3 条机械冻结（`EXPECTED_SCRIPTS`、`check_naming` 规则 B、按路径读源码的探针）全部要改判据 |
| B 合并中间层 | 如 `MatchSnapshot`（113 行/3 函数）并入 `MatchCombat`，链 6→5 | 纯搬移但破坏"按域分文件"的初衷；`extends` 指向要改，按路径读源码的探针会静默失明 | 不做：收益≈0，风险≠0 |

**翻案条件**：① 出现第二个"对局宿主家族"（需要复用这些域）；② GDScript 支持 partial class / mixin / 接口；③ 某个域大到必须独立测试且能给出行为观测面。任一出现再单独立计划（档 3）。

## 6. 守卫与验证纪律（本计划不新增源码文本守卫）

- `test-economy` §4 + 2026-11-02 结构审查已裁定：**不再新增"读源码文本判形态"的守卫**。所以"中间层不得有生命周期钩子"这条规则**只靠文档 + 评审**，不写探针（登记在 `registered-debt` 零守卫面）。
- 档 2：默认批全绿 + **≥1 条承重断言变异**（改坏它必须红）；档 3：逐条变异 + 真链路跑批（**占 7777 / 拉子进程，跑前必须让用户认领**）+ 逐任务评审。
- 判据一律 grep 该支自打的 `OK`/`ALL-OK`，退出码不算。
- 每项独立提交、可单独 revert；提交逐文件点名 `git add`，不 `git add -A`（多会话共用工作树，逐 hunk 认领）。

## 7. 不做（明确排除，防被当漏项）

- 不推平 6 域链（§5）。
- 不给单叶基类补第二个"假子类"，也不为将来"可能"再抽基类。
- 不重排 `server/` 目录、不改 `extends` 指向（会弄瞎按路径读源码的探针）。
- 不顺手改 `PvpMatchClient`（937 行）与 `Level0` 静态全局——它们是另一类问题（上帝对象 / 全局状态），不属于继承链治理。
- 不动真链路 3 支与默认批的 K3 承重守卫（上一轮刚削过）。

## 8. 任务汇总

| 阶段 | 任务 | 档 | 依赖 | 需用户认领 |
|---|---|---|---|---|
| 1 清错 | T1.3 / T1.4 / T1.5 | 2 | 无 | 否 |
| 1 清错 | T1.2 | 2 | T1.3 之后（同文件） | 否 |
| 1 清错 | T1.1 | 2 | 无 | 真链路窗口 |
| 1 清错 | T1.6 | 3 | T1.1 之后（同文件） | 是（真链路） |
| 2 去重 | T2.1 / T2.2 | 2/3 | T1.1 | 是（team/royale 真链路） |
| 2 去重 | T2.3 | 1 | 无 | 否 |
| 3 单叶 | T3.1 / T3.2 | 1（纯搬移） | 无 | 否（走默认批 + 手工冒烟） |
| 3 单叶 | T3.3 | 1 | 无 | 否 |
