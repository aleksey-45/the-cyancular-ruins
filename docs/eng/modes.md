# 对局模式(对抗 / 结算页 / 大乱斗)

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 对抗(mode id 仍是 `"team"`)

- 显示名 = **「对抗」**(两个汉字,不加任何副文案)。内部 mode id / RPC 通道 / 回放凭据一律仍是 `"team"`(`ModeDefs.MODE_TEAM`);改的只是语义与文案。模式名的唯一来源 = `scenes/mp_lobby/room_list.gd::MODE_LABEL`(房卡标题、等待室标题、筛选按钮、建房弹层分段按钮都从它取;`.tscn` 里的按钮 `text` 只是编辑器占位)。`ModeDefs.label(MODE_TEAM)` 也是「对抗」。
- 人数:总 **2~10** 人(两队各 **1~5**)。容量三处同源 = `ModeDefs.TEAM_SIZE`(= 每队上限 5)× `ModeDefs.TEAM_COUNT`(= 2)= `LobbyRooms.TEAM_ROLES`(= 10);大厅 `max_players` / 加入上限 / 列表 cap 全取这一份。每队上限闸门在 `team_join`(进房上限)与 `team_pick`(`RoomTypes.team_can_join`)。
- 开局条件 = **两队各 ≥1 人**(`RoomTypes.team_ready`,`min` 常量是 `TeamRules.MIN_PER_TEAM`);人数可以不等,4v2、5v1 都合法。未选边的人在**开局那一刻**由 `RoomTypes.team_autofill` 补进人少那一队(势均补 1 队;贪心不会破每队上限),写回 `room.team_of` 后再作为 `--teams` 下发 —— 大厅队伍表与 worker 的队伍归属因此永远是同一份。房主点「开始游戏」(`NetBusExt.team_start_requested` → `RoomManager.team_start`);无 AI 补位、无降级。
- 数值公式的**单一来源** = `core/mp/team_rules.gd`(`TeamRules`,`-s` 可测)。实现在 `TeamHost`;客户端(血量那一半)用同一份从 `match_sync` 的 `teams` **复算**,不新增协议字段。
  - 每局击杀目标 = `clampi(总人数 + 3, 5, 13)` ⇒ **2 人 → 5、6 人 → 9(与改造前的 3v3 逐字一致)、10 人 → 13**。
  - 开局比分补贴(少人方)= `min(人数差, 目标 - 1)`。每局开局都给(`_start_next_round` 里 `_scores = _initial_scores()`);上限是「目标-1」,防开局即胜。
  - 血量补贴(少人方)= 基础 `max_hp` + **每差 1 人 +10%,封顶 +40%**(⇒ 50/55/60/65/70,封顶 70)。服务端 `TeamHost._apply_health_subsidy` 设真值;客户端 `scenes/team_game.gd::_apply_team_health_subsidy` 复算出同一个数(否则快照里的 hp 会被钳到客户端上限并每帧回滚)。
  - 伤害补贴(少人方,**仅极端少**)= 人数差 ≥ `TeamRules.DAMAGE_THRESHOLD`(3,即 4v1 / 5v2 起)才给,每差 +10%,封顶 +30%。落点:① 换枪时把倍率写到武器 `damage`(弹丸直击与激光都从这里取伤害);② `_adjudicate_bullets` 前置一遍,只乘子弹自带的 `direct_hit_damage` / `explosion_damage`(榴弹直击与 AoE,不走武器 damage)。子弹上用 meta 标记只乘一次。
  - **人数差 = 0 时三处补贴恒等**:目标 9、比分不写(`_scores` 保持空表)、`max_hp` 一个字节不动、倍率恒 1.0 —— 既有 6 人 `team_match_probe` 的行为不变。守卫 = `tests/smoke/team_rules_smoke.gd`(§④「所有 n v n 势均局恒等」+ §③「6 人 3v3 恒等」)。
