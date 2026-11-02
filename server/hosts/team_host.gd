class_name TeamHost
extends MatchHost

# 对抗模式(内部 mode id 仍是 "team")第三个模式宿主,与 RoyaleHost 平级:两队(各 1..5 人,总 2..10)、三局两胜、
# 每局先到**动态目标**击杀赢一局(目标 = 总人数 + 3,钳 [5,13] ⇒ 6 人 = 9,与改造前的 3v3 逐字一致)、局间整队换边、
# 局内死亡 2s 复活;击杀后不复位任何人(代价见 _match_round_tick)。★ 计分不分死因:任一玩家倒地 → 对方队 +1;
# 子弹穿透队友、爆炸对队友满效(现状)。★ 掉线:整队走光才终局(走光即弃权,两队都走光 = 平局);队伍归属来自 MatchState._team_of。
# ★★ 人数不等时给少人方三种补贴(公式的**单一来源** = core/mp/team_rules.gd,本文件只负责"什么时候用"):
#   ① 开局比分补贴(每局开局给,上限 目标-1);② 血量补贴(max_hp 加成,服务端真值 + 客户端镜像);
#   ③ 伤害补贴(只在人数差 ≥ 阈值时给,倍乘**弹丸直击/激光**的武器伤害 + 榴弹的直击/爆炸伤害)。
#   人数差为 0(含 6 人 3v3)时三处都**恒等**:目标 9、不写比分、max_hp 不动、倍率 1.0 —— 既有 6 人探针照旧。
# ★ 本类是末端子类,生命周期钩子只能在这里;_init 顺序不可整理。
# ★ 出生点/选点:数据 = 地图 `# respawn 1|2`(按阵营半区写死;队 1 = 侧 1 左半、队 2 = 侧 2 右半,换边时互换);
#   随机/排除上一局/侧的选择在 TeamSpawn.plan_team_spawns,本文件只持有 _round_spawns / _side_swap_round /
#   _spawned_once / _last_spawn 四份状态与 _spawn_cell / role_spawns / _respawn_cell_for 的覆写。

const TEAM_ROUNDS_TO_WIN := 2    # ★ 不能叫 ROUNDS_TO_WIN:基类 MatchState 已有该常量,同名遮蔽会报错
# ★ _endgame_winner 的「未定」哨兵:必须三态,不能拿 0 当未定 —— 0 是合法结果(两队都走光 = 平局)。
const ENDGAME_NONE := -1
# 散点 / 复活选格 / 队层契约的常量与实现都在 TeamSpawn(server/hosts/team_spawn.gd)。★ 下面这行是转出:客户端
# scenes/team_game.gd 与 tests/harness/team_match_watcher.gd 按这个**名字**读数,契约表那条注释也留在 TeamSpawn 里。
const TEAM_ENEMY_LAYER := TeamSpawn.TEAM_ENEMY_LAYER
# 伤害补贴写到子弹上的标记(子弹只被补贴一次;子弹会飞好几十帧,重复乘会指数放大)。
const META_DAMAGE_SUBSIDY := "team_damage_subsidy"

var _round_spawns: Dictionary = {}   # role -> Vector2i(本局出生点,与 match_start / 换局后 match_sync 广播的同一份)
var _side_swap_round := false        # 换边:每局取反;true 时队 1 用侧 2(右半)、队 2 用侧 1(左半)
var _spawned_once: Dictionary = {}   # role -> true(首次摆位走出生点,之后走动态复活点)
var _last_spawn: Dictionary = {}     # role -> Vector2i(最近一次出生/复活格:局内复活排除本 role 上一次位置用)

var _endgame_winner := ENDGAME_NONE

# 本局的规则快照(TeamRules.subsidy 的返回值):counts / total / diff / smaller_team / kills_target / score_bonus /
# hp_bonus / damage_mult。★ 在开局那一刻算一次就**不再重算**(掉线不改目标/补贴:客户端手里的队伍表也不会随掉线更新,
# 重算会让两端看到的血上限不一致)。
var _rules: Dictionary = {}
var _kills_to_win: int = TeamRules.KILLS_MIN


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:

	MatchHost.ensure_spawn_grid(map_path)
	_team_of = teams.duplicate()
