# 继承链拆解 + 服务端/客户端结构对齐 实施计划（2026-11-04）

> 对象：① `MatchState → MatchGround → MatchSnapshot → MatchCombat → MatchRound → MatchHost`（6 个域文件的一条链）+ `TeamHost` / `RoyaleHost`；② `LobbyPage ← MpLobby`（单叶基类）；③ `EnemyFlyBase ← EnemyFlyBird`（单叶基类）。
> 背景 = [`docs/eng/netplay.md`](../../eng/netplay.md) 的「权威宿主的继承链」；零守卫登记 = [`registered-debt.md`](../../eng/registered-debt.md)。
> **裁定（2026-11-04，用户）：大改也拆，并且服务端与客户端结构对齐。**
> 结论：**域逻辑一律组合件（RefCounted + `bind(host)`），继承只留"模式子类"这一条真轴**；服务端链 `7 项目层 → 2 项目层`（`Node ← MatchHost ← TeamHost|RoyaleHost`），与客户端 `Node2D ← PvpMatchClient ← pvp_game|royale_game|team_game` 同构。

## 1. 目标结构（两侧同构）

```
客户端（现状，作为对齐基准）                     服务端（本次目标）
Node2D PvpMatchClient                            Node MatchHost
  ├ 共享状态（_local/_world/_replicas…）            ├ 共享状态（players/input_sources/grid/_ack_seq/_stats…）
  ├ 编排（_physics_process/_ready…）                ├ 编排（_init/_ready/_physics_process）
  ├ 虚钩子（7 个，三模式覆写）                       ├ 虚钩子（模式差异，TeamHost/RoyaleHost 覆写）
  └ 组合件（RefCounted + bind）                     └ 组合件（RefCounted + bind）
      TileSync / PickupSync / ResultScreen               GroundSync / SnapshotTx
      ReconnectDriver / ReplicaSet / TimeFx              CombatArbiter / RoundFlow
     （+ InputUplink 等 core 侧件）                      （+ InputIntake / TickTiming 已有）

pvp_game | royale_game | team_game               TeamHost | RoyaleHost
  （薄子类：只覆写宿主钩子）                          （薄子类：只覆写宿主钩子）
```

**六条对齐规则**（拆完后写进 `docs/eng/netplay.md`，替代今天"链的四条物理定律"）：

1. **模式差异只许出现在薄子类**：`TeamHost` / `RoyaleHost`（以及客户端的三个 game 场景）只覆写宿主虚钩子，不放域逻辑。
2. **域逻辑一律组合件**：新增/迁移的域 = 新文件 `XxxSync`（`class_name` 蛇形 = 文件名，`extends RefCounted`），**不许再靠 `extends` 分文件**。
3. **组合件契约（4.7.1 实测：GDScript 类之间允许循环引用）**：`var host: MatchHost = null` + `func bind(host: MatchHost, 显式依赖…)` —— 宿主与组件互相持**类型化**引用合法（本地实测 `HostCycle ↔ CompCycle` 互相 typed 引用+跨类读私有成员通过）；共享引用仍以参数交进来，不造单例。
4. **状态归属**：跨域状态留在宿主（玩家表 / 输入表 / 网格 / 统计 / tick 账本）；域内状态放组件（地面武器表 / 快照 diag 计数 / 仲裁缓存 / 回合闸）。
5. **创建方式一致**：宿主 `_ensure_xxx()` 懒建或 `_ready` 建一次 + `bind(self)`（客户端现有写法）；组件不自己找宿主。
6. **调用方向**：宿主 → 组件、组件 → 宿主都是**静态调用**（typed 引用），模式差异仍走宿主虚钩子（`TeamHost`/`RoyaleHost` 覆写）；热循环把数据以类型化参数取到组件内再用（见 §4）。

## 2. 阶段 1/2：先清链造成的错（不阻塞拆解，可与阶段 3 并行）

**阶段 1 清错（档 2，T1.1~T1.6）** 与 **阶段 2 去重（T2.1~T2.3）**：

