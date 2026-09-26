extends Node2D
# PvP 远端玩家副本:视觉(复用 Player 的 SpriteFrames/动画 + 各武器场景外观),由快照驱动。
# ★ 它**不是**纯视觉:还带一个只参与碰撞的「幽灵体」(见 _build_ghost_body)。原因:C2 客户端预测
#   只步进自己的玩家,若客户端世界里没有对手身体,「对手挡住我」这条信息在预测侧根本不存在 →
#   本地预测穿过去、服务器把你挡住 → 每帧分歧、每帧回滚(C2 的无限回滚循环,不是调参能缓解的)。
#   幽灵体让预测所依据的世界与权威世界一致。★ 它只**减小**分歧不消除(副本位置比权威落后一点),
#   验收按「回滚次数下降多少」量,别按「归零」验收。
# pose/facing/aim/previewing/downed/weapon 按「最新快照」即时套用(反应不落后,位置才平滑)。
#
# 位置走「自身差分指数追赶」:每帧朝「锚到本地玩家最近副本的目标点」按 `1 - exp(-INTERP_RATE*Δ)`
# 收敛。**2026-09-22 用户裁定,从「双快照 tick 域 alpha 插值」改回这个方案** —— 依据是实测:
# `SnapshotInterp.push()` 每收一包就把渲染时钟重置到 `latest - 1`,而 `advance()` 每帧推进
# `delta * 60`;在 **60fps 渲染 + 60Hz 快照**下那恰好是 1.0 tick ⇒ 下一帧时钟正好落在 `latest`
# 上,`sample()` 走"冻结在最新"那一支 ⇒ 渲染的就是**最新包的原值**,与"绕过插值直落"逐项相同。
# 于是对手的平滑度 == 包的到达平滑度:到达抖动 ±8ms 时 **11.67% 的帧零位移、单帧走到 2 个包的
# 距离**(±16ms 时 24.67% / 3 个包)—— 也就是用户报的「位置一跳一跳,看起来敌方掉帧」。
# 指数追赶对同样的到达抖动是**连续**收敛,不把抖动原样透传到画面上。
# 读数由 `tests/replica_smoothness_probe.tscn` 常驻钉住(改前红 / 改后绿)。
# ★★ 旧方案当年那条**致命缺陷已单独修掉、且必须一直保留**:渲染位置与目标相隔整幅地图时
# 最短向量为 0 ⇒ 副本一旦漂到远副本就**永远留在那儿**(对手被渲染到屏幕外「看不见」)。
# 现在的解法是把**目标点**锚到本地玩家最近副本再以普通差量追赶 —— 这与"平滑 vs 插值"**无关**,
# 是独立的一件事。**别"顺手简化"掉下面那两个 `anchor_to_nearest`。**

# 指数追赶速率(越大越跟手)。取自 2026-09-03 的 `aa1d8f0^`(旧平滑方案的最后一个版本;
# 该常量本身从 `2cfbea3` 起就是这个值)—— 刻意复用旧值,不新调参。
const INTERP_RATE := 12.0

const POSE_ANIM: Dictionary = {
	0: "idle", 1: "move", 2: "fly", 3: "charge", 4: "squat",
}  # 与 player.gd Pose 枚举值一致

# Pose.FLY 的值(与 player.gd 的 `enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }` 里 FLY 一致)。
# 本类 extends Node2D、不继承 Player,引用不到那个枚举 —— 而下面按 pose 分支需要它。
# ★ 刻意**不写行号**:该枚举在密集改动区,写死的行号漂过两次(见 spec「行号是负资产」)。
const POSE_FLY := 2

# 副本的"站在地上"判据里,「当前 _vel.y 已骤降到 ≈0」那一半的容差。
# 本体那份由物理保证(地面上 velocity.y 恒 0),副本没有物理,必须显式判。
const LAND_VEL_EPS := 1.0

