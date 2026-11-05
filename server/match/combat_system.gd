class_name CombatSystem
extends RefCounted

# 子弹 / 爆炸 / 光束的裁决与广播系统(C 方案 S2):只依赖 state + ports。
# 拆墙广播也在这里(同属「命中/破坏」这条线)。

const HitShape := preload("res://core/sim/hit_shape.gd")
const LagComp := preload("res://core/net/lag_comp.gd")

var _state: MatchState = null
var _ports: MatchPorts = null

# 每 tick 的回放受击面缓存:shooter_role -> {victim_role: Rect2};所属 tick 见 _hurt_rect_cache_tick。
var _hurt_rect_cache: Dictionary = {}
var _hurt_rect_cache_tick := -1


func bind(state: MatchState, ports: MatchPorts) -> void:
	_state = state
	_ports = ports


# 事件的时间锚点 = 上一次完成步进时的已消费 seq(帧末 deferred 记录)。
func event_seq_for(role: int) -> int:
	var fallback := maxi(int(_state._ack_seq.get(role, 0)) - 1, 0)
	return int(_state._stepped_seq.get(role, fallback))


func on_tile_destroyed(cell: Vector2i) -> void:
	# 子格是 16px(v4:64px 格 → 4×4),必须按当前格展开;两处一起清(sub_hp + destructible_sub)。
	TileDefs.zero_cell_sub_hp(cell)
	if not _state.destructible_sub.is_empty():
		for sy in 4:
			for sx in 4:
				_state.destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] = MazeGenerator.EMPTY
				_state.damaged_subs[Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)] = true
		_state._dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	# 拆砖事件带逐 peer 的 seq 锚点(不能 _rpc_all:锚点逐 peer 不同)。
	for r in _state.peer_by_role:
		_ports.net_rpc_role.call(int(r), "tile_destroyed", [cell, event_seq_for(int(r))])


func on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	_state.damaged_subs[sub] = true
	var dsub: Array = _state.destructible_sub
	if not dsub.is_empty() and sub.y >= 0 and sub.y < dsub.size() \
			and sub.x >= 0 and sub.x < (dsub[0] as Array).size():
		dsub[sub.y][sub.x] = MazeGenerator.EMPTY
		_state._dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	for r in _state.peer_by_role:
		_ports.net_rpc_role.call(int(r), "sub_destroyed", [sub, event_seq_for(int(r))], true)
	if _state.time_economy != null:
		var role := _state._role_of(owner)
		if role >= 0:
			_state.time_economy.award_blocks(role, 1)


func adjudicate() -> void:
	# 命中回放采样必须在本帧裁决之前推(含当前 tick):裁决读的就是"射手观看时刻"那一帧的受击面。
	_push_lag_frame()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	# 帧末用「本帧在场」的集合替换 _seen_bullets,顺带剪掉已消失的条目(大乱斗不换局,不剪就整局只增不减)。
	var live: Dictionary = {}
	var bullets: Array = _ports.scene_bullets.call()
	for b in bullets:
		if not is_instance_valid(b):
			continue
		var bullet := b as BulletBase
		var bid: int = bullet.get_instance_id()
		live[bid] = true
		if not _state._seen_bullets.has(bid):
			_state._seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)
		if bullet.shooter == null:
			continue
		if bullet.explodes:
			_adjudicate_grenade(bullet, w, h)
			continue
		# 命中裁决:子弹上一位置→当前位置线段 vs 玩家受击面。队友穿透用 continue 而不是 break。
		var shooter_role := _state._role_of(bullet.shooter)
		var prev := bullet.prev_pos
		var cur := bullet.global_position
		var grow := bullet.hit_grow()
		for role in _state.players:
			var p := _state.players[role] as Player
			if p == bullet.shooter:
				continue
			if _state.same_team(shooter_role, int(role)):
				continue
			if _segment_hits_player(bullet, p, prev, cur, grow, w, h):
				_ports.on_bullet_hit.call(bullet, p, int(role))
				break
	_state._seen_bullets = live


func _segment_hits_player(bullet: BulletBase, p: Node2D, prev: Vector2, cur: Vector2,
		grow: Vector2, w: float, h: float) -> bool:
	if not HitShape.hurtable(p):
		return false
	var rect := _replay_hurt_rect(bullet, p)
	return HitShape.candidate_hits(prev, cur, rect, w, h, grow)


func _replay_hurt_rect(bullet: BulletBase, p: Node2D) -> Rect2:
	var rect := _replay_rect_cached(bullet, p)
	return rect if rect.size != Vector2.ZERO else _live_hurt_rect(p)


