# 继承链拆解 + 服务端/客户端结构对齐 实施计划（C 方案：薄壳宿主 + 上下文/端口 + 系统）

> 对象：① `MatchState → MatchGround → MatchSnapshot → MatchCombat → MatchRound → MatchHost` 这条链 + `TeamHost` / `RoyaleHost`；② `LobbyPage ← MpLobby`；③ `EnemyFlyBase ← EnemyFlyBird`。
> 背景 = [`docs/eng/netplay.md`](../../eng/netplay.md) 的「权威宿主的继承链」；零守卫登记 = [`registered-debt.md`](../../eng/registered-debt.md)。
> **裁定（2026-11-04/05，用户）：大改也拆；服务端与客户端结构对齐；采用 C 方案（上下文 + 系统 + 薄壳）。**
> 结论：`extends` 只留"模式子类"这一条真轴；域逻辑全部改成**只依赖「状态 + 端口」的系统**；宿主退化成薄壳。服务端链 `7 项目层 → 2 项目层`，客户端同构改造。

## 1. 目标结构（两侧同构）

```
服务端（目标）                                      客户端（目标，同构对齐）
Node MatchHost（壳）                               Node2D PvpMatchClient（壳）
  ├ state: MatchState    (RefCounted 数据+纯查询)      ├ state: ClientState   (RefCounted 数据)
  ├ ports: MatchPorts    (Callable 效果/模式钩子)       ├ ports: ClientPorts   (Callable 效果)
  ├ ground: GroundSystem    ← bind(state, ports)      ├ tile_sync: TileSync      ← bind(state, ports)
  ├ snapshot: SnapshotSystem                          ├ pickup_sync: PickupSync
  ├ combat: CombatSystem                              ├ result_screen / reconnect_driver
  ├ round: RoundSystem                                ├ replica_set / time_fx
  └ 生命周期/输入 FIFO/每帧顺序/模式虚钩子实现           └ 生命周期/输入上行/场景接线/模式虚钩子实现
TeamHost | RoyaleHost（薄子类，只覆写壳的虚钩子）     pvp_game | royale_game | team_game（同上）
```

**七条规则**（拆完写进 `docs/eng/netplay.md`，替代现有"链的四条物理定律"）：

1. **`extends` 只留模式子类**：`TeamHost` / `RoyaleHost` 与客户端三个 game 场景只覆写壳的虚钩子，不放域逻辑。
2. **域逻辑 = 系统**：一个域一个文件 `<域>_system.gd`（`class_name XxxSystem extends RefCounted`），`bind(state, ports)` 后由壳按固定顺序调用；**不许再靠 `extends` 分文件**。
3. **系统只依赖 `state` + `ports`**：不持有 `MatchHost`/`PvpMatchClient` 引用，不 `get_tree()`、不直接碰 `NetBus`/`multiplayer`；需要宿主行为时走端口 Callable。
4. **`state` = 纯数据 + 纯查询**：只读写自身数据、不做网络/场景/引擎调用；公共可读字段与查询方法（`role_of` / `same_team` / `stat_entry` / `spawn_tables`…）都住这里。
5. **`ports` = 效果与模式钩子**：`net_rpc_all` / `net_rpc_peer` / `notify_direct_hit` / `broadcast_round_state` / `match_winner` / `spawn_cell` / `respawn_player` / `down_killer_of` / `award_down` / `finish_match` / `on_bullet_hit` / `start_next_round` / `reset_time_rewind_state`；全部 Callable，`bind` 时 `assert(ports.is_ready())`。**禁止把宿主自身塞进 `state` 或别的成员**（那是把 C 退回 A）。
6. **状态归属三分表**：跨域共享可变状态 → `state`；域内缓存/计数器 → 系统；Node 生命周期与网络落点 → 壳。
7. **依赖是 DAG，不靠"类循环引用"**：`state → 无`、`ports → 无`、`系统 → state+ports`、`壳 → 全部`。GDScript 允许类循环（实测见附录 B），但本架构**故意不用**——导出/工具链更稳，也是"更合理"的核心。

## 2. 阶段 1/2：先清链造成的错（不阻塞拆解，可与阶段 3 并行）

