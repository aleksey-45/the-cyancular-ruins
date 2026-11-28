class_name MatchPresenter
extends RefCounted

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")

const Actor := preload("res://core/sim/player_state_schema.gd")
const Enemy := MatchWorld.EnemyView
const Pose := MatchSampler.Pose
const CFG: PlayerConfig = preload("res://core/config/player_config.tres")
const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

var frame := MatchFrame.new()
var preview_minute := -1.0
var names := {}
var hues := {}
var _spec: WorldSpec
var _terrain: Terrain
var _role: int
var _account: GrainAccount
var _actors := {}
var _enemies := {}
var _health: Array = []
var _blasts := {}
var _splash_after := {}
var _balance := -1.0
var _locked := false
var sampler: MatchSampler
var world: WorldView
var camera := MatchCamera.new()
var hud := Hud.State.new()
var feedback := CombatFeedback.State.new()
var watch: WatchHud.State
var post := PostProcess.State.new()
var _score: RoundProjection
var radar := false
var watch_offset := Vector2.ZERO
var sounds: Array = []
var pitch := 1.0
var _now := 0.0
var _walls := PackedByteArray()
var _world_draw: Dictionary

func _init(spec: WorldSpec, terrain: Terrain, role: int, account: GrainAccount) -> void:
	_spec = spec
	_terrain = terrain
	_role = role
	world = WorldView.new(terrain.map_size)
	sampler = MatchSampler.new(terrain.map_size, role)
	_walls.resize((spec.map.size.x * spec.map.size.y + 7) >> 3)
	var cells := terrain.get_modified()
	for cell: Vector2i in cells:
		if cells[cell] == 0:
			var index := terrain.sub_index(cell)
			_walls[index >> 3] |= 1 << (index & 7)
	terrain.take_wall_changes()
	_account = account
	frame.mode = spec.mode
	if spec.mode != WorldSpec.SOLO:
		_score = RoundProjection.new(spec, role)
	if account != null:
		watch = WatchHud.State.new()
		frame.clock = MatchFrame.Clock.new()
		_clock(account.capture_state(), false, false)

func accept(step: Dictionary) -> void:
	sampler.accept(step)

## 世界时间可暂停。反馈、后期及联机倒计时使用界面时间。
func advance(world_delta: float, ui_delta: float, alpha: float, drop: float) -> DrawFrame:
	sounds.clear()
	var round_sample: Dictionary
	if world_delta > 0.0 or _world_draw.is_empty():
		_now += world_delta
		var sample := sampler.sample(_now, alpha)
		round_sample = sample.round
		var changes := _terrain.take_wall_changes()
		_compose(sample, _now, drop, changes)
		if not changes.is_empty():
			_walls = _walls.duplicate()
			for index: int in changes:
				var bit := 1 << (index & 7)
				if changes[index]:
					_walls[index >> 3] &= ~bit
				else:
					_walls[index >> 3] |= bit
		_apply_cues()
		var own: Array = sample.local
		var speed: float = own[Actor.VEL].x + own[Actor.KNOCK_VEL].x
		camera.advance(world_delta, frame.focus, _terrain.map_size, -speed if frame.clock and frame.clock.rewind else speed)
		_world_draw = world.build(frame, camera.position + watch_offset / CFG.cam_zoom)
	var panel := hud.advance(frame, world_delta)
	panel.feedback = feedback.advance(ui_delta)
	if frame.clock:
		panel.watch = watch.advance(frame.clock, world_delta, _now, frame.mode == WorldSpec.SOLO)
	if frame.mode == WorldSpec.SOLO:
		panel.day = Daylight.time_text(frame.day_minute)
		pitch = clampf(1.0 + TCFG.LOAN_PITCH_RANGE * frame.clock.loan_depth
				+ (0.12 if frame.clock.haste else -0.15 if frame.clock.rewind else 0.0), 0.7, 1.8)
	else:
		panel.score = _score.advance(round_sample, names, ui_delta)
	if radar:
		panel.radar = Minimap.project(frame, _terrain.map_size)
	var screen := post.advance(frame, world_delta, ui_delta, sounds)
	var terrain_film := 0.0
	if frame.mode != WorldSpec.SOLO:
		terrain_film = screen.rewind_film
		screen.rewind_film = 0.0
	return DrawFrame.new(_now, camera.position, _walls, Vector2(_now, terrain_film), _world_draw, panel, screen)

