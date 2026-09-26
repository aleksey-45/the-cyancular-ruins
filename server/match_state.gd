class_name MatchState
extends Node

# 对局权威的**共享状态底座**(阶段 5.6 拆 server/match_host.gd 时抽出)。
#
# ★ 为什么是"底座"而不是某个域:这条链上每一层都要读同一批状态(`players`/`grid`/
#   `peer_by_role`/回合计分…),而 GDScript 的父类方法**在编译期解析不了子类声明的符号**
#   —— 所以这些字段只能住在共同祖先里。把它们集中在这一处,也比散进四个域文件后
#   "谁都能改、谁都不知道谁改"要好查。
#
# 链:RoyaleHost → MatchHost(核心:生命周期/输入/物理编排) → MatchRound(回合状态机)
#      → MatchCombat(子弹与爆炸裁决) → MatchSnapshot(快照广播) → MatchState(本文件) → Node
#
# ★ 中间层**不得**定义 _init/_ready/_enter_tree/_exit_tree/_physics_process:
#   RoyaleHost 的 _init 契约是"先 plan_spawns 再 super._init"(顺序不可整理),
#   插入新的生命周期钩子会把它打断。
# 服务器权威对局模拟(每房间一个):建世界(只碰撞不渲染)+ 两个 Player(PacketInputSource 注入)。
# 每物理帧消费双方输入包注入,玩家 _physics_process 自动跑(Player 是 CharacterBody2D,父先于子)。
# 协议只传 canonical 坐标;渲染归各端副本(客户端侧),服务器只存真值。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> PacketInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> Array[输入包队列],按序消费不丢 just_pressed 边沿
var grid: Array = []
var _base_grid: Array = []   # 建局原始(未破坏)网格深拷贝:每局复位重铺,防客户端/服务器砖状态漂移

# 队伍表:role(int) -> 队号(1/2)。**唯一权威** —— 由大厅在 worker 命令行 `--teams` 显式传入。
# ★ 为什么不从 role 号推导:role 由大厅的「最小空闲号」分配、有人退出后不重排,编号会留空洞
#   ({1,3,5} 而只有 3 人),奇偶/区间推导必然出错。
# ★ 空表 = 无队伍(1v1 / 大乱斗 / 单机):`team_of` 恒 0、`same_team` 恒 false,行为与今天一致。
var _team_of: Dictionary = {}


# 某 role 的队号;无队伍/不在表里 → 0(调用方按 0 处理为"不豁免、不分组",别让它变成 1)。
func team_of(role: int) -> int:
	return int(_team_of.get(int(role), 0))


# 两个 role 是否同队 —— **单一来源**:子弹穿透队友、出生/复活分组、复位归属都问它。
# ★ 任一方为 0(无队伍)一律 false:0 == 0 若算同队,1v1 里两个玩家会被判成队友、子弹全穿。
func same_team(a_role: int, b_role: int) -> bool:
	var a := team_of(a_role)
	var b := team_of(b_role)
	return a > 0 and a == b