| ID | 改法 | 文件 | 验收 | 档 |
|---|---|---|---|---|
| T1.1 | `_host: Node` → `MatchHost`；三个 `start_on` 返回类型改 `-> MatchHost`；删 8 处恒真 `has_method`；4 处真模式判别改 `is TeamHost`/`is RoyaleHost` | `server/server_main.gd:5`、`server/match/match_bootstrap.gd`、`server/hosts/{team,royale}_host.gd` | 默认批 + `pvp_match_smoke` | 2 |
| T1.2 | `MatchState` 加 `reset_time_rewind_state()` 空实现、`MatchHost` 覆写；删 `match_round.gd:182-183` 反向 `has_method`+`call`（C 完成后这条自然变成端口） | `server/match/{match_state,match_round,match_host}.gd` | 默认批 + 换局重置真链路 | 2 |
| T1.3 | 删死开关 `adjudicate_exact_only`（零写入）及其实参 | `server/match/match_combat.gd:9,109` | 默认批（`bullet_sweep_probe`） | 2 |
| T1.4 | 端口延迟三常量搬 `core/mp/mode_defs.gd`，`worker_launcher` 反向引 core，删 `mode_room_rules.gd` 包装 | `core/mp/{mode_room_rules,mode_defs}.gd`、`server/lobby/worker_launcher.gd` | 默认批 + 真链路建房 | 2 |
| T1.5 | 删死字段 `_options`（仅赋值无读取） | `server/match/{match_state,match_host}.gd` | 默认批 | 2 |
| T1.6 | 删两个叶子冗余 `_on_bullet_hit` 覆写（幂等）；**先**把基类写点注释改成"三模式唯一写端" | `server/hosts/{team,royale}_host.gd`、`server/match/match_combat.gd` | 结算页 `dealt/taken` 三模式各一条（真链路） | 3 |
| T2.1 | COUNTDOWN 分支（`match_round.gd:65-90` ↔ `team_host.gd:234-257`，约 28 行逐字）提成 `RoundSystem` 的 `_countdown_step()`；`TeamHost` 覆写改调用 | `server/match/match_round.gd`、`server/hosts/team_host.gd` | `down_edge_probe` + `countdown_clock_smoke` + `team_match_probe` | 2 |
| T2.2 | `_respawn_player` 的 6 行 meta 清理、`request_suicide_role` 13 行上提进系统/壳；自杀用虚钩子 `_suicide_enabled()`（默认 false，两模式 true）保 1v1 不响应 K | 系统文件 + 壳 + 两个模式宿主 | `down_edge_probe` + 真链路 | 3 |
| T2.3 | 上提纪律落纸：剔除注释后逐字相同 ⇒ 上提；只多 1-2 行或语义不同 ⇒ 留两份并注原因 | 本文 + `docs/eng/netplay.md` | 文档评审 | 1 |

> **T1.6 与 T2.x 若与拆解步骤撞同一函数，合并进对应 S 步做**（避免同一段代码重写两次）。建议顺序：T1.3/T1.4/T1.5 → S0.5 → S1 → T1.2/T1.1 → S2/T1.6 → S3 → S4/T2.1/T2.2 → S5 → S6。

## 3. 阶段 3：拆解（每步一个提交、可单独 revert、每步跑默认批）

