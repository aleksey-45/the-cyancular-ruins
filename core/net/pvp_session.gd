class_name PvpSession
extends RefCounted

const MODE_NAMES := {WorldSpec.DUEL: "1v1", WorldSpec.TEAM: "团队对抗", WorldSpec.ROYALE: "大乱斗"}
const BETA_MODE_NAMES := {WorldSpec.DUEL: "Beta 1v1", WorldSpec.TEAM: "时空团队对抗", WorldSpec.ROYALE: "错乱大乱斗"}

static var player_name := "Anon"
static var beta_mode := false
static var entry_mode := ""
static var baseline: Dictionary = {}

static func mode_name(mode: String, beta: bool = false) -> String:
	return (BETA_MODE_NAMES if beta else MODE_NAMES)[mode]

static func begin_match(data: Dictionary, document: Dictionary) -> void:
	beta_mode = data["options"].get("beta", false)
	baseline = data.merged({"map": document}, true)

static func reset(beta := false, mode := "") -> void:
	beta_mode = beta
	entry_mode = mode
	baseline.clear()
