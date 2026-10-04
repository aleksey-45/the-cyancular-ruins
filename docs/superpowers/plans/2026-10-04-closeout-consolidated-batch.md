# 收尾批:§2 剩余 **12 个原子任务** 合并成 **5 个工作包** 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> ★★ **本计划是"合并执行"的**。用户裁定:**全做**,但**减少子代理数量**、**相似任务排同一个做**、**别拆那么细**。
> 因此把四份计划里剩余的 12 个原子任务按「**同文件 / 同族 / 同档位**」合并成 5 个工作包。
> **原子任务的内容一个字都没少** —— 少的是**派发次数**(以及随之而来的评审座位数),不是要求。
> ★ 原计划(`reflection-and-input-fallback` / `server-input-sanitize-and-queue` / `rpc-channel-split` / `aggregate-regression-entry`)
> 已各自加了"剩余任务已并入本计划"的横幅;**别再按它们派发**,否则会重复执行。

**Goal:** 把 `docs/eng/audit-2026-10-04-design-conventions.md` §2 里剩下的"与主流规范正面冲突"逐条收口:
反射家族的最后一片、两处**实测的**回溯保真缺陷、服务端无条件相信客户端输入、60 条 `@rpc` 挤在一个通道上,
外加一个**聚合回归入口**让上面这些每条都有便宜的红/绿判据。

**Architecture:** 五个工作包各自**单一主题、单一评审面**:
① 测试与流程工具(纯新增,不动产品代码);
② **回溯里武器快照的往返保真**(单机生产端 `_equip_index` + PvP 生产/写回端 `match_host.gd`);
③ 反射清理收口(`pvp_haste_mult` 注入化 + `pvp_match_client` 对象反射 + 敌人/子弹快照段);
④ 服务端收口客户端输入(钳位 + 有界可抽干的队列);
⑤ RPC 按流量类别分流。
**顺序按"先拿到判据、再改承重面、最后动传输层"排**,理由见下面「执行顺序与真链路批」。

**Tech Stack:** Godot 4.7.1 标准版(非 mono)、GDScript、`tests/` 的冒烟/探针/真链路跑批、Git Bash 脚本壳。

