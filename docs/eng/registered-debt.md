# 登记欠账(既有红 / 待还的债)

> 本文件是**这两类**欠账的清单:① 长期红的探针(**不算守卫**),② 重复真相源(该改生成式的地方)。
> ★ **2026-10-04 校正口径**:此前 `AGENTS.md` 称本文件是"**唯一**清单",而实际只有这两类 ——
> 性能/视觉/文档/工程类的债住别处,落点见 §四。**动手前先看本文件,再看 §四 那张表**。
> 纪律:每条都写清 **owner / 最后复核 / 症状 / 为什么留着 / 什么时候能销**;销掉时**删行**
> (历史在 git 里,不留"已修"注);**入库文档不得引用 `.superpowers/`**(那里 gitignore,别人 404,
> 要用的上下文请摘抄进来)。
> 相关:[`tests.md`](tests.md) §守卫边界 · [`AGENTS.md`](../../AGENTS.md) §2「反重复」· [`CLAUDE.md`](../../CLAUDE.md)

## 一、既有红 —— **这些不是守卫,别拿它们的行为当证据**

| 探针 | owner | 最后复核 | 症状 | 为什么留着 | 销掉的条件 |
|---|---|---|---|---|---|
| [`tests/probe/team_match_probe.sh`](../../tests/probe/team_match_probe.sh) | 用户(六人真链路只能由用户跑) | 2026-10-04 **静态复核,未跑** | **长期 FAIL,且判词与实况矛盾**:判词说"大厅队伍表是空的 / 45s 内没有 3v3 房",而**同一次跑**的客户端日志里房建成了、客户端进了等待室。★ **2026-10-04 状态订正**:根因**已修** —— `9003dae`(2026-09-28)"客户端不再被拨到生产云服 —— 预置 `PvpSession.server_address`",正是本行原先那句"客户端被某个不是探针大厅的东西服务着"。但**修复后没有留下六人整跑的判决**,而三个落点互相矛盾(`docs/superpowers/plans/2026-09-29-unowned-debt-sweep.md:11` 说"已修待验"、`.superpowers` 账本记 2026-09-20 曾 PASS 33 条、同一账本靠后段落仍称"既有的 FAIL") | 根因未钉死时的追查成本太高,且它是**唯一**"过真协议"的 3v3 覆盖 | **跑一次六人整链路**(池外 29200/29250、不碰 7777):绿 ⇒ 按上面「销掉时删行」删掉本行,并同步 `tests.md` / `handoff` / `AGENTS.md` §5 的复述;红 ⇒ 把"已修 `9003dae`、仍红"写进症状列并重新算根因 |
| [`tests/probe/ground_net_probe.tscn`](../../tests/probe/ground_net_probe.tscn) | 未认领 | 2026-10-04 **静态复核,未跑** | **既有抖动**:机器人走位在**随机图**上卡死(探针自己的头注也写了这一点) | 抖动来源是"每进程随机选一份 `.cyrm`"(见 [`world.md`](world.md));探针本体仍能看趋势 | 给探针**钉图**(取图类脚本的既有纪律) |
| [`tests/probe/brawl_rollback_probe.tscn`](../../tests/probe/brawl_rollback_probe.tscn) | 未认领 | 2026-10-04 **静态复核,未跑** | 它是"贴身缠斗扫描仪器",但**读 N≥4 时本身在抖**,且**变异下仍有一格假绿** | 留着仍能看见趋势 | 抖动与那一格假绿都消掉 |
| [`tests/smoke/reconnect_smoke.gd`](../../tests/smoke/reconnect_smoke.gd) | 未认领(由 UI→`.tscn` 迁移那条线留下) | 2026-10-04 **实测**(聚合入口 `bash tests/run_all.sh` 首跑) | **断言的锚点没了 ⇒ 该条守卫今天不守任何东西、且永远红**:判词原文 `RECONNECT SMOKE FAILED: 1` + `[FAIL] ★ 主菜单联机入口未走 PvpSession.reset()`(rc=1,日志 tests/.run_all_logs/smoke/reconnect_smoke.log)。★ **根因不是行为回归** —— [`scenes/main_menu.gd`](../../scenes/main_menu.gd):219 那行**仍在**调 `PvpSession.reset()`;是 [`reconnect_smoke.gd`](../../tests/smoke/reconnect_smoke.gd):294-295 把判据限定在 `_build_menu_buttons` 的函数体内,而按钮已搬进 `main_menu.tscn`、接线改到 `_wire_menu()`([`scenes/main_menu.gd`](../../scenes/main_menu.gd):207)⇒ `_func_body` 取到空串 ⇒ `count("PvpSession.reset()") >= 1` **恒假** | 它是 C1 纪律("进页复位、但**不**清回局凭据")的**唯一**源码级断言;删掉等于把那条纪律的守卫一起删掉 | 锚点从 `_build_menu_buttons` 换成 `_wire_menu`(或改成"整个文件去注释后至少一处 **且** 落在 `%MultiBtn` 那个 lambda 里")⇒ 转绿后**删掉本行**,并同步 `tests/known_red.txt` |
| [`tests/probe/elite_drop_probe.tscn`](../../tests/probe/elite_drop_probe.tscn) | 未认领 | 2026-10-04 **实测 7/7 全崩** | **判词肯定、退出时 segfault**:`rc=139`,而日志**末行**就是 `ELITE DROP PROBE: OK(真击杀 → 结晶 FX 出现 → 吸收入账 +300 颗粒)`、`FAIL` 词 **0** 行。跑法 `timeout 180 "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/elite_drop_probe.tscn`,**同配置 7 次全部 139**(3 次单跑 + 2 次跑批内 + 复跑 2 次);★ 两次复跑的**判词行** md5 相同。⇒ 断言结论**不受影响**,`run_all.sh` 把它记成 `OK+RC`(**不算红**),但它在真链路里**会**留孤儿/占端口那类麻烦 | 判词仍 OK、能继续看趋势(它是"精英掉落 → 结晶 FX → 吸收"链条上唯一的行为载体) | 找出退出时崩的那条链(先怀疑 SubViewport/贴图析构 —— `ground_net_probe` 头注记过同一类"只有真窗口/真析构才照得出来"的问题)⇒ `rc=0` 后**删掉本行** |
| [`tests/probe/elite_drop_probe.tscn`](../../tests/probe/elite_drop_probe.tscn) | (并入上一行) | 2026-10-04 **同配置跑两次** | ★ **顺带照实记一条同族边界**:该探针**跑在随机图上**(与 `climb_probe` 修 `c5804f4` 之前同一族)⇒ **非判词读数两次不一致**:墙碰撞 shapes 4032/4527、敌人数 65/24、开阔地板格 670/889、击杀距离 2294/4159px、`FX已释放` false/true。**只有判词行**可比 | 同上(读数不删 —— 探针是扫描仪器) | 按 `c5804f4` 的写法给该探针**钉图**(`MazeGenerator.set_map_file` + `load_map_file`),让非判词读数也可比;这也是 [`ground_net_probe.tscn`](../../tests/probe/ground_net_probe.tscn) 那一行"给探针钉图"的同一条纪律 |

★ **影响面照实写**:第一条意味着 **3v3 真链路今天没有可信的端到端守卫** —— 改 3v3 时别把"探针绿了"当证据,要另找覆盖(或先补守卫)。

★ **2026-10-04 加的两行(聚合入口首跑挖出来的)与 `tests/known_red.txt` 的关系**:后两条各自在 [tests/known_red.txt](../../tests/known_red.txt) 里有**对应基线行**——
`reconnect_smoke` 是**真红**(进基线,让聚合入口能报"新红"而不是永远 FAIL);`elite_drop_probe` 是 `OK+RC`(**不算红**,所以**不**进基线,但 `run_all.sh` 每跑一次都会单列出来)。
★ 这里只登记**不修**:`reconnect_smoke` 的锚点属于别的域(UI→`.tscn` 迁移),要单独立项。

## 二、重复的真相源(该改成生成式)

**判据**:同一个值必须**抄两处以上**,而且已经有一条守卫盯着它们是否相等 —— 那就是"重复 + 守卫"的永久税。优先改成「单一来源 + 生成器 + `--check`」。

| 重复的东西 | 现在的形态 | 打算怎么改 |
|---|---|---|
| HUD 底板色 `C_PLATE`(黑 0.1) | 唯一源在 `ui/factory/ui_factory.gd`;两个 `.tscn`(`ui/hud/pvp_hud.tscn` / `ui/hud/team_hud.tscn` 的 `Plate`)存**字面量**,由 `tests/smoke/ui_palette_single_source_smoke.gd` 钉住逐位相等 | 仿 `tools/gen_menu_theme.gd`:由调色板**生成**这两个 stylebox,守卫改成 `--check`。★ **别碰 HUD 视觉**(用户冻结令),只改"这个值是怎么来的"。★ **2026-10-04 补**:别照 `gen_menu_theme.gd` 现在的样子抄 —— 它自己也手抄了 `UiFactory` 的 `64/46`(`tools/gen_menu_theme.gd:218-221` vs `ui_factory.gd:305`),抄它会把同一笔税再交一次;正确姿势是调**生产入口**(`F.call("skin_menu_panel", …)`)再读回 stylebox —— 镜像守卫 `menu_theme_mirror_smoke.gd:190/200` 正是这么取值的 |
| 菜单 Theme `ui/theme/menu_theme.tres` | **生成链已建成**:`tools/gen_menu_theme.gd` 生成 + 镜像守卫(带条数下限,读**生产产出**)。★ **2026-10-04 校正**:称它"**范本**"过头了 —— 它只做到"生成物与守卫对账",没做到"**单一来源**"(上面那条手抄就是缺口) | —— |
| 编辑器内嵌的敌人注册表 | **已完成,留作范本**:`node level_editor/sync-enemies.js`(+ `--check` 只校验不写盘) | —— |

