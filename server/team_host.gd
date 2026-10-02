class_name TeamHost
extends MatchHost

# 3v3 团队对抗权威对局(第三个模式宿主,与 RoyaleHost 平级)。
#  - 6 人(两队各 3)、三局两胜、每队先到 TEAM_KILLS_TO_WIN 击杀赢一局、局间**整队换边**;
#    局内死亡 2s 复活。★ 击杀后**不**复位任何人(2026-09-21 用户要求删掉「把击杀者送回本方
#    出生点」那条规则):击杀者原地不动 —— 代价与理由见 `_match_round_tick` 里那段。
#  - 计分**不分死因**:任一玩家倒地 → 对方队 +1(枪杀/爆炸/溺水/自伤/队友误炸一律如此)。
#  - 子弹穿透队友(在 MatchCombat 裁决层,按 role 判);**爆炸对队友满效**(现状行为,未改)。
#  - 掉线:宽限期内身体留场;宽限期到点走 `mark_disconnected` —— **整队走光才终局**(掉 1 人
#    该队少人继续打),且**走光即弃权**:胜者 = 存活的对方队,两队都走光 = 平局(见 `_match_winner`)。
#  - 队伍归属来自 `MatchState._team_of`(由大厅经 `--teams` 显式传入)。
#
# ★ 继承链与中间层纪律同 RoyaleHost:本类是末端子类,生命周期钩子只能出现在这里。
# ★ `_init` 顺序不可整理:父类 `_init` 会**虚调** `_spawn_cell(role)` 摆位,那时 `_round_spawns`
#   必须已就绪(与 RoyaleHost 同一个坑,见 royale_host.gd:35-37)。

const TEAM_KILLS_TO_WIN := 9     # ★ 不能叫 KILLS_TO_WIN:基类 MatchState 已有该常量,同名遮蔽会报错
const TEAM_ROUNDS_TO_WIN := 2    # ★ 同上,基类是 ROUNDS_TO_WIN
# `_endgame_winner` 的"未定"哨兵。★ 三态,不能拿 0 当"未定":0 是**合法结果**
# (两队都走光 = 平局),它正是这个字段要表达的东西之一。
const ENDGAME_NONE := -1
const SPAWN_CLEARANCE := 15      # 两个基座的最小环面距离(格)
const TEAMMATE_CLEARANCE := 3    # 队内三人最小间距(格):够散开,又不至于走出"队形"
const SPAWN_BASE_RADIUS := 30    # 基座附近取点半径(格);池子不够会退回全量候选
const SPAWN_MAX_TRIES := 12      # 散点重试次数(见 plan_team_spawns 的说明;每份只要 ~几十微秒)
const RESPAWN_CLEARANCE := 8     # 复活点离**存活敌人**的最小环面距离(格)
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS   # 击杀归因时效(3s),与 RoyaleHost 同源
# ★ 队 B 的身体层(层位 5,值 16)。全仓层位占用:1 地形 / 2 玩家 / 4 敌人 / 8 掉落物(WeaponPickup)
#   —— 第 5 位在本批之前**无人占用**(唯一另一处用值 16 的是 `tests/replica_ghost_probe.gd` 的
#   备用障碍层,那是探针自己世界里的东西,与生产无关)。契约由 `_init` 末段与探针 ⑩ 共同钉住。
const TEAM_ENEMY_LAYER := 16

# ── 逐人数据 / ACS(B 册 Task 10,只做数据面)──
# 击杀分(Valorant 式"遭遇分"):按**倒下瞬间的敌方存活人数**加权,线性 +20/人:
#   1 人 → 70 / 2 → 90 / 3 → 110 / 4 → 130 / 5 → 150(公式 = BASE + PER_ALIVE × 人数)。
# ★★ 人数**含被击杀者本人** —— 这张表的定义是"首杀最高、收尾最低":首杀时敌方 5 人全在(150),
#   收尾时敌方只剩他一个(70)。数"倒下**之后**还剩几个"会得到 4…0,与表对不上(且 0 无档)。
# ★ 3v3 一队只有 3 人 ⇒ 实际只会取到 1/2/3(70/90/110);上限 5 是 Valorant 的 5v5 口径。
const KILL_BONUS_BASE := 50         # 公式基线:50 + 20×人数
const KILL_BONUS_PER_ALIVE := 20
const KILL_BONUS_MIN_ALIVE := 1
const KILL_BONUS_MAX_ALIVE := 5
const MULTI_KILL_BONUS := 50        # 同一局内该 role 的第 2、3… 个击杀,每个再 +50
# ★ 死亡**不扣分**:Riot 的 ACS 不含死亡惩罚,本仓不自己发明扣分(用户裁定)。
#   `deaths` 只用于展示与 MVP 并列判据。
#
# ★★ 伤害归因的"新鲜度"阈值(ms)—— 本任务最容易漏的一处:
#   `CombatFeedback.attribute()` 在 `attacker == victim` 时**静默跳过**(自伤不归因给自己),
#   于是自伤路径上 meta 会**停在上一名敌人**身上,而读端只看"有没有 meta + 在不在时效内"
#   ⇒ "自己的榴弹炸自己"会被错记成那名敌人的伤害。故读"这一下伤害是谁打的"必须用**紧窗口**。
# ★ 不能与击杀口径共用:击杀读的 `ATTRIB_WINDOW`(3s)是 A 册定的——"打一枪后 3s 内溺水仍算
#   你的击杀";拿它判"这一下伤害是谁打的"太宽(一次 0.4s 引信的榴弹自爆就会被计入)。
# ★ 阈值怎么定:真实命中路径的 `attribute()` → `take_hit()` → `took_hit` 信号是**同一调用栈**,
#   年龄 ≈ 0~1ms;而**上一物理帧**留下的归因至少 ~16.7ms 之前(60Hz)。8ms 落在两者之间:
#   容得下跨一次毫秒边界,又把"上一帧那次命中"挡在外面(< 一帧,故上一帧的归因必被拒)。
# ★ 已知边界(登记在报告里,未修):同**一帧**内先被敌人打中、再被自己的爆炸炸到,meta 仍是
#   那名敌人且年龄 ≈ 0 —— 那一下会被记到敌人账上。根治要改写端(`CombatFeedback`/`Explosion`),
#   不在本任务范围。
# ★★ 阈值成立的前提是"**归因与伤害同一调用栈**"(真实命中路径 ≈ 0~1ms)。**将来新增
#   「延迟扣血」型伤害必须自己每帧重写归因** —— `LaserWeaponBase` 的**缝 2**(命中结算)明确
#   把"持续/灼烧型"列为**预定扩展位**,而那种实现是"命中时写一次归因、后续帧再扣血":扣血
#   那一刻 meta 的年龄早已 > 8ms ⇒ 被**静默**判成"无攻击者",逐人 `dmg` 恒少且不报错
#   (没有断言、没有日志,只是 ACS 数字偏低)。写端不重写归因的话,这条阈值就是那个扩展位的
#   唯一提示。
const ATTRIB_FRESH_MS := 8

