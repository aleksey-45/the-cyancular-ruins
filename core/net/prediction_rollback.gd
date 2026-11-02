class_name PredictionRollback
extends RefCounted
# C2 rollback 控制器(与引擎解耦,纯逻辑):驱动方式由接入方决定 —— 手动步进(每帧 advance)或引擎自步进(note_post_step + note_input)。
# 收到权威(ack=C, 整态 S):ring[C] ≈ S → 预测被证实,trim <= C;ring[C] != S → 真性分歧(服务器外部事件:命中/传送/换边/墙/漂移),
# restore(S) 后按序重放 (C, last_applied] 的本地输入 —— 「重放 = 错在哪补哪」,绝不做橡皮筋位置拉拢。

const KEEP := 256           # ring 保留窗口(条记录;U1 后一条 = 1 tick ⇒ 4.3 秒)
const PHYS_DT := 1.0 / 60.0 # 回滚重放一律按固定物理步(确定性)
# 每条输入记录覆盖几个物理步:**1**(U1:一条记录 = 1 tick,60Hz 真输入,服务器每 tick 消费一条)。
# 保留这个 var 是因为纯逻辑探针/旧语义仍可显式设 2;PvP 客户端不再改它。
var ticks_per_record := 1

var _p = null               # 被预测 Player(动态)
var _scratch: PacketInputSource = PacketInputSource.new()   # 步进/重放喂入源

var _inputs: Dictionary = {}   # seq(int) -> 输入包记录(重放用)
var _captures: Dictionary = {} # seq(int) -> 步进后 capture_state()(比对/锚点)
var _seqs: Array[int] = []     # _captures 键升序
var _last_applied := 0
var _acked := 0
var _pending: Array = []       # [[ack, state], ...] 待 reconcile
var _rollbacks := 0
var _last_event_seq := 0       # 已按历史注入过的最大事件 seq(乱序事件拒绝用)
var _event_aligns := 0         # 事件对齐次数(诊断量;不计入 _rollbacks)
var _event_rejects := 0        # 事件拒绝次数(诊断量;兜底路径频率)
var _rej_ack := 0              # 拒绝原因:已被权威 ack 覆盖(seq <= _acked)
var _rej_future := 0           # 拒绝原因:来自未来(seq > _last_applied)
var _rej_missing := 0          # 拒绝原因:环里没有该 seq
var _rej_order := 0            # 拒绝原因:乱序 / callable 失效
var _events: Dictionary = {}   # seq(int) -> Array[Callable] 已注入的外部事件(重放/回滚时按 seq 重放,见 _apply_events_at)

# 环面地图尺寸(像素)。ZERO = 不做环面处理(退回裸距离比较);刻意不引 autoload,由接入方显式设,-s 下也能空跑。
var map_px: Vector2 = Vector2.ZERO

# 「预测被证实」的位置容差(px),回滚频率的闸门:贴身时对手在客户端眼里恒有滞后(实测 8 tick ≈ 93px),1px 容差会每帧 restore+重放。
# 实测 2px 砍掉 ~95% 频率而接触期偏差一行没动(那每帧一次的回滚本来就没买到精度)。代价:容差内的位置误差不再纠正;down/hp 仍精确比较。
const DEFAULT_POS_TOL := 2.0
var pos_tol: float = DEFAULT_POS_TOL

# 接触期(与远端玩家身体贴身)的位置容差 8.0:贴身的位置分歧由接触几何决定、回滚纠正不动(实测 1/2/4/8px 四档接触期偏差逐项相同)。
# ★ 这是扫描结论、不是随手可调的旋钮:要动它得重跑 CONTACT 族扫描并复核三条读数(偏差不恶化 / 8 与 16/32 频率同档 / 软接触只占体宽 1/10)。零守卫(brawl_rollback_probe 已删·2026-10-09)。
const DEFAULT_CONTACT_POS_TOL := 8.0
var contact_pos_tol: float = DEFAULT_CONTACT_POS_TOL
# ★ 2026-10-28:客户端在贴身区按"相对速度 × 幽灵滞后"动态覆盖它(8~48px,见 core/net/prediction_contact.gd);
#   本常量现在只是下限/默认值,别再以为它恒是 8。

