# 上游基线重建执行手册（port/upstream-2026-09）

> 状态：**待触发**——等 原作者(aleksey-45) 下一波大更新落地后，与本手册内容**一次性动工**。
> 本文是执行图：事实快照 + 已定决策 + 批次搬运表 + 硬点预案。执行前只需跑一次「§7 刷新清单」，不必重新分析。
> 基线记录日期：2026-09-21（侦察自 GitHub compare API + 本地只读 git，未做任何写入）。

---

## §1 事实快照（执行前须刷新，见 §7）

| 项 | 值 |
|---|---|
| 远端 | `https://github.com/aleksey-45/the-cyancular-ruins.git`（原作者；仓内另有拼写错误的 `orgin` 指向同一 URL） |
| 上游 main（侦察时） | `0bd4c1a5` 2026-09-17 |
| 本地 `origin/main` 缓存 | `781a30e` 2026-09-13（**已过期**；缓存后还有 160 提交） |
| 本地 HEAD（侦察时） | `38a6f1e` 分支 `proto-time-map` |
| merge-base | `014f2ea` 2026-09-04 |
| 未并入本地 | 约 **381** 提交（221 缓存 + 160 新） |
| 本地领先 | **134** 提交 |
| 上游 160 提交性质 | **大重构**（core/sim·net·config·present 四子目录、`scenes/` 全小写、`server/` 拆继承链、`tests/` 统一）+ 五个真特性 |

**三个关键利好**（已核实）：
1. `tile_defs.json` 内容 **md5 与本地完全一致**（仅从 `Globals/` 搬到 `data/`）；`tile_defs.gd` 只删死代码（-9 行）。
2. 上游**没有新增地图**（`maps/` 只有 demo.cyrm + factory1v1.cyrm，且删了 old_map.txt）。
3. 地图格式（.cyrm/.cyrt）**未见变化证据**（`map_format.gd` 是从 maze_generator 抽出的重构，未确认有新语义）。

---

## §2 已定决策（用户 2026-09-21 拍板，执行时不再问）

1. **以上游为基线重建**：旧线（`proto-time-map`/`editor_log` 等）永久保留只作内容来源，不做整树 merge。
2. **快照按上游拆两包**（`snapshot_world` 广播一次 + `snapshot_own` 定向）：接受原版 NetBus 方法表**一次性断点**；发布需两端同步升级。
3. **武器背包+地面拾取：联机一起做**（含 MatchGround 权威域/快照 capture-restore/复活丢枪/换局重置）。
4. **落点：新开 `port/upstream-2026-09` 分支 + 独立 worktree**（不动主工作区与并行会话）。
5. **NetBusExt 信封化收纳**：上游重连 3 RPC 收进 `ext_c2s/ext_s2c` kind；保留 hello/welcome 能力协商与 BUILD_ID（公网服旧服务端可长期使用）。

---

## §3 阶段 0：上游对象拿全（网络预案）

`git fetch origin`；若 schannel/TLS 失败（此机历史高发），按序尝试：
1. `git -c http.proxy= -c https.proxy= fetch origin`
2. `git -c http.sslBackend=openssl fetch origin`
3. 下载 main tarball（GitHub codeload）解到临时目录 → `git fetch <本地路径> main:refs/remotes/origin/main`（本地路径 fetch 不经 TLS）
4. 最后手段：curl/gh 逐文件 raw 拉取（仅当上面全败）

成功后：
- `git tag upstream-YYYY-MM-DD <sha>`（只读锚，记录侦察与执行两次快照）
- `git worktree add C:/Users/21559/Desktop/cyancular-port port/upstream-2026-09`
- 基线体检：`--headless --import` + 上游自带探针（grace/reconnect/weapon_inventory 等）跑绿，确认新树本身健康再开工

---

## §4 搬运批次表（每批独立提交+验证；顺序=依赖序）

