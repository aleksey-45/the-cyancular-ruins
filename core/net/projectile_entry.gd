class_name ProjectileEntry
extends RefCounted

# 一次预测/权威弹丸的生命周期记录。场景节点仍归场景所有，这里只保存热路径状态。

var origin_tick := 0
var birth_tick := 0
var tick := 0
var sim_tick := 0
var moved_tick := -1
var retired_tick := -1
var confirmed := false
var active := false
var origin_state: Dictionary = {}
var checkpoints: Dictionary = {}
var _bullet_id := 0

var bullet: BulletBody:
	get:
		return get_bullet()
	set(value):
		set_bullet(value)

func set_bullet(value: BulletBody) -> void:
	_bullet_id = value.get_instance_id() if value != null else 0

func get_bullet() -> BulletBody:
	return null if _bullet_id == 0 else instance_from_id(_bullet_id) as BulletBody

func initialize(body: BulletBody, initial: Dictionary, at: int, known: bool) -> void:
	set_bullet(body)
	origin_state = initial.duplicate(true)
	checkpoints = {}
	origin_tick = at
	birth_tick = at + 1
	tick = at
	sim_tick = at
	moved_tick = -1
	retired_tick = -1
	confirmed = known
	active = not known
	if known:
		checkpoints[at] = initial.duplicate(true)

func restore_at(initial: Dictionary, at: int) -> void:
	var body := get_bullet()
	if body != null:
		body.restore_motion(initial)
	tick = at
	sim_tick = at
	moved_tick = -1
	active = true
	retired_tick = -1
