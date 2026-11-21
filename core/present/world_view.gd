class_name WorldView
extends RefCounted

const WEAPONS := preload("res://assets/textures/weapons.png")
const BULLETS := preload("res://assets/textures/bullets.png")
const EXPLOSION := preload("res://assets/textures/effects.png")
const PLAYER_FRAMES := preload("res://scenes/player/player_frames.tres")
const PLAYER_CLIPS := [&"idle", &"move", &"fly", &"charge", &"squat"]
const Activity := EnemyBase.Activity
const ENEMY_CLIPS := [&"sleeping", &"fall_asleep", &"wake_up", &"jump", &"dashing",
	&"take_off", &"flying", &"dashing", &"run", &"run", &"disappear", &"disappear", &"appear", &"jump_backward", &"dead"]
const PLAYER_GLOW := Color(0.30, 0.62, 1.0)
const ENEMY_GLOW := Color(1.0, 0.94, 0.86)
const ELITE_GLOW := Color(2.0, 1.64, 0.12)
const PULSES := {&"jump": 0.75, &"dash": 0.8, &"take_off": 0.8, &"charge": 0.9, &"hurt": -0.5}
const EXPLOSION_FRAMES := [0.09, 0.18, 0.255, 0.33, 0.39, 0.45, 0.50, 0.55]
const DEBRIS := {"life": 0.4, "count": 10, "spread": TAU, "speed": Vector2(0, 120),
		"gravity": 900.0, "size": Vector2(4, 8)}
const SPLASH := {"life": 0.4, "count": 8, "spread": deg_to_rad(80), "speed": Vector2(60, 160),
		"gravity": 700.0, "size": Vector2(4, 10)}
const BUBBLES := {"life": 0.7, "count": 5, "spread": deg_to_rad(24), "speed": Vector2(40, 90),
		"gravity": -30.0, "size": Vector2(2, 4)}

enum Effect { BLAST, PARTICLES, NUMBER, GRAIN }

var _canvas: WorldCanvas
var _ui: GuideCanvas
var _size: Vector2
var _motions := {}
var _poses := {}
var _fire := {}
var _trails: Array[Array] = []
var _trail_deadlines := {}
var _alternate := false
var _paths := {}
var _next_paths := {}
var _effects := [[], [], [], []]
var _hits := {}
var _remote_hits := {}

func bind(canvas: WorldCanvas, size: Vector2, ui_canvas: GuideCanvas = null) -> void:
	_canvas = canvas
	_size = size
	_ui = ui_canvas


## 发光通道节点:交给 PostProcess 挂到 GlowViewport。
func glow_pass() -> CanvasItem:
	return _canvas.glow_pass()

func reset() -> void:
	for buffer in [_motions, _poses, _fire, _trails, _trail_deadlines, _paths, _next_paths, _hits, _remote_hits] + _effects:
		buffer.clear()
	_alternate = false

func clear_motion(id: int) -> void:
	_motions.erase(id)

func motion(id: int, kind: StringName, now: float, speed := 0.0) -> void:
	var strength := float(PULSES[kind]) if kind != &"land" else -clampf(inverse_lerp(220.0, 900.0, speed), 0.0, 1.0)
	if strength != 0.0:
		_motions[id] = Vector2(now, strength)

func remote_hurt(role: int, now: float) -> void:
	motion(role, &"hurt", now)
	_remote_hits[role] = now + 0.35

