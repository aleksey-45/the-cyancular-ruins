extends RefCounted

# 瞄准与蓄力视觉:抬枪朝向、预瞄激光/抛物线、爆炸预览标记、蓄力箭姿态、枪口后坐计时。
# ★ 状态不在这里:瞄准态与节点(_charge_arrow / _laser / _explosion_marker / 基准位置)都在宿主 WeaponBase 上
#   —— 快照、回滚、精灵 pose 直接读写它们;本类只按调用顺序操作,并持有 host 注入的节点引用。

const CHARGE_ARROW_SHOW_SCALE := 1.5      # 蓄力箭相对飞行箭的倍数(飞行箭世界缩放 = bullet_size × BulletBase.ART_WORLD_PX)
const CHARGE_ARROW_JITTER_PX := 0.5       # 上下抖动幅度(px);★ 只有蓄满(charge_ratio>=1)才抖
const CHARGE_ARROW_JITTER_PERIOD := 0.2   # 抖动周期(秒)
const PREVIEW_COLLISION_RADIUS: float = 4.0

var host: WeaponBase = null
var charge_arrow: Sprite2D = null
var muzzle: Marker2D = null
var laser: Line2D = null
var explosion_marker: Sprite2D = null


func _init(owner_weapon: WeaponBase = null, arrow: Sprite2D = null, muzzle_node: Marker2D = null,
		laser_node: Line2D = null, marker: Sprite2D = null) -> void:
	host = owner_weapon
	bind(arrow, muzzle_node, laser_node, marker)


# 节点引用由 host 注入:蓄力箭/枪口是场景子节点,预瞄线与爆炸标记是宿主 _ready() 里 new 出来的。
func bind(arrow: Sprite2D, muzzle_node: Marker2D, laser_node: Line2D, marker: Sprite2D) -> void:
	charge_arrow = arrow
	muzzle = muzzle_node
	laser = laser_node
	explosion_marker = marker


# 让蓄力箭与飞行箭同一标尺:飞行箭视觉 = bullet_size × ART_WORLD_PX;蓄力箭在玩家子树里(玩家根 scale 2.5),
# 局部缩放 = bullet_size × 本倍数 / 继承缩放。★ 别写死:玩家根是 2.5 倍,写死会再乘一次。
func sync_charge_arrow_scale() -> void:
	if charge_arrow == null or host._arrow_scale_synced:
		return
	var inherited := 1.0
	var par := charge_arrow.get_parent() as Node2D
	if par != null:
		var s := absf(par.get_global_transform().get_scale().x)
		if s > 0.0001:
			inherited = s
	charge_arrow.scale = Vector2.ONE * (host.bullet_size * CHARGE_ARROW_SHOW_SCALE / inherited)
	host._arrow_scale_synced = true


# 拉弓后移量(0→charge_arrow_pull 线性):显示与出膛点共用这一个量,不另加显示偏移。
func charge_pull_px() -> float:
	return host.charge_arrow_pull * host.charge_ratio


# 只移动箭,弓身不动;ChargeArrow 的 z_index 让箭画在弓身后。
# ★ 抖动是纯表现:出膛点按 charge_pull_px() 算,不吃抖动(见 WeaponBase._spawn_projectiles 的 b.global_position);放大在入树时一次性施加。
func apply_charge_arrow_pose() -> void:
	if charge_arrow == null:
		return
	sync_charge_arrow_scale()
	var on := host.charge_time > 0.0 and host._aiming
	charge_arrow.visible = on
	if not on:
		charge_arrow.position = host._base_arrow_pos
		return
	var jitter := 0.0
	if host.charge_ratio >= 1.0:   # ★ 蓄满才抖:蓄力过程中箭是稳的,拉满那一刻开始微颤
		var period_ms := maxf(CHARGE_ARROW_JITTER_PERIOD, 0.001) * 1000.0
		var phase := float(Time.get_ticks_msec() % int(period_ms)) / period_ms * TAU   # 0..TAU 一个周期
		jitter = sin(phase) * CHARGE_ARROW_JITTER_PX
	charge_arrow.position = host._base_arrow_pos + Vector2(-charge_pull_px(), jitter)


