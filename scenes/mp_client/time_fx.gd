class_name TimeFx
extends RefCounted


const TIME_GLOW_SELF := Color(0.30, 0.62, 1.0)
const TIME_GLOW_OTHER := Color(1.0, 0.94, 0.86)

var _state: ClientState = null
var _ports: ClientPorts = null
var _fx_self_t := 0.0
var _fx_other_t: Dictionary = {}
var _rw_film_mats: Dictionary = {}
var _rw_ghosts: Dictionary = {}


func bind(state: ClientState, ports: ClientPorts) -> void:
	_state = state
	_ports = ports


func tick(delta: float, self_hasting: bool) -> void:
	var local: Node2D = _state._local
	if self_hasting:
		if TimeGlow.on(local) == null:
			TimeGlow.attach(local, TIME_GLOW_SELF)
		_fx_self_t -= delta
		if _fx_self_t <= 0.0:
			_fx_self_t = 0.03
			var anim := local.animator as AnimatedSprite2D
			if anim != null:
				var red := int(Time.get_ticks_msec() / 60) % 2 == 0
				AfterImage.spawn((local as Node).get_parent(), anim,
						Color(1.0, 0.25, 0.25, 0.55) if red else Color(0.3, 0.4, 1.0, 0.55))
	else:
		var g := TimeGlow.on(local)
		if g != null:
			g.queue_free()
	var any_hasting := false
	for rep_node in _ports.all_replicas.call():
		if not is_instance_valid(rep_node) or not (rep_node is Node2D):
			continue
		var rep := rep_node as Node2D
		_time_fx_replica_rewind(rep, delta)
		if bool(rep.get_meta("rewind", false)):
			_time_fx_replica_off(rep)
			continue
		if not bool(rep.get_meta("haste", false)):
			_time_fx_replica_off(rep)
			continue
		any_hasting = true
		_time_fx_replica_on(rep, delta)
	if not any_hasting:
		_fx_other_t.clear()


func detach(rep: Node2D) -> void:
	_time_fx_replica_rewind_off(rep)
	_fx_other_t.erase(rep)


func _time_fx_replica_off(rep: Node2D) -> void:
	_fx_other_t.erase(rep)
	var glow := TimeGlow.on(rep)
	if glow != null:
		glow.queue_free()
	var label := rep.get_node_or_null("HasteTag") as Label
	if label != null:
		label.visible = false


func _time_fx_replica_on(rep: Node2D, delta: float) -> void:
	if TimeGlow.on(rep) == null:
		TimeGlow.attach(rep, TIME_GLOW_OTHER)
	var label := rep.get_node_or_null("HasteTag") as Label
	if label == null:
		label = UiFactory.label("▶▶ 3x", 16, Color(0.78, 0.55, 1.0))
		label.name = "HasteTag"
		label.position = Vector2(-26, -92)
		rep.add_child(label)
	label.text = "▶▶ %dx" % int(round(_state._time_haste_mult))
	label.visible = true
	var t := float(_fx_other_t.get(rep, 0.0))
	t -= delta
	if t <= 0.0:
		_fx_other_t[rep] = 0.06
		var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if anim != null:
			AfterImage.spawn(rep.get_parent(), anim, Color(1.0, 0.25, 0.25, 0.30))
			AfterImage.spawn(rep.get_parent(), anim, Color(0.3, 0.4, 1.0, 0.30))
	else:
		_fx_other_t[rep] = t


func _time_fx_replica_rewind(rep: Node2D, delta: float) -> void:
	if not bool(rep.get_meta("rewind", false)):
		_time_fx_replica_rewind_off(rep)
		return
	if not _rw_film_mats.has(rep):
		var m := ShaderMaterial.new()
		m.shader = load("res://scenes/effects/time_film.gdshader")
		m.set_shader_parameter("coverage", 1.0)
		rep.material = m
		_rw_film_mats[rep] = m
	var trail: Array = rep.get_meta("trail_last", [])
	var new_trail: Array = rep.get_meta("trail", [])
	var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim != null:
		for pt in _fresh_trail_points(trail, new_trail):
			var ghost_host := Node2D.new()
			ghost_host.global_position = Vector2(float(pt[0]), float(pt[1]))
			rep.get_parent().add_child(ghost_host)
			AfterImage.spawn(ghost_host, anim, Color(0.82, 0.88, 0.92, 0.35))
			var ghosts: Array = _rw_ghosts.get(rep, [])
			ghosts.append({"node": ghost_host, "t": 0.0})
			_rw_ghosts[rep] = ghosts
	rep.set_meta("trail_last", new_trail.duplicate())
	var ghosts2: Array = _rw_ghosts.get(rep, [])
	var alive: Array = []
	for g in ghosts2:
		g["t"] = float(g["t"]) + delta
		var host: Node2D = g["node"]
		if float(g["t"]) < 1.0 and is_instance_valid(host):
			if host.get_child_count() > 0:
				var vis := host.get_child(0) as CanvasItem
				if vis != null:
					vis.modulate.a = clampf(0.35 * (1.0 - float(g["t"])), 0.0, 1.0)
			alive.append(g)
		elif is_instance_valid(host):
			host.queue_free()
	_rw_ghosts[rep] = alive


static func _fresh_trail_points(old_trail: Array, new_trail: Array) -> Array:
	var max_k := mini(old_trail.size(), new_trail.size())
	var k := max_k
	while k > 0:
		var same := true
		for j in k:
			if not _same_trail_pt(old_trail[old_trail.size() - k + j], new_trail[j]):
				same = false
				break
		if same:
			break
		k -= 1
	return new_trail.slice(k)


static func _same_trail_pt(a: Variant, b: Variant) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var x: Array = a
	var y: Array = b
	return x.size() >= 2 and y.size() >= 2 \
			and is_equal_approx(float(x[0]), float(y[0])) \
			and is_equal_approx(float(x[1]), float(y[1]))


func _time_fx_replica_rewind_off(rep: Node2D) -> void:
	if _rw_film_mats.has(rep):
		if is_instance_valid(rep) and rep.material == _rw_film_mats[rep]:
			rep.material = null
		_rw_film_mats.erase(rep)
	if _rw_ghosts.has(rep):
		for g in _rw_ghosts[rep]:
			if is_instance_valid(g["node"]):
				(g["node"] as Node).queue_free()
		_rw_ghosts.erase(rep)
	if rep.has_meta("trail_last"):
		rep.remove_meta("trail_last")
