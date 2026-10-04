# 服务端收口客户端输入（audit §2.2 / §2.3）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"**服务端无条件相信客户端输入包**"这一条收口：① 轴值 `ax` **无界**（`ax=50` 在服务端约等于 35000px/s，全图才 9600px）；② 输入队列**无上限**、且每 tick 只消费 1 包 ⇒ 积压不可恢复（服务端自述 ρ=1）。

**Architecture:** 两处都在 `server/match/match_host.gd` 的**消费侧**（权威侧）—— 这是**同一个原则**的两半：**服务端是权威，输入的合法性与资源占用都由它负责**。改动不动协议字段（`ax` 仍是浮点），只动"收到之后怎么处理"。

**Tech Stack:** GDScript（Godot 4.7.1）、`server/` 的权威回路、`tests/probe/` 与 `tests/scripts/` 的真链路跑批。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.2 / §2.3 + 用户裁定（"§2 也可以做，拆分细一点"）+ `registered-debt.md` §七 已登记"**本设计不承担反作弊**"。

## Global Constraints

- ★★ **本计划的动机不是反作弊**（用户已裁定不承担，见 `registered-debt.md` §七）：是**协议健壮性** —— 版本不匹配、有 bug 的客户端、或单机壳里跑出来的包都能让服务端飞出去。**别**在提交信息或注释里写成"反作弊"。
- **档 3（协议/权威/输入包）** ⇒ 必做全套：纯逻辑 `-s` + 场景探针 + **每条承重断言逐条变异** + **真链路跑批** + **逐任务评审**。
- ★★ **真链路纪律**（[`AGENTS.md`](../AGENTS.md) §1）：任何会占 7777 的步骤**先查 `lobby_alive`**；跑批**前后** `tasklist | grep -i godot` 必须为空；收尾 `kill_port_range`；**进入验证阶段先把「这轮要跑哪些测试」列给用户认领**。
- 逐个文件点名 `git add`；**绝不** `git add -A`；提交前逐文件 `git diff` **认领每个 hunk**。
- **不许改客户端手感**：轴钳位只在**服务端消费侧**；合法输入（`|ax| ≤ 1`）必须**逐位不变**地得到与改前相同的位移。
- ★ 判据是 grep 文本（`SMOKE OK` / `ALL-OK` / 真链路脚本的判词），不是退出码。

## Review Focus

1. **队列上限的"丢谁"是设计决定，不是随手写**（Task 2）：包里有 `just_pressed` 边沿（`core/net/packet_input_source.gd:6-9` 自陈"走 reliable 是为不丢边沿"）⇒ 丢包策略必须**保住边沿**：合并轴值时把边沿**或**起来（或只丢"既无边沿、又被后一包覆盖"的中间包）。★ 这一条**写错的表现是"偶发丢一跳"**，真链路才看得见。
2. **"每 tick 一包"本身可能是对的**（Task 2）：包是 60Hz、tick 也是 60Hz ⇒ ρ=1 的根因是**开局突刺**（服务端自述"1 秒内 0→8 然后停住"）。所以修法可能是"**每 tick 把积压抽干、只应用最后一包**"（输入是**状态**不是命令流）⇒ 先量 ρ 再定方案，别照抄"加个上限"。
3. **上限要能与客户端对上**（Task 2）：丢包会让客户端预测/回滚与服务端**分叉** ⇒ 上限要么足够大（正常网络下永不触发），要么配一条"服务端丢过包"的可观测信号（日志/计数）供真链路核对。
4. **钳位的方向与口径**（Task 1）：钳到 `[-1, 1]`（轴是**归一化**量）；`NaN`/`INF` 也让它们变 `0`（`clampf` 对 `NaN` 的行为**要实测**，别假设）；★ 别顺手把 `mult` 或 `speed_target` 那套也改了（那是手感，属别的域）。

---

### Task 1: 服务端钳位轴值（audit §2.2）

