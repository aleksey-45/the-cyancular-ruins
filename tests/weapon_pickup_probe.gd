extends Node

# 地面武器(WeaponPickup)探针。场景模式 —— 判据是 **grep 文本 `WEAPON PICKUP: ALL-OK`**,
# 不能只看退出码(中途报错时 --quit-after 仍 exit 0 且不打印 ALL-OK)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 900 res://tests/weapon_pickup_probe.tscn
#
# ═══ 钉三件日常看不出来的事 ═══
#   ① 碰撞层归属:玩家与子弹都**不该**碰地上的枪。改错了的表现是"走过去被枪挡住"
#      或"子弹打在地上消失",而两者都不会报错。
#   ② 像素碰撞箱真的生成了(而不是走了空壳、碰撞箱缺席 —— 那会让拾取判定飘)。
#   ③ **落点与"何时开始模拟"无关** —— 这是联机端"客户端晚一个 RTT 才收到事件、
#      却必须落在同一位置"的前提。把摩擦从"速度阈值置零"改成"滑固定时长"就会破,
#      而破了之后单机完全正常,只在联机端表现为"看着够不着"。

var _failures: Array[String] = []

const PICKUP_SCENE := "res://scenes/weapons/weapon_pickup.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"


func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)


func _ready() -> void:
	await _phase_layers()
	await _phase_collision_shape()
	await _phase_landing_determinism()
	await _phase_inventory_roundtrip()
	await _phase_visual_built()
	if _failures.is_empty():
		print("WEAPON PICKUP: ALL-OK")
		get_tree().quit(0)
	else:
		printerr("WEAPON PICKUP FAILURES: " + str(_failures))
		get_tree().quit(1)


# ── ① 碰撞层归属 ──
func _phase_layers() -> void:
	var scene: PackedScene = load(PICKUP_SCENE)
	_check(scene != null, "weapon_pickup.tscn 可加载")
	if scene == null:
		return
	var pk: WeaponPickup = scene.instantiate()
	add_child(pk)
	await get_tree().physics_frame
	_check(pk.collision_layer == 8, "地面武器在层 4(值 8)")
	_check(pk.collision_mask == 9, "地面武器掩码 = 地形|掉落物 = 9")
	_check(pk.collision_mask & 2 == 0, "地面武器不得与玩家(层 2)碰撞")
	_check(pk.collision_mask & 4 == 0, "地面武器不得与敌人(层 3)碰撞")
	_check(pk.is_in_group(WeaponPickup.GROUP), "地面武器入了 weapon_pickup 组(拾取查询靠它)")

	# 反向:玩家掩码里也不该出现掉落物层(加了就是"玩家被地上的枪挡住")
	var ps: PackedScene = load(PLAYER_SCENE)
	var pl: Node = ps.instantiate()
	add_child(pl)
	await get_tree().physics_frame
	_check(pl.collision_mask & 8 == 0, "玩家掩码不含掉落物层")
	# 与 enemy_logic_smoke 的同类断言同源:单机下玩家掩码仍是 5
	_check(pl.collision_mask == 5, "玩家掩码仍应是 5(实际 %d)" % pl.collision_mask)
	pl.queue_free()
	pk.queue_free()
	await get_tree().physics_frame


# ── ② 像素碰撞箱真的建出来了 ──
func _phase_collision_shape() -> void:
	var pk: WeaponPickup = load(PICKUP_SCENE).instantiate()
	pk.configure(1, 1, 12, Vector2.ZERO)
	add_child(pk)
	await get_tree().physics_frame
	var cs: CollisionShape2D = pk.get_node_or_null("Shape")
	_check(cs != null, "应按 sprite 像素生成 CollisionShape2D")
	if cs != null and cs.shape is RectangleShape2D:
		var sz: Vector2 = (cs.shape as RectangleShape2D).size
		_check(sz.x > 4.0 and sz.y > 2.0, "碰撞箱尺寸应来自真实像素(实际 %s)" % str(sz))
	else:
		_failures.append("碰撞箱不是矩形(或不存在)")
	pk.queue_free()
	await get_tree().physics_frame


