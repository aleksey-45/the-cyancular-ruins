class_name WeaponBase
extends Node2D

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

@export var bullet_scene: PackedScene = preload("res://scenes/weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长(秒),旧 recoil_time 内联
# 预瞄判墙小球半径(px): PREVIEW_COLLISION_RADIUS×bullet_size 
const PREVIEW_COLLISION_RADIUS: float = 4.0

# ── 武器参数(说明见各参数上方注释)──
# 模板分类(轻/中/重),仅作信息/分组用
@export var tier: Tier = Tier.LIGHT
# 显示名,切枪/识别用
@export var weapon_name: String = "weapon"

# ── 开火 ──
# true=全自动(按住连发);false=半自动(按一下打一发)
@export var full_auto: bool = false
# 两次射击最小间隔(秒),越小射速越快
@export var fire_cooldown: float = 0.2
# true=重武器:按住左键进入激光预瞄,松开才发射
@export var heavy_aim: bool = false

# ── 子弹 ──
# 子弹速度(px/s),越大弹道越直、越难闪避
@export var bullet_speed: float = 900.0
# 子弹射程(px),超过即消失
@export var bullet_range: float = 600.0
# 子弹放大倍数(1.0=场景原始大小;缩放贴图与碰撞体)
@export var bullet_size: float = 1.0
# 子弹贴图染色(白色=原样显示 Bullets.png 贴图;想改子弹颜色就设这里)
@export var bullet_color: Color = Color.WHITE

# ── 霰弹/多弹丸 ──
# 每次开火弹丸数(1=单发,与旧版一致;>1 为霰弹)
@export var pellet_count: int = 1
# 弹丸散布半角(度):每颗弹丸在瞄准方向 ±spread_deg 内随机角度
@export var spread_deg: float = 0.0

# ── 伤害 ──
# 命中敌人扣除的 HP
@export var damage: int = 1
# 命中击退力度(>0 会覆盖敌人自身 knockback_strength)
@export var impact: float = 60.0

# ── 后坐/镜头 ──
# 开火把玩家向后推的力度(蹲下时不推)
@export var recoil_push: float = 0.0
# 枪口上跳幅度(枪精灵位移,纯视觉)
@export var recoil_kick: float = 4.0
# 开火镜头抖动幅度
@export var cam_shake: float = 2.0
# 镜头抖动时长(秒)
@export var cam_shake_time: float = 0.1

# ── 移动惩罚 ──
# 惩罚生效期间的水平移速倍率(1.0=不减,0.55=只剩 55%)
@export var move_penalty: float = 1.0
# 惩罚生效期间的跳跃初速倍率(1.0=不减)
@export var jump_penalty: float = 1.0
# 惩罚生效时机:NONE 永不 / WHILE_FIRING 开火后冷却中 / WHILE_AIM_OR_COOLDOWN 预瞄或冷却中
@export var penalty_mode: PenaltyMode = PenaltyMode.NONE

# ── 激光(heavy_aim 用)──
# 预瞄激光线长度(px)
@export var laser_length: float = 600.0
# 激光颜色
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)

# ── 瞄准 ──
# 本枪仰角钳制角(枪口/激光/出弹方向共用)
@export var pitch_clamp_deg: float = 45.0

# ── 弹道/预览(榴弹等抛体用)──
# 重力下坠倍率,发射时注入子弹(0=直线)
@export var bullet_gravity: float = 0.0
# true=重武器预瞄画抛物线弧线(取代直线激光);false=原直线激光
@export var preview_arc: bool = false
# 预瞄参考时长(秒),仅供画弧;真实爆炸时机由子弹 fuse_time 决定,预瞄只是参考
@export var preview_time: float = 0.5

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0

var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _aiming: bool = false
var _fire_buffered: bool = false
var _aim_facing: int = 1          # 最近一次明确的瞄准侧(近垂直瞄时用,不随走路翻侧)
var _current_aim_facing: int = 1  # 本帧实际生效的朝向(含冲刺锁定回落),弹道与枪口共用
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

