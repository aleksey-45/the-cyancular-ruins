class_name WorldSpec
extends RefCounted

const SOLO := "solo"
const DUEL := "pvp"
const TEAM := "team"
const ROYALE := "royale"

enum TimeScope { NONE, WORLD, PERSONAL }

var time_scope := TimeScope.NONE
var map: Dictionary
var mode: String
var roles: Array
var teams: Dictionary
var team_counts: Dictionary
var options: Dictionary
var seed: int
var floors: Array[Vector2i]
var sides: Dictionary
var solo_spawn: Vector2i
var weapons: Array[int]

func _init(document: Dictionary, match_mode: String, roster: Array, seed_value: int) -> void:
	map = document
	floors = SpawnPicker.floor_cells(map)
	mode = match_mode
	roles = roster.duplicate()
	roles.sort()
	seed = seed_value

static func solo(document: Dictionary, spawn: Vector2i, enabled: Array[int], seed_value: int) -> WorldSpec:
	var spec := WorldSpec.new(document, SOLO, [1], seed_value)
	spec.time_scope = TimeScope.WORLD
	spec.solo_spawn = spawn
	spec.weapons = enabled.duplicate()
	return spec

static func arena(document: Dictionary, match_mode: String, roster: Array, team_by_role: Dictionary,
		settings: Dictionary, seed_value: int) -> WorldSpec:
	var spec := WorldSpec.new(document, match_mode, roster, seed_value)
	spec.teams = team_by_role.duplicate()
	spec.team_counts = TeamRules.team_counts(spec.teams) if match_mode == TEAM else {}
	spec.sides = SpawnPicker.respawn_cells(document)
	spec.options = settings.duplicate(true)
	spec.time_scope = TimeScope.PERSONAL if settings.get("beta", false) else TimeScope.NONE
	spec.weapons = WeaponRegistry.enabled_ids(settings.get("disabled_weapons", []))
	return spec

func create_time() -> MatchTime:
	match time_scope:
		TimeScope.WORLD: return WorldTime.new(roles[0])
		TimeScope.PERSONAL: return PersonalTime.new(options["time"], roles)
	return null

func problem() -> String:
	if weapons.is_empty(): return "请至少启用一种武器"
	if mode == SOLO: return ""
	var problem := SpawnPicker.validate_multiplayer_spawns(map)
	if not problem.is_empty():
		return problem
	var limit := SpawnPicker.player_limit(sides, mode, options)
	if limit == 0: return "该模式出生点不足（侧 1 / 侧 2：%d / %d）" % [sides[1].size(), sides[2].size()]
	if roles.size() < RoomOptions.MIN_PLAYERS: return "至少需要 %d 名玩家" % RoomOptions.MIN_PLAYERS
	if roles.size() > limit: return "本图在此模式下最多支持 %d 人，当前 %d 人" % [limit, roles.size()]
	return ""
