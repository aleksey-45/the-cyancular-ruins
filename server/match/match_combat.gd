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


# 16px 子格被摧毁(cyrm v4):清持久子格 + 标记分块重建 + 广播 sub_destroyed 给客户端
# (客户端清 16px 渲染格与本地预测碰撞)。owner = 射手节点 → 映射 role,Beta 时间玩法
# 在这里结算"破坏瓦片得粒子"(B21;普通局 time_economy 为空,只广播)。
func _on_sub_destroyed(sub: Vector2i, _pre_hp: int, owner: Node) -> void:
	if not destructible_sub.is_empty() 			and sub.y >= 0 and sub.y < destructible_sub.size() 			and sub.x >= 0 and sub.x < (destructible_sub[0] as Array).size():
		destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true
	_rpc_all_ext("sub_destroyed", [sub])
	if time_economy != null:
		var role := _role_of_node(owner)
		if role != 0:
			time_economy.award_blocks(role, 1)

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
		# - 队友**穿透**:`continue` 而不是 `break` —— 队友不挡弹道,后面若有敌人照样打得到。
		#   射手 role 只查一次(循环外),别在循环里反复 _role_of。
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
		# - 直击穿透队友(与普通弹同口径)。**切勿随意把爆炸也豁免** —— 设计约定:
		#   子弹穿透队友、爆炸对队友满效(伤害 + 击退都照吃)。爆炸走 Explosion.apply_aoe,
		#   那条路径**按现状不动**(它本来就对所有玩家满效)。
		if same_team(_role_of(bullet.shooter), int(role)):
			continue
		var d := MazeGenerator.toroidal_delta_px(bullet.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d < HIT_RADIUS:
			_grenade_direct_hit(bullet, p)
			break


func _grenade_direct_hit(bullet: CharacterBody2D, victim: Node2D) -> void:
	bullet.set_meta("grenade_direct_hit", true)
	# - 归因先于伤害(与子弹 _on_bullet_hit / 爆炸同纪律):一击致死时倒地边沿同帧读
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
	# 射手 role:① 排除广播对象(原样)② **随载荷下发** —— 接收端要靠它认出"这颗是谁打的"。
	# - 接收端拿它做两件事:把视觉副本的 `shooter` 指向射手副本(否则榴弹的 `_check_player_contact`
	#   会在**出膛那一刻**就把射手自己的副本当成目标、当场起短引信 —— 客户端上那颗敌方榴弹
	#   会"刚飞出来就炸");以及「该停在哪」的队友豁免(3v3)。
	# - 加法式扩展:老客户端忽略未知键,不协商。
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
	# 发给非射手客户端(bullet.shooter 是 Node,反查成 role 才能交给 _rpc_all)
	_rpc_all("bullet_spawn", [data], shooter_role)

# 即时光束武器(激光)权威开火上报:每物理帧轮询各角色当前武器,把"本帧要广播的光束"发给非射手端。
# 时序与子弹广播相同机制:MatchHost 父先于子 → 这里读到的是上一物理帧玩家步进里 fire 记下的上报,
# 晚 1 tick 无感(光束 0.25s 存续)。COUNTDOWN 不注入输入 → 无 fire → 无上报,天然冻结。
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
	# 存活检测走 `NetBus.is_peer_live`(读 ENet peer 自己的 state),不是 `get_peers()`:后者滞后,
	# 挡不住"往已拆掉的 peer 发**定向**包"→ 那条 `Unable to send packet on channel 0`。
	if peer_by_role.has(shooter_role) and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, victim_role)