# 与建局基线(`_base_grid`)**不同**的格。给"重连后补破坏态"与"回大厅后回局"用:
# 客户端重进/重连时只拿 `match_path` 重建初始地图,而服务器上是破坏后的 `grid`
# → 不补这一份,客户端会留着服务器已摧毁的墙(**幻影墙** → 玩家撞上去 → 本地预测与服务端
# 分歧 → 可能回滚循环),或是凭空少墙。
# ★ 判据是"与基线不同",**不是**"当前为空":后者在将来出现"加砖"类改动时会静默漏报。
# ★ 顺序确定性(y 升序、同 y 升序 x):载荷要能在两端逐字比对。
# ★ 规模上限 **841**(≈8~10 KB):本类只服务 PvP 局,定图 `factory1v1.cyrm` 是 150×100 = 15000 格,
#   但 `TileDefs.damage_tile` 只认**可破坏纹理**(15~20 且形状掩码非 0),其余一律当场拒收 ——
#   实测 `factory1v1.cyrm` 里这样的格**恰好 841 个**,这就是本数组能有的最大长度。
#   (旧注释写的是"全拆光 15k 条",松了约 18 倍 —— 那是把**地图格数**当成了上限。)
# ★ 投递时机只有一处:**`match_sync` 应答**(进场一次 + 每次重连一次),不是每帧、也不是每局。
#   空数组连键都不带(见 `server_main._on_match_sync`),所以常态下一分钱不花。
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
const SNAPSHOT_INTERVAL := 1.0 / 60.0   # 60Hz 快照(unreliable;服务器 60Hz 模拟,本地玩家靠快照渲染,30Hz 太卡)
# 子弹/爆炸弹对玩家的命中判定半径(px, 玩家缩放 2.5 的碰撞箱量级)。
# ★ 单一来源在 BulletBase.PLAYER_HIT_RADIUS:客户端那份视觉榴弹也按同一半径判
# 「碰到玩家 → 短引信」(bullet_base._check_player_contact),两处各写一个数就会漂。
const HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS
var _seen_bullets: Dictionary = {}  # bullet instance_id -> true(只广播一次);每帧按在场子弹剪枝(见 _adjudicate_bullets)
var _snap_tick := 0   # 快照序号(客户端靠它丢弃乱序的旧快照)
# C2 rollback:每物理 tick 恰好消费一个输入包(FIFO),role -> 刚消费包的 seq(ack)。
# 客户端据 ack 锚定"服务器已确认到哪一输入",重放 seq>ack 的本地输入——1:1 同序,无 tick 映射漂移。
var _ack_seq: Dictionary = {}   # role(int) -> 已消费输入包 seq

# ── 对局选项(房主 role1 下发,经 claim_role 携带;进局时广播生效值)──
var _options: Dictionary = {}
var _round_full_heal := false        # 每回合开始双方回满血
var _disabled_weapons: Array[int] = []   # 禁用的武器槽位(双方一致)
var _ai_roles: Array = []            # AI 补位的 role 列表;这些 role 无网络 peer

# ── 回合制(阶段4):回合状态机 / 记分 / 复活 / 换边 ──
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

# ── 逐人统计(三模式共用;★ 2026-09-25 从 `TeamHost` 上提,见下)──
# ★ 为什么现在才提得上去:计分口径换成了不依赖队伍语义的 `ScoreRules`(见
#   core/sim/score_rules.gd)。旧口径 `kill_bonus_score(敌方存活人数)` 在 1v1(两人)与
#   大乱斗(自由混战)里**没有对应物** —— 公式与"上提"是因果关系,不是两件顺手的事。
# ★ 条目存的是**原始计数**(下面 8 个键);`kscore` / `acs` 一律**读时推导**。存一份算好的
#   kscore 就意味着"加了一项新惩罚却忘了同步"这种**不报错**的静默缺陷。
# ★ 载荷才用 spec §3.1 那七个字段(kills/deaths/assists/dealt/taken/kscore/acs)。
var _stats: Dictionary = {}          # role -> 原始计数(整场累计,不随局清零)
var _left_round: Dictionary = {}     # role -> 离开时所处的局号(ACS 的"实际参与局数"口径)
# 助攻表:**每受害者一张小表** —— `victim_role -> {attacker_role: 最后命中时刻(ms)}`。
# ★ 为什么需要它:归因只有 `CombatFeedback.attribute` 写的单个 `last_damager` meta,只够判
#   "谁拿的击杀",回答不了"还有谁打过他"。
# ★ 写入口唯一(`_note_hit`,由 `MatchCombat._on_player_hit` 调):所有伤害路径
#   (子弹 / 榴弹直击 / 爆炸 AoE / 激光)都汇到那一个钩子 —— 与 `dealt`/`taken` 同源。
# ★ 表的时刻是**墙钟**(`Time.get_ticks_msec`),窗口复用 `ATTRIB_WINDOW`,不新开常量。
var _assist_times: Dictionary = {}
# role -> true(已移出对局)。★ **必须住底座**:`_roster()` / `mvp_role()` 都要读它,
# 而 `RoyaleHost` 与 `TeamHost` 原先**各声明了一份**(上提时那两行必须一起删 —— 子类重复声明
# 基类成员是硬 Parse Error,见 Global Constraints)。
var _left: Dictionary = {}
# 归因时效(3s)。★ 三个读者原先各抄一份(`RoyaleHost`/`TeamHost` 各一个同名常量 + 单机播报);
# 收在底座,子类那两行删掉(同名遮蔽报错)。
const ATTRIB_WINDOW := CombatFeedback.ATTRIB_WINDOW_MS
# "**这一下**伤害是谁打的" —— 归因必须**新鲜**的阈值(ms)。
# ★ 与 `ATTRIB_WINDOW` 是**两个问题、两个窗口**:`ATTRIB_WINDOW`(3s)答"这次死亡算谁的击杀",
#   本阈值答"这一下伤害是谁打的"。★ 不能与击杀口径共用:击杀读的 3s 是"打一枪后 3s 内溺水
#   仍算你的击杀";拿它判"**这一下**伤害是谁打的"太宽(一次 0.4s 引信的榴弹自爆就会被计入)。
# ★ 阈值怎么定:真实命中路径的 `attribute()` → `take_hit()` → `took_hit` 信号是**同一调用栈**,
#   年龄 ≈ 0~1ms;而**上一物理帧**留下的归因至少 ~16.7ms 之前(60Hz)。8ms 落在两者之间:
#   容得下跨一次毫秒边界,又把"上一帧那次命中"挡在外面。
# ★★ 阈值成立的前提是"**归因与伤害同一调用栈**"(真实命中路径 ≈ 0~1ms)。**将来新增
#   「延迟扣血」型伤害必须自己每帧重写归因** —— `LaserWeaponBase` 的**缝 2**(命中结算)明确
#   把"持续/灼烧型"列为**预定扩展位**,而那种实现是"命中时写一次归因、后续帧再扣血":扣血
#   那一刻 meta 的年龄早已 > 8ms ⇒ 被**静默**判成"无攻击者",逐人伤害恒少且不报错
#   (没有断言、没有日志,只是 ACS 偏低)。写端不重写归因的话,这条阈值就是那个扩展位的唯一提示。
#   ★ 本段随常量一起从 `team_host.gd` 搬来(`CLAUDE.md` 的 3v3 小节原先把它的权威落点
#     指在 `team_host.gd` 的 `ATTRIB_FRESH_MS` 上方 —— 那处指针已随本批改到**这里**)。
const ATTRIB_FRESH_MS := 8