var _round_spawns: Dictionary = {}   # role -> Vector2i(本局出生点,与 match_start 广播的同一份)
var _swap_spawns: Dictionary = {}    # role -> Vector2i(换边后的点;两队点集整体对调)
var _spawned_once: Dictionary = {}   # role -> true(首次摆位走出生点,之后走动态复活点)
var _left: Dictionary = {}           # role -> true(已移出对局;排行榜/比分判据用)
# 走光(弃权)终局的胜者队:1/2 = 判胜,0 = 平局(两队都走光),ENDGAME_NONE = 未定(正常路径)。
# ★ 它**只**由 `mark_disconnected` 写、**只**由 `_match_winner` 首行读 —— 让 `match_winner`
#   仍然只有一个来源(`_broadcast_round_state` 照旧不碰它)。
var _endgame_winner := ENDGAME_NONE

# ── 逐人数据(整场累计;与 `_scores` 是两份不同的东西,见 `_start_next_round` 的注释)──
var _stats: Dictionary = {}          # role -> {kills, deaths, dmg, kscore}(整场不清零)
var _round_kills: Dictionary = {}    # role -> **本局**已击杀数(多杀加成的判据;每局清零)
var _left_round: Dictionary = {}     # role -> 离开时所处的局号(ACS 的"实际参与局数"口径)


func _init(map_path: String, role_peers: Dictionary, options: Dictionary = {},
		ai_roles: Array = [], spawns: Dictionary = {}, teams: Dictionary = {}) -> void:
	# 散点必须在 super._init() 之前就绪(父类 _init 会虚调 _spawn_cell 摆位)
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		MazeGenerator.set_map_file(map_path)
		WorldBuilder.load_grid()
	_team_of = teams.duplicate()
	# ★ spawns 传空 = 手工/测试路径,才自己算一份。常规路径由 start_on 算好传进来 ——
	#   `plan_team_spawns` 内部走 `spread_cells`(有 shuffle),重算会得到**另一份**散点,
	#   而广播给客户端的是 start_on 那一份(与 RoyaleHost 完全同款纪律)。
	_round_spawns = spawns if not spawns.is_empty() else plan_team_spawns(_team_of)
	_swap_spawns = compute_swap_spawns(_round_spawns, _team_of)
	# ★ 第 5 个实参是 `teams`,**不是** `spawns`(`RoyaleHost` 那两个参数同名易混)。
	#   传错的后果不是崩溃而是"整局队伍判定全错":`_team_of` 被塞成 `{role: Vector2i}`,
	#   `team_of()` 里 `int(Vector2i)` 报 `Nonexistent 'int' constructor` 并让该函数当场返回 0
	#   → 子弹不穿队友、`team_map()` 下发空表。守卫:`tests/team_host_probe` 的 ③ 直读
	#   `_team_of` 逐值断言 `typeof(...) == TYPE_INT`(只断言"非空"抓不到这一档)。
	super._init(map_path, role_peers, options, ai_roles, teams)

	# ── 队友不互挡(用户裁定"完全穿透")──
	# ★ 为什么必须"分队位"而不是改掩码:Godot 的碰撞**按节点**配,没有"按对"的开关。
	#   全部玩家同在第 2 层时,掩码含 2 就是"与所有玩家碰撞",无法只豁免队友。
	#   把队 B 挪到新层位 16,让两队掩码**互指对方的位**,即可 A↔B 挡、A↔A 与 B↔B 穿。
	# ★ 必须在 super._init **之后**:super 的建玩家循环里已经给每个人 `mask |= 2`。
	#   队 A 要把那一位**抹掉**再补上 16;队 B 则保留 super 给的 7(1|4|2)—— 正是它要的。
	# ★ 单机 / 1v1 / 大乱斗一行不受影响:它们不走本类。
	# ★ 契约(客户端那一半归 B 册 Task 6,按同一张表实现):
	#   1 队 layer=2 / mask=1|4|16(=21),2 队 layer=16 / mask=1|2|4(=7)。
	#   两队掩码都**保留**地形(1)与敌人(4)—— 抹掉 2 时把它们一起丢掉的话,该队会**穿墙**。
	_apply_team_layers()


# 按队给**在场的每个玩家**配碰撞层/掩码(机制说明见 `_init` 里那一段)。
# ★ 为什么单独成一个函数、而不是把这几行写在 `_init` 里:探针用「`role_peers` 传空 + 手工摆位」
#   建宿主,那条路径下 `players` 在 `_init` 那一刻**还是空的** —— 逻辑只写在 `_init` 里的话,
#   探针就只能**自己再抄一份**配层规则,于是它验的是抄件、不是生产代码(本仓明令禁止的
#   "第二份真相";`tests/team_host_probe.gd` 的 `_place` 正是为这个显式补调本函数)。
# ★ 幂等:重复调用没副作用(直接赋值,不叠加),故手工摆位路径可以放心再调一次。
func _apply_team_layers() -> void:
	for role in players:
		var p: Node2D = players[role]
		if p == null or not is_instance_valid(p):
			continue
		# ★ 队号必须**穷举** 1/2,不能写成 `if t == 1 … else …`:表外 role 的队号是 **0**
		#   ("查不到队伍"),`else` 会把它静默划进 **2 队**的身体层 —— 后果是**非对称碰撞**
		#   (它与 1 队互挡、与 2 队互穿),而且**不报错**,玩到才发现。故未知队号出声。
		# ★ 先拦再分(`continue` 写在**下面的 `match` 之外**),为的是不依赖那条容易记反的规则:
		#   **GDScript 的 `match` 体内 `continue` 在非末臂里会"落到下一个 pattern"** ——
		#   实测 `match i: 1: print("arm1"); continue` 会**继续执行 `2:` 那段**(arm1 与 arm2 都打印);
		#   而写在**末臂(`_`)**里则等同外层循环的 continue(实测有效)。
		#   两半都反直觉,所以这里干脆不用它:先 `if` 拦掉未知队号,剩下的 `match` 只列 1/2。
		# ★ 未知队号**什么都不配** = 保持 `super._init` 给的默认(层 2 / 掩码 7,即"全员互挡"),
		#   而不是把它当成某一队 —— 未知归属下"多挡一层"是可解释的,"少挡一层"不是。
		var t := team_of(int(role))
		if t != 1 and t != 2:
			push_error("TeamHost: role %d 的队号是 %d(不在 {1,2} 里),不配分队碰撞层" % [int(role), t])
			continue
		match t:
			1:
				p.collision_layer = 2
				p.collision_mask = (p.collision_mask & ~2) | TEAM_ENEMY_LAYER
			2:
				p.collision_layer = TEAM_ENEMY_LAYER


