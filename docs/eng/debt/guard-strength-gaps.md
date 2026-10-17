# 五、守卫强度已知缺口(2026-10-04 加)

> **本文件从 [`registered-debt.md`](../registered-debt.md) 拆出**（2026-10-13，原文件 888 行 / 126KB 越过了 `CLAUDE.md:5` 那条 64KB 上下文线）。返回索引：[`registered-debt.md`](../registered-debt.md)。
> ★ 文档会过期 —— **任何冲突以源码为准**，读之前先 `grep` 复核；`文件:行号` 与本仓自述一致地会漂。

## 五、守卫强度已知缺口(2026-10-04 加)

**这些不是"红",是有守卫但保证比读起来少** —— 与 [tests.md](../tests.md) 末节同一类,发现者都是审阅者不是实现者。

1. **`tests/probe/tile_collision_probe.gd` 用"跑完闩"(`_ran_to_end`)而不是计数闸。** 它只覆盖
   **`_run()` 自身**出错(那时闩为假 ⇒ `_finish()` 打 FAIL);但按 [`tests/lib/probe_base.gd`](../../../tests/lib/probe_base.gd)
   文件头的权威表述,**helper 内部**出错只结束那个 helper、`_run()` 继续跑到底 ⇒ 闩为真 ⇒ 断言被静默跳过而
   verdict 照打 `ALL-OK`。**权威形式是 `_checks >= EXPECTED_CHECKS`**(本仓对新场景探针的要求)。
   补法:给该文件加 `_checks` 计数 + `EXPECTED_CHECKS` 下限(要逐个断言点计数,这是本条一直没做的原因)。
2. **客户端 `Level0` 也注册了格级 `on_destroyed`**(`scenes/level_0.gd:246`,在 `pvp_mode` 早退**之前**),
   它的"惰性"依赖"客户端不调 `damage_tile`"这个事实,而**这条事实没有守卫**:`tests/smoke/laser_weapon_smoke.gd`（已删·2026-10-09）`:64-67`
   只要求文件里**提到** `Level0.pvp_mode`(没绑到 `_damage_tiles` 那条闸);子弹那半有
   `tests/smoke/bullet_tile_fx_smoke.gd`（已删·2026-10-09）`:63-68` 兜住 —— ★ **这两支都已随 2026-10-09 的测试面削减删除 ⇒ 这一面今天零守卫**。★ 风险:那条闸哪天一回归,客户端会**本地**清掉 16 个 `sub_hp`
   ⇒ 与服务器分歧;本轮新增的接线把这条的爆炸半径放大了。
   ★ **结构性解法(终审 R1,已核安全)**:把 `scenes/level_0.gd:246` 那行注册**移到 `pvp_mode` 早退之后** ——
   `pvp_game.gd:38` / `team_game.gd:40` / `royale_game.gd:33` 都在**实例化 Level0 之前**就设好
   `Level0.pvp_mode = true` ⇒ PvP 客户端**根本不会注册**它,把"没有守卫的纪律"变成"**不可能发生**"。
   现有 `tile_collision_probe` 相③b 正好是它的守卫:单机路径若不再注册,相③b 立刻红。
   同样留到下一批(终审之后不再新增未过审的生产改动)。
3. **`tests/probe/perf_probe.gd:179/205-211`（**该探针已删·2026-10-09**） 是"服务器清格子格"算法的第二份口径**(仍是 v3 的 `*2` / `x/2`)。
   ★ 准确说法是"**口径已分家的合成消融**",**别**登记成"重复真相源待合并" —— 它清 4/16 个子格、`:179` 选块也用的旧换算,
   所以它的 timing 与覆盖率跟生产实现不是一回事。

4. **`destroyed_cells_probe.gd`（已删·2026-10-09） 的反向断言"钉实象限"依赖格坐标奇偶**(终审 M2)。
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

9. ~~**`tests/smoke/pvp_match_smoke.sh` 的固定启动预算太紧,且失败信息指向错误的嫌疑对象**~~ **★ 2026-10-08 已修**(closeout 批;两处都修了)。
   **修法**:① `sleep 3`/`sleep 2` → **有界轮询**(服务器等 `SERVER_WAIT`=20s 出现"服务器就绪";建房等 `ROOM_WAIT`=30s
   出现房间号;进程**提前退出**就立刻收摊并打印它自己的日志 —— 原来这种情况只能等到 grep 失败,拿到的是那句**指向错嫌疑人**的判词);
   ② **早退路径补齐回收** —— 新增 `kill_my_clients`(按**命令行**精确杀本支的 Godot 客户端:它们用临时出站端口、不占 7777、
   也不在 worker 池里,而 `kill_procs "$!"` 在 Git Bash 下不可靠 ⇒ 原早退路径**够不着它们**)+ `kill_port_range 7800 8300`(worker 孙进程);
   ③ 判词改成「`Ns` 内**没看到房间号**(= 建房客户端没走到 `create_room`,**不是**服务器没起)」。
   **证据**:命令行模式隔离测试(`godot=2 → 0`);强制早退(`ROOM_WAIT=0`)残留 **0**;正常两遍 **`SMOKE PASS`**;
   ★ **入口层**:`bash tests/run_real.sh --yes` 由修前的「**3/3** 卡在第 1 支、`gate-failures=1`」变成
   **`RUN_REAL FAIL(entries: ok=4 fail=1 ; gate-failures=0)`** —— **5 支全部跑到了**,唯一的红是 `team_match_probe`(见 §一第 1 行,与本行无关)。
   ⇒ **本行可以销掉**;留着是因为下面那段"症状与真因分家"的教训对**同族脚本**仍然有效。

   **修前的记录(留作证)**:它起服务器后 `sleep 3`、起建房客户端后 `sleep 2`,然后 `grep` 服务器日志找房间号;找不到就打
   **「服务器未建房间」**并走 `exit 1`。★ 但真因可能是**客户端还没加载完** —— 本机实测:同一棵树、
   同配置连跑两次都红(空闲机第三次同样红),把副本里的 `sleep 3`/`sleep 2` 改成 `12`/`12` 后
   **一次就绿**(`SMOKE_MATCH OK create/join`)。⇒ 症状与真因**分家**,且**与代码无关**才是真正危险的地方
   (排查人第一反应会去怀疑服务器/网络)。★ 同族脚本里凡"固定 sleep 后 grep 就断言"的都要按这条重看。
   ★★ **2026-10-08 复现(控制器,closeout 批的"真链路批 B")**:结论**升级** —— 在这台机器上它**不是偶发**:
   经 `bash tests/run_real.sh --yes` **连跑三次、三次都在第 1 支就中止**(判词 `SMOKE FAIL: 服务器未建房间`,约 7s),
   而 `/tmp/pvp2_server.log` 里服务端**正常就绪**(`服务器就绪,等待玩家……(大厅 7777;配对后自动拉起对局 worker)`)
   ⇒ 再次确认**症状与真因分家**、且**与代码无关**。
   ★★ **它还有第二个后果(比第 1 条更值得记)**:该支失败后走早退路径 ⇒ 留下一批孙进程 ⇒ 入口的
   "跑后 Godot 必须为 0" 那条闸**判 FAIL 并中止整批** ⇒ **整批 `run_real` 今天连第 2 支都到不了**
   (`RUN_REAL FAIL(entries: ok=0 fail=1 ; gate-failures=1)`)。⇒ 本轮的真链路覆盖是**逐支手工跑**拿到的
   (每支之间守 `lobby_alive` + 清端口 + 前后进程为 0),**不是**从入口拿到的;这个区别要写进任何引用它的结论里。
   ★ 反证:同一支**单独**跑可以过(2026-10-08 实测 `SMOKE PASS`,约 20-40s),但也会先红一次
   (`超时 role=join snapshot=true round=true moved=true bullet_spawn=false`)⇒ **两副面孔都属于这一支的抖动**。
   ★★ **同一支的早退路径还漏杀孙进程**:`:28` 只 `kill_procs $SERVER_PID $A_PID; kill_port`,
   **没调** `kill_port_range 7800 8300` ⇒ 大 spawning 的 **worker(孙进程)**留着(实测漏 4 个 / 2 个),
   正是该脚本头注自己警告的"毒害下一支"。修法:早退路径也调 `kill_port_range`;根治则把固定 sleep
   改成**轮询等待**(有上限),这样既快又不脆。

