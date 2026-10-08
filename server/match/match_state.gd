class_name MatchState
extends Node

# 对局权威的共享状态基类：
# 集中维护各模式（1v1、大乱斗、3v3）通用的对局实体、输入队列、地图网格、队伍划分与统计数据。
# 继承结构：RoyaleHost / TeamHost -> MatchHost -> MatchRound -> MatchCombat -> MatchSnapshot -> MatchState -> Node

var players: Dictionary = {}        # 角色实体字典：role(int) -> Player 节点
var input_sources: Dictionary = {}  # 输入源字典：role -> PacketInputSource
var peer_by_role: Dictionary = {}   # 网络连接映射：role -> peer_id
var _pending_input: Dictionary = {} # 待消费输入数据包队列：role -> Array[输入包]
var grid: Array = []
var _base_grid: Array = []   # 对局初始地图网格快照，用于瓦片破坏差量比对与重置

# 队伍映射表：role(int) -> 队伍编号（1 或 2），空字典表示无队伍模式（1v1、大乱斗）
var _team_of: Dictionary = {}

# 时间玩法经济系统实例（常规模式下为 null）
var time_economy = null

# 时间玩法回溯状态记录
var _rw_on: Dictionary = {}        # 角色回溯状态标记：role -> bool
var _rw_trail: Dictionary = {}     # 角色回溯轨迹坐标历史


# 根据节点反查对应的角色编号（未找到返回 0）
func _role_of_node(n: Node) -> int:
	if n == null:
		return 0
	for r in players:
		if players[r] == n:
			return int(r)
	return 0


# 获取角色队伍编号（未分配队伍返回 0）
func team_of(role: int) -> int:
	return int(_team_of.get(int(role), 0))


# 判定两个角色是否处于同一队伍（无队伍时恒返回 false）
func same_team(a_role: int, b_role: int) -> bool:
	var a := team_of(a_role)
	var b := team_of(b_role)
	return a > 0 and a == b


# 获取相较于初始网格已被破坏或改变的瓦片坐标列表
# 供客户端断线重连或进场同步（match_sync）时拉取
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
var _snapshot_accum := 0.0
const SNAPSHOT_INTERVAL := 1.0 / 60.0   # 60Hz 快照广播周期（秒）
# 子弹与爆炸对玩家的命中判定半径（像素）
const HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS
var _seen_bullets: Dictionary = {}  # 已广播子弹实例追踪字典
var _snap_tick := 0   # 快照单调自增序号
var _ack_seq: Dictionary = {}   # 已确认消费的输入包序号：role(int) -> seq

# ── 对局选项与规则参数 ──
var _options: Dictionary = {}
var _round_full_heal := false        # 每回合开始双方恢复满血
var _disabled_weapons: Array[int] = []   # 禁用的武器类型编号列表
var _ai_roles: Array = []            # AI 补位角色编号列表

# ── 回合制状态机与比分 ──
enum RoundState { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER }
const KILLS_TO_WIN := 5      # 胜局所需击杀数
const ROUNDS_TO_WIN := 2     # 胜场所需回合数
const COUNTDOWN_TIME := 3.0  # 倒计时时长（秒）
const ROUND_OVER_TIME := 4.0 # 回合结束展示时长（秒）
const RESPAWN_DELAY := 2.0   # 死亡复活延迟（秒）
var _round_state := RoundState.COUNTDOWN
var _round_num := 1
var _scores: Dictionary = {}     # 各角色本局击杀数
var _rounds_won: Dictionary = {} # 局胜计数（1v1 为角色编号，3v3 为队伍编号）
var _round_timer := 0.0
var _side_swap := false          # 换边标记
var _respawn_pending: Dictionary = {}  # 复活倒计时：role -> 剩余秒数
var _down_counted: Dictionary = {}     # 倒地计分判定标记：role -> bool
var _last_round_winner := 0            # 最近一回合获胜角色编号

# ── 逐人统计数据 ──
var _stats: Dictionary = {}          # 角色累计统计数据：role -> 原始计数项
var _left_round: Dictionary = {}     # 角色离开对局时的局号
var _leave_round: Dictionary = {}    # 角色断开连接时的局号
var _assist_times: Dictionary = {}   # 助攻时效追踪表：victim_role -> {attacker_role: 命中时间戳}
var _left: Dictionary = {}           # 已离开对局角色集合：role -> true

# ── 断线宽限期快照 ──
# 记录掉线角色的剩余宽限期秒数：role -> 剩余秒数
var grace_snapshot: Dictionary = {}
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS # 击杀归因时间窗口（毫秒）
const ATTRIB_FRESH_MS := 8 # 单次伤害归因新鲜度阈值（毫秒）

# ── 自动化测试辅助控制变量 ──
static var test_destroy_cell := Vector2i(-1, -1)
static var test_destroy_after := 0.0     # 延迟触发时间（秒）