| 步 | 动作 | 验收 | 档 | 依赖 |
|---|---|---|---|---|
| **S0** | 基线（**已捕获**，见附录 A） | 数值留档 | — | — |
| **S0.5** | **端口层**：新建 `server/match/match_ports.gd`（`class_name MatchPorts extends RefCounted`，13 个 Callable + `is_ready()`）；`MatchHost` 建 `_ports` 并把 `_rpc_all`/模式钩子/广播绑上；**不改任何调用点**，只加 `MatchHost.ports()` 访问口与 assert | 默认批 48 支全绿（零行为变化） | 2 | S0 |
| **S1** | **SnapshotSystem**：`match_snapshot.gd` 113 行 → `server/match/snapshot_system.gd`（`extends RefCounted`，`bind(state, ports)`；`_tx_*` 计数器自带）；`MatchCombat extends MatchSnapshot` → `extends MatchState`；`MatchHost` 加 `_snapshot`、两处调用点改 `_snapshot.broadcast()/send_own()`；`match_snapshot.gd` 删除；同批改 props/docs 引用 | 默认批 + `snapshot_size_probe`（字节不变）+ O0 对比 Δ≤5% | 3 | S0.5 |
| **S2** | **CombatSystem**：`match_combat.gd` 342 行 → `combat_system.gd`；`_on_bullet_hit` 基类实现移到 `MatchHost`（虚方法，叶子覆写 + `super` 不变），系统经 `ports.on_bullet_hit` 调用；State helper 改 `state.xxx`；`MatchRound extends MatchCombat` → `extends MatchState`；`TileDefs.on_destroyed` 回调注册改指向宿主（宿主再转系统） | 默认批 + `rollback_fidelity_probe` + `bullet_sweep_probe` + **真链路 M1：`pvp_match_smoke`（需认领 7777）** + O0 | 3 | S1 |
| **S3** | **GroundSystem**：`match_ground.gd` 363 行 → `ground_system.gd`（6 个域字段搬进系统）；`MatchRound` 的两处 Ground 调用改 `_ground.xxx()`；`MatchHost` 4 处调用点同步 | 默认批 + `ground_weapon_field_smoke` + 真链路（随 M1） | 3 | S2 |
| **S4** | **RoundSystem**：`match_round.gd` 307 行 → `round_system.gd`（回合机/复活/每局复位/1v1 计分）；`MatchHost extends Node`，`_physics_process` 依次调 4 系统；模式钩子全部留在壳、叶子覆写、经端口供系统调用 | 默认批 + `down_edge_probe` + **真链路 M2：`pvp_match_smoke` + `team_match_probe`（需认领）** + O0 + 手工冒烟 | 3 | S3 |
| **S4b** | **砍链根**：`match_state.gd` 从 `extends Node` 改为 `extends RefCounted`（纯 `state`：字段 + 纯查询；`_rpc_all` 等引擎效果搬壳走端口）；`MatchHost extends Node` 持有 `var state`；全仓 `self.xxx` → `state.xxx` 机械替换（仅 `server/match/**` + 两宿主） | 默认批 + 同 M2 真链路 + `EXPECTED_SCRIPTS` 更新 | 3 | S4 |
| **S5** | **客户端对齐**：新建 `scenes/mp_client/client_state.gd`（`_local/_world/_replicas/_names/_last_snap_tick/_time_*…` 数据）与 `client_ports.gd`（`tint_of/apply_tint/enter_scene/leave_scene/set_status/pull_resync…`）；六件套 `bind(state, ports)` 取代 `bind(client: Node)`；`PvpMatchClient` 退化为壳（生命周期/输入上行/场景接线/模式虚钩子）；三模式子类保持只覆写钩子；顺带消掉 `_client.get("_rollback")` 字符串访问 | `menu_autotest` + `pvp_match_smoke`（**M3，需认领**）+ 进入三种模式各一次手工冒烟 | 3 | S4b |
| **S6** | **收口**：`match_state.gd` 可选改名 `match_context.gd`（若改名：class_name/文件/全仓引用同批）；`netplay.md` 链一节改写为「壳 + 状态/端口 + 系统」七规则 + 客户端对齐表；`registered-debt` 零守卫面更新；删本计划中已过时的旧定律；全仓 grep 零悬空；`check_naming` 全绿 | 默认批 + **真链路 M3** | 1 | S5 |

**里程碑 / off-ramp**：M1 = S2 后（链只剩 `Node←State←Ground←Round←Host←leaves`，快照已系统化）；M2 = S4b 后（目标形态达成：`Node ← MatchHost ← Team/Royale` + 4 系统）；M3 = S6 后（文档/命名收口 + 客户端对齐）。任一步失败 → 单独 revert；S4 失败可回退到 M1（仍比现状浅 3 层）。

## 4. 性能红线（拆解最大的真实风险）

