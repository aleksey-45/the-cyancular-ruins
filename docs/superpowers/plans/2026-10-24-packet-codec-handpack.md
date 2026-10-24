# 联机包体手打包与编码器重写 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ★ **写于 2026-10-24**。**已拍板（2026-10-24，仓主）**：本批全做（T1+T2+T3）；上行按原 spec 埋 `st`/`ct` 两个扩展字段（26→34 B/包）；执行方式 = **Native**（本会话按任务逐个实现，最后整体评审）。
>
> ★ **开工前置（硬）**：工作区里有两批**未提交**的他人改动在飞 ——（a）30Hz 采样重构（`TICKS_PER_RECORD` / `SampledInput` / `PredictionRollback.ticks_per_record` / 下行 30Hz）；（b）文档清理（删 `docs/superpowers/{plans,specs}/`、`docs/eng/debt/`、重写 `AGENTS.md`/`CLAUDE.md`）。本计划要改的文件与（a）**几乎完全重叠**（`net_bus.gd` / `pvp_match_client.gd` / `match_host.gd` / `match_state.gd` / tests）⇒ **必须等（a）提交、工作区干净后再动手**（否则逐 hunk 认领不可行，提交时会把别人的改动带走）。

**Goal:** 把上行输入包从 164 B/包（`Dictionary`）压到手打包 **34 B/包**（头 2 + 记录 32，含 `st`/`ct` 两个 4 B 扩展字段；30Hz ⇒ 1.02 KB/s/客户端，约 −79%）；把快照编码器从「每值 `resize()`+`append`」改成「按 schema 预算容量、一次性分配、下标写」（`encode_world` N=16 **294 µs → ≤ 50 µs**）；把快照里的 bool 改成 1 bit（世界条目 51→48 B、本人包 102→94 B）。

**Architecture:** 复用快照那套「首字节版本号 + 种类字节 + 一张 schema 表」的编解码器：`core/net/snapshot_codec.gd` 改名为 `core/net/net_codec.gd`（`class_name NetCodec`，它已是**全项目**线格式编解码器），新增 `KIND_INPUT` / `INPUT_SCHEMA` / `encode_input` / `decode_input`；`NetBus.send_input` 的载荷换成 `PackedByteArray`，在 RPC 入口解码后仍 emit 同形状 `Dictionary` ⇒ **服务端消费面（`MatchHost._on_input` / `InputIntake`）逻辑不动**（只多两处存档 + 读数）。编码器内部改成一次性分配 + 下标写（对外字节**逐位不变**），再把 `T_BOOL` 改成 1 bit 位流。版本字节是**全协议唯一**来源（两份版本号会漂）：Task 1 升到 2，Task 3 升到 3。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）/ GDScript / ENet

**Spec（2026-10-24 清理后仍存活的文档）:**
- [`docs/eng/netcode-input-uplink.md`](../../eng/netcode-input-uplink.md) §2（164 B 实测）§5.1（手打包方案）
- [`docs/eng/netcode-snapshots.md`](../../eng/netcode-snapshots.md) §1.2/§5.1（快照线格式与 schema 表）§5.4（载荷口径的赌注）
- [`docs/eng/netplay-rpc-channels.md`](../../eng/netplay-rpc-channels.md)（通道表，**本批不改**）
- [`AGENTS.md`](../../../AGENTS.md)（档 3 纪律、测试经济学、共用工作树）

> ★ **已删文档的结论已内联**：原先引用的 `docs/superpowers/specs/2026-10-13-net-bandwidth-and-cpu-optimization-design.md`（编码器 294 µs / 一次性分配 / 决策 #6 的上行扩字段）与 `docs/superpowers/plans/2026-10-09-input-uplink-codec-and-redundancy.md`（输入手打包草案）已随 2026-10-24 文档清理删除；与本批有关的结论抄在 §1，不必去点死链。

---

## 0. 现状与目标读数（写计划时点的实测 / 算术）

| 量 | 现在 | 本批后 | 依据 |
|---|---|---|---|
| 上行输入包（每包 1 条记录） | **164 B**（7 键 `Dictionary`） | **34 B**（头 2 + 记录 32；含 `st`/`ct` 各 4 B） | 164 为实测（`netcode-input-uplink.md` §2）；34 为 schema 算术 |
| 上行 / 客户端 | 164 × 30 ≈ **4.9 KB/s** | 34 × 30 ≈ **1.02 KB/s** | 30Hz 单记录（`TICKS_PER_RECORD = 2`） |
| 世界包条目 | **51 B**/人 | **48 B**/人 | `snapshot_size_probe` 实测 51；bool 4→4 bit |
| 本人包 | **102 B** | **94 B** | 实测 102；bool 10→10 bit |
| N=8 服务器出向（载荷） | ≈ **121 KB/s** | ≈ **113 KB/s** | 30Hz 折算：8×(世界+本人)×30 |
| `encode_world` 单次（N=16） | **294 µs** | **≤ 50 µs** | 一次性量具实测（原 spec §1.3，文件已删；读数复述在此） |

