# 已知边界与已知红

> 一行一项:**现象 + 规避 / 影响面**。销掉即删行。跑法与判据见 [`tests.md`](tests.md),取舍见 [`test-economy.md`](test-economy.md)。

## 已知红

- `tests/probe/team_match_probe.sh` —— **不可当 3v3 的端到端守卫**：2026-10-31 同配置两跑，第一跑 `FAIL`（c4 相⑤ 观察窗内快照间隔 10009ms > 1s，其余 5 端 19~34ms；c4 进程仍在跑心跳、分数也不变 ⇒ "该 peer 10s 没收到世界包"，探针自己写明"客户端停顿 / 定向投递异常无法区分"），第二跑 **`TEAM MATCH PROBE: ALL-OK`** ⇒ 判为**时序性 flake**，不是崩溃/协议回归；影响面 = 3v3 只能靠该支日志 + 人工试玩。翻案条件 = 同配置再现 10s 级单端快照断流时按真缺陷查（先看 `all_peers_sendable` 与 `is_peer_live` 对该 peer 的读数）。
- `tests/probe/rejoin_probe.sh` —— 2026-10-24 起的**已知红已修**（见 §三十七：watcher 代发 `pvp_start`）；2026-10-31 复跑 `REJOIN PROBE: ALL-OK(5)`。
- `tests/known_red.txt` 基线当前 **0 条** —— 任何红都算新红,`run_all.sh` 退出码非 0。

## 已知边界

- [`tests/harness/menu_autotest.gd`](../../tests/harness/menu_autotest.gd) 被产品代码 [`scenes/main_menu.gd`](../../scenes/main_menu.gd) `load()`(菜单的 `-- --autotest-*` 钩子)—— 改名 / 删除 / 移动它,必须同批改产品代码,否则钩子失效。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 手抄 `UiFactory.menu_panel()` 的 64/46,镜像守卫用同一对字面量 —— 改 `menu_panel()` 默认值**不会红**,生成物与守卫一起静默用旧值;改默认值必须两处同改。
- 默认批多数支没有 `EXPECTED_CHECKS` 条数闸(`run_all.sh` 表里 `GATE` 栏为 `-`)—— 单支 `OK` 只证明"没有失败输出",不证明每条断言都跑过。
- [`tests/run_all.sh`](../../tests/run_all.sh) 的承重安全检查只读整行注释以外的文本,看不见经 helper 间接开端口 / 拉子进程的形状 —— 新增这类支必须手工进 `EXCLUDED`。
- [`tests/run_real.sh`](../../tests/run_real.sh) 的 R20 锁心跳只在**支间**刷新(`LOCK_STALE_SECS` = 600s)—— 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- [`tests/probe/path_integrity_probe.gd`](../../tests/probe/path_integrity_probe.gd) 在 Windows 上不区分大小写 —— 路径大小写写错会通过(导出成 `.pck` 后区分大小写);它只答"有没有",不答"大小写对不对"。
- [`tests/probe/snapshot_size_probe.gd`](../../tests/probe/snapshot_size_probe.gd) 的世界包分片悬崖（FULL 最坏 trail 4 点，`8 + N×49`）：N≈28 时 1380 B < 1400 B MTU —— 超 MTU 即 unreliable 分片，丢一片 = 整帧丢。稳态 keyframe 帧远小于此。

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
| `rpc_channel_contract` | 通道表 ↔ `@rpc` 声明文本对账（含 `beam_fired` 重名集合） | **已由 `tools/gen_rpc_channel_table.py --check` 接管**（S-02，2026-10-31），见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md) |
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

**本批新增的覆盖缺口**（默认批 2026-10-26 起为 11 支；新增的 5 支不含这类"按一次只触发一次"的输入边沿断言，故缺口不因此缩小）：客户端侧边沿行为（数字键 1-4 只切一次 / F 只拾取一次 / Q 长按只丢一次）**零自动化守卫**；C2 逐 tick 重放只有 `rollback_fidelity_probe`（纯逻辑）与真链路 soak（真 `royale_game` 客户端跑 `SOAK: ALL-OK`，但不断言"按一次只切一次"）。翻案条件 = 再做输入/回滚改动时，先补 `sampled`/边沿类 `-s` 守卫或在真链路里加断言，否则这些行为只能人工试玩。

**本批真链路证据**：`pvp_match_smoke.sh` = `SMOKE PASS`；`royale_soak_probe.sh` = `SOAK: ALL-OK`（4 客户端真 royale_game，观测 58s，含受击/倒地/击杀/离场）。`rejoin_probe.sh` 失败见上「已知红」。

## 十一、2026-10-24 副本插值撤回又恢复 + 渲染层带 —— 边界与代价

> 现象（玩家报）：联机里「其他玩家的幽灵体图层不对（被梯子 / 建筑压着的应该是它，结果它压着地形）」，且「动作没有插值，看起来很怪」。
> 根因两条都是 `9378f5b0` 那批改动留下的：① 副本位置改成直出最新快照（理由是「本机实测与插值无差别」，真联机下不成立）；② 副本是运行时 `add_child` 到世界末尾的，而本体在 `level_0.tscn` 里排在 `WallLayer` 之前。

**改了什么**：恢复 `core/net/playout_clock.gd` + 位置历史 / 夹逼插值 / `SNAP_DIST` 一帧落位（`PLAYOUT_TICKS = 4`，30Hz 下行 = 2 个发包间隔 ≈ 67ms）；副本在 `_ready` 里把自己挪到 `Level0.wall_layer` 之前（与本体同一条渲染层带）；`allscript_probe` 的 `EXPECTED_SCRIPTS` 174→175。

**新增代价（如实登记）**：画面比权威晚 ≈67ms（深度补偿时最多 ≈133ms）；幽灵碰撞体**不跟**这段延迟（它直出最新权威位置）⇒「看得见的对手」与「挡你的对手」之间存在该量级的位置差。这是「观感平滑」换「预测一致」，不要为了消这个差把幽灵体也接上插值。

**零自动化守卫**：平滑度与图层遮挡都是观感项，仓主裁定不跑 / 不加自动守卫（见 [`tests.md`](tests.md) 的「不写清单」）。本轮验证 = 导出产物冒烟（`build_release.py`：客户端直接起 + `--registry-report` + 服务端 `--worker --port 7999`，三条都 `OK`）+ 一次临时 headless 探针（已删：30Hz 夹具下零位移帧 3/60、单帧位移恒 5.00px、幽灵体偏差 10px = 最新快照领先量、副本 index 1 < WallLayer index 2）+ 人眼。翻案条件 = 同类现象被玩家再报一次，或有人把 `_process` 改回直出 / 删掉 `_reorder_before_structures`。

**前提**：`level_0.tscn` 里 `Player` 必须排在 `WallLayer` 之前（本体的层带就是这么来的）；换这个顺序要同批复查 `player_replica._reorder_before_structures`。

**2026-10-24 追补（同一现象的第二轮）**：① 外观态（`pose` / `facing` / `aim` / `aim_facing` / `downed` / `type_id` / `vel`）改成与位置**同一渲染时刻**取样 —— 之前它们逐包瞬跳，动画/枪口比身体早一拍多，观感是「对手停下了腿还在走」（滑步）；幽灵碰撞体仍吃最新快照。② 客户端收到 `go_match` 后在帧末**再等一帧**才 `NetBus.stop()`，让大厅最后两条定向包先落地（治 `max channels: 0` 里客户端能治的那一半）。本轮按仓主明确要求**没有跑任何验证**（含探针与真链路），只做了导出产物冒烟；滑步/延迟是否可接受由人眼定。若仍嫌「飘」，调 `PLAYOUT_TICKS`（4 → 2/3 即 ≈33/50ms，`player_replica.gd` 顶部一行）。

## 十二、2026-10-26 联机拆砖粒子修复（锚定 / 17→1 / 去重）—— 边界与代价

> 现象（玩家报）：联机里可破坏砖被打/被拆的粒子反馈不对（接缝附近碎片出屏/错位、激光拆一格炸屏、致死一击双份）。根因三层全在**表现层** `scenes/mp_client/tile_sync.gd` + 两个粒子调用点，历次拆砖修复（幽灵墙/子格 4×4/复位）动的都是状态层。

**改了什么**：① 服务器事件坐标是 canonical ⇒ `TileSync._fx_pos()` 用 `anchor_to_nearest(…, 本地玩家)` 锚到可见副本（单机/拿不到本地玩家时原样返回）；② `on_cell` 的 16 次子格清理一律 `silent`，格级只播 1 簇（旧实现 17 簇/170 粒子）；③ `on_sub` 用 `damage_sub` 返回值判据（已死/重复事件不播）；④ 新增 `TileHitFx.mark_hit` / `consume_hit_near` 近期命中表（250ms / 48px / 128 条有界），视觉子弹、爆炸、激光的本地命中碎片播过之后，服务器破坏事件不再叠一份；⑤ `bullet_base._explode` 的爆炸碎片也走锚定。守卫 = `tests/probe/net_tile_fx_probe.tscn`（9 条断言 + `EXPECTED_CHECKS`，无端口/无子进程）。

**已知边界（照实）**：① 去重是**表现层启发式**（窗口/半径是拍的；发射端本地没播过命中、而服务器拆了的那种仍会播；反过来"本端播过、服务器其实拆的是别处"会漏一簇）——观感项只人眼验收；② 真链路证据待补：`sub_destroyed` RPC 是否真到达仍只有源码推断（`match_state.gd:146` 的「首次真正生效需复核」未销），本轮探针**不碰 RPC**（2026-10-26 已跑 `pvp_match_smoke` = `SMOKE PASS` 与 `royale_soak` = `SOAK: ALL-OK(4/4)`，但**只证明不崩/链路通**，没有一条断言直接数 `sub_destroyed` 到达）；③ 服务端 headless 仍会给每颗命中/爆炸/激光建不可见粒子（P4 未修，纯浪费）；④ 粒子层此前**零守卫**（`tile_collision` / `resync_world` / `bullet_tile_fx` 三支已删），本探针只覆盖客户端表现层坐标/簇数/去重三件事。⑤ 默认批 2026-10-26 追加 5 支守卫（6→11 支 / 62 条闸断言）：水判定、命中几何、最小破坏单位、联机粒子、子弹扫掠各 1 支；粒子层由此前零守卫变为有 1 支客户端表现层探针。翻案条件 = 真链路 `--diag` 的 `tile_sub/tile_cell` 读数与探针结论矛盾，或玩家再报接缝附近粒子错位。

## 十三、2026-10-26 碰撞箱/受击判定分离（hit_shape + hurt_rect + 扫掠命中）—— 边界与代价

**改了什么**：新增 `core/sim/hit_shape.gd`（纯静态：rect_of / rect_at / segment_hits_rect / distance_px_to_rect / first_hit）；玩家 / 敌人 / 对手副本各加 `hurt_rect()`（副本为 `hurt_rect_rendered()`）；`bullet.tscn` 与 `enemy_bullet.tscn` 的 collision_mask 5/3→**1**（只撞地形）；单机子弹/敌弹改"上一位置→当前位置"线段扫掠；PvP 服务器裁决与客户端 cull 走同一函数；激光 `_body_rect`、爆炸距离统一到它。删除 `BulletBase.PLAYER_HIT_RADIUS` / `MatchState.HIT_RADIUS`；新守卫 `tests/smoke/hit_shape_smoke.gd`（13 条断言 + 条数闸）与 `tests/probe/bullet_sweep_probe.tscn`（3000px/s 一帧跨 20px 受击面必中）。

**平衡变化（请人眼验收，不是回归）**：① PvP 玩家受击面由 40px 圆变当前姿态 AABB ⇒ 视觉受击面积变大、命中率上升；② 爆炸判定由"中心点→中心点"变"点到受击面" ⇒ 等效爆半径按半身变大（内圈比例/衰减曲线未动）。

**零自动化守卫的边界**：
- 姿态切换与 `hurt_rect()` 的同帧一致性：`hurt_rect()` 每次现算 `CollisionAabb.world_rect`（读 disabled），几何本身无缓存；但"判定读的是当帧已切好的箱"这条时序没有任何自动化断言 —— 新冒烟只测纯函数几何，不测真 Player。
- 真链路（`pvp_match_smoke.sh` / `royale_soak_probe.sh`）**已跑**：`SMOKE PASS` / `SOAK: ALL-OK(4/4)` —— 只证明服务器裁决链路不崩、快照/输入/子弹广播照常；**没有一条断言直接量命中率或受击面**，PvP 命中手感仍必须真机人眼。
- 客户端 cull 与权威位置仍有 §十一 的 67ms 时差：本批只统一几何、不统一时间；`hurt_rect_rendered()`（形状取幽灵体、位置取渲染位置）把该时差显式化，但没有消除它。
- `tests/harness/team_match_watcher.gd` 的 `NEAR_PX = 45` 仍按旧 40px 半径留余量，未随受击面重调 ⇒ 该读数偏保守。
- ~~`allscript_probe.EXPECTED_SCRIPTS` 需按新增脚本数同步~~ **已同步**：2026-10-26 全批新增 7 个 `.gd`（`hit_shape.gd` / `water_sample.gd` + 5 支新守卫），常量 176→**183**，且 `res://docs` 进 `SKIP_DIRS`（文档目录里的临时审计驱动不再计入编译面）；`RUN_ALL OK(11 runs / 62 gated-assertions)` 已实测。

## 十四、2026-10-26 子弹最小破坏单位（榴弹 1/4 格，其余 1 格）—— 边界与代价

**改了什么**：`BulletBase.tile_break_unit`（@export，单位 = 格，默认 1.0）；榴弹 `grenade_bullet.tscn` 设 **0.25**（= 1 个 16px 子格；★ 2026-10-30 起改为 **0.5 = 32px**，见 §三十二），其余枪不覆盖 = 1.0。`_damage_tile_at` 按单位分派：整格走 `TileDefs.damage_tile`（格级 `hp_grid`），1/4 格走 `damage_sub`（子格 `sub_hp`）。`Explosion.apply_aoe(..., tile_unit_cells)` 把同一参数传给新的公开 `Explosion.damage_tiles`：整格侧对爆区内每个 64px 格**去重**后按最近子格的衰减值扣一次；子格侧保持现状。`damage_sub` 在整格 16 子格打空、`current_grid[cell]=0` 的同时把 `hp_grid[cell]=0`（两本账在"格子已消失"上对齐）。`grenade_bullet.tscn` 的 collision_mask 5→1（task-8 分离的收尾：榴弹也不再靠物理碰撞吃敌人）。新守卫 `tests/smoke/tile_break_unit_smoke.gd`（10 条断言 + 条数闸）。

**平衡变化（请人眼验收）**：普通子弹打可破坏砖从"16px 逐子格磨"变成"整格一个单位" ⇒ 手枪（10 伤）一发打掉整片树叶格、步枪（4 伤）两发；榴弹仍是 16px 圆洞（爆炸单位 0.25）。网络事件类型相应变化：普通子弹破坏发 `tile_destroyed`，榴弹破坏发 `sub_destroyed`（task-6 的粒子层两种事件都走既有去重）。

**已知边界 / 零守卫**：
- 格级伤害没有"部分损伤"的视觉反馈：格级账被打到 1/8/30 时画面无变化（没有裂纹/血量读数），只有整格消失那一刻才可见；子格路径有逐子格消失但格级不显示 —— 观感项只人眼。
- 混打两本账仍独立：先子格磨掉半格（`sub_hp` 降、`hp_grid` 不动），再用整格单位命中时扣的是格级自己的 8/30，两者不互相抵扣；"格子已消失"的对齐只在整格清空那一刻发生。
- 颗粒（时间玩法）：格级销毁走 `damage_tile(cell, dmg, "explosion")`（无 owner 参数）⇒ `_on_sub_destroyed` 的 0 颗粒路径不变，整格拆砖在 Beta 时间玩法里仍 **0 颗粒**（旧行为，未改）。
- 真链路未跑：网络事件类型变化（tile_destroyed vs sub_destroyed）只有 `-s` 冒烟证据，需真链路批 + 人眼确认客户端两种事件都正常。

