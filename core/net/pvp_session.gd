class_name PvpSession
extends RefCounted

const DEFAULT_PORT := 7777
const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"

static var server_address := "127.0.0.1"
static var server_port := DEFAULT_PORT
static var role := 1
static var player_name := "Anon"
static var map_path := ""
static var token := ""
static var room_code := ""
static var room_mode := ""
static var beta_mode := false
static var entry_mode := ""
static var baseline: Dictionary = {}
static var room: Dictionary = {}
static var loading_match := false
static var match_events: Array = []

static func can_rejoin() -> bool:
	return not token.is_empty() and not room_code.is_empty()

static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode

static func clear_rejoin() -> void:
	token = ""
	room_code = ""

static func note_room(code: String, mode: String) -> void:
	if code != room_code or mode != room_mode:
		clear_rejoin()
	room_code = code
	room_mode = mode

static func reset() -> void:
	role = 1
	map_path = ""
	beta_mode = false
	entry_mode = ""
	baseline.clear()
	loading_match = false
	match_events.clear()