# ── 仅测试用:定时拆一格(相⑦ 用)──
# 由 `--test-destroy-tile <col>,<row>[,<delay>]` 写入;到点拆一次,之后置回 (-1,-1) 只拆一次。
# ★ 默认 (-1,-1) = 关:生产路径不带这个开关,行为与今天逐字一致。
# ★ 为什么需要它:重连探针的 worker 是**独立进程**,探针拿不到 `_host`,只能靠命令行开关
#   让 worker 自己在指定时刻制造"世界变了"这件事(既有的 `--test-ground-teleport` 同款手法)。
# ★ 与 `test_ground_teleport` 一样住在**基类**(`MatchGround` 那条是本域的开关):钩子要读它,
#   而钩子由 `MatchHost._physics_process` 每帧调,兄弟域之间互相看不见。
static var test_destroy_cell := Vector2i(-1, -1)
static var test_destroy_after := 0.0     # 秒;从对局开始(_ready)起算


func _rpc_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = true) -> void:
	for role in peer_by_role:
		if role == except_role or not players.has(role):
			continue
		var peer: int = peer_by_role[role]
		# ★ 判活走 `NetBus.is_peer_live`(读 ENet peer 自己的 state),**不是** `get_peers()`:
		#   后者比 ENet 的真实状态晚(见 NetBus 里那段注释),用它挡不住"往已拆掉的 peer 发定向包"
		#   → 就是那句 `Unable to send packet on channel 0, max channels: 0`。
		if live_only and not NetBus.is_peer_live(peer):
			continue
		# callv 展开实参:rpc_id 是变参口,而本函数要按调用方给的 args 转发。
		NetBus.callv("rpc_id", [peer, method] + args)


# 反查角色号。广播要"排除射手"时,调用点手上往往只有 Node(bullet.shooter)而不是 role。
# 找不到返回 -1(与 `_rpc_all` 的 except_role 默认值一致 = 不排除任何人)。

func _role_of(node: Node) -> int:
	for role in players:
		if players[role] == node:
			return int(role)
	return -1