# ── 开局(在 worker 进程调用):算散点 → 逐角色 match_start → 建 TeamHost ──
static func start_on(role_peers: Dictionary, map_path: String, options: Dictionary = {},
		teams: Dictionary = {}) -> Node:
	MazeGenerator.set_map_file(map_path)
	GameParameters.refresh_map_size()
	if MazeGenerator.current_grid == null or MazeGenerator.current_grid.is_empty():
		WorldBuilder.load_grid()
	var spawns := plan_team_spawns(teams)
	for role in role_peers:
		# 判活:报到与开局之间客户端可能已断开,定向可靠包发往正在断开的 peer 就是那条
		# channel 0 错误(判据见 NetBus.is_peer_live,与 RoyaleHost.start_on 同款)
		if not NetBus.is_peer_live(role_peers[role]):
			continue
		NetBus.rpc_id(role_peers[role], "match_start", role, spawns[role], map_path)
		NetBus.rpc_id(role_peers[role], "server_message", "3v3 开始")
	# 把**同一份**散点传进宿主:它据此摆位,而上面已把同一份经 match_start 广播给客户端
	return TeamHost.new(map_path, role_peers, options, [], spawns, teams)


# 按队出生散点:① 取两个相距 ≥ SPAWN_CLEARANCE 的基座;② 每队基座附近取 3 个散点(队内 ≥
# TEAMMATE_CLEARANCE)。→ 队内聚、队间远。
# ★ 与 `RoyaleHost.plan_spawns` 同一条纪律:**不得在广播之后再调一次**(内部有 shuffle)。
#
# ★★ 为什么外面套了一层重试循环(偏 brief 一处,**已记入 task-4-report**):
#   上面那两句话**并不**蕴含"队间远"。半径 30 的点云在 150×100 的环面上重叠得很厉害,
#   而基座只保证"相距 ≥ 15 格" —— 实测 200 次里 **123 次(61.5%)队间最小距 ≤ 队内最大距**,
#   最坏情况两队有人落在**同一格**(队间距 = 0)。散点本来就是洗牌撒出来的,故:
#   多试几份、挑一份真正满足"队间远"的;试满 SPAWN_MAX_TRIES 次仍不满足,就退回其中
#   **最好**的那一份(绝不返回空表 —— 那会让 `start_on` 的 `spawns[role]` 缺键)。
#   ★ 六个常量与签名一个没动;实测 200/200 满足(最差队间距从 0 抬到 20)。
static func plan_team_spawns(teams: Dictionary) -> Dictionary:
	var best := {}
	var best_margin := -(1 << 30)   # ★ GDScript 不接受 `-1 << 30`(移位只收正操作数)
	for _attempt in range(SPAWN_MAX_TRIES):
		var cand := _plan_team_spawns_once(teams)
		var margin := _spawn_margin(cand, teams)
		if margin > best_margin:
			best_margin = margin
			best = cand
		if margin > 0:
			break
	return best


# 单次散点(挑中就用它)。★ 本函数**逐字**来自 brief;重试与"哪一份更好"的判断在外面。
static func _plan_team_spawns_once(teams: Dictionary) -> Dictionary:
	var d := SpawnPicker.grid_dims()
	var bases: Array = GridPathfinder.spread_cells(
			SpawnPicker.spawn_candidates().duplicate(), 2, SPAWN_CLEARANCE, d.x, d.y)
	var by_team := {1: [], 2: []}
	for role in teams:
		var t := int(teams[role])
		if by_team.has(t):
			by_team[t].append(int(role))
	var out := {}
	for t in [1, 2]:
		(by_team[t] as Array).sort()   # 确定性:同队的 role 按号升序拿点
		var base: Vector2i = bases[t - 1] if t - 1 < bases.size() else Vector2i(-1, -1)
		var pts: Array = GridPathfinder.spread_cells(
				SpawnPicker.cells_within(base, SPAWN_BASE_RADIUS), (by_team[t] as Array).size(),
				TEAMMATE_CLEARANCE, d.x, d.y)
		for i in range((by_team[t] as Array).size()):
			out[int((by_team[t] as Array)[i])] = pts[i] if i < pts.size() else base
	return out


# "队间远"裕度 = 队间最小环面距 − 队内最大环面距(> 0 = 满足;越大越散)。
# ★ 只在 `plan_team_spawns` 内部用来挑那一份,**不对外**;跨队/队内按 `teams` 分,不按 role 号。
static func _spawn_margin(spawns: Dictionary, teams: Dictionary) -> int:
	if spawns.size() < 2:
		return 1   # 不足两人 = 没有"队间/队内"可言,视为满足(别让空表把重试跑满)
	var d := SpawnPicker.grid_dims()
	var max_in := 0
	var min_cross := 1 << 30
	var roles: Array = spawns.keys()
	roles.sort()
	for i in range(roles.size()):
		for j in range(i + 1, roles.size()):
			var dist := MazeGenerator.toroidal_dist(spawns[roles[i]], spawns[roles[j]], d.x, d.y)
			if int(teams.get(roles[i], 0)) == int(teams.get(roles[j], 0)):
				max_in = maxi(max_in, dist)
			else:
				min_cross = mini(min_cross, dist)
	return min_cross - max_in


# 换边用的点集:把两个队的点**整体对调**(队 A 第 i 人 ↔ 队 B 第 i 人)。
# ★ 前提:两队人数严格相等(满 6 人开局保证)。不相等 → 返回空表,`_start_next_round` 据此**不换边**
#   (宁可这局不换,也不要把人送到错的一侧)。纯函数,可 `-s` 测。
static func compute_swap_spawns(spawns: Dictionary, teams: Dictionary) -> Dictionary:
	var a: Array = []
	var b: Array = []
	for role in teams:
		if int(teams[role]) == 1:
			a.append(int(role))
		else:
			b.append(int(role))
	a.sort()
	b.sort()
	var out := {}
	if a.is_empty() or a.size() != b.size():
		return out
	for i in range(a.size()):
		out[a[i]] = spawns.get(b[i], Vector2i(-1, -1))
		out[b[i]] = spawns.get(a[i], Vector2i(-1, -1))
	return out


# 本局各 role 的出生点(供 match_sync 下发)。★ 覆写不可省:基类实现走 `_spawn_cell`,
# 而本类的 `_spawn_cell` 第二次起返回**动态复活点**且带 `_spawned_once` 副作用
# (与 RoyaleHost.role_spawns 同一个坑)。
func role_spawns() -> Dictionary:
	return _round_spawns.duplicate()


# 队伍表的只读取法(给 `match_sync` 下发用)。★ 客户端**不能**自己从 roles 推导。
func team_map() -> Dictionary:
	var out := {}
	for role in _team_of:
		out[int(role)] = int(_team_of[role])
	return out


func _spawn_cell(role: int) -> Vector2i:
	if not _spawned_once.has(role):
		_spawned_once[role] = true
		return _round_spawns.get(int(role), Vector2i(-1, -1))
	return _respawn_cell_for(int(role))


