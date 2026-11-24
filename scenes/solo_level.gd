class_name SoloLevel
extends MatchController

const DEATH_REWIND_SECONDS := 4.0
const MIN_DEATH_REWIND_SECONDS := 0.5

var spawn_cell: Vector2i
var enabled_weapons: Array[int]
var time_field := TimeField.new(GrainAccount.new())
var preview_minute := -1.0
var _rewind: RewindHistory
var _death_rewind_end := -1.0
var _weapon_floors: Array[Vector2i]
var _kills := 0

static func create(document: Dictionary, spawn: Vector2i, weapons: Array[int]) -> SoloLevel:
	var scene: PackedScene = load("res://scenes/level_0.tscn")
	var level: SoloLevel = scene.instantiate()
	level.map = document
	level.spawn_cell = spawn
	level.enabled_weapons = weapons
	return level

func _ready() -> void:
	combat_rules = CombatSimulator.new(terrain)
	combat_rules.time_field = time_field
	player = combat_rules.add_player(1)
	_weapon_floors = SpawnPicker.floor_cells(map)
	player.weapons.enabled_types = enabled_weapons
	_mount(Mode.SOLO, time_field.account)
	_bind_combat()
	_start_single()

func _input(event: InputEvent) -> void:
	# 死亡倒带优先于旧的模拟回溯：Recorder 负责画面回放，回放完自己 restart_single。
	var recorder: Node = get_node_or_null("View/Recorder")
	if recorder != null:
		if recorder.is_replaying():
			return
		if event.is_action_pressed(&"R") and event.is_pressed() and recorder.start_rewind():
			get_viewport().set_input_as_handled()
			return
	var replaying := _death_rewind_end >= 0.0
	if not replaying and (not player.sim_downed or not event.is_action_pressed(&"R")):
		return
	get_viewport().set_input_as_handled()
	if not event.is_pressed():
		return
	# 消耗本次按键的轮询状态，避免它传入新一局。
	for action in InputMap.get_actions():
		if event.is_action(action):
			Input.action_release(action)
	if event.is_echo():
		return
	if not replaying:
		var oldest := _rewind.oldest_time()
		_death_rewind_end = _rewind.time
		if _rewind.time - oldest >= MIN_DEATH_REWIND_SECONDS:
			_death_rewind_end = maxf(oldest, _rewind.time - DEATH_REWIND_SECONDS)
	elif event.is_action_pressed(&"R") or event.is_action_pressed(&"ui_cancel") \
			or (event is InputEventKey and (event.keycode == KEY_SPACE or event.physical_keycode == KEY_SPACE)) \
			or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		_death_rewind_end = _rewind.time

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
	if _death_rewind_end >= 0.0:
		if _rewind.time <= _death_rewind_end:
			restart_single()
		else:
			time_field.mode = TimeField.Mode.REWIND
			_rewind.rewind(delta, false)
		return
	var input := controls.sample()
	if not time_field.account.can_spend() and (Input.is_action_just_pressed(&"rewind") or Input.is_action_just_pressed(&"haste")):
		Sfx.play("deny")
	time_field.step(input[ActorInput.HELD], delta, _rewind, not player.sim_downed)
	var from := player.position
	combat_rules.step({player.role: _input_record(input, delta)})
	_live_step(from, player.presentation_events)

func _process(delta: float) -> void:
	var anchor := player.position
	var size := terrain.map_size
	var haste := time_field.is_hasting()
	var rewind := time_field.is_rewinding()
	_begin_frame(delta, anchor, haste, rewind)
	_frame.day_minute = preview_minute if preview_minute >= 0.0 else Daylight.minute_at(time_field.elapsed)
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
	_death_rewind_end = -1.0
	controls = LocalInputSource.new()
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
	for entry: Dictionary in map.points.values():
		if entry.kind != "enemy": continue
		var type_id: String = entry["type"]
		var enemy := combat_rules.add_enemy(type_id, player, CyrmMap.world_position(entry.cell))
		enemy.died.connect(_count_kill)
		var id := -1 - enemy.slot
		enemy.motion.connect(func(kind: StringName, speed: float) -> void:
			_world.motion(id, kind, _frame.now, speed))
	_rewind = RewindHistory.new(combat_rules)
	combat_rules.ground.scatter(_weapon_floors, enabled_weapons)

func _count_kill() -> void:
	_kills += 1
