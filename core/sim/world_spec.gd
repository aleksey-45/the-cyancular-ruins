class_name WorldSpec
extends RefCounted

const SOLO := "solo"
const DUEL := "pvp"
const TEAM := "team"
const ROYALE := "royale"

var map: Dictionary
var mode: String
var roles: Array
var teams: Dictionary
var options: Dictionary
var seed: int
var solo_spawn: Vector2i
var weapons: Array[int]

func _init(document: Dictionary, match_mode: String, roster: Array, sides: Dictionary,
		rules: Dictionary, seed_value: int) -> void:
	map = document
	mode = match_mode
	roles = roster.duplicate()
	roles.sort()
	teams = sides.duplicate()
	options = rules.duplicate(true)
	seed = seed_value
	weapons = WeaponRegistry.enabled_ids(options.get("disabled_weapons", []))

static func solo(document: Dictionary, spawn: Vector2i, enabled: Array[int], seed_value: int) -> WorldSpec:
	var spec := WorldSpec.new(document, SOLO, [1], {}, {}, seed_value)
	spec.solo_spawn = spawn
	spec.weapons = enabled.duplicate()
	return spec
