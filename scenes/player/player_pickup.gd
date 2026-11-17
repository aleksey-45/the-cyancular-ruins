class_name PlayerPickup
extends RefCounted

# 拾取(F)与长按丢弃(Q)+ 长按进度反馈。
# ★ 走**注入的端口**(两个方法名),不在 Player 里向上找场景类:旧 host_level() 让模拟类反向依赖 Level0,
#   且在 PvP/无 Level0 的环境里静默返回 null(什么都没做,也不报错)。未绑定 = 本端不执行拾取/丢弃,
#   联机只上行、由服务器裁决(GroundSystem)。
# ★ 两种模式都要跑 Q 的计时:联机时它是"长按才丢"的唯一执行点(服务器只收得到一次满了的边沿)。
const PORT_METHODS: Array[String] = ["try_pickup_for", "spawn_pickup"]

var host: Node = null

var _hold_t := 0.0
var _latched := false


func bind(h: Node) -> void:
	if h == null:
		return
	for m in PORT_METHODS:
		if not h.has_method(m):
			push_error("PlayerPickup: 宿主缺 %s() —— 拾取/丢弃端口没接线" % m)
			return
	host = h


func tick(p: Player, delta: float) -> void:
	var src := p.input_source
	if src.is_action_pressed("Q"):
		if not _latched:
			_hold_t += delta
			if _hold_t >= PlayerParams.weapon_drop_hold_time:
				_latched = true
				if Level0.pvp_mode:
					src.mark_drop_edge()
				else:
					_drop(p)
	else:
		_hold_t = 0.0
		_latched = false

	# F 是按下边沿:单机就地执行;联机只上行(服务器走 GroundSystem 裁决)。
	if src.is_pickup_pressed() and not Level0.pvp_mode and host != null:
		host.try_pickup_for(p)


# 长按 Q 的进度 0..1(只读;HUD 的丢弃进度条用):没有反馈的长按是不可用的 —— 玩家会以为按键没生效。
func progress() -> float:
	if _latched:
		return 1.0
	return clampf(_hold_t / PlayerParams.weapon_drop_hold_time, 0.0, 1.0)


func _drop(p: Player) -> void:
	if host == null or p.weapons.current_type_id() == 0:
		return   # 没宿主 / 空手,没什么可丢
	var e: Dictionary = p.weapons.drop_current()
	if e.is_empty():
		return
	host.spawn_pickup(int(e["type"]), int(e["mag"]),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
			0, true)   # self_drop=true:冷却期内不参与自己的拾取(防丢完原地按 F 捡回)
