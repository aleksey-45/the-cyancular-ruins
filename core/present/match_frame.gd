class_name MatchFrame
extends RefCounted

enum Mode { SOLO, DUEL, TEAM, ROYALE }

class Pose:
	var id: int
	var anchor: Vector2
	var scale := Vector2(2.5, 2.5)
	# 敌人使用场景提供的资源和 Activity，玩家使用默认资源和移动状态。
	var frames: SpriteFrames
	var state: int
	var facing := 1
	var downed: bool
	var haste: bool
	var rewind: bool
	var elite: bool
	var black_bird: bool
	var air_speed := 0.0
	var hit_left := 0.0
	var lunge_age := 0.0
	var hue := 0.0
	var weapon := 0
	var aim := Transform2D.IDENTITY
	var reload_left := 0.0
	var name := ""
	var team: int
	var health := -1.0

	func name_color(mode: Mode) -> Color:
		if mode == Mode.ROYALE:
			var base := UiFactory.C_TEAM_A
			return Color.from_hsv(fposmod(base.h + hue, 1.0), base.s, base.v)
		return UiFactory.C_TEAM_A if team == 1 else UiFactory.C_TEAM_B

class Clock:
	var balance: float
	var cap: float
	var allowance: int
	var borrowed: bool
	var long_turns: float
	var loan_depth: float
	var rewind: bool
	var haste: bool

class Beam:
	var points: PackedVector2Array
	var until: float

var now := 0.0
var mode := Mode.SOLO
var camera_at: Vector2
var focus: Vector2
var actors: Array[Pose] = []
# 拾取行是 [类型, 位置, 显示提示]，弹丸行是 [ID, 类型, 位置, 朝向]。
var pickups: Array[Array] = []
var projectiles: Array[Array] = []
var beams: Array[Beam] = []
var wall_changes: Dictionary = {}
var aim_guide := PackedVector2Array()
var health: int
var max_health: int
var oxygen: int
var max_oxygen: int
var downed: bool
var hit_ratio := 0.0
var kills := 0
# [选中槽位, 容量, (武器类型, 占位数)...]。弹药变化独立更新。
var inventory := PackedInt32Array()
var ammo := -1
var magazine := 0
var drop_progress: float
var clock: Clock
var trajectories: bool
var radar_players: bool

func begin(delta: float, local_at: Vector2) -> void:
	now += delta
	focus = local_at
	actors.clear()
	pickups.clear()
	projectiles.clear()
	for i in range(beams.size() - 1, -1, -1):
		if beams[i].until <= now:
			beams.remove_at(i)

func add_beam(points: PackedVector2Array) -> Beam:
	var beam := Beam.new()
	beam.points = points
	beam.until = now + 0.25
	beams.append(beam)
	return beam
