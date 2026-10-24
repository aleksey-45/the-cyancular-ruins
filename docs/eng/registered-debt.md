# 已知边界与已知红

> 一行一项:**现象 + 规避 / 影响面**。销掉即删行。跑法与判据见 [`tests.md`](tests.md),取舍见 [`test-economy.md`](test-economy.md)。

## 已知红

- `tests/probe/team_match_probe.sh` —— 整跑判 `FAIL`,不可当 3v3 的端到端守卫;影响面 = 3v3 只能靠该支日志 + 人工试玩。
- `tests/probe/rejoin_probe.sh` —— 2026-10-24 实测整跑 `FAIL`:房停在 `players=2 port=0`(客户端没写出结果文件)。失败点在**配对前**,而 `rejoin_watcher` 没有「房主点开始」动作(9378f5b0 起 1v1 需房主开始)⇒ 不可当重连端到端守卫;与本批 U1 无关。影响面 = 局内自动重连/回大厅回局只能靠该支日志 + 人工试玩,或者先修 watcher。
- `tests/known_red.txt` 基线当前 **0 条** —— 任何红都算新红,`run_all.sh` 退出码非 0。

## 已知边界

- [`tests/harness/menu_autotest.gd`](../../tests/harness/menu_autotest.gd) 被产品代码 [`scenes/main_menu.gd`](../../scenes/main_menu.gd) `load()`(菜单的 `-- --autotest-*` 钩子)—— 改名 / 删除 / 移动它,必须同批改产品代码,否则钩子失效。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 手抄 `UiFactory.menu_panel()` 的 64/46,镜像守卫用同一对字面量 —— 改 `menu_panel()` 默认值**不会红**,生成物与守卫一起静默用旧值;改默认值必须两处同改。
- 默认批多数支没有 `EXPECTED_CHECKS` 条数闸(`run_all.sh` 表里 `GATE` 栏为 `-`)—— 单支 `OK` 只证明"没有失败输出",不证明每条断言都跑过。
- [`tests/run_all.sh`](../../tests/run_all.sh) 的承重安全检查只读整行注释以外的文本,看不见经 helper 间接开端口 / 拉子进程的形状 —— 新增这类支必须手工进 `EXCLUDED`。
- [`tests/run_real.sh`](../../tests/run_real.sh) 的 R20 锁心跳只在**支间**刷新(`LOCK_STALE_SECS` = 600s)—— 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- [`tests/probe/path_integrity_probe.gd`](../../tests/probe/path_integrity_probe.gd) 在 Windows 上不区分大小写 —— 路径大小写写错会通过(导出成 `.pck` 后区分大小写);它只答"有没有",不答"大小写对不对"。
- [`tests/probe/snapshot_size_probe.gd`](../../tests/probe/snapshot_size_probe.gd) 的世界包分片悬崖在 N≈29（`7+29×48=1399 B < 1400 B MTU`）—— 超 MTU 即 unreliable 分片，丢一片 = 整帧丢。

## 九、2026-10-24 默认批激进削减（20 → 6）—— **删了什么 = 欠了什么**

> 仓主裁决：默认批只留 4 支承重/元闸，其余全删；重建 2 支编码面守卫。真链路批**未动**。
> 此节是**覆盖缺口清单**（不是"已修好"）；翻案条件 = 下列任一面再次改坏且没有其它守卫能抓到。

**保留**：`allscript_probe`（全仓 `.gd` 加载 + `EXPECTED_SCRIPTS` 174）· `path_integrity_probe`（`res://` 字面量存在性）· `snapshot_size_probe`（线格式体积/最坏包/容量）· `rollback_fidelity_probe`（C2 回放保真）。
**新建**：`net_wire_smoke`（三 kind 版本/种类头 · 坏包一律空 · 三 kind 往返 · `INPUT_SCHEMA`↔`pack_pair` 对齐）· `input_queue_smoke`（轴收口 · 有界+边沿 · 回复力 · 上限钳位）。两支都带 `EXPECTED_CHECKS`。

**删除的 16 支 → 各自留下的缺口**（逐条都曾挡过真实缺陷）：

