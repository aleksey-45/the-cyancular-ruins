# AGENTS.md

> **接手入口。** 工程权威是 [`CLAUDE.md`](CLAUDE.md)(**索引**;正文按域拆在 [`docs/eng/`](docs/eng),每条都带着"为什么");本文件**不复制它**,只回答三件事:**怎么跑、怎么干、去哪查**。
> ★ **文档会过期**:任何一处与源码冲突,**以源码为准**,并顺手把那处文档订正掉。真相源排序 —— **源码 > 探针实测 > `CLAUDE.md`/`docs/eng/` > 其它文档 > 本文件**。

## 0. 这是什么

Godot **4.7.1 标准版(非 mono)** 做的 2D 横版射击 demo「The Cyancular Ruins」:1920×1440、`rendering/mobile`、**环面世界**(左右/上下无缝回绕),单机 + PvP(1v1 / 3v3 / 大乱斗)+ 时间玩法(回溯 / 加速)。

- 单人肉鸽主线正在做,目标与数值在 [`docs/CyR单人模式主策划案(1).md`](<docs/CyR单人模式主策划案(1).md>)。
- 版本号规则 `KH_V0.5.0_YYMMDD`;**版本号唯一来源 = `project.godot` 的 `application/config/version`,只能写数字+点**(写 `v1.2.3` 会让导出预设校验失败)。
- 目录分层与操作见 [`README.md`](README.md);发布/裁剪模板见 [`RELEASE.md`](RELEASE.md)。

## 1. 怎么跑

引擎不在 PATH,而且**两个二进制不能混用**:`GODOT`(console 版,跑测试/服务端)与 `GODOT_EDITOR`(标准编辑器,导出用)。每个入口只留**一处**默认值([`tests/env.sh`](tests/env.sh) / `start_server.bat` / [`tools/build_release.py`](tools/build_release.py)),换机器设环境变量,**别改脚本里的绝对路径**。

```bash
# 冒烟(`-s`,`extends SceneTree`;成功打印 SMOKE OK)
"$GODOT" --headless --path . -s res://tests/smoke/enemy_logic_smoke.gd
# 场景探针(`extends Node`;`--quit-after` 单位是帧,统一给 3600 当安全网)
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/<名>.tscn
# 起 PvP 服务端(占 7777;终端开着 = 运行中)
"$GODOT" --headless --path . res://server/server_main.tscn
# 取图验收(★ 不带 --headless;带了就没有视口纹理、静默不存图)
"$GODOT" --path . --quit-after 300 res://tests/probe/<视觉探针>.tscn
```

- ★★ **跑测试前先问用户**:进入验证阶段时列出「这轮要跑哪些测试」,用户认领的自己跑,**其余由 agent 跑**(先问后跑,禁止先斩后奏)。agent 自跑时守这五条:
  1. **7777**:任何会占 7777 的步骤先查 `lobby_alive`,为真则**跳过并问** —— 大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局;
  2. **非 headless**(取图 / 真渲染探针)会弹窗口抢焦点,**跑前明确告知**;
  3. **真链路**:跑批**前后** `tasklist | grep -i godot` 必须为空(worker 是**孙进程**,孤儿会毒占端口、毒害下一支);收尾用 [`tests/env.sh`](tests/env.sh) 的 `kill_port_range`;**绝不扫 `[7800,8300)`**;
  4. **报告附证据**:关键行原文 + 退出码 / 日志位置 —— 只报"绿了"不算;
  5. **跑批环境要写进结论**:多进程抢 CPU 会**放大**换场卡顿、`_t` 会低报超长帧 ⇒ 时序类结论**同配置跑两次**再下。
- 命名检查:`python tools/check_naming.py`(四条:目录名小写 / `class_name` 与文件名对齐 / 文档引用的路径必须存在 / `.tscn` 一律 snake_case)。

## 2. 怎么改(一次改动的流程)

1. **定档** —— 先按**爆炸半径**定档(见下表)。档位看"改坏了要多久才发现",**不看改动行数**;一处改动同时触及两档就**取高档**。
2. **定位** —— `grep` 现网引用。**别信文档里的文件清单/枚举,它们会过期**(本仓踩过多次)。
3. **改** —— 单一真相源;新逻辑落进该落的那一层(格式层 / 几何层 / 渲染层 / 会话态分开,见 [`CLAUDE.md`](CLAUDE.md) 的架构索引)。
4. **守卫** —— 每条新断言都必须能回答「**去掉什么它才会红**」;答不出就别写。
5. **验证** —— 按档位做(下表);判据**一律 grep 文本**(`SMOKE OK` / `ALL-OK`),不看退出码。
6. **登记** —— 每条守卫在注释里写清「最强保证是什么、测不到什么」;本轮不修的边界写进 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)。
7. **提交** —— **逐个文件点名 `git add`**(新建 `.gd` 连 `.gd.uid` 一起加;`.tscn` 不用),**绝不 `git add -A`**。提交信息 `type(scope): 中文一句话`。

