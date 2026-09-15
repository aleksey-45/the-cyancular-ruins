extends Node2D
# PvP 远端玩家副本:视觉(复用 Player 的 SpriteFrames/动画 + 各武器场景外观),由快照驱动。
# ★ 它**不是**纯视觉:还带一个只参与碰撞的「幽灵体」(见 _build_ghost_body)。原因:C2 客户端预测
#   只步进自己的玩家,若客户端世界里没有对手身体,「对手挡住我」这条信息在预测侧根本不存在 →
#   本地预测穿过去、服务器把你挡住 → 每帧分歧、每帧回滚(C2 的无限回滚循环,不是调参能缓解的)。
#   幽灵体让预测所依据的世界与权威世界一致。★ 它只**减小**分歧不消除(副本位置是插值、落后约
#   一 tick),验收按「回滚次数下降多少」量,别按「归零」验收。
# pose/facing/aim/previewing/downed/weapon 按「最新快照」即时套用(反应不落后,位置才有插值)。
# 位置走「双快照 + tick 域 alpha 插值」:算法本身已收进 `core/snapshot_interp.gd`(SnapshotInterp,
# 2026-09-14 —— 此前本类与 enemy_replica 各有一份逐字同款;那段是环面插值的热点,CLAUDE.md 专门
# 记过教训,且有独立行为冒烟 tests/snapshot_interp_smoke.gd)。本类只负责:把勾子喂给它、
# 每帧推进时钟、以及把插值结果**锚到本地玩家(相机)最近副本**(保证渲染在可见副本,见 _process)。

const KEEP_TICKS := 8       # 位置缓冲保留窗口(最新前 8 tick;对手要更长的抗抖动窗,鸟只要 4)

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

# 幽灵体的姿态碰撞箱节点名:与 player.tscn / player.gd 的 POSE_NODE 逐字对应(同源,别改名)
const POSE_SHAPE: Dictionary = {
	0: "CollisionShape2D_stand", 1: "CollisionShape2D_move", 2: "CollisionShape2D_fly",
	3: "CollisionShape2D_charge", 4: "CollisionShape2D_squat",
}

# 幽灵体所在组:榴弹「碰到玩家」判定(见 bullet_base._check_player_contact)要把对手副本也算进候选。
# 单列一组而不是并进 "player":后者是「玩家实体」的语义,Explosion.apply_aoe 会遍历它逐个 take_hit、
# BulletBase._wrap 会取它第一个节点当锚点 —— 副本混进去会被当玩家结算/被当锚点。
const GROUP := "player_replica"

const HIT_FLASH_TIME := 0.35   # 受击闪烁时长(秒),闪烁频率对齐本地 iframe 眨眼感
const HIT_FLASH_RATE := 20.0

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var _weapon_slot_node: Node2D        # 武器挂点(运行时加,排在 AnimatedSprite2D 后 → 画在身体上层)
var _weapon: Node2D = null           # 当前武器场景实例(惰性:未 equip,仅外观)
var _weapon_slot_int := 0            # 服务器权威槽位
var _opponent_canonical := Vector2.ZERO   # 最新快照的服务器 canonical 位置(缓冲未满时直落用)
var _local_anchor := Vector2.ZERO         # 本地玩家(相机)位置,每帧跟随
var _have_data := false
var _facing := 1
var _aim := Vector2(1.0, 0.0)
var _previewing := false   # 对手是否正在预瞄(heavy 蓄力)。快照仍带该字段,但**不再驱动任何外观**
                           # ——预瞄红线只有使用者本人可见(用户裁定 2026-09-11);保留是给日后
                           # 想换成别的提示形式(音效/轮廓)时用,届时从 _drive_weapon_visual 接。
var _downed := false
var _hit_flash_t := 0.0

# ── 幽灵碰撞体(只碰撞、不参与任何逻辑)──
var _ghost: StaticBody2D = null
var _ghost_shapes: Dictionary = {}   # pose(int) -> CollisionPolygon2D

# ── 位置插值(算法在 core/snapshot_interp.gd;惰性构造见 _ensure_interp)──
var _interp: SnapshotInterp = null

func _ready() -> void:
	add_to_group(GROUP)
	# 复用 player.tscn 的内联 SpriteFrames —— 同一次实例化顺带把 5 份姿态碰撞多边形抄给幽灵体
	# (单一来源:日后改 player.tscn 的碰撞箱,副本自动跟上,不会漂)
	var tmp := preload("res://scenes/player/player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	_build_ghost_body(tmp)
	tmp.free()
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)