func _apply_cues() -> void:
	if frame.hit_ratio > 0.0:
		var ratio := frame.hit_ratio
		camera.shake(CFG.hit_cam_shake * ratio / 0.25 if ratio > 0.25 else 6.0, CFG.hit_cam_shake_time if ratio > 0.25 else 0.15)
		post.hit = maxf(post.hit, clampf(ratio * 2.0, 0.5, 1.0))
	for cue: Array in frame.cues:
		match cue[0]:
			"clear_motion":
				world.clear_motion(cue[1])
				if cue[1] == _role: camera.reset_follow()
			"motion": world.motion(cue[1], cue[2], frame.now, cue[3])
			"splash": world.splash(cue[1], cue[2], frame.now)
			"debris": world.debris(cue[1], cue[2], frame.now)
			"number": world.hit(cue[1], cue[2], cue[3], cue[4])
			"sound": sounds.append([cue[1], 0.0])
			"hit": feedback.hit_at = feedback.now
			"kill":
				feedback.kill(cue[1])
				sounds.append(["kill", 0.0])
			"streak_reset": feedback.streak = 0
			"grain": world.grain(cue[1], frame.now, TCFG.ELITE_GRAIN_DELAY_TICKS * ActorStep.DT)
			"grain_received": watch.tremble = WatchHud.TREMBLE_TIME
			"loan_locked": watch.flash = WatchHud.LOCK_FLASH_TIME
			"fire":
				world.fire(cue[1], cue[2], frame.now)
				var weapon := WeaponRegistry.definition(cue[2])
				sounds.append([weapon.shot_sound, 0.0])
				if cue[3] and weapon.has("shake"):
					camera.shake(weapon.shake, weapon.get("shake_time", 0.1))
			"blast":
				world.blast(cue[1], frame.now)
				var distance := ToroidalGrid.toroidal_delta_px(frame.focus, cue[1], _terrain.map_size).length()
				var reach := maxf(WeaponRegistry.blast_definition(cue[2]).radius * 2.5, 400.0)
				if distance <= reach:
					camera.shake(CFG.explosion_cam_shake * (1.0 - distance / reach), CFG.explosion_cam_shake_time)

func _compose(sample: Dictionary, now: float, drop: float, walls: Dictionary) -> MatchFrame:
	var own: Array = sample["local"]
	var health: Array = sample["health"]
	frame.begin(now, sample["focus"])
	frame.cues.append_array(sample.shots)
	frame.hit_ratio = 0.0
	frame.day_minute = preview_minute if preview_minute >= 0.0 else Daylight.minute_at(sample["elapsed"])
	frame.kills = sample["kills"]
	frame.trajectories = Settings.pvp_show_trajectories
	frame.radar_players = Settings.pvp_minimap_show_enemy
	var haste: bool = own[Actor.HASTE_MULT] > 1.0 or sample["time_mode"] == WorldTime.Mode.HASTE
	var rewind: bool = own[Actor.REWIND] or sample["time_mode"] == WorldTime.Mode.REWIND
	var new_actors := {_role: own}
	var aim: Vector2 = own[Actor.AIM]
	_player_pose(_role, frame.focus, own[Actor.VEL], own, health, aim, haste, rewind)
	_player_cues(_role, own, health, frame.focus, rewind)
	var body := Transform2D(0.0, Vector2.ONE * CFG.body_scale, 0.0, own[Actor.POS])
	var hull := CFG.crouched_hull if own[Actor.SQUAT] or health[Actor.DOWNED] else CFG.standing_hull
	_splash(_role, body * hull, own[Actor.VEL])
	frame.aim_guide = _aim_guide(own, frame.actors[0], sample["time_mode"] == WorldTime.Mode.HASTE)
	frame.drop_progress = drop if frame.actors[0].weapon != 0 and frame.actors[0].reload_left <= 0.0 else 0.0
	_sample_hud(own, health)
	if frame.clock != null:
		_clock(sample["account"], rewind, haste)
	for id: int in sample["players"]:
		var pose: Array = sample["players"][id]
		var row: Array = pose[Pose.STATE]
		var pos := _near(pose[Pose.POS])
		new_actors[id] = row
		_player_pose(id, pos, pose[Pose.VEL], row, row, row[Actor.AIM], row[Actor.HASTE_MULT] > 1.0, row[Actor.REWIND])
		_player_cues(id, row, row, pos, row[Actor.REWIND])
	_actors = new_actors
	_health = health
	_sample_enemies(sample["enemies"], haste, rewind)
	_sample_objects(sample, own, rewind, walls)
	return frame