# 复活点:优选开阔格中,离**所有存活敌人** ≥ RESPAWN_CLEARANCE 的第一个(池子洗牌后取首个)。
# ★ 判据是"离敌人远",**不是**"离所有玩家远" —— 队友在附近复活是好事(royale 那条是全员互敌,
#   故它判所有存活玩家;这里语义变了,别照抄)。
# ★ 池子来源:`SpawnPicker.respawn_pools()`(优选 → 兜底)。原先这里是写死的
#   `[spawn_candidates(), floor_cells()]` —— 第二档是**全部地板格**,干净池子筛空时会把人放进
#   **孤立单格区**的复活点里(与"开局被关住"同一个病)。池序列现在只有一处来源,且与
#   royale 那一侧是**同一份**(两处各抄一遍正是这个病的成因)。
# ★ `SpawnPicker` 的四张缓存是**每进程**的 `static var`,**从不主动清**。
#   本模式 worker 一局一进程、且用固定图(`MatchBootstrap.PVP_MAP`)→ 不需要 `reset_cache()`。
#   **若将来同一个进程里换图**(例如大厅进程也建宿主),必须显式 `SpawnPicker.reset_cache()`,
#   否则会**静默**沿用旧图的地板格池子(不报错,只是出生点全落在上一张图的格上)。
func _respawn_cell_for(role: int) -> Vector2i:
	for pool: Array in SpawnPicker.respawn_pools():
		var cells := pool.duplicate()
		cells.shuffle()
		for c in cells:
			var ok := true
			for other in players:
				if int(other) == role or same_team(role, int(other)):
					continue   # 队友不用躲(语义与 royale 那条"离所有存活玩家远"不同,见上面注释)
				var op: Node2D = players[other]
				if op == null or not is_instance_valid(op) or op.is_downed():
					continue
				var oc := Vector2i(int(op.global_position.x) / GameParameters.TILE_SIZE,
						int(op.global_position.y) / GameParameters.TILE_SIZE)
				if MazeGenerator.toroidal_dist(c, oc, SpawnPicker.grid_dims().x,
						SpawnPicker.grid_dims().y) < RESPAWN_CLEARANCE:
					ok = false
					break
			if ok:
				return c
	return Vector2i(-1, -1)


# 复活时清空归因 meta:复活后的环境死亡(溺水等)不再记到复活前最后射手头上。
# ★★ 照 `RoyaleHost._respawn_player` 那 6 行**逐字同构**,不是"顺手加上去的" —— 选**补齐对等**
#   而不是写一句"3v3 不需要":
#   · 归因窗口是 `ATTRIB_WINDOW`(3s),而 meta 在**受击瞬间**写下、**跨倒地**保留 ——
#     "复活后 3s 内的环境死亡(溺水/坠落)算给复活前那名射手"这条路径在 3v3 与 royale 里
#     是**同一个形状**,没有哪条 3v3 特有的规则把它排除掉;
#   · 计分口径是"不分死因"(规则 7),恰恰**更**看得见这条 —— 一次错归因在 3v3 直接变成
#     "对方队 +1 且击杀者被复位",比 royale 的排行榜好看一点要严重;
#   · 今天大概率不可达(需要复活后 3s 内死于环境),但"不可达"是**当前数值**的属性,
#     `ATTRIB_WINDOW`/`RESPAWN_DELAY`/`drown_delay` 任何一个被调都会让它可达 ——
#     而对等性欠债一旦留下,调参的人不会知道这里少了一行。守卫:探针 ⑫b(复活后 meta 必须不在)。
func _respawn_player(role: int) -> void:
	super._respawn_player(role)
	var p: Node2D = players.get(role)
	if p != null and is_instance_valid(p):
		p.remove_meta("last_damager")
		p.remove_meta("last_damager_time")


# 某 role 的**对方队号**(计分归属用)。无队伍 → 0。
func _enemy_team_of(role: int) -> int:
	var t := team_of(role)
	if t == 0:
		return 0
	return 2 if t == 1 else 1


# ── 回合机(团队版:计分键 = **队号**,不是 role)──
# ★ 为什么整段覆写而不是改基类:`MatchRound._match_round_tick` 的计分键、胜负判据、复位对象
#   三方都绑在 role 上,逐处插分支会让 1v1 那条路长出团队语义(1v1 的探针照样绿,但已经变了)。
func _match_round_tick(delta: float) -> void:
	for role in players:
		var p: Node2D = players[role]
		if not p.is_downed():
			continue
		# 复活调度独立于计分闩锁(与基类同款:旧实现把它塞在闩锁内,曾导致复活永不安排)
		if _round_state == RoundState.PLAYING and not _respawn_pending.has(role):
			_respawn_pending[role] = RESPAWN_DELAY
		if _down_counted.get(role, false):
			continue
		_down_counted[role] = true
		# 掉落:倒地**这一刻**在原地丢下除随机保留一把外的全部武器(与基类/大乱斗同款 ——
		# 见 `MatchGround._drop_all_but_one` 上方的完整理由)。共用 `_down_counted` 闩 ⇒
		# 每次死亡恰好一次;`_respawn_player` 那一支**不再**掉(会掉在出生点)。
		# ★ 本行与另外两处边沿是**同一个契约的三份落地**:少写这一处,3v3 会静默退化成
		#   "死亡不掉武器"(基类那支已删,没有别的地方会替它掉)。
		_drop_all_but_one(p, int(role))
		# 逐人数据(B 册 Task 10):倒下**一律**计 death;击杀只在"归因到且异队"时计给杀手。
		# ★ 刻意放在下面 `scorer != 0` 那道闸**之外**:"这场倒地有没有给对方队加分"与"谁死了"
		#   是两件事 —— deaths 的口径是"谁死了都算死"(用户裁定 ②)。
		_record_down(int(role), _attributed_killer(p))
		# 击杀定义(继承 1v1 的"不分死因"):任一玩家倒地 → **对方队** +1。
		# 队友误炸也照此(用户裁定):乱扔雷 = 给对面送分,惩罚是自带的,不必另立规则。
		var scorer := _enemy_team_of(int(role))
		if scorer != 0:
			_scores[scorer] = int(_scores.get(scorer, 0)) + 1
			# kill_event 的载荷仍是 **role 粒度**(射手 = 归因得到,0 = 无归因),
			# 客户端用 match_sync 的队伍表映射到队 —— 协议不为团队改字段(设计 §6)。
			# ★ 归因不到(killer = 0)时**照样广播**:计分归属与"有没有击杀者"是两件事,
			#   给 0 加守卫会让"队友误炸/溺水导致的倒地"在客户端完全无声。
			_broadcast_kill(_attributed_killer(p), int(role))
			_broadcast_round_state()
			# ★★ 2026-09-21 用户要求**删除**「击杀者复位」这一步(原为 `_reset_killer_only(p, int(role))`,
			#   该函数已随本次改动整体删除)。现在的行为:击杀者**原地不动**,受害者 2s 后回本方出生点复活。
			#   ★ 代价照实记录,**不粉饰**:被删掉的那条规则是**为反「反复活点蹲守」而立**的 ——
			#     有它时击杀者会被立刻送回本方出生点,于是没法杵在对手的复活点旁边等着再打一次。
			#     删除之后 3v3 **不再有**这条性质:击杀者可以守在对手出生点,等对面 2s 后落下来再补一轮。
			#     用户知情并接受(这是"击杀后还被传送"这一体验的对价)。**将来若想找回这条性质,
			#     别在原地重建它** —— 正确的形状是"复活点选点避开存活敌人"(`_respawn_cell_for` 那条
			#     `RESPAWN_CLEARANCE` 已经在做一半),而不是再把击杀者瞬移走。
			#   ★ 只动 3v3:1v1 的 `MatchRound._reset_survivor`(`match_round.gd`)与大乱斗**都原样保留** ——
			#     本函数是整体覆写、不走 `super`,两条路径本来就不相干。
	match _round_state:
		RoundState.COUNTDOWN:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_round_state = RoundState.PLAYING
				if _round_full_heal:
					for heal_role in players:
						(players[heal_role] as Node).apply_authoritative_state(
								(players[heal_role] as Node).max_hp,
								(players[heal_role] as Node).max_waterproof, false)
				_broadcast_round_state()
		RoundState.PLAYING:
			_handle_respawns(delta)
			for t in [1, 2]:
				if int(_scores.get(t, 0)) >= TEAM_KILLS_TO_WIN:
					_round_over(t)
					break
		RoundState.ROUND_OVER:
			_round_timer -= delta
			if _round_timer <= 0.0:
				_start_next_round()
		RoundState.MATCH_OVER:
			pass


