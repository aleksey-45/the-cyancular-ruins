class_name TimeEconomy
extends RefCounted

signal awarded(role: int, amount: int)

# 时间颗粒账户：服务端权威结算，客户端在预测与重放中推进本地账户。
#
# - 服务端账户随 STATE 同步；客户端在校正前恢复账户，再按输入逐 tick 重放消耗与回复。
# - 纯逻辑解耦：宿主持有经济系统实例，四类颗粒收支结算均统一调度本类处理：
#   击杀奖励（判定击杀者）、伤害收益（命中结算并归因至攻击者）、场景瓦片破坏奖励（按摧毁子格数结算）以及时间自然回复。
# - 收益过滤规则：仅对有效敌方目标生效；自残、自杀或未知来源不予结算，友方伤害由外层宿主过滤，被击杀者当前余额保持不变。

var rules: TimeRules
var accounts: Dictionary = {}   # role(int) -> GrainAccount


func _init(r: TimeRules = null, roles: Array = []) -> void:
	rules = r if r != null else TimeRules.new()
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = rules.make_account()

func restore_account(role: int, state: Dictionary) -> void:
	add_role(role)
	var account: GrainAccount = accounts[role]
	account.cap = state["cap"]
	account.window = state["win"]
	account.balance = state["b"]
	account.short_used = state["w"]
	account.loan_used = state["l"]
	account.locked = state["k"]


func step_haste(player: Node2D, record: Dictionary, delta: float) -> void:
	player.pvp_haste_mult = step_account_haste(player.role, record, player._controls_locked, delta)

# 账户检查与真实步进共用同一入口，不移动角色、创建节点或触发表现。
func step_account_haste(role: int, record: Dictionary, controls_locked: bool, delta: float) -> float:
	var account: GrainAccount = accounts[role]
	var haste: bool = (record["held"] & PacketInputSource.BIT_HASTE) != 0 \
			and not controls_locked and account.can_spend()
	if haste:
		account.spend(delta, rules.haste_burn)
	return rules.haste_mult if haste else 1.0


## 定时自然回复：以固定速率优先偿还透支额度，透支还清后恢复短期可用额度。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role in accounts:
		(accounts[role] as GrainAccount).regen(delta)


## 击杀收益结算：按被击杀者账户总额的一定比例奖励击杀者，被击杀者余额不扣减。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	var amount := int((accounts[victim] as GrainAccount).balance * rules.kill_ratio)
	if amount > 0:
		_award(killer, amount)


## 伤害收益结算：根据造成的伤害点数乘以收益倍率奖励攻击者。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	_award(attacker, damage * rules.damage_gain)


## 瓦片破坏收益结算：根据击碎的 16 像素子格数量奖励射手。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	_award(role, count * rules.block_gain)

func _award(role: int, amount: int) -> void:
	var deposited := (accounts[role] as GrainAccount).deposit(amount)
	if deposited > 0:
		awarded.emit(role, deposited)


## 获取状态同步负载字典，包含各角色的余额、短期已用量、透支量与锁定状态。
func state_payload() -> Dictionary:
	var out := {}
	for role in accounts:
		out[int(role)] = account_payload(role)
	return out

func account_payload(role: int) -> Dictionary:
	var account: GrainAccount = accounts[role]
	return {"b": account.balance, "w": account.short_used, "l": account.loan_used, "k": account.locked,
			"cap": account.cap, "win": account.window, "m": rules.haste_mult}