## 十五、2026-10-26 时间域解耦（服务器命中回放）+ 命中手感 P0 —— 边界与代价

**改了什么**：① 新增 `core/net/lag_comp.gd`（`PLAYOUT_TICKS=3`、`MAX_REWIND_TICKS=8`，客户端渲染与服务器回放共用）；`PLAYOUT_TICKS` 4→3 ⇒ 画面滞后 67ms→**≈50ms**（§十一 的 67ms 数值从此是历史值；§十三 的"只统一几何、不统一时间"也由此翻案——裁决侧已统一到射手观看时刻）。② 服务器 tick 域对齐：`MatchHost` 每物理 tick `_srv_tick += 1`，`_snap_tick = _srv_tick`（相位仍每 2 tick，tick 序列不变）⇒ 客户端输入包的 `st` 与服务器 tick 同刻度。③ 新增 `core/sim/hit_lag_history.gd`（24 tick ≈ 400ms 环形、每 tick 存 `role → {位置, 相对受击面}`）；`MatchCombat._adjudicate_bullets` 每 tick 推、`_segment_hits_player` 按 `want = clamp(st − PLAYOUT_TICKS, srv−MAX_REWIND, srv)` 回放受击面（普通弹与榴弹直击同一路径；非网络射手/AI 与无历史时回退现时）。④ P0-1 子弹体积：`HitShape.segment_hits_rect` 加 `grow`，`BulletBase.hit_grow()` 把碰撞矩形按速度角投影成世界 AABB 半展，单机/服务器/客户端 cull 三处同传。⑤ P0-3 反馈与可受击：世界系 `HitFeedbackFx`（目标身上的 X + 伤害数字，替代屏幕中心 X），`is_hurtable()` 统一为"敌人未死 / 玩家未倒地 / 副本未倒地"，爆炸敌人循环同过滤。守卫：`lag_history_smoke`（8 条）、`hit_shape_smoke` 13→14、`bullet_sweep_probe` 4→6。

**不动的部分（有意）**：移动预测 / 幽灵碰撞体仍吃最新权威态（时间域解耦只作用于裁决）；协议/c2/快照 schema 零改动（`st` 只是从"落位"变成"有消费者"）；爆炸 AoE **不回放**（现时位置，见下边界）。

**已知边界（照实）**：
- **回放深度不是精确的"射手观看时刻"**：`want = st − PLAYOUT_TICKS` 用的是"最近解码的快照 tick − 名义延迟"；实际单程延迟未知（没有 ping 的 RTT 半程估计进公式）⇒ 深度补偿（`playout_clock` 的 0~4 tick）会让真实渲染时刻比 `want` 再晚 0~4 tick，方向上是"服务器比射手看到的更晚回放"，可能偏保守 0~50ms。
- **AoE 不回放**：爆炸走 `Explosion.apply_aoe`，目标位置取现时；与子弹/激光直击的时间基准不一致（登记为有意：AoE 是区域伤害，回放半径会额外放大）。
- **历史 24 tick / 回放上限 8 tick**：`st` 过旧（断线重连、客户端卡顿 >400ms）时历史取不到 → 回退现时受击面（行为退回 P0 前）；`MAX_REWIND_TICKS=8` 防止异常 `st` 把回放拉穿。
- **无受击面历史插值**：`rect_for` 只取"最近的已记录 tick"（向下取整，无两帧插值）⇒ 回放位置有最多 1 tick（16.7ms）量化误差；姿态切换（站/蹲/飞箱尺寸变化）也按 tick 粒度跳变。
- **零自动化守卫**：回放链路的正确性（`st` 送达、`_srv_tick` 与快照 tick 同相位、回放命中率）只有 `-s` 纯逻辑（`lag_history_smoke`）+ 源码阅读；真链路 `pvp_match_smoke.sh` / `royale_soak_probe.sh` 需跑批 + 人眼，命中率与"看着中"是否改善只能实机试玩。
- P0-3 的伤害数字是本地表现：客户端只画自己收到的命中确认/命中反馈，数值取自 `hit_damage`（切枪后 source 失效时即子弹自带值），可能与服务器最终结算（武器真值）差一档；不参与任何判定。

## 十六、权威爆炸表现同步（2026-10-27，档 3）

**改了什么**：NetBusExt 新增可靠 RPC xplosion(pos, shooter_role, visual) + 信号 local_explosion；MatchHost 加入 uthority_explosion_sink 组并在 on_authority_explosion() 里用 _rpc_all_ext 广播权威位置；BulletBase._explode() 在有组回调时上报（子弹内不引 autoload，-s 冒烟可加载）；PvpMatchClient._enter_tree() 接信号，收到后收掉本端对应射手的视觉榴弹（取离权威位置最近那一颗）并在权威位置补画爆炸——**自己那发若视觉榴弹已自炸过则跳过，专治"双爆"**。

**为什么**：视觉榴弹由各端自己模拟（自己的=本地预测、对手的=快照位置+初速重建），引信/反弹与服务器裁决不同步 ⇒ 爆炸动画位置/时刻和掉血位置对不上；先看到本地炸、再看到权威伤害，读起来像"两次爆炸"。本事件把"看到的爆炸"钉在权威位置。

**边界（如实登记）**：① 射手自己那颗若已本地自炸，权威事件只用来收尾、不重播（可能仍比权威位置偏一点，属于本地预测表现）；② 事件是可靠通道但无序号，重连/丢包窗口内可能少一次表现；③ 纯表现层，零自动化守卫（只能真链路看 RPC 不报错 + 人眼）；④ 权威尺寸/伤害仍走原有服务器路径，未改。

## 十七、2026-10-26 P1 字段定点化（PROTO_VERSION 4→5）—— 字节前后与误差边界

**改了什么**：`core/net/net_codec.gd`：`PROTO_VERSION 4→5`；新增定点类型 `T_QV2`（2×i16）、`T_QAIM`（u8 角度）、`T_FAIM`（2×i16）与常量 `Q_SCALE / Q_VEL_CLAMP / Q_AIM_STEPS / AIM_FP`；世界包 `pos`/`vel`/`aim` 与输入包 `aim` 改定点（编码手写内联写 16 位；解码走 `_unpack` 新增三个 case + `_rd_i16`）；`WORLD_SCHEMA` / `INPUT_SCHEMA` 注释、`TRAIL_WIRE_MAX` 最坏包算式、`encode_*` 字节注释同步。`c2` / `trail` / `ax` / `st` / `ct` 不动（`c2` 是 C2 回滚锚点，不与世界包同批量化）。守卫：`net_wire_smoke` ③ 改定点容差（仍 5 条）、`snapshot_size_probe` 的往返 ③⑤ 改用 `_world_same` 容差并更新量化读数（仍 5 条）。文档：本文件 + `netcode-delta-and-quantization-details.md` §6 + `netcode-snapshots.md` + `netcode-input-uplink.md`。

**字节前后（代码算式；未跑引擎，由 Lead 实测复核）**：世界条目（trail 2 点 / 无 trail）48 → **33 B** / 32 → **17 B**（−31% / −47%）；最坏世界包（16 人 × trail 4 点）1031 → **791 B**；世界包 N=16（trail 2 点）775 → **535 B**、N=2 103 → **73 B**；输入包 46 → **42 B**（−8.7%）、30Hz ⇒ 1.38 → **1.26 KB/s**/客户端；本人包 94 B 不变；服务器上行（扇出算式，N=16）407.3 → **294.8 KB/s**。

**与任务书的偏差（唯一一处）**：任务书 "0.1px 定点（`round(pos*10)`），值域 0..19200 fits i16" 的算式不成立 —— 19200 是**缩放后**的值，而 0.1px 步长下 9600px 地图要 96000 > i16 上限 32767。改用 **0.5px 步长**（`Q_SCALE=2`：9600×2 = 19200 正好落在 i16 内，余量到 16383px 地图），量化误差 ±0.25px / ±0.25px·s⁻¹；速度共用该步长（0.25px/s 不可见）。aim 按任务书 u8 角度（误差 ≤0.70°），输入 aim 按任务书 1e-4。

**风险 / 边界**：
- i16 溢出：每个定点值 `roundi` 后 `clampi(-32768, 32767)` **饱和**（不 wrap）；当前最宽地图 9600px 有 1.7× 余量，未来地图 >16383px 会饱和成贴边位置 ⇒ 必须改步长（登记在此，不是静默错位）。
- 负值/回绕：canonical pos 是 [0,MAP)（服务器生产侧已 wrap），但编码对负值按 16 位二补码写出（守卫 fixture 用负 pos/vel 覆盖）；解码统一 `_rd_i16` 还原。
- aim 零向量：世界 aim 零向量 → angle 0 → RIGHT（`atan2(0,0)=0`，语义上"无瞄准"回落朝向）；输入 aim 零向量解码显式回 `Vector2.RIGHT`；定点容差断言要求解码长度 ≈1 ⇒ 漏 normalize 必红。
- 角度回绕：编码 `round(atan2/TAU*256) & 0xFF`（π→128，−π 与 π 同向），解码 `byte/256*TAU ∈ [0,2π)`，无 0/2π 接缝跳变。
- 部署：`PROTO_VERSION` 变了 ⇒ **两端必须同包发布**；旧客户端被解码拒绝（大声失败，不是静默错位）。
- 未做：`c2` 量化（必须两端一起做）、`trail` 量化（<1 B/点收益）、真位流打包；`docs/eng/netcode-at-16-players.md` / `pvp-networking.md` / `render.md` 里的旧字节/带宽读数已随 task-12 同步（P1.5 段）。
- 零自动化守卫：0.25px 位置阶梯与 0.70° 枪口的实际观感只能人眼；字节读数由两支守卫的 readout 打印，"是否值得"由人眼/真链路定。

## 十八、2026-10-26 P1.5 增量/差分（滚动关键帧 + 本人包差分，PROTO_VERSION 5→6）

**改了什么**：`core/net/net_codec.gd` 新增 `FULL/DELTA` 两态世界包与本人包、差分字段机制（`_enc_value` / `_write_unit_value` / `_read_unit_into` / `_delta_mask` / `_deep_equal`）、`apply_world` / `apply_own` 合并函数、周期常量 `OWN_FULL_PERIOD / WORLD_KF_PERIOD` 与 `own_full_phase` / `world_keyframe_quota`；`PROTO_VERSION 5→6`。`match_snapshot.gd` 改为：世界包滚动关键帧（每包 k 人全字段、游标轮转）+ FULL 只在请求/换局/名单变化时发；本人包 30Hz 差分 + 每 role 每 60 tick 错峰全量；本人包状态按 role 保留。`match_host._on_input` 识别 `BIT_NEED_FULL=512`。`net_bus.gd` 在**解码边界**合并（下游仍收完整 `{tick, players}` / `{ack_seq, q, c2}`，三模式客户端/探针/watcher 零改动），并暴露 `snapshot_need_full()` / `reset_snapshot_state()`；`pvp_match_client` 输入包带请求位、重连时重置基准。守卫：`net_wire_smoke` 5→**7**（⑤ 本人包差分、⑥ 世界包 keyframe/差分）；`snapshot_size_probe` 5→**9**（⑥⑦⑧ 尺寸/峰值、⑨ 相位错峰）。

**与任务书的偏差（两处，均按 Lead 补充/现状）**：① 任务书"世界 FULL 每 60 tick 一次"改为**滚动关键帧**（每包 k 人绝对刷新）——整包 FULL 会在 60 tick 边界造尖峰，滚动关键帧更平滑；FULL 只在请求/换局/名单变化时发。② 任务是"本人包降频到 30Hz"——S1(2026-10-24) 起本人包**本来**就是 30Hz，本轮实际新增的是差分 + 60 tick 错峰全量。

**字节/带宽（N=16、30Hz、典型帧；代码算式，由 Lead 实测复核）**：世界包 FULL 536 B → 稳态 keyframe 帧 **152 B**（28%）；本人包 FULL 99 B / 差分典型 36 B @30Hz（每 role 1 次全量/秒，差分 29 次/秒，≈1.14 KB/s）；服务器上行 ≈294.8 → **≈89 KB/s**；单端下行 ≈5.5 KB/s。

**容差 / 位序（承重面）**：世界 DELTA mask bit i = `WORLD_SCHEMA[i]`（`mask=0xFFFF`=keyframe）；本人包 mask 位序 = `C2_SCHEMA` → `WEAPON_SCHEMA` → `inv`（`_own_unit_at` 派生，改 schema 自动跟着变）。判等：世界按量化后整数（pos/vel 定点、aim 字节、bool 逐位）；本人包 float 字段 **1e-4 容差** ⇒ 被省略的字段客户端最多陈旧 1e-4（C2 对账 pos 容差 2px / vel 20，不受影响）。去“定点舍入/位序/宽度”任一错 ⇒ `net_wire_smoke` ⑤⑥ 必红。

**边界（照实）**：
- **世界包丢包最坏**：DELTA 走 unreliable，丢 1 包 ⇒ 客户端基准断 ⇒ 请求 `BIT_NEED_FULL`（reliable 输入）⇒ 服务器下一 30Hz 广播发 FULL（RTT + ≤33ms）。**没有周期 FULL**；滚动关键帧只保证"每个玩家 ≤60 tick 被绝对刷新"，整包基准仍必须连续（否则只能 FULL 修复）。⚠ 不要把世界包挪到 reliable（队头阻塞会让整局滞后）。
- **本人包丢包**：下一包基准断 ⇒ 请求 FULL；即使请求失效也有 60 tick（1s）全量兜底。请求位重复发送无害，FULL 到达后清。
- **相位重合**：本人包全量相位 `floor(idx×30/N)×2` tick，N≤30 互不重合；N>30 会有重合（仍 ≤1s 周期），当前上限 16。
- **基准边界**：客户端 `_world_state` 是"上一份**应用**的包"；服务端在 `all_peers_sendable()` 失败整发跳过时**不推进基准**（否则下一 DELTA 的 base 指向客户端从未收到的包）。
- **快照消费侧零改动**依赖 NetBus emit 完整形状：任何绕过 NetBus 直接解 `snapshot_world/own` 的新消费者必须自己做 DELTA 合并（登记在此）。
- **真链路未跑**：丢包/重连下的修复路径（请求位 → FULL）只有 `-s` 纯逻辑与源码论证，需真链路 + 人眼。
- 世界包 FULL 的 792 B 最坏值仍恒 1 片；`snapshot_size_probe` ⑧ 断言"16 人 keyframe 峰值 ≤2×均值"防的正是"改回整包 FULL 周期"这类回退。


## 十九、快照变卡与爆炸重复粒子（2026-10-28，档 3）

