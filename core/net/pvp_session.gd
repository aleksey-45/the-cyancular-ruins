class_name PvpSession
extends RefCounted

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"
const MODE_NAMES := {MODE_PVP: "1v1", MODE_TEAM: "团队对抗", MODE_ROYALE: "大乱斗"}
const BETA_MODE_NAMES := {MODE_PVP: "Beta 1v1", MODE_TEAM: "时空团队对抗", MODE_ROYALE: "错乱大乱斗"}

static var player_name := "Anon"
static var beta_mode := false
static var entry_mode := ""
static var baseline: Dictionary = {}
static var room: Dictionary = {}
static var loading_match := false
static var match_events: Array = []

static var room_code: String:
	get: return room.get("code", "")
static var room_mode: String:
	get: return room.get("mode", "")
static var role: int:
	get: return room.get("your_role", 1)

static func mode_name(mode: String, beta: bool = false) -> String:
	return (BETA_MODE_NAMES if beta else MODE_NAMES)[mode]

static func can_rejoin() -> bool:
	return not room_code.is_empty() and not str(room.get("token", "")).is_empty()

static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode and room.get("beta", false) == beta_mode

static func rejoin_payload() -> Dictionary:
	return {"code": room_code, "token": room["token"]} if can_rejoin() else {}

static func clear_rejoin() -> void:
	room.erase("token")

static func begin_match(data: Dictionary, map: Dictionary) -> void:
	beta_mode = data["options"].get("beta", false)
	if room_code != data["code"] or room_mode != data["mode"] or role != data["role"] \
			or room.get("beta", false) != beta_mode:
		room = {}
	room.merge({"code": data["code"], "mode": data["mode"], "your_role": data["role"],
			"beta": beta_mode, "in_match": true}, true)
	baseline = data.merged({"map_info": map})
	loading_match = true

static func reset() -> void:
	beta_mode = false
	entry_mode = ""
	baseline.clear()
	loading_match = false
	match_events.clear()