| ID | 改法 | 文件 | 验收 | 档 |
|---|---|---|---|---|
| T1.1 | `_host: Node` → `MatchHost`；三个 `start_on` 返回类型改 `-> MatchHost`；删 8 处恒真 `has_method`；4 处真模式判别改 `is TeamHost`/`is RoyaleHost` | `server/server_main.gd:5`、`server/match/match_bootstrap.gd`、`server/hosts/{team,royale}_host.gd` | 默认批 + `pvp_match_smoke` | 2 |
| T1.2 | `MatchState` 加 `reset_time_rewind_state()` 空实现、`MatchHost` 覆写；删 `match_round.gd:182-183` 反向 `has_method`+`call` | `server/match/{match_state,match_round,match_host}.gd` | 默认批 + 换局重置真链路 | 2 |
| T1.3 | 删死开关 `adjudicate_exact_only`（零写入）及其实参 | `server/match/match_combat.gd:9,109` | 默认批（`bullet_sweep_probe`） | 2 |
| T1.4 | 端口延迟三常量搬 `core/mp/mode_defs.gd`，`worker_launcher` 反向引 core，删 `mode_room_rules.gd` 包装 | `core/mp/{mode_room_rules,mode_defs}.gd`、`server/lobby/worker_launcher.gd` | 默认批 + 真链路建房 | 2 |
| T1.5 | 删死字段 `_options`（仅赋值无读取） | `server/match/{match_state,match_host}.gd` | 默认批 | 2 |
| T1.6 | 删两个叶子冗余 `_on_bullet_hit` 覆写（幂等）；**先**把基类写点注释改成"三模式唯一写端" | `server/hosts/{team,royale}_host.gd`、`server/match/match_combat.gd` | 结算页 `dealt/taken` 三模式各一条（真链路） | 3 |
| T2.1 | COUNTDOWN 分支（`match_round.gd:65-90` ↔ `team_host.gd:234-257`，约 28 行逐字）提成 `MatchRound._countdown_step()` | `server/match/match_round.gd`、`server/hosts/team_host.gd` | `down_edge_probe` + `countdown_clock_smoke` + `team_match_probe` | 2 |
| T2.2 | `_respawn_player` 的 6 行 meta 清理、`request_suicide_role` 13 行上提；自杀用虚钩子 `_suicide_enabled()`（默认 false，两模式 true）保 1v1 不响应 K | `server/match/{match_round,match_host}.gd`、两个模式宿主 | `down_edge_probe` + 真链路 | 3 |
| T2.3 | 上提纪律落纸：剔除注释后逐字相同 ⇒ 上提；只多 1-2 行或语义不同 ⇒ 留两份并注原因 | 本文 + `docs/eng/netplay.md` | 文档评审 | 1 |

> 顺序：T1.3/T1.4/T1.5（零行为）→ T1.2 → T1.1 → T2.x。**T1.6 和 T2.x 若与拆解步骤撞同一函数，合并进对应 S 步做，避免两次重写。**

## 3. 阶段 3：拆解（每步一个提交、可单独 revert、每步跑默认批）