func _player_pose(id: int, pos: Vector2, velocity: Vector2, row: Array, health: Array,
		aim: Vector2, haste: bool, rewind: bool) -> void:
	var pose := MatchFrame.Pose.new()
	pose.id = id
	pose.anchor = pos
	pose.facing = row[Actor.FACING]
	pose.state = row[Actor.STATE]
	pose.downed = health[Actor.DOWNED]
	pose.haste = haste
	pose.rewind = rewind
	pose.remote = id != _role
	pose.hit_left = health[Actor.IFRAMES]
	pose.air_speed = velocity.y if not (row[Actor.GROUNDED] or row[Actor.IN_WATER] or row[Actor.CLIMB_LATCHED]) else 0.0
	pose.weapon = Actor.equipped_type(row)
	if pose.weapon != 0:
		var weapon := WeaponRegistry.definition(pose.weapon)
		var gun: Array = row[Actor.EQUIPMENT]
		var facing: int = gun[GunBody.StateSlot.SHOT_FACING]
		pose.aim = GunBody.aim_transform(aim if aim != Vector2.ZERO else Vector2(facing, 0), facing, weapon["pitch"])
		pose.reload_left = gun[GunBody.StateSlot.RELOAD_LEFT]
		if gun[GunBody.StateSlot.AIMING] and weapon.has("draw_length"):
			pose.bow_draw = GunBody.charge_for_hold(weapon, gun[GunBody.StateSlot.HOLD])
	if frame.mode != WorldSpec.SOLO:
		pose.name = names.get(id, "玩家%d" % id)
		pose.team = _spec.teams.get(id, id)
		pose.hue = float(hues.get(id, 0.0)) / 360.0
		if id != _role and Settings.pvp_show_enemy_hp and not pose.downed:
			pose.health = float(health[Actor.HP]) / _max_hp(id)
	frame.actors.append(pose)

func _aim_guide(row: Array, pose: MatchFrame.Pose, world_haste: bool) -> PackedVector2Array:
	var gun: Array = row[Actor.EQUIPMENT]
	if pose.downed or gun.is_empty() or not gun[GunBody.StateSlot.AIMING]:
		return PackedVector2Array()
	var weapon := WeaponRegistry.definition(pose.weapon)
	var charge := GunBody.charge_for_hold(weapon, gun[GunBody.StateSlot.HOLD])
	var body := Transform2D(0.0, pose.scale, 0.0, row[Actor.POS])
	var muzzle := body * pose.aim * ShotRules.launch_offset(weapon, charge)
	var direction := pose.aim.x
	var points: PackedVector2Array
	if weapon.has("arc_time"):
		var dt := ActorStep.DT * (TCFG.HASTE_PLAYER if world_haste else 1.0)
		var speed := ShotRules.launch_speed(weapon, charge) * float(row[Actor.HASTE_MULT])
		points = ShotRules.trace_arc(_terrain, muzzle, direction * speed, weapon, dt, weapon["arc_time"])
	else:
		var length := float(weapon.get("guide_length", 600.0)) * pose.scale.x
		points = PackedVector2Array([muzzle, muzzle + direction * length])
	return Transform2D(0.0, ToroidalGrid.toroidal_delta_px(row[Actor.POS], pose.anchor, _terrain.map_size)) * points

