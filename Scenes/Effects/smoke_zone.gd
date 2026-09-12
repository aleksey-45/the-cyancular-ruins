class_name SmokeZone
extends Node2D

# 烟雾区(道具:烟雾弹):一团灰白软圆云,存续 duration 秒后淡出自毁。
# 纯程序化视觉(Explosion.make_circle_texture 软圆,与原作占位爆炸同源),零外部素材。
# 显隐规则在 Globals/smoke.gd(本节点只负责"看起来是烟"与登记 smoke_zone 组)。

var radius := 220.0
var duration := 6.0

var _puffs: Array = []
var _age := 0.0
var _base_alpha := 0.78


func _ready() -> void:
	add_to_group("smoke_zone")
	z_index = 60   # 盖在角色/子弹上;半透明,墙与地图仍可透见
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(int(position.x)) + "_" + str(int(position.y)))
	for i in 14:
		var s := Sprite2D.new()
		s.texture = Explosion.make_circle_texture(96)
		var ang := rng.randf() * TAU
		var dist := rng.randf() * radius * 0.72
		s.position = Vector2.from_angle(ang) * dist
		s.scale = Vector2.ONE * (radius * rng.randf_range(0.55, 0.95) / 96.0)
		s.rotation = rng.randf() * TAU
		var c := Color(0.80, 0.82, 0.85, 0.0)
		if i % 3 == 0:
			c = Color(0.70, 0.73, 0.78, 0.0)   # 深浅两阶,贴近原作灰蓝影调
		s.modulate = c
		add_child(s)
		_puffs.append(s)


func _process(delta: float) -> void:
	_age += delta
	rotation += delta * 0.06   # 整团缓慢旋绕
	# 淡入(0.25s)→ 存续 → 末尾 0.8s 淡出
	var a := _base_alpha
	if _age < 0.25:
		a = _base_alpha * (_age / 0.25)
	var remain := duration - _age
	if remain < 0.8:
		a *= maxf(remain / 0.8, 0.0)
	for s in _puffs:
		(s as Sprite2D).modulate.a = a
	if _age >= duration:
		queue_free()
