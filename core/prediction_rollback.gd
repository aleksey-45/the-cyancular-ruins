class_name PredictionRollback
extends RefCounted
# C2 rollback 控制器(与引擎解耦,纯逻辑)。被预测 Player 的驱动方式由接入方决定,两种皆可:
#   A) 手动步进(冒烟/无引擎环境):每帧调 advance(record) —— 内部把玩家 input_source 换成
#      scratch NetworkInputSource,喂入该记录后步进一次,再换回 → 确定性复现该输入。
#   B) 引擎自步进(真机本地预测,读真实 Input):每帧由接入方在玩家被引擎步进后调
#      note_post_step(seq, capture),把要发的记录 note_input(seq, record);reconcile() 在
#      下一帧步进前处理到期权威。回滚重放内部走 A 的 swap+scratch 步进。
#
# 收到权威(ack=C, 整态 S):
#   - ring[C] ≈ S → 预测被证实:trim ≤ C(常态,几乎零成本)
#   - ring[C] ≠ S → 真性分歧(服务器外部事件:命中/传送/换边/墙/漂移):
#                   restore(S) 到权威态,按序重放 (C, last_applied] 的本地输入 → 重对齐。
#                   「重放 = 错在哪补哪」,绝不做橡皮筋位置拉拢(复盘 P2)。
# 前提:服务器每物理 tick 恰好消费 1 个输入包并回带 ack_seq + capture_state() 整态
#       (server/match_host.gd;见 docs/pvp-c2-retrospective.md P1)。

const KEEP := 256           # ring 保留窗口
const PHYS_DT := 1.0 / 60.0 # 回滚重放一律按固定物理步(确定性)

var _p = null               # 被预测 Player(动态)
var _scratch: NetworkInputSource = NetworkInputSource.new()   # 步进/重放喂入源

var _inputs: Dictionary = {}   # seq(int) -> 输入包记录(重放用)
var _captures: Dictionary = {} # seq(int) -> 步进后 capture_state()(比对/锚点)
var _seqs: Array[int] = []     # _captures 键升序
var _last_applied := 0
var _acked := 0
var _pending: Array = []       # [[ack, state], ...] 待 reconcile
var _rollbacks := 0

func bind(p) -> void:
	_p = p

func last_applied() -> int:
	return _last_applied

func rollback_count() -> int:
	return _rollbacks

# ── 驱动 A:手动步进(本控制器喂 scratch 步进一次,记 capture)──
func advance(record: Dictionary) -> void:
	reconcile()
	if _p == null:
		return
	var seq := int(record.get("seq", _last_applied + 1))
	_step(record)
	_last_applied = seq
	_inputs[seq] = record
	_captures[seq] = _p.capture_state()
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_inputs.erase(old)
		_captures.erase(old)

# ── 驱动 B:引擎自步进——接入方在玩家被引擎步进后记录,在下次步进前 reconcile ──
func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	_captures[seq] = capture
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_captures.erase(old)

func note_input(seq: int, record: Dictionary) -> void:
	_inputs[seq] = record

# 服务器权威快照到达(可跨帧缓存,reconcile 时处理)。
func on_authoritative(ack: int, state: Dictionary) -> void:
	if ack <= _acked:
		return
	_pending.append([ack, state])

# 接入方每帧(玩家步进前)调用:处理所有到期权威快照。
func reconcile() -> void:
	while not _pending.is_empty():
		var pk: Array = _pending.pop_front()
		_handle_ack(int(pk[0]), pk[1])

# 权威态作预测起点重设(对局开始/换边/复活后)。
func reset_to(ack: int, state: Dictionary) -> void:
	_acked = ack
	_pending.clear()
	_inputs.clear()
	_captures.clear()
	_seqs.clear()
	_last_applied = ack
	if _p != null and not state.is_empty():
		_p.restore_state(state)

# 用记录步进一次:临时把玩家输入源换成 scratch(喂入该记录),步进后换回。
# 这样被预测玩家平时可读真实 Input(真机手感不变),重放才切换历史输入,保证孪生一致。
func _step(record: Dictionary) -> void:
	if _p == null:
		return
	var prev = _p.input_source
	_p.set_input_source(_scratch)
	_scratch.clear_edges()
	_scratch.apply_packet(record)
	_p._physics_process(PHYS_DT)
	_p.set_input_source(prev)

func _handle_ack(ack: int, S: Dictionary) -> void:
	if ack <= _acked:
		return
	_acked = ack
	if _p == null or not _captures.has(ack):
		_trim(ack)
		return
	var predicted: Dictionary = _captures[ack]
	if _close_enough(predicted, S):
		_trim(ack)          # 预测被证实:确认丢弃 ≤ ack
		return
	# 真性分歧 → 权威锚定 + 重放未确认输入(错在哪补哪,非拉拢)
	_rollbacks += 1
	_p.restore_state(S)
	for s in _seqs:
		if s > ack and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			_step(rec)
			_captures[s] = _p.capture_state()   # 刷新为重放后的真实整态
	_trim(ack)

func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)

# 两整态是否"预测被证实"(同一模拟下应 ≈ 相等;浮点/进程差给个小容差)。
# 超出 = 服务器外部事件或漂移 → 走 rollback。只比影响判定的关键量,避免过度回滚。
func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	if a.get("down", false) != b.get("down", false):
		return false
	if int(a.get("hp", 0)) != int(b.get("hp", 0)):
		return false
	var pa: Vector2 = a.get("pos", Vector2.ZERO)
	var pb: Vector2 = b.get("pos", Vector2.ZERO)
	if pa.distance_to(pb) > 1.0:
		return false
	var va: Vector2 = a.get("vel", Vector2.ZERO)
	var vb: Vector2 = b.get("vel", Vector2.ZERO)
	return va.distance_to(vb) < 20.0
