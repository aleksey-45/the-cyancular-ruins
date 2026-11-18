class_name ServerBody
extends Node2D

# 自管 RID 物理体的公共生命周期：创建于 _init，空间挂接与层掩码提交于进树，
# 释放于节点析构。角色、弹丸、敌人与拾取物的物理表达统一由这里托管，
# 子类只补充各自的形状槽同步与运动策略。

@export var collision_layer := 0
@export var collision_mask := 0

var _rid := RID()
var _physics: CollisionWorld
var terrain: Terrain:
	get: return _physics.terrain if _physics != null else null

func _init() -> void:
	_rid = CollisionWorld.create_body(collision_layer, collision_mask)

func get_rid() -> RID:
	return _rid

# 层掩码写入物理体的唯一入口：进树前的赋值由 _enter_tree 统一提交，运行期改动必须显式调用。
func _apply_layers() -> void:
	if _rid.is_valid():
		PhysicsServer2D.body_set_collision_layer(_rid, collision_layer)
		PhysicsServer2D.body_set_collision_mask(_rid, collision_mask)

## 两轴推进并把结果位姿写回节点变换；速度/着地语义由调用方按返回值处理。
func axis_move(motion: Vector2) -> Dictionary:
	var out := CollisionWorld.move_body_axes(_rid, global_transform, motion)
	global_position = out["position"]
	return out

func _enter_tree() -> void:
	_physics = CollisionWorld.acquire(self)
	PhysicsServer2D.body_set_space(_rid, _physics.space)
	_apply_layers()
	PhysicsServer2D.body_attach_object_instance_id(_rid, get_instance_id())

func _exit_tree() -> void:
	# free() 的 PREDELETE 先于离树触发；体已被析构时不再有 detach 的义务。
	_physics = null
	if _rid.is_valid():
		PhysicsServer2D.body_set_space(_rid, RID())

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rid.is_valid():
		PhysicsServer2D.free_rid(_rid)
		_rid = RID()