**修 1：本人包频率（结论：保持 30Hz，禁止回退 60Hz）**。P1.5 把本人包降到 30Hz 后用户报"快照变卡"；我先按"C2 锚点间距翻倍"解释并临时改成 60Hz，**仓主裁定 v0.5.1 就是 30Hz 且不卡** ⇒ 已恢复 30Hz（`match_host` 保留 `if snapshot_tick` 闸，并在注释里钉死"禁止 60Hz"）。真正的卡顿根因改判为**世界包增量链**：v0.5.1 每包自包含，丢/迟到一包只损失该帧；P1.5 的 DELTA 依赖 `base_tick` 链，链断后客户端只能等 `BIT_NEED_FULL` → 服务器 FULL，等于每个丢包换来一次 RTT 级冻结。已用确定性模拟（90 包 FULL + 滚动关键帧 DELTA，服务端编码→客户端 `apply_world` 合并，逐字段比对）证明**无丢包时合并值与权威一致**，故"插值/合并算错"排除；**修法已落地（客户端乱序缓冲，协议零改动）**：`NetCodec.chain_state(base, applied)` 把"链状态"拆三态 —— `CHAIN_OK`（可直接应用）、`CHAIN_STALE`（迟到旧包，静默丢，不再误请求 FULL）、`CHAIN_GAP`（缺前序包，进 pending 缓冲）。`NetBus.snapshot_world/_own` 在应用成功后反复尝试 pending 里的包按序补链 ⇒ **乱序到达零冻结**；只有 pending 超上限（真丢包）才置 `need_full` 付一次 RTT。守卫：`net_wire_smoke` 7→8 条（三态语义）；真链路 `pvp_match_smoke SMOKE PASS`、`royale_soak ALL-OK(4/4)`。**仍未做**：真丢包下仍是一次 RTT 级 FULL（未做冗余基准/重复补丁），需 `--netstat` + 人为丢包专测。P1.5 把本人包从每 tick 降到每 `SNAPSHOT_STRIDE` tick（30Hz），C2 回滚的权威锚点间距随之翻倍：移动中每 33ms 才校正一次 ⇒ 本地角色手感发涩/微跳（用户实测报"快照变卡"）。省带宽的承诺由**差分**兑现（全量 94 B → 典型差分 36 B），不能靠降频；已恢复 `_flush_own_snapshots` 每物理 tick 发，全量仍按 role 每 60 tick 错峰。带宽读数同步：本人包 ≈2.22 KB/s/role，N=16 服务器上行 ≈89 KB/s（仍远低于 P1.5 前 295 KB/s）。

**修 2：爆炸给已摧毁子格重复播粒子**。`current_subgrid` 的纹理在摧毁后**不变**（摧毁只写 `sub_hp`），而 `Explosion.destructible_subs()` 只查纹理 ⇒ 爆炸会把已经被打碎的树叶/砖再算一遍：既重复播碎片，又重复 `TileHitFx.mark_hit` 去重。新增 `TileDefs.sub_hp_at()` 只读口，`destructible_subs` 跳过 `sub_hp<=0`（`sub_hp` 未初始化时保持旧行为，纯逻辑 -s 不受影响）。守卫：`tile_break_unit_smoke` 10→11 条（"已摧毁子格不进爆炸可破坏集"）。

**待查（未修）**：开局 3s 倒计时问题（用户报"有问题"，现象待确认）。已知实现链：服务器只在 COUNTDOWN 起点广播一次 `round_state(timer=3.0)`，客户端 `Broadcast.tick(delta)` 本地走秒、`countdown_finished` 收尾；`_round_timer` 在 `_match_round_tick` 每 tick 递减。此路径本轮未改过，需要先定位现象（不显示/数字错/能行动/时长错/卡住）再动。

## 二十、开局 3s 倒计时数字不对/跳秒（2026-10-28，档 3）

**根因**：对局宿主在两客户端 claim 完就建局并**立刻**广播 
ound_state(COUNTDOWN, timer=3.0)，而那一刻客户端还在切场景、PvpHud.local_round_state 尚无订阅方 ⇒ 这条 COUNTDOWN 被静默丢掉。之后服务器已经开始走 3s 时钟，客户端只能在 PLAYING 转变时收到一条状态 ⇒ 倒计时要么不显示、要么从中段开始（数字不对/跳秒）。

**修法（服务器侧就绪闸 + 补发，协议零改动）**：MatchRound 新增 mark_client_ready(role) / _countdown_can_start(delta)——COUNTDOWN 的时钟**等所有网络 peer 都发过 match_sync（客户端场景 _ready 才发）后才开始**（AI 补位不等；上限 COUNTDOWN_HOLD_MAX=2.0s 兜底，超时照常开局）。就绪闸放行那一 tick 再**补发一次** 
ound_state(COUNTDOWN, timer=3.0)，客户端 HUD 从 3 起走且与服务器时钟同拍。server_main._on_match_sync 里调 mark_client_ready；MatchHost._ready / _start_next_round 复位就绪闸与补发标志。

**边界（如实登记）**：① 只覆盖 1v1（MatchRound._match_round_tick）；RoyaleHost / TeamHost 整段覆写了 _match_round_tick，不走这道闸 —— 大乱斗本来就有 HUD_SYNC_INTERVAL 周期重播可兜底，3v3 的 COUNTDOWN 仍按旧时序（若同样症状再现，需在各自覆写里加同样的就绪闸）；② 只修"起点丢失"，不改变本地走秒精度（Broadcast.tick(delta)，与服务器时钟的长期漂移仍靠下一次状态广播校正）；③ 真链路 smoke 只验证收到 round_state + 能行动，**倒计时数字观感只能人眼**；④ 协议/字节不变，PROTO_VERSION 不动。


## 二十一、放弃增量快照 + 命中 X 搬回屏幕中心（2026-10-28，档 3）

**回退 1：放弃世界/本人包增量（P1.5 整体下线，保留编解码能力）**。`MatchSnapshot._broadcast_snapshot()` 恢复 `NetCodec.encode_world(state)` 全量、`send_own_snapshots()` 恢复 `encode_own(..., true)`；`NetBus.snapshot_world/_own` 恢复"解码即发"（`_last_world_tick/_last_own_tick` 去重，不再有 `base_tick` 链、pending 缓冲、need_full 请求位；`snapshot_need_full()` 恒 false）。`BIT_NEED_FULL` 位保留但不再置位。世界包尺寸回到 **N=16 约 536 B/包**（30Hz），本人包 **99 B/包**（30Hz，含 P1.5 引入的 `tick` 字段 4 B）；N=16 服务器上行回到 **≈305 KB/s**（放弃增量换稳定性）。`net_wire_smoke` 7 条（链三态断言随代码移除），默认批 **12 支 / 81 条**。
**为什么**：用户实测 v0.5.1（全量）不卡、P1.5（增量）对手显示一顿一顿；DELTA 链在 unreliable 乱序/丢包下即使加乱序缓冲，真丢包仍需 FULL，本质是拿稳定性换带宽，裁定不要。

**回退 2：命中 X 搬回屏幕中心**。`BulletBase._spawn_hit_fx()` 恢复 `CombatFeedback.hit_marker()`（屏幕中心 X）；`HitFeedbackFx` 只保留**伤害数字**（`spawn_damage`，世界系），不再画目标身上的 X；`PvpMatchClient._on_hit_confirm()` 恢复只调 `CombatFeedback.hit_marker()`。理由：X 的位置是既有用户口径，未经要求不得搬动（此前 P0-3 的"X 画在目标身上"被仓主否决）。
**边界**：增量编解码 `encode_world(..., full=false)` / `apply_world` / `own_full_phase` 仍保留并由 `net_wire_smoke`/`snapshot_size_probe` 覆盖（能力测试，不代表生产路径）；`PROTO_VERSION` 仍 6（线格式未变，只是生产只发 FULL）。命中伤害数字仍为纯表现、零守卫。


## 二十二、贴身回滚：幽灵体外推到"现在" + 动态贴身容差（2026-10-28，档 3）

**现象**：联机贴得越近越卡顿/回滚（追人时尤其）。
**根因**（两条叠加）：① 客户端预测撞的是幽灵体，旧实现幽灵体位置 = **最近一条权威快照**（滞后 ≈ 单程 + 0~33ms 发包间隔；700px/s ⇒ 23~46px，相向时翻倍），而服务器用自己此刻的位置裁决 ⇒ 一进接触区，"这一步撞不撞"两边就掷硬币；② 旧实现用本帧碰撞结果 `touching_player()` 判"是否贴身"，追人时幽灵滞后会让客户端预测**穿过去**、本帧根本没撞上 ⇒ 判不到贴身、仍走 2px 容差 ⇒ 每 30Hz 验证点回滚一次。固定 8px 贴身容差 < 23~46px 滞后，兜不住。
**修法**（纯客户端，协议/服务器零改动）：
1. `PlayerReplica` 记最新快照的权威 `vel`；`_process` 里幽灵体位置 = 快照 `pos + vel × horizon`（`PredictionContact.ghost_horizon_s(ping_ms)` = RTT/2 + 半个 30Hz 间隔，封顶 `MAX_LAG_S=0.05s`），锚回本地玩家最近副本。匀速期误差≈0，急停/变向最坏 ≈ 700×0.05=35px。
2. `PvpMatchClient._update_contact_state()`：遍历 `player_replica` 组，用本地 `hurt_rect()` 与外推后幽灵 `ghost_rect()` 的 **AABB 间隙**（环面锚定后）判贴身（`CONTACT_GAP=12px`），并令 `contact_pos_tol = clamp(8 + 相对速度 × horizon, 8, 48)`；`touching_player()` 保留为兜底。赋值位置仍在 `note_post_step` 之前（探针源码守卫已改为认新入口）。
**守卫**：新增 `tests/smoke/prediction_contact_smoke.gd`（7 条：AABB 间隙几何 / 滞后封顶 / 容差下限·线性·封顶 / 贴身边界）；`rollback_fidelity_probe` 的接线守卫改认 `_update_contact_state()`（原注释已要求"换入口就改这里"）；`allscript_probe.EXPECTED_SCRIPTS` 188→190（新增 2 个 `.gd`）。变异：`BASE_CONTACT_TOL 8→4` ⇒ 该支 `FAILED: 2 处`。
**验证**：`RUN_ALL OK(13 runs / 88 gated-assertions)`；真链路 `pvp_match_smoke SMOKE PASS`、`royale_soak SOAK: ALL-OK(4/4)`。
**边界**：① 外推只压"匀速"误差，急停/反向时幽灵体可能过冲到 35px（动态容差兜，但观感上仍可能有一两帧推挤感）；② 可见副本仍是 playout 50ms 延迟——"看到的位置"和"挡住你的身体"的时差没变；③ 容差上限 48px 是"不掩盖真分歧"的取舍，不是精确校准；④ 全是客户端量，服务器权威碰撞/伤害逻辑没动；⑤ 真实手感只能真链路 + 人眼（回滚计数可用 `--netstat` 观察）。


## 二十三、受击事件时刻对齐的边界（2026-10-28，档 3）

**改了什么**：`hit_event` 增加 `seq`（= 受击方**上一条完成步进**的输入记录，`MatchState._stepped_seq`；裁决在玩家子节点步进之前 ⇒ 不是当帧 ack）；客户端 `PredictionRollback.apply_external_event(seq, apply)` 恢复 `_captures[seq]` → 应用 → 重放 `(seq, last_applied]`，并把事件存进 `_events[seq]` 供之后任何回滚重放重新应用；`take_hit(..., feedback_only)` 给不可注入路径只播反馈；网络回调只入队、物理帧开头注入；**2026-10-29** 起 `take_hit`/`took_hit` 带 `cause`，溺水伤害标 `cause="water"`、服务端跳过其回声。文件：`server/match/match_state.gd`、`server/match/match_host.gd`、`server/match/match_combat.gd`、`server/server_main.gd`、`core/net/net_bus.gd`、`core/net/prediction_rollback.gd`、`scenes/pvp_match_client.gd`、`scenes/player/combat_component.gd`、`scenes/player/player.gd`。
**守卫**：`rollback_fidelity_probe` D 组（⑤–⑪、⑯–⑱：注入 / **真实服务器顺序**的黄金轨迹 / 越界 / 同 seq 双发 / 乱序 / 注入后 reconcile 对独立黄金权威 / 迟到旧 ack 重放带回事件 / 计数）+ E 组（⑭⑮：反馈-only、⑲⑳：`cause` 透传）+ 源码守卫 10 条（客户端 5：入队 / 物理帧消费 / `_physics_process` 接线 / 注入唯一 / 兜底第 5 参；服务器 3：`_stepped_seq` 锚点、帧末记录调度、记录写入；溺水 2：调用带 `cause="water"`、`_on_player_hit` 跳过 water）。变异各自红在指定断言：删 restore→⑧/⑩、删重放步进→⑧/⑩、删越界拒绝→⑪/⑯、删乱序拒绝→⑬、不刷新捕获→⑫、重放不重新应用事件→⑰/⑱、锚点改回 `_ack_seq`→服务器守卫、删帧末记录→服务器守卫、删溺水 cause→⑲/源码守卫、Player 不转发 cause→⑲、服务端不跳过 water→源码守卫；删 `feedback_only` 早退→⑭。
**边界（照实）**：
1. **没有自动化真链路命中守卫**：命中不可确定性构造（`pvp_match_smoke` 两端出生点相距远）⇒ 改 `hit_event` 参数只靠人眼与日志。兜底理由是"参数不符会当场报错"，不是静默形态。真链路读数靠 `royale_soak` 透传 `--netstat` 看 `事件对齐/拒绝` 计数。
2. **服务器输入饥饿**（队列空、沿用上一条 held）k tick 时，玩家状态比 `_stepped_seq` **前进 k 步** ⇒ 注入点早 k 步（近似，方向不保证；steady state 才精确）。
3. **落水窒息**伤害是客户端已本地预测的伤害（两端跑同一份 `_tick_underwater`）⇒ **2026-10-29 已修**：`take_hit(..., cause="water")` 从 `player.gd` 溺水调用一路带到 `took_hit` 信号，`MatchCombat._on_player_hit` 对 `cause == "water"` 直接返回（不广播 `hit_event`，也不进 dealt/taken 统计）。守卫：探针 ⑲⑳（cause 透传 / 普通伤害为空）+ 两条源码守卫（溺水调用带 cause、服务端跳过回声），三处变异各自红。
4. **`_captures` 环 256 tick（4.3s）**：ping / reliable 重传导致事件超出环时走兜底 ⇒ 该次受击没有本地击退（只有白闪 / 震屏 / 音效）。
5. **事件必须按 seq 递增到达**（reliable 保序）；seq 回退一律拒绝并兜底，不会静默丢事件。
6. **注入只能在物理帧做**：网络回调在 idle 帧，帧外 `move_and_slide()` 按**渲染帧 delta** 缩放（实测同一速度跨 idle 帧位移 0.01~2px 不等；首帧前才是 0）⇒ 事件先入队 `_pending_hit_events`、下一个物理帧开头注入 ⇒ 受击反馈（白闪/音效/击退）最多晚 1 帧（≈16.7ms）。重连重建 C2 时队列清空。
7. **注释额度**：本批新增注释让 `core/net/prediction_rollback.gd` / `server/match/match_combat.gd` 的整行注释占比超过 `comment-style.md` §8 的 15%（前者基线已 16.4%，后者 14.9%→15.6%）—— 未删，因为删掉的是"为什么/边界"；此处登记为已知超限，翻案 = 后续批把这两处解释性注释收敛成行内短注。
8. **新断言只有完成戳、没有逐条计数闸**（沿用 `rollback_fidelity_probe` 既有约定）：删掉单条 `_check` 不会红，只有整组中途报错（缺 `_require_ran` 戳）才红。`ALL-OK` 只证明"没有失败输出"，不证明每条断言都跑过 —— 权威表述见 `tests/lib/probe_base.gd` 文件头。




## 二十四、下行全 60Hz + playout 2 + 副本插值加平滑（2026-10-30，档 3）

**改了什么**：① 下行快照从「≤6 人 60Hz / >6 人 30Hz」改为**所有人数 60Hz**（`MatchState.SNAPSHOT_HZ = 60` / `SNAPSHOT_STRIDE = 1`）；② `LagComp.PLAYOUT_TICKS` 3→2（客户端渲染延迟与服务器命中回放同一常量）⇒ 画面滞后 ≈50ms→**≈33ms**；③ 副本插值升级：位置由线性改**三次 Hermite**（切线 = 快照 `vel` × 段时长）、`aim`/`vel` 连续量在相邻两条历史之间插值（离散态仍整条）、最新端（underrun）**有界外插**（≤2 tick / 60px）；④ `PredictionContact.ghost_horizon_s` 的「半个发包间隔」从 1/60 改 0.5/60（快照变 60Hz 后幽灵滞后上限按新间隔）；⑤ 冲刺残影/冲刺距离等纯表现改动不在本条。