# ── ③ 落点与"何时开始模拟"无关 ──
func _phase_landing_determinism() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var fshape := CollisionShape2D.new()
	var frect := RectangleShape2D.new()
	frect.size = Vector2(12000, 64)   # 够宽:两把掉落物各滑 ~220px 且相距 1000px,都得落在地板上
	fshape.shape = frect
	floor_body.add_child(fshape)
	floor_body.position = Vector2(0, 300)
	add_child(floor_body)
	await get_tree().physics_frame

	var a: WeaponPickup = load(PICKUP_SCENE).instantiate()
	a.configure(1, 1, 12, Vector2(400.0, 0.0))
	add_child(a)
	a.global_position = Vector2(0, 0)

	# ★ 第二把同初速,但**延迟 20 个物理帧**才开始 —— 如实模拟"客户端晚一个 RTT 才收到事件"。
	#   两者最终横坐标必须一致:停止位置只取决于初速与摩擦,**与开始时刻无关**。
	for i in 20:
		await get_tree().physics_frame
	# ★ 两把必须**同型号**(这里都是 type_id=1)。用不同型号会得到一个假红:不同武器的
	#   精灵碰撞箱高度不同 → 下落距离不同 → **空中时长不同** → 空气阻力的衰减量不同 →
	#   落点天然不同。那不是"相位依赖",是"拿两种东西比"。
	# ★ 两把还必须**拉开距离**:掉落物掩码含层 8(= 与其它掉落物碰),同 x 起滑会互相顶,
	#   测出来的是"两把枪挤在一起",不是"相位依赖"。1000px 远超各自的滑行距离(~220px),
	#   且落在地板范围内(地板 12000 宽,居中于 0)。
	var b: WeaponPickup = load(PICKUP_SCENE).instantiate()
	b.configure(1, 2, 12, Vector2(400.0, 0.0))
	add_child(b)
	b.global_position = Vector2(1000, 0)

	var a_land := -1
	var b_land := -1
	var a_set := -1
	var b_set := -1
	for i in 400:
		await get_tree().physics_frame
		if a_land < 0 and a.is_on_floor():
			a_land = i
		if b_land < 0 and b.is_on_floor():
			b_land = i
		if a_set < 0 and a._settled:
			a_set = i
		if b_set < 0 and b._settled:
			b_set = i
		if a._settled and b._settled:
			break
	# 诊断读数:两者应当"落地帧差 ≈ 延迟帧数、滑动帧数相同"。
	# 差得多就说明摩擦之外还有别的相位依赖(而不是我预期的那条)。
	print("[pickup-probe] a 落地@%d 停稳@%d x=%.2f | b 落地@%d 停稳@%d x=%.2f"
			% [a_land, a_set, a.global_position.x, b_land, b_set, b.global_position.x])
	_check(a._settled, "第一把应停稳(settled)")
	_check(b._settled, "第二把应停稳(settled)")
	# b 起点比 a 右移 1000(见上:避免两把互相顶),比的是"各自滑了多远"
	var dx := absf(a.global_position.x - (b.global_position.x - 1000.0))
	_check(dx < 1.0,
			"落点与「何时开始模拟」无关(差 %.2f px;大了说明摩擦被改成按时间停)" % dx)
	# 测试自身的有效性:没滑出去的话上面那条恒真
	_check(a.global_position.x > 5.0,
			"掉落物应真的滑出去了一段(实际 x=%.2f;太小说明这条断言是空转)" % a.global_position.x)

	a.queue_free()
	b.queue_free()
	floor_body.queue_free()
	await get_tree().physics_frame


