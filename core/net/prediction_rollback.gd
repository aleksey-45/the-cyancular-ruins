class_name PredictionRollback
extends RefCounted
# 客户端回滚与预测控制器。负责在客户端推演本地输入，并在收到服务端权威快照时进行校验与对齐回滚。
# 支持两种驱动方式：
#   A) 手动步进：测试或无场景树环境下调用 advance(record)，使用内部临时输入源驱动玩家步进。
#   B) 引擎物理步进：本地真实玩家在 _physics_process 步进后记录 note_post_step()，
#      并在下一帧物理步进前调用 reconcile() 处理到期的服务端权威快照。
#
# 权威状态校验流程：
#   - 本地预测状态与服务端快照一致：在容差范围内认为预测成功，清理对应输入缓存。
#   - 本地预测状态与服务端快照分歧：恢复至服务端权威状态，并按序重放未确认的历史输入帧。
# 前提：服务端每物理帧消费 1 个输入包，并返回包含 ack_seq 与完整状态 capture_state() 的快照。

const KEEP := 256           # ring 保留窗口
const PHYS_DT := 1.0 / 60.0 # 回滚重放一律按固定物理步(确定性)

var _p = null               # 被预测 Player(动态)
var _scratch: PacketInputSource = PacketInputSource.new()   # 步进/重放传入源

var _inputs: Dictionary = {}   # seq(int) -> 输入包记录(重放用)
var _captures: Dictionary = {} # seq(int) -> 步进后 capture_state()(比对/锚点)
var _seqs: Array[int] = []     # _captures 键升序
var _last_applied := 0
var _acked := 0
var _pending: Array = []       # [[ack, state], ...] 待 reconcile
var _rollbacks := 0

# 环面地图尺寸（像素）。若为零向量则不做环面处理，直接使用平面欧氏距离。
# 不直接引用全局单例，由接入方显式配置，便于无场景树环境独立测试。
var map_px: Vector2 = Vector2.ZERO

# 预测一致性位置容差（像素）。超出容差将判定为状态分歧并触发回滚。
# 取值 2.0 像素，在消除抖动与保持同步手感之间取得平衡。
const DEFAULT_POS_TOL := 2.0
var pos_tol: float = DEFAULT_POS_TOL

# 接触状态下的位置容差（像素）。
# 当实体与远端对手身体贴身近战时，将容差放宽至 8.0 像素，避免因碰撞几何微小抖动引发每帧高频回滚。
const DEFAULT_CONTACT_POS_TOL := 8.0
var contact_pos_tol: float = DEFAULT_CONTACT_POS_TOL

# 本帧是否处于近身接触状态（由 Player.touching_player() 更新，纯本地状态提示，不参与网络同步）
var in_contact: bool = false

func bind(p) -> void:
	_p = p

func last_applied() -> int:
	return _last_applied

func rollback_count() -> int:
	return _rollbacks

# 驱动方式 A：手动步进（通过临时输入源步进一次并记录预测状态）。
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

# 驱动方式 B：引擎物理步进（接入方在实体完成物理步进后记录状态，下次步进前调谐）。
func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	_captures[seq] = capture
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_captures.erase(old)

func note_input(seq: int, record: Dictionary) -> void:
	_inputs[seq] = record

# 服务端权威快照到达。
func on_authoritative(ack: int, state: Dictionary) -> void:
	if ack <= _acked:
		return
	_pending.append([ack, state])

# 每帧处理已收到的服务端权威快照。
func reconcile() -> void:
	while not _pending.is_empty():
		var pk: Array = _pending.pop_front()
		_handle_ack(int(pk[0]), pk[1])

# 使用历史输入记录执行单步重放：临时将实体输入源替换为缓存输入源，步进后还原。
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
		# 预测一致时，同步背包（武器槽与弹药）等由服务端权威决定的非预测状态
		if _p.has_method("sync_soft_state"):
			_p.sync_soft_state(S)
		_trim(ack)          # 预测成功：清理已确认的历史输入
		return
	# 状态分歧：对齐至服务端权威状态，并按序重放未确认的本地输入帧
	_rollbacks += 1
	_p.restore_state(S)
	for s in _seqs:
		if s > ack and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			_step(rec)
			_captures[s] = _p.capture_state()   # 刷新为重放后的真实完整状态
	_trim(ack)

func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)

# 比对本地预测状态与服务端权威状态是否在容差范围内一致。
func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	if a.get("down", false) != b.get("down", false):
		return false
	if int(a.get("hp", 0)) != int(b.get("hp", 0)):
		return false
	# 根据当前是否近身接触选择对应容差
	var tol: float = contact_pos_tol if in_contact else pos_tol
	if _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) > tol:
		return false
	var va: Vector2 = a.get("vel", Vector2.ZERO)
	var vb: Vector2 = b.get("vel", Vector2.ZERO)
	return va.distance_to(vb) < 20.0


# 计算环面上的最短位置差，避免跨越地图边界时误判为位置分歧
func _pos_dist(a: Vector2, b: Vector2) -> float:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return a.distance_to(b)
	return MazeGenerator.toroidal_delta_px(a, b, map_px.x, map_px.y).length()
