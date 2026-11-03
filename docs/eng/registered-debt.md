# 已知边界与已知红

> 一行一项:**现象 + 规避 / 影响面**。销掉即删行。跑法与判据见 [`tests.md`](tests.md),取舍见 [`test-economy.md`](test-economy.md)。
> ★ **2026-11-02:本文件从 1,204 行砍到 ~60 行** —— §九~§五十六 的**逐批过程叙述**（"做了什么 / 逐字判词 / 差了几字节"）
> 已全部删除。它们记的都是**已经落地的改动**,存档在 git log 与各批提交里,不进"动手前必看"。
> 保留的只有**当前仍然成立**的三类:已知红 · 已知边界 · 零守卫面的清单。

## 已知红

- `tests/probe/team_match_probe.sh` —— **不可当 3v3 的端到端守卫**：2026-10-31 同配置两跑，第一跑 `FAIL`（c4 相⑤ 观察窗内快照间隔 10009ms > 1s，其余 5 端 19~34ms；c4 进程仍在跑心跳、分数也不变 ⇒ "该 peer 10s 没收到世界包"，探针自己写明"客户端停顿 / 定向投递异常无法区分"），第二跑 **`TEAM MATCH PROBE: ALL-OK`** ⇒ 判为**时序性 flake**，不是崩溃/协议回归；影响面 = 3v3 只能靠该支日志 + 人工试玩。翻案条件 = 同配置再现 10s 级单端快照断流时按真缺陷查（先看 `all_peers_sendable` 与 `is_peer_live` 对该 peer 的读数）。
- `tests/probe/rejoin_probe.sh` —— 2026-10-24 起的已知红**已修**（watcher 代发 `pvp_start`）；2026-10-31 复跑 `REJOIN PROBE: ALL-OK(5)`。
- `tests/known_red.txt` 基线当前 **0 条** —— 任何红都算新红,`run_all.sh` 退出码非 0。

## 已知边界