★ 新代码遇到"同一个值要抄两处"时,**直接上生成式**,别再补一条守卫。

## 三、怎么销一条

1. 修好 → **同配置跑两次**(分清噪声与信号);
2. 把这条从本文件**删掉**;
3. 若它本来是"守卫",按 [`tests.md`](tests.md) 的要求补一句「它现在能给的最强保证是什么、测不到什么」。

★ **销案记录的格式范本**(2026-10-04 补):[`docs/superpowers/plans/2026-09-29-unowned-debt-sweep.md`](../superpowers/plans/2026-09-29-unowned-debt-sweep.md)
的「本轮执行结果」那张表 —— 逐项写 **结果 + 提交 sha**,并含两段判决:`### ★ A4 是**伪欠账**(实读后推翻)` 与
`### ★ C1 …**不再是欠账**`。**"推翻一条欠账"和"修掉一条欠账"都要留同样详细的记录**。

## 四、本文件**不收**的那些债住在哪(2026-10-04 加)

| 类别 | 落点 |
|---|---|
| 性能 / 视觉取舍(61MB 地形显存、结算页"行底"、取景 150% 像素取舍) | [`docs/superpowers/handoff-2026-10-03.md`](../superpowers/handoff-2026-10-03.md) §2.4 |
| 各域的「已知边界(登记不修)」 | 对应 [`docs/eng/`](.) 域文档正文里,以「★ 已知边界(登记)」开头(如 `weapons.md` 的容量分叉、`render.md` 的挤压副产物) |
| 代码内契约与残留 | 源码注释里的「★ 已知」「★ 待修」 |
| 逐任务评审判决与恢复地图 | `.superpowers/sdd/progress.md`(**gitignore**) |
| 2026-10-04 全仓审计发现的 20 条(含 `[debug]` 键失效、发布包打进 tests、`ax` 无界等) | [`docs/eng/audit-2026-10-04-design-conventions.md`](audit-2026-10-04-design-conventions.md) §7 的批次清单,等人工挑入本表 |

## 五、守卫强度已知缺口(2026-10-04 加)

**这些不是"红",是有守卫但保证比读起来少** —— 与 [tests.md](tests.md) 末节同一类,发现者都是审阅者不是实现者。

1. **`tests/probe/tile_collision_probe.gd` 用"跑完闩"(`_ran_to_end`)而不是计数闸。** 它只覆盖
   **`_run()` 自身**出错(那时闩为假 ⇒ `_finish()` 打 FAIL);但按 [`tests/lib/probe_base.gd`](../../tests/lib/probe_base.gd)
   文件头的权威表述,**helper 内部**出错只结束那个 helper、`_run()` 继续跑到底 ⇒ 闩为真 ⇒ 断言被静默跳过而
   verdict 照打 `ALL-OK`。**权威形式是 `_checks >= EXPECTED_CHECKS`**(本仓对新场景探针的要求)。
   补法:给该文件加 `_checks` 计数 + `EXPECTED_CHECKS` 下限(要逐个断言点计数,这是本条一直没做的原因)。
2. **客户端 `Level0` 也注册了格级 `on_destroyed`**(`scenes/level_0.gd:246`,在 `pvp_mode` 早退**之前**),
   它的"惰性"依赖"客户端不调 `damage_tile`"这个事实,而**这条事实没有守卫**:`tests/smoke/laser_weapon_smoke.gd:64-67`
   只要求文件里**提到** `Level0.pvp_mode`(没绑到 `_damage_tiles` 那条闸);子弹那半有
   `tests/smoke/bullet_tile_fx_smoke.gd:63-68` 兜住。★ 风险:那条闸哪天一回归,客户端会**本地**清掉 16 个 `sub_hp`
   ⇒ 与服务器分歧;本轮新增的接线把这条的爆炸半径放大了。
   ★ **结构性解法(终审 R1,已核安全)**:把 `scenes/level_0.gd:246` 那行注册**移到 `pvp_mode` 早退之后** ——
   `pvp_game.gd:38` / `team_game.gd:40` / `royale_game.gd:33` 都在**实例化 Level0 之前**就设好
   `Level0.pvp_mode = true` ⇒ PvP 客户端**根本不会注册**它,把"没有守卫的纪律"变成"**不可能发生**"。
   现有 `tile_collision_probe` 相③b 正好是它的守卫:单机路径若不再注册,相③b 立刻红。
   同样留到下一批(终审之后不再新增未过审的生产改动)。
3. **`tests/probe/perf_probe.gd:179/205-211` 是"服务器清格子格"算法的第二份口径**(仍是 v3 的 `*2` / `x/2`)。
   ★ 准确说法是"**口径已分家的合成消融**",**别**登记成"重复真相源待合并" —— 它清 4/16 个子格、`:179` 选块也用的旧换算,
   所以它的 timing 与覆盖率跟生产实现不是一回事。

4. **`tests/probe/destroyed_cells_probe.gd` 的反向断言"钉实象限"依赖格坐标奇偶**(终审 M2)。
   被钉的是 `{行 0-1 × 列 2-3}` 那 4 个子格,只有 `cell.x` **奇**、`cell.y` **偶**时才对得上 `*2` 越界写法
   会去清的位置(今天选中的 `(9,6)` ⇒ `(4,3)` 正好对得上,所以那次变异确实红了)。换奇偶组合后钉的地方
   会错位、这条反向断言**静默失去力量** —— 但变异仍被 `left == 0`(真格 16 子格没被清)抓住,故**不阻塞**。
   修法:偏移从 `cell.x % 2` / `cell.y % 2` 推导,或**四个象限都钉**。
5. **`tests/probe/tile_collision_probe.gd` 的 `_scan()` 不断言采样点数 `n > 0`**(终审 M3)。
   全场调用(相⓪/相⑥)安全;但新增的窄调用 `_scan(world, subs3b, "相③b…")` 只采 16 点,
   若这 16 点恰好全落在链邻域(锁链顶/底的薄碰撞条会被整点跳过)⇒ **静默变成 0 点扫描**,
   打印 `抽样 0 点` 却什么都没验。一行 `if n == 0: _fail(...)` 即可封住。
6. **`TileDefs.sub_alive` 没有 `sub_cols == 0` / 越界守卫**(终审 M5)。它的兄弟访问器
   (`sub_texture` / `restore_sub` / `hp_grid_at` / `set_hp_grid`)都有。今天**无可达调用方**
   (`destroy_cell` 先自查边界、`damage_sub` 自查、`CollisionBuilder` 有 `sub_cols != 0` 门),
   所以只是"一致性 + fail-closed"的补法,不阻塞。
7. **同一算法的 4×4 遍历已散成 9 处**(终审 R3):生产 4 处(`TileDefs.destroy_cell` / `zero_cell_sub_hp`
   / `MatchCombat._on_tile_destroyed` 的清格 / `pvp_match_client` 的远端展开)+ 探针 5 处。
   **16px/4×4 这个约定已经因此出过三次 shipped bug**(`match_combat` 的 `*2`、缺"格→子格"的桥、`perf_probe`
   的过期口径)⇒ 属本文件 §二「该改成生成式」的同类:**先消重复,再谈守卫**。
   候选:`TileDefs.subs_in_cell(cell: Vector2i) -> Array[Vector2i]`(或接受回调的迭代器)作为单一来源。
   ★ 本轮**不做**:终审之后不再新增未过审的生产改动(见账本 ruling),留给下一批。
8. **`_hp` / `_type` 的越界回落是 `fill(1)` / `TYPE_WALL`**(终审 R5):`hp_of(0) == 1`、
   `type_id_of(越界)` 返回"墙" —— 全是**静默**回落。今天对 Task 3 新增的 `<= 0` 守门**不可达**
   (终审已逐行核:`_restore_sub` 在 `tex == 0` 时就 early-return),但任何人重写那个守门都会踩。

9. **`tests/smoke/pvp_match_smoke.sh` 的固定启动预算太紧,且失败信息指向错误的嫌疑对象**(2026-10-04 实测)。
   它起服务器后 `sleep 3`、起建房客户端后 `sleep 2`,然后 `grep` 服务器日志找房间号;找不到就打
   **「服务器未建房间」**并走 `exit 1`。★ 但真因可能是**客户端还没加载完** —— 本机实测:同一棵树、
   同配置连跑两次都红(空闲机第三次同样红),把副本里的 `sleep 3`/`sleep 2` 改成 `12`/`12` 后
   **一次就绿**(`SMOKE_MATCH OK create/join`)。⇒ 症状与真因**分家**,且**与代码无关**才是真正危险的地方
   (排查人第一反应会去怀疑服务器/网络)。★ 同族脚本里凡"固定 sleep 后 grep 就断言"的都要按这条重看。
   ★★ **同一支的早退路径还漏杀孙进程**:`:28` 只 `kill_procs $SERVER_PID $A_PID; kill_port`,
   **没调** `kill_port_range 7800 8300` ⇒ 大 spawning 的 **worker(孙进程)**留着(实测漏 4 个 / 2 个),
   正是该脚本头注自己警告的"毒害下一支"。修法:早退路径也调 `kill_port_range`;根治则把固定 sleep
   改成**轮询等待**(有上限),这样既快又不脆。

