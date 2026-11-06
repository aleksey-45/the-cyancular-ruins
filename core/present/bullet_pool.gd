class_name BulletPool
extends RefCounted


const MAX_PER_SCENE := 64

static var _shared: BulletPool = null

var _idle: Dictionary = {}
var _scenes: Dictionary = {}
var _released_frame: Dictionary = {}


static func shared() -> BulletPool:
	if _shared == null:
		_shared = BulletPool.new()
	return _shared


func acquire(scene_path: String) -> BulletBase:
	var b := _pop_idle(scene_path)
	if b == null:
		b = _instantiate(scene_path)
		if b == null:
			return null
	b.remember_scene_defaults()
	b.reset_for_pool()
	b.set_meta("scene_path", scene_path)
	# ★ 引擎陷阱:_ready() 只在首次入树时跑一次,复用再 add_child 不会重跑。不 request_ready 的话
	#   prev_pos 停在上一次的值(首帧扫掠线段横穿全图 = 服务器误判命中)且拖尾点集/弹色不上新。
	b.request_ready()
	return b


func release(b: BulletBase) -> void:
	if b == null or not is_instance_valid(b):
		return
	var path := String(b.get_meta("scene_path", ""))
	var parent := b.get_parent()
	if parent != null:
		parent.remove_child(b)
	b.set_physics_process(false)
	var arr: Array = _idle.get(path, [])
	if not _idle.has(path):
		_idle[path] = arr
	if arr.has(b):
		return
	_released_frame[b.get_instance_id()] = Engine.get_physics_frames()
	if arr.size() >= MAX_PER_SCENE:
		_released_frame.erase(b.get_instance_id())
		b.queue_free()
		return
	arr.append(b)


func idle_count(scene_path: String) -> int:
	var n := 0
	for b in _idle.get(scene_path, []):
		if is_instance_valid(b):
			n += 1
	return n


func _pop_idle(scene_path: String) -> BulletBase:
	var arr: Array = _idle.get(scene_path, [])
	var frame := Engine.get_physics_frames()
	for i in range(arr.size() - 1, -1, -1):
		var b := arr[i] as BulletBase
		if not is_instance_valid(b):
			arr.remove_at(i)
			continue
		if int(_released_frame.get(b.get_instance_id(), -1)) == frame:
			continue
		arr.remove_at(i)
		_released_frame.erase(b.get_instance_id())
		return b
	return null


func _instantiate(scene_path: String) -> BulletBase:
	if scene_path.is_empty():
		return null
	var scene: PackedScene = _scenes.get(scene_path)
	if scene == null:
		scene = load(scene_path) as PackedScene
		if scene == null:
			return null
		_scenes[scene_path] = scene
	var node := scene.instantiate()
	var b := node as BulletBase
	if b == null:
		node.queue_free()
		return null
	b.set_pool(self)
	return b
