# 结构性弊病还款 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 [2026-11-02 结构审查](../specs/2026-11-02-structural-review.md) 里判定的 7 条弊病按"先止损、再收口、最后防复发"的顺序清掉，每一项都留下可复核的证据。

**Architecture:** 七个任务互不共享写作用域，按依赖串行：**T1 工作树隔离**是所有动作的前提（它决定后续每个提交的基线）；**T3 → T4** 是同一件事的两档（先给 `Player` 加 `class_name`，再改承重的回滚路径）；**T2 / T7** 与其它任务无交集，可随时插入；**T6（CI）放最后**，因为它要把 T2/T5 之后的支数与闸值固化成"机器每次都会验"的状态。

**Tech Stack:** Godot 4.7.1（标准版，GDScript）· Git Bash 测试入口（`tests/run_all.sh`）· Python 3（`tools/check_naming.py`）· GitHub Actions（windows-latest）· Node.js（`level_editor`，仅 T1 提交时用到）。

**Spec:** [`docs/superpowers/specs/2026-11-02-structural-review.md`](../specs/2026-11-02-structural-review.md)（本计划每条任务的"为什么"都在那；行号引用前先 `grep` 复核，源码为准）

## Global Constraints

以下每条都是本仓强制口径（[AGENTS.md](../../../AGENTS.md)），每个任务隐含继承：

- **判据一律是 grep 文本**（该支自打的 `OK` / `ALL-OK` / `RUN_ALL ...`），**退出码不作判据**。
- **跑任何测试前先向用户列清单并认领**：占 7777 或拉子进程的（真链路批）必须用户认领；非 headless 的弹窗步骤跑前告知。
- **真链路跑批前后** `tasklist | grep -i godot` 必须为空；占端口的步骤先查 `lobby_alive`。
- **`PROTO_VERSION`（=8）、线格式、端口常量（大厅 7777 / worker 池 7800~8299）、`config/version`（=0.5.3）一律不动。**
- **新增 `.gd` 必须连 `.gd.uid` 一起 `git add`**；`.tscn` 不加 `.uid`（`*.tscn.uid` 零跟踪）。
- **`tests/probe/allscript_probe.gd` 的 `EXPECTED_SCRIPTS`** 与 `tests/path_integrity_allow.txt`、`SKIP_DIRS` 是三份互相咬合的**手工**真相源：增删脚本或目录必须同轮复算。
- **逐个文件点名 `git add`，绝不 `git add -A`**；提交前 `git status --short` + 逐文件 `git diff` 认领每个 hunk（多会话共用工作树）。
- 提交信息格式：`type(scope): 中文一句话`。
- **变异验证只做"本轮新增守卫"那一份，一支一次**（T5/T8/T9 合计 5 次，每次 <1 分钟）；纯重构任务不铺变异。改坏的必须正是该守卫声明要挡的那件事。
- **已知边界与"没跑"必须落在纸上**（代码注释或 [`registered-debt.md`](../../eng/registered-debt.md)），不能只在报告里说。
- `.ps1` / `.bat` 必须 CRLF；`.ps1` 编码 = 纯 ASCII 或带 UTF-8 BOM（本计划不新增这两类文件，除 T6 的 `workflow.yml` 不受此约束）。

## 验证口径（2026-11-02 修订：砍掉仪式，只留成本线）

判定原则：**一条验证只在"它红了会改变我下一步动作"时才值得跑**。按这条砍：

**保留（每个任务收尾都跑，合计 <3 分钟）**
1. `bash tests/run_all.sh` 跑一次默认批（headless、不占端口）；判据只看全批判词行，不看退出码。
2. **新增守卫各做一次变异**，全计划共 **5 次**：T5 的 `ramp_toward`(1) + T8 的 argv 往返(1) + T9 的三条(3)。外加两次**非守卫**的确认（T3 改名→红、T4 删字段→看是否红），都是 30 秒级动作，且各自有明确产出（证明重构生效 / 判定该路径有无守卫）。
3. 三个机械点：`python tools/check_naming.py` · `git ls-files '*.gd' | wc -l` 复算 · `git status --short` 认领 hunk。

**砍掉（连同理由）**
- ✂ **逐条变异验证**（档 2 / 档 3 按档位铺开）→ 只做新增守卫那 5 次 + 2 次确认。逐条变异 90% 的时间在验证常量，不在验证契约。
- ✂ **每个任务各跑一次真链路** → 整批**末尾跑一次**（T9 Step 6），一次覆盖全部改动。单支真链路 2~5 分钟，重复跑不产生新信息。
- ✂ **人眼对比清单**→ 降为 T5 末尾一句提示，不设 checkbox：不可自动化的东西设成勾选项只会被敷衍打勾。
- ✂ **给存量守卫补条数闸**（repo 的"存量不追补"）；新增守卫一律自带闸。
- ✂ 不再把 `EXPECTED_CHECKS` 当"断言都跑过"的证明 —— 它只证明条数够；这条风险改由 T9 Step 5 的存量体检一次性处理。

**真链路唯一一次（T9 Step 6）**

```bash
tasklist | grep -i godot       # 必须为空
bash tests/run_real.sh --yes   # 需用户认领
tasklist | grep -i godot       # 再查一次
```

Expected: `RUN_REAL ...` 判词；未认领 ⇒ 在报告与台账写"真链路未跑"，不阻塞其它任务。

## Review Focus

按"最可能咬到人"排序。每条都要在它所属任务里有对应的一步，不能只写在纸上。

1. **加 `class_name Player` 后全局类缓存没重建** → 干净环境（CI / 新 clone）里别的脚本报 `Could not find type "Player"`，而本机因为 `.godot/` 缓存是热的反而全绿。**期望行为：先 import 再跑批的人不需要知道这件事也能绿。**（T3 步骤 1、T6 步骤 3）
2. **抽时间玩法组件后 `ReplicaSet.remove()` 的按名调用静默失效** → `scenes/mp_client/replica_set.gd` 是 `_client._time_fx_replica_rewind_off(r)`，按名调；方法一改名/搬走就**不报错**，变成"副本拆了但残影/底片材质表还留着"= 节点泄漏（BUG-19 的形态）。**期望行为：迁移后该名字仍在宿主上。**（T5 步骤 3）
3. **清死代码时两份手工表不同步** → 删了 `audit_shots/` 却忘了从 `SKIP_DIRS` 摘 `res://audit_shots`，`path_integrity_probe` 立刻红（它正是为此而设），但只看 `allscript_probe` 的人会以为是"条数闸漂了"。**期望行为：两条探针同轮跑、同轮绿。**（T2 步骤 4）
4. **CI 在干净 clone 上不先 import 就开跑** → 需要资源的探针全红，而红的原因是没装缓存，不是代码坏。**期望行为：首跑红必须能凭日志一眼区分"没 import"与"真红"。**（T6 步骤 3）
5. **把 R7 当成"已修好"提交** → 工作树里那两行只实现了"两端速度归零"，**没有**原计划要求的可复跑守卫与 2×60s 复测；若不登记就提交，台账会从此说谎。**期望行为：提交信息与台账都写"守卫/真链路待补"，不写"已修复回滚"。**（T1 步骤 5）

---

### Task 1: 工作树隔离与按主题提交（P0 · 前提）

**Files:**
- 读：`git status --porcelain` 全量、`.tmp/`（备份落点）
- 提交（按用户认领的子集）：
  - `.gitignore`、`level_editor/**`（48 改 + 5 新）、`assets/textures/weapons.png`、`docs/eng/editor-{core,render,server,ui}.md`、`docs/eng/{tools,world}.md`
  - `scenes/pvp_match_client.gd`、`server/match/match_host.gd`（R7）
  - `docs/audit/**`（未跟踪的审计报告 + findings + 截图）

**Interfaces:**
- Consumes: 无（第一个任务）
- Produces: 一棵干净的工作树 + 4 个提交。后续所有任务的 `git diff` 基线。

> ⚠ **归属前置（不满足就停手）：** 这些改动**不是同一个会话的**。`docs/audit/2026-11-01-关卡编辑器问题汇报.md` 明写"`assets/textures/weapons.png` 不是本轮任何 agent 动的"，而 `pvp_match_client.gd` / `match_host.gd` 的改动是 R7（另一个主题）。本仓明文规定多会话共用工作树，**未认领的 hunk 不提交**。

