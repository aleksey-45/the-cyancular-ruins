# 输入上行：手打包 + 冗余命令 + 丢包注入仪器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把联机输入上行从「60Hz × 164 B 的 `Dictionary`，走**可靠有序**通道」改成「手打包的**命令窗口** + 冗余 + **不可靠有序**通道」，并补上能证明它有效的丢包注入仪器。

**Architecture:** 复用快照那套编解码（一张 schema 表 + 首字节版本号 + `PackedByteArray`）扩一个「输入窗口」种类；发送端每包带**最近 N 条命令**；接收端按 `seq` **去重后仍"每物理 tick 恰应用一条"**（这是 C2 回滚 1:1 同序的前提，不许破）；通道从 reliable 降为 unreliable_ordered ⇒ 队头阻塞消失，边沿由冗余保证。判定：`-s` 冒烟（纯逻辑）+ 真链路批 + `--netstat` 读数。

**Tech Stack:** Godot 4.7.1 标准版 / GDScript / ENet（`ENetMultiplayerPeer`）/ Python 3（UDP 代理，仅测试用）

**Spec:** [`docs/eng/netcode-input-uplink.md`](../../eng/netcode-input-uplink.md)（本文档的**唯一**依据；另见 [`netcode-snapshots.md`](../../eng/netcode-snapshots.md) §5.2/§6 与 [`AGENTS.md`](../../../AGENTS.md) 的测试纪律）

## Global Constraints

- **判据一律 grep 判词文本**（`SMOKE OK` / `ALL-OK` / `RUN_ALL …`），**退出码从来不是判据**。
- **新守卫必须自带条数闸**（`_checks != EXPECTED_CHECKS` ⇒ 红），否则 `ALL-OK` 只等于"没有失败输出"。
- **档 3**（协议 / 输入包）：每条承重断言**逐条变异验证** + **真链路跑批** + **逐任务评审**。
- **逐个文件 `git add`**，绝不 `git add -A`；新建 `.gd` 连 `.gd.uid` 一起加；提交信息 `type(scope): 中文一句话`。
- 进导出包的脚本**禁用 `RegEx`**（裁剪模板 `module_regex_enabled: false`）。
- 命令行开关**必须写在 `--` 之后**（`OS.get_cmdline_user_args()`）。
- 跑测试**先问用户**；任何占 7777 的步骤先查 `lobby_alive`；真链路**前后**本线 Godot 进程必须为 0；**池外那两支不扫 7800-8300**。
- 时序类结论**同配置跑两次**再下。每次提交前跑 `python tools/check_naming.py`。**不推送**。
- 改动 `@rpc` 的**通道号**必须同步 `docs/eng/netplay.md` 的通道表（`rpc_channel_contract_smoke` 会红）——本计划**只改传输模式字符串，不改通道号**。

## Review Focus

1. **版本不匹配的老客户端**发来旧格式（`Dictionary`）载荷：解码必须**返回空 + 不 emit + 只报一次**，而不是把错位的值喂进服务器模拟 ⇒ 表现为"整局输入全丢"还是"响亮报错"，这条决定现场怎么定位。
2. **`seq` 纪元归零**（重连重协商把 `_ack_seq[role]` 归零）：去重的判据 `seq <= acked` 在新纪元第一包（`seq=1`）上**必须放行** —— 写反了 = 重连后该玩家再也动不了。
3. **超过窗口长度的突发**（客户端物理追赶一次发 3+ 条）：窗口 N=3 只覆盖 3 帧，更长的突发仍会丢命令 ⇒ **跳跃/开火这种边沿会不会丢**。
4. **缺号时 `ack` 会跳 >1**（窗口也没补上）：客户端的 C2 重放假定"每 tick 一条、无缺号"；需要确认 `PredictionRollback._handle_ack` 对"跳号"已有路径（或把它登记为边界）。
5. **代理自身的失真**：注入器自己成了瓶颈/丢包源 ⇒ 读数会把代理的账算到游戏头上 ⇒ 它必须**自报实际丢包率**。

