# 测试与守卫

> 判据一律 **grep 文本**(`SMOKE OK` / `ALL-OK` / `RUN_ALL ...`);**退出码不是判据**。
> 现行清单只有两个自动来源:`bash tests/run_all.sh --list` 与 [`tests/README.md`](../../tests/README.md) —— 别抄任何枚举,它会漂。冲突以源码为准。

## 桶划分

判据是「跑它要什么资源」,不是「测多少代码」。

| 桶 | 资源边界 | 形态 | 跑法 |
|---|---|---|---|
| **冒烟** | 单进程;被测代码与测试同进程;不碰网络 / 磁盘 / 真场景实例;**autoload 未实例化** | `tests/smoke/*.gd`(`extends SceneTree`) | `-s` |
| **场景探针** | 单机、真场景树:真实例化 `.tscn`,走 `_ready` / 信号 / 资源加载 / 渲染 | `tests/probe/*.tscn` | `--quit-after 3600` |
| **真链路** | 跨进程 + 真端口 + 真协议:起大厅 / worker / 客户端子进程 | `tests/{smoke,probe}/*.sh` | `bash tests/run_real.sh` |

- 永远选能证明它的**最小**一档。桶选大了更慢、更脆、更难定位。
- 手感 / 观感 / 配色 / 版式**不是守卫缺口**:这类没有自动化判据,只能人眼与试玩。

## 单支跑法

`extends SceneTree` ⇒ `-s`;`extends Node` ⇒ `--quit-after <帧数>` 加 `.tscn`。引擎路径来自 [`tests/env.sh`](../../tests/env.sh) 的 `$GODOT`。

```bash
"$GODOT" --headless --path . -s res://tests/smoke/<名>.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/<名>.tscn
bash tests/smoke/<名>.sh
```

- `--quit-after` 的单位是**帧**,统一给 **3600**。它是安全网:探针跑完会自己 `quit()`,给少了会在负载重时先耗尽。
- 判据是 grep 到判词;**不要**接管道取 `rc`(`| tail` 报的是 `tail` 的退出码)。

## 默认批:`bash tests/run_all.sh`

- **自动枚举**三个 glob:`tests/smoke/*.gd` + `tests/probe/*.tscn` + `tests/probe/*.gd`(无同名 `.tscn` 的按 `-s` 跑)。清单不写死;落选走 `EXCLUDED` 显式清单 + 每条理由,规则匹配不到文件即红。
- 不碰 7777、不拉子进程、不弹窗。默认批里出现开端口 / 拉子进程的支 = 红。
- 选项:`--list`(跑哪些 + 排除哪些 + 每条理由 + 已知红基线)· `--only <子串>` · `--classify-check`(分类器自检)。
- 逐支判词:`OK`(判词肯定且 `rc == 0`)· `OK+RC`(判词肯定但 `rc != 0`,**不算红**,单列)· `FAIL` · `NO-VERDICT` · `TIMEOUT`。后两类**归红**。
- 全批判词(**纯 ASCII**):
  - `RUN_ALL OK(n runs / m gated-assertions)`
  - `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)`
  - `RUN_ALL FAIL(r new-red + k registered)`
- 退出码:有新红 ⇒ 非 0;只有已登记红 ⇒ 0。
- `m` = 带条数闸的那些支的闸值之和,**不是**全批断言总数。
- **`GATE` 栏** = 该支 `_checks` 条数闸的值;`-` 表示这一支**没有闸**。声明了 `EXPECTED_CHECKS` 却没拿它比较 ⇒ 栏内 `-(declared,unused:N)`,不计入 `m`。
- 说明行(`[env]` / `[enum]` / `[baseline]` / `[known-red]` / `[new-red]` / `[ok+rc]` 与 `--list` 的排除理由)不过 ASCII 过滤,原样含中文。
- 日志:`tests/.run_all_logs/` 下每支全文 + `summary.log`;跨跑次混装,同一路径会被下一趟覆盖。
- 入口自己会红的九种情形:glob 空转 / 过期排除项 / `probe/*.gd` 既没跑也没排除 / 默认批出现开端口或拉子进程的支 / 新红 / 基线条目过期 / 基线路径不在候选面 / 基线文件写错 / 声明了 `EXPECTED_CHECKS` 却没用于比较。

## 条数闸 `EXPECTED_CHECKS`

