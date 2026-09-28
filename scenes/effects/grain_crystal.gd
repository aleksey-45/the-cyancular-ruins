class_name GrainCrystalFx
extends Node2D

# 乌鸫精英击杀结晶(第一阶段):身体碎裂 → 结晶炸开散落 → 飞向怀表 → 被吸收。
# 世界空间节点(挂 WorldViewport 侧),但目标点每帧按**相机会算**到屏幕上的怀表中心
# ——怀表是 HUD 控件(屏幕空间),这样不需要跨 canvas 层搬节点。
# 吸收完成:入账(Level0.grain_account.deposit)+ 怀表颤抖(WatchHud.tremble)。

const SHARD_COUNT := 10
const SCATTER_TIME := 0.28          # 炸开+散落阶段时长(秒)
# 阶段二改成**指数收敛**(v = 到目标的位移 × ARRIVE_RATE,再限速):任意距离都在 ~0.3s 内到位,
# 且近目标时每帧步长只有几像素 —— 既不会绕着目标转圈,也不会一帧跨过去(隧穿)。
# 上一版是"纯加速度 + 阻尼",实测在真实世界里 1.9s 都到不了(只能靠兜底入账,碎片会半路消失)。
const ARRIVE_RATE := 16.0           # 收敛速率(1/s):时间常数 ≈ 1/16 ≈ 0.06s
const MAX_FLY_SPEED := 4200.0       # 限速(px/s):跨一整屏 ~0.46s;远距击杀也大概率赶在兜底线前到
const ABSORB_RADIUS := 16.0         # 吸收半径(按线段判近,见 _segment_hits)
const ABSORB_TIMEOUT := 1.6         # 阶段二超时即强制吸收(颗粒是数值承诺,不许因特效丢掉)
const ABSORB_TAIL := 0.8            # 吸收后再留一点尾巴让其余碎片飞完,然后自毁
const SHARD_COLOR := Color8(18, 18, 22)        # 黑结晶(用户指定;衬亮背景更醒目)
const CORE_COLOR := Color8(70, 70, 78)         # 黑结晶上的冷灰亮芯(保留体积感)

static var last_absorb_kind: String = ""   # 诊断:"fly"=真飞到怀表 | "timeout"=兜底路径(不应成为常态)
static var last_absorb_t: float = 0.0      # 诊断:吸收发生在阶段二开始后多久(秒)

var amount: int = TimeParams.ELITE_GRAIN_DROP
var _shards: Array = []             # [{p, v, size}]
var _t := 0.0
var _absorbed := false


static func spawn(host: Node, world_pos: Vector2, amount_: int) -> void:
	if host == null or not is_instance_valid(host):
		return
	var fx := GrainCrystalFx.new()
	fx.amount = amount_
	fx.global_position = world_pos
	fx.add_to_group("grain_crystal")
	for i in SHARD_COUNT:
		var ang := TAU * float(i) / float(SHARD_COUNT) + randf_range(-0.25, 0.25)
		fx._shards.append({
			"p": Vector2.ZERO,
			"v": Vector2.from_angle(ang) * randf_range(260.0, 720.0),
			"size": randf_range(4.0, 7.5),
		})
	host.add_child(fx)


func _process(delta: float) -> void:
	_t += delta
	if _t < SCATTER_TIME:
		# 阶段一:炸开散落(强阻尼,像碎片四散)
		for s in _shards:
			s["v"] = (s["v"] as Vector2) * exp(-4.5 * delta)
			s["p"] = (s["p"] as Vector2) + (s["v"] as Vector2) * delta
	else:
		# 阶段二:全体飞向怀表。三条纪律,缺一条都会"看着飞到了、颗粒没入账":
		#  ① **指数收敛而不是纯加速** —— 纯加速追踪会绕着目标来回冲(过冲后速度越来越大),
		#  ② **按线段判近** —— 高速下一帧能跨过目标几十像素,只判"当前点是否在半径内"会**穿过去**
		#     (FLY_ACCEL 提到 5200 之后实测就是这样:FX 一直飞、_absorbed 永远 false、余额零变化);
		#  ③ **兜底入账** —— 颗粒是**数值承诺**,特效再怎么飞丢也必须入账。超时即吸收。
		var target := _watch_world_target()
		var all_done := true
		for s in _shards:
			var prev: Vector2 = global_position + (s["p"] as Vector2)
			var to: Vector2 = target - prev
			var v: Vector2 = to * ARRIVE_RATE
			if v.length() > MAX_FLY_SPEED:
				v = v.normalized() * MAX_FLY_SPEED
			s["v"] = v
			var now: Vector2 = prev + v * delta
			s["p"] = now - global_position
			if (s["p"] as Vector2).length() > 8.0:
				all_done = false
			if not _absorbed and _segment_hits(prev, now, target, ABSORB_RADIUS):
				last_absorb_kind = "fly"
				_absorb()
		if all_done or _t >= SCATTER_TIME + ABSORB_TIMEOUT \
				or (_absorbed and _t >= SCATTER_TIME + ABSORB_TAIL):
			if not _absorbed:
				last_absorb_kind = "fly" if all_done else "timeout"
				_absorb()   # 兜底:特效没飞到也入账(上面那条"绝不丢颗粒")
			queue_free()
	queue_redraw()


## 线段 a→b 上离 p 最近的点是否落在 r 内(防"一帧跨过目标"的隧穿)。
static func _segment_hits(a: Vector2, b: Vector2, p: Vector2, r: float) -> bool:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.0001:
		return a.distance_to(p) <= r
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return (a + ab * t).distance_to(p) <= r


## 怀表中心的世界坐标:取 WatchHud 的屏幕矩形中心,经相机逆换算(表心随镜头移动也准)。
func _watch_world_target() -> Vector2:
	var tree := get_tree()
	if tree == null:
		return global_position
	var watch: Control = tree.get_first_node_in_group("watch_hud") as Control
	var cam := get_viewport().get_camera_2d()
	if watch == null or cam == null:
		return global_position
	var screen_center: Vector2 = watch.get_global_rect().get_center()
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	return cam.get_screen_center_position() + (screen_center - vp_size * 0.5) / cam.zoom


func _absorb() -> void:
	if _absorbed:
		return
	_absorbed = true
	last_absorb_t = _t
	if Level0.grain_account != null:
		Level0.grain_account.deposit(amount)
	var tree := get_tree()
	if tree != null:
		var watch = tree.get_first_node_in_group("watch_hud")
		if watch != null and watch.has_method("tremble"):
			watch.tremble()


func _draw() -> void:
	for s in _shards:
		var p: Vector2 = s["p"]
		var sz: float = s["size"]
		# 小菱形结晶(像素风):冷青白 + 亮芯
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(0, -sz * 2.0), p + Vector2(sz, 0), p + Vector2(0, sz * 2.0), p + Vector2(-sz, 0),
		]), SHARD_COLOR)
		draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), CORE_COLOR)
