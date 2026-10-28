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

**改了什么**：`BulletBase.tile_break_unit`（@export，单位 = 格，默认 1.0）；榴弹 `grenade_bullet.tscn` 设 **0.25**（= 1 个 16px 子格），其余枪不覆盖 = 1.0。`_damage_tile_at` 按单位分派：整格走 `TileDefs.damage_tile`（格级 `hp_grid`），1/4 格走 `damage_sub`（子格 `sub_hp`）。`Explosion.apply_aoe(..., tile_unit_cells)` 把同一参数传给新的公开 `Explosion.damage_tiles`：整格侧对爆区内每个 64px 格**去重**后按最近子格的衰减值扣一次；子格侧保持现状。`damage_sub` 在整格 16 子格打空、`current_grid[cell]=0` 的同时把 `hp_grid[cell]=0`（两本账在"格子已消失"上对齐）。`grenade_bullet.tscn` 的 collision_mask 5→1（task-8 分离的收尾：榴弹也不再靠物理碰撞吃敌人）。新守卫 `tests/smoke/tile_break_unit_smoke.gd`（10 条断言 + 条数闸）。

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