★ 口径一律是**载荷字节**（不含 RPC 信封 / ENet / IP·UDP 头）。线上字节仪器本仓仍然没有（原债单 §8.11 的结论；该编号随 `docs/eng/debt/` 清理失效）——本批**不补**，属另立计划。所以本表里的"KB/s"都是载荷口径或算术折算，写文档时必须这么标。

---

## 1. 与已删历史文档的关系（结论抄在这里，别去点死链）

2026-10-24 的文档清理删掉了 `docs/superpowers/plans/`、`docs/superpowers/specs/` 的**全部**历史计划/spec，以及 `docs/eng/debt/` 分册。与本批直接相关：

1. ★ **`held` 位掩码必须 u16**：`BIT_HASTE = 128`、`BIT_REWIND = 256`（全按最大 415）。已删的输入手打包草案（60Hz 单包时代）把它当 `u8`，照抄会**静默截断**。本计划按 2026-10-24 的 30Hz 单记录 / `TICKS_PER_RECORD = 2` 基线重写。
2. **编码器 294 µs（N=16）** 是一次性量具读到的改前读数；改成「一次性分配 + 下标写」后目标 **≤ 50 µs**（Task 2）。
3. **上行扩两个字段**（原 spec 决策 #6，仓主 2026-10-24 拍板执行）：`st` = 本端**最近成功解码**的服务器快照 tick；`ct` = 本帧客户端物理帧号（`Engine.get_physics_frames()`）。**本批只落位**（客户端填、服务器存档 + `--netstat` 读数），真正的消费者是未来的增量批 —— 但线格式**只改这一次**。
4. 已删的 stream/增量计划提出的 **合流 / 线上字节仪器 / 增量**，以及输入侧的 **seq 去重 / 冗余命令 / 不可靠通道 / 丢包注入**，**本批都不做** —— 它们属"怎么发"与"可靠性"，不是"编码"；要做时按档 3 另立计划。
5. **量化**：仓主已裁定本轮不做（碰回滚面：`c2` 是回滚锚点，两端必须同量化）。本批的位打包**只动 bool**（无损、无值域判断），不碰任何 float 精度。

## 2. 已拍板（2026-10-24，仓主）

1. **本批全做**：Task 1（上行手打包 + `st`/`ct`）+ Task 2（编码器重写）+ Task 3（bool 位打包）。
2. **上行扩展字段：埋**（一次改完线格式）：`INPUT_SCHEMA` 加 `["st","i"]`、`["ct","i"]` ⇒ 包 **26 → 34 B**。
3. **执行方式：Native**（本会话按任务逐个实现 + 最后整体评审）。

---

## Global Constraints

- **判据一律 grep 判词文本**（`SERVER INPUT SANITIZE OK` / `SNAPSHOT SIZE PROBE: ALL-OK` / `RUN_ALL …` / `SMOKE PASS`），**退出码从来不是判据**。
- **新守卫必须自带条数闸**：`server_input_sanitize_smoke.gd` 用 `_checks != 24` 兜底（与 `EXPECTED_CHECKS` 同等效力；本批**不**改成 `EXPECTED_CHECKS` —— 那会把 `run_all.sh` 的 gate 账与 `tests/README.md` 的读数一起卷进来，属另一件事）。
- **档 3**（协议 / 输入包 / 线格式）：每条**承重**断言做变异验证 + **真链路跑批** + 逐任务评审。
- **逐个文件 `git add`**，绝不 `git add -A`；新建 `.gd` 连 `.gd.uid` 一起加；提交信息 `type(scope): 中文一句话`。
- 进导出包的脚本**禁用 `RegEx`**；命令行开关**必须写在 `--` 之后**。
- 跑测试**先问用户**；任何占 7777 的步骤先查 `lobby_alive`；真链路**前后**本线 Godot 进程必须为 0；**池外那两支不扫 7800-8300**；时序类结论同配置跑两次。
- 每次提交前跑 `python tools/check_naming.py`；**不推送**。
- ★ **通道号 / 传输模式一个都不改**（`send_input` 仍是 `@rpc("any_peer","call_remote","reliable",1)`）⇒ `rpc_channel_contract_smoke` 与 `netplay-rpc-channels.md` 的通道表**应保持绿、不改表**；只改载荷编码。
- ★ **本批不新建 `.gd` 文件**（测试面 = 3 条新断言 + 0 新文件）⇒ `allscript_probe.EXPECTED_SCRIPTS`（现 188）**不变**。
- ★ **共用工作树**：提交前 `git status --short` + 逐文件 `git diff` 认领每个 hunk；不属于本批的改动不提交、也不"顺手修一下"。
- ★ **只订正本批触碰的事实**（类名、包字节数、输入包口径、CPU 读数）。`netcode-*.md` 里"快照 60Hz"那一类漂移是 30Hz 那批的账，**别在本批顺手改**。

