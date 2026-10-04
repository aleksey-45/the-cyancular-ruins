# 给 RPC 分流到不同 channel（audit §2.4）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全仓 **60 条 `@rpc` 无一例指定 `transfer_channel`** ⇒ 全部挤在通道 0 上按序传输：一次 `bullet_spawn` 的**重传**会顶住它后面**所有**权威事件（含 60Hz 输入与 `match_sync`）。本计划按**流量类别**给它们分流，让"一次性可靠载荷"的重传**不再堵住**"高频快照/输入"。

**Architecture:** 改动**只加参数**（`@rpc(mode, sync, call_local, transfer_channel)` 的第四项），但**它改的是传输语义** ⇒ 是本批最危险的一步，故单独一份。核心是**先把通道划分定成一张表**（单一来源、写进 `docs/eng/netplay.md`），再逐条对照 `@rpc` 声明落参数 + 一条**机械守卫**核"表与声明一致"。

**Tech Stack:** GDScript（Godot 4.7.1）、`MultiplayerAPI` 的 `@rpc` 注解、ENet peer、真链路跑批。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.4 + 用户裁定（"§2 也可以做，拆分细一点" + "2.4 单独一份"）。

## Global Constraints

- **档 3（协议）** ⇒ 全套：纯逻辑 + 场景探针 + **逐条**变异 + **真链路跑批** + **逐任务评审**。
- ★★ **先确认通道容量**（Review Focus 1）：`@rpc` 的第四项只有在 **peer 建了足够多通道**时才有意义 —— 先 `grep` 出 `ENetMultiplayerPeer` 的 `create_server(...)` / `create_client(...)` 调用**有没有给 `max_channels`**（Godot 4 的默认值与上限**要读源码或实测**，别假设）。
- ★★ **真链路纪律**：占 7777 的步骤**先查 `lobby_alive`**；跑批前后 `tasklist | grep -i godot` 必须为空；收尾 `kill_port_range`；**验证阶段先列测试给用户认领**。
- ★ **不许改可靠性语义**：`reliable`/`unreliable` 的选择**保持原样**（审计自己说"transfer_mode 的分工本身是对的，缺的只是 channel"，见 `net_bus.gd:232-235`/`253-255` 注释）—— 本计划**只加通道**。
- 逐个文件点名 `git add`；**绝不** `git add -A`；提交前逐文件 `git diff` 认领每个 hunk。
- 判据是 grep 文本 / 真链路判词，不是退出码。

## Review Focus

1. **通道容量是前提，不是细节**（Global Constraints 已述）：若 peer 只建了 1~3 个通道，而计划要用到 3 号以上 ⇒ 要么调整划分方案、要么同时改建 peer 的那一处（★ 那属于"改协议初始化"，要单独说明并加重验证）。
2. **同一"流"必须同通道**（否则重排）：判断标准是"**它后面的东西能不能等它**"。归类建议（先按实况数一遍再定）：
   - **通道 0（保留默认）**：`claim_role` / `match_sync` / 加入离开 / 一次性握手 —— **少而关键**；
   - **通道 1**：**快照类**（`unreliable`，例 `snapshot_world`）—— 丢了就丢，**绝不能被可靠重传顶住**；
   - **通道 2**：**输入类**（60Hz，例 `input`）—— 同上；
   - **通道 3**：**一次性可靠载荷**（例 `bullet_spawn` / `weapon_*` / `match_sync_data`）—— **允许重传**，但**别堵住别人**。
   ★ `call_local` 与通道无关（别顺手改）；`@rpc("any_peer")` 的那些要**单独过一遍**（谁在发、发多频繁）。
3. **一条声明都不许漏**（Task 2 的守卫）：60 条是**会变的枚举** ⇒ 守卫不能写死"60"，要**遍历源码**取全部 `@rpc(` 声明，与**通道表**（同一份文档里的表）对账；★ 表是单一来源，声明里只写数字。
4. **真链路的判据是"不回归"，不是"变快了"**：本计划**不要**用"卡顿变小了"当判据（多进程抢 CPU 会污染时序）；判据是既有真链路脚本**仍 PASS** + 一条**新增的可观测证据**（例：服务端日志里"通道 1 上重传 N 次"这类计数，能证明分流真的生效）。

---

### Task 1: 定通道表并落到声明（audit §2.4）

