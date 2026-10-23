# 服务端运维审计日志(复用 NetDiag)设计

> **这份是什么**:`server/` 侧(大厅 + 每个 worker)**常开审计事件**的通道、事件清单、保留与优雅停止的权威。
> 实现计划:[`docs/superpowers/plans/2026-10-21-server-event-logging.md`](../plans/2026-10-21-server-event-logging.md)。
> **2026-10-21 重写**:上一版设计要新建 `server/log/srv_log.gd`,侦察后发现 **`core/net/net_diag.gd` 已经
> 具备同类能力**(一行一 JSON、跨进程对齐、urgent flush、worker 继承开关、IO 失败不打断业务)⇒ 改为**在它上面加
> 一条常开审计通道**,不新建第二套日志设施(仓规最忌重复真相源)。本版按 2026-10-23 重构后基线重写。

## 1. 现状:NetDiag 已经有的 / 缺的

`core/net/net_diag.gd`(153 行,2026-10-22 加;权威章节 `docs/eng/tests.md:158`「结构化诊断」):

| 能力 | 现状 |
|---|---|
| 行格式 | **一行一 JSON**:`{t, pid, role, event, data}` |
| 跨进程对齐 | `t`(单调毫秒)+ `pid` + `role`;每个文件首行是 `session_start`(带 build/version/engine/os) |
| 崩溃后仍在 | `urgent=true` ⇒ 写完立刻 `flush()` |
| 让 worker 也开 | `--diag` 或 **`CYR_DIAG=1`**(子进程继承)—— 正是为"大厅 `OS.create_process` 拉起的 worker"设计 |
| IO 失败 | `push_warning` + `_open_failed`,**不影响对局** |
| 落盘位置 | `user://logs/diag-<role>-<pid>-<stamp>.jsonl` |

**缺口(本批要补的四条)**:

1. **默认关**:`--diag`/`CYR_DIAG` 是"排障时打开"的开关;运维审计必须**默认开**。
2. **无保留策略**:diag 文件只增不删(靠人清)。
3. **worker 的引擎日志按端口复用会互相覆盖**:`worker_<端口>.log` 由引擎 `--log-file` 写,下一局同端口开新局时**覆盖上一局的崩溃现场**。
4. **关窗口 = 直接被杀**:worker 可能变孤儿,端口要等 120/360 秒延迟才回收;且没有任何"关服"记录。

## 2. 决策

在 `NetDiag` 上新增**常开审计通道** `audit(event, data)`,与既有 diag 通道**互不替代**:

| | diag 通道(既有,不动语义) | ops 通道(本批新增) |
|---|---|---|
| 开关 | `--diag` / `CYR_DIAG=1` | **常开**,但**只在非 client 进程**(`role() != "client"`) |
| 文件 | `diag-<role>-<pid>-<stamp>.jsonl` | `ops-<role>-<pid>-<stamp>.jsonl` |
| 用途 | 排障时抓细节(快照间隔/回滚/拆砖) | 回答"为什么":谁在何时建房/进房/开局/关房/失联 |
| 落盘 | 按需 flush | **每条都 flush**(崩溃后必须还在) |

- **为什么不在客户端开审计**:`NetDiag.role()` 对玩家客户端返回 `client`。审计是**服务端运维**的事,
  若客户端也写 ops 文件,每个玩家机器都会多出一份无人使用的日志 ⇒ 判据做成纯函数 `should_audit(role)`。
- **为什么复用而不是新建**:格式/跨进程对齐/worker 继承开关/IO 兜底这四件事 `NetDiag` 已经做对且有为它们写的注释;
  重写一遍等于让两个文件各自演化,而调用点必然有一半走错门。

## 3. 保留与体积(不做大小轮转,理由见下)

- `ops` 文件**每次进程启动一个**;开新文件前把同目录 `ops-*.jsonl` 按文件名倒序保留**最新 60 份**,其余删除
  (文件名带 `YYYYMMDD_HHMMSS` ⇒ 字典序即时间序,不需要读文件内容)。
- **不做 2MB×10 轮转**:审计粒度是"事件级"而非"逐帧级"。估算:一局 = `room_created` + `player_join`×N +
  `match_start` + `match_end` + `room_closed` ≈ 10 行 × ~200 B ≈ **2 KB/局**;每天 100 局 ≈ 200 KB/天 ⇒
  长跑大厅单文件月级约 6 MB,配 60 份文件足够。★ 另加一条**可观测的上限**:单文件超过 **8 MB** 时
  `push_warning` 一次(不静默)—— 超了就说明事件量级判断错了,该回来看这份设计。
