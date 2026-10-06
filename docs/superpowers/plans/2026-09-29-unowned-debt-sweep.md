# 未认领欠账清扫（2026-09-29 盘点）

**来源**:2026-09-28 的「武器/联机债务审计」(见 `.superpowers/sdd/progress.md` 当日的四类分类)
+ 当天用户对「登记不修」那批的裁定(全部推翻、一律修)+ 当天的并发分工。

**本文件只收当前【无人认领】的项。** 已在做的**不在此列**:

- 对面会话(`` the-cyancular-ruins-c0 ``)的 **B 档六项**:`_left_round` 分母 · MATCH_OVER 后倒地记账 ·
  `_match_winner` 并列候选集 · 上报超时梯 · royale 在局宽限上界 · 未入树 `tick()` 冲刷 `_reloading`。
- 本会话已完成的**断线重连阶段 3**(六项,HEAD 见 git log)。
- 已修掉根因、等用户整跑的:`tests/team_match_probe.sh`(**根因已修 `9003dae`**,但六客户端整跑未验)。

**判据一律是 grep 文本,不看退出码。** 引擎走 `source tests/env.sh` + `"$GODOT"`。
**本仓的守卫纪律**:每条新断言都要**先证明它会红**(变异反证),"加了断言之后全绿"不是证据。

---

## A. 可立即实现（目标/落点都明确，有现成守卫模式可抄）

### A1 `tscn → json` 这个方向没有任何守卫
- **登记**:`CLAUDE.md:271`。
- **现状**:往 `scenes/weapons/` 放一个武器 `.tscn` 而不写 `data/weapons.json` 条目 ⇒
  `enemy_logic_smoke` / `level0_weapon_scatter_probe` / `kh_l3_probe` **三条全绿、一条断言都不红**,
  而那一把枪在**菜单 / 散落 / 图标 / HUD 名字**里全都不存在。反方向(json → tscn)是覆盖到的。
- **要做**:加一条断言 —— 扫 `scenes/weapons/*.tscn`,每个都必须在 `data/weapons.json` 里有条目。
  `EnemySpawner` 那边同样只有半边(`data/enemies.json` → `scenes/enemies/`),一并考虑。
- **守卫归属**:`enemy_logic_smoke.gd` 的 `_phase_weapon_registry`(它已有 ⑤/⑤b/⑥/⑦)。

### A2 菜单那一格没有计数断言
- **登记**:`CLAUDE.md:274`。
- **现状**:`_phase_weapon_registry` 的 ⑥ 是**源码级**的(只断言函数体里出现了 `WeaponRegistry.all_ids()`),
  把 `_fill_sp_panel` 的循环改成 `for i in 6:` 之类**⑥ 照样绿**,而菜单**静默只显示 6 行**。
  headless 跑 `main_menu.tscn` 也拦不住(它一行都不打印、且不按「单人模式」⇒ `_fill_sp_panel` 根本不被调)。
- **要做**:常驻探针 —— 实例化真 `main_menu.tscn` + 调生产的 `_fill_sp_panel()` +
  数 `VBox/CheckList` 下的 `CheckButton`,断言 == `WeaponRegistry.all_ids().size()`。
  ★ 该口径已在 `CLAUDE.md:274` 里实测过(临时探针:json 7 条 ⇒ `勾选框数=7 注册表=7`),照它落地即可。

### A3 发布产物侧没有自动化守卫
- **登记**:`CLAUDE.md:276`。
- **现状**:`data/weapons.json` 进不进 `.pck` **只由一次真导出回答**。`include_filter` 的 `data/*.json`
  是**保险不是机制**。若真没进包,`WeaponRegistry._ensure_loaded()` 只打**一条** `push_error` 且**只在 stderr**,
  不影响进程退出 ⇒ **光看"游戏能启动"看不出来**。
- **要做**:给 `tools/build_release.py` 的产物冒烟加一条 —— 起客户端后断言注册表**真的加载到了 N 条**
  (该脚本已经会跑一次产物冒烟并断言「worker 就绪」,照那个先例)。
- **量级**:中(要动发布脚本);**但只有真导出才验得了**,属"需要跑一次导出"的项。

### A4 `tier` 一致地填错没有守卫拦得住
- **登记**:`CLAUDE.md:107`。
- **现状**:`json` 的 `tier` 与 `.tscn` 的 `tier` export 不一致 ⇒ 容量算错(轻武器被当成重武器、8 格只能带两把)。
  **两者一致地填错**没有守卫。
