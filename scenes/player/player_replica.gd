extends Node2D
# PvP 远端玩家副本:纯视觉(复用 Player 的 SpriteFrames/动画 + 各武器场景外观),由快照驱动。
# pose/facing/aim/previewing/downed/weapon 按「最新快照」即时套用(反应不落后,位置才有插值)。
# 位置走「双快照 + 时间轴 alpha 插值」:缓冲最近若干 canonical 位置,渲染时钟落后最新约 1 tick,
# 期间按真实时间在相邻两帧快照间线性插值——比原指数追赶更快跟手、且无「速度相关滞后」。
# 时钟只在 tick 域走(服务器恒定 60Hz),不依赖两端时钟同步;丢包/卡顿 → 冻结在最新已收到位置,
# 下一个快照到达把时钟重置到「最新 - 1」窗口继续,不会倒退。相邻快照在环面上可能跨接缝,
# 取 toroidal 最短向量插值后取模回 canonical,最后锚到本地玩家(相机)最近副本渲染(见 _process)。

const SNAPSHOT_HZ := 60.0   # 服务器快照频率(恒定):渲染时钟的时间轴刻度,与 tick 一一对应
const KEEP_TICKS := 8       # 位置缓冲保留窗口(最新前 N tick;够插值 + 顶住小丢包)

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

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

# ── 位置插值缓冲 ──
var _pos_hist: Dictionary = {}     # 服务器 tick(int) → canonical 位置(只留最近 KEEP_TICKS)
var _tick_list: Array = []         # _pos_hist 的键升序缓存(小数组,推入后重建)
var _last_tick := 0                # 已入缓冲的最大 tick(丢弃乱序/重复)
var _render_tick := -1.0           # 渲染时钟(服务器 tick 域,浮点);-1 = 缓冲未满、尚未起步

func _ready() -> void:
	# 复用 Player.tscn 的内联 SpriteFrames
	var tmp := preload("res://scenes/player/Player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)

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
	else:
		rotation = 0.0
		var pose: int = int(data["pose"])
		animator.play(POSE_ANIM.get(pose, "idle"))
	# 位置交给插值缓冲(pose/facing 等即时套用,位置平滑落后一小段,分毫不可感)
	_push_position(tick, data["pos"])

# 入缓冲:只收递增 tick。每收一个新快照就把渲染时钟重置到「最新 - 1」起点——之后各帧按真实时间
# 累进扫完这个最新区间(tick 越密集/渲染帧越多,alpha 越细分越平滑)。时钟过快越过最新 → 冻结,
# 快照续上重置即恢复,不累积漂移、不回退。
func _push_position(tick: int, pos: Vector2) -> void:
	if tick <= _last_tick:
		return
	_last_tick = tick
	_pos_hist[tick] = pos
	var drop_below := tick - KEEP_TICKS
	for k in _pos_hist.keys():
		if k < drop_below:
			_pos_hist.erase(k)
	_tick_list = _pos_hist.keys()
	_tick_list.sort()
	if _tick_list.size() >= 2:
		_render_tick = float(_tick_list[-1]) - 1.0

# 在 tick 域取插值位置:clock 落在哪两个相邻快照之间就线性插哪个;跨接缝取最短向量后取模回 canonical。
# clock 越过已收到的最新(丢包/卡顿间隙)→ 冻结在最新;缓冲最前之前 → 冻结最早。
func _sample_position(clock: float) -> Vector2:
	var i := _tick_list.size() - 1
	while i > 0 and float(_tick_list[i]) > clock:
		i -= 1
	var a: int = _tick_list[i]
	var pa: Vector2 = _pos_hist[a]
	if i + 1 >= _tick_list.size():
		return pa
	var b: int = _tick_list[i + 1]
	var pb: Vector2 = _pos_hist[b]
	var alpha := clampf((clock - float(a)) / float(b - a), 0.0, 1.0)
	return MazeGenerator.toroidal_lerp(pa, pb, alpha, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

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
		if _render_tick >= 0.0 and _tick_list.size() >= 2:
			_render_tick += delta * SNAPSHOT_HZ
			var canonical := _sample_position(_render_tick)
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
