class_name WorldRewind
extends RefCounted

# 世界回溯:定频快照环缓(record)+ 反向应用器(step)。纯数据/编排,不碰 UI 与 shader。
# 快照含玩家(位置/速度/HP/朝向/倒地/武器弹量)、非精英敌人、子弹;精英不入快照、不回放(策划案)。
# 回放按快照重建子弹(不足则实例化)、把实体置回目标帧;回放期间不结算伤害(实体靠 TimeField.is_rewinding() 早退)。

static var hold_corpses := false   # 由 Level0 每帧同步:录制中=true(击杀保留尸体待复活)

var was_rewinding := false         # 状态沿(Level0 用它判进入/退出回溯)
var _frames: Array = []            # [{t, player:{...}, enemies:[...], bullets:[...]}]
var _t := 0.0                      # 世界已录制时间(秒)
var _acc := 0.0
var _cursor := 0.0                 # 本次回溯已倒退的秒数
var _replay_bullets: Array = []    # 回放用子弹节点(与当前应用帧的 bullets 下标对应)
var _parent: Node = null           # 回放子弹的挂载父节点(通常 WorldViewport)
# ★ 完成度观测量:判据是"分子 == 分母"(见 replay_completion_error()),不是 freed 引用数 == 0 —— 带子上留着
#   freed 实体是改动前就存在的条件,恒红的守卫与恒绿的一样没用;invalid_refs 只是登记用的观测量。
var _apply_started := 0
var _apply_completed := 0
var _bullets_completed := 0        # `_apply_bullets()` 自己的分子(见该函数末尾;评审 N-1)
var _invalid_refs := 0             # 带子上出现过的 freed / 非节点引用(观测)


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
# ★ 子弹段同理类型化;引信/射程状态必须逐帧带,rewind_state() 不再是"按名猜有没有"。
		var b := node as BulletBase
		if b == null:
			push_error("WorldRewind: bullets 里出现非 BulletBase 节点(%s)—— 本帧不为它入快照"
					% str(node))
			continue
		var sh := b.shooter
		# 进快照 → 回溯重建的榴弹不会退回未点燃(见 BulletBase.rewind_state 的注释)。
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
		"player": _snapshot_player(player),
		"enemies": pe,
		"bullets": pb,
	})
	var cutoff := _t - TimeParams.SNAP_SECONDS
	while _frames.size() > 1 and float(_frames[0]["t"]) < cutoff:
		_frames.pop_front()


# ── 回放(回溯中)──────────────────────────────────────────────

## 进入回溯:清空场上活弹(状态改由快照重建),游标归零。
# 玩家状态快照:位置/速度/HP/朝向/倒地 + 武器弹量(武器类型与下标、背包各格残弹、手持实弹数)。
func _snapshot_player(player: Node) -> Dictionary:
	var d := {
		"p": (player as Node2D).global_position,
		"v": player.get("velocity"),
		"hp": int(player.get("hp")),
		"facing": int(player.get("facing_direction")),
		"downed": player.has_method("is_downed") and player.is_downed(),
		"wslot": 0, "widx": -1, "wmags": [], "wlive": -1,
	}
# ★ 取组件用 as + 点名报错,不用带类型的直接赋值:后者在 weapons 不是 WeaponComponent 时会抛错并中止整个函数
#   ⇒ 退化成空字典(连同位置/HP 一起丢);现在武器四键停在初值,已收集的部分照旧返回。
	var wc := player.get("weapons") as WeaponComponent
	if wc == null:
		push_error("WorldRewind: player.weapons 不是 WeaponComponent —— 武器段无法回溯;本帧返回已收集的部分")
		return d
