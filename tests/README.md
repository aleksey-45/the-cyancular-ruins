# tests/ — 冒烟 / 诊断(无测试框架)

没有单测框架。运行命令见根 `CLAUDE.md`「常用命令」(headless + `-s`),成功以打印 `SMOKE OK` / `... OK` 且退出 0 为准。

文件分层(四个 bucket;`smoke/` 与 `probe/` 以文件名后缀为主,`harness/` 与 `scripts/` 按角色;一个 stem 的 `.gd` / `.tscn` / `.sh` / `.log` 伴随文件同桶):

- `smoke/`——行为回归主入口。`*_smoke.gd`(`extends SceneTree`,`-s` 跑)+ `*_smoke.sh`(多进程/双端编排,内部用 `taskkill` 按 PID + 杀 7777 端口兜底,别在 Windows bash 里直接 `kill`,杀不死 headless Godot)。`enemy_logic_smoke.gd` 覆盖最广(AI/LOS/环面/武器/碰撞);`grenade_smoke.gd`、`player_contract_smoke.gd`、`move_feel_smoke.gd` 等按域细分。
- `probe/`——单点诊断与真链路探针(`*_probe.gd` / `*_probe.tscn` / `*_probe.sh`,含 `kh_l*_probe`)。
- `harness/`——被 spawn 的辅助:`*_watcher.gd`(子进程观察者)、`*_bot_input.gd`(脚本机器人输入)、`*_client.*`(裸客户端,如 `pvp_smoke_client` / `net_lag_client`)、`net_lag_proxy.py`。
- `scripts/`——四个独立诊断工具:`convert_map.gd` / `convert_map_v4.gd` / `seam_analyze.gd` / `seam_screenshot.gd`。

`tests/` 顶层只留基础设施:`env.sh`(共享环境)、`lib/`(`scan_util.gd` / `probe_base.gd`,源码级探针的共享脚手架)、`path_integrity_allow.txt`(守卫的字面量常量指着它,故不随 `.gd` 搬进 `probe/`)与 `README.md`。

注意:`-s` 阶段 autoload 尚未实例化;测试脚本若静态引用会连带预加载"引用 autoload 的脚本"会在编译期失败(见 `smoke/enemy_logic_smoke.gd` 注释)。

## 聚合入口(2026-10-04 加)

两个入口:**判据一律 grep 文本,退出码从来不是判据**。

