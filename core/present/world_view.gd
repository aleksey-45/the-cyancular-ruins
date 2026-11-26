class_name WorldView
extends RefCounted

const WEAPONS := preload("res://assets/textures/weapons.png")
const BULLETS := preload("res://assets/textures/bullets.png")
const EXPLOSION := preload("res://assets/textures/effects.png")
const PLAYER_FRAMES := preload("res://scenes/player/player_frames.tres")
const PLAYER_SURFACE := preload("res://assets/textures/player_canvas_texture.tres")
const PLAYER_CLIPS := [&"idle", &"move", &"fly", &"charge", &"squat"]
const Activity := EnemyBase.Activity
const ENEMY_CLIPS := [&"sleeping", &"fall_asleep", &"wake_up", &"jump", &"dashing",
	&"take_off", &"flying", &"dashing", &"run", &"run", &"disappear", &"disappear", &"appear", &"jump_backward", &"dead"]
const PLAYER_GLOW := Color(0.30, 0.62, 1.0)
const ENEMY_GLOW := Color(1.0, 0.94, 0.86)
const ELITE_GLOW := Color(2.0, 1.64, 0.12)
const DASH_GHOST_INTERVAL := 0.03
const DASH_GHOST_LIFE := 0.20
const HASTE_GHOST_INTERVAL := 0.03
const REWIND_GHOST_INTERVAL := 0.06
const ENEMY_GHOST_INTERVAL := 0.06
const ENEMY_GHOST_LIFE := 0.16
const HURT_GHOST_LIFE := 0.18
const DEATH_GHOST_LIFE := 0.30
const TRAIL_LIFE := 0.26
# 单人时间加速残影交替使用红色和蓝色，初始不透明度为 55%。
const HASTE_GHOST_WARM := Color(1.0, 0.25, 0.25, 0.55)
const HASTE_GHOST_COOL := Color(0.3, 0.4, 1.0, 0.55)
const HURT_GHOST := Color(1.0, 0.4, 0.4, 0.5)
const DEATH_GHOST := Color(1.0, 1.0, 1.0, 0.5)
const ENEMY_GHOST := Color(ENEMY_GLOW, 0.18)
const EXPLOSION_FRAMES := [0.09, 0.18, 0.255, 0.33, 0.39, 0.45, 0.50, 0.55]
const DEBRIS := {"life": 0.4, "count": 10, "spread": TAU, "speed": Vector2(0, 120),
		"gravity": 900.0, "size": Vector2(4, 8)}
const SPLASH := {"life": 0.4, "count": 8, "spread": deg_to_rad(80), "speed": Vector2(60, 160),
		"gravity": 700.0, "size": Vector2(4, 10)}
const BUBBLES := {"life": 0.7, "count": 5, "spread": deg_to_rad(24), "speed": Vector2(40, 90),
		"gravity": -30.0, "size": Vector2(2, 4)}
# 血条的纵向偏移相对角色锚点，使其显示在名字上方。
const HP_BAR_CENTER := Vector2(0.0, -108.0)

enum Effect { BLAST, PARTICLES, NUMBER, GRAIN }

var _canvas: WorldCanvas
var _size: Vector2
var _squash := {}
var _after := AfterImageField.new()
var _ghost_after := {}
var _hit_prev := {}
var _downed_prev := {}
var _alternate := false
var _poses := {}
var _fire := {}
var _paths := {}
var _next_paths := {}
var _effects := [[], [], [], []]
var _hits := {}
# 按需创建拾取提示和敌人血条，后续帧复用已创建的节点。
var _pickup_nodes: Array[PickupPrompt] = []
var _reload_node: ReloadRing
var _hp_nodes: Array[EnemyHpBar] = []

func bind(canvas: WorldCanvas, size: Vector2) -> void:
	_canvas = canvas
	_size = size

func reset() -> void:
	for buffer in [_poses, _fire, _paths, _next_paths, _hits] + _effects:
		buffer.clear()
	_squash.clear()
	_after.clear()
	_ghost_after.clear()
	_hit_prev.clear()
	_downed_prev.clear()
	_alternate = false
	# 重开时也重置世界内提示，避免上一局的提示残留。
	for node in _pickup_nodes:
		if is_instance_valid(node):
			node.hide()
	if is_instance_valid(_reload_node):
		_reload_node.hide()
	for node in _hp_nodes:
		if is_instance_valid(node):
			node.hide()

