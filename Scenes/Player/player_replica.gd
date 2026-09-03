extends Node2D
# PvP 远端玩家副本:纯视觉(复用 Player 的 SpriteFrames/动画 + 各武器场景外观),由快照驱动
# pose/facing/position/weapon/aim/downed。不做物理(避免 set position 与物理引擎打架)。
# 插值走最短路径(toroidal_delta_px 见下);武器/受击/倒地都是快照/事件驱动的视觉。

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

const INTERP_RATE := 12.0  # 指数插值速率(越大越跟手)
const HIT_FLASH_TIME := 0.35   # 受击闪烁时长(秒),闪烁频率对齐本地 iframe 眨眼感
const HIT_FLASH_RATE := 20.0

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var _weapon_slot_node: Node2D        # 武器挂点(运行时加,排在 AnimatedSprite2D 后 → 画在身体上层)
var _weapon: Node2D = null           # 当前武器场景实例(惰性:未 equip,仅外观)
var _weapon_slot_int := 0            # 服务器权威槽位
var _opponent_canonical := Vector2.ZERO   # 对手服务器 canonical 位置
var _local_anchor := Vector2.ZERO         # 本地玩家(相机)位置,每帧跟随
var _have_data := false
var _facing := 1
var _aim := Vector2(1.0, 0.0)
var _previewing := false   # 对手是否正在预瞄(heavy 蓄力):驱动副本武器的预瞄红线/弧
var _downed := false
var _hit_flash_t := 0.0

func _ready() -> void:
	# 复用 Player.tscn 的内联 SpriteFrames
	var tmp := preload("res://Scenes/Player/Player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)

func apply_snapshot(data: Dictionary, local_anchor: Vector2) -> void:
	_opponent_canonical = data["pos"]
	_local_anchor = local_anchor
	_have_data = true
	_facing = 1 if int(data.get("facing", 1)) >= 0 else -1
	var aim: Vector2 = data.get("aim", Vector2.ZERO)
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	animator.flip_h = _facing < 0
	# 武器:槽位变了才重建(玩家每次换枪服务器快照带新槽位)
	var slot := int(data.get("weapon", 0))
	if slot > 0 and slot != _weapon_slot_int:
		_swap_weapon(slot)
	_previewing = bool(data.get("previewing", false))
	_downed = bool(data.get("downed", false))
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)   # 倒地转体(与 player._downed 一致)
	else:
		rotation = 0.0
		var pose: int = int(data["pose"])
		animator.play(POSE_ANIM.get(pose, "idle"))

# 服务器裁决命中:打的是对手 → 副本受击反馈(白闪/眨眼),让射手看到"打中了"。
func play_hit(_source_pos: Vector2) -> void:
	_hit_flash_t = HIT_FLASH_TIME

# 按槽位换武器外观:只挂 WeaponBase 场景做静物(不 equip → 其 _process 因 player==null 早退,惰性)。
func _swap_weapon(slot: int) -> void:
	_weapon_slot_int = slot
	if _weapon != null:
		_weapon.queue_free()
		_weapon = null
	var scene_path: String = WeaponComponent.WEAPONS.get(str(slot), "")
	if scene_path == "":
		return
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return
	_weapon = scene.instantiate()
	_weapon_slot_node.add_child(_weapon)

# 枪口朝向 + 预瞄线/弧:委托 WeaponBase.drive_remote_visual(副本武器不 equip,由其驱动外观,
# 不读鼠标/不开火)。倒地时隐藏预瞄(与单机 combat.went_down→cancel_aim 一致)。
func _drive_weapon_visual() -> void:
	if _weapon == null or not _weapon.has_method("drive_remote_visual"):
		return
	_weapon.drive_remote_visual(_aim, _facing, _previewing and not _downed)

func _process(delta: float) -> void:
	if _have_data:
		_drive_weapon_visual()
		# 目标副本 = 对手 canonical 锚到本地玩家(相机)最近副本,每帧重算(跟随相机跨接缝)。
		var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# 当前渲染位置也锚到 target 副本空间,普通差量插值——
		# 关键修复:旧实现用 toroidal_delta_px(最短路径),当渲染位置与目标相隔整幅地图时最短向量=0,
		# 副本一旦落到远副本就永远留在那(对手渲染到屏幕外 = "看不见对方")。
		var current := MazeGenerator.anchor_to_nearest(global_position, target,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
		# 渲染位置归到本地玩家(相机)最近副本:确保渲染在可见副本,不留在远副本。
		global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 受击闪烁:本地玩家被打是 iframe 半透明眨眼,副本同款(看得见"打中了")。
	if _hit_flash_t > 0.0:
		_hit_flash_t = maxf(_hit_flash_t - delta, 0.0)
		var on := int(_hit_flash_t * HIT_FLASH_RATE) % 2 == 0
		modulate.a = 0.4 if on else 1.0
		if _hit_flash_t <= 0.0:
			modulate.a = 1.0
	elif modulate.a != 1.0:
		modulate.a = 1.0
