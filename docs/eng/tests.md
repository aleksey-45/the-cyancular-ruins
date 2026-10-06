# 测试与守卫

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:测试 · ★★ 守卫/期望能给的保证总是比它读起来少。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 测试

**源码级探针的共享脚手架 = `tests/lib/`**:`scan_util.gd`(`class_name ScanUtil`,纯静态:读文件/走目录/剥注释视图/括号与实参切分/取函数体,**无 Node 依赖**)与 `probe_base.gd`(`class_name ProbeBase extends Node`:断言账本 `_failures` + `_check`/`_summary`/`_finish` + 一层转发到 ScanUtil 的扫描词汇)。`kh_l{1,3,4,5,6}_probe` 全部 `extends ProbeBase` 并覆写 `probe_id()`(如 "L5")—— 末行 `KH <id> PROBE: ALL-OK` 就是由它拼的。★ **加新源码级探针时别再从别处抄扫描函数**:`extends ProbeBase` 即可。★ 另注意 `tests/lib/` **本身会被 kh_l4/kh_l5 的字号规范扫描覆盖**,故新加的 lib 源码里不许出现非 16 倍数的字号载体字面量。

无单测框架。`tests/*.gd` 是 `extends SceneTree` 的冒烟/诊断脚本,用 `-s` 跑:`enemy_logic_smoke.gd` 为主(敌人 AI、环面数学、武器参数/命中、碰撞层、寻路/LOS、多弹丸),其余 seam_analyze/seam_screenshot/wrap_probe 是环面接缝诊断。★ **两种跑法,按脚本首行区分**:`extends SceneTree` → `-s res://tests/<名>.gd`(autoload 不存在);`extends Node` → `--quit-after <帧数> res://tests/<名>.tscn`(`--quit-after` 的单位是**帧**不是秒;它是安全网——脚本解析失败时场景根没脚本、一行不打印且不退出)。L1~L5 的层验收探针 `kh_l1/l3/l4/l5_probe.tscn` 都是场景模式,**判据必须是 grep 文本 `ALL-OK`**。