| 批 | 内容 | 关键文件 / 来源 | 备注 |
|---|---|---|---|
| B1 | 视觉/字体地基 | 上游 `core/pixel_font.gd`+CJK 链、`assets/fonts/unifont-17.0.05.otf`(5.3MB,OFL)、`ui/ui_factory.gd`(+208)、三 HUD 样式；本地 17 处 `less_perfect_dos_vga.ttf` 硬编码收口 | **不**执行上游"删 reload_enabled"（本地主线无此开关，单独决策） |
| B2 | 音效与设置 | 本地 `Globals/sfx.gd`(8bit 合成)、`Settings`(总线/键位/`user://settings.cfg`)、设置页 | 适配上游 `core/config/` 落点 |
| B3 | 场景纪律 | 本地 `Level0.safe_change_scene` + 演示世界保活 + `pause_menu` 接线 | 适配上游 `scenes/level_0.gd` 新结构 |
| B4 | 单人选项与选图 | 本地 `RunOptions`(难度/禁武器/地图)、`RoomManager.list_maps(include_time)`、`editor/map_importer.*`、导出 `map/*.cyrt` filter | — |
| B5 | 武器扩充 | 本地 laser_weapon_base/laser_gun、加特林(槽7)、开山砍刀(槽8)、`WeaponComponent.apply_card_stats`(CARD_STAT_KEYS)、剪影/custom art 路径 | 与上游背包模型的合并规则在 B8 定 |
| B6 | 道具系统 | 本地 prop_launcher+击退炮/吸力炮/烟雾弹、`Explosion.apply_force_aoe`、`Globals/smoke.gd`+`smoke_zone`、槽位 81-84、T 模式、烟雾可见性 | — |
| B7 | 打击反馈 | 本地 `Scenes/Effects/combat_feedback.gd`（命中X/击杀播报/受击增强）+ 联机 `hit_confirm` kind | — |
| B8 | **武器背包+地面拾取（上游特性原样落地，含联机）** | 上游 `core/sim/weapon_inventory.gd`(+120,纯逻辑)、`scenes/weapons/weapon_pickup.gd/.tscn`、`core/sim/ground_weapon_field.gd`(+63)、`core/present/sprite_bounds.gd`(+60)、`ui/weapon_slots.gd`、`server/match_ground.gd`(+248)、快照 capture/restore(`cb0711d7`)、软回灌(`ab0aa799`)、复活丢枪/换局重置(`a31930b0`) | **先决设计题**：本地 7/8 槽与道具 81-84 的 `tier` 与是否入背包；`_net_slot` 语义从"槽位号"变"背包下标"，牵动输入包解析 |
| B9 | **网络层重建** | ①快照两包 `snapshot_world/snapshot_own`（上游 `8f8b6ab`，含 `NetBus.rpc()` 而非逐 rpc_id 的 O(N²) 陷阱）②重连 stage1：`core/net/grace_window.gd`(+46 新)、`token/reclaim` 链路(`4921986d`/`97fca866`/`a25f7f3a`/`d7cccac8`/`0bd4c1a5`) ③NetBusExt 信封化收纳 ④ack 中毒守卫补进本地 `Scenes/pvp_client.gd:~198` 与 `Scenes/royale_game.gd:~180`（本地目前**无** `ack > _input_seq` 检查） | 重连要点：token 由大厅在 go_match 前下发 → 客户端 claim 后 report_token → worker 存 role→token；`_enter_grace` 需**同时清输入源与 _pending_input**；`_on_reclaim` 三拒条件；客户端只认 `server_disconnected` |
| B10 | 服务器与大厅增强 | 本地僵尸房清扫/端口策略/`PUBLIC_SERVER_ADDR` 公网双模/`_kill_port_holder` PS 修正、AI 补位(`ai_input_source`+`ai_player`)、**上游黏滞修复**(`a2c331d9`：`_pick_target` 黏滞分支 `dir: -d`——本地同 bug 在 `server/ai_player.gd:75`)+ 上游位置符号探针 | 上游后来改名 `ai_navigator.gd`/`AiInputSource`，在改名提交之后落地即可 |
| B11 | 大乱斗 | 本地 royale_lobby/hud/game、`RoyaleHost`、房间管理（限时/自杀键/死亡榜/排行榜）、机器人探针 | 上游 `royale_game.gd` 仅 +3-1（订阅重连）与快照拆分适配 |
| B12 | **时空维度私有层（最大）** | 本地 `Globals/time_params|clock|timeline|world.gd`、`.cyrt` 格式+`MazeGenerator` v4/cyrt 标记、`Level0` 执行层(explode/wipe/gen/spawn_enemy/玩家入史/`apply_tl_ops`)、表盘+时间线 HUD、编辑器时空模式(滑动条/预览播放/导出)、地图资产(timetest/timetest2/burnt_norton/用户图)、四探针(`time_ledger/events/map/player_ops`) | **与上游 `scenes/level_0.gd`(+347/-13) 同文件，冲突最重**：以上游文件为底手工重贴我们的段 |
| B13 | DevTools | 本地卡编辑器全套(store/schema/form/prompt/agent_link/portrait)、素材编辑器、日志监看；`editor/structure-editor.html` 时空模式与上游 `level_editor/structure-editor.html`(+3/-3) 三路合并 | 上游还有 `editor/tile_defs.js`、`sync-tiles.js` 小改 |
| B14 | 文档收口 | AGENTS.md/ARCHITECTURE/GDD/plans 全路径改写(core/·scenes/·ui/·tests/)、模块登记、全量探针、用户实机、重导出 exe | exe 仅此批导一次 |