**Files:**
- Modify: `server/match/match_host.gd`（消费输入包那一带，`:186-196` 与 `:245-255` 附近 —— **先 grep 定位**）
- Create: `tests/probe/input_sanitize_probe.gd`（`extends Node` 场景探针；或按本仓惯例落进既有探针）

**Interfaces:**
- Consumes: 客户端生产 `core/net/packet_input_source.gd:121` `_axis = pkt.get("ax", 0.0)` → `:175` `return _axis`（**无界**）；服务端 `server/match/match_host.gd:190` `(_pending_input[role] as Array).append(pkt)`（**无边检/钳位/限速**）；位移在 `scenes/player/player.gd:373` `var target_velocity_x = horizontal_input * speed_target * mult.x`。
- Produces: 服务端应用输入前把它**sanitize**（钳到 `[-1,1]`、非有限值 → `0`），落成一个**纯函数**（例 `static func sanitize_axis(v: float) -> float`）便于 headless 断言。

- [ ] **Step 1: 定位（先 `grep` 复核行号，别照抄）**

Run: `grep -n "_pending_input\|pop_front\|apply_input\|_axis" server/match/match_host.gd | head -20`
Run: `grep -n "get(\"ax\"\|_axis\|return _axis" core/net/packet_input_source.gd | head`
★ 把两条输出写进报告，并确认"服务端在哪一行**第一次**用到了客户端给的轴"。

- [ ] **Step 2: 写"能红"的断言**

探针里断言 `sanitize_axis`：① `-1.0 / 0.0 / 1.0` **原样**返回（合法值不变 —— 这条是"没改手感"的钉子）；② `50.0 → 1.0`、`-50.0 → -1.0`；③ `NAN` / `INF` / `-INF` → `0.0`（★ `clampf` 对 `NaN` 的行为**先实测**再定实现）；④ `0.5` 不变。
★ 再加一条**集成**断言（承重）：喂一个 `ax=50` 的输入包给权威回路 ⇒ 玩家**不会**瞬移（位移与 `ax=1` 那一帧相同）。

- [ ] **Step 3: 跑它，确认红**

Run: `timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/<你的冒烟>.gd`（纯函数那几条）
Run: 场景探针 `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/<你的探针>.tscn`
⇒ ① 应红（函数还不存在）或 ④ 红（`ax=50` 时位移是 `ax=1` 的 50 倍）。把原文写进报告。

- [ ] **Step 4: 实现**

`sanitize_axis(v)`：非有限 → `0.0`；否则 `clampf(v, -1.0, 1.0)`。在服务端**应用输入的那一处**调用它。
★ 只在**服务端消费侧**做（客户端不必钳；非法值本来就只可能来自异常客户端）。

- [ ] **Step 5: 跑它，确认绿 + **逐条**变异**

Run: 同 Step 3 ⇒ 绿。
变异（档 3 ⇒ **每条承重断言各来一次**）：① 把 `clampf` 去掉 ⇒ ② 红；② 把非有限值那支改成 `return v` ⇒ ③ 红；③ 把 `sanitize_axis` 换成恒等 ⇒ ④ 红。每次复原。
★ 把三条变异的"红在哪条断言"记进报告。

- [ ] **Step 6: 真链路跑批**

★ 先问用户认领；再按 `AGENTS.md` §1：`lobby_alive` 检查 → 跑 `tests/scripts/` 里那支与输入/回滚最相关的（例 `pvp_match_smoke.sh`，★ 它的 `sleep` 偏短，实测需 12 秒；跑不通先看是不是 harness 时序）→ 前后 `tasklist` 干净 → `kill_port_range 7800 8300`。
★ 结论里写清"**多进程抢 CPU 会放大换场卡顿**"这条环境口径；时序类结论**同配置跑两次**。

- [ ] **Step 7: 提交**

```bash
git add server/match/match_host.gd tests/probe/<探针>.gd tests/probe/<探针>.gd.uid tests/probe/<探针>.tscn
git commit -m "fix(server): 服务端钳位客户端轴值(非有限→0、|ax|≤1)+ 集成断言:异常包不再能瞬移"
```

---