**代价（照实登记）**：16 人局服务端上行从 ≈305 KB/s 升到 **≈610 KB/s**（≈4.9 Mbit/s，世界包 536B×16×60 + 本人包 99B×16×60）；`PLAYOUT_TICKS=2` 只有 1 包抖动余量，网络抖动/连丢 2 包时更依赖有界外插，可能看到轻微过冲再回拉。
**守卫/验证**：`run_all` 13 支全绿、真链路 soak 4 客户端（60Hz 路径）`SOAK: ALL-OK(4/4)`；插值的 Hermite/aim/外插行为只有临时探针验证，按「观感不写守卫」登记；命中回放深度与渲染延迟仍由 `lag_comp.gd` 单一常量保证同源。

## 二十五、联机模块全量审查（2026-10-30，只登记不修）

**做了什么**：对联机模块做了一次**只读**审查 —— `core/net/**`（16 支 / 3120 行）、`server/**`（24 支 / 6412 行）、客户端联机场景（9 支 / 3232 行）、联机文档 13 篇（1023 行）、联机守卫 18 支（6125 行），合计约 2 万行。产物：`docs/audit/2026-10-30-netplay/`（[00 总览与结论](../audit/2026-10-30-netplay/00-总览与结论.md) / [01 代码与注释审查](../audit/2026-10-30-netplay/01-代码与注释审查.md) / [02 bug 台账](../audit/2026-10-30-netplay/02-bug台账.md)）。基线 `326d586b`，**未改任何生产代码**。

**读数**：23 条行为缺陷（P1 × 5 / P2 × 12 / P3 × 6；其中 2 条为用户实机报）、27 条结构债、17 条注释问题、16 条文档漂移、5 条守卫盲区。旧 bughunt 报告（2026-10-22，`.superpowers/bughunt/REPORT.md`）的 17 条已逐条给复核状态（已修 3 / 仍在 3 / 未复核 11）。

**P1 清单**（详情、证据行号与修法见 02 台账）：
- `BUG-03` 重连补破坏态只补 64px 整格，16px 子格破坏全部漏补（旧报告 X6 的细化）⇒ 幻影墙 + 每帧回滚；
- `BUG-04` 回溯环缓不随换局复位（12s 环缓 > 7s 换局间隙）⇒ 可回放到上一局的帧（仅 Beta 时间玩法）；
- `BUG-05` 回溯记录 `downed` 但从不还原 ⇒ 回放到死亡帧得到「0 血且未倒地」的非法态（仅 Beta）；
- `BUG-06` 「重启本机服务器」的端口属主探测对 UDP 失明（`netstat` 行只有 4 列，判据写 `>= 5`）⇒ 残留进程清不掉、就绪轮询恒不成立；
- `BUG-01` / `BUG-02` 用户实机报的两条（每把枪械的子弹数量不独立 / 结算页 MVP 总是标给败方）。**`BUG-02` 已修**（2026-10-30，见 §二十六：根因是口径 —— MVP 只看 ACS、与胜负脱钩；用户裁定「全场最佳必须出自胜方」）；`BUG-01` 仍未定位，02 里给了候选机制与定位计划，**不建议在拿到现场证据前动代码**。

**本轮不修的理由**：本条是登记条目，不是修复批次；修复顺序、档位、验收判据、要跑的测试见 00 §4 与 02 §4（★ 跑测试前先列清单问用户）。

**修后必须同步**（否则二次漂移）：`docs/eng/netplay.md`（P1.5/30Hz 残留）、`netplay-rpc-channels.md`（61 条 / 通道 3 少 explosion）、`netcode-snapshots.md`（滚动关键帧/DELTA 已下线）、`netcode-at-16-players.md` 与 `netcode-delta-and-quantization-details.md`（trail「<1 B/点」算错、536 B 把 trail 2 点当典型）、`room-lifecycle-conventions.md`（I2 1v1 宽限写反）；守卫：`net_wire_smoke` / `snapshot_size_probe`（差分半套删除或量化后条数闸与容差都要改）。

## 二十六、联机 B1 批修复（2026-10-30，档 1~2）

**起因**：联机模块全量审查（见 §二十五 / `docs/audit/2026-10-30-netplay/`）后用户指令「开做」，并裁定「MVP 是明明赢了、全场最佳却是对面」= **bug**。

**改了什么**（8 条，详见 [02-bug台账 §6](../audit/2026-10-30-netplay/02-bug台账.md)）：
1. `BUG-02` MVP 归属：新增纯函数 `ScoreRules.pick_mvp(stats, candidates)`（ACS → 击杀 → 阵亡 → role 升序；**先收第一个候选**，修掉旧 `best_acs := -1.0` 在全员负 ACS 时返回 0=没有 ★ 的边界）；`MatchState.mvp_role(candidates)` 改为折表调用；1v1 传 `[胜者 role]`、3v3 传 `_roles_of_team(胜队)`，平局/候选全失配回落全 roster。**根因是口径不是取反**：旧实现只按 ACS 挑、与胜负脱钩，而 1v1 局内比分可以极端（赢的局 5-4、输的局 0-5）⇒ 败方总 kills 更多、deaths 更少 ⇒ ACS 反超。
2. `BUG-06` 端口属主探测：`ProcUtil` 新增 `pids_on_udp_port` / `_pid_of_udp_line` / `_addr_has_port`（**UDP 行只有 4 列**、端口按冒号后整段解析）；`local_server` 的残留清理/就绪轮询改调它，删 `_pids_on_port`。
3. `BUG-11` 1v1 `claim_role` 越界判据：`server_main._on_role_claimed` 去掉 `(_royale or _team_mode) and` 前缀。
4. `BUG-13` 回溯残像停摆：`pvp_match_client` 按"新旧 trail 重叠段之后的点"判新点（线上长度饱和在 `TRAIL_WIRE_MAX`，旧"数组变长"判据会停摆）。
5. `BUG-15` `--port` 校验：`ModeContext._parse_port`（非法 token / 缺值 / 越界一律拒绝启动）。
6. `BUG-16` `ProcUtil.kill_udp_port` 捕获 PowerShell 输出并 print（"不是我们一族就不杀"的警告原来不可见）。
7. `BUG-17` `NetCodec.encode_world` 循环封顶 200，与 `resize` 预算对齐。
8. `BUG-19`（泄漏面）残影过期即 `queue_free`、淡出按 `CanvasItem`、子类 `_remove_replica` 先收残影再 free 副本。

**守卫（能答「去掉什么才红」）**：
- `tests/smoke/mvp_choice_smoke.gd`（6 条 + `EXPECTED_CHECKS`）：①不限队仍取 ACS 最高（旧口径回归）；②候选=[胜者] 必须给胜者；③3v3 候选=胜队时必须只在胜队内挑；④不限队仍取全场最高（证明候选参数是唯一开关）；⑤完全并列 → 最小 role 且与插入顺序无关；⑥全员负 ACS 仍给出 MVP。去掉什么才红：删 `candidates` 过滤 ⇒ ②；`pick_mvp` 回退恒全表 ⇒ ②；删 `pool.sort()`/改并列规则 ⇒ ⑤；把首收逻辑改回 `best_acs := -1.0` ⇒ ⑥。
- `tests/smoke/net_argv_port_smoke.gd`（5 条 + `EXPECTED_CHECKS`）：UDP 4 列解析、TCP/对端不误命中、`:17777` 不当前缀、`--port` 非法/缺值/越界拒绝、合法 8123 进 ctx。去掉什么才红：列数判据改回 `>= 5` ⇒ ①；删 `cols[0] != "UDP"` ⇒ ②；`_addr_has_port` 改回 `contains(":"+port)` ⇒ ③；`_parse_port` 换回 `int()` ⇒ ④；`_parse_port` 不写 `ctx["port"]` ⇒ ⑤。
- `allscript_probe` 条数闸 190 → **192**（两支新 smoke）。

**验证（本机 headless；未占 7777、未弹窗）**：`mvp_choice_smoke` `MVP CHOICE OK(6 条断言)` · `net_argv_port_smoke` `NET ARGV OK(5 条断言)` · `net_wire_smoke` `NET WIRE OK(7 条断言)` · `snapshot_size_probe` `SNAPSHOT SIZE PROBE: ALL-OK` · `allscript_probe` `ALLSCRIPT: OK(192 个脚本全部加载)` · `python tools/check_naming.py` `命名检查 OK`。

**边界（照实）**：
1. **真链路批未跑**（`pvp_match_smoke` / `rejoin_probe` / `team_match_probe` / `royale_soak`：占 7777/端口池、拉子进程）—— 按 AGENTS §1 等用户认领。
2. **`BUG-20`（加速重影节拍器共享单例）未修**；观感类（残像/淡出）无自动断言，只能人眼。
3. `BUG-11` / `BUG-13` / `BUG-16` / `BUG-17` 四条修复**没有专属自动断言**（接线/观感/诊断/潜在越界），已在台账登记。
4. MVP 口径变了 ⇒ 3v3 的 MVP **只会出自胜队**；平局（`match_winner == 0`）退回全场 ACS 最高。这是裁定，不是遗漏。
5. 本轮改动**未提交**（git 未 add/commit）；新加两支 smoke 的 `.gd.uid` 已由 `--headless --import` 生成。


## 二十七、删除 `pvp_room_smoke`（2026-10-30）—— 删了什么 = 欠了什么

> 依据：[`docs/audit/2026-10-30-联机验证审计.md`](../audit/2026-10-30-联机验证审计.md) §1.1（A1）。本轮只删测试资产，**未改任何产品代码**。

**现象（代码路径级确定性，不需复现）**：该支自 2026-10-24（1v1 改为房主点「开始游戏」）起**结构性恒红** —— `pvp_smoke_client.gd`（harness/）从不发 `pvp_start`（`pairing_ready` 全仓唯一发射点在 `pvp_start` 内），`match_start` 判词不可达；30s 轮询超时后 `wait $A_PID/$B_PID` **永久阻塞**，只能靠 `run_real.sh` 的 `timeout 1200` 强杀 ⇒ `.sh` 的 kill 收尾行永远跑不到 ⇒ 大厅 + 2 客户端成孤儿 ⇒ 闸三 FAIL 并 **break** ⇒ 真链路批条目 3~6（rejoin / soak / role_cap / team_match）整批不跑。它违反本仓自述的「一条永远红的闸等于没有闸」，且此前从未登记。

**改了什么**：
- 删 `pvp_room_smoke.sh`（smoke/）+ `pvp_smoke_client.gd` / `.gd.uid` / `.tscn`（harness/）；
- `tests/run_real.sh` 的 `ENTRIES` 删行（6 → 5）+ `tests/README.md` 的清单 / 计数 / harness 列表同步；
- `allscript_probe.EXPECTED_SCRIPTS` 192 → **191**（编译面少一个 `.gd`）；
- `docs/eng/netplay.md` / `docs/eng/room-lifecycle-conventions.md` / `docs/pvp-networking.md` 的引用同步。

**留下的覆盖缺口（如实登记，不新增也不减少原有缺口）**：
1. **不受影响的**：1v1 建房 → 房主开始 → 对局 仍由 `pvp_match_smoke.sh` 覆盖（它的 create 端在 2/2 且自己是房主时代按 `pvp_start`；join 端按码加入走同一支）—— 这是删它的主要依据。
2. **原本就没有的**：房间回收梯（端口归还 / 超龄房收掉 / worker 退出）**任何真链路都不断言**（审查 G-03）—— 本条不新增该缺口，但请别把「删了一支真链路」误读成「覆盖变少」：那支从未真正覆盖到这里。
3. **确实失去的**：真链路里「房间列表 UI 路径」（列表 → 点行加入）与「claim 后收不到 `match_start` 的客户端表现」不再有人看（`pvp_match` 有 600 帧自超时兜底）。

**验证**：`bash tests/run_real.sh --list`（闸四：ENTRIES 每条匹配真实文件、无遗留 `.sh` 未登记）· `python tools/check_naming.py`（规则 C：文档引用路径存在）· `git status --short`（四个文件 staged 删除）。**真链路批未跑**（占 7777，按 AGENTS §1 等用户认领）。

**翻案条件**：需要真链路覆盖「房间列表 UI 路径」或「claim 后无 `match_start` 的客户端行为」时重写一支 —— 必须带**客户端自超时**与**可达判词**，且不得占用批内前序支的清理窗口。


## 二十八、下行丢包估计 + 打包服务端默认日志（2026-10-30，档 2）

> 用户指令：「有没有性能分析的 log（延迟/丢包/回滚）」→ 补丢包度量；「以后打包服务端都要有生成 log 的功能（默认同目录建立 log 文件夹然后往里面写文件）」。

**改了什么**：
1. **下行丢包估计**（新文件 [`core/net/net_metrics.gd`](../../core/net/net_metrics.gd)，纯静态、`-s` 可测）：世界包 / 本人包走 unreliable、每快照 tick 一包且包内带 `tick` ⇒ 相邻两包 tick 差 > 学到的步长即记丢包。`NetBus` 里两本累计账（`_rx_world_lost` / `_rx_own_lost`），`--netstat` 每秒一行新增 `世界包 rx/丢/≈%`、`本人包 rx/丢/≈%`；`--diag` 的 `snap_rx` 每秒一条新增 `world_lost / world_loss_pct / own_lost / own_loss_pct / step`。计数**始终在跑**（几行整数），只有日志是默认关。
2. **打包服务端默认日志**：`NetDiag.enabled()` 追加「导出构建（`OS.has_feature("template")`）里的服务端默认开」；`NetDiag.log_dir()` 走 `NetMetrics.server_log_dir`（导出服务端 = **exe 同目录 `log/`**，其余 = `user://logs`）；diag 与 ops 两个文件都落该目录，worker 的引擎日志 `worker_<port>.log` 同目录（`worker_launcher.log_path` 改调 `NetDiag.log_dir()`，不再自判）；`server_main` 启动即打「日志目录: …」并落 `server_boot`；服务端写 diag 每行 flush（worker 可能被强杀，最后几条最值钱）。
3. **打包侧断言**：[`tools/build_release.py`](../../tools/build_release.py) 的服务端产物冒烟加 `require_log_dir=True` —— 跑完 exe 同目录必须出现非空 `log/`，否则发布脚本红。`start_server.bat` 加 `mkdir log` + 引擎 `--log-file "%~dp0log\server_console.log"`（控制台输出另存）。
4. **守卫**：新 `tests/smoke/net_metrics_smoke.gd`（9 条 + `EXPECTED_CHECKS`，tick 缺口口径 / 步长折算 / 首包与乱序 / 丢包率分母 / 日志目录四组合）；`allscript_probe.EXPECTED_SCRIPTS` 191 → **193**。

**边界（照实）**：
1. 丢包是**估计**不是链路真值：迟到/乱序包（旧 tick）不计丢也不更新基线；重连/换局靠 `reset_snapshot_state()` 清基线（不清会把纪元跳变记成一笔假丢包）。**真实丢包分布未做人为丢包专测**（要真链路 + 网络损伤工具）。
2. 上行输入丢包仍只有间接读数（`input_intake` 的队列丢弃），没有 seq 缺口统计。
3. `NetMetrics` 的纯函数面有两处**接线**不在该冒烟里（`NetBus` 调用点、`NetDiag.log_dir` 调用点）：接线断了冒烟不会红，只有真链路 `--netstat` 读数或打包冒烟能发现 —— `build_release.py` 的 `require_log_dir` 正是后者的自动化。
4. 导出构建的服务端日志目录**未在本机实测**（本轮只跑了 headless 开发态与纯逻辑冒烟；导出模板冒烟要跑完整 `build_release.py`）—— 首次真跑发布时请确认 `log/` 真的出现在 exe 旁。
5. 引擎级 `--log-file` 只覆盖由 `start_server.bat` 启动的进程；直接双击 exe 时控制台输出不落盘（NetDiag 的结构化日志仍落盘）。
6. 客户端导出构建不强制日志（`--diag` 仍 opt-in），日志仍去 `user://logs`。

## 二十九、联机 B2 批修复（2026-10-30，档 1~2）

**起因**：B1 批之后用户指令「继续修 bug」，按审查台账 `docs/audit/2026-10-30-netplay/` 的 B2/B3 段做客户端接线与回滚环。

