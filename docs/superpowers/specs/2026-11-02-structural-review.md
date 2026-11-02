# 结构性问题审查（2026-11-02）

> **性质：**只读审查，未改任何文件、未跑任何测试（本机 headless 批与真链路批按 [AGENTS.md](../../../AGENTS.md) §1 需先认领）。
> **射程：**代码结构与仓库工程面；**不含**性能/手感/观感/数值。
> **数据口径：**`git ls-files` + 逐文件行计数（含空行）+ `git rev-list --objects --all`；时点 = 2026-11-02 13:00 工作树。

## 0. 规模画像

| 区域 | 文件 | 行数 | 备注 |
|---|---|---|---|
| `scenes/` | 79 | 15,331 | 最大单文件 `pvp_match_client.gd` 843 行 |
| `tests/` | 151 | 14,246（`.gd` 12,151） | 60 smoke + 55 probe + 18 harness |
| `level_editor/` | 136 | 23,810 | **第二个产品**：16,429 行 JS |
| `core/` | 77 | 10,289 | 分层最干净的一层 |
| `server/` | 30 | 7,241 | |
| `ui/` | 36 | 4,248 | |
| `docs/` | 184 | ~7,900 | 含 `archive/` 154 文件 / 7.1 MB |

- 生产 `.gd` = **180 文件 / 34,102 行**；测试 `.gd` = 12,151 行（≈36%）。
- `.gd` 注释行 5,404 / 42,040 ≈ **12.9%**；**35 个文件超出本仓自定的"≤15%"额度**（最高 39.3%）。
- `.gd` 里 **370 处日期戳**，分布在 136 个文件；`registered-debt.md` **818 行 / 53 节**。
- 工作树：**56 改 + 7 新，+3,820 / −675**，最后一次写入 11-01 19:40。
- `.git` = **42.2 MB**；最大历史 blob = `tools/easytier/easytier-core.exe` **23.27 MB**（已不在 HEAD）。
- **零 CI 配置**（无 `.github/` / `.gitlab-ci` / Jenkinsfile）。

## 1. 判断

代码本身的水准明显高于同类 Godot demo：分层在守（`server/`、`core/` 基本不反向依赖 UI），
守卫文档习惯（"最强保证 / 测不到什么"）罕见。真正的弊病是三处**结构性成本**：

1. 仓库边界失守（产物、一次性驱动、大二进制、跨夜未提交大改同处一棵树）；
2. 极少数上帝对象 + 核心实体走字符串反射（最承重的联机路径失去静态检查）；
3. 验证体系重量已超过项目体量，且零 CI（全部靠人工纪律兑现）。

## 2. 代码层问题（按严重度）

### C1 · PvpMatchClient 是 40+ 职责的上帝对象
`scenes/pvp_match_client.gd` 843 行，同时负责：时间玩法 HUD + 片 shader + 双 ramp、TileSync、
PickupSync、子弹接触剔除、命中事件队列、round_state、结算页、重连驱动、状态横幅、match_sync 补态、
角色配色、输入锁、输入上行装配。方法都很短（最长 59 行）——**坏在宽度不在长度**。
爆炸半径被放大到这 843 行里；`_on_match_sync` 一体负责补砖/补武器/补子弹，挂了的表现是"重连后某样东西没了"。
（已部分组件化：`TileSync` / `TimeFx` / `PickupSync` 已抽出，说明方向成立，只剩时间玩法那一块没摘。）

### C2 · 最承重的路径在用字符串反射
`Player` 是模拟核心却**故意无 `class_name`**（`scenes/player/player.gd:5` 注释：新全局类名要等编辑器重扫缓存）。
于是权威侧访问退化成字符串：

