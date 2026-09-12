class_name Smoke
extends RefCounted

# 烟雾区静态工具(无 autoload,-s 可测):
#  - spawn_zone:在 parent 下建一个 SmokeZone(视觉 + 记录),存续后自毁
#  - inside / zones:位置是否处于任一烟雾区
#  - apply_visibility:烟雾可见性规则——
#      · 烟雾区内的实体:对所有观察者不可见(烟雾外和烟雾内都看不见烟雾内)
#      · 观察者自己在烟雾内:除自己外所有目标都不可见(烟雾内只能看见地图建筑和自己)

const ZONE_SCRIPT := "res://Scenes/Effects/smoke_zone.gd"


static func spawn_zone(parent: Node, pos: Vector2, radius: float, duration: float) -> void:
	if parent == null:
		return
	var script: GDScript = load(ZONE_SCRIPT)
	if script == null:
		return
	var zone: Node2D = (script as GDScript).new()
	zone.radius = radius
	zone.duration = duration
	zone.position = pos
	parent.add_child(zone)


static func zones() -> Array:
	var out: Array = []
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	for z in tree.get_nodes_in_group("smoke_zone"):
		if not is_instance_valid(z):
			continue
		out.append({"pos": (z as Node2D).global_position, "radius": float(z.get("radius"))})
	return out


static func inside(pos: Vector2) -> bool:
	for z in zones():
		if pos.distance_to(z["pos"]) <= float(z["radius"]):
			return true
	return false


## 每帧可见性:targets 里的节点按规则显隐(自己 viewer 永远可见)
static func apply_visibility(viewer: Node2D, targets: Array) -> void:
	var zs := zones()
	if zs.is_empty():
		return
	var blinded := viewer != null and is_instance_valid(viewer) and inside(viewer.global_position)
	for t in targets:
		if not (t is Node2D) or not is_instance_valid(t):
			continue
		var n := t as Node2D
		if n == viewer:
			continue
		var hide := blinded or inside(n.global_position)
		n.visible = not hide