# 与枪口相同的出弹方向:经过 ±pitch_clamp_deg 仰角钳制后的世界单位向量。
func clamped_aim_dir() -> Vector2:
	var facing := host._current_aim_facing
	var pitch := WeaponBase.clamp_pitch(aim_world_dir(), facing, host.pitch_clamp_deg)
	var local := Vector2.from_angle(pitch)
	return Vector2(local.x * float(facing), local.y)


func auto_aim() -> void:
	var dir := aim_world_dir()
	var facing := host._aim_facing
	if absf(dir.x) > 0.1:
		facing = 1 if dir.x > 0.0 else -1
		host._aim_facing = facing
	var p := host.player as Player
	if p != null and absf(dir.x) > 0.1:
		p.set_facing(facing)
		# 冲刺时 player.set_facing 被锁(身体保持冲刺方向,位移需要),此时枪口不跟随身体翻转、保持鼠标瞄准侧;非冲刺时 set_facing 成功、get_facing() 读回一致,无差异。
		# ★ 旧写法对 is_charging 有 has_method 兜底;宿主恒为 Player ⇒ 直接读(非 Player 宿主上旧写法算 charging=false,这里走 p==null 同一分支)。
		var charging: bool = p.is_charging()
		if not charging:
			facing = host.get_facing()
	host._current_aim_facing = facing
	# 朝向镜像(scale.x=-1)会翻转旋转方向:clamp_pitch 已按 facing 折叠 dir.x,返回值再乘 facing 取反,朝左时镜像后的枪口才指向正确的俯仰象限。
	host.rotation = WeaponBase.clamp_pitch(dir, facing, host.pitch_clamp_deg) * float(facing)
	host.scale.x = float(facing)


func update_laser() -> void:
	host._sync_overlay_host()
	if laser == null or muzzle == null:
		return
	laser.visible = host._aiming and host.show_aim_laser
	if not host._aiming:
		update_explosion_marker(false)
		return
	if host.preview_arc or not is_zero_approx(host.bullet_gravity):
		# ★ 有下坠的武器默认走真实弹道(与 WeaponBase.fire 同源),不再要求逐个武器手动开 preview_arc。
		laser.points = sample_arc_points()
		update_explosion_marker(host.preview_arc)   # 爆炸球只跟 preview_arc:有下坠但没开弧线预览的武器不画球
	else:
		laser.points = PackedVector2Array([muzzle.position, muzzle.position + Vector2(host.laser_length, 0.0)])
		update_explosion_marker(false)


# 预瞄抛物线:与 fire 同源(v0 = 钳制瞄准方向 × speed,g = bullet_gravity × gravity0),1/60s 采样到 preview_time,途中遇墙(非 EMPTY)格截断(榴弹撞墙停驻处 = 爆炸点),并封顶 bullet_range。
func sample_arc_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := muzzle.global_position
	var start := p
	var v := clamped_aim_dir() * host.bullet_speed
	var g := host.bullet_gravity * GameParameters.gravity0
	var dt := 1.0 / 60.0
	var t := 0.0
	# 枪口起点判墙 ⇒ 真实榴弹会挣脱墙继续飞;跳过起点段判墙,避免弧线退化成贴脸短弧。
	var escape := disk_overlaps_solid(start)
	pts.append(host.to_local(p))
	while t < host.preview_time:
		v.y += g * dt
		# 水中阻力:与真实子弹一致(water_bullet_drag),入水后减速 ⇒ 弧线在水里更垂/更短。
		if Water.is_in_water(p):
			v *= Water.bullet_drag_factor(true, GameParameters.water_bullet_drag, dt)
		p += v * dt
		t += dt
		if escape and p.distance_to(start) < GameParameters.TILE_SIZE:
			continue  # 起点挣脱段:不判墙、不截断,榴弹正从枪口墙体里飞出
		if disk_overlaps_solid(p):
			break
		if p.distance_to(start) >= host.bullet_range:
			break
		pts.append(host.to_local(p))
	return pts