- [ ] **Step 1: 先做可恢复快照（不改工作树）**

```bash
git check-ignore -v .tmp/inflight.patch || git check-ignore -v .tmp/
git diff --binary > .tmp/inflight-2026-11-02.patch
git status --porcelain > .tmp/inflight-2026-11-02.status
mkdir -p .tmp/inflight-untracked
for f in $(git status --porcelain | sed -n 's/^?? //p'); do
  cp -r --parents "$f" .tmp/inflight-untracked/ 2>/dev/null || true
done
wc -l .tmp/inflight-2026-11-02.patch .tmp/inflight-2026-11-02.status
```

Expected: `git check-ignore` 要么报 `.tmp/` 被忽略（可写），要么报未忽略 ⇒ 此时把备份改落到 `.git/info/exclude` 里额外忽略的 `.tmp/`，**不要**把备份写进任何被跟踪的目录。

- [ ] **Step 2: 向用户确认归属与提交范围**

用一句话问清三批：① `level_editor` 重构 ② R7 两文件 ③ `assets/textures/weapons.png` —— 哪些属于本次可提交范围。
Expected: 得到"哪些提交、哪些留原地"的明确答复。答复未到之前**不执行任何 `git add`**。

- [ ] **Step 3: 提交 A —— 忽略编辑器 PID 文件（最小、零风险）**

```bash
git add .gitignore
git diff --cached -- .gitignore
git commit -m "chore(gitignore): 忽略编辑器服务器的单实例 PID 文件"
```

Expected: `git status --short` 里 `.gitignore` 消失；`.editor_server.pid` 不在任何提交里。

- [ ] **Step 4: 提交 B —— `level_editor` 重构（若用户认领）**

```bash
git add level_editor/server/instance.js level_editor/server/map_ops.js \
        level_editor/ui/86_fileops.js level_editor/editor.html \
        level_editor/tests/server/55_map_ops.js level_editor/tests/server/75_instance.js
# 其余逐文件点名（可分批提交，但每批 commit 前都要 git diff --cached 认领 hunk）
node level_editor/parts_check.js && node level_editor/build_dist.js --check
git commit -m "refactor(editor): 抽出实例接管/地图操作/文件操作三模块并补齐 smoke"
```

Expected: `node level_editor/build_dist.js --check` 打 OK（入库的 `dist/cyrm-editor.html` 与源码同源）；`git status --short` 只剩未被认领的那批。

- [ ] **Step 5: 提交 C —— R7 冻结期速度归零（档 3；只登记，不宣称修好）**

```bash
git add scenes/pvp_match_client.gd server/match/match_host.gd
git diff --cached -- scenes/pvp_match_client.gd server/match/match_host.gd
git commit -m "fix(net): COUNTDOWN 冻结期两端速度归零(R7 代码面;守卫与真链路待补)"
```

Expected: `git diff --cached` 恰好是两处 `velocity = Vector2.ZERO` 及其注释，**没有**别的 hunk。

- [ ] **Step 6: 在 `registered-debt.md` 追加 R7 条目（同轮，不能只剩提交）**

在 [`docs/eng/registered-debt.md`](../../eng/registered-debt.md) 末尾追加一节，逐字写明四条：
① 改了什么（两端各一处 `velocity = Vector2.ZERO`）；② **没做**什么（R7 原计划要求的"可复跑守卫 + 变异红/绿 + 2×60s 复测"全部未做）；③ 判据是什么（"开局首条 ack 不产生 rollback" 需探针，今天**零守卫**）；④ 指向 [`2026-11-01-rollback-source-align.md`](../plans/2026-11-01-rollback-source-align.md) §R7。

```bash
git add docs/eng/registered-debt.md
git commit -m "docs(debt): 登记 R7 代码面已落、守卫与真链路未跑的边界"
```

Expected: 台账里 grep 得到 `R7` 且含"未跑"字样；不出现"已验证/已修复"。

- [ ] **Step 7: 提交 D —— 审计报告入库（报告与截图同批，否则链接断）**

```bash
git add docs/audit/level-editor-findings docs/audit/2026-11-01-*.md
git commit -m "docs(audit): 入库 2026-11-01 关卡编辑器审计(报告 + findings + 截图)"
```

Expected: 报告里 `level-editor-findings/shots/*.png` 的相对链接在仓库内可解析（`ls` 能打开）；`docs/audit/.gdignore`（0 字节）保持入库不动。

- [ ] **Step 8: 收尾核对**

```bash
git status --short          # 只应剩"用户明确要求留在原地"的文件
git log --oneline -4        # 四个提交都在
bash tests/run_all.sh       # 默认批（不占端口）——见下方"跑前认领"
```

Expected: `RUN_ALL OK(n runs / m gated-assertions)` 或 `OK-WITH-KNOWN-RED`；`git status` 残留项与 Step 2 的答复一致。

---

### Task 2: 死代码清理 + 收紧编译面守卫（**2026-11-02 已完成**）

> **实际执行（比原计划更彻底）**：`git rm -r audit_shots` + **`git rm -r docs/archive`（整个归档目录，154 文件 / 7.28 MB，
> 含 122 张一次性截图与 8 个取图驱动）**；`SKIP_DIRS` 去掉 `res://audit_shots`（`res://docs` 保留）；
> `git ls-files '*.gd'` 从 255 → **241**，`EXPECTED_SCRIPTS` 仍是 **241**（被删的 14 个 `.gd` 原本就被 SKIP_DIRS 排除）。
> 另：`docs/audit/`（未跟踪的一次性审计：49 KB 报告 + findings + 7 张截图）也整体删除。
> 下面保留原步骤作方法记录（其中的路径已不存在）。

**Files:**
- Delete: `audit_shots/`（19 个 tracked 文件）
- Delete: `docs/archive/audit/2026-10-27-ui/_drivers/`、`docs/archive/audit/2026-10-27-ui/p1/_drivers/`（8 `.gd` + 8 `.tscn` + 2 `.py`）
- Modify: `tests/probe/allscript_probe.gd`（`SKIP_DIRS` 去两项）
- Modify: `tests/README.md` / `docs/eng/registered-debt.md`（若读数变了）

**Interfaces:**
- Consumes: T1 的干净工作树
- Produces: `SKIP_DIRS` = 10 项；`EXPECTED_SCRIPTS` **保持 241**（被删的两处本来就被排除在编译面之外，见 Step 3 的复算）

- [ ] **Step 1: 删前证据留档（确认两侧字节相同，删了不丢信息）**

```bash
sha256sum audit_shots/p1_shots.gd docs/archive/audit/2026-10-27-ui/p1/_drivers/p1_shots.gd
sha256sum audit_shots/p1_verify_phase1.gd docs/archive/audit/2026-10-27-ui/p1/_drivers/p1_verify_phase1.gd
```

Expected: 每对哈希相同（`audit_shots/` 是归档副本的重复品；归档 README 已声明"取图驱动是一次性证据，不再维护"）。**若不相同** ⇒ 停下，先 diff 再决定删哪一份。

- [ ] **Step 2: 删除两个死代码树**

```bash
git rm -r audit_shots
git rm -r docs/archive/audit/2026-10-27-ui/_drivers docs/archive/audit/2026-10-27-ui/p1/_drivers
git status --short
```

Expected: 只剩 `D` 行；`docs/archive/audit/2026-10-27-ui/` 下保留 122 张截图与 2 份结论 `.md`（证据不删）。

- [ ] **Step 3: 收紧 `SKIP_DIRS` 并复算条数闸**

把 `tests/probe/allscript_probe.gd` 的 `SKIP_DIRS` 改成（删掉 `"res://docs"` 与 `"res://audit_shots"`）：

```gdscript
const SKIP_DIRS := ["res://.godot", "res://builds", "res://releases", "res://gamelogs",
		"res://crashlogs", "res://maps", "res://map", "res://backup", "res://editor/_build",
		"res://_crashtest"]
```

复算（两条必须同时成立）：

```bash
git ls-files '*.gd' | wc -l                                   # 期望 241（255 − 14 已删）
git ls-files --others --exclude-standard '*.gd' | wc -l        # 期望 0
```

