class_name MatchCombat
extends MatchSnapshot

# 子弹 / 爆炸 / 光束的裁决与广播域;拆墙广播也在这里(它同属「命中/破坏」这条线)。

func _on_tile_destroyed(cell: Vector2i) -> void:
# ★ 子格是 16px(v4:64px 格 → 4×4),必须按当前格展开 —— 别用 *2,那是 v3 时代 32px/2×2 的过期口径:
# 会把邻格象限清出洞,而被拆那一格 16 个子格一个都没清(留幽灵墙)。反向换算见 _on_sub_destroyed 的 sub / 4。
# ★★ 必须一起清两处:sub_hp(下一局 build_sim 会按它把墙长回来)+ destructible_sub(本局分块碰撞数组)。
	TileDefs.zero_cell_sub_hp(cell)
	if not destructible_sub.is_empty():
		for sy in range(4):
			for sx in range(4):
				destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true

	_rpc_all("tile_destroyed", [cell])


# 16px 子格被摧毁:清持久子格 + 标记分块重建 + 广播;owner(射手节点)映射成 role,Beta 时间玩法在这里结算拆砖得颗粒。
func _on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	if not destructible_sub.is_empty() 			and sub.y >= 0 and sub.y < destructible_sub.size() 			and sub.x >= 0 and sub.x < (destructible_sub[0] as Array).size():
		destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	_rpc_all_ext("sub_destroyed", [sub])
	if time_economy != null:
		var role := _role_of_node(owner)
		if role != 0:
			time_economy.award_blocks(role, 1)



func _adjudicate_bullets() -> void:
# 帧末用「本帧在场」的集合替换 _seen_bullets,顺带剪掉已消失的条目。★ 必须剪:大乱斗不换局、永不调 _reset_world_and_clear_dynamics,不剪就整局只增不减。
	var live: Dictionary = {}
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as CharacterBody2D

		var bid: int = bullet.get_instance_id()
		live[bid] = true
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)

		if bullet.shooter == null:
			continue

		if bullet.explodes:
			_adjudicate_grenade(bullet)
			continue
# 命中裁决:对非射手玩家算 toroidal 距离(射手 role 只在循环外查一次)。★ 队友穿透用 continue 而不是 break —— 队友不挡弹道,后面若有敌人照样打得到。
		var shooter_role := _role_of(bullet.shooter)
		for role in players:
			var p: Node2D = players[role]
			if p == bullet.shooter:
				continue
			if same_team(shooter_role, int(role)):
				continue
			var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < HIT_RADIUS:
				_on_bullet_hit(bullet, p, role)
				break
# 剪枝用替换而不是逐条 erase:两者都是 O(子弹数),替换少一次遍历。
	_seen_bullets = live

# 爆炸弹对玩家的权威判定:只结算一次「直接命中」,不销毁子弹 —— 碰撞掩码不含玩家层、命中全靠这里的半径,
# 而销毁会把引信一起吞掉(爆炸永不触发)。引信由 bullet_base._check_player_contact 两端同源起,这里只补权威伤害 + 射手端反馈。

func _adjudicate_grenade(bullet: CharacterBody2D) -> void:
	if bullet.shooter == null:
		return   # 敌方爆炸弹(理论上只有敌方弹药):同普通弹的 shooter == null 分支,不补刀
	if bullet.has_meta("grenade_direct_hit"):
		return   # 40px 判定圈会被榴弹连续穿过好几帧,只结算第一次
	for role in players:
		var p: Node2D = players[role]
		if p == bullet.shooter:
			continue
# ★ 直击穿透队友(与普通弹同口径)。★ 别顺手把爆炸也豁免:用户裁定子弹穿透队友、爆炸对队友满效
# (伤害 + 击退都照吃;爆炸走 Explosion.apply_aoe,那条路径按现状不动)。
		if same_team(_role_of(bullet.shooter), int(role)):
			continue
		var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < HIT_RADIUS:
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: CharacterBody2D, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
# ★ 归因先于伤害(全仓纪律):一击致死时倒地边沿同帧读 last_damager,大乱斗靠它计击杀分。
	CombatFeedback.attribute(victim, bullet.shooter)
	if victim.has_method("take_hit"):

		victim.take_hit(bullet.global_position, bullet.direct_hit_damage, false, bullet.hit_impact)

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
		var p: Node2D = players[role]
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
	var shooter_role := -1
	var victim_role := -1
	for role in players:
		if players[role] == shooter:
			shooter_role = int(role)
		if players[role] == victim:
			victim_role = int(role)
	if shooter_role < 0 or victim_role < 0 or shooter_role == victim_role:
		return
# ★ 判活走 NetBus.is_peer_live(读 ENet peer 自己的 state),不是 get_peers():后者滞后,挡不住往已拆掉的 peer 发定向包(那条 channel 0 错误)。
	if peer_by_role.has(shooter_role) and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, victim_role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
# ★★ 归因先于伤害(全仓纪律)。★ 这一行必须住在基类:1v1 走 MatchBootstrap.start_on 直接建 MatchHost(全仓唯一
# 实例化点),没有子类那层覆写 ⇒ 原先 1v1 的子弹不进 dealt / taken,结算页显示「击杀 5 / 造成 0 / 承受 0」。
	CombatFeedback.attribute(victim, bullet.shooter)
	if victim.has_method("take_hit"):

		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)

	var shooter_role := 0
	for r in players:
		if players[r] == bullet.shooter:
			shooter_role = int(r)
			break
	if shooter_role != 0 and peer_by_role.has(shooter_role) \
			and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, _victim_role)
	bullet.queue_free()

# 玩家受击反馈:实际扣血后广播 hit_event;客户端按 victim_role 分支(自己 → 白闪/击退,对手 → 闪烁)。bind(role) 的参数追加在信号参数之后。

func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
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
	for r in peer_by_role:

		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)





func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0