---

### Task 1: 输入包换线格式（改名 + 编解码 + 两端接线）

**Files:**
- Rename: `core/net/snapshot_codec.gd` → `core/net/net_codec.gd`（`class_name SnapshotCodec` → `NetCodec`）
- Modify: `core/net/net_codec.gd`（加 `KIND_INPUT_BATCH` / `INPUT_SCHEMA` / `encode_input_batch` / `decode_input_batch`）
- Modify: `scenes/pvp_match_client.gd:491-511`（发送点：组包 → 编码）
- Modify: `core/net/net_bus.gd:203`（`send_input` 载荷 `Dictionary` → `PackedByteArray`，在此解码再 emit）
- Modify: `server/match/match_host.gd` `_on_input`（收到的仍是命令数组；本任务窗口 = 1）
- Modify: `server/match/match_snapshot.gd`、`tests/probe/snapshot_size_probe.gd`（改引用名）
- Create: `tests/smoke/input_packet_codec_smoke.gd`（+ `.gd.uid`）
- Modify: `tests/probe/allscript_probe.gd`（`EXPECTED_SCRIPTS` 161 → **162**）
- Modify: `docs/eng/netcode-input-uplink.md` §7（`~20B` 的订正已在 spec 里；接线后补实测）

**Interfaces:**
- Consumes: 既有 `PacketInputSource.pack_record(src: PlayerInput, seq: int, aim: Vector2) -> Dictionary`（**发送侧唯一来源，不许绕过**）
- Produces:
  - `NetCodec.PROTO_VERSION := 1` · `NetCodec.KIND_WORLD/OWN/INPUT_BATCH`
  - `NetCodec.INPUT_SCHEMA: Array = [["seq","i"],["ax","f"],["held","b"],["pressed","b"],["released","b"],["winst","i"],["aim","v2"]]`
  - `static func encode_input_batch(cmds: Array) -> PackedByteArray`（`cmds: Array[Dictionary]`，**升序**）
  - `static func decode_input_batch(data: PackedByteArray) -> Array`（失败返回 `[]`）
  - `PacketInputSource` 侧不变：`pack_record` 仍产出 `Dictionary`

- [ ] **Step 1: 纯改名并确认"零字节变化"**

`git mv core/net/snapshot_codec.gd core/net/net_codec.gd` + `git mv` 其 `.gd.uid`，改 `class_name` 与 4 处引用
（`match_snapshot.gd` / `net_bus.gd` / `snapshot_size_probe.gd` / 文档链接），然后**刷新全局类缓存**：

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --import
grep -c NetCodec .godot/global_script_class_cache.cfg   # 期望 ≥1；为 0 则 headless 会报 Identifier not declared
```

- [ ] **Step 2: 跑默认批确认读数逐位不变**

Run: `bash tests/run_all.sh`
Expected: `RUN_ALL OK(13 runs / 10 gated-assertions)`，且 `snapshot_size_probe` 的打印仍是
`世界包条目 … 368 B → 51 B`、`本人包 … 884 B → 102 B`（**改名不许动任何字节**）。

- [ ] **Step 3: 写失败的冒烟（3 条断言 + 条数闸）**

`tests/smoke/input_packet_codec_smoke.gd`（`extends SceneTree`；`PacketInputSource extends PlayerInput extends RefCounted`
⇒ **纯逻辑，`-s` 可跑**）：

```gdscript
const EXPECTED_CHECKS := 3
# ① 表与生产者的产出**逐键对齐**(去掉什么才红:改 INPUT_SCHEMA 的键/加字段不登记)
var src := PacketInputSource.new()
var pkt := PacketInputSource.pack_record(src, 7, Vector2(0.6, -0.8))
# 断言:pkt 的键集 == INPUT_SCHEMA 的键集(双向,差异要打印出来)
# ② 真实产出往返一致(去掉什么才红:encode/decode 任一侧写错位)
# 断言:decode_input_batch(encode_input_batch([pkt]))[0] 与 pkt 逐键一致(float 用 is_equal_approx)
# ③ 坏输入必须返回空(去掉什么才红:删掉版本/长度守卫)
# 断言:翻转首字节 ⇒ ==[];截断 5 字节 ⇒ ==[];拿世界包喂 decode_input_batch ⇒ ==[]
```

- [ ] **Step 4: 跑冒烟确认它红**

Run: `"$GODOT" --headless --path . -s res://tests/smoke/input_packet_codec_smoke.gd`
Expected: 脚本报 `Identifier "NetCodec"? … ` 或 `encode_input_batch` 不存在 ⇒ **FAIL**（未实现）。

