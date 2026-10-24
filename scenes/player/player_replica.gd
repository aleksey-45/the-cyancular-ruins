extends Node2D
# PvP 远端玩家副本:视觉(Player 的 SpriteFrames / 动画 + 各武器外观),由快照驱动。★ 它不是纯视觉:还带一个只参与碰撞的
# 幽灵体(见 _build_ghost_body)—— C2 客户端预测只步进自己的玩家,客户端世界里没有对手身体 ⇒「对手挡住我」在预测侧不存在
# ⇒ 每帧分歧回滚(幽灵体只减小分歧不消除)。★ 观感两条不变量:位置走 playout 插值、渲染层带排在世界结构层之前,理由与实测见 docs/eng/render.md。

# 大跳变阈值:相邻两条权威快照的间隔超过它 ⇒ 清历史、一帧落位(回溯 / 重生 / 换边本来就是瞬移,插值会演成「滑过去」)。
# ★ 128px 两侧余量的依据:常态相邻包位置差 ≈ 10px、丢包 200ms ≈ 60px、瞬移是几百~几千 px(实测见 docs/eng/render.md)。
const SNAP_DIST := 128.0

# 播放时钟(= core/net/playout_clock.gd)。★ 用 preload 取常量而不是全局类名:少一次编辑器扫描依赖。
const PlayoutClock := preload("res://core/net/playout_clock.gd")

# ── playout 缓冲插值 ── PLAYOUT_TICKS = 故意落后多少 tick:下行 30Hz(间隔 2 tick)⇒ 4 tick = 2 个间隔 ≈ 67ms 缓冲(1 个间隔
# 是夹逼插值的最低要求,第 2 个吸收抖动);改大 = 更抗抖但更迟,改 0 = 直出。place_history 存 canonical 且定长裁剪。
const PLAYOUT_TICKS := 4
const HISTORY_MAX := 12

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

const POSE_FLY := 2

const LAND_VEL_EPS := 1.0

# 脚底探针偏移(世界 px):水中查询要与本体同口径 —— 本体走 Water.is_in_water(脚底),脚底 = 原点 + Water.feet_offset(自己);取值在 _ready 里一次性问幽灵体。★ 为什么一次性问幽灵体而不是写死一个数:幽灵体的 5 份姿态多边形是从 player.tscn 现抄的、根同样是 scale 2.5 ⇒ to_global 出来的底边与本体逐像素相同(实测 stand = 57.0),写死数会随 player.tscn 的碰撞箱改动静默漂。★ 为什么是常量而不是逐帧按姿态重算:本体那边实际也是常量(Water.feet_offset 的缓存签名只数 CollisionShape2D 子节点,而玩家 5 份姿态箱全是 CollisionPolygon2D ⇒ 签名恒为 0、缓存永不失效)。★ 与本体那 1px 的差(如实登记):本体首帧调用时 5 个姿态箱全是启用态 ⇒ 它缓存的是 5 箱合并底边 = 58.0,副本这里是幽灵体当时启用的 stand 那一份 = 57.0;刻意不去逐像素对齐它 —— 那等于把本体的缓存口径抄进第二个地方,而那份缓存哪天被修成「跟着姿态走」时,抄来的 58 会朝反方向漂 1px;57 才是 feet_offset 的语义值(启用中的碰撞箱底边)。
var _water_feet_off: float = 24.0   # 24 = Water.feet_offset 的兜底值(幽灵体取不到时同款)

const POSE_SHAPE: Dictionary = {
	0: "CollisionShape2D_stand", 1: "CollisionShape2D_move", 2: "CollisionShape2D_fly",
	3: "CollisionShape2D_charge", 4: "CollisionShape2D_squat",
}

# 幽灵体所在组:榴弹「碰到玩家」判定要把对手副本也算进候选。单列一组而不是并进 player:后者是「玩家实体」的语义,Explosion.apply_aoe 会遍历它逐个 take_hit、BulletBase._wrap 会取它第一个节点当锚点 —— 副本混进去会被当玩家结算 / 被当锚点。
const GROUP := "player_replica"

