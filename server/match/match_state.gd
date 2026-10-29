class_name MatchState
extends Node

# 对局权威的共享状态底座:链上每一层都要读同一批状态,而 GDScript 的父类方法/字段在编译期解析不了子类声明的符号 ⇒ 它们只能住在
# 共同祖先里。链:RoyaleHost → MatchHost(生命周期/输入/物理编排) → MatchRound(回合机) → MatchCombat(裁决) → MatchSnapshot(快照)
# → MatchState(本文件) → Node。★ 中间层不得定义 _init/_ready/_enter_tree/_exit_tree/_physics_process:RoyaleHost 的 _init 契约是「先 plan_spawns 再 super._init」,插钩子会打断它。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> PacketInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> Array[输入记录队列](30Hz 采样:一条记录管 2 个物理 tick),按序消费不丢 just_pressed 边沿
var grid: Array = []
var _base_grid: Array = []   # 建局原始(未破坏)网格深拷贝:每局复位重铺,防客户端/服务器砖状态漂移

# 队伍表 role -> 队号(1/2):唯一权威,由大厅经 worker 命令行 --teams 显式传入。★ 不从 role 号推导(role 由「最小空闲号」分配、退出后不重排,编号留空洞);★ 空表 = 无队伍(1v1 / 大乱斗 / 单机)⇒ team_of 恒 0、same_team 恒 false。
var _team_of: Dictionary = {}

# Beta 时间玩法(B21)的服务器权威颗粒经济;★ 普通局恒 null(一切结算/广播短路),由 MatchHost._init 按房主 options 建。
var time_economy = null


var _rw_on: Dictionary = {}        # role -> bool(回溯中)
var _rw_trail: Dictionary = {}     # role -> Array(回溯中每 3 帧一个 [x,y],快照带下去给残像)



func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	for r in players:
		if players[r] == n:
			return int(r)
	return 0



func team_of(role: int) -> int:
	return int(_team_of.get(int(role), 0))


# 两个 role 是否同队 —— 单一来源:子弹穿透队友、出生/复活分组、复位归属都问它。★ 任一方为 0(无队伍)一律 false:
# 0 == 0 若算同队,1v1 里两个玩家会被判成队友、子弹全穿。
func same_team(a_role: int, b_role: int) -> bool:
	var a := team_of(a_role)
	var b := team_of(b_role)
	return a > 0 and a == b


# 与建局基线(_base_grid)不同的格,给「重连后补破坏态」用:客户端重连只拿 match_path 重建初始地图,不补这一份会留
# 幻影墙(→ 本地预测分歧,可能回滚循环)。★ 判据是「与基线不同」、不是「当前为空」;顺序确定(y 升序、同 y 升序 x);只由 match_sync 应答投递,空数组连键都不带。
func destroyed_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var rows := mini(grid.size(), _base_grid.size())
	for y in range(rows):
		var cur: Array = grid[y]
		var base: Array = _base_grid[y]
		var cols := mini(cur.size(), base.size())
		for x in range(cols):
			if int(cur[x]) != int(base[x]):
				out.append(Vector2i(x, y))
	return out