10. **`tests/smoke/project_settings_smoke.gd` 只判「设置值与文件原文」,够不到「日志真的落盘」与「release 模板那半边」**(2026-10-04 加,与它同批落地)。
    - **它给的最强保证**:`project.godot` 里那三行**逐字存在**(④ —— 唯一拦得住 `d6d2440` 那种"键名被乱码吞掉"的形状),
      且 `max_log_files` 读回来 == 64(③ —— 引擎默认 5,删行或改值当场红)。★ 它的 ①② **不算守卫**:
      三个键都是**引擎内置**设置,`has_setting` 与文件里写没写无关,`.pc` 的引擎默认值本来就是 `true`
      (空工程实测,见 [`tests/smoke/project_settings_smoke.gd`](../../tests/smoke/project_settings_smoke.gd) 头注 `:15-31`)。
    - **它测不到什么(照实登记)**:① **"日志真的落到了 `user://logs/`"** —— 它只读 `ProjectSettings`
      与 `project.godot` 的原文,要证明"真的在写"得**真起一个进程**再看文件系统
      (`%APPDATA%/Godot/app_userdata/<项目名>/logs/`;审计 §1.2 记的默认路径是 `user://logs/godot.log`);
      ② **导出模板的 release 半边** —— 本处跑的是 **debug 模板**(`GODOT`,console 版),
      `enable_file_logging.pc` 的实际行为只在 release 导出产物上才算数,而产物那一侧今天**没有**守卫。
      ★ 别拿 worker 的 `--log-file` 当证据:那是**引擎选项**、写的是 `worker_<port>.log`
      ([`server/lobby/worker_launcher.gd`](../../server/lobby/worker_launcher.gd):94-104),与 `[debug]/file_logging/*` 这三键是**两条路**。
    - **为什么留着不补**:①要起进程、还依赖 `user://` 的宿主路径与可写性,形状超出"`-s` 冒烟"这一层;
      ②只能在**导出之后**量(要真导出一次),属产物级冒烟的活 —— 两条都不该塞进这条 `-s` 守卫。
    - **什么时候能销**:有产物级冒烟通道时 —— 在 [`tools/build_release.py`](../../tools/build_release.py) 的产物冒烟里加一步:
      起一次产物,再断言 `user://logs/` 里**新增**了本次会话的日志文件。
      ★ 注意它与 §七 第 3 条是**同一条通道问题**:发布产物上的守卫,得先把要跑的东西**随包发布**。

13. **`Settings.apply_display()` 的"非早退分支"(真开窗/真全屏)只有源码级证据**(2026-10-04 加)。
   - **它给的保证**:`tests/smoke/settings_display_smoke.gd` 钉住了"早退排在两个窗口调用**之前**"与
     "`_ready()` 在 `load_settings()` **之后**调它"(按**源码位置**断言),外加档表/默认值/钳位/落盘往返。
   - **它测不到什么**:绿跑**全在 headless** ⇒ `window_set_size` / `window_set_mode` 真的生效**没人验**
     (非 headless 会抢焦点)。**要闭环得跑一次非 headless 并取几何**(与窗口批 Task 0 同性质)。
   - ★ **写法税**:因冒烟按源码文本查那两个 API 字面量,`apply_display()` **函数体内**的注释**不得**出现
     `window_set_size` / `window_set_mode`。
14. **`tests/probe/menu_shot_probe.gd` 的"取屏自证"是绊线不是保证**(2026-10-04 实测)。
   16×16 粗比在深色 UI 上会被摊薄:4 次取屏里 3 次抓到遮挡、**1 次放过**(设置页粗差 **0.0677** < 阈值 0.08,
   而那张图里开始菜单盖住了画面中间一大块)⇒ **用它取图必须人看图**,别把自证通过当"没被遮挡"。
15. **窗口/显示的接线没有常驻守卫 + Theme 没有 `OptionButton`**(2026-10-04 加)。
   - 设置页「显示」组"真落盘 + 真 apply 到窗口"只有**一次性 scratch 探针**(gitignored)证明过;要常驻得**新建**探针文件。
   - `tools/gen_menu_scene` 的 VARIANTS 里**没有 `OptionButton`** ⇒ 分辨率下拉只能挂
     `theme_type_variation = &"BtnLegacy"`(合法:`OptionButton < Button`,实测生效),**弹出列表**仍是引擎默认皮。
   - ★ 另一条**未裁决**的边界:在**装不下 1920×1440 的屏**(如 1080p,高 1080 < 1440)上,
     "首次运行要不要自适应换个小窗口"**还没定**(两个方向见窗口计划 Task 1 之前那段)。

16. **§五.13 已销账；§五.14 那条绊线又添一种误判（假阳）**(2026-10-04 Task 6 实测后由控制器补记)。
   - **§五.13 销账证据**：非 headless 实跑两次 —— `display/res_index=2`（基准档，放得下）⇒ 窗口 `(1920,1440)@(320,44)`；
     `res_index=3`（2560×1920，**放不下**可用区 `2560×1528`）⇒ 窗口 `(1920,1440)@(320,44)`，**等于 `fit_resolution(可用区)` 且不等于存档档**
     ⇒ "放得下就照存档 / 放不下就收进屏幕"两条路**都**有实测，位置两次**零误差**（判据带 ±2px 容差）。
     ★ **保留两条边界**：① **多屏 / 可用区原点非零本机造不出来**（两次原点都是 `(0,0)` ⇒ `usable.position` 这一项**等于没验**）；
     ② 那次断言是**一次性 scratch 脚本**（gitignored）⇒ **不是常驻守卫**，回归时不会自己红。
   - **§五.14 的补充（假阳）**：本机整屏被**系统级压暗到约 0.553×**（浏览器纯白实测 141/255；PIL 与 Godot 取屏**同值** ⇒ 是系统级、不是我们渲染的问题）。
     ⇒ 那个 16×16 粗比自证对**全局压暗没有免疫力**：本轮 **0.0880 / 0.134 判红而图是对的**（**假阳**），
     而它此前已有一次 **0.0677 判绿而图被遮挡**（**假阴**）。⇒ 结论加强：**它是绊线，两头都会错**，
     **一律要人看图**；且看图时**别把偏暗当渲染问题**。

## 六、功能性已知边界(2026-10-04 加)

**这一节既不是"红",也不是"守卫漏了",而是"回溯这件事本身的保真度上限"** —— 与各域文档里以「★ 已知边界(登记)」开头的那类同类。

1. **回溯不还原「被打磨、但还没碎的砖血」**(owner 未认领;最后复核 2026-10-04,实现时静态复核)。
   - **症状**:瓦片回溯账本 `_tile_pending` 只在**子格死掉**时记账(`scenes/level_0.gd` 的 `_on_sub_destroyed`
     里那句 `_tile_pending.append`)⇒ 格级 `hp_grid` 的**部分**磨损、以及活子格的 `sub_hp` 磨损**都不进账本**。
     "树干 hp30 拿激光磨到 6 时按回溯",回溯后树干**仍是 6**,磨掉的那 24 点不还原。
   - ★ **根因同一个,表现形式按"最后一击走哪条路径"分叉**(两条都要看,别只读上面那半边):
     - **`damage_tile`(激光)打空**的格:`hp_grid` 被归 0 ⇒ 回溯时 Task 3 补的那句
       `TileDefs.set_hp_grid(cell, hp_of(tex))` 把它还到**满血基线** ⇒ **正常**。
     - **`damage_sub`(子弹)打空、而此前已被磨过**的格:`damage_sub` 只清 `grid`、**不碰** `hp_grid`
       ⇒ 该格 `hp_grid` 仍是那个**正值**(如 6)⇒ `<= 0` 守门**有意不写**(见 `level_0.gd` 的注释订正)
       ⇒ 回溯后**仍是 6** ⇒ **"回溯后一发即碎"在这条路径上依然存在**。这半边才是本条最容易被漏读的形态:
       它**不**发生在"尚未被打碎"的时候,而发生在"**已碎、但碎在子弹路径上**"的时候。
     (今天能还原的只有两类:**死掉的子格** = 账本条目的口径;**被激光打空的整格** = 上面那句。)
   - **为什么留着**:属 **rewind 保真度**范围,与本轮的"格级 / 子格分家"(幽灵砖 / 幽灵墙)是**两件事** ——
     后者是**正确性**缺陷(同一格被两套表读出两个答案),这里只是"回溯粒度 = **死亡事件**、不是 **HP 变化量**"。
     要销得让**每一次扣血**都进账本,账本条目数、录制开销与回溯还原次数都会显著变多,还得与
     `SNAP_SECONDS` 的裁剪口径重新对齐。
   - **什么时候能销**:把"**格级 HP 的变化量**"也纳入回溯账本(记账口径从"死亡事件"改成"HP 变化量");
     届时 `scenes/level_0.gd` 里那句 `if TileDefs.hp_grid_at(cell) <= 0` 的守卫也可以去掉,
     `_restore_sub` 改成无条件写回账本里的 HP。