# 两名玩家是否同队。给**武器**用(它们只拿得到节点,拿不到 role)。
# ★ 1v1 / 大乱斗 / 单机:队伍表为空 ⇒ `team_of` 恒 0 ⇒ `same_team` 恒 false ⇒ 本函数恒 false
#   ⇒ 调用方(激光)的行为与今天**逐字不变**。这是本接口的安全性质,别改成"没表就返回 true"。
# ★ `_role_of` 查不到时返回 **-1**(不是 0),而 `same_team(-1, -1)` 同样是 false
#   (`team_of` 对未登记返回 0,判据是 `a > 0 and a == b`)—— 两种"查不到"都安全。
func is_friendly(a: Node, b: Node) -> bool:
	if a == null or b == null:
		return false
	return same_team(_role_of(a), _role_of(b))


# ── 逐人统计的读写口(三模式共用;写入点见 MatchCombat._on_player_hit 与各模式的倒地边沿)──

# role 的原始计数条目(惰性建:谁上过场谁才有条目;`stats_payload` 会把在场者补齐)。
func _stat_entry(role: int) -> Dictionary:
	role = int(role)
	if not _stats.has(role):
		_stats[role] = {"kills": 0, "deaths": 0, "assists": 0, "dealt": 0, "taken": 0,
				"team_damage": 0, "self_damage": 0, "team_kills": 0}
	return _stats[role]


# 逐人总积分。★ **唯一推导点** —— 伤害只在 `ScoreRules.kscore` 里出现一次。
func _kscore_of(role: int) -> int:
	var s: Dictionary = _stats.get(int(role), {})
	return ScoreRules.kscore(int(s.get("kills", 0)), int(s.get("assists", 0)),
			int(s.get("dealt", 0)), int(s.get("deaths", 0)),
			int(s.get("team_damage", 0)), int(s.get("self_damage", 0)),
			int(s.get("team_kills", 0)))


# ACS = kscore ÷ 局数。★ **不得再加伤害** —— 它已经在 kscore 里了(spec §1.4:
# 今天 `(kscore + 伤害)/局数` 之所以成立,仅仅因为今天的 kscore **不含**伤害)。
func _acs_of(role: int) -> float:
	return ScoreRules.acs(_kscore_of(int(role)), _rounds_for(int(role)))


# ACS 的"局数"口径:**全场已进行的局数**(`_round_num`);中途离开者**冻结在他离开时所处的局号**
# = 他实际参与的局数。★ 代价(分母更小 ⇒ ACS 偏高)是**有意**的口径,不是 bug。
# ★ 卡在 MATCH_OVER 时 `_round_num` 恰好等于"打过的局数"(`_start_next_round` 在终局分支
#   提前 return,不推进局号)⇒ 终局那一份 ACS 的分母正是整场局数。
func _rounds_for(role: int) -> int:
	return int(_left_round.get(int(role), _round_num))


# 逐人表的 role 集合:在场者 ∪ 已离开者 ∪ 有数据的。
# ★ 在场者**哪怕一次伤害都没打过**也要出现(面板要的是"所有参战者各一行")。
func _roster() -> Dictionary:
	var roles := {}
	for role in players:
		roles[int(role)] = true
	for role in _left:
		roles[int(role)] = true
	for role in _stats:
		roles[int(role)] = true
	return roles


# 逐人数据载荷:`{role: {kills, deaths, assists, dealt, taken, kscore, acs}}`
# (给 `round_state` 的 `stats` 键;三模式同一份)。
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


# MVP = **整场 ACS 最高者**;并列 → 击杀多者 → 阵亡少者 → **role 号升序**。
# ★ 确定性:候选按 role 升序遍历 + 只在**严格更优**时替换 ⇒ 完全并列时天然胜者是最小 role,
#   不依赖字典迭代顺序(同一份状态调多少次都是同一个答案)。
# ★★ **已离开者照样参与评选 —— 用户裁定,不是遗漏**:取向与大乱斗"按分判胜"一致;
#   他会因"分母 = 实际参与局数"(更小)而更容易胜出,那**也是**有意的口径。
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


