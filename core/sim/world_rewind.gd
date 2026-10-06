class_name WorldRewind
extends RefCounted

# 世界时空回溯系统：基于定频快照环形缓冲区与状态回放器。纯数据管理与调度，不耦合 UI 与 Shader。
#
# 系统模型：
#   · record()：正常游戏时间流逝时，每 1/SNAP_HZ 秒采集一帧快照 —— 玩家（位置、速度、生命值、朝向、倒地状态）、
#     非精英敌人（位置、速度、生命值、存活状态）、子弹（场景路径、位置、速度、归属）。
#   · step()：回溯期间按已倒退时间游标从最新帧向历史回放，将目标帧状态还原至各实体；
#     子弹根据快照进行重建与位置重定向（进入回溯时清空当前活动子弹，由快照帧接管）。
#   · 精英实体不记录进快照、不参与回溯，保持原本行为与行动。
#   · 实体状态保留：在录制窗口内被击杀的敌人不立即释放（设置 hold_corpses），暂时隐藏以便在回溯时复活；
#     超出历史记录窗口（TimeParams.SNAP_SECONDS）后由 Level0 统一释放清理。
#   · 回溯期间不结算常规伤害：实体脚本通过 TimeField.is_rewinding() 跳过逻辑，Level0 在回溯期间不传递输入。

static var hold_corpses := false   # 由 Level0 每帧同步更新：录制中为 true（击杀敌人后保留节点待回溯复活）

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
		# 引信与射程动态状态（如爆炸弹剩余引信时间）。若未保存，重建的榴弹将重置为初始状态，
		# 导致在错误时刻爆炸或松开回溯键时近距离触碰起爆（参见 BulletBase.rewind_state 说明）。
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

## 进入回溯：清空场上活动子弹（后续由快照重建），游标重置为 0。
## 玩家状态快照：记录位置、速度、生命值、朝向、倒地状态以及武器弹药配置（当前武器类型与槽位、各背包槽位弹药、手持武器弹药）。
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
	d["wslot"] = int(wc.get("_current_slot"))
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


## 退出回溯：回放子弹保留在场上（世界从回溯终止点继续正常模拟），游标重置为 0。
func finish() -> void:
	_cursor = 0.0
	_replay_bullets.clear()


func step(delta: float, player: Node) -> void:
	if _frames.size() < 2:
		return
	_cursor += delta * _mult()
	var target := _t - _cursor
	_apply(_frame_at(target), player)


## 初始快速倒流过渡至 1.0×（基于已倒退时间计算渐变，倒退越久越平稳收敛至 1.0×）
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


## 子弹回放：根据快照帧重建或重用节点（不足则实例化，多余则隐藏）。回放期间子弹由本方法更新位置，
## 实体更新通过 TimeField 冻结；退出回溯后恢复为正常活动子弹继续飞行。
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
		_replay_bullets.append(nb)
	for i in list.size():
		var nb2 = _replay_bullets[i]
		if is_instance_valid(nb2):
			(nb2 as Node2D).global_position = list[i]["p"]
			nb2.set("velocity_vec", list[i]["v"])
			# 每帧写回引信状态：使引信倒计时跟随回溯时间同步倒退
			if nb2.has_method("apply_rewind_state"):
				nb2.call("apply_rewind_state", list[i].get("fuse", {}))
			(nb2 as Node2D).visible = true
	for i in range(list.size(), _replay_bullets.size()):
		if is_instance_valid(_replay_bullets[i]):
			(_replay_bullets[i] as Node2D).visible = false


# ── 查询/维护 ───────────────────────────────────────────────

## 当前回放目标时间（秒）：瓦片账本按同一时间轴获取时间区间并进行还原。
func current_target() -> float:
	return _t - _cursor


## 获取当前回放中的子弹节点数组（回溯期间 Level0 使用其对精英敌人进行二次伤害判定）。
func replay_bullets() -> Array:
	return _replay_bullets


func frame_count() -> int:
	return _frames.size()


func recorded_seconds() -> float:
	return _t


## 已阵亡敌人节点过期清理：录制中保留隐藏的敌人节点，若阵亡时间超出历史缓冲区时长则彻底释放。
## 由 Level0 每帧调用，通过元数据 rw_death_ms 判定阵亡时间戳。
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
