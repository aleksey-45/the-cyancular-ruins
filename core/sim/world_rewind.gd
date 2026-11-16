class_name WorldRewind
extends RefCounted

# 玩家载荷与恢复的唯一实现(preload 而非依赖全局类缓存:`-s` 冒烟与无编辑器的批里 class_name 不一定已注册)。
const RewindFrame := preload("res://core/sim/rewind_frame.gd")


static var hold_corpses := false

var was_rewinding := false
var _frames: Array = []
var _t := 0.0
var _acc := 0.0
var _cursor := 0.0
var _replay_bullets: Array = []
var _parent: Node = null
var _apply_started := 0
var _apply_completed := 0
var _bullets_completed := 0
var _invalid_refs := 0


func _init(parent: Node = null) -> void:
	_parent = parent



func record(delta: float, player: Node, enemies: Array, bullets: Array) -> void:
	if player == null or not is_instance_valid(player):
		return
	var pl := player as Player
	if pl == null:
		push_error("WorldRewind: record() 收到非 Player 节点(%s)—— 本帧不入快照" % str(player))
		return
	_t += delta
	_acc += delta
	if _acc < 1.0 / float(TimeParams.SNAP_HZ):
		return
	_acc = 0.0
	var pe: Array = []
	for node in enemies:
		if not is_instance_valid(node) or (node as Node).has_meta("elite"):
			continue
# ★ 类型化替代字符串反射:反射拼错成员名时 get 静默返回 null,而 int(null) 当场中止整个 record() ⇒ 该帧压根不入快照。
		var e := node as EnemyBase
		if e == null:
			push_error("WorldRewind: enemies 里出现非 EnemyBase 节点(%s)—— 本帧不为它入快照"
					% str(node))
			continue
		pe.append({
			"n": e,
			"p": e.global_position,
			"v": e.velocity,
			"hp": e.hp,
			"dead": e.is_dead,
			"vis": e.visible,
		})
	var pb: Array = []
	for node in bullets:
		if not is_instance_valid(node):
			continue
		var b := node as BulletBase
		if b == null:
			push_error("WorldRewind: bullets 里出现非 BulletBase 节点(%s)—— 本帧不为它入快照"
					% str(node))
			continue
		var sh := b.shooter
		var fuse_state: Dictionary = b.rewind_state()
		pb.append({
			"sp": str(b.get_meta("scene_path", "")),
			"p": b.global_position,
			"v": b.velocity_vec,
			"from_player": sh != null and sh.is_in_group("player"),
			"dmg": b.hit_damage,
			"impact": b.hit_impact,
			"fuse": fuse_state,
		})
	_frames.append({
		"t": _t,
		"player": RewindFrame.build_player(pl),
		"enemies": pe,
		"bullets": pb,
	})
	var cutoff := _t - TimeParams.SNAP_SECONDS
	while _frames.size() > 1 and float(_frames[0]["t"]) < cutoff:
		_frames.pop_front()



func begin() -> void:
	_cursor = 0.0
	_replay_bullets.clear()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()


func finish() -> float:
	var exit_t := _t - _cursor
	var kept := 0
	for i in range(_frames.size()):
		if float(_frames[i]["t"]) <= exit_t:
			kept = i + 1
	if kept == 0 and not _frames.is_empty():
		kept = 1
	if kept > 0:
		_frames.resize(kept)
		_t = maxf(exit_t, float(_frames[kept - 1]["t"]))
	_cursor = 0.0
	_replay_bullets.clear()
	return _t


func step(delta: float, player: Node) -> void:
	if _frames.size() < 2:
		return
	_cursor += delta * _mult()
	var target := _t - _cursor
	_apply_started += 1
	_apply(_frame_at(target), player)


func apply_started_count() -> int:
	return _apply_started


func apply_completed_count() -> int:
	return _apply_completed


func replay_completion_error() -> String:
	if _apply_started <= 0:
		return "完成度观测量没有样本(回溯期 step() 一次都没被调到)—— 本条会空转"
	if _apply_completed > _apply_started:
		return "完成度分子超出分母:`_apply` %d/%d —— 计数点被改坏或重复计数(不是『没走完』)" % [
				_apply_completed, _apply_started]
	if _apply_completed != _apply_started:
		return ("回溯里 `_apply` 没走完:%d/%d 次(差 %d)—— 它在类型收窄上撞到 freed 实例,**当场抛错并中止**"
				% [_apply_completed, _apply_started, _apply_started - _apply_completed]
				+ "(本条范围只是 `_apply()` 自己的函数体;`_apply_bullets()` 内的中止见后一条)")
	if _bullets_completed > _apply_started:
		return "完成度分子超出分母:`_apply_bullets` %d/%d —— 计数点被改坏或重复计数(不是『没走完』)" % [
				_bullets_completed, _apply_started]
	if _bullets_completed != _apply_started:
		return ("回溯里 `_apply_bullets` 没走完:%d/%d 次(差 %d)—— 子弹段函数体内被中止 ⇒ 回放弹不重建/"
				% [_bullets_completed, _apply_started, _apply_started - _bullets_completed]
				+ "不摆位/引信不回写,后面『隐藏多余弹』也一起跳过。★ 它**不会**被前一条看见:"
				+ "脚本错误只中止出错的那个函数、`_apply()` 照常走到末尾 +1(评审 N-1 的插桩实测)")
	return ""