### 改动分档(档位决定动作,别一刀切)

| 档 | 什么算这一档 | 必做 | 免做 |
|---|---|---|---|
| **1 · 皮** | 文案、颜色常量值、版式/间距、纯表现参数 | 相关探针 + 视觉改动**前后取图对比** | 变异验证、评审 |
| **2 · 单系统** | 一个子系统内的逻辑(敌人 AI / 武器手感 / UI 数据流 / 单机玩法),**不动协议与存档** | 纯逻辑 `-s` + 相关场景探针;**至少一条**承重断言的变异验证 | 真链路跑批、逐任务评审 |
| **3 · 承重面** | 协议 / 输入包 / 回滚与快照 / 存档与地图格式 / 导出与裁剪 / 命中与碰撞判定 / 联机权威 | 上面全部 + **每条承重断言**逐条变异验证 + 真链路跑批 + **逐任务评审** | —— |

- ★ **变异验证按档分级**,不按"每条断言"平摊:档 1 免;档 2 至少一条(挑这次改动里最承重的);档 3 逐条。
- ★ 定档的判据是「**改坏了多久才发现**」:`test` 一秒就红 → 档 1;要跑六人真链路才发现 → 档 3。**不确定就往上取一档。**
- ★ 档 3 的「逐任务评审」= 每个任务做完先审再进下一个(本仓既有做法,账本见 `.superpowers/sdd/`)。

### 反重复:能生成就别再加守卫

**「重复的真相源 + 一条盯着它的守卫」是一种永久税** —— 改的时候要同步三处,漏一处才红。首选是把重复**消掉**(单一来源 + 生成器 + `--check`),守卫留给没有更好办法的地方。本仓已有的两个范本:

- `level_editor/sync-enemies.js`:真相源在 `data/enemies.json`,`--check` **只校验不写盘**(漂移退出 1 并点名首个差异行);
- `tools/gen_menu_theme.gd` → `ui/theme/menu_theme.tres`:从 `UiFactory` 的常量生成 Theme 资源,配镜像守卫。

**待改的候选登记在 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)**;新代码遇到"同一个值要抄两处"时,直接上生成式,别再补一条守卫。

**完成标准**(缺一条就不算完):

- 新断言答得出"去掉什么才红",**且按档位做了变异验证**;
- 每个"改了 A 就会过期"的 B(注释里的清单、写死的数量、按钮文案、文档里的路径)都 **`grep` 过并订正**;
- 已知边界 / 覆盖上限**落在纸上**(代码注释或 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)),而不是只在对话里说过。

## 3. 硬规则(每条都是踩过的坑)

**判据与守卫**

- ★★ 「grep 到 `ALL-OK`」**只证明没有任何断言失败,不证明每条断言都跑过**:脚本错误只结束**出错的那个函数**、调用方继续 ⇒ 后面静默跳过,verdict 照打 `ALL-OK`,**退出码恒 0**。新场景探针用 `_checks >= EXPECTED_CHECKS` 堵它。权威表述在 [`tests/lib/probe_base.gd`](tests/lib/probe_base.gd) 文件头。
- **退出码从来不是判据**;要退出码就**别接管道**(`| tail` 报的是 `tail` 的退出码)。
- `-s` 冒烟**必须写空载守卫**(`load()` 后立刻 `if X == null: print(...); quit(1); return`),否则一旦抛错就走不到 `quit()`,进程**永久挂起**;跑新冒烟一律套外层 `timeout`。
- 场景探针的 `--quit-after` 给足(统一 3600):给少了会在负载重时先耗尽,而**安全网耗尽与真失败在输出上长得一样**。
- ★★ 「**守卫能给的保证总是比它读起来少**」—— 本仓已出过十次以上(恒真断言、查子串不查分支、探针够不到承重分支、在出厂默认下恒真……),典型形态与通用检查法见 [`docs/eng/tests.md`](docs/eng/tests.md) 末节。**发现这些的几乎全是审阅者,不是实现者。**

**协作(本机常有多个会话同时改同一个仓库)**

