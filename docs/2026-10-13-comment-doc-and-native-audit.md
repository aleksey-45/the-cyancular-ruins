# 注释 / 文档 / 拆分 / Godot 内建 —— 全仓审计记录(2026-10-13)

> **这是什么**:一次性审计的**完整记录**。回答三个问题 —— ①哪些注释/文档不规范;②哪些文件过于冗杂该拆;③哪些地方改用 Godot 内建(方法/节点/文件格式)会明显更优。
> **怎么用**:每条都带 `文件:行` 与**复算命令**(附录 A)。引用前先 `grep` 复核 —— 本仓的真相源排序是 **源码 > 探针实测 > `CLAUDE.md`/`docs/eng/` > 其它文档 > `AGENTS.md`**,本文件属于最后两档。
> ★★ **现状追注(2026-10-13 同日)**:本文件是**审计快照**,而它点出的问题**绝大多数已在当天修掉** ——
> §2 的注释瘦身(104 个 `.gd` 压到 ≤15%,见 [`comment-style.md`](eng/comment-style.md) §8 与
> [`comment-diet-ledger.md`](2026-10-13-comment-diet-ledger.md))、§3 的文档失效引用与索引漂移
> (`check_naming` 的规则 C 已扩到 **37 份文档**、`CLAUDE.md` 索引 11 → 25 份、`registered-debt.md` 拆成 8 节)、
> §4 的拆分候选与 §5 的内建替代(结论是**只有 ~6 项该换**)。
> ⇒ **读 §3/§4 时请当"当时的样子"读**;要判断今天是否仍成立,跑附录 A 的复算命令或看
> [`comment-diet-ledger.md`](2026-10-13-comment-diet-ledger.md)。**本文件不追着改** —— 快照的价值正在于它没被改写。
> **没进索引**:本文件**不在** `CLAUDE.md` 的架构索引里(那张表由协调者维护),也没有任何守卫盯着它。
> ★★ **自曝(2026-10-13 已处置)**:本文件一度长到 **64.6 KB**,越过我在 §3.5 用来判 `registered-debt.md` 该拆的那条 **64KB 上下文线**。⇒ 执行记录已按同一判据**拆成独立一份**([`docs/2026-10-13-comment-slimming-batch.md`](2026-10-13-comment-slimming-batch.md)),本文件回到"快照"该有的体量。**再加内容前先想清楚它属于快照还是属于执行记录。**

## 0. 快照、口径与证据分级

| 项 | 值 |
|---|---|
| 快照 | `HEAD = 597037b`(2026-10-13);工作树另有 **2 个非本次修改**(`assets/textures/player.png`、`scenes/player/player.tscn`)—— 那是同仓其它会话的在飞改动,与本审计无关 |
| 规模 | 跟踪文件 **641**:`.gd` 163 / `.md` 164 / `.tscn` 49 / `.js` 16 / `.gdshader` 6 / `.sh` 8 / `.py` 6 / `.tres` 2 / `.cyrm` 2 |
| 行数 | 产品 `.gd` **32,360**;测试 `.gd` **8,480**;`level_editor/` **16,195**(其中 JS **15,946**) |
| 改动 | **零**。审计全程只读;唯一的写入在 `/tmp`(分析脚本与中间输出)。没有跑任何测试批、没有起 Godot、没有占 7777 |

**证据分级**(全文逐条标注):

- ★★ = 我(Lead)在源码/实跑中亲自复核过;
- ★ = 来自并行审计员,我抽验了其中若干条为真(抽验到哪条写明);
- ○ = **仅审计员报告,我未复核** —— 引用前必须自己核。

---

## 1. 结论速览(十二条)

1. ★★ 注释的问题**不是"写得少"或"死代码多"**(注释掉的代码 0、TODO/FIXME/HACK **0**、复读机注释 **0**),而是两头都出了问题:**内容上给自己发假的信用证**(大量注释承诺"改漏了会红",而那个守卫已在 2026-10-09 的测试面削减里删掉 —— 最刺眼的一处 `ui/hud/pvp_hud.tscn:30-31` 写着"改漏了它**响亮地红**,不是静默",现在真的静默),**形式上按"喂给模型"写**(见第 11 条)。
2. ★★ **约四分之一的显式锚点是错的**:注释里 `foo.gd:NNN` 式引用 59 条 → **14 条指错**;`docs/eng/` 抽样 27 条 → **9 条坏(33%)**。同一错锚点常被**抄进多个文件**(`player.gd:191` 一处错,三文件同错)。
3. ★★ **注释承担了 git 的职责**:全仓 **580 行注释带日期戳**;为 1 个常量写 **79 行**历史台账(`allscript_probe.gd:17-95`);文件头写成变更日志(`room_sweep_lint.gd:2-61`)。
4. ★★ **Godot 的文档注释(`##`)基本没用**:163 个 `.gd` 里只有 **34 个**含 `##`(全仓 256 行)⇒ 编辑器 F1/Inspector 里 public API 的文档是空的。这是**零风险**的内建能力。
5. ★★ **文档的失效集中在"测试面削减只清了 8/23 份 `docs/eng/`"**:`tests.md` 点名的 61 个测试/工具文件 **53 个已不存在**;`docs/eng/tools.md:12` 甚至写着"游戏侧今天还读不了 v4"(**与源码相反**,会让人不敢用现行格式)。
6. ★★ **同一事实三处手抄、已漂移**:`ls docs/eng/*.md` = **23**,`CLAUDE.md` 表列 **12**,`check_naming.py:45-48` 写死 **11** ⇒ `netcode-snapshots.md` 的路径今天**无守卫**。`bash tests/run_all.sh` 实际 **14 支**,README/AGENTS 都写 12。
7. ★★ **`registered-debt.md` 已越过 64KB 上下文线**(888 行 / 126,232 B),而它是"动手前先看它"的入口。
8. ★★ **最该拆的不是最大的文件,而是职责最多的文件**:`mp_lobby.gd`(房卡 516 / 等待室 227 / 协议 302 / 转连 126)、`pvp_match_client.gd`(重连 284 / 时间特效 254 / 地面武器 205)、`team_match_watcher.gd`(机器人导航 247 全在测试里)。
9. ★★ **"改用内建"要一件件判,不能一刀切**:真正**明显更优**的只有 6 项(见 §5.1),而**明确不该改**的有 7 项 —— 其中 `collision_builder.gd` 的贪心合并是**内建更差**(Godot `TileSet` 物理层逐 tile、不合并),网络层自研的编码比 `MultiplayerSynchronizer` **好 7 倍**(102 B vs 884 B/包)。
10. ★★ 最大的一笔"重复真相源税"是 `level_editor/` **16,195 行 JS + 一套与 GDScript 平行的格式实现**(`docs/eng/tools.md` 自陈"两边改一处必须同步改另一处");而它换来的"浏览器里能编辑"是**产品决策**,不是技术判断 —— 且当年自研理由里**唯一还硬的那条(逐子格辅码 tint)在游戏侧是死的**(见 §5.2-1)。
11. ★★ **注释是"写给模型看的",不是写给改这行的人看的**(详见 §2.9):① **10,758 处 Markdown 标记**(`**加粗**` 4,935 + 反引号 5,811)写在**哪都不渲染**的地方 —— 引擎帮助渲染的是 BBCode,`.gd` 在 GitHub 上也按代码渲染;注释共 11,502 行,**其中 55% 的行带着这类标记**。② **黑话不展开**:`★` 2,442、`§` 164、`相①~⑤` 111、`Task N` 96、`闸` 92、`收口` 55、`账本` 38、`A 册/B 册` 31、`判词` 22;其中 **12 行引用 `.superpowers/`(gitignore、不入库)**,`B2 甲案` 全仓 **0 命中** ⇒ 有些黑话**在新克隆里根本解不开**。③ **小作文**:注释占 `.gd` **非空行的 32%**,**7 个文件注释行 ≥ 代码行**;`ui/hud/status_banner.gd` 用 **40 行**注释解释一个 `const TOP_OFFSET := 128.0`(内含 3px 字体度量题外话 + 它自己两个已被推翻的旧版本)。
12. ★★ 建议**落纸一份 7 条注释规范**(全文在 §2.9 末尾,可直接抄进 `docs/eng/`),把"不写 Markdown、黑话就地展开、不写过程、单点注释 ≤5 行、旧结论直接删"变成可检查的规则。

---

## 2. 注释不规范

### 2.1 四类结构性问题

| # | 形态 | 最重位置 | 实测 |
|---|---|---|---|
| 1 | **守卫幻觉**(最危险) | `ui/hud/pvp_hud.tscn:9,30-31`、`ui/hud/team_hud.tscn:9,28` | 见 §2.2 |
| 2 | **锚点错**(行号/路径) | `player.gd:184,186`、`climb_component.gd:133`、`swim_component.gd:34` 同错 | 见 §2.3 |
| 3 | **历史台账写进注释** | `tests/probe/allscript_probe.gd:17-95`(79 行) | 见 §2.4 |
| 4 | **文件头缺失/职责不符** | 5 个零头注释 + `scenes/level_0.gd:4` | 见 §2.5 |

### 2.2 ★★ A 类:守卫幻觉(承诺"会红",实际零守卫)

背景:`docs/eng/registered-debt.md:3-10` 明写"标着`（已删·2026-10-09）`的守卫都已不存在""那些债没消失,只是变成**零守卫**"。但**大量引用没标注**。逐条已核:

| 位置 | 注释承诺 | 实测 |
|---|---|---|
| [`ui/hud/pvp_hud.tscn:9`](../ui/hud/pvp_hud.tscn) / `:30-31` | "改底板色必须同步这一行 —— `tests/smoke/ui_palette_single_source_smoke.gd` 会钉住两者相等"、"**不再靠人工对齐**…改漏了它**响亮地红**,不是静默" | 该守卫**不存在**;而 `:10` 确实还躺着一份 `bg_color = Color(0, 0, 0, 0.1)` ⇒ **承诺反转:现在改漏了就是静默** |
| [`ui/hud/team_hud.tscn:9`](../ui/hud/team_hud.tscn) / `:28` | 逐字同款 | 同款,同样有一份字面量 |
| [`ui/factory/ui_factory.gd:144`](../ui/factory/ui_factory.gd) / `:318` | "调色板纪律:`ui_palette_single_source_smoke` **扫全仓**" | 扫全仓的守卫已删 ⇒ 纪律**声明在、执行机制为零** |
| [`scenes/main_menu.gd:216`](../scenes/main_menu.gd) | "`reconnect_smoke` 有源码级断言钉着它"(守 C1:回局凭据要活过回主菜单) | 文件已删;且 `registered-debt.md` §一记它**删之前就已恒假**(锚点 `_build_menu_buttons` 没了)⇒ 双重假守卫 |
| [`ui/screens/match_result_payload.gd:69`](../ui/screens/match_result_payload.gd) | "签名不动 —— `kh_l6_probe` ⑯ 按位置钉着那个实参…**不要**删" | `git ls-files \| grep kh_l6_probe` = **0**(只剩 `.superpowers/` 与 `tests/.run_all_logs/` 的历史日志)⇒ 保留形参的**唯一理由已消失** |
| [`core/net/prediction_rollback.gd:71`](../core/net/prediction_rollback.gd) | "要动它得**重跑** `brawl_rollback_probe` 的 CONTACT 族并复核三条读数" | `tests/manual/` **整目录已删** ⇒ 不是"引用过期",是**操作指令不可执行**(同文件 `:38/:52/:57` 同病) |
| `scenes/pvp_match_client.gd:652`、`server/server_main.gd:261`、`server/match/match_combat.gd:13`、`server/hosts/royale_host.gd:415`、`server/hosts/team_host.gd:616`、`scenes/royale_game.gd:98`、`scenes/team_game.gd:92`、`ui/hud/{combat_feedback,broadcast,team_hud}.gd` 等 ★ | "这条有守卫:`hud_declarative_probe` / `kh_l5_probe` / `destroyed_cells_probe` / `stats_delivery_probe`…" | 全部已删,**多数没打**`（已删·2026-10-09）`标;`pvp_match_client.gd` 同一文件 `:1098` 标了、`:652` 没标 |

**为什么这一类最危险**:其余三类只让人"读到旧信息",这一类让人**放弃必要的人工核对** —— 它看着像一道闸,而闸门已经被拆走。

★ **同一形态还出现在 `.sh` 与 `.tscn` 里**:`tests/run_all.sh:14`/`:313` 仍拿已删的 `elite_drop_probe` 当 `OK+RC` 的形态例子,`:423` 拿**已删脚本的日志**当出处;`sp_launch_panel.tscn:7` 也引用已删的 `ui_palette_single_source_smoke`。反过来也要说清:**其余 `.tscn` 注释写得比多数 `.gd` 还细**(`ui/hud/broadcast.tscn:5-7`、`pvp_hud.tscn:20-35`),问题只在"承诺"那几行。

### 2.3 ★★ B 类:行号 / 路径锚点错(同一错锚点被抄进多个文件)

| 错锚点 | 实际 | 抄进了哪些文件 |
|---|---|---|
| `player.gd:191` | **该行是空行**;`tm` 的读点在 `player.gd:212` | `player.gd:186`、`climb_component.gd:133`、`swim_component.gd:34` |
| `match_host.gd:223` | 那是 `PacketInputSource.push_pending(...)`;真写点 `match_host.gd:259` | `player.gd:184` |
| `level_0.gd:94` | 那是 `start_reap(tree, old)`;真读点 `level_0.gd:267` | `core/config/run_options.gd:7`、`core/net/pvp_session.gd:108` |
| `core/pvp_session.gd`(路径) | **不存在**,真身 `core/net/pvp_session.gd` | `core/config/run_options.gd:9` |
| `server/match_snapshot.gd:34` | **目录+行号双错**:真身 `server/match/match_snapshot.gd:10`(`NetBus.rpc("snapshot_world")` 在 `:51`) | `core/net/net_bus.gd:146` |
| `royale_host.gd:428` | 那是"自杀脱困"小节标题;兜底说明在 `royale_host.gd:403` | `server/server_main.gd:368`、`:781` |
| `pvp_hud.gd:26` | 那是 `get:`;`PixelFont.shared()` 在 `pvp_hud.gd:38` | `ui/hud/royale_hud.gd:73`、`ui/hud/combat_feedback.gd:160` |
| `player.gd:1039-1042` | 那句 `if bool(d["downed"]) and not downed_now` 在 `player.gd:1080` | `core/sim/world_rewind.gd:184` |
| `collision_builder.gd:49` | `:49` 是注释行,判断在 `:50`(差 1 行,实质正确) | `core/sim/tile_defs.gd:313`、`server/match/match_round.gd:152` ★ |
| `player.gd:261` | `is_latched()` 读点在 `player.gd:286`(与 `:562`) | `scenes/player/climb_component.gd:57` ★ |
| `ui_factory.gd 文件头第 1 条纪律` | 文件头第 1 条是**字号 16 倍数**;颜色纪律在 `ui_factory.gd:192` | `ui/hud/royale_hud.gd:77` ★ |

**量化**:注释内 `foo.gd:NNN` 引用 59 条 → **14 条错(≈24%)** ★(我抽验了 8 条,全部为真);`docs/eng/` 侧 27 条抽样 → 9 条坏(33%) ★。

**信任面**(界定"这个数有多可信"):审计员**逐条打开被引行**核对了全部 59 条,其中 40 余条核对**正确** ★;我在上表里对 11 组错锚点**逐组回源码复核**,未发现误报 ⇒ 结论是"约四分之一错",**不是**"大面积不可信"。

另有一处**结构错挂** ★★:`core/sim/world_rewind.gd:117` 的 `## 进入回溯:清空场上活弹…` **紧贴 `func _snapshot_player()`(:120)**,于是编辑器帮助里那个函数的第一行描述的是**另一个函数**;真正"进入回溯"的 `func begin()` 在 `:215`。同类:`docs/eng/` 未规定该用 `#` 还是 `##`,全仓 `##` 的**挂载位置倒是没写错**(零个被空行隔开、零个落在函数体内)⇒ 错的是**内容**,不是用法。

### 2.4 ★★ C 类:注释里的历史台账(把 git 的活干了)

| 位置 | 行数 | 形态 |
|---|---|---|
| [`tests/probe/allscript_probe.gd:17-95`](../tests/probe/allscript_probe.gd) | **79** | 为 `const EXPECTED_SCRIPTS := 163`(:96)写"数法",内含 283→287→286→288→159→163 六代历史值,其中 4 段已是废值(文件自己写"现行值以本常量为准") |
| [`tools/room_sweep_lint.gd:2-61`](../tools/room_sweep_lint.gd) | 60 | 按"批次 3 / B 册 Task 5 / 阶段 2-B Task 4 / 2026-09-28 评审"逐条追加 |
| [`tests/harness/rejoin_watcher.gd:3-70`](../tests/harness/rejoin_watcher.gd) | 68 | 同上形态 |
| [`tools/gen_menu_scene.gd:3-61`](../tools/gen_menu_scene.gd) | 59 | 同上 |
| [`tests/probe/team_match_probe.gd:3-58`](../tests/probe/team_match_probe.gd) | 56 | 同上 |
| [`scenes/player/player.gd:980-1039`](../scenes/player/player.gd) | 60(函数体内) | **追加式订正**:"订正只作**追加**、原句保留在上"(:994)—— 读的人分不清哪句是现行结论 |
| [`core/sim/world_rewind.gd:152`](../core/sim/world_rewind.gd) | 49 | 同类 |

**佐证**:全仓注释里"订正"40 处、"原文"18 处、"曾经"16 处;带日期戳的注释行 **580** 行。**为什么这是问题**:本仓注释密度高**本来是优点**(§2.7),但追加式订正会让同一段注释里同时存在"已被推翻的旧结论"和"现行结论",而**读者无法分辨**。

### 2.5 文件头注释

**A1. 完全没有文件级头注释(严格口径:前 8 行零 `#`)—— 5 个** ★★(我自己扫过,与审计员一致;括号里是"第一句注释落在第几行"):

| 文件 | 行数 | 为什么该补 |
|---|---|---|
| [`scenes/weapons/weapon_base.gd`](../scenes/weapons/weapon_base.gd) | 602 | 6 把枪的基类 + `@export` 参数体系入口(第 9 行才有注释) |
| [`ui/hud/hud.gd`](../ui/hud/hud.gd) | 456 | 直接从 `const LAYER := 129` 开始(第 13 行);层级耦合(129 压在 128 上)只在 `core/present/post_process.gd:4` 有半边 |
| [`core/present/post_process.gd`](../core/present/post_process.gd) | 92 | 第 15 行才有注释 |
| [`core/present/camera_2d.gd`](../core/present/camera_2d.gd) | 38 | 第 11 行;`docs/eng/render.md` 曾写它"带前瞻/死区"而它两者都没有 —— **头注释缺失正是那条文档误写的土壤** |
| [`scenes/enemies/enemy_jump_bird.gd`](../scenes/enemies/enemy_jump_bird.gd) | 167 | 第 16 行才有注释 |