## Review Focus

1. **`held` 位掩码超过 8 位**（`BIT_HASTE = 128`、`BIT_REWIND = 256`，全按最大 415）：打成 `u8` ⇒ **加速/回溯按住位被静默截断**，表现为"按住没反应"，且 C2 对账看不出来（两端用同一份被截断的输入，仍能同步）。→ Task 1 断言②（喂全位掩码往返）。
2. **版本字节两端不一致**：`PROTO_VERSION` 升到 2 后，老端发来的包必须**解码返回空 + 只报一次 + 不喂进模拟**；守卫写松 ⇒ 错位值被当成合法输入（静默分歧，现场只表现为"抽"）。→ Task 1 断言③。
3. **扩展字段的语义**（`st` 必须是**最近成功解码**的 tick，不是"最后收到"的；`ct` 是物理帧号）：埋错语义比不埋更糟 —— 未来增量批会拿它当基线，错 = 静默错位。→ Task 1 断言②（非零往返）+ Step 6 的服务器读数人工核对。
4. **一次性分配少算/没裁**：`trail` 是唯一的变长字段（`TRAIL_WIRE_MAX = 4`），容量按最坏预算但**末尾必须 `resize(n)` 裁掉未用尾巴**。少分配 ⇒ 写越界；不裁 ⇒ 解码端 `int(r["o"]) != data.size()` 判坏包（整帧丢，且只报一次错误）。→ Task 2 用 `snapshot_size_probe` ③④（最坏包 N=16 × trail 4 点）。
5. **位流读写对称**：bool 改成 1 bit 后，任何一侧的位宽/顺序写错 ⇒ 逐字段错位；尾字节 padding 的校验若写成"忽略剩余位"，错位还可能是绿的。→ Task 3 的判据是 `snapshot_size_probe` ③（"丑数"夹具逐字段往返）+ ④（最坏包尺寸/往返）。
6. **另一处发送点漏改**：`tests/smoke/pvp_match_smoke.gd` 是产品外**唯一**另一处 `send_input` 调用点；漏改时发送端不报错，只有服务器解码处报"坏包"⇒ **只有真链路能发现**。→ Task 1 Step 7 的 `SMOKE PASS`。
7. **schema 与 producer 脱钩**：`pack_record` 加字段不登记 ⇒ 该字段在线上被静默丢掉（本仓最贵的病）。→ Task 1 断言①（双向键集对齐）。

---

### Task 1: 上行输入包手打包（`SnapshotCodec` → `NetCodec`，`PROTO_VERSION` 2）

