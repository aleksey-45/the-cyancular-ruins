extends RefCounted

# 时间视觉与时间场驱动:底片/加速 ramp、贷款深度、音高、高亮、按键边沿 deny、回溯/录制状态机。
# 时间状态与账本在 host(Level0)上,这里只放每帧操作;依赖注入,不反向找 Level0。

const GLOW_PLAYER := Color(0.30, 0.62, 1.0)
const GLOW_ENEMY := Color(1.0, 0.94, 0.86)
const GLOW_ELITE := Color(1.0, 0.82, 0.06)
const GLOW_RADIUS := 1500.0

var _host: Node = null


func setup(host: Node) -> void:
	_host = host


func tick_time_visuals(delta: float) -> void:
	var pp: PostProcess = _host._post_process
	var tf: TimeField = _host.time_field
	if pp == null or tf == null:
		return
	var rewinding: bool = tf.is_rewinding()
	_host._film_t = move_toward(_host._film_t, 1.0 if rewinding else 0.0, delta / 0.2)
	_host._haste_t = move_toward(_host._haste_t, 1.0 if tf.is_hasting() else 0.0, delta / 0.1)
	pp.set_time_effects(_host._film_t, tf.loan_depth(), _host._haste_t)

	var depth := tf.loan_depth()
	var mult := 1.0 + TimeParams.LOAN_PITCH_RANGE * depth
	if tf.is_hasting():
		mult += 0.12
	elif rewinding:
		mult -= 0.15
	Sfx.pitch_mult = clampf(mult, 0.7, 1.8)
	sync_time_glows()


func sync_time_glows() -> void:
	var tf: TimeField = _host.time_field
	if tf == null:
		return
	var want: Dictionary = {}
	if tf.is_hasting():
		var pl := _host.get_node_or_null("WorldViewport/Player") as Node2D
		if pl != null:
			want[pl] = [GLOW_PLAYER, 1]
		for e in _host.get_tree().get_nodes_in_group("enemies"):
			if not (e is Node2D) or not is_instance_valid(e) or bool(e.get("is_dead")):
				continue
			if e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]
			elif near_player(e as Node2D):
				want[e] = [GLOW_ENEMY, 1]
	elif tf.is_rewinding():
		for e in _host.get_tree().get_nodes_in_group("enemies"):
			if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]
	for k in _host._glows.keys():
		if not is_instance_valid(k) or not want.has(k):
			var old: TimeGlow = _host._glows[k]
			if is_instance_valid(old):
				old.queue_free()
			_host._glows.erase(k)
	for k in want.keys():
		var spec: Array = want[k]
		var g: TimeGlow = _host._glows.get(k)
		if g == null or not is_instance_valid(g):
			g = TimeGlow.attach(k, spec[0], int(spec[1]))
			if g != null:
				_host._glows[k] = g
		else:
			g.set_color(spec[0])


func near_player(n: Node2D) -> bool:
	var pl := _host.get_node_or_null("WorldViewport/Player") as Node2D
	if pl == null:
		return false
	var d := MazeGenerator.toroidal_delta_px(n.global_position, pl.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return d.length() <= GLOW_RADIUS


func drive_time(delta: float, want_rewind: bool, want_haste: bool) -> void:
	var ga: GrainAccount = _host.grain_account
	if ga != null and want_rewind and not _host._prev_want_rewind and not ga.can_spend():
		Sfx.play("deny")
	if ga != null and want_haste and not _host._prev_want_haste and not ga.can_spend():
		Sfx.play("deny")
	_host._prev_want_rewind = want_rewind
	_host._prev_want_haste = want_haste
	var tf: TimeField = _host.time_field
	tf.update(delta, want_rewind, want_haste)


func tick_rewind(delta: float) -> void:
	var rw: WorldRewind = _host._rewind
	if rw == null:
		return
	var ledger: TileLedger = _host._tile_ledger
	var pl := _host.get_node_or_null("WorldViewport/Player")
	var tf: TimeField = _host.time_field
	var rewinding: bool = tf != null and tf.is_rewinding()
	if rewinding and not rw.was_rewinding:
		rw.begin()
		_host._tile_cursor = rw.recorded_seconds()
	elif not rewinding and rw.was_rewinding:
		var exit_t: float = rw.finish()
		if ledger != null:
			ledger.prune_after(exit_t)
	rw.was_rewinding = rewinding
	_host._prev_time_mode = tf.mode if tf != null else 0
	if rewinding:
		WorldRewind.hold_corpses = false
		rw.step(delta, pl)
		_host._rewind_elite_hits()
		if ledger != null and _host._tile_cursor >= 0.0:
			var target := rw.current_target()
			for e in ledger.take_range(target, _host._tile_cursor):
				for c in e["cells"]:
					_host._restore_sub(c)
			_host._tile_cursor = target
	else:
		WorldRewind.hold_corpses = true
		rw.record(delta, pl, _host.get_tree().get_nodes_in_group("enemies"),
				_host.get_tree().get_nodes_in_group("bullet"))
		WorldRewind.expire_corpses(_host.get_tree())
		if ledger != null:
			if not _host._tile_pending.is_empty():
				ledger.record(rw.recorded_seconds(), _host._tile_pending)
				_host._tile_pending = []
			ledger.prune(rw.recorded_seconds() - TimeParams.SNAP_SECONDS)