**改了什么**（6 条，详见 [02-bug台账 §6](../audit/2026-10-30-netplay/02-bug台账.md)）：
1. `BUG-08` 回滚环泄漏：`PredictionRollback.note_post_step()` 的淘汰循环补 `_inputs.erase(old)` —— 生产路径（`pvp_match_client._physics_process`）走的是 `note_post_step` + `note_input`，旧代码只有 `advance()` 那条会清 `_inputs` ⇒ ack 断流（重连中/本人包停摆）时 `_inputs` 以 60 份/秒无界增长。
2. `BUG-18` 大厅假 claim 梯：`lobby_page.gd` 的转连 worker 一次性回调收成具名 `Callable`（`_claim_connected` / `_worker_fail`），`_bind_worker_once` / `_unbind_worker_once` 成对；`_do_go_match` 绑定，`_return_to_lobby` **先解绑**。旧写法（匿名 lambda + `CONNECT_ONE_SHOT` + 无解绑）在 worker 连不上回大厅后，大厅一连上仍会跑 `_claim_role_worker` ⇒ 向大厅 peer 发 `claim_role/player_options/report_token` 并起 25s claim 梯，把玩家从大厅弹走。
3. `BUG-20` 加速重影节拍器：`TimeFx._fx_other_t`(S-19 后;原在 `pvp_match_client`)从单 float 改 **per-副本 `Dictionary`**，递减改用调用链传下来的**物理 delta**（原为 `get_process_delta_time()`，在物理 delta 链里 ⇒ 帧率相关）；`_time_fx_replica_off` 里 `erase`。旧写法 k 个加速者每帧被减 k 次 ⇒ 触发 ≈ k/0.06 对/秒（16 人 ≈500 张 AfterImage/s）。
4. `BUG-21` 断线判定：局内从 `msg.contains("断开")` 文本子串改为 `multiplayer.server_disconnected` 直连 `_on_hard_disconnect`；`_on_server_message` 只留播报。旧判据把任何含"断开"的服务器播报当断线（`NetBus.stop()` 掐活连接），文案一改则重连静默失效。
5. `BUG-22` 权威爆炸 cull：`_on_network_explosion` 先判 `want != null` 再回收视觉弹 —— 对手副本未建时旧代码用 `b.shooter != null` 匹配，会把**别人的**榴弹 `queue_free()`（提前消失/双爆）。
6. `BUG-23` 3v3 尸体血条：`team_game.gd` 补 `visible = not downed`（与 `royale_game.gd:125` / `pvp_game.gd:118` 同口径；3v3 原漏）。

**守卫（能答「去掉什么才红」）**：
- 新增 `tests/smoke/prediction_rollback_ring_smoke.gd`（3 条 + `EXPECTED_CHECKS`）：①`note_post_step` 淘汰后 `_inputs.size() <= KEEP`；②最新 seq 仍在环里；③最老 seq 已被清。**变异验证**：删掉 `_inputs.erase(old)` 那行 ⇒ ①②③ 里两处红（`_inputs.size()=500`、`has(0)==true`），还原 ⇒ `ROLLBACK RING OK(3 条断言)`。
- `allscript_probe` 条数闸 193→**194**（+新冒烟）；`tests/README.md` 的"现有带 `EXPECTED_CHECKS` 的支"清单与默认批读数同批校正为 **17 支 / 111 条闸断言**（原来那份清单已滞后：net_wire 5→7、snapshot_size 5→9、tile_break 10→11 且漏 4 支）。

**验证（本机 headless；未占 7777、未弹窗）**：`ROLLBACK RING OK(3 条断言)` · `ALLSCRIPT: OK(194 个脚本全部加载)` · `python tools/check_naming.py` 绿。

**边界（照实）**：
1. **真链路批未跑**（`pvp_match_smoke` / `rejoin_probe` / `team_match_probe` / `royale_soak`：占 7777/端口池、拉子进程）—— 按 AGENTS §1 等用户认领。
2. `BUG-18/20/21/22/23` 五条**没有专属自动断言**（连接接线 / 观感 / 视觉），只能人眼验收；已在台账逐条登记"无自动断言"。
3. `BUG-20` 只修了"共享递减 + idle delta"两处；重影本身的观感（0.06s 一对）仍需人眼。
4. 本轮改动**未提交**（工作树 `M` 4 个源文件 + `M tests/probe/allscript_probe.gd` + `M tests/README.md` + 新增冒烟与 `.gd.uid`）。

## 三十、联机 B3 批修复：BUG-01 残弹独立性（2026-10-30，档 2）

**起因**：用户实机报「每把枪械的子弹数量不独立」；前轮把三条候选（同帧切枪窗口 / C2 条目滞后 / 拾取复用 inst）都核过未定案，本轮用真 `player.tscn` 探针复现并定位。

**根因（已定位）**：`WeaponComponent._equip_index()` 切枪时会把旧枪 `mag_ammo` 写回 `inventory.held[_current_index]`；但两处调用点**在调用前已经把条目换掉了**，写回于是落到**另一把枪**的条目上：
1. `pick_up()` 的「背包满 ⇒ 替换手上那把」：先写新条目、再 `_equip_index` ⇒ 旧枪实弹覆盖新条目 ⇒ 新枪 `pending_mag` = 旧枪残弹（地面那件的残弹被丢弃）。**这就是"背包满捡枪，新枪子弹跟着上一把走"**。
2. `random_keep_one()`（倒地随机保留一把）：不 flush 当前枪条目（条目陈旧 = 少扣刚打的发数），且 `held` 替换成 1 条后仍调默认 flush 的 `_equip_index(0)` ⇒ 旧枪实弹覆盖保留条目；掉落的当前枪带陈旧条目值。

**改了什么**（`scenes/player/weapon_component.gd`，档 2）：
- `_equip_index(index, flush_current: bool = true)`：新增开关；两个重建路径调用点传 `false`。默认行为不变。
- `pick_up()` 替换分支：`_equip_index(_current_index, false)`（旧枪实弹已由 `_last_dropped` 带走）。
- `random_keep_one()`：替换 `held` 前先 `_flush_current_mag()`；替换后 `_equip_index(0, false)`。

**守卫**：新增 `tests/probe/gun_ammo_independence_probe.gd` + `.tscn`（8 条 + `EXPECTED_CHECKS`；真 `player.tscn`，不碰网络/端口）：
① 背包满拾取替换 → 新枪残弹取地面值；② 新枪条目残弹也是地面值；③ 被换下那把带自己实弹；④ 随机保留项条目正确；
⑤ 倒地掉落的当前枪带真实实弹（不是条目陈旧值）；⑥ 对照：背包没满的拾取路径不变。
**变异验证（三条，逐条改坏 → 红 → 还原 → 绿）**：`pick_up` 改回默认 flush ⇒ ①②红；`random_keep_one` 去掉 flush ⇒ ⑤红；`random_keep_one` 改回默认 flush ⇒ ④红。
未修状态的红色原文已抄进 `docs/audit/2026-10-30-netplay/02-bug台账.md` 的 BUG-01 段。

**验证（本机 headless；未占 7777、未弹窗）**：`KH gun_ammo_independence PROBE: ALL-OK` · `ALLSCRIPT: OK(195 个脚本全部加载)`（条数闸 194→195）· `python tools/check_naming.py` 绿。`tests/README.md` 默认批读数同步 **18 支 / 119 条闸断言**（+`gun_ammo_independence_probe`(8)）。

**边界（照实）**：
1. **同帧多次切枪窗口**（一条旧枪在 `call_deferred` 未入树时被切走 ⇒ 不写回）未改：它保证"不把 0 写回"，与本次两条重建路径无关；真机可达但需同帧两次切枪事件，留 `_mag_ready` 抓手登记为后续项。
2. `restore_inventory`（回滚重建）后调用方 `equip_index` 会**瞬时**把旧实例实弹写进恢复条目；紧随的 `apply_mag(st["mag"])` 纠正、下帧 capture 再 flush ⇒ 自愈，未改。
3. 原候选 2（C2 `inv` 条目滞后）与候选 4（`pickup_sync` 缺 `mag` 默认 0）与本 bug 无关，仍可能独立成立，保留登记。
4. 本轮改动**未提交**（工作树含 B2 批未提交改动 + 本批）。

## 三十一、联机 B4 协议批：v7（DELTA 删除 + trail 定点化 + 版本握手，2026-10-30，档 3）

**起因**：审查台账 B4 批（`docs/audit/2026-10-30-netplay/01-代码与注释审查.md` S-01 / S-22 / BUG-07）。**两端必须同版发布。**

**改了什么**（`core/net/net_codec.gd` 由 922 行重写为 ~620 行）：
1. **S-01 删差分半套**：`PROTO_VERSION 6→7`。删除 `encode_world(full,prev,keyframes)` / `encode_own(full,prev)` 的 DELTA 分支、`apply_world` / `apply_own`、`_enc_value` / `_unit_equal` / `_deep_equal` / `_delta_mask` / `_write_masked_fields` / `_write_unit_value` / `_read_unit_into` / `_read_masked_fields` / `_own_unit_at` / `_own_unit_count`、`own_full_phase` / `world_keyframe_quota`、`OWN_FULL_PERIOD` / `WORLD_KF_PERIOD` / `W_MASK_ALL`。解码侧 `flags` 必须恰为 FULL（其它值一律拒绝）；`decode_world` / `decode_own` 返回形状收窄为 `{tick,players}` / `{ack_seq,q,tick,c2}`。
2. **S-22 trail 定点化**：`trail` 从 2×float32 改 **2×i16（Q_SCALE=0.5px 步长）**，与 pos/vel 同精度；世界条目 33→**25 B**、最坏世界包 791→**536 B**、N=16 常态包（trail 2 点）536→**408 B**。
3. **BUG-07 版本握手**：`NetBus.claim_role(role, name, proto)` / `NetBusExt.reclaim_role(role, token, proto)` 带 `PROTO_VERSION`；`server_main._proto_matches()` 在 claim/reclaim 入口校验，不符则**回一条用户可见的 `server_message` 并踢连接**（旧行为只剩每条包一条 push_error、比赛照开、画面静默冻结）。客户端两处（大厅 claim / 对局重连 reclaim）+ 两支测试客户端同步。

**守卫（承重断言逐条变异验证）**：
- `net_wire_smoke`：7→**5** 条（删 ⑤本人包差分 / ⑥世界包 keyframe+差分；trail 往返加 ≤0.25 容差）。
- `snapshot_size_probe`：9→**5** 条（删 ⑥~⑨ 差分/相位断言；`_t_bytes(T_TRAIL)` 改 1+4n；删 `_report_change_rate` / `_mask_bytes`；trail 往返容差同款）。读数：条目 **25 B**、最坏包 **536 B**、本人包 99 B。
- `allscript_probe`：`EXPECTED_SCRIPTS` 195 不变（无新增脚本）；全批 `RUN_ALL OK(18 runs / 113 gated-assertions)`。
- 变异验证（本批承重面 = 线格式；三条**实测**逐条改坏 → 红 → 还原 → 绿）：
  ① trail 量化步长错（`roundi(px * Q_SCALE)` 改成 `roundi(px * 1.0)`，误差 0.5 > 容差 0.25）⇒ `net_wire_smoke` ③ 红（`NET WIRE FAILED: 1 处`），还原后 `NET WIRE OK(5 条断言)`；
  ② 容量预算少算（`_schema_bytes` 的 T_TRAIL 从 `1+4n` 改 `1+2n`）⇒ `snapshot_size_probe` ④ 红（`FAIL ["最坏世界包必须能逐字段解码回来…"]`），还原后 `SNAPSHOT SIZE PROBE: ALL-OK`；
  ③ flags 判据删除（`decode_world`/`decode_own` 的 `!= FULL` 守卫整段拿去）⇒ `net_wire_smoke` ② 红（flags 字节改坏后仍被当合法包解出），还原后 `NET WIRE OK(5 条断言)`。

**验证（本机 headless；默认批不占 7777、不弹窗）**：
- `bash tests/run_all.sh` ⇒ `RUN_ALL OK(18 runs / 113 gated-assertions)`，18 支全 OK（net_wire 5 / snapshot_size 5 / allscript 195 / gun_ammo 8 / rollback ring 3 …）。
- `net_wire_smoke` readout：输入 42 B、世界 2 人 50 B、本人包 99 B；`SNAPSHOT SIZE PROBE: ALL-OK`（条目 25 B、最坏 536 B）。
- `python tools/check_naming.py` 绿（见随后终验）。

**边界（照实）**：
1. **真链路批未跑**（`pvp_match_smoke` / `rejoin_probe` / `team_match_probe` / `royale_soak`：占 7777/端口池、拉子进程）—— 档 3 要求真链路跑批，按 AGENTS §1 等用户认领；本批的"两端同版"只由版本字节与握手守门，跨进程未见真包。
2. 旧客户端（v6）连 v7 worker：claim 参数不匹配 ⇒ RPC 调用失败；v7 客户端连 v6 worker：worker 侧 `_on_role_claimed` 收不到 proto 参数 ⇒ 同样失败。方向正确（大声失败），但**未做跨版本矩阵测试**（发布纪律 = 两端必须同包，登记为边界）。
3. `flags` 字节保留（恒 FULL）以不动头部布局；将来若要重新引入"多形态"再定义位，现在**不许按位读**。
4. `snapshot_size_probe` 的每秒折算列按 `SNAP_HZ=60`；输出/带宽数字见 `netcode-at-16-players.md` §1（N=16 ≈487 KB/s trail 2 点 / ≈364 KB/s 空 trail）。
5. 本轮改动**未提交**（工作树含 B2/B3 批未提交改动 + 本批）。

## 三十二、榴弹 32px 破坏单位 + BUG-03 重连补子格（2026-10-30，档 3）

**起因**：① 用户裁定「榴弹应该是最多破坏到 32px 而不是 16px」；② 审查台账 BUG-03（P1）：重连补破坏态只补"整格已消失"，16px 子格破坏全漏 ⇒ 幽灵墙。

**改了什么**：
1. **爆炸/直击分三档**（`core/sim/explosion.gd` / `scenes/weapons/bullet_base.gd` / `core/sim/tile_defs.gd`）：
   `tile_break_unit >= 1.0` → 整 64px 格；`>= 0.5` → **32px 块**（2×2 子格，`TileDefs.damage_block32` 收口，块内 4 子格按**同一伤害**结算 ⇒ 洞边对齐 32px）；`< 0.5` → 逐 16px 子格。`grenade_bullet.tscn` 的 `tile_break_unit` **0.25 → 0.5**。
   爆炸碎片改为按**破坏单位**播（新 `Explosion.destructible_units`：16/32/64px 单位聚合、顺序确定、`d` 取单位内最近子格）⇒ 榴弹一块一簇，不再一块 4 簇。
2. **BUG-03 补态**：新增纯逻辑 `core/sim/tile_resync.gd`（`TileResync.partial_damaged_subs`）—— 只报「所在 64px 格仍与基线相同」的死子格（整格已消失的由 `destroyed_cells()` 展开，不重复发），顺序确定；`MatchState.damaged_partial_subs()` 委托它；`server_main._on_match_sync` 在载荷加 `destroyed_subs`（空数组不带键）；`pvp_match_client._on_match_sync` 在应用 `destroyed` 之后逐子格静默补（复用 `_on_remote_sub_destroyed(sub, true)`，不另写清瓦片/清碰撞逻辑）。

**守卫（逐条变异验证）**：
- `tile_break_unit_smoke`（11 条，口径改 32px）：① 边界（0.25/0.5 都走子格路径）；② 场景值 `tile_break_unit = 0.5`；④ `damage_block32` 一次清 2×2 子格、格级账不动；⑨ 爆炸 0.5：**块内 4 子格同生共死**（`_block_uniform`）、死亡子格数 = 4×块数、格级账只在整格全灭时归 0。
  变异：榴弹场景回 0.25 ⇒ ② 红；爆炸 `>= 0.5` 分派失效（改 `>=0.75`）⇒ ⑨ 红。