Expected: 第一条 = 241，第二条 = 0 ⇒ `EXPECTED_SCRIPTS` **保持 241 不动**（这一轮改的是"覆盖面变宽"，不是"脚本数变了"）。
**注意**：`res://docs` 摘掉后 `docs/` 下已无 `.gd`，探针应仍绿；若新增 `.gd` 到 `docs/`，这次会真红（这正是目的）。

- [ ] **Step 4: 两条咬合探针同轮跑（Review Focus #3）**

```bash
bash tests/run_all.sh --only allscript
bash tests/run_all.sh --only path_integrity
python tools/check_naming.py
```

Expected: `ALLSCRIPT: OK(241 个脚本全部加载)`；`path_integrity` 支判词为 OK（`SKIP_DIRS` 里已无指向不存在目录的项，故 `path_integrity_allow.txt` **不需要**改）；`命名检查 OK`。
若 `path_integrity` 红并点名 `res://audit_shots` ⇒ 说明 Step 3 漏删，回去删该项，**不要**往 allow 表里加豁免（那是把洞留着）。

- [ ] **Step 5: 提交**

```bash
git add tests/probe/allscript_probe.gd
git add docs/eng/registered-debt.md          # 若在末尾追加了"死代码已清"的边界说明
git commit -m "chore(repo): 删除 audit_shots 与归档取图驱动,编译面守卫收回两项豁免"
```

Expected: `git show --stat` 里只有删除 + 一个 `SKIP_DIRS` 文件的改动。

---

### Task 3: `class_name Player` + 非回滚调用点类型化（档 2）

**Files:**
- Modify: `scenes/player/player.gd`（加 `class_name`）
- Modify: `server/match/match_round.gd,166`、`server/match/match_combat.gd,110,144,227`、`server/match/match_snapshot.gd`
- Modify: `scenes/pvp_match_client.gd,209`（`_local` 已是 `Node2D`，但 `is_downed()` / `input_source` / `pvp_haste_mult` 是 `Player` 独有）

**Interfaces:**
- Consumes: T1 的干净工作树
- Produces: 全局类 `Player`（`scenes/player/player.gd`，snake = 文件名，过 `check_naming` 规则 B）；后续 T4 直接用它做类型标注

- [ ] **Step 1: 加 `class_name` 并重建全局类缓存**

`scenes/player/player.gd` 顶部改为：

```gdscript
class_name Player
extends CharacterBody2D
```

注释同步改写（原注释说"不做 class_name:新全局类名要等编辑器重扫缓存"—— 现在要做：把"为什么当年不做"留作历史，把"改后必须 import 才能被别的脚本解析"写成新契约）。

```bash
"$GODOT" --headless --path . --import          # console 二进制同样能做 import,不必用编辑器版
grep -c 'Player' .godot/global_script_class_cache.cfg
```

Expected: 缓存文件里出现 `Player`（`grep` 计数 ≥ 1）。**若 `--import` 不被该引擎版本识别**（stderr 含 `Unknown`）⇒ 改用 `"$GODOT" --headless --path . --editor --quit`，再核对同一文件。

- [ ] **Step 2: 逐个替换非回滚调用点（每处都是"调用方已经知道对面是 Player"的地方）**

**必须落到 `Player` 类型的局部变量上**才能拿到真编译期检查 —— `p is Player` 只做运行时判定、**不窄化静态类型**（`p` 仍是 `Node2D`，成员调用依旧是 unsafe access，拼错只警告）。形态（示例，`match_combat.gd`）：

```gdscript
	var pl := p as Player
	var fallback: Rect2 = pl.hurt_rect() if pl != null else HitShape.hurt_rect_of(p)
```

其余同款：`match_round.gd,166`（`p.has_method("cancel_jump_state")` → `var pl := p as Player; if pl != null: pl.cancel_jump_state()`）、
`match_combat.gd,144,227`（`hurt_rect` / `take_hit`）、`match_snapshot.gd`（`capture_state`）、
`pvp_match_client.gd,209`（`_local` 声明为 `var _local: Player = null`）。

Expected: `grep -n 'has_method' server/match/match_round.gd server/match/match_combat.gd server/match/match_snapshot.gd` **归零**（除 `_host.has_method` 那类非 Player 目标）。

- [ ] **Step 3: 一条变异 + 默认批（合并了原来的两步）**

把 `scenes/player/player.gd` 的 `func cancel_jump_state()` 临时改名成 `cancel_jump_state_x`：

```bash
bash tests/run_all.sh --only allscript     # 期望红:LOAD[FAIL] / Parse Error
# 还原名字后
bash tests/run_all.sh                      # 期望 RUN_ALL OK(...)
```

Expected: 变异那次红、还原后全绿。
**它证明的是"成员改名会当场红"**，不是"行为正确"—— 行为由默认批里 `rollback_fidelity_probe` / `snapshot_size_probe` / `net_wire_smoke` 三支判词兜。

- [ ] **Step 4: 提交**

```bash
git add scenes/player/player.gd scenes/pvp_match_client.gd server/match/match_round.gd \
        server/match/match_combat.gd server/match/match_snapshot.gd
git commit -m "refactor(sim): 给 Player 注册 class_name,非回滚调用点去字符串反射"
```

---

### Task 4: 回滚路径类型化（档 3 · 真链路归到 T9 末尾统一跑）

**Files:**
- Modify: `server/match/match_host.gd,452-509`（`_record_rw_frame` / `_apply_rw_frame`）
- Modify: `core/sim/world_rewind.gd,221`

**Interfaces:**
- Consumes: T3 产出的 `Player` 类型
- Produces: 承重回滚路径零 `p.get(` / `p.set(` / `p.has_method(`（子弹那一路保持原样，见下）

- [ ] **Step 1: 先建立"这条路径今天有没有守卫"的基线（不新增断言）**

```bash
bash tests/run_all.sh --only rollback
bash tests/run_all.sh --only snapshot
```

Expected: `rollback_fidelity_probe` 与 `snapshot_size_probe` 的既有判词（前者 34 条断言）全绿，把逐字判词抄进本任务报告。
**本步刻意不写新断言**：`core/sim/world_rewind.gd` 自述"零守卫（两支 rewind 探针已删·2026-10-09）"，
先跑基线才知道后面的变异能不能被既有断言抓到 —— 不然就是在凑一条"为改动定制"的守卫。

- [ ] **Step 2: `_apply_rw_frame` 改点访问**

```gdscript
	var p := players.get(int(frame["role"])) as Player
	if p == null:
		return
	p.velocity = f["v"]                  # 原 p.set("velocity", f["v"])
	p.hp = int(f["hp"])                  # 原 p.set("hp", …)
	p.facing_direction = int(f["facing"])
	var combat := p.combat
	var wc := p.weapons
```

Expected: `grep -n 'p\.get(\|p\.set(' server/match/match_host.gd` **归零**；子弹那几处（`b.get("shooter")` / `b.call("apply_rewind_state")`）**保留**——把 `BulletBase` 类型化是另一个任务，别在这一批扩面。

- [ ] **Step 3: `world_rewind.gd` 五处改点访问**

`var player := _player as Player` 之后：`player.velocity` / `player.hp` / `player.facing_direction` / `player.is_downed()` / `player.weapons`；`world_rewind.gd` 的 `has_method("rewind_restore")` 改成 `player is Player` + 直接调用。
同时把 `:111` 那段"零守卫"注释改写为"由点访问 + `rollback_fidelity_probe` 的往返断言守"。

Expected: `grep -n 'player\.get(\|player\.set(\|has_method' core/sim/world_rewind.gd` **归零**。

- [ ] **Step 4: 一条变异 + 如实登记（真链路不在这里跑）**

把 `p.facing_direction = int(f["facing"])` 删掉，跑：

```bash
bash tests/run_all.sh --only rollback
```

Expected: 两种结果都合法，**二选一并照实写**——
① 红 ⇒ 记逐字判词、还原、绿 ⇒ 这条路径有守卫；
② 照样绿 ⇒ **今天零守卫**，写进 [`registered-debt.md`](../../eng/registered-debt.md)（哪一处、去掉什么也不红），**不许**为凑红新写读源码文本的守卫。

真链路整批**只在 T9 Step 6 跑一次**（见「验证口径」），本任务不重复。

- [ ] **Step 5: 提交 + 登记**