# ★ spawns 传空只在手工/测试路径才自己算一份:plan_team_spawns 是随机的(SpawnChooser),重算会得到另一份散点,
#   而广播给客户端的是 start_on 那一份。出生点数据 = 地图 `# respawn 1|2` 两侧列表(缺则 TeamSpawn 回退几何生成)。
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
# ★ 第 5 个实参是 teams、不是 spawns(两者在 RoyaleHost 里同名易混):传错不是崩溃,而是整局队伍判定全错 —— _team_of 被塞成 {role: Vector2i} ⇒ team_of() 返回 0 ⇒ 子弹不穿队友、队伍表下发为空。
	super._init(map_path, role_peers, options, ai_roles, teams)
	_apply_team_layers()
	_init_team_rules()


# 规则快照 + 开局比分补贴(血量补贴要等玩家节点的 @onready 落地,见 _ready)。
# ★ 队伍表在这里已经是最终值:大厅侧先把「未选边」补好(RoomTypes.team_autofill)再下发 --teams。
func _init_team_rules() -> void:
	_rules = TeamRules.subsidy(_team_of)
	_kills_to_win = int(_rules["kills_target"])
	_scores = _initial_scores()


# 每局开局的比分:少人方带 `score_bonus` 分;势均(差 0)⇒ **空表**,与改造前的 6 人 3v3 逐字一致。
func _initial_scores() -> Dictionary:
	var bonus := int(_rules.get("score_bonus", 0))
	if bonus <= 0:
		return {}
	return {int(_rules["smaller_team"]): bonus}


# 开局一次性的待遇落地。★ 必须在玩家子节点 @onready 之后(所以是 _ready 而不是 _init),且要在 super._ready()
# 之前接上 weapon_changed —— 那一行会铺地面武器并给每人发一把,漏接的话"开局那把枪"没有伤害补贴,换一次枪才补上。
# ★ 差 0(含 6 人 3v3)时这里**一个字节都不改**:max_hp 保持 PlayerParams 默认、不连信号、不碰子弹 ⇒ 行为逐字一致。
func _ready() -> void:
	if int(_rules.get("hp_bonus", 0)) > 0:
		_apply_health_subsidy()
	if float(_rules.get("damage_mult", 1.0)) > 1.0:
		for role in players:
			var wc = (players[role] as Node).get("weapons")
			if wc != null and wc.has_signal("weapon_changed"):
				wc.weapon_changed.connect(_on_team_weapon_changed.bind(int(role)))
	super._ready()


# 血量补贴:少人方 max_hp = 基础 + 加成,并拉满。★ 客户端在 scenes/team_game.gd::_apply_team_health_subsidy 用**同一份**
# TeamRules 从 match_sync 的 teams 复算(不新增协议字段);两边必须同值,否则 C2 的 hp 每次快照都被钳到客户端上限。
func _apply_health_subsidy() -> void:
	var bonus := int(_rules.get("hp_bonus", 0))
	var small := int(_rules.get("smaller_team", 0))
	if bonus <= 0 or small == 0:
		return
	for role in players:
		if team_of(int(role)) != small:
			continue
		var c := (players[role] as Node).get("combat") as CombatComponent
		if c == null:
			continue
		c.max_hp = PlayerParams.player_max_hp + bonus
		c.hp = c.max_hp
		c.hp_changed.emit(c.hp, c.max_hp)


# 换枪时把伤害倍率刷到新武器实例上(武器每次 equip 都是新实例;直接写 `damage` 就改变了它之后所有弹丸的 `hit_damage`)。
# ★ 幂等靠"新实例没有标记":同一实例只乘一次(`team_base_damage` 记原值),否则换枪/重入会叠乘。
func _on_team_weapon_changed(_type_id: int, role: int) -> void:
	var mult := float(_rules.get("damage_mult", 1.0))
	if mult <= 1.0:
		return
	var p: Node2D = players.get(int(role))
	if p == null or not is_instance_valid(p):
		return
	var w = p.get("weapons")
	if w == null:
		return
	var weapon: WeaponBase = w.current_weapon()
	if weapon == null or not is_instance_valid(weapon):
		return
	if weapon.has_meta("team_base_damage"):
		return
	weapon.set_meta("team_base_damage", int(weapon.damage))
	weapon.damage = maxi(1, roundi(float(weapon.damage) * mult))