---

## §5 上游五特性实现要点（侦察结论，执行时免重查）

**① 断线重连 stage1**：`GraceWindow`(纯逻辑,30s,重复 enter=刷新) + NetBusExt 三 RPC(`session_token`/`report_token`/`reclaim_role`) + `pvp_session.token/worker_port` + `server_main` 宽限状态机(`_enter_grace` 清输入源**与**待处理输入队列/`_expire_graces` 每秒/`_on_reclaim` 三拒条件+`_ack_seq` 归零重发 `match_start`) + 客户端 `_begin_reconnect`(只认 `server_disconnected`,CONNECTED→DISCONNECTED 那一跃观测不到) + `0bd4c1a5` ack 守卫(`if ack > _input_seq: return`，本地 `prediction_rollback.gd:75/109` 的 `if ack <= _acked` 正是会被毒死的判据)。探针：`tests/reconnect_smoke.gd`(源码级双向守卫:重连 RPC 必须在 NetBusExt、绝不在 NetBus)、`reconnect_probe.tscn`。

**② 武器背包**：`WeaponInventory`(held=[{type,inst,mag}]，`MAX_WEAPONS=4` 与 `CAPACITY=8` 两条独立闸门，`SLOT_COST={轻2,中3,重4}`，`inst` 必须有否则同类型两把串弹) + `WeaponPickup`(CharacterBody2D,组 `weapon_pickup`,层8/掩9,`canonical_pos` 与 `global_position` 分离,`configure()` 须在 add_child 前) + `GroundWeaponField`(纯表,环面最近距离,**并列按 inst 升序=确定性**) + `SpriteBounds`(像素 alpha 包围盒) + `MatchGround`(服务器真的实例化 WeaponPickup 复用落体物理) + 单机 `level_0.scatter_weapons/try_pickup_for/clear_pickups`(12 把=每种2把跳禁用) + 输入 F 捡/Q 丢 + `ui/weapon_slots.gd`(4×2,CELL=22)。**关键契约**：`_current_slot` 保持"类型 id"语义 → PvP 快照协议与 PlayerReplica 零改动。

**③ 快照两包 O(N)**：世界包去 ack/c2、构造一次 `NetBus.rpc()` 广播（**必须 rpc 而非逐 rpc_id,否则 ENet 层仍 O(N²)**）；本人包只含 `{ack_seq, c2}` 定向发。实测：8 人局服务器上行 3555KB/s → 446KB/s（≈29→3.6Mbps）；单人条目 948B 中 c2 占 664B(70%)。本地现有 `snapshot_c2_self_only`（世界字段仍按人重复序列化）将被取代。

**④ AI 黏滞修复**：`server/ai_player.gd` `_pick_target` 黏滞分支 `dir: d` → `dir: -d`（契约：返回的 dir 恒为"我→对手"；`toroidal_delta_px(a,b)` 是 a→b，传 `(对手,我)` 必须取负）。**本地 `server/ai_player.gd:75` 同 bug**。探针：`tests/ai_input_source_smoke.gd`(真调 `_pick_target` 做符号断言)。