10. **`project_settings_smoke.gd`（已删·2026-10-09） 只判「设置值与文件原文」,够不到「日志真的落盘」与「release 模板那半边」**(2026-10-04 加,与它同批落地)。
    - **它给的最强保证**:`project.godot` 里那三行**逐字存在**(④ —— 唯一拦得住 `d6d2440` 那种"键名被乱码吞掉"的形状),
      且 `max_log_files` 读回来 == 64(③ —— 引擎默认 5,删行或改值当场红)。★ 它的 ①② **不算守卫**:
      三个键都是**引擎内置**设置,`has_setting` 与文件里写没写无关,`.pc` 的引擎默认值本来就是 `true`
      (空工程实测,见 `project_settings_smoke.gd`（已删·2026-10-09） 头注 `:15-31`)。
    - **它测不到什么(照实登记)**:① **"日志真的落到了 `user://logs/`"** —— 它只读 `ProjectSettings`
      与 `project.godot` 的原文,要证明"真的在写"得**真起一个进程**再看文件系统
      (`%APPDATA%/Godot/app_userdata/<项目名>/logs/`;审计 §1.2 记的默认路径是 `user://logs/godot.log`);
      ② **导出模板的 release 半边** —— 本处跑的是 **debug 模板**(`GODOT`,console 版),
      `enable_file_logging.pc` 的实际行为只在 release 导出产物上才算数,而产物那一侧今天**没有**守卫。
      ★ 别拿 worker 的 `--log-file` 当证据:那是**引擎选项**、写的是 `worker_<port>.log`
      ([`server/lobby/worker_launcher.gd`](../../../server/lobby/worker_launcher.gd):94-104),与 `[debug]/file_logging/*` 这三键是**两条路**。
    - **为什么留着不补**:①要起进程、还依赖 `user://` 的宿主路径与可写性,形状超出"`-s` 冒烟"这一层;
      ②只能在**导出之后**量(要真导出一次),属产物级冒烟的活 —— 两条都不该塞进这条 `-s` 守卫。
    - **什么时候能销**:有产物级冒烟通道时 —— 在 [`tools/build_release.py`](../../../tools/build_release.py) 的产物冒烟里加一步:
      起一次产物,再断言 `user://logs/` 里**新增**了本次会话的日志文件。
      ★ 注意它与 §七 第 3 条是**同一条通道问题**:发布产物上的守卫,得先把要跑的东西**随包发布**。

13. **`Settings.apply_display()` 的"非早退分支"(真开窗/真全屏)只有源码级证据**(2026-10-04 加)。
   - **它给的保证**:`settings_display_smoke.gd`（已删·2026-10-09） 钉住了"早退排在两个窗口调用**之前**"与
     "`_ready()` 在 `load_settings()` **之后**调它"(按**源码位置**断言),外加档表/默认值/钳位/落盘往返。
   - **它测不到什么**:绿跑**全在 headless** ⇒ `window_set_size` / `window_set_mode` 真的生效**没人验**
     (非 headless 会抢焦点)。**要闭环得跑一次非 headless 并取几何**(与窗口批 Task 0 同性质)。
   - ★ **写法税**:因冒烟按源码文本查那两个 API 字面量,`apply_display()` **函数体内**的注释**不得**出现
     `window_set_size` / `window_set_mode`。
14. **`menu_shot_probe.gd`（已删·2026-10-09） 的"取屏自证"是绊线不是保证**(2026-10-04 实测)。
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

17. **编辑器 `decodeMap` 的"闸门必须早于解压"变成零守卫**(2026-10-15,编辑器拆目录 + 测试面削减时按 D6 删掉)。
   - **症状**:把 `bodySize > MAX_BODY_SIZE` 那道闸挪到解压(`inflateBytes(payload…)`)**之后**,今天**不会红**。
     解压是"把攻击者给的字节变成内存"的那一步,判在它后面等于没判(deflate 炸弹直达内存)。
   - **为什么删**:那 4 条断言是"读源码文本比位置"(原先在 `level_editor/smoke.js`,现分片在
     `level_editor/tests/format/`),测的是"某人有没有写那段字" —— 一次纯注释改动就能把它弄红,
     命中 [`test-economy.md`](../test-economy.md) 的 D6。删时**如实登记**:行为侧只剩
     "头部声明的 `body_size` 超限必须拒"(期望子串 `64MB`),它钉**闸存在**、**钉不住位置**。
     同一批里 `worker.js` 的相位 ⑦(源码纪律)整块删除,其中"不许第二份格式实现"一条也无守卫。
   - **怎么销**:用**注入式假解压器**把顺序变成行为可观测(假 `inflateBytes` 记一笔"被调过",
     断言"超限时它一次都没被调"),或接受这半格空。
   - **owner**:编辑器侧([`level_editor/core/60_codec.js`](../../../level_editor/core/60_codec.js));
     **最后复核**:2026-10-15;**指针**:该文件那道闸上方的注释与
     [`editor-core.md`](../editor-core.md) §12 都已标"零守卫(已删·2026-10-15)"。

