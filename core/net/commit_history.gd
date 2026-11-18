class_name CommitHistory
extends RefCounted

const COMMITS_URL := "https://api.github.com/repos/aleksey-45/the-cyancular-ruins/commits?sha=siri&per_page=20"

static var _rows := PackedStringArray()

static func fetch(owner: Node) -> PackedStringArray:
	if not _rows.is_empty():
		return _rows
	var request := HTTPRequest.new()
	request.timeout = 10.0
	owner.add_child(request)
	if request.request(COMMITS_URL, ["Accept: application/vnd.github+json"]) != OK:
		request.queue_free()
		return []
	var response: Array = await request.request_completed
	request.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return []
	var entries: Variant = JSON.parse_string(response[3].get_string_from_utf8())
	if not entries is Array:
		return []
	_rows = PackedStringArray()
	for entry: Dictionary in entries:
		var commit: Dictionary = entry["commit"]
		_rows.append("%s  %s UTC  %s" % [str(entry["sha"]).left(7),
			str(commit["committer"]["date"]).replace("T", " ").left(16),
			str(commit["message"]).get_slice("\n", 0).strip_edges()])
	return _rows
