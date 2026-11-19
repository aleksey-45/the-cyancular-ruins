class_name HitEvents
extends RefCounted


var _state: ClientState = null
var _replica_for: Callable = Callable()

# 受击事件队列:网络回调跑在 idle 帧,而注入要重放(内部 move_and_slide)—— 物理帧外 move_and_slide 位移恒 0(实测),
# 故回调只入队,统一在下一个物理帧开头注入(反馈最多晚 1 帧 ≈16.7ms)。
var _pending_hit_events: Array = []


func bind(state: ClientState, replica_for: Callable) -> void:
	_state = state
	_replica_for = replica_for


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void:
	if _state._local == null:
		return
	if victim_role == PvpSession.role:
		# 网络回调在 idle 帧:只入队,由 _drain_hit_events() 在下一个物理帧开头注入(帧外 move_and_slide 位移恒 0)。
		_pending_hit_events.append([source_pos, damage, seq])
		return
	var r: Node2D = _replica_for.call(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


func _drain_hit_events() -> void:
	if _pending_hit_events.is_empty():
		return
	var events: Array = _pending_hit_events
	_pending_hit_events = []
	for ev in events:
		_apply_local_hit_event(ev[0], int(ev[1]), int(ev[2]))


func _apply_local_hit_event(source_pos: Vector2, damage: int, seq: int) -> void:
	if _state._rollback != null and _state._rollback.apply_external_event(seq, func() -> void:
			_state._local.take_hit(source_pos, damage, false, -1.0)) \
			== PredictionRollback.EventApply.APPLIED:
		return
	_state._local.take_hit(source_pos, damage, false, -1.0, true)


func clear() -> void:
	_pending_hit_events.clear()