func _replay_rect_cached(bullet: BulletBase, p: Node2D) -> Rect2:
	if _hurt_rect_cache_tick != _state._srv_tick:
		_hurt_rect_cache_tick = _state._srv_tick
		_hurt_rect_cache.clear()
	var shooter_role := _state._role_of(bullet.shooter)
	var victim_role := _state._role_of(p)
	if shooter_role < 0 or victim_role < 0 or not _state.peer_by_role.has(shooter_role):
		return Rect2()
	var st := int(_state._client_snap_tick.get(shooter_role, 0))
	if st <= 0:
		return Rect2()
	var by_victim: Dictionary = _hurt_rect_cache.get(shooter_role, {})
	if by_victim.has(victim_role):
		return by_victim[victim_role]
	var want := clampi(st - LagComp.PLAYOUT_TICKS, _state._srv_tick - LagComp.MAX_REWIND_TICKS, _state._srv_tick)
	var rect := _state._lag_hist.rect_for(victim_role, want)
	by_victim[victim_role] = rect
	_hurt_rect_cache[shooter_role] = by_victim
	return rect


func _live_hurt_rect(p: Node2D) -> Rect2:
	var pl := p as Player
	return pl.hurt_rect() if pl != null else HitShape.hurt_rect_of(p)


func _push_lag_frame() -> void:
	var entries: Dictionary = {}
	for role in _state.players:
		var p := _state.players[role] as Player
		if p == null or not is_instance_valid(p):
			continue
		var rect: Rect2 = p.hurt_rect()
		entries[int(role)] = {
			"p": p.global_position,
			"r": Rect2(rect.position - p.global_position, rect.size),
		}
	_state._lag_hist.push(_state._srv_tick, entries)


func _adjudicate_grenade(bullet: BulletBase, w: float, h: float) -> void:
	if bullet.shooter == null:
		return   # 敌方爆炸弹:同普通弹的 shooter == null 分支,不补刀
	if bullet.has_meta("grenade_direct_hit"):
		return   # 榴弹会在判定框内连续穿行好几帧,只结算第一次
	var prev := bullet.prev_pos
	var cur := bullet.global_position
	var grow := bullet.hit_grow()
	for role in _state.players:
		var p := _state.players[role] as Player
		if p == bullet.shooter:
			continue
		# 直击穿透队友(与普通弹同口径);爆炸本身对队友满效(走 Explosion.apply_aoe,不在这条路上)。
		if _state.same_team(_state._role_of(bullet.shooter), int(role)):
			continue
		if _segment_hits_player(bullet, p, prev, cur, grow, w, h):
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: BulletBase, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
	# 归因先于伤害(全仓纪律):一击致死时倒地边沿同帧读 last_damager。
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
	var shooter_role := _state._role_of(bullet.shooter)
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
	_ports.net_rpc_role_all.call("bullet_spawn", [data], shooter_role, true, false)


func broadcast_pending_beams() -> void:
	for role in _state.players:
		var p := _state.players[role] as Player
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
	_ports.net_rpc_role_all.call("beam_fired", [rep], shooter_role, true, false)


# 光束直击:服务器结算后把 X 标记(hit_confirm)发给射手本人。
func notify_direct_hit(shooter: Node, victim: Node) -> void:
	var shooter_role := _state._role_of(shooter)
	var victim_role := _state._role_of(victim)
	if shooter_role < 0 or victim_role < 0 or shooter_role == victim_role:
		return
	_ports.net_rpc_role.call(shooter_role, "hit_confirm", [shooter_role, victim_role], true)


# 玩家受击反馈:实际扣血后广播 hit_event(客户端按 victim_role 分支)。
func on_player_hit(source_pos: Vector2, damage: int, cause: String, role: int) -> void:
	if role < 0:
		return
	# 客户端已本地预测的伤害(落水窒息)不回声,否则客户端二次应用;也顺带排除无攻击者伤害进统计。
	if cause == "water":
		return
	var stat_victim: Node2D = _state.players.get(int(role))
	var stat_self := stat_victim != null and is_instance_valid(stat_victim) \
			and CombatFeedback.is_fresh_self_hit(stat_victim, MatchState.ATTRIB_FRESH_MS)
	var stat_attacker := _state._fresh_attacker_role(int(role))
	if stat_attacker != 0:
		_state._note_hit(int(role), stat_attacker)
		if not _state.same_team(stat_attacker, int(role)):
			var sa := _state._stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _state._stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
	if stat_self:
		var ss := _state._stat_entry(int(role))
		ss["self_damage"] = int(ss["self_damage"]) + int(damage)
	elif stat_attacker != 0 and _state.same_team(stat_attacker, int(role)):
		var sm := _state._stat_entry(stat_attacker)
		sm["team_damage"] = int(sm["team_damage"]) + int(damage)
	# Beta 时间玩法:伤害入账(每点 × damage_gain);窗口用 ATTRIB_WINDOW。
	if _state.time_economy != null and damage > 0 and stat_victim != null:
		var rw_attacker := _state._attributed_role_within(stat_victim, MatchState.ATTRIB_WINDOW)
		if rw_attacker != 0 and rw_attacker != int(role) and not _state.same_team(rw_attacker, int(role)):
			_state.time_economy.award_damage(rw_attacker, int(role), damage)
	var hit_seq := event_seq_for(role)
	for r in _state.peer_by_role:
		_ports.net_rpc_role.call(int(r), "hit_event", [role, damage, source_pos, hit_seq])