# ── ④ 背包的拾取 / 替换 / 丢弃往返 ──
# 这是玩家按 F/Q 时会走的**实际那几行**(Level0.try_pickup_for / player._try_drop
# 只是把它们接起来)。原先只有零散覆盖,这里把整条语义钉住:
#   放得下 → 直接进背包;放不下 → **替换手上当前那把**并把被换下的交还调用方。
func _phase_inventory_roundtrip() -> void:
	var ps: PackedScene = load(PLAYER_SCENE)
	var pl: Node = ps.instantiate()
	add_child(pl)
	pl.set_physics_process(false)
	await get_tree().physics_frame
	var wep: WeaponComponent = pl.weapons
	_check(wep != null, "玩家有 Weapons 组件")
	if wep == null:
		pl.queue_free()
		return

	# 开局空手(单机初始背包为空,武器散落在图上)
	_check(wep.current_slot_int() == 0, "开局空手(实际槽 %d)" % wep.current_slot_int())
	_check(wep.inventory.held.size() == 0, "开局背包为空")

	# 捡手枪(2格) → 直接进背包并上手
	var r1: int = wep.pick_up(1, 12)
	await get_tree().physics_frame
	_check(r1 == 0, "放得下时应返回 0(无替换),实际 %d" % r1)
	_check(wep.current_slot_int() == 1, "捡起后手上是它(实际 %d)" % wep.current_slot_int())
	_check(wep.inventory.used_slots() == 2, "占用 2 格(实际 %d)" % wep.inventory.used_slots())

	# ★ 视觉缩放:武器挂在 Player 下时继承根的 scale=2.5(player.tscn),
	#   地面态得自己补上 —— 漏了就是"地上的枪小 2.5 倍",**而且不报错**。
	#   直接比两者的 global_scale(比 y 轴:facing 翻转只改 x)。
	await get_tree().physics_frame
	var pv: WeaponPickup = load(PICKUP_SCENE).instantiate()
	pv.configure(1, 7, 12, Vector2.ZERO)
	add_child(pv)
	await get_tree().physics_frame
	var ground_vis: Node2D = pv.get_node_or_null("Visual")
	var held_vis: Node2D = wep.current_weapon()
	_check(ground_vis != null, "地面武器应有 Visual 子节点")
	if ground_vis != null and held_vis != null:
		var gy := ground_vis.global_scale.y
		var hy := held_vis.global_scale.y
		# 手持那把刚 equip、未受击退/换弹影响,scale 就是继承来的根缩放
		_check(is_equal_approx(gy, hy),
				"地面武器视觉缩放应与手持一致(地面 %.3f vs 手持 %.3f;差 2.5 倍即漏补 WORLD_SCALE)" % [gy, hy])
	pv.queue_free()
	await get_tree().physics_frame

	# 捡重狙(4格) → 2+4=6,仍放得下
	_check(wep.pick_up(3, 5) == 0, "重狙应放得下")
	await get_tree().physics_frame
	_check(wep.inventory.used_slots() == 6, "占用 6 格(实际 %d)" % wep.inventory.used_slots())

	# ★ 捡第二把重狙(4格) → 6+4=10 > 8,放不下 → **替换手上当前那把**(现在是重狙)
	#   返回被换下的类型 id,残弹经 take_last_dropped 交还
	var r2: int = wep.pick_up(3, 99)
	_check(r2 > 0, "放不下时应返回被替换掉的类型 id(实际 %d;=0 说明静默吞掉了)" % r2)
	var d: Dictionary = wep.take_last_dropped()
	_check(int(d.get("mag", -1)) == 5,
			"被换下的那把的残弹要交还调用方(实际 %s;换下的应是那把 5 发的重狙)" % str(d))
	_check(wep.inventory.used_slots() == 6, "替换后占用仍是 6 格(实际 %d)" % wep.inventory.used_slots())

	# 边界:此刻占 6 格(手枪2 + 重狙4)→ 轻武器(2)塞得进 8,重武器(4)塞不进 10
	_check(wep.inventory.can_hold(1), "6 格时应还塞得进一把轻武器(6+2=8)")
	_check(not wep.inventory.can_hold(5), "6 格时塞不进重武器(6+4=10),该走替换")

	# 丢弃:交出 {type, mag} 且背包少一条
	var before: int = wep.inventory.held.size()
	var dropped: Dictionary = wep.drop_current()
	_check(not dropped.is_empty(), "drop_current 应返回被丢下的那把")
	_check(wep.inventory.held.size() == before - 1,
			"丢弃后背包应少一条(实际 %d → %d)" % [before, wep.inventory.held.size()])
	_check(int(dropped.get("type", 0)) > 0, "丢下的条目要带类型 id")

	# ★ 被禁用闸门拒绝时必须返回 PICKUP_DENIED(-1) —— 与"捡成功、没替换"(0)分开。
	#   混在一起的话 Level0.try_pickup_for 会把地面那把**直接删掉而玩家什么都没拿到**。
	wep.set_enabled_slots([5])
	var denied: int = wep.pick_up(5, 3)
	_check(denied == WeaponComponent.PICKUP_DENIED,
			"被禁用闸门拒绝应返回 PICKUP_DENIED(-1),实际 %d" % denied)
	wep.set_enabled_slots([])

	# 清空背包 → 回到空手
	wep.set_initial_inventory([])
	await get_tree().physics_frame
	_check(wep.current_slot_int() == 0 and wep.inventory.held.is_empty(), "清空背包后回到空手")
	pl.queue_free()
	await get_tree().physics_frame


