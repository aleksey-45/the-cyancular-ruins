class_name DrawFrame
extends RefCounted

## 发布后由实况、片段和视图共享。世界图元中的贴图索引指向本场的纹理表。
var time: float
var camera: Vector2
var walls: PackedByteArray
var water: Vector2
var world: Dictionary
var hud: Dictionary
var post: Dictionary

func _init(at: float, center: Vector2, mask: PackedByteArray, water_state: Vector2,
		drawing: Dictionary, panel: Dictionary, screen: Dictionary) -> void:
	time = at
	camera = center
	walls = mask
	water = water_state
	world = drawing
	hud = panel
	post = screen
