# 功能性已知边界（续）：**只有静态推理、没有自动化路径**的那一类

> **本文件从 [`functional-boundaries.md`](functional-boundaries.md) 拆出**（2026-10-13）。
> **为什么拆**：原文件在拆出这一簇后是 **68,494 B > 64KB** —— 越过 `CLAUDE.md:5` 那条"工作区指令预算"
> 线（后半本会被截断，等于没写），判据与 `registered-debt.md` 那次拆分完全相同。
> **编号不变**：下面这三条在原文件里的编号是 15 / 23 / 24（原处留了 stub），所以 `§六.15` 之类的引用仍然指得到。
> ★ **本簇的共同点**：它们的边界**只能靠静态推理或人工复现** —— 没有自动化路径能到达，因此
> "改坏了会不会被发现"这个问题的答案是**不会**。这正是它们值得单独成篇的理由。

15. **玩家根那 5 处反射只有"计数上界"守卫、不逐名**(2026-10-04 由 Task 3 R1 的补审点名；原先只在报告里，控制器落纸)。
    ★★ **2026-10-04 已修（Plan B Task 15，提交 `70c0f9c`）** —— 下面第一条是**历史形态**（保留：它记着"控制器为守卫的
    充分性编理由"那次病），第二条是**实测证伪**，第三条起是**已落的修法与仍存的边界**。
   - 旧形状守卫是 `.get("` + `has_method("` **≤ 5** ⇒ 若有人把 `is_downed` 改名成 `is_downed_x`，**计数仍是 5 ⇒ 绿**，
     而行为会**静默退化**（`"downed"` 恒 false ⇒ `player.gd:461-469` 的倒地/复活还原被跳过 ——
     `apply_authoritative_state()` 里 `downed_val` 分流到 `combat.force_down()` / `combat.revive()`）。
     ★ **行号沿革（2026-10-13 复核；★ 下列三档**全部已过期**，照实保留是为了留痕）**：原文写 `player.gd:987-989` → Task 15 时实测 `995-998`
     （该文件当时共 998 行）→ closeout 批 Task 2（`b1eab80`）在 `rewind_restore` 里插了 44 行后又移到 `1039-1042`。
     **这三档现在全部过期**（该文件现 **845** 行）；**现行落点 = `player.gd:461-469`**
     （`apply_authoritative_state()` 里 `downed_val` 分流到 `force_down()` / `revive()`；
     复核法 = `grep -n "combat.revive()" scenes/player/player.gd`）。
     ★★ **2026-10-05 二次订正（closeout 批 Task 2，提交 `b1eab80`）**：那一轮在同一条链路的
     `player.gd::rewind_restore` 里插了 44 行 ⇒ 那四行又移了；复核法同上，实测 **`1039-1042`**
     （该文件现在共 **1042** 行 = 那四行就在末尾）；同轮 `EXPECTED_CHECKS` 也 61→**86**（新增 S8/S9，见下面 §13 的实况更新）。
     ★ 上面"995-998"**保留为当时实况**，别当现状读。
   - ★★ **2026-10-04 实测（Task 13 的 G-1 证伪了控制器原话）**：上面那句"**行为**断言能咬住"**实测不成立** ——
     只把 `_snapshot_player` 里的字符串改成 `has_method("is_downed_x")`（**真方法不动**）⇒ 探针 **ALL-OK 60/60**：
     `_s7_producer` 只断言 `wslot/widx/wmags/wlive`，**从不看 `snap["downed"]`**；而 `rewind_probe.gd`（已删·2026-10-09） 里 `downed` 出现 **0** 次。
     ⇒ **当时**这条形状守卫**只有"≤ 5 计数上界"一条保证**（Task 15 在本机把这一跑复现了一遍：旧探针 + 同一变异 = **60/60 零红**）。
     ★ 控制器当时为守卫的充分性**编了个理由**，正是本会话一直在追的那类病。
   - **Task 15 的修法（已落）**：(a) 度量换成 `_has_member_token` **逐名核** —— 5 个**访问形态**各一条谓词，与原来的 `≤ 5`
     合取进**同一条** `_check` ⇒ **条数不变**；(b) 补一条 `snap["downed"] == 真值` 的**行为**断言（两相：活着 → false、
     倒地 → true），`EXPECTED_CHECKS` 60→**61**（**历史值**；★ 现为 **90**：Task 2 +S8/S9 → 86、修复轮 1 +4 → 90）。逐条变异实测：5 条后缀拼接各自红在 (a) 那一条（消息里点名缺哪个），
     其中 ⑤ 就是 G-1（旧守卫下 60 条全绿 ⇒ 现在 **(a) 与 (b) 各红一条**）。
     ★★ 为什么每条都要带**访问形态**（`get("hp")` 而不是裸 `hp`）：裸名会被**同一个函数里的别的出现**骗过 ——
     `"hp"` 同时是字典键、`is_downed` 同时是 `player.is_downed()` 那个真方法调用 ⇒ 裸名判据对"字符串被改名"**恰好无牙**。
   - **仍存的覆盖上限（照实）**：(a) 只挡"成员名被改名/后缀拼接"；**换个完全不同的名字**（`is_downed` → `is_alive`）仍只有
     (b) 那条**行为**断言兜着（它现在真的会红）。**补了 `downed` 这一维 ≠ `snap` 全维都守住了**：`snap` 的 9 个键里
     `wslot/widx/wmags/wlive` 有"生产端 == 真值"断言（`rewind_weapon_probe` S7 + `rewind_probe` ⑨），`downed` 由 Task 15 补上，
     而 **`p`/`hp` 只有端到端间接覆盖、`v`/`facing` 两键今天没有任何断言**（清点见 Task 15 报告）。
   - ★ **第三处过期行号：已订正**（2026-10-04，控制器 R2 放行后定点改，提交 `dc06574`，纯注释）。原状：`core/sim/world_rewind.gd:150`
     也写着 `player.gd:987-989`（同款过期）；同段 `:151-152` 把本守卫描述成"度量写成 `.get("` + `has_method("` **≤ 5**"。
     现状：行号已成 `995-998`（★ **2026-10-05 又移到 `1039-1042`**，见本条第 1 段的二次订正），
     描述已改口为"**逐名核那 5 处访问形态 + 一条 `snap["downed"] == 真值` 的行为断言
     （`EXPECTED_CHECKS` 61；**历史值**，★ 现为 **90**）**"，并保留"旧计数上界对第 ⑤ 处改名无牙"的 G-1 实测根据。
     ★ 教训留档：Task 15 的硬约束**只允许碰** `rewind_weapon_probe.gd`（已删·2026-10-09） 与本文件 ⇒ 当时那两处**没改**、
     只在报告里点名；**是控制器放行才补上的** —— "改了 A 就过期的 B" 若落在**改动集之外**，必须显式交回控制器，别默默留着。
   - **手工复核点（将来改这一带时）**：`rewind_weapon_probe.gd`（已删·2026-10-09） 的 `PRODUCER_NAMED_PLAYER_ACCESS` 与 `_snapshot_player`
     里那 5 处必须**同时**改（后者改名 ⇒ 前者红，这是**设计**不是误报）。

23. **T10/T11 的行为面：当前无自动化路径可达**（★ 这是"归真链路批 A"这句话的**订正**）
   (2026-10-05 由 closeout 批 Task 3 的逐任务评审 I-3 判为**过度声明**并要求登记；owner 未认领)。
   - **被订正的那句话**：Task 3 的探针与报告里有 9 处把 T10/T11 的行为判据写成"**归真链路批 A**"。实测复核
     （评审 R43 + 实现者复核）：**批 A 结构上碰不到它们** ——
     ① `PvpSession.beta_mode` 的写点全仓只有三处，**没有一处落在自动化对局里**：
     [`scenes/beta_menu.gd`](../../../scenes/beta_menu.gd):104（`_enter_card()` —— 点击与 autotest **共用同一入口**；★ 2026-10-13 订正：原写 `:131`、`:128-135`，而该文件**只有 110 行**；**要人点 Beta 页**，**或**走 `main_menu.gd` 的
     `-- --autotest-*` 钩子 —— 见下面②之前那半条）、`lobby_create_form_probe.gd`（已删·2026-10-09）（只建大厅面板，不建局）、
     以及——★★ **2026-10-05 修复轮 2（评审 Minor ⑧）补上的那个驱动者**——
     [`tests/harness/menu_autotest.gd`](../../../tests/harness/menu_autotest.gd) 的 `_run_beta_flow()`（**`func` 在 `:161`** —— 原写的 ":158 起"是它上方的注释行）：它经
     [`scenes/main_menu.gd`](../../../scenes/main_menu.gd):**151-158(注释)+159-174(代码)** 的 `-- --autotest-*` 钩子走**就是** `beta_menu.gd:104`
     那条路，**headless 可达**；但今天它被 [`tests/run_all.sh`](../../../tests/run_all.sh):142 的 `EXCLUDED` 挡在批外，
     **且没有任何脚本调用它** ⇒ "无自动化路径"的**结论仍成立**，只是口径要写成"**要人点 / 或走
     `main_menu.gd` 的 `--autotest-*` 钩子**"。★ 并且这条恰好说明**翻案条件①其实已有半成品** ——
     那条路**只差**"最后一步真建局 + 进对局"。
     ② 真链路脚本**零命中**（★ 2026-10-05 修复轮 2 / 评审 Minor ③：换成**可复现**的命令 —— 裸 grep 会命中
     2 支脚本里的 `timeout` 子串，那是**反证**、不是命中）：
     ```bash
     grep -lwE 'beta|haste|rewind|time' tests/smoke/*.sh tests/probe/*.sh                  # 词边界 ⇒ 0 支
     grep -lE 'beta_mode|haste|rewind|TimeField|_time_' tests/smoke/*.sh tests/probe/*.sh   # 只认关键词 ⇒ 0 支
     grep -lE 'beta|haste|rewind|time' tests/smoke/*.sh tests/probe/*.sh                    # 反证 ⇒ 2 支(rejoin/team_match 的 timeout)
     ```
     ③ 客户端那 7 处所在的三个函数全在同一道 `beta_mode` 闸后（[`scenes/pvp_match_client.gd`](../../../scenes/pvp_match_client.gd) 的 `_tick_beta_time` 首行早退）；
     ④ 服务端那一写同理：[`server/match/match_host.gd`](../../../server/match/match_host.gd) 的那三段全在
     `if time_economy != null:` 内，而 `time_economy` 只在 `options["time"]` 非空时建 ⇒ **普通真链路里
     `match_host.gd:223` 那一行连"写 1.0"都不发生**。
   - **覆盖上限（照实；2026-10-08 按 [`test-economy.md`](../test-economy.md) 的 D6 收紧）**：
     **T11 零守卫**（原 S11 那 10 条**全是形状**，已删）；**T10 只剩行为 9 条**（形状 12 条已删）。
     **行为**（真 PvP 局里按住加速键）没有任何自动化路径；服务端那一写"被执行到"的证明也**没有**（只有"静态链完整 + 该字段是活真相源"：
     S10 ④ 用与 `match_host.gd:223` **逐字同款**的写法改字段，三个消费点与根速度域都跟着变）。
   - **翻案条件（具体可验，二选一）**：① 立一个 **`beta_mode` + `options["time"]` 的 headless twin harness**
     （在探针里直接置这两个开关、喂 `PacketInputSource` 的 haste 位、观察三个消费点与 `match_snapshot` 的
     `haste` 位）；或 ② 给**主菜单 Beta 页那条路**加一条真链路脚本（真人/机器人从 Beta 页开局，
     断言"按住加速键 ⇒ 三个消费点变快 + 对手端看到你的加速视效"）。★ **在那之前**，这三处的行为退化
     只能靠**人工在 Beta 页开一局**复现；`task-3-report.md` §7 的那几条是**人工复现步骤**，不是"批 A 会给出的覆盖"。

24. **`TimeField.current` 是 `static` 且**从不置回 `null`** ⇒ 同进程「单机 → 回菜单 → PvP」会把单机时间场带进 PvP**（**2026-10-13 由文档执行者静态发现，未实跑**；owner 未认领）。
   - **依据**：全仓对 `TimeField.current` 只有 **1 处赋值**（[`scenes/level_0.gd`](../../../scenes/level_0.gd):225，单机 `Level0._ready` 里 `TimeField.current = time_field`）、**0 处置 `null`**；而头注（[`core/sim/time_field.gd`](../../../core/sim/time_field.gd):17）写的是"`null` = 全域恒 1"，[`scenes/level_0.gd`](../../../scenes/level_0.gd):222 的注释也写"PvP 不建 ⇒ `TimeField.current` 为 null、倍率恒 1"。
   - **可推的后果**：同进程里只要进过一次单机，`TimeField.current != null` 就永久为真 ⇒ [`scenes/player/player.gd`](../../../scenes/player/player.gd):173 走 `TimeField.player_speed_mult()` 而**不读 `pvp_haste_mult`**（该分支另有 8 处读点：[`climb_component.gd`](../../../scenes/player/climb_component.gd):108、[`swim_component.gd`](../../../scenes/player/swim_component.gd):45、[`level_0.gd`](../../../scenes/level_0.gd):410、[`enemy_base.gd`](../../../scenes/enemies/enemy_base.gd):105、[`bullet_base.gd`](../../../scenes/weapons/bullet_base.gd):63、[`enemy_bullet.gd`](../../../scenes/enemies/enemy_bullet.gd):45、[`watch_hud.gd`](../../../ui/watch_hud.gd):129、[`time_symbol_hud.gd`](../../../ui/time_symbol_hud.gd):40）。★ 与 [`swim_component.gd`](../../../scenes/player/swim_component.gd):32 那条 2026-10-03 的修（"PvP 下这条原先恒 1"）是**同一族**：那条修的是"没有单机场时怎么办"，没有处理"单机场残留"。
   - **为什么只是"可推"**：① 生产路径里"回菜单"是否**真同进程**未核（`Level0.safe_change_scene` 只换场景，不重载进程 ⇒ 静态看成立）；② 真对局里的实际表现 headless 够不到。
   - **翻案条件**：① 在 `Level0` 退出（`_exit_tree`/`safe_change_scene` 之前）把 `TimeField.current` 置回 `null` —— 一行即可，但要确认**跨场景残留是否被别处依赖**；② 或把"读哪一份倍率"从"`current != null`"改成**显式模式参数**（PvP 由 `pvp_haste_mult` 决定，单机由 `TimeField` 决定），消灭这个隐式开关。
   - 落点：口径与"未核"标注见 [`time.md`](../time.md) §2 不变量 1 的例外与 §4.2。
