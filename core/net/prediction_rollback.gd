class_name PredictionRollback
extends RefCounted

const KEEP := 256
const PHYS_DT := 1.0 / 60.0
var ticks_per_record := 1

var _p = null
var _scratch: PacketInputSource = PacketInputSource.new()

var _inputs: Dictionary = {}
var _captures: Dictionary = {}
var _seqs: Array[int] = []
var _last_applied := 0
var _acked := 0
var _pending: Array = []
var _rollbacks := 0
var _last_event_seq := 0
var _event_aligns := 0
var _event_rejects := 0
var _rej_ack := 0
var _rej_future := 0
var _rej_missing := 0
var _rej_order := 0
var _events: Dictionary = {}

var map_px: Vector2 = Vector2.ZERO

# 「预测被证实」的位置容差(px),回滚频率的闸门:贴身时对手在客户端眼里恒有滞后(实测 8 tick ≈ 93px),1px 容差会每帧 restore+重放。
# 实测 2px 砍掉 ~95% 频率而接触期偏差一行没动(那每帧一次的回滚本来就没买到精度)。代价:容差内的位置误差不再纠正;down/hp 仍精确比较。
const DEFAULT_POS_TOL := 2.0
var pos_tol: float = DEFAULT_POS_TOL

const DEFAULT_CONTACT_POS_TOL := 8.0
var contact_pos_tol: float = DEFAULT_CONTACT_POS_TOL
# ★ 2026-10-28:客户端在贴身区按"相对速度 × 幽灵滞后"动态覆盖它(8~48px,见 core/net/prediction_contact.gd);
#   本常量现在只是下限/默认值,别再以为它恒是 8。

# 接触期速度容差(px/s)。★ 2026-10-31:同一台机器 3 客户端 soak 实测,回滚里 83~98% 是"纯速度分歧"
const DEFAULT_CONTACT_VEL_TOL := 400.0
var contact_vel_tol: float = DEFAULT_CONTACT_VEL_TOL
const VEL_TOL := 20.0

# 「预测被证实」要比对的字段集合(单一来源):S-06 —— 原先这 4 个字段的判据散在 _close_enough 函数体里,
const PREDICTED_FIELDS := ["down", "hp", "pos", "vel"]

var in_contact: bool = false

func bind(p) -> void:
	_p = p

func last_applied() -> int:
	return _last_applied

func rollback_count() -> int:
	return _rollbacks


func event_aligns() -> int:
	return _event_aligns


func event_rejects() -> int:
	return _event_rejects


## 拒绝原因分解(真链路读数用):ack=已被权威覆盖 / future=来自未来 / missing=环外 / order=乱序或失效。
func event_reject_breakdown() -> String:
	return "ack=%d future=%d missing=%d order=%d" % [_rej_ack, _rej_future, _rej_missing, _rej_order]

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
		_events.erase(old)

func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	_captures[seq] = capture
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_inputs.erase(old)
		_captures.erase(old)
		_events.erase(old)

func note_input(seq: int, record: Dictionary) -> void:
	_inputs[seq] = record

func on_authoritative(ack: int, state: Dictionary) -> void:
	if ack <= _acked:
		return
	_pending.append([ack, state])

# 外部事件注入的返回码。★ APPLIED 必须是 0:GDScript 运行期错误只会打断"出错的那个函数"并按返回类型给默认值,
# 拒绝路径若被写坏(越界访问)会返回默认值 —— 让它落在 APPLIED 上,探针的"必须 REJECTED"断言才会红,而不是静默假绿。
enum EventApply { APPLIED, REJECTED }

func apply_external_event(seq: int, apply: Callable) -> int:
	if _p == null or not apply.is_valid():
		_event_rejects += 1
		_rej_order += 1
		return EventApply.REJECTED
	if seq > _last_applied:
		_event_rejects += 1
		_rej_future += 1
		return EventApply.REJECTED
	if seq <= _acked:
		_event_rejects += 1
		_rej_ack += 1
		return EventApply.REJECTED
	if not _captures.has(seq):
		_event_rejects += 1
		_rej_missing += 1
		return EventApply.REJECTED
	if seq < _last_event_seq:
		_event_rejects += 1
		_rej_order += 1
		return EventApply.REJECTED
	if not _events.has(seq):
		_events[seq] = []
	(_events[seq] as Array).append(apply)
	_p.restore_state(_captures[seq])
	apply.call()
	_captures[seq] = _p.capture_state()
	_replay_steps_after(seq)
	_last_event_seq = seq
	_event_aligns += 1
	return EventApply.APPLIED