18. **编辑器那一整族"源码纪律"断言删除后的零守卫面**(2026-10-15,与 §17 同一批;本轮补齐登记)。
   - **背景**:旧 `editor_smoke.js` 的**相位 ⑪**(外加 `worker_io_smoke.js` 相位⑦、`smoke.js` 的格式层源码顺序)
     是一整族"**读源码文本判形态**"的断言(数调用点 / grep 某个 API / 按行比 `Math.floor`)。
     拆目录那批把它们**整块删除**(理由正确,命中 [`test-economy.md`](../test-economy.md) 的 D6),
     但当时只登记了 §17 那条 —— **其余全漏登**,而且 `docs/eng/editor-ui.md`(3 处)与
     `level_editor/ui/{20_tools,30_resize,80_ui_state}.js`(4 处)**还留着指向它的注释**。
     ★ 本轮已把这些**已不存在的守卫声明**全部订正;下面登记的是订正之后**真正空着的**那几格。
   - **已经转成行为断言、不欠债的(列出来免得下次重查)**:`PUT` 显式 `Content-Type`
     (`level_editor/tests/editor/20_hotkeys_errors.js` 记账 fetch 读请求头)、`createEmptyMap` 走 `clampMapSize`
     与 `clampTexture` 容量缺省问图集(`level_editor/tests/editor/10_core_tools.js`)、`editor.html` 的脚本清单与顺序
     (`parts_check.js` + `browser_check.js`)、`serve.bat` 的 EOL/编码(`tools/check_naming.py` 规则 E)、
     `GET /core.js` 逐字节一致(`level_editor/tests/server/10_basics.js`,只是路径改成了 `level_editor/core/00_constants.js`)、
     `.cyrm`/`.v3.bak` 的名字闸(`level_editor/tests/server/30_map_name_guard.js` 的行为矩阵)。
   - **仍然零守卫的**(去掉括号里那件事今天都不会红):
     ① `Core.lineCells` 的**每个**调用点都要先 `Math.floor`(**非整数 = `for(;;)` 死循环、挂住整个标签页**);
     ② `Core.createMap` 只该有那两个调用点(**新开一个造图入口 = A8 复发**:输 99999 分配巨图卡死);
     ③ `ui/`、`render/` 里不出现第二份 HSV 数学(**D4 重复真相源**,而 `Tint.*` 是硬依赖);
     ④ `ui/`、`render/` 不直调 `Core.subcellRender`(直调必须先 `posmod`,漏了就是越界抛错);
     ⑤ 上界不写死 `4095`(一律来自 `Render.atlasCapacity()`);
     ⑥ 写出口 `PUT` **恰好一处**、视图入口**全部**经 `guard` 收口(**漏了 = "按了没反应"**)、
        页面异常 / 未处理拒绝的监听**恰好两处**(多一处 = 同一次异常有两个写入者);
     ⑦ `Render.mount` 的 `onError` 指到**同一个** sink、`setErrorSink` 在导出表里;
     ⑧ `serve.bat` 的三件内容检查(`cd` 到脚本所在目录 / 用 node 起服务 / 结尾 `pause`)与
        `structure-editor.html` 已退休。
   - **本轮顺手补上的一条(原先属这一族)**:`#btn-selftest` / `#btn-fit` 的"id 打错 ⇒ 按钮**静默失效**"。
     它没有登记成债,而是**改成了真行为断言**:`browser_check.js` 现在**真点一下**页面上的「自检」按钮
     (不再直接调 `Editor.selfTest()`),判据取**状态栏**内容 —— 两条红路都实测过:
     id 改错 ⇒ `MISSING:btn-selftest` 红;id 在、接线摘掉 ⇒ `CLICK 超时:状态栏 15 秒一直是空的` 红。
     ★ 同一处还补了**条数闸**(`≥ EXPECTED_CHECKS = 17`,= `level_editor/ui/96_selftest.js` 里 `check(` 的条数)——
     原先 `SELFTEST OK` 只证明"没有任何失败输出",把自检削掉一半也照绿。抬到 18 实测:红。
   - **为什么删**:D6 —— 判据落在**文本**上而意图是**结构/语义**;一次纯注释改动就能把它弄红
     (本轮还真的看到三处代码**为它让步**:`level_editor/ui/20_tools.js` 那条"刻意不写成带括号的调用形式"的注释、
     `level_editor/ui/80_ui_state.js` 的"`guard(` 与调用必须同一行"、`level_editor/ui/30_resize.js` 的"这里不再写第二次 `createMap`" ——
     都是为了让按行扫描通过而写的,守卫一删它们就成了化石)。
   - **怎么销**(按性价比排):① **①号把陷阱本身消掉** —— 让 `Core.lineCells` 对非整数**当场抛**,
     死循环变成响亮报错,那条扫描就再也不需要了(代价:动了与基线逐字符等价的 `core/`,要同步
     §2 那条等价证据与 drops);② ③⑥ 这类"不许有第二处"可用**注入式替身计数**行为化(例如给
     `createMap` 包一层记账);③ ⑤⑦ 这类"取值来源"只能接受空着,或改成行为(改 `atlasCapacity()`
     返回值后看 `clampTexture` 是否跟着变);④ ⑧ 属**开发工具**的形态检查,可以接受空着。
   - **owner**:编辑器侧([`level_editor/ui/`](../../../level_editor/ui)、[`level_editor/render/`](../../../level_editor/render)、
     [`level_editor/core/85_geometry.js`](../../../level_editor/core/85_geometry.js));
     **最后复核**:2026-10-15;**指针**:本轮订正过的三处文档/注释见
     [`editor-ui.md`](../editor-ui.md) 的 `createMap` 上限、`guard` 收口、`lineCells` 整数三节。