func _player_cues(id: int, row: Array, health: Array, pos: Vector2, rewind: bool) -> void:
	var before: Array = _actors.get(id, [])
	if before.is_empty():
		return
	var mine := id == _role
	var previous := _health if mine else before
	if previous[Actor.LIFE] != health[Actor.LIFE]:
		_splash_after.erase(id)
		frame.cues.append(["clear_motion", id])
		return
	var damage := int(previous[Actor.HP]) - int(health[Actor.HP])
	if damage > 0:
		if mine:
			frame.hit_ratio = float(damage) / _max_hp(id)
			frame.cues.append(["sound", "hurt"])
			frame.cues.append(["motion", id, &"hurt", 0.0])
			if frame.mode == WorldSpec.SOLO:
				frame.cues.append(["number", id, pos, damage, true])
		else:
			frame.cues.append(["motion", id, &"hurt", 0.0])
			if health[Actor.LAST_ATTACKER] == _role:
				frame.cues.append(["hit"])
	if health[Actor.DOWNED] and not previous[Actor.DOWNED] and frame.mode != WorldSpec.SOLO:
		if mine:
			frame.cues.append(["streak_reset"])
		elif frame.mode == WorldSpec.DUEL or health[Actor.LAST_ATTACKER] == _role:
			frame.cues.append(["kill", names.get(id, "玩家%d" % id)])
	if rewind or before[Actor.REWIND] or health[Actor.DOWNED]:
		return
	if not row[Actor.IN_WATER] and not row[Actor.CLIMB_LATCHED]:
		_motion_cues(id, row[Actor.GROUNDED], before[Actor.GROUNDED], row[Actor.VEL], before[Actor.VEL])
	if row[Actor.CHARGE] and not before[Actor.CHARGE]:
		frame.cues.append(["motion", id, &"charge", 0.0])
	if mine:
		var gun: Array = row[Actor.EQUIPMENT]
		var old: Array = before[Actor.EQUIPMENT]
		if row[Actor.WEAPON_INST] != before[Actor.WEAPON_INST]:
			if not gun.is_empty():
				frame.cues.append(["sound", "switch"])
		elif not gun.is_empty() and not old.is_empty():
			var reloading: bool = gun[GunBody.StateSlot.RELOAD_LEFT] > 0.0
			var was_reloading: bool = old[GunBody.StateSlot.RELOAD_LEFT] > 0.0
			if reloading != was_reloading:
				frame.cues.append(["sound", "reload" if reloading else "switch"])

func _sample_hud(row: Array, health: Array) -> void:
	frame.health = health[Actor.HP]
	frame.max_health = _max_hp(_role)
	frame.oxygen = row[Actor.WATERPROOF]
	frame.max_oxygen = CFG.player_waterproof_max
	frame.downed = health[Actor.DOWNED]
	var entries: PackedInt32Array = row[Actor.INVENTORY]
	var inst: int = row[Actor.WEAPON_INST]
	frame.inventory = WeaponInventory.layout(entries, inst)
	var type: int = frame.actors[0].weapon
	frame.magazine = int(WeaponRegistry.definition(type).get("mag", 0)) if type != 0 else 0
	frame.ammo = entries[frame.inventory[0] * WeaponInventory.STRIDE + WeaponInventory.CARRIED] if frame.magazine > 0 else -1

func _max_hp(id: int) -> int:
	return TeamRules.max_hp(_spec.teams.get(id, 0), _spec.team_counts)

func _clock(account: Array, rewind: bool, haste: bool) -> void:
	var clock := frame.clock
	clock.balance = account[GrainAccount.BALANCE]
	clock.cap = _account.cap
	var loan: float = account[GrainAccount.LOAN_USED]
	var used: float = account[GrainAccount.SHORT_USED]
	var window := _account.window if _account.window > 0.0 else TCFG.SHORT_WINDOW
	clock.borrowed = loan > 0.5
	clock.allowance = -roundi(loan) if clock.borrowed else roundi(_account.window - used)
	clock.long_turns = clampf((used + loan) / window, 0.0, 1.0 + _account.loan_max / window)
	clock.loan_depth = loan / _account.loan_max if frame.mode == WorldSpec.SOLO and _account.loan_max > 0.0 else 0.0
	clock.rewind = rewind
	clock.haste = haste
	if _balance >= 0.0 and clock.balance > _balance:
		frame.cues.append(["grain_received"])
	if account[GrainAccount.LOCKED] and not _locked:
		frame.cues.append(["loan_locked"])
	_balance = clock.balance
	_locked = account[GrainAccount.LOCKED]