func fire(id: int, weapon: int, now: float) -> void:
	Sfx.play(WeaponRegistry.definition(weapon)["shot_sound"])
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
	_canvas.begin()
	if _ui != null:
		_ui.begin()
	_draw_trails(frame.now, frame.focus)
	for i in frame.actors.size():
		var pose := frame.actors[i]
		_actor(pose, frame)
		if i == 0 and not frame.aim_guide.is_empty():
			var weapon := WeaponRegistry.definition(pose.weapon)
			# main:没有 preview_arc 的枪只画直线激光;有 preview_arc 的才同时画弧。
			if not (bool(weapon.get("show_aim_laser", false)) and not bool(weapon.get("preview_arc", false))):
				_guide(frame.aim_guide, weapon.get("guide_color", Color(1, 0.2, 0.2, 0.6)),
						not weapon["projectile"]["blast"].is_empty())
		if not pose.name.is_empty():
			_nameplate(pose.anchor, pose.name, pose.name_color(frame.mode), pose.health)
	for row in frame.pickups:
		var weapon := WeaponRegistry.definition(row[0])
		var bounds: Rect2 = weapon["pickup_bounds"]
		var size := WeaponPickup.WORLD_SCALE
		var at: Vector2 = row[1]
		_canvas.sprite(WEAPONS, weapon["region"],
				Transform2D(0.0, Vector2.ONE * size, 0.0, at - bounds.get_center() * size))
		if row[2]:
			_pickup_prompt(at)
	_next_paths.clear()
	for row in frame.projectiles:
		if frame.trajectories:
			_trajectory(row[0], row[2])
		var bullet := WeaponRegistry.projectile_definition(row[1])
		_canvas.sprite(BULLETS, bullet["projectile_region"],
				Transform2D(row[3], Vector2.ONE * float(bullet["size"]), 0.0, row[2]),
				bullet.get("bullet_color", Color.WHITE))
	var previous := _paths
	_paths = _next_paths
	_next_paths = previous
	_draw_effects(frame, grain_target)
	_canvas.submit()
	if _ui != null:
		_ui.submit()

func _actor(pose: MatchFrame.Pose, frame: MatchFrame) -> void:
	var now := frame.now
	var enemy := pose.frames != null
	var flip := pose.facing < 0
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
	if not (pose.downed or (pose.rewind and not pose.elite)):
		var pulse: Vector2 = _motions.get(pose.id, Vector2.ZERO)
		var air := minf(absf(pose.air_speed) / 700.0, 1.0) * 0.1
		var amount := 0.06 * clampf(air + pulse.y * exp(-16.0 * (now - pulse.x)), -1.0, 1.0)
		visual = visual.scaled_local(Vector2(1.0 - amount, 1.0 + amount))
	else:
		_motions.erase(pose.id)
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
		if frame.mode == MatchFrame.Mode.DUEL or frame.mode == MatchFrame.Mode.TEAM:
			var base := UiFactory.C_TEAM_A
			var team_color := pose.name_color(frame.mode)
			tint = Color(team_color.r / base.r, team_color.g / base.g, team_color.b / base.b)
		var hit_left := float(_remote_hits.get(pose.id, 0.0)) - now if pose.remote else pose.hit_left
		var alpha := 0.4 if hit_left > 0.0 and int(hit_left * 20.0) % 2 == 0 else 1.0
		color = Color(tint, alpha)
		if frame.mode == MatchFrame.Mode.ROYALE and pose.hue != 0.0:
			color = Color(fposmod(pose.hue, 1.0), 1, 1, alpha)
			pass_kind = WorldCanvas.Pass.HUE
		if pose.haste and not pose.rewind:
			glow = Color((ENEMY_GLOW if pose.remote else PLAYER_GLOW) * tint, alpha)
		if not pose.downed:
			_trail(pose, frame, image, visual, tint)
	_texture(image, visual, color, flip, pass_kind)
	if glow.a > 0.0:
		_texture(image, visual, glow, flip, WorldCanvas.Pass.GLOW)
	if pose.weapon == 0:
		return
	var weapon := WeaponRegistry.definition(pose.weapon)
	var offset: Vector2 = weapon["sprite_offset"]
	# 蓄力弓:拉弓时把箭画在弓弦后方,后退量由 charge_arrow_pull 与蓄力比例决定。
	if pose.charge > 0.0 and weapon.has("charge_arrow_pull"):
		var pull: float = float(weapon["charge_arrow_pull"]) * pose.charge
		_canvas.sprite(BULLETS, weapon["projectile_region"],
				body * pose.aim * Transform2D(0.0, Vector2.ONE * float(weapon["size"]), 0.0, Vector2(-pull, 0.0)),
				Color.WHITE)
	var fired: Array = _fire.get(pose.id, [])
	if not fired.is_empty() and fired[0] == pose.weapon:
		offset.x -= float(weapon.get("kick", 0.0)) * (1.0 - clampf((now - float(fired[1])) / 0.06, 0.0, 1.0))
	var tilt := 0.0
	var reload := 1.0 - pose.reload_left / float(weapon["reload"]) if pose.reload_left > 0.0 else -1.0
	if reload >= 0.0:
		var lift := sin(PI * reload)
		tilt = 0.9 * lift
		offset += Vector2(-3.0 + 1.2 * sin(34.0 * reload), 7.0) * lift
	if clip == &"move":
		var cycle := age * frames.get_animation_speed(clip) / frames.get_frame_count(clip)
		offset.y += sin(TAU * cycle) * 1.4
	_canvas.sprite(WEAPONS, weapon["region"], body * pose.aim * Transform2D(tilt, offset), Color(Color.WHITE, color.a))
	# 重武器预瞄:main 的 laser_length/laser_color;弓的 show_aim_laser=false,用拉弓表现代替。
	if pose.aiming and bool(weapon.get("show_aim_laser", false)):
		var length := float(weapon.get("laser_length", 0.0))
		if length > 0.0:
			var aim_xform := body * pose.aim
			var dir := aim_xform.x.normalized()
			var target = _ui if _ui != null else _canvas
			target.line(PackedVector2Array([aim_xform.origin, aim_xform.origin + dir * length]),
					weapon.get("laser_color", Color(1.0, 0.2, 0.2, 0.6)), 2.0)
	if reload >= 0.0 and not pose.remote:
		_reload(pose.anchor, pose.facing, reload, pose.reload_left)