**⑤ 视觉整改+中文字体**：`core/pixel_font.gd`(+45/-4：`CJK_FONT_PATH`、`_sharpen()`、`_cjk_chain()`=Unifont+SystemFont 兜底 SimSun/YaHei)、`assets/fonts/unifont-17.0.05.otf`、`ui/ui_factory.gd`(12 颜色 token+7 个 style 工厂)、`core/settings.gd -3`(**删 reload_enabled**——本方案不采纳)、若干场景样式、`tests/combat_hud_visual_probe`。

**上游路径映射（本地→上游）**：`Globals/`→`core/sim|net|config|present/`；`Scenes/`→`scenes/`（`Scenes/Player|Weapons|Enemies|Effects`→小写同名）、HUD 类→`ui/`；`Tests/`→`tests/`；`server/match_host.gd`→`match_state/round/combat/snapshot/ground/bootstrap.gd` 继承链；`Globals/net_bus*.gd`→`core/net/`；`Globals/tile_defs.json`→`data/tile_defs.json`；`map/`→`maps/`。

---

## §6 硬点与预案

1. **tier 先决题**（B8 前必须定）：加特林(7)/砍刀(8)/道具(81-84) 的重量档与是否进背包；不定死则 `cost_of` 默认 LIGHT 静默算错容量。
2. **`_net_slot` 语义变更**：槽位号→背包下标，客户端/服务器输入包解析同步改（本地 `Scenes/pvp_client.gd`、`server/match_host.gd`）。
3. **方法表一次性断点**（已确认接受）：新旧构建互连 checksum 失败，发布需两端同步；与"信封保证后续增量稳定"不冲突。
4. **全路径大小写/搬家**：本地代码引用需全局扫描改写（`res://Scenes/…`→`res://scenes/…`），文档同步。
5. **并行会话**：port 期间 `proto-time-map` 新改动不会自动进 port——执行时先约定"主线冻结"或事后人工搬运。
6. **工作量**：14 批 × 0.5~2h（B8/B9/B12 为大头），跨多会话；每批交付即可独立验证。
7. **fetch/TLS 不稳**：见 §3 四级预案。

---

## §7 执行前刷新清单（原作者下一波更新落地后，照跑即可）

1. `git fetch origin`（或 §3 预案）→ `git log --oneline <本地缓存SHA>..origin/main` 看新提交；
2. `git tag upstream-<新日期> <新SHA>`；记录新的分叉计数；
3. 扫一遍新提交是否触碰 §4 表内文件（`core/`、`scenes/level_0.gd`、`core/net/`、`server/`、`ui/`、`data/`、`assets/fonts/`）——有则并入对应批次（同一批做完再验证）；
4. 若出现**全新特性**（非重构），按 §4 的格式追加为 B15+ 批次（提交范围+关键文件+重叠点三要素）；
5. 按 B1→B14 顺序开工，每批：`--import` 编译 → 本批探针 → `time_*` 回归 → 提交（信息注明上游 SHA）；
6. 旧线 `proto-time-map` 全程零改动；收口（B14）才重导出 exe。

---

## §8 参考：本地需要搬运的自研层清单（134 提交的净内容）

时空维度全套（time_* + .cyrt + 编辑器时空模式 + 地图资产 + 四探针）｜道具系统（三道具+Smoke+槽81-84+T模式）｜武器扩充（激光/加特林/砍刀/卡片数值/剪影）｜大乱斗（lobby/hud/game/Host/限时/自杀键/死亡榜）｜公网-局域网双模+信封协议+能力协商｜僵尸房清扫/端口策略/PS 杀端口修正｜AI 补位｜打击反馈（命中X/击杀播报/受击增强）｜8bit 音效｜设置系统（总线/键位/持久化）｜单人开局选项（难度/禁武器/地图）｜地图导入+全模式选图｜卡编辑器/素材编辑器/日志监看/map_importer｜`safe_change_scene` 场景纪律｜菜单演示世界保活｜版本信息面板｜DevTools 与 `structure-editor.html` 时空模式