**A2. "伪头注释"**:[`scenes/player/player.gd`](../scenes/player/player.gd)(**1083 行,全仓最大玩法脚本**)第 5 行是 `# --- 物理参数（推荐从全局读取） ---` 这类**分区标记**,不是职责总述;它还是全仓少数**没有 `class_name`** 的根节点之一。⇒ 若要补头注释,**从它开始**。

**惯例本身是明确的**:163/163 个 `.gd` 都以 `extends`/`class_name` 开头,**158/163** 在前 8 行内有头注释块 ⇒ 执行率 97%,上述 5 个是离群点。

**B. 头注释与文件实际职责不符**:

- ★★ [`scenes/level_0.gd:4`](../scenes/level_0.gd):890 行的单机主场景,文件头**只有一句"运行时破坏支持"**;它实际还管建图/世界尺寸、时间场与回溯、换场分帧拆除(`start_reap`)、ESC 暂停、PvP 旁路。`registered-debt` §五.2 与审计 §1.1 的两处坑都在这文件里 ⇒ 下一个读者拿不到地图。
- ★ [`tools/gen_menu_theme.gd:16`](../tools/gen_menu_theme.gd):头注释里是**可复制的运行命令**,而该脚本指向的 `ui_palette_single_source_smoke.gd` 已删 ⇒ 死命令(打印不出 `ALL-OK`);同文件 `:8`/`:147` 仍在**未标注**地引用它。

### 2.6 重复真相源(注释层)

| 事实 | 落点 | 现状 |
|---|---|---|
| ★★ HUD 底板色 `C_PLATE = Color(0,0,0,0.1)` | `ui/factory/ui_factory.gd`(唯一源)+ `ui/hud/pvp_hud.tscn:10` + `ui/hud/team_hud.tscn:10` 各一份字面量 | **盯它的守卫已删** ⇒ "重复 + 守卫"变成"**重复、零守卫**" |
| ★★ 调色板纪律"只在本文件定义颜色" | 声明在 `ui_factory.gd:192`;执行靠已删的扫全仓守卫 | 纪律在纸上、机制为零 |
| ★★ `tests/run_all.sh:102-107` 的 `BUDGET_OVERRIDE` 表 | 5 项**全部**指向已删文件(`team_spawn_smoke.gd`/`duel_spawn_timeout_smoke.gd`/`spawn_pool_smoke.gd`/`menu_theme_mirror_smoke.gd`/`ui_palette_single_source_smoke.gd`) | 整表是**死配置**;表头自称"只列文件头自己声明过的加长值"⇒ 未来同名文件会**静默继承错的预算** |
| ★★ 7 段注释文本一字不差地出现在 ≥3 个文件 | 例:"睡眠态判定…"、"加新敌人时照抄本方法…"、"环面尺寸:分歧判定要用它取最短向量…" | 改一处必漏另一处 |
| ★ `@rpc` 声明 59 条 | `tests/smoke/rpc_channel_contract_smoke.gd:18` 注释 + `:24 const` + `docs/eng/netplay.md` 通道表 | **28+31=59 当前正确**(实测);但 `:18` 里"`reconnect_smoke.gd` 的 13 条显式排除"**指向已删文件** |

### 2.7 ★★ 零发现(诚实报告:这几类**比预期干净**)

> **口径**:本节只讲**零信息量**的注释(死代码、复读机);**"信息过载"**那三类(Markdown / 黑话 / 小作文)在 **§2.9**。两者不矛盾 —— 本仓的毛病是**写得太多**,不是写得太少。

- **注释掉的代码块:0**。三种检测式(连跑 ≥3 行含代码关键字 / 注释行含赋值或调用 / 全仓 `#` 连跑 ≥12 行)扫 `.gd`/`.gdshader`/`.sh`/`.py`/`.tscn`/`level_editor/*.js`,**全部零命中**。
- **TODO / FIXME / HACK / 待办:0**。全仓命中的"临时"97% 是"临时目录/临时覆盖/临时态"这类正当技术用词;`XXX` 是游戏文案"击杀 XXX"与 shader 的 `c.xxx`。**唯一一处无主无日期的待办标记**是 [`scenes/level_0.gd:232`](../scenes/level_0.gd) `# 临时：从固定地图文件加载（随机生成已注释，两者之后一起删除）` —— 且"随机生成已注释"半句已不成立(`core/sim/maze_generator.gd` 现在是转发层,被注释的生成代码全仓找不到)。
- **复读机式注释(把代码翻译一遍):≈0**。定向扫描(`# 返回/设置/创建/初始化/播放/清空/重置/遍历/构建…` 紧贴代码)在 163 个 `.gd` 上零命中。
- ★ **唯一一处"该写而没写"**:`server/match/match_host.gd:190`(`_pending_input[role].append(pkt)`)与 `:251`(`q.pop_front()`)—— 审计 §2.2/§2.3 认定这是"`ax` 无界 + 每 tick 只消费 1 包"的**承重面**,而注释只描述**机制**,没写"为什么不做上限/不钳位";`:159` 有 ρ=1 的实测记录,却**没写"这是有意接受还是待修"** ⇒ 读者无法判断。改法:该行补一句"★ 已知边界(登记):见 `registered-debt.md` §八 / 审计 §2.2-2.3"。
- **`level_editor/` 全部 16 个 JS 都有头注释**(前 5 行内),TODO/FIXME/HACK 零命中,未发现过期注释 ★。
- **编码/字符**:`.gd` 无 BOM、无乱码。

### 2.8 观察项(不算缺陷,但没有规则覆盖)

- ★★ **`.gd` 换行混用**:40 个 CRLF / 123 个 LF。`tools/check_naming.py` 规则 E 只守 `.ps1`/`.bat` ⇒ `.gd` 的 EOL **无任何规则**。(Godot 不敏感,故列为观察项。)
- ★★ **全角括号离群**:`scenes/player/player.gd` 有 **9 处**全角 `（`;全仓仅 **7 个文件**出现过,其余多为 1~3 处。标点风格**没落纸** ⇒ 建议在 `docs/eng/` 写明"半角"。

### 2.9 ★★ 三类"写给模型看"的注释:Markdown / 黑话 / 小作文

> 这三条是**读者视角**的毛病,与 §2.2~§2.4 的"内容错"不同 —— 内容是**对的**,但**形式**是按"喂给下一个 agent 的上下文"写的,不是按"下一个改这行的人"写的。三条同源:**注释的读者被默认成"读过全部计划、账本与上一次对话的模型"**。

#### (a) 在注释里写 Markdown —— 10,758 处,55% 的注释行带标记 ★★

| 标记 | 次数 | 落在多少行 |
|---|---|---|
| `` `反引号` `` | 5,811 | 3,966 |
| `**加粗**` | 4,935 | 4,340 |
| `[文字](链接)` | 12 | 12(其余 `{role:int, name:String}` 这类是误命中字典类型语法) |
| md 表格 / `#` 标题 / `-` 列表 / 围栏 / `>` 引用 | **0** | 0(这一半是干净的) |

**密度**:`.gd` 注释共 **11,502** 行,其中 **6,314 行(55%)** 至少含一个 `**` 或反引号。最密的文件:`scenes/mp_lobby.gd` 560 处、`scenes/pvp_match_client.gd` 555、`tools/room_sweep_lint.gd` 441、`server/server_main.gd` 384。

**为什么这是毛病**:这些标记**在哪都不渲染** —— ① Godot 内置帮助渲染的是 **BBCode**(`[b]`/`[code]`/`[param x]`/`[method foo]`),不认 Markdown ⇒ `##` 文档注释里的 `**加粗**` 与反引号在 F1 面板里是**字面字符**;② `.gd` 在 GitHub 上也按代码渲染,同样不渲染。⇒ 10,758 个标记全是**纯噪声**,只增加读原文的成本。
**引擎内的正确写法**(与 §5.1-1 同一条):把 public API 写成 `##` + BBCode,例如 `## 命中时把 [param damage] 交给 [method take_hit]。`

#### (b) 不说人话 —— 项目内部黑话直接写进注释 ★★

| 黑话 | 注释里出现 | 例 |
|---|---|---|
| `★` / `★★` | **2,442** | 全仓最高频标记;`★` 同时充当"重点 / 订正 / 警告 / 历史"四种语义 |
| `§` 章节号 | 164 | `core/config/enemy_params.gd:21` "两个参数类互不依赖(spec §3)" |
| `相①`~`相⑤` | 111 | `core/config/settings.gd:109` "(冒烟 …(已删·2026-10-09) **相⑤** 直接喂可用区进来)" |
| `Task N` | 96 | `core/net/grace_window.gd:25` "这三处是 **Task 2**。" |
| `闸`(闸门/关闸) | 92 | `core/net/net_bus.gd:216` "禁武器**闸门**没上" |
| `spec` / `brief` / `plan` | 80 | `core/sim/score_rules.gd:12` "五个权重是首版默认值(spec §3.2)" |
| `收口` | 55 | `core/net/net_bus.gd:2` "PvP 唯一网络**收口**" |
| `账本` | 38 | `core/sim/tile_defs.gd:220` "pre_hp 供回溯**账本**记'改前值'" |
| `册`(`A 册`/`B 册`) | 31 | `scenes/team_game.gd:226` "契约(**A 册**定死,两边逐值对齐)" |
| `判词` | 22 | `core/sim/world_rewind.gd:277` "可直接当探针**判词**的错话" |
| `[RBCD]\d+` 编号 | 148 | `core/net/net_bus.gd:215` "(自检 **B2**…)"、`core/net/net_bus_ext.gd:82` "(2026-09-29,**B1 甲案**)" |
| `D6a` / `K1–K5` | 14 | `scenes/weapons/bullet_base.gd:63` "子弹尾迹(**D5**)…" |
| `ρ=1` | 3 | `server/match/match_host.gd:157` "队列长度就是 **ρ=1** 的随机游走" |

