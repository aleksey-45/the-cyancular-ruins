class_name PvpSession
extends RefCounted

const MODE_NAMES := {WorldSpec.DUEL: "1v1", WorldSpec.TEAM: "团队对抗", WorldSpec.ROYALE: "大乱斗"}
const BETA_MODE_NAMES := {WorldSpec.DUEL: "Beta 1v1", WorldSpec.TEAM: "时空团队对抗", WorldSpec.ROYALE: "错乱大乱斗"}

static var player_name := "Anon"
static var beta_mode := false
static var entry_mode := ""
static var baseline: Dictionary = {}
static var room: Dictionary = {}

static var room_code: String:
	get: return room.get("code", "")
static var room_mode: String:
	get: return room.get("mode", "")

static func mode_name(mode: String, beta: bool = false) -> String:
	return (BETA_MODE_NAMES if beta else MODE_NAMES)[mode]

static func can_rejoin() -> bool:
	return not room_code.is_empty() and not str(room.get("token", "")).is_empty()

static func rejoin_payload() -> Dictionary:
	return {"code": room_code, "token": room["token"]} if can_rejoin() else {}

static func begin_match(data: Dictionary, document: Dictionary) -> void:
	beta_mode = data["options"].get("beta", false)
	if room_code != data["code"] or room_mode != data["mode"] or room.get("your_role") != data["role"] \
			or room.get("beta", false) != beta_mode:
		room = {}
	room.merge({"code": data["code"], "mode": data["mode"], "your_role": data["role"],
			"beta": beta_mode, "in_match": true}, true)
	baseline = data.merged({"map": document}, true)

static func reset(beta := false, mode := "") -> void:
	beta_mode = beta
	entry_mode = mode
	baseline.clear()