# 伤害补贴的**弹丸直击/爆炸**那一半:`hit_damage` 已由武器 `damage` 乘过(见上),此处只乘子弹场景自带的
# `direct_hit_damage` / `explosion_damage`(榴弹的直击与 AoE 走它们,不经武器 damage)。
# ★ 挂在裁决之前(而不是自己另起一个节拍):子弹出膛后第一帧就会被裁决,晚一拍就可能漏掉首发。
# ⚠ 已知边界:爆炸伤害对**队友与自伤**同样吃这个倍率(本模式的爆炸对队友满效是既有裁定),见 registered-debt。
func _adjudicate_bullets() -> void:
	var mult := float(_rules.get("damage_mult", 1.0))
	if mult > 1.0:
		var small := int(_rules.get("smaller_team", 0))
		for b in get_tree().get_nodes_in_group("bullet"):
			if not is_instance_valid(b) or not (b is BulletBase):
				continue
			var bullet := b as BulletBase
			if bullet.has_meta(META_DAMAGE_SUBSIDY):
				continue
			var shooter_role := _role_of(bullet.shooter)
			if shooter_role < 0 or team_of(shooter_role) != small:
				continue
			bullet.set_meta(META_DAMAGE_SUBSIDY, true)
			bullet.direct_hit_damage = maxi(1, roundi(float(bullet.direct_hit_damage) * mult))
			bullet.explosion_damage = maxi(1, roundi(float(bullet.explosion_damage) * mult))
	super._adjudicate_bullets()


# ── 队友不互挡(用户裁定「完全穿透」)── 契约与配层规则单一来源 = TeamSpawn.apply_team_layers;本函数只留
# 「什么时候调」(必须在 super._init 之后),并让「手工摆位」路径还能补调一次(幂等、直接赋值不叠加)。
# ★ 队号 1/2 的穷举、表外 role push_error、1 队 mask=21 / 2 队 mask=7 的逐条理由全在那份实现里。
func _apply_team_layers() -> void:
	TeamSpawn.apply_team_layers(players, _team_of)



static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MatchHost.prepare_map(map_path)
	var spawns := plan_team_spawns(teams)
	for role in role_peers:

		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "对抗开始")

	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# ── 散点 ── 实现(数据驱动 / 缺数据回退几何)在 TeamSpawn.plan_team_spawns。
# ★ 保留静态转发而不是让调用点直接引 TeamSpawn:start_on 与手工路径的调用面零 diff,搬运不牵连调用方。
static func plan_team_spawns(teams: Dictionary, last: Dictionary = {}, side_swap := false) -> Dictionary:
	return TeamSpawn.plan_team_spawns(teams, last, side_swap)


# 换边点集(两队点整体对调):实现在 TeamSpawn.compute_swap_spawns。★ 保留静态转发是因为 team_match_probe 相④
# 直接用 `TeamHost.compute_swap_spawns(...)` 算期望 —— 探针不在本次改动面内,这个名字必须继续可用。
# ⚠ 数据驱动的出生点从第 2 局起是「换用另一侧点集 + 重随机」,不再是第 1 局的精确对调 ⇒ 相④ 的期望会过期(见 registered-debt)。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	return TeamSpawn.compute_swap_spawns(spawns, teams)



func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()



func team_map() -> Dictionary:
	var out := {}
	for role in _team_of:
		out[int(role)] = int(_team_of[role])
	return out


func _spawn_cell(role: int) -> Vector2i:
	role = int(role)
	var cell: Vector2i
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		cell = _round_spawns.get(role, Vector2i(-1, -1))
	else:
		cell = _respawn_cell_for(role)
	_last_spawn[role] = cell
	return cell


# 复活点:选格计算(本队这一局所在侧的 `# respawn` 列表 / 「躲敌人不躲队友」/ 排除上一次位置)在 TeamSpawn.respawn_cell;
# 本函数只留虚方法覆写与状态读取(数据缺失时 TeamSpawn 自己回退几何并 warning 一次)。
func _respawn_cell_for(role: int) -> Vector2i:
	return TeamSpawn.respawn_cell(int(role), players, _team_of, _last_spawn,
			map_spawn_data().get("respawns", {}), _side_swap_round)