# 脚底探针偏移(世界 px):水中查询要与本体同口径 —— 本体走 `Water.is_in_water(脚底)`,
# 脚底 = 原点 + `Water.feet_offset(自己)`。取值在 _ready 里**一次性**问幽灵体(见下)。
# ★ 为什么一次性问幽灵体、而不是写死一个数:幽灵体的 5 份姿态多边形是从 player.tscn **现抄**的、
#   根同样是 scale 2.5 ⇒ `to_global` 出来的底边与本体逐像素相同(实测 stand = 57.0)。写死数会随
#   player.tscn 的碰撞箱改动**静默漂**(水花线那种"看着没事、其实偏了"的错)。
# ★ 为什么是**常量**而不是逐帧按姿态重算:本体那边实际也是常量 —— `Water.feet_offset` 的缓存
#   签名只数 `CollisionShape2D` 子节点(water.gd:_feet_signature),而玩家 5 份姿态箱全是
#   `CollisionPolygon2D`(player.tscn)⇒ 签名恒为 0、缓存永不失效 ⇒ 逐帧问与问一次同值。
# ★ 与本体那 1px 的差(如实登记):本体**首帧**调用时 5 个姿态箱在场景里全是启用态
#   (player.tscn 不带 disabled,而 `swim.update` 排在 `_tick_pose_and_collision` **之前**)
#   ⇒ 它缓存的是**5 箱合并**底边 = 58.0;副本这里是幽灵体当时启用的 stand 那一份 = 57.0。
#   差 1px。**刻意不去逐像素对齐它**:那等于把本体的缓存口径抄进第二个地方,而那份缓存哪天
#   被修成"跟着姿态走"时,抄来的 58 会朝**反**方向漂 1px。57 才是 feet_offset 的语义值
#   ("启用中的碰撞箱底边")。1px 在 64px 量化的格查询里最多让判据在下沉的一帧内(320px/s
#   ≈ 5.3px/帧)提前/延后一次,可感度为零。
var _water_feet_off: float = 24.0   # 24 = Water.feet_offset 的兜底值(幽灵体取不到时同款)

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

# 补间形变(squash & stretch)。副本复用与本体同一个组件,数据换成快照。
var squash: SquashStretch = null
# 快照里的速度与姿态。`vel` **本来就在服务器载荷里**(server/match_snapshot.gd:20),
# 副本此前只是没读它 —— 加这个字段是"客户端开始读一个已存在的字段",协议零改动。
var _vel: Vector2 = Vector2.ZERO
var _pose: int = 0
# 上一帧的 vel.y。组件靠"上次在下落 + 现在已经落地"这一**对**值推导落地冲击,单看当前的
# _vel.y 推不出来 —— 服务器在落地那一帧就把它清零了。与本体 "_pre_move_vy 配帧首
# is_on_floor()" 是同款配对(见 spec §2.4)。
var _prev_vel_y: float = 0.0

var _weapon_slot_node: Node2D        # 武器挂点(运行时加,排在 AnimatedSprite2D 后 → 画在身体上层)
var _weapon: Node2D = null           # 当前武器场景实例(惰性:未 equip,仅外观)
var _weapon_type_int := 0            # 服务器权威槽位
# 最新快照的服务器 canonical 位置 —— 指数追赶的**目标**来源(每帧锚到本地玩家最近副本,见 _process)。
var _opponent_canonical := Vector2.ZERO
var _local_anchor := Vector2.ZERO         # 本地玩家(相机)位置,每帧跟随
var _have_data := false
# 首次定位是否已**直落**(见 _process)。★ 指数追赶**不能**用于开场第一帧:副本被创建在世界
# 原点,直接开始追赶要十几帧才到位,而那十几帧里幽灵体停在错位置 ⇒ 本地预测与权威分歧
# ⇒ 白回滚一次(replica_ghost_probe ② 实测:直落时 rb=0,追赶时 rb=1)。旧方案(`aa1d8f0^`)
# 没有这一条,是因为那会儿副本走的是"缓冲未满时直落最新权威位置"那条支路 —— 平滑换回来时
# 这一半被一起丢了,故在此显式补回。
var _placed := false
var _facing := 1
# **瞄准侧**(与 `_facing` **不是**同一个量,枪口外观只认这一个)。`_facing` 来自快照的
# `facing` 字段 = 服务器的 `facing_direction` = **走路朝向**(player.gd 的移动代码排在
# `weapons.tick` **之后**,每帧覆盖 `_auto_aim` 写进去的瞄准侧);而枪口俯仰必须按**瞄准侧**
# 折叠(clamp_pitch 先 `dir.x * facing`)。二者混用时,倒着走(A 往左走、鼠标朝右)会让
# `local = (-1, 0.3)` → 163° → 钳到 +limit → 再 `× -1` ⇒ 枪口**折到反侧极限而上翘**
# (2026-09-21 用户报:"A 往回走的时候,在 B 眼里枪还会翘起来"）。
# 本体那边由 `_auto_aim` 的 `_aim_facing` 承担同一职责(它算出的瞄准侧与身体朝向分离),
# 下面是它的逐字同款规则(见 weapon_base.gd 的 `_auto_aim`):鼠标有明确水平分量则跟随并
# **记住**,近垂直瞄(±0.1 以内)沿用上次明确侧,不随走路翻侧。
var _aim_facing := 1
var _aim := Vector2(1.0, 0.0)
var _previewing := false   # 对手是否正在预瞄(heavy 蓄力)。快照仍带该字段,但**不再驱动任何外观**
                           # ——预瞄红线只有使用者本人可见(用户裁定 2026-09-11);保留是给日后
                           # 想换成别的提示形式(音效/轮廓)时用,届时从 _drive_weapon_visual 接。