func _round_over(winner_team: int) -> void:
	_last_round_winner = winner_team
	_rounds_won[winner_team] = int(_rounds_won.get(winner_team, 0)) + 1
	_round_state = RoundState.ROUND_OVER
	_round_timer = ROUND_OVER_TIME
	_broadcast_round_state()


# 换局:局胜到 TEAM_ROUNDS_TO_WIN → MATCH_OVER;否则**整队换边** + 下一局。
# ★ 与基类的三处实质差异:
#   ① 局胜的键是**队号**(基类按 role 查,团队下永远是 0 → 永远打不完);
#   ② 换边 = `_round_spawns` 与 `_swap_spawns` **整体互换**(基类只翻一个 `_side_swap` 布尔);
#   ③ 换边后要**清 `_spawned_once`** —— 否则 `_spawn_cell` 走"动态复活点"分支,
#      开局六个人会被撒到"离敌人远"的随机格,而不是本方出生点。
#
# ★★ 本覆写存在的**首要理由**是消灭一个过渡态(Task 5/6 期间登记在案):
#   在此之前 `_match_round_tick` 的 ROUND_OVER 分支虚分派到的是**基类** `MatchRound._start_next_round`,
#   而 `_rounds_won` 的键早已是**队号** —— 队号 {1,2} 与 role 1/2 **字面撞号**,
#   "1 队赢 2 局"被基类读成"role 1 赢 2 局":结果碰巧对,但不是语义对齐(且基类**不换边**)。
#   守卫:`tests/team_host_probe` ⑨(源码级:本函数确实声明在这里;行为级:把状态机推过
#   ROUND_OVER 后出生点已对调、`_side_swap` 一路未被翻 —— 基类那条两样都做不到)。
#
# ★ 与 `_match_winner()` 的关系(**不是重复,是互补**):本函数判的是"**要不要**进 MATCH_OVER"
#   (答案只能是"进/不进"),`_match_winner()` 判的是"进去之后**报哪一队**"。两处**都经
#   `_threshold_team()`** 读 `TEAM_ROUNDS_TO_WIN`(常量收口后本文件没有直接读者了),
#   但**不能互换** —— `_match_winner()` 返回 1/2/0(0 = 平局,见它的首行
#   弃权分支;正常路径退回"局胜高者"时恒为 1 或 2)。它的返回值**是队号**,拿它跟阈值比
#   就是本仓反复踩过的"把队号当阈值"。
func _start_next_round() -> void:
	if _threshold_team() != 0:
		_round_state = RoundState.MATCH_OVER
		_broadcast_round_state()
		return
	_reset_world_and_clear_dynamics()
	# ★ 两队人数不等时 `_swap_spawns` 是空表 → **不换边**(宁可这局不换,也不要把人送到错的一侧)
	if not _swap_spawns.is_empty():
		var tmp := _round_spawns
		_round_spawns = _swap_spawns
		_swap_spawns = tmp
	# ★ 这一行不能省:不清的话下面 `_respawn_player` → `_spawn_cell` 走"动态复活点"分支,
	#   六个人被撒到地图各处,而**不是**本方(换边后的)出生点。探针 ⑧/⑨ 的位置断言专抓它。
	_spawned_once.clear()
	_round_num += 1
	_scores = {}
	# 多杀加成按**局**算:每局清零该局的 per-role 击杀计数。
	# ★ 整场累计的 `_stats` **不**清零 —— ACS 是整场口径,与 `_scores`(每局清零的**队伍比分**)
	#   是两份不同的东西:一场三局两胜里 `_scores` 会归零两次,而逐人数据跨局累加。
	_round_kills = {}
	_respawn_pending = {}
	_down_counted = {}
	for role in players:
		_respawn_player(role)
	_round_state = RoundState.COUNTDOWN
	_round_timer = COUNTDOWN_TIME
	_broadcast_round_state()


# 对局胜者(**队号**):① 走光(弃权)收场的看 `_endgame_winner`(见首行);
# ② 正常收局 = 先到 `TEAM_ROUNDS_TO_WIN` 局胜的那一队;③ 都还没到则退回"局胜高者"。
# ★ ③ 只在 `TEAM_ROUNDS_TO_WIN` 被调大(今天 = 2,而一局都没打完就收场的路只有走光,
#   已被 ① 接走)或将来出现"没打满就收场"的新路径时才会被走到。
# ★ 本函数**经 `_threshold_team()`** 读 `TEAM_ROUNDS_TO_WIN`(常量收口后唯一直接读者是它,
#   本函数与 Task 7 的 `_start_next_round` 都只是它的调用方)。没有这个阈值分支时,改常量
#   **一点行为都不变** —— 那正是本仓要防的"静默无效";同理,常量一旦失效,这条分支连同
#   `_start_next_round` / `_decided_by_rounds` 一起**静默**失效(三处共用同一个谓词)。
# ★★ 下面那两个 `2` **不是**阈值,是**队号**,别把它们换成 `TEAM_ROUNDS_TO_WIN`:
#   今天两者都等于 2,换错了不报错,而 Task 7 一旦把档位改成 3,返回给客户端的就会是
#   "3 队"这种不存在的队号(且照旧不报错)。
func _match_winner() -> int:
	# ★ 走光(弃权)终局**优先于**下面那条按局胜比较的兜底:它只在 `mark_disconnected` 里被写,
	#   正常收局路径恒为 ENDGAME_NONE ⇒ 下面那段"按局胜比、并列偏 1 队"的语义一字未动。
	#   为什么必须优先:走光这条**必然**走兜底(谁也没赢满 `TEAM_ROUNDS_TO_WIN` 局),而兜底在
	#   0:0 / 1:1 并列时偏 **1 队** ⇒ 不拦的话"整队走光的那一队"会被报成胜者。
	if _endgame_winner != ENDGAME_NONE:
		return _endgame_winner
	var decided := _threshold_team()
	if decided != 0:
		return decided
	return 1 if int(_rounds_won.get(1, 0)) >= int(_rounds_won.get(2, 0)) else 2