- [ ] **Step 5: 实现 `encode_input_batch` / `decode_input_batch`**

在 `net_codec.gd` 里按**既有模式**加（`_pack`/`_unpack` 复用同一台机器，不许另写一套读写）：
头 `[PROTO_VERSION][KIND_INPUT_BATCH][count: u8]` + 每命令 `INPUT_SCHEMA` 打包 = **2 + 1 + 23×N 字节**
（`seq` 用 `T_I32` = 32 位、`ax` `T_F` = float32、三个位掩码 `T_U8`、`winst` `T_I32`、`aim` `T_V2` = 2×float32）。
`decode_input_batch` 走与 `decode_own` 同款守卫：**头不符 / 越界 / 尾部多余字节 ⇒ 返回 `[]`**；`count` 上限 8。

- [ ] **Step 6: 接线（发送 + 接收），窗口 = 1**

- `pvp_match_client`：`NetBus.rpc_id(1, "send_input", NetCodec.encode_input_batch([pkt]))`
- `net_bus.gd`：`func send_input(payload: PackedByteArray)` → `var cmds := NetCodec.decode_input_batch(payload)`；
  `cmds.is_empty()` ⇒ `_input_decode_warned(...)`（照抄快照那处**只报一次**的写法）并 `return`；否则 `input_received.emit(sender, cmds)`
- `match_host._on_input(caller, cmds: Array)`：本任务取 `cmds[0]`（窗口=1），入队逻辑**一字不改**
- ★ **RPC 通道号不动**（仍是 `"reliable", 1`）⇒ `netplay.md` 通道表不用改；`rpc_channel_contract_smoke` 应保持绿

- [ ] **Step 7: 跑三档并记录读数**

Run: 冒烟 + `bash tests/run_all.sh` + 真链路 `bash tests/smoke/pvp_match_smoke.sh`（**先查 `lobby_alive`**）
Expected: `INPUT PACKET CODEC OK(3 …)` / `RUN_ALL OK(14 runs / 13 gated-assertions)` / `SMOKE PASS`；
输入包字节数打印应为 **25 B**（旧 164 B），N=8 服务器下行 **≈10 KB/s**（旧 76 KB/s）。

- [ ] **Step 8: 逐条变异验证（档 3 必做）**

改 → 跑 → **确认红** → **在 `finally` 里用内存原字节还原**（见 `.superpowers/net/mutate.py` 的写法）：
M1 `_put_f` 改 0.5 步进 ⇒ 断言②红；M2 `INPUT_SCHEMA` 的 `aim` 改 `T_I32` ⇒ 断言①②红；
M3 `decode_input_batch` 删版本守卫 ⇒ 断言③红。

- [ ] **Step 9: 提交**

```bash
git add core/net/net_codec.gd core/net/net_codec.gd.uid core/net/net_bus.gd \
  core/net/packet_input_source.gd scenes/pvp_match_client.gd server/match/match_host.gd \
  server/match/match_snapshot.gd tests/smoke/input_packet_codec_smoke.gd \
  tests/smoke/input_packet_codec_smoke.gd.uid tests/probe/snapshot_size_probe.gd \
  tests/probe/allscript_probe.gd docs/eng/netcode-input-uplink.md docs/eng/netcode-snapshots.md
git commit -m "feat(net): 输入包手打包(164B→25B) —— 复用快照那套 schema 表与版本字节"
```

---

