extends WeaponBase

# 开山砍刀(素材卡 wp_machete 评审稿;kind=melee,槽位未定,**不进现役注册表**
# weapon_component.WEAPONS——按施工范围只作独立场景交付,装备路径待评审后定)。
#
# 近战冷兵器:开火瞬间以玩家中心为弧心、瞄准方向为中轴做扇形横扫,不开物理弹:
#   - 弧内敌人吃 damage/impact(击退方向=环面最短向量径向推离),其他玩家走 take_hit;
#   - 弧内可子弹破坏砖(树叶/树干)按 damage 扣血("bullet" 语义,30 伤一刀碎树叶 8/树干 30);
#   - 挥空(敌+砖都没碰到)→ 冷却延长 + 硬直窗口内移速/跳跃惩罚 =「挥空有明显硬直」;
#   - 无弹夹无换弹(reload_active 恒 false,HUD 残弹随之隐藏)。
# 架构与激光武器同型(laser_weapon_base 先例):覆写 _spawn_projectiles 即时结算;
# Level0.pvp_mode=true 的客户端视觉副本只播弧光/音效/挥击动画,不裁决伤害、不吃硬直。
# 判定细节:环面一律 toroidal_delta_px/anchor_to_nearest;敌人被墙/树叶隔开时 LOS 判空
# (先砍开树叶才打得着——树叶本体吃刀,砖块判定不需要 LOS,砍墙本身就是接触)。

const SlashFx := preload("res://Scenes/Weapons/machete_slash_fx.gd")
const TileHitFx := preload("res://Scenes/Effects/tile_hit_fx.gd")

# ── 扇形横扫(与卡 kind_params 同名同值,卡 JSON 是单一事实来源)──
@export var arc_deg: float = 130.0      # 扇形张角(度)
@export var melee_range: float = 90.0   # 挥砍半径(px,自玩家中心)
# ── 挥空硬直(新增标定,已回写卡 kind_params)──
@export var whiff_extra_time: float = 0.35   # 挥空额外冷却(总冷却 = fire_cooldown + 此值)
@export var whiff_move_mult: float = 0.5     # 硬直期间移速倍率
@export var whiff_jump_mult: float = 0.6     # 硬直期间跳跃倍率
# ── 挥击表现 ──
@export var swing_time: float = 0.16                    # 精灵扫击动画时长(秒)
@export var slash_color: Color = Color(0.85, 0.95, 1.0, 0.55)   # 弧光颜色

var _swing_t := 0.0   # 挥击动画剩余时间
var _whiff_t := 0.0   # 硬直剩余时间(移/跳惩罚窗口)
var _whoosh: AudioStreamWAV = null

func _ready() -> void:
	# 先于 super():基类 _ready 按 custom_art_id 找 assets/custom/guns/<id>.png 换贴图
	# (普通 var 不能可靠地从 tscn 赋值,评审稿固定写死卡 id)
	custom_art_id = "wp_machete"
	super()
	_ensure_blade_texture()

func reload_active() -> bool:
	return false   # 近战无弹药系统(卡 mag_size=0):不换弹、HUD 不显示残弹

func get_movement_multiplier() -> Vector2:
	if _whiff_t > 0.0:
		return Vector2(whiff_move_mult, whiff_jump_mult)
	return super()

func _process(delta: float) -> void:
	super(delta)
	_whiff_t = maxf(_whiff_t - delta, 0.0)
	_update_swing(delta)

# ── 出弹钩子接管:扇形横扫(即时结算,不开物理弹)──
func _spawn_projectiles(base_dir: Vector2) -> void:
	var origin := player.global_position if player != null else global_position
	var aim := base_dir.normalized()
	if aim == Vector2.ZERO:
		aim = Vector2(float(get_facing()), 0.0)
	_swing_t = swing_time
	_spawn_slash(origin, aim)
	_play_whoosh()
	if not _authoritative():
		return
	var targets := _sweep_targets(origin, aim)
	var hit_any := targets > 0
	if _sweep_tiles(origin, aim):
		hit_any = true
	if targets > 0:
		Sfx.play("hit")
	if not hit_any:
		# 挥空硬直:fire() 已记 fire_cooldown,这里补上差额;惩罚窗口 = 整个延长的冷却
		var total := fire_cooldown + whiff_extra_time
		fire_cd_timer = total
		_whiff_t = total

