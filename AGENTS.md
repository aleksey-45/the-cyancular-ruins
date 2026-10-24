# AGENTS.md

> **接手入口。** 工程权威是 [`CLAUDE.md`](CLAUDE.md)(**索引**;分域正文在 [`docs/eng/`](docs/eng))。本文件只回答三件事:**怎么跑、怎么干、去哪查**。任何一处与源码冲突,**以源码为准**。

## 0. 这是什么

Godot **4.7.1 标准版(非 mono)** 做的 2D 横版射击 demo「The Cyancular Ruins」:视口 1920×1440、`rendering/mobile`、**环面世界**(左右 / 上下无缝回绕),单机 + PvP(1v1 / 3v3 / 大乱斗)+ 时间玩法(回溯 / 加速)。

- 单人模式的内容、数值与计划:[`docs/CyR单人模式主策划案(1).md`](<docs/CyR单人模式主策划案(1).md>)。
- **版本号唯一来源 = `project.godot` 的 `application/config/version`,只能写数字+点**(写 `v0.5.0` / 任何字母都会让导出失败)。发布标识 = `<前缀>_v<版本>_<YYYYMMDDHHMM>`;前缀来源同文件的 `application/config/release_prefix`,拼法收在 [`tools/archive_build.py`](tools/archive_build.py) 的 `release_version()` / `release_label()`。**别在任何文档里另抄一份版本号。**
- 目录分层与操作见 [`README.md`](README.md);导出 / 裁剪模板 / 产物冒烟见 [`RELEASE.md`](RELEASE.md)。

## 1. 怎么跑

引擎不在 PATH,**两个二进制不能混用**:`GODOT`(console 版,跑测试 / 服务端)与 `GODOT_EDITOR`(标准编辑器,导出用)。每个入口只留**一处**默认值([`tests/env.sh`](tests/env.sh) / `start_server.bat` / [`tools/build_release.py`](tools/build_release.py));换机器设环境变量,**别改脚本里的绝对路径**。

```bash
# 冒烟(`-s`,`extends SceneTree`)
"$GODOT" --headless --path . -s res://tests/smoke/net_wire_smoke.gd
# 场景探针(`extends Node`;`--quit-after` 单位是帧,统一给 3600 当安全网)
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/snapshot_size_probe.tscn
# 起 PvP 服务端(占 7777;终端开着 = 运行中)
"$GODOT" --headless --path . res://server/server_main.tscn
```

- **聚合入口**:`bash tests/run_all.sh` = headless 默认批(自动枚举 `tests/smoke/*.gd` + `tests/probe/*.tscn` + 无同名 `.tscn` 的 `tests/probe/*.gd`;不碰 7777、不弹窗;`--list` 看清单 / 排除理由 / 已知红基线,`--only <子串>` 跑子集,`--classify-check` 跑分类器自检);`bash tests/run_real.sh` = 真链路批(占 7777、拉子进程)。清单、逐支判词与跑法见 [`tests/README.md`](tests/README.md)。
- **命名 / 路径检查**:`python tools/check_naming.py`(A 目录名小写 / B `class_name` 转 snake 等于文件名 / C 文档引用的路径必须存在 / D `.tscn` snake_case / E `.ps1`·`.bat` 的 CRLF 与 `.ps1` 编码;`--self-test` 自测检查器本身)。
- ★★ **跑测试前先问用户**:进入验证阶段先列「这轮要跑哪些测试」,用户认领的自己跑,**其余由 agent 跑**。agent 自跑守五条:
  1. 任何会占 **7777** 的步骤先查 `lobby_alive`,为真则**跳过并问**(大厅 `_ready` 会 `kill_udp_port(7777)`,会端掉用户正在跑的对局);
  2. **非 headless**(弹窗抢焦点)的步骤**跑前明确告知**;
  3. **真链路**:跑批**前后** `tasklist | grep -i godot` 必须为空(worker 是孙进程,孤儿会毒占端口);收尾用 [`tests/env.sh`](tests/env.sh) 的 `kill_port_range`;要扫 `[7800,8300)` 的步骤必须先过 `lobby_alive`,而 `rejoin_probe.sh` / `team_match_probe.sh` 用池外端口、**不扫池**;
  4. **报告附证据**:关键行的逐字内容 + 退出码 / 日志位置;
  5. **跑批环境写进结论**;时序类结论**同配置跑两次**再下。

## 2. 怎么改(一次改动的流程)

