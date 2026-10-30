# 对局模式(3v3 / 结算页 / 大乱斗)

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 3v3 团队模式

- 启动契约(`server_main.gd` 文件头):`--worker --team --port P --roles r,… --teams t,…`。`roles` 与 `teams` 同序等长(第 i 个 role 的队号 = `teams[i]`);满员才开、不降级;`--royale` 与 `--team` 同时为真直接拒启动。
- 队伍表经 `match_sync` 的 `teams`(`TeamHost.team_map()` 的只读副本)下发,只在非空时带该键,不进 `round_state`。`MatchState._team_of` 就是这张表,不从 role 号推导;满员判据取 `_team_of_role.size()`,不是 `_role_set.size()`。
- `same_team()`:任一方 0 → false(0 = 查不到队伍),`same_team(0, 0)` 也是 false。
- 子弹穿透队友、爆炸对队友满效(爆炸走 `_explode()` → `Explosion.apply_aoe`,玩家分支不看队伍)。`same_team` 在 `server/match/match_combat.gd` 的 `_adjudicate_bullets` / `_adjudicate_grenade` 两处;`_check_player_contact` 只排除射手、不看队伍。
- 激光也穿透队友:`MatchState.is_friendly(a, b)` + `LaserWeaponBase._damage_path_targets` 玩家循环里一条 `continue`(不是 `break`,队友身后的敌人照打)。只改权威侧。
- 助攻与惩罚计数(`assists` / `team_damage` / `self_damage` / `team_kills`)只影响 `kscore`,不进 `dealt` / `taken`。助攻表 `MatchState._assist_times` = `victim_role -> {attacker_role: 时刻ms}`;写入口 `_note_hit`(由 `MatchCombat._on_player_hit` 调);判定在 `_record_down`(除击杀者外、窗口内、且 `same_team(attacker, killer)`);清空在 `MatchRound._respawn_player`;窗口复用 `ATTRIB_WINDOW`(3s)。队伍表为空 ⇒ 1v1 / 大乱斗拿不到助攻。
- 惩罚 = `(team_damage + self_damage) ÷ 5 + team_kills × 100`(`ScoreRules.penalty`),记在肇事者行上。
- 自伤专用通道:`CombatFeedback.note_self_hit` / `is_fresh_self_hit`,由 `Explosion.apply_aoe` 在 `shooter == victim` 时写;窗口 8ms;落地一笔真实归因时在 `attribute()` 里 `remove_meta("last_self_hit_time")`。
- 3v3 击杀后不复位任何人。1v1 的 `_reset_survivor` 与大乱斗保留。
- 掉线判据:整队走光才终局(`TeamHost.mark_disconnected`)。`server_main._expire_graces` 两处判据都必须带 `_team_mode`:分派 `GraceWindow.expire_action(_royale, _team_mode)` 必须与 `ACTION_REMOVE` 比较;末尾全员走光退出是 `(_royale or _team_mode) and …`。
- 3v3 有 K 键自杀:`TeamHost.request_suicide_role`;闸在 `server_main._on_suicide_request` 首行 `if not (_royale or _team_mode) or _host == null: return`;覆写必须留在 `TeamHost`。
- 3v3 满 6 人才开:超时梯 `_understaffed_wait > 30.0` → 打印超时 → `quit(0)`;满员判据 `_claims.size() >= _team_of_role.size()`;大厅闸门 `LobbyRooms.team_ready` / `team_room_ready`。
- 分队碰撞层:队 B 身体层 = `TeamHost.TEAM_ENEMY_LAYER := 16`(不许写死);副本幽灵体 `mask` 恒 0,`layer` 按代表玩家的队;服务端 `TeamHost._apply_team_layers` 与客户端 `team_game._apply_team_collision` 逐值对齐。掩码必须保留地形(1)与敌人(4);未知队号客户端落层 2、服务端什么都不配;副本懒建,`_ensure_replica` 里要再刷一遍。
- 平局:`match_winner == 0` 在 3v3 可达(两队都走光)。`ui/hud/team_hud.gd` 念「平 局」;`pvp_hud.gd` 的 1v1 兜底不能照抄到 3v3。
- 输赢文案由 `set_my_team()` 驱动:`_apply_teams` 在队伍表到达后必须调 `_hud.set_my_team(_team_of_role(PvpSession.role))`;队号只能从队伍表读,不是 role。
- 队色 = `modulate = 队色 / 本体主色`(`_apply_tint` 的 `color_override` 非透明时走);`BODY_BASE_COLOR = #639BFF`(`player.png` 的不透明众数色);队 1 的比值恰为 (1,1,1)(`C_TEAM_A` 就是它),队 2 有分量 > 1。换 sprite 素材要重测 `BODY_BASE_COLOR`。3v3 的 `hues` 是无效输入:`_apply_peer_hues_or_team` 覆写基类钩子、只消费载荷里的 `teams`,自己那具也走队色,`_apply_peer_hues` 不会被调用。
- `player_p2_hue.gdshader` 的 `COLOR` 入参已含纹理:只覆写 `COLOR.rgb`,`COLOR.a` 不动;uniform 默认 `0.0`(不改色)。
- 换边后客户端在**新一轮 COUNTDOWN** 重拉一次 `match_sync`,先置 `_resync_pull_pending = true` 再发;与重连补态共用同一个标志,不新立标志。
- `TeamHost._on_bullet_hit` 覆写先 `CombatFeedback.attribute(victim, bullet.shooter)` 再 `super`;基类 `MatchCombat._on_bullet_hit` 也写同一笔(幂等)。基类那行是 1v1 的唯一子弹归因写端,不可删。
- 逐人数据:离开者用 `MatchState.note_disconnect_round(role)`(`_enter_grace` 掉线那一刻记录);MATCH_OVER 之后倒地不进 `_stats`,ROUND_OVER 期间照旧入账。