- `round_state` 载荷:`TeamHost._broadcast_round_state` 在共有骨架上追加 `target`(本局目标,恒有)与 `handicap`(仅人数差 > 0:`team` / `diff` / `score` / `hp` / `damage_pct`)。`ui/hud/team_hud.gd` 的目标与「先到 N 杀」文案**只从载荷取**(旧实现写死 9,目标随人数缩放后会撒谎)。
- 掉线 / 人数变化**不重算**目标与补贴(开局那一刻的 `_rules` 是快照):客户端手里的队伍表也不随掉线更新,两端同值优先于"实时公平"。
- 启动契约(`server_main.gd` 文件头):`--worker --team --port P --roles r,… --teams t,…`。`roles` 与 `teams` 同序等长(第 i 个 role 的队号 = `teams[i]`);收齐判据 = `_claims.size() >= _team_of_role.size()`(催收不齐时 30s 超时梯 `quit(0)` 释放端口,不降级);`--royale` 与 `--team` 同时为真直接拒启动。
- 队伍表经 `match_sync` 的 `teams`(`TeamHost.team_map()` 的只读副本)下发,只在非空时带该键,不进 `round_state`(目标/补贴另走 `target` / `handicap`)。`MatchState._team_of` 就是这张表,不从 role 号推导。
- `same_team()`:任一方 0 → false(0 = 查不到队伍),`same_team(0, 0)` 也是 false。
- 子弹穿透队友、爆炸对队友满效(爆炸走 `_explode()` → `Explosion.apply_aoe`,玩家分支不看队伍)。`same_team` 在 `server/match/match_combat.gd` 的 `_adjudicate_bullets` / `_adjudicate_grenade` 两处;`_check_player_contact` 只排除射手、不看队伍。
- 激光也穿透队友:`MatchState.is_friendly(a, b)` + `LaserWeaponBase._damage_path_targets` 玩家循环里一条 `continue`(不是 `break`,队友身后的敌人照打)。只改权威侧。
- 助攻与惩罚计数(`assists` / `team_damage` / `self_damage` / `team_kills`)只影响 `kscore`,不进 `dealt` / `taken`。助攻表 `MatchState._assist_times` = `victim_role -> {attacker_role: 时刻ms}`;写入口 `_note_hit`(由 `MatchCombat._on_player_hit` 调);判定在 `_record_down`(除击杀者外、窗口内、且 `same_team(attacker, killer)`);清空在 `MatchRound._respawn_player`;窗口复用 `ATTRIB_WINDOW`(3s)。队伍表为空 ⇒ 1v1 / 大乱斗拿不到助攻。
- 惩罚 = `(team_damage + self_damage) ÷ 5 + team_kills × 100`(`ScoreRules.penalty`),记在肇事者行上。
- 自伤专用通道:`CombatFeedback.note_self_hit` / `is_fresh_self_hit`,由 `Explosion.apply_aoe` 在 `shooter == victim` 时写;窗口 8ms;落地一笔真实归因时在 `attribute()` 里 `remove_meta("last_self_hit_time")`。
- 对抗模式击杀后不复位任何人。1v1 的 `_reset_survivor` 与大乱斗保留。
- 掉线判据:整队走光才终局(`TeamHost.mark_disconnected`)。`server_main._expire_graces` 两处判据都必须带 `_team_mode`:分派 `GraceWindow.expire_action(_royale, _team_mode)` 必须与 `ACTION_REMOVE` 比较;末尾全员走光退出是 `(_royale or _team_mode) and …`。
- 对抗模式有 K 键自杀:`TeamHost.request_suicide_role`;闸在 `server_main._on_suicide_request` 首行 `if not (_royale or _team_mode) or _host == null: return`;覆写必须留在 `TeamHost`。
- 分队碰撞层:队 B 身体层 = `TeamHost.TEAM_ENEMY_LAYER := 16`(不许写死);副本幽灵体 `mask` 恒 0,`layer` 按代表玩家的队;服务端 `TeamHost._apply_team_layers` 与客户端 `team_game._apply_team_collision` 逐值对齐。掩码必须保留地形(1)与敌人(4);未知队号客户端落层 2、服务端什么都不配;副本懒建:`ReplicaSet.ensure`(S-18 后,`scenes/mp_client/replica_set.gd`)建完在 `ensure` 末尾自己 `refresh_labels()`,宿主不用再刷一遍。
- 平局:`match_winner == 0` 在对抗里可达(两队都走光)。`ui/hud/team_hud.gd` 念「平 局」;`pvp_hud.gd` 的 1v1 兜底不能照抄过来。
- 输赢文案由 `set_my_team()` 驱动:`_apply_teams` 在队伍表到达后必须调 `_hud.set_my_team(_team_of_role(PvpSession.role))`;队号只能从队伍表读,不是 role。
- 队色 = `modulate = 队色 / 本体主色`(`_apply_tint` 的 `color_override` 唯一参数);`BODY_BASE_COLOR = #639BFF`(`player.png` 的不透明众数色);队 1 的比值恰为 (1,1,1)(`C_TEAM_A` 就是它),队 2 有分量 > 1。换 sprite 素材要重测 `BODY_BASE_COLOR`。对抗模式颜色不可自选(2026-10-24 起):`_apply_peer_hues_or_team` 覆写基类钩子、只消费载荷里的 `teams`;自己那具也走队色。
- `player_p2_hue.gdshader` 已无代码引用(个人色相随大厅改色控件一起移除,文件暂留);`_apply_tint` 只剩 modulate 比值一条路。
- 换边后客户端在**新一轮 COUNTDOWN** 重拉一次 `match_sync`,先置 `_resync_pull_pending = true` 再发;与重连补态共用同一个标志,不新立标志。换边 = 每局 `_side_swap_round` 取反,`TeamHost._start_next_round` 用它重算 `_round_spawns = plan_team_spawns(_team_of, _round_spawns, _side_swap_round)`(**队 1 = 侧 1 左半、队 2 = 侧 2 右半**,取反后两队互换侧;每局在那一侧的 `# respawn` 列表里重随机并排除本 role 上一局点位)。`TeamHost.compute_swap_spawns` 仍保留旧语义的名字(探针/手工路径引用),但**不再是生产换边路径** —— `team_match_probe` 相④ 用"第 1 局点集精确对调"算的期望已过期(登记在债单)。
- 出生/复活点:自 2026-11 起由**地图文件的数据**决定(`.cyrm` 的 `# respawn 1|2` meta,**按阵营半区**:队 1 侧 1 左半 / 队 2 侧 2 右半、每侧 ≥5 且 3×3 桶覆盖;缺数据 / 人数超过该侧列表时 `TeamSpawn` 回退几何生成)。`TeamHost` 只管 `_round_spawns` / `_side_swap_round` / `_spawned_once` / `_last_spawn` 与 `_spawn_cell` / `role_spawns` / `_respawn_cell_for` 覆写;**局内复活也走本队这一局所在侧的列表**(`TeamSpawn.respawn_cell`,缺数据才回退 `SpawnPicker` 池)。每队 1~5 人都要各有一格(布局由出生点数据负责)。方位与完整规则见 [world.md](world.md)「出生/复活点:按阵营半区的地图数据」。
- `TeamHost._on_bullet_hit` 覆写先 `CombatFeedback.attribute(victim, bullet.shooter)` 再 `super`;基类 `MatchCombat._on_bullet_hit` 也写同一笔(幂等)。基类那行是 1v1 的唯一子弹归因写端,不可删。
- 逐人数据:离开者用 `MatchState.note_disconnect_round(role)`(`_enter_grace` 掉线那一刻记录);MATCH_OVER 之后倒地不进 `_stats`,ROUND_OVER 期间照旧入账。

