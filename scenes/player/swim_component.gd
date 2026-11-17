class_name SwimComponent
extends Node


const WaterSample := preload("res://core/sim/water_sample.gd")

signal waterproof_changed(current: int, max: int)

var in_water: bool = false
# 本帧水判定(唯一来源):根读它做呼吸/形变,别在根里再查一次水面(旧实现因此把呼吸线换成"中心+10px")。
var sample: WaterSample = null

# 防水值(氧气):没顶按 water_drain_interval 掉 1、暴露空气按 water_recover_interval 回 1;归零后按间隔扣血。
# ★ 归本组件(水判定的 owner);根只留一个只读转发属性给 HUD / 整态。
var waterproof: int = PlayerParams.player_waterproof_max
var max_waterproof: int = PlayerParams.player_waterproof_max
var _wp_timer: float = 0.0
var _was_submerged: bool = false
var _drown_timer: float = 0.0


func update(parent: CharacterBody2D, delta: float, move_mult: Vector2 = Vector2.ONE,
		src: PlayerInput = null, haste_mult: float = 1.0) -> bool:
	if src == null:
		push_error("SwimComponent.update: 缺 src(注入输入源)—— 本组件只读注入进来的输入,禁止读全局输入;本帧按「不在水中」安全返回(调用方应传 player.input_source)")
		in_water = false
		sample = null
		return false
	sample = Water.sample_body(parent, in_water)
	in_water = sample.in_water
	if not in_water:
		return false
	var horiz := src.get_axis("left", "right")
	var tm := haste_mult
	if TimeField.current != null:
		tm = TimeField.player_speed_mult()
	if tm <= 0.0:
		tm = 1.0
	var target_vx := horiz * PlayerParams.player_swim_speed * move_mult.x * tm
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
	parent.velocity.y = (PlayerParams.player_swim_up if src.is_action_pressed("up") else PlayerParams.player_swim_down) * tm
	return true


# 整态里的游泳段(键名 = NetCodec 的 C2_SCHEMA 标志位 `swim` + 氧气的 4 个键)。sample 是逐帧派生的,不入状态。
func capture_state() -> Dictionary:
	return {
		"swim": in_water,
		"wp": waterproof,
		"wp_t": _wp_timer,
		"wp_s": _was_submerged,
		"wp_d": _drown_timer,
	}


func restore_state(st: Dictionary) -> void:
	in_water = bool(st.get("swim", in_water))
	var wp_v := int(st.get("wp", waterproof))
	if wp_v != waterproof:
		waterproof = clampi(wp_v, 0, max_waterproof)
		waterproof_changed.emit(waterproof, max_waterproof)
	_wp_timer = float(st.get("wp_t", _wp_timer))
	_was_submerged = bool(st.get("wp_s", _was_submerged))
	_drown_timer = float(st.get("wp_d", _drown_timer))


# 呼吸/溺水(由 PlayerMotor 每帧按顺序调):判据只看 head_under —— 采样点与水面线由 Water.sample_body 定。
func update_waterproof(delta: float, water: WaterSample, body: CharacterBody2D) -> void:
	var submerged: bool = water != null and water.head_under
	if submerged != _was_submerged:
		_was_submerged = submerged
		_wp_timer = 0.0  # 状态切换重置:自切换起累计满一个间隔才结算第一下
	if submerged:
		_wp_timer += delta
		if _wp_timer >= GameParameters.water_drain_interval:
			_wp_timer = 0.0
			set_waterproof(waterproof - 1)
	else:
		_wp_timer += delta
		if _wp_timer >= GameParameters.water_recover_interval:
			_wp_timer = 0.0
			set_waterproof(waterproof + 1)
	if waterproof <= 0:
		_drown_timer += delta
		if _drown_timer >= GameParameters.water_drown_damage_interval:
			_drown_timer = 0.0
			# ★ cause="water":客户端已本地预测的伤害;服务器必须据此不广播 hit_event,否则客户端二次应用(多扣一次血 → 下个 ack 再回滚)。
			body.take_hit(body.global_position, PlayerParams.player_waterproof_damage, true, -1.0, false, "water")


# 唯一写入口(含"总是发信号"的权威态语义:HUD 靠它刷新)。
func set_waterproof(v: int) -> void:
	waterproof = clampi(v, 0, max_waterproof)
	waterproof_changed.emit(waterproof, max_waterproof)


func reset_oxygen() -> void:
	waterproof = max_waterproof
	_wp_timer = 0.0
	_was_submerged = false
	_drown_timer = 0.0
	waterproof_changed.emit(waterproof, max_waterproof)
