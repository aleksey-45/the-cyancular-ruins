class_name WeaponPickup
extends CharacterBody2D

# 地上的武器(可被按 F 捡起)。
#
# ★ 为什么是**独立场景**而不是"给武器场景加个落地模式":手持武器与地面武器是两种
#   生命周期完全不同的东西 —— 前者挂在 Player 下、由玩家驱动 tick、开火;后者是世界实体、
#   自己走物理、只被拾取查询。合成一个类就要在 WeaponBase 里塞满"我在地上吗"的分支。
#   分开后有一条**不可能搞错**的不变量:手持武器永远没有碰撞体,地面武器永远有。
#
# ★ 视觉复用武器场景实例:WeaponBase **没有 _process/_physics_process**(tick 由玩家显式
#   驱动,为 rollback 确定性),所以一个没人驱动的武器实例天然静止 —— 直接当哑视觉体挂进来
#   即可,不必另做一套地面外观。

const GROUP := "weapon_pickup"

# 掉落物碰撞层 = 层 4(值 8)。掩码只含地形(1)与其它掉落物(8):
#   · 玩家 mask=5、敌人 mask 不含 4 → 天然不碰(不会被地上的枪挡住)
#   · 子弹 mask=5 也不含 4 → 天然穿过(地上的枪不挡子弹)
# ★ 改这两个数之前先看 player.tscn / bullet_base 的掩码 —— 别顺手把 8 或进玩家掩码。
const LAYER_GROUND := 8
const MASK_GROUND := 9

# 世界缩放。武器挂在 Player 下时继承根的 scale=2.5(player.tscn),
# 落到世界里就得自己补上,否则视觉小 2.5 倍。★ 这个数字全项目只此一处。
const WORLD_SCALE := 2.5

@export var type_id: int = 1
var inst: int = 0
var mag: int = 0
var drop_velocity: Vector2 = Vector2.ZERO
var _settled: bool = false
var _age: float = 0.0

# ── 权威位置 vs 渲染位置(2026-09-15)──
# ★ 世界是环面的,协议只传 canonical 坐标。玩家在接缝附近时,一件"在地图另一头"的武器
#   **其实就在身边** —— 但节点画在 canonical 位置就是屏幕外(与敌人/子弹/副本同一个问题)。
#   所以两者分开:canonical_pos 永远在 [0,MAP)(权威,服务器与拾取判定读它),
#   global_position 是**渲染位置**,每帧由 set_anchor() 给的锚点锚到最近副本。
# ★ 本值**就是**这把枪看起来所在的位置:视觉中心已在 _build_collision 里被挪到节点原点
#   (2026-09-17 之前有一个 visual_offset 把两者分开,靠各处补偿来对齐,已整体删除),
#   渲染、碰撞箱、拾取判定圆心三者重合,不存在"第二个中心"。
var canonical_pos: Vector2 = Vector2.ZERO
var _anchor: Vector2 = Vector2.ZERO
var _has_anchor: bool = false


func set_anchor(p: Vector2) -> void:
	_anchor = p
	_has_anchor = true


# 由 canonical_pos 推出渲染位置。没设过锚点时就是 canonical 本身。
func sync_render_from_canonical() -> void:
	if not _has_anchor:
		global_position = canonical_pos
		return
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	global_position = GridPathfinder.anchor_to_nearest(canonical_pos, _anchor, w, h) if (w > 0.0 and h > 0.0) else canonical_pos


func _ready() -> void:
	add_to_group(GROUP)
	collision_layer = LAYER_GROUND
	collision_mask = MASK_GROUND
	scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	rotation = 0.0            # 不旋转:矩形碰撞箱 + 横版简化
	if canonical_pos == Vector2.ZERO:
		canonical_pos = global_position   # 没经 configure 就入树的(探针手摆)以自身位置为准
	if get_child_count() == 0:
		_build_visual()
		_build_collision()
	velocity = drop_velocity


# 由生成方调用。★ **必须在 add_child 之前调** —— `_ready` 会按当时的 type_id 建视觉与碰撞箱,
# 先入树再 configure 的话 `_ready` 已经用 @export 默认值(手枪)建过一次了。
# 入树后仍可调(热改),但那时走的是重建路径,见下面的 remove_child。
func configure(p_type_id: int, p_inst: int, p_mag: int, p_vel: Vector2) -> void:
	type_id = p_type_id
	inst = p_inst
	mag = p_mag
	drop_velocity = p_vel
	velocity = p_vel
	_settled = false
	if not is_inside_tree():
		return
	# ★ 必须先 `remove_child` 再 `queue_free`:`queue_free` 只是**标记**,节点要到帧末才真的没了,
	#   于是新 Visual 加进来时旧的那个还占着 "Visual" 这个名字 → Godot 给新节点**自动改名**,
	#   随后 `_build_collision()` 的 `get_node_or_null("Visual")` 抓到的是**旧的那份**
	#   (按 @export 默认 type_id 建的)→ 碰撞箱来自另一把枪。remove_child 让名字当场释放。
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_build_visual()
	_build_collision()


