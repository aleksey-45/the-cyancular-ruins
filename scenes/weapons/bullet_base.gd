class_name BulletBase
extends CharacterBody2D

const BOUNCE_DAMPING: float = 0.6
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const HitShape := preload("res://core/sim/hit_shape.gd")
const HitFeedbackFx := preload("res://scenes/effects/hit_feedback_fx.gd")

const CONTACT_GROUPS: Array[String] = ["player", "player_replica"]

# ★ 像素契约:根节点 scale 仍 = size(只服务碰撞/弹道),子弹视觉由 Sprite2D 局部缩放补到 1 美术像素 = ART_WORLD_PX 世界像素。
const ART_WORLD_PX: float = 1.0

var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 1.0
var gravity_factor: float = 0.0
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE
var max_range: float = 0.0
var traveled: float = 0.0
# 上一物理帧开始时的位置:扫掠判定线段的起点。★ 服务器裁决与客户端 cull 都读它 ⇒ 本帧位移必须与上一帧首尾相接;
# 环面 wrap 后本字段与 global_position 同处一个副本空间(见 _physics_process 末尾)。
var prev_pos: Vector2 = Vector2.ZERO
var source: Node = null
var shooter: Node = null
var hit_damage: int = 0
var hit_impact: float = 0.0
var apply_damage: bool = true

@export var explodes: bool = false
@export var direct_hit_damage: int = 10
@export var fuse_time: float = 0.5
@export var hit_fuse_time: float = 0.1
@export var explosion_radius: float = 128.0
@export var explosion_damage: int = 35
@export var explosion_knockback: float = 900.0
@export var explosion_visual: PackedScene = null
@export var tile_break_unit: float = 1.0

var _fuse_active: bool = false
var _fuse_elapsed: float = 0.0
var _fuse_duration: float = 0.0
# 判定点整体后移帧数:爆炸当帧只播火光/碎片/震屏,再过 EXPLOSION_SETTLE_FRAMES 个物理帧才做一次 apply_aoe。
# 子弹在窗口里保持存活但不可见、不移动;期间被清掉则放弃这次结算。
const EXPLOSION_SETTLE_FRAMES := 3
var _settle_frames: int = 0

var _pool = null
var _scene_defaults: Dictionary = {}
var _use_token: int = 0

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	rotation = velocity_vec.angle()
	scale = Vector2(size, size)
	_apply_pixel_scale()


func _apply_pixel_scale() -> void:
	if size <= 0.0001:
		return
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.scale = Vector2.ONE * (ART_WORLD_PX / size)

func _ready() -> void:
	prev_pos = global_position
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color
	add_to_group("bullet")
	if Settings.pvp_show_trajectories:
		_ensure_trail()


static func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


func _ensure_trail() -> void:
	var t := _trail_child()
	if t == null:
		BulletTrail.attach(self, bullet_color)
		return
	t.clear_points()
	t.default_color = Color(bullet_color.r, bullet_color.g, bullet_color.b, 0.55)
	t.add_point(global_position)


func _trail_child() -> Line2D:
	for c in get_children():
		var t := c as BulletTrail
		if t != null:
			return t
	return null


func despawn() -> void:
	if _pool != null:
		_pool.call("release", self)
		return
	queue_free()


func set_pool(p) -> void:
	_pool = p


func remember_scene_defaults() -> void:
	if not _scene_defaults.is_empty():
		return
	_scene_defaults = {
		"explodes": explodes, "direct_hit_damage": direct_hit_damage,
		"fuse_time": fuse_time, "hit_fuse_time": hit_fuse_time,
		"explosion_radius": explosion_radius, "explosion_damage": explosion_damage,
		"explosion_knockback": explosion_knockback, "explosion_visual": explosion_visual,
		"tile_break_unit": tile_break_unit,
	}


