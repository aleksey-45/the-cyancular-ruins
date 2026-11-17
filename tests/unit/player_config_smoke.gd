extends SceneTree
# PLAYER CONFIG SMOKE —— 玩家参数的**单一真相源**是 `core/config/player_config.tres`。
#
# 去掉什么会红:
#   ① `.tres` 换类型 / 挂错脚本 / 加载失败 ⇒ ① 红;
#   ② 转发层不再 `const _CFG := preload(...)` 这份 `.tres`(另接数据源或改成 getter 之外的东西)⇒ ③ 红;
#   ③ 有人把某个值**搬回 `player_params.gd` 当 `const`**(= 数据源不再是 .tres)⇒ ④ 红;
#   ④ `PlayerParams` 某个值与 `.tres` 对不上(漏读字段 / 读错名字)⇒ ② 红;
#   ⑤ `charge_duration` 被手抄成 `0.0853` 字面量(而不是 距离/速度 派生)⇒ ⑤ 红。
# ★ 不是"拿实现验实现":期望值来自**数据文件**(.tres 实例)与 `player_params.gd` 的常量表,
#   不是 PlayerParams 自己算出来的东西。

const EXPECTED_CHECKS := 5
const CFG_PATH := "res://core/config/player_config.tres"
const SCHEMA_PATH := "res://core/config/player_config.gd"
const ACCESSOR_PATH := "res://core/config/player_params.gd"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# 访问面:一处显式列出(不是从 PlayerParams 反射出来的) —— 期望值由 .tres 提供。
func _surface() -> Dictionary:
	return {
		"move_speed": PlayerParams.move_speed,
		"accel_ground": PlayerParams.accel_ground,
		"accel_air": PlayerParams.accel_air,
		"brake_ground": PlayerParams.brake_ground,
		"brake_air": PlayerParams.brake_air,
		"stop_snap": PlayerParams.stop_snap,
		"jump_velocity": PlayerParams.jump_velocity,
		"coyote_time": PlayerParams.coyote_time,
		"jump_buffer_time": PlayerParams.jump_buffer_time,
		"jump_cut_factor": PlayerParams.jump_cut_factor,
		"crouch_walk_speed": PlayerParams.crouch_walk_speed,
		"charge_down_velocity": PlayerParams.charge_down_velocity,
		"charge_distance": PlayerParams.charge_distance,
		"charge_velocity": PlayerParams.charge_velocity,
		"charge_air_gravity_mult": PlayerParams.charge_air_gravity_mult,
		"charge_dir_window": PlayerParams.charge_dir_window,
		"player_swim_speed": PlayerParams.player_swim_speed,
		"player_swim_up": PlayerParams.player_swim_up,
		"player_swim_down": PlayerParams.player_swim_down,
		"player_swim_accel": PlayerParams.player_swim_accel,
		"player_waterproof_max": PlayerParams.player_waterproof_max,
		"player_waterproof_damage": PlayerParams.player_waterproof_damage,
		"cam_lookahead_x": PlayerParams.cam_lookahead_x,
		"cam_lookahead_y": PlayerParams.cam_lookahead_y,
		"cam_y_bias": PlayerParams.cam_y_bias,
		"cam_smooth_x": PlayerParams.cam_smooth_x,
		"cam_smooth_y": PlayerParams.cam_smooth_y,
		"cam_deadzone": PlayerParams.cam_deadzone,
		"cam_zoom": PlayerParams.cam_zoom,
		"climb_ladder_up_speed": PlayerParams.climb_ladder_up_speed,
		"climb_ladder_down_speed": PlayerParams.climb_ladder_down_speed,
		"climb_chain_up_speed": PlayerParams.climb_chain_up_speed,
		"elastic_bounce": PlayerParams.elastic_bounce,
		"player_max_hp": PlayerParams.player_max_hp,
		"iframes_time": PlayerParams.iframes_time,
		"player_hit_knockback": PlayerParams.player_hit_knockback,
		"player_hit_knockback_up": PlayerParams.player_hit_knockback_up,
		"player_knock_decay_rate": PlayerParams.player_knock_decay_rate,
		"hit_cam_shake": PlayerParams.hit_cam_shake,
		"hit_cam_shake_time": PlayerParams.hit_cam_shake_time,
		"explosion_cam_shake": PlayerParams.explosion_cam_shake,
		"explosion_cam_shake_time": PlayerParams.explosion_cam_shake_time,
		"weapon_pickup_radius": PlayerParams.weapon_pickup_radius,
		"weapon_drop_hold_time": PlayerParams.weapon_drop_hold_time,
		"weapon_drop_speed": PlayerParams.weapon_drop_speed,
		"weapon_drop_up": PlayerParams.weapon_drop_up,
		"weapon_drop_offset": PlayerParams.weapon_drop_offset,
		"weapon_ground_friction": PlayerParams.weapon_ground_friction,
		"weapon_air_drag": PlayerParams.weapon_air_drag,
		"weapon_fall_gravity": PlayerParams.weapon_fall_gravity,
		"weapon_stop_eps": PlayerParams.weapon_stop_eps,
		"weapon_pickup_self_delay": PlayerParams.weapon_pickup_self_delay,
		"squash_amount": PlayerParams.squash_amount,
		"squash_recover": PlayerParams.squash_recover,
		"squash_jump": PlayerParams.squash_jump,
		"squash_land_min_vy": PlayerParams.squash_land_min_vy,
		"squash_land_ref_vy": PlayerParams.squash_land_ref_vy,
		"squash_land": PlayerParams.squash_land,
		"squash_hurt": PlayerParams.squash_hurt,
		"squash_dash": PlayerParams.squash_dash,
		"squash_air": PlayerParams.squash_air,
		"squash_air_ref_vy": PlayerParams.squash_air_ref_vy,
	}