# 「局胜阈值」这个谓词的**单一来源**:先到 `TEAM_ROUNDS_TO_WIN` 局的那一队;都还没到 → 0。
# ★ 它有**三个读者**,问的是同一个谓词的三种问法(此前三处各抄了一份逐字同构的循环):
#   `_start_next_round()` 问"**要不要**进 MATCH_OVER"、`_match_winner()` 问"进去之后**报哪一队**"、
#   `_decided_by_rounds()` 问"是否已由局胜决出"。三处的分支都是"有就拦/就返回",故共用它
#   不会改变任何一处的语义。
# ★ 返回值语义:队号 1/2 = 已达标;0 = **未达标**。★ 这个 0 **不是队号**(本模式没有 0 队),
#   正是那个"未定"哨兵 —— 与本文件 `ENDGAME_NONE` 的 0/队号关系照同一条纪律读:
#   **谁都不可能拿 0 去当队伍用**。三个读者的用法:`!= 0` 当闸 / 当布尔 / 直接返回。
func _threshold_team() -> int:
	for t in [1, 2]:
		if int(_rounds_won.get(t, 0)) >= TEAM_ROUNDS_TO_WIN:
			return t
	return 0


# round_state:`scores` / `rounds_won` 的**键是队号**;`winner` / `match_winner` 也是队号。
# ★ 队伍表**不在这里**下发:只走 `match_sync`(进场/重连各拉一次)。两条投递路径是自检 B2 那类
#   事故的形状,别为了"顺手"加第二条。
func _broadcast_round_state() -> void:
	var data := {
		"state": _round_state,
		"round": _round_num,
		"scores": _scores,
		"rounds_won": _rounds_won,
		"timer": _round_timer,
	}
	if _round_state == RoundState.ROUND_OVER and _last_round_winner != 0:
		data["winner"] = _last_round_winner
	if _round_state == RoundState.MATCH_OVER:
		data["match_winner"] = _match_winner()
		# MVP:整场 ACS 最高者(并列 → 击杀多者 → 阵亡少者 → role 升序,见 mvp_role)。
		# ★ 只在 MATCH_OVER 带 —— 局中还没有"整场"可言(与 `match_winner` 同款时机)。
		data["mvp"] = mvp_role()
	# 逐人数据:与 `destroyed` / `ground_weapons` 同款纪律 —— **只在非空时带该键**
	# (没有逐人数据的对局/旧客户端忽略未知键;空表不占带宽)。
	var table := stats_payload()
	if not table.is_empty():
		data["stats"] = table
	_rpc_all("round_state", [data])


# ── 击杀归因(自带一份,不从基类上提)──
# `kill_event` 要带"是谁杀的"(归因不到就带 0),故在这里落。
# ★ 2026-09-21:原先还有一个读端 —— 「击杀后复位击杀者」那条规则(已按用户要求删除)。
#   现在它只服务"击杀归属"这一族(`kill_event` 的射手字段 + `_record_down` 的逐人 `kills`)。
# ★ 为什么自带而不是把 `RoyaleHost._attributed_killer` 上提到基类:基类的归属由
#   `tests/kh_l5_probe.gd` 的"新接口归属(基类不得含子类方法)"反向断言守着,为省 12 行去动
#   那条探针不划算;两份都不足 15 行,读的还是同一个 meta(单一来源仍是 CombatFeedback)。
func _attributed_killer(victim: Node2D) -> int:
	return _attributed_role_within(victim, ATTRIB_WINDOW)


# "上一个打 victim 的人"的 role,且归因年龄 ≤ `window_ms`(超窗/无归因/自伤 → 0)。
# ★ 读端只有两处,问的是**两个不同的问题**,故窗口是参数而不是常量:
#   · 击杀归属(`_attributed_killer`,3s)= "这次死亡算谁的击杀"(A 册口径);
#   · 逐人伤害(`_fresh_attacker_role`,8ms)= "**这一下**伤害是谁打的"(见 `ATTRIB_FRESH_MS`)。
#   两个问题共用"读 meta + 把节点映射回 role"这一段(单一来源),只差那个窗口。
# ★ `shooter == victim` 的守卫不可省:写端(`CombatFeedback.attribute`)自伤时**静默跳过**,
#   但万一有人绕过写端直接 set_meta,这里不能再把自伤算成"自己杀自己"。
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


# ── 中途掉线(宽限期到点后由 server_main 调)—— 移出对局,但**整队走光才终局** ──
# ★ 判据是"某个队一个人都不剩",**不是** royale 那条"players.size() < 2":
#   6 人局里掉 1 个就终局 = 剩下的人白打(用户裁定:该队少人继续打)。
# ★ 也不能数 `peer_by_role`(那是"有网络连接的人"):3v3 没有 AI 补位,两者当前同键集,
#   但判据写成"每队还剩几个**在场上**的人"才表达得出这条规则的本意。
func mark_disconnected(role: int) -> void:
	role = int(role)
	if _left.has(role):
		return
	_left[role] = true
	# ACS 的"局数"口径:离开者**冻结在他离开时所处的局号**(= 他实际参与的局数,见 `_rounds_for`)
	_left_round[role] = _round_num
	_respawn_pending.erase(role)
	_down_counted[role] = true
	if players.has(role):
		var p: Node = players[role]
		if is_instance_valid(p):
			p.queue_free()
		players.erase(role)
	if input_sources.has(role):
		input_sources.erase(role)
	peer_by_role.erase(role)
	# 还有人的队:统计(队伍表里没出现的队号不算)
	var alive_teams := {}
	for r in players:
		var t := team_of(int(r))
		if t != 0:
			alive_teams[t] = true
	if alive_teams.size() < 2 and not _decided_by_rounds():
		# 走光即弃权:存活的那支队胜;一队不剩(两队都走光)= 平局 0(见 `_match_winner` 首行)。
		# ★★ 本判据**在走光收场之后仍然继续生效**(先走光那队把结果判给对手之后,对手也可能
		#    接着走光)—— 那一刻场上一个队都不剩,没有胜者可报,结果该收缩成平局。
		#    `_expire_graces` 是**一次循环里逐个调**本函数的,少了这条,"六个人在同一批宽限期
		#    里走光"的胜者就取决于**谁先被遍历到**(掉线到达顺序),即无意义的抖动。
		# ★ 收缩是**单调**的:存活队只会 2 → 1 → 0,不会把已判出的胜者改成另一队。
		# ★★ `_decided_by_rounds()` 那道闸**不能省**:三局两胜打完的局,胜者已定 ——
		#    冠军队赛后离场会把"存活队"改判成对方(赢家走人 = 改判负)。探针 ⑥b 专钉它。
		var survivors: Array = alive_teams.keys()
		_endgame_winner = int(survivors[0]) if survivors.size() == 1 else 0
		if _round_state != RoundState.MATCH_OVER:
			_finish_match()
			return      # `_finish_match` 内部自会广播(载荷里的 match_winner 已读新值)
	# 常规:把"场上少了人"这件事推给还在场的人(含上面那条"胜者收缩/改判"的新结果)
	_broadcast_round_state()


