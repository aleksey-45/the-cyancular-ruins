extends Node2D

# 可破坏方块受击粒子:一次性碎片爆散,播完自毁。静态辅助,挂到世界 viewport 渲染。

static var _tex: Texture2D = null

# 去重窗口:本地命中 → 服务器破坏事件通常 = RTT/2 + 一个 tick(局域/公网几十 ms 量级)。
const RECENT_WINDOW_MS := 250
# 去重半径:子格命中点与格心最多差 ~45px(64px 格的角到中心);取 48 覆盖"子弹打角、格级事件报中心"。
const RECENT_RADIUS_PX := 48.0
# 有界:每次命中 1 条、窗口 250ms;128 条足够覆盖高射速,超出先丢最旧,防长局内存增长。
const RECENT_MAX := 128

static var _recent_hits: Array[Dictionary] = []


static func _texture() -> Texture2D:
	if _tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_tex = ImageTexture.create_from_image(img)
	return _tex


# 记一次"本端已播过命中碎片"的世界坐标(调用方负责先锚定到本地玩家副本)。
static func mark_hit(world_pos: Vector2) -> void:
	var now := Time.get_ticks_msec()
	_prune(now)
	_recent_hits.append({"t": now, "p": world_pos})
	if _recent_hits.size() > RECENT_MAX:
		_recent_hits.pop_front()


# 该位置附近在窗口内是否刚播过命中碎片;命中即消费(一条只抵一次事件,避免误吞后续独立事件)。
static func consume_hit_near(world_pos: Vector2, radius_px: float = RECENT_RADIUS_PX,
		window_ms: int = RECENT_WINDOW_MS) -> bool:
	var now := Time.get_ticks_msec()
	_prune(now)
	for i in range(_recent_hits.size()):
		var h := _recent_hits[i]
		if (h["p"] as Vector2).distance_to(world_pos) <= radius_px:
			_recent_hits.remove_at(i)
			return true
	return false


# 测试/换局复位用:清空去重表(静态状态跨场景常驻,换局后旧命中不该影响新回合)。
static func clear_recent_hits() -> void:
	_recent_hits.clear()


static func _prune(now: int) -> void:
	var kept: Array[Dictionary] = []
	for h in _recent_hits:
		if now - int(h["t"]) <= RECENT_WINDOW_MS:
			kept.append(h)
	_recent_hits = kept


# 在 parent(世界 viewport)下于 at 处播一次碎片。texture_id 用于挑颜色(树叶绿/树干棕)。
static func spawn(parent: Node, at: Vector2, texture_id: int) -> void:
	if parent == null:
		return
	var color := Color(0.6, 0.6, 0.6)
	if texture_id >= 15 and texture_id <= 18:
		color = Color(0.413, 0.701, 0.57, 1.0)     # 树叶碎片
	elif texture_id >= 19 and texture_id <= 20:
		color = Color(0.301, 0.398, 0.43, 1.0)   # 树干碎片
	var p := CPUParticles2D.new()
	p.texture = _texture()
	p.position = at
	p.amount = 10
	p.lifetime = 0.4
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, 900.0)
	p.initial_velocity_min = -120.0
	p.initial_velocity_max = 120.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color = color
	parent.add_child(p)
	var tree := parent.get_tree()
	if tree != null:
		tree.create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)
