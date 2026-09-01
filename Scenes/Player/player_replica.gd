extends Node2D
# PvP 远端玩家副本:纯视觉(复用 Player 的 SpriteFrames/动画),由快照驱动 pose/facing/position。
# 不做物理(避免 set position 与物理引擎打架)。插值走最短路径(toroidal_delta_px)。

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

const INTERP_RATE := 12.0  # 指数插值速率(越大越跟手)

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var _opponent_canonical := Vector2.ZERO   # 对手服务器 canonical 位置
var _local_anchor := Vector2.ZERO         # 本地玩家(相机)位置,每帧跟随
var _have_data := false

func _ready() -> void:
	# 复用 Player.tscn 的内联 SpriteFrames
	var tmp := preload("res://Scenes/Player/Player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()

func apply_snapshot(data: Dictionary, local_anchor: Vector2) -> void:
	_opponent_canonical = data["pos"]
	_local_anchor = local_anchor
	_have_data = true
	animator.flip_h = int(data["facing"]) < 0
	if bool(data.get("downed", false)):
		animator.stop()
	else:
		var pose: int = int(data["pose"])
		animator.play(POSE_ANIM.get(pose, "idle"))

func _process(delta: float) -> void:
	if not _have_data:
		return
	# 目标副本 = 对手 canonical 锚到本地玩家(相机)最近副本,每帧重算(跟随相机跨接缝)。
	var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 当前渲染位置也锚到 target 副本空间,普通差量插值——
	# 关键修复:旧实现用 toroidal_delta_px(最短路径),当渲染位置与目标相隔整幅地图时最短向量=0,
	# 副本一旦落到远处副本就永远留在那(对手渲染到屏幕外 = "看不见对方")。
	var current := MazeGenerator.anchor_to_nearest(global_position, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
	# 渲染位置归到本地玩家(相机)最近副本:确保渲染在可见副本,不留在远副本。
	global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
