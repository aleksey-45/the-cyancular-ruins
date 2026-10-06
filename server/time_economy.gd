class_name TimeEconomy
extends RefCounted

# 服务端权威时间粒子经济系统：为每个对局角色（role）维护独立的 GrainAccount 实例并处理粒子结算。
#
# 设计规范：
#   · 服务端绝对权威：账户数据完全由服务端维护；客户端仅接收 10Hz 的状态广播镜像（time_state），
#     客户端数据不参与任何结算校验，保障对局安全性。
#   · 纯逻辑解耦（支持 -s 独立测试）：由宿主类统一调度四种结算方式：
#     击杀奖励（倒地瞬间判定）、伤害奖励（有效命中归因）、场景破坏（16px 子格破坏归因）、时间恢复（每帧 tick）。
#   · 结算过滤规则：仅对敌方生效；自伤、自杀、无法归因攻击者时不予结算；
#     友军伤害由调用方过滤；被击杀者当前余额不予扣减。

var rules: TimeRules
var accounts: Dictionary = {}   # role(int) -> GrainAccount


func _init(r: TimeRules = null, roles: Array = []) -> void:
	rules = r if r != null else TimeRules.new()
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = rules.make_account()


## 每帧自动恢复：推进时间恢复逻辑（优先偿还透支，还清后恢复短期额度，由 GrainAccount 自主管理锁定与解锁）。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role in accounts:
		(accounts[role] as GrainAccount).regen(delta)


## 击杀奖励：按被击杀者账户总额度的设定比例进行奖励（被击杀者自身余额不扣除）。自杀或无法归因时不结算。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	var amount := int((accounts[victim] as GrainAccount).balance * rules.kill_ratio)
	if amount > 0:
		(accounts[killer] as GrainAccount).deposit(amount)


## 伤害奖励：根据有效伤害点数按比例增加粒子。自伤或无法归因时不结算；队友伤害由外部调用方过滤。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	(accounts[attacker] as GrainAccount).deposit(damage * rules.damage_gain)


## 场景破坏奖励：每破坏一个 16px 子格奖励固定粒子。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	(accounts[role] as GrainAccount).deposit(count * rules.block_gain)


## 生成用于 10Hz 网络同步的状态广播数据字典：{role: {"b": 余额, "w": 短期已用, "l": 透支额度, "k": 锁定状态}}。
func state_payload() -> Dictionary:
	var out := {}
	for role in accounts:
		var a := accounts[role] as GrainAccount
		out[int(role)] = {"b": a.balance, "w": a.short_used, "l": a.loan_used, "k": a.locked,
				"cap": a.cap, "win": a.window, "m": rules.haste_mult}
	return out
