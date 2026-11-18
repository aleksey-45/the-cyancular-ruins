class_name TimeEconomy
extends RefCounted

# 时间颗粒账户：服务端权威结算，客户端在预测与重放中推进本地账户。
#
# - 服务端账户随 STATE 同步；客户端在校正前恢复账户，再按输入逐 tick 重放消耗与回复。
# - 纯逻辑解耦：宿主持有经济系统实例，四类颗粒收支结算均统一调度本类处理：
#   击杀奖励（判定击杀者）、伤害收益（命中结算并归因至攻击者）、场景瓦片破坏奖励（按摧毁子格数结算）以及时间自然回复。
# - 收益过滤规则：仅对有效敌方目标生效；自残、自杀或未知来源不予结算，友方伤害由外层宿主过滤，被击杀者当前余额保持不变。

var rules: Dictionary
var rewind_seconds: float
var accounts: Dictionary[int, GrainAccount] = {}


func _init(options: Dictionary, roles: Array = []) -> void:
	rules = TimeRules.normalized(options)
	rewind_seconds = minf(rules["cap"] / rules["rewind_burn"], 15.0)
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = GrainAccount.new(rules["initial"], rules["cap"], rules["window"],
				rules["regen"], rules["window"])

func restore_account(role: int, state: Array) -> void:
	add_role(role)
	accounts[role].restore_state(state)


func advance(players: Dictionary, inputs: Dictionary) -> void:
	for role: int in inputs:
		step_haste(players[role], inputs[role], ActorStep.DT)
	tick(ActorStep.DT)

func step_haste(player: Player, record: Array, delta: float) -> void:
	player.personal_haste_mult = 1.0
	var held: int = record[ActorInput.HELD]
	if player._controls_locked or player.sim_downed or player.rewinding \
			or (held & (ActorInput.BIT_HASTE | ActorInput.BIT_REWIND)) != ActorInput.BIT_HASTE:
		return
	var account: GrainAccount = accounts[player.role]
	if account.can_spend():
		account.spend(delta, rules["haste_burn"])
		player.personal_haste_mult = rules["haste_mult"]


## 定时自然回复：以固定速率优先偿还透支额度，透支还清后恢复短期可用额度。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role: int in accounts:
		accounts[role].regen(delta)


## 击杀收益结算：按被击杀者账户总额的一定比例奖励击杀者，被击杀者余额不扣减。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	accounts[killer].deposit(int(accounts[victim].balance * rules["kill_ratio"]))


## 伤害收益结算：根据造成的伤害点数乘以收益倍率奖励攻击者。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	accounts[attacker].deposit(damage * rules["damage_gain"])


## 瓦片破坏收益结算：根据击碎的 16 像素子格数量奖励射手。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	accounts[role].deposit(count * rules["block_gain"])


func state_payload() -> Dictionary[int, Array]:
	var states: Dictionary[int, Array] = {}
	for role: int in accounts:
		states[role] = accounts[role].capture_state()
	return states