# ── ⑤ 视觉真的建出来了(两条配置路径都要) ──
# ★ 这条 bug 是**真的漏过一次**:`Level0.spawn_pickup` 原先先 `add_child` 再 `configure`,
#   而 `_ready` 一入树就用 @export 默认值(type_id=1 手枪)建过一次视觉;`configure` 再建时
#   旧的 "Visual" 还占着名字(queue_free 要到帧末),新节点被**自动改名**,
#   于是 `get_node_or_null("Visual")` 抓到旧的那份 → **地面武器没有视觉、碰撞箱按错的枪算**。
#   探针当时只走"configure 在 add_child 之前"那条路,所以全绿 —— 补上另一条。
func _phase_visual_built() -> void:
	# 路径 A:configure 在 add_child **之前**(生产路径,Level0.spawn_pickup)
	var a: WeaponPickup = load(PICKUP_SCENE).instantiate()
	a.configure(5, 50, 4, Vector2.ZERO)   # 槽 5 = 榴弹发射器(与默认的手枪明显不同)
	add_child(a)
	await get_tree().physics_frame
	_check_pickup_visual(a, "A(configure 先于 add_child)")

	# 路径 B:configure 在 add_child **之后**(热改;挪位置/换型号时走这条)
	var b: WeaponPickup = load(PICKUP_SCENE).instantiate()
	add_child(b)
	await get_tree().physics_frame
	b.configure(5, 51, 4, Vector2.ZERO)
	await get_tree().physics_frame
	_check_pickup_visual(b, "B(add_child 先于 configure)")
	# 两条路径都不能留下**两个** Visual(名字被顶掉的那份会变成孤儿,白画一份或多一份碰撞箱)
	var vis_count := 0
	for c in b.get_children():
		if str(c.name).begins_with("Visual") or str(c.name).begins_with("@"):
			vis_count += 1
	_check(vis_count == 1, "重建后应恰好剩一个视觉节点(实际 %d;>1 说明旧的没当场摘掉)" % vis_count)

	a.queue_free()
	b.queue_free()
	await get_tree().physics_frame


func _check_pickup_visual(pk: WeaponPickup, tag: String) -> void:
	var vis: Node2D = pk.get_node_or_null("Visual")
	_check(vis != null, "%s:地面武器应有名为 Visual 的子节点" % tag)
	if vis == null:
		return
	var spr: Sprite2D = vis.get_node_or_null("Sprite2D")
	_check(spr != null, "%s:视觉里应有 Sprite2D" % tag)
	if spr == null:
		return
	_check(spr.texture != null, "%s:Sprite2D 应有贴图" % tag)
	# 视觉必须是**请求的那个型号**:槽 5 是榴弹发射器,而 tscn 的 @export 默认是手枪
	var want: PackedScene = load(WeaponComponent.WEAPONS[str(pk.type_id)])
	_check(want != null, "%s:注册表里应有槽 %d 的场景" % [tag, pk.type_id])
	if want == null:
		return
	var want_spr: Sprite2D = want.instantiate().get_node_or_null("Sprite2D")
	if want_spr != null:
		_check(spr.region_rect == want_spr.region_rect,
				"%s:视觉应与请求的型号一致(实际 region %s,期望 %s —— 不等说明建的是默认型号)"
				% [tag, spr.region_rect, want_spr.region_rect])
		# 碰撞箱也必须按**这个型号**的像素算(它取自同一份视觉)
		var cs: CollisionShape2D = pk.get_node_or_null("Shape")
		_check(cs != null, "%s:应有像素碰撞箱" % tag)
		if cs != null and cs.shape is RectangleShape2D:
			var got: Vector2 = (cs.shape as RectangleShape2D).size
			var want_rect: Rect2 = SpriteBounds.from_sprite(want_spr)
			_check(is_equal_approx(got.x, want_rect.size.x) and is_equal_approx(got.y, want_rect.size.y),
					"%s:碰撞箱应来自请求型号的像素(实际 %s,期望 %s)" % [tag, got, want_rect.size])
