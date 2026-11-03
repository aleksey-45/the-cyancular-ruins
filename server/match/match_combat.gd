class_name MatchCombat
extends MatchSnapshot

const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口
const LagComp := preload("res://core/net/lag_comp.gd")     # playout / 回放深度常量(与客户端副本同源)

# 裁决宽相位开关:false(生产默认)= 先 AABB 粗筛再精确;true = 直接精确(旧路径)。
# ★ 只给 tests/probe/bullet_sweep_probe 做新旧等价对比用;改它只影响算力,不影响任何命中结果(见 hit_shape.candidate_hits)。
var adjudicate_exact_only := false
# 每 tick 的回放受击面缓存:shooter_role -> {victim_role: Rect2};所属 tick 见 _hurt_rect_cache_tick。
var _hurt_rect_cache: Dictionary = {}
var _hurt_rect_cache_tick := -1

# 子弹 / 爆炸 / 光束的裁决与广播域;拆墙广播也在这里(它同属「命中/破坏」这条线)。

# 事件的**时间锚点** = 上一次完成步进时的已消费 seq(MatchState._stepped_seq,帧末 deferred 记录)。
func _event_seq_for(role) -> int:
	var fallback := maxi(int(_ack_seq.get(int(role), 0)) - 1, 0)
	return int(_stepped_seq.get(int(role), fallback))


func _on_tile_destroyed(cell: Vector2i) -> void:
# ★ 子格是 16px(v4:64px 格 → 4×4),必须按当前格展开 —— 别用 *2,那是 v3 时代 32px/2×2 的过期口径:
# 会把邻格象限清出洞,而被拆那一格 16 个子格一个都没清(留幽灵墙)。反向换算见 _on_sub_destroyed 的 sub / 4。
# ★★ 必须一起清两处:sub_hp(下一局 build_sim 会按它把墙长回来)+ destructible_sub(本局分块碰撞数组)。
	TileDefs.zero_cell_sub_hp(cell)
	if not destructible_sub.is_empty():
		for sy in 4:
			for sx in 4:
				destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] = MazeGenerator.EMPTY
				damaged_subs[Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)] = true
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true

	# 拆砖事件带**逐 peer 的 seq 锚点**,客户端把它注入预测历史(2026-11-01 R2)。★ 不能 _rpc_all:锚点逐 peer 不同。
	for r in peer_by_role:
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "tile_destroyed", cell, _event_seq_for(r))


# 16px 子格被摧毁:清持久子格 + 标记分块重建 + 广播;owner(射手节点)映射成 role,Beta 时间玩法在这里结算拆砖得颗粒。
func _on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	damaged_subs[sub] = true
	if not destructible_sub.is_empty() 			and sub.y >= 0 and sub.y < destructible_sub.size() 			and sub.x >= 0 and sub.x < (destructible_sub[0] as Array).size():
		destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	# 子格事件同样带逐 peer 的 seq 锚点(理由见 _event_seq_for)。
	for r in peer_by_role:
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBusExt.rpc_id(peer_by_role[r], "sub_destroyed", sub, _event_seq_for(r))
	if time_economy != null:
		var role := _role_of(owner)   # 查不到 = -1(不是 0:0 是「无队伍/无归因」的合法值)
		if role >= 0:
			time_economy.award_blocks(role, 1)



func _adjudicate_bullets() -> void:
	# 命中回放采样必须在本帧裁决之前推(含当前 tick):裁决读的就是"射手观看时刻"那一帧的受击面。
	_push_lag_frame()
	# 回放受击面按 tick 缓存(见 _replay_rect_cached):这一行之后 _lag_hist / _srv_tick / _client_snap_tick 本帧不再变。
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
# 帧末用「本帧在场」的集合替换 _seen_bullets,顺带剪掉已消失的条目。★ 必须剪:大乱斗不换局、永不调 _reset_world_and_clear_dynamics,不剪就整局只增不减。
	var live: Dictionary = {}
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as BulletBase

		var bid: int = bullet.get_instance_id()
		live[bid] = true
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)

		if bullet.shooter == null:
			continue

		if bullet.explodes:
			_adjudicate_grenade(bullet, w, h)
			continue
# 命中裁决:子弹上一位置→当前位置的线段 vs 玩家受击面(与客户端 cull / 单机子弹同一套 hit_shape)。★ 队友穿透用 continue 而不是 break —— 队友不挡弹道,后面若有敌人照样打得到。
		var shooter_role := _role_of(bullet.shooter)