func reset_for_pool() -> void:
	global_position = Vector2.ZERO
	prev_pos = Vector2.ZERO
	velocity_vec = Vector2.ZERO
	speed = 0.0
	traveled = 0.0
	max_range = 0.0
	size = 1.0
	scale = Vector2.ONE
	rotation = 0.0
	gravity_factor = 0.0
	breaks_terrain = false
	has_aoe = false
	bullet_color = Color.WHITE
	source = null
	shooter = null
	hit_damage = 0
	hit_impact = 0.0
	apply_damage = true
	explodes = bool(_scene_defaults.get("explodes", false))
	direct_hit_damage = int(_scene_defaults.get("direct_hit_damage", 10))
	fuse_time = float(_scene_defaults.get("fuse_time", 0.5))
	hit_fuse_time = float(_scene_defaults.get("hit_fuse_time", 0.1))
	explosion_radius = float(_scene_defaults.get("explosion_radius", 128.0))
	explosion_damage = int(_scene_defaults.get("explosion_damage", 35))
	explosion_knockback = float(_scene_defaults.get("explosion_knockback", 900.0))
	explosion_visual = _scene_defaults.get("explosion_visual", null)
	tile_break_unit = float(_scene_defaults.get("tile_break_unit", 1.0))
	_fuse_active = false
	_fuse_elapsed = 0.0
	_fuse_duration = 0.0
	_settle_frames = 0
	_use_token += 1
	set_physics_process(true)
	visible = true
	modulate = Color.WHITE
	for k in get_meta_list():
		remove_meta(k)
	if not _headless():
		var sp := get_node_or_null("Sprite2D") as Sprite2D
		if sp != null:
			sp.modulate = bullet_color
			sp.scale = Vector2.ONE


func _despawn_after(sec: float) -> void:
	var token := _use_token
	get_tree().create_timer(sec).timeout.connect(func() -> void:
		if is_instance_valid(self) and token == _use_token:
			despawn()
	)

