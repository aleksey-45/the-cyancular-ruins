class_name SoloLevel
extends MatchController

var spawn_cell: Vector2i
var enabled_weapons: Array[int]
var time_field := TimeField.new(GrainAccount.new())
var _rewind: RewindHistory
var _weapon_floors: Array[Vector2i]
var _kills := 0

func _ready() -> void:
	combat_rules = CombatSimulator.new(terrain)
	combat_rules.time_field = time_field
	player = combat_rules.add_player(1)
	_weapon_floors = SpawnPicker.floor_cells(map_info["grid"], map_info["size"])
	player.weapons.enabled_types = enabled_weapons
	_mount(Mode.SOLO, time_field.account)
	_bind_combat()
	_start_single()

func _unhandled_input(event: InputEvent) -> void:
	super(event)
	if player.sim_downed and event.is_action_pressed(&"R"):
		restart_single.call_deferred()

func _bind_combat() -> void:
	time_field.grain_received.connect(_view.watch.tremble)
	time_field.account.loan_locked.connect(_view.watch.flash_locked)
	combat_rules.grain_dropped.connect(func(at: Vector2) -> void:
		_world.grain(at, _frame.now, TimeParams.ELITE_GRAIN_DELAY_TICKS * ActorStep.DT))
	combat_rules.detonated.connect(func(_id: int, at: Vector2, type_id: int) -> void:
		_blast(at, type_id))
	combat_rules.tile_hit.connect(func(at: Vector2, type_id: int) -> void:
		_world.debris(at, type_id, _frame.now))
	combat_rules.player_hit.connect(func(_source: int, victim: Player, damage: int,
			_knock_changed: bool, _force: float) -> void:
		if damage > 0:
			_damage(damage)
			_world.hit(victim.role, victim.position, damage, true))
	combat_rules.npc_hit.connect(func(source: ActorBody, victim: EnemyBase, damage: int) -> void:
		if source is Player:
			_view.feedback.show_hit()
			_world.hit(-1 - victim.slot, victim.position, damage, false))
	combat_rules.projectile_hit_npc.connect(func(type_id: int) -> void:
		var sound: String = WeaponRegistry.projectile_definition(type_id)["npc_hit_sound"]
		if not sound.is_empty():
			Sfx.play(sound))

func _physics_process(delta: float) -> void:
	var input := controls.sample()
	if not time_field.account.can_spend() and (Input.is_action_just_pressed(&"rewind") or Input.is_action_just_pressed(&"haste")):
		Sfx.play("deny")
	time_field.step(input[ActorInput.HELD], delta, _rewind)
	var from := player.position
	combat_rules.step({player.role: _input_record(input, delta)})
	_live_step(from, player.presentation_events)

func _process(delta: float) -> void:
	var anchor := player.position
	var size := terrain.map_size
	var haste := time_field.is_hasting()
	var rewind := time_field.is_rewinding()
	_begin_frame(delta, anchor, haste, rewind)
	_frame.kills = _kills
	_local_pose(haste, rewind)
	for enemy: EnemyBase in combat_rules.enemies:
		if enemy.active:
			_enemy_pose(enemy, anchor, size, haste, rewind)
	for pickup: WeaponPickup in combat_rules.ground.items.values():
		_show_pickup(pickup.position, pickup.type_id, pickup.locked_role, pickup.unlock_tick, combat_rules.ground.tick)
	for bullet: BulletBody in combat_rules.projectiles.values():
		var at := GridPathfinder.anchor_to_nearest(bullet.position, anchor, size)
		_frame.projectiles.append([bullet.entity_id, bullet.type_id, at, bullet.transform.get_rotation()])
	_view.present(delta, _frame)

func _enemy_pose(enemy: EnemyBase, anchor: Vector2, size: Vector2, haste: bool, rewind: bool) -> void:
	var pose := _actor(-1 - enemy.slot)
	pose.anchor = GridPathfinder.anchor_to_nearest(enemy.position, anchor, size)
	pose.scale = enemy.scale
	pose.frames = enemy.kind.frames
	pose.state = enemy.activity
	pose.facing = -1 if enemy.facing_left else 1
	pose.downed = enemy.is_dead
	pose.haste = haste
	pose.rewind = rewind
	pose.elite = enemy.kind.elite
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
	combat_rules.clear_enemies()
	combat_rules.ground.clear()
	_reset_view()
	_start_single()

func _start_single() -> void:
	player.spawn_at(spawn_cell)
	player.sim_iframes = 0.0
	player._controls_locked = false
	player.weapons.set_initial_inventory([enabled_weapons[0]])
	for entry: Dictionary in map_info["spawns"]["enemies"]:
		var type_id: String = entry["type"]
		var enemy := combat_rules.add_enemy(type_id, player, terrain.cell_center(entry["cell"]))
		enemy.died.connect(_count_kill)
		var id := -1 - enemy.slot
		enemy.motion.connect(func(kind: StringName, speed: float) -> void:
			_world.motion(id, kind, _frame.now, speed))
	_rewind = RewindHistory.new(combat_rules)
	combat_rules.ground.scatter(_weapon_floors, enabled_weapons)

func _count_kill() -> void:
	_kills += 1