# 接触期**速度**容差(px/s)。★ 2026-10-31:同一台机器 3 客户端 soak 实测,回滚里 **83~98% 是"纯速度分歧"**
#   (pos 在容差内、hp 未变、只有 vel 超过 20)且几乎全部发生在贴身(92~98%)—— 贴身时客户端撞的是"幽灵体"
#   (按权威速度外推的对手),服务器撞的是对手**此刻**的真实身体,碰撞法线/冲量必然不同 ⇒ 贴身期速度分歧是
#   接触几何噪声,和位置同理(见 DEFAULT_CONTACT_POS_TOL 的由来)。容差 400 ≈ 走速(~700)的 57%:
#   实测贴身期 vel_err p90=275~334,400 覆盖常规碰撞噪声;仍能抓住冲刺/击退量级(>400)的真分歧。
#   ★ 非接触期仍是严格 20(那一档不是几何噪声,是"两端慢慢漂"的起点)。
const DEFAULT_CONTACT_VEL_TOL := 400.0
var contact_vel_tol: float = DEFAULT_CONTACT_VEL_TOL
# ★ 边界:贴身判据 `in_contact` 是客户端启发式(幽灵 AABB 间隙 ≤ CONTACT_GAP),不是精确碰撞 ⇒ 容差放宽
#   期间若真的漏掉一次"只改了速度、位置几乎没动"的权威修正(理论上只有击退初速),要等下一次位置分歧或
#   hit_event 才会纠正。观感/命中仍由 hit_event/快照兜底,不是静默错下去。
const VEL_TOL := 20.0

# 「预测被证实」要比对的字段集合(单一来源):S-06 —— 原先这 4 个字段的判据散在 _close_enough 函数体里,
# 往 Player.capture_state() 加一个"影响下一帧判定"的字段时没有任何东西提醒也加进比对(症状 = 两端慢慢漂、
# 只在碰巧回滚时纠正,不报错)。★ 这里只列"要比"的字段;inv/wslot/残弹是非预测字段,刻意不比(见 weapons.md)。
# ★ 每个键都必须在真 capture_state() 里存在 —— `rollback_fidelity_probe` 的预测字段断言盯着这一点。
const PREDICTED_FIELDS := ["down", "hp", "pos", "vel"]

# 接入方每物理步写一次:本帧是否正在贴身(Player.touching_player())。★ 默认 false = 改动前的行为;它不进 capture_state/restore_state、不上行(纯客户端本地量)。
var in_contact: bool = false

func bind(p) -> void:
	_p = p

func last_applied() -> int:
	return _last_applied

func rollback_count() -> int:
	return _rollbacks


func event_aligns() -> int:
	return _event_aligns


func event_rejects() -> int:
	return _event_rejects


## 拒绝原因分解(真链路读数用):ack=已被权威覆盖 / future=来自未来 / missing=环外 / order=乱序或失效。
func event_reject_breakdown() -> String:
	return "ack=%d future=%d missing=%d order=%d" % [_rej_ack, _rej_future, _rej_missing, _rej_order]

func advance(record: Dictionary) -> void:
	reconcile()
	if _p == null:
		return
	var seq := int(record.get("seq", _last_applied + 1))
	_step(record)
	_last_applied = seq
	_inputs[seq] = record
	_captures[seq] = _p.capture_state()
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_inputs.erase(old)
		_captures.erase(old)
		_events.erase(old)

func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	_captures[seq] = capture
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_inputs.erase(old)   # ★ 与 advance() 的淘汰同款三清;旧写法漏这一行 ⇒ ack 断流时 _inputs 以 60/s 无界增长(重连/本人包停摆期间)
		_captures.erase(old)
		_events.erase(old)

func note_input(seq: int, record: Dictionary) -> void:
	_inputs[seq] = record

func on_authoritative(ack: int, state: Dictionary) -> void:
	if ack <= _acked:
		return
	_pending.append([ack, state])

# 外部事件注入的返回码。★ APPLIED 必须是 0:GDScript 运行期错误只会打断"出错的那个函数"并按返回类型给默认值,
# 拒绝路径若被写坏(越界访问)会返回默认值 —— 让它落在 APPLIED 上,探针的"必须 REJECTED"断言才会红,而不是静默假绿。
enum EventApply { APPLIED, REJECTED }

