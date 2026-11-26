class_name EnemyType
extends Resource

@export var ai: GDScript
@export var frames: SpriteFrames
@export var hulls: Array[ConvexPolygonShape2D]
@export var body_scale: float
@export var hp: int
@export var elite: bool
@export var contact_damage: int
@export var contact_size := Vector2(44, 40)
@export var contact_offset := Vector2.ZERO

const PATHS := {
	"jump_bird": "res://scenes/enemies/enemy_jump_bird.tres",
	"fly_bird": "res://scenes/enemies/enemy_fly_bird.tres",
	"black_bird": "res://scenes/enemies/enemy_black_bird.tres",
}

static func get_type(id: String) -> EnemyType:
	return load(PATHS[id])
