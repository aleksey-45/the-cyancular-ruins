class_name MatchController
extends Node2D

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const Mode := MatchFrame.Mode

var player: Player
var controls := LocalInputSource.new()
var combat_rules: CombatSimulator

var map_info: Dictionary
var terrain: Terrain
@onready var _view: MatchView = $View
var _world := WorldView.new()
@onready var _camera: MatchCamera = _view.camera
var _local_motion := LocalMotion.new()
var _frame := MatchFrame.new()
var _mode := Mode.SOLO
var _pause_open := false
var _clock_account: GrainAccount
var _hit_damage := 0
var _poses: Dictionary[int, MatchFrame.Pose] = {}
var _splash_after := {}

func _enter_tree() -> void:
	terrain = Terrain.new(map_info["grid"], map_info["descriptors"])
	$View/WorldViewport.world_2d = terrain.physics.world

func _exit_tree() -> void:
	combat_rules.close()

func _mount(mode: MatchFrame.Mode, account: GrainAccount = null, radar := false) -> void:
	_mode = mode
	_frame.mode = mode
	_clock_account = account
	if account != null:
		_frame.clock = MatchFrame.Clock.new()
		_sample_clock(false, false)
	_view.mount(_world, terrain.get_grid_snapshot(), terrain.descriptors(), mode, _frame.clock, radar)
	_view.pause.toggled.connect(_set_pause)
	_view.pause.leave_requested.connect(_leave_match)

func _set_pause(open: bool) -> void:
	_pause_open = open
	if _mode == Mode.SOLO:
		get_tree().paused = open

func _leave_match() -> void:
	get_tree().paused = false
	if _mode != Mode.SOLO:
		NetSession.disconnect_client()
	SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _unhandled_input(event: InputEvent) -> void:
	controls.handle_event(player, event)

func _aim_direction() -> Vector2:
	if not is_inside_tree():
		return Vector2(player.facing_direction, 0.0)
	var window := get_window()
	var offset := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	return LocalInputSource.aim_direction(player.position, player.facing_direction, terrain.map_size,
			_camera.base_position, CFG.cam_zoom, offset)

func _input_record(record: Array, delta: float) -> Array:
	return controls.complete(player, record, delta, _aim_direction())

func _reset_view() -> void:
	_poses.clear()
	_splash_after.clear()
	_world.reset()

func _live_step(from: Vector2, actions: Array) -> void:
	_local_motion.from = from
	var id := player.role
	for action in actions:
		match action["kind"]:
			"fire":
				var weapon: int = action["type_id"]
				_world.fire(id, weapon, _frame.now)
				_camera.fire(weapon)
			"land":
				if not player.in_water and not player.climb_latched:
					_world.motion(id, &"land", _frame.now, action["speed"])
			"jump", "dash":
				_world.motion(id, StringName(action["kind"]), _frame.now)
			_:
				if Sfx.ACTION_SOUNDS.has(action["kind"]):
					Sfx.play(Sfx.ACTION_SOUNDS[action["kind"]])

func _damage(damage: int) -> void:
	Sfx.play("hurt")
	_world.motion(player.role, &"hurt", _frame.now)
	_hit_damage = maxi(_hit_damage, damage)

func _blast(at: Vector2, type_id: int) -> void:
	var radius: float = WeaponRegistry.blast_definition(type_id)["radius"]
	_world.blast(at, _frame.now)
	for index: int in terrain.blast_cells(at, radius):
		var cell := terrain.sub_position(index)
		_world.debris((Vector2(cell) + Vector2(0.5, 0.5)) * Terrain.SUB_SIZE, terrain.sub_texture(cell), _frame.now)
	var distance := GridPathfinder.toroidal_delta_px(player.position, at, terrain.map_size).length()
	_camera.blast(distance, radius)

func _begin_frame(delta: float, at: Vector2, haste: bool, rewind: bool) -> void:
	_frame.begin(delta, at)
	for id: int in combat_rules.beams:
		if ShotRules.shooter_role(id) == player.role:
			_frame.sample_beam(combat_rules.beams[id], combat_rules.tick)
	_frame.wall_changes = terrain.take_wall_changes()
	_frame.hit_ratio = float(_hit_damage) / float(player.sim_max_hp) if _hit_damage > 0 else 0.0
	_hit_damage = 0
	_camera.hit(_frame.hit_ratio)
	var speed_x := player.velocity.x + player.motion_knock_velocity.x
	_camera.advance(delta, at, terrain.map_size, -speed_x if rewind else speed_x)
	_frame.trajectories = Settings.pvp_show_trajectories
	_frame.radar_players = Settings.pvp_minimap_show_enemy
	if _clock_account != null:
		_sample_clock(rewind, haste)
	_sample_hud()