★ **口径订正(我自己扫错过一次)**:同一套正则还把 `梯`(138)与 `档`(14)算成黑话 —— 逐条看,`梯` 绝大多数是**游戏里的梯子**(`抓梯`/`爬梯`/`梯子回拉`),`档` 多数是**分辨率档位**。**这两个不算黑话**,表里已剔除。

**最硬的一条 —— 有些黑话在本仓根本解不开**:

- 注释里 **12 行(6 个文件)** 直接引 `\.superpowers/` 路径(如 `scenes/player/player.gd`、`tests/harness/menu_autotest.gd`)—— 而 `.superpowers/` 是 **gitignore、不入库**的 ⇒ 对任何**新克隆**(以及未来任何 agent)这些引用**不存在**。
- `B2 甲案` 在全仓 **0 命中**(`.gd` + `.md` 都搜不到)⇒ "甲案"是哪个案,只有当时的会话知道。
- `A 册` / `B 册` 只在 5~6 份**历史计划/spec** 里出现且**没有一处给出"这指哪份文档"**;`相③`/`相⑤` 的相位编号定义在**那支探针自己的文件头**(而多数探针已删)。

**改法(建议落纸为一条规则)**:注释里第一次出现的黑话**必须在同一行就地展开一次** —— 形如 `A 册(=\`docs/superpowers/plans/2026-09-18-team-3v3-a-server-rules.md\`)`;解不开的(尤其是只能指向 `.superpowers/` 的)应当**把不变量直接写出来,不用代号**。判据:一个只读这个文件的人,能不能在**不打开第二个文件**的前提下看懂这句注释。

#### (c) 小作文 / 把 `.gd` 当模型上下文 ★★

**规模**:`.gd` 全仓 **注释 11,502 行 / 代码 24,756 行 / 空行 4,582** ⇒ 注释占**非空行的 32%**。**7 个文件注释行 ≥ 代码行**:`scenes/player/player_replica.gd`(225/197)、`scenes/main_menu.gd`(221/219)、`tests/probe/allscript_probe.gd`(99/44)、`ui/hud/status_banner.gd`(95/43)、`core/net/pvp_session.gd`(90/37)、`server/lobby/rejoin_registry.gd`(59/53)、`core/net/grace_window.gd`(54/41)。

**"单点常量配长文"实测(连续注释块 → 紧跟的那个声明)**:

| 注释行数 | 落点 | 被注释的东西 |
|---|---|---|
| **79** | `tests/probe/allscript_probe.gd:96` | `const EXPECTED_SCRIPTS := 163` |
| **60** | `scenes/player/player.gd:1040` | 一句 `var wc: WeaponComponent = weapons` |
| **40** | `ui/hud/status_banner.gd:69` | `const TOP_OFFSET := 128.0` |
| **33** | `scenes/main_menu.gd:73` | `const BG_MAP := "res://maps/newfactory.cyrm"` |
| **29** | `core/net/packet_input_source.gd:149` | `const QUEUE_CAP_MIN := 2` |
| **28** | `ui/factory/ui_factory.gd:215` | `const C_TEAM_A := …` |
| **28** | `core/net/player_input.gd:32` | `var frozen := false` |

**范式样本(值得逐行读一遍)**:[`ui/hud/status_banner.gd:29-69`](../ui/hud/status_banner.gd)—— 一个 149 行的 HUD 里,**40 行注释解释一个 float 常量**,内容包括:①三块面板的实测矩形;②一段 **3px 字体度量的题外话**(引到引擎源码 `scene/gui/label.cpp` 的 `get_line_height()` 与 `_shape()`);③**它自己两个已被推翻的旧版本**("本条此前写…两个数都偏小 4"、"**别照这句话的上一版写**"、"更早那版注释写的是**两个错**");④一条 ⚠ 登记(横幅侵入排行榜 60px,不修)。而它开头自己写着**"结论不变"**。

**同源的"过程叙事"词频**(注释里):`这条` 189 行、`评审` 42、`收尾` 41、`当时` 26、`brief` 25、`报告` 19、`本批` 11、`变异` 11、`Finding` 7、`交接` 4 ⇒ 约 **370 行**注释在讲**工作过程**(谁在哪一批量了什么、上一版错在哪),而不是在讲**模块的不变量**。

**为什么这是毛病**(三条,按危害排序):
1. 它是 §2.2(守卫幻觉)与 §2.4(追加式订正)的**共同上游** —— 一旦开始"记录过程",过程就永远在长,而产品源码里的旧结论没人敢删。
2. **信噪比**:改一行要读 40 行,而这 40 行里**与本次改动相关的通常只有 1~2 行**。
3. **它会过期,而且过期时是有害的**(§2.2/§2.3 全是这么来的):过程叙述里的"当时实测"、"已删守卫"、"重跑某探针"都会比代码先过期。

**改法(建议落纸为三条规则)**:
1. 注释只写**不变量 + 为什么 + 边界**;**过程**(谁在哪个批次、评审发现了什么、上一版错在哪)归 **commit message / `docs/superpowers/` 的 spec** —— 那里才是它的家。
2. **单点注释上限**:一个声明/分支之上超过 **5 行**的注释,就该考虑搬进 `docs/eng/` 并在原处留一行指针(理由:注释与代码同文件,改代码的人一定会看到;超过 5 行就意味着"这段解释比它解释的代码还长")。
3. **被推翻的旧结论删掉,不保留"原句在上"** —— 本仓自己写过"订正只作追加、原句保留在上"(`scenes/player/player.gd:994`),这条**应当反转**:读的人需要的是**现行结论**,历史在 `git log`。

**建议直接落纸的注释规范(可整段抄进 `docs/eng/conventions.md`)**:

```text
代码注释规范(2026-10-13 审计提案)
1. 语言:一律中文;标点半角(全角括号仅出现在引用原文时)。★/⚠ 是本仓仅有的两个标记,
   不用 Markdown 的 ** / ` / # / - 列表 —— 引擎与 GitHub 都不渲染它们。
2. 文档注释:public API(class_name / signal / func / @export / const)用 ## + BBCode
   ([b] / [code] / [param x] / [method foo]),这样编辑器 F1 里才有内容。
3. 读者模型 = "只读这一个文件的人"。任何代号(册 / 相N / Task N / B11 / D5 / R19 …)
   首次出现必须就地展开成路径或直接写出不变量;不许只指向 .superpowers/(gitignore)。
4. 注释写"不变量 / 为什么 / 边界",不写过程(批次、评审、上一版错在哪)——过程进 commit。
5. 单点注释 > 5 行 ⇒ 搬 docs/eng/ 并在原处留一行指针。
6. 被推翻的结论直接删,不保留"原句在上"。
7. 引用了守卫的注释必须写"这是行为守卫 / 还是零守卫";守卫被删时,注释与守卫同批改。
```

---

## 3. 文档不规范(与源码不符 / 失效)

### 3.1 ★★ 会误导操作的(优先修)

| 位置 | 文档说 | 源码实际 |
|---|---|---|
| `docs/eng/tools.md:12` | "★★ **游戏侧今天还读不了 v4** —— 那个确认框点下去就是把一张好地图换成游戏打不开的一份" | **相反**:`core/sim/map_format.gd:97-102` 的 `is_v4()` → `MapFormatV4.parse()` 是**现行唯一在跑的路径** ⇒ 这条会让人不敢用现行格式,且把"安全操作"说成危险操作 |
| `docs/pvp-networking.md:120` | 服务器 pin `res://factory_1V1(260827).cyrm` | 该文件不存在;`server/match/match_bootstrap.gd:15` 是 `res://maps/newfactory.cyrm` |
| `docs/pvp-networking.md:341` | "现状**死亡即倒地、不复活**" | `server/match/match_state.gd:121` 有 `RESPAWN_DELAY := 2.0`(局内死亡后复活延迟)⇒ 同一句自相矛盾且已过期 |
| `docs/pvp-networking.md:3` | "阶段 3 回合制**未做**" | 回合制/3v3/大乱斗/重连/快照均已落地;而 `AGENTS.md` 至今把它列为现行"PvP 网络设计"入口 |

### 3.2 ★★ 计数与清单过期

