# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **本文件是索引**(2026-10-03 拆分):正文按域拆到 `docs/eng/` 下,这里只留**项目概览 + 常用命令 + 架构索引**。
> **为什么拆**:单文件 182KB,而工作区指令预算是 64KB ⇒ 每次加载都被截断,后半本(**联机 74KB、测试 12KB**)**从来没进过上下文** —— 等于没写。
> **全文归档**:拆分前的全文已**封存**在 [`docs/archive/claude-md-full-2026-10-02.md`](docs/archive/claude-md-full-2026-10-02.md)（只作查证 —— ★ 里面的 `文件:行号` 与文件清单**都已过期**，见 [`docs/archive/README.md`](docs/archive/README.md)）。★ **任何冲突以源码为准**,读之前先 `grep` 复核。

## 项目概览

Godot 4.7(标准版,非 mono)做的 2D 横版(平台跳跃)射击 demo「The Cyancular Ruins」。1920×1440 视口、`rendering/mobile`。核心特色:

- **环面世界**:地图左右/上下无缝回绕,敌人/子弹/镜头跨接缝连续。
- 单关卡(Level0)从 `maps/*.cyrm` 加载(现行 = **v4 二进制**,见 [`docs/eng/world.md`](docs/eng/world.md));**每次会话随机取一份地图文件**,不做运行时地形生成。
  ★ **2026-10-13 订正**:原文写"从 **ASCII 地图文件**加载,无运行时随机生成(生成逻辑已注释)" —— 三处都不准:
  ASCII 是 v1/v3 时代的**旧文本格式**(现行是 `CYRM\x04` 二进制);`MazeGenerator._random_cyrm()` 会
  **随机选一份** `.cyrm`(那是选图,不是生成);旧的生成逻辑已拆进 `MapFormat` / `GridPathfinder`。

## 常用命令

Godot 不在 PATH,用绝对路径。**4.7.1 标准编辑器**是当前主用版本(详见 `RELEASE.md`;4.4.1 mono 已弃用)。

**引擎路径可覆盖**(换机器/换版本不必改脚本):`tests/*/*.sh` 与 `start_server.bat` 读环境变量 **`GODOT`**(console 版),`tools/build_release.py` 读 **`GODOT_EDITOR`**(标准编辑器版——导出与 headless 跑测试是**两个不同的二进制**);未设时回落本机默认路径,且**每个入口只留一处默认值**(`tests/env.sh` / `start_server.bat` / `build_release.py`)。`tests/*/*.sh`(在 `tests/{smoke,probe,harness,scripts}/` 下一层)一律 `source` 同目录上一级的 `../env.sh` 取 `$GODOT` 与 kill 助手。下面是**默认路径**下的命令:

```bash
# 冒烟测试(SceneTree 脚本;成功打印 SMOKE OK 退出 0)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/smoke/network_input_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# PvP 服务端(headless,监听 7777;保持终端开着=运行中)。更省事:双击仓库根 start_server.bat。
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 导出单 exe 发布版
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

约定:**测试怎么跑,先问用户** —— 进入验证阶段时把「这轮要跑哪些测试」列出来,用户认领的自己跑,**其余由 agent 跑**(先问后跑,禁止先斩后奏)。agent 自跑时必须守 [`docs/eng/tests.md`](docs/eng/tests.md) 里「真链路跑批的两条纪律」与 `tests/env.sh` 的 kill 助手;另两条硬线:① 任何**占 7777** 的步骤先查 `lobby_alive`(大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局);② **非 headless**(取图/真渲染探针)会弹窗口抢焦点,**跑前明确告知**。发布/裁剪模板细节见 `RELEASE.md`(单 exe 靠自定义裁剪模板,勿用 UPX,保留 webp 模块)。模板重编只在**改裁剪 profile(增删类/模块)**时需要,单次≈10~15 分钟近全量(RELEASE.md §2.4);平时改 GDScript 只需重导出。

**版本号**:唯一来源是 `project.godot` 的 `application/config/version`,**只能写数字+点**(如 `0.5.0`;写 `v0.5.0` 或任何字母都会让导出预设校验失败)。`tools/build_release.py` 导出前把 `v<版本>` + 构建时间戳写进 `core/config/build_info.gd`、导出后还原成 dev 占位(工作区不脏);发布版由**主菜单版本号行**与**服务端启动自报的 `[server] 版本 …`** 两处显示(发布机往往没有 git)。归档名 = `<原名> <版本号> <时间戳>.exe`。该脚本还会跑一次**产物冒烟**(客户端直接起;服务端走 `-- --worker --port 7999`,不碰 7777,并**断言输出里有「worker 就绪」**——光"没报错"会漏掉"零错误地跑错分支")。★ `--worker` 这类开关**必须写在 `--` 之后**(`server_main.gd` 读 `OS.get_cmdline_user_args()`),写在前面会被 Godot 丢掉、静默起成大厅。

## 架构(索引)

**各域细节在 `docs/eng/` 下,按需要读那一份**(读前先 `grep` 复核 —— 文档会过期):

| 什么时候读 | 文件 |
|---|---|
| 改地图格式(cyrm)、环面几何/寻路、参数体系、砖块属性与破坏、水、碰撞层 | [`docs/eng/world.md`](docs/eng/world.md) |
| 加/改敌人、AI 状态机、寻路、精英与掉落 | [`docs/eng/enemies.md`](docs/eng/enemies.md) |
| 加/改武器与子弹、弹道与命中、背包容量、地面拾取、武器注册表 | [`docs/eng/weapons.md`](docs/eng/weapons.md) |
| 移动/跳跃/冲刺/下蹲、姿态碰撞箱、输入注入、残弹与换弹 | [`docs/eng/player.md`](docs/eng/player.md) |
| Level0 渲染管线、图集、后处理、补间形变 | [`docs/eng/render.md`](docs/eng/render.md) |
| 调色板与 UiFactory、菜单语汇、HUD、小地图、大厅版式 | [`docs/eng/ui.md`](docs/eng/ui.md) |
| 大厅/worker、匹配进图、房间与回合、回到大厅、重连、RPC 归属 | [`docs/eng/netplay.md`](docs/eng/netplay.md) |
| 快照管线(60Hz 全量编码、丢弃规则、输入队列的延迟累加、带宽实测与主流对照) | [`docs/eng/netcode-snapshots.md`](docs/eng/netcode-snapshots.md) |
| 3v3、结算页、大乱斗及其已知差异 | [`docs/eng/modes.md`](docs/eng/modes.md) |
| 探针怎么跑/怎么判、真链路纪律、守卫边界 | [`docs/eng/tests.md`](docs/eng/tests.md) |
| 浏览器地图编辑器、sync-*.js、导入/导出工具 | [`docs/eng/tools.md`](docs/eng/tools.md) |
| 时间玩法(回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕)、它的不变量与常量来源 | [`docs/eng/time.md`](docs/eng/time.md) |
| 注释怎么写(含**注释额度**:>100 行的 `.gd` ≤15%)、守卫幻觉怎么标 | [`docs/eng/comment-style.md`](docs/eng/comment-style.md) |
| 测试该不该写、写哪一档(桶划分与 D1~D9 不写清单) | [`docs/eng/test-economy.md`](docs/eng/test-economy.md) |
| 房间/端口生命周期约定(回收梯、超龄扫、端口池) | [`docs/eng/room-lifecycle-conventions.md`](docs/eng/room-lifecycle-conventions.md) |
| **动手前必看**:既有红 / 待还的债 / 已裁定不做 | [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)(**分节索引**,正文在 [`docs/eng/debt/`](docs/eng/debt)) |

**垂直专题:联机时序(`netcode-*.md` 系列 —— 快照 / 输入 / 时钟 / 抖动 / 带宽的研究与实测)**

| 主题 | 文件 |
|---|---|
| 快照管线(60Hz 全量编码、丢弃规则、延迟累加)+ 带宽实测与主流对照 | [`netcode-snapshots.md`](docs/eng/netcode-snapshots.md) |
| 输入上行链路(输入包 / 队列 / ack 与跨纪元) | [`netcode-input-uplink.md`](docs/eng/netcode-input-uplink.md) |
| 客户端插值与输入细节 | [`netcode-client-interp-and-input-details.md`](docs/eng/netcode-client-interp-and-input-details.md) |
| 增量与量化细节 | [`netcode-delta-and-quantization-details.md`](docs/eng/netcode-delta-and-quantization-details.md) |
| 16 人局的读数 | [`netcode-at-16-players.md`](docs/eng/netcode-at-16-players.md) |
| tick 率调研 | [`netcode-tick-rates-survey.md`](docs/eng/netcode-tick-rates-survey.md) |
| playout 时钟与同步来源(NTP / RTP / Valve) | [`netcode-playout-clock-sync-sources.md`](docs/eng/netcode-playout-clock-sync-sources.md) |
| 抖动缓冲实践(与 netfox 对照) | [`netcode-jitter-buffer-practice.md`](docs/eng/netcode-jitter-buffer-practice.md) |

★ **一次性时间点报告 —— 不是现行规范**(只在回溯"当时为什么这么判"时读):[`conventions-review-2026-10.md`](docs/eng/conventions-review-2026-10.md)、[`audit-2026-10-04-design-conventions.md`](docs/eng/audit-2026-10-04-design-conventions.md)。

★ **上表是手抄的,会漂** —— **真相源 = `ls docs/eng/*.md`**(本行写时是 **25 份**)。
`tools/check_naming.py` 的**规则 C** 已改成 **glob 覆盖全部 `docs/eng/*.md`**(2026-10-13 之前是写死的 11 个名字 ⇒ 另外十几份的路径引用**从来没人守**;同日还堵掉了"缀一个 `:55` 就绕过检查"的洞)。
★ **既有红 / 待还的债**(不算守卫的探针、重复真相源候选)登记在 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)。
★ **测试与守卫的判据纪律**在 [`docs/eng/tests.md`](docs/eng/tests.md);跑测试的分工见本文件 §常用命令 的约定。

