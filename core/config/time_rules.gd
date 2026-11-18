class_name TimeRules
extends RefCounted

enum { DEFAULT, MINIMUM, MAXIMUM }

# 每个设置项按默认值、下限和上限的顺序保存。建房与开局消息按此字典的字段顺序编码。
const FIELDS := {
	"initial": [1000.0, 0.0, 5000.0],
	"cap": [1800.0, 100.0, 9999.0],
	"rewind_burn": [150.0, 10.0, 500.0],
	"haste_burn": [70.0, 10.0, 500.0],
	"window": [250.0, 0.0, 1000.0],
	"regen": [50.0, 0.0, 300.0],
	"kill_ratio": [0.5, 0.0, 1.0],
	"haste_mult": [3.0, 1.0, 10.0],
	"block_gain": [10, 0, 200],
	"damage_gain": [4, 0, 50],
}


static func normalized(values: Dictionary = {}) -> Dictionary:
	var result := {}
	for field in FIELDS:
		var rule: Array = FIELDS[field]
		var value: Variant = values.get(field, rule[DEFAULT])
		if not (value is int or value is float) or not is_finite(value):
			value = rule[DEFAULT]
		var bounded := clampf(value, rule[MINIMUM], rule[MAXIMUM])
		result[field] = int(bounded) if rule[DEFAULT] is int else bounded
	result["cap"] = maxf(result["cap"], result["initial"])
	return result