func clear_motion(id: int) -> void:
	_squash.erase(id)
	_ghost_after.erase(id)

func motion(id: int, kind: StringName, now: float, speed := 0.0) -> void:
	_squash_for(id).impulse(kind, now, speed)

func _squash_for(id: int) -> SquashTracker:
	var squash: SquashTracker = _squash.get(id)
	if squash == null:
		squash = SquashTracker.new(id < 0)
		_squash[id] = squash
	return squash

func fire(id: int, weapon: int, now: float) -> void:
	_fire[id] = [weapon, now]

func blast(at: Vector2, now: float) -> void:
	_effects[Effect.BLAST].append([at, now])

func debris(at: Vector2, texture: int, now: float) -> void:
	var color := Color(0.6, 0.6, 0.6)
	if texture >= 15 and texture <= 18:
		color = Color(0.413, 0.701, 0.57)
	elif texture == 19 or texture == 20:
		color = Color(0.301, 0.398, 0.43)
	_effects[Effect.PARTICLES].append([at, now, DEBRIS, color])

func splash(at: Vector2, surface: bool, now: float) -> void:
	_effects[Effect.PARTICLES].append([at, now, SPLASH if surface else BUBBLES,
			Color(0.75, 0.88, 1.0, 0.9 if surface else 0.6)])

func hit(id: int, at: Vector2, damage: int, own: bool) -> void:
	if damage > 0:
		var row: Array = _hits.get_or_add(id, [at, 0, own])
		row[1] += damage

func grain(at: Vector2, now: float, flight: float) -> void:
	_effects[Effect.GRAIN].append([at, now, flight])

func present(frame: MatchFrame, grain_target := Vector2.ZERO) -> void:
	_canvas.set_daylight(frame.day_minute)
	_canvas.begin(frame.actors.size())
	_after.present(frame.now, frame.focus, _canvas, _size)
	# 上一帧的换弹环先隐藏，由当前帧的换弹状态决定是否显示。
	if is_instance_valid(_reload_node):
		_reload_node.hide()
	var prompts := 0
	var bars := 0
	for i in frame.actors.size():
		var pose := frame.actors[i]
		_actor(pose, frame)
		if i == 0 and not frame.aim_guide.is_empty():
			var weapon := WeaponRegistry.definition(pose.weapon)
			_guide(frame.aim_guide, weapon.get("guide_color", Color(1, 0.2, 0.2, 0.6)),
					not weapon["projectile"]["blast"].is_empty(), pose.bow_draw < 0.0)
		if not pose.name.is_empty():
			_nameplate(pose.anchor, pose.name, pose.name_color(frame.mode))
			if pose.health >= 0.0:
				var bar := _hp_bar(bars)
				bar.position = pose.anchor + HP_BAR_CENTER
				bar.ratio = pose.health
				bar.show()
				bars += 1
	for row in frame.pickups:
		var weapon := WeaponRegistry.definition(row[0])
		var bounds: Rect2 = weapon["pickup_bounds"]
		var size := WeaponPickup.WORLD_SCALE
		var at: Vector2 = row[1]
		_canvas.sprite(WEAPONS, weapon["region"],
				Transform2D(0.0, Vector2.ONE * size, 0.0, at - bounds.get_center() * size))
		if row[2]:
			_show_pickup_prompt(prompts, at)
			prompts += 1
	for i in range(prompts, _pickup_nodes.size()):
		_pickup_nodes[i].hide()
	for i in range(bars, _hp_nodes.size()):
		_hp_nodes[i].hide()
	_next_paths.clear()
	for row in frame.projectiles:
		if frame.trajectories:
			_trajectory(row[0], row[2])
		_projectile_sprite(WeaponRegistry.projectile_definition(row[1]), row[2], row[3])
	var previous := _paths
	_paths = _next_paths
	_next_paths = previous
	_draw_effects(frame, grain_target)
	_canvas.submit()