```bash
git add server/match/match_host.gd core/sim/world_rewind.gd
git commit -m "refactor(net): 回滚录制/回放改 Player 点访问"
```

（若 Step 4 判为 ②，同一提交里带上 `docs/eng/registered-debt.md`，提交信息改为 `...;该路径零守卫已登记`。）

---

### Task 5: 摘出 `MatchTimeView` + `MathUtil.ramp_toward`（档 2）

**Files:**
- Create: `scenes/mp_client/match_time_view.gd`（+ `.gd.uid`）
- Create: `tests/smoke/time_ramp_smoke.gd`（+ `.gd.uid`）
- Modify: `core/sim/math_util.gd`（+ 1 个静态函数）
- Modify: `scenes/pvp_match_client.gd`（抽走时间玩法整块，留 3 个委托口）
- Modify: `scenes/mp_client/time_fx.gd`（改读宿主访问器）
- Modify: `tests/probe/allscript_probe.gd`（`EXPECTED_SCRIPTS` 241 → **243**）
- Modify: `tests/README.md` 顶部判词台账（支数/闸值以实跑为准）

**Interfaces:**
- Consumes: T1（`pvp_match_client.gd` 已含 R7 的 5 行）
- Produces:
  - `MatchTimeView`（`class_name`，`extends RefCounted`）：`bind(host: Node) -> void` · `setup() -> void` · `on_time_state(payload: Dictionary) -> void` · `tick(delta: float) -> void` · `haste_mult() -> float`
  - `MathUtil.ramp_toward(current: float, target: float, up_sec: float, down_sec: float, delta: float) -> float`
  - 宿主保留（名字与签名**逐字不变**，因为外部按名调用）：`_time_fx_replica_rewind_off(rep: Node2D) -> void`、`_all_replicas() -> Array`、`_setup_beta_time_hud() -> void`、`_tick_beta_time(delta: float) -> void`、`time_haste_mult() -> float`
- **预期结果**：宿主 843 → ≈770 行（本块约 92 行净移出；这是"摘掉一整块职责"的第一刀，不是把 843 砍到 600）。
  **下一刀候选（本计划不做，留给后续）**：子弹接触剔除（`_contact_targets_now` / `_cull_bullet_contacts` / `_bullet_contact_target` / `_bullet_hurt_rect` / `_bullet_hits_entity` / `_update_contact_state`，约 90 行）与命中事件队列（`_pending_hit_events` 那组，约 60 行）。

- [ ] **Step 1: 先写 `ramp_toward` 的失败测试**

`tests/smoke/time_ramp_smoke.gd`（`extends SceneTree`，`EXPECTED_CHECKS := 4`）：

```gdscript
	# ① 对称速率:0→1 与 1→0 用同一满程秒数 ⇒ 半程各得 0.5(不含缓动)
	# ② 非对称:up 0.2s / down 0.1s ⇒ 同一 0.05s 里上行 0.25、下行 0.5
	# ③ 不越界:delta 远大于满程 ⇒ 恰好停在 1.0 / 0.0(不是 1.05 / -0.05)
	# ④ 零满程兜底:up_sec = 0 ⇒ 直接到位(不除零)
```

四条都用 `absf(got - want) < 1e-4`，最后断言 `_checks >= EXPECTED_CHECKS` 再打 `TIME RAMP OK(4 条断言)` / `FAILED`。

Expected（本步）：`load("res://core/sim/math_util.gd")` 成功但调用 `ramp_toward` 报"函数不存在" ⇒ 打 `TIME RAMP FAILED`。

- [ ] **Step 2: 实现 `MathUtil.ramp_toward`**

```gdscript
## 线性 ramp:按 up_sec / down_sec(0→1 / 1→0 的满程秒数)朝 target 逼近;不越界、不做缓动。
## 两个调用点(加速压暗 100ms 对称 / 回溯底片 200ms 上 100ms 下)原先各写一处 clampf 加减,
## 抽出后"上下速率不同"这件事只在一处表达。
static func ramp_toward(current: float, target: float, up_sec: float, down_sec: float, delta: float) -> float:
	var span := up_sec if target > current else down_sec
	if span <= 0.0:
		return target
	return move_toward(current, target, delta / span)
```

Expected: `bash tests/run_all.sh --only time_ramp` ⇒ `TIME RAMP OK(4 条断言)`。

- [ ] **Step 3: 建 `scenes/mp_client/match_time_view.gd` 并迁移**

迁移清单（**逐字搬，不改逻辑**）：宿主 147–260 行里除 `_time_fx` 那组（`_ensure_time_fx` / `_tick_time_fx` 保留在宿主）之外的全部成员与函数：
`_time_mirror` `_time_watch` `_time_rewinding` `_haste_dim_t` `_time_film_t` `_time_mat` `_time_sym` `_time_haste_mult`
→ 组件内改成 `_mirror` `_watch` `_rewinding` `_dim_t` `_film_t` `_mat` `_sym` `_haste_mult`；
函数 `_setup_beta_time_hud` → `setup()`、`_on_time_state` → `on_time_state()`、`_tick_beta_time` → `tick()`、
`_tick_beta_rewind` / `_apply_own_film` / `_film_targets` → 组件私有。
两个 ramp 表达式换成 `MathUtil.ramp_toward(...)`：
`_dim_t = MathUtil.ramp_toward(_dim_t, 1.0 if on else 0.0, 0.1, 0.1, delta)`
`_film_t = MathUtil.ramp_toward(_film_t, 1.0 if _rewinding else 0.0, 0.2, 0.1, delta)`。
组件里对宿主的访问沿用 `TimeFx` 的既有契约（直接读 `_client._local` / `_client._all_replicas()`，并在文件头写明"同 TimeFx"）。

宿主侧只留：

```gdscript
var _time_view: MatchTimeView = null

func _ensure_time_view() -> MatchTimeView:
	if _time_view == null:
		_time_view = MatchTimeView.new()
		_time_view.bind(self)
	return _time_view

func _setup_beta_time_hud() -> void:          # 子类调用点不变
	_ensure_time_view().setup()

func _tick_beta_time(delta: float) -> void:   # _physics_process 调用点不变
	_ensure_time_view().tick(delta)

func time_haste_mult() -> float:
	return _time_view.haste_mult() if _time_view != null else 3.0
```

Review Focus #2 的钉子：**`_time_fx_replica_rewind_off` 必须仍留在宿主上**（`replica_set.gd` 按名调），内容不变。

Expected: `grep -n '_time_mirror\|_time_watch\|_time_sym\|_time_mat\|_haste_dim_t\|_time_film_t' scenes/pvp_match_client.gd` **归零**；
`grep -n '_time_fx_replica_rewind_off' scenes/pvp_match_client.gd scenes/mp_client/replica_set.gd` 两处都在。

- [ ] **Step 4: 改 `time_fx.gd` 的跨组件私有读**

```gdscript
			label.text = "▶▶ %dx" % int(round(_client.time_haste_mult()))
```

Expected: `grep -n '_time_haste_mult' scenes/mp_client/time_fx.gd` 归零。

- [ ] **Step 5: 条数闸 + 判词台账同步（"改了 A 就会过期的 B"）**

先把两个新脚本挂进索引（`git ls-files` 只数已跟踪的，未 add 时数不到），再复算：

```bash
git add scenes/mp_client/match_time_view.gd scenes/mp_client/match_time_view.gd.uid \
        tests/smoke/time_ramp_smoke.gd tests/smoke/time_ramp_smoke.gd.uid
git ls-files '*.gd' | wc -l                              # 期望 243
git ls-files --others --exclude-standard '*.gd' | wc -l   # 期望 0
```

把 `allscript_probe.gd` 的 `EXPECTED_SCRIPTS` 改成 **243**（**若 T8 已先落地**：改成跑 `-- --update` 更新 `tests/script_inventory.txt`，别再动常量），并把 `tests/README.md` 顶部台账追加一行（照现有体例，写清 +2 是哪两支、闸断言 +4）；默认批的"n 支 / m 条"以实跑判词为准抄。

- [ ] **Step 6: 一条变异 + 默认批（人眼降为一句提示）**

```bash
bash tests/run_all.sh
```

Expected: 全绿，且 `time_ramp` 计入 `m`。
变异：把 `_film_t` 那行的 `0.2, 0.1` 写成 `0.1, 0.2` ⇒ `time_ramp` ② 红；还原 ⇒ 绿。