# ★ 扫掠参数每颗子弹算一次:prev/cur 全程不变,hit_grow() 要查碰撞体 + 三角函数,放进玩家循环里是每颗 × 每人白烧。
		var prev := bullet.prev_pos
		var cur := bullet.global_position
		var grow := bullet.hit_grow()
		for role in players:
			var p := players[role] as Player
			if p == bullet.shooter:
				continue
			if same_team(shooter_role, int(role)):
				continue
			if _segment_hits_player(bullet, p, prev, cur, grow, w, h):
				_on_bullet_hit(bullet, p, role)
				break
# 剪枝用替换而不是逐条 erase:两者都是 O(子弹数),替换少一次遍历。
	_seen_bullets = live


# 线段扫掠判命中:受击面来源唯一(Player.hurt_rect → HitShape),不再用中心点距离。
# ★★ 时间域解耦:读**射手观看时刻**的受击面(历史回放),否则"看着中/服务器不中";移动预测仍吃最新态,只影响裁决。
# ★ 宽相位:候选先过 AABB 粗筛(sweep_may_hit 在 hit_shape 内,与精确同一套环面锚点 + grow),过了才进精确。
func _segment_hits_player(bullet: BulletBase, p: Node2D, prev: Vector2, cur: Vector2,
		grow: Vector2, w: float, h: float) -> bool:
	if not HitShape.hurtable(p):
		return false
	var rect := _replay_hurt_rect(bullet, p)
	return HitShape.candidate_hits(prev, cur, rect, w, h, grow, adjudicate_exact_only)


# 射手观看时刻的受击面:st − PLAYOUT_TICKS(夹在 srv−MAX_REWIND..srv);无有效 st(非网络射手/尚未收到快照)或
# 无历史(开局/刚重连)时回退现时受击面 —— AI 补位没有"观看时刻",按现时裁决。
func _replay_hurt_rect(bullet: BulletBase, p: Node2D) -> Rect2:
	var rect := _replay_rect_cached(bullet, p)
	return rect if rect.size != Vector2.ZERO else _live_hurt_rect(p)


# 历史回放那一支(纯函数于 _client_snap_tick / _srv_tick / _lag_hist,三者在一次裁决内都不变)
func _replay_rect_cached(bullet: BulletBase, p: Node2D) -> Rect2:
	if _hurt_rect_cache_tick != _srv_tick:
		_hurt_rect_cache_tick = _srv_tick
		_hurt_rect_cache.clear()
	var shooter_role := _role_of(bullet.shooter)
	var victim_role := _role_of(p)
# ★ 无效 role 的安全阀只有这一处,且判据必须是 `< 0`(_role_of 的哨兵)—— 原写 `== 0` 时它恒假、纯死代码,
# 真正挡住的只有下一行的 peer_by_role.has()。AI 补位没有 peer(靠 has 挡),非玩家射手才是这里挡的那一档。
	if shooter_role < 0 or victim_role < 0 or not peer_by_role.has(shooter_role):
		return Rect2()
	var st := int(_client_snap_tick.get(shooter_role, 0))
	if st <= 0:
		return Rect2()
	var by_victim: Dictionary = _hurt_rect_cache.get(shooter_role, {})
	if by_victim.has(victim_role):
		return by_victim[victim_role]
	var want := clampi(st - LagComp.PLAYOUT_TICKS, _srv_tick - LagComp.MAX_REWIND_TICKS, _srv_tick)
	var rect := _lag_hist.rect_for(victim_role, want)
	by_victim[victim_role] = rect
	_hurt_rect_cache[shooter_role] = by_victim
	return rect


# 现时受击面(回退口径):读当前姿态/位置,不缓存。
func _live_hurt_rect(p: Node2D) -> Rect2:
	var pl := p as Player
	return pl.hurt_rect() if pl != null else HitShape.hurt_rect_of(p)


# 每物理 tick 把全员「位置 + 相对受击面」记进历史环;只记判定几何(不记姿态/朝向),内存 = 24 tick × 人数。
func _push_lag_frame() -> void:
	var entries: Dictionary = {}
	for role in players:
		var p := players[role] as Player
		if p == null or not is_instance_valid(p):
			continue
		var rect: Rect2 = p.hurt_rect()
		entries[int(role)] = {
			"p": p.global_position,
			"r": Rect2(rect.position - p.global_position, rect.size),
		}
	_lag_hist.push(_srv_tick, entries)

# 爆炸弹对玩家的权威判定:只结算一次「直接命中」,不销毁子弹 —— 物理掩码已不含玩家,命中全靠这里的线段扫掠;
# 销毁会把引信一起吞掉(爆炸永不触发)。引信由 bullet_base._check_player_contact 两端同源起,这里只补权威伤害 + 射手端反馈。