**Files:**
- Rename: `core/net/snapshot_codec.gd` → `core/net/net_codec.gd`（`core/net/snapshot_codec.gd.uid` → `core/net/net_codec.gd.uid`）；`class_name SnapshotCodec` → `NetCodec`
- Modify: `core/net/net_codec.gd`（加 `T_U16` / `KIND_INPUT` / `INPUT_SCHEMA` / `encode_input` / `decode_input`；`PROTO_VERSION` 1→2）
- Modify: `core/net/packet_input_source.gd`（`pack_record` 加 `snap_tick` / `client_tick` 两个**带默认值**的参数，仍是发送侧唯一来源）
- Modify: `core/net/net_bus.gd`（`send_input` 载荷 → `PackedByteArray`；解码 + 只报一次；两处 decode 调用改名）
- Modify: `scenes/pvp_match_client.gd`（发送点编码；**`_last_snap_tick` 上提到基类**；组包时填 `st`/`ct`）
- Modify: `scenes/pvp_game.gd`、`scenes/royale_game.gd`、`scenes/team_game.gd`（删掉各自声明的 `_last_snap_tick`，改用基类那份；`_on_snapshot_world` 的赋值处不动）
- Modify: `server/match/match_state.gd`（`_ack_seq` 旁边加 `_client_snap_tick` / `_client_tick` 两张 role→int 表）
- Modify: `server/match/match_host.gd`（`_on_input` 里记下 `st`/`ct`）
- Modify: `server/match/input_intake.gd`（`--netstat-srv` 的 1Hz 行追加 `st`/`ct` 读数）
- Modify: `tests/smoke/pvp_match_smoke.gd`（同款发送点，唯一另一处；手工组包处补 `st`/`ct` 键）
- Modify: `tests/smoke/server_input_sanitize_smoke.gd`（+3 条断言，`21 → 24`；OK 文本同步）
- Modify: `tests/probe/snapshot_size_probe.gd`（类名引用，多处）
- Modify: `docs/eng/netcode-snapshots.md`、`docs/eng/time.md`（`SnapshotCodec` → `NetCodec`、路径改名）
- Modify: `docs/eng/netcode-input-uplink.md`（§1.2/§1.3/§2/§5.1：30Hz 单记录 + 手打包 34 B 的现状与读数）
- 不新建文件

**Interfaces:**
- Consumes: `PacketInputSource.pack_record(src, seq, aim, snap_tick, client_tick) -> Dictionary`（发送侧唯一来源，不许绕过；后两个参数带默认值 `0`，老调用点不动）
  - 语义：`snap_tick` = 本端**最近成功解码**的服务器世界快照 `tick`（客户端 `_last_snap_tick`）；`client_tick` = 本帧客户端物理帧号（`Engine.get_physics_frames()`）
- Produces:
  - `NetCodec.PROTO_VERSION := 2` · `NetCodec.KIND_WORLD := 1` / `KIND_OWN := 2` / `KIND_INPUT := 3`
  - `NetCodec.T_U16 := "u16"`（新类型；`_pack` 写 2 B 小端、`_unpack` 读）
  - `NetCodec.INPUT_SCHEMA: Array = [["seq","i"],["ax","f"],["held","u16"],["pressed","b"],["released","b"],["winst","i"],["aim","v2"],["st","i"],["ct","i"]]`
  - `static func encode_input(pkt: Dictionary) -> PackedByteArray`（头 `[PROTO_VERSION][KIND_INPUT]` + `INPUT_SCHEMA` 记录 = **34 B**）
  - `static func decode_input(data: PackedByteArray) -> Dictionary`（头不符 / 越界 / 尾部多余字节 ⇒ `{}`）
  - `NetBus.send_input(payload: PackedByteArray) -> void`（`@rpc` 声明其余三参不动）
  - `NetBus.input_received(caller: int, pkt: Dictionary)` —— **签名不变** ⇒ `MatchHost._on_input(caller, pkt)` 的消费逻辑不改
  - 服务器读数：`MatchState._client_snap_tick[role]` / `_client_tick[role]`（本批只落位 + `--netstat` 显示）

- [ ] **Step 0: 确认开工前置**

Run: `git status --short`（应为空）· `git log --oneline -3`
Expected: 30Hz 采样重构那批与文档清理那批都已在提交里；工作区干净。不干净 ⇒ 停手，先问仓主（共用工作树，别把别人的 hunk 带走）。

- [ ] **Step 1: 纯改名（要求"零字节变化"）**

`git mv core/net/snapshot_codec.gd core/net/net_codec.gd` + 同目录 `.gd.uid` 一起 `git mv`；改 `class_name NetCodec` 与全部引用（`core/net/net_bus.gd` 2 处 decode、`server/match/match_snapshot.gd` 2 处 encode、`tests/probe/snapshot_size_probe.gd` 多处、文档路径）。刷新全局类缓存并确认：

Run:
```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --import
grep -c NetCodec .godot/global_script_class_cache.cfg    # 期望 ≥1；为 0 则 headless 会报 Identifier not declared
python tools/check_naming.py                             # 期望"命名检查 OK"（规则 B/C 都会碰这次改名）
```
Expected: 命名检查 OK；`bash tests/run_all.sh` ⇒ `RUN_ALL OK(...)`，且 `snapshot_size_probe` 打印仍是 `世界包条目 … 51 B`、`本人包 … 102 B`（**改名不许动任何字节**）。

- [ ] **Step 2: 写失败判据（3 条，21 → 24）**