- 新增 `resync_substate_smoke`（5 条 + 条数闸）：① 部分破坏子格必进列表；② 整格已消失的不重复发；③ 未破坏不发；④ 顺序确定（打乱插入顺序仍 (y,x) 升序、两次逐位相同）；⑤ 全是整格消失时列表为空（无假阳性）。
  变异：删「格仍与基线相同」过滤 ⇒ ①②③⑤ 红（实测 4 处）；删 `sort_custom` ⇒ ④ 红。
- `allscript_probe` 条数闸 195→**197**（+`tile_resync.gd` +`resync_substate_smoke.gd`）。

**验证（本机 headless；默认批不占 7777、不弹窗）**：`TILE BREAK UNIT OK(11 条断言)` · `RESYNC SUBSTATE OK(5 条断言)` · `ALLSCRIPT: OK(197 个脚本全部加载)` · `RUN_ALL OK(19 runs / 118 gated-assertions)`。

**边界（照实）**：
1. **真链路未跑**（v7 + 本批的 `match_sync` 载荷变化要跨进程验证：`pvp_match_smoke` / `rejoin_probe`）—— 按 AGENTS §1 等用户认领。
2. 客户端 `_on_remote_sub_destroyed(sub, true)` 在真 Level0 上的效果（贴图/碰撞块重建）无人眼验收；只由代码路径与既有链保证。
3. 16px 子格 **HP 被磨低但没死**的状态不进补态（外观/碰撞都不变，客户端无需知道）；若将来客户端要显示"受损砖"需要另加字段。
4. 32px 块内 4 个子格的纹理可能不同（树叶+树干混块）：破坏按块统一结算（爆炸 AoE 语义），碎片取块内最近子格的纹理 —— 观感边界。
5. 本批改动**未提交**（工作树含 B2/B3/B4 未提交改动 + 本批）。

## 三十三、联机 B5/B6 收尾批：BUG-04/05/09/10/12/14（2026-10-30，档 2~3；**台账 23 条全部修完**）

**起因**：用户「继续下所有」—— 收掉审查台账剩下的 6 条。

**改了什么**：
1. **BUG-04**（回溯环跨局，档 3，`match_host.gd`/`match_round.gd`）：新增 `MatchHost.reset_time_rewind_state()` —— 清 `_rw_buf/_rw_cursor/_rw_snap_t/_rw_t0/_rw_trail`，并对换局瞬间正处于回溯态的 role 解冻 `src.frozen=false` + `remove_meta("time_rewinding")`（否则下一局该玩家输入源永冻）；`MatchRound._reset_world_and_clear_dynamics()` 在**早退之前**动态调用它（`has_method`，base 类不持子类表）。环深 12s vs 换局间隙 7s 的漏洞关闭。
2. **BUG-05**（回溯不还原 downed，档 3，`match_host._apply_rw_frame`）：补 `combat.set_downed_by_rewind(bool(f["downed"]))`（该方法刻意不扣血/不发 went_down，与单机 `Player.rewind_restore` 同款）⇒ 不再出现"hp=0 且未倒地"的非法态。
3. **BUG-09**（ai_duel 摘房即还端口，档 3，`lobby_rooms.gd`/`worker_launcher.gd`/`room_manager.gd`）：新增拆除形态 `TEARDOWN_ADOPT`：房摘除但端口**继续占着**，`WorkerLauncher.adopt_orphan()` 记孤儿 pid，`RoomManager._process` 每 tick `reap_orphans()` 在进程退出后归还。旧写法走 DELAYED（120s 后无条件 release）⇒ 面板显示空闲、pid 被抹、回收梯看不见这场局。
4. **BUG-10**（同步 PowerShell 冻主线程，档 2，`proc_util.gd`/`worker_launcher.gd`/`lobby_rooms.gd`）：`kill_udp_port` 拆出阻塞核心 `_kill_udp_port_blocking`；新增 `kill_udp_port_async`（后台 `Thread`，主线程 `reap_kill_threads()` 收尸）；`kill_worker` 改走异步。★ 连带把 `TEARDOWN_KILL` 的"杀完立刻 release"改成**延迟归还**——杀已是异步的，立刻 release 可能在旧进程未死时把同端口发给新 worker（串线），延迟三档远大于一次 PowerShell 耗时。
5. **BUG-12**（ai_duel 不通知 guest，档 2，`room_manager.ai_duel`）：房内 `players.size() > 1` 直接拒绝并回 `server_message`（不再摘房后把 guest 留在已消失的等待室）。
6. **BUG-14**（回局凭据无模式，档 3，`rejoin_registry.gd`/`room_registry.gd`/`lobby_rooms.gd`/`net_bus_ext.gd`/`lobby_page.gd`/`room_manager.gd`）：凭据加 `mode`；`decision`/`owns` 都按（房间号，**模式**）判；`_grant_rejoin(..., mode)` 四处调用点各传 `ModeDefs.MODE_*`；`rejoin_request` RPC 带 `mode`（NetBusExt 扩展协议，两端同版）。跨模式同号房的泄漏与误放行都关闭。

**守卫**：
- 新增 `tests/smoke/rejoin_mode_smoke.gd`（4 条 + 条数闸）：① 凭据带 mode、同模式放行；② 同号跨模式拒绝；③ `owns` 按（房间号，模式）过滤列表；④ 同模式下 worker 死 / 房号不符 / TTL 过期三条原判据不回归。
  **变异验证（三条实测）**：去掉 decision 的 mode 比较 ⇒ ② 红；去掉 owns 的 mode 比较 ⇒ ③ 红；grant 不存 mode ⇒ ①③④ 红；还原后 `REJOIN MODE OK(4 条断言)`。
- `tools/room_sweep_lint.gd` 的 ⑥ 号检查随 B1 的越界守卫修正同步更新（旧断言期待的是已被修掉的 `((_royale or _team_mode) and ...)` 前缀；现断言裸 `not _role_set.has(role)` 且不许旧前缀复活）⇒ `SMOKE_ROOM_SWEEP OK(10 项检查)`。
- `allscript_probe` 条数闸 197→**198**（+`rejoin_mode_smoke.gd`）。

**验证（本机 headless；默认批不占 7777、不弹窗）**：`REJOIN MODE OK(4)` · `TILE BREAK UNIT OK(11)` · `RESYNC SUBSTATE OK(5)` · `ALLSCRIPT: OK(198 个脚本)` · `SMOKE_ROOM_SWEEP OK` · `RUN_ALL OK(20 runs / 122 gated-assertions)`。

**边界（照实）**：
1. **BUG-04/05/09/10/12 无自动断言**：服务器 Beta 回溯 / 大厅生命周期都没有可实例化的探针地基（`MatchHost` 要真地图与 autoload；`WorkerLauncher` 引 `NetDiag` ⇒ `-s` 编不过）。BUG-09/10 由 `room_sweep_lint` 守结构，行为只能真链路 + 人眼。★ 这 5 条**未做变异验证**（无断言可变异）。
2. **真链路批未跑**：v7 线格式、`match_sync` 补态、大厅拆除/cert 改动都要跨进程验（`pvp_match_smoke`/`rejoin_probe`/`team_match_probe`/`royale_soak`，占 7777）—— 等用户认领。
3. BUG-09 的孤儿梯只按 pid 存活判归还：AI worker 若**僵死**（进程活着但不退），端口会一直占着（旧实现更糟：120s 后端口被复用而 worker 还在）；2h 超龄清扫看不到已摘除的房 ⇒ 无兜底，登记为已知边界。
4. BUG-10 的"not ours 不杀"警告仍会被 PowerShell 打出（在后台线程里），但顺序/时间戳与主线程日志可能交错；线程收尸在大厅 tick 里做，退出前未收的线程由引擎等待。
5. 本轮改动**未提交**（工作树累计 B2~B6 全部未提交）。

## 三十四、B8 文档/注释批 + BUG-24「打完房间不回收」（2026-10-30，档 1~2 + 一条承重修复）

**起因**：① 用户「开始 B8 文档」= 01 的 `DD-*`(文档漂移) / `CM-*`(注释漂移) 批；② 用户现场问「打完了房间没有回收是什么原因」。

**BUG-24（新登记，用户实报）—— 打完不回收的根因与修法**：
- **根因**：`MatchRound._match_round_tick` 的 `MATCH_OVER` 分支是 `pass`（"等玩家退出/服务器关房"）⇒ **worker 对局结束后不主动退**；
  而大厅回收梯 `_reclaim_finished_matches` 的唯一判据是 `_match_over(port,pid) = not pid_alive(pid)` ⇒ **只要客户端还连在 worker 上（结算页赖着不退 / 迟退），房与端口就一直占着**；
  唯一兜底是 `_sweep_stale_rooms` 的 **2h 超龄**（对 1v1 是裸 `MAX_ROOM_AGE`）。
- **修法**：`MatchRound` 暴露 `is_match_over()`；`server_main._process` 给 worker 加**终局滞留**：`MATCH_OVER` 起 `MATCH_OVER_LINGER = 60s`，到点无论客户端在不在都 `quit(0)` 收场（先让结算数据早已送达；客户端 `_match_ended` 已置位，断开不会触发重连）。房/端口随后由回收梯 ≤30s 收掉。
- **边界**：① 真链路未跑（需一局打到 MATCH_OVER 并观察 ≤90s 内房消失）；② 60s 是否合适属产品口径，可调；③ 无自动断言（worker 生命周期无 `-s` 地基）。