| 步 | 动作 | 验收 | 档 | 依赖 |
|---|---|---|---|---|
| **S0** | 基线：默认批判词 + `--diag` 的 O0 tick 分段计时（`adjudicate/own_snap/world_snap/rewind`）+ `--list` 形状 + `EXPECTED_SCRIPTS=243` 记进计划附录 | 全部数值留档，供 S1~S4 对比 | — | — |
| **S1** | `MatchSnapshot`(113 行/3 函数/6 diag 字段) → 组件：`extends MatchState` → `extends RefCounted`；`var _host: Node` + `bind(host)`；`_tx_*` 字段留下；方法内直读宿主状态改 `_host.players` 等动态访问（方法体逻辑不动）。`MatchCombat extends MatchSnapshot` → `extends MatchState`。`MatchHost` 加 `_snapshot`、`_init` 里 bind、两处调用点改 `_snapshot.broadcast()/send_own()` | 默认批 48 支全绿 + `snapshot_size_probe` + O0 对比（Δ≤5%）；真链路里程碑 M1 时补 | 3 | S0 |
| **S2** | `MatchCombat`(342 行/18 函数) → 组件：同上；`_on_bullet_hit` 基类实现移到 `MatchHost` 成为虚方法（叶子覆写 + `super` 行为不变）；State helper 调用改 `_host._role_of(...)` 等动态调用。`MatchRound extends MatchCombat` → `extends MatchState`。`MatchHost` 加 `_combat`、替换调用点、`TileDefs.on_destroyed` 回调注册改 `_combat._on_tile_destroyed` | 默认批 + `rollback_fidelity_probe` + `bullet_sweep_probe` + **真链路 M1：`pvp_match_smoke`（需认领 7777）** + O0 | 3 | S1 |
| **S3** | `MatchGround`(363 行/21 函数，含 6 域字段) → 组件：字段整体搬进组件；`_host` 动态访问宿主（`_rpc_all`/`grid`/`players`/`_disabled_weapons`）；`MatchHost` 加 `_ground`、替换 4 处调用点；`RoundFlow` 拆分前先让 `MatchRound` 里对 Ground 的两处调用改 `_host._ground.xxx` | 默认批 + `ground_weapon_field_smoke` + 真链路（拾取/落定，随 M1） | 3 | S2 |
| **S4** | `MatchRound`(307 行/19 函数) → `RoundFlow` 组件 + **合并 `MatchState` 进 `MatchHost`**（全部共享字段/方法搬入，`MatchHost extends Node`；`_spawn_cell`/`role_spawns` 等钩子成为 `MatchHost` 虚方法）。模式钩子仍定义在 `MatchHost`、叶子覆写；`_physics_process` 依次调 4 个组件 | 默认批 + `down_edge_probe` + **真链路 M2：`pvp_match_smoke` + `team_match_probe`（需认领）** + O0 + 两种模式手工冒烟 | 3 | S3 |
| **S5** | 客户端侧对齐（typed 绑定）：把 `scenes/mp_client/` 六件套与 `core/net/input_uplink.gd` 的 `var _client: Node` + `bind(client: Node)` 改成 typed `PvpMatchClient`（循环引用已实测可行），顺带消掉 `_client.get("_rollback")` 这类字符串访问；三模式场景确认只覆写 `PvpMatchClient` 虚钩子、无域逻辑残留；客户端 6 件套与 `_ensure_*` 接线写成 `docs/eng/netplay.md` 的对齐表。若发现客户端仍用 `extends` 塞域逻辑（如时间玩法块），登记为后续独立任务 | 对齐表 + `menu_autotest` / `pvp_match_smoke` 不回归 | 2 | S4 |
| **S6** | 命名与文档收口：组件改名为对齐客户端风格（`ground_sync.gd`/`snapshot_tx.gd`/`combat_arbiter.gd`/`round_flow.gd`，`class_name` 蛇形），同批更新所有 docs/eng 引用与按路径读源码的探针（`rollback_fidelity_probe` 读 `match_combat.gd`/`match_host.gd` 的取数点）；`netplay.md` 链一节改写成「宿主 + 组合件」；`registered-debt` 零守卫面更新；删本计划 §1 的旧四条定律 | `check_naming` 全绿 + 默认批 + **真链路 M3：`pvp_match_smoke` + `team_match_probe`（认领）** + 全仓 grep 零悬空 | 3 | S4 |

**里程碑与off-ramp**：M1 = S2 后（链剩 `Node←State←Ground←Round←Host←leaves`），M2 = S4 后（目标形态达成），M3 = S6 后（命名/文档收口）。任一 S 步失败 → 单独 revert 该提交；S4 失败回退到 M1 形态也仍比现状浅 3 层。

## 4. 性能红线（拆解最大的真实风险）

- **热路径**（`_adjudicate_bullets` 逐子弹、`_replay_hurt_rect` 回放、快照打包逐玩家）：组件化后调用仍是"静态 + 一次虚分派"（与现状相同），但热循环仍应把 `players` / 子弹数组 / 受击面缓存以**类型化参数**传进组件（别在循环里反复走宿主成员查找），组件内用局部类型化变量。
- 每次拆步后跑一次 **O0 tick 分段计时**（`--diag`，同图同人数同子弹量）并与 S0 基线比：单段 Δ > 5% 即视为回归，先优化到 ≤5% 再提交。
- `perf_probe` 与导出批的服务端 tick 预算（60Hz 16.67ms）同为参考线。
- 快照包长/编码字节数必须逐字节不变（`snapshot_size_probe` 钉着），组件化不许顺手改线格式。

## 5. 验收与纪律