# 记一笔"谁打过谁"。(写端**不过滤队伍** —— 过滤只有一处,在 `_record_down` 的读端;
# 写端过滤会让"队友误伤拿助攻"这条规则散成两份判断。)
func _note_hit(victim_role: int, attacker_role: int) -> void:
	victim_role = int(victim_role)
	attacker_role = int(attacker_role)
	if not _assist_times.has(victim_role):
		_assist_times[victim_role] = {}
	(_assist_times[victim_role] as Dictionary)[attacker_role] = Time.get_ticks_msec()


# 清掉某受害者的助攻表 —— 由 `MatchRound._respawn_player` 调(复活 = 新的一条命,
# 与"助攻只算这一次倒地之前"一致)。★ 一处覆盖三模式:`RoyaleHost` / `TeamHost` 的
# `_respawn_player` 都 `super` 到 `MatchRound` 那一份。
func _clear_assist_table(victim_role: int) -> void:
	_assist_times.erase(int(victim_role))


# 逐人数据的唯一写入口(每次倒地边沿调一次)。
# ★ `deaths` **一律** +1:队友误炸 / 自杀 / 溺水全算死。
# ★ `kills` **只在"归因到且异队"**时记给杀手 —— 无归因与同队误炸不计**任何人**的击杀
#   (与"那一分照样给对方队"是两件事)。助攻由**本函数**就地记(计划 2 的 Task 1,
#   读端过滤见函数内的 `same_team` 那一段);惩罚由计划 2 的 Task 2 在此处补。
func _record_down(victim_role: int, killer_role: int) -> void:
	victim_role = int(victim_role)
	killer_role = int(killer_role)
	var v := _stat_entry(victim_role)
	v["deaths"] = int(v["deaths"]) + 1
	if killer_role == 0:
		return          # 无归因:不计任何人的击杀,**也不计任何人的助攻**
	if same_team(killer_role, victim_role):
		# ★ 队友击杀:不记 kills(用户裁定 ②),**也不记助攻**(没有"自己队的击杀"这回事)。
		#   "击杀队友"的代价记在**肇事者**行上,由惩罚那一项承担(见 Task 2)。
		var tm := _stat_entry(killer_role)
		tm["team_kills"] = int(tm["team_kills"]) + 1
		return
	var k := _stat_entry(killer_role)
	k["kills"] = int(k["kills"]) + 1
	# ── 助攻:表里**除击杀者之外**、且在归因窗口内、且**与击杀者同队**的 attacker ──
	# ★★ 前半句 `same_team(attacker, killer)` 是**唯一承重**的那半:没有它,受害者的**队友**
	#   误伤过他(爆炸),随后敌人把他补掉 ⇒ 那位队友**因为打死自己人而拿到助攻**(spec §3.4)。
	# ★★ 后半句 `same_team(attacker, victim)` 是**死代码** —— 但**不是"恒真"**(旧注释写错过
	#   这一点):上面那道 `if same_team(killer_role, victim_role): … return` 已经保证
	#   **击杀者与受害者异队**,于是"attacker 是受害者的队友"为真 ⇒ attacker 与 killer
	#   **必定不同队** ⇒ `not same_team(attacker, killer)` 早就为真 ⇒ 那个 `or` 的结果
	#   **永远不受后半句影响**。而"attacker 是受害者队友"这一档在本函数里**确实可达** ——
	#   ⑬k 的 (k3) 夹具本身就是(attacker 5 / victim 4 同属 2 队)⇒ 单看这一项它就是 true,
	#   挡掉那一档的始终是前半句。
	# ★ 留着它是**保险带**:哪天上面那道 `same_team(killer_role, victim_role)` 守卫改了
	#   (例如"队友击杀也算击杀"),它当场变成活的;照 spec §3.4 的写法也读得出来。
	#   ★ 变异实测(HEAD):只删后半句 ⇒ `ALL-OK`、**没有任何断言察觉**
	#     (ok 数不变:评审当时 150,本批 ⑬k 扩容后 156);
	#   只留后半句(删前半句)⇒ **只有 ⑬l 红**,(k3) 仍绿 —— 即"必须与击杀者同队"这条规则
	#   今天**只由 ⑬l 咬住**,别照 (k3) 的失败消息去推它的鉴别力(那条消息此后已订正)。
	# ★ 1v1 / 大乱斗:队伍表空 ⇒ `same_team` 恒 false ⇒ **天然拿不到任何助攻**,
	#   不需要特判(守卫:⑬l)。
	var now := Time.get_ticks_msec()
	var table: Dictionary = _assist_times.get(victim_role, {})
	for a in table:
		var attacker := int(a)
		if attacker == killer_role:
			continue
		if now - int(table[a]) > ATTRIB_WINDOW:
			continue
		if not same_team(attacker, killer_role) or same_team(attacker, victim_role):
			continue
		var sa := _stat_entry(attacker)
		sa["assists"] = int(sa["assists"]) + 1