1. **定档** —— 按**爆炸半径**定档(见下表)。档位看"改坏了要多久才发现",**不看改动行数**;同时触及两档就**取高档**。
2. **定位** —— `grep` 现网引用。**别信文档里的文件清单 / 枚举**。
3. **改** —— 单一真相源;新逻辑落进该落的那一层(格式层 / 几何层 / 渲染层 / 会话态分开,见 [`CLAUDE.md`](CLAUDE.md) 的架构索引)。
4. **守卫** —— 每条新断言都要答得出「**去掉什么它才会红**」;答不出就别写。
5. **验证** —— 按档位做(下表);判据**一律 grep 文本**(该支自打的 `OK` / `ALL-OK`),不看退出码。
6. **登记** —— 每条守卫在注释里写清「最强保证是什么、测不到什么」;本轮不修的边界写进 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)。
7. **提交** —— **逐个文件点名 `git add`**(新建 `.gd` 连 `.gd.uid` 一起加;`.tscn` 不用),**绝不 `git add -A`**。提交信息 `type(scope): 中文一句话`。

### 改动分档

| 档 | 什么算这一档 | 必做 | 免做 |
|---|---|---|---|
| **1 · 皮** | 文案、颜色常量值、版式 / 间距、纯表现参数 | 人眼对比 | 变异验证、评审 |
| **2 · 单系统** | 一个子系统内的逻辑(敌人 AI / 武器手感 / UI 数据流 / 单机玩法),**不动协议与存档** | 纯逻辑 `-s` + 相关场景探针;**至少一条**承重断言的变异验证 | 真链路跑批、逐任务评审 |
| **3 · 承重面** | 协议 / 输入包 / 回滚与快照 / 存档与地图格式 / 导出与裁剪 / 命中与碰撞判定 / 联机权威 | 上面全部 + **每条承重断言**逐条变异验证 + 真链路跑批 + **逐任务评审** | —— |

- 变异验证按档分级:档 1 免;档 2 至少一条(挑这次最承重的);档 3 逐条。**不确定就往上取一档。**
- 档 3 的「逐任务评审」= 每个任务做完先审再进下一个。
- ★ 默认批里**一支也不开端口、一支也不拉子进程**,真链路批只有 [`tests/run_real.sh`](tests/run_real.sh) 那几支 ⇒ **手感 / 观感 / 数值 / AI 行为只能靠人眼与试玩**。

### 守卫规矩

- **先答三问,任何一问答不出就停手**:① 去掉什么它才会红?② 它挡的是哪一种"真实发生过或极可能发生"的缺陷?③ 它在行为上可观测吗(只能读源码文本判形态 ⇒ 不写)?
- **桶由「要什么资源」决定**,永远选能证明它的最小那一档:

| 桶 | 资源边界 | 本仓形态 |
|---|---|---|
| **冒烟** | 单进程;不碰网络 / 磁盘 / 真实例化场景;`autoload` 尚未实例化 | `tests/smoke/*.gd`(`extends SceneTree`,`-s`) |
| **探针(场景)** | 单机、真场景树:真实例化 `.tscn`,走 `_ready` / 信号 / 资源加载 | `tests/probe/*.tscn` |
| **真链路** | 跨进程 + 真端口 + 真协议 | `tests/{smoke,probe}/*.sh` |

- **需要人眼的(配色 / 版式 / 手感 / 观感 / "好不好玩")都不写** —— 守卫在这里没有意义。
- **不写清单**:恒真 / 零断言只 `print("OK")` / 钉死会被反复调的数值与时序 / 与别处同源重复 / 只证明引擎或第三方库 / 读源码文本判形态 / 单文件 > 600 行且断言密度低 / 一条判定类别拆成 N 条"一个数值一条"。
- **一条判定类别 = 一条守卫**;越高层越少。**新守卫必须自带条数闸**(`EXPECTED_CHECKS` / `_checks >= N`),否则它的 `ALL-OK` 只等于"没有失败输出"([`tests/lib/probe_base.gd`](tests/lib/probe_base.gd) 文件头)。
- **单一真相源优先于守卫**:同一个值要抄两处时先上生成式,别再补一条盯漂移的守卫。两个范本:`level_editor/sync-enemies.js --check`(只校验不写盘,漂移退出 1)、`tools/gen_menu_theme.gd` → `ui/theme/menu_theme.tres`。
- **加守卫必须能说出它挡的缺陷**;答不出按违规处理。