2. **格级 HP 基线的"纹路口径"两侧不一致(仅混纹理格)**(owner 未认领;最后复核 2026-10-04,实现时静态复核)。
   - **症状**:格级 `hp_grid` 的基线是 `hp_of(`**16 子格的多数纹理**`)`(`MapFormatV4.flatten_scene`
     把 4×4 子格压成一格时的口径,`TileDefs.init_hp` 照它建表);而回溯写回用的是**单个子格**的纹理
     (`level_0.gd` 的 `hp_of(tex)`,`tex = current_subgrid[sub]`),探针相④b 期望的也是 `subs3b[0]` 的。
     在**混纹理格**上三者会不同。★ **但失配不是"先被复原的那个子格决定写入值"** —— 同一帧那 16 次
     回调共享**一条**账本条目,`_restore_sub` 按插入序(=`destroy_cell` 的**行主序**)回放 ⇒ 写进去的
     其实是 `hp_of(subs3b[0])`,与探针期望**一致**(终审逐行核过)。真正的失配要**复合情形**:清格那一击
     是激光、但此前已有子格被子弹打死(`destroy_cell` 只对**存活者**发回调)⇒ 首个"存活"子格的纹理
     与格级多数纹理不同,才会分家。
     ★ 今天**没有**触发:两张在库图 `demo.cyrm` / `newfactory.cyrm` 里"16 子格全活**且**混纹理"的格
     实测 **0 个**(离线解码测量)。★ 但这个"0 个"**没有随探针固化** —— GREEN 只覆盖每进程随机选中的
     **一个** `cell3b`,光看探针输出/`git diff` **核实不了全场**,换图(尤其编辑器真画的 4×4 混排图)
     就会变。探针那头也只在注释里写了这个前提。
   - **为什么留着**:修它要同时改**两侧**的口径(实现与探针),而"格级基线取多数纹理"本身是既有格式
     决策(见 `map_format_v4.gd` 文件头"对编辑器真画的 4×4 混排图是有损的");本轮的缺陷是"复原漏了
     `hp_grid`",不是这个压缩口径。
   - **什么时候能销**:两侧都改成 `TileDefs.hp_of(MazeGenerator.texture_of(<打包基线值>))`
     (实现用 `_pristine_grid[cell]`、探针用同一份基线),并在探针里**固化**"全场混纹理格计数"(而不是靠离线测量)。

11. **`tools/check_naming.py` 的路径检查只看**反引号 token**,不看 markdown 的链接目标**（`check_naming.py:123`
   的 `re.findall` 只捞 ``` `…` ```）(2026-10-04 实测,两条独立证据)。
   - 证据一(既有):本文件 §五 第 1 条那条链接原先写成了从 `docs/eng/` 出发**少一层**的相对路径 ⇒ **长期 404**,
     直到 2026-10-04 才被手工扫描发现并修掉。
   - 证据二(本轮引入):`audit-2026-10-04-design-conventions.md` 里本轮加的两条"已修"块链接也犯了同样的错
     (`](superpowers/…)` 从 `docs/eng/` 解析成 `docs/eng/superpowers/…`)⇒ 同样 404,同日修掉。
   ⇒ **它给的保证比读起来少**:文档改相对链接时**没有**任何机械化守卫;补法 = 让第四条也解析链接目标
   (右括号紧跟圆括号那种)并按所在目录核存在性(约多几行);★ 在那之前,改文档链接**必须手工核**。

12. **`tools/check_naming.py` 的 `DOC_FILES` 白名单不含审计报告与它的逐条复核文档**(2026-10-04 加,与上一条同族:都是"文档侧的机械守卫比读起来少")。
   - **它给的保证**:只查**列进 `DOC_FILES`** 的文档 —— 今天那张表(`check_naming.py:38-42`)是 `README.md` / `CLAUDE.md` / `RELEASE.md`
     + `docs/eng/` 的 **11** 份域文档。
   - **它测不到什么(照实登记)**:[`audit-2026-10-04-design-conventions.md`](audit-2026-10-04-design-conventions.md) 与
     [`conventions-review-2026-10.md`](conventions-review-2026-10.md) **都不在表里** —— 而它们正是"最该被检"的那类:
     审计报告被仓库里 **12** 份入库文件引用(含 `world.md` / `enemies.md` / `registered-debt.md` / `RELEASE.md` 这些**活文档**,
     很多地方把它当规范/出处引),复核文档一建立就被计划引用 ⇒ 它们正文里的反引号路径**一条都不检**,写错不会红;
     连带"C 文档不存在"那条也**只对列进表的文件生效**(没列进去 = 连文件本身存不存在都不查)。
   - **为什么留着不补**:★ **扩白名单不是这一批的活**(本批只做"订正 + 登记");且一扩就要先把全文的反引号 token 过一遍 ——
     里面混着"提议中、尚未存在"的文件名(例:复核文档 §4-16 特意**不给**那个尚未存在的聚合入口加反引号),盲扩会让检查**假红**。
   - **什么时候能销**:把这两份(及后续同类的审计/复核文档)加进 `DOC_FILES`,并配一条**能红**的自测
     (故意写坏一个反引号路径 ⇒ 检查必须 exit 1);在那之前,改这两份文档里的反引号路径与相对链接**必须手工核**(见上一条)。

13. **端口属主判不出来时,我们放弃清理并报错(不杀)⇒ 极端情况下双击开服会失败并打印提示**
    (`audit §2.1` 的护栏半边;owner 未认领;最后复核 2026-10-04 —— 改时用 dry-run 实测过三条分支 + 跑过 `kh_l5_probe`)。
    - **落点**:[`start_server.bat`](../../start_server.bat) 的 `:reap_port_holder` 与"收口重查" + [`core/net/proc_util.gd`](../../core/net/proc_util.gd) 的 `kill_udp_port`。
      取向 = **证不出是"我们这一族"的,就不杀**;名族 = **前缀** `Godot*` / `Cyancular*` / `The Cyancular*`
      **+ 本 exe 自己的名字**(`.bat` 从 `%GODOT%` 取 base name、`proc_util.gd` 取 `OS.get_executable_path()`,
      ⇒ 发布版 exe 被**改名**后,只要旧实例与本次要拉起的是同一个名字,照样清得掉 = Review Focus 5 那条失败模式)。
    - **症状(有意的取舍,不是 bug)**:7777 被**别人的程序**占着、或属主**进程名读不出来**(权限/竞态/进程已退出)时 ——
      · `proc_util.gd` 那条路径只打印 `[ProcUtil] UDP 7777 held by … -- not ours, not killing it`,**不杀**;
      · `.bat` 那条路径**连大厅都不起**:收口查得到端口就把话说明白(占主 PID + 进程名)然后 `pause` + `exit /b 1`。
    - **为什么这么取舍**:旧行为是**不管属主是谁一律强杀** ⇒ 端口被别人的程序占着时会**误杀别人的进程**(审计 §2.1)。
      代价不对称:**不杀**的代价只是"这次开服失败、用户手工处理";**误杀**的代价是端掉别人正在跑的东西。⇒ **宁可不杀,也不误杀。**
    - **动机仍在(已核)**:旧实例、旧 worker **就是我们这一族** ⇒ 照旧被杀,「占着 7777 ⇒ 新实例 bind 失败闪退」
      那个坑([`proc_util.gd`](../../core/net/proc_util.gd):5-9)仍然堵着。★ 但**这一条今天没有自动化守卫**:
      `kh_l5_probe` 第 3 条只**读文本**钉"修正写法在位 + 坏写法零处",**测不到**护栏分支的运行时行为;
      本轮的分支证据是**一次性 dry-run**(未入库,回归时**不会自己红**)。
    - **覆盖上限(照实登记,别当强保证)**:
      · 名族是**前缀**匹配 ⇒ 恰好以 `Godot` 起头的**别的**程序会被认成自己人(实测合成名 `Godotless` 命中)。
        风险被"它**真的**占着该端口"这层收窄限制住,但**不是**白名单兜底。
      · 把发布版 exe **改名**成不在这三族里的字串后:**同名**的旧实例仍认得出(第 4 条),
        但**不同名**时(例:`GODOT` 已指向改名后的新 exe、而占着 7777 的旧实例还是老名字,或反过来)
        ⇒ 清不掉、双击打印警告。
      · 名单在 `.bat` 与 `proc_util.gd` 里**各一份**(bat 没法 import GDScript)⇒ 改一处必须同时改另一处;
        今天**没有**守着两者相等的守卫(属 §二 那类"重复真相源",但两份都要能各自独立跑,本轮不做生成式)。
      · `proc_util.gd` 的第 4 条(自己的 exe 名)**含单引号时会跳过**(否则会破掉整条 PowerShell 串、
        连前缀三条一起失效);`.bat` 那侧走 `%~n` 与前缀,不受影响。
      · `.bat` 的收口最多等 **3 轮 × 1 秒**才判"清不掉" ⇒ taskkill 之后内核回收 socket 慢于 3 秒时会**假报**
        "被别的程序占着"(保守取向的代价:偏向不启动,不偏向误杀)。睡眠用 `ping -n 2 127.0.0.1` 而不是
        `timeout /t 1`:后者从 Git Bash 起 `.bat` 时会被 MSYS 的 `/usr/bin/timeout` 盖掉(实测报
        `invalid time interval '/t'`)⇒ 等待变 0 秒 ⇒ 又回到误判。
    - **什么时候能销 / 翻案条件**(任一):① 名族判定改成按**可执行文件路径/签名**而不是名字前缀
      (前缀过宽 + 改名清不掉这两条一起消);② 旧大厅退化成"不占端口就认不出"(则本条无意义);
      ③ "误杀别人"被重新判定为可接受(例如 7777 改成一个只可能属于我们的分配范围)。
      **翻案时必须同时改 `.bat` 与 `proc_util.gd` 两处名单**,并补一条**能红**的守卫 —— 今天只有 dry-run 证据。