# 俯仰角:把面向折进 dir.x,相对水平线求角并钳制到 ±45°。
static func clamp_pitch(dir: Vector2, facing: int, limit_deg: float = 45.0) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(limit_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	_base_sprite_pos = sprite.position
	_laser = Line2D.new()
	_laser.width = 1.0  # 细激光(经玩家 2.5x 缩放渲染约 2.5px)
	_laser.default_color = laser_color
	_laser.visible = false
	call_deferred("add_child", _laser)
	_explosion_marker = Sprite2D.new()
	_explosion_marker.texture = Explosion.make_circle_texture(16)
	_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
	_explosion_marker.visible = false
	call_deferred("add_child", _explosion_marker)

func _player_ok() -> bool:
	return player != null and (not player.has_method("is_downed") or not player.is_downed())

# 攻击输入查询:优先走 player 的注入输入(NetworkInputSource);本地/冒烟无该方法时回退真实 Input。
func _attack_pressed() -> bool:
	if player != null and player.has_method("is_attack_pressed"):
		return player.is_attack_pressed()
	return Input.is_action_pressed("attack")

func _attack_just_pressed() -> bool:
	if player != null and player.has_method("is_attack_just_pressed"):
		return player.is_attack_just_pressed()
	return Input.is_action_just_pressed("attack")

func _attack_just_released() -> bool:
	if player != null and player.has_method("is_attack_just_released"):
		return player.is_attack_just_released()
	return Input.is_action_just_released("attack")

func equip(p: Node2D, inherit_cooldown: float = 0.0) -> void:
	player = p
	# 切枪继承旧武器剩余冷却:后摇不能被切枪刷掉(否则可切枪连射)
	fire_cd_timer = maxf(inherit_cooldown, 0.0)
	# 缓冲开火不随切枪继承:旧武器 freed 标记随之消失,新武器从无缓冲开始
	_fire_buffered = false
	cancel_aim()

# 武器帧逻辑由所属 Player 的物理 tick 显式驱动(tick(),player.gd 每物理帧调用),
# 不再跑 idle _process:冷却/缓冲开火/重武器松开/预瞄/后坐必须落在固定的物理 tick 上,
# 否则同一输入在客户端预测重放/服务器权威模拟下会落在不同 tick(rollback 需要确定性)。
# delta 恒为物理帧 1/60,不随渲染帧率抖动。未被 Player 驱动的实例(如对手副本武器,
# player==null)由 drive_remote_visual 外部驱动,不进 tick。
func tick(delta: float) -> void:
	if not _player_ok():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	# 每帧同步朝向/枪口旋转(瞄准与预览弧线);fire() 内部还会再同步一次,
	# 覆盖直接开火等不经本帧 tick 的路径,避免读到走路覆盖的旧朝向。
	_auto_aim()
	# 缓冲开火:冷却结束且末尾按过开火 → 自动打出(土狼时间式;切枪即弃)
	if _fire_buffered and fire_cd_timer == 0.0:
		_fire_buffered = false
		fire()
	# 攻击输入轮询:heavy_aim 预瞄/松开发射,全自动按住连发,半自动按下单发。
	if heavy_aim:
		if _attack_just_pressed():
			_aiming = true
		if _attack_just_released():
			_aiming = false
			_update_laser()
			try_fire()
		_update_laser()
	elif full_auto:
		if _attack_pressed():
			try_fire()
	else:
		if _attack_just_pressed():
			try_fire()
	_recoil_recover(delta)

func try_fire() -> void:
	if fire_cd_timer > 0.0:
		# 冷却>0.5 的武器:最后 20% 内按开火不丢弃,改为缓冲,冷却结束自动打
		if fire_cooldown > 0.5 and fire_cd_timer <= fire_cooldown * 0.2:
			_fire_buffered = true
		return
	fire()

func fire() -> void:
	if not _player_ok():
		return
	fire_cd_timer = fire_cooldown
	# 开火瞬间同步朝向/枪口到鼠标:直接开火(_unhandled_input, input 阶段)先于 _process,
	# 读到的是上一物理帧被走路覆盖的 get_facing(),clamp_pitch 会折到走路侧、子弹打偏。
	# 统一先 _auto_aim:所有开火路径(直接/缓冲/连发/重武器)都取本帧最新瞄准方向。
	_auto_aim()
	var base_dir := _clamped_aim_dir()
	var spread := deg_to_rad(spread_deg)
	for i in range(pellet_count):
		var b: BulletBase = bullet_scene.instantiate()
		var ang := base_dir.angle() + randf_range(-spread, spread)
		b.setup(Vector2.from_angle(ang), bullet_speed, bullet_range, bullet_size, bullet_color, self)
		b.shooter = player
		b.gravity_factor = bullet_gravity
		b.hit_damage = damage
		b.hit_impact = impact
		b.global_position = muzzle.global_position
		# PvP:本地生成的子弹只做视觉(不裁决伤害);服务器权威子弹(Level0.pvp_mode=false)照常裁决。
		b.apply_damage = not Level0.pvp_mode
		# 服务器广播 bullet_spawn 时用(场景路径在运行期实例上可能为空)
		b.set_meta("scene_path", bullet_scene.resource_path)
		get_viewport().add_child(b)
	if player != null and player.has_method("apply_recoil"):
		player.apply_recoil(recoil_push)
	_recoil_timer = RECOIL_TIME
	sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)