var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
# 本局被摧毁过的 16px 子格(Vector2i → true):换局增量复位只还这些格(全量 build_sim 实测 ~0.48s ⇒ 每局卡顿)。
var damaged_subs: Dictionary = {}
var _snapshot_tick_phase := 0   # 物理 tick 相位:每 SNAPSHOT_STRIDE 个 tick 发一次(整数计数;用浮点累加在整除边界上会漂成 3 tick 一次)
# ── 下行发包频率(2026-10-23 起 30Hz)── ★ 物理模拟仍是 60Hz:快照的 tick 用 60Hz 物理 tick 计,30Hz 发包 ⇒ 每包跨 2 tick(SNAPSHOT_STRIDE)。
# 为什么 30Hz:下行载荷/发包次数减半(docs/eng/netcode-snapshots.md §5.2 那条「60→30Hz」选项);代价 = C2 对账频率减半、副本插值样本间隔翻倍(playout 的 tick 域不变,仍是 60Hz tick)。
# ★ SNAPSHOT_STRIDE 由 SNAPSHOT_HZ 推导(= 60Hz物理 tick / SNAPSHOT_HZ,必须整除):客户端 playout 时钟与位置历史都按「60Hz 物理 tick」计,两处不一致会让副本时间轴快/慢一倍。
# ★ 非整除的 HZ(如 40)会让 stride 被整除截断 ⇒ tick 时间轴与包率同时错;要改先选 60 的约数(30/20/15/12/10)。
const SNAPSHOT_HZ := 30
const SNAPSHOT_INTERVAL := 1.0 / SNAPSHOT_HZ
const SNAPSHOT_STRIDE := 60 / SNAPSHOT_HZ   # = 60Hz 物理 tick / 30Hz 发包
# ★ 命中判定半径的单一来源在 BulletBase.PLAYER_HIT_RADIUS:客户端那份视觉榴弹也按同一半径判「碰到玩家 → 短引信」,两处各写一个数就会漂。
const HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次);每帧按在场子弹剪枝(见 _adjudicate_bullets)
var _snap_tick := 0   # 快照的 tick 时间戳(60Hz 物理 tick 域,每包 +SNAPSHOT_STRIDE;客户端靠它丢弃乱序旧快照 + playout 插值)
# C2 rollback:每 2 个物理 tick 恰好消费一条输入记录(FIFO;30Hz 采样),ack 让客户端重放 seq > ack 的本地输入 —— 1:1 同序,无 tick 映射漂移。
var _ack_seq: Dictionary = {}   # role(int) -> 已消费输入记录的 seq
# ★ 上行只落位的两个扩展字段(本批无消费者;2026-10-24 随输入手打包一次改完线格式,增量批才用;见 NetCodec.INPUT_SCHEMA 的 st/ct)。
var _client_snap_tick: Dictionary = {}   # role(int) -> 该 role 最近**成功解码**的服务器快照 tick(st)
var _client_tick: Dictionary = {}        # role(int) -> 该 role 最近一包里的客户端物理帧号(ct)


var _options: Dictionary = {}
var _round_full_heal := false        # 每回合开始双方回满血
var _disabled_weapons: Array[int] = []   # 禁用的武器槽位(双方一致)
var _ai_roles: Array = []            # AI 补位的 role 列表;这些 role 无网络 peer


enum RoundState { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER }
const KILLS_TO_WIN := 5      # 每局先到 5 击杀赢
const ROUNDS_TO_WIN := 2     # 三局两胜
const COUNTDOWN_TIME := 3.0
const ROUND_OVER_TIME := 4.0
const RESPAWN_DELAY := 2.0   # 局内死亡后复活延迟
var _round_state := RoundState.COUNTDOWN
var _round_num := 1
var _scores: Dictionary = {}     # role -> 本局击杀
var _rounds_won: Dictionary = {} # 局胜数(键:1v1 = role;TeamHost = **队号**)—— 下一个人别按 role 查
var _round_timer := 0.0
var _side_swap := false          # true 时 P1 用 player2 出生点(每局换边)
var _respawn_pending: Dictionary = {}  # role -> 剩余复活秒
var _down_counted: Dictionary = {}     # role -> 本次倒地是否已计分/已入复活流程
var _last_round_winner := 0            # 最近一局的胜者 role(客户端播报"本局胜利/落败"用)

# ── 逐人统计(三模式共用)── ★ 条目只存原始计数,kscore / acs 一律读时推导:存一份算好的 kscore 就等于「加了新惩罚却
# 忘了同步」这种不报错的静默缺陷。★ 载荷才用 spec §3.1 的七个字段(kills/deaths/assists/dealt/taken/kscore/acs)。
var _stats: Dictionary = {}          # role -> 原始计数(整场累计,不随局清零)
var _left_round: Dictionary = {}     # role -> 离开时所处的局号(ACS 的"实际参与局数"口径)
# role -> 掉线那一刻所处的局号(与 _left_round 是两件事:后者是移出时写下的最终值)。★ 必须分开:掉线与宽限期到点之间
# 隔着 60s、可能换过局,而 ACS 分母要的是「他实际参与了几局」。⚠ 已知边界(不修):_round_num 在新一局 COUNTDOWN 期间就已 +1 ⇒ 那 ~3s 窗口里掉线的人被记上一局没打过的局号。
var _leave_round: Dictionary = {}
# 助攻表:每受害者一张小表 victim_role -> {attacker_role: 最后命中时刻(ms)}。★ 归因只有单个 last_damager meta,回答不了「还有谁打过他」;★ 写入口唯一(_note_hit,由 MatchCombat._on_player_hit 调),窗口复用 ATTRIB_WINDOW。
var _assist_times: Dictionary = {}
# role -> true(已移出对局)。★ 必须住底座(_roster / mvp_role 都要读);子类重复声明基类成员是硬 Parse Error,故 RoyaleHost / TeamHost 那两行必须一起删。
var _left: Dictionary = {}