- 系统调用是**静态调用**（typed `state`/`ports` 字段），与现状"一次虚分派"同量级；端口 `Callable.call` 只用于**事件级**（命中、广播、回合事件），不进逐子弹/逐玩家循环。
- 热路径（`_adjudicate_bullets`、`_replay_hurt_rect`、快照打包）：把 `players` / 子弹数组 / 受击面缓存以**类型化参数**传进系统方法，系统内用局部类型化变量。
- 每步后跑 `--diag` 的 **O0 tick 分段计时**（同图同人数同子弹量）对比 S0/M 基线：单段 Δ > 5% 视为回归，先优化 ≤5% 再提交。
- `perf_probe` 与服务端 60Hz 预算（16.67ms/tick）同为参考线；快照包长必须逐字节不变（`snapshot_size_probe`）。

## 5. 验收与纪律

- 档 3：每条承重断言**逐条变异** + 真链路跑批（**占 7777 / 拉子进程，跑前必须让用户认领**）+ 逐任务评审；默认批每步全绿。
- 判据一律 grep 该支自打的 `OK`/`ALL-OK`；退出码不算。
- 不新增"读源码文本判形态"守卫（`test-economy` §4 已裁定）；架构规则靠文档 + 评审，零守卫面登记进 `registered-debt`。
- 每步独立提交、逐文件点名 `git add`、不 `git add -A`；提交前逐 hunk 认领（多会话共用工作树）。
- 不改 `PROTO_VERSION` / 端口常量 / 线格式；不在拆解中改玩法、数值、协议。

## 6. 单叶基类（与拆解并行，纯搬移）

| ID | 对象 | 方案 A（推荐） | 方案 B（冻结） |
|---|---|---|---|
| T3.1 | `LobbyPage ← MpLobby`（496 行基类 + 8 抽象桩，仅 1 子类） | 合并回 `mp_lobby.gd`，删 `lobby_page.gd` | 保留拆分，抽象桩改默认空实现 + 标"单实现" |
| T3.2 | `EnemyFlyBase ← EnemyFlyBird`（181 行，仅 1 子类） | 合并：`EnemyFlyBird extends EnemyBase` | 保留 + 删"预支抽象"注释 |
| T3.3 | 规则 | 新增基类必须 ≥2 真子类或有明确在飞计划（写进 `netplay.md`） | — |

## 7. 不做（明确排除）

- 不推倒重写本计划之外的系统；不重排目录；不给单叶基类补"假子类"。
- 不为"模式"再抽策略对象（`TeamHost`/`RoyaleHost` 与客户端三场景子类保留——这是与客户端对齐的那条轴；策略化另案）。
- 不把客户端 `PvpMatchClient` 里剩余的时间玩法块、`Level0` 静态全局塞进本计划（另案）。
- 不动真链路 3 支与 K3 承重守卫（上一轮刚削过）。

## 8. 任务汇总与窗口需求

| 阶段 | 任务 | 档 | 真链路认领 |
|---|---|---|---|
| 1 清错 | T1.1~T1.5 | 2 | T1.1 需一次窗口 |
| 1 清错 | T1.6 | 3 | 是 |
| 2 去重 | T2.1 / T2.2 / T2.3 | 2/3/1 | T2.1/T2.2 需要 |
| 3 拆解 | S0（基线）、S0.5（端口层） | —/2 | 否 |
| 3 拆解 | S1 | 3 | 否（默认批 + O0） |
| 3 拆解 | S2（M1） | 3 | 是（`pvp_match_smoke`） |
| 3 拆解 | S3 | 3 | 是（随 M1） |
| 3 拆解 | S4 / S4b（M2） | 3 | 是（`pvp_match_smoke` + `team_match_probe`） |
| 3 拆解 | S5（M3，客户端对齐） | 3 | 是（`pvp_match_smoke`） |
| 3 拆解 | S6（M3 收口） | 1 | 随 M3 |
| 6 单叶 | T3.1~T3.3 | 1 | 否（默认批 + 手工冒烟） |

## 附录 A：S0 基线（2026-11-04 捕获）

