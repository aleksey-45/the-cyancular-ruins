class_name MatchCombat
extends MatchSnapshot

# 子弹/爆炸/光束的裁决与广播域(阶段 5.6 拆自 server/match_host.gd)。
# 含拆墙广播 —— 它同样是"命中/破坏"这条线上的事件。

func _on_tile_destroyed(cell: Vector2i) -> void:
	# 服务器无瓦片渲染层,只需清持久子格 + 标记分块重建
	if not destructible_sub.is_empty():
		for qy in range(2):
			for qx in range(2):
				destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	# 广播拆墙给双方客户端:客户端子弹是视觉副本(apply_damage=false)不判伤害,
	# 服务器拆的墙必须由事件驱动客户端清瓦片渲染,否则建筑"看着没被炸坏"。
	_rpc_all("tile_destroyed", [cell])

# 快照:canonical 坐标(玩家在服务器上始终 wrap_to_range 到 [0,MAP))。unreliable,30Hz。
# 带递增序号 tick:客户端靠它丢弃乱序到达的旧快照(unreliable 通道可能乱序)。

func _adjudicate_bullets() -> void:
	# 本帧在场子弹的 id 集合:帧末用它**替换** _seen_bullets —— 顺带剪掉已消失子弹的条目。
	# 必须剪:大乱斗没有换局,_reset_world_and_clear_dynamics 永不调用,不剪就是整局只增不减
	# (每颗子弹一条 int→bool;量不大,但那是"记住了一个再也不会读的 id")。
	var live: Dictionary = {}
	for b in get_tree().get_nodes_in_group("bullet"):
		if not is_instance_valid(b):
			continue
		var bullet := b as CharacterBody2D
		# 新子弹:广播给非射手客户端(射手已本地生成视觉)
		var bid: int = bullet.get_instance_id()
		live[bid] = true
		if not _seen_bullets.has(bid):
			_seen_bullets[bid] = true
			_broadcast_bullet_spawn(bullet)
		# 敌方子弹(无射手):服务器物理已裁决(撞玩家→take_hit),只广播视觉、不做半径补刀。
		if bullet.shooter == null:
			continue
		# 爆炸弹(榴弹等):不走半径补刀**销毁**(见 _adjudicate_grenade),但要做一次
		# 「直接命中玩家」结算 —— 短引信已由 bullet_base._check_player_contact 起(两端同源)。
		if bullet.explodes:
			_adjudicate_grenade(bullet)
			continue
		# 命中裁决:对非射手玩家算 toroidal 距离
		for role in players:
			var p: Node2D = players[role]
			if p == bullet.shooter:
				continue
			var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < HIT_RADIUS:
				_on_bullet_hit(bullet, p, role)
				break
	# 剪枝:替换成"本帧仍在场"的集合(等价于删掉已销毁子弹的条目)。
	# 用替换而不是逐条 erase:两者都是 O(子弹数),替换少一次遍历。
	_seen_bullets = live

# 爆炸弹(榴弹等)对玩家的权威判定:只结算一次「直接命中」,**不销毁子弹**。
# 为什么不销毁:子弹碰撞掩码不含玩家层、永远碰不到玩家身体,命中判定全靠这里的半径;
# 而销毁会把引信一起吞掉、爆炸永不触发 → 榴弹命中玩家却无爆炸伤害。
# 引信不在这里起 —— bullet_base._check_player_contact 用同一半径、同一候选集在两端各判一次
# (客户端那份视觉副本靠它同刻起爆),这里只补它做不了的两件事:权威伤害 + 射手端反馈。

func _adjudicate_grenade(bullet: CharacterBody2D) -> void:
	if bullet.shooter == null:
		return   # 敌方爆炸弹(理论上只有敌方弹药):同普通弹的 shooter == null 分支,不补刀
	if bullet.has_meta("grenade_direct_hit"):
		return   # 40px 判定圈会被榴弹连续穿过好几帧,只结算第一次
	for role in players:
		var p: Node2D = players[role]
		if p == bullet.shooter:
			continue
		var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < HIT_RADIUS:
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: CharacterBody2D, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
	# ★归因先于伤害(与子弹 _on_bullet_hit / 爆炸同纪律):一击致死时倒地边沿同帧读
	# last_damager,大乱斗靠它计击杀分。
	CombatFeedback.attribute(victim, bullet.shooter)
	if victim.has_method("take_hit"):
		# 受击反馈统一走 combat.took_hit → MatchHost._on_player_hit 广播 hit_event(子弹/鸟/爆炸同源)
		victim.take_hit(bullet.global_position, bullet.direct_hit_damage, false, bullet.hit_impact)
	# 射手端 X 标记(复用激光那条):榴弹直击有明确射手,与子弹的 hit_confirm 同口径
	notify_direct_hit(bullet.shooter, victim)


