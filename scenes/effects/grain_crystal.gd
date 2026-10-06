class_name GrainCrystalFx
extends Node2D

# 精英乌鸫击杀掉落结晶特效：击杀碎裂 → 结晶碎片散开 → 飞向怀表 UI → 触发吸收。
# 本节点位于世界空间（挂载于 WorldViewport 树下），目标点每帧通过相机反投影计算屏幕上怀表的中心坐标。
# 吸收完成后：增加粒子余额（Level0.grain_account.deposit）并触发怀表微震（WatchHud.tremble）。

const SHARD_COUNT := 10
const SCATTER_TIME := 0.28          # 炸开与散落阶段持续时间（秒）
# 阶段二采用指数收敛算法（速度 v = 目标向量 × ARRIVE_RATE 并设置速度上限）：
# 保证在各种距离下平稳飞向目标，近目标时自动平滑减速，防止围绕目标振荡或高速穿透判定范围。
const ARRIVE_RATE := 16.0           # 收敛速率（1/s），时间常数 ≈ 0.06s
const MAX_FLY_SPEED := 4200.0       # 飞行最大速率限制（px/s）
const ABSORB_RADIUS := 16.0         # 吸收判定半径（基于线段连续检测）
const ABSORB_TIMEOUT := 1.6         # 阶段二超时兜底：若超时则强制触发吸收，确保数值绝对不丢失
const ABSORB_TAIL := 0.8            # 触发吸收后保留短暂残影时间，等待其余碎片全部飞抵后自毁
const SHARD_COLOR := Color8(18, 18, 22)        # 结晶主颜色（深黑像素风格）
const CORE_COLOR := Color8(70, 70, 78)         # 结晶内部冷灰高光

static var last_absorb_kind: String = ""   # 诊断标记："fly"=正常飞抵怀表 | "timeout"=超时兜底吸收
static var last_absorb_t: float = 0.0      # 诊断数据：记录从阶段二开始至完成吸收所用时间（秒）

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
		# 阶段一：碎片向四周炸开散落（带指数衰减阻尼）
		for s in _shards:
			s["v"] = (s["v"] as Vector2) * exp(-4.5 * delta)
			s["p"] = (s["p"] as Vector2) + (s["v"] as Vector2) * delta
	else:
		# 阶段二：所有碎片飞向怀表目标点。
		# 核心机制：
		#   1. 指数收敛：避免纯加速度模式产生过冲和环绕振荡；
		#   2. 线段连续碰撞检测：针对高速运动防止单帧位移过大穿透吸收半径；
		#   3. 超时保底机制：保证时间粒子最终必定成功结算，不因特效表现异常而丢失。
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
				_absorb()   # 超时保底结算，确保粒子正常增加
			queue_free()
	queue_redraw()


## 连续碰撞检测：检测线段 a→b 上距离点 p 最近的点是否在半径 r 内（防止高速运动穿透）。
static func _segment_hits(a: Vector2, b: Vector2, p: Vector2, r: float) -> bool:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 <= 0.0001:
		return a.distance_to(p) <= r
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return (a + ab * t).distance_to(p) <= r


## 计算怀表中心在当前世界坐标系下的位置：根据 WatchHud 屏幕矩形中心结合相机变换进行逆向计算。
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
