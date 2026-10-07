class_name TimeEconomy
extends RefCounted

# 时间机制下的服务端权威颗粒账户经济系统：为每个角色维护独立的 GrainAccount。
#
# - 服务端权威：所有颗粒账户均由服务端宿主统一维护与计算，客户端仅接收定频同步状态用于渲染；
#   客户端上报的任何数值均不参与结算。
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
		(accounts[killer] as GrainAccount).deposit(amount)


## 伤害收益结算：根据造成的伤害点数乘以收益倍率奖励攻击者。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	(accounts[attacker] as GrainAccount).deposit(damage * rules.damage_gain)


## 瓦片破坏收益结算：根据击碎的 16 像素子格数量奖励射手。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	(accounts[role] as GrainAccount).deposit(count * rules.block_gain)


## 获取状态同步负载字典，包含各角色的余额、短期已用量、透支量与锁定状态。
func state_payload() -> Dictionary:
	var out := {}
	for role in accounts:
		var a := accounts[role] as GrainAccount
		out[int(role)] = {"b": a.balance, "w": a.short_used, "l": a.loan_used, "k": a.locked,
				"cap": a.cap, "win": a.window, "m": rules.haste_mult}
	return out