- 档 3：每条承重断言**逐条变异**（改坏某条必须红）+ 真链路跑批（**占 7777 / 拉子进程，跑前必须让用户认领**）+ 逐任务评审；默认批每步全绿。
- 判据一律 grep 该支自打的 `OK`/`ALL-OK`；退出码不算。
- 不新增"读源码文本判形态"守卫（`test-economy` §4 已裁定）；组件化后的结构靠 §1 六条规则 + 评审，零守卫面登记进 `registered-debt`。
- 每步独立提交、逐文件点名 `git add`、不 `git add -A`（多会话共用工作树）；提交前逐 hunk 认领。
- 不改 `PROTO_VERSION`、不改端口常量、不改线格式、不顺手改 `PvpMatchClient` 上帝对象与 `Level0` 静态全局（另案）。

## 6. 单叶基类（与拆解并行，纯搬移）

| ID | 对象 | 方案 A（推荐） | 方案 B（冻结） |
|---|---|---|---|
| T3.1 | `LobbyPage ← MpLobby`（496 行基类 + 8 抽象桩，仅 1 子类） | 合并回 `mp_lobby.gd`，删 `lobby_page.gd` | 保留拆分，抽象桩改默认空实现 + 标"单实现" |
| T3.2 | `EnemyFlyBase ← EnemyFlyBird`（181 行，仅 1 子类） | 合并：`EnemyFlyBird extends EnemyBase` | 保留 + 删"预支抽象"注释 |
| T3.3 | 规则 | 新增基类必须 ≥2 真子类或有明确在飞计划（写进 `netplay.md`） | — |

## 7. 不做（明确排除）

- 不推倒重写 `MatchHost` 以外的系统；不顺手重排目录。
- 不给单叶基类补第二个"假子类"。
- 不把客户端 `PvpMatchClient`（937 行）与 `Level0` 静态全局塞进本计划——它们是"上帝对象 / 全局状态"，另案。
- 不动真链路 3 支与 K3 承重守卫（上一轮刚削过）；不在拆解中改玩法/数值/协议。

## 8. 任务汇总与窗口需求

| 阶段 | 任务 | 档 | 真链路认领 |
|---|---|---|---|
| 1 清错 | T1.1~T1.5 | 2 | T1.1 需要一次窗口 |
| 1 清错 | T1.6 | 3 | 是 |
| 2 去重 | T2.1 / T2.2 / T2.3 | 2/3/1 | T2.1/T2.2 需要 |
| 3 拆解 | S0（基线） | — | 否 |
| 3 拆解 | S1 | 3 | 否（默认批 + O0） |
| 3 拆解 | S2（M1） | 3 | 是（`pvp_match_smoke`） |
| 3 拆解 | S3 | 3 | 是（随 M1 一起） |
| 3 拆解 | S4（M2） | 3 | 是（`pvp_match_smoke` + `team_match_probe`） |
| 3 拆解 | S5 | 2 | 否（默认批 + `menu_autotest`；客户端不改协议） |
| 3 拆解 | S6（M3） | 3 | 是（同 M2） |
| 6 单叶 | T3.1~T3.3 | 1 | 否（默认批 + 手工冒烟） |

**建议执行顺序**：S0 →（T1.3/T1.4/T1.5 零行为小手术）→ S1 → T1.2/T1.1 → S2/T1.6 → S3 → S4/T2.1/T2.2 → S5 → S6；单叶基类 T3.x 可随时并行。

## 附录 A：S0 基线（2026-11-04 捕获）

- 默认批：`RUN_ALL OK(48 runs / 402 gated-assertions)`，known-red 基线 0 条；枚举 51 = `smoke/*.gd` 32 + `probe/*.tscn` 16 + 无 tscn 的 `probe/*.gd` 3；排除 3 支真链路（`pvp_match_smoke.gd` / `rejoin_probe.tscn` / `team_match_probe.tscn`）。
- `tracked .gd = 243`（`EXPECTED_SCRIPTS` 同值）。
- 链文件 LOC：`match_state` 432 · `match_ground` 363 · `match_snapshot` 113 · `match_combat` 342 · `match_round` 307 · `match_host` 517 · `team_host` 432 · `royale_host` 258；链上 6 域文件合计 2,074 行，加两宿主 2,764 行。
- O0 tick 分段计时（`--diag` 的 `adjudicate/own_snap/world_snap/rewind`）：**待 M1 真链路窗口采集**（需认领 7777 + 对局）；采集后贴进本节，S1~S4 每步对比，单段 Δ > 5% 视为回归。
- 拆解后自检口径不变：默认批 48 支全绿、`snapshot_size_probe` 字节数不变、`rollback_fidelity_probe` 34 条不断言少跑、真链路里程碑判词 `SMOKE PASS` / `TEAM MATCH PROBE: ALL-OK`。