# ★ 复活时清 last_damager / last_damager_time:meta 在受击瞬间写下、跨倒地保留,而归因窗口是 ATTRIB_WINDOW(3s)⇒ 复活后 3s 内的
# 环境死亡会记到复活前那名射手头上。与 RoyaleHost 那份逐字同构(对等性欠债别留)。⚠ 零守卫:team_host_probe 已删(2026-10-09)。
# ★★ 逐字同构但**刻意不并到 MatchHost**:MatchHost 同时是 1v1 的类 ⇒ 上提等于让 1v1 也清这两条 meta,
#    而 Beta 局的 award_damage 读的正是 3s 窗口(_attributed_role_within)⇒ 1v1 复活后的伤害归因会变。
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")



func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


# ★ 整段覆写而不是改基类:基类的计分键、胜负判据、复位对象三方都绑在 role 上,逐处插分支会让 1v1 那条路长出团队语义。
func _match_round_tick(delta: float) -> void:
	for role in players:

		if _round_state == RoundState.MATCH_OVER:
			continue
		var p: Node2D = players[role]
		if not p.is_downed():
			continue

		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		_on_down_edge(int(role))
# ★★ 击杀者复位已按用户要求删除(2026-09-21,那个函数已整体删掉):击杀者原地不动,受害者 2s 后回本方出生点复活。
# ★ 代价照实记录:那条规则本是为反「反复活点蹲守」而立,删后对抗不再有这条性质;将来若要找回,正确的形状是「复活点选点避开存活敌人」(TeamSpawn.respawn_cell 的 RESPAWN_CLEARANCE 已做一半),而不是把击杀者瞬移走。
	match _round_state:
		RoundState.COUNTDOWN:
			# ★ 与基类 MatchRound 同一条就绪闸:客户端场景建好(发过 match_sync)后倒计时才开始、并补发一次。
			#   本类整段覆写了 _match_round_tick ⇒ 不抄这道闸,对抗开局那一局的倒计时会从"客户端还在切场景"时起算,
			#   本地时钟比服务器慢 1~2s ⇒ 最后 1 秒被 PLAYING 转变截掉(2026-11-01 用户实见)。
			if not _countdown_can_start(delta):
				return
			if not _countdown_bcast_done:
				_countdown_bcast_done = true
				_broadcast_round_state()
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
			else:
				_countdown_resync_tick(delta)
		RoundState.PLAYING:
			_handle_respawns(delta)
			for t in [1, 2]:
				# 目标随人数缩放(TeamRules):6 人 = 9(与改造前逐字一致),2 人 = 5,10 人 = 13。
				# ★ 比分里含少人方的开局补贴,但补贴上限是「目标 - 1」⇒ 不可能靠补贴开局即胜。
				if int(_scores.get(t, 0)) >= _kills_to_win:
					_round_over(t)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass


# ★ _round_over 不再覆写:本模式要的「记局胜(键 = 队号)+ 置 ROUND_OVER + 广播」与 MatchRound._round_over 逐字相同
#   (调用点传的就是队号 `_round_over(t)`),原先那份等于把基类整段抄了一遍。
# 换局:局胜到 TEAM_ROUNDS_TO_WIN → MATCH_OVER;否则整队换边 + 下一局。★ 与基类的实质差异:① 局胜的键是队号(基类按 role 查,
# 团队下永远是 0 → 永远打不完);② 换边 = 两队换用另一侧的 `# respawn` 点集(队 1↔侧 2 / 队 2↔侧 1),且每局从列表里重随机;
# ③ 换边后必须清 _spawned_once —— 否则 _spawn_cell 走动态复活点分支,开局的人会被撒到「离敌人远」的随机格而不是本方出生点。
# ★ 与 _match_winner() 互补:一个判要不要进 MATCH_OVER,一个判报哪一队。
func _start_next_round() -> void:
	if _threshold_team() != 0:
		_round_state = RoundState.MATCH_OVER
		_broadcast_round_state()
		return
	_reset_world_and_clear_dynamics()

	_side_swap_round = not _side_swap_round
	_round_spawns = plan_team_spawns(_team_of, _round_spawns, _side_swap_round)

	_spawned_once.clear()
	_round_num += 1
	# 每局重给少人方开局比分补贴;势均时是**空表**(与改造前逐字一致)。别写成"整场只给一次":_scores 每局清零,
	# 只给一次的话第 2 局起补贴就消失了,而补的是"这一局开局"的劣势。
	_scores = _initial_scores()
