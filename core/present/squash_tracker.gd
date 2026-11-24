class_name SquashTracker
extends RefCounted

# 挤压拉伸(单实体):把一次动作事件换成一个只作用于 sprite 局部坐标轴的 scale 乘子。
#
# 参数来自现有 Resource(main 同款字段/数值):
#   PlayerConfig.squash_*       玩家 jump/dash/land/hurt/air
#   EnemyConfig.shared_squash_* 敌人 take_off/charge/land/hurt/air
# 调用方(WorldView._actor)只把 sample() 返回的 Vector2 乘到 sprite 的局部缩放上;
# origin(角色锚点)不动,碰撞箱与武器/瞄准用的仍是未缩放的 body transform。
#
# 衰减沿用旧 WorldView 的指数形式:impulse * exp(-recover * age)。
# 新事件**覆盖**旧事件(而不是累加):旧实现 `_motions[id] = Vector2(now, strength)` 就是覆盖语义,
# tests/simulation_case.gd 的 "_actor_animation" 依赖「落地后紧接起跳,以起跳为准」,
# 累加会让 land(-1)+jump(0.75) 变成 -0.25 而破坏该断言。这里保留覆盖语义。

enum Profile { PLAYER, ENEMY }

const PLAYER_CFG: PlayerConfig = preload("res://core/config/player_config.tres")
const ENEMY_CFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

var _profile := Profile.PLAYER
var _amount := 0.06
var _recover := 16.0
var _land_min_vy := 220.0
var _land_ref_vy := 900.0
var _land := 1.0
var _air := 0.1
var _air_ref_vy := 700.0
var _impulses := {}
var _impulse := 0.0
var _at := -INF

# 事件 → 实体侧别的兜底推断:WorldView.motion() 只拿得到 id 与 kind(调用点不在本次写范围)。
# 约定(见 SoloLevel._start_single):敌人 id = -1 - slot(负数),玩家/副本 role 为正数。
# jump/dash 只有玩家发;take_off 只有敌人发;charge 两侧都有(玩家 charge = 冲刺蓄力起手)。
static func profile_for(id: int, kind: StringName) -> int:
	match kind:
		&"jump", &"dash":
			return Profile.PLAYER
		&"take_off":
			return Profile.ENEMY
		&"charge":
			return Profile.ENEMY if id < 0 else Profile.PLAYER
	return Profile.ENEMY if id < 0 else Profile.PLAYER


func setup(profile: int) -> void:
	_profile = profile
	if profile == Profile.ENEMY:
		_amount = ENEMY_CFG.shared_squash_amount
		_recover = ENEMY_CFG.shared_squash_recover
		_land_min_vy = ENEMY_CFG.shared_squash_land_min_vy
		_land_ref_vy = ENEMY_CFG.shared_squash_land_ref_vy
		_land = ENEMY_CFG.shared_squash_land
		_air = ENEMY_CFG.shared_squash_air
		_air_ref_vy = ENEMY_CFG.shared_squash_air_ref_vy
		_impulses = {
			&"hurt": -ENEMY_CFG.shared_squash_hurt,
			&"take_off": ENEMY_CFG.shared_squash_take_off,
			&"charge": ENEMY_CFG.shared_squash_charge,
			# 敌鸟没有独立的 jump/dash 事件,同义动作复用 take_off/charge 的强度。
			&"jump": ENEMY_CFG.shared_squash_take_off,
			&"dash": ENEMY_CFG.shared_squash_charge,
		}
	else:
		_amount = PLAYER_CFG.squash_amount
		_recover = PLAYER_CFG.squash_recover
		_land_min_vy = PLAYER_CFG.squash_land_min_vy
		_land_ref_vy = PLAYER_CFG.squash_land_ref_vy
		_land = PLAYER_CFG.squash_land
		_air = PLAYER_CFG.squash_air
		_air_ref_vy = PLAYER_CFG.squash_air_ref_vy
		_impulses = {
			&"jump": PLAYER_CFG.squash_jump,
			&"dash": PLAYER_CFG.squash_dash,
			# 玩家的 "charge" = 蓄力冲刺起手(Player.DASH 状态,动画 clip 名就是 charge);
			# main 的 SquashStretch.Impulse 里这就是 DASH,所以强度取 squash_dash。
			&"charge": PLAYER_CFG.squash_dash,
			&"hurt": -PLAYER_CFG.squash_hurt,
		}
	reset()


## 记录一次冲击。land 按竖直速度插值(低于 squash_land_min_vy 不形变),其余查配置强度。
func impulse(kind: StringName, now: float, speed := 0.0) -> void:
	var strength := 0.0
	if kind == &"land":
		var span := _land_ref_vy - _land_min_vy
		var k := clampf((speed - _land_min_vy) / span, 0.0, 1.0) if span > 0.0 else 1.0
		strength = -_land * k
	else:
		strength = float(_impulses.get(kind, 0.0))
	if is_zero_approx(strength):
		return
	_impulse = clampf(strength, -1.0, 1.0)
	_at = now


## 当前 sprite 局部 scale 乘子。age=0 时为冲击峰值,之后按 exp(-recover*age) 回到 1。
func sample(now: float, air_speed: float) -> Vector2:
	var air := clampf(absf(air_speed) / maxf(_air_ref_vy, 1.0), 0.0, 1.0) * _air
	var age := maxf(now - _at, 0.0)
	var value := clampf(air + _impulse * exp(-_recover * age), -1.0, 1.0)
	return Vector2(1.0 - _amount * value, 1.0 + _amount * value)


func reset() -> void:
	_impulse = 0.0
	_at = -INF


func profile() -> int:
	return _profile


func amount() -> float:
	return _amount