- `server/match/match_host.gd:452-509` —— 回滚重放整段是 `p.set("velocity", …)` / `p.get("combat")` / `b.call("apply_rewind_state", …)`；
- `core/sim/world_rewind.gd:97-105,221` —— 5 处按名访问，`has_method("is_downed")` 一改名就**静默**把 `downed` 写成 false（该文件 111 行自述"零守卫"）；
- `server/match/match_combat.gd:90,110,144,227` 与 `server/match/match_snapshot.gd:78` —— `has_method(...)` 守卫 + `call(...)`。

字段改名/拼错在 GDScript 里不报错：`get()` 拿不到返回 null，静默走默认值。这正是"回滚分歧 / 命中判定诡异"
最肥沃的土壤（对应 `registered-debt` §二十二、§四十三）。

### C3 · `beta_mode` 会话级全局 + 冻结 RPC 签名
`core/net/pvp_session.gd:20` 的 `static var beta_mode` 渗透了：大厅房间过滤、join RPC 签名
（`royale_join(code, invite, beta)`）、建房载荷、HUD 挂载、选项面板显隐、服务器房间类型、match options。
注释里已记下两次真实故障：`pvp_match_client.gd:158-163`（房主专属时钟 HUD）与
`scenes/mp_lobby.gd:501`（1v1 必须显式排除 time，因为 `create_room(caller)` 是冻结签名）。
⇒ 结构上 1v1 永远无法 beta，且每个新入口都会重新踩一次。

### C4 · 两套出生点系统并存，旧的那套自认零守卫
`core/sim/spawn_picker.gd`（网格几何推导 + 6 个 `static var` 缓存）与
`core/sim/spawn_chooser.gd`（地图 meta `# respawn` 点名随机）同时在跑；
`server/hosts/team_spawn.gd:125` 仍在用旧系统兜底；`spawn_picker.gd:10-11` 自述自适应分支
"生产图永不触发 + 原守卫已删（2026-10-09）⇒ **今天零守卫**"。

### C5 · 跨文件同值常量/表靠注释同步（4 处）
`ui/factory/ui_factory.gd:97`（底板色在 2 个 `.tscn` 各抄一份，原守卫已删）·
`scenes/player/player_replica.gd:28-31`（`DASH_GHOST_*` 与 `player.gd` 同值）·
`player_replica.gd:125`（`POSE_SHAPE` 必须同步）· `server/lobby/worker_launcher.gd:196`（argv 与 `server_main.gd` 逐字对应）。
四条都违背本仓"单一真相源优先于守卫"。

### C6 · 死代码副本把守卫打出了洞（**已处理：2026-11-02 全部删除**）
`audit_shots/` 19 个 tracked 文件，其中 3 个 `.gd` 与归档目录里的同名驱动**字节相同**（哈希比对 `same=True`）；
另有 8 个 `docs/` 下的 `.gd` **没有 `.gd.uid`**。
后果：`tests/probe/allscript_probe.gd` 被迫把 `res://docs` 与 `res://audit_shots` 放进 `SKIP_DIRS`
⇒ **编译面完整性检查被仓库卫生问题削掉两个目录**。
**处置**：`audit_shots/` 与整个 `docs/archive/`（154 文件 / 7.28 MB，含 122 张一次性截图与 8 个取图驱动）已全部 `git rm`；
`SKIP_DIRS` 只留 `res://docs`；`EXPECTED_SCRIPTS` 仍是 241（被删的 14 个 `.gd` 原本就在 SKIP_DIRS 之外）。

## 3. 工程/结构问题

### E1 · 一个仓库两个产品 + 格式三实现
`level_editor/` 是独立产品（16.4k 行 JS、55 个测试），与 Godot 共享 `.cyrm` 字节语义，格式存在
**三份实现**（GDScript v3 文本 / GDScript v4 二进制 / JS codec）；`level_editor/dist/cyrm-editor.html`
**356 KB 生成物入库**（有 `--check` 守漂移）。

### E2 · 仓库根 = 产物堆放场
根目录 4 个大二进制（2 exe 各 47 MB + 2 macOS zip 各 63 MB，均 ignore）；磁盘上 `releases/` **3.4 GB**、
`builds/` 253 MB、`web_build/` 41 MB。历史里还有 23.27 MB 第三方 exe。