## 结算页

- `ui/screens/match_result.gd`(`MatchResult`,CanvasLayer)模式无关;模式差异全部由 `ui/screens/match_result_payload.gd` 的三个适配器(`for_duel` / `for_royale` / `for_team`)折成一个载荷字典。`columns` 由数据决定。
- 列:`C_DUEL = [kills, deaths, dealt, taken, acs]` / `C_ROYALE = [kills, deaths, dealt, taken]` / `C_TEAM = [kills, deaths, assists, dealt, taken, acs]`;标题在 `ui/screens/match_result.gd::COLUMN_TITLES`。
- 载荷字段集 `{kills, deaths, assists, dealt, taken, kscore, acs}`;口径收在 `core/sim/score_rules.gd`(`ScoreRules`,纯静态):`kscore = 击杀×100 + 助攻×50 + 伤害÷5 − 死亡×50 − 惩罚`,`acs = kscore ÷ 局数`;读端不得再加伤害。
- 投递点:`1v1 server/match/match_round.gd` / 大乱斗 `server/hosts/royale_host.gd` / 对抗 `server/hosts/team_host.gd`。1v1 的击杀记给对手且不看归因;大乱斗是归因制,无归因的死亡不计任何人的击杀。
- `leave_requested` 只发一次(`_leaving` 防重入);离场走 `Level0.safe_change_scene`,不裸 `change_scene_to_file`。
- ESC:对局中 = 暂停菜单,结算页 = 返回主菜单。三个客户端的 MATCH_OVER 块都 `_pause_menu.queue_free()`;删掉这两行会让 ESC 在结算页同时触发两件事。
- 层位 150 只写在 `ui/screens/match_result.tscn` 里,只能从场景实例化,不 `MatchResult.new()`。
- 挂载 / 离场收在基类 `PvpMatchClient` 的 `_show_result` / `_leave_to_main_menu`,三个客户端只各覆写 `_build_result_payload()`。`_show_result` 每次都要刷新(`if _result == null` 只包住「建 + 连线」)。
- 第二条 MATCH_OVER 载荷可达:reclaim 成功会重播 `round_state`;`TeamHost._finish_match` 直接 PLAYING→MATCH_OVER;倒地边沿检测在 `_round_state` 之前且不看状态。