# 把一次服务器外部事件(受击)注入预测历史:恢复 _captures[seq] → apply() → 重放 (seq, last_applied]。
# 锚点 = 服务器**上一条已完成步进**的 seq(裁决在子节点步进之前,见 MatchState._stepped_seq 的注释);
# 注入记进 _events,后续任何一次回滚重放都会在对应 seq 重新应用它(I3:否则迟到旧 ack 会把它抹掉)。
# 返回 REJECTED = 不能安全注入(未来 / 已 ack / 环里没有 / 乱序 / callable 失效),调用方必须走兜底(只播反馈)。
# ★ 事件按 seq 递增到达(reliable 保序);seq 回退拒绝。★ 本 API 不碰 _rollbacks(事件对齐不是"预测被证伪")。
func apply_external_event(seq: int, apply: Callable) -> int:
	if _p == null or not apply.is_valid():
		_event_rejects += 1
		_rej_order += 1
		return EventApply.REJECTED
	if seq > _last_applied:
		_event_rejects += 1
		_rej_future += 1
		return EventApply.REJECTED
	if seq <= _acked:
		_event_rejects += 1
		_rej_ack += 1
		return EventApply.REJECTED
	if not _captures.has(seq):
		_event_rejects += 1
		_rej_missing += 1
		return EventApply.REJECTED
	if seq < _last_event_seq:
		_event_rejects += 1
		_rej_order += 1
		return EventApply.REJECTED
	if not _events.has(seq):
		_events[seq] = []
	(_events[seq] as Array).append(apply)
	# ★ 只应用"这一发新事件":_captures[seq] 里已经含该 seq 上更早事件的效果(同 tick 多发),再全量重放会重复扣。
	_p.restore_state(_captures[seq])
	apply.call()
	_captures[seq] = _p.capture_state()
	_replay_steps_after(seq)
	_last_event_seq = seq
	_event_aligns += 1
	return EventApply.APPLIED


# 重放 anchor 之后的每一步;每步之后按 seq 重放该 seq 上注入过的事件(与注入时的顺序一致:步进完再挨打)。
func _replay_steps_after(anchor: int) -> void:
	for s in _seqs:
		if s > anchor and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			_step(rec)
			_apply_events_at(s)
			_captures[s] = _p.capture_state()


func _apply_events_at(seq: int) -> void:
	var evs: Array = _events.get(seq, [])
	for ev in evs:
		var cb: Callable = ev
		if cb.is_valid():
			cb.call()

func reconcile() -> void:
	while not _pending.is_empty():
		var pk: Array = _pending.pop_front()
		_handle_ack(int(pk[0]), pk[1])

# 用记录步进一次:临时把玩家输入源换成 scratch(喂入该记录),步进后换回 —— 被预测玩家平时读真实输入(真机手感不变),重放才切历史输入。
# ★ 一条记录按 ticks_per_record 连跑(U1 下 = 1 步):与服务器逐 tick 同序。
func _step(record: Dictionary) -> void:
	if _p == null:
		return
	var prev = _p.input_source
	_p.set_input_source(_scratch)
	_scratch.clear_edges()
	_scratch.apply_packet(record)
	for i in maxi(1, ticks_per_record):
		if i > 0:
			_scratch.clear_edges()   # 第二 tick 起只保留 held(边沿只在该记录第一个 tick 生效)
		_manual_sim_step()
	_p.set_input_source(prev)


# ★★ 重放用的**手动物理步**。这里是「双驱动」的控制器那一半 —— 引擎也在步进同一个节点,时序契约:
#   ① 引擎侧:本地玩家节点自己的 `_physics_process` 每物理帧被引擎调一次,**重放期间不失能**(全仓没有对它
#      set_physics_process(false));它负责"本帧这一 tick"的那一次步进。
#   ② 控制器侧:生产路径只有 `_replay_steps_after` 调到这里,而它由**父节点**(PvpMatchClient)的
#      `_physics_process` 同步驱动 —— 树序上父先于子(玩家是它 add_child(level_0) 的孙子),所以重放永远是
#      `(ack, _last_applied]` 这些**引擎已经步进过**的旧 tick,不重复步进当前帧。纯逻辑探针走 advance() 手动
#      驱动,同一个入口;那种"接入方自己步进"的模式下须由接入方保证不双跑。
#   ③ ⇒ 以上靠两个**没有守卫**的前提:父节点排玩家之前(重排节点 / 改 physics_priority 会静默破掉)+
#      `_last_applied` 只是上一帧的 seq(note_post_step 必须先于本帧步进)。任一破掉 = 多跑一 tick、回滚分歧。
#   ④ 收敛方向(动玩家物理入口/帧序 = "回滚与快照"承重面,需 Lead 决策,此处**没有**落地):玩家侧抽
#      `step_sim(dt)` 作唯一物理步入口,引擎与重放共用,并把只该在引擎路径做的每帧表现副作用挡在重放外;
#      本函数随之只调 `_p.step_sim(PHYS_DT)`。★ PHYS_DT 与引擎 delta 的等价还依赖 physics_ticks_per_second == 60。
func _manual_sim_step() -> void:
	_p._physics_process(PHYS_DT)