**Spec:** [`audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.1/§2.2/§2.3/§2.4/§2.5/§2.6/§2.9/§2.10/§2.11
+ 用户裁定("全做、减少子代理、相似任务合并")+ [`registered-debt.md`](../eng/registered-debt.md)(§六.7 / §六.12 / §六.13 / §六.14 / §六.15 / §六.16 / §七)
+ [`tests.md`](../eng/tests.md) 的判据纪律。

---

## 合并映射表(12 → 5)

| 本计划 | 原计划 | 原任务 | 为什么能合并 |
|---|---|---|---|
| **Task 1** | `aggregate-regression-entry` | T1 + T2 + T3 | 三件都是**同一批纯新增工具**(入口 + 闸 + 登记),同一评审面,互不冲突 |
| | `reflection-and-input-fallback` | T14 | 纯探针读数修复,**同属测试工具**;且它要"连跑两次逐字节相同"的前提正是 Task 1 Step 3 的全量跑 |
| | (控制器追加) | `start_server.bat` 端口模式缺口 | 一行字面量;与 Task 1 的**端口纪律**同族(`run_real.sh` 的收尾就靠它)。缺口由该文件自己的注释点名(`start_server.bat:11-12`) |
| | (控制器追加) | `unsafe_*=2` 试跑 | **试跑只报告、不修**:它是"反射清完后还剩多少反射"的唯一量化判据,必须在 Task 1 的入口建好之后才做 |
| **Task 2** | `reflection-and-input-fallback` | T5 + T4 | **同一段往返**:T5 是实测的行为缺陷(`wlive` 被 `_ready` 冲掉、走掉那把的条目被反向冲掉),T4 是**同一条链路**上 `player.get("weapons")` 的反射。原计划自己写着"独立改它会留半状态" |
| **Task 3** | `reflection-and-input-fallback` | T10 + T11 + T12 | 同一族(字符串反射 → 类型化/注入);★ 且 **T10 与 T11 在 `scenes/pvp_match_client.gd:215` 上重叠**(T10 的"一处写"就是 T11 七处里的一处)⇒ 不合并就会同一行改两次 |
| **Task 4** | `server-input-sanitize-and-queue` | T1 + T2 | 同一个文件的**同一个原则**的两半(服务端是权威),共用同一个探针 |
| **Task 5** | `rpc-channel-split` | T1 | 本来就是 1 个任务;★ **不并进 Task 4**:它动 60 处声明 + **传输语义**,原计划自己标注"本批最危险的一步",与 Task 4 混在一起会让真链路红时**无法归属** |

## 合并的代价(诚实边界,别自欺)

- 评审粒度 = **工作包**,不再是原子任务 ⇒ 一个工作包里若出问题,**回退粒度也是工作包**。补偿 = 报告里**必须逐原子任务分节**(见每包的"报告分节"要求),可追溯性不丢。
- 真链路批 **4 → 2**(只在工作包边界跑,不逐任务跑)。★ 覆盖**没少**(跑的是包含两侧改动的**合并状态**,是超集),少的是**归属**;而归属由**每包先评审、后跑批**的顺序兜住。
- 派发次数 12 → 5,评审座位 12 → 4(Task 1 是档 2,免逐任务评审)。

## Global Constraints(所有工作包都受这些约束)

- **档位按 `AGENTS.md` §2 的表定,不照抄任何原计划里的档**:判据是「**改坏了多久才发现**」,一处改动触及多档就**取高档**。
  - **档 3**(协议 / 输入包 / 回滚与快照 / 存档与地图格式 / 导出与裁剪 / 命中与碰撞 / 联机权威)⇒ 纯逻辑 + 场景探针 + **每条承重断言逐条变异** + **真链路跑批** + **逐任务评审**。
  - 档 2 ⇒ 纯逻辑 + 相关场景探针 + **至少一条**承重断言变异;免真链路、免评审。
- ★★ **判据一律 grep 文本**(`SMOKE OK` / `ALL-OK` / 真链路脚本判词),**退出码从来不是判据**。
  每个新场景探针用 `_checks >= EXPECTED_CHECKS` 条数闸堵「脚本错误只结束出错那个函数、verdict 照打 ALL-OK」。
- ★★ **每条新断言都必须答得出「去掉什么它才会红」**;答不出就别写。★ **红在"哪条断言"上**要和"该红"对上(变异日志要写清,不能只写"红了")。
- ★★ **「守卫能给的保证总是比它读起来少」**:写完守卫后自问一遍"它是恒真吗 / 它查的是子串还是分支 / 探针够不够得到那条承重分支";**覆盖上限必须落在纸上**(代码注释或 `registered-debt.md`),不能只在报告里说过。
- ★★ **真链路纪律**([`AGENTS.md`](../AGENTS.md) §1):任何会占 7777 的步骤**先查 `lobby_alive`**(为真 ⇒ 跳过并报告);跑批**前后** `tasklist | grep -i godot` 必须为空(**worker 是孙进程**,孤儿会毒占端口);收尾用 `tests/env.sh` 的 `kill_port_range 7800 8300`;★ **池外两支**(`rejoin_probe.sh` / `team_match_probe.sh`)**一律不扫**该区间(实现事实)。**先列测试请用户认领**(用户已授权 agent 自跑)。
- ★ **跑批环境要写进结论**:多进程抢 CPU 会放大换场卡顿;时序类结论**同配置跑两次**再下;报告附**关键行原文**+日志位置。
- **逐个文件点名 `git add`**(新建 `.gd` 连 `.gd.uid` 一起加;`.tscn` 不用),**绝不 `git add -A`**;提交前 `git status --short` + 逐文件 `git diff` **认领每个 hunk**(共用工作树,别带走别人的改动)。
- 提交信息 `type(scope): 中文一句话`。★ **不准把本批动机写成"反作弊"**(用户已裁定不承担,见 §七)。
- ★ **文档会过期**:任何一处与源码冲突**以源码为准**,并顺手订正那处;原计划里的行号**一律先 `grep` 复核再用**。
- ★ 打印到控制台的东西**只许 ASCII**(本机控制台是 GBK,中文/`⇒`/`✓` 会把脚本打崩);文件内容可以是中文。
- ★ **穷尽式清单必须 `grep` 现网验证**(本仓被"枚举会过期"咬过多次),**别信本计划或任何文档里的行号/文件清单**。

## Review Focus(合并后新增的注意点)

1. **合并有没有把"两个独立决定"粘成一个**(Task 2 / Task 3 最像):如果实现者把 T4 的反射改动和 T5 的行为修复搅在一起、报告里分不清哪条断言属于哪一半 ⇒ **评审要按"逐原子任务分节"退回**。
2. **重叠行只许有一个归属**(Task 3 的 `pvp_match_client.gd:215`;Task 2 的 `world_rewind.gd:95`):报告必须点名"这一行由哪个原子任务负责、另一个任务为什么不再碰它"。
3. **别把"合并"当成"可以顺手多改"**:每个工作包**只做列出的原子任务**;发现的别的问题**登记 / 报告**,不顺手修。
4. **档 2 的 Task 1 里混进了 4 件事**(入口 / 读数修复 / 一行 `.bat` / 试跑登记)—— 后三件都是**小改**,但**每一件都要有自己的"能红"证据**(读数修复靠"改前 `<null>` → 改后 `true/false` + 两次跑逐字节相同";`.bat` 靠 `check_naming.py` 规则 E + 实测 `findstr` 命中;试跑靠"还原后 `project.godot` 不脏")。

---

### Task 1: 聚合回归入口 + 测试工具收口(档 2)

**这一包解决什么:** 本仓**没有 CI、也没有聚合回归入口** —— 判据靠逐脚本自造文本行、靠人记得跑哪些。先把入口建起来,
后面四个工作包每条改动才有一份**便宜的**红/绿判据;顺手把三件**测试/流程**上的小账还掉。

**合并自:** `aggregate-regression-entry` T1/T2/T3 + `reflection-and-input-fallback` T14 + 控制器追加的两件(`start_server.bat` 端口模式、`unsafe_*=2` 试跑)。

**Files:**
- Create: `tests/run_all.sh`(headless 默认批入口)
- Create: `tests/run_real.sh`(真链路批入口,带认领闸)
- Modify: `tests/README.md`(加"聚合入口"一节:判据、边界、"哪些**不**在默认批里、为什么")
- Modify: `AGENTS.md`(§1 跑法清单加一条 ★ **定点改**,别整段重写)
- Modify: `tests/probe/climb_probe.gd`(T14:死读数)
- Modify: `start_server.bat`(端口模式缺口,★ **必须保持 CRLF**)
- Modify: `docs/eng/registered-debt.md`(§六 加"无 CI"的现状与翻案条件;加 `unsafe_*` 试跑结果)

**Interfaces:**
- Consumes: `tests/env.sh`(`$GODOT` / `kill_port_range` / `lobby_alive`);`tests/smoke/*.gd`(`-s`,判词 `SMOKE OK`);`tests/probe/*.tscn`(`--quit-after 3600`,判词 `ALL-OK`);`tests/scripts/*.sh`(真链路)。
- Produces: `bash tests/run_all.sh` ⇒ 逐文件一行表格 + **唯一判词**(形如 `RUN_ALL OK(n 支 / m 断言)` / `RUN_ALL FAIL(k 支)`)+ 失败清单 + 每支的日志路径。
  `bash tests/run_real.sh [--yes]` ⇒ 先打印清单/端口/预计耗时 ⇒ 交互确认后逐个跑并按纪律收尾。

**Steps:**

- [ ] **Step 1: 分桶(先取证,别照抄目录名)**
  Run: `for f in tests/smoke/*.gd; do echo "$f: $(head -3 "$f" | tr '\n' ' ')"; done`
  Run: `ls tests/probe/*.tscn`
  Run: `grep -rln "lobby_alive\|7777\|get_cmdline_user_args" tests/smoke tests/probe`
  Run: `grep -rn "^extends\|--headless\|--quit-after" tests/smoke/*.gd tests/probe/*.gd | head -60`
  ★ **"headless 安全"按"该文件的跑法"分,不按目录名**(`extends SceneTree` + `-s` = 安全;`extends Node` + `.tscn` = 安全但慢;
  **非 headless 取图 / 占端口 / 多进程真链路** = 不进默认批)。
  ★ 产出**三个清单**写进报告:**默认批** / **排除(及原因)** / **真链路**。
  ★ 探针里 `EXPECTED_CHECKS` 有的要抄下来(默认批表里要有一栏"期望条数",对不上要单列)。

- [ ] **Step 2: 写 `tests/run_all.sh`(先写成"能红"的形状)**
  遍历默认批 → 每个套 `timeout` → **捕获输出到临时日志** → 从日志里 `grep` 判词 → 汇总表格。
  ★ **别**用 `| tail` 取判词(要留全文日志,并把**日志路径打进表里**);★ 任一 FAIL ⇒ 退出码非 0;
  ★ 顺手打印"环境口径":`$GODOT` 版本行、`lobby_alive`、跑前 godot 进程数。
  ★ 表里至少三栏:**文件 / 判词(原文) / 期望条数对得上吗**。
  ★★ **必须自动枚举**(`tests/smoke/*.gd` + `tests/probe/*.tscn` 用 glob),**不许把文件清单写死**:
  后面几个工作包会**新增探针**,写死的清单会让新探针**永不进默认批**,而入口照样打 OK(R1)。
  排除项走**显式清单 + 每条理由**;并打印"**枚举到 N 支**",防止 glob 静默空转仍报 OK。

- [ ] **Step 3: 第一次全量跑**
  Run: `bash tests/run_all.sh`(★ 可能几分钟;**全程 headless,不弹窗、不占 7777**)
  ⇒ 表格与判词原文写进报告;★ **任何一支红都如实列出**(可能是**既有红**,本包不负责修,但要登记进 `registered-debt.md` 或报告)。
  ★ 这一步的输出**同时**是 Task 1 后续三件小事的基线。

- [ ] **Step 4: 自检(入口不是装饰品的唯一证据)**
  造一个临时必败测试(例:`tests/smoke/_tmp_always_fail.gd`,打印 `SMOKE FAILED: 自检`)⇒ 入口必须 **FAIL、退出码非 0、在表里点名它**;删掉临时文件 ⇒ 回到 OK。两步输出都进报告。

- [ ] **Step 5: 写 `tests/run_real.sh`(认领闸)**
  ① `lobby_alive` 为真 ⇒ **拒绝并打印**"7777 上有活大厅,先停它";② 打印清单 + 每支的端口/耗时估计;
  ③ 无 `--yes` 且 stdin 非交互 ⇒ **拒绝**并提示手动跑;④ 跑前/跑后 `tasklist | grep -i godot` 必须为空(有残留 ⇒ 打印并非 0 退出);
  ⑤ 收尾 `kill_port_range 7800 8300`(★ **只对池内那几支**;池外 `rejoin_probe.sh` / `team_match_probe.sh` 一律不扫)。
  ★ 先 `head -20` 逐支读头注取证(占什么端口、多久、判词是什么),产出"顺序表"写进报告。
- [ ] **Step 6: `run_real.sh` 自检** —— 构造 `lobby_alive` 为真(或先起假大厅)⇒ 必须**拒绝**;让某一支失败(临时改判词期望)⇒ 汇总必须 FAIL 并点名;复原。★ **不要**在这一步跑真链路(真链路在 Task 2/3 与 Task 4/5 的边界跑)。

- [ ] **Step 7: T14 —— `climb_probe` 的 `latched` 死读数**
  ★ 事实(已实测 6 次):`tests/probe/climb_probe.gd` 的两处打印读的是 `p.get("_latched")`,而该字段**不在玩家根上**
  (它在 `scenes/player/climb_component.gd`;根只转发 `is_latched()`)⇒ 恒打 `<null>`,"是否攀附"这一维**从来没有读数**。
  ★ 先例:`tests/probe/squash_host_water_probe.gd:285` 怎么读同一状态(照抄形状)。
  ★ 改前**先确认那个属性在探针的运行形态下可达**:若探针只造了个**裸宿主**、根本没有 `climb` ⇒ **停下报告,别硬改**。
  ★ 证明读数真变了:改前 `latched=<null>` → 改后 `latched=true/false`,**连跑两次逐字节相同**(★ 该探针的地图已钉在 `res://maps/demo.cyrm`,见 `c5804f4`,所以这条现在做得到)。
  ★ 覆盖上限写进报告:`climb_probe` **仍不是守卫**(无断言、无条数闸),本步只让那一维**可观测**。

- [ ] **Step 8: `start_server.bat` 端口模式缺口(一行)**
  ★ `start_server.bat:37` 的 findstr 模式只覆盖 `:78xx` / `:79xx`,杀不到 **8000~8299** 的僵尸 worker(缺口由 `:11-12` 的注释自己点名,并给了待修写法 `:8[0-2][0-9][0-9]`)。
  ★ **必须保持 CRLF**:改完跑 `python tools/check_naming.py`(规则 E 会红就说明 EOL 被写坏了;红了用 `rm <file> && git checkout -- <file>` 重来)。
  ★ **证明它会红**:把模式改回旧写法 ⇒ 造一个"占 8000"的假场景下 `findstr` 应当**不漏**才行 —— 做不到完整场景就**至少**把"新旧两条 `findstr /r` 对同一份 `netstat` 样本的命中差"贴进报告(样本用真实 `netstat -ano -p UDP` 输出,别手编)。
  ★ 改完把注释里那段"⚠ 已知缺口"改成"已修 + 提交号",**别留着过期的话术**。

- [ ] **Step 9: `unsafe_*=2` 试跑(**只报告、不修、必须还原**)**
  ★ 动机:`AGENTS.md` 记过"未知成员在 `class_name` 类型上只是 **warning**(`UNSAFE_*`)"。若把它升成**错误**,反射一复发就是硬红 —— 这是"反射清完还剩多少"的唯一量化判据。
  ★ 做法:`project.godot` 里试加 `debug/gdscript/warnings/unsafe_property_access=2` / `unsafe_method_access=2` / `unsafe_cast=2` / `unsafe_call_argument=2`,跑 `bash tests/run_all.sh`,把**红的支与报错原文**记进报告与 `registered-debt.md`。
  ★ **然后无条件把 `project.godot` 还原**(`git diff project.godot` 必须为空),本包**不**替用户拍"要不要开"。★ 顺手写下"哪些红是**改得掉**的、哪些是引擎/第三方形状改不掉"的分类 —— 用户要的就是这个数据。

- [ ] **Step 10: 文档**
  `tests/README.md` 加一节(判据、边界、**默认批不含真链路** ⇒ "默认批绿 ≠ 真链路绿");`AGENTS.md` §1 定点加一行;
  `registered-debt.md` §六 加"无 CI"的现状与**翻案条件**(上 CI 需项目级决策:Windows + 两个 Godot 绝对路径 + `.bat`/`proc_util.gd` 有 Windows-only 分支;`tests/run_all.sh` 已经是能被 CI 直接调用的形状)。★ **不要**在没有用户裁决的情况下新建 `.github/`。

- [ ] **Step 11: 提交**(可能不止一个提交,逐文件点名 `git add`;新建 `.sh` 无需 `.uid`)
  ```bash
  git add tests/run_all.sh tests/README.md AGENTS.md
  git commit -m "test: 加聚合回归入口 tests/run_all.sh(headless 默认批:逐文件判词表 + 唯一判词)"
  git add tests/run_real.sh tests/README.md
  git commit -m "test: 加真链路入口 tests/run_real.sh(lobby_alive 闸 + 前后进程检查 + 端口回收;非交互拒绝)"
  git add tests/probe/climb_probe.gd start_server.bat docs/eng/registered-debt.md
  git commit -m "fix(test,proc): climb_probe 读回真实攀附状态;start_server.bat 清理覆盖 8000~8299;登记无 CI 与 unsafe_* 试跑"
  ```

**报告分节要求:** `Step 1 分桶三清单` / `run_all.sh 首跑表格+判词原文` / `自检两步输出` / `run_real.sh 闸的自检` / `T14 改前后读数` / `.bat` 命中证据 / `unsafe_*` 试跑红单 + 还原证据。

---

### Task 2: 回溯里**武器快照的往返保真**(单机 + PvP,★ 档 3)

**这一包解决什么:** 回溯写下的弹量在两条路径上会被**活的游戏逻辑**冲掉(实测,非本次引入);而这条链路上还剩一处
字符串反射(`player.get("weapons")`),它与那两条缺陷是**同一段往返**,分开改必然留半状态。

**合并自:** `reflection-and-input-fallback` T5(两处实测缺陷)+ T4(PvP 生产端/写回端反射 + `world_rewind.gd:95`)。
★ **档 3**(「回滚与快照」在档位表里是承重面)⇒ 逐条变异 + 真链路跑批 + 逐任务评审。

**Files:**
- Modify: `scenes/player/player.gd`(`_equip_index` 一带 —— 先 `grep` 复核)
- Modify(必要时): `scenes/weapons/weapon_component.gd`
- Modify: `core/sim/world_rewind.gd`(`:95` 的 `player.get("weapons")` + 该文件里所有 `get(`/`set(`/`call(` 的**玩家武器段**)
- Modify: `server/match/match_host.gd`(`:402-413` / `:455-465` 一带 —— 先 `grep` 复核)
- Modify: `tests/probe/rewind_weapon_probe.gd`(断言所在;现 `EXPECTED_CHECKS = 61`,加断言要同步四处计数口径)
- **不要改语义**: `tests/harness/royale_bound_watcher.gd:230` 与两个探针直调点**在读同一处** —— 先 `grep` 找齐,只报告/适配,别顺手改它们的行为

**Interfaces:**
- Consumes(实测原文,证据文件 `.superpowers/sdd/2026-10-04-reflection-and-input-fallback/task-1-report.md` §发现A(:116-129)/ §发现B(:130-136),**先读它,别照抄本段的数字**):
  - **A 切枪帧**:`_equip_index` 用 `call_deferred` 入树 + 先置 `pending_mag`(条目值)⇒ 回溯写下的 `live2.mag_ammo = wlive` 被 `_ready` 冲掉
    (仪器:切枪帧 mag=**9** → 入树后 **4** → 下一帧 **9**;★ 若最后一次 `rewind_restore` 正落在切枪帧,错值要等下一次回溯才被再写一遍)。
  - **B 走掉那把**:`_equip_index` 会把**走掉那把**的实弹出膛值写回条目(`weapon_component.gd:236-237`),而这发生在 `rewind_restore` 的"写条目"循环**之后**
    (仪器:`wmags=[11,1]` / `widx=1` ⇒ 切枪后实得 `held[0].mag=3`,`held[1].mag=1`)。
- Produces: 回溯后**弹量与快照逐字段一致**(含切枪帧与跨武器两种情形);该链路上**字符串反射 0 处**。

**★ Ruling(语义,控制器定;实现者别自己另选一套):**
> **回溯 = 逐字段回到快照记录的值**。`wlive`(当前枪的运行时弹量)与 `wmags`(各槽条目)**各自照抄快照**,
> 二者在快照时就允许不同(条目只在切枪/丢弃时同步,开火只扣 `mag_ammo`)。因此
> **任何"从条目推导当前枪 / 从当前枪写回条目"的动作,都不许在恢复之后把已恢复的值改掉** ——
> 要改的是**语句序或写入时机**(例:走 `WeaponComponent.apply_mag` / 让 `_ready` 不覆盖已回溯的值 / 把写回排在恢复之前),
> **不是**"挑一个量当权威、把另一个丢掉"。
> **代价(写错的后果):** 若实现者选了"以条目为准",切枪帧的弹量会静默回到旧值 —— 这正是发现 A;症状是"回溯后弹量偶尔不对",真链路才看得见。

- [ ] **Step 1: 定位** —— `grep -n 'get("\|set("\|call("' core/sim/world_rewind.gd server/match/match_host.gd scenes/player/player.gd`;
  弄清每个成员**属主**与**读写方向**(谁是生产、谁是写回),并数清 `player.get("weapons")` 一族**到底有几处**(★ 别信本计划的两处:自己 grep)。
- [ ] **Step 2: 先写"能红"的断言(档 3 ⇒ 优先行为,形状作副判据)**
  在 `tests/probe/rewind_weapon_probe.gd` 里把 **A / B 两组实测数字**变成断言(切枪帧与跨武器两种情形)。
  ★ 若现有 28 条功能断言**已覆盖**这两种情形却仍绿 ⇒ **报告**(说明它们没测到点上),别硬凑。
  ★ **先证明它会红**:把两组数字写成断言后**在改代码之前**跑 ⇒ 必须红在**这两条**上。
- [ ] **Step 3: 修 A / B**(按上面的 Ruling)⇒ 绿。★ `rewind_weapon_probe` 的**旧断言**要继续绿;若某条旧断言钉的**正是错行为** ⇒ 改它并**说明理由**(写进报告)。
- [ ] **Step 4: 清那族反射** —— `world_rewind.gd` 的玩家武器段 + `match_host.gd` 两段,改**类型化/点访问**:
  ★ 同文件 `world_rewind.gd:105` 已有先例(`var wc := player.get("weapons") as WeaponComponent` + `push_error` + `return d`);
  ★ 守卫形状:该文件那几段的 `get("`/`has_method(` **计数降到 0**(★ 别用 `contains("weapons")` 这种会被字典键骗过的写法 —— `§六.15 / Task 15` 的 G-1 实测就是栽在这上面);
  ★ **先证明它能红**:把某个成员名改成带后缀的假名 ⇒ 目标断言必红(用 `_has_member_token` 那套完整成员名 + 边界判定,别退回 `contains`)。
- [ ] **Step 5: 绿 + 逐条变异**(档 3:每条承重断言各来一次;变异日志写清"红在哪条断言")
- [ ] **Step 6: 真链路** —— ★ **本包与 Task 3 共用一批**(见「执行顺序与真链路批」)。先列测试请用户认领;按 §1 纪律跑;收尾 `kill_port_range 7800 8300`;关键行原文进报告。
- [ ] **Step 7: 登记** —— `registered-debt.md` §六 里那两条(发现 A / 发现 B)从"未修"改口为"已修 + 提交号";`§六.13`(weapon 子字典端到端缺口)按实况更新。
- [ ] **Step 8: 提交**(单文件点名;提交信息带"回溯/快照"字样)
  ```bash
  git add tests/probe/rewind_weapon_probe.gd scenes/player/player.gd scenes/weapons/weapon_component.gd
  git commit -m "fix(rewind): 回溯后弹量不再被 _ready 与切枪写回冲掉(两处实测缺陷)+ 行为断言"
  git add core/sim/world_rewind.gd server/match/match_host.gd
  git commit -m "refactor(rewind): 武器快照往返改用类型化访问(去掉 player.get(\"weapons\") 一族字符串反射)"
  git add docs/eng/registered-debt.md
  git commit -m "docs(debt): 两处回溯保真缺陷改口为已修(附提交号)"
  ```

**报告分节要求:** `A/B 两处定位与实测复现` / `新断言(先红证据)` / `修法与语义理由` / `旧断言是否被改、为什么` / `反射清零的计数与逐条变异` / `真链路` / `债单改口`。

---

### Task 3: 反射清理收口(★ 档 3)

**这一包解决什么:** 反射家族剩下的三片 —— `pvp_haste_mult` 那族的参数注入化、`pvp_match_client.gd` 的 7 处对象反射、
`world_rewind.gd` 里**敌人/子弹**快照段的同族反射。★ **T10 与 T11 在 `scenes/pvp_match_client.gd:215` 上重叠**,必须一次决定。

**合并自:** `reflection-and-input-fallback` T10 + T11 + T12。★ 档 3(T12 触及**回滚与快照**⇒ 取高档)。

**Files:**
- Modify: `scenes/player/swim_component.gd`(`:39` 一带)、`scenes/player/climb_component.gd`(`:133` 一带)、`scenes/weapons/weapon_base.gd`(`:367` 一带)
- Modify: `scenes/player/player.gd`(`:182` 属主;`:255` 是 `swim.update` 的调用点)
- Modify: `scenes/pvp_match_client.gd`(7 处对象反射 + `pvp_haste_mult` 的**那一处写**)
- Modify: `core/sim/world_rewind.gd`(敌人/子弹快照段)
- Modify: `tests/probe/rewind_weapon_probe.gd` 或既有 PvP 探针(断言所在)

**Interfaces:**
- Consumes(★ 全部**先 grep 复核**,行号会过期):
  - **T10**:`swim_component.gd:39`(`parent: CharacterBody2D`)/ `climb_component.gd:133`(`body: CharacterBody2D`)/ `weapon_base.gd:367`(`player: Node2D`)读 `pvp_haste_mult`;`pvp_match_client.gd:215` 写它。属主 = `player.gd:182`。
    ★★ **但"三读一写"是不全的(控制器派发前实测,见账本 R4)**:另有两个**类型化直读/直写**——
    `server/match/match_snapshot.gd:30` 读它(序列化进快照),`server/match/match_host.gd:223` **写它**(服务端权威每帧设倍率),
    加上属主自己 `player.gd:191` 也读。⇒ **验证目标**:服务端那一写**必须继续生效**(否则权威设的倍率静默失效,单机/探针全绿、真链路才现形)。
    ⇒ **实现者自己 `grep -rn "pvp_haste_mult" --include=*.gd .` 把读写点列全**(别照抄本段的数字),报告里逐点说明"改不改、为什么"。
  - **T11 七处**:`pvp_match_client.gd` 的 `:215`(写 `pvp_haste_mult`)/ `:230`(`is_downed`)/ `:234` `/` :240`(`input_source`)/ `:236` `/` :242`(`frozen`)/ `:294`(`animator`),全打在 `_local`(`Node2D`)上。
  - **T12**:`world_rewind.gd` 的敌人/子弹快照段(`.get("velocity")` / `.call("rewind_state")` / `.get("hit_damage")` …);`scenes/enemies/enemy_base.gd:1` **已有 `class_name EnemyBase`**。
- Produces: 三片反射**清零**(形状守卫)+ 倍率**真的生效**(行为守卫)。

**★ Ruling(修法选择,控制器定;依据是实测的爆炸半径,见 `registered-debt.md` §六.12):**
> **不给 player 根加 `class_name`** —— 实测它会当场打掉两个**刻意造裸**的测试桩
> (`tests/probe/water_probe.gd:90-91` 的 `class SwimHost`、`tests/smoke/player_contract_smoke.gd:189-190` 的 `class ClimbHost`,
> 注释写着该字段"为反射而给"),外溢到全局类名(缓存/命名/导出侧)。
> **首选 = 参数注入;`pvp_match_client.gd` 那 7 处不需要 `class_name` 也能点访问**(同文件 `:134` 已有 `_local.weapons.…` 先例)。
> ★★ `:234` / `:240` **不能**简单换成"注入源":同函数 `:236` 会把**同一个** `src.frozen = true` ⇒ **死锁**(§六.7)。
> 这两处的正确做法 = **保留"读宿主自己的 `input_source`",只把反射换成点访问**。

- [ ] **Step 1: 定位** —— 三片逐个看清:宿主类型、是"每次调用都给"还是"一次 bind 之后一直用"、各自调用点;★ 并把 `pvp_match_client.gd:215` 的归属**点名**(T10 的"一处写" = T11 的七处之一,**只改一次**)。
- [ ] **Step 2: 守卫(形状 + 行为,★ 每类先证明能红)**
  - 形状:那三处不再出现 `get("pvp_haste_mult")`;`pvp_match_client.gd` 那 7 处不再出现对象反射。
    ★ **别写成"包含某子串"** —— 用完整成员名 + 边界判定(参考 `rewind_weapon_probe.gd` 的 `_has_member_token`,并在注释里写清它只挡后缀/前缀拼接)。
  - 行为:倍率**真的**生效(改倍率 ⇒ 位移/攀爬速度随之变);★ **权威侧那条路也要有一条**:服务端设的倍率(`match_host.gd:223`)能到达消费点(R4 —— 只测客户端那条会漏掉"服务端那一写变成死代码");敌人/子弹快照**逐字段 == 真值**(优先用既有 rewind 探针的"怪复活 / 子弹回溯"相扩一条)。
- [ ] **Step 3: 改 —— 分步,别一把改(三处形状不同)**
  - `swim.update` ⇒ **加参数** `haste_mult: float = 1.0`;半径 = `player.gd:255` **一行**;两个桩**不用改**(默认值正好覆盖 `water_probe` 的缺 `src` 相);`player_contract_smoke.gd:129` 只查子串、不受影响。
  - `climb:133` / `weapon_base:367` ⇒ 宿主由 `equip` / `bind` **一次给入** ⇒ 要的是"**根每帧推倍率**"的 setter(**不是**构造参数)⇒ **单独一步**,各自配守卫。
  - T11 七处 ⇒ 点访问(先例 `:134`);`:234`/`:240` 按上面的 Ruling。
  - T12 ⇒ 敌人段类型化(`EnemyBase` 已有 `class_name`);子弹段先看有没有 `class_name`,**没有就报告**(加不加 `class_name` 是另一个决定,别顺手加)。
- [ ] **Step 4: 先红 → 改 → 绿 + 逐条变异**(档 3:每条承重断言各来一次;写清"红在哪条")
- [ ] **Step 5: 真链路** —— ★ **与 Task 2 共用一批**(见「执行顺序与真链路批」)。
- [ ] **Step 6: 登记** —— `§六.7`(死锁那条)/ `§六.12`(class_name 爆炸半径)按实况改口或销账;新发现的边界照实写。
- [ ] **Step 7: 提交**

**报告分节要求:** `T10 / T11 / T12 各自定位` / `:215 的归属声明` / `形状+行为守卫(先红证据)` / `分步改法(尤其 setter 那一步)` / `逐条变异` / `真链路` / `债单`。

---

### Task 4: 服务端收口客户端输入(★ 档 3)

**这一包解决什么:** ① 轴值 `ax` **无界**(`ax=50` 在服务端约等于 35000px/s,全图才 9600px);② 输入队列**无上限**、每 tick 只消费 1 包
⇒ 积压不可恢复(服务端自述 ρ=1)。两处都在 `server/match/match_host.gd` 的**消费侧** —— 同一个原则的两半:**服务端是权威**。

**合并自:** `server-input-sanitize-and-queue` T1 + T2。

**Files:**
- Modify: `server/match/match_host.gd`(append 侧 `:186-196` 与消费侧 `:245-255` 一带 —— **先 grep 定位**)
- Create/Modify: 探针(可并入 Task 1 的默认批;★ 先想清该是 `-s`(`extends SceneTree`)还是 `.tscn` 场景探针 —— 集成那条要跑权威回路,大概率是场景探针)
- Modify: `docs/eng/registered-debt.md`(登记边界)

**Interfaces:**
- Consumes: 客户端 `core/net/packet_input_source.gd:121` `_axis = pkt.get("ax", 0.0)` → `:175` `return _axis`(**无界**);
  服务端 `match_host.gd:190` `(_pending_input[role] as Array).append(pkt)`(**无边检/钳位/限速**);
  位移在 `scenes/player/player.gd:373` `var target_velocity_x = horizontal_input * speed_target * mult.x`;
  消费 `:251` `var pkt: Dictionary = q.pop_front()`(**每 tick 一包**)。
- Produces: ① 一个**纯函数** `sanitize_axis(v: float) -> float`(钳到 `[-1,1]`、非有限值 → `0`,便于 headless 断言),在服务端**应用输入前**调用;
  ② 队列**有硬上限**且**积压能被抽干**,丢包策略**保住 `just_pressed` 边沿**。

**★ Ruling / Review Focus(照抄原计划,别自己另发明):**
1. **队列上限的"丢谁"是设计决定**:包里带 `just_pressed` 边沿(`core/net/packet_input_source.gd:6-9` 自陈"走 reliable 是为不丢边沿")
   ⇒ 丢包必须**保住边沿**:合并轴值时把边沿**或**起来(或只丢"既无边沿、又被后一包覆盖"的中间包)。★ 写错的表现是"**偶发丢一跳**",真链路才看得见。
2. **"每 tick 一包"本身可能是对的**:包 60Hz、tick 也 60Hz ⇒ ρ=1 的根因是**开局突刺**(服务端自述"1 秒内 0→8 然后停住")
   ⇒ 可能是"**每 tick 把积压抽干、只应用最后一包**"(输入是**状态**不是命令流)。★ **先量 ρ 再定方案,别照抄"加个上限"**。
3. **上限要能与客户端对上**:丢包会让客户端预测/回滚与服务端**分叉** ⇒ 上限要么足够大(正常网络永不触发),要么配一条"服务端丢过包"的可观测信号供真链路核对。
4. **钳位的方向与口径**:钳到 `[-1,1]`(轴是**归一化**量);`NaN`/`INF` 让它们变 `0`(★ `clampf` 对 `NaN` 的行为**要实测**,别假设);**别顺手改 `mult` 或 `speed_target`**(那是手感,属别的域)。
5. ★★ **本包的动机不是反作弊**(用户已裁定不承担,见 `§七`):是**协议健壮性** —— 版本不匹配、有 bug 的客户端、单机壳里跑出来的包都能让服务端飞出去。**别**在提交信息或注释里写成"反作弊"。
6. ★ **不许改客户端手感**:轴钳位只在**服务端消费侧**;合法输入(`|ax| ≤ 1`)必须**逐位不变**地得到与改前相同的位移。

- [ ] **Step 1: 定位 + 先量 ρ** —— `grep -n "_pending_input\|pop_front\|apply_input\|_axis" server/match/match_host.gd`;
  在探针里构造"每 tick 灌 1 包、跑 120 tick"的回路,**打印改前的队列长度序列**(这是"改前基线",也是"到底修没修好"的判据:改后必须**不随时间发散**)。两条输出都进报告。
- [ ] **Step 2: 写"能红"的断言**
  ① `sanitize_axis`:合法值 `-1/0/1/0.5` **原样**返回(这条是"没改手感"的钉子);`50 → 1`、`-50 → -1`;`NAN`/`INF`/`-INF → 0`(★ `clampf` 对 `NaN` **先实测**再定实现)。
  ② **集成(承重)**:喂一个 `ax=50` 的输入包给权威回路 ⇒ 玩家**不会瞬移**(位移与 `ax=1` 那一帧相同)。
  ③ 队列长度**永不超过上限**(灌 200 包);④ 灌完停 1 秒后队列**排空**(`== 0`,即"有回复力" —— 这条**必红**);
  ⑤ **边沿不丢**:包 A 带 `just_pressed=开火`、其后 5 个包不带 ⇒ 抽干后**必须**恰好观察到 1 次;⑥ 正常速率下**行为与改前逐帧相同**。
- [ ] **Step 3: 跑它,确认红**(①/② 或 ④),原文进报告。
- [ ] **Step 4: 实现** —— `sanitize_axis`(非有限 → `0.0`;否则 `clampf(v,-1,1)`)在服务端应用输入那处调用;
  队列按 Step 1 量出的 ρ 选策略((a) 每 tick 抽干 / (b) 硬上限 + 丢最旧非边沿 / (c) 组合),**报告里说明选哪个、为什么、上限值依据**;★ 只在**服务端消费侧**做。
- [ ] **Step 5: 绿 + 逐条变异**(① 去掉 `clampf` ⇒ ② 红;② 非有限支改 `return v` ⇒ ③ 红;③ 恒等函数 ⇒ ④ 红;④ 上限去掉 ⇒ ⑤ 红;⑤ 抽干改回每 tick 一包 ⇒ ⑥ 红;⑥ 边沿 OR 去掉 ⇒ ⑦ 红;每条复原并记录"红在哪条断言")。
- [ ] **Step 6: 真链路** —— ★ **与 Task 5 共用一批**(见下)。★ 这条改的正是时序 ⇒ **同配置至少跑两遍**。
- [ ] **Step 7: 登记边界** —— `§六`:客户端预测/回滚在"服务端丢过包"时的表现**未实测**;翻案条件 = 有一条真链路能造出丢包并比对两端状态。
- [ ] **Step 8: 提交**
  ```bash
  git add server/match/match_host.gd tests/probe/<探针>.gd tests/probe/<探针>.gd.uid tests/probe/<探针>.tscn
  git commit -m "fix(server): 服务端钳位客户端轴值(非有限→0、|ax|<=1)+ 输入队列有界可抽干(丢包保住 just_pressed 边沿)"
  git add docs/eng/registered-debt.md
  git commit -m "docs(debt): 登记『服务端丢包时客户端预测未实测』与其翻案条件"
  ```

**报告分节要求:** `改前 ρ 序列` / `两类断言(先红证据)` / `策略选择与依据` / `逐条变异(逐条写红在哪)` / `真链路两遍` / `手感未变的证据`。

---

### Task 5: RPC 按流量类别分流到不同 channel(★ 档 3)

**这一包解决什么:** 全仓 **60 条 `@rpc` 无一例指定 `transfer_channel`** ⇒ 全挤在通道 0 上按序传输:
一次 `bullet_spawn` 的**重传**会顶住它后面**所有**权威事件(含 60Hz 输入与 `match_sync`)。
按**流量类别**分流,让"一次性可靠载荷"的重传**不再堵住**"高频快照/输入"。

**合并自:** `rpc-channel-split` T1(原样)。★ 档 3(协议)⇒ 全套。

**Files:**
- Modify: `docs/eng/netplay.md`(新增"**RPC 通道划分表**"一节 —— **单一来源**)
- Modify: 承载 `@rpc` 声明的文件(**先 `grep` 出清单**;已知至少 `core/net/net_bus.gd`、`core/net/net_bus_ext.gd`)
- Modify: 建 peer 的那一处(**仅当**下面 Review Focus 1 判定通道不够)
- Create: 一条机械化对账自检(脚本或探针)

**Interfaces:**
- Consumes: `@rpc` 声明 **60** 条、`transfer_channel` **0** 命中(审计实测,★ **复核**);
  `net_bus.gd:234` `@rpc("authority","unreliable")`(snapshot_world)与 `:255` `@rpc("authority","reliable")`(match_sync_data)为样例。
- Produces: `netplay.md` 的通道表(**通道号 → 语义 → 该通道上允许的 RPC 名单**)+ 每条声明带上第四项参数。

**★ Review Focus(原样,别自己另发明):**
1. ★★ **通道容量是前提**:`@rpc` 第四项只有在 peer 建了**足够多通道**时才有意义 ⇒ 先 `grep` 出 `ENetMultiplayerPeer` 的 `create_server(...)`/`create_client(...)` **有没有给 `max_channels`**(Godot 4 的默认值与上限**要读源码或实测**,别假设)。若要用到 3 号以上而 peer 只建了 1~3 个 ⇒ 要么调划分、要么同时改建 peer 那一处(★ 那属于"改协议初始化",**先报告**再决定是否并进本包)。
2. **同一"流"必须同通道**(否则重排);判据 = "**它后面的东西能不能等它**"。归类建议(先按实况数一遍再定):通道 0 = 少而关键的握手/`claim_role`/`match_sync`;通道 1 = **快照类**(`unreliable`,丢了就丢);通道 2 = **输入类**(60Hz);通道 3 = **一次性可靠载荷**(允许重传但别堵别人)。★ `call_local` 与通道无关(**别顺手改**);`@rpc("any_peer")` 那些**单独过一遍**(谁在发、多频繁)。
3. **一条声明都不许漏**:60 是**会变的枚举** ⇒ 守卫**不能写死 60**,要**遍历源码**取全部 `@rpc(` 与**通道表**(同一份文档里的表)对账;★ 表是单一来源,声明里只写数字。
4. **真链路的判据是"不回归",不是"变快了"**(多进程抢 CPU 会污染时序):判据 = 既有真链路脚本**仍 PASS** + 一条**新增的可观测证据**(例:服务端日志里"通道 1 上重传 N 次"这类计数,证明分流真生效)。
5. ★ **不许改可靠性语义**:`reliable`/`unreliable` 的选择**保持原样**(审计自己说"transfer_mode 的分工本身是对的,缺的只是 channel")—— 本包**只加通道**。

- [ ] **Step 1: 清点(输出全进报告)** —— `grep -rn "@rpc(" --include=*.gd . | wc -l`(复核 60);
  `grep -rn "@rpc(" --include=*.gd .`(逐条:文件 + 参数);`grep -rn "transfer_mode\|transfer_channel\|call_local" --include=*.gd .`;
  `grep -rn "ENetMultiplayerPeer\|create_server(\|create_client(\|max_channels" --include=*.gd core/ server/`。
  ★★ **作用域先说清(R6)**:产品代码那 **60** 条 = `core/net/net_bus.gd` 28 + `core/net/net_bus_ext.gd` 31 + `server/match/match_state.gd` 1(控制器派发前实测);
  ★ 另有 `tests/smoke/reconnect_smoke.gd` 的 **13** 条是**测试桩自己的 RPC** ⇒ 自检**显式排除**并**把排除条数打印出来**;
  测试桩要不要通道 ⇒ **登记待复核**,不并入本包。★ 别把 `grep -rn "@rpc(" --include=*.gd .` 的总数(应为 73)当成表的作用域。
- [ ] **Step 2: 写通道表(先文档、后代码)** —— `netplay.md` 里写**通道号 → 语义 → 允许的 RPC 名单(逐条点名到函数)** + 一句"为什么这样分"(重传隔离)+ peer 的 `max_channels` 现状。
- [ ] **Step 3: 改声明(逐条)** —— 只补第四项,**不动** mode/sync/reliable;改完 `python tools/check_naming.py` 仍 OK;`grep -c "transfer_channel"` 应等于表里点名的条数。
- [ ] **Step 4: 机械自检(**会红的**)** —— 遍历 `@rpc(` 声明抽**函数名**,与表里的名单对账,漏的/多的都报。证明:**把某条声明的通道删掉** ⇒ 报"表里有、声明没写"。
- [ ] **Step 5: 跑既有回归** —— `tests/smoke/` 里与网络最相关的 + 相关场景探针 ⇒ 绿(Task 1 建好后可直接 `bash tests/run_all.sh`)。
- [ ] **Step 6: 变异(逐条)** —— ① 把某条**快照**类 RPC 的通道改回 0 ⇒ 自检**必红**;② 把某条**可靠**载荷改到快照那条通道 ⇒ 自检应红(表里两个语义不同);复原。
- [ ] **Step 7: 真链路** —— ★ **与 Task 4 共用一批**(见下)。
- [ ] **Step 8: 提交**
  ```bash
  git add docs/eng/netplay.md core/net/net_bus.gd core/net/net_bus_ext.gd <其它承载声明的文件>
  git commit -m "feat(net): RPC 按流量类别分流到独立 channel(快照/输入不再被一次性可靠载荷的重传顶住);通道表落在 netplay.md 作单一来源"
  ```

**报告分节要求:** `清点四条命令原文` / `通道表与 max_channels 结论` / `声明改动条数对账` / `自检先红证据` / `逐条变异` / `真链路两遍 + 新增可观测证据`。

---

## 执行顺序与真链路批

**顺序(以及为什么):**

1. **Task 1 先做** —— 它是**判据**:后面四包的每次改动都靠 `bash tests/run_all.sh` 拿便宜的绿/红;且它自己**不碰产品代码**(档 2),风险最低。
2. **Task 2 次之** —— 它修的是**玩家能看见的既有缺陷**(回溯弹量),而且在此之后动同族文件(`world_rewind.gd` / `player.gd`)不会与它抢。
3. **Task 3 随后** —— 同族反射清理;`world_rewind.gd` 的敌人/子弹段与 Task 2 改过的玩家武器段在同一文件,**排在后面**能避免"改一半再改回去"。
4. **Task 4 / Task 5 最后** —— 服务端权威与传输层。★ 它们是**协议面**,排在**产品逻辑面之后**:前面几包若改了输入/快照的形状,协议层的真链路判决才准。
5. ★ **Task 5 排在 Task 4 之后**(不是并行):两者都改真链路才能验的东西,真链路一红时必须能**归属**到其中一个。

**真链路批(4 处档 3 要求 → 2 批,控制器 Ruling):**

- **批 A(覆盖 Task 2 + Task 3)**:在 Task 3 评审通过后跑。逐支先过 `lobby_alive`;跑前/跑后 `tasklist | grep -i godot` 为空;收尾 `kill_port_range 7800 8300`。
- **批 B(覆盖 Task 4 + Task 5)**:在 Task 5 评审通过后跑。★ Task 4 的队列改动是**时序**类 ⇒ **同配置至少跑两遍**再下结论;两遍的关键行原文都要进报告。
- **Ruling 的依据与代价:** 跑的是**包含两侧改动的合并状态**(覆盖是超集,不是子集),少的是**归属**;归属由「每包**先评审、后跑批**」的顺序兜住 —— 若批 A 红,Task 2/3 的评审已经各看过自己的 diff,定位范围是两包而不是十二个任务。
  **若错(某个缺陷只在单独一包下才现形):** 代价 = 一次额外的单包真链路跑(几分钟),不是漏检。
- ★ 若用户在派发过程中**认领**了某几支,agent 就不跑那几支,并把"谁跑的"写进报告。

## 本计划**不含**

- **§2.7 / §2.8** —— 已裁定"**记录而不修改**"。
- **反作弊**(恶意客户端伪造**合法范围内**的包)—— 用户已裁定不承担;Task 4 只做**健壮性**(`§七`)。
- **CI 实现** —— Task 1 只**登记**"要不要上、翻案条件";不在没有用户裁决的情况下新建 `.github/`。
- **推送到远端**(`origin/main` 落后本地约 85 个提交)—— 用户明确"先别推";`finishing-a-development-branch` 时再问。
- **修 Task 1 Step 3 暴露的既有红** —— 登记 + 报告,修它们属各自域的批次。
- **改动任何既有测试/探针/守卫的行为**(Task 1 只新增入口;Task 1 Step 7 只修一处**死读数**)。