**B8 文档/注释批（逐条真改，不只是标状态）**：
- **CM（代码注释/常量）**：`CM-01/02/06`（P1.5 差分口径 + mask u16/u32）随 v7 重写 `net_codec.gd` 不复存在；`CM-03` `net_bus` 注释改为陈述"NetBusExt 仍有同名副本(待删)"；`CM-04` `DemoInputSource`→`LocalInputSource`；`CM-05` `net_diag` 区分 `log_event()`(默认关) 与 `audit()`(常开)；`CM-07` 三处 8→16；`CM-08` `rr.match_time` 存的是建房页那份(缺省 0，下界)；`CM-09` 键必须是字符串(客户端 `room_list.gd` 读 "1"/"2"/"0")；`CM-10` `server_panel` 状态颜色表改用 `ServerStatus.STATE_*` 常量；`CM-11` 去掉 `ui.md:27` 行号(两处)；`CM-12` 外部读者清单补 `snapshot_size_probe`/`wait_room`；`CM-13` 已随 BUG-16 修(输出已捕获)；`CM-14` 46→42 B；`CM-15` 1s 渐隐已随 BUG-19 修(注释补记)；`CM-16` 两个子类→三个子类(6 处)；`CM-17` 去掉恒真条件 `(_haste_dim_t>0.001 or pp!=null)` → `_haste_dim_t>0.001`（**行为侧**:不再每帧无条件写 uniform，观感需人眼）。
- **DD（文档）**：`DD-01` RPC 合计 **60**（`net_bus` 28 + `net_bus_ext` 32；通道 3 = 10，46/1/3/**10**）—— 2026-10-30 时写的 61/33/11 是 S-04 删 `net_bus_ext.beam_fired` 死副本**之前**的数；2026-10-31 S-02 起由 `tools/gen_rpc_channel_table.py --check` 对账（见 §四十一）。`DD-02` "一条记录管 2 tick"→"一包两条记录、每条 1 tick"（3 处文档）；`DD-07` 1v1 超龄是**裸** `MAX_ROOM_AGE`（无在局宽限）；`DD-13/04` `pvp-networking` 世界包改 v7 全量口径；`DD-14` `_input_pair_phase`→`_input_batch_phase`；其余 `DD-03/05/06/08/09/10/11/12/15/16` 已在前几批随 v7/BUG 修同步。

**验证**：`RUN_ALL OK(20 runs / 122 gated-assertions)`（B8 只改注释/文档 + BUG-24 的 server_main 代码；解析由 allscript 198 覆盖）· `allscript_probe 198` · `check_naming` 绿 · md 链接 0 缺失。

**边界**：`S-04`（删 `net_bus_ext.beam_fired` 副本）、`S-25~S-27`（文档结构重构）、`G-01~G-05`（守卫缺口）本轮**不做**，保留登记；本轮改动**未提交**。

## 三十五、大重构第一刀：S-13① 面板日志 tail 抽出（2026-10-30，档 2）

**起因**：用户「先做大重构」—— 先做 01 审查里的大结构项，从风险最低、且有纯逻辑可测价值的一段开始。

**改了什么**：
- 新增 `server/gui/panel_log_tail.gd`（`PanelLogTail`，RefCounted）：面板日志的**增量读 / 半行不消费 / 文件轮转归零 / 超上限从头部按行边界截断**全部收进纯逻辑；`max_chars` 单一来源。
- `server_panel.gd` 删掉 `_log_off/_log_buf` 与整段 `_append_log_delta` 实现，改为委托 `_log_tail.read_delta()`；跟随/暂停与滚动位置（I1/I2）**留在 UI 侧不动**，`LOG_MAX_CHARS` 变成 `PanelLogTail.DEFAULT_MAX_CHARS` 的别名（单一来源）。
- 新增守卫 `tests/smoke/panel_log_tail_smoke.gd`（6 条 + 条数闸）：① 首次读全量；② 半行不消费（offset 不前进）；③ 补全后只吐新增；④ 重建归零 + rotated；⑤ 超上限切在行边界（首行不能半截）；⑥ reset 后重读。
  **变异验证（三条实测）**：把 `nl<0` 的早退去掉（半行被消费）⇒ ② 红；删 rotated 归零 ⇒ ④ 红；删行边界切分 ⇒ ⑤ 红；还原后 `PANEL LOG TAIL OK(6 条断言)`。
- `allscript_probe` 条数闸 198→**200**（+两个 .gd）；默认批 20→**21 支 / 128 条闸断言**。

**边界**：
1. UI 侧的跟随/暂停与滚动位置**仍无断言**（I1/I2 语义，只能人眼）；本次只保证 tail 的纯逻辑。
2. `S-13②`（`_audit*` 搬进独立的审计工具，**尚未创建**）、`S-13③`（关房二次确认保留 3 行）未做。
3. 其余大重构未动，计划顺序：`S-09`(lobby_rooms 拆) → `S-10/S-11/S-12`(死规则/死字段/房主名单单一来源) → `S-18`(replica_set) → `S-17`(pvp_match_client 两刀) → `S-03/S-05`(net_bus/packet_input_source)。承重面项需真链路批验收。（**2026-10-31：该清单已全部完成，见 §四十一**。）
4. 本轮改动**未提交**。

## 三十六、大重构第二刀：S-10 / S-11 / S-12（去重复真相源，2026-10-30，档 2）

- **S-10**：`core/mp/mode_room_rules.gd` 的 8 个规则函数（`min_players` / `max_players` / `team_size` / `needs_teams` / `start_allowed` / `degraded_start_allowed` / `visible_in_match` / `freeze_roster`）全仓**零调用点**，已删（只留 `port_return_seconds`，它唯一被 `room_registry.port_return_delay` 调用）；`LobbyRooms` 的三个上限常量改为 `ModeDefs` 的别名（`ROYALE_MAX_PLAYERS := ModeDefs.ROLE_MAX`、`TEAM_SIZE := ModeDefs.TEAM_SIZE`、`TEAM_ROLES := ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT`）⇒ 两处真相合成一处，漂移类缺陷结构性消失（无需再补盯漂移的守卫）。
- **S-11**：删 `RoomTypes.Room.options` 只写不读死字段 + 唯一写点（`royale_create` 里那三行）;真正的对局选项一直走 `player_options → _claim_opts → MatchHost`。
- **S-12**：新增 `ServerStatus.host_and_roster(...)`（纯函数）作为「房主 + 名单」的唯一判据（1v1 = players[0] / 局中退回冻结名单第一条；大乱斗·3v3 = host_peer + role）；`RoomRegistry.list_payload` 与 `LobbyRooms.host_name_of` 改为只搬字段。新增 `tests/smoke/room_view_smoke.gd`（4 条：4 种组合）。
  **变异验证（两条实测）**：`is_duel` 分支对调 ⇒ 4 处红；`roster_of` 局中不读冻结名单 ⇒ ②④红；还原后 `ROOM VIEW OK(4 条断言)`。

**验证**：`ALLSCRIPT: OK(201)` · `RUN_ALL OK(22 runs / 132 gated-assertions)`（见本轮终验）· 命名/链接检查绿。

**边界**：`S-09`（lobby_rooms 拆分）、`S-13②③`、`S-18`/`S-17`/`S-03`/`S-05` 仍未做；本轮改动**未提交**。（**2026-10-31：S-03/S-05 已完成，见 §四十一。**）

## 三十七、真链路批首跑结果 + BUG-25（测试基建，2026-10-30）

**结果（本机，用户认领后 `run_real.sh --yes`；环境 7777/池内全空、无 godot 残留）**：

| 支 | 首跑（串行全批） | 干净环境单跑 |
|---|---|---|
| `pvp_match_smoke` | FAIL（join 端 `bullet_spawn=false`） | **PASS**（`SMOKE PASS`，24s） |
| `royale_soak_probe` | FAIL（`Couldn't create an ENet host` err=20） | **PASS**（`SOAK: ALL-OK(4/4)`，134s） |
| `royale_role_cap_probe` | FAIL（同上 err=20） | **PASS**（`ROLE CAP PROBE: ALL-OK(9/9)`，119s） |
| `team_match_probe` | **OK**（`TEAM MATCH PROBE: ALL-OK`，203s） | — |
| `rejoin_probe` | FAIL（`房 8677 一直没配对 players=2 port=0`） | 未再跑：**已知红**（2026-10-24 起，见 §一） |

⇒ **v7 线格式 / claim 握手 / 快照 / 输入 / `match_sync` 补态 / 大厅建房配对在真跨进程链路上已被验证**（4 支 PASS）。

**BUG-25（新登记，P2，测试基建，未修）—— 串行真链路批会被"上一支的残留"连累**：
- 现象：全批首跑时 `pvp_match_smoke` FAIL 后，**两个 `server_main.tscn` 大厅进程仍占着 7777**（`Get-CimInstance` 实测：一个 console 版 + 一个 exe 版）；随后两支 soak 直接 `Couldn't create an ENet host err=20` 假 FAIL。清掉残留后单跑 → 三支全 PASS。
- 根因方向：`pvp_match_smoke.sh` 的 `kill_procs $SERVER_PID ...` 在 Git Bash/MSYS 下不可靠（脚本自己注释过），`kill_port`/`kill_port_range` 只覆盖 7777 与 worker 池的组合，未覆盖"console/exe 两种 Godot 同时起大厅"的情形；`run_real.sh` 只在整批开始做 `lobby_alive` 闸、不在 entry 之间清扫 7777。
- **根因（已定位并修）**：测试基建的清理原语按 **Git Bash/MSYS** 写（`netstat -ano` / `taskkill`）；从 **WSL bash** 调用时它们是 Linux 版/不存在 ⇒ `lobby_alive` 恒 false、`kill_*` 全静默 no-op、闸三的 `tasklist|grep godot` 恒 0。**修法**：`tests/env.sh` / `tests/run_real.sh` 加 WSL 分支（走 `powershell.exe`/`taskkill.exe` 互操作），并新增 `kill_lobby_by_cmdline`（按命令行清 `server_main.tscn`），接入 `pvp_match_smoke.sh` 全部收尾路径与 `run_real.sh` 每支 entry 尾部 + EXIT trap。
- **验证**：修后单跑 `pvp_match_smoke` PASS 且跑后 `7777 空闲 / 无 godot`；三份 shell `bash -n` 全过。
- ★ 同批修掉 `rejoin_probe` 的**已知红**：根因 = 2026-10-24 起 1v1 改由房主点「开始游戏」，而探针的 `rejoin_watcher` 走生产入口却没人点 ⇒ 房永远 `players=2 port=0`。修法 = c1 以 1s 节拍代发同一 `pvp_start` RPC（1 人时服务器会拒，重试到进局为止）。修后 `REJOIN PROBE: ALL-OK(5)`。

**全批复跑(修 BUG-25 后)**:`pvp_match_smoke` OK · `rejoin_probe` **OK(5)**(已知红已修)· `royale_soak` OK(4/4) · `royale_role_cap` OK(9/9) · `team_match_probe` FAIL(c1 观察到 MATCH_OVER;c2~c6 的引擎日志显示它们**都在跑**(相位=5、t≈673s、比分 1:5/2:9)——是机器人把比赛打完了,而相⑤还在等自杀/离场 ⇒ 该支的既有边界「3v3 不可当可信端到端守卫」(§一)复现,不是崩溃/协议回归;改进方向 = 相⑤ 前暂停或降低 bot 攻击性,属探针设计,不在本轮范围)。★ 全批**无 gate3 失败、无残留连累**(BUG-25 修法生效)。

## 三十八、大重构第三刀：S-09 第一片（3v3 纯判据迁入 RoomTypes，2026-10-30，档 2）

**触发**：用户「提交后继续」——按剩余清单开 S-09（`lobby_rooms.gd` 787 行职责超载）。

**改了什么（第一片）**：
- `LobbyRooms` 里那组 3v3 纯判据（`team_ready` / `team_can_join` / `team_next_role` / `_by_team` / `team_room_ready` / `room_registry.team_counts_of`）全部迁进 `RoomTypes.static`（纯 RefCounted，只依赖 `ModeDefs`）。
  ★ 关键事实：原注释自称「静态:-s 可测」，但宿主 `LobbyRooms` 是 Node 且引 `NetBus` ⇒ **那句断言根本不成立**；迁进 `RoomTypes` 后才真的可被 `-s` 驱动。
- `LobbyRooms.team_room_ready()` 保留为**对外公开口**（`RoomManager.team_start` 与 `team_match_probe` 调），体内只委托 `RoomTypes.team_room_ready`；`lobby_rooms` 内部的两处调用点改为 `RoomTypes.*`。
- `room_registry` 的 `team_counts_of` 删除本地实现，改调 `RoomTypes.team_counts_of`（字符串键协议口径原样）。
- `wait_room.gd` 注释同步（`LobbyRooms.team_ready` → `RoomTypes.team_ready`）。

**守卫**：`room_view_smoke` 4→**7 条**（新增 ⑤`by_team` 分组 ⑥`team_ready` 只认 3+3(4v2 不算)⑦最小空闲号/可加入/三档人数字符串键）。默认批 132→**135 条闸断言**。
**验证**：`ROOM VIEW OK(7 条断言)` · `SMOKE_ROOM_SWEEP OK(10 项检查)` · `ALLSCRIPT: OK(201)` · `RUN_ALL OK(22 runs / 135 gated-assertions)`。

**后续三片（同日完成）**：
- ② `RejoinRegistry.new_token()`（令牌本属凭据表）与 `NetBus.is_peer_online()`（判据 = `has_multiplayer_peer() and is_peer_live()`）：`lobby_rooms` / `room_manager` 的全部调用点改过去。
- ③ 面板读模型（`host_name_of` / `room_for_panel` / `display_roster_of`）→ `LobbySnapshot.host_of / room_for_panel / roster_of`（只搬字段；`LobbyRooms` 新增只读公开口 `peer_names` / `registry`）；`server_panel` 调用点跟改。
- ④ 三份 `_flush_{royale,pvp,team}_state` → 新 `server/lobby/wait_room_broadcast.gd`（`WaitRoomBroadcast.flush_*`，**保留** `call_deferred` + `await process_frame` 的时序约定与发送前再判开局）；`_release_port_later` → `WorkerLauncher.release_port_later(host, launcher, port, delay)`（本类仍 RefCounted，由大厅传 host 拿 SceneTree 定时器）；`room_sweep_lint` 的模式列表改为 `WorkerLauncher.release_port_later(`，白名单去掉 `_release_port_later`。
- **结果**：`lobby_rooms.gd` 787 → **650 行**（审查目标 ≤400 未完全达到：剩余主体是 RPC handler 与拆除收口本身，再拆要动协议面/房间生命周期，属下一轮，已登记）。`SMOKE_ROOM_SWEEP OK(10 项)`。

## 三十九、大重构第四/五刀 + B 组守卫（S-18 / S-17 / G-01·G-02·G-04·G-05，2026-10-30，档 2~3）

**S-18（副本集合与快照消费去重）**：新增 `scenes/mp_client/replica_set.gd`（134 行，`ReplicaSet`，组合件 `bind(client, replicas, tint_of, on_created)`；API `ensure/remove/apply_world_snapshot/ensure_label/refresh_labels/follow`）。`royale_game.gd` 285→**201**、`team_game.gd` 372→**291**。逐字保留：`ReplicaP%d` 节点名、BUG-23 的 `visible = not downed`、BUG-19 的「先 `_time_fx_replica_rewind_off` 再 free」、tick 闸与 `_last_snap_tick` 写回、昵称兜底；`_replicas` 字段留在宿主（`team_match_watcher` 直读它）。
**S-17（pvp_match_client 两刀）**：新增 `core/net/input_uplink.gd`（125 行；`begin_tick/submit/take_packet/accept_ack/reset_epoch/netstat_tick`）与 `scenes/mp_client/reconnect_driver.gd`（192 行；`bind/subscribe/recheck_disconnect/begin/retry/cancel/abort/on_resumed/on_exit_tree`）。宿主 1154→**942**。硬约束逐字保留：`seq` 只在 `reset_epoch` 归零、`winst` 每 tick 读一次即清、`_prev_tick_rec` 30Hz 两记录一包、ack 纪元、netstat 窗口、重试预算 2000/5000ms。三条信号改挂 RefCounted 驱动（宿主强持）。
**B 组守卫**：
- G-02 `tests/smoke/grace_dispatch_smoke.gd`（6 条，含 `expired()` 边界与 role 升序）+ 变异：`expire_action` 分派对调 ⇒ ①②③ 红。★ 附带发现：只对调两个常量的**值**不会红（断言比的是符号常量），已写进守卫注释。
- G-01 `core/net/reclaim_rules.gd`（`reject_reason` + `token_matches`）+ `server_main._on_reclaim` 改为「4 布尔 → 纯函数」，三拒绝分支/文案/踢人逐字等价；`reclaim_rules_smoke` 5 条；变异：删 `role_in_grace` 分支 ⇒ ③红、`token_matches` 恒 true ⇒ ④红。
- G-04 `pvp_match_smoke.gd`：`_last_snap_tick` 记真实快照 tick，`"st"` 与 `pack_pair` 第 4 参都传它（原注释「给 0 即可」已过期）。
- G-05 `rollback_fidelity_probe.gd`：实测 33 条后补 `EXPECTED_CHECKS=33` + 计数打印（同配置两次稳定）；变异：删一个 `_check` ⇒ 条数闸红。`team_match_probe.MIN_CHECKS` 未动（需真链路实测）。
- 同步：`EXPECTED_SCRIPTS` 201→**208**、`tests/README.md` 清单/总数、`check_naming` 绿。

**验证（默认批）**：`GRACE DISPATCH OK(6)` · `RECLAIM RULES OK(5)` · `[fid] checks = 33` · `ALLSCRIPT: OK(208)` · `RUN_ALL OK(24 runs / 179 gated-assertions)`。

**边界**：
1. G-01 的行为面（踢人 / 换输入源 / `_ack_seq`/`_stepped_seq` 复位 / match_start 应答）与 G-02 的到点真动作（移出对局 / `quit(0)`）仍需真 worker 探针；本轮只把**判据**变可测。
2. G-04 只到「真链路 smoke 传入真实 `st`」；回放窗口注入的两个断言未做。
3. S-17 的三条信号改挂 RefCounted 驱动（宿主强持），等价性靠生命周期论证 + 真链路 smoke；真断线时刻的 reclaim 路径未单独实测。
4. 同日后又完成：S-13②③、S-05、S-14、S-16、S-19、S-21（见 §四十）。仍**未做**：S-03（net_bus 三职）、S-15（卡点见 §四十）。（**2026-10-31：S-03 / S-15 均已完成，见 §四十一**。）
5. 本轮改动**未提交**（提交在收口时由 Lead 逐文件点名）。

## 四十、大重构第六刀：S-13②③ / S-05 / S-14 / S-16 / S-19 / S-21（2026-10-30，档 2~3）

**S-13②③**：`server_panel.gd` 的设计期仪器（`--panel-audit` 的 INSET 打印）→ 新 `server/gui/panel_inset_audit.gd`（`PanelInsetAudit.requested()/run(root)`，等 3 帧版式落定再量）；面板只留开关一行，890→**826 行**。S-13③ 复核：关房二次确认已走 `ServerStatus.can_close`（三行调用已在），无需改。★ 2026-10-31：该文件原先放在 `tools/`，而导出预设排除 `tools/*` ⇒ 服务端 exe 解析 `PanelInsetAudit` 失败（见 §四十二）；已挪回 `server/gui/`。
**S-05**：`packet_input_source.gd` 的**纯打包/常量**（`BIT_*`×10、`TICKS_PER_RECORD`、`INPUT_BATCH_TICKS`、`pack_record/pack_pair/unpack_pair`）→ 新 `core/net/input_wire.gd`（119 行，`InputWire` 全 static）；原文件 277→187，保留队列/边沿/latch 语义 + **同名转发壳**（调用点 6 处不越界）。逐字性：对 HEAD 做顶层单位切分 49/49 归类、0 UNCLASSIFIED；`net_wire_smoke` 仍 `42 B/包`、`NET WIRE OK(5)`、`INPUT QUEUE OK(4)`。**6 条变异实测**（清单位表/记录数/包级 seq/位定义/边沿累积/winst 帧末清），并暴露两个真缺口：`net_wire` 不钉"包级 seq=高 tick"、`input_queue` 对 `apply_packet` 边沿累积/winst 清零零覆盖（登记待补）。
**S-14**：`_role_of(node)->int`（查不到 `-1`）成唯一判据；`_role_of_node` 与 `match_combat` 两段内联循环收编；`match_combat.gd:93` 的 `== 0` → `< 0`（"无效 role 直接返回"的安全阀首次真正生效，且可证与旧行为等价）；`_record_down`/`_on_player_hit` 首部加 `role < 0` 防御。12 个调用点全核。变异：改名漏改 ⇒ allscript 12 条 `LOAD[FAIL]` 点名（说明默认批只能抓"接线漏"、抓不到哨兵语义）。
**S-16**：`MatchRound._round_state_base()`（5 共有键 + MATCH_OVER 的 `match_winner` + 非空 `stats`）落在 MatchRound 而非 MatchState（子类符号编译期不可见）；三模式 `_broadcast_round_state` 改 base + 各自追加；**键集/键值逐字一致**，仅 Dictionary 插入序变化（消费方全按键读）。变异：删 `"state"` 默认批 0 新红 ⇒ 该键集的守卫在真链路 watcher（`team_match_watcher` 的 ROUND_STATE_TIMEOUT）。
**S-19**：`TimeFx`（185 行，`bind/tick/detach`）承接 `_rw_film_mats/_rw_ghosts/_fx_self_t/_fx_other_t` 与 ~160 行视效；宿主 942→**798**，只留 `_ensure_time_fx()` / `_tick_time_fx()` / `_time_fx_replica_rewind_off()`（名字保留，S-18 的 `ReplicaSet.remove()` 按名调）。`detach` 比旧实现更严：`rewind_off` 后额外清 `_fx_other_t` 键。1v1 空集合 no-op 实测。
**S-21**：`HEAD_OFFSET`/`HP_BAR_OFFSET`/`follow()` 单一来源 = `ui/factory/world_label.gd`（`class_name WorldLabel`）；跟随下沉 `player_replica.attach_overhead`（幂等、失效自动摘）；三宿主删本地常量、只留调用；`replica_set.gd` 的血条偏移也改成引用同一常量。
**S-15 ⛔ 未做（按纪律主动停手）**：三条前置可观测断言（1v1 结算 kills 与记分条同数 / 大乱斗无归因死亡不记 kills / 3v3 队友误炸→对方队 +1 且无人记 kills）全仓都不存在；且"相位统一为只在 PLAYING 记账"本身是行为变更（1v1/3v3 在 ROUND_OVER 4s 窗口内仍记账）⇒ 抽模板必然在记分归属上二选一。按"重构前先绿，不绿不动"停手。另记：3v3 每次倒地调 `_attributed_killer(p)` 两次（team_host.gd:138/:145），抽模板会合并成一次（幂等等价）。（**2026-10-31 已做：三条判据以 `tests/probe/down_edge_probe.tscn` 落地并在重构前原样跑绿，相位与广播时机逐字保留、未做"统一为只在 PLAYING 记账"的行为变更；见 §四十一**。）

**验证**：`ALLSCRIPT: OK(211)` · `RUN_ALL OK(24 runs / 179 gated-assertions)` · `NET WIRE OK(5)` / `INPUT QUEUE OK(4)` / `ROLLBACK FIDELITY PROBE: ALL-OK`（33 条闸）· 命名检查 OK。
**边界**：
1. 默认批**不实例化** MatchHost/RoyaleHost/TeamHost ⇒ S-14 哨兵语义、S-16 键集在默认批零覆盖，只能真链路（`team_match_probe`/`royale_soak`）与 watcher 断言。
2. S-05 暴露的两个守卫缺口**已补**（2026-10-30 同日）：`net_wire_smoke` 5→6（包级 `seq/ct` 必须取高 tick 记录）、`input_queue_smoke` 4→6（`apply_packet` 边沿按位累积/`winst>0` 覆盖、`clear_edges` 连切枪一起清）；三条变异实测红、还原后绿。默认批 179→**182 条**。
3. S-19/S-21 的观感项（残影/重影/标签跟随）只能人眼；1v1 标签跟随比旧实现少滞后 1 帧（≤16.7ms）。
4. `--panel-audit` 仪器本身需要非 headless 面板实例才能跑，属设计期工具、无自动断言。
5. 仍**未做**：S-03（net_bus 三职）、S-15（卡点如上）、S-06（`_close_enough` 比对集）、S-07/S-02 生成式通道表。（**2026-10-31：这五项全部完成，见 §四十一**。）

## 四十一、S 批收尾：S-03 / S-06 / S-07 / S-02 / S-15（2026-10-31，档 2~3）

**起因**：用户「完成登记未做的所有联机部分优化任务，就是 S03 那些」= 01 审查 §3 落地顺序里剩下的结构项（§四十-5 那条清单 + §三十六-4 的计划顺序）。本批把 **01 审查里所有"建议做"的 S 项**全部落地；S-04 的 `beam_fired` 副本（已由 5dd1e1d1 删除）、S-08（不建议动）、S-25~S-27（文档结构重构，保留登记）不变。

**改了什么**：
1. **S-03（档 3）net_bus 三职拆分**：新增 [`core/net/snapshot_rx.gd`](../../core/net/snapshot_rx.gd)（`SnapshotRx`，RefCounted，不引 autoload）承接「解码 → tick 去重 → 坏包只警告一次 → tick 缺口丢包估计 → 1Hz 诊断窗口」；`net_bus.gd` 的入口只留 `accept_* + emit`（`send_input` / `snapshot_world` / `snapshot_own` / `reset_snapshot_state` / `snap_stats`），RPC 方法表与通道号仍独占 `net_bus.gd`（协议面不搬）。emit 形状逐字不变（`{tick, players}` / `{ack_seq, q, c2}`）。
2. **S-06（档 3）`_close_enough` 比对集单一来源**：`PredictionRollback.PREDICTED_FIELDS` + `_within(field, a, b)` 分派；位置容差仍是"接触与否二选一"（未简化）。`rollback_fidelity_probe` 33→**34**（㉑ = 表里每个键都出现在真 `capture_state()` 里）。
3. **S-07（档 2）LAN IP 发现拆出**：新增 [`core/net/lan_ip.gd`](../../core/net/lan_ip.gd)（`LanIp`）；`local_server.gd` 214→**93 行**，只留同名转发壳，调用点（`server_main` / `lobby_page` / `mp_lobby`）零改动；纯解析拆成 `parse_default_routes` / `parse_ip_file_line` / `rank_private` 三个静态函数 + `lan_ip_smoke` 5 条。
4. **S-02（皮 + 工具）通道表改生成式**：新增 [`tools/gen_rpc_channel_table.py`](../../tools/gen_rpc_channel_table.py)（`--check` 只读对账，漂移 exit 1；`--self-test`；`--write` 幂等但**本沙箱写不进 `docs/eng`**）；`docs/eng/netplay-rpc-channels.md` 按代码同步。**真值 = 60 条（`net_bus` 28 + `net_bus_ext` 32）/ 通道 46-1-3-10** —— 审计里的 61/33/11 是 S-04 删 `beam_fired` 副本之前的数，工具第一次跑抓到的正是这条真漂移。**不要按 61 改回文档**（那会让 `--check` 永久红）。
5. **S-15（档 3）倒地边沿模板方法**：`MatchRound._on_down_edge(role)` + 两个虚函数 `_down_killer_of(role)` / `_award_down(victim_role, killer_role)`；三个宿主各覆写两份差异。**相位与广播时机逐字保留**（1v1/3v3 在 `_round_state` 判断之外、大乱斗关在 `PLAYING` 里；1v1 只在 `scorer != 0` 广播、大乱斗无条件、3v3 在 `scorer != 0`）；**未做** 01 审查提的"相位统一成只在 PLAYING 记账"（那是行为变更，本批不碰）。新增 `tests/probe/down_edge_probe.tscn`（3 条）= 01 审查 S-15 要求的"重构前必须先绿"的三条可观测判据。

**守卫（逐条变异实测，红→还原→绿）**：
- `snapshot_rx_smoke`（7 条 + 条数闸）：① 同 tick 幂等；② 旧包丢弃；③ 坏包只警告一次（世界/本人共用快照旗 + 输入旗独立）；④ `reset()` 后旧 tick 重新接受；⑤ tick 缺口估计 + 步长学习；⑥ 本人包返回形状；⑦ `take_diag()` 键集 = 旧 `snap_rx` 的 8 键。
  变异实测：删 `tick <= _last_world_tick` 去重 ⇒ ①②④红；`warn_snapshot_once` 恒 true ⇒ ③红；`reset()` 漏清两条 tick ⇒ ④红；`snapshot_loss` 首参用错（`tick,tick`）⇒ ⑤红（lost=0 step=3）；`world_msgs` 键改名 ⇒ ⑦红。
- `rollback_fidelity_probe` ㉑：`PREDICTED_FIELDS` 的 `vel`→`velocity` ⇒ ㉑ + ①/④/⑩红；`_within` 的 pos 分支恒 true ⇒ ②③⑰红。
- `lan_ip_smoke`（5 条）：metric 排序方向反转 / 删同网卡去重 / 去掉"先 strip 再截分隔符" 各红一次。
- `down_edge_probe`（3 条）：删 1v1 `_scores` 自增 ⇒ ①红（记分条 0 / 结算 kills 5）；`RoyaleHost._down_killer_of` 改回对手 ⇒ ②红（kills=1、记分 {2:1}）；`TeamHost._award_down` 用 `team_of(killer)` ⇒ ③红（对方队 0）。
  ★ **重构前先绿的验证**：把三处内联代码临时复原成重构前原样（各模式自己的 drop/record/score/广播）跑 `down_edge_probe` = `ALL-OK`，再还原成模板 ⇒ 同一支仍 `ALL-OK`（抽取前后三条判据都绿）。
- `tools/gen_rpc_channel_table.py --check`：文档合计 60→61 ⇒ 红（1 项）；删一条 `@rpc` 声明 ⇒ 红（8 项）；`--self-test` 绿。

**验证（本机 headless；默认批不占 7777、不弹窗）**：本会话沙箱里 `bash tests/run_all.sh` 起不来（Git Bash 的 signal pipe 被沙箱拒绝），故按 `run_all.sh` 的同一枚举口径**逐支手跑**：**27 支全绿 / 0 红**（smoke/*.gd 排除 `pvp_match_smoke.gd` + probe/*.tscn 排除三支真链路 + probe/*.gd 无同名 tscn），`ALLSCRIPT: OK(216)`，闸断言合计 **198**（= 各支 `EXPECTED_CHECKS` 求和，含 `rollback_fidelity_probe` 34），`tools/gen_rpc_channel_table.py --check` = `OK(60 条 / 46/1/3/10)`，`--self-test` 绿，`python tools/check_naming.py` 绿。
★ 手跑环境：`APPDATA` 指向工作区内 `.tmp/appdata`（否则引擎写 `user://` 被沙箱拒绝 ⇒ 启动即 signal 11；`panel_log_tail_smoke` 这类真写 `user://` 的支会被误判红）。
**真链路批（用户认领后跑，Git Bash，占 7777/池/池外端口）**：`RUN_REAL FAIL(ok=4 fail=1)` —— `pvp_match_smoke` OK（`SMOKE PASS`，27s）· `rejoin_probe` **OK（`REJOIN PROBE: ALL-OK(5)`，59s；已知红已修后复跑）** · `royale_soak` OK（`SOAK: ALL-OK(4/4)`，132s）· `royale_role_cap` OK（`ROLE CAP PROBE: ALL-OK(9/9)`，119s）· `team_match_probe` **FAIL**（c4 相⑤ 单端快照间隔 10009ms；同配置**第二跑 `TEAM MATCH PROBE: ALL-OK`** ⇒ 判 flake，已登记到本文件「已知红」第一条）。全批 `gate-failures=0`、无残留连累。

**边界（照实）**：
1. **真链路批已跑**（2026-10-31，用户认领）：4/5 PASS；`team_match_probe` 的失败是同配置第二跑不复现的**时序 flake**（详见「已知红」第一条与上面的验证段），已按仓规「同配置跑两次」下结论。⇒ S-03 的**接线段**（`NetBus` handler 真调 `accept_* + emit`）与 S-15 的 RPC 载荷由「不崩 + 链路通」间接覆盖（`pvp_match`/`soak`/`role_cap`/`rejoin` 绿），但仍**没有一条断言直接数**某个 RPC 的到达；S-07 的真网卡路由仍只有本机单跑读数。
2. `down_edge_probe` 只证"记分 / 逐人 kills / 队分归属"三个语义；`round_state` / `kill_event` 的**线上载荷字节**在空 peer 表上短路（`_rpc_all` 不发包）⇒ 广播内容零覆盖。
3. `snapshot_rx_smoke` 不覆盖 NetDiag 落盘、`--diag` 开关与真实丢包分布；`NetBus` 侧 `take_diag` 的调用接线断了冒烟不会红（只有真链路 `--diag` 能看出）。
4. `gen_rpc_channel_table.py` 只能证明「两 autoload 的行首声明文本 ↔ 文档表/合计」一致 + 跨 autoload 无重名；**测不到**运行期派发（`GDScript.get_script_method_list()` 读不到 `rpc_config`）、`@rpc` 是否被引擎接受、接收端挂在哪个节点。
5. **S-07 顺带修掉的既有缺陷（行为变化）**：旧 `_read_ip_file_best` 在 `本机局域网 IP: <ip>(…` 上把 `IP:` 后的值按第一个空格截成空串 ⇒ `local_ip.txt` 快回路径**从未命中**（每次白跑一次 netstat）；新实现先 strip 再截 ⇒ 快回路径首次真正生效（仍校验 IP 属于本机）。副作用：网络切换后若旧 `local_ip.txt` 的 IP 仍是本机地址（多网卡在线），旧 IP 会继续占第一候选，靠「不通就换」兜底。另 `_priv_score` 3 档 → 4 档（192.168=4 / 10=3 / 172.16-31=2 / 其它=1；`>=2` 的"是否私有"语义不变，只让 fallback 排序更确定）。
6. **class 缓存 / `.uid` 是手工补的**：本会话沙箱下 `.godot/editor` 不可写 ⇒ 引擎无法重建 `global_script_class_cache.cfg`、也不会生成 `.uid`。本轮 `SnapshotRx` / `LanIp` 两条缓存条目与 5 个新增 `.gd.uid` 由 Lead 按 Godot 格式手工落盘（`.godot/` 是本地缓存、不入库；无沙箱环境重开编辑器会被引擎覆盖/重生成，无副作用）。
7. 本轮改动**已提交**（25 个文件；逐个文件点名 `git add`，新 `.gd` 连 `.gd.uid`、`.tscn` 不加）。提交环境：本会话后半段切到完全访问后才可用 `git`（先前沙箱下子进程写不进工作区子目录）。
8. `lan_ip_smoke` 的 ⑤ 经 `LanIp.lan_ip_candidates()` **间接**拉一次 `netstat.exe`（只读、不开端口、不写盘）—— 这是 `tests/run_all.sh` 承重安全检查的已知盲区（它只扫入口源码文本，看不见经 helper 间接拉起的进程，见该文件头「它的盲区」）。若以后要求默认批"零子进程"覆盖到间接形态，这条断言要改成注入式（netstat 文本作为参数喂纯函数，不碰真环境）。
9. ★ 2026-10-31 发布时发现 S-13② 把面板仪器放进 `tools/` 会让**服务端导出包解析失败**（默认批/真链路都不覆盖"导出包内容"）；已修复，见 §四十二。

## 四十二、发布阻断修复：`PanelInsetAudit` 在导出包里不可解析（2026-10-31，档 1）

**现象（`build_release.py` 的服务端产物冒烟当场抓到，发布中止）**：
`SCRIPT ERROR: Parse Error: Identifier "PanelInsetAudit" not declared in the current scope`（两次）→ `Failed to load script "res://server/gui/server_panel.gd"`。

**根因**：S-13②（2026-10-31 00:21）把面板的设计期仪器从 `server_panel.gd` 挪到 `tools/panel_inset_audit.gd`，而 `export_presets.cfg` 的**所有预设**都排除 `tools/*`；`server_main.gd` 以 `preload("res://server/gui/server_panel.tscn")` 拉起面板 ⇒ 服务端主场景加载时 `server_panel.gd` 解析失败。**编辑器里一切正常**（class cache 知道类名），只有导包后现形 —— 这正是「产物冒烟」存在的理由。客户端不受影响：客户端预设排除 `server/gui/*`，且客户端主场景不加载 `server_main.gd`。

**为什么之前没发现**：上一份发布产物（`RoF_v0.5.2_202610301027`）早于 S-13②；S 批只跑默认批 + 真链路，**两条链路都不看"导出包里有没有这个脚本"**（它们的盲区，只有 `build_release.py` 的产物冒烟覆盖）。

**修法**：`git mv tools/panel_inset_audit.gd server/gui/panel_inset_audit.gd`（连 `.gd.uid`）—— 服务端预设会打包 `server/gui/*`，类名可解析；客户端预设排除 `server/gui/*`（客户端本来就没有面板）。同步 `server_panel.gd` 注释与本文件 §三十五。

**验证**：`ALLSCRIPT: OK(216)`（无 `LOAD[FAIL]`）· `python tools/check_naming.py` 绿 · `build_release.py` 全流程重跑（Windows 客户端/服务端 + 冒烟 + macOS + Web + 归档）全绿；服务端冒烟断言「worker 就绪」+ exe 同目录 `log/` 非空。

**边界**：① 该类名是"产品脚本对 dev 仪器的硬引用"，仪器文件必须留在**被服务端预设打包**的目录里（别再挪回 `tools/`；挪之前先看 `export_presets.cfg` 的 `exclude_filter`）；② 产物冒烟不含 macOS/Web 的**运行**（Windows 主机跑不了 mac 二进制），那两份只有结构/体积校验；③ 这类"只在导出包才现形"的缺陷，默认批/真链路两条链路都抓不到 —— 发布前必须跑 `build_release.py`（它自带产物冒烟）。
