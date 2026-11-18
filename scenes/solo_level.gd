class_name SoloLevel
extends MatchController

var spawn_cell: Vector2i
var enabled_weapons: Array[int]
var combat_rules: CombatSimulator
var time_field := TimeField.new(GrainAccount.new())
var _rewind: WorldRewind
var _weapon_floors: Array[Vector2i]
var _kills := 0
@onready var _pickups := GroundWeaponField.new(world_viewport, time_field)

func _ready() -> void:
	super()
	process_physics_priority = -100 # 提交上一个 tick 的地形和历史，确定本 tick 的时间模式。
	combat_rules = CombatSimulator.new(terrain, world_viewport)
	combat_rules.time_field = time_field
	player.combat_rules = combat_rules
	player.ground_actions = _pickups.handle_actions
	player.projectile_count = combat_rules.count_projectiles.bind(player)
	EnemySpawner.load_types()
	_weapon_floors = SpawnPicker.floor_cells(map_info["grid"], map_info["size"])
	player.weapons.enabled_types = enabled_weapons
	player.restart_requested.connect(restart_single, CONNECT_DEFERRED)
	_mount(Mode.SOLO, time_field.account)
	_bind_combat()
	_start_single()

func _bind_combat() -> void:
	time_field.grain_received.connect(_view.watch.tremble)
	time_field.account.loan_locked.connect(_view.watch.flash_locked)
	combat_rules.grain_dropped.connect(func(at: Vector2) -> void:
		_world.grain(at, _frame.now, TimeParams.ELITE_GRAIN_DELAY_TICKS * ActorStep.DT))
	combat_rules.detonated.connect(func(_id: int, at: Vector2, type_id: int, cells: PackedInt32Array) -> void:
		_blast(at, type_id, cells))
	combat_rules.fired.connect(func(shot: Dictionary) -> void:
		if WeaponRegistry.definition(shot["type_id"])["attack"] == WeaponRegistry.Attack.BEAM:
			_show_beam(shot["vectors"]))
	combat_rules.tile_hit.connect(func(at: Vector2, type_id: int) -> void:
		_world.debris(at, type_id, _frame.now))
	combat_rules.player_hit.connect(func(_source: int, victim: Player, damage: int,
			_knock_changed: bool, _force: float) -> void:
		if damage > 0:
			_damage(damage)
			_world.hit(victim.get_instance_id(), victim.global_position, damage, true))
	combat_rules.npc_hit.connect(func(source: Node, victim: EnemyBase, damage: int) -> void:
		if source is Player:
			_view.feedback.show_hit()
			_world.hit(victim.get_instance_id(), victim.global_position, damage, false))
	combat_rules.projectile_hit_npc.connect(func(type_id: int) -> void:
		var sound: String = WeaponRegistry.projectile_definition(type_id)["npc_hit_sound"]
		if not sound.is_empty():
			Sfx.play(sound))

func _physics_process(delta: float) -> void:
	# 本帧新建的弹丸和掉落物从下一帧开始移动。按场景中的顺序推进已有实体。
	var bodies := world_viewport.get_children()
	terrain.flush_collisions()
	time_field.step_rewards()
	var input := LocalInputSource.sample(player.input_frozen)
	_drive_time(delta, input[ActorInput.HELD])
	_rewind.advance(delta, time_field.is_rewinding())
	var from := player.global_position
	combat_rules.submit(player, ActorStep.step(player, _input_record(input, delta), delta))
	# 掉落物在各自的物理步进前选好环面副本。
	var anchor := player.global_position
	for pickup: WeaponPickup in _pickups.items.values():
		pickup.place_near(anchor)
	_live_step(from, player.presentation_events)
	var pickup_delta := time_field.world_delta(delta)
	for body: Node in bodies:
		if body is EnemyBase and body.active:
			body.simulate_tick(delta)
		elif body is WeaponPickup:
			body.simulate_tick(pickup_delta)
		elif body is BulletBody and combat_rules.projectiles.get(body.entity_id) == body:
			combat_rules.step_projectile(body, delta)