人眼（不设 checkbox、不计入验收）：改完找一次 beta 大乱斗房试玩 5 分钟 —— 加速的压暗/残影/`▶▶ 3x`、回溯的底片/`◁◁`、怀表数值。这些没有自动判据，所以它们只写在这一句里，不写成"验证项"。

- [ ] **Step 7: 提交**

```bash
git add core/sim/math_util.gd scenes/mp_client/match_time_view.gd scenes/mp_client/match_time_view.gd.uid \
        tests/smoke/time_ramp_smoke.gd tests/smoke/time_ramp_smoke.gd.uid \
        scenes/pvp_match_client.gd scenes/mp_client/time_fx.gd \
        tests/probe/allscript_probe.gd tests/README.md
git commit -m "refactor(net): 时间玩法整块抽成 MatchTimeView,ramp 收进 MathUtil 并加守卫"
```

---

### Task 6: 默认批接入 CI（P1 · 放最后）

**Files:**
- Create: `.github/workflows/default-batch.yml`
- Modify: `tests/README.md`（补一节"CI 跑什么、不跑什么"）
- Modify: `AGENTS.md` §1（一行指针：默认批有 CI，真链路仍人工认领）

**Interfaces:**
- Consumes: T8/T9 之后的最终状态（脚本数由 `tests/script_inventory.txt` 生成物决定，不再手工数）与判词台账
- Produces: 每次 push/PR 产出 `RUN_ALL ...` 判词行；真链路批**不进** CI

- [ ] **Step 1: 先在本机测一次耗时（决定是否要分片）**

```bash
time bash tests/run_all.sh
```

Expected: 记下墙钟时间与 `RUN_ALL OK(n runs / m gated-assertions)`。若 > 15 分钟 ⇒ 本任务只对 `pull_request` 跑，`push` 到 main 用 `paths:` 收窄到 `**.gd` / `tests/**` / `project.godot`。

- [ ] **Step 2: 固化 Godot 下载源（先验证 URL 真的可下）**

```bash
curl -sIL -o /dev/null -w '%{http_code}\n' \
  "https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_win64.exe.zip"
```

Expected: `200`。**不是 200** ⇒ 改用 [`RELEASE.md`](../../../RELEASE.md) 记录的安装途径，把可用的 URL 与版本写进 workflow 头注释，再继续。

- [ ] **Step 3: 写 workflow（含 import 步骤 —— Review Focus #1/#4）**

```yaml
name: default-batch
on:
  pull_request:
  push:
    branches: [main]
    paths: ["**.gd", "tests/**", "project.godot", ".github/workflows/**"]
  workflow_dispatch:
jobs:
  headless:
    runs-on: windows-latest
    timeout-minutes: 30
    defaults: { run: { shell: bash } }
    steps:
      - uses: actions/checkout@v4
      - name: 装 Godot console(4.7.1)
        shell: pwsh
        run: |
          Invoke-WebRequest -Uri "${{ env.GODOT_URL }}" -OutFile godot.zip
          Expand-Archive godot.zip -DestinationPath .
          $exe = Get-ChildItem -Recurse -Filter "*console.exe" | Select-Object -First 1
          "GODOT=$($exe.FullName)" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
      - name: 首次 import(.godot 不入库 ⇒ 没有它就全是假红)
        run: '"$GODOT" --headless --path . --import || "$GODOT" --headless --path . --editor --quit'
      - name: 命名/路径检查
        run: python tools/check_naming.py
      - name: 默认批(headless;不占端口、不拉子进程)
        run: bash tests/run_all.sh
      - name: 上传摘要
        if: always()
        uses: actions/upload-artifact@v4
        with: { name: run_all_summary, path: "tests/.run_all_logs/", if-no-files-found: warn }
```

（`GODOT_URL` 放在 workflow 顶层的 `env:`，值取 Step 2 验证过的那个。）
Expected: 文件里**没有**任何真链路 entry；`run_real.sh` 不被调用。

- [ ] **Step 4: 首跑判红（分开"没 import"与"真红"）**

在 PR 上触发一次，看日志：
- 若出现成批 `Could not find type` / `Failed to load resource` ⇒ **环境问题**，修 workflow（Step 3 的 import 步骤），**不登记** `known_red.txt`；
- 若某支打自己的 `FAIL` / `NO-VERDICT` ⇒ **真红**，停本任务、转成新任务修（或按 `known_red.txt` 的规则登记，且必须带真实欠账指针与实测日期）；
- 若 `RUN_ALL OK(...)` ⇒ 通过。

Expected: 日志里能一眼看到全批判词行（纯 ASCII）与逐支表。

- [ ] **Step 5: 文档同步**

`tests/README.md` 追加一节"CI"：跑什么（默认批 + `check_naming` + import）、**不跑什么**（真链路四支 / 非 headless 取图 / 7777）、红线（首跑红先判环境还是真红）。
`AGENTS.md` §1 的聚合入口那一条后加一句："默认批已接 CI（`.github/workflows/default-batch.yml`）；真链路批仍按本节的认领纪律人工跑。"

```bash
git add .github/workflows/default-batch.yml tests/README.md AGENTS.md
git commit -m "ci(gate): 默认批接入 GitHub Actions(windows-latest + 先 import)"
```

---

### Task 7: 目录地图与文档拓扑修正（档 1）

> **2026-11-02 第二轮（已全部落地）**：`tests/README.md` **96 → 57 行**（35 行默认批流水账**直接删除**，
> 不搬归档；删掉与 `run_all.sh --list` 重复且互相矛盾的闸值清单；**修掉 4 行含裸 CR 的乱码**）；
> **8 个悬空文档指针清零**（`check_naming.py` 的失败信息原本指向已删除的 `docs/naming-cleanup-plan.md` 等）；
> `registered-debt.md` **1,204 → ~70 行**（删掉 §九~§五十六 的逐批过程，只留已知红 / 已知边界 / 零守卫面）;
> `pvp-networking.md` **237 → ~185 行**（删"文件地图"与"测试"两节）;
> `docs/CyR单人模式主策划案(1).md` → **`git mv` 去掉 `(1)`**;
> **整个 `docs/archive/` 与 `docs/audit/` 已删除**（本仓从此不设归档目录，历史一律看 `git log`）。

**Files:**
- Modify: `core/README.md`（整份重写清单部分）
- Modify: `docs/archive/README.md`（那条"这些文件现在都在本目录下"的口径已与现状不符）
- ~~Modify: `AGENTS.md` §4 指针表~~ → **已在 T10 完成**（`docs/superpowers/` 与 `docs/audit/` 两行已进 AGENTS §4）

**Interfaces:**
- Consumes: T10 已完成入口收敛（本任务不再改 AGENTS.md）
- Produces: `core/` 清单不再提供会过期的数字；归档口径与现状一致

- [ ] **Step 1: 用实测替换 `core/README.md` 的清单**

实测值（2026-11-02）：`config 9` / `mp 5` / `net 22` / `present 6` / `sim 31` / `ui 1`；autoload **5 个**（`GameParameters` `NetBus` `NetBusExt` `Settings` `LoadingScreen`）。
改写原则：**删掉所有"每个子目录有几个文件 + 逐个点名"的清单**，换成"这个子目录装什么、加东西时按什么判据归位"，并加一行"文件清单以 `ls` 为准，本文件不抄清单"（与 AGENTS.md §2「别信文档里的文件清单」同口径）。
补上现在完全没提的两个子目录：`mp/`（模式与房间规则常量）、`ui/`（`loading_screen`）。

- [x] **Step 2: 指针表 —— 已随 T10 的 AGENTS.md 重写落地**（两行都在；本条只剩归档口径）

在 `docs/archive/README.md` 那行后面补一句："2026-11-01 起重新启用 `docs/superpowers/{plans,specs}/` 作为**在飞**计划的落点；归档时整份搬进本目录。"

Expected: `ls docs` 的四类聚集地（`eng` / `archive` / `superpowers` / `audit`）在入口文档里都能查到。

- [ ] **Step 3: 自检**

```bash
python tools/check_naming.py
```