const HIT_FLASH_TIME := 0.35   # 受击闪烁时长(秒),闪烁频率对齐本地 iframe 眨眼感
const HIT_FLASH_RATE := 20.0

@onready var animator: AnimatedSprite2D = $AnimatedSprite2D

var squash: SquashStretch = null
var _vel: Vector2 = Vector2.ZERO
var _pose: int = 0
# 上一帧的 vel.y。组件靠「上次在下落 + 现在已经落地」这一对值推导落地冲击,单看当前的 _vel.y 推不出来 —— 服务器在落地那一帧就把它清零了;与本体「_pre_move_vy 配帧首 is_on_floor()」是同款配对。
var _prev_vel_y: float = 0.0

var _weapon_slot_node: Node2D        # 武器挂点(运行时加,排在 AnimatedSprite2D 后 → 画在身体上层)
var _weapon: Node2D = null           # 当前武器场景实例(惰性:未 equip,仅外观)
var _weapon_type_int := 0            # 服务器权威槽位
var _opponent_canonical := Vector2.ZERO
var _local_anchor := Vector2.ZERO         # 本地玩家(相机)位置,每帧跟随
var _have_data := false
var _clock: PlayoutClock = null
var place_history: Array = []
# 首帧是否已直落:第一帧历史里还没有样本,走插值会从原点滑过去;幽灵体也必须立刻落到权威位置,否则白分歧一次。
var _placed := false
var _facing := 1
# ★★ 瞄准侧(与 _facing 不是同一个量,枪口外观只认这一个)。_facing 来自快照的 facing 字段 = 服务器的走路朝向(player.gd 的移动代码排在 weapons.tick 之后,每帧覆盖 _auto_aim 写进去的瞄准侧);而枪口俯仰必须按瞄准侧折叠(clamp_pitch 先 dir.x * facing)。二者混用时,倒着走会让枪口折到反侧极限而上翘(用户报过「A 往回走的时候,在 B 眼里枪还会翘起来」)。
# 本体那边由 _auto_aim 的 _aim_facing 承担同一职责,下面是它的逐字同款规则:鼠标有明确水平分量则跟随并记住,近垂直瞄(±0.1 以内)沿用上次明确侧,不随走路翻侧。
var _aim_facing := 1
var _aim := Vector2(1.0, 0.0)
var _previewing := false   # 对手是否正在预瞄(heavy 蓄力)。快照仍带该字段,但**不再驱动任何外观**
var _downed := false
var _hit_flash_t := 0.0

# ── 幽灵碰撞体(只碰撞、不参与任何逻辑)──
var _ghost: StaticBody2D = null
var _ghost_shapes: Dictionary = {}   # pose(int) -> CollisionPolygon2D

func _ready() -> void:
	add_to_group(GROUP)
	var tmp := preload("res://scenes/player/player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	_build_ghost_body(tmp)
	tmp.free()
	_water_feet_off = Water.feet_offset(_ghost) if _ghost != null else 24.0
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)
	_reorder_before_structures.call_deferred()


# 渲染层带:插到世界注册的结构层之前,与本体同一条层带(理由见文件头)。★ 用 Level0.wall_layer 而不是节点名字面量;
# 只在自己与该层同一个父节点时动手(探针里副本可能挂在别处),取不到就什么都不做(少一层遮挡好过崩)。
func _reorder_before_structures() -> void:
	if not is_inside_tree():
		return
	var host := get_parent()
	if host == null:
		return
	var structures: Node = Level0.wall_layer
	if structures == null or not is_instance_valid(structures):
		return
	if structures.get_parent() != host or get_index() < structures.get_index():
		return
	host.move_child(self, structures.get_index())

# 幽灵碰撞体:StaticBody2D(layer 2 = 玩家层,与 player.tscn 一致;mask 0 = 它不需要感知任何东西,只被本地玩家的 move_and_slide 撞到)挂 5 份姿态多边形,形状从 player.tscn 现抄。用 StaticBody2D 而不是 CharacterBody2D:副本自身不由物理驱动,CharacterBody2D 会引入它自己的物理步进与 move_and_slide 竞争;作为副本子节点 ⇒ 位置 / 朝向 / 环面回绕全自动跟随。
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