在 `tests/smoke/server_input_sanitize_smoke.gd` 末尾（判词计数闸之前）加一组断言，红线写在注释里：

```gdscript
# ① schema 与生产者逐键对齐（去掉什么才红 = 给 pack_record 加字段不登记 / INPUT_SCHEMA 写错键）
var src := PacketInputSource.new()   # PlayerInput extends RefCounted ⇒ -s 里可 new
var pkt := PacketInputSource.pack_record(src, 7, Vector2(0.6, -0.8), 1234, 5678)
# 断言：pkt 键集 == NetCodec.INPUT_SCHEMA 键集（双向，差异打出来）
# ② 真实产出往返 + 位宽（去掉什么才红 = held 用 u8 ⇒ 截断；st/ct 漏进 schema ⇒ 4 B 字段丢；encode/decode 写错位）
var full := PacketInputSource.pack_record(src, 123456, Vector2(0.6, -0.8), 987654321, 12345678)
full["held"] = PacketInputSource.BIT_HASTE | PacketInputSource.BIT_REWIND \
        | PacketInputSource.BIT_ATTACK | PacketInputSource.BIT_UP      # 415
# 断言：decode_input(encode_input(full)) 逐键一致（float 用 is_equal_approx）；held == 415；st == 987654321；ct == 12345678
# ③ 坏包必须返回空（去掉什么才红 = 删版本/长度守卫 ⇒ 错位值喂进服务器模拟）
# 断言：翻首字节 ⇒ {}；截断 5 B ⇒ {}；拿 encode_world(...) 的产出喂 decode_input ⇒ {}
```

Expected: `SERVER INPUT SANITIZE FAILED` + `实跑 21 条断言,与 EXPECTED=24 对不上`（实现还没写）。

- [ ] **Step 3: 实现 `encode_input` / `decode_input`（复用既有 `_pack` / `_unpack`，不许另写一套读写）**

在 `net_codec.gd`：加 `T_U16` 类型（2 字节小端）、`KIND_INPUT`、`INPUT_SCHEMA`；`PROTO_VERSION := 2`。
`encode_input` = `[PROTO_VERSION][KIND_INPUT]` + `_pack(out, INPUT_SCHEMA, pkt)`；`decode_input` 走与 `decode_own` 同款守卫：头不符 / 越界 / 尾部多余字节 ⇒ 返回 `{}`。

- [ ] **Step 4: 接线（发送 + 接收 + 两处落位）**

- `pvp_match_client.gd`：`var pkt := PacketInputSource.pack_record(src, _input_seq, aim, _last_snap_tick, Engine.get_physics_frames())`；然后 `NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pkt))`
- **`_last_snap_tick` 上提到 `PvpMatchClient` 基类**：三个子类（`pvp_game` / `royale_game` / `team_game`）删掉自己声明的 `var _last_snap_tick := 0`（**子类重复声明基类成员是硬 Parse Error**），它们的 `_on_snapshot_world` 继续写继承来的那份
- `net_bus.gd`：`@rpc` 签名 `func send_input(payload: PackedByteArray)`；内部 `var pkt := NetCodec.decode_input(payload)`；`pkt.is_empty()` ⇒ `_input_decode_warned(payload)`（照抄 `_snapshot_decode_warned` 的**只报一次**写法，`_input_warned` 单独一个 bool）并 `return`；否则 `input_received.emit(multiplayer.get_remote_sender_id(), pkt)`
- `match_host.gd` 的 `_on_input`：在 `_intake.intake(...)` 之前写 `_client_snap_tick[role] = int(pkt.get("st", 0))` / `_client_tick[role] = int(pkt.get("ct", 0))`（两张表住 `match_state.gd`）；**消费逻辑本身一字不改**
- `input_intake.gd`：`--netstat-srv` 的 1Hz 行追加 `st`/`ct` 两列（只读数，本批无消费者）
- `tests/smoke/pvp_match_smoke.gd` 的发送点：手工组包补 `"st": 0, "ct": 0` 两键，再 `NetCodec.encode_input(pkt)`
- ★ RPC 通道号/传输模式不动 ⇒ `rpc_channel_contract_smoke` 应保持 `RPC CHANNEL CONTRACT OK`

- [ ] **Step 5: 跑绿（纯逻辑面）**

Run:
```bash
"$GODOT" --headless --path . -s res://tests/smoke/server_input_sanitize_smoke.gd
bash tests/run_all.sh
```
Expected: `SERVER INPUT SANITIZE OK(24 …)` / `RUN_ALL OK(...)`（支数不变 = 没新增文件；账以 `--list` 实测为准，**别手抄数字**）。