### Task 2: 消费端按 `seq` 去重（承重：1 seq = 1 tick）

**Files:**
- Modify: `core/net/packet_input_source.gd`（加 `ingest_window`，**不动** `push_pending` 的签名与语义）
- Modify: `server/match/match_host.gd` `_on_input` + `_physics_process`（消费循环改为"窗口入队 + 每 tick 取一条"）
- Modify: `tests/smoke/server_input_sanitize_smoke.gd`（21 → 25 条）

**Interfaces:**
- Consumes: `PacketInputSource.push_pending(q, pkt, cap) -> int`（返回**丢之前**的原始深度，包络靠它）
- Produces: `static func ingest_window(q: Array, cmds: Array, acked: int, cap: int) -> int`
  —— 只接受 `seq > acked` **且** `seq > q.back().seq`（保序；乱序到达的旧窗口整包作废）**且**队内无同 `seq`；
  逐条 `push_pending`；返回见过的最大原始深度（没有新命令时返回 `0`）。

- [ ] **Step 1: 写失败判据（4 条 + 条数闸 21→25）**

在 `server_input_sanitize_smoke.gd` 加一组断言（红线都写在注释里）：
① 同一 `seq` 灌 3 次 ⇒ 队里只有 1 条（**去掉去重 ⇒ 红**）；
② `seq <= acked` ⇒ 返回 0 且队不变（**去掉这条 ⇒ 重连后第一包进不来**）；
③ 窗口 `[3,4,5]` 在 `acked=2` 时 ⇒ 入队 3 条；再来窗口 `[3,4,5]` ⇒ 队不变（**幂等**）；
④ **乱序**：先吃 `[8,9,10]`，再吃 `[6,7]` ⇒ 队仍是 3 条，`seq` **保持升序**（**去掉 `seq > q.back()` ⇒ 顺序错乱**）。

- [ ] **Step 2: 跑冒烟确认它红**

Run: `"$GODOT" --headless --path . -s res://tests/smoke/server_input_sanitize_smoke.gd`
Expected: `FAILED`，报 `ingest_window` 不存在。

- [ ] **Step 3: 实现 `ingest_window` 并接进 `_on_input`**

`_on_input`：`var raw := PacketInputSource.ingest_window(_pending_input[role], cmds, _ack_seq.get(role, 0), cap)`
—— `raw > 0` 时才更新包络与丢弃计数（**重复包不是抖动的证据**）。消费循环保持不变（每 tick 恰 `pop_front` 一条）。

- [ ] **Step 4: 跑冒烟 + 默认批**

Run: `bash tests/run_all.sh`
Expected: `SERVER INPUT SANITIZE OK(25 …)` / `RUN_ALL OK(14 runs / 13 gated-assertions)`。

- [ ] **Step 5: 变异验证**

M4 删掉 `seq <= acked` 那行 ⇒ 判据②红；M5 删掉 `seq > q.back().seq` ⇒ 判据④红；
M6 把 `ingest_window` 的返回改成 `q.size()` ⇒ 包络判据红（与既有 M6 同族，确认没被新代码破坏）。

- [ ] **Step 6: 提交**

```bash
git add core/net/packet_input_source.gd server/match/match_host.gd tests/smoke/server_input_sanitize_smoke.gd
git commit -m "feat(net): 输入按 seq 去重/保序入库(1 seq = 1 tick 的前提) —— 为冗余命令铺路"
```

---

### Task 3: 冗余命令 + 通道降为 `unreliable_ordered`

**Files:**
- Modify: `scenes/pvp_match_client.gd`（新增最近 N 条已发命令的环形表；每包发最近 N 条）
- Modify: `core/net/net_bus.gd:203`（`@rpc("any_peer", "call_remote", "unreliable_ordered", 1)`）
- Modify: `tests/smoke/server_input_sanitize_smoke.gd`（+2 条：窗口突发 / 窗口外有界）