func _initialize() -> void:
	var cfg: Resource = load(CFG_PATH)
	if cfg == null:
		print("PLAYER CONFIG FAILED: load(%s) 返回 null(-s 空载守卫:不 quit 会挂死)" % CFG_PATH)
		quit(1)
		return
	var schema: Script = load(SCHEMA_PATH)
	var accessor: Script = load(ACCESSOR_PATH)
	if schema == null or accessor == null:
		print("PLAYER CONFIG FAILED: schema / accessor 加载失败(%s / %s)" % [SCHEMA_PATH, ACCESSOR_PATH])
		quit(1)
		return

	var surface := _surface()
	var consts: Dictionary = accessor.get_script_constant_map()

	# ① 数据文件可加载,且确实是 PlayerConfig 这份 schema。
	_chk(cfg is PlayerConfig and cfg.get_script() == schema,
			"① %s 应是 PlayerConfig 实例(实得类型 %s / 脚本 %s)"
					% [CFG_PATH, cfg.get_class(), str(cfg.get_script())])

	# ② 62 个可调值全部与 .tres 一致(转发层漏读 / 读错名字会指向具体字段)。
	var diff := ""
	for field in surface:
		var want = cfg.get(field)
		var got = surface[field]
		if typeof(want) != typeof(got) or want != got:
			diff += "%s(.tres=%s / PlayerParams=%s) " % [field, str(want), str(got)]
	_chk(diff == "", "② %d 个可调值应全部来自 .tres" % surface.size()
			+ ("" if diff == "" else ";对不上:" + diff))

	# ③ 转发层必须把**这份** .tres 以 const preload 进来(= 单一真相源接线没断)。
	var wired: bool = consts.has("_CFG") and (consts["_CFG"] as Object) == cfg
	_chk(wired, "③ %s 必须以 const _CFG := preload(\"%s\") 引入同一份实例(实得 _CFG=%s)"
			% [ACCESSOR_PATH, CFG_PATH, str(consts.get("_CFG"))])

	# ④ 这些值不许是编译期 const(有人搬回 .gd 常量 ⇒ 数据源不再是 .tres)。
	var consted := ""
	for field in surface:
		if consts.has(field):
			consted += field + " "
	_chk(consted == "", "④ 可调值必须留在 .tres,不能是 %s 里的 const" % ACCESSOR_PATH
			+ ("" if consted == "" else ";被搬回 const:" + consted))

	# ⑤ charge_duration 是派生值(距离 / 速度),不是手抄的 0.0853。
	var derived_ok: bool = PlayerParams.charge_velocity != 0.0 \
			and is_equal_approx(PlayerParams.charge_duration,
					PlayerParams.charge_distance / PlayerParams.charge_velocity)
	_chk(derived_ok, "⑤ charge_duration 应由 charge_distance/charge_velocity 派生(实得 %.6f,期望 %.6f)"
			% [PlayerParams.charge_duration,
			PlayerParams.charge_distance / maxf(PlayerParams.charge_velocity, 0.000001)])

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("PLAYER CONFIG OK(%d 条断言):.tres 可加载 · %d 个可调值来自 .tres · _CFG 接线 · 没有值搬回 const · charge_duration 派生"
				% [_checks, surface.size()])
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("PLAYER CONFIG FAILED: %d 处" % _fails.size())
		quit(1)