- [ ] **Step 6: 读数（写进文档，不做断言 —— D3）**

在 Step 5 的冒烟里加一行**读数字符串**（不是断言）：`编码后 %d B/包`（期望 34）。把它与 30Hz 折算（1.02 KB/s/客户端、N=8 约 8.2 KB/s）写进 `netcode-input-uplink.md`（注明**载荷口径**）；真链路跑批时用 `--netstat` 人工核对 `st`/`ct` 在涨。

- [ ] **Step 7: 真链路（档 3 必做；先问用户）**

Run（先查 `lobby_alive`，用户认领后由 agent 跑）：
```bash
bash tests/smoke/pvp_match_smoke.sh
```
Expected: `SMOKE PASS`。★ 这一支是**唯一**能证明 `PackedByteArray` 走 RPC、两端解码接线都对的判据（默认批只证明纯函数）；`st`/`ct` 的送达只由断言②（往返）覆盖 —— 真链路只证明不回归（本批字段无消费者，登记在案）。

- [ ] **Step 8: 变异验证（2 条承重）**

改 → 跑 → 确认红 → 用内存原字节还原（写法见 `.superpowers/net/mutate.py`）：
- M1：`decode_input` 删版本守卫 ⇒ 断言③红。
- M2：`INPUT_SCHEMA` 的 `held` 改回 `"b"`（u8）⇒ 断言②红（截断到 159）。
★ **不做**第三条（删 `T_U16` 的字节序 → 断言②也会红，但与 M2 同族，边际价值低）。

- [ ] **Step 9: 提交（逐个文件 `git add`）**

```bash
git add core/net/net_codec.gd core/net/net_codec.gd.uid core/net/net_bus.gd \
  core/net/packet_input_source.gd scenes/pvp_match_client.gd \
  scenes/pvp_game.gd scenes/royale_game.gd scenes/team_game.gd \
  server/match/match_state.gd server/match/match_host.gd server/match/input_intake.gd \
  tests/smoke/server_input_sanitize_smoke.gd tests/smoke/pvp_match_smoke.gd \
  tests/probe/snapshot_size_probe.gd \
  docs/eng/netcode-snapshots.md docs/eng/time.md docs/eng/netcode-input-uplink.md
git commit -m "feat(net): 输入上行手打包 164B→34B + SnapshotCodec→NetCodec + 埋 st/ct —— held 必须 u16"
```

---

### Task 2: 快照编码器重写（一次性分配 + 下标写，零字节变化）

**Files:**
- Modify: `core/net/net_codec.gd`（`encode_world` / `encode_own` / `encode_input` + 写原语 `_put_*`）
- Modify: `.superpowers/net/zstd_vs_codec.gd`（一次性量具的类名引用；**不入库**，只本地能跑）
- Modify: `docs/eng/netcode-snapshots.md`（在"载荷口径"那几节后面补一条**编码器 CPU 读数**：改前 294 µs / 改后实测值；原 spec 已删，读数只能落在这里）

**Interfaces:**
- 对外**全部不变**：`encode_world` / `encode_own` / `encode_input` 的签名与**产出字节逐位不变**（本任务零协议变化 ⇒ **不动 `PROTO_VERSION`**）
- 内部新增（示例签名，实现可等价）：
  - `static func _alloc_world(n_players: int) -> int` —— 返回容量字节数 = `7 + n × (1 + 67)`（67 = 世界 schema 定长 34 + trail 最坏 `1 + 8×TRAIL_WIRE_MAX` 33）
  - `static func _put_f_at(out: PackedByteArray, i: int, v: float) -> void`（`out.encode_float(i, v)` 就地写，**不 resize**）
  - `static func _put_u32_at(out: PackedByteArray, i: int, v: int) -> void`（`out.encode_u32(i, v)`）
  - 写指针 `n` 由 `_pack_at(out, n, schema, d) -> int` 在调用链上传递；末尾 `out.resize(n)`

- [ ] **Step 1: 先取 CPU 基线读数（一次性量具，不是判据）**

Run: 用编辑器二进制跑 `.superpowers/net/zstd_vs_codec.gd`（若它已不认新类名，先按 Task 1 的改名同步这个文件）
Expected: `encode_world` N=16 ≈ **294 µs**（与内联读数同量级；若差很多，先查是不是走了 debug/编辑器构建）。

