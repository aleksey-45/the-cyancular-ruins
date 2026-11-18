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

static var paths: Dictionary[String, String] = {}

static func _static_init() -> void:
	for entry: Dictionary in JSON.parse_string(FileAccess.get_file_as_string("res://data/enemies.json"))["enemies"]:
		paths[entry["id"]] = entry["scene"]