**Interfaces:**
- Consumes: Task 1 的 `encode_input_batch` / `decode_input_batch`（已支持 N 条）· Task 2 的 `ingest_window`
- Produces: `pvp_match_client._recent_cmds: Array`（**存已编码过的 `Dictionary` 原样**，容量 `INPUT_REDUNDANCY := 3`）

- [ ] **Step 1: 写失败判据（2 条）**

① 一 tick 到 3 条不同命令（`[n+1,n+2,n+3]`，窗口 3）⇒ **全部入队**（去掉冗余 ⇒ 只入 1 条 ⇒ 红）；
② 窗口外的突发（一次 10 条）⇒ 队 ≤ `QUEUE_CAP_MAX` 且 `seq` 升序（有界 + 保序 ⇒ 红在任一侧）。

- [ ] **Step 2: 实现发送端 ring**

`pvp_match_client._physics_process`：`_input_seq += 1` → `pack_record` → `_recent_cmds.append(pkt)` → 裁到 3 →
`NetCodec.encode_input_batch(_recent_cmds)` → `rpc_id(1, "send_input", …)`。
★ **重发的是存下来的原包内容，绝不许重新采样当前输入**（重采 = 同一 `seq` 两份不同内容 = 静默分歧）。

- [ ] **Step 3: 改传输模式并同步契约**

`net_bus.gd` 的 `send_input` 改 `"unreliable_ordered"`，**通道号仍是 1**（⇒ ENet 道 2，flags=0 = 有序不重传）。
Run: `"$GODOT" --headless --path . -s res://tests/smoke/rpc_channel_contract_smoke.gd`
Expected: `RPC CHANNEL CONTRACT OK(6 …)`（通道表**无需改**）。

- [ ] **Step 4: 跑默认批 + 真链路**

Run: `bash tests/run_all.sh`，然后 `bash tests/probe/rejoin_probe.sh` 与 `bash tests/smoke/pvp_match_smoke.sh`
Expected: `RUN_ALL OK(14 runs / )` / `REJOIN PROBE: ALL-OK(5 …)` / `SMOKE PASS`；输入包 **≤ 72 B**。

- [ ] **Step 5: 变异验证**

M7 把 `_recent_cmds` 改成每包只发当前一条 ⇒ 判据①红；M8 去掉发送端裁剪 ⇒ 判据②红。

- [ ] **Step 6: 提交**

```bash
git add scenes/pvp_match_client.gd core/net/net_bus.gd tests/smoke/server_input_sanitize_smoke.gd \
  docs/eng/netplay.md
git commit -m "feat(net): 输入包带最近 3 条命令冗余,通道降为 unreliable_ordered —— 解掉可靠有序的队头阻塞"
```

---

### Task 4: 丢包注入仪器（否则 Task 3 的收益无法定案）

**Files:**
- Create: `tests/scripts/netem_proxy.py`（UDP 代理：丢包率/延迟/抖动，**种子固定**，退出时打印**实际**丢包数）
- Modify: `core/net/net_bus.gd` `start_client`（读 `--proxy-port=N` ⇒ 连 `127.0.0.1:N`，**单点开关**：两处连接点都走它）
- Create: `tests/scripts/netem_run.sh`（起大厅/worker → 起代理 → 客户端带 `-- --netstat --proxy-port=N` 跑 60s → grep 读数）
- Modify: `tests/README.md`（跑法 + "它测什么/不测什么"）

**Interfaces:**
- Consumes: `NetBus.start_client(addr, port)`（`scenes/lobby_page.gd:333` 与 `scenes/pvp_match_client.gd:1192` 两个调用点共用它）
- Produces: `-- --proxy-port=N`（写在 `--` 之后）· 代理 CLI：`--listen 7801 --forward 7802 --loss 5 --delay-ms 40 --jitter-ms 20 --seed 20261009`

- [ ] **Step 1: 写代理并自证它不是瓶颈**

Python 3 标准库 `socket` + `select`；双向转发 UDP 数据报；按种子决定丢/延迟（延迟用最小堆排队）。
**每 5 秒打印**：`转发 A→B n / 丢弃 n / 实际丢包率 x%（目标 y%）`。
Expected: 目标 5% 时实测丢包率在 **4~6%**，且转发速率不成为瓶颈（打印包/秒）。