## 大乱斗(Royale)

- 入口:主菜单那颗「多 人 模 式」→ `scenes/mp_lobby.tscn`;从哪个模式进由 `_current_mode` 分派,没有静态标记。
- 房间:`LobbyRooms` 的 `RoyaleRoom` 注册表,与 1v1 的 `rooms` 并存且互斥;建房 / 加入 / 状态广播走 `NetBusExt` 的 `royale_*` RPC。
- 开局:房主 `royale_start`(或 `royale_start_ai`)→ `RoomManager` 调 `WorkerLauncher.spawn_royale_worker(port, roles, ai_roles)`,用 `OS.create_process` 拉起独立 worker:命令行 `--headless --log-file <path> [--path <res> res://server/server_main.tscn] -- --worker --royale --port P --roles 1,3 [--ai-roles r,r]`(editor / template_debug 必须带 `--path` + 场景;与 `server_main.gd` 的 argv 解析逐字对应)。role 集合显式传,不从人数推导;AI 补位号由 `LobbyRooms.royale_free_roles` 取人类未占用的空闲号。
- 开局判据:收齐 `_human_role_count()` 个人类 claim;已到 ≥2 人但 20s 收不齐 → 按已到人数降级开局;可用玩家 <2 人 → 10s 宽限后退出释放端口。`_on_role_claimed` 有报到串线防护:对局已开始 / role 不在 `--roles` 集合内 / role 已被别的 peer 占用 → `disconnect_peer`。开局延到帧末,让同一 poll 里的 `player_options` 先归档。
- 端口归还 `ROYALE_PORT_REUSE_DELAY = 360s`。
- 上界 `ROYALE_MATCH_TIME_CEILING = 1800s`(= 30 分钟 × 60);三环:`settings.gd` 装载 `royale_match_min` 时钳 `[1, 30]` 分钟、`scenes/mp_lobby.gd` 换算成秒下发(该行必须留在 `mp_lobby.gd`)、`scenes/mp_lobby/options_form.gd` 的滑块 `max_value = 15` 且 `value_changed` 不钳位地写 `Settings.royale_match_min`。改钳位 / 换算 / 滑块上限任一处都要回看这个上界。
- 权威 `server/hosts/royale_host.gd`(`RoyaleHost extends MatchHost`):覆写 `_init` / `_spawn_cell` / `_ready` / `_match_round_tick` / `_match_winner` / `_broadcast_round_state` / `_on_bullet_hit` / `_respawn_player`;自有 `set_display_names` / `mark_disconnected` / `request_suicide_role` / `_finish_match` / `_attributed_killer`。`_init` 必须先 `plan_spawns` 再 `super._init`(父类 `_init` 会虚调 `_spawn_cell`)。
- 规则:限时 `MATCH_TIME = 300s`;击杀最多者胜,榜首并列返回 0(平局);死亡 2s 复活;开局散点两两环面距 ≥ `SPAWN_CLEARANCE` 15 格,复活点离存活敌人 ≥ `RESPAWN_CLEARANCE` 8 格。出生/复活点主路径 = 地图 `# respawn 1|2` 两侧列表的**并集**(大乱斗无阵营,全图散布;每侧 ≥5 且过半区 3×3 桶覆盖,判据见 [world.md](world.md));**缺数据时**回退 `SpawnPicker` 几何池(出候选取 `spawn_candidates()`:头顶 2 格净空 + 左右邻格空 + 连通区 ≥ `area_threshold()`,纯 4 邻接、不含跳跃 / 梯子)+ `push_warning` 一次。
- 复活池回退序列(仅老图无 `# respawn` 时)`SpawnPicker.respawn_pools()` = `[spawn_candidates(), respawn_fallback(), respawn_last_resort()]`(第 ② 档连通区 ≥ `area_threshold()`,第 ③ 档连通区 ≥ 2、只排除孤立单格);`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for` 的这一层必须读同一份。
- `SpawnPicker` 的池是静态缓存(4 个 cache + 区域表):同一进程里换图重算必须先 `SpawnPicker.reset_cache()`。
- 归因:`_on_bullet_hit` 先 `CombatFeedback.attribute(victim, bullet.shooter)` 再 `super`;`_attributed_killer` 读 meta,时效 `ATTRIB_WINDOW`(3s);无源死亡(溺水 / 坠落)不计分,自杀先清 meta。
- `round_state`(大乱斗版)= `scores` / `deaths` / `names` / `alive` / `left` / `timer` / `match_winner`,昵称行覆盖真人 + 已离开者 + AI 补位。
- 客户端 `scenes/royale_game.gd` / `.tscn`:Level0(`pvp_mode`)+ PostProcess + N-1 个 `PlayerReplica`(按快照 roles 动态建)+ `RoyaleHud` + Minimap + 血条 + 拖尾;本地玩家与 1v1 共用 C2 预测 + `PredictionRollback`;消费 `NetBus.local_*`(snapshot / bullet_spawn / beam_fired / hit_event / tile_destroyed / round_state / peer_info / kill_event)与 `NetBusExt.local_*`(match_options / hit_confirm)。
- 开局三载荷(昵称 / 角色色相 / 生效选项)走进场拉取:对局场景 `_ready` 末尾主动拉,不走推送。`MatchHost.role_spawns()` 是只读取法,`RoyaleHost` 必须覆写。
- 人数上限 `LobbyRooms.ROYALE_MAX_PLAYERS = 16`;单端下行 ∝ N,服务器上行 ∝ N²。
- 输入队列有上限:跟着抖动包络走、逐 tick 衰减,超了丢最旧那包并把 `pressed` / `released` / `winst` 边沿并入队首。读数入口是 `snapshot_own` 的 `q` 与服务端 `--netstat`。
- `--ai-roles` 的 `AINavigator` 用 `host.RoundState.PLAYING` 动态查表。