| 位置 | 声明 | 实测 |
|---|---|---|
| `README.md:77`、`AGENTS.md:8`、`:158` | 默认批 **12 支** | `bash tests/run_all.sh --list` ⇒ **`enumerated 18 / excluded 4 / running 14`** |
| `docs/eng/tests.md:40,42,48-55` | "主要探针"六类清单 + `kh_l{1,3,4,5,6}_probe` | 点名的 **61** 个测试/工具文件名 ⇒ **53 个已不存在(87%)**;`:42` 的 `enemy_logic_smoke.gd` 不存在 |
| `docs/eng/enemies.md:11`、`world.md:14-15,50`、`ui.md:17`、`render.md:32-39`、`modes.md:66`、`netplay.md:24-42` ★ | 各处点名的守卫 | 大面积指向已删探针(`tests/manual/` 整目录已删),且**无"已删"横幅** |
| `README.md:98` | `data/` 有 `tile_defs.json` / `enemies.json` | `ls data/` = **3 个**,漏 `weapons.json`(而 `weapons.md` 与 `player.md` 都写"武器注册表单一来源 = `data/weapons.json`") |
| `README.md:76` | `Godot_console --headless …` | 不存在该二进制名(`CLAUDE.md:24` 给的是 `Godot_v4.7.1-stable_win64_console.exe`) |
| `RELEASE.md:91` | `python tools/archive_build.py --file "Some.exe"` | `tools/archive_build.py:122` 只认 `--stamp`/`--version`,其余 `sys.exit("未知参数 …")` ⇒ **这条命令当场失败** |
| `RELEASE.md:122` | 保留类里含 `Parallax2D` | 全仓 `Parallax2D` **仅 1 处命中 = RELEASE.md 自己**;无任何代码用它 |
| `RELEASE.md:68-69` + `README.md:65` | 归档名 `… v.1.1.4 …`、归档根 `builds/` | `tools/archive_build.py:78` 返回 `"%s_v%s"`(**无点**);`builds/` 与 `releases/` 两个根**都存在**(`releases/` 是累积式、不清理)⇒ `RELEASE.md` 全文 0 次提到 `releases/` ★ |
| `AGENTS.md:225` | `team_match_probe`"修复后**没有留下**六人整跑判决" | `docs/eng/registered-debt.md` §一**已记 2026-10-08 六人整跑 FAIL(8 条)**及根因行 ⇒ **清单比转述新** ★ |
| `AGENTS.md:225` | "**三条**探针不算守卫…外加**两条**候选" | `registered-debt.md` §一 实为 **6 行**(`:24/32/33/34/35/36`)、§二 **4 行** ★ |
| `docs/eng/tests.md:59` | "已知红的**唯一清单**是 `registered-debt.md` §一" | `registered-debt.md:13-14` 已**自我校正**"这个说法只对那两类成立",`AGENTS.md` 也同步了 ⇒ **最旧的那处没跟着订正** ★ |
| `docs/eng/registered-debt.md:40-41` | "`reconnect_smoke` 是**真红**(进基线)" | `tests/known_red.txt` 的注记已是"同批已删除…**现在本基线是空的(0 条)**";我实跑 `run_all.sh --list` 输出 `KNOWN-RED BASELINE (…; 0 条)` ★★ |
| `docs/eng/registered-debt.md:50` | 把 `menu_theme_mirror_smoke.gd:190/200` 当**范本**引用 | 该文件已删(同批被删)⇒ 范本成了空指针 ★ |
| `docs/eng/test-economy.md:97` | "仓内已有 **6 支**这么用:`tests/manual/climb_probe.gd:28/47`…" | 6 支里 **5 支已删**,`climb_probe` 这个**没打"已删"标** ★ |
| `docs/eng/test-economy.md:190` | `check_naming.check_doc_paths()` 走"根三份 + **`docs/eng/*.md`**" | 实现是**写死的 11 个名字元组**(`tools/check_naming.py:45-48`),不是 glob ⇒ 另 **12 份** `docs/eng/` 的路径引用**无人守** ★★ |
| 削减标记的覆盖面 | 8 份 `docs/eng/*.md` 承诺"凡标着`（已删·2026-10-09）`的守卫都已不存在" | `grep -l "已删·2026-10-09" docs/eng/*.md` = **8 / 23** —— 另 15 份无横幅,其中 `enemies.md`/`world.md` **实际引用了已删探针** ★ |

### 3.3 ★★ 索引三处手抄、已漂移成 23 / 12 / 11 / 10

| 落点 | 数量 | 内容 |
|---|---|---|
| `ls docs/eng/*.md`(真相源) | **23** | — |
| `CLAUDE.md` 架构索引表 | **12** | 漏 11 份(含 5 份 netcode 调研、`room-lifecycle-conventions`、`test-economy`、两份审计) |
| `tools/check_naming.py:45-48` 的 `DOC_FILES` | 3 根 + **11** | **写死的名字元组,不是 glob** ⇒ `netcode-snapshots.md`(469 行、`CLAUDE.md` 点名)的路径引用**今天没有任何守卫** |
| `AGENTS.md`「去哪查」表 | **10** 个域名 | 比 `CLAUDE.md` 还少 `netcode-snapshots` 与 `registered-debt` |

⇒ 这是 `AGENTS.md` 自己那条"**能生成就别再加守卫**"的头号候选:`ls docs/eng/*.md` 就是真相源。

### 3.4 ★★ 文档引用存在性的量化(全量扫描)

| 分区 | 引用的 `.gd/.tscn/.sh` | 指向不存在的 | 其中**未标**"已删/退役/历史" |
|---|---|---|---|
| `docs/superpowers/**`(历史计划+spec) | 8,204 | 2,890 | 2,863(历史档案的**正常状态**,不计为问题) |
| `docs/archive/**` | 464 | 172 | 146(同上) |
| `docs/eng/**` | 1,008 | **197** | **111** |
| `docs/*.md`(其余) | 228 | **53** | **53** |
| 仓库根文档(README/AGENTS/CLAUDE/RELEASE) | 41 | **0** | 0 |

> 口径说明:检查是**大小写敏感**的,故一部分"不存在"其实是改名后的旧写法(`EnemyJumpBird.tscn` vs `enemy_jump_bird.tscn`);`docs/eng` 那 111 条里我抽验过的都是真失效。**代码注释侧**同口径:631 处引用 / 50 个文件含至少一处失效 / 16 个文件**未标注**(剔除格式串后真失效约 12 处)。

### 3.5 ★★ 文档冗杂:该拆 / 该归档

判据沿用 `CLAUDE.md:5` 的先例(**单文件超过 64KB 工作区指令预算就会被截断,后半本等于没写**):

| 文件 | 行数 / 字节 | 判断 |
|---|---|---|
| `docs/eng/registered-debt.md` | **888 行 / 126,232 B** | ★★ **已越过同一根线**,且是"动手前先看它"的入口 ⇒ 按主题拆 `docs/eng/debt/`(既有红 / 重复真相源 / 各域登记 / 削减账 / 已销),本体只留索引 + §四 落点表 |
| `docs/eng/conventions-review-2026-10.md` | 704 行 / 63,442 B ★ | 一次性时间点报告却住在规范目录 ⇒ 整体归档 `docs/archive/`(维度 = 时间) |
| `docs/eng/audit-2026-10-04-design-conventions.md` | 554 行 / 58,289 B ★ | 同上;被 `world.md`/`render.md` 正向引用 ⇒ 归档时**保留锚点节** |
| `docs/eng/netcode-*.md`(8 份) | 合计 1,502 行 ★ | 其中 4 份标题自带"一手来源调研(增量)/细节" = 调研笔记而非域规范 ⇒ 可按主题合成 2 份(wire-format / clocks-and-interp) |
| `docs/eng/tests.md` | 104 行 | 行数小但**结构已崩**:探针清单 87% 失效、另有自陈"已降级为历史记录"的段落 ⇒ **整段删**,判据面让给 `run_all.sh --list` 与 `tests/README.md` |

**不必拆**:`world.md`(51)/`render.md`(41)/`ui.md`(59)/`weapons.md`(75)/`player.md`(23)/`modes.md`(108)/`netplay.md`(185)/`tools.md`(19)。

### 3.6 ★ 缺失的文档

- ★★ **时间玩法(回溯 / 加速 / 颗粒 / 怀表 / 世界重绕)整条线没有域文档**。源码:`core/sim/world_rewind.gd`、`core/sim/time_field.gd`、`core/config/time_params.gd`、`core/config/time_rules.gd`、`server/time_economy.gd`、`ui/watch_hud.gd`、`ui/time_symbol_hud.gd`、`core/sim/grain_account.gd`、`core/sim/tile_ledger.gd`;`docs/eng/` 下**没有 `time*.md`**,唯一落点 `docs/archive/kh-line-log.md` 被 `AGENTS.md` 明文标"已封存,勿当现行规范"。⇒ 主推玩法之一的设计理由被主动作废却无人接手。
- ★ `core/net/` 的进程/生命周期层有文档(`room-lifecycle-conventions.md`)但**没有索引指向它**。

---

## 4. 冗杂与拆分

### 4.1 ★★ 规模分布(163 个 `.gd`)

| 区间 | 文件数 |
|---|---|
| >800 行 | **10** |
| 601–800 | 3 |
| 401–600 | 19 |
| 201–400 | 32 |
| 30–200 | 90 |
| <30 | 9 |

**产品代码 >600 行的 10 个**:`scenes/mp_lobby.gd`(1385)、`scenes/pvp_match_client.gd`(1372)、`scenes/player/player.gd`(1083)、`server/lobby/lobby_rooms.gd`(1011)、`scenes/level_0.gd`(890)、`tools/room_sweep_lint.gd`(837)、`server/server_main.gd`(819)、`ui/factory/ui_factory.gd`(636)、`server/hosts/team_host.gd`(625)、`scenes/weapons/weapon_base.gd`(602)。

### 4.2 拆分建议(按"职责数"排,不按行数)

