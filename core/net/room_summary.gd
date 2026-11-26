class_name RoomSummary
extends RefCounted

var code: String
var mode: String
var occupied: int
var capacity: int
var beta: bool
var in_match: bool

func _init(info: Dictionary) -> void:
	code = info.code
	mode = info.mode
	occupied = info.players
	capacity = info.max
	beta = info.beta
	in_match = info.in_match

static func valid_code(value: String) -> bool:
	if value.length() != 8: return false
	for digit in value:
		if digit < "0" or digit > "9": return false
	return true