func _broadcast_bullet_spawn(bullet: CharacterBody2D) -> void:
	var scene_path := ""
	if bullet.scene_file_path != "":
		scene_path = bullet.scene_file_path
	elif bullet.has_meta("scene_path"):
		scene_path = bullet.get_meta("scene_path")
	# 协议只传 canonical [0,MAP):子弹锚到射手最近副本后可能是副本偏移坐标,归位。
	var canonical_pos := MazeGenerator.wrap_to_range(bullet.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var data := {
		"scene": scene_path,
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
	# 发给非射手客户端(bullet.shooter 是 Node,反查成 role 才能交给 _rpc_all)
	_rpc_all("bullet_spawn", [data], _role_of(bullet.shooter))

# 即时光束武器(激光)权威开火上报:每物理帧轮询各角色当前武器,把"本帧要广播的光束"发给非射手端。
# 时序与子弹广播同款:MatchHost 父先于子 → 这里读到的是上一物理帧玩家步进里 fire 记下的上报,
# 晚 1 tick 无感(光束 0.25s 存续)。COUNTDOWN 不喂输入 → 无 fire → 无上报,天然冻结。
# 非光束武器没有 collect_pending_beam_report(has_method 守卫跳过)。换枪 free 旧武器时上报随节点消失。

func _broadcast_pending_beams() -> void:
	for role in players:
		var p: Node2D = players[role]
		if p == null or p.weapons == null:
			continue
		# w 显式 Variant:collect_pending_beam_report 只存在于 LaserWeaponBase 子类(不在 WeaponBase 上)
		var w: Variant = p.weapons.current_weapon()
		if w == null or not w.has_method("collect_pending_beam_report"):
			continue
		var rep: Dictionary = w.collect_pending_beam_report()
		if rep.is_empty():
			continue
		_broadcast_beam_fired(int(role), rep)


func _broadcast_beam_fired(shooter_role: int, rep: Dictionary) -> void:
	rep["shooter_role"] = shooter_role
	# 只发给非射手端:射手自己客户端已本地预测画自己的光束,再收会双光束。
	_rpc_all("beam_fired", [rep], shooter_role)

# 即时光束武器(激光)的直击命中:服务器结算后把 X 标记(hit_confirm)发给射手本人,
# 与子弹 _on_bullet_hit 的 hit_confirm 同链路(爆炸 AoE 不发——伤害方不明确,激光方向明确可发)。

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
	if peer_by_role.has(shooter_role):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, victim_role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	if victim.has_method("take_hit"):
		# 受击反馈广播统一走 combat.took_hit → _on_player_hit(子弹/鸟/爆炸同源,避免重复)
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	# 命中确认(NetBusExt):告诉射手"你打中了"→ 客户端屏幕中心 X 标记。只发射手本人;
	# RoyaleHost 覆写先写归因 meta 再 super 到这里,大乱斗同样生效。
	var shooter_role := 0
	for r in players:
		if players[r] == bullet.shooter:
			shooter_role = int(r)
			break
	if shooter_role != 0 and peer_by_role.has(shooter_role) \
			and multiplayer.get_peers().has(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, _victim_role)
	bullet.queue_free()

# 玩家受击反馈:实际扣血(子弹/鸟接触/鸟弹/爆炸) → 广播 hit_event 给两端客户端。
# 客户端按 victim_role:是自己 → 白闪/击退;是对手 → 对手副本受击闪烁。
# bind(role) 在 Godot 里把绑定参数追加在信号参数之后 → 实际入参顺序为 (source_pos, damage, role)。

func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	for r in peer_by_role:
		NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)

# ── 回合制 ──

# 某角色的对手 role(1v1,players 恰两个角色;找不到返回 0)。

func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0

# 本局角色出生点(换边感知):首局 _side_swap=false → P1=player/P2=player2;换边后交换。