func _build_visual() -> void:
	var scene: PackedScene = load(WeaponComponent.WEAPONS.get(str(type_id), ""))
	if scene == null:
		push_warning("WeaponPickup: 槽 %d 没有武器场景,地面掉落物将是空壳" % type_id)
		return
	var w: Node2D = scene.instantiate()
	w.name = "Visual"
	# ★ 不写 w.player = null —— WeaponBase.player 默认就是 null(没人调过 equip),
	#   而按 Node2D 标注的变量动态写一个不存在的属性会在运行时炸。
	w.scale = Vector2.ONE     # 朝向固定为右;WeaponBase 没有 _process,不 tick 就是静止的
	w.rotation = 0.0
	add_child(w)


func _build_collision() -> void:
	# ★ 标成 Node2D 而不是 Node:下面要读写 vis.position,按 Node 推断的话它没有 position
	#   (`var x := vis.position + …` 会因"值没有确定类型"直接**解析失败**)。
	var vis := get_node_or_null("Visual") as Node2D
	if vis == null:
		return
	var spr: Sprite2D = vis.get_node_or_null("Sprite2D")
	if spr == null:
		return
	var r: Rect2 = SpriteBounds.from_sprite(spr)
	if r.size == Vector2.ZERO:
		return
	# 将视觉中心平移对齐至 body 原点，使渲染位置、碰撞体与拾取判定圆心保持一致。
	# gun_center 需计入武器根节点自身的 position，确保各类型武器拾取判定圆心均准确对齐。
	var gun_center := vis.position + spr.position + r.position + r.size * 0.5
	vis.position -= gun_center
	var cs := CollisionShape2D.new()
	cs.name = "Shape"
	var rect := RectangleShape2D.new()
	rect.size = r.size
	cs.shape = rect
	cs.position = Vector2.ZERO      # 视觉中心已对齐在原点
	add_child(cs)


func _physics_process(delta: float) -> void:
	# 时间场倍率适配：掉落物属于世界物体，加速时随环境减速，回溯时保持冻结。
	# 仅作用于未静止阶段；静止后跳过常规物理移动计算。
	delta = TimeField.world_delta(delta)
	_age += delta
	if _settled:
		# 静止后位置不变，但跟随玩家移动动态调整最近环面副本锚点；
		# 同时进行防嵌入检测，防止可破坏砖块恢复时将掉落物嵌入墙体。
		_unstick_up()
		sync_render_from_canonical()
		return
	velocity.y += PlayerParams.weapon_fall_gravity * delta
	if is_on_floor():
		velocity.x *= exp(-PlayerParams.weapon_ground_friction * delta)
	else:
		velocity.x *= exp(-PlayerParams.weapon_air_drag * delta)
	move_and_slide()
	_recompute_canonical()
	_unstick_up()
	sync_render_from_canonical()
	# 停止判定基于速度阈值（速度低于阈值时置零），确保不同步启动时间下的最终落点保持严格确定性。
	if is_on_floor() and absf(velocity.x) < PlayerParams.weapon_stop_eps:
		velocity = Vector2.ZERO
		_settled = true


# 环面:物理走出来的是世界坐标,取模回 canonical 存进 canonical_pos;
# 渲染位置再由它锚到玩家最近副本(两者分工见字段注释)。
# 渲染位置可能是**接缝外的副本**(canonical + k×地图尺寸),fposmod 正好把它折回 canonical。
func _recompute_canonical() -> void:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if w > 0.0 and h > 0.0:
		canonical_pos = Vector2(fposmod(global_position.x, w), fposmod(global_position.y, h))
	else:
		canonical_pos = global_position


# 嵌进实心格(贴墙丢弃、或停稳后可破坏砖被重铺盖在它身上)→ 向上挤出去。
# 几何来源统一走 CollisionAabb(已含 body 的 scale=2.5),不自己再拼一遍矩形。
# 返回是否真的动过。
func _unstick_up() -> bool:
	if not CollisionAabb.has_any(self):
		return false        # 没有碰撞体就没东西可挤(精灵全透明等)
	var dy := Unstick.push_up_dy(CollisionAabb.world_rect(self), GameParameters.TILE_SIZE)
	if dy <= 0.0:
		return false
	global_position.y -= dy
	velocity.y = 0.0
	_settled = false        # 解掉停稳,让重力重新接管(可能被推进了空中,该重新落一次)
	_recompute_canonical()
	return true


# 刚落地多久(秒)。拾取侧用它做"自己刚丢下的枪不立刻捡回"的冷却。
func age() -> float:
	return _age


# ── 拾取提示(用户 2026-09-16:「只要能捡起就会显示 F」→ **每把可捡的各自一个**)──
var _prompt: PickupPrompt = null


# 由持有方每帧按"这把现在能不能捡"开关。懒建:没人靠近过就不建节点。
func set_prompt_visible(v: bool) -> void:
	if v and _prompt == null:
		_prompt = PickupPrompt.new()
		# ★ 反向缩放:本节点 scale = WORLD_SCALE(2.5),而提示要按**世界单位**画
		#   (与 EnemyHpBar 那种挂在世界里的节点同尺寸),所以子节点乘 1/2.5 抵消掉。
		_prompt.scale = Vector2.ONE / WORLD_SCALE
		_prompt.position = Vector2(0.0, -PickupPrompt.GAP_ABOVE / WORLD_SCALE)
		add_child(_prompt)
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.visible = v