## 结算页

- `ui/screens/match_result.gd`(`MatchResult`,CanvasLayer)模式无关;模式差异全部由 `ui/screens/match_result_payload.gd` 的三个适配器(`for_duel` / `for_royale` / `for_team`)折成一个载荷字典。`columns` 由数据决定。
- 列:`C_DUEL = [kills, deaths, dealt, taken, acs]` / `C_ROYALE = [kills, deaths, dealt, taken]` / `C_TEAM = [kills, deaths, assists, dealt, taken, acs]`;标题在 `ui/screens/match_result.gd::COLUMN_TITLES`。
- 载荷字段集 `{kills, deaths, assists, dealt, taken, kscore, acs}`;口径收在 `core/sim/score_rules.gd`(`ScoreRules`,纯静态):`kscore = 击杀×100 + 助攻×50 + 伤害÷5 − 死亡×50 − 惩罚`,`acs = kscore ÷ 局数`;读端不得再加伤害。
- 投递点:`1v1 server/match/match_round.gd` / 大乱斗 `server/hosts/royale_host.gd` / 3v3 `server/hosts/team_host.gd`。1v1 的击杀记给对手且不看归因;大乱斗是归因制,无归因的死亡不计任何人的击杀。
- `leave_requested` 只发一次(`_leaving` 防重入);离场走 `Level0.safe_change_scene`,不裸 `change_scene_to_file`。
- ESC:对局中 = 暂停菜单,结算页 = 返回主菜单。三个客户端的 MATCH_OVER 块都 `_pause_menu.queue_free()`;删掉这两行会让 ESC 在结算页同时触发两件事。
- 层位 150 只写在 `ui/screens/match_result.tscn` 里,只能从场景实例化,不 `MatchResult.new()`。
- 挂载 / 离场收在基类 `PvpMatchClient` 的 `_show_result` / `_leave_to_main_menu`,三个客户端只各覆写 `_build_result_payload()`。`_show_result` 每次都要刷新(`if _result == null` 只包住「建 + 连线」)。
- 第二条 MATCH_OVER 载荷可达:reclaim 成功会重播 `round_state`;`TeamHost._finish_match` 直接 PLAYING→MATCH_OVER;倒地边沿检测在 `_round_state` 之前且不看状态。

## 大乱斗(Royale)