- 单支 `OK` 只证明「没有任何断言失败」,**不证明每条断言都跑过**:脚本错误只结束出错的那个函数、调用方继续,verdict 照打 `ALL-OK`;`ProbeBase._summary` 在整组一条都没跑时也会打 ✓。权威表述在 [`tests/lib/probe_base.gd`](../../tests/lib/probe_base.gd) 文件头。
- **新写的场景探针必须带闸**:同文件 `const EXPECTED_CHECKS := N`,并在收尾拿它比较(`_checks >= EXPECTED_CHECKS` 或 `!=`)。只声明不比较 = 没有闸。
- 存量不追补。

## 已知红基线:`tests/known_red.txt`

- 每行 `路径 类别 理由`。路径必须与枚举出来的那一支**逐字相同**;类别 ∈ `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `*`;理由**必填**;`#` 开头是注释;**空行 = 违规**。
- 基线内的红 = `KNOWN-RED`:不进新红计数,但**永远**印出文件名与条数;全批判词转 `OK-WITH-KNOWN-RED`、退出码 0。
- 不在基线里的红 ⇒ `RUN_ALL FAIL`、退出码非 0。
- **修好就删行**:条目"这趟跑到了却没红" = 过期 ⇒ 也红。路径不在候选面、同一路径出现两次 ⇒ 也红。
- 基线当前 **0 条**。

## 跑批纪律

- `-s` 冒烟必须写空载守卫:`load()` 之后立刻 `if X == null: print(...); quit(1); return`;否则 `_initialize()` 一抛错就走不到 `quit()`,进程**永久挂起**。跑新冒烟套外层 `timeout`。
- 查"某常量在不在"用 `get_script_constant_map()`,不要直接取属性 —— 取不存在的属性会抛错 → 挂起。
- 别拿"批量里红、单跑绿"断定是超时:安全网耗尽与探针真失败在输出上长得一样,先按真失败查。
- 占 7777 的步骤先查 `lobby_alive` —— 大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局。
- 两支真链路测试之间 `tasklist | grep -i godot` 必须为空:worker 是**孙进程**,孤儿会占住端口、毒害下一支。
- 池外 `rejoin_probe.sh`(29300/29350)与 `team_match_probe.sh`(29200/29250)**一律不扫** `[7800,8300)`;其余支扫之前必须先过 `lobby_alive`。

## 真链路批:`bash tests/run_real.sh`

- 用法:`bash tests/run_real.sh`(打印清单 / 端口 / 耗时估计后交互确认)· `--yes`(无确认,仍过全部闸)· `--list` · `--only <子串>`。
- 清单 = [`tests/run_real.sh`](../../tests/run_real.sh) 的 `ENTRIES`(`path|端口|耗时估计|判词|回收范围`);同目录里不进批的 `.sh` 走 `WRAPPERS`。
- 四道闸:① `lobby_alive` 为真 ⇒ 拒;② 无 `--yes` 且 stdin 非交互 ⇒ 拒;③ **R20 锁**(`tests/.run_all.lock`:pid 活 **且** 心跳在 `LOCK_STALE_SECS` = 600s 内才算活锁)+ 跑前跑后 `tasklist` 无 Godot;④ **清单不许烂**(`tests/{smoke,probe}/*.sh` 每支必须在 `ENTRIES` 或 `WRAPPERS` 里,两边每条都要匹配到真实文件)。
- 心跳只在**支间**刷新 ⇒ 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- 全批判词 `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(...)`,纯 ASCII;判词原文与各支日志在 `tests/.run_real_logs/`。
- **默认批绿 ≠ 真链路绿**:两条链路覆盖不相交。改联机权威 / 协议 / 回滚 / 输入包,两边都要看。
- `team_match_probe.sh` 整跑仍判 `FAIL`,不可当 3v3 的端到端守卫(见 [`registered-debt.md`](registered-debt.md))。

## 守卫能给的保证总是比它读起来少

- 逐条问"这一相里有多少输入是我自己喂的、有多少来自生产" —— 喂进去的那部分不构成对该路径的验证。
- 加新守卫时在它自己的注释里写清:「它能给的最强保证是什么」「它测不到什么」。
- 凡写"某变异会被 X 守住",先把该变异在**每个状态下的真值**列出来;凡写死一个可数的期望值,写清它是怎么数出来的。
- 变异判据要含"**红的原因对不对**":每个变异前确认已复原上一个;红时按**预期的断言名**核,报告记"红在哪条断言",不记"红了"。

## 结构化诊断(`--diag`)

实现:[`core/net/net_diag.gd`](../../core/net/net_diag.gd)(`class_name NetDiag`,静态、无 autoload)。