# 幽灵碰撞体:StaticBody2D(layer 2 = 玩家层,与 player.tscn 一致;mask 0 = 它不需要感知任何东西,
# 只被本地玩家的 move_and_slide 撞到)挂 5 份姿态多边形,形状从 player.tscn 现抄。
# 用 StaticBody2D 而不是 CharacterBody2D:副本自身不由物理驱动(位置由 _process 的插值决定),
# CharacterBody2D 会引入它自己的物理步进与 move_and_slide 竞争。作为副本子节点 → 位置/朝向/
# 环面回绕全自动跟随,无需任何额外代码。
func _build_ghost_body(src: Node) -> void:
	_ghost = StaticBody2D.new()
	_ghost.name = "GhostBody"
	_ghost.collision_layer = 2
	_ghost.collision_mask = 0
	add_child(_ghost)
	for pose in POSE_SHAPE:
		var from := src.get_node_or_null(POSE_SHAPE[pose]) as CollisionPolygon2D
		if from == null:
			continue   # player.tscn 改名了 → 少一份形状,不是致命(但 POSE_SHAPE 必须同步改)
		var poly := CollisionPolygon2D.new()
		poly.name = POSE_SHAPE[pose]
		poly.polygon = from.polygon
		poly.position = from.position
		poly.disabled = pose != 0
		_ghost.add_child(poly)
		_ghost_shapes[pose] = poly

# 幽灵体按姿态切换碰撞箱(与 player.gd 的 _coll_by_pose 同款)。形状必须跟姿态走:
# 否则蹲下躲进矮通道的对手仍按站姿挡路,预测侧又会与权威不一致。
func _set_ghost_pose(pose: int) -> void:
	for p in _ghost_shapes:
		(_ghost_shapes[p] as CollisionPolygon2D).disabled = p != pose

func apply_snapshot(data: Dictionary, local_anchor: Vector2, tick: int) -> void:
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
		# 幽灵体**不跟着变**:服务器侧 player.gd 的倒地分支在姿态碰撞箱切换之前就 return,
		# 尸体停在最后一个姿态的箱子上 —— 副本要同款,否则"倒地的对手还挡不挡路"两端不一致。
	else:
		rotation = 0.0
		var pose: int = clampi(int(data["pose"]), 0, POSE_SHAPE.size() - 1)
		animator.play(POSE_ANIM.get(pose, "idle"))
		_set_ghost_pose(pose)
	# ★ 幽灵体不随副本根节点的**视觉**转体而动。上面倒地分支给根节点设了 rotation = -90°,
	#   而幽灵体是它的子节点 → 会被一起转,碰撞箱跟着转 90°;但服务器侧 player.gd 的倒地分支
	#   **不旋转**(全文件零 rotation),尸体停在最后姿态的箱子上 → 两端"倒地的对手还挡不挡路"
	#   不一致。这里把幽灵体的**世界**旋转压回 0(等于给子节点一个抵消父节点的局部旋转),
	#   只让身体精灵转体。大乱斗 2s 一复活,倒地是常态,这是持续分歧源。
	if _ghost != null:
		_ghost.global_rotation = 0.0
	# 位置交给插值缓冲(pose/facing 等即时套用,位置平滑落后一小段,分毫不可感)
	_ensure_interp()
	_interp.push(tick, data["pos"])

# 惰性构造插值器:它要读地图尺寸,而尺寸由场景在 `GameParameters.refresh_map_size()` 之后才定下来。
# 放在 _ready 里会在「副本早于 refresh_map_size 创建」时**静默**拿到错的边界(环面回绕按错尺寸 →
# 出现空气墙),故推迟到**首次收到快照**才建 —— 那一定在场景 _ready 走完之后。
func _ensure_interp() -> void:
	if _interp == null:
		_interp = SnapshotInterp.new(KEEP_TICKS, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

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

# 枪口朝向/枪口仰角:委托 WeaponBase.drive_remote_visual(副本武器不 equip,由其驱动外观,
# 不读鼠标/不开火)。★ 预瞄红线**不在此画**(用户裁定 2026-09-11:只有使用者本人可见)。
func _drive_weapon_visual() -> void:
	if _weapon == null or not _weapon.has_method("drive_remote_visual"):
		return
	_weapon.drive_remote_visual(_aim, _facing)

func _process(delta: float) -> void:
	if _have_data:
		_drive_weapon_visual()
		if _interp != null and _interp.ready():
			_interp.advance(delta)
			var canonical := _interp.sample()
			# 插值出的 canonical 锚到本地玩家(相机)最近副本渲染:保证在可见副本。
			# 不做自身差分追赶——旧实现那句「最短向量=0 会卡在远副本」由这里直接锚定消解。
			global_position = MazeGenerator.anchor_to_nearest(canonical, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		else:
			# 缓冲未满(开场首个快照):直落最新权威位置,不做插值
			global_position = MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
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