### E3 · 跨夜未提交的 56 文件重构
`level_editor` 一次深度重构（新增 `server/instance.js` / `server/map_ops.js` / `ui/86_fileops.js` +
2 个新测试 + 6 份文档 + `.gitignore`）全部躺在工作树里；另有 **R7 冻结期速度归零**（两端各一处）
这一档 3 的联机修复也在同一棵树上未提交。

### E4 · 零 CI
`tests/run_all.sh` 设计讲究（五类判词 / 已知红基线 / 过期排除项也红 / 承重安全检查 / ASCII 判词），
但没有 CI；它依赖 Windows + Git Bash + 特定 Godot 路径，且文档明文"跑测试前先问用户"。
⇒ 守卫的强度被"没人自动跑"这个事实打了大折。

### E5 · 文档拓扑不稳定、目录地图过期 2~3 倍
入口文档只承认 `docs/eng/`（真相源）与已删的 `docs/archive/`，但当时实际还有
`docs/superpowers/`（3 计划 + 1 spec）与 `docs/audit/`（一次性审计）——**四处口径互相矛盾，且没有任何一处写全**。
最典型：`core/README.md` 说 `sim(12) net(12) config(6) present(3)`、四个 autoload；
实测 `sim 31 / net 22 / config 9 / present 6`，另有它完全没提的 `mp/`(5) 与 `ui/`(1)，
autoload 已是 **5 个**（`LoadingScreen` 在 `project.godot:33`）。

**★ 已在 2026-11-02 本会话处理（入口部分）**：`AGENTS.md` **117 行 / 11.9 KB → 61 行 / 6.0 KB**；
架构索引搬进新建的 `docs/eng/README.md`（26 行，按域路由）；`CLAUDE.md` 改为
`tools/sync_agents_md.py` 的**生成副本**（真源只剩 AGENTS.md，副本漂移由 `check_naming.py` 规则 F 判红）；
`AGENTS.md` 纳入 `DOC_FILES`（链接首次有守卫，**一纳入就抓到一条一直没人管的坏引用**）；
四类文档聚集地（`eng` / `archive` / `superpowers` / `audit`）全部进了 AGENTS §4 指针表。
**未处理**：`core/README.md` 的过期清单（计划 T7）、`docs/CyR单人模式主策划案(1).md` 的 `(1)` 改名（T10 Step 6，需 `git mv`）。

### E6 · 手工条数闸
`tests/probe/allscript_probe.gd:26` `EXPECTED_SCRIPTS := 241` 需手工数（`git ls-files '*.gd'` 减 SKIP_DIRS）。
今天恰好对（255 − 8 − 6 = 241），但那行常量后的注释已堆了三次历史订正。

## 4. 不做（明确排除）

- 不动 `PROTO_VERSION`（8）、不动端口常量（大厅 7777 / worker 池 7800~8299）、不升线格式。
- 不重排 `level_editor` 的 JS 分层、不做 `.cyrm` 三实现的合并（那是独立计划）。
- 不做 `filter-repo` 清历史（只登记；它要求强推，需单独裁定）。
- 不新增"读源码文本判形态"的守卫（[AGENTS.md](../../../AGENTS.md) §2 不写清单）。

### 4.1 判过但本轮不动（逐条给理由，避免被当成漏项）

| 条目 | 为什么本轮不动 |
|---|---|
| **C3** `beta_mode` 会话全局 + 冻结 RPC 签名 | 修法要改 `royale_join` / `team_join` 的 RPC 签名 = 协议面（档 3），该单独成计划；入口是服务端已有的 `RoomTypes.beta` |
| **C4** 两套出生点系统 | `SpawnPicker` 仍是大乱斗生产路径，删它需先证明 `SpawnChooser` 覆盖散点/兜底语义（真链路验证） |
| **C5** 跨文件同值常量（4 处） | 纯单一真相源改造，与"清理+防复发"两个主题都不重叠；优先 `ui_factory` 那两处 `.tscn` 底色（今天零守卫） |
| **E2** 根目录产物 / 历史 23 MB exe | 根目录整理属本机操作（不入库）；清历史要 `filter-repo` + 强推，需单独窗口 |
| **E6** 手工条数闸生成化 | **已移出**不做清单 ⇒ 并入计划的 T8 Step 1（改成生成物比对）；它正是"验证面过度定制"的标本 |

