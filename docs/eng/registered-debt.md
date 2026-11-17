# 已知边界与已知红

> 一行一项:**现象 + 规避 / 影响面**。销掉即删行。跑法与判据见 [`tests.md`](tests.md),取舍见 [`test-economy.md`](test-economy.md)。
> ★ **2026-11-02:本文件从 1,204 行砍到 ~60 行** —— §九~§五十六 的**逐批过程叙述**（"做了什么 / 逐字判词 / 差了几字节"）
> 已全部删除。它们记的都是**已经落地的改动**,存档在 git log 与各批提交里,不进"动手前必看"。
> 保留的只有**当前仍然成立**的三类:已知红 · 已知边界 · 零守卫面的清单。

## 已知红

- `tests/probe/team_match_probe.sh` —— **不可当 3v3 的端到端守卫**：2026-10-31 同配置两跑，第一跑 `FAIL`（c4 相⑤ 观察窗内快照间隔 10009ms > 1s，其余 5 端 19~34ms；c4 进程仍在跑心跳、分数也不变 ⇒ "该 peer 10s 没收到世界包"，探针自己写明"客户端停顿 / 定向投递异常无法区分"），第二跑 **`TEAM MATCH PROBE: ALL-OK`** ⇒ 判为**时序性 flake**，不是崩溃/协议回归；影响面 = 3v3 只能靠该支日志 + 人工试玩。2026-11-05 在继承链拆解（S1~S4）后复跑：一次 `ALL-OK`（283s），另一次在**开局前**即 `FAIL`（"选边前只有 5/6 人进房" + "大厅队伍表是空的"，只跑到 2 条断言）⇒ 仍是同一支的时序/启动 flake，未指向拆解。翻案条件 = 同配置再现 10s 级单端快照断流、或开局前丢客户端时按真缺陷查（先看 `all_peers_sendable`、`is_peer_live`、大厅 `team_room_state` 的 your_role 序列）。2026-11-06（S4b:等价的"宿主 has-a 上下文"结构）复跑：`ALL-OK` 多次(274~282s)；其间也偶发单端 `FAIL cN role=N team=0`（该端没收到 `match_sync_data`）；加"早到报到按 peer 排队 + claim 成功后重试"后仍偶发一次、再跑即 `ALL-OK`；worker 侧临时诊断显示 6 端都收到了非空 `teams` ⇒ 仍判启动/投递时序 flake。2026-11-16/17（回溯帧契约 + `PlayerNetState` 两次结构改动后）又见同一形状：先跑 `FAIL`（c2 相① `teams` 空、队色错 2、相④ 210s 内没打到 9 杀），同配置重跑 `ALL-OK`(285s) ⇒ 与状态编解码无关，仍是启动/投递时序。
- `tests/smoke/pvp_match_smoke.sh` —— **偶发 flake（2026-11-05）**：一次 `FAIL`（`SMOKE_MATCH FAIL: 超时 ... bullet_spawn=false`，同跑 snapshot/round_state/moved/ack 全真），同配置第二跑 **`SMOKE PASS`**。原因未定位；候选 = create 端服务器发的是**随机武器**，若随机到激光（只有 `beam_fired` 无 `bullet_spawn`）则该断言恒假，或纯时序。翻案条件 = 同配置连续复现（改探针判据前先确认不是"随机到非子弹武器"这一类）。2026-11-06（S4b 结构改后）另见一次 **1200s `NO-VERDICT`（hang）**：日志停在"客户端 B 加入"、没有任何客户端输出；同配置另有多跑 `SMOKE PASS` ⇒ 仍判环境/时序 flake，未指向结构改动。
- `tests/probe/rejoin_probe.sh` —— 2026-10-24 起的已知红**已修**（watcher 代发 `pvp_start`）；2026-10-31 复跑 `REJOIN PROBE: ALL-OK(5)`。
- `tests/known_red.txt` 基线当前 **0 条** —— 任何红都算新红,`run_all.sh` 退出码非 0。

## 已知边界

- [`tests/harness/menu_autotest.gd`](../../tests/harness/menu_autotest.gd) 被产品代码 [`scenes/main_menu.gd`](../../scenes/main_menu.gd) `load()`(菜单的 `-- --autotest-*` 钩子)—— 改名 / 删除 / 移动它,必须同批改产品代码,否则钩子失效。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 手抄 `UiFactory.menu_panel()` 的 64/46,镜像守卫用同一对字面量 —— 改 `menu_panel()` 默认值**不会红**,生成物与守卫一起静默用旧值;改默认值必须两处同改。
- **UI 设计系统 v1 的遗留边界（2026-11-09）**：
  - `UiKit.add_tab()` 里的 `ScrollContainer` 滚动条不会自动继承 `Kit` variation（动态滚动条需显式 `get_v_scroll_bar().theme_type_variation = &"Kit"`）。
  - `settings_menu` / `info_menu` / `beta_menu` 现在是**运行时构建**页面：unique name 由 `_ready` 里补 `owner` 登记，`.tscn` 里没有子节点；外部工具别解析 `.tscn` 找这些节点，要实例化后 `%Name`/`find_child`。
  - `tools/gen_menu_scene.gd` 里 info/beta/match_result 的旧结构转换路径已失效（三页改成 root-only/代码构建）；工具不在默认批，仅影响手工重生成。
  - `scenes/lobby_page.gd` 有 `DisplayServer.get_name() == "headless"` 早退：headless 实例化大厅不自动连服务器（默认批不占端口/不连外网）；真链路不受影响，但 headless 冒烟覆盖不到「_ready 自动连接」。
  - `ui/screens/pause_menu.*` / `match_result.*` 是 Control 叠加层 / 全屏状态屏，**不是** `AcceptDialog`（契约 §5 明确例外）；改弹层语义要连 Esc/toggled/leave_requested 一起评审。
  - `UiFactory.ui_label(..., "dim")` 仍是 32px（Label `Dim` variation 维持旧值以不静默缩小未迁移页）；16px 弱化文字走 `UiFactory.label(text, T_LABEL, C_TEXT_DIM)` 动态色 API。