# ── v5 命中补偿(favor-the-shooter):受害者位置回溯环(纯逻辑在 core/net/lag_comp.gd)──
var _pos_ring: Dictionary = {}     # role -> LagComp 环
var _sim_tick := 0                 # 60Hz 物理 tick 计数(回溯环的时间轴;与 30Hz 的 _snap_tick 分开)


func record_pos_ring() -> void:
	_sim_tick += 1
	for role in players:
		var p: Node2D = players[role]
		if p != null:
			LagComp.record(_pos_ring, int(role), p.global_position, _sim_tick)


func rewound_pos(role: int, ticks_back: int) -> Vector2:
	var p: Node2D = players.get(int(role))
	return LagComp.rewound(_pos_ring, int(role), _sim_tick, ticks_back,
			p.global_position if p != null else Vector2.ZERO)


# Wire 用 /root 查节点而不是裸标识符:-s 冒烟(无 autoload)也要能编译本文件;查不到 = 0 回溯。
func shooter_delay_ticks(shooter_role: int) -> int:
	if not peer_by_role.has(int(shooter_role)):
		return 0
	var wire: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Wire")
	if wire == null:
		return 0
	return LagComp.delay_ticks(wire.rtt_ms(int(peer_by_role[int(shooter_role)])), true)
# ── 断线宽限期读数 ── {role -> 剩余秒},由 worker 进程的 server_main 写入(它是宽限期表的持有者),三个 round_state 生产者
# 只负责并进载荷。★ 用「推」而不是让宿主反向持有引用(避免 back-reference);★ 每实例字段、不是 static;空 = 没人掉线(载荷里连 grace 键都不带)。
var grace_snapshot: Dictionary = {}
# 归因时效(3s)。★ 三个读者原先各抄一份同名常量,故收在底座(子类那两行必须删:同名遮蔽报错)。
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS
# 「这一下伤害是谁打的」的新鲜度阈值(ms)。★ 与 ATTRIB_WINDOW 是两个问题、两个窗口:3s 答「这次死亡算谁的击杀」,本阈值答「这一下」——共用会把一次 0.4s 引信的榴弹自爆也计入。★ 8ms 的依据:真实命中路径 attribute → take_hit →
# took_hit 是同一调用栈(年龄 ≈ 0~1ms),而上一物理帧留下的归因至少 ~16.7ms 之前。★★ 前提就是「归因与伤害同一调用栈」:将来新增延迟扣血型伤害必须自己每帧重写归因,否则被静默判成无攻击者(ACS 偏低)。
const ATTRIB_FRESH_MS := 8

# ── 仅测试用:定时拆一格 ── 由 --test-destroy-tile <col>,<row>[,<delay>] 写入,到点拆一次后置回 (-1,-1);★ 必须住基类:worker 是独立进程、探针拿不到 _host,只能让 worker 自己制造「世界变了」,而钩子由 MatchHost._physics_process 每帧调,兄弟域互相看不见。
static var test_destroy_cell := Vector2i(-1, -1)
static var test_destroy_after := 0.0     # 秒;从对局开始(_ready)起算