- [ ] **Step 2: 实现预分配 + 下标写**

要点：① 容量按 schema 预算（`_alloc_world` / `_alloc_own` / 定长 34 for input）**一次 `resize`**；② 写原语全部换 `encode_float(i,…)` / `encode_u32(i,…)` / 直接 `out[i] = …`，**不再 `append`/`append_array`**；③ 末尾 `out.resize(n)` 收尾（否则解码端 `data.size()` 校验会红/整帧丢）。

- [ ] **Step 3: 跑绿（承重判据：字节逐位不变 + 往返保真）**

Run:
```bash
bash tests/run_all.sh
```
Expected: `RUN_ALL OK(...)`；`snapshot_size_probe` 打印**仍是** `世界包条目 … 51 B` / `本人包 … 102 B`，且 `SNAPSHOT SIZE PROBE: ALL-OK`（③ 往返逐字段一致 = 写错位的直接判据；④ 最坏包 N=16 × trail 4 点仍 ≤ 1400 B）。

- [ ] **Step 4: 取改后读数并落纸**

Run: 同 Step 1 的量具（同 N=16）
Expected: `encode_world` **≤ 50 µs**。把改前/改后两个数写进 `docs/eng/netcode-snapshots.md`（**读数是记录，不是断言**）。

- [ ] **Step 5: 真链路抽查（档 3；先问用户）**

Run: `bash tests/smoke/pvp_match_smoke.sh`
Expected: `SMOKE PASS`（编码器重写是本批唯一会动**所有**快照字节产生路径的改动，默认批的探针够不着真实 RPC 路径）。

- [ ] **Step 6: 变异验证（1 条）**

M3：把 `_alloc_world` 的容量少算 8 B ⇒ `snapshot_size_probe` ③ 或 ④ 红（写越界/截断；若没红说明容量断言没咬住，回头查）。

- [ ] **Step 7: 提交**

```bash
git add core/net/net_codec.gd docs/eng/netcode-snapshots.md
git commit -m "perf(net): 快照编码器一次分配+下标写(N=16 294µs→XXµs) —— 字节逐位不变"
```

---

### Task 3: bool 位打包（`PROTO_VERSION` 3）

★ 依赖 Task 2 的预分配写入器（位流写建立在它上面）。**仓主已拍板做**。

**Files:**
- Modify: `core/net/net_codec.gd`（写/读改成**位流**：`_put_bits` / `_rd_bits` + 复用的 4 B 浮点暂存；`T_BOOL` → 1 bit；`PROTO_VERSION` 2→3；尾字节 padding 校验）
- Modify: `tests/probe/snapshot_size_probe.gd`（`_t_bytes` 改成按**位**计（`_t_bits`），`_schema_bytes` 折成 `ceil(bits/8)`；`EXPECTED_CHECKS` 仍为 4 —— **不加体积断言**（D3））
- Modify: `docs/eng/netcode-snapshots.md`（§1.2/§2.1/§5.1b 的尺寸更新为实测值 + 口径注）

**Interfaces:**
- 对外签名不变：`encode_world` / `encode_own` / `encode_input` / `decode_*`
- `PROTO_VERSION := 3`；`T_BOOL` 语义不变（bool），线宽 **1 bit**
- 预期尺寸（算术后由 probe 实测替换）：世界条目 **51 → 48 B**；本人包 **102 → 94 B**；N=8 服务器出向 ≈ 121 → 113 KB/s；上行输入包 **34 B 不变**（输入 schema 无 bool 字段）

- [ ] **Step 1: 实现位流写读**

要点：① 预分配容量沿用 Task 2 的上界（字节容量 ≥ 位需求，末尾按 `ceil(bit/8)` 裁）；② 浮点/向量按 32/64 bit 写入（`PackedByteArray.encode_float` 写进 4 B 暂存 → `decode_u32` → `_put_bits`，暂存数组每次 encode 只建一次）；③ 解码端游标改成 bit 游标，校验 `ceil(bit/8) == data.size()`（写死在注释里）；④ padding 位必须为零（写入时 `resize` 天然补 0）。

- [ ] **Step 2: 跑绿（判据是往返 + 最坏包，不是尺寸）**

Run: `bash tests/run_all.sh`
Expected: `RUN_ALL OK(...)`；`SNAPSHOT SIZE PROBE: ALL-OK`（③ 往返逐字段一致：`T_BOOL` 位宽写错 ⇒ 立刻红；④ 最坏包仍 1 片）。同时记录 probe 打印的新尺寸（读数，写进文档）。

