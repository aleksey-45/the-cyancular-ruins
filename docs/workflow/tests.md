# 测试与守卫

> 判据一律 **grep 文本**(`SMOKE OK` / `ALL-OK` / `RUN_ALL ...`);**退出码不是判据**。
> 本页只讲**机制与诊断**。跑什么 / 桶 / 闸 / 基线以 [`tests/README.md`](../../tests/README.md) 与 `bash tests/run_all.sh --list` 为准;怎么写见 [`test-authoring.md`](test-authoring.md);留不留见 [`test-economy.md`](test-economy.md)。**本页不抄清单与计数。**

## 单支跑法

`extends SceneTree` ⇒ `-s`;`extends Node` ⇒ `--quit-after <帧数>` 加 `.tscn`。引擎路径来自 [`tests/env.sh`](../../tests/env.sh) 的 `$GODOT`。

```bash
"$GODOT" --headless --path . -s res://tests/unit/<名>.gd
"$GODOT" --headless --path . --quit-after 3600 res://tests/scene/<名>.tscn
bash tests/e2e/<名>.sh
```

- `--quit-after` 的单位是**帧**,统一给 **3600**。它是安全网:探针跑完会自己 `quit()`,给少了会在负载重时先耗尽。
- 判据是 grep 到判词;**不要**接管道取 `rc`(`| tail` 报的是 `tail` 的退出码)。

## 判词语义(全批)

- 逐支:`OK`(判词肯定且 `rc == 0`)· `OK+RC`(判词肯定但 `rc != 0`,**不算红**,单列)· `FAIL` · `NO-VERDICT` · `TIMEOUT`;后两类归红。
- 全批:`RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)`;`m` = 带条数闸那些支的闸值之和,**不是**全批断言总数。
- 日志:`tests/.run_all_logs/` 下每支全文 + `summary.log`;跨跑次混装,同一路径会被下一趟覆盖。

## 条数闸

- 单支 `OK` 只证明「没有任何断言失败」,**不证明每条断言都跑过**:脚本错误只结束出错的那个函数、调用方继续,verdict 照打 `ALL-OK`;`ProbeBase._summary` 在整组一条都没跑时也会打 ✓。权威表述在 [`tests/lib/probe_base.gd`](../../tests/lib/probe_base.gd) 文件头。
- 新写的场景探针必须带闸,写法见 [`test-authoring.md`](test-authoring.md) §3。存量不追补。

## 已知红基线:`tests/known_red.txt`

- 每行 `路径 类别 理由`。路径必须与枚举出来的那一支**逐字相同**;类别 ∈ `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `*`;理由**必填**;`#` 开头是注释;**空行 = 违规**。
- 基线内的红 = `KNOWN-RED`:不进新红计数,但**永远**印出文件名与条数;全批判词转 `OK-WITH-KNOWN-RED`、退出码 0。
- **修好就删行**:条目"这趟跑到了却没红" = 过期 ⇒ 也红。路径不在候选面、同一路径出现两次 ⇒ 也红。

## 跑批纪律

- 查"某常量在不在"用 `get_script_constant_map()`,不要直接取属性 —— 取不存在的属性会抛错 → 挂起。
- 别拿"批量里红、单跑绿"断定是超时:安全网耗尽与探针真失败在输出上长得一样,先按真失败查。
- 占 7777 的步骤先查 `lobby_alive` —— 大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局。
- 两支真链路测试之间 `tasklist | grep -i godot` 必须为空:worker 是**孙进程**,孤儿会占住端口、毒害下一支。
- 池外 `rejoin_probe.sh`(29300/29350)与 `team_match_probe.sh`(29200/29250)**一律不扫** `[7800,8300)`;其余支扫之前必须先过 `lobby_alive`。
- **报告纪律**:结论里附**关键行的逐字内容**(判词原文)+ 退出码 / 日志位置 —— 别只写"跑了,是绿的"。跑批的**环境**(哪台机、哪版引擎、哪批参数)一并写进结论。
- **时序类结论必须同配置跑两次**再下:单跑得到的"偶发/稳定"分辨不出噪声与信号。
- **默认批绿 ≠ 真链路绿**:两条链路覆盖不相交。改联机权威 / 协议 / 回滚 / 输入包,两边都要看。

