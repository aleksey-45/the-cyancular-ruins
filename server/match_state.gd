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
# 服务器权威对局模拟(每房间一个):建世界(只碰撞不渲染)+ 两个 Player(NetworkInputSource 注入)。
# 每物理帧消费双方输入包注入,玩家 _physics_process 自动跑(Player 是 CharacterBody2D,父先于子)。
# 协议只传 canonical 坐标;渲染归各端副本(客户端侧),服务器只存真值。

var players: Dictionary = {}        # role(int) -> Player
var input_sources: Dictionary = {}  # role -> NetworkInputSource
var peer_by_role: Dictionary = {}   # role -> peer_id
var _pending_input: Dictionary = {} # role -> Array[输入包队列],按序消费不丢 just_pressed 边沿
var grid: Array = []
var _base_grid: Array = []   # 建局原始(未破坏)网格深拷贝:每局复位重铺,防客户端/服务器砖状态漂移
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
var _rounds_won: Dictionary = {} # role -> 局胜数
var _round_timer := 0.0
var _side_swap := false          # true 时 P1 用 player2 出生点(每局换边)
var _respawn_pending: Dictionary = {}  # role -> 剩余复活秒
var _down_counted: Dictionary = {}     # role -> 本次倒地是否已计分/已入复活流程
var _last_round_winner := 0            # 最近一局的胜者 role(客户端播报"本局胜利/落败"用)



func _rpc_all(method: String, args: Array = [], except_role: int = -1,
		live_only: bool = false) -> void:
	var live_peers := multiplayer.get_peers() if live_only else PackedInt32Array()
	for role in peer_by_role:
		if role == except_role or not players.has(role):
			continue
		var peer: int = peer_by_role[role]
		if live_only and not live_peers.has(peer):
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