func _actor(pose: MatchFrame.Pose, frame: MatchFrame) -> void:
	var now := frame.now
	var enemy := pose.frames != null
	var frames := pose.frames if enemy else PLAYER_FRAMES
	var clip := _enemy_clip(pose) if enemy else (&"idle" if pose.downed else PLAYER_CLIPS[pose.state]) as StringName
	var first_frame := pose.state == Activity.WAIT if enemy else pose.downed
	var clock: Array = _poses.get_or_add(pose.id, [clip, now])
	if clock[0] != clip:
		clock[0] = clip
		clock[1] = now
	var age := now - float(clock[1])
	var image := _frame(frames, clip, 0.0 if first_frame else age)
	var body := Transform2D(0.0, pose.scale, 0.0, pose.anchor)
	if not enemy and pose.downed:
		body *= Transform2D(-PI / 2.0 * pose.facing, Vector2(0, 6.8 - 2.0 * pose.facing))
	var visual := body
	# 挤压与拉伸只缩放精灵的局部坐标轴，武器挂点和瞄准沿用角色变换。
	var squash := _squash_for(pose.id)
	if pose.downed or (pose.rewind and not pose.elite):
		squash.reset()
	else:
		visual = visual.scaled_local(squash.sample(now, pose.air_speed))
	if pose.facing < 0:
		visual.x = -visual.x
	var tint := Color.WHITE
	var color := Color.WHITE
	var glow := Color.TRANSPARENT
	var pass_kind := WorldCanvas.Pass.NORMAL
	if enemy:
		if pose.hit_left > 0.0 or pose.state == Activity.TELEPORT:
			color = Color(3, 3, 3)
			if pose.black_bird:
				pass_kind = WorldCanvas.Pass.MASK
		if not pose.downed:
			if pose.elite and (pose.haste or pose.rewind):
				glow = ELITE_GLOW
			elif pose.haste and pose.anchor.distance_squared_to(frame.focus) < 1500.0 * 1500.0:
				glow = ENEMY_GLOW
	else:
		var skin_tint := Color.WHITE if frame.mode == MatchFrame.Mode.SOLO else pose.name_color(frame.mode) / UiFactory.C_TEAM_A
		if frame.mode == MatchFrame.Mode.DUEL or frame.mode == MatchFrame.Mode.TEAM:
			tint = skin_tint
		var hit_left := pose.hit_left
		var alpha := 0.4 if hit_left > 0.0 and int(hit_left * 20.0) % 2 == 0 else 1.0
		color = Color(skin_tint, alpha)
		pass_kind = WorldCanvas.Pass.PLAYER_BODY
		_canvas.eye_light(visual.translated_local(image.get_meta(&"eye_offset")))
		if pose.haste and not pose.rewind:
			glow = Color((ENEMY_GLOW if pose.remote else PLAYER_GLOW) * tint, alpha)
	_afterimages(pose, frame, image, visual, tint)
	_canvas.sprite(image.atlas if enemy else PLAYER_SURFACE, image.region, visual, color, pass_kind)
	if glow.a > 0.0:
		_canvas.sprite(image.atlas, image.region, visual, glow, WorldCanvas.Pass.GLOW)
	if pose.weapon == 0:
		return
	var weapon := WeaponRegistry.definition(pose.weapon)
	var offset: Vector2 = weapon["sprite_offset"]
	var fired: Array = _fire.get(pose.id, [])
	if not fired.is_empty() and fired[0] == pose.weapon:
		offset.x -= float(weapon.get("kick", 0.0)) * (1.0 - clampf((now - float(fired[1])) / 0.06, 0.0, 1.0))
	var tilt := 0.0
	var reload := 1.0 - pose.reload_left / float(weapon["reload"]) if pose.reload_left > 0.0 else -1.0
	if reload >= 0.0:
		var lift := sin(PI * reload)
		tilt = 0.9 * lift
		offset += Vector2(-3.0 + 1.2 * sin(34.0 * reload), 7.0) * lift
	var drawing := pose.bow_draw >= 0.0 and not pose.downed
	if clip == &"move" and not drawing:
		var cycle := age * frames.get_animation_speed(clip) / frames.get_frame_count(clip)
		offset.y += sin(TAU * cycle) * 1.4
	var aim := body * pose.aim
	_canvas.sprite(WEAPONS, weapon["region"], aim * Transform2D(tilt, offset), Color(Color.WHITE, color.a))
	if drawing:
		_draw_bow(weapon, aim, pose.bow_draw, now, color.a)
	if reload >= 0.0 and not pose.remote:
		_reload(pose.anchor, pose.facing, reload, pose.reload_left)