- **要做**:加一条断言 —— 逐条比对 json 的 `tier` 与它 `scene` 指向的 `.tscn` 的 `tier` export。
  ★ 这条**不需要新的机制**:`_phase_weapon_registry` 的 ② 已经逐条 `load()` 每个 json 的 `scene`,
  在同一循环里把 tscn 的 `tier` 读出来比即可。

### A5 菜单编号那一改动只有人眼判据
- **登记**:`CLAUDE.md:63`。
- **现状**:菜单上那个编号(看起来像键位、实为 `type_id`)已按用户裁定去掉,但**没有自动化判据** ——
  `kh_l4`/`kh_l5` 的字号扫描**只查整数字面量**(`is_valid_int()` 过滤),而菜单那两处一处是变量实参、
  一处是 `cb.text` 赋值,都不在其射程内。
- **要做**:源码级断言 —— `main_menu.gd` 的禁用武器网格那两处**不得**把 `type_id`/序号拼进显示文本。
  ★ 落点与判据形状需先读该文件确认(本条**未经**控制者实读,执行者先核)。

### A6 阶段 3 计划文件 Task 5 的代码块残留
- **落点**:`docs/superpowers/plans/2026-09-28-reconnect-stage3.md` 的 Task 5 代码块(`~:1658`:
  `roy.contains("_refresh_board(") and roy.contains("grace: Dictionary")`)。
- **现状**:`Expected` 那行**已**订正为 39,但**代码块仍是收紧前的谓词** —— 其中 `contains("_refresh_board(")`
  在断言里是**恒真**的(第二个子句已经要求了那个函数体)。实际落地在 `tests/reconnect_status_probe.gd` 里是收紧版。
- **要做**:把计划文件里的代码块同步成落地版(或加一句"此处以落地版为准")。
- **量级**:极小(纯文档)。

### A7 `_bright_in` 的阈值贴着底板均值的上沿
- **落点**:`tests/combat_hud_visual_probe.gd:235` 的 `_bright_in`(阈值 0.5)。
- **登记**:阶段 3 Task 5 的最终报告(`.superpowers/sdd/reconnect-stage3-task-5-report.md:250-251`)。
- **现状**:HUD 底板(黑 0.1 压浅灰蓝)的像素均值算下来 **≈ 0.504**,**刚过** 0.5 门槛 ——
  0.004 的余量。底板色、地图底色或该探针的取图口径任一微调,都会让"底板"被判成"亮文本"。
  今天没在抖,但那是个**悬在边界上的判据**。
- **要做**:把阈值从底板均值拉开(或改成"与底板的差值"而不是绝对亮度),并**记录实测的两个数**。
- **量级**:小;★ 该探针是**真渲染**的,改动要用户跑图验收。

---

## B. 需产品决策（不是"怎么写"，是"要不要 / 做成什么样"）

### B1 私密房玩家没有回局入口
- **登记**:`CLAUDE.md:444`(用户 2026-09-21 裁定**乙案:接受"回不去"**)。
- **现状**:私密房**不进列表**(`royale_list_payload` / `team_list_payload` 跳过非公开房)⇒ 没有那一行可点;
  私密房玩家按 ESC 回主菜单后只能重新建房 / 让房主重开。
- **用户 2026-09-28 的裁定是「全部推翻、一律修」** ⇒ 本条在法律上**已解锁**,但审计指出它是**产品行为变更**,
  有两条路且各有代价:
  - **甲**:只对**本人**列出他自己的私密房(回局计划 Task 7 末尾有留档)。保持"私密"语义。
  - **乙**:把私密房也列进列表 —— **"私密"就没了**。
- **要先问用户选哪条**,而不是直接实现。

### B2 弹数没有常规纠正路径
- **登记**:`CLAUDE.md:109`;原计划 `2026-09-25-ammo-rollback-fidelity.md` 明文「C3 刻意不做修复」。
- **现状**:`_close_enough` 不比 `mag`,`sync_soft_state` 的指纹只比 `wslot`/`winst`/背包结构 ⇒
  非回滚来源的弹数分歧**静默保留**(已知候选:榴弹的 `max_live_projectiles`)。
- **用户裁定**:C 档,**本轮不动**。⇒ 本条**不需要现在做**,登记在此以免被遗忘。

---

## C. 需先复现（现象未坐实）

### C1 `RoyaleHost.start_on` 的网格预载是条件式的
- **登记**:spec `2026-09-17-reconnect-stage2-3-design.md` §5(且 `CLAUDE.md:321` 已把它列为"仍未做")。
- **现状**:`server/royale_host.gd:51-52` 是 `if MazeGenerator.current_grid == null or ... is_empty(): WorldLoader.load_grid()`
  —— **条件式**重载。阶段 1 的最终修复波观察到一次"actor 的身体卡在几何里一直落着",
  而那一跑 r1 的出生格 `(121,28)` 在 `factory1v1` 里**确是合法地板格** ⇒ 疑似 `plan_spawns` 用到了**另一张图**的格。