# 预瞄判墙:以 center 为圆心、半径 6px 的小球是否压到任一墙(非 EMPTY)格(环面)。
func disk_overlaps_solid(center: Vector2) -> bool:
	var r := PREVIEW_COLLISION_RADIUS * host.bullet_size
	return TileQuery.rect_overlaps_solid(
			Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), GameParameters.TILE_SIZE)


func update_explosion_marker(visible_on: bool) -> void:
	# ★ 参数不能叫 show:CanvasItem 有同名方法,会触发 SHADOWED_VARIABLE_BASE_CLASS。
	if explosion_marker == null:
		return
	explosion_marker.visible = visible_on
	if visible_on and laser.points.size() > 0:
		explosion_marker.position = laser.points[laser.points.size() - 1]


func recoil_recover(delta: float) -> void:
	# 只推进计时器;精灵 pose 由 WeaponBase.tick() 末尾的 _apply_sprite_pose() 统一写(与 bob/换弹合成一处)。
	host._recoil_timer = maxf(host._recoil_timer - delta, 0.0)


func get_current_aim_dir() -> Vector2:
	return aim_world_dir()


func aim_world_dir() -> Vector2:
	# 网络驱动的玩家(服务器上的远端模拟)用注入的瞄准;本地玩家返回 ZERO ⇒ 落回鼠标。★ 宿主恒为 Player(有 class_name)⇒ 直接调,
	# 不再 has_method 探测:拼错方法名当场编译报错,不会静默落回"读鼠标"那条错源(非 Player 宿主 = 违约,与 null 同路落回鼠标)。
	var p := host.player as Player
	if p != null:
		var override: Vector2 = p.get_aim_dir_override()
		if override != Vector2.ZERO:
			return override
		# override 存在但为 ZERO(网络玩家还没收到瞄准)时:网络驱动 ⇒ 永不读宿主机 OS 鼠标(服务器 headless 上没有鼠标,读了是垃圾方向),用朝向兜底;本地 PlayerInput 的 override 恒为 ZERO ⇒ is_network_driven()==false ⇒ 走下面的鼠标路径。
		if p.input_is_network():
			return Vector2(float(host.get_facing()), 0.0)
	# 用基类 Viewport 而非 SubViewport:冒烟测试把武器挂到 SceneTree 根(Window),标 SubViewport 会在运行时类型检查失败(Window≠SubViewport),函数被中断返回零方向。
	var sub: Viewport = host.get_viewport()
	if sub == null:
		return Vector2(float(host.get_facing()), 0.0)
	var cam: Camera2D = sub.get_camera_2d()
	if cam == null:
		return Vector2(float(host.get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(host.get_facing()), 0.0)
	# 窗口鼠标 → 世界坐标:鼠标用根 Window 的真实坐标(SubViewport 的 get_mouse_position 是被 push 进去的窗口坐标,不能直接用)。
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	# 用相机无抖动的基准位置,避免镜头抖动让准星跟着跳。
	var cam_center: Vector2 = cam.global_position
	if cam.has_method("get_base_global_position"):
		cam_center = cam.get_base_global_position()
	# PostProcess 是中心裁剪(显示世界视口中心、窗口大小的区域);相机 zoom(<1 视野更大)让窗口 1px = 世界 1/zoom px,鼠标偏移按 zoom 放大回世界坐标。
	var world_mouse := cam_center + (mouse - win_size * 0.5) / cam.zoom
	var origin := host.player.global_position if host.player != null else host.global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(host.get_facing()), 0.0)
	return dir.normalized()