func _adjudicate_grenade(bullet: BulletBase, w: float, h: float) -> void:
	if bullet.shooter == null:
		return   # 敌方爆炸弹(理论上只有敌方弹药):同普通弹的 shooter == null 分支,不补刀
	if bullet.has_meta("grenade_direct_hit"):
		return   # 榴弹会在判定框内连续穿行好几帧,只结算第一次
	var prev := bullet.prev_pos
	var cur := bullet.global_position
	var grow := bullet.hit_grow()
	for role in players:
		var p := players[role] as Player
		if p == bullet.shooter:
			continue
# ★ 直击穿透队友(与普通弹同口径)。★ 别顺手把爆炸也豁免:用户裁定子弹穿透队友、爆炸对队友满效
# (伤害 + 击退都照吃;爆炸走 Explosion.apply_aoe,那条路径按现状不动)。
		if same_team(_role_of(bullet.shooter), int(role)):
			continue
		if _segment_hits_player(bullet, p, prev, cur, grow, w, h):
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: BulletBase, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
# ★ 归因先于伤害(全仓纪律):一击致死时倒地边沿同帧读 last_damager,大乱斗靠它计击杀分。
	CombatFeedback.attribute(victim, bullet.shooter)
	var pl := victim as Player
	if pl != null:

		pl.take_hit(bullet.global_position, bullet.direct_hit_damage, false, bullet.hit_impact)

	notify_direct_hit(bullet.shooter, victim)


func _broadcast_bullet_spawn(bullet: CharacterBody2D) -> void:
	var scene_path := ""
	if bullet.scene_file_path != "":
		scene_path = bullet.scene_file_path
	elif bullet.has_meta("scene_path"):
		scene_path = bullet.get_meta("scene_path")

	var canonical_pos := MazeGenerator.wrap_to_range(bullet.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
# 射手 role:既用于排除广播对象,也随载荷下发 —— 接收端要把视觉副本的 shooter 指向射手副本(否则榴弹的
# _check_player_contact 会在出膛那一刻把射手自己的副本当成目标、当场起短引信),并按它做队友豁免。协议只传 canonical [0,MAP)。
	var shooter_role := _role_of(bullet.shooter)
	var data := {
		"scene": scene_path,
		"shooter_role": shooter_role,
		"pos": canonical_pos,
		"vel": bullet.velocity_vec,
		"speed": bullet.speed,
		"range": bullet.max_range,
		"size": bullet.size,
		"color": bullet.bullet_color,
		"gravity": bullet.gravity_factor,
		"hit_damage": bullet.hit_damage,
		"hit_impact": bullet.hit_impact,
		"explodes": bullet.explodes,
		"direct_damage": bullet.direct_hit_damage,
		"fuse": bullet.fuse_time,
		"hit_fuse": bullet.hit_fuse_time,
		"radius": bullet.explosion_radius,
		"expl_damage": bullet.explosion_damage,
		"expl_knock": bullet.explosion_knockback,
	}
	if bullet.explosion_visual != null:
		data["visual"] = bullet.explosion_visual.resource_path

	_rpc_all("bullet_spawn", [data], shooter_role)

# 光束权威开火上报:每物理帧轮询各角色当前武器。★ 时序与子弹同款 —— MatchHost 父先于子,这里读到的是上一
# 物理帧记下的上报(光束 0.25s 存续,晚 1 tick 无感);COUNTDOWN 不喂输入 ⇒ 无上报,天然冻结。

func _broadcast_pending_beams() -> void:
	for role in players:
		var p := players[role] as Player
		if p == null or p.weapons == null:
			continue

		var w: Variant = p.weapons.current_weapon()
		if w == null or not w.has_method("collect_pending_beam_report"):
			continue
		var rep: Dictionary = w.collect_pending_beam_report()
		if rep.is_empty():
			continue
		_broadcast_beam_fired(int(role), rep)


func _broadcast_beam_fired(shooter_role: int, rep: Dictionary) -> void:
	rep["shooter_role"] = shooter_role

	_rpc_all("beam_fired", [rep], shooter_role)

# 光束直击:服务器结算后把 X 标记(hit_confirm)发给射手本人 —— 与子弹同链路;爆炸 AoE 不发(伤害方不明确)。

func notify_direct_hit(shooter: Node, victim: Node) -> void:
	var shooter_role := _role_of(shooter)
	var victim_role := _role_of(victim)
	if shooter_role < 0 or victim_role < 0 or shooter_role == victim_role:
		return
# ★ 判活走 NetBus.is_peer_live(读 ENet peer 自己的 state),不是 get_peers():后者滞后,挡不住往已拆掉的 peer 发定向包(那条 channel 0 错误)。
	if peer_by_role.has(shooter_role) and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, victim_role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
# ★★ 归因先于伤害(全仓纪律)。★ 这一行必须住在基类:1v1 走 MatchBootstrap.start_on 直接建 MatchHost(全仓唯一
# 实例化点),没有子类那层覆写 ⇒ 原先 1v1 的子弹不进 dealt / taken,结算页显示「击杀 5 / 造成 0 / 承受 0」。
	CombatFeedback.attribute(victim, bullet.shooter)
	var pl := victim as Player
	if pl != null:

		pl.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)

	var shooter_role := _role_of(bullet.shooter)
	if shooter_role >= 0 and peer_by_role.has(shooter_role) \
			and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, _victim_role)
	bullet.queue_free()

