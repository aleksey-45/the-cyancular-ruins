class_name TimeEconomy
extends RefCounted

# Beta 时间玩法的服务器权威颗粒经济(P2/B21):每个 role 一份 GrainAccount + 三条入账。

var rules: TimeRules
var accounts: Dictionary = {}   # role(int) -> GrainAccount


func _init(r: TimeRules = null, roles: Array = []) -> void:
	rules = r if r != null else TimeRules.new()
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = rules.make_account()


## 每帧回复(50/s 先还贷后回窗,GrainAccount 自己管锁定/解锁)。
func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role in accounts:
		(accounts[role] as GrainAccount).regen(delta)


## 击杀:得"被击杀者账户总额度 × 比例"(被击杀者不减少)。归因不到/自杀不结算。
func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	var amount := int((accounts[victim] as GrainAccount).balance * rules.kill_ratio)
	if amount > 0:
		(accounts[killer] as GrainAccount).deposit(amount)


## 伤害:每点 × damage_gain。归因不到/打自己不结算;同队过滤在调用方(宿主有 same_team)。
func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	(accounts[attacker] as GrainAccount).deposit(damage * rules.damage_gain)


## 拆砖:每摧毁一个 16px 子格 × block_gain。
func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	(accounts[role] as GrainAccount).deposit(count * rules.block_gain)


## 10Hz 显示镜像:{role: {"b":余额, "w":短时已用, "l":贷款, "k":锁定}}。
func state_payload() -> Dictionary:
	var out := {}
	for role in accounts:
		var a := accounts[role] as GrainAccount
		out[int(role)] = {"b": a.balance, "w": a.short_used, "l": a.loan_used, "k": a.locked,
				"cap": a.cap, "win": a.window, "m": rules.haste_mult}
	return out