func _rpc_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in peer_by_role:
		if role == except_role or not players.has(role):
			continue
		var peer: int = peer_by_role[role]
		if live_only and not NetBus.is_peer_live(peer):
			continue
		NetBus.callv("rpc_id", [peer, method] + args)

# 向所有客户端广播 NetBusExt 扩展 RPC
func _rpc_all_ext(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in peer_by_role:
		if role == except_role or not players.has(role):
			continue
		var peer: int = peer_by_role[role]
		if live_only and not NetBus.is_peer_live(peer):
			continue
		NetBusExt.callv("rpc_id", [peer, method] + args)


# 统一广播 round_state 回合状态载荷，合并断线宽限期快照
func _send_round_state(data: Dictionary) -> void:
	GraceWindow.merge_into(data, grace_snapshot)
	_rpc_all("round_state", [data])


# 根据节点对象查找对应的角色编号，未找到返回 -1

func _role_of(node: Node) -> int:
	for role in players:
		if players[role] == node:
			return int(role)
	return -1


# 判定两名玩家节点是否属于同一队伍
func is_friendly(a: Node, b: Node) -> bool:
	if a == null or b == null:
		return false
	return same_team(_role_of(a), _role_of(b))


# ── 逐人统计数据访问接口 ──

# 获取或初始化指定角色的统计数据字典
func _stat_entry(role: int) -> Dictionary:
	role = int(role)
	if not _stats.has(role):
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0}
	return _stats[role]


# 计算指定角色的战斗总积分
func _kscore_of(role: int) -> int:
	var s: Dictionary = _stats.get(int(role), {})
	return ScoreRules.kscore(int(s.get("kills", 0)), int(s.get("assists", 0)),
			int(s.get("dealt", 0)), int(s.get("deaths", 0)),
			int(s.get("team_damage", 0)), int(s.get("self_damage", 0)),
			int(s.get("team_kills", 0)))


# 计算指定角色的平均战斗得分
func _acs_of(role: int) -> float:
	return ScoreRules.acs(_kscore_of(int(role)), _rounds_for(int(role)))


# 获取指定角色参与的回合数（中途离开者保留其离开时的回合数）
func _rounds_for(role: int) -> int:
	return int(_left_round.get(int(role), _round_num))


# 记录角色断开连接时所处的回合数
func note_disconnect_round(role: int) -> void:
	_leave_round[int(role)] = _round_num


# 获取所有参战角色集合（包含在场角色、离开角色及有统计数据的角色）
func _roster() -> Dictionary:
	var roles := {}
	for role in players:
		roles[int(role)] = true
	for role in _left:
		roles[int(role)] = true
	for role in _stats:
		roles[int(role)] = true
	return roles


# 构造逐人战斗统计数据载荷
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


# 评选对局 MVP：优先取 ACS 最高者；并列时比较击杀数与阵亡数
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


# 记录攻击命中时间戳，用于助攻判定
func _note_hit(victim_role: int, attacker_role: int) -> void:
	victim_role = int(victim_role)
	attacker_role = int(attacker_role)
	if not _assist_times.has(victim_role):
		_assist_times[victim_role] = {}
	(_assist_times[victim_role] as Dictionary)[attacker_role] = Time.get_ticks_msec()


# 清空指定受害者的助攻记录（角色复活时调用）
func _clear_assist_table(victim_role: int) -> void:
	_assist_times.erase(int(victim_role))


# 角色倒地时记录统计数据（击杀、阵亡、误伤与助攻）
func _record_down(victim_role: int, killer_role: int) -> void:
	victim_role = int(victim_role)
	killer_role = int(killer_role)
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0:
		return
	if same_team(killer_role, victim_role):
		var tm := _stat_entry(killer_role)
		tm["team_kills"] = int(tm["team_kills"]) + 1
		return
	if time_economy != null:
		time_economy.award_kill(killer_role, victim_role)
	var k := _stat_entry(killer_role)
	k["kills"] = int(k["kills"]) + 1
	# 助攻判定：在伤害时间窗口内造成伤害且与击杀者同队的攻击者计为助攻
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


# 获取最近一次伤害的攻击者角色编号（要求命中时间在新鲜度阈值内）
func _fresh_attacker_role(victim_role: int) -> int:
	var victim: Node2D = players.get(int(victim_role))
	if victim == null or not is_instance_valid(victim):
		return 0
	return _attributed_role_within(victim, ATTRIB_FRESH_MS)


# 检查受害者在指定时间窗口内的攻击者角色编号
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


# ── 出生点查询接口 ──

func _spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))

# 获取各角色预设出生点字典
func role_spawns() -> Dictionary:
	var out := {}
	for role in players:
		out[int(role)] = _spawn_cell(int(role))
	return out