19. **编辑器新测试面(2026-10-15 拆目录那批)经**独立变异复核**后剩下的弱守卫**(2026-10-15,两名审阅者各跑一遍变异台;仓库外副本,零改动)。
   - **背景**:这批新写的 1525 条断言里,主体质量是好的 —— **15 条最承重的断言逐条做生产端变异,全部按预期红、且红在预期的断言名上**(例:非对称象限 `1<<(sy*2+sx)` 转置、调色板上界 `>=`→`>`、并发按 id 配对、应答到达撤闹钟、跨接缝去烤)。
     下面登记的是**复核后仍然存在的弱守卫与假绿**;最贵的 5 条已在同轮修掉并各自做过变异验证(见下"已修")。
   - **已修(附变异证据)**:
     ① ★★★ **大图背景层内容零覆盖** —— `40_golden_and_limits.js` 原先只比 1.92M 个子格里的**前 64 个**
     (0.0033%),`decodeColorLayer` 改成"`i >= 1000` 之后全填 0"**全绿**(静默丢数据)。已改成**跨全长步进**
     (步长 997,1926 个采样点)+ 两个端点;变异复跑 ⇒ 红在 `背景层 rgba[1994]`。
     ② ★★★ **`validateMap` 的 warnings 侧只有正例** —— 把 4×4 实心谓词整段改成"永远实心"**全绿**。
     已加"规规矩矩的图 `warnings` 必须为空"+「只填 3 行 / 1 行不算实心」两条;变异复跑 ⇒ 红 3 条。
     ③ ★★ **`tint/10` 的中性档期望值与被测代码同源**(`from Core.*`)—— 中性档整体挪位也测不出。
     已把期望值写死 `4/4/4/7`;变异(中性档 4→5)复跑 ⇒ 红。
     ④ ★★ **`render/10_mount` 的 `setDimOthers(false)`** 判据是"存在一条 alpha===1",被 `LAYER_BG` 的压暗豁免
     **恒真喂饱** —— 把 `setDimOthers` 整个掐掉全绿。已改成"一条 `0.4` 都不许有 + 这一趟真画过东西";
     变异复跑 ⇒ 红在预期那条。
     ⑤ ★★ **条数闸缺失** —— `harness.js` 的 `pass+fail===0` 只挡"全零";把**一整个分片**从入口的 require 里
     注释掉 ⇒ 275 通过 / 0 失败、判词照打 `SMOKE OK`。已给 `finish()` 加第二参 `minChecks`,7 个入口各自带实测条数
     (330→336 / 96 / 68 / 241 / 604 / 170 / 16);变异(注释掉一整个分片)复跑 ⇒ `只跑了 281 条断言(条数闸 336)`、rc=1。
   - **仍空着的(每条都附"去掉什么才会红")**:

| 位置 | 判定 | 去掉什么才会红 |
|---|---|---|
| `level_editor/tests/format/40_golden_and_limits.js` `MAX_BODY_SIZE > 20MB` / `4096 <= MAX_BODY_SIZE` | **已删·2026-10-15**(D1:被 `=== 64MB` 蕴含) | 被同分片 `=== 64MB` 蕴含,不可能单独红(实测:改成 21MB 只红那一条) |
| `tests/format/40` 的 `bigN === 1920000`;`tests/format/20` 的 `probe.size > 256` | **已删·2026-10-15**(D1:被 `=== 69615` 蕴含) | 各自被上一条(`1600`+`1200` / `=== 69615`)蕴含 |
| `tests/format/40` 的 `18` / `161` / `181` | 假绿(有意) | 纯夹具算术,对生产代码零覆盖 —— **有意保留**(支撑手推的 `161 = 18+24+28+24+65`),但别计入覆盖。★ 同族的 `eq(n, 320)` 已删(`20*16` 读一眼就能验,是纯算术) |
| `tests/format/60` 的 `>2 个出生点` | 弱守卫 | 没测"恰好 2 个不该报"(实测 `>2`→`>=2` 全绿) |
| `tests/format/60` 的 `indexOf('出生点')` / `indexOf('空')` | 弱守卫 | 三条文案都含该词,分不出是哪条在响 ⇒ 建议比 `warnings` 集合或钉整句 |
| `tests/format/20` 的 `≤256 项 → index_width=1` | 弱守卫 | 只喂了 3 项与 301 项,**256/257 分界无守卫**(实测 `<=256`→`<=255` 全绿) |
| `tests/format/40` 的"只有背景层仍放行" | 弱守卫 | 只钉"别误拒";`level_editor/core/60_codec.js` 颜色层那半 `room/4` 无断言(实测改成 `room` 全绿) |
| `tests/format/30` 的 `'incorrect data check'` | 弱守卫 | 判据是 **Node/V8 的措辞**,不是本仓契约(实测 `message` 为空、话在 `cause.message`) |
| `tests/worker_io/10` 的 `'compression'` 子串 | 弱守卫 | 吞掉 worker 带回的错因、换一句含该词的话仍绿(同文件 `'magic'` / `'小于头部'` 两条是对的) |
| `tests/worker_io/10` 的 `workerAvailable() === false` | 假绿 | 断言的是"node 没有全局 `Worker`",不是这个函数的实现(硬编码 `return false` 全绿) |
| `level_editor/worker.js` 的 `errText` 的 `cause` 回退 | 弱守卫 | 它的正当性只在"直调 core"那条被证过,worker 路径上没有断言 |
| `tests/tint/30` 的两条 `sameBytes(cache 像素, buildTilePixels(...))` | 弱守卫 | 两边是**同一生产函数同一实参** ⇒ 对该函数任何确定性变异都对称 |
| `tests/format/20` 注释「解码路径不许用 `isAir` 判空气」 | 注释超范围 | `isAir` 在生产侧**零调用点**(只有定义 + 导出)⇒ 那个分支不存在 |
| `level_editor/render/90_install_drag.js` 的 `live = !!s.selDrag && !!s.selection` | 弱守卫 | 注释自称"与 `dragSource` 早退逐字同源",但去掉 `&& !!s.selection` 全绿 |
| `render/86_install_layer_path.js` 的 `buildCell` 空气短路 / `84_install_thumbs.js` 的 `paintThumbRect` 空气短路 | 无覆盖 | 删掉各自都全绿(生产侧跑了 23788 / 82715 次)—— 属**性能型**短路,正确性不变 |
| `render/86_install_layer_path.js` 的"尺寸不符的离屏层不画" | 无覆盖 | 删掉全绿 |
| `level_editor/tests/render/50_layer_canvas.js` 的 ⑪b2「同一格只有一条缓存条目」 | 弱守卫 | 它前面 `cells().clear()` 之后那次折算读已把该格建进表 ⇒ 这条 get 必然命中 |
| `level_editor/tests/render/50_layer_canvas.js` 的 ⑪e「接缝另一侧由环面折算补上」 | 弱守卫 | 把 `torusList` 换成恒 `[[0,0]]` 照旧绿 —— 它实际钉的是副本那一笔的落点,不是折算 |
| `level_editor/tests/render/10_mount.js` 的两条视图断言 | 弱守卫 | 只判坐标**范围**不判值(`(10,10)` 也过) |
| `level_editor/tests/render/80_drag_layers.js` 的"旧的非折算口径"对照 | 对照不成立 | 与上一条同一个 `inSel` 分支,折算与非折算**同时** `hit:false` |
| `level_editor/tests/render/40_slicer_and_geometry.js` 的两条 reject 断言 | 红的原因不对 | 去掉 `.then(step, reject)` 第二实参 ⇒ Node 崩在 unhandled rejection;去掉 `reject(err)` ⇒ 120s 超时 |

   - **怎么销**:上表按性价比分三档 —— ⓐ 边界采样不足(256/257、2 个出生点、`room/4`)直接补样本,一条一两行;
     ⓑ 子串太松(「出生点」/「空」/「compression」/`incorrect data check`)改成比集合或钉完整短语
     (范本:`level_editor/tests/worker_io/40_request_timeout.js` 那条"取 `编解码请求超时` 整短语"的判据,自己解释了为什么不能用裸 `超时`);
     ⓒ "被前一条蕴含 / 夹具算术"那几条**保留但别计入覆盖**(它们改善诊断,不构成验证)。
   - **owner**:编辑器侧([`level_editor/tests/`](../../../level_editor/tests)、[`level_editor/render/`](../../../level_editor/render)、
     [`level_editor/worker.js`](../../../level_editor/worker.js));**最后复核**:2026-10-15。