## 守卫能给的保证总是比它读起来少

- 逐条问"这一相里有多少输入是我自己喂的、有多少来自生产" —— 喂进去的那部分不构成对该路径的验证。
- 加新守卫时在它自己的注释里写清:「它能给的最强保证是什么」「它测不到什么」。
- 凡写"某变异会被 X 守住",先把该变异在**每个状态下的真值**列出来;凡写死一个可数的期望值,写清它是怎么数出来的。
- 变异判据要含"**红的原因对不对**":每个变异前确认已复原上一个;红时按**预期的断言名**核,报告记"红在哪条断言",不记"红了"。

## 结构化诊断(`--diag`)

实现:[`core/net/net_diag.gd`](../../core/net/net_diag.gd)(`class_name NetDiag`,静态、无 autoload)。

- **开关**:① 客户端命令行 `-- --diag` —— 必须写在 `--` 之后,写在前面会被 Godot 丢掉;② 环境变量 `CYR_DIAG=1`,worker 作为子进程继承(它的命令行固定拼出,不带 `--diag`);③ **导出构建的服务端默认开**(2026-10-30:打包后的服务端必须永远有日志,不再要求服主记得加开关)。
- **文件**(2026-10-31 起分两份,别混回一个):`<日志目录>/diag-<role>-<pid>-<时间戳>.jsonl` = **事件**(回滚/丢包间隔/队列丢包/换局…,小而稀,直接 grep);`<日志目录>/metrics-<role>-<pid>-<时间戳>.jsonl` = **心跳指标**(queue / snapshot_tx / snap_rx,默认 **10s** 一条,`--diag-verbose` 或 `CYR_DIAG_VERBOSE=1` 才 1s —— 旧版每秒每角色一行,长局把 diag 撑到 700KB)。另有常开的运维 `ops-*.jsonl`(只有服务端)。一行一个 JSON,字段 `t` / `pid` / `role` / `event` / `data`。**日志目录**:导出构建的服务端 = **exe 同目录 `log/`**;其余 = `user://logs`;`CYR_LOG_DIR` 环境变量可整体覆盖(真链路批按支分目录)。选择逻辑在 [`core/net/net_metrics.gd`](../../core/net/net_metrics.gd) 的 `server_log_dir`(纯函数,`-s` 可测),`NetDiag.log_dir()` 只做一次转调 + env 覆盖 —— 别在第三处再判一次。
- **默认关 = 零成本**:`enabled()` 懒查一次;关着时不开文件、不拼 JSON。
- 判据:**零守卫**（原 `net_diag_smoke.gd` 已随 2026-10-24 默认批削减删除；缺口登记在 [`registered-debt.md`](../registered-debt.md) §九）。2026-10-30 起 `snap_rx` 的丢包字段与目录选择各有一支纯逻辑冒烟（`net_metrics_smoke`）；**接线**（`NetBus` 调用点、`NetDiag.log_dir` 调用点）仍无守卫，导出侧由 `build_release.py` 的 `require_log_dir` 兜底。