func _process(delta: float) -> void:
	var anchor := player.global_position
	var size := terrain.map_size
	var haste := time_field.is_hasting()
	var rewind := time_field.is_rewinding()
	_begin_frame(delta, anchor, haste, rewind)
	_frame.kills = _kills
	_local_pose(haste, rewind)
	for enemy: EnemyBase in EnemyBase.in_viewport(world_viewport):
		if enemy.active:
			_enemy_pose(enemy, anchor, size, haste, rewind)
	var now := Time.get_ticks_msec()
	for pickup: WeaponPickup in _pickups.items.values():
		var offset := GridPathfinder.toroidal_delta_px(anchor, pickup.canonical_pos, size)
		var can := GroundWeaponField.in_pickup_range(offset.length()) and GroundWeaponField.can_pick_up(
			player, pickup.type_id, pickup.locked_role, pickup.unlock_at, now)
		_frame.pickups.append([pickup.type_id, anchor + offset, can])
	for bullet: BulletBody in combat_rules.projectiles.values():
		var at := GridPathfinder.anchor_to_nearest(bullet.position, anchor, size)
		_frame.projectiles.append([bullet.entity_id, bullet.type_id, at, bullet.rotation])
	_view.present(delta, _frame)

func _enemy_pose(enemy: EnemyBase, anchor: Vector2, size: Vector2, haste: bool, rewind: bool) -> void:
	var pose := _actor(enemy.get_instance_id())
	pose.anchor = GridPathfinder.anchor_to_nearest(enemy.global_position, anchor, size)
	pose.scale = enemy.scale
	pose.frames = enemy.sprite_frames
	pose.state = enemy.activity
	pose.facing = -1 if enemy.facing_left else 1
	pose.downed = enemy.is_dead
	pose.haste = haste
	pose.rewind = rewind
	pose.elite = enemy.has_meta("elite")
	pose.black_bird = enemy is EnemyBlackBird
	pose.air_speed = 0.0 if enemy._grounded else enemy.velocity.y
	pose.hit_left = maxf(enemy.hit_reaction_left, enemy.corpse_left)
	if enemy is EnemyJumpBird:
		pose.lunge_age = EnemyJumpBird.DASH_TIMEOUT - enemy._dash_timer
	_splash(pose.id, enemy.collision_rect(), enemy.velocity)

func restart_single() -> void:
	terrain.reset()
	_view.terrain_view.patch(terrain.take_wall_changes())
	time_field.mode = TimeField.Mode.NONE
	combat_rules.clear()
	for enemy: EnemyBase in EnemyBase.in_viewport(world_viewport):
		enemy.queue_free()
	_pickups.clear()
	_reset_view()
	_start_single()

func _start_single() -> void:
	_rewind = WorldRewind.new(combat_rules, player)
	player.spawn_at(spawn_cell)
	player.sim_iframes = 0.0
	player._controls_locked = false
	player.weapons.set_initial_inventory([enabled_weapons[0]])
	for enemy in EnemySpawner.spawn_all(map_info["spawns"]["enemies"], world_viewport, combat_rules):
		enemy.set_physics_process(false)
		enemy.died.connect(_count_kill)
		var id := enemy.get_instance_id()
		enemy.motion.connect(func(kind: StringName, speed: float) -> void:
			_world.motion(id, kind, _frame.now, speed))
	_pickups.scatter(terrain, _weapon_floors, enabled_weapons)

func _count_kill() -> void:
	_kills += 1

const TIME_BUTTONS := ActorInput.BIT_REWIND | ActorInput.BIT_HASTE
var _prev_time_buttons := 0

func _drive_time(delta: float, held: int) -> void:
	var buttons := held & TIME_BUTTONS
	if not time_field.account.can_spend() and (buttons & ~_prev_time_buttons) != 0:
		Sfx.play("deny")
	_prev_time_buttons = buttons
	time_field.update(delta, (buttons & ActorInput.BIT_REWIND) != 0 and _rewind.can_rewind(),
			(buttons & ActorInput.BIT_HASTE) != 0)