func _replay_steps_after(anchor: int) -> void:
	for s in _seqs:
		if s > anchor and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			_step(rec)
			_apply_events_at(s)
			_captures[s] = _p.capture_state()


func _apply_events_at(seq: int) -> void:
	var evs: Array = _events.get(seq, [])
	for ev in evs:
		var cb: Callable = ev
		if cb.is_valid():
			cb.call()

func reconcile() -> void:
	while not _pending.is_empty():
		var pk: Array = _pending.pop_front()
		_handle_ack(int(pk[0]), pk[1])

func _step(record: Dictionary) -> void:
	if _p == null:
		return
	var prev = _p.input_source
	_p.set_input_source(_scratch)
	_scratch.clear_edges()
	_scratch.apply_packet(record)
	for i in maxi(1, ticks_per_record):
		if i > 0:
			_scratch.clear_edges()
		_manual_sim_step()
	_p.set_input_source(prev)


# ★★ 重放用的手动物理步。这里是「双驱动」的控制器那一半 —— 引擎也在步进同一个节点,时序契约:
func _manual_sim_step() -> void:
	_p._physics_process(PHYS_DT)

func _handle_ack(ack: int, S: Dictionary) -> void:
	if ack <= _acked:
		return
	_acked = ack
	if _p == null or not _captures.has(ack):
		_trim(ack)
		return
	var predicted: Dictionary = _captures[ack]
	if _close_enough(predicted, S):
		if _p.has_method("sync_soft_state"):
			_p.sync_soft_state(S)
		_trim(ack)
		return
	if NetDiag.enabled():
		NetDiag.log_event("rollback", {
			"ack": ack,
			"field": last_fail_field,
			"pos_err": snappedf(_pos_dist(predicted.get("pos", Vector2.ZERO), S.get("pos", Vector2.ZERO)), 0.01),
			"vel_err": snappedf(Vector2(predicted.get("vel", Vector2.ZERO)).distance_to(Vector2(S.get("vel", Vector2.ZERO))), 0.01),
			"in_contact": in_contact,
			"pos_tol": snappedf(contact_pos_tol if in_contact else pos_tol, 0.01),
			"vel_tol": snappedf(contact_vel_tol if in_contact else VEL_TOL, 0.01),
			"hp_before": int(predicted.get("hp", 0)),
			"hp_after": int(S.get("hp", 0)),
			"replay": _last_applied - ack,
		}, true)
	_rollbacks += 1
	_p.restore_state(S)
	_apply_events_at(ack)
	_replay_steps_after(ack)
	_trim(ack)

func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)
		_events.erase(s)

var last_fail_field := ""

func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	last_fail_field = ""
	for f in PREDICTED_FIELDS:
		if not _within(String(f), a, b):
			last_fail_field = String(f)
			return false
	return true


# 单字段比对。默认分支 false = 表里出现未知字段时判分歧(大声:宁多回滚一次,也不静默当成一致)。
func _within(field: String, a: Dictionary, b: Dictionary) -> bool:
	match field:
		"down":
			return a.get("down", false) == b.get("down", false)
		"hp":
			return int(a.get("hp", 0)) == int(b.get("hp", 0))
		"pos":
			var tol: float = contact_pos_tol if in_contact else pos_tol
			return _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) <= tol
		"vel":
			var va: Vector2 = a.get("vel", Vector2.ZERO)
			var vb: Vector2 = b.get("vel", Vector2.ZERO)
			var vtol: float = contact_vel_tol if in_contact else VEL_TOL
			return va.distance_to(vb) < vtol
		_:
			return false


# 两个位置在环面上是否几乎同位:裸 distance_to 在跨接缝那一帧会给出「一整幅地图宽」的假分歧 ⇒ 白跑一次回滚。
func _pos_dist(a: Vector2, b: Vector2) -> float:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return a.distance_to(b)
	return MazeGenerator.toroidal_delta_px(a, b, map_px.x, map_px.y).length()