func _enemy_clip(pose: MatchFrame.Pose) -> StringName:
	if pose.black_bird and pose.state == Activity.REST:
		return &"sleep"
	if pose.state == Activity.LUNGE:
		var start := &"turn_dash"
		if pose.lunge_age < float(pose.frames.get_frame_count(start)) / pose.frames.get_animation_speed(start):
			return start
	return ENEMY_CLIPS[pose.state]

func _trail(pose: MatchFrame.Pose, frame: MatchFrame, image: Texture2D, visual: Transform2D, tint: Color) -> void:
	if frame.now < float(_trail_deadlines.get(pose.id, 0.0)):
		return
	var foreground := pose.rewind and pose.remote
	var alternate := pose.haste and frame.mode == MatchFrame.Mode.SOLO
	var color := Color.WHITE
	if alternate:
		color = Color(1.0, 0.25, 0.25, 0.55) if _alternate else Color(0.3, 0.4, 1.0, 0.55)
		_alternate = not _alternate
	elif pose.haste:
		color = UiFactory.C_TEAM_B
	elif foreground:
		color = UiFactory.C_TEXT_DIM
	elif pose.state == Player.DASH:
		color = UiFactory.C_TEAM_A * tint
	else:
		return
	_trail_deadlines[pose.id] = frame.now + (0.03 if alternate else 0.06)
	var pass_kind := WorldCanvas.Pass.FOREGROUND if foreground else WorldCanvas.Pass.NORMAL
	_trails.append([frame.now, image, visual, color, pose.facing < 0, pass_kind])

func _draw_trails(now: float, anchor: Vector2) -> void:
	for i in range(_trails.size() - 1, -1, -1):
		var row := _trails[i]
		var fade := 1.0 - (now - float(row[0])) / 0.26
		if fade <= 0.0:
			_trails.remove_at(i)
		else:
			var color: Color = row[3]
			color.a *= fade
			var pose: Transform2D = row[2]
			pose.origin = GridPathfinder.anchor_to_nearest(pose.origin, anchor, _size)
			_texture(row[1], pose, color, row[4], row[5])

