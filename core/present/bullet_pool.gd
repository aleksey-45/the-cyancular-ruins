class_name BulletPool
extends RefCounted

## 子弹对象池:按场景路径复用 [BulletBase],替掉"每发 instantiate + queue_free"。
## 按场景路径分池:@export 初值来自场景(榴弹覆盖 explodes / fuse / radius / unit),跨场景复用会把榴弹变成直弹;
## 初值由 BulletBase.remember_scene_defaults() 在首次借出时快照。上限 MAX_PER_SCENE/场景,超出即销毁 ——
## 它挡的是"一次性爆发把节点永久攒在池里",不是限制复用;拿不到闲置就 instantiate(与池化前逐字相同)。
## 池是进程级静态实例,闲置弹会活过换局;闲置实例离树且物理关 ⇒ 不进组查询、不被裁决、不渲染。

const MAX_PER_SCENE := 64

static var _shared: BulletPool = null

var _idle: Dictionary = {}     # 场景路径 -> Array[BulletBase](闲置,已离树)
var _scenes: Dictionary = {}   # 场景路径 -> PackedScene(缓存:每发都 load() 也是一笔开销)
var _released_frame: Dictionary = {}   # 实例 id -> 归还时的物理帧(本帧内不再借出,见 release)


## 进程级单例(不做成 autoload:池只服务表现层,不该进全局节点树,也不该逼 -s 冒烟去实例化 autoload)。
static func shared() -> BulletPool:
	if _shared == null:
		_shared = BulletPool.new()
	return _shared


## 取一颗可用子弹(闲置优先,否则实例化一颗)。返回值尚未进树,调用方负责 setup / 定位 / add_child。
func acquire(scene_path: String) -> BulletBase:
	var b := _pop_idle(scene_path)
	if b == null:
		b = _instantiate(scene_path)
		if b == null:
			return null
	b.remember_scene_defaults()
	b.reset_for_pool()
	b.set_meta("scene_path", scene_path)
	# ★ 引擎陷阱:_ready() 只在**首次**入树时跑一次,复用再 add_child 不会重跑。不 request_ready 的话
	#   prev_pos 停在上一次的值(首帧扫掠线段横穿全图 = 服务器误判命中)且拖尾点集/弹色不上新。
	b.request_ready()
	return b


## 归还:离树 + 关物理 + 入池。字段与表现复位统一在 acquire 侧(见 BulletBase.reset_for_pool)。
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
		return   # 双 release 幂等:同一实例不许在池里排两次,否则会被两个调用方同时拿到
	# 本帧归还的实例压一帧再借:服务器 MatchHost._adjudicate_bullets 用**节点实例 id** 判"这颗弹广播过没有"
	# (_seen_bullets),而它每帧在子节点步进之前扫一次 —— 同一帧内"这颗弹死了、下一发又借到同一个实例"
	# 会被判成同一颗、**不再广播**(客户端少看见一发,服务器不报错)。压一帧即可让旧 id 在下次扫描里被剪掉。
	_released_frame[b.get_instance_id()] = Engine.get_physics_frames()
	if arr.size() >= MAX_PER_SCENE:
		_released_frame.erase(b.get_instance_id())
		b.queue_free()
		return
	arr.append(b)


func idle_count(scene_path: String) -> int:   # 探针用:验证"归还后确实在池里"与上限
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
			arr.remove_at(i)   # 池外被 free 掉的陈旧条目直接清掉(不清就会把已释放的实例借出去)
			continue
		if int(_released_frame.get(b.get_instance_id(), -1)) == frame:
			continue   # 本帧刚归还:压一帧(理由见 release)
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