# v5:kind 是 int(WireKind.*);发送/判活收在 Wire.send_to 一个调用内。_rpc_all_ext 保留独立名字
# 只是免动调用点 —— v4 它存在的理由(原方法表冻结、扩展 RPC 只能挂另一节点)已随方法表一起废止。
func _rpc_all(kind: int, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in peer_by_role:
		if role == except_role or not players.has(role):
			continue
		var peer: int = peer_by_role[role]
		if live_only and not Wire.is_peer_live(peer):
			continue
		Wire.send_to(peer, kind, args)

func _rpc_all_ext(kind: int, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	_rpc_all(kind, args, except_role, live_only)


# round_state 的唯一出口:三个生产者拼完 data 后都必须调它,宽限期读数只在这里并进去一次。★ 不并进 _rpc_all(会让每条事件白背一个 grace),也不让三个生产者各写一句(三份必然漂,而「其中一个忘了」不报错)。⚠ 零守卫:grace_feed_probe ④ 已删(2026-10-09)。
func _send_round_state(data: Dictionary) -> void:
	GraceWindow.merge_into(data, grace_snapshot)
	_rpc_all(WireKind.ROUND_STATE, [data])




func _role_of(node: Node) -> int:
	for role in players:
		if players[role] == node:
			return int(role)
	return -1


# 两名玩家是否同队(给只拿得到节点的武器用)。★ 队伍表空 ⇒ 恒 false ⇒ 激光行为逐字不变(别改成「没表就返回 true」);★ 两种「查不到」都安全(_role_of 返回 -1,而 same_team(-1, -1) 也是 false)。
func is_friendly(a: Node, b: Node) -> bool:
	if a == null or b == null:
		return false
	return same_team(_role_of(a), _role_of(b))





func _stat_entry(role: int) -> Dictionary:
	role = int(role)
	if not _stats.has(role):
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0}
	return _stats[role]



func _kscore_of(role: int) -> int:
	var s: Dictionary = _stats.get(int(role), {})
	return ScoreRules.kscore(int(s.get("kills", 0)), int(s.get("assists", 0)),
			int(s.get("dealt", 0)), int(s.get("deaths", 0)),
			int(s.get("team_damage", 0)), int(s.get("self_damage", 0)),
			int(s.get("team_kills", 0)))


# ACS = kscore ÷ 局数。★ 不得再加伤害 —— 它已经在 kscore 里了;kscore 是伤害的唯一推导点(spec §1.4)。
func _acs_of(role: int) -> float:
	return ScoreRules.acs(_kscore_of(int(role)), _rounds_for(int(role)))


# ACS 的局数口径:全场已进行的局数;中途离开者冻结在他离开时所处的局号(= 实际参与局数),分母更小、ACS 偏高是有意口径。★ 卡在 MATCH_OVER 时 _round_num 恰好等于打过的局数。
func _rounds_for(role: int) -> int:
	return int(_left_round.get(int(role), _round_num))



func note_disconnect_round(role: int) -> void:
	_leave_round[int(role)] = _round_num



func _roster() -> Dictionary:
	var roles := {}
	for role in players:
		roles[int(role)] = true
	for role in _left:
		roles[int(role)] = true
	for role in _stats:
		roles[int(role)] = true
	return roles



func stats_payload() -> Dictionary:
	var out := {}
	for r in _roster():
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		out[role] = {
			"kills": int(s.get("kills", 0)),
			"deaths": int(s.get("deaths", 0)),
			"assists": int(s.get("assists", 0)),
			"dealt": int(s.get("dealt", 0)),
			"taken": int(s.get("taken", 0)),
			"kscore": _kscore_of(role),
			"acs": _acs_of(role),
		}
	return out


# MVP = 整场 ACS 最高者;并列 → 击杀多者 → 阵亡少者 → role 号升序。★ 候选按 role 升序遍历 + 只在严格更优时替换
# ⇒ 完全并列时天然胜者是最小 role,不依赖字典迭代顺序。★★ 已离开者照样参与评选(用户裁定,不是遗漏)。
func mvp_role() -> int:
	var best_role := 0
	var best_acs := -1.0
	var best_kills := -1
	var best_deaths := 1 << 30
	var roles: Array = _roster().keys()
	roles.sort()
	for r in roles:
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		var acs := _acs_of(role)
		var kills := int(s.get("kills", 0))
		var deaths := int(s.get("deaths", 0))
		if acs > best_acs \
				or (acs == best_acs and (kills > best_kills
						or (kills == best_kills and deaths < best_deaths))):
			best_role = role
			best_acs = acs
			best_kills = kills
			best_deaths = deaths
	return best_role


# ★ 写端不过滤队伍 —— 过滤只有一处,在 _record_down 的读端(写端过滤会让「队友误伤拿助攻」这条规则散成两份判断)。
func _note_hit(victim_role: int, attacker_role: int) -> void:
	victim_role = int(victim_role)
	attacker_role = int(attacker_role)
	if not _assist_times.has(victim_role):
		_assist_times[victim_role] = {}
	(_assist_times[victim_role] as Dictionary)[attacker_role] = Time.get_ticks_msec()



func _clear_assist_table(victim_role: int) -> void:
	_assist_times.erase(int(victim_role))


# 逐人数据的唯一写入口(每次倒地边沿调一次)。★ deaths 一律 +1(队友误炸/自杀/溺水全算死);★ kills 只在「归因到
# 且异队」时记给杀手 —— 无归因与同队误炸不计任何人的击杀(与「那一分照样给对方队」是两件事)。
func _record_down(victim_role: int, killer_role: int) -> void:
	victim_role = int(victim_role)
	killer_role = int(killer_role)
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0:
		return          # 无归因:不计任何人的击杀,**也不计任何人的助攻**
	if same_team(killer_role, victim_role):
# ★ 队友击杀:不记 kills、也不记助攻(没有「自己队的击杀」这回事);代价记在肇事者行上(team_kills)。
		var tm := _stat_entry(killer_role)
		tm["team_kills"] = int(tm["team_kills"]) + 1
		return

	if time_economy != null:
		time_economy.award_kill(killer_role, victim_role)
	var k := _stat_entry(killer_role)
	k["kills"] = int(k["kills"]) + 1
# ── 助攻:表里除击杀者之外、在归因窗口内、且与击杀者同队的 attacker ── ★★ 规则只有这一条:原先还挂着的
# or same_team(attacker, victim_role) 是死代码(上面那道同队早退已保证击杀者与受害者异队)。★★ 前提是「那道早退还在」且「same_team 是等价比对」—— 它一旦变成非传递关系(如引入联盟),那个 or 就不再是死代码。⚠ 零守卫:team_host_probe (k4) 已删(2026-10-09)。
	var now := Time.get_ticks_msec()
	var table: Dictionary = _assist_times.get(victim_role, {})
	for a in table:
		var attacker := int(a)
		if attacker == killer_role:
			continue
		if now - int(table[a]) > ATTRIB_WINDOW:
			continue
		if not same_team(attacker, killer_role):
			continue
		var sa := _stat_entry(attacker)
		sa["assists"] = int(sa["assists"]) + 1


# 「这一下伤害是谁打的」—— 无归因 → 0。★ 必须有一个紧窗口而不是复用 3s:写端在 attacker == victim 时静默跳过,
# 自伤路径上 meta 会停在上一名敌人身上 ⇒「自己的榴弹炸自己」被错记成那名敌人。⚠ 已知边界(登记不修):同一帧内先被敌人打中、再被自己的爆炸炸到,那一下仍记到敌人账上。
func _fresh_attacker_role(victim_role: int) -> int:
	var victim: Node2D = players.get(int(victim_role))
	if victim == null or not is_instance_valid(victim):
		return 0
	return _attributed_role_within(victim, ATTRIB_FRESH_MS)


# 「上一个打 victim 的人」,归因年龄 ≤ window_ms(超窗/无归因/自伤 → 0)。★ 窗口是参数而不是常量:两个读者问的是两个不同的问题(击杀归属 3s / 逐人伤害 8ms);★ shooter == victim 的守卫不可省(防有人绕过写端直接 set_meta)。
func _attributed_role_within(victim: Node2D, window_ms: int) -> int:
	if not victim.has_meta("last_damager"):
		return 0
	var shooter: Node = victim.get_meta("last_damager")
	if shooter == null or not is_instance_valid(shooter) or shooter == victim:
		return 0
	if victim.has_meta("last_damager_time"):
		if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) > window_ms:
			return 0
	for role in players:
		if players[role] == shooter:
			return int(role)
	return 0





func _spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))



func role_spawns() -> Dictionary:
	var out := {}
	for role in players:
		out[int(role)] = _spawn_cell(int(role))
	return out


