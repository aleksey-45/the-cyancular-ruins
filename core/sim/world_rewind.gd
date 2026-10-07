class_name WorldRewind
extends RefCounted

# 世界时空回溯系统：定频快照环形缓冲区与状态回放器。负责实体状态记录与编排回放。
#
# 架构设计：与 TileLedger 场景瓦片破坏账本协同工作，本模块负责实体状态回溯：
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
var _cursor := 0.0                 # 本次回溯已倒退的秒数
var _replay_bullets: Array = []    # 回放用子弹节点(与当前应用帧的 bullets 下标对应)
var _parent: Node = null           # 回放子弹的挂载父节点(通常 WorldViewport)


func _init(parent: Node = null) -> void:
	_parent = parent


# ── 录制(正常流逝)────────────────────────────────────────────

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
		var sh = b.get("shooter")
		# 引信/射程状态(爆炸弹"还剩多久炸")。不进快照 → 回溯重建的榴弹退回未点燃 →
		# 在错误时刻爆炸 + 松手贴脸起爆(见 BulletBase.rewind_state 的注释)。
		var fuse_state: Dictionary = b.call("rewind_state") if b.has_method("rewind_state") else {}
		pb.append({
			"sp": str(b.get_meta("scene_path", "")),
			"p": (b as Node2D).global_position,
			"v": b.get("velocity_vec"),
			"from_player": sh != null and sh is Node and (sh as Node).is_in_group("player"),
			"dmg": int(b.get("hit_damage")),
			"impact": float(b.get("hit_impact")),
			"fuse": fuse_state,
		})
	_frames.append({
		"t": _t,
		"player": _snapshot_player(player),
		"enemies": pe,
		"bullets": pb,
	})
	var cutoff := _t - TimeParams.SNAP_SECONDS
	while _frames.size() > 1 and float(_frames[0]["t"]) < cutoff:
		_frames.pop_front()


# ── 回放(回溯中)──────────────────────────────────────────────

## 进入回溯：清空场上子弹（改为由快照重建），回溯游标归零。
## 玩家状态快照：记录位置、速度、生命值、朝向、倒地状态以及武器背包与当前弹药量。
func _snapshot_player(player: Node) -> Dictionary:
	var d := {
		"p": (player as Node2D).global_position,
		"v": player.get("velocity"),
		"hp": int(player.get("hp")),
		"facing": int(player.get("facing_direction")),
		"downed": player.has_method("is_downed") and player.is_downed(),
		"wslot": 0, "widx": -1, "wmags": [], "wlive": -1,
	}
	var wc = player.get("weapons")
	if wc == null:
		return d
	# 记录武器类型编号与槽位索引，保持武器状态快照与恢复逻辑的字段一致性
	d["wslot"] = int(wc.get("_current_type"))
	d["widx"] = int(wc.get("_current_index"))
	var inv = wc.get("inventory")
	if inv != null:
		var mags: Array = []
		for e in inv.get("held"):
			mags.append(int(e.get("mag")))
		d["wmags"] = mags
	var live = wc.call("current_weapon") if wc.has_method("current_weapon") else null
	if live != null and is_instance_valid(live):
		d["wlive"] = int(live.get("mag_ammo"))
	return d


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


## 子弹:按快照帧重建(不足则实例化,多余则隐藏)。回放期间子弹由本函数摆位,
## 实体侧靠 TimeField 冻结;退出回溯后它们恢复为活弹继续飞。
func _apply_bullets(list: Array, player: Node) -> void:
	while _replay_bullets.size() < list.size():
		var meta: Dictionary = list[_replay_bullets.size()]
		var sp := str(meta["sp"])
		var nb: Node = null
		if sp != "" and ResourceLoader.exists(sp):
			nb = (load(sp) as PackedScene).instantiate()
			if _parent != null and is_instance_valid(_parent):
				_parent.add_child(nb)
			elif player != null and is_instance_valid(player):
				player.get_parent().add_child(nb)
			(nb as Node2D).global_position = meta["p"]
			nb.set("velocity_vec", meta["v"])
			if bool(meta["from_player"]):
				nb.set("shooter", player)
			nb.set("apply_damage", true)
			nb.set("hit_damage", int(meta.get("dmg", 0)))
			nb.set("hit_impact", float(meta.get("impact", 0.0)))
			if nb.has_method("apply_rewind_state"):
				nb.call("apply_rewind_state", meta.get("fuse", {}))
			# 重建子弹时必须保留 scene_path 元数据，确保后续二次回溯时能够正确实例化
			nb.set_meta("scene_path", sp)
		_replay_bullets.append(nb)
	for i in list.size():
		var nb2 = _replay_bullets[i]
		if is_instance_valid(nb2):
			(nb2 as Node2D).global_position = list[i]["p"]
			# 逐帧恢复子弹引信倒计时，使回退过程中的引信时间同步回流
			if nb2.has_method("apply_rewind_state"):
				nb2.call("apply_rewind_state", list[i].get("fuse", {}))
			(nb2 as Node2D).visible = true
	for i in range(list.size(), _replay_bullets.size()):
		if is_instance_valid(_replay_bullets[i]):
			(_replay_bullets[i] as Node2D).visible = false


# ── 查询/维护 ───────────────────────────────────────────────

## 当前回放目标时间(秒):瓦片账本按同一时间轴取区间还原。
func current_target() -> float:
	return _t - _cursor


## 回放中的子弹节点(回溯期 Level0 用它们对精英做二次伤害判定)。
func replay_bullets() -> Array:
	return _replay_bullets


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