- [ ] **Step 3: 真链路（档 3；先问用户）**

Run: `bash tests/smoke/pvp_match_smoke.sh` + `bash tests/probe/royale_soak_probe.sh`（后者覆盖 N 路编解码；先查 `lobby_alive`）
Expected: `SMOKE PASS` / `SOAK: ALL-OK`。

- [ ] **Step 4: 变异验证（1 条）**

M4：把 `_unpack` 里任意一个 `T_BOOL` 的位宽写成 8 ⇒ probe ③ 红（逐字段错位）。

- [ ] **Step 5: 提交**

```bash
git add core/net/net_codec.gd tests/probe/snapshot_size_probe.gd docs/eng/netcode-snapshots.md
git commit -m "feat(net): 快照 bool 改 1 bit(世界 51→48B/本人 102→94B) —— 无损,版本号 3"
```

---

## 3. 验收清单（全批完成后逐条打勾）

- [ ] 默认批：`bash tests/run_all.sh` ⇒ `RUN_ALL OK(...)`（账以 `--list` 实测为准）；无新增/删除 `.gd` 文件。
- [ ] 真链路：`bash tests/run_real.sh --yes`（**先问用户**；R20 锁 + 前后进程为 0）⇒ `RUN_REAL OK(...)`；或按用户认领单跑 `pvp_match_smoke.sh`（+ Task 3 的 `royale_soak_probe.sh`）。
- [ ] `python tools/check_naming.py` ⇒ OK（改名后 `docs/eng` 的路径引用全部存在）。
- [ ] 读数落纸（**载荷口径**，注明不含信封/ENet/IP 头）：
  - 上行输入包 164 → **34 B**/包（30Hz ⇒ 4.9 → 1.02 KB/s/客户端；含 `st`/`ct` 各 4 B）；
  - 服务器 `--netstat-srv` 行能看到 `st`/`ct` 在涨（本批只落位、无消费者；真链路只证明不回归）；
  - 世界条目 51 → 48 B、本人包 102 → 94 B；
  - `encode_world` N=16 294 → **≤50 µs**。
- [ ] 文档订正：`netcode-input-uplink.md`（30Hz 单记录 + 34 B + `st`/`ct` 语义）、`netcode-snapshots.md`（类名 + 新尺寸 + CPU 读数）、`time.md`（路径）；**`netplay-rpc-channels.md` 不改**（通道/传输模式未动）。
- [ ] 已删的历史计划/spec 不需要标注（2026-10-24 文档清理已删；本计划即现行，无重复真相源）。

## Self-Review

- **Spec 覆盖**：上行 164 B（`netcode-input-uplink.md` §2）→ Task 1；`held` 位掩码 u16 的订正 → Task 1 断言②/变异 M2；`st`/`ct` 两字段（原 spec 决策 #6）→ Task 1 接口/接线/断言②；编码器 294 µs → Task 2；bool 位打包 → Task 3；量化/增量/合流/冗余**显式不做**（§1 逐条说明）。
- **类型一致**：`pack_record(src, seq, aim, snap_tick, client_tick)`、`encode_input` / `decode_input` / `INPUT_SCHEMA`、`T_U16`、`input_received(caller, pkt: Dictionary)`、`_client_snap_tick` / `_client_tick` 在 Task 1 的 Interfaces/Files/Steps 与 Review Focus 中逐字一致；`_pack`/`_unpack` 的签名在 Task 1/2/3 中一路沿用，没有另写第二套读写。
- **Review Focus 各有归属**：#1 → Task 1 断言② + M2；#2 → Task 1 断言③ + M1；#3 → Task 1 断言② + Step 6 读数；#4 → Task 2 Step 3 ④；#5 → Task 3 Step 2 ③ + M4；#6 → Task 1 Step 7 真链路；#7 → Task 1 断言①。
- **已拍板**：全做 T1+T2+T3；上行埋 `st`/`ct`；执行方式 Native（§2）。
- **诚实边界**：本批所有收益都是**载荷字节**口径；线上字节（含 RPC 信封/ENet/IP 头）本仓仍无仪器（原债单 §8.11，编号随 debt/ 清理失效），效果需真链路 `--diag` 的 `snapshot_tx` 读数作旁证；`royale_soak` 的 KB/s 是解码后 Dictionary 口径，**对线格式改动完全看不见**（别拿它当证据）；`st`/`ct` 本批无消费者，送达证据只有 `-s` 往返，真链路只证明不回归。
