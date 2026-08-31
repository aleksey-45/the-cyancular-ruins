extends Node2D
# PvP 远端玩家副本:纯视觉(复用 Player 的 SpriteFrames/动画),由快照驱动 pose/facing/position。
# 不做物理(避免 set position 与物理引擎打架)。插值走最短路径(toroidal_delta_px)。

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

const INTERP_RATE := 12.0  # 指数插值速率(越大越跟手)

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var _target := Vector2.ZERO
var _have_target := false

func _ready() -> void:
	# 复用 Player.tscn 的内联 SpriteFrames
	var tmp := preload("res://Scenes/Player/Player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()

func apply_snapshot(data: Dictionary, local_anchor: Vector2) -> void:
	var canonical: Vector2 = data["pos"]
	# 目标副本 = 锚到本地玩家最近副本
	_target = MazeGenerator.anchor_to_nearest(canonical, local_anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_have_target = true
	animator.flip_h = int(data["facing"]) < 0
	if bool(data.get("downed", false)):
		animator.stop()
	else:
		var pose: int = int(data["pose"])
		animator.play(POSE_ANIM.get(pose, "idle"))

func _process(delta: float) -> void:
	if not _have_target:
		return
	# 最短路径插值:增量 = 当前渲染位置 → 目标副本位置的最短向量 × 插值系数
	var d := MazeGenerator.toroidal_delta_px(global_position, _target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position += d * (1.0 - exp(-INTERP_RATE * delta))
