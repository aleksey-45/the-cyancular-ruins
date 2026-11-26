class_name RoomOptions
extends RefCounted

const REJOIN_SECONDS := 60
const MIN_PLAYERS := 2
const ROYALE_PLAYERS := Vector2i(MIN_PLAYERS, 16)
const ROYALE_MINUTES := Vector2i(1, 15)
const DEFAULT_MATCH_MINUTES := 5.0
const MATCH_SECONDS := int(DEFAULT_MATCH_MINUTES * 60)
const DEFAULTS := {
	"map": "res://maps/newfactory.cyrm", "max_players": ROYALE_PLAYERS.y, "match_time": MATCH_SECONDS,
	"round_full_heal": false, "disabled_weapons": [], "beta": false, "time": {},
	"player_collision": false,
}
const MODE_FIELDS := {
	WorldSpec.DUEL: ["disabled_weapons", "round_full_heal"],
	WorldSpec.TEAM: [],
	WorldSpec.ROYALE: ["disabled_weapons", "max_players", "match_time"],
}

static func normalized(mode: String, requested: Dictionary) -> Dictionary:
	var options := DEFAULTS.merged(requested, true)
	if mode == WorldSpec.ROYALE:
		options["max_players"] = capacity(mode, options)
		options["match_time"] = clampi(options["match_time"],
				ROYALE_MINUTES.x * 60, ROYALE_MINUTES.y * 60)
	if options["beta"]:
		options["time"] = TimeRules.normalized(options["time"])
	return options

static func capacity(mode: String, options: Dictionary) -> int:
	match mode:
		WorldSpec.TEAM: return TeamRules.MAX_TOTAL
		WorldSpec.DUEL: return 2
	return clampi(options.get("max_players", ROYALE_PLAYERS.y), ROYALE_PLAYERS.x, ROYALE_PLAYERS.y)