# PvP 门控,与激光武器同款:客户端视觉副本不裁决(单机/PvP 服务器都返回 true)。
func _authoritative() -> bool:
	return not Level0.pvp_mode

# ── 实体判定:弧内敌人 + 其他玩家(环面锚定 → 身体盒进半径 + 中心偏角带盒裕量 + LOS)──
# 返回命中实体数(挥空判定用;尸体敌人照常计入——基类 hurt 对死者只给击退,砍着也算接触)。
func _sweep_targets(origin: Vector2, aim: Vector2) -> int:
	var n := 0
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var ts := GameParameters.TILE_SIZE
	var half_arc := deg_to_rad(arc_deg * 0.5)
	for group in ["enemies", "player"]:
		for t in get_tree().get_nodes_in_group(group):
			var body := t as Node2D
			if body == null or body == player:
				continue
			if body.has_method("is_downed") and body.is_downed():
				continue   # 倒地玩家不吃近战
			# 环面:把目标锚到挥砍者最近副本再量锥(接缝两侧照常命中)
			var c := MazeGenerator.anchor_to_nearest(body.global_position, origin, w, h)
			var half := _body_half(body)
			# 半径:身体盒离弧心最近点进挥砍半径即够到(身体大只吃半格裕量,不按中心量)
			var nearest := Vector2(
				clampf(origin.x, c.x - half.x, c.x + half.x),
				clampf(origin.y, c.y - half.y, c.y + half.y))
			if (nearest - origin).length() > melee_range:
				continue
			# 角度:身体中心对中轴的偏角,放宽 asin 裕量(盒越近裕量越大)
			var to_center := c - origin
			var margin := atan2(half.length(), maxf(to_center.length(), 1.0))
			if absf(wrapf(to_center.angle() - aim.angle(), -PI, PI)) > half_arc + margin:
				continue
			# LOS:中心所在格间被墙/树叶隔开则砍不到(树叶吃刀在 _sweep_tiles,先砍开再打人)
			var grid := MazeGenerator.current_grid
			if not grid.is_empty() and not MazeGenerator.has_line_of_sight(
					MazeGenerator.cell_of(origin, ts, grid[0].size(), grid.size()),
					MazeGenerator.cell_of(c, ts, grid[0].size(), grid.size())):
				continue
			if body.is_in_group("enemies"):
				if player != null and is_instance_valid(player):
					body.set_meta("last_damager", player)   # 击杀归因(CombatFeedback 读)
				# 击退方向 = 弧心指向目标(环面最短向量);完全重合的退化情形回落瞄准方向
				var push := to_center.normalized() if to_center.length_squared() > 1.0 else aim
				body.hurt(damage, push, impact)
			elif body.has_method("take_hit"):
				# 与激光/爆炸一致:take_hit(源点, 伤, 不穿无敌帧, 击退);源点=挥砍者 → 推离射手
				body.take_hit(origin, damage, false, impact)
				if player != null and is_instance_valid(player):
					body.set_meta("last_damager", player)
					body.set_meta("last_damager_time", Time.get_ticks_msec())
			n += 1
	return n

