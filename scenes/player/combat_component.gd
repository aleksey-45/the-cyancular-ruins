class_name CombatComponent
extends Node

# 战斗子系统:生命/无敌帧/爆炸击退向量/倒地;由根 player.gd 驱动(take_hit 经根转发、apply_knock/update_iframe_blink 每物理帧),hp_changed 由根转发给 HUD。

static var pvp_arena := false


signal hp_changed(current: int, max: int)
signal went_down
signal took_hit(source_pos: Vector2, damage: int, cause: String)

var max_hp: int = PlayerParams.player_max_hp
var hp: int = PlayerParams.player_max_hp
var iframes: float = 0.0
var downed: bool = false
var knock_velocity: Vector2 = Vector2.ZERO

var body: CharacterBody2D

const IFRAME_BLINK_RATE := 20.0

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_downed() -> bool:
	return downed

func update_iframe_blink(delta: float) -> void:
	iframes = maxf(iframes - delta, 0.0)
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0,
		feedback_only: bool = false, cause: String = "") -> void:
	if downed or (not pvp_arena and iframes > 0.0 and not ignore_iframes):
		return
	if feedback_only:
		play_hit_feedback(source_pos, damage)
		return
	body.cancel_charge()
	hp -= damage
	took_hit.emit(source_pos, damage, cause)
	play_hit_feedback(source_pos, damage)
	iframes = PlayerParams.iframes_time
	var away := (body.global_position - source_pos).normalized()
	if GameParameters.MAP_WIDTH > 0.0 and GameParameters.MAP_HEIGHT > 0.0:
		var short_vec := MazeGenerator.toroidal_delta_px(source_pos, body.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not short_vec.is_zero_approx():
			away = short_vec.normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		knock_velocity = away * knockback
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()


func play_hit_feedback(_source_pos: Vector2, damage: int) -> void:
	Sfx.play("hurt")
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("flash_hit"):
			pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	var hit_ratio := float(damage) / float(max_hp)
	var cam: Camera2D = body.get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		if hit_ratio > 0.25:
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
		else:
			cam.shake(6.0, 0.15)

func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

func force_down() -> void:
	if not downed:
		_downed()

func set_downed_by_rewind(v: bool) -> void:
	if downed == v:
		return
	downed = v
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.play("downed" if v else "idle")
	if v:
		went_down.emit()


func restore_alive_state() -> void:
	if not downed:
		return
	set_downed_by_rewind(false)
	body.rotation = 0.0
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(false)


func revive() -> void:
	if not downed:
		return
	restore_alive_state()
	hp = max_hp

func _downed() -> void:
	downed = true
	body.rotation = -PI / 2.0 * float(body.get_facing())
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.stop()
	went_down.emit()
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(true)


# 整态里的战斗段(键名 = NetCodec 的 C2_SCHEMA:hp / ifr / down / knock)。
# ★ 只发值变化过的 hp:hp_changed 是 HUD 的唯一刷新源,但每帧重放都发会白刷。
func capture_state() -> Dictionary:
	return {"hp": hp, "ifr": iframes, "down": downed, "knock": knock_velocity}


func restore_state(st: Dictionary) -> void:
	var hp_v := int(st.get("hp", hp))
	if hp_v != hp:
		hp = clampi(hp_v, 0, max_hp)
		hp_changed.emit(hp, max_hp)
	var down_v := bool(st.get("down", downed))
	if down_v and not downed:
		force_down()
	elif not down_v and downed:
		# ★ 2026-11-01(R3):不能走 revive() —— 它会把 hp 顶成 max_hp,冲掉上面刚从整态恢复的 hp。
		restore_alive_state()
	iframes = float(st.get("ifr", iframes))
	knock_velocity = st.get("knock", knock_velocity)