3. **回溯写下的手持弹量被切枪帧的 `_ready` 冲掉**(2026-10-04 实测，owner 未认领；Plan B Task 5 已立)。
   - **实测**（`rewind_weapon_probe` 的仪器输出）：切枪帧 `mag_ammo=9` → 入树后 **4** → 下一帧 **9**。
   - **根因**：`_equip_index` 走 `call_deferred` 入树，并把 `pending_mag`（**条目值**）先置上；`_ready` 再把它写进 `mag_ammo`
     ⇒ 回溯刚写下的 `wlive` 被覆盖。**玩家可见**：回溯后切枪那一帧手里的弹量不是快照值。
   - **翻案条件**：Plan B Task 5 修好（改用 `WeaponComponent.apply_mag` 或调语句序）⇒ 销账并附提交号。
4. **`_equip_index` 把"走掉那把"的实弹出膛值写回条目，冲掉刚回溯的快照值**(2026-10-04 实测，owner 未认领；Plan B Task 5 已立)。
   - **实测**：`wmags=[11,1]` / `widx=1` ⇒ 回溯后 `held[0]=3`，**应为 11**（走掉那把把自己的出膛值写回了条目）。
   - **玩家可见**：跨武器回溯后，**没拿着的那把**的弹量被改成错的。
   - **翻案条件**：同第 3 条。

5. **Task 2「武器只读注入输入」的行为覆盖上限 —— ★ 已销账(2026-10-04,`938944d` 覆盖)**。
   ★ 与本节前四条不同,这一条是**测试覆盖上限**(与 §五 同族),不是回溯保真度。★ 按 §三 的销案纪律,下面留的是**销账记录**
   (历史症状 + 覆盖凭据 + 仍存的边界),不是"从没登记过"。
   - **登记时的实测**:Task 2 临时写了一条 `-s` 守卫(注入宿主 = 三边沿各自可置真、并**记录被问了几次**)覆盖三条路径 ——
     ① 半自动 ⇒ 同帧出 1 弹且**只问 `just_pressed`**;② 全自动 ⇒ 同帧出 1 弹且只问 `pressed`;
     ③ `heavy_aim` ⇒ 按下只进预瞄、**松开的当帧出 1 弹**、问 `just_released`。改前 / 改后**逐断言同结果**。
     ★★ **而那个守卫当时未入库**(跑完即删,只留日志文本)⇒ 它**对回归零保护**:今天重跑不会自己红,证据强度只等于"当时读过一次"。
   - **登记时的未实测(推断,不是实测)**:`m82a1`(重狙)、`grenade_launcher`(榴弹)、`laser_gun`(激光)、`s686`(霰弹)
     **没有逐把实跑**"注入宿主 ⇒ 同帧开火" —— 那三条路径是在 `pistol_test` 实例上把 `full_auto` / `heavy_aim` 标志置起来验的,
     **一个非手枪 `tscn` 都没实例化** ⇒ 连"真 `full_auto` 枪(`rifle_test` / `laser_gun`)、真 `heavy_aim` 枪(`m82a1` / `grenade_launcher`)"
     都只是**结构性推断**:唯一理由是 `WeaponBase` 的三个查询只按枪种标志选边沿、与弹道/弹夹无关 —— 而**没有任何守卫钉住这一点**。
   - **销账凭据(2026-10-04,commit `938944d`)**:`tests/probe/weapon_injected_fire_probe.gd`(`-s`,`extends SceneTree`)
     把上面那套断言**入库并参数化**到**全部 6 把真 `tscn` × 三种开火模式**(18 格;原生模式那一格**不改旗标**,另外两格才改)——
     判据 `WEAPON INJECTED FIRE PROBE: ALL-OK(158 条断言)`,并配 `_checks != EXPECTED_CHECKS` **条数闸**。每格断言:
     无输入相不开火 / 不耗弹(**阴性对照**)、注入该模式的边沿 ⇒ **同帧耗 1 发弹 + 冷却置满 + 真的产出弹丸或光束**、
     以及"本相只问该模式那一个(些)边沿"的**精确计数**;另有 12 条把每把 `tscn` **自己声明**的 `full_auto` / `heavy_aim` 钉住
     (把"哪把枪是哪种模式"从文献变成机器可查的事实)。
     ★ 变异逐条实测:`_attack_pressed` 恒 `true` ⇒ **36 红**(6 把枪的 `auto` 格全红);`_attack_just_released` 恒 `false` ⇒
     **24 红**(6 把枪的 `heavy` 格);半自动分支改问 `pressed` ⇒ **24 红**;往 `s686.tscn` 加 `full_auto = true` ⇒ 旗标断言红;
     去掉入树用的 `await`(节点不入树 ⇒ `_ready` 不跑)⇒ **18 条基线断言红**;
     ★ 人为制造一处脚本错误让**一格**断言静默跳过 ⇒ **只有条数闸红(135≠158)** —— 那正是没有这条闸时会假绿的形态。
   - **仍存的边界(照实登记)**:若有哪把枪**自己覆写**了开火判定,注入路径下它的开火行为今天仍**没有行为守卫** ——
     "覆写成别的边沿"会被边沿独占断言逮住,但"覆写成不读注入输入"只由 `tests/probe/kh_l3_probe.gd` 的**源码守卫**兜着
     (headless 下全局输入恒 false ⇒ 行为守卫对那条形状**天生无牙**,Task 2 实测)。**玩家可见面**:那种覆写会让联机里
     那把枪不开火 / 乱开火,而只有源码守卫会把改名级的写法拦住。
   - **仍未覆盖**:真链路里"注入 `attack=true` 的机器人宿主真的让武器出弹" —— 见下面第 6 条(归用户跑,本探针一个网络包都不发)。

6. **真链路里「注入 `attack=true` 的宿主」的唯一端到端载体是 PvP 机器人,而它未跑**(2026-10-04 登记;owner = 用户,六人真链路只由用户跑;Plan B Task 6 要求上纸)。
   - **载体(已核,不是照抄清单)**:`tests/harness/team_bot_input.gd`(`extends PlayerInput`,带 `attack` 字段与 `press_attack_edge()`)
     由 `tests/harness/team_match_watcher.gd` 的 `_pulse_attack()` 驱动,再经 `tests/probe/team_match_probe.sh` 起六人真链路 ——
     这是**唯一**会在真链路里注入 `attack=true` 的宿主。★ 另两个脚本手柄**不注入开火**:`tests/harness/ground_bot_input.gd`
     的三个 `_attack_*_raw()` **恒 false**;`tests/harness/soak_bot_input.gd` 虽读自己的 `_held/_pressed/_released`,
     但 `tests/probe/royale_soak_probe.gd` **从没给它排过** attack。
   - **未跑的理由(★ 订正 brief 的一处口径)**:Task 6 brief 写的是"**占 7777**",而 `team_match_probe.sh` 的头注与变量写着**它自己不占 7777**
     (`PROBE_LOBBY_PORT=29200` / `PROBE_WORKER_PORT=29250`,并**绝不**扫 `[7800,8300)`;真正会 `kill_port 7777` 的是 `royale_soak_probe.sh`,
     而那条**不**注入 attack)。⇒ 正确的未跑理由是两条:① **六人真链路按 §一 归用户跑**(agent 不擅自认领);
     ② 更关键 —— **即使跑,它今天的判决也不可信**:§一 第一条就是它(根因 `9003dae` 已修,但**修复后没有留下六人整跑的判决**)。
   - **未实测(= 推断,不是实测)**:"真链路下机器人的 `attack=true` 经 `PlayerInput` → `Player.is_attack_*` → `WeaponBase` 真的让武器开火"
     这句今天只有**组件级**证据(上面第 5 条),**没有端到端证据**;连 `Player.is_attack_*` 委托 `input_source` 这一跳也没有真链路断言
     (既有真链路跑批测的是移动 / 同步 / 回滚,不是开火)。
   - **玩家可见面**:"联机里机器人不开火 / 只有本机玩家能开火"这类**断链**不会让任何既有守卫变红。
   - **什么时候能销**:按该探针自己的口径跑一次(池外 29200/29250、**不动 7777**、收尾只扫它自己那段、前后 `tasklist` 无 Godot),
     加一条"机器人宿主在真对局里确实出了弹"的断言 —— 顺带把 §一 第一条那笔"修复后无整跑判决"一起结掉。

7. **「回溯退出必须读未被冻结的输入」这条不变量没有落纸**(2026-10-04 由 Plan B Task 6 复核发现；owner 未认领)。
   - **陷阱**：`scenes/pvp_match_client.gd:231` 读全局 `Input.is_action_pressed("rewind")`；**看着像** §2.6 的同类，
     但同一函数 `:236` 会把**同一个** `src`（`_local.input_source`）置 `frozen = true` ⇒ 若照 §2.6 改成
     `src.is_action_pressed("rewind")`，`want` 会**恒 false** ⇒ 每帧冻/解冻抖动、**回溯永远出不来**。
   - **现状**：权威侧干净（客户端 `pack_record(_local.input_source)` → 服务器读包里那位 `src.haste_held()`，
     见 `server/match/match_host.gd:214-215`）⇒ **不改行为**。
   - **该做的**：把这条不变量写进代码注释，或补一条守卫钉"回溯退出读的口**不是**被冻的那个 src"。