| 删掉 | 原来挡什么 | 现在的覆盖 |
|---|---|---|
| `mode_defs` / `mode_options` / `mode_room_rules` | 模式常量/选项键/房间规则表的单一来源（3v3 曾上发 1v1 的禁用武器；16 人上限只改了一半） | **零守卫**，只能靠联机场景行为/试玩 |
| `mode_context` | worker argv 解析边界（`--` 之后、`--roles` 等长、role 0/17） | **零守卫** |
| `room_registry` | 同号跨模式不串、三表合一、`started`↔`in_match` 双向别名 | **零守卫** |
| `rpc_channel_contract` | 通道表 ↔ `@rpc` 声明文本对账（含 `beam_fired` 重名集合） | **零守卫**，见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md) 已改口 |
| `server_input_sanitize` | 轴钳位 / 队列有界 / 丢包保边沿 / 抖动上限 | **已由 `input_queue_smoke` 接管**（24 条按 4 类压缩，覆盖面按类别等价；逐值细目不再断言） |
| `network_input` | `get_axis("up","down")` 由 held 推导（梯子回拉根因） | **零守卫** |
| `net_diag` / `ops_log` | `--diag` 开关零成本与落盘、审计文件命名/保留策略 | **零守卫** |
| `server_status` | 服务端面板数据层（端口三态/房间快照纯判据） | **零守卫** |
| `resync_world` | 重连补态「先还原基线、再应用 destroyed」 | **零守卫**，见 [`netplay-reconnect.md`](netplay-reconnect.md) 已改口 |
| `tile_collision` | 可破坏砖碰撞逐 16px 子格与游戏规则一致 | **零守卫** |
| `map_catalog` / `map_format_v4` | 地图目录/选图路径校验；cyrm v4 编解码/CRC 往返 | **零守卫**（存档/地图格式面） |
| `wrap_probe` | 鸟跟随玩家跨接缝回绕 | **零守卫**（原支本就零断言 = D2，删掉不减少保证） |

**未动**：真链路 6 支（`pvp_match` / `pvp_room` / `rejoin` / `soak` / `role_cap` / `team_match`），其中 `team_match` 仍登记为不可信（见本文件「已知红」）。

## 十、2026-10-24 U1：上行逐 tick 双记录（去 30Hz 锁存）—— 改动边界与缺口

> 目标（仓主裁决）：取消本地输入锁存（①），并让服务器逐 tick 消费（②），不翻倍频率。做法 = 一条记录 = 1 tick（60Hz 采样），30Hz 包内装两条（流水线：本包 = 上一 tick + 本 tick）。

**改了什么**：`PROTO_VERSION` 3→4；输入包 34→**46 B**（+35% 上行，1.02→**1.38 KB/s/客户端**）；`PacketInputSource.TICKS_PER_RECORD=1`、新增 `INPUT_BATCH_TICKS=2`；队列上限按记录翻倍 `[4,16]`（保住 [66,266] ms 时间缓冲）；删 `SampledInput`（切枪"按一次永久生效"的陈旧锁存缺陷随之消失，非补丁）；C2 环/重放改为 **1 步/记录**；服务端从"每 2 tick 消费一条"改为"**每 tick 消费一条**"；ack 逐 tick 前进（但仍只在 30Hz 本人包回带）。

**仍未动的延迟**：本人包/世界包仍 30Hz 发（S1 只把本人包挪到"消费并步进完当帧"，没有提高频率）；ack 仍只在 30Hz 本人包回带 ⇒ "输入→服务器确认"只剩离散化（本地理论 ≈0~50ms，均值 ~25ms），`--netstat` 的 `gap` 仍有 1~2 条 ×16.7ms 的偏置。再往下要 own 60Hz（+2.8 KB/s/客户端）或世界包也挪到步进后。

**S1（本人包帧末发）的验证边界（照实）**：没有一条断言能"证明更早"——只能靠 ① `pvp_match_smoke` 的 ack 前进 + c2 一致性（容差已按"世界包旧 1 tick"放宽）② `royale_soak` 真客户端不炸 ③ 手动 `--netstat`/`--diag` 读数对比。如果有人把 `send_own_snapshots()` 挪回 `_broadcast_snapshot()`，上面两条**都不会红**（只是回到旧延迟）⇒ 这条不变量只能靠代码注释与评审守。

