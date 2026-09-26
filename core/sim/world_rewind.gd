class_name WorldRewind
extends RefCounted

# 世界回溯(第一阶段):定频快照环缓 + 反向应用器。纯数据/编排,不碰 UI 与 shader。
#
# 模型(与旧线"瓦片事件账本"互补:本阶段只倒实体,瓦片账本下一阶段接):
#   · record():正常流逝时每 1/SNAP_HZ 秒采一帧 —— 玩家(位置/速度/HP/朝向/倒地)、
#     非精英敌人(位置/速度/HP/存亡)、子弹(场景路径/位置/速度/归属)。
#   · step():回溯中按"已倒退秒数"游标从最新帧往回走,应用目标帧(位置/状态一次性置回);
#     子弹按快照**重建/重定位**(回溯起点清空活弹,由快照帧接管)。
#   · 精英不入快照、不回放(策划案:精英不受回溯影响,依旧保持原本行为)。
#   · 尸体保留:录制期间被击杀的敌人不立即释放(hold_corpses),隐藏待复活;
#     超出缓冲窗口(TimeParams.SNAP_SECONDS)后才由 Level0 清理。
#   · 回放期间不结算伤害:实体脚本靠 TimeField.is_rewinding() 早退,Level0 在回放帧不喂输入。

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
		pb.append({
			"sp": str(b.get_meta("scene_path", "")),
			"p": (b as Node2D).global_position,
			"v": b.get("velocity_vec"),
			"from_player": sh != null and sh is Node and (sh as Node).is_in_group("player"),
			"dmg": int(b.get("hit_damage")),
			"impact": float(b.get("hit_impact")),
		})
	_frames.append({
		"t": _t,
		"player": {
			"p": (player as Node2D).global_position,
			"v": player.get("velocity"),
			"hp": int(player.get("hp")),
			"facing": int(player.get("facing_direction")),
			"downed": player.has_method("is_downed") and player.is_downed(),
		},
		"enemies": pe,
		"bullets": pb,
	})
	var cutoff := _t - TimeParams.SNAP_SECONDS
	while _frames.size() > 1 and float(_frames[0]["t"]) < cutoff:
		_frames.pop_front()


# ── 回放(回溯中)──────────────────────────────────────────────

## 进入回溯:清空场上活弹(状态改由快照重建),游标归零。
func begin() -> void:
	_cursor = 0.0
	_replay_bullets.clear()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()


## 退出回溯:回放子弹保持在场(世界从倒退后的状态继续),游标归零。
func finish() -> void:
	_cursor = 0.0
	_replay_bullets.clear()


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
		_replay_bullets.append(nb)
	for i in list.size():
		var nb2 = _replay_bullets[i]
		if is_instance_valid(nb2):
			(nb2 as Node2D).global_position = list[i]["p"]
			nb2.set("velocity_vec", list[i]["v"])
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