# 幽灵体所在碰撞层。★ 默认值不变(_build_ghost_body 里那句 2,全项目唯一一处),本函数只是把它变成可改的:3v3 按该副本代表的那名玩家的队配层(队 B 的玩家身体在层 16,见 TeamHost.TEAM_ENEMY_LAYER 那张契约表);1v1 / 大乱斗不调它 ⇒ 行为逐字不变。
# ★ 为什么必须跟着队走:幽灵体的全部用途是让「预测所依据的世界」与权威一致。队友之间是完全穿透(服务器侧两队掩码互指对方的位),副本若恒在层 2,本地预测就会被队友挡下 —— 而服务器上他穿过去了 ⇒ 每帧分歧、每帧回滚(与「幽灵体缺失」同一个形状)。
func set_ghost_layer(n: int) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.collision_layer = n


# 幽灵体按姿态切换碰撞箱(与 player.gd 的 _coll_by_pose 同款)。形状必须跟姿态走:否则蹲下躲进矮通道的对手仍按站姿挡路,预测侧又会与权威不一致。
func _set_ghost_pose(pose: int) -> void:
	for p in _ghost_shapes:
		(_ghost_shapes[p] as CollisionPolygon2D).disabled = p != pose


## canonical → 锚到本地玩家(相机)最近的那一份副本。
func _anchor_of(canon: Vector2) -> Vector2:
	return MazeGenerator.anchor_to_nearest(canon, _local_anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)