func _draw_bow(weapon: Dictionary, aim: Transform2D, charge: float, now: float, alpha: float) -> void:
	var center := aim * ShotRules.launch_offset(weapon, charge)
	var direction := aim.x.normalized()
	var region: Rect2 = weapon["projectile_region"]
	var tail := center - direction * (region.size.x * float(weapon["size"]) * 0.5 - 1.0)
	var pulse := 0.5 + 0.5 * sin(TAU * 6.0 * now) if charge == 1.0 else 0.0
	var string_color := Color(0.34, 0.59, 0.76, alpha).lerp(Color(0.58, 0.88, 1.0, alpha), pulse)
	_canvas.line(PackedVector2Array([aim * Vector2(3.5, -8.5), tail, aim * Vector2(3.5, 25.5)]), string_color, 2.0, true)
	_projectile_sprite(weapon, center, direction.angle(), Color(Color.WHITE * (1.45 + 0.85 * pulse), alpha))

func _projectile_sprite(spec: Dictionary, at: Vector2, rotation: float, color := Color.WHITE) -> void:
	_canvas.sprite(BULLETS, spec["projectile_region"],
			Transform2D(rotation, Vector2.ONE * float(spec["size"]), 0.0, at), color)

func _enemy_clip(pose: MatchFrame.Pose) -> StringName:
	if pose.black_bird and pose.state == Activity.REST:
		return &"sleep"
	if pose.state == Activity.LUNGE:
		var start := &"turn_dash"
		if pose.lunge_age < float(pose.frames.get_frame_count(start)) / pose.frames.get_animation_speed(start):
			return start
	return ENEMY_CLIPS[pose.state]

# 持续动作按各自的间隔生成残影。玩家进入受击状态或角色进入倒地状态时生成一次。
func _afterimages(pose: MatchFrame.Pose, frame: MatchFrame, image: AtlasTexture,
		visual: Transform2D, tint: Color) -> void:
	var now := frame.now
	var enemy := pose.frames != null
	var was_downed := bool(_downed_prev.get(pose.id, false))
	_downed_prev[pose.id] = pose.downed
	if pose.downed:
		if not was_downed:
			_after.spawn(now, image, visual, DEATH_GHOST,
					WorldCanvas.Pass.NORMAL, DEATH_GHOST_LIFE)
		return
	if not enemy:
		var hit_left := pose.hit_left
		var was_hit := bool(_hit_prev.get(pose.id, false))
		_hit_prev[pose.id] = hit_left > 0.0
		if hit_left > 0.0 and not was_hit:
			_after.spawn(now, image, visual, HURT_GHOST,
					WorldCanvas.Pass.NORMAL, HURT_GHOST_LIFE)
	var color := Color.WHITE
	var pass_kind := WorldCanvas.Pass.NORMAL
	var interval := 0.0
	var life := TRAIL_LIFE
	var alternate := false
	if enemy:
		if pose.state != Activity.TAKE_OFF and pose.state != Activity.CHARGE:
			return
		color = ENEMY_GHOST
		interval = ENEMY_GHOST_INTERVAL
		life = ENEMY_GHOST_LIFE
	else:
		var foreground := pose.rewind and pose.remote
		alternate = pose.haste and frame.mode == MatchFrame.Mode.SOLO
		if alternate:
			interval = HASTE_GHOST_INTERVAL
		elif pose.haste:
			color = UiFactory.C_TEAM_B
			interval = HASTE_GHOST_INTERVAL
		elif foreground:
			color = UiFactory.C_TEXT_DIM
			pass_kind = WorldCanvas.Pass.FOREGROUND
			interval = REWIND_GHOST_INTERVAL
		elif pose.state == Player.DASH:
			color = UiFactory.C_TEAM_A * tint
			interval = DASH_GHOST_INTERVAL
			life = DASH_GHOST_LIFE
		else:
			return
	if now < float(_ghost_after.get(pose.id, 0.0)):
		return
	# 仅在生成残影时切换红蓝颜色，避免固定采样间隔总选到同一种颜色。
	if alternate:
		color = HASTE_GHOST_WARM if _alternate else HASTE_GHOST_COOL
		_alternate = not _alternate
	_ghost_after[pose.id] = now + interval
	_after.spawn(now, image, visual, color, pass_kind, life)