- **开关**:① 客户端命令行 `-- --diag` —— 必须写在 `--` 之后,写在前面会被 Godot 丢掉;② 环境变量 `CYR_DIAG=1`,worker 作为子进程继承(它的命令行固定拼出,不带 `--diag`)。
- **文件**:`user://logs/diag-<role>-<pid>-<时间戳>.jsonl`,一行一个 JSON,字段 `t` / `pid` / `role` / `event` / `data`。
- **默认关 = 零成本**:`enabled()` 懒查一次;关着时不开文件、不拼 JSON。
- 判据:**零守卫**（原 `net_diag_smoke.gd` 已随 2026-10-24 默认批削减删除；缺口登记在 [`registered-debt.md`](registered-debt.md) §九）。

| 事件 | 落点 | 读它回答什么 |
|---|---|---|
| `session_start` | `net_diag.gd` 自己 | 版本 / 引擎 / OS / 文件路径 |
| `snap_gap` | [`core/net/wire.gd`](../../core/net/wire.gd) 的 SNAPSHOT_WORLD 接收侧 | 世界包断流 >150ms |
| `snap_rx` / `snapshot_tx` | `core/net/wire.gd` / [`server/match/match_snapshot.gd`](../../server/match/match_snapshot.gd) | 按 1Hz 对账「没发出」与「发了没收到」 |
| `rollback` | [`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的 `_handle_ack` | 位置 / 速度误差、是否贴身、重放条数 |
| `queue` / `queue_drop` | [`server/match/input_intake.gd`](../../server/match/input_intake.gd) | 服务器输入队列深度 / 上限 / 累计丢弃 |
| `pickup_try` | [`server/match/match_ground.gd`](../../server/match/match_ground.gd) | `none` / `range` / `denied` / `taken` 四种成因 |
| `pickup_add` / `pickup_remove` / `pickup_skip` | [`scenes/mp_client/pickup_sync.gd`](../../scenes/mp_client/pickup_sync.gd) | 客户端是否建出那把枪、早退原因 |
| `tile_cell` / `tile_sub` | [`scenes/mp_client/tile_sync.gd`](../../scenes/mp_client/tile_sync.gd) | 拆砖事件是否到达、是否静默补态 |
| `reconnect_begin` / `reconnect_resumed` | [`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd) | 局内自动重连的时间窗 |

- **边界**:① `t` 是各进程自己的单调时钟,跨进程只能按事件对齐、不能相减;② 只记事件、不采样逐帧状态;③ 写盘失败只 `push_warning`、不影响对局;④ 诊断事件**不进任何断言**,「日志里没有」≠「没发生」(关闭时一行都没有)。

## 运维审计通道(`ops`)

实现同样在 `net_diag.gd`,与 `--diag` 互不替代。

- **开关**:**常开**,但只在**非 client 进程**(`should_audit(role())`)。服务端启动即 `NetDiag.set_role("server")` —— 漏这一行,`role()` 会把大厅推断成 client,审计永远不写。
- **文件**:`user://logs/ops-<role>-<pid>-<时间戳>.jsonl`,与 diag 同形;每条都 `flush`。
- **保留策略**:数值只看常量 `NetDiag.OPS_KEEP`(60 份)与 `OPS_WARN_BYTES`(8 MiB)。开新文件前按文件名里的**时间戳段**倒序保留最新 N 份;单文件超上限 `push_warning` 一次。
- 一个进程一个文件(1 大厅 + 每局 1 worker)⇒ N 份 ≈ N-1 局。
- **事件**:`lobby_start` / `lobby_stop` · `room_created` / `room_closed` · `player_join` / `player_leave` / `player_detach` / `host_transfer` · `match_start` / `match_begin` / `match_end` / `match_over` · `abort` · `worker_spawn_failed` / `worker_lost`。细节归 `--diag`。
- **关窗 = 优雅停止**:`server_main` 拦 `NOTIFICATION_WM_CLOSE_REQUEST` → 逐个 `teardown_room` → 写**唯一**一条 `lobby_stop`;`--quit-after` 等正常退出走 `_exit_tree` 兜底(`_stop_logged` 去重)。
- **`worker_lost` 是"现场"不是"判定"**:记录 `alive_sec` + 该 worker 引擎日志最后 3 行;正常结束与崩溃都发。
- **每局日志归档**:开局前把 `worker_<端口>.log` 改名成 `worker_<端口>_<HHMMSS>.log`,同端口保留最新 `WorkerLauncher.WORKER_LOG_KEEP`(20)份。
- 判据:**零守卫**（原 `ops_log_smoke.gd` 已随 2026-10-24 默认批削减删除；缺口登记在 [`registered-debt.md`](registered-debt.md) §九）。
- **边界**:同 diag —— `t` 跨进程不可相减;写盘失败只 `push_warning`;审计事件不进断言。