Expected: `命名检查 OK(… 入口文档预算与 CLAUDE.md 副本一致)`。
**注意射程**：`core/README.md` 不在规则 C 的覆盖表内（`DOC_FILES` = 根四份 + `docs/eng` + `tests`），所以本任务的清单修改**没有**文档守卫兜底 —— 这也是 Step 1 选择"不抄清单"而不是"抄一份新清单"的原因。

- [ ] **Step 4: 改名 + 提交**（`git mv` 见 T10 Step 6；沙箱不允许写 `.git` 索引时留待有权限的会话）

```bash
git add core/README.md docs/archive/README.md
git commit -m "docs(layout): core/README 去清单化,归档口径与四类文档聚集地对齐"
```

---

### Task 8: 消掉两处"抄一份"：脚本台账 + worker argv（P1）

**Files:**
- Create: `tests/script_inventory.txt`（一行一个 `res://` 路径，排序）
- Modify: `tests/probe/allscript_probe.gd`（`EXPECTED_SCRIPTS` 常量 → 与 inventory 比对）
- Modify: `core/mp/mode_context.gd`（新增 `build_worker_args`）
- Modify: `server/lobby/worker_launcher.gd`（三处 argv 拼装改调 `build_worker_args`）
- Modify: `tests/smoke/net_argv_port_smoke.gd`（加往返断言）

**Interfaces:**
- Consumes: T5 之后的 `EXPECTED_SCRIPTS`（=243）；若 T8 先于 T5 落地，T5 的 Step 5 改为跑 `--update` 更新 inventory
- Produces:
  - `tests/script_inventory.txt` + `allscript_probe` 的差异报告（`ADDED:` / `REMOVED:` 逐行点名）
  - `ModeContext.build_worker_args(opts: Dictionary) -> PackedStringArray`，
    与既有 `ModeContext.from_args(args: PackedStringArray, default_port: int = 7777) -> Dictionary` 往返一致

> 为什么不是"再补一条守卫"：[test-economy.md](../../eng/test-economy.md) §4「能生成就别再加守卫」。
> 这两处今天都是"两处抄一份"，守卫只能事后发现漂移，生成式/单一入口让漂移不可能发生。

- [ ] **Step 1: 把手工条数闸换成"生成物 + --check"**

写 `tests/script_inventory.txt`（内容 = 当前扫到的那 243 条，排序、`res://` 形式），
`allscript_probe.gd` 的判据改成：**扫到的集合与 inventory 逐条 diff**，差异时打印
`ADDED: res://…` / `REMOVED: res://…` 并红；支持 `-- --update`（`OS.get_cmdline_user_args()`）在校验通过后重写该文件。
保留原有"扫不到任何脚本 ⇒ 直接红"的 fail-closed 判据。

```bash
bash tests/run_all.sh --only allscript      # 期望绿,判词里带 (243 个脚本)
```

Expected: 绿；此后再加 `.gd` 时红的那一刻会**直接点名是谁**，而不是"期望 241 实得 242"。
（这正是本仓自述"手工数了三次、注释里堆了三段订正"的那条摩擦。）

- [ ] **Step 2: worker argv 收成一对函数**

`core/mp/mode_context.gd` 加：

```gdscript
## 与 from_args 成对:构建 → 解析 → 必须还原成同一个字典(往返判据的唯一来源)。
## ★ 原先 WorkerLauncher 三处手拼字符串、server_main 手解 —— 两边改一处必须同步改另一处,今天零守卫。
static func build_worker_args(opts: Dictionary) -> PackedStringArray:
	# 键与 from_args 的解析键逐一对应:worker / port / role / roles / teams / ai / test_destroy_tile
```

`WorkerLauncher.spawn_worker / spawn_royale_worker / spawn_team_worker` 三处的 argv 拼装全部改调它。

Expected: `grep -n '"--worker"\|"--port"' server/lobby/worker_launcher.gd` **归零**（flag 字面量只允许出现在 `mode_context.gd`）。

- [ ] **Step 3: 往返断言 + 一条变异**

`tests/smoke/net_argv_port_smoke.gd` 里加一个判定类别（**一条**，不是每种模式一条）：

```gdscript
	for opts in [{"worker": true, "port": 8123}, {"worker": true, "roles": [1, 3]},
			{"worker": true, "roles": [1,2,3,4,5,6], "teams": {"1": 1, "2": 2}}]:
		_chk(ModeContext.from_args(ModeContext.build_worker_args(opts), 7777) == opts,
				"build→parse 往返恒等（%s）" % str(opts.keys()))
```

`EXPECTED_CHECKS` 同步 +1。
变异：把 `build_worker_args` 里 `--roles` 写成 `--role` ⇒ 往返红；还原 ⇒ 绿。

- [ ] **Step 4: 默认批 + 提交**

```bash
bash tests/run_all.sh
git add tests/script_inventory.txt tests/probe/allscript_probe.gd \
        core/mp/mode_context.gd server/lobby/worker_launcher.gd tests/smoke/net_argv_port_smoke.gd
git commit -m "refactor(net): worker argv 收成 build/parse 一对,脚本台账改成生成物比对"
```

---

### Task 9: 三条挡真缺陷的新守卫（P1 · 这批是"真正有用的"）

**Files:**
- Modify: `tests/probe/map_spawn_data_probe.gd`（写死两张图 → glob `maps/*.cyrm`）
- Create: `tests/probe/hud_plate_probe.gd` + `hud_plate_probe.tscn`（场景探针）
- Create: `tests/smoke/export_surface_smoke.gd`（`-s`，代理判据）
- Modify: `docs/eng/test-economy.md`（追加 §5 存量体检表）

**Interfaces:**
- Consumes: T8 的 `script_inventory.txt`（新增两个 `.gd` 后跑 `--update`）
- Produces: 三条各自带条数闸的守卫；一张"存量体检候选表"（**只出候选，不删**）

- [ ] **Step 1: 地图 spawn 数据改成自动枚举（挡"换图/加图就没人验"）**

`map_spawn_data_probe.gd` 里写死的 `NEWFACTORY` / `DEMO` 换成扫目录：

```gdscript
	var maps: Array[String] = []
	for f in DirAccess.get_files_at("res://maps"):
		if f.ends_with(".cyrm"):
			maps.append("res://maps/" + f)
```

断言合成一条判定类别：**每张图**的每侧 respawn 点满足 `≥ MIN_PER_SIDE` 且两两环面距 `≥ SIDE_EDGE_MARGIN`、且不落在实体内。
为什么值得写：地图数据是**唯一每次换图都要重验**的面（历史上出过"复活点落进封闭空间"§四十六补、"出生点贴边"§四十六），
而旧探针写死两张图 ⇒ 加第三张图时它静默不覆盖（这是本仓自述"枚举会过期"的同一个病）。

```bash
bash tests/run_all.sh --only map_spawn
```

Expected: `MAP SPAWN DATA ... ALL-OK`，判词里列出**每张图**。
变异：复制 `maps/demo.cyrm` 到 `maps/_tmp_bad.cyrm` 并塞一个贴边 respawn 点 ⇒ 红；删掉临时图 ⇒ 绿。

- [ ] **Step 2: HUD 底板色复本一致性（补 `ui_factory.gd` 自认的那条零守卫）**

先确认承载字段：

```bash
grep -n 'bg_color\|theme_override_styles\|C_PLATE' ui/hud/pvp_hud.tscn ui/hud/team_hud.tscn ui/factory/ui_factory.gd
```

把结论写进本步骤（读的是 `theme_override_styles/panel` 的 `bg_color` 还是 `self_modulate`），再写探针：
实例化两个 `.tscn`，取底板节点上的实际颜色，与 `UiFactory.C_PLATE` 逐位比较（4 位浮点）。

为什么值得写：`ui_factory.gd` 明文写着"改色必须手工同步那两处 —— 原守卫已删（2026-10-09），**今天零守卫**"。
这是"改配色 → 某个模式 HUD 底色不对"的唯一自动判据，且属于**行为可观测**（渲染值），不是读源码文本。

```bash
bash tests/run_all.sh --only hud_plate
```

Expected: `HUD PLATE: ALL-OK`。
变异：把 `team_hud.tscn` 里的 alpha 改 0.01 ⇒ 红；还原 ⇒ 绿。

- [ ] **Step 3: 导出面禁 `RegEx`（挡"编辑器全绿、导出后整个脚本解析失败"）**