# 对局是否已由**局胜**(三局两胜)决出 —— 与走光(弃权)并列的另一条收局路径。
# ★ `mark_disconnected` 唯一需要知道它的地方:弃权判据**不得改判一场已经打完的局**。
#   判据与 `_start_next_round` / `_match_winner` 同源(`_rounds_won` 对 `TEAM_ROUNDS_TO_WIN`)。
# ★ 刻意不用"在 `_start_next_round` 里记一个闩"的写法:那样 ROUND_OVER 期间(局胜已达标、
#   状态尚未推进到 MATCH_OVER 的那几帧)会漏判 —— 而掉线恰好可能落在这个窗口里。
func _decided_by_rounds() -> bool:
	return _threshold_team() != 0


func _finish_match() -> void:
	_round_state = RoundState.MATCH_OVER
	_broadcast_round_state()
	print("TeamHost: 对局结束(整队走光),胜者队 %d" % _match_winner())


# ── 自杀脱困(K 键:客户端 → NetBusExt.suicide_request → server_main._on_suicide_request)──
# 异常卡死(嵌墙/夹缝)时主动放弃生命:走正常倒地边沿 → 2s 复活;先清 `last_damager` 归因,
# 自杀不计入任何人击杀。
# ★ 与 `RoyaleHost.request_suicide_role` **逐字同构**(那边 12 行,规则 7"不分死因"对两个模式
#   同样成立)。在 3v3 下它落进**无归因**档:倒地 → **对方队 +1**、且无人被计入击杀
#   (`_record_down` / `kill_event` 都读 `_attributed_killer` = 0)。
#   ★ spec §10 第 ⑩ 行原本还写了一句"无归因 → **无人被复位**" —— 那条规则(以及那个三分档)
#     已随「击杀者复位」整体删除(2026-09-21,见 `_match_round_tick`),现在**任何**归因下都无人被复位。
# ★★ 本函数**必须留在子类**:`tests/kh_l5_probe.gd` 的"新接口归属"反向断言把
#    `request_suicide_role` 列进**禁入基类**名单(搬进基类 = 未定义符号)。
# ★ 为什么值得为它单独接一条闸:三局两胜里卡死的玩家比大乱斗难受得多(不能退、只能等对局
#   被别人打完),而 royale 那份现成 —— `server_main._on_suicide_request` 原先只认 `_royale`,
#   3v3 worker 上 `suicide_request` 被**静默丢掉**(K 键毫无反应,且不报错)。
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


# ══════════════════════════════════════════════════════════════════════════════════════════
# 逐人数据 + ACS / MVP(B 册 Task 10)
#
# ★ **只做数据面**:服务端算好、随 `round_state` 下发。结算面板(版式/排序/庆祝)不做。
# 用户裁定三条:
#   ① MVP 口径 = Valorant 式**整场 ACS** = (伤害 1:1 + 击杀分) / 局数,而**死亡不扣分**;
#   ② 逐人 `kills` **只算异队击杀**(队友误炸/无归因的自杀/溺水不计入任何人的 kills),
#      但 `deaths` **一律** +1(谁死了都算死);
#   ③ 只做数据面。
# 三条规则各自落在:① `kill_bonus_score` / `_acs_of` / `mvp_role`;② `_record_down`;
#   ③ 本段不碰任何 UI,只多 `round_state` 的两个键(`stats` / `mvp`)。
# ══════════════════════════════════════════════════════════════════════════════════════════


# role 的逐人条目(惰性建:谁上过场谁才有条目;`stats_payload` 会把在场者补齐)。
func _stat_entry(role: int) -> Dictionary:
	role = int(role)
	if not _stats.has(role):
		_stats[role] = {"kills": 0, "deaths": 0, "dmg": 0, "kscore": 0}
	return _stats[role]


# 击杀分公式(静态:探针可直接钉那张表,不必起宿主)。
# ★ 输入 = **倒下瞬间的敌方存活人数(含被击杀者本人)**,理由见 `KILL_BONUS_BASE` 上方那段。
static func kill_bonus_score(enemy_alive: int) -> int:
	var n := clampi(enemy_alive, KILL_BONUS_MIN_ALIVE, KILL_BONUS_MAX_ALIVE)
	return KILL_BONUS_BASE + KILL_BONUS_PER_ALIVE * n


# "**这一下**伤害是谁打的" —— 归因必须**新鲜**(`ATTRIB_FRESH_MS`)。无 → 0。
# ★ 与 `_attributed_killer` 是两个问题、两个窗口(见 `_attributed_role_within`)。
func _fresh_attacker_role(victim_role: int) -> int:
	var victim: Node2D = players.get(int(victim_role))
	if victim == null or not is_instance_valid(victim):
		return 0
	return _attributed_role_within(victim, ATTRIB_FRESH_MS)


# 受击回调覆写(虚分派:接线在 `MatchHost._wire_hit_feedback`,实际调到的是这一份)。
# ★ 一个钩子覆盖**全部**伤害来源 —— 子弹 / 榴弹直击 / 爆炸 AoE / 激光:它们的共同点是
#   "归因写入 `CombatFeedback.attribute` 都在 `take_hit` 之前"(本仓明文纪律),于是
#   `took_hit` 这一刻读 meta 就拿到攻击者。**不必去改 `Explosion`**(它是纯静态、不引 autoload)。
# ★ 但**子弹那一路要先把归因补上**,见 `_on_bullet_hit` —— 基础实现对玩家直击不写归因。
func _on_player_hit(source_pos: Vector2, damage: int, role: int) -> void:
	# 记给**攻击者**。三档都不记,各管一件事:
	#   · 自伤:写端 `attribute` 因 attacker == victim **静默跳过**、meta 停在上一名敌人身上
	#     ⇒ 由**新鲜度**判据挡掉(见 `ATTRIB_FRESH_MS`);
	#   · 队友伤害:**按队过滤**(用户裁定 2026-09-19,与"只算异队击杀"同口径)—— 子弹本来就
	#     穿队友,唯一能打到队友的是**爆炸**,不过滤就等于"朝队友扔雷即可刷 ACS",而且"爆心
	#     队友"会反过来抬高扔雷者;
	#   · 找不到攻击者(归因不到)→ 谁都不记。
	var attacker := _fresh_attacker_role(int(role))
	if attacker != 0 and not same_team(attacker, int(role)):
		var s := _stat_entry(attacker)
		s["dmg"] = int(s["dmg"]) + int(damage)
	super._on_player_hit(source_pos, damage, role)