func _trajectory(id: int, at: Vector2) -> void:
	var path: PackedVector2Array = _paths.get(id, PackedVector2Array())
	if not path.is_empty():
		var shift := ToroidalGrid.anchor_to_nearest(path[-1], at, _size) - path[-1]
		if shift != Vector2.ZERO:
			for i in path.size():
				path[i] += shift
	if path.size() == 16:
		path.remove_at(0)
	path.append(at)
	_next_paths[id] = path
	if path.size() > 1:
		_canvas.line(path, Color(1, 1, 1, 0.55), 2.5)

func _show_pickup_prompt(index: int, at: Vector2) -> void:
	var node := _pickup_prompt_node(index)
	node.position = at + Vector2(0.0, -PickupPrompt.GAP_ABOVE)
	node.show()


func _pickup_prompt_node(index: int) -> PickupPrompt:
	while _pickup_nodes.size() <= index:
		var node := PickupPrompt.new()
		node.name = "PickupPrompt%d" % _pickup_nodes.size()
		_hud_parent().add_child(node)
		_pickup_nodes.append(node)
	return _pickup_nodes[index]


# 提示跟随视口，沿用世界坐标，绘制在角色上方且不受昼夜环境色调制。
func _hud_parent() -> Node2D:
	return _canvas._overlay if _canvas._overlay != null else _canvas

func _draw_effects(frame: MatchFrame, grain_target: Vector2) -> void:
	var now := frame.now
	for hit_row: Array in _hits.values():
		_effects[Effect.NUMBER].append([hit_row[0], now, hit_row[1], hit_row[2]])
	_hits.clear()
	for beam: Array in frame.beams:
		var points: PackedVector2Array = beam[0]
		var alpha: float = beam[1]
		var offset := ToroidalGrid.anchor_to_nearest(points[0], frame.focus, _size) - points[0]
		points = Transform2D(0.0, offset) * points
		_canvas.line(points, Color(0.1, 0.35, 1.0, 0.30 * alpha), 10.0)
		_canvas.line(points, Color(1, 1, 1, 0.95 * alpha), 3.0)
		_canvas.circle(points[0], 13.0, Color(0.1, 0.35, 1.0, 0.18 * alpha))
		_canvas.circle(points[0], 5.0, Color(1, 1, 1, 0.65 * alpha))
	for kind in _effects.size():
		var rows: Array = _effects[kind]
		for i in range(rows.size() - 1, -1, -1):
			var row: Array = rows[i]
			var age := now - float(row[1])
			var at := ToroidalGrid.anchor_to_nearest(row[0], frame.focus, _size)
			match kind:
				Effect.BLAST:
					var index := EXPLOSION_FRAMES.bsearch(age)
					if index == EXPLOSION_FRAMES.size():
						rows.remove_at(i)
						continue
					var region := Rect2(Vector2(index % 4, index / 4) * 48, Vector2(48, 48))
					_canvas.sprite(EXPLOSION, region, Transform2D(0.0, Vector2(13, 13), 0.0, at))
				Effect.PARTICLES:
					if age >= float(row[2]["life"]):
						rows.remove_at(i)
					else:
						_draw_particles(row[2], row[3], age, at)
				Effect.NUMBER:
					var p := age / 0.6
					if p >= 1.0:
						rows.remove_at(i)
						continue
					at.y += WorldCanvas.FONT.get_ascent(32) - 90.0 - 56.0 * (1.0 - (1.0 - p) ** 2)
					var color := UiFactory.C_DANGER if row[3] else UiFactory.C_WARN
					_canvas.text_at(str(row[2]), at, Color(color, minf(1.0, 2.0 * (1.0 - p))), false, 6)
				Effect.GRAIN:
					var flight: float = row[2]
					if age >= flight:
						rows.remove_at(i)
					else:
						_draw_grains(at, grain_target, age, flight)