var _downed := false
var _hit_flash_t := 0.0

# ── 幽灵碰撞体(只碰撞、不参与任何逻辑)──
var _ghost: StaticBody2D = null
var _ghost_shapes: Dictionary = {}   # pose(int) -> CollisionPolygon2D

func _ready() -> void:
	add_to_group(GROUP)
	# 复用 player.tscn 的内联 SpriteFrames —— 同一次实例化顺带把 5 份姿态碰撞多边形抄给幽灵体
	# (单一来源:日后改 player.tscn 的碰撞箱,副本自动跟上,不会漂)
	var tmp := preload("res://scenes/player/player.tscn").instantiate()
	animator.sprite_frames = tmp.get_node("AnimatedSprite2D").sprite_frames
	_build_ghost_body(tmp)
	tmp.free()
	# 脚底探针偏移:一次性问幽灵体(_build_ghost_body 把 stand 那份多边形留作启用态,
	# 与本体首次调用 feet_offset 时的姿态一致)。详见 _water_feet_off 的说明。
	_water_feet_off = Water.feet_offset(_ghost) if _ghost != null else 24.0
	_weapon_slot_node = Node2D.new()
	_weapon_slot_node.name = "WeaponSlot"
	add_child(_weapon_slot_node)
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)

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

# 幽灵体所在碰撞层。★ **默认值不变**(`_build_ghost_body` 里那句 2,全项目唯一一处),
# 本函数只是把它变成可改的:3v3 按**该副本代表的那名玩家**的队配层(队 B 的玩家身体在层 16,
# 见 `TeamHost.TEAM_ENEMY_LAYER` 那张契约表)。1v1 / 大乱斗**不调它** ⇒ 行为逐字不变。
# ★ 为什么必须跟着队走:幽灵体的全部用途是让"预测所依据的世界"与权威一致。队友之间是
#   **完全穿透**(服务器侧两队掩码互指对方的位),副本若恒在层 2,本地预测就会被队友挡下 ——
#   而服务器上他穿过去了 ⇒ 每帧分歧、每帧回滚(C2 的无限回滚循环,与"幽灵体缺失"同一个形状)。
func set_ghost_layer(n: int) -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.collision_layer = n


# 幽灵体按姿态切换碰撞箱(与 player.gd 的 _coll_by_pose 同款)。形状必须跟姿态走:
# 否则蹲下躲进矮通道的对手仍按站姿挡路,预测侧又会与权威不一致。
func _set_ghost_pose(pose: int) -> void:
	for p in _ghost_shapes:
		(_ghost_shapes[p] as CollisionPolygon2D).disabled = p != pose

