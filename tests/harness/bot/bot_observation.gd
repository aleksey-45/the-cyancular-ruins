extends RefCounted

# 纯感知规则(不碰节点 / 会话态):输入是候选角色与相机 / 雷达参数,输出固定形状的 Observation 数组。
# Observation = {role:int, source:String, relation:String, pos:Vector2, time:float,
#                uncertainty:float, seen_action:String}
# 来源优先级 view > radar > memory;memory 原地刷新,过期条目不再输出。
# 环面数学复用 GridPathfinder(几何单一来源),本文件不复制。

const Geo := preload("res://core/sim/grid_pathfinder.gd")

const SOURCE_VIEW := "view"
const SOURCE_RADAR := "radar"
const SOURCE_MEMORY := "memory"

const REL_SELF := "self"
const REL_ALLY := "ally"
const REL_ENEMY := "enemy"
const REL_UNKNOWN := "unknown"

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"


# 敌我关系只从模式 + 队伍表判;队伍表缺(任一方 0)一律 unknown,不猜。
static func relation_of(role: int, my_role: int, mode: String, teams: Dictionary) -> String:
	if role == my_role:
		return REL_SELF
	match mode:
		MODE_TEAM:
			var a := int(teams.get(my_role, 0))
			var b := int(teams.get(role, 0))
			if a == 0 or b == 0:
				return REL_UNKNOWN
			return REL_ALLY if a == b else REL_ENEMY
		MODE_PVP, MODE_ROYALE:
			return REL_ENEMY
	return REL_UNKNOWN


# 主画面:世界视口(窗口 / zoom)按环面最短向量判入画,不以玩家为中心画矩形。
static func in_view(pos: Vector2, cam_center: Vector2, view_size: Vector2,
		map_size: Vector2) -> bool:
	var d := Geo.toroidal_delta_px(cam_center, pos, map_size.x, map_size.y)
	return absf(d.x) <= view_size.x * 0.5 and absf(d.y) <= view_size.y * 0.5


# 雷达:圆形范围 + 环面最短距离,不查墙体遮挡(与 Minimap 同一条规则)。
static func in_radar(pos: Vector2, self_pos: Vector2, radius_px: float,
		map_size: Vector2) -> bool:
	if radius_px <= 0.0:
		return false
	return Geo.toroidal_delta_px(self_pos, pos, map_size.x, map_size.y).length() <= radius_px


# candidates: [{role:int, pos:Vector2, action?:String}]。
# ctx 键:my_role / mode / teams / self_pos / cam_center / view_size / map_size /
#        radar_radius_px / radar_uncertainty_px / now / memory_ttl。
# memory: role -> {pos, time},可见时刷新、不可见但未过期时作 memory 来源。
static func build(candidates: Array, ctx: Dictionary, memory: Dictionary) -> Array:
	var out: Array = []
	var now := float(ctx.get("now", 0.0))
	var ttl := float(ctx.get("memory_ttl", 3.0))
	var map_size: Vector2 = ctx.get("map_size", Vector2.ONE)
	var self_pos: Vector2 = ctx.get("self_pos", Vector2.ZERO)
	var cam_center: Vector2 = ctx.get("cam_center", self_pos)
	var view_size: Vector2 = ctx.get("view_size", Vector2.ZERO)
	var radar_px := float(ctx.get("radar_radius_px", 0.0))
	var radar_unc := float(ctx.get("radar_uncertainty_px", 0.0))
	for c in candidates:
		var role := int(c.get("role", 0))
		if role == 0:
			continue
		var pos: Vector2 = c.get("pos", Vector2.INF)
		if not pos.is_finite():
			continue
		var rel := relation_of(role, int(ctx.get("my_role", 0)), str(ctx.get("mode", "")),
				ctx.get("teams", {}) as Dictionary)
		var mem: Dictionary = memory.get(role, {})
		var source := ""
		var unc := 0.0
		if in_view(pos, cam_center, view_size, map_size):
			source = SOURCE_VIEW
		elif in_radar(pos, self_pos, radar_px, map_size):
			source = SOURCE_RADAR
			unc = radar_unc
		elif not mem.is_empty() and now - float(mem.get("time", -INF)) <= ttl:
			source = SOURCE_MEMORY
			pos = mem.get("pos", pos)
			unc = radar_unc * 2.0
		else:
			continue
		memory[role] = {"pos": pos, "time": now}
		out.append({
			"role": role,
			"source": source,
			"relation": rel,
			"pos": pos,
			"time": now,
			"uncertainty": unc,
			"seen_action": str(c.get("action", "")),
		})
	return out


# 清掉过期记忆;调用方每帧或低频调用都可。
static func prune(memory: Dictionary, now: float, ttl: float) -> void:
	for role in memory.keys():
		var mem: Dictionary = memory[role]
		if now - float(mem.get("time", -INF)) > ttl:
			memory.erase(role)