20. **编辑器 `tests/editor/` 5x–8x 与 `tests/server/` 的复核结果**(2026-10-15,与 §19 同批;两名审阅者共跑 45 条生产端变异,仓库外副本、零改动)。
   - **先说正面结论(别重查)**:① **服务器侧没有假绿** —— 14 条生产端变异(Host 闸+端口、Origin、`Sec-Fetch-Site`、`realpath` 包含性、重试名单、退避封顶、临时文件清理、空体拒绝、静态遍历、名字正则……)**全部按预期红**;
     ② 服务器测试**真的起 HTTP、真的读写磁盘**:全目录无 fs 打桩,一律 `mkdtemp` 真目录 + `startServer({port:0})` 真端口 + `http.request`,
     连"`stat` 成功但 `open` 失败"都是用真 PowerShell `FileShare.None` 独占句柄造的(删掉 `stream.on('error')` ⇒ 整个 node 进程崩,正如注释预言);
     ③ 编辑器侧这些**有牙齿**:`level_editor/tests/editor/60_draft_write_race.js` 的真缺陷形状断言、
     `level_editor/tests/editor/52_save_flow.js` 的"保存失败徽标不许翻"、`level_editor/tests/editor/64_draft_guard.js` 的四条 `guard` 护栏、
     `level_editor/tests/editor/54_save_backup_boot.js` 的"备份在前"三条、`level_editor/tests/editor/50_save_names_persist.js` 起的逐字节比对、
     `level_editor/tests/editor/66_draft_crash_evict.js` 的记账断言。
   - **本轮已修(附变异证据)**:① `level_editor/tests/editor/40_interaction.js` 的总网"整个相位一条错误都没进 sink" —— `errs` 曾被清空四次
     ⇒ 只盖最后 25 行,删掉替身一个方法也判 ok。改成**只清 `calls`、`errs` 累计**(逐相断言仍然有效且更强);
     变异(删替身的 `setSelDrag`)⇒ 8 条红,总网打出被吞的三条异常。
     ② `level_editor/tests/editor/54_save_backup_boot.js` 的"工具条仍然接上了" —— `st.tool` 已被上游分片置成 `'line'`,点「直线」是**幂等**的
     (原文打印 `line → line` 照样过)。改成先挪到 `'brush'` 再点;变异(删掉 `level_editor/ui/85_panels.js` 里 `#toolbar .tool` 的点击接线)⇒ 红在 `brush → brush`。
     ③ 条数闸(§19 ⑤)同时也堵住了"整个分片空转"那条(变异:把 `level_editor/tests/editor/82_recheck_lib_space.js` 整相短路 ⇒ `只跑了 594 条断言(条数闸 604)`)。
   - **仍空着的**:

| 位置 | 判定 | 去掉什么才会红 / 证据 |
|---|---|---|
| `level_editor/tests/editor/60_draft_write_race.js` 的"与保存赛跑的那次落盘" | ★★★ **假绿**(夹具排程冒充被测守卫) | 删掉它声称钉住的 `level_editor/ui/75_draft_store.js` 里 `if (rev <= draftSavedRev) return null;` ⇒ **604/0 全绿**;加了打点的强化版更硬:生产**确实写了 `dirty:true`**,而断言报"干净"。根因是替身的 `setTimeout(…,0)` 事务排程让"保存"的那笔后落地,终态与 rev 守卫无关。**销法**:断言前先断言那次竞争写入真的发生,或让替身按创建顺序严格串行化 readwrite 事务(两选一都要重跑一遍本文件) |
| `level_editor/tests/editor/40_interaction.js` 的"走了搬动+存回选区两条路" | **已删·2026-10-15** 假绿(stale 累加器) | `calls` 自本相开头未清空,前几相早就压入过(变异:删掉"按在选区里"判定 ⇒ 上游那条红、这条绿) |
| `level_editor/tests/editor/30_history_clipboard.js` 的 `before` 快照断言 | **已删·2026-10-15** 假绿 | `applyEntry` 已把 `map.layers` 换成防御性拷贝 ⇒ 与快照脱钩(`snapshotMap` 改 alias 也全绿,同文件另一块才红) |
| `level_editor/tests/editor/40_interaction.js` 的"与落笔那一侧逐格一致" | **已删·2026-10-15** ★★ 自洽 oracle | 参照系 ≡ 被测物(`regionCells` 内部就是转调 `Render.inSel`)⇒ `inSel` 改非折算它照绿 |
| `level_editor/tests/editor/40_interaction.js` 的"0 个就是框里画什么都没发生" | **已删·2026-10-15** 弱守卫 | 与同文件"`regionCells` 会折算 clip"那条相反 ⇒ 把 `unwrap_sel` 变异掉,上游红它绿 |
| `level_editor/tests/editor/42_boot_ui_state.js` 头注「走真序列 `readUiState → setAtlas → applyUiState`」 | 弱守卫 | 三步全是测试自己调的,`bootLoad` 一次没跑(把 `level_editor/ui/92_boot.js` 的 `readUiState` 挪到 `loadAtlas()` 之后 ⇒ 604/0 全绿) |
| `level_editor/tests/editor/60_draft_write_race.js` 的 `t15.ms === DRAFT_DEBOUNCE_MS` | **已删·2026-10-15** 弱守卫 | 期望值就是被测常量(改成 30000 仍绿)。★ 同相位的 `level_editor/tests/editor/50_save_names_persist.js` 的 `DRAFT_DEBOUNCE_MS >= 500` **留着** —— 它至少钉住"有防抖"这个量级 |
| `level_editor/tests/editor/60_draft_write_race.js` 的 `savedAt >= before` | **已删·2026-10-15** 弱守卫 | 文案说"前移",判据是 `>=` ⇒ `flushDraft` 变空转本条照绿 |
| `level_editor/tests/editor/50_save_names_persist.js` 的"同名得到同一个备份名" | **已删·2026-10-15** 弱守卫 | 同一表达式调两次比相等 ⇒ 只挡非确定性 |
| `level_editor/tests/editor/54_save_backup_boot.js` 的 `v3BackupName(a) !== v3BackupName(b)` | **已删·2026-10-15** 弱守卫(重复) | 与 `level_editor/tests/editor/50_save_names_persist.js` 的同源同事实(D4) |
| `level_editor/tests/editor/54_save_backup_boot.js` 的两条 `indexOf(子串)` 确认框断言 | 弱守卫 | 查子串不查整句 |
| `level_editor/tests/editor/66_draft_crash_evict.js` 的 `count >= 1` | 弱守卫 | `>=1`,问两次也过 |
| `level_editor/tests/editor/66_draft_crash_evict.js` 的 getAll/cursor/keys 记账 | OK 但结构敏感 | **有牙齿**(删早退 / 换游标类型都红),登记为"代价形状"而非行为 |
| `level_editor/tests/editor/62_draft_restore_boot.js` 的 `tg-grid.classList.contains('on') === false` | **已删·2026-10-15** 假绿(⇒ `#tg-grid` 的 DOM 回写**零覆盖**) | 夹具喂的 `grid:false` 正好等于替身默认态 ⇒"没碰 DOM"与"按回去了"同形 |
| `level_editor/tests/editor/82_recheck_lib_space.js` 的"兜底文案里不出现备份名" | **已删·2026-10-15** 假绿(node 侧不可能红) | 替身的 `textContent` 不像真 DOM 那样聚合子节点文本 ⇒ 删掉 `level_editor/ui/90_open.js` 的 `.filter(!isBackupName)` 本条照绿(列表里真有 2 行 `.v3.bak`)—— 真实浏览器里会红 |
| `level_editor/tests/editor/54_save_backup_boot.js` 的 `desc-only` 整行隐藏 | 假绿 | 夹具把 `parentNode` 直连 `.desc-row` 替身,抹掉了唯一需要上溯的那层(真结构是 `div.desc-row > label > input`) |
| `level_editor/tests/editor/72_wiring_compress_pan.js` 的"控件不在时按默认走" | **已删·2026-10-15** 假绿(⇒ `DEFAULT_COMPRESS` 分支**零覆盖**) | 替身的 `getElementById` 永不返回 null ⇒ `DEFAULT_COMPRESS` 分支不可达 |
| `level_editor/ui/75_draft_store.js` 的"恢复时写回 `app.name`" | 覆盖率缺口 | 删掉全绿 |
| `level_editor/ui/80_ui_state.js` 对 `#dim-others` / `#brush-size` / `#tg-subgrid` / `#tg-torus` 的 DOM 写回 | 覆盖率缺口 | `grep` 全 `level_editor/tests/editor/` **零命中** |
| `level_editor/ui/70_draft.js` 的 `if (!dirty) return` 早退 | 覆盖率缺口 | 删掉全绿 |
| `level_editor/tests/editor/66_draft_crash_evict.js`(整片删掉) | 红的原因不对 | 不是条数闸报错,而是**挂到 120s 看门狗**、判词误指"lineCells 拿到非整数坐标" |
| `level_editor/tests/editor/62_draft_restore_boot.js`(整片删掉) | 红的原因不对 | 3 条失败全落在 `level_editor/tests/editor/64_draft_guard.js` 里,文案与"少了一个分片"无关 |
| `level_editor/tests/server/20_static_read_failure.js`、`level_editor/tests/server/50_write_gates.js` 的自跳过分支 | 弱守卫 | 自跳过打印 `--` 而**不计入断言**,也没有"skip==0"闸 ⇒ 非 Windows / 建不了链接的机器上整个相位静默消失而判词照绿(本机两条都真跑了) |
| `level_editor/tests/harness.js` 的 `minChecks` 闸(§19 ⑤ 已加) | 残留弱点 | 判据是**全局总数 `>=` 手抄字面量** ⇒"一个分片死掉 + 别处新增等量断言"仍可全绿,且数字要人工随增删同步(§二 那条"重复真相源+守卫"的税) |
| `level_editor/tests/editor/10_core_tools.js` 的两条 `lerpRGBA` 断言(黑白 t=0.5 / 同色 t=1) | **已删·2026-10-15** 假绿 | 代入的是**对称/退化特殊值**:`t=0.5` 与"同色"在 t↔1−t 反转下都不变 ⇒ `lerp_invert` 变异下仍绿(只有渐变端点那两条红) |
| `level_editor/tests/editor/20_hotkeys_errors.js` 的 URL 子串断言 | 弱守卫 | 多拼参数也过、文件名不需转义 ⇒ `encodeURIComponent` 无覆盖 |
| `level_editor/tests/editor/10_core_tools.js` 的 `eq(job.runChunk(4), {…})` | 脆性 | `eq` 走 `JSON.stringify` ⇒ **钉住键序**(只换 `level_editor/ui/20_tools.js` 的键序、行为零变化也会红) |
| `level_editor/tests/editor/40_interaction.js` 把「跨接缝框选 = 整整一行」这个**已知缺陷**钉成期望 | 脆性(反向) | 谁修好谁红 ⇒ 建议移进 `known-red.md` 或改成容忍两种(缺陷本身登记在 `tools.md` §5 ①) |
| `level_editor/tests/editor/30_history_clipboard.js` 的 `bytesOfEntry(whole) === 0` | 弱守卫 | 对"字节数"不敏感(有牙的是相邻两条) |
| `level_editor/tests/editor/10_core_tools.js` / `level_editor/tests/editor/42_boot_ui_state.js` 依赖"此刻图集容量 0" | 脆性 | 说的是**套件全局状态**,不是行为 |
| `level_editor/editor_smoke.js` 的 `PARTS` 清单 | 弱守卫 | 手抄,无"与目录对账"守卫(新加一个测试分片文件却忘了登记 ⇒ **静默不跑**,而条数闸只挡"变少"不挡"新文件没登记") |

   - ★ **2026-10-15 销毁批次(18 条)**:标 `**已删·2026-10-15**` 的行 = 断言已按 D 组删掉 —— 被前一条蕴含(D1)、纯算术夹具、同源重复(D4)、**代入对称/退化特殊值**、**替身喂默认态/返回类型不可达**五类。删后 `smoke` **336 → 331**、`editor` **604 → 591**,条数闸同步更新(它正是被这次删除拦下来的);销毁前后各重跑一遍原变异,**六条承重变异(跨全长背景层 / 无条件实心 / `setDimOthers` / 工具条接线 / 替身少方法 / 中性档挪位)全部照红** ⇒ 删掉的是死重,不是牙齿。
   - **怎么销**(按性价比):① 60 那条**假绿**优先(它挡的是"草稿被重新写脏 ⇒ 下次开机弹假恢复提示",已有两条备选修法);
     ② `42` 的"真序列"可以**真调一次 `bootLoad`**(替身齐全的前提下)把三步变成生产驱动;
     ③ 覆盖率缺口里 `dim-others` / `brush-size` / `tg-subgrid` / `tg-torus` 四条最便宜(补四行 DOM 断言);
     ④ "自洽 oracle / stale 累加器 / 默认态同形"三类改判据(换参照系、先清累加器、先喂非默认值);
     ⑤ 红的原因不对(整片删掉)可在入口给每个分片包一层"我跑完了"的记账;
     ⑥ 服务器的 skip 可以加一条"非 Windows 时**显式**把该相判为跳过并计入总条数闸"。
   - **owner**:编辑器侧([`level_editor/tests/editor/`](../../../level_editor/tests/editor)、[`level_editor/tests/server/`](../../../level_editor/tests/server)、
     [`level_editor/ui/`](../../../level_editor/ui));**最后复核**:2026-10-15。