func _trajectory(id: int, at: Vector2) -> void:
	var path: PackedVector2Array = _paths.get(id, PackedVector2Array())
	if not path.is_empty():
		var shift := GridPathfinder.anchor_to_nearest(path[-1], at, _size) - path[-1]
		if shift != Vector2.ZERO:
			for i in path.size():
				path[i] += shift
	if path.size() == 16:
		path.remove_at(0)
	path.append(at)
	_next_paths[id] = path
	if path.size() > 1:
		var target = _ui if _ui != null else _canvas
		target.line(path, Color(1, 1, 1, 0.55), 2.5)

func _pickup_prompt(at: Vector2) -> void:
	var center := at + Vector2(0, -64)
	var box := Rect2(center - Vector2(25, 25), Vector2(50, 50))
	_canvas.rect(box, Color(0.24, 0.42, 0.46, 0.72))
	_canvas.rect(box.grow(-1.5), Color(0.35, 0.85, 0.90), 3.0)
	_canvas.rect(box.grow(-8.5), Color(0.20, 0.55, 0.62), 3.0)
	_canvas.text_at("F", center + Vector2(0, WorldCanvas.centered_baseline()), Color(0.92, 0.97, 1.0))

func _draw_effects(frame: MatchFrame, grain_target: Vector2) -> void:
	var now := frame.now
	for hit_row: Array in _hits.values():
		_effects[Effect.NUMBER].append([hit_row[0], now, hit_row[1], hit_row[2]])
	_hits.clear()
	for beam: Array in frame.beams:
		var points: PackedVector2Array = beam[0]
		var alpha: float = beam[1]
		var offset := GridPathfinder.anchor_to_nearest(points[0], frame.focus, _size) - points[0]
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
			var at := GridPathfinder.anchor_to_nearest(row[0], frame.focus, _size)
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

func _nameplate(at: Vector2, name: String, color: Color, hp := -1.0) -> void:
	_canvas.text_at(name, at + Vector2(0, -78), Color(color, 0.85), true)
	if hp >= 0.0:
		var bar := Rect2(at + Vector2(-42, -112.5), Vector2(84, 9))
		_canvas.rect(bar.grow(2.0), Color(0, 0, 0, 0.45), -1.0, false)
		bar.size.x *= clampf(hp, 0.0, 1.0)
		_canvas.rect(bar, Color(0.35, 0.9, 0.4) if hp > 0.25 else Color(0.95, 0.35, 0.3), -1.0, false)

func _guide(points: PackedVector2Array, color: Color, explosive: bool) -> void:
	if points.size() < 2:
		return
	var target = _ui if _ui != null else _canvas
	target.line(points, color, 1.0)
	if explosive:
		target.circle(points[-1], 20.0, Color(1.0, 0.4, 0.2, 0.16))
		target.circle(points[-1], 9.0, Color(1.0, 0.4, 0.2, 0.48))

func _reload(at: Vector2, facing: int, progress: float, remaining: float) -> void:
	var center := at + Vector2(-58 * facing, -44)
	var target = _ui if _ui != null else _canvas
	target.arc(center, 24.0, 0.0, TAU, Color(0.42, 0.45, 0.5, 0.22), 9.0)
	if progress > 0.0:
		target.arc(center, 24.0, -PI * 0.5, -PI * 0.5 + TAU * progress, Color(0.8, 0.84, 0.88, 0.78), 9.0)
	target.text_at("%.1f" % remaining, center + Vector2(0, WorldCanvas.centered_baseline()),
			Color(0.93, 0.95, 0.97, 0.92))

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

func _texture(texture: Texture2D, pose: Transform2D, color: Color, flip: bool,
		pass_kind := WorldCanvas.Pass.NORMAL) -> void:
	var atlas := texture as AtlasTexture
	_canvas.sprite(atlas.atlas, atlas.region, pose, color, flip, pass_kind)


static func _frame(frames: SpriteFrames, animation: StringName, age: float) -> Texture2D:
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
			return frames.get_frame_texture(animation, i)
	return frames.get_frame_texture(animation, count - 1)