# 子弹直击的归因写入。★ **不可省**(与 `RoyaleHost._on_bullet_hit` 逐字同构):服务器上子弹
# 撞玩家不靠物理(子弹掩码 5 = 地形+敌人,不含玩家层),只经 `_adjudicate_bullets` 到这里,
# 而基础实现里**没有** `CombatFeedback.attribute`。
# 不写这一步的后果(都是静默):
#   ① 逐人 `dmg` 漏掉**最主要的伤害来源** ⇒ ACS 直接失真;
#   ② `_attributed_killer` 对枪杀恒 0 ⇒ `kill_event` 的射手恒 0(逐人 `kills` 也全漏),
#      即"枪杀在客户端播报里没有击杀者"。
# ★ 历史上这里还列过第 ③ 条:「击杀者复位在枪杀这条路上一直没生效」—— 那条规则已按用户要求
#   删除(2026-09-21),故不再是本行的理由;①② 两条与它无关,照旧成立。
func _on_bullet_hit(bullet: CharacterBody2D, victim: Node2D, victim_role: int) -> void:
	CombatFeedback.attribute(victim, bullet.shooter)
	super._on_bullet_hit(bullet, victim, victim_role)


# 逐人数据的唯一写入口(每次倒地边沿调一次,见 `_match_round_tick`)。
# ★ `deaths` **一律** +1:队友误炸 / 自杀 / 溺水全算死(用户裁定 ②)。
# ★ `kills` / `kscore` **只在"归因到且异队"**时记给杀手 —— 无归因与同队误炸不计**任何人**的
#   击杀;而那一分照样给对方队(A 册的 `_scores`)"对方队涨分"与"谁拿到击杀"是两件事。
func _record_down(victim_role: int, killer_role: int) -> void:
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0 or same_team(killer_role, victim_role):
		return
	# Beta 时间玩法:击杀得"被击杀者余额 × 比例"(被击杀者不减;同队/无归因已被上面挡掉)
	if time_economy != null:
		time_economy.award_kill(killer_role, victim_role)
	var k := _stat_entry(killer_role)
	# 多杀:同一局内该 role 的第 2、3… 个击杀各 +50(第 1 个 +0)。计数器每局清零。
	_round_kills[killer_role] = int(_round_kills.get(killer_role, 0)) + 1
	var bonus := kill_bonus_score(_enemy_alive_including_victim(victim_role)) \
			+ MULTI_KILL_BONUS * (int(_round_kills[killer_role]) - 1)
	k["kills"] = int(k["kills"]) + 1
	k["kscore"] = int(k["kscore"]) + bonus


# "倒下瞬间的敌方存活人数" —— 击杀加成的唯一输入。**含被击杀者本人**(见 `KILL_BONUS_BASE`)。
# ★ 判据是**队伍**(受害者的队 = 杀手的敌方队),不是"除受害者以外的人"。
# ★ 读 `is_downed()` 这个**真实状态**,不是 `_down_counted` 那个计分闩:同一帧里先后倒下的两人,
#   先处理谁都不影响结果(倒地那一刻 `is_downed()` 就已经是真了)⇒ 结果**确定性**。
func _enemy_alive_including_victim(victim_role: int) -> int:
	var t := team_of(victim_role)
	var n := 0
	for role in players:
		if int(role) == victim_role:
			n += 1     # ★ 本人算"存活"(这张表的定义;数"倒下之后剩几个"会得到 0,而 0 无档)
			continue
		if team_of(int(role)) != t:
			continue
		if (players[role] as Node2D).is_downed():
			continue
		n += 1
	return n


# ACS 的"局数"口径:**全场已进行的局数**(`_round_num`);中途离开者**冻结在他离开时所处的局号**
# = 他实际参与的局数(`mark_disconnected` 写 `_left_round`)。
# ★ 为什么按"实际参与"而不是一律用全场局数:离开者没打的那几局不该稀释他(brief 明写的选择)。
#   代价:分母比在场者小 ⇒ 同一份总分算出的 ACS 偏高。这是**有意**的口径,不是 bug。
# ★ 卡在 MATCH_OVER 时 `_round_num` 恰好等于"打过的局数"(`_start_next_round` 在终局分支**提前
#   return**,不推进局号)⇒ 终局那一份 ACS 的分母正是整场局数。
func _rounds_for(role: int) -> int:
	return int(_left_round.get(int(role), _round_num))


# ACS = (击杀分 + 伤害) / 局数。★ **死亡不扣分**(用户裁定 ①:Riot 的 ACS 不含死亡惩罚)。
func _acs_of(role: int) -> float:
	var s: Dictionary = _stats.get(int(role), {})
	var total := int(s.get("kscore", 0)) + int(s.get("dmg", 0))
	return float(total) / float(maxi(_rounds_for(int(role)), 1))


# 逐人表的 role 集合:在场者 ∪ 已离开者 ∪ 有数据的。
# ★ 在场者**哪怕一次伤害都没打过**也要出现(面板要的是"所有参战者各一行"),故不能只遍历 `_stats`。
func _roster() -> Dictionary:
	var roles := {}
	for role in players:
		roles[int(role)] = true
	for role in _left:
		roles[int(role)] = true
	for role in _stats:
		roles[int(role)] = true
	return roles


# 逐人数据载荷:`{role: {kills, deaths, dmg, kscore, acs}}`(给 `round_state` 的 `stats` 键)。
func stats_payload() -> Dictionary:
	var out := {}
	for r in _roster():
		var role := int(r)
		var s: Dictionary = _stats.get(role, {})
		out[role] = {
			"kills": int(s.get("kills", 0)),
			"deaths": int(s.get("deaths", 0)),
			"dmg": int(s.get("dmg", 0)),
			"kscore": int(s.get("kscore", 0)),
			"acs": _acs_of(role),
		}
	return out


# MVP = **整场 ACS 最高者**(用户裁定 ①);并列 → 击杀多者 → 阵亡少者 → **role 号升序**。
# ★ 确定性:候选按 role **升序**遍历 + 只在**严格更优**时替换 ⇒ 完全并列时天然的胜者是**最小
#   role**。不依赖字典迭代顺序 —— 同一份状态调多少次都是同一个答案(探针 ⑬f 钉它)。
# ★ 候选 = `_roster()`(与 `stats_payload` 同一个集合):MVP 是"这份逐人表里的第一名",
#   不是另立一份名单。
# ★★ **已离开者照样参与评选 —— 这是用户裁定(2026-09-19),不是遗漏**:取向与大乱斗
#   `_match_winner` 的"已离开但计过分的也算"一致。他还会因为"ACS 分母 = 实际参与局数"
#   (更小)而更容易胜出 —— 那**也是**有意的口径。
#   ⇒ **别**因为"退了的人不该拿 MVP"把 `_left` 从候选里滤掉(那会静默改掉一条产品规则);
#     守卫是探针 ⑬j:构造"计过分后离场、终局 MVP 指向他"那一档。
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