- ★★ **共用工作树**:逐个文件 `git add` 只保证"不带走别人的**文件**",**不保证不带走别人在同一文件里的 hunk**。提交前 `git status --short` + 逐文件 `git diff` **认领每个 hunk**;不属于本次改动的,不要提交、也不要"顺手修一下"。
- `CLAUDE.md` 通常**由协调者统一订正**;实现类任务不要顺手重写它。订正纪律:**定点改,别整段重写**(它的注释里带着大量"为什么")。
- 视觉验收:**看图判断,不要把对比度当验收标准**(用户明确取消过一次)。

**环境小口径**

- `.uid` 口径:跟踪 `*.gd.uid` / `*.gdshader.uid`;**`*.tscn.uid` 零跟踪**。
- 命令行开关(`--worker` 之类)必须写在 **`--` 之后**(`server_main.gd` 读 `OS.get_cmdline_user_args()`);写在前面会被 Godot 丢掉并**静默跑错分支**。
- 要进导出包的脚本**禁用 `RegEx`**(自定义裁剪模板 `module_regex_enabled: false` ⇒ 整个脚本解析失败,而编辑器里全绿)。
- 同一个量是**乘子**还是**浓度**,把方向写进注释与派发 —— 写反了会"越调越黑"且不报错。
- `.ps1` 保持**纯 ASCII + CRLF**(`.gitattributes` 钉着);PowerShell 起带空格的路径要**手工内嵌双引号**。
- **噪声与信号分不清时:同配置跑两次**。

## 4. 去哪查(指针)

| 想查什么 | 去哪 |
|---|---|
| 架构、参数体系、网络协议、敌人/武器/UI/渲染的**全部"为什么"** | [`CLAUDE.md`](CLAUDE.md) 是索引 → 按域读 [`docs/eng/`](docs/eng)(world / enemies / weapons / player / render / ui / netplay / modes / tests / tools) |
| 发布、裁剪模板、版本号、产物冒烟 | [`RELEASE.md`](RELEASE.md) |
| 目录分层、操作、PvP 规则要点 | [`README.md`](README.md) |
| 测试分层(bucket 划分)与跑法 | [`tests/README.md`](tests/README.md)、[`tests/env.sh`](tests/env.sh) 的注释 |
| 策划案(时间机制 / 肉鸽成长 / 数值 / 音美) | [`docs/CyR单人模式主策划案(1).md`](<docs/CyR单人模式主策划案(1).md>) |
| PvP 网络设计 | [`docs/pvp-networking.md`](docs/pvp-networking.md) |
| 地图格式(cyrm v3/v4)交接 | [`docs/2026-09-20-cyrm-v4-handover.md`](docs/2026-09-20-cyrm-v4-handover.md) |
| 历史设计与实施计划(每批一份 spec + plan) | `docs/superpowers/specs/`、`docs/superpowers/plans/` |
| 上一个会话的交接(欠账 + 纪律) | [`docs/superpowers/handoff-2026-10-03.md`](docs/superpowers/handoff-2026-10-03.md) |
| 本机运行账本(逐任务评审判决、全部登记项) | `.superpowers/sdd/progress.md`(**gitignore,不入库,但是恢复地图**) |
| KH 线(v0.5.0 时间玩法)历史日志 | [`docs/kh-line-log.md`](docs/kh-line-log.md)(原 `AGENTS.md`) |

## 5. 接手点(核对于 2026-10-03)

- **在做的那条线**:[`docs/superpowers/plans/2026-10-03-ui-to-tscn-and-theme.md`](docs/superpowers/plans/2026-10-03-ui-to-tscn-and-theme.md) —— 把菜单屏从"代码建 UI"搬进 `.tscn` + `Theme`。
  ★ **进度以 `git log` 为准,别照着计划里的勾选框判断**:截至 2026-10-03,Task 0/1/2/3/4 的成果**都已在提交里**(Theme 基座、字体资源化、设置页、信息页、Beta 页 + 结算页),而勾选框**还全是空的** —— 典型的"枚举会过期"。剩下的看计划的 Task 5/6(主菜单 + 统一大厅迁移、收尾删被接管的旧样式函数)。**动手前先 `git log` / `grep` 复核。**
- **既有红 / 重复真相源**:**唯一清单是 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)** —— 三条探针明确标注为**"不算守卫"**(其中 `team_match_probe.sh` 长期 FAIL ⇒ **3v3 真链路今天没有可信的端到端守卫**),外加两条"改生成式"的候选。**动手前先看它,别把红的当绿的。**
- **其它登记项**(地形图常驻 61MB 显存、结算页"行底"、取景 150% 的像素完美取舍等)在 [handoff](docs/superpowers/handoff-2026-10-03.md) §2.4 —— **先查那里,别当新问题重查一遍**。