# 命中回调:伤害/冲击由枪械管理(BulletBase 不含伤害)。
func apply_hit(target: Node, dir: Vector2) -> void:
	if target != null and target.has_method("hurt"):
		target.hurt(damage, dir, impact)

func cancel_aim() -> void:
	_aiming = false
	if _laser != null:
		_laser.visible = false

# 是否正在预瞄(heavy_aim 蓄力中):只有 heavy_aim 武器会置 _aiming。PvP 服务器快照读它,
# 让对手副本能看到"这人在蓄力瞄准"。非重武器恒 false(无预瞄)。
func is_previewing() -> bool:
	return _aiming

# PvP:服务器权威方向驱动"副本武器外观"(远端对手枪):只画朝向 + 预瞄线/弧,不读鼠标、不开火。
# 副本武器不 equip(player==null),_process 早退,由 player_replica 每帧调用本方法替代:
# 复刻 _auto_aim 的镜像/旋转(俯仰随枪 clamp),并同步 _laser/_explosion_marker 可见性。
func drive_remote_visual(aim_dir: Vector2, facing: int, show_preview: bool) -> void:
	if _laser == null or muzzle == null:
		return   # _ready 的 call_deferred 尚未建好(换枪当帧),下帧再驱动
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2(float(facing), 0.0)
	_aim_facing = facing
	_current_aim_facing = facing
	rotation = clamp_pitch(aim_dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)
	_aiming = show_preview
	_update_laser()

func get_movement_multiplier() -> Vector2:
	var active := false
	match penalty_mode:
		PenaltyMode.NONE:
			active = false
		PenaltyMode.WHILE_FIRING:
			active = fire_cd_timer > 0.0
		PenaltyMode.WHILE_AIM_OR_COOLDOWN:
			active = _aiming or fire_cd_timer > 0.0
	if not active:
		return Vector2.ONE
	return Vector2(move_penalty, jump_penalty)

# 与枪口相同的出弹方向:经过 ±45° 仰角钳制后的世界单位向量(fire 出弹用)。
# local.x 按 facing 折叠,还原到世界坐标时再乘回 facing,与 _auto_aim 的旋转一致。
# 折叠用 _current_aim_facing(_auto_aim 算出的瞄准侧,含冲刺锁定回落),不用 get_facing():
# 后者会被走路输入覆盖,朝向与鼠标反侧时子弹翻折到走路侧。
func _clamped_aim_dir() -> Vector2:
	var facing := _current_aim_facing
	var pitch := clamp_pitch(_aim_world_dir(), facing, pitch_clamp_deg)
	var local := Vector2.from_angle(pitch)
	return Vector2(local.x * float(facing), local.y)