| 文件 | 行数 | 职责账(函数长度合计) | 拆法 | 档位 |
|---|---|---|---|---|
| [`scenes/mp_lobby.gd`](../scenes/mp_lobby.gd) | 1385 | 房卡/创建弹层 ~**516**(`_build_ui` 171、`_make_card` 68、`_card_header` 47…)、等待室 ~**227**、三模式协议+ack 梯 ~**302**(`_join_code` 51、`_on_server_message` 37…)、转连/超时 ~**126** | 抽 `lobby_cards.gd`(动态行)+ `lobby_wait_room.gd`;`mp_lobby.gd` 留协议+转连 | 2 |
| [`scenes/pvp_match_client.gd`](../scenes/pvp_match_client.gd) | 1372 | 重连/reclaim ~**284**、时间特效 ~**254**、地面武器拾取 ~**205**、快照同步 ~**153**、子弹命中 ~**150**、结算/输入锁 ~88 | 抽 `match_reconnect.gd`、`match_time_fx.gd`、`ground_pickup_view.gd` | **3**(重连动协议) |
| [`tests/harness/team_match_watcher.gd`](../tests/harness/team_match_watcher.gd) | 1606 | 跳跃感知导航图 **247**(`:1236-1512`)+ 相位机 + 客户端侧断言 | 抽 `tests/harness/bot_nav.gd`(**注意:这不是重复造轮子** —— `:1237-1248` 有实测理由:4 邻域地板格 A\* 只连通 77 格(4%),而跳跃感知图主连通区 1792/2095 = 85.5%) | 1 |
| [`server/lobby/lobby_rooms.gd`](../server/lobby/lobby_rooms.gd) | 1011 | 1v1 ~150、royale ~216、team ~242、共用账本/拆除收口 ~336(内部类 `Room/RoyaleRoom/TeamRoom` 在 `:41-127`) | 先抽 `room_types.gd`(纯数据类),再按模式分文件 | **3**(端口/拆除收口) |
| [`scenes/player/player.gd`](../scenes/player/player.gd) | 1083 | 快照/还原 ~**190**(`capture_state`/`restore_state`/`sync_soft_state`/`rewind_restore`/`_apply_weapon_state`)+ 物理 ~330 + 拾取/掉落 ~70 | 已有 3 个组件先例(`ClimbComponent`/`CombatComponent`/`WeaponComponent`,`docs/eng/player.md:21` 有记载)⇒ 再抽 `PlayerSnapshot` | **3**(快照/回滚承重) |
| [`scenes/level_0.gd`](../scenes/level_0.gd) | 890 | 换场+分帧拆除 ~**190**(`:53-222`,含内部类 `_Reaper`)、建图/水体 ~154、破坏砖 ~121、时间视效 ~162、拾取 ~105 | 抽 `core/present/scene_reaper.gd` | 2 |
| [`server/server_main.gd`](../server/server_main.gd) | 819 | `_ready` **130**、宽限窗 ~100、reclaim 阶梯、`_on_match_sync` 98、IP/worker ~90 | 抽 `grace_reclaim.gd` | 2–3 |
| [`ui/factory/ui_factory.gd`](../ui/factory/ui_factory.gd) | 636 | `fit_name()` 单函数 **162 行**(纯文本度量裁剪)+ 样式工场 | 抽 `ui/factory/text_fit.gd` | 1 |
| [`tools/room_sweep_lint.gd`](../tools/room_sweep_lint.gd) | 837 | `_check()` **268 行** + 8 个 `_check_*`;**零行为断言**(83 处 `_fail` 全是读产品源码判形态),文件自己在 `:2-11` 承认"这是规范检查器,不是测试" | ★ **不该拆,该按本仓 D6/D6a 判据删或改成行为断言** | 2 |
| `server/hosts/team_host.gd` 625 / `scenes/weapons/weapon_base.gd` 602 | — | 边界值 | 暂不动 | — |

**其余规模信号**:最长函数 `team_match_probe._assert_stage3` **366 行**、`room_sweep_lint._check` **268 行**、`tile_collision_probe._run` **231 行**、`mp_lobby._build_ui` **171 行**、`ui_factory.fit_name` **162 行**;**8 对函数体逐字重复(≥8 行)**:`royale_game._on_snapshot_world` ↔ `team_game._on_snapshot_world`(24 行)、两份 `_remove_replica`(16)、`team_host._broadcast_round_state` ↔ `match_round._broadcast_round_state`(16)、`local_server._priv_score` ↔ `server_main._priv_score`(11)、`enemy_spawner.open_floor_cells` ↔ `match_ground._ground_spawn_cells`(11)、两份 `request_suicide_role`(11)、两份 `_kill_children`(9)、两份 `_process`(8)。

### 4.3 ★★ 反方向:不该拆的

- **9 个文件 <30 行**(`core/sim/math_util.gd` 12、`core/config/run_options.gd` 13、`scenes/effects/explosion_fx.gd` 10…)。再拆就是**文件税**。
- **服务器宿主已正确分层**:`MatchCombat → MatchRound → MatchHost → TeamHost/RoyaleHost`。上面那 8 对重复里属于宿主的只有 2 对,收益远小于 §4.2 的前 8 项。
- **没有孤儿脚本**:按 basename 反查,163 个 `.gd` 无一"零引用"。

---

## 5. 该用 Godot 内建的

### 5.1 ★★ A 档 —— 明显更优、风险低

| # | 项 | 证据 | 收益 |
|---|---|---|---|
| 1 | **`##` 文档注释** | 163 个 `.gd` 仅 34 个含 `##`(全仓 256 行) | 编辑器 F1 / Inspector 立刻有内容;**零行为风险** |
| 2 | **`.tscn` 子场景(`PackedScene` 实例化)** | `scenes/mp_lobby.tscn` = **82 节点 / 1324 行 / 0 个 instance**;`settings_menu.tscn` 54 节点同样零实例 | 房卡、创建弹层、等待室面板、设置页每一行都该是可复用子场景,而不是一个扁平大场景 |
| 3 | **（已完成,不是候选）六屏 UI 已从代码迁进 `.tscn` + `Theme`** | `main_menu` / `settings_menu` / `info_menu` / `beta_menu` / `match_result` / `mp_lobby` 六个 `.tscn` 都在库里,六个都 `theme = ExtResource(…menu_theme.tres)`;Theme 基座 `ui/theme/menu_theme.tres` 已入库 ★ | ★ 别再按"代码建 UI"去评估这六屏。**注意**:计划 `docs/superpowers/plans/2026-10-03-ui-to-tscn-and-theme.md` 的**勾选框全是空的,但 Task 0–6 的成果全在提交里** ⇒ 又一次"枚举会过期",动手前先 `git log` |
| 4 | **[`ui/screens/pause_menu.gd`](../ui/screens/pause_menu.gd) → `.tscn`** | 116 行纯静态 UI,且**没有** `pause_menu.tscn` | 补上上批迁移漏掉的小尾巴(A/B 边界) |
| 5 | **`TerrainAtlas` 烘焙成 `.tres`** | `core/sim/terrain_atlas.gd`(207 行)在 `:77-95` 每次进图 `Image.create` + 拼图 + `resize`,再在 `:95-105` `create_tile()` 建 352 个 tile | 烘成 `terrain_quadrants.png` + `wall/water_tileset.tres`,可删两个构造器;配 `--check` 生成器(范本:`tools/gen_menu_theme.gd`)。★ **A/B 边界**:审计员把它归 B 档,理由是"要配生成器 + 源砖 `structure.png` 必须稳定(改了要重烘)" —— 我按"删的是运行期构造、风险低"归 A,**前提那一半要照审计员的读** |
| 6 | **自研源码扫描器 → `GDScript` 反射** | `tests/lib/scan_util.gd` + `probe_base.gd` 的 `_func_body`/`code_only`/`contains` 一族;内建替身是 `load()` 后 `get_script_method_list()`/`get_script_constant_map()`(`probe_base.gd:100` 已有先例) | 按本仓 **D6/D6a** 判据,最承重的部分应**删**而非迁移。★ 硬约束:扫描逻辑**不许搬进** `core/`/`scenes/`(导出模板 `module_regex_enabled: false`,进导出包会解析失败);★ 合法 lint **保留**:`tools/check_naming.py`(430 行 Python,`re` 不受裁剪约束) |

### 5.2 B 档 —— 有前提

1. ★★ **`.cyrm` 地图格式 + 浏览器编辑器 → `TileSet(.tres)` + `EditorPlugin`**。前提 = **放弃浏览器编辑器**。能删格式层约 800 行 + `level_editor/` **16,195 行**,并消掉"格式有两份实现"(注释层同款:`docs/eng/tools.md` 自陈"两边改一处必须同步改另一处")。**当年自研理由今天多数不成立**:环面是 3×3 副本、与磁盘格式无关;64px 砖/16px 子格 `TileSet.tile_size` 就能表达;砖块属性早已解耦到 `data/tile_defs.json`;导出裁剪不是理由(`PackedScene` 一样进 `all_resources`)。**唯一还硬的**是逐子格 4 通道辅码 tint —— 而它**在游戏侧是死的**:`core/sim/map_format_v4.gd:140` 与 `:167` 只读 `(v >> 12) & 0xFFF` 的 texture,四图层也只消费「场景」层 ⇒ **编辑器里调好的颜色,游戏里一个像素都看不见**。
   ★★ **必须保留**的是 `core/sim/collision_builder.gd:63-125` 的**贪心合并 + 9 环面副本**(约 140 行):Godot `TileSet` 物理层**逐 tile 生成形状、不合并**,换过去 4000 个 shape 会变几万个 —— **这一处内建明显更差**。
   ⇒ **若决定保留浏览器编辑器,现状是对的(C 档);但不要再往格式里加游戏侧不消费的字段**(辅码已经是白付的一笔)。
   ★★ **迁移面要照实算**(这是决定"值不值"的另一半):引用 `MazeGenerator` 的 `.gd` = **57 个文件**(我实测;`.superpowers/` 下的草稿副本不计)、引用 `MapFormat` 18 个 / `MapFormatV4` 5 个;要改的落点是 `core/sim/world_builder.gd`、`core/sim/collision_builder.gd:31-58`(子格表入口)、`scenes/level_0.gd` 的 `_paint_maze`/`_paint_water`、`core/sim/map_catalog.gd`(选图缩略图)。**按 `AGENTS.md` 定档 = 档 3**(地图格式属"存档与地图格式"承重面)⇒ 要逐条变异验证 + 真链路跑批。
   ★ **另一条不该混进来的**:`core/sim/maze_generator.gd`(118 行)**全是"一行转发"**,它本身不是"自研格式"的一部分,而是接口税(文件头自陈"保留全仓既有调用面")⇒ 真动格式时它是**连带面**,不是理由。
