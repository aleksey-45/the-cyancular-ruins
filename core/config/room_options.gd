class_name RoomOptions
extends RefCounted

const ROYALE_PLAYERS := Vector2i(2, 16)
const ROYALE_MINUTES := Vector2i(1, 15)
const DEFAULT_MATCH_MINUTES := 5.0
const MATCH_SECONDS := int(DEFAULT_MATCH_MINUTES * 60)
const MODE_FIELDS := {
	PvpSession.MODE_PVP: ["disabled_weapons", "round_full_heal"],
	PvpSession.MODE_TEAM: [],
	PvpSession.MODE_ROYALE: ["disabled_weapons", "max_players", "match_time"],
}

static func normalized(mode: String, requested: Dictionary) -> Dictionary:
	var options := requested.duplicate()
	if mode == PvpSession.MODE_ROYALE:
		options["max_players"] = capacity(mode, options)
		options["match_time"] = clampi(options.get("match_time", MATCH_SECONDS),
				ROYALE_MINUTES.x * 60, ROYALE_MINUTES.y * 60)
	if options.get("beta", false):
		options["time"] = TimeRules.normalized(options.get("time", {}))
	return options

static func capacity(mode: String, options: Dictionary) -> int:
	match mode:
		PvpSession.MODE_TEAM: return TeamRules.MAX_TOTAL
		PvpSession.MODE_PVP: return 2
	return clampi(options.get("max_players", ROYALE_PLAYERS.y), ROYALE_PLAYERS.x, ROYALE_PLAYERS.y)