func _auto_aim() -> void:
	var dir := _aim_world_dir()
	# 瞄准朝向:鼠标有明确水平分量则跟随鼠标并记住(近垂直瞄时用上次明确侧,不随走路翻侧)。
	var facing := _aim_facing
	if absf(dir.x) > 0.1:
		facing = 1 if dir.x > 0.0 else -1
		_aim_facing = facing
	# 玩家精灵朝向:只在明确瞄向一侧时翻转(冲刺锁定/无玩家时回落 get_facing)。
	if player != null and player.has_method("set_facing") and absf(dir.x) > 0.1:
		player.set_facing(facing)
		# 冲刺时 player.set_facing 被锁(身体保持冲刺方向,位移需要);此时枪口**不跟随身体翻转**,
		# 保持鼠标瞄准侧(_aim_facing/本帧 facing)。非冲刺:set_facing 成功、身体已翻到瞄准侧,
		# get_facing() 读回一致,无差异。
		var charging := false
		if player.has_method("is_charging"):
			charging = bool(player.is_charging())
		if not charging:
			facing = get_facing()
	_current_aim_facing = facing
	# 朝向镜像(scale.x=-1)会翻转旋转方向。clamp_pitch 已按 facing 折叠 dir.x,
	# 返回值乘 facing 取反:朝左时镜像后的枪口才指向正确的俯仰象限。
	rotation = clamp_pitch(dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)

func _update_laser() -> void:
	if _laser == null or muzzle == null:
		return
	_laser.visible = _aiming
	if not _aiming:
		_update_explosion_marker(false)
		return
	if preview_arc:
		_laser.points = _sample_arc_points()
		_update_explosion_marker(true)
	else:
		# 激光继承枪口的钳制旋转:仰角限制与枪口一致,且与出弹方向(同样钳制)对齐。
		_laser.points = PackedVector2Array([muzzle.position, muzzle.position + Vector2(laser_length, 0.0)])
		_update_explosion_marker(false)

# 预瞄抛物线:与 fire 同源(v0=钳制瞄准方向*speed, g=bullet_gravity*gravity0),
# 1/60s 采样到 preview_time,途中遇墙(非 EMPTY)格截断(榴弹撞墙停驻处 = 爆炸点),
# 并封顶 bullet_range(榴弹超射程兜底爆炸,不会再飞)。
func _sample_arc_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := muzzle.global_position
	var start := p
	var v := _clamped_aim_dir() * bullet_speed
	var g := bullet_gravity * GameParameters.gravity0
	var dt := 1.0 / 60.0
	var t := 0.0
	# 枪口起点判墙 → 真实榴弹会挣脱墙继续飞;跳过起点段判墙,避免弧线退化成贴脸短弧
	var escape := _disk_overlaps_solid(start)
	pts.append(to_local(p))
	while t < preview_time:
		v.y += g * dt
		# 水中阻力:与真实子弹一致(water_bullet_drag),入水后减速 → 弧线在水里更垂/更短
		if Water.is_in_water(p):
			v *= Water.bullet_drag_factor(true, GameParameters.water_bullet_drag, dt)
		p += v * dt
		t += dt
		if escape and p.distance_to(start) < GameParameters.TILE_SIZE:
			continue  # 起点挣脱段:不判墙、不截断,榴弹正从枪口墙体里飞出
		if _disk_overlaps_solid(p):
			break
		if p.distance_to(start) >= bullet_range:
			break
		pts.append(to_local(p))
	return pts

