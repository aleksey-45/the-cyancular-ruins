class_name MatchState
extends RefCounted

# 对局权威的共享状态(C 方案 S4b):纯数据 + 纯查询;由 MatchHost 持有(state),不再在继承链上。
# 原「为什么共享字段要住共同祖先」的链式说明已随拆解失效;现行结构见 docs/eng/netplay.md「权威宿主的结构」。

const HitLagHistory := preload("res://core/sim/hit_lag_history.gd")

var players: Dictionary = {}
var input_sources: Dictionary = {}
var peer_by_role: Dictionary = {}
var _pending_input: Dictionary = {}
var grid: Array = []
var _base_grid: Array = []

var _team_of: Dictionary = {}

var time_economy = null


var _rw_on: Dictionary = {}
var _rw_trail: Dictionary = {}



func team_of(role: int) -> int:
	return int(_team_of.get(int(role), 0))


# 两个 role 是否同队 —— 单一来源:子弹穿透队友、出生/复活分组、复位归属都问它。★ 任一方为 0(无队伍)一律 false:
# 0 == 0 若算同队,1v1 里两个玩家会被判成队友、子弹全穿。
func same_team(a_role: int, b_role: int) -> bool:
	var a := team_of(a_role)
	var b := team_of(b_role)
	return a > 0 and a == b


func _opponent_of(role: int) -> int:
	for r in players:
		if int(r) != role:
			return int(r)
	return 0


func destroyed_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var rows := mini(grid.size(), _base_grid.size())
	for y in rows:
		var cur: Array = grid[y]
		var base: Array = _base_grid[y]
		var cols := mini(cur.size(), base.size())
		for x in cols:
			if int(cur[x]) != int(base[x]):
				out.append(Vector2i(x, y))
	return out


func damaged_partial_subs() -> Array[Vector2i]:
	return TileResync.partial_damaged_subs(damaged_subs, grid, _base_grid)

var destructible_sub: Array = []
var _dirty_chunks: Dictionary = {}
# 本局被摧毁过的 16px 子格(Vector2i → true):换局增量复位只还这些格(全量 build_sim 实测 ~0.48s ⇒ 每局卡顿)。
var damaged_subs: Dictionary = {}
var _snapshot_tick_phase := 0
const SNAPSHOT_HZ := 60
const SNAPSHOT_INTERVAL := 1.0 / SNAPSHOT_HZ
const SNAPSHOT_STRIDE := 60 / SNAPSHOT_HZ
var _seen_bullets: Dictionary = {}
var _snap_tick := 0
var _srv_tick := 0
var _lag_hist := HitLagHistory.new()
var _ack_seq: Dictionary = {}
var _stepped_seq: Dictionary = {}
var _stepped_seq_pending := false
# ★ 上行扩展字段:st 是命中回放的时间基准(2026-10-26 起有消费者);ct(客户端物理帧号)仍只落位。
var _client_snap_tick: Dictionary = {}
var _client_tick: Dictionary = {}


var _round_full_heal := false
var _disabled_weapons: Array[int] = []
var _ai_roles: Array = []


enum RoundState { COUNTDOWN, PLAYING, ROUND_OVER, MATCH_OVER }
const KILLS_TO_WIN := 5
const ROUNDS_TO_WIN := 2
const COUNTDOWN_TIME := 3.0
const ROUND_OVER_TIME := 4.0
const RESPAWN_DELAY := 2.0
const COUNTDOWN_HOLD_MAX := 2.0
const COUNTDOWN_RESYNC := 0.5
var _countdown_hold := COUNTDOWN_HOLD_MAX
var _client_ready: Dictionary = {}
var _countdown_bcast_done := false
var _countdown_resync := 0.0
var _round_state := RoundState.COUNTDOWN
var _round_num := 1
var _scores: Dictionary = {}
var _rounds_won: Dictionary = {}
var _round_timer := 0.0
var _side_swap := false
var _map_spawn_data: Dictionary = {}
var _map_spawn_data_loaded := false
var _duel_spawns: Dictionary = {}
var _duel_placed: Dictionary = {}
var _respawn_pending: Dictionary = {}
var _down_counted: Dictionary = {}
var _last_round_winner := 0