func _draw_grains(origin: Vector2, target: Vector2, age: float, life: float) -> void:
	var scatter := (1.0 - exp(-4.5 * minf(age, 0.28))) / 4.5
	var fly := smoothstep(0.28, life, age)
	for shard in 10:
		var speed := 260.0 + 460.0 * float(shard * 7 % 10) / 9.0
		var offset := Vector2.from_angle(TAU * shard / 10.0) * speed * scatter
		var at := (origin + offset).lerp(target, fly)
		var size := 4.0 + float(shard * 3 % 8) * 0.5
		_canvas.polygon(PackedVector2Array([at + Vector2(0, -2 * size), at + Vector2(size, 0),
				at + Vector2(0, 2 * size), at - Vector2(size, 0)]), Color8(18, 18, 22))
		_canvas.rect(Rect2(at - Vector2.ONE, Vector2(2, 2)), Color8(70, 70, 78), -1.0, false)

func _nameplate(at: Vector2, name: String, color: Color) -> void:
	_canvas.text_at(name, at + Vector2(0, -78), Color(color, 0.85), true)


func _hp_bar(index: int) -> EnemyHpBar:
	while _hp_nodes.size() <= index:
		var node := EnemyHpBar.new()
		node.name = "EnemyHpBar%d" % _hp_nodes.size()
		node.z_index = 100
		_hud_parent().add_child(node)
		_hp_nodes.append(node)
	return _hp_nodes[index]

func _guide(points: PackedVector2Array, color: Color, explosive: bool, overlay: bool) -> void:
	if points.size() < 2:
		return
	_canvas.line(points, color, 1.5, overlay)
	if explosive:
		_canvas.circle(points[-1], 20.0, Color(1.0, 0.4, 0.2, 0.16), true)
		_canvas.circle(points[-1], 9.0, Color(1.0, 0.4, 0.2, 0.48), true)

func _reload(at: Vector2, facing: int, progress: float, remaining: float) -> void:
	if not is_instance_valid(_reload_node):
		_reload_node = ReloadRing.new()
		_reload_node.name = "ReloadRing"
		_hud_parent().add_child(_reload_node)
	_reload_node.position = at + Vector2(-58.0 * facing, -44.0)
	_reload_node.set_progress(progress, remaining)
	_reload_node.show()

func _draw_particles(style: Dictionary, color: Color, age: float, at: Vector2) -> void:
	var count: int = style["count"]
	var speed: Vector2 = style["speed"]
	var sizes: Vector2 = style["size"]
	var fall := Vector2(0, float(style["gravity"]) * 0.5 * age * age)
	color.a *= minf(1.0, 3.0 * (1.0 - age / float(style["life"])))
	for i in count:
		var direction := Vector2.UP.rotated((float(i) / (count - 1) - 0.5) * float(style["spread"]))
		var weight := float(i * 7 % count) / (count - 1)
		var pos := at + direction * lerpf(speed.x, speed.y, weight) * age + fall
		var size := Vector2.ONE * lerpf(sizes.x, sizes.y, weight)
		_canvas.rect(Rect2(pos - size * 0.5, size), color, -1.0, false)

static func _frame(frames: SpriteFrames, animation: StringName, age: float) -> AtlasTexture:
	var count := frames.get_frame_count(animation)
	var duration := 0.0
	for i in count:
		duration += frames.get_frame_duration(animation, i)
	var at := age * frames.get_animation_speed(animation)
	if frames.get_animation_loop(animation):
		at = fposmod(at, duration)
	for i in count - 1:
		at -= frames.get_frame_duration(animation, i)
		if at < 0.0:
			return frames.get_frame_texture(animation, i) as AtlasTexture
	return frames.get_frame_texture(animation, count - 1) as AtlasTexture