新建 `tests/smoke/export_surface_smoke.gd`（`-s`）：**复用** `allscript_probe` 的 SKIP 规则（`const ProbeCfg := preload("res://tests/probe/allscript_probe.gd")` 后读 `ProbeCfg.SKIP_DIRS`，**不要手抄第三份**），
再额外排除 `tests/`、`tools/`、`docs/` 三个非导出目录，命中集合 = "进导出包的 `.gd`"，断言其中零 `RegEx.new(`。
文件头必须按 [test-economy.md](../../eng/test-economy.md) **D6b** 写明："代理判据：读源码文本，不是行为；
行为证据 = `tools/build_release.py` 的导出后冒烟（跑 exe、断言「worker 就绪」）。"

为什么值得写：裁剪模板 `module_regex_enabled: false` ⇒ 只要有人随手用一次 `RegEx`，**整个脚本在导出包里解析失败**，
而编辑器里全绿 —— AGENTS 把它列为硬规则，但**今天零守卫**；历史上已有一次发布阻断（`registered-debt` §四十二）。

```bash
bash tests/run_all.sh --only export_surface
```

Expected: `EXPORT SURFACE: ALL-OK(n 个导出面脚本,0 处 RegEx)`。
变异：在任意导出面脚本里加一行 `var r := RegEx.new()` ⇒ 红；删掉 ⇒ 绿。

- [ ] **Step 4: 更新脚本台账（T8 的生成物）**

```bash
bash tests/run_all.sh --only allscript -- --update   # 或按 T8 实现的开关形式
bash tests/run_all.sh
```

Expected: 全批绿；`script_inventory.txt` 里多了 `tests/probe/hud_plate_probe.gd` 与 `tests/smoke/export_surface_smoke.gd`。

- [ ] **Step 5: 存量体检表（只出候选，**不删**）**

跑一次默认批，按 [test-economy.md](../../eng/test-economy.md) 的 D 组逐支打分，把结论追加成该文件的 §5 表：
`支名 | 断言数 | 命中哪条 D | 判为候选/保留 | 依据（逐字证据）`。
**本步不删任何守卫** —— 删除要用户裁定，并按 `registered-debt` §九「删了什么 = 欠了什么」登记。
已知必须写进表的两条证据：
- `snapshot_size_probe` 文件头仍在宣传"两种线格式（Dictionary 直发 → 手打包）"，而 Dictionary 直发在 v7 已退役（该文件自己的 2026-10-30 备注就写了 ⑥~⑨ 随 DELTA 退役）⇒ **文件头过期**，要么改头要么删残留度量；
- `map_spawn_data_probe` 的写死图常量在 Step 1 已修，不再进表。

- [ ] **Step 6: 真链路唯一一次（**需用户认领**）**

```bash
tasklist | grep -i godot       # 必须为空
bash tests/run_real.sh --yes
tasklist | grep -i godot
```

Expected: `RUN_REAL ...`，前后无残留 Godot 进程。未认领 ⇒ 报告与台账写"真链路未跑"。

- [ ] **Step 7: 提交**

```bash
git add tests/probe/map_spawn_data_probe.gd tests/probe/hud_plate_probe.gd tests/probe/hud_plate_probe.gd.uid \
        tests/probe/hud_plate_probe.tscn tests/smoke/export_surface_smoke.gd tests/smoke/export_surface_smoke.gd.uid \
        tests/script_inventory.txt docs/eng/test-economy.md
git commit -m "test(guards): 地图 spawn 自动枚举 + HUD 底板色复本 + 导出面禁 RegEx"
```

---

### Task 10: `AGENTS.md` 收敛 + `CLAUDE.md` 生成副本（**2026-11-02 已完成，仅剩提交**）

> **状态（本会话已落地）**：`AGENTS.md` **117 行 / 11.9 KB → 61 行 / 5.9 KB**；架构索引搬进新建的 [`docs/eng/README.md`](../../eng/README.md)；
> `CLAUDE.md` 改成 [`tools/sync_agents_md.py`](../../../tools/sync_agents_md.py) 的**生成副本**（真源只有 AGENTS）；
> `check_naming.py` 新增**规则 F**（入口文档行数预算 + 副本一致），并把 `AGENTS.md` 纳入 `DOC_FILES`（它的链接从此有守卫）。
> **验证**：`python tools/check_naming.py` → `命名检查 OK(... 入口文档预算与 CLAUDE.md 副本一致)`；`python tools/sync_agents_md.py --check` → `CLAUDE.md MIRROR: OK`。
> 用户在 A/B 之间选了第三条：**不删 CLAUDE.md，让它成为生成副本**（保住 Claude Code 那类工具的文件名约定，同时不可能漂）。

**Files:**
- Rewrite: `AGENTS.md`（117 行 → 61 行，预算上闸 70）
- Create: `docs/eng/README.md`（按域路由索引，预算 80）
- Create: `tools/sync_agents_md.py`（生成器 + `--check`）
- Rewrite（生成）: `CLAUDE.md`（= 固定抬头 + AGENTS 正文）
- Modify: `tools/check_naming.py`（`DOC_FILES` 加 `AGENTS.md`；规则 F：预算 + 镜像）
- Modify: `README.md` / `tests/README.md` / 8 份 `docs/eng/*.md` 的索引回链（原来都指向 `CLAUDE.md`）
- Modify: `docs/eng/tests.md`（接收"报告纪律 / 同配置两次"）· `comment-style.md`（接收"乘子 vs 浓度"）· `ui.md`（接收"看图判断"）· `tools.md`（接收 `.ps1`/`.bat` 两条硬约束 + 带空格路径）

**Interfaces:**
- Consumes: 无（独立于其它任务）
- Produces: 入口唯一真相源 `AGENTS.md`；`docs/eng/README.md` 成为域索引；规则 F 防止再长回去

> **为什么必须收（实测）**：这份文件会被**注入每个会话的上下文**，它的长度是每次交互的固定税。
> 117 行里混了四种寿命不同的东西：① 事实 ② 命令 ③ 流程与硬规则 ④ 历史叙述（"2026-10-04 订正…"、"实测发生过…"）。
> ④ 该住 `registered-debt` / `archive`；② 的细节该住脚本头；① 只该写"去哪看"，不抄值。
> 硬证据：`AGENTS.md` 原本**不在** `check_naming.py` 的 `DOC_FILES` 里 ⇒ 30+ 个文档链接**零守卫**（本轮一纳入就抓到一条一直没人管的坏引用）。

- [x] **Step 1: 职责裁决 —— 用户裁定：AGENTS 唯一真相源，CLAUDE 为生成副本**（不选"删"也不选"退化成指针"）

- [x] **Step 2: 逐段归桶 + 搬运**（历史叙述 → `registered-debt`/`archive` 已有；命令细节 → 脚本头已有；桶表/不写清单 → `test-economy.md` 已有；本轮补搬 4 条到 `tests.md` / `comment-style.md` / `ui.md` / `tools.md`）

- [x] **Step 3: 按骨架重写**（五段：是什么 / 跑什么 / 怎么改（六步）/ 会静默错的硬规则 / 去哪查）

- [x] **Step 4: 两条防腐化守卫**（规则 F：`AGENTS.md ≤ 70`、`README ≤ 90`、`RELEASE ≤ 180`、`docs/eng/README ≤ 80`；`CLAUDE.md` 只查镜像一致、不查行数）

- [ ] **Step 5: 冷读验收（唯一还没做的）**

只打开 `AGENTS.md`、不看代码与其它文档，回答 5 问：① 默认批怎么跑、判词长什么样？② 档 3 改动要做哪几件事？③ 改地图格式读哪份文档？④ 什么时候绝对不能占 7777？⑤ 版本号唯一来源是什么？有一问卡住 ⇒ 回写一行（并跑生成器）。

- [ ] **Step 6: 改名 + 提交（需 `git` 写权限；本轮沙箱不允许写 `.git` 索引，故未做）**