# ── 砖块判定:扇形内的可子弹破坏砖(树叶/树干)按挥砍伤害扣血,命中即不算挥空 ──
func _sweep_tiles(origin: Vector2, aim: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	var ts := GameParameters.TILE_SIZE
	var cols: int = grid[0].size()
	var rows: int = grid.size()
	var base_cell := MazeGenerator.cell_of(origin, ts, cols, rows)
	var half_arc := deg_to_rad(arc_deg * 0.5)
	var reach := int(ceilf(melee_range / ts))
	var any := false
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cell := Vector2i(posmod(base_cell.x + dx, cols), posmod(base_cell.y + dy, rows))
			var v: int = grid[cell.y][cell.x]
			if v == 0 or not TileDefs.bullet_destroyable(v / 16):
				continue
			# 格中心按环面最短向量量锥(跨接缝的树照常吃刀)
			var center := Vector2(float(cell.x + 0.5) * ts, float(cell.y + 0.5) * ts)
			var to_c := MazeGenerator.toroidal_delta_px(origin, center,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			if to_c.length() > melee_range + ts * 0.5:
				continue
			if absf(wrapf(to_c.angle() - aim.angle(), -PI, PI)) > half_arc:
				continue
			TileHitFx.spawn(get_viewport(), origin + to_c, v / 16)
			TileDefs.damage_tile(cell, damage, "bullet")   # 破坏回调 Level0 刷渲染/碰撞
			any = true
	return any

# ── 表现:弧光 + 挥击动画 + 风声 ──
func _spawn_slash(origin: Vector2, aim: Vector2) -> void:
	var fx := SlashFx.new()
	fx.radius = melee_range
	fx.half_arc = deg_to_rad(arc_deg * 0.5)
	fx.center_angle = aim.angle()
	fx.color = slash_color
	fx.global_position = origin
	get_viewport().add_child(fx)

# 挥击动画:精灵局部坐标从上后方(+半角)顺劈到下前方(-半角),ease-out 先快后缓;
# 中段前探一小步。根节点旋转/镜像照旧由 _auto_aim 驱动,镜像自动翻转扫向(与换弹姿态同法)。
func _update_swing(delta: float) -> void:
	if _swing_t <= 0.0:
		return
	_swing_t = maxf(_swing_t - delta, 0.0)
	var p := 1.0 - _swing_t / maxf(swing_time, 0.01)   # 0→1
	var k := 1.0 - pow(1.0 - p, 2.0)
	sprite.rotation = lerp_angle(deg_to_rad(arc_deg * 0.5), -deg_to_rad(arc_deg * 0.5), k)
	sprite.position = _base_sprite_pos + Vector2(4.0, 0.0) * sin(p * PI)
	if _swing_t == 0.0:
		sprite.rotation = 0.0
		sprite.position = _base_sprite_pos

# 挥砍风声:程序合成噪声爆发(Sfx 同款 8bit 做法,但**不改公共 sfx.gd**——评审通过后
# 再决定是否把 "swing" 音色收编进 Sfx 统一管理)。走 SFX 总线(设置页音量滑条管得到),
# 总线未建时回退 Master。
func _play_whoosh() -> void:
	if _whoosh == null:
		_whoosh = _build_whoosh()
	var p := AudioStreamPlayer.new()
	p.stream = _whoosh
	p.volume_db = -8.0
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") != -1 else "Master"
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)

func _build_whoosh() -> AudioStreamWAV:
	var rate := 22000
	var n := int(0.16 * rate)
	var bytes := PackedByteArray()
	bytes.resize(n)
	var state := 0.0
	for i in n:
		var t := float(i) / float(n)
		state = lerp(state, randf_range(-1.0, 1.0), clampf(0.9 * (1.0 - t), 0.08, 1.0))
		bytes[i] = int(clampf(state * 0.65 * sin(t * PI), -1.0, 1.0) * 127.0) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_8_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = bytes
	return w

# 兜底刀身贴图:custom_art_id 指向的 assets/custom/guns/wp_machete.png(画师上传或
# gen_portrait 占位)由 WeaponBase._ready 换上;都还没有时程序化画一把,评审稿开箱可跑。
func _ensure_blade_texture() -> void:
	if sprite == null or sprite.texture != null:
		return
	var img := Image.create(48, 16, false, Image.FORMAT_RGBA8)
	var wood := Color8(122, 82, 48)
	var tape := Color8(34, 34, 34)
	var brass := Color8(176, 141, 63)
	var blade := Color8(138, 146, 156)
	var dark := Color8(90, 96, 104)
	var edge := Color8(200, 206, 212)
	for x in range(48):
		if x < 12:      # 木柄 + 黑胶带
			for y in range(6, 11):
				img.set_pixel(x, y, tape if (x % 4) < 1 else wood)
		elif x < 15:    # 黄铜圆护手
			for y in range(2, 14):
				img.set_pixel(x, y, brass)
		else:           # 刀身:厚背(3px 深灰)+ 刃体 + 开刃亮线
			for y in range(3, 6):
				img.set_pixel(x, y, dark)
			for y in range(6, 12):
				img.set_pixel(x, y, blade)
			img.set_pixel(x, 12, edge)
		if x >= 40:     # 刀尖收窄:刀背向刃线斜收,尖端落在开刃线上(x=47 只剩刃线 1px)
			for y in range(3, 4 + int(float(x - 40) * 9.0 / 7.0)):
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	sprite.texture = ImageTexture.create_from_image(img)
