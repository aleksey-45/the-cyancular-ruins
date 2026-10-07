class_name TimeField
extends RefCounted

# 世界时间场（阶段一）：将“时空回溯/时间加速/透支状态”转换为各实体每帧的 delta 时间缩放倍率。
# 统一封装集中查询接口，实体脚本仅需调用 delta = TimeField.xxx_delta(delta, self)。
#
# 设计要点:
#   - current 仅在单人关卡 Level0 中实例化；PvP 对局、菜单及测试探针中为 null，所有时间倍率恒为 1.0（完全不受影响）。
#   - HASTE(加速):玩家与精英 ×HASTE_PLAYER(2),普通敌人与敌方子弹 ×HASTE_WORLD(1)
#     ——"玩家相对普通敌人两倍"由**相对差**达成,不动 Engine.time_scale(物理/tween/网络不受扰)。
#   - REWIND(回溯):普通敌人/子弹/玩家 ×0(冻结,由回放器接管位置);**精英与玩家无关照常行动**
#     (策划案:精英怪不受回溯影响,依旧保持原本行为)。
#   - 透支状态：根据透支深度使普通敌人加速 × (1 + LOAN_ENEMY_SPEED_BONUS * depth)。

enum Mode { NONE, REWIND, HASTE }

static var current: TimeField = null   # 单机世界场实例;null = 全域恒 1

var mode: int = Mode.NONE
var account: GrainAccount = null
var rewind_time: float = 0.0           # 本次回溯持续(秒;视效 ramp 用)


func _init(acc: GrainAccount) -> void:
	account = acc


## 由 Level0 每帧调用:want_* = 按键按住状态。结算恢复/消耗,定模式。
func update(delta: float, want_rewind: bool, want_haste: bool) -> void:
	if account == null:
		mode = Mode.NONE
		return
	account.regen(delta)   # 短期时间窗口 50/s 常驻递减恢复(含偿还透支)
	var want := Mode.NONE
	if account.can_spend():
		if want_rewind and not want_haste:
			want = Mode.REWIND
		elif want_haste:
			want = Mode.HASTE
	if want == Mode.REWIND:
		account.spend(delta, TimeParams.COST_REWIND)
		rewind_time += delta
	else:
		rewind_time = 0.0
		if want == Mode.HASTE:
			account.spend(delta, TimeParams.COST_HASTE)
	# 颗粒余额当帧耗尽时立即终止效果，防止出现无余额仍继续回溯的异常帧
	if want != Mode.NONE and account.balance <= 0.0:
		want = Mode.NONE
		rewind_time = 0.0
	mode = want


func loan_depth() -> float:
	return account.loan_depth() if account != null else 0.0


func is_rewinding() -> bool:
	return mode == Mode.REWIND


func is_hasting() -> bool:
	return mode == Mode.HASTE


# ── 纯静态倍率查询(实体脚本调用;current 为 null 时恒 1)────────────

static func player_delta(d: float) -> float:
	var f := current
	if f == null:
		return d
	match f.mode:
		Mode.REWIND:
			return 0.0
		Mode.HASTE:
			return d * TimeParams.HASTE_PLAYER
	return d


static func enemy_delta(d: float, node: Node) -> float:
	var f := current
	if f == null:
		return d
	var elite: bool = node != null and node.has_meta("elite")
	if f.mode == Mode.REWIND:
		return d if elite else 0.0   # 精英不受回溯影响
	var mult := 1.0
	if f.mode == Mode.HASTE:
		mult = TimeParams.HASTE_PLAYER if elite else TimeParams.HASTE_WORLD
	if not elite:
		mult *= 1.0 + TimeParams.LOAN_ENEMY_SPEED_BONUS * f.loan_depth()
	return d * mult


static func bullet_delta(d: float, bullet: Node) -> float:
	var f := current
	if f == null:
		return d
	if f.mode == Mode.REWIND:
		return 0.0
	if f.mode != Mode.HASTE:
		return d
	var from_player := false
	if bullet != null:
		var s = bullet.get("shooter")
		from_player = s != null and s is Node and (s as Node).is_in_group("player")
	return d * (TimeParams.HASTE_PLAYER if from_player else TimeParams.HASTE_WORLD)


# 其它世界物件(掉落武器等):加速时随世界变慢,回溯时冻结。语义同"除主角外一切变慢"。
static func world_delta(d: float) -> float:
	var f := current
	if f == null:
		return d
	if f.mode == Mode.REWIND:
		return 0.0
	if f.mode == Mode.HASTE:
		return d * TimeParams.HASTE_WORLD
	return d


# ── 速度域倍率(正确做法:move_and_slide 用引擎 delta,缩放 delta 不改变位移;
#    "快/慢"必须落在速度上;delta 缩放只用于计时器/动画/AI 节拍)────────────

static func player_speed_mult() -> float:
	var f := current
	if f == null:
		return 1.0
	if f.mode == Mode.REWIND:
		return 0.0
	if f.mode == Mode.HASTE:
		return TimeParams.HASTE_PLAYER
	return 1.0


static func enemy_speed_mult(node: Node) -> float:
	var f := current
	if f == null:
		return 1.0
	var elite: bool = node != null and node.has_meta("elite")
	if f.mode == Mode.REWIND:
		return 0.0 if not elite else 1.0
	if f.mode == Mode.HASTE:
		return TimeParams.HASTE_PLAYER if elite else TimeParams.HASTE_WORLD
	return 1.0 if elite else 1.0 + TimeParams.LOAN_ENEMY_SPEED_BONUS * f.loan_depth()