# ★ 整场累计的 _stats 不清零:ACS 是整场口径,与每局清零的 _scores(队伍比分)是两份不同的东西。
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_countdown_hold = COUNTDOWN_HOLD_MAX
	_countdown_bcast_done = false
	_countdown_resync = COUNTDOWN_RESYNC
	_broadcast_round_state()


# 对局胜者(队号):① 走光(弃权)看 _endgame_winner;② 正常收局 = 先到 TEAM_ROUNDS_TO_WIN 局胜的那队;③ 都还没到则退回「局胜高者」。
# ★★ 下面那两个 2 不是阈值、是队号,别换成 TEAM_ROUNDS_TO_WIN —— 今天两者都等于 2,换错了不报错,而档位一改就会报出不存在的队号。
func _match_winner() -> int:
# ★ 走光终局优先于按局胜比较的兜底:走光必然走兜底(谁也没赢满),而兜底在 0:0 / 1:1 并列时偏 1 队 ⇒ 不拦就会把「整队走光」那队报成胜者。
	if _endgame_winner != ENDGAME_NONE:
		return _endgame_winner
	var decided := _threshold_team()
	if decided != 0:
		return decided
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# 「局胜阈值」谓词的单一来源:先到 TEAM_ROUNDS_TO_WIN 局的那一队,都还没到 → 0。★ 三个读者问的是同一个谓词的三种问法
# (_start_next_round 问要不要进、_match_winner 问报哪队、_decided_by_rounds 问是否已决出)。★ 返回的 0 不是队号(本模式没有 0 队)。
func _threshold_team() -> int:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 0



func _broadcast_round_state() -> void:
	var data := _round_state_base()
	# 本局击杀目标 + 少人方补贴:HUD 只从这里读数(**别在 HUD 里再写死一个 9** —— 目标随人数变)。
	# ★ 键名 `target` 是 team_hud 的读取契约;`handicap` 只在有人数差时出现(差 0 ⇒ 载荷不多这个键)。
	data["target"] = _kills_to_win
	if int(_rules.get("diff", 0)) > 0:
		data["handicap"] = {
			"team": int(_rules["smaller_team"]),
			"diff": int(_rules["diff"]),
			"score": int(_rules["score_bonus"]),
			"hp": int(_rules["hp_bonus"]),
			"damage_pct": roundi((float(_rules["damage_mult"]) - 1.0) * 100.0),
		}
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		# ★★ 2026-10-30 用户裁定「全场最佳必须出自胜方」:候选 = 胜队全部 role(平局 / 队号未知 ⇒ 空表 = 不限队)。
		# match_winner 已由 _round_state_base 并进载荷(同一份构造,不再各拼一份)。
		data["mvp"] = mvp_role(_roles_of_team(int(data["match_winner"])))
	_send_round_state(data)


# 某队全部 role(给 mvp_role 的候选集)。★ 用 `_roster()`(在场 ∪ 已离开 ∪ 计过分)而不是 players:
# 裁定「已离开者照样参与评选」⇒ 走光/掉线的人只要属于胜队就仍是候选。队号 <= 0(平局 / 未知)⇒ 空表 = 不限队。
func _roles_of_team(team: int) -> Array:
	var out: Array = []
	if team <= 0:
		return out
	for role in _roster():
		if team_of(int(role)) == team:
			out.append(int(role))
	return out


# ── 击杀归因:`_attributed_killer`(读上次射手 meta,3s 窗口)已上提到 MatchHost(与 RoyaleHost 逐字同款那份);
# 单一来源仍是 CombatFeedback 写 meta + MatchState._attributed_role_within 读。