- **要做**:**先复现、再定性**(spec 原话),不要直接改。修法候选是把预载改成无条件,但那要先证明代价可接受。
- **量级**:未知,**先做复现**。

---

## D. 判定为「从 GDScript 够不着」（推翻裁定也改不了）

### D1 引擎自己那条 `max channels: 0`
- **登记**:`CLAUDE.md:312` 与 `:440`。
- **现状**:`reconnect_probe` 的 worker 日志里每踢一次连接约 1 条 `ERROR: Unable to send packet on channel 0,
  max channels: 0`,**无 GDScript backtrace** ⇒ 是**引擎自己**的定向发送(最像路径确认应答 `SYS_CONFIRM_PATH`
  回给一个刚被踢、队列已拆的 peer)。
- **★ 用户 2026-09-28 的「一律修」对它不适用**:不是"没修",而是**从 GDScript 没有可改的落点**。
  如实登记即可,**不要**派 agent 去找"修法"。

---

## 执行建议

1. **A 组可直接开工**(A1~A5 是加守卫,与本仓既有模式同款;A6/A7 是文档/阈值)。
   ★ A5 与 A7 落地前**先实读落点**,控制者未逐条读过。
2. **B1 先问用户**选甲还是乙;B2 本轮不做。
3. **C1 先复现**,不要改代码。
4. **D1 不做**,只在文档里保持那条登记。

---

## 本轮执行结果(2026-09-29)

| 项 | 结果 | 提交 |
|---|---|---|
| A1 tscn → json 反方向覆盖 | **已做**(武器 + 敌人两份,判据 = 根脚本链;变异实测 3 组) | `3499dfb` |
| A2 菜单勾选框计数 | **已做**(常驻探针 `tests/menu_weapon_grid_probe.tscn`,8 条) | `f3e3d58` |
| A3 发布产物侧守卫 | **已做**(客户端开关 `-- --registry-report` + `build_release.py` 逐条对账) | `3ad9424` |
| A4 `tier` 一致地填错 | **不是欠账 —— 已存在**。见下 | (无) |
| A5 菜单编号只有人眼判据 | **已做**(与 A2 同一个探针:两处载体各断一次) | `f3e3d58` |
| A6 计划文件代码块残留 | **已做**(同步成落地版 + 注明权威落点) | `10dd3f7` |
| A7 `_bright_in` 阈值 | **已做**(改成相对底板量,合成图变异实测) | `aa234cd` |
| B1 私密房回局入口 | 用户裁定 **甲**,**已落地**(载荷带 token + `RejoinRegistry.owns` + 相⑨/段⑦) | `959d405` |
| B2 弹数纠正路径 | 本轮不做(C 档,已登记) | (无) |
| C1 `RoyaleHost.start_on` 网格预载 | 机制复现、生产路径实测未复现;**spec 那句归因已推翻**;**真因 = 当时的出生池缺陷,早已于 2026-09-19(`fc00db7`)修掉** ⇒ **不再是欠账**。见下 | (文档) |
| D1 引擎 `max channels: 0` | 不做(从 GDScript 够不着) | (无) |

### ★ A4 是**伪欠账**(实读后推翻)

计划照 `CLAUDE.md` 那句读成了"要在 ② 的循环里补一条 tier 比对",而 `_phase_weapon_registry`
**的 ② 里已经有那条断言**(`60c678b` 落地的,早于本计划):
`id N:tscn 的 tier(X) 必须等于 json 的 "<三值>"(Y)`,逐条 `load()` 每个 json 的 `scene`
并比对 `int(inst.tier)`。变异实测(json 把 id 4 从 `light` 改成 `heavy`、tscn 不动)确认它会红。
⇒ **没有加任何东西**,因为再加一条会是与它逐字重复的第二份。
★ 计划里那半句"**两者一致地填错**没有守卫"是**对的,但不可执行**:json 与 tscn 是仅有的两个
数据源,两者一致时**没有第三个真值可比** —— 那不是守卫缺口,是"定义上无从判断"。
`CLAUDE.md` 那句原文("第三条只在『json 与 tscn 各写各的』时才红")描述的正是这个事实。

### ★ C1 复现与定性(未改代码)