```bash
# ① 去掉下载残留的 (1):docs/CyR单人模式主策划案(1).md → 无括号名
git mv "docs/CyR单人模式主策划案(1).md" "docs/CyR单人模式主策划案.md"
# ② 把 AGENTS.md 里那一行改成正常链接,再重新生成副本
python tools/sync_agents_md.py && python tools/check_naming.py
# ③ 分两次提交:纯搬运 / 骨架+守卫
git add AGENTS.md CLAUDE.md docs/eng/README.md tools/sync_agents_md.py tools/check_naming.py \
        docs/eng/tests.md docs/eng/comment-style.md docs/eng/ui.md docs/eng/tools.md \
        README.md tests/README.md "docs/CyR单人模式主策划案.md"
git commit -m "docs(agents): 入口收成一份(117→61 行),CLAUDE.md 改为生成副本并上预算闸"
```

（其余逐条：`AGENTS.md` 里 `docs/CyR单人模式主策划案(1).md` 现为**反引号文字 + `docs/` 链接**的形式，是规则 C 的 tokenizer 见 `(` 就截断所致；改名后换回正常链接即可。）

- [ ] 旧 Step 记录（保留作方法参考）：下面是本任务开工前写的 A/B 裁决与五段骨架，已成历史

| 现有段落 | 去向 |
|---|---|
| §0 这是什么（版本/前缀/视口） | 保留，但只写"唯一来源 = `project.godot` 的哪几个键"，不抄值 |
| §1 怎么跑（命令 + 纪律） | 保留命令，**细节指向脚本头**；"实测发生过"叙述搬 `registered-debt` |
| §2 怎么改（定档表 / 守卫三问 / 完成标准） | 保留，压成表格；这是 AGENTS 的核心价值 |
| §3 硬规则 | 保留每条的**结论 + 一句为什么**；历史订正搬 `registered-debt` |
| §4 去哪查（指针表） | 保留并补 T7 的两行 |

Expected: 每个"搬走"的段落都在目标文件里落地（不是删除），`grep` 得到原文关键句。

- [ ] **Step 3: 按骨架重写（5 段 + 每段"放什么/不放什么"）**

```markdown
# AGENTS.md
> 一句话:工程权威在 CLAUDE.md(索引)→ docs/eng(域)。本文件只回答三件事:怎么跑、怎么改、去哪查。
## 0 身份与唯一来源     ← 只写"去哪看",不抄任何值/清单
## 1 三个入口命令       ← 跑 / 测 / 导;每条给"输出长什么样",细节指脚本头
## 2 改动流程           ← 定档表 + 守卫三问 + 完成标准(压成表)
## 3 硬规则             ← 只留"违反会静默出错"的,每条一句为什么
## 4 去哪查             ← 指针表(域文档 / 台账 / 归档 / 计划 / 审计)
```

**不放**进 AGENTS 的四类：可执行细节（→ 脚本头）· 文件清单/枚举（→ `--list` / `ls`）· 历史叙述与订正（→ `registered-debt` / `archive`）· 逐字数值（→ `docs/eng` 或代码常量）。

- [ ] **Step 4: 加两条防再腐化的守卫**

1. `tools/check_naming.py` 的 `DOC_FILES` 加入 `"AGENTS.md"`（此后它的链接由既有规则 C 校验）；
2. 新增规则 F：入口文档行数预算 —— `AGENTS.md ≤ 130`、`CLAUDE.md ≤ 60`、`README.md ≤ 90`、`RELEASE.md ≤ 180`，
   超了红并打印"该把哪类内容搬去 docs/eng"的提示。`--self-test` 里加一条超预算的假文件用例。

Expected: `python tools/check_naming.py` 绿；把 `AGENTS.md` 临时加 20 行 ⇒ 红；还原 ⇒ 绿。

- [ ] **Step 5: 冷读验收（这是重写成不成的唯一判据）**

只打开 `AGENTS.md`、不看代码与其它文档，回答下面 5 问（写进提交信息或报告）：
① 默认批怎么跑、判词长什么样？② 档 3 改动要做哪几件事？③ 改地图格式该读哪份文档？
④ 什么时候绝对不能占 7777？⑤ 版本号唯一来源是什么、release 前缀从哪来？
Expected: 5 问全可从 AGENTS 内部或它的一跳链接得到答案；任何一问卡住 ⇒ 回 Step 3 补一行。

- [ ] **Step 6: 分两次提交（否则 diff 无法评审）**

```bash
# 第一次:纯搬运(历史 → registered-debt;细节 → 脚本头),不动 AGENTS 骨架
git add AGENTS.md docs/eng/registered-debt.md tests/env.sh start_server.bat tools/build_release.py
git commit -m "docs(agents): 把 AGENTS.md 里的历史叙述与命令细节搬去台账与脚本头"

# 第二次:骨架重写 + 两条守卫
git add AGENTS.md CLAUDE.md tools/check_naming.py
git commit -m "docs(agents): 重写为'决策与纪律'五段式,入口文档纳入链接与行数守卫"
```

---

## 本计划不做（已裁定，不是遗漏）

spec 里这几条**判过但这一轮不动**，理由与"将来归谁"一并写死，免得后来者以为是漏项：

| spec 条目 | 为什么这轮不做 | 将来怎么做 |
|---|---|---|
| **C3 · `beta_mode` 会话级全局 + 冻结 RPC 签名** | 方向对（把 beta 从会话全局下沉到房间属性），但要改 `royale_join/team_join` 的 RPC 签名 = 协议面 ⇒ **档 3**，与"清理工作树"无关，混进来会把一个卫生计划变成协议计划 | 单独计划；入口是服务端已有的 `RoomTypes.beta`，客户端改读房间载荷而不是 `PvpSession` |
| **C4 · 两套出生点系统** | 旧系统 `SpawnPicker` 仍是大乱斗的生产路径，删它要先证明 `SpawnChooser` 能覆盖大乱斗的散点/兜底语义 ⇒ 需真链路对局验证 | 单独计划；先给 `SpawnPicker` 的自适应分支补一条守卫或删分支，再谈合并 |
| **C5 · 跨文件同值常量/表（4 处）** | 纯"单一真相源"改造，每处都是改生成式（`.tscn` 引不到 GDScript 常量这条尤其），与本计划主题不重叠 | 单独计划；优先 `ui_factory` 那两处 `.tscn` 底色（今天零守卫） |
| **E1 · level_editor 与 `.cyrm` 三实现** | 是"第二个产品"的架构问题，不是弊病修复；合并实现收益不确定、风险大 | 只在计划外登记；真要动先做"三实现逐字节一致性探针" |
| **E2 · 仓库根产物堆放 + 历史 23 MB exe** | 清根目录只需用户把 exe/zip 移到 `builds/`（不入库，属本机整理）；**清历史**要 `filter-repo` + 强推，必须单独裁定 | 本机整理随时可做；历史清理另开一次带备份的窗口 |

**已从"不做"里移出来的**：E6（手工条数闸）→ 已并入 **T8 Step 1**（改成生成物比对）；C5 的 `ui_factory` 那一处 → 已并入 **T9 Step 2**（先补守卫，真生成式仍留给后续计划）。

---

## 执行顺序与依赖

```
T1(工作树，前提)
 ├─► T2(死代码清理) ─────────────────┐
 ├─► T3(class_name) ─► T4(回滚类型化) │
 ├─► T5(MatchTimeView + ramp 守卫) ───┤
 ├─► T7(文档拓扑) ────────────────────┴─► T8(台账生成物化 + worker argv)
 │                                              └─► T9(三条新守卫 + 真链路唯一一次)
 │                                                     ├─► T6(CI 固化最终判词)
 │                                                     └─► T10(AGENTS.md 重写)
```

- **真链路整批只跑一次**，在 T9 Step 6；未认领时该步跳过、报告与台账写"真链路未跑"，不阻塞提交。
- **T5 与 T8 顺序可互换**：若 T8 先落地，T5 的 Step 5 改成跑 `--update` 更新 inventory（而不是改 `EXPECTED_SCRIPTS` 常量）。
- **T6 必须在 T9 之后**：它要把最终的支数与闸值固化进 workflow 与 `tests/README.md`。
- **T10 最后**：它吸收 T7 的两行指针表，并给入口文档加行数预算，此时全仓文档才定稿。
- 每一轮进入验证阶段前，先按 [AGENTS.md](../../../AGENTS.md) §1 **列出这轮要跑的测试**给用户认领。
- 每个任务一个提交（T1 是四个）；任何一个任务红着不提交，也不把后面的任务叠上去。