- 入口:主菜单那颗「多 人 模 式」→ `scenes/mp_lobby.tscn`;从哪个模式进由 `_current_mode` 分派,没有静态标记。
- 房间:`LobbyRooms` 的 `RoyaleRoom` 注册表,与 1v1 的 `rooms` 并存且互斥;建房 / 加入 / 状态广播走 `Wire` 的 `royale_*` RPC。
- 开局:房主 `royale_start`(或 `royale_start_ai`)→ `RoomManager` 调 `WorkerLauncher.spawn_royale_worker(port, roles, ai_roles)`,用 `OS.create_process` 拉起独立 worker:命令行 `--headless --log-file <path> [--path <res> res://server/server_main.tscn] -- --worker --royale --port P --roles 1,3 [--ai-roles r,r]`(editor / template_debug 必须带 `--path` + 场景;与 `server_main.gd` 的 argv 解析逐字对应)。role 集合显式传,不从人数推导;AI 补位号由 `LobbyRooms.royale_free_roles` 取人类未占用的空闲号。
- 开局判据:收齐 `_human_role_count()` 个人类 claim;已到 ≥2 人但 20s 收不齐 → 按已到人数降级开局;可用玩家 <2 人 → 10s 宽限后退出释放端口。`_on_role_claimed` 有报到串线防护:对局已开始 / role 不在 `--roles` 集合内 / role 已被别的 peer 占用 → `disconnect_peer`。开局延到帧末,让同一 poll 里的 `player_options` 先归档。
- 端口归还 `ROYALE_PORT_REUSE_DELAY = 360s`。
- 上界 `ROYALE_MATCH_TIME_CEILING = 1800s`(= 30 分钟 × 60);三环:`settings.gd` 装载 `royale_match_min` 时钳 `[1, 30]` 分钟、`scenes/mp_lobby.gd` 换算成秒下发(该行必须留在 `mp_lobby.gd`)、`scenes/mp_lobby/options_form.gd` 的滑块 `max_value = 15` 且 `value_changed` 不钳位地写 `Settings.royale_match_min`。改钳位 / 换算 / 滑块上限任一处都要回看这个上界。
- 权威 `server/hosts/royale_host.gd`(`RoyaleHost extends MatchHost`):覆写 `_init` / `_spawn_cell` / `_ready` / `_match_round_tick` / `_match_winner` / `_broadcast_round_state` / `_on_bullet_hit` / `_respawn_player`;自有 `set_display_names` / `mark_disconnected` / `request_suicide_role` / `_finish_match` / `_attributed_killer`。`_init` 必须先 `plan_spawns` 再 `super._init`(父类 `_init` 会虚调 `_spawn_cell`)。
- 规则:限时 `MATCH_TIME = 300s`;击杀最多者胜,榜首并列返回 0(平局);死亡 2s 复活;开局散点两两环面距 ≥ `SPAWN_CLEARANCE` 15 格,复活点离存活敌人 ≥ `RESPAWN_CLEARANCE` 8 格;出生候选要求头顶 2 格净空 + 左右邻格空 + 同层连通区 ≥ `SpawnPicker.area_threshold()`(正常 `OPEN_AREA_MIN = 20`,最大连通区 < 20 时按 `ADAPTIVE_RATIO = 0.5` 缩)。判据纯 4 邻接,不含跳跃 / 梯子;池子 `SpawnPicker.spawn_candidates()` 与大乱斗 / 3v3 共用。
- 复活池序列唯一来源 `SpawnPicker.respawn_pools()` = `[spawn_candidates(), respawn_fallback(), respawn_last_resort()]`(第 ② 档连通区 ≥ `area_threshold()`,第 ③ 档连通区 ≥ 2、只排除孤立单格);`RoyaleHost._spawn_cell` / `TeamHost._respawn_cell_for` 必须读这一份。
- `SpawnPicker` 的池是静态缓存(4 个 cache + 区域表):同一进程里换图重算必须先 `SpawnPicker.reset_cache()`。
- 归因:`_on_bullet_hit` 先 `CombatFeedback.attribute(victim, bullet.shooter)` 再 `super`;`_attributed_killer` 读 meta,时效 `ATTRIB_WINDOW`(3s);无源死亡(溺水 / 坠落)不计分,自杀先清 meta。
- `round_state`(大乱斗版)= `scores` / `deaths` / `names` / `alive` / `left` / `timer` / `match_winner`,昵称行覆盖真人 + 已离开者 + AI 补位。
- 客户端 `scenes/royale_game.gd` / `.tscn`:Level0(`pvp_mode`)+ PostProcess + N-1 个 `PlayerReplica`(按快照 roles 动态建)+ `RoyaleHud` + Minimap + 血条 + 拖尾;本地玩家与 1v1 共用 C2 预测 + `PredictionRollback`;消费 `Wire.local_*`(snapshot / bullet_spawn / beam_fired / hit_event / tile_destroyed / round_state / peer_info / kill_event)与 `Wire.local_*`(match_options / peer_hues / hit_confirm)。
- 开局三载荷(昵称 / 角色色相 / 生效选项)走进场拉取:对局场景 `_ready` 末尾主动拉,不走推送。`MatchHost.role_spawns()` 是只读取法,`RoyaleHost` 必须覆写。
- 人数上限 `LobbyRooms.ROYALE_MAX_PLAYERS = 16`;单端下行 ∝ N,服务器上行 ∝ N²。
- 输入队列有上限:跟着抖动包络走、逐 tick 衰减,超了丢最旧那包并把 `pressed` / `released` / `winst` 边沿并入队首。读数入口是 `snapshot_own` 的 `q` 与服务端 `--netstat`。
- `--ai-roles` 的 `AINavigator` 用 `host.RoundState.PLAYING` 动态查表。