### Task 2: 输入队列有界且积压可恢复（audit §2.3）

**Files:**
- Modify: `server/match/match_host.gd`（`:186-196` append 侧 + `:245-255` 消费侧）
- Modify/Create: 探针（可并入 Task 1 那个；或新建 `tests/probe/input_queue_probe.gd`）

**Interfaces:**
- Consumes: 现状 —— append **无上限**；消费 `:251` `var pkt: Dictionary = q.pop_front()`（**每 tick 一包**）；服务端自述（`:159`）"队列在开局 1 秒内从 0 跳到 8 然后就永远停在那儿（**ρ=1，没有回复力**）"。
- Produces: 队列有**硬上限**且**积压能被抽干**；丢包策略**保住 `just_pressed` 边沿**。

- [ ] **Step 1: 量 ρ（先把现状钉成数字）**

Run: `grep -n "队列\|ρ\|rho\|积压" server/match/match_host.gd | head`（找到它自述那段与是否有现成计数）
Run: 在探针里构造"每 tick 灌 1 包、跑 120 tick"的回路，**打印队列长度序列**（改前）
★ 把序列写进报告 —— 这是"改前基线"，也是本任务"到底修没修好"的判据（改后必须**不随时间发散**）。

- [ ] **Step 2: 写"能红"的断言**

① 队列长度**永不超过上限**（灌 200 包 ⇒ 上限内）；② 灌完停 1 秒后队列**排空**（`== 0`，即"有回复力"）；③ ★ **边沿不丢**：构造"包 A 带 `just_pressed=开火`、其后 5 个包不带"的序列 ⇒ 抽干后**必须**观察到那次开火恰好 1 次；④ 正常速率（每 tick 1 包）下**行为与改前逐帧相同**（这条是"别改正常手感"的钉子）。

- [ ] **Step 3: 跑它，确认红** ⇒ ② 必红（现状 ρ=1）。

- [ ] **Step 4: 实现（先定策略，写进注释）**

候选（报告里说明选哪个、为什么）：
  (a) **每 tick 抽干**：消费全部待处理包，轴取**最后一包**，边沿按 **OR** 合并 ⇒ 输入是"状态"而不是"命令流"，ρ 自然归零；
  (b) **硬上限 + 丢最旧**（若无边沿则丢，带边沿的保留）；
  (c) (a)+(b) 的组合（先抽干、超限时丢最旧的非边沿包）。
★ 无论选哪个，**上限值**要写进注释并说明依据（正常网络 RTT 下不会触发）。

- [ ] **Step 5: 跑它，确认绿 + **逐条**变异**

变异：① 把上限去掉 ⇒ ① 红；② 把抽干改回每 tick 一包 ⇒ ② 红；③ 把边沿 OR 去掉 ⇒ ③ 红。各自复原并记录。

- [ ] **Step 6: 真链路跑批**（同 Task 1 Step 6 的纪律；★ 至少跑**两遍**同配置，因为这条改的正是时序）

- [ ] **Step 7: 登记边界**

★ 在 `registered-debt.md` **§六** 写清：客户端的预测/回滚在"服务端丢过包"时的表现**未实测**（本任务只保证服务端队列有界、边沿不丢）；翻案条件 = 有一条真链路能造出丢包并比对两端状态。

- [ ] **Step 8: 提交**

```bash
git add server/match/match_host.gd tests/probe/<探针或冒烟> docs/eng/registered-debt.md
git commit -m "fix(server): 输入队列有界且积压可抽干(ρ=1 → 回复力);丢包保住 just_pressed 边沿"
```

---

## 本计划**不含**

- **§2.4（60 条 `@rpc` 无一指定 channel）** —— **单独一份**（它动 60 处声明，风险与验证面都不同）。
- **§2.5 / §2.6** —— Plan B；**§2.1 / §2.9 / §2.10 / §2.11** —— Plan C；**§2.7 / §2.8** 已判"记录而不修改"。
- **反作弊**（恶意客户端伪造合法范围内的包）—— 用户已裁定不承担；本计划只做**健壮性**。