**完成标准**(缺一条就不算完):

- 新断言答得出"去掉什么才红",**且按档位做了变异验证**;
- 每个"改了 A 就会过期"的 B(注释里的清单、写死的数量、按钮文案、文档里的路径)都 **`grep` 过并同步改掉**;
- 已知边界 / 覆盖上限**落在纸上**(代码注释或 [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md)),而不是只在对话里说过。

## 3. 硬规则

**判据与守卫**

- ★★ 「grep 到 `ALL-OK`」**只证明没有任何断言失败,不证明每条断言都跑过**:脚本错误只结束出错的那个函数、调用方继续 ⇒ 后面静默跳过,verdict 照打 `ALL-OK`。新场景探针用 `_checks >= EXPECTED_CHECKS` 堵它;权威表述在 [`tests/lib/probe_base.gd`](tests/lib/probe_base.gd) 文件头。
- **退出码从来不是判据**;要退出码就**别接管道**(`| tail` 报的是 `tail` 的退出码)。
- `-s` 冒烟**必须写空载守卫**(`load()` 后立刻 `if X == null: print(...); quit(1); return`),否则抛错后走不到 `quit()`,进程**永久挂起**;跑新冒烟一律套外层 `timeout`。
- 场景探针的 `--quit-after` 给足(统一 3600):给少了会在负载重时先耗尽,而**安全网耗尽与真失败在输出上长得一样**。
- **「守卫能给的保证总是比它读起来少」**:恒真断言、查子串不查分支、探针够不到承重分支、在出厂默认下恒真都是本仓出现过的形态;通用检查法见 [`docs/eng/tests.md`](docs/eng/tests.md) 末节。

**协作(本机常有多个会话同时改同一个仓库)**

- ★★ **共用工作树**:逐个文件 `git add` 只保证"不带走别人的**文件**",**不保证不带走别人在同一文件里的 hunk**。提交前 `git status --short` + 逐文件 `git diff` **认领每个 hunk**;不属于本次改动的不提交、也不"顺手修一下"。
- `CLAUDE.md` **由协调者统一维护**;实现类任务不要顺手重写它。
- 视觉验收:**看图判断,不要把对比度当验收标准**。

**环境小口径**

- `.uid` 口径:跟踪 `*.gd.uid` / `*.gdshader.uid`;**`*.tscn.uid` 零跟踪**。
- 命令行开关(`--worker` 之类)必须写在 **`--` 之后**(`server_main.gd` 读 `OS.get_cmdline_user_args()`);写在前面会被 Godot 丢掉并**静默跑错分支**。
- 要进导出包的脚本**禁用 `RegEx`**(裁剪模板 `module_regex_enabled: false` ⇒ 整个脚本解析失败,而编辑器里全绿)。
- 同一个量是**乘子**还是**浓度**,把方向写进注释与派发。
- `.ps1` 必须 **CRLF**;编码 =「**纯 ASCII 或带 UTF-8 BOM**」。`.bat` 同样必须 **CRLF**,编码不查。两者都由 `.gitattributes` 的 `eol=crlf` + `python tools/check_naming.py` 的**规则 E**逐文件守(红了用 `rm <file> && git checkout -- <file>` 重新落盘,纯 EOL、不动内容);PowerShell 起带空格的路径要**手工内嵌双引号**。
- **噪声与信号分不清时:同配置跑两次**。

## 4. 去哪查(指针)

| 想查什么 | 去哪 |
|---|---|
| 架构、参数体系、网络协议、敌人 / 武器 / UI / 渲染的域细节 | [`CLAUDE.md`](CLAUDE.md) 是索引 → 按域读 [`docs/eng/`](docs/eng);域的真相源 = `ls docs/eng/*.md` |
| 既有红 / 待还的债 / 已裁定不做 | [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md) |
| 发布、裁剪模板、版本号、产物冒烟 | [`RELEASE.md`](RELEASE.md) |
| 目录分层、操作、PvP 规则要点 | [`README.md`](README.md) |
| 测试分层与跑法 | [`tests/README.md`](tests/README.md)、[`tests/env.sh`](tests/env.sh) 的注释 |
| 策划案(时间机制 / 肉鸽成长 / 数值 / 音美) | [`docs/CyR单人模式主策划案(1).md`](<docs/CyR单人模式主策划案(1).md>) |
| PvP 网络设计 | [`docs/pvp-networking.md`](docs/pvp-networking.md) |
