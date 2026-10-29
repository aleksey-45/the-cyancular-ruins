class_name PredictionEconomy
extends RefCounted

# 只重算账户，验证角色实际读取的加速倍率和回溯许可。
# 返回可提交的账户前缀；遇到首个行为差异或缺失依赖才要求世界重放。
static func review(economy: TimeEconomy, states: Dictionary, commands: Dictionary, rewards: Dictionary,
		anchor: int, through: int, roles: Array, replacement: Dictionary = {}) -> Dictionary:
	var plan := {"roles": roles, "states": {}, "rewards": {}, "through": anchor,
			"invalid_from": 0}
	if roles.is_empty():
		plan["through"] = through
		return plan
	if not states.has(anchor): return _stop(plan, anchor + 1)
	var old := TimeEconomy.new(economy.rules, roles)
	var fresh := TimeEconomy.new(economy.rules, roles)
	for role in roles:
		if not states[anchor]["time"].has(role): return _stop(plan, anchor + 1)
		old.restore_account(role, states[anchor]["time"][role])
		fresh.restore_account(role, replacement.get(role, states[anchor]["time"][role]))
	plan["states"][anchor] = fresh.state_payload()
	var incoming := _calendar(rewards.values(), fresh.accounts)
	for at in range(anchor + 1, through + 1):
		if not states.has(at) or not commands.has(at): return _stop(plan, at)
		var trace: Dictionary = commands[at].get("economy", {})
		if not trace.get("valid", false): return _stop(plan, at)
		for key: Vector2i in incoming:
			if key.x == at and key.y > 0 and not trace["haste"].has(key.y):
				return _stop(plan, at)
		var previous := _calendar(trace["rewards"], old.accounts)
		var applied: Array = []
		for role in trace["haste"]:
			if old.accounts.has(role):
				var input: Dictionary = commands[at]["inputs"].get(role, {})
				if input.is_empty(): return _stop(plan, at)
				var read: Array = trace["haste"][role]
				var old_mult := old.step_account_haste(role, input, read[0], ActorStep.DT)
				var new_mult := fresh.step_account_haste(role, input, read[0], ActorStep.DT)
				if old_mult != read[1]: return _stop(plan, at)
				if new_mult != old_mult: return _stop(plan, at)
			_deposit(old, previous, at, role)
			applied.append_array(_deposit(fresh, incoming, at, role))
		for role in trace["rewind"]:
			if not old.accounts.has(role): continue
			var read: Array = trace["rewind"][role]
			var before: GrainAccount = old.accounts[role]
			var after: GrainAccount = fresh.accounts[role]
			if (read[0] or read[1]) and before.can_spend() != after.can_spend():
				return _stop(plan, at)
			if read[1]:
				before.spend(ActorStep.DT, economy.rules.rewind_burn)
				after.spend(ActorStep.DT, economy.rules.rewind_burn)
		old.tick(ActorStep.DT)
		fresh.tick(ActorStep.DT)
		for phase in [0, -1]:
			_deposit(old, previous, at, phase)
			applied.append_array(_deposit(fresh, incoming, at, phase))
		var expected := old.state_payload()
		for role in roles:
			if expected[role] != states[at]["time"].get(role, {}):
				return _stop(plan, at)
		plan["states"][at] = fresh.state_payload()
		plan["rewards"][at] = applied
		plan["through"] = at
	return plan

static func _calendar(events: Array, accounts: Dictionary) -> Dictionary:
	var ordered := events.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["serial"] < b["serial"])
	var calendar := {}
	for event: Dictionary in ordered:
		if accounts.has(event["role"]):
			calendar.get_or_add(Vector2i(event["tick"], event["phase"]), []).append(event)
	return calendar

static func _deposit(economy: TimeEconomy, calendar: Dictionary, at: int, phase: int) -> Array:
	var events: Array = calendar.get(Vector2i(at, phase), [])
	for event: Dictionary in events: economy.accounts[event["role"]].deposit(event["amount"])
	return events

static func _stop(plan: Dictionary, at: int) -> Dictionary:
	plan["invalid_from"] = at
	return plan
