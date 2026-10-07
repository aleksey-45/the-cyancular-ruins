class_name MatchCombat
extends MatchSnapshot

# 子弹、爆炸与光束武器判定及战斗事件广播模块。包含场景瓦片破坏同步广播。

func _on_tile_destroyed(cell: Vector2i) -> void:
	# 服务端更新持久化瓦片数据并标记物理分块脏标记
	if not destructible_sub.is_empty():
		for qy in range(2):
			for qx in range(2):
				destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	# 向所有客户端广播瓦片破坏事件
	_rpc_all("tile_destroyed", [cell])


# 16 像素子格被摧毁回调：更新子格状态、标记碰撞分块重建，并向各客户端广播 sub_destroyed 事件。
# 在时间机制下，若存在有效攻击者角色，结算场景破坏收益。
func _on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	if not destructible_sub.is_empty() \
			and sub.y >= 0 and sub.y < destructible_sub.size() \
			and sub.x >= 0 and sub.x < (destructible_sub[0] as Array).size():
		destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	_rpc_all_ext("sub_destroyed", [sub])
	if time_economy != null:
		var role := _role_of_node(owner)
		if role != 0:
			time_economy.award_blocks(role, 1)


func _adjudicate_bullets() -> void:
	# 收集当前帧存活子弹实例 ID，帧末替换 _seen_bullets 集合以回收已销毁条目
	var live: Dictionary = {}
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as CharacterBody2D
		# 新生成的子弹向非射手客户端广播生成事件（射手本地已预测生成）
		var bid: int = bullet.get_instance_id()
		live[bid] = true
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)
		# 无射手的环境子弹通过常规物理碰撞判定，跳过额外判定
		if bullet.shooter == null:
			continue
		# 爆炸弹由专用分支处理直接命中判定与引信引爆
		if bullet.explodes:
			_adjudicate_grenade(bullet)
			continue
		# 常规子弹对非射手敌方角色执行环面距离命中判定
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
	_seen_bullets = live


# 榴弹等爆炸物对角色的直接命中判定：仅结算直击伤害，保留弹体以保证引信正常触发爆炸
func _adjudicate_grenade(bullet: CharacterBody2D) -> void:
	if bullet.shooter == null:
		return
	if bullet.has_meta("grenade_direct_hit"):
		return
	for role in players:
		var p: Node2D = players[role]
		if p == bullet.shooter:
			continue
		if same_team(_role_of(bullet.shooter), int(role)):
			continue
		var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < HIT_RADIUS:
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: CharacterBody2D, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
	# 伤害归因：在造成伤害前记录攻击者元数据
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
	# 坐标规范化至地图区间
	var canonical_pos := MazeGenerator.wrap_to_range(bullet.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
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
	# 向除射手外的所有在线客户端广播生成数据
	_rpc_all("bullet_spawn", [data], shooter_role)


# 即时光束武器（激光）开火上报：轮询各角色当前手持武器中的光束数据并分发给非射手客户端
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


# 直击命中反馈：结算后向射手客户端发送命中确认 RPC，触发屏幕准心命中标记
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
	if peer_by_role.has(shooter_role) and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, victim_role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	# 伤害归因：在造成伤害前写入攻击者信息
	CombatFeedback.attribute(victim, bullet.shooter)
	if victim.has_method("take_hit"):
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	# 命中确认通知
	var shooter_role := 0
	for r in players:
		if players[r] == bullet.shooter:
			shooter_role = int(r)
			break
	if shooter_role != 0 and peer_by_role.has(shooter_role) \
			and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, _victim_role)
	bullet.queue_free()


# 玩家受击回调与结算统计：
# 统一处理子弹、激光与范围爆炸等所有伤害来源的归因记账与受击事件广播
func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	var stat_victim: Node2D = players.get(int(role))
	var stat_self := stat_victim != null and is_instance_valid(stat_victim) \
			and CombatFeedback.is_fresh_self_hit(stat_victim, ATTRIB_FRESH_MS)
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0:
		_note_hit(int(role), stat_attacker)
		if not same_team(stat_attacker, int(role)):
			# 敌对伤害分别累加至造成伤害 dealt 与承受伤害 taken
			var sa := _stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
	# 自伤与友军误伤统计
	if stat_self:
		var ss := _stat_entry(int(role))
		ss["self_damage"] = int(ss["self_damage"]) + int(damage)
	elif stat_attacker != 0 and same_team(stat_attacker, int(role)):
		var sm := _stat_entry(stat_attacker)
		sm["team_damage"] = int(sm["team_damage"]) + int(damage)
	# 时间机制结算：有效敌对伤害按规则比例奖励颗粒
	if time_economy != null and damage > 0 and stat_victim != null:
		var rw_attacker := _attributed_role_within(stat_victim, ATTRIB_WINDOW)
		if rw_attacker != 0 and rw_attacker != int(role) and not same_team(rw_attacker, int(role)):
			time_economy.award_damage(rw_attacker, int(role), damage)
	for r in peer_by_role:
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)


# 获取指定角色的对手编号（1v1 模式专用）
func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0