func _mult() -> float:
	var k := clampf(_cursor / maxf(TimeParams.REWIND_RAMP_TIME, 0.001), 0.0, 1.0)
	return lerpf(TimeParams.REWIND_START_MULT, 1.0, k)


func _frame_at(target: float) -> Dictionary:
	for i in range(_frames.size() - 1, -1, -1):
		if float(_frames[i]["t"]) <= target:
			return _frames[i]
	return _frames[0]


func _apply(f: Dictionary, player: Node) -> void:
	if f.is_empty():
		_apply_completed += 1
		_bullets_completed += 1
		return
	if is_instance_valid(player):
		var p := player as Player
		if p != null:
			RewindFrame.apply_player(p, f["player"])
	for d in f["enemies"]:
		var raw = d["n"]
		if not is_instance_valid(raw):
			_invalid_refs += 1
			continue
		var en := raw as EnemyBase
		if en == null:
			push_error("WorldRewind: enemies 里出现非 EnemyBase 节点(%s)—— 本帧不为它回放" % str(raw))
			continue
		en.rewind_restore(d)
	_apply_bullets(f["bullets"], player)
	_apply_completed += 1


func _apply_bullets(list: Array, player: Node) -> void:
	while _replay_bullets.size() < list.size():
		var meta: Dictionary = list[_replay_bullets.size()]
		var sp := str(meta["sp"])
# ★ 类型化替代 set/call 字符串反射:set 拼错静默不写(弹速/伤害/引信悄悄丢),call 拼错当场中止本函数。
		var nb: BulletBase = null
		if sp != "" and ResourceLoader.exists(sp):
			var inst := (load(sp) as PackedScene).instantiate()
			nb = inst as BulletBase
			if nb == null:
# ★ 转型失败时该节点既不入树也无人引用 ⇒ 必须显式 free() 否则泄漏;null 槽在本次回溯窗口内不会被重试。
				push_error("WorldRewind: %s 不是 BulletBase —— 该槽位本次回溯内不再重建" % sp)
				inst.free()
			else:
				if _parent != null and is_instance_valid(_parent):
					_parent.add_child(nb)
				elif player != null and is_instance_valid(player):
					player.get_parent().add_child(nb)
				nb.global_position = meta["p"]
				nb.velocity_vec = meta["v"]
				if bool(meta["from_player"]):
					nb.shooter = player
				nb.apply_damage = true
				nb.hit_damage = int(meta.get("dmg", 0))
				nb.hit_impact = float(meta.get("impact", 0.0))
				nb.apply_rewind_state(meta.get("fuse", {}))
# ★★ 重建出来的弹必须补上 scene_path meta,否则第二次回溯它就没了:写这份 meta 的唯一地方是出膛那一刻,
#   重建弹绕过它 ⇒ 再录进快照时 sp 是空串 ⇒ 下次不实例化、子弹凭空消失(单次回溯的探针照不到)。
				nb.set_meta("scene_path", sp)
		_replay_bullets.append(nb)
	for i in list.size():
		var raw2 = _replay_bullets[i]
		if not is_instance_valid(raw2):
			continue
		var nb2 := raw2 as BulletBase
		if nb2 == null:
			continue
		nb2.global_position = list[i]["p"]
		nb2.velocity_vec = list[i]["v"]
		nb2.apply_rewind_state(list[i].get("fuse", {}))
		nb2.visible = true
	for i in range(list.size(), _replay_bullets.size()):
		var raw3 = _replay_bullets[i]
		if not is_instance_valid(raw3):
			continue
		var nb3 := raw3 as BulletBase
		if nb3 == null:
			continue
		nb3.visible = false
	_bullets_completed += 1



func current_target() -> float:
	return _t - _cursor


func replay_bullets() -> Array:
	return _replay_bullets


func recorded_seconds() -> float:
	return _t


static func expire_corpses(tree: SceneTree) -> void:
	if tree == null:
		return
	var now := Time.get_ticks_msec()
	var life_ms := int(TimeParams.SNAP_SECONDS * 1000.0)
	for e in tree.get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or not (e as Node).has_meta("rw_death_ms"):
			continue
		if now - int((e as Node).get_meta("rw_death_ms")) > life_ms:
			(e as Node).queue_free()
