class_name ReplicaSet
extends RefCounted


const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")
const LABEL_SCRIPT := preload("res://ui/factory/world_label.gd")
const HP_BAR_OFFSET := LABEL_SCRIPT.HP_BAR_OFFSET

var _state: ClientState = null
var _ports: ClientPorts = null
var _replicas: Dictionary = {}
var _tint_of: Callable = Callable()
var _on_created: Callable = Callable()
var _id_labels: Dictionary = {}
var _hp_bars: Dictionary = {}


## 绑定宿主(同一份 `_replicas` 引用)与两个 Callable;`on_created` 省略 = 无补配。
func bind(state: ClientState, ports: ClientPorts, tint_of: Callable,
		on_created: Callable = Callable()) -> void:
	_state = state
	_ports = ports
	_replicas = state._replicas
	_tint_of = tint_of
	_on_created = on_created


func ensure(role: int) -> Node:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return _replicas[role]
	var replica: Node2D = REPLICA_SCENE.instantiate()
	replica.name = "ReplicaP%d" % role
	_state._world.add_child(replica)
	_replicas[role] = replica
	ensure_label(role)
	var col: Color = _tint_of.call(role)
	_ports.apply_tint.call(replica.get_node_or_null("AnimatedSprite2D"), col)
	if _on_created.is_valid():
		_on_created.call(replica, role)
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_state._world.add_child(bar)
		_hp_bars[role] = bar
	refresh_labels()
	return replica


func remove(role: int) -> void:
	if _replicas.has(role):
		var r: Node2D = _replicas[role]
		_ports.time_fx_rewind_off.call(r)
		if is_instance_valid(r):
			r.queue_free()
		_replicas.erase(role)
	if _id_labels.has(role):
		var l: Node = _id_labels[role]
		if is_instance_valid(l):
			l.queue_free()
		_id_labels.erase(role)
	if _hp_bars.has(role):
		var b: Node = _hp_bars[role]
		if is_instance_valid(b):
			b.queue_free()
		_hp_bars.erase(role)
	refresh_labels()


## 消费一条世界包:按 players 懒建/拆副本、套 apply_snapshot、刷血条(掉线者从快照消失即一并拆掉)。
## ★ 自己那份刻意不消费:C2 下本地玩家由引擎自步进,权威整态走本人包;写进来 = 每帧强写 = 橡皮筋。
func apply_world_snapshot(world: Dictionary) -> void:
	var local: Node2D = _state._local
	if local == null:
		return
	var snap_tick := int(world.get("tick", 0))
	if snap_tick < _state._last_snap_tick:
		return
	_state._last_snap_tick = snap_tick
	var players_snap: Dictionary = world["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role != PvpSession.role:
			var r := ensure(role) as Node2D
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, local.global_position, snap_tick)
				r.set_meta("haste", bool(data.get("haste", false)))
				r.set_meta("rewind", bool(data.get("rewind", false)))
				r.set_meta("trail", data.get("trail", []))
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
					(_hp_bars[role] as Node2D).visible = not bool(data.get("downed", false))
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			remove(int(role_str))


func ensure_label(role: int) -> void:
	if _state._world == null or _id_labels.has(role):
		return
	var lbl: Node2D = LABEL_SCRIPT.new()
	_state._world.add_child(lbl)
	_id_labels[role] = lbl


func refresh_labels() -> void:
	var names: Dictionary = _state._names
	for role in _id_labels:
		var nm := str(names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(names.get(role, PvpSession.player_name))
		var col: Color = _tint_of.call(int(role))
		(_id_labels[role] as Node2D).set_label(nm, col)


func follow(head_offset: Vector2) -> void:
	var local: Node2D = _state._local
	for role in _id_labels:
		var target: Node2D = local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + head_offset
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + HP_BAR_OFFSET