- ★★ **"grep 到 ALL-OK"只证明「没有任何断言失败」,不证明「每条断言都跑过」**(**完整表述与三层实测在 `tests/lib/probe_base.gd` 的文件头,那里是这条纪律的权威落点**):脚本错误只让**出错的那个函数当场结束、调用方继续** ⇒ 后面那些断言被**静默跳过**,而 verdict **照打 `ALL-OK`**;更尖的一层是 `ProbeBase._summary` 在**没有新增失败**时打 ✓,所以**整组一条都没跑**时那个 ✓ 汇总行**也会打**。★ **退出码从来不是判据**(出错时照样 exit 0)。★ 两个新场景探针用 `_checks >= EXPECTED_CHECKS` 堵同一件事。
- ★ **`-s` 冒烟必须写空载守卫**:`_initialize()` 里一旦抛错就走不到 `quit()`,进程**永久挂起**(不是干净失败,是超时)—— `load()` 之后立刻 `if X == null: print(...); quit(1); return`,且跑新冒烟**一律套 `timeout`**。★ 同理,查"某常量在不在"用 `get_script_constant_map()` 而不是直接取属性(取不存在的属性会抛错 → 挂起)。
- ★ **场景探针的 `--quit-after` 是安全网,给足(统一 3600 帧)** —— 探针跑完会自己 `quit()`,这个值**只在探针挂住时**才用得上,放宽**不花任何代价**;给少了会在机器负载重时**先耗尽**,表现为"一行 ALL-OK 都没有"、看着像功能坏了。★ 但**别拿"批量里红、单跑绿"断定就是超时** —— 安全网耗尽与探针真失败在输出上**长得一样**,要先按真失败查一遍。
- **主要探针(按主题)**:
  - 武器/背包:`laser_weapon_smoke.gd`、`weapon_inventory_smoke.gd`、`ground_weapon_field_smoke.gd`、`sprite_bounds_smoke.gd`;场景探针 `weapon_pickup_probe.tscn` / `level0_weapon_scatter_probe.tscn` / `menu_weapon_grid_probe.tscn`。★ 地面武器那两个探针的存在理由:改动里有两个 bug **所有数值断言都是绿的** —— 挂错父节点(在渲染树外)与热重建视觉被顶掉名字,只有取图人眼确认 + "挂在谁下面"这类断言才抓得到。
  - 敌人/环面:`enemy_logic_smoke.gd`(含 `_phase_collision_aabb` / `_phase_weapon_registry`)、`spawn_pool_smoke.gd`(★ 含 ⑥ **源码级**断言两个宿主真接了 `respawn_pools()` + royale 的**转发函数 `_respawn_pools` 本身**(只钉 `_spawn_cell` 会**差一跳**)+ ⑦ 补足分支可达性守卫)。
  - C2/回滚:`replica_ghost_probe.tscn`(负向对照把幽灵体层清零;⑤ `touching_player()` **命中过**、⑥ **摘掉幽灵体后全程不得命中** —— 后者同时钉住"**地形不算接触**")、`rollback_fidelity_probe.tscn`、`brawl_rollback_probe.tscn`(贴身缠斗**扫描仪器**;★ 照实登记:它读 N≥4 时本身在抖,变异下**仍有一格假绿**)。
  - 联机:`pvp_twin_smoke.sh`、`reconnect_probe.tscn`、`grace_window_smoke.gd`、`reconnect_smoke.gd`(源码级:三条 RPC 的**节点归属双向**断言 + `@rpc` 注解逐字)、`rpc_liveness_probe.tscn`、`net_ground_probe`、`ground_client_probe`、`ground_action_probe`、`resync_world_probe.tscn`、`match_sync_probe.tscn`、`match_host_hygiene_probe.tscn`(服务器侧记账卫生:`_seen_bullets` 每帧按在场子弹剪枝)、`grenade_player_hit_probe.tscn`、`late_match_probe.tscn`、`duel_spawn_timeout_smoke.gd`、`rejoin_*`。
  - 3v3:`team_room_smoke.gd`(⑥⑦⑧⑨ 源码级接线 + ⑩ 像素级 `BODY_BASE_COLOR` 众数)、`team_host_probe.tscn` / `team_table_probe.tscn` / `team_disconnect_probe.tscn`(都**真建宿主但 `role_peers` 传空**)、`team_spawn_smoke.gd`、`team_match_probe.tscn`(+`.sh`,**六人真链路**)。
  - 大乱斗:`royale_probe.tscn`(**跑前先确认 7777 空闲**)、`royale_bound_probe.tscn`(B1 role 空洞 / B2 开局三载荷跨场景;★ B2 曾长期登记为「客户端**收不到** `match_sync` 应答」—— **2026-10-03 定案为探针等待窗口太短**:载荷没丢、只是**晚到 2.5~5.9s**(换场那一下客户端要建整个 `royale_game` ⇒ 主循环卡住 ~8s ⇒ UDP 收缓冲溢出 ⇒ **可靠包靠 ENet 退避重传**,客户端一恢复就整批涌进;旁证:同一瞬间 `round_state` 计数 9→20,而 `world/own` 是平滑的。前一轮"9 次请求 0 次收到"的读数是**那一跑主进程在 ~10s 被杀**,观测窗太短。⇒ 等待形状已从固定 `SETTLE=2.0` 改成**等载荷 + 截止线**;`royale_bound_watcher._log` 另加了**墙钟戳**,因为 `_t` 是 delta 累加、Godot 会钳超长帧 ⇒ 卡顿期它**严重低报**)、`royale_c2_probe.tscn`(**C2 真链路**,用「按 K 自杀 → 2s 复活瞬移」造分歧)、`royale_soak_probe.tscn`(压力;**答不了渲染卡顿**,且 worker 子进程 stdout 不继承到管道 → worker 侧打印是盲区)、`royale_disconnect_count_probe.tscn`(★ `_ready` 里要 `_host.set_physics_process(false)`)、`royale_hud_cost_probe.tscn`。
  - UI/视觉:`combat_hud_visual_probe.tscn`(★ **必须真实渲染**;**底故意铺地图开阔区的浅灰蓝**而不是深色 —— 垫深底取图会把「浅底上读不出来」整类问题遮掉;★★ `_bright_in` 判据换过:旧实现的**绝对**阈值与底板合成均值只差 0.0046 ⇒ **判据整个空转**;现在基准**从图里量**)、`kh_l3_visual_probe.gd`(按**语义**断言三种颜色,都是**双向**的)、`hue_tint_probe.tscn`(★ **必须真渲染**;headless 下截图链给 null ⇒ **FAIL 并 return**,是**失败**不是静默早退)、`minimap_circle_probe.tscn`、`match_result_probe.tscn`、`pvp_hud_layout_probe.tscn`、`hud_declarative_probe.tscn`、`ui_palette_single_source_smoke.gd`、`squash_*`。
  - 其他:`unstick_smoke.gd`、`explosion_falloff_probe`、`score_rules_smoke.gd`、`stats_delivery_probe.tscn`、`match_result_payload_smoke.gd`、`ammo_rollback_probe.tscn`、`death_drop_probe.tscn`、`room_sweep_smoke.gd`、`lobby_visibility_probe.tscn`、`kh_l5_probe.gd`(源码级机械扫描:含**反向断言:基类不得含子类方法**)。
- **★ 真链路跑批的两条纪律**:
  - ★★ **两支真链路测试之间必须确认 `tasklist | grep -i godot` 为空。** worker 由大厅 `OS.create_process` 拉起,是**孙进程** —— 不在任何脚本记下的 PID 里;而下一支新大厅的端口分配集合是**进程内内存** ⇒ **再次选中同一端口** ⇒ 新 worker 报 `监听失败 20` ⇒ 客户端连到的是**上一支的僵尸 worker** ⇒ 整支**挂到外层 timeout、一行裁决都不打**(与真失败**长得一样**)。★ 前台 `timeout` 掐掉某支脚本时,它收尾那段**不会跑** ⇒ 必留孤儿 ⇒ **下一支**被毒。守卫 = `tests/env.sh` 的 **`kill_port_range LO HI`**。★★ `rejoin_probe` / `team_match_probe` **绝不能**扫 `[7800,8300)`(那会端掉用户正在跑的对局)。
  - ★ **`lobby_alive` 原先那版判据是结构性恒假(已修)**:`netstat … grep -E "[:.]7777[[:space:]].*LISTENING"` —— 而 **ENet 走 UDP、UDP 行没有状态列** ⇒ `.*LISTENING` **永不命中**。现收在 `tests/env.sh` 的 `lobby_alive()`。
- **⚠ 两条既有红(已登记,未修)**:
  - ❌ **`tests/probe/team_match_probe.sh` 是既有的 FAIL,且判词与实况矛盾**(判词说"大厅队伍表是空的""45s 内没有 3v3 房",而**同一跑的客户端日志**里房建成了、客户端进了等待室)。★ **A/B 已证**与任何一批改动无关。**影响**:这是**唯一**「过真协议」的 3v3 覆盖,而它红着 ⇒ 3v3 真链路目前**没有**可信的端到端守卫。★ 追查已做到可交接处(根因未钉死):探针是 29200 的唯一监听者、`LobbyRooms` 在位,但 6 个客户端**连上后全部断开**、探针那条信号 **一次都没触发** ⇒ **客户端被某个不是探针大厅的东西服务着**。未证假设与下一步见报告 §4.1b。
  - ⚠ **`tests/probe/ground_net_probe.tscn` 是既有的抖动**(机器人走位在随机图上卡死,探针自己的头注也写了这一点)。
- **★ B 档「登记边界」批(2026-09-28)的判据 + 回归清单**(判据一律是**文本**,不看退出码):
  - **`tests/probe/late_match_probe.tscn`**(`timeout 180 … --quit-after 3600`)→ 文本 `LATE MATCH PROBE: ALL-OK`。钉四项:① `_left_round` 分母的**读取端**;② MATCH_OVER 之后倒地**不**进 `_stats`(**含一条 ROUND_OVER 相**);③ `note_disconnect_round` 的**写入端**(经**真** `_enter_grace`);④ 大乱斗 `_match_winner` 的并列候选集(配 ⑤ 与 ⑤b;★ **⑤ 是必需的**反向对照)。★★ **覆盖上限(登记,不补相)**:④ 是**唯一**走到"只身幸存"的相 ⇒ 一个假想的退化实现能**全过**。★★ **另一处照实未钉**:MATCH_OVER 侧 ③ 的掉落与 ④ 的 `_reset_survivor` **没有断言**。
  - **`tests/smoke/duel_spawn_timeout_smoke.gd`**(`-s`,**真拉起一个独立 worker 进程**)→ 文本 `DUEL SPAWN TIMEOUT SMOKE: ALL-OK`。★ 三条纪律(与 `team_spawn_smoke` 同款):端口固定 **29015**(必须在真大厅 worker 端口池之外)/ **跑前先删日志**(否则上一次的"报到超时"行会把本跑**喂绿**)/ 断言要 `就绪` **与** `报到超时` **两条**行都在(少了前者,一个"开机即崩"的 worker 也会让后者失败,失败原因完全指错方向)。★ 它另有一层**源码级 belt**,判的是**语义不变量**(口径见该文件头),故标志改名 / 合取项重排 / 抽成一层 helper 都**不会**假绿。★ 三条已知上限 + "**承重的是 ③ 而不是 ①②**"见 §对局中的房。**别当它是证明** —— 真正的证明是那次**人工跑满 45 秒的真大厅**。
  - **★ 本批回归清单**:`ammo_rollback_probe` / `late_match_probe` / `death_drop_probe` / `team_host_probe` / `room_sweep_smoke` / `kh_l5_probe` / `rpc_liveness_probe` / `duel_spawn_timeout_smoke` / `royale_disconnect_count_probe`,加 **一次真大厅跑满 45 秒**。★ `brawl_rollback_probe` **本批不跑**;**真要跑得给 `--quit-after 30000`** —— 仓库统一的 **3600 对它不够**,而它的失败形状是"**无裁决行 + exit 0**"。
  - **★ 真大厅那一步的判据与护栏**(唯一会占 **7777** 的回归步):**`lobby_alive` 为真时必须跳过**(大厅的 `_ready` 会 `kill_udp_port(7777)`)。为假时跑 `timeout 45 … server_main.tscn`:**正确** = **EXIT=124** 且输出里**没有**「报到超时」行;**有病** = 自己 ~30s 退出(**EXIT=0**)且打了那一行。★★ **两者都要看**:只看退出码会被管道骗(`| tail` 报的是 `tail` 的退出码、**恒 0**);只看文本则分不出"被掐掉"与"提前退出" —— 本仓纪律是**判据一律 grep 文本**,要取退出码就**别接管道**。
- **★ `.uid` 入库口径**:本仓**跟踪** `*.gd.uid`、`.gitignore` 未屏蔽;而 **`*.tscn.uid` 零跟踪** ⇒ **新建 `.gd` 要跟它的 `.uid`,新建 `.tscn` 不用**。★ 成因:实现者都按名 `git add <具体文件>`,会**漏掉姐妹文件** ⇒ **给 `git add` 命令时,新建 `.gd` 的场合要显式带上 `.uid`**。

#### ★★ 守卫/期望能给的保证总是比它读起来少

共性:① 判据落在**文本/计数**上而意图是**语义/行为**;② 覆盖声明**写在注释里、没人验**;③ 发现它们的**几乎全是审阅者,不是实现者**。典型形态:

- ★★ **peer 给出的最准成因表述**:**「探针把夹具的写入当成了被测行为的一部分,于是被测的那一半从来没被验过。」** ⇒ 通用检查法:**逐条问"这一相里,有多少输入是我自己喂的、有多少是从生产来的"** —— 喂进去的那部分,无论多像,都**不构成对该路径的验证**。
- ★★ **「过期的注释会被改对,而"职责被张冠李戴"会让下一个删它的人以为自己论证过了。」**
- ★★ **算术教训**:**「把条件写成 `== A`」与「写成 `!= B`」的差集是 `B \ A`,不是"`A` 之外的全部"。** ⇒ 说"某个变体会被 X 守住"之前,先把它在**每个状态下的真值**列出来。
- ★ **加新守卫时逐条照做**:每条新守卫都要在**它自己的注释里**回答"**它能给的最强保证是什么、它测不到什么**";凡写"某变异会被 X 守住",**先把该变异在每个状态下的真值列出来**;凡写死一个**可数**的期望值,**写清它是怎么数出来的**。








