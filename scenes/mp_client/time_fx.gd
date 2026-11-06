class_name TimeFx
extends RefCounted

## PvP beta 时间玩法的他人视效状态(组合件):自己残影节拍 + 以副本节点为键的三张表(加速重影节拍 / 回溯底片材质 / 轨迹残像)。
## 宿主 bind(client) 后每帧 tick();副本被拆时**先 detach(rep) 再 queue_free** —— 残影宿主挂在 _world、不在副本子树里,
## 节点释放后这些键再也碰不到,漏 detach 就是永久节点泄漏(BUG-19)。
## ★ 1v1 不覆写 _all_replicas()(基类恒空)⇒ tick 的他人段是空集合 no-op;beta 也不在 1v1 开。

const TIME_GLOW_SELF := Color(0.30, 0.62, 1.0)    # 自己加速:冷白蓝(与单机主角同色)
const TIME_GLOW_OTHER := Color(1.0, 0.94, 0.86)   # 他人加速:暖白(与单机敌人同色)

var _client: Node = null
var _fx_self_t := 0.0                # 自己的残影节拍(0.03s)
var _fx_other_t: Dictionary = {}     # replica(Node2D) -> 他人重影节拍剩余秒(0.06s 一对)。★ 必须 per-副本:
#  单 float 会让 k 个加速者每帧各减它一次 ⇒ 触发 ≈ k/0.06 对/秒(16 人 ≈500 张 AfterImage/s)。
var _rw_film_mats: Dictionary = {}   # replica -> ShaderMaterial(满覆盖度)
var _rw_ghosts: Dictionary = {}      # replica -> Array[{node, t}](生成时刻,1s 渐隐)


## 绑定宿主(只存引用、无副作用;宿主第一次用到时懒建,与 ReplicaSet 同款)。
func bind(client: Node) -> void:
	_client = client


## 每帧入口(物理 delta)。调用方已保证 _local 非空且 beta_mode 为真,见 PvpMatchClient._tick_beta_time。
func tick(delta: float, self_hasting: bool) -> void:
	# 自己:加色高亮 + 红蓝交替残影(与单机同款节拍)。
	var local: Node2D = _client._local
	if self_hasting:
		if TimeGlow.on(local) == null:
			TimeGlow.attach(local, TIME_GLOW_SELF)
		_fx_self_t -= delta
		if _fx_self_t <= 0.0:
			_fx_self_t = 0.03
			var anim := local.animator as AnimatedSprite2D
			if anim != null:
				var red := int(Time.get_ticks_msec() / 60) % 2 == 0
				AfterImage.spawn((local as Node).get_parent(), anim,
						Color(1.0, 0.25, 0.25, 0.55) if red else Color(0.3, 0.4, 1.0, 0.55))
	else:
		var g := TimeGlow.on(local)
		if g != null:
			g.queue_free()
	# 他人:回溯优先(底片色 + 轨迹残像,不叠加速高亮);否则加速高亮 + 红蓝重影 + ▶▶3x。
	var any_hasting := false
	for rep_node in _client._all_replicas():
		if not is_instance_valid(rep_node) or not (rep_node is Node2D):
			continue
		var rep := rep_node as Node2D
		_time_fx_replica_rewind(rep, delta)
		if bool(rep.get_meta("rewind", false)):
			_time_fx_replica_off(rep)
			continue
		if not bool(rep.get_meta("haste", false)):
			_time_fx_replica_off(rep)
			continue
		any_hasting = true
		_time_fx_replica_on(rep, delta)
	if not any_hasting:
		_fx_other_t.clear()


## 副本被拆前的清理(**必须先于 queue_free**,顺序见文件头 BUG-19)。
func detach(rep: Node2D) -> void:
	_time_fx_replica_rewind_off(rep)
	_fx_other_t.erase(rep)   # 拆掉的副本不会再被 tick 遍历 ⇒ 节拍键只能在这里清


func _time_fx_replica_off(rep: Node2D) -> void:
	_fx_other_t.erase(rep)   # 不再加速 ⇒ 清掉该副本的节拍表,免得键泄漏/下次加速还接着走
	var glow := TimeGlow.on(rep)
	if glow != null:
		glow.queue_free()
	var label := rep.get_node_or_null("HasteTag") as Label
	if label != null:
		label.visible = false


