extends Node


const gravity0: float = 1600.0
const TILE_SIZE: int = 64

const water_sway_amp: float = 2.0
const water_sway_speed: float = 1.6
const water_bullet_drag: float = 2.0
const water_fx_move_threshold: float = 40.0
const water_fx_splash_band: float = 20.0
const water_fx_splash_interval: float = 0.15
const water_fx_bubble_interval: float = 0.12
const water_enter_depth: float = 8.0
const water_exit_depth: float = -2.0
const water_drain_interval: float = 1.0
const water_recover_interval: float = 0.3
const water_drown_damage_interval: float = 1.5

var MAP_WIDTH: int
var MAP_HEIGHT: int

func _ready() -> void:
	refresh_map_size()

func refresh_map_size() -> void:
	var cells := MazeGenerator.map_size()
	MAP_WIDTH = cells.x * TILE_SIZE
	MAP_HEIGHT = cells.y * TILE_SIZE