- 默认批：`RUN_ALL OK(48 runs / 402 gated-assertions)`，known-red 0 条；枚举 51 = `smoke/*.gd` 32 + `probe/*.tscn` 16 + 无 tscn 的 `probe/*.gd` 3；排除 3 支真链路（`pvp_match_smoke.gd` / `rejoin_probe.tscn` / `team_match_probe.tscn`）。
- `tracked .gd = 243`（`EXPECTED_SCRIPTS` 同值）；拆解会新增 `match_ports.gd`（+1）与客户端两个 `client_*.gd`（+2）⇒ S6 时把 `EXPECTED_SCRIPTS` 更新到 **246**，并在 `allscript_probe.gd` 的注释里记一行。
- 链文件 LOC：`match_state` 432 · `match_ground` 363 · `match_snapshot` 113 · `match_combat` 342 · `match_round` 307 · `match_host` 517 · `team_host` 432 · `royale_host` 258；6 域文件合计 2,074 行，加两宿主 2,764 行。
- O0 tick 分段计时（`--diag` 的 `adjudicate/own_snap/world_snap/rewind`）：**待 M1 真链路窗口采集**；采集后贴进本节，S1~S4 每步对比，单段 Δ > 5% 视为回归。
- 拆解后自检口径不变：默认批 48 支全绿、`snapshot_size_probe` 字节不变、`rollback_fidelity_probe` 34 条不断言少跑、真链路判词 `SMOKE PASS` / `TEAM MATCH PROBE: ALL-OK`。

## 附录 B：GDScript 语言特性实证（2026-11-04，Godot 4.7.1 本机实测）

> 探针脚本放 `tests/_gdtest/`，跑完即删，不进任何批。

| # | 问题 | 实测 | 结论 |
|---|---|---|---|
| L1 | 两个 `class_name` 类互相持有类型引用 | `CycleA ↔ CycleB` 加载并运行 OK | **允许**（场景才有限制；脚本/类可以） |
| L2 | `Node` 宿主 ↔ `RefCounted` 组件互相 typed 引用、跨类读私有成员 | `HostCycle ↔ CompCycle` OK，`host._secret` = 7 | **允许** |
| L3 | `Node` 类型变量上访问未声明成员 | `--check-only` 通过（生产客户端也这么写） | 允许（unsafe access，warning 级），无拼写保护 |
| L4 | typed 类上访问不存在成员是否编译期报错 | `h.no_such_member` 的 `--check-only` 通过，运行期才报 | **不能靠 typed 抓拼写**；靠默认批 + 探针 + 评审 |
| L5 | `@abstract`（4.5+） | 可解析；实例化抽象类 = `Parse Error: Cannot construct abstract class` | 可用；但 `MatchHost` 1v1 要实例化 ⇒ 整类不能 abstract |
| L6 | 接口 / 协议 | 无（proposals 仍开放） | 组合 + 窄依赖是当前语言下的正统解 |
| L7 | 新增 `class_name` 的全局类缓存 | 需先 `--import`，否则别的脚本报 `Could not find type` | 本仓已有约定（`Player` 同款） |

**对 C 方案的影响**：C **故意不使用类循环引用**（依赖是 DAG：系统 → state/ports；壳 → 全部）。L1/L2 只作为"如果需要也可以"的备选记录；L4 说明拆解每步必须真跑默认批与承重探针，不能靠类型系统兜底；L5 说明"必须覆写"的强制只能用文档/守卫，不用 abstract 基类（会多加一层）。

参考：[cyclic dependencies 讨论（脚本/类可循环）](https://forum.godotengine.org/t/understanding-unsupported-cyclic-dependencies/142828/3)、[unsafe property/method access 警告提案](https://github.com/godotengine/godot-proposals/issues/13316)、[抽象类 4.5+ 说明](https://github.com/jame581/godotprompter/blob/main/skills/gdscript-patterns/references/abstract-classes.md)、[GDScript 接口提案（未实现）](https://github.com/godotengine/godot-proposals/issues/8943)、[FCIS in Godot（纯核 + 壳）](https://dev.to/sammburr/fcis-in-godot-2433)、[Godot DI 模式（循环依赖反模式）](https://github.com/jame581/GodotPrompter/blob/3dfd9425/skills/dependency-injection/SKILL.md)。