func _physics_process(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	if _settle_frames > 0:
		_settle_frames -= 1
		if _settle_frames == 0:
			_settle_explosion()
		return
	prev_pos = global_position
	if gravity_factor > 0.0:
		velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
	# 爆炸弹的「碰到玩家 → 短引信」:两端同源(权威结算在 CombatSystem._adjudicate_grenade),这里只管引信时机;引信一旦启动就不再改时长。
	if explodes and not _fuse_active:
		_check_player_contact()
	if explodes and _fuse_active:
		_fuse_elapsed += delta
		if _fuse_elapsed >= _fuse_duration:
			_explode()
			if _settle_frames == 0:
				despawn()
			return
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var from := global_position
	var col := move_and_collide(step)
	var to := global_position
	var t_wall := 1.0
	if col != null:
		to = from + col.get_travel()
		var lens := step.length()
		t_wall = (col.get_travel().length() / lens) if lens > 0.0 else 0.0
	var hurt := first_hurt_on_segment(from, to, ["enemies"])
	if not hurt.is_empty() and float(hurt["t"]) <= t_wall:
		_on_hurt_target(from, to, hurt)
		return
	if col != null:
		_on_terrain_collision(col)
		return
	if traveled >= max_range:
		if explodes:
			_explode()
		if _settle_frames == 0:
			despawn()
		return
	_wrap()
	prev_pos = from + (global_position - to)


func first_hurt_on_segment(from: Vector2, to: Vector2, groups: Array, exclude: Node = null) -> Dictionary:
	var best: Dictionary = {}
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	var grow := hit_grow()
	for group in groups:
		for n in get_tree().get_nodes_in_group(group):
			if n == exclude or not (n is Node2D) or not HitShape.hurtable(n):
				continue
			var t := HitShape.segment_hits_rect(from, to, hurt_rect_for(n as Node2D), w, h, grow)
			if t >= 0.0 and (best.is_empty() or t < float(best["t"])):
				best = {"node": n, "t": t}
	return best


func hit_grow() -> Vector2:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or cs.shape == null or not (cs.shape is RectangleShape2D):
		return Vector2.ZERO
	var half: Vector2 = (cs.shape as RectangleShape2D).size * (0.5 * size)
	var ang := velocity_vec.angle() if not velocity_vec.is_zero_approx() else rotation
	var c := absf(cos(ang))
	var s := absf(sin(ang))
	return Vector2(half.x * c + half.y * s, half.x * s + half.y * c)


func hurt_rect_for(n: Node2D) -> Rect2:
	if n == null:
		return Rect2()
	if n.has_method("hurt_rect_rendered"):
		return n.hurt_rect_rendered()
	if n.has_method("hurt_rect"):
		return n.hurt_rect()
	return HitShape.hurt_rect_of(n)


func _on_hurt_target(from: Vector2, to: Vector2, hit: Dictionary) -> void:
	var target: Node = hit["node"]
	global_position = from + (to - from) * float(hit["t"])
	if explodes:
		_direct_hit(target)
		_start_fuse(hit_fuse_time)
		var normal := from - hurt_rect_for(target as Node2D).get_center()
		if normal.is_zero_approx():
			normal = -velocity_vec
		velocity_vec = velocity_vec.bounce(normal.normalized()) * BOUNCE_DAMPING
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
		return
	if apply_damage and is_instance_valid(source) and source.has_method("apply_hit"):
		_spawn_hit_fx(target)
		source.apply_hit(target, velocity_vec, hit_damage)
		Sfx.play("hit")
	elif apply_damage and target.has_method("hurt"):
		_spawn_hit_fx(target)
		target.hurt(hit_damage, velocity_vec, hit_impact)
		Sfx.play("hit")
	despawn()


func _spawn_hit_fx(target: Node) -> void:
	CombatFeedback.hit_marker()
	if CombatFeedback.current == null or not (target is Node2D):
		return
	HitFeedbackFx.spawn_damage(get_viewport(), _fx_pos((target as Node2D).global_position), hit_damage)


func _on_terrain_collision(col: KinematicCollision2D) -> void:
	if explodes:
		_start_fuse(fuse_time)
		var normal := col.get_normal()
		var reflected := velocity_vec.bounce(normal)
		velocity_vec = reflected * BOUNCE_DAMPING
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
		return
	_damage_tile_at(col.get_position(), col.get_normal())
	set_physics_process(false)
	velocity_vec = Vector2.ZERO
	_despawn_after(0.05)

func _apply_water_drag(delta: float) -> void:
	var factor := Water.bullet_drag_factor(Water.is_in_water(global_position), GameParameters.water_bullet_drag, delta)
	if factor < 1.0:
		velocity_vec *= factor


func _wrap() -> void:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	if _tile_break_is_cell() or MazeGenerator.current_subgrid.is_empty():
		var cell := _tile_cell_at(pos, normal)
		var tex := _cell_texture(cell)
		if tex == 0 or not TileDefs.bullet_destroyable(tex):
			return
		_spawn_tile_hit(pos, tex)
		if apply_damage:
			TileDefs.damage_tile(cell, hit_damage, "bullet")
		return
	var cols: int = MazeGenerator.current_subgrid[0].size()
	var rows: int = MazeGenerator.current_subgrid.size()
	var probes := [pos, pos - normal * 8.0, pos - normal * 16.0]
	for p in probes:
		var sub := Vector2i(posmod(int(p.x) / 16, cols), posmod(int(p.y) / 16, rows))
		var tex: int = MazeGenerator.current_subgrid[sub.y][sub.x]
		if tex != 0 and TileDefs.bullet_destroyable(tex):
			_spawn_tile_hit(pos, tex)
			if apply_damage:
				if tile_break_unit >= 0.5:
					TileDefs.damage_block32(Vector2i(sub.x / 2, sub.y / 2), hit_damage, "bullet", shooter)
				else:
					TileDefs.damage_sub(sub, hit_damage, "bullet", shooter)
			return


func _tile_break_is_cell() -> bool:
	return tile_break_unit >= 1.0


func _tile_cell_at(pos: Vector2, normal: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	var ts: int = GameParameters.TILE_SIZE
	return MazeGenerator.cell_of(pos - normal * (ts * 0.5), ts, grid[0].size(), grid.size())


func _cell_texture(cell: Vector2i) -> int:
	var grid := MazeGenerator.current_grid
	if cell.y < 0 or cell.y >= grid.size() or cell.x < 0 or cell.x >= grid[cell.y].size():
		return 0
	return MazeGenerator.texture_of(int(grid[cell.y][cell.x]))


func _spawn_tile_hit(pos: Vector2, tex: int) -> void:
	var at := _fx_pos(pos)
	TileHitFx.spawn(get_viewport(), at, tex)
	TileHitFx.mark_hit(at)


func _direct_hit(hit: Node) -> void:
	if not apply_damage:
		return
	if hit.has_method("hurt"):
		var dir := velocity_vec.normalized() if not velocity_vec.is_zero_approx() else Vector2.RIGHT
		CombatFeedback.hit_marker()
		hit.hurt(direct_hit_damage, dir)



# 爆炸弹「碰到玩家」判定(引信时机的单一来源):候选 = CONTACT_GROUPS 里的玩家实体与对手副本,排除 shooter(否则自己的榴弹一出膛就在自己身上起短引信)。
# ★ 判据 = 爆弹点是否落在目标受击面内(与子弹/激光同一套 hurt_rect);命中只起短引信、不改轨迹,直接伤由 CombatSystem._adjudicate_grenade 结算。
func _check_player_contact() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for group in CONTACT_GROUPS:
		for n in tree.get_nodes_in_group(group):
			if n == shooter or not (n is Node2D) or not HitShape.hurtable(n):
				continue
			var rect := hurt_rect_for(n as Node2D)
			if HitShape.distance_px_to_rect_at(global_position, rect, global_position, w, h) <= 0.0:
				start_player_fuse()
				return

func start_player_fuse() -> void:
	if explodes:
		_start_fuse(hit_fuse_time)

# ── 时间回溯:引信/射程状态的读写口(WorldRewind 快照用)──
# ★ 引信是这颗弹还剩多久炸的全部状态,必须进快照:否则重建出来的榴弹退回未点燃 —— 会在错误时刻爆炸,且与玩家重叠时走 0.1s 触碰引信贴脸起爆;traveled 同理,射程累计清零会让子弹飞过头。
func rewind_state() -> Dictionary:
	return {
		"fa": _fuse_active,
		"fe": _fuse_elapsed,
		"fd": _fuse_duration,
		"tr": traveled,
		"mr": max_range,
		"gf": gravity_factor,
		"sp": speed,
		"sz": size,
		"col": bullet_color,
	}


func apply_rewind_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	_fuse_active = bool(d.get("fa", false))
	_fuse_elapsed = float(d.get("fe", 0.0))
	_fuse_duration = float(d.get("fd", 0.0))
	traveled = float(d.get("tr", 0.0))
	max_range = float(d.get("mr", max_range))
	gravity_factor = float(d.get("gf", gravity_factor))
	speed = float(d.get("sp", speed))
	size = float(d.get("sz", size))
	scale = Vector2(size, size)
	bullet_color = d.get("col", bullet_color)
	var sp2 := get_node_or_null("Sprite2D") as Sprite2D
	if sp2 != null:
		sp2.modulate = bullet_color


func _start_fuse(duration: float) -> void:
	if not _fuse_active:
		_fuse_duration = duration
	_fuse_active = true

func _explode() -> void:
	# 判定点后移:权威/单机路径先只排结算,火光/碎片/震屏照旧当帧播;
	# 子弹本体隐藏并留在树上数 EXPLOSION_SETTLE_FRAMES 个物理帧(_settle_explosion 结算后销毁)。视觉副本没有结算 ⇒ 照旧当帧销毁。
	if apply_damage:
		_settle_frames = EXPLOSION_SETTLE_FRAMES
		visible = false
	if apply_damage:
		var sink := get_tree().get_first_node_in_group("authority_explosion_sink")
		if sink != null and sink.has_method("on_authority_explosion"):
			sink.on_authority_explosion(global_position, shooter, explosion_visual)
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	for e in Explosion.destructible_units(global_position, explosion_radius, tile_break_unit):
		var at := _fx_pos(e["pos"])
		TileHitFx.spawn(get_viewport(), at, int(e["tex"]))
		TileHitFx.mark_hit(at)
	if not apply_damage:
		Explosion.client_cam_shake(global_position, explosion_radius)


func _settle_explosion() -> void:
	var s: Node = shooter if is_instance_valid(shooter) else null
	Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback, s, tile_break_unit)
	despawn()


func _fx_anchor() -> Node2D:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	return p


func _fx_pos(at: Vector2) -> Vector2:
	var p := _fx_anchor()
	if p == null:
		return at
	return MazeGenerator.anchor_to_nearest(at, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)