# ★ 第三个形参 `_tick` 现在**不参与任何计算**(位置不再走 tick 域缓冲),保留它纯粹是为了
#   不改调用面:三个生产调用点(`pvp_game` / `royale_game` / `team_game`)与一批探针都按
#   三参调用,快照的 `tick` 也确实是副本的契约字段(哪天要按 tick 丢乱序包就得用它)。
#   名字带下划线 = GDScript 不再报 UNUSED_PARAMETER。
func apply_snapshot(data: Dictionary, local_anchor: Vector2, _tick: int) -> void:
	_opponent_canonical = data["pos"]
	_local_anchor = local_anchor
	_have_data = true
	_vel = data.get("vel", Vector2.ZERO)
	_facing = 1 if int(data.get("facing", 1)) >= 0 else -1
	var aim: Vector2 = data.get("aim", Vector2.ZERO)
	_aim = aim if aim != Vector2.ZERO else Vector2(float(_facing), 0.0)
	# 瞄准侧=枪口外观唯一的朝向来源(见 `_aim_facing` 的说明)。规则照抄 `_auto_aim` 的
	# `weapon_base.gd` 那三行:明确水平分量才翻侧并**闩住**,近垂直瞄沿用上次。
	# `_aim` 的零向量兜底(上面那行落成 `(±_facing, 0)`)天然落进"明确分量"那一支 ⇒
	# 快照不给方向时,瞄准侧会自动跟随走路朝向(与旧行为一致,不是退化)。
	if absf(_aim.x) > 0.1:
		_aim_facing = 1 if _aim.x > 0.0 else -1
	animator.flip_h = _facing < 0
	# 武器:槽位变了才重建(玩家每次换枪服务器快照带新槽位)。
	# ★ `type_id == 0`(空手)必须与"换了一把"同等对待 —— 那是服务器侧玩家把**最后一把**丢出去的
	#   那一刻。原先写成 `type_id > 0 and type_id != ...`,空手这一档被整个忽略 → 副本**一直举着那把
	#   已经不存在的枪**。`_swap_weapon(0)` 本来就是写好的空手路径(注册表查不到 → 留空),
	#   原先只是进不去。开局人手一把,所以"对手把枪丢了"几乎必然命中它;握两把以上时丢一把会
	#   自动换到另一把(type_id 变了,照常重建)—— 这也正是它一直没被发现的原因。
	var type_id := int(data.get("type_id", 0))
	if type_id != _weapon_type_int:
		_swap_weapon(type_id)
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
		_pose = pose
		animator.play(POSE_ANIM.get(pose, "idle"))
		_set_ghost_pose(pose)
	# ★ 幽灵体不随副本根节点的**视觉**转体而动。上面倒地分支给根节点设了 rotation = -90°,
	#   而幽灵体是它的子节点 → 会被一起转,碰撞箱跟着转 90°;但服务器侧 player.gd 的倒地分支
	#   **不旋转**(全文件零 rotation),尸体停在最后姿态的箱子上 → 两端"倒地的对手还挡不挡路"
	#   不一致。这里把幽灵体的**世界**旋转压回 0(等于给子节点一个抵消父节点的局部旋转),
	#   只让身体精灵转体。大乱斗 2s 一复活,倒地是常态,这是持续分歧源。
	if _ghost != null:
		_ghost.global_rotation = 0.0
	# 位置不在这里动:本类没有 delta,而指数追赶必须逐帧推进 —— 见 _process。

# 服务器裁决命中:打的是对手 → 副本受击反馈(白闪/眨眼),让射手看到"打中了"。
func play_hit(_source_pos: Vector2) -> void:
	_hit_flash_t = HIT_FLASH_TIME

# 按槽位换武器外观:只挂 WeaponBase 场景做静物(不 equip → 其 _process 因 player==null 早退,惰性)。
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

# 枪口朝向/枪口仰角:委托 WeaponBase.drive_remote_visual(副本武器不 equip,由其驱动外观,
# 不读鼠标/不开火)。★ 预瞄红线**不在此画**(用户裁定 2026-09-11:只有使用者本人可见)。
# ★ 第二个参数是 **`_aim_facing`(瞄准侧)不是 `_facing`(走路朝向)**:该参数同时决定
#   `clamp_pitch` 的折叠坐标系与 `scale.x`,两者都必须跟"枪指向哪边"。喂走路朝向会让
#   倒走时枪口折到反侧并翘起(见 `_aim_facing` 说明);身体翻转(animator.flip_h)与倒地
#   转体继续用 `_facing`,那是它本来就正确的地方。
func _drive_weapon_visual() -> void:
	if _weapon == null or not _weapon.has_method("drive_remote_visual"):
		return
	_weapon.drive_remote_visual(_aim, _aim_facing)