8. **工作区 EOL 漂移：`.gd` 也有**(2026-10-04 实测；benign)。
   - `player_contract_smoke.gd` 的工作区是 CRLF，仓内另有若干 `.gd` 同样（**入库 blob 都是 LF**；`git status` 看不见）。
   - **为什么无害**：`* text=auto eol=lf` 在 `add` 时归一 ⇒ 入库形态正确；Godot 两种都读。
   - **为什么登记**：`check_naming.py` 的**规则 E 只覆盖 `.ps1`/`.bat`** ⇒ 这类漂移**没有守卫**；谁拿工作区形态当判据会得到怪结论。
9. **`water_probe` 绿灯时 stderr 仍有一行 ERROR**(2026-10-04；**有意为之**)。
   那一相**故意**触发 `push_error`（为验证"缺 src 点名报错"这支能红）⇒ 判据只能是文本 `WATER OK`；
   若哪条 CI/脚本扫 stderr 的 `ERROR` 会**假阳**。
10. **`SwimComponent` 缺 `src` 时把 `in_water` 归 false 是新增语义**(2026-10-04 Plan B Task 6 引入)。
   理由是保住不变式「返回 true ⇔ 在水中」（否则读 `swim.in_water` 的副本/渲染会看到与根逻辑矛盾的残值）；
   **但没有守卫钉住这条不变式本身** ⇒ 若将来有人改掉这行，读 `in_water` 的那两处会静默看到残值。

11. **§2.6 的守卫有一处覆盖上限：那道行为相只驱动了 `up` 边沿/轴**(2026-10-04 由 Plan B Task 7 引入并登记)。
   它用 `Input.action_press("up")` 驱动攀爬 ⇒ **只读别的轴 / 别的动作**的"新式兜底"它咬不住。
   ★ 同族还有一条**测试基础设施**缺陷（已立 Plan B Task 9）：`tests/probe/climb_probe.gd` 依赖**随机地图**
   （`core/sim/maze_generator.gd:44` `maps[randi() % maps.size()]`）⇒ **同版本两次跑结论可能相反**、**不能当基线**；
   修法 = 用 `set_map_file` 钉图。★ **已修（2026-10-04，`c5804f4`）**：`climb_probe` 现已钉 `demo.cyrm`；钉图前连跑 6 次得 **3:3 两种互斥结论**，钉图后 md5 全等且与 demo 那一支逐字节相同。

12. **同族反射的两处"要动类结构"残留（候选批次，未立项）**(2026-10-04 由 Plan B Task 3 定位报告；owner 未认领)。
   - **残留**：`scenes/player/swim_component.gd:39` 的 `parent.get("pvp_haste_mult")`、`core/sim/world_rewind.gd:95` 的 `player.get("weapons")`
     —— 两者读的都是 **player 根**（`CharacterBody2D`）上的成员，而 **player 根没有 `class_name`** ⇒ 想类型化就得给根加全局类名。
   - **加 `class_name Player` 的爆炸半径（实测）**：会当场打掉两个**刻意造成的裸宿主桩**
     （`tests/probe/water_probe.gd` 的 `class SwimHost extends CharacterBody2D`、`tests/smoke/player_contract_smoke.gd` 的 `class ClimbHost`
     —— 它们的注释写着该字段"为反射而给"），并外溢到 `scenes/player/climb_component.gd:133` / `scenes/weapons/weapon_base.gd:367`（读同一字段）；
     且 `player.gd` 是全仓最大的文件，上全局类名还要考虑**全局类缓存 / 命名冲突 / 导出侧**。
   - **★ 首选修法是"参数注入"而不是"给根加类型"**：让 `update(...)` / `rewind_*` 多收一个参数（`haste_mult: float` / `weapons` 组件），
     调用方自己把它传进来 —— 这与 §2.6 的精神一致（**别伸手读宿主，让它注进来**），且**不需要动那两个测试桩**（参数类型仍是 `CharacterBody2D`）。
   - **翻案条件**：立一个专批把这两处（连同 `climb_component.gd:133` / `weapon_base.gd:367`）改成参数注入 ⇒ 销账并附提交号。

13. **「武器子字典经 `record()` → `rewind_restore()` 的端到端写回」没有守卫**(2026-10-04 由 Plan B Task 3 的逐任务评审**收窄措辞**后登记；owner 未认领)。
   - **真实措辞（★ 比 Task 3 首次报告里写的窄）**：报告原写"`record()` 把生产端输出写进 `_frames` 这一步没有断言"——**太宽**。
     实测（M-A 变异：把生产端那处按名取值改回退役名 `_current_slot`）证明 `record()` → `rewind_restore()` 这条链对**玩家字典本身是有守卫的**：
     `rewind_probe` 7 条红（位置差 276px / HP 30≠50 / HUD 血量通知未触发 + 4 条生产端字段红）。
   - **真正的洞**：Task 3 新加的两条守卫（`rewind_weapon_probe` 的 S7、`rewind_probe` 的 ⑨）**都直调**
     `WorldRewind._snapshot_player()`，**没有任何一条经 `record()` 落帧、再经 `rewind_restore()` 写回**去断言**武器子字典**
     （`widx` / `wmags` / `wlive`）——"空手 vs 装备武器、落哪一帧、`_frames` 裁剪"这些中间环节今天只有源码可见
     （`core/sim/world_rewind.gd` 的 `record()` 里那一行 `"player": _snapshot_player(player)`）。
     ★ 它与 `tests/probe/rewind_weapon_probe.gd` 文件头登记的那条边界（S1-S6 只覆盖消费端、S7 只直调生产函数）**不是同一件事**。
   - **它测不到什么（照实）**：也不覆盖真机"回溯到哪一帧"的帧选择（落点不可复现，`rewind_probe` 那半边只能作区间断言）。
   - **翻案条件**：补一条**武器子字典经 `record()` → `rewind_restore()` 的端到端断言** ⇒ 销账并附提交号。
     ★ 可行的形状（给动手的人一个确定性做法）：**录制窗口内把武器状态钉成常量**（例如两把枪、各格 5/7、手持 9），
     让引擎自己录几帧；**回溯前**再把它改成另一个值（例如全 0），然后按住 Shift 走真链路回溯 ⇒
     无论落到哪一帧，"逐字段 == 录制期常量"都是**确定**的断言（帧选择不确定被常量化掉了）。

14. **`WorldRewind` 的 `push_error` 在"完全取不到 `weapons`"时也会报**(2026-10-04 由 Task 3 R1 引入并登记)。
   - 旧写法 `if wc == null: return d` 是**静默**返回；R1 按控制器裁定改成"`as WeaponComponent` + 点名报错 + 返回已收集部分"后，
     "**取不到**"与"**类型不对**"两条路都会 `push_error`。
   - **今天无差别**：真机 `player.tscn` 必有 `$Weapons`，6 支 rewind 探针里"不是 `WeaponComponent`"出现 **0** 次。
   - **将来要分档的条件**：若出现"**没有 `$Weapons` 的占位玩家**"（那是**正常态**而非错误）⇒ 必须把两条路分开：
     缺组件 ⇒ 静默/降级；类型错 ⇒ 报错。届时改这一处 + 补一条守卫钉住分档。