21. **联机侧复核(2026-10-15;三名只读审阅者,范围 = 5 支真链路 `.sh` + `server/`/`core/net/`/`scenes/` 的联机接线)**。

    ★ **本批已修 6 条**(同一批提交;★ **未跑任何测试** ⇒ 只算"读起来对",不算"验过"),逐条附「为什么今天没有守卫会红」:

    | 已修 | 缺陷 | 为什么红不了 |
    |---|---|---|
    | 1v1 客户端**从不订阅** `local_sub_destroyed` | 子弹/爆炸拆的**子格**在 1v1 里是**幽灵墙**(服务器已无,客户端贴图**与碰撞**都在)⇒ 本地预测撞在服务器不存在的墙上 = 每帧 C2 回滚;视觉子弹也被挡下 | 拆砖有两条路:`damage_tile`(格级,`--test-destroy-tile` 走它)与 `damage_sub`(子弹/爆炸);而线上**只有后者**发 `sub_destroyed`。探针结构上碰不到子格那条 ⇒ **零守卫** |
    | RPC 通道契约守卫的 `TABLE_MD` | 2026-10-13 的文档拆分把通道表搬到了 `netplay-rpc-channels.md`,常量仍指 `netplay.md` ⇒ 解析出 0 行 ⇒ **唯一守通道号的那支红**(判词 `RPC CHANNEL CONTRACT FAILED`) | 它自己就是那条守卫;已知绿跑记录停在 2026-10-10(拆分**之前**)⇒ 不重跑看不见 |
    | `_on_remote_sub_destroyed(sub, silent := true)` | 默认值与姊妹函数(**false**)相反,而信号只传 1 个实参 ⇒ **活的**子弹/爆炸拆砖**永不播碎片**(格级那一路却播 17 发:16 子格 + 整格) | 只影响观感 ⇒ 没有任何守卫会红 |
    | `team_match_probe.FINAL_TIMEOUT=780` | 与 `RESULT_WAIT=680` **不同钟**(后者从 `_start_t` 算,而 `_start_t` 最晚取到 `BOOT_TIMEOUT+60=105`)⇒ 最坏 `105+680=785>780` ⇒ 收工上限先到点,判词退化成「超时(780s;阶段 3)」,**盖掉能指路的那条「只收到 N/6 份结果」** | "安全网耗尽与真失败同形"⇒ 只有最坏时序才现形 |
    | `royale_soak_probe.sh` 的 `RC=$?` | `\| tee` 之后拿到的是 **tee** 的退出码(结构性恒 0)⇒ "探针崩了"被静默变成 0 | 判据一律 grep 文本,退出码从来不是判据 ⇒ 没人发现(兄弟两支用 `PIPESTATUS`,本支漏了) |
    | 三支真链路脚本在 7777 有活大厅时的处置 | `pvp_match_smoke` / `pvp_room_smoke` **照跑**、`royale_soak_probe` **直接杀属主**;而服务器 `_ready` 本来就会 `kill_udp_port(7777)` ⇒ **会端掉用户正在进行的对局** | 批内由 `run_real.sh` 的闸一挡住 ⇒ 暴露面是**手动单跑**,而 `run_real.sh` 的收尾正好邀请手动单跑;脚本里那句"那时本脚本本来也 bind 不上"是**错的** |

    ★★ **同日第二批:上面那份"未修"清单里除一条外全部修掉了**(§21 记的是"修前状态",保留以便回溯):

    | 已修(第二批) | 修法 |
    |---|---|
    | **`team_match_probe` 没有条数闸 + 恒真断言 + 可空转循环**(3v3 **唯一**真链路的 `ALL-OK` 可以什么都不验) | 加 `_checks` 计数 + `MIN_CHECKS := 24` 闸(★ 取**下界**:相③ 的条数随抽到的武器合法浮动,精确数要真跑后钉);`if ka >= 1: _check(true, …)`(读数伪装成断言)改 `_notes.append`;`for r in conv_ok:`(空表时**一次不跑**)改成"先判六端都写了 + 再判六端都对"两条 |
    | `pvp_room_smoke.sh` 早退留活客户端 ⇒ **整批中止在第 2 支** | 共享助手提到 [`tests/env.sh`](../../../tests/env.sh) 的 `kill_clients_by_cmdline <客户端 .tscn 名>`(两支各留一行别名);本支**每条退出路径**都调 + 早退补 `kill_port_range` |
    | `royale_soak_probe` 三缺 | **(a)** 探针多打一行可 grep 的 `SOAK: 终局状态 —— N/M 端观察到 MATCH_OVER`(`.sh` 也据此区分 `PASS(终局)` / `PASS(未终局)`);**(b)** `.sh` 补 `--quit-after 54000`,探针收住子进程 PID 并在收尾 `OS.kill`;**(c)** 两处 `remove_absolute` 判定返回值,失败即点名 + `quit(1)` |
    | 两支池外区间重叠(team 扫 `[29250,29400)` 含 rejoin 的 29300/29350) | team 收窄到 `[29250,29300)` |
    | `pvp_room_smoke.sh` 停在 §五.9 修前形态(固定 `sleep 3` + 无存活判据 + 判词指错嫌疑人) | 照兄弟支改成**有界轮询 + 存活判据 + 判词点名真嫌疑**(三处:`服务器就绪`/房间号/`match_start`) |
    | `team_match_watcher.gd` 的 `_tick_enter` 无界等待 | 加 `ROUND_STATE_TIMEOUT := 30.0`(**从 TEAMS 到手那一刻单独计时**,不会因 match_sync 慢而假红;合计 < `ENTER_TIMEOUT 90`) |
    | `_clean()` 不清 **worker 日志**(`user://logs/worker_<port>.log`)⇒ 启动窗口里能读到上一跑那行"就绪" | 一并清,删不掉即收工(只扫池外那一段端口) |
    | **零读者访问器** | 删:`ui/hud/pvp_hud.gd` / `team_hud.gd` 的 4 个探针兼容转发(`_mask`/`_big`/`_sub`,**连内部都没用**)、`core/net/playout_clock.gd` 的 4 个、`server/lobby/rejoin_registry.gd` 的 `size()`(全仓零读者、无字符串式 `call()`) |
    | **时间规则客户端可写**(半条) | `TimeRules.from_dict()` 把 `haste_mult` **钉死成 `DEF_HASTE_MULT`**(服务器不听载荷;`from_dict` 的唯一调用方就是服务器,而 haste **不进建房页** ⇒ 3.0 以外的值只可能来自被改过的客户端) |

    ★ **仍开着的只剩一条**(需要**协议改动**,不在"顺手修"的射程内):
    **1v1 也能塞 `time`** —— 那道门只在客户端(`scenes/mp_lobby.gd`:`PvpSession.beta_mode and 模式 != 1v1`),
    而 worker 侧的 `options` **不带 `mode`** ⇒ 服务器无从判断"这一局该不该有颗粒经济"。
    要闭合得往 `_build_options()` 里加 `mode` 字段并在 `match_host.gd` 侧忽略 1v1 的 `time`(改协议 = 档 3,要真链路批 + 逐任务评审)。
    ★ 本仓明说不承担反作弊 ⇒ 这一条的定性是**协议完备性**,不是安全缺口。

    ★★★ **本批真正的模式发现 —— 「锚点/路径被搬家 ⇒ 守卫静默失效」,一天之内撞见三例**:
    ① `reconnect_smoke` 的 `_func_body` 锚在**已搬走的函数**里(按钮挪进 `.tscn`)⇒ 恒假、永远红(2026-10-04 登记,该支已删);
    ② `team_match_watcher` 靠**节点自身的 `visible`** 判"按钮亮了",而祖先面板隐藏**不算**(`is_visible_in_tree()` 才算)⇒ 第一帧误点后 `_started=true` **永久锁死**(2026-10-15 修);
    ③ `rpc_channel_contract_smoke` 的 `TABLE_MD` 指着**已搬走的表**(2026-10-15 修)。
    共同点:**锚点失效的方向恰好是"更容易满足"** ⇒ 它们要么照旧绿、要么红得**指向错嫌疑人**(三次分别被记成"产品没建房""等待预算算错""通道号写错了")。
    ⇒ **搬迁检查表**(下次搬家照做):`grep` 旧路径 / 旧函数体 / 旧节点名,把**所有**靠文本或路径活着的东西列出来**一起**改;
    判据能用**语义**的(`%UniqueName`、`is_visible_in_tree()`、`has_method()`)**就别**用"读某个字段/某段文本"的。

    - **owner**:联机侧([`tests/harness/`](../../../tests/harness)、[`tests/probe/`](../../../tests/probe)、[`tests/smoke/`](../../../tests/smoke)、
      [`server/`](../../../server)、[`core/net/`](../../../core/net)、[`scenes/`](../../../scenes));**最后复核**:2026-10-15。