# ★ 反射改真类型访问买到的不是编译期红:4.7.1 对 class_name 上的未知成员只按警告级 UNSAFE_* 处理,拼错同样是运行期报错。
# ★ 本函数仍有 5 处按名访问玩家根(player.gd 无 class_name,类型化要动类结构,已登记 registered-debt §六.15 —— ★ 2026-10-13 订正:原写 §六.14,本节编号有历史重复,该条现为 §六.15);
#   其中 has_method("is_downed") 一改名就静默把 downed 写成 false ⇒ 消费端静默跳过倒地/复活还原。零守卫(两支 rewind 探针已删·2026-10-09)。
	d["wslot"] = wc._current_type
	d["widx"] = wc._current_index
	var inv: WeaponInventory = wc.inventory
	if inv != null:
		var mags: Array = []
		for e in inv.held:
			mags.append(int(e["mag"]))
		d["wmags"] = mags
	var live: WeaponBase = wc.current_weapon()
	if live != null and is_instance_valid(live):
		d["wlive"] = live.mag_ammo
	return d


func begin() -> void:
	_cursor = 0.0
	_replay_bullets.clear()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		for b in tree.get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()


# 退出回溯(录像带模型):把"过去的将来"从磁带上裁掉,磁带钟退回出口,之后 record() 从这里续录 ⇒ 两次回溯互不串带。
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
	_apply_started += 1     # 完成度分母(见 `apply_started_count()`)
	_apply(_frame_at(target), player)


# ★ 断言口径:两条分子各配一个分母(apply_completed / apply_bullets_completed),不是 freed 引用数 == 0(那会恒红)。
func apply_started_count() -> int:
	return _apply_started


func apply_completed_count() -> int:
	return _apply_completed


# 子弹段"走完或无事可做"的帧数:与 apply_completed_count() 是两条独立分子(_apply 空帧早退也会给它 +1)。
func apply_bullets_completed_count() -> int:
	return _bullets_completed


func invalid_ref_count() -> int:
	return _invalid_refs


# 回放完成度的唯一判据:正常返回空串,否则返回一句可直接当探针判词的错话(只读、无副作用;无样本也在这里报)。
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
# 空帧 = 无事可做,不是中止;这里把 _bullets_completed 一起 +1 只为保住两条分子形态一致(今天不可达,死防御)。
		_apply_completed += 1
		_bullets_completed += 1
		return
	if is_instance_valid(player) and player.has_method("rewind_restore"):
		player.rewind_restore(f["player"])
	for d in f["enemies"]:
# ★★ is_instance_valid() 必须先于类型收窄:对真 freed 实例做 as EnemyBase 会抛错并中止整个 _apply() ⇒ 同帧
#   _apply_bullets() 整段被跳过。故 var raw 故意不加类型(带类型的赋值本身就会碰 freed 实例)。freed/非节点 ⇒
#   计数 + 静默跳过;有效但非 EnemyBase ⇒ 点名报错并跳过这一件。
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
# ★ 这一行只证明 _apply() 自己的函数体走到末尾,看不见 _apply_bullets() 体内的中止(脚本错误只中止出错的那个函数)。
	_apply_completed += 1


# 子弹按快照帧重建(不足则实例化,多余则隐藏);回放期间由本函数摆位,实体侧靠 TimeField 冻结。
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
# 循环二/三:同样先判有效性、再类型收窄(对真 freed 做 as 会中止整个函数)。今天取到 freed 引用不可达
# (_replay_bullets 只由本函数填、begin/finish 都 clear、回溯期子弹自毁路径全早退)—— 顺序本身就是不变量。
	for i in list.size():
		var raw2 = _replay_bullets[i]
		if not is_instance_valid(raw2):
			continue
		var nb2 := raw2 as BulletBase
		if nb2 == null:
			continue
		nb2.global_position = list[i]["p"]
		nb2.velocity_vec = list[i]["v"]
		# 引信每帧写回:倒退时引信跟着退(否则它会冻结在按下那一刻的剩余量)
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
# ★ 本函数自己的完成度分子:_apply() 末尾那次递增看不见本函数体内的中止(脚本错误只中止出错的那个函数)。
	_bullets_completed += 1


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


# 尸体过期清理:录制中被保留(隐藏)的尸体,死亡时刻(meta rw_death_ms)超出缓冲窗口才真正释放。
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