## 5. 验证面：哪些是"太特殊 / 太老"的（用户 2026-11-02 判断的实证）

115 支测试（60 smoke + 55 probe）没有一支是凭空写的 —— 每支文件头都能指出一个真实缺陷。问题不在"有没有用"，而在**配比与形态**：

| 现象 | 实测证据 | 属于 |
|---|---|---|
| **一支一事故**：守卫随修随加，跟随单次事故的现场数值 | `team_rules_smoke` 14 条、`spawn_chooser_smoke` 20 条、`wheel_switch_probe` 16 条、`stair_climb_probe` 11 条，多为"一个数值一条" | 逼近 D9（一条判定类别拆成 N 条） |
| **重资产承重**：4 支真链路占 2~5 分钟/支，全部要用户认领才能跑 | `rollback_fidelity_probe` 530 行/35 断言 · `team_match_probe` 821 行/51 断言且**无条数闸** · `royale_soak_probe` 535 行/0 断言（判词靠 print） | D8 边界 / 认领制 ⇒ 平时不跑 |
| **前提已死的"老"**：文件头还在描述已退役的对象 | `snapshot_size_probe` 头行仍写"同时量两种线格式（Dictionary 直发 → 手打包）"，而 Dictionary 线格式在 v7 已退役（该文件自己 2026-10-30 的备注写明 ⑥~⑨ 随 DELTA 一起退役） | 过期文档 = 让读者按错误前提解读判词 |
| **枚举写死**：新数据不会被覆盖 | `map_spawn_data_probe` 把 `maps/` 里两张图写成常量 ⇒ 加第三张图时探针静默不覆盖（而"换图后复活点落封闭空间"已发生过一次，§四十六补） | 与本仓自述"枚举会过期"同一个病 |
| **承重面反而零守卫**（比"测试太多"更值得管） | ① 导出面禁 `RegEx`（AGENTS 硬规则，`registered-debt` §四十二 有真实发布阻断前科）**零守卫**；② `ui_factory.gd:97` 自认配色复本"原守卫已删、今天零守卫"；③ `worker_launcher.gd:196` 自认 argv"两边改一处必须同步"**零守卫**；④ `AGENTS.md` **不在** `check_naming.py` 的 `DOC_FILES` ⇒ 它的 30+ 链接零守卫 | K3 面（改坏了很久才发现）缺守卫 |

**结论（决定计划怎么改）：**
1. **验证的"仪式"要砍**：逐条变异、每任务真链路 → 整计划 ≤3 次变异、真链路整批一次（计划「验证口径」节）。
2. **守卫要"换代"而不是"加码"**：优先写**一条挡一类**的（协议边界、导出面契约、数据枚举），并把"两处抄一份"改成生成式/单一入口（T8），而不是给已有支补闸。
3. **存量只体检不追补**：按 D 组打分出候选表（T9 Step 5 写进 `test-economy.md` §5），删除须用户裁定 + 按 §九 登记"删了什么 = 欠了什么"。

## 6. 未验证 / 边界

- 未跑任何测试；未实测 CI 时长与首跑绿红。
- `registered-debt.md` 只读标题与抽样正文，"哪些债已登记"可能有遗漏。
- `scenes/` 与 `server/` 的规则层是否重复只抽查了 `match_state` / HUD 两条链，未逐条对读。
- 验证面的"D 组打分"是静态判读（读文件头与断言文案），**未经实跑确认**；T9 Step 5 要求跑过之后再落表。