- 默认批多数支没有 `EXPECTED_CHECKS` 条数闸(`run_all.sh` 表里 `GATE` 栏为 `-`)—— 单支 `OK` 只证明"没有失败输出",不证明每条断言都跑过。
- [`tests/run_all.sh`](../../tests/run_all.sh) 的承重安全检查只读整行注释以外的文本,看不见经 helper 间接开端口 / 拉子进程的形状 —— 新增这类支必须手工进 `EXCLUDED`。
- [`tests/run_real.sh`](../../tests/run_real.sh) 的 R20 锁心跳只在**支间**刷新(`LOCK_STALE_SECS` = 600s)—— 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- [`tests/probe/path_integrity_probe.gd`](../../tests/probe/path_integrity_probe.gd) 在 Windows 上不区分大小写 —— 路径大小写写错会通过(导出成 `.pck` 后区分大小写);它只答"有没有",不答"大小写对不对"。
- [`tests/probe/snapshot_size_probe.gd`](../../tests/probe/snapshot_size_probe.gd) 的世界包分片悬崖（FULL 最坏 trail 4 点，`8 + N×49`）：N≈28 时 1380 B < 1400 B MTU —— 超 MTU 即 unreliable 分片，丢一片 = 整帧丢。稳态 keyframe 帧远小于此。
- [`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的 `PREDICTED_KEYS` 是"预测被证实"要比对的**唯一字段集**;往整态加影响判定的字段时（加在有所有权的组件的 `capture_state()`，由 [`PlayerNetState`](../../scenes/player/player_net_state.gd) 装配），**没有东西提醒你也加进比对**（症状 = 两端慢慢漂）。当前由 `rollback_fidelity_probe` 的键集对账兜底。
- **拆砖事件的 seq 注入有一条"退化回旧行为"的兜底**（[`scenes/mp_client/tile_sync.gd`](../../scenes/mp_client/tile_sync.gd) `_apply_event`）：`seq=0`（重连补态 / 探针直调）或注入被拒（环外 4.3s / 已 ack / 乱序 / 没有 rollback）⇒ **立即应用**。那一次仍可能产生一次回滚（不会连环）。服务器"逐 peer 发 seq"**没有自动守卫**，只有真链路 `pvp_match_smoke` 间接反映。
- **`CombatComponent.restore_alive_state()`**（`revive()` 减去 `hp=max_hp`）：C2 回滚 / 权威态 / 回溯三条恢复路径的"倒地→活着"都走它 ⇒ 跨"死亡→活着"的恢复现在按快照 hp，**旧行为是满血**（修 bug，但属可感知变化，headless 够不到、无断言）。
- **服务器 Beta 回溯的帧契约**（[`core/sim/rewind_frame.gd`](../../core/sim/rewind_frame.gd) `RewindFrame`）：帧形状 `{t, player}`、玩家载荷键集 `PLAYER_KEYS` 是唯一来源；单机 `WorldRewind` 与服务器 `_record_rw_frame` 共用同一个生产者、`_apply_rw_frame` 只寻帧后调 `RewindFrame.apply_player`。加字段仍要同时改 `build_player` / `apply_player`（**没有前置编译提示**），但"加了键却没测"会被 [`tests/probe/rewind_frame_probe.tscn`](../../tests/probe/rewind_frame_probe.tscn) ① 的键集/取值器断言照出来。
- **客户端出生即落稳**（[`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_settle_local_spawn`，三模式共用）：在 `_boot_world()` 里把"从格子中心落到地面"这段物理**提前跑完**（≤8 步，超了放弃）。**未跑验证**（用户当轮要求别测 + 另一会话占着 Godot 进程）⇒ 若出现"出生卡在墙里 / 悬空不动 / 落点比服务器高"，第一嫌疑是这里；正常表现应是首条 ack 时两端 `pos` 差 < 2px（原先实测差 9.6px，每局固定一次开局回滚）。
- **服务器按实例 id 判"这颗弹广播过没有"**（[`server/match/combat_system.gd`](../../server/match/combat_system.gd) 的 `_seen_bullets`）——子弹池化（[`core/present/bullet_pool.gd`](../../core/present/bullet_pool.gd)）之后，"同一帧内死一颗 → 池把它借给下一发"会被判成同一颗 ⇒ **不再广播**（客户端少看见一发、服务器不报错）。池已加"同一物理帧归还的实例不借出"（`_released_frame`）缓解；**结构修复未做**：把广播判据改成每发一个 use generation，或广播后清 meta 改按 `use_id` 记账（动 `server/match/**`，要单独评审）。
- [`docs/eng/registered-debt.md`](registered-debt.md) 本身**不是**逐项待办:它只登记"现在仍成立"的边界;一次性任务清单不入库(见 git log 与提交信息)。

## 零守卫面（按面列出;只统计 2026-10-24 与 2026-11-04 两轮削减后仍无替代守卫的）

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
| 拆砖事件的时间锚点（`CombatSystem.event_seq_for` 用 `_stepped_seq`、受击/整格/子格三条事件都走它、拆砖逐 peer 发） | 锚点晚一 tick / 广播发不出每人自己的 seq ⇒ 注入错 seq、幽灵墙循环 | **零守卫**（源码文本守卫按 `test-economy` D6a 砍掉）；行为面只有 `net_tile_fx_probe` 的注入/兜底两条 + 真链路间接反映 |
| 权威宿主/客户端的结构规则（C 方案：薄壳 `MatchHost`/`PvpMatchClient` + `state`/`ports` + 域系统；系统只依赖 state+ports、不持宿主、不碰 `NetBus`/场景树；依赖是 DAG） | 系统回头持有宿主或直接碰网络/场景树 ⇒ 难测 + 类循环；把网络/生命周期塞回 `state` ⇒ 状态不可单测；ports 漏绑/模式钩子漏传 ⇒ 静默丢功能（只有 `MatchPorts.is_ready` 的 assert 兜一部分）；重新长回 `extends` 分层 ⇒ 旧的 7 层链惨案（`0ae93a3e`/`3c8dc8f0`/`726a4008`，拆解见计划文件） | **零守卫**，规则只写在 [`netplay.md`](netplay.md)「权威宿主的结构」与本表；按文件路径读源码的形态守卫按 `test-economy` D6a 不写 |
| 回溯/权威态的状态恢复（`RewindFrame.apply_player` / `restore_state` / `apply_authoritative_state` 的 hp·倒地·击退·武器残弹） | 两份抄写漂移（服务器不清 `knock_velocity`、`revive()` 把 hp 顶成满血） | 回溯载荷往返 + 倒地恢复 hp 有 `rewind_frame_probe` 两条（2026-11-16）；**端到端（免伤/倒放）仍零守卫**。2026-11-01 起恢复实现单一，2026-11-16 起载荷也单一 |
| 房间生命周期约定（[`room-lifecycle-conventions.md`](room-lifecycle-conventions.md) A–I：端口归还/注册表删除/凭据作废收口 · 三表清扫 · pid 账 · 回收梯 · 启动协议 · 宽限分派 · 3v3 开局三律 · 一局限时上界链） | 新加拆除路径漏一步 ⇒ **静默端口泄漏**；清扫漏一张表 ⇒ 房与端口永不回收；启动参数静默跑错分支 | **零守卫**（源码文本检查器 `tools/room_sweep_lint.gd` 已删，2026-11-04 `test-economy` D6a/D8；行为面 `pvp_room_smoke.sh` 更早已删）⇒ 只剩该页 §3 人工自查 + 真链路间接反映 |
| 大乱斗多人端到端（8/9 人局、worker role 上界 16、多人编解码/负载读数） | 16 人上限只改大厅/UI、worker 仍卡 8 的洞；多人局端到端回归 | **零守卫**（`royale_soak_probe.*` 与 `royale_role_cap_probe.sh` 已删，2026-11-04 D2/D8）⇒ 只剩历史读数与人工试玩；回归入口 = git 历史 |
| bot 端到端（观察 → 决策 → 输入全链 · 真对局表现） | 输入手柄只实现无参钩子、漏带参钩子 ⇒ 服务器侧从不跳/不开火且 C2 每帧回滚（`team_bot_input.gd` 文件头教训） | **零守卫**（`bot_1v1_probe` + `bot_watcher` + `bot_input` 已删，2026-11-04）；纯逻辑观察/决策仍有 `bot_brain_smoke`；回归入口 = git 历史 |
| 背景四层景深的**旧端降级**(layer_flags bit4-6) | 旧编辑器/旧游戏版读新图时忽略 bit4-6 ⇒ 只看到「背景 100%」,另三层静默不画 | **契约性降级,不修**;新端行为零守卫(原探针已删,2026-11-08),旧端已不存在 ⇒ 无从测 |
| 渲染表现与数据细节(水体合批分桶/图集行序、tint 像素数学、视差两式、相机跟随、天色/光照/形体光) | 静默错色 / 错行 / 错相机,只有人眼能发现 | **零守卫**(按仓主裁定,2026-11-08 删除 water_atlas / wall_tint / tint_parity / bg_parallax / torus_camera 五支数据契约探针);唯一自动守卫 = `tests/probe/level0_boot_probe.tscn`(19 条:启动与接线结构) |