# ── 中途掉线(宽限期到点后由 server_main 调):移出对局,但整队走光才终局。★ 判据是「某个队一个人都不剩」,不是 royale 那条 players.size() < 2(6 人局掉 1 个就终局 = 剩下的人白打);也不能数 peer_by_role(那是「有连接的人」)。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if not _detach_role(role):
		return
	_left_round[role] = int(_leave_round.get(role, _round_num))

	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2 and not _decided_by_rounds():
# 走光即弃权:存活的那支队胜;一队不剩 = 平局 0。★ 本判据在走光收场之后仍生效(先走光那队把结果判给对手后,对手也可能接着走光)
# ⇒ 少了它,「六个人在同一批宽限期里走光」的胜者取决于遍历顺序;收缩是单调的。★★ _decided_by_rounds() 那道闸不能省。
		var survivors: Array = alive_teams.keys()
		_endgame_winner = int(survivors[0]) if survivors.size() == 1 else 0
		if _round_state != RoundState.MATCH_OVER:
			_finish_match()
			return      # `_finish_match` 内部自会广播(载荷里的 match_winner 已读新值)

	_broadcast_round_state()


# 对局是否已由局胜(三局两胜)决出。★ 弃权判据不得改判一场已经打完的局 —— 故刻意不用「在 _start_next_round 里记一个闩」的写法:那样 ROUND_OVER 期间(局胜已达标、状态未推进)会漏判。
func _decided_by_rounds() -> bool:
	return _threshold_team() != 0


# ★ 置态 + 广播两条已上提到 MatchHost._finish_match(与 RoyaleHost 逐字同款);这里只留收场文案。
func _finish_match() -> void:
	super._finish_match()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


# ── 自杀脱困(K 键:客户端 → NetBusExt.suicide_request → server_main._on_suicide_request)── 异常卡死时主动放弃生命,先清归因 ⇒
# 自杀不计入任何人击杀(对抗下落进无归因档:对方队 +1、无人被计击杀)。★ 必须留在子类;server_main 原先只认 _royale ⇒ 对抗的 K 键被静默丢掉。
# ★★ 与 RoyaleHost 那份逐字同构,但**不许**并到 MatchHost:server_main 按 `has_method("request_suicide_role")` 派发 ⇒
#    上提就等于给 1v1 也开了 K 键自杀(那是行为变更,不是重构)。
func request_suicide_role(role: int) -> void:
	if _round_state != RoundState.PLAYING:
		return
	var p: Node2D = players.get(int(role))
	if p == null or not is_instance_valid(p) or p.is_downed():
		return
	for m in ["last_damager", "last_damager_time"]:
		if p.has_meta(m):
			p.remove_meta(m)
	var combat: Node = p.get_node_or_null("Combat")
	if combat != null and combat.has_method("force_down"):
		combat.force_down()


# 逐人数据 + ACS / MVP 的口径已上提到 MatchState(公式见 core/sim/score_rules.gd);本文件只留对抗特有的两处写入:倒地边沿 _record_down、子弹直击补归因。


# 对抗口径:击杀定义沿用 1v1 的「不分死因」(任一玩家倒地 → 对方队 +1;队友误炸也照此,乱扔雷 = 给对面送分);
# 逐人 kills 仍只在「归因到且异队」时由基类 _record_down 记(队分与逐人 kills 是两条账,见 docs/eng/modes.md)。
func _down_killer_of(role: int) -> int:
	return _attributed_killer(players[int(role)])


func _award_down(victim_role: int, killer_role: int) -> void:
	var scorer := _enemy_team_of(victim_role)
	if scorer == 0:
		return
	_scores[scorer] = int(_scores.get(scorer, 0)) + 1
	_broadcast_kill(killer_role, victim_role)
	_broadcast_round_state()


# 子弹直击的归因写入(与 RoyaleHost._on_bullet_hit 逐字同构):服务器上子弹撞玩家不靠物理,只经 _adjudicate_bullets 到这里。
# ★ 基类自 2026-09-27 起也写同一笔 ⇒ 本覆写是冗余的重复写(attribute 幂等);★★ 别据此把基类那行删掉:1v1 直接建 MatchHost,基类那行是它唯一的子弹归因写端。
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)