- [ ] **Step 2: 接上 `--proxy-port` 开关**

`start_client` 开头：`if OS.get_cmdline_user_args().has(...)` ⇒ 解析出端口并改 `addr/port` 指向本机代理，
`print("[netem] 经代理 127.0.0.1:%d 连接真实 %s:%d")`（**一行日志 = 现场可确认开关生效**）。

- [ ] **Step 3: 写跑法脚本，跑**两次**（时序类结论必须同配置两遍）**

Run: `bash tests/scripts/netem_run.sh --loss 5`（两次）
Expected: 客户端 `[netstat]` 行里 `lag_ms − ping`（**服务器侧积压**）在
**改动前**出现"尖峰后不回落到 0"、**改动后**回到 0 附近徘徊 ⇒ **这就是 Task 3 的证据**。

- [ ] **Step 4: 记录读数并登记缺口**

在 `netcode-input-uplink.md` §8 把第 1/2 条（"队头阻塞影响量没有实测"）改成**实测读数**（两次），
并写清代理引入的额外延迟（代理自身的 RTT = 本机回环，可忽略但要写出来）。
★ 若读数**不支持**"队头阻塞有害"的预期 ⇒ **照实写**，并考虑把 Task 3 回退（那时它是净增复杂度）。

- [ ] **Step 5: 提交**

```bash
git add tests/scripts/netem_proxy.py tests/scripts/netem_run.sh core/net/net_bus.gd \
  tests/README.md docs/eng/netcode-input-uplink.md
git commit -m "test(net): 补 UDP 丢包/抖动注入仪器 —— 用它结案输入通道的队头阻塞"
```

---

## 其它三个子系统（**另立计划**，各有前置决策）

本计划只做「输入上行」。审计出的另外三条**不是同一子系统**，各自需要一次决策或一次测量才能动手：

| 子系统 | 前置 | 单独计划里要做的第一件事 |
|---|---|---|
| **lag compensation**（"打中没伤害"） | 先用 Task 4 的代理量出缺口是否真的发生；且要先分清**即时光束**（hitscan，该回退命中盒）与**实体子弹**（该由客户端提前量） | 定"回退谁/回退到哪一刻"（服务器已有 `_rw_buf` 的逐帧位置历史可复用） |
| **相关性 / 带宽上限**（大乱斗规模） | 先定**最大人数**：≤8 人则 72 KB/s 够用，**这条可以直接删掉**；≥16 人才值得做优先级累加器 | 定人数目标 |
| **playout 缓冲插值**（渲染手感） | **仓主拍板**：现状恒滞后 22.6~37.2px vs 缓冲 3 tick = 50ms 常量 | 先做客户端时钟同步（否则"渲染在多久之前"不可算） |

## Self-Review

- **Spec 覆盖**：§4.1（164 B）→ Task 1；§4.2（队头阻塞）→ Task 3；§4.3（顺序依赖）→ Task 1 必须先于 Task 3；§5.2 的"去重"→ Task 2；§6 判据 → Task 1/2 的条数闸 + Task 4 的读数；§7 文档漂移 → Task 1 Step 9。
- **类型一致**：`encode_input_batch`/`decode_input_batch`/`ingest_window` 三个签名在 Task 1/2/3 中逐字一致；`push_pending` 的签名与返回语义**全程不变**（既有 6 条断言继续成立）。
- **Review Focus 各有归属**：#1 → Task 1 Step 3 断言③；#2 → Task 2 断言②；#3 → Task 3 断言①；#4 → Task 3 Step 4 的真链路 + §8 登记；#5 → Task 4 Step 1 的自报丢包率。
- **未决项（不藏）**：`INPUT_REDUNDANCY = 3` 是按 §2 的"0.05s 保护"定的，不是按真对局丢包分布定的 —— Task 4 的读数可能要求改它；Task 3 若读数不利则回退。
