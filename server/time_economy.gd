class_name TimeEconomy
extends RefCounted


var rules: TimeRules
var accounts: Dictionary = {}


func _init(r: TimeRules = null, roles: Array = []) -> void:
	rules = r if r != null else TimeRules.new()
	for role in roles:
		add_role(int(role))


func add_role(role: int) -> void:
	if role > 0 and not accounts.has(role):
		accounts[role] = rules.make_account()


func tick(delta: float) -> void:
	if delta <= 0.0:
		return
	for role in accounts:
		(accounts[role] as GrainAccount).regen(delta)


func award_kill(killer: int, victim: int) -> void:
	if killer <= 0 or killer == victim or not accounts.has(victim) or not accounts.has(killer):
		return
	var amount := int((accounts[victim] as GrainAccount).balance * rules.kill_ratio)
	if amount > 0:
		(accounts[killer] as GrainAccount).deposit(amount)


func award_damage(attacker: int, victim: int, damage: int) -> void:
	if attacker <= 0 or attacker == victim or damage <= 0 or not accounts.has(attacker):
		return
	(accounts[attacker] as GrainAccount).deposit(damage * rules.damage_gain)


func award_blocks(role: int, count: int) -> void:
	if role <= 0 or count <= 0 or not accounts.has(role):
		return
	(accounts[role] as GrainAccount).deposit(count * rules.block_gain)


func state_payload() -> Dictionary:
	var out := {}
	for role in accounts:
		var a := accounts[role] as GrainAccount
		out[int(role)] = {"b": a.balance, "w": a.short_used, "l": a.loan_used, "k": a.locked,
				"cap": a.cap, "win": a.window, "m": rules.haste_mult}
	return out