func _sample_enemies(rows: Array, haste: bool, rewind: bool) -> void:
	var next := {}
	for row: Array in rows:
		var id := -1 - int(row[Enemy.SLOT])
		var before: Array = _enemies.get(id, [])
		next[id] = row
		if not row[Enemy.ACTIVE]:
			continue
		var pose := MatchFrame.Pose.new()
		pose.id = id
		pose.anchor = _near(row[Enemy.POS])
		pose.frames = row[Enemy.FRAMES]
		pose.scale = row[Enemy.SCALE]
		pose.state = row[Enemy.ACTIVITY]
		pose.facing = row[Enemy.FACING]
		pose.downed = row[Enemy.DOWNED]
		pose.haste = haste
		pose.rewind = rewind
		pose.elite = row[Enemy.ELITE]
		pose.black_bird = row[Enemy.BLACK_BIRD]
		pose.air_speed = 0.0 if row[Enemy.GROUNDED] else row[Enemy.VEL].y
		pose.hit_left = row[Enemy.HIT_LEFT]
		pose.lunge_age = row[Enemy.LUNGE]
		frame.actors.append(pose)
		_splash(id, row[Enemy.BOUNDS], row[Enemy.VEL])
		if not before.is_empty() and (not rewind or pose.elite):
			var damage := int(before[Enemy.HP]) - int(row[Enemy.HP])
			if damage > 0:
				frame.cues.append(["hit"])
				frame.cues.append(["motion", id, &"hurt", 0.0])
				frame.cues.append(["number", id, pose.anchor, damage, false])
			if pose.elite and pose.downed and not before[Enemy.DOWNED]:
				frame.cues.append(["grain", pose.anchor])
			if pose.state != before[Enemy.ACTIVITY]:
				if pose.state == EnemyBase.Activity.TAKE_OFF or pose.state == EnemyBase.Activity.CHARGE:
					frame.cues.append(["motion", id, &"take_off" if pose.state == EnemyBase.Activity.TAKE_OFF else &"charge", 0.0])
			_motion_cues(id, row[Enemy.GROUNDED], before[Enemy.GROUNDED], row[Enemy.VEL], before[Enemy.VEL])
	_enemies = next

func _motion_cues(id: int, grounded: bool, was_grounded: bool, velocity: Vector2, previous: Vector2) -> void:
	if grounded and not was_grounded:
		frame.cues.append(["motion", id, &"land", previous.y])
	elif not grounded and was_grounded and velocity.y < 0.0:
		frame.cues.append(["motion", id, &"jump", 0.0])

func _sample_objects(sample: Dictionary, own: Array, rewind: bool, walls: Dictionary) -> void:
	for id: int in sample["projectiles"]:
		var row: Array = sample["projectiles"][id]
		frame.projectiles.append([id, row[0], _near(row[1]), row[2]])
	for id: int in sample["beams"]:
		var at: float = sample["combat_tick"] if ShotRules.shooter_role(id) == _role else sample["remote_tick"]
		frame.sample_beam(sample["beams"][id], at)
	for row: Array in sample["pickups"].values():
		var offset := ToroidalGrid.toroidal_delta_px(own[Actor.POS], row[WeaponPickup.POS], _terrain.map_size)
		var available := GroundWeaponField.available(_role, _spec.weapons, row[WeaponPickup.TYPE],
			row[WeaponPickup.LOCKED_ROLE], row[WeaponPickup.UNLOCK_TICK], sample["pickup_tick"], offset.length_squared())
		frame.pickups.append([row[WeaponPickup.TYPE], frame.focus + offset, available])
	if not rewind:
		for id: int in sample["blasts"]:
			if not _blasts.has(id):
				var blast: Array = sample["blasts"][id]
				frame.cues.append(["blast", blast[CombatSimulator.Blast.POS], blast[CombatSimulator.Blast.TYPE]])
	_blasts = sample["blasts"]
	for index: int in walls:
		if not walls[index] and not rewind:
			var cell := _terrain.sub_position(index)
			frame.cues.append(["debris", _terrain.cell_center(cell), _terrain.sub_texture(cell)])

func _splash(id: int, bounds: Rect2, velocity: Vector2) -> void:
	if frame.now < float(_splash_after.get(id, 0.0)) or velocity.length_squared() < WCFG.water_fx_move_threshold ** 2:
		return
	var feet := Water.feet(bounds)
	var depth := _terrain.water_depth(feet)
	if depth != -INF:
		var surface := depth <= WCFG.water_fx_splash_band + bounds.size.y * 0.5
		frame.cues.append(["splash", feet - Vector2(0, depth if surface else 0.0), surface])
		_splash_after[id] = frame.now + (WCFG.water_fx_splash_interval if surface else WCFG.water_fx_bubble_interval)

func _near(pos: Vector2) -> Vector2:
	return ToroidalGrid.anchor_to_nearest(pos, frame.focus, _terrain.map_size)
