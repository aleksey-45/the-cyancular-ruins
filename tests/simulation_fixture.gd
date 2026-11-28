extends "res://tests/case.gd"

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")
const ECFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const NEUTRAL_INPUT := [0.0, 0, 0, 0, 0, Vector2.RIGHT]
const FORWARD_INPUT := [1.0, 0, 0, 0, 0, Vector2.RIGHT]

const POS: int = PlayerStateSchema.POS
const FLOOR: int = PlayerStateSchema.GROUNDED
const INV: int = PlayerStateSchema.INVENTORY

func _place(actor: Player, at: Vector2, team: int = 0) -> void:
	actor.team = team
	actor.position = at
	collider(actor, CollisionWorld.team_layer(team))
	actor.sync_collision_geometry()

func _attack(held: int, pressed: int, released := 0) -> Array:
	return [0.0, held, pressed, released, 0, Vector2.RIGHT]

func step_actions(actor: Player, record: Array, delta := ActorStep.DT) -> Array:
	ActorStep.step(actor, record, delta)
	return actor.combat_requests

func submit(actor: Player, requests: Array) -> void:
	actor.combat_requests = requests
	actor.combat.resolve_requests([actor.role])

func _fires(actions: Array) -> Array:
	return actions.filter(func(action: Dictionary) -> bool: return action["kind"] == "fire")

class ActorDisplay extends Node:
	var _frame: MatchFrame
	var _world: WorldView
	var drawing: Dictionary
	var presenter: MatchPresenter

func _display(parent: TestWorld, actor: Player) -> ActorDisplay:
	var display := ActorDisplay.new()
	var spec := WorldSpec.solo(parent.document, Vector2i.ZERO, [WeaponType.RIFLE], 0)
	display.presenter = MatchPresenter.new(spec, parent.terrain, actor.role, null)
	display._frame = display.presenter.frame
	display._world = display.presenter.world
	return display

func _draw_actor(display: ActorDisplay, actor: Player) -> void:
	var row := actor.capture_state()
	var frame := display._frame
	frame.begin(frame.now, actor.position)
	var presenter := display.presenter
	presenter._player_pose(actor.role, actor.position, actor.velocity, row, row, Vector2.RIGHT, false, false)
	presenter._player_cues(actor.role, row, row, actor.position, false)
	presenter._actors = {actor.role: row}
	presenter._health = row
	frame.aim_guide = presenter._aim_guide(row, frame.actors[0], false)
	for cue: Array in frame.cues:
		if cue[0] == "motion":
			display._world.motion(cue[1], cue[2], frame.now, cue[3])
	display.drawing = display._world.build(frame)

func _record_time(sim: CombatSimulator, actor: Player, delta := 1.0 / TCFG.SNAP_HZ) -> void:
	sim.time_field.history.record(delta, sim.tick, sim.time_field._sample.bind(sim, actor))