**机制**:`RoyaleHost.start_on` 的预载是条件式的 —— 它只问"网格**空不空**",不问"网格是不是
**这张图**的"。临时探针逐字重放那三行:先 `load_grid()` 过 `demo.cyrm`(125×75),再
`set_map_file("res://maps/factory1v1.cyrm")` + `refresh_map_size()` ⇒ 预载**被跳过**,
`current_grid` 停在 **125×75** 而 `GameParameters` 已是 **150×100** ⇒ `plan_spawns` 从
**demo 的地形**里取散点(实测 `(40,30)` / `(90,18)`,其中一格在 factory1v1 里是**实心格** ——
出生即卡在几何里)。这与阶段 1 那次观察到的现象**形状一致**。

**可达性(定性)—— 先实测、再审计**:第一版结论是**静态 grep** 得来的("四个调用点都在
`start_on` 之后 ⇒ 不可达"),那正是本仓反复咬过的"没找到 = 不存在"。**补测(2026-09-29)**:
临时插桩 `RoyaleHost.start_on` + 拉一个真 `--worker --royale` 子进程 + 一个真 ENet 客户端
claim role 1 让它开局,读它自己的日志 ——

```
[c1] start_on:预载被跳过=false; 之前 current_grid=0 _picked_map=res://maps/factory1v1.cyrm
```

⇒ **生产路径上没复现**:进 `start_on` 时网格**是空的**、预载那一支**确实被走到**。
**为什么**(审计,现在只是对上测的解释):全仓给 `MazeGenerator.current_grid` 赋值/加载的生产点
只有三处 —— `WorldBuilder.load_grid()`(唯一写法)、`level_0.gd`(**无条件**走它)、
`match_round.gd`(每局还原基线,同一张图);`server/` 下 `load_grid()` 的四个调用点里三个在
`start_on` **之后**,`_begin_match` 又有重入守卫。

**原始观察的现场已找到,而且归因被推翻了**(`.superpowers/sdd/rc1-final-fix-report.md` +
`_run1_prefix.log` 都还在盘上;那一跑 = 2026-09-17 23:19,worker 29002,r1 出生格 `(121,28)`、
r2 `(79,13)`):

- **推翻的判据就是 spec 自己引的那个数**:`(121,28)` 在 `demo.cyrm` 里**根本不是地板格**
  (实测 `is_floor_cell=false`、`带净空=false`),而 `plan_spawns` **只可能产出地板格**
  (主池 `spawn_candidates()`、兜底 `floor_cells()`,都是地板格的子集)⇒ 那一跑的网格**就是
  factory1v1**。(`maps/` 下只有 demo 与 factory1v1 两张图,没有第三个候选。)
- **真因 = 当时的出生池缺陷**:当时 `OPEN_AREA_MIN=20` 是**绝对**阈值,而 factory1v1 的**最大**
  地板连通区只有 **13 格** ⇒ `spawn_candidates()` 前两档**恒空**、池子**静默退化**成全部
  **843** 个地板格(155 个是孤立单格区)。实测 `(121,28)` 的连通区规模 = **4**,今天
  `area_threshold()` = 7 ⇒ **已被排除**;修复前它**在池里** ⇒ 玩家生在 4 格小间里 =
  「卡在几何里一直落着」。
- ⇒ **根因已于 2026-09-19 由 `fc00db7` 修掉**,今天的池子是 122 格、不再退化成一档。
  **这条不再是欠账**:观察已解释、根因已修、今天的池子不含该格。

**剩下的纯潜伏部分**:同一进程内先后用两张不同的图跑两次 `start_on` —— 今天没有这样的路径,
也没有任何东西**禁止**它(见下)。真要收紧,判据应当是"网格来自哪张图"
(例如 `load_grid()` 记一个 `current_grid_map`,条件改成 `current_grid_map != map_file_path()`),
**不是**把预载改成无条件 —— 那会让同一张图在 `start_on` 与 `MatchHost._init` 里**各解析一次**
(代价要先量)。已同步进 `CLAUDE.md` 的 §断线重连 那条登记。

**跨会话纪律(本仓 2026-09-28 实测得来,必须遵守)**:
- **一个文件一次只有一个持有者**,换手时报「`<文件>` 已交还,commit `<sha>`」。
- **提交前逐文件 `git diff` 认领每个 hunk** —— `git status` 只挡得住"别人的文件",
  挡不住"别人的改动落在你正在改的文件里"(后者在 `git status` 上**逐字相同**、必然放行)。
- **审阅包用 `git show <单提交>`**,不要用 `BASE..HEAD` 范围(本仓有并发提交,范围会把别人的带进来)。
- **提交按名 `git add`**,绝不用 `-A`;**新建脚本要把 `.uid` 一起入库**。