2. ★★ **`ResourceLoader.load_threaded_request`**:**不是更优**。换场瓶颈实测是 `remove_child` / `free`,而 `load+instantiate` 只有几毫秒;且 `.cyrm`/`.json` **没有 `.import`**,`ResourceLoader` 读不到。
3. ★ **[`ui/screens/pause_menu.gd`](../ui/screens/pause_menu.gd)** 见 A 档;`UiFactory.apply_font_recursive` → Theme `default_font` 是**行为断言**,而 2026-10-09 已删光取图探针 ⇒ **今天没有判据**,先别动。

### 5.3 ★★ C 档 —— 明确不该改(附理由,避免"一刀切改用内建")

| 项 | 现状 | 结论 |
|---|---|---|
| **对局内 HUD 进 `.tscn`** | `scenes/level_0.tscn:35` 的 `HUD` CanvasLayer **一个子节点都没有**;`ui/hud/hud.gd` 有 **21 处 `.new()`**;`ui/hud/` 共 **2,032 行**(12 个文件) | **C 档(不划算)**,理由三条:① 用户已裁定"HUD 优先 / 一个像素都不改";② HUD 是**每帧重建的数值控件**(血量段/残弹/武器槽),骨架能搬的只有底板那一层;③ 计划自己的"已知边界 1"承认动态行在编辑器里本来就看不见。⇒ **要动只动静态底板那一层**,别整块搬 |
| **网络层** | 传输层**已经**是 `ENetMultiplayerPeer` + `MultiplayerAPI`;自研的是权威/回滚/线格式 | **不该换**:`MultiplayerSynchronizer` 走的正是文档判为"编码胖"的**属性复制**老路(884 B/包 vs 手打包 102 B),换过去是拿更差的编码替掉更好的 |
| **寻路** | `core/sim/grid_pathfinder.gd`:环面 + `max_visit` 部分路径 + 逐格谓词三重契约 | **不该换**:`AStarGrid2D` 区域是矩形、不能环绕;`AStar2D` 是全搜或失败;且 `_DIRS4` 顺序影响平局路径形态(= AI 手感) |
| **图集/块合并** | `collision_builder.gd` 贪心合并 | **内建更差**(见 5.2-1) |
| **格级几何/LOS/激光** | `collision_aabb.gd`/`beam_trace.gd`/`unstick.gd`/`tile_query.gd` | `intersect_ray` 只给第一个命中且 `-s` 下无物理世界;`Shape2D` 没有 world-AABB |
| **配置数据** | `Settings` **已在用** `ConfigFile`(4 处);`data/*.json` 是 JS 编辑器共享真相源 | 换 `.tres` 会多出**第三个**真相源 |
| **输入注入** | `PlayerInput` + 5 个实现 | `Input` 是**全局单例**,服务器要在同帧模拟 N 个远端玩家各自的轴值/切枪/瞄准 —— 全局注入**结构上做不到** |
| **随机/噪声/补间/计时/对象池** | 随机用内建 `randf`/`RandomNumberGenerator`;`create_tween` 7 处;`get_tree().create_timer` 15 处;无自研噪声、**无对象池** | **没有轮子**;`FastNoiseLite` 全仓 0 命中是因为本作不需要噪声 |
| **补间形变(squash/stretch)** | `scenes/effects/squash_stretch.gd`;`docs/eng/render.md:27` 明写"**单标量是刻意的**"(同时事件天然叠加) | **Tween 做不了**(事件驱动 + 每帧重算 `_air`)⇒ 保留 |
| **数学逼近** | `core/sim/math_util.gd` **12 行**,核心是 1 行 `lerp(c, t, 1 - exp(-rate * dt))` | `move_toward` 是**线性**的(注释说"生硬");Godot 无指数逼近 ⇒ 这是**文件税**不是轮子(可并入邻近 util) |
| **相机** | `core/present/camera_2d.gd` **38 行**:跟随 3 行 + 抖动 3 行 | `position_smoothing_enabled`/`limit_*` **可用但故意不用**(`docs/eng/render.md:14`:"无前瞻、无死区、无平滑");Godot **没有相机抖动 API** ⇒ 保留。★ **但 `cam_lookahead_x`/`cam_lookahead_y`/`cam_deadzone` 是死参数**(文档已登记、代码不读)⇒ 属**死代码清理**,该删 |
| **程序化音效** | `core/present/sfx.gd` 的 `_noise_burst`(合成) | Godot **没有音频合成器**(`AudioStreamGenerator` 只是缓冲接口)⇒ 保留 |
| **netcode 核心模块** | `core/net/playout_clock.gd`(122)、`snapshot_codec.gd`(322)、`prediction_rollback.gd`(202) | `docs/eng/netcode-*.md` 里有**一手来源调研 + 实测读数**撑着(NTP 的最小延迟选样 / 手打包 vs zstd 实测 / 容差常数测量台)⇒ 不是"随手自研" |
| **选图与散点** | `core/sim/map_catalog.gd`(229)、`core/sim/spawn_picker.gd`(315)、`core/sim/world_rewind.gd`(492)、`core/sim/time_field.gd` | 全是本作**玩法/表现特性**的载体(缩略图 / 环面散点 / 40s 回溯带 / 时间场),Godot **无对应物** |
| **真链路仪器** | `tests/harness/*`(~3,900 行:菜单/机器人/soak/watcher) | 是跨进程仪器,不是可被 `--headless` 简化掉的东西;2026-10-09 已按测试经济学砍到只剩 12 支默认批(实为 14),**再砍 = 没覆盖** |
| **自研 CRC / 时间戳 / 发布工具** | `map_format_v4.gd:293-306` 手写 CRC 表;`core/config/app_info.gd` 取 **git 提交时间**;`tools/{build_release,archive_build,pixel_diff,check_naming}.py` | 内建**没有**对应物(无 git 绑定、无"版本号只能数字+点"的校验、无逐像素比对)⇒ 保留 |
| **源码级扫描器(不该被"内建替代"误伤的部分)** | `tests/probe/path_integrity_probe.gd` 走**代码→文件系统**;`tools/room_sweep_lint.gd` 是**按需跑的约定检查器** | 前者与 `check_naming` 的**方向不同**(文档→文件系统),是互补不是重复 ⇒ 删它没有依据 |
| **评估过、但本仓根本不存在的东西** | marching squares、对象池、自研 FSM 框架、自研噪声、自研版本比较 | Godot **没有**内建 FSM/行为树;其余本仓**没自研** ⇒ 不构成候选(列出来是为了说明"这份清单不是照抄一份'最佳实践'") |
| **自研信号** | `core/net/net_bus.gd` = autoload + 41 条**内建** `signal` | 它不是"自研信号系统";autoload 是让 RPC 跨场景路由的唯一办法 |

### 5.4 ★★ 已经在用的内建能力(别重复劳动)

`PackedScene` 19、`get_tree().create_timer` 15、`TileMapLayer` 9、`create_tween` 7、`ConfigFile` 4、`ENetMultiplayerPeer` 4、`TileSetAtlasSource` 2、`ResourceSaver` 2、`Input.parse_input_event`/`action_press` 各 1、`SceneTreeTimer` 1。
**全仓零使用**的:线程加载 `ResourceLoader.load_threaded_*`、`AStar2D`/`AStarGrid2D`、`NavigationServer2D`/`NavigationRegion2D`、`FastNoiseLite`、`MultiplayerSynchronizer`/`SceneReplicationConfig`、`AnimationTree`。

---

## 6. 建议动作(按性价比 × 风险)