func _show_pickup(pos: Vector2, type: int, owner: int, unlock: int, tick: int) -> void:
	var offset := GridPathfinder.toroidal_delta_px(player.position, pos, terrain.map_size)
	var available := GroundWeaponField.available(player, type, owner, unlock, tick, offset.length_squared())
	_frame.pickups.append([type, player.position + offset, available])

func _sample_clock(rewind: bool, haste: bool) -> void:
	var clock := _frame.clock
	var account := _clock_account
	clock.balance = account.balance
	clock.cap = account.cap
	var window := account.window if account.window > 0.0 else TimeParams.SHORT_WINDOW
	clock.borrowed = account.loan_used > 0.5
	clock.allowance = -roundi(account.loan_used) if clock.borrowed else roundi(account.window - account.short_used)
	clock.long_turns = clampf((account.short_used + account.loan_used) / window, 0.0, 1.0 + account.loan_max / window)
	clock.loan_depth = account.loan_depth() if _mode == Mode.SOLO else 0.0
	clock.rewind = rewind
	clock.haste = haste

func _sample_hud() -> void:
	_frame.health = player.sim_hp
	_frame.max_health = player.sim_max_hp
	_frame.oxygen = player.waterproof
	_frame.max_oxygen = player.max_waterproof
	_frame.downed = player.sim_downed
	_frame.drop_progress = controls.drop_hold_progress(player)
	var weapon := player.equipped
	_frame.inventory = player.weapons.cell_layout()
	_frame.magazine = int(weapon.definition.get("mag", 0)) if weapon != null else 0
	_frame.ammo = weapon.carried if _frame.magazine > 0 else -1

func _actor(id: int) -> MatchFrame.Pose:
	if not _poses.has(id):
		_poses[id] = MatchFrame.Pose.new()
		_poses[id].id = id
	var pose := _poses[id]
	_frame.actors.append(pose)
	return pose

func _player_pose(id: int, at: Vector2, facing: int, state: int, downed: bool,
		rewind: bool, haste: bool, hit_left := 0.0) -> MatchFrame.Pose:
	var pose := _actor(id)
	pose.anchor = at
	pose.facing = facing
	pose.state = state
	pose.downed = downed
	pose.rewind = rewind
	pose.haste = haste
	pose.hit_left = hit_left
	return pose

func _weapon_pose(pose: MatchFrame.Pose, type_id: int, aim: Vector2, facing: int, remaining: float) -> void:
	pose.weapon = type_id
	pose.reload_left = remaining
	if type_id != 0:
		pose.aim = GunBody.aim_transform(aim, facing, WeaponRegistry.definition(type_id)["pitch"])

func _local_pose(haste: bool, rewind: bool) -> MatchFrame.Pose:
	var pose := _player_pose(player.role, _frame.focus, player.facing_direction, player.state,
			player.sim_downed, rewind, haste, player.sim_iframes)
	pose.air_speed = 0.0 if player._grounded or player.in_water or player.climb_latched else player.velocity.y
	_splash(pose.id, player.collision_rect(), player.velocity)
	var weapon := player.equipped
	var aim := _aim_direction()
	_weapon_pose(pose, weapon.type_id if weapon != null else 0, aim,
			weapon.shot_facing if weapon != null else player.facing_direction, weapon.reload_left if weapon != null else 0.0)
	pose.charge = weapon.charge_ratio() if weapon != null else 0.0
	_frame.aim_guide = weapon.aim_guide(player, aim) if weapon != null else PackedVector2Array()
	return pose

func _splash(id: int, bounds: Rect2, velocity: Vector2) -> void:
	if _frame.now < float(_splash_after.get(id, 0.0)) or velocity.length_squared() < WCFG.water_fx_move_threshold ** 2:
		return
	var feet := Water.feet(bounds)
	var depth := terrain.water_depth(feet)
	if depth == -INF:
		return
	var surface := depth <= WCFG.water_fx_splash_band + bounds.size.y * 0.5
	_world.splash(feet - Vector2(0, depth if surface else 0.0), surface, _frame.now)
	_splash_after[id] = _frame.now + (WCFG.water_fx_splash_interval if surface else WCFG.water_fx_bubble_interval)

