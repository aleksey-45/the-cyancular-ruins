class_name EditorMeta
extends RefCounted

# 镜像 level_editor/core/40_meta.js —— 元数据段文本编解码。
# 文本形状与游戏侧 MapFormat.parse_spawn_metadata() 对齐:先注释、再出生点、再按侧复活点、最后敌人。
# ★ respawn 行按侧分组写(侧 1 全部在前、侧 2 在后):游戏侧按文件顺序去重,顺序变了「生效的那条」也会变。


static func build_meta(map: Dictionary) -> String:
	var lines: Array[String] = []
	var comments: Array = map.get("comments", [])
	for c in comments:
		lines.append("# " + String(c))
	var players: Array = map.get("players", [])
	for i in players.size():
		var kw := "player" if i == 0 else ("player2" if i == 1 else "player" + str(i + 1))
		var p: Dictionary = players[i]
		lines.append("# " + kw + " " + str(int(p["x"])) + " " + str(int(p["y"])))
	var rs: Array = map.get("respawns", [])
	for side in [1, 2]:
		for r in rs:
			var rr: Dictionary = r
			if int(rr["side"]) != side:
				continue
			lines.append("# respawn " + str(side) + " " + str(int(rr["x"])) + " " + str(int(rr["y"])))
	var enemies: Array = map.get("enemies", [])
	for e in enemies:
		var ee: Dictionary = e
		lines.append("# enemy " + String(ee["type"]) + " " + str(int(ee["x"])) + " " + str(int(ee["y"])))
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


# 解析失败的行降级成注释,不丢掉 —— 编辑器不许静默吃掉用户写的东西。
static func parse_meta(text: String) -> Dictionary:
	var players: Array = []
	var enemies: Array = []
	var respawns: Array = []
	var comments: Array = []
	var lines := text.split("\n")
	for raw in lines:
		var s := String(raw).strip_edges()
		if s == "":
			continue
		if s.substr(0, 1) != "#":
			comments.append(s)
			continue
		var body := s.substr(1).strip_edges()
		var parts := _split_ws(body)
		var head := parts[0] if parts.size() > 0 else ""
		if _is_player_head(head) and parts.size() >= 3:
			if _is_int_literal(parts[1]) and _is_int_literal(parts[2]):
				players.append({"x": int(parts[1]), "y": int(parts[2])})
				continue
		elif head == "respawn" and parts.size() >= 4:
			# 侧号只认 1|2;认不出的行降级成注释而不是丢掉。
			if (parts[1] == "1" or parts[1] == "2") and _is_int_literal(parts[2]) and _is_int_literal(parts[3]):
				respawns.append({"side": int(parts[1]), "x": int(parts[2]), "y": int(parts[3])})
				continue
		elif head == "enemy" and parts.size() >= 4:
			if _is_int_literal(parts[2]) and _is_int_literal(parts[3]):
				enemies.append({"type": parts[1], "x": int(parts[2]), "y": int(parts[3])})
				continue
		comments.append(body)
	return {"players": players, "enemies": enemies, "respawns": respawns, "comments": comments}


# /^player\d*$/ —— 手写,不引 RegEx。
static func _is_player_head(head: String) -> bool:
	if not head.begins_with("player"):
		return false
	var rest := head.substr(6)
	if rest == "":
		return true
	for i in rest.length():
		var cp := rest.unicode_at(i)
		if cp < 48 or cp > 57:
			return false
	return true


# /^[+-]?\d+$/ —— 不用 is_valid_int(它放行 1e3/3.5 之外还会接受 "+"/"-" 这类边界)。
static func _is_int_literal(s: String) -> bool:
	if s == "":
		return false
	var i := 0
	if s.unicode_at(0) == 43 or s.unicode_at(0) == 45:
		i = 1
	if i >= s.length():
		return false
	while i < s.length():
		var cp := s.unicode_at(i)
		if cp < 48 or cp > 57:
			return false
		i += 1
	return true


# JS 的 body.split(/\s+/) —— 按任意空白切,连续空白不产空项。
static func _split_ws(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for i in s.length():
		var cp := s.unicode_at(i)
		if EditorGeometry._is_js_space(cp):
			if cur != "":
				out.append(cur)
				cur = ""
			continue
		cur += s.substr(i, 1)
	if cur != "":
		out.append(cur)
	return out