| 顺序 | 动作 | 档 | 判据/验收 |
|---|---|---|---|
| 1 | 修 §2.2 的**守卫幻觉**4 处 + `ui_factory.gd:144/318`;修 §3.1 的 `tools.md:12`(v4 那条最危险) | 1(纯注释) | `grep` 确认不再出现已删守卫名;人读"改漏了会怎样" |
| 2 | 修 §2.3 的锚点错(先修**被多文件抄的那个**:`player.gd:191`、`level_0.gd:94`、`pvp_hud.gd:26`) | 1 | 逐条打开被引行核对 |
| 3 | 文档计数:`run_all` 12→14;`README.md:76,98`;`RELEASE.md:91`;`docs/eng/tests.md` 删失效清单 | 1 | `bash tests/run_all.sh --list` 输出对齐 |
| 4 | **索引改生成式**:`check_naming.py` 的 `DOC_FILES` 换 `glob('docs/eng/*.md')`;`CLAUDE.md` 表补齐 | 1 | `python tools/check_naming.py` 绿 + 新文档被覆盖 |
| 5 | 删 `run_all.sh:102-107` 死预算项;`allscript_probe.gd:17-95` 台账压到 3~5 行(数法+命令),历史交 git | 1 | `--list` 不再列无主预算;常量仍 == `git ls-files '*.gd' \| wc -l` |
| 6 | 拆分低风险三件:`bot_nav.gd`、`text_fit.gd`、`scene_reaper.gd` | 1–2 | 测试目录不进导出包;行为不变 |
| 7 | 补 `##` 文档注释(至少 `class_name` 脚本的 public API) | 1 | 编辑器 F1 能读到 |
| 7b | **落纸 §2.9 末尾那 7 条注释规范**(写进 `docs/eng/`),再按它做一轮"注释瘦身":去 Markdown 标记 → 黑话就地展开 → 单点 >5 行的搬 `docs/eng/` → 删"原句保留在上" | 1 | 复算:`**`+反引号 从 10,758 → 目标 < 1,000;`\.superpowers/` 引用 12 → 0;注释占非空行 32% → 目标 ≤25% |
| 8 | `registered-debt.md` 拆目录;补 `docs/eng/time.md`(唯一整块无文档的子系统) | — | 单文件 < 64KB |
| 9 | **需仓主拍板**:`level_editor/` 16,195 行去留(决定 §5.2-1 走 B 还是 C) | — | 产品决策 |
| 10 | 承重面拆分:`lobby_rooms.gd`、`player.gd` 快照层、`pvp_match_client.gd` 重连层 | **3** | 逐条变异验证 + 真链路跑批;别顺手做 |

---

## 7. 覆盖边界(我没查什么)

**已穷举**:全部 163 个 `.gd` 的行数/注释密度/最长注释块/头注释有无/`##` 分布/日期戳/重复函数体/重复注释文本;全部跟踪文件路径引用存在性(631 处代码注释引用 + 各分区 md 引用);`run_all.sh --list` 实跑(只枚举不跑);`docs/eng` 索引三处对账;引擎特性使用计数。

**没查或只粗查**:

- ★ 8 份 `docs/eng/netcode-*.md` 的**协议字段与频率数字**(20Hz/60Hz/字节预算/丢包阈值)未逐条 grep —— **本次最大盲区**。
- `docs/superpowers/**`(~100 份历史计划)只做体量与引用存活统计,**未逐份审计**;按"历史档案"口径不计为问题。
- `registered-debt.md` 只精读 §一、§二与前 60 行,§三~§八 未逐行核。
- 未通读全部 `.gd` 正文(逐行读过的是:两份审计涉及的十来个文件 + 本报告点名的文件);`level_editor/ui.js`(2968 行)、`tools/room_sweep_lint.gd` 正文、`server/lobby/lobby_rooms.gd` 正文未逐行读 ⇒ "注释描述的行为已被改掉"这一类**可能还有遗漏**。
- `docs/CyR单人模式主策划案(1).md`、`docs/2026-09-20-cyrm-v4-handover.md`、`docs/royale-soak-2026-09-12.md`、`docs/archive/**` 未查。
- **没跑任何测试、没起 Godot、没占端口、没弹窗**;唯一的脚本执行是 `bash tests/run_all.sh --list` 与 `python tools/check_naming.py`。
- **被我有意留在"未核"、没写进正文结论的审计员数字**(它们只是量级参考,不是判据):`.cyrm` 文件字节数(v4 实测约 151 KB / 240 KB)、`level_editor/` 里"生产 JS 7,110 行 + 编辑器自测 9,043 行"的拆分口径、`export_presets.cfg:12` 的 `include_filter` 具体内容、`MazeGenerator` 的调用点数(审计员给 71 个文件,**我实测 57 个**,以我的为准)、`docs/superpowers/plans` 的"~100 份"、`RELEASE.md` 裁剪 profile 的类清单。**凡正文写了数字的,都是我实测或逐条打开核过的。**

---

## 附录 A 复算命令

```bash
# 规模
git ls-files | wc -l
git ls-files '*.gd' | while read -r f; do printf '%6d %s\n' "$(wc -l < "$f")" "$f"; done | sort -rn | head -20
git ls-files '*.gd' | grep -v '^tests/' | while read -r f; do wc -l < "$f"; done | awk '{s+=$1} END{print s}'

# 注释统计(代码/注释/##/最长块)
#   —— 见本报告 §2 的 Python 脚本口径:按行首 strip 后是否以 # / ## 开头分类;
#      最长块 = 连续以 # 开头的最大行数(空行不打断)

# 注释里的文件引用对账(631 处 / 50 个文件 / 16 未标)
git ls-files '*.gd' | xargs grep -nE '^[[:space:]]*#'
#   再对每个 [A-Za-z0-9_-]+\.(gd|tscn|sh) token 做 basename 存在性检查

# 文档引用对账
git ls-files '*.md'   # 分 docs/eng | docs/*.md | docs/superpowers | docs/archive | 根文档 五档统计

# Godot 内建能力使用计数
for p in create_tween ConfigFile ENetMultiplayerPeer TileMapLayer AStar2D NavigationServer2D \
         FastNoiseLite ResourceLoader.load_threaded MultiplayerSynchronizer; do
  printf '%-28s %s\n' "$p" "$(grep -rn --include='*.gd' -F "$p" . | grep -v '^./.superpowers' | wc -l)"
done

# 默认批规模与已知红基线
bash tests/run_all.sh --list

# 注释里的 Markdown / 黑话(§2.9)
#   Markdown 标记:`**加粗**` 4,935 次 + 反引号 5,811 次,落在 6,314 行(注释共 11,502 行 ⇒ 55%)
git ls-files '*.gd' | xargs grep -hE '^[[:space:]]*#' | grep -cE '\*\*|`'
#   黑话(已剔除 `梯`/`档` 的假命中:那是游戏梯子与分辨率档位)
for t in '★' '§' '相[①②③④⑤]' 'Task *[0-9]' '收口' '账本' '[AB] *册' '判词' 'ρ='; do
  printf '%-16s %s\n' "$t" "$(git ls-files '*.gd' | xargs grep -hE '^[[:space:]]*#' | grep -cE "$t")"
done
#   解不开的黑话:引用 gitignore 目录 / 全仓 0 命中
git ls-files '*.gd' | xargs grep -nE '^[[:space:]]*#.*\.superpowers' | wc -l     # 12
git ls-files '*.gd' '*.md' | xargs grep -lF 'B2 甲案' | wc -l                     # 0
# 小作文(§2.9c):行构成 + 单点常量前的连续注释块长度
git ls-files '*.gd' | while read -r f; do
  awk 'BEGIN{c=0;k=0} {s=$0; sub(/^[ \t]+/,"",s); if(s=="")next; if(s ~ /^#/){c++;next} k++} END{print c, k}' "$f"
done | awk '{c+=$1;k+=$2} END{printf "注释 %d / 代码 %d (注释占非空 %.0f%%)\n", c, k, 100*c/(c+k)}'

# 命名/路径检查
python tools/check_naming.py
```

## 附录 B 数据表

**注释密度(≥150 行,前 12)**:

| 文件 | 注释/总行 | 比例 |
|---|---|---|
| `tests/probe/allscript_probe.gd` | 99 / 154 | 69% |
| `ui/hud/status_banner.gd` | 95 / 150 | 69% |
| `scenes/player/player_replica.gd` | 225 / 456 | 53% |
| `scenes/main_menu.gd` | 221 / 484 | 50% |
| `server/match/match_state.gd` | 227 / 519 | 50% |
| `ui/factory/ui_factory.gd` | 274 / 637 | 48% |
| `core/sim/world_rewind.gd` | 204 / 493 | 46% |
| `server/hosts/team_host.gd` | 260 / 626 | 46% |
| `server/server_main.gd` | 344 / 820 | 44% |
| `server/lobby/room_manager.gd` | 209 / 509 | 44% |
| `tools/room_sweep_lint.gd` | 340 / 838 | 42% |
| `scenes/pvp_match_client.gd` | 501 / 1373 | 40% |

**最长连续注释块(前 8)**:`allscript_probe.gd:17` **79** / `rejoin_watcher.gd:3` **68** / `player.gd:980` **60** / `room_sweep_lint.gd:2` **60** / `gen_menu_scene.gd:3` **59** / `team_match_probe.gd:3` **56** / `world_rewind.gd:152` **49** / `_shot_scene.gd:3` **47**。

**最长函数(前 7)**:`team_match_probe._assert_stage3` **366** / `room_sweep_lint._check` **268** / `tile_collision_probe._run` **231** / `mp_lobby._build_ui` **171** / `ui_factory.fit_name` **162** / `team_match_watcher._tick_meet_shooter` **149** / `server_main._ready` **130**。

---

## 8. 落地与执行（另立一份）

审计之后的动作**不再写进本文件**（本文件的性质是**一次性快照**，按 §3.5 的 64KB 判据不该继续长）：

- **执行记录、验证证据、指标增减** → [`docs/2026-10-13-comment-slimming-batch.md`](2026-10-13-comment-slimming-batch.md)
- **规范正文（7 条）** → [`docs/eng/comment-style.md`](eng/comment-style.md)
- 该批**新查到的三条文档错误**（`room-lifecycle-conventions.md` 误称检查器"已删除"、`netplay.md:88` 引用不存在的 `.sh`、`ui.md:17` 未标已删守卫）记在该批次文档 §2，其中第一条属 §2.2 同族的**反向守卫幻觉（低报覆盖）**。

---

> **本文件的性质**:一次性快照,不是规范。第 1 档动作全部属"纯注释/配置",任何一条都可以独立做;第 10 档(承重面拆分)按 `AGENTS.md` 的改动分档必须先定档、逐条变异验证、跑真链路 —— **别顺手做**。
