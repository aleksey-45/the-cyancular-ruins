# AGENTS.md

> **接手入口。** 工程权威是 [`CLAUDE.md`](CLAUDE.md)(**索引**;正文按域拆在 [`docs/eng/`](docs/eng),每条都带着"为什么");本文件**不复制它**,只回答三件事:**怎么跑、怎么干、去哪查**。
> ★ **文档会过期**:任何一处与源码冲突,**以源码为准**,并顺手把那处文档订正掉。真相源排序 —— **源码 > 探针实测 > `CLAUDE.md`/`docs/eng/` > 其它文档 > 本文件**。

## ★ 写测试的规矩 —— 该写冒烟、该写探针、还是**该不写**

> **为什么这一节在最前面**:2026-10-09 一次削掉 90%(默认批 **111 支 → 14 支**,删 343 个文件)。
> 复盘结论不是"测试写得不好",而是 **"写得太多"** —— 本仓的默认答案应当是**不写**。
> 判据与证据:[`docs/eng/test-economy.md`](docs/eng/test-economy.md);
> 那一次的台账、保留清单与**代价**:[`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md)。

### 0. 先答三问,任何一问答不出就**停手**

1. **去掉什么它才会红?** 答不出 ⇒ 不写(恒真 / 空转)。
2. **它挡的是哪一种「真实发生过或极可能发生」的缺陷?** 算不出 ⇒ 不写。
3. **它在行为上可观测吗?** 只能靠读源码文本判形态 ⇒ 不写(那是架构评审,不是守卫)。

★ 三问全过**才**进入下面挑桶。

### 1. 桶由「要什么资源」决定,不由「测多少代码」决定

Google 的官方口径把这两件事分开:**size = 跑它要占什么资源**(进程 / 内存 / 时间),
**scope = 你验证哪些代码路径**([*Software Engineering at Google* ch.11](https://abseil.io/resources/swe-book/html/ch11.html))。
本仓三个桶正好是按 **size** 切的:

| 桶 | 资源边界(**选桶就用这一栏判**) | 本仓形态 | 典型耗时 |
|---|---|---|---|
| **冒烟** | **单进程**:被测代码与测试同进程;不碰网络 / 磁盘 / 真实例化场景;`autoload` 尚未实例化 | `tests/smoke/*.gd`(`extends SceneTree`,`-s`) | 0~3 s |
| **探针(场景)** | **单机、真场景树**:真实例化 `.tscn`、走 `_ready` / 信号 / 资源加载 / 渲染 | `tests/probe/*.tscn` | 1~30 s |
| **真链路** | **跨进程 + 真端口 + 真协议**:起大厅 / worker / 客户端子进程 | `tests/{smoke,probe}/*.sh` | 分钟级 |

★ **永远选能证明它的最小那一档** —— Google 的原话是"总是写给定功能下**最小可能**的测试"。
★ 桶选大了**不是"更保险"**:更慢、更脆、更难定位。SWE@Google 明写 large 测试
"只该留给最复杂的场景、以及要**验配置**而不是验代码的场景"。

### 2. 该写哪一档 —— 按「你需要什么」查表

| 你要证明的东西 | 写在哪 |
|---|---|
| 纯逻辑:解析 / 编码解码 / 数值与公式 / 几何计算 / 状态机迁移 / 规则判定 | **冒烟**(`-s`) |
| 需要真实例化场景、节点生命周期、信号、资源加载、UI 树 | **探针**(`.tscn`) |
| 需要真端口 / 真子进程 / 真协议握手 / 真对局 | **真链路**(`.sh`) |
| **需要人眼看**:配色 / 版式 / 手感 / 观感 / "好不好玩" | **都不写** —— 见下 |

★★ **最后一行是最常被违反的一条**。Fowler:*"一旦你要测 usability 与『好不好看』,你就离开了自动化测试的领域"*;
Google 同样把"质量判断、音视频质量、创造性评估"划在自动化之外,归**探索性测试**
(SWE@Google ch.11 的「The Limits of Automated Testing」)。
⇒ **手感 / 观感不是"还没写守卫",是"守卫在这里没有意义"** —— 别拿一条钉死数值的断言去冒充它。

### 3. 不写清单(命中任意一条,删掉你正在写的那条)

**D 组 = 删**(逐条理由见 [`test-economy.md`](docs/eng/test-economy.md) §4):

| | 形态 |
|---|---|
| D1 | 答不出"去掉什么才会红"(恒真 / 空转) |
| D2 | **零断言**,判词靠 `print("XXX OK")` 的字面量、由入口 grep 它 |
| D3 | 钉死"会被反复调"的数值 / 时序 / 手感 |
| D4 | 与别处**同源重复**(同一个事实两份断言) |
| D5 | 只证明**引擎 / 第三方库**的行为 |
| D6 | **读源码文本**判形态(它测的是"某人有没有写那段字",不是行为) |
| D7 | **真机不可达**的防御分支的守卫 |
| D8 | 单文件 > 600 行且断言密度低 |
| D9 | 一条判定类别被拆成 N 条"一个数值一条断言" |

外加三条**结构性**的(都有权威出处):

- **别断言内部实现**。Kent Beck 的 Test Desiderata 里两条:**Behavioral**("行为被意外改变时它该红")与
  **Structure-insensitive**("过多 mock —— 尤其严格 mock —— 是结构敏感性的噩梦")
  ([出处](https://newsletter.kentbeck.com/p/desirable-unit-tests))。SWE@Google 侧同一条:
  *"brittle tests 会抵抗改变……改五行功能红掉几十条无关测试"*,而**最严重的来源就是 mock 滥用**
  (Google 内部一度喊出 "no more mocks!")。
- **别拿覆盖率当判据**。覆盖率只说明**那行被调用过**,不说明**结果对不对**;
  Google 建议**只统计 small 测试的覆盖率**(大测试会把覆盖率灌水)。
- **别在高层重复低层已测的**。Fowler:*"不需要在更高层重复这些测试"*,且*"底层测试好过高层测试"*。

### 4. 数量纪律

- **一条判定类别 = 一条守卫**,不是一个数值一条。
- **越高层越少**:Fowler —— *"层次越高,测试应当越少"*;端到端 *"减到最低限度(bare minimum)"*。
- **新守卫必须自带条数闸**(`EXPECTED_CHECKS` / `_checks >= N`),否则它的 `ALL-OK` 只等于
  "没有失败输出"([`tests/lib/probe_base.gd`](tests/lib/probe_base.gd) 文件头)。
  ★ 存量**不追补**(2026-10-08 已裁定,理由见 [`test-economy.md`](docs/eng/test-economy.md) §5.3 第 8 条);
  但**新写的没有闸 = 不许进**。
- **加守卫必须能说出它挡的缺陷**;"顺手加一条守卫"按违规处理。
- 动手前先过 **K1–K5**(能红 / 测本仓契约 / 覆盖档 3 面 / 一类别一条 / 失败信息能指路);
  桶与档位的关系见下面 §2 的**改动分档**表。

> ★ **诚实标注**:上面 SWE@Google ch.11、Fowler、Kent Beck 三份**读过全文**。Google Testing Blog 的
> [*Just Say No to More End-to-End Tests*](https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html)
> 与 [*Change-Detector Tests Considered Harmful*](https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html)
> **只拿到标题**(两处都取不到正文)⇒ 本节**没有**引用它们的原句;要引请自己打开核对。

## 0. 这是什么

Godot **4.7.1 标准版(非 mono)** 做的 2D 横版射击 demo「The Cyancular Ruins」:1920×1440、`rendering/mobile`、**环面世界**(左右/上下无缝回绕),单机 + PvP(1v1 / 3v3 / 大乱斗)+ 时间玩法(回溯 / 加速)。

- 单人肉鸽主线正在做,目标与数值在 [`docs/CyR单人模式主策划案(1).md`](<docs/CyR单人模式主策划案(1).md>)。
- 发布标识 **`<前缀>_v<版本>_<YYYYMMDDHHMM>`**(如 `RoF_v0.5.0_202610040204`)—— 主菜单/信息页版本行、
  服务端 `[server] 版本 …` 自报、归档目录与文件名都用它;前缀标"哪条线"(本线 `RoF`;另两条线是
  `KH_`(`KH_v0.5.0_B17`/`_P3*`)与 `siri_v0.5.0`)。**前缀的真相源 = `project.godot` 的
  `application/config/release_prefix`**;拼法在 `tools/archive_build.py` 的 `release_version()`/`release_label()`。
- **版本号唯一来源 = `project.godot` 的 `application/config/version`,只能写数字+点**(它要写进 Windows
  版本资源,**写 `v0.5.0`/`RoF_…` 会让导出失败**)。当前 **`0.5.0`**;发布标识 = 前缀(`release_prefix`)
  + 版本 + 时间戳,**每次构建用时间戳区分**。★ **别在任何文档里另抄一份版本号** —— 抄过的地方都过期过。
- 目录分层与操作见 [`README.md`](README.md);发布/裁剪模板见 [`RELEASE.md`](RELEASE.md)。

## 1. 怎么跑

引擎不在 PATH,而且**两个二进制不能混用**:`GODOT`(console 版,跑测试/服务端)与 `GODOT_EDITOR`(标准编辑器,导出用)。每个入口只留**一处**默认值([`tests/env.sh`](tests/env.sh) / `start_server.bat` / [`tools/build_release.py`](tools/build_release.py)),换机器设环境变量,**别改脚本里的绝对路径**。

```bash
# 冒烟(`-s`,`extends SceneTree`;成功打印 SMOKE OK)
"$GODOT" --headless --path . -s res://tests/smoke/network_input_smoke.gd
# 场景探针(`extends Node`;`--quit-after` 单位是帧,统一给 3600 当安全网)
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/tile_collision_probe.tscn
# 起 PvP 服务端(占 7777;终端开着 = 运行中)
"$GODOT" --headless --path . res://server/server_main.tscn
```

> ★★ **2026-10-09 测试面削减 90%**:上面两条**是仅存的例子** —— 全部**非 headless 取图探针**与
> `tests/manual/` 已在那一批里删除,所以**本仓现在没有"取图验收"这条命令了**。
> 那一批删了什么/留了什么/代价是什么:台账
> [`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md);
> 现行清单与跑法见 [`tests/README.md`](tests/README.md)。

- ★★ **跑测试前先问用户**:进入验证阶段时列出「这轮要跑哪些测试」,用户认领的自己跑,**其余由 agent 跑**(先问后跑,禁止先斩后奏)。agent 自跑时守这五条:
  1. **7777**:任何会占 7777 的步骤先查 `lobby_alive`,为真则**跳过并问** —— 大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局;
  2. **非 headless**(取图 / 真渲染探针)会弹窗口抢焦点,**跑前明确告知**;
  3. **真链路**:跑批**前后** `tasklist | grep -i godot` 必须为空(worker 是**孙进程**,孤儿会毒占端口、毒害下一支);收尾用 [`tests/env.sh`](tests/env.sh) 的 `kill_port_range`。★ **2026-10-04 订正**:"**绝不扫 `[7800,8300)`**"这句与实现**不符** —— 实测只有**池外两支**(`rejoin_probe.sh` / `team_match_probe.sh`)不扫,而 `pvp_match_smoke.sh` / `royale_soak_probe.sh` **照样扫该区间**(靠先过 `lobby_alive` 把关)。**真实规则**:任何要扫该区间的步骤,必须先过 `lobby_alive` 确认 7777 上没有活大厅;**池外那两支一律不扫**;
  4. **报告附证据**:关键行原文 + 退出码 / 日志位置 —— 只报"绿了"不算;
  5. **跑批环境要写进结论**:多进程抢 CPU 会**放大**换场卡顿、`_t` 会低报超长帧 ⇒ 时序类结论**同配置跑两次**再下。
- 命名检查:`python tools/check_naming.py`(五条:目录名小写 / `class_name` 与文件名对齐 / 文档引用的路径必须存在 / `.tscn` 一律 snake_case / `.ps1`·`.bat` 的 CRLF 与 `.ps1` 编码;`--self-test` 自测检查器自己)。
- **聚合回归入口**(2026-10-04 加):`bash tests/run_all.sh` = **headless 默认批**(**自动枚举** `tests/smoke/*.gd` + `tests/probe/*.tscn` + `tests/probe/*.gd`(没有同名 `.tscn` 的那些,按 `-s` 跑);不碰 7777、不弹窗;`--list` 看清单与**每条排除理由** + **已知红基线**,`--only <子串>` 跑子集),逐支判词分 `OK` / `OK+RC`(判词 OK **但** `rc != 0` ⇒ **不算红**、单列) / `FAIL` / `NO-VERDICT` / `TIMEOUT`,全批判词(**纯 ASCII**)`RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)`(基线 = `tests/known_red.txt`;**有新红才非 0**);真链路另走 `bash tests/run_real.sh`(活大厅 / 认领 / **R20 锁**+前后进程与另一批在飞 / 清单不许烂 四道闸)。★ **默认批绿 ≠ 真链路绿**(两条链路覆盖**不相交**);★ 单支 `OK` 只证明"**没有失败输出**"、不证明"每条断言都跑过",而 `KNOWN-RED` **不是**"已修好"(见 [`docs/eng/tests.md`](docs/eng/tests.md));清单、日志目录(`tests/.run_all_logs/`)与排除理由见 [`tests/README.md`](tests/README.md) 的「聚合入口」一节。

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
- ★★ **2026-10-09 起,上表的"必做"要打折读**:那一批把默认批从 **111 支砍到 14 支**、删掉
  `tests/manual/` 全部 18 支人工仪器,并删掉了 4 支真链路之外的**所有**多进程探针。
  ⇒ **档 1 的"视觉改动前后取图对比"与档 2 的"相关场景探针"多数已无对应探针**;
  档 3 的"真链路跑批"只剩 `tests/run_real.sh` 那 5 支。**改档 1/2 时,人眼/试玩成了唯一判据** ——
  这不是"免做",是"没有工具了"。台账与代价:
  [`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md)。

### 反重复:能生成就别再加守卫

**「重复的真相源 + 一条盯着它的守卫」是一种永久税** —— 改的时候要同步三处,漏一处才红。首选是把重复**消掉**(单一来源 + 生成器 + `--check`),守卫留给没有更好办法的地方。本仓已有的两个范本:

- `level_editor/sync-enemies.js`:真相源在 `data/enemies.json`,`--check` **只校验不写盘**(漂移退出 1 并点名首个差异行);
- `tools/gen_menu_theme.gd` → `ui/theme/menu_theme.tres`:从 `UiFactory` 的常量生成 Theme 资源,配镜像守卫。★ **2026-10-04 校正**:[`registered-debt.md`](docs/eng/registered-debt.md) §二 已把"**已完成,留作范本**"改口 —— 它只做到"生成物与守卫对账",**没做到"单一来源"**(生成器仍手抄 `UiFactory.menu_panel()` 的 64/46,而镜像守卫传的是它**自己写死的同一对字面量** ⇒ `menu_panel()` 默认值一改,生成器与守卫**一起静默用旧值**)。要拿它当范本,先读那条。

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
- `.ps1` 必须 **CRLF**;编码 =「**纯 ASCII 或带 UTF-8 BOM**」(带 BOM 时非 ASCII 是安全的 —— `tools/gamelog/capture_session.ps1` 实测 49 行中文靠它跑得好;没 BOM 才会被 PowerShell 按 ANSI/GBK 解成乱码)。`.bat` 同样必须 **CRLF**,**编码不查**(cmd 对非 ASCII 注释只是乱码,现存 `.bat` 里就有中文)。两者都由 `.gitattributes` 的 `eol=crlf` + `python tools/check_naming.py` 的**规则 E**逐文件守(红了用 `rm <file> && git checkout -- <file>` 重新落盘 —— 纯 EOL、不动内容);PowerShell 起带空格的路径要**手工内嵌双引号**。
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
| 本机运行账本(逐任务评审判决、全部登记项) | `.superpowers/sdd/`(**gitignore,不入库,但是恢复地图**):**按计划分子目录** —— 每批在 `.superpowers/sdd/<计划名>/` 下有 `progress.md`(逐轮裁决与 Ruling)、`task-N-brief.md` / `task-N-report.md`、`review-*.diff`(评审包);更早的批次是根下那个扁平的 `progress.md` |
| KH 线(v0.5.0 时间玩法)历史日志 —— **已封存,勿当现行规范** | [`docs/archive/kh-line-log.md`](docs/archive/kh-line-log.md)(原 `AGENTS.md`;封存纪律见 [`docs/archive/README.md`](docs/archive/README.md)) |

## 5. 接手点(核对于 2026-10-03)

- **在做的那条线**:[`docs/superpowers/plans/2026-10-03-ui-to-tscn-and-theme.md`](docs/superpowers/plans/2026-10-03-ui-to-tscn-and-theme.md) —— 把菜单屏从"代码建 UI"搬进 `.tscn` + `Theme`。
  ★ **进度以 `git log` 为准,别照着计划里的勾选框判断**:截至 2026-10-03,Task 0/1/2/3/4 的成果**都已在提交里**(Theme 基座、字体资源化、设置页、信息页、Beta 页 + 结算页),而勾选框**还全是空的** —— 典型的"枚举会过期"。剩下的看计划的 Task 5/6(主菜单 + 统一大厅迁移、收尾删被接管的旧样式函数)。**动手前先 `git log` / `grep` 复核。**
- **既有红 / 重复真相源**:清单是 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)。★ **2026-10-04 校正**:"唯一清单"这个说法**只对那两类成立** —— 性能/视觉/文档类的债住在 [`handoff`](docs/superpowers/handoff-2026-10-03.md) §2.4 与各域文档的「已知边界(登记)」里,落点表见该文件 §四。三条探针标注为**"不算守卫"**(其中 `team_match_probe.sh` 的**根因已于 2026-09-28 由 `9003dae` 修掉,但修复后没有留下六人整跑的判决** ⇒ **3v3 真链路今天仍没有可信的端到端守卫**),外加两条"改生成式"的候选。**动手前先看它,别把红的当绿的。**
- **其它登记项**(地形图常驻 61MB 显存、结算页"行底"、取景 150% 的像素完美取舍等)在 [handoff](docs/superpowers/handoff-2026-10-03.md) §2.4 —— **先查那里,别当新问题重查一遍**。