| 入口 | 跑什么 | 逐支判词 | 全批判词(纯 ASCII) | 占 7777? | 拉子进程? |
|---|---|---|---|---|---|
| `bash tests/run_all.sh` | **headless 默认批**:自动枚举 `smoke/*.gd` + `probe/*.tscn` + **`probe/*.gd`(无同名 `.tscn` 的)** | `OK` / `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `KNOWN-RED` | `RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)` | **不** | 仅 2 支拉**池外** worker(29014/29015) |
| `bash tests/run_real.sh` | **真链路批**:5 支多进程 `.sh`(见下) | 同上(除 `KNOWN-RED`) | `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(entries: ok=… fail=… ; gate-failures=…)` | **是**(3 支) | 是 |

### `run_all.sh` —— 默认批

- `--list` 打印"跑哪些 + **排除哪些 + 每条理由** + **已知红基线**";`--only <子串>` 跑便宜的子集;`--classify-check` 跑**分类器自检**(**20 例**,判据核心的回归语料)。
- ★★ **自动枚举,清单不写死**:**三个** glob —— `smoke/*.gd` + `probe/*.tscn` + **`probe/*.gd`(没有同名 `.tscn` 的,按 `-s` 跑)**。写死会让**新探针永不进默认批**而入口照样打 OK。落选一律走脚本里的 `EXCLUDED` 显式清单 + 每条理由。
  - ★ **2026-10-05 补(评审 C1)**:第三个 glob 是**补漏** —— 原先 18 支 `tests/probe/*.gd` **既不在批、也不在任何排除里**(而文件头却写着"落选一律显式")。现在:安全且有判词的 **9 支进批**,不打判词行的 **8 支**与 helper **1 支**逐支排除 + 理由;并有**机械闸**:每一支 `probe/*.gd` 必须(有同名 `.tscn`)或(进运行集)或(在 `EXCLUDED`/`OUT_OF_SCOPE` 里带理由),否则 `FATAL` 并点名。
- **判词分五类**(判据仍是**文本**;`rc` 只用来把"判词肯定"那一类再分一层):
  - `OK` = 判词肯定 **且** `rc == 0`;
  - `OK+RC` = 判词肯定 **但** `rc != 0` —— **不算红**(退出码不是判据),但**单独成类**印出来、**绝不混进 OK**。[`probe/elite_drop_probe.tscn`](probe/elite_drop_probe.tscn) 就是这一类(判词 OK,退出时 SIGSEGV ⇒ `rc=139`);
  - `FAIL` = 判词否定(含脚本自己打的 `[FAIL]`);
  - `NO-VERDICT` / `TIMEOUT` = 判词缺失 / 被外层 `timeout` 掐掉 ⇒ **归红**(它们正是"守卫自己瞎了"的形态:安全网耗尽与真失败在输出上**长得一样**)。★ 本入口把这两类**分开报**,别处常常把它们混为一谈。
  - ★★ **"判词肯定" = 三条件同时成立(2026-10-05 三轮;评审 C2 + 重审 C2 残余 + Task 6 假红)**:① **形状**:`ALL-OK`,或 `OK` **紧跟行尾/一个标点**(不许"OK 后面还有空白+正文");② **位置(2026-10-05 Task 6 改口径)**:命中行必须是**非引擎噪声行**,且它**之后不许再出现"判定形状"的行**(= 判词形状 / 失败 / **分项标记**);③ **不是分项标记**:命中行不许是方括号标签(`[OK` / `[ALL-OK`)也不许带 `✓`/`✗`。**★ "什么才算推翻判词"**(判词之后的行分三类):(a) **引擎噪声行** ⇒ **永不推翻**(噪声 = 空行 / `at: …` / `[N] …` / `GDScript backtrace` / `WARNING|ERROR|USER ERROR|USER WARNING|SCRIPT ERROR: …` / `Godot Engine v…`,清单来自 112 份真实日志的**实测尾部形状**;实测 30 份的判词后面就跟这类行);(b) **判定形状的行** ⇒ **推翻**(判词形状由"取**最后一条**命中"兜住;**失败行由 FAIL 优先兜住、而且更重** ⇒ ② 代码里真正要查的只剩**分项标记**这一支);(c) **其它良性尾行**(`notes: …`、一句说明、**未见过措辞**的引擎消息)⇒ **放行**。**为什么还留着 ①③**:只靠"独立的 `OK` 单词"时 `[squash_host] OK  6 ( … )` 这类**分项行**会顶掉判词;`PARSE[OK]: res://scenes/mp_lobby.tscn`(`lobby_parse_smoke`)与一条**以 `ALL-OK` 结尾的中文说明行**(`rewind_weapon_probe`)也会被当成判词 ⇒ "跑到一半崩、判词一行没打"读成 `OK`/`OK+RC`(不算红)。★ **射程**:判词**打出来之后**才死 ⇒ 仍是 `OK+RC`(**有意**保留 —— 那正是 `elite_drop_probe` 的形态,它只保证"判词被完整打出来了");判词形状不像 `OK`/`ALL-OK` 的支(例如 `aim_direction_probe` 打 `== PASS, …`)⇒ 落 `NO-VERDICT`(**方向安全,但会假红**)。★ **2026-10-05 Task 6 改的一处**:旧口径写"脚本在**真判词之后**再打非噪声行 ⇒ 也落 `NO-VERDICT`(**有意契约**:判词是最后一句)" —— 那句**已不成立**(它让 `haste_probe` 的 `  notes: …` 尾行把一支**健康**探针**随机**判红 ⇒ 训练人忽略 `NO-VERDICT`)。现行契约 = "**判词是最后一条『判定形状』的行**"。★ **放松的代价(照实写)**:良性尾行一律放行 ⇒ "判词**之后**才发生的真报错、既不含 `FAIL` 字样、措辞又不在 `NOISE` 清单里"不再被 `NO-VERDICT` 兜住(与 `OK+RC` 同一立场:判词一旦完整打出来,善后交给 `rc` 与日志全文);判词之后**再打判词行或分项标记**仍落 `NO-VERDICT`(方向安全:宁可假红,不把"判词不是最后一条判定行"读成绿)。★ 判据还先把 `` 剥掉(实测 28 处 `
`)。

- ★★ **已知红基线 [`tests/known_red.txt`](known_red.txt)**:每行 `路径 类别 理由…`(理由**必填**;`#` 注释;**空行 = 违规**;类别 ∈ `OK+RC|FAIL|NO-VERDICT|TIMEOUT|*`)。基线内的红 = `KNOWN-RED` ⇒ **不**进新红计数,但**永远**印出文件名与条数 ⇒ 全批判词 `RUN_ALL OK-WITH-KNOWN-RED`、**退出码 0**;**不在基线的红 ⇒ `RUN_ALL FAIL`、退出码非 0**。
  - **为什么需要**:本仓自己的话 —— [`probe/allscript_probe.gd`](probe/allscript_probe.gd) 的"一条**永远红**的闸等于没有闸"。一建起来就永远 FAIL 的入口,后面几个工作包**没法**拿它判断"我这次改坏了没有"。
  - **修好了就删行**:条目"这次跑到了、却没红" = 过期 ⇒ **也红**(与 `registered-debt.md` §三「销掉时删行」同规)。★ 配 `--only` 时只判**这一趟真跑过**的文件,所以子集跑不会误报 —— 也因此**那句"可能已修好,请删行"的提示不再出现**(2026-10-05 修;评审 I2:旧写法在 `--only` 子集跑下会教人删掉唯一那条基线 ⇒ 入口回到"永远 FAIL")。
  - **加行不是"让检查变绿"的手段**:每条都必须有真实的欠账指针与实测日期;基线**透明**(红照印)。★ 反过来,**写错也红**:路径不在候选面(第 7 种)或重复(第 8 种)。
- ★★ **入口自己会红的九种情形**(每条都答得出"去掉什么才红"):
  1. glob 空转(**枚举到 0 支**)或 `--only` 过滤后 0 支;
  2. **过期排除项**:某条规则匹配不到任何文件(= 改名漂移)。若不红,一个改名后的 `royale_probe` 会悄悄进默认批并**占 7777**;
  3. **`tests/probe/*.gd` 既没跑也没排除**(2026-10-05 加;评审 C1)。若不红,一支新的 `-s` 探针会**静默漏掉**,而入口照样绿;
  4. **默认批里出现会开端口 / 拉子进程的支**(扫 `NetBus.start_server(` / `ENetMultiplayerPeer` / `OS.create_process(`)⇒ 强制人去"显式排除(带理由)"或改探针。★ **盲区**:只看**整行注释以外**的文本,且**看不见经 helper 间接开端口**(如 `WorkerLauncher.spawn_worker`)—— 今天批里那 2 支正是这种形状(池外,已知无害,不会响);
  5. 某支 `FAIL` / `NO-VERDICT` / `TIMEOUT` **且不在基线里**;
  6. 基线条目**过期**(跑到了却没红);
  7. 基线里有一条**路径根本不在候选面**(不存在 / 已改名)—— 2026-10-05 加(评审 I1):若不红,那条基线就是**永久死行**,登记簿开始说谎;
  8. 基线文件里有**空行 / 缺理由 / 类别不合法**,或**同一路径重复**(重复行原先被关联数组**静默折叠**,2026-10-05 修;评审 M5);
  9. 某个 `EXPECTED_CHECKS` **声明了却没被用于比较**(M1)⇒ 该支 `GATE` 栏打 `-(declared,unused:N)`,且**不计入** `m`(否则 `m` 虚高而 `GATE` 栏读起来像"有闸盯着")。
- ★★ **单支 `OK` 只证明"没有失败输出",不证明"每条断言都跑过"**(脚本错误只结束出错的那个函数、调用方继续、verdict 照打 `ALL-OK`;权威:[`lib/probe_base.gd`](lib/probe_base.gd) 文件头)。表里 `GATE` 栏是 `-` 就表示"**这一支没有闸**"(或 `-(declared,unused:N)` = 声明了没用)。全批判词里的 `m` **只统计带闸的支**(= 各支 `EXPECTED_CHECKS` 之和),**不是**全批断言总数。
- **`OK+RC` 的由来(实测)**:[`probe/elite_drop_probe.tscn`](probe/elite_drop_probe.tscn) 同配置 7/7 次都是"**先打判词 OK、再在退出时 SIGSEGV**" ⇒ 只看文本它是**绿的**。这就是"守卫给的保证比读起来少"的活样本,登记在 [`../docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) §一。
- **日志与判词原文** —— ★★ **ASCII 的射程(2026-10-05 订正,评审 I3:别两处都说满)**:
  - **机器可读的那部分 = 全批判词行(`RUN_ALL ...` / `RUN_REAL ...`)与逐支表那一栏 ⇒ 纯 ASCII**(本机控制台是 GBK:中文 / `⇒` / `✓` 会把脚本打崩;判词行原先掺中文 ⇒ 在缺省控制台上是乱码,现在不是了);
  - **给人读的那部分 = `[env]`/`[enum]`/`[baseline]`/`[known-red]`/`[new-red]`/`[ok+rc]` 说明行与 `--list` 的排除理由 ⇒ 原样打印(含中文)**,不过 `ascii_only`(剥掉中文只会让理由变成残渣);
  - **判词原文**(含中文)在 `tests/.run_all_logs/summary.log` 与每支的 `tests/.run_all_logs/smoke/<名>.log` / `tests/.run_all_logs/probe/<名>.log`;失败清单一并在 `tests/.run_all_logs/failed.log`。★ 这些 `*.log` 被根 `.gitignore` 的 `*.log` 覆盖,**不会脏工作树**;
  - ★ **它们跨跑次混装**:同一路径会被下一趟覆盖 ⇒ 你读到的**不一定是这一趟的**(没有 run id / 时间戳 —— 这是**已知边界**,不是保证)。
- 逐支墙钟预算:smoke 60s / scene 120s,文件头自己声明过更大 `timeout` 的走脚本里的 `BUDGET_OVERRIDE`。★ 预算给**小**了是**可见的 `TIMEOUT`**(不会静默变绿)。

**不在默认批里的,以及为什么**(全量清单与理由:`bash tests/run_all.sh --list`):

1. **非 headless 取图 / 真渲染(10 支)** —— 会弹窗抢焦点,硬规定 agent 不许自跑:`combat_hud_visual_probe` / `hue_tint_probe` / `kh_l3_visual_probe` / `kh_l4_visual_probe` / `kh_visual_probe` / `match_result_probe` / `menu_shot_probe` / `minimap_circle_probe` / `render_forensics` / `squash_stretch_probe`。
2. **真链路 / 多进程(8 支探针 + 1 支 smoke)** —— 会占 7777 或拉子进程(⇒ 走 `run_real.sh`):`ground_net_probe` / `reconnect_probe` / `rejoin_probe` / `royale_bound_probe` / `royale_c2_probe` / `royale_probe` / `royale_soak_probe` / `team_match_probe`,以及 `smoke/pvp_match_smoke.gd`(要 `--role`,且要 7777 上有大厅)。
3. **登记在册的仪器(1 支)**:`brawl_rollback_probe` —— [`../docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) §一第 3 行(读 `N≥4` 时自身在抖,变异下**仍有一格假绿**),且 [`../docs/eng/tests.md`](../docs/eng/tests.md) 明写"**本批不跑**;真要跑得给 `--quit-after 30000`"(约 8 分钟,而它的失败形状是"**无裁决行 + exit 0**")。
4. **形状不合口径(1 支)**:`smoke/menu_autotest.gd`(`extends Node` 但**没有同名 `.tscn`**;它不是独立入口 —— 由 [`../scenes/main_menu.gd`](../scenes/main_menu.gd) 按 `-- --autotest-*` 挂到树根)。
5. **`tests/probe/*.gd` 里没有同名 `.tscn`、又不进批的(9 支)**(2026-10-05 加;评审 C1):
   - **8 支诊断仪器,共同理由 = 现判据读不了它们的判词**(2026-10-05 修复轮3 写准;两种形态别混为一谈):① **没有判词行**(逐支核过它的 `print` 里没有 `OK`/`PASS`/`DONE` 形状的判词):`aim_probe` / `climb_probe`(T14 的读数修复对象,判据是人读 `latched=`) / `muzzle_probe` / `order_probe` / `perf_probe`(★ 只有 `[perf] DONE` + 中文 通过/失败 行;口径已与生产分家,见 §五.3) / `preview_probe` / `tile_destroy_probe`;② **有判词行、但词汇不是 `OK`/`ALL-OK`**:`aim_direction_probe` 打 `== PASS, failures=0` ⇒ 绿跑落 `NO-VERDICT`(**假红**),而它**失败**时打 `== FAIL, …`(那个词汇现判据**认** ⇒ 会被判红)⇒ 它的危险是**假红**,**不是**"红的被藏起来"。⇒ 想让它们进批:① 类**先加判词行**;② 类**先把判词换成 `OK` 形状**。**它们从来不是守卫**(与 `registered-debt.md` §一 那三条"不算守卫"的探针同类)。
   - **1 支是 helper 不是入口**:`haste_probe_input.gd`(`extends PlayerInput`,被 `haste_probe.gd` `preload()` 当输入桩;那个 `haste_probe.tscn` 已在批里)。
   - ★ **另有 9 支同类探针已进批**(它们有判词行):`explosion_falloff_probe` / `map_catalog_probe` / `map_format_v4_probe` / `path_integrity_probe` / `settings_esc_probe` / `subcell_probe` / `water_probe` / `weapon_injected_fire_probe`(★ `EXPECTED_CHECKS := 158`,进批后计入 `m`)/ `wrap_probe` —— 这是它们**第一次真的被跑**。
6. **不在 glob 直径内的工具(4 支,`tests/scripts/*.gd`)** —— 它们是**迁移 / 诊断工具,不是测试**:`convert_map.gd` 与 `convert_map_v4.gd` **原地写盘**(★ `convert_map.gd` 今天跑**会毁图**:两张在库图已是 v4 二进制,它认不出 v2/v3 标记 ⇒ 落进"v1 单字符 250×150"那一支并覆盖写回;债单 §六.19);`seam_analyze.gd` 读的 `tests/_seam_a_old.png` / `_seam_b_fixed.png` **不在库里**(债单 §六.20);`seam_screenshot.gd` **非 headless**。★ 所以**没有**把 `tests/scripts/*.gd` 加进 glob —— 那等于让以后任何一个新工具脚本(可能原地写盘)**自动进回归批**。

### `run_real.sh` —— 真链路批

顺序 / 端口 / 耗时估计 / 判词(**表格**,命令 `bash tests/run_real.sh --list` 现打):

| # | 脚本 | 端口 | 耗时估计 | 判词 | 池内回收 |
|---|---|---|---|---|---|
| 1 | `smoke/pvp_match_smoke.sh` | 7777 + pool | ~20s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 2 | `smoke/pvp_room_smoke.sh` | 7777 + pool | ~40s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 3 | `probe/rejoin_probe.sh` | 29300 / 29350(**池外**) | 60~110s | `REJOIN PROBE: ALL-OK` | **不扫池** |
| 4 | `probe/royale_soak_probe.sh` | 7777 + pool | ~150~200s | `SOAK: ALL-OK` | 扫 `[7800,8300)` |
| 5 | `probe/team_match_probe.sh` | 29200 / 29250(**池外**) | 3~10min | `TEAM MATCH PROBE: ALL-OK` | **不扫池** |

- ★ **`tests/smoke/*.sh` 里另外 5 支不进真链路批**:`bullet_tile_fx` / `move_feel` / `pvp_reconcile` / `pvp_twin` / `room_sweep` 都只是"**一条 Godot + tee**"的单进程包装,同一个 `.gd` / `.tscn` **已在默认批里**(重复计费没有收益)。理由逐条写在脚本的 `WRAPPERS` 里。
- ★★ **四道闸**:① `lobby_alive` 为真 ⇒ **拒绝**(大厅 `_ready` 会 `kill_udp_port(7777)`,硬跑会端掉用户正在跑的对局);② 无 `--yes` 且 stdin 非交互 ⇒ **拒绝**并提示手动跑;③ **R20 锁 + 前后进程**:见下;④ **清单不许烂**:`tests/{smoke,probe}/*.sh` 每一支必须出现在 `ENTRIES`(跑)或 `WRAPPERS`(不跑 + 理由)里,且两边每条都要匹配到真实文件 —— 否则红(去掉它,新加的真链路 `.sh` 会**静默不进批**)。
- ★★ **闸③的由来是一次真事故,以及 R20 锁(2026-10-05 加)**:
  - **事故**:曾经在 `run_all.sh` 跑批期间调用 `run_real.sh --yes`,那一刻"`tasklist` 单点采样"恰好落在两个 headless 测试之间的空档 ⇒ 计数 0 ⇒ 放行 ⇒ **真链路脚本真的跑了起来**(短暂占了 7777;它自己 FAIL 早退,早退路径还复现了 `registered-debt.md` §五.9 的"漏杀孙进程")。
  - **R20 锁(主判据)**:`run_all.sh` 运行期持 `tests/.run_all.lock`(内容 `pid` / `start` / `heartbeat`,每支一刷心跳,正常结束或 Ctrl-C 都删);`run_real.sh` 见**活锁**即拒并打印锁里的 pid/起始/心跳。★ **判据按实现写清**(2026-10-05 订正 —— 原先 README 与脚本注释把判据说反了):**活锁 = `pid` 还活着 **且** 心跳在 `LOCK_STALE_SECS`(默认 600s)之内**;两者**任一**不成立 ⇒ **陈旧锁** ⇒ **打醒目警告后放行**(否则就成了"永远拒绝的闸"那一面)。⇒ 真正要盯的是**心跳那条**:它只在**支间**刷新 ⇒ "单支挂住"期间心跳会变旧(而单支最长预算 150s,仍 < 600s)。★ **刷新点与阈值是一对**:谁把单支预算调到 >600s(`BUDGET_OVERRIDE` / `SCENE_BUDGET`),就必须同时调 `LOCK_STALE_SECS`。
  - **副保险两条**:①`tests/.run_all_logs/summary.log` 在 `RUN_REAL_QUIET_SECS`(默认 **240s** > 单支最长预算 150s)内被写过 ⇒ 拒;②`tasklist` 连续 `GODOT_QUIET_SAMPLES`(=3)次采样为空才放行;跑前/每支跑完都判,判空带最多 ~10s 收尾等待(免得把"刚杀掉还在回收"误判成残留)。
  - ★ **覆盖上限**:副保险①的阈值**必然**小于"一支真的挂住"的最坏情形(挂住时长无上界)⇒ 它只是兜底;**锁才是"在飞"的判据**。锁本身也**挡不住**"有人手工绕过脚本直接跑 `.sh`"。
- ★ `team_match_probe.sh` 在 [`../docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) §一第 1 行**仍登记为不可信**:根因已修(`9003dae`),但**修复后没有留下六人整跑的判决**。⇒ 它绿了**也不改变**"3v3 今天没有可信端到端守卫"这句。

### ★★ 默认批绿 ≠ 真链路绿(两条链路覆盖**不相交**)

前者是纯逻辑 + in-process 场景(`-s` / 单进程 `.tscn`);后者要真端口、真子进程、真对局协议。改到**联机权威 / 协议 / 回滚 / 输入包**的改动必须**两边都看**,不能拿一边的绿代替另一边。同理:**默认批绿**也不代表非 headless 的取图验收通过(那 10 支**从不**进默认批)。

