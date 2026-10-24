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

# 接入方每物理步写一次:本帧是否正在贴身(Player.touching_player())。★ 默认 false = 改动前的行为;它不进 capture_state/restore_state、不上行(纯客户端本地量)。
var in_contact: bool = false

func bind(p) -> void:
	_p = p

func last_applied() -> int:
	return _last_applied

func rollback_count() -> int:
	return _rollbacks

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

func note_post_step(seq: int, capture: Dictionary) -> void:
	_last_applied = maxi(_last_applied, seq)
	_captures[seq] = capture
	_seqs.append(seq)
	while _seqs.size() > KEEP:
		var old: int = _seqs.pop_front()
		_captures.erase(old)

func note_input(seq: int, record: Dictionary) -> void:
	_inputs[seq] = record

func on_authoritative(ack: int, state: Dictionary) -> void:
	if ack <= _acked:
		return
	_pending.append([ack, state])

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
		_p._physics_process(PHYS_DT)
	_p.set_input_source(prev)

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
			"pos_err": snappedf(_pos_dist(predicted.get("pos", Vector2.ZERO), S.get("pos", Vector2.ZERO)), 0.01),
			"vel_err": snappedf(Vector2(predicted.get("vel", Vector2.ZERO)).distance_to(Vector2(S.get("vel", Vector2.ZERO))), 0.01),
			"in_contact": in_contact,
			"hp_before": int(predicted.get("hp", 0)),
			"hp_after": int(S.get("hp", 0)),
			"replay": _last_applied - ack,
		}, true)
	_rollbacks += 1
	_p.restore_state(S)
	for s in _seqs:
		if s > ack and s <= _last_applied:
			var rec: Dictionary = _inputs.get(s, {})
			if rec.is_empty():
				continue
			_step(rec)
			_captures[s] = _p.capture_state()   # 刷新为重放后的真实整态
	_trim(ack)

func _trim(below: int) -> void:
	while not _seqs.is_empty() and _seqs[0] <= below:
		var s: int = _seqs.pop_front()
		_inputs.erase(s)
		_captures.erase(s)

# 两整态是否"预测被证实":只比影响判定的关键量,避免过度回滚;超出 = 服务器外部事件或漂移 → 走 rollback。
func _close_enough(a: Dictionary, b: Dictionary) -> bool:
	if a.get("down", false) != b.get("down", false):
		return false
	if int(a.get("hp", 0)) != int(b.get("hp", 0)):
		return false
	# 容差按接触与否二选一:非接触期的位置分歧是真的(要立刻纠正),
	# 接触期的位置分歧是接触几何噪声(实测纠正不动,见 contact_pos_tol 的说明)。
	var tol: float = contact_pos_tol if in_contact else pos_tol
	if _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) > tol:
		return false
	var va: Vector2 = a.get("vel", Vector2.ZERO)
	var vb: Vector2 = b.get("vel", Vector2.ZERO)
	return va.distance_to(vb) < 20.0


# 两个位置在环面上是否几乎同位:裸 distance_to 在跨接缝那一帧会给出「一整幅地图宽」的假分歧 ⇒ 白跑一次回滚。
func _pos_dist(a: Vector2, b: Vector2) -> float:
	if map_px.x <= 0.0 or map_px.y <= 0.0:
		return a.distance_to(b)
	return MazeGenerator.toroidal_delta_px(a, b, map_px.x, map_px.y).length()