- worker 的**引擎日志**归档:`worker_<端口>.log` ⇒ 开局前重命名 `worker_<端口>_<HHMMSS>.log`,
  同端口只保留最新 **20** 份(名字即时间序);判据与命名都是纯函数。

## 4. 事件清单(审计通道)

落点按 **2026-10-23 重构后**的代码(行号见计划;worker 分支在 `server/server_main.gd`,不在 `match_host`)。

| 进程 | 事件 | 必带字段 |
|---|---|---|
| 大厅 | `lobby_start` | version, port |
| 大厅 | `lobby_stop` | reason(`close_request`\|`quit`), rooms_left |
| 大厅 | `room_created` | room, mode, peer, nick |
| 大厅 | `room_closed` | room, mode, reason(`operator`\|`sweep_timeout`\|`match_end`\|`abort`), port, players, uptime_sec |
| 大厅 | `player_join` | room, mode, peer, nick, players |
| 大厅 | `player_leave` | room, mode, peer, players |
| 大厅 | `host_transfer` | room, mode, from_peer, to_peer |
| 大厅 | `match_start` | room, mode, port, players, ai |
| 大厅 | `match_end` | room, mode, port, uptime_sec |
| 大厅 | `worker_spawn_failed` | room, mode, port |
| 大厅 | `worker_lost` | room, mode, port, pid, alive_sec, tail(**引擎日志最后 3 个非空行**) |
| worker | `match_boot` | port, mode, roles, map |
| worker | `match_over` | mode, reason |
| worker | `abort` | reason(`understaffed_timeout`\|`report_timeout`) |

★ **拿不到退出码**(Godot 4 `OS` 没有子进程退出码 API:`OS.create_process` 只给 pid、`is_process_running` 只给存活)
⇒ `worker_lost` 用**存活时长 + 引擎日志尾部**代替;尾部里的错误原文才是崩溃原因。
★ `nick` 写完整昵称(本机日志、无账号体系、用户裁定不考虑脱敏);`tail` 里的换行压成 ` ↵ `(一行一条)。
★ `mode` 一律用 `ModeDefs.MODE_*` 的字符串(`pvp`/`royale`/`team`),不再有 `kind` 这第二个名字。

## 5. 优雅停止

`server_main` 大厅分支 `_ready` 里 `get_tree().auto_accept_quit = false`;新增 `_notification` 处理
`NOTIFICATION_WM_CLOSE_REQUEST`:

1. 遍历 `RoomRegistry`(经 `LobbyRooms` 的门面视图)逐个 `teardown_room(room, TEARDOWN_KILL)`;
2. `audit("lobby_stop", {"reason": "close_request", "rooms_left": 0})`;
3. `get_tree().quit()`。

`--quit-after` 之类正常退出走 `_exit_tree` 兜底(用 `_stop_logged` 去重,不许写两条 `lobby_stop`)。

## 6. 守卫策略(按 `AGENTS.md` 的"写测试的规矩")

| 写 | 不写 |
|---|---|
| `should_audit(role)`、`ops_file_name(...)`、`ops_files_to_keep(names, keep)` | 事件**在正确时机被调用**(要真房间 ⇒ 真链路/人眼) |
| `audit()` 端到端:注入测试路径后**读回 JSON 校验字段**,且 `role=client` 时**不写** | 60 份保留的**真实磁盘行为** |
| `archive_name(path, stamp)`、`prune_worker_logs(names, port, keep)` 纯判据 | worker 日志归档的**真实重命名**(要连开两局) |
| `allscript_probe.EXPECTED_SCRIPTS` 190 → 191 | 关窗优雅停止(要真关窗口) |

不写的三条登记进 `docs/eng/debt/guard-strength-gaps.md`(§五 新增一条)。

## 7. 非目标(本批明确不做)

面板事件页 / 前端展示;**指标采集**(CPU/内存/tick);玩家管理(踢/封/权限);RCON / Web 面板;
持久化与备份;反作弊;把 diag 通道改成默认开。

## 8. 已知约束

- **注释额度**:`core/net/net_diag.gd` **20.0%**、`server/server_main.gd` **15.49%**、`server/lobby/lobby_rooms.gd`
  **17.7%** —— **三个文件都已超标**(后两个是 2026-10-23 重构删代码把比例顶上来的)。
  ⇒ 本批对这三个文件**只许加行尾注释**,不许净增整行注释;存量不追补(按 `comment-style.md` §8 的口径)。
- 脚本总数:**190**(`allscript_probe` 的 `EXPECTED_SCRIPTS`);本批新增 1 个 `.gd`(冒烟)⇒ **191**。
- 服务端代码**禁用 `RegEx`**(裁剪模板关了该模块)。