func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, _victim_role: int) -> void:
	# 注意： 归因**先于伤害**(全仓纪律:一击致死时倒地边沿同帧读 meta,大乱斗靠它计击杀分)。
	#   - 为什么写在**基类**、而不是只写在子类覆写里(2026-09-27 设计约定方案 A):
	#     1v1 走 `MatchBootstrap.start_on` **直接建 `MatchHost`**(全仓唯一实例化点),
	#     **没有**那层覆写  ->  原先 1v1 的子弹(主要伤害来源)不计入 `dealt`/`taken`,
	#     结算页显示 `击杀 5 / 造成 0 / 承受 0`(两列读同一对归因)。
	#   - 顺带闭合的**第二件事**:1v1 原先既然没有写端,`attribute()` 末尾那句
	#     `remove_meta("last_self_hit_time")` 也就永不执行  ->  "自己炸自己之后 8ms 内
	#     被敌人打中"会被记成 `self_damage`(玩家**因为被敌人打中而扣自己的分**)。
	#    ->  基类补这一行,**两件事一起闭合**。守卫:`tests/probe/stats_delivery_probe` ⑦
	#     ((a) 干净子弹链进 dealt/taken;(b) 自伤标记被这一笔当场作废)。
	#   - `RoyaleHost` / `TeamHost` 的同名覆写**仍然留着**:它们与这里现在写法重复,
	#     而 `attribute()` 是幂等的纯元数据写入,重复调用无害;删它们会一并作废
	#     docs/eng/modes.md 与 `team_host_probe` 上以那两处覆写为锚点的整段登记 —— 不值得。
	CombatFeedback.attribute(victim, bullet.shooter)
	if victim.has_method("take_hit"):
		# 受击反馈广播统一走 combat.took_hit → _on_player_hit(子弹/鸟/爆炸同源,避免重复)
		victim.take_hit(bullet.global_position, bullet.hit_damage, false, bullet.hit_impact)
	# 命中确认(NetBusExt):告诉射手"你打中了" → 客户端屏幕中心 X 标记。只发射手本人。
	var shooter_role := 0
	for r in players:
		if players[r] == bullet.shooter:
			shooter_role = int(r)
			break
	if shooter_role != 0 and peer_by_role.has(shooter_role) \
			and NetBus.is_peer_live(peer_by_role[shooter_role]):
		NetBusExt.rpc_id(peer_by_role[shooter_role], "hit_confirm", shooter_role, _victim_role)
	bullet.queue_free()

# 玩家受击反馈:实际扣除生命值(子弹/鸟接触/鸟弹/爆炸) → 广播 hit_event 给两端客户端。
# 客户端按 victim_role:是自己 → 白闪/击退;是对手 → 对手副本受击闪烁。
# bind(role) 在 Godot 里把绑定参数追加在信号参数之后 → 实际入参顺序为 (source_pos, damage, role)。