19. **服务端控制台面板(`server/gui/`)整块零自动化守卫**(2026-10-17 新增)。五处只能靠人眼/评审:
    ① **版式 / 配色 / 字号**零守卫(`AGENTS.md` §2 表末行:观感不写自动化守卫)——
       判据是人眼 + `-- --panel-audit` 打出的逐控件内缩(它是**设计期仪器,不是守卫**);
    ② **导出标记回退会让面板静默消失**:面板存在的前提是 `export_presets.cfg` 的 `custom_features="serverui"`
       + `project.godot` 的 `run/main_scene.serverui`。任一被改回去 ⇒ 服务端 exe 又变回 headless、
       面板不出现而**零报错**。硬造守卫必然是 D6(读配置文件文本判形态)⇒ 不写;
    ③ **`server/gui/lobby_snapshot.gd`(适配层)零守卫**:它引用 `LobbyRooms`,后者引用 `NetBus`
       ⇒ `-s` 冒烟里编译不过(实测 `Identifier not found: NetBus`)。对策:判据逻辑**全部**让给
       `server/gui/server_status.gd`(有冒烟钉着),适配层只做字段搬运 ⇒ 靠评审;
    ④ **`server/server_main.gd:118` 那一行的位置**零守卫:面板必须在 `_ready` 体内、
       `add_child(RoomManager)` 之后、`set_process(false)` 之前,且中间没有早退 ——
       钉它的 `duel_spawn_timeout_smoke` **已删·2026-10-09**;
    ⑤ **1280×960 窗口下 1920×1440 逻辑空间是 2/3 非整数缩放**,像素边缘略不均 ——
       与主菜单/大厅**同一个**已接受的取舍,不单独立项。
    - 设计/规则依据:[`docs/superpowers/specs/2026-10-16-server-console-gui-design.md`](../../superpowers/specs/2026-10-16-server-console-gui-design.md) §9。
    - **owner**:服务端侧([`server/gui/`](../../../server/gui)、[`server/server_main.gd`](../../../server/server_main.gd)、`export_presets.cfg`);**最后复核**:2026-10-17。