**本批新增的覆盖缺口**（默认批只剩 6 支）：客户端侧边沿行为（数字键 1-4 只切一次 / F 只拾取一次 / Q 长按只丢一次）**零自动化守卫**；C2 逐 tick 重放只有 `rollback_fidelity_probe`（纯逻辑）与真链路 soak（真 `royale_game` 客户端跑 `SOAK: ALL-OK`，但不断言"按一次只切一次"）。翻案条件 = 再做输入/回滚改动时，先补 `sampled`/边沿类 `-s` 守卫或在真链路里加断言，否则这些行为只能人工试玩。

**本批真链路证据**：`pvp_match_smoke.sh` = `SMOKE PASS`；`royale_soak_probe.sh` = `SOAK: ALL-OK`（4 客户端真 royale_game，观测 58s，含受击/倒地/击杀/离场）。`rejoin_probe.sh` 失败见上「已知红」。

## 十一、2026-10-24 副本插值撤回又恢复 + 渲染层带 —— 边界与代价

> 现象（玩家报）：联机里「其他玩家的幽灵体图层不对（被梯子 / 建筑压着的应该是它，结果它压着地形）」，且「动作没有插值，看起来很怪」。
> 根因两条都是 `9378f5b0` 那批改动留下的：① 副本位置改成直出最新快照（理由是「本机实测与插值无差别」，真联机下不成立）；② 副本是运行时 `add_child` 到世界末尾的，而本体在 `level_0.tscn` 里排在 `WallLayer` 之前。

**改了什么**：恢复 `core/net/playout_clock.gd` + 位置历史 / 夹逼插值 / `SNAP_DIST` 一帧落位（`PLAYOUT_TICKS = 4`，30Hz 下行 = 2 个发包间隔 ≈ 67ms）；副本在 `_ready` 里把自己挪到 `Level0.wall_layer` 之前（与本体同一条渲染层带）；`allscript_probe` 的 `EXPECTED_SCRIPTS` 174→175。

**新增代价（如实登记）**：画面比权威晚 ≈67ms（深度补偿时最多 ≈133ms）；幽灵碰撞体**不跟**这段延迟（它直出最新权威位置）⇒「看得见的对手」与「挡你的对手」之间存在该量级的位置差。这是「观感平滑」换「预测一致」，不要为了消这个差把幽灵体也接上插值。

**零自动化守卫**：平滑度与图层遮挡都是观感项，仓主裁定不跑 / 不加自动守卫（见 [`tests.md`](tests.md) 的「不写清单」）。本轮验证 = 导出产物冒烟（`build_release.py`：客户端直接起 + `--registry-report` + 服务端 `--worker --port 7999`，三条都 `OK`）+ 一次临时 headless 探针（已删：30Hz 夹具下零位移帧 3/60、单帧位移恒 5.00px、幽灵体偏差 10px = 最新快照领先量、副本 index 1 < WallLayer index 2）+ 人眼。翻案条件 = 同类现象被玩家再报一次，或有人把 `_process` 改回直出 / 删掉 `_reorder_before_structures`。

**前提**：`level_0.tscn` 里 `Player` 必须排在 `WallLayer` 之前（本体的层带就是这么来的）；换这个顺序要同批复查 `player_replica._reorder_before_structures`。

**2026-10-24 追补（同一现象的第二轮）**：① 外观态（`pose` / `facing` / `aim` / `aim_facing` / `downed` / `type_id` / `vel`）改成与位置**同一渲染时刻**取样 —— 之前它们逐包瞬跳，动画/枪口比身体早一拍多，观感是「对手停下了腿还在走」（滑步）；幽灵碰撞体仍吃最新快照。② 客户端收到 `go_match` 后在帧末**再等一帧**才 `NetBus.stop()`，让大厅最后两条定向包先落地（治 `max channels: 0` 里客户端能治的那一半）。本轮按仓主明确要求**没有跑任何验证**（含探针与真链路），只做了导出产物冒烟；滑步/延迟是否可接受由人眼定。若仍嫌「飘」，调 `PLAYOUT_TICKS`（4 → 2/3 即 ≈33/50ms，`player_replica.gd` 顶部一行）。
