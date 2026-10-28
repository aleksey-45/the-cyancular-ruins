class_name WorldRewind
extends RefCounted

# 世界时空回溯系统：定频快照环形缓冲区与状态回放器，负责关键实体状态的定频记录与倒流回放。
#
# 架构设计：与 NativeTerrain 的地形历史协同工作，本模块负责实体状态回溯：
#   - record()：常态下以定频（TimeParams.SNAP_HZ）记录关键实体状态（玩家、普通敌人、子弹）。
#   - step()：回溯激活时沿时间轴逆序回放，一次性还原实体的物理状态与子弹位置。
#   - 精英敌人豁免：精英单位不受回溯影响，保持自主行为。
#   - 击败实体保留：在快照窗口内被击败的敌人隐藏其物理和渲染节点，回溯至击败时刻前则恢复存活。
#   - 回溯期间伤害免疫：实体在 TimeField.is_rewinding() 期间免疫外部常规伤害，玩家输入被暂时挂起。

static var hold_corpses := false   # 由 Level0 每帧同步:录制中=true(击杀保留尸体待复活)

var was_rewinding := false         # 状态沿(Level0 用它判进入/退出回溯)
var _frames: Array = []            # [{t, player:{...}, enemies:[...], bullets:[...]}]
var _t := 0.0                      # 世界已录制时间(秒)
var _acc := 0.0
var _cursor := 0.0
var _replay_bullets: Dictionary = {}  # 历史 ID -> 回放对象，避免按下标串用不同弹丸
var _parent: Node = null           # 回放子弹的挂载父节点(通常 WorldViewport)


func _init(parent: Node = null) -> void:
	_parent = parent



func record(delta: float, player: Node, enemies: Array, bullets: Array) -> void:
	if player == null or not is_instance_valid(player):
		return
	_t += delta
	_acc += delta
	if _acc < 1.0 / float(TimeParams.SNAP_HZ):
		return
	_acc = 0.0
	var pe: Array = []
	for e in enemies:
		if not is_instance_valid(e) or e.has_meta("elite"):
			continue
		pe.append({
			"n": e,
			"p": (e as Node2D).global_position,
			"v": e.get("velocity"),
			"hp": int(e.get("hp")),
			"dead": bool(e.get("is_dead")),
			"vis": (e as Node2D).visible,
		})
	var pb: Array = []
	for b in bullets:
		if not is_instance_valid(b):
			continue
		var bullet: BulletBase = b
		var sh := bullet.shooter
		pb.append({
			# 重建后继续携带原历史 ID，二次录制与回溯仍对应同一颗弹丸。
			"id": int(bullet.get_meta("rewind_id", bullet.get_instance_id())),
			"sp": str(bullet.get_meta("scene_path", "")),
			"from_player": sh != null and sh is Node and (sh as Node).is_in_group("player"),
			"state": bullet.rewind_state(),
		})
	_frames.append({
		"t": _t,
		"player": player.capture_state(true),
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


## 退出时空回溯：裁剪回溯出口之后的时间轴数据，保持时间线连续一致。
## 时间轴游标重置至回溯出口，后续 record() 从该时刻继续追加录制。
## 保证多次连续回溯历史状态互不冲突，避免重复回放已被覆写的时间段。
## 返回出口时刻(磁带新末尾),Level0 用它把瓦片账本裁到同一位置。
func finish() -> float:
	var exit_t := _t - _cursor
	var kept := 0
	for i in range(_frames.size()):
		if float(_frames[i]["t"]) <= exit_t:
			kept = i + 1
	if kept == 0 and not _frames.is_empty():
		kept = 1   # 倒到了磁带最老处:世界就停在那帧上,磁带从它重新起算
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
	_apply(_frame_at(target), player)


## 起步快放 → 1×(用已倒退量做 ramp;越倒越接近 1×)
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
		return
	if is_instance_valid(player) and player.has_method("rewind_restore"):
		player.rewind_restore(f["player"])
	for d in f["enemies"]:
		if is_instance_valid(d["n"]) and (d["n"] as Node).has_method("rewind_restore"):
			(d["n"] as Node).rewind_restore(d)
	_apply_bullets(f["bullets"], player)


## 单人以目标帧决定对象集合；创建/回收在管理器处理，状态恢复复用弹丸公共接口。
func _apply_bullets(list: Array, player: Node) -> void:
	var wanted := {}
	for meta: Dictionary in list:
		var id: int = meta["id"]
		wanted[id] = true
		var bullet: BulletBase = _replay_bullets.get(id)
		if not is_instance_valid(bullet) or bullet.is_queued_for_deletion():
			var sp := str(meta["sp"])
			var host: Node = _parent
			if not is_instance_valid(host) and is_instance_valid(player):
				host = player.get_parent()
			if not is_instance_valid(host) or sp.is_empty() or not ResourceLoader.exists(sp):
				continue
			bullet = (load(sp) as PackedScene).instantiate()
			bullet.shooter = player if meta["from_player"] else null
			bullet.apply_damage = true
			bullet.set_meta("scene_path", sp)
			bullet.set_meta("rewind_id", id)
			bullet.apply_rewind_state(meta["state"])
			host.add_child(bullet)
			_replay_bullets[id] = bullet
		else:
			bullet.apply_rewind_state(meta["state"])
	for id in _replay_bullets.keys():
		if not wanted.has(id):
			var bullet: BulletBase = _replay_bullets[id]
			if is_instance_valid(bullet):
				bullet.queue_free()
			_replay_bullets.erase(id)



## 当前回放目标时间(秒):瓦片账本按同一时间轴取区间还原。
func current_target() -> float:
	return _t - _cursor


## 回放中的子弹节点(回溯期 Level0 用它们对精英做二次伤害判定)。
func replay_bullets() -> Array:
	return _replay_bullets.values()


func frame_count() -> int:
	return _frames.size()


func recorded_seconds() -> float:
	return _t


## 尸体过期清理:录制中被保留(隐藏)的尸体,死亡时间超出缓冲窗口 → 真正释放。
## Level0 每帧调;用 meta "rw_death_ms" 记的死亡时刻判定。
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
