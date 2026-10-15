# %s

> **本文件从 [`registered-debt.md`](../registered-debt.md) 拆出**（2026-10-13，原文件 888 行 / 126KB 越过了 `CLAUDE.md:5` 那条 64KB 上下文线）。返回索引：[`registered-debt.md`](../registered-debt.md)。
> ★ 文档会过期 —— **任何冲突以源码为准**，读之前先 `grep` 复核；`文件:行号` 与本仓自述一致地会漂。

## 一、既有红 —— **这些不是守卫,别拿它们的行为当证据**

| 探针 | owner | 最后复核 | 症状 | 为什么留着 | 销掉的条件 |
|---|---|---|---|---|---|
| [`tests/probe/team_match_probe.sh`](../../tests/probe/team_match_probe.sh) | 用户(六人真链路只能由用户跑) | 2026-10-04 **静态复核,未跑**;★ **2026-10-08 补跑了一次(见行末)** | **长期 FAIL,且判词与实况矛盾**:判词说"大厅队伍表是空的 / 45s 内没有 3v3 房",而**同一次跑**的客户端日志里房建成了、客户端进了等待室。★ **2026-10-04 状态订正**:根因**已修** —— `9003dae`(2026-09-28)"客户端不再被拨到生产云服 —— 预置 `PvpSession.server_address`",正是本行原先那句"客户端被某个不是探针大厅的东西服务着"。但**修复后没有留下六人整跑的判决**,而三个落点互相矛盾(`docs/superpowers/plans/2026-09-29-unowned-debt-sweep.md:11` 说"已修待验"、`.superpowers` 账本记 2026-09-20 曾 PASS 33 条、同一账本靠后段落仍称"既有的 FAIL") | 根因未钉死时的追查成本太高,且它是**唯一**"过真协议"的 3v3 覆盖 | **跑一次六人整链路**(池外 29200/29250、不碰 7777):绿 ⇒ 按上面「销掉时删行」删掉本行,并同步 `tests.md` / `handoff` / `AGENTS.md` §5 的复述;红 ⇒ 把"已修 `9003dae`、仍红"写进症状列并重新算根因 |
★★ **2026-10-08 六人整跑判决(补上了债单说缺的那一次)**:手工单跑 `team_match_probe.sh` ⇒ **FAIL(8 条)**,
根因行是 `FAIL 房主没有点开始(房内 6 人,队号表 { 1: 1, 2: 2, 3: 1, 4: 1, 5: 2, 6: 2 })`。⇒ **两点更新**:
① **旧的"队伍表是空的"症状已消失** —— 6 人全在、队号表有效(`9003dae` 那笔修复**有效**,本条原写的怀疑可以销掉);
② 现在的卡点是**探针脚本化的"房主点开始"那一步**,后面 7 条 FAIL(出生点 0/6、无子弹/手雷读数、无 ROUND_OVER、
自杀 0 端、ESC 离场)全是它的**下游**。★ **归因**:该次运行日志里 `RPC configuration` / `Unable to send` /
`channel` / `SCRIPT ERROR` **一条都没有**(`team_match_start` 走 `transfer_channel = 0` = 引擎系统默认道,**本批没动**)
⇒ **不能归因给 closeout 批的 Task 4/5**;要查的是探针的驱动脚本与等待预算。 |
| `ground_net_probe.tscn`（已删·2026-10-09） | 未认领 | 2026-10-04 **静态复核,未跑** | **既有抖动**:机器人走位在**随机图**上卡死(探针自己的头注也写了这一点) | 抖动来源是"每进程随机选一份 `.cyrm`"(见 [`world.md`](world.md));探针本体仍能看趋势 | 给探针**钉图**(取图类脚本的既有纪律) |
| `brawl_rollback_probe.tscn`（已删·2026-10-09） | 未认领 | 2026-10-04 **静态复核,未跑**；2026-10-08 **按测试经济 D5 移出默认批** | 它是"贴身缠斗扫描仪器",但**读 N≥4 时本身在抖**,且**变异下仍有一格假绿** | ★ **处置已变**：它**作为守卫不可靠**（上面那句），但它是 `PredictionRollback._close_enough` **容差常数的测量台**（[`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的注释指着它说"要动它得重跑"）⇒ **移入 `tests/manual/`，不删**；**它不再是批内的红/假绿问题**，而是一条**人工测量台**（跑法见 `README.md`（已删·2026-10-09）） | 抖动与那一格假绿**不再挡批**；若将来要把它变回守卫，得先让它在 N≥4 下稳定、并把判据写成行为级 |
| `reconnect_smoke.gd`（已删·2026-10-09） | 未认领(由 UI→`.tscn` 迁移那条线留下) | 2026-10-04 **实测**(聚合入口 `bash tests/run_all.sh` 首跑) | **断言的锚点没了 ⇒ 该条守卫今天不守任何东西、且永远红**:判词原文 `RECONNECT SMOKE FAILED: 1` + `[FAIL] ★ 主菜单联机入口未走 PvpSession.reset()`(rc=1,日志 tests/.run_all_logs/smoke/reconnect_smoke.log)。★ **根因不是行为回归** —— [`scenes/main_menu.gd`](../../scenes/main_menu.gd):219 那行**仍在**调 `PvpSession.reset()`;是 `reconnect_smoke.gd`（已删·2026-10-09）:294-295 把判据限定在 `_build_menu_buttons` 的函数体内,而按钮已搬进 `main_menu.tscn`、接线改到 `_wire_menu()`([`scenes/main_menu.gd`](../../scenes/main_menu.gd):207)⇒ `_func_body` 取到空串 ⇒ `count("PvpSession.reset()") >= 1` **恒假** | 它是 C1 纪律("进页复位、但**不**清回局凭据")的**唯一**源码级断言;删掉等于把那条纪律的守卫一起删掉 | 锚点从 `_build_menu_buttons` 换成 `_wire_menu`(或改成"整个文件去注释后至少一处 **且** 落在 `%MultiBtn` 那个 lambda 里")⇒ 转绿后**删掉本行**,并同步 `tests/known_red.txt` |
| `elite_drop_probe.tscn`（已删·2026-10-09） | 未认领 | 2026-10-04 **实测 7/7 全崩** | **判词肯定、退出时 segfault**:`rc=139`,而日志**末行**就是 `ELITE DROP PROBE: OK(真击杀 → 结晶 FX 出现 → 吸收入账 +300 颗粒)`、`FAIL` 词 **0** 行。跑法 `timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/elite_drop_probe.tscn`,**同配置 7 次全部 139**(3 次单跑 + 2 次跑批内 + 复跑 2 次);★ 两次复跑的**判词行** md5 相同。⇒ 断言结论**不受影响**,`run_all.sh` 把它记成 `OK+RC`(**不算红**),但它在真链路里**会**留孤儿/占端口那类麻烦 | 判词仍 OK、能继续看趋势(它是"精英掉落 → 结晶 FX → 吸收"链条上唯一的行为载体) | 找出退出时崩的那条链(先怀疑 SubViewport/贴图析构 —— `ground_net_probe` 头注记过同一类"只有真窗口/真析构才照得出来"的问题)⇒ `rc=0` 后**删掉本行** |
| `elite_drop_probe.tscn`（已删·2026-10-09） | (并入上一行) | 2026-10-04 **同配置跑两次** | ★ **顺带照实记一条同族边界**:该探针**跑在随机图上**(与 `climb_probe` 修 `c5804f4` 之前同一族)⇒ **非判词读数两次不一致**:墙碰撞 shapes 4032/4527、敌人数 65/24、开阔地板格 670/889、击杀距离 2294/4159px、`FX已释放` false/true。**只有判词行**可比 | 同上(读数不删 —— 探针是扫描仪器) | 按 `c5804f4` 的写法给该探针**钉图**(`MazeGenerator.set_map_file` + `load_map_file`),让非判词读数也可比;这也是 `ground_net_probe.tscn`（已删·2026-10-09） 那一行"给探针钉图"的同一条纪律 |

★ **影响面照实写**:第一条意味着 **3v3 真链路今天没有可信的端到端守卫** —— 改 3v3 时别把"探针绿了"当证据,要另找覆盖(或先补守卫)。

★ **2026-10-13 订正（原文与现状相反）**：原写"后两条各自在 `tests/known_red.txt` 里有对应基线行 —— `reconnect_smoke` 是**真红**(进基线)"。**今天这份基线是空的(0 条)** —— `reconnect_smoke` / `elite_drop_probe` / `ground_net_probe` / `brawl_rollback_probe` **都已在 2026-10-09 的测试面削减里删除**，`tests/known_red.txt` 的注记写着"同批已删除"。保留此段只为记住**那两条线的区别**（这也是 `run_all.sh` 判词分类的由来）：

- 进 `known_red.txt` 的 = **真红**（让聚合入口能报"新红"而不是永远 FAIL）；
- `OK+RC` = 判词 OK 但退出码非 0 ⇒ **不算红**，`run_all.sh` 每跑一次单列出来。

⇒ 今天要判断"有没有已知红"，看 `bash tests/run_all.sh --list` 尾部打印的 `KNOWN-RED BASELINE`，不要照抄本文件的历史叙述。
★ 这里只登记**不修**:`reconnect_smoke` 的锚点属于别的域(UI→`.tscn` 迁移),要单独立项。