# 玩家受击反馈:实际扣血后广播 hit_event;客户端按 victim_role 分支(自己 → 白闪/击退,对手 → 闪烁)。bind(role) 的参数追加在信号参数之后。

func _on_player_hit(source_pos: Vector2, damage: int, cause: String, role: int) -> void:
# ★ 查不到的 role 是 -1(_role_of 的哨兵):放进去会让 _stat_entry(-1) 造出一行假统计(role=-1 不进任何名单)。
	if role < 0:
		return
# ★ 客户端已本地预测的伤害(落水窒息,cause="water")不回声:两端跑同一份 _tick_underwater,再广播 hit_event 会让客户端二次应用。
#   这也顺带排除"无攻击者"的来源进 dealt/taken 统计(窒息本来就没有 attacker)。判据与单一来源见 player.gd 的溺水调用。
	if cause == "water":
		return
# ★ 一个钩子覆盖全部伤害来源(子弹/榴弹直击/爆炸 AoE/激光):共同点是「归因写入都先于 take_hit」,于是 took_hit 这一刻读 meta 就是攻击者。
	var stat_victim: Node2D = players.get(int(role))
	var stat_self := stat_victim != null and is_instance_valid(stat_victim) \
			and CombatFeedback.is_fresh_self_hit(stat_victim, ATTRIB_FRESH_MS)
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0:
# 助攻表:所有归因得到的命中都记一笔(含队友误伤 —— 读端按 same_team 过滤)。
		_note_hit(int(role), stat_attacker)
		if not same_team(stat_attacker, int(role)):
# dealt / taken 口径对称(spec §3.1):都只算敌人 —— 队友炸我不进 taken、自伤两列都不进(代价走下面的惩罚账);
# ★ 1v1 / 大乱斗队伍表空 ⇒ same_team 恒 false ⇒ 这两列就等于「对所有人的伤害」,不需要特判(别去优化它)。
# ★ 不进这两列的三档:自伤 → 自己的 self_damage;队友伤害 → 肇事者的 team_damage;归因不到 → 哪儿都不记。
			var sa := _stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
# ── 惩罚的两笔账:只减分,不进 dealt / taken(spec §3.5)。★ 自伤优先:自伤时 meta 通常还挂着上一名敌人(或为空),
# 真同时成立时按自伤记。⚠ 已知边界(不修):同一笔伤害会同时进 dealt(给那位敌人)与 self_damage —— 两个账户,不是双计。
	if stat_self:
		var ss := _stat_entry(int(role))
		ss["self_damage"] = int(ss["self_damage"]) + int(damage)
	elif stat_attacker != 0 and same_team(stat_attacker, int(role)):
		var sm := _stat_entry(stat_attacker)
		sm["team_damage"] = int(sm["team_damage"]) + int(damage)
# Beta 时间玩法:伤害入账(每点 × damage_gain),窗口用 ATTRIB_WINDOW(3s)而不是逐人统计那个 ATTRIB_FRESH_MS(8ms)—— 两者答的是两个问题(见 match_state.gd 两个常量的注释)。
	if time_economy != null and damage > 0 and stat_victim != null:
		var rw_attacker := _attributed_role_within(stat_victim, ATTRIB_WINDOW)
		if rw_attacker != 0 and rw_attacker != int(role) and not same_team(rw_attacker, int(role)):
			time_economy.award_damage(rw_attacker, int(role), damage)
	# 受击事件的时间锚点见 _event_seq_for(逐 peer 不同 ⇒ 下面必须点对点发)。
	var hit_seq := _event_seq_for(role)
	for r in peer_by_role:

		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos, hit_seq)





func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0