**Files:**
- Modify: `docs/eng/netplay.md`（新增"**RPC 通道划分表**"一节 —— 单一来源）
- Modify: 承载 `@rpc` 声明的文件（**先 `grep` 出清单**；已知至少 `core/net/net_bus.gd`、`core/net/net_bus_ext.gd`）
- Modify: 建 peer 的那一处（**仅当** Review Focus 1 判定通道不够）

**Interfaces:**
- Consumes: `@rpc` 声明 **60** 条、`transfer_channel` **0** 命中（审计实测）；`net_bus.gd:234` `@rpc("authority", "unreliable")`（snapshot_world）与 `:255` `@rpc("authority", "reliable")`（match_sync_data）为样例。
- Produces: `docs/eng/netplay.md` 里的通道表（**通道号 → 语义 → 该通道上允许的 RPC 名单**）+ 每条声明都带上第四项参数。

- [ ] **Step 1: 清点（三条命令，输出全进报告）**

Run: `grep -rn "@rpc(" --include=*.gd . | wc -l`（总数，审计说 60 —— 复核）
Run: `grep -rn "@rpc(" --include=*.gd . | sed 's/:.*@rpc(/ -> /' | head -70`（逐条：文件 + 参数）
Run: `grep -rn "transfer_mode\|transfer_channel\|call_local" --include=*.gd . | head`（现有分区语义的注释线索）
Run: `grep -rn "ENetMultiplayerPeer\|create_server(\|create_client(" --include=*.gd core/ server/ | head`（**通道容量**）

- [ ] **Step 2: 写通道表（先文档、后代码）**

在 `docs/eng/netplay.md` 写表：**通道号 → 语义 → 允许的 RPC 名单（逐条点名）** + 一句"为什么这样分"（重传隔离）。
★ 名单要**点名到函数**（表与声明是同一份真相源的两面）；★ 把"peer 的 `max_channels`"也写进这一节。

- [ ] **Step 3: 改声明（逐条）**

给每条 `@rpc` 补第四项。★ 只补参数，**不动** mode/sync/reliable 那几项；★ 改完 `python tools/check_naming.py` 仍 OK；★ `grep -c "transfer_channel"` 应等于表里点名的条数。

- [ ] **Step 4: 静态自检（会红的）**

写一条一次性脚本（或探针）遍历 `@rpc(` 声明、抽出**函数名**，与 `netplay.md` 表里的名单**对账**：漏的/多的都报出来。★ 它现在必须**能红**（把某条声明的通道删掉 ⇒ 报"表里有、声明没写"）。

- [ ] **Step 5: 跑既有回归（headless 那批）**

Run: `timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/<与网络最相关的冒烟>` + 相关场景探针 ⇒ 绿。

- [ ] **Step 6: 变异（逐条）**

① 把某条**快照**类 RPC 的通道改回 0 ⇒ Step 4 的自检**必红**（表/声明不一致）；② 把某条**可靠**载荷的通道改到快照那条上 ⇒ 自检应红（表里两个语义不同）；复原。

- [ ] **Step 7: 真链路跑批**

★ 先问用户认领；按纪律查 `lobby_alive` → 跑 `tests/scripts/pvp_match_smoke.sh`（★ 实测它的 `sleep` 偏短，需 12 秒；跑不通先怀疑 harness 时序）+ 与房间/重连最相关的一支 → 前后 `tasklist` 干净 → `kill_port_range 7800 8300`。
★ 同配置**跑两次**再下时序结论；报告里附关键行原文。

- [ ] **Step 8: 提交**

```bash
git add docs/eng/netplay.md core/net/net_bus.gd core/net/net_bus_ext.gd <其它承载声明的文件>
git commit -m "feat(net): RPC 按流量类别分流到独立 channel(快照/输入不再被一次性可靠载荷的重传顶住);通道表落在 netplay.md 作单一来源"
```

---

## 本计划**不含**

- **§2.2 / §2.3（轴钳位、输入队列）** —— 另一份（它是**服务端消费侧**，不动传输层）。
- **§2.5 / §2.6** —— Plan B；**§2.1 / §2.9 / §2.10 / §2.11** —— Plan C；**§2.7 / §2.8** 已判"记录而不修改"。
- **加通道数（改协议初始化）** —— 若 Review Focus 1 判定需要，**先报告**再决定是否并进本计划（那会把爆炸半径从"注解参数"扩到"连接建立"）。