func _handle_ack(ack: int, S: Dictionary) -> void:
	if ack <= _acked:
		return
	_acked = ack
	if _p == null or not _captures.has(ack):
		_trim(ack)
		return
	var predicted: Dictionary = _captures[ack]
	if _close_enough(predicted, S):
# ★ "预测被证实"只说明 down/hp/pos/vel 对得上:背包(inv/wslot)与残弹是非预测字段(拾取/丢弃/复活/换局全由服务器裁决),
#   不在这里补一次,客户端就只会在碰巧发生回滚时才看见自己捡了枪(表现为地上的枪没了、手上也没多、还开不了火,一条报错都没有)。
		if _p.has_method("sync_soft_state"):
			_p.sync_soft_state(S)
		_trim(ack)          # 预测被证实:确认丢弃 ≤ ack
		return
	# 真性分歧 → 权威锚定 + 重放未确认输入(错在哪补哪,非拉拢)
	# 诊断(--diag,默认关):这一行就是「本地被拉回」的那一帧。位置/速度误差、是否贴身、重放条数分开记,
	# 用来区分「服务器少模拟 tick」与「拆砖/传送这类外部事件」(判据见 docs/eng/tests.md)。
	if NetDiag.enabled():
		NetDiag.log_event("rollback", {
			"ack": ack,
			"field": last_fail_field,
			"pos_err": snappedf(_pos_dist(predicted.get("pos", Vector2.ZERO), S.get("pos", Vector2.ZERO)), 0.01),
			"vel_err": snappedf(Vector2(predicted.get("vel", Vector2.ZERO)).distance_to(Vector2(S.get("vel", Vector2.ZERO))), 0.01),
			"in_contact": in_contact,
			"pos_tol": snappedf(contact_pos_tol if in_contact else pos_tol, 0.01),
			"vel_tol": snappedf(contact_vel_tol if in_contact else VEL_TOL, 0.01),
			"hp_before": int(predicted.get("hp", 0)),
			"hp_after": int(S.get("hp", 0)),
			"replay": _last_applied - ack,
		}, true)
	_rollbacks += 1
	_p.restore_state(S)
	_apply_events_at(ack)      # 权威 S 是注入前锚点的状态时(ack == 事件 seq),先把该 seq 的事件补上,否则重放会把它抹掉
	_replay_steps_after(ack)
	_trim(ack)

func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)
		_events.erase(s)

# 两整态是否"预测被证实":只比影响判定的关键量,避免过度回滚;超出 = 服务器外部事件或漂移 → 走 rollback。
# ★ 比对集 = PREDICTED_FIELDS(单一来源);容差与判据按字段分派在 _within(位置容差是接触与否二选一,不能简化)。
# ★ `last_fail_field` 只为诊断(--diag 的 rollback 行):告诉读日志的人"这次到底哪个字段判了分歧",不用再猜。
var last_fail_field := ""

func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	last_fail_field = ""
	for f in PREDICTED_FIELDS:
		if not _within(String(f), a, b):
			last_fail_field = String(f)
			return false
	return true


# 单字段比对。默认分支 false = 表里出现未知字段时判分歧(大声:宁多回滚一次,也不静默当成一致)。
func _within(field: String, a: Dictionary, b: Dictionary) -> bool:
	match field:
		"down":
			return a.get("down", false) == b.get("down", false)
		"hp":
			return int(a.get("hp", 0)) == int(b.get("hp", 0))
		"pos":
			var tol: float = contact_pos_tol if in_contact else pos_tol
			return _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) <= tol
		"vel":
			var va: Vector2 = a.get("vel", Vector2.ZERO)
			var vb: Vector2 = b.get("vel", Vector2.ZERO)
			var vtol: float = contact_vel_tol if in_contact else VEL_TOL
			return va.distance_to(vb) < vtol
		_:
			return false


# 两个位置在环面上是否几乎同位:裸 distance_to 在跨接缝那一帧会给出「一整幅地图宽」的假分歧 ⇒ 白跑一次回滚。
func _pos_dist(a: Vector2, b: Vector2) -> float:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return a.distance_to(b)
	return MazeGenerator.toroidal_delta_px(a, b, map_px.x, map_px.y).length()