func _time_fx_replica_on(rep: Node2D, delta: float) -> void:
	if TimeGlow.on(rep) == null:
		TimeGlow.attach(rep, TIME_GLOW_OTHER)
	var label := rep.get_node_or_null("HasteTag") as Label
	if label == null:
		label = UiFactory.label("▶▶ 3x", 16, Color(0.78, 0.55, 1.0))
		label.name = "HasteTag"
		label.position = Vector2(-26, -92)
		rep.add_child(label)
	label.text = "▶▶ %dx" % int(round(_client._time_haste_mult))
	label.visible = true
	# 红蓝重影:同一帧贴红 / 蓝两张淡副本(加色叠加读作色差重影;与自己的交替残影区分)。节拍 per-副本、用物理 delta。
	var t := float(_fx_other_t.get(rep, 0.0))
	t -= delta
	if t <= 0.0:
		_fx_other_t[rep] = 0.06
		var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if anim != null:
			AfterImage.spawn(rep.get_parent(), anim, Color(1.0, 0.25, 0.25, 0.30))
			AfterImage.spawn(rep.get_parent(), anim, Color(0.3, 0.4, 1.0, 0.30))
	else:
		_fx_other_t[rep] = t


# 他人回溯视效:副本自身底片色(满覆盖度)+ 沿服务器轨迹的时间切片残像(1 秒渐隐)。轨迹点来自快照 trail(每 3 帧一个 [x,y])。
func _time_fx_replica_rewind(rep: Node2D, delta: float) -> void:
	if not bool(rep.get_meta("rewind", false)):
		_time_fx_replica_rewind_off(rep)
		return
	if not _rw_film_mats.has(rep):
		var m := ShaderMaterial.new()
		m.shader = load("res://scenes/effects/time_film.gdshader")
		m.set_shader_parameter("coverage", 1.0)
		rep.material = m
		_rw_film_mats[rep] = m
	# 轨迹残像:快照 trail 里**新出现**的点 → 每点一张淡副本(挂在副本父级,位置即轨迹点)。
	# 判据不能用数组变长:线上 trail 只带最近 4 点、很快就饱和(理由见 BUG-13)。
	var trail: Array = rep.get_meta("trail_last", [])
	var new_trail: Array = rep.get_meta("trail", [])
	var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim != null:
		for pt in _fresh_trail_points(trail, new_trail):
			var ghost_host := Node2D.new()
			ghost_host.global_position = Vector2(float(pt[0]), float(pt[1]))
			rep.get_parent().add_child(ghost_host)
			AfterImage.spawn(ghost_host, anim, Color(0.82, 0.88, 0.92, 0.35))
			var ghosts: Array = _rw_ghosts.get(rep, [])
			ghosts.append({"node": ghost_host, "t": 0.0})
			_rw_ghosts[rep] = ghosts
	rep.set_meta("trail_last", new_trail.duplicate())
	var ghosts2: Array = _rw_ghosts.get(rep, [])
	var alive: Array = []
	for g in ghosts2:
		g["t"] = float(g["t"]) + delta
		var host: Node2D = g["node"]
		if float(g["t"]) < 1.0 and is_instance_valid(host):
			# 淡出按 CanvasItem 取(AfterImage 是 Node2D,旧写法 as Sprite2D 恒 null);过期即 free,否则每次回溯漏 20+ 个空节点。
			if host.get_child_count() > 0:
				var vis := host.get_child(0) as CanvasItem
				if vis != null:
					vis.modulate.a = clampf(0.35 * (1.0 - float(g["t"])), 0.0, 1.0)
			alive.append(g)
		elif is_instance_valid(host):
			host.queue_free()
	_rw_ghosts[rep] = alive


# 新旧两条 trail 之间「新出现的点」:两条都是线上截断后的最近 N 点(旧的在先、新的在后),
# 找最大的 k 使 old 的后缀(k) == new 的前缀(k),new[k..] 就是新点。k ≤ 4,类 O(k²)。
static func _fresh_trail_points(old_trail: Array, new_trail: Array) -> Array:
	var max_k := mini(old_trail.size(), new_trail.size())
	var k := max_k
	while k > 0:
		var same := true
		for j in k:
			if not _same_trail_pt(old_trail[old_trail.size() - k + j], new_trail[j]):
				same = false
				break
		if same:
			break
		k -= 1
	return new_trail.slice(k)


# 两个 trail 点是否同一点(线上是 [x, y] 浮点数组;往返/量化后可能差一个 eps,故用 is_equal_approx)。
static func _same_trail_pt(a: Variant, b: Variant) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var x: Array = a
	var y: Array = b
	return x.size() >= 2 and y.size() >= 2 \
			and is_equal_approx(float(x[0]), float(y[0])) \
			and is_equal_approx(float(x[1]), float(y[1]))


func _time_fx_replica_rewind_off(rep: Node2D) -> void:
	if _rw_film_mats.has(rep):
		if is_instance_valid(rep) and rep.material == _rw_film_mats[rep]:
			rep.material = null
		_rw_film_mats.erase(rep)
	if _rw_ghosts.has(rep):
		for g in _rw_ghosts[rep]:
			if is_instance_valid(g["node"]):
				(g["node"] as Node).queue_free()
		_rw_ghosts.erase(rep)
	if rep.has_meta("trail_last"):
		rep.remove_meta("trail_last")
