class_name MatchFrame
extends RefCounted

enum Mode { SOLO, DUEL, TEAM, ROYALE }

class Pose:
	var id: int
	var remote: bool
	var anchor: Vector2
	var scale := Vector2.ONE * PlayerParams.body_scale
	# 有 SpriteFrames 时，WorldView 使用该敌人类型的动画资源。未设置时使用玩家的共享动画。
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

var now := 0.0
var day_minute := Daylight.minute_at(0.0)
var mode := Mode.SOLO
var focus: Vector2
var actors: Array[Pose] = []
# 掉落物按类型、显示位置和可拾取状态记录。弹丸按 ID、类型、显示位置和旋转角度记录。
var pickups: Array[Array] = []
var projectiles: Array[Array] = []
# 每条光束取自对应模拟帧，保存路径和本帧透明度。
var beams: Array[Array] = []
var wall_changes: Dictionary = {}
var aim_guide := PackedVector2Array()
var health: int
var max_health: int
var oxygen: int
var max_oxygen: int
var downed: bool
var hit_ratio := 0.0
var kills := 0
# 武器栏使用 WeaponInventory.cell_layout() 的返回值。剩余弹药和弹匣容量另存为字段。
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
	beams.clear()

func sample_beam(beam: Array, tick: float) -> void:
	var remaining := float(beam[CombatSimulator.Beam.END_TICK]) - tick
	if remaining > 0.0 and remaining <= CombatSimulator.BEAM_TICKS:
		beams.append([beam[CombatSimulator.Beam.POINTS], minf(remaining * ActorStep.DT / 0.12, 1.0)])
