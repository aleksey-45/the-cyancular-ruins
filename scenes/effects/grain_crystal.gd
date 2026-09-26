class_name GrainCrystalFx
extends Node2D

# 乌鸫精英击杀结晶(第一阶段):身体碎裂 → 结晶炸开散落 → 飞向怀表 → 被吸收。
# 世界空间节点(挂 WorldViewport 侧),但目标点每帧按**相机会算**到屏幕上的怀表中心
# ——怀表是 HUD 控件(屏幕空间),这样不需要跨 canvas 层搬节点。
# 吸收完成:入账(Level0.grain_account.deposit)+ 怀表颤抖(WatchHud.tremble)。

const SHARD_COUNT := 10
const SCATTER_TIME := 0.28          # 炸开+散落阶段时长(秒)
const FLY_ACCEL := 5200.0           # 飞向怀表的加速度(提速,原先太慢)
const SHARD_COLOR := Color8(18, 18, 22)        # 黑结晶(用户指定;衬亮背景更醒目)
const CORE_COLOR := Color8(70, 70, 78)         # 黑结晶上的冷灰亮芯(保留体积感)

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
		# 阶段二:全体加速飞向怀表;先到者触发一次吸收
		var target := _watch_world_target()
		var all_done := true
		for s in _shards:
			var to: Vector2 = target - (global_position + (s["p"] as Vector2))
			s["v"] = (s["v"] as Vector2) + to.normalized() * FLY_ACCEL * delta
			s["p"] = (s["p"] as Vector2) + (s["v"] as Vector2) * delta
			if (s["p"] as Vector2).length() > 8.0:
				all_done = false
			if not _absorbed and (s["p"] as Vector2).length() < 16.0:
				_absorb()
		if all_done:
			queue_free()
	queue_redraw()


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