# 对手此刻是否在水中(**脚底**探针,与本体同口径 —— 本体在 swim_component.update 里同样取
# `Water.is_in_water(脚底)`)。
# ★ 这一格**不需要协议字段**:本体的 `in_water` 本身就是**纯位置网格查询**(swim_component.gd
#   读 `MazeGenerator.current_grid`,而 PvP 客户端也建同一张图 —— `WorldBuilder.load_grid` 三处
#   共用),故副本在客户端跑同一查询即可:零载荷字段、零 RPC、零服务器改动。
# ★ 位置用渲染用的 `global_position`(已锚到最近副本、可能不在 [0,MAP))**是安全的**:
#   `Water.is_in_water` → `GridPathfinder.cell_of` 两端都 `posmod`,而 MAP_WIDTH/HEIGHT 由
#   `GameParameters.refresh_map_size()` 按 `格数 × TILE_SIZE` 算出 ⇒ 恒为 64 的整数倍 ⇒
#   整幅平移一个副本后落回**同一格**(实测:锚到非 canonical 副本与 canonical 查询同值)。
func _in_water() -> bool:
	var gp := global_position
	return Water.is_in_water(Vector2(gp.x, gp.y + _water_feet_off))


func _process(delta: float) -> void:
	if _have_data:
		_drive_weapon_visual()
		# 目标 = 对手 canonical 锚到本地玩家(相机)最近副本,每帧重算(跟随相机跨接缝)。
		var target := MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# 首次定位**直落**(理由见 `_placed`):目标本身已锚到本地玩家最近副本,直接落上去即可。
		if not _placed:
			global_position = target
			_placed = true
		else:
			# 当前渲染位置也锚到 target 所在的副本空间,再做**普通差量**追赶。
			# ★★ 别改成 `toroidal_delta_px(global_position, target, …)` 的"最短路径"写法:渲染位置与
			#   目标相隔整幅地图时最短向量为 0,副本一旦漂到远副本就永远留在那儿(对手渲染到屏幕外
			#   「看不见」)—— 那正是旧方案被替换掉的原因。先把两端各自锚进同一副本空间,差量才是
			#   要追赶的那个真实位移。
			var current := MazeGenerator.anchor_to_nearest(global_position, target,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
			# 渲染位置归到本地玩家(相机)最近副本:确保渲染在可见副本,不留在远副本。
			global_position = MazeGenerator.anchor_to_nearest(global_position, _local_anchor,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		# ★★ 幽灵体**不跟着平滑走**(2026-09-22):它跟的是**未经平滑的原始权威位置** `target`。
		#   幽灵体的唯一职责是让"预测所依据的世界"与权威世界一致(见文件头),它要的是
		#   **最小陈旧**,不是好看。而指数追赶是个低通滤波器 —— 目标以 300px/s 移动时它额外
		#   落后 `v / INTERP_RATE ≈ 25px`,那 25px 会直接变成"本地预测撞在一个位置不对的对手
		#   身上" ⇒ 白白多出分歧。
		#   ★ 这条还保证了一件更要紧的事:**预测路径与改回指数追赶之前逐位相同** —— 那时的
		#     alpha 插值在 60fps 下退化成"直落最新包"(见文件头),幽灵体跟的就是这个原始值。
		#     所以"画面变平滑"与"回滚面零回归"两件事可以同时成立,不必二选一。
		#   ★ `target` 与渲染位置用的是**同一个** anchor_to_nearest,故两者仍在同一副本空间。
		if _ghost != null:
			_ghost.global_position = target
	# 受击闪烁:本地玩家被打是 iframe 半透明眨眼,副本同款(看得见"打中了")。
	if _hit_flash_t > 0.0:
		_hit_flash_t = maxf(_hit_flash_t - delta, 0.0)
		var on := int(_hit_flash_t * HIT_FLASH_RATE) % 2 == 0
		modulate.a = 0.4 if on else 1.0
		if _hit_flash_t <= 0.0:
			modulate.a = 1.0
	elif modulate.a != 1.0:
		modulate.a = 1.0
	# 补间形变。放在 _process 而不是 apply_snapshot:后者没有 delta,而本函数是副本的
	# **表现层时钟**(插值推进与受击闪烁衰减都在这儿)。挂在快照回调上会与插值产生拍频。
	# ★ 参数必须**成对**:on_floor 取**当前**姿态,vel_y 取**上一帧**的值。这与本体
	#   "_pre_move_vy 配帧首 is_on_floor()" 是同款配对 —— 组件内部的落地判据是
	#   `on_floor and vel_y > squash_land_min_vy`,若把当前的 _vel.y 传进去,落地那一帧
	#   服务器已经把它清零了,挤压**永远不会触发**。
	# ★ on_floor 的**两半都不能省**。`pose != FLY` 只是"站在地上"的**代理**,它在两种
	#   `_vel.y` 并不趋于 0 的状态下**同样为真**:
	#     ① 水中下沉(本图最常见):姿态被强制成 MOVE/STAND,而 `velocity.y` **恒为**
	#        player_swim_down(=320,一个常量);
	#     ② 空中冲刺:本体的姿态逻辑把 `is_charge` 判在 `not is_on_floor()` **之前**,故下落
	#        途中起步的冲刺给出 on_floor=true,而冲刺只改 velocity.x。
	#   代理单独成判 ⇒ 落地项**每帧重触发**,指数恢复把 `_impulse` 压到 ≈ -0.91:
	#   ① 让对手**下沉期间持续** ~9% 挤压,② 更是满幅 -10%;而本体在这两种状态里都是中性的
	#   (水中 `_pre_move_vy` 被清零、冲刺只走拉伸),即两端出现本体**从不显示**的持续/反向形变。
	#   (另有一次性小项:带速入水那一帧 pose 先翻、`_prev_vel_y` 还攥着落速 → 假的水花挤压;
	#    本判据把它一并挡掉,因为入水帧的当前 `_vel.y` 已不是 ≈0。)
	#   ★ 历史:这半在计划初稿里就有,Task 2 阶段因"与 `vel_y > squash_land_min_vy` 互斥"
	#     被删 —— 那个理由只在调用点传**当前** `_vel.y` 时成立;现在传的是 `_prev_vel_y`
	#     (见上),故必须加回。**别删第三次。**
	var on_floor := (not _downed) and _pose != POSE_FLY \
			and absf(_vel.y) < LAND_VEL_EPS
	# ★ 水中:本体在 player.gd 把落地候选清零(`_pre_move_vy = 0.0 if (in_water or latched)`),
	#   故本体游泳时**精确中性**;副本此前没有这一项 ⇒ 下沉期间空中连续项恒成立
	#   (`clamp(320/700) × 0.30 ≈ 0.137`,`320` = `PlayerParams.player_swim_down`,一个常量)
	#   → 对手下沉的全过程恒带 ~1.37% 拉伸(= scale (0.9863, 1.0137)),而本体是 1.0000。
	#   ★ 消掉它**不需要协议字段**(旧记录称"要归零就得加字段",已作废):本体的 in_water
	#     本身就是纯位置网格查询,客户端有同一张图 —— 见 _in_water()。
	# ★ 爬梯那一半**刻意不在这里补**:本体的 `latched` 是**闩锁**,客户端手里只有无状态的位置
	#   代理("中心/脚底落在通道格"),拿它当判据会对"路过梯子/贴梯走过"误触发 ⇒ 那是**引入
	#   一类本体从不显示的新形变**,比留着残留更坏(用户裁定:本轮只修水中那一半)。
	#   残留据此**如实登记**(spec §4.3):空中爬梯持续 2.5~3.0% 拉伸、梯底停下那一下 ~6.3% 挤压。
	var vel_y := _prev_vel_y
	if _in_water():
		vel_y = 0.0
	squash.tick(delta, vel_y, on_floor, _downed)
	# ★ `_prev_vel_y` 记的是**原始** `_vel.y`(与本体记原始 velocity.y 同款):过滤只发生在
	#   **传参那一刻**,出水的下一帧宿主也立刻回到原始值,故两侧同相位。
	_prev_vel_y = _vel.y