func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	# ── 逐人统计(三模式共用;-  2026-09-25 从 `TeamHost._on_player_hit` 上提)──
	# 一个钩子覆盖**全部**伤害来源(子弹 / 榴弹直击 / 爆炸 AoE / 激光):它们的共同点是
	# "归因写入 `CombatFeedback.attribute` 都在 `take_hit` 之前"(本仓明文纪律,见
	# core/sim/explosion.gd:62 与 scenes/weapons/laser_weapon_base.gd:233),于是
	# `took_hit` 这一刻读 meta 就拿到攻击者。**不必去改 `Explosion` 的伤害逻辑**。
	# - "覆盖全部来源"说的是**钩子**;**归因写端**如今也是齐的 —— 子弹直击的 `attribute`
	#   由基类 `_on_bullet_hit` 自己写(2026-09-27 设计约定方案 A:补齐 1v1 缺的那一层覆写),
	#   爆炸 / 榴弹直击 / 激光各自照旧写。 ->  四条伤害来源在**三个模式**下都进 `dealt`/`taken`。
	#   - 历史(留档):在此之前基类**不写**、只有 `RoyaleHost`/`TeamHost` 的覆写写,而 1v1
	#     直接建 `MatchHost`  ->  1v1 一把手枪打完一局,结算页显示 `击杀 5 / 造成 0 / 承受 0`。
	#     守卫 `tests/probe/stats_delivery_probe` ⑦ 钉住"生产自己写不写"这一面。
	var stat_victim: Node2D = players.get(int(role))
	var stat_self := stat_victim != null and is_instance_valid(stat_victim) \
			and CombatFeedback.is_fresh_self_hit(stat_victim, ATTRIB_FRESH_MS)
	var stat_attacker := _fresh_attacker_role(int(role))
	if stat_attacker != 0:
		# 助攻表:所有**归因得到**的命中都记一笔(含队友误伤 —— 读端按 `same_team` 过滤)。
		_note_hit(int(role), stat_attacker)
		if not same_team(stat_attacker, int(role)):
			# `dealt` / `taken` **口径对称**(spec §3.1):都只算**敌人** ——
			#   队友爆炸炸到我不进 `taken`、自己炸自己也不进 `taken`/`dealt`
			#   (那两类的代价走**惩罚**,记在**肇事者**行上,见下面那两笔账)。
			# 注意： **不进这两列的三档**(2026-09-26 订正:旧措辞写"三档都不记",而自伤**确实会记**
			#   —— 只是记进 `self_damage` 那一列,不是"不记";照旧措辞读会得出相反的结论):
			#   ① **自伤**  ->  记进**自己**的 `self_damage`(写端 `CombatFeedback.attribute` 在
			#      attacker == victim 时静默跳过  ->  自伤没有归因通道,读端靠 `Explosion` 那笔
			#      `note_self_hit` + `ATTRIB_FRESH_MS` 新鲜度识别解析 —— **读端就在本文件下面几行**
			#      的 `CombatFeedback.is_fresh_self_hit(...)`(`:stat_self` 那一行),
			#      - **不是** `match_state.gd` 的 `_fresh_attacker_role` —— 那是**攻击者**归因的
			#      新鲜度函数,`last_self_hit_time` 它一个字节都不读;照旧指针去找会找不到这条通道);
			#      - 标记的另一半:写真实(非自伤)归因时 `CombatFeedback.attribute()` 会**当场作废**
			#      上一响留下的自伤标记,免得"自己先炸、敌人后炸"被记成自伤(守卫 ⑬n3/⑬n4);
			#   ② **队友伤害**  ->  记进**肇事者**的 `team_damage`(按 `same_team` 过滤);
			#   ③ **未识别攻击来源**(meta 缺失或不新鲜) ->  **哪儿都不记**,是本钩子唯一真正丢弃的一档。
			# - 1v1 / 大乱斗:队伍表空  ->  `same_team` 恒 false  ->  这两列就等于"对所有人的伤害",
			#   不需要特判(§5.6 的免费正确性,别去"优化"它)。-  同上,②那一档在那两个模式下
			#   天然不成立(没有队就无所谓队友),①那一路与队伍表无关、照旧走 `self_damage`。
			var sa := _stat_entry(stat_attacker)
			sa["dealt"] = int(sa["dealt"]) + int(damage)
			var sv := _stat_entry(int(role))
			sv["taken"] = int(sv["taken"]) + int(damage)
	# ── 惩罚的两笔账:只减分,**不进** dealt / taken(spec §3.5)──
	# - 自伤优先判定:自伤时 meta 通常还是上一名敌人(或为空),两者不同时成立;真同时成立
	#   (同帧内先被敌人打中、再被自己的爆炸炸到)时按**自伤**记 —— 那一下的来源就是自己的爆炸。
	#   注意： 已知边界(登记不修,承自 `ATTRIB_FRESH_MS` 的既有边界):上面那个 `if` 若成立,
	#     同一笔伤害会**同时**记进 `dealt`(给那位敌人)与 `self_damage`(给自己)—— 两个不同的
	#     账户,不是双计;`acs` 只读 kscore,而 kscore 里两者各出现一次。
	if stat_self:
		var ss := _stat_entry(int(role))
		ss["self_damage"] = int(ss["self_damage"]) + int(damage)
	elif stat_attacker != 0 and same_team(stat_attacker, int(role)):
		var sm := _stat_entry(stat_attacker)
		sm["team_damage"] = int(sm["team_damage"]) + int(damage)
	# Beta 时间玩法(B21):伤害入账(每点 × damage_gain)。归因口径与击杀相同机制窗口(3s):
	# `attribute` 都写在 `take_hit` 之前  ->  这一刻读 meta 就是"这一下是谁打的";
	# 自伤 / 未识别攻击来源 / 同队,谁都不给(设计约定)。
	# - 窗口用 `ATTRIB_WINDOW`(3s)而**不是**上面逐人统计那个 `ATTRIB_FRESH_MS`(8ms)——
	#   两者答的是**两个问题**,见 `match_state.gd` 里两个常量的注释。
	# - 合并订正:KH 原版调用的是两参重载 `_fresh_attacker_role(role, window)`,而主线已把
	#   该函数重构成"一参 + `_attributed_role_within(node, window)`" —— 两参版在本仓会与
	#   主线那份构成**同文件同名重复定义**(git 自动合并看不见),故改走既有 API。
	if time_economy != null and damage > 0 and stat_victim != null:
		var rw_attacker := _attributed_role_within(stat_victim, ATTRIB_WINDOW)
		if rw_attacker != 0 and rw_attacker != int(role) and not same_team(rw_attacker, int(role)):
			time_economy.award_damage(rw_attacker, int(role), damage)
	for r in peer_by_role:
		# 存活检测:这是**每次伤害**都发的定向包(交火时最密的一处),原先完全不判 ——
		# 往"正在断开"的 peer 发就是那条 channel 0 错误(判据为何不能用 get_peers 见 NetBus)。
		if NetBus.is_peer_live(peer_by_role[r]):
			NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos)

# ── 回合制 ──

# 某角色的对手 role(1v1,players 恰两个角色;找不到返回 0)。

func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0

# 本局角色出生点(换边感知):首局 _side_swap=false → P1=player/P2=player2;换边后交换。