## 附录 B：GDScript 语言特性实证（2026-11-04，Godot 4.7.1 本机实测）

> 一次性的探针脚本放在 `tests/_gdtest/`，跑完即删；`tests/_gdtest/` 不进任何批。

| # | 问题 | 实测 | 结论 |
|---|---|---|---|
| L1 | 两个 `class_name` 类互相持有类型引用 | `CycleA`(`var b: CycleB`) ↔ `CycleB`(`var a: CycleA`) 加载并运行 OK | **允许**（循环引用限制主要针对 `.tscn` 场景；脚本/类可以） |
| L2 | 宿主 `Node` ↔ 组件 `RefCounted` 互相 typed 引用，且组件读宿主私有成员 | `HostCycle`(`var comp: CompCycle`) ↔ `CompCycle`(`var host: HostCycle`) 运行 OK，跨类读 `host._secret` = 7 | **允许** ⇒ 组件可直接持 typed 宿主，不需要"`Node` + 动态访问"方案 |
| L3 | `Node` 类型变量上访问未声明成员 | `--check-only` 通过；客户端现有 `_client._world` 在生产运行 | 允许（unsafe access，warning 级），但**没有拼写保护** |
| L4 | typed 类上访问不存在成员是否编译期报错 | `h.no_such_member` 的 `--check-only` 通过，运行期才报错 | **不能靠 typed 抓拼写**；组件契约靠默认批 + 探针 + 评审 |
| L5 | `@abstract` 抽象类 / 抽象方法（Godot 4.5+） | `@abstract class_name` / `@abstract func` 可解析；实例化 = `Parse Error: Cannot construct abstract class` | **可用**；但 `MatchHost` 1v1 要实例化 ⇒ 整类不能 abstract（要"必须覆写"的钩子只能加一层 abstract 基类，不采用） |
| L6 | GDScript 接口 / 协议 | 无（proposals 仍开放） | 组合 + typed 循环引用是当前语言下的正统解 |
| L7 | 新增 `class_name` 的全局类缓存 | 新类要先 `--import` 扫一遍，否则别的脚本报 `Could not find type` | 本仓已有此约定（`Player` 加 class_name 时同款）；拆解每步跑默认批即可 |

**对计划的影响（已合并进 §1/§3/§4）**：

- 组件契约从"`Node` + 动态访问"升级为"**typed `MatchHost`**"：静态调用、无 unsafe 警告；客户端 S5 同步改成 typed 绑定，两侧同一套写法。
- 因为 L4（typed 也抓不住拼写错误），每条拆步不能只靠类型系统，必须真跑默认批 + 承重探针；`rollback_fidelity_probe` 等按路径读源码的取数点在同批更新。
- 场景 ↔ 脚本的循环依赖仍是禁区：`MatchHost` 由代码 `new()`（不是 `.tscn`）；若某个组件 preload 了含宿主脚本的场景，需单独确认——每步的 `--import` + `allscript_probe` 会暴露加载失败。
- 备选记录（不采用）：用 `@abstract` 中间基类强制模式钩子覆写 —— 会让链多一层，与"缩到 2 层"目标冲突。

参考：[cyclic dependencies 讨论（脚本/类可循环）](https://forum.godotengine.org/t/understanding-unsupported-cyclic-dependencies/142828/3)、[unsafe property/method access 警告提案](https://github.com/godotengine/godot-proposals/issues/13316)、[抽象类 4.5+ 说明](https://github.com/jame581/godotprompter/blob/main/skills/gdscript-patterns/references/abstract-classes.md)、[GDScript 接口提案（未实现）](https://github.com/godotengine/godot-proposals/issues/8943)。