- **水面合批不消费辅码**（[`scenes/level_0.gd`](../../scenes/level_0.gd) `_create_water_tileset` 的 `surface_texture` + [`scenes/effects/water_surface_batch.gd`](../../scenes/effects/water_surface_batch.gd)）：水面亮带恒采样**中性**水面砖（`WATER_SURFACE_BRICK`），只有水体层按描述符行 tint —— 地图给水体上了 hue/bri 辅码时，深水格有色、水面亮带仍原色（症状 = 水面处颜色断层）。规避 = 别给水格上辅码；修 = 水面砖也按格级水体描述符 tint（合批要按行分桶）。
- [`tests/harness/menu_autotest.gd`](../../tests/harness/menu_autotest.gd) 被产品代码 [`scenes/main_menu.gd`](../../scenes/main_menu.gd) `load()`(菜单的 `-- --autotest-*` 钩子)—— 改名 / 删除 / 移动它,必须同批改产品代码,否则钩子失效。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 手抄 `UiFactory.menu_panel()` 的 64/46,镜像守卫用同一对字面量 —— 改 `menu_panel()` 默认值**不会红**,生成物与守卫一起静默用旧值;改默认值必须两处同改。
- 默认批多数支没有 `EXPECTED_CHECKS` 条数闸(`run_all.sh` 表里 `GATE` 栏为 `-`)—— 单支 `OK` 只证明"没有失败输出",不证明每条断言都跑过。
- [`tests/run_all.sh`](../../tests/run_all.sh) 的承重安全检查只读整行注释以外的文本,看不见经 helper 间接开端口 / 拉子进程的形状 —— 新增这类支必须手工进 `EXCLUDED`。
- [`tests/run_real.sh`](../../tests/run_real.sh) 的 R20 锁心跳只在**支间**刷新(`LOCK_STALE_SECS` = 600s)—— 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- [`tests/probe/path_integrity_probe.gd`](../../tests/probe/path_integrity_probe.gd) 在 Windows 上不区分大小写 —— 路径大小写写错会通过(导出成 `.pck` 后区分大小写);它只答"有没有",不答"大小写对不对"。
- [`tests/probe/snapshot_size_probe.gd`](../../tests/probe/snapshot_size_probe.gd) 的世界包分片悬崖（FULL 最坏 trail 4 点，`8 + N×49`）：N≈28 时 1380 B < 1400 B MTU —— 超 MTU 即 unreliable 分片，丢一片 = 整帧丢。稳态 keyframe 帧远小于此。
- [`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的 `PREDICTED_KEYS` 是"预测被证实"要比对的**唯一字段集**;往 `Player.capture_state()` 加影响判定的字段时,**没有东西提醒你也加进比对**（症状 = 两端慢慢漂）。当前由 `rollback_fidelity_probe` 的键集对账兜底。
- **拆砖事件的 seq 注入有一条"退化回旧行为"的兜底**（[`scenes/mp_client/tile_sync.gd`](../../scenes/mp_client/tile_sync.gd) `_apply_event`）：`seq=0`（重连补态 / 探针直调）或注入被拒（环外 4.3s / 已 ack / 乱序 / 没有 rollback）⇒ **立即应用**。那一次仍可能产生一次回滚（不会连环）。服务器"逐 peer 发 seq"**没有自动守卫**，只有真链路 `pvp_match_smoke` 间接反映。
- **`CombatComponent.restore_alive_state()`**（`revive()` 减去 `hp=max_hp`）：C2 回滚 / 权威态 / 回溯三条恢复路径的"倒地→活着"都走它 ⇒ 跨"死亡→活着"的恢复现在按快照 hp，**旧行为是满血**（修 bug，但属可感知变化，headless 够不到、无断言）。
- **服务器 Beta 回溯只寻帧**（[`server/match/match_host.gd`](../../server/match/match_host.gd) `_apply_rw_frame` 调 `Player.rewind_restore`）：它依赖帧 schema `p/v/hp/facing/downed/widx/wmags/wlive`；改了 `_record_rw_frame` 的键就必须同步 `rewind_restore`，**没有前置编译提示**。
- **客户端出生即落稳**（[`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_settle_local_spawn`，三模式共用）：在 `_boot_world()` 里把"从格子中心落到地面"这段物理**提前跑完**（≤8 步，超了放弃）。**未跑验证**（用户当轮要求别测 + 另一会话占着 Godot 进程）⇒ 若出现"出生卡在墙里 / 悬空不动 / 落点比服务器高"，第一嫌疑是这里；正常表现应是首条 ack 时两端 `pos` 差 < 2px（原先实测差 9.6px，每局固定一次开局回滚）。
- **服务器按实例 id 判"这颗弹广播过没有"**（[`server/match/match_combat.gd`](../../server/match/match_combat.gd) 的 `_seen_bullets`）——子弹池化（[`core/present/bullet_pool.gd`](../../core/present/bullet_pool.gd)）之后，"同一帧内死一颗 → 池把它借给下一发"会被判成同一颗 ⇒ **不再广播**（客户端少看见一发、服务器不报错）。池已加"同一物理帧归还的实例不借出"（`_released_frame`）缓解；**结构修复未做**：把广播判据改成每发一个 use generation，或广播后清 meta 改按 `use_id` 记账（动 `server/match/**`，要单独评审）。
- [`docs/eng/registered-debt.md`](registered-debt.md) 本身**不是**逐项待办:它只登记"现在仍成立"的边界;任务清单在 `docs/superpowers/plans/`。

## 零守卫面（按面列出;只统计 2026-10-24 削减后仍无替代守卫的）

| 面 | 原来挡什么 | 现在 |
|---|---|---|
| 模式常量 / 选项键 / 房间规则表（`mode_defs` / `mode_options` / `mode_room_rules`） | 单一来源一致性(3v3 曾上发 1v1 的禁用武器；16 人上限只改一半) | **零守卫**,只能靠联机场景行为 / 试玩 |
| worker argv 解析边界(`mode_context`：`--` 之后、`--roles` 等长、role 0/17) | 启动参数静默跑错分支 | **零守卫**（计划 T8 改成 build/parse 一对纯函数 + 往返断言） |
| 房间注册表三表合一 / `started`↔`in_match` 双向别名(`room_registry`) | 同号跨模式不串 | **零守卫** |
| 通道表 ↔ `@rpc` 声明对账(`rpc_channel_contract`) | 通道号漂移 | 已由 [`tools/gen_rpc_channel_table.py`](../../tools/gen_rpc_channel_table.py) `--check` 接管 |
| 轴钳位 / 队列有界 / 丢包保边沿 / 抖动上限(`server_input_sanitize`) | 输入包异常 | 已由 `input_queue_smoke` 按类别接管 |
| `get_axis("up","down")` 由 held 推导(`network_input`) | 梯子回拉 | **零守卫** |
| `--diag` 开关零成本 / 审计文件命名与保留(`net_diag` / `ops_log`) | 日志口径 | **零守卫** |
| 服务端面板数据层:端口三态 / 房间快照纯判据(`server_status`) | 面板读数错 | **零守卫** |
| 重连补态「先还原基线、再应用 destroyed」(`resync_world`) | 幽灵墙 | **零守卫** |
| 可破坏砖碰撞逐 16px 子格与游戏规则一致(`tile_collision`) | 碰撞/渲染不一致 | **零守卫** |
| 地图目录/选图路径校验；cyrm v4 编解码 CRC 往返(`map_catalog` / `map_format_v4`) | 存档 / 地图格式面 | **零守卫** |
| 鸟跟随玩家跨接缝回绕(`wrap_probe`) | 接缝露馅 | **零守卫**（原支本就零断言,删掉不减少保证) |
| 拆砖事件的时间锚点（`MatchCombat._event_seq_for` 用 `_stepped_seq`、受击/整格/子格三条事件都走它、拆砖逐 peer 发） | 锚点晚一 tick / 广播发不出每人自己的 seq ⇒ 注入错 seq、幽灵墙循环 | **零守卫**（源码文本守卫按 `test-economy` D6a 砍掉）；行为面只有 `net_tile_fx_probe` 的注入/兜底两条 + 真链路间接反映 |
| 回溯/权威态的状态恢复（`Player.rewind_restore` / `restore_state` / `apply_authoritative_state` 的 hp·倒地·击退·武器残弹） | 两份抄写漂移（服务器不清 `knock_velocity`、`revive()` 把 hp 顶成满血） | **零守卫**（headless 够不到端到端）；2026-11-01 已合并成单一实现，漂移源消失 |
