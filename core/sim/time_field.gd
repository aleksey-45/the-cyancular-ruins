class_name TimeField
extends RefCounted


enum Mode { NONE, REWIND, HASTE }

static var current: TimeField = null

var mode: int = Mode.NONE
var account: GrainAccount = null
var rewind_time: float = 0.0


func _init(acc: GrainAccount) -> void:
	account = acc


func update(delta: float, want_rewind: bool, want_haste: bool) -> void:
	if account == null:
		mode = Mode.NONE
		return
	account.regen(delta)
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



static func enemy_delta(d: float, node: Node) -> float:
	var f := current
	if f == null:
		return d
	var elite: bool = node != null and node.has_meta("elite")
	if f.mode == Mode.REWIND:
		return d if elite else 0.0
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