## 在 t(服务器 tick 域,可为小数)处取样:夹逼线性插值,两侧都冻结(比最新还新 = underrun 不外插,比最老还老 = 不倒退)。
## ★★ 两端必须锚进同一个副本空间再插(b 锚到 pa,不是 _local_anchor),否则跨接缝时差量是一整幅地图、插值横穿全图。
func _sample_history(t: float) -> Vector2:
	var n := place_history.size()
	if n == 0:
		return _opponent_canonical
	var first: Dictionary = place_history[0]
	var last: Dictionary = place_history[n - 1]
	if t <= float(first["tick"]):
		return _anchor_of(first["pos"])
	if t >= float(last["tick"]):
		return _anchor_of(last["pos"])
	for i in range(n - 1):
		var a: Dictionary = place_history[i]
		var b: Dictionary = place_history[i + 1]
		var ta := float(a["tick"])
		var tb := float(b["tick"])
		if t < ta or t > tb:
			continue
		var pa := _anchor_of(a["pos"])
		var pb := MazeGenerator.anchor_to_nearest(b["pos"], pa,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if tb <= ta:
			return pb
		return pa.lerp(pb, (t - ta) / (tb - ta))
	return _anchor_of(last["pos"])


# 记一条位置历史;相邻样本的环面距离超过 SNAP_DIST ⇒ 设计好的瞬移 ⇒ 清历史让它一帧落位(判据必须用环面最短距离,跨接缝不是跳变)。
func _push_history(tick: int, canon: Vector2) -> void:
	if not place_history.is_empty():
		var last: Dictionary = place_history[place_history.size() - 1]
		var jump := GridPathfinder.toroidal_delta_px(last["pos"], canon,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if jump > SNAP_DIST:
			place_history.clear()
	place_history.append({"tick": tick, "pos": canon})
	while place_history.size() > HISTORY_MAX:
		place_history.pop_front()


# ★ tick 参与计算(播放时钟 + 位置历史,见文件头),三参签名是三个生产调用点与探针的既定调用面,别改成两参。
func apply_snapshot(data: Dictionary, local_anchor: Vector2, tick: int) -> void:
	_opponent_canonical = data["pos"]
	_local_anchor = local_anchor
	_have_data = true
	if _clock == null:
		_clock = PlayoutClock.new(PLAYOUT_TICKS)
	_clock.on_snapshot(tick)
	_push_history(tick, _opponent_canonical)
	_vel = data.get("vel", Vector2.ZERO)
	_facing = 1 if int(data.get("facing", 1)) >= 0 else -1
	var aim: Vector2 = data.get("aim", Vector2.ZERO)
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	if absf(_aim.x) > 0.1:
		_aim_facing = 1 if _aim.x > 0.0 else -1
	animator.flip_h = _facing < 0
	# 武器:槽位变了才重建(玩家每次换枪服务器快照带新槽位)。★ type_id == 0(空手)必须与「换了一把」同等对待 —— 那是服务器侧玩家把最后一把丢出去的那一刻;原先写成 type_id > 0 and ..., 空手这一档被整个忽略 ⇒ 副本一直举着那把已经不存在的枪(_swap_weapon(0) 本来就是写好的空手路径,原先只是进不去)。
	var type_id := int(data.get("type_id", 0))
	if type_id != _weapon_type_int:
		_swap_weapon(type_id)
	_previewing = bool(data.get("previewing", false))
	_downed = bool(data.get("downed", false))
	if _downed:
		animator.stop()
		rotation = -PI / 2.0 * float(_facing)   # 倒地转体(与 player._downed 一致)
	else:
		rotation = 0.0
		var pose: int = clampi(int(data["pose"]), 0, POSE_SHAPE.size() - 1)
		_pose = pose
		animator.play(POSE_ANIM.get(pose, "idle"))
		_set_ghost_pose(pose)
	# ★ 幽灵体不随副本根节点的视觉转体而动。倒地分支给根节点设了 rotation = -90°,而幽灵体是它的子节点 ⇒ 碰撞箱跟着转 90°;但服务器侧 player.gd 的倒地分支不旋转,尸体停在最后姿态的箱子上 ⇒ 两端「倒地的对手还挡不挡路」不一致。这里把幽灵体的世界旋转压回 0(等于给子节点一个抵消父节点的局部旋转),只让身体精灵转体;大乱斗 2s 一复活,倒地是常态,这是持续分歧源。
	if _ghost != null:
		_ghost.global_rotation = 0.0

func play_hit(_source_pos: Vector2) -> void:
	_hit_flash_t = HIT_FLASH_TIME

func _swap_weapon(type_id: int) -> void:
	_weapon_type_int = type_id
	if _weapon != null:
		_weapon.queue_free()
		_weapon = null
	var scene_path: String = WeaponRegistry.scene_of(type_id)
	if scene_path.is_empty():
		return
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return
	_weapon = scene.instantiate()
	_weapon_slot_node.add_child(_weapon)

# 枪口朝向 / 仰角:委托 WeaponBase.drive_remote_visual(副本武器不 equip,由其驱动外观,不读鼠标 / 不开火);★ 预瞄红线不在此画(只有使用者本人可见)。★ 第二个参数是 _aim_facing(瞄准侧)不是 _facing(走路朝向):该参数同时决定 clamp_pitch 的折叠坐标系与 scale.x,两者都必须跟「枪指向哪边」;喂走路朝向会让倒走时枪口折到反侧并翘起。身体翻转(animator.flip_h)与倒地转体继续用 _facing。
func _drive_weapon_visual() -> void:
	if _weapon == null or not _weapon.has_method("drive_remote_visual"):
		return
	_weapon.drive_remote_visual(_aim, _aim_facing)

# 对手此刻是否在水中(脚底探针,与本体同口径 —— 本体在 swim_component.update 里同样取 Water.is_in_water(脚底))。★ 这一格不需要协议字段:本体的 in_water 本身就是纯位置网格查询(读 MazeGenerator.current_grid,而 PvP 客户端也建同一张图),故副本在客户端跑同一查询即可:零载荷字段、零 RPC、零服务器改动。★ 位置用渲染用的 global_position(已锚到最近副本、可能不在 [0,MAP))是安全的:Water.is_in_water → GridPathfinder.cell_of 两端都 posmod,而 MAP_WIDTH/HEIGHT 由 GameParameters.refresh_map_size() 按「格数 × TILE_SIZE」算出 ⇒ 恒为 64 的整数倍 ⇒ 整幅平移一个副本后落回同一格(实测:锚到非 canonical 副本与 canonical 查询同值)。
func _in_water() -> bool:
	var gp := global_position
	return Water.is_in_water(Vector2(gp.x, gp.y + _water_feet_off))


func _process(delta: float) -> void:
	if _have_data:
		_drive_weapon_visual()
		if _clock != null:
			_clock.advance(delta)
		var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not _placed:
			global_position = target
			_placed = true
		else:
			# 按播放时钟取样(夹逼插值):延迟是选出来的常量,不是低通滤波器涌现出来的;取样后再锚回可见副本。
			global_position = _sample_history(_clock.render_tick)
			global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# ★★ 幽灵体不跟插值:它跟未经平滑的原始权威位置 target —— 幽灵体要的是最小陈旧(让预测所依据的世界与权威一致),
		# 不是好看;跟插值 = 再晚 67ms,直接变成「本地预测撞在一个位置不对的对手身上」⇒ 多分歧、多回滚。
		if _ghost != null:
			_ghost.global_position = target
	if _hit_flash_t > 0.0:
		_hit_flash_t = maxf(_hit_flash_t - delta, 0.0)
		var on := int(_hit_flash_t * HIT_FLASH_RATE) % 2 == 0
		modulate.a = 0.4 if on else 1.0
		if _hit_flash_t <= 0.0:
			modulate.a = 1.0
	elif modulate.a != 1.0:
		modulate.a = 1.0
	# 补间形变。放在 _process 而不是 apply_snapshot:后者没有 delta,而本函数是副本的表现层时钟(插值推进与受击闪烁衰减都在这儿);挂在快照回调上会与插值产生拍频。★ 参数必须成对:on_floor 取当前姿态,vel_y 取上一帧的值(与本体「_pre_move_vy 配帧首 is_on_floor()」同款)。
	# ★ 组件内部的落地判据是 on_floor and vel_y > squash_land_min_vy:若把当前的 _vel.y 传进去,落地那一帧服务器已经把它清零了 ⇒ 挤压永远不会触发。
	# ★ on_floor 的两半都不能省:pose != FLY 只是「站在地上」的代理,它在两种 _vel.y 并不趋于 0 的状态下同样为真 —— ① 水中下沉(姿态被强制成 MOVE/STAND,而 velocity.y 恒为 player_swim_down = 320);② 空中冲刺(本体把 is_charge 判在 not is_on_floor() 之前,冲刺只改 velocity.x)。代理单独成判 ⇒ 落地项每帧重触发、指数恢复把 _impulse 压到约 -0.91:让对手下沉期间持续约 9% 挤压、冲刺起步满幅 -10%,而本体在这两种状态里都是中性的 ⇒ 两端出现本体从不显示的持续 / 反向形变。★ 这半在计划初稿里就有、曾被删过一次(理由只在调用点传当前 _vel.y 时成立),别删第三次。
	var on_floor := (not _downed) and _pose != POSE_FLY \
			and absf(_vel.y) < LAND_VEL_EPS
	# ★ 水中:本体在 player.gd 把落地候选清零(_pre_move_vy = 0.0 if (in_water or latched)),故本体游泳时精确中性;副本此前没有这一项 ⇒ 下沉期间空中连续项恒成立(clamp(320/700) × 0.30 ≈ 0.137)⇒ 对手下沉全过程恒带约 1.37% 拉伸,而本体是 1.0000。★ 消掉它不需要协议字段:本体的 in_water 本身就是纯位置网格查询,客户端有同一张图 —— 见 _in_water()。★ 爬梯那一半刻意不在这里补:本体的 latched 是闩锁,客户端手里只有无状态的位置代理(中心 / 脚底落在通道格),拿它当判据会对「路过梯子 / 贴梯走过」误触发 ⇒ 那是引入一类本体从不显示的新形变,比留着残留更坏(本轮只修水中那一半);残留如实登记:空中爬梯持续 2.5~3.0% 拉伸、梯底停下那一下约 6.3% 挤压。
	var vel_y := _prev_vel_y
	if _in_water():
		vel_y = 0.0
	squash.tick(delta, vel_y, on_floor, _downed)
	_prev_vel_y = _vel.y