# ── 逐人统计(三模式共用)── ★ 条目只存原始计数,kscore / acs 一律读时推导:存一份算好的 kscore 就等于「加了新惩罚却
# 忘了同步」这种不报错的静默缺陷。★ 载荷才用 spec §3.1 的七个字段(kills/deaths/assists/dealt/taken/kscore/acs)。
var _stats: Dictionary = {}
var _left_round: Dictionary = {}
var _leave_round: Dictionary = {}
var _assist_times: Dictionary = {}
var _left: Dictionary = {}
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS
# 「这一下伤害是谁打的」的新鲜度阈值(ms)。
# took_hit 是同一调用栈(年龄 ≈ 0~1ms),而上一物理帧留下的归因至少 ~16.7ms 之前。★★ 前提就是「归因与伤害同一调用栈」:将来新增延迟扣血型伤害必须自己每帧重写归因,否则被静默判成无攻击者(ACS 偏低)。
const ATTRIB_FRESH_MS := 8

# ── 仅测试用:定时拆一格 ── 由 --test-destroy-tile <col>,<row>[,<delay>] 写入,到点拆一次后置回 (-1,-1);★ 必须住基类:worker 是独立进程、探针拿不到 _host,只能让 worker 自己制造「世界变了」,而钩子由 MatchHost._physics_process 每帧调,兄弟域互相看不见。
static var test_destroy_cell := Vector2i(-1, -1)
static var test_destroy_after := 0.0


func _role_of(node: Node) -> int:
	for role in players:
		if players[role] == node:
			return int(role)
	return -1


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


func _acs_of(role: int) -> float:
	return ScoreRules.acs(_kscore_of(int(role)), _rounds_for(int(role)))


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


func mvp_role(candidates: Array = []) -> int:
	var table := {}
	for r in _roster():
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		table[role] = {"acs": _acs_of(role), "kills": int(s.get("kills", 0)),
				"deaths": int(s.get("deaths", 0))}
	return ScoreRules.pick_mvp(table, candidates)


# ★ 写端不过滤队伍 —— 过滤只有一处,在 _record_down 的读端(写端过滤会让「队友误伤拿助攻」这条规则散成两份判断)。
func _note_hit(victim_role: int, attacker_role: int) -> void:
	victim_role = int(victim_role)
	attacker_role = int(attacker_role)
	if not _assist_times.has(victim_role):
		_assist_times[victim_role] = {}
	(_assist_times[victim_role] as Dictionary)[attacker_role] = Time.get_ticks_msec()



func _clear_assist_table(victim_role: int) -> void:
	_assist_times.erase(int(victim_role))


func _record_down(victim_role: int, killer_role: int) -> void:
	victim_role = int(victim_role)
	killer_role = int(killer_role)
	if victim_role < 0:
		return
	if killer_role < 0:
		killer_role = 0
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





func map_spawn_data() -> Dictionary:
	if not _map_spawn_data_loaded:
		_map_spawn_data_loaded = true
		_map_spawn_data = MazeGenerator.load_spawns()
	return _map_spawn_data


func map_respawn_points(side: int) -> Array:
	return SpawnPicker.filter_reachable((map_spawn_data().get("respawns", {}) as Dictionary).get(int(side), []))


func map_all_respawn_points() -> Array:
	var sides: Dictionary = map_spawn_data().get("respawns", {})
	var out: Array = []
	out.append_array(sides.get(1, []))
	out.append_array(sides.get(2, []))
	return SpawnPicker.filter_reachable(out)


static var _warned_legacy_spawn := false


func _warn_legacy_spawn() -> void:
	if _warned_legacy_spawn:
		return
	_warned_legacy_spawn = true
	push_warning("MatchState: 地图没有 # respawn 行 —— 出生/复活回退 # player/# player2 旧两点;要按侧数据驱动请用 tools/map_spawn_meta.gd 写入地图")


func _duel_side(role: int) -> int:
	return SpawnChooser.SIDE_LEFT if (int(role) == 1) != _side_swap else SpawnChooser.SIDE_RIGHT


func _legacy_spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))