| 事件 | 落点 | 读它回答什么 |
|---|---|---|
| `session_start` | `net_diag.gd` 自己 | 版本 / 引擎 / OS / 文件路径 |
| `server_boot` | [`server/server_main.gd`](../../server/server_main.gd) | 服务端启动参数（worker / port / 模式 / role 集合）|
| `snap_gap` | [`core/net/net_bus.gd`](../../core/net/net_bus.gd) 的 `snapshot_world` | 世界包断流 >150ms |
| `snap_rx` / `snapshot_tx` | `net_bus.gd` / [`server/match/snapshot_system.gd`](../../server/match/snapshot_system.gd) | 按 1Hz 对账「没发出」与「发了没收到」;`snap_rx` 另有 `world_lost` / `world_loss_pct` / `own_lost` / `own_loss_pct` / `step`（**下行丢包估计**:相邻快照 tick 缺口按学到的步长折算,口径见 `NetMetrics.snapshot_loss`）|
| `rollback` | [`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的 `_handle_ack` | 位置 / 速度误差、重放条数（贴身容差字段随 2026-11-10「玩家之间不互挡」一起删除）|
| `queue` / `queue_drop` | [`server/match/input_intake.gd`](../../server/match/input_intake.gd) | 服务器输入队列深度 / 上限 / 累计丢弃 |
| `pickup_try` | [`server/match/ground_system.gd`](../../server/match/ground_system.gd) | `none` / `range` / `denied` / `taken` 四种成因 |
| `pickup_anchor` | [`scenes/mp_client/pickup_sync.gd`](../../scenes/mp_client/pickup_sync.gd) | 收到服务器的**落定重锚**(落定那一刻重播的权威位置);没它 = 两端落点发散会永久留着 |
| `pickup_add` / `pickup_remove` / `pickup_skip` | [`scenes/mp_client/pickup_sync.gd`](../../scenes/mp_client/pickup_sync.gd) | 客户端是否建出那把枪、早退原因 |
| `tile_cell` / `tile_sub` | [`scenes/mp_client/tile_sync.gd`](../../scenes/mp_client/tile_sync.gd) | 拆砖事件是否到达、是否静默补态 |
| `reconnect_begin` / `reconnect_resumed` | [`scenes/mp_client/reconnect_driver.gd`](../../scenes/mp_client/reconnect_driver.gd) | 局内自动重连的时间窗 |

- **边界**:① `t` 是各进程自己的单调时钟,跨进程只能按事件对齐、不能相减;② 只记事件、不采样逐帧状态;③ 写盘失败只 `push_warning`、不影响对局;④ 诊断事件**不进任何断言**,「日志里没有」≠「没发生」(关闭时一行都没有)。

## 运维审计通道(`ops`)

实现同样在 `net_diag.gd`,与 `--diag` 互不替代。

- **开关**:**常开**,但只在**非 client 进程**(`should_audit(role())`)。服务端启动即 `NetDiag.set_role("server")` —— 漏这一行,`role()` 会把大厅推断成 client,审计永远不写。
- **文件**:`<日志目录>/ops-<role>-<pid>-<时间戳>.jsonl`(日志目录口径与 `--diag` 同一处:`NetDiag.log_dir()`;导出服务端 = exe 同目录 `log/`),与 diag 同形;每条都 `flush`。
- **保留策略**:数值只看常量 `NetDiag.OPS_KEEP`(60 份)与 `OPS_WARN_BYTES`(8 MiB)。开新文件前按文件名里的**时间戳段**倒序保留最新 N 份;单文件超上限 `push_warning` 一次。
- 一个进程一个文件(1 大厅 + 每局 1 worker)⇒ N 份 ≈ N-1 局。
- **事件**:`lobby_start` / `lobby_stop` · `room_created` / `room_closed` · `player_join` / `player_leave` / `player_detach` / `host_transfer` · `match_start` / `match_begin` / `match_end` / `match_over` · `abort` · `worker_spawn_failed` / `worker_lost`。细节归 `--diag`。
- **关窗 = 优雅停止**:`server_main` 拦 `NOTIFICATION_WM_CLOSE_REQUEST` → 逐个 `teardown_room` → 写**唯一**一条 `lobby_stop`;`--quit-after` 等正常退出走 `_exit_tree` 兜底(`_stop_logged` 去重)。
- **`worker_lost` 是"现场"不是"判定"**:记录 `alive_sec` + 该 worker 引擎日志最后 3 行;正常结束与崩溃都发。
- **每局日志归档**:开局前把 `worker_<端口>.log` 改名成 `worker_<端口>_<HHMMSS>.log`,同端口保留最新 `WorkerLauncher.WORKER_LOG_KEEP`(20)份。
- 判据:**零守卫**（原 `ops_log_smoke.gd` 已随 2026-10-24 默认批削减删除；缺口登记在 [`registered-debt.md`](../registered-debt.md) §九）。
- **边界**:同 diag —— `t` 跨进程不可相减;写盘失败只 `push_warning`;审计事件不进断言。