15. **玩家根那 5 处反射只有"计数上界"守卫、不逐名**(2026-10-04 由 Task 3 R1 的补审点名；原先只在报告里，控制器落纸)。
    ★★ **2026-10-04 已修（Plan B Task 15，提交 `70c0f9c`）** —— 下面第一条是**历史形态**（保留：它记着"控制器为守卫的
    充分性编理由"那次病），第二条是**实测证伪**，第三条起是**已落的修法与仍存的边界**。
   - 旧形状守卫是 `.get("` + `has_method("` **≤ 5** ⇒ 若有人把 `is_downed` 改名成 `is_downed_x`，**计数仍是 5 ⇒ 绿**，
     而行为会**静默退化**（`"downed"` 恒 false ⇒ `player.gd:995-998` 的倒地/复活还原被跳过）。
     ★ **行号订正**：原文写 `player.gd:987-989`，**已过期**；按内容复核（`grep -n "set_downed_by_rewind\|combat.revive()"
     scenes/player/player.gd`）实测是 **`995-998`**（该文件共 998 行，那四行就在末尾）。
   - ★★ **2026-10-04 实测（Task 13 的 G-1 证伪了控制器原话）**：上面那句"**行为**断言能咬住"**实测不成立** ——
     只把 `_snapshot_player` 里的字符串改成 `has_method("is_downed_x")`（**真方法不动**）⇒ 探针 **ALL-OK 60/60**：
     `_s7_producer` 只断言 `wslot/widx/wmags/wlive`，**从不看 `snap["downed"]`**；而 `rewind_probe.gd` 里 `downed` 出现 **0** 次。
     ⇒ **当时**这条形状守卫**只有"≤ 5 计数上界"一条保证**（Task 15 在本机把这一跑复现了一遍：旧探针 + 同一变异 = **60/60 零红**）。
     ★ 控制器当时为守卫的充分性**编了个理由**，正是本会话一直在追的那类病。
   - **Task 15 的修法（已落）**：(a) 度量换成 `_has_member_token` **逐名核** —— 5 个**访问形态**各一条谓词，与原来的 `≤ 5`
     合取进**同一条** `_check` ⇒ **条数不变**；(b) 补一条 `snap["downed"] == 真值` 的**行为**断言（两相：活着 → false、
     倒地 → true），`EXPECTED_CHECKS` 60→**61**。逐条变异实测：5 条后缀拼接各自红在 (a) 那一条（消息里点名缺哪个），
     其中 ⑤ 就是 G-1（旧守卫下 60 条全绿 ⇒ 现在 **(a) 与 (b) 各红一条**）。
     ★★ 为什么每条都要带**访问形态**（`get("hp")` 而不是裸 `hp`）：裸名会被**同一个函数里的别的出现**骗过 ——
     `"hp"` 同时是字典键、`is_downed` 同时是 `player.is_downed()` 那个真方法调用 ⇒ 裸名判据对"字符串被改名"**恰好无牙**。
   - **仍存的覆盖上限（照实）**：(a) 只挡"成员名被改名/后缀拼接"；**换个完全不同的名字**（`is_downed` → `is_alive`）仍只有
     (b) 那条**行为**断言兜着（它现在真的会红）。**补了 `downed` 这一维 ≠ `snap` 全维都守住了**：`snap` 的 9 个键里
     `wslot/widx/wmags/wlive` 有"生产端 == 真值"断言（`rewind_weapon_probe` S7 + `rewind_probe` ⑨），`downed` 由 Task 15 补上，
     而 **`p`/`hp` 只有端到端间接覆盖、`v`/`facing` 两键今天没有任何断言**（清点见 Task 15 报告）。
   - ★ **第三处过期行号：已订正**（2026-10-04，控制器 R2 放行后定点改，提交 `dc06574`，纯注释）。原状：`core/sim/world_rewind.gd:150`
     也写着 `player.gd:987-989`（同款过期）；同段 `:151-152` 把本守卫描述成"度量写成 `.get("` + `has_method("` **≤ 5**"。
     现状：行号已成 `995-998`，描述已改口为"**逐名核那 5 处访问形态 + 一条 `snap["downed"] == 真值` 的行为断言
     （`EXPECTED_CHECKS` 61）**"，并保留"旧计数上界对第 ⑤ 处改名无牙"的 G-1 实测根据。
     ★ 教训留档：Task 15 的硬约束**只允许碰** `tests/probe/rewind_weapon_probe.gd` 与本文件 ⇒ 当时那两处**没改**、
     只在报告里点名；**是控制器放行才补上的** —— "改了 A 就过期的 B" 若落在**改动集之外**，必须显式交回控制器，别默默留着。
   - **手工复核点（将来改这一带时）**：`rewind_weapon_probe.gd` 的 `PRODUCER_NAMED_PLAYER_ACCESS` 与 `_snapshot_player`
     里那 5 处必须**同时**改（后者改名 ⇒ 前者红，这是**设计**不是误报）。

16. **`scenes/player/combat_component.gd:108` 的 `animator.play("downed")` 是死引用（每次运行都报错）**(2026-10-04 由 Task 15 发现并登记；owner 未认领)。
   - **实测**：任何运行里都报 `ERROR: There is no animation with name 'downed'` —— `player.tscn` 的 `SpriteFrames` 只有
     `charge` / `fly` / `idle` / `move` / `squat`（控制器在 Task 15 那轮的探针输出里也看到同一行）。
   - **两个后果**：① **"回溯到倒地帧"的动画表现从未生效**；② 该错误让 `set_downed_by_rewind` 在 `downed = v` **之后中止**
     （状态已置，其后的 `went_down.emit()` 等未执行）⇒ 状态类断言不受影响，所以这个洞**被 guard 视线之外**。
   - **怎么修**（二选一，属**独立小批次**，与 §2 无关）：给 `SpriteFrames` 补一个 `downed` 动画（表现向，需要帧），
     或删掉这行 `play` 调用并确认后续逻辑不依赖它。★ 无论选哪个，顺手补一条"动画名存在于 SpriteFrames"的形状断言。

17. **本仓没有 CI,也没有"聚合回归入口"以外的机器判据**(2026-10-04 加;owner 未认领;最后复核 2026-10-04 `bash tests/run_all.sh` 实测)。
   - **症状(加这一条之前)**:判据靠**逐脚本自造文本行** + 靠人记得该跑哪些 ⇒ ① 没有任何东西保证"新加的探针会进批";② 没有一份便宜的"改了没有"的红/绿判据;**③ 真链路的三条纪律(7777 / 孤儿 worker / 池外不扫)全靠人记**。
   - **现状(2026-10-04 起)**:[`tests/run_all.sh`](../../tests/run_all.sh)(headless 默认批,自动枚举 + 逐支判词 + **已知红基线** [`tests/known_red.txt`](../../tests/known_red.txt))与 [`tests/run_real.sh`](../../tests/run_real.sh)(真链路批,四道闸)已入库。★ **它已经是能被 CI 直接调用的形状**:`run_all.sh` 的退出码 = "有没有新红",判词行可以 grep。
   - **为什么留着不补(为什么还没上 CI)**:上 CI 是**项目级决策**,至少要同时回答四件事 ——
     ① **Windows**:`.bat` 与 `core/net/proc_util.gd` 都有 Windows-only 分支(`taskkill` / `netstat -ano` / `ping -n`),Linux runner 跑不了;
     ② **两个 Godot 绝对路径**:`GODOT`(console 版,跑测试)与 `GODOT_EDITOR`(标准版,导出)是两个二进制且都要现装;
     ③ **真链路批要占 7777**:CI 里没有"用户正在跑的对局"这个概念,gates 的语义要重新定;
     ④ **发布产物那一侧的守卫今天也没有**(见 §五.10 与 §七.3 指的同一处通道问题)。
   - **什么时候能销 / 翻案条件**:决定上 CI 时 ⇒ 先落最小一步:`run_all.sh`(headless,不碰 7777)+ `python tools/check_naming.py --self-test` 两条,配一个 Windows runner;`run_real.sh` **不进** CI(它按设计要人认领)。★ **不要**在没有用户裁决的情况下新建 `.github/`(本批明确不建)。

18. **`debug/gdscript/warnings/unsafe_*=2` 试跑:红的形态、解析不过的脚本、"改得掉/改不掉"粗分类**(2026-10-04 加;owner 用户 —— **开不开是产品决策**;本行只交数据;最后复核 2026-10-04 实测)。
   - **动机**:`AGENTS.md` 记着"未知成员在 `class_name` 类型上只是 **warning**(`UNSAFE_*`)"。把它升成**错误**,反射一复发就是硬红 —— 这是"反射清完还剩多少"的**唯一量化判据**。
   - **键组合(试跑用的那一组)**:`[debug]` 段加 `gdscript/warnings/unsafe_property_access=2` / `unsafe_method_access=2` / `unsafe_cast=2` / `unsafe_call_argument=2`;跑 `bash tests/run_all.sh`。★ 时间盒下在**第 54 支**(共 101)处停 ⇒ 下面是**下界**。
   - **红的形态(54 支)**:**48 支 `NO-VERDICT`**(主体形态:依赖脚本解析不过 ⇒ 一行判词都不打,白等满 `--quit-after` ≈60s)· **3 支存活** `OK`(`lobby_parse_smoke` / `network_input_smoke` / `time_rules_smoke`)· **2 支 `FAIL`**(`settings_actions_smoke`:依赖 `settings.gd` 解析不过;`hud_declarative_probe`:`KH HUD PROBE: FAIL | res://ui/hud/royale_hud.gd; res://ui/hud/combat_fee…` —— **它自己点名了哪些脚本解析不过**)· **1 支 `TIMEOUT`**(`tile_query_smoke` 被 60s 外壳掐掉 ⇒ 解析错误能把一支 1 秒冒烟变成"看着像挂住")。
   - **解析不过的脚本(从 55 份跑批日志归并)**:`4377` 行 `Parse Error: … (Warning treated as error.)`,落在 **75 个源文件**、**1531 个不同 (文件, 行)**。按引擎措辞分类:`unsafe_call_argument` **2777** · `unsafe_method_access`("The method … is not present on the inferred type …") **898** · `unsafe_property_access`("The property … is not present on the inferred type …") **419** · `unsafe_cast` **283**。位置最多的文件:`tests/smoke/enemy_logic_smoke.gd`(210 行)· `tests/probe/ground_action_probe.gd`(95)· `tests/smoke/weapon_inventory_smoke.gd`(73)· `scenes/pvp_match_client.gd`(67)· `tests/smoke/grenade_smoke.gd`(65)· `core/sim/map_format.gd` / `core/config/settings.gd` / `scenes/player/player.gd` 等。
   - ★★ **一条必须先知道的操作事实**:该模式下**普查工具自己也解析不过** —— `Parse Error: Casting "Variant" to "GDScript" is unsafe. (Warning treated as error.) at: GDScript::reload (res://tests/probe/allscript_probe.gd:71)` ⇒ `allscript_probe` 打不出一行判词。所以上面这份普查是**从跑批日志归并**出来的,更完整的清单得**先修它自己那一处**(改成 `if s is GDScript:` 收窄)再跑。
   - **粗分类**:**全仓零第三方代码**(`find . -maxdepth 2 -name addons` = 0 命中)⇒ **没有"引擎/第三方形状改不掉"这一类**。四档:(a) **类型化/收窄改得掉**(`Variant` 来路静态可知:`map_format.gd` 的 `int()/bool()/String()`、`grid_pathfinder.gd` 的实参);(b) **反射那一家**(`player.gd` 等,与 §六.12 的"参数注入"同批);(c) **工具自己**(`allscript_probe.gd:71`,5 行级);(d) **只能逐点压警告**(`Variant` 来路静态不可知:`ConfigFile.get_value()`、`load()` 返回的 `Resource`、`InputEvent` 一族 ⇒ 引擎的出路是 `@warning_ignore(...)`,**那是把警告关掉、不是改对**)。★ 本行**不写**"建议开启/不开启"。
   - ★ **还原证据(R8)**:试跑后 `cp` 回原文件,`git diff project.godot` **为空**、`git status --short project.godot` **为空**、`grep -n "unsafe_" project.godot` **零命中**;那 4 行**没有**进任何提交;收尾时无残留 Godot 进程、`lobby_alive=false`、`[7800,8300)` 无占用。
   - **翻案条件**:用户裁定"反射必须清零"时 ⇒ 先按上面四档分档(先做 (a)(b)(c)),再开 `=2`;★ 届时**必须**同时跑一次真链路批(退时 segfault 那类问题只在真链路里现形)。

## 七、已裁定不做(won't fix,2026-10-04 加)

**本节不是欠账清单**:§一/§二 是"要还的债",这里是**已经判过、决定不还的** —— 每条都带**判决理由**与**翻案条件**。
★ **写在这里的唯一目的:下一代 agent 读到就不必按审计重查一遍。** 没有翻案条件的"不做"等于没判,所以三段缺一不可。
★ 判决来源:用户 2026-10-04 对审计 §1/§2/§3/§4 的逐类裁定(见 [`audit-2026-10-04-design-conventions.md`](audit-2026-10-04-design-conventions.md) §10 那张表)。
本节三条都不是"没发现",而是"发现了、判过不做"。

1. **菜单没有键盘/手柄焦点入口**(`audit §2.7`;owner 用户;最后复核 2026-10-04;判决:**记录而不修改**)。
   - **症状**:`grep -rn "grab_focus\|focus_neighbor" core/ scenes/ server/ ui/` = **0 命中**(2026-10-04 复核);
     全仓唯一被处理的"焦点"是返回 —— [`scenes/settings_menu.gd`](../../scenes/settings_menu.gd):142
     `if event.is_action_pressed("ui_cancel")`。而 Godot **不会**自动点亮首个可聚焦控件 ⇒
     冷启动后 Tab / 方向键 / 手柄**一个按钮都到不了**。
     ★ 这不是"机制没人用过":[`scenes/mp_lobby.gd`](../../scenes/mp_lobby.gd):506/509 为"进不去的房"
     按 `disabled` 切 `focus_mode`(NONE / ALL)—— 机制在、只是**没喂初值**,也没把屏与屏之间的邻居接起来。
   - **为什么判"不做"**:用户 2026-10-04 对审计 §2 的裁定是「**记录而不修改**」,且在审计 §7 的候选表里**不列为候选**
     (audit §10)。实质理由:现网入口只有鼠标,本仓是单机 + PvP demo,**没有**主机/手柄发行计划;
     而"手柄能走完全部菜单屏"的改动面是**每一屏**(首焦点 + 邻居网格 + 焦点可见样式),收益对不上面。
   - **什么条件下翻案**:真做手柄/键盘导航(或主机发行)时。**前置三件,缺一件就只是"能按 Tab 但看不出焦点跑哪去了"**:
     ① 每屏给首个可聚焦控件喂初值(`grab_focus()`,一般落在该屏主行动);
     ② 用 `focus_neighbor_*` 把网格**显式**接起来(本仓大量绝对定位 + 容器混排,靠引擎自动推导不可靠);
     ③ 给 `focus` 态补**可见**样式(Theme / StyleBox),否则焦点在哪看不见。
     ★ 届时以 `settings_menu.gd` 的 `ui_cancel` 为入口往回推,但**先 `grep` 复核行号**(审计是快照,行号会漂)。

2. **零 i18n / 没有文案表**(`audit §2.8`;owner 用户;最后复核 2026-10-04;判决:**记录而不修改**)。
   - **症状**:`grep -rn 'tr("' core/ scenes/ server/ ui/` = **0 命中**(★ 别用 `grep "tr("` —— 它会**假命中** `str(`);
     无 `.po` / `.csv` / `.translation`,`project.godot` 无 `internationalization` 段 ⇒ 文案全是**中文字面量**。
     量级:审计 §2.8 记"`ui/` + `scenes/` 约 **328** 处中文串面",★ 但**那个数来自子代理、审计自己标了未复核**
     (audit §5 第 5 条)⇒ 谁要引用**先自己数一遍**。
     ★ 同条点出的**结构性障碍**才是判"不做"的真正原因:多条探针**按文案找控件**
     ([`scenes/main_menu.gd`](../../scenes/main_menu.gd):204 自述 `kh_l4_visual_probe` 按文案找按钮;
     [`tests/smoke/menu_autotest.gd`](../../tests/smoke/menu_autotest.gd) 的 `_press_by_text` 同理)⇒ **改文案 = 改测试**。
   - **为什么判"不做"**:同样是用户 2026-10-04 的「记录而不修改」(audit §10)。它不是"加一份翻译文件"的工作量:
     ① 文案今天有**多个落点**(代码字面量 + `.tscn` 里的 `text=`,而"搬进 `.tscn`"这件事本身又添了这一处);
     ② 得先把"按文案找控件"的探针判据换成 `unique_name_in_owner` / `meta`,否则每换一版译文都要跟着改探针;
     ③ 项目**无**多语言发行需求。
   - **什么条件下翻案**:真要出中文以外的语言(或要让用户切语言)时。**顺序不能反**:
     先做 ② 的判据改造(探针不再认文案),再抽文案表(`.csv` + `TranslationServer`,或一层统一的取词),最后才谈译文。
     反过来先抽表 ⇒ "改文案 = 改测试"这条税**翻倍**(两套文案表 + 仍按文案找控件的探针)。

3. **发布版里"菜单自动探针"退化为 no-op ⇒ 发布版没有菜单端到端守卫**(owner 用户;最后复核 2026-10-04;判决:**裁剪后不随包发布**)。
   - **症状**:[`scenes/main_menu.gd`](../../scenes/main_menu.gd) 的 `_ready` 在命令行含 `-- --autotest-*` 时
     把 [`tests/smoke/menu_autotest.gd`](../../tests/smoke/menu_autotest.gd) 挂到树根,但那条依赖被 `:164` 的
     `ResourceLoader.exists("res://tests/smoke/menu_autotest.gd")` 守着 ⇒ 文件不在包里时它**静默跳过**
     (不报错、不打日志、不影响退出码)—— **不是坏,是"没有"**。
     ★ 裁剪**之前**它是能用的(2026-10-04 实况):`export_presets.cfg:11-13` 是 `export_filter="all_resources"` +
     `exclude_filter="*.md,.superpowers/*"`,审计 §1.3 对仓库根那两个产物直接 grep 得 **336** 条 `res://tests/*` 路径
     ⇒ 发布版里探针文件**在**。发布包裁剪(`exclude_filter` 加 `tests/*,tools/*`;audit §1.3 / §7 第 3 条)**已于
     2026-10-04 落地**(`10da6cc`)⇒ 它**已不在**包里。
     ★ **代价不只"少一条守卫"**:`menu_autotest.gd:43-47` 自述这条通道**曾是发布产物上跑场景探针的唯一一条**
     (导出 exe 编译了 `disable_path_overrides=yes`,`<exe> res://x.tscn` 会被引擎当场拒绝)
     ⇒ 裁剪同时收掉"在成品上跑 `tests/probe/*.tscn`"这个能力。
     ★ **配套订正已完成(2026-10-04:`10da6cc` 改口 + `d2b7e53` 补「**发布版里**」限定语)**:`main_menu.gd:154-156` 那句「tests/ 会一起打进发布包」
     **曾经是实况**,已改口为两段现况 —— 曾经会一起进包(⇒ 真守卫理由只是"文件可能不存在")+
     2026-10-04 起 `exclude_filter` 已含 `tests/*` ⇒ **发布版里**这条通道没了。
   - **为什么判"不做"**:用户 2026-10-04 裁定"发布版不再有菜单自动探针"(与发布包裁剪同批;audit §7 第 3 条那句
     "同时决定 `tests/smoke/menu_autotest.gd` 这个'生产依赖测试文件'该怎么办"就是这件事的入口)。代价侧很实在:
     ① 探针**不是单文件** —— 它的 `sceneprobe/<名>` 分支还要 `tests/probe/<名>.tscn`(`:48-49`),
     只放一个文件等于**同一种静默 no-op**(闭包会随探针增长再次缺文件);
     ② `-- --autotest-*` 会成为**成品里可用的隐藏开关**:它真点按钮、真切场景、真往 `user://` 写截图(`:495-513`)
     ⇒ 等于给成品留一条测试后门;
     ③ 它**本来也不是自动守卫**:没有任何脚本(零个 `.sh`、零个 `.py`)跑它,覆盖靠人手动拿开关跑一次再 grep。
   - **什么条件下翻案**:需要一个"**发布产物上真的跑过**"的端到端证据时(例如每次发布都必须验一遍菜单流转)。
     **翻案条件 = 把那条探针作为运行期资源随包发布**,并接受上面 ①②③:最小做法是让 `exclude_filter` 留一个白名单
     (只放 `tests/smoke/menu_autotest.gd` + 它 `sceneprobe/` 分支要用的 `tests/probe/*.tscn`),
     并给白名单配一条**能红**的守卫 —— 否则又是"闭包少了文件 ⇒ 静默 no-op"的老形状。
     ★ 更便宜的替代(只要"菜单能起来"这一档):在 [`tools/build_release.py`](../../tools/build_release.py) 的产物冒烟里加一步
     `-- --autotest-mp` + grep 一条文本(它已有同款做法:`check_weapon_registry` 拿 `-- --registry-report` 那行文本对账)。
     但那**不是**端到端守卫,只证明"主菜单 → 大厅"这一步没崩。