# 预瞄判墙:以 center 为圆心、半径 r(=6px)的小球是否压到任一墙(非 EMPTY)格(环面)。
# 小球按格子 AABB 粗查:球很小,最多跨 2 格,不会漏;比精确圆简单且略保守(宁多判墙不少判)。
func _disk_overlaps_solid(center: Vector2) -> bool:
	var r := PREVIEW_COLLISION_RADIUS*bullet_size
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var ts := GameParameters.TILE_SIZE
	var min_c := MazeGenerator.cell_of(center - Vector2(r, r), ts, cols, rows)
	var max_c := MazeGenerator.cell_of(center + Vector2(r, r), ts, cols, rows)
	var span_x := max_c.x - min_c.x
	if span_x < 0:
		span_x += cols
	var span_y := max_c.y - min_c.y
	if span_y < 0:
		span_y += rows
	for dy in range(span_y + 1):
		var y := posmod(min_c.y + dy, rows)
		for dx in range(span_x + 1):
			var x := posmod(min_c.x + dx, cols)
			if TileDefs.is_blocked(grid[y][x]):
				return true
	return false

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]

func _recoil_recover(delta: float) -> void:
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
		sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * recoil_kick * (_recoil_timer / RECOIL_TIME)
		if _recoil_timer == 0.0:
			sprite.position = _base_sprite_pos

# 当前瞄准方向(世界坐标系):本地=鼠标计算,网络=注入方向。PvP 输入包上报用。
func get_current_aim_dir() -> Vector2:
	return _aim_world_dir()

# 世界坐标系下从玩家指向鼠标的单位向量(未钳制俯仰)。
func _aim_world_dir() -> Vector2:
	# 网络驱动的玩家(服务器上的远端模拟)用注入的瞄准;本地玩家返回 ZERO → 落回鼠标。
	# has_method 守卫:冒烟里的 StubPlayer 没有该方法时跳过,不破坏测试。
	if player != null and player.has_method("get_aim_dir_override"):
		var override: Vector2 = player.get_aim_dir_override()
		if override != Vector2.ZERO:
			return override
		# override 存在但为 ZERO(网络玩家还没收到瞄准/瞄准为零):
		# 网络驱动 → 永不读宿主机 OS 鼠标(服务器 headless 上没有鼠标,读了是垃圾方向),用朝向兜底。
		# 本地 InputSource 的 override 恒为 ZERO → is_network_driven()==false → 走下面鼠标路径。
		if player.has_method("input_is_network") and player.input_is_network():
			return Vector2(float(get_facing()), 0.0)
	# 用基类 Viewport 而非 SubViewport:冒烟测试把武器挂到 SceneTree 根(Window),
	# 若标 SubViewport 会在运行时类型检查失败(Window≠SubViewport),函数被中断返回零方向。
	var sub: Viewport = get_viewport()
	if sub == null:
		return Vector2(float(get_facing()), 0.0)
	var cam: Camera2D = sub.get_camera_2d()
	if cam == null:
		return Vector2(float(get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(get_facing()), 0.0)
	# 窗口鼠标 -> 世界坐标。鼠标用根 Window 的真实坐标(SubViewport 的
	# get_mouse_position 是被 push 进去的窗口坐标,不能直接用)。
	# 相机把屏幕中心映射到 cam.global_position,world_mouse = 相机基准 + 鼠标偏移。
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	# 用相机无抖动的基准位置,避免镜头抖动让准星跟着跳
	var cam_center: Vector2 = cam.global_position
	if cam.has_method("get_base_global_position"):
		cam_center = cam.get_base_global_position()
	# PostProcess 是中心裁剪(显示世界视口中心窗口大小区域);相机 zoom(<1 视野更大)
	# 让 窗口 1px = 世界 1/zoom px,鼠标偏移按 zoom 放大回世界坐标(如 zoom=0.75 → ÷0.75)。
	# 不能 ÷crop_scale:crop 只定裁剪比例、不改像素换算,÷ 它(×1.3)会放大偏移,
	# 瞄准"水平"实际偏下,而榴弹枪口离地极近,弧线几步内就撞地板 → 预瞄贴在玩家身上。
	var world_mouse := cam_center + (mouse - win_size * 0.5) / cam.zoom
	var origin := player.global_position if player != null else global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	if player != null and player.has_method("get_facing"):
		return player.get_facing()
	return 1
