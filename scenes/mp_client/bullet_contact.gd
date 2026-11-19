class_name BulletContact
extends RefCounted


const HitShape := preload("res://core/sim/hit_shape.gd")

var _ports: ClientPorts = null
var _hits_entity: Callable = Callable()
var _contact_targets: Array = []
var _contact_targets_frame := -1


func bind(ports: ClientPorts, hits_entity: Callable) -> void:
	_ports = ports
	_hits_entity = hits_entity


func _tree() -> SceneTree:
	return _ports.get_tree.call() as SceneTree


func contact_targets_now() -> Array:
	var f := Engine.get_physics_frames()
	if f != _contact_targets_frame:
		_contact_targets_frame = f
		_contact_targets.clear()
		var tree := _tree()
		if tree != null:
			for group in BulletBase.CONTACT_GROUPS:
				for n in tree.get_nodes_in_group(group):
					if n is Node2D:
						_contact_targets.append(n)
	return _contact_targets


func cull_bullet_contacts() -> void:
	for n in _tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if bullet_contact_target(b) != null:
			b.despawn()


func bullet_contact_target(b: BulletBase) -> Node2D:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for n in contact_targets_now():
		if n == b.shooter or not (n is Node2D):
			continue
		if not _hits_entity.call(b, n as Node2D):
			continue
		if not HitShape.hurtable(n):
			continue
		if HitShape.segment_hits_rect(b.prev_pos, b.global_position,
				bullet_hurt_rect(n as Node2D), w, h, b.hit_grow()) >= 0.0:
			return n as Node2D
	return null


func bullet_hurt_rect(n: Node2D) -> Rect2:
	if n.has_method("hurt_rect_rendered"):
		return n.hurt_rect_rendered()
	if n.has_method("hurt_rect"):
		return n.hurt_rect()
	return HitShape.hurt_rect_of(n)


func bullet_hits_entity(_b: BulletBase, _ent: Node2D) -> bool:
	return true