# "**这一下**伤害是谁打的" —— 归因必须**新鲜**(`ATTRIB_FRESH_MS`)。无 → 0。
# ★ 为什么必须有一个**紧**窗口(8ms)而不是复用 3s:写端 `CombatFeedback.attribute` 在
#   `attacker == victim` 时**静默跳过**,于是自伤路径上 meta 会**停在上一名敌人**身上,而读端
#   只看"有没有 meta + 在不在时效内" ⇒ "自己的榴弹炸自己"会被错记成那名敌人的伤害。
#   真实命中路径的 `attribute()` → `take_hit()` → `took_hit` 是**同一调用栈**(年龄 ≈ 0~1ms),
#   而上一物理帧留下的归因至少 ~16.7ms 之前 ⇒ 8ms 落在两者之间。
# ★★ 已知边界(登记不修):同**一帧**内先被敌人打中、再被自己的爆炸炸到,meta 仍是那名敌人
#   且年龄 ≈ 0 —— 那一下会被记到敌人账上。
func _fresh_attacker_role(victim_role: int) -> int:
	var victim: Node2D = players.get(int(victim_role))
	if victim == null or not is_instance_valid(victim):
		return 0
	return _attributed_role_within(victim, ATTRIB_FRESH_MS)


# "上一个打 victim 的人"的 role,且归因年龄 ≤ `window_ms`(超窗/无归因/自伤 → 0)。
# ★ 读端有两处,问的是**两个不同的问题**,故窗口是参数而不是常量:击杀归属(子类的
#   `ATTRIB_WINDOW` = 3s)与逐人伤害(`ATTRIB_FRESH_MS` = 8ms)。
# ★ `shooter == victim` 的守卫不可省:写端自伤时静默跳过,但万一有人绕过写端直接 set_meta,
#   这里不能再把自伤算成"自己杀自己"。
# ★ 本函数**住在底座**,但**调用它的击杀归因函数住子类** ——
#   `tests/kh_l5_probe.gd:544-549` 的反向断言把那个名字列为"不得出现在基类并集里"。
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


# ── 出生点原语(阶段 5.6:**必须住在本底座**,不能在 MatchHost 里)──
# 父类的 MatchRound._respawn_player 要调它,而 GDScript 的父类方法解析不了子类符号 ——
# 方法与字段是同一条约束(实测踩到:放子类里直接 "Function _spawn_cell() not found in base self")。
# RoyaleHost 仍可覆写(虚分派与住哪一层无关)。


func _spawn_cell(role: int) -> Vector2i:
	var spawns := MazeGenerator.load_spawns()
	var key := "player" if (role == 1) != _side_swap else "player2"
	return spawns.get(key, Vector2i(-1, -1))

# 本局各 role 的出生点(canonical 格),供**进场拉取**(match_sync)下发给客户端。
# 1v1:由 `_spawn_cell` 得来(地图标定的 player/player2,换边只影响谁拿哪个)。
# ★ 大乱斗**必须覆写**成开局散点:基类实现走 `_spawn_cell`,而 `RoyaleHost` 覆写过的那个
#   第二次起会返回**动态复活点**,且带 `_spawned_once` 副作用 —— 拿它下发等于把复活点当出生点。
# ★ 这里给的是**只读取法**:别让上层直接读 `_round_spawns` 之类的私有字段(值可能被就地改)。

func role_spawns() -> Dictionary:
	var out := {}
	for role in players:
		out[int(role)] = _spawn_cell(int(role))
	return out

# 每物理帧:倒地转换检测(击杀计分/安排复活) + 回合状态机推进。
